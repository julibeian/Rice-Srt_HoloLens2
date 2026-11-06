param([Parameter(Mandatory)][ValidatePattern('^[a-z0-9-]{1,35}$')][string]$RunId)
$ErrorActionPreference='Stop'
$workspace=Split-Path -Parent (Split-Path -Parent $PSScriptRoot);$ops=Join-Path $workspace 'apps/field-app/ops'
$folder=Join-Path $PSScriptRoot ('asset-checks/'+$RunId)
if(Test-Path -LiteralPath $folder){throw 'Use a fresh RunId; do not replay sample submissions'}
[IO.Directory]::CreateDirectory($folder)|Out-Null
$results=@()
try{
 foreach($name in @('bacterial_blight_0.jpg','brown_spot_0.jpg','rice_blast_0.jpg','rice_water_weevil_0.jpg')){
  $runtime=& (Join-Path $ops 'Get-AppState.ps1')|ConvertFrom-Json;$before=Get-Content -Raw -LiteralPath (Join-Path $runtime.Evidence 'app-state.json')|ConvertFrom-Json
  $command=& (Join-Path $ops 'Invoke-CameraCheck.ps1') -Action dynamic_asset -Asset $name -RunId ($RunId+'-'+$results.Count)|ConvertFrom-Json
  $complete=$false
  for($attempt=0;$attempt -lt 12;$attempt++){
   Start-Sleep -Milliseconds 500
   $runtime=& (Join-Path $ops 'Get-AppState.ps1')|ConvertFrom-Json;$state=Get-Content -Raw -LiteralPath (Join-Path $runtime.Evidence 'app-state.json')|ConvertFrom-Json
   $native=$state.nativeDetector
   if($runtime.RuntimeVerified -and $state.runtimeSession -ceq $before.runtimeSession -and $native.frames -gt $before.nativeDetector.frames -and $native.source -ceq 'diagnostic_asset' -and -not $native.busy -and @($state.events|Where-Object {$_.event -ceq 'camera_check_completed' -and $_.details.id -ceq $command.Id}).Count){$complete=$true;break}
  }
  if(-not $complete){throw ('No bound diagnostic result for '+$name+'; inspect original command')}
  Copy-Item -LiteralPath (Join-Path $runtime.Evidence 'app-state.json') -Destination (Join-Path $folder ($name+'.json'))
  $results+=@{name=$name;runtime_session=$state.runtimeSession;native=$native;command=$command};Write-Output ($name+' : '+$native.detections.Count+' boxes, '+$native.inferenceMs+' ms')
 }
 $results|ConvertTo-Json -Depth 9|Set-Content -LiteralPath (Join-Path $folder 'results.json') -Encoding utf8NoBOM
}finally{& (Join-Path $ops 'Invoke-CameraCheck.ps1') -Action dynamic_start -RunId ($RunId+'-resume')|Out-Null}
