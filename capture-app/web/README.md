# 眼镜单张拍照客户端

部署只需要同目录的 `index.html`、`styles.css`、`app.bundle.js` 三个文件。页面不依赖外部 CDN、字体或 JavaScript 包。`capture-core.mjs` 与 `app.mjs` 是源文件；修改后执行 `node build-bundle.mjs` 生成经典脚本，供不支持 module 脚本的浏览器使用。

## 会话入口

优先使用 fragment 形式，示例中的值是占位符：

```text
https://rice-srt.cn/hololens/#token=SESSION_TOKEN&run=RUN_ID&autocapture=1
```

`token` 和 `run` 必须由实际会话服务提供。token 接受 16–256 位字母、数字、点、下划线、短横线或波浪线；run 接受 1–64 位字母、数字、点、下划线或短横线。也兼容查询参数；fragment 同名参数优先。页面立即从历史 URL 中去掉 token 和 autocapture，token 只保留在本次页面内存中，不写入浏览器存储。重新载入需要重新使用会话链接。在已打开标签页中打开新的 fragment 会话链接，会触发一次正常重新载入。

没有 `autocapture=1` 时由用户点击开启相机和拍摄。仅在显式设置该参数并通过服务端会话核验后，页面申请相机许可、等待画面约 1.8 秒后拍摄一次。会话失效、核验超时或 run 不匹配时不开启相机。成功取得 JPEG 后立即关闭相机，不循环拍摄，不读取历史媒体，不自动重试预测。

可选 `endpoint` 和 `events` 参数可覆盖预测和事件路径，但只接受本页面同源 URL；默认值也可通过 HTML 内相应 meta 标签修改。

## 服务契约

预测默认 `POST /hololens/api/predict`，请求为 multipart，照片字段 `file`，内容为新拍 JPEG。请求头为：

```text
X-HoloLens-Token: 当前会话 token
X-HoloLens-Run: 当前 run
X-Request-ID: 每张唯一请求编号
```

响应保留旧识别接口的 `predicted_class`、`confidence`、`is_valid`；也可兼容新版 `data.prediction`。服务端另外必须返回：

```json
{
  "capture_evidence": {
    "request_id": "与请求头完全相同",
    "image_sha256": "本次 JPEG 字节 SHA256",
    "received_at": "服务端时间",
    "prediction_id": "服务端识别编号"
  }
}
```

客户端核对请求编号和 JPEG 字节哈希后才显示结果。不在客户端重新按置信度阈值决定接受与否；接受与拒识以服务端布尔判定为准。拒识时大标题显示“无法确认”，不会把高分误当作有效结论。

事件默认 `POST /hololens/api/events`，同样附加会话 token 与 run 请求头。JSON 为 `{event, run_id, request_id, details}`。事件仅含匿名会话、阶段、请求编号、图像哈希、图片尺寸、耗时和必要的识别结果。token 不在 JSON 内，事件不含照片字节或设备身份。

`result_rendered` 在结果写入 DOM 并等待两个绘制帧后发送，details 包含 `image_sha256`、`accepted`、`class_name`、`confidence`、`prediction_id`。取消、超时、图片哈希不匹配、响应缺字段时均不发送这个完成事件。

## 运行与验证边界

需要可信 HTTPS 或 localhost 安全上下文、相机 API、真实 SHA256 能力，以及相机许可。没有相机 API 或 Web Crypto 时页面明确报错，不生成伪造哈希。内核缺少 AbortController 时采用请求代次防止迟到响应覆盖界面，但无法保证底层网络请求被即时撤销。尚未在 HoloLens 或旧 EdgeHTML 上验证。

本机测试命令：

```text
node --test tests/core.test.mjs
node tests/browser-smoke.mjs
```

核心测试 13 项通过，覆盖会话清理、同源限制、接受/拒识、请求与图像绑定、单次在途、取消、超时和迟到响应。浏览器测试 6 组通过，使用本机已安装 Edge、合成相机和本地模拟服务，验证单次拍照、相机关闭、DOM 后完成事件、拒识、取消、哈希不匹配、相机拒绝，以及失效会话不触发相机。它们不证明 HoloLens 真机拍照或真实模型推理已成功。

当前浏览器记录在 `tests/qa/browser-results.json`，已核对界面的截图为 `accepted-desktop.png` 和 `rejected-960px.png`。同目录 `browser-failure.json` 与 `failure-0.png` 是修复前同文档 fragment 导航问题的历史调试记录，已被最终通过记录取代。
