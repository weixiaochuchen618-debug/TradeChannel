using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Net;
using System.Net.NetworkInformation;
using System.Runtime.InteropServices;
using System.Threading;

namespace TCProbePathV1 {
    public sealed class SocketRow {
        public int ProcessId;
        public string LocalAddress;
        public int LocalPort;
        public string RemoteAddress;
        public int RemotePort;
        public string AddressFamily;
        public int State;
        public string Source = "GetExtendedTcpTable";
    }

    // Read-only IP Helper queries. UDP owner tables intentionally cannot prove
    // a remote endpoint; no packet capture, driver, ETW session or network write.
    public static class Native {
        [DllImport("iphlpapi.dll", SetLastError = true)]
        private static extern uint GetExtendedTcpTable(IntPtr table, ref int size,
            bool order, int family, int tableClass, uint reserved);

        public static SocketRow[] ReadTcp(int processId) {
            var rows = new List<SocketRow>();
            foreach (int family in new int[] { 2, 23 }) {
                int size = 0;
                uint first = GetExtendedTcpTable(IntPtr.Zero, ref size, false, family, 5, 0);
                if (first != 0 && first != 122) throw new Win32Exception((int)first);
                bool complete = false;
                for (int attempt = 0; attempt < 4; attempt++) {
                    if (size < 4 || size > 16777216) throw new InvalidOperationException("Table size");
                    int allocated = size;
                    IntPtr buffer = Marshal.AllocHGlobal(allocated);
                    try {
                        uint code = GetExtendedTcpTable(buffer, ref size, false, family, 5, 0);
                        if (code == 122) continue;
                        if (code != 0) throw new Win32Exception((int)code);
                        int count = Marshal.ReadInt32(buffer);
                        int stride = family == 2 ? 24 : 56;
                        if (count < 0 || count > (allocated - 4) / stride)
                            throw new InvalidOperationException("Table count");
                        for (int i = 0; i < count; i++) {
                            IntPtr row = IntPtr.Add(buffer, 4 + i * stride);
                            int pid = Marshal.ReadInt32(row, family == 2 ? 20 : 52);
                            if (pid != processId) continue;
                            int localOffset = family == 2 ? 4 : 0;
                            int remoteOffset = family == 2 ? 12 : 24;
                            int portOffset = family == 2 ? 8 : 20;
                            byte[] local = new byte[family == 2 ? 4 : 16];
                            byte[] remote = new byte[local.Length];
                            Marshal.Copy(IntPtr.Add(row, localOffset), local, 0, local.Length);
                            Marshal.Copy(IntPtr.Add(row, remoteOffset), remote, 0, remote.Length);
                            var l = family == 2 ? new IPAddress(local) : new IPAddress(local, (uint)Marshal.ReadInt32(row, 16));
                            var r = family == 2 ? new IPAddress(remote) : new IPAddress(remote, (uint)Marshal.ReadInt32(row, 40));
                            int lp = Marshal.ReadInt32(row, portOffset);
                            int rp = Marshal.ReadInt32(row, family == 2 ? 16 : 44);
                            rows.Add(new SocketRow {
                                ProcessId = pid, LocalAddress = l.ToString(), RemoteAddress = r.ToString(),
                                LocalPort = ((lp & 255) << 8) | ((lp >> 8) & 255),
                                RemotePort = ((rp & 255) << 8) | ((rp >> 8) & 255),
                                State = Marshal.ReadInt32(row, family == 2 ? 0 : 48),
                                AddressFamily = family == 2 ? "IPv4" : "IPv6"
                            });
                        }
                        complete = true;
                        break;
                    } finally { Marshal.FreeHGlobal(buffer); }
                }
                if (!complete) throw new InvalidOperationException("Table kept changing");
            }
            return rows.ToArray();
        }
    }

