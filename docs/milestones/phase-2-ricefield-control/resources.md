# 第二阶段资源与获取步骤

维护日期：2026-10-25。以下全部属于真机稻视界控制，不作为第一阶段 USB 终端的依赖。

## 两套 Perception Simulation 资源

| 资源 | 用途 | 架构与当前边界 |
| --- | --- | --- |
| 微软独立预览包 **3.0.24.0** | 本阶段官方 GUI 对照测试 | 包内 Control/Manager 为 x64；不替换本项目 legacy x86 编码器。官方 GUI 真机对照待验收 |
| HoloLens Emulator **10.0.22621.1402** 中的 legacy SDK | 构建本项目已有 x86 编码器 | 使用相互匹配的 Manager 与三个托管 DLL，不启动完整模拟器。MSI 产品版本为 `10.1.22621.1402`，不是眼镜系统版本 |

微软 [独立预览说明](https://learn.microsoft.com/en-us/windows/mixed-reality/develop/advanced-concepts/perception-simulation-standalone) 列出实时显示和键鼠控制能力，支持 HoloLens 2；连接已有设备时选 `HoloLens 2 (Legacy)`。本项目仍分别测试具体机器和控件，不据文档直接判为通过。

## 1. 获取官方 3.0.24.0 包

```powershell
& .\pc-control\official\Get-OfficialControl.ps1
```

[下载与检查脚本](../../../pc-control/official/Get-OfficialControl.ps1) 从微软 [下载入口](https://go.microsoft.com/fwlink/?linkid=2212643) 获取 MSI，检查最终 HTTPS 域名、微软签名和固定 SHA256，随后只读分析 MSI。结果在本机忽略目录 `tools/perception-simulation/official-3.0.24/`，不安装软件。

| 已核查项目 | 参考值 |
| --- | --- |
| 产品版本 | `3.0.24.0` |
| 安装包字节数 | `34230272` |
| 安装包 SHA256 | `E2873EB2633477AE32430D0A566FE5612AA45BF5552B95B83A20C78B518A1B8E` |
| 预期签名者 | Microsoft Corporation，签名状态 Valid |

链接未来可能返回不同文件。脚本遇到哈希变化会停止，不能为了继续测试而直接删去核验。在线入口可访问与缓存完整哈希通过分别记录。

如需安装，先读 [官方测试计划](official-3.0.24.0-test.md)。[安装脚本](../../../pc-control/official/Install-OfficialControl.ps1) 要求管理员权限，仅显式选择 App、ManagedApi、NativeApi、Recordings 功能，保存安装前设置与 MSI 日志。默认不请求驱动、服务或切换 PC 开发者模式；`-EnableDeveloperMode` 是另外的显式选项，本阶段资料发布不执行它。

## 2. 获取 legacy x86 SDK

官方下载来自 [HoloLens Emulator 归档](https://learn.microsoft.com/en-us/windows/mixed-reality/develop/advanced-concepts/hololens-emulator-archive) 的 **10.0.22621.1402**。可下载离线布局，再做管理镜像提取，不必安装或启动完整 Hyper-V 模拟器。布局可能包含体积较大的设备镜像，预留空间和下载时间。

在 PowerShell 7 中准备目录、下载安装器并核对：

```powershell
$simTools = Join-Path $PWD 'tools/perception-simulation'
New-Item -ItemType Directory -Path $simTools -Force | Out-Null
$emulatorSetup = Join-Path $simTools 'HoloLensEmulatorSetup.exe'
if (-not (Test-Path -LiteralPath $emulatorSetup)) {
    Invoke-WebRequest -Uri 'https://go.microsoft.com/fwlink/?linkid=2290700' -OutFile $emulatorSetup
}
$signature = Get-AuthenticodeSignature -LiteralPath $emulatorSetup
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '^CN=Microsoft Corporation,') {
    throw '安装器微软签名未通过。'
}
if ((Get-FileHash -LiteralPath $emulatorSetup).Hash -cne '8522252ED0D385C9CD1634F459B10E739CAE0ED4FFB2C26AEA651C85F1292D2E') {
    throw '归档安装器与参考版本不同，先核查来源和版本。'
}
$layoutDirectory = Join-Path $simTools 'offline'
$layoutLog = Join-Path $simTools 'layout.log'
$layoutProcess = Start-Process -FilePath $emulatorSetup -ArgumentList @(
    '/layout', ('"' + $layoutDirectory + '"'), '/quiet', '/norestart', '/log', ('"' + $layoutLog + '"')
) -WindowStyle Hidden -PassThru -Wait
if ($layoutProcess.ExitCode -notin @(0, 3010)) { throw '离线布局未完成，请检查本机日志。' }
```

布局完成后核对 MSI，并提取到当前构建器的默认目录。管理镜像提取可能需要 Windows Installer 权限；若系统要求，由管理员单独执行该提取步骤。不要因此改用别的 Windows 用户运行日常门户认证。

```powershell
$legacyMsi = Join-Path $layoutDirectory 'Installers/Microsoft HoloLens Emulator-x64_en-us.msi'
$legacySignature = Get-AuthenticodeSignature -LiteralPath $legacyMsi
if ($legacySignature.Status -ne 'Valid' -or $legacySignature.SignerCertificate.Subject -notmatch '^CN=Microsoft Corporation,') {
    throw 'legacy SDK MSI 微软签名未通过。'
}
if ((Get-FileHash -LiteralPath $legacyMsi).Hash -cne '0929E00047AD7FEA65521277AC367CC064B18983C3713A481EC3B0C34043458D') {
    throw 'legacy SDK MSI 与参考版本不符。'
}
$portableDirectory = Join-Path $simTools 'portable-hololens'
$extractLog = Join-Path $simTools 'extract-hololens.log'
if (Test-Path -LiteralPath $portableDirectory) { throw '提取目录已存在，先核对已有内容。' }
$extractProcess = Start-Process -FilePath msiexec.exe -ArgumentList @(
    '/a', ('"' + $legacyMsi + '"'), '/qn', '/norestart',
    ('TARGETDIR="' + $portableDirectory + '"'), '/L*v', ('"' + $extractLog + '"')
) -WindowStyle Hidden -PassThru -Wait
if ($extractProcess.ExitCode -notin @(0, 3010)) { throw '管理镜像提取失败，请检查日志。' }
& .\holographic-control\ops\Build-Control.ps1
```

预期文件位于 `tools/perception-simulation/portable-hololens/Windows Kits/10/Microsoft XDE/10.0.22621.0/`：

```text
PerceptionSimulationManager.dll
PerceptionSimulationManager.Interop.dll
SimulationStream.Interop.dll
PerceptionSimulationRest.dll
```

如果已经从微软安装器取得匹配的四个文件，使用 `Build-Control.ps1 -SdkDirectory <实际目录>`，不要求磁盘或用户名相同。构建器会拒绝 x64 Manager。旧目录中 `PerceptionSimulationInput.exe` 与其他 DLL 曾有架构混合，不能因为位于同一目录就断言可运行。

## 3. 恢复保护与桌面程序的工具

| 工具 | 官方来源 | 配置 |
| --- | --- | --- |
| Python | [官方 Windows 下载](https://www.python.org/downloads/windows/) | 安装后用 `python -m pip` 获取固定版本 Zig |
| Zig 0.15.2 | [Zig 官方下载](https://ziglang.org/download/) · [ziglang 包来源](https://pypi.org/project/ziglang/0.15.2/) | `python -m pip install --target .tools/zig-pypi ziglang==0.15.2` |
| MSVC x64 构建工具 | [Visual Studio 官方下载](https://visualstudio.microsoft.com/downloads/) | 安装 C++ x86/x64 工具；恢复保护构建器通过微软 `vswhere` 定位 linker |
| Windows SDK ARM64 库 | [Windows SDK](https://learn.microsoft.com/en-us/windows/apps/windows-sdk/) | 使用与本机 SDK 目录版本匹配的 `um/arm64/OneCore.Lib` |
| FFmpeg | [官方获取说明](https://ffmpeg.org/download.html) | Windows 构建来源按官方页面列出的提供者获取；让 `Get-Command ffmpeg` 指向本机已核实版本 |

FFmpeg 下载页面本次网页抓取超时，作为稳定官方入口保留；没有据此核实某个第三方 Windows 构建的最新版本。运行时、厂商包和编译结果不上传到源码仓库。

构建保护可手工指定 `-ZigPath`、`-LinkerPath` 和 `-OneCoreLibrary`。标准桌面工具仍调用自动发现路径；如果本机安装布局不受自动发现支持，应先补齐或调整构建配置再开启控制，不跳过保护。

## 4. 源码与检查入口

| 入口 | 用途 |
| --- | --- |
| [pc-control/README.md](../../../pc-control/README.md) | 自制 Windows 工具的操作说明 |
| [Build-Control.ps1](../../../holographic-control/ops/Build-Control.ps1) | legacy x86 编码器与离线自检 |
| [Build-SimulationLease.ps1](../../../holographic-control/ops/Build-SimulationLease.ps1) | 设备端 ARM64 恢复保护；自动发现本机工具 |
| [Control-Lease.ps1](../../../holographic-control/ops/Control-Lease.ps1) | 显式具名 Start/Stop/Status |
| [Test-Connection.ps1](../../../holographic-control/ops/Test-Connection.ps1) | 设备身份、证书连续性与门户认证 |
| [pc-control/ops/Build-Tests.ps1](../../../pc-control/ops/Build-Tests.ps1) | 离线指针测试，编译但不自动运行真机测试入口 |
| [TLS 测试](../../../holographic-control/tests/TlsPin.Tests.ps1) / [配对测试](../../../holographic-control/tests/PortalPairing.Tests.ps1) | 临时证书和请求替身验证，不改门户账号 |

输入、认证和恢复的使用顺序见 [通用手册](manual.md)。
