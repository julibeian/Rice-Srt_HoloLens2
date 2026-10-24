# 稻视界眼镜应用

`field-app` 是当前 HoloLens 独立应用，版本 **1.0.0.22 · 实验预览**。使用应用内原始 PV 预览完成目标选择、相机控制、高清采集、质量检查与裁剪，直接向识别网关上传并核对返回结果。

## 使用

点击预览移动取景框，用“范围”切换大小；点击“拍照”后等待画面稳定，应用保存原图和裁剪图，上传并显示结果。“查看原图”核对采集范围，“继续拍照”返回预览，失败上传可恢复。定位失败不阻止识别，历史照片重传保留原采集信息。

## 构建与测试

在仓库根目录执行：

```powershell
npm --prefix field-app ci
node field-app/build.mjs
node --test field-app/tests/*.test.cjs
python -B -m unittest discover -s field-app/tests -p test_server.py
```

共用界面输入见 [upstream-miniprogram](upstream-miniprogram/README.md)。Windows 打包、SDK 与设备配置见 [开发指南](../docs/development.md) 和 [设备调试](../docs/device-debugging.md)。

## 代码

| 路径 | 职责 |
| --- | --- |
| `src/native.js` | WinRT 相机、存储、位置、上传与恢复 |
| `src/camera-controls.js` | 相机能力、区域控制与曝光反馈 |
| `src/capture-quality.js` | 图像质量、稳定性与裁剪坐标 |
| `src/app.js`、`bridge.js` | 应用流程与业务接口 |
| `ops/`、`device/` | 构建、部署、运行诊断与证据导出 |
| `server/` | 识别网关及现有上游接口适配 |

网关使用 `/register`、`/session`、`/predict` 管理设备会话与图像请求。首次配置由部署工具完成，之后复用设备身份。上传请求与 `capture_evidence` 使用同一请求编号和图像 SHA256。

相机与上传测试使用明确的接口替身。真机验证范围及未完成实验见 [版本验证摘要](../experiments/results/pipeline-v1.0.0.22.md)，不将 API 接受或旧版本日志当作当前运行证据。
