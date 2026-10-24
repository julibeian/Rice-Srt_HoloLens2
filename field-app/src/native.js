(function(root){
 'use strict';
 var W=root.Windows, nativeMode=!!W, files={}, config, session=null, device=null, camera=null, stream=null, cameraUrl=null, logQueue=Promise.resolve(), fileQueue=Promise.resolve(), uploadIds={};
 var base='ms-appdata:///local',serviceWork=null,locationWork=null,lastPosition=null,locator=null;
 var cameraControls=null,cameraGeneration=0,captureBusy=false,analysisCanvas=null,Q=root.RiceCaptureQuality,K=root.RiceCameraControls,diagnosticSession=null,diagnosticIds={},previewWork=null,runtimeSession=null,appReady=false,cameraPreviewReady=false;
 function id(){if(W)return W.Security.Cryptography.CryptographicBuffer.encodeToHexString(W.Security.Cryptography.CryptographicBuffer.generateRandom(16));return String(Date.now())+'-'+Math.random().toString(16).slice(2);}
 function fail(message){var e=new Error(message);e.errMsg=message;return e;}
 function success(options,value){if(options.success)options.success(value);if(options.complete)options.complete(value);}
 function failure(options,error){var value={errMsg:error.errMsg||error.message||String(error),status:error.status,code:error.code};if(options.fail)options.fail(value);if(options.complete)options.complete(value);}
 function bufferBytes(buffer){var reader=W.Storage.Streams.DataReader.fromBuffer(buffer),bytes=new Uint8Array(buffer.length);reader.readBytes(bytes);reader.close();return bytes;}
 function ownedName(value){var prefix=base+'/';if(typeof value!=='string'||value.indexOf(prefix)!==0)throw fail('文件不属于本应用');var name=value.slice(prefix.length);if(!/^[A-Za-z0-9_.-]+$/.test(name))throw fail('文件路径无效');return name;}
 async function getFile(value){if(files[value])return files[value];if(value.indexOf('/assets/')===0||value.indexOf('assets/')===0)return W.Storage.StorageFile.getFileFromApplicationUriAsync(new W.Foundation.Uri('ms-appx:///'+value.replace(/^\//,'')));var name=ownedName(value);var f=await W.Storage.ApplicationData.current.localFolder.getFileAsync(name);files[value]=f;return f;}
 async function loadText(name){var f=await W.ApplicationModel.Package.current.installedLocation.getFileAsync(name);return JSON.parse(await W.Storage.FileIO.readTextAsync(f));}
 async function writeLocal(name,text){var file=await W.Storage.ApplicationData.current.localFolder.createFileAsync(name,W.Storage.CreationCollisionOption.replaceExisting);await W.Storage.FileIO.writeTextAsync(file,text);}
 function log(event,details){
  var safe={event:event,at:new Date().toISOString(),session:runtimeSession,details:details||{}};
  if(event==='app_ready')appReady=true;if(event==='boot_failed')appReady=false;
  if(!nativeMode){console.info('[Rice]',safe);return Promise.resolve();}
  var next=logQueue.then(async function(){
   var settings=null,rows=[];
   try{settings=W.Storage.ApplicationData.current.localSettings.values;rows=JSON.parse(settings['rice-diagnostic-events']||'[]');if(!Array.isArray(rows))rows=[];}catch(_){}
   rows.push(safe);rows=rows.slice(-24);
   // LocalSettings limits each value to 8 KiB, including UTF-16 text overhead.
   while(rows.length>1&&JSON.stringify(rows).length>3000)rows.shift();
   await writeLocal('app-state.json',JSON.stringify({phase:event,at:safe.at,version:config&&config.version||null,runtimeSession:runtimeSession,appReady:appReady,cameraPreviewReady:cameraPreviewReady,cameraSession:diagnosticSession,events:rows}));
   if(settings)try{settings['rice-diagnostic-events']=JSON.stringify(rows);}catch(_){}
  });
  // Diagnostics must never reject a camera, startup or upload operation.
  logQueue=next.catch(function(){});return logQueue;
 }
 function client(){var filter=new W.Web.Http.Filters.HttpBaseProtocolFilter();filter.allowAutoRedirect=false;filter.useProxy=false;var c=new W.Web.Http.HttpClient(filter);c.defaultRequestHeaders.tryAppendWithoutValidation('User-Agent','RiceHoloLensField/1.0 (+https://rice-srt.cn)');return c;}
 async function request(endpoint,data,token){
  var c=client(),request=new W.Web.Http.HttpRequestMessage(data==null?W.Web.Http.HttpMethod.get:W.Web.Http.HttpMethod.post,new W.Foundation.Uri(config.apiOrigin+config.apiPrefix+endpoint));
  if(token)request.headers.tryAppendWithoutValidation('Authorization','Bearer '+token);
  if(data!=null)request.content=new W.Web.Http.HttpStringContent(JSON.stringify(data),W.Storage.Streams.UnicodeEncoding.utf8,'application/json');
  var op=c.sendRequestAsync(request),timer=setTimeout(function(){try{op.cancel();}catch(_){}},15000);
  try{var response=await op;var text=await response.content.readAsStringAsync(),result;try{result=JSON.parse(text);}catch(_){throw fail('识别服务响应异常，请稍后重试');}if(response.statusCode<200||response.statusCode>=300){var e=fail(result.message||(result.error||{}).message||'识别服务暂不可用');e.status=response.statusCode;throw e;}return result;}
  finally{clearTimeout(timer);try{request.close();c.close();}catch(_){}}
 }
 async function protectDevice(value){var provider=new W.Security.Cryptography.DataProtection.DataProtectionProvider('LOCAL=user');var input=W.Security.Cryptography.CryptographicBuffer.convertStringToBinary(JSON.stringify(value),W.Security.Cryptography.BinaryStringEncoding.utf8);var protectedBuffer=await provider.protectAsync(input);var f=await W.Storage.ApplicationData.current.localFolder.createFileAsync('connection.dat',W.Storage.CreationCollisionOption.replaceExisting);await W.Storage.FileIO.writeBufferAsync(f,protectedBuffer);}
 async function recoverDevice(){try{var f=await W.Storage.ApplicationData.current.localFolder.getFileAsync('connection.dat'),buffer=await W.Storage.FileIO.readBufferAsync(f),provider=new W.Security.Cryptography.DataProtection.DataProtectionProvider(),clear=await provider.unprotectAsync(buffer);return JSON.parse(W.Security.Cryptography.CryptographicBuffer.convertBinaryToString(W.Security.Cryptography.BinaryStringEncoding.utf8,clear));}catch(_){return null;}}
 async function pair(code){if(!nativeMode)throw fail('请在眼镜上连接识别服务');var value=await request('/register',{pair_code:String(code).trim(),device_label:config.deviceLabel});device={device_id:value.device_id,device_key:value.device_key};await protectDevice(device);session=null;await access();await log('device_paired',{device_id:device.device_id});return true;}
 async function pairFromDeployment(){
  if(!nativeMode||device)return !!device;
  var bootstrap=await W.ApplicationModel.Package.current.installedLocation.tryGetItemAsync('pairing.json');if(!bootstrap)return false;
  var pairing=JSON.parse(await W.Storage.FileIO.readTextAsync(bootstrap));
  if(Number(pairing.expires_epoch)>Date.now()/1000)await pair(pairing.pair_code);
  else await log('pairing_expired',{});
  try{await bootstrap.deleteAsync();}catch(_){await log('pairing_file_cleanup_pending',{paired:!!device});}
  return !!device;
 }
 async function access(){if(session&&session.expires_epoch>Date.now()/1000+60)return session.access_token;if(!device)throw fail('请先在设置中连接识别服务');session=await request('/session',device);return session.access_token;}
 function ensureService(){if(!nativeMode)return Promise.resolve();if(serviceWork)return serviceWork;serviceWork=(async function(){if(!device){device=await recoverDevice();if(!device)await pairFromDeployment();}if(!device)throw fail('设备尚未配对，请连接识别服务');try{return await access();}catch(e){if(e.status===401){session=null;device=null;await pairFromDeployment();if(device)return access();}throw e;}})();serviceWork.then(function(){serviceWork=null;},function(){serviceWork=null;});return serviceWork;}
 async function event(name,details){if(!device)return;try{await request('/events',{event:name,details:details||{}},await access());}catch(_){} }
 async function init(){
  if(!nativeMode){var u=new URL(location.href);if(!/^(127\.0\.0\.1|localhost)$/.test(u.hostname)||u.searchParams.get('preview')!=='1')throw fail('请从眼镜应用列表打开稻视界');config=await (await fetch('config.json')).json();await log('preview_ready',{});return;}
  if(root.RiceBoot&&root.RiceBoot.activationReady){if(root.RiceBoot.trace)root.RiceBoot.trace('waiting_for_activation');await root.RiceBoot.activationReady;if(root.RiceBoot.trace)root.RiceBoot.trace('activation_ready');}
  config=await loadText('config.json');
  if(root.RiceBoot&&root.RiceBoot.trace)root.RiceBoot.trace('config_loaded');
  runtimeSession=id();appReady=false;
  var local=W.Storage.ApplicationData.current.localFolder,items=await local.getFilesAsync();for(var i=0;i<items.length;i++)files[base+'/'+items[i].name]=items[i];
  if(root.RiceBoot&&root.RiceBoot.trace)root.RiceBoot.trace('files_loaded');
  device=await recoverDevice();
  if(root.RiceBoot&&root.RiceBoot.trace)root.RiceBoot.trace('device_recovered');
  // Pairing/network and location run alongside the camera, never before it.
  await log('runtime_ready',{deviceFamily:W.System.Profile.AnalyticsInfo.versionInfo.deviceFamily,paired:!!device});
  if(config.cameraDiagnostics===true){diagnosticSession=id();await log('camera_diagnostic_ready',{session:diagnosticSession,version:config.version});}
 }
 async function stopCamera(){cameraGeneration++;cameraControls=null;cameraPreviewReady=false;var video=document.getElementById('camera-video');try{video.pause();video.srcObject=null;video.removeAttribute('src');video.load();}catch(_){}if(stream){stream.getTracks().forEach(function(t){t.stop();});stream=null;}if(camera){try{camera.close();}catch(_){}camera=null;}if(cameraUrl){try{URL.revokeObjectURL(cameraUrl);}catch(_){}cameraUrl=null;}}
 function cameraActive(generation){if(generation!==cameraGeneration||document.hidden){var error=fail('拍摄已取消，请重新对准');error.code='capture-cancelled';throw error;}}
 function delay(ms){return new Promise(function(resolve){setTimeout(resolve,ms);});}
 function cameraVideo(){var current=document.getElementById('camera-video');if(current.tagName==='VIDEO')return current;var video=document.createElement('video');video.id='camera-video';video.muted=true;video.setAttribute('playsinline','');video.setAttribute('aria-label','相机实时画面');video.onclick=current.onclick;current.parentNode.replaceChild(video,current);return video;}
 async function startCamera(){
  var video=document.getElementById('camera-video');await stopCamera();var generation=cameraGeneration;
  try{
   if(nativeMode){camera=new W.Media.Capture.MediaCapture();var settings=new W.Media.Capture.MediaCaptureInitializationSettings();settings.streamingCaptureMode=W.Media.Capture.StreamingCaptureMode.video;settings.photoCaptureSource=W.Media.Capture.PhotoCaptureSource.auto;await K.selectProfile(W,settings,log);cameraActive(generation);await K.bound(camera.initializeAsync(settings),10000);cameraActive(generation);cameraControls=await K.initialize(W,camera.videoDeviceController,log);cameraActive(generation);video=cameraVideo();cameraUrl=URL.createObjectURL(camera,{oneTimeOnly:true});video.src=cameraUrl;await K.bound(Promise.resolve(video.play()),5000);}
   else{if(!navigator.mediaDevices)throw fail('预览环境不支持相机');stream=await navigator.mediaDevices.getUserMedia({audio:false,video:{facingMode:'environment',width:{ideal:1920},height:{ideal:1080}}});cameraActive(generation);video=cameraVideo();video.srcObject=stream;await video.play();}
   var until=Date.now()+5000;while(!video.videoWidth||!video.videoHeight||video.readyState<2){cameraActive(generation);if(Date.now()>until)throw fail('相机未提供预览画面，请重开相机');await delay(100);}cameraActive(generation);
   cameraPreviewReady=true;await log('camera_preview_started',{width:video.videoWidth,height:video.videoHeight,source:'raw_pv'});return cameraCapabilities();
  }catch(error){if(generation===cameraGeneration)await stopCamera();throw error;}
 }
 async function capturePhoto(options){
  var raw=options&&options.raw,name=(raw?'source_':'capture_')+id()+'.jpg',virtual=base+'/'+name;
  if(nativeMode){if(!camera)throw fail('相机未开启');var imageStream=new W.Storage.Streams.InMemoryRandomAccessStream();try{await K.bound(camera.capturePhotoToStreamAsync(W.Media.MediaProperties.ImageEncodingProperties.createJpeg(),imageStream),12000);if(!imageStream.size||imageStream.size>7*1024*1024)throw fail('照片大小超出限制，请重拍');var reader=new W.Storage.Streams.DataReader(imageStream.getInputStreamAt(0));await reader.loadAsync(imageStream.size);var buffer=reader.readBuffer(imageStream.size);reader.close();var file=await W.Storage.ApplicationData.current.localFolder.createFileAsync(name,W.Storage.CreationCollisionOption.failIfExists);await W.Storage.FileIO.writeBufferAsync(file,buffer);files[virtual]=file;await log(raw?'raw_photo_captured':'photo_captured',{file:name,bytes:buffer.length,source:'raw_pv'});return virtual;}finally{imageStream.close();}}
  var canvas=document.createElement('canvas'),video=document.getElementById('camera-video');canvas.width=video.videoWidth||1280;canvas.height=video.videoHeight||720;canvas.getContext('2d').drawImage(video,0,0);var blob=await new Promise(function(resolve){canvas.toBlob(resolve,'image/jpeg',0.92);});files[virtual]={blob:blob,url:URL.createObjectURL(blob)};return virtual;
 }
 function cameraCapabilities(){return cameraControls?{supported:cameraControls.capabilities,enabled:cameraControls.enabled,photoSize:cameraControls.photoSize}:null;}
 async function readCameraCheck(){if(!diagnosticSession)return null;var file=await W.ApplicationModel.Package.current.installedLocation.tryGetItemAsync('camera-check.json');if(!file)return null;var command;try{command=JSON.parse(await W.Storage.FileIO.readTextAsync(file));}finally{await file.deleteAsync();}if(command.session!==diagnosticSession||!/^\w{16,64}$/.test(command.id)||diagnosticIds[command.id]||['controls','capture'].indexOf(command.action)<0){await log('camera_check_rejected',{});return null;}diagnosticIds[command.id]=true;return command;}
 async function diagnoseCamera(rect){if(!cameraControls)throw fail('原生相机未准备好');await K.target(W,cameraControls,rect,log);var metrics=sampleRegion(rect);var proof=Object.assign({assessment:Q.assess(metrics).reason},Q.summary(metrics));await log('camera_quality_probe',proof);return proof;}
 function sampleRegion(rect){var video=document.getElementById('camera-video');if(!video.videoWidth||video.readyState<2)throw fail('预览尚未准备好，请稍候');var region=Q.pixels(rect,video.videoWidth,video.videoHeight);if(!analysisCanvas){analysisCanvas=document.createElement('canvas');analysisCanvas.width=analysisCanvas.height=256;}var context=analysisCanvas.getContext('2d');context.drawImage(video,region.x,region.y,region.width,region.height,0,0,256,256);return Q.measure(context.getImageData(0,0,256,256));}
 async function loadPhoto(path){var image=new Image();return K.bound(new Promise(function(resolve,reject){image.onload=function(){resolve(image);};image.onerror=function(){reject(fail('原始照片读取失败，请重拍'));};image.src=root.RiceNative.imageUrl(path);}),10000);}
 function jpeg(canvas){if(!canvas.toBlob){var url=canvas.toDataURL('image/jpeg',.95);if(url.indexOf('data:image/jpeg;base64,')!==0)throw fail('当前相机无法生成 JPEG，请重开应用');var value=url.slice(url.indexOf(',')+1);return Promise.resolve({base64:value,size:Math.floor(value.length*3/4)-(value.endsWith('==')?2:value.endsWith('=')?1:0)});}return K.bound(new Promise(function(resolve,reject){canvas.toBlob(function(blob){if(blob&&blob.size>0)resolve(blob);else reject(fail('照片裁剪失败，请重拍'));},'image/jpeg',.95);}),10000);}
 async function adjustExposure(metrics,generation,event){
  var state=cameraControls,decision=Q.exposure(metrics),supported=!!(state&&state.capabilities.compensation),adjusted=false,limit=false;
  if(supported){
   var control=state.controller.exposureCompensationControl,step=Math.max(.333,Number(control.step)||.333),atLimit=function(){return decision.direction<0&&state.ev<=Number(control.min)+.01||decision.direction>0&&state.ev>=Number(control.max)-.01;};
   limit=!!atLimit();
   if(decision.direction&&!limit&&Date.now()-(state.lastExposureAdjustment||0)>=850){
    var previous=state.ev;state.exposureOk=await K.compensation(state,state.ev+decision.direction*step,log);cameraActive(generation);state.lastExposureAdjustment=Date.now();adjusted=Math.abs(state.ev-previous)>.001;limit=!!atLimit();
    if(adjusted){state.lastExposureApplied=Date.now();log(event,{direction:decision.direction,ev:Number(state.ev.toFixed(3)),target_mean:Number(metrics.targetMean.toFixed(3)),target_highlights:Number(metrics.targetHighlights.toFixed(3))});}
   }
  }
  var available=supported&&state.exposureOk!==false,adjusting=!!decision.direction&&available&&!limit,settling=adjusted||!!(state&&state.lastExposureApplied&&Date.now()-state.lastExposureApplied<450);
  var message=!decision.direction?'亮度已稳定，点拍照后放下手':!supported?'相机正在自动测光，请调整目标光线':!available?'曝光调节未完成，请重试或调整光线':limit?(decision.direction<0?'已达到最低曝光，请避开强反光':'已达到最高曝光，请给叶片补一些光'):decision.message;
  return {adjusted:adjusted,adjusting:adjusting,settling:settling,ev:state?state.ev:null,message:message};
 }
 function tunePreview(rect){
  if(captureBusy||!nativeMode||!cameraControls)return Promise.resolve(null);if(previewWork)return previewWork;var generation=cameraGeneration;
  previewWork=(async function(){cameraActive(generation);var key=JSON.stringify(rect);if(cameraControls.targetKey!==key){await K.target(W,cameraControls,rect,log,{continuous:true,preserveExposure:true});cameraActive(generation);cameraControls.targetKey=key;cameraControls.lastExposureAdjustment=Date.now();}
   var metrics=sampleRegion(rect),adjustment=await adjustExposure(metrics,generation,'camera_live_exposure');
   return {adjusted:adjustment.adjusted,adjusting:adjustment.adjusting||adjustment.settling,ev:adjustment.ev,metrics:Q.summary(metrics),assessment:Q.assess(metrics),message:adjustment.message};
  })();previewWork.then(function(){previewWork=null;},function(){previewWork=null;});return previewWork;
 }
 async function captureOptimizedPhoto(rect,progress){
  if(captureBusy)throw fail('正在优化拍摄，请稍候');if(!Q||!K)throw fail('拍摄组件未加载，请重开应用');Q.validate(rect);rect=Object.assign({},rect);var generation=cameraGeneration,original=null,cropped=null;captureBusy=true;progress=progress||function(){};
  try{
   if(previewWork)await previewWork;cameraActive(generation);progress('请放下手，保持目标在框内…');await delay(1000);cameraActive(generation);
   progress('正在对焦和调整亮度…');if(nativeMode){if(!camera||!cameraControls)throw fail('相机尚未开启');await K.target(W,cameraControls,rect,log,{preserveExposure:true});cameraActive(generation);if(cameraControls.capabilities.focus&&cameraControls.enabled.focus===false)throw fail('未能自动对焦，请调整距离后再拍');}await delay(450);cameraActive(generation);
   var deadline=Date.now()+8000,previous=null,stable=0,lastReason=null,lastClock=null,video=document.getElementById('camera-video');
   while(Date.now()<deadline){
    cameraActive(generation);var metrics=sampleRegion(rect),assessment=Q.assess(metrics),adjustment=nativeMode?await adjustExposure(metrics,generation,'camera_capture_exposure'):null,exposurePending=adjustment&&(adjustment.adjusting||adjustment.settling),difference=previous?Q.motion(metrics.signature,previous.signature):Infinity,clock=Number(video.currentTime)||0,fresh=!lastClock||clock!==lastClock;
    if(assessment.ok&&!exposurePending&&difference<.025&&fresh)stable++;else stable=0;
    previous=exposurePending?null:metrics;lastClock=clock;if(stable>=4)break;var message=exposurePending?(adjustment.adjusting?adjustment.message:'等待曝光稳定…'):!assessment.ok?assessment.message:!fresh?'等待相机更新画面…':'请保持稳定，等待画面清晰…';if(message!==lastReason){progress(message);lastReason=message;}await delay(150);
   }
   if(stable<4)throw fail(lastReason||'画面未稳定，请调整后再拍');cameraActive(generation);progress('正在拍摄高清照片…');
   var capturedAt=Date.now();original=await capturePhoto({raw:true});cameraActive(generation);var image=await loadPhoto(original);cameraActive(generation);
   var iw=image.naturalWidth||image.width,ih=image.naturalHeight||image.height;if(Math.abs(iw/ih-video.videoWidth/video.videoHeight)>.02)throw fail('照片与取景比例不一致，请重开相机');
   var crop=Q.pixels(rect,iw,ih);if(Math.min(crop.width,crop.height)<96)throw fail('目标像素不足，请靠近一些再拍');var canvas=document.createElement('canvas'),scale=Math.min(1,2048/Math.max(crop.width,crop.height));canvas.width=Math.round(crop.width*scale);canvas.height=Math.round(crop.height*scale);canvas.getContext('2d').drawImage(image,crop.x,crop.y,crop.width,crop.height,0,0,canvas.width,canvas.height);
   var check=document.createElement('canvas');check.width=check.height=256;var context=check.getContext('2d');context.drawImage(canvas,0,0,256,256);var actual=Q.measure(context.getImageData(0,0,256,256)),verdict=Q.assess(actual);if(!verdict.ok)throw fail(verdict.message+'，本张未上传');progress('正在裁剪目标…');var blob=await jpeg(canvas);cameraActive(generation);var cropName='capture_'+id()+'.jpg';if(blob.base64){cropped=base+'/'+cropName;await writeFile(cropped,blob.base64,'base64');}else cropped=await root.RiceNative.writeBlob(blob,cropName);cameraActive(generation);
   var evidence={roi:rect,sourceWidth:iw,sourceHeight:ih,cropWidth:canvas.width,cropHeight:canvas.height,quality:Q.summary(actual),source:'raw_pv',controls:cameraControls?Object.assign({},cameraControls.enabled):{},exposureEv:cameraControls?cameraControls.ev:null};
   await log('photo_captured',{file:ownedName(cropped),original_file:ownedName(original),bytes:blob.size,source:'optimized_pv',width:canvas.width,height:canvas.height,sharpness:evidence.quality.sharpness});cameraActive(generation);return {path:cropped,originalPath:original,selectedAt:capturedAt,capture:evidence};
  }catch(error){if(cropped)unlink(cropped);if(original)unlink(original);log('capture_quality_rejected',{message:String(error.message||error).slice(0,160)});throw error;}finally{captureBusy=false;if(cameraControls)cameraControls.targetKey=null;}
 }
 async function captureSystemPhoto(){
  if(!nativeMode)return capturePhoto();
  // Release our MediaCapture before giving the PV camera to the shell.
  await stopCamera();
  var C=W.Media.Capture,ui=new C.CameraCaptureUI();
  ui.photoSettings.allowCropping=false;ui.photoSettings.format=C.CameraCaptureUIPhotoFormat.jpeg;
  ui.photoSettings.maxResolution=C.CameraCaptureUIMaxPhotoResolution.large3M;
  log('system_camera_opened',{});
  var selected=await ui.captureFileAsync(C.CameraCaptureUIMode.photo);
  if(!selected){log('system_camera_cancelled',{});return null;}
  var properties=await selected.getBasicPropertiesAsync();
  if(!properties.size||properties.size>7*1024*1024)throw fail('系统照片大小超出限制，请重新拍摄');
  var name='capture_'+id()+'.jpg',copied=await selected.copyAsync(W.Storage.ApplicationData.current.localFolder,name,W.Storage.NameCollisionOption.failIfExists),virtual=base+'/'+name;
  files[virtual]=copied;log('photo_captured',{file:name,bytes:Number(properties.size),source:'system_camera'});return virtual;
 }
 function networkState(){if(!nativeMode)return navigator.onLine===false?'offline':'internet';return 'unknown';}
 function onNetworkChange(callback){
  if(nativeMode)log('network_monitor_fallback',{strategy:'online-offline-and-service-poll',reason:'holographic-session-rejects-nlm-events'});
  // Some HoloLens user sessions reject NLM event registration. This optional
  // monitor must not stop application startup or disable upload recovery.
  root.addEventListener('online',callback);root.addEventListener('offline',callback);
  var previous=networkState(),timer=nativeMode?root.setInterval(function(){if(document.hidden)return;var current=networkState();if(current!==previous||current==='unknown'){previous=current;callback();}},15000):null;
  var stop=function(){root.removeEventListener('online',callback);root.removeEventListener('offline',callback);if(timer!=null)root.clearInterval(timer);};root.addEventListener('beforeunload',stop);return stop;
 }
 function pendingCapture(){
  try{var pending=JSON.parse(localStorage.getItem('rice_pending_upload')||'null');if(pending&&files[pending.path])return pending;}catch(_){}
  if(!nativeMode)return null;
  try{var rows=JSON.parse(W.Storage.ApplicationData.current.localSettings.values['rice-diagnostic-events']||'[]');for(var i=rows.length-1;i>=0;i--){if(rows[i].event==='prediction_received'||rows[i].event==='history_saved')return null;if(rows[i].event==='photo_captured'){var name=rows[i].details.file,path=base+'/'+name,original=rows[i].details.original_file,originalPath=original&&/^source_[a-zA-Z0-9_-]+\.jpg$/.test(original)&&files[base+'/'+original]?base+'/'+original:null;if(/^capture_[a-zA-Z0-9_-]+\.jpg$/.test(name)&&files[path])return {id:id(),path:path,originalPath:originalPath,origin:'camera',selectedAt:Date.parse(rows[i].at)};return null;}}}catch(_){}return null;
 }
 async function chooseImages(options){
  if(options.sourceType&&options.sourceType[0]==='camera')return [await capturePhoto()];
  if(nativeMode){var picker=new W.Storage.Pickers.FileOpenPicker();picker.viewMode=W.Storage.Pickers.PickerViewMode.thumbnail;picker.suggestedStartLocation=W.Storage.Pickers.PickerLocationId.picturesLibrary;['.jpg','.jpeg','.png','.webp'].forEach(function(ext){picker.fileTypeFilter.append(ext);});var selected=await picker.pickMultipleFilesAsync();if(!selected||!selected.length)throw fail('chooseImage:fail cancel');var paths=[];for(var i=0;i<Math.min(options.count||6,selected.length);i++){var name='import_'+id()+selected[i].fileType.toLowerCase(),f=await selected[i].copyAsync(W.Storage.ApplicationData.current.localFolder,name,W.Storage.NameCollisionOption.failIfExists);files[base+'/'+name]=f;paths.push(base+'/'+name);}return paths;}
  return new Promise(function(resolve,reject){var input=document.createElement('input');input.type='file';input.accept='image/jpeg,image/png,image/webp';input.multiple=true;input.onchange=function(){var paths=[];Array.prototype.slice.call(input.files,0,options.count||6).forEach(function(file){var p=base+'/import_'+id()+'.'+(file.name.split('.').pop()||'jpg');files[p]={blob:file,url:URL.createObjectURL(file)};paths.push(p);});if(paths.length)resolve(paths);else reject(fail('chooseImage:fail cancel'));};input.addEventListener('cancel',function(){reject(fail('chooseImage:fail cancel'));});input.click();});
 }
 async function readFile(value,position,length){if(!nativeMode){var f=files[value];if(!f){var r=await fetch(value.replace(/^\//,''));return r.arrayBuffer();}var bytes=await f.blob.arrayBuffer();return bytes.slice(position||0,length?((position||0)+length):undefined);}var buffer=await W.Storage.FileIO.readBufferAsync(await getFile(value)),array=bufferBytes(buffer);return array.buffer.slice(position||0,length?((position||0)+length):undefined);}
 async function writeFile(value,data,encoding){
  var name=ownedName(value);if(!nativeMode){var blob=encoding==='base64'?new Blob([Uint8Array.from(atob(data),function(c){return c.charCodeAt(0);})]):new Blob([data]);files[value]={blob:blob,url:URL.createObjectURL(blob)};return;}
  var buffer=encoding==='base64'?W.Security.Cryptography.CryptographicBuffer.decodeFromBase64String(data):W.Security.Cryptography.CryptographicBuffer.createFromByteArray(new Uint8Array(data));var f=await W.Storage.ApplicationData.current.localFolder.createFileAsync(name,W.Storage.CreationCollisionOption.replaceExisting);await W.Storage.FileIO.writeBufferAsync(f,buffer);files[value]=f;
 }
 async function copyFile(from,to){var name=ownedName(to);if(nativeMode)files[to]=await (await getFile(from)).copyAsync(W.Storage.ApplicationData.current.localFolder,name,W.Storage.NameCollisionOption.replaceExisting);else{if(!files[from]){var blob=await (await fetch(from.replace(/^\//,''))).blob();files[to]={blob:blob,url:URL.createObjectURL(blob)};}else files[to]=files[from];}}
 function unlink(value){ownedName(value);var f=files[value];delete files[value];if(nativeMode&&f){var next=fileQueue.then(function(){return f.deleteAsync();});fileQueue=next.catch(function(e){log('file_cleanup_error',{message:e.message});});}else if(f&&f.url)try{URL.revokeObjectURL(f.url);}catch(_){} }
 async function fileSize(value){if(nativeMode)return Number((await (await getFile(value)).getBasicPropertiesAsync()).size);return files[value]?files[value].blob.size:(await readFile(value)).byteLength;}
 function fileSystem(){return {
  readFile:function(o){readFile(o.filePath,o.position,o.length).then(function(data){if(o.encoding==='base64'){var a=new Uint8Array(data),s='';for(var i=0;i<a.length;i++)s+=String.fromCharCode(a[i]);data=btoa(s);}success(o,{data:data});},function(e){failure(o,e);});},
  writeFile:function(o){writeFile(o.filePath,o.data,o.encoding).then(function(){success(o,{});},function(e){failure(o,e);});},
  copyFile:function(o){copyFile(o.srcPath,o.destPath).then(function(){success(o,{});},function(e){failure(o,e);});},
  getFileInfo:function(o){fileSize(o.filePath).then(function(n){success(o,{size:n});},function(e){failure(o,e);});},
  unlinkSync:unlink,readdirSync:function(){return Object.keys(files).filter(function(p){return p.indexOf(base+'/')===0;}).map(function(p){return p.slice(base.length+1);});}
 };}
 function upload(options){var current=null,aborted=false;var work=(async function(){
  if(!nativeMode){if(!root.RicePreviewUpload)throw fail('界面预览未连接真机识别');return root.RicePreviewUpload(options,files[options.filePath]);}
  var token=await ensureService();if(aborted)throw fail('上传已取消');var f=await getFile(options.filePath),buffer=await W.Storage.FileIO.readBufferAsync(f);if(!buffer.length||buffer.length>7*1024*1024)throw fail('照片超过上传大小限制');
  var hash=W.Security.Cryptography.CryptographicBuffer.encodeToHexString(W.Security.Cryptography.Core.HashAlgorithmProvider.openAlgorithm('SHA256').hashData(buffer)).toLowerCase(),requestId=options.requestId||uploadIds[options.filePath]||(uploadIds[options.filePath]='field-'+id());
  if(!/^[A-Za-z0-9._-]{1,80}$/.test(requestId))throw fail('本次照片编号无效');
  for(var attempt=0;attempt<2;attempt++){
  if(aborted)throw fail('上传已取消');if(attempt)token=await access();
  var content=new W.Web.Http.HttpMultipartFormDataContent(),image=new W.Web.Http.HttpBufferContent(buffer);image.headers.contentType=new W.Web.Http.Headers.HttpMediaTypeHeaderValue(f.fileType.toLowerCase()==='.png'?'image/png':f.fileType.toLowerCase()==='.webp'?'image/webp':'image/jpeg');content.add(image,'file',f.name);
  var c=client(),message=new W.Web.Http.HttpRequestMessage(W.Web.Http.HttpMethod.post,new W.Foundation.Uri(config.apiOrigin+config.apiPrefix+'/predict'));message.headers.tryAppendWithoutValidation('Authorization','Bearer '+token);message.headers.tryAppendWithoutValidation('X-Request-ID',requestId);message.headers.tryAppendWithoutValidation('X-Image-SHA256',hash);message.content=content;
  current=c.sendRequestAsync(message);var timer=setTimeout(function(){if(current)try{current.cancel();}catch(_){}},45000);
  await log('upload_started',{request_id:requestId,image_sha256:hash,bytes:buffer.length});
  try{var response=await current,text=await response.content.readAsStringAsync(),value;try{value=JSON.parse(text);}catch(_){throw fail('服务器返回了无法读取的结果');}if(response.statusCode===401&&attempt===0){session=null;continue;}if(response.statusCode!==200){var error=fail(value.message||(value.error||{}).message||'识别服务暂不可用');error.status=response.statusCode;error.code=value.error;if(response.statusCode===401)session=null;throw error;}var evidence=value.capture_evidence||{};if(evidence.request_id!==requestId||evidence.image_sha256!==hash||evidence.channel!=='hololens-app')throw fail('照片与识别结果不匹配，请重试');log('prediction_received',{request_id:requestId,image_sha256:hash,prediction_id:evidence.prediction_id,is_valid:value.is_valid,predicted_class:value.predicted_class});return {statusCode:response.statusCode,data:text};}
  finally{clearTimeout(timer);current=null;try{message.close();c.close();}catch(_){}}
  }
 })();work.then(function(result){success(options,result);},function(e){log('upload_error',{message:e.message});failure(options,e);});return {abort:function(){aborted=true;if(current)try{current.cancel();}catch(_){}}};}
 function getLocation(){
  if(lastPosition&&Date.now()-lastPosition.acquiredAt<15000)return Promise.resolve(lastPosition);
  if(locationWork)return locationWork;
  locationWork=(async function(){
   if(!nativeMode)return new Promise(function(resolve,reject){if(!navigator.geolocation){reject(fail('此环境不能提供设备位置'));return;}navigator.geolocation.getCurrentPosition(function(p){lastPosition={latitude:p.coords.latitude,longitude:p.coords.longitude,accuracy:p.coords.accuracy,acquiredAt:p.timestamp||Date.now(),source:'system'};resolve(lastPosition);},function(e){var error=fail(e.code===1?'位置权限未允许，请在位置设置中允许稻视界使用位置':e.code===3?'定位超时，系统暂未取得 Wi-Fi 位置':'系统暂未提供位置，请检查 Wi-Fi 和位置服务');error.code=e.code===1?'permission-denied':e.code===3?'timeout':'no-data';reject(error);},{timeout:20000,maximumAge:15000,enableHighAccuracy:false});});
   var G=W.Devices.Geolocation,permission=await G.Geolocator.requestAccessAsync();
   if(permission!==G.GeolocationAccessStatus.allowed){var denied=fail('位置权限未允许，请在位置设置中允许稻视界使用位置');denied.code='permission-denied';log('location_error',{code:denied.code,access:permission});throw denied;}
   if(!locator){locator=new G.Geolocator();locator.desiredAccuracy=G.PositionAccuracy.default;}
   if(locator.locationStatus===G.PositionStatus.disabled){var disabled=fail('系统位置服务已关闭，请在位置设置中开启');disabled.code='disabled';throw disabled;}
   var op=locator.getGeopositionAsync(15000,20000),timedOut=false,timer=setTimeout(function(){timedOut=true;try{op.cancel();}catch(_){}},22000);
   try{var result=await op,coordinate=result.coordinate,position=coordinate.point.position;if(!Number.isFinite(position.latitude)||!Number.isFinite(position.longitude)||Math.abs(position.latitude)>90||Math.abs(position.longitude)>180)throw fail('系统返回的位置无效');var acquiredAt=coordinate.timestamp?new Date(coordinate.timestamp).getTime():Date.now();if(!Number.isFinite(acquiredAt)||Date.now()-acquiredAt>60000)throw fail('系统位置已过期，请重新定位');lastPosition={latitude:position.latitude,longitude:position.longitude,accuracy:coordinate.accuracy,acquiredAt:acquiredAt,source:coordinate.positionSource};log('location_received',{accuracy:coordinate.accuracy,source:coordinate.positionSource});return lastPosition;}
   catch(e){var code=timedOut||e.number===-2147023436?'timeout':locator.locationStatus===G.PositionStatus.disabled?'disabled':'no-data';var error=fail(code==='timeout'?'定位超时，系统暂未取得 Wi-Fi 位置':code==='disabled'?'系统位置服务已关闭':'系统暂未提供位置，请检查 Wi-Fi 和位置权限');error.code=code;log('location_error',{code:code,status:locator.locationStatus,number:e.number||0});throw error;}finally{clearTimeout(timer);}
  })();locationWork.then(function(){locationWork=null;},function(){locationWork=null;});return locationWork;
 }
 async function locationPermission(){if(!nativeMode)return undefined;try{var locator=new W.Devices.Geolocation.Geolocator(),status=locator.locationStatus;return status===W.Devices.Geolocation.PositionStatus.disabled?false:undefined;}catch(_){return undefined;}}
 async function openSettings(){if(nativeMode){var ok=await W.System.Launcher.launchUriAsync(new W.Foundation.Uri('ms-settings:privacy-location'));if(!ok)throw fail('请在眼镜“设置 → 隐私 → 位置”中调整授权');}else throw fail('请在浏览器的网站权限中调整位置权限');}
 async function saveReport(value){if(!nativeMode){var f=files[value],a=document.createElement('a');a.href=f.url;a.download='稻视界报告-'+Date.now()+'.png';a.click();return;}var file=await getFile(value),folder=await W.Storage.KnownFolders.picturesLibrary.createFolderAsync('稻视界报告',W.Storage.CreationCollisionOption.openIfExists);await file.copyAsync(folder,'稻视界报告-'+Date.now()+'.png',W.Storage.NameCollisionOption.generateUniqueName);await log('report_exported',{});}
 root.RiceNative={init:init,id:id,log:log,event:event,pair:pair,pairFromDeployment:pairFromDeployment,ensureService:ensureService,isPaired:function(){return !!device;},version:function(){return config?config.version:'1.0.0.0';},nativeMode:nativeMode,userPath:base,chooseImages:chooseImages,startCamera:startCamera,stopCamera:stopCamera,capturePhoto:capturePhoto,captureOptimizedPhoto:captureOptimizedPhoto,cameraCapabilities:cameraCapabilities,resumeCamera:function(){return Promise.resolve(document.getElementById('camera-video').play());},captureSystemPhoto:captureSystemPhoto,networkState:networkState,onNetworkChange:onNetworkChange,readFile:readFile,writeFile:writeFile,copyFile:copyFile,unlink:unlink,fileSystem:fileSystem,upload:upload,getLocation:getLocation,locationPermission:locationPermission,openSettings:openSettings,saveReport:saveReport,
  diagnosticsEnabled:function(){return !!diagnosticSession;},readCameraCheck:readCameraCheck,diagnoseCamera:diagnoseCamera,tunePreview:tunePreview,
  imageUrl:function(value){if(value.indexOf('/assets/')===0)return value.slice(1);if(!nativeMode&&files[value])return files[value].url;return value;},
  writeBlob:async function(blob,name){var bytes=await new Promise(function(resolve,reject){var reader=new FileReader();reader.onload=function(){resolve(reader.result);};reader.onerror=function(){reject(fail('无法读取图片'));};reader.readAsArrayBuffer(blob);}),p=base+'/'+name;await writeFile(p,bytes);return p;},
  waitForFileWrites:function(){return fileQueue;},pendingCapture:pendingCapture
 };
 if(W){W.UI.WebUI.WebUIApplication.addEventListener('suspending',function(){stopCamera();});document.addEventListener('visibilitychange',function(){if(document.hidden)stopCamera();});}
}(window));
