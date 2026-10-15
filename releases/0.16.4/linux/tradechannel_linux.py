#!/usr/bin/env python3
"""TradeChannel dedicated Linux server backend (Python 3 stdlib only).

CLI: python3 tradechannel_linux.py ACTION --input FILE (or --input -).
Also supports exec(source) with __name__='__main__' and a StringIO stdin;
neither execution nor installed systemd units depend on __file__.

Public contract, case sensitive:
  inspect/status/recover/uninstall: {}
  plan: {Name, PublicEndpoint, TunnelSubnet, ClientRequest}
  apply/finalize: {PlanId}
  authorize: {ClientRequest, ClientAddress?}  (automatic first free /32)
  revoke: {DeviceId}
  capabilities/server_info/management_plan/uninstall_preview: {}
  devices: {Offset?, Limit?, IncludeRevoked?} (metadata only; no capture)
  management_apply: {PlanId, ApprovedChangeDigest}
  invite_create: {InviteId?, DeviceName?, ExpiresInHours?} (stable retry preserves original expiry)
  invite_cancel/invite_status: {InviteId}
  authorize_external: {InviteId, PairRequest} (offline pairing compact JWS)
  request_status: {RequestId, RequestDigest?, IncludeTelemetry?, RefreshAuthorization?}
  device_rename: {DeviceId, Name, ExpectedConfigRevision?}
  revoke_preview: {DeviceId}
  revoke/uninstall optionally bind ExpectedConfigRevision + ApprovedChangeDigest.
  transport_plan: {Transport:{Type:"tcp-reality", Port, ServerName}}
  transport_apply: {PlanId, ApprovedChangeDigest} (incremental UDP-to-TCP)
  transport_info: {ClientPublicKey, ServerPublicKey} (existing authorized device only)
  transport_options: {ServerPublicKey, ServerName, CandidatePorts?, CandidateServerNames?}
Every result is {Ok, Action, Data, Message}; errors have Data.Code and a
nonzero exit status. Public data never contains server/client private keys.
Only apply installs distribution packages. transport_apply can install the
pinned TCP component, with an explicit journal and approval; its binary is
retained after rollback. inspect/status/ordinary management queries do not create directories,
locks, plans, packages or services. A plan expires after one hour and is
bound to /etc/machine-id. One active node per dedicated machine.

Runtime resources are a private node directory, two specifically named
systemd units and their exact WantedBy links, one WireGuard interface and
one inet nftables table. No global firewall flush or default-route changes.
Static systemd units run nft, sysctl and wg-quick directly at boot. Input
policy accepts existing management traffic; traffic from the tunnel to the
host is denied. Forwarding policy drops everything except authorized IPv4
tunnel egress and related replies. Private/special destinations are denied.

Active journals precede mutations and contain private 0600 backups. A
crashed transaction blocks writes until explicit recover. Completed apply
retries and identical authorization requests preserve identity/revision.
Recovery refuses foreign files, links, peers, rules, unit overrides or
default-route drift. Failed recovery remains NeedsRecovery. Package installs
are deliberately not reversed; uninstall retains private audit/identity
state and packages, and reports that fact. No external/reboot validation is
claimed. VM integration testing remains necessary on each target image.

finalize explicitly commits a fully verified, pending INITIAL apply only.
It never creates keys, installs packages, changes network resources or restarts
services. recover retains its rollback behavior. Finalizing staged resources
does not reapply an expired plan; every resource must already match in full.
"""

import argparse
import base64
import contextlib
import copy
import datetime as dt
import errno
import hashlib
import ipaddress
import json
import os
import platform
import re
import select
import signal
import socket
import ssl
import stat
import subprocess
import sys
import threading
import time
import traceback
import uuid
try:
    import management_support as management
except ImportError:
    import importlib.util
    management_spec = importlib.util.spec_from_file_location('management_support', os.path.join(os.path.dirname(__file__), 'management_support.py'))
    management = importlib.util.module_from_spec(management_spec)
    management_spec.loader.exec_module(management)
    sys.modules['management_support'] = management
try:
    import transport_support as tcp_support
except ImportError:
    import importlib.util
    spec = importlib.util.spec_from_file_location('transport_support', os.path.join(os.path.dirname(__file__), 'transport_support.py'))
    tcp_support = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(tcp_support)
    sys.modules['transport_support'] = tcp_support


ROOT = "/var/lib/tradechannel"
TUNNEL_MTU = 1380
OWNER = ROOT + "/owner.json"
MANIFEST = ROOT + "/manifest.json"
ACTIVE = ROOT + "/active.json"
POLICY = "/usr/sbin/policy-rc.d"
POLICY_TEXT = "#!/bin/sh\n# TradeChannel temporary package-start guard\nexit 101\n"
MAX_INPUT = 128 * 1024
MAX_STATE = 4 * 1024 * 1024
MAX_PEERS = 256
ACTIONS = ("inspect", "plan", "apply", "finalize", "status", "authorize", "revoke", "recover", "uninstall", "transport_plan", "transport_apply", "transport_info", "transport_candidates", "transport_options", "deployment_state") + management.ACTIONS

