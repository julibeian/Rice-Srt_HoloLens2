$ErrorActionPreference='Stop'
$workspace=Split-Path -Parent (Split-Path -Parent $PSScriptRoot);$ops=Join-Path $workspace 'apps/field-app/ops'
$record=Join-Path $PSScriptRoot 'backend-actions.jsonl'
if(Test-Path -LiteralPath $record){throw 'Use original operation ids to inspect an interrupted backend comparison'}
function Record([string]$action,$value){@{at=[DateTimeOffset]::Now.ToString('o');action=$action;result=$value}|ConvertTo-Json -Depth 8 -Compress|Add-Content -LiteralPath $record -Encoding utf8NoBOM}
function Wait-Phase([string]$Phase){
 for($attempt=0;$attempt -lt 15;$attempt++){
  $runtime=& (Join-Path $ops 'Get-AppState.ps1')|ConvertFrom-Json
  $state=Get-Content -Raw -LiteralPath (Join-Path $runtime.Evidence 'app-state.json')|ConvertFrom-Json
  if($runtime.RuntimeVerified -and $state.nativeDetector.phase -ceq $Phase -and ($Phase -ne 'stopped' -or -not $state.nativeDetector.workerActive)){Record ('verified_'+$Phase) $state.nativeDetector;return}
  Start-Sleep -Milliseconds 200
 };throw ('Native phase not observed: '+$Phase)
}
try{
 Record 'stop_inference_keep_preview' (& (Join-Path $ops 'Invoke-CameraCheck.ps1') -Action dynamic_stop -RunId 'winml-backend-stop-01'|ConvertFrom-Json)
 Wait-Phase 'stopped'
 foreach($backend in @('cpu','gpu')){
  $worker=Join-Path $workspace $(if($backend -eq 'cpu'){'apps/field-app/.state/yolo-probe/arm64/20261106-144744-cpu/yolo-winml-probe.exe'}else{'apps/field-app/.state/yolo-probe/arm64/20261106-144933-gpu/yolo-winml-probe.exe'})
  $id='winml-backend-'+$backend+'-01'
  $result=& (Join-Path $ops 'Invoke-YoloProbe.ps1') -RunId $id -Worker $worker -Model (Join-Path $workspace 'apps/field-app/.state/yolo-320/model.onnx')|ConvertFrom-Json
  for($attempt=0;$result.Pending -and $attempt -lt 8;$attempt++){$result=& (Join-Path $ops 'Invoke-YoloProbe.ps1') -RunId $id|ConvertFrom-Json}
  Record $backend $result
  if($result.Pending){throw 'Backend observation still pending; do not run another backend concurrently'}
 }
}finally{Record 'resume_camera_inference' (& (Join-Path $ops 'Invoke-CameraCheck.ps1') -Action dynamic_start -RunId 'winml-backend-resume-01'|ConvertFrom-Json);Wait-Phase 'running'}
