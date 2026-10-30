param(
    [ValidateSet('arm64','x64')][string]$Architecture='arm64',
    [ValidateSet('token','account')][string]$Probe='token'
)
$ErrorActionPreference='Stop'
$repoRoot=Split-Path -Parent $PSScriptRoot
$compiler=Join-Path $repoRoot '.tools\zig-pypi\ziglang\zig.exe'
$name='hl-'+$Probe+'-probe'
$source=Join-Path $repoRoot ('native\'+$name+'.c')
$outputDirectory=Join-Path $repoRoot ('native\bin\'+$Architecture)
[IO.Directory]::CreateDirectory($outputDirectory)|Out-Null
$target=if($Architecture -eq 'arm64'){'aarch64-windows-msvc'}else{'x86_64-windows-msvc'}
$libraryArchitecture=if($Architecture -eq 'arm64'){'arm64'}else{'x64'}
$library='C:\Program Files (x86)\Windows Kits\10\Lib\10.0.26100.0\um\'+$libraryArchitecture+'\OneCore.Lib'
$output=Join-Path $outputDirectory ($name+'.exe')
$object=Join-Path $outputDirectory ($name+'.obj')
$hostCompiler='C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC\14.44.35207\bin\Hostx64\x64\cl.exe'
if($Architecture -eq 'x64' -and (Test-Path -LiteralPath $hostCompiler)){
    & $hostCompiler /nologo /O2 /GS- /std:c11 /c $source ('/Fo'+$object)
    if($LASTEXITCODE -ne 0){throw 'Host compilation failed.'}
}else{
    if(-not (Test-Path -LiteralPath $compiler)){throw 'The verified Zig compiler is missing.'}
    & $compiler cc -target $target -O2 -fno-stack-protector -fno-builtin -nostdlib -c $source -o $object
    if($LASTEXITCODE -ne 0){throw 'ARM64 object compilation failed.'}
}
$linker=Join-Path (Split-Path -Parent $hostCompiler) 'link.exe'
$machine=if($Architecture -eq 'arm64'){'ARM64'}else{'X64'}
& $linker /nologo /NODEFAULTLIB /ENTRY:hl_entry /SUBSYSTEM:CONSOLE ('/MACHINE:'+$machine) $object $library ('/OUT:'+$output)
if($LASTEXITCODE -ne 0){throw 'Native token probe compilation failed.'}
[ordered]@{Architecture=$Architecture;Path=$output;Sha256=(Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash;SourceSha256=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash}|ConvertTo-Json -Compress
