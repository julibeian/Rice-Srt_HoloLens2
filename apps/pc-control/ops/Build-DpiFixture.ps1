# Builds the local-only rendering diagnostic. Does not launch or connect it.
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$output=Join-Path $root '.state/dpi-fixture'
[IO.Directory]::CreateDirectory($output)|Out-Null
$compiler=Join-Path $env:WINDIR 'Microsoft.NET/Framework/v4.0.30319/csc.exe'
$exe=Join-Path $output 'DpiFixtureHost.exe'
& $compiler /nologo /codepage:65001 /target:winexe /platform:x86 /optimize+ /r:System.Drawing.dll /r:System.Windows.Forms.dll /r:System.Web.Extensions.dll ('/win32manifest:'+(Join-Path $root 'desktop/app.manifest')) ('/out:'+$exe) (Join-Path $root 'tests/DpiFixtureHost.cs')
if($LASTEXITCODE -ne 0){throw 'Local DPI fixture did not compile.'}
Copy-Item -LiteralPath (Join-Path $root 'desktop/App.config') -Destination ($exe+'.config')
@{executable=$exe;sha256=(Get-FileHash -LiteralPath $exe).Hash;launch_attempted=$false;device_input_sent=$false;manifest='same per-monitor DPI and Windows compatibility declarations as product'}|ConvertTo-Json
