$ErrorActionPreference='Stop'
$workspace=Split-Path -Parent (Split-Path -Parent $PSScriptRoot);$ops=Join-Path $workspace 'apps/field-app/ops'
. (Join-Path $workspace 'apps/holographic-control/ops/Holographic.Common.ps1')
$folder=Join-Path $PSScriptRoot 'state-reset59';$record=Join-Path $folder 'actions.jsonl'
$restart=Get-Content -Raw -LiteralPath (Join-Path $folder 'restart.json')|ConvertFrom-Json
if(-not $restart.Attempted -or $restart.ReplayAllowed -or (Test-Path -LiteralPath (Join-Path $folder 'resume.json'))){throw 'Invalid or already-started continuation; inspect the original operation without replay'}
@{at=[DateTimeOffset]::Now.ToString('o');restart_replayed=$false;reason='Initial observation stopped after verified reboot, during startup TLS certificate renewal. Pinned original public key and credentials verified again.'}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $folder 'resume.json') -Encoding utf8NoBOM
function Record([string]$action,$value){@{at=[DateTimeOffset]::Now.ToString('o');action=$action;result=$value}|ConvertTo-Json -Depth 10 -Compress|Add-Content -LiteralPath $record -Encoding utf8NoBOM}
function Snapshot([string]$Name){
 $context=New-HoloAuthenticatedPortalContext
 try{
  $state=[ordered]@{at=[DateTimeOffset]::Now.ToString('o');device=$context.Device.DeviceName;fingerprint=$context.Device.HostFingerprint;public_key=$context.PublicKeySha256}
  foreach($pair in @(@('mode','/api/holographic/simulation/control/mode'),@('mrc','/api/holographic/mrc/status'),@('power','/api/power/state'),@('battery','/api/power/battery'),@('systemperf','/api/resourcemanager/systemperf'),@('processes','/api/resourcemanager/processes'))){
   $response=$context.Client.GetAsync($context.BaseUri+$pair[1]).GetAwaiter().GetResult();try{$raw=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult();$state[$pair[0]]=@{status=[int]$response.StatusCode;body=($raw|ConvertFrom-Json)}}finally{$response.Dispose()}
  }
  $state|ConvertTo-Json -Depth 30|Set-Content -LiteralPath (Join-Path $folder ($Name+'.json')) -Encoding utf8NoBOM;return $state
 }finally{$context.Client.Dispose()}
}
$hardwareAfter=& (Join-Path $ops 'Invoke-GpuProbe.ps1') -RunId 'state-reset59-resume-snapshot' -Worker (Join-Path $workspace 'apps/field-app/.state/gpu-probe/32c76339e6174616b83132c44ce1536b/hl-gpu-probe.exe') -Seconds 2|ConvertFrom-Json
Record 'hardware_after_resume' $hardwareAfter
$hardwareBefore=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'hardware/state-reset59-before/samples.jsonl')|Select-Object -First 1|ConvertFrom-Json
if($hardwareAfter.Latest.tickMs -ge $hardwareBefore.tickMs){throw 'Expected boot uptime reset is missing'}
& (Join-Path $ops 'Measure-YoloIdle.ps1') -RunId 'state-reset59-after-idle-resume' -Seconds 30
$idleAfter=Snapshot 'after-idle'
if($idleAfter.mode.body.mode -ne 0 -or $idleAfter.fingerprint -cne $restart.Fingerprint){throw 'Unexpected control mode or original identity'}
Record 'start_same_package_after_reset' (& (Join-Path $ops 'Start-App.ps1')|ConvertFrom-Json)
$after=Snapshot 'after-active'
Record 'hardware_long_begin' (& (Join-Path $ops 'Invoke-GpuProbe.ps1') -RunId 'production59-postboot-clock' -Worker (Join-Path $workspace 'apps/field-app/.state/gpu-probe/32c76339e6174616b83132c44ce1536b/hl-gpu-probe.exe') -Seconds 600|ConvertFrom-Json)
& (Join-Path $ops 'Measure-YoloResources.ps1') -RunId 'production59-after-reset' -Seconds 600 -WarmupSeconds 10 -Rounds 1 -ExpectedVersion '1.0.0.59' -ExpectedModelSha256 'bf11d93c12fc6d24ff4cfd07a5fecaeb224c995b0f458c85c3d73149ea43c171' -OutputRoot (Join-Path $PSScriptRoot 'raw')
Record 'hardware_long_end' (& (Join-Path $ops 'Invoke-GpuProbe.ps1') -RunId 'production59-postboot-clock'|ConvertFrom-Json)
Record 'final_package_verified' (& (Join-Path $ops 'Verify-YoloDeployment.ps1') -RunId 'winml-production59-final'|ConvertFrom-Json)
$final=Snapshot 'final-active'
Record 'completed' $true
