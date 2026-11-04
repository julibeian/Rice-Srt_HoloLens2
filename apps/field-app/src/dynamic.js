/* Geometry and freshness policy for actual YOLO detection boxes. */
(function(root,factory){var value=factory();if(typeof module==='object'&&module.exports)module.exports=value;else root.RiceDynamic=value;}(typeof window==='object'?window:this,function(){
 'use strict';
 var classes=['稻纵卷叶螟','稻水象甲','稻叶蝉','白叶枯病','胡麻斑病','稻瘟病'];
 function fresh(result,age){return !!result&&result.onDevice===true&&result.model==='YOLOv8n-6'&&result.frames>0&&Number.isFinite(age)&&age>=0&&age<5000;}
 function boxes(result,width,height){
  if(!result||!(result.sourceWidth>0)||!(result.sourceHeight>0)||!(width>0)||!(height>0))return [];
  var scale=Math.min(width/result.sourceWidth,height/result.sourceHeight),ox=(width-result.sourceWidth*scale)/2,oy=(height-result.sourceHeight*scale)/2;
  return (result.detections||[]).filter(function(d){return d&&Number.isInteger(d.classId)&&d.classId>=0&&d.classId<6&&d.label===classes[d.classId]&&Array.isArray(d.box)&&d.box.length===4&&d.box.every(Number.isFinite)&&Number.isFinite(d.confidence)&&d.confidence>=0&&d.confidence<=1&&d.box[2]>d.box[0]&&d.box[3]>d.box[1];}).map(function(d){
   return {label:d.label,classId:d.classId,confidence:d.confidence,x:ox+Math.max(0,d.box[0])*scale,y:oy+Math.max(0,d.box[1])*scale,width:(Math.min(result.sourceWidth,d.box[2])-Math.max(0,d.box[0]))*scale,height:(Math.min(result.sourceHeight,d.box[3])-Math.max(0,d.box[1]))*scale};
  }).filter(function(d){return d.width>0&&d.height>0;});
 }
 return {classes:classes,fresh:fresh,boxes:boxes};
}));
