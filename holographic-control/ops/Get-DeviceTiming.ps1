# Inspect is read-only. PeriodTest requests1ms only for this worker and balances
# timeEndPeriod after45s. Reusing the same Mode/RunId only observes that attempt.
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_-]{1,64}$')][string]$RunId,
    [ValidateSet('Inspect','PeriodTest')][string]$Mode='Inspect'
)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$workspace=Split-Path -Parent $root
. (Join-Path $workspace 'HoloLens.Common.ps1')
$folder=Join-Path $root ('.state/timing/'+$RunId)
$checkpoint=Join-Path $folder 'invocation.json'
$base='U:\Users\DefaultAccount\AppData\Local\DevelopmentFiles\RiceHoloLensFieldV1'
$out=$base+'\'+$RunId+'.json'
$utf8=[Text.UTF8Encoding]::new($false)
function Save($Name,$Value){[IO.File]::WriteAllText((Join-Path $folder $Name),($Value|ConvertTo-Json -Depth 8),$utf8)}
$device=Invoke-HlBridge @{action='info'}
if($device.DeviceName -cne $script:HlConfig.DeviceName -or $device.HostFingerprint -cne $script:HlConfig.ExpectedFingerprint){throw 'Original USB identity is not verified'}
if(Test-Path -LiteralPath $checkpoint){
    $invocation=Get-Content -Raw -LiteralPath $checkpoint|ConvertFrom-Json
    if($invocation.RunId -cne $RunId -or $invocation.RemoteReport -cne $out -or $invocation.Device -cne $device.DeviceName -or $invocation.SshFingerprint -cne $device.HostFingerprint){throw 'Timing observation identity mismatch'}
    $previousMode=if($invocation.PSObject.Properties['Mode']){$invocation.Mode}else{'Inspect'}
    if($previousMode -cne $Mode){throw 'This timing RunId has another mode; do not replay it.'}
}else{
    [IO.Directory]::CreateDirectory($folder)|Out-Null
    $build=& (Join-Path $PSScriptRoot 'Build-Probe.ps1') -Probe timing|ConvertFrom-Json
    $remote=$base+'\hl-timing-'+$build.Sha256.Substring(0,16)+'.exe'
    if(-not(Invoke-HlBridge @{action='stat';path=$remote}).Exists){Invoke-HlBridge @{action='put';local=$build.Path;path=$remote}|Out-Null}
    $copy=Join-Path $folder 'worker.exe';Invoke-HlBridge @{action='get';path=$remote;local=$copy}|Out-Null
    if((Get-FileHash -LiteralPath $copy).Hash -cne $build.Sha256){throw 'Timing worker hash mismatch'}
    if((Invoke-HlBridge @{action='stat';path=$out}).Exists){throw 'Remote observation already exists'}
    Save 'invocation.json' @{RunId=$RunId;Mode=$Mode;At=[DateTimeOffset]::Now.ToString('o');Device=$device.DeviceName;SshFingerprint=$device.HostFingerprint;RemoteReport=$out;WorkerSha256=$build.Sha256;LaunchAttempted=$true;InputSent=$false;TimerRequestAllowed=($Mode -eq 'PeriodTest');MaxHoldSeconds=45}
    $flag=if($Mode -eq 'PeriodTest'){'--period-test-45-seconds '}else{''}
    $launch=Invoke-HlBridge @{action='exec';executable='C:\Windows\System32\DevToolsLauncher.exe';arguments=('LaunchForDebug '+$remote+' "'+$flag+'--out '+$out+'" Rice.HoloLens.Field_r5420n6798s24!Field')}
    Save 'launch.json' $launch
    if($launch.ExitCode -ne 0){throw 'Timing-query launch rejected; inspect the same RunId without replay'}
}
$clock=[Diagnostics.Stopwatch]::StartNew();$report=$null
while($clock.ElapsedMilliseconds -lt 15000){
    $stat=Invoke-HlBridge @{action='stat';path=$out}
    if($stat.Exists -and $stat.Length -gt 0){try{$report=(Invoke-HlBridge @{action='cat';path=$out}).Text|ConvertFrom-Json;break}catch{}}
    Start-Sleep -Milliseconds 250
}
if(-not $report){throw ('Timing query pending; inspect the SAME RunId: '+$RunId)}
if($report.inputSent -cne $false -or ($Mode -eq 'Inspect' -and ($report.readonly -cne $true -or $report.timerResolutionChanged -cne $false))){throw 'Unexpected timing report'}
$terminal=($Mode -eq 'Inspect' -or $report.phase -eq 'finished')
$balanced=if($Mode -eq 'Inspect'){$null}else{$terminal -and $report.beginPeriodResult -eq 0 -and $report.endPeriodResult -eq 0}
$proof=@{RunId=$RunId;Mode=$Mode;At=[DateTimeOffset]::Now.ToString('o');Terminal=$terminal;Active=($report.phase -eq 'period_active');RequestBalanced=$balanced;IdentityVerified=$true;InputSent=$false;TimerResolutionChanged=$report.timerResolutionChanged;Report=$report;Evidence=$folder;ReplayAllowed=$false}
Save 'result.json' $proof
$proof|ConvertTo-Json -Depth 8
