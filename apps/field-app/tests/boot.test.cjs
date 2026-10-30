const {test}=require('node:test');const assert=require('node:assert/strict');const fs=require('node:fs');const path=require('node:path');const vm=require('node:vm');
test('native startup waits for activation and completes its deferral only after application readiness',async()=>{
 const listeners={},root={Promise,Date,JSON,String,addEventListener(){},Windows:{UI:{WebUI:{WebUIApplication:{addEventListener(name,callback){listeners[name]=callback;}}}}}};root.window=root;vm.createContext(root);vm.runInContext(fs.readFileSync(path.join(__dirname,'../src/boot.js'),'utf8'),root);
 let ready=false,completed=0;root.RiceBoot.activationReady.then(()=>{ready=true;});await Promise.resolve();assert.equal(ready,false);
 listeners.activated({activatedOperation:{getDeferral(){return {complete(){completed++;}};}}});await root.RiceBoot.activationReady;assert.equal(ready,true);assert.equal(completed,0);root.RiceBoot.completeActivation();root.RiceBoot.completeActivation();assert.equal(completed,1);
});
