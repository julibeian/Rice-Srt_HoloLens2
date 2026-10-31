const {test}=require('node:test');
const assert=require('node:assert/strict');
const D=require('../src/dynamic.js');

test('frame plan uses the selected square ROI and a bounded output size',()=>{
 const plan=D.plan(1920,1080,{x:.25,y:.2,width:.5,height:.5},384);
 assert.deepEqual(plan,{x:480,y:216,width:960,height:540,size:384});
 assert.equal(D.plan(1920,1080,{x:.9,y:.9,width:.1,height:.1},9999).size,1024);
 assert.throws(()=>D.plan(0,1080,{x:0,y:0,width:.5,height:.5},384),/有效画面/);
 assert.throws(()=>D.plan(1920,1080,{x:.9,y:.9,width:.5,height:.5},384),/取景区域/);
});

test('interval uses an immediate next frame and backs off on failures',()=>{
 assert.equal(D.intervalFor({rttMs:1200,inferenceMs:800}),0);
 assert.equal(D.intervalFor({rttMs:1200},{gapMs:800}),800);
 assert.equal(D.intervalFor({failures:1,lastIntervalMs:1000}),1800);
 assert.equal(D.intervalFor({failures:3,lastIntervalMs:3500,maxIntervalMs:4000}),4000);
});

test('stable view waits for confirmation, rejects mixed and invalid frames',()=>{
 const now=100000;
 assert.equal(D.stableView([],now).status,'warming');
 const one=[{at:now-500,predicted_class:'稻瘟病',confidence:.9,is_valid:true}];
 assert.equal(D.stableView(one,now).status,'warming');
 assert.equal(D.stableView(one,now).preview,'稻瘟病');
 const two=one.concat([{at:now-200,predicted_class:'稻瘟病',confidence:.8,is_valid:true}]);
 const stable=D.stableView(two,now);
 assert.equal(stable.status,'stable');assert.equal(stable.label,'稻瘟病');assert.ok(Math.abs(stable.confidence-.85)<1e-9);
 const mixed=[{at:now-400,predicted_class:'稻瘟病',confidence:.9,is_valid:true},{at:now-200,predicted_class:'健康水稻',confidence:.9,is_valid:true}];
 assert.equal(D.stableView(mixed,now).status,'uncertain');
 const invalid=[{at:now-200,predicted_class:'其他',confidence:.9,is_valid:false}];
 assert.equal(D.stableView(invalid,now).status,'invalid');
 assert.equal(D.stableView(two,now+5000).status,'stale');
});

test('annotation maps CAM cells and box into display pixels',()=>{
 const value=D.annotationRects({grid:{width:2,height:2,values:[[0,.5],[0,0]]},box:[.5,0,.5,.5],peak:[.75,.25]},{x:0,y:0,width:.5,height:.5},{x:10,y:20,width:400,height:300});
 assert.equal(value.cells.length,1);assert.deepEqual(value.cells[0],{x:110,y:20,width:100,height:75,value:.5});
 assert.deepEqual(value.box,{x:110,y:20,width:100,height:75});
 assert.deepEqual(value.peak,{x:160,y:57.5});
 assert.equal(D.annotationRects(null,{x:0,y:0,width:1,height:1},{x:0,y:0,width:1,height:1}),null);
});

test('session runs capture/analyze repeatedly and stops on request',async()=>{
 let now=1000,frames=0,results=0,errors=0,stops=0;
 const session=D.createSession({
  now:()=>now,
  wait:async ms=>{now+=ms;},
  capture:async()=>({bytes:new Uint8Array([1]),hash:'a'.repeat(64),frameId:'f'+frames}),
  analyze:()=>({promise:(async()=>{frames++;now+=900;return {predicted_class:'健康水稻',confidence:.9,is_valid:true,timing:{inference_ms:800}};})()}),
  onResult:(result,view,stats)=>{results++;if(results===2)session.stop();},
  onError:()=>{errors++;},
  onStop:()=>{stops++;}
 });
 session.start();
 for(let i=0;i<200&&stops===0;i++)await new Promise(resolve=>setImmediate(resolve));
 assert.equal(results,2);assert.equal(errors,0);assert.equal(stops,1);assert.equal(session.isRunning(),false);
});

test('session reports errors, backs off and can recover',async()=>{
 let now=1000,attempts=0,errors=0,results=0,stops=0,lastError=null;
 const session=D.createSession({
  now:()=>now,wait:async ms=>{now+=ms;},
  capture:async()=>({bytes:new Uint8Array([1]),hash:'a'.repeat(64),frameId:'f'}),
  analyze:()=>({promise:(async()=>{attempts++;if(attempts===1)throw new Error('network down');return {predicted_class:'稻瘟病',confidence:.9,is_valid:true,timing:{inference_ms:800}};})()}),
  onResult:()=>{results++;session.stop();},onError:e=>{errors++;lastError=e.message;},onStop:()=>{stops++;}
 });
 session.start();
 for(let i=0;i<200&&stops===0;i++)await new Promise(resolve=>setImmediate(resolve));
 assert.equal(errors,1);assert.match(lastError,/network down/);assert.equal(results,1);assert.equal(stops,1);
});
