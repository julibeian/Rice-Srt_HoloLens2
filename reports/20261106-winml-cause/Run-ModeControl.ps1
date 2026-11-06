$ErrorActionPreference='Stop'
$workspace=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$ops=Join-Path $workspace 'apps/field-app/ops';$holo=Join-Path $workspace 'apps/holographic-control/ops'
$record=Join-Path $PSScriptRoot 'mode-control-actions.jsonl'
if(Test-Path -LiteralPath $record){throw 'Inspect the existing mode control; do not replay it'}
function Record([string]$action,$value){@{at=[DateTimeOffset]::Now.ToString('o');action=$action;result=$value}|ConvertTo-Json -Depth 8 -Compress|Add-Content -LiteralPath $record -Encoding utf8NoBOM}
Record 'hardware_begin' (& (Join-Path $ops 'Invoke-GpuProbe.ps1') -RunId 'mode-cycle' -Worker (Join-Path $workspace 'apps/field-app/.state/gpu-probe/517824e2222b419faef1df442c687d83/hl-gpu-probe.exe') -Seconds 300|ConvertFrom-Json)
for($cycle=1;$cycle -le 2;$cycle++){
 $lease='winml-mode-only-20261106-'+$cycle
 try{
  Record ('mode1_begin_'+$cycle) (& (Join-Path $holo 'Control-Lease.ps1') -Mode Start -RunId $lease|ConvertFrom-Json)
  & (Join-Path $ops 'Measure-YoloResources.ps1') -RunId ('mode1-only-'+$cycle) -Seconds 45 -WarmupSeconds 5 -Rounds 1 -ExpectedVersion '1.0.0.49' -OutputRoot (Join-Path $PSScriptRoot 'raw')
 }finally{Record ('mode0_restore_'+$cycle) (& (Join-Path $holo 'Control-Lease.ps1') -Mode Stop -RunId $lease|ConvertFrom-Json)}
 & (Join-Path $ops 'Measure-YoloResources.ps1') -RunId ('mode0-return-'+$cycle) -Seconds 45 -WarmupSeconds 10 -Rounds 1 -ExpectedVersion '1.0.0.49' -OutputRoot (Join-Path $PSScriptRoot 'raw')
}
Record 'hardware_end' (& (Join-Path $ops 'Invoke-GpuProbe.ps1') -RunId 'mode-cycle'|ConvertFrom-Json)
Record 'completed' $true
