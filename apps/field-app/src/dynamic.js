/* Dynamic recognition policy and overlay geometry. No DOM or WinRT here. */
(function(root,factory){var api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.RiceDynamic=api;}(typeof window==='object'?window:this,function(){
 'use strict';
 function finite(value){return typeof value==='number'&&Number.isFinite(value);}
 function clamp(value,min,max){return Math.max(min,Math.min(max,value));}
 function validate(rect){if(!rect||!['x','y','width','height'].every(function(key){return finite(rect[key]);})||rect.x<0||rect.y<0||rect.width<=0||rect.height<=0||rect.x+rect.width>1.000001||rect.y+rect.height>1.000001)throw new Error('动态取景区域无效');return rect;}
 function plan(width,height,rect,size){
  if(!finite(width)||!finite(height)||width<=0||height<=0)throw new Error('相机尚未提供有效画面');
  validate(rect);var side=Math.round(clamp(size||384,64,1024));
  return {x:Math.max(0,Math.min(width-1,Math.round(rect.x*width))),y:Math.max(0,Math.min(height-1,Math.round(rect.y*height))),width:Math.max(1,Math.min(width-Math.round(rect.x*width),Math.round(rect.width*width))),height:Math.max(1,Math.min(height-Math.round(rect.y*height),Math.round(rect.height*height))),size:side};
 }
 function intervalFor(stats,options){
  stats=stats||{};options=options||{};var maximum=finite(options.maxIntervalMs)?options.maxIntervalMs:4000,last=finite(stats.lastIntervalMs)?stats.lastIntervalMs:1200,gap=finite(options.gapMs)?options.gapMs:0;
  if(stats.failures>0)return clamp(Math.round(Math.max(1500,last*1.8)),1500,maximum);
  return clamp(Math.round(gap),0,maximum);
 }
 function average(rows,key){if(!rows.length)return null;var total=0,count=0;rows.forEach(function(row){if(finite(row[key])){total+=row[key];count++;}});return count?total/count:null;}
 function stableView(history,now,options){
  options=options||{};var windowMs=finite(options.windowMs)?options.windowMs:8000,minSamples=finite(options.minSamples)?options.minSamples:2,staleMs=finite(options.staleMs)?options.staleMs:4500;
  var rows=(history||[]).filter(function(row){return row&&finite(row.at)&&now-row.at<=windowMs;});
  if(!rows.length)return {status:'warming',label:'分析中…',preview:null,confidence:null,samples:0,latest:null,ageMs:null};
  var latest=rows[rows.length-1],ageMs=Math.max(0,now-(finite(latest.at)?latest.at:now)),stale=ageMs>staleMs;
  var valid=rows.filter(function(row){return row.is_valid===true&&typeof row.predicted_class==='string'&&row.predicted_class!=='其他';});
  if(!valid.length){
   return {status:stale?'stale':'invalid',label:stale?'等待新画面…':'未识别到水稻叶片',preview:latest.predicted_class||null,confidence:average(rows,'confidence'),samples:rows.length,latest:latest,ageMs:ageMs};
  }
  var groups={};
  valid.forEach(function(row){var key=row.predicted_class,group=groups[key];if(!group)group=groups[key]={name:key,count:0,weight:0};group.count++;group.weight+=finite(row.confidence)?row.confidence:0;});
  var ranked=Object.keys(groups).map(function(key){var g=groups[key];return {name:g.name,count:g.count,weight:g.weight,confidence:g.weight/g.count};}).sort(function(a,b){return b.count-a.count||b.weight-a.weight;});
  var top=ranked[0],second=ranked[1];
  if(valid.length<minSamples)return {status:'warming',label:'分析中…',preview:top.name,confidence:top.confidence,samples:rows.length,latest:latest,ageMs:ageMs};
  var stable=top.count>=minSamples&&(!second||top.count>second.count||top.weight>=second.weight*1.15);
  if(stale)return {status:'stale',label:'等待新画面…',preview:top.name,confidence:top.confidence,samples:rows.length,latest:latest,ageMs:ageMs};
  if(!stable)return {status:'uncertain',label:'识别不稳定，请稳住',preview:top.name,confidence:top.confidence,samples:rows.length,latest:latest,ageMs:ageMs};
  return {status:'stable',label:top.name,preview:top.name,confidence:top.confidence,samples:rows.length,validSamples:valid.length,latest:latest,ageMs:ageMs,ranked:ranked};
 }
 function annotationRects(annotation,roi,fit){
  if(!annotation||!annotation.grid||!Array.isArray(annotation.grid.values)||!roi||!fit||!finite(fit.width)||!finite(fit.height))return null;
  var grid=annotation.grid,width=grid.width,height=grid.height,values=grid.values;if(!finite(width)||!finite(height)||width<=0||height<=0)return null;
  var cells=[];
  for(var y=0;y<Math.min(height,values.length);y++)for(var x=0;x<Math.min(width,(values[y]||[]).length);x++){var value=values[y][x];if(!finite(value)||value<.03)continue;cells.push({x:fit.x+(roi.x+(x/width)*roi.width)*fit.width,y:fit.y+(roi.y+(y/height)*roi.height)*fit.height,width:(roi.width/width)*fit.width,height:(roi.height/height)*fit.height,value:Math.max(0,Math.min(1,value))});}
  var box=annotation.box,peak=annotation.peak,mapped=null,peakPoint=null;
  if(Array.isArray(box)&&box.length===4&&box.every(finite))mapped={x:fit.x+(roi.x+box[0]*roi.width)*fit.width,y:fit.y+(roi.y+box[1]*roi.height)*fit.height,width:Math.max(1,box[2]*roi.width*fit.width),height:Math.max(1,box[3]*roi.height*fit.height)};
  if(Array.isArray(peak)&&peak.length===2&&peak.every(finite))peakPoint={x:fit.x+(roi.x+peak[0]*roi.width)*fit.width,y:fit.y+(roi.y+peak[1]*roi.height)*fit.height};
  return {cells:cells,box:mapped,peak:peakPoint};
 }
 function createSession(options){
  options=options||{};var now=options.now||function(){return Date.now();},wait=options.wait||function(ms){return new Promise(function(resolve){setTimeout(resolve,ms);});};
  var running=false,currentAbort=null,history=[],stats={frames:0,ok:0,fail:0,failures:0,lastRtt:null,lastInference:null,startedAt:0};
  function snapshot(){return {frames:stats.frames,ok:stats.ok,fail:stats.fail,failures:stats.failures,lastRtt:stats.lastRtt,lastInference:stats.lastInference,startedAt:stats.startedAt,uptimeMs:stats.startedAt?Math.max(0,now()-stats.startedAt):0};}
  function emit(callback,args){if(typeof callback!=='function')return;try{callback.apply(null,args);}catch(_){}}
  async function loop(){
   var lastInterval=finite(options.gapMs)?options.gapMs:0;
   while(running){
    var started=now();
    try{
     var captured=await options.capture();if(!running)break;
     var operation=options.analyze(captured);currentAbort=operation&&operation.abort||null;
     var result=await (operation&&operation.promise?operation.promise:operation);currentAbort=null;if(!running)break;
     var rtt=now()-started;stats.frames++;stats.ok++;stats.failures=0;stats.lastRtt=rtt;stats.lastInference=result&&result.timing&&finite(result.timing.inference_ms)?result.timing.inference_ms:null;
     history.push({at:now(),predicted_class:result.predicted_class,confidence:result.confidence,is_valid:result.is_valid,result:result});if(history.length>24)history.shift();
     emit(options.onResult,[result,stableView(history,now(),options),snapshot()]);
     lastInterval=intervalFor({rttMs:rtt,inferenceMs:stats.lastInference,lastIntervalMs:lastInterval,minIntervalMs:options.minIntervalMs,maxIntervalMs:options.maxIntervalMs},options);
    }catch(error){
     if(!running)break;currentAbort=null;stats.fail++;stats.failures++;emit(options.onError,[error,snapshot()]);
     lastInterval=intervalFor({failures:stats.failures,lastIntervalMs:lastInterval,minIntervalMs:options.minIntervalMs,maxIntervalMs:options.maxIntervalMs},options);
    }
    if(!running)break;if(lastInterval>0)await wait(lastInterval);
   }
   running=false;emit(options.onStop,[snapshot()]);
  }
  return {start:function(){if(running)return false;running=true;stats.startedAt=now();loop();return true;},stop:function(){running=false;if(currentAbort&&typeof currentAbort==='function'){try{currentAbort();}catch(_){}}currentAbort=null;return true;},isRunning:function(){return running;},stats:snapshot,history:function(){return history.slice();}};
 }
 return {plan:plan,intervalFor:intervalFor,stableView:stableView,annotationRects:annotationRects,createSession:createSession};
}));
