param([ValidatePattern('^[A-Za-z0-9_-]{1,64}$')][string]$RunId=('yolo-verify-'+(Get-Date -Format 'yyyyMMdd-HHmmss')))
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$workspace=Split-Path -Parent (Split-Path -Parent $root)
. (Join-Path $workspace 'usb-terminal/HoloLens.Common.ps1')
$folder=Join-Path $root ('.state/yolo-deployment-checks/'+$RunId)
$resultPath=Join-Path $folder 'result.json'
if(Test-Path -LiteralPath $resultPath){Get-Content -LiteralPath $resultPath -Raw;return}
$installed=Get-Content -LiteralPath (Join-Path $root '.state/installed.json') -Raw|ConvertFrom-Json
$packageDirectory=[IO.File]::ReadAllText((Join-Path $root '.state/current-package.txt')).Trim()
$package=Get-Content -LiteralPath (Join-Path $packageDirectory 'package-evidence.json') -Raw|ConvertFrom-Json
if($installed.Identity -cne 'Rice.HoloLens.Field_r5420n6798s24!Field' -or $installed.RemoteLayout -cne 'U:\Users\DefaultAccount\AppData\Local\DevelopmentFiles\RiceHoloLensFieldV1' -or $installed.Version -cne $package.Version){throw 'Unexpected installed identity or build'}
$device=Invoke-HlBridge @{action='info'}
if($device.DeviceName -cne $script:HlConfig.DeviceName -or $device.HostFingerprint -cne $script:HlConfig.ExpectedFingerprint){throw 'Unexpected device identity'}
[IO.Directory]::CreateDirectory($folder)|Out-Null
$names=@('AppxManifest.xml','config.json','model.onnx','model-manifest.json','Rice.HoloLens.Yolo.dll','Rice.HoloLens.Yolo.winmd',$package.EntryPage)+@($package.ScriptFiles|ForEach-Object{$_.Deployed})
$files=@()
foreach($name in $names){
 $expected=(Get-FileHash -LiteralPath (Join-Path $package.Layout $name)).Hash
 $local=Join-Path $folder $name
 if(-not(Test-Path -LiteralPath $local)){Invoke-HlBridge @{action='get';path=($installed.RemoteLayout+'\'+$name);local=$local}|Out-Null}
 $actual=(Get-FileHash -LiteralPath $local).Hash
 if($actual -cne $expected){throw ('Deployed file hash mismatch: '+$name)}
 $files+=@{Name=$name;Sha256=$actual;MatchesBuild=$true}
}
$config=Get-Content -LiteralPath (Join-Path $folder 'config.json') -Raw|ConvertFrom-Json
$manifest=[xml](Get-Content -LiteralPath (Join-Path $folder 'AppxManifest.xml') -Raw)
$capabilities=@($manifest.Package.Capabilities.ChildNodes|Where-Object{$_.NodeType -eq 'Element'}|ForEach-Object{$_.GetAttribute('Name')})
$html=Get-Content -LiteralPath (Join-Path $folder $package.EntryPage) -Raw
if($config.cameraDiagnostics -ne $false -or $config.recognitionMode -cne 'local-yolo' -or $config.yoloSha256 -cne $package.ModelSha256 -or ($capabilities -join ',') -cne 'webcam' -or -not $html.Contains("connect-src 'none'")){throw 'Unexpected production network, diagnostics or model configuration'}
$runtime=& (Join-Path $PSScriptRoot 'Get-AppState.ps1')|ConvertFrom-Json
$state=Get-Content -LiteralPath (Join-Path $runtime.Evidence 'app-state.json') -Raw|ConvertFrom-Json
$native=$state.nativeDetector
if(-not $runtime.RuntimeVerified -or $state.cameraSession -or -not $state.cameraPreviewReady -or $native.phase -cne 'running' -or -not $native.modelLoaded -or -not $native.onDevice -or $native.modelSha256 -cne $package.ModelSha256 -or $native.inputSize -ne $package.InputSize -or $native.processId -notin $runtime.RunningProcesses -or $native.cameraFrames -lt 30 -or $native.source -cne 'camera' -or $native.hr -ne 0){throw 'Final production runtime or continuous-frame evidence not satisfied'}
Copy-Item -LiteralPath (Join-Path $runtime.Evidence 'app-state.json') -Destination (Join-Path $folder 'app-state.json')
$proof=[ordered]@{At=[DateTimeOffset]::Now.ToString('o');Device=$device.DeviceName;Version=$installed.Version;Identity=$installed.Identity;RuntimeSession=$state.runtimeSession;ProcessId=$native.processId;ModelSha256=$native.modelSha256;InputSize=$native.inputSize;CameraFrames=$native.cameraFrames;CameraDiagnosticSession=$state.cameraSession;RecognitionMode=$config.recognitionMode;Capabilities=$capabilities;NetworkCapability=$false;CspConnectNone=$true;VerifiedFiles=$files;RuntimeEvidence=$runtime.Evidence;Evidence=$folder;Passed=$true;NetworkTest='Running production app requests only webcam; no network capability and connect-src none. Device-wide network was not disabled.'}
[IO.File]::WriteAllText($resultPath,($proof|ConvertTo-Json -Depth 7),[Text.UTF8Encoding]::new($false))
$proof|ConvertTo-Json -Depth 7 -Compress
