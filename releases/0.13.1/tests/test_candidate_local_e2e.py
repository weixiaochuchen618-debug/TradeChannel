"""Real user-space WireGuard and Reality on loopback only; never host routes/TUN.

This proves local protocol wiring and authentication, not VPS availability,
physical-network reachability, cloud firewall or trading-application behavior.
"""
import base64
import datetime
import http.server
import json
import os
import re
from pathlib import Path
import socket
import ssl
import struct
import subprocess
import tempfile
import threading
import time
import unittest

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID

PACKAGE = Path(__file__).resolve().parents[1]
ENGINE = PACKAGE / 'assets' / 'sing-box.exe'
WG = PACKAGE / 'assets' / 'wg.exe'
FLAGS = subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0


def native(argv, data=None):
    result = subprocess.run([str(x) for x in argv], input=data, text=True,
                            capture_output=True, timeout=15, creationflags=FLAGS)
    if result.returncode:
        raise AssertionError('Fixture command failed; raw output suppressed.')
    return result.stdout.strip()


def port(kind=socket.SOCK_STREAM):
    with socket.socket(socket.AF_INET, kind) as server:
        server.bind(('127.0.0.1', 0))
        return server.getsockname()[1]


class EngineProcess:
    def __init__(self, configuration, directory, name):
        self.path = directory / (name + '.private.json')
        self.path.write_text(json.dumps(configuration), encoding='utf-8')
        native([ENGINE, 'check', '-c', self.path])
        self.process = subprocess.Popen([str(ENGINE), 'run', '-c', str(self.path)],
                                        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                                        creationflags=FLAGS)
        self.log = bytearray()
        def collect():
            while True:
                part = self.process.stderr.read1(4096)
                if not part:
                    break
                self.log.extend(part)
                del self.log[:-65536]
        self.thread = threading.Thread(target=collect, daemon=True)
        self.thread.start()

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=5)
        self.thread.join(timeout=2)
        self.process.stderr.close()


