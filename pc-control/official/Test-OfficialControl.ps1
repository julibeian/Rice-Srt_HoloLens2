param(
    [ValidateSet('Offline','Service','LocalDevice')][string]$Mode='Offline',
    [ValidatePattern('^[A-Za-z0-9_-]{1,64}$')][string]$RunId
)
$ErrorActionPreference = 'Stop'
$workspace = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
if (-not $RunId) { $RunId = 'official-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,6) }
$folder = Join-Path $workspace ('pc-control/.state/official-tests/' + $RunId)
$checkpoint = Join-Path $folder 'invocation.json'
$resultPath = Join-Path $folder 'result.json'
if (Test-Path -LiteralPath $checkpoint) {
    $prior = Get-Content -LiteralPath $checkpoint -Raw | ConvertFrom-Json
    if ($prior.Mode -cne $Mode) { throw 'This test RunId belongs to another mode.' }
    if (Test-Path -LiteralPath $resultPath) {
        $savedText = Get-Content -LiteralPath $resultPath -Raw
        $savedText
        $saved = $savedText | ConvertFrom-Json
        if ($null -ne $saved.ExitCode -and $saved.ExitCode -ne 0) { exit $saved.ExitCode }
        return
    }
    [ordered]@{RunId=$RunId;State='prior_attempt_pending';ReplayAttempted=$false;Evidence=$folder} | ConvertTo-Json
    return
}
[IO.Directory]::CreateDirectory($folder) | Out-Null
$windows = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$administrator = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$holographicClass = Test-Path -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{d612553d-06b1-49ca-8938-e39ef80eb16f}'
$issues = @()
if ($Mode -ne 'Offline') {
    if (-not (Get-Service -Name mrperceptionsimulation -ErrorAction SilentlyContinue)) { $issues += 'official_service_not_installed' }
    if (-not $administrator) { $issues += 'administrator_required_for_local_service_test' }
}
if ($Mode -eq 'LocalDevice') {
    if ([int]$windows.CurrentBuild -ge 26100) { $issues += 'windows_mixed_reality_removed_from_this_os' }
    if (-not $holographicClass) { $issues += 'holographic_device_class_missing' }
}
$preflight = [ordered]@{WindowsDisplayVersion=$windows.DisplayVersion;WindowsBuild=$windows.CurrentBuild;WindowsUBR=$windows.UBR;IsAdministrator=$administrator;HolographicDeviceClassPresent=$holographicClass;Issues=@($issues)}
if ($issues.Count -gt 0) {
    $invocation = [ordered]@{RunId=$RunId;At=(Get-Date).ToString('o');Mode=$Mode;LaunchAttempted=$false;PhysicalHeadsetContacted=$false;Preflight=$preflight}
    [IO.File]::WriteAllText($checkpoint,($invocation | ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
    $result = [ordered]@{RunId=$RunId;State='prerequisite_failed';ExitCode=3;Mode=$Mode;LaunchAttempted=$false;Preflight=$preflight;PhysicalHeadsetContacted=$false;Evidence=$folder}
    [IO.File]::WriteAllText($resultPath,($result | ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
    $result | ConvertTo-Json -Depth 6
    exit 3
}
$buildFolder = Join-Path $workspace 'pc-control/.state/official-probe-x64'
$buildPath = Join-Path $buildFolder 'build.json'
$sourceHash = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'OfficialSdkProbe.cs')).Hash
$built = if (Test-Path -LiteralPath $buildPath) { Get-Content -LiteralPath $buildPath -Raw | ConvertFrom-Json } else { $null }
if (-not $built -or $built.SourceSHA256 -cne $sourceHash) { & (Join-Path $PSScriptRoot 'Build-OfficialProbe.ps1') | Out-Null; $built=Get-Content -LiteralPath $buildPath -Raw | ConvertFrom-Json }
$arguments = @('--recording')
if ($Mode -in @('Service','LocalDevice')) { $arguments += '--service' }
if ($Mode -eq 'LocalDevice') { $arguments += '--exercise-local' }
$invocation = [ordered]@{RunId=$RunId;At=(Get-Date).ToString('o');Mode=$Mode;Executable=$built.Executable;SourceSHA256=$sourceHash;Arguments=$arguments;PhysicalHeadsetContacted=$false;LaunchAttempted=$true;Preflight=$preflight}
[IO.File]::WriteAllText($checkpoint,($invocation | ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
Copy-Item -LiteralPath $buildPath -Destination (Join-Path $folder 'build.json')
$stdout = Join-Path $folder 'stdout.json'
$stderr = Join-Path $folder 'stderr.txt'
$process = Start-Process -FilePath $built.Executable -ArgumentList $arguments -WorkingDirectory $buildFolder -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
$done = $process.WaitForExit(45000)
if (-not $done) {
    $result = [ordered]@{RunId=$RunId;State='process_pending';ProcessId=$process.Id;Mode=$Mode;LocalDeviceCleanupVerified=$false;PhysicalHeadsetContacted=$false;Evidence=$folder}
} else {
    $process.Refresh()
    $probe = Get-Content -LiteralPath $stdout -Raw | ConvertFrom-Json
    $result = [ordered]@{RunId=$RunId;State='completed';ExitCode=$process.ExitCode;Mode=$Mode;Probe=$probe;Preflight=$preflight;Service=@(Get-Service -Name mrperceptionsimulation -ErrorAction SilentlyContinue | Select-Object Name,Status,StartType);PhysicalHeadsetContacted=$false;Evidence=$folder}
}
[IO.File]::WriteAllText($resultPath,($result | ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
$result | ConvertTo-Json -Depth 12
if ($done -and $process.ExitCode -ne 0) { exit $process.ExitCode }
