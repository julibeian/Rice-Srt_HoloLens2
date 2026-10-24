param(
    [string]$SessionFile=(Join-Path (Split-Path -Parent $PSScriptRoot) '.state\session.json'),
    [string]$OutputDirectory=(Join-Path (Split-Path -Parent $PSScriptRoot) ('.state\native-package-'+[DateTime]::Now.ToString('yyyyMMdd-HHmmss'))),
    [switch]$AutoCapture,
    [switch]$NativeCamera,
    [string]$SdkDirectory='C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64'
)
$ErrorActionPreference='Stop'
$session=Get-Content -LiteralPath $SessionFile -Raw|ConvertFrom-Json
if($session.run_id -notmatch '^[A-Za-z0-9_-]{1,64}$'){throw 'Invalid run identifier.'}
if(Test-Path -LiteralPath $OutputDirectory){throw 'Use a fresh output directory; existing packages are preserved.'}
$layout=Join-Path $OutputDirectory 'layout'
$assets=Join-Path $layout 'Assets'
[IO.Directory]::CreateDirectory($assets)|Out-Null
$allow=@('index.html','styles.css','capture-core.js','native-runtime.js','app.js')
foreach($name in $allow){Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $layout $name)}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'AppxManifest.template.xml') -Destination (Join-Path $layout 'AppxManifest.xml')
# Intentionally omit cloud token and all other account/server configuration.
$source=if($NativeCamera){'native'}else{'ui'}
$automatic=[bool]$AutoCapture -and -not $NativeCamera
$eyeSession=[ordered]@{run_id=$session.run_id;transport='usb';autocapture=$automatic;capture_source=$source}
[IO.File]::WriteAllText((Join-Path $layout 'session.json'),($eyeSession|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
Add-Type -AssemblyName System.Drawing
foreach($size in @(44,50,150)){
    $bitmap=[Drawing.Bitmap]::new($size,$size);$graphics=[Drawing.Graphics]::FromImage($bitmap)
    try{
        $graphics.Clear([Drawing.Color]::FromArgb(20,40,58))
        $brush=[Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(141,225,201))
        try{$graphics.FillEllipse($brush,[int]($size*0.24),[int]($size*0.15),[int]($size*0.52),[int]($size*0.70))}finally{$brush.Dispose()}
        $bitmap.Save((Join-Path $assets ('Logo'+$size+'.png')),[Drawing.Imaging.ImageFormat]::Png)
    }finally{$graphics.Dispose();$bitmap.Dispose()}
}
$version=([xml](Get-Content -LiteralPath (Join-Path $layout 'AppxManifest.xml') -Raw)).Package.Identity.Version
$package=Join-Path $OutputDirectory ('Rice.HoloLens.Capture_'+$version+'_neutral_unsigned.appx')
& (Join-Path $SdkDirectory 'makeappx.exe') pack /d $layout /p $package
if($LASTEXITCODE -ne 0){throw 'MakeAppx schema validation or packaging failed.'}
$proof=[ordered]@{version=$version;run_id=$session.run_id;transport='usb';autocapture=$automatic;capture_source=$source;contains_cloud_token=$false;manifest=(Join-Path $layout 'AppxManifest.xml');package=$package;package_sha256=(Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash;scope='Built and schema-validated only; installation and actual camera behavior unverified'}
$proof|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $OutputDirectory 'package-evidence.json') -Encoding utf8
$proof|ConvertTo-Json
