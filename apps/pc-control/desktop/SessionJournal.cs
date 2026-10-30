using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

namespace Rice.HoloLens.Control {
    // Disk and JSON serialization never run on an input, decoder or UI thread.
    public sealed class SessionJournal : IDisposable {
        readonly BlockingCollection<object> queue=new BlockingCollection<object>(4096);
        readonly Task writer;
        long dropped;
        int closed;
        public string Error {get;private set;}
        sealed class Barrier {internal readonly TaskCompletionSource<bool> Done=new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);}
        public SessionJournal(string path){writer=Task.Factory.StartNew(()=>Write(path),CancellationToken.None,TaskCreationOptions.LongRunning,TaskScheduler.Default);}
        public void Log(string type,object value){
            if(Volatile.Read(ref closed)!=0)return;
            var row=new{at=DateTimeOffset.Now.ToString("o"),monotonicTicks=Stopwatch.GetTimestamp(),type=type,value=value};
            try{if(!queue.TryAdd(row))Interlocked.Increment(ref dropped);}catch(InvalidOperationException){}
        }
        public async Task FlushAsync(){var barrier=new Barrier();if(!queue.IsAddingCompleted){try{if(!queue.TryAdd(barrier))throw new IOException("Session journal backlog full");}catch(InvalidOperationException){return;}await barrier.Done.Task.ConfigureAwait(false);}}
        void Write(string path){
            var json=new JavaScriptSerializer();StreamWriter file=null;
            try{file=new StreamWriter(path,true,new UTF8Encoding(false)){AutoFlush=true};}catch(Exception e){Error=e.GetType().Name;}
            foreach(var row in queue.GetConsumingEnumerable()){
                var barrier=row as Barrier;if(barrier!=null){barrier.Done.TrySetResult(true);continue;}
                try{if(file!=null){long lost=Interlocked.Exchange(ref dropped,0);if(lost>0)file.WriteLine(json.Serialize(new{type="journal_overflow",count=lost}));file.WriteLine(json.Serialize(row));}}catch(Exception e){Error=e.GetType().Name;}
            }
            if(file!=null)file.Dispose();
        }
        public void Dispose(){if(Interlocked.Exchange(ref closed,1)!=0)return;queue.CompleteAdding();writer.Wait(3000);}
    }
}
