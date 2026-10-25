# 第一阶段资源清单

维护日期：2026-10-25。资源用于 USB 管理终端；实时画面、鼠标输入与微软 3.0.24.0 官方控制软件包归入 [第二阶段](../README.md)。

## 外部依赖

| 资源 | 获取入口 | 用途与选择 |
| --- | --- | --- |
| Git for Windows | [官方安装页](https://git-scm.com/downloads/win) | 克隆仓库与后续更新；私人仓库需要访问权限 |
| PowerShell 7 x64 | [官方 Windows 安装说明](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-windows) · [官方发布附件](https://github.com/PowerShell/PowerShell/releases) | 本项目后台使用完整 ZIP 运行时，放入 `runtime/powershell/`；不随源码分发 |
| Windows SDK | [微软 SDK 入口](https://learn.microsoft.com/en-us/windows/apps/windows-sdk/) · [历史版本入口](https://learn.microsoft.com/en-us/windows/apps/windows-sdk/downloads-archive) | 参考目录版本 `10.0.26100.0`；以实际包含部署工具与 DLL 的目录填写配置，优先获取该系列受维护的更新 |
| USB NCM 配置说明 | [微软 Device Portal：USB](https://learn.microsoft.com/en-us/windows/mixed-reality/develop/advanced-concepts/using-the-windows-device-portal#connecting-over-usb) | 设备开发者设置与 USB 数据网络；HoloLens 2 默认支持 NCM |
| SDK 配对与命令参数 | [WinAppDeployCmd 官方说明](https://learn.microsoft.com/en-us/windows/uwp/packaging/install-universal-windows-apps-with-the-winappdeploycmd-tool) | 发现、只读应用列表与首次临时码认证；不是常规远程 shell |

SDK 的版本号、安装器版本和安装目录版本未必相同。第一阶段只要求管理工具，不要求安装完整模拟器。旧安装包仅用作复现参考，不把它标成最新版本。

## 仓库资源

| 文件 | 用途 |
| --- | --- |
| [config.example.json](../../../config.example.json) | 不含真实设备身份的配置模板 |
| [Get-DeviceIdentity.ps1](../../../tools/connection/Get-DeviceIdentity.ps1) | 首次建档或迁移时，观察已配对设备的 SSH 指纹，支持与管理员提供的可信基准比较；不修改配置 |
| [Test-Workstation.ps1](../../../tools/connection/Test-Workstation.ps1) | 只读检查本机运行时、SDK、配置占位符和关键后台脚本，不联系设备 |
| [Connect-HoloLens.ps1](../../../Connect-HoloLens.ps1) | 终端与单次命令入口 |
| [Start-HoloLensBridge.ps1](../../../Start-HoloLensBridge.ps1) / [Stop-HoloLensBridge.ps1](../../../Stop-HoloLensBridge.ps1) | 后台启动、停止及当前用户自启管理 |
| [Register-HoloLensTask.ps1](../../../Register-HoloLensTask.ps1) | 注册当前用户后台任务，检查已有任务归属 |
| [HoloLens.Common.ps1](../../../HoloLens.Common.ps1) | SDK 发现、原 SSH 身份核对、受限文件和程序操作 |
| [HoloLens.Bridge.ps1](../../../HoloLens.Bridge.ps1) / [HoloLens.Watchdog.ps1](../../../HoloLens.Watchdog.ps1) | 用户范围的管道服务、保活、会话复用与卡住恢复 |

源码随本仓库版本维护。微软与其他第三方运行时从各自官方来源获取，并遵守其许可证；本分支不重新打包或上传厂商二进制。

## 检查与结果

四组连接检查分别位于 `tests/HoloLens.Discovery.Tests.ps1`、`tests/HoloLens.Connection.Tests.ps1`、`tests/HoloLens.DiscoveryProcess.Tests.ps1` 和 `tests/HoloLens.StatusFile.Tests.ps1`。前三者中的发现进程检查会启动 SDK 发现子进程，其余使用离线对象或本机文件锁；都不重新配对或执行设备写入。

已有真机结果与新的复现模板见 [验证说明](validation.md)，问题与修复顺序见 [迭代历史](history.md)。原始报告、设备名、网络地址、凭据和配对缓存不作为通用资源发布。
