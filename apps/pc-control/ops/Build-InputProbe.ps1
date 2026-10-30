param([ValidatePattern('^\d+\.\d+\.\d+\.\d+$')][string]$Version='1.0.0.0')
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$folder=Join-Path $root ('.state\input-probe\'+[DateTime]::Now.ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6))
$layout=Join-Path $folder 'layout'
[IO.Directory]::CreateDirectory((Join-Path $layout 'AppAssets'))|Out-Null
foreach($name in @('index.html','probe.css','probe.js','probe-model.js')){[IO.File]::WriteAllText((Join-Path $layout $name),(Get-Content -LiteralPath (Join-Path $root ('input-probe\'+$name)) -Raw).Replace('1.0.0.0',$Version),[Text.UTF8Encoding]::new($false))}
$manifest=(Get-Content -LiteralPath (Join-Path $root 'input-probe\AppxManifest.xml') -Raw).Replace('Version="1.0.0.0"',('Version="'+$Version+'"'))
[IO.File]::WriteAllText((Join-Path $layout 'AppxManifest.xml'),$manifest,[Text.UTF8Encoding]::new($false))
Add-Type -AssemblyName System.Drawing
foreach($size in @(44,50,150)){
 $bitmap=[Drawing.Bitmap]::new($size,$size);$graphics=[Drawing.Graphics]::FromImage($bitmap)
 try{$graphics.Clear([Drawing.Color]::FromArgb(20,44,73));$pen=[Drawing.Pen]::new([Drawing.Color]::Gold,([single]$size/10));try{$graphics.DrawRectangle($pen,([single]$size/4),([single]$size/4),([single]$size/2),([single]$size/2))}finally{$pen.Dispose()};$bitmap.Save((Join-Path $layout ('AppAssets\Logo'+$size+'.png')),[Drawing.Imaging.ImageFormat]::Png)}finally{$graphics.Dispose();$bitmap.Dispose()}
}
$package=Join-Path $folder ('Rice.HoloLens.InputProbe_'+$Version+'_neutral.appx')
& 'C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64\makeappx.exe' pack /d $layout /p $package /l *> (Join-Path $folder 'makeappx.log')
if($LASTEXITCODE -ne 0){throw ('Input probe packaging failed; inspect '+$folder)}
$proof=[ordered]@{version=$Version;package=$package;layout=$layout;sha256=(Get-FileHash -LiteralPath $package).Hash;package_name='Rice.HoloLens.InputProbe';application_id='Probe';built_at=[DateTimeOffset]::Now.ToString('o');files=@(Get-ChildItem -LiteralPath $layout -File -Recurse|ForEach-Object {@{path=[IO.Path]::GetRelativePath($layout,$_.FullName);sha256=(Get-FileHash -LiteralPath $_.FullName).Hash}});capabilities=@();separate_from_field_app=$true}
[IO.File]::WriteAllText((Join-Path $folder 'package-evidence.json'),($proof|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
$proof|ConvertTo-Json -Depth 5
