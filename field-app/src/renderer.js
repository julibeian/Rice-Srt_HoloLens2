(function(root){
 'use strict';
 var tagMap={view:'div',text:'span',image:'img','cover-view':'div','cover-image':'img','scroll-view':'div',block:null,map:'div'};
 function val(v,s){return typeof v==='function'?v(s):v;}
 function attrs(node,s){var a={};Object.keys(node.attrs||{}).forEach(function(k){if(k.indexOf('wx:')!==0)a[k]=val(node.attrs[k],s);});return a;}
 function eventObject(e){return {type:e.type,detail:{value:e.target.value,scrollTop:e.currentTarget.scrollTop||0,height:0},currentTarget:{dataset:e.currentTarget.dataset},target:{dataset:e.target.dataset}};}
 function build(nodes,s,page){var out=[],branch=false;
  nodes.forEach(function(n){
   if(n.text!==undefined){var t=val(n.text,s);if(t!=null&&String(t).trim())out.push({text:String(t)});return;}
   var a=n.attrs||{},values=a['wx:for']!==undefined?val(a['wx:for'],s):null;
   var renderOne=function(scope,index){
    if(a['wx:if']!==undefined){branch=!!val(a['wx:if'],scope);if(!branch)return;}
    else if(a['wx:elif']!==undefined){if(branch)return;branch=!!val(a['wx:elif'],scope);if(!branch)return;}
    else if(a['wx:else']!==undefined){if(branch)return;branch=true;}else branch=false;
    var at=attrs(n,scope),children=build(n.children||[],scope,page);
    if(n.tag==='block'){out.push.apply(out,children);return;}
    if(n.tag==='bottom-navigation'){
     var component={data:{active:at.active},onNavigate:function(e){var target=e.currentTarget.dataset.target;var routes={home:'/pages/index/index',history:root.RiceRequire('utils/navigation-state').historyDestination(root.wx),map:'/pages/map/map'};if(target&&target!==at.active&&routes[target])root.wx.redirectTo({url:routes[target]});}};
     out.push.apply(out,build(root.RiceTemplates['bottom-navigation'],component.data,component));return;
    }
    var events={};Object.keys(at).forEach(function(k){var m=k.match(/^(bind|catch)(?::)?(tap|input|focus|blur|scroll|change|touchmove|keyboardheightchange)$/);if(!m)return;var type={tap:'click',touchmove:'pointermove',keyboardheightchange:'focus'}[m[2]]||m[2];var handler=at[k];events[type]=function(e){if(m[1]==='catch')e.stopPropagation();if(typeof page[handler]==='function')page[handler](eventObject(e));};delete at[k];});
    if(n.tag==='scroll-view')at.class=(at.class||'')+' wx-scroll';
    if(n.tag==='map'){at.class=(at.class||'')+' native-map';children.unshift({tag:'div',attrs:{class:'map-engine'},children:[],managed:true});}
    var key=a['wx:key']&&a['wx:key']!=='index'?(a['wx:key']==='*this'?scope[a['wx:for-item']||'item']:(scope[a['wx:for-item']||'item']||{})[a['wx:key']]):index;
    out.push({tag:tagMap[n.tag]===undefined?n.tag:tagMap[n.tag],attrs:at,events:events,children:children,key:key,map:n.tag==='map'?{attrs:at,page:page,callout:nodeEvent(a,'bindcallouttap'),region:nodeEvent(a,'bindregionchange')}:null});
   };
   if(values&&typeof values.forEach==='function')values.forEach(function(item,index){var local=Object.assign({},s);local[a['wx:for-item']||'item']=item;local[a['wx:for-index']||'index']=index;renderOne(local,index);});
   else if(a['wx:for']===undefined)renderOne(s);
  });return out;
 }
 function nodeEvent(a,k){return a[k];}
 function apply(el,v,old){
  var a=v.attrs||{},before=old&&old.attrs||{};
  Object.keys(before).forEach(function(k){if(!(k in a)&&k.indexOf('bind')!==0)el.removeAttribute(k);});
  Object.keys(a).forEach(function(k){var value=a[k];if(k==='src'&&value&&root.RiceNative)value=RiceNative.imageUrl(value);
   if(k==='style')value=String(value||'').replace(/(-?\d*\.?\d+)rpx/g,'$1px');
   if(k==='disabled'||k==='hidden'){el[k]=!!value;return;}
   if(k==='value'){if(el.value!==String(value==null?'':value))el.value=value==null?'':value;return;}
   if(k==='scroll-top'){if(before[k]!==value&&Number.isFinite(Number(value)))el.scrollTop=Number(value);return;}
   if(k==='scroll-into-view'){if(value&&value!==before[k])setTimeout(function(){var target=document.getElementById(value);if(target)target.scrollIntoView({block:'nearest'});},0);return;}
   if(k==='mode'){el.style.objectFit=value==='aspectFill'?'cover':'contain';return;}
   if(k.indexOf('bind')===0||k==='markers'||k==='type'&&el.tagName==='CANVAS')return;
   if(value!==false&&value!=null)el.setAttribute(k,value===true?'':String(value));else el.removeAttribute(k);
  });
  el._riceHandlers=v.events||{};Object.keys(el._riceHandlers).forEach(function(type){if(!el._riceEvents)el._riceEvents={};if(!el._riceEvents[type]){el._riceEvents[type]=true;el.addEventListener(type,function(e){var f=el._riceHandlers[type];if(f)f(e);});}});
  if(el.tagName==='CANVAS'&&!el.createImage)el.createImage=function(){return new Image();};
  if((a['aria-role']==='button'||(v.events||{}).click)&&el.tagName!=='BUTTON'){el.setAttribute('role','button');el.tabIndex=0;if(!el._riceKey){el._riceKey=true;el.addEventListener('keydown',function(e){if(e.key==='Enter'||e.key===' '){e.preventDefault();el.click();}});}}
 }
 function patch(parent,index,v){var el=parent.childNodes[index],old=el&&el._riceVNode;
  if(!el||!old||(v.text!==undefined)!==(old.text!==undefined)||v.tag!==old.tag||(v.key!==undefined&&old.key!==v.key)){
   var next=v.text!==undefined?document.createTextNode(v.text):document.createElement(v.tag||'div');if(el)parent.replaceChild(next,el);else parent.appendChild(next);el=next;old=null;
  }
  if(v.text!==undefined){if(el.nodeValue!==v.text)el.nodeValue=v.text;el._riceVNode=v;return;}
  apply(el,v,old);el._riceVNode=v;
  if(!v.managed){(v.children||[]).forEach(function(c,i){patch(el,i,c);});while(el.childNodes.length>(v.children||[]).length)el.removeChild(el.lastChild);}
  if(v.map)el._riceMap=v.map;
 }
 root.RiceRender=function(container,template,data,page){var list=build(template,data,page);list.forEach(function(v,i){patch(container,i,v);});while(container.childNodes.length>list.length)container.removeChild(container.lastChild);if(root.RiceMap)RiceMap.refresh(container);};
}(window));
