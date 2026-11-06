param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_-]{1,80}$')][string]$RunId,
    [ValidateRange(10,3600)][int]$Seconds=120,
    [ValidateRange(0,300)][int]$WarmupSeconds=20,
    [ValidateRange(1,10)][double]$IntervalSeconds=1,
    [ValidateRange(1,10)][int]$Rounds=3,
    [string]$ExpectedVersion='1.0.0.48',
    [string]$ExpectedModelSha256='e6b6d2f6baaae3b7970f1a4e425f2c2347a90fe6aab34c3da0aed738fcf1b048',
    [string]$ExpectedCameraKey='',
    [Nullable[int]]$ExpectedControlMode=$null,
    [string]$OutputRoot=''
)
$ErrorActionPreference='Stop'
$appRoot=Split-Path -Parent $PSScriptRoot
$workspace=Split-Path -Parent (Split-Path -Parent $appRoot)
. (Join-Path $workspace 'apps/holographic-control/ops/Holographic.Common.ps1')
if(-not $OutputRoot){$OutputRoot=Join-Path $workspace 'reports/20261105-yolo-camera-resources/raw'}
$folder=Join-Path $OutputRoot $RunId
if(Test-Path -LiteralPath $folder){throw 'RunId already exists. Preserve the previous observations and use a new RunId.'}
[IO.Directory]::CreateDirectory($folder)|Out-Null
$utf8=[Text.UTF8Encoding]::new($false)
$checkControlMode=$PSBoundParameters.ContainsKey('ExpectedControlMode')
$runPath=Join-Path $folder 'run.json'
$run=[ordered]@{schema=1;run_id=$RunId;status='initializing';pid=$PID;started_at=[DateTimeOffset]::Now.ToString('o');rounds=$Rounds;seconds=$Seconds;warmup_seconds=$WarmupSeconds;interval_seconds=$IntervalSeconds;expected_version=$ExpectedVersion;expected_model_sha256=$ExpectedModelSha256;expected_camera_key=$ExpectedCameraKey;source='HoloLens Device Portal; complete device CPU and individual GPU engines';observer='Pinned USB HTTPS; systemperf and own app-state at sample rate; power/thermal/battery every 10s; no live video stream';errors=@()}
$run.expected_control_mode=if($checkControlMode){$ExpectedControlMode}else{$null}
function Save-Run {[IO.File]::WriteAllText($runPath,($run|ConvertTo-Json -Depth 8),$utf8)}
function Read-Observation([string]$Path){
    $requestClock=[Diagnostics.Stopwatch]::StartNew()
    try{
        $response=$context.Client.GetAsync($context.BaseUri+$Path).GetAwaiter().GetResult()
        try{
            $raw=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            $body=$null
            if([int]$response.StatusCode -eq 200){try{$body=$raw|ConvertFrom-Json -Depth 80}catch{return @{status=[int]$response.StatusCode;duration_ms=$requestClock.Elapsed.TotalMilliseconds;error='Invalid JSON';raw=$raw}}}
            return @{status=[int]$response.StatusCode;duration_ms=$requestClock.Elapsed.TotalMilliseconds;body=$body}
        }finally{$response.Dispose()}
    }catch{return @{status=$null;duration_ms=$requestClock.Elapsed.TotalMilliseconds;error=$_.Exception.Message}}
}
Save-Run
$context=$null;$writer=$null
try{
    $context=New-HoloAuthenticatedPortalContext
    $run.device=$context.Device.DeviceName
    $run.ssh_identity_verified=$true
    $run.portal_public_key_sha256=$context.PublicKeySha256
    $inventory=Read-Observation '/api/app/packagemanager/packages'
    if($inventory.status -ne 200){throw 'Cannot read current package identity'}
    $fieldPackages=@($inventory.body.InstalledPackages|Where-Object{$_.PackageRelativeId -ceq 'Rice.HoloLens.Field_r5420n6798s24!Field'})
    if($fieldPackages.Count -ne 1 -or $fieldPackages[0].PackageFullName -notmatch ('^Rice\.HoloLens\.Field_'+[regex]::Escape($ExpectedVersion)+'_(arm64|neutral)__r5420n6798s24$')){throw 'Unexpected installed package'}
    $run.package_full_name=$fieldPackages[0].PackageFullName
    [IO.File]::WriteAllText((Join-Path $folder 'package.json'),($fieldPackages[0]|ConvertTo-Json -Depth 8),$utf8)
    $appPath='/api/filesystem/apps/file?knownfolderid=LocalAppData&packagefullname='+[uri]::EscapeDataString($fieldPackages[0].PackageFullName)+'&path='+[uri]::EscapeDataString('\LocalState')+'&filename=app-state.json'
    $session=$null;$process=$null
    for($round=1;$round -le $Rounds;$round++){
        $run.status='sampling';$run.current_round=$round;Save-Run
        $stream=[IO.File]::Open((Join-Path $folder ('round-{0:D2}.jsonl' -f $round)),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
        $writer=[IO.StreamWriter]::new($stream,$utf8);$writer.AutoFlush=$true
        $clock=[Diagnostics.Stopwatch]::StartNew();$nextSample=0.0;$nextHealth=0.0;$index=0;$health=$null;$hotCount=0;$lastProgress=-1
        while($clock.Elapsed.TotalSeconds -lt ($WarmupSeconds+$Seconds)){
            if($clock.Elapsed.TotalSeconds -lt $nextSample){Start-Sleep -Milliseconds ([Math]::Min(250,[Math]::Max(1,[int](($nextSample-$clock.Elapsed.TotalSeconds)*1000))));continue}
            $startedMs=$clock.Elapsed.TotalMilliseconds
            $sample=[ordered]@{index=$index;round=$round;at=[DateTimeOffset]::Now.ToString('o');elapsed_ms=$startedMs;measurement=($startedMs -ge $WarmupSeconds*1000);systemperf=(Read-Observation '/api/resourcemanager/systemperf');app=(Read-Observation $appPath)}
            if($checkControlMode){$sample.control_mode=Read-Observation '/api/holographic/simulation/control/mode'}
            if($clock.Elapsed.TotalSeconds -ge $nextHealth){
                $health=[ordered]@{at=[DateTimeOffset]::Now.ToString('o');power=(Read-Observation '/api/power/state');thermal=(Read-Observation '/api/holographic/thermal/stage');mitigation=(Read-Observation '/api/holographic/thermal/getMitigationLevels');battery=(Read-Observation '/api/power/battery')}
                $nextHealth=$clock.Elapsed.TotalSeconds+10
                if($health.thermal.status -eq 200 -and $health.thermal.body.CurrentStage -ge 2){$hotCount++}else{$hotCount=0}
            }
            $sample.health=$health
            $sample.completed_elapsed_ms=$clock.Elapsed.TotalMilliseconds
            $sample.overrun_ms=[Math]::Max(0,$clock.Elapsed.TotalMilliseconds-$startedMs-$IntervalSeconds*1000)
            $writer.WriteLine(($sample|ConvertTo-Json -Depth 65 -Compress))
            if($sample.app.status -ne 200 -or $sample.systemperf.status -ne 200){throw 'Required performance/app endpoint failed; partial data preserved'}
            if($checkControlMode -and ($sample.control_mode.status -ne 200 -or $sample.control_mode.body.mode -ne $ExpectedControlMode)){throw 'Control mode changed or could not be verified; partial data preserved'}
            $state=$sample.app.body;$native=$state.nativeDetector
            if($state.version -cne $ExpectedVersion -or $native.modelSha256 -cne $ExpectedModelSha256 -or $native.inputSize -ne 320 -or -not $native.onDevice){throw 'Unexpected runtime/model identity'}
            if(-not $session){$session=$state.runtimeSession;$process=$native.processId;$run.runtime_session=$session;$run.process_id=$process;Save-Run}
            if($state.runtimeSession -cne $session -or $native.processId -ne $process){throw 'Runtime session/process changed during the experiment'}
            if($ExpectedCameraKey -and $state.cameraTelemetry.key -cne $ExpectedCameraKey){throw 'Actual camera setting differs from requested setting'}
            if($sample.measurement -and ($native.phase -cne 'running' -or -not $native.modelLoaded -or $native.source -cne 'camera' -or $native.hr -ne 0 -or -not $state.cameraPreviewReady)){throw 'Live camera YOLO inference is not healthy'}
            if($health.power.status -eq 200 -and $health.power.body.LowPowerState){throw 'Device entered low power; round is incomplete'}
            if($hotCount -ge 2){throw 'Thermal stage >=2 on consecutive health samples; partial round preserved'}
            $index++;$nextSample+=$IntervalSeconds
            if($clock.Elapsed.TotalSeconds-$nextSample -gt $IntervalSeconds){$nextSample=$clock.Elapsed.TotalSeconds+$IntervalSeconds}
            $progress=[int][Math]::Floor($clock.Elapsed.TotalSeconds/30)
            if($progress -gt $lastProgress){$lastProgress=$progress;Write-Output ('{0}: round {1}/{2}, {3:N1}s, CPU {4}%, frames {5}' -f $RunId,$round,$Rounds,$clock.Elapsed.TotalSeconds,$sample.systemperf.body.CpuLoad,$native.cameraFrames)}
        }
        $writer.Dispose();$writer=$null
        $run.completed_rounds=$round;Save-Run
    }
    $run.status='recorded';$run.finished_at=[DateTimeOffset]::Now.ToString('o');Save-Run
    Write-Output ('Recorded '+$folder)
}catch{
    $run.status='failed';$run.errors+=@($_.Exception.Message);$run.finished_at=[DateTimeOffset]::Now.ToString('o');Save-Run
    throw
}finally{
    if($writer){$writer.Dispose()}
    if($context){$context.Client.Dispose()}
}
