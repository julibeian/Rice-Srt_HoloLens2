param([switch]$HoldActivation)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$workspace=Split-Path -Parent $root
. (Join-Path $workspace 'HoloLens.Common.ps1')
$base='U:\Users\DefaultAccount\AppData\Local\DevelopmentFiles\RiceHoloLensNativeSurface'
$run=Join-Path $root ('.state\native-surface\runs\'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[Guid]::NewGuid().ToString('N').Substring(0,6))
[IO.Directory]::CreateDirectory($run)|Out-Null
$download=Join-Path $run 'NativeSurface.exe'
Invoke-HlBridge @{action='get';path=($base+'\NativeSurface.exe');local=$download}|Out-Null
$hashMatches=(Get-FileHash -LiteralPath $download).Hash -eq (Get-FileHash -LiteralPath (Join-Path $root '.state\native-surface\layout\NativeSurface.exe')).Hash
if(-not $hashMatches){throw 'Deployed native surface binary does not match the local build.'}
$helpers=@{}
foreach($name in 'launch','diagnostic','process'){
 $exe=Join-Path $root ('.state\native-surface\hl-native-'+$name+'.exe')
 $remote=$base+'\hl-native-'+$name+'-'+(Get-FileHash -LiteralPath $exe).Hash.Substring(0,8)+'.exe'
 if(-not(Invoke-HlBridge @{action='stat';path=$remote}).Exists){Invoke-HlBridge @{action='put';local=$exe;path=$remote}|Out-Null}
 $helpers[$name]=$remote
}
$launchReport=$base+'\launch-'+[Guid]::NewGuid().ToString('N')+'.json'
$clock=[Diagnostics.Stopwatch]::StartNew()
$hold=if($HoldActivation){' --hold-60-seconds'}else{''}
Invoke-HlBridge @{action='exec';executable='C:\Windows\System32\DevToolsLauncher.exe';arguments=('LaunchForDeploy '+$helpers.launch+' "rice-hololens-native://open --activate-app'+$hold+' --out '+$launchReport+'"')}|Out-Null
$launch=$null
for($i=0;$i -lt 35;$i++){Start-Sleep -Milliseconds 200;$s=Invoke-HlBridge @{action='stat';path=$launchReport};if($s.Exists -and $s.Length -gt 0){$launch=(Invoke-HlBridge @{action='cat';path=$launchReport}).Text|ConvertFrom-Json;break}}
$observations=@()
foreach($delay in 0,1500,3500){
 if($delay){Start-Sleep -Milliseconds $delay}
 $targetPid=if($launch){[string]$launch.activatedProcessId}else{''}
 $p=(Invoke-HlBridge @{action='exec';executable=$helpers.process;arguments=$targetPid}).Output|ConvertFrom-Json
 $observations+=[pscustomobject]@{ElapsedMs=$clock.ElapsedMilliseconds;Processes=$p.processes;EnumerationComplete=$p.enumeration_complete;SnapshotError=$p.snapshot_error;EnumerationError=$p.enumeration_error;ScannedProcesses=$p.scanned_processes;Target=$p.target}
}
$guiInventory=$null;$guiLaunch=$null
if($launch){
 $processResult=$base+'\processes-'+[Guid]::NewGuid().ToString('N')+'.json'
 $before=Invoke-HlBridge @{action='stat';path=$processResult}
 $guiLaunch=Invoke-HlBridge @{action='exec';executable='C:\Windows\System32\DevToolsLauncher.exe';arguments=('LaunchForDebugAsUser '+$helpers.process+' "'+$launch.activatedProcessId+' --out '+$processResult+'" '+$launch.activatedProcessId)}
 for($i=0;$i -lt 15;$i++){
  Start-Sleep -Milliseconds 150
  $after=Invoke-HlBridge @{action='stat';path=$processResult}
  if($after.Exists -and $after.Length -gt 0 -and (-not $before.Exists -or $after.LastWriteTime -ne $before.LastWriteTime)){$guiInventory=(Invoke-HlBridge @{action='cat';path=$processResult}).Text|ConvertFrom-Json;break}
 }
}
$diagnostic=$base+'\diagnostic-'+[Guid]::NewGuid().ToString('N')+'.json'
Invoke-HlBridge @{action='exec';executable='C:\Windows\System32\DevToolsLauncher.exe';arguments=('LaunchForDebug '+$helpers.diagnostic+' "'+$diagnostic+'" Rice.HoloLens.NativeSurface_r5420n6798s24!Native')}|Out-Null
$copied=$null
for($i=0;$i -lt 20;$i++){Start-Sleep -Milliseconds 200;$s=Invoke-HlBridge @{action='stat';path=$diagnostic};if($s.Exists -and $s.Length -gt 0){$copied=(Invoke-HlBridge @{action='cat';path=$diagnostic}).Text|ConvertFrom-Json;break}}
$state=$null
if($copied){foreach($item in $copied.files){if($item.name -eq 'native-state.json' -and $item.win32Error -eq 0){$state=(Invoke-HlBridge @{action='cat';path=$item.destination}).Text|ConvertFrom-Json}}}
$proof=[ordered]@{At=[DateTimeOffset]::Now.ToString('o');ExecutableHashVerified=$hashMatches;Launch=$launch;Observations=$observations;GuiLaunch=$guiLaunch;GuiInventory=$guiInventory;NativeState=$state;Diagnostic=$copied;RemoteHelpers=$helpers;Run=$run;VisualVerified=$false}
[IO.File]::WriteAllText((Join-Path $run 'runtime.json'),($proof|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $root '.state\native-surface\latest-run.txt'),$run,[Text.UTF8Encoding]::new($false))
$proof|ConvertTo-Json -Depth 8
