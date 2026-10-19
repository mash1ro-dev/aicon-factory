using System;
using System.Drawing;
using System.Runtime.InteropServices;
public static class ShellIconTest {
    [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] struct Info {
        public IntPtr Icon; public int Index; public uint Attributes;
        [MarshalAs(UnmanagedType.ByValTStr,SizeConst=260)] public string Display;
        [MarshalAs(UnmanagedType.ByValTStr,SizeConst=80)] public string Type;
    }
    [DllImport("shell32.dll",CharSet=CharSet.Unicode)] static extern IntPtr SHGetFileInfo(string path,uint attributes,ref Info info,uint size,uint flags);
    [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr icon);
    public static double BluePixelMatch(string path,string frame) {
        Info info=new Info();
        if(SHGetFileInfo(path,0,ref info,(uint)Marshal.SizeOf(typeof(Info)),0x100)==IntPtr.Zero || info.Icon==IntPtr.Zero)throw new InvalidOperationException("Shell icon unavailable");
        try {
            using(var actual=Icon.FromHandle(info.Icon).ToBitmap())using(var expected=new Bitmap(frame)) {
                if(actual.Width!=32 || actual.Height!=32 || expected.Width!=32)throw new InvalidOperationException("Unexpected Shell bitmap dimensions");
                int samples=0,matched=0;
                for(int y=0;y<32;y++)for(int x=16;x<32;x++) {
                    Color e=expected.GetPixel(x,y); if(e.A<240 || e.B-e.R<40)continue;
                    Color a=actual.GetPixel(x,y);samples++;
                    if(Math.Abs(e.R-a.R)<30 && Math.Abs(e.G-a.G)<30 && Math.Abs(e.B-a.B)<30)matched++;
                }
                if(samples<10)throw new InvalidOperationException("Test image lacks expected blue samples");
                return (double)matched/samples;
            }
        }finally{DestroyIcon(info.Icon);}
    }
}
