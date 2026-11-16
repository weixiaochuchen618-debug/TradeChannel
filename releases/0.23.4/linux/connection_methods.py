"""Shared connection contracts and closed, executable Linux dispatch.

The local package and the in-memory SSH payload use the same JSON declaration.
The bootstrap sets _DECLARATION_JSON before exec; no remote file is required.
Only handlers implemented below are callable. Declaration values are never
evaluated as Python, shell commands, import paths, or arbitrary method names.
"""
import copy
import json
import os
import re


_WINDOWS_HANDLERS = {
    "ValidateTransport": {"direct-transport-v1", "reality-transport-v1"},
    "ConfigureClient": {"wireguard-direct-v1", "wireguard-reality-v1"},
    "DeploymentRequest": {"linux-backend-v1"},
    "Deploy": {"linux-backend-v1"},
    "Probe": {"candidate-profile-v1"},
}
_LINUX_HANDLERS = {
    "ValidatePlan": {"direct-plan-v1", "reality-plan-v1"},
    "ConfigureServer": {"wireguard-direct-v1", "wireguard-reality-v1"},
    "PublicParameters": {"direct-parameters-v1", "reality-parameters-v1"},
}
_ACTIONS = {
    "Inspect": "inspect", "Plan": "plan", "Apply": "apply", "Probe": "status",
    "AddPlan": "transport_plan", "AddApply": "transport_apply",
    "Parameters": "transport_info", "Options": "transport_options",
}


def _unique_object(pairs):
    value = {}
    for name, item in pairs:
        if name in value:
            raise ValueError("Duplicate connection capability field.")
        value[name] = item
    return value


def validate_declaration(value):
    """Fail closed on unsupported handlers, inconsistent IDs and action remaps."""
    if (not isinstance(value, dict) or value.get("Kind") != "TradeChannel.ConnectionMethods"
            or value.get("SchemaVersion") != 1 or value.get("ContractVersion") != 1):
        raise ValueError("Unsupported connection capability contract.")
    architectures, aliases = set(), set()
    for arch in value.get("Architectures", []):
        if (arch.get("Id") not in ("amd64", "arm64") or arch["Id"] in architectures
                or arch.get("ElfMachine") != {"amd64": 62, "arm64": 183}[arch["Id"]]
                or not isinstance(arch.get("Aliases"), list) or not arch["Aliases"]):
            raise ValueError("Unsupported architecture declaration.")
        architectures.add(arch["Id"])
        for alias in arch["Aliases"]:
            if (not isinstance(alias, str) or alias != alias.lower() or alias in aliases
                    or alias not in {"amd64": ("amd64", "x86_64"), "arm64": ("arm64", "aarch64")}[arch["Id"]]):
                raise ValueError("Invalid or duplicate architecture alias.")
            aliases.add(alias)
    if architectures != {"amd64", "arm64"} or aliases != {"amd64", "x86_64", "arm64", "aarch64"}:
        raise ValueError("Required architecture declaration is missing.")
    if value.get("LinuxTargets") != [{"Id": "ubuntu", "Version": "24.04"}, {"Id": "debian", "Version": "13"}]:
        raise ValueError("Unsupported Linux target declaration.")
    ids, types = set(), set()
    for method in value.get("Methods", []):
        identifier, transport = method.get("Id"), method.get("TransportType")
        if (not isinstance(identifier, str) or not re.fullmatch(r"[A-Z][A-Za-z0-9]{0,31}", identifier)
                or identifier == "Auto" or identifier in ids or transport in types
                or transport not in ("udp-direct", "tcp-reality")):
            raise ValueError("Invalid or duplicate connection method.")
        ids.add(identifier)
        types.add(transport)
        reality = transport == "tcp-reality"
        if (method.get("RequiresTransport") is not reality or method.get("NetworkProtocol") != ("Tcp" if reality else "Udp")
                or method.get("ServerPlatforms") != ["linux"]
                or method.get("ServerArchitectures") != ["amd64", "arm64"]
                or type(method.get("PreferenceOrder")) is not int
                or not all(isinstance(method.get(k), str) and method[k] for k in ("DisplayName", "TechnicalName"))):
            raise ValueError("Inconsistent connection method contract.")
        for section, allowed in (("Handlers", _WINDOWS_HANDLERS), ("LinuxHandlers", _LINUX_HANDLERS)):
            handlers = method.get(section, {})
            if set(handlers) != set(allowed) or any(handlers[k] not in allowed[k] for k in allowed):
                raise ValueError("Unregistered connection method handler.")
        if (method["Handlers"]["ValidateTransport"] != ("reality-transport-v1" if reality else "direct-transport-v1")
                or method["Handlers"]["ConfigureClient"] != ("wireguard-reality-v1" if reality else "wireguard-direct-v1")
                or method["LinuxHandlers"]["ValidatePlan"] != ("reality-plan-v1" if reality else "direct-plan-v1")
                or method["LinuxHandlers"]["ConfigureServer"] != method["Handlers"]["ConfigureClient"]
                or method["LinuxHandlers"]["PublicParameters"] != ("reality-parameters-v1" if reality else "direct-parameters-v1")):
            raise ValueError("Connection handler does not match its transport.")
        probe = method.get("Probe", {})
        if (probe.get("ProfileId") != identifier or probe.get("Handler") != "candidate-profile-v1"
                or probe.get("Transport") != ("WireGuardOverVlessReality" if reality else "WireGuardUdp")
                or probe.get("ChangesActiveConnection") is not False or probe.get("RequiresBoundPathEvidence") is not True):
            raise ValueError("Inconsistent connection probe contract.")
        phases = method.get("Deployment", {})
        expected = set(_ACTIONS) if reality else {"Inspect", "Plan", "Apply", "Probe"}
        if set(phases) != expected:
            raise ValueError("Incomplete connection deployment contract.")
        for phase, contract in phases.items():
            if (contract.get("Action") != _ACTIONS[phase]
                    or contract.get("Mutates") is not (phase in ("Plan", "Apply", "AddPlan", "AddApply"))
                    or not all(isinstance(contract.get(k), list) and all(isinstance(x, str) for x in contract[k])
                               for k in ("Required", "Optional"))
                    or len(set(contract["Required"] + contract["Optional"])) != len(contract["Required"] + contract["Optional"])):
                raise ValueError("Unregistered deployment action or input contract.")
    if ids != {"Udp", "Tcp"} or types != {"udp-direct", "tcp-reality"}:
        raise ValueError("The legacy connection methods must remain available.")
    return copy.deepcopy(value)


