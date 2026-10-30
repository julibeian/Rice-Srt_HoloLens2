const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const {JSDOM,VirtualConsole}=require('jsdom');
const root=path.resolve(__dirname,'../.state/preview');
const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function until(fn){for(let i=0;i<100;i++){if(fn())return;await sleep(10);}assert.ok(fn(),'Timed out');}
async function start(options={}){
 const errors=[],counts={started:0,captured:0,uploads:0},vc=new VirtualConsole();
 vc.on('jsdomError',e=>{if(!/Could not load (img|link)|Not implemented: HTMLMediaElement/.test(e.message))errors.push(e.message);});
 const dom=new JSDOM(fs.readFileSync(path.join(root,'index.html'),'utf8').replace(/<script[^>]+src="[^"]+"[^>]*><\/script>/g,''),{url:'http://127.0.0.1:8786/?preview=1',runScripts:'outside-only',pretendToBeVisual:true,virtualConsole:vc});
 const w=dom.window;
 w.fetch=async url=>{if(String(url)==='config.json')return {json:async()=>JSON.parse(fs.readFileSync(path.join(root,'config.json')))};throw new Error('Unexpected test network: '+url);};
 w.URL.createObjectURL=()=> 'blob:test-image';w.URL.revokeObjectURL=()=>{};
 w.HTMLMediaElement.prototype.pause=function(){};w.HTMLMediaElement.prototype.load=function(){};
 for(const file of ['boot.js','capture-quality.js','camera-controls.js','native.js','bridge.js','miniapp.js'])w.eval(fs.readFileSync(path.join(root,file),'utf8')+'\n//# sourceURL='+file);
 const p='ms-appdata:///local/capture_ui.jpg';await w.RiceNative.writeFile(p,'/9j/dGVzdA==','base64');
 w.RiceNative.startCamera=async()=>{counts.started++;};w.RiceNative.stopCamera=async()=>{};w.RiceNative.resumeCamera=async()=>{};
 w.RiceNative.captureOptimizedPhoto=async(rect,progress)=>{counts.captured++;if(options.capture)return options.capture(rect,progress,w);return {path:p,selectedAt:Date.now()};};
 w.RiceNative.getLocation=options.location||(async()=>{throw new Error('系统暂未提供位置');});
 w.RicePreviewUpload=async()=>{counts.uploads++;if(options.upload)return options.upload();return {statusCode:200,data:JSON.stringify({predicted_class:'稻瘟病',confidence:.96,is_valid:true,message:'检测成功',top3_predictions:[['稻瘟病',.96]]})};};
 if(options.before)options.before(w);
 w.eval(fs.readFileSync(path.join(root,'app.js'),'utf8')+'\n//# sourceURL=app.js');
 await until(()=>w.RiceBoot.phase==='ready');await until(()=>options.resume?(w.RiceApp.state.busy||w.RiceApp.state.result):w.RiceApp.state.cameraReady);
 return {dom,w,errors,counts,p,close:()=>dom.window.close()};
}
function click(w,id){const node=w.document.getElementById(id);assert.ok(node,id);assert.equal(node.disabled,false,id+' disabled');node.click();}

test('launch opens the live camera with a target selector and no automatic photo or confirmation step',async()=>{
 const s=await start();try{assert.equal(s.counts.started,1);assert.equal(s.counts.captured,0);assert.equal(s.w.document.querySelectorAll('header,footer,.bottom-navigation,#camera-use,#camera-review').length,0);assert.ok(s.w.document.getElementById('camera-target'));assert.equal(s.w.document.getElementById('view-camera').hidden,false);assert.equal(s.w.document.getElementById('camera-shutter').disabled,false);assert.equal(s.errors.length,0);}finally{s.close();}
});
test('one gesture captures, uploads immediately while location is pending, displays result and saves history',async()=>{
 let resolveLocation;const pending=new Promise(resolve=>{resolveLocation=resolve;});const s=await start({location:()=>pending});try{
  click(s.w,'camera-shutter');await until(()=>s.counts.uploads===1&&!s.w.RiceApp.state.busy);await s.w.RiceApp.waitForSaves();
  assert.equal(s.counts.captured,1);assert.equal(s.counts.started,1);assert.equal(s.w.RiceApp.state.result.predicted_class,'稻瘟病');assert.match(s.w.document.getElementById('result-title').textContent,/稻瘟病/);
  let records=JSON.parse(s.w.localStorage.getItem('rice_history_list'));assert.equal(records.length,1);assert.equal(records[0].sortedResults[0].location.status,'unlocated');
  resolveLocation({latitude:32.1,longitude:118.7,accuracy:150,acquiredAt:Date.now()});await sleep(40);
  records=JSON.parse(s.w.localStorage.getItem('rice_history_list'));assert.equal(records[0].sortedResults[0].location.status,'located');assert.equal(records[0].sortedResults[0].location.lat,32.1);
  click(s.w,'tab-history');assert.equal(s.w.document.querySelectorAll('.history-row').length,1);s.w.document.querySelector('.history-row').click();assert.equal(s.w.RiceApp.state.view,'result');assert.match(s.w.document.getElementById('result-title').textContent,/稻瘟病/);
  assert.equal(s.w.document.querySelectorAll('#details-button,#export-button,#result-details').length,0);
  assert.equal(s.w.RiceBoot.errors.length,0,JSON.stringify(s.w.RiceBoot.errors));
 }finally{s.close();}
});
test('double gesture cannot capture or upload twice while inference is in progress',async()=>{
 let resolveUpload;const upload=new Promise(resolve=>{resolveUpload=resolve;});const s=await start({upload:()=>upload});try{
  click(s.w,'camera-shutter');s.w.document.getElementById('camera-shutter').click();await until(()=>s.counts.uploads===1);assert.equal(s.counts.captured,1);assert.equal(s.w.RiceApp.state.busy,true);
  resolveUpload({statusCode:200,data:JSON.stringify({predicted_class:'健康水稻',confidence:.95,is_valid:true})});await until(()=>!s.w.RiceApp.state.busy);assert.equal(s.counts.uploads,1);assert.equal(s.w.document.getElementById('camera-shutter').disabled,false);
 }finally{s.close();}
});
test('invalid image remains a retake result and never becomes healthy or gets disease details',async()=>{
 const s=await start({upload:()=>({statusCode:200,data:JSON.stringify({predicted_class:'其他',confidence:.99,is_valid:false,message:'非水稻叶片'})})});try{click(s.w,'camera-shutter');await until(()=>s.counts.uploads===1&&!s.w.RiceApp.state.busy);await s.w.RiceApp.waitForSaves();const r=JSON.parse(s.w.localStorage.getItem('rice_history_list'))[0];assert.equal(r.summary.invalidCount,1);assert.equal(r.summary.healthyCount,0);assert.equal(s.w.document.getElementById('details-button'),null);assert.match(s.w.document.getElementById('result-title').textContent,/请再拍/);}finally{s.close();}
});
test('upload errors are inline and retry uses the same photo without another capture or confirmation',async()=>{
 let attempts=0;const s=await start({upload:()=>{if(attempts++===0)throw new Error('网络连接失败');return {statusCode:200,data:JSON.stringify({predicted_class:'健康水稻',confidence:.97,is_valid:true})};}});try{
  click(s.w,'camera-shutter');await until(()=>s.counts.uploads===1&&!s.w.RiceApp.state.busy);assert.match(s.w.document.getElementById('result-message').textContent,/网络连接失败/);assert.equal(s.w.document.getElementById('upload-retry').hidden,false);
  click(s.w,'upload-retry');await until(()=>s.counts.uploads===2&&!s.w.RiceApp.state.busy);assert.equal(s.counts.captured,1);assert.equal(s.w.RiceApp.state.result.displayStatus,'healthy');assert.equal(s.w.document.querySelectorAll('[role=dialog]').length,0);
 }finally{s.close();}
});
test('album photo auto-uploads; missing EXIF never borrows the current device location',async()=>{
 const s=await start({location:async()=>({latitude:32.1,longitude:118.7,accuracy:30,acquiredAt:Date.now()})});try{s.w.RiceNative.chooseImages=async()=>[s.p];click(s.w,'album-button');await until(()=>s.counts.uploads===1&&!s.w.RiceApp.state.busy);await s.w.RiceApp.waitForSaves();await sleep(50);assert.equal(s.counts.captured,0);assert.equal(s.w.RiceApp.state.result.location.status,'unlocated');assert.equal(s.w.RiceApp.state.result.origin,'album');}finally{s.close();}
});
test('settings, permission errors and service repair stay on the same document and leave camera usable',async()=>{
 const s=await start({before:w=>{w.RiceNative.ensureService=async()=>{throw new Error('设备尚未配对');};}});try{
  await sleep(25);click(s.w,'tab-settings');assert.equal(s.w.RiceApp.state.view,'settings');assert.match(s.w.document.getElementById('connection-status').textContent,/未配对/);assert.match(s.w.document.getElementById('location-status').textContent,/系统暂未提供位置/);
  let paired=0;s.w.RiceNative.pair=async code=>{assert.equal(code,'12345678');paired++;};s.w.RiceNative.ensureService=async()=>{};s.w.document.getElementById('pair-code').value='12345678';click(s.w,'pair-button');await until(()=>paired===1);await sleep(20);assert.match(s.w.document.getElementById('connection-status').textContent,/界面预览|已连接/);
  click(s.w,'tab-camera');await until(()=>s.w.RiceApp.state.cameraReady);assert.equal(s.counts.started,2);assert.equal(s.w.document.getElementById('camera-shutter').disabled,false);assert.equal(s.w.RiceBoot.errors.length,0);
 }finally{s.close();}
});
test('small window automatically shows result; continue returns to the already warm camera',async()=>{
 const s=await start({before:w=>{Object.defineProperty(w,'innerWidth',{value:600,writable:true});}});try{click(s.w,'camera-shutter');await until(()=>s.counts.uploads===1&&!s.w.RiceApp.state.busy);assert.equal(s.w.RiceApp.state.view,'result');click(s.w,'next-photo');assert.equal(s.w.RiceApp.state.view,'camera');assert.equal(s.counts.started,1);}finally{s.close();}
});
test('installed app keeps its own preview and waits for optimized capture before uploading',async()=>{
 let complete;const photo=new Promise(resolve=>{complete=resolve;});const s=await start({capture:()=>photo,before:w=>{w.RiceNative.nativeMode=true;}});try{
  assert.equal(s.counts.captured,0);assert.equal(s.counts.started,1);assert.equal(s.counts.uploads,0);click(s.w,'camera-shutter');assert.equal(s.counts.captured,1);assert.equal(s.w.RiceApp.state.capturing,true);assert.equal(s.w.document.getElementById('camera-cancel').hidden,false);
  complete({path:s.p,selectedAt:Date.now()});await until(()=>s.counts.uploads===1&&!s.w.RiceApp.state.capturing);assert.equal(s.w.RiceApp.state.view,'result');assert.equal(s.w.RiceApp.state.result.predicted_class,'稻瘟病');assert.equal(s.w.document.querySelectorAll('[role=dialog]').length,0);
 }finally{s.close();}
});

test('quality rejection leaves the preview usable and sends no image to the server',async()=>{const s=await start({capture:async()=>{throw new Error('目标过亮，请降低屏幕亮度或避开反光');}});try{click(s.w,'camera-shutter');await until(()=>!s.w.RiceApp.state.capturing);assert.equal(s.counts.uploads,0);assert.equal(s.w.RiceApp.state.view,'camera');assert.equal(s.w.document.getElementById('camera-shutter').disabled,false);assert.match(s.w.document.getElementById('camera-message').textContent,/过亮/);assert.equal(s.w.localStorage.getItem('rice_pending_upload'),null);}finally{s.close();}});
test('installed preview actively adjusts target lighting before the user presses the shutter',async()=>{let adjustments=0;const s=await start({before:w=>{w.RiceNative.nativeMode=true;w.RiceNative.tunePreview=async()=>{adjustments++;return {adjusting:true,message:'目标过亮，正在降低曝光…'};};}});try{await until(()=>adjustments>0);assert.equal(s.counts.captured,0);assert.equal(s.counts.uploads,0);assert.match(s.w.document.getElementById('camera-message').textContent,/降低曝光/);assert.match(s.w.document.querySelector('#camera-target span').textContent,/自动调光/);}finally{s.close();}});

test('crop and source photo stay paired through history and can be viewed separately',async()=>{const original='ms-appdata:///local/source_ui.jpg';const s=await start({capture:async(_,progress,w)=>{await w.RiceNative.writeFile(original,'/9j/c291cmNl','base64');return {path:'ms-appdata:///local/capture_ui.jpg',originalPath:original,capture:{source:'raw_pv'},selectedAt:Date.now()};}});try{click(s.w,'camera-shutter');await until(()=>s.counts.uploads===1&&!s.w.RiceApp.state.busy);await s.w.RiceApp.waitForSaves();const record=JSON.parse(s.w.localStorage.getItem('rice_history_list'))[0];assert.equal(record.permanentPaths.length,2);assert.match(record.sortedResults[0].originalImagePath,/_source\.jpg$/);const crop=s.w.document.getElementById('result-image').src;click(s.w,'show-original');assert.equal(s.w.RiceApp.state.showingOriginal,true);click(s.w,'show-original');assert.equal(s.w.document.getElementById('result-image').src,crop);}finally{s.close();}});
test('restart restores the pending photo without opening camera again or assigning a new device location',async()=>{
 const s=await start({resume:true,before:w=>{w.localStorage.setItem('rice_pending_upload',JSON.stringify({id:'persisted-request',path:'ms-appdata:///local/capture_ui.jpg',origin:'camera',selectedAt:Date.now()-120000}));}});try{
  await until(()=>s.counts.uploads===1&&!s.w.RiceApp.state.busy);await s.w.RiceApp.waitForSaves();assert.equal(s.counts.started,0);assert.equal(s.counts.captured,0);assert.equal(s.w.RiceApp.state.view,'result');assert.equal(s.w.RiceApp.state.result.location.status,'unlocated');assert.equal(s.w.localStorage.getItem('rice_pending_upload'),null);
 }finally{s.close();}
});
test('a failed upload resumes itself after a network-restored event',async()=>{
 let online,attempt=0;const s=await start({upload:()=>{if(attempt++===0)throw new Error('The server name or address could not be resolved');return {statusCode:200,data:JSON.stringify({predicted_class:'健康水稻',confidence:.96,is_valid:true})};},before:w=>{w.RiceNative.onNetworkChange=fn=>{online=fn;};w.RiceNative.networkState=()=> 'internet';}});try{
  click(s.w,'camera-shutter');await until(()=>s.counts.uploads===1&&!s.w.RiceApp.state.busy);assert.match(s.w.document.getElementById('result-message').textContent,/Wi-Fi/);online();await until(()=>s.counts.uploads===2&&!s.w.RiceApp.state.busy);assert.equal(s.counts.captured,1);assert.equal(s.w.RiceApp.state.result.displayStatus,'healthy');
 }finally{s.close();}
});

