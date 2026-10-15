"""Windows-safe unit/transaction tests. No real OS, networking or root commands.

Run: python -B -m unittest discover -s product/tests -p test_linux_server.py -v
The fake kernel models effects and injected crashes; these are not VM tests.
"""

import base64
import contextlib
import copy
import datetime as dt
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import shlex
import stat
import struct
from types import SimpleNamespace
import unittest
from unittest import mock
import uuid


SOURCE = Path(__file__).resolve().parents[1] / "linux" / "tradechannel_linux.py"
SPEC = importlib.util.spec_from_file_location("tradechannel_linux", SOURCE)
tc = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(tc)


def public_key(seed):
    return base64.b64encode(hashlib.sha256(seed.encode()).digest()).decode()


def request(number=1):
    return {"SchemaVersion": 1, "Kind": "TradeChannel.ClientRequest",
            "RequestId": str(uuid.UUID(int=number)), "DeviceId": str(uuid.UUID(int=1000 + number)),
            "CreatedAtUtc": "2026-10-04T01:02:03.1234567Z", "ClientPublicKey": public_key("client-" + str(number)),
            "AddressFamilies": ["IPv4"]}


def plan_input():
    return {"Name": "Linux 香港候选", "PublicEndpoint": "203.0.113.10:51820", "TunnelSubnet": "10.78.0.0/24",
            "ClientRequest": request()}


# Captured Ubuntu 24.04 managed-table JSON from the public 2026-10-04
# server-diagnostics report. Only addresses and identifiers are replaced.
# Keep the original declaration/rule order, handles and expression shapes.
# Embedded here so tests never need server artifacts or private state.
UBUNTU_NFT = json.loads(r'''{"nftables":[
{"table":{"family":"inet","handle":7,"name":"tc_111111112222"}},
{"chain":{"family":"inet","handle":1,"hook":"input","name":"input","policy":"accept","prio":-5,"table":"tc_111111112222","type":"filter"}},
{"chain":{"family":"inet","handle":4,"hook":"forward","name":"forward","policy":"drop","prio":-5,"table":"tc_111111112222","type":"filter"}},
{"chain":{"family":"inet","handle":22,"hook":"postrouting","name":"postrouting","policy":"accept","prio":100,"table":"tc_111111112222","type":"nat"}},
{"rule":{"chain":"input","comment":"TradeChannel:11111111-2222-4333-8444-555555555555","expr":[{"match":{"left":{"meta":{"key":"iifname"}},"op":"==","right":"tc1111111122"}},{"drop":null}],"family":"inet","handle":2,"table":"tc_111111112222"}},
{"rule":{"chain":"input","comment":"TradeChannel:11111111-2222-4333-8444-555555555555","expr":[{"match":{"left":{"meta":{"key":"iifname"}},"op":"==","right":"ens5"}},{"match":{"left":{"meta":{"key":"nfproto"}},"op":"==","right":"ipv4"}},{"match":{"left":{"payload":{"field":"dport","protocol":"udp"}},"op":"==","right":51820}},{"accept":null}],"family":"inet","handle":3,"table":"tc_111111112222"}},
{"rule":{"chain":"forward","comment":"TradeChannel:11111111-2222-4333-8444-555555555555","expr":[{"match":{"left":{"ct":{"key":"state"}},"op":"in","right":"invalid"}},{"drop":null}],"family":"inet","handle":5,"table":"tc_111111112222"}},
{"rule":{"chain":"forward","comment":"TradeChannel:11111111-2222-4333-8444-555555555555","expr":[{"match":{"left":{"meta":{"key":"iifname"}},"op":"==","right":"tc1111111122"}},{"match":{"left":{"meta":{"key":"oifname"}},"op":"==","right":"tc1111111122"}},{"drop":null}],"family":"inet","handle":6,"table":"tc_111111112222"}},
{"rule":{"chain":"forward","comment":"TradeChannel:11111111-2222-4333-8444-555555555555","expr":[{"match":{"left":{"meta":{"key":"iifname"}},"op":"==","right":"tc1111111122"}},{"match":{"left":{"payload":{"field":"daddr","protocol":"ip"}},"op":"==","right":{"prefix":{"addr":"0.0.0.0","len":8}}}},{"drop":null}],"family":"inet","handle":7,"table":"tc_111111112222"}},
{"rule":{"chain":"forward","comment":"TradeChannel:11111111-2222-4333-8444-555555555555","expr":[{"match":{"left":{"meta":{"key":"iifname"}},"op":"==","right":"tc1111111122"}},{"match":{"left":{"payload":{"field":"daddr","protocol":"ip"}},"op":"==","right":{"prefix":{"addr":"10.0.0.0","len":8}}}},{"drop":null}],"family":"inet","handle":8,"table":"tc_111111112222"}},
{"rule":{"chain":"forward","comment":"TradeChannel:11111111-2222-4333-8444-555555555555","expr":[{"match":{"left":{"meta":{"key":"iifname"}},"op":"==","right":"tc1111111122"}},{"match":{"left":{"payload":{"field":"daddr","protocol":"ip"}},"op":"==","right":{"prefix":{"addr":"100.64.0.0","len":10}}}},{"drop":null}],"family":"inet","handle":9,"table":"tc_111111112222"}},
{"rule":{"chain":"forward","comment":"TradeChannel:11111111-2222-4333-8444-555555555555","expr":[{"match":{"left":{"meta":{"key":"iifname"}},"op":"==","right":"tc1111111122"}},{"match":{"left":{"payload":{"field":"daddr","protocol":"ip"}},"op":"==","right":{"prefix":{"addr":"127.0.0.0","len":8}}}},{"drop":null}],"family":"inet","handle":10,"table":"tc_111111112222"}},
{"rule":{"chain":"forward","comment":"TradeChannel:11111111-2222-4333-8444-555555555555","expr":[{"match":{"left":{"meta":{"key":"iifname"}},"op":"==","right":"tc1111111122"}},{"match":{"left":{"payload":{"field":"daddr","protocol":"ip"}},"op":"==","right":{"prefix":{"addr":"169.254.0.0","len":16}}}},{"drop":null}],"family":"inet","handle":11,"table":"tc_111111112222"}},
{"rule":{"chain":"forward","comment":"TradeChannel:11111111-2222-4333-8444-555555555555","expr":[{"match":{"left":{"meta":{"key":"iifname"}},"op":"==","right":"tc1111111122"}},{"match":{"left":{"payload":{"field":"daddr","protocol":"ip"}},"op":"==","right":{"prefix":{"addr":"172.16.0.0","len":12}}}},{"drop":null}],"family":"inet","handle":12,"table":"tc_111111112222"}},
{"rule":{"chain":"forward","comment":"TradeChannel:11111111-2222-4333-8444-555555555555","expr":[{"match":{"left":{"meta":{"key":"iifname"}},"op":"==","right":"tc1111111122"}},{"match":{"left":{"payload":{"field":"daddr","protocol":"ip"}},"op":"==","right":{"prefix":{"addr":"192.0.0.0","len":24}}}},{"drop":null}],"family":"inet","handle":13,"table":"tc_111111112222"}},
{"rule":{"chain":"forward","comment":"TradeChannel:11111111-2222-4333-8444-555555555555","expr":[{"match":{"left":{"meta":{"key":"iifname"}},"op":"==","right":"tc1111111122"}},{"match":{"left":{"payload":{"field":"daddr","protocol":"ip"}},"op":"==","right":{"prefix":{"addr":"192.168.0.0","len":16}}}},{"drop":null}],"family":"inet","handle":14,"table":"tc_111111112222"}},
{"rule":{"chain":"forward","comment":"TradeChannel:11111111-2222-4333-8444-555555555555","expr":[{"match":{"left":{"meta":{"key":"iifname"}},"op":"==","right":"tc1111111122"}},{"match":{"left":{"payload":{"field":"daddr","protocol":"ip"}},"op":"==","right":{"prefix":{"addr":"198.18.0.0","len":15}}}},{"drop":null}],"family":"inet","handle":15,"table":"tc_111111112222"}},
{"rule":{"chain":"forward","comment":"TradeChannel:11111111-2222-4333-8444-555555555555","expr":[{"match":{"left":{"meta":{"key":"iifname"}},"op":"==","right":"tc1111111122"}},{"match":{"left":{"payload":{"field":"daddr","protocol":"ip"}},"op":"==","right":{"prefix":{"addr":"224.0.0.0","len":4}}}},{"drop":null}],"family":"inet","handle":16,"table":"tc_111111112222"}},
{"rule":{"chain":"forward","comment":"TradeChannel:11111111-2222-4333-8444-555555555555","expr":[{"match":{"left":{"meta":{"key":"iifname"}},"op":"==","right":"tc1111111122"}},{"match":{"left":{"payload":{"field":"daddr","protocol":"ip"}},"op":"==","right":{"prefix":{"addr":"240.0.0.0","len":4}}}},{"drop":null}],"family":"inet","handle":17,"table":"tc_111111112222"}},
{"rule":{"chain":"forward","comment":"TradeChannel:11111111-2222-4333-8444-555555555555","expr":[{"match":{"left":{"meta":{"key":"iifname"}},"op":"==","right":"tc1111111122"}},{"match":{"left":{"payload":{"field":"daddr","protocol":"ip"}},"op":"==","right":"203.0.113.10"}},{"drop":null}],"family":"inet","handle":18,"table":"tc_111111112222"}},
{"rule":{"chain":"forward","comment":"TradeChannel:11111111-2222-4333-8444-555555555555","expr":[{"match":{"left":{"meta":{"key":"iifname"}},"op":"==","right":"tc1111111122"}},{"match":{"left":{"meta":{"key":"oifname"}},"op":"==","right":"ens5"}},{"match":{"left":{"payload":{"field":"saddr","protocol":"ip"}},"op":"==","right":{"prefix":{"addr":"10.78.0.0","len":24}}}},{"accept":null}],"family":"inet","handle":19,"table":"tc_111111112222"}},
{"rule":{"chain":"forward","comment":"TradeChannel:11111111-2222-4333-8444-555555555555","expr":[{"match":{"left":{"meta":{"key":"iifname"}},"op":"==","right":"ens5"}},{"match":{"left":{"meta":{"key":"oifname"}},"op":"==","right":"tc1111111122"}},{"match":{"left":{"payload":{"field":"daddr","protocol":"ip"}},"op":"==","right":{"prefix":{"addr":"10.78.0.0","len":24}}}},{"match":{"left":{"ct":{"key":"state"}},"op":"in","right":"established"}},{"accept":null}],"family":"inet","handle":20,"table":"tc_111111112222"}},
{"rule":{"chain":"forward","comment":"TradeChannel:11111111-2222-4333-8444-555555555555","expr":[{"match":{"left":{"meta":{"key":"iifname"}},"op":"==","right":"ens5"}},{"match":{"left":{"meta":{"key":"oifname"}},"op":"==","right":"tc1111111122"}},{"match":{"left":{"payload":{"field":"daddr","protocol":"ip"}},"op":"==","right":{"prefix":{"addr":"10.78.0.0","len":24}}}},{"match":{"left":{"ct":{"key":"state"}},"op":"in","right":"related"}},{"accept":null}],"family":"inet","handle":21,"table":"tc_111111112222"}},
{"rule":{"chain":"postrouting","comment":"TradeChannel:11111111-2222-4333-8444-555555555555","expr":[{"match":{"left":{"meta":{"key":"iifname"}},"op":"==","right":"tc1111111122"}},{"match":{"left":{"meta":{"key":"oifname"}},"op":"==","right":"ens5"}},{"match":{"left":{"payload":{"field":"saddr","protocol":"ip"}},"op":"==","right":{"prefix":{"addr":"10.78.0.0","len":24}}}},{"masquerade":null}],"family":"inet","handle":23,"table":"tc_111111112222"}}
]}''')


def captured_nft(plan):
    p = tc.paths(plan)
    text = json.dumps(UBUNTU_NFT)
    replacements = {
        "11111111-2222-4333-8444-555555555555": plan["NodeId"],
        "tc_111111112222": p["Table"], "tc1111111122": p["Interface"],
        "ens5": plan["DefaultInterface"], "203.0.113.10": plan["PublicEndpoint"].split(":")[0],
    }
    for old, new in replacements.items():
        text = text.replace(old, new)
    return json.loads(text)


class Crash(BaseException):
    pass


class MemoryFS:
    def __init__(self):
        self.files, self.links, self.modes = {}, {}, {}
        self.dirs = {"/", "/var", "/var/lib", "/etc", "/etc/systemd", "/etc/systemd/system",
                     "/etc/systemd/system/multi-user.target.wants", "/usr", "/usr/sbin"}
        self.unsafe = set()
        self.mutations = []
        self.locked = False
        self.fail_path = None

    def check(self, path, leaf_link=False):
        tc.require(path.startswith("/") and ".." not in path.split("/"), "UnsafePath", "Unsafe path.")
        for bad in self.unsafe | set(self.links):
            if path == bad and leaf_link and bad in self.links and bad not in self.unsafe:
                continue
            tc.require(path != bad and not path.startswith(bad + "/"), "UnsafePath", "Symlink, reparse point or unsafe ownership.")
        for p, mode in self.modes.items():
            if path == p or path.startswith(p + "/"):
                if p == tc.ROOT or p.startswith(tc.ROOT + "/"):
                    tc.require(mode == (0o700 if p in self.dirs else 0o600), "UnsafePath", "Unsafe state mode.")

    def exists(self, path):
        self.check(path)
        return path in self.files or path in self.dirs

    def metadata(self, path):
        self.check(path.rsplit("/", 1)[0])
        kind = "Symlink" if path in self.links else "RegularFile" if path in self.files else "Directory" if path in self.dirs else "Missing"
        return {"Exists": kind != "Missing", "Type": kind,
                "Mode": format(self.modes.get(path, 0o777 if kind == "Symlink" else 0o755), "04o") if kind != "Missing" else None,
                "Uid": 0, "LinkCount": 1, "Size": len(self.files.get(path, "")), "ReparsePoint": path in self.unsafe}

    def read(self, path):
        self.check(path)
        return self.files.get(path)

    def mkdir(self, path):
        self.check(path)
        if path not in self.dirs:
            tc.require(path.rsplit("/", 1)[0] in self.dirs, "UnsafePath", "Missing parent.")
            self.dirs.add(path)
            self.modes[path] = 0o700
            self.mutations.append(("mkdir", path))

    def list(self, path):
        self.check(path)
        return sorted({p[len(path) + 1:].split("/")[0] for p in set(self.files) | self.dirs | set(self.links)
                       if p.startswith(path + "/")})

    def cas(self, path, before, after, mode=0o600):
        tc.require(self.read(path) == before, "OwnershipMismatch", "File changed.")
        if before == after:
            return
        if self.fail_path == path:
            self.fail_path = None
            raise tc.TCError("DiskFailure", "Injected write failure.")
        tc.require(path.rsplit("/", 1)[0] in self.dirs, "UnsafePath", "Missing parent.")
        if after is None:
            self.files.pop(path, None)
            self.modes.pop(path, None)
        else:
            self.files[path] = after
            self.modes[path] = mode
        self.mutations.append(("write", path))

    def link(self, path):
        self.check(path, leaf_link=True)
        tc.require(path not in self.files, "OwnershipMismatch", "Foreign regular file in link slot.")
        return self.links.get(path)

    def cas_link(self, path, before, after):
        tc.require(self.link(path) == before, "OwnershipMismatch", "Link changed.")
        if before != after:
            if after is None:
                self.links.pop(path, None)
            else:
                self.links[path] = after
            self.mutations.append(("link", path))

    @contextlib.contextmanager
    def lock(self, readonly=False):
        tc.require(not self.locked, "Busy", "Operation already running.")
        self.locked = True
        try:
            yield
        finally:
            self.locked = False


