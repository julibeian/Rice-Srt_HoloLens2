param([switch]$RequestPairingPin)
. (Join-Path $PSScriptRoot 'Holographic.Common.ps1')
$credentialPath=Join-Path $script:HolographicRoot '.state\portal-credential.clixml'
$context=if(Test-Path -LiteralPath $credentialPath){New-HoloAuthenticatedPortalContext}else{New-HoloPortalContext}
try{
    $results=@(Invoke-HoloPortalRequest $context GET '/api/os/info';Invoke-HoloPortalRequest $context GET '/api/holographic/simulation/control/mode')
    $authenticated=$results[0].Status -eq 200
    $requestPin=$RequestPairingPin -and -not $authenticated
    if($requestPin){
        Invoke-HoloPortalRequest $context GET '/devicepair.htm'|Out-Null
        $results+=Invoke-HoloPortalRequest $context POST '/api/authorize/startpair'
    }
    $proof=[ordered]@{CheckedAt=[DateTimeOffset]::Now.ToString('o');Device=$context.Device.DeviceName;Address=$context.Device.Address;SshIdentityVerified=$true;PortalCertificatePinned=$true;CertificateSha256=$context.CertificateSha256;PublicKeySha256=$context.PublicKeySha256;CertificateRenewed=$context.CertificateRenewed;Requests=$results;PortalAuthenticated=$authenticated;InputVerified=$false;LiveViewVerified=$false;CredentialsChanged=$false;PairingPinRequested=[bool]$requestPin;PairingPinSkippedBecauseAuthenticated=([bool]$RequestPairingPin -and $authenticated)}
    $path=Join-Path $script:HolographicRoot '.state\connection-status.json'
    [IO.File]::WriteAllText($path,($proof|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
    $proof|ConvertTo-Json -Depth 5
}finally{$context.Client.Dispose()}
