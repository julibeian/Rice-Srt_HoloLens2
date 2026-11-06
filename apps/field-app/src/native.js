/* HoloLens local camera and native YOLO bridge. No recognition HTTP client. */
(function(root){
 'use strict';
 var W=root.Windows,K=root.RiceCameraControls,nativeMode=!!W,config={},runtimeSession=null,diagnosticSession=null,diagnosticIds={},camera=null,cameraUrl=null,cameraGeneration=0,cameraPreviewReady=false,appReady=false,detector=null,canvas=null,lastCameraTime=-1,logQueue=Promise.resolve(),rows=[],latestNative=null,engineGeneration=0,captureRequest=null,cameraMetrics=null,previewRestoreTimer=null;
 function id(){return nativeMode?W.Security.Cryptography.CryptographicBuffer.encodeToHexString(W.Security.Cryptography.CryptographicBuffer.generateRandom(16)):String(Date.now());}
 function fail(message){return new Error(message);}
 function delay(ms){return new Promise(function(resolve){setTimeout(resolve,ms);});}
 async function write(name,value){var file=await W.Storage.ApplicationData.current.localFolder.createFileAsync(name+'.pending',W.Storage.CreationCollisionOption.replaceExisting);await W.Storage.FileIO.writeTextAsync(file,JSON.stringify(value));await file.renameAsync(name,W.Storage.NameCollisionOption.replaceExisting);}
 function log(event,details){
  var row={event:event,at:new Date().toISOString(),session:runtimeSession,details:details||{}};
  if(event==='app_ready')appReady=true;if(event==='boot_failed')appReady=false;
  if(!nativeMode){console.info('[Rice]',row);return Promise.resolve();}
  logQueue=logQueue.then(async function(){rows.push(row);rows=rows.slice(-24);while(rows.length>1&&JSON.stringify(rows).length>6500)rows.shift();await write('app-state.json',{phase:event,at:row.at,version:config.version,runtimeSession:runtimeSession,appReady:appReady,cameraPreviewReady:cameraPreviewReady,cameraSession:diagnosticSession,cameraTelemetry:(diagnosticSession||config.resourceTelemetry)?cameraTelemetry():null,nativeDetector:latestNative,events:rows});}).catch(function(){});return logQueue;
 }
 async function init(){
  if(!nativeMode)throw fail('请在 HoloLens 应用内运行本地检测');
  if(root.RiceBoot&&root.RiceBoot.activationReady)await root.RiceBoot.activationReady;
  var file=await W.ApplicationModel.Package.current.installedLocation.getFileAsync('config.json');config=JSON.parse(await W.Storage.FileIO.readTextAsync(file));
  if(config.recognitionMode!=='local-yolo')throw fail('本版本仅支持眼镜内 YOLO 检测');
  runtimeSession=id();if(config.cameraDiagnostics===true)diagnosticSession=id();
  if(config.resourceTelemetry===true)captureRequest=K.validateCapture(config.cameraCaptureRequest||null);
  await log('runtime_ready',{deviceFamily:W.System.Profile.AnalyticsInfo.versionInfo.deviceFamily,recognition:'local-yolo',networkRequired:false});
 }
 async function stopCamera(){cameraGeneration++;cameraPreviewReady=false;restorePreview();var video=document.getElementById('camera-video');try{video.pause();video.removeAttribute('src');video.load();}catch(_){}if(camera){try{camera.close();}catch(_){}camera=null;}if(cameraUrl){try{URL.revokeObjectURL(cameraUrl);}catch(_){}cameraUrl=null;}}
 function videoElement(){var current=document.getElementById('camera-video');if(current.tagName==='VIDEO')return current;var video=document.createElement('video');video.id='camera-video';video.muted=true;video.setAttribute('playsinline','');video.setAttribute('aria-label','相机实时画面');current.parentNode.replaceChild(video,current);return video;}
 async function startCamera(){
  await stopCamera();var generation=cameraGeneration;
  function current(){if(generation!==cameraGeneration)throw fail('相机启动已取消');}
  try{
   camera=new W.Media.Capture.MediaCapture();var settings=new W.Media.Capture.MediaCaptureInitializationSettings();settings.streamingCaptureMode=W.Media.Capture.StreamingCaptureMode.video;
   var selection=await K.selectProfile(W,settings,log,captureRequest);current();await K.bound(camera.initializeAsync(settings),12000);current();
   var controls=await K.initialize(W,camera.videoDeviceController,log);current();
   var video=videoElement();cameraUrl=URL.createObjectURL(camera,{oneTimeOnly:true});video.src=cameraUrl;await K.bound(Promise.resolve(video.play()),7000);
   var until=Date.now()+7000;while(!video.videoWidth||video.readyState<2){current();if(Date.now()>until)throw fail('相机尚未提供实时画面');await delay(100);}current();cameraPreviewReady=true;lastCameraTime=-1;
   var actual=null;try{if(K.readPreview)actual=K.readPreview(W,camera.videoDeviceController);}catch(error){if(captureRequest)throw error;}
   if(captureRequest&&(!actual||actual.width!==captureRequest.width||actual.height!==captureRequest.height||Math.abs(actual.fps-captureRequest.fps)>.001||video.videoWidth!==captureRequest.width||video.videoHeight!==captureRequest.height))throw fail('相机实际参数与实验请求不一致');
   cameraMetrics={generation:generation,requested:captureRequest,selected:selection&&selection.selected||null,actual:actual,key:actual&&actual.key||null,startedAt:new Date().toISOString(),acceptedSubmissions:0,lastReadPixelsMs:0,lastSubmitMs:0};
   if(diagnosticSession||config.resourceTelemetry)await write('camera-capabilities.json',{runtimeSession:runtimeSession,at:new Date().toISOString(),profiles:selection,actualPreview:actual});
   await log('camera_preview_started',{width:video.videoWidth,height:video.videoHeight,source:'raw_pv',controls:controls&&controls.enabled,actual:actual});return true;
  }catch(error){if(generation===cameraGeneration)await stopCamera();throw error;}
 }
 function cameraTelemetry(){
  if(!cameraMetrics)return null;var video=document.getElementById('camera-video'),counter=null,method='unavailable',dropped=null,corrupted=null;
  try{if(typeof video.getVideoPlaybackQuality==='function'){var quality=video.getVideoPlaybackQuality();if(Number.isFinite(quality.totalVideoFrames)){counter=quality.totalVideoFrames;dropped=quality.droppedVideoFrames;corrupted=quality.corruptedVideoFrames;method='getVideoPlaybackQuality.totalVideoFrames';}}else if(Number.isFinite(video.webkitDecodedFrameCount)){counter=video.webkitDecodedFrameCount;dropped=video.webkitDroppedFrameCount;method='webkitDecodedFrameCount';}}catch(_){}
  var overlay=document.getElementById('dynamic-overlay'),bounds=typeof video.getBoundingClientRect==='function'?video.getBoundingClientRect():null;
  return Object.assign({},cameraMetrics,{videoWidth:video.videoWidth,videoHeight:video.videoHeight,mediaTimeMs:Number(video.currentTime)*1000,decodedFrames:counter,droppedFrames:dropped,corruptedFrames:corrupted,frameCounterMethod:method,previewReady:cameraPreviewReady,previewMode:video.style&&video.style.visibility==='hidden'?'masked':'visible',viewportWidth:Number(root.innerWidth)||null,viewportHeight:Number(root.innerHeight)||null,devicePixelRatio:Number(root.devicePixelRatio)||null,previewCssWidth:bounds?bounds.width:null,previewCssHeight:bounds?bounds.height:null,overlayPixelWidth:Number(overlay.width)||null,overlayPixelHeight:Number(overlay.height)||null});
 }
 function setPreviewMode(mode){
  if(!diagnosticSession)throw fail('预览负载对照只允许在诊断包中执行');
  if(!cameraPreviewReady||['visible','masked'].indexOf(mode)<0)throw fail('无效的预览负载对照');
  // Leave capture, layout, video playback and inference scheduling intact.
  // The experiment is valid only if new PV timestamps AND pixel signatures advance.
  restorePreview();if(mode==='masked'){document.getElementById('camera-video').style.visibility='hidden';previewRestoreTimer=setTimeout(function(){restorePreview();log('performance_preview_restored',{reason:'120_second_limit'});},120000);}
 }
 function restorePreview(){if(previewRestoreTimer!==null){clearTimeout(previewRestoreTimer);previewRestoreTimer=null;document.getElementById('camera-video').style.visibility='';}}
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
  var measured=!!(cameraMetrics&&(diagnosticSession||config.resourceTelemetry)),started=measured?Date.now():0,context=canvas.getContext('2d');context.drawImage(video,0,0,width,height);var image=context.getImageData(0,0,width,height),readFinished=measured?Date.now():0;var accepted=submitPixels(image,width,height,clock,false);if(accepted)lastCameraTime=clock;
  if(measured){cameraMetrics.lastReadPixelsMs=readFinished-started;cameraMetrics.lastSubmitMs=Date.now()-readFinished;cameraMetrics.submittedWidth=width;cameraMetrics.submittedHeight=height;if(accepted)cameraMetrics.acceptedSubmissions++;}return accepted;
 }
 async function submitAsset(name){
  if(['bacterial_blight_0.jpg','brown_spot_0.jpg','rice_blast_0.jpg','rice_water_weevil_0.jpg'].indexOf(name)<0)throw fail('验证图像不在允许清单');
  var image=document.getElementById('yolo-asset');await new Promise(function(resolve,reject){image.onload=resolve;image.onerror=function(){reject(fail('内置验证图像读取失败'));};image.src='assets/yolo-samples/'+name;});
  var work=document.createElement('canvas');work.width=image.naturalWidth;work.height=image.naturalHeight;var context=work.getContext('2d');context.drawImage(image,0,0);if(!submitPixels(context.getImageData(0,0,work.width,work.height),work.width,work.height,Date.now(),true))throw fail('本地引擎忙，验证图像没有排队或重发');
  return name;
 }
 async function readCameraCheck(){
  if(!diagnosticSession)return null;var file=await W.ApplicationModel.Package.current.installedLocation.tryGetItemAsync('camera-check.json');if(!file)return null;
  // The SDK publishes this file while copying it. A locked/partial read must
  // leave it available for the next poll, before any command can be consumed.
  var command=JSON.parse(await W.Storage.FileIO.readTextAsync(file));await file.deleteAsync();
  if(command.session!==diagnosticSession||!/^\w{16,64}$/.test(command.id)||diagnosticIds[command.id]||['dynamic_start','dynamic_stop','dynamic_asset','yolo_state','performance_preview'].indexOf(command.action)<0){await log('camera_check_rejected',{});return null;}
  diagnosticIds[command.id]=true;return command;
 }
 root.RiceNative={init:init,id:id,log:log,nativeMode:nativeMode,version:function(){return config.version;},startCamera:startCamera,stopCamera:stopCamera,cameraTelemetry:cameraTelemetry,setPreviewMode:setPreviewMode,restorePreview:restorePreview,yoloStart:yoloStart,yoloStop:yoloStop,yoloState:yoloState,submitCamera:submitCamera,submitAsset:submitAsset,readCameraCheck:readCameraCheck,diagnosticsEnabled:function(){return !!diagnosticSession;},telemetryEnabled:function(){return config.resourceTelemetry===true;},autoStart:function(){return config.autoStart!==false;}};
 if(W)W.UI.WebUI.WebUIApplication.addEventListener('suspending',function(){if(detector)try{detector.stop();}catch(_){}stopCamera();});
}(window));
