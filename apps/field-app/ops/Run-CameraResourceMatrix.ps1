param(
    [ValidatePattern('^[A-Za-z0-9_-]{1,40}$')][string]$RunId='matrix-20261105',
    [ValidateRange(30,600)][int]$Seconds=120,
    [ValidateRange(10,120)][int]$WarmupSeconds=20
)
$ErrorActionPreference='Stop'
$appRoot=Split-Path -Parent $PSScriptRoot
$workspace=Split-Path -Parent (Split-Path -Parent $appRoot)
. (Join-Path $workspace 'usb-terminal/HoloLens.Common.ps1')
$reportRoot=Join-Path $workspace 'reports/20261105-yolo-camera-resources'
$planPath=Join-Path $reportRoot ($RunId+'-plan.json')
$statusPath=Join-Path $reportRoot ($RunId+'-status.json')
if(Test-Path -LiteralPath $planPath){throw 'A matrix plan with this RunId already exists. Inspect its original process and observations before continuing.'}
$control=Get-Content -LiteralPath (Join-Path $reportRoot 'raw/instrumented-default-control/run.json') -Raw|ConvertFrom-Json
if($control.status -cne 'recorded' -or $control.completed_rounds -ne 3){throw 'The three instrumentation-control rounds must finish before changing any camera setting'}
$utf8=[Text.UTF8Encoding]::new($false)
$sizes=@(@(896,504),@(1280,720),@(1504,846),@(1920,1080),@(2284,1284))
$configurations=@(foreach($size in $sizes){foreach($rate in @(15,30)){[ordered]@{width=$size[0];height=$size[1];fps=$rate;key=('{0}x{1}@{2}' -f $size[0],$size[1],$rate)}}})
$capability=Get-Content -LiteralPath (Join-Path $reportRoot 'configurations/instrumented-default/capabilities.json') -Raw|ConvertFrom-Json
foreach($configuration in $configurations){if($configuration.key -notin @($capability.profiles.previews.key)){throw ('Requested matrix format is not advertised: '+$configuration.key)}}
$plan=[ordered]@{schema=1;run_id=$RunId;created_at=[DateTimeOffset]::Now.ToString('o');pid=$PID;seconds=$Seconds;warmup_seconds=$WarmupSeconds;repetitions=3;configurations=$configurations;orders=@(@(0..9),@(9..0),@(0..9));order_rationale='Ascending first and third passes, descending second pass to expose time/thermal/order effects. Same 20s warmup and 120s measurement per trial.';selection='Five separated pixel levels including original and maximum advertised preview; both advertised frame rates. Nearby alternative widths 1522,1952,2272 remain in capability inventory.';camera_change_method='Exact package startup settings applied to the physical PV camera; new process and fresh camera frames verified before every trial';camera_diagnostics=$false;resource_telemetry=$true;model_input=320;model_sha256='e6b6d2f6baaae3b7970f1a4e425f2c2347a90fe6aab34c3da0aed738fcf1b048';native_dll_sha256='6d9e91e1bc27244e406f858c6f1498400f61a606a2923d00a113fffecb4d04ff'}
[IO.File]::WriteAllText($planPath,($plan|ConvertTo-Json -Depth 10),$utf8)
$baselinePackage=Get-Content -LiteralPath (Join-Path $reportRoot 'baseline/original-package.json') -Raw|ConvertFrom-Json
$status=[ordered]@{schema=1;run_id=$RunId;status='running';pid=$PID;started_at=[DateTimeOffset]::Now.ToString('o');completed_trials=0;trials=@();method='Start each trial with an exact on-device camera capture configuration; diagnostics/assets disabled; original model/native DLL reused'}
function Save-Status {$status.updated_at=[DateTimeOffset]::Now.ToString('o');[IO.File]::WriteAllText($statusPath,($status|ConvertTo-Json -Depth 10),$utf8)}
Save-Status
try{
    for($pass=1;$pass -le 3;$pass++){
        foreach($configurationIndex in $plan.orders[$pass-1]){
            $configuration=$configurations[$configurationIndex]
            $trialId=('{0}-p{1}-c{2:D2}-{3}x{4}-{5}' -f $RunId,$pass,($configurationIndex+1),$configuration.width,$configuration.height,$configuration.fps)
            $status.current_trial=$trialId;$status.current_configuration=$configuration.key;Save-Status
            Write-Output ('Applying '+$trialId+' : '+$configuration.key)
            $trialEvidence=Join-Path $reportRoot ('packages/'+$trialId)
            [IO.Directory]::CreateDirectory($trialEvidence)|Out-Null
            $buildOutput=@(& (Join-Path $PSScriptRoot 'Build-App.ps1') -Version '1.0.0.48' -InputSize 320 -NativePackageDirectory $baselinePackage.original_package_directory -ResourceTelemetry -CameraWidth $configuration.width -CameraHeight $configuration.height -CameraFps $configuration.fps)
            [IO.File]::WriteAllText((Join-Path $trialEvidence 'build.txt'),($buildOutput -join [Environment]::NewLine),$utf8)
            $packageDirectory=[IO.File]::ReadAllText((Join-Path $appRoot '.state/current-package.txt')).Trim()
            $packageRecord=Get-Content -LiteralPath (Join-Path $packageDirectory 'package-evidence.json') -Raw|ConvertFrom-Json
            if($packageRecord.NativeDllSha256.ToLowerInvariant() -cne $plan.native_dll_sha256 -or $packageRecord.ModelSha256 -cne $plan.model_sha256){throw 'Model/native binary changed during the matrix'}
            Copy-Item -LiteralPath (Join-Path $packageDirectory 'package-evidence.json') -Destination (Join-Path $trialEvidence 'package.json')
            $installOutput=@(& (Join-Path $PSScriptRoot 'Install-App.ps1') -PackageDirectory $packageDirectory -Launch)
            [IO.File]::WriteAllText((Join-Path $trialEvidence 'install.txt'),($installOutput -join [Environment]::NewLine),$utf8)
            $ready=$false
            for($readyAttempt=0;$readyAttempt -lt 4;$readyAttempt++){
                $runtime=& (Join-Path $PSScriptRoot 'Get-AppState.ps1')|ConvertFrom-Json
                $runtimeState=Get-Content -LiteralPath (Join-Path $runtime.Evidence 'app-state.json') -Raw|ConvertFrom-Json
                if($runtime.RuntimeVerified -and $runtimeState.cameraPreviewReady -and $runtimeState.PSObject.Properties['cameraTelemetry'] -and $runtimeState.cameraTelemetry -and $runtimeState.cameraTelemetry.key -ceq $configuration.key -and $runtimeState.nativeDetector.phase -eq 'running' -and $runtimeState.nativeDetector.cameraFrames -ge 3 -and -not $runtimeState.cameraSession){$ready=$true;break}
                Start-Sleep -Milliseconds 500
            }
            [IO.File]::WriteAllText((Join-Path $trialEvidence 'readiness.json'),($runtimeState|ConvertTo-Json -Depth 55),$utf8)
            if(-not $ready){throw ('Actual PV camera configuration and fresh continuous YOLO frames were not verified: '+$trialId)}
            $readback=(Invoke-HlBridge @{action='cat';path='U:\Users\DefaultAccount\AppData\Local\DevelopmentFiles\RiceHoloLensFieldV1\config.json'}).Text
            [IO.File]::WriteAllText((Join-Path $trialEvidence 'device-config.json'),$readback,$utf8)
            $deviceConfiguration=$readback|ConvertFrom-Json
            if($deviceConfiguration.cameraDiagnostics -or -not $deviceConfiguration.resourceTelemetry -or $deviceConfiguration.cameraCaptureRequest.width -ne $configuration.width -or $deviceConfiguration.cameraCaptureRequest.height -ne $configuration.height -or $deviceConfiguration.cameraCaptureRequest.fps -ne $configuration.fps){throw 'Actual package camera configuration differs'}
            & (Join-Path $PSScriptRoot 'Measure-YoloResources.ps1') -RunId $trialId -Seconds $Seconds -WarmupSeconds $WarmupSeconds -Rounds 1 -ExpectedVersion '1.0.0.48' -ExpectedCameraKey $configuration.key
            $record=Get-Content -LiteralPath (Join-Path $reportRoot ('raw/'+$trialId+'/run.json')) -Raw|ConvertFrom-Json
            if($record.status -cne 'recorded' -or $record.completed_rounds -ne 1){throw ('Trial is incomplete: '+$trialId)}
            $status.trials+=@{run_id=$trialId;configuration=$configuration.key;pass=$pass;status='recorded';finished_at=[DateTimeOffset]::Now.ToString('o')}
            $status.completed_trials++;Save-Status
        }
    }
    $status.status='recorded';$status.finished_at=[DateTimeOffset]::Now.ToString('o');Save-Status
    Write-Output ('Recorded all '+$status.completed_trials+' matrix trials; original production package still needs restoration.')
}catch{
    $status.status='failed';$status.error=$_.Exception.Message;$status.finished_at=[DateTimeOffset]::Now.ToString('o');Save-Status
    throw
}
