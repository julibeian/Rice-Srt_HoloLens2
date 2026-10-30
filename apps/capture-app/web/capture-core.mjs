export class CaptureError extends Error {
  constructor(code, message) { super(message); this.name = 'CaptureError'; this.code = code; }
}

const ENV = typeof globalThis !== 'undefined' ? globalThis : window;

export function randomId(prefix = 'hl') {
  let suffix;
  if (ENV.crypto && typeof ENV.crypto.getRandomValues === 'function') {
    const bytes = ENV.crypto.getRandomValues(new Uint8Array(16));
    suffix = Array.from(bytes).map(x => x.toString(16).padStart(2, '0')).join('');
  } else suffix = `${Date.now().toString(36)}${Math.random().toString(36).slice(2, 14)}`;
  return `${prefix}-${suffix}`;
}

export function sameOriginEndpoint(candidate, origin, fallback) {
  try {
    const url = new URL(candidate || fallback, `${origin}/`);
    if (url.origin !== origin || !['http:', 'https:'].includes(url.protocol) || url.username || url.password) {
      throw new Error('invalid endpoint');
    }
    return `${url.pathname}${url.search}`;
  } catch (error) { throw new CaptureError('configuration', '识别会话配置无效，请重新打开本次联调链接。'); }
}

export function readConfiguration(locationLike, historyLike, meta = {}) {
  const url = new URL(locationLike.href);
  const fragment = new URLSearchParams(url.hash.slice(1));
  const param = name => fragment.get(name) || url.searchParams.get(name) || '';
  const rawToken = param('token');
  const run = param('run');
  const autoCapture = param('autocapture') === '1';
  // Remove the token before any application fetch. It is never written to storage.
  url.searchParams.delete('token');
  url.searchParams.delete('autocapture');
  if (fragment.has('token') || fragment.has('autocapture')) {
    fragment.delete('token'); fragment.delete('autocapture');
    url.hash = fragment.toString();
  }
  if (historyLike && typeof historyLike.replaceState === 'function') {
    historyLike.replaceState(null, '', `${url.pathname}${url.search}${url.hash}`);
  }
  const token = /^[A-Za-z0-9._~-]{16,256}$/.test(rawToken) ? rawToken : '';
  const runId = /^[A-Za-z0-9._-]{1,64}$/.test(run) ? run : '';
  return {
    token, runId, autoCapture,
    sessionId: randomId('view'),
    predictEndpoint: sameOriginEndpoint(param('endpoint') || meta.predict,
      url.origin, '/hololens/api/predict'),
    eventsEndpoint: sameOriginEndpoint(param('events') || meta.events,
      url.origin, '/hololens/api/events'),
    hasSession: Boolean(token && runId),
    timeoutMs: 15000,
  };
}

export async function sha256Blob(blob) {
  if (!ENV.crypto || !ENV.crypto.subtle) throw new CaptureError('secure_context', '当前浏览器无法核验照片，请从可信的 HTTPS 地址打开拍照页面。');
  const buffer = typeof blob.arrayBuffer === 'function' ? await blob.arrayBuffer() : await new Promise((resolve, reject) => {
    const reader = new FileReader(); reader.onload = () => resolve(reader.result);
    reader.onerror = () => reject(new CaptureError('photo_read', '照片读取失败，请重新拍摄。'));
    reader.readAsArrayBuffer(blob);
  });
  const digest = await ENV.crypto.subtle.digest('SHA-256', buffer);
  return Array.from(new Uint8Array(digest)).map(x => x.toString(16).padStart(2, '0')).join('');
}

function plain(value, limit = 128) {
  return typeof value === 'string' ? value.replace(/[\u0000-\u001f\u007f]/g, '').slice(0, limit) : '';
}

export function normalizePrediction(payload, expected = null) {
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) {
    throw new CaptureError('invalid_response', '识别服务返回了无法读取的结果，请稍后重试。');
  }
  const prediction = (payload.data && payload.data.prediction) || payload;
  const accepted = typeof prediction.accepted === 'boolean' ? prediction.accepted : prediction.is_valid;
  const className = plain(prediction.class_name || prediction.predicted_class);
  const confidence = prediction.confidence;
  if (typeof accepted !== 'boolean' || !className || typeof confidence !== 'number' ||
      !Number.isFinite(confidence) || confidence < 0 || confidence > 1) {
    throw new CaptureError('invalid_response', '识别结果不完整，请稍后重试。');
  }
  const evidence = payload.capture_evidence;
  if (expected && (!evidence || evidence.request_id !== expected.requestId ||
      typeof evidence.image_sha256 !== 'string' || evidence.image_sha256.toLowerCase() !== expected.imageSha256)) {
    throw new CaptureError('image_mismatch', '返回结果未能对应本次照片，请重新拍摄。');
  }
  return {
    accepted, className, confidence,
    decision: accepted ? 'accepted' : (prediction.decision === 'other' || className === '其他' ? 'other' : 'abstained'),
    requestId: plain((evidence && evidence.request_id) || payload.request_id, 64),
    imageSha256: plain(evidence && evidence.image_sha256, 64).toLowerCase(),
    predictionId: plain(evidence && evidence.prediction_id, 128),
  };
}

