"""Management/pairing transactions with a fake kernel and real RSA signatures.

No SSH target, route, DNS, adapter, proxy or real service is used. cryptography
is a TEST-ONLY independent verifier; Linux runtime uses distribution OpenSSL.
"""
import base64
import copy
import datetime as dt
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import unittest
from unittest import mock

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa
from cryptography.exceptions import InvalidSignature

spec = importlib.util.spec_from_file_location("management_fixture_base", Path(__file__).with_name("test_linux_server.py"))
base = importlib.util.module_from_spec(spec); spec.loader.exec_module(base)
tc, mg = base.tc, base.tc.management


class FixtureCrypto:
    def __init__(self, private): self.key = private
    def available(self): return True
    def generate(self):
        private = self.key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()).decode("ascii")
        return private, self.public(private)
    def public(self, private):
        key = serialization.load_pem_private_key(private.encode("ascii"), password=None).public_key().public_numbers()
        return {"kty": "RSA", "n": mg.b64(key.n.to_bytes(384, "big")), "e": mg.b64(key.e.to_bytes(3, "big"))}
    def sign(self, private, data):
        key = serialization.load_pem_private_key(private.encode("ascii"), password=None)
        return key.sign(data, padding.PKCS1v15(), hashes.SHA256())
    def verify(self, jwk, data, signature):
        try:
            key = rsa.RSAPublicNumbers(int.from_bytes(mg.unb64(jwk["e"]), "big"), int.from_bytes(mg.unb64(jwk["n"]), "big")).public_key()
            key.verify(signature, data, padding.PKCS1v15(), hashes.SHA256())
            return True
        except (InvalidSignature, ValueError): return False


class ManagementTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.signer = rsa.generate_private_key(public_exponent=65537, key_size=3072)
        cls.recipient = rsa.generate_private_key(public_exponent=65537, key_size=3072)
        cls.crypto = FixtureCrypto(cls.signer)
        cls.recipient_crypto = FixtureCrypto(cls.recipient)
        cls.recipient_pem, cls.recipient_jwk = cls.recipient_crypto.generate()

    def setUp(self):
        self.fs, self.time = base.MemoryFS(), dt.datetime(2026, 10, 8, 2, tzinfo=dt.timezone.utc)
        self.os = base.FakeOS(self.fs)
        self.b = tc.Backend(self.fs, self.os, now=lambda: self.time, management_crypto=self.crypto, progress=lambda _: None)
        p = self.b.plan(base.plan_input())
        self.b.apply({"PlanId": p["PlanId"]})
        self.plan = self.b.load_plan(p["PlanId"], self.os.probe())

    def call(self, action, value=None, code=None):
        result = tc.envelope(action, value or {}, self.b)
        if code:
            self.assertFalse(result["Ok"], result)
            self.assertEqual(result["Data"]["Code"], code, result)
        else: self.assertTrue(result["Ok"], result)
        return result["Data"]

    def upgrade(self):
        plan = self.call("management_plan")
        self.call("management_apply", {"PlanId": plan["PlanId"], "ApprovedChangeDigest": plan["ChangeDigest"]})
        return plan

    def invite(self):
        self.upgrade()
        return self.call("invite_create", {"DeviceName": "New desktop"})

    def pair(self, invitation, number=2, update=None, header=None):
        request = base.request(number)
        body = {"SchemaVersion": 1, "Kind": "TradeChannel.PairRequest", "InviteId": invitation["InviteId"],
                "ServerBinding": invitation["ServerBinding"], "ClientRequest": request, "DeviceName": "Second computer",
                "RecipientJwk": copy.deepcopy(self.recipient_jwk), "RequestDigest": mg.request_digest(request),
                "RequestDigestAlgorithm": mg.DIGEST_ALGORITHM, "CreatedAtUtc": self.time.isoformat().replace("+00:00", "Z")}
        if update: update(body)
        if header is None:
            signed = mg.sign_jws(self.recipient_crypto, self.recipient_pem, body)
        else:
            first, second = mg.b64(mg.compact(header).encode()), mg.b64(mg.compact(body).encode())
            signature = self.recipient_crypto.sign(self.recipient_pem, (first + "." + second).encode("ascii"))
            signed = first + "." + second + "." + mg.b64(signature)
        return {"InviteId": invitation["InviteId"], "PairRequest": signed}, body

    def test_query_catalog_never_mutates_or_captures(self):
        before, calls = copy.deepcopy(self.fs.files), list(self.os.calls)
        with mock.patch.object(self.os, "network_probe", create=True, side_effect=AssertionError("capture forbidden")):
            self.assertEqual(self.call("capabilities")["ManagementApiVersion"], 1)
            self.assertEqual(self.call("server_info")["OwnershipState"], "Applied")
            rows = self.call("devices")["Devices"]
        self.assertEqual(len(rows), 1)
        self.assertIsNone(rows[0]["AuthorizedAtUtc"])
        self.assertEqual(rows[0]["TimeEvidence"], "Unknown")
        self.assertEqual(self.fs.files, before)
        self.assertTrue(all(c == ["wg", "pubkey"] for c in self.os.calls[len(calls):]))

    def test_upgrade_preserves_keys_peers_runtime_and_is_retry_stable(self):
        files, calls = copy.deepcopy(self.fs.files), list(self.os.calls)
        plan = self.upgrade()
        self.assertTrue(all(c == ["wg", "pubkey"] for c in self.os.calls[len(calls):]))
        for path, text in files.items(): self.assertEqual(self.fs.files[path], text, path)
        private, info = self.fs.files[mg.PRIVATE_KEY], self.call("server_info")
        result = self.call("management_apply", {"PlanId": plan["PlanId"], "ApprovedChangeDigest": plan["ChangeDigest"]})
        self.assertEqual(self.fs.files[mg.PRIVATE_KEY], private)
        self.assertEqual(result["ManagementSigningPublicKey"], info["ManagementSigningPublicKey"])
        self.assertEqual(self.call("capabilities")["ManagementApiVersion"], 2)
        self.assertIsNone(self.call("devices")["Devices"][0]["AuthorizedAtUtc"])

    def test_upgrade_requires_exact_approval_and_valid_revision(self):
        p = self.call("management_plan")
        self.call("management_apply", {"PlanId": p["PlanId"], "ApprovedChangeDigest": "0" * 64}, "ApprovalMismatch")
        self.b.authorize({"ClientRequest": base.request(2)})
        self.call("management_apply", {"PlanId": p["PlanId"], "ApprovedChangeDigest": p["ChangeDigest"]}, "RevisionConflict")
        self.assertIsNone(self.fs.read(mg.PRIVATE_KEY))

    def test_expired_management_plan_has_no_key_effect(self):
        p = self.call("management_plan"); self.time += dt.timedelta(hours=2)
        self.call("management_apply", {"PlanId": p["PlanId"], "ApprovedChangeDigest": p["ChangeDigest"]}, "PlanExpired")
        self.assertIsNone(self.fs.read(mg.PRIVATE_KEY))

    def test_management_absence_proof_is_readonly_and_blocks_delayed_old_apply(self):
        p = self.call("management_plan")
        value = {"PlanId": p["PlanId"], "ApprovedChangeDigest": p["ChangeDigest"]}
        self.time += dt.timedelta(hours=2)
        files, writes, runtime = copy.deepcopy(self.fs.files), list(self.fs.mutations), copy.deepcopy(self.os.running)
        proof = self.call("management_recovery_state", value)
        self.assertEqual(proof["Outcome"], "NotApplied")
        self.assertEqual(proof["ServerBinding"], p["ServerBinding"])
        self.assertEqual(proof["PlanId"], p["PlanId"])
        self.assertEqual(proof["FilesAbsent"], {"State": True, "PrivateKey": True, "PublicKey": True})
        self.assertTrue(proof["PlanExpired"] and proof["ReadOnly"])
        self.assertIn("management_recovery_state", self.call("capabilities")["ReadOnlyActions"])
        self.call("management_apply", value, "PlanExpired")
        self.assertEqual(self.fs.files, files)
        self.assertEqual(self.fs.mutations, writes)
        self.assertEqual(self.os.running, runtime)

    def test_management_absence_proof_requires_original_expired_plan(self):
        p = self.call("management_plan")
        value = {"PlanId": p["PlanId"], "ApprovedChangeDigest": p["ChangeDigest"]}
        self.call("management_recovery_state", value, "ManagementPlanStillValid")
        self.time += dt.timedelta(hours=2)
        before = copy.deepcopy(self.fs.files)
        self.call("management_recovery_state", dict(value, ApprovedChangeDigest="f" * 64), "ApprovalMismatch")
        self.call("management_recovery_state", dict(value, PlanId=str(uuid_value(888))), "ApprovalMismatch")
        self.assertEqual(self.fs.files, before)

    def test_management_absence_proof_rejects_tampered_proposal(self):
        p = self.call("management_plan"); self.time += dt.timedelta(hours=2)
        path = mg.DIRECTORY + "/plans/" + p["PlanId"] + ".json"
        changed = copy.deepcopy(p); changed["Changes"].append("unexpected")
        self.b.write_json(path, changed)
        before = copy.deepcopy(self.fs.files)
        self.call("management_recovery_state", {"PlanId": p["PlanId"], "ApprovedChangeDigest": p["ChangeDigest"]}, "ApprovalMismatch")
        self.assertEqual(self.fs.files, before)

    def test_management_absence_proof_rejects_any_partial_identity(self):
        p = self.call("management_plan"); self.time += dt.timedelta(hours=2)
        for path in (mg.STATE, mg.PRIVATE_KEY, mg.PUBLIC_KEY):
            with self.subTest(path=path):
                self.fs.files[path] = "preserve-this-original-content"
                before = copy.deepcopy(self.fs.files)
                self.call("management_recovery_state", {"PlanId": p["PlanId"], "ApprovedChangeDigest": p["ChangeDigest"]}, "ManagementInitializationPresent")
                self.assertEqual(self.fs.files, before)
                del self.fs.files[path]

    def test_management_absence_proof_rejects_configuration_change(self):
        p = self.call("management_plan")
        self.b.authorize({"ClientRequest": base.request(2)})
        self.time += dt.timedelta(hours=2)
        before = copy.deepcopy(self.fs.files)
        self.call("management_recovery_state", {"PlanId": p["PlanId"], "ApprovedChangeDigest": p["ChangeDigest"]}, "RevisionConflict")
        self.assertEqual(self.fs.files, before)

    def test_management_absence_proof_preserves_pending_transaction(self):
        p = self.call("management_plan"); self.fs.fail_path = mg.STATE
        self.call("management_apply", {"PlanId": p["PlanId"], "ApprovedChangeDigest": p["ChangeDigest"]}, "NeedsRecovery")
        self.time += dt.timedelta(hours=2)
        before = copy.deepcopy(self.fs.files)
        self.call("management_recovery_state", {"PlanId": p["PlanId"], "ApprovedChangeDigest": p["ChangeDigest"]}, "NeedsRecovery")
        self.assertEqual(self.fs.files, before)

    def test_management_absence_proof_allows_new_explicit_plan_without_new_device(self):
        old = self.call("management_plan"); self.time += dt.timedelta(hours=2)
        self.call("management_recovery_state", {"PlanId": old["PlanId"], "ApprovedChangeDigest": old["ChangeDigest"]})
        manifest, runtime = copy.deepcopy(self.b.read_json(tc.MANIFEST)), copy.deepcopy(self.os.running)
        replacement = self.upgrade()
        self.assertNotEqual(replacement["PlanId"], old["PlanId"])
        self.assertEqual(self.b.read_json(tc.MANIFEST), manifest)
        self.assertEqual(self.os.running, runtime)
        self.assertEqual(self.call("devices")["ActiveDeviceCount"], 1)

    def test_deleted_management_files_do_not_erase_archived_identity(self):
        old = self.upgrade(); self.time += dt.timedelta(hours=2)
        for path in (mg.STATE, mg.PRIVATE_KEY, mg.PUBLIC_KEY):
            del self.fs.files[path]
        before = copy.deepcopy(self.fs.files)
        self.call("management_recovery_state", {"PlanId": old["PlanId"], "ApprovedChangeDigest": old["ChangeDigest"]}, "ManagementHistoryPresent")
        self.assertEqual(self.fs.files, before)

    def test_management_write_failure_blocks_legacy_then_recovers_same_identity(self):
        p = self.call("management_plan"); self.fs.fail_path = mg.STATE
        self.call("management_apply", {"PlanId": p["PlanId"], "ApprovedChangeDigest": p["ChangeDigest"]}, "NeedsRecovery")
        partial_key, runtime = self.fs.files[mg.PRIVATE_KEY], copy.deepcopy(self.os.running)
        self.assertEqual(self.call("status")["Status"], "NeedsRecovery")
        self.assertFalse(self.call("inspect")["Supported"])
        self.call("authorize", {"ClientRequest": base.request(2)}, "NeedsRecovery")
        self.assertEqual(self.call("recover")["Outcome"], "ManagementCommitPreserved")
        self.assertEqual(self.fs.files[mg.PRIVATE_KEY], partial_key)
        self.assertEqual(self.os.running, runtime)
        self.assertEqual(self.call("devices")["ActiveDeviceCount"], 1)

    def test_invite_is_signed_and_contains_no_client_or_management_secret(self):
        invitation = self.invite()
        body, message, signature = mg.decode_jws(invitation["Invite"])
        self.assertTrue(self.crypto.verify(body["ManagementSigningPublicKey"], message, signature))
        self.assertEqual(body["Kind"], "TradeChannel.PairInvite")
        self.assertNotIn("PrivateKey", json.dumps(body))
        self.assertNotIn("Uuid", json.dumps(body))
        self.assertEqual(self.call("invite_status", {"InviteId": invitation["InviteId"]})["State"], "Open")

    def test_invite_creation_idempotency_preserves_original_expiry_and_identity(self):
        self.upgrade()
        parameters = {"InviteId": str(uuid_value(900)), "DeviceName": "Laptop", "ExpiresInHours": 24}
        first = self.call("invite_create", parameters)
        self.time += dt.timedelta(hours=6)
        before = copy.deepcopy(self.fs.files)
        retry = self.call("invite_create", parameters)
        self.assertEqual(retry["Invite"], first["Invite"])
        self.assertEqual(retry["IssuedAtUtc"], first["IssuedAtUtc"])
        self.assertEqual(retry["ExpiresAtUtc"], first["ExpiresAtUtc"])
        self.assertEqual(self.fs.files, before)
        self.call("invite_create", dict(parameters, DeviceName="Another computer"), "InviteIdConflict")
        original = self.call("invite_status", {"InviteId": parameters["InviteId"]})
        self.assertEqual(original["Invite"], first["Invite"])

    def test_oversize_management_history_cannot_create_unreadable_recovery_journal(self):
        self.upgrade()
        state = self.b.read_json(mg.STATE)
        state["RetainedMigrationEvidence"] = "x" * (2100 * 1024)
        self.b.write_json(mg.STATE, state)
        before = copy.deepcopy(self.fs.files)
        self.call("invite_create", {}, "JournalCapacity")
        self.assertEqual(self.fs.files, before)
        self.assertIsNone(self.fs.read(mg.PENDING))
        self.call("authorize", {"ClientRequest": base.request(2)}, "JournalCapacity")
        self.assertEqual(self.fs.files, before)
        self.assertIsNone(self.fs.read(tc.ACTIVE))

    def test_external_authorization_returns_original_device_and_server_signature(self):
        invitation = self.invite(); request, body = self.pair(invitation)
        result = self.call("authorize_external", request)
        auth, message, signature = mg.decode_jws(result["Authorization"])
        self.assertTrue(self.crypto.verify(self.call("server_info")["ManagementSigningPublicKey"], message, signature))
        self.assertEqual(auth["ClientResponse"]["DeviceId"], base.request(2)["DeviceId"])
        self.assertEqual(auth["ServerBinding"], invitation["ServerBinding"])
        self.assertEqual(auth["RequestDigest"], body["RequestDigest"])
        self.assertEqual(self.call("devices")["ActiveDeviceCount"], 2)
        self.assertEqual(self.call("invite_status", {"InviteId": invitation["InviteId"]})["State"], "Consumed")
        devices = self.call("devices")["Devices"]
        paired = next(r for r in devices if r["DeviceId"] == base.request(2)["DeviceId"])
        self.assertEqual(paired["Name"], "Second computer")
        self.assertEqual(paired["AuthorizedAtUtc"], "2026-10-08T02:00:00Z")
        self.assertEqual(paired["Source"], "Pairing")

    def test_identical_retry_and_request_status_do_not_add_peer_or_change_revision(self):
        invitation = self.invite(); request, _ = self.pair(invitation)
        first = self.call("authorize_external", request)
        files, calls = copy.deepcopy(self.fs.files), list(self.os.calls)
        retry = self.call("authorize_external", request)
        status = self.call("request_status", {"RequestId": base.request(2)["RequestId"], "RequestDigest": first["RequestDigest"]})
        self.assertEqual(retry["Authorization"], first["Authorization"])
        self.assertEqual(status["Authorization"], first["Authorization"])
        self.assertEqual(status["ClientResponse"], first["ClientResponse"])
        self.assertEqual(self.fs.files, files)
        self.assertEqual(self.os.calls, calls)

    def test_expired_authorization_refresh_keeps_identity_and_reissues_signed_return(self):
        invitation = self.invite(); request, _ = self.pair(invitation)
        original = self.call("authorize_external", request)
        manifest = self.b.read_json(tc.MANIFEST)
        self.time += dt.timedelta(days=8)
        refreshed = self.call("request_status", {"RequestId": base.request(2)["RequestId"], "RequestDigest": original["RequestDigest"], "RefreshAuthorization": True})
        body, data, signature = mg.decode_jws(refreshed["Authorization"])
        self.assertNotEqual(refreshed["Authorization"], original["Authorization"])
        self.assertTrue(self.crypto.verify(self.call("server_info")["ManagementSigningPublicKey"], data, signature))
        self.assertEqual(body["DeviceId"], base.request(2)["DeviceId"])
        self.assertEqual(body["ExpiresAtUtc"], "2026-10-23T02:00:00Z")
        self.assertEqual(self.b.read_json(tc.MANIFEST), manifest)
        retry = self.call("authorize_external", request)
        self.assertEqual(retry["Authorization"], refreshed["Authorization"])

    def test_failed_authorization_refresh_has_safe_metadata_only_recovery(self):
        invitation = self.invite(); request, _ = self.pair(invitation); self.call("authorize_external", request)
        manifest = self.b.read_json(tc.MANIFEST)
        path = mg.DIRECTORY + "/requests/" + base.request(2)["RequestId"] + ".json"
        self.time += dt.timedelta(days=8); self.fs.fail_path = path
        self.call("request_status", {"RequestId": base.request(2)["RequestId"], "RefreshAuthorization": True}, "NeedsRecovery")
        self.assertIsNotNone(self.fs.read(mg.PENDING))
        self.assertEqual(self.call("recover")["Outcome"], "ManagementCommitPreserved")
        self.assertEqual(self.b.read_json(tc.MANIFEST), manifest)
        recovered = self.call("request_status", {"RequestId": base.request(2)["RequestId"]})
        self.assertEqual(mg.decode_jws(recovered["Authorization"])[0]["ExpiresAtUtc"], "2026-10-23T02:00:00Z")

    def test_request_status_explicit_telemetry_is_bound_to_exact_device(self):
        rows = [{"DeviceId": base.request()["DeviceId"], "ClientAddress": "10.78.0.2/32", "LatestHandshakeUnix": 1791424800,
                 "ReceiveBytes": 99, "TransmitBytes": 150}]
        with mock.patch.object(self.os, "peer_telemetry", create=True, return_value=rows) as telemetry:
            result = self.call("request_status", {"RequestId": base.request()["RequestId"], "IncludeTelemetry": True})
        telemetry.assert_called_once()
        self.assertEqual(result["Telemetry"]["ClientPublicKey"], base.request()["ClientPublicKey"])
        self.assertEqual(result["Telemetry"]["DeviceId"], base.request()["DeviceId"])

    def test_consumed_invitation_rejects_different_request(self):
        invitation = self.invite(); request, _ = self.pair(invitation); self.call("authorize_external", request)
        replaced, _ = self.pair(invitation, 3)
        self.call("authorize_external", replaced, "InviteConsumed")
        self.assertEqual(self.call("devices")["ActiveDeviceCount"], 2)

    def test_cancelled_or_expired_invite_cannot_authorize(self):
        invitation = self.invite(); request, _ = self.pair(invitation)
        self.call("invite_cancel", {"InviteId": invitation["InviteId"]})
        self.call("authorize_external", request, "InviteUnavailable")
        second = self.call("invite_create", {"ExpiresInHours": 1})
        request, _ = self.pair(second); self.time += dt.timedelta(hours=2)
        self.assertEqual(self.call("invite_status", {"InviteId": second["InviteId"]})["State"], "Expired")
        self.call("authorize_external", request, "InviteUnavailable")
        self.assertEqual(self.call("devices")["ActiveDeviceCount"], 1)

    def test_invalid_requests_and_algorithm_confusion_have_no_peer_effect(self):
        invitation = self.invite()
        cases = [
            (lambda b: b["ServerBinding"].update(RemoteOwnerId=str(uuid_value(55))), None, "ServerBindingMismatch"),
            (lambda b: b.update(RequestDigest="0" * 64), None, "RequestDigestMismatch"),
            (lambda b: b["RecipientJwk"].update(d="secret"), None, "InvalidInput"),
            (None, {"alg": "none"}, "InvalidAlgorithm"),
            (None, {"alg": "RS256", "jku": "https://malicious.invalid/key"}, "InvalidInput"),
            (None, {"alg": "HS256"}, "InvalidAlgorithm")]
        for update, header, code in cases:
            with self.subTest(code=code):
                # Copy avoids changing the shared recipient or invitation fixture.
                signed, _ = self.pair(copy.deepcopy(invitation), update=lambda b, f=update: f(b) if f else None, header=header)
                self.call("authorize_external", signed, code)
        self.assertEqual(self.call("devices")["ActiveDeviceCount"], 1)

    def test_signature_tamper_and_oversize_rejected_before_mutation(self):
        invitation = self.invite(); request, _ = self.pair(invitation)
        token = request["PairRequest"].split(".")
        token[2] = mg.b64(bytes([mg.unb64(token[2])[0] ^ 1]) + mg.unb64(token[2])[1:])
        self.call("authorize_external", dict(request, PairRequest=".".join(token)), "InvalidSignature")
        self.call("authorize_external", dict(request, PairRequest="x" * (mg.PAIR_LIMIT + 1)), "InvalidJws")
        self.assertEqual(self.call("devices")["ActiveDeviceCount"], 1)

    def test_external_authorization_failure_rolls_back_peer_invite_and_request_record(self):
        invitation = self.invite(); request, _ = self.pair(invitation)
        self.os.fail = lambda argv: argv[:2] == ["wg", "syncconf"]
        self.call("authorize_external", request, "RolledBack")
        self.assertEqual(self.call("invite_status", {"InviteId": invitation["InviteId"]})["State"], "Open")
        self.assertEqual(self.call("devices")["ActiveDeviceCount"], 1)
        self.assertIsNone(self.fs.read(mg.DIRECTORY + "/requests/" + base.request(2)["RequestId"] + ".json"))
        self.call("authorize_external", request)

    def test_crash_during_external_authorization_is_outcome_unknown_and_safe_recovery(self):
        invitation = self.invite(); request, _ = self.pair(invitation)
        self.os.crash = lambda argv: argv[:2] == ["wg", "syncconf"]
        with self.assertRaises(base.Crash): self.b.execute("authorize_external", request)
        pending = self.b.read_json(tc.ACTIVE)
        self.assertEqual(pending["SchemaVersion"], 2)
        self.assertEqual(pending["Action"], "authorize_external")
        self.assertEqual(self.call("request_status", {"RequestId": base.request(2)["RequestId"]})["Status"], "OutcomeUnknown")
        self.call("authorize_external", request, "NeedsRecovery")
        self.os.crash = None; self.call("recover")
        self.assertEqual(self.call("invite_status", {"InviteId": invitation["InviteId"]})["State"], "Open")
        self.assertEqual(self.call("devices")["ActiveDeviceCount"], 1)
        self.call("authorize_external", request)

    def test_revocation_is_authoritative_preserves_other_peer_and_blocks_replay(self):
        invitation = self.invite(); request, _ = self.pair(invitation); self.call("authorize_external", request)
        preview = self.call("revoke_preview", {"DeviceId": base.request(2)["DeviceId"]})
        self.call("revoke", {"DeviceId": base.request(2)["DeviceId"], "ExpectedConfigRevision": preview["ConfigRevision"], "ApprovedChangeDigest": preview["ChangeDigest"]})
        status = self.call("request_status", {"RequestId": base.request(2)["RequestId"]})
        self.assertEqual(status["Status"], "Revoked")
        self.assertNotIn("ClientResponse", status)
        self.assertEqual(self.call("authorize_external", request)["Status"], "Revoked")
        self.call("authorize", {"ClientRequest": base.request(2)}, "AuthorizationConflict")
        catalog = self.call("devices")
        self.assertEqual((catalog["ActiveDeviceCount"], catalog["RevokedDeviceCount"]), (1, 1))
        row = next(r for r in catalog["Devices"] if r["DeviceId"] == base.request(2)["DeviceId"])
        self.assertEqual(row["RevokedAtUtc"], "2026-10-08T02:00:00Z")
        self.b.verify(self.plan, self.b.read_json(tc.MANIFEST))

    def test_stale_revoke_approval_has_no_effect(self):
        self.upgrade(); self.b.authorize({"ClientRequest": base.request(2)})
        preview = self.call("revoke_preview", {"DeviceId": base.request(2)["DeviceId"]})
        self.b.authorize({"ClientRequest": base.request(3)})
        self.call("revoke", {"DeviceId": base.request(2)["DeviceId"], "ExpectedConfigRevision": preview["ConfigRevision"], "ApprovedChangeDigest": preview["ChangeDigest"]}, "RevisionConflict")
        self.assertEqual(self.call("devices")["ActiveDeviceCount"], 3)

    def test_rename_is_metadata_only_and_catalog_is_paginated(self):
        self.upgrade(); self.b.authorize({"ClientRequest": base.request(2)})
        before, calls = self.b.read_json(tc.MANIFEST), list(self.os.calls)
        result = self.call("device_rename", {"DeviceId": base.request(2)["DeviceId"], "Name": "Office PC", "ExpectedConfigRevision": 2})
        self.assertEqual(result["ConfigRevision"], 2)
        self.assertEqual(self.b.read_json(tc.MANIFEST), before)
        self.assertEqual(self.os.calls, calls)
        first, second = self.call("devices", {"Limit": 1}), self.call("devices", {"Offset": 1, "Limit": 1})
        self.assertEqual(first["NextOffset"], 1); self.assertIsNone(second["NextOffset"])
        self.assertNotEqual(first["Devices"][0]["DeviceId"], second["Devices"][0]["DeviceId"])

    def test_uninstall_preview_and_apply_preserve_audit_not_cloud_resources(self):
        self.upgrade(); preview = self.call("uninstall_preview")
        self.assertFalse(preview["CloudServerReleased"])
        self.assertIn("billing", " ".join(preview["Warnings"]))
        self.call("uninstall", {"ExpectedConfigRevision": preview["ConfigRevision"], "ApprovedChangeDigest": preview["ChangeDigest"]})
        self.assertIsNotNone(self.fs.read(mg.PRIVATE_KEY)); self.assertIsNotNone(self.fs.read(mg.STATE))
        self.assertEqual(self.call("server_info")["OwnershipState"], "Uninstalled")
        self.assertEqual(self.call("request_status", {"RequestId": base.request()["RequestId"]})["Status"], "Revoked")

    def test_retired_history_does_not_consume_active_capacity_and_addresses_stay_reserved(self):
        self.fs = base.MemoryFS(); self.os = base.FakeOS(self.fs)
        self.b = tc.Backend(self.fs, self.os, now=lambda: self.time, management_crypto=self.crypto)
        value = base.plan_input(); value["TunnelSubnet"] = "10.78.0.0/16"
        p = self.b.plan(value); self.b.apply({"PlanId": p["PlanId"]}); self.upgrade()
        # A validated retired catalog isolates history capacity from a long
        # sequence of identical sync operations. Retired records never enter
        # live resources, and each reserved address belongs to this /16.
        manifest = self.b.read_json(tc.MANIFEST)
        import ipaddress
        manifest["Revoked"] = [self.b.new_peer(base.request(i), str(ipaddress.IPv4Address("10.78.0.1") + i) + "/32") for i in range(2, 258)]
        self.b.write_json(tc.MANIFEST, manifest)
        result = self.call("authorize", {"ClientRequest": base.request(300)})
        self.assertEqual(result["ClientResponse"]["ClientAddress"], "10.78.1.3/32")
        self.assertEqual(self.call("devices")["ActiveDeviceCount"], 2)

    def test_exhausted_address_pool_preserves_retired_identity(self):
        self.fs = base.MemoryFS(); self.os = base.FakeOS(self.fs)
        self.b = tc.Backend(self.fs, self.os, now=lambda: self.time, management_crypto=self.crypto)
        value = base.plan_input(); value["TunnelSubnet"] = "10.78.0.0/30"
        p = self.b.plan(value); self.b.apply({"PlanId": p["PlanId"]})
        self.b.revoke({"DeviceId": base.request()["DeviceId"]})
        self.call("authorize", {"ClientRequest": base.request(2)}, "AddressPoolExhausted")
        self.assertEqual(self.call("devices")["RevokedDeviceCount"], 1)

    def test_jws_public_der_matches_independent_library(self):
        raw = mg.public_der(self.recipient_jwk)
        independent = self.recipient.public_key().public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)
        self.assertEqual(raw, independent)
        self.assertEqual(mg.parse_public_der(independent), self.recipient_jwk)

    def test_real_openssl_cross_verification_when_available(self):
        executable = "/usr/bin/openssl" if os.name == "posix" else r"C:\Program Files\Git\usr\bin\openssl.exe"
        if not os.path.isfile(executable): self.skipTest("OpenSSL executable unavailable")
        crypto = mg.OpenSSLCrypto(executable)
        private, public = crypto.generate()
        self.assertEqual(crypto.public(private), public)
        token = mg.sign_jws(crypto, private, {"Kind": "CrossImplementationVector", "Text": "新电脑"})
        body, data, signature = mg.decode_jws(token)
        self.assertTrue(self.crypto.verify(public, data, signature))
        independent = mg.sign_jws(self.recipient_crypto, self.recipient_pem, body)
        _, data, signature = mg.decode_jws(independent)
        self.assertTrue(crypto.verify(self.recipient_jwk, data, signature))
        self.assertFalse(crypto.verify(self.recipient_jwk, data + b"x", signature))

    def test_trace_returns_only_validated_global_exit_no_body(self):
        runner = tc.LinuxOS(); stream, context = mock.Mock(), mock.Mock()
        stream.getsockname.return_value = ("192.0.2.10", 43123)
        stream.recv.side_effect = [bytes([v]) for v in b"HTTP/1.1 200 OK\r\n"] + [b"Content-Type: text/plain\r\n\r\nip=8.8.8.8\nprivate=secret\n", b""]
        context.wrap_socket.return_value = stream
        with mock.patch.object(runner, "guard"), mock.patch.object(tc.socket, "socket", return_value=stream), mock.patch.object(tc.ssl, "create_default_context", return_value=context):
            result = runner.direct_https()
        self.assertEqual(result["ObservedExitIPv4"], "8.8.8.8")
        self.assertEqual(result["ExitEvidence"], "VerifiedTlsTrace")
        self.assertNotIn("secret", json.dumps(result))


def uuid_value(number):
    import uuid
    return uuid.UUID(int=number)


if __name__ == "__main__": unittest.main()
