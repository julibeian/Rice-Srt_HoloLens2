import { CaptureError, PredictionFlow, Telemetry, randomId, readConfiguration, sha256Blob } from './capture-core.mjs';

const ui = {};
for (const id of ['camera-status', 'session-note', 'camera-preview', 'captured-photo', 'camera-placeholder',
  'capture-label', 'camera-button', 'capture-button', 'cancel-button', 'retake-button', 'capture-hint',
  'result-panel', 'result-title', 'result-message', 'score-row', 'result-score', 'result-detail',
  'result-reference', 'run-label']) ui[id] = document.getElementById(id);

const state = { stream: null, opening: false, preparing: false, busy: false, photoUrl: '',
  cameraGeneration: 0, captureGeneration: 0, autoTimer: null, autoAttempted: false };
const metaContent = name => {
  const element = document.querySelector(`meta[name="${name}"]`);
  return element ? element.content : '';
};
let config;
try {
  config = readConfiguration(window.location, window.history, {
    predict: metaContent('capture-predict-endpoint'), events: metaContent('capture-events-endpoint'),
  });
} catch (error) {
  showError(error);
  ui['camera-button'].disabled = true;
  throw error;
}
const telemetry = new Telemetry(config);
const flow = new PredictionFlow(config, { telemetry, onTransition: handleTransition });

function renderControls() {
  const working = state.busy || state.preparing;
  ui['camera-button'].textContent = state.opening ? '正在开启相机' : state.stream ? '关闭相机' : '开启相机';
  ui['camera-button'].disabled = working || state.opening;
  ui['capture-button'].disabled = !state.stream || state.opening || working || !config.hasSession;
  ui['capture-button'].textContent = state.preparing ? '正在保存照片' : state.busy ? '正在识别' : '拍摄并识别';
  ui['cancel-button'].hidden = !state.busy;
  ui['retake-button'].hidden = !state.photoUrl || working;
  ui['retake-button'].disabled = state.opening;
  ui['camera-status'].textContent = state.opening ? '相机正在开启' : state.stream ? '相机已开启' : '相机已关闭';
  ui['camera-status'].dataset.active = String(Boolean(state.stream));
}

function resetResult() {
  ui['result-panel'].dataset.state = 'idle';
  ui['result-panel'].setAttribute('aria-busy', 'false');
  ui['result-title'].textContent = '等待拍摄';
  ui['result-message'].textContent = '对准一片叶片，画面稳定后点击“拍摄并识别”。';
  ui['score-row'].hidden = true;
  ui['result-detail'].hidden = true;
  ui['result-reference'].hidden = true;
}

function clearPhoto() {
  if (state.photoUrl) URL.revokeObjectURL(state.photoUrl);
  state.photoUrl = '';
  ui['captured-photo'].removeAttribute('src');
  ui['captured-photo'].hidden = true;
  ui['capture-label'].hidden = true;
}

function stopCamera() {
  state.cameraGeneration += 1;
  if (state.stream) state.stream.getTracks().forEach(track => track.stop());
  state.stream = null;
  ui['camera-preview'].pause();
  ui['camera-preview'].srcObject = null;
  ui['camera-preview'].hidden = true;
  ui['camera-placeholder'].hidden = Boolean(state.photoUrl);
  renderControls();
}

function cancelAutoCapture() {
  if (state.autoTimer !== null) clearTimeout(state.autoTimer);
  state.autoTimer = null;
}

function cameraFailure(error) {
  const name = error && error.name;
  if (name === 'NotAllowedError' || name === 'PermissionDeniedError') return new CaptureError('camera_permission',
    '相机访问未获允许。请允许此页面使用相机，再点击“开启相机”。');
  if (name === 'NotFoundError' || name === 'DevicesNotFoundError') return new CaptureError('camera_missing',
    '没有找到可用相机，请检查设备相机状态后重试。');
  if (name === 'NotReadableError' || name === 'TrackStartError') return new CaptureError('camera_busy',
    '相机暂时无法使用，请关闭其他正在使用相机的应用后重试。');
  return error instanceof CaptureError ? error : new CaptureError('camera_unavailable',
    '相机未能开启，请检查浏览器的相机许可后重试。');
}

