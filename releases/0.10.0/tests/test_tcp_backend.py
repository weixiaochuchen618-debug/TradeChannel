"""TCP deployment transactions use the shipped fake kernel; no host mutation."""
import base64
import copy
import importlib.util
import json
from pathlib import Path
import unittest

spec=importlib.util.spec_from_file_location('tcp_base_tests',Path(__file__).with_name('test_linux_server.py'))
base=importlib.util.module_from_spec(spec);spec.loader.exec_module(base)
tc=base.tc

class TcpOS(base.FakeOS):
    def __init__(self,fs):
        super().__init__(fs);self.binary=False;self.busy=False;self.download_failure=False;self.transport_starts=0
    def transport_port_busy(self,port):return self.busy
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
