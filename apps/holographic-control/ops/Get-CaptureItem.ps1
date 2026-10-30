param([Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_-]{1,64}$')][string]$RunId)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$workspace=Split-Path -Parent (Split-Path -Parent $root)
. (Join-Path $workspace 'usb-terminal/HoloLens.Common.ps1')
$folder=Join-Path $root ('.state/capture-item/'+$RunId)
$checkpoint=Join-Path $folder 'invocation.json'
$base='U:\Users\DefaultAccount\AppData\Local\DevelopmentFiles\RiceHoloLensFieldV1'
$out=$base+'\'+$RunId+'.json'
$utf8=[Text.UTF8Encoding]::new($false)
function Save($Name,$Value){[IO.File]::WriteAllText((Join-Path $folder $Name),($Value|ConvertTo-Json -Depth 8),$utf8)}
$device=Invoke-HlBridge @{action='info'}
if($device.DeviceName -cne $script:HlConfig.DeviceName -or $device.HostFingerprint -cne $script:HlConfig.ExpectedFingerprint){throw 'Original USB identity is not verified'}
if(Test-Path -LiteralPath $checkpoint){
    $invocation=Get-Content -Raw -LiteralPath $checkpoint|ConvertFrom-Json
    if($invocation.RunId -cne $RunId -or $invocation.RemoteReport -cne $out -or $invocation.Device -cne $device.DeviceName -or $invocation.SshFingerprint -cne $device.HostFingerprint){throw 'Capture-item observation identity mismatch'}
}else{
    [IO.Directory]::CreateDirectory($folder)|Out-Null
    $build=& (Join-Path $PSScriptRoot 'Build-Probe.ps1') -Probe capture-item|ConvertFrom-Json
    $remote=$base+'\hl-capture-item-'+$build.Sha256.Substring(0,16)+'.exe'
    if(-not(Invoke-HlBridge @{action='stat';path=$remote}).Exists){Invoke-HlBridge @{action='put';local=$build.Path;path=$remote}|Out-Null}
    $copy=Join-Path $folder 'worker.exe';Invoke-HlBridge @{action='get';path=$remote;local=$copy}|Out-Null
    if((Get-FileHash -LiteralPath $copy).Hash -cne $build.Sha256){throw 'Capture-item worker hash mismatch'}
    if((Invoke-HlBridge @{action='stat';path=$out}).Exists){throw 'Remote observation already exists'}
    Save 'invocation.json' @{RunId=$RunId;At=[DateTimeOffset]::Now.ToString('o');Device=$device.DeviceName;SshFingerprint=$device.HostFingerprint;RemoteReport=$out;WorkerSha256=$build.Sha256;LaunchAttempted=$true;InputSent=$false;CaptureStarted=$false}
    $launch=Invoke-HlBridge @{action='exec';executable='C:\Windows\System32\DevToolsLauncher.exe';arguments=('LaunchForDebug '+$remote+' "--out '+$out+'" Rice.HoloLens.Field_r5420n6798s24!Field')}
    Save 'launch.json' $launch
    if($launch.ExitCode -ne 0){throw 'Capability-query launch rejected; inspect the same RunId without replay'}
}
$clock=[Diagnostics.Stopwatch]::StartNew();$report=$null
while($clock.ElapsedMilliseconds -lt 15000){
    $stat=Invoke-HlBridge @{action='stat';path=$out}
    if($stat.Exists -and $stat.Length -gt 0){$report=(Invoke-HlBridge @{action='cat';path=$out}).Text|ConvertFrom-Json;break}
    Start-Sleep -Milliseconds 250
}
if(-not $report){throw ('Capability query pending; inspect the SAME RunId: '+$RunId)}
if($report.readonly -cne $true -or $report.inputSent -cne $false -or $report.pickerOpened -cne $false -or $report.captureStarted -cne $false){throw 'Unexpected capability-only report'}
$proof=@{RunId=$RunId;At=[DateTimeOffset]::Now.ToString('o');Terminal=$true;IdentityVerified=$true;InputSent=$false;CaptureStarted=$false;Report=$report;Evidence=$folder;ReplayAllowed=$false}
Save 'result.json' $proof
$proof|ConvertTo-Json -Depth 8
