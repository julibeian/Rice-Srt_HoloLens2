#ifndef RICE_YOLO_CORE_H
#define RICE_YOLO_CORE_H
#ifndef YOLO_SIDE
#define YOLO_SIDE 640
#endif
#define YOLO_ANCHORS ((YOLO_SIDE/8)*(YOLO_SIDE/8)+(YOLO_SIDE/16)*(YOLO_SIDE/16)+(YOLO_SIDE/32)*(YOLO_SIDE/32))
#define YOLO_OUTPUTS (YOLO_ANCHORS*10)
#define YOLO_CANDIDATES 1024
#define YOLO_DETECTIONS 100
typedef struct {float x1,y1,x2,y2,score;int class_id;} YoloBox;
static double y_min(double a,double b){return a<b?a:b;}
static double y_max(double a,double b){return a>b?a:b;}
static double y_clip(double v,double lo,double hi){return y_max(lo,y_min(v,hi));}
static int y_finite(float f){union{float f;unsigned int u;}x={f};return (x.u&0x7f800000u)!=0x7f800000u;}
/* RGBA8 source -> fixed-size RGB NCHW, half-pixel bilinear, letterbox114, /255. */
static void y_letterbox(const unsigned char*rgba,int width,int height,float*out){
 double ratio=y_min((double)YOLO_SIDE/width,(double)YOLO_SIDE/height);
 int nw=(int)(width*ratio+.5),nh=(int)(height*ratio+.5),px=(YOLO_SIDE-nw)/2,py=(YOLO_SIDE-nh)/2;
 const int area=YOLO_SIDE*YOLO_SIDE;
 for(int i=0;i<area*3;i++)out[i]=114.0f/255.0f;
 for(int y=0;y<nh;y++){
  double sy=y_clip((y+.5)/ratio-.5,0,height-1);int y0=(int)sy,y1=y0+1<height?y0+1:y0;double fy=sy-y0;
  for(int x=0;x<nw;x++){
   double sx=y_clip((x+.5)/ratio-.5,0,width-1);int x0=(int)sx,x1=x0+1<width?x0+1:x0;double fx=sx-x0;
   int pos=(y+py)*YOLO_SIDE+x+px;
   for(int c=0;c<3;c++){
    double p00=rgba[(y0*width+x0)*4+c],p01=rgba[(y0*width+x1)*4+c];
    double p10=rgba[(y1*width+x0)*4+c],p11=rgba[(y1*width+x1)*4+c];
    double top=p00+(p01-p00)*fx,bot=p10+(p11-p10)*fx;
    out[c*area+pos]=(float)((top+(bot-top)*fy)/255.0);
   }
  }
 }
}
static float y_iou(YoloBox a,YoloBox b){
 double iw=y_max(0,y_min(a.x2,b.x2)-y_max(a.x1,b.x1)),ih=y_max(0,y_min(a.y2,b.y2)-y_max(a.y1,b.y1));
 double inter=iw*ih,area=(a.x2-a.x1)*(a.y2-a.y1)+(b.x2-b.x1)*(b.y2-b.y1)-inter;
 return area>0?(float)(inter/area):0;
}
static int y_decode(const float*raw,int width,int height,float threshold,float overlap,YoloBox*candidates,YoloBox*result){
 int count=0;
 for(int a=0;a<YOLO_ANCHORS;a++){
  float score=0;int cls=-1;
  for(int c=0;c<6;c++){float v=raw[(4+c)*YOLO_ANCHORS+a];if(v>score&&v<=1){score=v;cls=c;}}
  if(cls<0||score<threshold)continue;
  float cx=raw[a],cy=raw[YOLO_ANCHORS+a],w=raw[2*YOLO_ANCHORS+a],h=raw[3*YOLO_ANCHORS+a];
  if(!y_finite(cx)||!y_finite(cy)||!y_finite(w)||!y_finite(h)||w<=0||h<=0)continue;
  int pos=count;while(pos>0&&candidates[pos-1].score<score)pos--;
  if(pos>=YOLO_CANDIDATES)continue;
  int end=count<YOLO_CANDIDATES?count:YOLO_CANDIDATES-1;
  for(int i=end;i>pos;i--)candidates[i]=candidates[i-1];
  candidates[pos]=(YoloBox){cx-w/2,cy-h/2,cx+w/2,cy+h/2,score,cls};if(count<YOLO_CANDIDATES)count++;
 }
 int kept=0;
 for(int i=0;i<count&&kept<YOLO_DETECTIONS;i++){
  int discard=0;for(int j=0;j<kept;j++)if(result[j].class_id==candidates[i].class_id&&y_iou(result[j],candidates[i])>overlap){discard=1;break;}
  if(!discard)result[kept++]=candidates[i];
 }
 double ratio=y_min((double)YOLO_SIDE/width,(double)YOLO_SIDE/height);
 int px=(YOLO_SIDE-(int)(width*ratio+.5))/2,py=(YOLO_SIDE-(int)(height*ratio+.5))/2;
 for(int i=0;i<kept;i++){
  result[i].x1=(float)y_clip((result[i].x1-px)/ratio,0,width);result[i].x2=(float)y_clip((result[i].x2-px)/ratio,0,width);
  result[i].y1=(float)y_clip((result[i].y1-py)/ratio,0,height);result[i].y2=(float)y_clip((result[i].y2-py)/ratio,0,height);
 }
 return kept;
}
#endif
