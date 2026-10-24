param(
    [Parameter(Mandatory=$true)][string]$PackageDirectory,
    [string]$SessionFile=(Join-Path (Split-Path -Parent $PSScriptRoot) '.state\session.json'),
    [switch]$AuditEvidence
)
# Transfers an ALREADY captured native JPEG. No camera or activation calls.
$ErrorActionPreference='Stop'
$totalClock=[Diagnostics.Stopwatch]::StartNew()
$phaseClock=[Diagnostics.Stopwatch]::StartNew()
$timings=[ordered]@{}
$captureRoot=Split-Path -Parent $PSScriptRoot
. (Join-Path (Split-Path -Parent $captureRoot) 'HoloLens.Common.ps1')
$package=Get-Content -LiteralPath (Join-Path $PackageDirectory 'package-evidence.json') -Raw|ConvertFrom-Json
$session=Get-Content -LiteralPath $SessionFile -Raw|ConvertFrom-Json
$run=[string]$session.run_id
if($run -notmatch '^[A-Za-z0-9_-]{1,64}$' -or $package.run_id -ne $run -or $package.capture_source -ne 'native' -or $package.autocapture -ne $false){throw 'Requires the same run and a native-source package with automatic capture disabled.'}
if($session.expires_epoch -le [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()){throw 'Renew this SAME cloud run before transfer; do not capture again.'}
$remoteRoot='U:\Users\DefaultAccount\AppData\Local\DevelopmentFiles\RiceHoloLensCaptureV1\native-shots\'+$run
$localRoot=Join-Path $captureRoot ('.state\runs\'+$run)
[IO.Directory]::CreateDirectory($localRoot)|Out-Null
$utf8=[Text.UTF8Encoding]::new($false)
function Save-Json([string]$Path,$Value){[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 15),$utf8)}
function Read-EyeJson([string]$Path){
    # cat already checks existence and length; avoid a second remote stat call.
    (Invoke-HlBridge @{action='cat';path=$Path}).Text|ConvertFrom-Json
}
function Assert-Binding($Result,$Photo){
    $proof=$Result.capture_evidence
    if($null -eq $proof -or $proof.run_id -ne $run -or $proof.request_id -ne $Photo.request_id -or $proof.image_sha256 -ne $Photo.image_sha256 -or $proof.prediction_id -notmatch '^[A-Za-z0-9._-]{1,128}$'){throw 'Result is not bound to the exact eye JPEG.'}
    if($Result.is_valid -isnot [bool] -or [string]::IsNullOrWhiteSpace($Result.predicted_class) -or $null -eq $Result.confidence -or $Result.confidence -lt 0 -or $Result.confidence -gt 1){throw 'Invalid model response.'}
}
$connection=Invoke-HlBridge @{action='info'}
$state=Read-EyeJson ($remoteRoot+'\state-native.json')
$photo=Read-EyeJson ($remoteRoot+'\capture.json')
if($state.run_id -ne $run -or $state.runtime -ne 'winrt-media-capture' -or $state.capture_origin -ne 'arm64-mediacapture' -or $state.photo.request_id -ne $photo.request_id -or $state.photo.image_sha256 -ne $photo.image_sha256){throw 'Native camera state and metadata differ.'}
if($photo.run_id -ne $run -or $photo.request_id -notmatch '^[A-Za-z0-9._-]{1,64}$' -or $photo.image_sha256 -notmatch '^[a-f0-9]{64}$' -or $photo.image_bytes -lt 4 -or $photo.image_bytes -gt 7340032 -or $photo.photo_attempts -ne 1 -or $photo.photo_api_completed -ne $true -or $photo.camera_closed -ne $true){throw 'Native metadata does not prove one completed exposure and closed camera.'}
Save-Json (Join-Path $localRoot 'capture.json') $photo
Save-Json (Join-Path $localRoot 'state-native.json') $state
$timings.metadata_ms=[math]::Round($phaseClock.Elapsed.TotalMilliseconds,2)
$phaseClock.Restart()
$photoPath=Join-Path $localRoot 'photo.jpg'
$photoDownloaded=-not (Test-Path -LiteralPath $photoPath)
if($photoDownloaded){Invoke-HlBridge @{action='get';path=($remoteRoot+'\photo.jpg');local=$photoPath}|Out-Null}
if((Get-FileHash -LiteralPath $photoPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $photo.image_sha256 -or (Get-Item -LiteralPath $photoPath).Length -ne $photo.image_bytes){throw 'Transferred JPEG differs from the eye hash or byte length.'}
$timings.photo_download_and_hash_ms=[math]::Round($phaseClock.Elapsed.TotalMilliseconds,2)
$handler=[Net.Http.HttpClientHandler]::new();$handler.AllowAutoRedirect=$false
$client=[Net.Http.HttpClient]::new($handler);$client.Timeout=[TimeSpan]::FromSeconds(45)
function Cloud-Request([string]$Method,[string]$Path){
    $request=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method),('https://rice-srt.cn/hololens/api/'+$Path))
    $response=$null
    try{
        foreach($pair in @(@('X-HoloLens-Token',[string]$session.token),@('X-HoloLens-Run',$run),@('X-Request-ID',[string]$photo.request_id),@('X-HoloLens-Image-SHA256',[string]$photo.image_sha256),@('User-Agent','RiceHoloLensUsbBridge/1.0 (actual paired eye capture)'))){$request.Headers.TryAddWithoutValidation($pair[0],$pair[1])|Out-Null}
        if($Method -eq 'POST'){
            $form=[Net.Http.MultipartFormDataContent]::new()
            $content=[Net.Http.StreamContent]::new([IO.File]::OpenRead($photoPath))
            $content.Headers.ContentType=[Net.Http.Headers.MediaTypeHeaderValue]::new('image/jpeg')
            $form.Add($content,'file','hololens-single-shot.jpg');$request.Content=$form
        }
        $response=$client.SendAsync($request).GetAwaiter().GetResult()
        $responseText=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if(-not $response.IsSuccessStatusCode){throw ('Cloud '+$Path+' HTTP '+[int]$response.StatusCode)}
        $responseText|ConvertFrom-Json
    }finally{if($response){$response.Dispose()};$request.Dispose()}
}
try{
    $phaseClock.Restart()
    $predictionReused=$false
    $resultPath=Join-Path $localRoot 'result.json'
    if(Test-Path -LiteralPath $resultPath){
        $result=Get-Content -LiteralPath $resultPath -Raw|ConvertFrom-Json
        Assert-Binding $result $photo
        $predictionReused=$true
    }else{
        # Authenticated response carries the image/run/request binding. The gateway
        # handles a repeated same request id idempotently after an interrupted save.
        $result=Cloud-Request 'POST' 'predict'
        Assert-Binding $result $photo
        Save-Json $resultPath $result
    }
    $timings.prediction_request_or_resume_ms=[math]::Round($phaseClock.Elapsed.TotalMilliseconds,2)
    $phaseClock.Restart()
    if($AuditEvidence){
        $evidence=Cloud-Request 'GET' 'evidence'
        if($evidence.latest_prediction.prediction_id -ne $result.capture_evidence.prediction_id -or $evidence.latest_prediction.image_sha256 -ne $photo.image_sha256){throw 'Server evidence differs from the received prediction.'}
        Save-Json (Join-Path $localRoot 'cloud-evidence.json') $evidence
    }
    $timings.optional_evidence_audit_ms=[math]::Round($phaseClock.Elapsed.TotalMilliseconds,2)
}finally{$client.Dispose();$handler.Dispose()}
$phaseClock.Restart()
$remoteResult=$remoteRoot+'\result.json'
$remoteStat=Invoke-HlBridge @{action='stat';path=$remoteResult}
if(-not $remoteStat.Exists){Invoke-HlBridge @{action='put';local=$resultPath;path=$remoteResult}|Out-Null}
$readback=Join-Path $localRoot ('result-eye-readback-'+[Guid]::NewGuid().ToString('N')+'.json')
Invoke-HlBridge @{action='get';path=$remoteResult;local=$readback}|Out-Null
$eyeResult=Get-Content -LiteralPath $readback -Raw|ConvertFrom-Json
Assert-Binding $eyeResult $photo
if(($eyeResult|ConvertTo-Json -Depth 15 -Compress) -cne ($result|ConvertTo-Json -Depth 15 -Compress)){throw 'Eye result differs from the exact server response.'}
if((Get-FileHash -LiteralPath $readback).Hash -ne (Get-FileHash -LiteralPath $resultPath).Hash){throw 'Eye result readback file hash mismatch.'}
$timings.result_return_and_readback_ms=[math]::Round($phaseClock.Elapsed.TotalMilliseconds,2)
$timings.total_ms=[math]::Round($totalClock.Elapsed.TotalMilliseconds,2)
$receipt=[ordered]@{
    run_id=$run;phase='verified_result_returned_to_eye_storage';at=[DateTimeOffset]::Now.ToString('o')
    device=$connection.DeviceName;request_id=$photo.request_id;image_sha256=$photo.image_sha256
    image_bytes=$photo.image_bytes;prediction_id=$result.capture_evidence.prediction_id
    predicted_class=$result.predicted_class;confidence=$result.confidence;is_valid=$result.is_valid
    eye_result_path=$remoteResult;eye_result_sha256=(Get-FileHash -LiteralPath $readback).Hash.ToLowerInvariant()
    camera_closed=$photo.camera_closed;photo_attempts=$photo.photo_attempts
    prediction_reused=$predictionReused;photo_downloaded=$photoDownloaded
    timings=$timings;evidence_audit_requested=[bool]$AuditEvidence
    ui_rendered_verified=$false;scope='Exact image recognized by existing model and result read back from eye storage; no UI-render claim.'
}
Save-Json (Join-Path $localRoot 'native-transfer-receipt.json') $receipt
Save-Json (Join-Path $localRoot 'workflow.json') $receipt
$receipt|ConvertTo-Json -Depth 8
