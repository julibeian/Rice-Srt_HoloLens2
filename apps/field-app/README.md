# 稻视界眼镜内动态检测

最后核验的正式版为 **1.0.0.63、ARM64、包内 YOLOv8n 六类目标检测**。HoloLens 连续读取原始 PV 新帧，在眼镜内完成预处理、WinML GPU 推理、分类别 NMS 和检测框显示。相机预览独立持续运行；停止识别后释放模型与工作线程，预览保留。

应用只申请相机权限，页面设置 `connect-src 'none'`，启动不需要识别服务或 Wi-Fi 预检。旧 ConvNeXt 十类动态分类、CAM、图像上传和 USB 识别中继回退均不属于当前应用。云端旧动态挂载已撤除；不恢复用户已否决的静态拍照加识别反馈路线。

## 使用与限制

打开应用后自动开始连续检测；“停止识别”释放模型，“开始识别”重新加载。未检出目标不代表健康。结果超过 5 秒会清除旧框，不把上一帧结果永久留在预览上。

固定类别顺序：稻纵卷叶螟、稻水象甲、稻叶蝉、白叶枯病、胡麻斑病、稻瘟病。默认输入 320×320、RGB NCHW `/255`、letterbox 填充 114，置信度阈值 0.4，分类别 NMS IoU 0.45。模型输出为 `[1,10,2100]`。

原下载模型为 640×640、opset19/IR9。第一版适配保留 FP32 训练参数，改为 opset12/IR7，并为 320 输入重建检测网格与形状常量；原 FP32 文件继续保留。1.0.0.63 将同一模型内部表示转为 FP16，输入和输出接口仍为 FP32，没有重新训练或更换模型的训练来源。FP16 舍入会改变浮点参数字节和部分预测数值，不是逐位等价转换。与桌面参考的对照在 `bacterial_blight_0.jpg` 上有一项超过 0.01 置信度门槛，因此只以同眼镜 FP32/FP16 对照为准：四张内置诊断图类别与框数一致，最大置信度差 0.007，最大框坐标差 0.249 px，详见[本轮报告](../../reports/20261106-winml-cause/定因与改善报告.md)；这些检查不能替代真实病害准确率。

2026-11-06 在正常模式、同一相机配置下做了四轮交替对照：按已观测结果的帧号去重，原版等价内容 2221 ms，FP16、张量复用和减少不变框层重绘后的内容 1781 ms，耗时约降低 19.8%；完成检测由 0.441 提升到 0.525 次/秒，约提高 19.1%。两臂 GPU 总引擎占用接近不证明本应用份额相同。相同内容在不同时段分别约 1.16 秒和约 2.2 秒，具体漂移来源仍未定因，不能跨时段相减或全面排除底层策略。仍未达到视频逐帧检测速度。稻瘟病误判为胡麻斑病、胡麻斑病默认阈值下漏检的情况仍在，真实叶片、多光照和准确率未验收。

20:02、20:31 续查未发现原 USB 设备，最后一次正式部署证明停留在 16:45。用于分离预览渲染影响的 1.0.0.64 诊断候选已构建，尚未部署或进行在线验收；其中预览遮罩仅在诊断会话可用，120 秒自动恢复。生产配置不会读取该命令。重连后续测入口为[定因计划](../../docs/plans/20261106-winml-cause/执行入口.md)。

## 构建、部署与核验

在仓库根目录构建现有已验证模型。默认 320 构建读取 `.state/yolo-320-fp16/model-manifest.json`，原生组件默认复用输入/输出张量；指定 `NativePackageDirectory` 时继承该来源包的组件和模型，显式 `ModelDirectory` 可以覆盖模型。构建依赖现有 Windows SDK、MSVC 链接器、Zig 和 Node.js；四张诊断图默认从旁边的 `srt-rice/手机端可跑版/samples` 读取，可通过 `RICE_YOLO_SAMPLES` 指定目录。

```powershell
runtime/powershell/pwsh.exe -NoProfile -File apps/field-app/ops/Build-App.ps1 -Version 1.0.0.65 -InputSize 320  # 64 留给诊断候选；版本须高于设备已安装版本
runtime/powershell/pwsh.exe -NoProfile -File apps/field-app/ops/Install-App.ps1 -Launch
```

需要重做 FP16 候选时，用 `Prepare-YoloFloat16.py --output <新的目录>/model.onnx`，再检查同目录的六组数值结果。该脚本用 Python 3.14 和 `.state/winml-experiment-deps`，拒绝覆盖旧候选。精度改变还须用同眼镜、相同解码输入的 FP32 对照核验；桌面 JPEG/WinML 数值差异不能直接当作精度转换差异。原始 opset/320 适配的历史复做入口保留在 11 月 1 日计划中。部署器在已知当前版本较高时会在停止应用、复制文件前拒绝降级；回切旧内容须用更高版本重新构建。

待至少 30 个真实新帧完成后，以新 RunId 核对原设备、实际进程、模型、包文件回读哈希、权限和诊断入口关闭状态：

```powershell
runtime/powershell/pwsh.exe -NoProfile -File apps/field-app/ops/Verify-YoloDeployment.ps1 -RunId yolo-production-check
```

同一 RunId 只取回原证据；需新观察时使用新名称。安装、启动接受或 `networkRequests=0` 字段本身不能替代实际推理和网络独立性证据。核验脚本不会断开整台设备网络。

测试：

```powershell
node --test apps/field-app/tests/*.test.cjs
py -3.14 -B -m unittest discover -s apps/field-app/tests -p 'test_resource_analysis.py'
runtime/powershell/pwsh.exe -NoProfile -File tests/HoloLens.Discovery.Tests.ps1
```

## 代码与证据

| 路径 | 职责 |
| --- | --- |
| `src/native.js` | 原始相机预览、新帧传递、本地组件身份与资源生命周期 |
| `src/app.js`、`dynamic.js` | 持续预览、开始/停止、框映射与过期清除 |
| `yolo-native/` | ARM64 WinRT 组件、WinML、预处理和 NMS |
| `ops/Adapt-YoloModel.py` | 版本语义转换、检测网格适配、权重与数值核验 |
| `ops/Build-App.ps1`、`Verify-YoloDeployment.ps1` | 包构建和真机文件/运行核验 |
| `ops/Prepare-YoloFloat16.py`、`Verify-YoloPrecisionResults.py` | 隔离精度候选及同设备数值检查 |
| `device/hl-gpu-probe.c`、`ops/Analyze-WinMLCause.py` | 驱动 GPU 时钟/执行时间与可逆模式对照分析 |
| `server/retire_dynamic.py` | 有备份及回滚的旧动态云端挂载撤除 |

[执行步骤](../../docs/plans/20261101-yolo-on-device/执行入口.md)、[部署报告](../../reports/20261101-yolo-on-device/部署报告.md)保存当前证据与限制。旧版本及已被否决的产品流程仅作历史记录。根目录 `README.md` 继续由用户维护。

## 真实相机资源采样

2026-11-05完成五个PV相机尺寸、15/30 fps各三轮的30轮整机CPU/GPU采样；2026-11-06补齐原包对照与12文件恢复核验。模型输入保持320、原权重与原生组件字节一致。逐轮结果、呈现计数与检测吞吐的口径、运行时长和供电条件差异见[采样报告](../../reports/20261105-yolo-camera-resources/采样报告.md)；复做和状态入口见[采样计划](../../docs/plans/20261105-yolo-camera-resources/执行入口.md)。原包1.0.0.48已恢复，资源采样开关不会随正常构建默认启用。
