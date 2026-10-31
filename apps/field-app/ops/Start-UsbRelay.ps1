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
$process=Start-Process -FilePath $python -ArgumentList @('-B',$script,'--host',$HostAddress,'--port',[string]$Port) -WorkingDirectory $root -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
$deadline=(Get-Date).AddSeconds(5)
do{
    Start-Sleep -Milliseconds 200
    $listener=Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
}while(-not $listener -and (Get-Date) -lt $deadline -and -not $process.HasExited)
if(-not $listener){
    if(-not $process.HasExited){Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue}
    throw ('USB relay did not start; see '+$stderr)
}
[IO.File]::WriteAllText((Join-Path $state 'usb-relay.pid'),[string]$process.Id,[Text.UTF8Encoding]::new($false))
[ordered]@{State='started';Port=$Port;ProcessId=$process.Id;Host=$HostAddress;Stdout=$stdout;Stderr=$stderr}|ConvertTo-Json -Compress
