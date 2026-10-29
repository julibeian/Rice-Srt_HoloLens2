// Explicit CLI exercise of the same backend used by the desktop window.
// It does not automate Windows UI, accept secrets or change pairing.
using System;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Diagnostics;
using System.Reflection;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using Rice.HoloLens.Control;
using ApplicationIdentity=Rice.HoloLens.Control.ApplicationIdentity;
class DeviceSmoke {
    static readonly JavaScriptSerializer Json=new JavaScriptSerializer();
    static void Emit(object value){Console.WriteLine(Json.Serialize(value));}
    static void Main(string[] args){bool owner;using(var mutex=new Mutex(true,"Local\\RiceHoloLensDesktopControl",out owner)){if(!owner)throw new Exception("Close the desktop controller before exercising its backend");Run(args[0]).GetAwaiter().GetResult();}}
    static async Task Run(string root){
        using(var session=new DeviceSession(root)){
            session.Notice+=message=>Emit(new{notice=message});
            try{
                await session.ConnectAsync();var deadline=DateTime.UtcNow.AddSeconds(20);while(session.FrameSequence==0&&DateTime.UtcNow<deadline)await Task.Delay(100);
                Emit(new{ready=session.Connected,frames=session.FrameSequence,age=session.FrameAge,log=session.LogDirectory});
                string line;int snapshot=0;
                while((line=Console.ReadLine())!=null){var words=line.Split(' ');try{
                    if(words[0]=="exit")break;
                    if(words[0]=="start")await session.StartControlAsync();
                    else if(words[0]=="stop")await session.StopControlAsync();
                    else if(words[0]=="calibrate")await session.CalibrateAsync();
                    else if(words[0]=="detail")await session.SetVideoProfileAsync(true);
                    else if(words[0]=="interactive")await session.SetVideoProfileAsync(false);
                    else if(words[0]=="high-snapshot")Emit(new{highFrame=await session.SaveHighFrameAsync()});
                    else if(words[0]=="pose"){
                        if(!session.Controlling)throw new Exception("An active named control lease is required");
                        var request=(Task<System.Collections.Generic.Dictionary<string,object>>)typeof(DeviceSession).GetMethod("Send",BindingFlags.Instance|BindingFlags.NonPublic).Invoke(session,new object[]{"pose",false});Emit(await request);
                    }
                    else if(words[0]=="apps"){await session.RefreshApplicationsAsync();foreach(var app in session.Applications)Emit(new{application=app.Aumid,package=app.PackageFullName,name=app.DisplayName});}
                    else if(words[0]=="open"&&words.Length==2){ApplicationIdentity target=null;foreach(var app in session.Applications)if(app.Aumid==words[1]){target=app;break;}await session.LaunchApplicationAsync(target);}
                    else if(words[0]=="check-launch")await session.CheckPendingActivationAsync();
                    else if(words[0]=="home")await session.HomeAsync();
                    else if(words[0]=="metrics")await Measure(session,words.Length>1?int.Parse(words[1]):10);
                    else if(words[0]=="timed-click")await TimedClick(session,new PointF(float.Parse(words[1],CultureInfo.InvariantCulture),float.Parse(words[2],CultureInfo.InvariantCulture)),++snapshot);
                    else if(words[0]=="click")await session.ClickAsync(new PointF(float.Parse(words[1],CultureInfo.InvariantCulture),float.Parse(words[2],CultureInfo.InvariantCulture)));
                    else if(words[0]=="look")await session.LookAsync(float.Parse(words[1],CultureInfo.InvariantCulture),float.Parse(words[2],CultureInfo.InvariantCulture));
                    else if(words[0]=="stale-check"){
                        var log=Path.Combine(session.LogDirectory,"events.jsonl");
                        await session.FlushLogsAsync();int before=CountClicks(log);
                        // Kill only this session's own decoder to exercise the
                        // real stale-frame gate without sending a device click.
                        var gate=(SemaphoreSlim)typeof(DeviceSession).GetField("lifecycle",BindingFlags.Instance|BindingFlags.NonPublic).GetValue(session);
                        // Defer automatic recovery until the real stale-input
                        // call is queued, so a successfully healed view cannot
                        // accidentally turn this rejection test into a click.
                        await gate.WaitAsync();Task click=null;
                        try{var decoder=(Process)typeof(DeviceSession).GetField("decoder",BindingFlags.Instance|BindingFlags.NonPublic).GetValue(session);decoder.Kill();await Task.Delay(2800);click=session.ClickAsync(new PointF(800,400));}finally{gate.Release();}
                        bool rejected=false;try{await click;}catch(InvalidOperationException error){rejected=error.Message.Contains("停滞");}
                        await session.FlushLogsAsync();if(!rejected||CountClicks(log)!=before)throw new Exception("Stale frame input was not safely rejected");
                        Emit(new{staleFrameRejected=true,deviceTapSent=false,frameAge=session.FrameAge});
                    }
                    else if(words[0]=="recovery-check"){
                        long generation=session.VideoGeneration,sequence=session.FrameSequence;var watch=Stopwatch.StartNew();
                        var decoder=(Process)typeof(DeviceSession).GetField("decoder",BindingFlags.Instance|BindingFlags.NonPublic).GetValue(session);decoder.Kill();
                        while((session.VideoGeneration==generation||session.FrameSequence<=sequence||session.FrameAge>1)&&watch.Elapsed.TotalSeconds<25)await Task.Delay(50);
                        if(session.VideoGeneration==generation||session.FrameSequence<=sequence||session.FrameAge>1)throw new Exception("Automatic video recovery did not produce a fresh new-generation frame");
                        long firstRecovered=session.FrameSequence;await Task.Delay(1500);
                        if(session.FrameSequence-firstRecovered<8||session.FrameAge>1)throw new Exception("Recovered video did not remain live through the health monitor cycle");
                        var result=new{automaticVideoRecovered=true,elapsedMs=watch.Elapsed.TotalMilliseconds,oldGeneration=generation,newGeneration=session.VideoGeneration,calibrationInvalidated=!session.Calibrated,controlling=session.Controlling,frameAge=session.FrameAge};session.Log("video_recovery_sample",result);Emit(result);
                    }
                    else if(words[0]=="inspect")using(var image=session.Snapshot()){if(image==null)throw new Exception("No live image");var path=Path.Combine(session.LogDirectory,"smoke-"+(++snapshot)+".png");image.Save(path);Emit(new{frame=path,width=image.Width,height=image.Height,age=session.FrameAge,sequence=session.FrameSequence,controlling=session.Controlling,calibrated=session.Calibrated});}
                    Emit(new{command=line,ok=true});
                }catch(Exception error){Emit(new{command=line,ok=false,type=error.GetType().Name,error=error.Message});}}
            }finally{session.DisconnectAsync().GetAwaiter().GetResult();}
        }
    }
    static int CountClicks(string path){int count=0;using(var stream=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite))using(var reader=new StreamReader(stream)){string row;while((row=reader.ReadLine())!=null)if(row.Contains("\"type\":\"click_issued_once\""))count++;}return count;}
    // This ROI belongs ONLY to the explicitly selected InputProbe 1.0.0.0
    // scene. Product code never treats an arbitrary frame change as success.
    static async Task TimedClick(DeviceSession session,PointF target,int number){
        using(var before=session.AcquireFrame()){
            if(before==null||before.Width!=854||!session.Calibrated)throw new Exception("Timed InputProbe clicks require a fresh calibrated interactive view");
            var watch=Stopwatch.StartNew();long begun=Stopwatch.GetTimestamp();await session.ClickAsync(target);long sequence=before.Sequence;
            while(watch.ElapsedMilliseconds<4000){
                using(var current=session.AcquireFrame(sequence)){
                    if(current!=null){sequence=current.Sequence;int changed=0;
                        for(int y=302;y<326;y++)for(int x=135;x<391;x++){int i=y*current.Stride+x*4;if(Math.Abs(current.Pixels[i]-before.Pixels[i])+Math.Abs(current.Pixels[i+1]-before.Pixels[i+1])+Math.Abs(current.Pixels[i+2]-before.Pixels[i+2])>160)changed++;}
                        if(changed>150){
                            var result=new{measurement="inputprobe_selection_roi_change_requires_trusted_state_readback",target=target,changedPixels=changed,requestToVisibleFrameMs=(current.ReceivedTicks-begun)*1000.0/Stopwatch.Frequency,completedMs=watch.Elapsed.TotalMilliseconds,number=number,beforeSequence=before.Sequence,afterSequence=current.Sequence};
                            session.Log("visible_click_sample",result);Emit(result);
                            // Evidence encoding happens AFTER the measured interval.
                            lock(before.DrawingSync)before.Image.Save(Path.Combine(session.LogDirectory,"timed-"+number+"-before.png"));
                            lock(current.DrawingSync)current.Image.Save(Path.Combine(session.LogDirectory,"timed-"+number+"-after.png"));return;
                        }
                    }
                }
                await Task.Delay(5);
            }
            throw new Exception("No visible InputProbe selection change; input was not retried");
        }
    }
    static async Task Measure(DeviceSession session,int seconds){
        if(seconds<2||seconds>60)throw new ArgumentOutOfRangeException("seconds");
        var processes=new System.Collections.Generic.List<Process>{Process.GetCurrentProcess()};
        foreach(string field in new[]{"decoder","video"}){var process=typeof(DeviceSession).GetField(field,BindingFlags.Instance|BindingFlags.NonPublic).GetValue(session) as Process;if(process!=null)processes.Add(process);}
        double cpuBefore=0;foreach(var process in processes)try{cpuBefore+=process.TotalProcessorTime.TotalMilliseconds;}catch{}
        var ages=new System.Collections.Generic.List<double>();var start=session.FrameSequence;int generation=session.VideoGeneration;var watch=Stopwatch.StartNew();
        while(watch.Elapsed.TotalSeconds<seconds){ages.Add(session.FrameAge*1000);await Task.Delay(20);}
        double cpuAfter=0;foreach(var process in processes)try{process.Refresh();cpuAfter+=process.TotalProcessorTime.TotalMilliseconds;}catch{}
        if(session.VideoGeneration!=generation||cpuAfter<cpuBefore||double.IsInfinity(session.FrameAge)){Emit(new{measurement="invalidated_by_video_recovery",generation=generation,currentGeneration=session.VideoGeneration});return;}
        ages.Sort();var result=new{measurement="local_decode_receipt_not_device_capture",seconds=watch.Elapsed.TotalSeconds,frames=session.FrameSequence-start,fps=(session.FrameSequence-start)/watch.Elapsed.TotalSeconds,ageP50Ms=ages[ages.Count/2],ageP95Ms=ages[(int)((ages.Count-1)*.95)],cpuCorePercent=(cpuAfter-cpuBefore)/watch.Elapsed.TotalMilliseconds*100,processCount=processes.Count};
        session.Log("performance_sample",result);Emit(result);
    }
}
