using System;
using System.Drawing;
using System.Diagnostics;
using Rice.HoloLens.Control;
class PointerTests {
    static void Main(string[] args) {
        try{Run(args);}catch(Exception error){Console.WriteLine(error.GetType().Name+": "+error.Message);Environment.ExitCode=1;}
    }
    static void Run(string[] args) {
        var fitted=PointerMap.Fit(new Size(1000,800),new Size(1280,720));
        if(fitted.Width!=1000||fitted.Height!=562||fitted.Y!=119)throw new Exception("Letterbox geometry failed");
        PointF mapped;
        if(PointerMap.TryImagePoint(new Point(500,30),new Size(1000,800),new Size(1280,720),out mapped))throw new Exception("Letterbox must reject input");
        if(!PointerMap.TryImagePoint(new Point(500,400),new Size(1000,800),new Size(1280,720),out mapped)||Math.Abs(mapped.X-640)>1||Math.Abs(mapped.Y-360)>1)throw new Exception("Image coordinate mapping failed");
        var map=PointerMap.FromProbes(new PointF(600,450),new PointF(840,458),new PointF(605,246),-.1,1.55);
        var aimed=map.Aim(new PointF(845,254));
        if(Math.Abs(aimed.X-.1)>0.0001||Math.Abs(aimed.Y-1.72)>0.0001)throw new Exception("Affine pointer mapping failed");
        try {PointerMap.FromProbes(new PointF(10,10),new PointF(10,10),new PointF(10,10),0,0);throw new Exception("Invalid calibration accepted");}catch(InvalidOperationException){}
        try {PointerMap.FromProbes(new PointF(406,391),new PointF(287,402),new PointF(851,235),0,1.5);throw new Exception("Recorded text false positive calibration accepted");}catch(InvalidOperationException){}
        var compact=PointerMap.FromProbes(new PointF(394,267),new PointF(538,271),new PointF(394,154),-.1,1.62,.08,.06);
        if(Math.Abs(compact.Jxx-1800)>1)throw new Exception("Compact probe spacing was not preserved");
        foreach(int width in new[]{854,1280})using(var before=new Bitmap(width,width*9/16))using(var current=new Bitmap(width,width*9/16)){
            var centre=new PointF(width/2,width/4);int radius=(int)Math.Round(6*width/1280.0);
            using(var g=Graphics.FromImage(before))g.Clear(Color.FromArgb(25,40,55));
            using(var g=Graphics.FromImage(current))g.Clear(Color.FromArgb(25,40,55));
            for(int y=-radius-2;y<=radius+2;y++)for(int x=-radius-2;x<=radius+2;x++)if(Math.Abs(Math.Sqrt(x*x+y*y)-radius)<.8)current.SetPixel((int)centre.X+x,(int)centre.Y+y,Color.White);
            var located=PointerLocator.Find(current,before,centre,24);
            if(located==null||Math.Abs(located.Point.X-centre.X)>2||Math.Abs(located.Point.Y-centre.Y)>2)throw new Exception("Resolution-aware ring detection failed");
            if(PointerLocator.Find(current,current,centre,24)!=null)throw new Exception("Static content cannot confirm pointer motion");
        }
        Console.WriteLine("Coordinate mapping, letterbox rejection and degenerate calibration checks passed.");
        if(args.Length==4)using(var current=new Bitmap(args[0]))using(var before=new Bitmap(args[1])) {
            var watch=Stopwatch.StartNew();var expected=new PointF(float.Parse(args[2]),float.Parse(args[3]));
            var result=PointerLocator.Find(current,before,expected,100);
            if(result==null)throw new Exception("Real headset pointer was not located");
            double error=Math.Sqrt(Math.Pow(result.Point.X-expected.X,2)+Math.Pow(result.Point.Y-expected.Y,2));
            Console.WriteLine("Real frame pointer: "+result.Point+"; error="+error.ToString("F1")+" px; elapsed="+watch.ElapsedMilliseconds+" ms");
            if(error>10)throw new Exception("Real headset pointer detection is inaccurate");
            if(PointerLocator.Find(current,current,expected,100)!=null)throw new Exception("Unchanged frame cannot prove a moved pointer");
        }
    }
}