def _load():
    raw = globals().get("_DECLARATION_JSON")
    if raw is None:
        path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "ConnectionMethods.json")
        with open(path, "r", encoding="utf-8-sig") as stream:
            raw = stream.read(65537)
    if not isinstance(raw, str) or len(raw.encode("utf-8")) > 65536:
        raise ValueError("Connection capability declaration exceeds its size limit.")
    return validate_declaration(json.loads(raw, object_pairs_hook=_unique_object))


_DECLARATION = _load()


def declaration():
    return copy.deepcopy(_DECLARATION)


def methods():
    return sorted(copy.deepcopy(_DECLARATION["Methods"]), key=lambda row: (row["PreferenceOrder"], row["Id"]))


def method(identifier, require):
    found = [item for item in _DECLARATION["Methods"] if item["Id"] == identifier]
    require(len(found) == 1, "UnknownConnectionMethod", "The connection method is not registered.")
    return copy.deepcopy(found[0])


def for_plan(plan, require):
    transport = plan.get("Transport")
    require(transport is None or isinstance(transport, dict), "InvalidTransport", "Transport must be an object.")
    kind = "udp-direct" if transport is None else transport.get("Type")
    found = [item for item in _DECLARATION["Methods"] if item["TransportType"] == kind]
    require(len(found) == 1, "InvalidTransport", "The server transport type is not registered.")
    return copy.deepcopy(found[0])


def normalize_architecture(machine):
    if not isinstance(machine, str):
        return None
    name = machine.strip().lower()
    return next((row["Id"] for row in _DECLARATION["Architectures"] if name in row["Aliases"]), None)


def architecture(machine, require):
    identifier = normalize_architecture(machine)
    require(identifier is not None, "UnsupportedArchitecture", "Only Linux amd64 and arm64 components are supported.")
    return copy.deepcopy(next(row for row in _DECLARATION["Architectures"] if row["Id"] == identifier))


