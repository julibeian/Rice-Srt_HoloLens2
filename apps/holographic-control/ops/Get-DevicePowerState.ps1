param([Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_-]{1,64}$')][string]$RunId)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$workspace=Split-Path -Parent (Split-Path -Parent $root)
. (Join-Path $workspace 'usb-terminal/HoloLens.Common.ps1')
$folder=Join-Path $root ('.state/power-observations/'+$RunId)
$checkpoint=Join-Path $folder 'invocation.json'
$base='U:\Users\DefaultAccount\AppData\Local\DevelopmentFiles\RiceHoloLensFieldV1'
$out=$base+'\'+$RunId+'.json'
$utf8=[Text.UTF8Encoding]::new($false)
function Save($Name,$Value){[IO.File]::WriteAllText((Join-Path $folder $Name),($Value|ConvertTo-Json -Depth 12),$utf8)}
$device=Invoke-HlBridge @{action='info'}
if($device.DeviceName -cne $script:HlConfig.DeviceName -or $device.HostFingerprint -cne $script:HlConfig.ExpectedFingerprint){throw 'Original USB identity is not verified'}
if(Test-Path -LiteralPath $checkpoint){
 $invocation=Get-Content -LiteralPath $checkpoint -Raw|ConvertFrom-Json
 if($invocation.RunId -cne $RunId -or $invocation.RemoteReport -cne $out -or $invocation.Device -cne $device.DeviceName -or $invocation.SshFingerprint -cne $device.HostFingerprint){throw 'Power observation identity mismatch'}
}else{
 [IO.Directory]::CreateDirectory($folder)|Out-Null
 $build=& (Join-Path $PSScriptRoot 'Build-Probe.ps1') -Probe power-state|ConvertFrom-Json
 $remote=$base+'\hl-power-state-'+$build.Sha256.Substring(0,16)+'.exe'
 if(-not(Invoke-HlBridge @{action='stat';path=$remote}).Exists){Invoke-HlBridge @{action='put';path=$remote;local=$build.Path}|Out-Null}
 $copy=Join-Path $folder 'worker.exe';Invoke-HlBridge @{action='get';path=$remote;local=$copy}|Out-Null
 if((Get-FileHash -LiteralPath $copy).Hash -cne $build.Sha256){throw 'Read-only power worker hash mismatch'}
 if((Invoke-HlBridge @{action='stat';path=$out}).Exists){throw 'Remote observation already exists'}
 Save 'invocation.json' @{RunId=$RunId;At=[DateTimeOffset]::Now.ToString('o');Device=$device.DeviceName;SshFingerprint=$device.HostFingerprint;RemoteReport=$out;WorkerSha256=$build.Sha256;LaunchAttempted=$true;InputSent=$false}
 $launch=Invoke-HlBridge @{action='exec';executable='C:\Windows\System32\DevToolsLauncher.exe';arguments=('LaunchForDebug '+$remote+' "--out '+$out+'" Rice.HoloLens.Field_r5420n6798s24!Field')}
 Save 'launch.json' $launch
 if($launch.ExitCode -ne 0){throw 'Diagnostic launch rejected; query the same RunId without replay'}
}
$watch=[Diagnostics.Stopwatch]::StartNew();$report=$null
while($watch.ElapsedMilliseconds -lt 25000){
 $stat=Invoke-HlBridge @{action='stat';path=$out}
 if($stat.Exists -and $stat.Length -gt 0){$report=(Invoke-HlBridge @{action='cat';path=$out}).Text|ConvertFrom-Json;break}
 Start-Sleep -Milliseconds 300
}
if(-not $report){throw ('Diagnostic pending; query the SAME RunId without relaunch: '+$RunId)}
if($report.readonly -cne $true -or $report.inputSent -cne $false){throw 'Unexpected diagnostic report type'}
Save 'native-result.json' $report
if($report.systemEvents.PSObject.Properties['files']){
 foreach($item in $report.systemEvents.files){if(-not $item.saved){continue};$remotePath=[string]$item.path;if(-not $remotePath.StartsWith($out,[StringComparison]::Ordinal)){throw 'Unexpected event artifact path'};$suffix=$remotePath.Substring($out.Length);if($suffix -cnotmatch '^\.event-[0-5]\.xml$'){throw 'Unexpected event artifact suffix'};$local=Join-Path $folder ([IO.Path]::GetFileName($remotePath));if(-not(Test-Path -LiteralPath $local)){Invoke-HlBridge @{action='get';path=$remotePath;local=$local}|Out-Null}}
}
Save 'result.json' @{At=[DateTimeOffset]::Now.ToString('o');RunId=$RunId;Terminal=$true;InputSent=$false;Report=$report;Evidence=$folder;ReplayAllowed=$false}
@{At=[DateTimeOffset]::Now.ToString('o');RunId=$RunId;Terminal=$true;Report=$report;Evidence=$folder;InputSent=$false}|ConvertTo-Json -Depth 10
