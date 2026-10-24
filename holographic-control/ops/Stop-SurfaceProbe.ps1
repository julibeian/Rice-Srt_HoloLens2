$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$workspace=Split-Path -Parent $root
. (Join-Path $workspace 'HoloLens.Common.ps1')
$base='U:\Users\DefaultAccount\AppData\Local\DevelopmentFiles\RiceHoloLensSurfaceProbe'
$exe=Join-Path $root '.state\surface-probe\hl-surface-stop.exe'
$remote=$base+'\hl-surface-stop-'+(Get-FileHash -LiteralPath $exe).Hash.Substring(0,8)+'.exe'
if(-not(Invoke-HlBridge @{action='stat';path=$remote}).Exists){Invoke-HlBridge @{action='put';local=$exe;path=$remote}|Out-Null}
$path=$base+'\stop-result.json';$before=Invoke-HlBridge @{action='stat';path=$path}
Invoke-HlBridge @{action='exec';executable='C:\Windows\System32\DevToolsLauncher.exe';arguments=('LaunchForDebug '+$remote+' "stop" Rice.HoloLens.SurfaceProbe_r5420n6798s24!Surface')}|Out-Null
$result=$null
for($i=0;$i -lt 20;$i++){Start-Sleep -Milliseconds 150;$s=Invoke-HlBridge @{action='stat';path=$path};if($s.Exists -and $s.Length -gt 0 -and (-not $before.Exists -or $s.LastWriteTime -ne $before.LastWriteTime)){$result=(Invoke-HlBridge @{action='cat';path=$path}).Text|ConvertFrom-Json;break}}
if(-not $result -or $result.package -ne 'Rice.HoloLens.SurfaceProbe_r5420n6798s24' -or $result.error -ne 0 -or $result.matched -ne $result.terminated){throw 'The isolated surface probe stop was not verified.'}
[IO.File]::WriteAllText((Join-Path $root '.state\surface-probe\stop-final.json'),($result|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
$result|ConvertTo-Json
