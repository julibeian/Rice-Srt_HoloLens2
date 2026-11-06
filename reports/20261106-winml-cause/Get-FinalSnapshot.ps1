param([Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_-]{1,40}$')][string]$RunId)
$ErrorActionPreference='Stop'
$workspace=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $workspace 'apps/holographic-control/ops/Holographic.Common.ps1')
$folder=Join-Path $PSScriptRoot 'final'
[IO.Directory]::CreateDirectory($folder)|Out-Null
$context=New-HoloAuthenticatedPortalContext
try{
 $state=[ordered]@{at=[DateTimeOffset]::Now.ToString('o');run_id=$RunId;device=$context.Device.DeviceName;fingerprint=$context.Device.HostFingerprint;public_key=$context.PublicKeySha256}
 foreach($pair in @(@('mode','/api/holographic/simulation/control/mode'),@('mrc','/api/holographic/mrc/status'),@('power','/api/power/state'),@('battery','/api/power/battery'),@('thermal','/api/holographic/thermal/stage'),@('mitigation','/api/holographic/thermal/getMitigationLevels'))){
  $response=$context.Client.GetAsync($context.BaseUri+$pair[1]).GetAwaiter().GetResult()
  try{$raw=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult();$state[$pair[0]]=@{status=[int]$response.StatusCode;body=($raw|ConvertFrom-Json)}}finally{$response.Dispose()}
 }
 $state|ConvertTo-Json -Depth 20|Set-Content -LiteralPath (Join-Path $folder ($RunId+'.json')) -Encoding utf8NoBOM
 Write-Output ($state|ConvertTo-Json -Depth 4 -Compress)
}finally{$context.Client.Dispose()}
