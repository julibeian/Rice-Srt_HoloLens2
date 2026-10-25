using System;
using System.Drawing;
using System.Diagnostics;
using Rice.HoloLens.Control;
class PointerTests {
    static void Main(string[] args) {
        var fitted=PointerMap.Fit(new Size(1000,800),new Size(1280,720));
        if(fitted.Width!=1000||fitted.Height!=562||fitted.Y!=119)throw new Exception("Letterbox geometry failed");
        PointF mapped;
        if(PointerMap.TryImagePoint(new Point(500,30),new Size(1000,800),new Size(1280,720),out mapped))throw new Exception("Letterbox must reject input");
        if(!PointerMap.TryImagePoint(new Point(500,400),new Size(1000,800),new Size(1280,720),out mapped)||Math.Abs(mapped.X-640)>1||Math.Abs(mapped.Y-360)>1)throw new Exception("Image coordinate mapping failed");
        var map=PointerMap.FromProbes(new PointF(600,450),new PointF(840,458),new PointF(605,246),-.1,1.55);
        var aimed=map.Aim(new PointF(845,254));
        if(Math.Abs(aimed.X-.1)>0.0001||Math.Abs(aimed.Y-1.72)>0.0001)throw new Exception("Affine pointer mapping failed");
        try {PointerMap.FromProbes(new PointF(10,10),new PointF(10,10),new PointF(10,10),0,0);throw new Exception("Invalid calibration accepted");}catch(InvalidOperationException){}
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
