$ErrorActionPreference='Stop'
$workspace=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$build=Join-Path $workspace 'holographic-control/.state/usb-power/arm64'
[IO.Directory]::CreateDirectory($build)|Out-Null
$env:ZIG_GLOBAL_CACHE_DIR=Join-Path $workspace 'capture-app/device-research/.cache/zig-global'
$env:ZIG_LOCAL_CACHE_DIR=Join-Path $workspace 'capture-app/device-research/.cache/zig-local'
$object=Join-Path $build 'hl-usb-power.obj';$exe=Join-Path $build 'hl-usb-power.exe'
& (Join-Path $workspace '.tools/zig-pypi/ziglang/zig.exe') cc -target aarch64-windows-msvc -O2 -std=c11 -fno-stack-protector -fno-builtin -nostdlib -c (Join-Path $workspace 'holographic-control/device/hl-usb-power.c') -o $object
if($LASTEXITCODE -ne 0){throw 'USB power worker compilation failed'}
$lib='C:/Program Files (x86)/Windows Kits/10/Lib/10.0.26100.0/um/arm64'
& 'C:/Program Files/Microsoft Visual Studio/2022/Community/VC/Tools/MSVC/14.44.35207/bin/Hostx64/x64/link.exe' /nologo /NODEFAULTLIB /ENTRY:usb_power_entry /SUBSYSTEM:CONSOLE /MACHINE:ARM64 /DYNAMICBASE /NXCOMPAT /OPT:REF $object (Join-Path $lib 'OneCore.Lib') (Join-Path $lib 'PowrProf.Lib') ('/OUT:'+$exe)
if($LASTEXITCODE -ne 0){throw 'USB power worker linking failed'}
@{Path=$exe;Sha256=(Get-FileHash -LiteralPath $exe).Hash}|ConvertTo-Json -Compress
