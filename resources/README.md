# 资料库

收集能够帮助产品设计、采样与实验判断的资料。每条材料说明来源、用途和使用限制，阅读结论与原文链接一起保留。

## 基础文档

电脑连接相关依赖、官方获取入口和复用脚本见 [第一阶段资源清单](../docs/milestones/phase-1-usb-terminal/resources.md)。实时画面、鼠标控制及微软 3.0.24.0 官方控制软件另见 [第二阶段资源](../docs/milestones/phase-2-ricefield-control/resources.md)。

| 编号 | 资料 | 用途 |
| --- | --- | --- |
| REF-001 | [Windows Device Portal](https://learn.microsoft.com/en-us/windows/mixed-reality/develop/advanced-concepts/using-the-windows-device-portal) | 开发设备连接与调试；用于实验工具，不作为产品部署中的通用远程服务 |
| REF-002 | [Perception Simulation](https://learn.microsoft.com/en-us/windows/mixed-reality/develop/advanced-concepts/perception-simulation-overview) | 理解可重复的模拟头部、手部与输入测试 |
| REF-003 | [Manual camera controls](https://learn.microsoft.com/en-us/windows/apps/develop/camera/capture-device-controls-for-photo-and-video-capture) | 相机能力检查、曝光与对焦接口 |
| REF-004 | [Locatable camera overview](https://learn.microsoft.com/en-us/windows/mixed-reality/develop/advanced-concepts/locatable-camera-overview) | HoloLens 相机模式与采集约束 |
| REF-005 | [App views](https://learn.microsoft.com/en-us/windows/mixed-reality/design/app-views) | 区分二维窗口与沉浸视图的显示规则 |

这些条目是官方技术资料，具体硬件能力与应用效果仍以项目实验验证。

## 待补充主题

| 方向 | 收集时需要关注 |
| --- | --- |
| 水稻叶片数据集 | 类别定义、标注、拍摄条件、许可、数据划分 |
| 叶片分割与取景 | 方法、失败情形、端侧计算与实际像素细节 |
| 光照与图像质量 | 评价指标、测量方法和真实采集对照 |
| 识别评估 | 拒识、混淆、跨来源表现及样本偏差 |
| 设备稳定性 | 电源状态、启动、网络与恢复机制 |

通过“资料收集”Issue 提交，或复制 [条目模板](templates/resource.md) 编写阅读笔记。材料可标为“待阅读”“已阅读”“待实验”“已用于设计”，用于归纳材料的适用范围与后续验证。
