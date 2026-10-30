# 设备调试指南

适用于项目已配置开发通道的 HoloLens 2。设备管理信息保存在忽略的 `config.json` 和 `.state/` 中，每个执行环境分别维护。

## 配置

新电脑、新 Windows 用户或另一台眼镜从 [第一阶段通用操作手册](milestones/phase-1-usb-terminal/manual.md) 开始，其中包含依赖获取、首次 SDK 配对、可信身份建档和恢复检查。实时画面与鼠标控制在 [第二阶段](milestones/README.md) 单独验收。

首次使用从 `config.example.json` 复制配置，填入设备名称、SDK 安装路径和经核实的 SSH 主机指纹。发现 GUID 与 USB 地址只作为发现提示；实际连接继续核对原主机身份。已有配置及配对关系直接复用，不为常规重连替换指纹。

```powershell
pwsh -NoProfile -File usb-terminal/Connect-HoloLens.ps1 -Command status
pwsh -NoProfile -File usb-terminal/Start-HoloLensBridge.ps1 -InstallAutostart
```

后台桥与监督进程负责恢复连接；命令失败或超时不自动重放。终端支持目录查询、文件传输和运行设备端已有程序，不提供通用的远程 PowerShell shell。

SDK 发现最长等待 12 秒，超时只结束本次创建的发现进程。重新连接复用已验证主机指纹的 SSH 会话；断开失败也会释放旧对象。SDK 未返回设备元数据时保留诊断，不能据此丢弃已通过身份验证的连接。

监督进程同时检查桥的进度时间。桥停止推进超过 120 秒（命令超时设置较长时相应延长）会替换该桥进程，再发现原设备；正在执行的命令结果记为未知，不自动重发。`status` 中的 `UpdatedAt`、`ActiveOperation` 和 `SourceHashes` 可核对当前进度与实际加载的源码。设备关机、深度休眠或链路本身不可用期间，桥仍须等待设备恢复，不能只凭后台进程存在宣称在线。

恢复检查需在重新连接后实际运行设备端只读命令，再检查门户认证。`reconnect` 返回表示请求已接受；等待 `connected` 后的命令成功才证明本轮通道可用。NJAU 的 Wi-Fi 关联、云端健康 HTTP 200 和电脑到眼镜的管理通道分别验收；不能用其中一项替代另外两项。

接电待机超时会影响无人值守调试。在门户修改前保存原电源方案；将接电时的待机、无人值守待机及显示超时设为所需值，保留电池供电时的原值，重新读取并在设备重启后复核。门户“Sleep settings”会同时设置待机和显示超时，接口及设备范围见 [Microsoft 设备门户说明](https://learn.microsoft.com/en-us/windows/mixed-reality/using-the-windows-device-portal)。本项目的单次重启验收使用运行时长归零和原 SSH 指纹核对证明恢复，不以重启接口 HTTP 200 作为完成依据。

## 应用与运行诊断

```powershell
pwsh -NoProfile -File apps/field-app/ops/Get-AppState.ps1
pwsh -NoProfile -File apps/field-app/ops/Install-App.ps1
pwsh -NoProfile -File apps/field-app/ops/Start-App.ps1
```

应用身份为 `Rice.HoloLens.Field_r5420n6798s24!Field`。部署工具仅处理本应用；安装版本、实际运行版本、相机预览和上传结果分别读取证据。无法枚举进程或包身份时保留错误，不将空列表当作已退出。

## 第二阶段：全息实验控制

新环境从 [第二阶段通用手册](milestones/phase-2-ricefield-control/manual.md) 开始，脚本入口见 [控制工具说明](../apps/holographic-control/README.md)。门户凭据在执行环境加密保存，认证有效时复用。建立具名的 300 秒设备端恢复租约后才进行 PC 输入，操作结合当前画面，结束时关闭自身流并确认 Default(0)。同一操作编号的超时继续读取原结果，避免重复拍摄或输入。微软 3.0.24.0 独立包的真机对照按 [官方测试计划](milestones/phase-2-ricefield-control/official-3.0.24.0-test.md) 单独记录。

原始诊断、照片、全息视频和设备账户材料保存在受控实验资料位置。提交问题时提供脱敏的错误码、版本、现象与必要摘要。
