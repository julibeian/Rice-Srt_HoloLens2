function ConvertTo-VideoPowerObservation {
    param($State,[int]$HttpStatus=200,[string]$ReadError)
    $known=$false;$sleeping=$null;$available=$null;$reason=$null
    if($ReadError){$reason=$ReadError}
    elseif($HttpStatus -ne 200){$reason='power_http_'+$HttpStatus}
    elseif($null -eq $State){$reason='power_response_missing'}
    else{
        $powerProperty=$State.PSObject.Properties['LowPowerState']
        $availableProperty=$State.PSObject.Properties['LowPowerStateAvailable']
        if($availableProperty -and $availableProperty.Value -is [bool]){$available=$availableProperty.Value}
        if($available -ceq $false){$reason='power_state_unavailable'}
        elseif($availableProperty -and $availableProperty.Value -isnot [bool]){$reason='power_availability_invalid'}
        elseif(-not $powerProperty){$reason='power_state_missing'}
        elseif($powerProperty.Value -isnot [bool]){$reason='power_state_invalid'}
        else{$known=$true;$sleeping=$powerProperty.Value}
    }
    [pscustomobject]@{PowerStateKnown=$known;LowPowerState=$sleeping;LowPowerStateAvailable=$available;PowerState=if(-not $known){'unknown'}elseif($sleeping){'low_power'}else{'awake'};PowerObservationError=$reason}
}
