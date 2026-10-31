# 稻视界眼镜应用

`apps/field-app` 是当前 HoloLens 独立应用，版本 **1.0.0.31 诊断/中继构建、1.0.0.32 直连生产构建 · 动态识图实验**。使用应用内原始 PV 预览完成目标选择、相机控制、高清采集、质量检查与裁剪，直接向识别网关上传并核对返回结果；新增动态模式按取景框连续取帧并叠加上云识别结果。

## 使用

点击预览移动取景框，用“范围”切换大小；点击“拍照”后等待画面稳定，应用保存原图和裁剪图，上传并显示结果。“查看原图”核对采集范围，“继续拍照”返回预览，失败上传可恢复。定位失败不阻止识别，历史照片重传保留原采集信息。

动态模式：点“动态识图”后应用每轮从取景框裁剪 384×384 JPEG，按端到端延迟自动节流上传到 `/hololens-app/api/dynamic/frame`；HUD 显示稳定类别、置信度、端到端延迟、推理耗时、模型版本和输入尺寸，画布叠加 CAM 关注区域。再点“停止动态”恢复静态拍照。云端默认 160 输入，可在 `config.json` 调整 `dynamicFrameSize`、`dynamicInputSize`、`dynamicJpegQuality`、`dynamicGapMs`（0 表示请求完成立即下一帧）。若直连健康探测失败且配置了链路本地 `relayOrigin`，应用自动改走 USB 中继；请求中途网络失败会切换到另一来源重试一次，不伪造结果。`relayOrigin` 只接受 `169.254.*`、`127.0.0.1` 或 `localhost`，中继不记录请求体或令牌。

## 构建与测试

在仓库根目录执行：

```powershell
npm --prefix apps/field-app ci
node apps/field-app/build.mjs
node --test apps/field-app/tests/*.test.cjs
python -B -m unittest discover -s apps/field-app/tests -p 'test_*.py'
```

生产构建（优先直连阿里云；`relayOrigin` 存在时直连健康探测失败自动改走 USB 中继）：

```powershell
runtime/powershell/pwsh.exe -NoProfile -File apps/field-app/ops/Build-App.ps1 -Version 1.0.0.36
```

USB 中继启动与停止（仅绑定 USB 主机地址，转发 `/hololens-app/api/*` 到生产 HTTPS）：

```powershell
runtime/powershell/pwsh.exe -NoProfile -File apps/field-app/ops/Start-UsbRelay.ps1
runtime/powershell/pwsh.exe -NoProfile -File apps/field-app/ops/Stop-UsbRelay.ps1
```

强制中继诊断构建（不使用自动回退，便于复现校园网络问题）：

```powershell
runtime/powershell/pwsh.exe -NoProfile -File apps/field-app/ops/Build-App.ps1 -Version 1.0.0.36 -CameraDiagnostics -ApiOrigin http://169.254.216.241:9021
```

诊断构建支持通过 `camera-check.json` 触发 `controls`、`capture`、`dynamic_start`、`dynamic_stop`、`dynamic_asset`；生产构建不启用该轮询。

共用界面输入见 [upstream-miniprogram](upstream-miniprogram/README.md)。Windows 打包、SDK 与设备配置见 [开发指南](../../docs/development.md) 和 [设备调试](../../docs/device-debugging.md)。动态阶段云端清单与实测见 [动态识图交付](../../reports/20261031-dynamic-recognition/README.md)。

## 代码

| 路径 | 职责 |
| --- | --- |
| `src/native.js` | WinRT 相机、存储、位置、上传、恢复与动态帧 |
| `src/camera-controls.js` | 相机能力、区域控制与曝光反馈 |
| `src/capture-quality.js` | 图像质量、稳定性与裁剪坐标 |
| `src/dynamic.js` | 动态节流、平滑、标注映射与循环（纯逻辑） |
| `src/app.js`、`bridge.js` | 应用流程与业务接口 |
| `ops/`、`device/` | 构建、部署、运行诊断与证据导出 |
| `server/` | 识别网关、动态模型模块、CAM 与 USB 中继 |

网关使用 `/register`、`/session`、`/predict` 管理设备会话与图像请求，动态模式使用 `/dynamic/frame`、`/dynamic/health`。首次配置由部署工具完成，之后复用设备身份。上传请求与 `capture_evidence` 使用同一请求编号和图像 SHA256；动态帧使用帧编号和图像 SHA256。

相机与上传测试使用明确的接口替身。真机验证范围及未完成实验见 [版本验证摘要](../../experiments/results/pipeline-v1.0.0.22.md)，不将 API 接受或旧版本日志当作当前运行证据。
