const {test}=require('node:test');const assert=require('node:assert/strict');const D=require('../src/dynamic.js');
const frame={onDevice:true,model:'YOLOv8n-6',frames:1,sourceWidth:896,sourceHeight:504,detections:[{classId:1,label:'稻水象甲',confidence:.85,box:[224,126,672,378]}]};
test('actual frame coordinates map through contain scaling and letterboxing',()=>{
 const [box]=D.boxes(frame,1000,1000);assert.equal(box.x,250);assert.equal(box.y,359.375);assert.equal(box.width,500);assert.equal(box.height,281.25);
});
test('multi-object classes stay separate and malformed or mismatched labels are rejected',()=>{
 const other={classId:3,label:'白叶枯病',confidence:.6,box:[0,0,100,100]};
 const f={...frame,detections:[...frame.detections,other,{...other,label:'健康水稻'},{...other,classId:9},{...other,box:[2,2,1,1]},{...other,box:[0,0,NaN,10]}]};
 assert.deepEqual(D.boxes(f,896,504).map(x=>x.classId),[1,3]);
});
test('stale and nonlocal outputs cannot continue drawing boxes',()=>{
 assert.equal(D.fresh(frame,100),true);assert.equal(D.fresh(frame,5000),false);assert.equal(D.fresh(frame,Infinity),false);assert.equal(D.fresh({...frame,onDevice:false},0),false);assert.equal(D.fresh({...frame,model:'ConvNeXt'},0),false);
});
