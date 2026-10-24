param([switch]$BuildOnly)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$workspace=Split-Path -Parent $root
$build=Join-Path $root '.state\native-debug'
[IO.Directory]::CreateDirectory($build)|Out-Null
$file=Join-Path $root 'device\hl-native-watch.c';$obj=Join-Path $build 'hl-native-watch.obj';$exe=Join-Path $build 'hl-native-watch.exe'
$env:ZIG_GLOBAL_CACHE_DIR=Join-Path $workspace 'capture-app\device-research\.cache\zig-global'
$env:ZIG_LOCAL_CACHE_DIR=Join-Path $workspace 'capture-app\device-research\.cache\zig-local'
& (Join-Path $workspace '.tools\zig-pypi\ziglang\zig.exe') cc -target aarch64-windows-msvc -O2 -std=c11 -fno-stack-protector -fno-builtin -nostdlib -c $file -o $obj
if($LASTEXITCODE -ne 0){throw 'Native watcher compilation failed.'}
$libs='C:\Program Files (x86)\Windows Kits\10\Lib\10.0.26100.0\um\arm64'
& 'C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC\14.44.35207\bin\Hostx64\x64\link.exe' /nologo /Brepro /NODEFAULTLIB /ENTRY:launch_watch_entry /SUBSYSTEM:CONSOLE /MACHINE:ARM64 /DYNAMICBASE /NXCOMPAT $obj (Join-Path $libs 'OneCore.Lib') (Join-Path $libs 'RuntimeObject.Lib') ('/OUT:'+$exe)
if($LASTEXITCODE -ne 0){throw 'Native watcher link failed.'}
if($BuildOnly){[ordered]@{Executable=$exe;Sha256=(Get-FileHash -LiteralPath $exe).Hash;DeviceContacted=$false}|ConvertTo-Json;return}
. (Join-Path $workspace 'HoloLens.Common.ps1')
$base='U:\Users\DefaultAccount\AppData\Local\DevelopmentFiles\RiceHoloLensNativeSurface'
$remote=$base+'\hl-native-watch-'+(Get-FileHash -LiteralPath $exe).Hash.Substring(0,8)+'.exe'
if(-not(Invoke-HlBridge @{action='stat';path=$remote}).Exists){Invoke-HlBridge @{action='put';local=$exe;path=$remote}|Out-Null}
$out=$base+'\native-debug-'+[Guid]::NewGuid().ToString('N')+'.json'
Invoke-HlBridge @{action='exec';executable='C:\Windows\System32\DevToolsLauncher.exe';arguments=('LaunchForDebug '+$remote+' "'+$out+' --debug" Rice.HoloLens.NativeSurface_r5420n6798s24!Native')}|Out-Null
$launcher=Join-Path $root '.state\native-surface\hl-native-launch.exe'
$launchRemote=$base+'\hl-native-launch-'+(Get-FileHash -LiteralPath $launcher).Hash.Substring(0,8)+'.exe'
if(-not(Invoke-HlBridge @{action='stat';path=$launchRemote}).Exists){Invoke-HlBridge @{action='put';local=$launcher;path=$launchRemote}|Out-Null}
$launchOut=$base+'\native-debug-request-'+[Guid]::NewGuid().ToString('N')+'.json'
Invoke-HlBridge @{action='exec';executable='C:\Windows\System32\DevToolsLauncher.exe';arguments=('LaunchForDeploy '+$launchRemote+' "rice-hololens-native://open --activate-app --out '+$launchOut+'"')}|Out-Null
$captured=$null
for($i=0;$i -lt 75;$i++){
 Start-Sleep -Milliseconds 300
 $stat=Invoke-HlBridge @{action='stat';path=$out}
 if($stat.Exists -and $stat.Length -gt 0){$captured=(Invoke-HlBridge @{action='cat';path=$out}).Text;break}
}
if(-not $captured){throw ('Debugger observation is pending; do not restart it: '+$out)}
$evidence=Join-Path $build ('debug-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.json')
[IO.File]::WriteAllText($evidence,$captured,[Text.UTF8Encoding]::new($false))
$captured
