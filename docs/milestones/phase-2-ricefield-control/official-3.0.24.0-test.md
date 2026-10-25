# 微软 Perception Simulation 3.0.24.0 官方软件对照测试

阶段：二，真机稻视界眼镜控制。状态：**官方软件包静态核查可执行；官方 GUI 真机功能测试待完成**。此项不归入第一阶段 USB 管理连接的完成项。

测试目标是比较微软官方 GUI 与本项目桌面工具在同一设备、应用版本和控件上的实际行为，判断哪些能力可以直接复用官方工具，哪些仍需要本项目整合。官方文档的能力说明、自制后端的成功和安装成功分别保留证据。

## 1. 先检查软件包，暂不操作设备

```powershell
& .\pc-control\official\Get-OfficialControl.ps1
```

记录产品版本、微软签名、MSI SHA256、组件表与依赖。参考包为 **3.0.24.0**，SHA256 见 [资源清单](resources.md)。检查脚本不会安装软件、启用驱动或连接眼镜。已有缓存会重新核对签名和哈希；`-Refresh` 才重新下载。缓存通过不写成已经重新验证在线文件哈希。

确认包内容和测试机条件后，由设备维护者在本机管理员 PowerShell 7 中选择安装：

```powershell
& .\pc-control\official\Install-OfficialControl.ps1
```

安装脚本默认仅选择 App、ManagedApi、NativeApi、Recordings，未请求驱动或服务。保存安装前基线、MSI 日志、退出码与实际程序哈希；退出码 3010 表示请求重启，不能直接记作安装后运行完成。本次资料更新没有执行安装或重启。

官方程序通常位于 `%ProgramFiles%/Microsoft Perception Simulation/Control/PerceptionSimulationControl.exe`。[微软说明](https://learn.microsoft.com/en-us/windows/mixed-reality/develop/advanced-concepts/perception-simulation-standalone) 要求 Windows 10 2004 或更新，并将已有 HoloLens 2 目标选为 `HoloLens 2 (Legacy)`。完整 Hyper-V 模拟器的要求不能直接套到这个独立 GUI。

## 2. 真机测试前准备

1. 记录电脑、眼镜系统、应用版本、源码提交和包哈希。第一阶段应先执行实际只读命令，确认原 SSH 身份；门户再核对原公钥与认证。
2. 两个工具依次运行。先结束前一个工具的自身控制流，并取得同名恢复结果 `Default(0)`；不抢占已有非默认模式。
3. 统一选择稻视界的“范围”切换作为首个可见控件，随后验证菜单、历史结果和 Home。拍照与上传有独立副作用，不作为默认对照动作；若测试它们，另建实验编号。
4. 官方 GUI 中手工填写本次发现的 USB 地址，使用该设备有效的门户账户。不要把密码放进进程参数、日志或截图。
5. 若门户凭据由脚本随机生成，仅当前 Windows 用户持有 DPAPI 文件，需先完成官方认证界面的受控凭据输入方案；该步骤尚未验收。不要为了方便而重设原门户账户，不输出明文密码来补齐测试记录。已知账号的新环境可在官方认证窗口直接输入，并用同一账号供本项目安全提示保存。

## 3. 以独立保护包住官方 GUI 会话

下面先启用具名设备端 300 秒保护，再由维护者在官方窗口完成有限测试。保护到期后本轮结束，不能继续沿用过期会话输入。官方 GUI 需选择刚核对的设备，关闭它后再读取恢复结果。

```powershell
$officialRun = 'official-' + [guid]::NewGuid().ToString('N')
$officialControl = Join-Path $env:ProgramFiles 'Microsoft Perception Simulation/Control/PerceptionSimulationControl.exe'
& .\holographic-control\ops\Control-Lease.ps1 -Mode Start -RunId $officialRun
try {
    if (-not (Test-Path -LiteralPath $officialControl)) { throw '官方程序未安装。' }
    Start-Process -FilePath $officialControl -PassThru -Wait | Out-Null
} finally {
    & .\holographic-control\ops\Control-Lease.ps1 -Mode Stop -RunId $officialRun
    & .\holographic-control\ops\Control-Lease.ps1 -Mode Status -RunId $officialRun
}
```

官方 GUI 是否与预先建立的本项目保护兼容，也是待验证项。若拒绝已有模式，记录原错误并结束此轮，不移除保护后硬测。关闭、断开和恢复结果未知时查询原 RunId，不重复点按、不换编号重启。

官方软件未宣称具备本项目的 2.5 秒旧帧拒绝或准星确认机制，这两项不能直接套用。受控中断测试采用观察和恢复核对，不在冻结画面上点击可能有副作用的控件。

## 4. 逐项对照表

下列“已有”均指原开发环境的历史记录，不是本次新增的官方 GUI 结果。完整 Windows 窗口流程与共用后端调用分别填写。

| 项目 | 微软 3.0.24.0 官方 GUI | 本项目工具已有记录 | 本轮应保存的证据 |
| --- | --- | --- | --- |
| 启动与原设备认证 | 待验收 | 后端已有 | 版本、目标身份核对、认证状态；隐去密码 |
| 可解码的真实全息画面 | 待验收 | 后端已有 | 新帧与可读稻视界界面；排除 PV 独立流和 PC 离线预览 |
| “范围”控件单次点按 | 待验收 | 后端已有 | 点按前后文字与取景框变化 |
| 功能菜单、历史结果、原图切换 | 待验收 | 后端已有 | 各控件的前后对应画面，不重传旧照片 |
| Home 与返回稻视界 | 待验收 | 后端已有 | Start 菜单、新的实际应用会话与画面 |
| 完整 PC 图形窗口流程 | 待验收 | 待验收，已有离线渲染 | 在运行中的 Windows 窗口实际完成上述动作 |
| 受控视频中断 | 待验收 | 自制后端已拒绝旧帧点按 | 流状态与输入是否被阻止；官方工具按实际行为记录 |
| 主动关闭与 Default(0) 恢复 | 待验收 | 后端与具名保护已有 | 自身流关闭结果、同名租约结果、门户读回模式 |
| 电脑侧进程意外结束后恢复 | 待验收 | 设备端到期保护机制已有，完整故障组合待验收 | 超时预算、保护报告及设备模式，不杀无关进程 |
| 第二台电脑同样流程 | 待验收 | 待验收 | 独立环境信息与逐项结果 |

## 5. 结果记录模板与通过条件

```text
测试编号：自行填写
日期与时区：自行填写
工具名称和版本：官方 3.0.24.0 / 本项目 0.1.0
MSI、EXE 和源码摘要：自行填写
电脑系统、眼镜系统、应用实际版本：自行填写
可信身份及门户认证：未验收
具名保护 RunId 与启动结果：自行填写
画面/范围/菜单/历史/原图/Home：逐项未验收
真实 Windows 窗口流程：未验收
中断与旧画面时的行为：未验收
关闭自身流结果：未验收
同名保护恢复与门户 Default(0)：未验收
耗时、异常、重试与未知结果：自行填写
本机证据目录和脱敏文件摘要：自行填写
与另一工具的差异及后续取舍：自行填写
```

一项控件只在“当前新画面 → 单次输入 → 对应新画面变化”闭合后通过。一次结果不扩展到所有应用；所有选定功能、停止恢复和两种工具的对照结果齐备后，再评估本阶段完成。真实叶片、复杂光照和识别准确率继续独立验收。
