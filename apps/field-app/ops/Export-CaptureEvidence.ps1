param([string]$RuntimeEvidence)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$workspace=Split-Path -Parent (Split-Path -Parent $root)
. (Join-Path $workspace 'apps/holographic-control\ops\Holographic.Common.ps1')
if(-not $RuntimeEvidence){$RuntimeEvidence=(Get-Content -LiteralPath (Join-Path $root '.state\runtime-status.json') -Raw|ConvertFrom-Json).Evidence}
$evidencePath=[IO.Path]::GetFullPath($RuntimeEvidence)
$diagnosticRoot=[IO.Path]::GetFullPath((Join-Path $root '.state\diagnostics'))+[IO.Path]::DirectorySeparatorChar
if(-not $evidencePath.StartsWith($diagnosticRoot,[StringComparison]::OrdinalIgnoreCase)){throw 'Use a saved diagnostic from this application.'}
$state=Get-Content -LiteralPath (Join-Path $evidencePath 'app-state.json') -Raw|ConvertFrom-Json
$installed=Get-Content -LiteralPath (Join-Path $root '.state\installed.json') -Raw|ConvertFrom-Json
if($installed.Identity -cne 'Rice.HoloLens.Field_r5420n6798s24!Field' -or $state.version -cne $installed.Version -or $state.runtimeSession -notmatch '^[a-f0-9]{16,64}$'){throw 'The snapshot is not from the currently installed Field version.'}
$events=@($state.events|Where-Object{$_.session -ceq $state.runtimeSession})
$names=@('capture_requested','raw_photo_captured','photo_captured','upload_started','prediction_received','history_saved')
$selected=@{};$last=-1
foreach($name in $names){
    $index=-1;for($i=$last+1;$i -lt $events.Count;$i++){if($events[$i].event -eq $name){$index=$i;break}}
    if($index -lt 0){throw ('The saved session lacks an ordered '+$name+' event.')}
    $selected[$name]=$events[$index];$last=$index
}
$upload=$selected.upload_started.details;$prediction=$selected.prediction_received.details
if($upload.request_id -cne $prediction.request_id -or $upload.image_sha256 -cne $prediction.image_sha256 -or $upload.image_sha256 -notmatch '^[a-f0-9]{64}$'){throw 'Upload and prediction identity do not match.'}
$record=([long]$selected.history_saved.details.record_id).ToString([Globalization.CultureInfo]::InvariantCulture)
if($record -notmatch '^\d{10,16}$'){throw 'Unexpected history identity.'}
$folder=Join-Path $root ('.state\capture-evidence\'+$state.runtimeSession+'-'+$record)
$resultPath=Join-Path $folder 'verification.json'
if(Test-Path -LiteralPath $resultPath){Get-Content -LiteralPath $resultPath -Raw;return}
[IO.Directory]::CreateDirectory($folder)|Out-Null
$context=New-HoloAuthenticatedPortalContext
try {
    $response=$context.Client.GetAsync($context.BaseUri+'/api/app/packagemanager/packages').GetAwaiter().GetResult()
    try {
        if([int]$response.StatusCode -ne 200){throw 'Current package inventory is unavailable.'}
        $packages=($response.Content.ReadAsStringAsync().GetAwaiter().GetResult()|ConvertFrom-Json).InstalledPackages
        # HoloLens reports its Name in PackageFamilyName; match the full AUMID.
        $package=@($packages|Where-Object{$_.PackageRelativeId -ceq $installed.Identity})
        if($package.Count -ne 1 -or $package[0].PackageFullName -cne ('Rice.HoloLens.Field_'+$installed.Version+'_neutral__r5420n6798s24')){throw 'Unexpected installed package identity.'}
        $package=$package[0]
    } finally {$response.Dispose()}
    $files=@()
    foreach($kind in @('source','crop')){
        $name=if($kind -eq 'source'){'rice_'+$record+'_source.jpg'}else{'rice_'+$record+'_0.jpg'}
        $expectedBytes=[long]$(if($kind -eq 'source'){$selected.raw_photo_captured.details.bytes}else{$selected.photo_captured.details.bytes})
        if($expectedBytes -le 0 -or $expectedBytes -gt 8388608){throw 'Unexpected image size.'}
        $path=Join-Path $folder $name
        if(-not(Test-Path -LiteralPath $path)){
            $uri=$context.BaseUri+'/api/filesystem/apps/file?knownfolderid=LocalAppData&packagefullname='+[uri]::EscapeDataString($package.PackageFullName)+'&path='+[uri]::EscapeDataString('\LocalState')+'&filename='+[uri]::EscapeDataString($name)
            $response=$context.Client.GetAsync($uri).GetAwaiter().GetResult()
            try {
                if([int]$response.StatusCode -ne 200){throw ('The recorded '+$kind+' image is unavailable.')}
                $bytes=$response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
                if($bytes.Length -ne $expectedBytes){throw 'Image byte count differs from the capture event.'}
                $file=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
                try{$file.Write($bytes,0,$bytes.Length)}finally{$file.Dispose()}
            } finally {$response.Dispose()}
        }
        $actual=(Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant()
        if((Get-Item -LiteralPath $path).Length -ne $expectedBytes -or ($kind -eq 'crop' -and $actual -cne $upload.image_sha256)){throw 'Downloaded photo does not match the recorded upload.'}
        $files += [ordered]@{Kind=$kind;Name=$name;Path=$path;Bytes=$expectedBytes;Sha256=$actual}
    }
    $proof=[ordered]@{At=[DateTimeOffset]::Now.ToString('o');Version=$installed.Version;PackageFullName=$package.PackageFullName;RuntimeSession=$state.runtimeSession;CaptureAtDeviceUtc=$selected.capture_requested.at;RuntimeEvidence=$evidencePath;RequestId=$upload.request_id;PredictionId=$prediction.prediction_id;ImageSha256=$upload.image_sha256;UploadedFileVerified=$true;PipelineVerified=$true;CropWidth=$selected.photo_captured.details.width;CropHeight=$selected.photo_captured.details.height;Sharpness=$selected.photo_captured.details.sharpness;IsValidLeaf=$prediction.is_valid;PredictedClass=$prediction.predicted_class;Files=$files;Events=@($names|ForEach-Object{$selected[$_]});Scope='Current-version camera, crop and upload integrity. A rejected non-leaf does not validate leaf recognition accuracy or lighting generalization.'}
    [IO.File]::WriteAllText($resultPath,($proof|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
    [pscustomobject]$proof|Select-Object At,Version,RuntimeSession,RequestId,PredictionId,ImageSha256,UploadedFileVerified,PipelineVerified,CropWidth,CropHeight,IsValidLeaf,PredictedClass,Files|ConvertTo-Json -Depth 5
}finally{$context.Client.Dispose()}
