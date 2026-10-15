"""Loopback SSH protocol fixture. Parses payloads, NEVER executes backend source."""
import sys
sys.dont_write_bytecode = True
import base64, hashlib, json, pathlib, socket, threading, time
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / 'deployment' / 'test-libs'))
import paramiko

metadata, state_path, log_path = map(pathlib.Path, sys.argv[1:4])
key = paramiko.RSAKey.generate(3072)
guard = threading.Lock()
stats = {'Authenticated': 0, 'Actions': [], 'SourceDigestsVerified': 0}

def save_stats():
    log_path.write_text(json.dumps(stats), encoding='utf8')

class Server(paramiko.ServerInterface):
    def check_auth_password(self, username, password):
        if username == 'root' and password == 'TC_Identity_Local_Fixture_Only!':
            with guard:
                stats['Authenticated'] += 1
                save_stats()
            return paramiko.AUTH_SUCCESSFUL
        return paramiko.AUTH_FAILED

    def get_allowed_auths(self, username):
        return 'password'

    def check_channel_request(self, kind, channel_id):
        return paramiko.OPEN_SUCCEEDED if kind == 'session' else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED

    def check_channel_exec_request(self, channel, command):
        if not command.decode('utf8').startswith("python3 -I -c 'import sys,json,hashlib,io;"):
            return False
        threading.Thread(target=read_payload, args=(channel,), daemon=True).start()
        return True

def read_payload(channel):
    try:
        content = bytearray()
        while True:
            part = channel.recv(65536)
            if not part:
                break
            content.extend(part)
            if len(content) > 4194304:
                raise ValueError('InputTooLarge')
        payload = json.loads(content.decode('utf8'))
        if hashlib.sha256(payload['Source'].encode('utf8')).hexdigest() != payload['SourceSHA256']:
            raise ValueError('SourceDigestMismatch')
        action = payload['Action']
        # Empty input is the only accepted read. No NetworkProbe, capture, shell
        # execution, file writes on a server, or network configuration is possible.
        if payload['Input'] != {} or action not in ('server_info', 'inspect', 'capabilities'):
            reply = {'Ok': False, 'Action': action, 'Data': {'Code': 'FixtureMutationForbidden'}}
        else:
            state = json.loads(state_path.read_text(encoding='utf-8-sig'))
            if state.get('PrerequisiteMissing'):
                with guard:
                    stats['Actions'].append(action)
                    stats['SourceDigestsVerified'] += 1
                    save_stats()
                channel.send_exit_status(127)
                return
            data = state['ServerInfo'] if action == 'server_info' else state['Inspection'] if action == 'inspect' else {'Fixture': True}
            reply = {'Ok': True, 'Action': action, 'Data': data}
        with guard:
            stats['Actions'].append(action)
            stats['SourceDigestsVerified'] += 1
            save_stats()
        channel.sendall(json.dumps(reply).encode('utf8'))
        channel.send_exit_status(0 if reply['Ok'] else 1)
    except Exception:
        try:
            channel.send_exit_status(1)
        except Exception:
            pass
    finally:
        channel.shutdown_write()
        channel.close()

def serve(sock):
    transport = paramiko.Transport(sock)
    try:
        transport.add_server_key(key)
        transport.start_server(server=Server())
        until = time.monotonic() + 240
        channels = []
        while transport.is_active() and time.monotonic() < until:
            channel = transport.accept(0.5)
            if channel is not None:
                channels.append(channel)
            channels = [c for c in channels if not c.closed]
    except Exception:
        pass
    finally:
        transport.close()

listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
listener.bind(('127.0.0.1', 0))
listener.listen(8)
listener.settimeout(0.5)
save_stats()
metadata.write_text(json.dumps({'Port': listener.getsockname()[1], 'Fingerprint': 'SHA256:' + base64.b64encode(hashlib.sha256(key.asbytes()).digest()).decode().rstrip('=')}), encoding='utf8')
until = time.monotonic() + 240
while time.monotonic() < until:
    try:
        sock, address = listener.accept()
        assert address[0] == '127.0.0.1'
        threading.Thread(target=serve, args=(sock,), daemon=True).start()
    except socket.timeout:
        pass
listener.close()
