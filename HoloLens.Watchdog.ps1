. (Join-Path $PSScriptRoot 'HoloLens.Common.ps1')
$watchdogMutex=[Threading.Mutex]::new($false,('Local\'+$script:HlPipeName+'-watchdog'))
$ownsWatchdog=$false
try { $ownsWatchdog=$watchdogMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsWatchdog=$true }
if (-not $ownsWatchdog) { $watchdogMutex.Dispose(); exit 0 }
try {
    $powerShell=Join-Path $PSHOME 'pwsh.exe'
    $daemon=Join-Path $PSScriptRoot 'HoloLens.Bridge.ps1'
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
        $worker.WaitForExit()
        # A normal stop is deliberate. Unexpected exits are restarted.
        if ($worker.ExitCode -eq 0) { break }
        $log=Join-Path $script:HlStateDirectory 'watchdog.log'
        if((Test-Path -LiteralPath $log) -and (Get-Item -LiteralPath $log).Length -gt 1MB){[IO.File]::Move($log,($log+'.1'),$true)}
        [IO.File]::AppendAllText($log,([DateTimeOffset]::Now.ToString('o')+' worker exited '+$worker.ExitCode+'; restarting in five seconds.'+[Environment]::NewLine))
        Start-Sleep -Seconds 5
    }
} finally {
    if ($ownsWatchdog) { $watchdogMutex.ReleaseMutex() }
    $watchdogMutex.Dispose()
}
