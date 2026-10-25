$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'HoloLens.Common.ps1')
function Assert-Hl($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }

$script:HlConfig.DeviceName = 'HL-TEST-DEVICE'
$script:HlConfig.DiscoveryGuid = '11111111-1111-1111-1111-111111111111'
$lines = @(
    '169.254.100.20 11111111-1111-1111-1111-111111111111 HL-TEST-DEVICE'
    '169.254.100.21 22222222-2222-2222-2222-222222222222 HL-TEST-DEVICE'
    '169.254.100.22 33333333-3333-3333-3333-333333333333 OTHER-HOLOLENS'
    '169.254.999.21 44444444-4444-4444-4444-444444444444 HL-TEST-DEVICE'
    '10.0.0.8 55555555-5555-5555-5555-555555555555 HL-TEST-DEVICE'
)
$script:TestCandidates = @(ConvertFrom-HlDiscoveryOutput $lines)
Assert-Hl ($script:TestCandidates.Count -eq 2) 'Discovery must exclude other names, malformed addresses and non-USB addresses.'
Assert-Hl ($script:TestCandidates[0].Address -eq '169.254.100.20') 'The saved GUID must remain the preferred discovery hint.'
$script:ProbeAddresses = [Collections.Generic.List[string]]::new()
$script:Disposed = 0
function Get-HlDiscoveredDevices { $script:TestCandidates }
function Connect-HlDevice([string]$Address) {
    $script:ProbeAddresses.Add($Address)
    if ($Address -ne '169.254.100.21') { throw 'SSH host identity differs from the paired HoloLens.' }
    $mock = [pscustomobject]@{}
    $mock | Add-Member ScriptMethod Disconnect {}
    $mock | Add-Member ScriptMethod Dispose { $script:Disposed++ }
    $mock
}
$selected = Find-HlDevice
Assert-Hl ($selected -eq '169.254.100.21') 'An old GUID must not prevent reconnecting to the authenticated device.'
Assert-Hl ($script:ProbeAddresses.Count -eq 2) 'A rejected preferred address must not prevent trying the authenticated candidate.'
Assert-Hl ($script:HlDiscoveredGuid -eq '22222222-2222-2222-2222-222222222222') 'Reported discovery identity must describe the current connection.'
Assert-Hl ($script:Disposed -eq 1) 'Successful identity probe must release its connection.'
$selectedConnection=Find-HlDevice -KeepConnection
Assert-Hl ($selectedConnection.Address -eq '169.254.100.21' -and $null -ne $selectedConnection.Client) 'The bridge must reuse the already authenticated connection.'
Assert-Hl ($script:Disposed -eq 1) 'A retained connection must not be disposed before the bridge can use it.'
Close-HlDeviceConnection $selectedConnection.Client
Assert-Hl ($script:Disposed -eq 2) 'The bridge retains responsibility for closing its connection.'
$script:TestCandidates = @($script:TestCandidates[0])
$rejected = $false
try { Find-HlDevice | Out-Null } catch { $rejected = $_.Exception.Message -like '*No discovered candidate authenticated*' }
Assert-Hl $rejected 'A matching name and GUID must never bypass SSH identity validation.'
$script:TestCandidates = @()
$missing = $false
try { Find-HlDevice | Out-Null } catch { $missing = $_.Exception.Message -like '*USB network is unavailable*' }
Assert-Hl $missing 'A missing USB device must remain a retry state.'
'Discovery regression checks passed: filtering, GUID changes, rejected candidates, connection disposal and missing device.'
