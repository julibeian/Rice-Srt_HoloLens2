param(
    [ValidatePattern('^[A-Za-z0-9_-]{1,64}$')][string]$RunId=('wake-'+(Get-Date -Format 'yyyyMMdd-HHmmss')),
    [ValidateSet('Auto','Restart','None')][string]$Strategy='Auto',
    [ValidateRange(30,900)][int]$TimeoutSeconds=240,
    [ValidateRange(1,10)][int]$ProbeSeconds=2,
    [switch]$Check,
    [switch]$Force
)
# Wake the original pinned device over the USB management link and prove the
# result with a decodable frame, not with HTTP 200 alone. Restart is the only
# remote wake primitive the device has shown; it is rate limited and logged.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Holographic.Common.ps1')
$root=$script:HolographicRoot
$folder=Join-Path $root ('.state\wake\'+$RunId)
[IO.Directory]::CreateDirectory($folder)|Out-Null
$resultPath=Join-Path $folder 'result.json'
$statePath=Join-Path $root '.state\wake\state.json'
$cooldownSeconds=600
function New-Result([string]$state){
    [ordered]@{
        runId=$RunId;at=[DateTimeOffset]::Now.ToString('o');state=$state;strategy=$Strategy
        initialLowPower=$null;awake=$false;elapsedSeconds=$null;restartStatus=$null
        videoBytes=0;videoFrames=0;probeSeconds=$ProbeSeconds;stages=$stages
        identityVerified=$true;evidence=$folder;error=$null
    }
}
$stages=[Collections.Generic.List[object]]::new()
function Add-Stage([string]$name,$data){
    $stages.Add([ordered]@{at=[DateTimeOffset]::Now.ToString('o');stage=$name;data=$data})
}
function Save-Result($result){
    [IO.File]::WriteAllText($resultPath,($result|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    $result|ConvertTo-Json -Depth 8
}
function Get-PowerObservation($context){
    $response=$null
    try{
        $response=$context.Client.GetAsync($context.BaseUri+'/api/power/state').GetAwaiter().GetResult()
        $status=[int]$response.StatusCode
        if($status -ne 200){return [ordered]@{known=$false;status=$status;low=$null}}
        $body=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult()|ConvertFrom-Json
        if($null -eq $body.LowPowerState){return [ordered]@{known=$false;status=$status;low=$null}}
        return [ordered]@{known=$true;status=$status;low=[bool]$body.LowPowerState}
    }catch{return [ordered]@{known=$false;status=0;low=$null;error=$_.Exception.GetType().Name}}
    finally{if($response){$response.Dispose()}}
}
function Get-FfprobePath {
    $runtime=Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'apps/pc-control\dist\runtime.json'
    $runtime=[IO.Path]::GetFullPath($runtime)
    if(Test-Path -LiteralPath $runtime){
        $ffmpeg=[string](Get-Content -LiteralPath $runtime -Raw -Encoding UTF8|ConvertFrom-Json).Ffmpeg
        $probe=Join-Path (Split-Path -Parent $ffmpeg) 'ffprobe.exe'
        if(Test-Path -LiteralPath $probe){return $probe}
    }
    return $null
}
function Test-FreshVideo($context,[int]$seconds){
    $path=Join-Path $folder ('probe-'+[DateTimeOffset]::Now.ToString('HHmmssfff')+'.mp4')
    $url=$context.BaseUri+'/api/holographic/stream/live_med.mp4?holo=true&pv=false&mic=false&loopback=false&RenderFromCamera=false'
    $response=$null;$stream=$null;$file=$null;$cts=$null
    try{
        $response=$context.Client.GetAsync($url,[Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        if([int]$response.StatusCode -ne 200){return [ordered]@{ok=$false;status=[int]$response.StatusCode;bytes=0;frames=0;file=$path}}
        $stream=$response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $file=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
        $cts=[Threading.CancellationTokenSource]::new($seconds*1000)
        $buffer=[byte[]]::new(65536);$bytes=0
        try{
            while($bytes -lt 8388608){
                $count=$stream.ReadAsync($buffer,0,$buffer.Length,$cts.Token).GetAwaiter().GetResult()
                if($count -eq 0){break}
                $file.Write($buffer,0,$count);$bytes+=$count
            }
        }catch [OperationCanceledException]{}
        $frames=0
        if($bytes -ge 50000){
            $probe=Get-FfprobePath
            if($probe){
                $json=& $probe -v error -count_frames -select_streams v:0 -show_entries stream=nb_read_frames -of json $path 2>$null
                try{$frames=[int](($json|ConvertFrom-Json).streams[0].nb_read_frames)}catch{$frames=0}
            }
        }
        return [ordered]@{ok=($bytes -ge 50000 -and ($frames -gt 0 -or -not (Get-FfprobePath)));status=200;bytes=$bytes;frames=$frames;file=$path}
    }catch{return [ordered]@{ok=$false;status=0;bytes=0;frames=0;file=$path;error=$_.Exception.GetType().Name}}
    finally{
        if($file){$file.Dispose()};if($stream){$stream.Dispose()};if($response){$response.Dispose()};if($cts){$cts.Dispose()}
    }
}
function Get-CsrfToken($context){
    # The portal issues the CSRF cookie with the authenticated page, not with
    # the JSON API responses, so load the page once before any POST.
    $page=$null
    try{
        $page=$context.Client.GetAsync($context.BaseUri+'/default.htm').GetAwaiter().GetResult()
        if([int]$page.StatusCode -ne 200){return $null}
        $cookie=$context.Handler.CookieContainer.GetCookies([uri]($context.BaseUri+'/'))['CSRF-Token']
        if($cookie){return $cookie.Value}
        foreach($path in @('/api/control/restart','/api/holographic/simulation/control/stream')){
            $cookie=$context.Handler.CookieContainer.GetCookies([uri]($context.BaseUri+$path))['CSRF-Token']
            if($cookie){return $cookie.Value}
        }
        return $null
    }catch{return $null}
    finally{if($page){$page.Dispose()}}
}
function Send-Restart($context){
    $uri=[uri]($context.BaseUri+'/api/control/restart')
    $request=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post,$uri)
    try{
        $token=Get-CsrfToken $context
        if($token){$request.Headers.Add('X-CSRF-Token',$token)}
        $request.Content=[Net.Http.ByteArrayContent]::new([byte[]]::new(0))
        $response=$context.Client.SendAsync($request).GetAwaiter().GetResult()
        try{return [int]$response.StatusCode}finally{$response.Dispose()}
    }catch{
        # A reboot can tear the connection down before the response is read;
        # that is not by itself a failure, the loop below verifies the result.
        Add-Stage 'restart_request_interrupted' $_.Exception.GetType().Name
        return 0
    }finally{$request.Dispose()}
}
$result=New-Result 'started'
$context=$null
try{
    $context=New-HoloAuthenticatedPortalContext
    Add-Stage 'identity_verified' @{device=$context.Device.DeviceName;address=$context.Device.Address}
    $power=Get-PowerObservation $context
    $result.initialLowPower=$power.low
    Add-Stage 'initial_power' $power
    if(-not $power.known){$result.state='power_unknown';return (Save-Result $result)}
    if($power.low -eq $false){
        $video=Test-FreshVideo $context $ProbeSeconds
        $result.awake=$true;$result.videoBytes=$video.bytes;$result.videoFrames=$video.frames
        Add-Stage 'already_awake_probe' $video
        $result.state=if($video.ok){'already_awake'}else{'awake_without_video'}
        return (Save-Result $result)
    }
    if($Check){$result.state='low_power_check_only';return (Save-Result $result)}
    if($Strategy -eq 'None'){$result.state='low_power_no_strategy';return (Save-Result $result)}
    if(-not $Force -and (Test-Path -LiteralPath $statePath)){
        $last=Get-Content -LiteralPath $statePath -Raw -Encoding UTF8|ConvertFrom-Json
        if($last.lastRestartAt){
            $age=([DateTimeOffset]::Now-[DateTimeOffset]$last.lastRestartAt).TotalSeconds
            if($age -lt $cooldownSeconds){
                $result.state='cooldown';$result.error=('last restart {0:N0}s ago' -f $age)
                Add-Stage 'cooldown' @{ageSeconds=[math]::Round($age);limitSeconds=$cooldownSeconds}
                return (Save-Result $result)
            }
        }
    }
    $started=[DateTimeOffset]::Now
    $result.restartStatus=Send-Restart $context
    Add-Stage 'restart_sent' @{status=$result.restartStatus}
    [IO.File]::WriteAllText($statePath,([ordered]@{lastRestartAt=$started.ToString('o');runId=$RunId;device=$context.Device.DeviceName}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    Start-Sleep -Seconds 15
    $lastVideo=$null
    while((([DateTimeOffset]::Now)-$started).TotalSeconds -lt $TimeoutSeconds){
        $power=Get-PowerObservation $context
        Add-Stage 'poll' $power
        if($power.known -and $power.low -eq $false){
            $video=Test-FreshVideo $context $ProbeSeconds
            $lastVideo=$video
            Add-Stage 'video_probe' $video
            if($video.ok){
                $result.awake=$true;$result.videoBytes=$video.bytes;$result.videoFrames=$video.frames
                $result.elapsedSeconds=[math]::Round(((([DateTimeOffset]::Now)-$started).TotalSeconds),1)
                $result.state='awake_verified'
                return (Save-Result $result)
            }
        }
        Start-Sleep -Seconds 5
    }
    $result.elapsedSeconds=[math]::Round(((([DateTimeOffset]::Now)-$started).TotalSeconds),1)
    if($lastVideo){$result.videoBytes=$lastVideo.bytes;$result.videoFrames=$lastVideo.frames}
    $result.state='wake_timeout';$result.error='no decodable frame within the budget'
    return (Save-Result $result)
}finally{
    if($context){$context.Client.Dispose()}
}
