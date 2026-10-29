using System;
using System.Drawing;
using System.Windows.Forms;
using System.Web.Script.Serialization;
public sealed class PortalClipboardConfiguration {
    public string Device {get;set;}
    public string Address {get;set;}
    public string UserName {get;set;}
    public string Password {get;set;}
}
public sealed class PortalCredentialClipboard : Form {
    readonly PortalClipboardConfiguration config;
    readonly Timer timer=new Timer();
    readonly Label status=new Label();
    string copied;
    PortalCredentialClipboard(PortalClipboardConfiguration configuration){
        config=configuration;Text="官方测试 · 本机凭据";ClientSize=new Size(540,230);
        StartPosition=FormStartPosition.CenterScreen;FormBorderStyle=FormBorderStyle.FixedDialog;
        MaximizeBox=false;Font=new Font("Microsoft YaHei UI",10);
        Controls.Add(new Label {Location=new Point(18,16),Size=new Size(504,58),Text="已验证："+config.Device+" / "+config.Address+"\r\n仅向微软官方 Device Portal 登录框传递本机已有凭据。"});
        Controls.Add(new TextBox {Location=new Point(18,80),Size=new Size(504,28),ReadOnly=true,Text=config.UserName});
        var user=new Button {Location=new Point(18,122),Size=new Size(150,36),Text="复制用户名",AccessibleName="复制已验证用户名"};Controls.Add(user);
        var password=new Button {Location=new Point(182,122),Size=new Size(150,36),Text="复制密码",AccessibleName="复制已验证密码"};Controls.Add(password);
        var close=new Button {Location=new Point(346,122),Size=new Size(176,36),Text="关闭凭据窗口"};Controls.Add(close);
        status.Location=new Point(18,176);status.Size=new Size(504,44);status.Text="密码不显示、不写入日志；复制后 30 秒自动清除。";Controls.Add(status);
        timer.Interval=30000;timer.Tick+=(s,e)=>{ClearOwn();status.Text="本窗口复制的密码已从剪贴板清除。";};
        user.Click+=(s,e)=>{ClearOwn();Clipboard.SetText(config.UserName);status.Text="用户名已复制。";};
        password.Click+=(s,e)=>{ClearOwn();copied=config.Password;Clipboard.SetText(copied);timer.Start();status.Text="密码已复制，30 秒后清除。";};
        close.Click+=(s,e)=>Close();FormClosed+=(s,e)=>{ClearOwn();timer.Dispose();config.Password=null;};
    }
    void ClearOwn(){timer.Stop();try{if(copied!=null&&Clipboard.ContainsText()&&Clipboard.GetText()==copied)Clipboard.Clear();}finally{copied=null;}}
    [STAThread]public static int Main(){
        try{
            string line=Console.ReadLine();if(line==null||line.Length>16384)return 2;
            var config=new JavaScriptSerializer().Deserialize<PortalClipboardConfiguration>(line);line=null;
            if(config==null||config.Device!="HOLOLENS-I0IHKJ"||config.Address==null||!config.Address.StartsWith("169.254.")||String.IsNullOrEmpty(config.UserName)||String.IsNullOrEmpty(config.Password))return 2;
            Application.EnableVisualStyles();Application.SetCompatibleTextRenderingDefault(false);
            using(var form=new PortalCredentialClipboard(config))Application.Run(form);
            return 0;
        }catch{return 2;}
    }
}
