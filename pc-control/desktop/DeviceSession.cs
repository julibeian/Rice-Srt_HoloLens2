using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

namespace Rice.HoloLens.Control {
    public sealed class DeviceSession : IDisposable {
        public readonly string Workspace,LogDirectory;
        readonly string powershell,ffmpeg;
        readonly JavaScriptSerializer json=new JavaScriptSerializer();
        readonly object logLock=new object(),frameLock=new object();
        readonly SemaphoreSlim commandGate=new SemaphoreSlim(1,1),lifecycle=new SemaphoreSlim(1,1);
        Process video,decoder,controller;
        Bitmap frame;
        long frameSequence;
        DateTime frameAt=DateTime.MinValue;
        string leaseRun;
        CancellationTokenSource controlCancellation=new CancellationTokenSource();
        bool videoStopping,stopping;
        PointerMap pointerMap;
        float pitch=.1f,yaw=-.23f;
        public bool Connected {get;private set;}
        public bool Controlling {get;private set;}
        public string DeviceName {get;private set;}
        public DateTime ControlExpires {get;private set;}
        public string LastNotice {get;private set;}
        public long FrameSequence {get{return Interlocked.Read(ref frameSequence);}}
        public double FrameAge {get{lock(frameLock)return (DateTime.UtcNow-frameAt).TotalSeconds;}}
        public bool Calibrated {get{return pointerMap!=null;}}
        public event Action<string> Notice;
        public DeviceSession(string workspace) {
            Workspace=Path.GetFullPath(workspace);powershell=Path.Combine(Workspace,"runtime\\powershell\\pwsh.exe");
            var runtime=json.Deserialize<Dictionary<string,object>>(File.ReadAllText(Path.Combine(Workspace,"pc-control\\dist\\runtime.json")));
            ffmpeg=(string)runtime["Ffmpeg"];
            LogDirectory=Path.Combine(Workspace,"pc-control\\.state\\sessions",DateTime.Now.ToString("yyyyMMdd-HHmmss")+"-"+Guid.NewGuid().ToString("N").Substring(0,6));
            Directory.CreateDirectory(LogDirectory);
        }
        public static string Quote(string value) {
            var result=new StringBuilder("\"");int slashes=0;
            foreach(char c in value){if(c=='\\'){slashes++;continue;}if(c=='\"'){result.Append('\\',slashes*2+1).Append(c);slashes=0;continue;}result.Append('\\',slashes).Append(c);slashes=0;}
            return result.Append('\\',slashes*2).Append('"').ToString();
        }
        ProcessStartInfo StartInfo(string program,string arguments) {
            return new ProcessStartInfo(program,arguments){WorkingDirectory=Workspace,UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true,RedirectStandardError=true,RedirectStandardInput=true,StandardOutputEncoding=Encoding.UTF8,StandardErrorEncoding=Encoding.UTF8};
        }
        public void Log(string type,object value) {try{lock(logLock)File.AppendAllText(Path.Combine(LogDirectory,"events.jsonl"),json.Serialize(new{at=DateTimeOffset.Now.ToString("o"),type=type,value=value})+Environment.NewLine,Encoding.UTF8);}catch{}}
        void Say(string message){LastNotice=message;Log("notice",message);var handler=Notice;if(handler!=null)handler(message);}
        static async Task<T> Bounded<T>(Task<T> work,int milliseconds,string label) {
            if(await Task.WhenAny(work,Task.Delay(milliseconds))!=work)throw new TimeoutException(label+"超时；先核对本次结果，再继续操作");return await work;
        }
        string OperationCommand(string operation){return "-NoLogo -NoProfile -NonInteractive -File "+Quote(Path.Combine(Workspace,"pc-control\\ops\\Invoke-Operation.ps1"))+" -Operation "+Quote(operation);}
        async Task<Dictionary<string,object>> RunScript(string operation,params string[] arguments) {
            var command=OperationCommand(operation);
            foreach(var argument in arguments)command+=" "+Quote(argument);
            using(var process=new Process{StartInfo=StartInfo(powershell,command)}) {
                process.Start();process.StandardInput.Close();
                var output=process.StandardOutput.ReadToEndAsync();var error=process.StandardError.ReadToEndAsync();
                string text;
                try{text=await Bounded(output,45000,"设备操作");}catch{KillOwn(process);throw;}
                var errors=await error;process.WaitForExit();
                Log("script",new{operation=operation,arguments=arguments,exit=process.ExitCode,output=text,error=errors});
                if(process.ExitCode!=0)throw new InvalidOperationException("设备操作未完成，详情已保存在运行记录中");
                return json.Deserialize<Dictionary<string,object>>(text.Trim().TrimStart('\uFEFF'));
            }
        }
        static bool True(Dictionary<string,object> data,string name){return data.ContainsKey(name)&&data[name] is bool&&(bool)data[name];}
        public async Task ConnectAsync() {
            Say("正在核对原眼镜与保存的认证…");
            var status=await RunScript("BridgeStatus");
            if(!status.ContainsKey("State")||(string)status["State"]!="connected")throw new InvalidOperationException("正在等待原眼镜连接，后台会继续自动发现");
            var portal=await RunScript("Portal");
            if(!True(portal,"SshIdentityVerified")||!True(portal,"PortalAuthenticated")||!True(portal,"PortalCertificatePinned"))throw new InvalidOperationException("原眼镜身份或保存的认证未通过核对");
            DeviceName=(string)portal["Device"];Connected=true;
            StartVideo();Say("已连接 "+DeviceName+"，正在接收真实全息画面…");
        }
        void StartVideo() {
            if(video!=null)StopVideo();videoStopping=false;
            decoder=new Process{StartInfo=StartInfo(ffmpeg,"-hide_banner -loglevel warning -fflags nobuffer -flags low_delay -probesize 65536 -analyzeduration 0 -i pipe:0 -an -vf fps=12 -f image2pipe -vcodec mjpeg -q:v 3 pipe:1")};
            decoder.ErrorDataReceived+=(s,e)=>{if(e.Data!=null)Log("decoder",e.Data);};decoder.Start();decoder.BeginErrorReadLine();
            video=new Process{StartInfo=StartInfo(powershell,OperationCommand("Video"))};
            video.ErrorDataReceived+=(s,e)=>{if(e.Data!=null)Log("video",e.Data);};video.Start();video.StandardInput.Close();video.BeginErrorReadLine();
            var source=video;var destination=decoder;
            Task.Run(async()=>{try{await source.StandardOutput.BaseStream.CopyToAsync(destination.StandardInput.BaseStream);destination.StandardInput.Close();}catch(Exception e){if(!videoStopping)Log("video_pipe",e.GetType().Name);}});
            Task.Run(()=>ReadFrames(destination));
        }
        void ReadFrames(Process process) {
            try {
                var input=process.StandardOutput.BaseStream;var bytes=new byte[16384];var jpeg=new MemoryStream();int last=-1;bool collecting=false;
                int count;
                while((count=input.Read(bytes,0,bytes.Length))>0)for(int i=0;i<count;i++) {
                    int current=bytes[i];
                    if(!collecting&&last==255&&current==216){jpeg.SetLength(0);jpeg.Position=0;jpeg.WriteByte(255);collecting=true;}
                    if(collecting)jpeg.WriteByte((byte)current);
                    if(collecting&&last==255&&current==217){
                        try{jpeg.Position=0;using(var image=Image.FromStream(jpeg)) {var next=new Bitmap(image);lock(frameLock){var old=frame;frame=next;frameAt=DateTime.UtcNow;Interlocked.Increment(ref frameSequence);if(old!=null)old.Dispose();}}}catch(ArgumentException){}
                        collecting=false;
                    }
                    if(jpeg.Length>4194304){collecting=false;jpeg.SetLength(0);jpeg.Position=0;}last=current;
                }
                jpeg.Dispose();if(!videoStopping)Say("实时画面已结束，请重新连接眼镜");
            }catch(Exception e){if(!videoStopping)Log("frame_reader",e.GetType().Name);}
        }
        public Bitmap Snapshot(){lock(frameLock)return frame==null?null:new Bitmap(frame);}
        void RequireFresh(){if(FrameAge>2.5||FrameSequence==0)throw new InvalidOperationException("当前画面已停滞，点按未发送；请先恢复实时画面");}
        async Task WaitFrames(long after,int count) {
            var until=DateTime.UtcNow.AddSeconds(6);
            while(FrameSequence<after+count){controlCancellation.Token.ThrowIfCancellationRequested();if(DateTime.UtcNow>until)throw new TimeoutException("等待新的眼镜画面超时，点按未发送");await Task.Delay(60);}
            RequireFresh();
        }
        async Task SettleView(long after){await Task.Delay(900,controlCancellation.Token);await WaitFrames(after,8);}
        async Task<Dictionary<string,object>> Send(string command,bool cleanup=false) {
            if(!cleanup)controlCancellation.Token.ThrowIfCancellationRequested();
            if(!cleanup&&ControlExpires!=DateTime.MinValue&&DateTime.UtcNow>ControlExpires.AddSeconds(-5))throw new OperationCanceledException("控制保护即将到期，已停止发送输入");
            await commandGate.WaitAsync();
            try {
                if(controller==null||controller.HasExited)throw new InvalidOperationException("控制流已关闭");
                controller.StandardInput.WriteLine(command);controller.StandardInput.Flush();
                var line=await Bounded(controller.StandardOutput.ReadLineAsync(),12000,"控制请求");
                if(line==null)throw new InvalidOperationException("眼镜控制流已结束");
                var answer=json.Deserialize<Dictionary<string,object>>(line);Log("controller",new{command=command,response=answer});
                if(!True(answer,"ok"))throw new InvalidOperationException("控制请求未被接受，未自动重发");return answer;
            }finally{commandGate.Release();}
        }
        public async Task StartControlAsync() {
            await lifecycle.WaitAsync();
            Exception failure=null;
            try{await StartControlCore();}catch(Exception error){failure=error;}
            try{if(failure!=null){await StopInternal();throw failure;}}finally{lifecycle.Release();}
        }
        async Task StartControlCore() {
                if(Controlling)return;if(!Connected)throw new InvalidOperationException("请先连接眼镜");RequireFresh();
                if(leaseRun!=null){await StopInternal();if(leaseRun!=null)throw new InvalidOperationException("上次控制恢复仍待核对");}
                stopping=false;controlCancellation.Dispose();controlCancellation=new CancellationTokenSource();
                leaseRun="pc-control-"+Guid.NewGuid().ToString("N");ControlExpires=DateTime.UtcNow.AddSeconds(300);
                Say("正在建立限时控制保护…");
                var lease=await RunScript("StartLease","-RunId",leaseRun);
                if(!True(lease,"Active"))throw new InvalidOperationException("未能建立控制保护");
                controller=new Process{StartInfo=StartInfo(powershell,OperationCommand("Controller"))};
                controller.ErrorDataReceived+=(s,e)=>{if(e.Data!=null)Log("controller_error",e.Data);};controller.Start();controller.BeginErrorReadLine();
                var first=await Bounded(controller.StandardOutput.ReadLineAsync(),20000,"启动控制");
                var ready=json.Deserialize<Dictionary<string,object>>(first??"{}");Log("controller_start",ready);
                if(!True(ready,"ok")||!ready.ContainsKey("state")||(string)ready["state"]!="connected")throw new InvalidOperationException("控制连接未完成");
                Controlling=true;pitch=.1f;yaw=-.23f;
                await Send("presence on");await Send("track-position");await Send("look-absolute 0.1 -0.23 0");await Send("hand-frustum ignore");await Send("hand-look 0 0.21 0");await Send("hand on");
                await RunScript("FocusApp");await Send("move 0 0 0.7");
                await SettleView(FrameSequence);pointerMap=null;
                Say("控制已开启，正在校准鼠标…");await CalibrateCore();
        }
        static string Position(double x,double y){if(x<-.85||x>.85||y<.5||y>1.97)throw new InvalidOperationException("该位置超出可点按范围，请先调整视角");return "hand-position "+x.ToString("F5",CultureInfo.InvariantCulture)+" "+y.ToString("F5",CultureInfo.InvariantCulture)+" -0.3";}
        async Task<PointerCandidate> Probe(double x,double y,PointF? expected) {
            RequireFresh();await Send("hand off");long sequence=FrameSequence;await WaitFrames(sequence,4);
            using(var before=Snapshot()) {
                await Send(Position(x,y));await Send("hand on");sequence=FrameSequence;
                await Task.Delay(450,controlCancellation.Token);await WaitFrames(sequence,4);
                for(int attempt=0;attempt<3;attempt++) {
                    using(var current=Snapshot()) {
                        var found=await Task.Run(()=>PointerLocator.Find(current,before,expected,expected.HasValue?130:1800));
                        if(found!=null){Log("pointer",new{handX=x,handY=y,x=found.Point.X,y=found.Point.Y,score=found.Score,change=found.Change});return found;}
                    }
                    await Task.Delay(400,controlCancellation.Token);
                }
            }
            throw new InvalidOperationException("未能从新画面确认眼镜准星，点按未发送；可调整视角后重新校准");
        }
        async Task CalibrateCore() {
            if(!Controlling)throw new InvalidOperationException("请先开始控制");pointerMap=null;
            Say("校准鼠标 1 / 3…");var first=await Probe(0,1.5,null);
            Say("校准鼠标 2 / 3…");var horizontal=await Probe(.2,1.5,null);
            Say("校准鼠标 3 / 3…");var vertical=await Probe(0,1.67,null);
            pointerMap=PointerMap.FromProbes(first.Point,horizontal.Point,vertical.Point,0,1.5);
            Log("calibration",pointerMap);Say("鼠标已校准：单击实时画面点按，右键拖动调整视角");
        }
        public async Task CalibrateAsync(){await lifecycle.WaitAsync();try{await CalibrateCore();}finally{lifecycle.Release();}}
        public async Task ClickAsync(PointF target) {
            await lifecycle.WaitAsync();
            try {
                if(!Controlling||stopping)throw new InvalidOperationException("请先开始控制");RequireFresh();if(pointerMap==null)await CalibrateCore();
                var hand=pointerMap.Aim(target);PointerCandidate observed=null;double error=double.PositiveInfinity;
                Say("正在定位眼镜准星…");
                for(int attempt=0;attempt<3;attempt++){
                    observed=await Probe(hand.X,hand.Y,target);
                    double dx=target.X-observed.Point.X,dy=target.Y-observed.Point.Y;error=Math.Sqrt(dx*dx+dy*dy);
                    if(error<=9)break;var delta=pointerMap.Delta(dx,dy);hand=new PointF(hand.X+delta.X,hand.Y+delta.Y);
                }
                if(error>9)throw new InvalidOperationException("准星尚未对准目标，点按未发送；请重新校准");
                RequireFresh();await Send("tap");Log("click_issued_once",new{x=target.X,y=target.Y,pointer=observed.Point,errorPixels=error});await SettleView(FrameSequence);Say("已发送一次点按，请核对眼镜画面的变化");
            }finally{lifecycle.Release();}
        }
        public async Task HomeAsync(){await lifecycle.WaitAsync();try{if(!Controlling)throw new InvalidOperationException("请先开始控制");RequireFresh();await Send("home");pointerMap=null;await SettleView(FrameSequence);Say("已发送开始菜单手势");}finally{lifecycle.Release();}}
        public async Task FocusAppAsync(){await lifecycle.WaitAsync();try{await RunScript("FocusApp");if(Controlling){await Send("move 0 0 0.7");await SettleView(FrameSequence);}pointerMap=null;Say("已请求打开稻视界，请查看实时画面");}finally{lifecycle.Release();}}
        public async Task LookAsync(float deltaPitch,float deltaYaw){await lifecycle.WaitAsync();try{if(!Controlling)throw new InvalidOperationException("请先开始控制");RequireFresh();pitch=Math.Max(-.9f,Math.Min(.9f,pitch+deltaPitch));yaw=Math.Max(-1.4f,Math.Min(1.4f,yaw+deltaYaw));await Send("look-absolute "+pitch.ToString("F4",CultureInfo.InvariantCulture)+" "+yaw.ToString("F4",CultureInfo.InvariantCulture)+" 0");pointerMap=null;await SettleView(FrameSequence);Say("视角已调整，下次点按时自动校准");}finally{lifecycle.Release();}}
        public async Task MoveAsync(float distance){await lifecycle.WaitAsync();try{if(!Controlling)throw new InvalidOperationException("请先开始控制");RequireFresh();await Send("move 0 0 "+distance.ToString("F3",CultureInfo.InvariantCulture));pointerMap=null;await SettleView(FrameSequence);Say("观看距离已调整，下次点按时自动校准");}finally{lifecycle.Release();}}
        public async Task StopControlAsync(){stopping=true;controlCancellation.Cancel();await lifecycle.WaitAsync();try{await StopInternal();}finally{lifecycle.Release();}}
        async Task StopInternal() {
            Controlling=false;pointerMap=null;
            if(controller!=null){
                try{if(!controller.HasExited){try{await Send("hand off",true);}catch{}var closed=await Send("exit",true);Log("stream_closed",closed);controller.StandardInput.Close();if(!controller.WaitForExit(5000))KillOwn(controller);}}catch(Exception e){Log("controller_cleanup",e.GetType().Name);KillOwn(controller);}finally{controller.Dispose();controller=null;}
            }
            if(leaseRun!=null){
                Say("正在恢复眼镜正常控制…");
                try{var result=await RunScript("StopLease","-RunId",leaseRun);if(!True(result,"Restored"))throw new InvalidOperationException("恢复未确认");Log("restored",new{run=leaseRun,result=result});leaseRun=null;Say("已停止控制，眼镜已恢复正常模式");}
                catch{Say("恢复结果仍待核对；设备端保护最晚于 "+ControlExpires.ToLocalTime().ToString("HH:mm:ss")+" 到期");throw;}
            }
        }
        public async Task DisconnectAsync(){await StopControlAsync();StopVideo();Connected=false;Say("已断开，后台 USB 连接仍保留");}
        void StopVideo(){videoStopping=true;KillOwn(video);KillOwn(decoder);if(video!=null){video.Dispose();video=null;}if(decoder!=null){decoder.Dispose();decoder=null;}lock(frameLock){if(frame!=null){frame.Dispose();frame=null;}frameAt=DateTime.MinValue;}}
        static void KillOwn(Process process){try{if(process!=null&&!process.HasExited){process.Kill();process.WaitForExit(2000);}}catch{}}
        public void Dispose(){StopVideo();KillOwn(controller);if(controller!=null)controller.Dispose();lock(frameLock){if(frame!=null)frame.Dispose();frame=null;}}
    }
}
