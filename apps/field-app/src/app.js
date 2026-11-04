(function(root){
 'use strict';
 var N=root.RiceNative,D=root.RiceDynamic,active=false,starting=false,stopping=false,latest=null,receivedAt=0,lastFrames=0,polling=false,assetMode=false,diagnosticBusy=false,generation=0;
 function el(name){return document.getElementById(name);}function text(name,value){el(name).textContent=value||'';}
 function message(value){text('camera-message',value);}
 function controls(){el('dynamic-toggle').disabled=starting||stopping;el('dynamic-toggle').textContent=starting?'加载模型…':stopping?'停止中…':active?'停止识别':'开始识别';}
 function clear(){latest=null;el('dynamic-overlay').getContext('2d').clearRect(0,0,el('dynamic-overlay').width,el('dynamic-overlay').height);text('dynamic-confidence','');}
 function render(){
  var canvas=el('dynamic-overlay'),surface=assetMode?el('yolo-asset'):el('camera-video'),bounds=surface.getBoundingClientRect(),w=Math.round(bounds.width),h=Math.round(bounds.height);
  if(!w||!h)return;if(canvas.width!==w||canvas.height!==h){canvas.width=w;canvas.height=h;}var context=canvas.getContext('2d');context.clearRect(0,0,w,h);
  var age=latest?latest.resultAgeMs+Date.now()-receivedAt:Infinity;
  if(!active||!D.fresh(latest,age)){if(active&&latest)text('dynamic-hint','等待新结果，旧框已清除');return;}
  var boxes=D.boxes(latest,w,h);context.lineWidth=3;context.font='bold 21px Segoe UI,Microsoft YaHei';
  boxes.forEach(function(box){var label=box.label+' '+(box.confidence*100).toFixed(1)+'%';context.strokeStyle='#7eff8a';context.strokeRect(box.x,box.y,box.width,box.height);var tw=context.measureText(label).width+12,y=Math.max(0,box.y-28);context.fillStyle='rgba(4,35,12,.95)';context.fillRect(box.x,y,tw,28);context.fillStyle='#effff0';context.fillText(label,box.x+6,y+22);});
 }
 function show(result){
  latest=result;receivedAt=Date.now();text('dynamic-label',assetMode?'内置验证图像':result.detections.length?'检出 '+result.detections.length+' 个目标':'未检出目标');
  text('dynamic-confidence',result.detections.length?(result.detections[0].confidence*100).toFixed(1)+'%':'');
  text('dynamic-meta','眼镜内 YOLOv8n · 第 '+result.cameraFrames+' 个相机帧 · 推理 '+Math.round(result.inferenceMs)+' ms · '+result.inputSize+'px');
  text('dynamic-hint',assetMode?'仅验证模型与框显示，不计实物叶片效果':result.detections.length?'持续检测中，请缓慢移动观察':'未检出不等于健康，请调整距离和视角');render();
 }
 async function start(){
  if(active||starting||stopping)return;var current=++generation;starting=true;controls();message('正在加载眼镜内模型…');
  try{var model=await N.yoloStart();if(current!==generation||document.hidden){await N.yoloStop();return;}active=true;assetMode=false;el('yolo-asset').hidden=true;el('camera-video').hidden=false;lastFrames=0;clear();text('dynamic-label','模型已就绪');text('dynamic-hint','正在读取相机新帧');text('dynamic-meta','眼镜内 YOLOv8n · '+model.inputSize+'px');message('');await N.log('dynamic_started',{engine:'local-yolo',modelSha256:model.modelSha256,onDevice:true,networkRequired:false});}
  catch(error){if(current===generation){active=false;message('本地识别未能启动：'+error.message);N.log('dynamic_start_failed',{message:String(error.message||error)});}}
  finally{if(current===generation){starting=false;controls();}}
 }
 async function stop(reason){
  if(stopping)return;++generation;active=false;starting=false;stopping=true;controls();clear();assetMode=false;el('yolo-asset').hidden=true;el('camera-video').hidden=false;
  try{var state=await N.yoloStop();text('dynamic-label','识别已停止');text('dynamic-hint','相机预览保持开启');message('');await N.log('dynamic_stopped',{reason:reason||'user',native:state});}
  catch(error){message(error.message);N.log('dynamic_stop_pending',{message:error.message});}finally{stopping=false;controls();}
 }
 async function poll(){
  if(!active||polling||document.hidden)return;polling=true;
  try{var result=N.yoloState();if(result.phase==='error')throw new Error(result.stage+': '+result.error);if(result.phase==='stopped')throw new Error('本地模型已释放，请重新开始');
   if(result.frames>lastFrames){lastFrames=result.frames;show(result);if(result.cameraFrames<=2||result.cameraFrames%5===0||result.source==='diagnostic_asset')await N.log(result.source==='diagnostic_asset'?'yolo_asset_result':'dynamic_frame',result);}
   if(!assetMode&&!result.busy)N.submitCamera();
  }catch(error){active=false;clear();message('本地检测失败：'+error.message);await N.log('dynamic_error',{message:error.message});try{await N.yoloStop();}catch(_){}controls();}
  finally{polling=false;}
 }
 async function asset(name){
  if(!active)await start();if(!active)throw new Error('本地模型未运行');assetMode=true;
  var until=Date.now()+15000;while(N.yoloState().busy&&Date.now()<until)await new Promise(function(resolve){setTimeout(resolve,100);});
  await N.submitAsset(name);el('yolo-asset').hidden=false;el('camera-video').hidden=true;clear();await N.log('yolo_asset_submitted',{asset:name,onDevice:true});
 }
 async function check(){
  if(diagnosticBusy)return;diagnosticBusy=true;var command;
  try{command=await N.readCameraCheck();if(!command)return;
   if(command.action==='dynamic_start'){if(assetMode){assetMode=false;el('yolo-asset').hidden=true;el('camera-video').hidden=false;clear();}await start();}
   else if(command.action==='dynamic_stop')await stop('diagnostic');else if(command.action==='dynamic_asset')await asset(String(command.asset||''));
   await N.log('camera_check_completed',{id:command.id,action:command.action,native:N.yoloState()});
  }catch(error){await N.log('camera_check_error',{id:command&&command.id||'',message:error.message});}finally{diagnosticBusy=false;}
 }
 el('dynamic-toggle').addEventListener('click',function(){if(active)stop('user');else start();});
 el('camera-retry').addEventListener('click',async function(){await stop('camera_restart');try{await N.startCamera();el('camera-retry').hidden=true;await start();}catch(error){message(error.message);}});
 document.addEventListener('visibilitychange',function(){if(document.hidden&&(active||starting))stop('hidden');});
 root.addEventListener('resize',render);setInterval(render,200);setInterval(poll,100);
 (async function(){
  try{await N.init();text('version','稻视界 '+N.version()+' · 眼镜内检测');await N.startCamera();await N.log('app_ready',{version:N.version(),workflow:'continuous-local-yolo',onDevice:true,networkRequired:false});if(root.RiceBoot){root.RiceBoot.phase='ready';root.RiceBoot.completeActivation();}if(N.diagnosticsEnabled())setInterval(check,500);if(N.autoStart())await start();else{message('相机已就绪，可开始识别');controls();}}
  catch(error){message('应用未能打开：'+error.message);el('camera-retry').hidden=false;await N.log('boot_failed',{message:error.message});if(root.RiceBoot)root.RiceBoot.completeActivation();}
 })();
}(window));