export function httpFailure(status) {
  if (status === 401 || status === 403) return new CaptureError('session_expired', '本次识别会话已失效，请重新打开联调链接。');
  if (status === 413) return new CaptureError('image_too_large', '照片超过服务限制，请重新拍摄。');
  if (status === 429) return new CaptureError('service_busy', '识别服务繁忙，请稍后重新尝试。');
  if (status === 503) return new CaptureError('service_unavailable', '识别服务暂时不可用，请稍后重新尝试。');
  return new CaptureError('http_error', '识别请求未完成，请检查网络后重新尝试。');
}

export class Telemetry {
  constructor(config, fetchFn = ENV.fetch.bind(ENV)) { this.config = config; this.fetchFn = fetchFn; this.pending = new Set(); }
  emit(event, requestId = '', details = {}) {
    if (!this.config.hasSession) return Promise.resolve(false);
    const allowed = ['image_sha256', 'width', 'height', 'accepted', 'class_name', 'confidence',
      'prediction_id', 'duration_ms', 'http_status', 'error_name', 'stage', 'capture_id'];
    const safeDetails = { session_id: this.config.sessionId, at: new Date().toISOString() };
    for (const key of allowed) {
      const value = details[key];
      if (typeof value === 'string') safeDetails[key] = plain(value, 128);
      else if (typeof value === 'boolean' || (typeof value === 'number' && Number.isFinite(value))) safeDetails[key] = value;
    }
    const operation = Promise.resolve().then(() => this.fetchFn(this.config.eventsEndpoint, {
      method: 'POST', credentials: 'same-origin', cache: 'no-store', keepalive: true,
      headers: { 'Content-Type': 'application/json', 'X-HoloLens-Token': this.config.token,
        'X-HoloLens-Run': this.config.runId },
      body: JSON.stringify({ event: plain(event, 48), run_id: this.config.runId,
        request_id: plain(requestId, 64), details: safeDetails }),
    })).then(response => response.ok).catch(() => false);
    this.pending.add(operation);
    operation.then(() => this.pending.delete(operation), () => this.pending.delete(operation));
    return operation;
  }
  async flush() { await Promise.all(Array.from(this.pending).map(operation => operation.catch(() => false))); }
}

export class PredictionFlow {
  constructor(config, { fetchFn = ENV.fetch.bind(ENV), onTransition = () => {}, telemetry = null,
    clock = () => performance.now() } = {}) {
    this.config = config; this.fetchFn = fetchFn; this.onTransition = onTransition;
    this.telemetry = telemetry; this.clock = clock; this.active = null; this.generation = 0;
  }
  cancel(reason = 'cancelled') {
    const operation = this.active;
    if (!operation) return;
    this.active = null; this.generation += 1;
    operation.controller.abort();
    clearTimeout(operation.timer);
    if (this.telemetry) this.telemetry.emit(reason === 'timeout' ? 'prediction_timeout' : 'prediction_cancelled', operation.requestId,
      { image_sha256: operation.imageSha256, duration_ms: Math.round(this.clock() - operation.started) });
    this.onTransition({ state: reason, requestId: operation.requestId, imageSha256: operation.imageSha256 });
  }
  async predict(blob, capture) {
    if (!this.config.hasSession) throw new CaptureError('configuration', '请使用本次联调链接开启识别会话。');
    if (this.active) throw new CaptureError('busy', '上一张照片仍在识别，请等待或取消。');
    const generation = ++this.generation;
    const operation = { requestId: randomId('hl'), imageSha256: capture.imageSha256,
      controller: typeof AbortController === 'function' ? new AbortController() : { signal: undefined, abort() {} }, started: this.clock() };
    this.active = operation;
    const current = () => this.active === operation && this.generation === generation;
    operation.timer = setTimeout(() => { if (current()) this.cancel('timeout'); }, this.config.timeoutMs);
    this.onTransition(Object.assign({ state: 'loading', requestId: operation.requestId }, capture));
    if (this.telemetry) this.telemetry.emit('prediction_started', operation.requestId, { image_sha256: capture.imageSha256,
      width: capture.width, height: capture.height, capture_id: capture.captureId });
    const form = new FormData();
    form.append('file', blob, `${operation.requestId}.jpg`);
    try {
      const response = await this.fetchFn(this.config.predictEndpoint, {
        method: 'POST', credentials: 'same-origin', cache: 'no-store', signal: operation.controller.signal,
        headers: { 'X-HoloLens-Token': this.config.token, 'X-HoloLens-Run': this.config.runId,
          'X-Request-ID': operation.requestId }, body: form,
      });
      if (!current()) return null;
      if (!response.ok) throw httpFailure(response.status);
      let payload;
      try { payload = await response.json(); }
      catch (error) { throw new CaptureError('invalid_response', '识别服务返回了无法读取的结果，请稍后重试。'); }
      if (!current()) return null;
      const result = normalizePrediction(payload, operation);
      this.active = null;
      clearTimeout(operation.timer);
      const durationMs = Math.round(this.clock() - operation.started);
      this.onTransition(Object.assign({ state: 'result', result, durationMs }, capture));
      return result;
    } catch (error) {
      if (!current()) return null;
      this.active = null;
      clearTimeout(operation.timer);
      const failure = error instanceof CaptureError ? error :
        new CaptureError('network', '连接中断，请检查网络后重新尝试。');
      if (this.telemetry) this.telemetry.emit('prediction_error', operation.requestId, { image_sha256: capture.imageSha256,
        error_name: failure.code, duration_ms: Math.round(this.clock() - operation.started) });
      this.onTransition({ state: 'error', error: failure, requestId: operation.requestId });
      return null;
    }
  }
}
