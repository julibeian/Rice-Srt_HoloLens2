$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\ops\Holographic.Common.ps1')
$rsa=[Security.Cryptography.RSA]::Create(2048)
$otherRsa=[Security.Cryptography.RSA]::Create(2048)
$caRsa=[Security.Cryptography.RSA]::Create(2048)
$otherCaRsa=[Security.Cryptography.RSA]::Create(2048)
$certificates=[Collections.Generic.List[Security.Cryptography.X509Certificates.X509Certificate2]]::new()
function New-TestAuthority($Key,[string]$Name){
 $request=[Security.Cryptography.X509Certificates.CertificateRequest]::new($Name,$Key,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
 $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($true,$false,0,$true))
 $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new([Security.Cryptography.X509Certificates.X509KeyUsageFlags]::KeyCertSign,$true))
 $cert=$request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-7),[DateTimeOffset]::UtcNow.AddDays(7));$certificates.Add($cert);return $cert
}
function New-TestLeaf($Key,$Issuer,[string]$Name,[switch]$Expired){
 $request=[Security.Cryptography.X509Certificates.CertificateRequest]::new($Name,$Key,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
 $begin=[DateTimeOffset]::UtcNow.AddDays(-2);$end=if($Expired){[DateTimeOffset]::UtcNow.AddDays(-1)}else{[DateTimeOffset]::UtcNow.AddDays(1)}
 $cert=$request.Create($Issuer,$begin,$end,[Security.Cryptography.RandomNumberGenerator]::GetBytes(16));$certificates.Add($cert);return $cert
}
try{
 $authority=New-TestAuthority $caRsa 'CN=Expected HoloLens Authority'
 $otherAuthority=New-TestAuthority $otherCaRsa 'CN=Unexpected Authority'
 $old=New-TestLeaf $rsa $authority 'CN=169.254.1.2'
 $renewed=New-TestLeaf $rsa $authority 'CN=169.254.1.2'
 $newAddress=New-TestLeaf $rsa $authority 'CN=169.254.1.3'
 $differentKey=New-TestLeaf $otherRsa $authority 'CN=169.254.1.2'
 $differentIssuer=New-TestLeaf $rsa $otherAuthority 'CN=169.254.1.2'
 $unexpectedName=New-TestLeaf $rsa $authority 'CN=unrelated-device'
 $expired=New-TestLeaf $rsa $authority 'CN=169.254.1.2' -Expired
 $cases=@(
  @{Name='Same key leaf renewal';Certificate=$renewed;Expected=$true},
  @{Name='Same key and verified new USB address';Certificate=$newAddress;Expected=$true},
  @{Name='Different server key';Certificate=$differentKey;Expected=$false},
  @{Name='Different issuer';Certificate=$differentIssuer;Expected=$false},
  @{Name='Unrelated certificate subject';Certificate=$unexpectedName;Expected=$false},
  @{Name='Expired replacement';Certificate=$expired;Expected=$false}
 )
 foreach($case in $cases){$result=Test-HoloPortalCertificateRenewal $old $case.Certificate 'CN=169.254.1.3';if($result.Allowed -ne $case.Expected){throw ('TLS renewal boundary failed: '+$case.Name)}}
 [ordered]@{Cases=$cases.Count;Passed=$cases.Count;DeviceContacted=$false;CertificateStoresChanged=$false;Test='TLS renewal accepts existing key continuity and rejects changed identity or expired replacements'}|ConvertTo-Json
}finally{foreach($cert in $certificates){$cert.Dispose()};$rsa.Dispose();$otherRsa.Dispose();$caRsa.Dispose();$otherCaRsa.Dispose()}
