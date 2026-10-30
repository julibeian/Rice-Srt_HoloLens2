using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;

namespace Rice.HoloLens.Control {
    public sealed class OperationOutput {
        public string Output,Error;
        public int ExitCode,ProcessId;
    }
    // One deadline covers both output pipes AND the owned process. Peek avoids
    // an uncancellable Framework pipe read when an inherited writer stays open.
    public static class OperationProcess {
        const int MaximumOutputBytes=8*1024*1024;
        [DllImport("kernel32.dll",SetLastError=true)]static extern bool PeekNamedPipe(SafeFileHandle pipe,IntPtr buffer,uint size,IntPtr read,out uint available,IntPtr remaining);
        [DllImport("kernel32.dll",SetLastError=true)]static extern bool ReadFile(SafeFileHandle pipe,byte[] buffer,uint count,out uint read,IntPtr overlapped);
        static Task<string> Capture(StreamReader reader,CancellationToken cancellation){
            var input=reader.BaseStream as FileStream;
            if(input==null)throw new NotSupportedException("设备操作输出不是预期的本机管道");
            var encoding=reader.CurrentEncoding;
            return Task.Factory.StartNew(()=>{
                using(var bytes=new MemoryStream()){
                    byte[] buffer=new byte[16384];
                    while(!cancellation.IsCancellationRequested){
                        uint available;
                        if(!PeekNamedPipe(input.SafeFileHandle,IntPtr.Zero,0,IntPtr.Zero,out available,IntPtr.Zero)){
                            int error=Marshal.GetLastWin32Error();
                            if(error==109||error==233||error==232)break;
                            throw new Win32Exception(error,"读取设备操作输出失败");
                        }
                        if(available==0){Thread.Sleep(10);continue;}
                        uint received;
                        // Do not use FileStream.Read here: its read-ahead buffer
                        // could hide bytes from the next PeekNamedPipe call.
                        if(!ReadFile(input.SafeFileHandle,buffer,Math.Min((uint)buffer.Length,available),out received,IntPtr.Zero)){
                            int error=Marshal.GetLastWin32Error();if(error==109)break;throw new Win32Exception(error);
                        }
                        int count=(int)received;
                        if(count==0)break;
                        if(bytes.Length+count>MaximumOutputBytes)throw new IOException("设备操作输出超过容量限制");
                        bytes.Write(buffer,0,count);
                    }
                    bytes.Position=0;
                    using(var text=new StreamReader(bytes,encoding,true))return text.ReadToEnd();
                }
            },CancellationToken.None,TaskCreationOptions.LongRunning,TaskScheduler.Default);
        }
        static async Task ObserveFailure(Task work,TaskCompletionSource<Exception> failure){try{await work.ConfigureAwait(false);}catch(Exception error){failure.TrySetResult(error);}}
        static async Task<bool> StopOwn(Process process,Task exit){
            try{if(!process.HasExited)process.Kill();}catch{}
            await Task.WhenAny(exit,Task.Delay(2000)).ConfigureAwait(false);
            try{return process.HasExited;}catch{return false;}
        }
        public static async Task<OperationOutput> RunAsync(ProcessStartInfo start,int timeoutMilliseconds){
            if(timeoutMilliseconds<=0)throw new ArgumentOutOfRangeException("timeoutMilliseconds");
            if(start.UseShellExecute||!start.RedirectStandardOutput||!start.RedirectStandardError)throw new ArgumentException("设备操作必须使用私有输出管道");
            using(var process=new Process{StartInfo=start})using(var cancellation=new CancellationTokenSource())using(var timer=new CancellationTokenSource()){
                var exit=new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
                EventHandler exited=(sender,args)=>exit.TrySetResult(true);
                process.Exited+=exited;process.EnableRaisingEvents=true;
                Task<string> output=null,error=null;Task complete=null;bool started=false;
                Exception failure=null;OperationOutput result=null;
                try{
                    if(!process.Start())throw new InvalidOperationException("设备操作进程未启动");
                    started=true;if(process.HasExited)exit.TrySetResult(true);
                    if(start.RedirectStandardInput)process.StandardInput.Close();
                    output=Capture(process.StandardOutput,cancellation.Token);error=Capture(process.StandardError,cancellation.Token);
                    complete=Task.WhenAll(output,error,exit.Task);
                    var pipeFailure=new TaskCompletionSource<Exception>(TaskCreationOptions.RunContinuationsAsynchronously);
                    var observeOutput=ObserveFailure(output,pipeFailure);var observeError=ObserveFailure(error,pipeFailure);
                    var winner=await Task.WhenAny(complete,pipeFailure.Task,Task.Delay(timeoutMilliseconds,timer.Token)).ConfigureAwait(false);
                    if(winner==pipeFailure.Task)System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(pipeFailure.Task.Result).Throw();
                    if(winner!=complete){
                        var timeout=new TimeoutException("设备操作超时；先核对本次结果，再继续操作");
                        timeout.Data["ProcessId"]=process.Id;throw timeout;
                    }
                    await complete.ConfigureAwait(false);
                    result=new OperationOutput{Output=output.Result,Error=error.Result,ExitCode=process.ExitCode,ProcessId=process.Id};
                }catch(Exception errorCaught){failure=errorCaught;}
                timer.Cancel();cancellation.Cancel();
                if(failure!=null&&started)failure.Data["ProcessExitConfirmed"]=await StopOwn(process,exit.Task).ConfigureAwait(false);
                // Each pipe has a single reader and only already-available
                // bytes are read. Cancel also releases readers for inherited
                // writers; never terminate the other process holding them.
                if(output!=null)try{await output.ConfigureAwait(false);}catch{}
                if(error!=null)try{await error.ConfigureAwait(false);}catch{}
                if(complete!=null&&complete.IsFaulted){var observed=complete.Exception;}
                process.Exited-=exited;
                if(failure!=null)System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(failure).Throw();
                return result;
            }
        }
    }
}
