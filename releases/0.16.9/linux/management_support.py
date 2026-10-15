"""Linux management API v2 and offline pairing v1 / optional signed grant v2.

No listener, automatic network switch or SSH credentials are introduced here.
Management state is an explicit, sidecar-only upgrade of an owned v1 node.
All mutable operations use the existing server lock. Peer/invite changes share
the backend's durable journal, so a crash never permits a second consumption.
OpenSSL implements RSA; this module only encodes standard DER/JWS containers.
"""
import base64
import copy
import datetime as dt
import hashlib
import ipaddress
import json
import os
import re
import shutil
import subprocess
import tempfile
import uuid

API_VERSION = 2
PAIR_LIMIT = 128 * 1024
PAGE_LIMIT = 256 * 1024
ROOT = "/var/lib/tradechannel"
DIRECTORY = ROOT + "/management"
STATE = DIRECTORY + "/state.json"
PRIVATE_KEY = DIRECTORY + "/signing.pem"
PUBLIC_KEY = DIRECTORY + "/signing-public.json"
PENDING = ROOT + "/management-active.json"
ACTIONS = ("capabilities", "server_info", "devices", "management_plan", "management_apply",
           "management_recovery_state",
           "invite_create", "invite_cancel", "invite_status", "authorize_external", "request_status",
           "device_rename", "revoke_preview", "uninstall_preview")
DIGEST_ALGORITHM = "TC-ClientRequest-v1"
EXIT_TRACE_TARGET = "https://1.1.1.1/cdn-cgi/trace"
EXIT_EVIDENCE_LIFETIME = dt.timedelta(hours=24)


class ManagementError(Exception):
    def __init__(self, code, message, **data):
        super().__init__(message)
        self.code, self.message, self.data = code, message, data


def require(condition, code="InvalidInput", message="Management input does not match the supported schema."):
    if not condition:
        raise ManagementError(code, message)


def compact(value):
    return json.dumps(value, ensure_ascii=True, sort_keys=True, separators=(",", ":"))


def b64(value):
    return base64.urlsafe_b64encode(value).decode("ascii").rstrip("=")


def unb64(value, limit=PAIR_LIMIT):
    require(isinstance(value, str) and len(value) <= limit and re.fullmatch(r"[A-Za-z0-9_-]+", value),
            "InvalidJws", "Invalid base64url segment.")
    try:
        raw = base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))
    except (ValueError, TypeError):
        raise ManagementError("InvalidJws", "Invalid base64url segment.") from None
    require(b64(raw) == value, "InvalidJws", "Noncanonical base64url segment.")
    return raw


def strict_json(raw):
    require(len(raw) <= PAIR_LIMIT, "InputTooLarge", "Pairing data exceeds 128 KiB.")
    def pairs(values):
        result = {}
        for k, v in values:
            require(k not in result, "InvalidJson", "Duplicate JSON fields are rejected.")
            result[k] = v
        return result
    try:
        value = json.loads(raw.decode("utf-8"), object_pairs_hook=pairs,
                           parse_constant=lambda _: require(False, "InvalidJson", "Invalid number."))
    except (ValueError, UnicodeError, RecursionError):
        raise ManagementError("InvalidJson", "Pairing JSON could not be decoded.") from None
    def depth(value, level=0):
        require(level <= 16, "InvalidJson", "Pairing nesting exceeds the limit.")
        for child in value.values() if isinstance(value, dict) else value if isinstance(value, list) else ():
            depth(child, level + 1)
    depth(value)
    return value


def schema(value, required, optional=()):
    require(isinstance(value, dict) and set(required) <= set(value) <= set(required) | set(optional))


def request_digest(request):
    """Stable cross-language tuple: strict v1 strings, LF separators, no final LF."""
    names = ("SchemaVersion", "Kind", "RequestId", "DeviceId", "CreatedAtUtc", "ClientPublicKey")
    text = "\n".join(str(request[n]) for n in names) + "\nIPv4"
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def validate_jwk(jwk):
    schema(jwk, ("kty", "n", "e"))
    require(jwk["kty"] == "RSA", "InvalidRecipientKey", "Only RSA public recipient keys are supported.")
    modulus, exponent = unb64(jwk["n"], 600), unb64(jwk["e"], 16)
    require(len(modulus) == 384 and modulus[0] & 0x80 and int.from_bytes(exponent, "big") == 65537,
            "InvalidRecipientKey", "Pairing requires RSA-3072 with exponent 65537.")
    return jwk


