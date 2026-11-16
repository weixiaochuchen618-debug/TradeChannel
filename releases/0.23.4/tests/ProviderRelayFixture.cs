// Loopback-only SOCKS fixture. CONNECT is acknowledged but NEVER opens an
// outbound connection or resolves a name. Payload is marker + exact echo.
using System;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
public static class ProviderRelayFixture {
    static byte[] Read(Stream stream, int length) {
        byte[] data = new byte[length]; int offset = 0;
        while (offset < length) { int n = stream.Read(data, offset, length - offset); if (n == 0) throw new EndOfStreamException(); offset += n; }
        return data;
    }
    static void Serve(TcpClient client, string marker, bool wrongProtocol) {
        using (client) {
            try {
                client.ReceiveTimeout = 10000; client.SendTimeout = 10000; var stream = client.GetStream();
                if (wrongProtocol) { byte[] bad = Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\n\r\n"); stream.Write(bad, 0, bad.Length); return; }
                byte[] head = Read(stream, 2); if (head[0] != 5) return; Read(stream, head[1]); stream.Write(new byte[] { 5, 0 }, 0, 2);
                head = Read(stream, 4); if (head[0] != 5 || head[1] != 1) return;
                if (head[3] == 1) Read(stream, 6); else if (head[3] == 4) Read(stream, 18); else if (head[3] == 3) Read(stream, Read(stream, 1)[0] + 2); else return;
                stream.Write(new byte[] { 5, 0, 0, 1, 127, 0, 0, 1, 0, 0 }, 0, 10);
                byte[] prefix = Encoding.ASCII.GetBytes(marker); stream.Write(prefix, 0, prefix.Length);
                client.ReceiveTimeout = 0; byte[] buffer = new byte[16384]; int count;
                while ((count = stream.Read(buffer, 0, buffer.Length)) > 0) stream.Write(buffer, 0, count);
                client.Client.Shutdown(SocketShutdown.Send);
            } catch { }
        }
    }
    public static int Main(string[] args) {
        if (args.Length != 5) return 2;
        int port = Int32.Parse(args[0]), parent = Int32.Parse(args[3]); long parentTicks = Int64.Parse(args[4]);
        var listener = new TcpListener(IPAddress.Loopback, port); listener.Server.ExclusiveAddressUse = true;
        try {
            listener.Start(); File.WriteAllText(args[1], ((IPEndPoint)listener.LocalEndpoint).Port.ToString());
            using (var timer = new Timer(delegate {
                try { using (var p = Process.GetProcessById(parent)) { if (p.HasExited || p.StartTime.ToUniversalTime().Ticks != parentTicks) Environment.Exit(0); } }
                catch { Environment.Exit(0); }
            }, null, 500, 500)) {
                while (true) { TcpClient client = listener.AcceptTcpClient(); Task ignored = Task.Run(delegate { Serve(client, args[2], args[2] == "HTTP"); }); }
            }
        } catch { return 1; } finally { listener.Stop(); }
    }
}
