#!/usr/bin/env python3
"""Short-lived, pinned-TLS enrollment; the offline management contract is intact.

Installed/launched only through authenticated SSH. The HTTP surface has exactly
two operations: read an invitation and submit its signed public PairRequest.
Management keys remain at management_support.PRIVATE_KEY. Peer authorization and
invitation consumption use Manager.authorize_external's existing durable journal.
No client private key, SSH credential, arbitrary command or recovery action is
accepted by the listener. Runtime dependencies: Python stdlib + system OpenSSL.
"""
import argparse
import copy
import ctypes
import ctypes.util
import datetime as dt
import hashlib
import hmac
import http.server
import ipaddress
import json
import os
from pathlib import Path
import re
import socket
import ssl
import stat
import struct
import subprocess
import sys
import tempfile
import threading
import time
import uuid

# -I intentionally ignores the working directory. Only the root-owned installed
# sibling modules are imported; SSH bootstrap may instead preload these modules.
# -I does not stop Python from caching their bytecode in RUNTIME/__pycache__,
# which the ownership check reads as an unowned file: before 0.21.4 every
# invitation after a server's first was refused (OnlineOwnershipMismatch).
sys.dont_write_bytecode = True
if "management_support" not in sys.modules:
    sys.path.insert(0, str(Path(__file__).resolve().parent))
import management_support as mg
import tradechannel_linux as tc

ROOT = tc.ROOT + "/pairing-online"
CONFIG = ROOT + "/service.json"
TOKEN_KEY = ROOT + "/token.key"
CERT = ROOT + "/tls.crt"
TLS_KEY = ROOT + "/tls.key"
RATE = ROOT + "/rate.json"
OWNERSHIP = ROOT + "/installation.json"
MAINTENANCE = ROOT + "/maintenance.json"
RUNTIME = ROOT + "/runtime"
BYTECODE_CACHE = "__pycache__"
BYTECODE_ENTRY = re.compile(r"([a-z_]+)\.cpython-\d+(?:\.opt-[12])?\.pyc(?:\.\d+)?")
UNIT_PATH = "/etc/systemd/system/tradechannel-pairing-online.service"
UNIT_NAME = "tradechannel-pairing-online.service"
SOURCES = ("connection_methods.py", "management_support.py", "transport_support.py", "tradechannel_linux.py", "pairing_online.py")
MAX_BODY = 128 * 1024
RETRY_SECONDS = 120
# Invitation lifetime is chosen by the operator on the management computer.
# The retry window stays fixed; only the invitation itself may last up to a day.
MAX_LIFETIME = 86400
DEFAULT_PORT = 18443
UNIT = """[Unit]
Description=TradeChannel short-lived invitation enrollment
After=network.target
[Service]
Type=simple
ExecStart=/usr/bin/python3 -I /var/lib/tradechannel/pairing-online/runtime/pairing_online.py serve
Restart=no
UMask=0077
NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=yes
StandardOutput=null
StandardError=null
TimeoutStopSec=10
"""


def require(value, code="InvalidOnlineInput", message="Online pairing input is invalid."):
    mg.require(value, code, message)


def fingerprint(jwk):
    mg.validate_jwk(jwk)
    return "SHA256:" + __import__("base64").b64encode(hashlib.sha256(mg.compact(jwk).encode()).digest()).decode().rstrip("=")


def stamp(value):
    return value.astimezone(dt.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def public_host(value, allow_loopback=False):
    try:
        address = ipaddress.IPv4Address(value)
        require(str(address) == value and (address.is_global or allow_loopback and address.is_loopback))
    except (ValueError, TypeError):
        raise mg.ManagementError("InvalidOnlineHost", "Use the owned server's public IPv4 address.") from None
    return value


def certificate_sha256(pem):
    return hashlib.sha256(ssl.PEM_cert_to_DER_cert(pem)).hexdigest()


def universal_newlines(text):
    """What SecureFS.read() returns for stored text: CRLF and lone CR become LF."""
    return text.replace("\r\n", "\n").replace("\r", "\n")


class AesCbc:
    """OpenSSL EVP, not a Python cipher implementation. Keys never enter argv."""
    def __init__(self, library=None):
        candidate = library or ctypes.util.find_library("crypto")
        if not candidate and os.name == "nt":
            candidate = r"C:\Program Files\Git\mingw64\bin\libcrypto-3-x64.dll"
        try:
            self.lib = ctypes.CDLL(candidate) if candidate else None
            require(self.lib is not None, "MissingOnlineCrypto", "System libcrypto is required.")
            self.lib.EVP_CIPHER_CTX_new.restype = ctypes.c_void_p
            self.lib.EVP_CIPHER_CTX_free.argtypes = [ctypes.c_void_p]
            self.lib.EVP_aes_256_cbc.restype = ctypes.c_void_p
            self.lib.EVP_EncryptInit_ex.argtypes = [ctypes.c_void_p] * 5
            self.lib.EVP_EncryptUpdate.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.POINTER(ctypes.c_int), ctypes.c_void_p, ctypes.c_int]
            self.lib.EVP_EncryptFinal_ex.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.POINTER(ctypes.c_int)]
        except (OSError, AttributeError):
            raise mg.ManagementError("MissingOnlineCrypto", "OpenSSL EVP AES support is required.") from None

    def encrypt(self, key, iv, plaintext):
        require(len(key) == 32 and len(iv) == 16 and len(plaintext) <= MAX_BODY)
        context = self.lib.EVP_CIPHER_CTX_new()
        require(context, "OnlineCryptoFailed")
        output = ctypes.create_string_buffer(len(plaintext) + 32)
        first, last = ctypes.c_int(), ctypes.c_int()
        try:
            require(self.lib.EVP_EncryptInit_ex(context, self.lib.EVP_aes_256_cbc(), None, key, iv) == 1, "OnlineCryptoFailed")
            require(self.lib.EVP_EncryptUpdate(context, output, ctypes.byref(first), plaintext, len(plaintext)) == 1, "OnlineCryptoFailed")
            require(self.lib.EVP_EncryptFinal_ex(context, ctypes.byref(output, first.value), ctypes.byref(last)) == 1, "OnlineCryptoFailed")
            return output.raw[:first.value + last.value]
        finally:
            self.lib.EVP_CIPHER_CTX_free(context)


