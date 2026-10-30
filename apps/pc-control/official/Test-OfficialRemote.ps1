param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_-]{1,55}$')][string]$RunId,
    [ValidateSet('https','http')][string]$Protocol='https',
    [ValidateSet('Native','Legacy')][string]$ClientKind='Legacy',
    [switch]$Direct
)
$ErrorActionPreference='Stop'
$workspace=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$folder=Join-Path $workspace ('apps/pc-control/.state/official-tests/'+$RunId)
$checkpoint=Join-Path $folder 'invocation.json'
$resultPath=Join-Path $folder 'result.json'
if(Test-Path -LiteralPath $checkpoint){
    $prior=Get-Content -LiteralPath $checkpoint -Raw|ConvertFrom-Json
    if($prior.Protocol -cne $Protocol){throw 'This run belongs to another transport.'}
    $priorKind=if($prior.PSObject.Properties['ClientKind']){$prior.ClientKind}else{'Native'}
    if($priorKind -cne $ClientKind){throw 'This run belongs to another official client.'}
    if([bool]$prior.Direct -ne [bool]$Direct){throw 'This run belongs to another proxy mode.'}
    if(Test-Path -LiteralPath $resultPath){
        $saved=Get-Content -LiteralPath $resultPath -Raw;$saved
        $savedResult=$saved|ConvertFrom-Json
        if($savedResult.ExitCode){exit $savedResult.ExitCode};return
    }
    [ordered]@{RunId=$RunId;State='prior_attempt_pending';ReplayAttempted=$false;Evidence=$folder}|ConvertTo-Json
    return
}
$installed=Join-Path $env:ProgramFiles 'Microsoft Perception Simulation/Sdk/References'
if((Get-FileHash -LiteralPath (Join-Path $installed 'PerceptionSimulationManager.dll')).Hash -cne '7CA60202EC55309102FC0E54837576475416A383809A7024BAAE891107E25B1C'){throw 'Unexpected official SDK.'}
$runtime=Join-Path $workspace 'apps/pc-control/.state/official-remote-x64'
[IO.Directory]::CreateDirectory($runtime)|Out-Null
$vendorFiles=@(foreach($dll in Get-ChildItem -LiteralPath $installed -Filter '*.dll' -File){
    Copy-Item -LiteralPath $dll.FullName -Destination (Join-Path $runtime $dll.Name) -Force
    [pscustomobject]@{Name=$dll.Name;SHA256=(Get-FileHash -LiteralPath $dll.FullName).Hash}
})
$exe=Join-Path $runtime 'OfficialRemoteProbe.exe'
$compiler=Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
$arguments=@('/nologo','/utf8output','/platform:x64','/target:exe','/r:System.Web.Extensions.dll',('/out:'+$exe))
foreach($dll in @('SimulationStream.Interop.dll','PerceptionSimulation.Interop.dll','PerceptionSimulationManager.Interop.dll','PerceptionSimulationRest.dll')){$arguments+='/r:'+(Join-Path $runtime $dll)}
$arguments+=Join-Path $PSScriptRoot 'OfficialRemoteProbe.cs'
$compile=@(& $compiler @arguments 2>&1)
if($LASTEXITCODE){throw ('Official remote probe compile failed: '+($compile -join [Environment]::NewLine))}
. (Join-Path $workspace 'apps/holographic-control/ops/Holographic.Common.ps1')
$context=New-HoloAuthenticatedPortalContext
$leaseRun='guard-'+$RunId
$process=$null;$leaseAttempted=$false;$exitCode=2
[IO.Directory]::CreateDirectory($folder)|Out-Null
$invocation=[ordered]@{RunId=$RunId;At=[DateTimeOffset]::Now.ToString('o');Protocol=$Protocol;ClientKind=$ClientKind;Address=$context.Device.Address;Device=$context.Device.DeviceName;SshFingerprint=$context.Device.HostFingerprint;PortalPublicKey=$context.PublicKeySha256;CertificateSha256=$context.CertificateSha256;LeaseRunId=$leaseRun;OfficialGuiTest=$false;SecretsVia='private_stdin';SourceSha256=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'OfficialRemoteProbe.cs')).Hash;VendorFiles=$vendorFiles;LaunchAttempted=$false}
$invocation.Direct=[bool]$Direct
$result=[ordered]@{RunId=$RunId;State='started';OfficialGuiTest=$false;ExitCode=2;Evidence=$folder}
try{
    $leaseAttempted=$true
    $lease=& (Join-Path $workspace 'apps/holographic-control/ops/Control-Lease.ps1') -Mode Start -RunId $leaseRun|ConvertFrom-Json
    if(-not $lease.Active){throw 'The named device guard is not active.'}
    $result.LeaseStart=$lease
    $invocation.LaunchAttempted=$true
    [IO.File]::WriteAllText($checkpoint,($invocation|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'OfficialRemoteProbe.cs') -Destination (Join-Path $folder 'OfficialRemoteProbe.cs')
    $start=[Diagnostics.ProcessStartInfo]::new($exe)
    $start.WorkingDirectory=$runtime;$start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $start.StandardInputEncoding=[Text.UTF8Encoding]::new($false)
    $start.StandardOutputEncoding=[Text.UTF8Encoding]::new($false)
    $start.StandardErrorEncoding=[Text.UTF8Encoding]::new($false)
    $process=[Diagnostics.Process]::new();$process.StartInfo=$start
    $null=$process.Start()
    $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
    $saved=Import-Clixml -LiteralPath (Join-Path $workspace 'apps/holographic-control/.state/portal-credential.clixml')
    $network=$saved.Credential.GetNetworkCredential()
    $configuration=@{Address=($Protocol+'://'+$context.Device.Address);UserName=$network.UserName;Password=$network.Password;ExpiresAt=[DateTimeOffset]::UtcNow.AddSeconds(240).ToString('o');ClientKind=$ClientKind;CertificateSha256=$context.CertificateSha256;Direct=[bool]$Direct}
    $process.StandardInput.WriteLine(($configuration|ConvertTo-Json -Compress));$process.StandardInput.Close()
    $configuration=$null;$network=$null;$saved=$null
    if(-not $process.WaitForExit(35000)){
        $process.Kill();$process.WaitForExit(5000)|Out-Null
        $result.State='bounded_timeout';$result.ProcessTerminated=$true;$exitCode=124
    }else{$exitCode=$process.ExitCode;$result.State='completed'}
    $outText=$stdout.GetAwaiter().GetResult();$errText=$stderr.GetAwaiter().GetResult()
    [IO.File]::WriteAllText((Join-Path $folder 'stdout.jsonl'),$outText,[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $folder 'stderr.txt'),$errText,[Text.UTF8Encoding]::new($false))
    $lines=@($outText -split '\r?\n'|Where-Object {$_})
    if($lines.Count){$result.Probe=$lines[-1]|ConvertFrom-Json}
}catch{
    $result.State='error';$result.ErrorType=$_.Exception.GetType().Name
    $result.Hresult='0x'+$_.Exception.HResult.ToString('X8')
}finally{
    if($process){if(-not $process.HasExited){$process.Kill();$process.WaitForExit(5000)|Out-Null};$process.Dispose()}
    if($leaseAttempted){
        try{$result.LeaseStop=& (Join-Path $workspace 'apps/holographic-control/ops/Control-Lease.ps1') -Mode Stop -RunId $leaseRun|ConvertFrom-Json}
        catch{$result.RestorePending=$true;$exitCode=2}
    }
    try{$result.FinalMode=$context.Client.GetStringAsync($context.BaseUri+'/api/holographic/simulation/control/mode').GetAwaiter().GetResult()|ConvertFrom-Json}catch{$result.ModeReadError=$_.Exception.GetType().Name;$exitCode=2}
    $context.Client.Dispose()
    $result.ExitCode=$exitCode
    [IO.File]::WriteAllText($resultPath,($result|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
}
$result|ConvertTo-Json -Depth 12
if($exitCode){exit $exitCode}
