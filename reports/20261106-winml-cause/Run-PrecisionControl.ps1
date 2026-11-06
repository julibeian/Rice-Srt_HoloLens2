$ErrorActionPreference='Stop'
$workspace=Split-Path -Parent (Split-Path -Parent $PSScriptRoot);$ops=Join-Path $workspace 'apps/field-app/ops'
$record=Join-Path $PSScriptRoot 'precision-control-actions.jsonl'
if(Test-Path -LiteralPath $record){throw 'Inspect the existing process and trials instead of replaying a precision control'}
function Record([string]$action,$value){@{at=[DateTimeOffset]::Now.ToString('o');action=$action;result=$value}|ConvertTo-Json -Depth 7 -Compress|Add-Content -LiteralPath $record -Encoding utf8NoBOM}
$trials=@(
 @{id='fp16-cached52-before';package='20261106-151156-1.0.0.52';version='1.0.0.52';model='bf11d93c12fc6d24ff4cfd07a5fecaeb224c995b0f458c85c3d73149ea43c171'},
 @{id='fp32-cached54-control';package='20261106-151311-1.0.0.54';version='1.0.0.54';model='e6b6d2f6baaae3b7970f1a4e425f2c2347a90fe6aab34c3da0aed738fcf1b048'},
 @{id='fp16-cached52-after';package='20261106-151156-1.0.0.52';version='1.0.0.52';model='bf11d93c12fc6d24ff4cfd07a5fecaeb224c995b0f458c85c3d73149ea43c171'}
)
foreach($trial in $trials){
 $package=Join-Path $workspace ('apps/field-app/.state/packages/'+$trial.package)
 $proof=Get-Content -LiteralPath (Join-Path $package 'package-evidence.json') -Raw|ConvertFrom-Json
 if($proof.NativeDllSha256 -cne 'AE864881DE50C7F88EED3585D635A62135070FE79189150D64EA93D14E242CB7' -or $proof.ModelSha256 -cne $trial.model){throw 'Controlled binary/model identity differs'}
 Record ($trial.id+'_install') (& (Join-Path $ops 'Install-App.ps1') -PackageDirectory $package -Launch)
 & (Join-Path $ops 'Measure-YoloResources.ps1') -RunId $trial.id -Seconds 90 -WarmupSeconds 10 -Rounds 1 -ExpectedVersion $trial.version -ExpectedModelSha256 $trial.model -ExpectedCameraKey '896x504@30' -OutputRoot (Join-Path $PSScriptRoot 'raw')
 Record ($trial.id+'_completed') $true
}
Record 'completed' $true
