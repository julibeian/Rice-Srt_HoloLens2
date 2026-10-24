/* WinRT camera controls are capability checked; unsupported features stay explicit. */
(function(root,factory){var api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.RiceCameraControls=api;}(typeof window==='object'?window:this,function(){
 'use strict';
 function list(values){if(!values)return [];var out=[],n=Number(values.size==null?values.length:values.size)||0;for(var i=0;i<Math.min(n,128);i++)out.push(values.getAt?values.getAt(i):values[i]);return out;}
 function bound(operation,ms){return new Promise(function(resolve,reject){var finished=false,timer=setTimeout(function(){if(finished)return;finished=true;try{if(operation.cancel)operation.cancel();}catch(_){}reject(new Error('相机控制超时，请重开相机'));},ms||4000);Promise.resolve(operation).then(function(value){if(finished)return;finished=true;clearTimeout(timer);resolve(value);},function(error){if(finished)return;finished=true;clearTimeout(timer);reject(error);});});}
 async function attempt(name,work,log){try{await work();return true;}catch(error){log('camera_control_unavailable',{control:name,message:String(error.message||error).slice(0,160)});return false;}}
 function inspect(controller){
  var f=controller.focusControl,e=controller.exposureControl,c=controller.exposureCompensationControl,w=controller.whiteBalanceControl,r=controller.regionsOfInterestControl,z=controller.zoomControl;
  return {focus:!!(f&&f.supported),focusModes:list(f&&f.supportedFocusModes),focusRanges:list(f&&f.supportedFocusRanges),exposure:!!(e&&e.supported),compensation:!!(c&&c.supported),whiteBalance:!!(w&&w.supported),regionFocus:!!(r&&r.autoFocusSupported&&r.maxRegions>0),regionExposure:!!(r&&r.autoExposureSupported&&r.maxRegions>0),regionWhiteBalance:!!(r&&r.autoWhiteBalanceSupported&&r.maxRegions>0),zoom:!!(z&&z.supported)};
 }
 async function selectProfile(W,settings,log){
  try{
   var E=W.Devices.Enumeration;if(!E||!W.Media.Capture.MediaCapture.findAllVideoProfiles)return;
   var devices=list(await bound(E.DeviceInformation.findAllAsync(E.DeviceClass.videoCapture),4000));if(!devices.length)return;
   var device=devices.filter(function(d){return /PV|photo|RGB|color/i.test(d.name);})[0]||devices[0];settings.videoDeviceId=device.id;
   var best=null;list(W.Media.Capture.MediaCapture.findAllVideoProfiles(device.id)).forEach(function(profile){list(profile.supportedPhotoMediaDescription).forEach(function(photo){var area=photo.width*photo.height;if(area>9000000||photo.width/photo.height<1.7||photo.width/photo.height>1.85)return;var previews=list(profile.supportedPreviewMediaDescription).filter(function(p){return Math.abs(p.width/p.height-photo.width/photo.height)<.015;}).sort(function(a,b){return Math.abs(a.width-896)-Math.abs(b.width-896);});if(previews.length&&(!best||area>best.photo.width*best.photo.height))best={profile:profile,photo:photo,preview:previews[0]};});});
   if(best){settings.videoProfile=best.profile;settings.photoMediaDescription=best.photo;settings.previewMediaDescription=best.preview;log('camera_profile_selected',{photo_width:best.photo.width,photo_height:best.photo.height,preview_width:best.preview.width,preview_height:best.preview.height});}
  }catch(error){log('camera_profile_default',{message:String(error.message||error).slice(0,160)});}
 }
 async function initialize(W,controller,log){
  var state={controller:controller,capabilities:inspect(controller),enabled:{},baselineEv:0,ev:0,photoSize:null};
  try{var type=W.Media.Capture.MediaStreamType.photo,properties=list(controller.getAvailableMediaStreamProperties(type)).filter(function(p){return p.width>=640&&p.height>=360&&p.width*p.height<=9000000&&Math.abs(p.width/p.height-16/9)<.02;}).sort(function(a,b){return b.width*b.height-a.width*a.height;});if(properties.length){var best=properties[0];if(await attempt('photo_resolution',function(){return bound(controller.setMediaStreamPropertiesAsync(type,best),4000);},log))state.photoSize={width:best.width,height:best.height};}if(!state.photoSize){var current=controller.getMediaStreamProperties(type);state.photoSize={width:current.width,height:current.height};}}catch(error){log('camera_resolution_default',{message:String(error.message||error).slice(0,160)});}
  try{if(state.capabilities.compensation)state.ev=state.baselineEv=Number(controller.exposureCompensationControl.value)||0;}catch(_){}
  log('camera_capabilities',Object.assign({},state.capabilities,{focusModes:state.capabilities.focusModes.join(','),focusRanges:state.capabilities.focusRanges.join(','),photo_width:state.photoSize&&state.photoSize.width,photo_height:state.photoSize&&state.photoSize.height}));return state;
 }
 async function target(W,state,rect,log,options){
  options=options||{};var d=state.controller,c=state.capabilities,enabled={},r=d.regionsOfInterestControl;
  if(c.exposure)enabled.exposure=await attempt('auto_exposure',function(){return bound(d.exposureControl.setAutoAsync(true));},log);
  if(c.whiteBalance)enabled.whiteBalance=await attempt('auto_white_balance',function(){return bound(d.whiteBalanceControl.setPresetAsync(W.Media.Devices.ColorTemperaturePreset.auto));},log);
  if(c.compensation&&!options.preserveExposure)await compensation(state,state.baselineEv,log);
  if(c.regionFocus||c.regionExposure||c.regionWhiteBalance){var roi=new W.Media.Devices.RegionOfInterest();roi.bounds={x:rect.x,y:rect.y,width:rect.width,height:rect.height};roi.boundsNormalized=true;roi.autoFocusEnabled=c.regionFocus;roi.autoExposureEnabled=c.regionExposure;roi.autoWhiteBalanceEnabled=c.regionWhiteBalance;roi.weight=100;var regionOk=await attempt('target_region',function(){return bound(r.setRegionsAsync([roi],false));},log);enabled.regionFocus=regionOk&&c.regionFocus;enabled.regionExposure=regionOk&&c.regionExposure;}
  if(c.focus){
   enabled.focus=await attempt('auto_focus',async function(){var f=d.focusControl,M=W.Media.Devices.FocusMode,mode=options.continuous&&c.focusModes.indexOf(M.continuous)>=0?M.continuous:c.focusModes.indexOf(M.auto)>=0?M.auto:c.focusModes.indexOf(M.continuous)>=0?M.continuous:null;if(mode==null)throw new Error('驱动未提供自动对焦模式');await bound(f.unlockAsync());var settings=new W.Media.Devices.FocusSettings();settings.mode=mode;var full=W.Media.Devices.AutoFocusRange.fullRange;if(c.focusRanges.indexOf(full)>=0)settings.autoFocusRange=full;if(f.waitForFocusSupported)settings.waitForFocus=!options.continuous;f.configure(settings);await bound(f.focusAsync(),4500);var failed=W.Media.Capture.MediaCaptureFocusState&&W.Media.Capture.MediaCaptureFocusState.failed;if(failed!=null&&f.focusState===failed)throw new Error('未能对焦，请调整距离');},log);
  }
  state.enabled=enabled;log('camera_target_controls',enabled);return enabled;
 }
 async function compensation(state,requested,log){var c=state.controller.exposureCompensationControl;if(!state.capabilities.compensation)return false;var min=Number(c.min),max=Number(c.max),step=Number(c.step);if(!Number.isFinite(min)||!Number.isFinite(max)||!(step>0))return false;var value=Math.max(min,Math.min(max,min+Math.round((requested-min)/step)*step));if(Math.abs(value-state.ev)<step*.1)return true;var ok=await attempt('exposure_compensation',function(){return bound(c.setValueAsync(value));},log);if(ok){state.ev=value;log('camera_exposure_adjusted',{ev:Number(value.toFixed(3))});}return ok;}
 return {list:list,bound:bound,inspect:inspect,selectProfile:selectProfile,initialize:initialize,target:target,compensation:compensation};
}));
