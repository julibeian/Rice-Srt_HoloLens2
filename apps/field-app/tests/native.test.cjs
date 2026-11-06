const {test}=require('node:test');const assert=require('node:assert/strict');const fs=require('node:fs');const vm=require('node:vm');const path=require('node:path');
const source=fs.readFileSync(path.join(__dirname,'../src/native.js'),'utf8');
function fixture(options={}){
 const events=[],calls=[],config={version:'1.0.0.47',recognitionMode:'local-yolo',yoloSha256:'a'.repeat(64),yoloDeviceKind:3,...options.config};
 const native={phase:'stopped',protocol:1,onDevice:true,modelSha256:config.yoloSha256,modelLoaded:false,workerActive:false};
 const video={tagName:'VIDEO',style:{},videoWidth:320,videoHeight:180,readyState:4,currentTime:1,pause(){},load(){},removeAttribute(){},play:async()=>{}};
 const document={getElementById:()=>video,createElement:()=>{const c={width:0,height:0};c.getContext=()=>({drawImage(){},getImageData:()=>({data:new Uint8ClampedArray(c.width*c.height*4)})});return c;}};
 const W={Storage:{ApplicationData:{current:{localFolder:{createFileAsync:async name=>{const file={name,text:null,renameAsync:async()=>events.push(JSON.parse(file.text))};return file;}}}},CreationCollisionOption:{replaceExisting:0},NameCollisionOption:{replaceExisting:0},FileIO:{readTextAsync:async file=>file===options.commandFile?options.readCommand():JSON.stringify(config),writeTextAsync:async(file,text)=>{file.text=text;}}},ApplicationModel:{Package:{current:{installedLocation:{path:'C:\\package',getFileAsync:async()=>({}),tryGetItemAsync:async()=>options.commandFile||null}}}},System:{Profile:{AnalyticsInfo:{versionInfo:{deviceFamily:'Windows.Holographic'}}}},Security:{Cryptography:{CryptographicBuffer:{generateRandom:()=>new Uint8Array(16),encodeToHexString:()=> 'b'.repeat(32),createFromByteArray:bytes=>({bytes})}}},UI:{WebUI:{WebUIApplication:{addEventListener(){}}}},Media:{Capture:{MediaCapture:function(){this.initializeAsync=async()=>{};this.close=()=>{};this.videoDeviceController={};},MediaCaptureInitializationSettings:function(){},StreamingCaptureMode:{video:2}}}};
 Object.defineProperty(W,'Web',{get(){throw Error('Recognition network client must not be used');}});
 function Detector(){this.start=(p,h,k)=>{calls.push({kind:'start',p,h,k});Object.assign(native,{phase:options.pending?'loading':'running',modelLoaded:!options.pending,workerActive:true});};this.getState=()=>JSON.stringify({...native,...options.nativeOverride});this.stop=()=>{calls.push({kind:'stop'});Object.assign(native,{phase:'stopped',modelLoaded:false,workerActive:false});};this.submit=(buffer,w,h,t,diagnostic)=>{calls.push({kind:'submit',bytes:buffer.bytes.length,w,h,t,diagnostic});return true;};}
 const root={window:null,Windows:W,document,URL:{createObjectURL:()=> 'blob:camera',revokeObjectURL(){}},Uint8Array,Uint8ClampedArray,Promise,Date,JSON,Number,Error,setTimeout:options.setTimeout||setTimeout,clearTimeout:options.clearTimeout||clearTimeout,console,RiceBoot:{activationReady:Promise.resolve()},RiceCameraControls:{selectProfile:async(W,settings,log,request)=>{if(request)calls.push({kind:'cameraProfile',request});},validateCapture:require('../src/camera-controls.js').validateCapture,readPreview:()=>{const fps=config.cameraCaptureRequest?config.cameraCaptureRequest.fps:30;return {width:video.videoWidth,height:video.videoHeight,fps,key:video.videoWidth+'x'+video.videoHeight+'@'+fps};},initialize:async()=>({enabled:{}}),bound:op=>Promise.resolve(op)},Rice:{HoloLens:{Yolo:{Detector}}}};root.window=root;vm.createContext(root);vm.runInContext(source,root);
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
test('diagnostic frame commands are ignored in the production app',async()=>{
 const r=fixture();await r.N.init();assert.equal(await r.N.readCameraCheck(),null);
});

test('preview load controls are sealed in production and preserve live capture in diagnostics',async()=>{
 const production=fixture();await production.N.init();await production.N.startCamera();assert.throws(()=>production.N.setPreviewMode('masked'),/诊断包/);assert.equal(production.video.style.visibility,undefined);
 const r=fixture({config:{cameraDiagnostics:true}});await r.N.init();await r.N.startCamera();await r.N.yoloStart();r.N.setPreviewMode('masked');
 assert.equal(r.N.cameraTelemetry().previewMode,'masked');assert.equal(r.N.cameraTelemetry().previewReady,true);assert.equal(r.N.submitCamera(),true);r.video.currentTime=2;assert.equal(r.N.submitCamera(),true);
 assert.throws(()=>r.N.setPreviewMode('invalid'),/无效/);r.N.setPreviewMode('visible');assert.equal(r.N.cameraTelemetry().previewMode,'visible');assert.equal(r.calls.filter(c=>c.kind==='stop').length,0);
 r.N.setPreviewMode('masked');await r.N.stopCamera();assert.equal(r.video.style.visibility,'');
});

test('diagnostic preview masking restores automatically without releasing camera or model',async()=>{
 let expire,limit,cleared=false;
 const r=fixture({config:{cameraDiagnostics:true},setTimeout:(callback,ms)=>{if(ms===120000){expire=callback;limit=ms;return 'preview-lease';}return setTimeout(callback,ms);},clearTimeout:value=>{if(value==='preview-lease')cleared=true;else clearTimeout(value);}});
 await r.N.init();await r.N.startCamera();await r.N.yoloStart();r.N.setPreviewMode('masked');assert.equal(limit,120000);expire();
 assert.equal(cleared,true);assert.equal(r.N.cameraTelemetry().previewMode,'visible');assert.equal(r.N.cameraTelemetry().previewReady,true);assert.equal(r.N.yoloState().modelLoaded,true);assert.equal(r.calls.filter(c=>c.kind==='stop').length,0);
});

test('a command still being copied survives a locked or partial read and is consumed once',async()=>{
 let reads=0,deletions=0;const command={session:'b'.repeat(32),id:'c'.repeat(32),action:'yolo_state'};
 const options={config:{cameraDiagnostics:true},readCommand:async()=>{reads++;if(reads===1)throw new Error('file is being used');if(reads===2)return '{"session":';return JSON.stringify(command);}};
 options.commandFile={deleteAsync:async()=>{deletions++;options.commandFile=null;}};
 const r=fixture(options);await r.N.init();
 await assert.rejects(r.N.readCameraCheck(),/being used/);assert.equal(deletions,0);
 await assert.rejects(r.N.readCameraCheck(),SyntaxError);assert.equal(deletions,0);
 assert.equal((await r.N.readCameraCheck()).id,command.id);assert.equal(deletions,1);
 assert.equal(await r.N.readCameraCheck(),null);assert.equal(reads,3);
});
test('reports actual video counters and leaves unsupported counters explicitly unavailable',async()=>{
 const r=fixture();await r.N.init();await r.N.startCamera();assert.equal(r.N.cameraTelemetry().decodedFrames,null);assert.equal(r.N.cameraTelemetry().frameCounterMethod,'unavailable');
 r.video.getVideoPlaybackQuality=()=>({totalVideoFrames:123,droppedVideoFrames:2,corruptedVideoFrames:0});
 const snapshot=r.N.cameraTelemetry();assert.equal(snapshot.decodedFrames,123);assert.equal(snapshot.droppedFrames,2);assert.equal(snapshot.videoWidth,320);assert.equal(snapshot.mediaTimeMs,1000);
});
test('starts the physical camera with an exact capture request while diagnostic image commands stay disabled',async()=>{
 const capture={width:320,height:180,fps:15},r=fixture({config:{resourceTelemetry:true,cameraCaptureRequest:capture}});
 await r.N.init();assert.equal(r.N.telemetryEnabled(),true);assert.equal(r.N.diagnosticsEnabled(),false);await r.N.startCamera();
 assert.deepEqual(r.calls.find(c=>c.kind==='cameraProfile').request,capture);assert.equal(r.N.cameraTelemetry().key,'320x180@15');
 assert.equal(await r.N.readCameraCheck(),null);
});
