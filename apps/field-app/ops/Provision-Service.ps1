# Place a short-lived, one-use code outside the distributable package.
# No campus password, account password, device key or session token is saved here.
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$workspace=Split-Path -Parent (Split-Path -Parent $root)
. (Join-Path $workspace 'usb-terminal/HoloLens.Common.ps1')
$installed=Get-Content -LiteralPath (Join-Path $root '.state\installed.json') -Raw|ConvertFrom-Json
if($installed.RemoteLayout -ne 'U:\Users\DefaultAccount\AppData\Local\DevelopmentFiles\RiceHoloLensFieldV1'){throw 'Unexpected application deployment path.'}
$issued=$null;$pair=$null;$local=Join-Path $root ('.state\pair-'+[Guid]::NewGuid().ToString('N')+'.json')
try{
 $issued=ssh -o BatchMode=yes -o ConnectTimeout=10 aliyun 'sudo -n -u admin python3 /opt/rice-hololens-app/current/server.py pair-code --data-dir /var/lib/rice-hololens-app'
 if($LASTEXITCODE -ne 0){throw 'Could not issue one-use device code.'}
 $pair=$issued|ConvertFrom-Json
 [IO.File]::WriteAllText($local,($pair|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
 $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
 $acl=[Security.AccessControl.FileSecurity]::new();$acl.SetOwner($identity.User);$acl.SetAccessRuleProtection($true,$false)
 $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($identity.User,'FullControl','Allow'))
 Set-Acl -LiteralPath $local -AclObject $acl
 $info=Invoke-HlBridge @{action='info'}
 Import-HlSdk
 $client=Connect-HlDevice $info.Address
 try{$client.RemoteDevice.PutFile(($installed.RemoteLayout+'\pairing.json'),$local,$true)}finally{$client.Disconnect();$client.Dispose()}
 $proof=[ordered]@{ProvisionedAt=[DateTimeOffset]::Now.ToString('o');ExpiresAt=[DateTimeOffset]::FromUnixTimeSeconds([long]$pair.expires_epoch).ToLocalTime().ToString('o');OneUse=$true;IncludesDeviceKey=$false;PackageModified=$false}
 [IO.File]::WriteAllText((Join-Path $root '.state\service-provisioned.json'),($proof|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
 $proof|ConvertTo-Json -Compress
}finally{if(Test-Path -LiteralPath $local){Remove-Item -LiteralPath $local};$issued=$null;$pair=$null}
