#Requires -Version 7.0
param(
    [Parameter(Mandatory)][string]$SdkDirectory,
    [Parameter(Mandatory)][ipaddress]$Address,
    [string]$ExpectedFingerprint
)
$ErrorActionPreference='Stop'
$sdkAssembly=Join-Path $SdkDirectory 'Microsoft.Tools.Deploy.dll'
if(-not(Test-Path -LiteralPath $sdkAssembly -PathType Leaf)){throw 'Microsoft.Tools.Deploy.dll is missing from the selected SDK directory.'}
[Reflection.Assembly]::LoadFrom($sdkAssembly)|Out-Null
$client=[Microsoft.Tools.Deploy.RemoteDeployClient]::CreateRemoteDeployClient()
try{
    $options=[Microsoft.Tools.Deploy.ConnectionOptions]::new()
    $options.IPAddress=$Address
    $options.Credentials=[Net.NetworkCredential]::new('DevToolsUser','')
    $options.ConnectTimeout=[TimeSpan]::FromSeconds(8)
    $client.Connect($options)
    $observed=[string]$client.RemoteDevice.Sha1Fingerprint
    if(-not $observed){throw 'The SDK did not return an SSH host fingerprint.'}
    if($ExpectedFingerprint -and $observed -cne $ExpectedFingerprint){throw 'SSH host identity differs from the supplied trusted baseline. No configuration was changed.'}
    [pscustomobject]@{
        Address=$Address.ToString()
        ObservedFingerprint=$observed
        IdentityVerified=[bool]$ExpectedFingerprint
        ConfigurationChanged=$false
        PairingRequested=$false
        Note=if($ExpectedFingerprint){'Compared with the explicitly supplied trusted baseline.'}else{'Observation only. An administrator must verify the physical target or an existing trusted baseline before configuring trust.'}
    }|ConvertTo-Json
}finally{
    try{$client.Disconnect()}catch{}
    $client.Dispose()
}
