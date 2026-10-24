$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'field-app/ops/Field.NetworkPolicy.ps1')
$checks = 0
function Assert-Recovery($Inspection, [bool]$Expected, [string]$Reason) {
    $actual = Get-FieldWifiRecoveryDecision $Inspection
    if ($actual.CanRecover -ne $Expected -or $actual.Reason -cne $Reason) {
        throw ('Unexpected recovery decision: ' + ($actual | ConvertTo-Json -Compress))
    }
    $script:checks++
}
function Disconnected-Fixture {
    # Shape observed on the real HoloLens: no current connection properties.
    @'
{"openError":0,"enumError":0,"interfaces":[{"state":4,"radioQueryError":0,"radios":[{"software":1,"hardware":1}],"listError":0,"matchingNetworks":[{"ssid":"NJAU","profile":"NJAU","connectable":true,"secure":false,"auth":1}],"connectionQueryError":5023}]}
'@ | ConvertFrom-Json
}
$wifi = Disconnected-Fixture
Assert-Recovery $wifi $true 'saved_njau_recovery_allowed'
$wifi = Disconnected-Fixture
$wifi.interfaces[0].state = 1
Assert-Recovery $wifi $false 'wifi_connection_unverified'
$wifi = Disconnected-Fixture
$wifi.interfaces[0] | Add-Member NoteProperty connectionState 1
$wifi.interfaces[0] | Add-Member NoteProperty connectedSsid 'OTHER'
$wifi.interfaces[0].connectionQueryError = 0
Assert-Recovery $wifi $false 'different_wifi_kept'
$wifi.interfaces[0].connectedSsid = 'NJAU'
Assert-Recovery $wifi $true 'saved_njau_recovery_allowed'
$wifi.interfaces[0].connectedSsid = ''
Assert-Recovery $wifi $false 'wifi_connection_unverified'
$wifi = Disconnected-Fixture
$wifi.interfaces[0].matchingNetworks[0].profile = ''
Assert-Recovery $wifi $false 'saved_njau_profile_unavailable'
$wifi = Disconnected-Fixture
$wifi.interfaces[0].radios[0].software = 2
Assert-Recovery $wifi $false 'wifi_radio_not_enabled'
# A second enabled adapter must not authorize recovery on a disabled target.
$wifi.interfaces += ((Disconnected-Fixture).interfaces[0])
$wifi.interfaces[1].matchingNetworks = @()
Assert-Recovery $wifi $false 'wifi_radio_not_enabled'
$wifi = Disconnected-Fixture
$wifi.interfaces[0].matchingNetworks[0].secure = $true
Assert-Recovery $wifi $false 'saved_njau_profile_unavailable'
$wifi = Disconnected-Fixture
$wifi.openError = 5
Assert-Recovery $wifi $false 'wifi_inspection_unavailable'
Assert-Recovery ([pscustomobject]@{}) $false 'wifi_inspection_unavailable'
$wifi = Disconnected-Fixture
$wifi.interfaces = @()
Assert-Recovery $wifi $false 'wifi_inspection_unavailable'
"Network recovery checks passed: $checks (including the disconnected-device regression)."
