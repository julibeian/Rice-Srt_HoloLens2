# Pure result validation. This file neither submits requests nor replays operations.
$script:Phase2ResultSchema=Join-Path (Split-Path -Parent $PSScriptRoot) 'contracts\operation-result.schema.json'
function Assert-Phase2Result {
    param([Parameter(Mandatory)]$Result,[string]$EvidenceRoot)
    $text=$Result|ConvertTo-Json -Depth 16
    if(-not(Test-Json -Json $text -SchemaFile $script:Phase2ResultSchema -ErrorAction Stop)){throw 'Invalid operation result.'}
    if($Result.ended_at -and [DateTimeOffset]::Parse($Result.ended_at) -lt [DateTimeOffset]::Parse($Result.started_at)){throw 'End precedes start.'}
    if($EvidenceRoot){
        $references=@($Result.device_identity_ref,$Result.source_manifest_ref)+@($Result.readback_evidence)+@($Result.cleanup.evidence)
        foreach($layer in @('request','transport','device_state','visible_effect')){$references+=@($Result.layers.$layer.evidence)}
        foreach($reference in $references){$file=([string]$reference).Split('#')[0];if(-not(Test-Path -LiteralPath ([IO.Path]::GetFullPath($file,$EvidenceRoot)) -PathType Leaf)){throw ('Missing evidence file: '+$file)}}
    }
}
function Write-Phase2Result {
    param([Parameter(Mandatory)]$Result,[Parameter(Mandatory)][string]$Path,[string]$EvidenceRoot)
    Assert-Phase2Result $Result -EvidenceRoot $EvidenceRoot
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($Result|ConvertTo-Json -Depth 16))
    # Immutable observations: an unknown result is followed by another observation,
    # never rewritten as success and never used as authorization to submit again.
    $stream=[IO.File]::Open([IO.Path]::GetFullPath($Path),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try{$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}
}
