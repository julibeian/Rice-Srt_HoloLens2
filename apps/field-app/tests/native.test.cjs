const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const crypto=require('node:crypto');
const source=fs.readFileSync(require('node:path').join(__dirname,'../src/native.js'),'utf8');
function runtime(options={}){
 const local=new Map(),calls=[],hash=crypto.createHash('sha256').update('photo').digest('hex');let token=0;
 function file(name,data){return {name,fileType:'.'+name.split('.').pop(),data:data||Buffer.from('photo'),deleteAsync:async function(){local.delete(name);},getBasicPropertiesAsync:async function(){return {size:this.data.length};},copyAsync:async function(_,name){const copied=file(name,this.data);local.set(name,copied);return copied;}};}
 local.set('photo.jpg',file('photo.jpg'));
 const settings=options.limitedDiagnosticSettings?new Proxy({},{set(target,key,value){if(key==='rice-diagnostic-events'&&Buffer.byteLength(String(value),'utf16le')>8192)throw new Error('Settings value exceeds the 8 KiB limit.');target[key]=value;return true;}}):{};
 function Headers(){this.values={};this.tryAppendWithoutValidation=(key,value)=>{this.values[key]=value;};}
 function Message(method,uri){this.uri=uri;this.method=method;this.headers=new Headers();this.close=()=>{};}
 function Client(){this.defaultRequestHeaders=new Headers();this.close=()=>{};this.sendRequestAsync=message=>{
  const endpoint=message.uri.slice(message.uri.lastIndexOf('/'));calls.push({endpoint,message});let value,status=200;
  if(endpoint==='/register')value={device_id:'device-test',device_key:'never-printed-test-key'};
  else if(endpoint==='/session')value={access_token:'test-session-'+(++token),expires_epoch:Date.now()/1000+3600};
  else {const fields=message.headers.values;value={predicted_class:'健康水稻',is_valid:true,confidence:.97,capture_evidence:{channel:'hololens-app',request_id:fields['X-Request-ID'],image_sha256:options.badEvidence?'0'.repeat(64):hash,prediction_id:'prediction-test'}};
   if(options.unauthorized&&calls.filter(c=>c.endpoint==='/predict').length===1){status=401;value={error:'session_expired',message:'连接已过期，请重试'};}
  }
  const op=Promise.resolve({statusCode:status,content:{readAsStringAsync:async()=>JSON.stringify(value)}});op.cancel=()=>{};return op;
 };}
 function Geolocator(){this.locationStatus=1;this.getGeopositionAsync=(age,timeout)=>{calls.push({endpoint:'geolocation',age,timeout,accuracy:this.desiredAccuracy});const op=Promise.resolve({coordinate:{point:{position:{latitude:32.1,longitude:118.7}},accuracy:300,timestamp:new Date(),positionSource:2}});op.cancel=()=>{};return op;};}
 Geolocator.requestAccessAsync=async()=>options.denied?2:1;
 const W={
  Foundation:{Uri:function(value){return new String(value);}},
  Storage:{ApplicationData:{current:{localSettings:{values:settings},localFolder:{getFilesAsync:async()=>[],getFileAsync:async name=>{if(!local.has(name))throw new Error('missing');return local.get(name);},createFileAsync:async name=>{const f=file(name,Buffer.alloc(0));local.set(name,f);return f;}}}},CreationCollisionOption:{replaceExisting:1},NameCollisionOption:{failIfExists:0},FileIO:{readTextAsync:async f=>f.text,writeTextAsync:async(f,text)=>{f.text=text;},readBufferAsync:async f=>f.data,writeBufferAsync:async(f,data)=>{f.data=data;}},Streams:{UnicodeEncoding:{utf8:1}}},
  Media:{Capture:{CameraCaptureUI:function(){this.photoSettings={};this.captureFileAsync=async mode=>{calls.push({endpoint:'system-camera',mode,settings:this.photoSettings});return options.cancelSystem?null:file('shell.jpg');};},CameraCaptureUIPhotoFormat:{jpeg:0},CameraCaptureUIMaxPhotoResolution:{large3M:4},CameraCaptureUIMode:{photo:1}}},
  ApplicationModel:{Package:{current:{installedLocation:{getFileAsync:async()=>({text:JSON.stringify({apiOrigin:'https://example.test',apiPrefix:'/api',deviceLabel:'HoloLens'})}),tryGetItemAsync:async()=>options.noBootstrap?null:{text:JSON.stringify({pair_code:'12345678',expires_epoch:Date.now()/1000+(options.expired?-1:900)}),deleteAsync:async()=>{}}}}}},
  Security:{Cryptography:{CryptographicBuffer:{generateRandom:()=>crypto.randomBytes(16),encodeToHexString:buffer=>buffer.toString('hex'),convertStringToBinary:text=>Buffer.from(text),convertBinaryToString:(_,buffer)=>buffer.toString()},BinaryStringEncoding:{utf8:1},Core:{HashAlgorithmProvider:{openAlgorithm:()=>({hashData:buffer=>crypto.createHash('sha256').update(buffer).digest()})}},DataProtection:{DataProtectionProvider:function(){this.protectAsync=async buffer=>buffer;this.unprotectAsync=async buffer=>buffer;}}}},
  Web:{Http:{HttpClient:Client,HttpRequestMessage:Message,HttpMethod:{get:'GET',post:'POST'},Filters:{HttpBaseProtocolFilter:function(){}},HttpStringContent:function(value){this.value=value;},HttpMultipartFormDataContent:function(){this.parts=[];this.add=(content,name,filename)=>this.parts.push({content,name,filename});},HttpBufferContent:function(buffer){this.buffer=buffer;this.headers={};},Headers:{HttpMediaTypeHeaderValue:function(value){this.value=value;}}}},
  System:{Profile:{AnalyticsInfo:{versionInfo:{deviceFamily:'Windows.Holographic'}}}},UI:{WebUI:{WebUIApplication:{addEventListener:()=>{}}}},
  Devices:{Geolocation:{Geolocator,GeolocationAccessStatus:{allowed:1},PositionStatus:{disabled:3},PositionAccuracy:{default:0}}}
 };
 const events={},polls=[];
 if(options.deniedDiagnosticSettings)Object.defineProperty(W.Storage.ApplicationData.current,'localSettings',{get(){throw new Error('Access is denied.');}});
 if(options.deniedDiagnosticFile){const original=W.Storage.FileIO.writeTextAsync;W.Storage.FileIO.writeTextAsync=async(f,text)=>{if(f.name==='app-state.json')throw new Error('Diagnostic file is temporarily unavailable.');return original(f,text);};}
 if(options.networkEventsDenied)W.Networking={Connectivity:{NetworkInformation:{addEventListener(){throw new Error('Access is denied.');},getInternetConnectionProfile(){throw new Error('Access is denied.');}}}};
 const root={Windows:W,document:{addEventListener:()=>{},getElementById:()=>null,hidden:false},console,setTimeout,clearTimeout,Promise,URL,Uint8Array,Date,Math,Number,Error,JSON,addEventListener:(name,callback)=>{events[name]=callback;},removeEventListener:(name)=>{delete events[name];},setInterval:(callback,ms)=>{const poll={callback,ms,active:true};polls.push(poll);return poll;},clearInterval:poll=>{poll.active=false;}};root.window=root;vm.createContext(root);vm.runInContext(source,root);return {N:root.RiceNative,calls,local,hash,events,polls};
}
function upload(N){return new Promise((resolve,reject)=>N.upload({filePath:'ms-appdata:///local/photo.jpg',success:resolve,fail:reject}));}
test('native upload automatically pairs once, sends the actual multipart photo and verifies its result hash',async()=>{
 const r=runtime();await r.N.init();await Promise.all([r.N.ensureService(),r.N.ensureService()]);const response=await upload(r.N);assert.equal(response.statusCode,200);assert.equal(r.calls.filter(c=>c.endpoint==='/register').length,1);const request=r.calls.find(c=>c.endpoint==='/predict').message;assert.equal(request.content.parts.length,1);assert.equal(request.content.parts[0].name,'file');assert.equal(request.content.parts[0].content.buffer.toString(),'photo');assert.equal(request.headers.values['X-Image-SHA256'],r.hash);assert.equal(r.N.isPaired(),true);
});
test('expired bootstrap is recorded and produces an actionable pairing error before uploading',async()=>{
 const r=runtime({expired:true});await r.N.init();await assert.rejects(upload(r.N),e=>/尚未配对/.test(e.errMsg));assert.equal(r.calls.filter(c=>c.endpoint==='/predict').length,0);await r.N.log('test_checkpoint',{});const events=JSON.parse(r.local.get('app-state.json').text).events;assert.ok(events.some(e=>e.event==='pairing_expired'));
});
test('native upload rejects a result for a different photo',async()=>{const r=runtime({badEvidence:true});await r.N.init();await assert.rejects(upload(r.N),e=>/不匹配/.test(e.errMsg));});
test('an expired upload token refreshes and retries automatically with the same image/request identity',async()=>{
 const r=runtime({unauthorized:true});await r.N.init();assert.equal((await upload(r.N)).statusCode,200);const predictions=r.calls.filter(c=>c.endpoint==='/predict');assert.equal(predictions.length,2);assert.equal(predictions[0].message.headers.values['X-Request-ID'],predictions[1].message.headers.values['X-Request-ID']);assert.notEqual(predictions[0].message.headers.values.Authorization,predictions[1].message.headers.values.Authorization);
});
test('native location allows Wi-Fi accuracy, uses bounded cached-location overload and shares current reading',async()=>{
 const r=runtime();const positions=await Promise.all([r.N.getLocation(),r.N.getLocation()]);assert.equal(positions[0].latitude,32.1);const calls=r.calls.filter(c=>c.endpoint==='geolocation');assert.equal(calls.length,1);assert.equal(calls[0].accuracy,0);assert.equal(calls[0].age,15000);assert.equal(calls[0].timeout,20000);assert.equal((await r.N.getLocation()).accuracy,300);
});
test('native location distinguishes denied app permission from missing system position',async()=>{const r=runtime({denied:true});await assert.rejects(r.N.getLocation(),e=>e.code==='permission-denied'&&/位置权限/.test(e.message));assert.equal(r.calls.filter(c=>c.endpoint==='geolocation').length,0);});
test('system camera owns the gesture capture, disables cropping and returns the photo straight to app storage',async()=>{const r=runtime();const photo=await r.N.captureSystemPhoto();assert.match(photo,/capture_.*\.jpg$/);const call=r.calls.find(c=>c.endpoint==='system-camera');assert.equal(call.mode,1);assert.equal(call.settings.allowCropping,false);assert.equal(call.settings.format,0);assert.equal(call.settings.maxResolution,4);assert.ok(r.local.has(photo.split('/').pop()));});
test('cancelling the system camera returns no photo and never uploads an earlier image',async()=>{const r=runtime({cancelSystem:true});assert.equal(await r.N.captureSystemPhoto(),null);assert.equal(r.calls.filter(c=>c.endpoint==='/predict').length,0);});

