param([ValidateRange(1,2147483647)][int]$MatrixProcessId=14180)
$ErrorActionPreference='Stop'
$appRoot=Split-Path -Parent $PSScriptRoot
$workspace=Split-Path -Parent (Split-Path -Parent $appRoot)
. (Join-Path $workspace 'usb-terminal/HoloLens.Common.ps1')
$reportRoot=Join-Path $workspace 'reports/20261105-yolo-camera-resources'
$statusPath=Join-Path $reportRoot 'closing-status.json'
if(Test-Path -LiteralPath $statusPath){throw 'A closing operation already exists. Inspect the original process and result; do not start another.'}
$matrixStatusPath=Join-Path $reportRoot 'matrix-startup-20261105-status.json'
$matrixProcess=Get-Process -Id $MatrixProcessId -ErrorAction Stop
$matrixStarted=$matrixProcess.StartTime.ToUniversalTime().Ticks
$utf8=[Text.UTF8Encoding]::new($false)
$closing=[ordered]@{schema=1;status='waiting_for_matrix';pid=$PID;matrix_pid=$MatrixProcessId;matrix_started_ticks=$matrixStarted;started_at=[DateTimeOffset]::Now.ToString('o')}
function Save-Closing {$closing.updated_at=[DateTimeOffset]::Now.ToString('o');[IO.File]::WriteAllText($statusPath,($closing|ConvertTo-Json -Depth 8),$utf8)}
Save-Closing
try{
    while($true){
        $live=Get-Process -Id $MatrixProcessId -ErrorAction SilentlyContinue
        $matrixState=Get-Content -LiteralPath $matrixStatusPath -Raw|ConvertFrom-Json
        $sameProcess=$live -and $live.StartTime.ToUniversalTime().Ticks -eq $matrixStarted
        if(-not $sameProcess){
            if($matrixState.status -cne 'recorded' -or $matrixState.completed_trials -ne 30){throw 'The actual matrix process exited without thirty recorded trials; no automatic restoration or replay was performed'}
            break
        }
        if($matrixState.status -eq 'failed'){throw ('Matrix reported failure: '+$matrixState.error)}
        Start-Sleep -Seconds 10
    }
    $closing.status='restoring_original';Save-Closing
    $baseline=Get-Content -LiteralPath (Join-Path $reportRoot 'baseline/original-package.json') -Raw|ConvertFrom-Json
    $originalDirectory=[string]$baseline.original_package_directory
    $original=Get-Content -LiteralPath (Join-Path $originalDirectory 'package-evidence.json') -Raw|ConvertFrom-Json
    if($original.Version -cne '1.0.0.48' -or $original.ModelSha256 -cne 'e6b6d2f6baaae3b7970f1a4e425f2c2347a90fe6aab34c3da0aed738fcf1b048' -or (Get-FileHash -LiteralPath $original.Package).Hash -cne $original.Sha256){throw 'Original package identity differs from the preserved baseline'}
    $closing.original_package_directory=$originalDirectory
    $closing.original_package_sha256=$original.Sha256
    Save-Closing
    [IO.File]::WriteAllText((Join-Path $appRoot '.state/current-package.txt'),$originalDirectory,$utf8)
    $installOutput=@(& (Join-Path $PSScriptRoot 'Install-App.ps1') -PackageDirectory $originalDirectory -Launch)
    [IO.File]::WriteAllText((Join-Path $reportRoot 'restoration-install.txt'),($installOutput -join [Environment]::NewLine),$utf8)
    $ready=$false
    for($attempt=0;$attempt -lt 5;$attempt++){
        $runtime=& (Join-Path $PSScriptRoot 'Get-AppState.ps1')|ConvertFrom-Json
        $state=Get-Content -LiteralPath (Join-Path $runtime.Evidence 'app-state.json') -Raw|ConvertFrom-Json
        if($runtime.RuntimeVerified -and $state.cameraPreviewReady -and -not $state.cameraSession -and $state.nativeDetector.phase -eq 'running' -and $state.nativeDetector.cameraFrames -ge 3 -and $state.nativeDetector.sourceWidth -eq 896 -and $state.nativeDetector.sourceHeight -eq 504){$ready=$true;break}
        Start-Sleep -Milliseconds 500
    }
    [IO.File]::WriteAllText((Join-Path $reportRoot 'restoration-ready.json'),($state|ConvertTo-Json -Depth 50),$utf8)
    if(-not $ready){throw 'Restored original camera/model runtime was not observed'}
    $closing.status='sampling_original_again';$closing.runtime_session=$state.runtimeSession;Save-Closing
    Write-Output 'Original production package restored; recording three final baseline rounds.'
    & (Join-Path $PSScriptRoot 'Measure-YoloResources.ps1') -RunId 'baseline48-restored' -ExpectedVersion '1.0.0.48' -Seconds 120 -WarmupSeconds 20 -Rounds 3
    $closing.status='verifying_original_files';Save-Closing
    $verification=& (Join-Path $PSScriptRoot 'Verify-YoloDeployment.ps1') -RunId 'yolo-resources-restored-20261105'|ConvertFrom-Json
    if(-not $verification.Passed -or $verification.RuntimeSession -cne $closing.runtime_session){throw 'Original package/runtime file verification did not pass in the final sampling session'}
    [IO.File]::WriteAllText((Join-Path $reportRoot 'restored-verification.json'),($verification|ConvertTo-Json -Depth 12),$utf8)
    if((Get-FileHash -LiteralPath (Join-Path $workspace 'README.md')).Hash -cne $baseline.readme_sha256){throw 'Root README differs from the baseline'}
    $closing.status='recorded';$closing.finished_at=[DateTimeOffset]::Now.ToString('o');Save-Closing
    Write-Output 'Original package, continuous camera session and twelve deployment files verified. Recompute and audit all records before declaring the task complete.'
}catch{
    $closing.status='failed';$closing.error=$_.Exception.Message;$closing.finished_at=[DateTimeOffset]::Now.ToString('o');Save-Closing
    throw
}
