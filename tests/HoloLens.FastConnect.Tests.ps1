$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'usb-terminal/HoloLens.Common.ps1')
function Assert-Fast($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }

# Isolated cache and identity so this test never touches the real device state.
$script:HlEndpointPath = Join-Path $script:HlStateDirectory ('fast-connect-' + [guid]::NewGuid().ToString('N') + '.json')
$script:HlConfig.DeviceName = 'HL-FAST-DEVICE'
$script:HlConfig.DiscoveryGuid = '99999999-9999-9999-9999-999999999999'
$script:HlConfig.ExpectedFingerprint = 'AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD'
$script:CachedAddress = '169.254.100.20'
$script:DiscoveredAddress = '169.254.100.21'
$script:Reachable = $false
$script:DiscoveryCalls = 0
$script:ConnectCalls = [Collections.Generic.List[string]]::new()

function Get-HlDiscoveredDevices {
    $script:DiscoveryCalls++
    @([pscustomobject]@{ Address=$script:DiscoveredAddress; DiscoveryGuid='22222222-2222-2222-2222-222222222222' })
}
function Test-HlEndpointReachable([string]$Address, [int]$TimeoutMilliseconds) { return $script:Reachable }
function Connect-HlDevice([string]$Address) {
    $script:ConnectCalls.Add($Address)
    if ($Address -notin @($script:CachedAddress, $script:DiscoveredAddress)) { throw 'SSH host identity differs from the paired HoloLens.' }
    $mock = [pscustomobject]@{}
    $mock | Add-Member ScriptMethod Disconnect {}
    $mock | Add-Member ScriptMethod Dispose {}
    $mock
}

try {
    # Caching must refuse anything that is not the configured USB identity.
    Save-HlEndpoint '10.0.0.5' $script:HlConfig.ExpectedFingerprint
    Assert-Fast (-not (Test-Path -LiteralPath $script:HlEndpointPath)) 'A non-USB address must never be cached.'
    Save-HlEndpoint $script:CachedAddress 'FF:FF:FF:FF:FF:FF:FF:FF:FF:FF:FF:FF:FF:FF:FF:FF:FF:FF:FF:FF'
    Assert-Fast (-not (Test-Path -LiteralPath $script:HlEndpointPath)) 'A fingerprint that is not the pinned identity must never be cached.'
    Save-HlEndpoint $script:CachedAddress $script:HlConfig.ExpectedFingerprint
    $saved = Get-HlEndpoint
    Assert-Fast ($null -ne $saved -and $saved.Address -ceq $script:CachedAddress) 'The verified USB endpoint must be reusable.'

    # A cached endpoint that no longer matches the configured identity is ignored.
    $other = [ordered]@{ DeviceName='OTHER-DEVICE'; SshFingerprint=$script:HlConfig.ExpectedFingerprint; Address=$script:CachedAddress }
    [IO.File]::WriteAllText($script:HlEndpointPath, ($other | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    Assert-Fast ($null -eq (Get-HlEndpoint)) 'A cache for another device name must be ignored.'
    $other.DeviceName = $script:HlConfig.DeviceName
    $other.SshFingerprint = 'FF:FF:FF:FF:FF:FF:FF:FF:FF:FF:FF:FF:FF:FF:FF:FF:FF:FF:FF:FF'
    [IO.File]::WriteAllText($script:HlEndpointPath, ($other | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    Assert-Fast ($null -eq (Get-HlEndpoint)) 'A cache with a different pinned fingerprint must be ignored.'

    # Without a cache the SDK discovery list is still the fallback.
    Remove-Item -LiteralPath $script:HlEndpointPath -ErrorAction SilentlyContinue
    $script:Reachable = $false
    $script:DiscoveryCalls = 0
    $address = Find-HlDevice
    Assert-Fast ($address -ceq $script:DiscoveredAddress) 'Discovery must still locate the device without a cache.'
    Assert-Fast ($script:DiscoveryCalls -eq 1) 'Discovery must run exactly once without a cache.'
    Assert-Fast ($script:HlConnectionMethod -ceq 'discovered') 'An SDK discovery connection must be recorded as discovered.'

    # A reachable cached endpoint must skip SDK discovery entirely.
    Save-HlEndpoint $script:CachedAddress $script:HlConfig.ExpectedFingerprint
    $script:Reachable = $true
    $script:DiscoveryCalls = 0
    $script:ConnectCalls.Clear()
    $address = Find-HlDevice
    Assert-Fast ($address -ceq $script:CachedAddress) 'The verified cached USB endpoint must be reused.'
    Assert-Fast ($script:DiscoveryCalls -eq 0) 'A cached session must not pay for SDK discovery.'
    Assert-Fast ($script:HlConnectionMethod -ceq 'cached') 'The cached route must be reported as cached.'
    Assert-Fast ($script:ConnectCalls.Count -eq 1 -and $script:ConnectCalls[0] -ceq $script:CachedAddress) 'The cached address must still pass SSH identity validation.'

    # Keeping the connection must return the authenticated client and its method.
    $connection = Find-HlDevice -KeepConnection
    Assert-Fast ($connection.Address -ceq $script:CachedAddress -and $null -ne $connection.Client -and $connection.Method -ceq 'cached') 'A retained cached session must expose its client and method.'
    Close-HlDeviceConnection $connection.Client

    # An unreachable cache falls back to discovery when discovery is due.
    $script:Reachable = $false
    $script:HlLastDiscoveryAttempt = [DateTime]::MinValue
    $script:DiscoveryCalls = 0
    $address = Find-HlDevice
    Assert-Fast ($address -ceq $script:DiscoveredAddress) 'An unreachable cache must fall back to a changed USB address.'
    Assert-Fast ($script:DiscoveryCalls -eq 1) 'Discovery must run when the cached route fails and discovery is due.'

    # While discovery is rate-limited an unreachable cache must fail fast, not
    # spend the SDK discovery budget on every one-second retry.
    $script:HlLastDiscoveryAttempt = [DateTime]::UtcNow
    $script:DiscoveryCalls = 0
    $limited = $false
    try { Find-HlDevice | Out-Null } catch { $limited = $_.Exception.Message -like '*cached USB endpoint*' }
    Assert-Fast $limited 'A rate-limited cached failure must report the cached route error.'
    Assert-Fast ($script:DiscoveryCalls -eq 0) 'A rate-limited retry must not run SDK discovery.'
    'Fast-connect regression passed: cache validation, discovery fallback, cached reuse without discovery, retained client and rate-limited retry.'
} finally {
    foreach ($path in @($script:HlEndpointPath, ($script:HlEndpointPath + '.tmp'))) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue }
    }
}
