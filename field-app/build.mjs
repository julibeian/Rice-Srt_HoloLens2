import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {fileURLToPath} from 'node:url';

const root=path.dirname(fileURLToPath(import.meta.url));
const source=process.env.RICE_MINIPROGRAM_ROOT || path.join(root,'upstream-miniprogram');
const output=path.resolve(process.argv[2] || path.join(root,'.state','preview'));
if(!output.startsWith(root+path.sep)) throw new Error('Build output must stay inside field-app.');
fs.mkdirSync(output,{recursive:true});
const pages=['index','history','map','profile'];
const manifest=[];
const read=(name)=>{const data=fs.readFileSync(path.join(source,name));manifest.push({path:name,sha256:crypto.createHash('sha256').update(data).digest('hex')});return data.toString('utf8');};
function copyTree(relative){for(const entry of fs.readdirSync(path.join(source,relative),{withFileTypes:true})){const name=path.join(relative,entry.name);if(entry.isDirectory())copyTree(name);else{const data=fs.readFileSync(path.join(source,name));fs.mkdirSync(path.dirname(path.join(output,name)),{recursive:true});fs.writeFileSync(path.join(output,name),data);manifest.push({path:name.replaceAll('\\','/'),sha256:crypto.createHash('sha256').update(data).digest('hex')});}}}
copyTree('assets');
fs.copyFileSync(path.join(source,'THIRD_PARTY_NOTICES.txt'),path.join(output,'THIRD_PARTY_NOTICES.txt'));

// Compile WXML expressions to ordinary, static JavaScript functions. No eval,
// new Function, remote scripts or WeChat runtime are used on the headset.
function parseWxml(text){
 const root={tag:'block',attrs:{},children:[]}, stack=[root];
 const tokens=text.match(/<!--[\s\S]*?-->|<\/?[\w-]+(?:\s+(?:"[^"]*"|'[^']*'|[^'">])*)?\/?\s*>|[^<]+/g)||[];
 for(const token of tokens){
  if(token.startsWith('<!--'))continue;
  if(token.startsWith('</')){if(stack.length<2)throw new Error('Unbalanced WXML');stack.pop();continue;}
  if(token.startsWith('<')){
   const tag=token.match(/^<([\w-]+)/)[1],attrs={};
   const body=token.slice(tag.length+1).replace(/\/?\s*>$/,'');
   const pattern=/([\w:.-]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+)))?/g;
   let match;while((match=pattern.exec(body)))attrs[match[1]]=match[2]??match[3]??match[4]??true;
   const node={tag,attrs,children:[]};stack.at(-1).children.push(node);
   if(!/\/\s*>$/.test(token))stack.push(node);
  }else if(token.trim())stack.at(-1).children.push({text:token});
 }
 if(stack.length!==1)throw new Error('Unclosed WXML tag '+stack.at(-1).tag);
 return root.children;
}
function value(text){
 if(typeof text!=='string')return JSON.stringify(text);
 const matches=[...text.matchAll(/{{([\s\S]*?)}}/g)];
 if(!matches.length)return JSON.stringify(text.replace(/微信位置授权设置/g,'眼镜位置设置').replace(/本小程序/g,'本应用'));
 const expression=(code)=>`function($){try{with($){return (${code});}}catch(_){return undefined;}}`;
 if(matches.length===1&&matches[0][0]===text)return expression(matches[0][1]);
 let cursor=0,parts=[];
 for(const m of matches){if(m.index>cursor)parts.push(JSON.stringify(text.slice(cursor,m.index)));parts.push(`String(((${expression(m[1])})($)) == null ? '' : ((${expression(m[1])})($)))`);cursor=m.index+m[0].length;}
 if(cursor<text.length)parts.push(JSON.stringify(text.slice(cursor)));
 return `function($){return ${parts.join('+')};}`;
}
function serialize(node){
 if(node.text!==undefined)return `{text:${value(node.text)}}`;
 return `{tag:${JSON.stringify(node.tag)},attrs:{${Object.entries(node.attrs).map(([k,v])=>JSON.stringify(k)+':'+value(v)).join(',')}},children:[${node.children.map(serialize).join(',')}]}`;
}
let templates='window.RiceTemplates={};\n';
for(const name of pages){const id=`pages/${name}/${name}`;templates+=`RiceTemplates[${JSON.stringify(id)}]=[${parseWxml(read(id+'.wxml')).map(serialize).join(',')}];\n`;}
templates+=`RiceTemplates["bottom-navigation"]=[${parseWxml(read('components/bottom-navigation/bottom-navigation.wxml')).map(serialize).join(',')}];\n`;
fs.writeFileSync(path.join(output,'templates.js'),templates);
function legacyCss(text){return text
 .replace(/\binset\s*:\s*0\s*(?=[;}])/g,'top:0;right:0;bottom:0;left:0')
 .replace(/env\(safe-area-inset-(?:top|right|bottom|left)\)/g,'0px')
 .replace(/#([a-f\d]{8}|[a-f\d]{4})\b/gi,(_,hex)=>{if(hex.length===4)hex=[...hex].map(c=>c+c).join('');return `rgba(${parseInt(hex.slice(0,2),16)},${parseInt(hex.slice(2,4),16)},${parseInt(hex.slice(4,6),16)},${+(parseInt(hex.slice(6,8),16)/255).toFixed(4)})`;})
 .replace(/font-weight\s*:\s*(\d+)/g,(_,value)=>'font-weight:'+Math.min(900,Math.max(100,Math.round(Number(value)/100)*100)));}
