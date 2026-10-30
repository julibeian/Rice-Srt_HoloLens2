using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

namespace Rice.HoloLens.Control {
    public sealed class PointerCandidate {
        public PointF Point;
        public double Score;
        public double Change;
        public double HandX,HandY;
    }
    // Finds the headset's small, neutral-colour ring. Frame differences reject
    // static circles in the app and in the underlying camera preview.
    public static class PointerLocator {
        static readonly int[,,] Offsets=MakeOffsets();
        static int[,,] MakeOffsets(){var values=new int[8,12,6];for(int r=3;r<=10;r++)for(int a=0;a<12;a++){double angle=a*Math.PI/6;values[r-3,a,0]=(int)Math.Round(r*Math.Cos(angle));values[r-3,a,1]=(int)Math.Round(r*Math.Sin(angle));values[r-3,a,2]=(int)Math.Round(Math.Max(1,r-2)*Math.Cos(angle));values[r-3,a,3]=(int)Math.Round(Math.Max(1,r-2)*Math.Sin(angle));values[r-3,a,4]=(int)Math.Round((r+2)*Math.Cos(angle));values[r-3,a,5]=(int)Math.Round((r+2)*Math.Sin(angle));}return values;}
        static byte[] Pixels(Bitmap source,out int stride) {
            using(var copy=new Bitmap(source.Width,source.Height,PixelFormat.Format32bppArgb)) {
                using(var g=Graphics.FromImage(copy))g.DrawImageUnscaled(source,0,0);
                var bits=copy.LockBits(new Rectangle(0,0,copy.Width,copy.Height),ImageLockMode.ReadOnly,PixelFormat.Format32bppArgb);
                stride=bits.Stride;
                var values=new byte[stride*copy.Height];
                Marshal.Copy(bits.Scan0,values,0,values.Length);copy.UnlockBits(bits);return values;
            }
        }
        static double Grey(byte[] pixels,int stride,int x,int y) {
            int i=y*stride+x*4;
            int lo=Math.Min(pixels[i],Math.Min(pixels[i+1],pixels[i+2]));
            int hi=Math.Max(pixels[i],Math.Max(pixels[i+1],pixels[i+2]));
            return hi-lo>55?0:(pixels[i]+pixels[i+1]+pixels[i+2])/3.0;
        }
        public static PointerCandidate Find(Bitmap current,Bitmap previous,PointF? expected,int searchRadius) {
            if(current==null||previous==null||current.Size!=previous.Size)return null;
            int stride,oldStride;var pixels=Pixels(current,out stride);var old=Pixels(previous,out oldStride);
            return FindPixels(pixels,old,current.Width,current.Height,stride,oldStride,expected,searchRadius);
        }
        public static PointerCandidate Find(VideoFrame current,VideoFrame previous,PointF? expected,int searchRadius){
            if(current==null||previous==null||current.Width!=previous.Width||current.Height!=previous.Height)return null;
            return FindPixels(current.Pixels,previous.Pixels,current.Width,current.Height,current.Stride,previous.Stride,expected,searchRadius);
        }
        public static bool HasRing(VideoFrame current,PointF point){
            int radius=Math.Max(3,(int)Math.Round(8*current.Width/1280.0));
            return FindPixels(current.Pixels,null,current.Width,current.Height,current.Stride,0,point,radius)!=null;
        }
        static PointerCandidate FindPixels(byte[] pixels,byte[] old,int width,int height,int stride,int oldStride,PointF? expected,int searchRadius){
            int left=10,right=width-10,top=10,bottom=height-10;
            if(expected.HasValue){left=Math.Max(left,(int)expected.Value.X-searchRadius);right=Math.Min(right,(int)expected.Value.X+searchRadius);top=Math.Max(top,(int)expected.Value.Y-searchRadius);bottom=Math.Min(bottom,(int)expected.Value.Y+searchRadius);}
            PointerCandidate best=null,runner=null;
            int minRadius=Math.Max(3,(int)Math.Floor(5*width/1280.0)),maxRadius=Math.Min(10,(int)Math.Ceiling(8*width/1280.0));
            for(int y=top;y<bottom;y++)for(int x=left;x<right;x++) {
                for(int radius=minRadius;radius<=maxRadius;radius++) {
                    int cardinal=0;
                    if(Grey(pixels,stride,x-radius,y)>135)cardinal++;
                    if(Grey(pixels,stride,x+radius,y)>135)cardinal++;
                    if(Grey(pixels,stride,x,y-radius)>135)cardinal++;
                    if(Grey(pixels,stride,x,y+radius)>135)cardinal++;
                    if(cardinal<3)continue;
                    double ring=0,inner=0,outer=0,change=0;int neutral=0,changed=0;
                    for(int a=0;a<12;a++) {
                        int ri=radius-3,dx=Offsets[ri,a,0],dy=Offsets[ri,a,1];
                        double light=Grey(pixels,stride,x+dx,y+dy);ring+=light;if(light>135)neutral++;
                        inner+=Grey(pixels,stride,x+Offsets[ri,a,2],y+Offsets[ri,a,3]);
                        outer+=Grey(pixels,stride,x+Offsets[ri,a,4],y+Offsets[ri,a,5]);
                        if(old!=null){double delta=light-Grey(old,oldStride,x+dx,y+dy);change+=Math.Max(0,delta);if(delta>40)changed++;}
                    }
                    ring/=12;inner/=12;outer/=12;change/=12;
                    if(neutral<9||ring<155||ring-inner<32||ring-outer<15||(old!=null&&(change<50||changed<7)))continue;
                    double score=(ring-inner)*1.5+(ring-outer)*.8+change*.6+neutral*2;
                    if(expected.HasValue){double dx=x-expected.Value.X,dy=y-expected.Value.Y;score-=Math.Sqrt(dx*dx+dy*dy)*.35;}
                    var candidate=new PointerCandidate{Point=new PointF(x,y),Score=score,Change=change};
                    if(best==null||score>best.Score){if(best!=null&&Distance(best.Point,candidate.Point)>maxRadius*2)runner=best;best=candidate;}
                    else if(Distance(best.Point,candidate.Point)>maxRadius*2&&(runner==null||score>runner.Score))runner=candidate;
                }
            }
            if(old!=null&&best!=null&&runner!=null&&runner.Score>best.Score*.94)return null;
            return best;
        }
        static double Distance(PointF a,PointF b){return Math.Sqrt(Math.Pow(a.X-b.X,2)+Math.Pow(a.Y-b.Y,2));}
    }
    public sealed class PointerMap {
        public double OriginX,OriginY,HandX,HandY,Jxx,Jxy,Jyx,Jyy;
        public static PointerMap FromProbes(PointF first,PointF horizontal,PointF vertical,double handX,double handY,double horizontalStep=.2,double verticalStep=.17) {
            if(horizontalStep<=0||verticalStep<=0)throw new InvalidOperationException("Invalid probe step");
            var map=new PointerMap{OriginX=first.X,OriginY=first.Y,HandX=handX,HandY=handY,Jxx=(horizontal.X-first.X)/horizontalStep,Jyx=(horizontal.Y-first.Y)/horizontalStep,Jxy=(vertical.X-first.X)/verticalStep,Jyy=(vertical.Y-first.Y)/verticalStep};
            double determinant=map.Jxx*map.Jyy-map.Jxy*map.Jyx;
            if(Math.Abs(determinant)<40000||map.Jxx<100||map.Jyy>-100||Math.Abs(map.Jxy)>Math.Abs(map.Jxx)*.65||Math.Abs(map.Jyx)>Math.Abs(map.Jyy)*.65)throw new InvalidOperationException("Pointer calibration is inconsistent; input rejected");
            return map;
        }
        public PointF Delta(double x,double y) {
            double determinant=Jxx*Jyy-Jxy*Jyx;
            return new PointF((float)((Jyy*x-Jxy*y)/determinant),(float)((Jxx*y-Jyx*x)/determinant));
        }
        public PointF Aim(PointF target) {var delta=Delta(target.X-OriginX,target.Y-OriginY);return new PointF((float)(HandX+delta.X),(float)(HandY+delta.Y));}
        public static Rectangle Fit(Size viewport,Size image) {
            if(viewport.Width<=0||viewport.Height<=0||image.Width<=0||image.Height<=0)return Rectangle.Empty;
            double scale=Math.Min((double)viewport.Width/image.Width,(double)viewport.Height/image.Height);
            int width=(int)Math.Round(image.Width*scale),height=(int)Math.Round(image.Height*scale);
            return new Rectangle((viewport.Width-width)/2,(viewport.Height-height)/2,width,height);
        }
        public static bool TryImagePoint(Point point,Size viewport,Size image,out PointF result) {
            var box=Fit(viewport,image);result=PointF.Empty;
            if(box.IsEmpty||!box.Contains(point))return false;
            result=new PointF((float)(point.X-box.X)*image.Width/box.Width,(float)(point.Y-box.Y)*image.Height/box.Height);return true;
        }
    }
}
