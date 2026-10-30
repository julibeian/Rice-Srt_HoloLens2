param([Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_-]{1,64}$')][string]$RunId)
$ErrorActionPreference='Stop'
$workspace=Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$folder=Join-Path $workspace ('reports\phase2-full-control\'+$RunId)
$receipt=Join-Path $folder 'source-manifest.json'
if(Test-Path -LiteralPath $receipt){Get-Content -LiteralPath $receipt -Raw;exit}
if(Test-Path -LiteralPath $folder){throw 'Partial baseline exists; inspect it instead of overwriting evidence.'}
[IO.Directory]::CreateDirectory((Join-Path $folder 'source'))|Out-Null
$utf8=[Text.UTF8Encoding]::new($false)
function Write-Json($Path,$Value){[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 12),$utf8)}
$head=(& git -C $workspace rev-parse HEAD).Trim()
if($LASTEXITCODE){throw 'Cannot identify Git baseline.'}
$status=@(& git -c core.quotepath=false -C $workspace status --short)
[IO.File]::WriteAllLines((Join-Path $folder 'git-status.txt'),$status,$utf8)
[IO.File]::WriteAllLines((Join-Path $folder 'unstaged.patch'),@(& git -c core.quotepath=false -C $workspace diff --binary),$utf8)
[IO.File]::WriteAllLines((Join-Path $folder 'staged.patch'),@(& git -c core.quotepath=false -C $workspace diff --cached --binary),$utf8)
$paths=@(& git -c core.quotepath=false -C $workspace ls-files --cached --others --exclude-standard)|Sort-Object -Unique
if($LASTEXITCODE){throw 'Cannot enumerate source baseline.'}
$files=@(foreach($relative in $paths){
    $source=Join-Path $workspace $relative
    if(-not(Test-Path -LiteralPath $source -PathType Leaf)){continue}
    # Git ignored configuration, credentials, binaries and raw runs are never copied.
    $destination=Join-Path $folder ('source\'+$relative)
    [IO.Directory]::CreateDirectory((Split-Path -Parent $destination))|Out-Null
    Copy-Item -LiteralPath $source -Destination $destination
    $hash=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
    if((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -cne $hash){throw ('Source changed during snapshot: '+$relative)}
    [ordered]@{path=$relative.Replace('\','/');bytes=(Get-Item -LiteralPath $destination).Length;sha256=$hash;snapshot=('source/'+$relative.Replace('\','/'))}
})
$instructions=Join-Path $workspace 'AGENTS.md'
Copy-Item -LiteralPath $instructions -Destination (Join-Path $folder 'local-instructions.md')
$historicalFolder=Join-Path $workspace 'reports\20261027-official-focus\官方GUI连接交付'
$historicalManifest=Join-Path $historicalFolder '证据清单.json'
$historical=Get-Content -LiteralPath $historicalManifest -Raw|ConvertFrom-Json
$checks=@(foreach($entry in $historical.files){
    $path=Join-Path $historicalFolder $entry.path
    $exists=Test-Path -LiteralPath $path -PathType Leaf
    $actual=if($exists){(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash}else{$null}
    [ordered]@{path=$entry.path;exists=$exists;expected=$entry.sha256;actual=$actual;match=($exists -and $actual -ceq $entry.sha256 -and (Get-Item -LiteralPath $path).Length -eq $entry.bytes)}
})
Write-Json (Join-Path $folder 'historical-verification.json') ([ordered]@{at=[DateTimeOffset]::Now.ToString('o');source='reports/20261027-official-focus/官方GUI连接交付/证据清单.json';manifest_sha256=(Get-FileHash -LiteralPath $historicalManifest).Hash;checks=$checks;all_match=(@($checks|Where-Object {-not $_.match}).Count -eq 0);scope='Frozen historical delivery only; no new device acceptance.'})
$index=@(
    @{path='reports/20261027-official-focus/官方GUI连接交付/README.md';scope='Official video, normal stop, process interruption and restart are historical; effective GUI selection is unverified.'},
    @{path='reports/20261027-official-focus/官方GUI连接交付/过程记录.md';scope='Chronological observations; do not infer one root cause from latest failure.'},
    @{path='reports/20261024-device-acceptance/验收进度.md';scope='Historical USB recovery and non-leaf application pipeline; not whole-device acceptance.'},
    @{path='reports/20261025-apps/pc-control/验收记录.md';scope='Custom backend control evidence; complete Windows GUI flow remains unverified.'}
)|ForEach-Object {[ordered]@{path=$_.path;scope=$_.scope;sha256=(Get-FileHash -LiteralPath (Join-Path $workspace $_.path)).Hash}}
Write-Json (Join-Path $folder 'evidence-index.json') $index
$result=[ordered]@{schema_version=1;run_id=$RunId;created_at=[DateTimeOffset]::Now.ToString('o');head=$head;dirty=($status.Count -gt 0);git_status=$status;source_count=$files.Count;files=$files;local_instructions_sha256=(Get-FileHash -LiteralPath $instructions).Hash;historical_manifest_verified=(@($checks|Where-Object {-not $_.match}).Count -eq 0);excluded='Git-ignored local credentials, configuration, dependencies and raw device data. Baseline is local and not published.';device_mutations=0}
Write-Json $receipt $result
[ordered]@{run_id=$RunId;folder=$folder;head=$head;source_count=$files.Count;historical_files=$checks.Count;historical_manifest_verified=$result.historical_manifest_verified;device_mutations=0}|ConvertTo-Json
