# 微软 Perception Simulation 对照工具

以微软原版 3.0.24.0 为主要测试对象；本目录的程序只负责安装核查和 SDK 探针，不替换原版 GUI。原有 `pc-control/desktop` 使用的 legacy x86 SDK 与本目录 x64 运行目录隔离。

## 安装

先使用项目提供的 PowerShell 7 下载并校验微软签名和固定版本哈希：

```powershell
& .\runtime\powershell\pwsh.exe -NoProfile -File .\pc-control\official\Get-OfficialControl.ps1
```

在管理员 PowerShell 7 中安装：

```powershell
# 默认仅安装原版界面、SDK 和示例。
& .\pc-control\official\Install-OfficialControl.ps1

# 明确选择官方驱动和后台服务；用户已在本次任务中要求补齐。
& .\pc-control\official\Install-OfficialControl.ps1 -IncludeDriversAndService
```

`-EnableDeveloperMode` 是单独的电脑设置选项。安装过程保存原设置、所选功能、MSI 日志、退出码和驱动/服务清单，不自动重启。Windows 驱动发布者确认可能需要维护者在系统安全窗口完成；签名有效和安装完成分别记录。

## 电脑侧测试

```powershell
& .\pc-control\official\Test-OfficialControl.ps1 -Mode Offline -RunId example-offline
& .\pc-control\official\Test-OfficialControl.ps1 -Mode Service -RunId example-service
& .\pc-control\official\Test-OfficialControl.ps1 -Mode LocalDevice -RunId example-local-device
```

- `Offline`：枚举平台、生成头部/视线/双手输入，录制 XEF 并回放至计数接收器。
- `Service`：离线测试加本机官方 COM 服务激活，必须先完成 Service 安装。
- `LocalDevice`：再创建一个本机 WMR 模拟设备和自身控制流，最后移除该设备；这项测试会改变本机模拟设备的临时状态。

`Service` 和 `LocalDevice` 需在管理员 PowerShell 中执行。`LocalDevice` 还会先检查系统版本和 Holographic 设备类；微软已从 Windows 11 24H2 起移除 WMR，因此在这些系统上保存 `prerequisite_failed`，不创建设备。该限制针对本机 WMR 模拟设备，HoloLens 远程连接另行验收。参见[微软移除功能说明](https://learn.microsoft.com/en-us/windows/whats-new/removed-features)。

这些测试都不连接物理 HoloLens。相同 Mode/RunId 读取已有结果，不重复调用，保留已有失败退出码。原始输出、构建摘要和测试记录位于 `pc-control/.state/official-tests/`。若结果为 `process_pending`，应先调查原进程和清理状态，不换编号重复创建设备。创建接口报错也可能已留下设备节点，需核对本次操作前后的 PnP 证据后，仅清理本次创建的节点。

探针使用 `%ProgramFiles%/Microsoft Perception Simulation/Sdk/References` 中的一致 x64 文件；构建时核对原版 Manager 哈希并保存源码快照。录制测试在打开回放文件前释放所有子 COM 引用，避免托管互操作对象延长文件占用。

服务测试按官方本机服务示例指定 `CLSCTX_LOCAL_SERVER`，不使用默认的进程内激活。当前电脑上普通权限调用被拒绝，管理员调用通过；未修改 COM 访问权限或微软程序。

2026-10-26 实际结果：3.0.24.0 的六项安装功能完成，MSI 退出码 0、无需重启，三个驱动包已进入驱动存储。官方 GUI 启动、Legacy 选择、离线 SDK 与管理员服务测试通过；本机 WMR 创建因缺少设备类失败，测试残留已清理。证据见[安装与测试记录](../../reports/20261026-official-drivers/安装与测试记录.md)。

## 真机测试

电脑侧测试通过后，按 [官方 GUI 对照流程](../../docs/milestones/phase-2-ricefield-control/official-3.0.24.0-test.md) 核对原设备身份、保存的门户认证和当前新画面。任何真机输入都需先建立具名 300 秒设备保护，结束后关闭自身流并确认同名租约恢复 Default(0)。本机虚拟设备测试与物理眼镜测试不能互相替代。

官方程序弹出 Windows Device Portal 登录框时，由维护者手工登录。若账号是本项目生成并保存在当前 Windows 用户 DPAPI 中，可运行下面的本机辅助窗口：

```powershell
& .\runtime\powershell\pwsh.exe -NoProfile -Sta -File .\pc-control\official\Open-PortalCredentialHandoff.ps1
```

辅助窗口先核对当前 USB SSH 身份、门户服务器公钥及已有凭据认证。维护者点击按钮复制用户名和密码，再手工粘贴到官方登录框；脚本不填充或提交登录窗口，不修改账号，不显示或记录明文密码。复制的密码 30 秒后清除，窗口关闭时也仅清除仍属于本窗口的密码。该辅助过程本身不代表官方认证、视频或输入已通过。

## 2026-10-26 诊断进度

本轮用户要求代理自主完成官方测试。已保存的账号在固定证书的原生 WinRT HTTPS 请求中返回 200，但原版 GUI 未复用该会话；其独立认证框没有呈现可验证的账号输入，未继续发送密码或提交。官方视频和点按仍未验收，详见[本轮记录](../../reports/20261026-phase2-live/官方测试进度.md)。

新增诊断入口均不修改微软二进制文件：

- `Test-OfficialRemote.ps1`：在具名保护内调用安装包自己的 x64 Native 或 Legacy REST 库；凭据仅经私有 stdin，结果与 GUI 验收分开。相同编号返回已有结果。
- `Initialize-OfficialHttpAuthentication.ps1`：调用 Windows 原生 HTTP 接口，严格固定原门户证书，限定 180 秒保留会话。HTTP 200 不代表原版 GUI 已登录，跨进程复用未通过。
- `Inspect-OfficialWindows.ps1`：只读核对官方窗口、所属认证弹窗及输入桌面，不读取密码值。
- `Invoke-OfficialLoginInput.ps1`：仅用于已有明确授权的诊断，要求精确原版 EXE、同一设备及有效具名保护。输入 API 接受不等于视觉生效；未验证账号栏时默认拒绝密码，未验证密码栏时默认拒绝提交。本轮只尝试了用户名。
- `Open-PortalCredentialClipboard.ps1`：独立 Windows 辅助窗口，凭据经私有 stdin 进入；密码不显示、不记录，复制内容限时清除。它也不能代替官方 GUI 的输入验证。

## 2026-10-27 本机认证转发试验

用户已要求代理自主输入和检测，旧手工辅助流程不再作为当前任务的前置条件。本轮试验 `Build-OfficialAuthRelay.ps1` / `Start-OfficialAuthRelay.ps1`：只向指定、固定哈希的微软原版 GUI 进程开放临时回环端口，再经原 SSH 身份、固定证书和已有门户会话转到原眼镜；必须已有有效具名设备保护，270 秒内停止。凭据和 CSRF 只通过私有 stdin，未知路径和非自身流被拒绝；相同编号不重放。

原版 GUI 经此转发的模式查询与控制流创建已有 HTTP 200，独立 PowerShell 访问被拒绝。输入 WebSocket 的断开删除参数已补齐支持，但电脑高权限壁纸屏保阻挡后续 GUI 操作，尚未取得官方视频和点按成功。临时连接不等于原版直接登录框已通过，转发器也不生成输入或画面。运行格式和恢复必须沿用具名设备保护，详情见[本轮记录](../../reports/20261027-official-focus/官方续测记录.md)。
