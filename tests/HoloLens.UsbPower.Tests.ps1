$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../HoloLens.UsbPower.ps1')
$owner='00112233445566778899aabbccddeeff'
$packet=New-HlUsbPowerHeartbeat -Owner $owner -Sequence 1234567890123
if($packet.Length -ne 32 -or [BitConverter]::ToUInt32($packet,0) -ne 0x48555048 -or [BitConverter]::ToUInt32($packet,4) -ne 1){throw 'USB heartbeat framing changed'}
if([Convert]::ToHexString($packet[8..23]).ToLowerInvariant() -cne $owner -or [BitConverter]::ToUInt64($packet,24) -ne 1234567890123){throw 'USB owner or sequence is not byte exact'}
if(Test-HlUsbPowerPolicy $null 'device' 'fingerprint'){throw 'Missing configuration enabled policy'}
if(Test-HlUsbPowerPolicy ([pscustomobject]@{Enabled=$false}) 'device' 'fingerprint'){throw 'Disabled configuration enabled policy'}
if(Test-HlUsbPowerPolicy ([pscustomobject]@{Enabled='true'}) 'device' 'fingerprint'){throw 'Non-boolean flag enabled policy'}
$valid=[pscustomobject]@{Enabled=$true;DeviceName='device';ExpectedFingerprint='fingerprint';Owner=$owner;WorkerSha256=('A'*64)}
if(-not(Test-HlUsbPowerPolicy $valid 'device' 'fingerprint')){throw 'Exact policy was not accepted'}
$rejected=0
foreach($test in @(@{device='different';fingerprint='fingerprint'},@{device='device';fingerprint='different'})){
    try{$null=Test-HlUsbPowerPolicy $valid $test.device $test.fingerprint}catch{$rejected++}
}
if($rejected -ne 2){throw 'Another device identity was accepted'}
$valid.Owner='malformed';$rejected=$false;try{$null=Test-HlUsbPowerPolicy $valid 'device' 'fingerprint'}catch{$rejected=$true}
if(-not $rejected){throw 'Malformed ownership was accepted'}
@{passed=9;device_operations=0;automatic_trust_changes=0}|ConvertTo-Json
