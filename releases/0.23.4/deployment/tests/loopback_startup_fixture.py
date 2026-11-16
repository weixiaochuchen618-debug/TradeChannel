"""Actual loopback SSH failures; never executes received commands/backend code."""
import base64
import hashlib
import json
import pathlib
import re
import shlex
import socket
import sys
import threading
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "test-libs"))
import paramiko

metadata_path = pathlib.Path(sys.argv[1])
mode = sys.argv[2]
host_key = paramiko.RSAKey.generate(2048)
stats = {"Mode": mode, "BytesReceived": 0, "BackendExecuted": False, "Commands": 0, "BootstrapSyntaxValid": False}
stats_lock = threading.Lock()


def write_stats():
    with stats_lock:
        metadata_path.with_suffix(".stats.json").write_text(json.dumps(stats), encoding="utf-8")


class Server(paramiko.ServerInterface):
    def check_auth_password(self, username, password):
        if username in ("root", "fixture") and password == "TC_Isolated_Startup_Only_31!":
            return paramiko.AUTH_SUCCESSFUL
        return paramiko.AUTH_FAILED

    def get_allowed_auths(self, username):
        return "password"

    def check_channel_request(self, kind, channel_id):
        return paramiko.OPEN_SUCCEEDED if kind == "session" else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED

    def check_channel_exec_request(self, channel, command):
        text = command.decode("utf-8")
        prefixes = ("python3 -I -c 'import sys,json,hashlib,io;",
                    "sudo -n -- python3 -I -c 'import sys,json,hashlib,io;",
                    "LC_ALL=C sudo -n -- python3 -I -c 'import sys,json,hashlib,io;")
        if not text.startswith(prefixes):
            return False
        compile(shlex.split(text)[-1], "isolated-bootstrap-syntax", "exec")
        with stats_lock:
            stats["Commands"] += 1
            stats["BootstrapSyntaxValid"] = True
        write_stats()
        threading.Thread(target=run_command, args=(channel, text), daemon=True).start()
        return True


def run_command(channel, command):
    try:
        # Give SSH exec-success its turn, then close while a payload larger
        # than the 32 KiB channel window is still being written.
        if mode != "backend_success":
            time.sleep(0.05)
        if mode == "stall_payload":
            deadline = time.monotonic() + 40
            while not channel.closed and channel.get_transport().is_active() and time.monotonic() < deadline:
                time.sleep(0.05)
            return
        if mode in ("python_missing", "sudo_denied"):
            error = b"/bin/sh: 1: python3: not found\n" if mode == "python_missing" else b"sudo: a password is required\n"
            channel.sendall_stderr(error)
            channel.send_exit_status(127 if mode == "python_missing" else 1)
            with stats_lock:
                stats["SentExitStatus"] = True
            write_stats()
            return
        if mode == "drop_partial":
            content = channel.recv(8192)
            with stats_lock:
                stats["BytesReceived"] = len(content)
            channel.get_transport().close()
            return
        if mode == "missing_exit":
            return
        marker = re.search(r"TCDeployBootstrap-[a-f0-9]{32}", command)
        if marker:
            channel.sendall_stderr((marker.group(0) + "\n").encode("ascii"))
        content = bytearray()
        while True:
            part = channel.recv(65536)
            if not part:
                break
            content.extend(part)
            if len(content) > 4194304:
                raise ValueError("InputTooLarge")
        with stats_lock:
            stats["BytesReceived"] = len(content)
        payload = json.loads(content.decode("utf-8"))
        if hashlib.sha256(payload["Source"].encode("utf-8")).hexdigest() != payload["SourceSHA256"]:
            raise ValueError("SourceDigestMismatch")
        if mode == "backend_sudo_text":
            channel.sendall_stderr(b"sudo: a password is required\n")
        succeeded = mode == "backend_success"
        code = "Completed" if succeeded else "FixtureBackendRejected"
        channel.sendall(json.dumps({"Ok": succeeded, "Action": payload["Action"], "Data": {"Code": code},
                                    "Message": "Isolated backend error"}).encode("utf-8"))
        channel.send_exit_status(0 if succeeded else 127 if mode == "backend_127" else 1)
    except Exception as error:
        with stats_lock:
            stats["FixtureErrorType"] = type(error).__name__
    finally:
        write_stats()
        try:
            channel.shutdown_write()
            channel.close()
            with stats_lock:
                stats["ChannelClosed"] = True
            write_stats()
        except Exception:
            pass


def client(sock):
    transport = paramiko.Transport(sock, default_window_size=32768, default_max_packet_size=32768)
    try:
        transport.add_server_key(host_key)
        transport.start_server(server=Server())
        deadline = time.monotonic() + 90
        channels = []
        while transport.is_active() and time.monotonic() < deadline:
            channel = transport.accept(0.5)
            if channel is not None:
                channels.append(channel)
    except Exception:
        pass
    finally:
        transport.close()


listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
listener.bind(("127.0.0.1", 0))
listener.listen(4)
listener.settimeout(0.5)
metadata_path.write_text(json.dumps({"Port": listener.getsockname()[1],
    "Fingerprint": "SHA256:" + base64.b64encode(hashlib.sha256(host_key.asbytes()).digest()).decode("ascii").rstrip("=")}), encoding="utf-8")
deadline = time.monotonic() + 90
while time.monotonic() < deadline:
    try:
        sock, _ = listener.accept()
        threading.Thread(target=client, args=(sock,), daemon=True).start()
    except socket.timeout:
        pass
listener.close()
