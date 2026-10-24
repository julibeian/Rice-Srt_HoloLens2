# Terminate only this application's JavaScript host; preserve all LocalState.
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$workspace=Split-Path -Parent $root
. (Join-Path $workspace 'HoloLens.Common.ps1')
$installed=Get-Content -LiteralPath (Join-Path $root '.state\installed.json') -Raw|ConvertFrom-Json
$base='U:\Users\DefaultAccount\AppData\Local\DevelopmentFiles\RiceHoloLensFieldV1'
if($installed.Identity -ne 'Rice.HoloLens.Field_r5420n6798s24!Field' -or $installed.RemoteLayout -ne $base){throw 'Unexpected app identity or directory.'}
$exe=Join-Path $root '.state\stop-helper\hl-field-stop.exe'
if(-not (Test-Path -LiteralPath $exe)){& (Join-Path $PSScriptRoot 'Build-StopHelper.ps1')|Out-Null}
$hash=(Get-FileHash -LiteralPath $exe).Hash.Substring(0,8)
$remote=$base+'\hl-field-stop-'+$hash+'.exe'
if(-not (Invoke-HlBridge @{action='stat';path=$remote}).Exists){Invoke-HlBridge @{action='put';local=$exe;path=$remote}|Out-Null}
$out=$base+'\stop-result.json'
if((Invoke-HlBridge @{action='stat';path=$out}).Exists){
 $info=Invoke-HlBridge @{action='info'};Import-HlSdk;$client=Connect-HlDevice $info.Address
 try{$client.RemoteDevice.DeleteFile($out)}finally{$client.Disconnect();$client.Dispose()}
}
Invoke-HlBridge @{action='exec';executable='C:\Windows\System32\DevToolsLauncher.exe';arguments=('LaunchForDebug '+$remote+' "stop" '+$installed.Identity)}|Out-Null
$proof=$null
for($i=0;$i -lt 30;$i++){Start-Sleep -Milliseconds 200;$s=Invoke-HlBridge @{action='stat';path=$out};if($s.Exists -and $s.Length -gt 0){$proof=(Invoke-HlBridge @{action='cat';path=$out}).Text|ConvertFrom-Json;break}}
if(-not $proof){throw 'App stop helper produced no result.'}
[IO.File]::WriteAllText((Join-Path $root '.state\last-app-stop.json'),($proof|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
if($proof.error -ne 0){throw ('App host could not be stopped: '+$proof.error)}
$proof|ConvertTo-Json -Compress
