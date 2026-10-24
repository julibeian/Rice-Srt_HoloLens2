$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$workspace=Split-Path -Parent $root
$sdk=Join-Path $workspace 'tools\perception-simulation\portable-hololens\Windows Kits\10\Microsoft XDE\10.0.22621.0'
$output=Join-Path $root '.state\desktop-x86'
[IO.Directory]::CreateDirectory($output)|Out-Null
$dlls=@('PerceptionSimulationManager.dll','PerceptionSimulationManager.Interop.dll','SimulationStream.Interop.dll','PerceptionSimulationRest.dll')
foreach($name in $dlls){Copy-Item -LiteralPath (Join-Path $sdk $name) -Destination (Join-Path $output $name) -Force}
$refs=@('/r:System.Web.Extensions.dll','/r:System.Net.Http.dll')
foreach($name in $dlls|Where-Object {$_ -ne 'PerceptionSimulationManager.dll'}){$refs+=('/r:'+(Join-Path $output $name))}
$exe=Join-Path $output 'PerceptionControl.exe'
& 'C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe' /nologo /target:exe /platform:x86 /optimize+ @refs ('/out:'+$exe) (Join-Path $root 'desktop\PerceptionControl.cs')
if($LASTEXITCODE -ne 0){throw 'SDK controller compilation failed.'}
$selfTest=& $exe --self-test
$exitCode=$LASTEXITCODE
$selfTest|Set-Content -LiteralPath (Join-Path $root '.state\desktop-self-test.json') -Encoding utf8
$selfTest
if($exitCode -ne 0){throw 'Offline SDK packet test failed; this controller is not ready.'}
Get-FileHash -LiteralPath $exe|Select-Object Path,Hash|ConvertTo-Json -Compress
