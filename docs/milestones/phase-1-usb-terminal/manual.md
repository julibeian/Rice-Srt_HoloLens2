# 第一阶段通用操作手册：Windows 电脑通过 USB 管理 HoloLens 2

适用于新电脑、新 Windows 用户或另一台 HoloLens 2。目标是建立 USB 管理终端，支持目录查询、文件传输、运行设备已有程序和自动重连。本手册不启用实时画面或鼠标控制，这些内容见 [第二阶段](../README.md)。

参考组合为 Windows 11 x64、HoloLens 2 ARM64 / Windows Holographic 22621、Windows SDK 10.0.26100.0 与 PowerShell 7。其他组合应填写 [新环境验收记录](validation.md)，不能直接继承参考组合的通过结论。

## 1. 准备设备和电脑

1. 准备支持数据传输的 USB-C 线。供电成功不代表已经建立数据链路。
2. 在眼镜的“设置 → 更新与安全 → 开发者选项”中，由设备管理员开启开发者模式和设备发现。不同系统的菜单名称可能略有变化。首次配对需要有人读取设备显示的一次性码。
3. 安装 Git、PowerShell 7 x64 和 Windows SDK，来源见 [资源清单](resources.md)。本阶段不需要 Node.js、Python、Visual Studio、完整 HoloLens 模拟器或 Perception Simulation 软件包。
4. 确认将使用同一普通 Windows 用户完成首次配对和后续运行。SDK 配对缓存、后台任务和本地命名管道均有用户范围。

