# 设备调试指南

适用于项目已配置开发通道的 HoloLens 2。设备管理信息保存在忽略的 `config.json` 和 `.state/` 中，每个执行环境分别维护。

## 配置

首次使用从 `config.example.json` 复制配置，填入设备名称、SDK 安装路径和经核实的 SSH 主机指纹。发现 GUID 与 USB 地址只作为发现提示；实际连接继续核对原主机身份。已有配置及配对关系直接复用，不为常规重连替换指纹。

```powershell
pwsh -NoProfile -File Connect-HoloLens.ps1 -Command status
pwsh -NoProfile -File Start-HoloLensBridge.ps1 -InstallAutostart
```

后台桥与监督进程负责恢复连接；命令失败或超时不自动重放。终端支持目录查询、文件传输和运行设备端已有程序，不提供通用的远程 PowerShell shell。

## 应用与运行诊断

```powershell
pwsh -NoProfile -File field-app/ops/Get-AppState.ps1
pwsh -NoProfile -File field-app/ops/Install-App.ps1
pwsh -NoProfile -File field-app/ops/Start-App.ps1
```

应用身份为 `Rice.HoloLens.Field_r5420n6798s24!Field`。部署工具仅处理本应用；安装版本、实际运行版本、相机预览和上传结果分别读取证据。无法枚举进程或包身份时保留错误，不将空列表当作已退出。

## 全息实验控制

操作入口见 [控制工具说明](../holographic-control/README.md)。门户凭据在执行环境加密保存，认证有效时复用。建立具名的 300 秒设备端恢复租约后才进行 PC 输入，操作结合当前画面，结束时关闭自身流并确认 Default(0)。同一操作编号的超时继续读取原结果，避免重复拍摄或输入。

原始诊断、照片、全息视频和设备账户材料保存在受控实验资料位置。提交问题时提供脱敏的错误码、版本、现象与必要摘要。
