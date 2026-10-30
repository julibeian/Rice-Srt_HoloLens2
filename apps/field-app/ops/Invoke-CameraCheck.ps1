param([ValidateSet('controls','capture')][string]$Action='controls',[ValidateRange(0,1)][double]$TargetX=0.5,[ValidateRange(0,1)][double]$TargetY=0.46)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$workspace=Split-Path -Parent (Split-Path -Parent $root)
. (Join-Path $workspace 'usb-terminal/HoloLens.Common.ps1')
& (Join-Path $PSScriptRoot 'Get-AppState.ps1')|Out-Null
$runtime=Get-Content -LiteralPath (Join-Path $root '.state\runtime-status.json') -Raw|ConvertFrom-Json
$state=Get-Content -LiteralPath (Join-Path $runtime.Evidence 'app-state.json') -Raw|ConvertFrom-Json
if(-not $state.cameraSession -or $state.version -ne $runtime.Version){throw 'A current CameraDiagnostics build must be running.'}
$requestId=[Guid]::NewGuid().ToString('N')
$folder=Join-Path $root '.state\camera-checks'
[IO.Directory]::CreateDirectory($folder)|Out-Null
$path=Join-Path $folder ($requestId+'.json')
$command=[ordered]@{id=$requestId;session=$state.cameraSession;action=$Action;target=@{x=$TargetX;y=$TargetY}}
[IO.File]::WriteAllText($path,($command|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
$installed=Get-Content -LiteralPath (Join-Path $root '.state\installed.json') -Raw|ConvertFrom-Json
$remote=$installed.RemoteLayout+'\camera-check.json'
if((Invoke-HlBridge @{action='stat';path=$remote}).Exists){throw 'A previous camera check has not been consumed; it was not overwritten or repeated.'}
Invoke-HlBridge @{action='put';local=$path;path=$remote}|Out-Null
[ordered]@{Id=$requestId;Action=$Action;Version=$runtime.Version;Submitted=$true;Completed=$false;Evidence=$path}|ConvertTo-Json -Compress
