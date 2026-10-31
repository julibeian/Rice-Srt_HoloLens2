param([int]$Port = 9021)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$listener=Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if(-not $listener){
    [ordered]@{State='already_stopped';Port=$Port}|ConvertTo-Json -Compress
    return
}
$processId=$listener.OwningProcess
$process=Get-CimInstance Win32_Process -Filter ('ProcessId='+$processId) -ErrorAction SilentlyContinue
if(-not $process -or $process.CommandLine -notmatch 'usb_relay\.py'){
    throw ('Port '+$Port+' is owned by an unexpected process '+$processId+'; refusing to stop it.')
}
Stop-Process -Id $processId -Force
$pidFile=Join-Path $root '.state/usb-relay.pid'
if(Test-Path -LiteralPath $pidFile){Remove-Item -LiteralPath $pidFile -Force}
[ordered]@{State='stopped';Port=$Port;ProcessId=$processId}|ConvertTo-Json -Compress