def encrypt_authorization(crypto, aes, signed, jwk):
    """Same RSA-OAEP-256 / A256CBC-HS512 compact JWE as PairCrypto.Encrypt."""
    mg.decode_jws(signed)
    mg.validate_jwk(jwk)
    cek, iv = os.urandom(64), os.urandom(16)
    header = mg.b64(b'{"alg":"RSA-OAEP-256","enc":"A256CBC-HS512","cty":"TC-Pairing-v1"}')
    with tempfile.TemporaryDirectory(prefix="tc-online-public-") as directory:
        path = os.path.join(directory, "recipient.der")
        with open(path, "xb") as stream:
            stream.write(mg.public_der(jwk))
        wrapped = crypto.run(["pkeyutl", "-encrypt", "-pubin", "-keyform", "DER", "-inkey", path,
                              "-pkeyopt", "rsa_padding_mode:oaep", "-pkeyopt", "rsa_oaep_md:sha256",
                              "-pkeyopt", "rsa_mgf1_md:sha256"], cek)
    ciphertext = aes.encrypt(cek[32:], iv, signed.encode("ascii"))
    aad = header.encode("ascii")
    tag = hmac.new(cek[:32], aad + iv + ciphertext + struct.pack(">Q", len(aad) * 8), hashlib.sha512).digest()[:32]
    result = ".".join((header, mg.b64(wrapped), mg.b64(iv), mg.b64(ciphertext), mg.b64(tag)))
    require(len(result) <= MAX_BODY, "OnlineOutputTooLarge")
    return result


def remove_bytecode_cache(fs, cache, entries):
    """Delete RUNTIME/__pycache__: root-owned regular files only, no links.

    Bytecode is binary derived data, so it cannot go through the text-only
    compare-and-swap; the parent still passes the strict state-path check.
    """
    fs.check(RUNTIME)
    info = os.lstat(cache)
    require(stat.S_ISDIR(info.st_mode) and info.st_uid == 0 and not info.st_mode & 0o022,
            "OnlineOwnershipMismatch", "The runtime bytecode cache is not a private root directory.")
    paths = [cache + "/" + entry for entry in entries]
    for path in paths:
        item = os.lstat(path)
        require(stat.S_ISREG(item.st_mode) and item.st_uid == 0 and item.st_nlink == 1,
                "OnlineOwnershipMismatch", "The runtime bytecode cache contains an unexpected entry.")
    for path in paths:
        os.unlink(path)
    os.rmdir(cache)


