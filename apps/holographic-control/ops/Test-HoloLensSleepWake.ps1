param(
    [ValidatePattern('^[A-Za-z0-9_-]{1,64}$')][string]$RunId=('sleepwake-'+(Get-Date -Format 'yyyyMMdd-HHmmss')),
    [ValidateRange(60,1800)][int]$SleepTimeoutSeconds=600,
    [ValidateRange(30,600)][int]$WakeTimeoutSeconds=240,
    [ValidateRange(10,120)][int]$PollSeconds=20,
    [ValidateRange(0,300)][int]$QuietWaitSeconds=0,
    [switch]$SkipSleep,
    [switch]$KeepBridge
)
# Controlled sleep/wake experiment for the original pinned device.
# The bridge is stopped to let the device-side 45s lease lapse; the portal is
# then probed directly (certificate pin + saved credential) so the observation
# no longer depends on the bridge. The bridge is always restarted afterwards.
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
. (Join-Path $PSScriptRoot 'Holographic.Common.ps1')
$folder=Join-Path $root ('reports\phase2-full-control\t07-sleepwake-20261029\'+$RunId)
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
    runId=$RunId;at=[DateTimeOffset]::Now.ToString('o');state='started';device=$config.DeviceName
    address=$address;identityRecordsMatch=$true;sleepCandidate=$false;sleepObservedSeconds=$null
    portalDownSamples=0;sshAliveDuringSleep=$null;bridgeRestartSeconds=$null
    awakeAfterSeconds=$null;videoOk=$false;videoBytes=0;videoFrames=0
    baselineLowPower=$null;samples=$samples;evidence=$folder;error=$null
}
function Save-Result {
    [IO.File]::WriteAllText($resultPath,($result|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
}
function New-DirectPortalClient {
    $handler=[HoloPortalTls]::CreateHandler($address,$pin.CertificateSha256)
    $client=[Net.Http.HttpClient]::new($handler)
    $client.Timeout=[TimeSpan]::FromSeconds(6)
    $network=$saved.Credential.GetNetworkCredential()
    $client.DefaultRequestHeaders.Authorization=[Net.Http.Headers.AuthenticationHeaderValue]::new('Basic',[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($network.UserName+':'+$network.Password)))
    $network=$null
    return $client
}
function Get-DirectPower($client){
    $response=$null
    try{
        $response=$client.GetAsync('https://'+$address+'/api/power/state').GetAwaiter().GetResult()
        if([int]$response.StatusCode -ne 200){return [ordered]@{ok=$false;low=$null;status=[int]$response.StatusCode}}
        $body=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult()|ConvertFrom-Json
        if($null -eq $body.LowPowerState){return [ordered]@{ok=$false;low=$null;status=200}}
        return [ordered]@{ok=$true;low=[bool]$body.LowPowerState;status=200}
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
    }catch{return $false}
    finally{$client.Dispose()}
}
function Test-FreshVideo($client,[int]$seconds){
    $path=Join-Path $folder ('probe-'+[DateTimeOffset]::Now.ToString('HHmmssfff')+'.mp4')
    $response=$null;$stream=$null;$file=$null;$cts=$null
    try{
        $url='https://'+$address+'/api/holographic/stream/live_med.mp4?holo=true&pv=false&mic=false&loopback=false&RenderFromCamera=false'
        $response=$client.GetAsync($url,[Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        if([int]$response.StatusCode -ne 200){return [ordered]@{ok=$false;bytes=0;frames=0;status=[int]$response.StatusCode}}
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
                if(Test-Path -LiteralPath $ffprobe){
                    $json=& $ffprobe -v error -count_frames -select_streams v:0 -show_entries stream=nb_read_frames -of json $path 2>$null
                    try{$frames=[int](($json|ConvertFrom-Json).streams[0].nb_read_frames)}catch{$frames=0}
                }
            }
        }
        return [ordered]@{ok=($bytes -ge 50000 -and $frames -gt 0);bytes=$bytes;frames=$frames;status=200;file=$path}
    }catch{return [ordered]@{ok=$false;bytes=0;frames=0;error=$_.Exception.GetType().Name}}
    finally{if($file){$file.Dispose()};if($stream){$stream.Dispose()};if($response){$response.Dispose()};if($cts){$cts.Dispose()}}
}
function Get-BridgeState {
    $path=Join-Path $root '.state\status.json'
    if(-not (Test-Path -LiteralPath $path)){return 'missing'}
    try{return [string](Get-Content -LiteralPath $path -Raw|ConvertFrom-Json).State}catch{return 'unreadable'}
}
function Start-Bridge {
    & (Join-Path $root 'usb-terminal/Start-HoloLensBridge.ps1') *> (Join-Path $folder 'bridge-start.txt')
}
$bridgeStopped=$false
try{
    Save-Result
    $client=New-DirectPortalClient
    try{
        $baseline=Get-DirectPower $client
        $result.baselineLowPower=$baseline.low
        $samples.Add([ordered]@{at=[DateTimeOffset]::Now.ToString('o');phase='baseline';portalOk=$baseline.ok;low=$baseline.low;ssh=(Test-SshBanner)})
        if($SkipSleep){
            $result.state='baseline_only';Save-Result;return ($result|ConvertTo-Json -Depth 8)
        }
    }finally{$client.Dispose()}
    if(-not $KeepBridge){
        & (Join-Path $root 'usb-terminal/Stop-HoloLensBridge.ps1') -DisableAutostart *> (Join-Path $folder 'bridge-stop.txt')
        $bridgeStopped=$true
    }
    $started=[DateTimeOffset]::Now
    $portalDown=0;$sshDuringSleep=$null
    while((([DateTimeOffset]::Now)-$started).TotalSeconds -lt $SleepTimeoutSeconds){
        Start-Sleep -Seconds $PollSeconds
        $client=$null
        try{
            $client=New-DirectPortalClient
            $power=Get-DirectPower $client
            $ssh=Test-SshBanner
            if(-not $power.ok){$portalDown++}else{$portalDown=0}
            $samples.Add([ordered]@{at=[DateTimeOffset]::Now.ToString('o');phase='sleep_wait';portalOk=$power.ok;low=$power.low;ssh=$ssh;portalDownStreak=$portalDown})
            Save-Result
            if($portalDown -ge 2 -or ($power.ok -and $power.low -eq $true)){
                $result.sleepCandidate=$true
                $result.sleepObservedSeconds=[math]::Round((([DateTimeOffset]::Now)-$started).TotalSeconds,1)
                $result.portalDownSamples=$portalDown
                $result.sshAliveDuringSleep=$ssh
                $sshDuringSleep=$ssh
                break
            }
        }catch{
            $samples.Add([ordered]@{at=[DateTimeOffset]::Now.ToString('o');phase='sleep_wait';error=$_.Exception.GetType().Name})
        }finally{if($client){$client.Dispose()}}
    }
    $wakeStart=[DateTimeOffset]::Now
    if($result.sleepCandidate -and $QuietWaitSeconds -gt 0){
        Start-Sleep -Seconds $QuietWaitSeconds
        $client=$null
        try{
            $client=New-DirectPortalClient
            $power=Get-DirectPower $client
            $ssh=Test-SshBanner
            $samples.Add([ordered]@{at=[DateTimeOffset]::Now.ToString('o');phase='quiet_wait_probe';portalOk=$power.ok;low=$power.low;ssh=$ssh;quietSeconds=$QuietWaitSeconds})
            Save-Result
            if($power.ok -and $power.low -eq $false -and $ssh){
                $video=Test-FreshVideo $client 2
                $result.videoBytes=$video.bytes;$result.videoFrames=$video.frames;$result.videoOk=$video.ok
                $result.awakeAfterSeconds=[math]::Round((([DateTimeOffset]::Now)-$wakeStart).TotalSeconds,1)
                $result.state=if($video.ok){'self_wake_after_quiet'}else{'self_wake_no_video'}
                Save-Result
                return ($result|ConvertTo-Json -Depth 8)
            }
        }catch{}finally{if($client){$client.Dispose()}}
    }
    Start-Bridge
    $bridgeStopped=$false
    $result.bridgeRestartSeconds=[math]::Round((([DateTimeOffset]::Now)-$wakeStart).TotalSeconds,1)
    $awake=$false
    while((([DateTimeOffset]::Now)-$wakeStart).TotalSeconds -lt $WakeTimeoutSeconds){
        $client=$null
        try{
            $client=New-DirectPortalClient
            $power=Get-DirectPower $client
            if($power.ok -and $power.low -eq $false){
                $video=Test-FreshVideo $client 2
                $result.videoBytes=$video.bytes;$result.videoFrames=$video.frames;$result.videoOk=$video.ok
                $samples.Add([ordered]@{at=[DateTimeOffset]::Now.ToString('o');phase='wake_check';portalOk=$true;low=$false;videoOk=$video.ok;bytes=$video.bytes;frames=$video.frames;bridge=(Get-BridgeState)})
                Save-Result
                if($video.ok){$awake=$true;break}
            }else{
                $samples.Add([ordered]@{at=[DateTimeOffset]::Now.ToString('o');phase='wake_check';portalOk=$power.ok;low=$power.low;bridge=(Get-BridgeState)})
                Save-Result
            }
        }catch{$samples.Add([ordered]@{at=[DateTimeOffset]::Now.ToString('o');phase='wake_check';error=$_.Exception.GetType().Name})}
        finally{if($client){$client.Dispose()}}
        Start-Sleep -Seconds 5
    }
    $result.awakeAfterSeconds=[math]::Round((([DateTimeOffset]::Now)-$wakeStart).TotalSeconds,1)
    $result.state=if($awake){'wake_verified'}elseif($result.sleepCandidate){'wake_unverified'}else{'no_sleep_observed'}
    Save-Result
    $result|ConvertTo-Json -Depth 8
}finally{
    if($bridgeStopped){
        try{Start-Bridge}catch{}
    }
    $task=Get-ScheduledTask -TaskName $config.ScheduledTaskName -ErrorAction SilentlyContinue
    if($task -and [string]$task.State -eq 'Disabled'){Enable-ScheduledTask -TaskName $config.ScheduledTaskName|Out-Null}
    Save-Result
}
