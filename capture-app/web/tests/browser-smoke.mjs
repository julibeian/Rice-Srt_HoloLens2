import { createRequire } from 'node:module';
import { createServer } from 'node:http';
import { createHash } from 'node:crypto';
import { readFile, mkdir, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';

const require = createRequire(import.meta.url);
const { chromium } = require('playwright');
const root = new URL('../', import.meta.url);
const output = new URL('./qa/', import.meta.url);
await mkdir(output, { recursive: true });
const secret = 'browser-test-session-token-123456';
const events = [];
const predictions = [];
const checks = [];

const server = createServer(async (req, res) => {
  try {
    const url = new URL(req.url, 'http://localhost');
    if (req.method === 'GET' && url.pathname === '/hololens/api/evidence') {
      const run = req.headers['x-hololens-run'];
      res.writeHead(run === 'browser-expired' ? 401 : 200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ run_id: run })); return;
    }
    if (req.method === 'GET' && /^\/hololens\/(?:index\.html|styles\.css|app\.bundle\.js)?$/.test(url.pathname)) {
      const name = url.pathname.split('/').pop() || 'index.html';
      const type = name.endsWith('.css') ? 'text/css' : name.endsWith('.js') ? 'text/javascript' : 'text/html';
      res.writeHead(200, { 'Content-Type': `${type}; charset=utf-8`, 'Cache-Control': 'no-store' });
      res.end(await readFile(new URL(name, root))); return;
    }
    if (req.method === 'POST' && ['/hololens/api/predict', '/hololens/api/events'].includes(url.pathname)) {
      const chunks = []; for await (const chunk of req) chunks.push(chunk);
      const body = Buffer.concat(chunks);
      assert.equal(req.headers['x-hololens-token'], secret);
      if (url.pathname.endsWith('/events')) {
        const event = JSON.parse(body); assert.equal(event.run_id, req.headers['x-hololens-run']);
        assert.equal(JSON.stringify(event).includes(secret), false);
        events.push(event); res.writeHead(204); res.end(); return;
      }
      const form = await new Request('http://localhost/predict', { method: 'POST',
        headers: { 'Content-Type': req.headers['content-type'] }, body }).formData();
      const photo = Buffer.from(await form.get('file').arrayBuffer());
      assert.equal(photo[0], 0xff); assert.equal(photo[1], 0xd8);
      const hash = createHash('sha256').update(photo).digest('hex');
      const run = req.headers['x-hololens-run'];
      const requestId = req.headers['x-request-id'];
      predictions.push({ run, requestId, imageSha256: hash, bytes: photo.length });
      if (run.includes('cancel')) await new Promise(resolve => setTimeout(resolve, 2000));
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ predicted_class: '稻瘟病', confidence: 0.99, is_valid: !run.includes('reject'),
        capture_evidence: { request_id: requestId, image_sha256: run.includes('mismatch') ? 'a'.repeat(64) : hash,
          received_at: new Date().toISOString(), prediction_id: `prediction-${run}` } }));
      return;
    }
    res.writeHead(404); res.end();
  } catch (error) { res.writeHead(500); res.end(JSON.stringify({ error: error.message })); }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const origin = `http://127.0.0.1:${server.address().port}`;
