param([string]$PackageDirectory,[string]$RemoteDirectory='RiceHoloLensFieldV1',[switch]$Launch)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$workspace=Split-Path -Parent (Split-Path -Parent $root)
. (Join-Path $workspace 'usb-terminal/HoloLens.Common.ps1')
if(-not $PackageDirectory){$PackageDirectory=[IO.File]::ReadAllText((Join-Path $root '.state\current-package.txt')).Trim()}
$proof=Get-Content -LiteralPath (Join-Path $PackageDirectory 'package-evidence.json') -Raw|ConvertFrom-Json
if((Get-FileHash -LiteralPath $proof.Package).Hash -ne $proof.Sha256){throw 'Package hash changed.'}
if($RemoteDirectory -notmatch '^RiceHoloLensField[A-Za-z0-9_-]{1,40}$'){throw 'Invalid app deployment directory.'}
if($RemoteDirectory -eq 'RiceHoloLensFieldV1' -and (Test-Path -LiteralPath (Join-Path $root '.state\installed.json'))){& (Join-Path $PSScriptRoot 'Stop-App.ps1')|Out-Null}
$info=Invoke-HlBridge @{action='info'}
$sdk=Join-Path $script:HlConfig.SdkDirectory 'WinAppDeployCmd.exe'
& $sdk deployfiles -file (Join-Path $proof.Layout 'AppxManifest.xml') -remotedeploydir $RemoteDirectory -ip $info.Address 2>&1|Tee-Object -FilePath (Join-Path $PackageDirectory 'deploy.log')
if($LASTEXITCODE -ne 0){throw 'Device file deployment failed.'}
& $sdk registerfiles -remotedeploydir $RemoteDirectory -ip $info.Address 2>&1|Tee-Object -FilePath (Join-Path $PackageDirectory 'register.log')
if($LASTEXITCODE -ne 0){throw 'Device app registration failed.'}
$remoteLayout='U:\Users\DefaultAccount\AppData\Local\DevelopmentFiles\'+$RemoteDirectory
$installed=[ordered]@{Version=$proof.Version;Identity=$proof.Identity;RemoteLayout=$remoteLayout;InstalledAt=[DateTimeOffset]::Now.ToString('o');PackageSha256=$proof.Sha256}
[IO.File]::WriteAllText((Join-Path $root '.state\installed.json'),($installed|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
if($Launch){& (Join-Path $PSScriptRoot 'Start-App.ps1')|Out-Null;$installed=Get-Content -LiteralPath (Join-Path $root '.state\installed.json') -Raw|ConvertFrom-Json}
$installed|ConvertTo-Json -Compress
