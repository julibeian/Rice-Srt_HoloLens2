param([ValidatePattern('^[A-Za-z0-9_-]{1,64}$')][string]$RunId=('holo-view-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[Guid]::NewGuid().ToString('N').Substring(0,6)))
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$workspace=Split-Path -Parent $root
. (Join-Path $workspace 'HoloLens.Common.ps1')
$device=Invoke-HlBridge @{action='info'}
if($device.HostFingerprint -ne $script:HlConfig.ExpectedFingerprint){throw 'HoloLens identity mismatch.'}
$local=Join-Path $root ('.state\mrc\'+$RunId)
[IO.Directory]::CreateDirectory($local)|Out-Null
$invocationPath=Join-Path $local 'invocation.json'
if(Test-Path -LiteralPath $invocationPath){
    $invocation=Get-Content -LiteralPath $invocationPath -Raw|ConvertFrom-Json
    if($invocation.Run -ne $RunId){throw 'Existing capture checkpoint does not match this run.'}
}else{
    $exe=Join-Path $workspace 'capture-app\device-research\bin\arm64\hl-camera-capture.exe'
    $hash=(Get-FileHash -LiteralPath $exe).Hash
    $remote='U:\Users\DefaultAccount\AppData\Local\DevelopmentFiles\RiceHoloLensCaptureV1\hl-camera-capture-'+$hash.Substring(0,8)+'.exe'
    if(-not(Invoke-HlBridge @{action='stat';path=$remote}).Exists){Invoke-HlBridge @{action='put';local=$exe;path=$remote}|Out-Null}
    $report='U:\Users\DefaultAccount\AppData\Local\DevelopmentFiles\RiceHoloLensCaptureV1\'+$RunId+'.json'
    $invocation=[ordered]@{Run=$RunId;RemoteReport=$report;BinaryHash=$hash;CreatedAt=[DateTimeOffset]::Now.ToString('o');LaunchAttempted=$true}
    # Persist before launching. A retry with this RunId only retrieves this attempt.
    [IO.File]::WriteAllText($invocationPath,($invocation|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    $arguments='--capture --mrc --run '+$RunId+' --out '+$report
    $reply=Invoke-HlBridge @{action='exec';executable='C:\Windows\System32\DevToolsLauncher.exe';arguments=('LaunchForDebug '+$remote+' "'+$arguments+'" Rice.HoloLens.Field_r5420n6798s24!Field')}
    if($reply.ExitCode -ne 0){throw 'MRC worker launch failed; this run will not be automatically replayed.'}
}
$result=$null
for($i=0;$i -lt 70;$i++){
    Start-Sleep -Milliseconds 400
    $stat=Invoke-HlBridge @{action='stat';path=$invocation.RemoteReport}
    if($stat.Exists -and $stat.Length -gt 0){$result=(Invoke-HlBridge @{action='cat';path=$invocation.RemoteReport}).Text|ConvertFrom-Json;break}
}
if(-not $result){throw ('MRC result is pending; retrieve the SAME RunId: '+$RunId)}
[IO.File]::WriteAllText((Join-Path $local 'result.json'),($result|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
if(-not $result.photoApiCompleted -or -not $result.cameraClosed -or $result.image_bytes -le 0){throw ('MRC photo unavailable: '+$result.reason)}
$imagePath=Join-Path $local 'photo.jpg'
if(-not(Test-Path -LiteralPath $imagePath)){Invoke-HlBridge @{action='get';path=$result.photoPath;local=$imagePath}|Out-Null}
if((Get-FileHash -LiteralPath $imagePath).Hash -ne $result.image_sha256){throw 'Retrieved image hash differs from the device capture.'}
$proof=[ordered]@{Run=$RunId;Image=$imagePath;ImageBytes=$result.image_bytes;Sha256=$result.image_sha256;MrcEffectApplied=$result.mrcEffectApplied;CameraClosed=$result.cameraClosed;InputVerified=$false;VisibleUiVerified=$false;Evidence=(Join-Path $local 'result.json')}
[IO.File]::WriteAllText((Join-Path $root '.state\latest-mrc.json'),($proof|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
$proof|ConvertTo-Json
