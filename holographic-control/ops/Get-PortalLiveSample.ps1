param(
    [ValidatePattern('^[A-Za-z0-9_-]{1,64}$')][string]$RunId=('live-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[Guid]::NewGuid().ToString('N').Substring(0,6)),
    [ValidateRange(1,15)][int]$Seconds=6
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Holographic.Common.ps1')
$folder=Join-Path $script:HolographicRoot ('.state\live\'+$RunId)
$checkpoint=Join-Path $folder 'result.json'
if(Test-Path -LiteralPath $checkpoint){Get-Content -LiteralPath $checkpoint -Raw;return}
$context=New-HoloAuthenticatedPortalContext
[IO.Directory]::CreateDirectory($folder)|Out-Null
$path=Join-Path $folder 'live.mp4'
$proof=[ordered]@{RunId=$RunId;At=[DateTimeOffset]::Now.ToString('o');State='request_started';Seconds=$Seconds;StreamHttpStatus=$null;Bytes=0;Holograms=$true;PhotoVideoCamera=$false;Microphone=$false;LoopbackAudio=$false;RenderFromCamera=$false;StreamClosed=$false;VisibleUiVerified=$false;Video=$path;Evidence=$folder}
[IO.File]::WriteAllText($checkpoint,($proof|ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
$response=$null;$stream=$null;$file=$null;$deadline=$null
try {
    # Explicitly exclude PV and both audio sources. This does not reserve the
    # application's camera or upload a view of the room to an external service.
    $url=$context.BaseUri+'/api/holographic/stream/live_high.mp4?holo=true&pv=false&mic=false&loopback=false&RenderFromCamera=false'
    $response=$context.Client.GetAsync($url,[Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
    $proof.StreamHttpStatus=[int]$response.StatusCode
    if($proof.StreamHttpStatus -eq 200){
        $stream=$response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $file=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
        $deadline=[Threading.CancellationTokenSource]::new($Seconds*1000)
        $buffer=[byte[]]::new(65536)
        try {
            while($proof.Bytes -lt 20971520){
                $count=$stream.ReadAsync($buffer,0,$buffer.Length,$deadline.Token).GetAwaiter().GetResult()
                if($count -eq 0){break}
                $file.Write($buffer,0,$count);$proof.Bytes+=$count
            }
            $proof.State='sample_received'
        } catch [OperationCanceledException] {$proof.State='bounded_sample_received'}
        if($proof.Bytes -eq 0){$proof.State='empty_stream'}
    } else {$proof.State='stream_rejected'}
} catch {$proof.State='stream_error';$proof.ErrorType=$_.Exception.GetType().Name}
finally {
    if($file){$file.Dispose()};if($stream){$stream.Dispose()};if($response){$response.Dispose()};if($deadline){$deadline.Dispose()}
    $context.Client.Dispose();$proof.StreamClosed=$true
    [IO.File]::WriteAllText($checkpoint,($proof|ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
}
$proof|ConvertTo-Json -Depth 4
