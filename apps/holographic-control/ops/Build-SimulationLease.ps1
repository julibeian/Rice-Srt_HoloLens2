param([string]$LinkerPath,[string]$OneCoreLibrary,[string]$ZigPath)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$workspace=Split-Path -Parent (Split-Path -Parent $root)
if(-not $ZigPath){$ZigPath=Join-Path $workspace '.tools\zig-pypi\ziglang\zig.exe'}
if(-not $OneCoreLibrary){
    $config=Get-Content -LiteralPath (Join-Path $workspace 'config.json') -Raw|ConvertFrom-Json
    $sdkBinVersion=Split-Path -Parent $config.SdkDirectory
    $sdkVersion=Split-Path -Leaf $sdkBinVersion
    $sdkRoot=Split-Path -Parent (Split-Path -Parent $sdkBinVersion)
    $OneCoreLibrary=Join-Path $sdkRoot ('Lib\'+$sdkVersion+'\um\arm64\OneCore.Lib')
}
if(-not $LinkerPath){
    $vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if(Test-Path -LiteralPath $vswhere){
        $candidates=@(& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -find 'VC\Tools\MSVC\**\bin\Hostx64\x64\link.exe')
        if($LASTEXITCODE -eq 0 -and $candidates.Count){$LinkerPath=$candidates[0]}
    }
}
foreach($inputFile in @($ZigPath,$OneCoreLibrary,$LinkerPath)){
    if(-not $inputFile -or -not(Test-Path -LiteralPath $inputFile -PathType Leaf)){
        throw 'Simulation lease tools are incomplete. Install Zig 0.15.2, Windows SDK ARM64 libraries and MSVC x64 build tools, or provide -ZigPath, -OneCoreLibrary and -LinkerPath explicitly. See the phase-two manual.'
    }
}
$build=Join-Path $root '.state\probe\arm64'
[IO.Directory]::CreateDirectory($build)|Out-Null
$env:ZIG_GLOBAL_CACHE_DIR=Join-Path $workspace 'apps/capture-app\device-research\.cache\zig-global'
$env:ZIG_LOCAL_CACHE_DIR=Join-Path $workspace 'apps/capture-app\device-research\.cache\zig-local'
$object=Join-Path $build 'hl-simulation-lease.obj'
$exe=Join-Path $build 'hl-simulation-lease.exe'
& $ZigPath cc -target aarch64-windows-msvc -O2 -std=c11 -fno-stack-protector -fno-builtin -nostdlib -c (Join-Path $root 'device\hl-simulation-lease.c') -o $object
if($LASTEXITCODE -ne 0){throw 'Simulation lease compilation failed.'}
& $LinkerPath /nologo /NODEFAULTLIB /ENTRY:simulation_lease_entry /SUBSYSTEM:CONSOLE /MACHINE:ARM64 /DYNAMICBASE /NXCOMPAT /OPT:REF $object $OneCoreLibrary ('/OUT:'+$exe)
if($LASTEXITCODE -ne 0){throw 'Simulation lease link failed.'}
Get-FileHash -LiteralPath $exe|Select-Object Path,Hash|ConvertTo-Json -Compress
