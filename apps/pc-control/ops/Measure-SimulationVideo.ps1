param(
 [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_-]{1,64}$')][string]$RunId,
 [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_-]{1,64}$')][string]$LeaseRunId,
 [ValidateRange(2,10)][int]$Seconds=5
)
$ErrorActionPreference='Stop'
$workspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$folder=Join-Path $workspace ('reports/phase2-full-control/'+$RunId)
$resultPath=Join-Path $folder 'result.json'
if(Test-Path -LiteralPath $resultPath){Get-Content -LiteralPath $resultPath -Raw;return}
if(Test-Path -LiteralPath $folder){throw 'Partial measurement exists; do not replay this run.'}
$guard=& (Join-Path $workspace 'apps/holographic-control/ops/Control-Lease.ps1') -Mode Status -RunId $LeaseRunId | ConvertFrom-Json
if(-not $guard.Active){throw 'An active named device protection is required.'}
. (Join-Path $workspace 'apps/holographic-control/ops/Holographic.Common.ps1')
$context=New-HoloAuthenticatedPortalContext
[IO.Directory]::CreateDirectory($folder)|Out-Null
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Diagnostics;
using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
public static class SimulationVideoMeasurement {
 public static async Task<object> Read(string address,string pin,string authorization,string cookie,string csrf,string path,int seconds){
  byte[] descriptor=null;var records=new List<object>();int eye0=0,eye1=0;long total=0;bool closed=false;string error=null;double elapsed=0;
  using(var data=new MemoryStream())using(var socket=new ClientWebSocket()){
   socket.Options.Proxy=null;socket.Options.RemoteCertificateValidationCallback=(s,c,h,e)=>c!=null&&Convert.ToHexString(SHA256.HashData(c.GetRawCertData()))==pin;
   socket.Options.SetRequestHeader("Authorization",authorization);socket.Options.SetRequestHeader("Cookie",cookie);socket.Options.SetRequestHeader("X-CSRF-Token",csrf);socket.Options.SetRequestHeader("Origin","https://"+address);
   using(var deadline=new CancellationTokenSource(TimeSpan.FromSeconds(10))){
    var clock=new Stopwatch();
    try{
     await socket.ConnectAsync(new Uri("wss://"+address+"/api/holographic/simulation/display/stream?additionalView=false"),deadline.Token);
     deadline.CancelAfter(TimeSpan.FromSeconds(seconds));clock.Start();var buffer=new byte[65536];int expected=-1,eye=-1;
     while(total<20*1024*1024){
      using(var message=new MemoryStream()){
       WebSocketReceiveResult part;
       do{part=await socket.ReceiveAsync(new ArraySegment<byte>(buffer),deadline.Token);if(part.MessageType!=WebSocketMessageType.Binary)throw new InvalidDataException("Expected binary simulation display");if(message.Length+part.Count>8*1024*1024)throw new InvalidDataException("Display payload exceeds bound");message.Write(buffer,0,part.Count);}while(!part.EndOfMessage);
       var bytes=message.ToArray();
       if(descriptor==null){if(bytes.Length!=16)throw new InvalidDataException("Unknown descriptor");descriptor=bytes;continue;}
       if(expected<0){if(bytes.Length!=8)throw new InvalidDataException("Unknown texture header");eye=BitConverter.ToUInt16(bytes,0);expected=BitConverter.ToInt32(bytes,4);if(eye>1||expected<=0||expected>8*1024*1024)throw new InvalidDataException("Invalid eye or texture size");continue;}
       if(bytes.Length!=expected||bytes.Length<4||bytes[0]!=0||bytes[1]!=0||bytes[2]!=0||bytes[3]!=1)throw new InvalidDataException("Texture is not the declared Annex B payload");
       data.Write(bytes,0,bytes.Length);total+=bytes.Length;if(eye==0)eye0++;else eye1++;records.Add(new{eye=eye,bytes=bytes.Length,elapsedMs=clock.Elapsed.TotalMilliseconds});expected=-1;
      }
     }
    }catch(OperationCanceledException){error="bounded_read_ended";}catch(Exception e){error=e.GetType().Name+": "+e.Message;}
    finally{elapsed=clock.Elapsed.TotalSeconds;if(socket.State==WebSocketState.Open)try{using(var stop=new CancellationTokenSource(2000))await socket.CloseOutputAsync(WebSocketCloseStatus.NormalClosure,"measurement ended",stop.Token);closed=true;}catch{}}
   }
   File.WriteAllBytes(path,data.ToArray());
  }
  return new{descriptorHex=descriptor==null?null:Convert.ToHexString(descriptor),eye0=eye0,eye1=eye1,seconds=elapsed,eye0Fps=elapsed>0?eye0/elapsed:0,bytes=total,closed=closed,error=error,records=records};
 }
}
'@
try {
 $page=$context.Client.GetAsync($context.BaseUri+'/default.htm').GetAwaiter().GetResult();$page.Dispose()
 $uri=[uri]($context.BaseUri+'/api/holographic/simulation/display/stream')
 $csrf=$context.Handler.CookieContainer.GetCookies($uri)['CSRF-Token'];if(-not $csrf){throw 'No authenticated CSRF session.'}
 $result=[SimulationVideoMeasurement]::Read($context.Device.Address,$context.CertificateSha256,$context.Client.DefaultRequestHeaders.Authorization.ToString(),$context.Handler.CookieContainer.GetCookieHeader($uri),$csrf.Value,(Join-Path $folder 'both-eyes.h264'),$Seconds).GetAwaiter().GetResult()
 $proof=@{run_id=$RunId;lease_run_id=$LeaseRunId;at=[DateTimeOffset]::Now.ToString('o');source='official-simulation-display';input_sent=$false;visible_ui_verified=$false;result=$result}
 [IO.File]::WriteAllText($resultPath,($proof|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
 $proof | Select-Object run_id,source,input_sent,@{n='summary';e={$_.result|Select-Object descriptorHex,eye0,eye1,seconds,eye0Fps,bytes,closed,error}} | ConvertTo-Json -Depth 5
} finally {$context.Client.Dispose()}
