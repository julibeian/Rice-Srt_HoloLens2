$ErrorActionPreference='Stop'
$workspace=Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$run='recorder-fixture-'+[guid]::NewGuid().ToString('N')
$fixture=Join-Path $workspace ('reports\phase2-full-control\'+$run)
[IO.Directory]::CreateDirectory((Join-Path $fixture 'observations'))|Out-Null
$utf8=[Text.UTF8Encoding]::new($false);$count=0
function Check($Condition,$Label){if(-not $Condition){throw $Label};$script:count++}
try{
 [IO.File]::WriteAllText((Join-Path $fixture 'trial.json'),(@{schema_version=1;run_id=$run}|ConvertTo-Json),$utf8)
 $evidence=Join-Path $fixture 'source.txt';[IO.File]::WriteAllText($evidence,'original',$utf8)
 $script=Join-Path $workspace 'apps/pc-control\ops\Add-Phase2Observation.ps1'
 $first=& $script -RunId $run -ObservationId example -Kind before -EvidencePath $evidence -Summary 'offline fixture'|ConvertFrom-Json
 [IO.File]::WriteAllText($evidence,'later',$utf8)
 $again=& $script -RunId $run -ObservationId example -Kind before -EvidencePath $evidence -Summary 'offline fixture'|ConvertFrom-Json
 Check ($first.sha256 -ceq $again.sha256 -and [IO.File]::ReadAllText((Join-Path $fixture $again.archived_path)) -ceq 'original') 'Repeated observation retrieves original immutable evidence'
 $partial=Join-Path $fixture 'observations\partial.evidence.txt';[IO.File]::WriteAllText($partial,'preserve',$utf8)
 $failed=$false;try{& $script -RunId $run -ObservationId partial -Kind after -EvidencePath $evidence -Summary 'offline fixture'|Out-Null}catch{$failed=$true}
 Check ($failed -and [IO.File]::ReadAllText($partial) -ceq 'preserve') 'Partial archival cannot overwrite existing bytes'
 [IO.File]::WriteAllText((Join-Path $fixture 'trial.json'),(@{schema_version=1;run_id='different'}|ConvertTo-Json),$utf8)
 $failed=$false;try{& $script -RunId $run -ObservationId mismatch -Kind after -EvidencePath $evidence -Summary 'offline fixture'|Out-Null}catch{$failed=$true}
 Check $failed 'Mismatched trial identity rejected'
}finally{
 $resolved=[IO.Path]::GetFullPath($fixture);$allowed=[IO.Path]::GetFullPath((Join-Path $workspace 'reports\phase2-full-control'))+[IO.Path]::DirectorySeparatorChar
 if(-not $resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolved) -cne $run){throw 'Unsafe test cleanup target.'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
}
@{passed=$count;device_operations=0}|ConvertTo-Json
