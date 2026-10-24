param([switch]$Deploy,[ValidatePattern('^\d+\.\d+\.\d+\.\d+$')][string]$Version='1.0.0.5')
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$workspace=Split-Path -Parent $root
$folder=Join-Path $root '.state\native-surface'
$layout=Join-Path $folder 'layout'
[IO.Directory]::CreateDirectory($layout)|Out-Null
Copy-Item -LiteralPath (Join-Path $root '.state\surface-probe\layout\Assets') -Destination $layout -Recurse -Force
$includes=@('-isystem','C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC\14.44.35207\include')
foreach($part in 'um','shared','ucrt','winrt'){$includes+=@('-isystem',('C:\Program Files (x86)\Windows Kits\10\Include\10.0.26100.0\'+$part))}
$object=Join-Path $folder 'native-host.obj'
$exe=Join-Path $layout 'NativeSurface.exe'
$env:ZIG_GLOBAL_CACHE_DIR=Join-Path $workspace 'capture-app\device-research\.cache\zig-global'
$env:ZIG_LOCAL_CACHE_DIR=Join-Path $workspace 'capture-app\device-research\.cache\zig-local'
& (Join-Path $workspace '.tools\zig-pypi\ziglang\zig.exe') cc -target aarch64-windows-msvc -O2 -std=c11 -fno-stack-protector -fno-builtin -nostdlib @includes -c (Join-Path $root 'surface-probe\native-host.c') -o $object
if($LASTEXITCODE -ne 0){throw 'Native surface compilation failed.'}
$lib='C:\Program Files (x86)\Windows Kits\10\Lib\10.0.26100.0\um\arm64'
& 'C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC\14.44.35207\bin\Hostx64\x64\link.exe' /nologo /Brepro /NODEFAULTLIB /ENTRY:native_surface_entry /SUBSYSTEM:WINDOWS /APPCONTAINER /MACHINE:ARM64 /DYNAMICBASE /NXCOMPAT /OPT:REF $object (Join-Path $lib 'OneCore.Lib') (Join-Path $lib 'RuntimeObject.lib') (Join-Path $lib 'uuid.lib') (Join-Path $lib 'd3d11.lib') ('/OUT:'+$exe)
if($LASTEXITCODE -ne 0){throw 'Native surface link failed.'}
$manifest=@'
<?xml version="1.0" encoding="utf-8"?>
<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10" xmlns:uap="http://schemas.microsoft.com/appx/manifest/uap/windows10" IgnorableNamespaces="uap">
 <Identity Name="Rice.HoloLens.NativeSurface" Publisher="CN=RiceHoloLensCapture" Version="1.0.0.0" ProcessorArchitecture="arm64" />
 <Properties><DisplayName>原生全息窗口测试</DisplayName><PublisherDisplayName>Rice Project</PublisherDisplayName><Logo>Assets\Logo50.png</Logo></Properties>
 <Dependencies><TargetDeviceFamily Name="Windows.Holographic" MinVersion="10.0.19041.0" MaxVersionTested="10.0.22621.0" /></Dependencies>
 <Resources><Resource Language="zh-CN" /></Resources>
 <Applications><Application Id="Native" Executable="NativeSurface.exe" EntryPoint="Rice.HoloLens.NativeSurface.App"><uap:VisualElements DisplayName="原生全息窗口测试" Description="限时原生窗口生命周期诊断" Square150x150Logo="Assets\Logo150.png" Square44x44Logo="Assets\Logo44.png" BackgroundColor="#176B3A" />
 <Extensions><uap:Extension Category="windows.protocol"><uap:Protocol Name="rice-hololens-native"><uap:DisplayName>原生全息窗口测试</uap:DisplayName></uap:Protocol></uap:Extension></Extensions>
 </Application></Applications>
</Package>
'@
[IO.File]::WriteAllText((Join-Path $layout 'AppxManifest.xml'),$manifest.Replace('Version="1.0.0.0"',('Version="'+$Version+'"')),[Text.UTF8Encoding]::new($false))
& 'C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64\makeappx.exe' pack /d $layout /p (Join-Path $folder 'NativeSurface.appx') /o *> (Join-Path $folder 'makeappx.log')
if($LASTEXITCODE -ne 0){throw 'Native surface package validation failed.'}
$launchSource=(Get-Content -LiteralPath (Join-Path $workspace 'capture-app\device-research\hl-uri-launch.c') -Raw).Replace('rice-hololens-capture','rice-hololens-native').Replace('Rice.HoloLens.Capture_r5420n6798s24!Capture','Rice.HoloLens.NativeSurface_r5420n6798s24!Native').Replace('Rice.HoloLens.Capture_r5420n6798s24','Rice.HoloLens.NativeSurface_r5420n6798s24')
$launchFile=Join-Path $folder 'hl-native-launch.c'
[IO.File]::WriteAllText($launchFile,$launchSource,[Text.UTF8Encoding]::new($false))
$launchObj=Join-Path $folder 'hl-native-launch.obj';$launchExe=Join-Path $folder 'hl-native-launch.exe'
& (Join-Path $workspace '.tools\zig-pypi\ziglang\zig.exe') cc -target aarch64-windows-msvc -O2 -std=c11 -fno-stack-protector -fno-builtin -nostdlib -c $launchFile -o $launchObj
if($LASTEXITCODE -ne 0){throw 'Native surface launcher compilation failed.'}
& 'C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC\14.44.35207\bin\Hostx64\x64\link.exe' /nologo /Brepro /NODEFAULTLIB /ENTRY:hl_uri_entry /SUBSYSTEM:CONSOLE /MACHINE:ARM64 /DYNAMICBASE /NXCOMPAT $launchObj (Join-Path $lib 'OneCore.Lib') ('/OUT:'+$launchExe)
if($LASTEXITCODE -ne 0){throw 'Native surface launcher link failed.'}
foreach($helper in @(@{Name='diagnostic';Source='hl-field-diagnostic.c';Entry='field_diagnostic_entry'},@{Name='process';Source='hl-field-process.c';Entry='field_process_entry'})){
 $helperSource=(Get-Content -LiteralPath (Join-Path $workspace ('field-app\device\'+$helper.Source)) -Raw).Replace('RiceHoloLensFieldV1','RiceHoloLensNativeSurface').Replace('Rice.HoloLens.Field_r5420n6798s24','Rice.HoloLens.NativeSurface_r5420n6798s24').Replace('app-state.json','native-state.json').Replace('"hl-field"','"nativesurface"').Replace('#include "../../native/hl-report-path.h"',('#include "'+(Join-Path $workspace 'native\hl-report-path.h').Replace('\','/')+'"'))
 $helperFile=Join-Path $folder ('hl-native-'+$helper.Name+'.c');$helperObj=Join-Path $folder ('hl-native-'+$helper.Name+'.obj');$helperExe=Join-Path $folder ('hl-native-'+$helper.Name+'.exe')
 [IO.File]::WriteAllText($helperFile,$helperSource,[Text.UTF8Encoding]::new($false))
 & (Join-Path $workspace '.tools\zig-pypi\ziglang\zig.exe') cc -target aarch64-windows-msvc -O2 -std=c11 -fno-stack-protector -fno-builtin -nostdlib -c $helperFile -o $helperObj
 if($LASTEXITCODE -ne 0){throw ('Native surface helper compilation failed: '+$helper.Name)}
 & 'C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC\14.44.35207\bin\Hostx64\x64\link.exe' /nologo /Brepro /NODEFAULTLIB ('/ENTRY:'+$helper.Entry) /SUBSYSTEM:CONSOLE /MACHINE:ARM64 /DYNAMICBASE /NXCOMPAT $helperObj (Join-Path $lib 'OneCore.Lib') ('/OUT:'+$helperExe)
 if($LASTEXITCODE -ne 0){throw ('Native surface helper link failed: '+$helper.Name)}
}
if($Deploy){
 . (Join-Path $workspace 'HoloLens.Common.ps1')
 $info=Invoke-HlBridge @{action='info'};$sdk=Join-Path $script:HlConfig.SdkDirectory 'WinAppDeployCmd.exe'
 & $sdk deployfiles -file (Join-Path $layout 'AppxManifest.xml') -remotedeploydir RiceHoloLensNativeSurface -ip $info.Address *> (Join-Path $folder 'deploy.log')
 if($LASTEXITCODE -ne 0){throw 'Native surface deployment failed.'}
 & $sdk registerfiles -remotedeploydir RiceHoloLensNativeSurface -ip $info.Address *> (Join-Path $folder 'register.log')
 if($LASTEXITCODE -ne 0){throw 'Native surface registration failed.'}
}
[ordered]@{Identity='Rice.HoloLens.NativeSurface_r5420n6798s24!Native';Executable=$exe;Layout=$layout;Deployed=[bool]$Deploy}|ConvertTo-Json
