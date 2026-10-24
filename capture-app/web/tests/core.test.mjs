import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { CaptureError, PredictionFlow, Telemetry, normalizePrediction, readConfiguration,
  sameOriginEndpoint, sha256Blob } from '../capture-core.mjs';

const config = { token: 'unit-test-session-token-1234', runId: 'unit-run', sessionId: 'unit-view',
  hasSession: true, predictEndpoint: '/hololens/api/predict', eventsEndpoint: '/hololens/api/events', timeoutMs: 1000 };
const capture = { imageSha256: 'b'.repeat(64), width: 640, height: 360, captureId: 'photo-unit' };
const deferred = () => { let resolve; let reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no; }); return { promise, resolve, reject }; };
const responseFor = (requestId, changes = {}) => ({ ok: true, status: 200, json: async () => Object.assign({
  predicted_class: '稻瘟病', confidence: 0.91, is_valid: true,
  capture_evidence: { request_id: requestId, image_sha256: capture.imageSha256, prediction_id: 'prediction-unit' },
}, changes) });

test('fragment session takes precedence, and secrets plus auto-capture disappear from browser history', () => {
  let rewritten = '';
  const actual = readConfiguration({ href: 'https://rice-srt.cn/hololens/?token=query-token-abcdefghijkl&run=query&autocapture=1#token=fragment-token-abcdefghijkl&run=fragment&autocapture=1' },
    { replaceState(a, b, value) { rewritten = value; } });
  assert.equal(actual.token, 'fragment-token-abcdefghijkl');
  assert.equal(actual.runId, 'fragment');
  assert.equal(actual.autoCapture, true);
  assert.equal(actual.hasSession, true);
  assert.doesNotMatch(rewritten, /token|autocapture/);
  assert.match(rewritten, /run=fragment/);
});

test('invalid sessions remain unusable and prediction/event routes must stay same-origin', () => {
  const invalid = readConfiguration({ href: 'https://rice-srt.cn/hololens/#token=short&run=invalid!run' }, { replaceState() {} });
  assert.equal(invalid.hasSession, false);
  assert.throws(() => sameOriginEndpoint('https://example.com/exfil', 'https://rice-srt.cn', '/predict'), CaptureError);
  assert.throws(() => sameOriginEndpoint('https://username:password@rice-srt.cn/predict', 'https://rice-srt.cn', '/predict'), CaptureError);
});

test('server refusal is preserved even when softmax confidence is high', () => {
  const result = normalizePrediction({ predicted_class: '稻瘟病', confidence: 0.99, is_valid: false });
  assert.equal(result.accepted, false);
  assert.equal(result.decision, 'abstained');
  assert.equal(result.className, '稻瘟病');
});

test('new API decisions normalize without applying a client-side threshold', () => {
  const result = normalizePrediction({ data: { prediction: { class_name: '健康水稻', confidence: 0.40,
    accepted: true, decision: 'accepted' } } });
  assert.equal(result.accepted, true);
  assert.equal(result.className, '健康水稻');
});

test('request ID, JPEG hash, and required fields cannot silently mismatch', () => {
  const good = { predicted_class: '稻瘟病', confidence: 0.8, is_valid: true,
    capture_evidence: { request_id: 'hl-expected', image_sha256: capture.imageSha256 } };
  const expected = { requestId: 'hl-expected', imageSha256: capture.imageSha256 };
  assert.equal(normalizePrediction(good, expected).accepted, true);
  assert.throws(() => normalizePrediction(good, { requestId: 'wrong', imageSha256: capture.imageSha256 }), /对应本次照片/);
  assert.throws(() => normalizePrediction(good, { requestId: 'hl-expected', imageSha256: 'a'.repeat(64) }), /对应本次照片/);
  assert.throws(() => normalizePrediction({ confidence: 4, is_valid: true }, expected), /不完整/);
});

test('one JPEG is posted once with correct session headers and result binding', async () => {
  const transitions = [];
  let calls = 0;
  const photo = new Blob(['jpeg-test-bytes'], { type: 'image/jpeg' });
  const runner = new PredictionFlow(config, { onTransition: value => transitions.push(value), fetchFn: async (url, options) => {
    calls += 1;
    assert.equal(url, '/hololens/api/predict');
    assert.equal(options.method, 'POST');
    assert.equal(options.headers['X-HoloLens-Token'], config.token);
    assert.equal(options.headers['X-HoloLens-Run'], config.runId);
    assert.equal(await options.body.get('file').text(), 'jpeg-test-bytes');
    return responseFor(options.headers['X-Request-ID']);
  } });
  const result = await runner.predict(photo, capture);
  assert.equal(calls, 1);
  assert.equal(result.accepted, true);
  assert.deepEqual(transitions.map(x => x.state), ['loading', 'result']);
});

