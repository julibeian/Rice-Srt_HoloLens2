$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$workspace=Split-Path -Parent (Split-Path -Parent $root)
$build=Join-Path $root '.state\process-probe'
[IO.Directory]::CreateDirectory($build)|Out-Null
$env:ZIG_GLOBAL_CACHE_DIR=Join-Path $workspace 'apps/capture-app\device-research\.cache\zig-global'
$env:ZIG_LOCAL_CACHE_DIR=Join-Path $workspace 'apps/capture-app\device-research\.cache\zig-local'
$object=Join-Path $build 'hl-field-process.obj'
$exe=Join-Path $build 'hl-field-process.exe'
& (Join-Path $workspace '.tools\zig-pypi\ziglang\zig.exe') cc -target aarch64-windows-msvc -O2 -std=c11 -fno-stack-protector -fno-builtin -nostdlib -c (Join-Path $root 'device\hl-field-process.c') -o $object
if($LASTEXITCODE -ne 0){throw 'Stop helper compile failed.'}
$lib='C:\Program Files (x86)\Windows Kits\10\Lib\10.0.26100.0\um\arm64\OneCore.Lib'
& 'C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC\14.44.35207\bin\Hostx64\x64\link.exe' /nologo /NODEFAULTLIB /ENTRY:field_process_entry /SUBSYSTEM:CONSOLE /MACHINE:ARM64 /DYNAMICBASE /NXCOMPAT $object $lib ('/OUT:'+$exe)
if($LASTEXITCODE -ne 0){throw 'Stop helper link failed.'}
Get-FileHash -LiteralPath $exe|Select-Object Path,Hash|ConvertTo-Json -Compress

