param(
 [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_-]{1,64}$')][string]$RunId,
 [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_-]{1,64}$')][string]$LeaseRunId,
 [ValidateRange(5,30)][int]$Seconds=20,
 [switch]$AdditionalView
)
$ErrorActionPreference='Stop'
$workspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$folder=Join-Path $workspace ('reports/phase2-full-control/'+$RunId)
$resultPath=Join-Path $folder 'result.json'
if(Test-Path -LiteralPath $resultPath){$original=Get-Content -Raw -LiteralPath (Join-Path $folder 'request.json')|ConvertFrom-Json;if($original.run -cne $RunId -or $original.lease -cne $LeaseRunId -or $original.additional_view -ne [bool]$AdditionalView -or $original.seconds -ne $Seconds){throw 'RunId belongs to different simulation-view parameters; no replay.'};Get-Content -Raw -LiteralPath $resultPath;return}
if(Test-Path -LiteralPath $folder){throw 'Partial view experiment exists; do not replay.'}
$guard=& (Join-Path $workspace 'holographic-control/ops/Control-Lease.ps1') -Mode Status -RunId $LeaseRunId|ConvertFrom-Json
if(-not $guard.Active){throw 'Active named protection is required'}
$invocation=Get-Content -Raw -LiteralPath (Join-Path $guard.Evidence 'invocation.json')|ConvertFrom-Json
$remaining=([DateTimeOffset]::Parse($invocation.At).AddSeconds($invocation.LeaseSeconds)-[DateTimeOffset]::Now).TotalSeconds
if($remaining -lt $Seconds+30){throw 'Insufficient remaining protection for this experiment; do not start a partial sample.'}
. (Join-Path $workspace 'holographic-control/ops/Holographic.Common.ps1')
$context=New-HoloAuthenticatedPortalContext
[IO.Directory]::CreateDirectory($folder)|Out-Null
$utf8=[Text.UTF8Encoding]::new($false)
@{at=[DateTimeOffset]::Now.ToString('o');run=$RunId;lease=$LeaseRunId;additional_view=[bool]$AdditionalView;seconds=$Seconds;input_sent=$false;independent_mrc_requested=$false}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $folder 'request.json')
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;
public static class HoloSimulationViews {
 public static async Task<object> Read(string address,string pin,string authorization,string cookie,string csrf,string folder,int seconds,bool additional){
  byte[] descriptor=null;var records=new List<object>();var files=new Dictionary<int,FileStream>();long total=0;bool closeSent=false,closeReceived=false;string error=null;double elapsed=0;
  using(var socket=new ClientWebSocket())using(var budget=new CancellationTokenSource(TimeSpan.FromSeconds(seconds+10))){
   socket.Options.Proxy=null;socket.Options.RemoteCertificateValidationCallback=(s,c,h,e)=>c!=null&&c.GetCertHashString(HashAlgorithmName.SHA256)==pin;
   socket.Options.SetRequestHeader("Authorization",authorization);socket.Options.SetRequestHeader("Cookie",cookie);socket.Options.SetRequestHeader("X-CSRF-Token",csrf);socket.Options.SetRequestHeader("Origin","https://"+address);
   Task stop=null;var clock=new Stopwatch();
   try{
    await socket.ConnectAsync(new Uri("wss://"+address+"/api/holographic/simulation/display/stream?additionalView="+(additional?"true":"false")),budget.Token);
    clock.Start();stop=Task.Run(async()=>{await Task.Delay(seconds*1000,budget.Token);await socket.CloseOutputAsync(WebSocketCloseStatus.NormalClosure,"bounded view experiment ended",budget.Token);closeSent=true;});
    byte[] buffer=new byte[65536];int expected=-1,view=-1,flags=0;
    while(total<67108864&&records.Count<5000){
     using(var message=new MemoryStream()){
      WebSocketReceiveResult part;
      do{part=await socket.ReceiveAsync(new ArraySegment<byte>(buffer),budget.Token);if(part.MessageType==WebSocketMessageType.Close){closeReceived=true;break;}if(part.MessageType!=WebSocketMessageType.Binary||message.Length+part.Count>8388608)throw new InvalidDataException("Unknown or oversized display payload");message.Write(buffer,0,part.Count);}while(!part.EndOfMessage);
      if(closeReceived)break;byte[] bytes=message.ToArray();
      if(descriptor==null){if(bytes.Length!=16)throw new InvalidDataException("Unknown display descriptor");descriptor=bytes;File.WriteAllBytes(Path.Combine(folder,"descriptor.bin"),bytes);continue;}
      if(expected<0){if(bytes.Length!=8)throw new InvalidDataException("Unknown texture header");view=BitConverter.ToUInt16(bytes,0);flags=BitConverter.ToUInt16(bytes,2);expected=BitConverter.ToInt32(bytes,4);if(view>3||expected<=0||expected>8388608)throw new InvalidDataException("Invalid view or texture bound");continue;}
      if(bytes.Length!=expected||bytes.Length<4||bytes[0]!=0||bytes[1]!=0||bytes[2]!=0||bytes[3]!=1)throw new InvalidDataException("Texture is not declared Annex B");
      double received=clock.Elapsed.TotalMilliseconds;FileStream output;
      if(!files.TryGetValue(view,out output)){output=new FileStream(Path.Combine(folder,"view-"+view+".h264"),FileMode.CreateNew,FileAccess.Write,FileShare.Read);files.Add(view,output);}
      output.Write(bytes,0,bytes.Length);total+=bytes.Length;records.Add(new{view=view,flags=flags,bytes=bytes.Length,received_ms=received});expected=-1;
     }
    }
   }catch(Exception e){error=e.GetType().Name+": "+e.Message;}
   finally{
    elapsed=clock.Elapsed.TotalSeconds;
    if(stop!=null&&!stop.IsCompleted)budget.Cancel();if(stop!=null)try{await stop;}catch{}
    if(!closeSent&&(socket.State==WebSocketState.Open||socket.State==WebSocketState.CloseReceived))try{using(var finish=new CancellationTokenSource(2000)){await socket.CloseOutputAsync(WebSocketCloseStatus.NormalClosure,"view cleanup",finish.Token);closeSent=true;}}catch{}
    foreach(var output in files.Values)output.Dispose();
   }
  }
  return new{descriptorHex=descriptor==null?null:Convert.ToHexString(descriptor),bytes=total,seconds=elapsed,closeSent=closeSent,closeReceived=closeReceived,error=error,records=records};
 }
}
'@
try{
 $page=$context.Client.GetAsync($context.BaseUri+'/default.htm').GetAwaiter().GetResult();$page.Dispose()
 $uri=[uri]($context.BaseUri+'/api/holographic/simulation/display/stream');$csrf=$context.Handler.CookieContainer.GetCookies($uri)['CSRF-Token'];if(-not $csrf){throw 'No authenticated CSRF session'}
 $capture=[HoloSimulationViews]::Read($context.Device.Address,$context.CertificateSha256,$context.Client.DefaultRequestHeaders.Authorization.ToString(),$context.Handler.CookieContainer.GetCookieHeader($uri),$csrf.Value,$folder,$Seconds,[bool]$AdditionalView).GetAwaiter().GetResult()
 [IO.File]::WriteAllText((Join-Path $folder 'capture.json'),($capture|ConvertTo-Json -Depth 9),$utf8)
 $runtime=Get-Content -Raw -LiteralPath (Join-Path $workspace 'pc-control/dist/runtime.json')|ConvertFrom-Json;$ffprobe=Join-Path (Split-Path -Parent $runtime.Ffmpeg) 'ffprobe.exe'
 $views=@(foreach($group in @($capture.records|Group-Object view)){
  $id=[int]$group.Name;$file=Join-Path $folder ('view-'+$id+'.h264');$text=& $ffprobe -v error -count_frames -show_entries stream=codec_name,width,height,nb_read_frames -of json $file 2> (Join-Path $folder ('view-'+$id+'-decode-errors.txt'));$code=$LASTEXITCODE
  $media=$text|ConvertFrom-Json;[IO.File]::WriteAllText((Join-Path $folder ('view-'+$id+'-media.json')),($media|ConvertTo-Json -Depth 7),$utf8)
  $records=@($group.Group);$start=[double]$records[0].received_ms+3000;$end=[double]$records[-1].received_ms;$steady=@($records|Where-Object {$_.received_ms -gt $start})
  $decoded=0;$width=0;$height=0;$stream=@($media.streams)|Select-Object -First 1
  if($stream){if($stream.PSObject.Properties['nb_read_frames']){[void][int]::TryParse([string]$stream.nb_read_frames,[ref]$decoded)};if($stream.PSObject.Properties['width']){$width=[int]$stream.width};if($stream.PSObject.Properties['height']){$height=[int]$stream.height}}
  $decoderClean=(Get-Item -LiteralPath (Join-Path $folder ('view-'+$id+'-decode-errors.txt'))).Length -eq 0
  $consistent=$code -eq 0 -and $decoderClean -and $decoded -eq $records.Count -and $end-$start -ge 1000 -and $width -gt 0 -and $height -gt 0
  @{view=$id;decoded=$decoded;texture_messages=$records.Count;decoded_count_matches=$consistent;decoder_clean=$decoderClean;steady_fps=if($consistent){$steady.Count*1000/($end-$start)}else{$null};width=$width;height=$height;bytes=(Get-Item -LiteralPath $file).Length;sha256=(Get-FileHash -LiteralPath $file).Hash;ui_verified=$false}
 })
 $proof=@{at=[DateTimeOffset]::Now.ToString('o');run_id=$RunId;lease_run_id=$LeaseRunId;additional_view=[bool]$AdditionalView;source='simulation-display';views=$views;close_sent=$capture.closeSent;close_received=$capture.closeReceived;error=$capture.error;independent_mrc_requested=$false;input_sent=$false;visible_effect_verified=$false;capture='capture.json'}
 [IO.File]::WriteAllText($resultPath,($proof|ConvertTo-Json -Depth 8),$utf8);$proof|ConvertTo-Json -Depth 7
}finally{$context.Client.Dispose()}