    public sealed class SocketWatch : IDisposable {
        [UnmanagedFunctionPointer(CallingConvention.Winapi)]
        private delegate void ChangeCallback(IntPtr context, IntPtr row, int notificationType);
        [DllImport("iphlpapi.dll")]
        private static extern uint NotifyRouteChange2(ushort family, ChangeCallback callback,
            IntPtr context, [MarshalAs(UnmanagedType.U1)] bool initial, out IntPtr handle);
        [DllImport("iphlpapi.dll")]
        private static extern uint CancelMibChangeNotify2(IntPtr handle);
        private readonly int pid;
        private readonly long startTicks;
        private readonly object gate = new object();
        private readonly Dictionary<string, SocketRow> rows = new Dictionary<string, SocketRow>();
        private readonly ManualResetEvent stop = new ManualResetEvent(false);
        private readonly Thread thread;
        private readonly ChangeCallback routeCallback;
        private IntPtr routeNotification;
        private int errors, reads, networkChanges;
        private bool stopped, overflow;
        public int ProcessId { get { return pid; } }
        public long ProcessStartTicks { get { return startTicks; } }
        public int Errors { get { return errors; } }
        public int Reads { get { return reads; } }
        public int NetworkChanges { get { return networkChanges; } }
        public bool Overflow { get { return overflow; } }
        public SocketWatch(int processId) {
            pid = processId;
            using (Process p = Process.GetProcessById(pid)) { startTicks = p.StartTime.ToUniversalTime().Ticks; }
            routeCallback = RouteChanged;
            uint registration = NotifyRouteChange2(0, routeCallback, IntPtr.Zero, false, out routeNotification);
            if (registration != 0) { stop.Dispose(); throw new Win32Exception((int)registration); }
            NetworkChange.NetworkAddressChanged += AddressChanged;
            NetworkChange.NetworkAvailabilityChanged += AvailabilityChanged;
            thread = new Thread(Run);
            thread.IsBackground = true;
            thread.Name = "TC candidate socket observation";
            thread.Start();
        }
        private void AddressChanged(object sender, EventArgs args) { Interlocked.Increment(ref networkChanges); }
        private void AvailabilityChanged(object sender, NetworkAvailabilityEventArgs args) { Interlocked.Increment(ref networkChanges); }
        private void RouteChanged(IntPtr context, IntPtr row, int notificationType) { Interlocked.Increment(ref networkChanges); }
        private void Run() {
            do {
                try {
                    using (Process p = Process.GetProcessById(pid)) {
                        if (p.HasExited || p.StartTime.ToUniversalTime().Ticks != startTicks)
                            throw new InvalidOperationException("Process ownership changed");
                    }
                    SocketRow[] current = Native.ReadTcp(pid);
                    lock (gate) {
                        foreach (SocketRow row in current) {
                            if (row.State != 5) continue; // ESTABLISHED only
                            string key = row.LocalAddress + ":" + row.LocalPort + "/" + row.RemoteAddress + ":" + row.RemotePort;
                            if (!rows.ContainsKey(key)) {
                                if (rows.Count >= 256) { overflow = true; break; }
                                rows.Add(key, row);
                            }
                        }
                    }
                } catch { Interlocked.Increment(ref errors); }
                Interlocked.Increment(ref reads);
                if (reads >= 2400) { overflow = true; break; }
            } while (!stop.WaitOne(25));
        }
        public SocketRow[] Snapshot() {
            lock (gate) { var result = new SocketRow[rows.Count]; rows.Values.CopyTo(result, 0); return result; }
        }
        public void Dispose() {
            if (stopped) return;
            stop.Set();
            if (!thread.Join(5000)) throw new InvalidOperationException("Observer did not stop");
            if (routeNotification != IntPtr.Zero) {
                uint result = CancelMibChangeNotify2(routeNotification);
                if (result != 0) throw new Win32Exception((int)result);
                routeNotification = IntPtr.Zero;
            }
            NetworkChange.NetworkAddressChanged -= AddressChanged;
            NetworkChange.NetworkAvailabilityChanged -= AvailabilityChanged;
            stop.Dispose();
            stopped = true;
        }
    }
}
