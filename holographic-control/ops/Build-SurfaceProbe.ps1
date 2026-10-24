param([switch]$Deploy,[ValidatePattern('^\d+\.\d+\.\d+\.\d+$')][string]$Version='1.0.0.3')
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$workspace=Split-Path -Parent $root
$folder=Join-Path $root '.state\surface-probe'
$layout=Join-Path $folder 'layout'
[IO.Directory]::CreateDirectory((Join-Path $layout 'Assets'))|Out-Null
Copy-Item -LiteralPath (Join-Path $root 'surface-probe\index.html') -Destination (Join-Path $layout 'index.html') -Force
Copy-Item -LiteralPath (Join-Path $root 'surface-probe\surface-state.js') -Destination (Join-Path $layout 'surface-state.js') -Force
$current=Get-Content -LiteralPath (Join-Path $workspace 'field-app\.state\current-package.txt') -Raw
$fieldPackage=Get-Content -LiteralPath (Join-Path $current.Trim() 'package-evidence.json') -Raw|ConvertFrom-Json
foreach($size in 44,50,150){Copy-Item -LiteralPath (Join-Path $fieldPackage.Layout ('AppAssets\Logo'+$size+'.png')) -Destination (Join-Path $layout ('Assets\Logo'+$size+'.png')) -Force}
$manifest=@'
<?xml version="1.0" encoding="utf-8"?>
<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10" xmlns:uap="http://schemas.microsoft.com/appx/manifest/uap/windows10" IgnorableNamespaces="uap">
 <Identity Name="Rice.HoloLens.SurfaceProbe" Publisher="CN=RiceHoloLensCapture" Version="1.0.0.0" ProcessorArchitecture="neutral" />
 <Properties><DisplayName>全息窗口测试</DisplayName><PublisherDisplayName>Rice Project</PublisherDisplayName><Logo>Assets\Logo50.png</Logo></Properties>
 <Dependencies><TargetDeviceFamily Name="Windows.Universal" MinVersion="10.0.19041.0" MaxVersionTested="10.0.22621.0" /></Dependencies>
 <Resources><Resource Language="zh-CN" /></Resources>
 <Applications><Application Id="Surface" StartPage="index.html"><uap:VisualElements DisplayName="全息窗口测试" Description="独立静态窗口诊断" Square150x150Logo="Assets\Logo150.png" Square44x44Logo="Assets\Logo44.png" BackgroundColor="#176B3A" />
 <Extensions><uap:Extension Category="windows.protocol"><uap:Protocol Name="rice-hololens-surface" ReturnResults="always"><uap:DisplayName>全息窗口测试</uap:DisplayName></uap:Protocol></uap:Extension></Extensions>
 </Application></Applications>
