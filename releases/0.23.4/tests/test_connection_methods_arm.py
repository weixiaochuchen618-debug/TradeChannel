"""Offline X1/X2 contracts and ARM installer tests; never execute a Linux binary.

Backend tests use the existing fake kernel. Installer tests use only a disposable
temporary directory behind a path-restricting POSIX adapter and mocked downloads.
Fixture digests are deliberate; official release pins are checked separately.
"""
import contextlib
import copy
import hashlib
import io
import json
import os
from pathlib import Path
import stat
import struct
import tarfile
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

from test_tcp_backend import TcpOS, base, tc

cm = tc.connection_methods
tcp = tc.tcp_support


def elf(machine, payload=b"fixture", library=False):
    header = bytearray(64)
    header[:7] = b"\x7fELF\x02\x01\x01"
    struct.pack_into("<HHI", header, 16, 3 if library else 2, machine, 1)
    return bytes(header) + payload


def archive_fixture(architecture="arm64", machine=183, layout=None, symlink=False, duplicate=False):
    binary = elf(machine, b"sing-box fixture")
    library = elf(machine, b"cronet fixture", library=True)
    buffer = io.BytesIO()
    prefix = layout or "sing-box-1.14.2-linux-" + architecture
    with tarfile.open(fileobj=buffer, mode="w:gz") as archive:
        for leaf, value in (("sing-box", binary), ("libcronet.so", library)):
            member = tarfile.TarInfo(prefix + "/" + leaf)
            member.size = len(value)
            if symlink and leaf == "libcronet.so":
                member.type = tarfile.SYMTYPE
                member.linkname = "../../foreign"
                member.size = 0
            archive.addfile(member, io.BytesIO(value))
            if duplicate and leaf == "sing-box":
                archive.addfile(member, io.BytesIO(value))
    raw = buffer.getvalue()
    return raw, {
        "ArchiveSHA256": hashlib.sha256(raw).hexdigest(),
        "BinarySHA256": hashlib.sha256(binary).hexdigest(),
        "LibrarySHA256": hashlib.sha256(library).hexdigest(),
    }


class SandboxPosix:
    """Real file bytes, mocked POSIX metadata; all writes must stay under root."""
    name = "posix"
    O_NOFOLLOW = 0x40000000
    O_WRONLY, O_RDONLY, O_CREAT, O_EXCL = os.O_WRONLY, os.O_RDONLY, os.O_CREAT, os.O_EXCL

    def __init__(self, root):
        self.root = Path(root).resolve()
        self.modes = {}
        self.overrides = {}
        self.descriptors = {}
        self.writes = []
        self.path = SimpleNamespace(exists=self.exists, lexists=self.lexists)

    def local(self, path):
        resolved = Path(path).resolve()
        if resolved != self.root and self.root not in resolved.parents:
            raise AssertionError("The installer attempted to access outside its disposable root.")
        return resolved

    def exists(self, path):
        return True if path in ("/usr", "/usr/lib") else self.local(path).exists()

    def lexists(self, path):
        return os.path.lexists(self.local(path))

    @staticmethod
    def geteuid():
        return 0

    def mkdir(self, path, mode):
        self.local(path).mkdir()
        self.modes[str(path)] = stat.S_IFDIR | mode

    def lstat(self, path):
        if path in ("/usr", "/usr/lib"):
            return SimpleNamespace(st_mode=stat.S_IFDIR | 0o755, st_uid=0)
        value = self.local(path).stat()
        result = dict(st_dev=value.st_dev, st_ino=value.st_ino, st_uid=0, st_nlink=value.st_nlink,
                      st_size=value.st_size, st_mode=self.modes.get(str(path), stat.S_IFREG | 0o644))
        result.update(self.overrides.get(str(path), {}))
        return SimpleNamespace(**result)

    def open(self, path, flags, mode=0o777):
        local = self.local(path)
        if not flags & self.O_NOFOLLOW:
            raise AssertionError("Component opens must retain no-follow semantics.")
        if flags & self.O_CREAT:
            if not flags & self.O_EXCL:
                raise AssertionError("Component creation must be exclusive.")
            self.writes.append(str(path))
        descriptor = os.open(local, flags & ~self.O_NOFOLLOW, mode)
        self.descriptors[descriptor] = str(path)
        if flags & self.O_CREAT:
            self.modes[str(path)] = stat.S_IFREG | mode
        return descriptor

    def fstat(self, descriptor):
        return self.lstat(self.descriptors[descriptor])

    @staticmethod
    def fdopen(descriptor, *args, **kwargs):
        if args and 'b' not in args[0]:
            kwargs.setdefault('newline', '\n')
        return os.fdopen(descriptor, *args, **kwargs)

    @staticmethod
    def fsync(descriptor):
        return os.fsync(descriptor)


