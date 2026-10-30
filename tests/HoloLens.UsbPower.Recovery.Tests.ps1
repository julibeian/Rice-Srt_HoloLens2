$ErrorActionPreference='Stop'
$workspace=Split-Path -Parent $PSScriptRoot
. (Join-Path $workspace 'usb-terminal/HoloLens.UsbPower.ps1')
# Replace route/file/SDK boundaries. No device operation or network mutation.
Add-Type -TypeDefinition 'public static class HlUsbPowerRoute{public static uint GetBestInterface(uint d,out uint i){i=12;return 0;}}'
function Get-NetAdapter {param($InterfaceIndex,$ErrorAction);[pscustomobject]@{Status='Up';PnPDeviceID=$script:adapterId}}
$fixture=Join-Path $workspace ('apps/pc-control/.state/tests/usb-power-'+[guid]::NewGuid().ToString('N'))
$script:HlStateDirectory=$fixture;$script:HlRoot=$fixture;$script:HlConfig=[pscustomobject]@{DeviceName='fixture';ExpectedFingerprint='fingerprint'}
$script:adapterId='USB\fixture';$script:puts=0;$script:launches=0
[IO.Directory]::CreateDirectory((Join-Path $fixture 'apps/holographic-control/.state/usb-power/arm64'))|Out-Null
$worker=Join-Path $fixture 'apps/holographic-control/.state/usb-power/arm64/hl-usb-power.exe'
[IO.File]::WriteAllText($worker,'not executable; SDK boundaries are mocked')
$policy=[pscustomobject]@{Enabled=$true;DeviceName='fixture';ExpectedFingerprint='fingerprint';Owner=('1'*32);WorkerSha256=(Get-FileHash -LiteralPath $worker).Hash}
$path=Join-Path $fixture 'usb-power-policy.json'
$policy|ConvertTo-Json|Set-Content -LiteralPath $path -Encoding utf8
$script:remoteReport=[pscustomobject]@{protocol=2;phase='active';owner=$policy.Owner;ackSequenceLow=100}
function Invoke-HlOperation {param($Client,$Request,$Address)
    switch($Request.action){
        'stat' {return @{Exists=$true}}
        'cat' {return @{Text=($script:remoteReport|ConvertTo-Json)}}
        'exec' {$script:launches++;return @{ExitCode=0}}
        default {throw ('Unexpected mocked operation '+$Request.action)}
    }
}
$remote=[pscustomobject]@{Sha1Fingerprint='fingerprint'}
$remote|Add-Member ScriptMethod PutFile {param($target,$local,$overwrite);if(-not $overwrite){throw 'Heartbeat must explicitly overwrite'};$script:puts++}
$remote|Add-Member ScriptMethod GetFile {param($source,$local,$overwrite);[IO.File]::Copy($script:worker,$local,$overwrite)}
$client=[pscustomobject]@{RemoteDevice=$remote}
try{
    $result=Invoke-HlUsbPowerTick $client '169.254.1.2'
    if($result.State -cne 'awaiting_heartbeat_ack' -or $script:launches){throw 'A persisted active report was treated as live'}
    $script:remoteReport.ackSequenceLow=101
    $result=Invoke-HlUsbPowerTick $client '169.254.1.2'
    if($result.State -cne 'active' -or $script:launches){throw 'Advancing acknowledgement was not accepted'}
    $script:HlUsbPowerAck.ChangedAt=[Diagnostics.Stopwatch]::GetTimestamp()-21*[Diagnostics.Stopwatch]::Frequency
    $result=Invoke-HlUsbPowerTick $client '169.254.1.2'
    if($result.State -cne 'starting' -or $script:launches -ne 1){throw 'Stale report did not use the kernel-checked native ensure path'}
    $script:remoteReport.ackSequenceLow=102
    $result=Invoke-HlUsbPowerTick $client '169.254.1.2'
    if($result.State -cne 'active' -or $script:HlUsbPowerPending){throw 'Recovered acknowledgement did not clear pending state'}
    $before=$script:puts;$script:remoteReport.owner='2'*32
    $result=Invoke-HlUsbPowerTick $client '169.254.1.2'
    if($result.State -cne 'waiting_for_previous_lease' -or $script:puts -ne $before){throw 'Another owner was overwritten'}
    $script:remoteReport.owner=$policy.Owner;$remote.Sha1Fingerprint='different';$rejected=$false
    try{$null=Invoke-HlUsbPowerTick $client '169.254.1.2'}catch{$rejected=$true}
    if(-not $rejected -or $script:puts -ne $before){throw 'Wrong SSH identity reached heartbeat writes'}
    $remote.Sha1Fingerprint='fingerprint';$script:adapterId='PCI\fixture';$rejected=$false
    try{$null=Invoke-HlUsbPowerTick $client '169.254.1.2'}catch{$rejected=$true}
    if(-not $rejected -or $script:puts -ne $before){throw 'A non-USB route reached heartbeat writes'}
    $policy.Enabled=$false;$policy|ConvertTo-Json|Set-Content -LiteralPath $path -Encoding utf8
    $result=Invoke-HlUsbPowerTick $client '169.254.1.2'
    if($result.State -cne 'disabled' -or $script:puts -ne $before){throw 'Disabled policy still wrote the device'}
    @{passed=8;device_operations=0;persisted_report_is_not_liveness=$true}|ConvertTo-Json
}finally{
    $resolved=[IO.Path]::GetFullPath($fixture);$allowed=[IO.Path]::GetFullPath((Join-Path $workspace 'apps/pc-control/.state/tests'))+[IO.Path]::DirectorySeparatorChar
    if(-not $resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolved) -notlike 'usb-power-*'){throw 'Unsafe fixture cleanup'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
