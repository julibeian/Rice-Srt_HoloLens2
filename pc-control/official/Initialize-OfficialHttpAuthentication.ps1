param([Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_-]{1,64}$')][string]$RunId)
$ErrorActionPreference='Stop'
$workspace=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$folder=Join-Path $workspace ('pc-control/.state/official-tests/'+$RunId)
$resultPath=Join-Path $folder 'result.json'
if(Test-Path -LiteralPath $folder){
    if(Test-Path -LiteralPath $resultPath){$priorText=Get-Content -LiteralPath $resultPath -Raw;$priorText;if(-not ($priorText|ConvertFrom-Json).Observation.NativeWinRtAuthentication){exit 2}}
    else{'{"State":"prior_attempt_pending","ReplayAttempted":false}';exit 3}
    return
}
. (Join-Path $workspace 'holographic-control/ops/Holographic.Common.ps1')
$context=New-HoloAuthenticatedPortalContext
try{
    [IO.Directory]::CreateDirectory($folder)|Out-Null
    $pinHelper=Join-Path $folder 'NativePinnedHttpSeed.dll'
    $compiler=Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
    $framework=Split-Path -Parent $compiler
    $runtimeFacade=Get-ChildItem -LiteralPath (Join-Path $env:WINDIR 'Microsoft.NET/assembly/GAC_MSIL/System.Runtime') -Filter 'System.Runtime.dll' -Recurse -File|Select-Object -First 1 -ExpandProperty FullName
    $metadata='C:/Program Files (x86)/Windows Kits/10/UnionMetadata/10.0.26100.0/Windows.winmd'
    $compile=@(& $compiler /nologo /utf8output /target:library /platform:x64 (('/out:')+$pinHelper) (('/r:')+$metadata) (('/r:')+$runtimeFacade) (('/r:')+(Join-Path $framework 'System.Runtime.WindowsRuntime.dll')) (('/r:')+(Join-Path $framework 'System.Runtime.InteropServices.WindowsRuntime.dll')) (Join-Path $PSScriptRoot 'NativePinnedHttpSeed.cs') 2>&1)
    if($LASTEXITCODE){throw ('Pinned native HTTP helper compile failed: '+($compile -join [Environment]::NewLine))}
    $start=[Diagnostics.ProcessStartInfo]::new((Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'))
    $seed=Join-Path $PSScriptRoot 'Seed-WinRtPortalAuthentication.ps1'
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $start.StandardInputEncoding=[Text.UTF8Encoding]::new($false);$start.StandardOutputEncoding=[Text.UTF8Encoding]::new($false)
    foreach($arg in @('-NoLogo','-NoProfile','-NonInteractive','-File',$seed)){$start.ArgumentList.Add($arg)}
    $child=[Diagnostics.Process]::Start($start)
    $saved=Import-Clixml -LiteralPath (Join-Path $workspace 'holographic-control/.state/portal-credential.clixml')
    $network=$saved.Credential.GetNetworkCredential()
    $expiry=[DateTimeOffset]::UtcNow.AddSeconds(180).ToString('o')
    $configuration=@{BaseUri=('https://'+$context.Device.Address);Device=$context.Device.DeviceName;UserName=$network.UserName;Password=$network.Password;ExpiresAt=$expiry;PinHelper=$pinHelper;CertificateSha256=$context.CertificateSha256}
    [IO.File]::WriteAllText((Join-Path $folder 'invocation.json'),(@{At=[DateTimeOffset]::Now.ToString('o');ProcessId=$child.Id;Device=$context.Device.DeviceName;SshIdentityVerified=$true;PortalCertificatePreverified=$context.CertificateSha256;SecretTransport='private_stdin';ExpiresAt=$expiry}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    $child.StandardInput.WriteLine(($configuration|ConvertTo-Json -Compress));$child.StandardInput.Close()
    $configuration=$null;$network=$null;$saved=$null
    $pending=$child.StandardOutput.ReadLineAsync()
    if(-not $pending.Wait(20000)){$child.Kill();throw 'Native WinRT authentication did not complete.'}
    $observation=$pending.GetAwaiter().GetResult()
    $result=[ordered]@{RunId=$RunId;ProcessId=$child.Id;ExpiresAt=$expiry;Observation=($observation|ConvertFrom-Json);OfficialGuiVerified=$false;Evidence=$folder}
    [IO.File]::WriteAllText($resultPath,($result|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
    $result|ConvertTo-Json -Depth 5
    if(-not $result.Observation.NativeWinRtAuthentication){exit 2}
}finally{$context.Client.Dispose()}
