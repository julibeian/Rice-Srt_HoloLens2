using System;
using System.IO;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using Rice.HoloLens.Control;
class SessionJournalTests {
    static void Main(){try{Run().GetAwaiter().GetResult();}catch(Exception error){Console.WriteLine(error.GetType().Name+": "+error.Message);Environment.ExitCode=1;}}
    static async Task Run(){
        string root=Path.Combine(Path.GetTempPath(),"hololens-journal-"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(root);
        string path=Path.Combine(root,"events.jsonl");
        try{
            using(var journal=new SessionJournal(path)){
                for(int i=0;i<500;i++)journal.Log("ordered",new{sequence=i});
                await journal.FlushAsync();
                string[] lines;using(var input=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite))using(var reader=new StreamReader(input))lines=reader.ReadToEnd().Split(new[]{'\r','\n'},StringSplitOptions.RemoveEmptyEntries);if(lines.Length!=500)throw new Exception("Flush did not preserve all queued events");
                var json=new JavaScriptSerializer();for(int i=0;i<lines.Length;i++){var row=json.Deserialize<System.Collections.Generic.Dictionary<string,object>>(lines[i]);var value=(System.Collections.Generic.Dictionary<string,object>)row["value"];if(Convert.ToInt32(value["sequence"])!=i||!row.ContainsKey("monotonicTicks"))throw new Exception("Journal reordered events or omitted monotonic time");}
                if(journal.Error!=null)throw new Exception(journal.Error);
            }
            using(var held=new FileStream(path,FileMode.Open,FileAccess.ReadWrite,FileShare.None))using(var journal=new SessionJournal(path)){
                journal.Log("locked-disk",new{inputMustNotBlock=true});await journal.FlushAsync();
                if(journal.Error==null)throw new Exception("Disk failure must be observable without blocking input");
            }
            Console.WriteLine("Async journal order, flush, timestamps and disk failure checks passed: 4");
        }finally{if(File.Exists(path))File.Delete(path);Directory.Delete(root);}
    }
}
