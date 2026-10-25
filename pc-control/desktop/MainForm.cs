using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace Rice.HoloLens.Control {
    public sealed class ControlButton : Button {
        bool hovering,pressed;
        protected override void OnMouseEnter(EventArgs e){hovering=true;Invalidate();base.OnMouseEnter(e);}
        protected override void OnMouseLeave(EventArgs e){hovering=false;pressed=false;Invalidate();base.OnMouseLeave(e);}
        protected override void OnMouseDown(MouseEventArgs e){pressed=true;Invalidate();base.OnMouseDown(e);}
        protected override void OnMouseUp(MouseEventArgs e){pressed=false;Invalidate();base.OnMouseUp(e);}
        protected override void OnPaint(PaintEventArgs e){
            var colour=BackColor;if(Enabled&&hovering)colour=ControlPaint.Light(colour,pressed?.05f:.12f);
            using(var brush=new SolidBrush(colour))e.Graphics.FillRectangle(brush,ClientRectangle);
            using(var pen=new Pen(Enabled?FlatAppearance.BorderColor:Color.FromArgb(56,73,90)))e.Graphics.DrawRectangle(pen,0,0,Width-1,Height-1);
            TextRenderer.DrawText(e.Graphics,Text,Font,ClientRectangle,Enabled?ForeColor:Color.FromArgb(140,160,180),TextFormatFlags.HorizontalCenter|TextFormatFlags.VerticalCenter|TextFormatFlags.SingleLine|TextFormatFlags.EndEllipsis);
            if(Focused&&ShowFocusCues)ControlPaint.DrawFocusRectangle(e.Graphics,new Rectangle(3,3,Width-6,Height-6),ForeColor,colour);
        }
    }
    public sealed class VideoSurface : System.Windows.Forms.Control {
        Bitmap image;Point down;Point? hover;
        public bool InputEnabled,Stale;
        public event Action<PointF> ImageClicked;
        public event Action<Point> ViewDragged;
        public VideoSurface(){DoubleBuffered=true;BackColor=Color.FromArgb(8,12,17);TabStop=true;AccessibleName="眼镜实时全息画面";Cursor=Cursors.Cross;SetStyle(ControlStyles.ResizeRedraw,true);}
        public void SetFrame(Bitmap next){var old=image;image=next;if(old!=null)old.Dispose();Invalidate();}
        protected override void OnPaint(PaintEventArgs e){
            base.OnPaint(e);var g=e.Graphics;g.Clear(BackColor);
            if(image==null){using(var font=new Font("Microsoft YaHei UI",14))using(var brush=new SolidBrush(Color.FromArgb(159,176,194)))DrawCentre(g,"连接眼镜后显示真实全息画面",font,brush,ClientRectangle);return;}
            var fit=PointerMap.Fit(ClientSize,image.Size);g.InterpolationMode=InterpolationMode.Bilinear;g.DrawImage(image,fit);
            if(InputEnabled&&hover.HasValue&&fit.Contains(hover.Value))using(var pen=new Pen(Color.FromArgb(70,190,255),1.5f)){var p=hover.Value;g.DrawLine(pen,p.X-10,p.Y,p.X-4,p.Y);g.DrawLine(pen,p.X+4,p.Y,p.X+10,p.Y);g.DrawLine(pen,p.X,p.Y-10,p.X,p.Y-4);g.DrawLine(pen,p.X,p.Y+4,p.X,p.Y+10);}
            if(Stale){using(var brush=new SolidBrush(Color.FromArgb(220,24,29,38)))g.FillRectangle(brush,fit.X,fit.Y,fit.Width,45);using(var font=new Font("Microsoft YaHei UI",11))using(var brush=new SolidBrush(Color.FromArgb(255,198,102)))DrawCentre(g,"画面暂未更新 · 点按已暂停",font,brush,new Rectangle(fit.X,fit.Y,fit.Width,45));}
        }
        static void DrawCentre(Graphics g,string value,Font font,Brush brush,Rectangle box){using(var format=new StringFormat{Alignment=StringAlignment.Center,LineAlignment=StringAlignment.Center})g.DrawString(value,font,brush,box,format);}
        protected override void OnMouseDown(MouseEventArgs e){base.OnMouseDown(e);down=e.Location;Focus();}
        protected override void OnMouseMove(MouseEventArgs e){base.OnMouseMove(e);hover=e.Location;if(InputEnabled)Invalidate();}
        protected override void OnMouseLeave(EventArgs e){base.OnMouseLeave(e);hover=null;Invalidate();}
        protected override void OnMouseUp(MouseEventArgs e){base.OnMouseUp(e);if(!InputEnabled||Stale||image==null)return;
            if(e.Button==MouseButtons.Right){var drag=ViewDragged;if(drag!=null)drag(new Point(e.X-down.X,e.Y-down.Y));return;}
            if(e.Button!=MouseButtons.Left||Math.Abs(e.X-down.X)+Math.Abs(e.Y-down.Y)>6)return;
            PointF point;if(PointerMap.TryImagePoint(e.Location,ClientSize,image.Size,out point)){var click=ImageClicked;if(click!=null)click(point);}
        }
        protected override void Dispose(bool disposing){if(disposing&&image!=null){image.Dispose();image=null;}base.Dispose(disposing);}
    }
    public sealed class MainForm : Form {
        readonly DeviceSession session;
        readonly EventWaitHandle showRequest;
        readonly VideoSurface view=new VideoSurface();
        readonly Label connection=new Label(),detail=new Label(),notice=new Label(),counter=new Label(),videoStatus=new Label();
        readonly TextBox journal=new TextBox();
        readonly Button connect,start,stop,focus,home,calibrate;
        readonly List<Button> motionButtons=new List<Button>();
        readonly System.Windows.Forms.Timer refresh=new System.Windows.Forms.Timer();
        readonly Color background=Color.FromArgb(15,22,31),panel=Color.FromArgb(23,33,46),muted=Color.FromArgb(153,174,195),accent=Color.FromArgb(70,199,156);
        bool busy,closing,closed,fullScreen;long drawnSequence=-1;Rectangle normalBounds;FormBorderStyle normalBorder;
        int frameCount;DateTime statsAt=DateTime.UtcNow;
        public MainForm(string workspace,EventWaitHandle showEvent=null,bool previewMode=false){
            showRequest=showEvent;
            session=new DeviceSession(workspace);session.Notice+=ShowNotice;
            Text="稻视界 · 眼镜控制";Name="RiceHoloLensControl";AccessibleName=Text;
            Width=1280;Height=840;MinimumSize=new Size(1060,700);StartPosition=FormStartPosition.CenterScreen;BackColor=background;ForeColor=Color.White;Font=new Font("Microsoft YaHei UI",9);AutoScaleMode=AutoScaleMode.Dpi;KeyPreview=true;
            var header=new Panel{Dock=DockStyle.Top,Height=78,BackColor=panel,Padding=new Padding(20,12,20,8)};Controls.Add(header);
            var title=new Label{Text="稻视界  /  眼镜控制",Font=new Font("Microsoft YaHei UI",17,FontStyle.Bold),AutoSize=true,Location=new Point(20,10)};header.Controls.Add(title);
            detail.Text="真实全息画面 · 鼠标点按 · USB 连接";detail.ForeColor=muted;detail.AutoSize=true;detail.Location=new Point(23,47);header.Controls.Add(detail);
            connection.Text="● 尚未连接";connection.ForeColor=muted;connection.AutoSize=true;connection.Anchor=AnchorStyles.Top|AnchorStyles.Right;connection.Location=new Point(1000,17);header.Controls.Add(connection);
            var full=MakeButton("全屏",(s,e)=>ToggleFullscreen());full.Width=70;full.Height=29;full.Anchor=AnchorStyles.Top|AnchorStyles.Right;full.Location=new Point(1135,39);header.Controls.Add(full);
            var saveTop=MakeButton("保存画面",async(s,e)=>await Run(SaveFrame));saveTop.Width=90;saveTop.Height=29;saveTop.Anchor=AnchorStyles.Top|AnchorStyles.Right;saveTop.Top=39;header.Controls.Add(saveTop);
            var logsTop=MakeButton("运行记录",(s,e)=>ProcessFolder());logsTop.Width=90;logsTop.Height=29;logsTop.Anchor=AnchorStyles.Top|AnchorStyles.Right;logsTop.Top=39;header.Controls.Add(logsTop);
            header.Resize+=(s,e)=>{connection.Left=Math.Max(500,header.Width-280);full.Left=header.Width-94;logsTop.Left=header.Width-194;saveTop.Left=header.Width-294;};full.Left=header.Width-94;logsTop.Left=header.Width-194;saveTop.Left=header.Width-294;
            var footer=new Panel{Dock=DockStyle.Bottom,Height=66,BackColor=panel,Padding=new Padding(16,8,16,7)};Controls.Add(footer);
            notice.Dock=DockStyle.Top;notice.Height=24;notice.Text="准备就绪";notice.AutoEllipsis=true;footer.Controls.Add(notice);
            videoStatus.Dock=DockStyle.Bottom;videoStatus.Height=20;videoStatus.ForeColor=muted;videoStatus.Font=new Font("Microsoft YaHei UI",9);footer.Controls.Add(videoStatus);
            var body=new TableLayoutPanel{Dock=DockStyle.Fill,ColumnCount=2,RowCount=1,Padding=new Padding(14,12,14,12),BackColor=background};body.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,100));body.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute,250));Controls.Add(body);body.BringToFront();
            var left=new TableLayoutPanel{Dock=DockStyle.Fill,RowCount=2,ColumnCount=1,Margin=new Padding(0,0,12,0)};left.RowStyles.Add(new RowStyle(SizeType.Percent,100));left.RowStyles.Add(new RowStyle(SizeType.Absolute,90));body.Controls.Add(left,0,0);
            view.Dock=DockStyle.Fill;view.Margin=new Padding(0);left.Controls.Add(view,0,0);
            journal.Dock=DockStyle.Fill;journal.Margin=new Padding(0,8,0,0);journal.Multiline=true;journal.ReadOnly=true;journal.ScrollBars=ScrollBars.Vertical;journal.BackColor=panel;journal.ForeColor=muted;journal.BorderStyle=BorderStyle.None;journal.Font=new Font("Microsoft YaHei UI",9);journal.AccessibleName="运行消息";left.Controls.Add(journal,0,1);
            var side=new FlowLayoutPanel{Dock=DockStyle.Fill,FlowDirection=FlowDirection.TopDown,WrapContents=false,AutoScroll=true,BackColor=panel,Padding=new Padding(13,12,13,10),Margin=new Padding(0)};body.Controls.Add(side,1,0);
            var sideTitle=new Label{Text="设备与控制",AutoSize=true,Font=new Font("Microsoft YaHei UI",11,FontStyle.Bold),Margin=new Padding(0,0,0,10)};side.Controls.Add(sideTitle);
            connect=SideButton(side,"连接眼镜",()=>session.ConnectAsync());
            focus=SideButton(side,"打开稻视界",()=>session.FocusAppAsync());
            start=SideButton(side,"开始控制",()=>session.StartControlAsync());start.BackColor=Color.FromArgb(32,112,88);start.FlatAppearance.BorderColor=accent;
            stop=MakeButton("停止控制 · 恢复眼镜",async(s,e)=>await Run(()=>session.StopControlAsync(),true));stop.Width=210;stop.BackColor=Color.FromArgb(96,47,51);stop.FlatAppearance.BorderColor=Color.FromArgb(173,94,98);side.Controls.Add(stop);
            counter.Text="控制关闭";counter.ForeColor=muted;counter.Width=210;counter.Height=25;counter.TextAlign=ContentAlignment.MiddleCenter;side.Controls.Add(counter);
            home=SideButton(side,"开始菜单",()=>session.HomeAsync());
            calibrate=SideButton(side,"重新校准鼠标",()=>session.CalibrateAsync());
            var label=new Label{Text="调整视角",AutoSize=true,ForeColor=muted,Margin=new Padding(0,10,0,5)};side.Controls.Add(label);
            var arrows=new TableLayoutPanel{Width=210,Height=72,ColumnCount=3,RowCount=2,Margin=new Padding(0,0,0,4)};
            for(int i=0;i<3;i++)arrows.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,33.333f));for(int i=0;i<2;i++)arrows.RowStyles.Add(new RowStyle(SizeType.Percent,50));side.Controls.Add(arrows);
            AddArrow(arrows,"↑",1,0,-.025f,0);AddArrow(arrows,"←",0,1,0,-.025f);AddArrow(arrows,"↓",1,1,.025f,0);AddArrow(arrows,"→",2,1,0,.025f);
            var distance=new FlowLayoutPanel{Width=210,Height=42,Margin=new Padding(0),WrapContents=false};side.Controls.Add(distance);
            var nearer=MakeButton("靠近",async(s,e)=>await Run(()=>session.MoveAsync(-.15f)));nearer.Width=100;var farther=MakeButton("退后",async(s,e)=>await Run(()=>session.MoveAsync(.15f)));farther.Width=100;distance.Controls.Add(nearer);distance.Controls.Add(farther);motionButtons.Add(nearer);motionButtons.Add(farther);
            var help=new Label{Text="左键：定位并点按\r\n右键拖动：转动视角\r\n方向键：微调视角\r\n控制到期自动恢复眼镜",Width=210,Height=104,ForeColor=muted,Font=new Font("Microsoft YaHei UI",8),Margin=new Padding(0,8,0,4)};side.Controls.Add(help);
            view.ImageClicked+=async point=>await Run(()=>session.ClickAsync(point));
            view.ViewDragged+=async delta=>{if(Math.Abs(delta.X)+Math.Abs(delta.Y)>4)await Run(()=>session.LookAsync(-delta.Y*.0006f,-delta.X*.0006f));};
            refresh.Interval=85;refresh.Tick+=RefreshState;refresh.Start();
            Shown+=async(s,e)=>{if(previewMode)return;session.Log("window_shown",new{visible=Visible,state=WindowState.ToString(),bounds=Bounds.ToString(),screen=Screen.FromControl(this).WorkingArea.ToString()});Activate();await Run(()=>session.ConnectAsync());};FormClosing+=ClosingRequested;FormClosed+=(s,e)=>{refresh.Stop();session.Dispose();};
            KeyDown+=async(s,e)=>{if(busy||!session.Controlling)return;float dp=0,dy=0;if(e.KeyCode==Keys.Up)dp=-.025f;else if(e.KeyCode==Keys.Down)dp=.025f;else if(e.KeyCode==Keys.Left)dy=-.025f;else if(e.KeyCode==Keys.Right)dy=.025f;else if(e.KeyCode==Keys.F11){ToggleFullscreen();return;}else return;e.Handled=true;await Run(()=>session.LookAsync(dp,dy));};
            ShowNotice("启动后自动复用本机保存的眼镜认证");UpdateButtons();
        }
        Button MakeButton(string text,EventHandler handler){var button=new ControlButton{Text=text,AccessibleName=text,Height=32,Margin=new Padding(0,0,0,5),FlatStyle=FlatStyle.Flat,BackColor=Color.FromArgb(34,49,65),ForeColor=Color.White,UseVisualStyleBackColor=false};button.FlatAppearance.BorderColor=Color.FromArgb(65,86,106);button.Click+=handler;return button;}
        Button SideButton(FlowLayoutPanel parent,string text,Func<Task> action){var b=MakeButton(text,async(s,e)=>await Run(action));b.Width=210;parent.Controls.Add(b);return b;}
        void AddArrow(TableLayoutPanel panel,string text,int x,int y,float dp,float dy){var b=MakeButton(text,async(s,e)=>await Run(()=>session.LookAsync(dp,dy)));b.Dock=DockStyle.Fill;b.Margin=new Padding(2);panel.Controls.Add(b,x,y);motionButtons.Add(b);}
        async Task Run(Func<Task> action,bool interrupt=false){if(busy&&!interrupt)return;busy=true;UpdateButtons();try{await action();}catch(OperationCanceledException){ShowNotice("已取消当前控制操作");}catch(Exception error){session.Log("ui_error",new{type=error.GetType().Name,message=error.Message});ShowNotice(error.Message);}finally{busy=false;if(!IsDisposed)UpdateButtons();}}
        void UpdateButtons(){connect.Enabled=!busy&&!session.Controlling;start.Enabled=!busy&&session.Connected&&!session.Controlling&&session.FrameAge<2.5;stop.Enabled=session.Controlling;focus.Enabled=!busy&&session.Connected;home.Enabled=!busy&&session.Controlling;calibrate.Enabled=!busy&&session.Controlling;foreach(var button in motionButtons)button.Enabled=!busy&&session.Controlling&&session.FrameAge<2.5;view.InputEnabled=!busy&&session.Controlling&&!closing;}
        void ShowNotice(string message){if(IsDisposed)return;if(InvokeRequired){try{BeginInvoke(new Action<string>(ShowNotice),message);}catch{}return;}notice.Text=message;journal.AppendText(DateTime.Now.ToString("HH:mm:ss")+"  "+message+Environment.NewLine);journal.SelectionStart=journal.TextLength;journal.ScrollToCaret();}
        async void RefreshState(object sender,EventArgs args){
            if(showRequest!=null&&showRequest.WaitOne(0)){WindowState=FormWindowState.Normal;Show();BringToFront();Activate();}
            if(IsDisposed)return;long sequence=session.FrameSequence;
            if(sequence!=drawnSequence){var snapshot=session.Snapshot();if(snapshot!=null){view.SetFrame(snapshot);drawnSequence=sequence;frameCount++;}}
            view.Stale=session.Connected&&session.FrameAge>2.5;view.Invalidate();
            connection.Text=session.Connected?"● "+session.DeviceName:"● 尚未连接";connection.ForeColor=session.Connected?accent:muted;
            double remaining=Math.Max(0,(session.ControlExpires-DateTime.UtcNow).TotalSeconds);
            counter.Text=session.Controlling?"控制剩余  "+TimeSpan.FromSeconds(remaining).ToString(@"mm\:ss"):"控制关闭";counter.ForeColor=session.Controlling?accent:muted;
            if((DateTime.UtcNow-statsAt).TotalSeconds>=1){double fps=frameCount/(DateTime.UtcNow-statsAt).TotalSeconds;videoStatus.Text=(session.Connected?"已验证原眼镜身份  ·  ":"")+(sequence>0?"画面 "+fps.ToString("F0")+" 帧/秒  ·  更新于 "+Math.Min(999,session.FrameAge).ToString("F1")+" 秒前":"等待实时画面")+"  ·  "+(session.Controlling?(session.Calibrated?"鼠标已校准":"鼠标待校准"):"只读观看");frameCount=0;statsAt=DateTime.UtcNow;}
            UpdateButtons();
            if(session.Controlling&&remaining<10&&!busy)await Run(()=>session.StopControlAsync(),true);
        }
        Task SaveFrame(){using(var image=session.Snapshot()){if(image==null)throw new InvalidOperationException("尚无可保存的画面");var path=Path.Combine(session.LogDirectory,"frame-"+DateTime.Now.ToString("HHmmss-fff")+".png");image.Save(path);ShowNotice("画面已保存在本次运行记录中");}return Task.FromResult(0);}
        public void RenderPreview(string source,string destination){
            refresh.Stop();using(var input=new Bitmap(source))view.SetFrame(new Bitmap(input));
            connection.Text="● 本机已配对眼镜";connection.ForeColor=accent;notice.Text="界面布局预览（离线渲染）";videoStatus.Text="单击画面定位并点按  ·  停止控制后恢复眼镜";
            ShowInTaskbar=false;StartPosition=FormStartPosition.Manual;Location=new Point(-20000,-20000);Show();Application.DoEvents();PerformLayout();using(var output=new Bitmap(Width,Height)){DrawToBitmap(output,new Rectangle(0,0,Width,Height));output.Save(destination);}Hide();
            session.Dispose();
        }
        void ProcessFolder(){try{System.Diagnostics.Process.Start("explorer.exe",DeviceSession.Quote(session.LogDirectory));}catch(Exception e){ShowNotice(e.Message);}}
        void ToggleFullscreen(){if(!fullScreen){normalBounds=Bounds;normalBorder=FormBorderStyle;FormBorderStyle=FormBorderStyle.None;WindowState=FormWindowState.Maximized;}else{WindowState=FormWindowState.Normal;FormBorderStyle=normalBorder;Bounds=normalBounds;}fullScreen=!fullScreen;}
        async void ClosingRequested(object sender,FormClosingEventArgs e){if(closed)return;e.Cancel=true;if(closing)return;closing=true;UpdateButtons();ShowNotice("正在关闭画面并恢复眼镜…");try{await session.DisconnectAsync();}catch(Exception error){session.Log("close_pending",error.Message);}finally{closed=true;Close();}}
    }
    static class Program {
        [DllImport("user32.dll")]static extern bool SetProcessDPIAware();
        [DllImport("user32.dll")]static extern bool AllowSetForegroundWindow(int processId);
        [STAThread]static void Main(string[] args){
            string workspace=Path.GetFullPath(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"..\\.."));
            if(args.Length==3&&args[0]=="--render-preview"){SetProcessDPIAware();Application.EnableVisualStyles();Application.SetCompatibleTextRenderingDefault(false);using(var preview=new MainForm(workspace,null,true))preview.RenderPreview(args[1],args[2]);return;}
            bool owner;using(var mutex=new Mutex(true,"Local\\RiceHoloLensDesktopControl",out owner)){
                if(!owner){try{foreach(var process in System.Diagnostics.Process.GetProcessesByName("RiceHoloLensControl")){try{if(process.Id!=System.Diagnostics.Process.GetCurrentProcess().Id&&process.MainModule.FileName==Application.ExecutablePath)AllowSetForegroundWindow(process.Id);}catch{}finally{process.Dispose();}}using(var request=EventWaitHandle.OpenExisting("Local\\RiceHoloLensDesktopShow"))request.Set();}catch{MessageBox.Show("眼镜控制或验收会话正在运行。","稻视界",MessageBoxButtons.OK,MessageBoxIcon.Information);}return;}
                SetProcessDPIAware();Application.EnableVisualStyles();Application.SetCompatibleTextRenderingDefault(false);
                try{if(!File.Exists(Path.Combine(workspace,"Connect-HoloLens.ps1")))throw new FileNotFoundException("请在完整项目目录内启动软件");using(var request=new EventWaitHandle(false,EventResetMode.AutoReset,"Local\\RiceHoloLensDesktopShow"))Application.Run(new MainForm(workspace,request));}catch(Exception error){MessageBox.Show(error.Message,"稻视界 · 启动未完成",MessageBoxButtons.OK,MessageBoxIcon.Error);}
            }
        }
    }
}
