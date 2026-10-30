$ErrorActionPreference='Stop'
$script:HolographicRoot=Split-Path -Parent $PSScriptRoot
$script:HolographicWorkspace=Split-Path -Parent (Split-Path -Parent $script:HolographicRoot)
. (Join-Path $script:HolographicWorkspace 'usb-terminal/HoloLens.Common.ps1')
[IO.Directory]::CreateDirectory((Join-Path $script:HolographicRoot '.state'))|Out-Null

if(-not ('HoloPortalTls' -as [type])){
    Add-Type -TypeDefinition @'
using System;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Net.Security;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
public static class HoloPortalTls {
    // This first certificate-only exchange is made only after the existing USB
    // SSH identity has been checked. It sends no HTTP request or credential.
    public static byte[] ReadCertificate(string address) {
        using(var tcp=new TcpClient()) {
            if(!tcp.ConnectAsync(address,443).Wait(5000))throw new TimeoutException("Portal TLS connect timed out.");
            tcp.ReceiveTimeout=5000;tcp.SendTimeout=5000;
            using(var tls=new SslStream(tcp.GetStream(),false,(sender,cert,chain,errors)=>true)) {
                tls.ReadTimeout=5000;tls.WriteTimeout=5000;
                tls.AuthenticateAsClient(address);
                return tls.RemoteCertificate.Export(X509ContentType.Cert);
            }
        }
    }
    public static HttpClientHandler CreateHandler(string address,string fingerprint) {
        var handler=new HttpClientHandler();
        handler.UseProxy=false;handler.AllowAutoRedirect=false;
        handler.CookieContainer=new CookieContainer();handler.UseCookies=true;
        handler.ServerCertificateCustomValidationCallback=(req,cert,chain,errors)=>
            req.RequestUri.Host==address && cert!=null &&
            cert.GetCertHashString(HashAlgorithmName.SHA256)==fingerprint;
        return handler;
    }
}
'@
}

function Get-HoloPortalPublicKeyPin {
    param([Security.Cryptography.X509Certificates.X509Certificate2]$Certificate)
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Certificate.PublicKey.ExportSubjectPublicKeyInfo()))
}

function Test-HoloPortalCertificateRenewal {
    param([Security.Cryptography.X509Certificates.X509Certificate2]$Previous,[Security.Cryptography.X509Certificates.X509Certificate2]$Current,[string]$ExpectedSubject)
    $oldKey=Get-HoloPortalPublicKeyPin $Previous;$newKey=Get-HoloPortalPublicKeyPin $Current
    $sameKey=$oldKey -ceq $newKey
    $sameIssuer=$Previous.Issuer -ceq $Current.Issuer
    $subjectAllowed=$Current.Subject -ceq $Previous.Subject -or $Current.Subject -ceq $ExpectedSubject
    $timeValid=$Current.NotAfter.ToUniversalTime() -gt [DateTime]::UtcNow -and $Current.NotBefore.ToUniversalTime() -le [DateTime]::UtcNow.AddMinutes(5)
    [pscustomobject]@{Allowed=($sameKey -and $sameIssuer -and $subjectAllowed -and $timeValid);SameKey=$sameKey;SameIssuer=$sameIssuer;SubjectAllowed=$subjectAllowed;TimeValid=$timeValid;PublicKeySha256=$newKey}
}

