# 独立输入验证场景

此应用用于二阶段 T04/T05 的输入对照。包为 `Rice.HoloLens.InputProbe`，不包含相机、麦克风或联网能力，与稻视界分开安装。三个选择按钮、拖动区、滑块和普通文字框提供可观察结果；会话与最近 500 个事件保存到自己的 `LocalState/input-probe-state.json`，每条事件区分 `isTrusted`，避免把浏览器替身事件当作真机输入。

使用 `ops/Build-InputProbe.ps1` 构建，再使用 `ops/Invoke-InputProbe.ps1` 的 Install、Launch、State 分别安装、激活和读回。安装版本和激活回执分别记录，必须继续核对真实新画面与应用会话。读取保存事件不表示应用此刻仍在前台。

`ops/New-Phase2InputTrial.ps1` 冻结每轮来源、场景和源码，`ops/Add-Phase2Observation.ps1` 归档不可覆盖的观察。`ops/Start-Phase2InputConsole.ps1` 是明确的诊断入口：具名 300 秒保护、单一所有者、每次选择前后视频、输入只发一次和正常清理。`-InitializeProbe` 只初始化模拟位姿并激活本测试场景，不发送 tap 或 Home。常规产品仍需实现通用目标模型。

MRC 两次短采样之间留有间隔；只有 84 字节容器头的 HTTP 200 被记为不完整。读取可以重试，输入命令不重发。黑色新帧不作为可见目标成功的证据，点击仍需结合实际画面定位与应用事件。

2026-10-27：1.0.0.0 真机安装、真实画面、同会话一次原生 B 点击和 Home 开始菜单已有本机记录。系统 Start 的 Settings 点按尚未打开设置，不能把悬停高亮或包计数当作通过。未达到 A05 的四类各 30 次要求。

技术依据：[微软门户应用启动与文件读取](https://learn.microsoft.com/en-us/windows/uwp/debug-test-perf/device-portal-api-core)、[微软 Perception Simulation](https://learn.microsoft.com/en-us/windows/mixed-reality/develop/advanced-concepts/perception-simulation-overview)。SDK 输入接受和应用可见响应分层记录。
