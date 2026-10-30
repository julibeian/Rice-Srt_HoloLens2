using System;
using System.Collections.Generic;
using System.Collections;
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
        readonly object frameLock=new object();
        readonly SessionJournal journal;
        readonly SemaphoreSlim commandGate=new SemaphoreSlim(1,1),lifecycle=new SemaphoreSlim(1,1);
        Process video,decoder,controller,controllerAdapter;
        bool controllerOutcomeUnknown;
        VideoFrameStore frames;
        long frameSequence;
        int videoGeneration;
        long videoStartedTicks;
        volatile bool videoEnded;
        readonly CancellationTokenSource sessionCancellation=new CancellationTokenSource();
        Task monitor;
        VideoProfile profile=VideoProfile.Interactive;
        string videoState="未连接";
        string leaseRun;
        long controlDeadlineTicks;
        CancellationTokenSource controlCancellation=new CancellationTokenSource();
        volatile bool videoStopping,stopping;
        PointF? lastPointer;
        PointerMap pointerMap;
        readonly List<ApplicationIdentity> applications=new List<ApplicationIdentity>();
        ApplicationIdentity pendingApplication;
        string pendingActivationId;
        float pitch=.1f,yaw=-.23f;
        public bool Connected {get;private set;}
        public bool Controlling {get;private set;}
        public string DeviceName {get;private set;}
        public DateTime ControlExpires {get;private set;}
        public double ControlRemainingSeconds {get{return Math.Max(0,(controlDeadlineTicks-Stopwatch.GetTimestamp())/(double)Stopwatch.Frequency);}}
        public string LastNotice {get;private set;}
        public long FrameSequence {get{return Interlocked.Read(ref frameSequence);}}
        public double FrameAge {get{lock(frameLock)return frames==null?double.PositiveInfinity:frames.AgeSeconds;}}
        public string VideoState {get{return videoState;}}
        public VideoProfile Profile {get{return profile;}}
        public int VideoGeneration {get{return Volatile.Read(ref videoGeneration);}}
        public bool Calibrated {get{return pointerMap!=null;}}
        public IList<ApplicationIdentity> Applications {get{return applications.AsReadOnly();}}
        public bool HasPendingActivation {get{return pendingApplication!=null;}}
        public event Action<string> Notice;
        public event Action FrameAvailable;
        public DeviceSession(string workspace) {
            Workspace=Path.GetFullPath(workspace);powershell=Path.Combine(Workspace,"runtime\\powershell\\pwsh.exe");
            var runtime=json.Deserialize<Dictionary<string,object>>(File.ReadAllText(Path.Combine(Workspace,"apps/pc-control\\dist\\runtime.json")));
            ffmpeg=(string)runtime["Ffmpeg"];
            LogDirectory=Path.Combine(Workspace,"apps/pc-control\\.state\\sessions",DateTime.Now.ToString("yyyyMMdd-HHmmss")+"-"+Guid.NewGuid().ToString("N").Substring(0,6));
            Directory.CreateDirectory(LogDirectory);
            journal=new SessionJournal(Path.Combine(LogDirectory,"events.jsonl"));
        }
        public static string Quote(string value) {
            var result=new StringBuilder("\"");int slashes=0;
            foreach(char c in value){if(c=='\\'){slashes++;continue;}if(c=='\"'){result.Append('\\',slashes*2+1).Append(c);slashes=0;continue;}result.Append('\\',slashes).Append(c);slashes=0;}
            return result.Append('\\',slashes*2).Append('"').ToString();
        }
        ProcessStartInfo StartInfo(string program,string arguments) {
            return new ProcessStartInfo(program,arguments){WorkingDirectory=Workspace,UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true,RedirectStandardError=true,RedirectStandardInput=true,StandardOutputEncoding=Encoding.UTF8,StandardErrorEncoding=Encoding.UTF8};
        }
        public void Log(string type,object value) {journal.Log(type,value);}
        public Task FlushLogsAsync(){return journal.FlushAsync();}
        void Say(string message){LastNotice=message;Log("notice",message);var handler=Notice;if(handler!=null)handler(message);}
        static async Task<T> Bounded<T>(Task<T> work,int milliseconds,string label) {
            if(await Task.WhenAny(work,Task.Delay(milliseconds))!=work)throw new TimeoutException(label+"超时；先核对本次结果，再继续操作");return await work;
        }
        string OperationCommand(string operation){return "-NoLogo -NoProfile -NonInteractive -File "+Quote(Path.Combine(Workspace,"apps/pc-control\\ops\\Invoke-Operation.ps1"))+" -Operation "+Quote(operation);}
        async Task<Dictionary<string,object>> RunScript(string operation,params string[] arguments) {
            var command=OperationCommand(operation);
            foreach(var argument in arguments)command+=" "+Quote(argument);
            OperationOutput result;
            try{result=await OperationProcess.RunAsync(StartInfo(powershell,command),45000).ConfigureAwait(false);}
            catch(TimeoutException timeout){Log("script_timeout",new{operation=operation,arguments=arguments,processId=timeout.Data["ProcessId"],exitConfirmed=timeout.Data["ProcessExitConfirmed"],replayed=false});throw;}
            Log("script",new{operation=operation,arguments=arguments,exit=result.ExitCode,output=result.Output,error=result.Error});
            if(result.ExitCode!=0)throw new InvalidOperationException("设备操作未完成，详情已保存在运行记录中");
            return json.Deserialize<Dictionary<string,object>>(result.Output.Trim().TrimStart('\uFEFF'));
        }
        static bool True(Dictionary<string,object> data,string name){return data.ContainsKey(name)&&data[name] is bool&&(bool)data[name];}
        public async Task ConnectAsync() {
            await lifecycle.WaitAsync().ConfigureAwait(false);
            try{if(Controlling)throw new InvalidOperationException("请先停止当前控制");await ConnectCore().ConfigureAwait(false);}finally{lifecycle.Release();}
        }
        async Task ConnectCore() {
            Say("正在核对原眼镜与保存的认证…");
            var status=await RunScript("BridgeStatus");
            if(!status.ContainsKey("State")||(string)status["State"]!="connected")throw new InvalidOperationException("正在等待原眼镜连接，后台会继续自动发现");
            var portal=await RunScript("Portal");
            if(!True(portal,"SshIdentityVerified")||!True(portal,"PortalAuthenticated")||!True(portal,"PortalCertificatePinned"))throw new InvalidOperationException("原眼镜身份或保存的认证未通过核对");
            DeviceName=(string)portal["Device"];Connected=true;
            StartVideo();Say("已连接 "+DeviceName+"，正在接收真实全息画面…");
            if(monitor==null)monitor=Task.Run(()=>MonitorVideo());
            try{await LoadApplicationsCore();}catch(Exception error){Log("application_inventory_error",error.Message);Say("已连接，应用清单暂不可用；请刷新应用列表");}
        }
        async Task LoadApplicationsCore(){
            if(!Connected)throw new InvalidOperationException("请先连接眼镜");
            var result=await RunScript("Applications","-RunId","apps-"+Guid.NewGuid().ToString("N"));
            if(!True(result,"ok")||!True(result,"InventoryVerified")||!result.ContainsKey("Applications"))throw new InvalidOperationException("应用清单读取失败，不能用空列表表示未安装应用");
            var next=new List<ApplicationIdentity>();var rows=result["Applications"] as IEnumerable;
            if(rows==null)throw new InvalidOperationException("应用清单格式未通过核对");
            foreach(var item in rows){var row=item as Dictionary<string,object>;if(row==null)throw new InvalidOperationException("应用条目格式未通过核对");var identity=ApplicationIdentity.FromInventory(row);if(next.Exists(x=>x.SamePackage(identity)))throw new InvalidOperationException("应用清单出现重复身份");next.Add(identity);}
            applications.Clear();applications.AddRange(next);
            Say("已读取 "+applications.Count+" 个应用入口"+(True(result,"InventoryComplete")?"":"；部分条目读取不完整，详情见运行记录"));
        }
        public async Task RefreshApplicationsAsync(){await lifecycle.WaitAsync();try{await LoadApplicationsCore();}finally{lifecycle.Release();}}
        async Task ObserveActivationCore(bool queryOnly=false){
            var result=await RunScript(queryOnly?"ApplicationStatus":"LaunchApplication","-RunId",pendingActivationId,"-Aumid",pendingApplication.Aumid,"-PackageFullName",pendingApplication.PackageFullName);
            string state=result.ContainsKey("State")?(string)result["State"]:"outcome_unknown";
            if(state=="outcome_unknown")throw new InvalidOperationException("上次应用启动结果仍待核对；再次点击将查询原操作");
            var target=pendingApplication;pendingApplication=null;pendingActivationId=null;pointerMap=null;lastPointer=null;
            if(!True(result,"ActivationAccepted"))throw new InvalidOperationException("应用启动未被接受，请刷新应用列表并查看运行记录");
            if(Controlling)await SettleView(FrameSequence);
            Say("已请求打开 "+target.DisplayName+"，请核对当前画面");
        }
        public async Task LaunchApplicationAsync(ApplicationIdentity target){
            await lifecycle.WaitAsync();
            try{
                if(!Connected)throw new InvalidOperationException("请先连接眼镜");
                if(pendingApplication!=null)throw new InvalidOperationException("上次启动结果待核对，请先核对原操作");
                if(target==null||!applications.Exists(x=>x.SamePackage(target)))throw new InvalidOperationException("请从当前已核对的应用列表中选择目标");
                pointerMap=null;pendingApplication=target;pendingActivationId="launch-"+Guid.NewGuid().ToString("N");
                await ObserveActivationCore();
            }finally{lifecycle.Release();}
        }
        public async Task CheckPendingActivationAsync(){await lifecycle.WaitAsync();try{if(pendingApplication==null){Say("没有待核对的启动操作");return;}await ObserveActivationCore(true);}finally{lifecycle.Release();}}
        void StartVideo() {
            StopVideo();videoStopping=false;videoEnded=false;videoState="等待首帧";videoStartedTicks=Stopwatch.GetTimestamp();
            var store=new VideoFrameStore(profile.Width,profile.Height,Interlocked.Increment(ref videoGeneration));
            lock(frameLock)frames=store;
            Log("video_start",new{generation=store.Generation,source="official-holographic",endpoint=profile.Endpoint,width=profile.Width,height=profile.Height,format="BGRA",fpsLimit=0,audio=false,pv=false});
            decoder=new Process{StartInfo=StartInfo(ffmpeg,profile.DecoderArguments)};
            decoder.ErrorDataReceived+=(s,e)=>{if(e.Data!=null)Log("decoder",e.Data);};decoder.Start();decoder.BeginErrorReadLine();
            video=new Process{StartInfo=StartInfo(powershell,OperationCommand("Video")+" -VideoProfile "+(profile==VideoProfile.Detail?"Detail":"Interactive"))};
            video.ErrorDataReceived+=(s,e)=>{if(e.Data!=null)Log("video",e.Data);};video.Start();video.StandardInput.Close();video.BeginErrorReadLine();
            var source=video;var destination=decoder;
            // Framework anonymous pipes use blocking handles. Dedicated workers
            // keep their reads from starving continuations, timers and input.
            Task.Factory.StartNew(()=>{try{source.StandardOutput.BaseStream.CopyTo(destination.StandardInput.BaseStream,65536);}catch(Exception e){if(IsCurrent(store))Log("video_pipe",e.GetType().Name);}finally{try{destination.StandardInput.Close();}catch{}}},CancellationToken.None,TaskCreationOptions.LongRunning,TaskScheduler.Default);
            Task.Factory.StartNew(()=>ReadFrames(destination,store),CancellationToken.None,TaskCreationOptions.LongRunning,TaskScheduler.Default);
        }
        bool IsCurrent(VideoFrameStore store){lock(frameLock)return !videoStopping&&frames==store;}
        void ReadFrames(Process process,VideoFrameStore store) {
            long first=Stopwatch.GetTimestamp();int dropped=0;
            try {
                var input=process.StandardOutput.BaseStream;byte[] discard=null;bool firstFrame=true;
                while(IsCurrent(store)){
                    var next=store.Rent();
                    if(next==null){if(discard==null)discard=new byte[checked(store.Width*store.Height*4)];if(!VideoFrameStore.ReadFrame(input,discard))break;dropped++;continue;}
                    bool published=false;
                    try{
                        if(!VideoFrameStore.ReadFrame(input,next.Pixels))break;
                        lock(frameLock){if(frames!=store)break;store.Publish(next,Interlocked.Increment(ref frameSequence),Stopwatch.GetTimestamp());published=true;videoState="实时";}
                        if(firstFrame){firstFrame=false;Log("video_first_frame",new{generation=store.Generation,elapsedMs=(Stopwatch.GetTimestamp()-first)*1000.0/Stopwatch.Frequency});}
                        var available=FrameAvailable;if(available!=null)try{available();}catch(Exception e){Log("frame_listener",e.GetType().Name);}
                    }finally{if(!published)next.Dispose();}
                }
            }catch(Exception e){if(IsCurrent(store))Log("frame_reader",e.GetType().Name);}
            finally{if(IsCurrent(store)){videoEnded=true;videoState="画面已结束";Log("video_ended",new{generation=store.Generation,droppedFrames=dropped});}}
        }
        public VideoFrame AcquireFrame(long after=-1){lock(frameLock)return frames==null?null:frames.AcquireLatest(after);}
        public Bitmap Snapshot(){using(var frame=AcquireFrame()){if(frame==null)return null;lock(frame.DrawingSync)return new Bitmap(frame.Image);}}
        public async Task<string> SaveHighFrameAsync(){
            await lifecycle.WaitAsync().ConfigureAwait(false);
            try{
                if(!Connected)throw new InvalidOperationException("请先连接眼镜");RequireFresh();
                string path=Path.Combine(LogDirectory,"high-"+DateTime.Now.ToString("HHmmss-fff")+"-"+Guid.NewGuid().ToString("N").Substring(0,8)+".png");
                var previous=profile;bool switched=previous!=VideoProfile.Detail;Exception captureFailure=null;
                // This device ends its old MRC stream when another profile is
                // opened. Own the transition instead of racing two requests.
                try{
                    if(switched){Say("正在临时切换高清画面，抓帧后恢复交互画面…");long after=FrameSequence;profile=VideoProfile.Detail;StartVideo();await WaitVideoFrame(after,VideoGeneration).ConfigureAwait(false);}
                    using(var frame=AcquireFrame()){
                        if(frame==null||frame.Width!=1280||frame.Height!=720)throw new InvalidOperationException("尚无新的高清画面");RequireFresh();
                        await Task.Run(()=>{Bitmap copy;lock(frame.DrawingSync)copy=new Bitmap(frame.Image);using(copy)copy.Save(path,System.Drawing.Imaging.ImageFormat.Png);}).ConfigureAwait(false);
                    }
                    Log("high_snapshot",new{path=path,source="live_high.mp4",audio=false,pv=false,temporaryProfileSwitch=switched});
                }catch(Exception error){captureFailure=error;}
                if(switched&&Connected&&!sessionCancellation.IsCancellationRequested){
                        Say("正在恢复交互画面；首次点按需重新校准…");long after=FrameSequence;profile=previous;StartVideo();
                        try{await WaitVideoFrame(after,VideoGeneration).ConfigureAwait(false);Log("snapshot_video_restored",new{profile=profile.Name,generation=VideoGeneration,frameAge=FrameAge});}
                        catch(Exception error){Log("snapshot_video_restore_pending",new{path=path,error=error.Message});throw new InvalidOperationException("交互画面恢复待核对，已保留抓帧记录；点按保持暂停",error);}
                }
                if(captureFailure!=null)System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(captureFailure).Throw();
                return path;
            }finally{lifecycle.Release();}
        }
        async Task WaitVideoFrame(long after,int generation){
            var watch=Stopwatch.StartNew();
            while(Connected&&generation==VideoGeneration&&(FrameSequence<=after||FrameAge>2.5)){
                sessionCancellation.Token.ThrowIfCancellationRequested();
                if(videoEnded||watch.Elapsed.TotalSeconds>15)throw new TimeoutException("等待新视频首帧超时");
                await Task.Delay(20,sessionCancellation.Token).ConfigureAwait(false);
            }
            if(!Connected||generation!=VideoGeneration)throw new InvalidOperationException("视频会话已改变");RequireFresh();
        }
        public async Task SetVideoProfileAsync(bool detail){await lifecycle.WaitAsync().ConfigureAwait(false);try{var next=detail?VideoProfile.Detail:VideoProfile.Interactive;if(profile==next)return;profile=next;pointerMap=null;lastPointer=null;if(Connected)StartVideo();Say(detail?"已切换高清画面；首次点按需重新校准":"已切换交互画面；首次点按需重新校准");}finally{lifecycle.Release();}}
        void RequireFresh(){if(FrameAge>2.5||FrameSequence==0)throw new InvalidOperationException("当前画面已停滞，点按未发送；请先恢复实时画面");}
        async Task WaitFrames(long after,int count,int timeoutSeconds=6) {
            var watch=Stopwatch.StartNew();
            while(FrameSequence<after+count||FrameAge>2.5){controlCancellation.Token.ThrowIfCancellationRequested();if(watch.Elapsed.TotalSeconds>timeoutSeconds)throw new TimeoutException("等待新的眼镜画面超时，点按未发送");await Task.Delay(10).ConfigureAwait(false);}
            RequireFresh();
        }
        async Task SettleView(long after){await WaitFrames(after,1).ConfigureAwait(false);}
        async Task<Dictionary<string,object>> Send(string command,bool cleanup=false) {
            if(!cleanup)controlCancellation.Token.ThrowIfCancellationRequested();
            if(!cleanup&&controlDeadlineTicks!=0&&ControlRemainingSeconds<5)throw new OperationCanceledException("控制保护即将到期，已停止发送输入");
            await commandGate.WaitAsync();
            try {
                if(controller==null||controller.HasExited)throw new InvalidOperationException("控制流已关闭");
                controller.StandardInput.WriteLine(command);controller.StandardInput.Flush();
                var line=await Bounded(controller.StandardOutput.ReadLineAsync(),12000,"控制请求");
                if(line==null)throw new InvalidOperationException("眼镜控制流已结束");
                var answer=json.Deserialize<Dictionary<string,object>>(line);Log("controller",new{command=command,response=answer});
                if(!True(answer,"ok"))throw new InvalidOperationException("控制请求未被接受，未自动重发");return answer;
            }catch(TimeoutException){
                controllerOutcomeUnknown=true;stopping=true;controlCancellation.Cancel();
                // Retire this protocol stream: a late reply cannot be matched
                // to the next command. Exit is sent once, never another tap.
                try{controller.StandardInput.WriteLine("exit");controller.StandardInput.Flush();}catch{}
                Log("controller_outcome_unknown",new{command=command,replayed=false});throw;
            }finally{commandGate.Release();}
        }
        public async Task StartControlAsync() {
            await lifecycle.WaitAsync();
            Exception failure=null;
            try{await StartControlCore();}catch(Exception error){failure=error;}
            try{if(failure!=null){await StopInternal();throw failure;}}finally{lifecycle.Release();}
        }
        async Task StartControlCore() {
                if(Controlling)return;if(!Connected)throw new InvalidOperationException("请先连接眼镜");
                if(leaseRun!=null){await StopInternal();if(leaseRun!=null)throw new InvalidOperationException("上次控制恢复仍待核对");}
                stopping=false;controlCancellation.Dispose();controlCancellation=new CancellationTokenSource();
                leaseRun="apps/pc-control-"+Guid.NewGuid().ToString("N");ControlExpires=DateTime.UtcNow.AddSeconds(300);controlDeadlineTicks=Stopwatch.GetTimestamp()+300L*Stopwatch.Frequency;
                Say("正在建立限时控制保护…");
                var lease=await RunScript("StartLease","-RunId",leaseRun);
                if(!True(lease,"Active"))throw new InvalidOperationException("未能建立控制保护");
                controller=new Process{StartInfo=StartInfo(powershell,OperationCommand("Controller"))};
                controller.ErrorDataReceived+=(s,e)=>{if(e.Data!=null)Log("controller_error",e.Data);};controller.Start();controller.BeginErrorReadLine();
                var first=await Bounded(controller.StandardOutput.ReadLineAsync(),20000,"启动控制");
                var ready=json.Deserialize<Dictionary<string,object>>(first??"{}");Log("controller_start",ready);
                if(!True(ready,"ok")||!ready.ContainsKey("state")||(string)ready["state"]!="connected")throw new InvalidOperationException("控制连接未完成");
                controllerOutcomeUnknown=false;
                if(ready.ContainsKey("AdapterProcessId")){
                    var adapter=Process.GetProcessById(Convert.ToInt32(ready["AdapterProcessId"]));
                    string expected=Path.Combine(Workspace,"apps/holographic-control\\.state\\desktop-x86\\PerceptionControl.exe");
                    if(!string.Equals(adapter.MainModule.FileName,expected,StringComparison.OrdinalIgnoreCase)){adapter.Dispose();throw new InvalidOperationException("控制子进程身份未通过核对");}
                    controllerAdapter=adapter;
                }
                Controlling=true;pitch=.1f;yaw=-.23f;
                // Presence is the only wake action before obtaining a current
                // image. It is always covered by the named device-side lease.
                await Send("presence on");
                if(FrameAge>2.5||videoEnded){long sequence=FrameSequence;StartVideo();await WaitFrames(sequence,1,15);}
                RequireFresh();await Send("track-position");await Send("look-absolute 0.1 -0.23 0");await Send("hand-frustum ignore");await Send("hand-look 0 0.21 0");await Send("hand on");
                await Send("move 0 0 0.7");
                await SettleView(FrameSequence);pointerMap=null;
                Say("控制已开启；可打开开始菜单或选择应用，首次点按时校准鼠标");
        }
        static string Position(double x,double y){if(x<-.85||x>.85||y<.5||y>1.97)throw new InvalidOperationException("该位置超出可点按范围，请先调整视角");return "hand-position "+x.ToString("F5",CultureInfo.InvariantCulture)+" "+y.ToString("F5",CultureInfo.InvariantCulture)+" -0.3";}
        async Task<PointerCandidate> Probe(double x,double y,PointF? expected) {
            RequireFresh();int generation=VideoGeneration;double scale=profile.Width/1280.0;
            // Repeated targets need a genuine pointer-free baseline. For a new
            // target, movement itself supplies the frame difference.
            bool hide=!lastPointer.HasValue||!expected.HasValue||Distance(lastPointer.Value,expected.Value)<24*scale;
            if(hide){
                await Send("hand off");long sequence=FrameSequence;var absent=Stopwatch.StartNew();
                do{
                    await WaitFrames(sequence,1);using(var candidate=AcquireFrame()){
                        if(candidate==null)continue;sequence=candidate.Sequence;
                        if(lastPointer.HasValue){if(!PointerLocator.HasRing(candidate,lastPointer.Value))break;}
                        // First calibration has no trusted previous pointer.
                        // Allow the device encoder to drain this one baseline;
                        // steady clicks use observed disappearance instead.
                        else if(absent.ElapsedMilliseconds>=1200)break;
                    }
                    if(absent.ElapsedMilliseconds>2200)throw new InvalidOperationException("未确认旧准星已移开，点按未发送");
                }while(true);
            }
            using(var before=AcquireFrame()) {
                if(before==null)throw new InvalidOperationException("没有可用于定位的新画面");
                long sequence=before.Sequence;await Send(Position(x,y));if(hide)await Send("hand on");
                var watch=Stopwatch.StartNew();bool nudged=false;PointF? stablePoint=null;int stableFrames=0;
                while(watch.ElapsedMilliseconds<2500){
                    await WaitFrames(sequence,1);
                    if(VideoGeneration!=generation)throw new InvalidOperationException("视频来源已变化，请重新校准");
                    using(var current=AcquireFrame(sequence)) {
                        if(current==null)continue;sequence=current.Sequence;
                        var found=await Task.Run(()=>PointerLocator.Find(current,before,expected,expected.HasValue?(int)Math.Ceiling(18*scale):1800)).ConfigureAwait(false);
                        if(found!=null){
                            stableFrames=stablePoint.HasValue&&Distance(stablePoint.Value,found.Point)<=3*scale?stableFrames+1:1;stablePoint=found.Point;
                            if(stableFrames>=2){found.HandX=x;found.HandY=y;lastPointer=found.Point;Log("pointer",new{handX=x,handY=y,x=found.Point.X,y=found.Point.Y,score=found.Score,change=found.Change,sequence=sequence,stableFrames=stableFrames,hoverNudged=nudged,elapsedMs=watch.Elapsed.TotalMilliseconds});return found;}
                        }else{stablePoint=null;stableFrames=0;}
                    }
                    // A white glyph can cover the ring. Move the hover a few
                    // pixels within the existing hit tolerance, then require a
                    // newly visible ring. No selection gesture is retried.
                    if(!nudged&&stableFrames==0&&expected.HasValue&&pointerMap!=null&&watch.ElapsedMilliseconds>=500){
                        var offset=pointerMap.Delta(0,7*scale);x+=offset.X;y+=offset.Y;await Send(Position(x,y));nudged=true;
                        Log("pointer_hover_nudge",new{pixels=7*scale,tapSent=false});
                    }
                }
                SavePointerDiagnostic(before,"baseline");using(var current=AcquireFrame())if(current!=null)SavePointerDiagnostic(current,"unconfirmed");
            }
            throw new InvalidOperationException("未能从新画面确认眼镜准星，点按未发送；可调整视角后重新校准");
        }
        static double Distance(PointF first,PointF second){return Math.Sqrt(Math.Pow(first.X-second.X,2)+Math.Pow(first.Y-second.Y,2));}
        void SavePointerDiagnostic(VideoFrame frame,string kind){var held=frame.Retain();Task.Run(()=>{using(held){try{Bitmap copy;lock(held.DrawingSync)copy=new Bitmap(held.Image);using(copy)copy.Save(Path.Combine(LogDirectory,"pointer-"+held.Sequence+"-"+kind+".png"));}catch(Exception e){Log("evidence_error",e.GetType().Name);}}});}
        async Task CalibrateCore() {
            if(!Controlling)throw new InvalidOperationException("请先开始控制");pointerMap=null;
            Say("校准鼠标 1 / 3…");var first=await Probe(-.1,1.62,null);
            Say("校准鼠标 2 / 3…");var horizontal=await Probe(-.02,1.62,null);
            Say("校准鼠标 3 / 3…");var vertical=await Probe(-.1,1.68,null);
            pointerMap=PointerMap.FromProbes(first.Point,horizontal.Point,vertical.Point,-.1,1.62,.08,.06);
            Log("calibration",pointerMap);Say("鼠标已校准：单击实时画面点按，右键拖动调整视角");
        }
        public async Task CalibrateAsync(){await lifecycle.WaitAsync();try{await CalibrateCore();}finally{lifecycle.Release();}}
        public async Task ClickAsync(PointF target) {
            await lifecycle.WaitAsync();
            try {
                var watch=Stopwatch.StartNew();bool initialCalibration=pointerMap==null;
                if(!Controlling||stopping)throw new InvalidOperationException("请先开始控制");RequireFresh();if(pointerMap==null)await CalibrateCore();
                if(target.X<0||target.Y<0||target.X>=profile.Width||target.Y>=profile.Height)throw new InvalidOperationException("目标不在当前画面内，点按未发送");
                var hand=pointerMap.Aim(target);PointerCandidate observed=null;double error=double.PositiveInfinity;
                Say("正在定位眼镜准星…");
                for(int attempt=0;attempt<3;attempt++){
                    observed=await Probe(hand.X,hand.Y,target);
                    double dx=target.X-observed.Point.X,dy=target.Y-observed.Point.Y;error=Math.Sqrt(dx*dx+dy*dy);
                    if(error<=9*profile.Width/1280.0)break;var delta=pointerMap.Delta(dx,dy);hand=new PointF((float)(observed.HandX+delta.X),(float)(observed.HandY+delta.Y));
                }
                if(error>9*profile.Width/1280.0){pointerMap=null;throw new InvalidOperationException("准星尚未对准目标，点按未发送；请重新校准");}
                RequireFresh();await Send("tap");double accepted=watch.Elapsed.TotalMilliseconds;
                Log("click_issued_once",new{x=target.X,y=target.Y,pointer=observed.Point,errorPixels=error,initialCalibration=initialCalibration,requestToAcceptedMs=accepted});
                await SettleView(FrameSequence);Log("click_timing",new{requestToAcceptedMs=accepted,requestToNextFrameMs=watch.Elapsed.TotalMilliseconds,initialCalibration=initialCalibration,visibleEffectVerified=false,clock="Stopwatch"});Say("已发送一次点按，请核对眼镜画面的变化");
            }finally{lifecycle.Release();}
        }
        public async Task HomeAsync(){await lifecycle.WaitAsync();try{if(!Controlling)throw new InvalidOperationException("请先开始控制");RequireFresh();await Send("home");pointerMap=null;await SettleView(FrameSequence);Say("已发送开始菜单手势");}finally{lifecycle.Release();}}
        public async Task LookAsync(float deltaPitch,float deltaYaw){await lifecycle.WaitAsync();try{if(!Controlling)throw new InvalidOperationException("请先开始控制");RequireFresh();pitch=Math.Max(-.9f,Math.Min(.9f,pitch+deltaPitch));yaw=Math.Max(-1.4f,Math.Min(1.4f,yaw+deltaYaw));await Send("look-absolute "+pitch.ToString("F4",CultureInfo.InvariantCulture)+" "+yaw.ToString("F4",CultureInfo.InvariantCulture)+" 0");pointerMap=null;await SettleView(FrameSequence);Say("视角已调整，下次点按时自动校准");}finally{lifecycle.Release();}}
        public async Task MoveAsync(float distance){await lifecycle.WaitAsync();try{if(!Controlling)throw new InvalidOperationException("请先开始控制");RequireFresh();await Send("move 0 0 "+distance.ToString("F3",CultureInfo.InvariantCulture));pointerMap=null;await SettleView(FrameSequence);Say("观看距离已调整，下次点按时自动校准");}finally{lifecycle.Release();}}
        public async Task StopControlAsync(){stopping=true;controlCancellation.Cancel();await lifecycle.WaitAsync();try{await StopInternal();}finally{lifecycle.Release();}}
        async Task StopInternal() {
            Controlling=false;pointerMap=null;
            if(controller!=null){
                try{if(!controller.HasExited){
                    if(!controllerOutcomeUnknown){try{await Send("hand off",true);}catch{}var closed=await Send("exit",true);if(!closed.ContainsKey("state")||(string)closed["state"]!="closed"||!closed.ContainsKey("httpStatus")||Convert.ToInt32(closed["httpStatus"])!=200)throw new InvalidOperationException("Own stream closure not confirmed");Log("stream_closed",closed);}
                    else Log("stream_close_unknown",new{replayed=false});
                    controller.StandardInput.Close();if(!controller.WaitForExit(5000))KillOwn(controller);
                }}catch(Exception e){Log("controller_cleanup",e.GetType().Name);KillOwn(controller);}finally{controller.Dispose();controller=null;KillOwn(controllerAdapter);if(controllerAdapter!=null){controllerAdapter.Dispose();controllerAdapter=null;}}
            }
            if(leaseRun!=null){
                Say("正在恢复眼镜正常控制…");
                try{var result=await RunScript("StopLease","-RunId",leaseRun);if(!True(result,"Restored"))throw new InvalidOperationException("恢复未确认");Log("restored",new{run=leaseRun,result=result});leaseRun=null;Say("已停止控制，眼镜已恢复正常模式");}
                catch{Say("恢复结果仍待核对；设备端保护最晚于 "+ControlExpires.ToLocalTime().ToString("HH:mm:ss")+" 到期");throw;}
            }
        }
        async Task MonitorVideo(){
            var clock=Stopwatch.StartNew();double lastPresence=0,nextCheck=5;int retries=0;
            try{while(!sessionCancellation.IsCancellationRequested){
                await Task.Delay(1000,sessionCancellation.Token).ConfigureAwait(false);
                if(!Connected)continue;
                if(Controlling&&(stopping||ControlRemainingSeconds<10)){try{await StopControlAsync().ConfigureAwait(false);}catch(Exception error){Log("automatic_stop_pending",error.Message);}continue;}
                if(!await lifecycle.WaitAsync(0).ConfigureAwait(false))continue;
                try{
                    if(!Connected)continue;
                    if(!videoEnded&&FrameAge<2.5){
                        retries=0;nextCheck=clock.Elapsed.TotalSeconds+3;
                        if(Controlling&&clock.Elapsed.TotalSeconds-lastPresence>=30){await Send("presence on").ConfigureAwait(false);lastPresence=clock.Elapsed.TotalSeconds;Log("presence_keepalive",new{lease=leaseRun,expires=ControlExpires});}
                        continue;
                    }
                    // Authentication + MP4 probing can take several seconds.
                    // Do not kill a healthy startup before it can yield a frame.
                    if(!videoEnded&&double.IsInfinity(FrameAge)&&(Stopwatch.GetTimestamp()-videoStartedTicks)/(double)Stopwatch.Frequency<15){videoState="等待首帧";continue;}
                    if(clock.Elapsed.TotalSeconds<nextCheck)continue;
                    videoState="画面停滞，核对设备状态";pointerMap=null;lastPointer=null;
                    var power=await RunScript("Power").ConfigureAwait(false);
                    if(!Connected||sessionCancellation.IsCancellationRequested)continue;
                    if(!True(power,"IdentityVerified"))throw new InvalidOperationException("电源观察的设备身份未通过核对");
                    bool powerKnown=True(power,"PowerStateKnown"),sleeping=powerKnown&&True(power,"LowPowerState");
                    nextCheck=clock.Elapsed.TotalSeconds+15;
                    Log("video_health",new{powerStateKnown=powerKnown,sleeping=powerKnown?(bool?)sleeping:null,retries=retries,controlling=Controlling});
                    if(powerKnown&&sleeping&&!Controlling){videoState="设备休眠；开始控制可尝试限时唤醒";continue;}
                    if(retries>=3){videoState="视频恢复未完成，请重新连接";continue;}
                    if(Controlling)await Send("presence on").ConfigureAwait(false);
                    retries++;videoState="正在恢复视频（"+retries+" / 3）";StartVideo();nextCheck=clock.Elapsed.TotalSeconds+Math.Min(15,3*retries);
                }catch(Exception error){videoState="视频恢复待核对";nextCheck=clock.Elapsed.TotalSeconds+15;Log("video_health_error",error.Message);}
                finally{lifecycle.Release();}
            }}catch(OperationCanceledException){}
        }
        public async Task DisconnectAsync(){await StopControlAsync();await lifecycle.WaitAsync().ConfigureAwait(false);try{Connected=false;StopVideo();Say("已断开，后台 USB 连接仍保留");}finally{lifecycle.Release();}}
        void StopVideo(){videoStopping=true;lock(frameLock){if(frames!=null){frames.Dispose();frames=null;}}pointerMap=null;lastPointer=null;KillOwn(video);KillOwn(decoder);if(video!=null){video.Dispose();video=null;}if(decoder!=null){decoder.Dispose();decoder=null;}videoState="画面已停止";}
        static void KillOwn(Process process){try{if(process!=null&&!process.HasExited){process.Kill();process.WaitForExit(2000);}}catch{}}
        public void Dispose(){sessionCancellation.Cancel();Connected=false;StopVideo();KillOwn(controller);KillOwn(controllerAdapter);if(controller!=null)controller.Dispose();if(controllerAdapter!=null)controllerAdapter.Dispose();journal.Dispose();}
    }
}
