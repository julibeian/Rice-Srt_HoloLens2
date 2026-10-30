param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_-]{1,64}$')][string]$RunId,
    [ValidateRange(10,60)][int]$Seconds=30,
    [ValidateSet('Interactive','Detail','Low')][string]$VideoProfile='Interactive',
    [switch]$RenderFromCamera,
    [switch]$DisableStabilizationBuffer,
    [ValidateSet('Default','ImmediateAck','RawTls')][string]$Transport='Default',
    [ValidateSet('PowerShell','Native')][string]$Reader='PowerShell'
)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$workspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
. (Join-Path $workspace 'holographic-control/ops/Holographic.Common.ps1')
$folder=Join-Path $workspace ('reports/phase2-full-control/'+$RunId)
$resultPath=Join-Path $folder 'result.json'
if(Test-Path -LiteralPath $resultPath){Get-Content -LiteralPath $resultPath -Raw;return}
if(Test-Path -LiteralPath (Join-Path $folder 'request.json')){throw 'Source measurement already requested; inspect existing evidence instead of overwriting it.'}
[IO.Directory]::CreateDirectory($folder)|Out-Null
$utf8=[Text.UTF8Encoding]::new($false)
function Save-Json($Name,$Value){[IO.File]::WriteAllText((Join-Path $folder $Name),($Value|ConvertTo-Json -Depth 9),$utf8)}
$endpoint=switch($VideoProfile){'Detail'{'live_high.mp4'}'Low'{'live_low.mp4'}default{'live_med.mp4'}}
$effectiveReader=if($Transport -eq 'RawTls'){'NativeRawTls'}else{$Reader}
Save-Json 'request.json' @{at=[DateTimeOffset]::Now.ToString('o');endpoint=$endpoint;seconds=$Seconds;render_from_camera=[bool]$RenderFromCamera;disable_stabilization=[bool]$DisableStabilizationBuffer;transport=$Transport;reader=$effectiveReader;pv=$false;microphone=$false;loopback=$false;input_sent=$false}
$context=$null;$response=$null;$stream=$null;$file=$null;$deadline=$null;$socketTransport=$null
$chunks=[Collections.Generic.List[object]]::new();$bytes=[long]0
$proof=[ordered]@{at=[DateTimeOffset]::Now.ToString('o');run_id=$RunId;state='request_started';endpoint=$endpoint;bytes=0;read_seconds=$null;http_status=$null;stream_closed=$false;frames=$null;first_packet_ms=$null;whole_read_fps=$null;steady_start_ms=$null;steady_end_ms=$null;steady_frames=$null;steady_wall_fps=$null;mbps=$null;input_sent=$false;error=$null}
try{
    if($Reader -eq 'Native'){. (Join-Path $PSScriptRoot 'Video.SourceReader.ps1')}
    $context=New-HoloAuthenticatedPortalContext
    if($Transport -eq 'ImmediateAck'){
        . (Join-Path $PSScriptRoot 'Video.SocketTransport.ps1')
        $socketTransport=[HoloVideoSocketTransport]::new($context.Device.Address,$context.CertificateSha256,[byte]1)
        $socketTransport.Client.DefaultRequestHeaders.Authorization=$context.Client.DefaultRequestHeaders.Authorization
        $socketTransport.Client.Timeout=$context.Client.Timeout
        $context.Client.Dispose();$context.Client=$socketTransport.Client
    }
    $url=$context.BaseUri+'/api/holographic/stream/'+$endpoint+'?holo=true&pv=false&mic=false&loopback=false&RenderFromCamera='+([bool]$RenderFromCamera).ToString().ToLowerInvariant()
    if($DisableStabilizationBuffer){$url+='&vstab=false&vstabbuffer=0'}
    if($Transport -eq 'RawTls'){
        . (Join-Path $PSScriptRoot 'Video.RawTransport.ps1')
        $file=[IO.File]::Open((Join-Path $folder 'source.mp4'),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
        $capture=[HoloVideoRawTransport]::CaptureAsync($context.Device.Address,$context.CertificateSha256,$context.Client.DefaultRequestHeaders.Authorization.ToString(),([uri]$url).PathAndQuery,$file,$Seconds).GetAwaiter().GetResult()
        $bytes=$capture.Bytes;$chunks=$capture.Chunks
        $proof.http_status=$capture.HttpStatus;$proof.raw_framing=$capture.Framing;$proof.raw_certificate_verified=$capture.CertificateVerified
        $proof.read_seconds=$capture.Seconds;$proof.bytes=$bytes;$proof.state='bounded_copy_received'
    }else{
    $response=$context.Client.GetAsync($url,[Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
    $proof.http_status=[int]$response.StatusCode
    if($proof.http_status -ne 200){throw ('Stream HTTP '+$proof.http_status)}
    $stream=$response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
    $file=[IO.File]::Open((Join-Path $folder 'source.mp4'),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    $deadline=[Threading.CancellationTokenSource]::new($Seconds*1000);$clock=[Diagnostics.Stopwatch]::StartNew();$buffer=[byte[]]::new(65536)
    try{
        if($Reader -eq 'Native'){
            $capture=[HoloVideoSourceReader]::CopyAsync($stream,$file,$clock,$deadline.Token).GetAwaiter().GetResult()
            $bytes=$capture.Bytes;$chunks=$capture.Chunks
        }else{while($bytes -lt 67108864){
            $count=$stream.ReadAsync($buffer,0,$buffer.Length,$deadline.Token).GetAwaiter().GetResult()
            $received=$clock.Elapsed.TotalMilliseconds
            if($count -eq 0){break}
            $bytes+=$count;$chunks.Add(@{byte_end=$bytes;received_ms=$received;bytes=$count})
            $file.Write($buffer,0,$count)
        }}
    }catch [OperationCanceledException]{}
    $proof.read_seconds=$clock.Elapsed.TotalSeconds;$proof.bytes=$bytes;$proof.state='bounded_copy_received'
    }
}catch{$proof.state='source_error';$proof.error=$_.Exception.GetType().Name+': '+$_.Exception.Message}
finally{
    if($file){$file.Dispose()};if($stream){$stream.Dispose()};if($response){$response.Dispose()};if($deadline){$deadline.Dispose()};if($context){$context.Client.Dispose()}
    $proof.stream_closed=$true;Save-Json 'chunks.json' @($chunks)
    $proof.transport=$Transport
    $proof.reader=$effectiveReader
    if($socketTransport){$proof.socket_count=$socketTransport.ConnectedSockets;$proof.socket_ack_frequency=$socketTransport.AckFrequencyApplied}
}
if($proof.state -eq 'bounded_copy_received'){
    try{
        $runtime=Get-Content -LiteralPath (Join-Path $workspace 'pc-control/dist/runtime.json') -Raw|ConvertFrom-Json
        $ffprobe=Join-Path (Split-Path -Parent $runtime.Ffmpeg) 'ffprobe.exe'
        $mediaText=& $ffprobe -v error -select_streams v:0 -count_frames -show_packets -show_streams -show_entries packet=pos,size,pts_time,dts_time:stream=width,height,duration,nb_read_frames,avg_frame_rate -of json (Join-Path $folder 'source.mp4') 2> (Join-Path $folder 'ffprobe-error.txt')
        if($LASTEXITCODE -ne 0){throw 'Video parsing did not succeed'}
        $media=$mediaText|ConvertFrom-Json;Save-Json 'media.json' $media
        $index=0;$arrivals=@(foreach($packet in $media.packets){
            $end=[long]$packet.pos+[long]$packet.size
            while($index -lt $chunks.Count -and $chunks[$index].byte_end -lt $end){$index++}
            if($index -ge $chunks.Count){throw 'Packet extends beyond received bytes'}
            @{received_ms=$chunks[$index].received_ms;byte_end=$end;pts_seconds=[double]$packet.pts_time}
        })
        if($arrivals.Count -lt 2){throw 'No usable video packet interval'}
        Save-Json 'packet-arrivals.json' $arrivals
        $proof.frames=[int]$media.streams[0].nb_read_frames;$proof.first_packet_ms=$arrivals[0].received_ms;$proof.whole_read_fps=$proof.frames/$proof.read_seconds
        # A fixed PC-clock window after first packet + 3s excludes startup.
        # Count only complete packet arrivals, never PTS or repeated paints.
        $start=$arrivals[0].received_ms+3000;$end=$arrivals[-1].received_ms
        if($end-$start -lt 5000){throw 'Steady interval is too short'}
        $steady=@($arrivals|Where-Object {$_.received_ms -gt $start -and $_.received_ms -le $end})
        $proof.steady_start_ms=$start;$proof.steady_end_ms=$end;$proof.steady_frames=$steady.Count;$proof.steady_wall_fps=$steady.Count*1000/($end-$start);$proof.mbps=$bytes*8/$proof.read_seconds/1000000;$proof.state='measured'
        $proof.sha256=(Get-FileHash -LiteralPath (Join-Path $folder 'source.mp4')).Hash
    }catch{$proof.state='measurement_incomplete';$proof.error=$_.Exception.GetType().Name+': '+$_.Exception.Message}
}
Save-Json 'result.json' $proof
$proof|ConvertTo-Json -Depth 5
if($proof.state -ne 'measured'){exit 2}
