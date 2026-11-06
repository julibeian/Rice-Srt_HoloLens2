$ErrorActionPreference='Stop'
$appRoot=Split-Path -Parent $PSScriptRoot
$workspace=Split-Path -Parent (Split-Path -Parent $appRoot)
$sdk='C:\Program Files (x86)\Windows Kits\10';$ver='10.0.26100.0'
$vc='C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC\14.44.35207'
$folder=Join-Path $appRoot ('.state/gpu-probe/'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($folder)|Out-Null
$env:ZIG_GLOBAL_CACHE_DIR=Join-Path $workspace 'apps/capture-app/device-research/.cache/zig-global'
$env:ZIG_LOCAL_CACHE_DIR=Join-Path $workspace 'apps/capture-app/device-research/.cache/zig-local'
$includes=@('-isystem',(Join-Path $vc 'include'));foreach($part in @('um','shared','ucrt','winrt')){$includes+=@('-isystem',(Join-Path $sdk ('Include/'+$ver+'/'+$part)))}
$object=Join-Path $folder 'probe.obj';$exe=Join-Path $folder 'hl-gpu-probe.exe'
& (Join-Path $workspace '.tools/zig-pypi/ziglang/zig.exe') cc -target aarch64-windows-msvc -O2 -std=c11 -fno-stack-protector -fno-builtin -nostdlib @includes -c (Join-Path $appRoot 'device/hl-gpu-probe.c') -o $object
if($LASTEXITCODE -ne 0){throw 'GPU probe compile failed'}
& (Join-Path $vc 'bin/Hostx64/x64/link.exe') /nologo /NODEFAULTLIB /ENTRY:gpu_probe_entry /SUBSYSTEM:CONSOLE /MACHINE:ARM64 /DYNAMICBASE /NXCOMPAT $object (Join-Path $sdk ('Lib/'+$ver+'/um/arm64/OneCore.Lib')) ('/OUT:'+$exe)
if($LASTEXITCODE -ne 0){throw 'GPU probe link failed'}
@{Path=$exe;Sha256=(Get-FileHash -LiteralPath $exe).Hash}|ConvertTo-Json -Compress
