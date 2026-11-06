$ErrorActionPreference='Stop'
$workspace=Split-Path -Parent (Split-Path -Parent $PSScriptRoot);$ops=Join-Path $workspace 'apps/field-app/ops'
$record=Join-Path $PSScriptRoot 'heartbeat-control-actions.jsonl'
if(Test-Path -LiteralPath $record){throw 'Do not replay heartbeat controls; inspect the original process and trial'}
function Record([string]$action,$value){@{at=[DateTimeOffset]::Now.ToString('o');action=$action;result=$value}|ConvertTo-Json -Depth 7 -Compress|Add-Content -LiteralPath $record -Encoding utf8NoBOM}
Record 'install' (& (Join-Path $ops 'Install-App.ps1') -PackageDirectory (Join-Path $workspace 'apps/field-app/.state/packages/20261106-154656-1.0.0.58') -Launch)
$index=0
foreach($mode in @('log','off','counter','log')){
 $index++;$id='heartbeat58-'+$index+'-'+$mode
 $command=& (Join-Path $ops 'Invoke-CameraCheck.ps1') -Action performance_heartbeat -HeartbeatMode $mode -RunId ($id+'-command')|ConvertFrom-Json
 Record ($id+'_command') $command
 $ack=$false
 for($attempt=0;$attempt -lt 10;$attempt++){
  $runtime=& (Join-Path $ops 'Get-AppState.ps1')|ConvertFrom-Json;$state=Get-Content -Raw -LiteralPath (Join-Path $runtime.Evidence 'app-state.json')|ConvertFrom-Json
  if(@($state.events|Where-Object {$_.event -ceq 'camera_check_completed' -and $_.details.id -ceq $command.Id -and $_.details.heartbeatMode -ceq $mode}).Count){$ack=$true;Copy-Item -LiteralPath (Join-Path $runtime.Evidence 'app-state.json') -Destination (Join-Path $PSScriptRoot ($id+'-ack.json'));break}
  Start-Sleep -Milliseconds 200
 }
 if(-not $ack){throw 'The heartbeat change was not acknowledged; do not infer it from throughput'}
 & (Join-Path $ops 'Measure-YoloResources.ps1') -RunId $id -Seconds 75 -WarmupSeconds 5 -Rounds 1 -ExpectedVersion '1.0.0.58' -ExpectedModelSha256 'bf11d93c12fc6d24ff4cfd07a5fecaeb224c995b0f458c85c3d73149ea43c171' -ExpectedCameraKey '896x504@30' -OutputRoot (Join-Path $PSScriptRoot 'raw')
 Record ($id+'_complete') $true
}
Record 'completed' $true
