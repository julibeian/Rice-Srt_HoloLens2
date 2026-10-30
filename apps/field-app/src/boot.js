(function(){
 window.RiceBoot={phase:'scripts_loading',errors:[],startedAt:new Date().toISOString()};
 var traceQueue=Promise.resolve();
 window.RiceBoot.trace=function(phase){if(!window.Windows)return;traceQueue=traceQueue.then(function(){return Windows.Storage.ApplicationData.current.localFolder.createFileAsync('boot-state.json',Windows.Storage.CreationCollisionOption.replaceExisting).then(function(file){return Windows.Storage.FileIO.writeTextAsync(file,JSON.stringify({phase:phase,at:new Date().toISOString(),startedAt:window.RiceBoot.startedAt}));});}).catch(function(){});};
 window.RiceBoot.trace('scripts_loading');
 var resolveActivation,activationDeferral=null,activationComplete=false;
 window.RiceBoot.activationReady=new Promise(function(resolve){resolveActivation=resolve;});
 window.RiceBoot.completeActivation=function(){activationComplete=true;if(activationDeferral){var current=activationDeferral;activationDeferral=null;current.complete();}window.RiceBoot.trace('activation_completed');};
 if(window.Windows){try{Windows.UI.WebUI.WebUIApplication.addEventListener('activated',function(args){window.RiceBoot.trace('activation_received');try{activationDeferral=args.activatedOperation.getDeferral();}catch(_){}resolveActivation();if(activationComplete)window.RiceBoot.completeActivation();});}catch(_){resolveActivation();}}else resolveActivation();
 function record(row){window.RiceBoot.errors.push(row);if(window.Windows){try{Windows.Storage.ApplicationData.current.localFolder.createFileAsync('boot-error.json',Windows.Storage.CreationCollisionOption.replaceExisting).then(function(f){return Windows.Storage.FileIO.writeTextAsync(f,JSON.stringify(row));}).then(null,function(){});}catch(_){}}if(window.RiceNative&&RiceNative.log)RiceNative.log('script_error',row).catch(function(){});}
 window.addEventListener('error',function(e){record({message:String(e.message||'脚本错误'),file:String(e.filename||''),line:e.lineno||0,stack:String(e.error&&e.error.stack||'').slice(0,2000)});});
 if(window.Windows)try{Windows.UI.WebUI.WebUIApplication.addEventListener('unhandlederrordetected',function(args){try{args.unhandledError.propagate();}catch(error){record({message:String(error.message||error),number:error.number||0,stack:String(error.stack||'').slice(0,2000),source:'winrt-unhandled'});}});}catch(_){}
}());
