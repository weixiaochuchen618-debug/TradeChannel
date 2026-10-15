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

if __name__=='__main__':unittest.main()