test('denied native network monitoring cannot stop startup and polling still enables upload recovery',async()=>{
 const r=runtime({networkEventsDenied:true});let changes=0;
 const stop=r.N.onNetworkChange(()=>{changes++;});
 await r.N.init();await r.N.log('app_ready',{});
 r.events.online();r.polls[0].callback();assert.equal(changes,2);assert.equal(r.polls[0].ms,15000);
 const state=JSON.parse(r.local.get('app-state.json').text);assert.equal(state.appReady,true);assert.ok(state.runtimeSession);assert.ok(state.events.some(row=>row.event==='network_monitor_fallback'));
 assert.equal((await upload(r.N)).statusCode,200);
 stop();assert.equal(r.polls[0].active,false);assert.equal(r.events.online,undefined);
});

test('diagnostic history stays within native settings limits and cannot prevent startup or uploads',async()=>{const r=runtime({limitedDiagnosticSettings:true});await r.N.init();for(let i=0;i<35;i++)await r.N.log('camera_quality_probe',{message:'光照变化'.repeat(40),id:i});await r.N.log('app_ready',{});const state=JSON.parse(r.local.get('app-state.json').text);assert.equal(state.appReady,true);assert.ok(state.events.length<24);assert.ok(state.events.some(row=>row.event==='app_ready'));assert.equal((await upload(r.N)).statusCode,200);});

test('denied diagnostic storage remains optional while the application and service initialize',async()=>{for(const options of [{deniedDiagnosticSettings:true},{deniedDiagnosticFile:true}]){const r=runtime(options);await r.N.init();await r.N.log('app_ready',{});assert.equal((await upload(r.N)).statusCode,200);}});
