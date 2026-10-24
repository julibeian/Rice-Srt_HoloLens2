$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$workspace=Split-Path -Parent $root
$original=Join-Path $workspace 'capture-app\device-research\hl-uri-launch.c'
$source=(Get-Content -LiteralPath $original -Raw -Encoding utf8).Replace('rice-hololens-capture','rice-hololens-field').Replace('Rice.HoloLens.Capture_r5420n6798s24!Capture','Rice.HoloLens.Field_r5420n6798s24!Field').Replace('Rice.HoloLens.Capture_r5420n6798s24','Rice.HoloLens.Field_r5420n6798s24')
$build=Join-Path $root '.state\launcher'
[IO.Directory]::CreateDirectory($build)|Out-Null
$file=Join-Path $build 'hl-field-launch.c'
[IO.File]::WriteAllText($file,$source,[Text.UTF8Encoding]::new($false))
$env:ZIG_GLOBAL_CACHE_DIR=Join-Path $workspace 'capture-app\device-research\.cache\zig-global'
$env:ZIG_LOCAL_CACHE_DIR=Join-Path $workspace 'capture-app\device-research\.cache\zig-local'
$object=Join-Path $build 'hl-field-launch.obj'
$exe=Join-Path $build 'hl-field-launch.exe'
& (Join-Path $workspace '.tools\zig-pypi\ziglang\zig.exe') cc -target aarch64-windows-msvc -O2 -std=c11 -fno-stack-protector -fno-builtin -nostdlib -c $file -o $object
if($LASTEXITCODE -ne 0){throw 'Launcher compile failed.'}
$libraries='C:\Program Files (x86)\Windows Kits\10\Lib\10.0.26100.0\um\arm64'
& 'C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC\14.44.35207\bin\Hostx64\x64\link.exe' /nologo /NODEFAULTLIB /ENTRY:hl_uri_entry /SUBSYSTEM:CONSOLE /MACHINE:ARM64 /DYNAMICBASE /NXCOMPAT $object (Join-Path $libraries 'OneCore.Lib') (Join-Path $libraries 'RuntimeObject.Lib') (Join-Path $libraries 'bcrypt.lib') ('/OUT:'+$exe)
if($LASTEXITCODE -ne 0){throw 'Launcher link failed.'}
Get-FileHash -LiteralPath $exe|Select-Object Path,Hash|ConvertTo-Json -Compress
