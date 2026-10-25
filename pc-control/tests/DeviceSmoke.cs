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
                    else if(words[0]=="focus")await session.FocusAppAsync();
                    else if(words[0]=="home")await session.HomeAsync();
                    else if(words[0]=="click")await session.ClickAsync(new PointF(float.Parse(words[1],CultureInfo.InvariantCulture),float.Parse(words[2],CultureInfo.InvariantCulture)));
                    else if(words[0]=="look")await session.LookAsync(float.Parse(words[1],CultureInfo.InvariantCulture),float.Parse(words[2],CultureInfo.InvariantCulture));
                    else if(words[0]=="stale-check"){
                        var log=Path.Combine(session.LogDirectory,"events.jsonl");
                        int before=CountClicks(log);
                        // Kill only this session's own decoder to exercise the
                        // real stale-frame gate without sending a device click.
                        var decoder=(Process)typeof(DeviceSession).GetField("decoder",BindingFlags.Instance|BindingFlags.NonPublic).GetValue(session);
                        decoder.Kill();await Task.Delay(2800);
                        bool rejected=false;try{await session.ClickAsync(new PointF(800,400));}catch(InvalidOperationException){rejected=true;}
                        if(!rejected||CountClicks(log)!=before)throw new Exception("Stale frame input was not safely rejected");
                        Emit(new{staleFrameRejected=true,deviceTapSent=false,frameAge=session.FrameAge});
                    }
                    else if(words[0]=="inspect")using(var image=session.Snapshot()){if(image==null)throw new Exception("No live image");var path=Path.Combine(session.LogDirectory,"smoke-"+(++snapshot)+".png");image.Save(path);Emit(new{frame=path,width=image.Width,height=image.Height,age=session.FrameAge,sequence=session.FrameSequence,controlling=session.Controlling,calibrated=session.Calibrated});}
                    Emit(new{command=line,ok=true});
                }catch(Exception error){Emit(new{command=line,ok=false,type=error.GetType().Name,error=error.Message});}}
            }finally{session.DisconnectAsync().GetAwaiter().GetResult();}
        }
    }
    static int CountClicks(string path){int count=0;foreach(var row in File.ReadAllLines(path))if(row.Contains("\"type\":\"click_issued_once\""))count++;return count;}
}
