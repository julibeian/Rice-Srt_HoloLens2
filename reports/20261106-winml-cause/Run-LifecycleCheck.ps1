$ErrorActionPreference='Stop'
$workspace=Split-Path -Parent (Split-Path -Parent $PSScriptRoot);$ops=Join-Path $workspace 'apps/field-app/ops'
$folder=Join-Path $PSScriptRoot 'lifecycle56'
if(Test-Path -LiteralPath $folder){throw 'Inspect the existing lifecycle operations; do not replay them'}
[IO.Directory]::CreateDirectory($folder)|Out-Null
function Snapshot([string]$Name){
 $runtime=& (Join-Path $ops 'Get-AppState.ps1')|ConvertFrom-Json
 if(-not $runtime.RuntimeVerified -or $runtime.RuntimeVersion -cne '1.0.0.56'){throw 'Current diagnostic runtime is not verified'}
 $path=Join-Path $runtime.Evidence 'app-state.json';$state=Get-Content -Raw -LiteralPath $path|ConvertFrom-Json
 Copy-Item -LiteralPath $path -Destination (Join-Path $folder ($Name+'.json'))
 return $state
}
$before=Snapshot 'before'
& (Join-Path $ops 'Invoke-CameraCheck.ps1') -Action dynamic_stop -RunId 'winml-lifecycle-stop56'|Set-Content -LiteralPath (Join-Path $folder 'stop-command.json') -Encoding utf8NoBOM
$stopped=$null
for($i=0;$i -lt 12;$i++){$current=Snapshot ('stopping-'+$i);if($current.nativeDetector.phase -ceq 'stopped' -and -not $current.nativeDetector.workerActive -and -not $current.nativeDetector.modelLoaded){$stopped=$current;break};Start-Sleep -Milliseconds 200}
if(-not $stopped){throw 'Actual model/thread release was not observed'}
Start-Sleep -Seconds 3
$preview=Snapshot 'stopped-preview'
if(-not $preview.cameraPreviewReady -or $preview.cameraTelemetry.decodedFrames -le $stopped.cameraTelemetry.decodedFrames -or $preview.nativeDetector.cameraFrames -ne $stopped.nativeDetector.cameraFrames){throw 'Preview persistence or stopped inference was not verified'}
& (Join-Path $ops 'Invoke-CameraCheck.ps1') -Action dynamic_start -RunId 'winml-lifecycle-resume56'|Set-Content -LiteralPath (Join-Path $folder 'start-command.json') -Encoding utf8NoBOM
for($i=0;$i -lt 12;$i++){$resumed=Snapshot ('resuming-'+$i);if($resumed.nativeDetector.phase -ceq 'running' -and $resumed.nativeDetector.cameraFrames -gt 0){break};Start-Sleep -Milliseconds 200}
if($resumed.nativeDetector.phase -cne 'running' -or $resumed.nativeDetector.cameraFrames -le 0 -or $resumed.runtimeSession -cne $before.runtimeSession){throw 'Same-session fresh-frame reload not verified'}
& (Join-Path $ops 'Measure-YoloResources.ps1') -RunId 'reload56-continuous' -Seconds 40 -WarmupSeconds 0 -Rounds 1 -ExpectedVersion '1.0.0.56' -ExpectedModelSha256 'bf11d93c12fc6d24ff4cfd07a5fecaeb224c995b0f458c85c3d73149ea43c171' -OutputRoot (Join-Path $PSScriptRoot 'raw')
$final=Snapshot 'after'
if($final.nativeDetector.cameraFrames -lt 30){throw 'Less than 30 new camera frames after reload'}
@{Passed=$true;RuntimeSession=$final.runtimeSession;ProcessId=$final.nativeDetector.processId;ModelReleased=$true;WorkerReleased=$true;PreviewAdvancedWhileStopped=$true;CameraFramesAfterReload=$final.nativeDetector.cameraFrames}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $folder 'result.json') -Encoding utf8NoBOM
