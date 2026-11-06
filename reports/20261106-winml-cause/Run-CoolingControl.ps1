$ErrorActionPreference='Stop'
$workspace=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$ops=Join-Path $workspace 'apps/field-app/ops'
$actions=Join-Path $PSScriptRoot 'cooling-actions.jsonl'
function Record([string]$action,$value){@{at=[DateTimeOffset]::Now.ToString('o');action=$action;result=$value}|ConvertTo-Json -Depth 6 -Compress|Add-Content -LiteralPath $actions -Encoding utf8NoBOM}
if(Test-Path -LiteralPath $actions){
 $prior=@(Get-Content -LiteralPath $actions|ForEach-Object {$_|ConvertFrom-Json})
 if($prior.Count -ne 1 -or $prior[0].action -cne 'stop_original'){throw 'Cooling control has already advanced; inspect original process and evidence'}
 Record 'resume_after_known_put_failure' 'The first attempt stopped the app then failed before hardware probe launch; no measurement has started.'
}else{Record 'stop_original' (& (Join-Path $ops 'Stop-App.ps1')|ConvertFrom-Json)}
Record 'hardware_begin' (& (Join-Path $ops 'Invoke-GpuProbe.ps1') -RunId 'cooling-load-cycle' -Worker (Join-Path $workspace 'apps/field-app/.state/gpu-probe/517824e2222b419faef1df442c687d83/hl-gpu-probe.exe') -Seconds 380|ConvertFrom-Json)
& (Join-Path $ops 'Measure-YoloIdle.ps1') -RunId 'original-off-cool-01' -Seconds 120
Record 'start_original' (& (Join-Path $ops 'Start-App.ps1')|ConvertFrom-Json)
& (Join-Path $ops 'Measure-YoloResources.ps1') -RunId 'original-after-cool-01' -Seconds 180 -WarmupSeconds 0 -Rounds 1 -OutputRoot (Join-Path $PSScriptRoot 'raw')
Record 'hardware_end' (& (Join-Path $ops 'Invoke-GpuProbe.ps1') -RunId 'cooling-load-cycle'|ConvertFrom-Json)
Record 'completed' $true
