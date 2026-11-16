"""Online enrollment contracts with real OpenSSL/JWE/TLS and isolated fake kernel."""
import concurrent.futures
import copy
import datetime as dt
import hashlib
import hmac
import http.client
import json
import os
from pathlib import Path
import socket
import ssl
import stat
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

from cryptography.hazmat.primitives import hashes, serialization, padding as symmetric_padding
from cryptography.hazmat.primitives.asymmetric import padding
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography import x509
from cryptography.x509.oid import NameOID
from pairing_online_test_support import Fixture, mg, online, tc


def decrypt(ciphertext, private_pem):
    head, wrapped, iv, encrypted, tag = ciphertext.split(".")
    header = mg.strict_json(mg.unb64(head))
    assert header == {"alg": "RSA-OAEP-256", "enc": "A256CBC-HS512", "cty": "TC-Pairing-v1"}
    private = serialization.load_pem_private_key(private_pem.encode(), None)
    cek = private.decrypt(mg.unb64(wrapped), padding.OAEP(mgf=padding.MGF1(hashes.SHA256()), algorithm=hashes.SHA256(), label=None))
    aad = head.encode()
    expected = hmac.new(cek[:32], aad + mg.unb64(iv) + mg.unb64(encrypted) + struct.pack(">Q", len(aad) * 8), hashlib.sha512).digest()[:32]
    assert hmac.compare_digest(expected, mg.unb64(tag))
    decoder = Cipher(algorithms.AES(cek[32:]), modes.CBC(mg.unb64(iv))).decryptor()
    raw = decoder.update(mg.unb64(encrypted)) + decoder.finalize()
    unpad = symmetric_padding.PKCS7(128).unpadder()
    return (unpad.update(raw) + unpad.finalize()).decode()


