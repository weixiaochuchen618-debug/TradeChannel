"""Offline deployment acceptance; never launches SSH/listeners or a tunnel.

Windows PS 5.1 is the packaged runtime. The server adapter is an in-memory
kernel; native work is limited to local keys, syntax checks and compilation.
"""
import concurrent.futures
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

PACKAGE = Path(__file__).resolve().parents[2]
WORKSPACE = PACKAGE.parents[1]
REPORT = WORKSPACE / 'reports/release-0.11.0/deployment-upgrade-tests.json'
CHANGED = [
    'DeploymentFlow.psm1', 'ConnectionBundle.psm1', 'DeploymentPairing.psm1',
    'DeploymentTransport.psm1', 'CandidateProbe.psm1', 'NodeStore.psm1',
    'linux/tradechannel_linux.py', 'tests/test_tcp_backend.py',
    'deployment/TradeChannelDeployHost.cs', 'deployment/TradeChannelDeployHost.exe',
    'deployment/tests/Test-DeploymentWorkflow.ps1', 'deployment/tests/Test-DeploymentPairing.ps1',
    'deployment/tests/Test-PairingCrossPlatform.ps1', 'deployment/tests/run_deployment_upgrade_tests.py',
    'tests/test_transport_options.py',
]


def run(name, command):
    started = time.monotonic()
    child_env = os.environ.copy()
    # A Python child of pwsh inherits PS7's PSModulePath. Framework PS5 must
    # load its own Security/Utility modules for the real ACL/hash checks.
    if Path(command[0]).name.lower() == 'powershell.exe':
        for key in list(child_env):
            if key.upper() == 'PSMODULEPATH':
                del child_env[key]
        child_env['PSMODULEPATH'] = str(Path(child_env.get('WINDIR', r'C:\Windows'))/'System32/WindowsPowerShell/v1.0/Modules')
    result = subprocess.run(command, cwd=PACKAGE, env=child_env, capture_output=True, timeout=180)
    output = (result.stdout + result.stderr).decode('utf-8', errors='replace')
    record = {'Name': name, 'Command': command, 'ExitCode': result.returncode,
              'Ok': result.returncode == 0, 'DurationSeconds': round(time.monotonic()-started, 3)}
    start = output.find('{')
    if start >= 0:
        try:
            record['Result'], _ = json.JSONDecoder().raw_decode(output[start:])
        except json.JSONDecodeError:
            pass
    count = re.search(r'Ran (\d+) tests', output)
    if count:
        record['CheckCount'] = int(count[1])
    elif isinstance(record.get('Result'), dict):
        record['CheckCount'] = record['Result'].get('CheckCount', 0)
    else:
        count = re.search(r'ServerSetup: (\d+) passed; (\d+) failed', output)
        if count:
            record.update(CheckCount=int(count[1])+int(count[2]), Passed=int(count[1]), Failed=int(count[2]))
    if not record['Ok']:
        record['Diagnostic'] = output[-4000:]
    print(json.dumps({'Name': name, 'Ok': record['Ok'], 'Checks': record.get('CheckCount', 0)}, ensure_ascii=False), flush=True)
    return record


