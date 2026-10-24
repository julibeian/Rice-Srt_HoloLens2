param(
    [uri]$StartPage = 'https://rice-srt.cn/hololens/',
    [string]$Version = '1.0.0.0',
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'package'),
    [string]$SdkDirectory = 'C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64'
)
$ErrorActionPreference = 'Stop'
if ($StartPage.Scheme -ne 'https' -or $StartPage.Host -ne 'rice-srt.cn') {
    throw 'This package is restricted to the project HTTPS origin rice-srt.cn.'
}
if (-not $StartPage.AbsolutePath.StartsWith('/hololens/')) {
    throw 'StartPage must be inside the isolated /hololens/ deployment.'
}
$layout=Join-Path $OutputDirectory 'layout'
$assets=Join-Path $layout 'Assets'
[IO.Directory]::CreateDirectory($assets)|Out-Null
Add-Type -AssemblyName System.Drawing
foreach($size in @(44,50,150)) {
    $bitmap=[Drawing.Bitmap]::new($size,$size)
    $graphics=[Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.Clear([Drawing.Color]::FromArgb(19,38,25))
        $brush=[Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(160,225,125))
        try { $graphics.FillEllipse($brush,[int]($size*0.24),[int]($size*0.15),[int]($size*0.52),[int]($size*0.70)) }
        finally { $brush.Dispose() }
        $bitmap.Save((Join-Path $assets ('Logo'+$size+'.png')),[Drawing.Imaging.ImageFormat]::Png)
    } finally { $graphics.Dispose();$bitmap.Dispose() }
}
$escaped=[Security.SecurityElement]::Escape($StartPage.AbsoluteUri)
$manifest=@"
<?xml version="1.0" encoding="utf-8"?>
<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10"
 xmlns:uap="http://schemas.microsoft.com/appx/manifest/uap/windows10" IgnorableNamespaces="uap">
  <Identity Name="Rice.HoloLens.Capture" Publisher="CN=RiceHoloLensCapture" Version="$Version" ProcessorArchitecture="neutral" />
  <Properties>
    <DisplayName>稻视界拍照识别</DisplayName>
    <PublisherDisplayName>Rice Project</PublisherDisplayName>
    <Logo>Assets\Logo50.png</Logo>
  </Properties>
  <Dependencies>
    <TargetDeviceFamily Name="Windows.Universal" MinVersion="10.0.19041.0" MaxVersionTested="10.0.22621.0" />
  </Dependencies>
  <Resources><Resource Language="zh-CN" /></Resources>
  <Applications>
    <Application Id="Capture" StartPage="$escaped">
      <uap:VisualElements DisplayName="稻视界拍照识别" Description="眼镜单次拍照与水稻照片候选识别"
       Square150x150Logo="Assets\Logo150.png" Square44x44Logo="Assets\Logo44.png" BackgroundColor="#132619" />
      <uap:ApplicationContentUriRules>
        <uap:Rule Match="https://rice-srt.cn/hololens/*" Type="include" WindowsRuntimeAccess="all" />
      </uap:ApplicationContentUriRules>
    </Application>
  </Applications>
  <Capabilities>
    <Capability Name="internetClient" />
    <DeviceCapability Name="webcam" />
  </Capabilities>
</Package>
"@
[IO.File]::WriteAllText((Join-Path $layout 'AppxManifest.xml'),$manifest,[Text.UTF8Encoding]::new($false))
$package=Join-Path $OutputDirectory ('Rice.HoloLens.Capture_'+$Version+'_neutral_unsigned.appx')
& (Join-Path $SdkDirectory 'makeappx.exe') pack /d $layout /p $package /o
if ($LASTEXITCODE -ne 0) { throw 'MakeAppx validation or packaging failed.' }
[ordered]@{
    Scope='Local manifest/schema/package construction only. Not installed or run.'
    StartPage=$StartPage.AbsoluteUri
    Manifest=Join-Path $layout 'AppxManifest.xml'
    UnsignedPackage=$package
    Sha256=(Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash
    Note='Prefer registered loose-file developer deployment until signing/trust is explicitly established. This package still requires runtime validation.'
}|ConvertTo-Json -Depth 4|Set-Content -LiteralPath (Join-Path $OutputDirectory 'package-evidence.json') -Encoding utf8
Write-Output $package
