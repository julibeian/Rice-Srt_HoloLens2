param(
    [ValidateSet('arm64','x64')][string]$Architecture='arm64',
    [ValidateSet('perception','portal','uia','injector','local-simulation','lifecycle','desktop-state','certificate','settings','audio','power','power-state')][string]$Probe='perception'
)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$workspace=Split-Path -Parent $root
$build=Join-Path $root ('.state\probe\'+$Architecture)
[IO.Directory]::CreateDirectory($build)|Out-Null
$env:ZIG_GLOBAL_CACHE_DIR=Join-Path $workspace 'capture-app\device-research\.cache\zig-global'
$env:ZIG_LOCAL_CACHE_DIR=Join-Path $workspace 'capture-app\device-research\.cache\zig-local'
$name='hl-'+$Probe+'-probe'
$object=Join-Path $build ($name+'.obj')
$exe=Join-Path $build ($name+'.exe')
$target=if($Architecture -eq 'arm64'){'aarch64-windows-msvc'}else{'x86_64-windows-msvc'}
$includes=@()
if($Probe -in @('uia','certificate')){
    $includes+=@('-isystem','C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC\14.44.35207\include')
    $includeRoot='C:\Program Files (x86)\Windows Kits\10\Include\10.0.26100.0'
    foreach($part in 'um','shared','ucrt','winrt'){$includes+=@('-isystem',(Join-Path $includeRoot $part))}
}
& (Join-Path $workspace '.tools\zig-pypi\ziglang\zig.exe') cc -target $target -O2 -std=c11 -fno-stack-protector -fno-builtin -nostdlib @includes -c (Join-Path $root ('device\'+$name+'.c')) -o $object
if($LASTEXITCODE -ne 0){throw 'Perception probe compilation failed.'}
$lib='C:\Program Files (x86)\Windows Kits\10\Lib\10.0.26100.0\um\'+$Architecture+'\OneCore.Lib'
$extraLibs=@()
if($Probe -eq 'uia'){$extraLibs=@((Join-Path (Split-Path -Parent $lib) 'uuid.lib'),(Join-Path (Split-Path -Parent $lib) 'oleaut32.lib'))}
if($Probe -eq 'certificate'){$extraLibs=@((Join-Path (Split-Path -Parent $lib) 'crypt32.lib'))}
if($Probe -eq 'power-state'){$extraLibs=@((Join-Path (Split-Path -Parent $lib) 'PowrProf.lib'))}
& 'C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC\14.44.35207\bin\Hostx64\x64\link.exe' /nologo /NODEFAULTLIB ('/ENTRY:'+$Probe.Replace('-','_')+'_probe_entry') /SUBSYSTEM:CONSOLE ('/MACHINE:'+$Architecture.ToUpperInvariant()) /DYNAMICBASE /NXCOMPAT /OPT:REF $object $lib @extraLibs ('/OUT:'+$exe)
if($LASTEXITCODE -ne 0){throw 'Perception probe link failed.'}
[ordered]@{Architecture=$Architecture;Path=$exe;Sha256=(Get-FileHash -LiteralPath $exe).Hash}|ConvertTo-Json -Compress
