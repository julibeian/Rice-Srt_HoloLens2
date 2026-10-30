param()
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$native=& (Join-Path $PSScriptRoot 'Build-ScreenNative.ps1') -Architecture arm64 | ConvertFrom-Json
$folder=Join-Path $root ('.state/screen-probe/'+[DateTime]::Now.ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6))
$layout=Join-Path $folder 'layout';[IO.Directory]::CreateDirectory((Join-Path $layout 'AppAssets'))|Out-Null
foreach($name in @('index.html','probe.css','probe.js','stats.js','AppxManifest.xml')){Copy-Item -LiteralPath (Join-Path $root ('screen-probe/'+$name)) -Destination (Join-Path $layout $name)}
$assetFolder=@(Get-ChildItem -LiteralPath (Join-Path $root '.state/input-probe') -Directory|Sort-Object LastWriteTime -Descending|Where-Object {Test-Path -LiteralPath (Join-Path $_.FullName 'layout/AppAssets/Logo44.png')}|Select-Object -First 1)
if($assetFolder.Count -ne 1){throw 'Build the existing InputProbe once to provide the existing project icons'}
foreach($size in @(44,50,150)){Copy-Item -LiteralPath (Join-Path $assetFolder[0].FullName ('layout/AppAssets/Logo'+$size+'.png')) -Destination (Join-Path $layout ('AppAssets/Logo'+$size+'.png'))}
Copy-Item -LiteralPath $native.dll -Destination (Join-Path $layout 'Rice.HoloLens.ScreenNative.dll')
Copy-Item -LiteralPath $native.winmd -Destination (Join-Path $layout 'Rice.HoloLens.ScreenNative.winmd')
$version=([xml](Get-Content -LiteralPath (Join-Path $layout 'AppxManifest.xml') -Raw)).Package.Identity.Version
$appx=Join-Path $folder ('Rice.HoloLens.ScreenProbe_'+$version+'_arm64.appx')
& 'C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64\makeappx.exe' pack /d $layout /p $appx /l *> (Join-Path $folder 'makeappx.log')
if($LASTEXITCODE -ne 0){throw ('Screen probe package failed schema validation: '+$folder)}
$proof=[ordered]@{version=$version;package_name='Rice.HoloLens.ScreenProbe';application_id='Probe';layout=$layout;package=$appx;sha256=(Get-FileHash -LiteralPath $appx).Hash;native_build=$native;capabilities=@('graphicsCapture');microphone=$false;webcam=$false;internet=$false;automatic_capture=$false;picker_required=$true;capture_budget_ms=20000;files=@(Get-ChildItem -LiteralPath $layout -File -Recurse|ForEach-Object {@{path=[IO.Path]::GetRelativePath($layout,$_.FullName);sha256=(Get-FileHash -LiteralPath $_.FullName).Hash}});built_at=[DateTimeOffset]::Now.ToString('o');device_runtime_verified=$false}
[IO.File]::WriteAllText((Join-Path $folder 'package-evidence.json'),($proof|ConvertTo-Json -Depth 7),[Text.UTF8Encoding]::new($false))
$proof|ConvertTo-Json -Depth 7
