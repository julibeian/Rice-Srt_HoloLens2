#Requires -Version 7.0
param([string]$Workspace=(Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
$ErrorActionPreference='Stop'
$Workspace=[IO.Path]::GetFullPath($Workspace)
$checks=[Collections.Generic.List[object]]::new()
function Add-Check([string]$Name,[bool]$Passed,[string]$Detail){
    $checks.Add([pscustomobject]@{Name=$Name;Passed=$Passed;Detail=$Detail})
}
Add-Check 'Windows x64 process' ($IsWindows -and [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -eq 'X64') 'Use PowerShell 7 x64 on the Windows workstation.'
$runtime=Join-Path $Workspace 'runtime/powershell'
Add-Check 'Dedicated PowerShell runtime' ((Test-Path -LiteralPath (Join-Path $runtime 'pwsh.exe')) -and (Test-Path -LiteralPath (Join-Path $runtime 'pwsh.dll'))) 'Extract the complete official PowerShell win-x64 ZIP into runtime/powershell.'
$configPath=Join-Path $Workspace 'config.json'
$config=$null
try{if(Test-Path -LiteralPath $configPath){$config=Get-Content -LiteralPath $configPath -Raw|ConvertFrom-Json}}catch{}
Add-Check 'Readable local configuration' ($null -ne $config) 'Create config.json from config.example.json only if no configuration already exists.'
if($null -ne $config){
    $values=@{}
    foreach($property in $config.PSObject.Properties){$values[$property.Name]=$property.Value}
    foreach($name in @('DeviceName','ExpectedFingerprint','SdkDirectory','RemoteWorkingDirectory','ScheduledTaskName')){
        $value=[string]$values[$name]
        Add-Check ('Configured '+$name) (-not [string]::IsNullOrWhiteSpace($value) -and $value -notmatch '^CONFIGURE_') 'Fill this field with the administrator-verified value for this workstation and headset.'
    }
    foreach($name in @('KeepAliveSeconds','ReconnectSeconds','CommandTimeoutSeconds')){
        $number=0
        Add-Check ('Positive '+$name) ([int]::TryParse([string]$values[$name],[ref]$number) -and $number -gt 0) 'Use a positive integer.'
    }
    foreach($name in @('WinAppDeployCmd.exe','Microsoft.Tools.Deploy.dll')){
        $exists=$values['SdkDirectory'] -and (Test-Path -LiteralPath (Join-Path $values['SdkDirectory'] $name) -PathType Leaf)
        Add-Check ('SDK '+$name) ([bool]$exists) 'Use a complete matching x64 Windows SDK tool directory.'
    }
}
foreach($name in @('Connect-HoloLens.ps1','Start-HoloLensBridge.ps1','Register-HoloLensTask.ps1','HoloLens.Common.ps1','HoloLens.Bridge.ps1','HoloLens.Watchdog.ps1')){
    Add-Check $name (Test-Path -LiteralPath (Join-Path $Workspace $name) -PathType Leaf) 'Keep the repository directory structure.'
}
$ok=@($checks|Where-Object {-not $_.Passed}).Count -eq 0
[pscustomobject]@{Ok=$ok;DeviceContacted=$false;ConfigurationChanged=$false;IdentityVerified=$false;Checks=$checks.ToArray()}|ConvertTo-Json -Depth 4
if(-not $ok){exit 1}
