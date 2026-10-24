param([ValidateSet('arm64','x64')][string]$Architecture='arm64')
$ErrorActionPreference='Stop'
$root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$zig=Join-Path $root '.tools\zig-pypi\ziglang\zig.exe'
$link='C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC\14.44.35207\bin\Hostx64\x64\link.exe'
$libRoot='C:\Program Files (x86)\Windows Kits\10\Lib\10.0.26100.0\um'
$env:ZIG_GLOBAL_CACHE_DIR=Join-Path $PSScriptRoot '.cache\zig-global'
$env:ZIG_LOCAL_CACHE_DIR=Join-Path $PSScriptRoot '.cache\zig-local'
$directory=Join-Path $PSScriptRoot ('bin\'+$Architecture)
[IO.Directory]::CreateDirectory($directory)|Out-Null
$source=Join-Path $PSScriptRoot 'hl-wifi-connect.c'
$object=Join-Path $directory 'hl-wifi-connect.obj'
$exe=Join-Path $directory 'hl-wifi-connect.exe'
$target=if($Architecture -eq 'arm64'){'aarch64-windows-msvc'}else{'x86_64-windows-msvc'}
& $zig cc -target $target -O2 -std=c11 -fno-stack-protector -fno-builtin -nostdlib -c $source -o $object
if($LASTEXITCODE -ne 0){throw 'Wi-Fi helper compilation failed.'}
& $link /nologo /NODEFAULTLIB /ENTRY:hl_wifi_entry /SUBSYSTEM:CONSOLE ('/MACHINE:'+$Architecture.ToUpperInvariant()) /DYNAMICBASE /NXCOMPAT $object (Join-Path $libRoot ($Architecture+'\OneCore.Lib')) ('/OUT:'+$exe)
if($LASTEXITCODE -ne 0){throw 'Wi-Fi helper linking failed.'}
[ordered]@{Architecture=$Architecture;Path=$exe;Sha256=(Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash}|ConvertTo-Json -Compress
