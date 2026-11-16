"""Real loopback SSH + HTTPS; installs/authorizes against MemoryFS/fake kernel.

The SSH handler verifies the exact production stdin source bundle and invokes
ssh_entry with an isolated application. Shell/systemd/kernel effects are NOT
executed on this Windows machine. Only generated TLS files touch the supplied
temporary root. No real service credentials or server is used.
"""
import hashlib
import json
import os
from pathlib import Path
import socket
import sys
import threading
import time
import types

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "deployment" / "test-libs"))
if os.environ.get("TC_PAIR_ONLINE_TEST_DEPS"):
    sys.path.insert(0, os.environ["TC_PAIR_ONLINE_TEST_DEPS"])
import paramiko
from pairing_online_test_support import Fixture, online, mg, tc


def main():
    directory = Path(sys.argv[1]).resolve()
    if not directory.is_dir() or not directory.name.startswith("tc-online-"):
        raise RuntimeError("An explicit isolated test directory is required")
    fixture = Fixture()
    keyfile, certfile = directory / "tls.key", directory / "tls.crt"
    keyfile.write_text(Fixture.certificate[0], encoding="ascii")
    certfile.write_text(Fixture.certificate[1], encoding="ascii")
    stats = {"SshCommands": 0, "AuthenticationCount": 0, "HashVerified": True, "SourcesCompiled": True, "EmbeddedMethodsVerified": True, "HttpAuthorizations": 0, "DroppedResponses": 0}
    control = {"drop": False, "ssh_drop": False, "bad_binding": False}
    threads = []
    connections = []

    class DropOnceHandler(online.PairingHandler):
        def reply(self, status, value):
            if value.get("Data", {}).get("Status") == "Authorized":
                stats["HttpAuthorizations"] += 1
                if control["drop"]:
                    control["drop"] = False
                    stats["DroppedResponses"] += 1
                    self.close_connection = True
                    self.connection.shutdown(socket.SHUT_RDWR)
                    self.connection.close()
                    return
            super().reply(status, value)

    https = online.PairingServer(("127.0.0.1", 0), fixture.application, str(certfile), str(keyfile))
    https.RequestHandlerClass = DropOnceHandler
    https_thread = threading.Thread(target=https.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
    https_thread.start()
    ssh_key = paramiko.RSAKey.generate(3072)
    ssh = socket.socket(); ssh.bind(("127.0.0.1", 0)); ssh.listen(8); ssh.settimeout(0.2)
    stopped = threading.Event()
    pin = "SHA256:" + __import__("base64").b64encode(hashlib.sha256(ssh_key.asbytes()).digest()).decode().rstrip("=")

    class Server(paramiko.ServerInterface):
        def check_auth_password(self, username, password):
            if username == "root" and password == "TC_Online_Loopback_Only!":
                stats["AuthenticationCount"] += 1
                return paramiko.AUTH_SUCCESSFUL
            return paramiko.AUTH_FAILED

        def get_allowed_auths(self, username):
            return "password"

        def check_channel_request(self, kind, channel_id):
            return paramiko.OPEN_SUCCEEDED if kind == "session" else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED

        def check_channel_exec_request(self, channel, command):
            def run():
                try:
                    if not command.decode().startswith("python3 -I -c '"):
                        raise RuntimeError("Unexpected remote entry")
                    raw = bytearray()
                    while True:
                        part = channel.recv(32768)
                        if not part:
                            break
                        raw.extend(part)
                        if len(raw) > 4194304:
                            raise RuntimeError("Oversized SSH input")
                    payload = json.loads(raw.decode())
                    if "Source" in payload:
                        valid = hashlib.sha256(payload["Source"].encode()).hexdigest() == payload["SourceSHA256"]
                        stats["HashVerified"] &= valid
                        if not valid:
                            raise RuntimeError("Source hash mismatch")
                        compile(payload["Source"], "tradechannel_linux.py", "exec")
                        stats["SshCommands"] += 1
                        fixture.backend.execution_context = payload.get("ExecutionContext")
                        try:
                            result = tc.envelope(payload["Action"], payload["Input"], fixture.backend)
                        finally:
                            fixture.backend.execution_context = None
                        channel.sendall(mg.compact(result).encode())
                        channel.send_exit_status(0 if result["Ok"] else 1)
                        return
                    valid = hashlib.sha256(payload["SourcesJson"].encode()).hexdigest() == payload["SourcesSHA256"]
                    stats["HashVerified"] &= valid
                    if not valid:
                        raise RuntimeError("Source hash mismatch")
                    sources = json.loads(payload["SourcesJson"])
                    if set(sources) != set(online.SOURCES):
                        raise RuntimeError("Unexpected modules")
                    for name, source in sources.items():
                        compile(source, name, "exec")
                    registry = types.ModuleType("online_payload_registry")
                    registry.__file__ = "connection_methods.py"
                    exec(compile(sources["connection_methods.py"], registry.__file__, "exec"), registry.__dict__)
                    methods_match = registry.declaration() == tc.connection_methods.declaration()
                    stats["EmbeddedMethodsVerified"] &= methods_match
                    if not methods_match:
                        raise RuntimeError("Embedded connection methods differ")
                    stats["SshCommands"] += 1
                    result = online.ssh_entry(payload["Request"], sources, application=fixture.application,
                                              run_system=lambda argv: fixture.system_commands.append(argv), listener_start=lambda app: None,
                                              execution_context=payload.get("ExecutionContext"), sources_sha256=payload["SourcesSHA256"])
                    if control["ssh_drop"]:
                        control["ssh_drop"] = False
                        channel.send_exit_status(1)
                        return
                    if control["bad_binding"] and result.get("OperationBinding"):
                        control["bad_binding"] = False
                        result["OperationBinding"]["OperationId"] = "11111111-2222-4333-8444-555555555555"
                    channel.sendall(mg.compact(result).encode())
                    channel.send_exit_status(0 if result["Ok"] else 1)
                except Exception:
                    channel.sendall(b'{"Ok":false,"Action":"create","Data":{"Code":"FixtureDispatchFailed"}}')
                    channel.send_exit_status(1)
                finally:
                    channel.close()
            worker = threading.Thread(target=run, daemon=True); threads.append(worker); worker.start()
            return True

    def accept():
        while not stopped.is_set():
            try:
                connection, _ = ssh.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            transport = paramiko.Transport(connection)
            connections.append(transport)
            transport.add_server_key(ssh_key)
            try:
                transport.start_server(server=Server())
            except Exception:
                transport.close()

    thread = threading.Thread(target=accept, daemon=True); thread.start()
    print(mg.compact(dict(fixture.expected, SshPort=ssh.getsockname()[1], SshFingerprint=pin,
                         PublicHost="127.0.0.1", Port=https.server_address[1])), flush=True)
    try:
        for line in sys.stdin:
            request = json.loads(line.lstrip("\ufeff"))
            action = request["Action"]
            if action == "stats":
                value = dict(stats, PeerCount=fixture.count(), NetworkScope="LoopbackOnly", Kernel="Fake",
                             SystemCommands=fixture.system_commands)
                # Source text necessarily mentions field names; inspect server
                # state/peer records only when checking client private material.
                value["NoClientPrivateKey"] = not any("<RSAKeyValue>" in text or '"RecipientPrivateKey"' in text for path, text in fixture.fs.files.items() if "/runtime/" not in path)
            elif action == "drop_next":
                control["drop"] = True; value = {"Ready": True}
            elif action == "drop_ssh":
                control["ssh_drop"] = True; value = {"Ready": True}
            elif action == "bad_binding":
                control["bad_binding"] = True; value = {"Ready": True}
            elif action == "advance":
                fixture.clock.offset += __import__("datetime").timedelta(seconds=int(request["Seconds"]))
                value = {"Advanced": True}
            elif action == "offline_authorize":
                value = fixture.backend.execute("authorize_external", request["Input"])
            elif action == "quit":
                break
            else:
                raise RuntimeError("Unknown fixture control")
            print(mg.compact({"Ok": True, "Data": value}), flush=True)
    finally:
        stopped.set(); ssh.close()
        for transport in connections:
            transport.close()
        https.shutdown(); https.server_close(); https_thread.join(timeout=10)
        for worker in threads:
            worker.join(timeout=2)


if __name__ == "__main__":
    main()
