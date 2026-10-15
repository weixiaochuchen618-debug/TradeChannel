"""Local login-only SSH server. Never executes or accepts a remote command."""
import sys

sys.dont_write_bytecode = True
import base64
import hashlib
import json
import pathlib
import socket
import threading
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "deployment" / "test-libs"))
import paramiko

metadata, log_path = map(pathlib.Path, sys.argv[1:3])
key = paramiko.RSAKey.generate(3072)
guard = threading.Lock()
stats = {"Authenticated": 0, "AuthenticationAttempts": [], "RemoteCommandAttempts": 0}


def save_stats():
    log_path.write_text(json.dumps(stats), encoding="utf8")


class Server(paramiko.ServerInterface):
    def check_auth_password(self, username, password):
        # Both constants are synthetic test inputs. Record equality only: no
        # received password, key, exception, or reversible representation.
        user_matches = username == "root"
        corrected_matches = password == "TC_Identity_Local_Fixture_Only!"
        initial_matches = password == "TC_Identity_Deliberately_Wrong!"
        accepted = user_matches and corrected_matches
        with guard:
            stats["AuthenticationAttempts"].append({
                "UserMatchesExpected": user_matches,
                "MatchesInitialTestPassword": initial_matches,
                "MatchesCorrectedTestPassword": corrected_matches,
                "Accepted": accepted,
            })
            stats["Authenticated"] += int(accepted)
            save_stats()
        return paramiko.AUTH_SUCCESSFUL if accepted else paramiko.AUTH_FAILED

    def get_allowed_auths(self, username):
        return "password"

    def check_channel_request(self, kind, channel_id):
        return paramiko.OPEN_SUCCEEDED if kind == "session" else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED

    def check_channel_exec_request(self, channel, command):
        with guard:
            stats["RemoteCommandAttempts"] += 1
            save_stats()
        return False


def serve(sock):
    transport = paramiko.Transport(sock)
    try:
        transport.add_server_key(key)
        transport.start_server(server=Server())
        until = time.monotonic() + 120
        while transport.is_active() and time.monotonic() < until:
            channel = transport.accept(0.25)
            if channel is not None:
                channel.close()
    except Exception:
        pass
    finally:
        transport.close()


listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
listener.bind(("127.0.0.1", 0))
listener.listen(8)
listener.settimeout(0.25)
save_stats()
metadata.write_text(json.dumps({
    "Port": listener.getsockname()[1],
    "Fingerprint": "SHA256:" + base64.b64encode(hashlib.sha256(key.asbytes()).digest()).decode().rstrip("="),
}), encoding="utf8")
until = time.monotonic() + 120
while time.monotonic() < until:
    try:
        sock, address = listener.accept()
        assert address[0] == "127.0.0.1"
        threading.Thread(target=serve, args=(sock,), daemon=True).start()
    except socket.timeout:
        pass
listener.close()