function showError(error) {
  ui['result-panel'].dataset.state = 'error';
  ui['result-panel'].setAttribute('aria-busy', 'false');
  ui['result-title'].textContent = '本次未能完成';
  ui['result-message'].textContent = error && error.message ? error.message : '请重新尝试。';
  ui['score-row'].hidden = true;
  ui['result-detail'].hidden = true;
  ui['result-reference'].hidden = true;
}

async function waitForFrame(video) {
  if (video.readyState >= 2 && video.videoWidth > 0 && video.videoHeight > 0) return;
  await new Promise((resolve, reject) => {
    const started = performance.now();
    const timer = setInterval(() => {
      if (video.readyState >= 2 && video.videoWidth > 0 && video.videoHeight > 0) {
        clearInterval(timer); resolve();
      } else if (performance.now() - started > 10000) {
        clearInterval(timer); reject(new CaptureError('camera_no_frame', '相机暂未传回画面，请关闭相机后重试。'));
      }
    }, 100);
  });
}

async function openCamera() {
  if (state.opening || state.busy || state.preparing) return false;
  if (!navigator.mediaDevices || typeof navigator.mediaDevices.getUserMedia !== 'function') {
    const error = new CaptureError('camera_api_missing', '当前页面无法使用相机，请使用设备上的受支持浏览器并从 HTTPS 地址打开。');
    showError(error); telemetry.emit('camera_error', '', { error_name: error.code }); return false;
  }
  clearPhoto(); resetResult();
  state.opening = true;
  const generation = ++state.cameraGeneration;
  renderControls();
  ui['capture-hint'].textContent = '若设备询问相机许可，请选择允许。画面清晰后再拍摄。';
  let stream;
  try {
    try {
      stream = await navigator.mediaDevices.getUserMedia({ audio: false, video: {
        facingMode: { ideal: 'environment' }, width: { ideal: 1920 }, height: { ideal: 1080 },
        frameRate: { ideal: 15, max: 30 },
      } });
    } catch (error) {
      if (error && error.name === 'OverconstrainedError') {
        stream = await navigator.mediaDevices.getUserMedia({ audio: false, video: true });
      } else throw error;
    }
    if (generation !== state.cameraGeneration) {
      stream.getTracks().forEach(track => track.stop()); return false;
    }
    state.stream = stream;
    ui['camera-preview'].srcObject = stream;
    ui['camera-preview'].hidden = false;
    ui['camera-placeholder'].hidden = true;
    await ui['camera-preview'].play();
    await waitForFrame(ui['camera-preview']);
    if (generation !== state.cameraGeneration) return false;
    ui['capture-hint'].textContent = '对准一片叶片，保持稳定。拍照完成后会立即关闭相机。';
    telemetry.emit('camera_ready', '', { width: ui['camera-preview'].videoWidth,
      height: ui['camera-preview'].videoHeight });
    return true;
  } catch (error) {
    if (stream) stream.getTracks().forEach(track => track.stop());
    state.stream = null;
    ui['camera-preview'].srcObject = null;
    ui['camera-preview'].hidden = true;
    ui['camera-placeholder'].hidden = false;
    const failure = cameraFailure(error);
    showError(failure); telemetry.emit('camera_error', '', { error_name: failure.code });
    return false;
  } finally {
    state.opening = false; renderControls();
  }
}

