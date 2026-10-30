$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../ops/Video.Health.Model.ps1')
$cases=@(
    @{body='{"LowPowerState":false,"LowPowerStateAvailable":true}';expected='awake';known=$true},
    @{body='{"LowPowerState":true,"LowPowerStateAvailable":true}';expected='low_power';known=$true},
    @{body='{"LowPowerState":false}';expected='awake';known=$true},
    @{body='{"LowPowerState":false,"LowPowerStateAvailable":false}';expected='unknown';known=$false},
    @{body='{"LowPowerStateAvailable":true}';expected='unknown';known=$false},
    @{body='{"LowPowerState":"false","LowPowerStateAvailable":true}';expected='unknown';known=$false},
    @{body='{"LowPowerState":0,"LowPowerStateAvailable":true}';expected='unknown';known=$false},
    @{body='{"LowPowerState":false,"LowPowerStateAvailable":"true"}';expected='unknown';known=$false},
    @{body='{"LowPowerState":null}';expected='unknown';known=$false}
)
foreach($case in $cases){
    $value=ConvertTo-VideoPowerObservation -State ($case.body|ConvertFrom-Json)
    if($value.PowerState -cne $case.expected -or $value.PowerStateKnown -cne $case.known){throw ('Unexpected power classification: '+$case.body)}
    if(-not $case.known -and ($null -ne $value.LowPowerState -or -not $value.PowerObservationError)){throw 'Unknown power must remain nullable with a reason'}
}
foreach($code in @(401,404,503)){
    $value=ConvertTo-VideoPowerObservation -State ('{"LowPowerState":false}'|ConvertFrom-Json) -HttpStatus $code
    if($value.PowerStateKnown -or $null -ne $value.LowPowerState){throw 'Rejected query must not imply awake'}
}
$failed=ConvertTo-VideoPowerObservation -ReadError 'TaskCanceledException'
if($failed.PowerState -cne 'unknown' -or $failed.PowerObservationError -cne 'TaskCanceledException'){throw 'Network observation error not retained'}
@{passed=13;device_operations=0;unknown_does_not_mean_awake=$true}|ConvertTo-Json
