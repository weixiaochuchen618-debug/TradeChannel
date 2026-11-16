// .NET Framework 4.8 / C# 5. In-process supervisor component: no child, service,
// external listener, DNS resolution, selector mutation or persisted live mapping.
using System;
using System.Collections.Generic;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

public sealed class TCProviderRelayBinding {
    public int Slot { get; set; }
    public string Lane { get; set; }
    public string ProviderId { get; set; }
    public int Port { get; set; }
    public int OwnerPid { get; set; }
    public long OwnerStartedTicks { get; set; }
    public string OwnerPath { get; set; }
    public string Identity { get; set; }
    public bool Healthy { get; set; }
    public string Reason { get; set; }
    internal int Key { get { return (Slot - 1) * 2 + (Lane == "trade" ? 1 : 0); } }
    internal string Fingerprint { get { return String.Join("|", Slot, Lane, ProviderId, Port, OwnerPid, OwnerStartedTicks, OwnerPath.ToUpperInvariant(), Identity); } }
    internal TCProviderRelayBinding Copy() { return (TCProviderRelayBinding)MemberwiseClone(); }
}

public static class TradeChannelProviderRelay {
    [DllImport("iphlpapi.dll", SetLastError = true)]
    static extern uint GetExtendedTcpTable(IntPtr table, ref int size, bool sort, int family, int tableClass, uint reserved);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool QueryFullProcessImageName(IntPtr process, int flags, StringBuilder name, ref int size);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    public static int[] ListenerOwners(int port) {
        var owners = new HashSet<int>();
        foreach (int family in new int[] { 2, 23 }) {
            bool complete = false;
            for (int attempt = 0; attempt < 3; attempt++) {
                int size = 0; uint first = GetExtendedTcpTable(IntPtr.Zero, ref size, false, family, 3, 0);
                if (size <= 0) { if (first == 0) { complete = true; break; } throw new IOException("ListenerInventoryUnavailable"); }
                size += 4096; IntPtr buffer = Marshal.AllocHGlobal(size);
                try {
                    uint result = GetExtendedTcpTable(buffer, ref size, false, family, 3, 0);
                    if (result == 122) continue;
                    if (result != 0) throw new IOException("ListenerInventoryUnavailable");
                    int rowSize = family == 2 ? 24 : 56, portOffset = family == 2 ? 8 : 20, pidOffset = family == 2 ? 20 : 52;
                    int count = Marshal.ReadInt32(buffer);
                    if (count < 0 || 4L + (long)count * rowSize > size) throw new IOException("ListenerInventoryInvalid");
                    for (int i = 0; i < count; i++) {
                        IntPtr row = IntPtr.Add(buffer, 4 + i * rowSize); int raw = Marshal.ReadInt32(row, portOffset);
                        int local = ((raw & 255) << 8) | ((raw >> 8) & 255);
                        if (local == port) owners.Add(Marshal.ReadInt32(row, pidOffset));
                    }
                    complete = true; break;
                } finally { Marshal.FreeHGlobal(buffer); }
            }
            if (!complete) throw new IOException("ListenerInventoryUnstable");
        }
        return owners.ToArray();
    }
    public static string ImagePath(int pid) {
        IntPtr handle = OpenProcess(0x1000, false, pid);
        if (handle == IntPtr.Zero) return null;
        try { var name = new StringBuilder(32768); int size = name.Capacity; return QueryFullProcessImageName(handle, 0, name, ref size) ? name.ToString(0, size) : null; }
        finally { CloseHandle(handle); }
    }
    public static bool HasIdentity(TCProviderRelayBinding binding) {
        try {
            int[] owners = ListenerOwners(binding.Port);
            if (owners.Length != 1 || owners[0] != binding.OwnerPid || binding.OwnerPid == Process.GetCurrentProcess().Id) return false;
            using (Process process = Process.GetProcessById(binding.OwnerPid)) {
                if (process.StartTime.ToUniversalTime().Ticks != binding.OwnerStartedTicks || process.HasExited) return false;
            }
            string path = ImagePath(binding.OwnerPid);
            if (!String.Equals(path, binding.OwnerPath, StringComparison.OrdinalIgnoreCase)) return false;
            for (string item = Path.GetFullPath(path); !String.IsNullOrEmpty(item); item = Path.GetDirectoryName(item)) {
                if ((File.GetAttributes(item) & FileAttributes.ReparsePoint) != 0) return false;
            }
            return IPGlobalProperties.GetIPGlobalProperties().GetActiveTcpListeners().Any(p => p.Port == binding.Port && (p.Address.Equals(IPAddress.Loopback) || p.Address.Equals(IPAddress.Any)));
        } catch { return false; }
    }
    public static bool ProbeSocks(int port, int milliseconds) {
        using (var client = new TcpClient(AddressFamily.InterNetwork)) {
            try {
                var connect = client.ConnectAsync(IPAddress.Loopback, port);
                if (!connect.Wait(milliseconds)) return false;
                connect.GetAwaiter().GetResult(); client.ReceiveTimeout = milliseconds; client.SendTimeout = milliseconds;
                var stream = client.GetStream(); stream.Write(new byte[] { 5, 1, 0 }, 0, 3);
                return stream.ReadByte() == 5 && stream.ReadByte() == 0;
            } catch { return false; }
        }
    }
}

