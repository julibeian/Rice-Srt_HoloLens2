$ErrorActionPreference='Stop'
$workspace=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$run='status-fixture-'+[guid]::NewGuid().ToString('N')
$folder=Join-Path $workspace ('pc-control\.state\application-operations\'+$run)
$script=Join-Path $workspace 'pc-control\ops\Invoke-Applications.ps1'
$pwsh=Join-Path $workspace 'runtime\powershell\pwsh.exe'
$result=& $pwsh -NoProfile -File $script -Action Status -RunId $run -Aumid 'never-submitted' -PackageFullName 'never-submitted'|ConvertFrom-Json
if($result.State -cne 'not_submitted' -or $result.ReplayAttempted -or (Test-Path -LiteralPath $folder)){throw 'Status of a missing operation must not submit or create an operation.'}
[IO.Directory]::CreateDirectory($folder)|Out-Null
$utf8=[Text.UTF8Encoding]::new($false)
try{
 [IO.File]::WriteAllText((Join-Path $folder 'invocation.json'),(@{action='Launch';aumid='fixture';package_full_name='fixture';operation_id=$run}|ConvertTo-Json),$utf8)
 $result=& $pwsh -NoProfile -File $script -Action Status -RunId $run -Aumid fixture -PackageFullName fixture|ConvertFrom-Json
 if($result.State -cne 'outcome_unknown' -or $result.ReplayAttempted -or (Get-ChildItem -LiteralPath $folder -File).Count -ne 1){throw 'A pending operation query must not enter the request path.'}
 [IO.File]::WriteAllText((Join-Path $folder 'result.json'),(@{ok=$true;State='activation_accepted';OperationId=$run;ReplayAttempted=$false}|ConvertTo-Json),$utf8)
 $hash=(Get-FileHash -LiteralPath (Join-Path $folder 'result.json')).Hash
 $result=& $pwsh -NoProfile -File $script -Action Status -RunId $run -Aumid fixture -PackageFullName fixture|ConvertFrom-Json
 if($result.State -cne 'activation_accepted' -or (Get-FileHash -LiteralPath (Join-Path $folder 'result.json')).Hash -cne $hash){throw 'Status query must retain the original result.'}
}finally{
 $resolved=[IO.Path]::GetFullPath($folder);$allowed=[IO.Path]::GetFullPath((Join-Path $workspace 'pc-control\.state\application-operations'))+[IO.Path]::DirectorySeparatorChar
 if(-not $resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolved) -cne $run){throw 'Unsafe status fixture cleanup.'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
}
@{passed=3;device_operations=0}|ConvertTo-Json
