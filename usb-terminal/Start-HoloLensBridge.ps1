param([switch]$InstallAutostart,[switch]$UninstallAutostart)
. (Join-Path $PSScriptRoot 'HoloLens.Common.ps1')
$legacyLink=Join-Path ([Environment]::GetFolderPath('Startup')) 'HoloLens USB SSH Bridge.lnk'
if($UninstallAutostart){
    if(Get-HlScheduledTask){Set-HlTaskAutostart $false|ConvertTo-Json -Compress}
    if(Test-Path -LiteralPath $legacyLink){Remove-Item -LiteralPath $legacyLink}
    exit 0
}
if($InstallAutostart -or -not (Get-HlScheduledTask)){
    & (Join-Path $PSScriptRoot 'Register-HoloLensTask.ps1')|Out-Host
}
$task=Get-HlScheduledTask
if(-not $task){throw 'The Windows-managed HoloLens task is missing.'}
$expected=Join-Path $PSScriptRoot 'HoloLens.Watchdog.ps1'
if($task.Definition.Actions.Item(1).Arguments -notmatch [regex]::Escape($expected)){throw 'Unexpected scheduled task owner.'}
if(-not $task.Enabled){$task.Enabled=$true}
if(Test-Path -LiteralPath $legacyLink){
    Copy-Item -LiteralPath $legacyLink -Destination (Join-Path $script:HlStateDirectory 'legacy-startup.lnk') -Force
    Remove-Item -LiteralPath $legacyLink
}
# The task may already be warm. Only a responsive current-user pipe confirms it.
try{Invoke-HlBridge @{action='status'} 500|ConvertTo-Json -Depth 5;exit 0}catch{}
# Task Scheduler can take several seconds to launch the watchdog. Start the
# same owned bridge directly; the watchdog adopts it by PID from status.json,
# so supervision and the one-minute recovery trigger remain intact.
$bridge=Join-Path $PSScriptRoot 'HoloLens.Bridge.ps1'
try{Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -ArgumentList @('-NoLogo','-NoProfile','-WindowStyle','Hidden','-File',('"'+$bridge+'"')) -WindowStyle Hidden|Out-Null}catch{}
for($attempt=0;$attempt -lt 32;$attempt++){
    try{
        $started=Invoke-HlBridge @{action='status'} 500
        if([int]$task.State -ne 4){try{$task.Run($null)|Out-Null}catch{}}
        $started|ConvertTo-Json -Depth 5;exit 0
    }catch{}
    Start-Sleep -Milliseconds 250
}
# Fall back to the scheduled task only when the direct launch did not answer.
try{if([int]$task.State -ne 4){$task.Run($null)|Out-Null}}catch{}
for($attempt=0;$attempt -lt 20;$attempt++){
    try{Invoke-HlBridge @{action='status'} 1000|ConvertTo-Json -Depth 5;exit 0}catch{}
    Start-Sleep -Milliseconds 500
}
throw 'Bridge startup timed out; the Windows task remains responsible for recovery.'
