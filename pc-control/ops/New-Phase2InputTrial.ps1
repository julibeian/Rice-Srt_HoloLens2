param(
 [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_-]{1,64}$')][string]$RunId,
 [Parameter(Mandatory)][ValidateSet('direct-sdk','custom-adapter','official-gui')][string]$Route,
 [Parameter(Mandatory)][ValidateSet('shell','settings','independent-app','browser','3d-app')][string]$Scenario,
 [Parameter(Mandatory)][string]$TargetIdentity
)
$ErrorActionPreference='Stop'
$workspace=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$folder=Join-Path $workspace ('reports\phase2-full-control\'+$RunId)
$path=Join-Path $folder 'trial.json'
if(Test-Path -LiteralPath $path){Get-Content -LiteralPath $path -Raw;exit}
if(Test-Path -LiteralPath $folder){throw 'Partial trial exists; inspect original evidence.'}
. (Join-Path $workspace 'holographic-control\ops\Holographic.Common.ps1')
$context=New-HoloAuthenticatedPortalContext
try{
 [IO.Directory]::CreateDirectory((Join-Path $folder 'source'))|Out-Null
 [IO.Directory]::CreateDirectory((Join-Path $folder 'observations'))|Out-Null
 $sources=@(Get-ChildItem -LiteralPath (Join-Path $workspace 'pc-control\input-probe'),(Join-Path $workspace 'holographic-control\desktop'),(Join-Path $workspace 'pc-control\official'),(Join-Path $workspace 'pc-control\ops') -File -Recurse|Where-Object {$_.Extension -in @('.ps1','.cs','.js','.css','.html','.xml')})
 $manifest=@(foreach($file in $sources){$relative=[IO.Path]::GetRelativePath($workspace,$file.FullName);$dest=Join-Path $folder ('source\'+$relative);[IO.Directory]::CreateDirectory((Split-Path -Parent $dest))|Out-Null;Copy-Item -LiteralPath $file.FullName -Destination $dest;$hash=(Get-FileHash -LiteralPath $file.FullName).Hash;if((Get-FileHash -LiteralPath $dest).Hash -cne $hash){throw 'Source changed during trial freeze.'};@{path=$relative.Replace('\','/');sha256=$hash}})
 $modeResponse=$context.Client.GetAsync($context.BaseUri+'/api/holographic/simulation/control/mode').GetAwaiter().GetResult()
 try{if([int]$modeResponse.StatusCode -ne 200){throw 'Mode observation unavailable.'};$mode=$modeResponse.Content.ReadAsStringAsync().GetAwaiter().GetResult()|ConvertFrom-Json}finally{$modeResponse.Dispose()}
 $trial=[ordered]@{schema_version=1;run_id=$RunId;started_at=[DateTimeOffset]::Now.ToString('o');route=$Route;scenario=$Scenario;target=$TargetIdentity;device=$context.Device.DeviceName;ssh_fingerprint=$context.Device.HostFingerprint;certificate_sha256=$context.CertificateSha256;initial_mode=$mode;source_manifest=$manifest;control_started=$false;visible_effect_verified=$false;result='not_run';scope='Recorder only; this command submits no input. Before/after frames, input response, target state and cleanup are independent observations.'}
 [IO.File]::WriteAllText($path,($trial|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
 [ordered]@{run_id=$RunId;folder=$folder;route=$Route;scenario=$Scenario;initial_mode=$mode;source_files=$manifest.Count;device_mutations=0}|ConvertTo-Json
}finally{$context.Client.Dispose()}
