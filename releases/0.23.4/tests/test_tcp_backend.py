"""TCP deployment transactions use the shipped fake kernel; no host mutation."""
import base64
import copy
import importlib.util
import json
from pathlib import Path
import unittest
from unittest import mock

from cryptography.hazmat.primitives.asymmetric import rsa
from test_management_backend import FixtureCrypto

spec=importlib.util.spec_from_file_location('tcp_base_tests',Path(__file__).with_name('test_linux_server.py'))
base=importlib.util.module_from_spec(spec);spec.loader.exec_module(base)
tc=base.tc

class TcpOS(base.FakeOS):
    def __init__(self,fs):
        super().__init__(fs);self.binary=False;self.busy=False;self.download_failure=False;self.transport_starts=0
    def transport_port_busy(self,port):return self.busy
    def tls_endpoint_probe(self,server_name,timeout_seconds):
        # Fixture-only positive TLS endpoint result; never touches a socket.
        return {'Status':'TlsEndpointReachable','ErrorCode':None}
    def ensure_transport(self):
        if self.download_failure:raise tc.TCError('TransportDownloadFailed','Fixture download failure.')
        self.binary=True;return tc.tcp_support.BINARY
    def verify_transport(self):
        tc.require(self.binary,'TransportHashMismatch','Fixture binary missing.')
        return tc.tcp_support.BINARY
    def reality_keypair(self):
        private=base.public_key('reality-private')
        public=base.public_key(private)
        to_url=lambda value:base64.urlsafe_b64encode(base64.b64decode(value)).decode().rstrip('=')
        return {'PrivateKey':to_url(private),'PublicKey':to_url(public),'ShortId':'1234567890abcdef','Uuid':'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'}
    def effect(self,argv,input_text):
        if argv[0] in (tc.tcp_support.BINARY,'sing-box-1.14.2'):
            self.verify_transport()
            json.loads(self.fs.files[argv[-1]])
            return ''
        if argv[:2] in (['systemctl','start'],['systemctl','stop']) and argv[2].endswith('-transport.service'):
            if argv[1]=='start':self.running.add(argv[2]);self.transport_starts+=1
            else:self.running.discard(argv[2])
            return ''
        return super().effect(argv,input_text)

class TcpBackendTests(unittest.TestCase):
    def setUp(self):
        self.fs=base.MemoryFS();self.os=TcpOS(self.fs)
        self.backend=tc.Backend(self.fs,self.os,now=lambda:base.dt.datetime(2026,10,8,tzinfo=base.dt.timezone.utc))
        self.input=base.plan_input();self.input['Transport']={'Type':'tcp-reality','Port':443,'ServerName':'www.bing.com'}
    def plan(self):
        self.preview=self.backend.plan(self.input)
        self.plan_data=self.backend.load_plan(self.preview['PlanId'],self.os.probe())
        self.paths=tc.paths(self.plan_data)
    def apply(self):
        self.plan();return self.backend.apply({'PlanId':self.preview['PlanId']})
    def test_tcp_plan_apply_authorize_revoke_preserve_transport_and_existing_peer(self):
        result=self.apply();response=result['ClientResponse']
        self.assertEqual(response['Transport']['Port'],443)
        self.assertNotIn('PrivateKey',json.dumps(response))
        transport=self.fs.files[self.paths['TransportConfig']]
        self.assertIn(self.paths['TransportUnit'],self.os.running)
        starts=self.os.transport_starts
        authorized=self.backend.authorize({'ClientRequest':base.request(2)})
        self.assertEqual(authorized['ClientResponse']['Transport'],response['Transport'])
        self.assertEqual(self.fs.files[self.paths['TransportConfig']],transport)
        self.assertEqual(self.os.transport_starts,starts)
        self.backend.revoke({'DeviceId':base.request(2)['DeviceId']})
        manifest=self.backend.read_json(tc.MANIFEST)
        self.assertEqual(len(manifest['Peers']),1)
        self.assertEqual(self.fs.files[self.paths['TransportConfig']],transport)
        self.assertEqual(self.os.transport_starts,starts)
        self.backend.verify(self.plan_data,manifest)
    def test_tcp_port_conflict_is_rejected_before_plan_state(self):
        self.os.busy=True
        with self.assertRaises(tc.TCError) as caught:self.backend.plan(self.input)
        self.assertEqual(caught.exception.code,'TransportPortBusy')
        self.assertFalse(self.fs.mutations)
    def test_download_failure_restores_prior_host_resources(self):
        self.plan();self.os.download_failure=True
        with self.assertRaises(tc.TCError):self.backend.apply({'PlanId':self.preview['PlanId']})
        self.assertIsNone(self.fs.read(tc.MANIFEST))
        self.assertFalse(self.os.running)
        self.assertEqual(self.os.env['Forwarding'],'0')
        self.assertIsNone(self.fs.read(tc.ACTIVE))
    def test_tcp_uninstall_stops_only_owned_units_and_removes_config(self):
        self.apply();self.backend.uninstall({})
        self.assertFalse(self.os.running)
        self.assertIsNone(self.fs.read(self.paths['TransportConfig']))
        self.assertIsNone(self.fs.read(self.paths['TransportService']))
        self.assertTrue(self.os.binary)
    def test_tcp_manifest_identity_drift_is_rejected(self):
        self.apply();manifest=self.backend.read_json(tc.MANIFEST);manifest['Transport']['PublicKey']='A'*43
        self.backend.write_json(tc.MANIFEST,manifest)
        with self.assertRaises(tc.TCError) as caught:self.backend.verify(self.plan_data,manifest)
        self.assertEqual(caught.exception.code,'IdentityDrift')
    def test_transport_accepts_only_wireguard_udp_destination(self):
        self.apply();cfg=json.loads(self.fs.files[self.paths['TransportConfig']])
        allow,reject=cfg['route']['rules']
        self.assertEqual(allow['network'],'udp')
        self.assertEqual(allow['port'],[51820])
        self.assertEqual(allow['override_address'],'127.0.0.1')
        self.assertEqual(reject['action'],'reject')
        self.assertEqual(len(cfg['outbounds']),1)

