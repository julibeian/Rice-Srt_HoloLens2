using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using Rice.HoloLens.Control;

class OperationProcessTests {
    static readonly JavaScriptSerializer Json=new JavaScriptSerializer();
    static int Main(string[] args){try{Run(args).GetAwaiter().GetResult();return 0;}catch(Exception error){Console.Error.WriteLine(error);return 1;}}
    static ProcessStartInfo Start(string fixture,string mode,string marker){return new ProcessStartInfo(fixture,"--mode "+mode+" --marker \""+marker+"\""){UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true,RedirectStandardError=true,RedirectStandardInput=true,StandardOutputEncoding=Encoding.UTF8,StandardErrorEncoding=Encoding.UTF8};}
    static Dictionary<string,object> Marker(string path){return Json.Deserialize<Dictionary<string,object>>(File.ReadAllText(path));}
    static bool OwnedAlive(string marker,string fixture,bool stop){
        var data=Marker(marker);try{using(var child=Process.GetProcessById(Convert.ToInt32(data["pid"]))){
            if(child.HasExited)return false;
            if(child.MainModule.FileName!=fixture||child.StartTime.ToUniversalTime().Ticks!=Convert.ToInt64(data["startUtcTicks"]))throw new Exception("Fixture PID identity changed");
            if(stop){child.Kill();if(!child.WaitForExit(3000))throw new Exception("Owned fixture did not stop");}return true;
        }}catch(ArgumentException){return false;}
    }
    static Task UiMessageLoopCase(string fixture,string marker){
        var done=new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var thread=new Thread(()=>{
            int ticks=0;bool timedOut=false;Exception failure=null;var watch=Stopwatch.StartNew();
            using(var context=new System.Windows.Forms.WindowsFormsSynchronizationContext())using(var timer=new System.Windows.Forms.Timer{Interval=25}){
                SynchronizationContext.SetSynchronizationContext(context);timer.Tick+=(sender,args)=>ticks++;timer.Start();
                context.Post(async state=>{
                    try{await OperationProcess.RunAsync(Start(fixture,"close-streams",marker),800);}catch(TimeoutException){timedOut=true;}catch(Exception error){failure=error;}
                    timer.Stop();System.Windows.Forms.Application.ExitThread();
                },null);
                System.Windows.Forms.Application.Run();
            }
            if(failure!=null)done.TrySetException(failure);
            else if(!timedOut||ticks<5||watch.ElapsedMilliseconds>3500)done.TrySetException(new Exception("Local UI message loop was blocked"));
            else{Console.WriteLine("UI message loop remained responsive: ticks="+ticks);done.TrySetResult(true);}
        });
        thread.IsBackground=true;thread.SetApartmentState(ApartmentState.STA);thread.Start();return done.Task;
    }
    static async Task Run(string[] args){
        string fixture=Path.GetFullPath(args[0]),root=Path.GetFullPath(args[1]);Directory.CreateDirectory(root);int passed=0;
        foreach(string mode in new[]{"normal","nonzero","drain","utf8-chunks"}){
            string marker=Path.Combine(root,mode+".json");var result=await OperationProcess.RunAsync(Start(fixture,mode,marker),5000);
            if(mode=="normal"&&(result.ExitCode!=0||!result.Output.Contains("\"value\":7")||!result.Error.Contains("fixture stderr")))throw new Exception("Normal stdout/stderr missing");
            if(mode=="nonzero"&&(result.ExitCode!=3||!result.Error.Contains("fixture rejection")))throw new Exception("Nonzero exit was lost");
            if(mode=="drain"&&(result.Output.Length!=96*4096||result.Error.Length!=96*4096))throw new Exception("Concurrent pipe output was truncated");
            if(mode=="utf8-chunks"&&result.Output!="{\"message\":\"眼镜原身份已核对，点按未重发\",\"value\":7}")throw new Exception("Split UTF8 data was corrupted");
            if(OwnedAlive(marker,fixture,true))throw new Exception("Completed fixture still running");passed++;
        }
        foreach(string mode in new[]{"close-stdout","close-streams","inherited-writers"}){
            string marker=Path.Combine(root,mode+".json");var watch=Stopwatch.StartNew();bool timedOut=false;int ticks=0;
            using(var timer=new Timer(_=>Interlocked.Increment(ref ticks),null,0,25)){
                try{await OperationProcess.RunAsync(Start(fixture,mode,marker),800);}catch(TimeoutException){timedOut=true;}
            }
            bool rootAlive=OwnedAlive(marker,fixture,true),holderAlive=false;
            if(File.Exists(marker+".holder"))holderAlive=OwnedAlive(marker+".holder",fixture,true);
            if(!timedOut||watch.ElapsedMilliseconds>3500||rootAlive||ticks<5)throw new Exception("Deadline or owned-process cleanup failed: "+mode);
            if(mode=="inherited-writers"&&!holderAlive)throw new Exception("Inherited writer was unexpectedly killed or never started");
            Console.WriteLine(mode+": bounded in "+watch.ElapsedMilliseconds+"ms; async ticks="+ticks+"; inherited writer preserved="+holderAlive);passed++;
        }
        {
            string marker=Path.Combine(root,"excess-output.json");bool rejected=false;
            try{await OperationProcess.RunAsync(Start(fixture,"excess-output",marker),5000);}catch(IOException){rejected=true;}
            bool alive=OwnedAlive(marker,fixture,true);if(!rejected||alive)throw new Exception("Output limit did not stop the owned process");passed++;
        }
        {
            string marker=Path.Combine(root,"ui-message-loop.json");await UiMessageLoopCase(fixture,marker);
            if(OwnedAlive(marker,fixture,true))throw new Exception("UI fault fixture was not stopped");passed++;
        }
        Console.WriteLine("Operation process: "+passed+" local process/pipe cases passed; device input=0; automatic replay=0");
    }
}
