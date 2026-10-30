# 第二阶段通用操作手册：真机稻视界眼镜控制

本阶段在已配对的 USB 管理通道上启用门户认证、真实全息视频和鼠标输入。先完成 [第一阶段](../phase-1-usb-terminal/manual.md) 的身份、实际命令和恢复检查，再从本手册继续。微软 **3.0.24.0** 官方软件包按 [对照测试计划](official-3.0.24.0-test.md) 单独验收。

适用范围是 HoloLens 2 上的本项目稻视界应用。现有桌面工具不是任意 Windows 应用的远程桌面，也没有获得所有系统控件的验收结论。

## 1. 获取第二阶段源码

在自己的仓库中先结束正在运行的控制、关闭自身流并确认 Default(0)，再停止旧目录的桥并更新：

```powershell
git fetch origin
git switch codex/ricefield-device-control
& .\runtime\powershell\pwsh.exe -NoProfile -File usb-terminal/Start-HoloLensBridge.ps1 -InstallAutostart
& .\runtime\powershell\pwsh.exe -NoProfile -File usb-terminal/Connect-HoloLens.ps1 -Command status
```

不要把其他电脑的 `config.json`、`.state/` 或 DPAPI 凭据覆盖到本机。如果使用新的克隆，按第一阶段为此目录配置运行时、任务和配对。下文从仓库根目录打开 PowerShell 7 会话：

```powershell
& .\runtime\powershell\pwsh.exe -NoProfile
```

在这个 PowerShell 7 会话中直接调用脚本；含 `PSCredential` 或 `SecureString` 的参数在同一进程内传递，不能改写成命令行中的明文值。

## 2. 准备控制与构建依赖

来源和完整步骤见 [资源清单](resources.md)。自制控制工具需要：

| 依赖 | 用途 |
| --- | --- |
| 第一阶段的运行时、SDK、可信配置与 USB 桥 | 已认证设备管理 |
| legacy x86 Perception Simulation SDK 的四个匹配 DLL | 本项目 x86 输入编码器；不能换成 3.0.24.0 的 x64 DLL |
| Windows 自带 .NET Framework C# 编译器 | Windows Forms 和控制器 |
| FFmpeg 命令 | 解码官方全息视频；构建时记录本机实际位置 |
| Python、Zig 0.15.2、MSVC x64 构建工具、Windows SDK ARM64 `OneCore.Lib` | 构建设备端 300 秒恢复保护 |
| Node.js 与本项目应用构建输入 | 在新设备部署稻视界；已有完整安装材料时可按受控部署流程复用 |

恢复保护构建器通过 `vswhere` 找到本机 MSVC，通过 `config.json` 中的 SDK 路径定位 ARM64 库；不再依赖原开发电脑的 Visual Studio 版本目录。自定义工具位置可通过构建脚本参数指定。

## 3. 在目标眼镜准备稻视界应用

新设备或缺少本机安装记录时，按 [开发指南](../../development.md) 准备 Node.js、SDK 和应用构建输入，再构建及部署：

```powershell
npm --prefix apps/field-app ci
& .\apps/field-app\ops\Build-App.ps1 -Version 1.0.0.22
& .\apps/field-app\ops\Install-App.ps1
& .\apps/field-app\ops\Start-App.ps1
& .\apps/field-app\ops\Get-AppState.ps1
```

安装和启动请求被接受后仍须读回实际运行版本与会话，不能只用退出码判断新版运行。此部署使用项目开发目录和固定应用身份 `Rice.HoloLens.Field_r5420n6798s24!Field`。新电脑缺少 `.state/installed.json` 时，不随意手写或复制另一台设备的安装回执。

`Start-App.ps1` 另含项目既有的联网检查与受限恢复策略；其中历史 NJAU 网络配置不是其他环境的通用前提。USB 观看和管理不依赖校园 Wi-Fi，云端识别则需要眼镜自己的服务访问成功，分别记录结果。

## 4. 验证门户并在本 Windows 用户下保存认证

在眼镜开发者设置中启用 Device Portal。先运行：

```powershell
& .\apps/holographic-control\ops\Test-Connection.ps1
```

脚本先核对第一阶段的原 SSH 身份，再建立同一 USB 目标的门户证书记录。后续仅允许已经核查的同公钥证书连续更新，不通过关闭 TLS 检查解决证书变化。

已有保存凭据且认证成功时直接复用。新电脑上已有门户账号时，在本机安全提示输入，然后保存到当前 Windows 用户：

```powershell
$portalCredential = Get-Credential -Message '输入该眼镜已有的 Device Portal 账号'
& .\apps/holographic-control\ops\Save-PortalCredential.ps1 -Credential $portalCredential
$portalCredential = $null
& .\apps/holographic-control\ops\Test-Connection.ps1
```

预期 `SshIdentityVerified`、`PortalCertificatePinned`、`PortalAuthenticated` 均为 `true`。`InputVerified=false` 和 `LiveViewVerified=false` 表示这个连接检查自身不做输入或视觉判定，不等于已验证功能失效，也不能据它们宣布所有功能成功。

