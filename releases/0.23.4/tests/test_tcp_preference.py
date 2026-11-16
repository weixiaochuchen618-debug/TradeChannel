"""Supported-port ordering and preservation; real backend with no live sockets."""
import json
import unittest
from unittest import mock
import test_tcp_backend as fixture

tc=fixture.tc

class TcpPreferenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        fixture.TransportInfoTests.setUpClass.__func__(cls)
    setUp=fixture.TransportInfoTests.setUp
    snapshot=fixture.TransportInfoTests.snapshot
    enable_tcp=fixture.TransportInfoTests.enable_tcp

    def options(self, ports):
        return self.backend.execute('transport_options', dict(ServerPublicKey=self.request['ServerPublicKey'], ServerName='www.bing.com', CandidatePorts=ports))

    def test_preferred_free_then_only_busy_falls_back(self):
        before=self.snapshot()
        for preferred in (8443,2443):
            ports=[preferred]+[p for p in (443,8443,2443) if p!=preferred]
            with mock.patch.object(self.os,'transport_port_busy',return_value=False):
                result=self.options(ports)
            self.assertEqual(result['Port'],preferred);self.assertFalse(result['FallbackUsed'])
            with mock.patch.object(self.os,'transport_port_busy',side_effect=lambda p:p==preferred):
                result=self.options(ports)
            self.assertEqual(result['Port'],443);self.assertTrue(result['FallbackUsed'])
            self.assertEqual(result['PreferredPort'],preferred)
        self.assertEqual(before,self.snapshot())

    def test_all_busy_has_specific_result_without_remote_write(self):
        before=self.snapshot()
        with mock.patch.object(self.os,'transport_port_busy',return_value=True), mock.patch.object(self.os,'tls_endpoint_probe',side_effect=AssertionError('No viable listener')):
            result=self.options([2443,443,8443])
        self.assertEqual(result['Code'],'TransportPortsUnavailable');self.assertIsNone(result['Port'])
        self.assertEqual(before,self.snapshot())

    def test_unsupported_port_rejected_at_all_new_input_boundaries(self):
        for action,inputs in (
            ('transport_options',dict(ServerPublicKey=self.request['ServerPublicKey'],ServerName='www.bing.com',CandidatePorts=[1443])),
            ('transport_plan',dict(Transport=dict(Type='tcp-reality',Port=1443,ServerName='www.bing.com'))),
            ('plan',dict(fixture.base.plan_input(),Transport=dict(Type='tcp-reality',Port=1443,ServerName='www.bing.com')))):
            before=self.snapshot()
            with self.assertRaises(tc.TCError) as caught:self.backend.execute(action,inputs)
            self.assertEqual(caught.exception.code,'UnsupportedTcpPort')
            self.assertEqual(before,self.snapshot())

    def test_existing_tcp_is_not_rotated_to_new_preference(self):
        self.enable_tcp();before=self.snapshot()
        with mock.patch.object(self.os,'transport_port_busy',side_effect=AssertionError('Preserve listener')), mock.patch.object(self.os,'tls_endpoint_probe',side_effect=AssertionError('Preserve TLS target')):
            result=self.options([2443,443,8443])
        self.assertEqual(result['Status'],'Available');self.assertTrue(result['PreservedExisting'])
        self.assertEqual(result['Transport']['Port'],443)
        self.assertEqual(before,self.snapshot())

if __name__=='__main__':unittest.main()
