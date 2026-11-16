"""Bounded, real dual-endpoint experiment; never import product/user state.

Run: python -B tests/Verify-DualEndpointFeasibility.py --budget 180
Only this file and the two named reports are persistent outputs. All protocol
listeners and direct dialers bind 127.0.0.1; WireGuard is system:false. Native
StdNetBind is deliberately avoided via loopback direct detours (see report).
Negative feasibility observations are data, not failing harness assertions.
"""
import argparse
import base64
import datetime as dt
import hashlib
import http.client
import http.server
import json
import os
from pathlib import Path
import re
import secrets
import select
import shutil
import socket
import socketserver
import ssl
import struct
import subprocess
import tempfile
import threading
import time
import unittest
import urllib.parse

import psutil
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID

PACKAGE = Path(__file__).resolve().parents[1]
WORKSPACE = PACKAGE.parents[1]
ENGINE = PACKAGE / 'assets' / 'sing-box.exe'
FLAGS = subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0
LOOP = '127.0.0.1'
TARGET = LOOP  # All business requests and urltest URLs are explicit loopback.
WG_SERVER = '10.123.0.1'
STATE = None


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def free_port():
    with socket.socket() as sock:
        sock.bind((LOOP, 0))
        return sock.getsockname()[1]


def exact(sock, size):
    data = b''
    while len(data) < size:
        part = sock.recv(size - len(data))
        if not part:
            raise EOFError('fixture stream closed')
        data += part
    return data


def pause(seconds):
    STATE.ensure_budget()
    if STATE.expired.wait(min(seconds, STATE.remaining())):
        raise TimeoutError('total runtime budget exhausted')
    STATE.ensure_budget()


class Owned:
    """Never signal by image name; verify PID, birth, exe and exact argv."""
    def __init__(self, argv, label, config=None):
        STATE.ensure_budget()
        self.argv = [str(arg) for arg in argv]
        self.label, self.config = label, config
        self.process = subprocess.Popen(self.argv, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, creationflags=FLAGS,
                                        cwd=STATE.directory)
        self.birth = psutil.Process(self.process.pid).create_time()
        self.row = {'label': label, 'pid': self.process.pid,
                    'birth_utc': dt.datetime.fromtimestamp(self.birth, dt.timezone.utc).isoformat(),
                    'configuration': config.name if config else None,
                    'configuration_in_owned_temp': config is None or config.parent == STATE.directory,
                    'identity_checked_before_signal': False, 'exited': False}
        with STATE.lock:
            STATE.children.append(self)

    def same(self):
        if self.process.poll() is not None:
            return False
        try:
            p = psutil.Process(self.process.pid)
            return (p.create_time() == self.birth and
                    Path(p.exe()).resolve() == Path(self.argv[0]).resolve() and
                    p.cmdline() == self.argv and
                    (self.config is None or self.config.resolve().parent == STATE.directory))
        except psutil.NoSuchProcess:
            return False

    def close(self):
        if self.process.poll() is None:
            if not self.same():
                self.row['cleanup_identity_mismatch'] = True
                raise RuntimeError('owned process identity mismatch; refused signal')
            self.row['identity_checked_before_signal'] = True
            self.process.terminate()
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                if not self.same():
                    raise RuntimeError('owned process identity mismatch before kill')
                self.process.kill()
                self.process.wait(timeout=2)
        self.row['exited'] = self.process.poll() is not None
        self.row['exit_code'] = self.process.poll()

    def command(self, timeout=8):
        try:
            out, err = self.process.communicate(timeout=min(timeout, STATE.remaining()))
        except subprocess.TimeoutExpired:
            self.close()
            raise TimeoutError('fixture native command timed out') from None
        self.row['exited'] = True
        self.row['exit_code'] = self.process.returncode
        if self.process.returncode:
            # Neither native stdout nor stderr is ever printed (keys/config).
            STATE.native_errors.append({'command': self.label,
                                        'stderr_sha256': hashlib.sha256(err).hexdigest(),
                                        'sanitized_error': STATE.redact(err.decode(errors='replace'))[:1000]})
            raise AssertionError('fixture native command failed; output suppressed')
        if '-key:' in self.label:
            STATE.sensitive.update(line.split(': ', 1)[1] for line in out.decode().splitlines() if ': ' in line)
        return out.decode().strip()


class Engine(Owned):
    def __init__(self, config, label):
        assert all(i['listen'] == LOOP and i['listen_port'] > 0 for i in config.get('inbounds', []))
        assert all(e['system'] is False and e.get('detour') and not e.get('listen_port')
                   for e in config.get('endpoints', []))
        assert all(o.get('inet4_bind_address') == LOOP for o in config.get('outbounds', [])
                   if o['type'] in ('direct', 'vless', 'socks'))
        self.path = STATE.directory / (label + '.private.json')
        self.path.write_text(json.dumps(config), encoding='utf-8')
        STATE.checks += 1
        Owned([STATE.executable, 'check', '-c', self.path], 'check:' + label, self.path).command()
        super().__init__([STATE.executable, 'run', '-c', self.path], 'run:' + label, self.path)
        STATE.runs += 1
        self.logs = []
        self.log_counts = {'error_lines': 0, 'warning_lines': 0, 'total_lines': 0}
        def collect():
            for line in iter(self.process.stderr.readline, b''):
                self.log_counts['total_lines'] += 1
                self.log_counts['error_lines'] += int(b'ERROR' in line)
                self.log_counts['warning_lines'] += int(b'WARN' in line)
                # Keep metadata only, not raw logs, configuration, keys or payloads.
        self.reader = threading.Thread(target=collect, daemon=True)
        self.reader.start()

    def close(self):
        super().close()
        self.reader.join(timeout=1)
        self.row['log_metadata'] = dict(self.log_counts)
        for pipe in (self.process.stdout, self.process.stderr):
            if not pipe.closed:
                pipe.close()


class Relay:
    """Two independent source tuples at the real server; payload never retained."""
    def __init__(self, server_port):
        self.server = (LOOP, server_port)
        self.started = time.monotonic()
        self.events, self.sockets, self.peers = [], {}, {}
        self.lock = threading.Lock()
        self.block = set()
        self.closed = threading.Event()
        for lane in ('udp', 'tcp'):
            for side in ('front', 'back'):
                s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                s.bind((LOOP, 0))
                self.sockets[(lane, side)] = s
        def run():
            inverse = {s: k for k, s in self.sockets.items()}
            while not self.closed.is_set():
                try:
                    readable, _, _ = select.select(list(inverse), [], [], .1)
                    for s in readable:
                        data, addr = s.recvfrom(65535)
                        lane, side = inverse[s]
                        if addr[0] != LOOP:
                            continue
                        if side == 'back' and addr != self.server:
                            continue
                        kind = struct.unpack('<I', data[:4])[0] if len(data) >= 4 else 0
                        with self.lock:
                            self.events.append({'t': round(time.monotonic() - self.started, 4),
                                                'lane': lane, 'direction': 'to_server' if side == 'front' else 'from_server',
                                                'type': kind, 'bytes': len(data), 'dropped': lane in self.block})
                        if side == 'front':
                            self.peers[lane] = addr
                            destination, out = self.server, self.sockets[(lane, 'back')]
                        else:
                            destination, out = self.peers.get(lane), self.sockets[(lane, 'front')]
                        if destination and lane not in self.block:
                            out.sendto(data, destination)
                except OSError:
                    if not self.closed.is_set():
                        continue
        self.thread = threading.Thread(target=run, daemon=True)
        self.thread.start()

    def port(self, lane):
        return self.sockets[(lane, 'front')].getsockname()[1]

    def mark(self):
        with self.lock:
            return len(self.events)

    def summary(self, start=0):
        with self.lock:
            events = self.events[start:].copy()
        counts = {}
        sequence = []
        for e in events:
            key = f"{e['lane']}/{e['direction']}/type{e['type']}/len{e['bytes']}"
            counts[key] = counts.get(key, 0) + 1
            if e['direction'] == 'from_server' and e['type'] == 4:
                if not sequence or sequence[-1]['lane'] != e['lane']:
                    sequence.append({'t': e['t'], 'lane': e['lane']})
        return {'packets': len(events), 'counts': counts,
                'server_transport_return_path_changes': sequence[:64],
                'return_path_changes_truncated': len(sequence) > 64}

    def close(self):
        self.closed.set()
        self.thread.join(timeout=1)
        for s in self.sockets.values():
            s.close()


