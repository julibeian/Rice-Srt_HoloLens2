(function(root){
 'use strict';
 var N=root.RiceNative,timer;
 function callbacks(o,p){p.then(function(value){if(o.success)o.success(value||{});if(o.complete)o.complete(value||{});},function(e){var value={errMsg:e.errMsg||e.message||String(e)};if(o.fail)o.fail(value);if(o.complete)o.complete(value);});}
 root.wx={
  env:{USER_DATA_PATH:N.userPath},getFileSystemManager:N.fileSystem,
  getStorageSync:function(key){var value=localStorage.getItem(key);return value==null?'':JSON.parse(value);},setStorageSync:function(key,value){localStorage.setItem(key,JSON.stringify(value));},removeStorageSync:function(key){localStorage.removeItem(key);},
  getSetting:function(o){callbacks(o,N.locationPermission().then(function(value){var settings={};if(value!==undefined)settings['scope.userLocation']=value;return {authSetting:settings};}));},getLocation:function(o){callbacks(o,N.getLocation());},uploadFile:N.upload,
  showToast:function(o){var toast=document.getElementById('toast');clearTimeout(timer);toast.textContent=o.title;toast.hidden=false;timer=setTimeout(function(){toast.hidden=true;},o.duration||3000);}
 };
}(window));
