"""Real backend, fake kernel/filesystem. No SSH or external network is used."""
import copy
import datetime as dt
import json
import unittest
import uuid

import test_linux_server as base

tc = base.tc


def execution(action, inputs, intent=None):
    wire = json.dumps(inputs, sort_keys=True, separators=(',', ':'), ensure_ascii=False)
    return {'SchemaVersion': 1, 'IntentId': intent or str(uuid.uuid4()), 'Operation': action,
            'InputDigest': tc.digest(wire), 'WireInput': wire}


class ResolutionTests(unittest.TestCase):
    def fixture(self):
        f = base.BackendTests()
        f.setUp()
        return f

    def invoke(self, f, action, inputs, context=None):
        f.backend.execution_context = context
        return tc.envelope(action, inputs, f.backend)

    def resolve(self, f, action, inputs, intent, failure=None, transaction=None):
        query = {'Operation': action, 'IntentId': intent, 'OriginalInput': inputs}
        if failure:
            query['OriginalFailureCode'] = failure
        if transaction:
            query['TransactionId'] = transaction
        mutations = list(f.fs.mutations)
        result = self.invoke(f, 'operation_result', query)
        self.assertTrue(result['Ok'], result)
        self.assertEqual(mutations, f.fs.mutations, 'operation_result must not write evidence or repair resources')
        data = result['Data']
        self.assertTrue(data['ReadOnly'])
        return data

    def failed_case(self, case, fresh):
        f = self.fixture()
        if case == 'authorize_rollback':
            f.apply()
            action, inputs = 'authorize', {'ClientRequest': base.request(2)}
            f.os.fail = lambda cmd: cmd[:2] == ['wg', 'syncconf']
        else:
            f.plan()
            action, inputs = 'apply', {'PlanId': f.plan_id}
            if case == 'apply_expired':
                f.time += dt.timedelta(hours=2)
            else:
                f.os.fail = lambda cmd: cmd == ['systemctl', 'start', f.paths['TunnelUnit']]
        context = execution(action, inputs)
        reply = self.invoke(f, action, inputs, context if fresh else None)
        self.assertFalse(reply['Ok'], reply)
        self.assertNotIn(tc.ACTIVE, f.fs.files)
        return f, action, inputs, context, reply

    def test_three_original_failures_legacy_and_new_settle_without_mutation(self):
        for fresh in (False, True):
            for case in ('apply_rollback', 'apply_expired', 'authorize_rollback'):
                with self.subTest(fresh=fresh, case=case):
                    f, action, inputs, context, reply = self.failed_case(case, fresh)
                    data = self.resolve(f, action, inputs, context['IntentId'], reply['Data']['Code'], reply['Data'].get('TransactionId'))
                    self.assertEqual(data['Outcome'], 'RejectedBeforeMutation' if case == 'apply_expired' else 'RolledBack', data)
                    self.assertEqual(data['ManagedResourceVerification'], 'Verified')
                    self.assertNotIn('PrivateKey', json.dumps(data))
                    self.assertEqual(data, self.resolve(f, action, inputs, context['IntentId'], reply['Data']['Code'], reply['Data'].get('TransactionId')))

    def test_success_response_lost_resolves_and_same_intent_is_idempotent(self):
        f = self.fixture(); f.plan()
        inputs = {'PlanId': f.plan_id}; context = execution('apply', inputs)
        reply = self.invoke(f, 'apply', inputs, context)
        self.assertTrue(reply['Ok'], reply)
        before = list(f.fs.mutations)
        again = self.invoke(f, 'apply', inputs, context)
        self.assertEqual(reply, again)
        self.assertEqual(before, f.fs.mutations)
        self.assertEqual(self.resolve(f, 'apply', inputs, context['IntentId'])['Outcome'], 'Applied')

    def test_same_intent_changed_input_never_mutates(self):
        f, action, inputs, context, reply = self.failed_case('apply_expired', True)
        changed = {'PlanId': str(uuid.uuid4())}
        other = execution(action, changed, context['IntentId'])
        before = list(f.fs.mutations)
        result = self.invoke(f, action, changed, other)
        self.assertFalse(result['Ok'])
        self.assertEqual(result['Data']['Code'], 'OperationBindingMismatch')
        self.assertEqual(before, f.fs.mutations)

    def test_pending_or_tampered_archive_stays_unknown(self):
        for tamper in ('active', 'file', 'action', 'input'):
            with self.subTest(tamper=tamper):
                f, action, inputs, context, reply = self.failed_case('apply_rollback', True)
                txid = reply['Data']['TransactionId']; path = tc.ROOT + '/transactions/' + txid + '.json'
                tx = json.loads(f.fs.files[path])
                if tamper == 'active':
                    f.fs.files[tc.ACTIVE] = tc.dumps(tx)
                elif tamper == 'file':
                    f.fs.files[f.paths['TunnelService']] = 'foreign'
                elif tamper == 'action':
                    tx['Action'] = 'authorize'; f.fs.files[path] = tc.dumps(tx)
                else:
                    tx['ExecutionContext']['InputDigest'] = '0' * 64; f.fs.files[path] = tc.dumps(tx)
                data = self.resolve(f, action, inputs, context['IntentId'], 'RolledBack', txid)
                self.assertIn(data['Outcome'], ('Unknown', 'Pending'), data)

    def test_missing_plan_and_reinstalled_owner_are_not_absence_proof(self):
        f, action, inputs, context, reply = self.failed_case('apply_expired', False)
        del f.fs.files[tc.ROOT + '/plans/' + f.plan_id + '.json']
        data = self.resolve(f, action, inputs, context['IntentId'], 'PlanExpired')
        self.assertEqual(data['Outcome'], 'Unknown')
        self.assertEqual(data['ReasonCode'], 'PlanNotFound')

    def test_authorized_then_revoked_is_never_reauthorized_by_read(self):
        f = self.fixture(); f.apply(); inputs = {'ClientRequest': base.request(2)}
        context = execution('authorize', inputs)
        self.assertTrue(self.invoke(f, 'authorize', inputs, context)['Ok'])
        self.assertTrue(self.invoke(f, 'revoke', {'DeviceId': inputs['ClientRequest']['DeviceId']})['Ok'])
        self.assertEqual(self.resolve(f, 'authorize', inputs, context['IntentId'])['Outcome'], 'Unknown')

    def test_digest_is_exact_utf8_and_preserves_arrays_null_and_number_text(self):
        for inputs in ({'中文': '香港', 'empty': None, 'array': [2443, 443]}, {'float': 1.25, 'zero': 0, 'bool': False}):
            f = self.fixture(); context = execution('apply', inputs)
            f.backend.execution_context = context
            f.backend.check_execution_context('apply', inputs)
            broken = copy.deepcopy(context); broken['WireInput'] += ' '
            f.backend.execution_context = broken
            with self.assertRaises(tc.TCError):
                f.backend.check_execution_context('apply', inputs)

    def test_receipt_write_failure_does_not_rollback_committed_installation(self):
        f = self.fixture(); f.plan(); inputs = {'PlanId': f.plan_id}; context = execution('apply', inputs)
        original = f.backend.operation_complete
        def fail(result):
            raise tc.TCError('NeedsRecovery', 'fixture result write failed')
        f.backend.operation_complete = fail
        result = self.invoke(f, 'apply', inputs, context)
        self.assertFalse(result['Ok'])
        self.assertEqual(result['Data']['Code'], 'NeedsRecovery')
        self.assertEqual(json.loads(f.fs.files[tc.MANIFEST])['Status'], 'Applied')
        f.backend.operation_complete = original
        self.assertEqual(self.resolve(f, 'apply', inputs, context['IntentId'])['Outcome'], 'Applied')

    def test_unrelated_request_and_owner_do_not_inherit_original_outcome(self):
        f,action,inputs,context,reply=self.failed_case('authorize_rollback',True)
        other={'ClientRequest':base.request(3)}
        data=self.resolve(f,action,other,context['IntentId'],'RolledBack',reply['Data']['TransactionId'])
        self.assertEqual(data['Outcome'],'Unknown');self.assertEqual(data['ReasonCode'],'OperationBindingMismatch')
        owner=json.loads(f.fs.files[tc.OWNER]);owner['OwnerId']=str(uuid.uuid4());f.fs.files[tc.OWNER]=tc.dumps(owner)
        data=self.resolve(f,action,inputs,context['IntentId'],'RolledBack',reply['Data']['TransactionId'])
        self.assertEqual(data['Outcome'],'Unknown')

    def test_duplicate_legacy_archive_is_ambiguous_and_missing_id_never_guesses(self):
        f,action,inputs,context,reply=self.failed_case('apply_rollback',False)
        path=tc.ROOT+'/transactions/'+reply['Data']['TransactionId']+'.json';tx=json.loads(f.fs.files[path]);tx['TransactionId']=str(uuid.uuid4())
        f.fs.files[tc.ROOT+'/transactions/'+tx['TransactionId']+'.json']=tc.dumps(tx)
        data=self.resolve(f,action,inputs,context['IntentId'],'RolledBack')
        self.assertEqual(data['Outcome'],'Unknown');self.assertEqual(data['ReasonCode'],'OperationEvidenceAmbiguous')


