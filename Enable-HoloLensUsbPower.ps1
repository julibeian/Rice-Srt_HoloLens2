param([switch]$Disable)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'HoloLens.Common.ps1')
$policyPath=Join-Path $script:HlStateDirectory 'usb-power-policy.json'
if($Disable){
    if(Test-Path -LiteralPath $policyPath){$policy=Get-Content -LiteralPath $policyPath -Raw|ConvertFrom-Json;$policy.Enabled=$false;$policy|ConvertTo-Json|Set-Content -LiteralPath $policyPath -Encoding utf8}
    @{Enabled=$false;DeviceRestoreDeadlineSeconds=45}|ConvertTo-Json;return
}
$device=Invoke-HlBridge @{action='info'}
if($device.HostFingerprint -cne $script:HlConfig.ExpectedFingerprint -or $device.DeviceName -cne $script:HlConfig.DeviceName){throw 'Original device identity not verified'}
$worker=& (Join-Path $PSScriptRoot 'holographic-control/ops/Build-UsbPower.ps1')|ConvertFrom-Json
$owner=[guid]::NewGuid().ToString('N')
if(Test-Path -LiteralPath $policyPath){
    $previous=Get-Content -LiteralPath $policyPath -Raw|ConvertFrom-Json
    if($previous.DeviceName -cne $script:HlConfig.DeviceName -or $previous.ExpectedFingerprint -cne $script:HlConfig.ExpectedFingerprint){throw 'Existing power policy belongs to another identity'}
    $owner=$previous.Owner
}
$policy=[ordered]@{Enabled=$true;DeviceName=$script:HlConfig.DeviceName;ExpectedFingerprint=$script:HlConfig.ExpectedFingerprint;Owner=$owner;WorkerSha256=$worker.Sha256;EnabledAt=[DateTimeOffset]::Now.ToString('o');DeviceLeaseMs=45000;Override='DC sleep, unattended sleep and display idle only while USB heartbeat is live';InputSimulationChanged=$false}
[IO.File]::WriteAllText($policyPath,($policy|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
[pscustomobject]$policy|Select-Object Enabled,DeviceName,WorkerSha256,DeviceLeaseMs,Override|ConvertTo-Json
