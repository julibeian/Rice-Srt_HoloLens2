$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$workspace=Split-Path -Parent $root
$build=Join-Path $root '.state\network-probe'
[IO.Directory]::CreateDirectory($build)|Out-Null
$source=(Get-Content -LiteralPath (Join-Path $workspace 'capture-app\device-research\hl-network-probe.c') -Raw).Replace('/hololens/api/health','/hololens-app/api/health')
$file=Join-Path $build 'hl-field-network.c'
[IO.File]::WriteAllText($file,$source,[Text.UTF8Encoding]::new($false))
$env:ZIG_GLOBAL_CACHE_DIR=Join-Path $workspace 'capture-app\device-research\.cache\zig-global'
$env:ZIG_LOCAL_CACHE_DIR=Join-Path $workspace 'capture-app\device-research\.cache\zig-local'
$object=Join-Path $build 'hl-field-network.obj'
$exe=Join-Path $build 'hl-field-network.exe'
& (Join-Path $workspace '.tools\zig-pypi\ziglang\zig.exe') cc -target aarch64-windows-msvc -O2 -std=c11 -fno-stack-protector -fno-builtin -nostdlib -c $file -o $object
if($LASTEXITCODE -ne 0){throw 'Network probe compile failed.'}
$libraries='C:\Program Files (x86)\Windows Kits\10\Lib\10.0.26100.0\um\arm64'
$deps=@('OneCore.Lib','Winhttp.lib','Iphlpapi.lib','Ws2_32.lib')|ForEach-Object{Join-Path $libraries $_}
& 'C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC\14.44.35207\bin\Hostx64\x64\link.exe' /nologo /NODEFAULTLIB /ENTRY:hl_network_entry /SUBSYSTEM:CONSOLE /MACHINE:ARM64 /DYNAMICBASE /NXCOMPAT $object @deps ('/OUT:'+$exe)
if($LASTEXITCODE -ne 0){throw 'Network probe link failed.'}
Get-FileHash -LiteralPath $exe|Select-Object Path,Hash|ConvertTo-Json -Compress
