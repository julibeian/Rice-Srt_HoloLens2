param([Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_-]{1,64}$')][string]$RunId,[ValidateRange(10,600)][int]$Seconds=120)
$ErrorActionPreference='Stop'
$appRoot=Split-Path -Parent $PSScriptRoot;$workspace=Split-Path -Parent (Split-Path -Parent $appRoot)
. (Join-Path $workspace 'apps/holographic-control/ops/Holographic.Common.ps1')
$folder=Join-Path $workspace ('reports/20261106-winml-cause/idle/'+$RunId)
if(Test-Path -LiteralPath $folder){throw 'Use a new RunId'}
[IO.Directory]::CreateDirectory($folder)|Out-Null
$context=New-HoloAuthenticatedPortalContext;$stream=[IO.StreamWriter]::new((Join-Path $folder 'samples.jsonl'),$false,[Text.UTF8Encoding]::new($false));$stream.AutoFlush=$true
try{
 $clock=[Diagnostics.Stopwatch]::StartNew();$health=$null;$nextHealth=0
 while($clock.Elapsed.TotalSeconds -lt $Seconds){
  $row=[ordered]@{at=[DateTimeOffset]::Now.ToString('o');elapsed_ms=$clock.Elapsed.TotalMilliseconds}
  $paths=@{perf='/api/resourcemanager/systemperf'}
  if($clock.Elapsed.TotalSeconds -ge $nextHealth){$paths.power='/api/power/state';$paths.thermal='/api/holographic/thermal/stage';$paths.mitigation='/api/holographic/thermal/getMitigationLevels';$paths.battery='/api/power/battery';$nextHealth+=10}
  foreach($key in $paths.Keys){$response=$context.Client.GetAsync($context.BaseUri+$paths[$key]).GetAwaiter().GetResult();try{$raw=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult();$row[$key]=@{status=[int]$response.StatusCode;body=($raw|ConvertFrom-Json)}}finally{$response.Dispose()}}
  $stream.WriteLine(($row|ConvertTo-Json -Depth 25 -Compress));if([int]$clock.Elapsed.TotalSeconds%30 -eq 0){Write-Output ('Idle '+[int]$clock.Elapsed.TotalSeconds+'s; GPU0 '+$row.perf.body.GPUData.AvailableAdapters[0].EnginesUtilization[0])};Start-Sleep -Milliseconds 950
 }
}finally{$stream.Dispose();$context.Client.Dispose()}
