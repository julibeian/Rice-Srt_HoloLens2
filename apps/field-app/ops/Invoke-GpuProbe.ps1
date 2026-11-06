param([Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_-]{1,64}$')][string]$RunId,[string]$Worker,[ValidateRange(1,3600)][int]$Seconds=1)
$ErrorActionPreference='Stop'
$appRoot=Split-Path -Parent $PSScriptRoot;$workspace=Split-Path -Parent (Split-Path -Parent $appRoot)
. (Join-Path $workspace 'usb-terminal/HoloLens.Common.ps1')
$folder=Join-Path $workspace ('reports/20261106-winml-cause/hardware/'+$RunId)
$record=Join-Path $folder 'invocation.json'
$device=Invoke-HlBridge @{action='info'}
if($device.DeviceName -cne $script:HlConfig.DeviceName -or $device.HostFingerprint -cne $script:HlConfig.ExpectedFingerprint){throw 'Original device identity required'}
if(-not(Test-Path -LiteralPath $record)){
 if(-not $Worker){throw 'First call requires a compiled Worker'}
 [IO.Directory]::CreateDirectory($folder)|Out-Null
 $hash=(Get-FileHash -LiteralPath $Worker).Hash
 $base='U:\Users\DefaultAccount\AppData\Local\DevelopmentFiles\RiceHoloLensFieldV1'
 $remote=$base+'\gpu-probe-'+$hash.Substring(0,12)+'.exe';$output=$base+'\gpu-'+$RunId+'.jsonl'
 if((Invoke-HlBridge @{action='stat';path=$output}).Exists){throw 'Unowned existing report'}
 if(-not(Invoke-HlBridge @{action='stat';path=$remote}).Exists){Invoke-HlBridge @{action='put';local=$Worker;path=$remote}|Out-Null}
 $readback=Join-Path $folder 'worker.exe';Invoke-HlBridge @{action='get';path=$remote;local=$readback}|Out-Null
 if((Get-FileHash -LiteralPath $readback).Hash -cne $hash){throw 'Worker readback mismatch'}
 $invocation=@{RunId=$RunId;Device=$device.DeviceName;Fingerprint=$device.HostFingerprint;Worker=$remote;WorkerSha256=$hash;Seconds=$Seconds;Output=$output;At=[DateTimeOffset]::Now.ToString('o');Attempted=$true;ReplayAllowed=$false}
 $invocation|ConvertTo-Json|Set-Content -LiteralPath $record -Encoding utf8NoBOM
 $launch=Invoke-HlBridge @{action='exec';executable='C:\Windows\System32\DevToolsLauncher.exe';arguments=('LaunchForDebug '+$remote+' "'+$output+' '+$Seconds+'" Rice.HoloLens.Field_r5420n6798s24!Field')}
 $launch|ConvertTo-Json -Depth 4|Set-Content -LiteralPath (Join-Path $folder 'launch.json') -Encoding utf8NoBOM
 if($launch.ExitCode -ne 0){throw 'Launch outcome unknown; query the same RunId'}
 Start-Sleep -Milliseconds 1000
}else{$invocation=Get-Content -Raw -LiteralPath $record|ConvertFrom-Json}
if($invocation.Device -cne $device.DeviceName -or $invocation.Fingerprint -cne $device.HostFingerprint){throw 'Observation identity differs'}
$stat=Invoke-HlBridge @{action='stat';path=$invocation.Output}
if($stat.Exists){$raw=(Invoke-HlBridge @{action='cat';path=$invocation.Output}).Text;[IO.File]::WriteAllText((Join-Path $folder 'samples.jsonl'),$raw,[Text.UTF8Encoding]::new($false));$samples=@($raw -split '\r?\n'|Where-Object {$_}|ForEach-Object {$_|ConvertFrom-Json});@{RunId=$RunId;SampleCount=$samples.Count;Latest=$samples[-1];Evidence=$folder}|ConvertTo-Json -Depth 6 -Compress}else{@{RunId=$RunId;Pending=$true;Evidence=$folder}|ConvertTo-Json -Compress}