class RegistryTests(unittest.TestCase):
    def test_declarations_cover_real_handlers_and_keep_legacy_ids(self):
        self.assertEqual([row["Id"] for row in cm.methods()], ["Udp", "Tcp"])
        self.assertEqual(cm.method("Tcp", tc.require)["Deployment"]["AddApply"]["Action"], "transport_apply")
        for row in cm.methods():
            self.assertEqual(row["Probe"]["ProfileId"], row["Id"])
            self.assertFalse(row["Probe"]["ChangesActiveConnection"])
        changed = cm.methods()
        changed[0]["Id"] = "Changed"
        self.assertEqual(cm.methods()[0]["Id"], "Udp")

    def test_declaration_rejects_unknown_handler_remap_duplicate_and_architecture(self):
        for change in (
            lambda value: value["Methods"][0]["LinuxHandlers"].update(ConfigureServer="eval"),
            lambda value: value["Methods"][0]["Deployment"]["Inspect"].update(Action="uninstall"),
            lambda value: value["Methods"][0]["Handlers"].update(ConfigureClient="wireguard-reality-v1"),
            lambda value: value["Methods"][0].update(Id="Tcp"),
            lambda value: value["Architectures"][1].update(ElfMachine=62),
        ):
            declaration = cm.declaration()
            change(declaration)
            with self.assertRaises(ValueError):
                cm.validate_declaration(declaration)
        with self.assertRaises(ValueError):
            json.loads('{"Id":"Udp","Id":"Tcp"}', object_pairs_hook=cm._unique_object)

    def test_aliases_and_unsupported_architectures(self):
        for supplied, expected in (("x86_64", "amd64"), ("AMD64", "amd64"), ("arm64", "arm64"), ("aarch64", "arm64")):
            with self.subTest(supplied=supplied):
                self.assertEqual(cm.architecture(supplied, tc.require)["Id"], expected)
        for unsupported in ("armv7l", "i686", "ppc64le", "aarch64_be", "", None):
            with self.subTest(unsupported=unsupported), self.assertRaises(tc.TCError) as caught:
                cm.architecture(unsupported, tc.require)
            self.assertEqual(caught.exception.code, "UnsupportedArchitecture")

    def test_dispatch_preserves_approval_input_and_rejects_unregistered_operations(self):
        backend = mock.Mock()
        backend.execute.return_value = {"Status": "fixture"}
        value = {"PlanId": "00000000-0000-4000-8000-000000000001", "ApprovedChangeDigest": "a" * 64}
        self.assertEqual(cm.dispatch(backend, "Tcp", "AddApply", value, tc.require), {"Status": "fixture"})
        backend.execute.assert_called_once_with("transport_apply", value)
        backend.reset_mock()
        for method, phase, inputs in (("Udp", "AddApply", value), ("Tcp", "uninstall", {}),
                                      ("Auto", "Inspect", {}), ("Udp", "Inspect", {"Action": "apply"}),
                                      ("Tcp", "AddPlan", {"Transport": {"Type": "unknown", "Port": 443, "ServerName": "www.bing.com"}})):
            with self.subTest(method=method, phase=phase), self.assertRaises(tc.TCError):
                cm.dispatch(backend, method, phase, inputs, tc.require)
        backend.execute.assert_not_called()

    def test_server_probe_contract_matches_actual_backend_input(self):
        value = {"NetworkProbe": True, "ProbeRepeats": 1, "CaptureSeconds": 10, "ProbeRelayPort": 443, "ProbeSourceIPv4": "198.51.100.4"}
        request = cm.deployment_request("Udp", "Probe", value, tc.require)
        self.assertEqual(request["Operation"], "status")
        self.assertEqual(request["Input"], value)
        self.assertFalse(request["Mutates"])

    def test_arm_official_pins_keep_existing_version_and_amd64_receipt(self):
        amd64 = tcp.component_release(tc.require, "x86_64")
        arm64 = tcp.component_release(tc.require, "aarch64")
        self.assertEqual(amd64["Version"], "1.14.2")
        self.assertEqual(arm64["Version"], "1.14.2")
        self.assertTrue(amd64["ArchiveURL"].endswith("sing-box-1.14.2-linux-amd64.tar.gz"))
        self.assertTrue(arm64["ArchiveURL"].endswith("sing-box-1.14.2-linux-arm64.tar.gz"))
        self.assertEqual(amd64["ArchiveSHA256"], "a684484d7477d1437282ee411f4d131d0340aaad60a7868841ebd5d87dd8a0c6")
        self.assertEqual(arm64["ArchiveSHA256"], "b43a1fb1bda131c6653576741ce527eb2bdeab7c9308ca90ee8b972abb7e4a7f")
        self.assertEqual(tcp._receipt(amd64), "|".join((tcp.ARCHIVE_SHA256, tcp.BINARY_SHA256, tcp.LIBRARY_SHA256)))
        self.assertEqual(tcp.BINARY, "/usr/lib/tradechannel/1.14.2/sing-box")


