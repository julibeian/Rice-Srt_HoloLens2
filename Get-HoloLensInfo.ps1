param([string]$OutputDirectory)
. (Join-Path $PSScriptRoot 'HoloLens.Common.ps1')
if (-not $OutputDirectory) { $OutputDirectory=Join-Path $PSScriptRoot ('reports\'+[DateTimeOffset]::Now.ToString('yyyyMMdd-HHmmss')) }
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)
[IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
$report=[ordered]@{ CapturedAt=[DateTimeOffset]::Now.ToString('o'); Device=(Invoke-HlBridge @{action='info'}); Channel=(Invoke-HlBridge @{action='status'}); HostUsb=@(); HostUsbNetwork=@(); NetworkAddresses=@(); Commands=[ordered]@{}; Errors=[Collections.Generic.List[string]]::new() }
$remoteFolder=[string]$report.Device.WorkingDirectory
$null=Invoke-HlBridge @{action='mkdir';path=$remoteFolder;cwd=$report.Device.WorkingDirectory}
$report.HostUsb=@(Get-PnpDevice -PresentOnly | Where-Object {$_.InstanceId -like 'USB\VID_045E&PID_0661*'} | Select-Object Status,Class,FriendlyName,InstanceId)
$adapters=@(Get-NetAdapter | Where-Object {$_.InterfaceDescription -eq 'UsbNcm Host Device'})
$report.HostUsbNetwork=@($adapters | Select-Object ifIndex,Name,InterfaceDescription,Status,MacAddress,LinkSpeed,DriverVersion,DriverInformation)
$report.NetworkAddresses=@(foreach($adapter in $adapters){ Get-NetIPAddress -InterfaceIndex $adapter.ifIndex | Select-Object InterfaceIndex,AddressFamily,IPAddress,PrefixLength })

$probeText='HoloLens USB SSH round trip verified at '+$report.CapturedAt
$probeLocal=Join-Path $OutputDirectory 'roundtrip-sent.txt'
$probeReceived=Join-Path $OutputDirectory 'roundtrip-received.txt'
$probeRemote=[IO.Path]::Combine($remoteFolder,('connection-check-'+[Guid]::NewGuid().ToString('N')+'.txt'))
[IO.File]::WriteAllText($probeLocal,$probeText,[Text.UTF8Encoding]::new($false))
$null=Invoke-HlBridge @{action='put';local=$probeLocal;path=$probeRemote;cwd=$remoteFolder}
$null=Invoke-HlBridge @{action='get';local=$probeReceived;path=$probeRemote;cwd=$remoteFolder}
$sentHash=(Get-FileHash -LiteralPath $probeLocal -Algorithm SHA256).Hash
$receivedHash=(Get-FileHash -LiteralPath $probeReceived -Algorithm SHA256).Hash
$report.FileTransfer=[ordered]@{ RemotePath=$probeRemote; SentSha256=$sentHash; ReceivedSha256=$receivedHash; Verified=($sentHash -eq $receivedHash) }
if(-not $report.FileTransfer.Verified){throw 'USB SSH round trip SHA256 verification failed.'}

$remoteNtdll='C:\Windows\System32\ntdll.dll'
$localNtdll=Join-Path $OutputDirectory 'device-ntdll.dll'
try {
    $null=Invoke-HlBridge @{action='get';local=$localNtdll;path=$remoteNtdll;cwd=$remoteFolder}
    $version=[Diagnostics.FileVersionInfo]::GetVersionInfo($localNtdll)
    $report.OsBinary=[ordered]@{ Source=$remoteNtdll; FileVersion=$version.FileVersion; ProductVersion=$version.ProductVersion; ProductName=$version.ProductName; FileDescription=$version.FileDescription }
} catch { $report.Errors.Add('OS binary version: '+(Get-HlErrorMessage $_.Exception)) }
finally { if(Test-Path -LiteralPath $localNtdll){Remove-Item -LiteralPath $localNtdll} }

$diagnostics=@(
    @{Name='timezone';Executable='tzutil.exe';Arguments='/g'},
    @{Name='power-sleep-states';Executable='powercfg.exe';Arguments='/a'},
    @{Name='time-sync';Executable='w32tm.exe';Arguments='/query /status'},
    @{Name='connected-hardware';Executable='pnputil.exe';Arguments='/enum-devices /connected'}
)
foreach($diagnostic in $diagnostics){
    try{
        $result=Invoke-HlBridge @{action='exec';executable=$diagnostic.Executable;arguments=$diagnostic.Arguments;cwd=$remoteFolder}
        $report.Commands[$diagnostic.Name]=$result
        if($result.ExitCode -ne 0){$report.Errors.Add($diagnostic.Name+': remote command returned '+$result.ExitCode+'; '+$result.Output.Trim())}
        [IO.File]::WriteAllText((Join-Path $OutputDirectory ($diagnostic.Name+'.txt')),[string]$result.Output,[Text.UTF8Encoding]::new($false))
    }catch{$report.Errors.Add($diagnostic.Name+': '+(Get-HlErrorMessage $_.Exception))}
}

$remoteDxdiag=[IO.Path]::Combine($remoteFolder,('dxdiag-'+[Guid]::NewGuid().ToString('N')+'.xml'))
try{
    $result=Invoke-HlBridge @{action='exec';executable='dxdiag.exe';arguments=('/dontskip /whql:off /x "'+$remoteDxdiag+'"');cwd=$remoteFolder}
    $report.Commands['dxdiag']=$result
    $file=Invoke-HlBridge @{action='stat';path=$remoteDxdiag;cwd=$remoteFolder}
    if($file.Exists){
        $destination=Join-Path $OutputDirectory 'dxdiag.xml'
        $null=Invoke-HlBridge @{action='get';local=$destination;path=$remoteDxdiag;cwd=$remoteFolder}
        $report.DxDiagReport=$destination
        $xmlSettings=[Xml.XmlReaderSettings]::new()
        $xmlSettings.DtdProcessing=[Xml.DtdProcessing]::Prohibit
        $xmlReader=[Xml.XmlReader]::Create($destination,$xmlSettings)
        try{$xmlDocument=[Xml.XmlDocument]::new();$xmlDocument.XmlResolver=$null;$xmlDocument.Load($xmlReader)}finally{$xmlReader.Dispose()}
        $report.SystemInformation=[ordered]@{}
        foreach($node in $xmlDocument.SelectSingleNode('/DxDiag/SystemInformation').ChildNodes){$report.SystemInformation[$node.Name]=$node.InnerText}
        $report.DisplayDevices=@(foreach($display in $xmlDocument.SelectNodes('/DxDiag/DisplayDevices/DisplayDevice')){
            $displayInfo=[ordered]@{}
            foreach($field in @('CardName','Manufacturer','ChipType','DisplayMemory','DedicatedMemory','SharedMemory','CurrentMode','DriverVersion','DriverDate')){
                $node=$display.SelectSingleNode($field)
                if($node){$displayInfo[$field]=$node.InnerText}
            }
            $displayInfo
        })
    }else{$report.Errors.Add('The OS dxdiag command did not create an XML report. Exit code: '+$result.ExitCode)}
}catch{$report.Errors.Add('dxdiag: '+(Get-HlErrorMessage $_.Exception))}

try{
    $apps=& (Join-Path $script:HlConfig.SdkDirectory 'WinAppDeployCmd.exe') list -ip $report.Device.Address
    if($LASTEXITCODE -ne 0){throw 'SDK app enumeration failed.'}
    $report.InstalledPackages=@($apps | Where-Object{$_ -match '^\S+_\d+\.\d+\.\d+\.\d+_'})
    [IO.File]::WriteAllLines((Join-Path $OutputDirectory 'installed-packages.txt'),[string[]]$report.InstalledPackages,[Text.UTF8Encoding]::new($false))
}catch{$report.Errors.Add('Installed packages: '+(Get-HlErrorMessage $_.Exception))}

$report.Channel=Invoke-HlBridge @{action='status'}
$json=$report | ConvertTo-Json -Depth 14
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'device-info.json'),$json,[Text.UTF8Encoding]::new($false))
$summary=@"
# HoloLens USB / SSH 设备实测信息

