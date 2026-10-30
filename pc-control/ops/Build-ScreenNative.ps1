param([ValidateSet('arm64','x64')][string]$Architecture='arm64')
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot;$workspace=Split-Path -Parent $root
$vc='C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC\14.44.35207'
$sdk='C:\Program Files (x86)\Windows Kits\10';$sdkVersion='10.0.26100.0'
$folder=Join-Path $root ('.state\screen-native\'+$Architecture+'\'+[DateTime]::Now.ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6))
[IO.Directory]::CreateDirectory($folder)|Out-Null
$env:PATH=(Join-Path $vc 'bin\Hostx64\x64')+';'+$env:PATH
$includeRoot=Join-Path $sdk ('Include\'+$sdkVersion)
$source=Join-Path $root 'screen-probe\ScreenNative.c';$idl=Join-Path $root 'screen-probe\ScreenNative.idl'
# MIDLRT metadata paths must use backslashes. Forward slashes produce HRESULT 0x8007007B.
& (Join-Path $sdk ('bin\'+$sdkVersion+'\x64\midlrt.exe')) /winrt /nomidl /env $Architecture /I (Join-Path $includeRoot 'winrt') /I (Join-Path $includeRoot 'um') /I (Join-Path $includeRoot 'shared') /metadata_dir (Join-Path $sdk ('UnionMetadata\'+$sdkVersion)) /h (Join-Path $folder 'ScreenNative.h') /winmd (Join-Path $folder 'Rice.HoloLens.ScreenNative.winmd') $idl *> (Join-Path $folder 'midl.log')
if($LASTEXITCODE -ne 0){throw ('WinRT metadata compilation failed: '+$folder)}
$env:ZIG_GLOBAL_CACHE_DIR=Join-Path $workspace 'capture-app\device-research\.cache\zig-global'
$env:ZIG_LOCAL_CACHE_DIR=Join-Path $workspace 'capture-app\device-research\.cache\zig-local'
$includes=@('-isystem',(Join-Path $vc 'include'))
foreach($part in @('um','shared','ucrt','winrt')){$includes+=@('-isystem',(Join-Path $includeRoot $part))}
$object=Join-Path $folder 'ScreenNative.obj';$dll=Join-Path $folder 'Rice.HoloLens.ScreenNative.dll'
$target=if($Architecture -eq 'arm64'){'aarch64-windows-msvc'}else{'x86_64-windows-msvc'}
& (Join-Path $workspace '.tools\zig-pypi\ziglang\zig.exe') cc -target $target -O2 -std=c11 -fno-stack-protector -fno-builtin -nostdlib -Wall -Wextra -Werror @includes -I $folder -c $source -o $object *> (Join-Path $folder 'compile.log')
if($LASTEXITCODE -ne 0){throw ('Native screen bridge compilation failed: '+$folder)}
$libRoot=Join-Path $sdk ('Lib\'+$sdkVersion+'\um\'+$Architecture)
& (Join-Path $vc 'bin\Hostx64\x64\link.exe') /nologo /DLL /NOENTRY /NODEFAULTLIB /APPCONTAINER ('/MACHINE:'+$Architecture.ToUpperInvariant()) /DYNAMICBASE /NXCOMPAT /OPT:REF $object (Join-Path $libRoot 'WindowsApp.lib') (Join-Path $libRoot 'd3d11.lib') ('/DEF:'+(Join-Path $root 'screen-probe\ScreenNative.def')) ('/OUT:'+$dll) *> (Join-Path $folder 'link.log')
if($LASTEXITCODE -ne 0){throw ('Native screen bridge linking failed: '+$folder)}
$proof=[ordered]@{architecture=$Architecture;folder=$folder;dll=$dll;winmd=(Join-Path $folder 'Rice.HoloLens.ScreenNative.winmd');dll_sha256=(Get-FileHash -LiteralPath $dll).Hash;winmd_sha256=(Get-FileHash -LiteralPath (Join-Path $folder 'Rice.HoloLens.ScreenNative.winmd')).Hash;built_at=[DateTimeOffset]::Now.ToString('o');sdk=$sdkVersion;automatic_capture=$false;picker_required=$true;capture_budget_ms=20000;files=@('ScreenNative.c','ScreenNative.idl','ScreenNative.def')|ForEach-Object {@{path=('pc-control/screen-probe/'+$_);sha256=(Get-FileHash -LiteralPath (Join-Path $root ('screen-probe\'+$_))).Hash}}}
[IO.File]::WriteAllText((Join-Path $folder 'build-evidence.json'),($proof|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
$proof|ConvertTo-Json -Depth 5
