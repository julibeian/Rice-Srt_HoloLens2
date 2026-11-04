/* HoloLens local camera and native YOLO bridge. No recognition HTTP client. */
(function(root){
 'use strict';
 var W=root.Windows,K=root.RiceCameraControls,nativeMode=!!W,config={},runtimeSession=null,diagnosticSession=null,diagnosticIds={},camera=null,cameraUrl=null,cameraGeneration=0,cameraPreviewReady=false,appReady=false,detector=null,canvas=null,lastCameraTime=-1,logQueue=Promise.resolve(),rows=[],latestNative=null,engineGeneration=0;
 function id(){return nativeMode?W.Security.Cryptography.CryptographicBuffer.encodeToHexString(W.Security.Cryptography.CryptographicBuffer.generateRandom(16)):String(Date.now());}
 function fail(message){return new Error(message);}
 function delay(ms){return new Promise(function(resolve){setTimeout(resolve,ms);});}
 async function write(name,value){var file=await W.Storage.ApplicationData.current.localFolder.createFileAsync(name+'.pending',W.Storage.CreationCollisionOption.replaceExisting);await W.Storage.FileIO.writeTextAsync(file,JSON.stringify(value));await file.renameAsync(name,W.Storage.NameCollisionOption.replaceExisting);}
 function log(event,details){
  var row={event:event,at:new Date().toISOString(),session:runtimeSession,details:details||{}};
  if(event==='app_ready')appReady=true;if(event==='boot_failed')appReady=false;
  if(!nativeMode){console.info('[Rice]',row);return Promise.resolve();}
  logQueue=logQueue.then(async function(){rows.push(row);rows=rows.slice(-24);while(rows.length>1&&JSON.stringify(rows).length>6500)rows.shift();await write('app-state.json',{phase:event,at:row.at,version:config.version,runtimeSession:runtimeSession,appReady:appReady,cameraPreviewReady:cameraPreviewReady,cameraSession:diagnosticSession,nativeDetector:latestNative,events:rows});}).catch(function(){});return logQueue;
 }
 async function init(){
  if(!nativeMode)throw fail('请在 HoloLens 应用内运行本地检测');
  if(root.RiceBoot&&root.RiceBoot.activationReady)await root.RiceBoot.activationReady;
  var file=await W.ApplicationModel.Package.current.installedLocation.getFileAsync('config.json');config=JSON.parse(await W.Storage.FileIO.readTextAsync(file));
  if(config.recognitionMode!=='local-yolo')throw fail('本版本仅支持眼镜内 YOLO 检测');
  runtimeSession=id();if(config.cameraDiagnostics===true)diagnosticSession=id();
  await log('runtime_ready',{deviceFamily:W.System.Profile.AnalyticsInfo.versionInfo.deviceFamily,recognition:'local-yolo',networkRequired:false});
 }
 async function stopCamera(){cameraGeneration++;cameraPreviewReady=false;var video=document.getElementById('camera-video');try{video.pause();video.removeAttribute('src');video.load();}catch(_){}if(camera){try{camera.close();}catch(_){}camera=null;}if(cameraUrl){try{URL.revokeObjectURL(cameraUrl);}catch(_){}cameraUrl=null;}}
 function videoElement(){var current=document.getElementById('camera-video');if(current.tagName==='VIDEO')return current;var video=document.createElement('video');video.id='camera-video';video.muted=true;video.setAttribute('playsinline','');video.setAttribute('aria-label','相机实时画面');current.parentNode.replaceChild(video,current);return video;}
 async function startCamera(){
  await stopCamera();var generation=cameraGeneration;
  function current(){if(generation!==cameraGeneration)throw fail('相机启动已取消');}
  try{
   camera=new W.Media.Capture.MediaCapture();var settings=new W.Media.Capture.MediaCaptureInitializationSettings();settings.streamingCaptureMode=W.Media.Capture.StreamingCaptureMode.video;
   await K.selectProfile(W,settings,log);current();await K.bound(camera.initializeAsync(settings),12000);current();
   var controls=await K.initialize(W,camera.videoDeviceController,log);current();
   var video=videoElement();cameraUrl=URL.createObjectURL(camera,{oneTimeOnly:true});video.src=cameraUrl;await K.bound(Promise.resolve(video.play()),7000);
   var until=Date.now()+7000;while(!video.videoWidth||video.readyState<2){current();if(Date.now()>until)throw fail('相机尚未提供实时画面');await delay(100);}current();cameraPreviewReady=true;lastCameraTime=-1;
   await log('camera_preview_started',{width:video.videoWidth,height:video.videoHeight,source:'raw_pv',controls:controls&&controls.enabled});return true;
  }catch(error){if(generation===cameraGeneration)await stopCamera();throw error;}
 }
 function yoloState(){if(!detector)return null;var value=JSON.parse(detector.getState());if(value.protocol!==1||value.onDevice!==true||value.modelSha256!==config.yoloSha256||(config.yoloInputSize&&value.inputSize!==config.yoloInputSize))throw fail('本地检测组件身份不匹配');latestNative=value;return value;}
 async function yoloStart(){
  if(!root.Rice||!Rice.HoloLens||!Rice.HoloLens.Yolo)throw fail('ARM64 本地检测组件未加载');
  if(detector){var previous=yoloState();if(previous.phase==='running')return previous;if(previous.phase==='loading'||previous.phase==='stopping')throw fail('本地模型仍在切换，请稍候');}
  var generation=++engineGeneration;detector=new Rice.HoloLens.Yolo.Detector();lastCameraTime=-1;
  var folder=W.ApplicationModel.Package.current.installedLocation.path;detector.start(folder+'\\model.onnx',config.yoloSha256,config.yoloDeviceKind||3);
  var deadline=Date.now()+30000;
  while(Date.now()<deadline){if(generation!==engineGeneration)throw fail('本地模型加载已取消');var state=yoloState();if(state.phase==='error')throw fail(state.stage+': '+state.error+' (0x'+Number(state.hr).toString(16)+')');if(state.phase==='running'&&state.modelLoaded){await log('yolo_model_loaded',state);return state;}await delay(100);}
  detector.stop();throw fail('本地模型加载超时，正在释放资源');
 }
 async function yoloStop(){
  engineGeneration++;if(!detector)return null;detector.stop();var deadline=Date.now()+30000;
  while(Date.now()<deadline){var state=yoloState();if((state.phase==='stopped'||state.phase==='error')&&state.workerActive===false){await log('yolo_native_stopped',state);return state;}await delay(100);}
  throw fail('本地推理仍在停止中，未重复启动');
 }
 function submitPixels(image,width,height,time,diagnostic){
  if(!detector)throw fail('本地模型尚未加载');var bytes=new Uint8Array(image.data.buffer,image.data.byteOffset,image.data.byteLength),buffer=W.Security.Cryptography.CryptographicBuffer.createFromByteArray(bytes);
  return detector.submit(buffer,width,height,time,!!diagnostic);
 }
 function submitCamera(){
  var video=document.getElementById('camera-video');if(!cameraPreviewReady||video.readyState<2)return false;
  var clock=Number(video.currentTime)*1000;if(!Number.isFinite(clock)||clock<=lastCameraTime)return false;
  var scale=Math.min(1,1920/video.videoWidth,1080/video.videoHeight),width=Math.round(video.videoWidth*scale),height=Math.round(video.videoHeight*scale);
  if(!canvas)canvas=document.createElement('canvas');if(canvas.width!==width||canvas.height!==height){canvas.width=width;canvas.height=height;}
  var context=canvas.getContext('2d');context.drawImage(video,0,0,width,height);var accepted=submitPixels(context.getImageData(0,0,width,height),width,height,clock,false);if(accepted)lastCameraTime=clock;return accepted;
 }
 async function submitAsset(name){
  if(['bacterial_blight_0.jpg','brown_spot_0.jpg','rice_blast_0.jpg','rice_water_weevil_0.jpg'].indexOf(name)<0)throw fail('验证图像不在允许清单');
  var image=document.getElementById('yolo-asset');await new Promise(function(resolve,reject){image.onload=resolve;image.onerror=function(){reject(fail('内置验证图像读取失败'));};image.src='assets/yolo-samples/'+name;});
  var work=document.createElement('canvas');work.width=image.naturalWidth;work.height=image.naturalHeight;var context=work.getContext('2d');context.drawImage(image,0,0);if(!submitPixels(context.getImageData(0,0,work.width,work.height),work.width,work.height,Date.now(),true))throw fail('本地引擎忙，验证图像没有排队或重发');
  return name;
 }
 async function readCameraCheck(){
  if(!diagnosticSession)return null;var file=await W.ApplicationModel.Package.current.installedLocation.tryGetItemAsync('camera-check.json');if(!file)return null;
  var command;try{command=JSON.parse(await W.Storage.FileIO.readTextAsync(file));}finally{await file.deleteAsync();}
  if(command.session!==diagnosticSession||!/^\w{16,64}$/.test(command.id)||diagnosticIds[command.id]||['dynamic_start','dynamic_stop','dynamic_asset','yolo_state'].indexOf(command.action)<0){await log('camera_check_rejected',{});return null;}
  diagnosticIds[command.id]=true;return command;
 }
 root.RiceNative={init:init,id:id,log:log,nativeMode:nativeMode,version:function(){return config.version;},startCamera:startCamera,stopCamera:stopCamera,yoloStart:yoloStart,yoloStop:yoloStop,yoloState:yoloState,submitCamera:submitCamera,submitAsset:submitAsset,readCameraCheck:readCameraCheck,diagnosticsEnabled:function(){return !!diagnosticSession;},autoStart:function(){return config.autoStart!==false;}};
 if(W)W.UI.WebUI.WebUIApplication.addEventListener('suspending',function(){if(detector)try{detector.stop();}catch(_){}stopCamera();});
}(window));
