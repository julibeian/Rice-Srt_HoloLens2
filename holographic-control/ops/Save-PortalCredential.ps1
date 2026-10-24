param([Management.Automation.PSCredential]$Credential)
if(-not $Credential){throw 'Provide an existing portal PSCredential from a local secure prompt. This script does not request or change a portal password.'}
. (Join-Path $PSScriptRoot 'Holographic.Common.ps1')
$context=New-HoloPortalContext
try{
    $network=$Credential.GetNetworkCredential()
    $basic=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($network.UserName+':'+$network.Password))
    $context.Client.DefaultRequestHeaders.Authorization=[Net.Http.Headers.AuthenticationHeaderValue]::new('Basic',$basic)
    $network=$null;$basic=$null
    $check=Invoke-HoloPortalRequest $context GET '/api/os/info'
    if($check.Status -ne 200){throw ('Portal credential was not accepted: HTTP '+$check.Status+'. Nothing was saved.')}
    $path=Join-Path $script:HolographicRoot '.state\portal-credential.clixml'
    [pscustomobject]@{DeviceName=$context.Device.DeviceName;SshFingerprint=$context.Device.HostFingerprint;CertificateSha256=$context.CertificateSha256;PublicKeySha256=$context.PublicKeySha256;Credential=$Credential;SavedAt=[DateTimeOffset]::Now.ToString('o')} | Export-Clixml -LiteralPath $path
    [pscustomobject]@{Saved=$true;Device=$context.Device.DeviceName;PortalAuthenticated=$true;PasswordProtection='Windows DPAPI, current Windows user';CredentialsChangedOnDevice=$false}|ConvertTo-Json
}finally{$context.Client.Dispose()}
