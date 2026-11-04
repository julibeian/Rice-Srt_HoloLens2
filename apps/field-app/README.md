# 稻视界眼镜内动态检测

当前实现为 **1.0.0.48、ARM64、包内 YOLOv8n 六类目标检测**。HoloLens 连续读取原始 PV 新帧，在眼镜内完成预处理、WinML GPU 推理、分类别 NMS 和检测框显示。相机预览独立持续运行；停止识别后释放模型与工作线程，预览保留。

应用只申请相机权限，页面设置 `connect-src 'none'`，启动不需要识别服务或 Wi-Fi 预检。旧 ConvNeXt 十类动态分类、CAM、图像上传和 USB 识别中继回退均不属于当前应用。云端旧动态挂载已撤除；不恢复用户已否决的静态拍照加识别反馈路线。

## 使用与限制

打开应用后自动开始连续检测；“停止识别”释放模型，“开始识别”重新加载。未检出目标不代表健康。结果超过 5 秒会清除旧框，不把上一帧结果永久留在预览上。

固定类别顺序：稻纵卷叶螟、稻水象甲、稻叶蝉、白叶枯病、胡麻斑病、稻瘟病。默认输入 320×320、RGB NCHW `/255`、letterbox 填充 114，置信度阈值 0.4，分类别 NMS IoU 0.45。模型输出为 `[1,10,2100]`。

原下载模型为 640×640、opset19/IR9。适配保留训练权重，改为 opset12/IR7，并为 320 输入重建检测网格与形状常量。算子转换与同尺寸参考图的数值一致，不代表 320 与原 640 的预测完全相同。没有量化或重新训练。

眼镜实测推理约 0.6 秒/帧，属于持续检测，尚未达到视频逐帧检测速度。现有样本存在稻瘟病误判为胡麻斑病、胡麻斑病在默认阈值下漏检的问题。真实叶片、多光照和准确率仍未验收。内置图像只供诊断同一本地引擎及框显示，不能代替实物效果。

## 构建、部署与核验

在仓库根目录依次执行；模型转换使用本机 Python3.9 的 ONNX Runtime，以及 `.state/model-analysis-20261101/deps` 中的 ONNX1.17。构建依赖现有 Windows SDK、MSVC 链接器、Zig 和 Node.js；四张诊断图默认从旁边的 `srt-rice/手机端可跑版/samples` 读取，可通过 `RICE_YOLO_SAMPLES` 指定目录。

```powershell
py -3.9 -B apps/field-app/ops/Adapt-YoloModel.py --size 320 --output apps/field-app/.state/yolo-320/model.onnx
runtime/powershell/pwsh.exe -NoProfile -File apps/field-app/ops/Test-YoloCore.ps1 -InputSize 320
runtime/powershell/pwsh.exe -NoProfile -File apps/field-app/ops/Build-App.ps1 -Version 1.0.0.48 -InputSize 320
runtime/powershell/pwsh.exe -NoProfile -File apps/field-app/ops/Install-App.ps1 -Launch
```

待至少 30 个真实新帧完成后，以新 RunId 核对原设备、实际进程、模型、包文件回读哈希、权限和诊断入口关闭状态：

```powershell
runtime/powershell/pwsh.exe -NoProfile -File apps/field-app/ops/Verify-YoloDeployment.ps1 -RunId yolo-production-check
```

同一 RunId 只取回原证据；需新观察时使用新名称。安装、启动接受或 `networkRequests=0` 字段本身不能替代实际推理和网络独立性证据。核验脚本不会断开整台设备网络。

测试：

```powershell
node --test apps/field-app/tests/*.test.cjs
python -B -m unittest discover -s apps/field-app/tests -p 'test_*.py'
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
| `server/retire_dynamic.py` | 有备份及回滚的旧动态云端挂载撤除 |

[执行步骤](../../docs/plans/20261101-yolo-on-device/执行入口.md)、[部署报告](../../reports/20261101-yolo-on-device/部署报告.md)保存当前证据与限制。旧版本及已被否决的产品流程仅作历史记录。根目录 `README.md` 继续由用户维护。
