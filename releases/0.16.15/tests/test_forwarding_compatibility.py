"""IPv4 0/1 transaction matrix using only the in-memory OS/FS adapters.

No subprocess, network socket, system sysctl, firewall or service is changed.
"""
import copy
import json
import unittest
from unittest import mock

import test_linux_server as fixtures

tc = fixtures.tc


class ForwardingCompatibilityTests(unittest.TestCase):
    def fixture(self, original):
        case = fixtures.BackendTests("runTest")
        case.setUp()
        case.os.env["Forwarding"] = original
        return case

    def assert_no_network_writes(self, calls):
        self.assertTrue(all(call == ["wg", "pubkey"] for call in calls), calls)

    def test_inspect_accepts_zero_and_one_without_any_writes(self):
        for original in ("0", "1"):
            with self.subTest(original=original):
                case = self.fixture(original)
                result = case.call("inspect")
                self.assertTrue(result["Supported"], result)
                self.assertFalse(case.fs.mutations)
                self.assertFalse(case.os.calls)
                self.assertEqual(case.os.env["Forwarding"], original)

    def test_invalid_forwarding_is_not_treated_as_a_supported_original_value(self):
        for invalid in ("2", "-1", "", 1, True, None):
            with self.subTest(value=invalid):
                case = self.fixture(invalid)
                result = case.call("inspect")
                self.assertFalse(result["Supported"])
                self.assertIn("InvalidForwarding", [issue["Code"] for issue in result["Issues"]])
                case.call("plan", fixtures.plan_input(), ok=False)
                self.assertFalse(case.fs.mutations)

    def test_enabled_ipv4_does_not_allow_ipv6_or_foreign_networking(self):
        changes = (
            lambda env: env.update(IPv6Forwarding="1"),
            lambda env: env["Nft"]["nftables"].append({"table": {"family": "ip", "name": "foreign"}}),
            lambda env: env["LegacyRules"].append("-A FORWARD -j ACCEPT"),
            lambda env: env["Services"].append("docker.service"),
            lambda env: env["Rules"].append({"priority": 100, "table": 99}),
            lambda env: env.update(EnabledServices=["nftables.service"]),
        )
        for index, change in enumerate(changes):
            with self.subTest(change=index):
                case = self.fixture("1")
                change(case.os.env)
                self.assertEqual(case.call("plan", fixtures.plan_input(), ok=False)["Code"], "PreflightRejected")
                self.assertFalse(case.fs.mutations)
                self.assertFalse(case.os.calls)

    def test_apply_and_uninstall_preserve_the_exact_original_value(self):
        for original in ("0", "1"):
            with self.subTest(original=original):
                case = self.fixture(original)
                route = copy.deepcopy(case.os.env["Routes"][0])
                case.apply()
                manifest = json.loads(case.fs.files[tc.MANIFEST])
                self.assertEqual(manifest["OriginalForwarding"], original)
                self.assertEqual(case.os.env["Forwarding"], "1")
                tx = next(json.loads(value) for path, value in case.fs.files.items()
                          if path.startswith(tc.ROOT + "/transactions/"))
                self.assertEqual(tx["OriginalForwarding"], original)
                self.assertEqual(tx["After"]["OriginalForwarding"], original)
                case.call("uninstall")
                self.assertEqual(case.os.env["Forwarding"], original)
                self.assertEqual(case.os.env["Routes"][0], route)
                self.assertFalse(case.os.tunnels)
                self.assertFalse(case.fs.links)
                self.assertFalse(tc.nft_normalized(case.os.env["Nft"]))
                self.assertFalse(any("flush" in call for call in case.os.calls))
                self.assertEqual(case.call("uninstall")["Status"], "Uninstalled")

    def test_post_package_forwarding_drift_is_not_overwritten(self):
        for original, changed in (("0", "1"), ("1", "0")):
            with self.subTest(original=original):
                case = self.fixture(original)
                case.os.env["Tools"]["nft"] = False
                case.os.env["Nft"] = None
                case.plan()
                case.os.install_effect = lambda: case.os.env.update(Forwarding=changed)
                result = case.call("apply", {"PlanId": case.plan_id}, ok=False)
                self.assertEqual(result["Code"], "NeedsRecovery")
                self.assertEqual(result["FailureCode"], "ForwardingDrift")
                self.assertEqual(case.os.env["Forwarding"], changed)
                self.assertFalse(any(call[0] == "sysctl" or call[:2] == ["systemctl", "start"]
                                     for call in case.os.calls))
                self.assertNotIn(tc.MANIFEST, case.fs.files)
                self.assertIsNone(json.loads(case.fs.files[tc.ACTIVE])["After"])

    def test_failed_apply_restores_original_without_regenerating_identity(self):
        for original in ("0", "1"):
            with self.subTest(original=original):
                case = self.fixture(original)
                case.plan()
                case.os.fail = lambda call: call == ["systemctl", "start", case.paths["TunnelUnit"]]
                self.assertEqual(case.call("apply", {"PlanId": case.plan_id}, ok=False)["Code"], "RolledBack")
                self.assertEqual(case.os.env["Forwarding"], original)
                self.assertNotIn(tc.ACTIVE, case.fs.files)
                self.assertNotIn(tc.MANIFEST, case.fs.files)
                self.assertFalse(case.os.tunnels)
                identity = case.fs.files[case.paths["Identity"]]
                case.call("apply", {"PlanId": case.plan_id})
                self.assertEqual(case.fs.files[case.paths["Identity"]], identity)
                self.assertEqual(case.os.key_count, 1)

    def test_crash_recover_restores_zero_and_one_and_can_be_retried(self):
        for original in ("0", "1"):
            with self.subTest(original=original):
                case = self.fixture(original)
                case.pending_initial_apply()
                self.assertEqual(case.os.env["Forwarding"], "1")
                self.assertEqual(case.call("recover")["Outcome"], "RolledBack")
                self.assertEqual(case.os.env["Forwarding"], original)
                self.assertFalse(case.os.tunnels)
                self.assertFalse(case.fs.links)
                self.assertEqual(case.call("recover")["Status"], "NoRecoveryRequired")
                case.call("apply", {"PlanId": case.plan_id})
                self.assertEqual(json.loads(case.fs.files[tc.MANIFEST])["OriginalForwarding"], original)
                self.assertEqual(case.os.key_count, 1)

    def test_finalize_original_zero_and_one_without_network_mutations(self):
        for original in ("0", "1"):
            with self.subTest(original=original):
                case = self.fixture(original)
                tx = case.pending_initial_apply()
                self.assertEqual(tx["OriginalForwarding"], original)
                snapshot = copy.deepcopy((case.os.env, case.os.running, case.os.tunnels))
                calls = len(case.os.calls)
                result = case.call("finalize", {"PlanId": case.plan_id})
                self.assertEqual(result["Status"], "Applied")
                self.assertEqual(snapshot, (case.os.env, case.os.running, case.os.tunnels))
                self.assert_no_network_writes(case.os.calls[calls:])
                self.assertEqual(json.loads(case.fs.files[tc.MANIFEST])["OriginalForwarding"], original)
                self.assertNotIn(tc.ACTIVE, case.fs.files)
                self.assertEqual(result, case.call("finalize", {"PlanId": case.plan_id}))
                case.call("uninstall")
                self.assertEqual(case.os.env["Forwarding"], original)

    def test_finalize_commit_failure_can_retry_for_both_original_values(self):
        for original in ("0", "1"):
            with self.subTest(original=original):
                case = self.fixture(original)
                case.pending_initial_apply()
                snapshot = copy.deepcopy((case.os.env, case.os.running, case.os.tunnels))
                calls = len(case.os.calls)
                case.fs.fail_path = tc.MANIFEST
                result = case.call("finalize", {"PlanId": case.plan_id}, ok=False)
                self.assertEqual((result["Code"], result["FailureCode"]), ("NeedsRecovery", "DiskFailure"))
                self.assertEqual(snapshot, (case.os.env, case.os.running, case.os.tunnels))
                self.assert_no_network_writes(case.os.calls[calls:])
                case.call("finalize", {"PlanId": case.plan_id})
                case.call("uninstall")
                self.assertEqual(case.os.env["Forwarding"], original)

    def test_finalize_rejects_mismatched_or_invalid_original_values(self):
        for original in ("0", "1"):
            for target, value in (("Journal", "1" if original == "0" else "0"),
                                  ("After", "1" if original == "0" else "0"),
                                  ("Both", "2"), ("Both", 1)):
                with self.subTest(original=original, target=target, value=value):
                    case = self.fixture(original)
                    tx = case.pending_initial_apply()
                    if target in ("Journal", "Both"):
                        tx["OriginalForwarding"] = value
                    if target in ("After", "Both"):
                        tx["After"]["OriginalForwarding"] = value
                    case.fs.files[tc.ACTIVE] = tc.dumps(tx)
                    writes, calls = len(case.fs.mutations), len(case.os.calls)
                    self.assertEqual(case.call("finalize", {"PlanId": case.plan_id}, ok=False)["Code"], "FinalizeNotAllowed")
                    self.assertEqual(len(case.fs.mutations), writes)
                    self.assert_no_network_writes(case.os.calls[calls:])

    def test_recovery_rejects_original_mismatch_without_changing_network(self):
        for original in ("0", "1"):
            with self.subTest(original=original):
                case = self.fixture(original)
                tx = case.pending_initial_apply()
                tx["OriginalForwarding"] = "1" if original == "0" else "0"
                case.fs.files[tc.ACTIVE] = tc.dumps(tx)
                calls = len(case.os.calls)
                result = case.call("recover", ok=False)
                self.assertEqual((result["Code"], result["RecoveryCode"]), ("NeedsRecovery", "InvalidJournal"))
                self.assert_no_network_writes(case.os.calls[calls:])
                self.assertEqual(case.os.env["Forwarding"], "1")

    def test_runtime_forwarding_drift_still_blocks_status_and_uninstall(self):
        for original in ("0", "1"):
            with self.subTest(original=original):
                case = self.fixture(original)
                case.apply()
                case.os.env["Forwarding"] = "0"
                writes, calls = len(case.fs.mutations), len(case.os.calls)
                self.assertEqual(case.call("status", ok=False)["Code"], "TunnelDrift")
                self.assertEqual(case.call("uninstall", ok=False)["Code"], "TunnelDrift")
                self.assertEqual(len(case.fs.mutations), writes)
                self.assert_no_network_writes(case.os.calls[calls:])

    def test_committed_journal_recovery_keeps_original_value(self):
        for original in ("0", "1"):
            with self.subTest(original=original):
                case = self.fixture(original)
                case.plan()
                original_cas = case.fs.cas
                def fail_cleanup(path, before, after, **kwargs):
                    if path == tc.ACTIVE and after is None:
                        raise tc.TCError("DiskFailure", "isolated archive cleanup failure")
                    return original_cas(path, before, after, **kwargs)
                with mock.patch.object(case.fs, "cas", side_effect=fail_cleanup):
                    self.assertEqual(case.call("apply", {"PlanId": case.plan_id}, ok=False)["Code"], "NeedsRecovery")
                calls = len(case.os.calls)
                self.assertEqual(case.call("recover")["Outcome"], "CommitPreserved")
                self.assert_no_network_writes(case.os.calls[calls:])
                self.assertEqual(json.loads(case.fs.files[tc.MANIFEST])["OriginalForwarding"], original)
                case.call("uninstall")
                self.assertEqual(case.os.env["Forwarding"], original)

    def test_manifest_cannot_supply_a_noncanonical_forwarding_restore_value(self):
        for invalid in ("2", "0;echo injected", 1, None):
            with self.subTest(value=invalid):
                case = self.fixture("0")
                case.apply()
                manifest = json.loads(case.fs.files[tc.MANIFEST])
                manifest["OriginalForwarding"] = invalid
                case.fs.files[tc.MANIFEST] = tc.dumps(manifest)
                writes, calls = len(case.fs.mutations), len(case.os.calls)
                self.assertEqual(case.call("uninstall", ok=False)["Code"], "InvalidState")
                self.assertEqual(len(case.fs.mutations), writes)
                self.assert_no_network_writes(case.os.calls[calls:])


if __name__ == "__main__":
    unittest.main()
