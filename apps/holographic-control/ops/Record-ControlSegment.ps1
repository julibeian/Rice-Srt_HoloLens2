param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_-]{1,64}$')][string]$RunId,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_-]{1,64}$')][string]$CaptureRunId,
    [ValidateRange(1,15)][int]$Seconds=15,
    [ValidateSet('Interactive','Detail','Low')][string]$VideoProfile='Detail',
    [string]$Steps='',
    [double]$LaunchAppSeconds=-1,
    [ValidateRange(0,20)][double]$LeadSeconds=2.5
)
# One process owns both the live recording and the simulated-hand input, so the
# tap lands inside the recorded segment. Steps use the same
# "<offset-seconds>:<command>" syntax as Invoke-ControlSequence and are offset
# from the moment the controller reports connected.
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$workspace=Split-Path -Parent (Split-Path -Parent $root)
$folder=Join-Path $root ('.state/segments/'+$RunId)
$record=Join-Path $folder 'segment.jsonl'
if(Test-Path -LiteralPath $record){throw ('This segment already ran; read the same run instead of replaying: '+$RunId)}
[IO.Directory]::CreateDirectory($folder)|Out-Null
function Record($value){[IO.File]::AppendAllText($record,($value|ConvertTo-Json -Depth 6 -Compress)+"`n",[Text.UTF8Encoding]::new($false))}
$parsed=@()
foreach($step in ($Steps -split '\|')){
    if([string]::IsNullOrWhiteSpace($step)){continue}
    $parts=$step.Split(':',2)
    if($parts.Count -ne 2){throw ('Step must be "<seconds>:<command>": '+$step)}
    $parsed+=@{Offset=[double]::Parse($parts[0],[Globalization.CultureInfo]::InvariantCulture);Command=$parts[1].Trim()}
}
$parsed=$parsed|Sort-Object {$_.Offset}
$startedAt=[DateTimeOffset]::Now.ToString('o')
# 1. Recording runs in a child process so the input timeline is unaffected by
#    blocking stream reads. The child keeps every existing identity, pin and
#    credential check of Get-PortalLiveSample.
$readStart=[Diagnostics.ProcessStartInfo]::new()
$readStart.FileName=Join-Path $workspace 'runtime/powershell/pwsh.exe'
$readStart.Arguments='-NoProfile -File "'+(Join-Path $PSScriptRoot 'Get-PortalLiveSample.ps1')+'" -RunId '+$CaptureRunId+' -Seconds '+$Seconds+' -VideoProfile '+$VideoProfile
$readStart.WorkingDirectory=$workspace
$readStart.UseShellExecute=$false;$readStart.CreateNoWindow=$true
$readStart.RedirectStandardOutput=$true;$readStart.RedirectStandardError=$true
$reader=[Diagnostics.Process]::new();$reader.StartInfo=$readStart
Record @{event='launch';at=$startedAt;steps=$Steps;leadSeconds=$LeadSeconds;captureRunId=$CaptureRunId;seconds=$Seconds;profile=$VideoProfile}
if(-not $reader.Start()){throw 'Recording child did not start.'}
$recordingClock=[Diagnostics.Stopwatch]::StartNew()
if($LaunchAppSeconds -ge 0){
    while($recordingClock.Elapsed.TotalSeconds -lt $LaunchAppSeconds){Start-Sleep -Milliseconds 20}
    # Own-app activation only; the launch result is recorded separately by the
    # existing Start-App evidence file. It is not retried here.
    $appStart=[Diagnostics.ProcessStartInfo]::new()
    $appStart.FileName=Join-Path $workspace 'runtime/powershell/pwsh.exe'
    $appStart.Arguments='-NoProfile -File "'+(Join-Path $workspace 'apps/field-app/ops/Start-App.ps1')+'"'
    $appStart.WorkingDirectory=$workspace
    $appStart.UseShellExecute=$false;$appStart.CreateNoWindow=$true
    $appStart.RedirectStandardOutput=$true;$appStart.RedirectStandardError=$true
    $appProcess=[Diagnostics.Process]::new();$appProcess.StartInfo=$appStart
    $appProcess.Start()|Out-Null
    Record @{event='app_launch_requested';at=[DateTimeOffset]::Now.ToString('o');offsetSeconds=[Math]::Round($recordingClock.Elapsed.TotalSeconds,3)}
    $appProcess.Dispose()
}
Start-Sleep -Seconds ([Math]::Max(0,$LeadSeconds-($recordingClock.Elapsed.TotalSeconds)))
if($parsed.Count -eq 0){
    $reader.WaitForExit(90000)|Out-Null
    Record @{event='recording_finished';at=[DateTimeOffset]::Now.ToString('o');noInput=$true;capture=$reader.StandardOutput.ReadToEnd().Trim();error=$reader.StandardError.ReadToEnd().Trim()}
    $reader.Dispose()
    Get-Content -LiteralPath $record
    return
}
# 2. Controller connection.
$ctlStart=[Diagnostics.ProcessStartInfo]::new()
$ctlStart.FileName=Join-Path $workspace 'runtime/powershell/pwsh.exe'
$ctlStart.Arguments='-NoProfile -File "'+(Join-Path $PSScriptRoot 'Start-PerceptionControl.ps1')+'"'
$ctlStart.WorkingDirectory=$workspace
$ctlStart.UseShellExecute=$false;$ctlStart.CreateNoWindow=$true
$ctlStart.RedirectStandardInput=$true;$ctlStart.RedirectStandardOutput=$true;$ctlStart.RedirectStandardError=$true
$controller=[Diagnostics.Process]::new();$controller.StartInfo=$ctlStart
if(-not $controller.Start()){throw 'Controller adapter did not start.'}
function Read-Line([int]$TimeoutMs){
    $task=$controller.StandardOutput.ReadLineAsync()
    if(-not $task.Wait($TimeoutMs)){return $null}
    return $task.Result
}
try{
    $readyLine=Read-Line 60000
    if(-not $readyLine){throw 'Controller adapter produced no connection status.'}
    $ready=$readyLine|ConvertFrom-Json
    Record @{event='ready';at=[DateTimeOffset]::Now.ToString('o');line=$readyLine}
    if($ready.ok -and $ready.state -eq 'connected'){
        $clock=[Diagnostics.Stopwatch]::StartNew()
        foreach($step in $parsed){
            while($clock.Elapsed.TotalSeconds -lt $step.Offset){Start-Sleep -Milliseconds 20}
            $at=[DateTimeOffset]::Now.ToString('o')
            $controller.StandardInput.WriteLine($step.Command)
            $answer=Read-Line 30000
            Record @{event='command';at=$at;offsetSeconds=[Math]::Round($clock.Elapsed.TotalSeconds,3);command=$step.Command;answer=$answer}
        }
    }
}finally{
    try{if(-not $controller.HasExited){$controller.StandardInput.WriteLine('exit');$controller.StandardInput.Close();if(-not $controller.WaitForExit(10000)){$controller.Kill()}}}catch{}
    try{$tail=$controller.StandardOutput.ReadToEnd();if($tail){Record @{event='controller_tail';line=$tail.TrimEnd()}}}catch{}
    $controller.Dispose()
    $readerOut=$null
    try{$readerOut=$reader.StandardOutput.ReadToEnd()}catch{}
    try{$readerErr=$reader.StandardError.ReadToEnd()}catch{}
    $reader.WaitForExit(90000)|Out-Null
    Record @{event='recording_finished';at=[DateTimeOffset]::Now.ToString('o');capture=$readerOut.Trim();error=$readerErr.Trim()}
    $reader.Dispose()
}
Get-Content -LiteralPath $record
