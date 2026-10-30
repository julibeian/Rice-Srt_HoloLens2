. (Join-Path $PSScriptRoot 'HoloLens.Common.ps1')
$watchdogMutex=[Threading.Mutex]::new($false,('Local\'+$script:HlPipeName+'-watchdog'))
$ownsWatchdog=$false
try { $ownsWatchdog=$watchdogMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsWatchdog=$true }
if (-not $ownsWatchdog) { $watchdogMutex.Dispose(); exit 0 }
try {
    $powerShell=Join-Path $PSHOME 'pwsh.exe'
    $daemon=Join-Path $PSScriptRoot 'HoloLens.Bridge.ps1'
    [IO.File]::WriteAllText((Join-Path $script:HlStateDirectory 'watchdog-status.json'),(@{ProcessId=$PID;StartedAt=[DateTimeOffset]::Now.ToString('o');SourceHash=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    while ($true) {
        $worker=$null
        $statusPath=Join-Path $script:HlStateDirectory 'status.json'
        if(Test-Path -LiteralPath $statusPath){
            try{
                $saved=Get-Content -LiteralPath $statusPath -Raw|ConvertFrom-Json
                $candidate=Get-CimInstance Win32_Process -Filter ('ProcessId='+[int]$saved.ProcessId)
                if($candidate -and $candidate.CommandLine -match [regex]::Escape($daemon)){
                    $worker=[Diagnostics.Process]::GetProcessById([int]$saved.ProcessId)
                    # Open and retain its handle before waiting, including after supervisor recovery.
                    $null=$worker.Handle
                }
            }catch{$worker=$null}
        }
        if(-not $worker){$worker=Start-Process -FilePath $powerShell -ArgumentList @('-NoLogo','-NoProfile','-WindowStyle','Hidden','-File',('"'+$daemon+'"')) -WindowStyle Hidden -PassThru}
        # Native SDK calls can hang while the process remains alive. Recover only
        # this owned bridge; never replay an operation whose outcome is unknown.
        $stalled=$false
        $stallLimit=[Math]::Max(120, [int]$script:HlConfig.CommandTimeoutSeconds + 60)
        while (-not $worker.WaitForExit(5000)) {
            try {
                $saved=Get-Content -LiteralPath $statusPath -Raw|ConvertFrom-Json
                if(Test-HlWorkerStalled $saved $worker.Id ([DateTimeOffset]::Now) $stallLimit){
                    $log=Join-Path $script:HlStateDirectory 'watchdog.log'
                    [IO.File]::AppendAllText($log,([DateTimeOffset]::Now.ToString('o')+' bridge '+$worker.Id+' made no progress for '+$stallLimit+' seconds; replacing the owned process. Active operation '+$saved.ActiveOperation+' has unknown outcome and will not be repeated.'+[Environment]::NewLine))
                    $worker.Kill(); $worker.WaitForExit(); $stalled=$true
                }
            } catch {
                # A partially replaced status file is retried on the next tick.
            }
        }
        # A normal stop is deliberate. Unexpected exits are restarted.
        if (-not $stalled -and $worker.ExitCode -eq 0) { $worker.Dispose(); break }
        $log=Join-Path $script:HlStateDirectory 'watchdog.log'
        if((Test-Path -LiteralPath $log) -and (Get-Item -LiteralPath $log).Length -gt 1MB){[IO.File]::Move($log,($log+'.1'),$true)}
        [IO.File]::AppendAllText($log,([DateTimeOffset]::Now.ToString('o')+' worker exited '+$worker.ExitCode+'; restarting in five seconds.'+[Environment]::NewLine))
        $worker.Dispose()
        Start-Sleep -Seconds 5
    }
} finally {
    if ($ownsWatchdog) { $watchdogMutex.ReleaseMutex() }
    $watchdogMutex.Dispose()
}
