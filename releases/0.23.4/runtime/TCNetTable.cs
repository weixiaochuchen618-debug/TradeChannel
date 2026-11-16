using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class TCNetTable {
    [DllImport("iphlpapi.dll", SetLastError=true)]
    static extern uint GetExtendedTcpTable(IntPtr table, ref int size, bool sort, int family, int tableClass, uint reserved);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    static extern bool QueryFullProcessImageName(IntPtr process, int flags, StringBuilder name, ref int size);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool CloseHandle(IntPtr handle);
    public static int[] ListenerOwners(int port) {
        var owners=new List<int>();
        foreach(int family in new int[]{2,23}) {
            int rowSize=family==2?24:56, portOffset=family==2?8:20, pidOffset=family==2?20:52;
            bool complete=false;
            for(int attempt=0;attempt<3;attempt++) {
                int size=0;uint first=GetExtendedTcpTable(IntPtr.Zero,ref size,false,family,3,0);
                if(size<=0) {if(first==0){complete=true;break;}throw new InvalidOperationException("TCP listener inventory unavailable");}
                size+=4096;IntPtr buffer=Marshal.AllocHGlobal(size);
                try {
                    uint result=GetExtendedTcpTable(buffer,ref size,false,family,3,0);
                    if(result==122)continue;
                    if(result!=0)throw new InvalidOperationException("TCP listener inventory unavailable");
                    int count=Marshal.ReadInt32(buffer);
                    if(count<0 || 4L+(long)count*rowSize>size)throw new InvalidOperationException("TCP listener inventory invalid");
                    for(int i=0;i<count;i++) {
                        IntPtr row=IntPtr.Add(buffer,4+i*rowSize);int raw=Marshal.ReadInt32(row,portOffset);
                        int local=((raw&255)<<8)|((raw>>8)&255);
                        if(local==port){int pid=Marshal.ReadInt32(row,pidOffset);if(!owners.Contains(pid))owners.Add(pid);}
                    }
                    complete=true;break;
                }finally{Marshal.FreeHGlobal(buffer);}
            }
            if(!complete)throw new InvalidOperationException("TCP listener inventory changed repeatedly");
        }
        return owners.ToArray();
    }
    public static string ImagePath(int pid) {
        IntPtr handle=OpenProcess(0x1000,false,pid);if(handle==IntPtr.Zero)return null;
        try{var name=new StringBuilder(32768);int size=name.Capacity;return QueryFullProcessImageName(handle,0,name,ref size)?name.ToString(0,size):null;}finally{CloseHandle(handle);}
    }
}
