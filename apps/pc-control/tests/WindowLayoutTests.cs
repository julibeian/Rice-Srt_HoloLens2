using System;
using System.Drawing;
using System.Reflection;
using System.Windows.Forms;

// Instantiates an unshown preview form. No portal, device, input or external UI.
static class WindowLayoutTests {
    static Control Find(Control parent,string accessibleName) {
        if(parent.AccessibleName==accessibleName)return parent;
        foreach(Control child in parent.Controls){var found=Find(child,accessibleName);if(found!=null)return found;}
        return null;
    }
    static void Layout(Control parent){parent.PerformLayout();foreach(Control child in parent.Controls)Layout(child);}
    static void Check(Form form,Size client,string label){
        form.ClientSize=client;Layout(form);
        var video=Find(form,"眼镜实时全息画面");
        if(video==null)throw new Exception("Missing video surface");
        var available=video.Parent.ClientRectangle;
        Console.WriteLine(label+" form="+form.ClientSize+" parent="+available+" video="+video.Bounds);
        if(video.Left<0||video.Top<0||video.Right>available.Width||video.Bottom>available.Height)
            throw new Exception("Video extends outside its resized parent: "+label);
        if(video.Parent.Right>video.Parent.Parent.ClientSize.Width||video.Parent.Bottom>video.Parent.Parent.ClientSize.Height)
            throw new Exception("Video container extends outside the resized body: "+label);
        if(video.Width<100||video.Height<60)throw new Exception("Video collapsed: "+label);
    }
    [STAThread]static int Main(string[] args){
        try{
            var assembly=Assembly.LoadFrom(args[0]);
            var type=assembly.GetType("Rice.HoloLens.Control.MainForm",true);
            using(var form=(Form)Activator.CreateInstance(type,new object[]{args[1],null,true})){
                form.CreateControl();
                Check(form,new Size(2400,1400),"wide");
                Check(form,new Size(1000,650),"shrink-after-wide");
                Check(form,new Size(1800,1100),"expand-again");
                Check(form,new Size(960,580),"minimum-after-wide");
                Check(form,new Size(2400,1400),"before-dpi-autoscale");
                form.Scale(new SizeF(1.25f,1.25f));
                Check(form,new Size(2400,1400),"dpi-autoscale-at-fixed-screen-size");
                Check(form,new Size(1000,650),"shrink-after-dpi-autoscale");
            }
            Console.WriteLine("Window layout: resize and DPI autoscale transitions passed; device calls=0");return 0;
        }catch(Exception error){Console.Error.WriteLine(error);return 1;}
    }
}
