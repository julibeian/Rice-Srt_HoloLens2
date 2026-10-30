$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\ops\Phase2.Results.ps1')
$count=0
function Check($Condition,[string]$Label){if(-not $Condition){throw $Label};$script:count++}
function Reject($Result,[string]$Label){$failed=$false;try{Assert-Phase2Result $Result}catch{$failed=$true};Check $failed $Label}
function Layer($Status,$Evidence){@{status=$Status;evidence=@($Evidence)}}
function Example {
    @{schema_version=1;operation_id='schema-test';session_id='test';device_identity_ref='environment.json#/device';source_manifest_ref='source-manifest.json';kind='input';target=@{type='control';identity='observed-target'};parameters_sha256=('0'*64);started_at='2026-10-27T20:00:00+08:00';ended_at='2026-10-27T20:00:01+08:00';status='unknown';layers=@{request=(Layer passed 'request.json');transport=(Layer passed 'http-200.json');device_state=(Layer unknown @());visible_effect=(Layer unknown @())};readback_evidence=@();error=@{code='no_visible_result';message='HTTP success does not prove a selection.'};cleanup=@{status='verified';evidence=@('lease-default-0.json')}}
}
$r=Example;Assert-Phase2Result $r;Check $true 'unknown result preserves protocol success'
$r=Example;$r.status='completed';$r.error=$null;Reject $r 'HTTP 200 cannot complete input'
$r=Example;$r.status='completed';$r.error=$null;$r.layers.device_state=Layer passed 'state.json';$r.layers.visible_effect=Layer passed @('before.png','after.png');Assert-Phase2Result $r;Check $true 'visible input plus restoration accepted'
$r.cleanup.status='pending';Reject $r 'input completion needs verified cleanup'
$r=Example;$r.layers.transport.evidence=@();Reject $r 'passed layer requires evidence'
$r=Example;$r.kind='management';$r.status='completed';$r.error=$null;$r.layers.device_state=Layer passed 'state.json';Reject $r 'management completion needs readback'
$r.readback_evidence=@('readback.json');Assert-Phase2Result $r;Check $true 'management readback accepted'
$r=Example;$r.ended_at='2026-10-27T19:59:59+08:00';Reject $r 'time cannot run backwards'
$r=Example;$r.password='do-not-record';Reject $r 'unknown fields rejected'
$r=Example;$r.error=$null;Reject $r 'unknown result requires explicit error'
$temp=Join-Path ([IO.Path]::GetTempPath()) ('p2-result-'+[guid]::NewGuid().ToString('N')+'.json')
try{Write-Phase2Result (Example) $temp;$original=(Get-FileHash -LiteralPath $temp).Hash;$rejected=$false;try{Write-Phase2Result (Example) $temp}catch{$rejected=$true};Check ($rejected -and (Get-FileHash -LiteralPath $temp).Hash -ceq $original) 'existing observations remain immutable'}finally{Remove-Item -LiteralPath $temp -ErrorAction SilentlyContinue}
[ordered]@{passed=$count;device_operations=0}|ConvertTo-Json
