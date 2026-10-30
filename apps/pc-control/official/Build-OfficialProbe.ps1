$ErrorActionPreference = 'Stop'
$workspace = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$installed = Join-Path $env:ProgramFiles 'Microsoft Perception Simulation/Sdk/References'
$destination = Join-Path $workspace 'apps/pc-control/.state/official-probe-x64'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
$expectedManager = '7CA60202EC55309102FC0E54837576475416A383809A7024BAAE891107E25B1C'
if ((Get-FileHash -LiteralPath (Join-Path $installed 'PerceptionSimulationManager.dll')).Hash -cne $expectedManager) { throw 'The installed SDK manager does not match the reviewed Microsoft 3.0.24.0 package.' }
[IO.Directory]::CreateDirectory($destination) | Out-Null
$manifest = foreach ($source in Get-ChildItem -LiteralPath $installed -Filter '*.dll' -File) {
    Copy-Item -LiteralPath $source.FullName -Destination (Join-Path $destination $source.Name) -Force
    [pscustomobject]@{Name=$source.Name;SHA256=(Get-FileHash -LiteralPath $source.FullName).Hash;Version=$source.VersionInfo.FileVersion}
}
$output = Join-Path $destination 'OfficialSdkProbe.exe'
$arguments = @('/nologo','/utf8output','/platform:x64','/target:exe','/r:System.Web.Extensions.dll',('/out:'+$output))
foreach ($name in @('SimulationStream.Interop.dll','PerceptionSimulation.Interop.dll','PerceptionSimulationManager.Interop.dll')) { $arguments += '/r:'+(Join-Path $destination $name) }
$arguments += Join-Path $PSScriptRoot 'OfficialSdkProbe.cs'
$diagnostics = @(& $compiler @arguments 2>&1)
if ($LASTEXITCODE -ne 0) { throw ('The official SDK probe did not compile: ' + ($diagnostics -join [Environment]::NewLine)) }
$result = [ordered]@{At=(Get-Date).ToString('o');ProcessBits=64;Executable=$output;SourceSHA256=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'OfficialSdkProbe.cs')).Hash;VendorFiles=@($manifest);InstalledSdkUsed=$true;LegacySdkUsed=$false}
[IO.Directory]::CreateDirectory((Join-Path $destination 'sources')) | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'OfficialSdkProbe.cs') -Destination (Join-Path $destination ('sources/' + $result.SourceSHA256 + '.cs')) -Force
[IO.File]::WriteAllText((Join-Path $destination 'build.json'),($result | ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
$result | ConvertTo-Json -Depth 5
