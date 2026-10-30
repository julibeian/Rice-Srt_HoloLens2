# USB 重连后的低功耗排查

2026 年 10 月 29 日下午续做。桌面程序仍为 **0.3.2.0**，本轮新增设备端只读电源诊断和低清源测量入口，没有更换桌面二进制。当前重连后远程唤醒仍未成功，25 fps 和新版真机 DPI 回归继续保留。

## 连接时间线与结论更正

后台日志显示 12:34:41 USB 管理链路离线，13:56:07 重新认证连接，中间约 81.4 分钟不可达。真实 GUI 最后仍有新帧的记录为 12:34:41；11:20 之后该 GUI 没有再发送控制命令。

下午看到“功耗代理确认序号推进，但设备低功耗”不能证明**连续 USB 连接期间**发生了保活失效，也不能确定进入低功耗的时刻。实际物理拔插仍未直接验收。当前已确定的缺口是：设备重连后，已有策略没有将低功耗设备恢复到有效供帧状态。完整“接入电脑就切换正常功耗”要求尚未达到。

## 本轮真实观察

| 项目 | 观察结果 |
| --- | --- |
| 原 USB 身份与门户 | 原指纹、既有证书与保存凭据通过 |
| 当前电源方案 | DC 休眠、无人值守和显示超时均读回 0；不是只写了 AC 分支 |
| 电源能力 | 系统报告 S0 Low Power Idle Network Connected；当前电池接口报告 `AcOnline=1`，与上午的 0 分时记录 |
| 额外 30 秒电源请求 | Display、System、Execution 三类均被接受并正常清除；期间仍低功耗 |
| 设备原生只读查询 | SystemExecutionState、空闲信息、LastSleepTime／LastWakeTime 查询成功；执行标志为 2，两个时间为 0，不能当作已醒或从未休眠的证明 |
| 事件与 SleepStudy | 原生 System 事件查询返回 120；门户 SleepStudy 返回 403，不用空结果推断没有休眠事件 |
| 当前温度 | Thermal stage 0，各缓解级别 0；没有据此定位全部低功耗原因 |
| 重连后的 presence 尝试 | 新建 300 秒具名保护，仅一次 presence，无点按、无应用启动；仍低功耗，中清视频 40 字节 |
| 清理 | 自身流 DELETE 200，同名保护恢复 Default(0)；额外电源请求均已清除，USB 功耗策略继续启用 |

原生电源查询使用 [CallNtPowerInformation](https://learn.microsoft.com/en-us/windows/win32/api/powerbase/nf-powerbase-callntpowerinformation) 的只读级别，未设置电源请求或改变电源方案。事件查询的权限／支持错误原样保留。微软文档也区分 [电源请求的作用和终止条件](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-powersetrequest)；请求被接受不等于本机全息视频已经恢复。

## 新增工具与视频对照

`apps/holographic-control/ops/Get-DevicePowerState.ps1 -RunId <唯一编号>` 在原身份上运行受限只读探针。同一 RunId 只回读原始报告，已实测 PID 和设备运行时计数保持原值，不会重新启动诊断。事件接口不可用或拒绝时记录原因，不自动提权或修改权限。

`apps/pc-control/ops/Measure-VideoSource.ps1` 和 `apps/holographic-control/ops/Get-PortalLiveSample.ps1` 新增 **Low** 诊断档，日常桌面默认仍为中清。低清本轮同样只收到 40 字节，解析失败后测量结果明确为 `measurement_incomplete`，帧率和码率均为空，未计为有效对照。

只读取得的全局 MRC 设置为 Profile 0、视频 30 fps、稳定缓冲 15 帧，并返回可用采集尺寸。这些是录制／采集默认设置，不能直接当作实时流实际参数。官方 [流接口说明](https://learn.microsoft.com/en-us/windows/mixed-reality/develop/advanced-concepts/device-portal-api-reference#mixed-reality-streaming) 将实时预览参数单独列出；没有据此改动全局 MRC、相机或音频设置，也未宣称找到约 21 fps 的根因。

发现回归及 46 项相机／交互检查通过；ARM64 原生诊断已在原设备执行，重复 RunId 回读和无效视频拒绝计数有独立证据。真实物理重接唤醒、持续未佩戴保活、新版三种 DPI 真机点按、25 fps、1–2 Mbps 与长期运行仍待完成。

本机证据目录为 `reports/phase2-full-control/t07-power-diagnosis-20261029/`，包含源码和原始回执快照、连接中断时间线、请求释放、同名保护恢复及证据哈希。此前 0.3.1 的 CPU 成绩与 0.3.2 的本机 DPI 结果保留原归属。
