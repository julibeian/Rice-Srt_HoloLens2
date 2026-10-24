param([switch]$DisableAutostart)
. (Join-Path $PSScriptRoot 'HoloLens.Common.ps1')
if($DisableAutostart){
    if(Get-HlScheduledTask){$null=Set-HlTaskAutostart $false}
    $link=Join-Path ([Environment]::GetFolderPath('Startup')) 'HoloLens USB SSH Bridge.lnk'
    if(Test-Path -LiteralPath $link){Remove-Item -LiteralPath $link}
}
$task=Get-HlScheduledTask
if($task){$task.Enabled=$false}
try{Invoke-HlBridge @{action='stop'}|ConvertTo-Json -Compress}catch{
    $task=Get-HlScheduledTask
    if($task -and [int]$task.State -eq 4){throw 'The Windows-managed channel is still running; a graceful stop could not be confirmed.'}
    'Bridge is not running.'
}
