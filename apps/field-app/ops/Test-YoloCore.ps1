param([ValidateSet(320,640)][int]$InputSize=320)
$ErrorActionPreference='Stop';$root=Split-Path -Parent $PSScriptRoot;$workspace=Split-Path -Parent (Split-Path -Parent $root)
$sdk='C:\Program Files (x86)\Windows Kits\10';$ver='10.0.26100.0'
$folder=Join-Path $root ('.state/yolo-core-tests/'+$InputSize);[IO.Directory]::CreateDirectory($folder)|Out-Null
$env:ZIG_GLOBAL_CACHE_DIR=Join-Path $workspace 'apps/capture-app/device-research/.cache/zig-global';$env:ZIG_LOCAL_CACHE_DIR=Join-Path $workspace 'apps/capture-app/device-research/.cache/zig-local'
$includes=@('-isystem','C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC\14.44.35207\include');foreach($part in @('um','shared','ucrt')){$includes+=@('-isystem',(Join-Path $sdk ('Include/'+$ver+'/'+$part)))}
$obj=Join-Path $folder 'core.obj';$dll=Join-Path $folder 'core.dll'
& (Join-Path $workspace '.tools/zig-pypi/ziglang/zig.exe') cc -target x86_64-windows-msvc -O2 -std=c11 -fno-stack-protector -fno-builtin -nostdlib ('-DYOLO_SIDE='+$InputSize) @includes -c (Join-Path $root 'tests/YoloCoreExports.c') -o $obj
if($LASTEXITCODE -ne 0){throw 'Native core test compilation failed'}
& 'C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC\14.44.35207\bin\Hostx64\x64\link.exe' /nologo /DLL /NOENTRY /NODEFAULTLIB /MACHINE:X64 /DYNAMICBASE /NXCOMPAT $obj (Join-Path $sdk ('Lib/'+$ver+'/um/x64/WindowsApp.lib')) ('/OUT:'+$dll)
if($LASTEXITCODE -ne 0){throw 'Native core test link failed'}
$model=Join-Path $root $(if($InputSize -eq 640){'.state/yolo/model.onnx'}else{'.state/yolo-'+$InputSize+'/model.onnx'})
& py -3.9 -B (Join-Path $PSScriptRoot 'Test-YoloCore.py') --dll $dll --model $model --size $InputSize --out (Join-Path $folder 'result.json')
if($LASTEXITCODE -ne 0){throw 'Native core/model equivalence failed'}