def der(tag, content):
    length = len(content)
    encoded = bytes([length]) if length < 128 else bytes([0x80 | ((length.bit_length() + 7) // 8)]) + length.to_bytes((length.bit_length() + 7) // 8, "big")
    return bytes([tag]) + encoded + content


def public_der(jwk):
    validate_jwk(jwk)
    def integer(value):
        return der(2, b"\0" + value if value[0] & 0x80 else value)
    rsa = der(0x30, integer(unb64(jwk["n"])) + integer(unb64(jwk["e"])))
    # rsaEncryption OID + explicit NULL, subjectPublicKey BIT STRING.
    return der(0x30, bytes.fromhex("300d06092a864886f70d0101010500") + der(3, b"\0" + rsa))


def parse_public_der(value):
    def item(raw, offset=0):
        require(offset + 2 <= len(raw), "InvalidSigningKey", "Invalid RSA public encoding.")
        tag, length, at = raw[offset], raw[offset + 1], offset + 2
        if length & 0x80:
            count = length & 0x7f
            require(0 < count <= 4 and at + count <= len(raw), "InvalidSigningKey")
            length, at = int.from_bytes(raw[at:at + count], "big"), at + count
        require(at + length <= len(raw), "InvalidSigningKey")
        return tag, raw[at:at + length], at + length
    tag, content, end = item(value)
    require(tag == 0x30 and end == len(value), "InvalidSigningKey")
    alg, algorithm, pos = item(content)
    require(alg == 0x30 and algorithm == bytes.fromhex("06092a864886f70d0101010500"), "InvalidSigningKey")
    tag, bits, end = item(content, pos)
    require(tag == 3 and bits[:1] == b"\0" and end == len(content), "InvalidSigningKey")
    tag, rsa, end = item(bits[1:])
    require(tag == 0x30 and end == len(bits) - 1, "InvalidSigningKey")
    tag, n, pos = item(rsa)
    require(tag == 2, "InvalidSigningKey")
    tag, e, end = item(rsa, pos)
    require(tag == 2 and end == len(rsa), "InvalidSigningKey")
    jwk = {"kty": "RSA", "n": b64(n.lstrip(b"\0")), "e": b64(e.lstrip(b"\0"))}
    validate_jwk(jwk)
    return jwk


class OpenSSLCrypto:
    """Fixed-argument OpenSSL calls; private PEM never enters argv or logs."""
    def __init__(self, executable=None):
        self.executable = executable or ("/usr/bin/openssl" if os.name == "posix" else shutil.which("openssl"))

    def available(self):
        return bool(self.executable and os.path.isfile(self.executable))

    def run(self, args, data=None):
        require(self.available(), "MissingManagementDependency", "OpenSSL is required for management signing; install the distribution openssl package before applying this plan.")
        try:
            process = subprocess.run([self.executable] + args, input=data, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, timeout=45, check=False)
        except (OSError, subprocess.TimeoutExpired):
            raise ManagementError("SigningOperationFailed", "The cryptographic operation did not complete.") from None
        require(process.returncode == 0, "SigningOperationFailed", "The cryptographic operation failed; private details were suppressed.")
        require(len(process.stdout) <= PAIR_LIMIT, "SigningOperationFailed", "Cryptographic output exceeds the limit.")
        return process.stdout

    def generate(self):
        private = self.run(["genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:3072",
                            "-pkeyopt", "rsa_keygen_pubexp:65537"]).decode("ascii")
        return private, self.public(private)

    def public(self, private):
        raw = self.run(["pkey", "-pubout", "-outform", "DER"], private.encode("ascii"))
        return parse_public_der(raw)

    def sign(self, private, data):
        with tempfile.TemporaryDirectory(prefix="tc-management-") as directory:
            if os.name == "posix": os.chmod(directory, 0o700)
            path = os.path.join(directory, "private.pem")
            with open(path, "x", encoding="ascii") as stream: stream.write(private)
            if os.name == "posix": os.chmod(path, 0o600)
            return self.run(["dgst", "-sha256", "-sign", path], data)

    def verify(self, jwk, data, signature):
        validate_jwk(jwk)
        require(len(signature) == 384, "InvalidSignature", "RSA-3072 signatures must be 384 bytes.")
        with tempfile.TemporaryDirectory(prefix="tc-management-") as directory:
            if os.name == "posix": os.chmod(directory, 0o700)
            public, sig = os.path.join(directory, "public.der"), os.path.join(directory, "signature.bin")
            with open(public, "xb") as stream: stream.write(public_der(jwk))
            with open(sig, "xb") as stream: stream.write(signature)
            try:
                self.run(["dgst", "-sha256", "-verify", public, "-keyform", "DER", "-signature", sig], data)
            except ManagementError as exc:
                if exc.code == "SigningOperationFailed": return False
                raise
        return True


def sign_jws(crypto, private, body):
    header = b64(b'{"alg":"RS256","typ":"JWT"}')
    payload = b64(compact(body).encode("utf-8"))
    message = (header + "." + payload).encode("ascii")
    result = message.decode("ascii") + "." + b64(crypto.sign(private, message))
    require(len(result) <= PAIR_LIMIT, "InputTooLarge", "Signed pairing data exceeds the limit.")
    return result


def decode_jws(value):
    require(isinstance(value, str) and len(value.encode("utf-8")) <= PAIR_LIMIT and value.count(".") == 2,
            "InvalidJws", "Pairing input must be a compact JWS within 128 KiB.")
    header, payload, signature = value.split(".")
    head = strict_json(unb64(header, 4096))
    schema(head, ("alg",), ("typ",))
    require(head["alg"] == "RS256" and head.get("typ", "JWT") == "JWT", "InvalidAlgorithm", "Only RS256 JWS is allowed; unknown headers are rejected.")
    return strict_json(unb64(payload)), (header + "." + payload).encode("ascii"), unb64(signature, 1024)


class Manager:
    def __init__(self, backend):
        self.b = backend
        self.crypto = backend.management_crypto

    def at(self):
        return self.b.now().astimezone(dt.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")

    def time(self, text):
        from datetime import datetime
        try:
            require(isinstance(text, str) and re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,7})?(?:Z|\+00:00)", text))
            return datetime.fromisoformat(text.replace("Z", "+00:00"))
        except ValueError:
            raise ManagementError("InvalidInput", "Invalid UTC timestamp.") from None

    def guid(self, value):
        require(isinstance(value, str) and re.fullmatch(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", value))
        require(uuid.UUID(value).int != 0)
        return value

    def name(self, value):
        require(isinstance(value, str) and 1 <= len(value) <= 80 and value == value.strip() and value.isprintable())
        return value

    def context(self, applied=True):
        env = self.b.os.probe()
        owner = self.b.owner(env)
        require(owner is not None, "NotInstalled", "No owned server installation exists.")
        manifest, plan = self.b.manifest(env)
        require(manifest is not None, "NotInstalled", "No owned node exists.")
        if applied: require(manifest["Status"] == "Applied", "NodeUninstalled", "The server service has been uninstalled.")
        return env, owner, manifest, plan

    def locked_context(self, env, applied=True):
        """Re-read authoritative files after obtaining the shared lock."""
        owner = self.b.owner(env)
        manifest, plan = self.b.manifest(env)
        require(owner is not None and manifest is not None, "NotInstalled", "The node changed while waiting for the server lock.")
        if applied: require(manifest["Status"] == "Applied", "NodeUninstalled", "The service has been uninstalled.")
        return owner, manifest, plan

    def binding(self, owner, manifest):
        return {"RemoteOwnerId": owner["OwnerId"], "NodeId": manifest["NodeId"], "ServerPublicKey": manifest["ServerPublicKey"]}

    def load(self, owner, manifest, required=True):
        value = self.b.read_json(STATE)
        if value is None:
            require(not required, "ManagementUpgradeRequired", "Apply an explicit management capability plan first.")
            return None
        require(isinstance(value, dict) and value.get("SchemaVersion") == 2 and value.get("Kind") == "TradeChannel.ManagementState"
                and value.get("ServerBinding") == self.binding(owner, manifest), "ManagementIdentityMismatch", "Management metadata belongs to another server identity.")
        require(type(value.get("ManagementRevision")) is int and value["ManagementRevision"] >= 1
                and isinstance(value.get("Devices"), dict) and isinstance(value.get("Invites"), dict), "InvalidManagementState")
        return value

    def signing(self):
        private, public = self.b.fs.read(PRIVATE_KEY), self.b.read_json(PUBLIC_KEY)
        require(private is not None and public is not None, "ManagementIdentityMissing", "The pinned management signing identity is missing; refusing to replace it.")
        validate_jwk(public)
        require(self.crypto.public(private) == public, "ManagementIdentityMismatch", "Management signing identity has changed.")
        return private, public

    def audit(self, state, action, **public):
        state["ManagementRevision"] += 1
        records = state.get("Audit", [])
        state["Audit"] = (records + [dict(public, Action=action, AtUtc=self.at())])[-200:]

    def init_dirs(self):
        self.b.fs.mkdir(DIRECTORY)
        for name in ("plans", "requests"):
            self.b.fs.mkdir(DIRECTORY + "/" + name)

    def public_state(self, state):
        return {"ManagementApiVersion": API_VERSION if state else 1,
                "ManagementRevision": state["ManagementRevision"] if state else None}

    def capabilities(self, value):
        schema(value, ())
        env = self.b.os.probe()
        owner = self.b.owner(env)
        manifest, plan = self.b.manifest(env) if owner else (None, None)
        state = self.load(owner, manifest, False) if manifest else None
        return dict(self.public_state(state), BackendApiVersion=API_VERSION, PairingVersion=1 if state else None,
                    Actions=list(ACTIONS) + ["transport_plan", "transport_apply"], ReadOnlyActions=["capabilities", "server_info", "devices", "management_recovery_state", "invite_status", "request_status", "revoke_preview", "uninstall_preview"],
                    ManagementUpgradeRequired=not bool(state), OpenSSLAvailable=self.crypto.available(),
                    ExternalAuthorization=bool(state), DeviceCatalog=True, SharedTcpAuthentication=bool(plan and plan.get("Transport")),
                    AutomaticNetworkActivation=False, IncrementalTcpAddition=bool(manifest and manifest["Status"] == "Applied" and not plan.get("Transport")))

    def server_info(self, value):
        schema(value, ())
        env = self.b.os.probe()
        owner = self.b.owner(env)
        if owner is None:
            return {"OwnershipState": "NotInstalled", "ManagementApiVersion": 1, "Node": None, "RemoteOwnerId": None}
        with self.b.fs.lock(readonly=True):
            manifest, plan = self.b.manifest(env)
            state = self.load(owner, manifest, False) if manifest else None
            tx = self.b.read_json(ROOT + "/active.json") or self.b.read_json(PENDING)
            result = dict(self.public_state(state), RemoteOwnerId=owner["OwnerId"], Node=self.b.node(plan, manifest) if manifest else None,
                          OwnershipState="NeedsRecovery" if tx else manifest["Status"] if manifest else "OwnedNotInstalled",
                          PendingOperation={"Action": tx.get("Action"), "TransactionId": tx.get("TransactionId")} if tx else None,
                          ConfigRevision=manifest["ConfigRevision"] if manifest else None, ManagementSigningPublicKey=None,
                          ObservedExit=None, ObservedExitEvidence="NotTested", SharedTcpAuthentication=bool(plan and plan.get("Transport")))
            result["ActivePlanId"] = manifest["PlanId"] if manifest else None
            result["Protocols"] = (["udp", "tcp-reality"] if plan and plan.get("Transport") else ["udp"]) if manifest and manifest["Status"] == "Applied" else []
            result["Services"] = []
            if plan and manifest and manifest["Status"] == "Applied":
                names = self.b.service_paths(plan)
                for label in (("Firewall", "Tunnel", "Transport") if plan.get("Transport") else ("Firewall", "Tunnel")):
                    service = self.b.os.service(names[label + "Unit"])
                    result["Services"].append({"Role": label, "Unit": names[label + "Unit"], "ActiveState": service.get("ActiveState"),
                        "MainPID": service.get("MainPID"), "ActiveEnterTimestampMonotonic": service.get("ActiveEnterTimestampMonotonic"),
                        "ExecMainStartTimestampMonotonic": service.get("ExecMainStartTimestampMonotonic")})
            if state:
                _, result["ManagementSigningPublicKey"] = self.signing()
            if manifest and manifest["Status"] == "Applied" and not tx:
                try:
                    self.b.verify(plan, manifest, env)
                    result["Health"] = {"LocalConfiguration": "Verified", "ExternalConnectivity": "NotTested"}
                except Exception as exc:
                    result["Health"] = {"LocalConfiguration": "Failed", "Code": getattr(exc, "code", "VerificationFailed")}
            return result

    def management_recovery_state(self, value):
        """Prove an expired proposal has no current effect, without retrying it.

        Expiry is checked under the same lock as management_apply: a delayed
        original command can no longer initialize metadata after this proof.
        A partial identity is never treated as an unused proposal.
        """
        schema(value, ("PlanId", "ApprovedChangeDigest"))
        self.guid(value["PlanId"])
        require(isinstance(value["ApprovedChangeDigest"], str)
                and re.fullmatch(r"[0-9a-f]{64}", value["ApprovedChangeDigest"]))
        env = self.b.os.probe()
        with self.b.fs.lock(readonly=True):
            owner, manifest, plan = self.locked_context(env)
            self.b.no_transaction()
            self.b.verify(plan, manifest, env)
            approved = self.b.read_json(DIRECTORY + "/plans/" + value["PlanId"] + ".json")
            require(isinstance(approved, dict) and approved.get("SchemaVersion") == 2
                    and approved.get("Kind") == "TradeChannel.ManagementPlan"
                    and approved.get("PlanId") == value["PlanId"]
                    and approved.get("ServerBinding") == self.binding(owner, manifest)
                    and approved.get("ChangeDigest") == value["ApprovedChangeDigest"],
                    "ApprovalMismatch", "The original management proposal is unavailable or belongs to another intent.")
            unsigned = {k: v for k, v in approved.items() if k != "ChangeDigest"}
            require(hashlib.sha256(compact(unsigned).encode("utf-8")).hexdigest() == approved["ChangeDigest"],
                    "ApprovalMismatch", "The original proposal changed.")
            require(approved["ConfigRevision"] == manifest["ConfigRevision"],
                    "RevisionConflict", "The tunnel configuration changed after the original proposal.")
            require(self.time(approved["ExpiresAtUtc"]) <= self.b.now(),
                    "ManagementPlanStillValid", "The original proposal can still execute; its outcome is not resolved.")
            absent = {name: self.b.fs.read(path) is None for name, path in
                      (("State", STATE), ("PrivateKey", PRIVATE_KEY), ("PublicKey", PUBLIC_KEY))}
            require(all(absent.values()), "ManagementInitializationPresent",
                    "Management files exist; preserve their identity and inspect the original transaction.")
            archives = self.b.fs.list(ROOT + "/transactions")
            require(len(archives) <= 1024, "ManagementHistoryUnverified", "Initialization history exceeds the read budget.")
            for leaf in archives:
                require(re.fullmatch(r"[0-9a-f-]{36}\.json", leaf), "InvalidJournal", "Unexpected transaction archive.")
                tx = self.b.read_json(ROOT + "/transactions/" + leaf)
                require(isinstance(tx, dict) and tx.get("TransactionId") == leaf[:-5], "InvalidJournal")
                require(tx.get("Action") != "management_apply", "ManagementHistoryPresent",
                        "A previous management initialization is archived; recover that identity instead of replacing it.")
            return {"SchemaVersion": 1, "Kind": "TradeChannel.ManagementRecoveryState", "Outcome": "NotApplied",
                    "PlanId": approved["PlanId"], "ApprovedChangeDigest": approved["ChangeDigest"],
                    "ServerBinding": self.binding(owner, manifest), "ConfigRevision": manifest["ConfigRevision"],
                    "PlanExpiresAtUtc": approved["ExpiresAtUtc"], "ObservedAtUtc": self.at(), "PlanExpired": True,
                    "FilesAbsent": absent, "PendingOperation": None, "Health": {"LocalConfiguration": "Verified"},
                    "ManagementHistoryAbsent": True, "ReadOnly": True}

    def devices(self, value):
        schema(value, (), ("Offset", "Limit", "IncludeRevoked"))
        offset, limit, revoked = value.get("Offset", 0), value.get("Limit", 50), value.get("IncludeRevoked", True)
        require(type(offset) is int and 0 <= offset <= 100000 and type(limit) is int and 1 <= limit <= 100 and type(revoked) is bool)
        env, owner, manifest, plan = self.context(False)
        with self.b.fs.lock(readonly=True):
            owner, manifest, plan = self.locked_context(env, False)
            state = self.load(owner, manifest, False)
            rows = []
            for records, status in ((manifest["Peers"], "Authorized"), (manifest["Revoked"] if revoked else [], "Revoked")):
                for peer in records:
                    meta = state["Devices"].get(peer["DeviceId"], {}) if state else {}
                    rows.append({"DeviceId": peer["DeviceId"], "RequestId": peer["RequestId"], "ClientPublicKey": peer["ClientPublicKey"],
                                 "ClientAddress": peer["ClientAddress"], "Name": meta.get("Name") or "Device " + peer["DeviceId"][:8],
                                 "State": status, "AuthorizedAtUtc": meta.get("AuthorizedAtUtc"), "RevokedAtUtc": meta.get("RevokedAtUtc"),
                                 "LastHandshakeUtc": None, "Traffic": None, "Telemetry": "NotRequested", "Source": meta.get("Source", "Legacy"),
                                 "TimeEvidence": "Known" if meta.get("AuthorizedAtUtc") else "Unknown"})
            rows.sort(key=lambda r: (r["State"] != "Authorized", r["DeviceId"]))
            result = {"Devices": rows[offset:offset + limit], "Total": len(rows), "NextOffset": offset + limit if offset + limit < len(rows) else None,
                      "ConfigRevision": manifest["ConfigRevision"], "ActiveDeviceCount": len(manifest["Peers"]),
                      "RevokedDeviceCount": len(manifest["Revoked"]), "ActiveDeviceLimit": 256, "ReadOnly": True,
                      "PendingOperation": bool(self.b.fs.read(ROOT + "/active.json") or self.b.fs.read(PENDING))}
            require(len(compact(result).encode("utf-8")) <= PAGE_LIMIT, "ResultTooLarge", "Device page exceeds 256 KiB; use a smaller page.")
            return result

    def management_plan(self, value):
        schema(value, ())
        env, owner, manifest, plan = self.context()
        with self.b.fs.lock():
            owner, manifest, plan = self.locked_context(env)
            self.b.no_transaction()
            self.b.verify(plan, manifest, env)
            current = self.load(owner, manifest, False)
            if current:
                self.signing()
                return dict(self.public_state(current), Status="AlreadyEnabled", Changes=[])
            self.init_dirs()
            for leaf in self.b.fs.list(DIRECTORY + "/plans"):
                require(re.fullmatch(r"[0-9a-f-]{36}\.json", leaf), "OwnershipMismatch", "Unexpected management proposal file.")
                retained = self.b.read_json(DIRECTORY + "/plans/" + leaf)
                require(retained and retained.get("PlanId") == leaf[:-5] and retained.get("Kind") == "TradeChannel.ManagementPlan", "InvalidManagementState")
                if self.time(retained["ExpiresAtUtc"]) <= self.b.now():
                    self.b.fs.cas(DIRECTORY + "/plans/" + leaf, self.b.dumps(retained), None)
            require(len(self.b.fs.list(DIRECTORY + "/plans")) < 128, "PlanLimit", "Management proposal limit reached; wait for unused proposals to expire.")
            changes = ["Create independent RSA-3072 management signing identity", "Index existing device identities without inventing historical timestamps",
                       "Enable offline invitations and device metadata; preserve all running services, tunnel keys, peers, ports and rules"]
            data = {"SchemaVersion": 2, "Kind": "TradeChannel.ManagementPlan", "PlanId": str(uuid.uuid4()),
                    "ServerBinding": self.binding(owner, manifest), "ConfigRevision": manifest["ConfigRevision"],
                    "ExpiresAtUtc": (self.b.now() + dt.timedelta(hours=1)).isoformat(timespec="seconds").replace("+00:00", "Z"),
                    "Changes": changes, "RequiredDependency": "openssl", "OpenSSLAvailable": self.crypto.available()}
            data["ChangeDigest"] = hashlib.sha256(compact(data).encode("utf-8")).hexdigest()
            self.b.write_json(DIRECTORY + "/plans/" + data["PlanId"] + ".json", data)
            return data

    def metadata_transaction(self, action, changes):
        tx = {"SchemaVersion": 2, "Kind": "TradeChannel.ManagementTransaction", "TransactionId": str(uuid.uuid4()),
              "Action": action, "Phase": "Pending", "Files": changes}
        require(len(self.b.dumps(tx).encode("utf-8")) <= 4 * 1024 * 1024, "JournalCapacity", "Management metadata exceeds the bounded recovery budget; no metadata was changed.")
        self.b.fs.cas(PENDING, None, self.b.dumps(tx))
        try:
            for path, versions in changes.items(): self.b.fs.cas(path, versions["Before"], versions["After"])
            tx["Phase"] = "Committed"
            self.b.write_json(PENDING, tx)
            self.archive_metadata(tx)
        except Exception:
            # A durable barrier remains. Explicit recover safely finishes exact
            # staged metadata; do not mutate running v1 resources on this path.
            raise ManagementError("NeedsRecovery", "Management metadata outcome requires recovery; no additional change is permitted.", TransactionId=tx["TransactionId"]) from None

    def archive_metadata(self, tx):
        path = ROOT + "/transactions/" + self.guid(tx["TransactionId"]) + ".json"
        existing = self.b.fs.read(path)
        require(existing in (None, self.b.dumps(tx)), "OwnershipMismatch", "Management audit archive changed.")
        self.b.fs.cas(path, existing, self.b.dumps(tx))
        self.b.fs.cas(PENDING, self.b.dumps(tx), None)

    def management_apply(self, value):
        schema(value, ("PlanId", "ApprovedChangeDigest"))
        self.guid(value["PlanId"])
        require(isinstance(value["ApprovedChangeDigest"], str) and re.fullmatch(r"[0-9a-f]{64}", value["ApprovedChangeDigest"]))
        env, owner, manifest, plan = self.context()
        with self.b.fs.lock():
            owner, manifest, plan = self.locked_context(env)
            self.b.no_transaction()
            self.b.verify(plan, manifest, env)
            approved = self.b.read_json(DIRECTORY + "/plans/" + value["PlanId"] + ".json")
            require(isinstance(approved, dict) and approved.get("PlanId") == value["PlanId"] and approved.get("ServerBinding") == self.binding(owner, manifest)
                    and approved.get("ChangeDigest") == value["ApprovedChangeDigest"], "ApprovalMismatch", "The approval does not match this server management plan.")
            unsigned = {k: v for k, v in approved.items() if k != "ChangeDigest"}
            require(hashlib.sha256(compact(unsigned).encode("utf-8")).hexdigest() == approved["ChangeDigest"], "ApprovalMismatch", "Stored plan content changed.")
            current = self.load(owner, manifest, False)
            if current:
                _, public = self.signing()
                return dict(self.public_state(current), Status="Enabled", ManagementSigningPublicKey=public)
            require(self.time(approved["ExpiresAtUtc"]) > self.b.now(), "PlanExpired", "The management plan expired; refresh and approve a new plan.")
            require(approved["ConfigRevision"] == manifest["ConfigRevision"], "RevisionConflict", "The server changed after the management plan was prepared.")
            require(self.crypto.available(), "MissingManagementDependency", "Install the distribution openssl package before applying management capabilities.")
            require(self.b.fs.read(PRIVATE_KEY) is None and self.b.fs.read(PUBLIC_KEY) is None, "ManagementIdentityMismatch", "Partial management identity requires recovery, not replacement.")
            private, public = self.crypto.generate()
            devices = {p["DeviceId"]: {"Name": "Device " + p["DeviceId"][:8], "AuthorizedAtUtc": None, "RevokedAtUtc": None,
                                      "Source": "Legacy"} for p in manifest["Peers"] + manifest["Revoked"]}
            state = {"SchemaVersion": 2, "Kind": "TradeChannel.ManagementState", "ServerBinding": self.binding(owner, manifest),
                     "ManagementRevision": 1, "Devices": devices, "Invites": {}, "Audit": [{"Action": "ManagementUpgrade", "AtUtc": self.at()}]}
            self.metadata_transaction("management_apply", {PRIVATE_KEY: {"Before": None, "After": private},
                                        PUBLIC_KEY: {"Before": None, "After": self.b.dumps(public)}, STATE: {"Before": None, "After": self.b.dumps(state)}})
            return dict(self.public_state(state), Status="Enabled", ManagementSigningPublicKey=public, RunningConfigurationChanged=False)

    def recover_metadata(self):
        tx = self.b.read_json(PENDING)
        require(isinstance(tx, dict) and tx.get("SchemaVersion") == 2 and tx.get("Kind") == "TradeChannel.ManagementTransaction"
                and tx.get("Phase") in ("Pending", "Committed"), "InvalidJournal", "Management journal is invalid.")
        changes = tx.get("Files", {})
        require(isinstance(changes, dict), "InvalidJournal")
        action = tx.get("Action")
        if action == "authorization_refresh":
            require(len(changes) == 1, "InvalidJournal")
            path = next(iter(changes))
            require(isinstance(path, str) and path.startswith(DIRECTORY + "/requests/") and path.endswith(".json"), "InvalidJournal")
            request_id = self.guid(path[len(DIRECTORY + "/requests/"):-5])
            before, after = (self.b.parse_json(changes[path][label]) for label in ("Before", "After"))
            require(before.get("RequestId") == after.get("RequestId") == request_id
                    and all(before[k] == after[k] for k in ("SchemaVersion", "Kind", "RequestDigest", "InviteId", "DeviceId", "PairRequestHash", "RecipientJwk")), "InvalidJournal", "Authorization refresh changed its identity.")
        else:
            require(action in ("management_apply", "invite_create", "invite_cancel", "device_rename")
                    and set(changes) == ({STATE, PRIVATE_KEY, PUBLIC_KEY} if action == "management_apply" else {STATE}), "InvalidJournal", "Management journal contains unexpected paths.")
            staged = self.b.parse_json(changes[STATE]["After"])
            env, owner, manifest, _ = self.context(False)
            require(staged.get("ServerBinding") == self.binding(owner, manifest), "ManagementIdentityMismatch", "Staged management state belongs to another server.")
            if action == "management_apply":
                require(all(v["Before"] is None for v in changes.values()), "InvalidJournal")
                public = self.b.parse_json(changes[PUBLIC_KEY]["After"])
                require(self.crypto.public(changes[PRIVATE_KEY]["After"]) == public, "ManagementIdentityMismatch", "Staged management keys do not match.")
            else:
                prior = self.b.parse_json(changes[STATE]["Before"])
                require(prior["ServerBinding"] == staged["ServerBinding"] and staged["ManagementRevision"] == prior["ManagementRevision"] + 1, "InvalidJournal")
        for path, versions in changes.items():
            schema(versions, ("Before", "After"))
            current = self.b.fs.read(path)
            require(current in (versions["Before"], versions["After"]), "OwnershipMismatch", "Management metadata changed outside its transaction.")
        for path, versions in changes.items(): self.b.fs.cas(path, self.b.fs.read(path), versions["After"])
        env, owner, manifest, _ = self.context(False)
        self.load(owner, manifest)
        self.signing()
        tx["Phase"] = "Committed"
        self.b.write_json(PENDING, tx)
        self.archive_metadata(tx)
        return {"Status": "Recovered", "Outcome": "ManagementCommitPreserved", "RunningConfigurationChanged": False}

    def invite_view(self, invite):
        state = invite["State"]
        if state == "Open" and self.time(invite["ExpiresAtUtc"]) <= self.b.now(): state = "Expired"
        return {"InviteId": invite["InviteId"], "State": state, "DeviceName": invite["DeviceName"],
                "IssuedAtUtc": invite["IssuedAtUtc"], "ExpiresAtUtc": invite["ExpiresAtUtc"],
                "RequestId": invite.get("RequestId"), "ConsumedAtUtc": invite.get("ConsumedAtUtc"), "CancelledAtUtc": invite.get("CancelledAtUtc")}

    def invite_create(self, value):
        schema(value, (), ("DeviceName", "ExpiresInHours", "InviteId"))
        name, hours = self.name(value.get("DeviceName", "New computer")), value.get("ExpiresInHours", 24)
        require(type(hours) is int and 1 <= hours <= 168)
        invitation_id = self.guid(value["InviteId"]) if "InviteId" in value else str(uuid.uuid4())
        input_digest = hashlib.sha256(compact({"DeviceName": name, "ExpiresInHours": hours}).encode("utf-8")).hexdigest()
        env, owner, manifest, plan = self.context()
        with self.b.fs.lock():
            owner, manifest, plan = self.locked_context(env)
            self.b.no_transaction()
            self.b.verify(plan, manifest, env)
            before = self.load(owner, manifest)
            private, public = self.signing()
            existing = before["Invites"].get(invitation_id)
            if existing:
                require(existing.get("InputDigest") == input_digest, "InviteIdConflict", "The invitation ID already belongs to different creation parameters.")
                return dict(self.invite_view(existing), Invite=existing["Invite"], ServerBinding=self.binding(owner, manifest))
            require(len(before["Invites"]) < 512, "InviteLimit", "Invitation history limit reached; export records before management maintenance.")
            binding = self.binding(owner, manifest)
            body = {"SchemaVersion": 1, "Kind": "TradeChannel.PairInvite", "InviteId": invitation_id,
                    **binding, "ServerBinding": binding, "ManagementSigningPublicKey": public, "PublicEndpoint": plan["PublicEndpoint"],
                    "IssuedAtUtc": self.at(), "ExpiresAtUtc": (self.b.now() + dt.timedelta(hours=hours)).isoformat(timespec="seconds").replace("+00:00", "Z"),
                    "Capabilities": {"PairingVersion": 1, "ManagementApiVersion": 2, "Transport": "tcp-reality" if plan.get("Transport") else "udp"}}
            signed = sign_jws(self.crypto, private, body)
            after = copy.deepcopy(before)
            invitation = {k: body[k] for k in ("InviteId", "IssuedAtUtc", "ExpiresAtUtc")}
            invitation.update(State="Open", DeviceName=name, Invite=signed, InputDigest=input_digest)
            after["Invites"][body["InviteId"]] = invitation
            self.audit(after, "InviteCreated", InviteId=body["InviteId"])
            self.metadata_transaction("invite_create", {STATE: {"Before": self.b.dumps(before), "After": self.b.dumps(after)}})
            return dict(self.invite_view(invitation), Invite=signed, ServerBinding=binding)

    def invite_status(self, value):
        schema(value, ("InviteId",))
        invitation_id = self.guid(value["InviteId"])
        env, owner, manifest, _ = self.context(False)
        with self.b.fs.lock(readonly=True):
            owner, manifest, _ = self.locked_context(env, False)
            state = self.load(owner, manifest)
            invitation = state["Invites"].get(invitation_id)
            require(invitation is not None, "InviteNotFound", "This invitation does not exist on this server.")
            return dict(self.invite_view(invitation), Invite=invitation["Invite"], ServerBinding=self.binding(owner, manifest),
                        ManagementRevision=state["ManagementRevision"], PendingOperation=bool(self.b.fs.read(ROOT + "/active.json") or self.b.fs.read(PENDING)))

    def invite_cancel(self, value):
        schema(value, ("InviteId",))
        invitation_id = self.guid(value["InviteId"])
        env, owner, manifest, _ = self.context()
        with self.b.fs.lock():
            owner, manifest, _ = self.locked_context(env)
            self.b.no_transaction()
            before = self.load(owner, manifest)
            invitation = before["Invites"].get(invitation_id)
            require(invitation is not None, "InviteNotFound", "The invitation does not exist.")
            require(invitation["State"] != "Consumed", "InviteConsumed", "An already consumed invitation cannot be cancelled; revoke its device instead.")
            if invitation["State"] == "Cancelled": return self.invite_view(invitation)
            after = copy.deepcopy(before)
            after["Invites"][invitation_id].update(State="Cancelled", CancelledAtUtc=self.at())
            self.audit(after, "InviteCancelled", InviteId=invitation_id)
            self.metadata_transaction("invite_cancel", {STATE: {"Before": self.b.dumps(before), "After": self.b.dumps(after)}})
            return self.invite_view(after["Invites"][invitation_id])

    def pair_request(self, value, invitation_id, binding):
        body, message, signature = decode_jws(value)
        schema(body, ("SchemaVersion", "Kind", "InviteId", "ServerBinding", "ClientRequest", "DeviceName", "RecipientJwk", "RequestDigest", "RequestDigestAlgorithm", "CreatedAtUtc"))
        require(type(body["SchemaVersion"]) is int and body["SchemaVersion"] == 1 and body["Kind"] == "TradeChannel.PairRequest")
        require(body["InviteId"] == invitation_id and body["ServerBinding"] == binding, "ServerBindingMismatch", "The pairing request targets another invitation or server.")
        self.name(body["DeviceName"])
        self.time(body["CreatedAtUtc"])
        require(self.time(body["CreatedAtUtc"]) <= self.b.now() + dt.timedelta(minutes=5), "InvalidPairRequestTime", "Pairing request time is in the future.")
        request = self.b.validate_client_request(body["ClientRequest"])
        require(body["RequestDigestAlgorithm"] == DIGEST_ALGORITHM and body["RequestDigest"] == request_digest(request), "RequestDigestMismatch", "The request digest does not match the exact client identity.")
        validate_jwk(body["RecipientJwk"])
        require(self.crypto.verify(body["RecipientJwk"], message, signature), "InvalidSignature", "The pairing request signature is invalid.")
        return body

    def peer_transition(self, action, before, after, peer, owner):
        state = self.load(owner, before, False)
        if not state: return {}
        updated = copy.deepcopy(state)
        meta = updated["Devices"].setdefault(peer["DeviceId"], {"Name": "Device " + peer["DeviceId"][:8], "AuthorizedAtUtc": None, "RevokedAtUtc": None, "Source": "Legacy"})
        if action == "authorize": meta.update(AuthorizedAtUtc=self.at(), Source="LocalManagement")
        else: meta["RevokedAtUtc"] = self.at()
        self.audit(updated, "DeviceAuthorized" if action == "authorize" else "DeviceRevoked", DeviceId=peer["DeviceId"])
        return {STATE: {"Before": self.b.dumps(state), "After": self.b.dumps(updated)}}

    def exit_trace(self, owner, manifest):
        """Bounded, readonly status BEFORE the mutation lock; never infer egress from an endpoint.

        status() verifies the installed node and uses certificate-verified direct HTTPS.
        Capture/relay options remain absent: no listener, restart, peer or route change.
        Missing/failed/disagreeing evidence is a normal v1 fallback, not a signing error.
        """
        try:
            result = self.b.status({"NetworkProbe": True, "ProbeRepeats": 2})
            node, report = result.get("Node", {}), result.get("NetworkProbe", {})
            if (result.get("Status") != "Applied" or node.get("NodeId") != manifest["NodeId"]
                    or node.get("ServerPublicKey") != manifest["ServerPublicKey"]
                    or report.get("ReadOnly") is not True or report.get("ProbeRepeats") != 2):
                return None
            rows = report.get("ServerHttps", [])
            if not isinstance(rows, list) or len(rows) != 2:
                return None
            addresses = []
            for row in rows:
                if (not isinstance(row, dict) or row.get("ExitEvidence") != "VerifiedTlsTrace"
                        or row.get("Ok") is not True or row.get("TlsVerified") is not True
                        or row.get("TcpConnected") is not True or row.get("ProxyUsed") is not False
                        or row.get("Target") != EXIT_TRACE_TARGET
                        or type(row.get("HttpStatus")) is not int or not 200 <= row["HttpStatus"] < 300):
                    return None
                address = ipaddress.IPv4Address(row.get("ObservedExitIPv4"))
                if not address.is_global or address.is_multicast or address.is_reserved:
                    return None
                addresses.append(str(address))
            if len(set(addresses)) != 1:
                return None
            return {"ServerBinding": self.binding(owner, manifest), "ObservedExitIPv4": addresses[0],
                    "ObservedAtUtc": self.at(), "VerifiedSampleCount": len(addresses)}
        except Exception:
            # No trace response body, certificate exception, private state or raw failure is exported.
            return None

    def grant_exit_evidence(self, trace, authorization):
        """Project only a fresh real trace, bound to this exact authorization/identity tuple."""
        if (not trace or trace["ServerBinding"] != authorization["ServerBinding"]
                or self.time(trace["ObservedAtUtc"]) > self.time(authorization["IssuedAtUtc"])):
            return None
        expires = min(self.time(trace["ObservedAtUtc"]) + EXIT_EVIDENCE_LIFETIME,
                      self.time(authorization["ExpiresAtUtc"]))
        if expires <= self.b.now():
            return None
        return {"SchemaVersion": 1, "Kind": "TradeChannel.ServerExitEvidence", "Source": "ServerVerifiedTlsTrace",
                "ServerBinding": copy.deepcopy(authorization["ServerBinding"]), "InviteId": authorization["InviteId"],
                "RequestId": authorization["RequestId"], "RequestDigest": authorization["RequestDigest"],
                "RequestDigestAlgorithm": DIGEST_ALGORITHM, "DeviceId": authorization["DeviceId"],
                "ClientPublicKey": authorization["ClientPublicKey"], "ObservedExitIPv4": trace["ObservedExitIPv4"],
                "ObservedAtUtc": trace["ObservedAtUtc"], "ExpiresAtUtc": expires.isoformat(timespec="seconds").replace("+00:00", "Z"),
                "ProbeTarget": EXIT_TRACE_TARGET, "VerifiedSampleCount": trace["VerifiedSampleCount"]}

    def version_grant(self, authorization, trace):
        # The v1 whitelist stays exact: the optional evidence exists only on an explicitly v2 body.
        authorization.pop("ExitEvidence", None)
        authorization["SchemaVersion"] = 1
        evidence = self.grant_exit_evidence(trace, authorization)
        if evidence:
            authorization.update(SchemaVersion=2, ExitEvidence=evidence)
        return authorization

    def authorize_external(self, value):
        schema(value, ("InviteId", "PairRequest"))
        invitation_id = self.guid(value["InviteId"])
        env, owner, manifest, plan = self.context()
        # This unlocked snapshot only avoids probing an already consumed invitation.
        # Every authorization/consumption decision is still repeated under the mutation lock.
        invitation_snapshot = self.load(owner, manifest)["Invites"].get(invitation_id)
        trace = self.exit_trace(owner, manifest) if invitation_snapshot and invitation_snapshot.get("State") == "Open" else None
        with self.b.fs.lock():
            owner, manifest, plan = self.locked_context(env)
            self.b.no_transaction()
            before = self.load(owner, manifest)
            invitation = before["Invites"].get(invitation_id)
            require(invitation is not None, "InviteNotFound", "The invitation does not exist on this server.")
            body = self.pair_request(value["PairRequest"], invitation_id, self.binding(owner, manifest))
            request = body["ClientRequest"]
            filename = DIRECTORY + "/requests/" + self.guid(request["RequestId"]) + ".json"
            registered = self.b.read_json(filename)
            if invitation["State"] == "Consumed":
                require(invitation.get("RequestId") == request["RequestId"] and invitation.get("RequestDigest") == body["RequestDigest"]
                        and registered and registered.get("PairRequestHash") == hashlib.sha256(value["PairRequest"].encode("ascii")).hexdigest(),
                        "InviteConsumed", "The invitation is consumed by a different request.")
                return self.request_status_locked(request["RequestId"], body["RequestDigest"], owner, manifest, plan)
            require(invitation["State"] == "Open" and self.time(invitation["ExpiresAtUtc"]) > self.b.now(), "InviteUnavailable", "The invitation is cancelled, expired or already consumed.")
            require(registered is None, "AuthorizationConflict", "This request is already registered through another invitation.")
            private, _ = self.signing()
            result = {}
            def builder(plan, before_manifest, after_manifest, peer):
                state = copy.deepcopy(before)
                state["Invites"][invitation_id].update(State="Consumed", RequestId=request["RequestId"], RequestDigest=body["RequestDigest"], ConsumedAtUtc=self.at())
                state["Devices"][peer["DeviceId"]] = {"Name": body["DeviceName"], "AuthorizedAtUtc": self.at(), "RevokedAtUtc": None, "Source": "Pairing", "InviteId": invitation_id}
                self.audit(state, "ExternalDeviceAuthorized", DeviceId=peer["DeviceId"], InviteId=invitation_id)
                response = self.b.make_client_response(plan, after_manifest, peer)
                authorization = {"SchemaVersion": 1, "Kind": "TradeChannel.PairAuthorization", "InviteId": invitation_id,
                    "ServerBinding": self.binding(owner, after_manifest), "RemoteOwnerId": owner["OwnerId"], "NodeId": plan["NodeId"],
                    "RequestId": request["RequestId"], "RequestDigest": body["RequestDigest"], "RequestDigestAlgorithm": DIGEST_ALGORITHM,
                    "DeviceId": peer["DeviceId"], "ClientPublicKey": peer["ClientPublicKey"], "ClientAddress": peer["ClientAddress"],
                    "ConfigRevision": after_manifest["ConfigRevision"], "ClientResponse": response, "IssuedAtUtc": self.at(),
                    "ExpiresAtUtc": (self.b.now() + dt.timedelta(days=7)).isoformat(timespec="seconds").replace("+00:00", "Z")}
                self.version_grant(authorization, trace)
                signed = sign_jws(self.crypto, private, authorization)
                saved = {"SchemaVersion": 1, "Kind": "TradeChannel.PairAuthorizationRecord", "RequestId": request["RequestId"],
                         "RequestDigest": body["RequestDigest"], "InviteId": invitation_id, "DeviceId": peer["DeviceId"],
                         "PairRequestHash": hashlib.sha256(value["PairRequest"].encode("ascii")).hexdigest(), "Authorization": signed,
                         "ClientResponse": response, "AuthorizationBody": authorization, "RecipientJwk": body["RecipientJwk"]}
                result.update(Status="Authorized", Authorization=signed, ClientResponse=response, Node=self.b.node(plan, after_manifest),
                              RequestId=request["RequestId"], RequestDigest=body["RequestDigest"])
                return {STATE: {"Before": self.b.dumps(before), "After": self.b.dumps(state)}, filename: {"Before": None, "After": self.b.dumps(saved)}}
            self.b.change_peers("authorize", request, None, management_builder=builder, lock_held=True)
            require(result, "AuthorizationConflict", "This device was authorized outside this invitation; request a new invitation or reconcile the prior authorization.")
            return result

    def request_status_locked(self, request_id, expected_digest, owner, manifest, plan):
        if self.b.fs.read(ROOT + "/active.json") or self.b.fs.read(PENDING):
            return {"Status": "OutcomeUnknown", "RequestId": request_id, "UserActions": ["Recover", "QueryAgain"]}
        active = next((p for p in manifest["Peers"] if p["RequestId"] == request_id), None)
        revoked = next((p for p in manifest["Revoked"] if p["RequestId"] == request_id), None)
        peer = active or revoked
        if peer is None: return {"Status": "NotFound", "RequestId": request_id}
        actual_digest = request_digest(peer["Request"])
        require(expected_digest is None or expected_digest == actual_digest, "RequestDigestMismatch", "The stored request does not match this digest.")
        result = {"Status": "Authorized" if active and manifest["Status"] == "Applied" else "Revoked", "RequestId": request_id,
                  "RequestDigest": actual_digest, "DeviceId": peer["DeviceId"], "Node": self.b.node(plan, manifest)}
        if result["Status"] == "Authorized":
            saved = self.b.read_json(DIRECTORY + "/requests/" + request_id + ".json")
            if saved:
                require(saved.get("RequestDigest") == actual_digest and saved.get("DeviceId") == peer["DeviceId"], "InvalidManagementState", "Stored authorization no longer matches its device.")
                result.update(Authorization=saved["Authorization"], ClientResponse=saved["ClientResponse"])
            else: result["ClientResponse"] = self.b.make_client_response(plan, manifest, peer)
        return result

    def request_status(self, value):
        schema(value, ("RequestId",), ("RequestDigest", "IncludeTelemetry", "RefreshAuthorization"))
        request_id = self.guid(value["RequestId"])
        expected = value.get("RequestDigest")
        require(expected is None or isinstance(expected, str) and re.fullmatch(r"[0-9a-f]{64}", expected))
        telemetry = value.get("IncludeTelemetry", False)
        refresh = value.get("RefreshAuthorization", False)
        require(type(telemetry) is bool and type(refresh) is bool)
        env, owner, manifest, plan = self.context(False)
        trace = self.exit_trace(owner, manifest) if refresh else None
        with self.b.fs.lock(readonly=not refresh):
            owner, manifest, plan = self.locked_context(env, False)
            result = self.request_status_locked(request_id, expected, owner, manifest, plan)
            if result["Status"] == "Authorized":
                peer = next(p for p in manifest["Peers"] if p["RequestId"] == request_id)
                result["ClientPublicKey"] = peer["ClientPublicKey"]
                if refresh and "Authorization" in result:
                    self.b.no_transaction()
                    self.b.verify(plan, manifest, env)
                    private, _ = self.signing()
                    path = DIRECTORY + "/requests/" + request_id + ".json"
                    before = self.b.read_json(path)
                    after = copy.deepcopy(before)
                    body = after["AuthorizationBody"]
                    body.update(ClientResponse=self.b.make_client_response(plan, manifest, peer), ConfigRevision=manifest["ConfigRevision"],
                                IssuedAtUtc=self.at(), ExpiresAtUtc=(self.b.now() + dt.timedelta(days=7)).isoformat(timespec="seconds").replace("+00:00", "Z"))
                    self.version_grant(body, trace)
                    after.update(Authorization=sign_jws(self.crypto, private, body), ClientResponse=body["ClientResponse"])
                    self.metadata_transaction("authorization_refresh", {path: {"Before": self.b.dumps(before), "After": self.b.dumps(after)}})
                    result.update(Authorization=after["Authorization"], ClientResponse=after["ClientResponse"])
                if telemetry:
                    self.b.verify(plan, manifest)
                    row = next(r for r in self.b.os.peer_telemetry(plan, manifest) if r["DeviceId"] == peer["DeviceId"])
                    result["Telemetry"] = dict(row, ClientPublicKey=peer["ClientPublicKey"], Source="OwnedWireGuardKernel")
            return result

    def device_rename(self, value):
        schema(value, ("DeviceId", "Name"), ("ExpectedConfigRevision",))
        device_id, name = self.guid(value["DeviceId"]), self.name(value["Name"])
        env, owner, manifest, _ = self.context(False)
        with self.b.fs.lock():
            owner, manifest, _ = self.locked_context(env, False)
            self.b.no_transaction()
            require(value.get("ExpectedConfigRevision", manifest["ConfigRevision"]) == manifest["ConfigRevision"], "RevisionConflict", "Device configuration changed; refresh before renaming.")
            require(any(p["DeviceId"] == device_id for p in manifest["Peers"] + manifest["Revoked"]), "DeviceNotFound", "The device is not registered.")
            before = self.load(owner, manifest)
            if before["Devices"][device_id]["Name"] == name: return {"DeviceId": device_id, "Name": name, "ConfigRevision": manifest["ConfigRevision"], "ManagementRevision": before["ManagementRevision"]}
            after = copy.deepcopy(before)
            after["Devices"][device_id]["Name"] = name
            self.audit(after, "DeviceRenamed", DeviceId=device_id)
            self.metadata_transaction("device_rename", {STATE: {"Before": self.b.dumps(before), "After": self.b.dumps(after)}})
            return {"DeviceId": device_id, "Name": name, "ConfigRevision": manifest["ConfigRevision"], "ManagementRevision": after["ManagementRevision"]}

    def preview(self, action, device_id=None):
        env, owner, manifest, plan = self.context(False)
        self.b.no_transaction()
        if manifest["Status"] == "Applied": self.b.verify(plan, manifest, env)
        if device_id:
            peer = next((p for p in manifest["Peers"] + manifest["Revoked"] if p["DeviceId"] == device_id), None)
            require(peer is not None, "DeviceNotFound", "The device is not registered.")
        body = {"Action": action, "ServerBinding": self.binding(owner, manifest), "ConfigRevision": manifest["ConfigRevision"],
                "DeviceId": device_id, "AffectedDeviceIds": [device_id] if device_id else [p["DeviceId"] for p in manifest["Peers"]],
                "SharedTcpAuthentication": bool(plan.get("Transport")), "CloudServerReleased": False,
                "PackagesRetained": action == "uninstall", "IdentityAndAuditRetained": True}
        body["ChangeDigest"] = hashlib.sha256(compact(body).encode("utf-8")).hexdigest()
        body["Warnings"] = (["Shared TCP outer UUID remains valid; only this device's WireGuard authorization is revoked."] if device_id and plan.get("Transport") else [])
        if action == "uninstall": body["Warnings"].append("Uninstall interrupts all listed devices; cloud server resources and billing continue.")
        return body

    def revoke_preview(self, value):
        schema(value, ("DeviceId",))
        device_id = self.guid(value["DeviceId"])
        with self.b.fs.lock(readonly=True): return self.preview("revoke", device_id)

    def uninstall_preview(self, value):
        schema(value, ())
        with self.b.fs.lock(readonly=True): return self.preview("uninstall")

    def verify_approval(self, action, value, manifest, owner, plan):
        revision, approved = value.get("ExpectedConfigRevision"), value.get("ApprovedChangeDigest")
        require(revision is None or type(revision) is int and revision == manifest["ConfigRevision"], "RevisionConflict", "Configuration changed after the maintenance preview.")
        if approved is not None:
            preview = self.preview(action, value.get("DeviceId"))
            require(isinstance(approved, str) and approved == preview["ChangeDigest"], "ApprovalMismatch", "The approval does not match the exact maintenance target and revision.")

    def validate_peer_journal(self, tx, plan):
        """Only explicitly enumerated sidecar paths may augment peer journals."""
        extra = tx.get("ManagementFiles", {}) or {p: tx["Files"][p] for p in tx.get("ManagementPaths", [])}
        require(type(tx.get("SchemaVersion")) is int and tx["SchemaVersion"] == 2 and isinstance(extra, dict) and STATE in extra,
                "InvalidJournal", "Invalid v2 management peer journal.")
        require(set(extra) <= {STATE, DIRECTORY + "/requests/" + self.guid(tx["After"]["Peers"][-1]["RequestId"]) + ".json"}
                if tx["Action"] in ("authorize", "authorize_external", "authorize_v2") else set(extra) == {STATE}, "InvalidJournal", "Management journal contains an unexpected path.")
        for path, versions in extra.items():
            schema(versions, ("Before", "After"))
            require(isinstance(versions["After"], str) and (versions["Before"] is None or isinstance(versions["Before"], str)), "InvalidJournal")
            require(tx["Files"].get(path) == versions, "InvalidJournal", "Management backups changed.")
        before = self.b.parse_json(extra[STATE]["Before"])
        after = self.b.parse_json(extra[STATE]["After"])
        require(before["ServerBinding"] == after["ServerBinding"] and before["ServerBinding"]["NodeId"] == plan["NodeId"]
                and after["ManagementRevision"] == before["ManagementRevision"] + 1, "InvalidJournal", "Management transition does not match the node.")
