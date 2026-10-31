param(
    [string]$HostAddress = '169.254.216.241',
    [int]$Port = 9021
)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$state=Join-Path $root '.state'
[IO.Directory]::CreateDirectory($state)|Out-Null
$listener=Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if($listener){
    [ordered]@{State='already_listening';Port=$Port;ProcessId=$listener.OwningProcess}|ConvertTo-Json -Compress
    return
}
$python=(Get-Command python -ErrorAction Stop).Source
$script=Join-Path $root 'apps/field-app/server/usb_relay.py'
$stdout=Join-Path $state ('usb-relay-'+$Port+'.out.log')
$stderr=Join-Path $state ('usb-relay-'+$Port+'.err.log')
$commandLine='"'+$python+'" -B "'+$script+'" --host '+$HostAddress+' --port '+$Port
$created=Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine=$commandLine;CurrentDirectory=$root}
if([int]$created.ReturnValue -ne 0){throw ('WMI could not create the USB relay (return '+$created.ReturnValue+').')}
$processId=[int]$created.ProcessId
Start-Sleep -Seconds 2
$listener=Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if(-not $listener){
    Start-Sleep -Seconds 2
    $listener=Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
}
if(-not $listener){
    Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
    throw ('USB relay did not start; process '+$processId)
}
[IO.File]::WriteAllText((Join-Path $state 'usb-relay.pid'),[string]$processId,[Text.UTF8Encoding]::new($false))
[ordered]@{State='started';Port=$Port;ProcessId=$processId;Host=$HostAddress;Method='wmi';Stdout=$stdout;Stderr=$stderr}|ConvertTo-Json -Compress
