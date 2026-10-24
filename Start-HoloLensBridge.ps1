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
if(-not $task.Enabled){$task.Enabled=$true}
if([int]$task.State -ne 4){$task.Run($null)|Out-Null}
if(Test-Path -LiteralPath $legacyLink){
    Copy-Item -LiteralPath $legacyLink -Destination (Join-Path $script:HlStateDirectory 'legacy-startup.lnk') -Force
    Remove-Item -LiteralPath $legacyLink
}
for($attempt=0;$attempt -lt 20;$attempt++){
    try{Invoke-HlBridge @{action='status'} 1000|ConvertTo-Json -Depth 5;exit 0}catch{}
    if([int](Get-HlScheduledTask).State -ne 4){throw 'The Windows-managed HoloLens task exited. See .state logs.'}
    Start-Sleep -Milliseconds 500
}
throw 'Bridge startup timed out; the Windows task remains responsible for recovery.'
