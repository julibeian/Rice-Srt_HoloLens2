# 稻视界 · HoloLens 实验平台

面向水稻图像采集与识别的实验产品。眼镜端负责取景、拍照、图像质量检查与结果展示，云端提供识别服务；项目组共同维护实验方案、样本规范、技术资料和版本交付。

当前版本：**v1.0.0.22 · 实验预览**。已在非叶片对照样本上验证采集、裁剪、上传与结果绑定；真实叶片、多光照及长期运行仍需补充实验。

## 从这里开始

| 目标 | 入口 |
| --- | --- |
| 了解产品能力与架构 | [产品说明](docs/product.md) · [系统架构](docs/architecture.md) |
| 安装开发环境、构建和测试 | [开发指南](docs/development.md) |
| 连接电脑与眼镜、查看阶段性成果 | [阶段成果总览](docs/milestones/README.md) |
| 组织采样与验证 | [实验中心](experiments/README.md) · [采集协议](experiments/protocols/leaf-capture.md) |
| 查找与补充资料 | [资料库](resources/README.md) |
| 提交问题、方案或实验结果 | [协作说明](CONTRIBUTING.md) · [新建 Issue](https://github.com/julibeian/hololens-terminal/issues/new/choose) |
| 下载实验预览包 | [版本发布](https://github.com/julibeian/hololens-terminal/releases/tag/v1.0.0.22) · [版本说明](CHANGELOG.md) |

## 五阶段路线

| 阶段 | 目标 | 当前状态 |
| --- | --- | --- |
| 一 | 电脑通过 USB 稳定连接眼镜 | 已完成：身份校验、远程程序执行、文件往返、断线重连、桥进程自恢复、受控重启 |
| 二 | 在电脑上稳定操作眼镜内画面 | 基本可用、验收进行中：实时画面、点按、跨应用启动、延迟优化与可用性看护；25 fps、完整 DPI、三维交互与长时稳定性仍在推进 |
| 三 | 静态识别模型嵌入眼镜 | 未开始 |
| 四 | 动态识别模型嵌入眼镜 | 未开始 |
| 五 | 前后端挂载 | 未开始 |

阶段一、二的已有成果与验收范围分别记录在 [阶段成果总览](docs/milestones/README.md)、[第一阶段手册](docs/milestones/phase-1-usb-terminal/manual.md) 和 [第二阶段能力登记](docs/milestones/phase-2-hololens-control/README.md)。稻视界是第二阶段的验证应用之一，其应用专用手册见 [稻视界控制](docs/milestones/phase-2-ricefield-control/manual.md)。

阶段状态、复现边界与后续工作见 [阶段成果总览](docs/milestones/README.md)。

## 产品流程

选择取景区域 → 对焦与曝光调整 → 高清拍照 → 质量检查与裁剪 → 云端识别 → 核对结果并保存历史。

原图与裁剪图保持关联，上传与返回结果使用请求编号和 SHA256 核对。质量不合格的图像会提示重新采集；非叶片拒识结果单独展示。定位失败不阻止识别，失败上传可以恢复。

## 当前验证范围

| 项目 | 状态 |
| --- | --- |
| 原始 PV 预览、目标区域控制、高清采集与裁剪 | 已有单场景真机验证 |
| 新拍图像、上传、返回结果与历史记录关联 | 已有非叶片对照验证 |
| 全息预览中的取景框与快门点按 | 已验证这两项操作 |
| 水稻叶片识别、不同光照下的细节与清晰度 | 待实验验证 |
| 网络波动、低功耗恢复、跨重启和长期运行 | 待稳定性验证 |

实验条件、结果和限制见 [v1.0.0.22 验证摘要](experiments/results/pipeline-v1.0.0.22.md)。

## 参与项目

资料按主题和用途收集，实验按编号与版本归档，代码通过 Pull Request 合并。先从 [路线图](docs/roadmap.md) 选择问题，再使用对应模板提交材料。资料与结论按版本、实验编号和样本批次维护。

主要代码位于 `field-app/`；`holographic-control/` 提供实验控制工具；`capture-app/` 保留可复用的采集原型。硬件与凭据由各自环境配置，参考 [设备调试指南](docs/device-debugging.md)。
