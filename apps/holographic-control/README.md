# 全息显示与实验控制

本模块辅助 HoloLens 实验：获取官方全息显示样本、用官方 SDK 编码输入，并以设备端限时租约保证控制结束后恢复默认模式。应用内正常采集不依赖 PC 控制器。

这些能力属于 [第二阶段：真机稻视界眼镜控制](../../docs/milestones/phase-2-ricefield-control/README.md)，在第一阶段 USB 管理连接完成后单独验收。新电脑按 [通用手册](../../docs/milestones/phase-2-ricefield-control/manual.md) 准备；微软 **3.0.24.0** 官方软件包按 [对照测试计划](../../docs/milestones/phase-2-ricefield-control/official-3.0.24.0-test.md) 验证，不混用本项目 legacy x86 DLL。

Windows 图形入口见 [稻视界眼镜控制](../../apps/pc-control/README.md)，支持真实视频、鼠标定位点按、视角调整与停止恢复。脚本控制器的 `pose`、`status` 现在包含模拟手的可见状态；超出追踪范围时 `tap` 拒绝发送。实验中可以显式使用 `hand-frustum ignore`，仅影响当前模拟会话。

## 入口

配置设备与门户凭据后，在仓库根目录使用 PowerShell 7：

```powershell
pwsh -NoProfile -File apps/holographic-control/ops/Test-Connection.ps1
pwsh -NoProfile -File apps/holographic-control/ops/Build-Control.ps1
pwsh -NoProfile -File apps/holographic-control/ops/Start-PerceptionControl.ps1 -SelfTest
pwsh -NoProfile -File apps/holographic-control/ops/Get-PortalLiveSample.ps1 -RunId preview-check -Seconds 2
```

`Test-Connection` 复用已有认证；不因为 USB 暂不可达而重新设置账户。`Get-PortalLiveSample` 限时采样，同一 RunId 读取原结果。传输成功仍需解码并检查实际画面。

## 控制会话

```powershell
$controlRunId = 'experiment-control-' + [guid]::NewGuid().ToString('N')
pwsh -NoProfile -File apps/holographic-control/ops/Control-Lease.ps1 -Mode Start -RunId $controlRunId
try {
    pwsh -NoProfile -File apps/holographic-control/ops/Start-PerceptionControl.ps1
} finally {
    pwsh -NoProfile -File apps/holographic-control/ops/Control-Lease.ps1 -Mode Stop -RunId $controlRunId
}
```

租约由设备独立计时 300 秒，拒绝抢占已有非默认模式。结束时关闭自身流，核对同名租约恢复 Default(0)。输入结合当前画面执行；接口接受、模拟位姿与真实可见效果分别记录。`streamId` 保留大小写，凭据与 CSRF 会话经私有 stdin 传递。

## 环境与认证

PC 控制器依赖匹配的 **x86** SDK 组件，构建器从 `tools/perception-simulation/portable-hololens/Windows Kits/10/Microsoft XDE/10.0.22621.0` 读取。SDK 安装介质不进入源码仓库。

门户凭据以当前 Windows 用户的数据保护保存，且绑定设备 SSH 身份和门户服务器密钥。同公钥证书续签需连续性核验。需要首次配置时使用 `Set-Up-PortalAccess.ps1` 的显式 Start/Complete 流程，由设备管理员提供实际临时码；Status 默认只读。

## 诊断工具

`Invoke-LocalSimulationTest.ps1` 默认 Inspect，只读检查本机控制接口；Presence/Home 为显式限时实验。MRC、窗口、生命周期与原生探针按各自用途运行。相同操作编号不重发，超时继续观察原操作。

公开的版本验证只覆盖已观察的取景框与快门两项操作，见 [实验摘要](../../experiments/results/pipeline-v1.0.0.22.md)。原始显示流、设备环境与运行记录保存到执行环境的 `.state/`。