class OnlineTests(unittest.TestCase):
    def setUp(self):
        self.f = Fixture()
        self.f.install()

    def assert_code(self, code, function, *args):
        with self.assertRaises((mg.ManagementError, tc.TCError)) as raised:
            function(*args)
        self.assertEqual(code, raised.exception.code)

    def test_install_identity_pinned_and_no_tunnel_restart(self):
        initial = self.f.backend.manager().signing()[0]
        running = copy.deepcopy(self.f.kernel.running)
        calls = len(self.f.kernel.calls)
        self.f.install()
        self.assertEqual(initial, self.f.backend.manager().signing()[0])
        self.assertEqual(running, self.f.kernel.running)
        self.assertTrue(all(c == ["wg", "pubkey"] for c in self.f.kernel.calls[calls:]))
        self.assertEqual(self.f.system_commands, [["systemctl", "daemon-reload"]] * 2)
        self.assertNotIn("[Install]", online.UNIT)
        self.assertNotIn("Restart=always", online.UNIT)

    def test_installed_runtime_imports_without_package_root_json(self):
        with tempfile.TemporaryDirectory(prefix="tc-online-runtime-") as directory:
            for name in online.SOURCES:
                Path(directory, name).write_text(self.f.fs.read(online.RUNTIME + "/" + name), encoding="utf-8")
            script = 'import sys,json; sys.path.insert(0,sys.argv[1]); import pairing_online as p; import connection_methods as c; print(json.dumps({"Methods":[m["Id"] for m in c.methods()],"Key":p.mg.PRIVATE_KEY,"Actions":list(p.SOURCES)}))'
            process = subprocess.run([sys.executable, "-I", "-B", "-c", script, directory], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15, check=False)
            self.assertEqual(process.returncode, 0, process.stderr.decode())
            result = json.loads(process.stdout)
            self.assertEqual(result["Methods"], ["Udp", "Tcp"])
            self.assertEqual(result["Key"], mg.PRIVATE_KEY)
            self.assertIn("connection_methods.py", result["Actions"])
            self.assertFalse(Path(directory, "ConnectionMethods.json").exists())

    def test_listener_runtime_leaves_no_bytecode_cache(self):
        # systemd runs "python3 -I runtime/pairing_online.py serve" without -B.
        # -I alone still cached the sibling modules, and the next install refused
        # the runtime as containing an unowned file (0.21.3 field failure).
        with tempfile.TemporaryDirectory(prefix="tc-online-runtime-") as directory:
            for name in online.SOURCES:
                Path(directory, name).write_text(self.f.fs.read(online.RUNTIME + "/" + name), encoding="utf-8")
            process = subprocess.run([sys.executable, "-I", str(Path(directory, "pairing_online.py")), "--help"],
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30, check=False, cwd=tempfile.gettempdir())
            self.assertEqual(process.returncode, 0, process.stderr.decode())
            self.assertEqual(sorted(os.listdir(directory)), sorted(online.SOURCES))

    def test_bytecode_cache_left_by_a_listener_no_longer_blocks_the_next_invitation(self):
        first, _ = self.f.create()
        self.f.clock.offset += dt.timedelta(seconds=600 + online.RETRY_SECONDS + 5)
        cache = self.f.listener_cache()
        result = self.f.install()
        self.assertTrue(result["Maintenance"]["BytecodeCacheRemoved"])
        self.assertNotIn(cache, self.f.fs.dirs)
        self.assertFalse(any(path.startswith(cache + "/") for path in self.f.fs.files))
        second, _ = self.f.create()
        self.assertNotEqual(first["InviteId"], second["InviteId"])
        self.assertTrue(second["InvitationCode"].startswith("TCI1."))
        self.assertFalse(self.f.install()["Maintenance"]["BytecodeCacheRemoved"])

    def test_unexpected_bytecode_cache_entry_still_refuses_and_keeps_the_cache(self):
        cache = self.f.listener_cache("management_support.cpython-311.pyc", "payload.cpython-311.pyc")
        before = copy.deepcopy(self.f.fs.files)
        self.assert_code("OnlineOwnershipMismatch", self.f.install)
        self.assertEqual(before, self.f.fs.files)
        self.assertIn(cache, self.f.fs.dirs)

    def test_bytecode_cache_removal_validates_every_entry_before_deleting(self):
        with tempfile.TemporaryDirectory(prefix="tc-online-cache-") as directory:
            cache = directory + "/__pycache__"
            os.mkdir(cache)
            names = ["management_support.cpython-311.pyc", "tradechannel_linux.cpython-311.pyc"]
            for name in names:
                Path(cache, name).write_bytes(b"\x00compiled")
            real = os.lstat

            def posix(path, linked=""):
                info = real(path)
                mode = (stat.S_IFDIR | 0o700) if stat.S_ISDIR(info.st_mode) else (stat.S_IFREG | 0o600)
                links = 2 if linked and path.endswith(linked) else 1
                return os.stat_result((mode, info.st_ino, info.st_dev, links, 0, 0, info.st_size, 0, 0, 0))

            checked = []
            fs = mock.Mock()
            fs.check.side_effect = checked.append
            with mock.patch.object(online.os, "lstat", side_effect=lambda path: posix(path, names[1])):
                with self.assertRaises((mg.ManagementError, tc.TCError)) as raised:
                    online.remove_bytecode_cache(fs, cache, names)
            self.assertEqual("OnlineOwnershipMismatch", raised.exception.code)
            self.assertEqual(sorted(os.listdir(cache)), names)
            with mock.patch.object(online.os, "lstat", side_effect=posix):
                online.remove_bytecode_cache(fs, cache, names)
            self.assertFalse(os.path.exists(cache))
            self.assertEqual(checked, [online.RUNTIME, online.RUNTIME])

    def test_windows_line_endings_in_sent_sources_allow_every_later_invitation(self):
        # Sources arrive as packaged, with CRLF in tradechannel_linux.py. Until
        # 0.21.6 they were stored and digested as sent but read back with LF, so
        # the next install found a changed runtime: every invitation after a
        # server's first was refused.
        f = Fixture()
        sources = f.windows_sources()
        first = f.create_over_ssh(sources)
        self.assertTrue(first["Ok"], first.get("Message"))
        second = f.create_over_ssh(sources)
        self.assertTrue(second["Ok"], second.get("Message"))
        self.assertFalse(second["Data"]["Maintenance"]["RuntimeUpdated"])
        for name in online.SOURCES:
            self.assertNotIn("\r", f.fs.read_exact(online.RUNTIME + "/" + name), name)

    def test_crlf_runtime_stored_by_earlier_clients_is_adopted_then_rewritten(self):
        # The field server: an earlier client stored CRLF sources with digests
        # over CRLF, and its listener left a bytecode cache beside them.
        f = Fixture()
        sources = f.windows_sources()
        with mock.patch.object(online, "universal_newlines", lambda text: text):  # What earlier clients did.
            self.assertTrue(f.create_over_ssh(sources)["Ok"])
        self.assertIn("\r\n", f.fs.read_exact(online.RUNTIME + "/pairing_online.py"))
        f.listener_cache()
        adopted = f.create_over_ssh(sources)
        self.assertTrue(adopted["Ok"], adopted.get("Message"))
        self.assertTrue(adopted["Data"]["Maintenance"]["RuntimeUpdated"])
        self.assertTrue(adopted["Data"]["Maintenance"]["BytecodeCacheRemoved"])
        # Same release here, so cas() leaves the CRLF file; the record still matches.
        again = f.create_over_ssh(sources)
        self.assertTrue(again["Ok"], again.get("Message"))
        self.assertFalse(again["Data"]["Maintenance"]["RuntimeUpdated"])

    def test_install_interrupted_under_an_earlier_client_still_recovers(self):
        f = Fixture()
        sources = f.windows_sources()
        f.fs.fail_path = online.UNIT_PATH  # The CRLF runtime is already written.
        with mock.patch.object(online, "universal_newlines", lambda text: text):
            self.assertEqual(f.create_over_ssh(sources)["Data"]["Code"], "DiskFailure")
        self.assertIsNotNone(f.fs.read(online.MAINTENANCE))
        self.assertIn("\r\n", f.fs.read_exact(online.RUNTIME + "/pairing_online.py"))
        recovered = f.create_over_ssh(sources)
        self.assertTrue(recovered["Ok"], recovered.get("Message"))
        self.assertTrue(recovered["Data"]["Maintenance"]["Recovered"])
        self.assertIsNone(f.fs.read(online.MAINTENANCE))
        self.assertTrue(f.create_over_ssh(sources)["Ok"])

    def test_state_read_turns_stored_crlf_into_lf_and_exact_read_keeps_it(self):
        # The SecureFS asymmetry the fixture's MemoryFS mirrors.
        with tempfile.TemporaryDirectory(prefix="tc-online-text-") as directory:
            path = os.path.join(directory, "pairing_online.py")
            Path(path).write_bytes(b"first\r\nsecond\rthird\n")
            fs = tc.SecureFS()
            # POSIX descriptors are binary; on Windows only O_BINARY keeps the CR.
            flags = getattr(os, "O_NOFOLLOW", 0) or os.O_BINARY
            with mock.patch.object(fs, "check"), mock.patch.object(os, "O_NOFOLLOW", flags, create=True):
                self.assertEqual("first\nsecond\nthird\n", fs.read(path))
                self.assertEqual("first\r\nsecond\rthird\n", fs.read_exact(path))

    def test_install_wrong_management_identity_never_replaces_key(self):
        before = copy.deepcopy(self.f.fs.files)
        wrong = dict(self.f.expected, ExpectedManagementFingerprint="SHA256:" + "A" * 43, PublicHost="127.0.0.1", Port=18443)
        self.assert_code("OnlineSigningIdentityChanged", self.f.application.install, wrong, self.f.sources)
        self.assertEqual(before, self.f.fs.files)

    def test_missing_original_signing_key_never_generated_or_replaced(self):
        self.f.fs.files.pop(mg.PRIVATE_KEY)
        before = copy.deepcopy(self.f.fs.files)
        self.assert_code("ManagementIdentityMissing", self.f.install)
        self.assertEqual(before, self.f.fs.files)

    def test_near_expiry_tls_certificate_blocks_new_invitation(self):
        original = self.f.crypto.run
        def fail_expiring(args, data=None):
            if args[:2] == ["x509", "-checkend"]:
                raise mg.ManagementError("SigningOperationFailed", "Fixture expired certificate")
            return original(args, data)
        before = copy.deepcopy(self.f.fs.files)
        with mock.patch.object(self.f.crypto, "run", side_effect=fail_expiring):
            self.assert_code("OnlineTlsCertificateExpired", self.f.create)
        self.assertEqual(before, self.f.fs.files)

    def test_owned_runtime_upgrade_without_invites_preserves_all_node_keys(self):
        before = copy.deepcopy(self.f.fs.files)
        changed = dict(self.f.sources)
        changed["pairing_online.py"] += "\n# simulated next owned release\n"
        result = self.f.application.install(dict(self.f.expected, PublicHost="127.0.0.1", Port=18443), changed,
                                            lambda command: self.f.system_commands.append(command))
        self.assertTrue(result["Maintenance"]["RuntimeUpdated"])
        self.assertFalse(result["Maintenance"]["CertificateRenewed"])
        self.assertIn(["systemctl", "stop", online.UNIT_NAME], self.f.system_commands)
        for path in (mg.PRIVATE_KEY, mg.PUBLIC_KEY, tc.MANIFEST, online.TOKEN_KEY, online.TLS_KEY, online.CERT):
            self.assertEqual(before[path], self.f.fs.read(path), path)
        self.assertEqual(self.f.fs.read_exact(online.RUNTIME + "/pairing_online.py"), changed["pairing_online.py"].replace("\r\n", "\n"))
        self.assertIsNone(self.f.fs.read(online.MAINTENANCE))
        invitation, _ = self.f.create()
        self.assertEqual(invitation["State"], "Open")

    def test_owned_unit_upgrade_is_recorded_and_tampered_unit_is_rejected(self):
        old = online.UNIT
        with mock.patch.object(online, "UNIT", old + "# next owned unit revision\n"):
            result = self.f.install()
        self.assertTrue(result["Maintenance"]["RuntimeUpdated"])
        self.f.fs.files[online.UNIT_PATH] += "# unowned edit\n"
        before = copy.deepcopy(self.f.fs.files)
        self.assert_code("OnlineOwnershipMismatch", self.f.install)
        self.assertEqual(before, self.f.fs.files)

    def test_active_and_consumed_retry_windows_defer_maintenance(self):
        invitation, _ = self.f.create(ExpiresInSeconds=60)
        changed = dict(self.f.sources)
        changed["pairing_online.py"] += "\n# next release\n"
        options = dict(self.f.expected, PublicHost="127.0.0.1", Port=18443)
        before = copy.deepcopy(self.f.fs.files)
        self.assert_code("OnlineMaintenanceDeferred", self.f.application.install, options, changed, lambda _: None)
        with mock.patch.object(self.f.application, "_certificate_usable", return_value=False):
            self.assert_code("OnlineMaintenanceDeferred", self.f.application.install, options, self.f.sources, lambda _: None)
        self.assertEqual(before, self.f.fs.files)
        pair, _ = self.f.pair(invitation)
        self.f.application.redeem(invitation["InviteId"], self.f.code(invitation)["k"], pair)
        self.f.clock.offset += dt.timedelta(seconds=61)
        self.assert_code("OnlineMaintenanceDeferred", self.f.application.install, options, changed, lambda _: None)
        self.f.clock.offset += dt.timedelta(seconds=121)
        result = self.f.application.install(options, changed, lambda _: None)
        self.assertTrue(result["Maintenance"]["RuntimeUpdated"])

    def test_expired_tls_renews_automatically_without_replacing_management_or_token_keys(self):
        private = serialization.load_pem_private_key(self.f.fs.read(online.TLS_KEY).encode(), None)
        subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "TradeChannel Online Pairing")])
        now = dt.datetime.now(dt.timezone.utc)
        expired = (x509.CertificateBuilder().subject_name(subject).issuer_name(subject).public_key(private.public_key())
                   .serial_number(x509.random_serial_number()).not_valid_before(now - dt.timedelta(days=800))
                   .not_valid_after(now - dt.timedelta(days=1)).sign(private, hashes.SHA256())).public_bytes(serialization.Encoding.PEM).decode()
        # Model an originally owned certificate reaching the end of its life;
        # update the fixture's old recorded hashes, not the production verifier.
        self.f.fs.files[online.CERT] = expired
        config = self.f.backend.read_json(online.CONFIG)
        config["TlsSha256"] = online.certificate_sha256(expired)
        self.f.fs.files[online.CONFIG] = self.f.backend.dumps(config)
        ownership = self.f.backend.read_json(online.OWNERSHIP)
        for path in (online.CERT, online.CONFIG):
            ownership["Hashes"][path] = hashlib.sha256(self.f.fs.read(path).encode()).hexdigest()
        self.f.fs.files[online.OWNERSHIP] = self.f.backend.dumps(ownership)
        before = copy.deepcopy(self.f.fs.files)
        result = self.f.install()
        self.assertTrue(result["Maintenance"]["CertificateRenewed"])
        self.assertNotEqual(result["TlsSha256"], config["TlsSha256"])
        for path in (mg.PRIVATE_KEY, mg.PUBLIC_KEY, tc.MANIFEST, online.TOKEN_KEY):
            self.assertEqual(before[path], self.f.fs.read(path), path)
        invitation, _ = self.f.create()
        self.assertEqual(self.f.code(invitation)["t"], result["TlsSha256"])
        body, message, signature = mg.decode_jws(self.f.application.fetch(invitation["InviteId"], self.f.code(invitation)["k"])["SignedDescriptor"])
        self.assertTrue(self.f.crypto.verify(self.f.backend.manager().signing()[1], message, signature))

    def test_runtime_tamper_and_unowned_overrides_block_automatic_upgrade(self):
        path = online.RUNTIME + "/management_support.py"
        installed = self.f.fs.files[path]
        self.f.fs.files[path] += "\n# tampered independently\n"
        before = copy.deepcopy(self.f.fs.files)
        self.assert_code("OnlineOwnershipMismatch", self.f.install)
        self.assertEqual(before, self.f.fs.files)
        self.f.fs.files[path] = installed
        self.f.fs.dirs.add(online.UNIT_PATH + ".d")
        self.assert_code("OnlineUnitConflict", self.f.install)

    def test_interrupted_owned_maintenance_recovers_before_create(self):
        changed = dict(self.f.sources)
        changed["management_support.py"] += "\n# next owned management source\n"
        options = dict(self.f.expected, PublicHost="127.0.0.1", Port=18443)
        keys = {path: self.f.fs.read(path) for path in (mg.PRIVATE_KEY, mg.PUBLIC_KEY, tc.MANIFEST, online.TOKEN_KEY)}
        self.f.fs.fail_path = online.RUNTIME + "/management_support.py"
        self.assert_code("DiskFailure", self.f.application.install, options, changed, lambda _: None)
        self.assertIsNotNone(self.f.fs.read(online.MAINTENANCE))
        restarted = online.OnlinePairing(self.f.backend, allow_loopback=True)
        recovered = restarted.install(options, changed, lambda _: None)
        self.assertTrue(recovered["Maintenance"]["Recovered"])
        self.assertIsNone(self.f.fs.read(online.MAINTENANCE))
        for path, original in keys.items():
            self.assertEqual(original, self.f.fs.read(path))
        self.f.application = restarted
        self.assertEqual(self.f.create()[0]["State"], "Open")

    def test_interrupted_certificate_renewal_recovers_as_one_pinned_pair(self):
        before = {path: self.f.fs.read(path) for path in (mg.PRIVATE_KEY, mg.PUBLIC_KEY, tc.MANIFEST, online.TOKEN_KEY)}
        old_pin = self.f.application.config()["TlsSha256"]
        self.f.fs.fail_path = online.TLS_KEY
        with mock.patch.object(self.f.application, "_certificate_usable", return_value=False):
            self.assert_code("DiskFailure", self.f.install)
        self.assertIsNotNone(self.f.fs.read(online.MAINTENANCE))
        self.f.application = online.OnlinePairing(self.f.backend, allow_loopback=True)
        result = self.f.install()
        self.assertTrue(result["Maintenance"]["Recovered"])
        self.assertNotEqual(old_pin, result["TlsSha256"])
        self.f.application._verify_owned_installation(self.f.application.config())
        for path, value in before.items():
            self.assertEqual(value, self.f.fs.read(path))
        invitation, _ = self.f.create()
        self.assertEqual(self.f.code(invitation)["t"], result["TlsSha256"])

    def test_invalid_create_cannot_trigger_install_or_certificate_maintenance(self):
        before = copy.deepcopy(self.f.fs.files)
        value = dict(self.f.expected, InviteId="61616161-2222-4333-8444-555555555555", DeviceName="New PC", ExpiresInSeconds=0, PublicHost="127.0.0.1", Port=18443)
        with mock.patch.object(self.f.application, "install", side_effect=AssertionError("invalid creation must not install")):
            result = online.ssh_entry({"Action": "create", "Input": value}, self.f.sources, application=self.f.application)
        self.assertFalse(result["Ok"])
        self.assertEqual(result["Data"]["Code"], "InvalidOnlineInput")
        self.assertEqual(before, self.f.fs.files)

    def test_maintenance_journal_cannot_write_management_keys(self):
        changed = dict(self.f.sources)
        changed["management_support.py"] += "\n# retry test\n"
        self.f.fs.fail_path = online.RUNTIME + "/management_support.py"
        self.assert_code("DiskFailure", self.f.application.install, dict(self.f.expected, PublicHost="127.0.0.1", Port=18443), changed, lambda _: None)
        journal = self.f.backend.read_json(online.MAINTENANCE)
        private = self.f.fs.read(mg.PRIVATE_KEY)
        journal["Files"][mg.PRIVATE_KEY] = {"Before": private, "After": "forbidden"}
        self.f.fs.files[online.MAINTENANCE] = self.f.backend.dumps(journal)
        self.assert_code("OnlineMaintenanceInvalid", self.f.install)
        self.assertEqual(private, self.f.fs.read(mg.PRIVATE_KEY))

    def test_ssh_execution_context_binds_business_input_and_response(self):
        value = dict(self.f.expected, InviteId="61616161-2222-4333-8444-555555555555", DeviceName="New PC", ExpiresInSeconds=600, PublicHost="127.0.0.1", Port=18443)
        wire = mg.compact(value)
        source_hash = hashlib.sha256(mg.compact(self.f.sources).encode()).hexdigest()
        context = dict(SchemaVersion=1, OperationId="62626262-2222-4333-8444-555555555555", Action="create", InputDigest=hashlib.sha256(wire.encode()).hexdigest(),
                       WireInput=wire, SourcesSHA256=source_hash, TargetDigest="a" * 64)
        changed = dict(value, DeviceName="Changed")
        rejected = online.ssh_entry({"Action": "create", "Input": changed}, self.f.sources, application=self.f.application, run_system=lambda _: None,
                                    listener_start=lambda _: None, execution_context=context, sources_sha256=source_hash)
        self.assertFalse(rejected["Ok"])
        self.assertEqual(rejected["Data"]["Code"], "OnlineOperationBindingMismatch")
        self.assertEqual(len(self.f.backend.read_json(mg.STATE)["Invites"]), 0)
        result = online.ssh_entry({"Action": "create", "Input": value}, self.f.sources, application=self.f.application, run_system=lambda _: None,
                                 listener_start=lambda _: None, execution_context=context, sources_sha256=source_hash)
        self.assertTrue(result["Ok"], result)
        self.assertEqual(result["OperationBinding"]["OperationId"], context["OperationId"])
        self.assertEqual(result["OperationBinding"]["InputDigest"], context["InputDigest"])

    def test_creation_retries_are_stable_and_secret_is_not_persisted(self):
        invite, value = self.f.create()
        again = self.f.application.create(value)
        self.assertEqual(invite["InvitationCode"], again["InvitationCode"])
        self.assertEqual(invite["ExpiresAtUtc"], again["ExpiresAtUtc"])
        code = self.f.code(invite)
        self.assertEqual(len(mg.unb64(code["k"])), 32)
        self.assertFalse(any(code["k"] in text for text in self.f.fs.files.values()))
        self.assert_code("InviteIdConflict", self.f.application.create, dict(value, DeviceName="Changed"))
        # Restarted application reconstructs the exact code without storing a bearer.
        self.f.application = online.OnlinePairing(self.f.backend, allow_loopback=True)
        self.assertEqual(invite["InvitationCode"], self.f.application.create(value)["InvitationCode"])

    def test_short_expiry_is_also_in_offline_signature(self):
        invite, value = self.f.create(ExpiresInSeconds=60)
        code = self.f.code(invite)
        descriptor = self.f.application.fetch(invite["InviteId"], code["k"])
        body, message, signature = mg.decode_jws(descriptor["SignedDescriptor"])
        self.assertTrue(self.f.crypto.verify(self.f.backend.manager().signing()[1], message, signature))
        offline, _, _ = mg.decode_jws(body["Invite"])
        self.assertEqual(offline["ExpiresAtUtc"], invite["ExpiresAtUtc"])
        pair, _ = self.f.pair(invite)
        self.f.clock.offset += dt.timedelta(seconds=61)
        self.assert_code("OnlineInviteExpired", self.f.application.redeem, invite["InviteId"], code["k"], pair)
        self.assert_code("InviteUnavailable", self.f.backend.execute, "authorize_external", dict(InviteId=invite["InviteId"], **pair))
        self.assertEqual(self.f.count(), 1)

    def test_lifetime_bounds_accept_a_full_day_and_reject_its_neighbours(self):
        """0.22.0 A1: the operator chooses the lifetime, so 1800 is no ceiling."""
        value = dict(self.f.expected, InviteId="61616161-2222-4333-8444-555555555555", DeviceName="New PC")
        self.assertEqual(86400, online.MAX_LIFETIME)
        self.assertEqual(120, online.RETRY_SECONDS)
        for seconds in (60, 1800, online.MAX_LIFETIME):
            self.f.application.validate_create(dict(value, ExpiresInSeconds=seconds))
        for seconds in (59, 86401, 0):
            self.assert_code("InvalidOnlineInput", self.f.application.validate_create,
                             dict(value, ExpiresInSeconds=seconds))

    def test_full_day_invitation_keeps_the_receiver_until_its_deadline(self):
        invitation, _ = self.f.create(ExpiresInSeconds=online.MAX_LIFETIME)
        stored = self.f.backend.read_json(mg.STATE)["Invites"][invitation["InviteId"]]
        expires = self.f.application.m.time(stored["ExpiresAtUtc"])
        retry = self.f.application.m.time(stored["Online"]["RetryUntilUtc"])
        self.assertAlmostEqual(86400, (expires - self.f.clock()).total_seconds(), delta=1)
        # Only the invitation grew; the response retry window stays 120 seconds.
        self.assertEqual(dt.timedelta(seconds=online.RETRY_SECONDS), retry - expires)
        self.assertEqual(expires, self.f.application._active_deadline())
        self.assertEqual(expires, self.f.application.active_until())
        self.f.clock.offset += dt.timedelta(seconds=43200)
        self.assertEqual(expires, self.f.application.active_until())
        # A used invitation keeps the receiver only for its retry window.
        pair, _ = self.f.pair(invitation)
        self.f.application.redeem(invitation["InviteId"], self.f.code(invitation)["k"], pair)
        self.assertEqual(retry, self.f.application.active_until())

    def test_full_day_invitation_needs_a_certificate_that_covers_it(self):
        """A certificate with 12 hours left cannot cover 24 hours, and an active
        invitation defers both the renewal and the listener update."""
        started = []
        payload = dict(self.f.expected, InviteId="61616161-2222-4333-8444-555555555555", DeviceName="New PC",
                       ExpiresInSeconds=online.MAX_LIFETIME, PublicHost="127.0.0.1", Port=18443)
        creation = {key: payload[key] for key in ("InviteId", "DeviceName", "ExpiresInSeconds",
                                                 "ExpectedServerBinding", "ExpectedManagementFingerprint")}
        real = self.f.crypto.run

        def twelve_hours(args, data=None):
            if args[:2] == ["x509", "-checkend"] and int(args[2]) > 12 * 3600:
                raise mg.ManagementError("SigningOperationFailed", "Fixture certificate expires within twelve hours")
            return real(args, data)

        first = online.ssh_entry({"Action": "create", "Input": dict(payload, ExpiresInSeconds=600)}, self.f.sources,
                                 application=self.f.application, run_system=self.f.system_commands.append,
                                 listener_start=started.append)
        self.assertTrue(first["Ok"], first)
        before = copy.deepcopy(self.f.fs.files)
        with mock.patch.object(self.f.crypto, "run", side_effect=twelve_hours):
            self.assert_code("OnlineTlsCertificateExpired", self.f.application.create, creation)
            deferred = online.ssh_entry({"Action": "create", "Input": payload}, self.f.sources,
                                        application=self.f.application, run_system=lambda _: None,
                                        listener_start=started.append)
        self.assertFalse(deferred["Ok"])
        self.assertEqual("OnlineMaintenanceDeferred", deferred["Data"]["Code"])
        self.assertEqual(before, self.f.fs.files)

    def test_repeat_create_returns_the_same_invitation_and_starts_the_receiver(self):
        """Restart=no means a restarted server needs the same input run again."""
        started = []
        payload = dict(self.f.expected, InviteId="61616161-2222-4333-8444-555555555555", DeviceName="New PC",
                       ExpiresInSeconds=online.MAX_LIFETIME, PublicHost="127.0.0.1", Port=18443)
        first = online.ssh_entry({"Action": "create", "Input": payload}, self.f.sources,
                                 application=self.f.application, run_system=self.f.system_commands.append,
                                 listener_start=started.append)
        self.assertTrue(first["Ok"], first)
        self.assertEqual("Ready", first["Data"]["ListenerStatus"])
        second = online.ssh_entry({"Action": "create", "Input": payload}, self.f.sources,
                                  application=self.f.application, run_system=self.f.system_commands.append,
                                  listener_start=started.append)
        self.assertTrue(second["Ok"], second)
        self.assertEqual(first["Data"]["InvitationCode"], second["Data"]["InvitationCode"])
        self.assertEqual(first["Data"]["ExpiresAtUtc"], second["Data"]["ExpiresAtUtc"])
        self.assertEqual(1, len(self.f.backend.read_json(mg.STATE)["Invites"]))
        self.assertEqual(2, len(started))

    def test_valid_authorization_jwe_retries_and_two_protocols(self):
        invite, _ = self.f.create()
        code = self.f.code(invite)
        pair, request = self.f.pair(invite)
        first = self.f.application.redeem(invite["InviteId"], code["k"], pair)
        second = self.f.application.redeem(invite["InviteId"], code["k"], pair)
        plain = decrypt(first["EncryptedAuthorization"], self.f.crypto.generate()[0])
        self.assertEqual(plain, decrypt(second["EncryptedAuthorization"], self.f.crypto.generate()[0]))
        body, message, signature = mg.decode_jws(plain)
        self.assertTrue(self.f.crypto.verify(self.f.backend.manager().signing()[1], message, signature))
        self.assertEqual(body["DeviceId"], request["ClientRequest"]["DeviceId"])
        self.assertEqual(body["ClientResponse"]["Transport"]["Port"], 443)
        self.assertEqual(body["ClientResponse"]["MTU"], 1380)
        self.assertNotIn("Authorization", first)
        self.assertNotIn("ClientResponse", first)
        self.assertEqual(self.f.count(), 2)

    def test_atomic_competing_devices_only_one_wins(self):
        invite, _ = self.f.create()
        code = self.f.code(invite)
        pairs = [self.f.pair(invite, number=n)[0] for n in (2, 3)]
        gate = threading.Barrier(2)
        def consume(pair):
            gate.wait(timeout=5)
            try:
                return self.f.application.redeem(invite["InviteId"], code["k"], pair)["Status"]
            except (mg.ManagementError, tc.TCError) as error:
                return error.code
        with concurrent.futures.ThreadPoolExecutor(2) as pool:
            result = list(pool.map(consume, pairs))
        self.assertCountEqual(result, ["Authorized", "InviteConsumed"])
        self.assertEqual(self.f.count(), 2)

    def test_lost_response_retry_survives_restart_and_expiry_grace(self):
        invite, _ = self.f.create(ExpiresInSeconds=60)
        pair, _ = self.f.pair(invite)
        token = self.f.code(invite)["k"]
        self.f.application.redeem(invite["InviteId"], token, pair)  # Reply intentionally discarded.
        self.f.application = online.OnlinePairing(self.f.backend, allow_loopback=True)
        self.f.clock.offset += dt.timedelta(seconds=70)
        self.assertEqual(self.f.application.fetch(invite["InviteId"], token)["Status"], "RetryOnly")
        self.assertEqual(self.f.application.redeem(invite["InviteId"], token, pair)["Status"], "Authorized")
        self.assertEqual(self.f.count(), 2)
        self.f.clock.offset += dt.timedelta(seconds=111)
        self.assert_code("OnlineInviteExpired", self.f.application.redeem, invite["InviteId"], token, pair)

    def test_wrong_token_and_tampered_signed_request_never_consume(self):
        invite, _ = self.f.create()
        pair, _ = self.f.pair(invite)
        token = self.f.code(invite)["k"]
        self.assert_code("InviteAuthenticationFailed", self.f.application.redeem, invite["InviteId"], "A" * 43, pair)
        parts = pair["PairRequest"].split(".")
        signature = bytearray(mg.unb64(parts[2])); signature[0] ^= 1
        parts[2] = mg.b64(signature)
        self.assert_code("InvalidSignature", self.f.application.redeem, invite["InviteId"], token, {"PairRequest": ".".join(parts)})
        self.assertEqual(self.f.count(), 1)
        self.assertEqual(self.f.backend.execute("invite_status", {"InviteId": invite["InviteId"]})["State"], "Open")

    def test_cancelled_and_revoked_cannot_issue_authorization(self):
        invite, _ = self.f.create()
        pair, _ = self.f.pair(invite)
        self.f.application.cancel(dict(self.f.expected, InviteId=invite["InviteId"]))
        self.assert_code("InviteUnavailable", self.f.application.redeem, invite["InviteId"], self.f.code(invite)["k"], pair)
        other, _ = self.f.create()
        pair, request = self.f.pair(other)
        self.f.application.redeem(other["InviteId"], self.f.code(other)["k"], pair)
        self.f.backend.execute("revoke", {"DeviceId": request["ClientRequest"]["DeviceId"]})
        self.assert_code("OnlineAuthorizationUnavailable", self.f.application.redeem, other["InviteId"], self.f.code(other)["k"], pair)

    def test_peer_journal_failure_blocks_second_claim_until_recovery(self):
        invite, _ = self.f.create()
        pair, _ = self.f.pair(invite)
        token = self.f.code(invite)["k"]
        self.f.fs.fail_path = mg.STATE
        try:
            self.f.application.redeem(invite["InviteId"], token, pair)
        except (tc.TCError, mg.ManagementError):
            pass
        active = self.f.backend.read_json(tc.ACTIVE)
        if active:
            with self.assertRaises((mg.ManagementError, tc.TCError)):
                self.f.application.redeem(invite["InviteId"], token, pair)
            self.f.backend.execute("recover", {})
        result = self.f.application.redeem(invite["InviteId"], token, pair)
        self.assertEqual(result["Status"], "Authorized")
        self.assertEqual(self.f.count(), 2)

    def test_rate_limit_persists_restart_bounds_sources_and_resets(self):
        rate = online.RateLimiter(self.f.backend, per_ip=2, total=3)
        self.assertTrue(rate.allow("127.0.0.1"))
        self.assertTrue(rate.allow("127.0.0.1"))
        rate = online.RateLimiter(self.f.backend, per_ip=2, total=3)
        self.assertFalse(rate.allow("127.0.0.1"))
        self.assertTrue(rate.allow("127.0.0.2"))
        self.assertFalse(rate.allow("127.0.0.3"))
        self.assertEqual(len(self.f.backend.read_json(online.RATE)["Sources"]), 2)
        self.f.clock.offset += dt.timedelta(seconds=61)
        self.assertTrue(rate.allow("127.0.0.1"))

    def test_identity_drift_rejected_before_authorize(self):
        invite, _ = self.f.create()
        before = self.f.count()
        self.f.fs.files[mg.PUBLIC_KEY] = self.f.backend.dumps({"kty": "RSA", "n": "A" * 512, "e": "AQAB"})
        with self.assertRaises((tc.TCError, mg.ManagementError)):
            self.f.application.fetch(invite["InviteId"], self.f.code(invite)["k"])
        self.assertEqual(before, self.f.count())

    def test_ssh_entry_installs_creates_and_retries_real_core(self):
        payload = dict(self.f.expected, InviteId="61616161-2222-4333-8444-555555555555", DeviceName="New PC", ExpiresInSeconds=600, PublicHost="127.0.0.1", Port=18443)
        started = []
        for _ in range(2):
            result = online.ssh_entry({"Action": "create", "Input": payload}, self.f.sources, application=self.f.application,
                                      run_system=lambda command: self.f.system_commands.append(command), listener_start=lambda app: started.append(True))
            self.assertTrue(result["Ok"], result)
        self.assertEqual(len(started), 2)
        self.assertEqual(len(self.f.backend.read_json(mg.STATE)["Invites"]), 1)


