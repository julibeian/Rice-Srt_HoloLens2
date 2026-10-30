// Runs the real baseline/current frame readers over one frozen input file.
// No device discovery, portal request, input or Windows UI automation.
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
class ReplayDecodeBenchmark {
    static object ReadProperty(object instance,string name){return instance.GetType().GetProperty(name).GetValue(instance,null);}
    static void Main(string[] args){
        string assemblyPath=Path.GetFullPath(args[0]),workspace=Path.GetFullPath(args[1]),capture=Path.GetFullPath(args[2]),mode=args[3];
        if(mode!="baseline"&&mode!="current")throw new ArgumentException("Unknown benchmark mode");
        var json=new JavaScriptSerializer();var assembly=Assembly.LoadFile(assemblyPath);var type=assembly.GetType("Rice.HoloLens.Control.DeviceSession",true);
        var runtime=json.Deserialize<System.Collections.Generic.Dictionary<string,object>>(File.ReadAllText(Path.Combine(workspace,"apps/pc-control\\dist\\runtime.json")));
        string ffmpeg=(string)runtime["Ffmpeg"];
        string decoder=mode=="baseline"?"-hide_banner -loglevel warning -fflags nobuffer -flags low_delay -probesize 65536 -analyzeduration 0 -i pipe:0 -an -vf fps=12 -f image2pipe -vcodec mjpeg -q:v 3 pipe:1":(string)assembly.GetType("Rice.HoloLens.Control.VideoProfile",true).GetField("Interactive").GetValue(null).GetType().GetProperty("DecoderArguments").GetValue(assembly.GetType("Rice.HoloLens.Control.VideoProfile",true).GetField("Interactive").GetValue(null),null);
        object session=Activator.CreateInstance(type,new object[]{workspace});
        try{
            object store=null;
            if(mode=="current"){
                store=Activator.CreateInstance(assembly.GetType("Rice.HoloLens.Control.VideoFrameStore",true),new object[]{854,480,1,6});
                type.GetField("frames",BindingFlags.Instance|BindingFlags.NonPublic).SetValue(session,store);
            }
            using(var process=new Process{StartInfo=new ProcessStartInfo(ffmpeg,decoder){UseShellExecute=false,CreateNoWindow=true,RedirectStandardInput=true,RedirectStandardOutput=true,RedirectStandardError=true}}){
                var host=Process.GetCurrentProcess();double before=host.TotalProcessorTime.TotalMilliseconds;var clock=Stopwatch.StartNew();
                process.Start();var errors=process.StandardError.ReadToEndAsync();
                // Replay at the input's PTS cadence through an independent
                // FFmpeg copy process; its CPU is included for BOTH versions.
                using(var feeder=new Process{StartInfo=new ProcessStartInfo(ffmpeg,"-hide_banner -loglevel error -re -i "+Quote(capture)+" -an -c:v copy -f mpegts pipe:1"){UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true,RedirectStandardError=true}}){
                    feeder.Start();var feederErrors=feeder.StandardError.ReadToEndAsync();
                    var pump=Task.Factory.StartNew(()=>{try{feeder.StandardOutput.BaseStream.CopyTo(process.StandardInput.BaseStream,65536);}finally{process.StandardInput.Close();}},CancellationToken.None,TaskCreationOptions.LongRunning,TaskScheduler.Default);
                    var reader=type.GetMethod("ReadFrames",BindingFlags.Instance|BindingFlags.NonPublic);
                    reader.Invoke(session,mode=="baseline"?new object[]{process}:new object[]{process,store});
                    if(!pump.Wait(5000))throw new TimeoutException("Replay pipe did not close");
                    if(!process.WaitForExit(5000)||!feeder.WaitForExit(5000))throw new TimeoutException("Replay did not finish");
                    string decodeErrors=errors.GetAwaiter().GetResult(),feedErrors=feederErrors.GetAwaiter().GetResult();
                    if(process.ExitCode!=0||feeder.ExitCode!=0)throw new InvalidDataException("Replay decoder failed: "+decodeErrors+feedErrors);
                    host.Refresh();process.Refresh();feeder.Refresh();double cpu=host.TotalProcessorTime.TotalMilliseconds-before+process.TotalProcessorTime.TotalMilliseconds+feeder.TotalProcessorTime.TotalMilliseconds;
                    long frames=Convert.ToInt64(ReadProperty(session,"FrameSequence"));if(frames<10)throw new InvalidDataException("Too few replay frames");
                    Console.WriteLine(json.Serialize(new{mode=mode,source=capture,readerAssembly=assemblyPath,frames=frames,wallSeconds=clock.Elapsed.TotalSeconds,cpuMs=cpu,cpuCorePercent=cpu/clock.Elapsed.TotalMilliseconds*100,cpuMsPerFrame=cpu/frames,processes=3,networkIncluded=false,guiIncluded=false,deviceInputSent=false,decoder=decoder,decoderWarnings=decodeErrors,feederWarnings=feedErrors}));
                }
            }
        }finally{((IDisposable)session).Dispose();}
    }
    static string Quote(string value){return "\""+value.Replace("\"","\\\"")+"\"";}
}
