"""Outbound TLS target selection: fake server and fully mocked OS sockets/child.

Never executes a real SSH command, DNS query, connect, or TLS handshake.
"""
import io
import json
import subprocess
import sys
import unittest
from unittest import mock

import test_tcp_backend as fixture

tc = fixture.tc
REACHABLE = {'Status': 'TlsEndpointReachable', 'ErrorCode': None}
FAILED = {'Status': 'Failed', 'ErrorCode': 'TlsCertificateInvalid'}


class TransportOptionsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        fixture.TransportInfoTests.setUpClass.__func__(cls)

    setUp = fixture.TransportInfoTests.setUp
    snapshot = fixture.TransportInfoTests.snapshot
    enable_tcp = fixture.TransportInfoTests.enable_tcp

    def options(self, name='www.bing.com', **extra):
        return self.backend.execute('transport_options', dict(ServerPublicKey=self.request['ServerPublicKey'], ServerName=name, **extra))

    def test_default_tls_endpoint_precheck_stops_at_first_success_without_mutation(self):
        before = self.snapshot()
        with mock.patch.object(self.os, 'tls_endpoint_probe', return_value=REACHABLE) as probe:
            result = self.options()
        self.assertEqual(result['SelectedServerName'], 'www.bing.com')
        self.assertEqual(result['HandshakeValidation'], 'TlsEndpointReachable')
        self.assertEqual(result['ValidationLayer'], 'TlsEndpointReachable')
        self.assertEqual(result['ServerNameChoices'], ['www.bing.com', 'www.microsoft.com'])
        self.assertEqual(probe.call_count, 1)
        self.assertEqual(self.snapshot(), before)

    def test_default_certificate_failure_uses_only_controlled_fallback(self):
        before = self.snapshot()
        with mock.patch.object(self.os, 'tls_endpoint_probe', side_effect=[FAILED, REACHABLE]) as probe:
            result = self.options()
        self.assertEqual(result['SelectedServerName'], 'www.microsoft.com')
        self.assertEqual(result['ServerName'], 'www.microsoft.com')
        self.assertEqual(result['HandshakeChecks'][0]['ErrorCode'], 'TlsCertificateInvalid')
        self.assertEqual([call.args[0] for call in probe.call_args_list], ['www.bing.com', 'www.microsoft.com'])
        self.assertTrue(all(0 < call.args[1] <= 4 for call in probe.call_args_list))
        self.assertEqual(self.snapshot(), before)

    def test_no_success_preserves_udp_peers_and_does_not_create_plan_or_apply(self):
        before = self.snapshot()
        with mock.patch.object(self.os, 'tls_endpoint_probe', return_value=FAILED), \
             mock.patch.object(self.backend, 'transport_plan', side_effect=AssertionError('No plan')), \
             mock.patch.object(self.backend, 'transport_apply', side_effect=AssertionError('No apply')):
            result = self.options()
        self.assertEqual((result['Status'], result['Code']), ('Unavailable', 'TransportHandshakeUnavailable'))
        self.assertIsNone(result['SelectedServerName'])
        self.assertEqual(result['HandshakeValidation'], 'Failed')
        self.assertEqual(len(result['HandshakeChecks']), 2)
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(self.backend.deployment_state(self.request)['Udp']['Status'], 'Healthy')

    def test_custom_target_failure_is_retained_without_silent_default_fallback(self):
        with mock.patch.object(self.os, 'tls_endpoint_probe', return_value={'Status': 'Failed', 'ErrorCode': 'DnsFailed'}) as probe:
            result = self.options('custom.example.com')
        self.assertEqual(result['ServerNameChoices'], ['custom.example.com'])
        self.assertEqual(result['ServerName'], 'custom.example.com')
        self.assertIsNone(result['SelectedServerName'])
        self.assertEqual([call.args[0] for call in probe.call_args_list], ['custom.example.com'])
        self.assertEqual(result['HandshakeChecks'][0]['ErrorCode'], 'DnsFailed')

    def test_budget_exhaustion_does_not_start_another_probe(self):
        with mock.patch.object(tc.time, 'monotonic', side_effect=[10.0, 10.0, 18.1]), \
             mock.patch.object(self.os, 'tls_endpoint_probe', return_value={'Status': 'Failed', 'ErrorCode': 'TlsTimeout'}) as probe:
            result = self.options()
        self.assertEqual(probe.call_count, 1)
        self.assertEqual(probe.call_args.args[1], 4)
        self.assertEqual(result['HandshakeChecks'][-1]['ErrorCode'], 'TlsBudgetExhausted')
        self.assertEqual(result['HandshakeBudgetSeconds'], 8)

    def test_existing_tcp_preserves_target_and_does_not_run_new_tls_probe(self):
        self.enable_tcp(); before = self.snapshot()
        with mock.patch.object(self.os, 'tls_endpoint_probe', side_effect=AssertionError('No replacement probe')):
            result = self.options('custom.example.com')
        self.assertEqual(result['Status'], 'Available')
        self.assertTrue(result['PreservedExisting'])
        self.assertEqual(result['SelectedServerName'], 'www.bing.com')
        self.assertEqual(result['HandshakeValidation'], 'NotTested')
        self.assertEqual(self.snapshot(), before)

    def test_occupied_ports_do_not_make_an_outbound_probe(self):
        self.os.busy = True; before = self.snapshot()
        with mock.patch.object(self.os, 'tls_endpoint_probe', side_effect=AssertionError('No viable port')):
            result = self.options()
        self.assertEqual(result['Code'], 'TransportPortsUnavailable')
        self.assertEqual(result['HandshakeValidation'], 'NotTested')
        self.assertEqual(self.snapshot(), before)

    def test_unhealthy_udp_blocks_outbound_precheck(self):
        manifest = self.backend.read_json(tc.MANIFEST)
        plan = self.backend.load_plan(manifest['PlanId'], self.os.probe())
        self.os.running.remove(tc.paths(plan)['TunnelUnit'])
        with mock.patch.object(self.os, 'tls_endpoint_probe', side_effect=AssertionError('Unhealthy UDP')):
            with self.assertRaises(tc.TCError) as caught:
                self.options()
        self.assertEqual(caught.exception.code, 'ServiceDrift')

    def test_pending_transaction_blocks_outbound_precheck(self):
        self.fs.files[tc.ACTIVE] = '{}'
        with mock.patch.object(self.os, 'tls_endpoint_probe', side_effect=AssertionError('Pending transaction')):
            with self.assertRaises(tc.TCError) as caught:
                self.options()
        self.assertEqual(caught.exception.code, 'NeedsRecovery')

    def test_unapproved_or_reordered_choices_are_rejected_before_probe(self):
        cases = [('www.bing.com', ['www.microsoft.com', 'www.bing.com']),
                 ('www.bing.com', ['www.bing.com', 'other.example.com']),
                 ('custom.example.com', ['custom.example.com', 'www.microsoft.com'])]
        for name, choices in cases:
            with self.subTest(name=name), mock.patch.object(self.os, 'tls_endpoint_probe', side_effect=AssertionError('Unapproved choices')):
                with self.assertRaises(tc.TCError) as caught:
                    self.options(name, CandidateServerNames=choices)
                self.assertEqual(caught.exception.code, 'InvalidTransportChoices')

    def test_selected_target_is_used_by_incremental_plan_and_final_transport(self):
        with mock.patch.object(self.os, 'tls_endpoint_probe', side_effect=[FAILED, REACHABLE]):
            selected = self.options()
        plan = self.backend.transport_plan({'Transport': {'Type': 'tcp-reality', 'Port': selected['Port'], 'ServerName': selected['SelectedServerName']}})
        self.assertEqual(plan['Transport']['ServerName'], 'www.microsoft.com')
        self.backend.transport_apply({'PlanId': plan['PlanId'], 'ApprovedChangeDigest': plan['ChangeDigest']})
        info = self.backend.transport_info(self.request)
        self.assertEqual(info['Transport']['ServerName'], 'www.microsoft.com')
        self.assertEqual(self.backend.deployment_state(self.request)['Udp']['Status'], 'Healthy')


