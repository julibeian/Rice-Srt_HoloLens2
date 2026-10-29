param([string]$RegisterPath)
$ErrorActionPreference='Stop'
$workspace=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if(-not $RegisterPath){$RegisterPath=Join-Path $workspace 'docs\plans\20261027-phase2-hololens-control\任务状态.json'}
$s=Get-Content -LiteralPath $RegisterPath -Raw|ConvertFrom-Json
foreach($pair in @(@{name='tasks';count=24},@{name='requirements';count=16},@{name='acceptance_cases';count=32})){
 $items=@($s.($pair.name));if($items.Count -ne $pair.count -or @($items.id|Sort-Object -Unique).Count -ne $pair.count){throw ('Unexpected register entries: '+$pair.name)}
}
$references=0
foreach($task in $s.tasks){
 if($task.status -notin $s.task_status_values){throw ('Invalid task status '+$task.id)}
 if($task.status -eq 'completed'){
  foreach($dependency in $task.requires){if(($s.tasks|Where-Object id -EQ $dependency).status -ne 'completed'){throw ('Unmet dependency '+$task.id+' -> '+$dependency)}}
  if(-not $task.artifacts.Count -or -not $task.evidence.Count){throw ('Completed task lacks artifacts or evidence: '+$task.id)}
 }
 foreach($reference in (@($task.artifacts)+@($task.evidence))){if(-not(Test-Path -LiteralPath ([IO.Path]::GetFullPath(([string]$reference).Split('#')[0],$workspace)))){throw ('Missing task reference '+$task.id+': '+$reference)};$references++}
}
foreach($milestone in $s.milestones){if($milestone.status -eq 'completed'){foreach($id in $milestone.tasks){if(($s.tasks|Where-Object id -EQ $id).status -ne 'completed'){throw ('Milestone completed prematurely: '+$milestone.id)}}}}
foreach($requirement in $s.requirements){
 if($requirement.status -eq 'completed'){foreach($id in $requirement.acceptance){if(($s.acceptance_cases|Where-Object id -EQ $id).status -ne 'passed'){throw ('Requirement completed before acceptance: '+$requirement.id)}}}
 foreach($reference in $requirement.evidence){if(-not(Test-Path -LiteralPath ([IO.Path]::GetFullPath(([string]$reference).Split('#')[0],$workspace)))){throw ('Missing requirement reference '+$requirement.id+': '+$reference)};$references++}
}
foreach($case in $s.acceptance_cases){
 if($case.status -notin $s.acceptance_status_values){throw ('Invalid acceptance status '+$case.id)}
 if($case.status -eq 'passed' -and (-not $case.runs.Count -or -not $case.evidence.Count)){throw ('Passed acceptance has no run evidence '+$case.id)}
 foreach($reference in $case.evidence){if(-not(Test-Path -LiteralPath ([IO.Path]::GetFullPath(([string]$reference).Split('#')[0],$workspace)))){throw ('Missing acceptance reference '+$case.id+': '+$reference)};$references++}
}
if(@($s.tasks|Where-Object id -EQ $s.next_task).Count -ne 1){throw 'Next task is not registered.'}
@{valid=$true;completed_tasks=@($s.tasks|Where-Object status -EQ completed).id;passed_acceptance=@($s.acceptance_cases|Where-Object status -EQ passed).id;checked_references=$references;next_task=$s.next_task}|ConvertTo-Json