class IncrementalTcpTests(unittest.TestCase):
    def setUp(self):
        self.fs = base.MemoryFS(); self.os = TcpOS(self.fs)
        self.backend = tc.Backend(self.fs, self.os, now=lambda: base.dt.datetime(2026, 10, 8, tzinfo=base.dt.timezone.utc), progress=lambda _: None)
        result = self.backend.plan(base.plan_input())
        self.backend.apply({'PlanId': result['PlanId']})
        self.backend.authorize({'ClientRequest': base.request(2)})
        self.old_manifest = self.backend.read_json(tc.MANIFEST)
        self.old_plan = self.backend.load_plan(self.old_manifest['PlanId'], self.os.probe())
        self.old_paths = tc.paths(self.old_plan)
        self.old_identity = self.backend.identity(self.old_plan)

    def plan(self):
        self.preview = self.backend.transport_plan({'Transport': {'Type': 'tcp-reality', 'Port': 443, 'ServerName': 'www.bing.com'}})
        return self.preview

    def apply(self):
        self.plan()
        return self.backend.transport_apply({'PlanId': self.preview['PlanId'], 'ApprovedChangeDigest': self.preview['ChangeDigest']})

    def test_incremental_tcp_preserves_tunnel_identity_config_peers_and_running_services(self):
        before = copy.deepcopy(self.fs.files); calls = len(self.os.calls)
        result = self.apply()
        manifest = self.backend.read_json(tc.MANIFEST)
        plan = self.backend.load_plan(manifest['PlanId'], self.os.probe())
        self.assertEqual(result['Status'], 'TransportEnabled')
        self.assertFalse(result['WireGuardRestarted'])
        self.assertTrue(result['MaintenancePreview'])
        self.assertEqual(manifest['Peers'], self.old_manifest['Peers'])
        self.assertEqual(manifest['ServerPublicKey'], self.old_manifest['ServerPublicKey'])
        self.assertEqual(plan['NodeId'], self.old_plan['NodeId'])
        self.assertEqual(self.backend.identity(plan)['PrivateKey'], self.old_identity['PrivateKey'])
        for path in tc.resource_paths(self.old_plan): self.assertEqual(self.fs.files[path], before[path], path)
        units = {self.old_paths['TunnelUnit'], self.old_paths['FirewallUnit']}
        self.assertFalse(any(c[:2] in (['systemctl', 'start'], ['systemctl', 'stop']) and c[2] in units for c in self.os.calls[calls:]))
        self.assertFalse(any(c[:2] in (['wg-quick', 'up'], ['wg-quick', 'down'], ['wg', 'syncconf']) for c in self.os.calls[calls:]))
        self.assertEqual(manifest['ConfigRevision'], self.old_manifest['ConfigRevision'] + 1)
        response = self.backend.execute('request_status', {'RequestId': base.request(2)['RequestId']})['ClientResponse']
        self.assertEqual(response['Transport']['Port'], 443)
        self.backend.verify(plan, manifest)

    def test_retry_is_idempotent_and_new_peer_uses_existing_transport_identity(self):
        self.apply(); before = copy.deepcopy(self.fs.files); starts = self.os.transport_starts
        self.backend.transport_apply({'PlanId': self.preview['PlanId'], 'ApprovedChangeDigest': self.preview['ChangeDigest']})
        self.assertEqual(self.fs.files, before); self.assertEqual(self.os.transport_starts, starts)
        manifest = self.backend.read_json(tc.MANIFEST)
        authorization = self.backend.authorize({'ClientRequest': base.request(3)})
        self.assertEqual(authorization['ClientResponse']['Transport']['Uuid'], manifest['Transport']['Uuid'])

    def test_stale_preview_and_wrong_approval_do_not_create_transport(self):
        self.plan()
        with self.assertRaises(tc.TCError) as caught:
            self.backend.transport_apply({'PlanId': self.preview['PlanId'], 'ApprovedChangeDigest': '0' * 64})
        self.assertEqual(caught.exception.code, 'ApprovalMismatch')
        self.backend.authorize({'ClientRequest': base.request(3)})
        with self.assertRaises(tc.TCError) as caught:
            self.backend.transport_apply({'PlanId': self.preview['PlanId'], 'ApprovedChangeDigest': self.preview['ChangeDigest']})
        self.assertEqual(caught.exception.code, 'RevisionConflict')
        self.assertNotIn('Transport', self.backend.identity(self.old_plan))
        self.assertFalse(self.os.binary)

    def test_component_download_failure_restores_original_udp_without_restart(self):
        self.plan(); self.os.download_failure = True
        with self.assertRaises(tc.TCError) as caught:
            self.backend.transport_apply({'PlanId': self.preview['PlanId'], 'ApprovedChangeDigest': self.preview['ChangeDigest']})
        self.assertEqual(caught.exception.code, 'RolledBack')
        self.assertEqual(self.backend.read_json(tc.MANIFEST), self.old_manifest)
        self.assertEqual(self.backend.identity(self.old_plan), self.old_identity)
        self.assertIsNone(self.fs.read(tc.ACTIVE))
        self.backend.verify(self.old_plan, self.old_manifest)

    def test_transport_check_failure_rolls_back_private_identity_and_new_resources(self):
        self.plan(); self.os.fail = lambda argv: argv[:2] == [tc.tcp_support.BINARY, 'check']
        with self.assertRaises(tc.TCError) as caught:
            self.backend.transport_apply({'PlanId': self.preview['PlanId'], 'ApprovedChangeDigest': self.preview['ChangeDigest']})
        self.assertEqual(caught.exception.code, 'RolledBack')
        newplan = self.backend.load_plan(self.preview['PlanId'], self.os.probe())
        p = tc.paths(newplan)
        self.assertIsNone(self.fs.read(p['TransportConfig'])); self.assertIsNone(self.fs.link(p['TransportLink']))
        self.assertEqual(self.backend.identity(self.old_plan), self.old_identity)
        self.assertTrue(self.os.binary)
        self.backend.verify(self.old_plan, self.old_manifest)

    def test_crash_after_start_is_recovered_without_touching_existing_tunnel(self):
        self.plan(); newplan = self.backend.load_plan(self.preview['PlanId'], self.os.probe()); p = tc.paths(newplan)
        self.os.crash = lambda argv: argv == ['systemctl', 'start', p['TransportUnit']]
        with self.assertRaises(base.Crash):
            self.backend.transport_apply({'PlanId': self.preview['PlanId'], 'ApprovedChangeDigest': self.preview['ChangeDigest']})
        self.assertEqual(self.backend.status({})['Status'], 'NeedsRecovery')
        tx = self.backend.read_json(tc.ACTIVE)
        self.assertEqual((tx['SchemaVersion'], tx['Action']), (2, 'transport_add'))
        result = self.backend.recover({})
        self.assertEqual(result['Outcome'], 'RolledBack')
        self.assertEqual(self.backend.read_json(tc.MANIFEST), self.old_manifest)
        self.assertNotIn(p['TransportUnit'], self.os.running)
        self.backend.verify(self.old_plan, self.old_manifest)

    def test_external_file_mutation_keeps_recovery_barrier(self):
        self.plan(); newplan = self.backend.load_plan(self.preview['PlanId'], self.os.probe()); p = tc.paths(newplan)
        self.os.crash = lambda argv: argv == ['systemctl', 'start', p['TransportUnit']]
        with self.assertRaises(base.Crash):
            self.backend.transport_apply({'PlanId': self.preview['PlanId'], 'ApprovedChangeDigest': self.preview['ChangeDigest']})
        self.fs.files[p['TransportConfig']] = 'foreign'
        with self.assertRaises(tc.TCError) as caught: self.backend.recover({})
        self.assertEqual(caught.exception.code, 'NeedsRecovery')
        self.assertEqual(self.fs.files[p['TransportConfig']], 'foreign')
        self.assertIsNotNone(self.fs.read(tc.ACTIVE))

    def test_new_transport_journal_path_injection_is_rejected(self):
        self.plan(); newplan = self.backend.load_plan(self.preview['PlanId'], self.os.probe()); p = tc.paths(newplan)
        self.os.crash = lambda argv: argv == ['systemctl', 'start', p['TransportUnit']]
        with self.assertRaises(base.Crash):
            self.backend.transport_apply({'PlanId': self.preview['PlanId'], 'ApprovedChangeDigest': self.preview['ChangeDigest']})
        tx = self.backend.read_json(tc.ACTIVE)
        tx['Files']['/etc/foreign.conf'] = {'Before': None, 'After': 'malicious'}
        self.backend.write_json(tc.ACTIVE, tx)
        with self.assertRaises(tc.TCError) as caught: self.backend.recover({})
        self.assertEqual(caught.exception.code, 'NeedsRecovery')
        self.assertIsNone(self.fs.read('/etc/foreign.conf'))

class TransportInfoTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.crypto = FixtureCrypto(rsa.generate_private_key(public_exponent=65537, key_size=3072))

    def setUp(self):
        self.fs = base.MemoryFS(); self.os = TcpOS(self.fs)
        self.backend = tc.Backend(self.fs, self.os, now=lambda: base.dt.datetime(2026, 10, 8, tzinfo=base.dt.timezone.utc),
                                  management_crypto=self.crypto, progress=lambda _: None)
        preview = self.backend.plan(base.plan_input())
        self.backend.apply({'PlanId': preview['PlanId']})
        upgrade = self.backend.execute('management_plan', {})
        self.backend.execute('management_apply', {'PlanId': upgrade['PlanId'], 'ApprovedChangeDigest': upgrade['ChangeDigest']})
        self.backend.authorize({'ClientRequest': base.request(2)})
        self.request = {'ClientPublicKey': base.request(2)['ClientPublicKey'],
                        'ServerPublicKey': self.backend.read_json(tc.MANIFEST)['ServerPublicKey']}

    def enable_tcp(self):
        preview = self.backend.transport_plan({'Transport': {'Type': 'tcp-reality', 'Port': 443, 'ServerName': 'www.bing.com'}})
        self.backend.transport_apply({'PlanId': preview['PlanId'], 'ApprovedChangeDigest': preview['ChangeDigest']})

    def test_auto_candidates_preserve_listeners_and_select_supported_fallback(self):
        before = self.snapshot()
        with mock.patch.object(self.os, 'transport_port_busy', side_effect=lambda port: port == 443):
            result = self.backend.transport_candidates({'ServerPublicKey': self.request['ServerPublicKey'], 'ServerName': 'www.bing.com'})
        self.assertEqual((result['Status'], result['Port']), ('Selected', 8443))
        self.assertEqual([x['Port'] for x in result['Candidates']], [443, 8443, 2443])
        self.assertEqual(result['HandshakeValidation'], 'NotTested')
        self.assertEqual(self.snapshot(), before)

    def test_candidates_exhausted_preserve_udp(self):
        before = self.snapshot(); self.os.busy = True
        result = self.backend.transport_candidates({'ServerPublicKey': self.request['ServerPublicKey'], 'ServerName': 'www.bing.com'})
        self.assertEqual(result['Status'], 'Unavailable')
        self.assertIsNone(result['Port'])
        self.assertEqual(self.snapshot(), before)

    def test_existing_tcp_port_and_identity_are_preserved_even_if_candidates_busy(self):
        self.enable_tcp(); before = self.snapshot(); self.os.busy = True
        result = self.backend.transport_candidates({'ServerPublicKey': self.request['ServerPublicKey'], 'ServerName': 'other.example.com'})
        self.assertTrue(result['PreservedExisting'])
        self.assertEqual(result['Transport'], {'Type': 'tcp-reality', 'Port': 443, 'ServerName': 'www.bing.com'})
        self.assertEqual(self.snapshot(), before)

    def test_candidate_port_race_rejected_before_install_with_udp_intact(self):
        plan = self.backend.transport_plan({'Transport': {'Type': 'tcp-reality', 'Port': 8443, 'ServerName': 'www.bing.com'}})
        before = self.snapshot(); self.os.busy = True
        with self.assertRaises(tc.TCError) as caught:
            self.backend.transport_apply({'PlanId': plan['PlanId'], 'ApprovedChangeDigest': plan['ChangeDigest']})
        self.assertEqual(caught.exception.code, 'TransportPortBusy')
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(self.backend.deployment_state(self.request)['Udp']['Status'], 'Healthy')

    def test_tcp_download_failure_rechecks_real_udp_and_preserves_peer_count(self):
        manifest = self.backend.read_json(tc.MANIFEST)
        plan = self.backend.transport_plan({'Transport': {'Type': 'tcp-reality', 'Port': 443, 'ServerName': 'www.bing.com'}})
        self.os.download_failure = True
        with self.assertRaises(tc.TCError) as caught:
            self.backend.transport_apply({'PlanId': plan['PlanId'], 'ApprovedChangeDigest': plan['ChangeDigest']})
        self.assertEqual(caught.exception.code, 'RolledBack')
        self.assertEqual(self.backend.read_json(tc.MANIFEST), manifest)
        state = self.backend.deployment_state(self.request)
        self.assertEqual((state['Status'], state['Udp']['Status']), ('Settled', 'Healthy'))
        self.assertEqual(len(self.backend.read_json(tc.MANIFEST)['Peers']), 2)
        self.assertFalse(state['TcpConfigured'])

    def test_port_race_during_component_preparation_rolls_back_before_publish(self):
        manifest = self.backend.read_json(tc.MANIFEST)
        plan = self.backend.transport_plan({'Transport': {'Type': 'tcp-reality', 'Port': 443, 'ServerName': 'www.bing.com'}})
        original = self.os.ensure_transport
        def prepare():
            result = original(); self.os.busy = True; return result
        with mock.patch.object(self.os, 'ensure_transport', side_effect=prepare):
            with self.assertRaises(tc.TCError) as caught:
                self.backend.transport_apply({'PlanId': plan['PlanId'], 'ApprovedChangeDigest': plan['ChangeDigest']})
        self.assertEqual(caught.exception.code, 'RolledBack')
        self.assertEqual(caught.exception.data['FailureCode'], 'TransportPortBusy')
        self.assertEqual(self.backend.read_json(tc.MANIFEST), manifest)
        self.assertEqual(self.backend.deployment_state(self.request)['Udp']['Status'], 'Healthy')

    def test_actual_udp_state_remains_readable_when_tcp_service_is_broken(self):
        self.enable_tcp(); manifest = self.backend.read_json(tc.MANIFEST)
        plan = self.backend.load_plan(manifest['PlanId'], self.os.probe()); unit = tc.paths(plan)['TransportUnit']
        self.os.running.remove(unit)
        before = self.snapshot(); state = self.backend.deployment_state(self.request)
        self.assertEqual((state['Status'], state['Udp']['Status']), ('Settled', 'Healthy'))
        self.assertEqual(state['Services']['Transport']['ActiveState'], 'inactive')
        self.assertEqual(self.snapshot(), before)

    def test_pending_transport_transaction_reports_udp_without_recovery_or_replay(self):
        plan = self.backend.transport_plan({'Transport': {'Type': 'tcp-reality', 'Port': 443, 'ServerName': 'www.bing.com'}})
        newplan = self.backend.load_plan(plan['PlanId'], self.os.probe())
        self.os.crash = lambda argv: argv == ['systemctl', 'start', tc.paths(newplan)['TransportUnit']]
        with self.assertRaises(base.Crash):
            self.backend.transport_apply({'PlanId': plan['PlanId'], 'ApprovedChangeDigest': plan['ChangeDigest']})
        before = self.snapshot(); state = self.backend.deployment_state(self.request)
        self.assertEqual(state['Status'], 'NeedsRecovery')
        self.assertEqual(state['Udp']['Status'], 'Healthy')
        self.assertEqual(state['Transaction']['Action'], 'transport_add')
        self.assertEqual(self.snapshot(), before)

    def test_state_cannot_claim_udp_healthy_after_runtime_drift(self):
        manifest = self.backend.read_json(tc.MANIFEST); plan = self.backend.load_plan(manifest['PlanId'], self.os.probe())
        self.os.tunnels[tc.paths(plan)['Interface']]['PublicKey'] = base.public_key('drift')
        before = self.snapshot(); state = self.backend.deployment_state(self.request)
        self.assertEqual(state['Udp'], {'Status': 'Failed', 'ErrorCode': 'TunnelDrift'})
        self.assertEqual(self.snapshot(), before)

    def test_state_rejects_wrong_server_and_revoked_device(self):
        with self.assertRaises(tc.TCError) as caught:
            self.backend.deployment_state(dict(self.request, ServerPublicKey=base.public_key('another')))
        self.assertEqual(caught.exception.code, 'ServerBindingMismatch')
        self.backend.revoke({'DeviceId': base.request(2)['DeviceId']})
        self.assertEqual(self.backend.deployment_state(self.request)['Udp']['Status'], 'Failed')

    def test_candidates_do_not_expand_ports_or_accept_unknown_fields(self):
        for extra in ({'CandidatePorts': [80]}, {'CandidatePorts': [443, 443]}, {'Unknown': True}):
            before = self.snapshot()
            with self.assertRaises(tc.TCError):
                self.backend.transport_candidates(dict(ServerPublicKey=self.request['ServerPublicKey'], ServerName='www.bing.com', **extra))
            self.assertEqual(self.snapshot(), before)

    def snapshot(self):
        return copy.deepcopy((self.fs.files, self.fs.dirs, self.fs.links, self.fs.modes, self.fs.mutations,
                              self.os.running, self.os.tunnels, self.os.env, self.os.transport_starts,
                              self.os.key_count, self.os.install_count, self.os.binary))

    def query(self, value=None, code=None):
        before, calls = self.snapshot(), len(self.os.calls)
        # These fixtures have no real networking, installer, signer or service.
        with mock.patch.object(self.backend, 'change_peers', side_effect=AssertionError('No authorization')), \
             mock.patch.object(self.os, 'ensure_transport', side_effect=AssertionError('No install')):
            result = tc.envelope('transport_info', self.request if value is None else value, self.backend)
        self.assertEqual(self.snapshot(), before)
        self.assertTrue(all(c == ['wg', 'pubkey'] for c in self.os.calls[calls:]), self.os.calls[calls:])
        self.assertEqual(result['Action'], 'transport_info')
        if code:
            self.assertFalse(result['Ok'], result)
            self.assertEqual(result['Data']['Code'], code, result)
            self.assertNotIn('Transport', result['Data'])
            self.assertNotIn('Status', result['Data'])
        else:
            self.assertTrue(result['Ok'], result)
        return result

    def test_unconfigured_tcp_is_bound_not_configured_without_mutation(self):
        with mock.patch.object(self.fs, 'lock', wraps=self.fs.lock) as lock:
            first = self.query()['Data']
        lock.assert_called_once_with(readonly=True)
        self.assertEqual(first['Status'], 'NotConfigured')
        self.assertEqual(set(first), {'Kind', 'NodeId', 'RemoteOwnerId', 'ServerPublicKey', 'ClientPublicKey', 'ClientAddress', 'Status', 'MTU'})
        self.assertEqual(first['MTU'], tc.TUNNEL_MTU)
        self.assertEqual(first['Kind'], 'TradeChannel.TransportInfo')
        self.assertEqual(first['ClientPublicKey'], self.request['ClientPublicKey'])
        self.assertEqual(first['ClientAddress'], '10.78.0.3/32')
        self.assertEqual(self.query()['Data'], first)

    def test_available_matches_authorize_return_and_binds_existing_client(self):
        self.enable_tcp()
        manifest = self.backend.read_json(tc.MANIFEST)
        plan = self.backend.load_plan(manifest['PlanId'], self.os.probe())
        peer = next(p for p in manifest['Peers'] if p['ClientPublicKey'] == self.request['ClientPublicKey'])
        result = self.query()['Data']
        self.assertEqual(result['Status'], 'Available')
        self.assertEqual(result['MTU'], tc.client_response(plan, manifest, peer)['MTU'])
        self.assertEqual(result['NodeId'], manifest['NodeId'])
        self.assertEqual(result['RemoteOwnerId'], self.backend.owner(self.os.probe())['OwnerId'])
        self.assertEqual(result['ServerPublicKey'], self.request['ServerPublicKey'])
        self.assertEqual(result['ClientPublicKey'], peer['ClientPublicKey'])
        self.assertEqual(result['ClientAddress'], peer['ClientAddress'])
        self.assertEqual(result['Transport'], tc.client_response(plan, manifest, peer)['Transport'])
        self.assertEqual(set(result['Transport']), {'Type', 'Server', 'Port', 'ServerName', 'Uuid', 'RealityPublicKey', 'RealityShortId'})
        for _ in range(3): self.assertEqual(self.query()['Data'], result)
        initial = self.query(dict(self.request, ClientPublicKey=base.request()['ClientPublicKey']))['Data']
        self.assertEqual(initial['ClientAddress'], '10.78.0.2/32')
        self.assertEqual(initial['Transport'], result['Transport'])

    def test_wrong_server_identity_is_rejected_with_or_without_tcp(self):
        self.query(dict(self.request, ServerPublicKey=base.public_key('other-server')), 'ServerBindingMismatch')
        self.enable_tcp()
        self.query(dict(self.request, ServerPublicKey=base.public_key('other-server')), 'ServerBindingMismatch')

    def test_unknown_and_revoked_client_are_rejected(self):
        self.enable_tcp()
        self.query(dict(self.request, ClientPublicKey=base.public_key('unknown')), 'DeviceNotFound')
        self.backend.revoke({'DeviceId': base.request(2)['DeviceId']})
        self.query(code='DeviceRevoked')

    def test_request_requires_exact_fields_and_canonical_nonzero_keys(self):
        for value in ({}, [], None, 'input', {'ClientPublicKey': self.request['ClientPublicKey']},
                      {'ServerPublicKey': self.request['ServerPublicKey']}, dict(self.request, DeviceId=base.request(2)['DeviceId'])):
            with self.subTest(value=value):
                # None is passed directly here; the query helper uses it as default.
                if value is None:
                    self.assertEqual(tc.envelope('transport_info', None, self.backend)['Data']['Code'], 'InvalidInput')
                else: self.query(value, 'InvalidInput')
        for field in ('ClientPublicKey', 'ServerPublicKey'):
            for value in (None, 123, [], '', 'bad', 'A' * 43 + '=', 'A' * 42 + 'B=', self.request[field].rstrip('=')):
                with self.subTest(field=field, value=value): self.query(dict(self.request, **{field: value}), 'InvalidKey')

    def test_management_v2_is_required_and_cannot_be_created_by_query(self):
        self.fs.files.pop(tc.management.STATE)
        self.query(code='ManagementUpgradeRequired')

    def test_absent_or_uninstalled_node_is_rejected(self):
        self.backend.uninstall({})
        self.query(code='NodeUninstalled')
        backend = tc.Backend(base.MemoryFS(), base.FakeOS(base.MemoryFS()))
        result = tc.envelope('transport_info', self.request, backend)
        self.assertEqual(result['Data']['Code'], 'NotInstalled')
        self.assertFalse(backend.fs.mutations)

    def test_management_catalog_identity_state_and_binding_must_match(self):
        original = self.backend.read_json(tc.management.STATE)
        for update, code in (({'State': 'Revoked'}, 'DeviceNotAuthorized'),
                             ({'RevokedAtUtc': '2026-10-08T00:00:00Z'}, 'DeviceNotAuthorized'),
                             ({'ClientPublicKey': base.public_key('another-client')}, 'DeviceIdentityMismatch')):
            state = copy.deepcopy(original)
            state['Devices'][base.request(2)['DeviceId']].update(update)
            self.backend.write_json(tc.management.STATE, state)
            self.query(code=code)
        state = copy.deepcopy(original); state['Devices'].pop(base.request(2)['DeviceId'])
        self.backend.write_json(tc.management.STATE, state); self.query(code='InvalidManagementState')
        state = copy.deepcopy(original); state['ServerBinding']['ServerPublicKey'] = base.public_key('another-server')
        self.backend.write_json(tc.management.STATE, state); self.query(code='ManagementIdentityMismatch')

    def test_pending_tunnel_or_management_transaction_is_not_repaired(self):
        for path in (tc.ACTIVE, tc.management.PENDING):
            self.fs.files[path] = '{}'
            self.query(code='NeedsRecovery')
            self.fs.files.pop(path)

    def test_inactive_overridden_and_changed_tcp_resources_are_failures(self):
        self.enable_tcp()
        manifest = self.backend.read_json(tc.MANIFEST)
        p = tc.paths(self.backend.load_plan(manifest['PlanId'], self.os.probe()))
        self.os.running.discard(p['TransportUnit']); self.query(code='ServiceDrift')
        self.os.running.add(p['TransportUnit'])
        self.os.override[p['TransportUnit']] = dict(self.os.service(p['TransportUnit']), DropInPaths='/etc/foreign.conf')
        self.query(code='ServiceDrift'); self.os.override.clear()
        self.os.binary = False; self.query(code='TransportHashMismatch'); self.os.binary = True
        self.fs.files[p['TransportConfig']] += '\n'; self.query(code='ConfigDrift')

    def test_wireguard_runtime_identity_drift_is_a_failure(self):
        self.enable_tcp()
        manifest = self.backend.read_json(tc.MANIFEST)
        p = tc.paths(self.backend.load_plan(manifest['PlanId'], self.os.probe()))
        self.os.tunnels[p['Interface']]['PublicKey'] = base.public_key('different-live-server')
        self.query(code='TunnelDrift')

    def test_tcp_leftovers_cannot_be_reported_not_configured(self):
        manifest = self.backend.read_json(tc.MANIFEST)
        plan = self.backend.load_plan(manifest['PlanId'], self.os.probe())
        p = tc.paths(dict(plan, Transport=True))
        for label in ('TransportConfig', 'TransportService'):
            self.fs.files[p[label]] = 'foreign'
            self.query(code='ConfigDrift'); self.fs.files.pop(p[label])
        self.fs.links[p['TransportLink']] = p['TransportService']
        self.query(code='ConfigDrift'); self.fs.links.pop(p['TransportLink'])
        self.os.override[p['TransportUnit']] = {'LoadState': 'loaded', 'ActiveState': 'inactive'}
        self.query(code='ServiceDrift')

    def test_server_private_keys_and_other_device_metadata_never_leave_response(self):
        self.enable_tcp()
        manifest = self.backend.read_json(tc.MANIFEST)
        plan = self.backend.load_plan(manifest['PlanId'], self.os.probe())
        identity = self.backend.identity(plan)
        state = self.backend.read_json(tc.management.STATE)
        state['Devices'][base.request()['DeviceId']].update(Name='OTHER-DEVICE-SECRET', Secret='PRIVATE-OTHER-DEVICE')
        self.backend.write_json(tc.management.STATE, state)
        result = self.query()
        for value in (identity['PrivateKey'], identity['Transport']['PrivateKey'], self.fs.files[tc.management.PRIVATE_KEY],
                      'OTHER-DEVICE-SECRET', 'PRIVATE-OTHER-DEVICE', base.request()['ClientPublicKey']):
            self.assertNotIn(value, json.dumps(result))
        manifest['Transport']['PublicKey'] = identity['Transport']['PrivateKey']
        self.backend.write_json(tc.MANIFEST, manifest)
        failed = self.query(code='IdentityDrift')
        self.assertNotIn(identity['Transport']['PrivateKey'], json.dumps(failed))

    def test_capabilities_advertises_readonly_operation_and_cli_dispatches(self):
        result = self.backend.execute('capabilities', {})
        self.assertEqual(result['Actions'].count('transport_info'), 1)
        self.assertEqual(result['ReadOnlyActions'].count('transport_info'), 1)
        output = base.io.StringIO()
        before = self.snapshot()
        status = tc.main(['transport_info', '--input', '-'], base.io.StringIO(json.dumps(self.request)), output, self.backend)
        self.assertEqual(status, 0)
        self.assertEqual(json.loads(output.getvalue())['Data']['Status'], 'NotConfigured')
        self.assertEqual(self.snapshot(), before)


