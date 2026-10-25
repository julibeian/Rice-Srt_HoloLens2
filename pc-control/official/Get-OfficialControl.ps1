param([switch]$Refresh)
$ErrorActionPreference = 'Stop'
$workspace = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$folder = Join-Path $workspace 'tools/perception-simulation/official-3.0.24'
[IO.Directory]::CreateDirectory($folder) | Out-Null
$package = Join-Path $folder 'PerceptionSimulation.msi'
$download = Join-Path $folder 'PerceptionSimulation.download.msi'
$source = 'https://go.microsoft.com/fwlink/?linkid=2212643'
$existingAnalysis = if (Test-Path -LiteralPath (Join-Path $folder 'package-analysis.json')) { Get-Content -LiteralPath (Join-Path $folder 'package-analysis.json') -Raw | ConvertFrom-Json } else { $null }
if ($Refresh -or -not (Test-Path -LiteralPath $package)) {
    $response = Invoke-WebRequest -Uri $source -OutFile $download -PassThru -TimeoutSec 120 -MaximumRedirection 8
    $final = [uri]$response.BaseResponse.RequestMessage.RequestUri
    if ($final.Scheme -ne 'https' -or $final.Host -ne 'download.microsoft.com') { throw 'Unexpected official download destination.' }
    $signature = Get-AuthenticodeSignature -LiteralPath $download
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '^CN=Microsoft Corporation,') { throw 'The downloaded Microsoft signature did not validate.' }
    if ((Get-FileHash -LiteralPath $download).Hash -cne 'E2873EB2633477AE32430D0A566FE5612AA45BF5552B95B83A20C78B518A1B8E') { throw 'Package changed; inspect the new version before extracting or running it.' }
    Move-Item -LiteralPath $download -Destination $package -Force
} else { $final = if ($existingAnalysis) { $existingAnalysis.FinalUrl } else { $null } }
$signature = Get-AuthenticodeSignature -LiteralPath $package
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '^CN=Microsoft Corporation,') { throw 'Cached Microsoft signature did not validate.' }
if ((Get-FileHash -LiteralPath $package).Hash -cne 'E2873EB2633477AE32430D0A566FE5612AA45BF5552B95B83A20C78B518A1B8E') { throw 'Cached package hash changed.' }
$installer = New-Object -ComObject WindowsInstaller.Installer
$database = $installer.OpenDatabase($package, 0)
function Read-MsiTable([string]$Table) {
    if ($Table -notmatch '^[A-Za-z_]+$') { throw 'Invalid MSI table.' }
    $view = $database.OpenView(('SELECT * FROM `{0}`' -f $Table))
    [void]$view.Execute()
    $columns = $view.ColumnInfo(0)
    $fieldCount = [int]$columns.GetType().InvokeMember('FieldCount', [Reflection.BindingFlags]::GetProperty, $null, $columns, $null)
    $names = @(); for ($i = 1; $i -le $fieldCount; $i++) { $names += $columns.StringData($i) }
    $names = @($names | Where-Object { -not [string]::IsNullOrEmpty($_) })
    $rows = @()
    while ($record = $view.Fetch()) {
        $row = [ordered]@{}
        for ($i = 1; $i -le $names.Count; $i++) { $row[$names[$i-1]] = $record.StringData($i) }
        $rows += [pscustomobject]$row
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($record)
    }
    [void]$view.Close()
    foreach ($obj in @($columns, $view)) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($obj) }
    return $rows
}
$tables = @((Read-MsiTable '_Tables').Name)
$metadata = [ordered]@{}
foreach ($table in @('Property','Feature','FeatureComponents','LaunchCondition','CustomAction','InstallExecuteSequence','ServiceInstall','Registry','Class','ProgId','Directory','File','Component')) {
    if ($tables -contains $table) { $metadata[$table] = @(Read-MsiTable $table) }
}
foreach ($obj in @($database, $installer)) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($obj) }
$result = [ordered]@{ At = (Get-Date).ToString('o'); Source = $source; FinalUrl = [string]$final; Package = $package; Bytes = (Get-Item -LiteralPath $package).Length; SHA256 = (Get-FileHash -LiteralPath $package).Hash; SignatureStatus = [string]$signature.Status; Signer = $signature.SignerCertificate.Subject; Metadata = $metadata; Installed = $false }
$json = $result | ConvertTo-Json -Depth 10
[IO.File]::WriteAllText((Join-Path $folder 'package-analysis.json'), $json, [Text.UTF8Encoding]::new($false))
[ordered]@{ Package = $package; SHA256 = $result.SHA256; SignatureStatus = $result.SignatureStatus; Product = @($metadata.Property | Where-Object Property -in @('ProductVersion','ProductName','Manufacturer')); Features = $metadata.Feature; LaunchCondition = $metadata.LaunchCondition; CustomActions = $metadata.CustomAction; Services = $metadata.ServiceInstall; Registry = $metadata.Registry; Analysis = (Join-Path $folder 'package-analysis.json') } | ConvertTo-Json -Depth 7
