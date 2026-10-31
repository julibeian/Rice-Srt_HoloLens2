param(
    [switch]$Uninstall,
    [ValidateRange(1,60)][int]$IntervalMinutes=5
)
# Register (or remove) the per-user availability supervisor. The supervisor
# only restarts the local bridge and verifies a decodable frame; it never
# changes device identity, credentials, security or audio settings.
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$taskName='HoloLensWakeSupervisor'
$existing=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if($Uninstall){
    if($existing){Unregister-ScheduledTask -TaskName $taskName -Confirm:$false}
    [pscustomobject]@{TaskName=$taskName;Installed=$false}|ConvertTo-Json
    return
}
$pwsh=Join-Path $root 'runtime\powershell\pwsh.exe'
$script=Join-Path $PSScriptRoot 'Watch-HoloLensAvailability.ps1'
if(-not (Test-Path -LiteralPath $pwsh)){throw 'The bundled pwsh executable is missing.'}
if(-not (Test-Path -LiteralPath $script)){throw 'The supervisor script is missing.'}
$action=New-ScheduledTaskAction -Execute $pwsh -Argument ('-NoLogo -NoProfile -WindowStyle Hidden -File "'+$script+'" -Once')
$atLogon=New-ScheduledTaskTrigger -AtLogOn
$repeat=New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) -RepetitionDuration (New-TimeSpan -Days 3650)
$settings=New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
$principal=New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
if($existing){Unregister-ScheduledTask -TaskName $taskName -Confirm:$false}
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger @($atLogon,$repeat) -Settings $settings -Principal $principal -Description 'Restart the local HoloLens bridge and verify a decodable frame when the pinned device is asleep or unreachable.' | Out-Null
$registered=Get-ScheduledTask -TaskName $taskName
[pscustomobject]@{TaskName=$taskName;Installed=$true;State=[string]$registered.State;IntervalMinutes=$IntervalMinutes;Script=$script;Executable=$pwsh}|ConvertTo-Json
