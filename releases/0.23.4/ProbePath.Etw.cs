using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Runtime.InteropServices;
using System.Threading;

namespace TCProbePathV1 {
    public sealed class UdpSocketRow {
        public int ProcessId, LocalPort, RemotePort, State;
        public string LocalAddress, RemoteAddress, AddressFamily, Source;
    }
    // Windows x64, manifest Kernel-Network UDP IPv4 Send v0 only.
    // This is a private real-time, memory-only session with a unique GUID/name.
    // The callback does not copy/retain event payloads or other processes' data.
    public sealed class UdpEtwWatch : IDisposable {
        private static readonly Guid Provider = new Guid("7dd42a49-5329-4832-8dfd-43d979153a88");
        [StructLayout(LayoutKind.Sequential)] private struct Wnode {
            public uint BufferSize, ProviderId; public ulong HistoricalContext; public long TimeStamp;
            public Guid Guid; public uint ClientContext, Flags;
        }
        [StructLayout(LayoutKind.Sequential)] private struct Properties {
            public Wnode Wnode; public uint BufferSize, MinimumBuffers, MaximumBuffers, MaximumFileSize,
                LogFileMode, FlushTimer, EnableFlags; public int AgeLimit;
            public uint NumberOfBuffers, FreeBuffers, EventsLost, BuffersWritten, LogBuffersLost, RealTimeBuffersLost;
            public IntPtr LoggerThreadId; public uint LogFileNameOffset, LoggerNameOffset;
        }
        [StructLayout(LayoutKind.Sequential)] private struct Descriptor {
            public ushort Id; public byte Version, Channel, Level, Opcode; public ushort Task; public ulong Keyword;
        }
        [StructLayout(LayoutKind.Sequential)] private struct Header {
            public ushort Size, HeaderType, Flags, EventProperty; public uint ThreadId, ProcessId;
            public long TimeStamp; public Guid ProviderId; public Descriptor EventDescriptor;
            public uint KernelTime, UserTime; public Guid ActivityId;
        }
        [StructLayout(LayoutKind.Sequential)] private struct Record {
            public Header Header; public uint BufferContext; public ushort ExtendedDataCount, UserDataLength;
            public IntPtr ExtendedData, UserData, UserContext;
        }
        // Exact EVENT_TRACE_LOGFILEW x64 layout, including unused native headers.
        [StructLayout(LayoutKind.Explicit, Size=448)] private struct Logfile {
            [FieldOffset(0)] public IntPtr LogFileName;
            [FieldOffset(8)] public IntPtr LoggerName;
            [FieldOffset(28)] public uint ProcessTraceMode;
            [FieldOffset(400)] public IntPtr BufferCallback;
            [FieldOffset(416)] public uint EventsLost;
            [FieldOffset(424)] public IntPtr EventRecordCallback;
            [FieldOffset(432)] public uint IsKernelTrace;
            [FieldOffset(440)] public IntPtr Context;
        }
        [UnmanagedFunctionPointer(CallingConvention.Winapi)] private delegate void RecordCallback(ref Record record);
        [UnmanagedFunctionPointer(CallingConvention.Winapi)] private delegate uint BufferCallback(ref Logfile logfile);
        [DllImport("advapi32.dll", CharSet=CharSet.Unicode)] private static extern uint StartTraceW(out ulong handle, string name, IntPtr properties);
        [DllImport("advapi32.dll", CharSet=CharSet.Unicode)] private static extern uint ControlTraceW(ulong handle, string name, IntPtr properties, uint code);
        [DllImport("advapi32.dll")] private static extern uint EnableTraceEx2(ulong handle, ref Guid provider, uint control, byte level, ulong any, ulong all, uint timeout, IntPtr parameters);
        [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern ulong OpenTraceW(ref Logfile logfile);
        [DllImport("advapi32.dll")] private static extern uint ProcessTrace([In] ulong[] handles, uint count, IntPtr start, IntPtr end);
        [DllImport("advapi32.dll")] private static extern uint CloseTrace(ulong handle);

        private readonly object gate = new object();
        private readonly Dictionary<string, UdpSocketRow> rows = new Dictionary<string, UdpSocketRow>();
        private readonly Process process;
        private readonly uint remoteAddress;
        private readonly int remotePort;
        private readonly Guid sessionGuid;
        private readonly RecordCallback callback;
        private readonly BufferCallback bufferCallback;
        private Thread reader;
        private ulong session, consumer = ulong.MaxValue;
        private bool created, disposed;
        private volatile bool stopping;
        private int errors, buffers, matched;
        private bool overflow;
        public int ProcessId { get; private set; }
        public long ProcessStartTicks { get; private set; }
        public string SessionName { get; private set; }
        public string SessionGuid { get { return sessionGuid.ToString("D"); } }
        public uint StartCode { get; private set; }
        public uint EnableCode { get; private set; }
        public uint ProcessTraceCode { get; private set; }
        public uint StopCode { get; private set; }
        public uint EventsLost { get; private set; }
        public uint BuffersLost { get; private set; }
        public int Errors { get { return errors; } }
        public int Buffers { get { return buffers; } }
        public int MatchedEvents { get { return matched; } }
        public bool Overflow { get { return overflow; } }
        public bool Started { get; private set; }
        public bool CleanupComplete { get; private set; }

        public UdpEtwWatch(int processId, long expectedStartTicks, string address, int port, string identity) {
            if (IntPtr.Size != 8) throw new PlatformNotSupportedException("UDP ETW requires Windows x64");
            IPAddress ip;
            if (!IPAddress.TryParse(address, out ip) || ip.AddressFamily != System.Net.Sockets.AddressFamily.InterNetwork || port < 1 || port > 65535)
                throw new ArgumentException("Literal IPv4 target required");
            sessionGuid = Guid.Parse(identity);
            if (sessionGuid == Guid.Empty) throw new ArgumentException("Unique session identity required");
            SessionName = "TCProbe-UDP-" + sessionGuid.ToString("N");
            process = Process.GetProcessById(processId);
            // Hold the original process handle; never retarget a later reused PID.
            IntPtr ownedHandle = process.Handle;
            ProcessId = processId; ProcessStartTicks = process.StartTime.ToUniversalTime().Ticks;
            if (process.HasExited || ProcessStartTicks != expectedStartTicks) { process.Dispose(); throw new InvalidOperationException("Process birth mismatch"); }
            remoteAddress = BitConverter.ToUInt32(ip.GetAddressBytes(), 0); remotePort = port;
            callback = OnEvent; bufferCallback = OnBuffer;
            CleanupComplete = true;
        }
        private static IntPtr NewProperties(Guid guid) {
            int size = Marshal.SizeOf(typeof(Properties));
            IntPtr p = Marshal.AllocHGlobal(4096);
            Marshal.Copy(new byte[4096], 0, p, 4096);
            Properties value = new Properties();
            value.Wnode.BufferSize = 4096; value.Wnode.Guid = guid; value.Wnode.ClientContext = 1; value.Wnode.Flags = 0x20000;
            value.BufferSize = 16; value.MinimumBuffers = 4; value.MaximumBuffers = 4;
            value.LogFileMode = 0x100 | 0x10000000; // REAL_TIME | NO_PER_PROCESSOR_BUFFERING; no ETL file
            value.FlushTimer = 1; value.LoggerNameOffset = (uint)size;
            Marshal.StructureToPtr(value, p, false); return p;
        }
        public void Start() {
            if (created || disposed) throw new InvalidOperationException("Observer already used");
            IntPtr props = NewProperties(sessionGuid);
            try {
                StartCode = StartTraceW(out session, SessionName, props);
                if (StartCode != 0) throw new Win32Exception((int)StartCode);
                created = true; CleanupComplete = false;
                Guid provider = Provider;
                EnableCode = EnableTraceEx2(session, ref provider, 1, 4, 0x10, 0, 1000, IntPtr.Zero);
                if (EnableCode != 0) throw new Win32Exception((int)EnableCode);
                IntPtr name = Marshal.StringToHGlobalUni(SessionName);
                try {
                    Logfile log = new Logfile(); log.LoggerName = name; log.ProcessTraceMode = 0x100 | 0x10000000;
                    log.EventRecordCallback = Marshal.GetFunctionPointerForDelegate(callback);
                    log.BufferCallback = Marshal.GetFunctionPointerForDelegate(bufferCallback);
                    consumer = OpenTraceW(ref log);
                    if (consumer == ulong.MaxValue) throw new Win32Exception(Marshal.GetLastWin32Error());
                } finally { Marshal.FreeHGlobal(name); }
                reader = new Thread(Read); reader.IsBackground = true; reader.Name = "TC owned UDP ETW"; reader.Start();
                Started = true;
            } catch { Interlocked.Increment(ref errors); throw; }
            finally { Marshal.FreeHGlobal(props); }
        }
        private void Read() {
            ProcessTraceCode = ProcessTrace(new ulong[] { consumer }, 1, IntPtr.Zero, IntPtr.Zero);
            if (!stopping || (ProcessTraceCode != 0 && ProcessTraceCode != 1223)) Interlocked.Increment(ref errors);
        }
        private uint OnBuffer(ref Logfile log) {
            Interlocked.Increment(ref buffers);
            if (log.EventsLost > EventsLost) EventsLost = log.EventsLost;
            return 1;
        }
        private void OnEvent(ref Record record) {
            // Inspect only fixed UDP-send metadata; rejected data is never copied,
            // decoded to text, logged, counted by PID, or stored anywhere.
            if (record.Header.ProviderId != Provider || record.Header.EventDescriptor.Id != 42 || record.Header.EventDescriptor.Version != 0 || record.UserDataLength < 20 || record.UserData == IntPtr.Zero) return;
            IntPtr data = record.UserData;
            if (Marshal.ReadInt32(data, 0) != ProcessId) return;
            if (unchecked((uint)Marshal.ReadInt32(data, 8)) != remoteAddress) return;
            int port = (Marshal.ReadByte(data, 16) << 8) | Marshal.ReadByte(data, 17);
            if (port != remotePort) return;
            try {
                if (process.HasExited || process.StartTime.ToUniversalTime().Ticks != ProcessStartTicks) return;
                string local = new IPAddress(BitConverter.GetBytes(Marshal.ReadInt32(data, 12))).ToString();
                string remote = new IPAddress(BitConverter.GetBytes(remoteAddress)).ToString();
                int localPort = (Marshal.ReadByte(data, 18) << 8) | Marshal.ReadByte(data, 19);
                string key = local + ":" + localPort + "/" + remote + ":" + port;
                lock (gate) {
                    if (!rows.ContainsKey(key)) {
                        if (rows.Count >= 256) { overflow = true; return; }
                        rows.Add(key, new UdpSocketRow { ProcessId=ProcessId, LocalAddress=local, LocalPort=localPort,
                            RemoteAddress=remote, RemotePort=port, AddressFamily="IPv4", State=0, Source="WindowsKernelNetworkUdpSendV0" });
                    }
                }
                Interlocked.Increment(ref matched);
            } catch { Interlocked.Increment(ref errors); }
        }
        public UdpSocketRow[] Snapshot() { lock (gate) { var a = new UdpSocketRow[rows.Count]; rows.Values.CopyTo(a, 0); return a; } }
        // Separate local watchdog process. It survives its worker's normal
        // termination and uses only this persisted random session identity.
        // A private receipt also permits exact-session recovery if both die.
        public static int GuardOwnSession(int ownerPid, long ownerBirth, string identity, string readyPath, string stopPath, int seconds) {
            if (seconds < 5 || seconds > 90) throw new ArgumentOutOfRangeException("seconds");
            Process owner = null;
            try {
                owner = Process.GetProcessById(ownerPid);
                IntPtr handle = owner.Handle;
                if (owner.StartTime.ToUniversalTime().Ticks != ownerBirth) return 5;
                File.WriteAllText(readyPath, identity);
                var clock = Stopwatch.StartNew(); bool observed = false;
                while (true) {
                    if (owner.HasExited || File.Exists(stopPath) || clock.Elapsed.TotalSeconds >= seconds) {
                        uint stop = StopOwn(identity);
                        return stop == 0 && QueryOwn(identity) == 4201 ? 0 : (int)(stop == 0 ? 1 : stop);
                    }
                    uint query = QueryOwn(identity);
                    if (query == 0) observed = true;
                    else if (query == 4201 && observed) return 0;
                    else if (query != 4201) return (int)query;
                    Thread.Sleep(100);
                }
            } catch { return 1; }
            finally { if (owner != null) owner.Dispose(); }
        }
        public static uint QueryOwn(string identity) {
            Guid guid = Guid.Parse(identity); IntPtr props = NewProperties(guid);
            try {
                uint code = ControlTraceW(0, "TCProbe-UDP-" + guid.ToString("N"), props, 0);
                if (code == 0 && ((Properties)Marshal.PtrToStructure(props, typeof(Properties))).Wnode.Guid != guid) return 5;
                return code;
            } finally { Marshal.FreeHGlobal(props); }
        }
        // Only the exact randomly generated GUID/name can be stopped. Used for
        // this instance and its private persisted lease, never a session scan.
        public static uint StopOwn(string identity) {
            Guid guid = Guid.Parse(identity); IntPtr props = NewProperties(guid);
            try {
                string name = "TCProbe-UDP-" + guid.ToString("N");
                uint code = ControlTraceW(0, name, props, 0);
                if (code == 4201) return 0; // own session is already absent
                if (code != 0) return code;
                if (((Properties)Marshal.PtrToStructure(props, typeof(Properties))).Wnode.Guid != guid) return 5;
                uint stopped = ControlTraceW(0, name, props, 1);
                return stopped == 4201 ? 0 : stopped;
            } finally { Marshal.FreeHGlobal(props); }
        }
        public void Dispose() {
            if (disposed) return;
            stopping = true;
            if (created) {
                IntPtr props = NewProperties(sessionGuid);
                try {
                    uint query = ControlTraceW(0, SessionName, props, 0);
                    if (query == 0) {
                        Properties p = (Properties)Marshal.PtrToStructure(props, typeof(Properties));
                        if (p.Wnode.Guid != sessionGuid) throw new InvalidOperationException("Trace ownership mismatch");
                        StopCode = ControlTraceW(0, SessionName, props, 1);
                        if (StopCode == 4201) StopCode = 0;
                        p = (Properties)Marshal.PtrToStructure(props, typeof(Properties));
                        EventsLost = Math.Max(EventsLost, p.EventsLost); BuffersLost = p.LogBuffersLost + p.RealTimeBuffersLost;
                    } else StopCode = query == 4201 ? 0 : query;
                    if (StopCode != 0) throw new Win32Exception((int)StopCode);
                } finally { Marshal.FreeHGlobal(props); }
                if (QueryOwn(SessionGuid) != 4201) throw new InvalidOperationException("Trace still present");
            }
            if (consumer != ulong.MaxValue) {
                bool closed = false;
                if (reader != null && !reader.Join(3000)) {
                    uint close = CloseTrace(consumer);
                    if (close != 0 && close != 7007) throw new Win32Exception((int)close);
                    closed = true;
                }
                if (reader != null && !reader.Join(2000)) throw new InvalidOperationException("ETW reader did not stop");
                if (!closed) {
                    uint close = CloseTrace(consumer);
                    if (close != 0 && close != 7007) throw new Win32Exception((int)close);
                }
                consumer = ulong.MaxValue;
            }
            process.Dispose(); CleanupComplete = true; disposed = true;
            GC.KeepAlive(callback); GC.KeepAlive(bufferCallback);
        }
    }
}
