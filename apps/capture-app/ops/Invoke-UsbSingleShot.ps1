param(
    [Parameter(Mandatory=$true)][string]$PackageDirectory,
    [string]$SessionFile=(Join-Path (Split-Path -Parent $PSScriptRoot) '.state\session.json'),
    [ValidateRange(5,600)][int]$TimeoutSeconds=90,
    [switch]$Install,
    [switch]$Launch,
    [switch]$AuditEvidence
)
$ErrorActionPreference='Stop'
$captureRoot=Split-Path -Parent $PSScriptRoot
$workspace=Split-Path -Parent (Split-Path -Parent $captureRoot)
. (Join-Path $workspace 'usb-terminal/HoloLens.Common.ps1')
$PackageDirectory=(Resolve-Path -LiteralPath $PackageDirectory).Path
$package=Get-Content -LiteralPath (Join-Path $PackageDirectory 'package-evidence.json') -Raw|ConvertFrom-Json
$session=Get-Content -LiteralPath $SessionFile -Raw|ConvertFrom-Json
$run=[string]$session.run_id
if($run -notmatch '^[A-Za-z0-9_-]{1,64}$' -or $package.run_id -ne $run -or $package.transport -ne 'usb'){throw 'Session and package do not match.'}
if($session.expires_epoch -le [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()){throw 'Cloud session expired; renew this SAME run before proceeding. Do not take another photo.'}
$localRun=Join-Path $captureRoot ('.state\runs\'+$run)
[IO.Directory]::CreateDirectory($localRun)|Out-Null
$remoteLayout='U:\Users\DefaultAccount\AppData\Local\DevelopmentFiles\RiceHoloLensCaptureV1'
$aumid='Rice.HoloLens.Capture_r5420n6798s24!Capture'
$utf8=[Text.UTF8Encoding]::new($false)
function Write-Checkpoint([string]$Phase,$Details){
    $entry=[ordered]@{run_id=$run;phase=$Phase;at=[DateTimeOffset]::Now.ToString('o');details=$Details}
    [IO.File]::WriteAllText((Join-Path $localRun 'workflow.json'),($entry|ConvertTo-Json -Depth 10),$utf8)
    $entry|ConvertTo-Json -Depth 10 -Compress|Write-Output
}
function Put-NewFile([string]$Local,[string]$Remote){
    $stat=Invoke-HlBridge @{action='stat';path=$Remote}
    if(-not $stat.Exists){Invoke-HlBridge @{action='put';local=$Local;path=$Remote}|Out-Null}
}
function Invoke-AsAppUser([string]$Executable,[string]$Parameters){
    $reply=Invoke-HlBridge @{action='exec';executable='C:\Windows\System32\DevToolsLauncher.exe';arguments=('LaunchForDebug '+$Executable+' "'+$Parameters+'" '+$aumid)}
    if($reply.ExitCode -ne 0){throw ('Application-user launch failed: '+$reply.ExitCode+' '+$reply.Output)}
}
function Read-RemoteJson([string]$Path){
    $stat=Invoke-HlBridge @{action='stat';path=$Path}
    if(-not $stat.Exists -or $stat.Length -eq 0){return $null}
    $read=Invoke-HlBridge @{action='cat';path=$Path}
    return $read.Text|ConvertFrom-Json
}
function Invoke-Transfer([string]$Action){
    $name='transfer-'+$Action+'-'+[Guid]::NewGuid().ToString('N')+'.json'
    $remoteReport=$remoteLayout+'\'+$name
    Invoke-AsAppUser $remoteTransfer ('--'+$Action+' '+$run+' --out '+$remoteReport)
    for($i=0;$i -lt 20;$i++){
        $report=Read-RemoteJson $remoteReport
        if($null -ne $report){
            [IO.File]::WriteAllText((Join-Path $localRun $name),($report|ConvertTo-Json -Depth 10),$utf8)
            if($report.argumentError -or $report.outputCreateError -ne 0){throw ('Transfer helper failed: '+($report|ConvertTo-Json -Depth 6 -Compress))}
            if($report.user -eq 'DevToolsUser' -or $report.architecture -ne 'arm64'){throw 'Transfer helper did not run as the eye application user on ARM64.'}
            return $report
        }
        Start-Sleep -Milliseconds 100
    }
    throw 'Transfer report was not observed; inspect the existing invocation before retrying.'
}
function Assert-Result($Result,$Photo){
    $proof=$Result.capture_evidence
    if($null -eq $proof -or $proof.run_id -ne $run -or $proof.request_id -ne $Photo.request_id -or $proof.image_sha256 -ne $Photo.image_sha256 -or $proof.prediction_id -notmatch '^[A-Za-z0-9._-]{1,128}$'){throw 'Cloud result is not bound to this exact eye photograph.'}
    if($Result.is_valid -isnot [bool] -or [string]::IsNullOrWhiteSpace($Result.predicted_class) -or $Result.confidence -lt 0 -or $Result.confidence -gt 1){throw 'Invalid recognition response.'}
}
function Submit-Photo([string]$PhotoPath,$Photo){
    $handler=[Net.Http.HttpClientHandler]::new();$handler.AllowAutoRedirect=$false
    $client=[Net.Http.HttpClient]::new($handler);$client.Timeout=[TimeSpan]::FromSeconds(30)
    $request=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post,'https://rice-srt.cn/hololens/api/predict')
    $response=$null
    try{
        foreach($pair in @(@('X-HoloLens-Token',[string]$session.token),@('X-HoloLens-Run',$run),@('X-Request-ID',[string]$Photo.request_id),@('X-HoloLens-Image-SHA256',[string]$Photo.image_sha256),@('User-Agent','RiceHoloLensUsbBridge/1.0 (actual paired eye capture)'))){$request.Headers.TryAddWithoutValidation($pair[0],$pair[1])|Out-Null}
        $form=[Net.Http.MultipartFormDataContent]::new()
        $content=[Net.Http.StreamContent]::new([IO.File]::OpenRead($PhotoPath))
        $content.Headers.ContentType=[Net.Http.Headers.MediaTypeHeaderValue]::new('image/jpeg')
        $form.Add($content,'file','hololens-single-shot.jpg');$request.Content=$form
        $response=$client.SendAsync($request).GetAwaiter().GetResult()
        $text=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if(-not $response.IsSuccessStatusCode){throw ('Recognition HTTP '+[int]$response.StatusCode)}
        $result=$text|ConvertFrom-Json;Assert-Result $result $Photo
        return $result
    }finally{if($response){$response.Dispose()};$request.Dispose();$client.Dispose();$handler.Dispose()}
}
try{$info=Invoke-HlBridge @{action='info'}}catch{Write-Checkpoint 'waiting_for_device' @{reason=$_.Exception.Message};return}
Write-Checkpoint 'connected' @{device=$info.DeviceName;transport=$info.Transport;address=$info.Address}
if($Install){
    $manifest=Join-Path $PackageDirectory 'layout\AppxManifest.xml'
    $sdk=Join-Path $script:HlConfig.SdkDirectory 'WinAppDeployCmd.exe'
    & $sdk deployfiles -file $manifest -remotedeploydir RiceHoloLensCaptureV1 -ip $info.Address 2>&1|Tee-Object -FilePath (Join-Path $localRun 'deploy-native.log')|Out-Null
    if($LASTEXITCODE -ne 0){throw 'Loose-file deployment failed; inspect saved SDK log.'}
    & $sdk registerfiles -remotedeploydir RiceHoloLensCaptureV1 -ip $info.Address 2>&1|Tee-Object -FilePath (Join-Path $localRun 'register-native.log')|Out-Null
    if($LASTEXITCODE -ne 0){throw 'Application registration failed; inspect saved SDK log.'}
    Write-Checkpoint 'registered' @{version=$package.version}
}
# Native source already has its own one-exposure worker and persistent attempt
# marker. Observe its output directly; the JavaScript page is not a prerequisite.
# No camera operation is ever requested by this observer.
if($package.PSObject.Properties.Name -contains 'capture_source' -and $package.capture_source -eq 'native'){
    if($Launch){
        $uriLocal=Join-Path $captureRoot 'device-research\bin\arm64\hl-uri-launch.exe'
        $remoteUri=$script:HlConfig.RemoteWorkingDirectory+'\hl-uri-launch-'+(Get-FileHash -LiteralPath $uriLocal).Hash.Substring(0,8)+'.exe'
        Put-NewFile $uriLocal $remoteUri
        $launchReport=$remoteLayout+'\launch-native-'+[Guid]::NewGuid().ToString('N')+'.json'
        Invoke-AsAppUser $remoteUri ('rice-hololens-capture://open --out '+$launchReport)
        Write-Checkpoint 'activation_requested' @{report=$launchReport;note='Activation acceptance is not visible UI proof.'}
    }
    $nativeMetadata=$remoteLayout+'\native-shots\'+$run+'\capture.json'
    $nativeDeadline=[DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    while([DateTimeOffset]::UtcNow -lt $nativeDeadline){
        $nativeStat=Invoke-HlBridge @{action='stat';path=$nativeMetadata}
        if($nativeStat.Exists -and $nativeStat.Length -gt 0){
            & (Join-Path $PSScriptRoot 'Complete-NativeSingleShot.ps1') -PackageDirectory $PackageDirectory -SessionFile $SessionFile -AuditEvidence:$AuditEvidence
            return
        }
        Start-Sleep -Milliseconds 100
    }
    Write-Checkpoint 'waiting_for_native_photo' @{note='No new camera attempt requested. Preserve the same run and inspect its existing capture invocation.'}
    return
}
$transferLocal=Join-Path $captureRoot 'device-research\bin\arm64\hl-capture-transfer.exe'
$uriLocal=Join-Path $captureRoot 'device-research\bin\arm64\hl-uri-launch.exe'
$remoteTransfer=$script:HlConfig.RemoteWorkingDirectory+'\hl-capture-transfer-'+(Get-FileHash -LiteralPath $transferLocal).Hash.Substring(0,8)+'.exe'
$remoteUri=$script:HlConfig.RemoteWorkingDirectory+'\hl-uri-launch-'+(Get-FileHash -LiteralPath $uriLocal).Hash.Substring(0,8)+'.exe'
Put-NewFile $transferLocal $remoteTransfer
if($Launch){
    Put-NewFile $uriLocal $remoteUri
    $launchReport=$remoteLayout+'\launch-native-'+[Guid]::NewGuid().ToString('N')+'.json'
    Invoke-AsAppUser $remoteUri ('rice-hololens-capture://open --out '+$launchReport)
    Write-Checkpoint 'activation_requested' @{report=$launchReport;note='Activation acceptance is not camera or result proof.'}
}
$deadline=[DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
while([DateTimeOffset]::UtcNow -lt $deadline){
    $export=Invoke-Transfer 'export'
    $stateFile=$export.files|Where-Object {$_.name -eq 'state.json' -and $_.win32Error -eq 0}|Select-Object -First 1
    if($stateFile){
        $state=Read-RemoteJson $stateFile.destination
        if($null -ne $state -and $state.run_id -eq $run){
            [IO.File]::WriteAllText((Join-Path $localRun 'eye-state.json'),($state|ConvertTo-Json -Depth 12),$utf8)
            if($state.phase -eq 'camera_error' -or $state.phase -eq 'camera_attempt_finished'){Write-Checkpoint 'camera_action_required' $state;return}
            if($state.photo){
                $photo=$state.photo
                if($photo.image_sha256 -notmatch '^[a-f0-9]{64}$' -or $photo.request_id -notmatch '^[A-Za-z0-9._-]{1,64}$' -or $state.runtime -ne 'winrt-media-capture' -or $photo.camera_closed -ne $true){throw 'Eye metadata does not prove the requested camera flow.'}
                $photoPath=Join-Path $localRun 'photo.jpg'
                if(-not (Test-Path -LiteralPath $photoPath)){
                    $photoRemote=$remoteLayout+'\transfer\'+$run+'\photo.jpg'
                    if((Invoke-HlBridge @{action='stat';path=$photoRemote}).Exists){Invoke-HlBridge @{action='get';path=$photoRemote;local=$photoPath}|Out-Null}
                }
                if(Test-Path -LiteralPath $photoPath){
                    if((Get-FileHash -LiteralPath $photoPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $photo.image_sha256 -or (Get-Item -LiteralPath $photoPath).Length -ne $photo.image_bytes){throw 'Transferred JPEG does not match the eye SHA256 and byte length.'}
                    $resultPath=Join-Path $localRun 'result.json'
                    if(Test-Path -LiteralPath $resultPath){$result=Get-Content -LiteralPath $resultPath -Raw|ConvertFrom-Json;Assert-Result $result $photo}
                    else{
                        $result=Submit-Photo $photoPath $photo
                        [IO.File]::WriteAllText($resultPath,($result|ConvertTo-Json -Depth 12),$utf8)
                        Write-Checkpoint 'cloud_result_received' @{request_id=$photo.request_id;image_sha256=$photo.image_sha256;prediction_id=$result.capture_evidence.prediction_id;is_valid=$result.is_valid;predicted_class=$result.predicted_class;confidence=$result.confidence}
                    }
                    if($state.phase -eq 'result_rendered'){
                        if($state.result.prediction_id -ne $result.capture_evidence.prediction_id -or $state.result.request_id -ne $photo.request_id -or $state.result.image_sha256 -ne $photo.image_sha256){throw 'Eye render acknowledgement differs from this exact result.'}
                        Write-Checkpoint 'verified_eye_result_rendered' @{eye_state=(Join-Path $localRun 'eye-state.json');photo=$photoPath;result=$resultPath;request_id=$photo.request_id;image_sha256=$photo.image_sha256;prediction_id=$result.capture_evidence.prediction_id};return
                    }
                    $incoming=$remoteLayout+'\incoming-result-'+$run+'.json'
                    Put-NewFile $resultPath $incoming
                    $import=Invoke-Transfer 'import'
                    $bad=$import.files|Where-Object {$_.win32Error -notin @(0,80,183)}
                    if($bad){throw ('Eye result import failed: '+($bad|ConvertTo-Json -Compress))}
                }
            }
        }
    }
    Start-Sleep -Seconds 2
}
Write-Checkpoint 'waiting_for_eye_state' @{note='No verified render acknowledgement within this bounded observation. Preserve this same run and photo; do not start another capture.'}
