param(
 [ValidateSet('Inspect','Presence','Home')][string]$Mode='Inspect',
 [ValidatePattern('^[A-Za-z0-9_-]{1,64}$')][string]$RunId=('local-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[Guid]::NewGuid().ToString('N').Substring(0,6))
)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$workspace=Split-Path -Parent (Split-Path -Parent $root)
. (Join-Path $workspace 'usb-terminal/HoloLens.Common.ps1')
$folder=Join-Path $root ('.state\local-tests\'+$RunId)
[IO.Directory]::CreateDirectory($folder)|Out-Null
$checkpoint=Join-Path $folder 'invocation.json'
$base='U:\Users\DefaultAccount\AppData\Local\DevelopmentFiles\RiceHoloLensFieldV1'
if(Test-Path -LiteralPath $checkpoint){
 $invocation=Get-Content -LiteralPath $checkpoint -Raw|ConvertFrom-Json
 if($invocation.Mode -ne $Mode -or $invocation.RunId -ne $RunId){throw 'The existing test checkpoint has another mode or run identity.'}
}else{
 $device=Invoke-HlBridge @{action='info'}
 if($device.DeviceName -ne $script:HlConfig.DeviceName -or $device.HostFingerprint -ne $script:HlConfig.ExpectedFingerprint){throw 'The current USB peer does not match the saved HoloLens identity.'}
 & (Join-Path $PSScriptRoot 'Build-Probe.ps1') -Probe local-simulation|Out-Null
 $exe=Join-Path $root '.state\probe\arm64\hl-local-simulation-probe.exe'
 $hash=(Get-FileHash -LiteralPath $exe).Hash
 $remote=$base+'\hl-local-simulation-'+$hash.Substring(0,16)+'.exe'
 if(-not(Invoke-HlBridge @{action='stat';path=$remote}).Exists){Invoke-HlBridge @{action='put';local=$exe;path=$remote}|Out-Null}
 $copy=Join-Path $folder 'worker.exe'
 Invoke-HlBridge @{action='get';path=$remote;local=$copy}|Out-Null
 if((Get-FileHash -LiteralPath $copy).Hash -ne $hash){throw 'The remote test worker does not match the local binary.'}
 $out=$base+'\'+$RunId+'.json'
 if((Invoke-HlBridge @{action='stat';path=$out}).Exists){throw 'A report with this run identity already exists on the device.'}
 $invocation=[ordered]@{RunId=$RunId;Mode=$Mode;RemoteWorker=$remote;WorkerSha256=$hash;RemoteReport=$out;CreatedAt=[DateTimeOffset]::Now.ToString('o');LaunchAttempted=$true;DeviceName=$device.DeviceName;SshFingerprint=$device.HostFingerprint}
 # A repeated RunId only retrieves the first launch; an observation timeout never
 # starts the worker or repeats the Home gesture again.
 [IO.File]::WriteAllText($checkpoint,($invocation|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
 $action=if($Mode -eq 'Home'){'--home-test '}elseif($Mode -eq 'Presence'){'--presence-test '}else{''}
 $launch=Invoke-HlBridge @{action='exec';executable='C:\Windows\System32\DevToolsLauncher.exe';arguments=('LaunchForDebug '+$remote+' "'+$action+'--out '+$out+'" Rice.HoloLens.Field_r5420n6798s24!Field')}
 [IO.File]::WriteAllText((Join-Path $folder 'launch.json'),($launch|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
 if($launch.ExitCode -ne 0){throw ('The worker launch failed. Inspect this run without replaying it: '+$RunId)}
}
$clock=[Diagnostics.Stopwatch]::StartNew();$result=$null;$activeSaved=$false
while($clock.ElapsedMilliseconds -lt 45000){
 $stat=Invoke-HlBridge @{action='stat';path=$invocation.RemoteReport}
 if($stat.Exists -and $stat.Length -gt 0){
  $result=(Invoke-HlBridge @{action='cat';path=$invocation.RemoteReport}).Text|ConvertFrom-Json
  if($result.phase -eq 'lease_active' -and -not $activeSaved){[IO.File]::WriteAllText((Join-Path $folder 'active.json'),($result|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false));$activeSaved=$true}
  if($result.phase -in @('finished','inspect_only_no_stream')){break}
 }
 Start-Sleep -Milliseconds 350
}
$terminal=$result -and $result.phase -in @('finished','inspect_only_no_stream')
$unchanged=$result -and $result.setControlMode -eq '0x8000000A' -and $result.currentControlMode -eq $result.previousControlMode
$restored=if($Mode -eq 'Inspect' -or $unchanged){$true}else{$terminal -and $result.restoreControlMode -eq '0x00000000' -and $result.currentControlMode -eq $result.previousControlMode -and $result.restorePresence -eq '0x00000000' -and ($Mode -ne 'Home' -or -not $result.previousExecutionState -or $result.restoreExecutionState -ne 0)}
$accepted=$result -and $result.localCom -eq '0x00000000' -and ($Mode -eq 'Inspect' -or ($result.createControlStream -eq '0x00000000' -and $result.setPresence -eq '0x00000000'))
$proof=[ordered]@{RunId=$RunId;Mode=$Mode;At=[DateTimeOffset]::Now.ToString('o');Terminal=[bool]$terminal;ApiAccepted=[bool]$accepted;Restored=[bool]$restored;Report=$result;VisualVerified=$false;Evidence=$folder;ReplaySafe=$true;Scope='Public local COM stream under the existing app user; API acceptance only. No portal authentication or visible UI success is claimed.'}
[IO.File]::WriteAllText((Join-Path $folder 'result.json'),($proof|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
if(-not $terminal){throw ('This observation is pending; inspect the SAME RunId without replaying it: '+$RunId)}
if(-not $restored){throw ('This test did not verify restoration; inspect '+(Join-Path $folder 'result.json'))}
$proof|ConvertTo-Json -Depth 8
