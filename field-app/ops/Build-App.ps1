param([ValidatePattern('^\d+\.\d+\.\d+\.\d+$')][string]$Version='1.0.0.0',[switch]$CameraDiagnostics)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$folder=Join-Path $root ('.state\packages\'+[DateTime]::Now.ToString('yyyyMMdd-HHmmss')+'-'+$Version)
$layout=Join-Path $folder 'layout'
& node (Join-Path $root 'build.mjs') $layout
if($LASTEXITCODE -ne 0){throw 'Front-end conversion failed.'}
$manifest=Get-Content -LiteralPath (Join-Path $root 'AppxManifest.xml') -Raw -Encoding utf8
$manifest=$manifest.Replace('Version="1.0.0.0"',('Version="'+$Version+'"'))
$utf8=[Text.UTF8Encoding]::new($false)
$entryHtml=Get-Content -LiteralPath (Join-Path $layout 'index.html') -Raw -Encoding utf8
$scriptFiles=@()
foreach($scriptName in @('boot.js','vendor/leaflet/leaflet.js','capture-quality.js','camera-controls.js','native.js','bridge.js','miniapp.js','app.js')){
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
$config|Add-Member -NotePropertyName cameraDiagnostics -NotePropertyValue ([bool]$CameraDiagnostics) -Force
[IO.File]::WriteAllText((Join-Path $layout 'config.json'),($config|ConvertTo-Json),$utf8)
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
$package=Join-Path $folder ('Rice.HoloLens.Field_'+$Version+'_neutral.appx')
& 'C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64\makeappx.exe' pack /d $layout /p $package /l *> (Join-Path $folder 'makeappx.log')
if($LASTEXITCODE -ne 0){Get-Content -LiteralPath (Join-Path $folder 'makeappx.log') -Tail 25;throw 'Appx validation or packaging failed.'}
$proof=[ordered]@{Version=$Version;Package=$package;Layout=$layout;EntryPage=$entryPage;ScriptFiles=$scriptFiles;Sha256=(Get-FileHash -LiteralPath $package).Hash;Identity='Rice.HoloLens.Field_r5420n6798s24!Field';IncludesDeviceKey=$false;IncludesCampusCredentials=$false;BuiltAt=[DateTimeOffset]::Now.ToString('o')}
[IO.File]::WriteAllText((Join-Path $folder 'package-evidence.json'),($proof|ConvertTo-Json),$utf8)
[IO.File]::WriteAllText((Join-Path $root '.state\current-package.txt'),$folder,$utf8)
$proof|ConvertTo-Json -Compress
