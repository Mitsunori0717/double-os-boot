using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public sealed class EdgeBoxSetupCore {
    public int Efficiency;
    public int[] Lps;
}
public static class EdgeBoxSetupTopology {
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool GetLogicalProcessorInformationEx(int relation, IntPtr buffer, ref uint length);
    public static EdgeBoxSetupCore[] GetCores() {
        uint len=0;
        GetLogicalProcessorInformationEx(0,IntPtr.Zero,ref len);
        if(len==0) throw new InvalidOperationException("CPU topology unavailable");
        IntPtr buf=Marshal.AllocHGlobal((int)len);
        try {
            if(!GetLogicalProcessorInformationEx(0,buf,ref len)) throw new InvalidOperationException("CPU topology query failed");
            var result=new List<EdgeBoxSetupCore>();
            for(int offset=0; offset<(int)len;) {
                IntPtr p=IntPtr.Add(buf,offset);
                int size=Marshal.ReadInt32(p,4);
                if(size<32 || offset+size>len) throw new InvalidOperationException("Invalid CPU topology");
                if(Marshal.ReadInt32(p)==0) {
                    int groups=Marshal.ReadInt16(p,30);
                    var lps=new List<int>();
                    for(int g=0;g<groups;g++) {
                        int a=32+g*(IntPtr.Size+8);
                        if(a+IntPtr.Size+8>size) throw new InvalidOperationException("Invalid CPU affinity");
                        ulong mask=IntPtr.Size==8 ? unchecked((ulong)Marshal.ReadInt64(p,a)) : unchecked((uint)Marshal.ReadInt32(p,a));
                        int group=Marshal.ReadInt16(p,a+IntPtr.Size);
                        if(group!=0) throw new InvalidOperationException("Multiple processor groups require a manual plan");
                        for(int b=0;b<IntPtr.Size*8;b++) if((mask & (1UL<<b))!=0) lps.Add(b);
                    }
                    result.Add(new EdgeBoxSetupCore{Efficiency=Marshal.ReadByte(p,9),Lps=lps.ToArray()});
                }
                offset+=size;
            }
            return result.ToArray();
        } finally { Marshal.FreeHGlobal(buf); }
    }
}
