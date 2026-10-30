#Requires -RunAsAdministrator
param([switch]$EnableDeveloperMode, [switch]$IncludeDriversAndService)
$ErrorActionPreference = 'Stop'
$workspace = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$package = Join-Path $workspace 'tools/perception-simulation/official-3.0.24/PerceptionSimulation.msi'
$signature = Get-AuthenticodeSignature -LiteralPath $package
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '^CN=Microsoft Corporation,') { throw 'The Microsoft installer signature did not validate.' }
if ((Get-FileHash -LiteralPath $package).Hash -cne 'E2873EB2633477AE32430D0A566FE5612AA45BF5552B95B83A20C78B518A1B8E') { throw 'The reviewed installer hash changed.' }
$folder = Join-Path $workspace ('apps/pc-control/.state/official-install/' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
[IO.Directory]::CreateDirectory($folder) | Out-Null
$devKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
$before = Get-ItemProperty -LiteralPath $devKey -Name AllowDevelopmentWithoutDevLicense -ErrorAction SilentlyContinue
$features = @('App','ManagedApi','NativeApi','Recordings')
if ($IncludeDriversAndService) { $features += @('Drivers','Service') }
$baseline = [ordered]@{ At = (Get-Date).ToString('o'); DeveloperModeValueExisted = ($null -ne $before); DeveloperModeValue = if ($before) { $before.AllowDevelopmentWithoutDevLicense } else { $null }; EnableDeveloperModeRequested = [bool]$EnableDeveloperMode; Package = $package; Features = $features; DriversRequested = [bool]$IncludeDriversAndService; ServiceRequested = [bool]$IncludeDriversAndService; ExistingSimulationServices = @(Get-Service -Name mrperceptionsimulation -ErrorAction SilentlyContinue | Select-Object Name,Status,StartType) }
[IO.File]::WriteAllText((Join-Path $folder 'baseline.json'), ($baseline | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
$log = Join-Path $folder 'msi.log'
$start = [Diagnostics.ProcessStartInfo]::new('msiexec.exe')
$start.Arguments = '/i "' + $package + '" ADDLOCAL=' + ($features -join ',') + ' /qn /norestart REBOOT=ReallySuppress /L*V "' + $log + '"'
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$process = [Diagnostics.Process]::Start($start)
$process.WaitForExit()
$code = $process.ExitCode
if ($code -notin @(0,3010)) {
    $failure = [ordered]@{ At = (Get-Date).ToString('o'); ExitCode = $code; Installed = $false; RequestedFeatures = $features; Evidence = $folder; MsiLog = $log }
    [IO.File]::WriteAllText((Join-Path $folder 'result.json'), ($failure | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
    throw ('Microsoft installation failed with code ' + $code + '; see ' + $log)
}
if ($EnableDeveloperMode) {
    New-Item -Path $devKey -Force | Out-Null
    New-ItemProperty -LiteralPath $devKey -Name AllowDevelopmentWithoutDevLicense -Value 1 -PropertyType DWord -Force | Out-Null
}
$control = Join-Path $env:ProgramFiles 'Microsoft Perception Simulation/Control/PerceptionSimulationControl.exe'
if (-not (Test-Path -LiteralPath $control)) { throw 'The Microsoft control executable was not installed at the expected path.' }
if ((Get-FileHash -LiteralPath $control).Hash -cne 'B31AA8177BE97AF20D0B3C97E59BB3AD169082920C86CB6BFF0BC0B2F8DDA09D') { throw 'Installed control does not match the reviewed Microsoft payload.' }
$serviceError = $null
$drivers = @()
if ($IncludeDriversAndService) {
    try { Start-Service -Name mrperceptionsimulation -ErrorAction Stop } catch { $serviceError = $_.Exception.Message }
    try { $drivers = @(Get-WindowsDriver -Online -All -ErrorAction Stop | Where-Object OriginalFileName -match 'perceptionsimulation(headset|sixdof)' | Select-Object Driver,OriginalFileName,ProviderName,ClassName,Date,Version,Inbox) } catch { $drivers = @([pscustomobject]@{InventoryError=$_.Exception.Message}) }
}
$result = [ordered]@{ At = (Get-Date).ToString('o'); ExitCode = $code; Installed = $true; RestartRequired = ($code -eq 3010); Control = $control; ControlSHA256 = (Get-FileHash -LiteralPath $control).Hash; DeveloperModeEnabled = ((Get-ItemProperty -LiteralPath $devKey -Name AllowDevelopmentWithoutDevLicense -ErrorAction SilentlyContinue).AllowDevelopmentWithoutDevLicense -eq 1); DriversRequested = [bool]$IncludeDriversAndService; ServiceRequested = [bool]$IncludeDriversAndService; Service = @(Get-Service -Name mrperceptionsimulation -ErrorAction SilentlyContinue | Select-Object Name,Status,StartType); ServiceError = $serviceError; DriverStore = $drivers; Evidence = $folder }
[IO.File]::WriteAllText((Join-Path $folder 'result.json'), ($result | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
$result | ConvertTo-Json -Depth 4