def ps(script, *args):
    return ['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(PACKAGE/script), *args]


def main():
    if os.name != 'nt':
        raise SystemExit('This offline acceptance runner requires Windows PowerShell 5.1.')
    incremental = '--handshake-incremental' in sys.argv[1:]
    previous = json.loads(REPORT.read_text(encoding='utf-8')) if incremental else None
    suites = [
        ('DeploymentWorkflow', ps('deployment/tests/Test-DeploymentWorkflow.ps1')),
        ('DeploymentPairing', ps('deployment/tests/Test-DeploymentPairing.ps1')),
        ('PairingCrossPlatform', ps('deployment/tests/Test-PairingCrossPlatform.ps1')),
        ('ServerSetup', ps('tests/Test-ServerSetup.ps1', '-WgPath', str(PACKAGE/'assets/wg.exe'))),
    ]
    suites += [(name, [sys.executable, '-B', '-m', 'unittest', 'discover', '-s', str(PACKAGE/'tests'), '-p', file])
               for name, file in [('LinuxBackend', 'test_linux_server.py'),
                                  ('ManagementBackend', 'test_management_backend.py'), ('TcpBackend', 'test_tcp_backend.py')]]
    suites.append(('TransportOptions', [sys.executable, '-B', '-m', 'unittest', 'discover', '-s', str(PACKAGE/'tests'), '-p', 'test_transport_options.py', '-v']))
    if incremental:
        suites = [(name, command) for name, command in suites if name in ('DeploymentWorkflow', 'TcpBackend', 'TransportOptions')]
    # These suites use unique temporary roots and share no mutable runtime state.
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        futures = [pool.submit(run, name, command) for name, command in suites]
        results = [future.result() for future in futures]
    compiler = Path(os.environ.get('WINDIR', r'C:\Windows'))/'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
    build = run('DeployHostBuild', [str(compiler), '/nologo', '/target:exe', '/platform:x64',
                '/out:'+str(PACKAGE/'deployment/TradeChannelDeployHost.exe'), '/reference:System.Web.Extensions.dll',
                '/reference:'+str(PACKAGE/'assets/lib/Renci.SshNet.dll'), str(PACKAGE/'deployment/TradeChannelDeployHost.cs')])
    results.append(build)
    increment_results = list(results)
    if incremental:
        replacements = {result['Name']: result for result in results}
        results = [replacements.pop(result['Name'], result) for result in previous['Tests']]
        results.extend(replacements.values())
    report = {
        'SchemaVersion': 1, 'Release': '0.11.0', 'Kind': 'TradeChannel.DeploymentUpgradeTests',
        'GeneratedAtUtc': dt.datetime.now(dt.timezone.utc).isoformat(),
        'Ok': all(x['Ok'] for x in results), 'CheckCount': sum(x.get('CheckCount', 0) for x in results),
        'Tests': results,
        'Contracts': {
            'ProtocolPreparation': {'Udp': {'ServerPreparation': 'Pending/Inspecting/NotConfigured/Configured/Failed/OutcomeUnknown',
                                           'LocalPreparation': 'Missing/SyntaxValidated', 'Error': 'null or {Code,Message}'},
                                    'Tcp': 'same fields as Udp'},
            'ValidationProfiles': {'Udp': {'PathValidation': 'NotTested/CurrentEnvironmentPassed/Failed/Inconclusive'}, 'Tcp': 'same fields as Udp'},
            'CloudRuleList': '[{Purpose:SSH|UDP|TCP,Protocol:tcp|udp,Port:int,Evidence:NotInspected,ServerName?:selected TCP target}]',
            'RecommendedProfileId': 'null/Udp/Tcp',
            'LineApis': ['Register-TCLineProfiles -Root -Id', 'Prepare-TCTcpLineProfile -Root -Id -TransportInfo', 'Get-TCLineProfile -Root -Id -ProfileId Udp/Tcp'],
            'CandidateProbe': 'optional -ProfileId Udp/Tcp; sequential, cleanup barrier, existing active identity guard',
            'NewReadOnlyBackendActions': {'transport_candidates': ['ServerPublicKey','ServerName','CandidatePorts'], 'transport_options': ['ServerPublicKey','ServerName','CandidatePorts','CandidateServerNames'], 'deployment_state': ['ClientPublicKey','ServerPublicKey']},
            'TransportOptions': {'SelectedServerName': 'selected certificate-verified target or null',
                                 'HandshakeValidation': 'TlsEndpointReachable/Failed/NotTested',
                                 'FailureReasons': 'HandshakeChecks[].ErrorCode',
                                 'DefaultChoices': ['www.bing.com','www.microsoft.com'], 'CustomChoices': 'requested domain only',
                                 'TotalBudgetSeconds': 8, 'PerAttemptBudgetSeconds': 4,
                                 'Approval': 'exact ordered CandidateServerNames persisted in Review.OptionalTcpPreparation and ApprovedTransportChoices; legacy approval keeps only original target',
                                 'ValidationLayer': 'TLS endpoint certificate/hostname/SNI on outbound 443; never claims Reality authentication'},
            'Pairing': 'Strict V1 wire unchanged. Existing signed ClientResponse.Transport negotiates Tcp; local ConnectionBundle v1 re-verifies and binds original signed V1 authorization.',
            'StopTransaction': 'Durable Prepared intent before executor cancellation; original dispatch ID and snapshot retained; never interpreted as remote rollback.',
        },
        'WriteScope': [{'Path': 'releases/0.11.0/'+name, 'SHA256': hashlib.sha256((PACKAGE/name).read_bytes()).hexdigest()} for name in CHANGED],
        'ExcludedWriteScope': ['UI', 'RuntimeBridge', 'Worker', 'LineStore', 'AutoTransport'],
        'SafetyEvidence': {'DataRoots': 'unique package deployment/test-runs roots; ServerSetup private temporary test root',
                           'ProgramDataTouched': False, 'TradechannelRootTouched': False,
                           'RealSshUsed': False, 'LocalNetworkUsed': False, 'TunnelStarted': False,
                           'ProfilePublishing': 'real LineStore, real wg genkey/pubkey and sing-box check; no stubbed profile publication'},
        'NotExecuted': [
            {'Test': 'Test-DeployTransport.ps1', 'Reason': 'Starts loopback SSH networking; prohibited by task scope.'},
            {'Test': 'test_candidate_local_e2e.py / live path and cloud acceptance', 'Reason': 'Would use networking; no SSH host/cloud account/real interface used.'},
        ],
        'CompatibilityProbe': {'Runtime': 'PowerShell 7', 'Ok': False, 'AcceptanceRuntime': False,
                               'Reason': 'Observed pre-existing NodeStore V1 reader rejecting ConvertFrom-Json Int64 schemaVersion; packaged Windows PowerShell 5.1 acceptance is tested above.'},
        'IntegrationNotes': ['Advanced Linux entry should call the same deployment core; no independent Auto installation path was added.',
                             'Healthy UDP-only transport_options performs bounded remote certificate-verified TLS prechecks. Existing TCP is preserved without a replacement probe; its HandshakeValidation remains NotTested.',
                             'No download version, URL or integrity pin changed. No automatic cloud-rule mutation.',
                             'Preview package manifest/hash regeneration remains with shared-release packaging; this report binds tested sources and compiled DeployHost.'],
    }
    if incremental:
        report['HandshakePrecheckIncrement'] = {'GeneratedAtUtc': report['GeneratedAtUtc'], 'PreviousReportGeneratedAtUtc': previous['GeneratedAtUtc'],
                                              'PreviousCheckCount': previous['CheckCount'], 'NewChecks': report['CheckCount']-previous['CheckCount'],
                                              'Ok': all(x['Ok'] for x in increment_results), 'Tests': increment_results,
                                              'UnchangedTests': [x['Name'] for x in previous['Tests'] if x['Name'] not in {y['Name'] for y in increment_results}],
                                              'Scope': 'transport_options/OS TLS adapter, exact approval/plan/cloud wiring, offline fixtures and DeployHost allowlist build only'}
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    REPORT.write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    print(json.dumps({'Report': str(REPORT), 'Ok': report['Ok'], 'CheckCount': report['CheckCount']}), flush=True)
    return 0 if report['Ok'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