async function captureAndPredict() {
  if (state.busy || state.preparing || !state.stream || state.opening) return;
  state.autoAttempted = true;
  cancelAutoCapture();
  const generation = ++state.captureGeneration;
  state.preparing = true;
  renderControls();
  try {
    await waitForFrame(ui['camera-preview']);
    const width = ui['camera-preview'].videoWidth;
    const height = ui['camera-preview'].videoHeight;
    if (!width || !height) throw new CaptureError('camera_no_frame', '当前画面尚未就绪，请重新开启相机。');
    const canvas = document.createElement('canvas');
    canvas.width = width; canvas.height = height;
    const context = canvas.getContext('2d', { alpha: false });
    if (!context) throw new CaptureError('photo_capture', '照片生成失败，请重新拍摄。');
    context.drawImage(ui['camera-preview'], 0, 0, width, height);
    const blob = await new Promise((resolve, reject) => canvas.toBlob(value => {
      if (value && value.size > 0) resolve(value);
      else reject(new CaptureError('photo_capture', '照片生成失败，请重新拍摄。'));
    }, 'image/jpeg', 0.90));
    // The one-shot session never leaves the camera running during network work.
    stopCamera();
    if (generation !== state.captureGeneration) return;
    clearPhoto();
    state.photoUrl = URL.createObjectURL(blob);
    ui['captured-photo'].src = state.photoUrl;
    ui['captured-photo'].hidden = false;
    ui['camera-placeholder'].hidden = true;
    ui['capture-label'].hidden = false;
    ui['capture-hint'].textContent = '相机已关闭。本次结果只对应上方这张照片。';
    const imageSha256 = await sha256Blob(blob);
    if (generation !== state.captureGeneration) return;
    const capture = { captureId: randomId('photo'), imageSha256, width, height };
    telemetry.emit('photo_captured', '', { image_sha256: imageSha256, width, height, capture_id: capture.captureId });
    state.preparing = false;
    await flow.predict(blob, capture);
  } catch (error) {
    if (generation !== state.captureGeneration) return;
    stopCamera();
    const failure = error instanceof CaptureError ? error : new CaptureError('photo_capture', '拍照未能完成，请重新开启相机。');
    showError(failure); telemetry.emit('capture_error', '', { error_name: failure.code });
  } finally {
    if (generation === state.captureGeneration) { state.preparing = false; renderControls(); }
  }
}

function afterPaint(callback) {
  window.requestAnimationFrame(() => window.requestAnimationFrame(callback));
}

function handleTransition(transition) {
  if (transition.state === 'loading') {
    state.busy = true;
    ui['result-panel'].dataset.state = 'loading';
    ui['result-panel'].setAttribute('aria-busy', 'true');
    ui['result-title'].textContent = '正在识别';
    ui['result-message'].textContent = '正在处理本次照片，请稍候。你可以取消本次请求。';
    ui['score-row'].hidden = true;
    ui['result-detail'].hidden = true;
    ui['result-reference'].hidden = true;
  } else if (transition.state === 'result') {
    state.busy = false;
    const result = transition.result;
    ui['result-panel'].dataset.state = result.accepted ? 'accepted' : 'rejected';
    ui['result-panel'].setAttribute('aria-busy', 'false');
    ui['result-title'].textContent = result.accepted ? result.className : '无法确认';
    ui['result-message'].textContent = result.accepted ? '已返回本次照片的候选结果，请结合现场情况复核。' :
      result.decision === 'other' ? '当前照片可能不在模型支持范围内。请重新拍摄清晰叶片或请专业人员判断。' :
        '模型未接受本次结果。请调整光照和距离后重拍，或请专业人员判断。';
    ui['result-score'].textContent = `${(result.confidence * 100).toFixed(1)}%`;
    ui['score-row'].hidden = false;
    ui['result-detail'].textContent = result.accepted ? '此分数仅表示模型判断强度，不是实际诊断正确率。' :
      '本次没有形成可接受的病名结论。';
    ui['result-detail'].hidden = false;
    ui['result-reference'].textContent = `本次参考编号 ${result.requestId.slice(-12)}`;
    ui['result-reference'].hidden = false;
    const renderGeneration = state.captureGeneration;
    afterPaint(() => {
      if (renderGeneration !== state.captureGeneration || ui['result-panel'].dataset.state !== (result.accepted ? 'accepted' : 'rejected')) return;
      telemetry.emit('result_rendered', result.requestId, { image_sha256: result.imageSha256,
        width: transition.width, height: transition.height, accepted: result.accepted,
        class_name: result.className, confidence: result.confidence,
        prediction_id: result.predictionId, duration_ms: transition.durationMs });
    });
  } else if (transition.state === 'error') {
    state.busy = false; showError(transition.error);
  } else if (transition.state === 'cancelled' || transition.state === 'timeout') {
    state.busy = false;
    showError(new CaptureError(transition.state, transition.state === 'timeout' ?
      '识别等待已超过 15 秒。请检查网络后重新拍摄。' : '本次识别已取消，迟到的响应不会替换当前结果。'));
    ui['result-title'].textContent = transition.state === 'timeout' ? '本次识别超时' : '本次识别已取消';
  }
  renderControls();
}

