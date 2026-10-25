# 开发指南

## 前端与离线测试

准备 Node.js、Python 和 PowerShell 7。在仓库根目录执行：

```powershell
npm --prefix field-app ci
node field-app/build.mjs
node --test field-app/tests/*.test.cjs
python -B -m unittest discover -s field-app/tests -p test_server.py
python tools/Verify-Product.py
```

构建默认读取仓库内 `field-app/upstream-miniprogram/`，不需要相邻工程。若需显式使用其他共用界面源码，设置 `RICE_MINIPROGRAM_ROOT`，并在 PR 中说明来源和输入差异。

## 设备管理工具的离线检查

配置模板不含真实设备身份。新环境先复制模板；已有 `config.json` 时保留原配置：

```powershell
if (-not (Test-Path config.json)) { Copy-Item config.example.json config.json }
pwsh -NoProfile -File tests/HoloLens.Discovery.Tests.ps1
pwsh -NoProfile -File tests/HoloLens.Connection.Tests.ps1
pwsh -NoProfile -File tests/HoloLens.StatusFile.Tests.ps1
pwsh -NoProfile -File tests/Field.Network.Tests.ps1
pwsh -NoProfile -File holographic-control/tests/TlsPin.Tests.ps1
pwsh -NoProfile -File holographic-control/tests/PortalPairing.Tests.ps1
```

以上检查使用离线替身、本机文件锁和临时测试证书，不进行设备操作。`tests/HoloLens.DiscoveryProcess.Tests.ps1` 另行检查 SDK 发现子进程的限时清理，会启动一次发现，但不配对或写设备。新电脑先按 [第一阶段通用手册](milestones/phase-1-usb-terminal/manual.md) 配置并运行 `tools/connection/Test-Workstation.ps1`。

## Windows 打包与原生工具

电脑端真机控制归入 [第二阶段](milestones/phase-2-ricefield-control/README.md)。其 [资源清单](milestones/phase-2-ricefield-control/resources.md) 区分 legacy x86 编码器、ARM64 恢复保护及微软 3.0.24.0 官方对照包。恢复保护构建器通过本机 `vswhere` 定位 MSVC，并从配置的 SDK 定位 ARM64 库；可显式指定工具路径。

现有构建脚本使用 Windows SDK **10.0.26100.0** 的 MakeAppx、ARM64 库和 WinRT 头文件，以及 .NET Framework C# 编译器。原生辅助工具使用 Zig **0.15.2**：

```powershell
python -m pip install --target .tools/zig-pypi ziglang==0.15.2
pwsh -NoProfile -File field-app/ops/Build-App.ps1 -Version 1.0.0.22
```

打包后单独核对新包的版本、文件摘要与 SHA256。部署、启动与真机运行结果分别验收，重新构建的包不能直接套用已发布附件的哈希。

## 原型测试

```powershell
node --test capture-app/web/tests/core.test.mjs capture-app/uwp/core.test.cjs
python -B -m unittest discover -s capture-app/server -p 'test_*.py'
```

可选浏览器检查从原型目录安装依赖，使用标准 Playwright 包：

```powershell
npm --prefix capture-app ci
npm --prefix capture-app exec -- playwright install chromium
npm --prefix capture-app run test:browser
```

默认使用 Playwright 安装的 Chromium；需要使用已有浏览器时，可通过 `PLAYWRIGHT_BROWSER_EXECUTABLE` 指定可执行文件。

浏览器与相机替身测试用于验证程序行为，真机成像和交互由实验协议单独验证。

## 发布检查

运行相关测试和 `python tools/Verify-Product.py`，更新版本说明与 `releases/<版本>/manifest.json`。提交前运行 `python tools/Check-Repository.py` 检查暂存内容，再上传包与 SHA256 清单。运行时、SDK 安装介质和凭据由各环境安装或配置，不加入 Git。