class OnlinePairing:
    def __init__(self, backend, allow_loopback=False, aes=None):
        self.b = backend
        self.m = backend.manager()
        self.allow_loopback = allow_loopback  # Injection for isolated tests; no production CLI flag.
        self.aes = aes or AesCbc()
        self.http_crypto = backend.management_crypto
        self.remove_cache = remove_bytecode_cache  # Isolated tests substitute their memory filesystem.

    def _identity(self, value):
        env, owner, manifest, plan = self.m.context()
        _, public = self.m.signing()
        require(value.get("ExpectedServerBinding") == self.m.binding(owner, manifest), "OnlineServerChanged", "The selected server identity changed.")
        require(value.get("ExpectedManagementFingerprint") == fingerprint(public), "OnlineSigningIdentityChanged", "The management signing identity changed.")
        self.m.load(owner, manifest)
        return env, owner, manifest, plan, public

    def config(self):
        value = self.b.read_json(CONFIG)
        require(value and value.get("SchemaVersion") == 1, "OnlineNotInstalled", "Install online pairing through the pinned SSH connection first.")
        require(certificate_sha256(self.b.fs.read(CERT)) == value["TlsSha256"], "OnlineTlsIdentityChanged", "The invitation TLS identity changed.")
        return value

    def _active_deadline(self):
        state = self.b.read_json(mg.STATE)
        require(state and isinstance(state.get("Invites"), dict), "InvalidManagementState")
        deadlines = [self.m.time(v["ExpiresAtUtc"] if v["State"] == "Open" else v["Online"]["RetryUntilUtc"])
                     for v in state["Invites"].values() if v.get("Online") and v["State"] in ("Open", "Consumed")]
        return max(deadlines) if deadlines else self.b.now()

    def _certificate_usable(self, certificate, seconds):
        try:
            self.http_crypto.run(["x509", "-checkend", str(seconds), "-noout"], certificate.encode("ascii"))
            return True
        except mg.ManagementError as error:
            if error.code == "SigningOperationFailed":
                return False
            raise

    def _check_unit_location(self):
        for path in (UNIT_PATH + ".d", "/run/systemd/system/" + UNIT_NAME, "/run/systemd/system/" + UNIT_NAME + ".d"):
            require(not self.b.fs.exists(path), "OnlineUnitConflict", "The online service has an unexpected unit override.")

    def _drop_bytecode_cache(self):
        """Remove the bytecode an earlier listener cached beside its sources.

        Only compiled forms of the five owned modules may be there; anything
        else is still an unowned file and keeps the refusal.
        """
        if BYTECODE_CACHE not in self.b.fs.list(RUNTIME):
            return False
        cache = RUNTIME + "/" + BYTECODE_CACHE
        entries = self.b.fs.list(cache)
        modules = {name[:-3] for name in SOURCES}
        for entry in entries:
            match = BYTECODE_ENTRY.fullmatch(entry)
            require(match is not None and match.group(1) in modules, "OnlineOwnershipMismatch",
                    "The runtime bytecode cache contains an unexpected file.")
        self.remove_cache(self.b.fs, cache, entries)
        return True

    def _verify_owned_installation(self, existing):
        names = self.b.fs.list(RUNTIME)
        require(set(names) <= set(SOURCES), "OnlineOwnershipMismatch", "The runtime contains an unowned file.")
        # Since 0.21.6 digests cover the text as read() returns it. Earlier
        # clients digested it as sent, CRLF included, and that text stays on disk
        # (cas() skips a rewrite that read() cannot tell apart): accept both forms.
        stored = {name: self.b.fs.read_exact(RUNTIME + "/" + name) for name in names}
        require(all(isinstance(text, str) for text in stored.values()),
                "OnlineOwnershipMismatch", "The installed online sources differ from their recorded digest.")
        installed = {name: universal_newlines(text) for name, text in stored.items()}
        require(existing["RuntimeDigest"] in {hashlib.sha256(mg.compact(texts).encode()).hexdigest() for texts in (installed, stored)},
                "OnlineOwnershipMismatch", "The installed online sources differ from their recorded digest.")
        self._check_unit_location()
        certificate, private = self.b.fs.read(CERT), self.b.fs.read(TLS_KEY)
        require(certificate and private and certificate_sha256(certificate) == existing["TlsSha256"], "OnlineTlsIdentityChanged")
        public_pem = self.http_crypto.run(["x509", "-pubkey", "-noout"], certificate.encode())
        public_der = self.http_crypto.run(["pkey", "-pubin", "-outform", "DER"], public_pem)
        require(self.http_crypto.public(private) == mg.parse_public_der(public_der), "OnlineTlsIdentityChanged")
        token = self.b.fs.read(TOKEN_KEY)
        require(isinstance(token, str) and re.fullmatch(r"[0-9a-f]{64}", token), "OnlineIdentityMissing")
        recorded = self.b.read_json(OWNERSHIP)
        tracked = [RUNTIME + "/" + name for name in names] + [UNIT_PATH, CONFIG, TOKEN_KEY, CERT, TLS_KEY]
        if recorded:
            require(recorded.get("SchemaVersion") == 1 and recorded.get("Kind") == "TradeChannel.OnlineInstallation"
                    and recorded.get("ServerBinding") == existing["ServerBinding"] and set(recorded.get("Hashes", {})) == set(tracked), "OnlineOwnershipMismatch")
            for path in tracked:
                content = self.b.fs.read_exact(path)
                require(content is not None and recorded["Hashes"][path] in
                        {hashlib.sha256(text.encode()).hexdigest() for text in (universal_newlines(content), content)},
                        "OnlineOwnershipMismatch", "An owned online resource changed outside its maintenance transaction.")
        else:
            # Migration from the first E1 implementation: its config already
            # pins the complete old runtime and TLS certificate. The sole old
            # unit form is known exactly; do not adopt an arbitrary unit.
            require(self.b.fs.read(UNIT_PATH) == UNIT, "OnlineOwnershipMismatch")
        return installed

    def _apply_maintenance(self, journal, runner):
        allowed = {RUNTIME + "/" + name for name in SOURCES} | {UNIT_PATH, CONFIG, TOKEN_KEY, CERT, TLS_KEY, OWNERSHIP}
        mg.schema(journal, ("SchemaVersion", "Kind", "ServerBinding", "StopListener", "Files"))
        require(journal["SchemaVersion"] == 1 and journal["Kind"] == "TradeChannel.OnlineMaintenance"
                and type(journal["StopListener"]) is bool and isinstance(journal["Files"], dict)
                and {CONFIG, OWNERSHIP} <= set(journal["Files"]) <= allowed, "OnlineMaintenanceInvalid")
        require(self._active_deadline() <= self.b.now(), "OnlineMaintenanceDeferred", "Existing invitations or their response retry windows are still active.")
        self._check_unit_location()
        for path, versions in journal["Files"].items():
            mg.schema(versions, ("Before", "After"))
            states = (versions["Before"], versions["After"])
            # A journal from before 0.21.6 may hold CRLF sources as After; once
            # written, only the exact read still equals them.
            require((versions["Before"] is None or isinstance(versions["Before"], str)) and isinstance(versions["After"], str)
                    and (self.b.fs.read(path) in states or self.b.fs.read_exact(path) in states), "OnlineOwnershipMismatch")
            if path == TOKEN_KEY and versions["Before"] is not None:
                require(versions["Before"] == versions["After"], "OnlineIdentityChanged")
        if journal["StopListener"]:
            runner(["systemctl", "stop", UNIT_NAME])
        for path, versions in journal["Files"].items():
            self.b.fs.cas(path, self.b.fs.read(path), versions["After"], mode=0o600)
        runner(["systemctl", "daemon-reload"])
        self.b.fs.cas(MAINTENANCE, self.b.fs.read(MAINTENANCE), None)

    def _recover_maintenance(self, expected_binding, runner):
        journal = self.b.read_json(MAINTENANCE)
        if journal is None:
            return False
        require(journal.get("ServerBinding") == expected_binding, "OnlineServerChanged")
        self._apply_maintenance(journal, runner)
        return True

    def install(self, value, sources, run_system=None, valid_for_seconds=MAX_LIFETIME + RETRY_SECONDS + 30):
        mg.schema(value, ("ExpectedServerBinding", "ExpectedManagementFingerprint", "PublicHost", "Port"))
        public_host(value["PublicHost"], self.allow_loopback)
        require(type(value["Port"]) is int and 1024 <= value["Port"] <= 65535, "InvalidOnlinePort")
        require(isinstance(sources, dict) and set(sources) == set(SOURCES), "InvalidOnlineSources")
        for name, source in sources.items():
            require(isinstance(source, str) and len(source.encode("utf-8")) <= 2 * 1024 * 1024, "InvalidOnlineSources")
            compile(source, name, "exec")
        # Sources arrive as packaged; tradechannel_linux.py is CRLF in the Windows
        # package. cas() stored it as sent but read() hands it back with LF, so
        # the recorded runtime digest never matched again and every invitation
        # after a server's first was refused (OnlineOwnershipMismatch,
        # 0.20.0-0.21.5). Store the form read() returns.
        sources = {name: universal_newlines(source) for name, source in sources.items()}
        env, owner, manifest, plan, public = self._identity(value)
        require(self.allow_loopback or plan["PublicEndpoint"].split(":")[0] == value["PublicHost"], "OnlineEndpointMismatch")
        require(value["Port"] != int(plan["PublicEndpoint"].split(":")[1]) and value["Port"] != (plan.get("Transport") or {}).get("Port"), "OnlinePortConflict")
        runtime_digest = hashlib.sha256(mg.compact(sources).encode()).hexdigest()
        runner = run_system or system_command
        runtime_updated = certificate_renewed = recovered = cache_removed = False
        with self.b.fs.lock():
            self.b.no_transaction()
            locked = self.m.locked_context(env)
            require(self.m.binding(locked[0], locked[1]) == value["ExpectedServerBinding"], "OnlineServerChanged")
            _, locked_public = self.m.signing()
            require(fingerprint(locked_public) == value["ExpectedManagementFingerprint"], "OnlineSigningIdentityChanged")
            for directory in (ROOT, RUNTIME):
                self.b.fs.mkdir(directory)
            recovered = self._recover_maintenance(value["ExpectedServerBinding"], runner)
            cache_removed = self._drop_bytecode_cache()
            existing = self.b.read_json(CONFIG)
            if existing:
                require(all(existing[k] == value[k] for k in ("PublicHost", "Port")) and existing["ServerBinding"] == value["ExpectedServerBinding"]
                        and existing["ManagementFingerprint"] == fingerprint(public),
                        "OnlineInstallationConflict", "The existing online endpoint belongs to different connection or identity parameters.")
                self._verify_owned_installation(existing)
            else:
                self._check_unit_location()
                for name, source in sources.items():
                    require(self.b.fs.read(RUNTIME + "/" + name) in (None, source), "OnlineOwnershipMismatch")
                require(set(self.b.fs.list(RUNTIME)) <= set(SOURCES) and self.b.fs.read(UNIT_PATH) in (None, UNIT)
                        and self.b.fs.read(OWNERSHIP) is None, "OnlineOwnershipMismatch")
            key, cert = self.b.fs.read(TLS_KEY), self.b.fs.read(CERT)
            require((key is None) == (cert is None), "OnlineIdentityIncomplete", "Incomplete TLS identity requires explicit repair.")
            runtime_updated = bool(existing and (existing["RuntimeDigest"] != runtime_digest or self.b.fs.read(UNIT_PATH) != UNIT))
            certificate_renewed = bool(existing and not self._certificate_usable(cert, valid_for_seconds))
            changed = existing is None or runtime_updated or certificate_renewed
            if changed:
                require(self._active_deadline() <= self.b.now(), "OnlineMaintenanceDeferred", "Wait for the existing invitations and their retry windows before online component or certificate maintenance.")
            if key is None or certificate_renewed:
                require(key is not None or existing is None, "OnlineIdentityMissing")
                key, cert = make_certificate(self.http_crypto)
            config = dict(SchemaVersion=1, PublicHost=value["PublicHost"], Port=value["Port"],
                          ListenHost="127.0.0.1" if self.allow_loopback else "0.0.0.0", ServerBinding=value["ExpectedServerBinding"],
                          ManagementFingerprint=fingerprint(public), TlsSha256=certificate_sha256(cert), RuntimeDigest=runtime_digest)
            token = self.b.fs.read(TOKEN_KEY)
            require(token is not None or existing is None, "OnlineIdentityMissing")
            token = token or os.urandom(32).hex()
            require(isinstance(token, str) and re.fullmatch(r"[0-9a-f]{64}", token), "OnlineIdentityMissing")
            desired = {RUNTIME + "/" + name: source for name, source in sources.items()}
            desired.update({UNIT_PATH: UNIT, CONFIG: self.b.dumps(config), TLS_KEY: key, CERT: cert, TOKEN_KEY: token})
            ownership = dict(SchemaVersion=1, Kind="TradeChannel.OnlineInstallation", ServerBinding=config["ServerBinding"],
                             Hashes={path: hashlib.sha256(text.encode()).hexdigest() for path, text in desired.items()})
            if changed:
                desired[OWNERSHIP] = self.b.dumps(ownership)
                journal = dict(SchemaVersion=1, Kind="TradeChannel.OnlineMaintenance", ServerBinding=config["ServerBinding"], StopListener=bool(existing),
                               Files={path: {"Before": self.b.fs.read(path), "After": text} for path, text in desired.items()})
                encoded = self.b.dumps(journal)
                require(len(encoded.encode()) <= 4 * 1024 * 1024, "OnlineMaintenanceTooLarge")
                self.b.fs.cas(MAINTENANCE, None, encoded)
                self._apply_maintenance(journal, runner)
            else:
                # Recording ownership for a verified legacy install changes no
                # listener/source/certificate and is safe with existing invites.
                if self.b.fs.read(OWNERSHIP) is None:
                    self.b.fs.cas(OWNERSHIP, None, self.b.dumps(ownership))
                runner(["systemctl", "daemon-reload"])
            require(self.config() == config, "OnlineInstallationConflict")
        return dict(Status="Prepared", **config, RunningTunnelChanged=False, AutomaticallyEnabledAtBoot=False,
                    Maintenance={"RuntimeUpdated": runtime_updated, "CertificateRenewed": certificate_renewed, "Recovered": recovered,
                                 "BytecodeCacheRemoved": cache_removed})

    def _token(self, invite_id, digest):
        value = self.b.fs.read(TOKEN_KEY)
        require(isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value), "OnlineIdentityMissing")
        return mg.b64(hmac.new(bytes.fromhex(value), ("TC-Online-v1\n" + invite_id + "\n" + digest).encode(), hashlib.sha256).digest())

    def validate_create(self, value):
        mg.schema(value, ("InviteId", "DeviceName", "ExpiresInSeconds", "ExpectedServerBinding", "ExpectedManagementFingerprint"))
        invite_id = self.m.guid(value["InviteId"])
        self.m.name(value["DeviceName"])
        require(len(value["DeviceName"]) <= 64 and type(value["ExpiresInSeconds"]) is int and 60 <= value["ExpiresInSeconds"] <= MAX_LIFETIME)
        return invite_id

    def create(self, value):
        invite_id = self.validate_create(value)
        env, owner, manifest, plan, public = self._identity(value)
        config = self.config()
        require(config["ServerBinding"] == value["ExpectedServerBinding"] and config["ManagementFingerprint"] == fingerprint(public), "OnlineServerChanged")
        try:
            self.http_crypto.run(["x509", "-checkend", str(value["ExpiresInSeconds"] + RETRY_SECONDS + 30), "-noout"], self.b.fs.read(CERT).encode("ascii"))
        except mg.ManagementError:
            raise mg.ManagementError("OnlineTlsCertificateExpired", "The existing TLS certificate cannot cover this invitation lifetime; repair it through SSH before creating a new invitation.") from None
        digest = hashlib.sha256(mg.compact(dict(value, TlsSha256=config["TlsSha256"], PublicHost=config["PublicHost"], Port=config["Port"])).encode()).hexdigest()
        token = self._token(invite_id, digest)
        with self.b.fs.lock():
            owner, manifest, plan = self.m.locked_context(env)
            self.b.no_transaction()
            self.b.verify(plan, manifest, env)
            before = self.m.load(owner, manifest)
            private, public = self.m.signing()
            require(fingerprint(public) == value["ExpectedManagementFingerprint"] and self.m.binding(owner, manifest) == value["ExpectedServerBinding"], "OnlineServerChanged")
            invitation = before["Invites"].get(invite_id)
            if invitation:
                require(invitation.get("Online", {}).get("InputDigest") == digest, "InviteIdConflict")
            else:
                require(len(before["Invites"]) < 512, "InviteLimit")
                expires = self.b.now() + dt.timedelta(seconds=value["ExpiresInSeconds"])
                binding = self.m.binding(owner, manifest)
                body = dict(SchemaVersion=1, Kind="TradeChannel.PairInvite", InviteId=invite_id, **binding,
                            ServerBinding=binding, ManagementSigningPublicKey=public, PublicEndpoint=plan["PublicEndpoint"],
                            IssuedAtUtc=self.m.at(), ExpiresAtUtc=stamp(expires),
                            Capabilities={"PairingVersion": 1, "ManagementApiVersion": 2, "OnlineVersion": 1,
                                          "Transport": "tcp-reality" if plan.get("Transport") else "udp"})
                signed = mg.sign_jws(self.m.crypto, private, body)
                descriptor = dict(SchemaVersion=1, Kind="TradeChannel.OnlineInvite", InviteId=invite_id, Invite=signed,
                                  PublicHost=config["PublicHost"], Port=config["Port"], TlsSha256=config["TlsSha256"],
                                  ManagementFingerprint=fingerprint(public), ExpiresAtUtc=stamp(expires),
                                  RetryUntilUtc=stamp(expires + dt.timedelta(seconds=RETRY_SECONDS)))
                invitation = dict(InviteId=invite_id, State="Open", DeviceName=value["DeviceName"], Invite=signed,
                                  IssuedAtUtc=self.m.at(), ExpiresAtUtc=stamp(expires), InputDigest=digest,
                                  Online=dict(InputDigest=digest, TokenHash=hashlib.sha256(token.encode()).hexdigest(),
                                              Descriptor=mg.sign_jws(self.m.crypto, private, descriptor),
                                              RetryUntilUtc=descriptor["RetryUntilUtc"]))
                after = copy.deepcopy(before)
                after["Invites"][invite_id] = invitation
                self.m.audit(after, "OnlineInviteCreated", InviteId=invite_id)
                # Same metadata journal/recovery allowlist as offline invites.
                self.m.metadata_transaction("invite_create", {mg.STATE: {"Before": self.b.dumps(before), "After": self.b.dumps(after)}})
        code = dict(v=1, h=config["PublicHost"], p=config["Port"], i=invite_id, k=token, t=config["TlsSha256"],
                    m=fingerprint(public), e=int(self.m.time(invitation["ExpiresAtUtc"]).timestamp()))
        return dict(self.m.invite_view(invitation), InvitationCode="TCI1." + mg.b64(mg.compact(code).encode()),
                    RetryUntilUtc=invitation["Online"]["RetryUntilUtc"], ServerBinding=config["ServerBinding"],
                    ManagementFingerprint=fingerprint(public), TlsSha256=config["TlsSha256"],
                    PublicHost=config["PublicHost"], Port=config["Port"], NetworkChanged=False)

    def _lookup(self, invite_id, token):
        self.m.guid(invite_id)
        require(isinstance(token, str) and re.fullmatch(r"[A-Za-z0-9_-]{43}", token), "InviteAuthenticationFailed")
        config = self.config()
        with self.b.fs.lock(readonly=True):
            self.b.no_transaction()
            require(self.b.fs.read(MAINTENANCE) is None, "OnlineMaintenancePending")
            state = self.b.read_json(mg.STATE)
            require(state and state.get("ServerBinding") == config["ServerBinding"], "OnlineServerChanged")
            invitation = state["Invites"].get(invite_id)
            online = invitation.get("Online", {}) if invitation else {}
            expected = online.get("TokenHash", "0" * 64)
            require(hmac.compare_digest(hashlib.sha256(token.encode()).hexdigest(), expected), "InviteAuthenticationFailed")
            require(invitation["State"] in ("Open", "Consumed"), "InviteUnavailable")
            deadline = invitation["ExpiresAtUtc"] if invitation["State"] == "Open" else online["RetryUntilUtc"]
            require(self.m.time(deadline) > self.b.now(), "OnlineInviteExpired", "This online invitation has expired.")
            _, public = self.m.signing()
            require(fingerprint(public) == config["ManagementFingerprint"], "OnlineSigningIdentityChanged")
            return copy.deepcopy(invitation)

    def fetch(self, invite_id, token):
        invitation = self._lookup(invite_id, token)
        return dict(Status="InvitationReady" if invitation["State"] == "Open" else "RetryOnly", SignedDescriptor=invitation["Online"]["Descriptor"])

    def redeem(self, invite_id, token, value):
        mg.schema(value, ("PairRequest",))
        self._lookup(invite_id, token)
        # Existing lock + journal checks expiry again at mutation time, binds the
        # exact signed request, consumes once and refuses revoked authorizations.
        result = self.b.execute("authorize_external", {"InviteId": invite_id, "PairRequest": value["PairRequest"]})
        require(result.get("Status") == "Authorized" and result.get("Authorization"), "OnlineAuthorizationUnavailable", "The original authorization is unavailable or revoked; use management recovery.")
        body, _, _ = mg.decode_jws(value["PairRequest"])
        encrypted = encrypt_authorization(self.http_crypto, self.aes, result["Authorization"], body["RecipientJwk"])
        return dict(Status="Authorized", RequestId=result["RequestId"], RequestDigest=result["RequestDigest"], EncryptedAuthorization=encrypted)

    def status(self, value):
        mg.schema(value, ("InviteId", "ExpectedServerBinding", "ExpectedManagementFingerprint"))
        self._identity(value)
        result = self.b.execute("invite_status", {"InviteId": self.m.guid(value["InviteId"])})
        result.pop("Invite", None)
        return result

    def cancel(self, value):
        mg.schema(value, ("InviteId", "ExpectedServerBinding", "ExpectedManagementFingerprint"))
        self._identity(value)
        return self.b.execute("invite_cancel", {"InviteId": self.m.guid(value["InviteId"])})

    def active_until(self):
        config = self.config()
        state = self.b.read_json(mg.STATE)
        require(state and state.get("ServerBinding") == config["ServerBinding"], "OnlineServerChanged")
        return self._active_deadline()


