using System;
using System.Text;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
public static class AiconTestNative {
    [StructLayout(LayoutKind.Sequential)] public struct RECT {public int Left,Top,Right,Bottom;}
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h,out uint p);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h,StringBuilder b,int n);
    [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr SendMessageTimeout(IntPtr h,uint m,IntPtr w,string l,uint flags,uint ms,out IntPtr result);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h,out RECT r);
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr h,IntPtr dc,uint flags);
    [DllImport("user32.dll")] static extern bool RedrawWindow(IntPtr h,IntPtr update,IntPtr region,uint flags);
    static void Require(IntPtr h,int pid,string expectedClass) {
        uint p;GetWindowThreadProcessId(h,out p);if(p!=(uint)pid)throw new InvalidOperationException("Wrong process; action refused");
        if(expectedClass!=null){var c=new StringBuilder(256);GetClassName(h,c,256);if(c.ToString()!=expectedClass)throw new InvalidOperationException("Wrong control class; action refused");}
    }
    static void Message(IntPtr h,uint m,string text){IntPtr r;if(SendMessageTimeout(h,m,IntPtr.Zero,text,2,5000,out r)==IntPtr.Zero)throw new InvalidOperationException("Test dialog did not respond within five seconds");}
    public static bool Visible(IntPtr h,int pid){Require(h,pid,null);return IsWindowVisible(h);}
    public static void DialogText(IntPtr h,int pid,string text){Require(h,pid,"Edit");Message(h,0x000C,text);}
    public static void DialogClick(IntPtr h,int pid){Require(h,pid,"Button");Message(h,0x00F5,null);}
    public static void Capture(IntPtr h,int pid,string path){
        Require(h,pid,null);RECT r;if(!GetWindowRect(h,out r))throw new InvalidOperationException("Window rectangle unavailable");
        RedrawWindow(h,IntPtr.Zero,IntPtr.Zero,0x581);System.Threading.Thread.Sleep(100);
        int w=r.Right-r.Left,v=r.Bottom-r.Top;if(w<100||v<100||w>6000||v>6000)throw new InvalidOperationException("Invalid window dimensions");
        using(var b=new Bitmap(w,v,PixelFormat.Format32bppArgb))using(var g=Graphics.FromImage(b)){
            g.Clear(Color.Magenta);IntPtr dc=g.GetHdc();bool ok;try{ok=PrintWindow(h,dc,2);}finally{g.ReleaseHdc(dc);}
            if(!ok)throw new InvalidOperationException("PrintWindow failed; screenshot not claimed");
            int changed=0;var colors=new System.Collections.Generic.HashSet<int>();for(int y=10;y<v;y+=31)for(int x=10;x<w;x+=31){var c=b.GetPixel(x,y);if((c.R!=255||c.G!=0||c.B!=255)&&(c.R>10||c.G>10||c.B>10))changed++;colors.Add(c.ToArgb());}
            if(changed<20||colors.Count<6)throw new InvalidOperationException("Blank capture; screenshot not claimed");
            b.Save(path,ImageFormat.Png);
        }
    }
}
