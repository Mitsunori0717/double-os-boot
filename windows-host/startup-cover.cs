using System;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

// サインイン時にはコンパイルも PowerShell の読み込みも行わず、この EXE を直接起動する。
internal sealed class EdgeBoxStartupCover : Form {
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int z, uint flags);
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int key);
    readonly string root;
    readonly System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer();
    readonly DateTime started = DateTime.UtcNow;
    DateTime? esc;
    int ticks;
    string Ready { get { return Path.Combine(root,"display-splash-ready.flag"); } }
    string Off { get { return Path.Combine(root,"display-splash-leftoff.flag"); } }
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams {
        get { var p=base.CreateParams; p.ExStyle |= 0x08000008; return p; }
    }
    EdgeBoxStartupCover(string directory) {
        root=directory;
        FormBorderStyle=FormBorderStyle.None;
        StartPosition=FormStartPosition.Manual;
        BackColor=Color.Black;
        ShowInTaskbar=false;
        TopMost=true;
        DoubleBuffered=true;
        Font=new Font("Meiryo UI",20,FontStyle.Regular,GraphicsUnit.Point);
        MoveToLeft();
        try { File.Delete(Off); File.Delete(Ready); } catch { }
        timer.Interval=250;
        timer.Tick+=Tick;
        Shown+=delegate { Refresh(); MarkReady(); timer.Start(); };
        FormClosed+=delegate { timer.Stop(); try {File.Delete(Ready);} catch {} };
    }
    void MoveToLeft() {
        Screen left=Screen.AllScreens[0];
        foreach(var s in Screen.AllScreens) if(s.Bounds.X<left.Bounds.X) left=s;
        if(Bounds!=left.Bounds) { Bounds=left.Bounds; Invalidate(); }
    }
    void MarkReady() { try { File.WriteAllText(Ready,"1"); } catch {} }
    void Tick(object sender,EventArgs e) {
        if(File.Exists(Off) || (DateTime.UtcNow-started).TotalSeconds>450) {Close(); return;}
        if((GetAsyncKeyState(0x1B)&0x8000)!=0) {
            if(esc==null) esc=DateTime.UtcNow;
            else if((DateTime.UtcNow-esc.Value).TotalSeconds>=1) {Close(); return;}
        } else esc=null;
        ticks++;
        if(ticks%4==0) {MoveToLeft(); MarkReady(); Invalidate();}
        SetWindowPos(Handle,new IntPtr(-1),0,0,0,0,0x0013);
    }
    protected override void OnPaint(PaintEventArgs e) {
        base.OnPaint(e);
        var rect=new Rectangle(0,Math.Max(0,ClientSize.Height-112),ClientSize.Width,64);
        TextRenderer.DrawText(e.Graphics,"Edge Box 起動中"+new string('.',(ticks/4)%4),Font,rect,Color.LightGray,
            TextFormatFlags.HorizontalCenter|TextFormatFlags.VerticalCenter|TextFormatFlags.SingleLine);
    }
    [STAThread] static void Main(string[] args) {
        if(args.Length!=1 || !Directory.Exists(args[0])) return;
        bool owner;
        using(var mutex=new Mutex(true,"Local\\EdgeBoxStartupCover",out owner)) {
            if(!owner) return;
            try { Application.EnableVisualStyles(); Application.Run(new EdgeBoxStartupCover(args[0])); }
            catch(Exception ex) {try{File.AppendAllText(Path.Combine(args[0],"display-error.txt"),DateTime.Now+" StartupCover: "+ex+Environment.NewLine);}catch{}}
            finally {mutex.ReleaseMutex();}
        }
    }
}
