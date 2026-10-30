using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using Rice.HoloLens.Control;

class VideoFrameTests {
    static int passed;
    static void Check(bool value,string label){if(!value)throw new Exception(label);passed++;}
    sealed class Fragmented : MemoryStream {public Fragmented(byte[] bytes):base(bytes){}public override int Read(byte[] buffer,int offset,int count){return base.Read(buffer,offset,Math.Min(7,count));}}
    static void Main(){
        var data=new byte[128];for(int i=0;i<data.Length;i++)data[i]=(byte)i;
        var target=new byte[128];using(var stream=new Fragmented(data)){Check(VideoFrameStore.ReadFrame(stream,target)&&target[127]==127,"fragmented reads must assemble exactly one frame");Check(!VideoFrameStore.ReadFrame(stream,target),"clean EOF is distinct from a partial frame");}
        bool truncated=false;try{using(var stream=new Fragmented(new byte[127]))VideoFrameStore.ReadFrame(stream,target);}catch(InvalidDataException){truncated=true;}Check(truncated,"truncated raw frame must be rejected");
        using(var store=new VideoFrameStore(32,18,1,3)){
            var one=store.Rent();one.Pixels[0]=41;store.Publish(one,1,Stopwatch.GetTimestamp());
            using(var held=store.AcquireLatest()){
                for(int i=2;i<300;i++){var next=store.Rent();Check(next!=null,"pool reuses released slots");next.Pixels[0]=(byte)i;store.Publish(next,i,Stopwatch.GetTimestamp());}
                Check(held.Pixels[0]==41&&held.Sequence==1,"reader must keep an immutable old frame during publication");
                using(var latest=store.AcquireLatest()){Check(latest.Sequence==299,"latest-only consumer must not queue old frames");Check(store.AcquireLatest(299)==null,"unchanged sequence must not masquerade as a new frame");}
            }
        }
        var disposedStore=new VideoFrameStore(32,18,2,2);var frame=disposedStore.Rent();frame.Pixels[0]=99;disposedStore.Publish(frame,1,Stopwatch.GetTimestamp());var retained=disposedStore.AcquireLatest();disposedStore.Dispose();Check(retained.Pixels[0]==99,"shutdown must not unpin a frame still used by a renderer");retained.Dispose();Check(disposedStore.Rent()==null,"closed store must not rent frames");
        using(var store=new VideoFrameStore(16,16,3,2)){
            var a=store.Rent();var b=store.Rent();Check(store.Rent()==null,"pool must remain bounded when readers hold all slots");a.Dispose();b.Dispose();
        }
        using(var store=new VideoFrameStore(32,18,5)){
            var next=store.Rent();for(int i=0;i<next.Pixels.Length;i+=4){next.Pixels[i]=30;next.Pixels[i+1]=60;next.Pixels[i+2]=190;next.Pixels[i+3]=255;}
            next.Pixels[0]=220;next.Pixels[1]=210;next.Pixels[2]=200;store.Publish(next,1,Stopwatch.GetTimestamp());
            using(var held=store.AcquireLatest())using(var targetImage=new Bitmap(64,36)){
                using(var graphics=Graphics.FromImage(targetImage))Check(held.Draw(graphics,new Rectangle(0,0,64,36)),"native frame rendering must succeed");
                Check(targetImage.GetPixel(32,18).R==190&&targetImage.GetPixel(32,18).B==30,"native BGRA channels must match");
                Check(targetImage.GetPixel(0,0).R==200&&targetImage.GetPixel(0,0).B==220,"native top-down frame orientation must match");
            }
        }
        using(var store=new VideoFrameStore(32,18,4)){
            var producer=Task.Run(()=>{for(int i=1;i<=1000;i++){var next=store.Rent();while(next==null){Thread.Yield();next=store.Rent();}for(int j=0;j<next.Pixels.Length;j++)next.Pixels[j]=(byte)i;store.Publish(next,i,Stopwatch.GetTimestamp());}});
            int reads=0;while(!producer.IsCompleted){using(var current=store.AcquireLatest()){if(current==null)continue;byte expected=current.Pixels[0];Thread.SpinWait(1000);for(int i=0;i<current.Pixels.Length;i++)if(current.Pixels[i]!=expected)throw new Exception("frame was reused while retained");reads++;}}producer.GetAwaiter().GetResult();Check(reads>0,"concurrent producer and renderer exercised");
        }
        foreach(double dpi in new[]{1.0,1.25,1.5,2.0})foreach(Size image in new[]{new Size(896,504),new Size(1280,720)}){
            var viewport=new Size((int)(970*dpi),(int)(620*dpi));PointF mapped;Check(PointerMap.TryImagePoint(new Point(viewport.Width/2,viewport.Height/2),viewport,image,out mapped)&&Math.Abs(mapped.X-image.Width/2f)<2&&Math.Abs(mapped.Y-image.Height/2f)<2,"DPI and letterbox coordinates stay in image pixels");
        }
        Check(!VideoProfile.Interactive.DecoderArguments.Contains("fps=")&&!VideoProfile.Interactive.DecoderArguments.Contains("mjpeg")&&VideoProfile.Interactive.DecoderArguments.Contains("rawvideo"),"interactive profile must not re-encode JPEG or impose a frame-rate cap");
        Console.WriteLine("Video ownership, framing, concurrency, bounded pool and DPI checks passed: "+passed);
    }
}
