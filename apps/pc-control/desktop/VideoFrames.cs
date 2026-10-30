using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

namespace Rice.HoloLens.Control {
    public sealed class VideoProfile {
        public readonly string Name,Endpoint;
        public readonly int Width,Height;
        VideoProfile(string name,string endpoint,int width,int height){Name=name;Endpoint=endpoint;Width=width;Height=height;}
        public static readonly VideoProfile Interactive=new VideoProfile("交互", "live_med.mp4",854,480);
        public static readonly VideoProfile Detail=new VideoProfile("高清", "live_high.mp4",1280,720);
        public string DecoderArguments {get{return "-hide_banner -loglevel warning -fflags nobuffer -flags low_delay -probesize 65536 -analyzeduration 0 -threads 2 -i pipe:0 -an -vf scale="+Width+":"+Height+" -vsync 0 -enc_time_base -1 -pix_fmt bgra -c:v rawvideo -threads 2 -f rawvideo pipe:1";}}
    }

    // A slot is writable only with one producer reference. After publication all
    // leases are read-only. Replaced frames return to the pool after the LAST
    // renderer, locator or screenshot reader releases them.
    internal sealed class VideoSlot {
        internal readonly byte[] Bytes;
        internal readonly Bitmap Image;
        internal readonly object DrawingSync=new object();
        internal GCHandle Pin;
        internal int References;
        internal long Sequence,ReceivedTicks;
        internal readonly VideoFrameStore Store;
        internal VideoSlot(VideoFrameStore store,int width,int height){Store=store;Bytes=new byte[checked(width*height*4)];Pin=GCHandle.Alloc(Bytes,GCHandleType.Pinned);Image=new Bitmap(width,height,width*4,PixelFormat.Format32bppArgb,Pin.AddrOfPinnedObject());}
        internal void Destroy(){Image.Dispose();if(Pin.IsAllocated)Pin.Free();}
    }
    public sealed class VideoFrame : IDisposable {
        VideoSlot slot;
        internal VideoFrame(VideoSlot value){slot=value;}
        internal VideoSlot Slot {get{if(slot==null)throw new ObjectDisposedException("VideoFrame");return slot;}}
        public byte[] Pixels {get{return Slot.Bytes;}}
        public Bitmap Image {get{return Slot.Image;}}
        public object DrawingSync {get{return Slot.DrawingSync;}}
        public int Width {get{return Slot.Store.Width;}}
        public int Height {get{return Slot.Store.Height;}}
        public int Stride {get{return Width*4;}}
        public long Sequence {get{return Slot.Sequence;}}
        public long ReceivedTicks {get{return Slot.ReceivedTicks;}}
        public double AgeSeconds {get{return (Stopwatch.GetTimestamp()-ReceivedTicks)/(double)Stopwatch.Frequency;}}
        public VideoFrame Retain(){var value=Slot;return value.Store.Retain(value);}
        [StructLayout(LayoutKind.Sequential)]struct DibInfo {
            internal uint Size;internal int Width,Height;internal ushort Planes,Bits;
            internal uint Compression,ImageSize;internal int Xppm,Yppm;internal uint Used,Important,Colour;
        }
        [DllImport("gdi32.dll")]static extern int StretchDIBits(IntPtr target,int x,int y,int width,int height,int sx,int sy,int sourceWidth,int sourceHeight,IntPtr pixels,ref DibInfo info,uint usage,uint operation);
        [DllImport("gdi32.dll")]static extern int SetStretchBltMode(IntPtr target,int mode);
        public bool Draw(Graphics graphics,Rectangle destination){
            if(destination.Width<=0||destination.Height<=0)return false;
            var value=Slot;var info=new DibInfo{Size=40,Width=Width,Height=-Height,Planes=1,Bits=32};
            var hdc=graphics.GetHdc();try{SetStretchBltMode(hdc,3);return StretchDIBits(hdc,destination.X,destination.Y,destination.Width,destination.Height,0,0,Width,Height,value.Pin.AddrOfPinnedObject(),ref info,0,0x00CC0020)>0;}finally{graphics.ReleaseHdc(hdc);}
        }
        public void Dispose(){var value=Interlocked.Exchange(ref slot,null);if(value!=null)value.Store.Release(value);}
    }
    public sealed class VideoFrameStore : IDisposable {
        readonly object gate=new object();
        readonly VideoSlot[] slots;
        VideoFrame latest;
        bool disposed;
        public readonly int Width,Height,Generation;
        public VideoFrameStore(int width,int height,int generation,int capacity=6){
            if(width<=0||height<=0||capacity<2)throw new ArgumentOutOfRangeException();
            Width=width;Height=height;Generation=generation;slots=new VideoSlot[capacity];
            for(int i=0;i<capacity;i++)slots[i]=new VideoSlot(this,width,height);
        }
        public VideoFrame Rent(){lock(gate){if(disposed)return null;foreach(var slot in slots)if(slot.References==0){slot.References=1;return new VideoFrame(slot);}return null;}}
        internal VideoFrame Retain(VideoSlot slot){lock(gate){if(slot.References<=0)throw new ObjectDisposedException("VideoFrame");slot.References++;return new VideoFrame(slot);}}
        internal void Release(VideoSlot slot){lock(gate){if(--slot.References==0&&disposed)slot.Destroy();}}
        // Takes ownership of next, including when shutdown raced publication.
        public void Publish(VideoFrame next,long sequence,long receivedTicks){
            VideoFrame old;
            lock(gate){if(disposed){next.Dispose();return;}next.Slot.Sequence=sequence;next.Slot.ReceivedTicks=receivedTicks;old=latest;latest=next;}
            if(old!=null)old.Dispose();
        }
        public VideoFrame AcquireLatest(long after=-1){lock(gate){return disposed||latest==null||latest.Sequence<=after?null:latest.Retain();}}
        public double AgeSeconds {get{lock(gate)return latest==null?double.PositiveInfinity:latest.AgeSeconds;}}
        public void Dispose(){
            lock(gate){if(disposed)return;disposed=true;var old=latest;latest=null;if(old!=null)old.Dispose();foreach(var slot in slots)if(slot.References==0&&slot.Pin.IsAllocated)slot.Destroy();}
        }
        public static bool ReadFrame(Stream input,byte[] destination){
            int offset=0;
            while(offset<destination.Length){int count=input.Read(destination,offset,destination.Length-offset);if(count==0){if(offset==0)return false;throw new InvalidDataException("Truncated raw video frame; not published");}offset+=count;}
            return true;
        }
    }
}
