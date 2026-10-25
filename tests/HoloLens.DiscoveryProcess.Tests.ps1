$ErrorActionPreference='Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'HoloLens.Common.ps1')
$clock=[Diagnostics.Stopwatch]::StartNew()
$timedOut=$false;$ownedPid=0
try { Get-HlDiscoveredDevices -TimeoutMilliseconds 1 | Out-Null }
catch [TimeoutException] {$timedOut=$true;$ownedPid=[int]$_.Exception.Data['DiscoveryProcessId']}
if(-not $timedOut -or $ownedPid -le 0){throw 'A bounded SDK discovery must report its timeout and owned child PID.'}
if($clock.ElapsedMilliseconds -gt 5000){throw 'The SDK discovery timeout did not remain bounded.'}
if(Get-Process -Id $ownedPid -ErrorAction SilentlyContinue){throw 'The timed-out discovery child is still running.'}
'Discovery process regression passed: bounded wait and cleanup of only its owned SDK child.'
