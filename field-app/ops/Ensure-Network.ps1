param([string]$EvidenceDirectory)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$workspace=Split-Path -Parent $root
. (Join-Path $workspace 'HoloLens.Common.ps1')
. (Join-Path $PSScriptRoot 'Field.NetworkPolicy.ps1')
if(-not $EvidenceDirectory){$EvidenceDirectory=Join-Path $root ('.state\network-check-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[Guid]::NewGuid().ToString('N').Substring(0,6))}
[IO.Directory]::CreateDirectory($EvidenceDirectory)|Out-Null
$remoteBase='U:\Users\DefaultAccount\AppData\Local\DevelopmentFiles\RiceHoloLensFieldV1'

function Invoke-FieldNetworkHelper([string]$Name,[string]$Local,[string]$Arguments){
    $hash=(Get-FileHash -LiteralPath $Local).Hash
    $remote=$remoteBase+'\network-check-'+$Name+'-'+$hash.Substring(0,8)+'.exe'
    if(-not(Invoke-HlBridge @{action='stat';path=$remote}).Exists){Invoke-HlBridge @{action='put';local=$Local;path=$remote}|Out-Null}
    $report=$remoteBase+'\network-check-'+[Guid]::NewGuid().ToString('N')+'.json'
    $reply=Invoke-HlBridge @{action='exec';executable='C:\Windows\System32\DevToolsLauncher.exe';arguments=('LaunchForDebug '+$remote+' "'+$Arguments+' --out '+$report+'" Rice.HoloLens.Field_r5420n6798s24!Field')}
    if($reply.ExitCode -ne 0){throw ('Network helper did not launch: '+$Name)}
    $result=$null
    for($i=0;$i -lt 60;$i++){
        Start-Sleep -Milliseconds 250
        $stat=Invoke-HlBridge @{action='stat';path=$report}
        if($stat.Exists -and $stat.Length -gt 0){$result=(Invoke-HlBridge @{action='cat';path=$report}).Text|ConvertFrom-Json;break}
    }
    if(-not $result){throw ('Network helper result is pending: '+$Name)}
    [IO.File]::WriteAllText((Join-Path $EvidenceDirectory ($Name+'.json')),($result|ConvertTo-Json -Depth 9),[Text.UTF8Encoding]::new($false))
    return $result
}

$healthExe=Join-Path $root '.state\network-probe\hl-field-network.exe'
$wifiExe=Join-Path $workspace 'capture-app\device-research\bin\arm64\hl-wifi-connect.exe'
$first=Invoke-FieldNetworkHelper 'health-before' $healthExe ''
$health=$first;$recoveryAttempted=$false;$reason='service_ready'
if($first.httpStatus -ne 200){
    $wifi=Invoke-FieldNetworkHelper 'wifi-inspect' $wifiExe '--scan'
    $decision=Get-FieldWifiRecoveryDecision $wifi
    [IO.File]::WriteAllText((Join-Path $EvidenceDirectory 'recovery-decision.json'),($decision|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    $reason=$decision.Reason
    if($decision.CanRecover){
        # Re-select only the already saved NJAU profile. Do not enable radios,
        # change another network, create a profile, or submit account credentials.
        $recoveryAttempted=$true
        Invoke-FieldNetworkHelper 'wifi-reselect' $wifiExe '--connect-open'|Out-Null
        $health=Invoke-FieldNetworkHelper 'health-after' $healthExe ''
        $reason=if($health.httpStatus -eq 200){'saved_njau_reselected_service_ready'}else{'service_still_unavailable'}
    }
}
$proof=[ordered]@{CheckedAt=[DateTimeOffset]::Now.ToString('o');NetworkReady=($health.httpStatus -eq 200);HttpStatus=$health.httpStatus;RecoveryAttempted=$recoveryAttempted;Reason=$reason;Evidence=$EvidenceDirectory;CredentialsRequested=$false}
[IO.File]::WriteAllText((Join-Path $EvidenceDirectory 'status.json'),($proof|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
$proof|ConvertTo-Json -Compress