TRANSPORT_SERVER_NAMES = ("www.bing.com", "www.microsoft.com")
TRANSPORT_TLS_TOTAL_SECONDS = 8.0
TRANSPORT_TLS_ATTEMPT_SECONDS = 4.0
# A constant child isolates potentially unbounded resolver calls. The parent
# kills/reaps it at the deadline; no background DNS worker can outlive the probe.
# The target is JSON on stdin, never interpolated into Python/shell source.
TRANSPORT_TLS_PROBE = r'''
import json, socket, ssl, sys, time
value = json.loads(sys.stdin.read(2048))
deadline = time.monotonic() + value['TimeoutSeconds']
def remaining():
    budget = deadline - time.monotonic()
    if budget <= 0: raise TimeoutError()
    return budget
result = {'Status': 'Failed', 'ErrorCode': 'TlsProbeFailed'}
try:
    context = ssl.create_default_context()
    context.check_hostname = True
    context.verify_mode = ssl.CERT_REQUIRED
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    with socket.create_connection((value['ServerName'], 443), timeout=remaining()) as stream:
        stream.settimeout(remaining())
        with context.wrap_socket(stream, server_hostname=value['ServerName']):
            remaining()
            result = {'Status': 'TlsEndpointReachable', 'ErrorCode': None}
except ssl.SSLCertVerificationError:
    result['ErrorCode'] = 'TlsCertificateInvalid'
except (TimeoutError, socket.timeout):
    result['ErrorCode'] = 'TlsTimeout'
except socket.gaierror:
    result['ErrorCode'] = 'DnsFailed'
except ssl.SSLError:
    result['ErrorCode'] = 'TlsHandshakeFailed'
except OSError:
    result['ErrorCode'] = 'TcpConnectionFailed'
except Exception:
    pass
sys.stdout.write(json.dumps(result))
'''
RFC1918 = tuple(ipaddress.IPv4Network(x) for x in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"))
BLOCKED = ("0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8",
           "169.254.0.0/16", "172.16.0.0/12", "192.0.0.0/24", "192.168.0.0/16",
           "198.18.0.0/15", "224.0.0.0/4", "240.0.0.0/4")
VALIDATION = {"LocalConfiguration": "Verified", "ExternalConnectivity": "NotTested", "Reboot": "NotTested"}
PROBE_IP = "1.1.1.1"
PROBE_PORT = 443
PROBE_PATH = "/cdn-cgi/trace"
CAPTURE_LIMIT = 400
CAPTURE_HEADER_BYTES = 120  # Maximum IPv4 + TCP headers; never retain raw bytes.


class TCError(Exception):
    def __init__(self, code, message, **data):
        super().__init__(message)
        self.code, self.message, self.data = code, message, data


def require(condition, code="InvalidInput", message="Input does not match the supported schema."):
    if not condition:
        raise TCError(code, message)


def dumps(value):
    return json.dumps(value, ensure_ascii=True, sort_keys=True, separators=(",", ":")) + "\n"


def digest(value):
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def parse_json(text, limit=MAX_STATE):
    def pairs(items):
        out = {}
        for key, value in items:
            require(key not in out, "InvalidJson", "Duplicate JSON fields are not accepted.")
            out[key] = value
        return out
    try:
        require(len(text.encode("utf-8")) <= limit, "InputTooLarge", "JSON exceeds the size limit.")
        result = json.loads(text.lstrip("\ufeff"), object_pairs_hook=pairs,
                            parse_constant=lambda _: require(False, "InvalidJson", "Invalid JSON number."))
        def depth(value, level=0):
            require(level <= 20, "InvalidJson", "JSON nesting exceeds the limit.")
            for child in value.values() if isinstance(value, dict) else value if isinstance(value, list) else []:
                depth(child, level + 1)
        depth(result)
        return result
    except (ValueError, UnicodeError, RecursionError):
        raise TCError("InvalidJson", "JSON could not be decoded.") from None


def fields(value, required, optional=()):
    require(isinstance(value, dict) and set(required) <= set(value) <= set(required) | set(optional))


def guid(value):
    require(isinstance(value, str) and re.fullmatch(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", value))
    require(uuid.UUID(value).int != 0)
    return value


def key(value):
    require(isinstance(value, str) and re.fullmatch(r"[A-Za-z0-9+/]{43}=", value), "InvalidKey", "Invalid WireGuard key.")
    try:
        raw = base64.b64decode(value, validate=True)
    except ValueError:
        raise TCError("InvalidKey", "Invalid WireGuard key.") from None
    require(len(raw) == 32 and any(raw) and base64.b64encode(raw).decode("ascii") == value,
            "InvalidKey", "Invalid WireGuard key.")
    return value


def timestamp(value):
    require(isinstance(value, str) and re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,7})?(?:Z|\+00:00)", value))
    try:
        return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        raise TCError("InvalidInput", "Invalid UTC timestamp.") from None


def utc(value):
    return value.astimezone(dt.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def client_request(value):
    fields(value, ("SchemaVersion", "Kind", "RequestId", "DeviceId", "CreatedAtUtc", "ClientPublicKey", "AddressFamilies"))
    require(type(value["SchemaVersion"]) is int and value["SchemaVersion"] == 1
            and value["Kind"] == "TradeChannel.ClientRequest" and value["AddressFamilies"] == ["IPv4"])
    guid(value["RequestId"])
    guid(value["DeviceId"])
    timestamp(value["CreatedAtUtc"])
    key(value["ClientPublicKey"])
    return copy.deepcopy(value)


def subnet(value):
    try:
        require(isinstance(value, str) and len(value) <= 18)
        network = ipaddress.IPv4Network(value, strict=True)
        require(str(network) == value and 16 <= network.prefixlen <= 30
                and any(network.subnet_of(n) for n in RFC1918))
        return network
    except (ValueError, TCError):
        raise TCError("InvalidSubnet", "TunnelSubnet must be canonical RFC1918 IPv4 /16 through /30.") from None


def endpoint(value):
    require(isinstance(value, str) and re.fullmatch(r"[0-9.]{7,15}:[1-9][0-9]{0,4}", value),
            "InvalidEndpoint", "PublicEndpoint must be a canonical unicast IPv4:port.")
    address, port = value.split(":")
    try:
        ip = ipaddress.IPv4Address(address)
    except ValueError:
        raise TCError("InvalidEndpoint", "Invalid IPv4 endpoint.") from None
    # Matches the Windows IPv4 endpoint contract; public reachability is not inferred.
    require(str(ip) == address and 16777216 <= int(ip) < 3758096384
            and not ip.is_loopback and not ip.is_link_local and int(port) <= 65535,
            "InvalidEndpoint", "Invalid unicast IPv4 endpoint or UDP port.")
    return address, int(port)


def plan_input(value):
    fields(value, ("Name", "PublicEndpoint", "TunnelSubnet", "ClientRequest"), ("Transport",))
    require(isinstance(value["Name"], str) and 1 <= len(value["Name"]) <= 80
            and value["Name"] == value["Name"].strip() and value["Name"].isprintable())
    endpoint(value["PublicEndpoint"])
    subnet(value["TunnelSubnet"])
    client_request(value["ClientRequest"])
    if 'Transport' in value:
        transport = value['Transport']
        fields(transport, ('Type', 'Port', 'ServerName'))
        require(transport['Type'] == 'tcp-reality' and type(transport['Port']) is int and 1 <= transport['Port'] <= 65535)
        require(isinstance(transport['ServerName'], str) and len(transport['ServerName']) <= 253
                and re.fullmatch(r'(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}', transport['ServerName']),
                'InvalidTransport', 'Reality requires a valid fully qualified handshake server name.')
    return copy.deepcopy(value)


def addresses(network):
    return str(network.network_address + 1) + "/" + str(network.prefixlen), str(network.network_address + 2) + "/32"


def client_address(network, value):
    try:
        require(isinstance(value, str) and value.endswith("/32"))
        addr = ipaddress.IPv4Interface(value)
        require(str(addr) == value and network.network_address + 1 < addr.ip < network.broadcast_address)
        return value
    except (ValueError, TCError):
        raise TCError("InvalidClientAddress", "ClientAddress must be an unused host /32 in TunnelSubnet.") from None


def paths(plan):
    node = guid(plan["NodeId"])
    suffix = node.replace("-", "")[:12]
    directory = ROOT + "/nodes/" + node
    interface = "tc" + suffix[:10]
    prefix = "tradechannel-" + suffix
    fw, wg = prefix + "-firewall.service", prefix + "-tunnel.service"
    result = {"Directory": directory, "Interface": interface, "Table": "tc_" + suffix,
            "Identity": directory + "/identity.json", "Config": directory + "/" + interface + ".conf",
            "Sync": directory + "/sync.conf", "Firewall": directory + "/firewall.json",
            "Sysctl": directory + "/sysctl.conf",
            "FirewallUnit": fw, "TunnelUnit": wg,
            "FirewallService": "/etc/systemd/system/" + fw, "TunnelService": "/etc/systemd/system/" + wg,
            "FirewallLink": "/etc/systemd/system/multi-user.target.wants/" + fw,
            "TunnelLink": "/etc/systemd/system/multi-user.target.wants/" + wg}
    if plan.get('Transport'):
        unit = prefix + '-transport.service'
        result.update(TransportConfig=directory+'/transport.json', TransportUnit=unit,
                      TransportService='/etc/systemd/system/'+unit,
                      TransportLink='/etc/systemd/system/multi-user.target.wants/'+unit)
    return result


def resource_paths(plan):
    p = paths(plan)
    return [p[k] for k in ("Config", "Sync", "Firewall", "Sysctl", "FirewallService", "TunnelService") + (("TransportConfig", "TransportService") if plan.get("Transport") else ())]


def link_paths(plan):
    p = paths(plan)
    result = {p["FirewallLink"]: p["FirewallService"], p["TunnelLink"]: p["TunnelService"]}
    if plan.get('Transport'): result[p['TransportLink']] = p['TransportService']
    return result


def firewall(plan):
    """Generate both nft JSON input and a comparable kernel listing (no flush)."""
    p = paths(plan)
    table, interface, wan = p["Table"], p["Interface"], plan["DefaultInterface"]
    common = {"family": "inet", "table": table}
    items = [{"table": {"family": "inet", "name": table}}]
    def chain(name, kind, priority, policy):
        items.append({"chain": dict(common, name=name, type=kind, hook=name, prio=priority, policy=policy)})
    def match(left, right):
        return {"match": {"op": "==", "left": left, "right": right}}
    def meta(name, value):
        return match({"meta": {"key": name}}, value)
    def ip(field, value):
        net = ipaddress.IPv4Network(value)
        rhs = str(net.network_address) if net.prefixlen == 32 else {"prefix": {"addr": str(net.network_address), "len": net.prefixlen}}
        return match({"payload": {"protocol": "ip", "field": field}}, rhs)
    def icmp_type(value):
        # ICMPv4 type only; code and echo are deliberately not matched.
        return match({"payload": {"protocol": "icmp", "field": "type"}}, value)
    def state(value):
        # Conntrack state is a bitmask: nft's canonical JSON uses membership.
        # Upstream tests/py/any/ct.t.json (nftables 1.0.9) documents this form:
        # https://www.netfilter.org/projects/nftables/files/nftables-1.0.9.tar.xz
        return {"match": {"op": "in", "left": {"ct": {"key": "state"}}, "right": value}}
    def rule(name, expressions, verdict):
        items.append({"rule": dict(common, chain=name, expr=expressions + [{verdict: None}],
                                   comment="TradeChannel:" + plan["NodeId"])})
    incoming, outgoing = meta("iifname", interface), meta("oifname", interface)
    chain("input", "filter", -5, "accept")
    # Path-MTU discovery needs ICMP before any drop: otherwise the server can
    # never learn a smaller MTU and large packets black-hole silently.
    rule("input", [icmp_type(3)], "accept")
    rule("input", [icmp_type(11)], "accept")
    rule("input", [incoming], "drop")
    rule("input", [meta("iifname", wan), meta("nfproto", "ipv4"),
                   match({"payload": {"protocol": "udp", "field": "dport"}}, endpoint(plan["PublicEndpoint"])[1])], "accept")
    chain("forward", "filter", -5, "drop")
    rule("forward", [icmp_type(3)], "accept")
    rule("forward", [icmp_type(11)], "accept")
    rule("forward", [state("invalid")], "drop")
    rule("forward", [incoming, outgoing], "drop")
    for cidr in BLOCKED + (endpoint(plan["PublicEndpoint"])[0] + "/32",):
        rule("forward", [incoming, ip("daddr", cidr)], "drop")
    rule("forward", [incoming, meta("oifname", wan), ip("saddr", plan["TunnelSubnet"])], "accept")
    for ctstate in ("established", "related"):
        rule("forward", [meta("iifname", wan), outgoing, ip("daddr", plan["TunnelSubnet"]), state(ctstate)], "accept")
    chain("postrouting", "nat", 100, "accept")
    rule("postrouting", [incoming, meta("oifname", wan), ip("saddr", plan["TunnelSubnet"])], "masquerade")
    return {"nftables": items}


def nft_normalized(value):
    """Ignore allocation IDs and declaration placement, never rule order.

    Ubuntu 24.04 nft lists all chain declarations before listing their rules;
    generated input interleaves each declaration with that chain's rules.
    Stable-partition declarations from statements on both sides. The order of
    declarations, rules and expressions within each partition stays unchanged;
    policies, priorities, ownership comments, counters and all matches remain
    part of the comparison. This does not alter generated files or journals.
    """
    def clean(obj):
        if isinstance(obj, dict):
            return {k: clean(v) for k, v in obj.items() if k not in ("handle", "index")}
        if isinstance(obj, list):
            return [clean(v) for v in obj]
        return obj
    require(isinstance(value, dict) and isinstance(value.get("nftables"), list), "ProbeFailed", "Invalid nftables inspection.")
    items = clean([x for x in value["nftables"] if "metainfo" not in x])
    declarations = [x for x in items if set(x) in ({"table"}, {"chain"})]
    statements = [x for x in items if set(x) not in ({"table"}, {"chain"})]
    return declarations + statements


def resources(plan, private, peers, transport_identity=None):
    p = paths(plan)
    header = ["[Interface]", "PrivateKey = " + key(private), "ListenPort = " + str(endpoint(plan["PublicEndpoint"])[1])]
    peer_lines = []
    for peer in sorted(peers, key=lambda x: x["ClientAddress"]):
        peer_lines += ["", "[Peer]", "PublicKey = " + key(peer["ClientPublicKey"]), "AllowedIPs = " + peer["ClientAddress"]]
    config = "\n".join(header + ["Address = " + plan["ServerAddress"], "MTU = " + str(TUNNEL_MTU), "Table = off"] + peer_lines) + "\n"
    sync = "\n".join(header + peer_lines) + "\n"
    # BBR is why the TCP outer tunnel is usable on a lossy cross-border path:
    # CUBIC treats loss as congestion and collapses throughput, which is exactly
    # the condition this transport exists to survive. fq is BBR's required qdisc.
    # The buffer sizes below are the practical bandwidth-delay product for long
    # paths, well above the kernel default that otherwise caps a single flow.
    sysctl = (
              "# Managed by TradeChannel; removed on uninstall.\n"
              "net.core.default_qdisc=fq\n"
              "net.ipv4.tcp_congestion_control=bbr\n"
              "net.core.rmem_max=26214400\n"
              "net.core.wmem_max=26214400\n"
              "net.ipv4.tcp_rmem=4096 87380 26214400\n"
              "net.ipv4.tcp_wmem=4096 65536 26214400\n"
              )
    rules = {"nftables": [{"create" if "table" in x else "add": x} for x in firewall(plan)["nftables"]]}
    # nft's create prevents adopting an existing table at boot or on a retry.
    fw = ("[Unit]\nDescription=TradeChannel IPv4 firewall\nWants=network-online.target\n"
          "After=network-online.target\nBefore=" + p["TunnelUnit"] + "\n\n[Service]\nType=oneshot\nRemainAfterExit=yes\n"
          "ExecStart=/usr/sbin/sysctl -q --load " + p["Sysctl"] + "\n"
          "ExecStart=/usr/sbin/nft -j -f " + p["Firewall"] + "\n"
          "ExecStart=/usr/sbin/sysctl -q -w net.ipv4.ip_forward=1\n"
          "ExecStop=-/usr/sbin/nft delete table inet " + p["Table"] + "\n"
          "StandardOutput=null\nStandardError=null\nUMask=0077\n\n[Install]\nWantedBy=multi-user.target\n")
    wg = ("[Unit]\nDescription=TradeChannel WireGuard IPv4 tunnel\nWants=network-online.target\n"
          "Requires=" + p["FirewallUnit"] + "\nAfter=network-online.target " + p["FirewallUnit"] + "\n"
          "PartOf=" + p["FirewallUnit"] + "\n\n[Service]\nType=oneshot\nRemainAfterExit=yes\n"
          "ExecStart=/usr/bin/wg-quick up " + p["Config"] + "\nExecStop=/usr/bin/wg-quick down " + p["Config"] + "\n"
          "StandardOutput=null\nStandardError=null\nUMask=0077\n\n[Install]\nWantedBy=multi-user.target\n")
    result = {p["Config"]: config, p["Sync"]: sync, p["Firewall"]: dumps(rules), p["Sysctl"]: sysctl,
              p["FirewallService"]: fw, p["TunnelService"]: wg}
    if plan.get('Transport'):
        require(transport_identity is not None, 'IdentityMissing', 'TCP identity is missing.')
        result[p['TransportConfig']] = dumps(tcp_support.configuration(plan, peers, transport_identity))
        result[p['TransportService']] = ('[Unit]\nDescription=TradeChannel TCP transport\n'
            'Wants=network-online.target\nRequires='+p['TunnelUnit']+'\nAfter=network-online.target '+p['TunnelUnit']+'\n'
            'PartOf='+p['TunnelUnit']+'\n\n[Service]\nType=simple\n'
            'ExecStart='+tcp_support.BINARY+' run -c '+p['TransportConfig']+'\n'
            'WorkingDirectory='+tcp_support.BIN_DIRECTORY+'\nEnvironment=LD_LIBRARY_PATH='+tcp_support.BIN_DIRECTORY+'\n'
            'Restart=on-failure\nRestartSec=3\nUMask=0077\nNoNewPrivileges=yes\n'
            'ProtectSystem=strict\nProtectHome=yes\nPrivateTmp=yes\n'
            'StandardOutput=null\nStandardError=null\n\n[Install]\nWantedBy=multi-user.target\n')
    return result


def client_response(plan, manifest, peer):
    response = {"SchemaVersion": 1, "Kind": "TradeChannel.ClientResponse", "Status": "Authorized",
            "RequestId": peer["RequestId"], "DeviceId": peer["DeviceId"], "NodeId": plan["NodeId"], "NodeName": plan["Name"],
            "ClientPublicKey": peer["ClientPublicKey"], "ClientAddress": peer["ClientAddress"],
            "ServerPublicKey": manifest["ServerPublicKey"], "PublicEndpoint": plan["PublicEndpoint"],
            "TunnelSubnet": plan["TunnelSubnet"], "ServerAddress": plan["ServerAddress"],
            "AllowedIPs": ["0.0.0.0/0"], "PersistentKeepalive": 25, "AddressFamilies": ["IPv4"], "MTU": TUNNEL_MTU,
            "ConfigRevision": manifest["ConfigRevision"],
            "Validation": {"LocalAuthorization": "Verified", "CloudFirewall": "NotVerified",
                           "ExternalConnectivity": "NotTested", "Handshake": "NotTested"}}
    if plan.get('Transport'): response['Transport'] = tcp_support.public_parameters(plan, manifest, peer)
    return response


class SecureFS:
    """All writes are pinned by Backend; no-follow checks also cover ancestors.

    State is root-only. Protected non-writable ancestors plus a process lock
    exclude unprivileged rename races. Privileged hostile code is out of scope.
    Intentional systemd links use separate, exact-target operations.
    """
    def check(self, path, leaf_link=False):
        require(path.startswith("/") and os.path.normpath(path) == path, "UnsafePath", "Noncanonical resource path.")
        parts = path.split("/")[1:]
        cursor = ""
        for i, part in enumerate(parts):
            cursor += "/" + part
            try:
                info = os.lstat(cursor)
            except FileNotFoundError:
                continue
            islink = stat.S_ISLNK(info.st_mode) or bool(getattr(info, "st_file_attributes", 0) & 0x400)
            if leaf_link and i == len(parts) - 1 and stat.S_ISLNK(info.st_mode):
                require(info.st_uid == 0, "UnsafePath", "Link is not root owned.")
                return
            require(not islink and info.st_uid == 0 and not info.st_mode & 0o022,
                    "UnsafePath", "Resource path has unsafe ownership, permissions or links.")
            require(stat.S_ISDIR(info.st_mode) or (i == len(parts) - 1 and stat.S_ISREG(info.st_mode) and info.st_nlink == 1),
                    "UnsafePath", "Resource is not a private regular file or directory.")
            if cursor == ROOT or cursor.startswith(ROOT + "/"):
                require(stat.S_IMODE(info.st_mode) == (0o700 if stat.S_ISDIR(info.st_mode) else 0o600),
                        "UnsafePath", "State permissions must be 0700/0600.")

    def exists(self, path):
        self.check(path)
        return os.path.lexists(path)

    def metadata(self, path):
        """Read only lstat metadata, never dereference an unexpected leaf link."""
        self.check(os.path.dirname(path))
        try:
            info = os.lstat(path)
        except FileNotFoundError:
            return {"Exists": False, "Type": "Missing", "Mode": None}
        kind = ("Symlink" if stat.S_ISLNK(info.st_mode) else "RegularFile" if stat.S_ISREG(info.st_mode)
                else "Directory" if stat.S_ISDIR(info.st_mode) else "Other")
        return {"Exists": True, "Type": kind, "Mode": format(stat.S_IMODE(info.st_mode), "04o"),
                "Uid": info.st_uid, "LinkCount": info.st_nlink, "Size": info.st_size,
                "ReparsePoint": bool(getattr(info, "st_file_attributes", 0) & 0x400)}

    def read(self, path):
        self.check(path)
        if not os.path.exists(path):
            return None
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(fd, "r", encoding="utf-8") as stream:
            text = stream.read(MAX_STATE + 1)
        require(len(text.encode("utf-8")) <= MAX_STATE, "StateTooLarge", "State file exceeds the size limit.")
        return text

    def mkdir(self, path):
        self.check(path)
        if os.path.exists(path):
            require(os.path.isdir(path), "UnsafePath", "Expected a directory.")
            return
        os.mkdir(path, 0o700)
        self._sync(os.path.dirname(path))

    def list(self, path):
        self.check(path)
        if not os.path.exists(path):
            return []
        return sorted(os.listdir(path))

    def _sync(self, path):
        fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)

    def cas(self, path, before, after, mode=0o600):
        """Compare-before-write: never adopt an unexpected existing file."""
        require(self.read(path) == before, "OwnershipMismatch", "A resource changed; refusing to overwrite it.")
        if before == after:
            return
        directory = os.path.dirname(path)
        if after is None:
            os.unlink(path)
            self._sync(directory)
            return
        temp = directory + "/.tc-write-" + uuid.uuid4().hex
        fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode)
        try:
            with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as stream:
                stream.write(after)
                stream.flush()
                os.fsync(stream.fileno())
            self.check(path)
            require(self.read(path) == before, "OwnershipMismatch", "Resource changed during write.")
            if before is None:
                os.link(temp, path, follow_symlinks=False)
                os.unlink(temp)
            else:
                os.replace(temp, path)
            self._sync(directory)
        finally:
            if os.path.lexists(temp):
                os.unlink(temp)

    def link(self, path):
        self.check(path, leaf_link=True)
        if not os.path.lexists(path):
            return None
        require(os.path.islink(path), "OwnershipMismatch", "Expected an owned systemd link.")
        return os.readlink(path)

    def cas_link(self, path, before, after):
        require(self.link(path) == before, "OwnershipMismatch", "Systemd link changed; refusing to modify it.")
        if before == after:
            return
        require(before is None or after is None, "OwnershipMismatch", "Refusing to replace a systemd link.")
        if after is None:
            os.unlink(path)
        else:
            os.symlink(after, path)
        self._sync(os.path.dirname(path))

    @contextlib.contextmanager
    def lock(self, readonly=False):
        import fcntl
        path = ROOT + "/lock"
        self.check(path)
        flags = os.O_RDONLY if readonly else os.O_RDWR
        fd = os.open(path, flags | os.O_NOFOLLOW)
        try:
            try:
                fcntl.flock(fd, (fcntl.LOCK_SH if readonly else fcntl.LOCK_EX) | fcntl.LOCK_NB)
            except BlockingIOError:
                raise TCError("Busy", "Another server operation is running.") from None
            yield
        finally:
            os.close(fd)


def packet_header(packet, address, wan, tunnel, wg_port):
    """Decode only allowlisted IPv4 headers from AF_PACKET/SOCK_DGRAM.

    No Ethernet header, payload, raw options, hardware address or peer key is
    returned. Incomplete headers and all IP fragments are discarded; a complete
    header with a snaplen-truncated payload still supplies the original length.
    Direction is relative to the named interface (including the WG interface).
    """
    if len(address) < 3 or address[0] not in (wan, tunnel) or address[1] != 0x0800 or address[2] not in (0, 4):
        return None
    if len(packet) < 20 or packet[0] >> 4 != 4:
        return None
    ihl = (packet[0] & 15) * 4
    total = int.from_bytes(packet[2:4], "big")
    if ihl < 20 or len(packet) < ihl or total < ihl or int.from_bytes(packet[6:8], "big") & 0xbfff:
        return None
    protocol = packet[9]
    minimum = 20 if protocol == 6 else 8 if protocol == 17 else 0
    if not minimum or len(packet) < ihl + minimum or total < ihl + minimum:
        return None
    source = socket.inet_ntoa(packet[12:16])
    destination = socket.inet_ntoa(packet[16:20])
    sport = int.from_bytes(packet[ihl:ihl + 2], "big")
    dport = int.from_bytes(packet[ihl + 2:ihl + 4], "big")
    if protocol == 6:
        if 22 in (sport, dport) or not ((destination == PROBE_IP and dport == PROBE_PORT) or
                                      (source == PROBE_IP and sport == PROBE_PORT)):
            return None
        size = (packet[ihl + 12] >> 4) * 4
        if size < 20 or len(packet) < ihl + size or total < ihl + size:
            return None
        mss, cursor = None, ihl + 20
        while cursor < ihl + size:
            kind = packet[cursor]
            if kind == 0:  # End of options; no raw padding is retained.
                break
            if kind == 1:
                cursor += 1
                continue
            if cursor + 2 > ihl + size:
                return None
            length = packet[cursor + 1]
            if length < 2 or cursor + length > ihl + size:
                return None
            if kind == 2:
                if length != 4 or mss is not None:
                    return None
                mss = int.from_bytes(packet[cursor + 2:cursor + 4], "big")
            cursor += length
        extra = {"TcpFlags": ((packet[ihl + 12] & 1) << 8) | packet[ihl + 13],
                 "TcpSequence": int.from_bytes(packet[ihl + 4:ihl + 8], "big"),
                 "TcpAcknowledgment": int.from_bytes(packet[ihl + 8:ihl + 12], "big"),
                 "TcpHeaderLength": size, "TcpMss": mss, "PayloadLength": total - ihl - size}
    else:
        # Only the server side of the planned WG UDP port, on the WAN. The
        # public endpoint may be NATed, so it need not equal the WAN local IP.
        if address[0] != wan or (dport if address[2] == 0 else sport) != wg_port:
            return None
        size = int.from_bytes(packet[ihl + 4:ihl + 6], "big")
        if size < 8 or size != total - ihl:
            return None
        extra = {"PayloadLength": size - 8}
    return dict(extra, Interface=address[0], Direction="Incoming" if address[2] == 0 else "Outgoing",
                Protocol="TCP" if protocol == 6 else "UDP", SourceAddress=source, DestinationAddress=destination,
                SourcePort=sport, DestinationPort=dport, IpLength=total)


class HeaderCapture:
    """Bounded, receive-only sockets; the worker expires even during a slow probe.

    Packet bytes exist only while decoding a bounded header snapshot. Only the
    metadata allowlist above can enter the report. No pcap, payload or file I/O.
    """
    def __init__(self, plan, seconds):
        require(type(seconds) is int and 1 <= seconds <= 60)
        self.wan, self.tunnel = plan["DefaultInterface"], paths(plan)["Interface"]
        self.wg_port = endpoint(plan["PublicEndpoint"])[1]
        self.seconds = seconds
        self.sockets, self.worker = [], None
        self.stop = threading.Event()
        self.report = {"Status": "NotStarted", "RequestedSeconds": seconds, "SampleLimit": CAPTURE_LIMIT,
                       "MatchedPackets": 0, "OmittedPackets": 0, "Samples": []}

    def fail(self, code):
        self.report.update(Status="Failed", Code=code)

    def close(self):
        sockets, self.sockets = self.sockets, []
        for stream in sockets:
            try:
                stream.close()
            except Exception:
                self.fail("CaptureCloseFailed")

    def start(self):
        self.started = time.monotonic()
        self.deadline = self.started + self.seconds
        self.wall_started = dt.datetime.now(dt.timezone.utc)
        self.report["StartedAtUtc"] = self.wall_started.isoformat(timespec="milliseconds").replace("+00:00", "Z")
        try:
            if not hasattr(socket, "AF_PACKET"):
                self.fail("CaptureUnsupported")
                return
            for interface in (self.wan, self.tunnel):
                # Protocol 0 receives nothing until bound to the exact interface.
                # ETH_P_ALL (3) includes outgoing packets; filter IPv4 in Python.
                # https://man7.org/linux/man-pages/man7/packet.7.html
                stream = socket.socket(socket.AF_PACKET, socket.SOCK_DGRAM, 0)
                self.sockets.append(stream)
                stream.setblocking(False)
                stream.bind((interface, 3))
            self.report["Status"] = "Running"
            self.worker = threading.Thread(target=self.collect, name="tradechannel-headers", daemon=True)
            self.worker.start()
        except Exception as exc:
            self.worker = None
            self.fail("CapturePermissionDenied" if isinstance(exc, PermissionError) else "CaptureStartFailed")
            self.close()

    def collect(self):
        try:
            while not self.stop.is_set():
                remaining = self.deadline - time.monotonic()
                if remaining <= 0:
                    break
                ready, _, _ = select.select(self.sockets, [], [], min(0.1, remaining))
                for stream in ready:
                    if self.stop.is_set() or time.monotonic() >= self.deadline:
                        break
                    try:
                        packet, address = stream.recvfrom(CAPTURE_HEADER_BYTES)
                    except (BlockingIOError, InterruptedError):
                        continue
                    elapsed = time.monotonic() - self.started
                    if elapsed >= self.seconds:
                        break
                    sample = packet_header(packet, address, self.wan, self.tunnel, self.wg_port)
                    del packet, address
                    if sample is None:
                        continue
                    self.report["MatchedPackets"] += 1
                    if len(self.report["Samples"]) < CAPTURE_LIMIT:
                        stamp = self.wall_started + dt.timedelta(seconds=elapsed)
                        sample.update(TimeUtc=stamp.isoformat(timespec="milliseconds").replace("+00:00", "Z"),
                                      OffsetMilliseconds=round(elapsed * 1000, 3))
                        self.report["Samples"].append(sample)
                    else:
                        self.report["OmittedPackets"] += 1
            if not self.stop.is_set():
                self.report["Status"] = "Completed"
        except Exception:
            self.fail("CaptureReadFailed")
        finally:
            self.close()
            self.report["ElapsedMilliseconds"] = round((time.monotonic() - self.started) * 1000)

    def finish(self):
        if self.worker is not None:
            try:
                self.worker.join(max(0, self.deadline - time.monotonic()) + 0.5)
                if self.worker.is_alive():
                    self.stop.set()
                    self.close()
                    self.fail("CaptureDeadlineExceeded")
            except Exception:
                self.stop.set()
                self.close()
                self.fail("CaptureFinishFailed")
        self.report.setdefault("ElapsedMilliseconds", round((time.monotonic() - self.started) * 1000))
        # A deadline failure must not expose a report that a late worker mutates.
        return copy.deepcopy(self.report)


def probe_source_ipv4(value):
    try:
        require(isinstance(value, str))
        address = ipaddress.IPv4Address(value)
    except ValueError:
        raise TCError("InvalidInput", "ProbeSourceIPv4 must be a public unicast IPv4 address.") from None
    require(str(address) == value and address.is_global and not address.is_multicast and not address.is_reserved,
            "InvalidInput", "ProbeSourceIPv4 must be a public unicast IPv4 address.")
    return value


def wireguard_datagram(packet):
    """Check framing only; authentication remains entirely with WireGuard."""
    kind = int.from_bytes(packet[:4], "little")
    if kind in (1, 2, 3):
        return len(packet) == {1: 148, 2: 92, 3: 64}[kind]
    # Transport padding can stop at the tunnel MTU, which need not be a
    # multiple of 16. The empty encrypted keepalive is exactly 32 bytes.
    return kind == 4 and 32 <= len(packet) <= 65507


class UdpPortProbe:
    """One source IP, UDP 443, loopback WG only; no payload retained or logged."""
    def __init__(self, plan, seconds, source):
        require(type(seconds) is int and 1 <= seconds <= 60)
        self.source = probe_source_ipv4(source)
        self.target = ("127.0.0.1", endpoint(plan["PublicEndpoint"])[1])
        self.seconds = seconds
        self.sockets, self.worker = [], None
        self.stop = threading.Event()
        self.started = self.deadline = None
        self.report = {"Status": "NotStarted", "Temporary": True, "PersistentConfigChanged": False,
                       "ListenPort": 443, "SourceIPv4": self.source,
                       "Target": {"Address": self.target[0], "Port": self.target[1]},
                       "RequestedSeconds": seconds, "Started": False, "Stopped": False,
                       "ToWireGuardPackets": 0, "ToWireGuardBytes": 0, "ToClientPackets": 0, "ToClientBytes": 0,
                       "RejectedSourcePackets": 0, "RejectedWireGuardPackets": 0}

    def fail(self, code):
        self.report.update(Status="Failed", Code=code)

    def close(self):
        streams, self.sockets = self.sockets, []
        self.report["Stopped"] = True
        for stream in streams:
            try:
                stream.close()
            except Exception:
                self.report["Stopped"] = False
                self.fail("UdpPortProbeCloseFailed")

    def start(self, deadline):
        self.started = time.monotonic()
        self.deadline = min(deadline, self.started + self.seconds)
        self.report["StartedAtUtc"] = utc(dt.datetime.now(dt.timezone.utc))
        try:
            if self.started >= self.deadline:
                self.fail("UdpPortProbeDeadlineExceeded")
                self.close()
                return
            # No SO_REUSEADDR/SO_REUSEPORT: an existing listener is never shared,
            # displaced or stopped. Both sockets belong only to this worker.
            public = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            self.sockets.append(public)
            public.bind(("0.0.0.0", 443))
            public.setblocking(False)
            upstream = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            self.sockets.append(upstream)
            upstream.bind(("127.0.0.1", 0))
            upstream.connect(self.target)
            upstream.setblocking(False)
            self.report.update(Status="Running", Started=True)
            self.worker = threading.Thread(target=self.forward, name="tradechannel-udp-port-probe", daemon=True)
            self.worker.start()
        except Exception as exc:
            self.worker = None
            code = "UdpPortProbePortInUse" if isinstance(exc, OSError) and exc.errno == errno.EADDRINUSE else "UdpPortProbeStartFailed"
            self.fail(code)
            self.close()

    def forward(self):
        client = None
        try:
            public, upstream = self.sockets
            while not self.stop.is_set():
                remaining = self.deadline - time.monotonic()
                if remaining <= 0:
                    break
                ready, _, _ = select.select(self.sockets, [], [], min(0.1, remaining))
                for stream in ready:
                    if self.stop.is_set() or time.monotonic() >= self.deadline:
                        break
                    try:
                        packet, address = stream.recvfrom(65508)
                    except (BlockingIOError, InterruptedError):
                        continue
                    try:
                        if self.stop.is_set() or time.monotonic() >= self.deadline:
                            break
                        incoming = stream is public
                        allowed = (address[0] == self.source and 1 <= address[1] <= 65535) if incoming else address == self.target
                        if not allowed:
                            self.report["RejectedSourcePackets"] += 1
                            continue
                        if not wireguard_datagram(packet):
                            self.report["RejectedWireGuardPackets"] += 1
                            continue
                        if incoming:
                            sent = upstream.send(packet)
                            client = address  # Update only after a valid, forwarded datagram.
                            counter = "ToWireGuard"
                        elif client is not None:
                            sent = public.sendto(packet, client)
                            counter = "ToClient"
                        else:
                            continue
                        if sent != len(packet):
                            raise OSError()
                        self.report[counter + "Packets"] += 1
                        self.report[counter + "Bytes"] += sent
                    finally:
                        del packet, address
            if not self.stop.is_set():
                self.report["Status"] = "Completed"
            else:
                self.fail("UdpPortProbeCancelled")
        except Exception:
            self.fail("UdpPortProbeIoFailed")
        finally:
            self.close()
            self.report["ElapsedMilliseconds"] = round((time.monotonic() - self.started) * 1000)

    def finish(self):
        if self.worker is not None:
            try:
                self.worker.join(max(0, self.deadline - time.monotonic()) + 0.5)
                if self.worker.is_alive():
                    self.stop.set()
                    self.close()
                    self.worker.join(0.2)
                    self.fail("UdpPortProbeDeadlineExceeded")
            except Exception:
                self.stop.set()
                self.close()
                self.fail("UdpPortProbeFinishFailed")
        else:
            self.close()
        self.report.setdefault("ElapsedMilliseconds", round((time.monotonic() - self.started) * 1000) if self.started is not None else 0)
        return copy.deepcopy(self.report)


class LinuxOS:
    """OS seam: tests substitute this entire class. Never executes on Windows."""
    COMMANDS = {"ip": "/usr/sbin/ip", "wg": "/usr/bin/wg", "wg-quick": "/usr/bin/wg-quick",
                "nft": "/usr/sbin/nft", "sysctl": "/usr/sbin/sysctl", "systemctl": "/usr/bin/systemctl",
                "apt-get": "/usr/bin/apt-get", "systemd-detect-virt": "/usr/bin/systemd-detect-virt", "openssl": "/usr/bin/openssl", "ss": "/usr/bin/ss"}

    def guard(self):
        require(sys.platform == "linux" and os.geteuid() == 0, "UnsupportedHost", "This backend requires root on a supported Linux VM.")

    def available(self, command):
        path = self.COMMANDS.get(command, "/usr/sbin/" + command)
        return os.path.isfile(path) and os.access(path, os.X_OK)

    def run(self, argv, input_text=None, acceptable=(0,), timeout=60):
        self.guard()
        if argv[0] == tcp_support.BINARY:
            # Only this exact hash-pinned owned executable may use an absolute
            # path. Do not widen the system command seam to arbitrary scripts.
            path = self.verify_transport()
        else:
            path = self.COMMANDS.get(argv[0], "/usr/sbin/" + argv[0])
            require(path.startswith(("/usr/bin/", "/usr/sbin/")) and "/" not in argv[0], "InvalidCommand", "Unrecognized command.")
        env = {"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "LANG": "C", "LC_ALL": "C",
               "DEBIAN_FRONTEND": "noninteractive", "NEEDRESTART_MODE": "l", "UCF_FORCE_CONFFOLD": "1"}
        try:
            with subprocess.Popen([path] + list(argv[1:]), stdin=subprocess.PIPE, text=True,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, shell=False,
                                  start_new_session=True, env=env) as proc:
                try:
                    output, _ = proc.communicate(input_text, timeout=timeout)
                except subprocess.TimeoutExpired:
                    # A timed-out apt process must not leave children running after
                    # its temporary service-start policy is removed by recovery.
                    os.killpg(proc.pid, signal.SIGKILL)
                    proc.communicate()
                    raise
        except (OSError, subprocess.TimeoutExpired):
            raise TCError("CommandFailed", "A required system operation failed or timed out.") from None
        require(proc.returncode in acceptable, "CommandFailed", "A required system operation failed; tool output was suppressed.")
        require(len(output) <= MAX_STATE, "ProbeFailed", "System inspection output exceeds the limit.")
        return output.strip()

    def read_system(self, path):
        # procfs/sysctl files are virtual and can reject oversized individual
        # reads even though their content is only a few bytes. Bound each read,
        # as well as the total, instead of asking a kernel handler for 4 MiB.
        content = bytearray()
        try:
            with open(path, "rb", buffering=0) as stream:
                while True:
                    chunk = stream.read(min(4096, MAX_STATE + 1 - len(content)))
                    if not chunk:
                        break
                    content.extend(chunk)
                    require(len(content) <= MAX_STATE, "ProbeFailed", "System file exceeds the inspection limit.")
            return content.decode("utf-8")
        except OSError as exc:
            public_paths = {"/etc/os-release", "/etc/machine-id", "/etc/ufw/ufw.conf",
                            "/proc/net/udp", "/proc/net/udp6", "/proc/net/ip_tables_names", "/proc/net/ip6_tables_names",
                            "/proc/sys/net/ipv4/ip_forward", "/proc/sys/net/ipv6/conf/all/forwarding"}
            name = path if path in public_paths else "system file"
            raise TCError("SystemReadFailed", "System state read failed: %s (errno=%s)." % (name, exc.errno),
                          SystemFile=name, Errno=exc.errno) from None

    def probe(self):
        self.guard()
        osinfo = {}
        for line in self.read_system("/etc/os-release").splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                osinfo[k] = v.strip('"')
        machine = self.read_system("/etc/machine-id").strip()
        require(re.fullmatch(r"[a-f0-9]{32}", machine) and int(machine, 16), "ProbeFailed", "A stable machine-id is required.")
        required = ("ip", "systemctl", "systemd-detect-virt", "apt-get", "sysctl")
        require(all(self.available(x) for x in required), "ProbeFailed", "Required base system tools are missing.")
        virt = self.run(["systemd-detect-virt", "--container"], acceptable=(0, 1))
        routes = parse_json(self.run(["ip", "-j", "-4", "route", "show", "table", "all"]))
        rules = parse_json(self.run(["ip", "-j", "-4", "rule", "show"]))
        links = parse_json(self.run(["ip", "-j", "-d", "link", "show"]))
        ips = parse_json(self.run(["ip", "-j", "-4", "address", "show"]))
        services = self.run(["systemctl", "list-unit-files", "--type=service", "--no-pager", "--no-legend"])
        service_names = [line.split()[0] for line in services.splitlines() if line.split()]
        enabled_names = [line.split()[0] for line in services.splitlines()
                         if len(line.split()) > 1 and line.split()[1] in ("enabled", "enabled-runtime")]
        active = self.run(["systemctl", "list-units", "--type=service", "--state=active", "--no-pager", "--no-legend"])
        active_names = [line.split()[0] for line in active.splitlines() if line.split()]
        nft = parse_json(self.run(["nft", "-j", "list", "ruleset"])) if self.available("nft") else None
        legacy = []
        for family, tool in (("ip", "iptables-legacy-save"), ("ip6", "ip6tables-legacy-save")):
            filename = "/proc/net/" + family + "_tables_names"
            if os.path.exists(filename) and self.read_system(filename).strip() and not self.available(tool):
                legacy.append("Legacy kernel tables cannot be inspected with the installed tools.")
        for tool in ("iptables-legacy-save", "ip6tables-legacy-save", "iptables-save", "ip6tables-save"):
            if self.available(tool):
                text = self.run([tool])
                # Empty default ACCEPT chains are harmless; any rules/custom chains/drop policy are not.
                legacy += [line for line in text.splitlines() if line.startswith("-A ") or
                           (line.startswith(":") and not re.match(r":(?:INPUT|OUTPUT|FORWARD|PREROUTING|POSTROUTING) ACCEPT \[", line))]
        udp = set()
        for path in ("/proc/net/udp", "/proc/net/udp6"):
            if os.path.exists(path):
                for line in self.read_system(path).splitlines()[1:]:
                    udp.add(int(line.split()[1].rsplit(":", 1)[1], 16))
        wgfiles = sorted(os.listdir("/etc/wireguard")) if os.path.isdir("/etc/wireguard") else []
        ufw_enabled = False
        if os.path.exists("/etc/ufw/ufw.conf"):
            ufw_enabled = bool(re.search(r"(?m)^\s*ENABLED\s*=\s*yes\s*$", self.read_system("/etc/ufw/ufw.conf")))
        return {"OS": {"Id": osinfo.get("ID", ""), "Version": osinfo.get("VERSION_ID", ""), "Architecture": platform.machine()},
                "MachineBinding": digest(machine), "Container": virt != "none",
                "Systemd": os.path.isdir("/run/systemd/system"), "Routes": routes, "Rules": rules, "Links": links,
                "Addresses": ips, "Services": service_names, "ActiveServices": active_names, "Nft": nft,
                "EnabledServices": enabled_names,
                "LegacyRules": legacy, "WireGuardFiles": wgfiles, "UdpPorts": sorted(udp),
                "Forwarding": self.read_system("/proc/sys/net/ipv4/ip_forward").strip(),
                "IPv6Forwarding": self.read_system("/proc/sys/net/ipv6/conf/all/forwarding").strip()
                    if os.path.exists("/proc/sys/net/ipv6/conf/all/forwarding") else "0",
                "Tools": {x: self.available(x) for x in ("wg", "wg-quick", "nft", "openssl")},
                "UfwEnabled": ufw_enabled,
                "PolicyExists": os.path.lexists(POLICY)}

    def service(self, unit):
        output = self.run(["systemctl", "show", unit, "--no-pager", "--property=LoadState,FragmentPath,DropInPaths,ActiveState,UnitFileState,MainPID,ActiveEnterTimestampMonotonic,ExecMainStartTimestampMonotonic"])
        return dict(line.split("=", 1) for line in output.splitlines() if "=" in line)

    def live(self, interface):
        # Never use wg show dump/showconf: those expose private or preshared keys.
        public = self.run(["wg", "show", interface, "public-key"])
        port = self.run(["wg", "show", interface, "listen-port"])
        rows = self.run(["wg", "show", interface, "allowed-ips"])
        peers = {}
        for line in rows.splitlines():
            public_key, allowed = line.split(None, 1)
            peers[public_key] = allowed.strip()
        return {"PublicKey": public, "Port": port, "Peers": peers,
                "FwMark": self.run(["wg", "show", interface, "fwmark"])}

    def peer_telemetry(self, plan, manifest):
        interface = paths(plan)["Interface"]
        transfers = self.run(["wg", "show", interface, "transfer"], timeout=6)
        handshakes = self.run(["wg", "show", interface, "latest-handshakes"], timeout=6)
        def rows(text, columns):
            result = {}
            for line in text.splitlines():
                parts = line.split()
                require(len(parts) == columns and parts[0] not in result and
                        all(re.fullmatch(r"[0-9]{1,20}", v) for v in parts[1:]),
                        "TelemetryInvalid", "WireGuard telemetry could not be decoded.")
                result[key(parts[0])] = [int(v) for v in parts[1:]]
            return result
        transfer, handshake = rows(transfers, 3), rows(handshakes, 2)
        known = {p["ClientPublicKey"] for p in manifest["Peers"]}
        require(set(transfer) == set(handshake) == known, "TelemetryDrift", "Live telemetry peer identities differ from owned state.")
        return [{"DeviceId": p["DeviceId"], "ClientAddress": p["ClientAddress"],
                 "ReceiveBytes": transfer[p["ClientPublicKey"]][0], "TransmitBytes": transfer[p["ClientPublicKey"]][1],
                 "LatestHandshakeUnix": handshake[p["ClientPublicKey"]][0]} for p in manifest["Peers"]]

    def forward_route(self, plan):
        client = plan["ClientAddress"].split("/")[0]
        result = parse_json(self.run(["ip", "-j", "-4", "route", "get", PROBE_IP,
                                     "from", client, "iif", paths(plan)["Interface"]], timeout=6))
        require(isinstance(result, list) and len(result) <= 8, "ProbeFailed", "Unexpected route lookup output.")
        allowed = {"dst", "from", "src", "prefsrc", "gateway", "dev", "iif", "table", "type", "flags", "cache", "uid"}
        return {"FromClient": client, "IncomingInterface": paths(plan)["Interface"],
                "Routes": [{k: v for k, v in row.items() if k in allowed} for row in result]}

    def direct_https(self):
        """Fixed IPv4 trace; six-second deadline, bounded body, IP-only evidence."""
        self.guard()
        started = time.monotonic()
        deadline = started + 6
        connection = None
        stage = "Connect"
        result = {"Ok": False, "Target": "https://1.1.1.1/cdn-cgi/trace", "TimeoutSeconds": 6,
                  "ProxyUsed": False, "TcpConnected": False, "TlsVerified": False}
        def remaining():
            seconds = deadline - time.monotonic()
            if seconds <= 0:
                raise TimeoutError()
            return seconds
        try:
            connection = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            connection.settimeout(remaining())
            connection.connect((PROBE_IP, PROBE_PORT))
            address, port = connection.getsockname()[:2]
            result.update(TcpConnected=True, LocalAddress=address, LocalPort=port)
            stage = "TLS"
            context = ssl.create_default_context()
            connection.settimeout(remaining())
            connection = context.wrap_socket(connection, server_hostname=PROBE_IP)
            result["TlsVerified"] = True
            stage = "HTTP"
            connection.settimeout(remaining())
            connection.sendall(b"GET /cdn-cgi/trace HTTP/1.1\r\nHost: 1.1.1.1\r\nUser-Agent: TradeChannel-Diagnostics/1\r\nConnection: close\r\n\r\n")
            line = bytearray()
            while len(line) < 128 and not line.endswith(b"\r\n"):
                connection.settimeout(remaining())
                char = connection.recv(1)
                if not char:
                    break
                line.extend(char)
            require(re.fullmatch(rb"HTTP/1\.[01] [1-5][0-9]{2}(?: [^\r\n]*)?\r\n", line) is not None,
                    "HttpsInvalidResponse", "HTTPS status line was invalid.")
            status = int(line[9:12])
            result.update(Ok=200 <= status < 300, HttpStatus=status)
            if result["Ok"]:
                # A trace is independent evidence of server egress, never the
                # SSH endpoint assumption. Missing/oversized bodies keep HTTPS
                # success but leave exit verification explicitly inconclusive.
                result["ExitEvidence"] = "Unavailable"
                try:
                    response = bytearray()
                    while len(response) <= 12288:
                        connection.settimeout(remaining())
                        chunk = connection.recv(min(1024, 12289 - len(response)))
                        if not chunk: break
                        response.extend(chunk)
                    require(len(response) <= 12288 and b"\r\n\r\n" in response, "TraceUnavailable")
                    headers, body = bytes(response).split(b"\r\n\r\n", 1)
                    require(len(headers) <= 8192, "TraceUnavailable")
                    if re.search(rb"(?im)^transfer-encoding:\s*chunked\s*$", headers):
                        decoded = bytearray()
                        while body:
                            line, tail = body.split(b"\r\n", 1)
                            require(re.fullmatch(rb"[0-9a-fA-F]{1,6}", line), "TraceUnavailable")
                            size = int(line, 16)
                            if size == 0: break
                            require(size <= 4096 - len(decoded) and len(tail) >= size + 2 and tail[size:size + 2] == b"\r\n", "TraceUnavailable")
                            decoded.extend(tail[:size]); body = tail[size + 2:]
                        body = bytes(decoded)
                    require(len(body) <= 4096, "TraceUnavailable")
                    ips = re.findall(rb"(?m)^ip=([0-9.]{7,15})\r?$", body)
                    require(len(ips) == 1, "TraceUnavailable")
                    ip = ipaddress.IPv4Address(ips[0].decode("ascii"))
                    require(ip.is_global, "TraceUnavailable")
                    result.update(ObservedExitIPv4=str(ip), ExitEvidence="VerifiedTlsTrace")
                except Exception:
                    pass  # No trace body or raw exception is returned/logged.
            stage = "Completed"
        except Exception as exc:
            code = "Timeout" if isinstance(exc, (TimeoutError, socket.timeout)) else "TlsVerificationFailed" if isinstance(exc, ssl.SSLCertVerificationError) else "HttpsFailed"
            result["Code"] = exc.code if isinstance(exc, TCError) else code
        finally:
            if connection is not None:
                connection.close()
        result.update(Stage=stage, ElapsedMilliseconds=round((time.monotonic() - started) * 1000))
        return result

    def network_probe(self, plan, manifest, repeats, progress, capture_seconds=0,
                      probe_relay_port=0, probe_source_ipv4=None):
        self.guard()
        require(type(probe_relay_port) is int and probe_relay_port in (0, 443)
                and (capture_seconds > 0 if probe_relay_port else probe_source_ipv4 is None))
        def observe(callback):
            try:
                return {"Ok": True, "Data": callback()}
            except Exception as exc:
                return {"Ok": False, "Code": exc.code if isinstance(exc, TCError) else "ProbeFailed"}
        report = {"SchemaVersion": 1, "ReadOnly": True, "Target": {"Address": PROBE_IP, "Port": PROBE_PORT},
                  "ProbeRepeats": repeats, "Capture": {"Status": "NotIncluded"}}
        capture = HeaderCapture(plan, capture_seconds) if capture_seconds else None
        relay = UdpPortProbe(plan, capture_seconds, probe_source_ipv4) if probe_relay_port else None
        try:
            if capture is not None:
                capture.start()
            if relay is not None:
                if capture.report["Status"] == "Running":
                    relay.start(capture.deadline)
                else:
                    relay.fail("UdpPortProbeCaptureUnavailable")
            report["WireGuardBefore"] = observe(lambda: self.peer_telemetry(plan, manifest))
            report["ForwardRoute"] = observe(lambda: self.forward_route(plan))
            progress("Running bounded server HTTPS diagnostics; network configuration is unchanged.")
            report["ServerHttps"] = []
            for _ in range(repeats):
                try:
                    report["ServerHttps"].append(self.direct_https())
                except Exception:
                    if capture is None:
                        raise
                    report["ServerHttps"].append({"Ok": False, "Code": "HttpsFailed"})
        except BaseException:
            if relay is not None:
                relay.stop.set()
                capture.stop.set()
            raise
        finally:
            try:
                if capture is not None:
                    report["Capture"] = capture.finish()
            finally:
                if relay is not None:
                    report["UdpPortProbe"] = relay.finish()
        report["WireGuardAfter"] = observe(lambda: self.peer_telemetry(plan, manifest))
        if capture is not None:
            report["Ok"] = (report["Capture"]["Status"] == "Completed" and
                            all(report[k]["Ok"] for k in ("WireGuardBefore", "ForwardRoute", "WireGuardAfter")) and
                            all(row["Ok"] for row in report["ServerHttps"]) and
                            (relay is None or report["UdpPortProbe"]["Status"] == "Completed"))
        return report

    def ensure_transport(self):
        self.guard()
        return tcp_support.install_binary(require)

    def verify_transport(self):
        self.guard()
        return tcp_support.verify_binary(require)

    def transport_port_busy(self, port):
        return bool(self.run(['ss', '-H', '-ltn', 'sport = :'+str(port)]).strip())

    def tls_endpoint_probe(self, server_name, timeout_seconds):
        """Remote-only, bounded DNS/TCP/TLS certificate check; no Reality auth."""
        self.guard()
        require(isinstance(server_name, str) and 0 < timeout_seconds <= TRANSPORT_TLS_ATTEMPT_SECONDS)
        try:
            reply = subprocess.run([sys.executable, '-I', '-c', TRANSPORT_TLS_PROBE],
                                   input=dumps({'ServerName': server_name, 'TimeoutSeconds': timeout_seconds}),
                                   capture_output=True, text=True, timeout=timeout_seconds, check=False)
            if reply.returncode != 0 or len(reply.stdout) > 1024:
                return {'Status': 'Failed', 'ErrorCode': 'TlsProbeFailed'}
            result = parse_json(reply.stdout, limit=1024)
            if result == {'Status': 'TlsEndpointReachable', 'ErrorCode': None}:
                return result
            if result.get('Status') == 'Failed' and result.get('ErrorCode') in (
                    'TlsCertificateInvalid', 'TlsTimeout', 'DnsFailed', 'TlsHandshakeFailed',
                    'TcpConnectionFailed', 'TlsProbeFailed'):
                return {'Status': 'Failed', 'ErrorCode': result['ErrorCode']}
        except subprocess.TimeoutExpired:
            # subprocess.run kills and reaps the owned child before returning.
            return {'Status': 'Failed', 'ErrorCode': 'TlsTimeout'}
        except (OSError, ValueError, TCError):
            pass
        return {'Status': 'Failed', 'ErrorCode': 'TlsProbeFailed'}

    def reality_keypair(self):
        binary = self.ensure_transport()
        raw = self.run([binary, 'generate', 'reality-keypair'])
        private = re.search(r'(?m)^PrivateKey:\s*([A-Za-z0-9_-]{43})\s*$', raw)
        public = re.search(r'(?m)^PublicKey:\s*([A-Za-z0-9_-]{43})\s*$', raw)
        require(private and public, 'TransportIdentityFailed', 'TCP identity generation returned an invalid result.')
        return {'PrivateKey': private.group(1), 'PublicKey': public.group(1), 'ShortId': os.urandom(8).hex(), 'Uuid': str(uuid.uuid4())}

    def install(self):
        self.run(["apt-get", "update"], timeout=900)
        self.run(["apt-get", "-y", "--no-install-recommends", "-o", "Dpkg::Options::=--force-confold",
                  "install", "wireguard-tools", "nftables", "openssl"], timeout=900)


def default_route(env):
    found = [r for r in env["Routes"] if r.get("dst") == "default"]
    require(len(found) == 1 and found[0].get("table", "main") in ("main", 254)
            and not found[0].get("nexthops"), "DefaultRoute", "Exactly one main IPv4 default route is required.")
    route = found[0]
    require(isinstance(route.get("dev"), str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,14}", route["dev"])
            and route["dev"] != "lo", "DefaultRoute", "Unsupported default interface.")
    return {k: route[k] for k in ("dst", "dev", "gateway", "table", "metric", "prefsrc") if k in route}


def environment_issues(env, plan=None, owned=False, recovery=False):
    issues = []
    def issue(code, message):
        issues.append({"Code": code, "Message": message})
    osinfo = env["OS"]
    if (osinfo["Id"], osinfo["Version"]) not in (("ubuntu", "24.04"), ("debian", "13")) or osinfo["Architecture"] not in ("x86_64", "amd64"):
        issue("UnsupportedOS", "Only Ubuntu 24.04 and Debian 13 amd64 are supported targets.")
    if env["Container"] or not env["Systemd"]:
        issue("UnsupportedHost", "A dedicated VM with systemd is required; containers are unsupported.")
    try:
        route = default_route(env)
        if plan and route != plan["DefaultRoute"]:
            issue("RouteDrift", "The default route changed since planning.")
    except TCError as exc:
        issue(exc.code, exc.message)
    rule_pairs = [(r.get("priority"), r.get("table")) for r in env["Rules"]]
    if rule_pairs not in ([(0, "local"), (32766, "main"), (32767, "default")], [(0, 255), (32766, 254), (32767, 253)]) or any(
            set(r) - {"priority", "table", "src", "protocol"} or r.get("src", "all") != "all" for r in env["Rules"]):
        issue("PolicyRouting", "Custom policy routing is unsupported.")
    names = env["Services"]
    active = env["ActiveServices"]
    if any(re.match(r"(?:docker|containerd|firewalld|netfilter-persistent|libvirtd|virtqemud)(?:\.|@)", s) for s in names):
        issue("ForeignNetworkManager", "Docker, virtualization or custom firewall services were found.")
    if env.get("UfwEnabled", "ufw.service" in active) or "nftables.service" in active + env.get("EnabledServices", []):
        issue("ForeignFirewallService", "An existing firewall service is active.")
    if env["LegacyRules"]:
        issue("ForeignFirewall", "Existing iptables rules or policies are unsupported.")
    if env["WireGuardFiles"] or any(re.match(r"wg-quick@[^.]+\.service$", s) for s in names):
        issue("ForeignWireGuard", "Existing WireGuard configuration or units were found.")
    interface = paths(plan)["Interface"] if plan else None
    table = paths(plan)["Table"] if plan else None
    for link in env["Links"]:
        kind = link.get("linkinfo", {}).get("info_kind", "")
        if (kind in ("wireguard", "bridge", "tun", "vxlan", "gre", "gretap", "veth")
                or (interface and link.get("ifname") == interface)) and not (owned and link.get("ifname") == interface and kind == "wireguard"):
            issue("ForeignInterface", "An existing tunnel, bridge or reserved interface conflicts.")
    if env["Nft"] is not None:
        for item in nft_normalized(env["Nft"]):
            obj = next(iter(item.values()))
            if not (owned and obj.get("family") == "inet" and (obj.get("table") == table or ("table" in item and obj.get("name") == table))):
                issue("ForeignFirewall", "Existing nftables resources are unsupported.")
                break
    if not owned and env["Forwarding"] != "0":
        issue("ExistingForwarding", "IPv4 forwarding is already enabled on an unmanaged server.")
    if env.get("IPv6Forwarding", "0") != "0":
        issue("ExistingIPv6Forwarding", "Existing IPv6 forwarding is unsupported on a dedicated IPv4 node.")
    if plan:
        network = subnet(plan["TunnelSubnet"])
        for row in env["Addresses"]:
            if owned and row.get("ifname") == interface:
                continue
            for addr in row.get("addr_info", []):
                if addr.get("family") == "inet" and ipaddress.IPv4Network(str(addr["local"]) + "/" + str(addr["prefixlen"]), strict=False).overlaps(network):
                    issue("SubnetConflict", "TunnelSubnet overlaps a host interface.")
        for route in env["Routes"]:
            dest = route.get("dst", "default")
            if dest == "default" or (owned and route.get("dev") == interface):
                continue
            if ipaddress.IPv4Network(dest, strict=False).overlaps(network):
                issue("SubnetConflict", "TunnelSubnet overlaps an existing route.")
        if not owned and endpoint(plan["PublicEndpoint"])[1] in env["UdpPorts"]:
            issue("PortConflict", "The requested UDP port is already in use.")
        if env["MachineBinding"] != plan["MachineBinding"]:
            issue("HostMismatch", "The plan belongs to another machine.")
    if not recovery and not all(env["Tools"].values()) and env["PolicyExists"]:
        issue("PackagePolicyConflict", "An existing package service policy prevents safe unattended installation.")
    # Keep diagnostics bounded and stable; never include raw system command output.
    return list({i["Code"]: i for i in issues}.values())


class Backend:
    def __init__(self, fs=None, system=None, now=None, progress=None, management_crypto=None):
        self.fs = fs or SecureFS()
        self.os = system or LinuxOS()
        self.now = now or (lambda: dt.datetime.now(dt.timezone.utc))
        self.progress = progress or (lambda message: print(message, file=sys.stderr, flush=True))
        self.management_crypto = management_crypto or management.OpenSSLCrypto()
        self.dumps, self.parse_json = dumps, parse_json
        self.validate_client_request, self.make_client_response = client_request, client_response
        self.service_paths = paths

    def manager(self):
        return management.Manager(self)

    def read_json(self, path):
        text = self.fs.read(path)
        return None if text is None else parse_json(text)

    def write_json(self, path, value):
        self.fs.cas(path, self.fs.read(path), dumps(value))

    def owner(self, env, create=False):
        if not self.fs.exists(ROOT):
            if not create:
                return None
            self.fs.mkdir(ROOT)
            self.fs.cas(OWNER, None, dumps({"SchemaVersion": 1, "Kind": "TradeChannel.LinuxOwner",
                                          "OwnerId": str(uuid.uuid4()), "MachineBinding": env["MachineBinding"]}))
            self.fs.cas(ROOT + "/lock", None, "")
            for directory in ("plans", "nodes", "transactions"):
                self.fs.mkdir(ROOT + "/" + directory)
        owner = self.read_json(OWNER)
        require(isinstance(owner, dict) and owner.get("SchemaVersion") == 1 and owner.get("Kind") == "TradeChannel.LinuxOwner",
                "OwnershipMismatch", "Existing state directory is not a complete TradeChannel installation.")
        guid(owner["OwnerId"])
        require(owner["MachineBinding"] == env["MachineBinding"], "HostMismatch", "State belongs to another machine.")
        require(self.fs.exists(ROOT + "/lock"), "OwnershipMismatch", "State lock is missing.")
        return owner

    def load_plan(self, plan_id, env):
        path = ROOT + "/plans/" + guid(plan_id) + ".json"
        plan = self.read_json(path)
        require(isinstance(plan, dict) and plan.get("PlanId") == plan_id and plan.get("SchemaVersion") == 1,
                "PlanNotFound", "The stored plan is missing or invalid.")
        plan_input({k: plan[k] for k in ("Name", "PublicEndpoint", "TunnelSubnet", "ClientRequest") + (("Transport",) if plan.get("Transport") else ())})
        guid(plan["NodeId"])
        owner = self.owner(env)
        require(owner is not None and plan.get("OwnerId") == owner["OwnerId"] and plan.get("MachineBinding") == env["MachineBinding"],
                "HostMismatch", "Plan ownership or machine identity does not match.")
        require(addresses(subnet(plan["TunnelSubnet"])) == (plan["ServerAddress"], plan["ClientAddress"]),
                "InvalidState", "Stored plan addresses do not match the subnet.")
        require(plan["DefaultInterface"] == plan["DefaultRoute"]["dev"] and
                re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,14}", plan["DefaultInterface"]), "InvalidState", "Invalid planned interface.")
        timestamp(plan["PlanExpiresAt"])
        return plan

    def manifest(self, env):
        manifest = self.read_json(MANIFEST)
        if manifest is None:
            return None, None
        plan = self.load_plan(manifest["PlanId"], env)
        require(manifest.get("NodeId") == plan["NodeId"] and manifest.get("Status") in ("Applied", "Uninstalled")
                and type(manifest.get("ConfigRevision")) is int and manifest["ConfigRevision"] >= 1,
                "InvalidState", "Stored node state is invalid.")
        return manifest, plan

    def assert_ready(self, env, plan=None, owned=False, recovery=False):
        issues = environment_issues(env, plan, owned, recovery)
        if issues:
            raise TCError("PreflightRejected", "Dedicated-server preflight failed.", Issues=issues)

    def no_transaction(self):
        require(self.fs.read(ACTIVE) is None, "NeedsRecovery", "A transaction is unfinished; run recover before making changes.")
        require(self.fs.read(management.PENDING) is None, "NeedsRecovery", "Management metadata has an unfinished transaction; run recover before making changes.")

    def inspect(self, value):
        fields(value, ())
        env = self.os.probe()
        owner = self.owner(env)
        manifest, plan = self.manifest(env) if owner else (None, None)
        owned = bool(manifest and manifest["Status"] == "Applied")
        issues = environment_issues(env, plan if owned else None, owned)
        if owner and (self.fs.read(ACTIVE) is not None or self.fs.read(management.PENDING) is not None):
            issues.append({"Code": "NeedsRecovery", "Message": "An unfinished transaction requires explicit recovery."})
        if owned and not issues and plan and manifest:
            try:
                self.verify(plan, manifest, env)
            except TCError as exc:
                issues.append({"Code": exc.code, "Message": exc.message})
        deployed_name = None
        if plan and plan.get("Name"):
            deployed_name = plan.get("Name")
        elif manifest and manifest.get("NodeName"):
            deployed_name = manifest.get("NodeName")

        return {"Supported": not issues, "OS": env["OS"], "Issues": issues,
                "Summary": "Dedicated server checks passed." if not issues else "Deployment or maintenance is blocked.",
                "Warnings": self.warnings(env), "WarningSummary": " ".join(self.warnings(env)), "RequiresCloudFirewall": True,
                "AlreadyDeployed": bool(owned and not issues),
                "OwnedDeployment": owned,
                "DeployedStatus": ("Applied" if owned else (manifest.get("Status") if manifest else None)),
                "ExistingNodeName": deployed_name, "ConflictNetworks": self.conflict_networks(env)}

    def conflict_networks(self, env):
        """Read-only IPv4 interface/routes for overlap-aware subnet selection."""
        result = set()
        for row in env.get("Addresses", []):
            for address in row.get("addr_info", []):
                if address.get("family") == "inet":
                    try: result.add(str(ipaddress.IPv4Network(str(address["local"]) + "/" + str(address["prefixlen"]), strict=False)))
                    except (ValueError, KeyError): pass
        for row in env.get("Routes", []):
            destination = row.get("dst", "default")
            if destination in ("default", "0.0.0.0/0"): continue
            try: result.add(str(ipaddress.IPv4Network(destination, strict=False)))
            except (ValueError, TypeError): pass
        return sorted(result)

    def warnings(self, env):
        result = ["Cloud firewall UDP permission, external connectivity and reboot recovery require separate validation.",
                  "Package installation is not rolled back; private audit and identity state is retained on uninstall."]
        if env["Nft"] is None:
            result.append("nftables inspection is deferred until tools are installed; apply repeats preflight before configuring networking.")
        return result

    def public_plan(self, plan):
        names = ("PlanId", "Supported", "OS", "Steps", "Name", "PublicEndpoint", "TunnelSubnet", "ServerAddress", "ClientAddress", "Warnings", "RequiresCloudFirewall", "PlanExpiresAt")
        return {k: copy.deepcopy(plan[k]) for k in names + (('Transport',) if plan.get('Transport') else ())}

    def plan(self, value):
        value = plan_input(value)
        env = self.os.probe()
        owner = self.owner(env)
        existing, oldplan = self.manifest(env) if owner else (None, None)
        if existing and existing["Status"] == "Applied":
            require(all(oldplan[k] == value[k] for k in value), "NodeExists", "A dedicated node already exists; use authorize for another device.")
            with self.fs.lock(readonly=True):
                self.no_transaction()
                self.verify(oldplan, existing, env)
                return self.public_plan(oldplan)
        route = default_route(env)
        server, client = addresses(subnet(value["TunnelSubnet"]))
        candidate = dict(value, SchemaVersion=1, PlanId=str(uuid.uuid4()), NodeId=str(uuid.uuid4()),
                         MachineBinding=env["MachineBinding"], DefaultInterface=route["dev"], DefaultRoute=route,
                         ServerAddress=server, ClientAddress=client)
        self.assert_ready(env, candidate)
        if candidate.get('Transport'):
            require(not self.os.transport_port_busy(candidate['Transport']['Port']), 'TransportPortBusy', 'The planned TCP port already has a listener.')
        owner = self.owner(env, create=True)
        with self.fs.lock():
            self.no_transaction()
            current, _ = self.manifest(env)
            require(current is None or current["Status"] == "Uninstalled", "NodeExists", "A node was installed concurrently.")
            self.prune_plans(env)
            files = self.fs.list(ROOT + "/plans")
            fingerprint = digest(dumps(value))
            for leaf in files:
                require(re.fullmatch(r"[0-9a-f-]{36}\.json", leaf), "OwnershipMismatch", "Unexpected file in plans directory.")
                old = self.load_plan(leaf[:-5], env)
                if old["InputFingerprint"] == fingerprint and timestamp(old["PlanExpiresAt"]) > self.now() and (not current or old["PlanId"] != current["PlanId"]):
                    return self.public_plan(old)
            require(len(files) < 128, "PlanLimit", "The retained plan limit has been reached.")
            candidate.update(OwnerId=owner["OwnerId"], InputFingerprint=fingerprint, Supported=True, OS=env["OS"],
                             PlanExpiresAt=utc(self.now() + dt.timedelta(hours=1)), RequiresCloudFirewall=True,
                             Warnings=self.warnings(env), Steps=["Recheck host and ownership", "Journal private backups",
                             "Install missing distribution tools", "Create server identity and initial authorization",
                             "Install owned firewall and WireGuard units", "Verify local configuration"])
            self.fs.cas(ROOT + "/plans/" + candidate["PlanId"] + ".json", None, dumps(candidate))
            return self.public_plan(candidate)

    def identity(self, plan, create=False):
        path = paths(plan)["Identity"]
        obj = self.read_json(path)
        if obj is None:
            require(create, "IdentityMissing", "Server identity is missing; refusing to generate a replacement.")
            private = key(self.os.run(["wg", "genkey"]))
            public = key(self.os.run(["wg", "pubkey"], input_text=private + "\n"))
            require(public != plan["ClientRequest"]["ClientPublicKey"], "InvalidKey", "Client and server identities must differ.")
            obj = {"NodeId": plan["NodeId"], "PrivateKey": private, "PublicKey": public}
            if plan.get('Transport'): obj['Transport'] = self.os.reality_keypair()
            self.fs.cas(path, None, dumps(obj))
        fields(obj, ("NodeId", "PrivateKey", "PublicKey"), ('Transport',))
        require(obj["NodeId"] == plan["NodeId"] and key(obj["PublicKey"]) ==
                self.os.run(["wg", "pubkey"], input_text=key(obj["PrivateKey"]) + "\n"),
                "IdentityDrift", "Stored server identity does not match its public key.")
        if plan.get('Transport'):
            require(isinstance(obj.get('Transport'), dict), 'IdentityMissing', 'TCP identity is missing; refusing to rotate it.')
            transport = obj['Transport']
            fields(transport, ('PrivateKey', 'PublicKey', 'ShortId', 'Uuid'))
            require(all(isinstance(transport[k], str) and re.fullmatch(r'[A-Za-z0-9_-]{43}', transport[k]) for k in ('PrivateKey', 'PublicKey')))
            guid(transport['Uuid'])
            require(re.fullmatch(r'[0-9a-f]{16}', transport['ShortId']))
            wg_private = base64.b64encode(base64.urlsafe_b64decode(transport['PrivateKey']+'=')).decode()
            derived = self.os.run(['wg', 'pubkey'], input_text=wg_private+'\n').strip()
            expected = base64.b64encode(base64.urlsafe_b64decode(transport['PublicKey']+'=')).decode()
            require(derived == expected, 'IdentityDrift', 'TCP private/public identity no longer matches.')
        return obj

    def expected_files(self, plan, manifest):
        if manifest is None or manifest["Status"] == "Uninstalled":
            return {p: None for p in resource_paths(plan)}
        identity = self.identity(plan)
        require(identity["PublicKey"] == manifest["ServerPublicKey"], "IdentityDrift", "Manifest identity changed.")
        peers = manifest["Peers"]
        require(isinstance(peers, list) and len(peers) <= MAX_PEERS, "InvalidState", "Invalid peer records.")
        devices, requests, keys, addrs = set(), set(), set(), set()
        for peer in peers:
            req = client_request(peer["Request"])
            require(all(peer[k] == req[k] for k in ("RequestId", "DeviceId", "ClientPublicKey")), "InvalidState", "Peer request mismatch.")
            addr = client_address(subnet(plan["TunnelSubnet"]), peer["ClientAddress"])
            require(peer["DeviceId"] not in devices and peer["RequestId"] not in requests and peer["ClientPublicKey"] not in keys
                    and peer["ClientPublicKey"] != identity["PublicKey"] and addr not in addrs, "InvalidState", "Duplicate peer identities or addresses.")
            devices.add(peer["DeviceId"])
            requests.add(peer["RequestId"])
            keys.add(peer["ClientPublicKey"])
            addrs.add(addr)
        if plan.get('Transport'):
            require(manifest.get('Transport') == {k: identity['Transport'][k] for k in ('PublicKey', 'ShortId', 'Uuid')}, 'IdentityDrift', 'Public TCP transport parameters changed.')
        files = resources(plan, identity["PrivateKey"], peers, identity.get("Transport"))
        require(manifest["ResourceHashes"] == {p: digest(t) for p, t in files.items()}, "ConfigDrift", "Manifest resource hashes do not match generated resources.")
        return files

    def check_units(self, plan, allow_missing=False):
        p = paths(plan)
        for label in ("Firewall", "Tunnel") + (("Transport",) if plan.get("Transport") else ()):
            info = self.os.service(p[label + "Unit"])
            if allow_missing and info.get("LoadState") == "not-found":
                continue
            require(info.get("FragmentPath") == p[label + "Service"] and not info.get("DropInPaths")
                    and info.get("LoadState") == "loaded", "ServiceDrift", "Service ownership or overrides changed.")

    def verify_runtime(self, plan, manifest, env, allow_absent=False):
        p = paths(plan)
        self.assert_ready(env, plan, owned=True, recovery=True)
        nft = nft_normalized(env["Nft"]) if env["Nft"] is not None else []
        expected = nft_normalized(firewall(plan))
        require((allow_absent and not nft) or nft == expected, "FirewallDrift", "Owned firewall rules are missing or changed.")
        found = [link for link in env["Links"] if link.get("ifname") == p["Interface"]]
        if allow_absent and not found:
            return
        require(len(found) == 1 and found[0].get("linkinfo", {}).get("info_kind") == "wireguard", "TunnelDrift", "Owned WireGuard interface is missing or changed.")
        live = self.os.live(p["Interface"])
        require(live == {"PublicKey": manifest["ServerPublicKey"], "Port": str(endpoint(plan["PublicEndpoint"])[1]),
                         "Peers": {x["ClientPublicKey"]: x["ClientAddress"] for x in manifest["Peers"]}, "FwMark": "off"},
                "TunnelDrift", "Live WireGuard identity, peers or settings differ from state.")
        if not allow_absent:
            ips = [a for row in env["Addresses"] if row.get("ifname") == p["Interface"] for a in row.get("addr_info", []) if a.get("family") == "inet"]
            require(len(ips) == 1 and str(ips[0]["local"]) + "/" + str(ips[0]["prefixlen"]) == plan["ServerAddress"]
                    and "UP" in found[0].get("flags", []) and found[0].get("mtu") == TUNNEL_MTU
                    and env["Forwarding"] == "1", "TunnelDrift", "Tunnel address, MTU, link state or forwarding differs.")

    def verify(self, plan, manifest, env=None):
        require(manifest["Status"] == "Applied", "NodeUninstalled", "This node has been uninstalled.")
        for path, text in self.expected_files(plan, manifest).items():
            require(self.fs.read(path) == text, "ConfigDrift", "An owned configuration file is missing or changed.")
        for path, target in link_paths(plan).items():
            require(self.fs.link(path) == target, "ServiceDrift", "An owned boot link is missing or changed.")
        self.check_units(plan)
        if plan.get('Transport'): self.os.verify_transport()
        for unit in tuple(paths(plan)[label+'Unit'] for label in (('Firewall','Tunnel','Transport') if plan.get('Transport') else ('Firewall','Tunnel'))):
            require(self.os.service(unit).get("ActiveState") == "active", "ServiceDrift", "An owned service is not running.")
        self.verify_runtime(plan, manifest, env or self.os.probe())

    def node(self, plan, manifest):
        return {"NodeId": plan["NodeId"], "Name": plan["Name"], "NodeName": plan["Name"], "Platform": "Linux",
                "PublicEndpoint": plan["PublicEndpoint"], "TunnelSubnet": plan["TunnelSubnet"],
                "ServerAddress": plan["ServerAddress"], "ServerPublicKey": manifest["ServerPublicKey"],
                "ConfigRevision": manifest["ConfigRevision"], "DeviceCount": len(manifest["Peers"])}

    def applied(self, plan, manifest, peer=None):
        result = {"Status": "Applied", "Node": self.node(plan, manifest), "Validation": dict(VALIDATION)}
        if peer:
            result["ClientResponse"] = client_response(plan, manifest, peer)
        return result

    def start_journal(self, action, plan, before, env):
        tx = {"SchemaVersion": 1, "TransactionId": str(uuid.uuid4()), "Action": action, "Phase": "Pending",
              "PlanId": plan["PlanId"], "Before": copy.deepcopy(before), "After": None,
              "Files": {}, "Links": {}, "OriginalForwarding": env["Forwarding"], "PackageGuard": False}
        self.fs.cas(ACTIVE, None, dumps(tx))
        return tx

    def stage(self, tx, plan, after, management_files=None):
        old = self.expected_files(plan, tx["Before"])
        new = self.expected_files(plan, after)
        for path, text in old.items():
            require(self.fs.read(path) == text, "OwnershipMismatch", "Deployment resource is already occupied or changed.")
        before_links = tx["Before"] is not None and tx["Before"]["Status"] == "Applied"
        after_links = after["Status"] == "Applied"
        tx["Files"] = {p: {"Before": old[p], "After": new[p]} for p in old}
        extra = management_files if management_files is not None else tx.get("ManagementFiles", {})
        tx["Files"].update(copy.deepcopy(extra))
        if management_files:
            tx["ManagementPaths"] = sorted(management_files)
        tx["Links"] = {p: {"Before": t if before_links else None, "After": t if after_links else None} for p, t in link_paths(plan).items()}
        for path, versions in tx["Links"].items():
            require(self.fs.link(path) == versions["Before"], "OwnershipMismatch", "A boot link is already occupied or changed.")
        tx["After"] = copy.deepcopy(after)
        require(len(dumps(tx).encode("utf-8")) <= MAX_STATE, "JournalCapacity", "The complete private transaction exceeds its bounded recovery budget; no resource change was made.")
        self.write_json(ACTIVE, tx)

    def write_staged(self, tx):
        for path, versions in tx["Files"].items():
            self.fs.cas(path, versions["Before"], versions["After"])
        for path, versions in tx["Links"].items():
            self.fs.cas_link(path, versions["Before"], versions["After"])

    def archive(self, tx):
        path = ROOT + "/transactions/" + guid(tx["TransactionId"]) + ".json"
        existing = self.fs.read(path)
        require(existing in (None, dumps(tx)), "OwnershipMismatch", "Transaction archive changed.")
        self.fs.cas(path, existing, dumps(tx))
        self.fs.cas(ACTIVE, dumps(tx), None)

    def commit(self, tx):
        self.fs.cas(MANIFEST, dumps(tx["Before"]) if tx["Before"] is not None else None, dumps(tx["After"]))
        tx["Phase"] = "Committed"
        self.write_json(ACTIVE, tx)
        self.archive(tx)

    def package_install(self, tx):
        require(self.fs.read(POLICY) is None, "PackagePolicyConflict", "An existing package service policy cannot be overwritten.")
        tx["PackageGuard"] = True
        self.write_json(ACTIVE, tx)
        # This non-secret executable hook is 0700; all data/backups remain 0600.
        self.fs.cas(POLICY, None, POLICY_TEXT, mode=0o700)
        self.progress("Installing required distribution packages.")
        self.os.install()
        self.fs.cas(POLICY, POLICY_TEXT, None)
        tx["PackageGuard"] = False
        self.write_json(ACTIVE, tx)

    def new_peer(self, request, address):
        return {"RequestId": request["RequestId"], "DeviceId": request["DeviceId"],
                "ClientPublicKey": request["ClientPublicKey"], "ClientAddress": address, "Request": copy.deepcopy(request)}

    def apply(self, value):
        fields(value, ("PlanId",))
        guid(value["PlanId"])
        env = self.os.probe()
        require(self.owner(env), "PlanNotFound", "No stored deployment plan exists.")
        with self.fs.lock():
            self.no_transaction()
            plan = self.load_plan(value["PlanId"], env)
            before, oldplan = self.manifest(env)
            if before and before["Status"] == "Applied":
                require(before["PlanId"] == plan["PlanId"], "NodeExists", "Another node is already installed.")
                self.verify(oldplan, before, env)
                initial = next((p for p in before["Peers"] if p["RequestId"] == plan["ClientRequest"]["RequestId"]), None)
                require(initial is not None, "InitialClientRevoked", "The initial device was revoked; apply will not reauthorize it.")
                return self.applied(plan, before, initial)
            require(before is None or before["PlanId"] != plan["PlanId"], "NodeUninstalled", "This node was uninstalled; create a new plan to install a new node.")
            require(timestamp(plan["PlanExpiresAt"]) > self.now(), "PlanExpired", "The deployment plan has expired; create a fresh plan.")
            self.assert_ready(env, plan)
            p = paths(plan)
            for path in resource_paths(plan):
                require(self.fs.read(path) is None, "OwnershipMismatch", "A planned resource is already occupied.")
            for path in link_paths(plan):
                require(self.fs.link(path) is None, "OwnershipMismatch", "A planned boot link is already occupied.")
            for unit in tuple(p[label+'Unit'] for label in (('Firewall','Tunnel','Transport') if plan.get('Transport') else ('Firewall','Tunnel'))):
                require(self.os.service(unit).get("LoadState") == "not-found", "OwnershipMismatch", "A planned unit name is already registered.")
            self.fs.mkdir(p["Directory"])
            tx = self.start_journal("apply", plan, before, env)
            try:
                if not all(env["Tools"].values()):
                    self.package_install(tx)
                # Packages can change the host: re-probe before any networking mutations.
                fresh = self.os.probe()
                self.assert_ready(fresh, plan)
                require(all(fresh["Tools"].values()) and fresh["Nft"] is not None,
                        "MissingTools", "Required tools are still unavailable after installation.")
                if plan.get('Transport'):
                    require(not self.os.transport_port_busy(plan['Transport']['Port']), 'TransportPortBusy', 'TCP port became occupied after planning.')
                    self.os.ensure_transport()
                identity = self.identity(plan, create=True)
                peer = self.new_peer(plan["ClientRequest"], plan["ClientAddress"])
                after = {"SchemaVersion": 1, "PlanId": plan["PlanId"], "NodeId": plan["NodeId"], "Status": "Applied",
                         "ServerPublicKey": identity["PublicKey"], "ConfigRevision": 1, "Peers": [peer], "Revoked": [],
                         "OriginalForwarding": env["Forwarding"], "ResourceHashes": {}}
                if plan.get('Transport'):
                    after['Transport'] = {k: identity['Transport'][k] for k in ('PublicKey', 'ShortId', 'Uuid')}
                after["ResourceHashes"] = {path: digest(text) for path, text in resources(plan, identity["PrivateKey"], after["Peers"], identity.get("Transport")).items()}
                self.stage(tx, plan, after)
                self.write_staged(tx)
                self.os.run(["nft", "-c", "-j", "-f", p["Firewall"]])
                if plan.get('Transport'): self.os.run([tcp_support.BINARY, 'check', '-c', p['TransportConfig']])
                self.os.run(["systemctl", "daemon-reload"])
                self.progress("Starting owned firewall and WireGuard services.")
                self.os.run(["systemctl", "start", p["FirewallUnit"]])
                self.os.run(["systemctl", "start", p["TunnelUnit"]])
                if plan.get('Transport'): self.os.run(['systemctl', 'start', p['TransportUnit']])
                self.verify(plan, after)
                self.commit(tx)
                return self.applied(plan, after, peer)
            except Exception as exc:
                self.failed(tx, plan, exc)

    def status(self, value):
        fields(value, (), ("NetworkProbe", "ProbeRepeats", "CaptureSeconds", "ProbeRelayPort", "ProbeSourceIPv4"))
        network_probe = value.get("NetworkProbe", False)
        repeats = value.get("ProbeRepeats", 1)
        capture_seconds = value.get("CaptureSeconds", 0)
        relay_port = value.get("ProbeRelayPort", 0)
        require(type(network_probe) is bool and type(repeats) is int and 1 <= repeats <= 3
                and type(capture_seconds) is int and 0 <= capture_seconds <= 60
                and type(relay_port) is int and relay_port in (0, 443)
                and (network_probe or not {"ProbeRepeats", "CaptureSeconds", "ProbeRelayPort", "ProbeSourceIPv4"}.intersection(value)))
        if relay_port:
            require(capture_seconds > 0 and "ProbeSourceIPv4" in value)
            probe_source_ipv4(value["ProbeSourceIPv4"])
        else:
            require("ProbeSourceIPv4" not in value)
        env = self.os.probe()
        if not self.owner(env):
            require(not network_probe, "NotInstalled", "Network diagnostics require a verified applied node.")
            return {"Status": "NotInstalled", "OS": env["OS"], "Validation": {"LocalConfiguration": "NotConfigured", "ExternalConnectivity": "NotTested", "Reboot": "NotTested"}}
        with self.fs.lock(readonly=True):
            management_tx = self.read_json(management.PENDING)
            if management_tx is not None:
                require(not network_probe, "NeedsRecovery", "Resolve the pending management transaction before network diagnostics.")
                return {"Status": "NeedsRecovery", "TransactionId": guid(management_tx["TransactionId"]),
                        "ManagementTransaction": {"Action": management_tx.get("Action"), "Phase": management_tx.get("Phase"),
                                                  "RecoveryKind": "SidecarMetadata"},
                        "Validation": {"LocalConfiguration": "NotVerified", "ExternalConnectivity": "NotTested", "Reboot": "NotTested"}}
            tx = self.read_json(ACTIVE)
            if tx is not None:
                require(not network_probe, "NeedsRecovery", "Network diagnostics require the pending transaction to be resolved.")
                plan = self.load_plan(tx["PlanId"], env)
                return {"Status": "NeedsRecovery", "TransactionId": guid(tx["TransactionId"]),
                        "Diagnostics": self.pending_diagnostics(tx, plan, env),
                        "Validation": {"LocalConfiguration": "NotVerified", "ExternalConnectivity": "NotTested", "Reboot": "NotTested"}}
            manifest, plan = self.manifest(env)
            if manifest is None:
                require(not network_probe, "NotInstalled", "Network diagnostics require a verified applied node.")
                return {"Status": "NotInstalled", "OS": env["OS"]}
            if manifest["Status"] == "Uninstalled":
                require(not network_probe, "NotInstalled", "Network diagnostics require a verified applied node.")
                return {"Status": "Uninstalled", "RetainedPrivateState": True, "PackagesRetained": True}
            self.verify(plan, manifest, env)
            result = self.applied(plan, manifest)
            if network_probe:
                # Preserve the OS adapter's existing four-argument call when off.
                options = {"capture_seconds": capture_seconds} if capture_seconds else {}
                if relay_port:
                    options.update(probe_relay_port=relay_port, probe_source_ipv4=value["ProbeSourceIPv4"])
                result["NetworkProbe"] = self.os.network_probe(plan, manifest, repeats, self.progress, **options)
                result["NetworkProbe"]["Forwarding"] = env["Forwarding"]
                if capture_seconds and not result["NetworkProbe"].get("Ok", False):
                    raise TCError("NetworkProbeFailed", "Network diagnostics did not complete successfully.", **result)
            return result

    def deployment_state(self, value):
        """Read the journal and actual UDP resources, even when TCP is pending.

        This is evidence, never recovery or permission to replay a mutation.
        Keep TCP health separate so a broken TCP unit cannot hide UDP evidence.
        """
        fields(value, ("ClientPublicKey", "ServerPublicKey"))
        client_key, server_key = key(value["ClientPublicKey"]), key(value["ServerPublicKey"])
        env = self.os.probe()
        owner = self.owner(env)
        require(owner, "NotInstalled", "No owned installation exists.")
        with self.fs.lock(readonly=True):
            manifest, plan = self.manifest(env)
            require(manifest and manifest["ServerPublicKey"] == server_key,
                    "ServerBindingMismatch", "The request targets another server.")
            tx = self.read_json(ACTIVE) or self.read_json(management.PENDING)
            result = {"Kind": "TradeChannel.DeploymentState", "NodeId": manifest["NodeId"],
                      "RemoteOwnerId": owner["OwnerId"], "ServerPublicKey": server_key,
                      "ClientPublicKey": client_key, "Status": "NeedsRecovery" if tx else "Settled",
                      "Transaction": {k: tx.get(k) for k in ("TransactionId", "Action", "Phase")} if tx else None,
                      "Udp": {"Status": "NotVerified"}, "TcpConfigured": bool(plan.get("Transport"))}
            p = paths(plan)
            result["Services"] = {label: {k: self.os.service(p[label+"Unit"]).get(k)
                                         for k in ("LoadState", "ActiveState", "FragmentPath")}
                                  for label in ("Firewall", "Tunnel") + (("Transport",) if plan.get("Transport") else ())}
            try:
                peer = next((x for x in manifest["Peers"] if x["ClientPublicKey"] == client_key), None)
                require(peer, "DeviceNotAuthorized", "The existing device is not authorized.")
                udp_plan = copy.deepcopy(plan); udp_plan.pop("Transport", None)
                udp_manifest = copy.deepcopy(manifest); udp_manifest.pop("Transport", None)
                udp_paths = resource_paths(udp_plan)
                udp_manifest["ResourceHashes"] = {k: v for k, v in manifest["ResourceHashes"].items() if k in udp_paths}
                self.verify(udp_plan, udp_manifest, env)
                result["Udp"] = {"Status": "Healthy", "ClientAddress": peer["ClientAddress"],
                                 "ClientResponse": client_response(udp_plan, udp_manifest, peer)}
            except TCError as exc:
                result["Udp"] = {"Status": "Failed", "ErrorCode": exc.code}
            return result

    def transport_candidates(self, value):
        """Inspect supported TCP candidates without changing any listener."""
        fields(value, ("ServerPublicKey", "ServerName"), ("CandidatePorts",))
        server_key = key(value["ServerPublicKey"])
        ports = value.get("CandidatePorts", [443, 8443, 2443])
        require(isinstance(ports, list) and ports and len(ports) <= 3
                and all(type(p) is int and p in (443, 8443, 2443) for p in ports)
                and len(ports) == len(set(ports)))
        env = self.os.probe()
        with self.fs.lock(readonly=True):
            self.no_transaction()
            manifest, plan = self.manifest(env)
            require(manifest and manifest["ServerPublicKey"] == server_key, "ServerBindingMismatch", "Server identity changed.")
            self.verify(plan, manifest, env)
            if plan.get("Transport"):
                return {"Status": "Available", "Transport": copy.deepcopy(plan["Transport"]), "Candidates": [], "PreservedExisting": True}
            plan_input({k: plan[k] for k in ("Name", "PublicEndpoint", "TunnelSubnet", "ClientRequest")}
                       | {"Transport": {"Type": "tcp-reality", "Port": ports[0], "ServerName": value["ServerName"]}})
            rows = [{"Port": p, "Protocol": "tcp", "Busy": self.os.transport_port_busy(p)} for p in ports]
            selected = next((x["Port"] for x in rows if not x["Busy"]), None)
            return {"Status": "Selected" if selected else "Unavailable", "Port": selected, "Candidates": rows,
                    "ServerName": value["ServerName"], "HandshakeValidation": "NotTested", "RequiresCloudFirewall": True}

    def transport_options(self, value):
        """Healthy UDP-only node: approved ports plus bounded outbound TLS choices."""
        fields(value, ("ServerPublicKey", "ServerName"), ("CandidatePorts", "CandidateServerNames"))
        name = value["ServerName"]
        defaults = list(TRANSPORT_SERVER_NAMES) if name == TRANSPORT_SERVER_NAMES[0] else [name]
        choices = value.get("CandidateServerNames", defaults)
        require(isinstance(choices, list) and choices and len(choices) <= 2
                and choices[0] == name and (choices == defaults or choices == [name]),
                "InvalidTransportChoices", "Only the requested target and controlled default fallback are supported.")
        result = self.transport_candidates({k: v for k, v in value.items() if k != "CandidateServerNames"})
        result.update(SelectedServerName=None, HandshakeValidation="NotTested", HandshakeChecks=[],
                      ServerNameChoices=choices, HandshakeBudgetSeconds=TRANSPORT_TLS_TOTAL_SECONDS,
                      ValidationLayer="TlsEndpointReachable")
        if result["Status"] == "Available":
            result["SelectedServerName"] = result["Transport"]["ServerName"]
            return result  # Preserve the existing service; do not probe/rotate its target.
        if result["Status"] != "Selected":
            result["Code"] = "TransportPortsUnavailable"
            return result
        deadline = time.monotonic() + TRANSPORT_TLS_TOTAL_SECONDS
        for target in choices:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                result["HandshakeChecks"].append({"ServerName": target, "Port": 443,
                                                  "Status": "Failed", "ErrorCode": "TlsBudgetExhausted"})
                break
            check = self.os.tls_endpoint_probe(target, min(TRANSPORT_TLS_ATTEMPT_SECONDS, remaining))
            result["HandshakeChecks"].append(dict(check, ServerName=target, Port=443))
            if check == {"Status": "TlsEndpointReachable", "ErrorCode": None}:
                result.update(SelectedServerName=target, ServerName=target, HandshakeValidation="TlsEndpointReachable")
                return result
        result.update(Status="Unavailable", Code="TransportHandshakeUnavailable", HandshakeValidation="Failed")
        return result

    def transport_info(self, value):
        """Read a healthy node's TCP parameters for an existing public identity."""
        fields(value, ("ClientPublicKey", "ServerPublicKey"))
        client_key, server_key = key(value["ClientPublicKey"]), key(value["ServerPublicKey"])
        env = self.os.probe()
        require(self.owner(env) is not None, "NotInstalled", "No owned server installation exists.")
        with self.fs.lock(readonly=True):
            self.no_transaction()
            manager = self.manager()
            owner, manifest, plan = manager.locked_context(env)
            require(manifest["ServerPublicKey"] == server_key, "ServerBindingMismatch", "The request targets another WireGuard server identity.")
            state = manager.load(owner, manifest)
            peer = next((p for p in manifest["Peers"] if p["ClientPublicKey"] == client_key), None)
            if peer is None:
                require(not any(p["ClientPublicKey"] == client_key for p in manifest["Revoked"]),
                        "DeviceRevoked", "The requested client identity has been revoked.")
                raise TCError("DeviceNotFound", "The requested client identity is not registered.")
            meta = state["Devices"].get(peer["DeviceId"])
            require(isinstance(meta, dict), "InvalidManagementState", "The device is absent from the management v2 catalog.")
            # As in management.devices, State and ClientPublicKey come from
            # Peers/Revoked; legacy v2 sidecars contain metadata only. Reject
            # any conflicting explicit identity/state or retirement evidence.
            require(meta.get("ClientPublicKey", peer["ClientPublicKey"]) == client_key,
                    "DeviceIdentityMismatch", "Management device public identity does not match.")
            require(meta.get("State", "Authorized") == "Authorized" and not meta.get("RevokedAtUtc"),
                    "DeviceNotAuthorized", "Management device state is not authorized.")
            self.verify(plan, manifest, env)
            if not plan.get("Transport"):
                require("Transport" not in manifest and "Transport" not in self.read_json(paths(plan)["Identity"]),
                        "IdentityDrift", "TCP identity exists without an applied transport configuration.")
                p = paths(dict(plan, Transport=True))
                require(all(not self.fs.metadata(p[label])["Exists"] for label in ("TransportConfig", "TransportService", "TransportLink")),
                        "ConfigDrift", "TCP resources exist without an applied transport configuration.")
                service = self.os.service(p["TransportUnit"])
                require(service.get("LoadState") == "not-found" and service.get("ActiveState") == "inactive",
                        "ServiceDrift", "TCP service exists without an applied transport configuration.")
            result = tcp_support.transport_info(plan, manifest, peer, owner)
            # verify() checked the live owned tunnel's MTU before this projection.
            # Existing clients can refresh it without issuing another device identity.
            result["MTU"] = TUNNEL_MTU
            return result

    def transport_plan(self, value):
        """Plan adding TCP to an owned UDP node without recreating its peers."""
        fields(value, ("Transport",))
        env = self.os.probe()
        owner = self.owner(env)
        require(owner, "NotInstalled", "No owned server installation exists.")
        with self.fs.lock():
            self.no_transaction()
            manifest, old = self.manifest(env)
            require(manifest and manifest["Status"] == "Applied", "NotInstalled", "No applied server exists.")
            self.verify(old, manifest, env)
            require(not old.get("Transport"), "TransportAlreadyEnabled", "TCP is already configured; replacement parameters require a separate maintenance operation.")
            candidate = copy.deepcopy(old)
            candidate["Transport"] = copy.deepcopy(value["Transport"])
            checked = plan_input({k: candidate[k] for k in ("Name", "PublicEndpoint", "TunnelSubnet", "ClientRequest", "Transport")})
            require(not self.os.transport_port_busy(checked["Transport"]["Port"]), "TransportPortBusy", "The planned TCP port has another listener.")
            candidate.update(PlanId=str(uuid.uuid4()), InputFingerprint=digest(dumps(checked)),
                             PlanExpiresAt=utc(self.now() + dt.timedelta(hours=1)))
            approval = {"Action": "transport_add", "RemoteOwnerId": owner["OwnerId"], "NodeId": old["NodeId"],
                        "PlanId": candidate["PlanId"], "BasePlanId": old["PlanId"], "BaseConfigRevision": manifest["ConfigRevision"],
                        "Transport": checked["Transport"], "PublicEndpoint": old["PublicEndpoint"],
                        "ServerPublicKey": manifest["ServerPublicKey"], "AffectedDeviceIds": [p["DeviceId"] for p in manifest["Peers"]],
                        "PlanExpiresAt": candidate["PlanExpiresAt"]}
            approval["ChangeDigest"] = digest(dumps(approval))
            candidate["TransportMaintenance"] = approval
            self.prune_plans(env)
            require(len(self.fs.list(ROOT + "/plans")) < 128, "PlanLimit", "Retained plans require maintenance before another can be created.")
            self.fs.cas(ROOT + "/plans/" + candidate["PlanId"] + ".json", None, dumps(candidate))
            return dict(approval, RequiresCloudFirewall=True, MaintenancePreview=True, WireGuardRestartRequired=False,
                        FirewallChanges="None: existing owned input policy accepts management/TCP traffic; cloud ingress still needs verification.",
                        Changes=["Install pinned TCP component if absent", "Create new Reality transport identity", "Add TCP relay service and boot link",
                                 "Keep existing WireGuard server identity, devices, UDP endpoint, firewall and tunnel services"],
                        Warnings=["Physical VPS and reboot acceptance remain unverified.", "Cloud TCP ingress must permit the chosen port.",
                                  "TCP uses a shared outer UUID; per-device WireGuard authorization remains separate."])

    def prune_plans(self, env):
        """Remove expired proposals only; protect every installation/journal reference."""
        protected = set()
        manifest = self.read_json(MANIFEST)
        if manifest: protected.add(manifest["PlanId"])
        active = self.read_json(ACTIVE)
        if active:
            protected.update(x for x in (active.get("PlanId"), active.get("BeforePlanId"), active.get("AfterPlanId")) if x)
            for side in (active.get("Before"), active.get("After")):
                if side: protected.add(side["PlanId"])
        # Archives remain useful recovery/audit evidence; do not orphan their
        # referenced proposals merely to bypass the plan count protection.
        for leaf in self.fs.list(ROOT + "/transactions"):
            require(re.fullmatch(r"[0-9a-f-]{36}\.json", leaf), "OwnershipMismatch", "Unexpected transaction archive.")
            tx = self.read_json(ROOT + "/transactions/" + leaf)
            protected.update(x for x in (tx.get("PlanId"), tx.get("BeforePlanId"), tx.get("AfterPlanId")) if x)
            for side in (tx.get("Before"), tx.get("After")):
                if isinstance(side, dict) and side.get("PlanId"): protected.add(side["PlanId"])
        for leaf in self.fs.list(ROOT + "/plans"):
            require(re.fullmatch(r"[0-9a-f-]{36}\.json", leaf), "OwnershipMismatch", "Unexpected plan file.")
            old = self.load_plan(leaf[:-5], env)
            if old["PlanId"] not in protected and timestamp(old["PlanExpiresAt"]) <= self.now():
                self.fs.cas(ROOT + "/plans/" + leaf, dumps(old), None)

    def transport_apply(self, value):
        fields(value, ("PlanId", "ApprovedChangeDigest"))
        guid(value["PlanId"])
        require(isinstance(value["ApprovedChangeDigest"], str) and re.fullmatch(r"[0-9a-f]{64}", value["ApprovedChangeDigest"]))
        env = self.os.probe()
        owner = self.owner(env)
        require(owner, "NotInstalled", "No owned server installation exists.")
        with self.fs.lock():
            self.no_transaction()
            newplan = self.load_plan(value["PlanId"], env)
            approval = newplan.get("TransportMaintenance")
            require(isinstance(approval, dict) and approval.get("Action") == "transport_add"
                    and approval.get("PlanId") == newplan["PlanId"] and approval.get("RemoteOwnerId") == owner["OwnerId"], "InvalidMaintenancePlan", "This is not an incremental TCP plan.")
            approved = {k: v for k, v in approval.items() if k != "ChangeDigest"}
            require(digest(dumps(approved)) == approval.get("ChangeDigest") == value["ApprovedChangeDigest"], "ApprovalMismatch", "The approval does not match this exact TCP maintenance plan.")
            before, oldplan = self.manifest(env)
            require(before and before["Status"] == "Applied", "NotInstalled", "The server is not applied.")
            if before["PlanId"] == newplan["PlanId"]:
                self.verify(newplan, before, env)
                return dict(self.applied(newplan, before), Status="TransportEnabled", MaintenancePreview=True)
            require(before["PlanId"] == approval["BasePlanId"] and before["ConfigRevision"] == approval["BaseConfigRevision"],
                    "RevisionConflict", "The node changed after preparing the TCP maintenance plan.")
            require(timestamp(newplan["PlanExpiresAt"]) > self.now(), "PlanExpired", "TCP maintenance plan expired; refresh its preview.")
            require(not oldplan.get("Transport"), "TransportAlreadyEnabled", "TCP is already configured.")
            self.verify(oldplan, before, env)
            require(not self.os.transport_port_busy(newplan["Transport"]["Port"]), "TransportPortBusy", "TCP port became occupied after planning.")
            oldidentity = self.identity(oldplan)
            # Reality uses X25519. Existing wg tools can generate its keypair
            # without installing/downloading a TCP binary before the journal.
            reality_private = key(self.os.run(["wg", "genkey"]))
            reality_public = key(self.os.run(["wg", "pubkey"], input_text=reality_private + "\n"))
            url_key = lambda value: base64.urlsafe_b64encode(base64.b64decode(value)).decode("ascii").rstrip("=")
            reality = {"PrivateKey": url_key(reality_private), "PublicKey": url_key(reality_public),
                       "ShortId": os.urandom(8).hex(), "Uuid": str(uuid.uuid4())}
            newidentity = dict(copy.deepcopy(oldidentity), Transport=reality)
            after = dict(copy.deepcopy(before), PlanId=newplan["PlanId"], ConfigRevision=before["ConfigRevision"] + 1,
                         Transport={k: newidentity["Transport"][k] for k in ("PublicKey", "ShortId", "Uuid")})
            oldfiles = resources(oldplan, oldidentity["PrivateKey"], before["Peers"])
            newfiles = resources(newplan, newidentity["PrivateKey"], after["Peers"], newidentity["Transport"])
            after["ResourceHashes"] = {p: digest(t) for p, t in newfiles.items()}
            p = paths(newplan)
            for path in set(newfiles) - set(oldfiles): require(self.fs.read(path) is None, "OwnershipMismatch", "New TCP resource path is occupied.")
            require(self.fs.link(p["TransportLink"]) is None and self.os.service(p["TransportUnit"]).get("LoadState") == "not-found",
                    "OwnershipMismatch", "The new TCP boot link or unit already exists.")
            file_versions = {path: {"Before": oldfiles.get(path), "After": newfiles.get(path)} for path in set(oldfiles) | set(newfiles)}
            file_versions[p["Identity"]] = {"Before": dumps(oldidentity), "After": dumps(newidentity)}
            oldlinks, newlinks = link_paths(oldplan), link_paths(newplan)
            tx = {"SchemaVersion": 2, "Kind": "TradeChannel.TransportTransaction", "TransactionId": str(uuid.uuid4()),
                  "Action": "transport_add", "Phase": "Pending", "PlanId": newplan["PlanId"],
                  "BeforePlanId": oldplan["PlanId"], "AfterPlanId": newplan["PlanId"], "Before": before, "After": after,
                  "Files": file_versions, "Links": {path: {"Before": oldlinks.get(path), "After": newlinks.get(path)} for path in set(oldlinks) | set(newlinks)},
                  "OriginalForwarding": env["Forwarding"], "PackageGuard": False}
            require(len(dumps(tx).encode("utf-8")) <= MAX_STATE, "JournalCapacity", "TCP maintenance exceeds the bounded recovery budget; no server resources were changed.")
            self.fs.cas(ACTIVE, None, dumps(tx))
            try:
                self.os.ensure_transport()
                require(not self.os.transport_port_busy(newplan["Transport"]["Port"]),
                        "TransportPortBusy", "TCP port became occupied while preparing the component.")
                self.write_staged(tx)
                self.os.run([tcp_support.BINARY, "check", "-c", p["TransportConfig"]])
                self.os.run(["systemctl", "daemon-reload"])
                self.progress("Adding TCP relay; existing WireGuard and firewall services remain running.")
                self.os.run(["systemctl", "start", p["TransportUnit"]])
                self.verify(newplan, after)
                self.commit(tx)
                return dict(self.applied(newplan, after), Status="TransportEnabled", MaintenancePreview=True, WireGuardRestarted=False)
            except Exception as exc:
                persisted = self.read_json(ACTIVE)
                if persisted and persisted.get("Phase") == "Committed":
                    raise TCError("NeedsRecovery", "TCP addition committed but journal cleanup requires recovery.", TransactionId=tx["TransactionId"]) from None
                try:
                    self.rollback_transport(tx, env)
                except Exception as recovery_error:
                    tx.update(Phase="NeedsRecovery", FailureCode=getattr(exc, "code", "OperationFailed"), RecoveryCode=getattr(recovery_error, "code", "RecoveryFailed"))
                    self.write_json(ACTIVE, tx)
                    raise TCError("NeedsRecovery", "TCP addition failed and its restoration requires explicit recovery.", TransactionId=tx["TransactionId"]) from None
                raise TCError("RolledBack", "TCP addition failed; original UDP resources and device identities remain. Installed binary is retained.",
                              FailureCode=getattr(exc, "code", "OperationFailed"), TransactionId=tx["TransactionId"]) from None

    def validate_transport_journal(self, tx, env):
        require(tx.get("SchemaVersion") == 2 and tx.get("Kind") == "TradeChannel.TransportTransaction" and tx.get("Action") == "transport_add"
                and tx.get("Phase") in ("Pending", "NeedsRecovery", "Committed", "RolledBack"), "InvalidJournal", "Invalid incremental TCP journal.")
        guid(tx["TransactionId"])
        oldplan, newplan = self.load_plan(tx["BeforePlanId"], env), self.load_plan(tx["AfterPlanId"], env)
        require(not oldplan.get("Transport") and newplan.get("Transport") and tx["PlanId"] == newplan["PlanId"]
                and all(oldplan[k] == newplan[k] for k in ("NodeId", "OwnerId", "MachineBinding", "PublicEndpoint", "TunnelSubnet", "DefaultRoute", "DefaultInterface", "ServerAddress", "ClientAddress", "ClientRequest")),
                "InvalidJournal", "TCP maintenance changed the base tunnel identity or network.")
        before, after = tx["Before"], tx["After"]
        require(before["PlanId"] == oldplan["PlanId"] and after["PlanId"] == newplan["PlanId"] and after["ConfigRevision"] == before["ConfigRevision"] + 1
                and all(before[k] == after[k] for k in ("NodeId", "Status", "ServerPublicKey", "Peers", "Revoked", "OriginalForwarding")), "InvalidJournal", "TCP maintenance changed device authorization.")
        p = paths(newplan)
        identity_versions = tx["Files"].get(p["Identity"])
        require(isinstance(identity_versions, dict), "InvalidJournal")
        oldidentity, newidentity = parse_json(identity_versions["Before"]), parse_json(identity_versions["After"])
        require("Transport" not in oldidentity and {k: v for k, v in newidentity.items() if k != "Transport"} == oldidentity
                and oldidentity["PublicKey"] == before["ServerPublicKey"] and oldidentity["NodeId"] == oldplan["NodeId"], "InvalidJournal", "TCP maintenance rotated WireGuard identity.")
        require(key(oldidentity["PublicKey"]) == self.os.run(["wg", "pubkey"], input_text=key(oldidentity["PrivateKey"]) + "\n"), "IdentityDrift", "Journal WireGuard identity is invalid.")
        transport = newidentity["Transport"]
        fields(transport, ("PrivateKey", "PublicKey", "ShortId", "Uuid"))
        guid(transport["Uuid"])
        require(all(isinstance(transport[k], str) and re.fullmatch(r"[A-Za-z0-9_-]{43}", transport[k]) for k in ("PrivateKey", "PublicKey"))
                and re.fullmatch(r"[0-9a-f]{16}", transport["ShortId"]), "InvalidJournal")
        require(after["Transport"] == {k: transport[k] for k in ("PublicKey", "ShortId", "Uuid")}, "InvalidJournal")
        oldfiles = resources(oldplan, oldidentity["PrivateKey"], before["Peers"])
        newfiles = resources(newplan, newidentity["PrivateKey"], after["Peers"], transport)
        require(before["ResourceHashes"] == {p: digest(v) for p, v in oldfiles.items()} and after["ResourceHashes"] == {p: digest(v) for p, v in newfiles.items()}, "InvalidJournal")
        expected = {path: {"Before": oldfiles.get(path), "After": newfiles.get(path)} for path in set(oldfiles) | set(newfiles)}
        expected[p["Identity"]] = identity_versions
        oldlinks, newlinks = link_paths(oldplan), link_paths(newplan)
        links = {path: {"Before": oldlinks.get(path), "After": newlinks.get(path)} for path in set(oldlinks) | set(newlinks)}
        require(tx["Files"] == expected and tx["Links"] == links and self.read_json(MANIFEST) in (before, after), "InvalidJournal", "TCP journal paths or resource backups changed.")
        for path, versions in expected.items(): require(self.fs.read(path) in (versions["Before"], versions["After"]), "OwnershipMismatch", "TCP maintenance file was changed externally.")
        for path, versions in links.items(): require(self.fs.link(path) in (versions["Before"], versions["After"]), "OwnershipMismatch", "TCP maintenance boot link was changed externally.")
        return oldplan, newplan

    def rollback_transport(self, tx, env):
        oldplan, newplan = self.validate_transport_journal(tx, env)
        # Only the added service is stopped. The exact old tunnel/firewall is
        # checked before restoring sidecar/files, preserving all existing peers.
        self.verify_runtime(oldplan, tx["Before"], self.os.probe())
        p = paths(newplan)
        info = self.os.service(p["TransportUnit"])
        if info.get("LoadState") != "not-found":
            require(info.get("FragmentPath") == p["TransportService"] and not info.get("DropInPaths"), "ServiceDrift", "The TCP service ownership changed.")
            self.os.run(["systemctl", "stop", p["TransportUnit"]])
        for path, versions in tx["Links"].items(): self.fs.cas_link(path, self.fs.link(path), versions["Before"])
        for path, versions in tx["Files"].items(): self.fs.cas(path, self.fs.read(path), versions["Before"])
        self.os.run(["systemctl", "daemon-reload"])
        self.fs.cas(MANIFEST, self.fs.read(MANIFEST), dumps(tx["Before"]))
        self.verify(oldplan, tx["Before"])
        tx["Phase"] = "RolledBack"
        self.write_json(ACTIVE, tx)
        self.archive(tx)

    def recover_transport(self, tx, env):
        try:
            oldplan, newplan = self.validate_transport_journal(tx, env)
            if tx["Phase"] == "Committed":
                self.verify_final_files(tx, "After")
                self.verify(newplan, tx["After"])
                self.archive(tx)
                return {"Status": "Recovered", "Outcome": "CommitPreserved", "MaintenanceKind": "TcpAddition"}
            if tx["Phase"] == "RolledBack":
                self.verify_final_files(tx, "Before")
                self.verify(oldplan, tx["Before"])
                self.archive(tx)
            else: self.rollback_transport(tx, env)
            return {"Status": "Recovered", "Outcome": "RolledBack", "MaintenanceKind": "TcpAddition", "InstalledBinaryRetained": True}
        except Exception as exc:
            if tx["Phase"] not in ("Committed", "RolledBack"):
                tx.update(Phase="NeedsRecovery", RecoveryCode=getattr(exc, "code", "RecoveryFailed"))
                self.write_json(ACTIVE, tx)
            raise TCError("NeedsRecovery", "TCP maintenance ownership/restoration could not be verified; no success was recorded.", TransactionId=tx["TransactionId"], RecoveryCode=getattr(exc, "code", "RecoveryFailed")) from None

    def finalize(self, value):
        """Commit verified initial deployment state without any OS mutations."""
        fields(value, ("PlanId",))
        guid(value["PlanId"])
        env = self.os.probe()
        require(self.owner(env), "PlanNotFound", "No owned deployment state exists.")
        with self.fs.lock():
            plan = self.load_plan(value["PlanId"], env)
            tx = self.read_json(ACTIVE)
            if tx is None:
                state, installed_plan = self.manifest(env)
                require(state is not None and state["Status"] == "Applied" and state["PlanId"] == plan["PlanId"],
                        "FinalizeNotAllowed", "There is no matching applied node or pending initial deployment.")
                self.verify(installed_plan, state)
                peer = self.initial_peer(plan, state)
                return self.applied(plan, state, peer)
            after = tx.get("After")
            require(type(tx.get("SchemaVersion")) is int and tx["SchemaVersion"] == 1
                    and tx.get("PlanId") == plan["PlanId"] and tx.get("Action") == "apply"
                    and tx.get("Before") is None and tx.get("Phase") in ("Pending", "NeedsRecovery", "Committed")
                    and isinstance(after, dict) and after.get("Status") == "Applied",
                    "FinalizeNotAllowed", "Only a matching pending initial apply can be finalized.")
            fields(after, ("SchemaVersion", "PlanId", "NodeId", "Status", "ServerPublicKey", "ConfigRevision", "Peers",
                           "Revoked", "OriginalForwarding", "ResourceHashes"), ("Transport",))
            require(type(after["SchemaVersion"]) is int and after["SchemaVersion"] == 1
                    and after["PlanId"] == plan["PlanId"] and after["NodeId"] == plan["NodeId"]
                    and type(after["ConfigRevision"]) is int and after["ConfigRevision"] == 1
                    and isinstance(after["Peers"], list) and len(after["Peers"]) == 1 and after["Revoked"] == []
                    and tx.get("OriginalForwarding") == after["OriginalForwarding"] == "0",
                    "FinalizeNotAllowed", "Pending state is not an exact initial deployment.")
            peer = self.initial_peer(plan, after)
            self.validate_journal(tx, plan)
            # This is the same full check used before apply commits: exact
            # files, private identity, links, active units, route, nft and WG.
            self.verify(plan, after)
            try:
                if self.read_json(MANIFEST) is None:
                    self.commit(tx)
                else:
                    # A crash can occur after manifest CAS but before recording
                    # Committed. validate_journal + full verify already proved
                    # that the existing manifest equals this exact After state.
                    self.verify_final_files(tx, "After")
                    tx["Phase"] = "Committed"
                    self.write_json(ACTIVE, tx)
                    self.archive(tx)
            except Exception as exc:
                # Do not call failed(): its rollback changes network resources.
                # The durable pending/committed journal remains the write barrier.
                raise TCError("NeedsRecovery", "Verification passed but final state commit or cleanup did not complete; retry finalize or run recover.",
                              TransactionId=tx["TransactionId"],
                              FailureCode=exc.code if isinstance(exc, TCError) else "CommitFailed") from None
            return self.applied(plan, after, peer)

    def initial_peer(self, plan, state):
        peer = next((p for p in state.get("Peers", []) if p.get("RequestId") == plan["ClientRequest"]["RequestId"]), None)
        require(peer is not None, "InitialClientRevoked", "The initial client is absent; finalization will not reauthorize it.")
        require(peer.get("Request") == plan["ClientRequest"] and peer.get("ClientAddress") == plan["ClientAddress"]
                and all(peer.get(k) == plan["ClientRequest"][k] for k in ("RequestId", "DeviceId", "ClientPublicKey")),
                "FinalizeNotAllowed", "The initial client authorization does not match the original plan.")
        return peer

    def pending_diagnostics(self, tx, plan, env):
        """Public, read-only evidence for a pending transaction; no repair occurs.

        Enumerate paths from the validated plan, never from journal path keys.
        Private files are inspected in memory and represented only by metadata,
        hashes and booleans. No exception messages, source text, keys, complete
        manifest/identity objects or journal contents are returned.
        """
        p = paths(plan)
        def token(value):
            return value if isinstance(value, str) and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]{0,63}", value) else "Unknown"
        def error(exc):
            return {"Ok": False, "Code": token(exc.code) if isinstance(exc, TCError) else "DiagnosticFailed",
                    "ExceptionType": token(type(exc).__name__)}
        def check(callback):
            try:
                callback()
                return {"Ok": True}
            except Exception as exc:
                return error(exc)
        def metadata(path):
            try:
                return self.fs.metadata(path)
            except Exception as exc:
                return error(exc)
        report = {"SchemaVersion": 1, "ReadOnly": True,
                  "Transaction": {"TransactionId": guid(tx["TransactionId"]), "PlanId": plan["PlanId"],
                                  "Action": token(tx.get("Action")), "Phase": token(tx.get("Phase")),
                                  "FailureCode": token(tx.get("FailureCode")), "RecoveryCode": token(tx.get("RecoveryCode"))},
                  "Files": [], "Links": [], "Services": [], "State": {}, "Checks": {},
                  "Forwarding": env["Forwarding"] if env["Forwarding"] in ("0", "1") else "Unknown"}
        own, foreign = [], 0
        for item in (env.get("Nft") or {}).get("nftables", []):
            if "metainfo" in item:
                continue
            if len(item) == 1 and isinstance(next(iter(item.values())), dict):
                obj = next(iter(item.values()))
                if obj.get("family") == "inet" and (obj.get("table") == p["Table"] or
                        ("table" in item and obj.get("name") == p["Table"])):
                    own.append(copy.deepcopy(item))
                    continue
            foreign += 1
        actual = {"nftables": own}
        expected = nft_normalized(firewall(plan))
        report["Firewall"] = {"Family": "inet", "Table": p["Table"], "Available": env.get("Nft") is not None,
                              "Actual": actual, "ExpectedNormalized": expected,
                              "MatchesExpected": nft_normalized(actual) == expected, "ForeignObjectCount": foreign}
        for path in resource_paths(plan):
            row = {"Path": path, "Metadata": metadata(path)}
            versions = tx.get("Files", {}).get(path, {})
            for label in ("Before", "After"):
                text = versions.get(label)
                row[label + "Hash"] = digest(text) if isinstance(text, str) else None
            try:
                text = self.fs.read(path)
                row.update(CurrentHash=digest(text) if text is not None else None,
                           MatchesBefore="Before" in versions and text == versions["Before"],
                           MatchesAfter="After" in versions and text == versions["After"])
            except Exception as exc:
                row["ReadCheck"] = error(exc)
            report["Files"].append(row)
        for path, target in link_paths(plan).items():
            row = {"Path": path, "Metadata": metadata(path), "ExpectedTarget": target}
            versions = tx.get("Links", {}).get(path, {})
            try:
                actual_target = self.fs.link(path)
                row.update(TargetMatchesExpected=actual_target == target,
                           MatchesBefore="Before" in versions and actual_target == versions["Before"],
                           MatchesAfter="After" in versions and actual_target == versions["After"])
            except Exception as exc:
                row["ReadCheck"] = error(exc)
            report["Links"].append(row)
        for label in ("Firewall", "Tunnel"):
            row = {"Unit": p[label + "Unit"]}
            try:
                info = self.os.service(p[label + "Unit"])
                row.update({name: token(info.get(name)) for name in ("LoadState", "ActiveState", "UnitFileState")})
                row.update(FragmentPathMatchesExpected=info.get("FragmentPath") == p[label + "Service"],
                           HasDropIns=bool(info.get("DropInPaths")))
            except Exception as exc:
                row["ReadCheck"] = error(exc)
            report["Services"].append(row)
        for label, path in (("Manifest", MANIFEST), ("Identity", p["Identity"])):
            row = {"Metadata": metadata(path)}
            try:
                obj = self.read_json(path)
                row["JsonObjectPresent"] = isinstance(obj, dict)
                if isinstance(obj, dict):
                    row["NodeIdMatchesPlan"] = obj.get("NodeId") == plan["NodeId"]
                    row["PublicKeyFormatValid"] = check(lambda: key(obj.get("ServerPublicKey" if label == "Manifest" else "PublicKey")))["Ok"]
                    if label == "Manifest":
                        row.update(SchemaVersion=obj.get("SchemaVersion") if type(obj.get("SchemaVersion")) is int else None,
                                   Status=token(obj.get("Status")), PlanIdMatchesPlan=obj.get("PlanId") == plan["PlanId"])
                    else:
                        row["SchemaFieldsMatch"] = set(obj) == {"NodeId", "PrivateKey", "PublicKey"}
                if label == "Manifest":
                    row.update(MatchesBefore=obj == tx.get("Before"), MatchesAfter=obj == tx.get("After"))
            except Exception as exc:
                row["ReadCheck"] = error(exc)
            report["State"][label] = row
        report["Checks"]["Journal"] = check(lambda: self.validate_journal(tx, plan))
        report["Checks"]["Services"] = check(lambda: self.check_units(plan, allow_missing=True))
        report["Checks"]["Preflight"] = check(lambda: self.assert_ready(env, plan, owned=True, recovery=True))
        for label in ("Before", "After"):
            state = tx.get(label)
            if isinstance(state, dict) and state.get("Status") == "Applied":
                report["Checks"][label + "Runtime"] = check(lambda state=state: self.verify_runtime(plan, state, env, allow_absent=True))
        if any(link.get("ifname") == p["Interface"] for link in env["Links"]):
            try:
                live = self.os.live(p["Interface"])
                public = {"Present": True, "PeerCount": len(live.get("Peers", {})),
                          "ListenPortMatches": live.get("Port") == str(endpoint(plan["PublicEndpoint"])[1]),
                          "FwMarkDisabled": live.get("FwMark") == "off"}
                for label in ("Before", "After"):
                    state = tx.get(label)
                    if isinstance(state, dict):
                        public[label + "PublicKeyMatches"] = live.get("PublicKey") == state.get("ServerPublicKey")
                        public[label + "PeersMatch"] = live.get("Peers") == {r["ClientPublicKey"]: r["ClientAddress"] for r in state.get("Peers", [])}
                report["WireGuard"] = public
            except Exception as exc:
                report["WireGuard"] = error(exc)
        else:
            report["WireGuard"] = {"Present": False}
        # nft is not a secret store, but an externally modified rule comment
        # must not smuggle a WireGuard key into otherwise public diagnostics.
        def scrub(value):
            if isinstance(value, str):
                return re.sub(r"[A-Za-z0-9+/]{43}=", "[redacted-key]", value)
            if isinstance(value, list):
                return [scrub(v) for v in value]
            if isinstance(value, dict):
                return {scrub(k): scrub(v) for k, v in value.items()}
            return value
        return scrub(report)

    def authorize(self, value):
        fields(value, ("ClientRequest",), ("ClientAddress",))
        request = client_request(value["ClientRequest"])
        return self.change_peers("authorize", request, value.get("ClientAddress"))

    def revoke(self, value):
        fields(value, ("DeviceId",), ("ExpectedConfigRevision", "ApprovedChangeDigest"))
        return self.change_peers("revoke", guid(value["DeviceId"]), None, approval=value)

    def change_peers(self, action, request, requested_address, management_builder=None, lock_held=False, approval=None):
        env = self.os.probe()
        owner = self.owner(env)
        require(owner, "NotInstalled", "No owned server is installed.")
        with contextlib.nullcontext() if lock_held else self.fs.lock():
            self.no_transaction()
            before, plan = self.manifest(env)
            require(before is not None, "NotInstalled", "No owned server is installed.")
            self.verify(plan, before, env)
            if approval: self.manager().verify_approval(action, approval, before, owner, plan)
            after = copy.deepcopy(before)
            peer = None
            if action == "authorize":
                for record in before["Peers"] + before["Revoked"]:
                    if any(record[k] == request[k] for k in ("RequestId", "DeviceId", "ClientPublicKey")):
                        require(record in before["Peers"] and record["Request"] == request and
                                (requested_address is None or requested_address == record["ClientAddress"]),
                                "AuthorizationConflict", "Device, request or key is already registered or revoked.")
                        return dict(self.applied(plan, before, record), Status="Authorized")
                require(len(before["Peers"]) < MAX_PEERS and request["ClientPublicKey"] != before["ServerPublicKey"],
                        "AuthorizationConflict", "Active peer limit reached or client identity conflicts with the server.")
                require(len(before["Revoked"]) < 4096, "RetiredHistoryLimit", "Retired identity history limit reached; retired addresses remain reserved.")
                network = subnet(plan["TunnelSubnet"])
                used = {r["ClientAddress"] for r in before["Peers"] + before["Revoked"]}
                if requested_address is None:
                    requested_address = next((str(network.network_address + i) + "/32" for i in range(2, network.num_addresses - 1)
                                              if str(network.network_address + i) + "/32" not in used), None)
                require(requested_address is not None, "AddressPoolExhausted", "No unused client addresses remain; retired addresses are not automatically reused.")
                address = client_address(network, requested_address)
                require(address not in used, "AddressConflict", "The client address is already used or retired.")
                peer = self.new_peer(request, address)
                after["Peers"].append(peer)
            else:
                peer = next((p for p in before["Peers"] if p["DeviceId"] == request), None)
                if peer is None:
                    require(any(p["DeviceId"] == request for p in before["Revoked"]), "DeviceNotFound", "The device is not registered.")
                    return {"Status": "Revoked", "DeviceId": request, "ConfigRevision": before["ConfigRevision"]}
                after["Peers"].remove(peer)
                after["Revoked"].append(peer)
            after["ConfigRevision"] += 1
            identity = self.identity(plan)
            after["ResourceHashes"] = {p: digest(t) for p, t in resources(plan, identity["PrivateKey"], after["Peers"], identity.get("Transport")).items()}
            metadata = management_builder(plan, before, after, peer) if management_builder else self.manager().peer_transition(action, before, after, peer, owner)
            oldfiles = self.expected_files(plan, before)
            newfiles = self.expected_files(plan, after)
            staged = {p: {"Before": oldfiles[p], "After": newfiles[p]} for p in oldfiles}
            staged.update(metadata)
            proposed = {"SchemaVersion": 2 if metadata else 1, "TransactionId": "11111111-1111-1111-1111-111111111111",
                        "Action": ("authorize_external" if management_builder else action + "_v2") if metadata else action,
                        "Phase": "Pending", "PlanId": plan["PlanId"], "Before": before, "After": after, "Files": staged,
                        "Links": {p: {"Before": target, "After": target} for p, target in link_paths(plan).items()},
                        "OriginalForwarding": env["Forwarding"], "PackageGuard": False}
            if metadata: proposed["ManagementPaths"] = sorted(metadata)
            require(len(dumps(proposed).encode("utf-8")) <= MAX_STATE, "JournalCapacity", "Authorization history exceeds the bounded recovery budget; no new device or invitation was changed.")
            tx = self.start_journal(action, plan, before, env)
            try:
                if metadata:
                    tx["SchemaVersion"] = 2
                    # Publish v2 only with complete staged backups. Its new
                    # action is deliberately rejected by the old v1 recoverer.
                    tx["Action"] = "authorize_external" if management_builder else action + "_v2"
                self.stage(tx, plan, after, management_files=metadata if metadata else None)
                self.write_staged(tx)
                self.os.run(["wg", "syncconf", paths(plan)["Interface"], paths(plan)["Sync"]])
                self.verify(plan, after)
                self.commit(tx)
                if action == "authorize":
                    return dict(self.applied(plan, after, peer), Status="Authorized")
                return {"Status": "Revoked", "DeviceId": request, "ConfigRevision": after["ConfigRevision"]}
            except Exception as exc:
                self.failed(tx, plan, exc)

    def uninstall(self, value):
        fields(value, (), ("ExpectedConfigRevision", "ApprovedChangeDigest"))
        env = self.os.probe()
        require(self.owner(env), "NotInstalled", "No owned server is installed.")
        with self.fs.lock():
            self.no_transaction()
            before, plan = self.manifest(env)
            require(before is not None, "NotInstalled", "No owned server is installed.")
            self.manager().verify_approval("uninstall", value, before, self.owner(env), plan)
            if before["Status"] == "Uninstalled":
                return {"Status": "Uninstalled", "RetainedPrivateState": True, "PackagesRetained": True}
            self.verify(plan, before, env)
            after = dict(copy.deepcopy(before), Status="Uninstalled")
            tx = self.start_journal("uninstall", plan, before, env)
            try:
                self.stage(tx, plan, after)
                self.stop_owned(plan, before, env)
                self.os.run(["sysctl", "-q", "-w", "net.ipv4.ip_forward=" + before["OriginalForwarding"]])
                self.write_staged(tx)
                self.os.run(["systemctl", "daemon-reload"])
                self.verify_absent(plan, before["OriginalForwarding"])
                self.commit(tx)
                return {"Status": "Uninstalled", "RetainedPrivateState": True, "PackagesRetained": True}
            except Exception as exc:
                self.failed(tx, plan, exc)

    def stop_owned(self, plan, manifest, env):
        self.verify_runtime(plan, manifest, env, allow_absent=True)
        self.check_units(plan, allow_missing=True)
        p = paths(plan)
        for label in (('Transport','Tunnel','Firewall') if plan.get('Transport') else ('Tunnel','Firewall')):
            info = self.os.service(p[label + "Unit"])
            if info.get("LoadState") != "not-found":
                self.os.run(["systemctl", "stop", p[label + "Unit"]])
        # A killed oneshot can leave runtime resources with inactive/failed units.
        fresh = self.os.probe()
        self.verify_runtime(plan, manifest, fresh, allow_absent=True)
        if any(x.get("ifname") == p["Interface"] for x in fresh["Links"]):
            self.os.run(["ip", "link", "delete", "dev", p["Interface"]])
        if fresh["Nft"] is not None and nft_normalized(fresh["Nft"]):
            self.os.run(["nft", "delete", "table", "inet", p["Table"]])

    def verify_absent(self, plan, forwarding):
        env = self.os.probe()
        self.assert_ready(env, plan, owned=True, recovery=True)
        require(not any(x.get("ifname") == paths(plan)["Interface"] for x in env["Links"])
                and (env["Nft"] is None or not nft_normalized(env["Nft"])) and env["Forwarding"] == forwarding,
                "RecoveryFailed", "Runtime resources or forwarding were not restored.")

    def verify_final_files(self, tx, outcome):
        for path, versions in tx["Files"].items():
            require(self.fs.read(path) == versions[outcome], "RecoveryFailed", "Final transaction files do not match its outcome.")
        for path, versions in tx["Links"].items():
            require(self.fs.link(path) == versions[outcome], "RecoveryFailed", "Final boot links do not match the transaction outcome.")
        require(self.read_json(MANIFEST) == tx[outcome], "RecoveryFailed", "Final node state does not match the transaction outcome.")

    def validate_journal(self, tx, plan):
        if tx.get("Action") == "transport_add":
            self.validate_transport_journal(tx, self.os.probe())
            return
        guid(tx["TransactionId"])
        require(tx["PlanId"] == plan["PlanId"] and tx["Action"] in ("apply", "authorize", "revoke", "uninstall", "authorize_external", "authorize_v2", "revoke_v2")
                and tx["Phase"] in ("Pending", "NeedsRecovery", "Committed", "RolledBack")
                and tx["OriginalForwarding"] in ("0", "1"), "InvalidJournal", "Transaction journal is invalid.")
        extra = tx.get("ManagementFiles", {}) or {p: tx["Files"][p] for p in tx.get("ManagementPaths", [])}
        if extra: self.manager().validate_peer_journal(tx, plan)
        require(set(tx["Files"]) in (set(), set(resource_paths(plan)) | set(extra))
                and set(tx["Links"]) in (set(), set(link_paths(plan))), "InvalidJournal", "Journal contains unowned resource paths.")
        if tx["Files"]:
            old = self.expected_files(plan, tx["Before"])
            new = self.expected_files(plan, tx["After"])
            expected = {p: {"Before": old[p], "After": new[p]} for p in old}
            expected.update(extra)
            require(tx["Files"] == expected,
                    "InvalidJournal", "Journal backups do not match node state.")
            for p, target in link_paths(plan).items():
                expected = {"Before": target if tx["Before"] and tx["Before"]["Status"] == "Applied" else None,
                            "After": target if tx["After"]["Status"] == "Applied" else None}
                require(tx["Links"].get(p) == expected, "InvalidJournal", "Journal link targets are not owned.")
        else:
            require(not tx["Links"] and tx["After"] is None, "InvalidJournal", "Journal staging is incomplete.")
        for path, versions in tx["Files"].items():
            require(self.fs.read(path) in (versions["Before"], versions["After"]), "OwnershipMismatch", "A transaction resource was modified externally.")
        for path, versions in tx["Links"].items():
            require(self.fs.link(path) in (versions["Before"], versions["After"]), "OwnershipMismatch", "A transaction link was modified externally.")
        require(self.read_json(MANIFEST) in (tx["Before"], tx["After"]), "OwnershipMismatch", "Node state changed outside the transaction.")

    def rollback(self, tx, plan):
        self.validate_journal(tx, plan)
        if tx["PackageGuard"]:
            current = self.fs.read(POLICY)
            require(current in (None, POLICY_TEXT), "OwnershipMismatch", "Package policy changed outside the transaction.")
            self.fs.cas(POLICY, current, None)
        env = self.os.probe()
        self.assert_ready(env, plan, owned=True, recovery=True)
        if tx["After"] is not None:
            candidates = [m for m in (tx["Before"], tx["After"]) if m and m["Status"] == "Applied"]
            compatible = None
            for manifest in candidates:
                try:
                    self.verify_runtime(plan, manifest, env, allow_absent=True)
                    compatible = manifest
                    break
                except TCError:
                    pass
            require(compatible is not None, "OwnershipMismatch", "Runtime resources changed outside the transaction.")
            if tx["Action"] in ("authorize", "revoke", "authorize_external", "authorize_v2", "revoke_v2"):
                # Restore files first, then sync in place: other authorized peers stay connected.
                self.check_units(plan)
                for path, versions in tx["Files"].items():
                    self.fs.cas(path, self.fs.read(path), versions["Before"])
                self.os.run(["wg", "syncconf", paths(plan)["Interface"], paths(plan)["Sync"]])
            else:
                self.stop_owned(plan, compatible, env)
                for path, versions in tx["Links"].items():
                    self.fs.cas_link(path, self.fs.link(path), versions["Before"])
                for path, versions in tx["Files"].items():
                    self.fs.cas(path, self.fs.read(path), versions["Before"])
                self.os.run(["systemctl", "daemon-reload"])
                self.os.run(["sysctl", "-q", "-w", "net.ipv4.ip_forward=" + tx["OriginalForwarding"]])
                if tx["Before"] and tx["Before"]["Status"] == "Applied":
                    self.os.run(["systemctl", "start", paths(plan)["FirewallUnit"]])
                    self.os.run(["systemctl", "start", paths(plan)["TunnelUnit"]])
                    if plan.get('Transport'): self.os.run(['systemctl', 'start', paths(plan)['TransportUnit']])
        if tx["Before"] and tx["Before"]["Status"] == "Applied":
            self.verify(plan, tx["Before"])
        else:
            self.verify_absent(plan, tx["OriginalForwarding"])
        current = self.fs.read(MANIFEST)
        self.fs.cas(MANIFEST, current, dumps(tx["Before"]) if tx["Before"] is not None else None)
        tx["Phase"] = "RolledBack"
        tx["PackageGuard"] = False
        self.write_json(ACTIVE, tx)
        self.archive(tx)

    def failed(self, tx, plan, cause):
        code = cause.code if isinstance(cause, TCError) else "OperationFailed"
        persisted = self.read_json(ACTIVE)
        if persisted and persisted.get("Phase") in ("Committed", "RolledBack"):
            # Archive/cleanup failures cannot reverse a durable final outcome or
            # rewrite its immutable archive. recover verifies then finishes it.
            raise TCError("NeedsRecovery", "The transaction outcome is durable but final cleanup needs recovery.",
                          TransactionId=tx["TransactionId"], FailureCode=code) from None
        try:
            self.rollback(tx, plan)
        except Exception as recovery_error:
            persisted = self.read_json(ACTIVE)
            if persisted and persisted.get("Phase") in ("Committed", "RolledBack"):
                raise TCError("NeedsRecovery", "Restoration completed but final journal cleanup needs recovery.",
                              TransactionId=tx["TransactionId"], FailureCode=code) from None
            tx["Phase"] = "NeedsRecovery"
            tx["FailureCode"] = code
            tx["RecoveryCode"] = recovery_error.code if isinstance(recovery_error, TCError) else "RecoveryFailed"
            try:
                self.write_json(ACTIVE, tx)
            except Exception:
                pass  # The pre-mutation Pending journal remains the recovery barrier.
            raise TCError("NeedsRecovery", "Operation failed and rollback is incomplete; explicit recovery is required.",
                          TransactionId=tx["TransactionId"], FailureCode=code, RecoveryCode=tx["RecoveryCode"]) from None
        raise TCError("RolledBack", "Operation failed; owned configuration was rolled back. Installed packages and identity are retained.",
                      TransactionId=tx["TransactionId"], FailureCode=code) from None

    def recover(self, value):
        fields(value, ())
        env = self.os.probe()
        require(self.owner(env), "NotInstalled", "No owned recovery state exists.")
        with self.fs.lock():
            if self.fs.read(management.PENDING) is not None:
                require(self.fs.read(ACTIVE) is None, "NeedsRecovery", "Two pending journals require explicit diagnosis; refusing to choose an outcome.")
                return self.manager().recover_metadata()
            tx = self.read_json(ACTIVE)
            if tx is None:
                manifest, plan = self.manifest(env)
                if manifest and manifest["Status"] == "Applied":
                    self.verify(plan, manifest, env)
                return {"Status": "NoRecoveryRequired"}
            if tx.get("Action") == "transport_add":
                return self.recover_transport(tx, env)
            plan = self.load_plan(tx["PlanId"], env)
            try:
                self.validate_journal(tx, plan)
                if tx["Phase"] == "Committed":
                    self.verify_final_files(tx, "After")
                    if tx["After"]["Status"] == "Applied":
                        self.verify(plan, tx["After"], env)
                    else:
                        self.verify_absent(plan, tx["After"]["OriginalForwarding"])
                    self.archive(tx)
                    return {"Status": "Recovered", "Outcome": "CommitPreserved"}
                if tx["Phase"] == "RolledBack":
                    self.verify_final_files(tx, "Before")
                    if tx["Before"] and tx["Before"]["Status"] == "Applied":
                        self.verify(plan, tx["Before"], env)
                    else:
                        self.verify_absent(plan, tx["OriginalForwarding"])
                    self.archive(tx)
                else:
                    self.rollback(tx, plan)
                return {"Status": "Recovered", "Outcome": "RolledBack", "PackagesRetained": True}
            except Exception as exc:
                persisted = self.read_json(ACTIVE)
                if persisted and persisted.get("Phase") in ("Committed", "RolledBack"):
                    raise TCError("NeedsRecovery", "Finalized transaction still requires verified journal cleanup.",
                                  TransactionId=tx["TransactionId"]) from None
                tx["Phase"] = "NeedsRecovery"
                tx["RecoveryCode"] = exc.code if isinstance(exc, TCError) else "RecoveryFailed"
                self.write_json(ACTIVE, tx)
                raise TCError("NeedsRecovery", "Recovery could not verify ownership and restoration; no success was recorded.",
                              TransactionId=tx["TransactionId"], RecoveryCode=tx["RecoveryCode"]) from None

    def execute(self, action, value):
        require(action in ACTIONS, "UnknownAction", "Unknown backend action.")
        try:
            if action in management.ACTIONS:
                result = getattr(self.manager(), action)(value)
                if action == "capabilities":
                    result["Actions"].extend(("transport_info", "transport_candidates", "transport_options", "deployment_state"))
                    result["ReadOnlyActions"].extend(("transport_info", "transport_candidates", "transport_options", "deployment_state"))
                return result
            return getattr(self, action)(value)
        except management.ManagementError as exc:
            raise TCError(exc.code, exc.message, **exc.data) from None


