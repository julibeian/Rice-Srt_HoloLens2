param(
    [ValidateSet('Status','Start','Stop')][string]$Mode='Status',
    [ValidatePattern('^[A-Za-z0-9_-]{1,64}$')][string]$RunId
)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$workspace=Split-Path -Parent $root
. (Join-Path $workspace 'HoloLens.Common.ps1')
$base='U:\Users\DefaultAccount\AppData\Local\DevelopmentFiles\RiceHoloLensFieldV1'
if(-not $RunId){throw 'Provide a named run; repeated names only inspect the existing lease.'}
$folder=Join-Path $root ('.state\control-leases\'+$RunId)
$checkpoint=Join-Path $folder 'invocation.json'
$device=Invoke-HlBridge @{action='info'}
if($device.DeviceName -cne $script:HlConfig.DeviceName -or $device.HostFingerprint -cne $script:HlConfig.ExpectedFingerprint){throw 'Unexpected USB identity.'}
if(Test-Path -LiteralPath $checkpoint){
    $invocation=Get-Content -LiteralPath $checkpoint -Raw|ConvertFrom-Json
    if($invocation.RemoteReport -cne ($base+'\'+$RunId+'.json') -or $invocation.StopFile -cne ($base+'\'+$RunId+'.json.stop')){throw 'Unexpected lease report or stop path.'}
}else{
    if($Mode -ne 'Start'){throw 'No such control lease.'}
    [IO.Directory]::CreateDirectory($folder)|Out-Null
    & (Join-Path $PSScriptRoot 'Build-SimulationLease.ps1')|Out-Null
    $exe=Join-Path $root '.state\probe\arm64\hl-simulation-lease.exe'
    $hash=(Get-FileHash -LiteralPath $exe).Hash
    $remote=$base+'\hl-control-lease-'+$hash.Substring(0,16)+'.exe'
    if(-not(Invoke-HlBridge @{action='stat';path=$remote}).Exists){Invoke-HlBridge @{action='put';local=$exe;path=$remote}|Out-Null}
    $copy=Join-Path $folder 'worker.exe';Invoke-HlBridge @{action='get';path=$remote;local=$copy}|Out-Null
    if((Get-FileHash -LiteralPath $copy).Hash -cne $hash){throw 'Mode guard hash mismatch.'}
    $out=$base+'\'+$RunId+'.json'
    if((Invoke-HlBridge @{action='stat';path=$out}).Exists -or (Invoke-HlBridge @{action='stat';path=($out+'.stop')}).Exists){throw 'This run name already exists on the device.'}
    $invocation=[pscustomobject]@{RunId=$RunId;At=[DateTimeOffset]::Now.ToString('o');Device=$device.DeviceName;SshFingerprint=$device.HostFingerprint;RemoteReport=$out;StopFile=($out+'.stop');WorkerSha256=$hash;LeaseSeconds=300;RestoreMode=0;LaunchAttempted=$true}
    [IO.File]::WriteAllText($checkpoint,($invocation|ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
    $launch=Invoke-HlBridge @{action='exec';executable='C:\Windows\System32\DevToolsLauncher.exe';arguments=('LaunchForDebug '+$remote+' "--test-300-seconds --out '+$out+'" Rice.HoloLens.Field_r5420n6798s24!Field')}
    [IO.File]::WriteAllText((Join-Path $folder 'launch.json'),($launch|ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
    if($launch.ExitCode -ne 0){throw 'Mode guard launch failed; do not replay this run.'}
}
if($invocation.PSObject.Properties['SshFingerprint'] -and $invocation.SshFingerprint -cne $device.HostFingerprint){throw 'This lease belongs to another device.'}
if($Mode -eq 'Stop' -and -not(Invoke-HlBridge @{action='stat';path=$invocation.StopFile}).Exists){
    $stop=Join-Path $folder 'stop.txt';[IO.File]::WriteAllText($stop,'stop')
    Invoke-HlBridge @{action='put';local=$stop;path=$invocation.StopFile}|Out-Null
}
$result=$null
for($i=0;$i -lt 24;$i++){
    $stat=Invoke-HlBridge @{action='stat';path=$invocation.RemoteReport}
    if($stat.Exists -and $stat.Length -gt 0){
        $result=(Invoke-HlBridge @{action='cat';path=$invocation.RemoteReport}).Text|ConvertFrom-Json
        if($Mode -ne 'Stop' -or $result.phase -eq 'restored'){break}
    }
    Start-Sleep -Milliseconds 200
}
if(-not $result){throw 'Lease observation pending; inspect the same named run without replaying it.'}
$restored=$result.phase -eq 'restored' -and $result.currentMode -eq $result.previousMode -and $result.restore -eq '0x00000000'
$proof=[ordered]@{RunId=$RunId;At=[DateTimeOffset]::Now.ToString('o');Active=($result.phase -eq 'test_active' -and $result.currentMode -eq 1);Restored=[bool]$restored;Report=$result;Evidence=$folder;ReplaySafe=$true}
[IO.File]::WriteAllText((Join-Path $folder 'result.json'),($proof|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
$proof|ConvertTo-Json -Depth 6
if($Mode -eq 'Stop' -and -not $restored){throw 'Mode restoration not yet verified; inspect the same run.'}
