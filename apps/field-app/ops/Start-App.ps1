$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$workspace=Split-Path -Parent (Split-Path -Parent $root)
. (Join-Path $workspace 'usb-terminal/HoloLens.Common.ps1')
$path=Join-Path $root '.state\installed.json'
$installed=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json -AsHashtable
if($installed.Identity -ne 'Rice.HoloLens.Field_r5420n6798s24!Field' -or $installed.RemoteLayout -ne 'U:\Users\DefaultAccount\AppData\Local\DevelopmentFiles\RiceHoloLensFieldV1'){throw 'Unexpected installed application identity.'}
try{
    $installed.NetworkPreflight=(& (Join-Path $PSScriptRoot 'Ensure-Network.ps1')|ConvertFrom-Json)
}catch{
    # Offline access to the app still matters; a network diagnostic failure must
    # not prevent the activation attempt or become a repeated Wi-Fi/IP question.
    $installed.NetworkPreflight=@{NetworkReady=$false;Reason='network_check_unavailable';Error=$_.Exception.Message}
}
$launcher=Join-Path $root '.state\launcher\hl-field-launch.exe'
$hash=(Get-FileHash -LiteralPath $launcher).Hash.Substring(0,8)
$remote=$installed.RemoteLayout+'\hl-field-launch-'+$hash+'.exe'
if(-not (Invoke-HlBridge @{action='stat';path=$remote}).Exists){Invoke-HlBridge @{action='put';local=$launcher;path=$remote}|Out-Null}
$out=$installed.RemoteLayout+'\launch-'+[Guid]::NewGuid().ToString('N')+'.json'
$reply=Invoke-HlBridge @{action='exec';executable='C:\Windows\System32\DevToolsLauncher.exe';arguments=('LaunchForDeploy '+$remote+' "rice-hololens-field://open --activate-app --out '+$out+'"')}
if($reply.ExitCode -ne 0){throw 'Own-app activation helper did not start.'}
$proof=$null
for($i=0;$i -lt 35;$i++){Start-Sleep -Milliseconds 350;$s=Invoke-HlBridge @{action='stat';path=$out};if($s.Exists -and $s.Length -gt 0){$proof=(Invoke-HlBridge @{action='cat';path=$out}).Text|ConvertFrom-Json;break}}
$installed.LaunchEvidence=$out
$installed.ActivationAccepted=$proof -and $proof.launchAccepted -eq $true
$installed.RuntimeVerified=$false
[IO.File]::WriteAllText($path,($installed|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
$runtime=$null
if($installed.ActivationAccepted){for($attempt=0;$attempt -lt 5;$attempt++){& (Join-Path $PSScriptRoot 'Get-AppState.ps1')|Out-Null;$runtime=Get-Content -LiteralPath (Join-Path $root '.state\runtime-status.json') -Raw|ConvertFrom-Json;if($runtime.RuntimeVerified){break};Start-Sleep -Milliseconds 700}}
$installed.RuntimeVerified=[bool]($runtime -and $runtime.RuntimeVerified)
[IO.File]::WriteAllText($path,($installed|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
[ordered]@{ActivationAccepted=$installed.ActivationAccepted;RuntimeVerified=$installed.RuntimeVerified;RuntimeVersion=if($runtime){$runtime.RuntimeVersion}else{$null};User=if($runtime){$runtime.User}elseif($proof){$proof.user}else{$null};Reason=if($proof){$proof.reason}else{'activation_outcome_unknown'};Evidence=$out;RuntimeEvidence=if($runtime){$runtime.Evidence}else{$null}}|ConvertTo-Json -Compress