采集时间：$($report.CapturedAt)

- 设备：$($report.Device.DeviceName)
- 设备发现标识：$($report.Device.DiscoveryGuid)
- 连接：$($report.Device.Transport)
- USB 地址：$($report.Device.Address)
- 处理器架构：$($report.Device.Architecture)
- 系统家族：$($report.Device.Target.DeviceFamily)
- 远程账户：$($report.Device.User)
- 可写工作目录：$($report.Device.WorkingDirectory)
- SSH 主机指纹：$($report.Device.HostFingerprint)
- 文件往返 SHA256 一致：$($report.FileTransfer.Verified)
- 通道状态：$($report.Channel.State)

完整结构化信息见 device-info.json；系统工具输出、已安装应用清单和可用的 dxdiag 报告位于同一目录。

## 采集限制

本机固件不自带 CMD、PowerShell、hostname 或 whoami。现有入口执行设备上实际存在的程序，提供 SDK SSH 文件与目录操作。
设备门户另有独立认证；本次未修改设备门户账号、设备电源策略或固件。
"@ -split '\r?\n'
if($report.Contains('OsBinary')){$summary+=@('',('系统二进制版本：'+$report.OsBinary.FileVersion))}
if($report.Contains('SystemInformation')){
    $systemInfo=$report.SystemInformation
    $summary+=@('','## 硬件与系统实测','', '| 项目 | 设备报告值 |','| --- | --- |',
        ('| 型号 | '+$systemInfo.SystemModel+' |'),
        ('| 处理器 | '+$systemInfo.Processor+' |'),
        ('| 内存 | '+$systemInfo.Memory+' |'),
        ('| 操作系统 | '+$systemInfo.OperatingSystem+' |'),
        ('| BIOS | '+$systemInfo.BIOS+' |'),
        ('| 固件类型 | '+$systemInfo.FirmwareType+' |'),
        ('| DirectX | '+$systemInfo.DirectXVersion+' |'))
    foreach($display in $report.DisplayDevices){$summary+=@(
        ('| GPU | '+$display.CardName+' |'),
        ('| 当前显示模式 | '+$display.CurrentMode+' |'),
        ('| GPU 驱动 | '+$display.DriverVersion+' |'))}
    if($report.Contains('InstalledPackages')){$summary+=@('',('已列出 '+$report.InstalledPackages.Count+' 个应用包，包含系统组件。'))}
}
if($report.Errors.Count){$summary+=@('','采集未完成项：');$summary+=@($report.Errors | ForEach-Object{'- '+$_})}
[IO.File]::WriteAllLines((Join-Path $OutputDirectory '设备信息.md'),[string[]]$summary,[Text.UTF8Encoding]::new($false))
[ordered]@{ReportDirectory=$OutputDirectory;InfoJson=(Join-Path $OutputDirectory 'device-info.json');FileTransferVerified=$report.FileTransfer.Verified;Errors=$report.Errors.ToArray()} | ConvertTo-Json -Depth 5
