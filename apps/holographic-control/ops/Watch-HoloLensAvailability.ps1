param(
    [ValidatePattern('^[A-Za-z0-9_-]{1,64}$')][string]$RunId=('supervisor-'+(Get-Date -Format 'yyyyMMdd-HHmmss')),
    [switch]$Once,
    [ValidateRange(60,1800)][int]$IntervalSeconds=120,
    [ValidateRange(30,600)][int]$WakeTimeoutSeconds=150,
    [ValidateRange(60,3600)][int]$CooldownSeconds=300,
    [switch]$Force
)
# Availability supervisor for the original pinned device.
# It never touches device identity, credentials or security settings. When the
# pinned portal is unreachable or reports low power, it restarts the local
# bridge (the only observed non-destructive wake trigger) and verifies a
# decodable frame before recording success. Attempts are rate limited.
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
. (Join-Path $PSScriptRoot 'Holographic.Common.ps1')
$stateDir=Join-Path $script:HolographicRoot '.state\supervisor'
[IO.Directory]::CreateDirectory($stateDir)|Out-Null
$statePath=Join-Path $stateDir 'state.json'
$folder=Join-Path $stateDir $RunId
[IO.Directory]::CreateDirectory($folder)|Out-Null
$resultPath=Join-Path $folder 'result.json'
$config=Get-Content -LiteralPath (Join-Path $root 'config.json') -Raw -Encoding UTF8|ConvertFrom-Json
$pin=Get-Content -LiteralPath (Join-Path $script:HolographicRoot '.state\portal-tls-pin.json') -Raw|ConvertFrom-Json
$saved=Import-Clixml -LiteralPath (Join-Path $script:HolographicRoot '.state\portal-credential.clixml')
if($config.DeviceName -cne $pin.DeviceName -or $pin.DeviceName -cne $saved.DeviceName){throw 'Saved device identity records disagree.'}
if($config.ExpectedFingerprint -cne $pin.SshFingerprint -or $pin.SshFingerprint -cne $saved.SshFingerprint){throw 'Saved SSH fingerprint records disagree.'}
$address=[string]$config.InitialAddress
if($address -notmatch '^169\.254\.\d+\.\d+$'){throw 'The configured USB address is not link-local.'}
$samples=[Collections.Generic.List[object]]::new()
$result=[ordered]@{
    runId=$RunId;at=[DateTimeOffset]::Now.ToString('o');state='checking';device=$config.DeviceName
    identityRecordsMatch=$true;portalReachable=$null;lowPower=$null;sshReachable=$null
    bridgeState=$null;action='none';actionSkippedReason=$null;wakeSeconds=$null;wakeMethod=$null
    videoOk=$false;videoProbed=$false;videoBytes=0;videoFrames=0;samples=$samples;evidence=$folder;error=$null
}
function Save-Result {[IO.File]::WriteAllText($resultPath,($result|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))}
function New-DirectPortalClient {
    # Certificate pinning and same-key leaf renewal live in the shared helper.
    return (New-HoloDirectPortalContext -Address $address).Client
}
function Get-DirectPower($client){
    $response=$null
    try{
        $response=$client.GetAsync('https://'+$address+'/api/power/state').GetAwaiter().GetResult()
        if([int]$response.StatusCode -ne 200){return [ordered]@{ok=$false;low=$null}}
        $body=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult()|ConvertFrom-Json
        if($null -eq $body.LowPowerState){return [ordered]@{ok=$false;low=$null}}
        return [ordered]@{ok=$true;low=[bool]$body.LowPowerState}
    }catch{return [ordered]@{ok=$false;low=$null;error=$_.Exception.GetType().Name}}
    finally{if($response){$response.Dispose()}}
}
function Test-SshBanner {
    $client=[Net.Sockets.TcpClient]::new()
    try{
        $task=$client.ConnectAsync($address,22);if(-not $task.Wait(3000) -or -not $client.Connected){return $false}
        $client.ReceiveTimeout=3000;$stream=$client.GetStream();$buffer=[byte[]]::new(64)
        $count=$stream.Read($buffer,0,64)
        return [Text.Encoding]::ASCII.GetString($buffer,0,[Math]::Max($count,0)).StartsWith('SSH-2.0-')
    }catch{return $false}finally{$client.Dispose()}
}
function Test-FreshVideo($client,[int]$seconds){
    $path=Join-Path $folder ('probe-'+[DateTimeOffset]::Now.ToString('HHmmssfff')+'.mp4')
    $response=$null;$stream=$null;$file=$null;$cts=$null
    try{
        $url='https://'+$address+'/api/holographic/stream/live_med.mp4?holo=true&pv=false&mic=false&loopback=false&RenderFromCamera=false'
        $response=$client.GetAsync($url,[Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        if([int]$response.StatusCode -ne 200){return [ordered]@{ok=$false;bytes=0;frames=0}}
        $stream=$response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $file=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
        $cts=[Threading.CancellationTokenSource]::new($seconds*1000)
        $buffer=[byte[]]::new(65536);$bytes=0
        try{while($bytes -lt 8388608){$count=$stream.ReadAsync($buffer,0,$buffer.Length,$cts.Token).GetAwaiter().GetResult();if($count -eq 0){break};$file.Write($buffer,0,$count);$bytes+=$count}}catch [OperationCanceledException]{}
        $frames=0
        if($bytes -ge 50000){
            $runtimePath=Join-Path $root 'apps/pc-control\dist\runtime.json'
            if(Test-Path -LiteralPath $runtimePath){
                $ffmpeg=[string](Get-Content -LiteralPath $runtimePath -Raw|ConvertFrom-Json).Ffmpeg
                $ffprobe=Join-Path (Split-Path -Parent $ffmpeg) 'ffprobe.exe'
                if(Test-Path -LiteralPath $ffprobe){$json=& $ffprobe -v error -count_frames -select_streams v:0 -show_entries stream=nb_read_frames -of json $path 2>$null;try{$frames=[int](($json|ConvertFrom-Json).streams[0].nb_read_frames)}catch{$frames=0}}
            }
        }
        return [ordered]@{ok=($bytes -ge 50000 -and $frames -gt 0);bytes=$bytes;frames=$frames}
    }catch{return [ordered]@{ok=$false;bytes=0;frames=0;error=$_.Exception.GetType().Name}}
    finally{if($file){$file.Dispose()};if($stream){$stream.Dispose()};if($response){$response.Dispose()};if($cts){$cts.Dispose()}}
}
function Get-BridgeState {
    $path=Join-Path $root '.state\status.json'
    if(-not(Test-Path -LiteralPath $path)){return 'missing'}
    try{return [string](Get-Content -LiteralPath $path -Raw|ConvertFrom-Json).State}catch{return 'unreadable'}
}
function Test-Cooldown {
    if($Force){return $null}
    if(-not(Test-Path -LiteralPath $statePath)){return $null}
    try{
        $state=Get-Content -LiteralPath $statePath -Raw|ConvertFrom-Json
        if($state.lastRestartAt){
            $restartAge=([DateTimeOffset]::Now-[DateTimeOffset]$state.lastRestartAt).TotalSeconds
            if($restartAge -lt 900){return ('restart cooldown {0:N0}s of 900s' -f $restartAge)}
        }
        if($state.lastAttemptAt){
            $age=([DateTimeOffset]::Now-[DateTimeOffset]$state.lastAttemptAt).TotalSeconds
            if($age -lt $CooldownSeconds){return ('cooldown {0:N0}s of {1}s' -f $age,$CooldownSeconds)}
        }
    }catch{}
    return $null
}
function Save-Attempt([string]$outcome,[switch]$Restart){
    $previous=$null
    if(Test-Path -LiteralPath $statePath){try{$previous=Get-Content -LiteralPath $statePath -Raw|ConvertFrom-Json}catch{}}
    $state=[ordered]@{lastAttemptAt=[DateTimeOffset]::Now.ToString('o');lastOutcome=$outcome;runId=$RunId;device=$config.DeviceName}
    if($previous -and $previous.lastRestartAt){$state.lastRestartAt=$previous.lastRestartAt}
    if($Restart){$state.lastRestartAt=[DateTimeOffset]::Now.ToString('o')}
    [IO.File]::WriteAllText($statePath,($state|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
}
function Restart-Bridge {
    try{
        & (Join-Path $root 'usb-terminal/Stop-HoloLensBridge.ps1') -DisableAutostart *> (Join-Path $folder 'bridge-stop.txt')
        Start-Sleep -Seconds 2
    }finally{
        # Never leave the bridge task disabled if the stop half fails.
        & (Join-Path $root 'usb-terminal/Start-HoloLensBridge.ps1') *> (Join-Path $folder 'bridge-start.txt')
    }
}
function Wait-Awake([DateTimeOffset]$Deadline){
    # Success requires a decodable frame, not just an awake power flag.
    while(([DateTimeOffset]::Now) -lt $Deadline){
        $client=$null
        try{
            $client=New-DirectPortalClient
            $power=Get-DirectPower $client
            if($power.ok -and $power.low -eq $false){
                $video=Test-FreshVideo $client 2
                $result.videoProbed=$true
                $result.videoOk=$video.ok;$result.videoBytes=$video.bytes;$result.videoFrames=$video.frames
                $samples.Add([ordered]@{at=[DateTimeOffset]::Now.ToString('o');phase='verify';portalOk=$true;low=$false;videoOk=$video.ok;bytes=$video.bytes;frames=$video.frames;bridge=(Get-BridgeState)})
                Save-Result
                if($video.ok){return [ordered]@{portalOk=$true;low=$false;videoOk=$true;bytes=$video.bytes;frames=$video.frames;bridge=(Get-BridgeState)}}
            }else{
                $samples.Add([ordered]@{at=[DateTimeOffset]::Now.ToString('o');phase='verify';portalOk=$power.ok;low=$power.low;bridge=(Get-BridgeState)})
            }
        }catch{}
        finally{if($client){$client.Dispose()}}
        Start-Sleep -Seconds 4
    }
    return $null
}
$result.bridgeState=Get-BridgeState
$client=$null
try{
    $client=New-DirectPortalClient
    $power=Get-DirectPower $client
    $result.portalReachable=$power.ok;$result.lowPower=$power.low
    $result.sshReachable=Test-SshBanner
    $samples.Add([ordered]@{at=[DateTimeOffset]::Now.ToString('o');phase='check';portalOk=$power.ok;low=$power.low;ssh=$result.sshReachable;bridge=$result.bridgeState})
    if($power.ok -and $power.low -eq $false){
        if($result.bridgeState -eq 'connected'){
            # A connected bridge already proves the device is reachable; skip
            # the two-second video pull to keep the periodic check cheap.
            $result.state='healthy'
            $samples.Add([ordered]@{at=[DateTimeOffset]::Now.ToString('o');phase='health';bridge=$result.bridgeState;videoProbe='skipped_connected'})
        } else {
            $video=Test-FreshVideo $client 2
            $result.videoProbed=$true
            $result.videoOk=$video.ok;$result.videoBytes=$video.bytes;$result.videoFrames=$video.frames
            $samples.Add([ordered]@{at=[DateTimeOffset]::Now.ToString('o');phase='video';ok=$video.ok;bytes=$video.bytes;frames=$video.frames})
            $result.state=if($video.ok){'healthy'}else{'low_power_video'}
        }
    }else{$result.state=if($power.ok){'low_power'}else{'unreachable'}}
}catch{$result.error=$_.Exception.GetType().Name}
finally{if($client){$client.Dispose()}}
if($result.state -eq 'healthy'){
    # A healthy device with a stopped bridge would soon lose its power lease.
    if((Get-BridgeState) -ne 'connected'){
        try{& (Join-Path $root 'usb-terminal/Start-HoloLensBridge.ps1') *> (Join-Path $folder 'bridge-resume.txt')}catch{$result.bridgeResumeError=$_.Exception.GetType().Name}
    }
    Save-Result;return ($result|ConvertTo-Json -Depth 8)
}
$skip=Test-Cooldown
if($skip){
    $result.actionSkippedReason=$skip;$result.state='cooldown'
    Save-Result;return ($result|ConvertTo-Json -Depth 8)
}
$result.action='discovery'
Save-Attempt 'discovery_started'
$started=[DateTimeOffset]::Now
$sdk=Join-Path ([string]$config.SdkDirectory) 'WinAppDeployCmd.exe'
if(Test-Path -LiteralPath $sdk){
    try{& $sdk devices 3 *> (Join-Path $folder 'discovery.txt')}
    catch{$result.error=('discovery: '+$_.Exception.GetType().Name)}
    $samples.Add([ordered]@{at=[DateTimeOffset]::Now.ToString('o');phase='discovery';tool=$sdk})
    Save-Result
} else {
    $result.error='WinAppDeployCmd.exe was not found.'
}
# The USB/SDK enumeration alone has been observed to wake the device within
# about 16 seconds; wait a short window before resorting to a bridge restart.
$wake=Wait-Awake ($started.AddSeconds([Math]::Min(45,$WakeTimeoutSeconds)))
if(-not $wake){
    $result.action='restart_bridge'
    Save-Attempt 'restart_bridge_started'
    try{Restart-Bridge}catch{$result.error=('restart: '+$_.Exception.GetType().Name)}
    $wake=Wait-Awake ($started.AddSeconds($WakeTimeoutSeconds))
}
if(-not $wake){
    # If the portal is reachable now (State A: portal and SSH up, display off),
    # a controlled restart is the only verified recovery; enum and bridge
    # restart cannot clear it. A 15-minute restart cooldown prevents loops.
    $portalNow=$false
    $probeClient=$null
    try{
        $probeClient=New-DirectPortalClient
        $portalPower=Get-DirectPower $probeClient
        $portalNow=[bool]$portalPower.ok
    }catch{}finally{if($probeClient){$probeClient.Dispose()}}
    if($portalNow){
        $result.action='portal_restart'
        Save-Attempt 'portal_restart_started' -Restart
        $restartScript=Join-Path $PSScriptRoot 'Invoke-HoloLensWake.ps1'
        $restartRunId='supervisor-restart-'+[DateTimeOffset]::Now.ToString('yyyyMMdd-HHmmss')
        try{
            $restartText=& $restartScript -RunId $restartRunId -Force -TimeoutSeconds 420 2>&1 | Out-String
            $restartResult=$null
            try{$restartResult=$restartText|ConvertFrom-Json}catch{}
            if($restartResult -and $restartResult.state -eq 'awake_verified' -and [int]$restartResult.videoFrames -gt 0){
                $result.videoProbed=$true;$result.videoOk=$true
                $result.videoBytes=[int]$restartResult.videoBytes;$result.videoFrames=[int]$restartResult.videoFrames
                $wake=[ordered]@{portalOk=$true;low=$false;videoOk=$true;bytes=$result.videoBytes;frames=$result.videoFrames;bridge=(Get-BridgeState);method='portal_restart'}
                $samples.Add([ordered]@{at=[DateTimeOffset]::Now.ToString('o');phase='restart_verify';state=$restartResult.state;bytes=$result.videoBytes;frames=$result.videoFrames;bridge=(Get-BridgeState)})
            }else{
                $samples.Add([ordered]@{at=[DateTimeOffset]::Now.ToString('o');phase='restart_failed';state=$(if($restartResult){$restartResult.state}else{'unparsed'})})
            }
        }catch{$result.error=('portal_restart: '+$_.Exception.GetType().Name)}
    }
}
$result.wakeSeconds=[math]::Round((([DateTimeOffset]::Now)-$started).TotalSeconds,1)
$result.wakeMethod=if($wake){if($wake.method){$wake.method}else{$result.action}}else{$null}
$result.state=if($wake -and $wake.videoOk){'recovered'}elseif($wake){'awake_without_video'}else{'recovery_failed'}
Save-Attempt $result.state
# A wake without the bridge would leave the device without its power lease.
if((Get-BridgeState) -ne 'connected'){
    try{& (Join-Path $root 'usb-terminal/Start-HoloLensBridge.ps1') *> (Join-Path $folder 'bridge-resume.txt')}catch{$result.bridgeResumeError=$_.Exception.GetType().Name}
}
Save-Result
$result|ConvertTo-Json -Depth 8
