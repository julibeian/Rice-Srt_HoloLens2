$ErrorActionPreference='Stop'
$workspace=Split-Path -Parent (Split-Path -Parent $PSScriptRoot);$ops=Join-Path $workspace 'apps/field-app/ops'
$record=Join-Path $PSScriptRoot 'alternating-actions.jsonl'
if(Test-Path -LiteralPath $record){throw 'Inspect the existing alternating comparison instead of replaying it'}
function Record([string]$action,$value){@{at=[DateTimeOffset]::Now.ToString('o');action=$action;result=$value}|ConvertTo-Json -Depth 7 -Compress|Add-Content -LiteralPath $record -Encoding utf8NoBOM}
$trials=@(
 @{id='ab60-original-1';package='20261106-163135-1.0.0.60';version='1.0.0.60';model='e6b6d2f6baaae3b7970f1a4e425f2c2347a90fe6aab34c3da0aed738fcf1b048'},
 @{id='ab61-improved-1';package='20261106-163105-1.0.0.61';version='1.0.0.61';model='bf11d93c12fc6d24ff4cfd07a5fecaeb224c995b0f458c85c3d73149ea43c171'},
 @{id='ab62-original-2';package='20261106-163146-1.0.0.62';version='1.0.0.62';model='e6b6d2f6baaae3b7970f1a4e425f2c2347a90fe6aab34c3da0aed738fcf1b048'},
 @{id='ab63-improved-2';package='20261106-163211-1.0.0.63';version='1.0.0.63';model='bf11d93c12fc6d24ff4cfd07a5fecaeb224c995b0f458c85c3d73149ea43c171'}
)
foreach($trial in $trials){
 $package=Join-Path $workspace ('apps/field-app/.state/packages/'+$trial.package)
 $proof=Get-Content -LiteralPath (Join-Path $package 'package-evidence.json') -Raw|ConvertFrom-Json
 if($proof.Version -cne $trial.version -or $proof.ModelSha256 -cne $trial.model){throw 'Controlled package identity differs'}
 Record ($trial.id+'_install') (& (Join-Path $ops 'Install-App.ps1') -PackageDirectory $package -Launch)
 & (Join-Path $ops 'Measure-YoloResources.ps1') -RunId $trial.id -Seconds 120 -WarmupSeconds 15 -Rounds 1 -ExpectedVersion $trial.version -ExpectedModelSha256 $trial.model -ExpectedCameraKey '896x504@30' -OutputRoot (Join-Path $PSScriptRoot 'raw')
 Record ($trial.id+'_completed') $true
}
Record 'completed' $true
