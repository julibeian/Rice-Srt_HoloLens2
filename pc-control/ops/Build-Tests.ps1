$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$output=Join-Path $root '.state\tests'
[IO.Directory]::CreateDirectory($output)|Out-Null
$compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
& $compiler /nologo /codepage:65001 /target:exe /platform:x86 /optimize+ /r:System.Drawing.dll /r:System.Web.Extensions.dll ('/out:'+(Join-Path $output 'DeviceSmoke.exe')) (Join-Path $root 'desktop\PointerGeometry.cs') (Join-Path $root 'desktop\DeviceSession.cs') (Join-Path $root 'tests\DeviceSmoke.cs')
if($LASTEXITCODE -ne 0){throw 'Backend smoke test build failed.'}
& $compiler /nologo /codepage:65001 /target:exe /platform:x86 /optimize+ /r:System.Drawing.dll ('/out:'+(Join-Path $output 'PointerTests.exe')) (Join-Path $root 'desktop\PointerGeometry.cs') (Join-Path $root 'tests\PointerTests.cs')
if($LASTEXITCODE -ne 0){throw 'Pointer test build failed.'}
& (Join-Path $output 'PointerTests.exe')
if($LASTEXITCODE -ne 0){throw 'Pointer test failed.'}
