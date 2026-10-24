/* Deterministic camera geometry and quality checks. No learned disease labels. */
(function(root,factory){var api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.RiceCaptureQuality=api;}(typeof window==='object'?window:this,function(){
 'use strict';
 function clamp(value,min,max){return Math.max(min,Math.min(max,value));}
 function finite(value){return typeof value==='number'&&Number.isFinite(value);}
 function dimensions(width,height){if(!finite(width)||!finite(height)||width<=0||height<=0)throw new Error('相机尚未提供有效画面');}
 function fit(width,height,boxWidth,boxHeight){dimensions(width,height);dimensions(boxWidth,boxHeight);var scale=Math.min(boxWidth/width,boxHeight/height),w=width*scale,h=height*scale;return {x:(boxWidth-w)/2,y:(boxHeight-h)/2,width:w,height:h};}
 function region(width,height,point,fraction){dimensions(width,height);point=point||{x:.5,y:.5};var side=Math.min(width,height)*clamp(fraction||.65,.25,.95),w=side/width,h=side/height;return {x:clamp(finite(point.x)?point.x:.5,w/2,1-w/2)-w/2,y:clamp(finite(point.y)?point.y:.5,h/2,1-h/2)-h/2,width:w,height:h};}
 function validate(rect){if(!rect||!['x','y','width','height'].every(function(key){return finite(rect[key]);})||rect.x<0||rect.y<0||rect.width<=0||rect.height<=0||rect.x+rect.width>1.000001||rect.y+rect.height>1.000001)throw new Error('取景区域无效，请重新对准');return rect;}
 function pixels(rect,width,height){validate(rect);dimensions(width,height);var x=clamp(Math.floor(rect.x*width),0,width-1),y=clamp(Math.floor(rect.y*height),0,height-1);return {x:x,y:y,width:Math.max(1,Math.min(width-x,Math.round(rect.width*width))),height:Math.max(1,Math.min(height-y,Math.round(rect.height*height)))};}
 function point(clientX,clientY,box,width,height){var area=fit(width,height,box.width,box.height),x=clientX-box.left-area.x,y=clientY-box.top-area.y;if(x<0||y<0||x>area.width||y>area.height)return null;return {x:x/area.width,y:y/area.height};}
 function measure(image){
  var w=image.width,h=image.height,data=image.data;dimensions(w,h);if(!data||data.length!==w*h*4||w<4||h<4)throw new Error('无法读取清晰度数据');
  var grey=new Float32Array(w*h),sum=0,squared=0,high=0,dark=0,targetSum=0,targetHigh=0,targetCount=0;
  for(var i=0;i<grey.length;i++){var at=i*4,value=(data[at]*.299+data[at+1]*.587+data[at+2]*.114)/255;grey[i]=value;sum+=value;squared+=value*value;if(value>.97)high++;if(value<.035)dark++;var px=i%w,py=Math.floor(i/w);if(px>=w*.2&&px<w*.8&&py>=h*.2&&py<h*.8){targetSum+=value;targetCount++;if(value>.97)targetHigh++;}}
  var lap=0,lapSquared=0,n=0;for(var y=1;y<h-1;y++)for(var x=1;x<w-1;x++){var p=y*w+x,v=grey[p-1]+grey[p+1]+grey[p-w]+grey[p+w]-4*grey[p];lap+=v;lapSquared+=v*v;n++;}
  var signature=new Float32Array(32*32);for(var sy=0;sy<32;sy++)for(var sx=0;sx<32;sx++){var total=0,k=0,x0=Math.floor(sx*w/32),x1=Math.max(x0+1,Math.floor((sx+1)*w/32)),y0=Math.floor(sy*h/32),y1=Math.max(y0+1,Math.floor((sy+1)*h/32));for(var yy=y0;yy<Math.min(y1,h);yy++)for(var xx=x0;xx<Math.min(x1,w);xx++){total+=grey[yy*w+xx];k++;}signature[sy*32+sx]=total/k;}
  var mean=sum/grey.length;return {mean:mean,targetMean:targetSum/targetCount,targetHighlights:targetHigh/targetCount,contrast:Math.sqrt(Math.max(0,squared/grey.length-mean*mean)),highlights:high/grey.length,shadows:dark/grey.length,sharpness:Math.max(0,lapSquared/n-Math.pow(lap/n,2))*65025,signature:signature};
 }
 function motion(a,b){if(!a||!b||a.length!==b.length)return Infinity;var sum=0,offset=0;for(var i=0;i<a.length;i++)offset+=a[i]-b[i];offset/=a.length;for(var j=0;j<a.length;j++)sum+=Math.abs(a[j]-b[j]-offset);return sum/a.length;}
 function assess(metrics){if(metrics.mean<.09||metrics.shadows>.87)return {ok:false,reason:'dark',message:'目标太暗，请增加照明'};if(metrics.mean>.94||metrics.highlights>.35)return {ok:false,reason:'bright',message:'目标过亮，请降低屏幕亮度或避开反光'};if(metrics.contrast<.035||metrics.sharpness<18)return {ok:false,reason:'blur',message:'目标还不清楚，请稳住并稍微调整距离'};return {ok:true,reason:'ready',message:'画面清晰'};}
 function exposure(metrics){var mean=finite(metrics.targetMean)?metrics.targetMean:metrics.mean,high=finite(metrics.targetHighlights)?metrics.targetHighlights:metrics.highlights;if(high>.16||mean>.74)return {direction:-1,message:'目标过亮，正在降低曝光…'};if(mean<.24&&high<.1)return {direction:1,message:'目标偏暗，正在增加曝光…'};return {direction:0,message:'亮度已稳定'};}
 function summary(m){return {mean:Number(m.mean.toFixed(3)),targetMean:Number(m.targetMean.toFixed(3)),targetHighlights:Number(m.targetHighlights.toFixed(3)),contrast:Number(m.contrast.toFixed(3)),highlights:Number(m.highlights.toFixed(3)),sharpness:Number(m.sharpness.toFixed(2))};}
 return {fit:fit,region:region,validate:validate,pixels:pixels,point:point,measure:measure,motion:motion,assess:assess,exposure:exposure,summary:summary};
}));