class ArmBackendTests(unittest.TestCase):
    def fixture(self, architecture="aarch64", os_id="ubuntu", version="24.04"):
        fs = base.MemoryFS()
        kernel = TcpOS(fs)
        kernel.env["OS"] = {"Id": os_id, "Version": version, "Architecture": architecture}
        backend = tc.Backend(fs, kernel, now=lambda: base.dt.datetime(2026, 10, 16, tzinfo=base.dt.timezone.utc))
        return backend, fs, kernel

    def test_arm_and_amd64_aliases_complete_both_configuration_paths(self):
        for architecture in ("aarch64", "arm64", "x86_64", "amd64"):
            for os_id, version in (("ubuntu", "24.04"), ("debian", "13")):
                for method in ("Udp", "Tcp"):
                    with self.subTest(architecture=architecture, os=os_id, method=method):
                        backend, fs, kernel = self.fixture(architecture, os_id, version)
                        self.assertTrue(backend.inspect({})["Supported"])
                        self.assertFalse(fs.mutations)
                        value = base.plan_input()
                        if method == "Tcp":
                            value["Transport"] = {"Type": "tcp-reality", "Port": 443, "ServerName": "www.bing.com"}
                        plan = cm.dispatch(backend, method, "Plan", value, tc.require)
                        applied = cm.dispatch(backend, method, "Apply", {"PlanId": plan["PlanId"]}, tc.require)
                        self.assertEqual(applied["Status"], "Applied")
                        self.assertEqual(cm.dispatch(backend, method, "Probe", {}, tc.require)["Status"], "Applied")
                        stored = backend.load_plan(plan["PlanId"], kernel.probe())
                        backend.verify(stored, backend.read_json(tc.MANIFEST))
                        config = fs.files[tc.paths(stored)["Config"]]
                        self.assertIn("MTU = 1380\nTable = off", config)
                        self.assertNotIn("PrivateKey", json.dumps(applied["ClientResponse"]))
                        if method == "Tcp":
                            transport = json.loads(fs.files[tc.paths(stored)["TransportConfig"]])
                            self.assertEqual(transport["route"]["rules"][0]["port"], [51820])
                            self.assertIn("/usr/lib/tradechannel/1.14.2/sing-box", fs.files[tc.paths(stored)["TransportService"]])

    def test_arm_incremental_tcp_keeps_existing_wireguard_and_peer_identity(self):
        backend, fs, kernel = self.fixture()
        preview = backend.plan(base.plan_input())
        backend.apply({"PlanId": preview["PlanId"]})
        old = backend.read_json(tc.MANIFEST)
        plan = backend.load_plan(old["PlanId"], kernel.probe())
        config = fs.files[tc.paths(plan)["Config"]]
        start = len(kernel.calls)
        addition = cm.dispatch(backend, "Tcp", "AddPlan", {"Transport": {"Type": "tcp-reality", "Port": 8443, "ServerName": "www.bing.com"}}, tc.require)
        result = cm.dispatch(backend, "Tcp", "AddApply", {"PlanId": addition["PlanId"], "ApprovedChangeDigest": addition["ChangeDigest"]}, tc.require)
        self.assertEqual(result["Status"], "TransportEnabled")
        self.assertFalse(result["WireGuardRestarted"])
        new = backend.read_json(tc.MANIFEST)
        self.assertEqual(new["Peers"], old["Peers"])
        self.assertEqual(new["ServerPublicKey"], old["ServerPublicKey"])
        self.assertEqual(fs.files[tc.paths(plan)["Config"]], config)
        self.assertFalse(any(call[:2] in (["wg-quick", "up"], ["wg-quick", "down"]) for call in kernel.calls[start:]))
        backend.authorize({"ClientRequest": base.request(2)})
        backend.revoke({"DeviceId": base.request(2)["DeviceId"]})
        backend.uninstall({})
        self.assertFalse(kernel.running)

    def test_architecture_drift_blocks_apply_before_install_and_alias_change_is_allowed(self):
        backend, fs, kernel = self.fixture()
        preview = backend.plan(base.plan_input())
        before = copy.deepcopy(fs.files)
        kernel.env["OS"]["Architecture"] = "x86_64"
        with self.assertRaises(tc.TCError) as caught:
            backend.apply({"PlanId": preview["PlanId"]})
        self.assertEqual(caught.exception.code, "HostArchitectureMismatch")
        self.assertEqual(fs.files, before)
        self.assertEqual(kernel.install_count, 0)
        kernel.env["OS"]["Architecture"] = "arm64"
        self.assertEqual(backend.apply({"PlanId": preview["PlanId"]})["Status"], "Applied")

    def test_unsupported_architecture_and_old_os_remain_blocked(self):
        for architecture, os_id, version in (("armv7l", "ubuntu", "24.04"), ("aarch64", "ubuntu", "22.04"), ("i686", "debian", "13")):
            with self.subTest(architecture=architecture, version=version):
                backend, fs, kernel = self.fixture(architecture, os_id, version)
                self.assertFalse(backend.inspect({})["Supported"])
                with self.assertRaises(tc.TCError) as caught:
                    backend.plan(base.plan_input())
                self.assertEqual(caught.exception.code, "PreflightRejected")
                self.assertFalse(fs.mutations)

    def test_capabilities_are_same_shared_methods(self):
        backend, _, _ = self.fixture()
        result = backend.execute("capabilities", {})
        self.assertEqual(result["ConnectionMethods"], cm.methods())
        self.assertEqual(result["ServerArchitectures"], cm.declaration()["Architectures"])
        self.assertEqual(result["ConnectionMethodContractVersion"], 1)


