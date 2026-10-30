$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$workspace=Split-Path -Parent (Split-Path -Parent $root)
. (Join-Path $workspace 'usb-terminal/HoloLens.Common.ps1')
$base='U:\Users\DefaultAccount\AppData\Local\DevelopmentFiles\RiceHoloLensSurfaceProbe'
$exe=Join-Path $root '.state\surface-probe\hl-surface-diagnostic.exe'
$remote=$base+'\hl-surface-diagnostic-'+(Get-FileHash -LiteralPath $exe).Hash.Substring(0,8)+'.exe'
if(-not(Invoke-HlBridge @{action='stat';path=$remote}).Exists){Invoke-HlBridge @{action='put';local=$exe;path=$remote}|Out-Null}
$out=$base+'\surface-diagnostic-'+[Guid]::NewGuid().ToString('N')+'.json'
Invoke-HlBridge @{action='exec';executable='C:\Windows\System32\DevToolsLauncher.exe';arguments=('LaunchForDebug '+$remote+' "'+$out+'" Rice.HoloLens.SurfaceProbe_r5420n6798s24!Surface')}|Out-Null
$copied=$null
for($i=0;$i -lt 20;$i++){Start-Sleep -Milliseconds 150;$s=Invoke-HlBridge @{action='stat';path=$out};if($s.Exists -and $s.Length -gt 0){$copied=(Invoke-HlBridge @{action='cat';path=$out}).Text|ConvertFrom-Json;break}}
if(-not $copied){throw 'Surface diagnostic did not produce a result.'}
$state=$null
foreach($item in $copied.files){if($item.name -eq 'surface-state.json' -and $item.win32Error -eq 0){$state=(Invoke-HlBridge @{action='cat';path=$item.destination}).Text|ConvertFrom-Json}}
$proof=[ordered]@{At=[DateTimeOffset]::Now.ToString('o');State=$state;Diagnostic=$copied;VisualVerified=$false}
$folder=Join-Path $root '.state\surface-probe\runs'
[IO.Directory]::CreateDirectory($folder)|Out-Null
$path=Join-Path $folder ('state-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[Guid]::NewGuid().ToString('N').Substring(0,6)+'.json')
[IO.File]::WriteAllText($path,($proof|ConvertTo-Json -Depth 7),[Text.UTF8Encoding]::new($false))
$proof|ConvertTo-Json -Depth 7