ui['camera-button'].addEventListener('click', () => {
  cancelAutoCapture();
  if (state.stream) stopCamera(); else openCamera();
});
ui['capture-button'].addEventListener('click', captureAndPredict);
ui['cancel-button'].addEventListener('click', () => flow.cancel());
ui['retake-button'].addEventListener('click', () => {
  cancelAutoCapture();
  state.captureGeneration += 1;
  openCamera();
});
window.addEventListener('pagehide', () => {
  cancelAutoCapture(); state.captureGeneration += 1; flow.cancel(); stopCamera(); clearPhoto();
});
window.addEventListener('hashchange', () => {
  // Opening a fresh fragment link in an existing browser tab is otherwise a
  // same-document navigation and would keep the previous in-memory session.
  const nextFragment = new URLSearchParams(window.location.hash.slice(1));
  if (nextFragment.has('token')) {
    cancelAutoCapture(); state.captureGeneration += 1; flow.cancel(); stopCamera();
    window.location.reload();
  }
});

ui['run-label'].textContent = config.runId ? `本次会话 ${config.runId}` : '';
if (!config.hasSession) {
  ui['session-note'].textContent = '识别会话尚未配置。可手动开启相机取景；识别时请使用本次联调链接。';
  ui['session-note'].hidden = false;
} else if (config.autoCapture) {
  ui['session-note'].textContent = '本次为单张联调：相机获准后会自动拍摄一张，随后立即关闭相机并显示结果。';
  ui['session-note'].hidden = false;
}
renderControls();
telemetry.emit('page_ready', '', { stage: config.autoCapture ? 'one_shot' : 'manual' });
if (config.autoCapture && config.hasSession) {
  // A deferred old link must not activate a camera after its session is revoked.
  const preflightAbort = new AbortController();
  const preflightTimer = setTimeout(() => preflightAbort.abort(), 5000);
  fetch('/hololens/api/evidence', {
    headers: { 'X-HoloLens-Token': config.token, 'X-HoloLens-Run': config.runId },
    credentials: 'omit', cache: 'no-store', signal: preflightAbort.signal,
  }).then(async response => {
    if (!response.ok) throw new CaptureError('inactive_session', '本次联调会话已失效，请使用当前会话；相机未开启。');
    const proof = await response.json();
    if (proof.run_id !== config.runId) throw new CaptureError('inactive_session', '会话校验不一致，相机未开启。');
    return openCamera();
  }).then(ready => {
    if (!ready || state.autoAttempted) return;
    state.autoTimer = setTimeout(() => {
      state.autoTimer = null;
      if (!state.autoAttempted && state.stream) captureAndPredict();
    }, 1800);
  }).catch(error => {
    showError(error instanceof CaptureError ? error : new CaptureError('session_unavailable', '当前无法核对识别会话，相机未开启。'));
  }).finally(() => clearTimeout(preflightTimer));
}
