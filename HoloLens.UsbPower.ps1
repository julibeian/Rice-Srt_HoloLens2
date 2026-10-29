# Optional, identity-bound USB power lease. Called inside the existing bridge;
# never call its public pipe recursively from here.
function New-HlUsbPowerHeartbeat {
    param([Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{32}$')][string]$Owner,[uint64]$Sequence=[Diagnostics.Stopwatch]::GetTimestamp())
    $packet=[byte[]]::new(32)
    [BitConverter]::GetBytes([uint32]0x48555048).CopyTo($packet,0)
    [BitConverter]::GetBytes([uint32]1).CopyTo($packet,4)
    [Convert]::FromHexString($Owner).CopyTo($packet,8)
    [BitConverter]::GetBytes($Sequence).CopyTo($packet,24)
    return ,$packet
}
function Test-HlUsbPowerPolicy {
    param($Policy,[string]$DeviceName,[string]$Fingerprint)
    if($null -eq $Policy -or -not $Policy.PSObject.Properties['Enabled'] -or $Policy.Enabled -cne $true){return $false}
    if($Policy.DeviceName -cne $DeviceName -or $Policy.ExpectedFingerprint -cne $Fingerprint){throw 'USB power policy belongs to another device'}
    if($Policy.Owner -cnotmatch '^[a-f0-9]{32}$' -or $Policy.WorkerSha256 -cnotmatch '^[A-F0-9]{64}$'){throw 'Malformed USB power policy'}
    return $true
}
function Invoke-HlUsbPowerTick {
    param($Client,[string]$Address)
    $policyPath=Join-Path $script:HlStateDirectory 'usb-power-policy.json'
    if(-not(Test-Path -LiteralPath $policyPath)){return @{State='disabled'}}
    $policy=Get-Content -LiteralPath $policyPath -Raw|ConvertFrom-Json
    if(-not(Test-HlUsbPowerPolicy $policy $script:HlConfig.DeviceName $script:HlConfig.ExpectedFingerprint)){return @{State='disabled'}}
    if($Client.RemoteDevice.Sha1Fingerprint -cne $script:HlConfig.ExpectedFingerprint){throw 'USB power lease requires original SSH identity'}
    $ip=[Net.IPAddress]::Parse($Address).GetAddressBytes()
    if($ip.Length -ne 4 -or $ip[0] -ne 169 -or $ip[1] -ne 254){throw 'USB power policy requires the USB link-local route'}
    if(-not ('HlUsbPowerRoute' -as [type])){
        Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;public static class HlUsbPowerRoute{[DllImport("iphlpapi.dll")]public static extern uint GetBestInterface(uint destination,out uint index);}'
    }
    [uint32]$index=0
    if([HlUsbPowerRoute]::GetBestInterface([BitConverter]::ToUInt32($ip,0),[ref]$index) -ne 0){throw 'USB route unavailable'}
    $adapter=Get-NetAdapter -InterfaceIndex $index -ErrorAction Stop
    if($adapter.Status -cne 'Up' -or $adapter.PnPDeviceID -notlike 'USB\*'){throw 'Original device is not reached over an active USB adapter'}
    $base='U:\Users\DefaultAccount\AppData\Local\DevelopmentFiles\RiceHoloLensFieldV1'
    $remoteReport=$base+'\usb-power-report.json'
    $report=$null
    if((Invoke-HlOperation $Client @{action='stat';path=$remoteReport} $Address).Exists){
        try{$report=(Invoke-HlOperation $Client @{action='cat';path=$remoteReport} $Address).Text|ConvertFrom-Json}catch{}
    }
    if($report -and $report.phase -ceq 'active' -and $report.owner -cne $policy.Owner){return @{State='waiting_for_previous_lease';PreviousOwner=$report.owner;LeaseMs=45000}}
    $heartbeatPath=Join-Path $script:HlStateDirectory 'usb-power-heartbeat.bin'
    [IO.File]::WriteAllBytes($heartbeatPath,(New-HlUsbPowerHeartbeat $policy.Owner))
    # Only this fixed owned heartbeat is replaced. General file operations
    # retain their no-overwrite default.
    $Client.RemoteDevice.PutFile($base+'\usb-power-heartbeat.bin',$heartbeatPath,$true)
    if($report -and $report.owner -ceq $policy.Owner -and $report.phase -ceq 'active'){
        $now=[Diagnostics.Stopwatch]::GetTimestamp()
        if(-not(Get-Variable HlUsbPowerAck -Scope Script -ErrorAction SilentlyContinue)){
            $script:HlUsbPowerAck=@{Value=$report.ackSequenceLow;ChangedAt=$now;Owner=$policy.Owner;Verified=$false}
        }elseif($script:HlUsbPowerAck.Owner -cne $policy.Owner -or $script:HlUsbPowerAck.Value -ne $report.ackSequenceLow){
            $script:HlUsbPowerAck=@{Value=$report.ackSequenceLow;ChangedAt=$now;Owner=$policy.Owner;Verified=$true}
            $script:HlUsbPowerPending=$false;$script:HlUsbPowerAttempts=0
        }
        $age=($now-$script:HlUsbPowerAck.ChangedAt)/[double][Diagnostics.Stopwatch]::Frequency
        if($age -lt 20){
            return @{State=if($script:HlUsbPowerAck.Verified){'active'}else{'awaiting_heartbeat_ack'};InterfaceIndex=$index;LeaseMs=45000;Worker=$report;AckObservedAgeSeconds=$age}
        }
        # A persisted active report is not a live process. The idempotent native
        # ensure call below checks the kernel mutex before starting anything.
    }
    if(-not(Get-Variable HlUsbPowerAttempts -Scope Script -ErrorAction SilentlyContinue)){$script:HlUsbPowerAttempts=0;$script:HlUsbPowerPending=$false}
    if($script:HlUsbPowerPending){
        if($report -and $report.owner -ceq $policy.Owner){$script:HlUsbPowerPending=$false}
        else{return @{State='launch_outcome_pending';ReplayAllowed=$false}}
    }
    if($script:HlUsbPowerAttempts -ge 3){return @{State='start_failed';Attempts=$script:HlUsbPowerAttempts}}
    $local=Join-Path $script:HlRoot 'holographic-control/.state/usb-power/arm64/hl-usb-power.exe'
    if((Get-FileHash -LiteralPath $local).Hash -cne $policy.WorkerSha256){throw 'USB power worker differs from enabled policy'}
    $remote=$base+'\hl-usb-power-'+$policy.WorkerSha256.Substring(0,16)+'.exe'
    if(-not(Invoke-HlOperation $Client @{action='stat';path=$remote} $Address).Exists){Invoke-HlOperation $Client @{action='put';local=$local;path=$remote} $Address|Out-Null}
    $copy=Join-Path $script:HlStateDirectory 'usb-power-verified-worker.exe'
    $Client.RemoteDevice.GetFile($remote,$copy,$true)
    if((Get-FileHash -LiteralPath $copy).Hash -cne $policy.WorkerSha256){throw 'Remote USB power worker hash mismatch'}
    $script:HlUsbPowerAttempts++;$script:HlUsbPowerPending=$true
    $launch=Invoke-HlOperation $Client @{action='exec';executable='C:\Windows\System32\DevToolsLauncher.exe';arguments=('LaunchForDebug '+$remote+' "" Rice.HoloLens.Field_r5420n6798s24!Field')} $Address
    if($launch.ExitCode -ne 0){return @{State='launch_rejected';ExitCode=$launch.ExitCode;ReplayAllowed=$false}}
    return @{State='starting';InterfaceIndex=$index;LeaseMs=45000;ReplayAllowed=$false}
}