class TcpResolutionTests(unittest.TestCase):
    def test_tcp_rollback_and_port_rejection_resolve_with_original_udp_intact(self):
        import test_tcp_backend as tcp
        for mode in ('rollback','rejection'):
            with self.subTest(mode=mode):
                f=tcp.IncrementalTcpTests();f.setUp();f.plan()
                inputs={'PlanId':f.preview['PlanId'],'ApprovedChangeDigest':f.preview['ChangeDigest']}
                context=execution('transport_apply',inputs);f.backend.execution_context=context
                if mode=='rollback':f.os.download_failure=True
                else:f.os.busy=True
                reply=tcp.tc.envelope('transport_apply',inputs,f.backend)
                self.assertFalse(reply['Ok'],reply)
                f.backend.execution_context=None
                query={'Operation':'transport_apply','IntentId':context['IntentId'],'OriginalInput':inputs,'OriginalFailureCode':reply['Data']['Code']}
                if 'TransactionId' in reply['Data']:query['TransactionId']=reply['Data']['TransactionId']
                before=list(f.fs.mutations);result=tcp.tc.envelope('operation_result',query,f.backend)
                self.assertTrue(result['Ok'],result)
                self.assertEqual(result['Data']['Outcome'],'RolledBack' if mode=='rollback' else 'RejectedBeforeMutation',result)
                self.assertEqual(f.backend.read_json(tcp.tc.MANIFEST),f.old_manifest)
                self.assertEqual(before,f.fs.mutations)


if __name__ == '__main__':
    unittest.main()
