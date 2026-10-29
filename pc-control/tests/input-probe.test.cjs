const test = require('node:test');
const assert = require('node:assert/strict');
const Probe = require('../input-probe/probe-model.js');
test('independent targets record separate trusted observations and immutable snapshots', () => {
  const p = new Probe('test');
  p.observe({type:'click',target:'a',trusted:true}); const before = p.snapshot();
  p.observe({type:'click',target:'b',trusted:false});
  assert.deepEqual(before.clicks,{a:1,b:0,c:0});
  assert.deepEqual(p.snapshot().clicks,{a:1,b:1,c:0});
  assert.equal(p.events[1].trusted,false);
});
test('cancel, lost focus and hidden application remove held observations', () => {
  for(const event of ['pointercancel','windowblur','visibilityhidden']) {
    const p = new Probe('test'); p.observe({type:'pointerdown',target:'drag-surface',pointer_id:7});
    assert.deepEqual(p.heldPointers,{7:'drag-surface'});
    p.observe({type:event,target:'window',pointer_id:7}); assert.deepEqual(p.heldPointers,{});
  }
});
test('Unicode and newlines stay intact while trace storage remains bounded', () => {
  const p = new Probe('test'); const text='稻田 Rice 123，α🙂\n第二行';
  p.observe({type:'input',target:'text',value:text});
  for(let i=0;i<1000;i++)p.observe({type:'pointermove',target:'drag-surface',pointer_id:1});
  assert.equal(p.snapshot().text,text);assert.equal(p.events.length,500);assert.equal(p.sequence,1001);
});
