param([ValidateSet('dynamic_start','dynamic_stop','dynamic_asset','yolo_state')][string]$Action='yolo_state',[ValidateSet('','bacterial_blight_0.jpg','brown_spot_0.jpg','rice_blast_0.jpg','rice_water_weevil_0.jpg')][string]$Asset='', [ValidatePattern('^[A-Za-z0-9_-]{1,64}$')][string]$RunId=('yolo-'+[guid]::NewGuid().ToString('N')))
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot;$workspace=Split-Path -Parent (Split-Path -Parent $root)
. (Join-Path $workspace 'usb-terminal/HoloLens.Common.ps1')
$folder=Join-Path $root ('.state/camera-checks/'+$RunId);$record=Join-Path $folder 'invocation.json'
if(Test-Path -LiteralPath $record){Get-Content -LiteralPath $record -Raw;return}
if(($Action -eq 'dynamic_asset') -ne [bool]$Asset){throw 'Asset is required only for dynamic_asset'}
$runtime=& (Join-Path $PSScriptRoot 'Get-AppState.ps1')|ConvertFrom-Json
$state=Get-Content -Raw -LiteralPath (Join-Path $runtime.Evidence 'app-state.json')|ConvertFrom-Json
if(-not $runtime.RuntimeVerified -or -not $state.cameraSession -or $state.version -ne $runtime.Version){throw 'Current CameraDiagnostics build is not verified running'}
$installed=Get-Content -Raw -LiteralPath (Join-Path $root '.state/installed.json')|ConvertFrom-Json
$remote=$installed.RemoteLayout+'\camera-check.json'
if((Invoke-HlBridge @{action='stat';path=$remote}).Exists){throw 'Prior command remains; not overwritten or repeated'}
[IO.Directory]::CreateDirectory($folder)|Out-Null
$requestId=[guid]::NewGuid().ToString('N');$command=@{id=$requestId;session=$state.cameraSession;action=$Action;asset=$Asset}
$commandPath=Join-Path $folder 'command.json';$command|ConvertTo-Json -Compress|Set-Content -LiteralPath $commandPath -Encoding utf8NoBOM
$proof=@{RunId=$RunId;Id=$requestId;Action=$Action;Asset=$Asset;Session=$state.runtimeSession;Version=$runtime.Version;Attempted=$true;Completed=$false;ReplayAllowed=$false;Evidence=$folder}
$proof|ConvertTo-Json|Set-Content -LiteralPath $record -Encoding utf8NoBOM
Invoke-HlBridge @{action='put';local=$commandPath;path=$remote}|Out-Null
$proof|ConvertTo-Json -Compress