test('second click while a request is pending cannot post a second image', async () => {
  const pending = deferred();
  let calls = 0;
  let requestId;
  const runner = new PredictionFlow(config, { fetchFn: async (url, options) => {
    calls += 1; requestId = options.headers['X-Request-ID']; return pending.promise;
  } });
  const first = runner.predict(new Blob(['photo']), capture);
  await assert.rejects(runner.predict(new Blob(['second']), capture), /上一张照片/);
  assert.equal(calls, 1);
  pending.resolve(responseFor(requestId));
  await first;
});

test('cancelled request A cannot replace result B even when fetch ignores abort', async () => {
  const pending = [];
  const transitions = [];
  const runner = new PredictionFlow(config, { onTransition: value => transitions.push(value), fetchFn: (url, options) => {
    const request = deferred(); pending.push({ request, id: options.headers['X-Request-ID'] }); return request.promise;
  } });
  const first = runner.predict(new Blob(['photoA']), capture);
  runner.cancel();
  const second = runner.predict(new Blob(['photoB']), capture);
  pending[1].request.resolve(responseFor(pending[1].id, { predicted_class: '健康水稻' }));
  await second;
  pending[0].request.resolve(responseFor(pending[0].id));
  assert.equal(await first, null);
  assert.deepEqual(transitions.map(x => x.state), ['loading', 'cancelled', 'loading', 'result']);
  assert.equal(transitions.at(-1).result.className, '健康水稻');
});

test('timeout is terminal for that image and never retries prediction', async () => {
  const pending = deferred();
  const transitions = [];
  let calls = 0;
  let id;
  const runner = new PredictionFlow(Object.assign({}, config, { timeoutMs: 20 }), { onTransition: value => transitions.push(value),
    fetchFn: (url, options) => { calls += 1; id = options.headers['X-Request-ID']; return pending.promise; } });
  const attempt = runner.predict(new Blob(['photo']), capture);
  await new Promise(resolve => setTimeout(resolve, 45));
  assert.equal(runner.active, null);
  assert.deepEqual(transitions.map(x => x.state), ['loading', 'timeout']);
  pending.resolve(responseFor(id));
  assert.equal(await attempt, null);
  assert.equal(calls, 1);
});

test('cancellation during body parsing also ignores stale JSON', async () => {
  const body = deferred();
  const entered = deferred();
  const transitions = [];
  let id;
  const runner = new PredictionFlow(config, { onTransition: value => transitions.push(value), fetchFn: async (url, options) => {
    id = options.headers['X-Request-ID']; return { ok: true, status: 200, json: () => { entered.resolve(); return body.promise; } };
  } });
  const attempt = runner.predict(new Blob(['photo']), capture);
  await entered.promise;
  runner.cancel();
  body.resolve(await responseFor(id).json());
  assert.equal(await attempt, null);
  assert.deepEqual(transitions.map(x => x.state), ['loading', 'cancelled']);
});

test('HTTP and malformed-result failures do not fabricate a diagnosis', async () => {
  for (const reply of [{ ok: false, status: 503 }, { ok: true, status: 200, json: async () => ({ is_valid: true }) }]) {
    const transitions = [];
    const runner = new PredictionFlow(config, { onTransition: value => transitions.push(value), fetchFn: async () => reply });
    assert.equal(await runner.predict(new Blob(['photo']), capture), null);
    assert.deepEqual(transitions.map(x => x.state), ['loading', 'error']);
    assert.equal(runner.active, null);
  }
});

test('anonymous event body is bounded to approved fields and never includes the token or photo', async () => {
  let recorded;
  const telemetry = new Telemetry(config, async (url, options) => {
    recorded = { url, options, body: JSON.parse(options.body) }; return { ok: true };
  });
  telemetry.emit('result_rendered', 'request-unit', { image_sha256: capture.imageSha256, accepted: false,
    class_name: '其他', confidence: 0.95, token: config.token, photo: 'private bytes' });
  await telemetry.flush();
  assert.equal(recorded.url, config.eventsEndpoint);
  assert.equal(recorded.options.headers['X-HoloLens-Token'], config.token);
  assert.equal(recorded.body.event, 'result_rendered');
  assert.equal(recorded.body.details.accepted, false);
  assert.equal(recorded.body.details.class_name, '其他');
  assert.doesNotMatch(recorded.options.body, /unit-test-session-token|private bytes/);
  assert.equal(Object.hasOwn(recorded.body.details, 'photo'), false);
});

test('photo hash matches SHA256 of the exact JPEG bytes', async () => {
  const bytes = Buffer.from([0xff, 0xd8, 0x00, 0xa1, 0xff, 0xd9]);
  const actual = await sha256Blob(new Blob([bytes], { type: 'image/jpeg' }));
  assert.equal(actual, createHash('sha256').update(bytes).digest('hex'));
});
