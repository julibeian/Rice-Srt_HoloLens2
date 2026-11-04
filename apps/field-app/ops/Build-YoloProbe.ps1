param([ValidateSet('arm64','x64')][string]$Architecture='arm64',[ValidateSet('cpu','gpu')][string]$Device='cpu',[ValidateSet(320,416,640)][int]$InputSize=640)
$ErrorActionPreference='Stop'
$appRoot=Split-Path -Parent $PSScriptRoot
$workspace=Split-Path -Parent (Split-Path -Parent $appRoot)
$vc='C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC\14.44.35207'
$sdk='C:\Program Files (x86)\Windows Kits\10';$ver='10.0.26100.0'
$folder=Join-Path $appRoot ('.state/yolo-probe/'+$Architecture+'/'+[DateTime]::Now.ToString('yyyyMMdd-HHmmss')+'-'+$Device)
[IO.Directory]::CreateDirectory($folder)|Out-Null
$env:ZIG_GLOBAL_CACHE_DIR=Join-Path $workspace 'apps/capture-app/device-research/.cache/zig-global'
$env:ZIG_LOCAL_CACHE_DIR=Join-Path $workspace 'apps/capture-app/device-research/.cache/zig-local'
$includes=@('-isystem',(Join-Path $vc 'include'))
foreach($part in @('um','shared','ucrt','winrt')){$includes+=@('-isystem',(Join-Path $sdk ('Include/'+$ver+'/'+$part)))}
$target=if($Architecture -eq 'arm64'){'aarch64-windows-msvc'}else{'x86_64-windows-msvc'}
$obj=Join-Path $folder 'probe.obj';$exe=Join-Path $folder 'yolo-winml-probe.exe'
$deviceKind=if($Device -eq 'gpu'){3}else{1}
& (Join-Path $workspace '.tools/zig-pypi/ziglang/zig.exe') cc -target $target -O2 -std=c11 -fno-stack-protector -fno-builtin -nostdlib ('-DYOLO_DEVICE_KIND='+$deviceKind) ('-DYOLO_PROBE_SIDE='+$InputSize) @includes -c (Join-Path $appRoot 'yolo-native/WinMlProbe.c') -o $obj *> (Join-Path $folder 'compile.log')
if($LASTEXITCODE -ne 0){Get-Content -LiteralPath (Join-Path $folder 'compile.log') -Tail 30;throw 'YOLO WinML probe compile failed'}
$lib=Join-Path $sdk ('Lib/'+$ver+'/um/'+$Architecture)
& (Join-Path $vc 'bin/Hostx64/x64/link.exe') /nologo /NODEFAULTLIB /ENTRY:yolo_probe_entry /SUBSYSTEM:CONSOLE ('/MACHINE:'+$Architecture.ToUpperInvariant()) /DYNAMICBASE /NXCOMPAT /OPT:REF $obj (Join-Path $lib 'WindowsApp.lib') (Join-Path $lib 'oleaut32.lib') ('/OUT:'+$exe) *> (Join-Path $folder 'link.log')
if($LASTEXITCODE -ne 0){Get-Content -LiteralPath (Join-Path $folder 'link.log') -Tail 25;throw 'YOLO WinML probe link failed'}
@{Path=$exe;Architecture=$Architecture;Sha256=(Get-FileHash -LiteralPath $exe).Hash}|ConvertTo-Json -Compress
