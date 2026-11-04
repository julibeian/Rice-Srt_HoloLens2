// Exercise the real desktop backend against isolated PowerShell operations.
// The fixture enforces the production RunId contract and never contacts a device.
using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using Rice.HoloLens.Control;

class ControlLeaseTests {
    static readonly JavaScriptSerializer Json=new JavaScriptSerializer();
    static string fixture,operations;
    static void Check(bool value,string message){if(!value)throw new Exception(message);}
    static List<Dictionary<string,object>> Calls(){
        var result=new List<Dictionary<string,object>>();var path=Path.Combine(operations,"calls.jsonl");
        if(File.Exists(path))foreach(var line in File.ReadAllLines(path))result.Add(Json.Deserialize<Dictionary<string,object>>(line));
        return result;
    }
    static async Task<Exception> Failure(Func<Task> action){try{await action();}catch(Exception error){return error;}throw new Exception("Expected operation rejection");}
    static void Flag(string name,bool enabled){var path=Path.Combine(operations,name);if(enabled)File.WriteAllText(path,"fixture");else if(File.Exists(path))File.Delete(path);}
    static int Main(string[] args){try{Run(args[0]).GetAwaiter().GetResult();return 0;}catch(Exception error){Console.Error.WriteLine(error);return 1;}}
    static async Task Run(string workspace){
        fixture=Path.Combine(workspace,"apps/pc-control/.state/tests","control-lease-"+Guid.NewGuid().ToString("N"));
        operations=Path.Combine(fixture,"apps/pc-control/ops");Directory.CreateDirectory(operations);
        var dist=Path.Combine(fixture,"apps/pc-control/dist");Directory.CreateDirectory(dist);
        File.WriteAllText(Path.Combine(dist,"runtime.json"),"{\"Ffmpeg\":\"unused-fixture\"}");
        File.WriteAllText(Path.Combine(operations,"Invoke-Operation.ps1"),@"
param([string]$Operation,[ValidatePattern('^[A-Za-z0-9_-]{1,64}$')][string]$RunId)
$ErrorActionPreference='Stop'
[IO.File]::AppendAllText((Join-Path $PSScriptRoot 'calls.jsonl'),(@{operation=$Operation;run=$RunId}|ConvertTo-Json -Compress)+[Environment]::NewLine)
switch($Operation){
 'StartLease' {if(Test-Path (Join-Path $PSScriptRoot 'reject-start')){throw 'fixture-start-rejected'};'{""Active"":true}'}
 'Controller' {'{""ok"":false,""state"":""fixture-controller-rejected""}'}
 'StopLease' {if(Test-Path (Join-Path $PSScriptRoot 'reject-stop')){throw 'fixture-stop-pending'};'{""Restored"":true}'}
 default {throw 'Unexpected fixture operation'}
}
");
        using(var session=new DeviceSession(fixture)){
            typeof(DeviceSession).GetField("powershell",BindingFlags.NonPublic|BindingFlags.Instance).SetValue(session,Path.Combine(workspace,@"runtime\powershell\pwsh.exe"));
            typeof(DeviceSession).GetField("<Connected>k__BackingField",BindingFlags.NonPublic|BindingFlags.Instance).SetValue(session,true);
            var notices=new List<string>();session.Notice+=message=>notices.Add(message);
            var samePath=typeof(DeviceSession).GetMethod("SameExecutablePath",BindingFlags.NonPublic|BindingFlags.Static);
            string actual=Path.Combine(workspace,@"apps\holographic-control\.state\desktop-x86\PerceptionControl.exe");
            string migrated=Path.Combine(workspace,"apps/holographic-control\\.state\\desktop-x86\\PerceptionControl.exe");
            Check((bool)samePath.Invoke(null,new object[]{actual,migrated}),"Migrated separators rejected the expected controller executable");
            Check((bool)samePath.Invoke(null,new object[]{actual,actual.ToUpperInvariant()}),"Windows path case rejected the expected controller executable");
            Check(!(bool)samePath.Invoke(null,new object[]{actual,Path.Combine(workspace,@"other\PerceptionControl.exe")}),"A different controller executable was accepted");
            var run=typeof(DeviceSession).GetMethod("RunScript",BindingFlags.NonPublic|BindingFlags.Instance);
            foreach(var invalid in new[]{"apps/pc-control-bad","bad\\run",new string('a',65),"run\n"}){
                var failure=await Failure(()=> (Task<Dictionary<string,object>>)run.Invoke(session,new object[]{"StartLease",new[]{"-RunId",invalid}}));
                Check(failure.Message.Contains("操作未发送"),"Invalid RunId was dispatched to PowerShell");
            }
            Check(Calls().Count==0&&!session.HasPendingControlRestore,"Local rejection created a lease or fixture call");

            Flag("reject-stop",true);
            var startError=await Failure(()=>session.StartControlAsync());var calls=Calls();
            Check(startError.Message=="控制连接未完成"&&startError.StackTrace.Contains("StartControlCore"),"Cleanup masked the original start failure");
            Check(calls.Count==3&&(string)calls[0]["operation"]=="StartLease"&&(string)calls[1]["operation"]=="Controller"&&(string)calls[2]["operation"]=="StopLease","Backend did not start and clean up exactly once");
            string id=(string)calls[0]["run"];
            Check(Regex.IsMatch(id,@"\Apc-control-[a-f0-9]{32}\z")&&(string)calls[2]["run"]==id,"Lease ID contract or same-run cleanup regressed");
            Check(session.HasPendingControlRestore&&!session.Controlling,"Pending restoration was presented as control off");

            await Failure(()=>session.StartControlAsync());calls=Calls();
            Check(calls.Count==4&&(string)calls[3]["operation"]=="StopLease"&&(string)calls[3]["run"]==id,"Pending restoration started another lease or duplicated cleanup");
            Flag("reject-stop",false);await session.StopControlAsync();int stopped=Calls().Count;
            Check(!session.HasPendingControlRestore&&session.ControlRemainingSeconds==0&&session.ControlExpires==default(DateTime),"Verified restoration retained a pending lease or countdown");
            await session.StopControlAsync();Check(Calls().Count==stopped,"Repeated stop dispatched another device operation");

            Flag("reject-start",true);Flag("reject-stop",true);int before=Calls().Count;
            var rejected=await Failure(()=>session.StartControlAsync());calls=Calls();
            Check(rejected.Message.StartsWith("建立控制保护失败")&&calls.Count==before+2,"Start rejection was obscured or sent controller input");
            Check((string)calls[before]["operation"]=="StartLease"&&(string)calls[before+1]["operation"]=="StopLease","Rejected start dispatched an unsafe operation");
            Check(!notices.Exists(message=>message.Contains("最晚于")||message.Contains("到期")),"Unverified lease advertised a guaranteed expiry");
            Flag("reject-start",false);Flag("reject-stop",false);await session.StopControlAsync();
            Check(!session.HasPendingControlRestore,"Same-run restoration retry did not clear pending state");
            await session.FlushLogsAsync();
        }
        Console.WriteLine("Control leases: RunId preflight, real PowerShell binding, controller path identity, failed-start cleanup, same-run recovery, original errors and countdown reset passed; device calls=0");
    }
}