class HttpTests(unittest.TestCase):
    def setUp(self):
        self.f = Fixture()
        self.temp = tempfile.TemporaryDirectory(prefix="tc-online-http-")
        root = Path(self.temp.name)
        (root / "key.pem").write_text(Fixture.certificate[0], encoding="ascii")
        (root / "cert.pem").write_text(Fixture.certificate[1], encoding="ascii")
        self.server = online.PairingServer(("127.0.0.1", 0), self.f.application, str(root / "cert.pem"), str(root / "key.pem"))
        self.port = self.server.server_address[1]
        self.f.install(self.port)
        self.invite, _ = self.f.create()
        self.code = self.f.code(self.invite)
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.05})
        self.thread.start()

    def tearDown(self):
        self.server.shutdown(); self.server.server_close(); self.thread.join(timeout=10)
        self.temp.cleanup()

    def request(self, method="GET", suffix="", token=None, body=None):
        context = ssl._create_unverified_context()
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        connection = http.client.HTTPSConnection("127.0.0.1", self.port, context=context, timeout=8)
        connection.connect()
        self.assertEqual(hashlib.sha256(connection.sock.getpeercert(binary_form=True)).hexdigest(), self.code["t"])
        headers = {"Authorization": "Bearer " + (token or self.code["k"]), "Content-Type": "application/json"}
        connection.request(method, "/v1/invitations/" + self.invite["InviteId"] + suffix, body=body, headers=headers)
        response = connection.getresponse()
        result = response.status, json.loads(response.read())
        connection.close()
        return result

    def test_real_tls_fetch_and_post_encrypted_grant(self):
        status, result = self.request()
        self.assertEqual(status, 200)
        self.assertEqual(result["Data"]["Status"], "InvitationReady")
        pair, _ = self.f.pair(self.invite)
        status, result = self.request("POST", "/consume", body=json.dumps(pair))
        self.assertEqual(status, 200, result)
        self.assertEqual(result["Data"]["EncryptedAuthorization"].count("."), 4)
        self.assertEqual(self.f.count(), 2)

    def test_http_does_not_expose_invitation_or_accept_plaintext(self):
        status, result = self.request(token="A" * 43)
        self.assertEqual((status, result["Code"]), (401, "InviteAuthenticationFailed"))
        with socket.create_connection(("127.0.0.1", self.port), timeout=3) as stream:
            stream.sendall(b"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
            try:
                self.assertFalse(stream.recv(1024).startswith(b"HTTP"))
            except ConnectionResetError:
                pass
        self.assertEqual(self.f.count(), 1)

    def test_duplicate_json_and_wrong_paths_rejected(self):
        status, result = self.request("POST", "/consume", body='{"PairRequest":"x","PairRequest":"y"}')
        self.assertEqual(result["Code"], "InvalidJson")
        status, result = self.request(suffix="?token=unsupported")
        self.assertEqual(result["Code"], "InvalidOnlineHttp")
        self.assertEqual(self.f.count(), 1)

    def test_no_invites_extend_service_past_retry_deadline(self):
        self.server.shutdown(); self.thread.join(timeout=5)
        self.f.clock.offset += dt.timedelta(seconds=721)
        before = time.monotonic()
        self.server.serve_until_expired()
        self.assertLess(time.monotonic() - before, 1)

    def test_unused_invitation_stops_at_expiry_without_extra_retry_window(self):
        self.server.shutdown(); self.thread.join(timeout=5)
        self.f.clock.offset += dt.timedelta(seconds=601)
        self.assertLessEqual(self.f.application.active_until(), self.f.clock())
        before = time.monotonic()
        self.server.serve_until_expired()
        self.assertLess(time.monotonic() - before, 1)


if __name__ == "__main__":
    unittest.main()
