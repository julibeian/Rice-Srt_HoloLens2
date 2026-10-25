$ErrorActionPreference='Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'HoloLens.Common.ps1')
function Assert-Connection($Condition,[string]$Message){if(-not $Condition){throw $Message}}
$remote=[pscustomobject]@{Sha1Fingerprint=$script:HlConfig.ExpectedFingerprint;UserName='DevToolsUser'}
$client=[pscustomobject]@{RemoteDevice=$remote;TargetInfo=$null;EffectiveProcessorArchitecture=$null}
$info=Get-HlDeviceInfo $client '127.0.0.2'
Assert-Connection (-not $info.MetadataAvailable) 'A relay without SDK discovery metadata must remain usable after SSH identity verification.'
Assert-Connection ($null -eq $info.Architecture) 'Missing architecture must not be invented.'
Assert-Connection ($info.MetadataErrors.Count -gt 0) 'Missing metadata must have a diagnostic.'
Assert-Connection ($info.HostFingerprint -ceq $script:HlConfig.ExpectedFingerprint) 'Identity must come from the SSH connection.'
Assert-Connection ($info.Transport -eq 'Network / authenticated SSH') 'Network transport must not be labelled USB.'
$client.TargetInfo=[pscustomobject]@{Connected=$true;Build=22621}
$client.EffectiveProcessorArchitecture='Arm64'
$info=Get-HlDeviceInfo $client '169.254.100.20'
Assert-Connection ($info.MetadataAvailable -and $info.Target.Connected -eq $true -and $info.Target.Build -eq '22621') 'Available metadata must remain represented.'
Assert-Connection ($info.Architecture -eq 'Arm64') 'SDK architecture must remain represented.'
$client.PSObject.Properties.Remove('TargetInfo')
$info=Get-HlDeviceInfo $client '127.0.0.2'
Assert-Connection ($info.MetadataErrors.Count -gt 0 -and -not $info.MetadataAvailable) 'A failed metadata property must preserve its error without losing the SSH connection.'
$remote.Sha1Fingerprint='UNTRUSTED'
$rejected=$false
try{Get-HlDeviceInfo $client '127.0.0.2'|Out-Null}catch{$rejected=$_.Exception.Message -like '*SSH host identity differs*'}
Assert-Connection $rejected 'Unavailable metadata must never bypass the original SSH pin.'
$script:CleanupCalls=[Collections.Generic.List[string]]::new()
$broken=[pscustomobject]@{}
$broken|Add-Member ScriptMethod Disconnect {$script:CleanupCalls.Add('disconnect');throw 'Device already disconnected'}
$broken|Add-Member ScriptMethod Dispose {$script:CleanupCalls.Add('dispose')}
Close-HlDeviceConnection $broken
Assert-Connection (($script:CleanupCalls -join ',') -ceq 'disconnect,dispose') 'Lost connections must still release their SDK resources.'
Close-HlDeviceConnection $null
$now=[DateTimeOffset]::Now
$saved=[pscustomobject]@{ProcessId=1234;UpdatedAt=$now.AddSeconds(-121).ToString('o')}
Assert-Connection (Test-HlWorkerStalled $saved 1234 $now) 'A live process with expired bridge progress must be recoverable.'
Assert-Connection (-not(Test-HlWorkerStalled $saved 5678 $now)) 'A stale status for a different PID must never cause termination.'
$saved.UpdatedAt=$now.AddSeconds(-60).ToString('o')
Assert-Connection (-not(Test-HlWorkerStalled $saved 1234 $now)) 'A normal SDK operation must retain its recovery budget.'
$saved.UpdatedAt='invalid'
Assert-Connection (-not(Test-HlWorkerStalled $saved 1234 $now)) 'An unreadable timestamp must not authorize killing a process.'
'Connection regression passed: missing/failed metadata, architecture, transport, host identity, lost-session cleanup and stalled-worker ownership.'
