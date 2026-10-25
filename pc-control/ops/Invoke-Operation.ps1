param(
    [Parameter(Mandatory)][ValidateSet('BridgeStatus','Portal','StartLease','StopLease','FocusApp','Controller','Video')][string]$Operation,
    [ValidatePattern('^[A-Za-z0-9_-]{1,64}$')][string]$RunId
)
$ErrorActionPreference='Stop'
# .NET Framework parents can otherwise make PowerShell inherit an OEM codepage.
# This also keeps Chinese evidence paths intact in the desktop session log.
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$OutputEncoding=[Text.UTF8Encoding]::new($false)
$workspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
switch($Operation){
    'BridgeStatus' { & (Join-Path $workspace 'Connect-HoloLens.ps1') -Command status }
    'Portal' { & (Join-Path $workspace 'holographic-control\ops\Test-Connection.ps1') }
    'StartLease' { if(-not $RunId){throw 'A named lease is required.'}; & (Join-Path $workspace 'holographic-control\ops\Control-Lease.ps1') -Mode Start -RunId $RunId }
    'StopLease' { if(-not $RunId){throw 'A named lease is required.'}; & (Join-Path $workspace 'holographic-control\ops\Control-Lease.ps1') -Mode Stop -RunId $RunId }
    'FocusApp' { & (Join-Path $workspace 'field-app\ops\Start-App.ps1') }
    'Controller' { & (Join-Path $workspace 'holographic-control\ops\Start-PerceptionControl.ps1') }
    'Video' { & (Join-Path $PSScriptRoot 'Stream-Video.ps1') }
}
