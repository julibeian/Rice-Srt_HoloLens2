param([ValidateSet('arm64','x64','both')][string]$Architecture='both',[ValidateSet('uri','camera-probe','camera-capture','result-notification')][string]$Variant='uri')
$ErrorActionPreference='Stop'
$root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$zig=Join-Path $root '.tools\zig-pypi\ziglang\zig.exe'
$link='C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC\14.44.35207\bin\Hostx64\x64\link.exe'
$hostCompiler=Join-Path (Split-Path -Parent $link) 'cl.exe'
$libRoot='C:\Program Files (x86)\Windows Kits\10\Lib\10.0.26100.0\um'
$env:ZIG_GLOBAL_CACHE_DIR=Join-Path $PSScriptRoot '.cache\zig-global'
$env:ZIG_LOCAL_CACHE_DIR=Join-Path $PSScriptRoot '.cache\zig-local'
[IO.Directory]::CreateDirectory($env:ZIG_GLOBAL_CACHE_DIR)|Out-Null
[IO.Directory]::CreateDirectory($env:ZIG_LOCAL_CACHE_DIR)|Out-Null
$architectures=if($Architecture -eq 'both'){@('arm64','x64')}else{@($Architecture)}
foreach($arch in $architectures){
    $directory=Join-Path $PSScriptRoot ('bin\'+$arch)
    [IO.Directory]::CreateDirectory($directory)|Out-Null
    $stem=if($Variant -eq 'uri'){'hl-uri-launch'}elseif($Variant -eq 'camera-probe'){'hl-camera-probe'}elseif($Variant -eq 'camera-capture'){'hl-camera-capture'}else{'hl-result-notification'}
    $entry=if($Variant -eq 'uri'){'hl_uri_entry'}elseif($Variant -eq 'camera-probe'){'hl_camera_probe_entry'}elseif($Variant -eq 'camera-capture'){'hl_camera_capture_entry'}else{'hl_result_notification_entry'}
    $source=Join-Path $PSScriptRoot ($stem+'.c')
    $object=Join-Path $directory ($stem+'.obj')
    $exe=Join-Path $directory ($stem+'.exe')
    $target=if($arch -eq 'arm64'){'aarch64-windows-msvc'}else{'x86_64-windows-msvc'}
    $machine=if($arch -eq 'arm64'){'ARM64'}else{'X64'}
    if($arch -eq 'x64' -and (Test-Path -LiteralPath $hostCompiler)){
        & $hostCompiler /nologo /O2 /GS- /std:c11 /c $source ('/Fo'+$object)
    }else{
        & $zig cc -target $target -O2 -std=c11 -fno-stack-protector -fno-builtin -nostdlib -c $source -o $object
    }
    if($LASTEXITCODE -ne 0){throw 'URI helper compilation failed.'}
    & $link /nologo /NODEFAULTLIB ('/ENTRY:'+$entry) /SUBSYSTEM:CONSOLE ('/MACHINE:'+$machine) /DYNAMICBASE /NXCOMPAT $object (Join-Path $libRoot ($arch+'\OneCore.Lib')) (Join-Path $libRoot ($arch+'\RuntimeObject.lib')) (Join-Path $libRoot ($arch+'\bcrypt.lib')) ('/OUT:'+$exe)
    if($LASTEXITCODE -ne 0){throw 'URI helper linking failed.'}
    [ordered]@{Architecture=$arch;Path=$exe;Sha256=(Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash;SourceSha256=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash}|ConvertTo-Json -Compress
}
