param([Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_-]{1,35}$')][string]$RunId,[string]$ExpectedVersion='1.0.0.64')
$ErrorActionPreference='Stop'
$appRoot=Split-Path -Parent $PSScriptRoot;$workspace=Split-Path -Parent (Split-Path -Parent $appRoot)
. (Join-Path $workspace 'apps/holographic-control/ops/Holographic.Common.ps1')
$runtime=& (Join-Path $PSScriptRoot 'Get-AppState.ps1')|ConvertFrom-Json
$initial=Get-Content -LiteralPath (Join-Path $runtime.Evidence 'app-state.json') -Raw|ConvertFrom-Json
if(-not $runtime.RuntimeVerified -or $runtime.RuntimeVersion -cne $ExpectedVersion -or -not $initial.cameraSession -or -not $initial.cameraTelemetry -or $initial.cameraTelemetry.previewMode -cne 'visible' -or $initial.nativeDetector.source -cne 'camera'){throw 'First deploy and verify the explicit diagnostic candidate with its live preview visible on the original device'}
$folder=Join-Path $workspace ('reports/20261106-winml-cause/preview-controls/'+$RunId)
if(Test-Path -LiteralPath $folder){throw 'Use a new RunId; inspect the original operation instead of replaying it'}
[IO.Directory]::CreateDirectory($folder)|Out-Null
$record=Join-Path $folder 'actions.jsonl';$summary=@()
function Record([string]$Action,$Result){@{at=[DateTimeOffset]::Now.ToString('o');action=$Action;result=$Result}|ConvertTo-Json -Depth 8 -Compress|Add-Content -LiteralPath $record -Encoding utf8NoBOM}
function Assert-DefaultMode{
 $context=New-HoloAuthenticatedPortalContext
 try{$response=$context.Client.GetAsync($context.BaseUri+'/api/holographic/simulation/control/mode').GetAwaiter().GetResult();try{$body=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult()|ConvertFrom-Json;if([int]$response.StatusCode -ne 200 -or $body.mode -ne 0){throw 'Keep the actual normal control mode fixed during this experiment'}}finally{$response.Dispose()}}finally{$context.Client.Dispose()}
}
function Wait-PreviewAck([string]$Id,[string]$Mode){
 for($attempt=0;$attempt -lt 8;$attempt++){
  $current=& (Join-Path $PSScriptRoot 'Get-AppState.ps1')|ConvertFrom-Json
  $observed=Get-Content -LiteralPath (Join-Path $current.Evidence 'app-state.json') -Raw|ConvertFrom-Json
  if(-not $current.RuntimeVerified -or $observed.runtimeSession -cne $initial.runtimeSession -or $observed.cameraSession -cne $initial.cameraSession -or $observed.nativeDetector.processId -ne $initial.nativeDetector.processId){throw 'The runtime changed; preserve this attempt'}
  if(@($observed.events|Where-Object {$_.event -ceq 'camera_check_error' -and $_.details.id -ceq $Id}).Count){throw 'The preview command failed; inspect the recorded error instead of resending it'}
  if(@($observed.events|Where-Object {$_.event -ceq 'camera_check_completed' -and $_.details.id -ceq $Id -and $_.details.camera.previewMode -ceq $Mode}).Count -and $observed.cameraTelemetry.previewMode -ceq $Mode){return Join-Path $current.Evidence 'app-state.json'}
 }
 throw 'Preview acknowledgement missing; do not resend the command'
}
$restorationVerified=$false
try{
 $index=0;$geometry=$null
 foreach($mode in @('visible','masked','visible')){
  $index++;$trial=$RunId+'-'+$index+'-'+$mode;Assert-DefaultMode
  $command=& (Join-Path $PSScriptRoot 'Invoke-CameraCheck.ps1') -Action performance_preview -PreviewMode $mode -RunId ($trial+'-command')|ConvertFrom-Json
  Record ($trial+'_command') $command
  Copy-Item -LiteralPath (Wait-PreviewAck $command.Id $mode) -Destination (Join-Path $folder ($trial+'-ack.json'))
  & (Join-Path $PSScriptRoot 'Measure-YoloResources.ps1') -RunId $trial -Seconds 75 -WarmupSeconds 5 -Rounds 1 -ExpectedVersion $ExpectedVersion -ExpectedModelSha256 $initial.nativeDetector.modelSha256 -ExpectedCameraKey '896x504@30' -ExpectedControlMode 0 -OutputRoot (Join-Path $folder 'raw')
  $rows=@(Get-Content -LiteralPath (Join-Path $folder ('raw/'+$trial+'/round-01.jsonl'))|ForEach-Object {$_|ConvertFrom-Json}|Where-Object measurement)
  $native=@($rows.app.body.nativeDetector|Sort-Object cameraFrames -Unique)
  $pixels=@($native.inputSignature|Select-Object -Unique)
  $observedGeometry=@($rows|ForEach-Object {$t=$_.app.body.cameraTelemetry;'{0},{1},{2},{3},{4},{5},{6}' -f $t.viewportWidth,$t.viewportHeight,$t.devicePixelRatio,$t.previewCssWidth,$t.previewCssHeight,$t.overlayPixelWidth,$t.overlayPixelHeight}|Select-Object -Unique)
  $invalidGeometry=@($rows|Where-Object {$t=$_.app.body.cameraTelemetry;$t.viewportWidth -le 0 -or $t.viewportHeight -le 0 -or $t.devicePixelRatio -le 0 -or $t.previewCssWidth -le 0 -or $t.previewCssHeight -le 0 -or $t.overlayPixelWidth -le 0 -or $t.overlayPixelHeight -le 0})
  for($rowIndex=1;$rowIndex -lt $rows.Count;$rowIndex++){if($rows[$rowIndex].app.body.nativeDetector.cameraFrames -lt $rows[$rowIndex-1].app.body.nativeDetector.cameraFrames){throw 'Frame counter moved backwards; raw observations preserved'}}
  if($rows.Count -ne 75 -or @($rows.app.body.cameraTelemetry.previewMode|Where-Object {$_ -cne $mode}).Count -or $native[-1].cameraFrames-$native[0].cameraFrames -lt 30 -or $pixels.Count -lt 10 -or $native[-1].frameTime -le $native[0].frameTime -or $observedGeometry.Count -ne 1 -or $invalidGeometry.Count){throw 'Invalid comparison: mode, fresh PV pixels/timestamps, or fixed geometry was not maintained; raw observations preserved'}
  if($geometry -and $observedGeometry[0] -cne $geometry){throw 'Window geometry changed between phases'};$geometry=$observedGeometry[0]
  $summary+=@{trial=$trial;mode=$mode;meanObservedInferenceMs=($native.inferenceMs|Measure-Object -Average).Average;cameraFrameDelta=$native[-1].cameraFrames-$native[0].cameraFrames;uniquePixelSignatures=$pixels.Count;geometry=$geometry}
  Record ($trial+'_valid') $summary[-1]
 }
}finally{
 try{
  $restore=& (Join-Path $PSScriptRoot 'Invoke-CameraCheck.ps1') -Action performance_preview -PreviewMode visible -RunId ($RunId+'-restore')|ConvertFrom-Json
  Record 'restore_visible' $restore
  Copy-Item -LiteralPath (Wait-PreviewAck $restore.Id 'visible') -Destination (Join-Path $folder 'restore-visible-ack.json')
  Assert-DefaultMode;$restorationVerified=$true;Record 'restore_verified' $true
 }catch{Record 'restore_observation_pending' $_.Exception.Message}
 # The diagnostic component independently restores visibility after 120 seconds.
}
if(-not $restorationVerified){throw 'Visible preview restoration could not be observed; retain this attempt and inspect the independent 120-second restoration before continuing'}
$summary|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $folder 'summary.json') -Encoding utf8NoBOM
Record 'completed' $true
