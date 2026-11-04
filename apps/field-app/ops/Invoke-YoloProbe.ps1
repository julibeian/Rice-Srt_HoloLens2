param([Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_-]{1,64}$')][string]$RunId,[string]$Worker,[string]$Model)
$ErrorActionPreference='Stop'
$appRoot=Split-Path -Parent $PSScriptRoot
$workspace=Split-Path -Parent (Split-Path -Parent $appRoot)
. (Join-Path $workspace 'usb-terminal/HoloLens.Common.ps1')
$folder=Join-Path $appRoot ('.state/yolo-observations/'+$RunId)
$invocationPath=Join-Path $folder 'invocation.json'
$info=Invoke-HlBridge @{action='info'}
if($info.DeviceName -cne $script:HlConfig.DeviceName -or $info.HostFingerprint -cne $script:HlConfig.ExpectedFingerprint){throw 'Original device identity not verified'}
if(Test-Path -LiteralPath $invocationPath){
 $inv=Get-Content -Raw -LiteralPath $invocationPath|ConvertFrom-Json
 if($inv.RunId -cne $RunId -or $inv.Device -cne $info.DeviceName -or $inv.Fingerprint -cne $info.HostFingerprint){throw 'Observation identity mismatch'}
}else{
 if(-not $Worker -or -not $Model){throw 'Initial invocation needs Worker and Model'}
 $workerHash=(Get-FileHash -LiteralPath $Worker).Hash;$modelHash=(Get-FileHash -LiteralPath $Model).Hash
 $base='U:\Users\DefaultAccount\AppData\Local\DevelopmentFiles\RiceHoloLensFieldV1'
 $remoteWorker=$base+'\yolo-probe-'+$workerHash.Substring(0,12)+'.exe'
 $remoteModel=$base+'\yolo-model-'+$modelHash.Substring(0,12)+'.onnx'
 if(-not(Invoke-HlBridge @{action='stat';path=$remoteWorker}).Exists){Invoke-HlBridge @{action='put';local=$Worker;path=$remoteWorker}|Out-Null}
 if(-not(Invoke-HlBridge @{action='stat';path=$remoteModel}).Exists){Invoke-HlBridge @{action='put';local=$Model;path=$remoteModel}|Out-Null}
 [IO.Directory]::CreateDirectory($folder)|Out-Null
 $roundtrip=Join-Path $folder 'deployed-model.onnx';Invoke-HlBridge @{action='get';path=$remoteModel;local=$roundtrip}|Out-Null
 if((Get-FileHash -LiteralPath $roundtrip).Hash -cne $modelHash){throw 'Device model readback hash mismatch'}
 $out=$base+'\'+$RunId+'.json'
 if((Invoke-HlBridge @{action='stat';path=$out}).Exists){throw 'Existing unowned report'}
 $inv=@{RunId=$RunId;Device=$info.DeviceName;Fingerprint=$info.HostFingerprint;Worker=$remoteWorker;WorkerSha256=$workerHash;Model=$remoteModel;ModelSha256=$modelHash;RemoteReport=$out;At=[DateTimeOffset]::Now.ToString('o');LaunchAttempted=$true}
 $inv|ConvertTo-Json|Set-Content -LiteralPath $invocationPath -Encoding utf8
 $launch=Invoke-HlBridge @{action='exec';executable='C:\Windows\System32\DevToolsLauncher.exe';arguments=('LaunchForDebug '+$remoteWorker+' "'+$remoteModel+' '+$out+'" Rice.HoloLens.Field_r5420n6798s24!Field')}
 $launch|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $folder 'launch.json') -Encoding utf8
 if($launch.ExitCode -ne 0){throw 'Probe launch outcome unknown; query SAME RunId'}
}
$watch=[Diagnostics.Stopwatch]::StartNew()
do{
 $stat=Invoke-HlBridge @{action='stat';path=$inv.RemoteReport}
 if($stat.Exists -and $stat.Length -gt 0){$value=(Invoke-HlBridge @{action='cat';path=$inv.RemoteReport}).Text|ConvertFrom-Json;$value|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $folder 'result.json') -Encoding utf8;@{RunId=$RunId;Result=$value;ModelSha256=$inv.ModelSha256;Evidence=$folder}|ConvertTo-Json -Depth 6 -Compress;return}
 Start-Sleep -Milliseconds 300
}while($watch.ElapsedMilliseconds -lt 25000)
@{RunId=$RunId;Pending=$true;ReplayAllowed=$false;Evidence=$folder}|ConvertTo-Json -Compress
