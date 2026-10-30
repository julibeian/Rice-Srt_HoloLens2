param(
    [Parameter(Mandatory)][ValidateSet('BridgeStatus','Portal','Power','StartLease','StopLease','Applications','LaunchApplication','ApplicationStatus','Controller','Video')][string]$Operation,
    [ValidatePattern('^[A-Za-z0-9_-]{1,64}$')][string]$RunId,
    [string]$Aumid,[string]$PackageFullName,
    [ValidateSet('Interactive','Detail')][string]$VideoProfile='Interactive'
)
$ErrorActionPreference='Stop'
# .NET Framework parents can otherwise make PowerShell inherit an OEM codepage.
# This also keeps Chinese evidence paths intact in the desktop session log.
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$OutputEncoding=[Text.UTF8Encoding]::new($false)
$workspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
switch($Operation){
    'BridgeStatus' { & (Join-Path $workspace 'usb-terminal/Connect-HoloLens.ps1') -Command status }
    'Portal' { & (Join-Path $workspace 'apps/holographic-control\ops\Test-Connection.ps1') }
    'Power' { & (Join-Path $PSScriptRoot 'Get-VideoHealth.ps1') }
    'StartLease' { if(-not $RunId){throw 'A named lease is required.'}; & (Join-Path $workspace 'apps/holographic-control\ops\Control-Lease.ps1') -Mode Start -RunId $RunId }
    'StopLease' { if(-not $RunId){throw 'A named lease is required.'}; & (Join-Path $workspace 'apps/holographic-control\ops\Control-Lease.ps1') -Mode Stop -RunId $RunId }
    'Applications' { & (Join-Path $PSScriptRoot 'Invoke-Applications.ps1') -Action List -RunId $RunId }
    'LaunchApplication' { & (Join-Path $PSScriptRoot 'Invoke-Applications.ps1') -Action Launch -RunId $RunId -Aumid $Aumid -PackageFullName $PackageFullName }
    'ApplicationStatus' { & (Join-Path $PSScriptRoot 'Invoke-Applications.ps1') -Action Status -RunId $RunId -Aumid $Aumid -PackageFullName $PackageFullName }
    'Controller' { & (Join-Path $workspace 'apps/holographic-control\ops\Start-PerceptionControl.ps1') }
    'Video' { & (Join-Path $PSScriptRoot 'Stream-Video.ps1') -VideoProfile $VideoProfile }
}
