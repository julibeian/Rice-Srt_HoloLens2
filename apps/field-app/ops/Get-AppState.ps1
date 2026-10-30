$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$workspace=Split-Path -Parent (Split-Path -Parent $root)
. (Join-Path $workspace 'usb-terminal/HoloLens.Common.ps1')
$installed=Get-Content -LiteralPath (Join-Path $root '.state\installed.json') -Raw|ConvertFrom-Json
$exe=Join-Path $root '.state\diagnostic\hl-field-diagnostic.exe'
$hash=(Get-FileHash -LiteralPath $exe).Hash.Substring(0,8)
$remote=$installed.RemoteLayout+'\hl-field-diagnostic-'+$hash+'.exe'
if(-not (Invoke-HlBridge @{action='stat';path=$remote}).Exists){Invoke-HlBridge @{action='put';local=$exe;path=$remote}|Out-Null}
$run='diagnostic-'+[Guid]::NewGuid().ToString('N')
$out=$installed.RemoteLayout+'\'+$run+'.json'
Invoke-HlBridge @{action='exec';executable='C:\Windows\System32\DevToolsLauncher.exe';arguments=('LaunchForDebug '+$remote+' "'+$out+'" '+$installed.Identity)}|Out-Null
$result=$null
for($i=0;$i -lt 25;$i++){Start-Sleep -Milliseconds 300;$s=Invoke-HlBridge @{action='stat';path=$out};if($s.Exists -and $s.Length -gt 0){$result=(Invoke-HlBridge @{action='cat';path=$out}).Text|ConvertFrom-Json;break}}
if(-not $result){throw 'Diagnostic helper produced no result.'}
$folder=Join-Path $root ('.state\diagnostics\'+$run)
[IO.Directory]::CreateDirectory($folder)|Out-Null
[IO.File]::WriteAllText((Join-Path $folder 'diagnostic.json'),($result|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
$state=$null;$bootError=$null
foreach($file in $result.files){
 if($file.win32Error -ne 0){continue}
 $value=(Invoke-HlBridge @{action='cat';path=$file.destination}).Text
 [IO.File]::WriteAllText((Join-Path $folder $file.name),$value,[Text.UTF8Encoding]::new($false))
 if($file.name -eq 'app-state.json'){$state=$value|ConvertFrom-Json}
 if($file.name -eq 'boot-error.json'){$bootError=$value|ConvertFrom-Json}
}
$currentEvents=if($state){@($state.events)}else{@()}
if($state -and $state.PSObject.Properties['runtimeSession'] -and $state.runtimeSession){$currentEvents=@($currentEvents|Where-Object {$_.PSObject.Properties['session'] -and $_.session -eq $state.runtimeSession})}
$phases=@($currentEvents|ForEach-Object{$_.event})
$runtimeEvents=@('app_ready','page_opened','view_opened','camera_preview_started','photo_captured','prediction_received','report_exported')
$runtimeSeen=@($phases|Where-Object{$_ -in $runtimeEvents}).Count -gt 0
$readyEvent=@($currentEvents|Where-Object{$_.event -eq 'app_ready'})|Select-Object -Last 1
$runtimeVersion=if($readyEvent -and $readyEvent.details.PSObject.Properties['version']){$readyEvent.details.version}else{$null}
if(-not $runtimeVersion -and $state -and $state.PSObject.Properties['version']){$runtimeVersion=$state.version}
$processes=@();$processError=$null
try{$inventory=Invoke-HlBridge @{action='exec';executable='C:\Windows\System32\DevToolsLauncher.exe';arguments='GetRunningStoreApps'};if($inventory.ExitCode -ne 0){throw 'Running app inventory failed.'};$processes=@(($inventory.Output|ConvertFrom-Json)|Where-Object{$_.aumid -eq $installed.Identity -and $_.isAppProcess -eq $true})}catch{$processError=$_.Exception.Message}
if($processError){
    try{
        $probe=Join-Path $root '.state\process-probe\hl-field-process.exe'
        $probeRemote=$installed.RemoteLayout+'\hl-field-process-'+(Get-FileHash -LiteralPath $probe).Hash.Substring(0,8)+'.exe'
        if(-not(Invoke-HlBridge @{action='stat';path=$probeRemote}).Exists){Invoke-HlBridge @{action='put';local=$probe;path=$probeRemote}|Out-Null}
        $probeResult=$installed.RemoteLayout+'\processes-'+[Guid]::NewGuid().ToString('N')+'.json'
        $before=Invoke-HlBridge @{action='stat';path=$probeResult}
        $launchProbe=Invoke-HlBridge @{action='exec';executable='C:\Windows\System32\DevToolsLauncher.exe';arguments=('LaunchForDebug '+$probeRemote+' "0 --out '+$probeResult+'" '+$installed.Identity)}
        if($launchProbe.ExitCode -ne 0){throw 'Native process probe could not start.'}
        $fresh=$false
        for($attempt=0;$attempt -lt 15;$attempt++){Start-Sleep -Milliseconds 150;$after=Invoke-HlBridge @{action='stat';path=$probeResult};if($after.Exists -and $after.Length -gt 0 -and (-not $before.Exists -or $after.LastWriteTime -ne $before.LastWriteTime)){$fresh=$true;break}}
        if(-not $fresh){throw 'Native process probe did not produce a fresh result.'}
        $nativeInventory=(Invoke-HlBridge @{action='cat';path=$probeResult}).Text|ConvertFrom-Json
        if(-not $nativeInventory.PSObject.Properties['enumeration_complete'] -or -not $nativeInventory.enumeration_complete){
            throw ('Native process enumeration is unavailable or incomplete; do not interpret its list as a stopped app. Snapshot error='+$nativeInventory.snapshot_error+'; enumeration error='+$nativeInventory.enumeration_error)
        }
        $family=$installed.Identity.Split('!')[0]
        $processes=@($nativeInventory.processes|Where-Object{$_.package -eq $family -and $_.name -ieq 'WWAHost.exe'})
        $unidentifiedHosts=@($nativeInventory.processes|Where-Object{$_.name -ieq 'WWAHost.exe' -and -not $_.package})
        if($processes.Count -eq 0 -and $unidentifiedHosts.Count -gt 0){throw 'WWAHost is present but its package identity cannot be read; application running state is unverified.'}
        $processError=$null
    }catch{$processError=$_.Exception.Message}
}
$ready=if($state -and $state.PSObject.Properties['appReady']){[bool]$state.appReady}else{$runtimeSeen}
$proof=[ordered]@{At=[DateTimeOffset]::Now.ToString('o');User=$result.user;Version=$installed.Version;RuntimeVersion=$runtimeVersion;RuntimeVerified=($ready -and $runtimeVersion -eq $installed.Version -and $state.phase -ne 'boot_failed' -and $processes.Count -gt 0);RuntimeSession=if($state -and $state.PSObject.Properties['runtimeSession']){$state.runtimeSession}else{$null};CameraPreviewReady=if($state -and $state.PSObject.Properties['cameraPreviewReady']){[bool]$state.cameraPreviewReady}else{$false};RunningProcesses=@($processes|ForEach-Object{$_.pid});ProcessError=$processError;Phase=if($state){$state.phase}else{'no_runtime_evidence'};BootError=$bootError;Events=@($phases);Evidence=$folder}
$proof.RunningState=if($processes.Count -gt 0){'verified_running'}elseif($processError){'unknown'}else{'not_observed'}
$pairPath=$installed.RemoteLayout+'\pairing.json'
if($installed.RemoteLayout -eq 'U:\Users\DefaultAccount\AppData\Local\DevelopmentFiles\RiceHoloLensFieldV1' -and (Invoke-HlBridge @{action='stat';path=$pairPath}).Exists){
 $temporaryPair=(Invoke-HlBridge @{action='cat';path=$pairPath}).Text|ConvertFrom-Json
 if([double]$temporaryPair.expires_epoch -le [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() -or $phases -contains 'device_paired'){
  $info=Invoke-HlBridge @{action='info'};Import-HlSdk;$client=Connect-HlDevice $info.Address
  try{$client.RemoteDevice.DeleteFile($pairPath)}finally{$client.Disconnect();$client.Dispose()}
  $proof.ExpiredOrUsedPairingFileRemoved=$true
 }
 $temporaryPair=$null
}
[IO.File]::WriteAllText((Join-Path $root '.state\runtime-status.json'),($proof|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
$proof|ConvertTo-Json -Depth 8 -Compress
