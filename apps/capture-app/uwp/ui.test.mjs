// Local UI regression only. All WinRT/camera/storage/model APIs below are mocks.
import { createServer } from 'node:http';
import { readFile, mkdir, writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import assert from 'node:assert/strict';
const require = createRequire(import.meta.url);
const { chromium } = require('playwright');
const mock = `window.Windows={UI:{WebUI:{WebUIApplication:{addEventListener:function(){}}}}};
window.NativeCaptureRuntime=function(){
 const self=this;this.files={};this.attempted=false;window.testRuntime=this;this.exposures=0;
 this.loadConfiguration=async()=>({run_id:'hl-ui-test',transport:'usb',autocapture:false});
 this.open=async()=>{};this.closeCamera=()=>{};this.deviceFamily=()=> 'MOCK UI ONLY';this.hasAttempted=()=>this.attempted;
 this.reserveAttempt=()=>{this.attempted=true};this.newId=()=> 'hl-request-ui';this.hresult=()=>null;
 this.readPhoto=async()=>null;this.readJSON=async name=> this.files[name]||null;
 this.writeJSON=async(name,value)=>{this.files[name]=JSON.parse(JSON.stringify(value))};
 this.preview=()=>new Promise(resolve=>setTimeout(()=>resolve('data:image/svg+xml;base64,'+btoa('<svg xmlns="http://www.w3.org/2000/svg" width="600" height="400"><rect width="600" height="400" fill="gray"/><text x="30" y="200" fill="white">SYNTHETIC UI TEST</text></svg>')),2000));
 this.capture=async id=>{this.exposures++;const photo={request_id:id,image_sha256:'a'.repeat(64),image_bytes:99,camera_closed:true};
  this.files['result.json']={predicted_class:'稻瘟病',is_valid:location.hash!=='#reject',confidence:0.99,message:'模拟接口响应，仅验证界面。',capture_evidence:{run_id:'hl-ui-test',request_id:id,image_sha256:photo.image_sha256,prediction_id:'prediction-ui'}};return photo;};
};`;
const server = createServer(async (req, res) => {
  const name = new URL(req.url, 'http://localhost').pathname.slice(1) || 'index.html';
  if (!['index.html', 'styles.css', 'capture-core.js', 'native-runtime.js', 'app.js'].includes(name)) { res.writeHead(404); res.end(); return; }
  res.writeHead(200, { 'Content-Type': name.endsWith('.js') ? 'text/javascript; charset=utf-8' : name.endsWith('.css') ? 'text/css' : 'text/html; charset=utf-8' });
  res.end(name === 'native-runtime.js' ? mock : await readFile(new URL(name, import.meta.url)));
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const origin = 'http://127.0.0.1:' + server.address().port;
let browser;
const checks = [];
try {
  browser = await chromium.launch({ executablePath: process.env.PLAYWRIGHT_BROWSER_EXECUTABLE || undefined, headless: true, args: ['--no-first-run', '--disable-background-networking'] });
  const page = await browser.newPage({ viewport: { width: 960, height: 700 } });
  const errors = []; page.on('pageerror', e => errors.push(e.message));
  for (const rejected of [false, true]) {
    await page.goto(origin + (rejected ? '/?scenario=rejected#reject' : '/?scenario=accepted'));
    await page.locator('#capture-button').click();
    await page.waitForFunction(() => window.testRuntime.files['state.json'].phase === 'result_rendered');
    await page.waitForTimeout(1200);
    assert.equal(await page.locator('#result-title').innerText(), rejected ? '未确认识别' : '稻瘟病');
    assert.equal(await page.locator('#score').innerText(), '99.0%');
    assert.equal(await page.evaluate(() => window.testRuntime.exposures), 1);
    assert.equal(await page.evaluate(() => window.testRuntime.files['state.json'].result.accepted), !rejected);
    assert.equal(await page.locator('#capture-button').isDisabled(), true);
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth), false);
    checks.push(rejected ? 'High-score refusal preserved in UI and eye acknowledgement' : 'Late photo preview cannot overwrite displayed result or its acknowledgement');
  }
  assert.deepEqual(errors, []);
  await mkdir(new URL('./qa/', import.meta.url), { recursive: true });
  await writeFile(new URL('./qa/ui-results.json', import.meta.url), JSON.stringify({ scope: 'PC headless Edge with mock WinRT, camera, storage and model only. Not HoloLens proof.', at: new Date().toISOString(), checks, errors }, null, 2));
  console.log(JSON.stringify({ ui_checks_passed: checks.length, errors }));
} finally { if (browser) await browser.close(); await new Promise(resolve => server.close(resolve)); }