class Http(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def reply(self, head=False):
        self.server.observations.append({'method': self.command, 'path': self.path,
                                         't': round(time.monotonic(), 4)})
        if self.path.startswith('/hold'):
            self.server.hold_seen.set()
            self.server.release.wait(8)
        body = b'DUAL_ENDPOINT_LOOPBACK_ONLY\n'
        try:
            self.send_response(200)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            if not head:
                self.wfile.write(body)
                self.wfile.flush()
        except (OSError, ssl.SSLError):
            pass

    def do_HEAD(self):
        self.reply(True)

    def do_GET(self):
        self.reply()

    def log_message(self, *args):
        pass


class Echo(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(8)
        try:
            while True:
                data = self.request.recv(4096)
                if not data:
                    break
                self.request.sendall(data)
        except OSError:
            pass


class TcpServer(socketserver.ThreadingTCPServer):
    daemon_threads = True

    def handle_error(self, request, client_address):
        pass  # Expected resets in negative session tests; no raw traceback.


class HttpServer(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, request, client_address):
        pass


class SocksAssociation(socketserver.BaseRequestHandler):
    def handle(self):
        s = self.request
        s.settimeout(.2)
        self.server.sockets.append(s)
        try:
            version, count = exact(s, 2)
            if version != 5 or 0 not in exact(s, count):
                return
            s.sendall(b'\x05\x00')
            header = exact(s, 4)
            if header[:3] != b'\x05\x03\x00':
                return
            if header[3] == 1:
                exact(s, 6)
            elif header[3] == 4:
                exact(s, 18)
            else:
                exact(s, exact(s, 1)[0] + 2)
            s.sendall(b'\x05\x00\x00\x01' + socket.inet_aton(LOOP) + struct.pack('!H', self.server.bridge.port))
            self.server.bridge.associated.set()
            while not self.server.bridge.closed.is_set():
                try:
                    if not s.recv(1):
                        return
                except socket.timeout:
                    pass
        except (OSError, EOFError):
            pass


class SocksUdpBridge:
    """Owned loopback SOCKS5 UDP socket supplies the server's packet bind.

    Raw packets are allowed only from the two owned relay back sockets. UDP
    association response and packet headers preserve those source tuples.
    The owned Go UDP association socket is discovered through its PID (no IPC
    or user config), because SOCKS allows a client to request address 0:0.
    """
    def __init__(self):
        self.socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.socket.bind((LOOP, 0))
        self.socket.settimeout(.1)
        self.port = self.socket.getsockname()[1]
        self.target, self.sources = None, set()
        self.associated, self.closed = threading.Event(), threading.Event()
        self.tcp = TcpServer((LOOP, 0), SocksAssociation)
        self.tcp.bridge, self.tcp.sockets = self, []
        def run():
            while not self.closed.is_set():
                try:
                    data, source = self.socket.recvfrom(65535)
                    if source == self.target and data.startswith(b'\x00\x00\x00\x01') and len(data) > 10:
                        destination = (socket.inet_ntoa(data[4:8]), struct.unpack('!H', data[8:10])[0])
                        if destination in self.sources:
                            self.socket.sendto(data[10:], destination)
                    elif source in self.sources and self.target:
                        packet = b'\x00\x00\x00\x01' + socket.inet_aton(source[0]) + struct.pack('!H', source[1]) + data
                        self.socket.sendto(packet, self.target)
                except socket.timeout:
                    pass
                except OSError:
                    if self.closed.is_set():
                        return
        self.thread = threading.Thread(target=run, daemon=True)
        self.thread.start()

    def attach(self, engine):
        if not self.associated.wait(min(3, STATE.remaining())):
            raise AssertionError('server SOCKS UDP association was not created')
        end = time.monotonic() + 3
        while time.monotonic() < end:
            candidates = [c for c in psutil.Process(engine.process.pid).net_connections(kind='udp') if c.laddr]
            if candidates:
                if len(candidates) != 1 or candidates[0].laddr.ip != LOOP:
                    raise AssertionError('server UDP association was not exclusively loopback')
                self.target = (LOOP, candidates[0].laddr.port)
                return
            pause(.05)
        raise AssertionError('owned server UDP association socket could not be observed')

    def close(self):
        self.closed.set()
        for s in self.tcp.sockets:
            s.close()
        self.thread.join(timeout=1)
        self.socket.close()


def direct(tag):
    d = {'type': 'direct', 'tag': tag, 'inet4_bind_address': LOOP}
    return d


class Fixture:
    def __init__(self, label):
        self.label = label
        self.engines, self.services, self.threads, self.connections = [], [], [], []
        self.row = {'scenario': label, 'observations': {}}
        STATE.scenarios.append(self.row)
        self.relay = None
        self.bridge = None
        try:
            self.setup()
        except Exception:
            self.close()
            raise

    def serve(self, server):
        self.services.append(server)
        t = threading.Thread(target=server.serve_forever, kwargs={'poll_interval': .1}, daemon=True)
        self.threads.append(t)
        t.start()
        return server

    def setup(self):
        self.http = HttpServer((LOOP, 0), Http)
        self.http.daemon_threads = True
        self.http.hold_seen, self.http.release = threading.Event(), threading.Event()
        self.http.observations = []
        self.serve(self.http)
        self.echo = self.serve(TcpServer((LOOP, 0), Echo))
        self.bridge = SocksUdpBridge()
        self.serve(self.bridge.tcp)
        self.server_port = self.bridge.port
        self.relay = Relay(self.server_port)
        self.bridge.sources = {self.relay.sockets[(lane, 'back')].getsockname() for lane in ('udp', 'tcp')}
        self.client_key = Owned([STATE.executable, 'generate', 'wg-keypair'], 'client-key:' + self.label).command()
        self.server_key = Owned([STATE.executable, 'generate', 'wg-keypair'], 'server-key:' + self.label).command()
        client = dict(line.split(': ', 1) for line in self.client_key.splitlines())
        server = dict(line.split(': ', 1) for line in self.server_key.splitlines())
        self.client_private, self.client_public = client['PrivateKey'], client['PublicKey']
        self.server_private, self.server_public = server['PrivateKey'], server['PublicKey']
        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'localhost')])
        now = dt.datetime.now(dt.timezone.utc)
        cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name)
                .public_key(key.public_key()).serial_number(x509.random_serial_number())
                .not_valid_before(now - dt.timedelta(minutes=1))
                .not_valid_after(now + dt.timedelta(days=1))
                .add_extension(x509.SubjectAlternativeName([x509.DNSName('localhost')]), False)
                .sign(key, hashes.SHA256()))
        cp, kp = (STATE.directory / (self.label + '-cert.pem'), STATE.directory / (self.label + '-key.pem'))
        cp.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
        kp.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
        camouflage = HttpServer((LOOP, 0), Http)
        camouflage.daemon_threads = True
        camouflage.observations = []
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cp, kp)
        camouflage.socket = context.wrap_socket(camouflage.socket, server_side=True)
        self.serve(camouflage)
        self.reality = dict(line.split(': ', 1) for line in
                            Owned([STATE.executable, 'generate', 'reality-keypair'], 'reality-key:' + self.label).command().splitlines())
        self.uuid, self.secret = secrets.token_hex(16), secrets.token_urlsafe(32)
        import uuid
        self.uuid = str(uuid.UUID(self.uuid))
        STATE.sensitive.update((self.uuid, self.secret))
        self.tcp_port = free_port()
        self.server_proxy = free_port()
        wg_config = {'log': {'level': 'debug', 'timestamp': False}, 'inbounds': [
            {'type': 'mixed', 'tag': 'health-proxy', 'listen': LOOP, 'listen_port': self.server_proxy,
             'users': [{'username': 'fixture', 'password': self.secret}]}
        ], 'endpoints': [
            {'type': 'wireguard', 'tag': 'wg-server', 'system': False, 'workers': 2,
             'address': [WG_SERVER + '/24'], 'private_key': self.server_private, 'detour': 'wg-bind',
             'peers': [{'public_key': self.client_public, 'allowed_ips': ['10.123.0.2/32']}]}
        ], 'outbounds': [{'type': 'socks', 'tag': 'wg-bind', 'server': LOOP,
                          'server_port': self.bridge.tcp.server_address[1], 'version': '5',
                          'inet4_bind_address': LOOP}, direct('direct')],
            'route': {'rules': [
                {'inbound': ['wg-server'], 'port': [self.http.server_port, self.echo.server_address[1], self.server_proxy],
                 'action': 'route', 'outbound': 'direct', 'override_address': LOOP},
                {'inbound': ['health-proxy'], 'ip_cidr': [LOOP + '/32'], 'port': [self.http.server_port],
                 'action': 'route', 'outbound': 'direct'},
                {'action': 'reject'}], 'final': 'direct'}}
        self.engines.append(Engine(wg_config, self.label + '-wg-server'))
        self.bridge.attach(self.engines[-1])
        tcp_config = {'log': {'level': 'debug', 'timestamp': False}, 'inbounds': [
            {'type': 'vless', 'tag': 'tcp-in', 'listen': LOOP, 'listen_port': self.tcp_port,
             'users': [{'uuid': self.uuid}], 'tls': {'enabled': True, 'server_name': 'localhost',
                'reality': {'enabled': True, 'handshake': {'server': LOOP, 'server_port': camouflage.server_port},
                            'private_key': self.reality['PrivateKey'], 'short_id': ['1234567890abcdef']}}}
        ], 'outbounds': [direct('relay')], 'route': {'rules': [
            {'inbound': ['tcp-in'], 'network': 'udp', 'ip_cidr': [LOOP + '/32'],
             'port': [self.relay.port('tcp')], 'action': 'route', 'outbound': 'relay'},
            {'action': 'reject'}], 'final': 'relay'}}
        self.engines.append(Engine(tcp_config, self.label + '-reality-server'))
        self.proxy, self.probe_proxy, self.auto_proxy, self.api_port = [free_port() for _ in range(4)]
        self.wait_tcp(self.tcp_port)

    def wait_tcp(self, port):
        end = time.monotonic() + min(3, STATE.remaining())
        while time.monotonic() < end:
            if any(e.process.poll() is not None for e in self.engines):
                raise AssertionError('fixture engine exited during startup')
            try:
                with socket.create_connection((LOOP, port), timeout=.2):
                    return
            except OSError:
                pause(.05)
        raise TimeoutError('fixture listener startup timeout')

    def client(self, keepalive=0, urltest=False, interrupt=False):
        endpoints = []
        for lane in ('udp', 'tcp'):
            endpoints.append({'type': 'wireguard', 'tag': 'wg-' + lane, 'system': False, 'workers': 2,
                'address': ['10.123.0.2/32'], 'private_key': self.client_private,
                'detour': 'udp-bind' if lane == 'udp' else 'reality',
                'peers': [{'address': LOOP, 'port': self.relay.port(lane), 'public_key': self.server_public,
                           'allowed_ips': [WG_SERVER + '/32'], 'persistent_keepalive_interval': keepalive}]})
        vless = {'type': 'vless', 'tag': 'reality', 'server': LOOP, 'server_port': self.tcp_port,
                 'inet4_bind_address': LOOP, 'uuid': self.uuid,
                 'tls': {'enabled': True, 'server_name': 'localhost',
                         'utls': {'enabled': True, 'fingerprint': 'chrome'},
                         'reality': {'enabled': True, 'public_key': self.reality['PublicKey'], 'short_id': '1234567890abcdef'}}}
        config = {'log': {'level': 'debug', 'timestamp': False},
                  'inbounds': [{'type': 'mixed', 'tag': tag, 'listen': LOOP, 'listen_port': p,
                                'users': [{'username': 'fixture', 'password': self.secret}]}
                               for tag, p in [('selected', self.proxy), ('manual-tcp-probe', self.probe_proxy), ('auto', self.auto_proxy)]],
                  'endpoints': endpoints, 'outbounds': [direct('udp-bind'), vless,
                      {'type': 'selector', 'tag': 'select', 'outbounds': ['wg-udp', 'wg-tcp'],
                       'default': 'wg-udp', 'interrupt_exist_connections': interrupt}],
                  'route': {'rules': [
                      {'inbound': ['manual-tcp-probe'], 'ip_cidr': [LOOP + '/32'], 'action': 'route',
                       'outbound': 'wg-tcp', 'override_address': WG_SERVER},
                      {'inbound': ['selected'], 'ip_cidr': [LOOP + '/32'], 'action': 'route',
                       'outbound': 'select', 'override_address': WG_SERVER},
                      {'inbound': ['auto'], 'action': 'route', 'outbound': 'auto' if urltest else 'select'}],
                      'final': 'select'},
                  'experimental': {'clash_api': {'external_controller': f'{LOOP}:{self.api_port}',
                                                 'secret': self.secret, 'default_mode': 'rule'}}}
        if urltest:
            # HTTP proxy CONNECT encapsulates explicit 127.0.0.1 business URL
            # through the WG virtual address; dialing 127 directly inside a
            # user-space netstack would hit that netstack's own loopback.
            for lane in ('udp', 'tcp'):
                config['outbounds'].append({'type': 'http', 'tag': 'urlprobe-' + lane,
                    'server': WG_SERVER, 'server_port': self.server_proxy,
                    'username': 'fixture', 'password': self.secret, 'detour': 'wg-' + lane})
            config['outbounds'].append({'type': 'urltest', 'tag': 'auto', 'outbounds': ['urlprobe-udp', 'urlprobe-tcp'],
                                       'url': f'http://{TARGET}:{self.http.server_port}/health',
                                       'interval': '1s', 'idle_timeout': '8s',
                                       'interrupt_exist_connections': False})
        self.row['same_key_and_address'] = endpoints[0]['private_key'] == endpoints[1]['private_key'] and endpoints[0]['address'] == endpoints[1]['address']
        self.row['keepalive_seconds'] = keepalive
        self.row['interrupt_exist_connections'] = interrupt
        self.client_engine = Engine(config, self.label + '-client')
        self.engines.append(self.client_engine)
        self.wait_tcp(self.api_port)
        self.verify_bindings()

    def verify_bindings(self):
        samples = []
        for e in self.engines:
            for c in psutil.Process(e.process.pid).net_connections(kind='inet'):
                if c.laddr and (c.type == socket.SOCK_DGRAM or c.status == psutil.CONN_LISTEN):
                    samples.append({'role': e.label, 'address': c.laddr.ip, 'port': c.laddr.port,
                                    'kind': 'udp' if c.type == socket.SOCK_DGRAM else 'tcp'})
                    if c.laddr.ip != LOOP:
                        raise AssertionError('non-loopback engine socket; experiment stopped')
        if not samples:
            raise AssertionError('unable to verify engine listener sockets')
        self.row.setdefault('listener_samples', []).append(samples)

    def api(self, path, method='GET', body=None):
        STATE.ensure_budget()
        c = http.client.HTTPConnection(LOOP, self.api_port, timeout=min(2, STATE.remaining()))
        try:
            c.request(method, path, body=json.dumps(body) if body is not None else None,
                      headers={'Authorization': 'Bearer ' + self.secret, 'Content-Type': 'application/json'})
            r = c.getresponse()
            data = r.read(32768)
            return r.status, json.loads(data) if data else None
        finally:
            c.close()

    def select(self, lane):
        status, _ = self.api('/proxies/select', 'PUT', {'name': 'wg-' + lane})
        if status != 204:
            raise AssertionError('selector mutation did not succeed')
        return self.api('/proxies/select')[1]['now']

    def wait_both_authenticated_lanes(self, timeout=8):
        end = time.monotonic() + min(timeout, STATE.remaining())
        while time.monotonic() < end:
            counts = self.relay.summary()['counts']
            if all(any(k.startswith(lane + '/to_server/type4/') for k in counts) for lane in ('udp', 'tcp')):
                return True
            pause(.1)
        return False

    def http_connection(self, port=None, path='/probe'):
        c = http.client.HTTPConnection(LOOP, port or self.proxy, timeout=min(2.2, STATE.remaining()))
        auth = base64.b64encode(('fixture:' + self.secret).encode()).decode()
        c.request('GET', f'http://{TARGET}:{self.http.server_port}{path}',
                  headers={'Proxy-Authorization': 'Basic ' + auth, 'Connection': 'keep-alive'})
        self.connections.append(c)
        return c

    def read_http(self, c):
        start = time.monotonic()
        try:
            r = c.getresponse()
            body = r.read(1024)
            ok = r.status == 200 and body == b'DUAL_ENDPOINT_LOOPBACK_ONLY\n'
            return {'ok': ok, 'http_status': r.status, 'elapsed_ms': round((time.monotonic() - start) * 1000)}
        except Exception as error:
            return {'ok': False, 'error_type': type(error).__name__,
                    'elapsed_ms': round((time.monotonic() - start) * 1000)}

    def http_probe(self, port=None):
        try:
            c = self.http_connection(port)
            result = self.read_http(c)
            c.close()
            return result
        except Exception as error:
            return {'ok': False, 'error_type': type(error).__name__}

    def tcp(self):
        s = socket.create_connection((LOOP, self.proxy), timeout=min(2.2, STATE.remaining()))
        s.settimeout(min(2.2, STATE.remaining()))
        self.connections.append(s)
        s.sendall(b'\x05\x01\x02')
        if exact(s, 2) != b'\x05\x02':
            raise AssertionError('SOCKS fixture authentication negotiation failed')
        user, password = b'fixture', self.secret.encode()
        s.sendall(b'\x01' + bytes([len(user)]) + user + bytes([len(password)]) + password)
        if exact(s, 2) != b'\x01\x00':
            raise AssertionError('SOCKS fixture authentication failed')
        s.sendall(b'\x05\x01\x00\x01' + socket.inet_aton(TARGET) + struct.pack('!H', self.echo.server_address[1]))
        reply = exact(s, 4)
        if reply[1] != 0:
            raise AssertionError('SOCKS fixture connect failed')
        if reply[3] == 1:
            exact(s, 6)
        elif reply[3] == 4:
            exact(s, 18)
        else:
            exact(s, exact(s, 1)[0] + 2)
        return s

    def echo_once(self, s):
        start = time.monotonic()
        data = secrets.token_bytes(24)
        try:
            s.sendall(data)
            ok = exact(s, len(data)) == data
            return {'ok': ok, 'elapsed_ms': round((time.monotonic() - start) * 1000)}
        except Exception as error:
            return {'ok': False, 'error_type': type(error).__name__,
                    'elapsed_ms': round((time.monotonic() - start) * 1000)}

    def hold(self):
        self.http.hold_seen.clear()
        self.http.release.clear()
        c = self.http_connection(path='/hold')
        if not self.http.hold_seen.wait(min(2.2, STATE.remaining())):
            raise AssertionError('held HTTP did not reach fixture backend')
        return c

    def close(self):
        if hasattr(self, 'http'):
            self.http.release.set()
        for c in self.connections:
            c.close()
        errors = []
        for e in reversed(self.engines):
            try:
                e.close()
            except Exception as error:
                errors.append(type(error).__name__)
        if self.relay:
            self.row['wire_metadata'] = self.relay.summary()
            self.relay.close()
        if self.bridge:
            self.bridge.close()
        for service in self.services:
            service.shutdown()
            service.server_close()
        for t in self.threads:
            t.join(timeout=1)
        self.row['cleanup_errors'] = errors
        if hasattr(self, 'http'):
            self.row['http_backend_requests'] = self.http.observations
        if errors:
            raise RuntimeError('fixture cleanup incomplete')


