"""Real sing-box, generated routing rules, local dummy SOCKS servers only.

No WireGuard identity, TUN, system proxy, route, firewall or active controller.
The copied test executable has a separate name so production identity checks
cannot mistake it for the live engine.
"""
import json
import os
from pathlib import Path
import shutil
import socket
import socketserver
import struct
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request


def exact(sock, length):
    value = b""
    while len(value) < length:
        chunk = sock.recv(length - len(value))
        if not chunk:
            raise EOFError("fixture connection closed")
        value += chunk
    return value


def address(sock, kind):
    if kind == 1:
        exact(sock, 4)
    elif kind == 3:
        exact(sock, exact(sock, 1)[0])
    elif kind == 4:
        exact(sock, 16)
    else:
        raise ValueError("unexpected address type")
    exact(sock, 2)


class ProxyHandler(socketserver.BaseRequestHandler):
    def handle(self):
        s = self.request
        s.settimeout(60)
        try:
            version, count = exact(s, 2)
            assert version == 5
            exact(s, count)
            s.sendall(b"\x05\x00")
            head = exact(s, 4)
            assert head[:3] == b"\x05\x01\x00"
            address(s, head[3])
            s.sendall(b"\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x00")
            # Do not connect to the requested destination. Act as a local echo.
            s.sendall(self.server.label)
            while True:
                data = s.recv(4096)
                if not data:
                    break
                s.sendall(data)
        except (OSError, EOFError):
            pass


