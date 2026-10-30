$ErrorActionPreference='Stop'
$workspace=Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$plan=Get-Content -LiteralPath (Join-Path $workspace 'docs\plans\20261027-phase2-hololens-control\任务状态.json') -Raw|ConvertFrom-Json
$folder=Join-Path $workspace 'docs\milestones\phase-2-hololens-control'
$path=Join-Path $folder 'capabilities.json'
if(Test-Path -LiteralPath $path){throw 'Capability register exists; update observations explicitly without resetting it.'}
[IO.Directory]::CreateDirectory($folder)|Out-Null
$entries=@(foreach($requirement in $plan.requirements){
    [ordered]@{id=$requirement.id;description=$requirement.description;priority=$requirement.priority;mandatory=($requirement.priority -in @('P0','P1'));acceptance=$requirement.acceptance;tasks=@($plan.tasks|Where-Object {$requirement.id -in $_.requirements}|ForEach-Object {$_.id});implementation='not_verified';acceptance_status='not_run';observations=@();scenarios=@('shell-and-settings','browser-2d','independent-business-2d','holographic-3d');boundaries=@()}
})
$result=[ordered]@{schema_version=1;scope='HoloLens whole-device visual operation and management';plan_ref='../../plans/20261027-phase2-hololens-control/任务状态.json';mandatory_priorities=@('P0','P1');historical_results_are_new_acceptance=$false;result_schema='../../../apps/pc-control/contracts/operation-result.schema.json';verification_layers=@('request','transport','device_state','visible_effect');routes=@(@{id='direct-sdk';role='candidate';status='cross_application_not_verified'},@{id='custom-legacy-adapter';role='candidate';status='historical_application_success_only'},@{id='official-gui';role='comparison';status='historical_video_success_input_unverified'},@{id='portal-virtual-input';role='candidate_text';status='not_probed'});capabilities=$entries}
[IO.File]::WriteAllText($path,($result|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
[ordered]@{path=$path;mandatory_requirements=@($entries|Where-Object mandatory).Count;count=$entries.Count}|ConvertTo-Json
