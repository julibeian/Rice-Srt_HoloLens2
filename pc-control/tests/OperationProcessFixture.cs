using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

// Local fault process only. Never loads device configuration or sends input.
class OperationProcessFixture {
    [DllImport("kernel32.dll")]static extern IntPtr GetStdHandle(int kind);
    [DllImport("kernel32.dll")]static extern bool CloseHandle(IntPtr handle);
    static string Value(string[] args,string key){for(int i=0;i+1<args.Length;i++)if(args[i]==key)return args[i+1];return null;}
    static int Main(string[] args){
        string mode=Value(args,"-Operation")??Value(args,"--mode"),marker=Value(args,"--marker");
        if(marker==null||mode==null)return 64;
        using(var current=Process.GetCurrentProcess()){
            var record=new{pid=current.Id,startUtcTicks=current.StartTime.ToUniversalTime().Ticks,executable=current.MainModule.FileName,mode=mode,local_fixture=true,device_input_sent=false};
            using(var file=new FileStream(marker,FileMode.CreateNew,FileAccess.Write))using(var writer=new StreamWriter(file))writer.Write(new JavaScriptSerializer().Serialize(record));
        }
        if(mode=="normal"){Console.WriteLine("{\"local_fixture\":true,\"value\":7}");Console.Error.WriteLine("fixture stderr");return 0;}
        if(mode=="nonzero"){Console.WriteLine("{\"local_fixture\":true,\"error\":true}");Console.Error.WriteLine("fixture rejection");return 3;}
        if(mode=="drain"){for(int i=0;i<96;i++){Console.Out.Write(new string('o',4096));Console.Error.Write(new string('e',4096));}return 0;}
        if(mode=="utf8-chunks"){
            byte[] bytes=Encoding.UTF8.GetBytes("{\"message\":\"眼镜原身份已核对，点按未重发\",\"value\":7}");
            using(var output=Console.OpenStandardOutput())for(int i=0;i<bytes.Length;i++){output.Write(bytes,i,1);output.Flush();Thread.Sleep(1);}return 0;
        }
        if(mode=="excess-output"){for(int i=0;i<2304;i++)Console.Out.Write(new string('o',4096));return 0;}
        if(mode=="holder"){Thread.Sleep(65000);return 0;}
        if(mode=="inherited-writers"){
            using(var current=Process.GetCurrentProcess())using(var child=Process.Start(new ProcessStartInfo(current.MainModule.FileName,"--mode holder --marker \""+marker+".holder\""){UseShellExecute=false,CreateNoWindow=true})){
                for(int i=0;i<100&&!File.Exists(marker+".holder");i++)Thread.Sleep(10);
                if(!File.Exists(marker+".holder"))return 5;
                Console.WriteLine("{\"local_fixture\":true,\"inherited_writers\":true}");return 0;
            }
        }
        if(mode=="close-stdout"||mode=="close-streams"){
            Console.Out.Flush();Console.Error.Flush();CloseHandle(GetStdHandle(-11));
            if(mode=="close-streams")CloseHandle(GetStdHandle(-12));
            Thread.Sleep(65000);return 0;
        }
        return 64;
    }
}
