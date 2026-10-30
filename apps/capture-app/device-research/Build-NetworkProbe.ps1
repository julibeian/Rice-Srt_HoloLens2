param([ValidateSet('arm64','x64','both')][string]$Architecture='both')
$ErrorActionPreference='Stop'
$root=Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$zig=Join-Path $root '.tools\zig-pypi\ziglang\zig.exe'
$link='C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC\14.44.35207\bin\Hostx64\x64\link.exe'
$compiler=Join-Path (Split-Path -Parent $link) 'cl.exe'
$libRoot='C:\Program Files (x86)\Windows Kits\10\Lib\10.0.26100.0\um'
$env:ZIG_GLOBAL_CACHE_DIR=Join-Path $PSScriptRoot '.cache\zig-global'
$env:ZIG_LOCAL_CACHE_DIR=Join-Path $PSScriptRoot '.cache\zig-local'
[IO.Directory]::CreateDirectory($env:ZIG_GLOBAL_CACHE_DIR)|Out-Null
[IO.Directory]::CreateDirectory($env:ZIG_LOCAL_CACHE_DIR)|Out-Null
$architectures=if($Architecture -eq 'both'){@('arm64','x64')}else{@($Architecture)}
foreach($arch in $architectures){
    $directory=Join-Path $PSScriptRoot ('bin\'+$arch)
    [IO.Directory]::CreateDirectory($directory)|Out-Null
    $source=Join-Path $PSScriptRoot 'hl-network-probe.c'
    $object=Join-Path $directory 'hl-network-probe.obj'
    $exe=Join-Path $directory 'hl-network-probe.exe'
    $target=if($arch -eq 'arm64'){'aarch64-windows-msvc'}else{'x86_64-windows-msvc'}
    $machine=if($arch -eq 'arm64'){'ARM64'}else{'X64'}
    if($arch -eq 'x64' -and (Test-Path -LiteralPath $compiler)){
        & $compiler /nologo /O2 /GS- /std:c11 /c $source ('/Fo'+$object)
    }else{
        & $zig cc -target $target -O2 -std=c11 -fno-stack-protector -fno-builtin -nostdlib -c $source -o $object
    }
    if($LASTEXITCODE -ne 0){throw 'Network probe compilation failed.'}
    $libraries=@('OneCore.Lib','Winhttp.lib','Iphlpapi.lib','Ws2_32.lib') | ForEach-Object { Join-Path $libRoot ($arch+'\'+$_) }
    & $link /nologo /NODEFAULTLIB /ENTRY:hl_network_entry /SUBSYSTEM:CONSOLE ('/MACHINE:'+$machine) /DYNAMICBASE /NXCOMPAT $object @libraries ('/OUT:'+$exe)
    if($LASTEXITCODE -ne 0){throw 'Network probe linking failed.'}
    [ordered]@{Architecture=$arch;Path=$exe;Sha256=(Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash;SourceSha256=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash}|ConvertTo-Json -Compress
}
