param(
 [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_-]{1,64}$')][string]$RunId,
 [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_-]{1,64}$')][string]$ObservationId,
 [Parameter(Mandatory)][ValidateSet('before','input','after','device-state','gui-focus','cleanup','decision')][string]$Kind,
 [Parameter(Mandatory)][string]$EvidencePath,
 [Parameter(Mandatory)][string]$Summary
)
$ErrorActionPreference='Stop'
$workspace=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$folder=Join-Path $workspace ('reports\phase2-full-control\'+$RunId)
$trial=Get-Content -LiteralPath (Join-Path $folder 'trial.json') -Raw|ConvertFrom-Json
if($trial.schema_version -ne 1 -or $trial.run_id -cne $RunId){throw 'Observation belongs to a different trial.'}
$receipt=Join-Path $folder ('observations\'+$ObservationId+'.json')
if(Test-Path -LiteralPath $receipt){Get-Content -LiteralPath $receipt -Raw;exit}
$extension=[IO.Path]::GetExtension($EvidencePath).ToLowerInvariant()
if($extension -notin @('.json','.jsonl','.png','.mp4','.txt')){throw 'Only explicit observation formats may be archived.'}
$destination=Join-Path $folder ('observations\'+$ObservationId+'.evidence'+$extension)
[IO.File]::Copy([IO.Path]::GetFullPath($EvidencePath),$destination,$false)
$hash=(Get-FileHash -LiteralPath $EvidencePath).Hash
if((Get-FileHash -LiteralPath $destination).Hash -cne $hash){throw 'Evidence changed during archival.'}
$value=[ordered]@{schema_version=1;run_id=$RunId;observation_id=$ObservationId;kind=$Kind;recorded_at=[DateTimeOffset]::Now.ToString('o');original_path=[IO.Path]::GetFullPath($EvidencePath);archived_path=[IO.Path]::GetRelativePath($folder,$destination);bytes=(Get-Item -LiteralPath $destination).Length;sha256=$hash;summary=$Summary;device_input_sent_by_recorder=$false}
$stream=[IO.File]::Open($receipt,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
try{$bytes=[Text.UTF8Encoding]::new($false).GetBytes(($value|ConvertTo-Json -Depth 5));$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}
$value|ConvertTo-Json
