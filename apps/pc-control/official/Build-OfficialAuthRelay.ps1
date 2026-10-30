param([switch]$SelfTest)
$ErrorActionPreference='Stop'
$workspace=Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$source=Join-Path $PSScriptRoot 'OfficialAuthRelay.cs'
$hash=(Get-FileHash -LiteralPath $source).Hash
$folder=Join-Path $workspace ('apps/pc-control/.state/official-relay-build/'+$hash)
$exe=Join-Path $folder 'OfficialAuthRelay.exe'
if(-not(Test-Path -LiteralPath $exe)){
    [IO.Directory]::CreateDirectory($folder)|Out-Null
    $compiler=Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
    $compile=@(& $compiler /nologo /utf8output /platform:x64 /target:exe /r:System.Net.Http.dll /r:System.Web.dll /r:System.Web.Extensions.dll ('/out:'+$exe) $source 2>&1)
    if($LASTEXITCODE){throw ('Relay compilation failed: '+($compile -join [Environment]::NewLine))}
    Copy-Item -LiteralPath $source -Destination (Join-Path $folder 'OfficialAuthRelay.cs')
}
if($SelfTest){& $exe --self-test;if($LASTEXITCODE){throw 'Relay identity self-test failed.'}}
[pscustomobject]@{Executable=$exe;SourceSha256=$hash;ExecutableSha256=(Get-FileHash -LiteralPath $exe).Hash}|ConvertTo-Json
