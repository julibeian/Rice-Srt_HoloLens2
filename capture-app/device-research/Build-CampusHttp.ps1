$ErrorActionPreference='Stop'
$root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$zig=Join-Path $root '.tools\zig-pypi\ziglang\zig.exe'
$link='C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC\14.44.35207\bin\Hostx64\x64\link.exe'
$libRoot='C:\Program Files (x86)\Windows Kits\10\Lib\10.0.26100.0\um\arm64'
$env:ZIG_GLOBAL_CACHE_DIR=Join-Path $PSScriptRoot '.cache\zig-global'
$env:ZIG_LOCAL_CACHE_DIR=Join-Path $PSScriptRoot '.cache\zig-local'
$directory=Join-Path $PSScriptRoot 'bin\arm64'
$source=Join-Path $PSScriptRoot 'hl-campus-http.c'
$object=Join-Path $directory 'hl-campus-http.obj'
$exe=Join-Path $directory 'hl-campus-http.exe'
& $zig cc -target aarch64-windows-msvc -O2 -std=c11 -fno-stack-protector -fno-builtin -nostdlib -c $source -o $object
if($LASTEXITCODE -ne 0){throw 'Campus HTTP compilation failed.'}
& $link /nologo /NODEFAULTLIB /ENTRY:hl_campus_entry /SUBSYSTEM:CONSOLE /MACHINE:ARM64 /DYNAMICBASE /NXCOMPAT $object (Join-Path $libRoot 'OneCore.Lib') (Join-Path $libRoot 'Winhttp.lib') ('/OUT:'+$exe)
if($LASTEXITCODE -ne 0){throw 'Campus HTTP linking failed.'}
[ordered]@{Path=$exe;Sha256=(Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash}|ConvertTo-Json -Compress
