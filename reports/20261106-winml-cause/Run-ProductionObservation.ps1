$ErrorActionPreference='Stop'
$workspace=Split-Path -Parent (Split-Path -Parent $PSScriptRoot);$ops=Join-Path $workspace 'apps/field-app/ops'
$record=Join-Path $PSScriptRoot 'production-actions.jsonl'
if(Test-Path -LiteralPath $record){throw 'Production observation has already started; inspect its original process and run'}
function Record([string]$action,$value){@{at=[DateTimeOffset]::Now.ToString('o');action=$action;result=$value}|ConvertTo-Json -Depth 8 -Compress|Add-Content -LiteralPath $record -Encoding utf8NoBOM}
$lifecycle=Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'lifecycle56/result.json')|ConvertFrom-Json
$precision=Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'precision-device-verification.json')|ConvertFrom-Json
if(-not $lifecycle.Passed -or -not $precision.passed){throw 'Lifecycle or same-device numerical gate is incomplete'}
Record 'install_production' (& (Join-Path $ops 'Install-App.ps1') -PackageDirectory (Join-Path $workspace 'apps/field-app/.state/packages/20261106-152513-1.0.0.57') -Launch)
Record 'hardware_begin' (& (Join-Path $ops 'Invoke-GpuProbe.ps1') -RunId 'production57-ten-minutes' -Worker (Join-Path $workspace 'apps/field-app/.state/gpu-probe/32c76339e6174616b83132c44ce1536b/hl-gpu-probe.exe') -Seconds 600|ConvertFrom-Json)
& (Join-Path $ops 'Measure-YoloResources.ps1') -RunId 'production57-ten-minutes' -Seconds 600 -WarmupSeconds 10 -Rounds 1 -ExpectedVersion '1.0.0.57' -ExpectedModelSha256 'bf11d93c12fc6d24ff4cfd07a5fecaeb224c995b0f458c85c3d73149ea43c171' -OutputRoot (Join-Path $PSScriptRoot 'raw')
Record 'hardware_end' (& (Join-Path $ops 'Invoke-GpuProbe.ps1') -RunId 'production57-ten-minutes'|ConvertFrom-Json)
Record 'deployment_verified' (& (Join-Path $ops 'Verify-YoloDeployment.ps1') -RunId 'winml-production57-final'|ConvertFrom-Json)
Record 'completed' $true
