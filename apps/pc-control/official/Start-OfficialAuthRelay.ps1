param(
    [ValidateSet('Start','Status','Stop')][string]$Mode='Status',
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_-]{1,55}$')][string]$RunId,
    [int]$OfficialProcessId,
    [ValidatePattern('^[A-Za-z0-9_-]{1,64}$')][string]$LeaseRunId,
    [ValidateRange(0,65535)][int]$Port
)
$ErrorActionPreference='Stop'
$workspace=Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$folder=Join-Path $workspace ('apps/pc-control/.state/official-relays/'+$RunId)
$checkpoint=Join-Path $folder 'invocation.json'
$readyFile=Join-Path $folder 'ready.json'
if(Test-Path -LiteralPath $checkpoint){
    $invocation=Get-Content -LiteralPath $checkpoint -Raw|ConvertFrom-Json
    if($OfficialProcessId -and $OfficialProcessId -ne $invocation.OfficialProcessId){throw 'This run belongs to another official process.'}
    if($LeaseRunId -and $LeaseRunId -cne $invocation.LeaseRunId){throw 'This run belongs to another named guard.'}
    if($Mode -eq 'Start'){
        $previousEnd=Join-Path $folder 'ended.json'
        if(Test-Path -LiteralPath $previousEnd){
            [pscustomobject]@{State='ended';RunId=$RunId;ReplayAttempted=$false;Result=(Get-Content -LiteralPath $previousEnd -Raw|ConvertFrom-Json);Evidence=$folder}|ConvertTo-Json -Depth 5
        }elseif(Test-Path -LiteralPath $readyFile){
            [pscustomobject]@{State='prior_start_observed';ReplayAttempted=$false;Ready=(Get-Content -LiteralPath $readyFile -Raw|ConvertFrom-Json);Evidence=$folder}|ConvertTo-Json -Depth 4
        }else{'{"State":"prior_start_pending","ReplayAttempted":false}'}
        return
    }
    if($Mode -eq 'Stop'){[IO.File]::WriteAllText((Join-Path $folder 'stop'),'stop')}
    $ended=Join-Path $folder 'ended.json'
    if($Mode -eq 'Stop'){for($i=0;$i -lt 40 -and -not(Test-Path -LiteralPath $ended);$i++){Start-Sleep -Milliseconds 100}}
    if(Test-Path -LiteralPath $ended){Get-Content -LiteralPath $ended -Raw}else{
        [pscustomobject]@{State='running_or_pending';RunId=$RunId;ProcessId=$invocation.ProcessId;ExpiresAt=$invocation.ExpiresAt;Evidence=$folder}|ConvertTo-Json
    }
    return
}
if($Mode -ne 'Start'){throw 'No such relay run.'}
if(-not $OfficialProcessId -or -not $LeaseRunId){throw 'Start requires an exact official process and an active named device guard.'}
$gui=Get-Process -Id $OfficialProcessId
$expected=Join-Path $env:ProgramFiles 'Microsoft Perception Simulation/Control/PerceptionSimulationControl.exe'
if($gui.Path -ine $expected -or (Get-FileHash -LiteralPath $expected).Hash -cne 'B31AA8177BE97AF20D0B3C97E59BB3AD169082920C86CB6BFF0BC0B2F8DDA09D' -or (Get-AuthenticodeSignature -LiteralPath $expected).Status -ne 'Valid'){throw 'The process is not the reviewed signed Microsoft original.'}
$build=& (Join-Path $PSScriptRoot 'Build-OfficialAuthRelay.ps1')|ConvertFrom-Json
. (Join-Path $workspace 'apps/holographic-control/ops/Holographic.Common.ps1')
$context=New-HoloAuthenticatedPortalContext
try{
    $lease=& (Join-Path $workspace 'apps/holographic-control/ops/Control-Lease.ps1') -Mode Status -RunId $LeaseRunId|ConvertFrom-Json
    if(-not $lease.Active){throw 'The named device guard is not active.'}
    $leaseInvocation=Get-Content -LiteralPath (Join-Path $workspace ('apps/holographic-control/.state/control-leases/'+$LeaseRunId+'/invocation.json')) -Raw|ConvertFrom-Json
    $expiry=[DateTimeOffset]::Parse($leaseInvocation.At).AddSeconds(270)
    if($expiry -lt [DateTimeOffset]::Now.AddSeconds(60)){throw 'Too little device guard time remains.'}
    $page=$context.Client.GetAsync($context.BaseUri+'/default.htm').GetAwaiter().GetResult()
    try{if([int]$page.StatusCode -ne 200){throw 'Authenticated portal page unavailable.'}}finally{$page.Dispose()}
    $cookieUri=[uri]($context.BaseUri+'/api/holographic/simulation/control/stream')
    $csrf=$context.Handler.CookieContainer.GetCookies($cookieUri)['CSRF-Token']
    if(-not $csrf){throw 'The verified portal did not issue a CSRF cookie.'}
    [IO.Directory]::CreateDirectory($folder)|Out-Null
    $start=[Diagnostics.ProcessStartInfo]::new($build.Executable)
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $start.StandardInputEncoding=[Text.UTF8Encoding]::new($false)
    $process=[Diagnostics.Process]::Start($start)
    $invocation=[ordered]@{RunId=$RunId;At=[DateTimeOffset]::Now.ToString('o');ProcessId=$process.Id;OfficialProcessId=$gui.Id;OfficialStartTicks=$gui.StartTime.ToUniversalTime().Ticks;OfficialExeSha256=(Get-FileHash -LiteralPath $expected).Hash;LeaseRunId=$LeaseRunId;ExpiresAt=$expiry.ToString('o');Device=$context.Device.DeviceName;Address=$context.Device.Address;SshFingerprint=$context.Device.HostFingerprint;CertificateSha256=$context.CertificateSha256;PublicKeySha256=$context.PublicKeySha256;SourceSha256=$build.SourceSha256;ExecutableSha256=$build.ExecutableSha256;RequestedPort=$Port;SecretsVia='private_stdin';OfficialGuiVideoVerified=$false;OfficialGuiInputVerified=$false}
    [IO.File]::WriteAllText($checkpoint,($invocation|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    $configuration=@{OfficialProcessId=$gui.Id;OfficialStartTicks=$invocation.OfficialStartTicks;Port=$Port;Address=$context.Device.Address;CertificateSha256=$context.CertificateSha256;Authorization=$context.Client.DefaultRequestHeaders.Authorization.ToString();Cookie=$context.Handler.CookieContainer.GetCookieHeader($cookieUri);CsrfToken=$csrf.Value;ExpiresAt=$expiry.ToString('o');Folder=$folder}
    $process.StandardInput.WriteLine(($configuration|ConvertTo-Json -Compress));$process.StandardInput.Close();$configuration=$null
    $pending=$process.StandardOutput.ReadLineAsync()
    if(-not $pending.Wait(10000)){$process.Kill();throw 'Relay readiness timed out; do not replay this run.'}
    $ready=$pending.GetAwaiter().GetResult()|ConvertFrom-Json
    $ready|Add-Member -NotePropertyName RunId -NotePropertyValue $RunId
    $ready|Add-Member -NotePropertyName Evidence -NotePropertyValue $folder
    [IO.File]::WriteAllText($readyFile,($ready|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    $ready|ConvertTo-Json
    if($ready.state -ne 'ready'){exit 2}
}finally{$context.Client.Dispose()}