class RateLimiter:
    """Fixed bounded buckets, charged before TLS/crypto. Durable across restart."""
    def __init__(self, backend, per_ip=20, total=120, seconds=60):
        self.b, self.per_ip, self.total, self.seconds = backend, per_ip, total, seconds
        self.lock = threading.Lock()

    def allow(self, address):
        with self.lock:
            with self.b.fs.lock():
                now = int(self.b.now().timestamp())
                previous = self.b.fs.read(RATE)
                value = self.b.parse_json(previous) if previous else None
                if value is None or now >= value["Start"] + self.seconds:
                    value = {"Start": now, "Count": 0, "Sources": {}}
                source = hashlib.sha256(address.encode()).hexdigest()
                count = value["Sources"].get(source, 0)
                if now < value["Start"] or value["Count"] >= self.total or count >= self.per_ip:
                    return False
                value["Count"] += 1
                value["Sources"][source] = count + 1
                self.b.fs.cas(RATE, previous, self.b.dumps(value))
                return True


class PairingHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "TradeChannelPairing/1"
    sys_version = ""

    def log_message(self, *args):
        pass  # Never log bearer tokens, requests, grants or device identifiers.

    def send_error(self, code, message=None, explain=None):
        self.reply(code, {"Ok": False, "Code": "InvalidOnlineHttp"})

    def reply(self, status, value):
        raw = mg.compact(value).encode("utf-8")
        require(len(raw) <= MAX_BODY, "OnlineOutputTooLarge")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.send_header("X-Content-Type-Options", "nosniff")
        if status == 429:
            self.send_header("Retry-After", "60")
        self.end_headers()
        self.wfile.write(raw)
        self.close_connection = True

    def do_GET(self):
        self.handle_pairing(False)

    def do_POST(self):
        self.handle_pairing(True)

    def handle_pairing(self, consume):
        try:
            match = re.fullmatch(r"/v1/invitations/([0-9a-f-]{36})" + (r"/consume" if consume else ""), self.path)
            require(match is not None and len(self.headers) <= 16 and self.headers.get("Transfer-Encoding") is None, "InvalidOnlineHttp")
            require(sum(len(k) + len(v) for k, v in self.headers.items()) <= 16384, "InvalidOnlineHttp")
            auth = self.headers.get_all("Authorization", [])
            require(len(auth) == 1 and re.fullmatch(r"Bearer [A-Za-z0-9_-]{43}", auth[0]), "InviteAuthenticationFailed")
            length = self.headers.get_all("Content-Length", [])
            require(len(length) <= 1, "InvalidOnlineHttp")
            if consume:
                require(len(length) == 1 and re.fullmatch(r"[0-9]{1,6}", length[0]) and 1 <= int(length[0]) <= MAX_BODY
                        and self.headers.get("Content-Type", "").split(";")[0].strip().lower() == "application/json", "InvalidOnlineHttp")
                raw = self.rfile.read(int(length[0]))
                require(len(raw) == int(length[0]), "InvalidOnlineHttp")
                value = self.server.application.redeem(match[1], auth[0][7:], mg.strict_json(raw))
            else:
                require(not length or length == ["0"], "InvalidOnlineHttp")
                value = self.server.application.fetch(match[1], auth[0][7:])
            self.reply(200, {"Ok": True, "Data": value})
        except (mg.ManagementError, tc.TCError) as exc:
            status = 401 if exc.code == "InviteAuthenticationFailed" else 410 if exc.code == "OnlineInviteExpired" else 409
            self.reply(status, {"Ok": False, "Code": exc.code})
        except (OSError, ValueError):
            self.close_connection = True
        except Exception:
            self.reply(500, {"Ok": False, "Code": "OnlineOperationFailed"})


