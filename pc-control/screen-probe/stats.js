(function(root){
 'use strict';
 function CaptureStats(warmupMs){this.warmup=warmupMs===undefined?3000:warmupMs;this.first=null;this.lastDevice=null;this.frames=[];this.duplicates=0;this.regressions=0;this.unknown=0;}
 CaptureStats.prototype.observe=function(receivedMs,deviceTime){
  if(typeof receivedMs!=='number'||!isFinite(receivedMs))throw new Error('Invalid receipt clock');
  if(typeof deviceTime!=='number'||!isFinite(deviceTime)){this.unknown++;return false;}
  if(this.lastDevice!==null&&deviceTime<=this.lastDevice){if(deviceTime===this.lastDevice)this.duplicates++;else this.regressions++;return false;}
  if(this.frames.length&&receivedMs<this.frames[this.frames.length-1].received)throw new Error('Receipt clock regressed');
  if(this.frames.length>=3000)throw new Error('Frame observation bound reached');
  if(this.first===null)this.first=receivedMs;this.lastDevice=deviceTime;this.frames.push({received:receivedMs,device:deviceTime});return true;
 };
 CaptureStats.prototype.summary=function(){
  var start=this.first===null?null:this.first+this.warmup,end=this.frames.length?this.frames[this.frames.length-1].received:null;
  var steady=start===null?[]:this.frames.filter(function(f){return f.received>start;});
  var verified=this.unknown===0&&start!==null&&end-start>=1000&&steady.length>1;
  return {acquired_unique_frames:this.frames.length,steady_frames:steady.length,steady_start_ms:start,steady_end_ms:end,actual_capture_fps:verified?steady.length*1000/(end-start):null,timestamp_verified:verified,duplicate_timestamps:this.duplicates,regressed_timestamps:this.regressions,unknown_timestamps:this.unknown,scope:'Device capture arrival only; not PC transport or painted FPS'};
 };
 if(typeof module!=='undefined'&&module.exports)module.exports=CaptureStats;else root.CaptureStats=CaptureStats;
}(this));
