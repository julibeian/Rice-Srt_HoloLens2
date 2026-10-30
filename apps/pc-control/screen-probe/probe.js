(function(){
 'use strict';
 var state={schema_version:1,app_version:'1.0.0.2',session_id:Date.now().toString(36)+'-'+Math.random().toString(36).slice(2),phase:'initializing',source_selected:false,capture_started:false,events:[],error:null};
 var bridge=null,pollTimer=null,writing=false,dirty=false,lastPhase=null,finishedCapture=null;
 function el(id){return document.getElementById(id);}
 function errorData(error){return {name:error.name||'Error',number:error.number===undefined?null:error.number,message:String(error.message||error)};}
 function save(){
  if(writing){dirty=true;return;}writing=true;dirty=false;var text=JSON.stringify(state);
  Windows.Storage.ApplicationData.current.localFolder.createFileAsync('screen-probe-state.json',Windows.Storage.CreationCollisionOption.replaceExisting).then(function(file){return Windows.Storage.FileIO.writeTextAsync(file,text);}).then(function(){writing=false;if(dirty)save();},function(error){writing=false;el('details').textContent='保存失败 '+String(error.number||error.message);});
 }
 function event(name,details){state.events.push({type:name,at:new Date().toISOString(),details:details||null});if(state.events.length>60)state.events.shift();save();}
 function computeSummary(nativeState){
  var stats=new CaptureStats(3000),observations=nativeState.observations||[];
  observations.forEach(function(frame){stats.observe(frame.received_us/1000,frame.device_100ns);});
  var summary=stats.summary();summary.measurement_completed=summary.timestamp_verified&&nativeState.phase==='completed'&&nativeState.hresult==='0x00000000'&&nativeState.session_close_hresult==='0x00000000'&&nativeState.pool_close_hresult==='0x00000000'&&nativeState.picker_outcome_known===true&&nativeState.picker_cleanup_verified===true;
  summary.capture_content_verified=false;
  if(!summary.measurement_completed)summary.actual_capture_fps=null;
  return summary;
 }
 function refresh(){
  if(!bridge)return;var nativeState=JSON.parse(bridge.getState());state.native=nativeState;state.phase=nativeState.phase;state.source_selected=nativeState.source_selected;state.capture_started=nativeState.capture_started;state.source=nativeState.source;state.frame_file=nativeState.frame_file;
  var unresolvedPicker=nativeState.picker_requested&&nativeState.picker_cleanup_verified!==true;
  el('choose').disabled=nativeState.active||nativeState.phase==='preflight_failed'||unresolvedPicker;el('stop').disabled=!nativeState.active;
  if(nativeState.phase==='capturing')el('status').textContent='正在采集，约 20 秒后停止；已收到 '+nativeState.observed_frames+' 帧';
  else if(nativeState.phase==='choosing_source')el('status').textContent='请在眼镜的系统选择器中选择画面';
  else if(nativeState.phase==='ready')el('status').textContent='采集能力和图形设备已就绪';
  else if(nativeState.phase==='selection_cancelled')el('status').textContent='画面选择已取消';
  if(lastPhase!==nativeState.phase){lastPhase=nativeState.phase;event('native_phase',{phase:lastPhase,stage:nativeState.stage,hresult:nativeState.hresult});}
  if(nativeState.terminal&&!nativeState.active&&finishedCapture!==nativeState.capture_id){
   finishedCapture=nativeState.capture_id;state.summary=computeSummary(nativeState);state.stop_reason=nativeState.stop_reason;
   if(nativeState.phase==='failed'){state.error={name:'NativeCaptureError',number:null,message:nativeState.stage+' '+nativeState.hresult};el('status').textContent='采集未完成';}
   else el('status').textContent=nativeState.phase==='selection_cancelled'?'画面选择已取消':'采集已停止';
   if(unresolvedPicker)el('status').textContent='来源选择状态待核对；需结束此验证进程后再开始新测试';
   el('result').textContent=state.summary.actual_capture_fps===null?'没有取得完整的可验证采集结果':state.summary.actual_capture_fps.toFixed(2)+' 帧/秒（设备采集）';
   el('details').textContent=JSON.stringify(state.error||state.summary,null,2);event('capture_finished',{phase:state.phase,summary:state.summary,frame_file:state.frame_file});
  }
 }
 function choose(){
  if(!bridge||el('choose').disabled)return;state.error=null;state.summary=null;state.frame_file=null;finishedCapture=null;el('choose').disabled=true;
  try{bridge.openPicker(Windows.Storage.ApplicationData.current.localFolder.path);event('picker_requested');refresh();}
  catch(error){state.error=errorData(error);event('picker_request_failed',state.error);refresh();}
 }
 function stop(){if(!bridge)return;try{bridge.stop();el('stop').disabled=true;el('status').textContent='正在停止采集…';event('stop_requested');}catch(error){state.error=errorData(error);event('stop_failed',state.error);}}
 el('choose').addEventListener('click',choose);el('stop').addEventListener('click',stop);
 window.addEventListener('unload',function(){if(pollTimer)clearInterval(pollTimer);if(bridge)try{bridge.stop();}catch(_){} });
 try{
  bridge=new Rice.HoloLens.ScreenNative.Probe();state.preflight=JSON.parse(bridge.inspect());refresh();
  if(state.preflight.component_protocol!==2||state.preflight.phase!=='ready'||!state.preflight.supported||!state.preflight.device_created||!state.preflight.frame_pool_factory_available){el('choose').disabled=true;state.phase='preflight_failed';state.error={name:'NativePreflightError',number:null,message:state.preflight.component_protocol!==2?'原生组件版本不匹配':state.preflight.stage+' '+state.preflight.hresult};el('status').textContent='采集准备失败';el('details').textContent=JSON.stringify(state.error,null,2);event('preflight_failed',state.error);}
  else{event('ready',{supported:state.preflight.supported,device_created:state.preflight.device_created});pollTimer=setInterval(function(){try{refresh();}catch(error){clearInterval(pollTimer);pollTimer=null;state.error=errorData(error);stop();state.phase='failed';el('choose').disabled=true;event('state_read_failed',state.error);}},750);}
 }catch(error){state.error=errorData(error);state.phase='preflight_failed';el('status').textContent='采集准备失败';el('details').textContent=JSON.stringify(state.error,null,2);event('preflight_failed',state.error);}
}());
