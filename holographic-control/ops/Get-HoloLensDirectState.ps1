param(
    [ValidatePattern('^[A-Za-z0-9_-]{1,64}$')][string]$RunId=('direct-'+(Get-Date -Format 'yyyyMMdd-HHmmss')),
    [ValidateRange(1,10)][int]$ProbeSeconds=2
)
# Read the pinned device directly over HTTPS without the bridge, so the call
# still works while the bridge is stopped (sleep/wake experiments). Identity is
# established by the saved SSH fingerprint records plus the pinned server key;
# no credential is sent to an unverified peer.
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
. (Join-Path $PSScriptRoot 'Holographic.Common.ps1')
$config=Get-Content -LiteralPath (Join-Path $root 'config.json') -Raw -Encoding UTF8|ConvertFrom-Json
$pin=Get-Content -LiteralPath (Join-Path $script:HolographicRoot '.state\portal-tls-pin.json') -Raw|ConvertFrom-Json
$saved=Import-Clixml -LiteralPath (Join-Path $script:HolographicRoot '.state\portal-credential.clixml')
if($config.DeviceName -cne $pin.DeviceName -or $pin.DeviceName -cne $saved.DeviceName){throw 'Saved device identity records disagree.'}
if($config.ExpectedFingerprint -cne $pin.SshFingerprint -or $pin.SshFingerprint -cne $saved.SshFingerprint){throw 'Saved SSH fingerprint records disagree.'}
$address=[string]$config.InitialAddress
$folder=Join-Path $script:HolographicRoot ('.state\direct\'+$RunId)
[IO.Directory]::CreateDirectory($folder)|Out-Null
$result=[ordered]@{runId=$RunId;at=[DateTimeOffset]::Now.ToString('o');address=$address;identityRecordsMatch=$true;portalOk=$false;lowPower=$null;ssh=$false;videoBytes=0;videoFrames=0;evidence=$folder}
function Test-SshBanner {
    $client=[Net.Sockets.TcpClient]::new()
    try{
        $task=$client.ConnectAsync($address,22);if(-not $task.Wait(3000) -or -not $client.Connected){return $false}
        $client.ReceiveTimeout=3000;$stream=$client.GetStream();$buffer=[byte[]]::new(64)
        $count=$stream.Read($buffer,0,64)
        return [Text.Encoding]::ASCII.GetString($buffer,0,[Math]::Max($count,0)).StartsWith('SSH-2.0-')
    }catch{return $false}finally{$client.Dispose()}
}
$result.ssh=Test-SshBanner
$handler=[HoloPortalTls]::CreateHandler($address,$pin.CertificateSha256)
$client=[Net.Http.HttpClient]::new($handler);$client.Timeout=[TimeSpan]::FromSeconds(6)
try{
    $network=$saved.Credential.GetNetworkCredential()
    $client.DefaultRequestHeaders.Authorization=[Net.Http.Headers.AuthenticationHeaderValue]::new('Basic',[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($network.UserName+':'+$network.Password)))
    $network=$null
    $response=$client.GetAsync('https://'+$address+'/api/power/state').GetAwaiter().GetResult()
    if([int]$response.StatusCode -eq 200){
        $body=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult()|ConvertFrom-Json
        $result.portalOk=$true;$result.lowPower=[bool]$body.LowPowerState
    }
    $response.Dispose()
    if($result.portalOk){
        $path=Join-Path $folder 'probe.mp4'
        $url='https://'+$address+'/api/holographic/stream/live_med.mp4?holo=true&pv=false&mic=false&loopback=false&RenderFromCamera=false'
        $streamResponse=$client.GetAsync($url,[Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        if([int]$streamResponse.StatusCode -eq 200){
            $stream=$streamResponse.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
            $file=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
            $cts=[Threading.CancellationTokenSource]::new($ProbeSeconds*1000)
            $buffer=[byte[]]::new(65536);$bytes=0
            try{while($bytes -lt 8388608){$count=$stream.ReadAsync($buffer,0,$buffer.Length,$cts.Token).GetAwaiter().GetResult();if($count -eq 0){break};$file.Write($buffer,0,$count);$bytes+=$count}}catch [OperationCanceledException]{}
            $file.Dispose();$stream.Dispose();$cts.Dispose();$result.videoBytes=$bytes
            if($bytes -ge 50000){
                $ffmpeg=[string](Get-Content -LiteralPath (Join-Path $root 'pc-control\dist\runtime.json') -Raw|ConvertFrom-Json).Ffmpeg
                $ffprobe=Join-Path (Split-Path -Parent $ffmpeg) 'ffprobe.exe'
                if(Test-Path -LiteralPath $ffprobe){$json=& $ffprobe -v error -count_frames -select_streams v:0 -show_entries stream=nb_read_frames -of json $path 2>$null;try{$result.videoFrames=[int](($json|ConvertFrom-Json).streams[0].nb_read_frames)}catch{}}
            }
        }
        $streamResponse.Dispose()
    }
}catch{$result.portalError=$_.Exception.GetType().Name}
finally{$client.Dispose()}
[IO.File]::WriteAllText((Join-Path $folder 'result.json'),($result|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
$result|ConvertTo-Json -Depth 6