class FakeOS:
    def __init__(self, fs):
        self.fs = fs
        self.env = {"OS": {"Id": "ubuntu", "Version": "24.04", "Architecture": "x86_64"},
                    "MachineBinding": tc.digest("a" * 32), "Container": False, "Systemd": True,
                    "Routes": [{"dst": "default", "gateway": "172.31.0.1", "dev": "ens5", "protocol": "dhcp"},
                               {"dst": "172.31.0.0/20", "dev": "ens5"}],
                    "Rules": [{"priority": 0, "table": "local", "src": "all"},
                              {"priority": 32766, "table": "main", "src": "all"},
                              {"priority": 32767, "table": "default", "src": "all"}],
                    "Links": [{"ifname": "lo"}, {"ifname": "ens5", "mtu": 1500, "flags": ["UP"]}],
                    "Addresses": [{"ifname": "ens5", "addr_info": [{"family": "inet", "local": "172.31.0.2", "prefixlen": 20}]}],
                    "Services": ["ssh.service", "wg-quick@.service"], "ActiveServices": ["ssh.service"],
                    "Nft": {"nftables": []}, "LegacyRules": [], "WireGuardFiles": [], "UdpPorts": [68],
                    "Forwarding": "0", "Tools": {"wg": True, "wg-quick": True, "nft": True}, "PolicyExists": False}
        self.calls = []
        self.running = set()
        self.tunnels = {}
        self.override = {}
        self.fail = None
        self.crash = None
        self.key_count = 0
        self.install_count = 0
        self.install_effect = None

    def probe(self):
        env = copy.deepcopy(self.env)
        env["PolicyExists"] = tc.POLICY in self.fs.files
        return env

    def service(self, unit):
        if unit in self.override:
            return self.override[unit]
        path = "/etc/systemd/system/" + unit
        if path not in self.fs.files:
            return {"LoadState": "not-found", "ActiveState": "inactive", "FragmentPath": "", "DropInPaths": ""}
        return {"LoadState": "loaded", "ActiveState": "active" if unit in self.running else "inactive",
                "FragmentPath": path, "DropInPaths": "", "UnitFileState": "enabled"}

    def live(self, interface):
        return copy.deepcopy(self.tunnels[interface])

    def install(self):
        self.install_count += 1
        assert self.fs.files[tc.POLICY] == tc.POLICY_TEXT
        assert self.fs.modes[tc.POLICY] == 0o700
        self.env["Tools"] = {k: True for k in self.env["Tools"]}
        if self.env["Nft"] is None:
            self.env["Nft"] = {"nftables": []}
        if self.install_effect:
            self.install_effect()

    def parse_config(self, path):
        interface, peers = {}, {}
        current = interface
        for line in self.fs.files[path].splitlines():
            if line == "[Peer]":
                current = {}
            elif " = " in line:
                k, value = line.split(" = ", 1)
                current[k] = value
                if k == "AllowedIPs":
                    peers[current["PublicKey"]] = value
        return interface, {"PublicKey": public_key(interface["PrivateKey"]), "Port": interface["ListenPort"], "Peers": peers, "FwMark": "off"}

    def remove_tunnel(self, name):
        self.tunnels.pop(name, None)
        self.env["Links"] = [x for x in self.env["Links"] if x.get("ifname") != name]
        self.env["Addresses"] = [x for x in self.env["Addresses"] if x.get("ifname") != name]
        self.env["Routes"] = [x for x in self.env["Routes"] if x.get("dev") != name]
        self.env["UdpPorts"] = [68]

    def run(self, argv, input_text=None, **unused):
        argv = list(argv)
        self.calls.append(argv)
        if self.fail and self.fail(argv):
            self.fail = None
            raise tc.TCError("CommandFailed", "Suppressed private tool error.")
        result = self.effect(argv, input_text)
        if self.crash and self.crash(argv):
            self.crash = None
            raise Crash("power loss after side effect")
        return result

    def effect(self, argv, input_text):
        if argv == ["wg", "genkey"]:
            self.key_count += 1
            return public_key("server-private-" + str(self.key_count))
        if argv == ["wg", "pubkey"]:
            return public_key(input_text.strip())
        if argv[:2] == ["wg", "syncconf"]:
            _, tunnel = self.parse_config(argv[3])
            tc.require(argv[2] in self.tunnels, "CommandFailed", "Interface missing.")
            self.tunnels[argv[2]] = tunnel
            return ""
        if argv[:2] == ["nft", "-c"]:
            json.loads(self.fs.files[argv[-1]])
            return ""
        if argv[:3] == ["nft", "-j", "-f"]:
            tc.require(not self.env["Nft"]["nftables"], "CommandFailed", "Table exists.")
            items = [next(iter(x.values())) for x in json.loads(self.fs.files[argv[3]])["nftables"]]
            # The Ubuntu kernel listing observed in the public diagnostic puts
            # declarations first, instead of echoing the input command order.
            items = [x for x in items if "rule" not in x] + [x for x in items if "rule" in x]
            for handle, item in enumerate(items, 1):
                next(iter(item.values()))["handle"] = handle
            self.env["Nft"] = {"nftables": items}
            return ""
        if argv[:3] == ["nft", "delete", "table"]:
            table = argv[-1]
            self.env["Nft"]["nftables"] = [x for x in self.env["Nft"]["nftables"]
                if not (next(iter(x.values())).get("table") == table or ("table" in x and x["table"]["name"] == table))]
            return ""
        if argv[0] == "sysctl":
            # Only the forwarding key is observable state here. --load takes a
            # file path, which must not be parsed as a key=value assignment.
            for item in argv[1:]:
                if "=" in item and item.split("=", 1)[0] == "net.ipv4.ip_forward":
                    self.env["Forwarding"] = item.split("=", 1)[1]
            return ""
        if argv[:2] == ["wg-quick", "up"]:
            name = argv[2].rsplit("/", 1)[1][:-5]
            config, tunnel = self.parse_config(argv[2])
            self.tunnels[name] = tunnel
            address, prefix = config["Address"].split("/")
            self.env["Links"].append({"ifname": name, "linkinfo": {"info_kind": "wireguard"}, "mtu": int(config["MTU"]), "flags": ["UP"]})
            self.env["Addresses"].append({"ifname": name, "addr_info": [{"family": "inet", "local": address, "prefixlen": int(prefix)}]})
            self.env["Routes"].append({"dev": name, "dst": str(tc.ipaddress.IPv4Network(config["Address"], strict=False))})
            self.env["UdpPorts"].append(int(config["ListenPort"]))
            return ""
        if argv[:2] == ["wg-quick", "down"]:
            self.remove_tunnel(argv[2].rsplit("/", 1)[1][:-5])
            return ""
        if argv[:3] == ["ip", "link", "delete"]:
            self.remove_tunnel(argv[-1])
            return ""
        if argv[:2] == ["systemctl", "daemon-reload"]:
            return ""
        if argv[:2] in (["systemctl", "start"], ["systemctl", "stop"]):
            unit = argv[2]
            start = argv[1] == "start"
            if (start and unit in self.running) or (not start and unit not in self.running):
                return ""
            prefix = "ExecStart=" if start else "ExecStop="
            for line in self.fs.files["/etc/systemd/system/" + unit].splitlines():
                if line.startswith(prefix):
                    command = shlex.split(line[len(prefix):].lstrip("-"))
                    command[0] = command[0].rsplit("/", 1)[1]
                    self.run(command)
            if start:
                self.running.add(unit)
            else:
                self.running.discard(unit)
            return ""
        raise AssertionError("Unexpected mocked command " + repr(argv))


