// Local transport benchmark; no device, credentials or room imagery.
using System;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Threading.Tasks;
class RawPipeBenchmark {
    static void Main(string[] args){
        if(args.Length>1){
            foreach(string timebase in new[]{""," -enc_time_base -1"})using(var process=new Process{StartInfo=new ProcessStartInfo(args[0],"-hide_banner -loglevel warning -flags low_delay -probesize 65536 -analyzeduration 0 -threads 2 -i \""+args[1]+"\" -an -vf scale=854:480 -vsync 0"+timebase+" -pix_fmt bgra -c:v rawvideo -threads 2 -f rawvideo pipe:1"){UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true,RedirectStandardError=true}}){
                process.Start();var errors=process.StandardError.ReadToEndAsync();long count=0;int n;var bytes=new byte[65536];while((n=process.StandardOutput.BaseStream.Read(bytes,0,bytes.Length))>0)count+=n;process.WaitForExit();Console.WriteLine("timebase="+timebase+" frames="+count/(854*480*4)+" bytes="+count+" error="+errors.GetAwaiter().GetResult());
            }return;
        }
        foreach(bool named in new[]{false,true}){
            string name="hololens-raw-bench-"+Guid.NewGuid().ToString("N");
            using(var pipe=named?new NamedPipeServerStream(name,PipeDirection.In,1,PipeTransmissionMode.Byte,PipeOptions.Asynchronous,4*1024*1024,0):null)
            using(var process=new Process{StartInfo=new ProcessStartInfo(args[0],"-hide_banner -loglevel error -f lavfi -i color=c=black:s=854x480:r=30 -frames:v 150 -an -pix_fmt bgra -c:v rawvideo -threads 2 -f rawvideo -y "+(named?"\\\\.\\pipe\\"+name:"pipe:1")){UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true,RedirectStandardError=true}}){
                process.Start();var errors=process.StandardError.ReadToEndAsync();if(named)pipe.WaitForConnection();
                Stream input=named?(Stream)pipe:process.StandardOutput.BaseStream;var bytes=new byte[854*480*4];int frames=0,reads=0;long count=0;var watch=Stopwatch.StartNew();
                while(true){int offset=0;while(offset<bytes.Length){int received=input.Read(bytes,offset,bytes.Length-offset);reads++;if(received==0)break;count+=received;offset+=received;}if(offset==0)break;if(offset!=bytes.Length)throw new Exception("Truncated local frame");frames++;}
                process.WaitForExit();Console.WriteLine("named="+named+" frames="+frames+" seconds="+watch.Elapsed.TotalSeconds.ToString("F3")+" fps="+(frames/watch.Elapsed.TotalSeconds).ToString("F1")+" MBps="+(count/watch.Elapsed.TotalSeconds/1000000).ToString("F1")+" reads="+reads+" error="+errors.GetAwaiter().GetResult());if(process.ExitCode!=0)throw new Exception("ffmpeg failed");
            }
        }
    }
}
