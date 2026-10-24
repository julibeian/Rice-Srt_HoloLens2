'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { Controller, validateConfiguration, verifyResult } = require('./capture-core.js');
const run = 'hl-test-usb';
const photo = { request_id: 'request-test-1', image_sha256: 'a'.repeat(64), image_bytes: 99, camera_closed: true };
const response = (patch = {}) => ({ predicted_class: '稻瘟病', confidence: 0.99, is_valid: true,
  capture_evidence: { run_id: run, request_id: photo.request_id, image_sha256: photo.image_sha256, prediction_id: 'prediction-1', ...patch } });
function fixture() {
  const files = {}, runtime = {
    exposures: 0, attempted: false, storedPhoto: null, open: async () => {}, deviceFamily: () => 'Test only',
    readJSON: async name => files[name] || null,
    writeJSON: async (name, value) => { files[name] = structuredClone(value); },
    readPhoto: async () => runtime.storedPhoto,
    hasAttempted: () => runtime.attempted, reserveAttempt: () => { runtime.attempted = true; },
    newId: () => photo.request_id, hresult: () => null,
    capture: async () => { runtime.exposures++; runtime.storedPhoto = photo; return photo; }
  };
  return { runtime, files, controller: new Controller(runtime) };
}
test('USB config has no cloud credential or arbitrary endpoint', () => {
  assert.deepEqual(validateConfiguration({ run_id: run, transport: 'usb', token: 'must-not-propagate', endpoint: 'https://other.example' }), { run_id: run, transport: 'usb', autocapture: false, capture_source: 'ui' });
  assert.throws(() => validateConfiguration({ run_id: '../other', transport: 'usb' }));
  assert.throws(() => validateConfiguration({ run_id: run, transport: 'network' }));
});
test('rapid duplicate calls and reopen cannot take a second photograph', async () => {
  const f = fixture(); await f.controller.initialize({ run_id: run, transport: 'usb' });
  await Promise.all([f.controller.capture(), f.controller.capture()]);
  assert.equal(f.runtime.exposures, 1);
  const reopened = new Controller(f.runtime); await reopened.initialize({ run_id: run, transport: 'usb' });
  assert.equal(await reopened.capture(), false); assert.equal(f.runtime.exposures, 1);
});
test('a failed or interrupted attempt is never automatically repeated', async () => {
  const f = fixture(); f.runtime.capture = async () => { f.runtime.exposures++; throw new Error('permission denied'); };
  await f.controller.initialize({ run_id: run, transport: 'usb' });
  await f.controller.capture(); await f.controller.capture();
  assert.equal(f.controller.state.phase, 'camera_error'); assert.equal(f.runtime.exposures, 1);
  const reopened = new Controller(f.runtime); await reopened.initialize({ run_id: run, transport: 'usb' });
  assert.equal(reopened.state.phase, 'camera_attempt_finished'); assert.equal(await reopened.capture(), false);
});
test('photo survives missing network/result and resumes with no new exposure', async () => {
  const f = fixture(); await f.controller.initialize({ run_id: run, transport: 'usb' }); await f.controller.capture();
  for (let i = 0; i < 3; i++) assert.equal(await f.controller.checkResult(), false);
  f.files['result.json'] = response();
  assert.equal(await f.controller.checkResult(), true); assert.equal(f.controller.state.phase, 'result_received');
  assert.equal(await f.controller.acknowledgeRendered(), true); assert.equal(f.controller.state.phase, 'result_rendered');
  assert.equal(f.runtime.exposures, 1); assert.equal(f.files['state.json'].result.image_sha256, photo.image_sha256);
});
test('wrong run, request or JPEG cannot render a result', async () => {
  for (const patch of [{ run_id: 'other' }, { request_id: 'other' }, { image_sha256: 'b'.repeat(64) }]) {
    assert.throws(() => verifyResult(response(patch), run, photo), /本次照片/);
    const f = fixture(); await f.controller.initialize({ run_id: run, transport: 'usb' }); await f.controller.capture();
    f.files['result.json'] = response(patch); assert.equal(await f.controller.checkResult(), false);
    assert.equal(f.controller.state.phase, 'result_error'); assert.equal(await f.controller.acknowledgeRendered(), false);
  }
});
test('high-confidence rejection is preserved in the eye acknowledgement', async () => {
  const f = fixture(); await f.controller.initialize({ run_id: run, transport: 'usb' }); await f.controller.capture();
  f.files['result.json'] = { ...response(), is_valid: false }; await f.controller.checkResult(); await f.controller.acknowledgeRendered();
  assert.equal(f.controller.state.result.accepted, false); assert.equal(f.controller.state.result.confidence, 0.99);
});
test('native camera handoff is discovered without a second UI exposure', async () => {
  const f = fixture(); await f.controller.initialize({ run_id: run, transport: 'usb', capture_source: 'native', autocapture: true });
  assert.equal(f.controller.state.phase, 'waiting_for_capture'); assert.equal(await f.controller.capture(), false);
  f.runtime.storedPhoto = photo; f.files['capture.json'] = photo; f.files['result.json'] = response();
  assert.equal(await f.controller.checkResult(), true); await f.controller.acknowledgeRendered();
  assert.equal(f.controller.state.result.request_id, photo.request_id); assert.equal(f.runtime.exposures, 0);
});
