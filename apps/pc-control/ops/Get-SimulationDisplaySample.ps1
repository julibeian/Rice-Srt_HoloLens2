param(
 [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_-]{1,64}$')][string]$RunId,
 [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_-]{1,64}$')][string]$LeaseRunId,
 [ValidateRange(1,10)][int]$Seconds=4
)
$ErrorActionPreference='Stop'
$workspace=Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$folder=Join-Path $workspace ('reports\phase2-full-control\'+$RunId)
$resultPath=Join-Path $folder 'simulation-display-sample.json'
if(Test-Path -LiteralPath $resultPath){Get-Content -LiteralPath $resultPath -Raw;exit}
if(Test-Path -LiteralPath $folder){throw 'Partial display sample exists; inspect its original files.'}
. (Join-Path $workspace 'apps/holographic-control\ops\Holographic.Common.ps1')
$guard=& (Join-Path $workspace 'apps/holographic-control\ops\Control-Lease.ps1') -Mode Status -RunId $LeaseRunId|ConvertFrom-Json
if(-not $guard.Active){throw 'Simulation display sampling requires the active named device protection.'}
$context=New-HoloAuthenticatedPortalContext
[IO.Directory]::CreateDirectory($folder)|Out-Null
Copy-Item -LiteralPath $PSCommandPath -Destination (Join-Path $folder 'sample-source.ps1')
if(-not('Phase2DisplayCapture' -as [type])){
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
public static class Phase2DisplayCapture {
 public static async Task<object> Read(string address,string pin,string authorization,string cookie,string csrf,string folder,int seconds){
  var records=new List<object>();long total=0;bool connected=false,closed=false;string error=null;
  using(var socket=new ClientWebSocket()){
   socket.Options.Proxy=null;
   socket.Options.RemoteCertificateValidationCallback=(sender,cert,chain,errors)=>cert!=null && Convert.ToHexString(SHA256.HashData(cert.GetRawCertData()))==pin;
   socket.Options.SetRequestHeader("Authorization",authorization);socket.Options.SetRequestHeader("Cookie",cookie);
   socket.Options.SetRequestHeader("X-CSRF-Token",csrf);socket.Options.SetRequestHeader("Origin","https://"+address);
   using(var deadline=new CancellationTokenSource(TimeSpan.FromSeconds(seconds+5))){
    try{
     await socket.ConnectAsync(new Uri("wss://"+address+"/api/holographic/simulation/display/stream?additionalView=false"),deadline.Token);connected=true;
     deadline.CancelAfter(TimeSpan.FromSeconds(seconds));var buffer=new byte[65536];
     while(records.Count<200 && total<20*1024*1024){
      using(var message=new MemoryStream()){
       WebSocketReceiveResult part;
       do{part=await socket.ReceiveAsync(new ArraySegment<byte>(buffer),deadline.Token);if(part.MessageType==WebSocketMessageType.Close){closed=true;break;}if(message.Length+part.Count>8*1024*1024)throw new InvalidDataException("Display message exceeds limit");message.Write(buffer,0,part.Count);}while(!part.EndOfMessage);
       if(closed)break;var data=message.ToArray();string name="message-"+records.Count.ToString("D3")+".bin";
       File.WriteAllBytes(Path.Combine(folder,name),data);total+=data.Length;
       records.Add(new{file=name,bytes=data.Length,type=part.MessageType.ToString(),received_at=DateTimeOffset.Now.ToString("o"),prefix_hex=Convert.ToHexString(data.AsSpan(0,Math.Min(80,data.Length)))});
      }
     }
    }catch(OperationCanceledException){error="bounded_read_ended";}catch(Exception e){error=e.GetType().Name;}
    finally{if(socket.State==WebSocketState.Open){try{using(var stop=new CancellationTokenSource(2000))await socket.CloseOutputAsync(WebSocketCloseStatus.NormalClosure,"sample ended",stop.Token);closed=true;}catch{}}}
   }
  }
  return new{connected=connected,closed=closed,bytes=total,messages=records,error=error,control_streams_created=0,input_sent=false};
 }
}
'@
}
try{
 $page=$context.Client.GetAsync($context.BaseUri+'/default.htm').GetAwaiter().GetResult();$page.Dispose()
 $uri=[uri]($context.BaseUri+'/api/holographic/simulation/display/stream')
 $csrf=$context.Handler.CookieContainer.GetCookies($uri)['CSRF-Token'];if(-not $csrf){throw 'No authenticated CSRF session.'}
 $result=[Phase2DisplayCapture]::Read($context.Device.Address,$context.CertificateSha256,$context.Client.DefaultRequestHeaders.Authorization.ToString(),$context.Handler.CookieContainer.GetCookieHeader($uri),$csrf.Value,$folder,$Seconds).GetAwaiter().GetResult()
 $proof=@{run_id=$RunId;lease_run_id=$LeaseRunId;observed_at=[DateTimeOffset]::Now.ToString('o');device=$context.Device.DeviceName;ssh_fingerprint=$context.Device.HostFingerprint;certificate_sha256=$context.CertificateSha256;source='simulation-display';result=$result;visible_effect_verified=$false;audio_requested=$false}
 [IO.File]::WriteAllText($resultPath,($proof|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
 $proof|ConvertTo-Json -Depth 10
}finally{$context.Client.Dispose()}
