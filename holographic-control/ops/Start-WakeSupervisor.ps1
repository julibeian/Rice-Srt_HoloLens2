param(
    [ValidateRange(60,3600)][int]$IntervalSeconds=180
)
# Long-running launcher for the availability supervisor. Started by the bridge
# (or manually). A local mutex keeps a single instance per session; it survives
# bridge restarts because it runs as a separate process.
$ErrorActionPreference='Stop'
$mutex=$null
try{
    $mutex=[Threading.Mutex]::new($false,'Local\HoloLensWakeSupervisorLoop')
    $owned=$false
    try{$owned=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$owned=$true}
    if(-not $owned){exit 0}
    $script=Join-Path $PSScriptRoot 'Watch-HoloLensAvailability.ps1'
    $pwsh=Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'runtime\powershell\pwsh.exe'
    while($true){
        try{
            & $pwsh -NoProfile -File $script -Once *> (Join-Path $PSScriptRoot '..\.state\supervisor\launcher-last.txt')
        }catch{}
        Start-Sleep -Seconds $IntervalSeconds
    }
}finally{
    if($mutex){try{$mutex.ReleaseMutex()}catch{};$mutex.Dispose()}
}