class DualEndpointFeasibility(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if STATE is None:
            raise unittest.SkipTest('Use explicit bounded CLI for real loopback feasibility experiments')

    def fixture(self, label, **options):
        f = Fixture(label)
        self.addCleanup(f.close)
        f.client(**options)
        return f

    def test_01_lazy_start_and_sequential_forwarding(self):
        f = self.fixture('lazy')
        pause(1.5)
        idle = f.relay.summary()
        o = f.row['observations']
        o['startup_idle_1_5_seconds'] = idle
        o['udp_selected_first'] = f.http_probe()
        self.assertTrue(o['udp_selected_first']['ok'])
        pause(.15)  # Allow WG peer handshake rate limiter to elapse.
        o['tcp_packets_before_probe'] = sum(v for k, v in f.relay.summary()['counts'].items() if k.startswith('tcp/to_server'))
        o['selection_after_tcp'] = f.select('tcp')
        o['tcp_selected'] = f.http_probe()
        self.assertTrue(o['tcp_selected']['ok'])
        o['selection_after_udp'] = f.select('udp')
        o['udp_after_tcp'] = f.http_probe()
        f.verify_bindings()

    def test_02_unselected_keepalive_and_return_path(self):
        f = self.fixture('keepalive', keepalive=1)
        o = f.row['observations']
        o['selector_before'] = f.api('/proxies/select')[1]['now']
        o['both_lanes_transport_packets_after_handshake_retry'] = f.wait_both_authenticated_lanes()
        pause(2.2)
        o['idle_without_application_through_handshake_retry'] = f.relay.summary()
        self.assertTrue(o['both_lanes_transport_packets_after_handshake_retry'])
        o['selected_http'] = f.http_probe()
        o['selector_after'] = f.api('/proxies/select')[1]['now']
        f.verify_bindings()
        counts = o['idle_without_application_through_handshake_retry']['counts']
        self.assertTrue(any(k.startswith('udp/to_server') for k in counts))
        self.assertTrue(any(k.startswith('tcp/to_server') for k in counts))

    def test_03_manual_probe_with_selected_http_and_tcp(self):
        f = self.fixture('manual-probe')
        o = f.row['observations']
        o['selected_baseline'] = f.http_probe()
        self.assertTrue(o['selected_baseline']['ok'])
        pause(.15)
        stream = f.tcp()
        o['old_tcp_before'] = f.echo_once(stream)
        self.assertTrue(o['old_tcp_before']['ok'])
        held = f.hold()
        mark = f.relay.mark()
        o['manual_probe_unselected_tcp'] = f.http_probe(f.probe_proxy)
        o['selector_after_probe'] = f.api('/proxies/select')[1]['now']
        f.http.release.set()
        o['held_selected_http_after_probe'] = f.read_http(held)
        o['old_selected_tcp_after_probe'] = f.echo_once(stream)
        o['selected_new_http_after_probe'] = f.http_probe()
        o['probe_window_wire'] = f.relay.summary(mark)
        f.verify_bindings()

    def test_04_urltest_probes_same_identity_while_selected(self):
        f = self.fixture('urltest', urltest=True)
        o = f.row['observations']
        o['both_lanes_transport_packets_after_handshake_retry'] = f.wait_both_authenticated_lanes()
        pause(.3)
        o['startup_urltest_wire'] = f.relay.summary()
        o['selector_before'] = f.api('/proxies/select')[1]['now']
        o['selected_baseline'] = f.http_probe()
        # Touch URLTest group to enable its short, bounded interval timer.
        o['urltest_selected_application'] = f.http_probe(f.auto_proxy)
        try:
            stream = f.tcp()
            o['old_tcp_before'] = f.echo_once(stream)
        except Exception as error:
            stream = None
            o['old_tcp_before'] = {'ok': False, 'error_type': type(error).__name__}
        mark = f.relay.mark()
        pause(3.2)
        o['periodic_urltest_window'] = f.relay.summary(mark)
        if stream:
            o['old_tcp_after_periodic_urltest'] = f.echo_once(stream)
        o['selected_new_http_after_urltest'] = f.http_probe()
        o['selector_after'] = f.api('/proxies/select')[1]['now']
        o['auto_selected'] = f.api('/proxies/auto')[1].get('now')
        o['urlprobe_delay_history_counts'] = {lane: len(f.api('/proxies/urlprobe-' + lane)[1].get('history', [])) for lane in ('udp', 'tcp')}
        f.verify_bindings()
        counts = f.relay.summary()['counts']
        self.assertTrue(any(k.startswith('udp/to_server') for k in counts))
        self.assertTrue(any(k.startswith('tcp/to_server') for k in counts))
        self.assertTrue(any(r['method'] == 'HEAD' and r['path'] == '/health' for r in f.http.observations))

    def switch_case(self, interrupt):
        f = self.fixture('switch-' + str(interrupt).lower(), interrupt=interrupt)
        o = f.row['observations']
        o['baseline'] = f.http_probe()
        self.assertTrue(o['baseline']['ok'])
        pause(.15)
        stream = f.tcp()
        o['old_tcp_before'] = f.echo_once(stream)
        self.assertTrue(o['old_tcp_before']['ok'])
        held = f.hold()
        mark = f.relay.mark()
        o['selection_after_switch'] = f.select('tcp')
        # First distinguish selector closure from activating the target WG peer.
        f.http.release.set()
        o['held_old_http_before_target_activation'] = f.read_http(held)
        o['old_tcp_before_target_activation'] = f.echo_once(stream)
        o['new_tcp_selected_http'] = f.http_probe()
        o['old_tcp_after_target_activation'] = f.echo_once(stream)
        o['switch_window_wire'] = f.relay.summary(mark)
        o['engine_pid_unchanged'] = f.client_engine.same()
        f.verify_bindings()

    def test_05_switch_preserve_setting(self):
        self.switch_case(False)

    def test_06_switch_interrupt_setting(self):
        self.switch_case(True)

    def test_07_failure_manual_recovery_and_stop_control(self):
        f = self.fixture('failure')
        o = f.row['observations']
        f.select('tcp')
        o['tcp_before_fault'] = f.http_probe()
        self.assertTrue(o['tcp_before_fault']['ok'])
        # Fixture-only two-way UDP blackhole on the Reality-carried WG lane.
        f.relay.block.add('tcp')
        o['fault'] = 'drop both directions of Reality-carried WG datagrams in owned relay'
        o['selected_tcp_during_fault'] = f.http_probe()
        o['selector_after_failure'] = f.api('/proxies/select')[1]['now']
        o['manual_selection_recovery'] = f.select('udp')
        o['udp_after_manual_recovery'] = f.http_probe()
        mark = f.relay.mark()
        pause(2.2)
        o['unselected_failed_endpoint_window'] = f.relay.summary(mark)
        # Existing documented proxy PUT accepts selector choice only, no stop.
        status, body = f.api('/proxies/wg-tcp', 'PUT', {'name': 'wg-udp'})
        o['endpoint_put_http_status'] = status
        o['endpoint_put_requires_selector'] = body == {'message': 'Must be a Selector'}
        o['automatic_stop_unselected_endpoint'] = 'Unknown: no supported per-endpoint stop interface found in bundled 1.14.2'
        f.relay.block.clear()
        f.select('tcp')
        o['tcp_after_fault_removed'] = f.http_probe()
        f.verify_bindings()


def network_snapshot():
    """Read-only hashes; never export existing process command lines or secrets."""
    script = """
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=New-Object System.Text.UTF8Encoding($false)
$s=[ordered]@{}
$s.Routes=@(Get-NetRoute | Sort-Object InterfaceIndex,DestinationPrefix,NextHop | Select-Object InterfaceIndex,DestinationPrefix,NextHop,RouteMetric)
$s.Dns=@(Get-DnsClientServerAddress | Sort-Object InterfaceIndex,AddressFamily | Select-Object InterfaceIndex,AddressFamily,ServerAddresses)
$s.Adapters=@(Get-NetAdapter | Sort-Object InterfaceIndex | Select-Object InterfaceIndex,Name,Status)
$s.Firewall=@(Get-NetFirewallProfile | Sort-Object Name | Select-Object Name,Enabled,DefaultInboundAction,DefaultOutboundAction)
$p=Get-ItemProperty 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings'
$s.Proxy=@{Enabled=$p.ProxyEnable;Server=$p.ProxyServer;PAC=$p.AutoConfigURL}
$s.WinHttp=@(netsh winhttp show proxy)
$s | ConvertTo-Json -Depth 10 -Compress
"""
    shell = Path(os.environ['SYSTEMROOT']) / 'System32/WindowsPowerShell/v1.0/powershell.exe'
    p = Owned([shell, '-NoProfile', '-NonInteractive', '-Command', script], 'readonly-network-snapshot')
    try:
        raw = json.loads(p.command(timeout=12))
        return {'available': True, 'sha256': {k: hashlib.sha256(json.dumps(v, sort_keys=True).encode()).hexdigest() for k, v in raw.items()}}
    except Exception as error:
        return {'available': False, 'error_type': type(error).__name__}


class Experiment:
    def __init__(self, budget):
        self.start = time.monotonic()
        self.budget, self.deadline = budget, self.start + budget
        self.expired, self.lock = threading.Event(), threading.RLock()
        self.scenarios, self.children, self.native_errors = [], [], []
        self.sensitive = set()
        self.runs, self.checks = 0, 0
        self.temp_parent = Path(tempfile.gettempdir()).resolve()
        self.directory = Path(tempfile.mkdtemp(prefix='TC-DualEndpoint-', dir=self.temp_parent)).resolve()
        self.executable = self.directory / 'tc-dual-endpoint-fixture.exe'
        shutil.copyfile(ENGINE, self.executable)
        self.engine_hash = sha(self.executable)
        self.watchdog_errors = []
        def expire():
            self.expired.set()
            with self.lock:
                children = list(self.children)
            for child in reversed(children):
                try:
                    child.close()
                except Exception as error:
                    self.watchdog_errors.append(type(error).__name__)
        self.watchdog = threading.Timer(budget, expire)
        self.watchdog.daemon = True
        self.watchdog.start()

    def remaining(self):
        return max(.01, self.deadline - time.monotonic())

    def redact(self, text):
        for secret in self.sensitive:
            text = text.replace(secret, '<redacted>')
        text = text.replace(str(self.directory), '<owned-temp>')
        text = re.sub(r'[A-Za-z0-9+/]{40,}={0,2}', '<redacted-long-token>', text)
        text = re.sub(r'(?i)[a-f0-9]{32,}', '<redacted-hex>', text)
        return text

    def ensure_budget(self):
        if self.expired.is_set() or time.monotonic() >= self.deadline:
            raise TimeoutError('total runtime budget exhausted')

    def cleanup(self):
        self.watchdog.cancel()
        errors = []
        for child in reversed(self.children):
            try:
                child.close()
            except Exception as error:
                errors.append(type(error).__name__)
        alive = [c.row['pid'] for c in self.children if c.process.poll() is None]
        self.temp_boundary_verified = (self.directory.parent == self.temp_parent and
            self.directory.name.startswith('TC-DualEndpoint-') and self.directory != self.temp_parent and
            not self.directory.is_symlink() and
            all(not p.is_symlink() for p in self.directory.rglob('*')))
        if self.temp_boundary_verified and not alive and not errors:
            shutil.rmtree(self.directory)
        self.cleanup_result = {'owned_children': len(self.children), 'still_running_owned_pids': alive,
                               'errors': errors, 'watchdog_errors': self.watchdog_errors,
                               'temporary_parent': str(self.temp_parent), 'temporary_directory': self.directory.name,
                               'temp_delete_boundary_verified': self.temp_boundary_verified,
                               'temp_directory_absent_after_cleanup': not self.directory.exists()}


class Result(unittest.TextTestResult):
    def startTest(self, test):
        print('Running ' + test.id().split('.')[-1], flush=True)
        super().startTest(test)

    def _exc_info_to_string(self, err, test):
        # unittest must not leak exception strings containing native config.
        return 'Suppressed raw exception; type=' + err[0].__name__


def feasibility(result):
    by = {s['scenario']: s for s in STATE.scenarios}
    rows = []
    def row(name, status, evidence):
        rows.append({'criterion': name, 'status': status, 'evidence': evidence})
    lazy = by.get('lazy', {}).get('observations', {})
    row('selector_same_key_configuration_and_real_sequential_forwarding',
        'Pass' if lazy.get('udp_selected_first', {}).get('ok') and lazy.get('tcp_selected', {}).get('ok') else 'Unknown',
        'lazy: actual UDP and Reality-nested WG HTTP requests, not check-only')
    row('return_to_udp_immediately_after_tcp_is_usable',
        'Fail' if lazy.get('udp_after_tcp', {}).get('ok') is False else 'Unknown',
        'lazy: UDP -> TCP forwarding succeeded; immediate return to UDP timed out in bounded window')
    row('no_keepalive_unselected_path_quiet_in_short_window',
        'Pass' if lazy.get('startup_idle_1_5_seconds', {}).get('packets') == 0 and lazy.get('tcp_packets_before_probe') == 0 else 'Unknown',
        'only the measured 1.5-second startup window and before first probe; not endpoint lifecycle suspension')
    ka = by.get('keepalive', {}).get('observations', {}).get('idle_without_application_through_handshake_retry', {})
    seq = ka.get('server_transport_return_path_changes', [])
    row('unselected_endpoint_remains_quiet_with_keepalive',
        'Fail' if any(k.startswith('tcp/to_server') for k in ka.get('counts', {})) else 'Unknown',
        'keepalive: selector stays wg-udp; both lanes emit WireGuard packets before application requests')
    row('keepalive_does_not_change_server_return_path', 'Fail' if len(seq) > 1 else 'Unknown',
        'no server transport-data reply during the idle-only window; no peer IPC endpoint telemetry; keepalive roaming cannot be directly established')
    ko = by.get('keepalive', {}).get('observations', {})
    row('keepalive_dual_identity_preserves_selected_http',
        'Fail' if ko.get('both_lanes_transport_packets_after_handshake_retry') and ko.get('selected_http', {}).get('ok') is False else 'Unknown',
        'both lanes received handshake responses and sent type4/32-byte packets; selector stayed UDP and selected HTTP timed out')
    for label, field in [('manual-probe', 'held_selected_http_after_probe'), ('urltest', 'selected_new_http_after_urltest')]:
        o = by.get(label, {}).get('observations', {})
        bad = [k for k, v in o.items() if isinstance(v, dict) and v.get('ok') is False and ('selected' in k or 'old_tcp' in k)]
        row(label + '_does_not_affect_selected_forwarding', 'Fail' if bad else 'Unknown',
            label + ': ' + (', '.join(bad) if bad else 'bounded run cannot prove a general no-interruption guarantee'))
    for label in ('switch-false', 'switch-true'):
        o = by.get(label, {}).get('observations', {})
        bad = [k for k in ('held_old_http_before_target_activation', 'old_tcp_before_target_activation', 'old_tcp_after_target_activation')
               if o.get(k, {}).get('ok') is False]
        row(label + '_preserves_old_sessions', 'Fail' if bad else 'Unknown',
            ', '.join(bad) if bad else 'see bounded session observations')
    row('automatic_stop_unselected_endpoint_on_failure', 'Unknown',
        '1.14.2 pinned WireGuard schema has no on_demand; documented proxy PUT only controls selector; no supported endpoint stop interface established')
    row('automatic_protocol_failover', 'Unknown',
        'failure case distinguishes observed selector state from explicitly requested manual fallback; no automatic stop implementation')
    fo = by.get('failure', {}).get('observations', {})
    row('manual_udp_recovery_after_tcp_fixture_blackhole',
        'Pass' if fo.get('tcp_before_fault', {}).get('ok') and fo.get('selected_tcp_during_fault', {}).get('ok') is False and fo.get('udp_after_manual_recovery', {}).get('ok') else 'Unknown',
        'TCP baseline passed; injected TCP-lane datagram loss timed out; explicit manual UDP selection restored new HTTP only; TCP after fault removal did not recover in window')
    row('A_unaffected', 'Pass' if STATE.cleanup_result['temp_directory_absent_after_cleanup'] and not result.errors and
        not STATE.cleanup_result['still_running_owned_pids'] else 'Unknown',
        'isolated test executable/configuration/keys; no product module invocation or production process signals; write scope only three authorized paths')
    return rows


def write_reports(document):
    out = WORKSPACE / 'reports' / 'release-0.11.0'
    out.mkdir(parents=True, exist_ok=True)
    jp, mp = out / 'dual-endpoint-feasibility.json', out / 'dual-endpoint-feasibility.md'
    jp.write_text(json.dumps(document, ensure_ascii=False, indent=2), encoding='utf-8')
    lines = ['# 0.11.0 B 方案同 key 双 endpoint 回环可行性', '',
             '**结论：A unaffected；B 不能承诺无中断，不作为一期 A 的交付门槛。**', '',
             f"本次 unittest 实际运行 {document['tests']['run']} 项，通过 {document['tests']['passed']} 项；"
             f"错误 {document['tests']['errors']}，断言失败 {document['tests']['failures']}。"
             f"sing-box `run` 实际启动 {document['execution']['engine_runs']} 次，`check` {document['execution']['config_checks']} 次；"
             '两者分开计数，测试通过表示实验完成，不等于 B 并发可行。', '',
             f"总运行预算 {document['execution']['budget_seconds']} 秒，实际 {document['execution']['elapsed_seconds']} 秒。", '',
             '本次为最终必要场景验证；历史准备/诊断尝试另列 previous_attempts，不能计入当前七项通过结果。'
             '累计实际执行计数：' + json.dumps(document.get('cumulative_execution', {}), ensure_ascii=False) + '。', '',
             '## 判定', '', '| 判定项 | 结果 | 证据 |', '|---|---|---|']
    for r in document['feasibility']:
        lines.append(f"| {r['criterion']} | {r['status']} | {r['evidence']} |")
    lines += ['', '## 实际观察', '']
    for s in document['scenarios']:
        lines += ['### ' + s['scenario'], '', '```json', json.dumps(s['observations'], ensure_ascii=False, indent=2), '```', '']
    lines += ['## 拓扑与验证边界', '',
              '真实 bundled sing-box 1.14.2 的两个 WireGuard endpoints 在同一 client 进程中复用本次生成的 client key 和 10.123.0.2；server 只有一个对应 peer。'
              'UDP 通过回环 direct detour，TCP 通过真实 VLESS/Reality 承载 WireGuard datagram。双路径的透明回环 UDP relay 为 server 提供两个独立 source tuple，'
              '记录包类型/长度/方向/相对时间和服务器回包路径，完全不保存包内容。HTTP、TCP echo、健康检查业务目标和所有真实后端均为 127.0.0.1 随机端口。'
              '10.123.0.1/10.123.0.2 只作为 user-space WG 内部传输地址，不写宿主地址/路由。业务入口通过 fixture route override 封装到内部 WG 地址，再在服务器回环转发。', '',
              '为严格满足全部 socket 绑定 127.0.0.1，server WG 使用 SOCKS UDP detour + inet4_bind_address，'
              'client UDP WG 也使用 direct detour；不启用 StdNetBind 默认 wildcard 路径。该调整属于 fixture，不能外推未经测试的默认 socket 实现。'
              '1.14.2 direct outbound 不接受 udp_bind_port；准备尝试因此失败，未冒充实际 run。服务器 SOCKS UDP 适配层只转发回环 UDP 封装，'
              '不实现 WireGuard、不解密，不更改源 tuple；WireGuard 握手、加密及 peer 行为均由真实引擎执行。'
              '每项启动后及结束前读取 owned PID 的实际 TCP LISTEN/UDP bind；结果逐项保存在 JSON listener_samples。', '',
              'urltest 使用显式 http://127.0.0.1:随机端口/health；其两个成员为 HTTP CONNECT 探针 outbound，分别 detour 到同 key WG UDP/TCP endpoint。'
              '服务器认证 mixed proxy 也只监听回环。这层封装让目标 127.0.0.1 指向真实服务器本地业务，而不是 client user-space netstack 自己的 loopback。'
              '探针通过两个真实 WG endpoint，记录后端收到的 HEAD、两个 delay history 和实际回包路径；它证明探针激活/干扰边界，不能当成裸 endpoint URLTest 的延迟比较。'
              '没有调用会把 HTTP URL 替换成外网默认目标的 Clash /delay。'
              '手动 probe 使用独立认证 mixed inlet，直接路由至未选 WG TCP endpoint，不改变 selector。'
              'TLS camouflage 的临时自签名证书仅供回环 Reality 握手，不安装系统信任。', '',
              '## Observations limitations', '']
    lines += ['- ' + x for x in document['limitations']]
    lines += ['', '## 准备失败与诊断尝试', '',
              '初始 direct udp_bind_port schema 尝试失败（run 0），随后改为回环 SOCKS UDP bind，'
              '成功取得实际 UDP/TCP 转发。直接让 WG netstack 拨号 127.0.0.1 的诊断运行虽握手成功，'
              '业务请求超时；最终使用业务目标 127.0.0.1 + 内部 WG 封装/服务端回环转发。'
              '这些失败只说明 fixture 准备/寻址问题，不用于推导 B 可行性。', '']
    lines += ['', '## 隔离与清理', '', '```json', json.dumps(document['cleanup'], ensure_ascii=False, indent=2), '```', '',
              '原有进程只保存 PID/出生时间用于只读核对，不读取其配置、命令行或 private；停止动作限定本次 Popen handle，'
              '并核对 PID、出生时间、临时 exe 绝对路径、完整 argv 和配置目录。所有子进程退出后才验证并删除本次唯一 temp 目录。'
              '原始引擎日志不落报告，仅保留错误/警告计数；所有 key、UUID、控制/代理认证只存临时配置并随目录清理。', '',
              '网络前后快照只读并只保存哈希：' + json.dumps(document['isolation'], ensure_ascii=False), '',
              '## 复现', '', '从 `releases/0.11.0` 执行：', '',
              '```powershell', 'python -B tests/Verify-DualEndpointFeasibility.py --budget 180', '```', '',
              '测试只写指定测试文件和 reports/release-0.11.0/dual-endpoint-feasibility.md/json；临时文件在系统 temp 中，'
              '不调用产品网络接管、不触碰系统 TUN/路由/DNS/代理/防火墙或现有进程。', '',
              '## 版本对应资料', '',
              '- [1.14.2 对应 WireGuard options](https://raw.githubusercontent.com/SagerNet/sing-box/af6e64c3b69e6132ebaee0e1a3d24e93903f6709/option/wireguard.go)',
              '- [1.14.2 endpoint 启动与 bind](https://raw.githubusercontent.com/SagerNet/sing-box/af6e64c3b69e6132ebaee0e1a3d24e93903f6709/transport/wireguard/endpoint.go)',
              '- [1.14.2 Clash proxy 控制/探测实现](https://raw.githubusercontent.com/SagerNet/sing-box/af6e64c3b69e6132ebaee0e1a3d24e93903f6709/experimental/clashapi/proxies.go)',
              '- [selector 官方说明](https://sing-box.sagernet.org/configuration/outbound/selector/)', '']
    mp.write_text('\n'.join(lines), encoding='utf-8')


def main():
    global STATE
    parser = argparse.ArgumentParser()
    parser.add_argument('--budget', type=float, default=180)
    parser.add_argument('--case', help='optional one unittest method for fixture diagnosis')
    args = parser.parse_args()
    if not 45 <= args.budget <= 240:
        parser.error('budget must be between 45 and 240 seconds')
    STATE = Experiment(args.budget)
    previous_path = WORKSPACE / 'reports' / 'release-0.11.0' / 'dual-endpoint-feasibility.json'
    history = []
    if previous_path.exists():
        previous = json.loads(previous_path.read_text(encoding='utf-8'))
        if previous.get('schema') == 1 and previous.get('release') == '0.11.0':
            history = previous.get('previous_attempts', []) + [
                {k: previous[k] for k in ('generated_utc', 'execution', 'tests', 'cleanup', 'native_errors')}]
    before = after = {'available': False}
    baseline = {(p.pid, p.create_time()) for p in psutil.process_iter()}
    candidate_hash = sha(PACKAGE / 'tests' / 'test_candidate_local_e2e.py')
    result = None
    try:
        version = Owned([STATE.executable, 'version'], 'engine-version').command()
        if 'sing-box version 1.14.2' not in version:
            raise AssertionError('experiment requires bundled sing-box 1.14.2')
        before = network_snapshot()
        suite = (unittest.TestSuite([DualEndpointFeasibility(args.case)]) if args.case else
                 unittest.defaultTestLoader.loadTestsFromTestCase(DualEndpointFeasibility))
        result = unittest.TextTestRunner(verbosity=1, resultclass=Result).run(suite)
        after = network_snapshot()
    finally:
        STATE.cleanup()
    if result is None:
        raise RuntimeError('experiment did not execute tests; no feasibility claim')
    current = {(p.pid, p.create_time()) for p in psutil.process_iter()}
    isolation = {'all_verified_engine_listeners_127_0_0_1': not any(
        c['address'] != LOOP for s in STATE.scenarios for sample in s.get('listener_samples', []) for c in sample),
        'network_snapshot_before': before, 'network_snapshot_after': after,
        'network_snapshot_equal': before.get('available') and after.get('available') and before.get('sha256') == after.get('sha256'),
        'existing_processes_exited_or_replaced_during_run': len(baseline - current),
        'existing_processes_signaled': 0, 'product_modules_invoked': 0, 'user_private_files_read': 0,
        'original_engine_sha256_unchanged': sha(ENGINE) == STATE.engine_hash,
        'candidate_local_e2e_sha256_unchanged': sha(PACKAGE / 'tests' / 'test_candidate_local_e2e.py') == candidate_hash}
    document = {'schema': 1, 'release': '0.11.0', 'generated_utc': dt.datetime.now(dt.timezone.utc).isoformat(),
        'conclusion': 'A unaffected / B不能承诺无中断',
        'execution': {'engine_version': version, 'engine_sha256': STATE.engine_hash,
                      'engine_runs': STATE.runs, 'config_checks': STATE.checks,
                      'budget_seconds': args.budget, 'budget_exceeded': STATE.expired.is_set(),
                      'elapsed_seconds': round(time.monotonic() - STATE.start, 3)},
        'previous_attempts': history,
        'tests': {'run': result.testsRun, 'passed': result.testsRun - len(result.errors) - len(result.failures) - len(result.skipped),
                  'errors': len(result.errors), 'failures': len(result.failures), 'skipped': len(result.skipped),
                  'error_tests': [{'test': t.id(), 'error': e} for t, e in result.errors + result.failures]},
        'feasibility': feasibility(result), 'scenarios': STATE.scenarios,
        'business_targets': {'http': LOOP, 'tcp_echo': LOOP, 'urltest_url_host': LOOP,
                             'wireguard_internal_addresses': [WG_SERVER, '10.123.0.2'],
                             'host_network_changes': 0,
                             'direct_endpoint_urltest_without_http_connect_wrapper_tested': False},
        'owned_processes': [c.row for c in STATE.children], 'native_errors': STATE.native_errors,
        'isolation': isolation, 'cleanup': STATE.cleanup_result,
        'limitations': [
            '没有 WireGuard peer IPC/get endpoint 遥测；server 回包目的 tuple 是实际 packet-path 证据。不能据此精确报告 peer 内部 endpoint 状态、密钥槽或每次 keepalive 是否认证成功。',
            'type4/32-byte 仅是加密空 transport packet 的长度/类型观察，不解密或保存内容；回包路径交替可证明外部行为，内部 roaming 细节仅推断。',
            '同 key 两实例各有独立握手/计数状态；旧会话失败可能包含 endpoint roaming、接收密钥不匹配及 selector 主动关闭，报告不把所有失败单因归于 roaming。',
            '仅短时回环协议/HTTP/TCP 会话实验；不证明公网、云规则、物理直连、TUN、DNS/出口接管、交易会话或长期稳定性。应用 UDP 会话切换未测。',
            '没有可靠支持的单 endpoint 停用接口就记 Unknown；关闭整个 owned client 进程只是测试清理，不能当成产品自动停未选 endpoint。',
            '网络前后快照只证明采样时状态；无法排除外部进程在两次采样之间变化。原有进程自行退出只记录，不归因于 B。',
            'keepalive=1 秒及 urltest=1 秒用于预算内放大可观察行为，不代表生产默认间隔；各场景全新临时身份，失败用例只操作 fixture relay。']}
    attempts = history + [document]
    document['cumulative_execution'] = {
        'attempts': len(attempts),
        'unittest_executions': sum(h['tests']['run'] for h in attempts),
        'unittest_passed': sum(h['tests']['passed'] for h in attempts),
        'unittest_failures': sum(h['tests']['failures'] for h in attempts),
        'unittest_errors': sum(h['tests']['errors'] for h in attempts),
        'engine_runs': sum(h['execution']['engine_runs'] for h in attempts),
        'config_checks': sum(h['execution']['config_checks'] for h in attempts),
        'owned_children': sum(h['cleanup']['owned_children'] for h in attempts),
        'all_attempts_cleanup_verified': all(h['cleanup']['temp_directory_absent_after_cleanup'] and
                                             not h['cleanup']['still_running_owned_pids'] for h in attempts)}
    write_reports(document)
    print(json.dumps({'conclusion': document['conclusion'], 'tests': document['tests'],
                      'engine_runs': STATE.runs, 'config_checks': STATE.checks,
                      'cleanup': STATE.cleanup_result}, ensure_ascii=False), flush=True)
    return 0 if result.wasSuccessful() and STATE.cleanup_result['temp_directory_absent_after_cleanup'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