public sealed class TCProviderRelayHost : IDisposable {
    sealed class Connection : IDisposable {
        internal readonly long Number;
        internal readonly TCProviderRelayBinding Binding;
        internal readonly TcpClient Client;
        internal TcpClient Upstream;
        internal Connection(long number, TCProviderRelayBinding binding, TcpClient client) { Number = number; Binding = binding; Client = client; }
        public void Dispose() { try { Client.Close(); } catch { } try { if (Upstream != null) Upstream.Close(); } catch { } }
    }
    readonly object sync = new object();
    readonly int[] ports;
    readonly HashSet<int> reserved;
    readonly TcpListener[] listeners = new TcpListener[8];
    readonly ConcurrentDictionary<long, Connection> connections = new ConcurrentDictionary<long, Connection>();
    readonly SemaphoreSlim limit = new SemaphoreSlim(512, 512);
    Dictionary<int, TCProviderRelayBinding> bindings = new Dictionary<int, TCProviderRelayBinding>();
    Timer healthTimer;
    volatile bool disposed;
    int checking;
    long sequence;
    string revision = "empty";
    public string SessionId { get; private set; }
    public string Revision { get { lock (sync) { return revision; } } }
    public bool Running { get { return !disposed; } }
    public int ConnectionCount { get { return connections.Count; } }
    public TCProviderRelayHost(string sessionId, int[] listenPorts, int[] reservedPorts) {
        Guid id;
        if (!Guid.TryParse(sessionId, out id) || listenPorts == null || listenPorts.Length != 8 || listenPorts.Distinct().Count() != 8 || listenPorts.Any(p => p < 1024 || p > 65535 || p == 17890 || p == 17891)) throw new ArgumentException("InvalidRelayContract");
        SessionId = sessionId; ports = (int[])listenPorts.Clone();
        reserved = new HashSet<int>(reservedPorts ?? new int[0]); foreach (int p in ports) reserved.Add(p); reserved.Add(17890); reserved.Add(17891);
        try {
            // Bind the entire reservation before exposing any accept loop. A single
            // conflict rolls back all earlier binds, never a partial healthy host.
            for (int i = 0; i < 8; i++) {
                listeners[i] = new TcpListener(IPAddress.Loopback, ports[i]);
                listeners[i].Server.ExclusiveAddressUse = true; listeners[i].Start(128);
            }
            for (int i = 0; i < 8; i++) { Task ignored = Accept(i); }
            healthTimer = new Timer(CheckHealth, null, 1000, 1000);
        } catch { Dispose(); throw; }
    }
    public TCProviderRelayBinding[] Snapshot() { lock (sync) { return bindings.Values.OrderBy(b => b.Key).Select(b => b.Copy()).ToArray(); } }
    public void Validate(TCProviderRelayBinding[] next) {
        if (next == null || next.Length > 8) throw new ArgumentException("InvalidBindings");
        var keys = new HashSet<int>(); var slots = new Dictionary<int, string>(); var targetPorts = new Dictionary<int, string>();
        foreach (var b in next) {
            Guid id;
            if (b == null || b.Slot < 1 || b.Slot > 4 || (b.Lane != "daily" && b.Lane != "trade") || !Guid.TryParseExact(b.ProviderId, "D", out id) || id == Guid.Empty || b.Port < 1 || b.Port > 65535 || reserved.Contains(b.Port) || b.OwnerPid <= 0 || b.OwnerStartedTicks <= 0 || String.IsNullOrWhiteSpace(b.OwnerPath) || !Path.IsPathRooted(b.OwnerPath) || String.IsNullOrEmpty(b.Identity)) throw new ArgumentException("InvalidBindingOrLoopbackRisk");
            if (!keys.Add(b.Key)) throw new ArgumentException("DuplicateLane");
            if (slots.ContainsKey(b.Slot) && slots[b.Slot] != b.ProviderId) throw new ArgumentException("SplitSlotIdentity");
            if (targetPorts.ContainsKey(b.Port) && targetPorts[b.Port] != b.ProviderId) throw new ArgumentException("SharedUpstreamPort");
            slots[b.Slot] = b.ProviderId; targetPorts[b.Port] = b.ProviderId;
            if (!TradeChannelProviderRelay.HasIdentity(b)) throw new IOException("UpstreamOwnerMismatch");
            if (!TradeChannelProviderRelay.ProbeSocks(b.Port, 1200) || !TradeChannelProviderRelay.HasIdentity(b)) throw new IOException("SocksHandshakeFailed");
        }
    }
    public void Replace(TCProviderRelayBinding[] next, string expectedRevision, string newRevision, string[] protectedTags) {
        Validate(next);
        var nextMap = next.ToDictionary(b => b.Key, b => b.Copy());
        foreach (var b in nextMap.Values) { b.Healthy = true; b.Reason = null; }
        lock (sync) {
            if (disposed) throw new ObjectDisposedException("Relay");
            if (revision != expectedRevision || String.IsNullOrEmpty(newRevision)) throw new InvalidOperationException("RelayRevisionChanged");
            foreach (string tag in protectedTags ?? new string[0]) {
                int key = TagKey(tag); if (key < 0) continue;
                TCProviderRelayBinding oldBinding, newBinding;
                // A selected but unmapped slot cannot silently gain an identity.
                if (!bindings.TryGetValue(key, out oldBinding) || !nextMap.TryGetValue(key, out newBinding) || oldBinding.Fingerprint != newBinding.Fingerprint) throw new InvalidOperationException("SelectedProviderImmutable");
            }
            bindings = nextMap; revision = newRevision;
            foreach (var c in connections.Values) {
                TCProviderRelayBinding b;
                if (!nextMap.TryGetValue(c.Binding.Key, out b) || b.Fingerprint != c.Binding.Fingerprint) c.Dispose();
            }
        }
    }
    public static int TagKey(string tag) {
        for (int slot = 1; slot <= 4; slot++) {
            string daily = slot == 1 ? "provider" : "provider" + slot;
            if (tag == daily) return (slot - 1) * 2;
            if (tag == daily + "-trade") return (slot - 1) * 2 + 1;
        }
        return -1;
    }
    void CheckHealth(object ignored) {
        if (disposed || Interlocked.Exchange(ref checking, 1) != 0) return;
        try {
            foreach (var copy in Snapshot()) {
                if (!copy.Healthy || TradeChannelProviderRelay.HasIdentity(copy)) continue;
                lock (sync) {
                    TCProviderRelayBinding current;
                    if (bindings.TryGetValue(copy.Key, out current) && current.Fingerprint == copy.Fingerprint) { current.Healthy = false; current.Reason = "UpstreamOwnerLost"; }
                    foreach (var c in connections.Values) if (c.Binding.Key == copy.Key && c.Binding.Fingerprint == copy.Fingerprint) c.Dispose();
                }
            }
        } finally { Interlocked.Exchange(ref checking, 0); }
    }
    async Task Accept(int key) {
        while (!disposed) {
            TcpClient client;
            try { client = await listeners[key].AcceptTcpClientAsync().ConfigureAwait(false); } catch { if (!disposed) Dispose(); return; }
            TCProviderRelayBinding binding;
            lock (sync) { bindings.TryGetValue(key, out binding); if (binding != null) binding = binding.Copy(); }
            if (binding == null || !binding.Healthy || !limit.Wait(0)) { client.Close(); continue; }
            var connection = new Connection(Interlocked.Increment(ref sequence), binding, client);
            if (!connections.TryAdd(connection.Number, connection)) { limit.Release(); client.Close(); continue; }
            Task ignored = Forward(connection);
        }
    }
    static async Task<byte[]> ReadExact(NetworkStream stream, int count) {
        var bytes = new byte[count]; int offset = 0;
        while (offset < count) { int read = await stream.ReadAsync(bytes, offset, count - offset).ConfigureAwait(false); if (read == 0) throw new EndOfStreamException(); offset += read; }
        return bytes;
    }
    static async Task<byte[]> ReadAddress(NetworkStream stream, byte type) {
        if (type == 1) return await ReadExact(stream, 6).ConfigureAwait(false);
        if (type == 4) return await ReadExact(stream, 18).ConfigureAwait(false);
        if (type == 3) {
            byte[] length = await ReadExact(stream, 1).ConfigureAwait(false); if (length[0] == 0) throw new IOException("EmptySocksDomain");
            byte[] tail = await ReadExact(stream, length[0] + 2).ConfigureAwait(false);
            return length.Concat(tail).ToArray();
        }
        throw new IOException("SocksAddressUnsupported");
    }
    static bool LocalDestination(byte type, byte[] address) {
        IPAddress ip;
        if (type == 1) ip = new IPAddress(address.Take(4).ToArray());
        else if (type == 4) ip = new IPAddress(address.Take(16).ToArray());
        else {
            string name = Encoding.ASCII.GetString(address, 1, address[0]).TrimEnd('.');
            if (name.Any(c => c <= 32 || c >= 127) || String.Equals(name, "localhost", StringComparison.OrdinalIgnoreCase) || String.Equals(name, "localhost.localdomain", StringComparison.OrdinalIgnoreCase) || name.EndsWith(".localhost", StringComparison.OrdinalIgnoreCase) || String.Equals(name, Environment.MachineName, StringComparison.OrdinalIgnoreCase)) return true;
            try { var host = IPGlobalProperties.GetIPGlobalProperties(); if (String.Equals(name, host.HostName, StringComparison.OrdinalIgnoreCase) || String.Equals(name, host.HostName + "." + host.DomainName, StringComparison.OrdinalIgnoreCase)) return true; } catch { return true; }
            if (!IPAddress.TryParse(name, out ip)) return false; // Never resolve via this host's DNS.
        }
        if (ip.IsIPv4MappedToIPv6) ip = ip.MapToIPv4();
        if (IPAddress.IsLoopback(ip) || ip.Equals(IPAddress.Any) || ip.Equals(IPAddress.IPv6Any)) return true;
        try { return NetworkInterface.GetAllNetworkInterfaces().SelectMany(n => n.GetIPProperties().UnicastAddresses).Any(a => a.Address.Equals(ip)); } catch { return true; }
    }
    static async Task Copy(NetworkStream source, NetworkStream destination, Socket output) {
        byte[] buffer = new byte[16384];
        while (true) { int count = await source.ReadAsync(buffer, 0, buffer.Length).ConfigureAwait(false); if (count == 0) break; await destination.WriteAsync(buffer, 0, count).ConfigureAwait(false); }
        try { output.Shutdown(SocketShutdown.Send); } catch { }
    }
    async Task Forward(Connection c) {
        Timer deadline = null;
        try {
            c.Client.NoDelay = true; deadline = new Timer(delegate { c.Dispose(); }, null, 5000, Timeout.Infinite);
            NetworkStream downstream = c.Client.GetStream(); byte[] greeting = await ReadExact(downstream, 2).ConfigureAwait(false);
            if (greeting[0] != 5 || greeting[1] == 0) return;
            byte[] methods = await ReadExact(downstream, greeting[1]).ConfigureAwait(false);
            byte method = methods.Contains((byte)0) ? (byte)0 : (byte)255;
            await downstream.WriteAsync(new byte[] { 5, method }, 0, 2).ConfigureAwait(false); if (method != 0) return;
            byte[] header = await ReadExact(downstream, 4).ConfigureAwait(false);
            if (header[0] != 5 || header[1] != 1 || header[2] != 0) { await downstream.WriteAsync(new byte[] { 5, 7, 0, 1, 0, 0, 0, 0, 0, 0 }, 0, 10).ConfigureAwait(false); return; }
            byte[] address = await ReadAddress(downstream, header[3]).ConfigureAwait(false);
            int destinationPort = (address[address.Length - 2] << 8) | address[address.Length - 1];
            if (destinationPort == 0 || reserved.Contains(destinationPort) || LocalDestination(header[3], address)) { await downstream.WriteAsync(new byte[] { 5, 2, 0, 1, 0, 0, 0, 0, 0, 0 }, 0, 10).ConfigureAwait(false); return; }
            if (!TradeChannelProviderRelay.HasIdentity(c.Binding)) return;
            c.Upstream = new TcpClient(AddressFamily.InterNetwork); c.Upstream.NoDelay = true;
            await c.Upstream.ConnectAsync(IPAddress.Loopback, c.Binding.Port).ConfigureAwait(false);
            if (!TradeChannelProviderRelay.HasIdentity(c.Binding)) return;
            lock (sync) { TCProviderRelayBinding current; if (!bindings.TryGetValue(c.Binding.Key, out current) || !current.Healthy || current.Fingerprint != c.Binding.Fingerprint) return; }
            NetworkStream upstream = c.Upstream.GetStream();
            await upstream.WriteAsync(new byte[] { 5, 1, 0 }, 0, 3).ConfigureAwait(false);
            byte[] hello = await ReadExact(upstream, 2).ConfigureAwait(false); if (hello[0] != 5 || hello[1] != 0) return;
            byte[] request = header.Concat(address).ToArray(); await upstream.WriteAsync(request, 0, request.Length).ConfigureAwait(false);
            byte[] replyHeader = await ReadExact(upstream, 4).ConfigureAwait(false);
            if (replyHeader[0] != 5 || replyHeader[2] != 0) return;
            byte[] replyAddress = await ReadAddress(upstream, replyHeader[3]).ConfigureAwait(false);
            byte[] reply = replyHeader.Concat(replyAddress).ToArray(); await downstream.WriteAsync(reply, 0, reply.Length).ConfigureAwait(false); if (replyHeader[1] != 0) return;
            deadline.Dispose(); deadline = null;
            Task up = Copy(downstream, upstream, c.Upstream.Client), down = Copy(upstream, downstream, c.Client.Client);
            Task first = await Task.WhenAny(up, down).ConfigureAwait(false); if (first.IsFaulted || first.IsCanceled) c.Dispose();
            await Task.WhenAll(up, down).ConfigureAwait(false);
        } catch { /* No destinations, payloads or credentials are logged. */ }
        finally { if (deadline != null) deadline.Dispose(); Connection removed; connections.TryRemove(c.Number, out removed); c.Dispose(); limit.Release(); }
    }
    public void Dispose() {
        lock (sync) {
            if (disposed) return; disposed = true;
            if (healthTimer != null) healthTimer.Dispose();
            bindings.Clear();
            foreach (var listener in listeners) if (listener != null) try { listener.Stop(); } catch { }
            foreach (var c in connections.Values) c.Dispose();
        }
    }
}
