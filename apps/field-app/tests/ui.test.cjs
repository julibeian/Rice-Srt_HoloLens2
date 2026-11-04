const {test}=require('node:test');const assert=require('node:assert/strict');const fs=require('node:fs');const path=require('node:path');const {JSDOM}=require('jsdom');
async function flush(){for(let i=0;i<6;i++)await new Promise(resolve=>setImmediate(resolve));}
async function fixture(options={}){
 const html=fs.readFileSync(path.join(__dirname,'../src/index.html'),'utf8').replace(/<script[^>]*>[^<]*<\/script>/g,'');
 const dom=new JSDOM(html,{runScripts:'outside-only',pretendToBeVisual:true}),w=dom.window,intervals=[],events=[],draws=[];let submit=0,stops=0,resolveLoad;
 const state={protocol:1,onDevice:true,model:'YOLOv8n-6',modelSha256:'a'.repeat(64),phase:'running',workerActive:true,modelLoaded:true,busy:false,frames:0,cameraFrames:0,sourceWidth:896,sourceHeight:504,detections:[],inputSize:640,resultAgeMs:0,inferenceMs:100};
 w.setInterval=(f,ms)=>{intervals.push({f,ms});return intervals.length;};w.fetch=()=>{throw Error('Unexpected network')};
 const context={clearRect(){draws.length=0;},strokeRect(...a){draws.push(a)},measureText:s=>({width:s.length*10}),fillRect(){},fillText(){}};w.HTMLCanvasElement.prototype.getContext=()=>context;
 w.HTMLElement.prototype.getBoundingClientRect=()=>({width:896,height:504});
 w.RiceBoot={completeActivation(){}};
 w.RiceNative={init:async()=>{},version:()=> '1.0.0.47',startCamera:async()=>{},yoloStart:()=>options.pending?new Promise(resolve=>{resolveLoad=resolve;}):Promise.resolve(state),yoloStop:async()=>{stops++;state.phase='stopped';state.workerActive=false;return state;},yoloState:()=>state,submitCamera:()=>{submit++;return true;},readCameraCheck:async()=>null,log:async(event,details)=>events.push({event,details}),diagnosticsEnabled:()=>false,autoStart:()=>true};
 w.eval(fs.readFileSync(path.join(__dirname,'../src/dynamic.js'),'utf8'));w.eval(fs.readFileSync(path.join(__dirname,'../src/app.js'),'utf8'));await flush();
 return {w,dom,state,events,draws,poll:async()=>{await intervals.find(x=>x.ms===100).f();await flush();},render:()=>intervals.find(x=>x.ms===200).f(),submit:()=>submit,stops:()=>stops,resolveLoad:()=>resolveLoad(state)};
}
test('keeps the preview running and overlays multiple native boxes without opening a result page',async()=>{
 const r=await fixture();Object.assign(r.state,{frames:1,cameraFrames:1,detections:[{classId:1,label:'稻水象甲',confidence:.85,box:[10,20,100,200]},{classId:3,label:'白叶枯病',confidence:.7,box:[200,100,300,300]}]});await r.poll();assert.equal(r.draws.length,2);assert.equal(r.w.document.getElementById('dynamic-label').textContent,'检出 2 个目标');assert.equal(r.submit(),1);assert.equal(r.w.document.getElementById('camera-video').hidden,false);assert.equal(r.w.document.getElementById('result-panel'),null);r.dom.window.close();
});
test('busy native work does not build a queue and stale detections are cleared',async()=>{
 const r=await fixture();Object.assign(r.state,{frames:1,cameraFrames:1,busy:true,resultAgeMs:6000,detections:[{classId:1,label:'稻水象甲',confidence:.8,box:[10,10,20,20]}]});await r.poll();assert.equal(r.submit(),0);assert.equal(r.draws.length,0);assert.match(r.w.document.getElementById('dynamic-hint').textContent,/旧框已清除/);r.dom.window.close();
});
test('hiding the app during model loading cannot reactivate a late result',async()=>{
 const r=await fixture({pending:true});Object.defineProperty(r.w.document,'hidden',{value:true,configurable:true});r.w.document.dispatchEvent(new r.w.Event('visibilitychange'));await flush();r.resolveLoad();await flush();assert.ok(r.stops()>=1);assert.equal(r.events.some(x=>x.event==='dynamic_started'),false);assert.equal(r.w.document.getElementById('dynamic-toggle').textContent,'开始识别');r.dom.window.close();
});