class PairingServer(http.server.ThreadingHTTPServer):
    daemon_threads = False
    block_on_close = True
    allow_reuse_address = True
    request_queue_size = 16

    def __init__(self, address, application, certificate, private_key, rate_limiter=None):
        self.application = application
        self.rate_limiter = rate_limiter or RateLimiter(application.b)
        self.slots = threading.BoundedSemaphore(8)
        self.tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.tls.minimum_version = ssl.TLSVersion.TLSv1_2
        self.tls.load_cert_chain(certificate, private_key)
        self.tls.options |= ssl.OP_NO_COMPRESSION
        super().__init__(address, PairingHandler)

    def process_request(self, request, client_address):
        accepted = False
        try:
            if not self.slots.acquire(blocking=False):
                return
            accepted = True
            if not self.rate_limiter.allow(client_address[0]):
                return
            super().process_request(request, client_address)
            accepted = False  # Worker owns the slot and socket now.
            request = None
        except (mg.ManagementError, tc.TCError):
            pass
        finally:
            if request is not None:
                self.shutdown_request(request)
            if accepted:
                self.slots.release()

    def process_request_thread(self, request, client_address):
        secured = None
        connection = [request]
        def deadline():
            try:
                connection[0].shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            connection[0].close()
        timer = threading.Timer(45, deadline)
        timer.daemon = True
        timer.start()
        try:
            request.settimeout(5)
            secured = self.tls.wrap_socket(request, server_side=True)
            connection[0] = secured
            secured.settimeout(15)
            self.finish_request(secured, client_address)
        except (OSError, ssl.SSLError):
            pass
        finally:
            timer.cancel()
            self.shutdown_request(secured or request)
            self.slots.release()

    def handle_error(self, request, client_address):
        pass

    def serve_until_expired(self):
        # Clients cannot extend this lifetime. New invitations require SSH.
        self.timeout = 0.5
        while self.application.active_until() > self.application.b.now():
            self.handle_request()


