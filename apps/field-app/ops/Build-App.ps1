param([ValidatePattern('^\d+\.\d+\.\d+\.\d+$')][string]$Version='1.0.0.64',[switch]$CameraDiagnostics,[ValidateSet(320,416,640)][int]$InputSize=320,[string]$NativePackageDirectory,[string]$ModelDirectory,[switch]$ReuseTensors=$true,[switch]$ResourceTelemetry,[int]$CameraWidth=0,[int]$CameraHeight=0,[double]$CameraFps=0)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
if(($CameraWidth -ne 0 -or $CameraHeight -ne 0 -or $CameraFps -ne 0) -and (-not $ResourceTelemetry -or $CameraWidth -lt 160 -or $CameraWidth -gt 4096 -or $CameraHeight -lt 120 -or $CameraHeight -gt 4096 -or $CameraFps -lt 1 -or $CameraFps -gt 120)){throw 'Exact camera parameters require ResourceTelemetry and a valid size/rate'}
$folder=Join-Path $root ('.state\packages\'+[DateTime]::Now.ToString('yyyyMMdd-HHmmss')+'-'+$Version)
$layout=Join-Path $folder 'layout'
if($NativePackageDirectory){
 if($PSBoundParameters.ContainsKey('ReuseTensors')){throw 'Select a new native build for ReuseTensors; a source package already fixes the native binary'}
 $existingNative=Get-Content -LiteralPath (Join-Path $NativePackageDirectory 'package-evidence.json') -Raw|ConvertFrom-Json
 if($existingNative.InputSize -ne $InputSize -or (Get-FileHash -LiteralPath $existingNative.Package).Hash -cne $existingNative.Sha256){throw 'Native source package identity or input size differs'}
 $existingDll=Join-Path $existingNative.Layout 'Rice.HoloLens.Yolo.dll'
 $existingWinmd=Join-Path $existingNative.Layout 'Rice.HoloLens.Yolo.winmd'
 if((Get-FileHash -LiteralPath $existingDll).Hash -cne $existingNative.NativeDllSha256 -or -not(Test-Path -LiteralPath $existingWinmd)){throw 'Existing native component hash differs'}
 $nativeProof=[pscustomobject]@{Dll=$existingDll;Winmd=$existingWinmd;DllSha256=$existingNative.NativeDllSha256;ReuseTensors=if($existingNative.PSObject.Properties['ReuseTensors']){$existingNative.ReuseTensors}else{$null}}
}else{$nativeProof=& (Join-Path $PSScriptRoot 'Build-YoloNative.ps1') -InputSize $InputSize -ReuseTensors:$ReuseTensors|ConvertFrom-Json}
$modelRoot=if($ModelDirectory){[IO.Path]::GetFullPath($ModelDirectory)}elseif($NativePackageDirectory){$existingNative.Layout}else{Join-Path $root $(if($InputSize -eq 320){'.state/yolo-320-fp16'}elseif($InputSize -eq 640){'.state/yolo'}else{'.state/yolo-'+$InputSize})}
$modelProof=Get-Content -LiteralPath (Join-Path $modelRoot 'model-manifest.json') -Raw|ConvertFrom-Json
if($modelProof.input_size -ne $InputSize -or @($modelProof.parity).Count -lt 6 -or (Get-FileHash -LiteralPath $modelProof.path).Hash.ToLowerInvariant() -cne $modelProof.sha256 -or @($modelProof.parity|Where-Object {-not $_.allclose}).Count -ne 0){throw 'YOLO model identity or conversion verification failed'}
& node (Join-Path $root 'build.mjs') $layout
if($LASTEXITCODE -ne 0){throw 'Front-end conversion failed.'}
$manifest=Get-Content -LiteralPath (Join-Path $root 'AppxManifest.xml') -Raw -Encoding utf8
$manifest=$manifest.Replace('Version="1.0.0.0"',('Version="'+$Version+'"'))
$utf8=[Text.UTF8Encoding]::new($false)
$entryHtml=Get-Content -LiteralPath (Join-Path $layout 'index.html') -Raw -Encoding utf8
$scriptFiles=@()
foreach($scriptName in @('boot.js','camera-controls.js','dynamic.js','native.js','app.js')){
 $original=Join-Path $layout $scriptName
 $scriptHash=(Get-FileHash -LiteralPath $original).Hash
 $parent=[IO.Path]::GetDirectoryName($scriptName).Replace('\','/')
 $hashedName=[IO.Path]::GetFileNameWithoutExtension($scriptName)+'-'+$scriptHash.Substring(0,12).ToLowerInvariant()+'.js'
 $relative=if($parent){$parent+'/'+$hashedName}else{$hashedName}
 Copy-Item -LiteralPath $original -Destination (Join-Path $layout $relative)
 $entryHtml=$entryHtml.Replace(('src="'+$scriptName+'"'),('src="'+$relative+'"'))
 $scriptFiles+=@{Source=$scriptName;Deployed=$relative;Sha256=$scriptHash}
}
$entryPage='index-'+$Version.Replace('.','-')+'.html'
[IO.File]::WriteAllText((Join-Path $layout $entryPage),$entryHtml,$utf8)
$manifest=$manifest.Replace('StartPage="index.html"',('StartPage="'+$entryPage+'"'))
[IO.File]::WriteAllText((Join-Path $layout 'AppxManifest.xml'),$manifest,$utf8)
$config=Get-Content -LiteralPath (Join-Path $layout 'config.json') -Raw|ConvertFrom-Json
$config.version=$Version
$config.yoloSha256=$modelProof.sha256
$precision=if($modelProof.PSObject.Properties['precision']){$modelProof.precision}else{'FP32'}
$config|Add-Member -NotePropertyName yoloPrecision -NotePropertyValue $precision -Force
$config|Add-Member -NotePropertyName yoloInputSize -NotePropertyValue $InputSize -Force
$config|Add-Member -NotePropertyName cameraDiagnostics -NotePropertyValue ([bool]$CameraDiagnostics) -Force
$config|Add-Member -NotePropertyName resourceTelemetry -NotePropertyValue ([bool]$ResourceTelemetry) -Force
$config|Add-Member -NotePropertyName cameraCaptureRequest -NotePropertyValue $(if($CameraWidth){@{width=$CameraWidth;height=$CameraHeight;fps=$CameraFps}}else{$null}) -Force
[IO.File]::WriteAllText((Join-Path $layout 'config.json'),($config|ConvertTo-Json -Depth 8),$utf8)
Copy-Item -LiteralPath $nativeProof.Dll -Destination (Join-Path $layout 'Rice.HoloLens.Yolo.dll')
Copy-Item -LiteralPath $nativeProof.Winmd -Destination (Join-Path $layout 'Rice.HoloLens.Yolo.winmd')
Copy-Item -LiteralPath $modelProof.path -Destination (Join-Path $layout 'model.onnx')
Copy-Item -LiteralPath (Join-Path $modelRoot 'model-manifest.json') -Destination (Join-Path $layout 'model-manifest.json')
Add-Type -AssemblyName System.Drawing
$assets=Join-Path $layout 'AppAssets'
[IO.Directory]::CreateDirectory($assets)|Out-Null
$image=[Drawing.Image]::FromFile((Join-Path $layout 'assets\brand-logo.png'))
try{
 foreach($size in @(44,50,150)){
  $bitmap=[Drawing.Bitmap]::new($size,$size);$graphics=[Drawing.Graphics]::FromImage($bitmap)
  try{$graphics.Clear([Drawing.Color]::FromArgb(247,245,236));$graphics.InterpolationMode=[Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic;$graphics.DrawImage($image,0,0,$size,$size);$bitmap.Save((Join-Path $assets ('Logo'+$size+'.png')),[Drawing.Imaging.ImageFormat]::Png)}finally{$graphics.Dispose();$bitmap.Dispose()}
 }
}finally{$image.Dispose()}
$package=Join-Path $folder ('Rice.HoloLens.Field_'+$Version+'_arm64.appx')
& 'C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64\makeappx.exe' pack /d $layout /p $package /l *> (Join-Path $folder 'makeappx.log')
if($LASTEXITCODE -ne 0){Get-Content -LiteralPath (Join-Path $folder 'makeappx.log') -Tail 25;throw 'Appx validation or packaging failed.'}
$proof=[ordered]@{Version=$Version;Package=$package;Layout=$layout;EntryPage=$entryPage;ScriptFiles=$scriptFiles;Sha256=(Get-FileHash -LiteralPath $package).Hash;Identity='Rice.HoloLens.Field_r5420n6798s24!Field';RecognitionMode='local-yolo';InputSize=$InputSize;ModelSha256=$modelProof.sha256;ModelPrecision=$precision;NativeDllSha256=$nativeProof.DllSha256;ReuseTensors=$nativeProof.ReuseTensors;IncludesDeviceKey=$false;IncludesCampusCredentials=$false;BuiltAt=[DateTimeOffset]::Now.ToString('o')}
[IO.File]::WriteAllText((Join-Path $folder 'package-evidence.json'),($proof|ConvertTo-Json),$utf8)
[IO.File]::WriteAllText((Join-Path $root '.state\current-package.txt'),$folder,$utf8)
$proof|ConvertTo-Json -Compress
