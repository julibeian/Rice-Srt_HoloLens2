const test=require('node:test');
const assert=require('node:assert/strict');
const Stats=require('../screen-probe/stats.js');
test('counts a real30Hz arrival window after warmup',()=>{const s=new Stats(3000);for(let i=0;i<=600;i++)s.observe(i*1000/30,i*333333);const r=s.summary();assert.equal(r.timestamp_verified,true);assert.ok(Math.abs(r.actual_capture_fps-30)<0.01);});
test('repeated timestamps cannot create high frame rate',()=>{const s=new Stats(0);for(let i=0;i<=100;i++){for(let j=0;j<30;j++)s.observe(i*100,i);}const r=s.summary();assert.equal(r.acquired_unique_frames,101);assert.equal(r.duplicate_timestamps,2929);assert.equal(r.actual_capture_fps,10);});
test('missing timestamp keeps frame rate unverified',()=>{const s=new Stats(0);s.observe(0,0);s.observe(2000,null);s.observe(3000,3);const r=s.summary();assert.equal(r.timestamp_verified,false);assert.equal(r.actual_capture_fps,null);});
test('regressed device timestamps are excluded',()=>{const s=new Stats(0);s.observe(0,10);s.observe(10,9);s.observe(1000,11);s.observe(2000,12);const r=s.summary();assert.equal(r.regressed_timestamps,1);assert.equal(r.acquired_unique_frames,3);assert.equal(r.actual_capture_fps,1);});
test('empty and too-short observations do not claim FPS',()=>{const s=new Stats();assert.equal(s.summary().actual_capture_fps,null);s.observe(100,1);s.observe(150,2);assert.equal(s.summary().actual_capture_fps,null);});
