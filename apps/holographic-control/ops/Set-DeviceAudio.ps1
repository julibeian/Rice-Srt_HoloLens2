param([ValidateSet('Inspect','Mute')][string]$Mode='Inspect',[Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_-]{1,64}$')][string]$RunId)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot;$workspace=Split-Path -Parent (Split-Path -Parent $root)
. (Join-Path $workspace 'usb-terminal/HoloLens.Common.ps1')
$folder=Join-Path $workspace ('reports\phase2-full-control\'+$RunId)
[IO.Directory]::CreateDirectory($folder)|Out-Null
$invocationPath=Join-Path $folder 'audio-invocation.json'
$base='U:\Users\DefaultAccount\AppData\Local\DevelopmentFiles\RiceHoloLensFieldV1'
$device=Invoke-HlBridge @{action='info'}
if($device.DeviceName -cne $script:HlConfig.DeviceName -or $device.HostFingerprint -cne $script:HlConfig.ExpectedFingerprint){throw 'Unexpected device identity.'}
if(Test-Path -LiteralPath $invocationPath){$invocation=Get-Content -LiteralPath $invocationPath -Raw|ConvertFrom-Json;if($invocation.mode -cne $Mode){throw 'Existing audio run has a different mode.'}}
else{
 & (Join-Path $PSScriptRoot 'Build-Probe.ps1') -Probe audio|Out-Null
 $local=Join-Path $root '.state\probe\arm64\hl-audio-probe.exe';$hash=(Get-FileHash -LiteralPath $local).Hash;$remote=$base+'\hl-audio-'+$hash.Substring(0,16)+'.exe'
 if(-not(Invoke-HlBridge @{action='stat';path=$remote}).Exists){Invoke-HlBridge @{action='put';local=$local;path=$remote}|Out-Null}
 $download=Join-Path $folder 'worker.exe';Invoke-HlBridge @{action='get';path=$remote;local=$download}|Out-Null
 if((Get-FileHash -LiteralPath $download).Hash -cne $hash){throw 'Remote audio helper hash mismatch.'}
 $out=$base+'\'+$RunId+'.json';if((Invoke-HlBridge @{action='stat';path=$out}).Exists){throw 'Audio operation already exists on device.'}
 $invocation=@{mode=$Mode;run_id=$RunId;at=[DateTimeOffset]::Now.ToString('o');device=$device.DeviceName;fingerprint=$device.HostFingerprint;remote_report=$out;worker_sha256=$hash;replay_allowed=$false}
 [IO.File]::WriteAllText($invocationPath,($invocation|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
 $argument=if($Mode -eq 'Mute'){'--mute '}else{''}
 $launch=Invoke-HlBridge @{action='exec';executable='C:\Windows\System32\DevToolsLauncher.exe';arguments=('LaunchForDebug '+$remote+' "'+$argument+'--out '+$out+'" Rice.HoloLens.Field_r5420n6798s24!Field')}
 [IO.File]::WriteAllText((Join-Path $folder 'audio-launch.json'),($launch|ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
}
$result=$null
for($i=0;$i -lt 30;$i++){$stat=Invoke-HlBridge @{action='stat';path=$invocation.remote_report};if($stat.Exists -and $stat.Length -gt 0){$result=(Invoke-HlBridge @{action='cat';path=$invocation.remote_report}).Text|ConvertFrom-Json;break};Start-Sleep -Milliseconds 200}
if(-not $result){throw 'Audio result pending; inspect this same run without replay.'}
$proof=@{mode=$Mode;run_id=$RunId;observed_at=[DateTimeOffset]::Now.ToString('o');device=$device.DeviceName;result=$result;playback_only=$true;microphone_changed=$false;muted_verified=[bool]$result.allPlaybackRolesSilent}
[IO.File]::WriteAllText((Join-Path $folder 'audio-result.json'),($proof|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
$proof|ConvertTo-Json -Depth 8
if($Mode -eq 'Mute' -and -not $proof.muted_verified){throw 'Playback silence was not verified; inspect this same run.'}
