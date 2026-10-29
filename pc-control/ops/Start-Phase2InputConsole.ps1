param([Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_-]{1,58}$')][string]$RunId,[switch]$InitializeProbe,[switch]$InitializePose,[ValidateRange(-1,1)][single]$InitialForwardMeters=0)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$workspace=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$folder=Join-Path $workspace ('reports\phase2-full-control\'+$RunId)
$trial=Get-Content -LiteralPath (Join-Path $folder 'trial.json') -Raw|ConvertFrom-Json
if($trial.route -notin @('direct-sdk','custom-adapter')){throw 'This console is not an official GUI input test.'}
$invocationPath=Join-Path $folder 'console-invocation.json'
if(Test-Path -LiteralPath $invocationPath){throw 'Console already invoked. Inspect original cleanup and do not replay.'}
$ownsMutex=$false;$mutex=[Threading.Mutex]::new($true,'Local\RiceHoloLensDesktopControl',[ref]$ownsMutex)
if(-not $ownsMutex){$mutex.Dispose();throw 'Another desktop controller owns the device.'}
$clock=[Diagnostics.Stopwatch]::StartNew();$counter=0;$child=$null;$leaseStarted=$false;$expiry=$null
$utf8=[Text.UTF8Encoding]::new($false)
function Save($Name,$Value){[IO.File]::WriteAllText((Join-Path $folder $Name),($Value|ConvertTo-Json -Depth 12),$utf8)}
function Emit($Kind,$Value){$row=@{at=[DateTimeOffset]::Now.ToString('o');elapsed_ms=$clock.ElapsedMilliseconds;kind=$Kind;value=$Value};[IO.File]::AppendAllText((Join-Path $folder 'console-events.jsonl'),($row|ConvertTo-Json -Compress -Depth 12)+[Environment]::NewLine,$utf8);$row|ConvertTo-Json -Compress -Depth 12}
function Sample([string]$Label){
 # MRC can return only its 84-byte container header when a previous sample has
 # just disconnected. Retry only this read, preserving each separate receipt.
 $sample=$null
 for($readAttempt=0;$readAttempt -lt 2;$readAttempt++){
  if($script:counter -gt 0){Start-Sleep -Milliseconds 1800}
  $script:counter++;$sampleRun=$RunId+'-'+$script:counter
  if($sampleRun.Length -gt 64){throw 'Sample identifier too long.'}
  $sample=& (Join-Path $workspace 'holographic-control\ops\Get-PortalLiveSample.ps1') -RunId $sampleRun -Seconds 2|ConvertFrom-Json
  if($sample.StreamHttpStatus -eq 200 -and $sample.Bytes -ge 1000 -and $sample.StreamClosed){break}
  Emit 'display-read-incomplete' @{sample_result=(Join-Path $sample.Evidence 'result.json');bytes=$sample.Bytes;http_status=$sample.StreamHttpStatus;input_replayed=$false} | Out-Host
 }
 if($sample.StreamHttpStatus -ne 200 -or $sample.Bytes -lt 1000 -or -not $sample.StreamClosed){throw 'No fresh bounded display sample.'}
 $picture=Join-Path $folder ('frame-'+$script:counter.ToString('D3')+'-'+$Label+'.png')
 & ffmpeg -hide_banner -loglevel error -i $sample.Video -vf fps=1 -update 1 $picture 2> (Join-Path $folder ('decode-'+$script:counter+'.txt'))
 if($LASTEXITCODE -ne 0 -or -not(Test-Path -LiteralPath $picture)){throw 'No decoded display frame.'}
 $proof=@{at=[DateTimeOffset]::Now.ToString('o');frame=$picture;sha256=(Get-FileHash -LiteralPath $picture).Hash;sample_result=(Join-Path $sample.Evidence 'result.json');sample_started=$sample.At;sample_seconds=$sample.Seconds;label=$Label}
 Save ('frame-'+$script:counter.ToString('D3')+'.json') $proof
 return $proof
}
try{
 Copy-Item -LiteralPath $PSCommandPath -Destination (Join-Path $folder 'console-source.ps1')
 Save 'console-invocation.json' @{run_id=$RunId;at=[DateTimeOffset]::Now.ToString('o');route=$trial.route;replay_allowed=$false;initialize_probe=[bool]$InitializeProbe;initialize_pose=[bool]$InitializePose;initial_forward_meters=$InitialForwardMeters;console_source_sha256=(Get-FileHash -LiteralPath $PSCommandPath).Hash;controller_source_sha256=(Get-FileHash -LiteralPath (Join-Path $workspace 'holographic-control\desktop\PerceptionControl.cs')).Hash;controller_exe_sha256=(Get-FileHash -LiteralPath (Join-Path $workspace 'holographic-control\.state\desktop-x86\PerceptionControl.exe')).Hash}
 $lease=& (Join-Path $workspace 'holographic-control\ops\Control-Lease.ps1') -Mode Start -RunId $RunId|ConvertFrom-Json
 $leaseStarted=$true;Save 'lease-start.json' $lease
 if(-not $lease.Active){throw 'Named device protection not active.'}
 $leaseInvocation=Get-Content -LiteralPath (Join-Path $workspace ('holographic-control\.state\control-leases\'+$RunId+'\invocation.json')) -Raw|ConvertFrom-Json
 $expiry=[DateTimeOffset]::Parse($leaseInvocation.At).AddSeconds(280)
 $start=[Diagnostics.ProcessStartInfo]::new((Join-Path $workspace 'runtime\powershell\pwsh.exe'))
 $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
 $start.StandardInputEncoding=$utf8;$start.StandardOutputEncoding=$utf8
 foreach($argument in @('-NoProfile','-File',(Join-Path $workspace 'holographic-control\ops\Start-PerceptionControl.ps1'))){$start.ArgumentList.Add($argument)}
 $child=[Diagnostics.Process]::Start($start);$childError=$child.StandardError.ReadToEndAsync()
 $ready=$child.StandardOutput.ReadLineAsync();if(-not $ready.Wait(20000)){throw 'Controller start pending; no input replay.'}
 $ready=$ready.Result|ConvertFrom-Json;Emit 'controller-ready' $ready
 if(-not $ready.ok -or $ready.state -ne 'connected'){throw 'Controller not connected.'}
 if($InitializeProbe -or $InitializePose){
  if($InitializeProbe -and $trial.target -cne 'Rice.HoloLens.InputProbe_r5420n6798s24!Probe'){throw 'Probe activation is limited to the independent test scene.'}
  # Pose/presence initialization is explicit and has no tap or Home gesture.
  # The first selectable target is observed only after this initialization.
  foreach($setup in @('presence on','track-position','look-absolute 0.1 -0.23 0','hand-frustum ignore','hand-look 0 0.21 0','hand on')){
   Emit 'initialization-issued-once' @{command=$setup;selection_gesture=$false}
   $child.StandardInput.WriteLine($setup);$child.StandardInput.Flush();$answer=$child.StandardOutput.ReadLineAsync()
   if(-not $answer.Wait(12000)){throw 'Initialization result unknown; no replay.'}
   $answer=$answer.Result|ConvertFrom-Json;Emit 'initialization-response' $answer;if(-not $answer.ok){throw 'Initialization rejected.'}
  }
  if($InitializeProbe){
   $activation=& (Join-Path $PSScriptRoot 'Invoke-InputProbe.ps1') -Action Launch -RunId ($RunId+'-open')|ConvertFrom-Json
   Emit 'initialization-activation' $activation;if(-not $activation.activation_accepted){throw 'Probe activation not accepted.'}
   $InitialForwardMeters=0.7
  }
  if($InitialForwardMeters -ne 0){$child.StandardInput.WriteLine('move 0 0 '+$InitialForwardMeters.ToString('F3',[Globalization.CultureInfo]::InvariantCulture));$child.StandardInput.Flush();$answer=$child.StandardOutput.ReadLineAsync();if(-not $answer.Wait(12000)){throw 'View movement result unknown.'};Emit 'initialization-view' ($answer.Result|ConvertFrom-Json)}
 }
 Emit 'sample' (Sample 'initial')
 Emit 'ready' @{run_id=$RunId;expires_at=$expiry.ToString('o');commands='sample; pose; status; explicit SDK commands; exit';auto_fresh_before_each_input=$true}
 while([DateTimeOffset]::Now -lt $expiry){
  $pending=[Console]::In.ReadLineAsync()
  while(-not $pending.Wait(250) -and [DateTimeOffset]::Now -lt $expiry){}
  if(-not $pending.IsCompleted){Emit 'expired' @{input_sent=$false};break}
  $line=$pending.Result;if($null -eq $line -or $line -eq 'exit'){break}
  if([string]::IsNullOrWhiteSpace($line)){continue}
  if($line.Length -gt 256 -or $line -match '[\r\n]'){Emit 'rejected' @{reason='invalid_command_length';input_sent=$false};continue}
  $inputSent=$false;$phase='before'
  try{
   if($line -eq 'sample'){Emit 'sample' (Sample 'inspect');continue}
   $readOnly=$line -in @('pose','status')
   if(-not $readOnly){
    if([DateTimeOffset]::Now -gt $expiry.AddSeconds(-15)){throw 'Too little protection time remains; input not sent.'}
    $fresh=Sample 'before';Emit 'before' $fresh
    if(([DateTimeOffset]::Now-[DateTimeOffset]::Parse($fresh.at)).TotalSeconds -gt 2.5){throw 'Frame became stale; input not sent.'}
   }
   Emit 'command-issued-once' @{command=$line;read_only=$readOnly}
   $child.StandardInput.WriteLine($line);$child.StandardInput.Flush()
   $inputSent=-not $readOnly;$phase='response'
   $answer=$child.StandardOutput.ReadLineAsync()
   if(-not $answer.Wait(12000)){throw 'Input result unknown; command will not be replayed.'}
   if(-not $answer.Result){throw 'Input channel ended.'}
   Emit 'response' ($answer.Result|ConvertFrom-Json)
   if(-not $readOnly){$phase='after';Emit 'after' (Sample 'after')}
  }catch{Emit 'operation-error' @{type=$_.Exception.GetType().Name;message=$_.Exception.Message;command=$line;phase=$phase;input_sent=$inputSent;replayed=$false};break}
 }
}finally{
 $cleanup=[ordered]@{at=[DateTimeOffset]::Now.ToString('o');stream_close_verified=$false;lease_restored=$false;errors=@()}
 if($child){
  try{if(-not $child.HasExited){$child.StandardInput.WriteLine('exit');$child.StandardInput.Flush();$child.StandardInput.Close();if(-not $child.WaitForExit(10000)){throw 'Controller cleanup pending.'}};$tail=$child.StandardOutput.ReadToEnd();[IO.File]::WriteAllText((Join-Path $folder 'controller-cleanup.txt'),$tail,$utf8);$cleanup.stream_close_verified=[bool]($tail -match '"state":"closed"' -and $tail -match '"httpStatus":200');$cleanup.stderr=$childError.GetAwaiter().GetResult()}catch{$cleanup.errors+=@{stage='controller';type=$_.Exception.GetType().Name;message=$_.Exception.Message};if(-not $child.HasExited){$child.Kill()}}finally{$child.Dispose()}
 }
 if($leaseStarted){try{$restored=& (Join-Path $workspace 'holographic-control\ops\Control-Lease.ps1') -Mode Stop -RunId $RunId|ConvertFrom-Json;$cleanup.lease_restored=[bool]$restored.Restored;Save 'lease-stop.json' $restored}catch{$cleanup.errors+=@{stage='lease';type=$_.Exception.GetType().Name;message=$_.Exception.Message}}}
 Save 'cleanup.json' $cleanup;Emit 'cleanup' $cleanup
 $mutex.ReleaseMutex();$mutex.Dispose()
}
