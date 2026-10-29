param()
$ErrorActionPreference='Stop'
$workspace=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $workspace 'holographic-control/ops/Holographic.Common.ps1')
$context=New-HoloAuthenticatedPortalContext
try{
    $saved=Import-Clixml -LiteralPath (Join-Path $workspace 'holographic-control/.state/portal-credential.clixml')
    if($saved.DeviceName -cne $context.Device.DeviceName -or $saved.SshFingerprint -cne $context.Device.HostFingerprint -or $saved.PublicKeySha256 -cne $context.PublicKeySha256){throw 'Saved credential identity mismatch.'}
    $runtime=Join-Path $workspace 'pc-control/.state/official-credential-helper'
    [IO.Directory]::CreateDirectory($runtime)|Out-Null
    $exe=Join-Path $runtime 'PortalCredentialClipboard.exe'
    $compiler=Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
    $source=Join-Path $PSScriptRoot 'PortalCredentialClipboard.cs'
    $compile=@(& $compiler /nologo /utf8output /target:winexe /platform:x64 /r:System.Drawing.dll /r:System.Windows.Forms.dll /r:System.Web.Extensions.dll (('/out:')+$exe) $source 2>&1)
    if($LASTEXITCODE){throw ('Credential helper compile failed: '+($compile -join [Environment]::NewLine))}
    $start=[Diagnostics.ProcessStartInfo]::new($exe)
    $start.WorkingDirectory=$runtime;$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardInput=$true
    $start.StandardInputEncoding=[Text.UTF8Encoding]::new($false)
    $child=[Diagnostics.Process]::Start($start)
    $network=$saved.Credential.GetNetworkCredential()
    $configuration=@{Device=$context.Device.DeviceName;Address=$context.Device.Address;UserName=$network.UserName;Password=$network.Password}
    $child.StandardInput.WriteLine(($configuration|ConvertTo-Json -Compress));$child.StandardInput.Close()
    $network=$null;$configuration=$null;$saved=$null
    [ordered]@{ProcessId=$child.Id;SourceSha256=(Get-FileHash -LiteralPath $source).Hash;Device=$context.Device.DeviceName;AuthenticationAutomated=$false;PlaintextLogged=$false;SecretTransport='private_stdin'}|ConvertTo-Json
}finally{$context.Client.Dispose()}
