param(
    [ValidateSet('Status','Start','Complete')][string]$Mode='Status',
    [ValidatePattern('^[A-Za-z0-9_-]{1,64}$')][string]$RunId='portal-setup',
    [Security.SecureString]$Pin
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Holographic.Common.ps1')
. (Join-Path $PSScriptRoot 'PortalPairing.Common.ps1')
$result=Invoke-HoloPortalPairing -Mode $Mode -RunId $RunId -Pin $Pin
if($result.PSObject.Properties['Evidence']){Save-HoloPairingState $result (Join-Path $result.Evidence 'result.json')}
$result|ConvertTo-Json -Depth 5