function New-HoloPortalContext {
    $device=Invoke-HlBridge @{action='info'}
    if($device.HostFingerprint -ne $script:HlConfig.ExpectedFingerprint -or $device.DeviceName -ne $script:HlConfig.DeviceName -or $device.Address -notmatch '^169\.254\.\d+\.\d+$'){
        throw 'The current USB peer did not match the saved HoloLens identity.'
    }
    $pinPath=Join-Path $script:HolographicRoot '.state\portal-tls-pin.json'
    $der=[HoloPortalTls]::ReadCertificate($device.Address)
    $current=[Security.Cryptography.X509Certificates.X509Certificate2]::new($der)
    $observedHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($der))
    $renewed=$false;$writePin=$false
    if(Test-Path -LiteralPath $pinPath){
        $pin=Get-Content -LiteralPath $pinPath -Raw|ConvertFrom-Json
        if($pin.SshFingerprint -ne $device.HostFingerprint -or $pin.DeviceName -ne $device.DeviceName){throw 'Portal certificate belongs to another saved device.'}
        $certificatePath=Join-Path $script:HolographicRoot '.state\portal-server.cer'
        if($pin.PSObject.Properties['CertificateFile']){
            if($pin.CertificateFile -notmatch '^portal-server-[A-F0-9]{64}\.cer$'){throw 'Unexpected pinned certificate filename.'}
            $certificatePath=Join-Path $script:HolographicRoot ('.state\'+$pin.CertificateFile)
        }
        if((Get-FileHash -LiteralPath $certificatePath).Hash -cne $pin.CertificateSha256){throw 'The saved certificate does not match its pin.'}
        $previous=[Security.Cryptography.X509Certificates.X509Certificate2]::new($certificatePath)
        try{
            if($observedHash -cne $pin.CertificateSha256){
                # A leaf renewal may change its fingerprint while keeping the
                # authenticated server key. Never infer key continuity from the
                # device name alone, and never send credentials while checking.
                $check=Test-HoloPortalCertificateRenewal $previous $current ('CN='+$device.Address)
                if(-not $check.Allowed){throw 'The Device Portal key, issuer, subject or validity changed. The saved pin remains in effect; no credentials were sent.'}
                $history=Join-Path $script:HolographicRoot ('.state\tls-renewals\'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[Guid]::NewGuid().ToString('N').Substring(0,6))
                [IO.Directory]::CreateDirectory($history)|Out-Null
                Copy-Item -LiteralPath $pinPath -Destination (Join-Path $history 'previous-pin.json')
                Copy-Item -LiteralPath $certificatePath -Destination (Join-Path $history 'previous-server.cer')
                $evidence=[ordered]@{At=[DateTimeOffset]::Now.ToString('o');DeviceName=$device.DeviceName;SshFingerprint=$device.HostFingerprint;PreviousCertificateSha256=$pin.CertificateSha256;CurrentCertificateSha256=$observedHash;Renewal=$check;CredentialsSent=$false}
                [IO.File]::WriteAllText((Join-Path $history 'verification.json'),($evidence|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
                $pin.CertificateSha256=$observedHash
                $pin|Add-Member -NotePropertyName RenewedAt -NotePropertyValue ([DateTimeOffset]::Now.ToString('o')) -Force
                $renewed=$true;$writePin=$true
            }
            $keyPin=Get-HoloPortalPublicKeyPin $current
            if($pin.PSObject.Properties['PublicKeySha256'] -and $pin.PublicKeySha256 -cne $keyPin){throw 'The public key does not match its stored pin.'}
            if(-not $pin.PSObject.Properties['PublicKeySha256'] -or -not $pin.PSObject.Properties['CertificateFile']){$writePin=$true}
        }finally{$previous.Dispose()}
    }else{
        $pin=[pscustomobject]@{DeviceName=$device.DeviceName;SshFingerprint=$device.HostFingerprint;CertificateSha256=$observedHash;PinnedAt=[DateTimeOffset]::Now.ToString('o');TrustBasis='Existing pinned SSH identity on the same point-to-point USB network; certificate-only first exchange.'}
        $keyPin=Get-HoloPortalPublicKeyPin $current;$writePin=$true
    }
    if($writePin){
        $certificateFile='portal-server-'+$observedHash+'.cer'
        $versionedPath=Join-Path $script:HolographicRoot ('.state\'+$certificateFile)
        if(Test-Path -LiteralPath $versionedPath){if((Get-FileHash -LiteralPath $versionedPath).Hash -cne $observedHash){throw 'A stored certificate file does not match its name.'}}else{[IO.File]::WriteAllBytes($versionedPath,$der)}
        $pin|Add-Member -NotePropertyName PublicKeySha256 -NotePropertyValue $keyPin -Force
        $pin|Add-Member -NotePropertyName CertificateFile -NotePropertyValue $certificateFile -Force
        $temporary=$pinPath+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
        [IO.File]::WriteAllText($temporary,($pin|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary,$pinPath,$true)
        [IO.File]::WriteAllBytes((Join-Path $script:HolographicRoot '.state\portal-server.cer'),$der)
    }
    $current.Dispose()
    $handler=[HoloPortalTls]::CreateHandler($device.Address,$pin.CertificateSha256)
    $client=[Net.Http.HttpClient]::new($handler)
    $client.Timeout=[TimeSpan]::FromSeconds(10)
    return @{Device=$device;BaseUri=('https://'+$device.Address);CertificateSha256=$pin.CertificateSha256;PublicKeySha256=$keyPin;CertificateRenewed=$renewed;Handler=$handler;Client=$client}
}

function Invoke-HoloPortalRequest {
    param($Context,[ValidateSet('GET','POST')][string]$Method,[string]$Path)
    if($Path -notin @('/devicepair.htm','/api/authorize/startpair','/api/os/info','/api/holographic/simulation/control/mode')){throw 'This diagnostic only allows fixed, reviewed portal endpoints.'}
    $uri=[uri]($Context.BaseUri+$Path)
    $request=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method),$uri)
    try{
        if($Method -eq 'POST'){
            $csrf=$Context.Handler.CookieContainer.GetCookies($uri)['CSRF-Token']
            if($csrf){$request.Headers.Add('X-CSRF-Token',$csrf.Value)}
            $request.Content=[Net.Http.ByteArrayContent]::new([byte[]]::new(0))
        }
        $response=$Context.Client.SendAsync($request).GetAwaiter().GetResult()
        try{return [pscustomobject]@{Method=$Method;Path=$Path;Status=[int]$response.StatusCode;Authenticate=$response.Headers.WwwAuthenticate.ToString()}}
        finally{$response.Dispose()}
    }finally{$request.Dispose()}
}

function New-HoloAuthenticatedPortalContext {
    $context=New-HoloPortalContext
    try {
        $path=Join-Path $script:HolographicRoot '.state\portal-credential.clixml'
        if(-not(Test-Path -LiteralPath $path)){throw 'No saved portal credential is available.'}
        $saved=Import-Clixml -LiteralPath $path
        $sameKey=if($saved.PSObject.Properties['PublicKeySha256']){$saved.PublicKeySha256 -ceq $context.PublicKeySha256}else{$saved.CertificateSha256 -ceq $context.CertificateSha256}
        if(-not $sameKey -or $saved.DeviceName -cne $context.Device.DeviceName -or $saved.SshFingerprint -cne $context.Device.HostFingerprint){throw 'Saved portal credential belongs to a different device or server key.'}
        $network=$saved.Credential.GetNetworkCredential()
        $context.Client.DefaultRequestHeaders.Authorization=[Net.Http.Headers.AuthenticationHeaderValue]::new('Basic',[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($network.UserName+':'+$network.Password)))
        $network=$null;$saved=$null
        if((Invoke-HoloPortalRequest $context GET '/api/os/info').Status -ne 200){throw 'Saved portal credential is not currently accepted.'}
        return $context
    } catch {$context.Client.Dispose();throw}
}

function New-HoloDirectPortalContext {
    # Pinned portal access that does not depend on the SSH bridge. The SSO key
    # renewal path mirrors New-HoloPortalContext: a leaf may renew only with the
    # same public key, issuer, subject and valid time; no credential is sent to
    # a peer that fails that check.
    param(
        [Parameter(Mandatory)][ValidatePattern('^169\.254\.\d+\.\d+$')][string]$Address,
        [ValidateRange(3,60)][int]$TimeoutSeconds=6
    )
    $pinPath=Join-Path $script:HolographicRoot '.state\portal-tls-pin.json'
    $credentialPath=Join-Path $script:HolographicRoot '.state\portal-credential.clixml'
    if(-not(Test-Path -LiteralPath $pinPath)){throw 'No pinned portal certificate is available.'}
    if(-not(Test-Path -LiteralPath $credentialPath)){throw 'No saved portal credential is available.'}
    $config=Get-Content -LiteralPath (Join-Path $script:HolographicWorkspace 'config.json') -Raw -Encoding UTF8|ConvertFrom-Json
    $pin=Get-Content -LiteralPath $pinPath -Raw -Encoding UTF8|ConvertFrom-Json
    $saved=Import-Clixml -LiteralPath $credentialPath
    if($config.DeviceName -cne $pin.DeviceName -or $pin.DeviceName -cne $saved.DeviceName){throw 'Saved device identity records disagree.'}
    if($config.ExpectedFingerprint -cne $pin.SshFingerprint -or $pin.SshFingerprint -cne $saved.SshFingerprint){throw 'Saved SSH fingerprint records disagree.'}
    $der=[HoloPortalTls]::ReadCertificate($Address)
    $current=[Security.Cryptography.X509Certificates.X509Certificate2]::new($der)
    try{
        $observed=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($der))
        $renewed=$false
        if($observed -cne $pin.CertificateSha256){
            $certificateFile=if($pin.PSObject.Properties['CertificateFile']){[string]$pin.CertificateFile}else{'portal-server.cer'}
            if($certificateFile -notmatch '^portal-server(-[A-F0-9]{64})?\.cer$'){throw 'Unexpected pinned certificate filename.'}
            $certificatePath=Join-Path $script:HolographicRoot ('.state\'+$certificateFile)
            if(-not(Test-Path -LiteralPath $certificatePath)){throw 'The previously pinned certificate file is missing.'}
            $previous=[Security.Cryptography.X509Certificates.X509Certificate2]::new($certificatePath)
            try{
                $check=Test-HoloPortalCertificateRenewal $previous $current ('CN='+$Address)
                if(-not $check.Allowed){throw 'The Device Portal key, issuer, subject or validity changed. The saved pin remains in effect; no credentials were sent.'}
                $history=Join-Path $script:HolographicRoot ('.state\tls-renewals\'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[Guid]::NewGuid().ToString('N').Substring(0,6))
                [IO.Directory]::CreateDirectory($history)|Out-Null
                Copy-Item -LiteralPath $pinPath -Destination (Join-Path $history 'previous-pin.json')
                Copy-Item -LiteralPath $certificatePath -Destination (Join-Path $history 'previous-server.cer')
                $evidence=[ordered]@{At=[DateTimeOffset]::Now.ToString('o');DeviceName=$config.DeviceName;SshFingerprint=$config.ExpectedFingerprint;PreviousCertificateSha256=$pin.CertificateSha256;CurrentCertificateSha256=$observed;Renewal=$check;CredentialsSent=$false;Source='direct'}
                [IO.File]::WriteAllText((Join-Path $history 'verification.json'),($evidence|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
                $pin.CertificateSha256=$observed
                $pin|Add-Member -NotePropertyName RenewedAt -NotePropertyValue ([DateTimeOffset]::Now.ToString('o')) -Force
                $versioned=Join-Path $script:HolographicRoot ('.state\portal-server-'+$observed+'.cer')
                if(-not(Test-Path -LiteralPath $versioned)){[IO.File]::WriteAllBytes($versioned,$der)}
                $pin|Add-Member -NotePropertyName CertificateFile -NotePropertyValue ('portal-server-'+$observed+'.cer') -Force
                $pin|Add-Member -NotePropertyName PublicKeySha256 -NotePropertyValue $check.PublicKeySha256 -Force
                [IO.File]::WriteAllText($pinPath,($pin|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
                [IO.File]::WriteAllBytes((Join-Path $script:HolographicRoot '.state\portal-server.cer'),$der)
                $renewed=$true
            }finally{$previous.Dispose()}
        }
        $keyPin=Get-HoloPortalPublicKeyPin $current
        if($pin.PSObject.Properties['PublicKeySha256'] -and $pin.PublicKeySha256 -cne $keyPin){throw 'The public key does not match its stored pin.'}
        $handler=[HoloPortalTls]::CreateHandler($Address,$observed)
        $client=[Net.Http.HttpClient]::new($handler)
        $client.Timeout=[TimeSpan]::FromSeconds($TimeoutSeconds)
        $network=$saved.Credential.GetNetworkCredential()
        $client.DefaultRequestHeaders.Authorization=[Net.Http.Headers.AuthenticationHeaderValue]::new('Basic',[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($network.UserName+':'+$network.Password)))
        $network=$null
        return @{Client=$client;Address=$Address;CertificateSha256=$observed;PublicKeySha256=$keyPin;Renewed=$renewed;DeviceName=$config.DeviceName}
    }finally{$current.Dispose()}
}
