"""Isolated actual SSH protocol server. Only binds 127.0.0.1; never executes backend."""
import base64, hashlib, json, pathlib, socket, sys, threading, time
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / 'test-libs'))
import paramiko

key = paramiko.RSAKey.generate(3072)
stats = {'AuthenticationCount': 0, 'CommandCount': 0, 'Failures': []}
stats_lock = threading.Lock()
drop_action = sys.argv[2] if len(sys.argv) > 2 else None
drop_used = False
backend_evidence = json.loads(pathlib.Path(sys.argv[3]).read_text(encoding='utf-8-sig')) if len(sys.argv) > 3 else None

class Server(paramiko.ServerInterface):
    def check_auth_password(self, username, password):
        if username == 'root' and password == 'TC_Isolated_Fixture_Only_91!':
            with stats_lock: stats['AuthenticationCount'] += 1
            return paramiko.AUTH_SUCCESSFUL
        return paramiko.AUTH_FAILED
    def get_allowed_auths(self, username): return 'password'
    def check_channel_request(self, kind, channel_id):
        return paramiko.OPEN_SUCCEEDED if kind == 'session' else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
    def check_channel_exec_request(self, channel, command):
        command = command.decode('utf8')
        if not command.startswith("python3 -I -c 'import sys,json,hashlib,io;"):
            return False
        threading.Thread(target=run_command, args=(channel,), daemon=True).start()
        return True

def run_command(channel):
    global drop_used
    try:
        content = bytearray()
        while True:
            part = channel.recv(65536)
            if not part: break
            content.extend(part)
            if len(content) > 4194304: raise ValueError('InputTooLarge')
        payload = json.loads(content.decode('utf8'))
        if hashlib.sha256(payload['Source'].encode()).hexdigest() != payload['SourceSHA256']:
            raise ValueError('SourceDigestMismatch')
        context = payload.get('ExecutionContext')
        if (not context or context['SchemaVersion'] != 1 or context['Operation'] != payload['Action']
                or hashlib.sha256(context['WireInput'].encode('utf-8')).hexdigest() != context['InputDigest']
                or json.loads(context['WireInput']) != payload['Input']):
            raise ValueError('ExecutionContextMismatch')
        with stats_lock:
            stats['CommandCount'] += 1
            result = dict(stats)
            should_drop = payload['Action'] == drop_action and not drop_used
            if should_drop:
                drop_used = True
        if should_drop:
            channel.get_transport().close()
            return
        data = {'Fixture': 'ActualLoopbackSSH', 'StdinHashVerified': True, 'WireBindingVerified': True, 'SessionStats': result}
        if payload['Action'] == 'operation_result' and backend_evidence:
            rows = [r for r in backend_evidence['Cases'] if r['IntentId'] == payload['Input']['IntentId']]
            if len(rows) != 1 or rows[0]['Input'] != payload['Input']['OriginalInput']:
                raise ValueError('UnexpectedResolutionRequest')
            data = rows[0]['ResolutionReply']['Data']
        channel.sendall(json.dumps({'Ok': True, 'Action': payload['Action'], 'Data': data, 'Message': 'isolated'}).encode())
        channel.send_exit_status(0)
    except Exception as exc:
        with stats_lock: stats['Failures'].append(type(exc).__name__)
        try: channel.send_exit_status(1)
        except Exception: pass
    finally:
        try:
            channel.shutdown_write()
            channel.close()
        except Exception:
            pass

def client(sock):
    transport = paramiko.Transport(sock)
    try:
        transport.add_server_key(key)
        transport.start_server(server=Server())
        until = time.time() + 240
        channels = []
        while transport.is_active() and time.time() < until:
            channel = transport.accept(1)
            if channel is not None: channels.append(channel)
            channels = [item for item in channels if not item.closed]
    except Exception: pass
    finally: transport.close()

listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
listener.bind(('127.0.0.1', 0)); listener.listen(8); listener.settimeout(1)
metadata = {'Port': listener.getsockname()[1], 'Fingerprint': 'SHA256:' + base64.b64encode(hashlib.sha256(key.asbytes()).digest()).decode().rstrip('=')}
pathlib.Path(sys.argv[1]).write_text(json.dumps(metadata), encoding='utf8')
until = time.time() + 240
while time.time() < until:
    try:
        sock, _ = listener.accept()
        threading.Thread(target=client, args=(sock,), daemon=True).start()
    except socket.timeout: pass
listener.close()