def header_packet(source="10.78.0.2", destination="1.1.1.1", sport=43000, dport=443,
                  protocol=6, options=b"", ip_options=b"", payload=b"", flags=0x12, fragments=0x4000):
    """Synthetic IPv4 datagrams; packet tests never open a real socket."""
    if protocol == 6:
        transport = struct.pack("!HHIIBBHHH", sport, dport, 0x10203040, 0x50607080,
                                ((20 + len(options)) // 4 << 4) | (flags >> 8), flags & 255, 4096, 0, 0) + options
    else:
        transport = struct.pack("!HHHH", sport, dport, 8 + len(payload), 0)
    size = 20 + len(ip_options) + len(transport) + len(payload)
    ip = struct.pack("!BBHHHBBH4s4s", 0x40 | ((20 + len(ip_options)) // 4), 0, size, 123,
                     fragments, 64, protocol, 0, tc.socket.inet_aton(source), tc.socket.inet_aton(destination))
    return ip + ip_options + transport + payload


class PacketHeaderTests(unittest.TestCase):
    def decode(self, packet, interface="ens5", direction=0, ethertype=0x0800):
        return tc.packet_header(packet, (interface, ethertype, direction, 1, b"private-mac"),
                                "ens5", "tc0123456789", 51820)

    def test_tcp_headers_on_both_interfaces_and_directions_without_payload(self):
        options = b"\x01\x02\x04\x05\x3c\x01\x00\x00"
        packet = header_packet(options=options, ip_options=b"\x01" * 4,
                               payload=b"SSH-secret-key-application-body", flags=0x1d2)
        for interface in ("ens5", "tc0123456789"):
            for direction in (0, 4):
                with self.subTest(interface=interface, direction=direction):
                    result = self.decode(packet, interface, direction)
                    self.assertEqual(result, {
                        "Interface": interface, "Direction": "Incoming" if direction == 0 else "Outgoing",
                        "Protocol": "TCP", "SourceAddress": "10.78.0.2", "DestinationAddress": "1.1.1.1",
                        "SourcePort": 43000, "DestinationPort": 443, "IpLength": len(packet),
                        "TcpFlags": 0x1d2, "TcpSequence": 0x10203040, "TcpAcknowledgment": 0x50607080,
                        "TcpHeaderLength": 28, "TcpMss": 1340, "PayloadLength": 31})
                    self.assertNotIn("SSH", json.dumps(result))
                    self.assertNotIn("private", json.dumps(result))
                    reverse = self.decode(header_packet(source="1.1.1.1", destination="10.78.0.2", sport=443, dport=43000),
                                          interface, direction)
                    self.assertEqual(reverse["SourcePort"], 443)
                    self.assertIsNone(reverse["TcpMss"])

    def test_target_address_and_port_must_belong_to_same_endpoint(self):
        denied = [
            {"destination": "8.8.8.8"}, {"dport": 80}, {"destination": "1.1.1.2"},
            {"source": "1.1.1.1", "destination": "8.8.8.8"},  # Split IP/port match.
            {"destination": "1.1.1.1", "sport": 443, "dport": 80},
            {"source": "1.1.1.1", "destination": "10.78.0.2", "sport": 80, "dport": 43000},
            {"sport": 22}, {"source": "1.1.1.1", "sport": 443, "dport": 22},
            {"destination": "172.31.0.2", "sport": 2222, "dport": 52000},
            {"destination": "172.31.0.2", "sport": 52000, "dport": 2222},
            {"protocol": 1}, {"protocol": 17},
        ]
        for values in denied:
            with self.subTest(values=values):
                self.assertIsNone(self.decode(header_packet(**values)))
        for interface in ("lo", "eth0", "tc0123456788", ""):
            self.assertIsNone(self.decode(header_packet(), interface))
        for direction in (1, 2, 3, 5, -1):
            self.assertIsNone(self.decode(header_packet(), direction=direction))
        for ethertype in (0x86dd, 0x0806, 3):
            self.assertIsNone(self.decode(header_packet(), ethertype=ethertype))
        for address in ((), ("ens5",), ("ens5", 0x0800)):
            self.assertIsNone(tc.packet_header(header_packet(), address, "ens5", "tc0123456789", 51820))

    def test_wireguard_udp_matches_only_wan_and_directional_server_port(self):
        incoming = header_packet(source="198.51.100.5", destination="172.31.0.2", dport=51820,
                                 protocol=17, payload=b"encrypted-secret")
        outgoing = header_packet(source="172.31.0.2", destination="198.51.100.5", sport=51820,
                                 dport=43000, protocol=17, payload=b"encrypted-secret")
        for packet, direction in ((incoming, 0), (outgoing, 4)):
            result = self.decode(packet, direction=direction)
            self.assertEqual(result["Protocol"], "UDP")
            self.assertEqual(result["PayloadLength"], 16)
            self.assertEqual(set(result), {"Interface", "Direction", "Protocol", "SourceAddress",
                                          "DestinationAddress", "SourcePort", "DestinationPort", "IpLength", "PayloadLength"})
            self.assertNotIn("secret", json.dumps(result))
            self.assertIsNone(self.decode(packet, direction=4 - direction))
            self.assertIsNone(self.decode(packet, interface="tc0123456789", direction=direction))
        self.assertIsNone(self.decode(header_packet(protocol=17, dport=51821)))
        self.assertIsNone(self.decode(header_packet(protocol=17, dport=53)))

    def test_truncated_headers_and_full_headers_with_truncated_payload(self):
        for packet, size in (
            (header_packet(options=b"\x02\x04\x05\x3c", payload=b"private" * 30), 44),
            (header_packet(protocol=17, dport=51820, payload=b"private" * 30), 28),
            (header_packet(ip_options=b"\x01" * 40, options=b"\x01" * 36 + b"\x02\x04\x05\x3c",
                           payload=b"private" * 30), 120),
        ):
            for end in range(size):
                with self.subTest(size=size, end=end):
                    self.assertIsNone(self.decode(packet[:end]))
            self.assertEqual(self.decode(packet[:size]), self.decode(packet))
            self.assertEqual(self.decode(packet[:tc.CAPTURE_HEADER_BYTES])["IpLength"], len(packet))

    def test_malformed_lengths_fragments_and_tcp_options_are_discarded(self):
        original = header_packet(options=b"\x02\x04\x05\x3c")
        for offset, replacement in (
            (0, b"\x65"), (0, b"\x44"), (0, b"\x4f"), (2, b"\x00\x13"),
            (2, b"\x00\x28"), (32, b"\x40"), (32, b"\xf0"),
            (40, b"\x02\x00\x05\x3c"), (40, b"\x02\x01\x05\x3c"),
            (40, b"\x02\x03\x05\x3c"), (40, b"\x03\x08\x05\x3c"),
            (40, b"\x01\x01\x01\x03"),
        ):
            damaged = original[:offset] + replacement + original[offset + len(replacement):]
            with self.subTest(offset=offset, replacement=replacement):
                self.assertIsNone(self.decode(damaged))
        self.assertIsNone(self.decode(header_packet(options=b"\x02\x04\x05\x3c" * 2)))
        for fragments in (1, 0x2000, 0x2001, 0x8000):
            for protocol in (6, 17):
                self.assertIsNone(self.decode(header_packet(protocol=protocol, fragments=fragments, dport=51820 if protocol == 17 else 443)))
        udp = header_packet(protocol=17, dport=51820)
        for length in (0, 7, 9, 65535):
            self.assertIsNone(self.decode(udp[:24] + struct.pack("!H", length) + udp[26:]))


class HeaderCaptureTests(unittest.TestCase):
    def setUp(self):
        self.plan = {"NodeId": str(uuid.UUID(int=1234)), "DefaultInterface": "ens5",
                     "PublicEndpoint": "203.0.113.10:51820"}
        self.tunnel = tc.paths(self.plan)["Interface"]
        self.now, self.waits = 0.0, []
        self.queues = [[], []]
        self.streams = [mock.Mock(spec=["bind", "setblocking", "recvfrom", "close"]) for _ in range(2)]
        for index, stream in enumerate(self.streams):
            stream.recvfrom.side_effect = lambda size, i=index: self.queues[i].pop(0)
        def patch(target, name, **kwargs):
            patcher = mock.patch.object(target, name, **kwargs)
            self.addCleanup(patcher.stop)
            return patcher.start()
        patch(tc.socket, "AF_PACKET", new=17, create=True)
        self.create = patch(tc.socket, "socket", side_effect=self.streams)
        patch(tc.time, "monotonic", side_effect=lambda: self.now)
        self.select = patch(tc.select, "select", side_effect=self.select_packets)
        self.thread_patcher = mock.patch.object(tc.threading, "Thread")
        self.addCleanup(self.thread_patcher.stop)
        self.thread = self.thread_patcher.start()
        self.thread.return_value.is_alive.return_value = False

    def select_packets(self, readers, writers, errors, timeout):
        self.assertEqual(writers, [])
        self.assertEqual(errors, [])
        self.assertGreater(timeout, 0)
        self.assertLessEqual(timeout, 0.1)
        self.assertLessEqual(self.now + timeout, self.deadline + 1e-8)
        self.waits.append(timeout)
        ready = [stream for i, stream in enumerate(self.streams) if self.queues[i] and stream in readers]
        self.now += min(timeout, 0.001) if ready else timeout
        return ready, [], []

    def run_capture(self, seconds=1):
        self.deadline = self.now + seconds
        capture = tc.HeaderCapture(self.plan, seconds)
        capture.start()
        if capture.report["Status"] == "Running":
            capture.collect()
        return capture.finish()

    def test_socket_contract_and_both_interfaces_only_store_headers(self):
        tcp = header_packet(options=b"\x02\x04\x05\x3c", payload=b"secret-payload")
        udp = header_packet(protocol=17, dport=51820, payload=b"secret-key")
        self.queues[0] = [(tcp, ("ens5", 0x0800, 4)), (udp, ("ens5", 0x0800, 0)),
                          (header_packet(dport=22), ("ens5", 0x0800, 0))]
        self.queues[1] = [(tcp, (self.tunnel, 0x0800, 0))]
        result = self.run_capture()
        self.assertEqual(result["Status"], "Completed")
        self.assertEqual(result["MatchedPackets"], 3)
        self.assertEqual(result["OmittedPackets"], 0)
        self.assertEqual(len(result["Samples"]), 3)
        self.assertNotIn("secret", json.dumps(result))
        self.assertEqual(self.create.call_args_list, [mock.call(17, tc.socket.SOCK_DGRAM, 0)] * 2)
        for stream, interface in zip(self.streams, ("ens5", self.tunnel)):
            stream.bind.assert_called_once_with((interface, 3))
            stream.setblocking.assert_called_once_with(False)
            stream.close.assert_called_once()
            self.assertTrue(all(call.args == (120,) for call in stream.recvfrom.call_args_list))
            self.assertTrue(all(call[0] in ("bind", "setblocking", "recvfrom", "close") for call in stream.mock_calls))
        self.assertTrue(all(row["TimeUtc"].endswith("Z") and 0 <= row["OffsetMilliseconds"] < 1000 for row in result["Samples"]))
        self.assertEqual(result["ElapsedMilliseconds"], 1000)

    def test_sample_cap_keeps_counting_and_obeys_bridge_array_and_depth_limits(self):
        packet = header_packet(payload=b"key-must-not-escape")
        self.queues[0] = [(packet, ("ens5", 0x0800, 4))] * (tc.CAPTURE_LIMIT + 13)
        report = self.run_capture()
        self.assertLessEqual(tc.CAPTURE_LIMIT, 400)
        self.assertEqual(len(report["Samples"]), tc.CAPTURE_LIMIT)
        self.assertEqual(report["MatchedPackets"], tc.CAPTURE_LIMIT + 13)
        self.assertEqual(report["OmittedPackets"], 13)
        self.assertFalse(self.queues[0])
        self.assertEqual(report["Status"], "Completed")
        def bridge_contract(value, depth=0):
            self.assertLessEqual(depth, 16)
            if isinstance(value, list):
                self.assertLessEqual(len(value), 512)
            for child in value.values() if isinstance(value, dict) else value if isinstance(value, list) else []:
                bridge_contract(child, depth + 1)
        bridge_contract({"Ok": True, "Action": "status", "Data": {"NetworkProbe": {"Capture": report}}, "Message": ""})
        self.assertNotIn("key-must-not-escape", json.dumps(report))

    def test_sixty_second_idle_deadline_uses_monotonic_clock_without_real_wait(self):
        report = self.run_capture(60)
        self.assertEqual(report["Status"], "Completed")
        self.assertEqual(report["ElapsedMilliseconds"], 60000)
        self.assertEqual(report["MatchedPackets"], 0)
        self.assertLessEqual(len(self.waits), 601)
        self.assertTrue(all(not stream.recvfrom.called for stream in self.streams))

    def test_busy_unrelated_traffic_and_late_readiness_cannot_extend_deadline(self):
        self.queues[0] = [(header_packet(destination="8.8.8.8"), ("ens5", 0x0800, 4))] * 2000
        report = self.run_capture()
        self.assertEqual(report["ElapsedMilliseconds"], 1000)
        self.assertEqual(report["MatchedPackets"], 0)
        self.assertGreater(len(self.queues[0]), 0)
        self.assertLessEqual(self.streams[0].recvfrom.call_count, 1000)
        for stream in self.streams:
            stream.reset_mock()
        self.create.side_effect = self.streams
        def late(*args):
            self.now = self.deadline
            return self.streams, [], []
        self.select.side_effect = late
        result = self.run_capture()
        self.assertEqual(result["MatchedPackets"], 0)
        for stream in self.streams:
            stream.recvfrom.assert_not_called()

    def test_setup_errors_are_sanitized_and_close_partially_opened_sockets(self):
        for failure, code in ((PermissionError("secret"), "CapturePermissionDenied"),
                              (OSError("secret"), "CaptureStartFailed"),
                              (tc.TCError("secret", "private-key"), "CaptureStartFailed")):
            with self.subTest(code=code):
                self.create.side_effect = self.streams
                for stream in self.streams:
                    stream.reset_mock()
                self.streams[1].bind.side_effect = failure
                result = self.run_capture()
                self.assertEqual(result["Status"], "Failed")
                self.assertEqual(result["Code"], code)
                self.assertNotIn("secret", json.dumps(result))
                self.assertNotIn("private-key", json.dumps(result))
                for stream in self.streams:
                    stream.close.assert_called_once()
        self.thread.assert_not_called()

    def test_missing_packet_family_does_not_open_any_socket(self):
        family = tc.socket.AF_PACKET
        del tc.socket.AF_PACKET
        try:
            result = self.run_capture()
        finally:
            tc.socket.AF_PACKET = family
        self.assertEqual(result["Code"], "CaptureUnsupported")
        self.assertEqual(result["Status"], "Failed")
        self.create.assert_not_called()

    def test_read_and_close_failures_do_not_report_completed(self):
        self.queues[0] = [(header_packet(), ("ens5", 0x0800, 4))]
        self.streams[0].recvfrom.side_effect = OSError("secret-payload")
        result = self.run_capture()
        self.assertEqual(result["Code"], "CaptureReadFailed")
        self.assertEqual(result["Status"], "Failed")
        self.assertNotIn("secret", json.dumps(result))
        for stream in self.streams:
            stream.close.assert_called_once()
        self.queues[0] = []
        self.create.side_effect = self.streams
        self.streams[1].close.side_effect = OSError("secret-key")
        result = self.run_capture()
        self.assertEqual(result["Code"], "CaptureCloseFailed")
        self.assertEqual(result["Status"], "Failed")
        self.assertNotIn("secret", json.dumps(result))

    def test_worker_start_and_join_failures_are_not_silent_success(self):
        self.thread.return_value.start.side_effect = RuntimeError("private-key")
        result = self.run_capture()
        self.assertEqual(result["Code"], "CaptureStartFailed")
        self.assertNotIn("private-key", json.dumps(result))
        self.create.side_effect = self.streams
        self.thread.return_value.start.side_effect = None
        self.thread.return_value.is_alive.return_value = True
        capture = tc.HeaderCapture(self.plan, 60)
        capture.start()
        self.now += 60
        result = capture.finish()
        self.assertEqual(result["Code"], "CaptureDeadlineExceeded")
        self.assertEqual(result["Status"], "Failed")
        self.assertTrue(capture.stop.is_set())
        self.assertFalse(capture.sockets)
        self.assertLessEqual(self.thread.return_value.join.call_args.args[0], 0.5)
        capture.report["Samples"].append({"Late": True})
        self.assertEqual(result["Samples"], [])
        self.create.side_effect = self.streams
        self.thread.return_value.join.side_effect = RuntimeError("private-key")
        capture = tc.HeaderCapture(self.plan, 1)
        capture.start()
        result = capture.finish()
        self.assertEqual(result["Status"], "Failed")
        self.assertEqual(result["Code"], "CaptureFinishFailed")
        self.assertNotIn("private-key", json.dumps(result))
        self.assertTrue(capture.stop.is_set())
        self.assertFalse(capture.sockets)

    def test_capture_spans_probe_and_expires_during_slow_https_with_real_worker(self):
        self.thread_patcher.stop()
        https_started, capture_closed = tc.threading.Event(), tc.threading.Event()
        self.streams[1].close.side_effect = capture_closed.set
        self.deadline = 1
        self.queues[0] = [(header_packet(), ("ens5", 0x0800, 4))]
        def gated_select(*args):
            self.assertTrue(https_started.wait(1))
            return self.select_packets(*args)
        self.select.side_effect = gated_select
        runner = tc.LinuxOS()
        def telemetry(*unused):
            for stream in self.streams:
                self.assertTrue(stream.bind.called)
            return [{"ReceiveBytes": 30 if capture_closed.is_set() else 10, "TransmitBytes": 40}]
        def https():
            https_started.set()
            self.assertTrue(capture_closed.wait(1), "Capture must expire independently of the HTTPS operation")
            return {"Ok": True}
        with mock.patch.object(runner, "guard"), mock.patch.object(runner, "peer_telemetry", side_effect=telemetry), \
             mock.patch.object(runner, "forward_route", return_value={}), mock.patch.object(runner, "direct_https", side_effect=https):
            result = runner.network_probe(self.plan, {}, 1, lambda _: None, capture_seconds=1)
        self.assertTrue(result["Ok"], result)
        self.assertEqual(result["WireGuardBefore"]["Data"][0]["ReceiveBytes"], 10)
        self.assertEqual(result["WireGuardAfter"]["Data"][0]["ReceiveBytes"], 30)
        self.assertEqual(result["Capture"]["MatchedPackets"], 1)
        self.assertEqual(result["Capture"]["ElapsedMilliseconds"], 1000)
        for stream in self.streams:
            stream.close.assert_called_once()


class UdpPortProbeTests(unittest.TestCase):
    def setUp(self):
        self.plan = {"PublicEndpoint": "203.0.113.10:51820"}
        self.source = "1.1.1.1"
        self.now, self.events = 0.0, []
        self.streams = [mock.Mock(spec=["bind", "connect", "setblocking", "recvfrom", "send", "sendto", "close"])
                        for _ in range(2)]
        for i, stream in enumerate(self.streams):
            stream.recvfrom.side_effect = lambda size, index=i: self.receive(size, index)
            stream.send.side_effect = len
            stream.sendto.side_effect = lambda packet, address: len(packet)
        def patch(target, name, **kwargs):
            patcher = mock.patch.object(target, name, **kwargs)
            self.addCleanup(patcher.stop)
            return patcher.start()
        self.create = patch(tc.socket, "socket", side_effect=self.streams)
        patch(tc.time, "monotonic", side_effect=lambda: self.now)
        self.select = patch(tc.select, "select", side_effect=self.ready)
        self.thread_patcher = mock.patch.object(tc.threading, "Thread")
        self.addCleanup(self.thread_patcher.stop)
        self.thread = self.thread_patcher.start()
        self.thread.return_value.is_alive.return_value = False

    @staticmethod
    def packet(kind=1, length=148):
        return kind.to_bytes(4, "little") + (b"private-wireguard-payload" * 3000)[:length - 4]

    def receive(self, size, index):
        self.assertEqual(size, 65508)
        selected, packet, address = self.events.pop(0)
        self.assertEqual(index, selected)
        return packet, address

    def ready(self, readers, writers, errors, timeout):
        self.assertEqual(writers, [])
        self.assertEqual(errors, [])
        self.assertTrue(0 < timeout <= 0.1)
        self.assertLessEqual(self.now + timeout, self.deadline + 1e-8)
        self.now += min(timeout, 0.001) if self.events else timeout
        return ([self.streams[self.events[0][0]]] if self.events else []), [], []

    def run_probe(self, seconds=1):
        self.deadline = self.now + seconds
        self.probe = tc.UdpPortProbe(self.plan, seconds, self.source)
        self.probe.start(self.deadline)
        if self.probe.report["Status"] == "Running":
            self.probe.forward()
        return self.probe.finish()

    def test_wireguard_framing_accepts_only_known_types_and_exact_handshake_lengths(self):
        for kind, length in ((1, 148), (2, 92), (3, 64), (4, 32), (4, 1412), (4, 65507)):
            with self.subTest(kind=kind, length=length):
                self.assertTrue(tc.wireguard_datagram(self.packet(kind, length)))
                if kind != 4:
                    self.assertFalse(tc.wireguard_datagram(self.packet(kind, length - 1)))
                    self.assertFalse(tc.wireguard_datagram(self.packet(kind, length + 1)))
        for packet in (b"", b"\x01", b"\x04\x00\x00", b"SSH-2.0", self.packet(0), self.packet(5),
                       self.packet(0x101), self.packet(4, 31), self.packet(4, 65508)):
            self.assertFalse(tc.wireguard_datagram(packet))

    def test_only_public_canonical_single_ipv4_is_accepted(self):
        self.assertEqual(tc.probe_source_ipv4(self.source), self.source)
        for value in (None, True, 171, [], {}, "", "localhost", "1.1.1.1/32", "001.001.001.001",
                      " 1.1.1.1", "1.1.1.1:1234", "::1", "0.0.0.0", "127.0.0.1",
                      "10.0.0.1", "172.16.0.1", "192.168.1.1", "169.254.1.2", "100.64.0.1",
                      "192.0.2.1", "198.51.100.1", "203.0.113.1", "224.0.0.1", "255.255.255.255", "240.0.0.1"):
            with self.subTest(value=value), self.assertRaises(tc.TCError) as error:
                tc.UdpPortProbe(self.plan, 1, value)
            self.assertEqual(error.exception.code, "InvalidInput")
        for seconds in (0, 61, True, "1"):
            with self.assertRaises(tc.TCError):
                tc.UdpPortProbe(self.plan, seconds, self.source)
        self.create.assert_not_called()

    def test_fixed_bind_target_and_nat_port_changes_with_counters_only(self):
        first, second, response = self.packet(), self.packet(4, 32), self.packet(2, 92)
        self.events = [(0, first, (self.source, 41000)), (1, response, ("127.0.0.1", 51820)),
                       (0, second, (self.source, 42000)), (1, response, ("127.0.0.1", 51820))]
        result = self.run_probe()
        public, upstream = self.streams
        self.assertEqual(self.create.call_args_list, [mock.call(tc.socket.AF_INET, tc.socket.SOCK_DGRAM)] * 2)
        public.bind.assert_called_once_with(("0.0.0.0", 443))
        upstream.bind.assert_called_once_with(("127.0.0.1", 0))
        upstream.connect.assert_called_once_with(("127.0.0.1", 51820))
        self.assertEqual(upstream.send.call_args_list, [mock.call(first), mock.call(second)])
        self.assertEqual(public.sendto.call_args_list, [mock.call(response, (self.source, 41000)),
                                                       mock.call(response, (self.source, 42000))])
        public.send.assert_not_called()
        upstream.sendto.assert_not_called()
        self.assertEqual(result["ToWireGuardPackets"], 2)
        self.assertEqual(result["ToWireGuardBytes"], 180)
        self.assertEqual(result["ToClientPackets"], 2)
        self.assertEqual(result["ToClientBytes"], 184)
        self.assertEqual(result["Status"], "Completed")
        self.assertTrue(result["Temporary"] and result["Started"] and result["Stopped"])
        self.assertFalse(result["PersistentConfigChanged"])
        self.assertNotIn("private-wireguard", json.dumps(result))
        self.assertFalse(any(isinstance(v, (list, bytes)) for v in result.values()))
        for stream in self.streams:
            stream.setblocking.assert_called_once_with(False)
            stream.close.assert_called_once()
        self.assertFalse(self.probe.sockets)

    def test_source_and_wireguard_validation_on_both_sides_prevent_reply_redirection(self):
        response = self.packet(2, 92)
        self.events = [(1, response, ("127.0.0.1", 51820)),  # No client yet.
                       (0, self.packet(), ("1.0.0.1", 40000)),
                       (0, self.packet(), (self.source, 0)),
                       (0, self.packet(), (self.source, 41000)),
                       (0, b"SSH-private", (self.source, 42000)),
                       (0, self.packet(1, 147), (self.source, 42000)),
                       (1, response, ("127.0.0.2", 51820)),
                       (1, response, ("127.0.0.1", 443)),
                       (1, self.packet(2, 91), ("127.0.0.1", 51820)),
                       (1, response, ("127.0.0.1", 51820))]
        result = self.run_probe()
        self.assertEqual(result["RejectedSourcePackets"], 4)
        self.assertEqual(result["RejectedWireGuardPackets"], 3)
        self.assertEqual(result["ToWireGuardPackets"], 1)
        self.assertEqual(result["ToClientPackets"], 1)
        self.streams[0].sendto.assert_called_once_with(response, (self.source, 41000))
        self.assertNotIn("SSH", json.dumps(result))

    def test_port_in_use_never_reuses_or_displaces_existing_listener(self):
        self.streams[0].bind.side_effect = OSError(tc.errno.EADDRINUSE, "private existing owner")
        with mock.patch.object(tc.subprocess, "Popen", side_effect=AssertionError("No process commands")) as spawn:
            result = self.run_probe()
        self.assertEqual(result["Status"], "Failed")
        self.assertEqual(result["Code"], "UdpPortProbePortInUse")
        self.assertFalse(result["Started"])
        self.assertTrue(result["Stopped"])
        self.create.assert_called_once_with(tc.socket.AF_INET, tc.socket.SOCK_DGRAM)
        self.streams[0].close.assert_called_once()
        self.assertEqual(self.streams[1].mock_calls, [])
        self.thread.assert_not_called()
        spawn.assert_not_called()
        self.assertNotIn("private", json.dumps(result))

    def test_sixty_second_idle_window_and_busy_traffic_both_stop_at_deadline(self):
        result = self.run_probe(60)
        self.assertEqual(result["ElapsedMilliseconds"], 60000)
        self.assertEqual(result["Status"], "Completed")
        for stream in self.streams:
            stream.close.assert_called_once()
            stream.reset_mock()
        self.create.side_effect = self.streams
        self.events = [(0, self.packet(4, 32), (self.source, 41000))] * 2000
        result = self.run_probe()
        self.assertEqual(result["ElapsedMilliseconds"], 1000)
        self.assertTrue(0 < result["ToWireGuardPackets"] <= 1000)
        self.assertGreater(len(self.events), 0)
        self.assertTrue(result["Stopped"])
        for stream in self.streams:
            stream.close.assert_called_once()

    def test_late_readiness_and_expired_start_never_forward(self):
        def late(*args):
            self.now = self.deadline
            return self.streams, [], []
        self.select.side_effect = late
        result = self.run_probe()
        self.assertEqual(result["ToWireGuardPackets"], 0)
        for stream in self.streams:
            stream.recvfrom.assert_not_called()
            stream.send.assert_not_called()
            stream.sendto.assert_not_called()
        self.create.reset_mock()
        probe = tc.UdpPortProbe(self.plan, 1, self.source)
        probe.start(self.now)
        self.assertEqual(probe.finish()["Code"], "UdpPortProbeDeadlineExceeded")
        self.create.assert_not_called()

    def test_start_io_close_and_thread_errors_close_sockets_and_hide_exception_text(self):
        public, upstream = self.streams
        for target, name, code in ((upstream, "connect", "UdpPortProbeStartFailed"),
                                   (self.thread.return_value, "start", "UdpPortProbeStartFailed"),
                                   (public, "recvfrom", "UdpPortProbeIoFailed"),
                                   (upstream, "send", "UdpPortProbeIoFailed"),
                                   (public, "close", "UdpPortProbeCloseFailed")):
            with self.subTest(stage=name):
                self.create.side_effect = self.streams
                for stream in self.streams:
                    stream.reset_mock()
                self.events = [(0, self.packet(), (self.source, 41000))]
                with mock.patch.object(target, name, side_effect=OSError("private-payload")):
                    result = self.run_probe()
                    for stream in self.streams:
                        stream.close.assert_called_once()
                self.assertEqual(result["Status"], "Failed")
                self.assertEqual(result["Code"], code)
                self.assertNotIn("private", json.dumps(result))
        self.create.side_effect = self.streams
        probe = tc.UdpPortProbe(self.plan, 1, self.source)
        probe.start(self.now + 1)
        self.thread.return_value.join.side_effect = RuntimeError("private-payload")
        result = probe.finish()
        self.assertEqual(result["Code"], "UdpPortProbeFinishFailed")
        self.assertTrue(probe.stop.is_set())
        self.assertFalse(probe.sockets)
        self.assertNotIn("private", json.dumps(result))

    def test_stuck_worker_is_cancelled_and_all_sockets_closed_with_bounded_join(self):
        probe = tc.UdpPortProbe(self.plan, 60, self.source)
        probe.start(60)
        self.now = 60
        self.thread.return_value.is_alive.return_value = True
        result = probe.finish()
        self.assertEqual(result["Code"], "UdpPortProbeDeadlineExceeded")
        self.assertEqual(self.thread.return_value.join.call_args_list, [mock.call(0.5), mock.call(0.2)])
        self.assertTrue(probe.stop.is_set() and result["Stopped"])
        for stream in self.streams:
            stream.close.assert_called_once()
        probe.report["ToClientPackets"] = 100
        self.assertEqual(result["ToClientPackets"], 0)

    def test_probe_exception_cancels_real_worker_and_closes_all_sockets(self):
        self.thread_patcher.stop()
        released = tc.threading.Event()
        def wait_for_progress(*args):
            self.assertTrue(released.wait(1))
            return [], [], []
        self.select.side_effect = wait_for_progress
        capture = mock.Mock()
        capture.report = {"Status": "Running"}
        capture.deadline = 60
        capture.stop = tc.threading.Event()
        capture.finish.return_value = {"Status": "Failed"}
        runner = tc.LinuxOS()
        def progress(message):
            released.set()
            raise RuntimeError("private callback")
        with mock.patch.object(tc, "HeaderCapture", return_value=capture), \
             mock.patch.object(runner, "guard"), mock.patch.object(runner, "peer_telemetry", return_value=[]), \
             mock.patch.object(runner, "forward_route", return_value={}):
            with self.assertRaises(RuntimeError):
                runner.network_probe(self.plan, {}, 1, progress, capture_seconds=60,
                                     probe_relay_port=443, probe_source_ipv4=self.source)
        self.assertTrue(capture.stop.is_set())
        capture.finish.assert_called_once()
        for stream in self.streams:
            stream.close.assert_called_once()


class BackendTests(unittest.TestCase):
    def setUp(self):
        self.fs = MemoryFS()
        self.os = FakeOS(self.fs)
        self.time = dt.datetime(2026, 10, 4, 2, tzinfo=dt.timezone.utc)
        self.backend = tc.Backend(self.fs, self.os, now=lambda: self.time, progress=lambda _: None)

    def call(self, action, value=None, ok=True):
        result = tc.envelope(action, {} if value is None else value, self.backend)
        self.assertEqual(result["Ok"], ok, result)
        self.assertEqual(set(result), {"Ok", "Action", "Data", "Message"})
        self.assertEqual(result["Action"], action)
        return result["Data"]

    def plan(self):
        result = self.call("plan", plan_input())
        self.plan_id = result["PlanId"]
        self.plan_data = self.backend.load_plan(self.plan_id, self.os.probe())
        self.paths = tc.paths(self.plan_data)
        return result

    def apply(self):
        self.plan()
        return self.call("apply", {"PlanId": self.plan_id})

    def pending_initial_apply(self):
        self.plan()
        self.os.crash = lambda argv: argv == ["systemctl", "start", self.paths["TunnelUnit"]]
        with self.assertRaises(Crash):
            self.backend.apply({"PlanId": self.plan_id})
        self.os.env["Nft"] = captured_nft(self.plan_data)
        tx = json.loads(self.fs.files[tc.ACTIVE])
        tx.update(Phase="NeedsRecovery", FailureCode="FirewallDrift", RecoveryCode="OwnershipMismatch")
        self.fs.files[tc.ACTIVE] = tc.dumps(tx)
        return tx

    def test_inspection_and_status_are_readonly_and_report_support(self):
        result = self.call("inspect")
        self.assertTrue(result["Supported"])
        self.assertEqual(result["Issues"], [])
        self.assertIn("Summary", result)
        self.assertEqual(self.call("status")["Status"], "NotInstalled")
        self.assertFalse(self.fs.mutations)
        self.assertFalse(self.os.calls)
        self.apply()
        writes, commands = len(self.fs.mutations), len(self.os.calls)
        self.assertTrue(self.call("inspect")["Supported"])
        self.assertEqual(self.call("status")["Status"], "Applied")
        self.assertEqual(len(self.fs.mutations), writes)
        self.assertTrue(all(call == ["wg", "pubkey"] for call in self.os.calls[commands:]))

    def test_network_status_is_opt_in_bounded_and_does_not_mutate_state(self):
        self.apply()
        writes = len(self.fs.mutations)
        with mock.patch.object(self.os, "network_probe", create=True, return_value={"ServerHttps": [{"Ok": False, "Code": "Timeout"}]}) as probe:
            self.call("status")
            probe.assert_not_called()
            result = self.call("status", {"NetworkProbe": True, "ProbeRepeats": 2})
            self.assertEqual(probe.call_args.args[2], 2)
            self.assertEqual(result["NetworkProbe"]["Forwarding"], "1")
            self.assertEqual(result["Validation"]["ExternalConnectivity"], "NotTested")
        self.assertEqual(len(self.fs.mutations), writes)
        for value in ({"NetworkProbe": "true"}, {"NetworkProbe": True, "ProbeRepeats": 4},
                      {"NetworkProbe": True, "ProbeRepeats": True}, {"ProbeRepeats": 1}):
            self.assertEqual(self.call("status", value, ok=False)["Code"], "InvalidInput")

    def test_wg_telemetry_maps_only_owned_keys_to_device_ids(self):
        self.plan()
        runner = tc.LinuxOS()
        peer = request()
        manifest = {"Peers": [{"ClientPublicKey": peer["ClientPublicKey"], "DeviceId": peer["DeviceId"], "ClientAddress": "10.78.0.2/32"}]}
        with mock.patch.object(runner, "run", side_effect=[peer["ClientPublicKey"] + " 123 456", peer["ClientPublicKey"] + " 1791079320"]) as run:
            result = runner.peer_telemetry(self.plan_data, manifest)
        self.assertEqual(result, [{"DeviceId": peer["DeviceId"], "ClientAddress": "10.78.0.2/32", "ReceiveBytes": 123,
                                   "TransmitBytes": 456, "LatestHandshakeUnix": 1791079320}])
        self.assertNotIn(peer["ClientPublicKey"], json.dumps(result))
        self.assertEqual([c.args[0][-1] for c in run.call_args_list], ["transfer", "latest-handshakes"])
        with mock.patch.object(runner, "run", side_effect=[public_key("foreign") + " 1 2", public_key("foreign") + " 0"]):
            with self.assertRaises(tc.TCError):
                runner.peer_telemetry(self.plan_data, manifest)

    def test_capture_input_constraints_reject_before_os_access_for_every_action(self):
        invalid = [{"NetworkProbe": True, "CaptureSeconds": value}
                   for value in (-1, 61, True, False, "1", 1.5, None, [], {})]
        invalid += [{"CaptureSeconds": 0}, {"CaptureSeconds": 1},
                    {"NetworkProbe": False, "CaptureSeconds": 0}, {"NetworkProbe": False, "CaptureSeconds": 60}]
        valid_inputs = {"inspect": {}, "plan": plan_input(), "apply": {"PlanId": str(uuid.UUID(int=7))},
                        "finalize": {"PlanId": str(uuid.UUID(int=7))}, "authorize": {"ClientRequest": request()},
                        "revoke": {"DeviceId": request()["DeviceId"]}, "recover": {}, "uninstall": {}}
        with mock.patch.object(self.os, "probe", side_effect=AssertionError("Invalid input must not inspect the OS")):
            for value in invalid:
                with self.subTest(value=value):
                    self.assertEqual(self.call("status", value, ok=False)["Code"], "InvalidInput")
            for action, value in valid_inputs.items():
                for seconds in (0, 1, 60):
                    with self.subTest(action=action, seconds=seconds):
                        self.assertEqual(self.call(action, dict(value, CaptureSeconds=seconds), ok=False)["Code"], "InvalidInput")
        self.assertFalse(self.fs.mutations)
        self.assertFalse(self.os.calls)

    def test_capture_zero_preserves_old_os_adapter_and_default_probe_schema(self):
        self.apply()
        runner = tc.LinuxOS()
        def old_adapter(plan, manifest, repeats, progress):
            return runner.network_probe(plan, manifest, repeats, progress)
        with mock.patch.object(self.os, "network_probe", create=True, side_effect=old_adapter), \
             mock.patch.object(runner, "guard"), mock.patch.object(runner, "peer_telemetry", return_value=[]), \
             mock.patch.object(runner, "forward_route", return_value={}), \
             mock.patch.object(runner, "direct_https", return_value={"Ok": False, "Code": "Timeout"}) as https, \
             mock.patch.object(tc, "HeaderCapture") as capture, mock.patch.object(tc, "UdpPortProbe") as relay, \
             mock.patch.object(tc.socket, "socket") as sockets:
            ordinary = self.call("status", {"NetworkProbe": True})["NetworkProbe"]
            disabled = self.call("status", {"NetworkProbe": True, "CaptureSeconds": 0})["NetworkProbe"]
            relay_disabled = self.call("status", {"NetworkProbe": True, "ProbeRelayPort": 0})["NetworkProbe"]
            https.side_effect = OSError("unexpected close failure")
            with self.assertRaises(OSError):
                runner.network_probe(self.plan_data, {}, 1, lambda _: None)
        self.assertEqual(ordinary, disabled)
        self.assertEqual(ordinary, relay_disabled)
        self.assertNotIn("UdpPortProbe", relay_disabled)
        self.assertEqual(disabled["Capture"], {"Status": "NotIncluded"})
        self.assertNotIn("Ok", disabled)
        self.assertEqual(disabled["SchemaVersion"], 1)
        capture.assert_not_called()
        relay.assert_not_called()
        sockets.assert_not_called()

    def test_udp_probe_parameters_are_status_only_require_capture_and_cannot_change_target(self):
        valid = {"NetworkProbe": True, "CaptureSeconds": 1, "ProbeRelayPort": 443, "ProbeSourceIPv4": "1.1.1.1"}
        invalid = [dict(valid, ProbeRelayPort=port) for port in (True, False, "443", 443.0, -1, 80, 51820, None)]
        invalid += [dict(valid, CaptureSeconds=0), dict(valid, NetworkProbe=False),
                    {k: v for k, v in valid.items() if k != "ProbeSourceIPv4"},
                    {k: v for k, v in valid.items() if k != "CaptureSeconds"},
                    {"ProbeRelayPort": 0}, {"NetworkProbe": True, "ProbeSourceIPv4": valid["ProbeSourceIPv4"]},
                    dict(valid, ProbeRelayPort=0), dict(valid, ProbeSourceIPv4=None),
                    dict(valid, ProbeSourceIPv4="127.0.0.1"),
                    dict(valid, ProbeTarget="8.8.8.8:53"), dict(valid, ProbeTargetPort=80),
                    dict(valid, ProbeListenAddress="127.0.0.1"), dict(valid, ProbeDestinationIPv4="8.8.8.8")]
        actions = {"inspect": {}, "plan": plan_input(), "apply": {"PlanId": str(uuid.UUID(int=7))},
                   "finalize": {"PlanId": str(uuid.UUID(int=7))}, "authorize": {"ClientRequest": request()},
                   "revoke": {"DeviceId": request()["DeviceId"]}, "recover": {}, "uninstall": {}}
        with mock.patch.object(self.os, "probe", side_effect=AssertionError("No OS access for invalid parameters")), \
             mock.patch.object(tc.socket, "socket", side_effect=AssertionError("No sockets for invalid parameters")):
            for value in invalid:
                with self.subTest(value=value):
                    self.assertEqual(self.call("status", value, ok=False)["Code"], "InvalidInput")
            for action, value in actions.items():
                for option in ({"ProbeRelayPort": 0}, {"ProbeRelayPort": 443}, {"ProbeSourceIPv4": valid["ProbeSourceIPv4"]}):
                    with self.subTest(action=action, option=option):
                        self.assertEqual(self.call(action, dict(value, **option), ok=False)["Code"], "InvalidInput")
        self.assertFalse(self.fs.mutations)
        self.assertFalse(self.os.calls)

    def test_udp_probe_status_shares_capture_deadline_and_only_uses_existing_read_commands(self):
        self.apply()
        runner = tc.LinuxOS()
        interface, peer = self.paths["Interface"], request()["ClientPublicKey"]
        commands = {("wg", "show", interface, "transfer"): peer + " 123 456",
                    ("wg", "show", interface, "latest-handshakes"): peer + " 1791079320",
                    ("ip", "-j", "-4", "route", "get", "1.1.1.1", "from", "10.78.0.2", "iif", interface): "[]"}
        events = []
        capture, relay = mock.Mock(), mock.Mock()
        capture.report, capture.deadline = {"Status": "Running"}, 12345.0
        capture.start.side_effect = lambda: events.append("capture-start")
        capture.finish.side_effect = lambda: events.append("capture-finish") or {"Status": "Completed"}
        relay.start.side_effect = lambda deadline: events.append(("relay-start", deadline))
        relay.finish.side_effect = lambda: events.append("relay-finish") or {
            "Status": "Completed", "Temporary": True, "PersistentConfigChanged": False,
            "Started": True, "Stopped": True, "ToWireGuardPackets": 5, "ToClientPackets": 4}
        def run(argv, **unused):
            events.append(tuple(argv))
            self.assertIn(tuple(argv), commands, "Only existing WG telemetry/route reads are permitted")
            return commands[tuple(argv)]
        before = copy.deepcopy((self.fs.files, self.fs.links, self.fs.modes, self.os.env, self.os.tunnels, self.os.running))
        writes, calls, installs = len(self.fs.mutations), len(self.os.calls), self.os.install_count
        with mock.patch.object(self.os, "network_probe", create=True, side_effect=runner.network_probe), \
             mock.patch.object(runner, "guard"), mock.patch.object(runner, "run", side_effect=run), \
             mock.patch.object(runner, "direct_https", return_value={"Ok": True}), \
             mock.patch.object(tc, "HeaderCapture", return_value=capture), \
             mock.patch.object(tc, "UdpPortProbe", return_value=relay) as factory, \
             mock.patch.object(tc.socket, "socket", side_effect=AssertionError("No actual networking")), \
             mock.patch.object(tc.subprocess, "Popen", side_effect=AssertionError("No actual commands")):
            result = self.call("status", {"NetworkProbe": True, "CaptureSeconds": 60,
                                          "ProbeRelayPort": 443, "ProbeSourceIPv4": "1.1.1.1"})
        factory.assert_called_once_with(self.plan_data, 60, "1.1.1.1")
        relay.start.assert_called_once_with(capture.deadline)
        self.assertEqual(events[:2], ["capture-start", ("relay-start", capture.deadline)])
        self.assertEqual(events[-4:-2], ["capture-finish", "relay-finish"])
        report = result["NetworkProbe"]["UdpPortProbe"]
        self.assertTrue(report["Temporary"] and report["Stopped"])
        self.assertFalse(report["PersistentConfigChanged"])
        self.assertEqual(report["ToWireGuardPackets"], 5)
        self.assertEqual(before, (self.fs.files, self.fs.links, self.fs.modes, self.os.env, self.os.tunnels, self.os.running))
        self.assertEqual(len(self.fs.mutations), writes)
        self.assertEqual(self.os.install_count, installs)
        self.assertTrue(all(argv == ["wg", "pubkey"] for argv in self.os.calls[calls:]))

    def test_udp_probe_failure_is_visible_and_capture_failure_prevents_binding(self):
        self.apply()
        runner = tc.LinuxOS()
        capture, relay = mock.Mock(), mock.Mock()
        capture.deadline = 12345.0
        value = {"NetworkProbe": True, "CaptureSeconds": 1, "ProbeRelayPort": 443, "ProbeSourceIPv4": "1.1.1.1"}
        with mock.patch.object(self.os, "network_probe", create=True, side_effect=runner.network_probe), \
             mock.patch.object(runner, "guard"), mock.patch.object(runner, "peer_telemetry", return_value=[]), \
             mock.patch.object(runner, "forward_route", return_value={}), \
             mock.patch.object(runner, "direct_https", return_value={"Ok": True}), \
             mock.patch.object(tc, "HeaderCapture", return_value=capture), \
             mock.patch.object(tc, "UdpPortProbe", return_value=relay):
            for failed in ("relay", "capture"):
                with self.subTest(failed=failed):
                    relay.reset_mock()
                    capture.report = {"Status": "Running" if failed == "relay" else "Failed"}
                    capture.finish.return_value = {"Status": "Completed" if failed == "relay" else "Failed"}
                    relay.finish.return_value = {"Status": "Failed", "Temporary": True, "PersistentConfigChanged": False,
                                                "Code": "UdpPortProbePortInUse" if failed == "relay" else "UdpPortProbeCaptureUnavailable"}
                    result = self.call("status", value, ok=False)
                    self.assertEqual(result["Code"], "NetworkProbeFailed")
                    self.assertFalse(result["NetworkProbe"]["Ok"])
                    self.assertEqual(result["NetworkProbe"]["UdpPortProbe"], relay.finish.return_value)
                    self.assertIn("WireGuardAfter", result["NetworkProbe"])
                    if failed == "capture":
                        relay.start.assert_not_called()
                        relay.fail.assert_called_once_with("UdpPortProbeCaptureUnavailable")
                    relay.finish.assert_called_once()

    def test_capture_status_brackets_read_operations_and_never_runs_mutating_commands(self):
        self.apply()
        runner = tc.LinuxOS()
        interface = self.paths["Interface"]
        peer = request()["ClientPublicKey"]
        events = []
        transfer_count = [0]
        def command(argv, **unused):
            events.append(tuple(argv))
            if argv == ["wg", "show", interface, "transfer"]:
                transfer_count[0] += 1
                return peer + " %d 456" % (100 * transfer_count[0])
            if argv == ["wg", "show", interface, "latest-handshakes"]:
                return peer + " 1791079320"
            if argv == ["ip", "-j", "-4", "route", "get", "1.1.1.1", "from", "10.78.0.2", "iif", interface]:
                return '[{"dst":"1.1.1.1","dev":"ens5"}]'
            self.fail("Non-read command: " + repr(argv))
        def https():
            events.append("https")
            return {"Ok": True}
        capture = mock.Mock()
        capture.start.side_effect = lambda: events.append("capture-start")
        def finish():
            events.append("capture-finish")
            return {"Status": "Completed", "SampleLimit": 400, "Samples": []}
        capture.finish.side_effect = finish
        before = copy.deepcopy((self.fs.files, self.fs.links, self.fs.modes, self.os.env, self.os.tunnels, self.os.running))
        writes, commands, installs = len(self.fs.mutations), len(self.os.calls), self.os.install_count
        with mock.patch.object(self.os, "network_probe", create=True, side_effect=runner.network_probe), \
             mock.patch.object(runner, "guard"), mock.patch.object(runner, "run", side_effect=command), \
             mock.patch.object(runner, "direct_https", side_effect=https), \
             mock.patch.object(tc, "HeaderCapture", return_value=capture) as factory, \
             mock.patch.object(tc.subprocess, "Popen", side_effect=AssertionError("No real commands")), \
             mock.patch.object(tc.socket, "socket", side_effect=AssertionError("No real sockets")):
            for seconds in (1, 60):
                events.clear()
                result = self.call("status", {"NetworkProbe": True, "ProbeRepeats": 2, "CaptureSeconds": seconds})
                self.assertEqual(factory.call_args.args[1], seconds)
                report = result["NetworkProbe"]
                self.assertTrue(report["Ok"])
                self.assertEqual(report["Capture"]["Status"], "Completed")
                self.assertEqual(report["WireGuardAfter"]["Data"][0]["ReceiveBytes"] -
                                 report["WireGuardBefore"]["Data"][0]["ReceiveBytes"], 100)
                self.assertEqual(events[0], "capture-start")
                self.assertEqual(events[-3], "capture-finish")
                self.assertEqual(events.count("https"), 2)
                self.assertNotIn(peer, json.dumps(report))
                self.assertEqual(result["Validation"]["ExternalConnectivity"], "NotTested")
        self.assertEqual(before, (self.fs.files, self.fs.links, self.fs.modes, self.os.env, self.os.tunnels, self.os.running))
        self.assertEqual(len(self.fs.mutations), writes)
        self.assertEqual(self.os.install_count, installs)
        self.assertTrue(all(argv == ["wg", "pubkey"] for argv in self.os.calls[commands:]))

    def test_capture_or_probe_failures_keep_diagnostics_but_status_is_not_success(self):
        self.apply()
        runner = tc.LinuxOS()
        capture = mock.Mock()
        with mock.patch.object(self.os, "network_probe", create=True, side_effect=runner.network_probe), \
             mock.patch.object(runner, "guard"), mock.patch.object(runner, "peer_telemetry", return_value=[]) as telemetry, \
             mock.patch.object(runner, "forward_route", return_value={}) as route, \
             mock.patch.object(runner, "direct_https", return_value={"Ok": True}) as https, \
             mock.patch.object(tc, "HeaderCapture", return_value=capture):
            for failed in ("capture", "telemetry", "route", "https", "https_exception"):
                with self.subTest(failed=failed):
                    capture.finish.return_value = {"Status": "Failed", "Code": "CaptureReadFailed"} if failed == "capture" else {"Status": "Completed"}
                    telemetry.side_effect = OSError("private telemetry") if failed == "telemetry" else None
                    route.side_effect = OSError("private route") if failed == "route" else None
                    https.side_effect = OSError("private https") if failed == "https_exception" else None
                    https.return_value = {"Ok": False, "Code": "Timeout"} if failed == "https" else {"Ok": True}
                    result = self.call("status", {"NetworkProbe": True, "CaptureSeconds": 1}, ok=False)
                    self.assertEqual(result["Code"], "NetworkProbeFailed")
                    self.assertFalse(result["NetworkProbe"]["Ok"])
                    self.assertIn("WireGuardBefore", result["NetworkProbe"])
                    self.assertIn("WireGuardAfter", result["NetworkProbe"])
                    self.assertEqual(result["NetworkProbe"]["Forwarding"], "1")
                    self.assertNotIn("private", json.dumps(result))
                    output = io.StringIO()
                    code = tc.main(["status", "--input", "-"],
                                   stdin=io.StringIO('{"NetworkProbe":true,"CaptureSeconds":1}'),
                                   stdout=output, backend=self.backend)
                    self.assertEqual(code, 1)
                    self.assertFalse(json.loads(output.getvalue())["Ok"])

    def test_forwarding_route_probe_uses_exact_client_and_interface(self):
        self.plan()
        runner = tc.LinuxOS()
        with mock.patch.object(runner, "run", return_value='[{"dst":"1.1.1.1","dev":"ens5","gateway":"172.31.0.1"}]') as run:
            report = runner.forward_route(self.plan_data)
        self.assertEqual(run.call_args.args[0], ["ip", "-j", "-4", "route", "get", "1.1.1.1", "from", "10.78.0.2", "iif", self.paths["Interface"]])
        self.assertEqual(report["Routes"][0]["dev"], "ens5")

    def test_direct_https_has_fixed_destination_verified_tls_and_no_body(self):
        runner = tc.LinuxOS()
        stream = mock.Mock()
        stream.getsockname.return_value = ("192.0.2.10", 43123)
        stream.recv.side_effect = [bytes([b]) for b in b"HTTP/1.1 200 OK\r\n"]
        context = mock.Mock()
        context.wrap_socket.return_value = stream
        with mock.patch.object(runner, "guard"), mock.patch.object(tc.socket, "socket", return_value=stream) as create, \
             mock.patch.object(tc.ssl, "create_default_context", return_value=context):
            report = runner.direct_https()
        create.assert_called_once_with(tc.socket.AF_INET, tc.socket.SOCK_STREAM)
        stream.connect.assert_called_once_with(("1.1.1.1", 443))
        context.wrap_socket.assert_called_once_with(stream, server_hostname="1.1.1.1")
        self.assertTrue(report["Ok"])
        self.assertTrue(report["TlsVerified"])
        self.assertFalse(report["ProxyUsed"])
        self.assertEqual(report["HttpStatus"], 200)
        self.assertNotIn("HTTP/1.1", json.dumps(report))
        self.assertTrue(all(0 < c.args[0] <= 6 for c in stream.settimeout.call_args_list))
        stream.close.assert_called_once()

    def test_direct_https_timeout_is_sanitized_and_socket_is_closed(self):
        runner = tc.LinuxOS()
        stream = mock.Mock()
        stream.connect.side_effect = TimeoutError("private diagnostic text")
        with mock.patch.object(runner, "guard"), mock.patch.object(tc.socket, "socket", return_value=stream):
            result = runner.direct_https()
        self.assertEqual(result["Code"], "Timeout")
        self.assertEqual(result["Stage"], "Connect")
        self.assertNotIn("private diagnostic text", json.dumps(result))
        stream.close.assert_called_once()

    def test_preflight_refuses_conflicting_hosts_without_state_writes(self):
        changes = [lambda e: e["OS"].update(Version="22.04"), lambda e: e.update(Container=True),
                   lambda e: e.update(Systemd=False), lambda e: e["Services"].append("docker.service"),
                   lambda e: e["ActiveServices"].append("ufw.service"), lambda e: e["ActiveServices"].append("nftables.service"),
                   lambda e: e["LegacyRules"].append("-A FORWARD -j ACCEPT"), lambda e: e["WireGuardFiles"].append("wg0.conf"),
                   lambda e: e["Nft"]["nftables"].append({"table": {"family": "ip", "name": "foreign"}}),
                   lambda e: e["Links"].append({"ifname": "wg0", "linkinfo": {"info_kind": "wireguard"}}),
                   lambda e: e["Rules"].append({"priority": 100, "table": 99}), lambda e: e.update(Forwarding="2"),
                   lambda e: e.update(EnabledServices=["nftables.service"]), lambda e: e.update(IPv6Forwarding="1"),
                   lambda e: e["UdpPorts"].append(51820),
                   lambda e: e["Routes"].append({"dst": "10.78.0.0/16", "dev": "ens5"})]
        pristine = copy.deepcopy(self.os.env)
        for change in changes:
            with self.subTest(change=changes.index(change)):
                self.os.env = copy.deepcopy(pristine)
                change(self.os.env)
                self.call("plan", plan_input(), ok=False)
                self.assertFalse(self.fs.mutations)
        self.os.env = pristine
        self.os.env["OS"].update(Id="debian", Version="13")
        self.assertTrue(self.call("inspect")["Supported"])

    def test_schema_rejects_unbounded_noncanonical_and_secret_fields(self):
        changes = [("Name", "x\n[Service]"), ("Name", "x" * 81), ("TunnelSubnet", "10.78.0.1/24"),
                   ("TunnelSubnet", "8.8.8.0/24"), ("TunnelSubnet", "10.0.0.0/15"),
                   ("PublicEndpoint", "host.example:51820"), ("PublicEndpoint", "1.2.3.4:65536"),
                   ("PublicEndpoint", "127.0.0.1:22"), ("PublicEndpoint", "1.2.3.4:01")]
        for name, value in changes:
            with self.subTest(name=name, value=value):
                inp = plan_input()
                inp[name] = value
                self.call("plan", inp, ok=False)
        for name, value in [("SchemaVersion", True), ("AddressFamilies", ["IPv4", "IPv6"]), ("ClientPublicKey", "A" * 43 + "="),
                            ("RequestId", "../../etc/passwd"), ("CreatedAtUtc", "today"), ("PrivateKey", "secret")]:
            inp = plan_input()
            inp["ClientRequest"][name] = value
            self.call("plan", inp, ok=False)
        self.call("apply", {"PlanId": "../../etc/passwd"}, ok=False)
        self.assertFalse(self.fs.mutations)

    def test_plan_is_idempotent_expires_and_is_machine_bound(self):
        first = self.plan()
        self.assertEqual(self.call("plan", plan_input()), first)
        self.assertEqual(self.os.key_count, 0)
        self.assertNotIn("MachineBinding", first)
        self.time += dt.timedelta(hours=2)
        self.assertEqual(self.call("apply", {"PlanId": self.plan_id}, ok=False)["Code"], "PlanExpired")
        self.os.env["MachineBinding"] = tc.digest("b" * 32)
        self.assertEqual(self.call("apply", {"PlanId": self.plan_id}, ok=False)["Code"], "HostMismatch")

    def test_response_compatibility_identity_and_replay(self):
        result = self.apply()
        response = result["ClientResponse"]
        expected_fields = {"SchemaVersion", "Kind", "Status", "RequestId", "DeviceId", "NodeId", "NodeName", "ClientPublicKey",
                           "ClientAddress", "ServerPublicKey", "PublicEndpoint", "TunnelSubnet", "ServerAddress", "AllowedIPs",
                           "PersistentKeepalive", "AddressFamilies", "ConfigRevision", "Validation", "MTU"}
        self.assertEqual(set(response), expected_fields)
        self.assertEqual(response["Kind"], "TradeChannel.ClientResponse")
        self.assertEqual(response["Status"], "Authorized")
        for k in ("RequestId", "DeviceId", "ClientPublicKey", "AddressFamilies", "SchemaVersion"):
            self.assertEqual(response[k], request()[k])
        self.assertEqual(response["ClientAddress"], "10.78.0.2/32")
        self.assertEqual(response["ServerAddress"], "10.78.0.1/24")
        self.assertEqual(response["AllowedIPs"], ["0.0.0.0/0"])
        self.assertEqual(response["PersistentKeepalive"], 25)
        self.assertEqual(response["MTU"], 1380)
        self.assertIn("MTU = " + str(response["MTU"]) + "\n", self.fs.files[self.paths["Config"]])
        self.assertEqual(response["ConfigRevision"], 1)
        self.assertEqual(result["Validation"], tc.VALIDATION)
        self.assertEqual(response["Validation"], {"LocalAuthorization": "Verified", "CloudFirewall": "NotVerified", "ExternalConnectivity": "NotTested", "Handshake": "NotTested"})
        self.time += dt.timedelta(days=5)
        self.assertEqual(result, self.call("apply", {"PlanId": self.plan_id}))
        self.assertEqual(self.os.key_count, 1)
        private = json.loads(self.fs.files[self.paths["Identity"]])["PrivateKey"]
        self.assertNotIn(private, json.dumps(result))
        self.assertNotIn(private, json.dumps(self.os.calls))
        self.assertTrue(all(mode == 0o600 for p, mode in self.fs.modes.items() if p in self.fs.files))

    def test_service_reboot_without_backend_file_and_firewall_semantics(self):
        self.apply()
        fw = self.fs.files[self.paths["FirewallService"]]
        wg = self.fs.files[self.paths["TunnelService"]]
        self.assertIn("After=network-online.target " + self.paths["FirewallUnit"], wg)
        self.assertIn("Requires=" + self.paths["FirewallUnit"], wg)
        self.assertIn("StandardError=null", wg)
        self.assertIn("net.ipv4.ip_forward=1", fw)
        self.assertNotIn("tradechannel_linux.py", fw + wg)
        self.assertNotIn("PrivateKey", fw + wg)
        rules = tc.firewall(self.plan_data)["nftables"]
        input_chain = next(x["chain"] for x in rules if "chain" in x and x["chain"]["name"] == "input")
        forward = next(x["chain"] for x in rules if "chain" in x and x["chain"]["name"] == "forward")
        self.assertEqual(input_chain["policy"], "accept")
        self.assertEqual(forward["policy"], "drop")
        self.assertTrue(all("flush" not in x for x in json.loads(self.fs.files[self.paths["Firewall"]])["nftables"]))
        self.os.remove_tunnel(self.paths["Interface"])
        self.os.env["Nft"] = {"nftables": []}
        self.os.env["Forwarding"] = "0"
        self.os.running.clear()
        self.os.run(["systemctl", "start", self.paths["FirewallUnit"]])
        self.os.run(["systemctl", "start", self.paths["TunnelUnit"]])
        self.assertEqual(self.call("status")["Validation"]["Reboot"], "NotTested")

    def test_authorize_revoke_and_conflicts_preserve_existing_peers(self):
        self.apply()
        result = self.call("authorize", {"ClientRequest": request(2)})
        self.assertEqual(result["ClientResponse"]["ClientAddress"], "10.78.0.3/32")
        self.assertEqual(result["ClientResponse"]["ConfigRevision"], 2)
        self.assertEqual(result, self.call("authorize", {"ClientRequest": request(2)}))
        self.call("authorize", {"ClientRequest": request(3), "ClientAddress": "10.78.0.3/32"}, ok=False)
        changed = request(2)
        changed["ClientPublicKey"] = public_key("different")
        self.assertEqual(self.call("authorize", {"ClientRequest": changed}, ok=False)["Code"], "AuthorizationConflict")
        revoked = self.call("revoke", {"DeviceId": request(2)["DeviceId"]})
        self.assertEqual(revoked, self.call("revoke", {"DeviceId": request(2)["DeviceId"]}))
        self.call("authorize", {"ClientRequest": request(2)}, ok=False)
        self.assertEqual(self.os.live(self.paths["Interface"])["Peers"], {request()["ClientPublicKey"]: "10.78.0.2/32"})
        self.assertEqual(self.os.key_count, 1)
        self.call("revoke", {"DeviceId": request()["DeviceId"]})
        self.assertEqual(self.call("apply", {"PlanId": self.plan_id}, ok=False)["Code"], "InitialClientRevoked")

    def test_subnet_capacity_is_enforced(self):
        inp = plan_input()
        inp["TunnelSubnet"] = "10.78.0.0/30"
        plan = self.call("plan", inp)
        self.call("apply", {"PlanId": plan["PlanId"]})
        self.call("authorize", {"ClientRequest": request(2)}, ok=False)

    def test_foreign_paths_symlinks_modes_and_units_are_not_adopted(self):
        self.fs.dirs.add(tc.ROOT)
        self.assertEqual(self.call("plan", plan_input(), ok=False)["Code"], "OwnershipMismatch")
        self.fs.dirs.remove(tc.ROOT)
        self.plan()
        self.fs.files[self.paths["FirewallService"]] = "foreign-service"
        self.assertEqual(self.call("apply", {"PlanId": self.plan_id}, ok=False)["Code"], "OwnershipMismatch")
        self.assertEqual(self.fs.files[self.paths["FirewallService"]], "foreign-service")
        self.fs.files.pop(self.paths["FirewallService"])
        self.fs.links[self.paths["Config"]] = "/etc/ssh/sshd_config"
        self.assertEqual(self.call("apply", {"PlanId": self.plan_id}, ok=False)["Code"], "UnsafePath")
        self.fs.links.clear()
        self.fs.modes[tc.OWNER] = 0o644
        self.assertEqual(self.call("apply", {"PlanId": self.plan_id}, ok=False)["Code"], "UnsafePath")
        self.assertEqual(self.os.key_count, 0)

    def test_drift_refuses_status_authorization_and_uninstall(self):
        self.apply()
        original = self.fs.files[self.paths["Config"]]
        self.fs.files[self.paths["Config"]] += "# external edit\n"
        writes = len(self.fs.mutations)
        for action, value in (("status", {}), ("authorize", {"ClientRequest": request(2)}), ("uninstall", {})):
            self.assertEqual(self.call(action, value, ok=False)["Code"], "ConfigDrift")
        self.assertEqual(len(self.fs.mutations), writes)
        self.fs.files[self.paths["Config"]] = original
        self.os.env["Nft"]["nftables"][-1]["rule"]["expr"][-1] = {"accept": None}
        self.assertEqual(self.call("status", ok=False)["Code"], "FirewallDrift")
        self.os.env["Nft"] = tc.firewall(self.plan_data)
        self.os.tunnels[self.paths["Interface"]]["Peers"][public_key("intruder")] = "10.78.0.100/32"
        self.assertEqual(self.call("status", ok=False)["Code"], "TunnelDrift")

    def test_systemd_dropin_and_route_drift_are_rejected(self):
        self.apply()
        unit = self.paths["TunnelUnit"]
        info = self.os.service(unit)
        info["DropInPaths"] = "/etc/systemd/system/foreign.conf"
        self.os.override[unit] = info
        self.assertEqual(self.call("uninstall", ok=False)["Code"], "ServiceDrift")
        self.os.override.clear()
        self.os.env["Routes"][0]["dev"] = "ens6"
        self.assertEqual(self.call("status", ok=False)["Code"], "PreflightRejected")

    def test_failed_apply_rolls_back_and_reuses_identity(self):
        self.plan()
        self.os.fail = lambda a: a == ["systemctl", "start", self.paths["TunnelUnit"]]
        result = self.call("apply", {"PlanId": self.plan_id}, ok=False)
        self.assertEqual(result["Code"], "RolledBack")
        self.assertNotIn(tc.ACTIVE, self.fs.files)
        self.assertNotIn(tc.MANIFEST, self.fs.files)
        self.assertEqual(self.os.env["Forwarding"], "0")
        self.assertEqual(self.os.env["Nft"], {"nftables": []})
        self.assertFalse(self.os.tunnels)
        self.assertFalse(self.fs.links)
        identity = self.fs.files[self.paths["Identity"]]
        self.call("apply", {"PlanId": self.plan_id})
        self.assertEqual(self.fs.files[self.paths["Identity"]], identity)
        self.assertEqual(self.os.key_count, 1)

    def test_partial_file_failure_has_backups_before_mutation(self):
        self.plan()
        self.fs.fail_path = self.paths["Sync"]
        result = self.call("apply", {"PlanId": self.plan_id}, ok=False)
        self.assertEqual(result["Code"], "RolledBack")
        self.assertNotIn(self.paths["Config"], self.fs.files)
        journal = next(json.loads(v) for p, v in self.fs.files.items() if p.startswith(tc.ROOT + "/transactions/"))
        self.assertEqual(set(journal["Files"]), set(tc.resource_paths(self.plan_data)))
        self.assertEqual(journal["Phase"], "RolledBack")

    def test_crash_blocks_mutations_until_explicit_recovery(self):
        self.plan()
        self.os.crash = lambda a: a[:2] == ["wg-quick", "up"]
        with self.assertRaises(Crash):
            self.backend.apply({"PlanId": self.plan_id})
        self.assertEqual(self.call("status")["Status"], "NeedsRecovery")
        self.assertEqual(self.call("apply", {"PlanId": self.plan_id}, ok=False)["Code"], "NeedsRecovery")
        self.assertEqual(self.call("recover")["Outcome"], "RolledBack")
        self.assertFalse(self.os.tunnels)
        self.call("apply", {"PlanId": self.plan_id})
        self.assertEqual(self.os.key_count, 1)

    def test_pending_status_reports_public_readonly_evidence_and_separate_failures(self):
        self.plan()
        self.os.crash = lambda a: a[:2] == ["wg-quick", "up"]
        with self.assertRaises(Crash):
            self.backend.apply({"PlanId": self.plan_id})
        private = json.loads(self.fs.files[self.paths["Identity"]])["PrivateKey"]
        self.os.env["Nft"]["nftables"][-1]["rule"]["expr"][-1] = {"accept": None}
        self.os.env["Nft"]["nftables"].append({"table": {"family": "inet", "name": "foreign-secret-table"}})
        self.os.env["Nft"]["nftables"][-2]["rule"]["comment"] = "private=" + private
        before = copy.deepcopy((self.fs.files, self.fs.links, self.fs.modes, self.os.env, self.os.running))
        count = len(self.fs.mutations)
        calls = len(self.os.calls)
        data = self.call("status")
        diag = data["Diagnostics"]
        self.assertEqual(data["Status"], "NeedsRecovery")
        self.assertTrue(diag["ReadOnly"])
        self.assertTrue(diag["Checks"]["Journal"]["Ok"])
        self.assertFalse(diag["Firewall"]["MatchesExpected"])
        self.assertEqual(diag["Firewall"]["ForeignObjectCount"], 1)
        self.assertEqual(diag["Checks"]["AfterRuntime"]["Code"], "PreflightRejected")
        self.assertTrue(diag["WireGuard"]["AfterPeersMatch"])
        self.assertFalse(diag["State"]["Manifest"]["Metadata"]["Exists"])
        self.assertTrue(diag["State"]["Identity"]["SchemaFieldsMatch"])
        self.assertTrue(all(row["MatchesAfter"] for row in diag["Files"]))
        self.assertTrue(all(row["Metadata"]["Mode"] == "0600" for row in diag["Files"]))
        text = json.dumps(data)
        for secret in (private, "foreign-secret-table", "[Interface]", "PrivateKey", "ResourceHashes"):
            self.assertNotIn(secret, text)
        self.assertEqual(before, (self.fs.files, self.fs.links, self.fs.modes, self.os.env, self.os.running))
        self.assertEqual(len(self.fs.mutations), count)
        self.assertTrue(all(c == ["wg", "pubkey"] for c in self.os.calls[calls:]))

    def test_pending_diagnostics_survive_file_drift_without_following_journal_paths(self):
        self.plan()
        self.os.crash = lambda a: a[:2] == ["wg-quick", "up"]
        with self.assertRaises(Crash):
            self.backend.apply({"PlanId": self.plan_id})
        self.fs.files[self.paths["Config"]] += "# outside change\n"
        tx = json.loads(self.fs.files[tc.ACTIVE])
        tx["Files"]["/etc/foreign-secret"] = {"Before": "private", "After": "private"}
        self.fs.files[tc.ACTIVE] = tc.dumps(tx)
        diag = self.call("status")["Diagnostics"]
        self.assertEqual(diag["Checks"]["Journal"]["Code"], "InvalidJournal")
        self.assertEqual({row["Path"] for row in diag["Files"]}, set(tc.resource_paths(self.plan_data)))
        self.assertFalse(next(row for row in diag["Files"] if row["Path"] == self.paths["Config"])["MatchesAfter"])
        self.assertNotIn("/etc/foreign-secret", json.dumps(diag))

    def test_failed_recovery_stays_explicit_and_never_removes_foreign_rules(self):
        self.plan()
        self.os.crash = lambda a: a[:2] == ["wg-quick", "up"]
        with self.assertRaises(Crash):
            self.backend.apply({"PlanId": self.plan_id})
        original = copy.deepcopy(self.os.env["Nft"])
        self.os.env["Nft"]["nftables"].append({"rule": {"family": "inet", "table": self.paths["Table"], "chain": "input", "expr": [{"accept": None}]}})
        calls = len(self.os.calls)
        self.assertEqual(self.call("recover", ok=False)["Code"], "NeedsRecovery")
        self.assertFalse(any(c[:2] in (["systemctl", "stop"], ["nft", "delete"]) for c in self.os.calls[calls:]))
        self.assertEqual(self.call("status")["Status"], "NeedsRecovery")
        self.assertEqual(json.loads(self.fs.files[tc.ACTIVE])["Phase"], "NeedsRecovery")
        self.os.env["Nft"] = original
        self.call("recover")
        self.assertNotIn(tc.ACTIVE, self.fs.files)

    def test_captured_ubuntu_nft_matches_only_after_declaration_normalization(self):
        self.plan()
        actual = captured_nft(self.plan_data)
        expected = tc.firewall(self.plan_data)
        # The fixture was captured independently from generated input. Native
        # nft puts all three chain declarations before any rule, with handles.
        self.assertEqual([next(iter(x)) for x in actual["nftables"][:5]], ["table", "chain", "chain", "chain", "rule"])
        self.assertEqual([next(iter(x)) for x in expected["nftables"][:5]], ["table", "chain", "rule", "rule", "chain"])
        self.assertEqual(tc.nft_normalized(actual), tc.nft_normalized(expected))
        self.assertEqual(len(actual["nftables"]), 24)
        self.assertEqual(len([x for x in actual["nftables"] if "rule" in x]), 20)

    def test_native_shape_does_not_hide_rule_order_or_policy_drift(self):
        self.plan()
        expected = tc.nft_normalized(tc.firewall(self.plan_data))
        def reorder(items):
            items[9], items[20] = items[20], items[9]
        changes = [reorder, lambda a: a[2]["chain"].update(policy="accept"),
                   lambda a: a[2]["chain"].update(prio=0),
                   lambda a: a[5]["rule"]["expr"][2]["match"].update(right=51821),
                   lambda a: a[9]["rule"]["expr"][-1].update(drop="unexpected"),
                   lambda a: a[9]["rule"].update(comment="ForeignOwner"),
                   lambda a: a[9]["rule"]["expr"].insert(0, {"counter": {"packets": 1, "bytes": 64}}),
                   lambda a: a[9]["rule"]["expr"][1]["match"]["right"]["prefix"].update(len=9),
                   lambda a: a.pop(9), lambda a: a.append(copy.deepcopy(a[9]))]
        for index, mutate in enumerate(changes):
            with self.subTest(change=index):
                actual = captured_nft(self.plan_data)
                mutate(actual["nftables"])
                self.assertNotEqual(tc.nft_normalized(actual), expected)

    def test_real_shape_failure_recovers_then_reapplies_without_identity_regeneration(self):
        self.plan()
        original_effect = self.os.effect
        def observed_kernel(argv, input_text):
            result = original_effect(argv, input_text)
            if argv[:3] == ["nft", "-j", "-f"]:
                self.os.env["Nft"] = captured_nft(self.plan_data)
            return result
        def previous_normalizer(value):
            # Reproduce the shipped bug: allocation IDs were removed but
            # declaration placement was compared as if it were rule order.
            result = []
            for item in value["nftables"]:
                if "metainfo" not in item:
                    result.append({name: {k: copy.deepcopy(v) for k, v in obj.items() if k not in ("handle", "index")}
                                   for name, obj in item.items()})
            return result
        with mock.patch.object(self.os, "effect", side_effect=observed_kernel), mock.patch.object(tc, "nft_normalized", side_effect=previous_normalizer):
            failure = self.call("apply", {"PlanId": self.plan_id}, ok=False)
        self.assertEqual((failure["Code"], failure["FailureCode"], failure["RecoveryCode"]),
                         ("NeedsRecovery", "FirewallDrift", "OwnershipMismatch"))
        pending = self.call("status")
        self.assertEqual(pending["Status"], "NeedsRecovery")
        self.assertTrue(pending["Diagnostics"]["Firewall"]["MatchesExpected"])
        self.assertTrue(pending["Diagnostics"]["Checks"]["Journal"]["Ok"])
        self.assertTrue(pending["Diagnostics"]["Checks"]["AfterRuntime"]["Ok"])
        self.assertNotIn(tc.MANIFEST, self.fs.files)  # Status must not finalize.
        identity = self.fs.files[self.paths["Identity"]]
        route = copy.deepcopy(tc.default_route(self.os.env))
        recovery = self.call("recover")
        self.assertEqual((recovery["Status"], recovery["Outcome"]), ("Recovered", "RolledBack"))
        self.assertNotIn(tc.ACTIVE, self.fs.files)
        self.assertFalse(self.os.tunnels)
        self.assertEqual(self.os.env["Forwarding"], "0")
        self.assertEqual(tc.nft_normalized(self.os.env["Nft"]), [])
        self.assertEqual(tc.default_route(self.os.env), route)
        self.assertEqual(self.os.env["ActiveServices"], ["ssh.service"])
        self.assertEqual(self.fs.files[self.paths["Identity"]], identity)
        self.call("apply", {"PlanId": self.plan_id})
        self.assertEqual(self.os.key_count, 1)
        self.assertEqual(self.fs.files[self.paths["Identity"]], identity)
        self.assertEqual(self.call("status")["Status"], "Applied")

    def test_finalize_verifies_pending_initial_apply_without_network_mutations(self):
        self.pending_initial_apply()
        before_os = copy.deepcopy((self.os.env, self.os.running, self.os.tunnels))
        before_identity = self.fs.files[self.paths["Identity"]]
        calls, writes = len(self.os.calls), len(self.fs.mutations)
        # Expiry limits new deployment, not verification of already staged
        # resources under the user's separate explicit finalize action.
        self.time += dt.timedelta(hours=2)
        result = self.call("finalize", {"PlanId": self.plan_id})
        self.assertEqual(result["Status"], "Applied")
        self.assertEqual(result["ClientResponse"]["RequestId"], request()["RequestId"])
        self.assertEqual(result["ClientResponse"]["ConfigRevision"], 1)
        self.assertEqual(result["Validation"], tc.VALIDATION)
        self.assertEqual(before_os, (self.os.env, self.os.running, self.os.tunnels))
        self.assertTrue(all(c == ["wg", "pubkey"] for c in self.os.calls[calls:]))
        written = {p for _, p in self.fs.mutations[writes:]}
        self.assertTrue(all(p in (tc.MANIFEST, tc.ACTIVE) or p.startswith(tc.ROOT + "/transactions/") for p in written))
        self.assertEqual(self.fs.files[self.paths["Identity"]], before_identity)
        self.assertEqual(self.os.key_count, 1)
        self.assertNotIn(tc.ACTIVE, self.fs.files)
        writes = len(self.fs.mutations)
        self.assertEqual(result, self.call("finalize", {"PlanId": self.plan_id}))
        self.assertEqual(len(self.fs.mutations), writes)
        self.assertEqual(self.call("status")["Status"], "Applied")

    def test_finalize_refuses_file_rule_link_and_peer_drift_without_writes(self):
        self.pending_initial_apply()
        saved = copy.deepcopy((self.fs.files, self.fs.links, self.os.env, self.os.tunnels))
        changes = [lambda: self.fs.files.__setitem__(self.paths["Config"], self.fs.files[self.paths["Config"]] + "# changed\n"),
                   lambda: self.os.env["Nft"]["nftables"][2]["chain"].update(policy="accept"),
                   lambda: self.fs.links.__setitem__(self.paths["TunnelLink"], "/etc/foreign.service"),
                   lambda: self.os.tunnels[self.paths["Interface"]]["Peers"].update({public_key("foreign"): "10.78.0.100/32"})]
        for index, change in enumerate(changes):
            with self.subTest(change=index):
                self.fs.files, self.fs.links, self.os.env, self.os.tunnels = copy.deepcopy(saved)
                change()
                writes, calls = len(self.fs.mutations), len(self.os.calls)
                failure = self.call("finalize", {"PlanId": self.plan_id}, ok=False)
                self.assertIn(failure["Code"], ("OwnershipMismatch", "FirewallDrift", "ServiceDrift", "TunnelDrift"))
                self.assertEqual(len(self.fs.mutations), writes)
                self.assertTrue(all(c == ["wg", "pubkey"] for c in self.os.calls[calls:]))
                self.assertNotIn(tc.MANIFEST, self.fs.files)

    def test_finalize_refuses_noninitial_or_mismatched_transactions(self):
        tx = self.pending_initial_apply()
        changes = [lambda t: t.update(Action="authorize"), lambda t: t.update(Before=copy.deepcopy(t["After"])),
                   lambda t: t.update(Phase="RolledBack"), lambda t: t["After"].update(ConfigRevision=2),
                   lambda t: t["After"].update(NodeId=str(uuid.uuid4())),
                   lambda t: t["After"]["Peers"][0].update(ClientAddress="10.78.0.3/32")]
        for index, change in enumerate(changes):
            with self.subTest(change=index):
                altered = copy.deepcopy(tx)
                change(altered)
                self.fs.files[tc.ACTIVE] = tc.dumps(altered)
                writes = len(self.fs.mutations)
                self.assertEqual(self.call("finalize", {"PlanId": self.plan_id}, ok=False)["Code"], "FinalizeNotAllowed")
                self.assertEqual(len(self.fs.mutations), writes)
        self.fs.files[tc.ACTIVE] = tc.dumps(tx)
        self.assertEqual(self.call("finalize", {"PlanId": str(uuid.uuid4())}, ok=False)["Code"], "PlanNotFound")

    def test_finalize_commit_failure_keeps_network_and_can_be_retried(self):
        self.pending_initial_apply()
        before_os = copy.deepcopy((self.os.env, self.os.running, self.os.tunnels))
        calls = len(self.os.calls)
        self.fs.fail_path = tc.MANIFEST
        error = self.call("finalize", {"PlanId": self.plan_id}, ok=False)
        self.assertEqual((error["Code"], error["FailureCode"]), ("NeedsRecovery", "DiskFailure"))
        self.assertEqual(before_os, (self.os.env, self.os.running, self.os.tunnels))
        self.assertTrue(all(c == ["wg", "pubkey"] for c in self.os.calls[calls:]))
        self.assertIn(tc.ACTIVE, self.fs.files)
        self.assertNotIn(tc.MANIFEST, self.fs.files)
        self.call("finalize", {"PlanId": self.plan_id})
        self.assertEqual(self.call("status")["Status"], "Applied")

    def test_finalize_resumes_crash_after_manifest_commit_without_restarting(self):
        self.pending_initial_apply()
        original_cas = self.fs.cas
        def fail_committed_marker(path, before, after, **kw):
            if path == tc.ACTIVE and after is not None and json.loads(after).get("Phase") == "Committed":
                raise Crash("power loss after manifest commit")
            return original_cas(path, before, after, **kw)
        with mock.patch.object(self.fs, "cas", side_effect=fail_committed_marker):
            with self.assertRaises(Crash):
                self.backend.finalize({"PlanId": self.plan_id})
        self.assertEqual(json.loads(self.fs.files[tc.ACTIVE])["Phase"], "NeedsRecovery")
        self.assertEqual(json.loads(self.fs.files[tc.MANIFEST])["Status"], "Applied")
        before_os = copy.deepcopy((self.os.env, self.os.running, self.os.tunnels))
        self.call("finalize", {"PlanId": self.plan_id})
        self.assertEqual(before_os, (self.os.env, self.os.running, self.os.tunnels))
        self.assertNotIn(tc.ACTIVE, self.fs.files)
        self.assertEqual(self.os.key_count, 1)

    def test_finalize_finishes_already_committed_journal_cleanup(self):
        self.pending_initial_apply()
        original_cas = self.fs.cas
        def fail_cleanup(path, before, after, **kw):
            if path == tc.ACTIVE and after is None:
                raise tc.TCError("DiskFailure", "cleanup failed")
            return original_cas(path, before, after, **kw)
        with mock.patch.object(self.fs, "cas", side_effect=fail_cleanup):
            self.assertEqual(self.call("finalize", {"PlanId": self.plan_id}, ok=False)["Code"], "NeedsRecovery")
        self.assertEqual(json.loads(self.fs.files[tc.ACTIVE])["Phase"], "Committed")
        before_os = copy.deepcopy((self.os.env, self.os.running, self.os.tunnels))
        self.call("finalize", {"PlanId": self.plan_id})
        self.assertEqual(before_os, (self.os.env, self.os.running, self.os.tunnels))
        self.assertNotIn(tc.ACTIVE, self.fs.files)

    def test_finalize_never_installs_an_unapplied_plan_or_reauthorizes_revoked_client(self):
        self.plan()
        writes = len(self.fs.mutations)
        self.assertEqual(self.call("finalize", {"PlanId": self.plan_id}, ok=False)["Code"], "FinalizeNotAllowed")
        self.assertEqual(len(self.fs.mutations), writes)
        self.assertEqual(self.os.key_count, 0)
        self.call("apply", {"PlanId": self.plan_id})
        self.call("revoke", {"DeviceId": request()["DeviceId"]})
        writes = len(self.fs.mutations)
        self.assertEqual(self.call("finalize", {"PlanId": self.plan_id}, ok=False)["Code"], "InitialClientRevoked")
        self.assertEqual(len(self.fs.mutations), writes)

    def test_rollback_failure_does_not_report_success(self):
        self.plan()
        count = [0]
        original = self.os.run
        def injected(argv, **kw):
            if list(argv) == ["systemctl", "start", self.paths["TunnelUnit"]] or list(argv) == ["systemctl", "stop", self.paths["FirewallUnit"]]:
                count[0] += 1
                raise tc.TCError("CommandFailed", "private-key-should-not-escape")
            return original(argv, **kw)
        with mock.patch.object(self.os, "run", side_effect=injected):
            result = self.call("apply", {"PlanId": self.plan_id}, ok=False)
        self.assertEqual(result["Code"], "NeedsRecovery")
        self.assertEqual(count[0], 2)
        self.assertNotIn("private-key-should-not-escape", json.dumps(result))
        self.call("recover")

    def test_authorization_failure_rolls_back_without_restarting_other_peers(self):
        self.apply()
        original = self.os.live(self.paths["Interface"])
        commands = len(self.os.calls)
        self.os.fail = lambda a: a[:2] == ["wg", "syncconf"]
        self.assertEqual(self.call("authorize", {"ClientRequest": request(2)}, ok=False)["Code"], "RolledBack")
        self.assertEqual(self.os.live(self.paths["Interface"]), original)
        self.assertFalse(any(c[:2] in (["systemctl", "stop"], ["systemctl", "start"]) for c in self.os.calls[commands:]))
        self.assertEqual(self.call("status")["Node"]["ConfigRevision"], 1)

    def test_crash_after_authorization_sync_restores_previous_peers(self):
        self.apply()
        self.os.crash = lambda a: a[:2] == ["wg", "syncconf"]
        with self.assertRaises(Crash):
            self.backend.authorize({"ClientRequest": request(2)})
        self.assertEqual(len(self.os.live(self.paths["Interface"])["Peers"]), 2)
        self.call("recover")
        self.assertEqual(len(self.os.live(self.paths["Interface"])["Peers"]), 1)

    def test_journal_cannot_redirect_recovery_to_foreign_files(self):
        self.plan()
        self.os.crash = lambda a: a[:2] == ["wg-quick", "up"]
        with self.assertRaises(Crash):
            self.backend.apply({"PlanId": self.plan_id})
        tx = json.loads(self.fs.files[tc.ACTIVE])
        tx["Files"]["/etc/ssh/sshd_config"] = {"Before": "foreign", "After": "changed"}
        self.fs.files[tc.ACTIVE] = tc.dumps(tx)
        self.fs.files["/etc/ssh/sshd_config"] = "foreign"
        self.assertEqual(self.call("recover", ok=False)["Code"], "NeedsRecovery")
        self.assertEqual(self.fs.files["/etc/ssh/sshd_config"], "foreign")

    def test_install_is_apply_only_and_rechecks_post_package_firewall(self):
        self.os.env["Tools"] = {k: False for k in self.os.env["Tools"]}
        self.os.env["Nft"] = None
        self.call("inspect")
        self.plan()
        self.assertEqual(self.os.install_count, 0)
        self.call("apply", {"PlanId": self.plan_id})
        self.assertEqual(self.os.install_count, 1)
        self.assertNotIn(tc.POLICY, self.fs.files)
        self.assertEqual(self.fs.files[self.paths["Identity"]].count("PrivateKey"), 1)

    def test_package_failure_cleans_owned_temporary_policy(self):
        self.os.env["Tools"]["nft"] = False
        self.os.env["Nft"] = None
        self.plan()
        def fail():
            raise tc.TCError("CommandFailed", "apt failure")
        self.os.install_effect = fail
        self.assertEqual(self.call("apply", {"PlanId": self.plan_id}, ok=False)["Code"], "RolledBack")
        self.assertNotIn(tc.POLICY, self.fs.files)
        self.assertEqual(self.os.env["Forwarding"], "0")

    def test_post_package_conflict_never_starts_networking(self):
        self.os.env["Tools"]["nft"] = False
        self.os.env["Nft"] = None
        self.plan()
        def foreign_rules():
            self.os.env["Nft"] = {"nftables": [{"table": {"family": "ip", "name": "foreign"}}]}
        self.os.install_effect = foreign_rules
        result = self.call("apply", {"PlanId": self.plan_id}, ok=False)
        self.assertEqual(result["Code"], "NeedsRecovery")
        self.assertEqual(result["FailureCode"], "PreflightRejected")
        self.assertNotIn(tc.POLICY, self.fs.files)
        self.assertFalse(any(c[:2] == ["systemctl", "start"] for c in self.os.calls))
        self.assertEqual(self.os.env["Nft"]["nftables"][0]["table"]["name"], "foreign")

    def test_finalize_failure_preserves_commit_for_recovery(self):
        self.plan()
        original = self.fs.cas
        failed = [False]
        def fail_cleanup(path, before, after, **kw):
            if path == tc.ACTIVE and after is None and not failed[0]:
                failed[0] = True
                raise tc.TCError("DiskFailure", "cleanup failed")
            return original(path, before, after, **kw)
        with mock.patch.object(self.fs, "cas", side_effect=fail_cleanup):
            self.assertEqual(self.call("apply", {"PlanId": self.plan_id}, ok=False)["Code"], "NeedsRecovery")
        self.assertEqual(json.loads(self.fs.files[tc.ACTIVE])["Phase"], "Committed")
        self.assertIn(self.paths["Interface"], self.os.tunnels)
        self.assertEqual(self.call("recover")["Outcome"], "CommitPreserved")
        self.assertEqual(self.call("status")["Status"], "Applied")
        self.assertEqual(self.os.key_count, 1)

    def test_finalize_failure_after_rollback_can_be_recovered(self):
        self.plan()
        self.fs.fail_path = self.paths["Sync"]
        original = self.fs.cas
        failed = [False]
        def fail_cleanup(path, before, after, **kw):
            if path == tc.ACTIVE and after is None and not failed[0]:
                failed[0] = True
                raise tc.TCError("DiskFailure", "cleanup failed")
            return original(path, before, after, **kw)
        with mock.patch.object(self.fs, "cas", side_effect=fail_cleanup):
            self.assertEqual(self.call("apply", {"PlanId": self.plan_id}, ok=False)["Code"], "NeedsRecovery")
        self.assertEqual(json.loads(self.fs.files[tc.ACTIVE])["Phase"], "RolledBack")
        self.assertEqual(self.call("recover")["Outcome"], "RolledBack")
        self.assertNotIn(tc.ACTIVE, self.fs.files)
        self.assertFalse(self.os.tunnels)

    def test_state_path_checks_reject_links_hardlinks_and_reparse_points(self):
        fs = tc.SecureFS()
        def attr(mode, count=1, flags=0):
            return SimpleNamespace(st_mode=mode, st_uid=0, st_nlink=count, st_file_attributes=flags)
        for bad in (attr(stat.S_IFLNK | 0o700), attr(stat.S_IFREG | 0o600, count=2), attr(stat.S_IFREG | 0o600, flags=0x400)):
            with self.subTest(bad=bad):
                def lstat(path):
                    if path == tc.OWNER:
                        return bad
                    return attr(stat.S_IFDIR | (0o700 if path == tc.ROOT else 0o755))
                with mock.patch.object(tc.os, "lstat", side_effect=lstat):
                    with self.assertRaises(tc.TCError) as error:
                        fs.check(tc.OWNER)
                self.assertEqual(error.exception.code, "UnsafePath")

    def test_firewall_denies_private_peer_host_and_unsolicited_traffic(self):
        self.apply()
        rules = tc.firewall(self.plan_data)["nftables"]
        def verdict(chain, packet):
            policy = next(x["chain"]["policy"] for x in rules if x.get("chain", {}).get("name") == chain)
            for item in rules:
                rule = item.get("rule")
                if not rule or rule["chain"] != chain:
                    continue
                matched = True
                for expr in rule["expr"]:
                    if "match" not in expr:
                        if matched:
                            return next(iter(expr))
                        break
                    match = expr["match"]
                    left, right = match["left"], match["right"]
                    if "meta" in left:
                        value = packet.get(left["meta"]["key"])
                    elif "ct" in left:
                        self.assertEqual(match["op"], "in")
                        value = packet.get("state")
                    else:
                        value = packet.get(left["payload"]["field"])
                        if left["payload"]["protocol"] == "ip" and packet.get("nfproto") != "ipv4":
                            matched = False
                            break
                    if isinstance(right, dict) and "prefix" in right:
                        p = right["prefix"]
                        ok = tc.ipaddress.ip_address(value) in tc.ipaddress.ip_network(str(p["addr"]) + "/" + str(p["len"]))
                    else:
                        ok = value == right
                    if not ok:
                        matched = False
                        break
            return policy
        normal = {"iifname": self.paths["Interface"], "oifname": "ens5", "nfproto": "ipv4",
                  "saddr": "10.78.0.2", "daddr": "8.8.8.8", "state": "new"}
        self.assertEqual(verdict("forward", normal), "accept")
        for destination in ("10.0.0.1", "172.16.5.1", "192.168.1.1", "169.254.169.254", "127.0.0.1", "100.64.0.1", "224.0.0.1", "203.0.113.10"):
            self.assertEqual(verdict("forward", dict(normal, daddr=destination, state="established")), "drop")
        self.assertEqual(verdict("forward", dict(normal, oifname=self.paths["Interface"], daddr="10.78.0.3")), "drop")
        self.assertEqual(verdict("forward", dict(normal, saddr="1.2.3.4")), "drop")
        self.assertEqual(verdict("forward", dict(normal, nfproto="ipv6", saddr="fd00::2", daddr="2606:4700:4700::1111")), "drop")
        returning = dict(normal, iifname="ens5", oifname=self.paths["Interface"], saddr="8.8.8.8", daddr="10.78.0.2")
        self.assertEqual(verdict("forward", returning), "drop")
        self.assertEqual(verdict("forward", dict(returning, state="established")), "accept")
        self.assertEqual(verdict("input", dict(normal, daddr="10.78.0.1", dport=22)), "drop")
        for port in (22, 2222):
            self.assertEqual(verdict("input", dict(normal, iifname="ens5", dport=port)), "accept")

    def test_uninstall_only_owned_resources_is_idempotent_and_retains_audit(self):
        self.apply()
        self.fs.files["/etc/ssh/sshd_config"] = "Port 2222\n"
        original_route = copy.deepcopy(self.os.env["Routes"][0])
        result = self.call("uninstall")
        self.assertTrue(result["RetainedPrivateState"])
        self.assertEqual(result, self.call("uninstall"))
        self.assertFalse(self.os.tunnels)
        self.assertFalse(self.fs.links)
        self.assertEqual(self.os.env["Forwarding"], "0")
        self.assertEqual(self.os.env["Routes"][0], original_route)
        self.assertEqual(self.fs.files["/etc/ssh/sshd_config"], "Port 2222\n")
        self.assertTrue(all(p not in self.fs.files for p in tc.resource_paths(self.plan_data)))
        self.assertIn(self.paths["Identity"], self.fs.files)
        self.assertFalse(any("flush" in c or c[:2] == ["ip", "route"] for c in self.os.calls))

    def test_failed_uninstall_restores_node(self):
        self.apply()
        self.fs.fail_path = self.paths["Config"]
        self.assertEqual(self.call("uninstall", ok=False)["Code"], "RolledBack")
        self.assertEqual(self.call("status")["Status"], "Applied")

    def test_new_plan_after_uninstall_has_a_new_node_identity(self):
        first = self.apply()
        self.call("uninstall")
        second = self.call("plan", plan_input())
        self.assertNotEqual(second["PlanId"], self.plan_id)
        result = self.call("apply", {"PlanId": second["PlanId"]})
        self.assertNotEqual(result["Node"]["NodeId"], first["Node"]["NodeId"])
        self.assertNotEqual(result["Node"]["ServerPublicKey"], first["Node"]["ServerPublicKey"])

    def test_native_runner_captures_output_uses_argv_and_terminates_process_group(self):
        runner = tc.LinuxOS()
        proc = mock.MagicMock()
        proc.__enter__.return_value = proc
        proc.pid = 12345
        proc.returncode = 0
        proc.communicate.return_value = ("public-result\n", "private-error")
        with mock.patch.object(runner, "guard"), mock.patch.object(tc.subprocess, "Popen", return_value=proc) as spawn:
            self.assertEqual(runner.run(["wg", "pubkey"], input_text="server-secret"), "public-result")
            argv = spawn.call_args.args[0]
            self.assertEqual(argv, ["/usr/bin/wg", "pubkey"])
            self.assertNotIn("server-secret", repr(spawn.call_args))
            self.assertFalse(spawn.call_args.kwargs["shell"])
            self.assertTrue(spawn.call_args.kwargs["start_new_session"])
            self.assertEqual(spawn.call_args.kwargs["env"]["NEEDRESTART_MODE"], "l")
            proc.communicate.side_effect = [tc.subprocess.TimeoutExpired("apt-get", 1), ("", "")]
            with mock.patch.object(tc.os, "killpg", create=True) as kill, mock.patch.object(tc.signal, "SIGKILL", 9, create=True):
                with self.assertRaises(tc.TCError) as error:
                    runner.run(["apt-get", "update"], timeout=1)
                kill.assert_called_once_with(12345, tc.signal.SIGKILL)
            self.assertEqual(error.exception.code, "CommandFailed")

    def test_cli_stringio_limits_errors_and_no_private_output(self):
        broken = mock.Mock()
        broken.execute.side_effect = RuntimeError("private-key-must-never-appear")
        error = tc.envelope("inspect", {}, broken)
        self.assertEqual(error["Data"]["Diagnostic"]["ExceptionType"], "RuntimeError")
        self.assertNotIn("private-key-must-never-appear", json.dumps(error))
        output = io.StringIO()
        code = tc.main(["plan", "--input", "-"], stdin=io.StringIO(json.dumps(plan_input())), stdout=output, backend=self.backend)
        self.assertEqual(code, 0)
        parsed = json.loads(output.getvalue())
        self.assertEqual(parsed["Action"], "plan")
        for raw in ('{"x":1,"x":2}', '{"Password":"secret"}', " " * (tc.MAX_INPUT + 1), '[' * 1000):
            output = io.StringIO()
            self.assertEqual(tc.main(["inspect", "--input", "-"], stdin=io.StringIO(raw), stdout=output, backend=self.backend), 1)
            self.assertFalse(json.loads(output.getvalue())["Ok"])
            self.assertNotIn("secret", output.getvalue())
        output = io.StringIO()
        self.assertEqual(tc.main(["invalid"], stdout=output, backend=self.backend), 1)
        self.assertEqual(json.loads(output.getvalue())["Data"]["Code"], "InvalidArguments")

    def test_linux_probe_parses_real_command_shapes_without_os_mutations(self):
        runner = tc.LinuxOS()
        files = {"/etc/os-release": 'ID=ubuntu\nVERSION_ID="24.04"\n',
                 "/etc/machine-id": "a" * 32,
                 "/proc/sys/net/ipv4/ip_forward": "0",
                 "/proc/net/udp": "sl local_address rem_address\n0: 00000000:0035 00000000:0000\n"}
        commands = {
            ("systemd-detect-virt", "--container"): "none",
            ("ip", "-j", "-4", "route", "show", "table", "all"): '[{"dst":"default","dev":"eth0","gateway":"192.0.2.1","protocol":"static"}]',
            ("ip", "-j", "-4", "rule", "show"): '[{"priority":0,"src":"all","table":"local"},{"priority":32766,"src":"all","table":"main"},{"priority":32767,"src":"all","table":"default"}]',
            ("ip", "-j", "-d", "link", "show"): '[{"ifname":"lo","link_type":"loopback"},{"ifname":"eth0","link_type":"ether"}]',
            ("ip", "-j", "-4", "address", "show"): '[{"ifname":"eth0","addr_info":[{"family":"inet","local":"192.0.2.10","prefixlen":24}]}]',
            ("systemctl", "list-unit-files", "--type=service", "--no-pager", "--no-legend"): 'ssh.service enabled enabled\n',
            ("systemctl", "list-units", "--type=service", "--state=active", "--no-pager", "--no-legend"): 'ssh.service loaded active running OpenSSH server\n',
        }
        tools = {"ip", "systemctl", "systemd-detect-virt", "apt-get", "sysctl"}
        with mock.patch.object(runner, "guard"), mock.patch.object(runner, "available", side_effect=lambda x: x in tools), \
             mock.patch.object(runner, "read_system", side_effect=lambda p: files[p]), \
             mock.patch.object(runner, "run", side_effect=lambda argv, **_: commands[tuple(argv)]), \
             mock.patch.object(tc.os.path, "exists", side_effect=lambda p: p in files), \
             mock.patch.object(tc.os.path, "lexists", return_value=False), \
             mock.patch.object(tc.os.path, "isdir", side_effect=lambda p: p == "/run/systemd/system"), \
             mock.patch.object(tc.platform, "machine", return_value="x86_64"):
            facts = runner.probe()
        self.assertEqual(facts["UdpPorts"], [53])
        self.assertEqual(facts["EnabledServices"], ["ssh.service"])
        self.assertEqual(tc.environment_issues(facts), [])

    def test_virtual_system_files_use_bounded_reads_and_safe_diagnostics(self):
        class VirtualFile(io.BytesIO):
            def read(self, size=-1):
                if size < 0 or size > 4096:
                    raise OSError(22, "kernel rejects oversized virtual reads")
                return super().read(size)
        with mock.patch("builtins.open", return_value=VirtualFile(b"0\n")):
            self.assertEqual(tc.LinuxOS().read_system("/proc/sys/net/ipv4/ip_forward"), "0\n")
        with mock.patch("builtins.open", side_effect=OSError(13, "private content must not be logged")):
            with self.assertRaises(tc.TCError) as error:
                tc.LinuxOS().read_system("/etc/machine-id")
            self.assertEqual(error.exception.code, "SystemReadFailed")
            self.assertEqual(error.exception.data["Errno"], 13)
            self.assertNotIn("private content", str(error.exception))

    def test_exec_source_bootstrap_without_file_on_windows_never_invokes_linux(self):
        output = io.StringIO()
        with mock.patch.object(tc.sys, "platform", "win32"), mock.patch.object(tc.sys, "argv", ["tradechannel_linux.py", "inspect", "--input", "-"]), \
             mock.patch.object(tc.sys, "stdin", io.StringIO("{}")), mock.patch.object(tc.sys, "stdout", output), \
             mock.patch.object(tc.subprocess, "run", side_effect=AssertionError("No host commands allowed")):
            with self.assertRaises(SystemExit) as stop:
                exec(compile(SOURCE.read_text(encoding="utf-8"), "<ssh-payload>", "exec"), {"__name__": "__main__"})
        self.assertEqual(stop.exception.code, 1)
        self.assertEqual(json.loads(output.getvalue())["Data"]["Code"], "UnsupportedHost")


if __name__ == "__main__":
    unittest.main()
