import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {fileURLToPath} from 'node:url';

const root=path.dirname(fileURLToPath(import.meta.url));
const output=path.resolve(process.argv[2]||path.join(root,'.state','preview'));
if(!output.startsWith(root+path.sep))throw new Error('Build output must stay inside apps/field-app.');
fs.mkdirSync(output,{recursive:true});
const manifest=[];
function copy(from,to){const bytes=fs.readFileSync(from);fs.mkdirSync(path.dirname(to),{recursive:true});fs.writeFileSync(to,bytes);manifest.push({path:path.relative(root,from).replaceAll('\\','/'),sha256:crypto.createHash('sha256').update(bytes).digest('hex')});}
for(const name of ['index.html','shell.css','boot.js','camera-controls.js','dynamic.js','native.js','app.js','config.json'])copy(path.join(root,'src',name),path.join(output,name));
copy(path.join(root,'upstream-miniprogram/assets/brand-logo.png'),path.join(output,'assets/brand-logo.png'));
const samples=process.env.RICE_YOLO_SAMPLES||'E:/微信小程序开发软件/srt-rice/手机端可跑版/samples';
for(const name of ['bacterial_blight_0.jpg','brown_spot_0.jpg','rice_blast_0.jpg','rice_water_weevil_0.jpg'])copy(path.join(samples,name),path.join(output,'assets/yolo-samples',name));
fs.writeFileSync(path.join(output,'source-manifest.json'),JSON.stringify({generatedAt:new Date().toISOString(),recognitionMode:'local-yolo',files:manifest},null,2));
console.log(JSON.stringify({output,sourceFiles:manifest.length,recognitionMode:'local-yolo'}));
