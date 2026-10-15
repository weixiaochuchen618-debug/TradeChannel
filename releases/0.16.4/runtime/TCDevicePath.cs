using System;
using System.Text;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class TCDevicePath {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode)]
    public static extern uint QueryDosDevice(string name, StringBuilder target, int size);
    [DllImport("wininet.dll", SetLastError=true)]
    static extern bool InternetSetOption(IntPtr handle, int option, IntPtr buffer, int length);
    public static bool NotifyProxyChange() {
        bool changed=InternetSetOption(IntPtr.Zero,39,IntPtr.Zero,0);
        bool refreshed=InternetSetOption(IntPtr.Zero,37,IntPtr.Zero,0);
        return changed && refreshed;
    }
}
public static class TCProviderPipeIdentity {
    [DllImport("kernel32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetNamedPipeServerProcessId(SafePipeHandle pipe, out uint serverId);
}
