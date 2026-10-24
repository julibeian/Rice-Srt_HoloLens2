$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$workspace=Split-Path -Parent $root
$build=Join-Path $root '.state\probe\arm64'
[IO.Directory]::CreateDirectory($build)|Out-Null
$env:ZIG_GLOBAL_CACHE_DIR=Join-Path $workspace 'capture-app\device-research\.cache\zig-global'
$env:ZIG_LOCAL_CACHE_DIR=Join-Path $workspace 'capture-app\device-research\.cache\zig-local'
$object=Join-Path $build 'hl-simulation-lease.obj'
$exe=Join-Path $build 'hl-simulation-lease.exe'
& (Join-Path $workspace '.tools\zig-pypi\ziglang\zig.exe') cc -target aarch64-windows-msvc -O2 -std=c11 -fno-stack-protector -fno-builtin -nostdlib -c (Join-Path $root 'device\hl-simulation-lease.c') -o $object
if($LASTEXITCODE -ne 0){throw 'Simulation lease compilation failed.'}
& 'C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC\14.44.35207\bin\Hostx64\x64\link.exe' /nologo /NODEFAULTLIB /ENTRY:simulation_lease_entry /SUBSYSTEM:CONSOLE /MACHINE:ARM64 /DYNAMICBASE /NXCOMPAT /OPT:REF $object 'C:\Program Files (x86)\Windows Kits\10\Lib\10.0.26100.0\um\arm64\OneCore.Lib' ('/OUT:'+$exe)
if($LASTEXITCODE -ne 0){throw 'Simulation lease link failed.'}
Get-FileHash -LiteralPath $exe|Select-Object Path,Hash|ConvertTo-Json -Compress
