param(
    [string]$SdkDirectory = 'C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64',
    [string]$OutputPath = (Join-Path $PSScriptRoot 'sdk-api-evidence.json')
)
$ErrorActionPreference = 'Stop'
$deploy = [Reflection.Assembly]::LoadFrom((Join-Path $SdkDirectory 'Microsoft.Tools.Deploy.dll'))
$connectivity = [Reflection.Assembly]::LoadFrom((Join-Path $SdkDirectory 'Microsoft.Tools.Connectivity.dll'))
$names = @(
    'Microsoft.Tools.Deploy.RemoteDeployClient',
    'Microsoft.Tools.Deploy.InstallAppxOptions',
    'Microsoft.Tools.Connectivity.RemoteDevice',
    'Microsoft.Tools.Connectivity.RemoteCommand',
    'Microsoft.Tools.Connectivity.LaunchFlags'
)
$rows = foreach ($name in $names) {
    $type = $deploy.GetType($name)
    if (-not $type) { $type = $connectivity.GetType($name) }
    [ordered]@{
        Name = $name
        Assembly = $type.Assembly.Location
        Methods = @($type.GetMethods([Reflection.BindingFlags]'Public,Instance,Static,DeclaredOnly') | ForEach-Object ToString)
        Properties = @($type.GetProperties([Reflection.BindingFlags]'Public,Instance,Static') | ForEach-Object {
            [ordered]@{Signature=$_.ToString();CanWrite=$_.CanWrite}
        })
        EnumValues = if ($type.IsEnum) {
            @([Enum]::GetValues($type) | ForEach-Object { [ordered]@{Name=$_.ToString();Value=[int]$_} })
        } else { @() }
    }
}
$result = [ordered]@{
    CapturedAt = [DateTimeOffset]::Now.ToString('o')
    Scope = 'Local assembly reflection only. No device discovery, connection, process execution or installation.'
    Tools = @(foreach($tool in @('makeappx.exe','signtool.exe','WinAppDeployCmd.exe','MakeCert.exe','pvk2pfx.exe')) {
        $path=Join-Path $SdkDirectory $tool
        [ordered]@{Name=$tool;Path=$path;Exists=(Test-Path -LiteralPath $path)}
    })
    Types = @($rows)
}
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding utf8
Write-Output $OutputPath
