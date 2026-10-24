(function(root){
 'use strict';
 var N=root.RiceNative,store=root.RiceRequire('utils/history-store'),locations=root.RiceRequire('utils/location'),locationService=root.RiceRequire('utils/location-service');
 var state={view:'camera',busy:false,capturing:false,cameraReady:false,result:null,lastJob:null,location:null,locating:false,historyPage:0,detailPage:0,details:false,recordId:null,editingLocation:false,targetPoint:{x:.5,y:.46},targetSize:1,showingOriginal:false};
 var Q=root.RiceCaptureQuality,targetSizes=[.4,.6,.85];
 var cameraWork=null,connectionWork=null,connectionTimer=null,map=null,mapLayer=null,mapMarkers=null,deviceMarker=null,accuracyCircle=null,satellite=false,historyRows=[],saveQueue=Promise.resolve(),diagnosticTimer=null,diagnosticWork=false,previewTimer=null,captureErrorUntil=0;
 function el(id){return document.getElementById(id);}
 function text(id,value){el(id).textContent=value||'';}
 function toast(message){wx.showToast({title:message});}
 function errorText(error){var message=error.errMsg||error.message||String(error);if(/name or address could not be resolved|0x80072ee7|12007/i.test(message))return '眼镜网络无法解析识别服务地址，请连接 Wi-Fi；恢复后自动重传';if(/canceled|cancelled/i.test(message))return '网络请求中断，恢复连接后自动重传';return message;}
 function time(value){var d=new Date(value);return d.getFullYear()+'-'+('0'+(d.getMonth()+1)).slice(-2)+'-'+('0'+d.getDate()).slice(-2)+' '+('0'+d.getHours()).slice(-2)+':'+('0'+d.getMinutes()).slice(-2);}
 function controls(){el('camera-shutter').disabled=!state.cameraReady||state.busy||state.capturing;el('album-button').disabled=state.busy||state.capturing;el('camera-region-size').disabled=state.busy||state.capturing;el('camera-cancel').hidden=!state.capturing||state.busy;el('upload-retry').disabled=state.busy;text('camera-shutter',state.busy?'识别中…':state.capturing?'优化拍摄中…':'拍照');}
 function cameraMessage(message){text('camera-message',message);}
 function targetRegion(){var video=el('camera-video');return Q.region(video.videoWidth||1920,video.videoHeight||1080,state.targetPoint,targetSizes[state.targetSize]);}
 function drawTarget(){var frame=el('camera-target'),video=el('camera-video'),box=video.getBoundingClientRect();if(!state.cameraReady||!box.width||!box.height){frame.hidden=true;return;}var fit=Q.fit(video.videoWidth||1920,video.videoHeight||1080,box.width,box.height),rect=targetRegion();frame.style.left=(fit.x+rect.x*fit.width)+'px';frame.style.top=(fit.y+rect.y*fit.height)+'px';frame.style.width=(rect.width*fit.width)+'px';frame.style.height=(rect.height*fit.height)+'px';frame.hidden=false;}
 function view(name){
  state.view=name;document.querySelector('.work-area').setAttribute('data-view',name);
  el('app').classList.toggle('camera-full',name==='camera');el('app').classList.toggle('photo-full',name==='result');el('app').classList.remove('menu-open');el('menu-toggle').hidden=name!=='camera'&&name!=='result';text('menu-toggle','功能');
  ['camera','map','history','settings'].forEach(function(key){el('view-'+key).hidden=key!==name;});
  Array.prototype.forEach.call(document.querySelectorAll('[data-view].rail-button'),function(button){var active=button.getAttribute('data-view')===name;button.className='rail-button'+(active?' active':'');button.setAttribute('aria-pressed',String(active));});
  if(name==='camera')openCamera();if(name==='map')openMap();if(name==='history')renderHistory();
  if(name!=='camera'&&name!=='result'){state.cameraReady=false;N.stopCamera();controls();}
  el('next-photo').hidden=name!=='result';N.log('view_opened',{view:name});
 }
 function openCamera(){
  if(state.cameraReady){N.resumeCamera().catch(function(){state.cameraReady=false;openCamera();});drawTarget();return;}
  if(cameraWork||document.hidden)return cameraWork;
  cameraMessage('正在开启相机…');el('camera-retry').hidden=true;
  cameraWork=N.startCamera().then(function(capabilities){state.cameraReady=true;drawTarget();cameraMessage('把目标放进框内，点拍照后放下手；点画面可移动框');if(capabilities){var c=capabilities.supported;text('camera-capabilities',(c.focus?'自动对焦可用':'对焦由设备默认控制')+' · '+(c.regionExposure?'目标测光可用':c.exposure?'自动曝光可用':'曝光由设备默认控制')+(capabilities.photoSize?' · '+capabilities.photoSize.width+'×'+capabilities.photoSize.height:'')+' · 稳定检测与框内裁剪');}},function(error){state.cameraReady=false;cameraMessage('相机未能开启：'+errorText(error));el('camera-retry').hidden=false;N.log('camera_error',{message:errorText(error)});}).then(function(){cameraWork=null;controls();});return cameraWork;
 }
 function connectionStatus(connected,message){text('service-indicator',connected?'服务已连接':'服务未连接');el('service-indicator').setAttribute('data-connected',String(connected));text('connection-status',message);}
 function connect(){
  if(connectionWork)return connectionWork;
  text('connection-status','正在连接识别服务…');
  connectionWork=N.ensureService().then(function(){connectionStatus(true,N.nativeMode?'识别服务已连接':'界面预览：相机与识别需在眼镜上验证');if(N.isPaired()&&connectionTimer){clearInterval(connectionTimer);connectionTimer=null;}N.log('service_ready',{paired:N.isPaired()});return true;},function(error){connectionStatus(false,errorText(error));N.log('service_error',{message:errorText(error)});return false;}).then(function(value){connectionWork=null;return value;});return connectionWork;
 }
 async function pair(){
  var code=el('pair-code').value.trim();if(!/^\d{8}$/.test(code)){text('connection-status','请输入 8 位设备配对码');return;}
  el('pair-button').disabled=true;try{await N.pair(code);el('pair-code').value='';await connect();}catch(error){connectionStatus(false,errorText(error));}finally{el('pair-button').disabled=false;}
 }
 function positionText(position){return '已定位 · 精度约 '+Math.ceil(position.accuracy||0)+' 米';}
 function locate(){
  if(state.locating)return state.locationPromise;
  state.locating=true;text('location-status','正在获取系统位置…');text('map-status','正在获取系统位置…');el('locate-button').disabled=true;
  state.locationPromise=N.getLocation().then(function(position){state.location=position;text('location-status',positionText(position));text('map-status',positionText(position));if(map){drawDevicePosition();map.setView([position.latitude,position.longitude],position.accuracy>1000?12:17,{animate:false});}return position;},function(error){text('location-status',errorText(error));text('map-status',errorText(error)+'；也可给照片手动标位置');return null;}).then(function(position){state.locating=false;el('locate-button').disabled=false;return position;});return state.locationPromise;
 }
 function freshPhotoLocation(job){
  if(job.origin==='camera'&&Date.now()-job.selectedAt>60000){job.location=locations.unavailable('capture-expired');return;}
  var pending=job.origin==='camera'?N.getLocation().then(function(position){if(Math.abs(position.acquiredAt-job.selectedAt)>60000)return locations.unavailable('capture-expired');return locations.located({lat:position.latitude,lng:position.longitude},'device',position);}):locationService.readPhotoLocation({path:job.path},wx).then(function(value){return value.location;});
  pending.then(function(location){job.location=location;if(job.result)job.result=locations.normalizeResult(Object.assign({},job.result,{location:location}));if(state.lastJob===job&&job.result){state.result=job.result;renderResult();}if(job.recordId&&location.status==='located')try{store.setImageLocation(job.recordId,1,location,wx);}catch(_){}},function(){job.location=locations.unavailable('unavailable');});
 }
 function parseResult(raw,job){
  var result=JSON.parse(raw);if(!result||typeof result.predicted_class!=='string'||typeof result.is_valid!=='boolean'||typeof result.confidence!=='number'||!Number.isFinite(result.confidence)||result.confidence<0||result.confidence>1)throw new Error('识别服务返回格式异常，请重试上传');
  var status=result.is_valid!==true||result.predicted_class==='其他'?'invalid':/健康/.test(result.predicted_class)?'healthy':'disease';
  return locations.normalizeResult(Object.assign({},result,{displayStatus:status,confidenceText:(result.confidence*100).toFixed(1)+'%',imagePath:job.path,originalImagePath:job.originalPath||null,capture:job.capture||null,imageIndex:1,imageId:job.id,origin:job.origin,selectedAt:job.selectedAt,location:job.location||locations.unavailable('pending')}));
 }
 function upload(job){return new Promise(function(resolve,reject){N.upload({filePath:job.path,requestId:'field-'+job.id,name:'file',url:'https://rice-srt.cn/hololens-app/api/predict',success:function(response){if(response.statusCode!==200){reject(new Error('上传失败，请重试'));return;}resolve(response.data);},fail:reject});});}
 async function analyse(job){
  state.busy=true;state.lastJob=job;state.recordId=null;state.details=false;state.result=null;controls();
  state.showingOriginal=false;el('show-original').hidden=true;
  try{wx.setStorageSync('rice_pending_upload',{id:job.id,path:job.path,originalPath:job.originalPath||null,capture:job.capture||null,origin:job.origin,selectedAt:job.selectedAt});}catch(error){N.log('pending_save_error',{message:errorText(error)});}
  text('result-title','正在识别…');text('result-message','照片已拍摄，正在自动上传');el('result-image').src=N.imageUrl(job.path);el('result-image').hidden=false;el('result-confidence').hidden=true;el('upload-retry').hidden=true;el('result-panel').classList.remove('show-details');text('result-location','');text('result-time','');cameraMessage('照片正在上传识别…');
  el('result-panel').setAttribute('data-status','loading');view('result');
  try{var raw=await upload(job);job.uploadFailed=false;job.result=parseResult(raw,job);try{wx.removeStorageSync('rice_pending_upload');}catch(_){}state.result=job.result;renderResult();cameraMessage(job.result.displayStatus==='invalid'?'本张未通过识别，可直接再拍一张':'识别完成，可直接再拍一张');
   if(state.view==='camera')view('result');
   // Show the answer before copying files or waiting for the location provider.
   var queued=saveQueue.then(function(){return saveJob(job);});saveQueue=queued.catch(function(error){N.log('history_error',{message:errorText(error)});toast('结果已显示，记录保存失败：'+errorText(error));});
  }catch(error){job.uploadFailed=true;state.result=null;el('result-panel').setAttribute('data-status','fail');text('result-title','上传未完成');text('result-message',errorText(error));el('upload-retry').hidden=false;cameraMessage('上传未完成，可重试上传或直接拍下一张');if(state.view==='camera')view('result');N.log('analysis_error',{message:errorText(error)});}
  finally{state.busy=false;controls();}
 }
 async function capture(){
  if(state.capturing)return;
  if(state.busy){cameraMessage('照片正在自动上传识别，请稍候');return;}
  if(!state.cameraReady){cameraMessage('正在重新开启相机…');openCamera();return;}
  state.capturing=true;controls();N.log('capture_requested',{mode:'target-focus-quality-crop'});
  try{var photo=await N.captureOptimizedPhoto(targetRegion(),cameraMessage);if(!photo)return;var job={id:N.id(),path:photo.path,originalPath:photo.originalPath,capture:photo.capture,origin:'camera',selectedAt:photo.selectedAt||Date.now()};freshPhotoLocation(job);await analyse(job);}
  catch(error){captureErrorUntil=Date.now()+4000;cameraMessage(error.code==='capture-cancelled'?'已取消拍摄，可重新对准':errorText(error));N.log('camera_error',{message:errorText(error)});}
  finally{state.busy=false;state.capturing=false;controls();if(!state.cameraReady&&state.view==='camera'&&!document.hidden)openCamera();}
 }
 async function importPhoto(){
  if(state.busy||state.capturing)return;state.busy=true;controls();
  try{var paths=await N.chooseImages({count:1,sourceType:['album']}),job={id:N.id(),path:paths[0],origin:'album',selectedAt:Date.now()};freshPhotoLocation(job);await analyse(job);}catch(error){if(!/cancel/i.test(errorText(error)))toast(errorText(error));}finally{state.busy=false;controls();}
 }
 async function saveJob(job){
  var stamp=Math.max(Date.now(),state.lastRecordStamp?state.lastRecordStamp+1:0);state.lastRecordStamp=stamp;
  var match=/\.(jpg|jpeg|png|webp)$/i.exec(job.path),saved=N.userPath+'/rice_'+stamp+'_0.'+(match?match[1].toLowerCase():'jpg');
  var savedOriginal=job.originalPath?N.userPath+'/rice_'+stamp+'_source.jpg':null;
  try{await N.copyFile(job.path,saved);if(savedOriginal)await N.copyFile(job.originalPath,savedOriginal);}catch(error){N.unlink(saved);if(savedOriginal)N.unlink(savedOriginal);throw error;}
  var result=locations.normalizeResult(Object.assign({},job.result,{imagePath:saved,originalImagePath:savedOriginal,location:job.location||job.result.location}));
  var status=result.displayStatus,record={id:stamp,time:time(stamp),imageCount:1,thumbnailPath:saved,locationVersion:2,isMapMarked:false,permanentPaths:savedOriginal?[saved,savedOriginal]:[saved],sortedResults:[result],summary:{hasResults:true,isAllHealthy:status==='healthy',hasDisease:status==='disease',diseaseNamesText:status==='disease'?result.predicted_class:'',total:1,diseaseCount:status==='disease'?1:0,healthyCount:status==='healthy'?1:0,invalidCount:status==='invalid'?1:0,failCount:0}};
  try{store.append(record,wx);}catch(error){N.unlink(saved);if(savedOriginal)N.unlink(savedOriginal);throw error;}
  job.recordId=stamp;job.result=result;if(state.lastJob===job){state.result=result;state.recordId=stamp;renderResult();}
  N.unlink(job.path);if(job.originalPath)N.unlink(job.originalPath);job.path=saved;job.originalPath=savedOriginal;if(state.view==='history')renderHistory();N.log('history_saved',{record_id:stamp});
 }
 function renderResult(){
  var result=state.result;if(!result)return;
  el('result-panel').setAttribute('data-status',result.displayStatus);text('result-title',result.displayStatus==='invalid'?'请再拍一张':result.predicted_class);text('result-confidence','置信度 '+(result.confidenceText||(result.confidence*100).toFixed(1)+'%'));el('result-confidence').hidden=result.displayStatus==='invalid';
  text('result-message',result.displayStatus==='invalid'?(result.message||'本张未通过识别'):(result.message||'识别完成'));
  el('result-image').src=N.imageUrl(state.showingOriginal&&result.originalImagePath?result.originalImagePath:result.imagePath);el('result-image').hidden=false;el('upload-retry').hidden=true;el('show-original').hidden=!result.originalImagePath;text('show-original',state.showingOriginal?'查看识别区域':'查看原图');
  text('result-location',result.location&&result.location.status==='located'?result.locationBadge+' · 精度约 '+Math.ceil(result.location.accuracy||0)+' 米':result.location&&result.location.reason==='pending'?'位置获取中，不影响识别':'未取得位置，可在地图补充');
  text('result-time',state.recordId?time(state.recordId).slice(5):'');
 }
 function renderHistory(){
  var list=el('history-list');while(list.firstChild)list.removeChild(list.firstChild);
  try{historyRows=store.load(wx).slice().reverse();}catch(error){text('history-page','读取失败');toast(errorText(error));return;}
  var size=Math.max(1,Math.min(5,Math.floor((innerHeight-140)/90))),pages=Math.max(1,Math.ceil(historyRows.length/size));state.historyPage=Math.min(state.historyPage,pages-1);
  if(!historyRows.length){var empty=document.createElement('p');empty.className='history-empty';empty.textContent='拍照识别后自动保存最近 15 条记录';list.appendChild(empty);}
  historyRows.slice(state.historyPage*size,(state.historyPage+1)*size).forEach(function(record){var button=document.createElement('button'),image=document.createElement('img'),label=document.createElement('span'),title=document.createElement('span'),meta=document.createElement('span');button.className='history-row';image.src=N.imageUrl(record.thumbnailPath);image.alt='识别照片';title.className='history-title';title.textContent=record.summary&&record.summary.diseaseNamesText||record.sortedResults[0]&&record.sortedResults[0].predicted_class||'检测记录';meta.className='muted';meta.textContent=record.time;label.appendChild(title);label.appendChild(meta);button.appendChild(image);button.appendChild(label);button.onclick=function(){state.lastJob=null;state.recordId=record.id;state.result=record.sortedResults[0]||null;state.details=false;state.detailPage=0;renderResult();view('result');};list.appendChild(button);});
  text('history-page',(state.historyPage+1)+' / '+pages);el('history-previous').disabled=state.historyPage===0;el('history-next').disabled=state.historyPage>=pages-1;
 }
 function safeMap(callback){return root.MSApp&&MSApp.execUnsafeLocalFunction?MSApp.execUnsafeLocalFunction(callback):callback();}
 function setMapLayer(){if(mapLayer)map.removeLayer(mapLayer);mapLayer=L.tileLayer(satellite?'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}':'https://tile.openstreetmap.org/{z}/{x}/{y}.png',{maxZoom:19,attribution:satellite?'© Esri':'© OpenStreetMap',keepBuffer:0}).addTo(map);var failures=0;mapLayer.on('tileerror',function(){if(++failures===3)text('map-status','底图加载失败，请检查网络；定位和照片坐标仍保留');});}
 function openMap(){
  if(!root.L){text('map-status','地图组件未加载，请重新打开应用');return;}
  safeMap(function(){if(!map){var p=state.location;map=L.map(el('field-map'),{zoomControl:true}).setView(p?[p.latitude,p.longitude]:[32.0359,118.7611],p?16:4);setMapLayer();map.on('click',function(event){if(state.editingLocation)saveManualLocation(event.latlng);});}map.invalidateSize();drawDevicePosition();drawRecordMarkers();});
  if(!state.location&&!state.locating)locate();else if(state.location)text('map-status',positionText(state.location));
 }
 function drawDevicePosition(){if(!map||!state.location)return;var p=state.location;safeMap(function(){if(deviceMarker)map.removeLayer(deviceMarker);if(accuracyCircle)map.removeLayer(accuracyCircle);deviceMarker=L.marker([p.latitude,p.longitude],{icon:L.divIcon({className:'device-dot',iconSize:[20,20]})}).addTo(map).bindPopup('当前位置');accuracyCircle=L.circle([p.latitude,p.longitude],{radius:p.accuracy||0,weight:1,color:'#1577df',fillOpacity:.12}).addTo(map);});}
 function drawRecordMarkers(){if(!map)return;if(mapMarkers)map.removeLayer(mapMarkers);mapMarkers=L.layerGroup().addTo(map);try{store.load(wx).forEach(function(record){locations.recordPoints(record).forEach(function(point){var label=document.createElement('span');label.textContent=point.name+' · '+point.time;L.circleMarker([point.location.lat,point.location.lng],{radius:8,color:point.status==='disease'?'#bb5b23':'#237545',fillOpacity:.9}).addTo(mapMarkers).bindPopup(label).on('click',function(){state.recordId=record.id;state.result=record.sortedResults.find(function(r){return r.imageIndex===point.imageIndex;});state.details=false;renderResult();view('result');});});});}catch(error){toast(errorText(error));}}
 function editMap(){if(!state.recordId||!state.result||!locations.isLocationEligible(state.result)){toast('请先完成一次有效识别或从记录打开照片');return;}state.editingLocation=!state.editingLocation;text('map-edit',state.editingLocation?'取消标位置':'给照片标位置');text('map-status',state.editingLocation?'在地图上点选田块，立即保存到本张照片':'已取消标位置');}
 function saveManualLocation(point){try{var record=store.setImageLocation(state.recordId,state.result.imageIndex,locations.located({lat:point.lat,lng:point.lng},'manual',{acquiredAt:Date.now()}),wx);state.result=record.sortedResults.find(function(r){return r.imageIndex===state.result.imageIndex;});if(state.lastJob&&state.lastJob.recordId===state.recordId){state.lastJob.location=state.result.location;state.lastJob.result=state.result;}state.editingLocation=false;text('map-edit','给照片标位置');text('map-status','照片位置已保存');drawRecordMarkers();renderResult();}catch(error){toast(errorText(error));}}
 Array.prototype.forEach.call(document.querySelectorAll('.rail-button'),function(button){button.onclick=function(){view(button.getAttribute('data-view'));};});
 el('menu-toggle').onclick=function(){var open=!el('app').classList.contains('menu-open');el('app').classList.toggle('menu-open',open);text('menu-toggle',open?'收起':'功能');};
 el('camera-shutter').onclick=capture;el('album-button').onclick=importPhoto;el('camera-retry').onclick=openCamera;el('connect-button').onclick=connect;el('pair-button').onclick=pair;
 el('camera-region-size').onclick=function(){if(state.capturing||state.busy)return;state.targetSize=(state.targetSize+1)%targetSizes.length;text('camera-region-size','范围：'+['小','中','大'][state.targetSize]);drawTarget();};
 el('camera-video').onclick=function(event){if(state.capturing||state.busy||!state.cameraReady)return;var video=el('camera-video'),point=Q.point(event.clientX,event.clientY,video.getBoundingClientRect(),video.videoWidth||1920,video.videoHeight||1080);if(point){state.targetPoint=point;drawTarget();cameraMessage('已移动取景框，点拍照后自动对焦');}};
 el('camera-cancel').onclick=function(){state.cameraReady=false;N.stopCamera();controls();};
 el('show-original').onclick=function(){if(!state.result||!state.result.originalImagePath)return;state.showingOriginal=!state.showingOriginal;renderResult();};
 el('upload-retry').onclick=function(){if(!state.busy&&state.lastJob)analyse(state.lastJob);};el('next-photo').onclick=function(){view('camera');};
 el('history-previous').onclick=function(){state.historyPage--;renderHistory();};el('history-next').onclick=function(){state.historyPage++;renderHistory();};
 el('locate-button').onclick=locate;el('location-retry').onclick=locate;el('location-settings').onclick=function(){N.openSettings().catch(function(error){toast(errorText(error));});};el('map-type').onclick=function(){satellite=!satellite;text('map-type',satellite?'普通图':'卫星图');if(map)safeMap(setMapLayer);};el('map-edit').onclick=editMap;
 root.RiceApp={state:state,view:view,capture:capture,connect:connect,locate:locate,waitForSaves:function(){return saveQueue;}};
 window.addEventListener('resize',function(){drawTarget();if(state.view==='history')renderHistory();if(map)map.invalidateSize();});
 document.addEventListener('loadedmetadata',function(event){if(event.target.id==='camera-video')drawTarget();},true);
 document.addEventListener('visibilitychange',function(){if(document.hidden){state.cameraReady=false;drawTarget();controls();N.stopCamera();}else{if(state.view==='camera'&&!state.capturing)openCamera();connect();locate();}});
 function monitorNetwork(){N.onNetworkChange(function(){if(N.networkState()==='offline'){connectionStatus(false,'眼镜网络已断开，恢复联网后自动重传照片');return;}connect().then(function(connected){if(connected&&!state.busy&&!state.capturing&&state.lastJob&&state.lastJob.uploadFailed)analyse(state.lastJob);});});}
 window.addEventListener('beforeunload',function(){N.stopCamera();clearInterval(connectionTimer);clearInterval(diagnosticTimer);clearInterval(previewTimer);});
 function tunePreview(){if(!N.nativeMode||!N.tunePreview||!state.cameraReady||state.busy||state.capturing||diagnosticWork||document.hidden||state.view!=='camera')return;N.tunePreview(targetRegion()).then(function(value){if(!value||!state.cameraReady||state.capturing||state.view!=='camera')return;var label=el('camera-target').querySelector('span');label.textContent=value.adjusting?'自动调光中':'只识别框内';if(Date.now()>=captureErrorUntil)cameraMessage(value.message+'；点画面可移动框');},function(error){if(state.cameraReady&&!state.capturing&&Date.now()>=captureErrorUntil)cameraMessage('自动调节暂不可用：'+errorText(error));});}
 async function checkCameraCommand(){if(diagnosticWork||state.busy||state.capturing||!state.cameraReady||document.hidden)return;diagnosticWork=true;var command;try{command=await N.readCameraCheck();if(!command)return;if(command.target&&Number.isFinite(command.target.x)&&Number.isFinite(command.target.y)){state.targetPoint={x:Math.max(0,Math.min(1,command.target.x)),y:Math.max(0,Math.min(1,command.target.y))};drawTarget();}N.log('camera_check_started',{id:command.id,action:command.action});if(command.action==='controls')await N.diagnoseCamera(targetRegion());else await capture();await N.log('camera_check_completed',{id:command.id,action:command.action,message:el('camera-message').textContent});}catch(error){N.log('camera_check_error',{id:command&&command.id||'',message:errorText(error)});}finally{diagnosticWork=false;}}
 async function start(){try{await N.init();text('version','稻视界 '+N.version()+' · 对焦、稳定拍摄与目标裁剪');var pending=N.pendingCapture();connect();locate();if(pending){freshPhotoLocation(pending);analyse(pending);view('result');N.log('upload_resumed',{origin:pending.origin});}else openCamera();if(!N.isPaired())connectionTimer=setInterval(function(){if(!document.hidden)connect();},10000);root.RiceBoot.phase='ready';N.log('app_ready',{version:N.version(),native:N.nativeMode,paired:N.isPaired(),workflow:'target-focus-quality-crop'});}catch(error){root.RiceBoot.phase='error';cameraMessage('应用未能打开：'+errorText(error));N.log('boot_failed',{message:errorText(error)});}}
 start().then(async function(){await N.log('startup_hooks_started',{hidden:document.hidden});if(N.nativeMode)try{Windows.UI.Core.CoreWindow.getForCurrentThread().activate();await N.log('core_window_activated',{hidden:document.hidden});}catch(error){await N.log('core_window_activation_unavailable',{message:errorText(error),number:error.number||0});}if(root.RiceBoot.completeActivation)root.RiceBoot.completeActivation();await N.log('activation_completion_returned',{hidden:document.hidden});monitorNetwork();previewTimer=setInterval(tunePreview,600);if(N.diagnosticsEnabled&&N.diagnosticsEnabled()){diagnosticTimer=setInterval(checkCameraCommand,500);setTimeout(function(){clearInterval(diagnosticTimer);},300000);}}).catch(function(error){N.log('boot_failed',{message:errorText(error)});cameraMessage('应用未能完成启动：'+errorText(error));if(root.RiceBoot.completeActivation)try{root.RiceBoot.completeActivation();}catch(_){}});
}(window));

