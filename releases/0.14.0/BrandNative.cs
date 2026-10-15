using System;
using System.Runtime.InteropServices;

namespace TradeChannel.UI
{
    public static class BrandNative
    {
        public const string AppId = "TradeChannel.Console";
        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        private static extern int SetCurrentProcessExplicitAppUserModelID(string id);
        [DllImport("shell32.dll", PreserveSig = true)]
        private static extern int SHGetPropertyStoreForWindow(IntPtr hwnd, ref Guid iid, out IPropertyStore store);
        [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = true)]
        private static extern int SHGetPropertyStoreFromParsingName(string path, IntPtr bind, uint flags, ref Guid iid, out IPropertyStore store);
        [DllImport("ole32.dll")]
        private static extern int PropVariantClear(ref PropVariant value);
        [DllImport("user32.dll")]
        private static extern IntPtr SendMessage(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);
        public static IntPtr ReadWindowIcon(IntPtr hwnd)
        {
            var icon = SendMessage(hwnd, 0x007F, new IntPtr(1), IntPtr.Zero);
            if (icon == IntPtr.Zero) icon = SendMessage(hwnd, 0x007F, IntPtr.Zero, IntPtr.Zero);
            return icon;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct PropertyKey { public Guid Format; public uint Id; public PropertyKey(uint id) { Format = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"); Id = id; } }
        [StructLayout(LayoutKind.Explicit, Size = 24)]
        private struct PropVariant { [FieldOffset(0)] public ushort Type; [FieldOffset(8)] public IntPtr Pointer; }
        [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IPropertyStore
        {
            [PreserveSig] int GetCount(out uint count);
            [PreserveSig] int GetAt(uint index, out PropertyKey key);
            [PreserveSig] int GetValue(ref PropertyKey key, out PropVariant value);
            [PreserveSig] int SetValue(ref PropertyKey key, ref PropVariant value);
            [PreserveSig] int Commit();
        }
        private static void Set(IPropertyStore store, uint id, string text)
        {
            var key = new PropertyKey(id);
            var value = new PropVariant { Type = 31, Pointer = Marshal.StringToCoTaskMemUni(text) };
            try { Marshal.ThrowExceptionForHR(store.SetValue(ref key, ref value)); }
            finally { PropVariantClear(ref value); }
        }
        public static void InitializeProcess() { Marshal.ThrowExceptionForHR(SetCurrentProcessExplicitAppUserModelID(AppId)); }
        public static void SetWindow(IntPtr hwnd, string launcher)
        {
            Guid iid = typeof(IPropertyStore).GUID;
            IPropertyStore store;
            Marshal.ThrowExceptionForHR(SHGetPropertyStoreForWindow(hwnd, ref iid, out store));
            try {
                Set(store, 5, AppId);
                Set(store, 2, "\"" + launcher + "\"");
                Set(store, 3, launcher + ",0");
                Set(store, 4, "TradeChannel");
            } finally { Marshal.ReleaseComObject(store); }
        }
        public static string ReadWindowAppId(IntPtr hwnd)
        {
            Guid iid = typeof(IPropertyStore).GUID;
            IPropertyStore store;
            Marshal.ThrowExceptionForHR(SHGetPropertyStoreForWindow(hwnd, ref iid, out store));
            try { return Read(store); } finally { Marshal.ReleaseComObject(store); }
        }
        public static string ReadShortcutAppId(string path)
        {
            Guid iid = typeof(IPropertyStore).GUID;
            IPropertyStore store;
            Marshal.ThrowExceptionForHR(SHGetPropertyStoreFromParsingName(path, IntPtr.Zero, 0, ref iid, out store));
            try { return Read(store); } finally { Marshal.ReleaseComObject(store); }
        }
        private static string Read(IPropertyStore store)
        {
            var key = new PropertyKey(5); PropVariant value;
            Marshal.ThrowExceptionForHR(store.GetValue(ref key, out value));
            try { return value.Type == 31 ? Marshal.PtrToStringUni(value.Pointer) : null; }
            finally { PropVariantClear(ref value); }
        }
        public static void SetShortcut(string path)
        {
            Guid iid = typeof(IPropertyStore).GUID;
            IPropertyStore store;
            Marshal.ThrowExceptionForHR(SHGetPropertyStoreFromParsingName(path, IntPtr.Zero, 2, ref iid, out store));
            try { Set(store, 5, AppId); Marshal.ThrowExceptionForHR(store.Commit()); }
            finally { Marshal.ReleaseComObject(store); }
        }
    }
}