def make_certificate(crypto):
    with tempfile.TemporaryDirectory(prefix="tc-online-tls-") as directory:
        if os.name == "posix":
            os.chmod(directory, 0o700)
        private, cert = os.path.join(directory, "tls.key"), os.path.join(directory, "tls.crt")
        crypto.run(["req", "-x509", "-newkey", "rsa:3072", "-sha256", "-nodes", "-days", "30",
                    "-subj", "/CN=TradeChannel Online Pairing", "-keyout", private, "-out", cert])
        return Path(private).read_text(encoding="ascii"), Path(cert).read_text(encoding="ascii")


def system_command(args):
    process = subprocess.run(args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20, check=False)
    require(process.returncode == 0, "OnlineServiceStartFailed", "The invitation service could not be prepared; retry the same InviteId over SSH.")
    return process.stdout.decode("utf-8", errors="strict")


def start_listener(application):
    config = application.config()
    # systemctl start is idempotent and never restarts the tunnel or an already
    # active enrollment listener. Unit is deliberately not enabled at boot.
    system_command(["systemctl", "start", UNIT_NAME])
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    for _ in range(30):
        try:
            with socket.create_connection(("127.0.0.1", config["Port"]), timeout=1) as stream:
                with context.wrap_socket(stream, server_hostname="TradeChannel") as secured:
                    require(hashlib.sha256(secured.getpeercert(binary_form=True)).hexdigest() == config["TlsSha256"], "OnlineTlsIdentityChanged")
                    return
        except OSError:
            time.sleep(0.1)
            # Covers the exit/start race when a previous lifetime ended just
            # before this SSH call created a fresh invitation. Never restart an
            # active listener; systemctl start is idempotent on the same unit.
            system_command(["systemctl", "start", UNIT_NAME])
    raise mg.ManagementError("OnlineServiceStartFailed", "The listener did not become ready; retry the same InviteId over SSH.")


