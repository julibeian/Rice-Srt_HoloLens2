$ErrorActionPreference='Stop'
$workspace=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$ops=Join-Path $workspace 'apps/field-app/ops';$holo=Join-Path $workspace 'apps/holographic-control/ops'
$record=Join-Path $PSScriptRoot 'gpu-contention-actions.jsonl'
if(Test-Path -LiteralPath $record){throw 'Do not replay a started contention control'}
function Record([string]$action,$value){@{at=[DateTimeOffset]::Now.ToString('o');action=$action;result=$value}|ConvertTo-Json -Depth 8 -Compress|Add-Content -LiteralPath $record -Encoding utf8NoBOM}
Record 'hardware_begin' (& (Join-Path $ops 'Invoke-GpuProbe.ps1') -RunId 'gpu-contention-cycle' -Worker (Join-Path $workspace 'apps/field-app/.state/gpu-probe/2ee51da9689c4d36a34cbbbe8942b0f2/hl-gpu-probe.exe') -Seconds 160|ConvertFrom-Json)
& (Join-Path $ops 'Measure-YoloResources.ps1') -RunId 'gpu-contention-mode0-a' -Seconds 30 -WarmupSeconds 5 -Rounds 1 -ExpectedVersion '1.0.0.50' -OutputRoot (Join-Path $PSScriptRoot 'raw')
$lease='winml-gpu-contention-20261106'
try{
 Record 'mode1_begin' (& (Join-Path $holo 'Control-Lease.ps1') -Mode Start -RunId $lease|ConvertFrom-Json)
 & (Join-Path $ops 'Measure-YoloResources.ps1') -RunId 'gpu-contention-mode1-b' -Seconds 30 -WarmupSeconds 5 -Rounds 1 -ExpectedVersion '1.0.0.50' -OutputRoot (Join-Path $PSScriptRoot 'raw')
}finally{Record 'mode0_restore' (& (Join-Path $holo 'Control-Lease.ps1') -Mode Stop -RunId $lease|ConvertFrom-Json)}
& (Join-Path $ops 'Measure-YoloResources.ps1') -RunId 'gpu-contention-mode0-a2' -Seconds 30 -WarmupSeconds 5 -Rounds 1 -ExpectedVersion '1.0.0.50' -OutputRoot (Join-Path $PSScriptRoot 'raw')
Record 'hardware_end' (& (Join-Path $ops 'Invoke-GpuProbe.ps1') -RunId 'gpu-contention-cycle'|ConvertFrom-Json)
Record 'completed' $true