let browser;
try {
  browser = await chromium.launch({ executablePath: process.env.PLAYWRIGHT_BROWSER_EXECUTABLE || undefined,
    headless: true, args: ['--use-fake-device-for-media-stream', '--use-fake-ui-for-media-stream', '--no-first-run', '--disable-background-networking'] });
  const context = await browser.newContext({ viewport: { width: 1280, height: 800 }, permissions: ['camera'] });
  const page = await context.newPage();
  const browserErrors = [];
  page.on('pageerror', error => browserErrors.push(error.message));
  const link = run => `${origin}/hololens/#token=${secret}&run=${run}&autocapture=1`;
  const waitEvent = async (name, run) => {
    const deadline = Date.now() + 8000;
    while (!events.some(event => event.event === name && event.run_id === run)) {
      if (Date.now() > deadline) throw new Error(`Missing ${name} for ${run}`);
      await new Promise(resolve => setTimeout(resolve, 50));
    }
    return events.find(event => event.event === name && event.run_id === run);
  };

  await page.goto(link('browser-accepted'));
  await page.locator('#result-panel[data-state="accepted"]').waitFor({ timeout: 15000 });
  const event = await waitEvent('result_rendered', 'browser-accepted');
  const prediction = predictions.find(row => row.run === 'browser-accepted');
  assert.equal(event.request_id, prediction.requestId);
  assert.equal(event.details.image_sha256, prediction.imageSha256);
  assert.equal(event.details.accepted, true);
  assert.equal(event.details.class_name, '稻瘟病');
  assert.equal(await page.locator('#result-title').innerText(), '稻瘟病');
  assert.equal(await page.locator('#camera-status').innerText(), '相机已关闭');
  assert.equal(await page.evaluate(() => document.querySelector('video').srcObject), null);
  assert.equal(page.url().includes('token='), false);
  assert.equal(page.url().includes('autocapture='), false);
  assert.equal(await page.evaluate(() => JSON.stringify(localStorage).includes('browser-test-session-token')), false);
  await page.waitForTimeout(2100);
  assert.equal(predictions.filter(row => row.run === 'browser-accepted').length, 1);
  await page.screenshot({ path: fileURLToPath(new URL('accepted-desktop.png', output)), fullPage: true });
  checks.push({ name: 'one-shot accepted response and exact JPEG evidence binding', passed: true });

  await page.setViewportSize({ width: 960, height: 700 });
  await page.goto(link('browser-reject'));
  await page.locator('#result-panel[data-state="rejected"]').waitFor({ timeout: 15000 });
  const rejected = await waitEvent('result_rendered', 'browser-reject');
  assert.equal(await page.locator('#result-title').innerText(), '无法确认');
  assert.equal(rejected.details.accepted, false);
  assert.equal(rejected.details.confidence, 0.99);
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth), false);
  await page.screenshot({ path: fileURLToPath(new URL('rejected-960px.png', output)), fullPage: true });
  checks.push({ name: 'high-confidence refusal stays refused and narrow layout has no horizontal overflow', passed: true });

  await page.goto(link('browser-cancel'));
  await page.locator('#result-panel[data-state="loading"]').waitFor({ timeout: 15000 });
  await page.locator('#cancel-button').click();
  await page.waitForTimeout(2400);
  assert.equal(await page.locator('#result-title').innerText(), '本次识别已取消');
  assert.equal(events.some(item => item.run_id === 'browser-cancel' && item.event === 'result_rendered'), false);
  assert.equal(predictions.filter(item => item.run === 'browser-cancel').length, 1);
  checks.push({ name: 'cancelled real-browser fetch never paints a late result or retries', passed: true });

  await page.goto(link('browser-mismatch'));
  await page.locator('#result-panel[data-state="error"]').waitFor({ timeout: 15000 });
  assert.match(await page.locator('#result-message').innerText(), /对应本次照片/);
  assert.equal(events.some(item => item.run_id === 'browser-mismatch' && item.event === 'result_rendered'), false);
  checks.push({ name: 'server hash mismatch is visible and cannot claim result_rendered', passed: true });

  const deniedPage = await context.newPage();
  await deniedPage.addInitScript(() => {
    navigator.mediaDevices.getUserMedia = async () => { throw new DOMException('Permission denied', 'NotAllowedError'); };
  });
  await deniedPage.goto(`${origin}/hololens/#token=${secret}&run=browser-permission`);
  await deniedPage.locator('#camera-button').click();
  await deniedPage.locator('#result-panel[data-state="error"]').waitFor();
  assert.match(await deniedPage.locator('#result-message').innerText(), /相机访问未获允许/);
  assert.equal(await deniedPage.locator('#camera-button').isEnabled(), true);
  assert.equal(await deniedPage.locator('#capture-button').isDisabled(), true);
  assert.equal(predictions.some(item => item.run === 'browser-permission'), false);
  checks.push({ name: 'camera permission refusal is recoverable and posts no image', passed: true });

  const expiredPage = await context.newPage();
  await expiredPage.addInitScript(() => {
    window.cameraCalls = 0;
    navigator.mediaDevices.getUserMedia = async () => { window.cameraCalls++; throw new Error('must not be called'); };
  });
  await expiredPage.goto(link('browser-expired'));
  await expiredPage.locator('#result-panel[data-state="error"]').waitFor();
  assert.equal(await expiredPage.evaluate(() => window.cameraCalls), 0);
  assert.equal(predictions.some(item => item.run === 'browser-expired'), false);
  checks.push({ name: 'revoked deferred automatic link cannot open the camera', passed: true });

  assert.deepEqual(browserErrors, []);
  const result = { scope: 'Local installed Edge with synthetic camera and mock service only; not HoloLens or live inference',
    browser_version: browser.version(), checked_at: new Date().toISOString(), checks,
    predictions, events: events.map(row => ({ event: row.event, run_id: row.run_id,
      request_id: row.request_id, details: row.details })), browser_errors: browserErrors };
  await writeFile(new URL('browser-results.json', output), JSON.stringify(result, null, 2));
  console.log(JSON.stringify({ checks_passed: checks.length, predictions: predictions.length,
    evidence_file: fileURLToPath(new URL('browser-results.json', output)) }));
} catch (error) {
  const pageStates = [];
  if (browser) {
    for (const [index, page] of browser.contexts().flatMap(context => context.pages()).entries()) {
      pageStates.push({ index, url_path: new URL(page.url()).pathname,
        body: (await page.locator('body').innerText().catch(() => '')).slice(0, 2500) });
      await page.screenshot({ path: fileURLToPath(new URL(`failure-${index}.png`, output)), fullPage: true }).catch(() => {});
    }
  }
  await writeFile(new URL('browser-failure.json', output), JSON.stringify({ error: error.message, checks, predictions, events, pageStates }, null, 2));
  throw error;
} finally {
  if (browser) await browser.close();
  await new Promise(resolve => server.close(resolve));
}
