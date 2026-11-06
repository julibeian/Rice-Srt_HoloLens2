param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_-]{1,64}$')][string]$RunId,
    [Parameter(Mandatory)][string]$Steps,
    [ValidateRange(1,120)][int]$HoldSeconds=0
)
# Deterministic, pre-declared controller input sequence. Steps are separated by
# "|", each "<offset-seconds>:<controller command>". Offsets are measured from
# the moment the controller reports its connected state. No command is retried:
# the same run name is read back instead of replayed.
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$workspace=Split-Path -Parent (Split-Path -Parent $root)
$folder=Join-Path $root ('.state/sequences/'+$RunId)
$record=Join-Path $folder 'sequence.jsonl'
if(Test-Path -LiteralPath $record){throw ('This sequence already ran; read the same run instead of replaying: '+$RunId)}
[IO.Directory]::CreateDirectory($folder)|Out-Null
function Record($value){[IO.File]::AppendAllText($record,($value|ConvertTo-Json -Depth 6 -Compress)+"`n",[Text.UTF8Encoding]::new($false))}
$parsed=@()
foreach($step in ($Steps -split '\|')){
    $parts=$step.Split(':',2)
    if($parts.Count -ne 2){throw ('Step must be "<seconds>:<command>": '+$step)}
    $offset=[double]::Parse($parts[0],[Globalization.CultureInfo]::InvariantCulture)
    if($offset -lt 0 -or $offset -gt 120){throw 'Step offset out of range'}
    $command=$parts[1].Trim()
    if($command.Length -eq 0 -or $command.Length -gt 256){throw 'Invalid controller command'}
    $parsed+=@{Offset=$offset;Command=$command}
}
$parsed=$parsed|Sort-Object {$_.Offset}
$start=[Diagnostics.ProcessStartInfo]::new()
$start.FileName=Join-Path $workspace 'runtime/powershell/pwsh.exe'
$start.Arguments='-NoProfile -File "'+(Join-Path $PSScriptRoot 'Start-PerceptionControl.ps1')+'"'
$start.WorkingDirectory=$workspace
$start.UseShellExecute=$false;$start.CreateNoWindow=$true
$start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
$process=[Diagnostics.Process]::new();$process.StartInfo=$start
Record @{at=[DateTimeOffset]::Now.ToString('o');event='launch';steps=$Steps;holdSeconds=$HoldSeconds}
if(-not $process.Start()){throw 'Controller adapter did not start.'}
function Read-Line([int]$TimeoutMs){
    $task=$process.StandardOutput.ReadLineAsync()
    if(-not $task.Wait($TimeoutMs)){return $null}
    return $task.Result
}
$ready=$null
try{
    $readyLine=Read-Line 60000
    if(-not $readyLine){throw 'Controller adapter produced no connection status.'}
    Record @{at=[DateTimeOffset]::Now.ToString('o');event='ready';line=$readyLine}
    $ready=$readyLine|ConvertFrom-Json
    if(-not $ready.ok -or $ready.state -ne 'connected'){Record @{event='not_connected'};$ready|ConvertTo-Json -Compress;return}
    $clock=[Diagnostics.Stopwatch]::StartNew()
    foreach($step in $parsed){
        while($clock.Elapsed.TotalSeconds -lt $step.Offset){Start-Sleep -Milliseconds 20}
        $at=[DateTimeOffset]::Now.ToString('o')
        $process.StandardInput.WriteLine($step.Command)
        $answer=Read-Line 30000
        Record @{at=$at;offsetSeconds=[Math]::Round($clock.Elapsed.TotalSeconds,3);event='command';command=$step.Command;answer=$answer}
        if($step.Command -eq 'exit'){break}
    }
    if($HoldSeconds -gt 0){Start-Sleep -Seconds $HoldSeconds}
}finally{
    try{if(-not $process.HasExited){$process.StandardInput.WriteLine('exit');$process.StandardInput.Close();if(-not $process.WaitForExit(10000)){$process.Kill()}}}catch{}
    try{$tail=$process.StandardOutput.ReadToEnd();if($tail){Record @{event='trailing_output';line=$tail.TrimEnd()}}}catch{}
    try{$err=$process.StandardError.ReadToEnd();if($err){Record @{event='stderr';line=$err.TrimEnd()}}}catch{}
    $process.Dispose()
}
Record @{at=[DateTimeOffset]::Now.ToString('o');event='finished';evidence=$folder}
Get-Content -LiteralPath $record