class RealCommandBoundaryTests(unittest.TestCase):
    def setUp(self):
        from unittest import mock
        self.mock = mock
        self.runner = tc.LinuxOS()
        self.process = mock.MagicMock()
        self.process.__enter__.return_value = self.process
        self.process.communicate.return_value = ('', '')
        self.process.returncode = 0

    def test_ss_real_binary_path_is_usable_without_shell_or_wrong_sbin_fallback(self):
        with self.mock.patch.object(self.runner, 'guard'), self.mock.patch.object(tc.subprocess, 'Popen', return_value=self.process) as start:
            self.assertFalse(self.runner.transport_port_busy(443))
        self.assertEqual(start.call_args.args[0], ['/usr/bin/ss', '-H', '-ltn', 'sport = :443'])
        self.assertFalse(start.call_args.kwargs['shell'])

    def test_only_hash_verified_pinned_transport_absolute_path_can_execute(self):
        with self.mock.patch.object(self.runner, 'guard'), self.mock.patch.object(self.runner, 'verify_transport', return_value=tc.tcp_support.BINARY) as verify, self.mock.patch.object(tc.subprocess, 'Popen', return_value=self.process) as start:
            self.runner.run([tc.tcp_support.BINARY, 'check', '-c', '/var/lib/tradechannel/fixture/transport.json'])
        verify.assert_called_once()
        self.assertEqual(start.call_args.args[0][0], tc.tcp_support.BINARY)
        self.assertFalse(start.call_args.kwargs['shell'])

    def test_untrusted_absolute_executable_is_rejected_before_process_creation(self):
        with self.mock.patch.object(self.runner, 'guard'), self.mock.patch.object(tc.subprocess, 'Popen') as start:
            with self.assertRaises(tc.TCError) as caught: self.runner.run(['/bin/sh', '-c', 'untrusted'])
        self.assertEqual(caught.exception.code, 'InvalidCommand')
        start.assert_not_called()

if __name__=='__main__':unittest.main()