class ComponentInstallerTests(unittest.TestCase):
    def setUp(self):
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        self.root = Path(self.stack.enter_context(tempfile.TemporaryDirectory(prefix="tc-x1x2-arm-")))
        self.fs = SandboxPosix(self.root)
        component_root = self.root / "component"
        directory = component_root / "1.14.2"
        self.binary, self.library = directory / "sing-box", directory / "libcronet.so"
        self.receipt = directory / "sing-box.sha256"
        self.stack.enter_context(mock.patch.multiple(tcp, os=self.fs, sys=SimpleNamespace(platform="linux"),
                                                     platform=SimpleNamespace(machine=lambda: "aarch64"),
                                                     COMPONENT_ROOT=str(component_root), BIN_DIRECTORY=str(directory),
                                                     BINARY=str(self.binary), LIBRARY=str(self.library), RECEIPT=str(self.receipt)))
        self.download = self.stack.enter_context(mock.patch.object(tcp.urllib.request, "urlopen"))
        self.raw, pins = archive_fixture()
        self.stack.enter_context(mock.patch.dict(tcp.RELEASES, {"arm64": pins}))
        self.download.side_effect = lambda *_args, **_kwargs: io.BytesIO(self.raw)

    def error(self, code, action):
        with self.assertRaises(tc.TCError) as caught:
            action()
        self.assertEqual(caught.exception.code, code)

    def test_arm_install_verify_and_reuse_never_redownload_existing_version(self):
        self.assertEqual(tcp.install_binary(tc.require), str(self.binary))
        request = self.download.call_args.args[0]
        self.assertTrue(request.full_url.endswith("sing-box-1.14.2-linux-arm64.tar.gz"))
        self.assertEqual(self.download.call_args.kwargs["timeout"], 40)
        self.assertEqual(self.fs.writes, [str(self.binary), str(self.library), str(self.receipt)])
        before = {path: path.read_bytes() for path in (self.binary, self.library, self.receipt)}
        self.download.side_effect = AssertionError("Existing verified components must not be downloaded or upgraded.")
        self.assertEqual(tcp.install_binary(tc.require), str(self.binary))
        self.assertEqual(tcp.verify_binary(tc.require), str(self.binary))
        self.assertEqual(before, {path: path.read_bytes() for path in before})
        self.assertEqual(self.download.call_count, 1)

    def test_download_hash_mismatch_and_size_limit_write_no_components(self):
        self.raw += b"tampered"
        self.error("TransportHashMismatch", lambda: tcp.install_binary(tc.require))
        self.assertFalse(self.fs.writes)
        with mock.patch.object(tcp, "MAX_ARCHIVE", 64):
            self.error("TransportHashMismatch", lambda: tcp.install_binary(tc.require))
        self.assertFalse(self.fs.writes)

    def test_wrong_architecture_rejected_even_when_fixture_hashes_match(self):
        self.raw, pins = archive_fixture(machine=62)
        with mock.patch.dict(tcp.RELEASES, {"arm64": pins}):
            self.error("TransportArchitectureMismatch", lambda: tcp.install_binary(tc.require))
        self.assertFalse(self.fs.writes)

    def test_elf_class_endian_version_and_machine_are_all_checked(self):
        release = tcp.component_release(tc.require)
        valid = bytearray(elf(183))
        for index, replacement in ((4, 1), (5, 2), (6, 0), (18, 62), (20, 0)):
            invalid = bytearray(valid)
            invalid[index] = replacement
            self.error("TransportArchitectureMismatch", lambda: tcp._elf(bytes(invalid), release, tc.require))
        self.error("TransportArchitectureMismatch", lambda: tcp._elf(bytes(valid[:20]), release, tc.require))

    def test_wrong_archive_layout_duplicate_and_links_cannot_install(self):
        for options in ({"layout": "sing-box-1.14.2-linux-amd64"}, {"symlink": True}, {"duplicate": True}):
            with self.subTest(options=options):
                self.raw, pins = archive_fixture(**options)
                with mock.patch.dict(tcp.RELEASES, {"arm64": pins}):
                    self.error("TransportArchiveInvalid", lambda: tcp.install_binary(tc.require))
                self.assertFalse(self.fs.writes)

    def test_component_and_receipt_corruption_are_rejected_without_replacement(self):
        tcp.install_binary(tc.require)
        self.download.reset_mock()
        for path in (self.binary, self.library, self.receipt):
            with self.subTest(path=path.name):
                good = path.read_bytes()
                damaged = good[:-1] + bytes((good[-1] ^ 1,))
                path.write_bytes(damaged)
                self.error("TransportHashMismatch", lambda: tcp.install_binary(tc.require))
                self.assertEqual(path.read_bytes(), damaged)
                path.write_bytes(good)
        self.download.assert_not_called()

    def test_existing_other_architecture_is_never_overwritten(self):
        tcp.install_binary(tc.require)
        before = {path: path.read_bytes() for path in (self.binary, self.library, self.receipt)}
        self.download.reset_mock()
        with mock.patch.object(tcp.platform, "machine", return_value="x86_64"):
            self.error("TransportArchitectureMismatch", lambda: tcp.install_binary(tc.require))
        self.assertEqual(before, {path: path.read_bytes() for path in before})
        self.download.assert_not_called()

    def test_existing_amd64_same_version_uses_legacy_three_digest_receipt(self):
        self.raw, pins = archive_fixture("amd64", 62)
        with mock.patch.dict(tcp.RELEASES, {"amd64": pins}), mock.patch.object(tcp.platform, "machine", return_value="amd64"):
            tcp.install_binary(tc.require)
            self.assertEqual(self.receipt.read_text(encoding="ascii"), "|".join(pins[k] for k in ("ArchiveSHA256", "BinarySHA256", "LibrarySHA256")) + "\n")
            self.download.reset_mock()
            tcp.install_binary(tc.require)
            self.download.assert_not_called()

    def test_incomplete_installation_is_preserved_and_missing_library_detected(self):
        tcp.install_binary(tc.require)
        original = self.binary.read_bytes()
        self.library.unlink()
        self.download.reset_mock()
        self.error("TransportComponentMissing", lambda: tcp.install_binary(tc.require))
        self.assertEqual(self.binary.read_bytes(), original)
        self.download.assert_not_called()
        self.binary.unlink()
        self.error("OwnershipMismatch", lambda: tcp.install_binary(tc.require))
        self.assertTrue(self.receipt.exists())
        self.download.assert_not_called()

    def test_unsafe_file_ownership_links_and_parent_modes_are_rejected(self):
        tcp.install_binary(tc.require)
        for path, override in ((self.binary, {"st_uid": 1000}), (self.library, {"st_nlink": 2}),
                               (self.binary, {"st_mode": stat.S_IFLNK | 0o777}),
                               (self.binary.parent, {"st_mode": stat.S_IFDIR | 0o777})):
            with self.subTest(path=path.name, override=override):
                self.fs.overrides[str(path)] = override
                self.error("UnsafePath", lambda: tcp.verify_binary(tc.require))
                self.fs.overrides.clear()

    def test_unsupported_host_or_architecture_stops_before_download_and_filesystem_writes(self):
        with mock.patch.object(tcp.platform, "machine", return_value="armv7l"):
            self.error("UnsupportedArchitecture", lambda: tcp.install_binary(tc.require))
        with mock.patch.object(tcp.sys, "platform", "win32"):
            self.error("UnsupportedHost", lambda: tcp.install_binary(tc.require))
        self.assertFalse(list(self.root.iterdir()))
        self.download.assert_not_called()

    def test_failed_download_does_not_install_or_execute_anything(self):
        self.download.side_effect = tcp.urllib.error.URLError("offline mock")
        self.error("TransportDownloadFailed", lambda: tcp.install_binary(tc.require))
        self.assertFalse(self.fs.writes)


if __name__ == "__main__":
    unittest.main()
