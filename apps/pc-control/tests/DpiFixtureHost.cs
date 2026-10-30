using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Web.Script.Serialization;
using System.Windows.Forms;
[assembly:System.Runtime.Versioning.TargetFramework(".NETFramework,Version=v4.8",FrameworkDisplayName=".NET Framework 4.8")]

// Local rendering fixture. No connection, controller, or device input is started.
static class DpiFixtureHost {
    static readonly string Root=Path.GetFullPath(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,@"..\..\.."));
    static Control Find(Control parent){if(parent.AccessibleName=="眼镜实时全息画面")return parent;foreach(Control child in parent.Controls){var match=Find(child);if(match!=null)return match;}return null;}
    static void DisableCommands(Control parent){foreach(Control child in parent.Controls){if(child is Button && child.Text!="全屏")child.Enabled=false;if(child is ComboBox)child.Enabled=false;DisableCommands(child);}}
    [STAThread]static void Main(){
        var assembly=Assembly.LoadFrom(Path.Combine(Root,@"apps/pc-control\dist\RiceHoloLensControl.exe"));
        assembly.GetType("Rice.HoloLens.Control.Program").GetMethod("SetDpi",BindingFlags.NonPublic|BindingFlags.Static).Invoke(null,null);
        Application.EnableVisualStyles();Application.SetCompatibleTextRenderingDefault(false);
        var formType=assembly.GetType("Rice.HoloLens.Control.MainForm",true);
        using(var form=(Form)Activator.CreateInstance(formType,new object[]{Root,null,true})){
            form.Text="HoloLens · 本机 DPI 绘制测试（无设备输入）";form.AccessibleName=form.Text;
            var session=formType.GetField("session",BindingFlags.NonPublic|BindingFlags.Instance).GetValue(form);
            var storeType=assembly.GetType("Rice.HoloLens.Control.VideoFrameStore",true);
            var frameType=assembly.GetType("Rice.HoloLens.Control.VideoFrame",true);
            var store=Activator.CreateInstance(storeType,new object[]{854,480,1,6});
            session.GetType().GetField("frames",BindingFlags.NonPublic|BindingFlags.Instance).SetValue(session,store);
            var frame=storeType.GetMethod("Rent").Invoke(store,null);
            var pixels=(byte[])frameType.GetProperty("Pixels").GetValue(frame,null);
            for(int y=0;y<480;y++)for(int x=0;x<854;x++){
                var colour=y<240?(x<427?Color.Red:Color.Lime):(x<427?Color.Blue:Color.Yellow);
                if(x%107<2||y%60<2)colour=Color.White;
                int offset=(y*854+x)*4;pixels[offset]=colour.B;pixels[offset+1]=colour.G;pixels[offset+2]=colour.R;pixels[offset+3]=255;
            }
            var sourceImage=(Bitmap)frameType.GetProperty("Image").GetValue(frame,null);
            using(var graphics=Graphics.FromImage(sourceImage))using(var font=new Font("Arial",28,FontStyle.Bold)){
                graphics.DrawString("TOP LEFT",font,Brushes.Black,40,70);graphics.DrawString("TOP RIGHT",font,Brushes.Black,460,70);
                graphics.DrawString("BOTTOM LEFT",font,Brushes.White,25,320);graphics.DrawString("BOTTOM RIGHT",font,Brushes.Black,435,320);
            }
            storeType.GetMethod("Publish").Invoke(store,new object[]{frame,1L,Stopwatch.GetTimestamp()});
            var view=Find(form);var setFrame=view.GetType().GetMethod("SetFrame");var acquire=storeType.GetMethod("AcquireLatest");
            var sequence=session.GetType().GetField("frameSequence",BindingFlags.NonPublic|BindingFlags.Instance);
            var slot=frameType.GetProperty("Slot",BindingFlags.NonPublic|BindingFlags.Instance).GetValue(frame,null);
            var received=slot.GetType().GetField("ReceivedTicks",BindingFlags.NonPublic|BindingFlags.Instance);
            var map=assembly.GetType("Rice.HoloLens.Control.PointerMap").GetMethod("TryImagePoint",BindingFlags.Public|BindingFlags.Static);
            var folder=Path.Combine(Root,@"reports\phase2-full-control\t07-dpi-20261029\fixture");Directory.CreateDirectory(folder);
            view.MouseUp+=(sender,e)=>{
                var arguments=new object[]{e.Location,view.ClientSize,new Size(854,480),new PointF()};
                bool hit=(bool)map.Invoke(null,arguments);var point=(PointF)arguments[3];
                var record=new{at=DateTimeOffset.Now.ToString("o"),mouse=e.Location.ToString(),client=view.ClientSize.ToString(),hit=hit,image_point=point.ToString(),local_fixture=true,device_input_sent=false};
                File.WriteAllText(Path.Combine(folder,"click-"+DateTime.UtcNow.Ticks+".json"),new JavaScriptSerializer().Serialize(record));
            };
            long count=1;
            using(var timer=new Timer{Interval=100}){
                timer.Tick+=(sender,e)=>{received.SetValue(slot,Stopwatch.GetTimestamp());sequence.SetValue(session,++count);setFrame.Invoke(view,new[]{acquire.Invoke(store,new object[]{-1L})});DisableCommands(form);};
                form.Shown+=(sender,e)=>{DisableCommands(form);timer.Start();};
                Application.Run(form);timer.Stop();
            }
        }
    }
}