class TlsOSAdapterTests(unittest.TestCase):
    def test_parent_passes_json_stdin_and_enforces_child_timeout(self):
        reply = subprocess.CompletedProcess([], 0, json.dumps(REACHABLE), '')
        with mock.patch.object(tc.LinuxOS, 'guard'), mock.patch.object(tc.subprocess, 'run', return_value=reply) as run:
            result = tc.LinuxOS().tls_endpoint_probe('custom.example.com', 3.5)
        self.assertEqual(result, REACHABLE)
        command = run.call_args.args[0]
        self.assertEqual(command, [sys.executable, '-I', '-c', tc.TRANSPORT_TLS_PROBE])
        self.assertFalse(any('custom.example.com' in x for x in command))
        self.assertEqual(json.loads(run.call_args.kwargs['input']), {'ServerName': 'custom.example.com', 'TimeoutSeconds': 3.5})
        self.assertEqual(run.call_args.kwargs['timeout'], 3.5)
        self.assertNotIn('shell', run.call_args.kwargs)

    def test_dns_child_timeout_is_an_ordinary_failure(self):
        with mock.patch.object(tc.LinuxOS, 'guard'), mock.patch.object(tc.subprocess, 'run', side_effect=subprocess.TimeoutExpired('fixture', 4)):
            result = tc.LinuxOS().tls_endpoint_probe('www.bing.com', 4)
        self.assertEqual(result, {'Status': 'Failed', 'ErrorCode': 'TlsTimeout'})

    def child(self, *, error=None, clock=None):
        stream = mock.MagicMock(); stream.__enter__.return_value = stream
        context = mock.Mock(); context.wrap_socket.return_value = mock.MagicMock()
        if error:
            context.wrap_socket.side_effect = error
        output = io.StringIO()
        with mock.patch.object(tc.socket, 'create_connection', return_value=stream) as connect, \
             mock.patch.object(tc.ssl, 'create_default_context', return_value=context), \
             mock.patch.object(tc.sys, 'stdin', io.StringIO(json.dumps({'ServerName': 'www.bing.com', 'TimeoutSeconds': 4}))), \
             mock.patch.object(tc.sys, 'stdout', output), \
             mock.patch.object(tc.time, 'monotonic', side_effect=clock or [10.0, 10.1, 10.2, 10.3]):
            exec(tc.TRANSPORT_TLS_PROBE, {'__name__': 'fixture_tls_child'})
        return json.loads(output.getvalue()), context, stream, connect

    def test_child_uses_certificate_hostname_validation_and_sni_on_443(self):
        result, context, stream, connect = self.child()
        self.assertEqual(result, REACHABLE)
        self.assertTrue(context.check_hostname)
        self.assertEqual(context.verify_mode, tc.ssl.CERT_REQUIRED)
        self.assertEqual(context.minimum_version, tc.ssl.TLSVersion.TLSv1_2)
        self.assertEqual(connect.call_args.args[0], ('www.bing.com', 443))
        context.wrap_socket.assert_called_once_with(stream, server_hostname='www.bing.com')
        stream.send.assert_not_called()
        stream.__exit__.assert_called_once()

    def test_invalid_certificate_does_not_count_as_reachable(self):
        result, _, stream, _ = self.child(error=tc.ssl.SSLCertVerificationError('fixture invalid certificate'))
        self.assertEqual(result, FAILED)
        stream.__exit__.assert_called_once()

    def test_elapsed_connect_budget_prevents_tls_handshake(self):
        result, context, stream, _ = self.child(clock=[10.0, 10.1, 14.2])
        self.assertEqual(result, {'Status': 'Failed', 'ErrorCode': 'TlsTimeout'})
        context.wrap_socket.assert_not_called()
        stream.__exit__.assert_called_once()

    def test_adapter_rejects_malformed_or_unrecognized_success(self):
        for output in ('garbage', '{"Status":"RealityAuthenticated"}', '{"Status":"TlsEndpointReachable","ErrorCode":"Failed"}'):
            reply = subprocess.CompletedProcess([], 0, output, '')
            with self.subTest(output=output), mock.patch.object(tc.LinuxOS, 'guard'), mock.patch.object(tc.subprocess, 'run', return_value=reply):
                self.assertEqual(tc.LinuxOS().tls_endpoint_probe('www.bing.com', 4), {'Status': 'Failed', 'ErrorCode': 'TlsProbeFailed'})


if __name__ == '__main__':
    unittest.main()
