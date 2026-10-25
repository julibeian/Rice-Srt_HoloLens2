# 稻视界眼镜控制（Windows）

版本：0.1.0，源码预览。属于 **第二阶段：真机稻视界眼镜控制**，阶段状态仍为进行中。

在电脑上观看已配对 HoloLens 的真实全息画面，并通过鼠标定位和点按、方向键或右键拖动调整视角。

新电脑先完成 [第一阶段 USB 管理连接](../docs/milestones/phase-1-usb-terminal/manual.md)，再按 [第二阶段通用手册](../docs/milestones/phase-2-ricefield-control/manual.md) 配置门户、SDK、应用和恢复保护。微软 **3.0.24.0** 官方控制软件的获取及对照测试见 [独立测试计划](../docs/milestones/phase-2-ricefield-control/official-3.0.24.0-test.md)。本工具的后端验证不等于官方 GUI 或完整桌面窗口流程已通过。

## 启动

在本机完成配置和构建后，双击桌面的 **稻视界眼镜控制**，或打开 `dist/RiceHoloLensControl.exe`。软件启动后核对配置的 USB 设备、SSH 身份、门户服务器密钥和当前 Windows 用户保存的凭据，随后显示画面。已有认证通过时，无需在窗口中重复输入密码或 PIN。

1. 等待实时画面更新，再点击 **开始控制**。软件打开稻视界并校准鼠标；校准期间不要点按其他控件。
2. 在视频里单击要操作的位置。软件会移动眼镜准星，从新的画面确认其位置，再发送一次点按。查看画面确认实际页面变化。
3. 右键拖动或点击方向按钮调整视角。调整后首次点按会重新校准；**靠近／退后**改变虚拟观看距离。
4. 点击 **开始菜单**发送 Home 手势；点击 **打开稻视界**返回本项目应用。
5. 点击 **停止控制 · 恢复眼镜**结束控制。关闭窗口也会关闭本次输入流并核对设备恢复结果。

控制显示剩余时间，单次最长 5 分钟；临近到期自动结束，可以再次点击“开始控制”。电脑进程意外退出时，设备端同名保护独立到期恢复正常模式。画面过期、准星未确认、设备身份或认证核对失败时，不发送点按。不要在不清楚前次结果时重复点击。

**保存画面**只将本次全息视频帧保存到本机运行目录，可通过 **运行记录** 打开。视频关闭独立 PV 和两路音频，但应用自身显示的相机预览仍会出现在全息画面内。

## 依赖与构建

它依赖完整项目中的 `config.json`、已配对的 USB 桥、专用 PowerShell 7、官方 legacy x86 SDK 控制器、FFmpeg、设备端恢复保护的构建工具和当前 Windows 用户保存的 DPAPI 门户凭据。其他电脑分别完成配置与构建，保留项目目录结构；不把现有 EXE、`runtime.json` 或加密凭据直接复制为独立安装包。

```powershell
runtime/powershell/pwsh.exe -NoProfile -File holographic-control/ops/Build-Control.ps1
runtime/powershell/pwsh.exe -NoProfile -File pc-control/Build.ps1 -DesktopShortcut
runtime/powershell/pwsh.exe -NoProfile -File pc-control/ops/Build-Tests.ps1
```

使用系统现有 .NET Framework C# 编译器构建 Windows Forms 程序，无需安装 Python 或 Node 依赖。构建时从当前 `ffmpeg` 命令解析视频解码器位置，保存在本机生成的 `dist/runtime.json`。界面、解码器和认证子进程之间使用私有管道，不建立网页服务器或开放监听端口。密码、CSRF cookie/token 不进入命令行或桌面程序日志。

`desktop/DeviceSession.cs` 管理身份核对、视频、输入、准星确认与设备恢复；`desktop/PointerGeometry.cs` 处理视频缩放和鼠标坐标；`desktop/MainForm.cs` 为界面。`tests/DeviceSmoke.cs` 是同一后端的显式真机测试入口，与桌面窗口使用同一互斥锁，避免两个本工具会话同时控制设备。

运行记录位于 `.state/sessions/<时间-编号>/`，均保留本机。同一后端已真机验证真实视频、范围切换、功能菜单、历史记录打开、原图切换、开始菜单、断流拒绝输入和停止恢复。图形窗口完成了原生离线渲染检查；Windows 自动化工具未能激活窗口，完整窗口点击流程尚未自动验收。复杂系统窗口、文本输入、拖拽物体、持续拖动和任意应用的全部控件也尚未完成验收。真实叶片和复杂光照验收仍独立保留。