def envelope(action, value, backend=None):
    try:
        data = (backend or Backend()).execute(action, value)
        return {"Ok": True, "Action": action, "Data": data, "Message": "Operation completed."}
    except TCError as exc:
        return {"Ok": False, "Action": action, "Data": dict(exc.data, Code=exc.code), "Message": exc.message}
    except Exception as exc:
        # Keep a useful source location without arguments, locals, source lines,
        # filesystem paths or the raw exception text (which may contain keys).
        frames = traceback.extract_tb(exc.__traceback__)
        own = [f for f in frames if os.path.basename(f.filename) == "tradechannel_linux.py"]
        location = own[-1] if own else None
        name = type(exc).__name__
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]{0,63}", name):
            name = "Exception"
        diagnostic = {"ExceptionType": name}
        if location:
            diagnostic.update(Function=location.name, Line=location.lineno)
        return {"Ok": False, "Action": action, "Data": {"Code": "OperationFailed", "Diagnostic": diagnostic},
                "Message": "Server inspection/operation failed (%s at %s:%s); private details were suppressed." %
                           (name, diagnostic.get("Function", "unknown"), diagnostic.get("Line", 0))}


def main(argv=None, stdin=None, stdout=None, backend=None):
    class Parser(argparse.ArgumentParser):
        def error(self, message):
            raise TCError("InvalidArguments", "Use ACTION --input FILE or ACTION --input -.")
    action = "Unknown"
    output = stdout or sys.stdout
    try:
        parser = Parser(add_help=False)
        parser.add_argument("action", choices=ACTIONS)
        parser.add_argument("--input", required=True)
        args = parser.parse_args(argv)
        action = args.action
        if args.input == "-":
            raw = (stdin or sys.stdin).read(MAX_INPUT + 1)
        else:
            # Input is read-only public JSON; all output/resource paths remain pinned.
            with open(args.input, "r", encoding="utf-8-sig") as stream:
                raw = stream.read(MAX_INPUT + 1)
        value = parse_json(raw, limit=MAX_INPUT)
        result = envelope(action, value, backend)
    except TCError as exc:
        result = {"Ok": False, "Action": action, "Data": dict(exc.data, Code=exc.code), "Message": exc.message}
    except Exception:
        result = {"Ok": False, "Action": action, "Data": {"Code": "InputFailed"}, "Message": "Input could not be read."}
    output.write(dumps(result))
    output.flush()
    return 0 if result["Ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