class ProxyServer(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = False


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def main():
    package = Path(__file__).resolve().parent.parent
    servers = []
    streams = []
    engine = None
    checks = []
    with tempfile.TemporaryDirectory(prefix="TC-Selectors-") as temp:
        root = Path(temp)
        try:
            for label in (b"HK\n", b"A1\n", b"B2\n", b"BT\n"):
                server = ProxyServer(("127.0.0.1", 0), ProxyHandler)
                server.label = label
                threading.Thread(target=server.serve_forever, daemon=True).start()
                servers.append(server)
            ports = [s.server_address[1] for s in servers]
            policy_path = root / "policy.json"
            shell = Path(os.environ["WINDIR"]) / "System32/WindowsPowerShell/v1.0/powershell.exe"
            env = dict(os.environ, PSModulePath=str(shell.parent / "Modules"))
            subprocess.run([str(shell), "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                            "-File", str(package / "tests/Export-TestProviderPolicy.ps1"),
                            "-OutputPath", str(policy_path), "-DailyA", str(ports[1]),
                            "-DailyB", str(ports[2]), "-TradeB", str(ports[3]), "-AgentRoot", str(root)],
                           env=env, check=True, capture_output=True, timeout=25)
            policy = json.loads(policy_path.read_text(encoding="utf-8-sig"))
            inlet, application_port, api_port = free_port(), free_port(), free_port()
            while api_port in (inlet, application_port):
                api_port = free_port()
            while application_port == inlet:
                application_port = free_port()
            config = {
                "log": {"level": "error"},
                "inbounds": [{"type": "mixed", "tag": "egress-probe", "listen": "127.0.0.1",
                              "listen_port": inlet, "users": [
                                  {"username": "tradechannel-probe", "password": "fixture-only"},
                                  {"username": "tradechannel-daily", "password": "fixture-only"}]},
                             {"type": "mixed", "tag": "test-application", "listen": "127.0.0.1", "listen_port": application_port}],
                "outbounds": [{"type": "socks", "tag": "hk", "server": "127.0.0.1",
                               "server_port": ports[0], "version": "5"}] + policy["outbounds"],
                "dns": {"servers": [{"type": "udp", "tag": "dns-direct", "server": "127.0.0.1"},
                                    {"type": "udp", "tag": "dns-trade", "server": "127.0.0.1"}],
                        "rules": policy["dns"]["rules"], "final": "dns-direct"},
                "route": policy["route"],
                "experimental": {"clash_api": {"external_controller": f"127.0.0.1:{api_port}",
                                                "secret": "fixture-only", "default_mode": "global"}},
            }
            assert not config.get("endpoints")
            assert all(i["type"] == "mixed" and i["listen"] == "127.0.0.1" for i in config["inbounds"])
            config_path = root / "fixture.json"
            config_path.write_text(json.dumps(config), encoding="utf-8")
            executable = root / "tc-test-engine.exe"
            shutil.copyfile(package / "assets/sing-box.exe", executable)
            subprocess.run([str(executable), "check", "-c", str(config_path)], check=True,
                           capture_output=True, timeout=15)
            log = open(root / "engine.log", "wb")
            engine = subprocess.Popen([str(executable), "run", "-c", str(config_path)],
                                      stdout=log, stderr=log, creationflags=subprocess.CREATE_NO_WINDOW)
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

            def api(path, method="GET", body=None):
                req = urllib.request.Request(f"http://127.0.0.1:{api_port}{path}", method=method,
                    data=json.dumps(body).encode() if body is not None else None,
                    headers={"Authorization": "Bearer fixture-only", "Content-Type": "application/json"})
                with opener.open(req, timeout=2) as response:
                    raw = response.read()
                    return json.loads(raw) if raw else None

            for _ in range(60):
                try:
                    api("/configs")
                    break
                except OSError:
                    time.sleep(.1)
            else:
                raise AssertionError("isolated engine did not start")

            def stream(lane, expect):
                s = socket.create_connection(("127.0.0.1", inlet), 3)
                streams.append(s)
                s.sendall(b"\x05\x01\x02")
                assert exact(s, 2) == b"\x05\x02"
                name = f"tradechannel-{lane}".encode()
                password = b"fixture-only"
                s.sendall(b"\x01" + bytes([len(name)]) + name + bytes([len(password)]) + password)
                assert exact(s, 2) == b"\x01\x00"
                # Documentation IP, consumed only by dummy server, never dialed.
                s.sendall(b"\x05\x01\x00\x01" + socket.inet_aton("192.0.2.42") + struct.pack("!H", 444))
                head = exact(s, 4)
                assert head[:3] == b"\x05\x00\x00"
                address(s, head[3])
                assert exact(s, 3) == expect
                return s

            def application(host, expect):
                s = socket.create_connection(("127.0.0.1", application_port), 3)
                s.settimeout(5)
                streams.append(s)
                s.sendall(b"\x05\x01\x00")
                assert exact(s, 2) == b"\x05\x00"
                encoded = host.encode()
                s.sendall(b"\x05\x01\x00\x03" + bytes([len(encoded)]) + encoded + struct.pack("!H", 444))
                head = exact(s, 4)
                assert head[:3] == b"\x05\x00\x00", head
                address(s, head[3])
                assert exact(s, 3) == expect
                return s

            def mode_script(mode):
                result_path = root / "script-result.json"
                wrapper = root / "mode-entrypoint.ps1"
                wrapper.write_text("""param($Target,$Config,$Mode,$Output)
$ErrorActionPreference='Stop'
function Clear-DnsClientCache {param($ErrorAction)}
$result=& $Target -Mode $Mode -ConfigPath $Config
[IO.File]::WriteAllText($Output,($result|ConvertTo-Json -Depth 6),(New-Object Text.UTF8Encoding($false)))
""", encoding="utf-8-sig")
                subprocess.run([str(shell), "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                                "-File", str(wrapper), "-Target", str(package / "runtime/Set-TradeChannelMode.ps1"),
                                "-Config", str(config_path), "-Mode", mode, "-Output", str(result_path)],
                               env=env, check=True, capture_output=True, timeout=15)
                return json.loads(result_path.read_text(encoding="utf-8-sig"))

            assert set(api("/configs")["mode-list"]) == {"global", "rule"}
            real_trade = application("trading.example", b"HK\n")
            assistant = application("assistant.example", b"HK\n")
            ordinary = application("ordinary.example", b"HK\n")
            api("/proxies/daily-exit", "PUT", {"name": "provider2"})
            original_ids = {c["id"] for c in api("/connections")["connections"]
                            if c["metadata"]["host"] in ("trading.example", "assistant.example")}
            assert len(original_ids) == 2
            switched = mode_script("Trading")
            assert switched["ControllerMode"] == "rule" and switched["AssistantConnectionsKept"] == 1, switched
            assert ordinary.recv(1) == b"", "only the daily flow should close on a mode change"
            for s in (real_trade, assistant):
                s.sendall(b"alive")
                assert exact(s, 5) == b"alive"
            assert original_ids <= {c["id"] for c in api("/connections")["connections"]}
            day = application("ordinary.example", b"B2\n")
            assert mode_script("Global")["ControllerMode"] == "global"
            assert day.recv(1) == b""
            for s in (real_trade, assistant):
                s.sendall(b"back")
                assert exact(s, 4) == b"back"
            assert original_ids <= {c["id"] for c in api("/connections")["connections"]}
            for s in (real_trade, assistant, ordinary, day):
                s.close()
            checks.append("product mode commands preserve real trading and listed assistant sessions in both directions")
            checks.append("ordinary connections alone reconnect through the selected provider after leaving global mode")
            mode_script("Trading")

            trade = stream("probe", b"HK\n")
            time.sleep(.1)
            trade_ids = {c["id"] for c in api("/connections")["connections"] if "trade-exit" in c["chains"]}
            assert len(trade_ids) == 1
            checks.append("trade starts at simulated HK")
            for selected, label in (("provider", b"A1\n"), ("provider2", b"B2\n")):
                api("/proxies/daily-exit", "PUT", {"name": selected})
                day = stream("daily", label)
                day.close()
                trade.sendall(b"still-trading")
                assert exact(trade, 13) == b"still-trading"
                now_ids = {c["id"] for c in api("/connections")["connections"]}
                assert trade_ids <= now_ids
                assert api("/proxies/trade-exit")["now"] == "hk"
                checks.append(f"daily {selected} leaves original trade connection intact")
            api("/proxies/daily-exit", "PUT", {"name": "direct"})
            trade.sendall(b"daily-off")
            assert exact(trade, 9) == b"daily-off"
            checks.append("daily direct fallback leaves trade intact")
            try:
                api("/proxies/trade-exit", "PUT", {"name": "provider2"})
                raise AssertionError("daily port unexpectedly selectable for trading")
            except urllib.error.HTTPError as error:
                assert 400 <= error.code < 500
            assert api("/proxies/trade-exit")["now"] == "hk"
            checks.append("trade selector rejects whitelist-only outbound")
            api("/proxies/trade-exit", "PUT", {"name": "provider2-trade"})
            backup = stream("probe", b"BT\n")
            backup.sendall(b"dedicated")
            assert exact(backup, 9) == b"dedicated"
            checks.append("explicit backup uses dedicated provider port")
            assert engine.poll() is None
            checks.append("single isolated engine survives all selector changes")
            print(json.dumps({"Passed": True, "Checks": len(checks), "Cases": checks,
                              "NetworkScope": "loopback fixtures only; no live tunnel or routes"}, ensure_ascii=False))
        finally:
            for stream_socket in streams:
                stream_socket.close()
            if engine is not None:
                engine.terminate()
                engine.wait(timeout=8)
                log.close()
            for server in servers:
                server.shutdown()
                server.server_close()


if __name__ == "__main__":
    main()
