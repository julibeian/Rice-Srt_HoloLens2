const {test}=require('node:test');const assert=require('node:assert/strict');const fs=require('node:fs');const vm=require('node:vm');const path=require('node:path');
const source=fs.readFileSync(path.join(__dirname,'../src/native.js'),'utf8');
function fixture(options={}){
 const events=[],calls=[],config={version:'1.0.0.47',recognitionMode:'local-yolo',yoloSha256:'a'.repeat(64),yoloDeviceKind:3,...options.config};
 const native={phase:'stopped',protocol:1,onDevice:true,modelSha256:config.yoloSha256,modelLoaded:false,workerActive:false};
 const video={tagName:'VIDEO',videoWidth:320,videoHeight:180,readyState:4,currentTime:1,pause(){},load(){},removeAttribute(){},play:async()=>{}};
 const document={getElementById:()=>video,createElement:()=>{const c={width:0,height:0};c.getContext=()=>({drawImage(){},getImageData:()=>({data:new Uint8ClampedArray(c.width*c.height*4)})});return c;}};
 const W={Storage:{ApplicationData:{current:{localFolder:{createFileAsync:async name=>{const file={name,text:null,renameAsync:async()=>events.push(JSON.parse(file.text))};return file;}}}},CreationCollisionOption:{replaceExisting:0},NameCollisionOption:{replaceExisting:0},FileIO:{readTextAsync:async()=>JSON.stringify(config),writeTextAsync:async(file,text)=>{file.text=text;}}},ApplicationModel:{Package:{current:{installedLocation:{path:'C:\\package',getFileAsync:async()=>({})}}}},System:{Profile:{AnalyticsInfo:{versionInfo:{deviceFamily:'Windows.Holographic'}}}},Security:{Cryptography:{CryptographicBuffer:{generateRandom:()=>new Uint8Array(16),encodeToHexString:()=> 'b'.repeat(32),createFromByteArray:bytes=>({bytes})}}},UI:{WebUI:{WebUIApplication:{addEventListener(){}}}},Media:{Capture:{MediaCapture:function(){this.initializeAsync=async()=>{};this.close=()=>{};this.videoDeviceController={};},MediaCaptureInitializationSettings:function(){},StreamingCaptureMode:{video:2}}}};
 Object.defineProperty(W,'Web',{get(){throw Error('Recognition network client must not be used');}});
 function Detector(){this.start=(p,h,k)=>{calls.push({kind:'start',p,h,k});Object.assign(native,{phase:options.pending?'loading':'running',modelLoaded:!options.pending,workerActive:true});};this.getState=()=>JSON.stringify({...native,...options.nativeOverride});this.stop=()=>{calls.push({kind:'stop'});Object.assign(native,{phase:'stopped',modelLoaded:false,workerActive:false});};this.submit=(buffer,w,h,t,diagnostic)=>{calls.push({kind:'submit',bytes:buffer.bytes.length,w,h,t,diagnostic});return true;};}
 const root={window:null,Windows:W,document,URL:{createObjectURL:()=> 'blob:camera',revokeObjectURL(){}},Uint8Array,Uint8ClampedArray,Promise,Date,JSON,Number,Error,setTimeout,clearTimeout,console,RiceBoot:{activationReady:Promise.resolve()},RiceCameraControls:{selectProfile:async()=>{},initialize:async()=>({enabled:{}}),bound:op=>Promise.resolve(op)},Rice:{HoloLens:{Yolo:{Detector}}}};root.window=root;vm.createContext(root);vm.runInContext(source,root);
 return {N:root.RiceNative,native,video,calls,events,config};
}
test('loads the packaged model and submits new PV frames without a recognition network',async()=>{
 const r=fixture();await r.N.init();await r.N.startCamera();await r.N.yoloStart();assert.equal(r.calls[0].p,'C:\\package\\model.onnx');assert.equal(r.N.submitCamera(),true);assert.equal(r.N.submitCamera(),false);r.video.currentTime=2;assert.equal(r.N.submitCamera(),true);assert.equal(r.calls.filter(c=>c.kind==='submit').length,2);assert.equal(r.calls[1].bytes,320*180*4);assert.equal(r.calls[1].diagnostic,false);
});
test('rejects nonlocal or wrong-model native runtime identity',async()=>{
 const r=fixture({nativeOverride:{onDevice:false}});await r.N.init();await assert.rejects(r.N.yoloStart(),/身份不匹配/);
});
test('stop cancels a pending load and waits for actual native worker release',async()=>{
 const r=fixture({pending:true});await r.N.init();const loading=r.N.yoloStart();await new Promise(resolve=>setTimeout(resolve,5));const stopped=await r.N.yoloStop();assert.equal(stopped.workerActive,false);await assert.rejects(loading,/加载已取消/);assert.equal(r.calls.filter(c=>c.kind==='start').length,1);
});
test('refuses old recognition configuration instead of falling back to a service',async()=>{
 const r=fixture({config:{recognitionMode:'cloud'}});await assert.rejects(r.N.init(),/仅支持眼镜内/);assert.equal(r.calls.length,0);
});