const css=(text)=>legacyCss(text.replace(/(-?\d*\.?\d+)rpx/g,'$1px').replace(/(^|[\s,])page(?=[\s,{])/g,'$1body').replace(/(^|[\s,])image(?=[\s,{])/g,'$1img').replace(/(^|[\s,])view(?=[\s,{])/g,'$1div').replace(/(^|[\s,])text(?=[\s,{])/g,'$1span').replace(/scroll-view/g,'.wx-scroll'));
fs.writeFileSync(path.join(output,'miniapp.css'),css(read('app.wxss')+'\n'+read('components/bottom-navigation/bottom-navigation.wxss')));
for(const name of pages)fs.writeFileSync(path.join(output,name+'.css'),css(read(`pages/${name}/${name}.wxss`)));

const modules=[];
function collect(relative){for(const e of fs.readdirSync(path.join(source,relative),{withFileTypes:true})){const name=relative+'/'+e.name;if(e.isDirectory())collect(name);else if(e.name.endsWith('.js')){let text=read(name);if(name==='pages/index/index.js')text=text.replace("const PREDICT_URL = API_BASE_URL + '/batch_predict'","const PREDICT_URL = API_BASE_URL + '/hololens-app/api/predict'").replace("const FILE_FIELD_NAME = 'files'","const FILE_FIELD_NAME = 'file'");if(name==='utils/header-layout.js')text='module.exports={headerLayout:function(){return {headerTopInset:20,headerNavHeight:44,headerRightInset:24};}}';modules.push(JSON.stringify(name.slice(0,-3))+':function(require,module,exports){\n'+text+'\n}');}}}
collect('utils');collect('pages');
const loader=`(function(){var modules={${modules.join(',\n')}},cache={};window.RiceRequire=function require(id){if(cache[id])return cache[id].exports;if(!modules[id])throw new Error('Module missing: '+id);var m=cache[id]={exports:{}};modules[id](function(relative){var parts=id.split('/');parts.pop();relative.split('/').forEach(function(p){if(p==='..')parts.pop();else if(p!=='.')parts.push(p);});return require(parts.join('/').replace(/\\.js$/,''));},m,m.exports);return m.exports;};}());`;
fs.writeFileSync(path.join(output,'miniapp.js'),loader);
for(const name of ['index.html','shell.css','renderer.js','capture-quality.js','camera-controls.js','native.js','bridge.js','app.js','boot.js','config.json']){const from=path.join(root,'src',name),to=path.join(output,name);if(name.endsWith('.css'))fs.writeFileSync(to,legacyCss(fs.readFileSync(from,'utf8')));else fs.copyFileSync(from,to);}
if(fs.existsSync(path.join(root,'vendor')))fs.cpSync(path.join(root,'vendor'),path.join(output,'vendor'),{recursive:true});
fs.writeFileSync(path.join(output,'source-manifest.json'),JSON.stringify({source,generatedAt:new Date().toISOString(),files:manifest},null,2));
console.log(JSON.stringify({output,sourceFiles:manifest.length,pages,bytes:fs.statSync(path.join(output,'miniapp.js')).size}));
