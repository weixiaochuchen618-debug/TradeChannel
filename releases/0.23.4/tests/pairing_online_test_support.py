"""Only fake Linux state/kernel and loopback sockets; no production path IO."""
import contextlib
import datetime as dt
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import threading
import uuid

from test_tcp_backend import base, tc, TcpOS

sys.modules["tradechannel_linux"] = tc
spec = importlib.util.spec_from_file_location("pairing_online", Path(__file__).resolve().parents[1] / "linux" / "pairing_online.py")
online = importlib.util.module_from_spec(spec)
sys.modules["pairing_online"] = online
spec.loader.exec_module(online)
mg = tc.management


class MemoryFS(base.MemoryFS):
    def __init__(self):
        super().__init__()
        self.mutex = threading.RLock()

    @contextlib.contextmanager
    def lock(self, readonly=False):
        with self.mutex:
            yield

    def read(self, path):
        # SecureFS.read() decodes with universal newlines while cas() stores text
        # unchanged, so stored CRLF reads back as LF. A raw read here hid the
        # field failure fixed in 0.21.6.
        text = super().read(path)
        return None if text is None else io.TextIOWrapper(io.BytesIO(text.encode("utf-8")), encoding="utf-8").read()

    def read_exact(self, path):
        return super().read(path)


class Clock:
    def __init__(self):
        self.offset = dt.timedelta()

    def __call__(self):
        return dt.datetime.now(dt.timezone.utc) + self.offset


class Crypto(mg.OpenSSLCrypto):
    identity = None

    def __init__(self):
        super().__init__("/usr/bin/openssl" if os.name == "posix" else r"C:\Program Files\Git\usr\bin\openssl.exe")

    def generate(self):
        if Crypto.identity is None:
            Crypto.identity = super().generate()
        return Crypto.identity


class Fixture:
    certificate = None

    def __init__(self):
        self.fs, self.clock, self.crypto = MemoryFS(), Clock(), Crypto()
        self.kernel = TcpOS(self.fs)
        self.backend = tc.Backend(self.fs, self.kernel, now=self.clock, management_crypto=self.crypto, progress=lambda _: None)
        plan_input = base.plan_input()
        plan_input["PublicEndpoint"] = "1.1.1.1:51820"  # Syntax fixture, never contacted.
        plan_input["Transport"] = {"Type": "tcp-reality", "Port": 443, "ServerName": "www.bing.com"}
        plan = self.backend.plan(plan_input)
        self.backend.apply({"PlanId": plan["PlanId"]})
        proposal = self.backend.execute("management_plan", {})
        self.backend.execute("management_apply", {"PlanId": proposal["PlanId"], "ApprovedChangeDigest": proposal["ChangeDigest"]})
        manager = self.backend.manager()
        _, owner, manifest, _ = manager.context()
        self.expected = {"ExpectedServerBinding": manager.binding(owner, manifest),
                         "ExpectedManagementFingerprint": online.fingerprint(manager.signing()[1])}
        self.application = online.OnlinePairing(self.backend, allow_loopback=True)
        self.application.remove_cache = self.remove_cache
        if Fixture.certificate is None:
            Fixture.certificate = online.make_certificate(self.crypto)
        self.fs.mkdir(online.ROOT)
        self.fs.cas(online.TLS_KEY, None, Fixture.certificate[0])
        self.fs.cas(online.CERT, None, Fixture.certificate[1])
        folder = Path(__file__).resolve().parents[1] / "linux"
        # As the deploy host sends them (File.ReadAllText): BOM dropped, line
        # endings kept; tradechannel_linux.py is CRLF in the Windows package.
        self.sources = {name: (folder / name).read_bytes().decode("utf-8-sig") for name in online.SOURCES}
        # Python-only fixtures mirror the embedded source contract. The actual
        # SSH/PowerShell E2E obtains it from Get-TCConnectionMethodPythonSource.
        declaration = (folder.parent / "ConnectionMethods.json").read_bytes().decode("utf-8-sig")
        self.sources["connection_methods.py"] = "_DECLARATION_JSON = " + json.dumps(declaration) + "\n" + self.sources["connection_methods.py"]
        self.system_commands = []

    def install(self, port=18443):
        return self.application.install(dict(self.expected, PublicHost="127.0.0.1", Port=port), self.sources,
                                        lambda command: self.system_commands.append(command))

    def windows_sources(self):
        """CRLF throughout, whatever line endings this checkout has."""
        return {name: text.replace("\r\n", "\n").replace("\n", "\r\n") for name, text in self.sources.items()}

    def create_over_ssh(self, sources):
        """One "生成邀请码" as the deploy host runs it: install, create, then let it expire."""
        payload = dict(self.expected, InviteId=str(uuid.uuid4()), DeviceName="New PC", ExpiresInSeconds=600, PublicHost="127.0.0.1", Port=18443)
        result = online.ssh_entry({"Action": "create", "Input": payload}, sources, application=self.application,
                                  run_system=self.system_commands.append, listener_start=lambda _: None)
        self.clock.offset += dt.timedelta(seconds=600 + online.RETRY_SECONDS + 5)
        return result

    def remove_cache(self, fs, cache, entries):
        fs.check(online.RUNTIME)
        for entry in entries:
            fs.files.pop(cache + "/" + entry, None)
            fs.modes.pop(cache + "/" + entry, None)
        fs.dirs.discard(cache)
        fs.modes.pop(cache, None)

    def listener_cache(self, *names):
        """What a pre-0.21.4 listener left beside its sources (UMask=0077)."""
        cache = online.RUNTIME + "/" + online.BYTECODE_CACHE
        self.fs.dirs.add(cache)
        self.fs.modes[cache] = 0o700
        for name in names or ("connection_methods.cpython-311.pyc", "management_support.cpython-311.pyc",
                              "transport_support.cpython-311.pyc", "tradechannel_linux.cpython-311.pyc"):
            self.fs.files[cache + "/" + name] = "\x00compiled"
            self.fs.modes[cache + "/" + name] = 0o600
        return cache

    def create(self, **fields):
        value = dict(self.expected, InviteId=str(uuid.uuid4()), DeviceName="Isolated new computer", ExpiresInSeconds=600)
        value.update(fields)
        return self.application.create(value), value

    def code(self, invitation):
        return mg.strict_json(mg.unb64(invitation["InvitationCode"][5:]))

    def pair(self, invitation, number=2, private=None):
        private, public = private or self.crypto.generate()
        request = base.request(number)
        request["CreatedAtUtc"] = online.stamp(self.clock())
        body = dict(SchemaVersion=1, Kind="TradeChannel.PairRequest", InviteId=invitation["InviteId"],
                    ServerBinding=invitation["ServerBinding"], ClientRequest=request, DeviceName="New computer",
                    RecipientJwk=public, RequestDigest=mg.request_digest(request), RequestDigestAlgorithm=mg.DIGEST_ALGORITHM,
                    CreatedAtUtc=online.stamp(self.clock()))
        return {"PairRequest": mg.sign_jws(self.crypto, private, body)}, body

    def count(self):
        return len(self.backend.read_json(tc.MANIFEST)["Peers"])
