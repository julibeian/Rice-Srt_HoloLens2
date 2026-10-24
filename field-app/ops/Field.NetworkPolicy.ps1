# Pure policy: inspection failures must never become permission to switch Wi-Fi.
function Get-FieldWifiRecoveryDecision($Inspection) {
    $decision = [pscustomobject]@{ CanRecover = $false; Reason = 'wifi_inspection_unavailable' }
    if (-not $Inspection -or -not $Inspection.PSObject.Properties['openError'] -or
        -not $Inspection.PSObject.Properties['enumError'] -or
        -not $Inspection.PSObject.Properties['interfaces'] -or
        $Inspection.openError -ne 0 -or $Inspection.enumError -ne 0) { return $decision }
    $interfaces = @($Inspection.interfaces)
    if (-not $interfaces.Count) { return $decision }

    foreach ($iface in $interfaces) {
        if (-not $iface -or -not $iface.PSObject.Properties['state']) { return $decision }
        $connected = $iface.PSObject.Properties['connectionQueryError'] -and
            $iface.connectionQueryError -eq 0 -and
            $iface.PSObject.Properties['connectionState'] -and $iface.connectionState -eq 1
        if ($connected) {
            if (-not $iface.PSObject.Properties['connectedSsid'] -or -not $iface.connectedSsid) {
                $decision.Reason = 'wifi_connection_unverified'; return $decision
            }
            if ($iface.connectedSsid -cne 'NJAU') {
                $decision.Reason = 'different_wifi_kept'; return $decision
            }
        } elseif ($iface.state -ne 4) {
            $decision.Reason = 'wifi_connection_unverified'; return $decision
        }
        # WlanQueryInterface(current_connection) normally fails with 5023 while
        # disconnected (interface state 4), so connectionState/SSID are absent.
        elseif ($iface.PSObject.Properties['connectionState'] -and $iface.connectionState -ne 4) {
            $decision.Reason = 'wifi_connection_unverified'; return $decision
        }
    }

    $savedTargetSeen = $false
    foreach ($iface in $interfaces) {
        if (-not $iface.PSObject.Properties['listError'] -or $iface.listError -ne 0 -or
            -not $iface.PSObject.Properties['matchingNetworks']) { continue }
        $saved = @($iface.matchingNetworks | Where-Object {
            $_ -and $_.PSObject.Properties['ssid'] -and $_.ssid -ceq 'NJAU' -and
            $_.PSObject.Properties['profile'] -and $_.profile -ceq 'NJAU' -and
            $_.PSObject.Properties['connectable'] -and $_.connectable -eq $true -and
            $_.PSObject.Properties['secure'] -and $_.secure -eq $false -and
            $_.PSObject.Properties['auth'] -and $_.auth -eq 1
        })
        if (-not $saved.Count) { continue }
        $savedTargetSeen = $true
        if (-not $iface.PSObject.Properties['radioQueryError'] -or $iface.radioQueryError -ne 0 -or
            -not $iface.PSObject.Properties['radios']) { continue }
        $enabled = @($iface.radios | Where-Object {
            $_ -and $_.PSObject.Properties['software'] -and $_.software -eq 1 -and
            $_.PSObject.Properties['hardware'] -and $_.hardware -eq 1
        })
        if ($enabled.Count) {
            $decision.CanRecover = $true
            $decision.Reason = 'saved_njau_recovery_allowed'
            return $decision
        }
    }
    $decision.Reason = if ($savedTargetSeen) { 'wifi_radio_not_enabled' } else { 'saved_njau_profile_unavailable' }
    return $decision
}
