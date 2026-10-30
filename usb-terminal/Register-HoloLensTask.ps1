. (Join-Path $PSScriptRoot 'HoloLens.Common.ps1')
$taskService=New-Object -ComObject Schedule.Service
$taskService.Connect()
$taskFolder=$taskService.GetFolder('\')
$taskName=$script:HlConfig.ScheduledTaskName
$watchdog=Join-Path $PSScriptRoot 'HoloLens.Watchdog.ps1'
$powerShell=Join-Path $script:HlRoot 'runtime\powershell\pwsh.exe'
if(-not (Test-Path -LiteralPath $powerShell)){throw 'The dedicated PowerShell runtime is missing.'}
$existing=$null
try{$existing=$taskFolder.GetTask($taskName)}catch{}
if($existing){
    $existingAction=$existing.Definition.Actions.Item(1)
    if($existingAction.Path -ne $powerShell -or $existingAction.Arguments -notmatch [regex]::Escape($watchdog)){
        throw 'A different application owns this scheduled task name. Refusing to replace it.'
    }
    [IO.File]::WriteAllText((Join-Path $script:HlStateDirectory 'scheduled-task.previous.xml'),$existing.Xml)
}
$task=$taskService.NewTask(0)
$task.RegistrationInfo.Description='Maintain the paired HoloLens USB SSH channel as the current Windows user. No password and no elevation.'
$task.Principal.UserId=$script:HlUserSid
$task.Principal.LogonType=3
$task.Principal.RunLevel=0
$task.Settings.Enabled=$true
$task.Settings.AllowDemandStart=$true
$task.Settings.StartWhenAvailable=$true
$task.Settings.DisallowStartIfOnBatteries=$false
$task.Settings.StopIfGoingOnBatteries=$false
$task.Settings.ExecutionTimeLimit='PT0S'
$task.Settings.MultipleInstances=2
$task.Settings.RestartInterval='PT1M'
$task.Settings.RestartCount=999
$task.Settings.Hidden=$false
$trigger=$task.Triggers.Create(9)
$trigger.UserId=$script:HlUserSid
$trigger.Delay='PT5S'
$recovery=$task.Triggers.Create(1)
$recovery.StartBoundary=[DateTime]::Now.AddSeconds(10).ToString('yyyy-MM-ddTHH:mm:ss')
$recovery.Repetition.Interval='PT1M'
$recovery.Repetition.StopAtDurationEnd=$false
$recovery.Enabled=$true
$action=$task.Actions.Create(0)
$action.Path=$powerShell
$action.Arguments='-NoLogo -NoProfile -WindowStyle Hidden -File "'+$watchdog+'"'
$action.WorkingDirectory=$script:HlRoot
$registered=$taskFolder.RegisterTaskDefinition($taskName,$task,6,$script:HlUserSid,$null,3,$null)
[IO.File]::WriteAllText((Join-Path $script:HlStateDirectory 'scheduled-task.xml'),$registered.Xml)
$registered.Run($null)|Out-Null
[ordered]@{Name=$registered.Name;State=[int]$registered.State;User=$task.Principal.UserId;RunLevel=$task.Principal.RunLevel;Action=$action.Path;Arguments=$action.Arguments}|ConvertTo-Json -Depth 4