微软对 HoloLens 2 推荐 USB NCM；本方案使用它，不依赖旧的 `127.0.0.1:10080` 转发服务。见 [Device Portal 的 USB 连接说明](https://learn.microsoft.com/en-us/windows/mixed-reality/develop/advanced-concepts/using-the-windows-device-portal#connecting-over-usb)。

## 2. 获取源码和专用 PowerShell 运行时

在自己选择的工作目录执行：

```powershell
git clone --branch codex/pc-hololens-connection https://github.com/julibeian/hololens-terminal.git pc-hololens
Set-Location pc-hololens
```

仓库为私人仓库时，先使用有访问权限的 GitHub 账户登录 Git。所有后续命令均从克隆后的仓库根目录执行，目录名称和磁盘盘符可以自选。

后台任务使用仓库内 `runtime/powershell/pwsh.exe`；只把系统 `pwsh` 加入 PATH 还不够。从 [PowerShell 官方发布页](https://github.com/PowerShell/PowerShell/releases) 下载稳定版 `win-x64.zip`，将完整内容解压到这个目录。保留 DLL、模块和其他运行时文件，不只复制一个 EXE。下面在 Windows PowerShell 或 PowerShell 7 中运行，交互选择已下载的 ZIP：

```powershell
$runtimeArchive = Read-Host 'PowerShell win-x64.zip 的完整路径'
if (Test-Path -LiteralPath 'runtime/powershell') {
    throw '运行时目录已存在，请先核对已有版本，不要覆盖正在使用的运行时。'
}
New-Item -ItemType Directory -Path runtime -Force | Out-Null
Expand-Archive -LiteralPath $runtimeArchive -DestinationPath runtime/powershell
$ps7 = Join-Path $PWD 'runtime/powershell/pwsh.exe'
& $ps7 -NoProfile -Command '$PSVersionTable.PSVersion'
```

后续打开新终端后，重新执行 `$ps7 = Join-Path $PWD 'runtime/powershell/pwsh.exe'`。脚本要求 PowerShell 7；不要改用 Windows 自带的 `powershell.exe` 5.1 运行。

## 3. 找到 Windows SDK 和 USB 设备

确认同一个 SDK 目录里存在 `WinAppDeployCmd.exe`、`Microsoft.Tools.Deploy.dll` 及其依赖。参考安装位置是：

```powershell
$sdkDirectory = 'C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64'
$deployTool = Join-Path $sdkDirectory 'WinAppDeployCmd.exe'
Test-Path -LiteralPath $deployTool
Test-Path -LiteralPath (Join-Path $sdkDirectory 'Microsoft.Tools.Deploy.dll')
& $deployTool devices 3
```

非默认安装位置填写自己的实际路径。输出中找到当前眼镜的设备名称、`169.254.*.*` USB 地址和发现 GUID。不要复制其他人的设备名或地址；新接入后地址和 GUID 都可能变化。设备名称用于筛选候选，SSH 主机指纹用于确认身份。

若列表为空，先检查线缆的数据能力、设备发现开关以及 Windows 设备管理器中的 USB 网络设备。已配对设备在休眠、重启或链路不可用期间也可能发现为空；这不构成重新配对或替换主机指纹的理由。

## 4. 仅在新电脑或新 Windows 用户上完成首次 SDK 配对

先尝试只读连接：

```powershell
$usbAddress = Read-Host '本次发现的眼镜 USB 地址'
& $deployTool list -ip $usbAddress -connecttimeout 8
```

已有配对且命令成功时跳过下面的配对操作。首次认证被拒绝、并确认当前目标与账号无误时，在眼镜开发者选项中点“配对”，读取屏幕上临时的开发配对码，然后在本机安全提示中输入：

```powershell
$sdkPairCode = Read-Host '眼镜开发者选项显示的临时配对码' -AsSecureString
$sdkPairText = [Net.NetworkCredential]::new('', $sdkPairCode).Password
try {
    & $deployTool list -ip $usbAddress -pin $sdkPairText -connecttimeout 8
    if ($LASTEXITCODE -ne 0) { throw 'SDK 配对或连接失败，先核对本次结果。' }
} finally {
    $sdkPairText = $null
    $sdkPairCode = $null
}
```

这是官方 SDK 的 `-pin` 参数，因此临时码会短暂存在于该 SDK 进程参数中；不将字面码写进命令历史，不运行终端转录或共享进程命令行截图。配对码不是开机 PIN，也不是第二阶段的门户配对码。该步骤读取应用列表，不安装或卸载应用。[WinAppDeployCmd 官方参数](https://learn.microsoft.com/en-us/windows/uwp/packaging/install-universal-windows-apps-with-the-winappdeploycmd-tool)。

此后用不带 `-pin` 的 `list` 再检查一次。不要为日常重连、USB 地址改变或 GUID 改变而重复配对。

## 5. 建立并核对设备身份配置

已存在 `config.json` 时先保留并核对，不用模板覆盖。新环境创建一次：

```powershell
if (-not (Test-Path -LiteralPath config.json)) {
    Copy-Item -LiteralPath config.example.json -Destination config.json
}
& $ps7 -NoProfile -File tools/connection/Get-DeviceIdentity.ps1 `
    -SdkDirectory $sdkDirectory -Address $usbAddress
```

辅助脚本只读取已配对连接的 SSH 指纹，不修改配置、不申请新的配对，也不创建远端目录。没有传入可信基准时，输出 `IdentityVerified=false`，表示只观察到指纹。它不能替你判断首次目标是否正确。

已有设备由管理员提供原有可信指纹，通过受控渠道比对。新设备首次建档则由管理员结合实际 USB 接线、设备名称、设备显示和刚完成的配对确认目标，将观察值作为首次基准。把确认后的值手工填写到 `config.json`；不要用脚本把任意观察值自动覆盖为可信值。新环境可以再次显式比较：

```powershell
$trustedFingerprint = Read-Host '管理员核实的原设备 SSH 指纹'
& $ps7 -NoProfile -File tools/connection/Get-DeviceIdentity.ps1 `
    -SdkDirectory $sdkDirectory -Address $usbAddress `
    -ExpectedFingerprint $trustedFingerprint
```

| 配置项 | 填写规则 |
| --- | --- |
| `DeviceName` | 本设备在 SDK 发现输出中的完整名称 |
| `DiscoveryGuid` | 本次发现值；仅为优先提示，改变后仍必须检查同一 SSH 身份 |
| `ExpectedFingerprint` | 核实过的原 SSH 指纹，保留 SDK 返回的格式和大小写 |
| `SdkDirectory` | 含部署工具和 SDK DLL 的实际 x64 目录 |
| `RemoteWorkingDirectory` | 该开发用户可写的远端工作目录；连接脚本会在不存在时创建 |
| `ScheduledTaskName` | 本工具的任务名；默认 `HoloLensUsbSshBridge`，不能覆盖别的应用的任务 |
| `KeepAliveSeconds` / `ReconnectSeconds` | 默认均为 5 秒 |
| `CommandTimeoutSeconds` | 默认 30 秒；超时后的未知结果不自动重发 |
| `InitialAddress` | 保留兼容字段；当前 USB 自动发现不依赖它，不是已经配置好的 Wi-Fi 备用链路 |

JSON 内反斜杠写为 `\\`，例如配置模板里的 SDK 路径。配置和 `.state/` 均被 Git 忽略。

## 6. 离线检查，再启动后台桥

```powershell
& $ps7 -NoProfile -File tools/connection/Test-Workstation.ps1
& $ps7 -NoProfile -File tests/HoloLens.Discovery.Tests.ps1
& $ps7 -NoProfile -File tests/HoloLens.Connection.Tests.ps1
& $ps7 -NoProfile -File tests/HoloLens.StatusFile.Tests.ps1
```

以上检查不执行设备命令。可另运行 `tests/HoloLens.DiscoveryProcess.Tests.ps1` 验证 SDK 发现子进程的超时清理；它会启动一次真实 SDK 发现，但不配对、不写设备。

前置检查通过后：

```powershell
& $ps7 -NoProfile -File Start-HoloLensBridge.ps1 -InstallAutostart
& $ps7 -NoProfile -File Connect-HoloLens.ps1 -Command status
& $ps7 -NoProfile -File Connect-HoloLens.ps1 -Command info
& $ps7 -NoProfile -File Connect-HoloLens.ps1 -Command 'tzutil /g'
```

任务以当前 Windows 用户运行，不需要保存 Windows 密码，也不提升为管理员。`State=connected`、新的心跳和实际只读命令成功一起构成本轮管理通道可用证据。`status` 返回成功只说明本机后台可响应；`waiting_for_device` 则是等待设备，不是已连通。

常用状态字段：`State`、`UpdatedAt`、`LastHeartbeat`、`ActiveOperation`、`LastError`、`Connections`、`SourceHashes`。`SourceHashes` 是当前桥进程加载的源码摘要，便于排除“磁盘源码已更新但后台还运行旧代码”。

## 7. 使用受限管理终端

```powershell
& $ps7 -NoProfile -File Connect-HoloLens.ps1
```

交互终端中使用：

```text
help
info
pwd
ls
tzutil /g
exit
```

`exec` 运行设备上已有的程序；设备固件没有常规 CMD/PowerShell shell，不能把管道、重定向或 shell 内置命令原样发送过去。当前权限为普通开发用户，不是管理员或 SYSTEM。

文件传输需要明确指定两端路径。例如本机先创建 UTF-8 测试文件，再以全新文件名进行往返：

```powershell
$transferId = [guid]::NewGuid().ToString('N')
$localSource = Join-Path $PWD ('.state\transfer-' + $transferId + '.txt')
$localReturn = Join-Path $PWD ('.state\return-' + $transferId + '.txt')
[IO.File]::WriteAllText($localSource, 'USB round-trip', [Text.UTF8Encoding]::new($false))
$remoteFile = 'transfer-' + $transferId + '.txt'
& $ps7 -NoProfile -File Connect-HoloLens.ps1 -Command ('put "{0}" "{1}"' -f $localSource, $remoteFile)
& $ps7 -NoProfile -File Connect-HoloLens.ps1 -Command ('get "{0}" "{1}"' -f $remoteFile, $localReturn)
(Get-FileHash -LiteralPath $localSource).Hash -eq (Get-FileHash -LiteralPath $localReturn).Hash
```

预期得到 `True`。传输不覆盖已有文件，远端测试文件会保留在自己的工作目录中。终端 `exit` 只关闭前台，后台继续保活。

## 8. 重连、更新与停止

```powershell
& $ps7 -NoProfile -File Connect-HoloLens.ps1 -Command reconnect
& $ps7 -NoProfile -File Connect-HoloLens.ps1 -Command status
```

等待 `connected` 后重新执行只读命令。`reconnect` 只接受重连请求，不能直接当作恢复成功。命令超时可能已经在设备执行，应先查询原结果；不能自动重放安装、启动或其他有副作用的操作。

更新代码前先停止当前桥，更新后重新启动；移动目录时也要检查任务实际指向的位置。同一 Windows 用户一次只运行一个本项目桥，多个克隆共用该用户的管道名。

```powershell
& $ps7 -NoProfile -File Stop-HoloLensBridge.ps1 -DisableAutostart
git pull --ff-only
& $ps7 -NoProfile -File Start-HoloLensBridge.ps1 -InstallAutostart
```

如果新目录遇到任务归属冲突，保留旧任务并查明来源，不强行覆盖。先在旧目录停用它，再为新目录填写独立任务名；不得同时运行两个桥。只想停止时执行 `Stop-HoloLensBridge.ps1 -DisableAutostart`，本项目的配置与配对记录会保留。

## 9. 常见问题与判断顺序

| 现象 | 判断与处理 |
| --- | --- |
| 缺少专用运行时 | 将完整官方 x64 PowerShell ZIP 解压到约定目录，不能只安装系统别名 |
| SDK DLL 加载失败 | 核对完整 SDK、x64 目录及依赖；不要从 DLL 下载站拼装 |
| 发现超时或没有目标 | 检查 USB NCM、设备发现和电源状态；单次 SDK 发现最多等待 12 秒，之后由后台重试 |
| GUID 或地址改变 | 重新发现；仍使用原 SSH 指纹核对，不重配对 |
| 主机指纹不一致 | 停止连接并核实是否更换或重刷了设备；不自动信任新指纹 |
| 元数据为空或读取异常 | 保留 `MetadataErrors`；已验证 SSH 身份与实际命令结果独立判断，不能编造型号或认定退出 |
| 本机任务运行但命令不通 | 查看 `.state/bridge.log`、`.state/watchdog.log`、状态进度与实际设备可达性 |
| 桥进程活着却卡住 | 监督器默认在进度停止超过 120 秒后恢复自己的桥；长命令按超时设置扩展预算，不重放未知操作 |
| 接电后短时可用又失联 | 记录设备电源与低功耗状态。按设备管理策略备份并调整接电待机配置，保留电池原值；不要从一次成功推出永久在线 |
| Wi-Fi 连接正常但 USB 管理失败 | Wi-Fi、云端服务和 USB 管理是三条独立检查，不能互相替代 |
| 想看到画面或点按 | 转入第二阶段；第一阶段的终端连通不能证明显示或输入可用 |

## 10. 新环境完成条件

按 [验证说明](validation.md) 留存：自己使用的系统与 SDK 版本、原设备身份核对结论、实际只读命令、文件往返哈希、主动重连后的命令以及后台退出恢复结果。重启、拔插和长期运行只有实际测试过才填写通过。

本阶段的重启恢复记录来自既有设备的单次历史验收；本次文档整理没有再次重启设备。后台仍可能等待关机或深度休眠的眼镜，不能承诺在任何状态下都能唤醒。