</Package>
'@
[IO.File]::WriteAllText((Join-Path $layout 'AppxManifest.xml'),$manifest.Replace('Version="1.0.0.0"',('Version="'+$Version+'"')),[Text.UTF8Encoding]::new($false))
& 'C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64\makeappx.exe' pack /d $layout /p (Join-Path $folder 'SurfaceProbe.appx') /o *> (Join-Path $folder 'makeappx.log')
if($LASTEXITCODE -ne 0){throw 'Static surface package validation failed.'}
$source=(Get-Content -LiteralPath (Join-Path $workspace 'capture-app\device-research\hl-uri-launch.c') -Raw).Replace('rice-hololens-capture','rice-hololens-surface').Replace('Rice.HoloLens.Capture_r5420n6798s24!Capture','Rice.HoloLens.SurfaceProbe_r5420n6798s24!Surface').Replace('Rice.HoloLens.Capture_r5420n6798s24','Rice.HoloLens.SurfaceProbe_r5420n6798s24')
$file=Join-Path $folder 'hl-surface-launch.c'
[IO.File]::WriteAllText($file,$source,[Text.UTF8Encoding]::new($false))
$env:ZIG_GLOBAL_CACHE_DIR=Join-Path $workspace 'capture-app\device-research\.cache\zig-global'
$env:ZIG_LOCAL_CACHE_DIR=Join-Path $workspace 'capture-app\device-research\.cache\zig-local'
$object=Join-Path $folder 'hl-surface-launch.obj'
$exe=Join-Path $folder 'hl-surface-launch.exe'
& (Join-Path $workspace '.tools\zig-pypi\ziglang\zig.exe') cc -target aarch64-windows-msvc -O2 -std=c11 -fno-stack-protector -fno-builtin -nostdlib -c $file -o $object
if($LASTEXITCODE -ne 0){throw 'Surface launcher compilation failed.'}
& 'C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC\14.44.35207\bin\Hostx64\x64\link.exe' /nologo /NODEFAULTLIB /ENTRY:hl_uri_entry /SUBSYSTEM:CONSOLE /MACHINE:ARM64 /DYNAMICBASE /NXCOMPAT $object 'C:\Program Files (x86)\Windows Kits\10\Lib\10.0.26100.0\um\arm64\OneCore.Lib' ('/OUT:'+$exe)
if($LASTEXITCODE -ne 0){throw 'Surface launcher link failed.'}
foreach($helper in @(@{Name='diagnostic';Source='hl-field-diagnostic.c';Entry='field_diagnostic_entry'},@{Name='stop';Source='hl-field-stop.c';Entry='stop_field_entry'})){
 $helperSource=(Get-Content -LiteralPath (Join-Path $workspace ('field-app\device\'+$helper.Source)) -Raw).Replace('RiceHoloLensFieldV1','RiceHoloLensSurfaceProbe').Replace('Rice.HoloLens.Field_r5420n6798s24','Rice.HoloLens.SurfaceProbe_r5420n6798s24').Replace('app-state.json','surface-state.json')
 $helperFile=Join-Path $folder ('hl-surface-'+$helper.Name+'.c');$helperObj=Join-Path $folder ('hl-surface-'+$helper.Name+'.obj');$helperExe=Join-Path $folder ('hl-surface-'+$helper.Name+'.exe')
 [IO.File]::WriteAllText($helperFile,$helperSource,[Text.UTF8Encoding]::new($false))
 & (Join-Path $workspace '.tools\zig-pypi\ziglang\zig.exe') cc -target aarch64-windows-msvc -O2 -std=c11 -fno-stack-protector -fno-builtin -nostdlib -c $helperFile -o $helperObj
 if($LASTEXITCODE -ne 0){throw ('Surface helper compilation failed: '+$helper.Name)}
 & 'C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC\14.44.35207\bin\Hostx64\x64\link.exe' /nologo /Brepro /NODEFAULTLIB ('/ENTRY:'+$helper.Entry) /SUBSYSTEM:CONSOLE /MACHINE:ARM64 /DYNAMICBASE /NXCOMPAT $helperObj 'C:\Program Files (x86)\Windows Kits\10\Lib\10.0.26100.0\um\arm64\OneCore.Lib' ('/OUT:'+$helperExe)
 if($LASTEXITCODE -ne 0){throw ('Surface helper link failed: '+$helper.Name)}
}
if($Deploy){
    . (Join-Path $workspace 'HoloLens.Common.ps1')
    $info=Invoke-HlBridge @{action='info'}
    $sdk=Join-Path $script:HlConfig.SdkDirectory 'WinAppDeployCmd.exe'
    $base='U:\Users\DefaultAccount\AppData\Local\DevelopmentFiles\RiceHoloLensSurfaceProbe'
    $stopExe=Join-Path $folder 'hl-surface-stop.exe'
    $stopRemote=$base+'\hl-surface-stop-'+(Get-FileHash -LiteralPath $stopExe).Hash.Substring(0,8)+'.exe'
    if(-not(Invoke-HlBridge @{action='stat';path=$stopRemote}).Exists){Invoke-HlBridge @{action='put';local=$stopExe;path=$stopRemote}|Out-Null}
    $stopReport=$base+'\stop-result.json';$before=Invoke-HlBridge @{action='stat';path=$stopReport}
    Invoke-HlBridge @{action='exec';executable='C:\Windows\System32\DevToolsLauncher.exe';arguments=('LaunchForDebug '+$stopRemote+' "stop" Rice.HoloLens.SurfaceProbe_r5420n6798s24!Surface')}|Out-Null
    $stopped=$null
    for($i=0;$i -lt 15;$i++){Start-Sleep -Milliseconds 150;$after=Invoke-HlBridge @{action='stat';path=$stopReport};if($after.Exists -and $after.Length -gt 0 -and (-not $before.Exists -or $after.LastWriteTime -ne $before.LastWriteTime)){$stopped=(Invoke-HlBridge @{action='cat';path=$stopReport}).Text|ConvertFrom-Json;break}}
    if(-not $stopped -or $stopped.error -ne 0 -or $stopped.matched -ne $stopped.terminated){throw 'The isolated surface probe could not be stopped before updating.'}
    [IO.File]::WriteAllText((Join-Path $folder 'stop-before-update.json'),($stopped|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    & $sdk deployfiles -file (Join-Path $layout 'AppxManifest.xml') -remotedeploydir RiceHoloLensSurfaceProbe -ip $info.Address *> (Join-Path $folder 'deploy.log')
    if($LASTEXITCODE -ne 0){throw 'Surface probe deployment failed.'}
    & $sdk registerfiles -remotedeploydir RiceHoloLensSurfaceProbe -ip $info.Address *> (Join-Path $folder 'register.log')
    if($LASTEXITCODE -ne 0){throw 'Surface probe registration failed.'}
}
[ordered]@{Identity='Rice.HoloLens.SurfaceProbe_r5420n6798s24!Surface';Layout=$layout;Launcher=$exe;Package=(Join-Path $folder 'SurfaceProbe.appx');PackageSha256=(Get-FileHash -LiteralPath (Join-Path $folder 'SurfaceProbe.appx')).Hash;Deployed=[bool]$Deploy}|ConvertTo-Json
