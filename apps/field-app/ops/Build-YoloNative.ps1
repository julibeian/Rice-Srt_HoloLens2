param([ValidateSet('arm64','x64')][string]$Architecture='arm64',[ValidateSet(320,416,640)][int]$InputSize=640)
$ErrorActionPreference='Stop'
$appRoot=Split-Path -Parent $PSScriptRoot;$workspace=Split-Path -Parent (Split-Path -Parent $appRoot)
$vc='C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC\14.44.35207'
$sdk='C:\Program Files (x86)\Windows Kits\10';$ver='10.0.26100.0'
$folder=Join-Path $appRoot ('.state/yolo-native/'+$Architecture+'/'+[DateTime]::Now.ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6))
[IO.Directory]::CreateDirectory($folder)|Out-Null
$env:PATH=(Join-Path $vc 'bin/Hostx64/x64')+';'+$env:PATH
$includeRoot=Join-Path $sdk ('Include/'+$ver)
& (Join-Path $sdk ('bin/'+$ver+'/x64/midlrt.exe')) /winrt /nomidl /env $Architecture /I (Join-Path $includeRoot 'winrt') /I (Join-Path $includeRoot 'um') /I (Join-Path $includeRoot 'shared') /metadata_dir (Join-Path $sdk ('UnionMetadata/'+$ver)) /h (Join-Path $folder 'YoloNative.h') /winmd (Join-Path $folder 'Rice.HoloLens.Yolo.winmd') (Join-Path $appRoot 'yolo-native/YoloNative.idl') *> (Join-Path $folder 'midl.log')
if($LASTEXITCODE -ne 0){Get-Content -LiteralPath (Join-Path $folder 'midl.log') -Tail 30;throw 'YOLO WinRT metadata failed'}
$env:ZIG_GLOBAL_CACHE_DIR=Join-Path $workspace 'apps/capture-app/device-research/.cache/zig-global';$env:ZIG_LOCAL_CACHE_DIR=Join-Path $workspace 'apps/capture-app/device-research/.cache/zig-local'
$includes=@('-isystem',(Join-Path $vc 'include'));foreach($part in @('um','shared','ucrt','winrt')){$includes+=@('-isystem',(Join-Path $includeRoot $part))}
$target=if($Architecture -eq 'arm64'){'aarch64-windows-msvc'}else{'x86_64-windows-msvc'}
$obj=Join-Path $folder 'YoloNative.obj';$dll=Join-Path $folder 'Rice.HoloLens.Yolo.dll'
& (Join-Path $workspace '.tools/zig-pypi/ziglang/zig.exe') cc -target $target -O2 -std=c11 -fno-stack-protector -fno-builtin -nostdlib -Wall -Wextra -Werror ('-DYOLO_SIDE='+$InputSize) @includes -I $folder -c (Join-Path $appRoot 'yolo-native/YoloNative.c') -o $obj *> (Join-Path $folder 'compile.log')
if($LASTEXITCODE -ne 0){Get-Content -LiteralPath (Join-Path $folder 'compile.log') -Tail 40;throw 'YOLO native compilation failed'}
$lib=Join-Path $sdk ('Lib/'+$ver+'/um/'+$Architecture)
& (Join-Path $vc 'bin/Hostx64/x64/link.exe') /nologo /DLL /NOENTRY /NODEFAULTLIB /APPCONTAINER ('/MACHINE:'+$Architecture.ToUpperInvariant()) /DYNAMICBASE /NXCOMPAT /OPT:REF $obj (Join-Path $lib 'WindowsApp.lib') (Join-Path $lib 'bcrypt.lib') (Join-Path $lib 'oleaut32.lib') ('/DEF:'+(Join-Path $appRoot 'yolo-native/YoloNative.def')) ('/OUT:'+$dll) *> (Join-Path $folder 'link.log')
if($LASTEXITCODE -ne 0){Get-Content -LiteralPath (Join-Path $folder 'link.log') -Tail 25;throw 'YOLO native link failed'}
$proof=@{Architecture=$Architecture;InputSize=$InputSize;Dll=$dll;Winmd=(Join-Path $folder 'Rice.HoloLens.Yolo.winmd');DllSha256=(Get-FileHash -LiteralPath $dll).Hash;WinmdSha256=(Get-FileHash -LiteralPath (Join-Path $folder 'Rice.HoloLens.Yolo.winmd')).Hash;Folder=$folder}
$proof|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $folder 'build.json') -Encoding utf8
$proof|ConvertTo-Json -Compress