class FixtureHttp(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b'LOCAL_PROTOCOL_E2E_ONLY\n'
        self.send_response(200)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


class FixtureDns:
    def __init__(self):
        self.socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.socket.bind(('127.0.0.1', 0))
        self.port = self.socket.getsockname()[1]
        self.socket.settimeout(.2)
        self.running = True
        self.queries = 0
        def run():
            while self.running:
                try:
                    query, source = self.socket.recvfrom(4096)
                except socket.timeout:
                    continue
                if len(query) < 17:
                    continue
                self.queries += 1
                offset = 12
                while offset < len(query) and query[offset]:
                    offset += query[offset] + 1
                end = offset + 5
                answer = (query[:2] + b'\x81\x80' + b'\x00\x01\x00\x01\x00\x00\x00\x00' + query[12:end] +
                          b'\xc0\x0c' + struct.pack('!HHIH', 1, 1, 60, 4) + socket.inet_aton('10.123.0.1'))
                self.socket.sendto(answer, source)
        self.thread = threading.Thread(target=run, daemon=True)
        self.thread.start()

    def close(self):
        self.running = False
        self.thread.join(timeout=2)
        self.socket.close()


def response(proxy, target, username='fixture', password='independent-fixture-secret'):
    with socket.create_connection(('127.0.0.1', proxy), timeout=5) as connection:
        auth = base64.b64encode((username + ':' + password).encode()).decode()
        request = ('GET http://' + target + '/probe HTTP/1.1\r\nHost: ' + target +
                   '\r\nProxy-Authorization: Basic ' + auth + '\r\nConnection: close\r\n\r\n')
        connection.sendall(request.encode())
        body = bytearray()
        while len(body) < 65536:
            chunk = connection.recv(min(4096, 65536 - len(body)))
            if not chunk:
                break
            body.extend(chunk)
            if b'\r\n\r\n' in body:
                headers, content = bytes(body).split(b'\r\n\r\n', 1)
                length = re.search(br'(?i)content-length:\s*(\d+)', headers)
                if length and len(content) >= int(length.group(1)):
                    break
        return bytes(body)


class CandidateLocalEndToEnd(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='TC-CandidateLocalE2E-', dir=os.environ.get('LOCALAPPDATA'))
        self.directory = Path(self.temporary.name)
        self.engines = []
        self.http = http.server.ThreadingHTTPServer(('127.0.0.1', 0), FixtureHttp)
        self.http.daemon_threads = True
        self.http_thread = threading.Thread(target=self.http.serve_forever, daemon=True)
        self.http_thread.start()
        self.dns = FixtureDns()
        self.client_private = native([WG, 'genkey'])
        self.server_private = native([WG, 'genkey'])
        self.client_public = native([WG, 'pubkey'], self.client_private)
        self.server_public = native([WG, 'pubkey'], self.server_private)
        self.wg_port = port(socket.SOCK_DGRAM)
        server = {'log': {'level': 'warn'}, 'endpoints': [
            {'type': 'wireguard', 'tag': 'wg-server', 'system': False,
             'listen_port': self.wg_port, 'address': ['10.123.0.1/24'],
             'private_key': self.server_private,
             'peers': [{'public_key': self.client_public, 'allowed_ips': ['10.123.0.2/32']}]}
        ], 'outbounds': [{'type': 'direct', 'tag': 'direct'}], 'route': {'rules': [
            {'inbound': ['wg-server'], 'network': 'udp', 'port': [53], 'action': 'route', 'outbound': 'direct', 'override_address': '127.0.0.1', 'override_port': self.dns.port},
            {'inbound': ['wg-server'], 'port': [self.http.server_port], 'action': 'route', 'outbound': 'direct', 'override_address': '127.0.0.1'},
            {'inbound': ['wg-server'], 'action': 'reject'}], 'final': 'direct'}}
        self.server_configuration = server
        self.wg_engine = EngineProcess(server, self.directory, 'wg-server')
        self.engines.append(self.wg_engine)
        time.sleep(.5)

    def tearDown(self):
        for engine in reversed(self.engines):
            engine.close()
        self.http.shutdown()
        self.http.server_close()
        self.http_thread.join(timeout=2)
        self.dns.close()
        self.temporary.cleanup()

    def client(self, proxy, tcp=None):
        endpoint = {'type': 'wireguard', 'tag': 'hk', 'system': False,
                    'address': ['10.123.0.2/32'], 'private_key': self.client_private,
                    'peers': [{'address': '127.0.0.1', 'port': self.wg_port,
                               'public_key': self.server_public, 'allowed_ips': ['0.0.0.0/0']}]}
        configuration = {'log': {'level': 'warn'}, 'inbounds': [
            {'type': 'mixed', 'tag': 'probe', 'listen': '127.0.0.1', 'listen_port': proxy,
             'users': [{'username': 'fixture', 'password': 'independent-fixture-secret'}]}
        ], 'endpoints': [endpoint], 'outbounds': [], 'route': {'final': 'hk'}}
        if tcp:
            endpoint['detour'] = 'tc-transport'
            configuration['outbounds'] = [tcp]
        source = self.directory / 'source-candidate.private.json'
        generated = self.directory / 'generated-probe.private.json'
        generator = self.directory / 'generate-probe.ps1'
        source.write_text(json.dumps(configuration), encoding='utf-8')
        generator.write_text('''param($PackageRoot,$InputPath,$OutputPath,[int]$Port)
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PackageRoot 'CandidateProbe.psm1') -PassThru -DisableNameChecking
$candidate=[IO.File]::ReadAllText($InputPath)|ConvertFrom-Json
$config=& $module {param($c,$port) New-TCCandidateProbeConfig ([pscustomobject]@{DirectDns='127.0.0.1'}) $c $null $port 'fixture' 'independent-fixture-secret'} $candidate $Port
[IO.File]::WriteAllText($OutputPath,($config|ConvertTo-Json -Depth 30),(New-Object Text.UTF8Encoding($false)))
''', encoding='utf-8-sig')
        powershell = Path(os.environ['SYSTEMROOT']) / 'System32/WindowsPowerShell/v1.0/powershell.exe'
        native([powershell, '-NoProfile', '-NonInteractive', '-File', generator,
                PACKAGE, source, generated, str(proxy)])
        probe = json.loads(generated.read_text(encoding='utf-8'))
        self.assertTrue(all(entry['type'] == 'mixed' for entry in probe['inbounds']))
        self.assertFalse(probe['endpoints'][0]['system'])
        self.assertEqual('hk', probe['dns']['servers'][1]['detour'])
        self.assertEqual('dns-hk', probe['route']['default_domain_resolver']['server'])
        self.engines.append(EngineProcess(probe, self.directory, 'wg-client'))
        time.sleep(.5)

    def test_udp_forwarding_and_loopback_auth(self):
        proxy = port()
        self.client(proxy)
        target = '10.123.0.1:' + str(self.http.server_port)
        body = response(proxy, target)
        self.assertIn(b'200 OK', body)
        self.assertIn(b'LOCAL_PROTOCOL_E2E_ONLY', body)
        bad = response(proxy, target, password='wrong-fixture-password')
        self.assertNotIn(b'LOCAL_PROTOCOL_E2E_ONLY', bad)
        self.assertIn(b'407', bad)
        by_domain = response(proxy, 'probe.fixture:' + str(self.http.server_port))
        self.assertIn(b'LOCAL_PROTOCOL_E2E_ONLY', by_domain)
        self.assertGreater(self.dns.queries, 0)

    def test_tcp_reality_nested_wireguard_forwarding(self):
        # Self-signed certificate is only a local Reality camouflage backend;
        # it is never installed in the OS trust store or used to bypass TLS.
        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'localhost')])
        now = datetime.datetime.now(datetime.timezone.utc)
        cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name)
                .public_key(key.public_key()).serial_number(x509.random_serial_number())
                .not_valid_before(now - datetime.timedelta(minutes=1))
                .not_valid_after(now + datetime.timedelta(days=1))
                .add_extension(x509.SubjectAlternativeName([x509.DNSName('localhost')]), False)
                .sign(key, hashes.SHA256()))
        certificate = self.directory / 'fixture-cert.pem'
        private = self.directory / 'fixture-key.pem'
        certificate.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
        private.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
        tls_server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), FixtureHttp)
        tls_server.daemon_threads = True
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(certificate, private)
        tls_server.socket = context.wrap_socket(tls_server.socket, server_side=True)
        thread = threading.Thread(target=tls_server.serve_forever, daemon=True)
        thread.start()
        try:
            # Add a loopback-only relay target for the strict TLS negative test.
            self.wg_engine.close()
            self.engines.remove(self.wg_engine)
            self.server_configuration['route']['rules'].insert(0,
                {'inbound': ['wg-server'], 'port': [tls_server.server_port], 'action': 'route',
                 'outbound': 'direct', 'override_address': '127.0.0.1'})
            self.wg_engine = EngineProcess(self.server_configuration, self.directory, 'wg-server')
            self.engines.append(self.wg_engine)
            pair = native([ENGINE, 'generate', 'reality-keypair'])
            reality = dict(line.split(': ', 1) for line in pair.splitlines())
            tcp_port = port()
            uuid = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'
            tcp = {'log': {'level': 'warn'}, 'inbounds': [
                {'type': 'vless', 'tag': 'tcp-in', 'listen': '127.0.0.1', 'listen_port': tcp_port,
                 'users': [{'uuid': uuid}], 'tls': {'enabled': True, 'server_name': 'localhost',
                  'reality': {'enabled': True, 'handshake': {'server': '127.0.0.1', 'server_port': tls_server.server_port},
                              'private_key': reality['PrivateKey'], 'short_id': ['1234567890abcdef']}}}
            ], 'outbounds': [{'type': 'direct', 'tag': 'wg-relay'}], 'route': {'rules': [
                {'inbound': ['tcp-in'], 'network': 'udp', 'ip_cidr': ['127.0.0.1/32'], 'port': [self.wg_port], 'action': 'route', 'outbound': 'wg-relay'},
                {'inbound': ['tcp-in'], 'action': 'reject'}], 'final': 'wg-relay'}}
            self.engines.append(EngineProcess(tcp, self.directory, 'reality-server'))
            proxy = port()
            self.client(proxy, {'type': 'vless', 'tag': 'tc-transport', 'server': '127.0.0.1', 'server_port': tcp_port,
                                'uuid': uuid, 'tls': {'enabled': True, 'server_name': 'localhost',
                                  'utls': {'enabled': True, 'fingerprint': 'chrome'},
                                  'reality': {'enabled': True, 'public_key': reality['PublicKey'], 'short_id': '1234567890abcdef'}}})
            body = response(proxy, '10.123.0.1:' + str(self.http.server_port))
            self.assertIn(b'200 OK', body)
            self.assertIn(b'LOCAL_PROTOCOL_E2E_ONLY', body)
            by_domain = response(proxy, 'probe.fixture:' + str(self.http.server_port))
            self.assertIn(b'LOCAL_PROTOCOL_E2E_ONLY', by_domain)
            self.assertGreater(self.dns.queries, 0)
            checker = self.directory / 'check-strict-tls.ps1'
            result = self.directory / 'strict-tls-result.json'
            checker.write_text('''param($PackageRoot,$OutputPath,[int]$ProxyPort,[int]$TlsPort)
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PackageRoot 'CandidateProbe.psm1') -PassThru -DisableNameChecking
$row=& $module {param($p,$t) Invoke-TCCandidateProbeHttp $p 'fixture' 'independent-fixture-secret' ([pscustomobject]@{Name='StrictTlsFixture';Url=('https://10.123.0.1:'+$t+'/probe');Trace=$false}) 5} $ProxyPort $TlsPort
[IO.File]::WriteAllText($OutputPath,($row|ConvertTo-Json),(New-Object Text.UTF8Encoding($false)))
''', encoding='utf-8-sig')
            powershell = Path(os.environ['SYSTEMROOT']) / 'System32/WindowsPowerShell/v1.0/powershell.exe'
            native([powershell, '-NoProfile', '-NonInteractive', '-File', checker,
                    PACKAGE, result, str(proxy), str(tls_server.server_port)])
            strict = json.loads(result.read_text(encoding='utf-8'))
            self.assertEqual('Failed', strict['Status'])
            self.assertFalse(strict['TlsVerified'])
            self.assertIn(strict['Code'], ('TlsFailed', 'DnsTcpOrTlsFailed'))
        finally:
            tls_server.shutdown()
            tls_server.server_close()
            thread.join(timeout=2)


if __name__ == '__main__':
    unittest.main(verbosity=2)
