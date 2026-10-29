# 通用输入路线决定

2026-10-27，T05。主产品继续使用官方 legacy SDK 编码、经固定证书与认证门户发送的自制适配器。微软 3.0.24.0 原版 GUI 保留为独立对照客户端。

当前支持决定的实测包括：独立输入应用的 B 选择产生一次可信原生点击并显示 B=1；Home 打开系统 Start；从 Start 选择设置，继续选择“系统”，真实画面进入“声音”页。各输入都有新画面和单次请求记录，结束时自身流关闭、同名保护恢复 Default(0)。这些结果说明本路线具有跨系统与独立应用的最小操作能力，尚未证明四类场景各 30 次正确率、持续手势、中文或三维对象操作。

定位不能只依赖附近控件的悬停高亮。较早一次 Start 的 Settings 点按没有页面切换；后一次把小型手部射线光标移入目标内部，才打开设置。不同界面平面必须重新定位，较大的手部圆环不能直接当作目标命中。短 MRC 采样紧邻重连时还观察到 HTTP 200、仅 84 字节容器头；记录器将其拒绝，读取间隔与限次重读不重放输入。

官方 GUI 历史上已有真实视频与清理恢复记录，但可见选择仍未通过。本轮精确选择已核对的官方窗口后，电脑操作工具依次返回 `coordinate input geometry is unavailable` 和恢复时的 `failed to activate captured window`；转发器收到零个请求。因此这轮不作为官方输入成功或官方协议失败的证明，也不将电脑焦点错误认定为官方输入问题的唯一根因。临时转发停止，设备保护恢复。

后续将 SDK 路线接入通用应用身份模型、视频状态与坐标校准，再扩展按住释放、文字及三维操作。官方问题在独立对照中继续调查，不把它变成主产品必须经过的启动窗口。现有 300 秒保护继续有效；没有经过验证的续期前保持限时会话。用户要求的眼镜播放静音和 0% 音量必须保留。

本机原始证据：`reports/phase2-full-control/t05-sdk-probe-20261027-c/`、`t05-sdk-shell-20261027-d/`、`t05-official-settings-20261027-e/`；历史官方交付为 `reports/20261027-official-focus/官方GUI连接交付/`。原始画面不随公开源码发布。

路线依据：[微软 Perception Simulation](https://learn.microsoft.com/en-us/windows/mixed-reality/develop/advanced-concepts/perception-simulation-overview)、[HoloLens 门户模拟与显示接口](https://learn.microsoft.com/en-us/windows/mixed-reality/develop/advanced-concepts/device-portal-api-reference)。实际支持范围以上述实测为准。
