# 阶段成果

整理日期：2026-10-25。这里记录电脑连接与真机控制的工程进展，供其他电脑和设备的维护者复现。使用者填写自己的设备身份、SDK 路径和凭据；仓库不包含原开发电脑的配置或配对材料。

## 第一阶段：电脑通过 USB 管理眼镜

状态：**已有阶段性真机结果，提供通用部署手册**。目标是让 Windows 电脑通过 USB NCM 和已经配对的 Windows SDK SSH 通道执行受限管理操作，并在同一设备重新可达时恢复连接。已验证端点缓存把常规重连缩短到约 1 秒；首次连接和缓存失效时仍走完整发现。

| 交付 | 入口 |
| --- | --- |
| 新电脑从零配置、首次配对、日常操作与故障排查 | [通用操作手册](phase-1-usb-terminal/manual.md) |
| 依赖获取、配置模板与辅助脚本 | [资源清单](phase-1-usb-terminal/resources.md) |
| 关键问题、修复及路线变化 | [重要迭代历史](phase-1-usb-terminal/history.md) |
| 已验证范围与新环境验收记录模板 | [验证说明](phase-1-usb-terminal/validation.md) |
| 固定阶段源码 | [codex/pc-hololens-connection](https://github.com/julibeian/hololens-terminal/tree/codex/pc-hololens-connection) |

本阶段不包含实时画面、鼠标输入或识别效果结论。已有结果来自一个开发环境与一台 HoloLens 2；通用文档和离线检查不等于已经完成第二台电脑的真机复现。

## 第二阶段：HoloLens 整机操作与管理

状态：**进行中**。范围扩展为系统与多应用可视化操作、键盘文字、持续手势、三维交互、设备维护及异常恢复。见 [整机实施与能力登记](phase-2-hololens-control/README.md) 和 [执行入口](../plans/20261027-phase2-hololens-control/执行入口.md)。M0 基线已建立，通用输入仍待跨应用验证。

第二阶段有独立的 [资料目录](phase-2-ricefield-control/README.md)、[操作手册](phase-2-ricefield-control/manual.md)、[官方 3.0.24.0 对照测试计划](phase-2-ricefield-control/official-3.0.24.0-test.md) 和 [源码分支](https://github.com/julibeian/hololens-terminal/tree/codex/ricefield-device-control)。自制软件后端的真机记录、桌面窗口检查与官方 GUI 的测试分别记载，不以第一阶段连通代替控制验收。

应用采集与识别另按 [v1.0.0.22 实验摘要](../../experiments/results/pipeline-v1.0.0.22.md) 管理。真实叶片、复杂光照与长期稳定性继续保留待验证状态。
