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
    }
    // Finds the headset's small, neutral-colour ring. Frame differences reject
    // static circles in the app and in the underlying camera preview.
    public static class PointerLocator {
        static readonly int[,,] Offsets=MakeOffsets();
        static int[,,] MakeOffsets(){var values=new int[4,12,6];for(int r=5;r<=8;r++)for(int a=0;a<12;a++){double angle=a*Math.PI/6;values[r-5,a,0]=(int)Math.Round(r*Math.Cos(angle));values[r-5,a,1]=(int)Math.Round(r*Math.Sin(angle));values[r-5,a,2]=(int)Math.Round((r-3)*Math.Cos(angle));values[r-5,a,3]=(int)Math.Round((r-3)*Math.Sin(angle));values[r-5,a,4]=(int)Math.Round((r+2)*Math.Cos(angle));values[r-5,a,5]=(int)Math.Round((r+2)*Math.Sin(angle));}return values;}
        static byte[] Pixels(Bitmap source,out int stride) {
            using(var copy=new Bitmap(source.Width,source.Height,PixelFormat.Format24bppRgb)) {
                using(var g=Graphics.FromImage(copy))g.DrawImageUnscaled(source,0,0);
                var bits=copy.LockBits(new Rectangle(0,0,copy.Width,copy.Height),ImageLockMode.ReadOnly,PixelFormat.Format24bppRgb);
                stride=bits.Stride;
                var values=new byte[stride*copy.Height];
                Marshal.Copy(bits.Scan0,values,0,values.Length);copy.UnlockBits(bits);return values;
            }
        }
        static double Grey(byte[] pixels,int stride,int x,int y) {
            int i=y*stride+x*3;
            int lo=Math.Min(pixels[i],Math.Min(pixels[i+1],pixels[i+2]));
            int hi=Math.Max(pixels[i],Math.Max(pixels[i+1],pixels[i+2]));
            return hi-lo>55?0:(pixels[i]+pixels[i+1]+pixels[i+2])/3.0;
        }
        public static PointerCandidate Find(Bitmap current,Bitmap previous,PointF? expected,int searchRadius) {
            if(current==null||previous==null||current.Size!=previous.Size)return null;
            int stride,oldStride;var pixels=Pixels(current,out stride);var old=Pixels(previous,out oldStride);
            int left=10,right=current.Width-10,top=10,bottom=current.Height-10;
            if(expected.HasValue){left=Math.Max(left,(int)expected.Value.X-searchRadius);right=Math.Min(right,(int)expected.Value.X+searchRadius);top=Math.Max(top,(int)expected.Value.Y-searchRadius);bottom=Math.Min(bottom,(int)expected.Value.Y+searchRadius);}
            PointerCandidate best=null;
            for(int y=top;y<bottom;y++)for(int x=left;x<right;x++) {
                for(int radius=5;radius<=8;radius++) {
                    int cardinal=0;
                    if(Grey(pixels,stride,x-radius,y)>135)cardinal++;
                    if(Grey(pixels,stride,x+radius,y)>135)cardinal++;
                    if(Grey(pixels,stride,x,y-radius)>135)cardinal++;
                    if(Grey(pixels,stride,x,y+radius)>135)cardinal++;
                    if(cardinal<3)continue;
                    double ring=0,inner=0,outer=0,change=0;int neutral=0;
                    for(int a=0;a<12;a++) {
                        int ri=radius-5,dx=Offsets[ri,a,0],dy=Offsets[ri,a,1];
                        double light=Grey(pixels,stride,x+dx,y+dy);ring+=light;if(light>135)neutral++;
                        inner+=Grey(pixels,stride,x+Offsets[ri,a,2],y+Offsets[ri,a,3]);
                        outer+=Grey(pixels,stride,x+Offsets[ri,a,4],y+Offsets[ri,a,5]);
                        change+=Math.Max(0,light-Grey(old,oldStride,x+dx,y+dy));
                    }
                    ring/=12;inner/=12;outer/=12;change/=12;
                    if(neutral<9||ring<155||ring-inner<32||ring-outer<15||change<18)continue;
                    double score=(ring-inner)*1.5+(ring-outer)*.8+change*.6+neutral*2;
                    if(expected.HasValue){double dx=x-expected.Value.X,dy=y-expected.Value.Y;score-=Math.Sqrt(dx*dx+dy*dy)*.35;}
                    if(best==null||score>best.Score)best=new PointerCandidate{Point=new PointF(x,y),Score=score,Change=change};
                }
            }
            return best;
        }
    }
    public sealed class PointerMap {
        public double OriginX,OriginY,HandX,HandY,Jxx,Jxy,Jyx,Jyy;
        public static PointerMap FromProbes(PointF first,PointF horizontal,PointF vertical,double handX,double handY) {
            var map=new PointerMap{OriginX=first.X,OriginY=first.Y,HandX=handX,HandY=handY,Jxx=(horizontal.X-first.X)/.2,Jyx=(horizontal.Y-first.Y)/.2,Jxy=(vertical.X-first.X)/.17,Jyy=(vertical.Y-first.Y)/.17};
            double determinant=map.Jxx*map.Jyy-map.Jxy*map.Jyx;
            if(Math.Abs(determinant)<40000||Math.Abs(map.Jxx)<100||Math.Abs(map.Jyy)<100)throw new InvalidOperationException("Pointer calibration is inconsistent");
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
