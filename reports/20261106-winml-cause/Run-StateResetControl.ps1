$ErrorActionPreference='Stop'
$workspace=Split-Path -Parent (Split-Path -Parent $PSScriptRoot);$ops=Join-Path $workspace 'apps/field-app/ops'
. (Join-Path $workspace 'apps/holographic-control/ops/Holographic.Common.ps1')
$folder=Join-Path $PSScriptRoot 'state-reset59'
if(Test-Path -LiteralPath $folder){throw 'One reset has already been started. Inspect its original restart record; never resend it.'}
[IO.Directory]::CreateDirectory($folder)|Out-Null
$record=Join-Path $folder 'actions.jsonl'
function Record([string]$action,$value){@{at=[DateTimeOffset]::Now.ToString('o');action=$action;result=$value}|ConvertTo-Json -Depth 10 -Compress|Add-Content -LiteralPath $record -Encoding utf8NoBOM}
function Snapshot([string]$Name){
 $context=New-HoloAuthenticatedPortalContext
 try{
  $state=[ordered]@{at=[DateTimeOffset]::Now.ToString('o');device=$context.Device.DeviceName;fingerprint=$context.Device.HostFingerprint;public_key=$context.PublicKeySha256}
  foreach($pair in @(@('mode','/api/holographic/simulation/control/mode'),@('mrc','/api/holographic/mrc/status'),@('power','/api/power/state'),@('battery','/api/power/battery'),@('systemperf','/api/resourcemanager/systemperf'),@('processes','/api/resourcemanager/processes'))){
   $response=$context.Client.GetAsync($context.BaseUri+$pair[1]).GetAwaiter().GetResult();try{$raw=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult();$state[$pair[0]]=@{status=[int]$response.StatusCode;body=($raw|ConvertFrom-Json)}}finally{$response.Dispose()}
  }
  $state|ConvertTo-Json -Depth 30|Set-Content -LiteralPath (Join-Path $folder ($Name+'.json')) -Encoding utf8NoBOM
  return $state
 }finally{$context.Client.Dispose()}
}
Record 'install_same_production_contents' (& (Join-Path $ops 'Install-App.ps1') -PackageDirectory (Join-Path $workspace 'apps/field-app/.state/packages/20261106-155806-1.0.0.59') -Launch)
$before=Snapshot 'before-active'
if($before.mode.status -ne 200 -or $before.mode.body.mode -ne 0 -or $before.mrc.status -ne 200 -or $before.mrc.body.IsRecording){throw 'Control mode is not Default or recording state is not clear; reset not sent'}
& (Join-Path $ops 'Measure-YoloResources.ps1') -RunId 'production59-before-reset' -Seconds 90 -WarmupSeconds 10 -Rounds 1 -ExpectedVersion '1.0.0.59' -ExpectedModelSha256 'bf11d93c12fc6d24ff4cfd07a5fecaeb224c995b0f458c85c3d73149ea43c171' -OutputRoot (Join-Path $PSScriptRoot 'raw')
Record 'hardware_before' (& (Join-Path $ops 'Invoke-GpuProbe.ps1') -RunId 'state-reset59-before' -Worker (Join-Path $workspace 'apps/field-app/.state/gpu-probe/32c76339e6174616b83132c44ce1536b/hl-gpu-probe.exe') -Seconds 2|ConvertFrom-Json)
Record 'stop_own_app' (& (Join-Path $ops 'Stop-App.ps1')|ConvertFrom-Json)
& (Join-Path $ops 'Measure-YoloIdle.ps1') -RunId 'state-reset59-before-idle' -Seconds 30
$idleBefore=Snapshot 'before-idle'
if($idleBefore.mode.body.mode -ne 0 -or $idleBefore.mrc.body.IsRecording){throw 'Mode/recording changed; reset not sent'}
$context=New-HoloAuthenticatedPortalContext
try{
 $page=$context.Client.GetAsync($context.BaseUri+'/default.htm').GetAwaiter().GetResult();try{if([int]$page.StatusCode -ne 200){throw 'Authenticated page unavailable'}}finally{$page.Dispose()}
 $uri=[uri]($context.BaseUri+'/api/control/restart');$cookie=$context.Handler.CookieContainer.GetCookies($uri)['CSRF-Token']
 if(-not $cookie){throw 'No CSRF cookie; reset not sent'}
 $request=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post,$uri)
 $request.Headers.Add('X-CSRF-Token',$cookie.Value);$request.Content=[Net.Http.ByteArrayContent]::new([byte[]]::new(0))
 $attempt=@{RunId='state-reset59-once';at=[DateTimeOffset]::Now.ToString('o');Device=$context.Device.DeviceName;Fingerprint=$context.Device.HostFingerprint;Attempted=$true;ReplayAllowed=$false}
 $attempt|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $folder 'restart.json') -Encoding utf8NoBOM
 try{$response=$context.Client.SendAsync($request).GetAwaiter().GetResult();try{Record 'restart_http_status' ([int]$response.StatusCode)}finally{$response.Dispose()}}catch{Record 'restart_response_interrupted' $_.Exception.GetType().Name}
 $request.Dispose()
}finally{$context.Client.Dispose()}
$watch=[Diagnostics.Stopwatch]::StartNew();$connected=$false
while($watch.Elapsed.TotalSeconds -lt 300){
 Start-Sleep -Seconds 5
 $context=$null
 try{$context=New-HoloAuthenticatedPortalContext;$response=$context.Client.GetAsync($context.BaseUri+'/api/os/info').GetAwaiter().GetResult();try{if([int]$response.StatusCode -eq 200){$connected=$true;Record 'original_identity_reconnected' @{device=$context.Device.DeviceName;fingerprint=$context.Device.HostFingerprint;seconds=$watch.Elapsed.TotalSeconds};break}}finally{$response.Dispose()}}catch{Record 'reconnect_pending' $_.Exception.GetType().Name}finally{if($context){$context.Client.Dispose()}}
}
if(-not $connected){throw 'Reset observation pending after bounded reconnect; do not resend the restart'}
$hardwareAfter=& (Join-Path $ops 'Invoke-GpuProbe.ps1') -RunId 'state-reset59-after' -Worker (Join-Path $workspace 'apps/field-app/.state/gpu-probe/32c76339e6174616b83132c44ce1536b/hl-gpu-probe.exe') -Seconds 2|ConvertFrom-Json
Record 'hardware_after' $hardwareAfter
$hardwareBefore=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'hardware/state-reset59-before/samples.jsonl')|Select-Object -First 1|ConvertFrom-Json
if($hardwareAfter.Latest.tickMs -ge $hardwareBefore.tickMs){throw 'Device uptime did not reset; do not claim a reboot or resend it'}
& (Join-Path $ops 'Measure-YoloIdle.ps1') -RunId 'state-reset59-after-idle' -Seconds 30
$idleAfter=Snapshot 'after-idle'
Record 'start_same_package_after_reset' (& (Join-Path $ops 'Start-App.ps1')|ConvertFrom-Json)
$after=Snapshot 'after-active'
& (Join-Path $ops 'Measure-YoloResources.ps1') -RunId 'production59-after-reset' -Seconds 600 -WarmupSeconds 10 -Rounds 1 -ExpectedVersion '1.0.0.59' -ExpectedModelSha256 'bf11d93c12fc6d24ff4cfd07a5fecaeb224c995b0f458c85c3d73149ea43c171' -OutputRoot (Join-Path $PSScriptRoot 'raw')
Record 'final_package_verified' (& (Join-Path $ops 'Verify-YoloDeployment.ps1') -RunId 'winml-production59-final'|ConvertFrom-Json)
Record 'completed' $true
