# 原生采集与平台接口工具

本目录包含 ARM64/x64 的 WinRT 相机、网络检查、URI 激活和传输辅助工具。当前应用复用部分源码，构建脚本位于当前目录和 `apps/field-app/ops/`。

`hl-network-probe.c` 只读检查适配器并向项目固定健康接口发起一次有界 HTTPS GET，保留 TLS 校验。`hl-wifi-connect.c` 使用既有网络配置。`hl-uri-launch.c` 限制允许的 URI 与本项目应用身份，支持 `--inspect` 和不覆盖的独立输出文件。

相机与传输工具保留请求身份、实际照片摘要与响应关联。检查/构建成功只说明对应接口行为，实际运行、可见界面、成像和识别效果通过真机实验分别验证。

工具输出与 SDK 反射结果属于实验执行环境，不作为团队版本流水。使用方法与验证边界见 [设备调试](../../../docs/device-debugging.md) 和 [实验中心](../../../experiments/README.md)。
