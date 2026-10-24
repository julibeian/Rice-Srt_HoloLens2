param([switch]$SelfTest)
. (Join-Path $PSScriptRoot 'Holographic.Common.ps1')
$exe=Join-Path $script:HolographicRoot '.state\desktop-x86\PerceptionControl.exe'
if(-not(Test-Path -LiteralPath $exe)){throw 'Build the controller with Build-Control.ps1 first.'}
if($SelfTest){& $exe --self-test;exit $LASTEXITCODE}
$context=New-HoloPortalContext
$process=$null
try{
    $credentialPath=Join-Path $script:HolographicRoot '.state\portal-credential.clixml'
    if(-not(Test-Path -LiteralPath $credentialPath)){
        [pscustomobject]@{State='portal_credentials_required';UsbIdentityVerified=$true;Address=$context.Device.Address;PortalCertificatePinned=$true;InputVerified=$false;LiveViewVerified=$false;CredentialEntryScript=(Join-Path $PSScriptRoot 'Save-PortalCredential.ps1')}|ConvertTo-Json
        return
    }
    $saved=Import-Clixml -LiteralPath $credentialPath
    $certificateMatches=$saved.CertificateSha256 -ceq $context.CertificateSha256 -or ($saved.PSObject.Properties['PublicKeySha256'] -and $saved.PublicKeySha256 -ceq $context.PublicKeySha256)
    if($saved.SshFingerprint -ne $context.Device.HostFingerprint -or -not $certificateMatches -or $saved.DeviceName -ne $context.Device.DeviceName){throw 'Saved portal credential belongs to another device or server key.'}
    $credential=$saved.Credential.GetNetworkCredential()
    $basic=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($credential.UserName+':'+$credential.Password))
    $context.Client.DefaultRequestHeaders.Authorization=[Net.Http.Headers.AuthenticationHeaderValue]::new('Basic',$basic)
    $basic=$null
    $check=Invoke-HoloPortalRequest $context GET '/api/os/info'
    if($check.Status -ne 200){[pscustomobject]@{State='portal_credential_rejected';Status=$check.Status;InputVerified=$false;LiveViewVerified=$false}|ConvertTo-Json;return}
    $page=$context.Client.GetAsync($context.BaseUri+'/default.htm').GetAwaiter().GetResult()
    try{if([int]$page.StatusCode -ne 200){throw 'The authenticated portal page is unavailable.'}}finally{$page.Dispose()}
    $cookieUri=[uri]($context.BaseUri+'/api/holographic/simulation/control/stream')
    $csrf=$context.Handler.CookieContainer.GetCookies($cookieUri)['CSRF-Token']
    if(-not $csrf){throw 'The authenticated portal did not issue a CSRF cookie.'}
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=$exe;$start.WorkingDirectory=Split-Path -Parent $exe
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $process=[Diagnostics.Process]::new();$process.StartInfo=$start
    if(-not $process.Start()){throw 'Controller process did not start.'}
    $configuration=@{Address=$context.Device.Address;UserName=$credential.UserName;Password=$credential.Password;CertificateSha256=$context.CertificateSha256;CsrfToken=$csrf.Value;CookieHeader=$context.Handler.CookieContainer.GetCookieHeader($cookieUri)}|ConvertTo-Json -Compress
    $process.StandardInput.WriteLine($configuration);$configuration=$null;$credential=$null
    $first=$process.StandardOutput.ReadLine()
    if(-not $first){throw 'Controller exited before reporting connection status.'}
    $first
    $ready=$first|ConvertFrom-Json
    if(-not $ready.ok -or $ready.state -ne 'connected'){return}
    # Caller supplies explicit commands over its existing terminal/PTY. Secrets
    # travelled only over the private child stdin pipe, never process arguments.
    while(($command=[Console]::ReadLine()) -ne $null){
        if([string]::IsNullOrWhiteSpace($command)){continue}
        if($command.Length -gt 256){throw 'Controller command is too long.'}
        $process.StandardInput.WriteLine($command)
        if($command.Trim() -eq 'exit'){break}
        $answer=$process.StandardOutput.ReadLine()
        if(-not $answer){break}
        $answer
    }
}finally{
    if($process){
        try{if(-not $process.HasExited){$process.StandardInput.WriteLine('exit');$process.StandardInput.Close();if(-not $process.WaitForExit(8000)){$process.Kill()}}}catch{}
        if($process.HasExited){$remaining=$process.StandardOutput.ReadToEnd();if($remaining){$remaining.TrimEnd()}}
        $process.Dispose()
    }
    $context.Client.Dispose()
}