def supports_environment(osinfo):
    return (isinstance(osinfo, dict) and {"Id": osinfo.get("Id"), "Version": osinfo.get("Version")} in _DECLARATION["LinuxTargets"]
            and normalize_architecture(osinfo.get("Architecture")) is not None)


def _direct_plan(plan, require):
    require(plan.get("Transport") is None, "InvalidTransport", "Standard connections do not use a transport overlay.")


def _reality_plan(plan, require):
    value = plan.get("Transport")
    require(isinstance(value, dict) and set(value) == {"Type", "Port", "ServerName"}, "InvalidTransport", "Invalid server transport fields.")
    require(value["Type"] == "tcp-reality" and type(value["Port"]) is int and 1 <= value["Port"] <= 65535,
            "InvalidTransport", "Invalid server transport type or port.")
    require(isinstance(value["ServerName"], str) and len(value["ServerName"]) <= 253
            and re.fullmatch(r"(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}", value["ServerName"]),
            "InvalidTransport", "Reality requires a valid fully qualified handshake server name.")


def validate_plan(plan, require):
    selected = for_plan(plan, require)
    handlers = {"direct-plan-v1": _direct_plan, "reality-plan-v1": _reality_plan}
    handlers[selected["LinuxHandlers"]["ValidatePlan"]](plan, require)
    return selected


def _wireguard_config(plan, private, peers, identity, mtu, require):
    header = ["[Interface]", "PrivateKey = " + private, "ListenPort = " + plan["PublicEndpoint"].rsplit(":", 1)[1]]
    lines = []
    for peer in sorted(peers, key=lambda row: row["ClientAddress"]):
        lines += ["", "[Peer]", "PublicKey = " + peer["ClientPublicKey"], "AllowedIPs = " + peer["ClientAddress"]]
    return {"WireGuardConfig": "\n".join(header + ["Address = " + plan["ServerAddress"], "MTU = " + str(mtu), "Table = off"] + lines) + "\n",
            "WireGuardSync": "\n".join(header + lines) + "\n", "TransportConfig": None}


def _reality_config(plan, private, peers, identity, mtu, require):
    import transport_support
    require(identity is not None, "IdentityMissing", "TCP identity is missing.")
    result = _wireguard_config(plan, private, peers, identity, mtu, require)
    result["TransportConfig"] = transport_support.configuration(plan, peers, identity)
    return result


def server_configuration(plan, private, peers, identity, mtu, require):
    selected = validate_plan(plan, require)
    handlers = {"wireguard-direct-v1": _wireguard_config, "wireguard-reality-v1": _reality_config}
    return handlers[selected["LinuxHandlers"]["ConfigureServer"]](plan, private, peers, identity, mtu, require)


def public_parameters(plan, manifest, peer, require):
    import transport_support
    selected = validate_plan(plan, require)
    handlers = {"direct-parameters-v1": lambda *_: None, "reality-parameters-v1": transport_support.public_parameters}
    return handlers[selected["LinuxHandlers"]["PublicParameters"]](plan, manifest, peer)


def deployment_request(identifier, phase, value, require):
    selected = method(identifier, require)
    contract = selected["Deployment"].get(phase)
    require(contract is not None, "UnsupportedConnectionOperation", "This connection method does not support that deployment phase.")
    require(isinstance(value, dict) and set(contract["Required"]) <= set(value)
            and set(value) <= set(contract["Required"] + contract["Optional"]),
            "InvalidInput", "Deployment input does not match the registered phase.")
    if phase in ("Plan", "AddPlan"):
        actual = validate_plan(value, require)
        require(actual["Id"] == identifier, "ConnectionMethodMismatch", "The requested method does not match the deployment transport.")
    return {"Kind": "TradeChannel.ConnectionMethodRequest", "ContractVersion": 1, "MethodId": identifier,
            "Phase": phase, "Operation": contract["Action"], "Input": copy.deepcopy(value), "Mutates": contract["Mutates"]}


def dispatch(backend, identifier, phase, value, require):
    """Use the existing backend execution/ownership/approval boundary unchanged."""
    request = deployment_request(identifier, phase, value, require)
    return backend.execute(request["Operation"], request["Input"])