DPAPI 凭据绑定当前 Windows 用户和设备。换电脑或换用户后重新保存自己的凭据；不能直接复制原电脑的 `.clixml`。不要把认证失败与 USB 发现暂为空混为一谈。

只有设备尚未建立门户账号，且管理员明确决定创建或更新门户认证时，才使用下面的显式配对流程。它可能替换已有门户账号，但不改变开机 PIN 或 SDK SSH 配对：

```powershell
$portalRun = 'portal-' + [guid]::NewGuid().ToString('N')
& .\apps/holographic-control\ops\Set-Up-PortalAccess.ps1 -Mode Start -RunId $portalRun
$portalPin = Read-Host '眼镜当前显示的门户一次性码' -AsSecureString
& .\apps/holographic-control\ops\Set-Up-PortalAccess.ps1 -Mode Complete -RunId $portalRun -Pin $portalPin
$portalPin = $null
& .\apps/holographic-control\ops\Set-Up-PortalAccess.ps1 -Mode Status -RunId $portalRun
```

同一 RunId 只取回原结果。网络超时后先查 Status，不重发账号变更。未取得实际门户临时码时不提交，不使用开机 PIN 代替。官方 GUI 的认证也必须复用这个目标的有效门户账户，见 [官方测试的认证要求](official-3.0.24.0-test.md)。

## 5. 离线构建和检查

```powershell
& .\apps/holographic-control\ops\Build-Control.ps1
& .\apps/holographic-control\ops\Build-SimulationLease.ps1
& .\apps/pc-control\Build.ps1 -DesktopShortcut
& .\apps/pc-control\ops\Build-Tests.ps1
& .\apps/holographic-control\ops\Start-PerceptionControl.ps1 -SelfTest
```

这些命令构建并检查本机程序，不开始设备控制。`Build-SimulationLease` 仅产生 ARM64 程序；设备保护在后续显式 Start 时才部署并启动。`Build-Tests` 编译显式真机入口但只自动运行离线指针测试，不自动执行真机点按。

`apps/pc-control/dist/runtime.json` 由本机生成，内含 FFmpeg 实际路径。移动或更换解码器后重新构建，不把别人的绝对路径当作可移植配置。专用 PowerShell 的完整运行时仍须保留。

## 6. 先取得可解码的真实画面

```powershell
$previewRun = 'preview-' + [guid]::NewGuid().ToString('N')
& .\apps/holographic-control\ops\Get-PortalLiveSample.ps1 -RunId $previewRun -Seconds 2
```

按输出的本机视频文件路径使用 FFmpeg 解码并实际查看。HTTP 200、少量字节或未解码的流均不证明看到了全息界面。区分真实全息显示、独立 PV 相机和 PC 上离线渲染的界面预览。样本、视频与画面只保存在本机。

## 7. 使用自制 Windows 图形工具

打开 `apps/pc-control/dist/RiceHoloLensControl.exe`，或构建时创建的桌面快捷方式。

1. 等待新的真实画面，点击“开始控制”。工具建立独立的具名 300 秒设备保护，打开稻视界并校准鼠标。
2. 校准完成后单击画面中的目标。后端用新画面确认准星后才发送一次点按；操作后继续看新画面，确认具体控件变化。
3. 使用右键拖动或方向按钮调整视角，“靠近／退后”调整虚拟观看距离。调整后首次点按重新校准。
4. “开始菜单”发送 Home，“打开稻视界”回到本应用。截图和事件位于本机 `apps/pc-control/.state/sessions/`。
5. 点击“停止控制 · 恢复眼镜”或关闭窗口。读取本次恢复结果，确认自己的控制流关闭、同名保护恢复 `Default(0)`。

每次控制最多 5 分钟。显示画面超过 2.5 秒没有更新时拒绝点按；未知结果先核对，不重复点击。自制工具与微软官方 GUI 不同时连接控制，也不同时运行另一个显式真机测试入口。

## 8. 脚本实验的保护与停止

脚本控制必须自行建立具名保护；桌面工具已经管理自己的保护，不叠加另一套同类控制。

```powershell
$controlRun = 'control-' + [guid]::NewGuid().ToString('N')
& .\apps/holographic-control\ops\Control-Lease.ps1 -Mode Start -RunId $controlRun
try {
    & .\apps/holographic-control\ops\Start-PerceptionControl.ps1
} finally {
    & .\apps/holographic-control\ops\Control-Lease.ps1 -Mode Stop -RunId $controlRun
    & .\apps/holographic-control\ops\Control-Lease.ps1 -Mode Status -RunId $controlRun
}
```

交互输入前查看新画面。`streamId` 是不透明值，保留大小写。超时后继续查同一 RunId；不创建新编号去重复未知结果。保护恢复结果还未取得时，保留该编号并继续查询，不把进程结束当作已恢复。

## 9. 进入微软官方软件对照测试

按 [3.0.24.0 官方测试计划](official-3.0.24.0-test.md) 分别记录画面、已选控件、Home、中断、关闭与模式恢复。官方包校验成功、官方文档声称支持以及自制后端已通过，均不能替代官方 GUI 的当前真机结果。