def ssh_entry(value, sources, backend=None, run_system=None, listener_start=None, application=None,
              execution_context=None, sources_sha256=None):
    """Fixed SSH bootstrap entry; no shell/source fields come from the UI."""
    action = value.get("Action") if isinstance(value, dict) else "Unknown"
    proof = None
    def envelope(ok, data, message=None):
        result = {"Ok": ok, "Action": action, "Data": data}
        if message is not None:
            result["Message"] = message
        if proof is not None:
            result["OperationBinding"] = proof
        return result
    try:
        mg.schema(value, ("Action", "Input"))
        require(action in ("create", "status", "cancel"))
        if execution_context is not None:
            context = execution_context
            mg.schema(context, ("SchemaVersion", "OperationId", "Action", "InputDigest", "WireInput", "SourcesSHA256", "TargetDigest"))
            require(type(context["SchemaVersion"]) is int and context["SchemaVersion"] == 1 and context["Action"] == action
                    and isinstance(context["OperationId"], str) and re.fullmatch(r"[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}", context["OperationId"])
                    and uuid.UUID(context["OperationId"]).int != 0, "OnlineOperationBindingMismatch")
            require(all(isinstance(context[k], str) and re.fullmatch(r"[0-9a-f]{64}", context[k]) for k in ("InputDigest", "SourcesSHA256", "TargetDigest"))
                    and context["SourcesSHA256"] == sources_sha256 and isinstance(context["WireInput"], str)
                    and len(context["WireInput"].encode("utf-8")) <= MAX_BODY
                    and hashlib.sha256(context["WireInput"].encode("utf-8")).hexdigest() == context["InputDigest"]
                    and mg.strict_json(context["WireInput"].encode("utf-8")) == value["Input"], "OnlineOperationBindingMismatch")
            proof = {k: context[k] for k in ("OperationId", "Action", "InputDigest", "SourcesSHA256", "TargetDigest")}
        application = application or OnlinePairing(backend or tc.Backend())
        if action == "create":
            mg.schema(value["Input"], ("InviteId", "DeviceName", "ExpiresInSeconds", "ExpectedServerBinding", "ExpectedManagementFingerprint", "PublicHost", "Port"))
            creation = {k: value["Input"][k] for k in ("InviteId", "DeviceName", "ExpiresInSeconds", "ExpectedServerBinding", "ExpectedManagementFingerprint")}
            application.validate_create(creation)
            prepared = application.install({k: value["Input"][k] for k in ("ExpectedServerBinding", "ExpectedManagementFingerprint", "PublicHost", "Port")}, sources, run_system,
                                           valid_for_seconds=value["Input"]["ExpiresInSeconds"] + RETRY_SECONDS + 30)
            result = application.create(creation)
            result["Maintenance"] = prepared["Maintenance"]
            if application.active_until() > application.b.now():
                (listener_start or start_listener)(application)
                result["ListenerStatus"] = "Ready"
            else:
                result["ListenerStatus"] = "InactiveExpired"
        else:
            result = getattr(application, action)(value["Input"])
        return envelope(True, result)
    except (mg.ManagementError, tc.TCError) as exc:
        return envelope(False, {"Code": exc.code}, exc.message)
    except Exception:
        return envelope(False, {"Code": "OnlineOperationFailed"}, "Online pairing failed; private details were suppressed.")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("serve",))
    parser.parse_args()
    require(os.name == "posix" and os.geteuid() == 0, "OnlinePrivilegeRequired")
    os.umask(0o077)
    application = OnlinePairing(tc.Backend())
    config = application.config()
    application._identity({"ExpectedServerBinding": config["ServerBinding"], "ExpectedManagementFingerprint": config["ManagementFingerprint"]})
    for path in (CERT, TLS_KEY):
        application.b.fs.check(path)
    with PairingServer((config["ListenHost"], config["Port"]), application, CERT, TLS_KEY) as server:
        server.serve_until_expired()


if __name__ == "__main__":
    main()
