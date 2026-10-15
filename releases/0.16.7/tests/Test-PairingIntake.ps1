#requires -Version 5.1
[CmdletBinding()]param([string]$PackageRoot,[string]$TestOutputDirectory='')
$ErrorActionPreference='Stop'
if(-not $PackageRoot){$PackageRoot=Split-Path $PSScriptRoot -Parent}

# Also imported by the WPF test by AST; test fixtures never read the installed store.
function New-PairIntakeFixture {
 param([string]$PackageRoot,[string]$FixtureRoot)
 Import-Module (Join-Path $PackageRoot 'DeploymentPairing.psm1') -Force -DisableNameChecking
 $pairModule=Get-Module DeploymentPairing;& $pairModule {Initialize-TCPairCrypto}
 $wg=Join-Path $PackageRoot 'assets\wg.exe'
 $clientModule=Import-Module (Join-Path $PackageRoot 'ServerSetup.psm1') -PassThru -DisableNameChecking
 $serverKeys=& $clientModule {param($Path) New-TCKeyPair $Path} $wg
 $private=[TradeChannel.Deployment.PairCrypto]::NewPrivateKey();$jwk=[TradeChannel.Deployment.PairCrypto]::PublicJwk($private)|ConvertFrom-Json
 $fingerprint=[TradeChannel.Deployment.PairCrypto]::Fingerprint(($jwk|ConvertTo-Json -Compress))
 $owner=[guid]::NewGuid().ToString();$node=[guid]::NewGuid().ToString();$inviteId=[guid]::NewGuid().ToString()
 $inviteBody=[ordered]@{SchemaVersion=1;Kind='TradeChannel.PairInvite';InviteId=$inviteId;RemoteOwnerId=$owner;NodeId=$node;ServerPublicKey=$serverKeys.Public;ManagementSigningPublicKey=$jwk;PublicEndpoint='1.1.1.1:51820';IssuedAtUtc=[DateTime]::UtcNow.ToString('o');ExpiresAtUtc=[DateTime]::UtcNow.AddHours(24).ToString('o');Capabilities=@('authorize_external')}
 $invite=[TradeChannel.Deployment.PairCrypto]::Sign(($inviteBody|ConvertTo-Json -Depth 24 -Compress),$private)
 $created=New-TCPairRequest -Invite $invite -ConfirmedFingerprint $fingerprint -DeviceName '隔离新电脑' -Root $FixtureRoot -WgPath $wg
 $requestInfo=Get-TCPairRequestInfo -PairRequest $created.PairRequest;$request=$requestInfo.Payload.ClientRequest
 $response=[ordered]@{SchemaVersion=1;Kind='TradeChannel.ClientResponse';Status='Authorized';RequestId=$request.RequestId;DeviceId=$request.DeviceId;NodeId=$node;NodeName='隔离测试服务器';ClientPublicKey=$request.ClientPublicKey;ClientAddress='10.78.0.2/32';ServerPublicKey=$serverKeys.Public;PublicEndpoint='1.1.1.1:51820';TunnelSubnet='10.78.0.0/24';ServerAddress='10.78.0.1/24';AllowedIPs=@('0.0.0.0/0');PersistentKeepalive=25;AddressFamilies=@('IPv4');ConfigRevision=1;MTU=1380;Validation=@{LocalAuthorization='Verified';CloudFirewall='NotVerified';Handshake='NotTested';ExternalConnectivity='NotTested'};Transport=@{Type='tcp-reality';Server='1.1.1.1';Port=8443;ServerName='www.bing.com';Uuid='aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';RealityPublicKey=('A'*43);RealityShortId='1234567890abcdef'}}
 $authorization=[ordered]@{SchemaVersion=1;Kind='TradeChannel.PairAuthorization';InviteId=$inviteId;ServerBinding=$requestInfo.Payload.ServerBinding;RemoteOwnerId=$owner;NodeId=$node;DeviceId=$request.DeviceId;ClientPublicKey=$request.ClientPublicKey;ClientAddress=$response.ClientAddress;ConfigRevision=1;ClientResponse=$response;IssuedAtUtc=[DateTime]::UtcNow.ToString('o');ExpiresAtUtc=[DateTime]::UtcNow.AddDays(7).ToString('o');RequestDigest=$created.RequestDigest;RequestDigestAlgorithm='TC-ClientRequest-v1';RequestId=$request.RequestId}
 $signed=[TradeChannel.Deployment.PairCrypto]::Sign(($authorization|ConvertTo-Json -Depth 24 -Compress),$private)
 $grant=(Protect-TCPairAuthorization -SignedAuthorization $signed -PairRequest $created.PairRequest -Invite $invite).EncryptedAuthorization
 $serverKeys=$null
 [pscustomobject]@{Invite=$invite;InviteBody=$inviteBody;Created=$created;RequestInfo=$requestInfo;Response=$response;Authorization=$authorization;Signed=$signed;Grant=$grant;ServerPrivate=$private;ServerJwk=$jwk;Fingerprint=$fingerprint;Wg=$wg;Root=$FixtureRoot}
}
function Assert-PairIntake {param([bool]$Condition,[string]$Name)if(-not $Condition){throw ('Pair intake FAILED: '+$Name)};$script:Checks.Add($Name)}
function Assert-PairIntakeReject {param([scriptblock]$Action,[string]$Name,[string]$Code='')
 $rejected=$false;try{& $Action|Out-Null}catch{$rejected=(-not $Code -or $_.Exception.Message.Contains('[TC:'+$Code+']'))}
 Assert-PairIntake $rejected $Name
}
function Copy-PairFixture {param($Value) return ($Value|ConvertTo-Json -Depth 24 -Compress|ConvertFrom-Json)}
function Sign-PairFixture {param($Value,[string]$Key) return [TradeChannel.Deployment.PairCrypto]::Sign(($Value|ConvertTo-Json -Depth 24 -Compress),$Key)}
function Start-PairV2Fixture {
 param([string]$PackageRoot,[string]$Directory)
 # MemoryFS/fake kernel isolate all installation paths. Only HTTP/TLS boundary is mocked
 # for the new evidence path: real LinuxOS.direct_https/network_probe + real status and OpenSSL.
 $python=@'
import copy, importlib.util, json, os, sys, types
from pathlib import Path
from unittest import mock
root = Path(sys.argv[1])
sys.path.insert(0, str(root / 'tests'))
spec = importlib.util.spec_from_file_location('pair_v2_fixture', root / 'tests' / 'test_tcp_backend.py')
fixture = importlib.util.module_from_spec(spec); spec.loader.exec_module(fixture)
tc, mg = fixture.tc, fixture.tc.management
fs = fixture.base.MemoryFS(); kernel = fixture.TcpOS(fs)
kernel.guard = lambda: tc.require(isinstance(kernel.fs, fixture.base.MemoryFS), 'FixtureOnly')
kernel.network_probe = types.MethodType(tc.LinuxOS.network_probe, kernel)
kernel.direct_https = types.MethodType(tc.LinuxOS.direct_https, kernel)
kernel.peer_telemetry = types.MethodType(tc.LinuxOS.peer_telemetry, kernel)
kernel.forward_route = types.MethodType(tc.LinuxOS.forward_route, kernel)
openssl = '/usr/bin/openssl' if os.name == 'posix' else r'C:\Program Files\Git\usr\bin\openssl.exe'
b = tc.Backend(fs, kernel, management_crypto=mg.OpenSSLCrypto(openssl), progress=lambda _: None)
p = fixture.base.plan_input(); p['PublicEndpoint'] = '1.1.1.1:51820'
plan = b.plan(p); b.apply({'PlanId': plan['PlanId']})
prepared = b.execute('management_plan', {})
b.execute('management_apply', {'PlanId': prepared['PlanId'], 'ApprovedChangeDigest': prepared['ChangeDigest']})
transport = b.execute('transport_plan', {'Transport': {'Type': 'tcp-reality', 'Port': 8443, 'ServerName': 'www.bing.com'}})
b.execute('transport_apply', {'PlanId': transport['PlanId'], 'ApprovedChangeDigest': transport['ChangeDigest']})
mode, calls = 'Verified', []
class HttpBoundary:
    def __init__(self, *args):
        index = len(calls); calls.append(mode)
        self.peer = None
        address = '8.8.4.4' if mode == 'Inconsistent' and index % 2 else '8.8.8.8'
        if mode == 'Private': address = '10.0.0.1'
        body = ('ip=' + address + '\ncolo=FIXTURE\n').encode('ascii') if mode != 'Missing' else b'colo=FIXTURE\n'
        status = b'503 Unavailable' if mode == 'HttpFailed' else b'200 OK'
        self.data = b'HTTP/1.1 ' + status + b'\r\nContent-Length: ' + str(len(body)).encode() + b'\r\n\r\n' + body
    def settimeout(self, seconds): assert 0 < seconds <= 6
    def connect(self, peer): assert peer == ('1.1.1.1', 443); self.peer = peer
    def getsockname(self): return ('172.31.0.2', 43000)
    def sendall(self, request): assert self.peer and request.startswith(b'GET /cdn-cgi/trace HTTP/1.1\r\n')
    def recv(self, count): value, self.data = self.data[:count], self.data[count:]; return value
    def close(self): pass
    def bind(self, *args): raise AssertionError('No listeners/capture/relay in evidence path')
def tls_wrap(stream, server_hostname):
    assert server_hostname == '1.1.1.1'
    if mode == 'TlsFailed': raise tc.ssl.SSLCertVerificationError('Fixture untrusted certificate')
    return stream
context = mock.Mock(); context.wrap_socket.side_effect = tls_wrap
for line in sys.stdin:
    try:
        v = tc.parse_json(line, limit=tc.MAX_INPUT); action, value = v['Action'], v.get('Input', {})
        mode = v.get('HttpMode', 'Verified'); calls.clear()
        before = list(kernel.calls); before_peers = b.read_json(tc.MANIFEST)['Peers']
        with mock.patch.object(tc.socket, 'socket', side_effect=HttpBoundary), mock.patch.object(tc.ssl, 'create_default_context', return_value=context):
            if action == 'FixtureSign':
                private, _ = mg.Manager(b).signing(); data = {'Authorization': mg.sign_jws(b.management_crypto, private, value)}
            elif action == 'FixtureTrace':
                snapshot = copy.deepcopy(fs.files); env, owner, manifest, _ = mg.Manager(b).context()
                trace = mg.Manager(b).exit_trace(owner, manifest)
                assert snapshot == fs.files
                data = {'Trace': trace, 'FilesUnchanged': True}
            else:
                data = b.execute(action, value)
        data = dict(data)
        data['Fixture'] = {'HttpCalls': len(calls), 'PeersBefore': len(before_peers), 'PeersAfter': len(b.read_json(tc.MANIFEST)['Peers']),
                           'ServiceRestarted': any(cmd[:2] in (['systemctl', 'restart'], ['wg-quick', 'up'], ['wg-quick', 'down']) for cmd in kernel.calls[len(before):]),
                           'ManifestRevision': b.read_json(tc.MANIFEST)['ConfigRevision']}
        response = {'Ok': True, 'Data': data}
    except Exception as exc:
        response = {'Ok': False, 'Data': {'Code': getattr(exc, 'code', 'FixtureFailure')}, 'Message': 'Isolated server fixture failed.'}
    sys.stdout.write(json.dumps(response, separators=(',', ':')) + '\n'); sys.stdout.flush()
'@
 $path=Join-Path $Directory 'pair-v2-http-fixture.py';[IO.File]::WriteAllText($path,$python,(New-Object Text.UTF8Encoding($true)))
 $start=New-Object Diagnostics.ProcessStartInfo;$start.FileName='python.exe';$start.Arguments='-u "'+$path+'" "'+[IO.Path]::GetFullPath($PackageRoot)+'"';$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
 $process=New-Object Diagnostics.Process;$process.StartInfo=$start;$null=$process.Start();return $process
}
function Invoke-PairV2Fixture {
 param($Process,[string]$Action,$InputData=@{},[string]$HttpMode='Verified')
 $Process.StandardInput.WriteLine((@{Action=$Action;Input=$InputData;HttpMode=$HttpMode}|ConvertTo-Json -Depth 24 -Compress));$Process.StandardInput.Flush();$line=$Process.StandardOutput.ReadLineAsync()
 if(-not $line.Wait(30000)){throw ('Bounded V2 fixture timeout: '+$Action)}
 if(-not $line.Result){throw ('V2 fixture exited before '+$Action)}
 $result=$line.Result|ConvertFrom-Json
 if(-not $result.Ok){throw ('V2 fixture '+$Action+' failed: '+$result.Data.Code)}
 return $result.Data
}
function Test-PairV2CandidateIntake {
 param([string]$PackageRoot,[string]$Root,$Enrollment,$EncryptedGrant,$VerifiedBundle,$ServerProcess,[string]$InviteId)
 # Capture at the network comparison driver entry and abort before path preparation, TUN,
 # sockets, HTTP or public DNS. Real intake/materialization/signature/inspection logic runs.
 Import-Module (Join-Path $PackageRoot 'DeploymentStore.psm1') -DisableNameChecking
 Import-Module (Join-Path $PackageRoot 'ProtocolComparison.psm1') -DisableNameChecking
 Import-Module (Join-Path $PackageRoot 'NodeStore.psm1') -DisableNameChecking
 Import-Module (Join-Path $PackageRoot 'LineStore.psm1') -DisableNameChecking
 $boundary=Get-Module ProtocolComparison
 & $boundary {
  $script:PairIntakeOriginalComparison=${function:Invoke-TCProtocolComparison}
  $script:PairIntakeProbeCalls=New-Object 'Collections.Generic.List[object]'
  function script:Invoke-TCProtocolComparison {
   [CmdletBinding()]param([string]$Root,[string]$NodeId,[string]$ExpectedExitIPv4,[string]$ExpectedExitSource,[string]$CancellationPath,[int]$TimeoutSeconds=360,[int]$InterfaceIndex=0,[scriptblock]$ProgressCallback)
   $script:PairIntakeProbeCalls.Add([pscustomobject]@{Root=$Root;NodeId=$NodeId;ExpectedExitIPv4=$ExpectedExitIPv4;ExpectedExitSource=$ExpectedExitSource;CancellationPath=$CancellationPath;InterfaceIndex=$InterfaceIndex;PublicNetworkAttempted=$false})
   throw '[TC:OfflineProbeBoundary] Comparison dispatch captured before network/path preparation; no probe result is fabricated.'
  }
 }
 try{
  $program=Join-Path $Root 'NinjaTrader.exe';Copy-Item -LiteralPath (Join-Path $PackageRoot 'assets\wg.exe') -Destination $program
  $inspection=[pscustomobject]@{EngineStaged=$true;WgHelperStaged=$true;ExistingDeployment=$false;NinjaTraderPaths=@($program);DirectDnsIPv4=@('9.9.9.9')}
  $beforeNodes=@(Get-TCNodes -Root (Join-Path $Root 'Product')).Count
  $first=Complete-TCPairCandidate -Root $Root -EnrollmentId $Enrollment.EnrollmentId -EncryptedAuthorization $EncryptedGrant -Name 'V2 actual candidate intake' -ClientInspection $inspection
  $run=Get-TCDeploymentRun -Root $Root -RunId $Enrollment.EnrollmentId;$line=Get-TCLine -Root $Root -Id $first.Id
  $calls=@(& $boundary {$script:PairIntakeProbeCalls.ToArray()})
  Assert-PairIntake ($run.ExpectedExitIPv4 -ceq $VerifiedBundle.ExitEvidence.ObservedExitIPv4 -and $run.ExpectedExitSource -ceq 'ServerVerifiedTlsTrace' -and $run.ConnectionBundle.ContractVersion -eq 2) 'Real Complete-TCPairCandidate consumes full verified V2 bundle for trusted expected exit without a nonexistent Verified flag'
  Assert-PairIntake ($calls.Count -eq 1 -and $calls[0].NodeId -ceq $first.Id -and $calls[0].Root -ceq $Root -and $calls[0].ExpectedExitIPv4 -ceq $VerifiedBundle.ExitEvidence.ObservedExitIPv4 -and $calls[0].ExpectedExitSource -ceq 'ServerVerifiedTlsTrace' -and -not $calls[0].PublicNetworkAttempted) 'Verified V2 automatically schedules independent comparison with bound exit and intercepts it before any public network/TUN operation'
  Assert-PairIntake ($run.ProfileProbeState -ceq 'Interrupted' -and -not $run.RecommendedProfileId -and $run.AttentionRequired) 'Captured offline probe leaves actionable incomplete checks and never fabricates a recommendation'
  Assert-PairIntake (($run.Programs -join '|') -ceq ($inspection.NinjaTraderPaths -join '|') -and $run.DirectDns -ceq '9.9.9.9' -and $line.Profiles.Count -eq 2 -and @(Get-TCNodes -Root (Join-Path $Root 'Product')).Count -eq ($beforeNodes+1)) 'ClientInspection programs/DNS reach real persisted V2 UDP/TCP candidate while publishing exactly one line'
  $udp=Get-TCLineProfile -Root $Root -Id $first.Id -ProfileId Udp;$manifest=Read-TCDJson $udp.ManifestPath
  Assert-PairIntake (($manifest.TradeProgramPaths -join '|') -ceq ($inspection.NinjaTraderPaths -join '|') -and $manifest.DirectDns -ceq '9.9.9.9') 'Actual candidate manifest retains the matching inspected program and DNS rather than empty Pairing defaults'
  Assert-PairIntake (-not $run.ConnectionBundle.PSObject.Properties['Source'] -and -not $run.ConnectionBundle.PSObject.Properties['SignedAuthorization'] -and -not $run.ConnectionBundle.PSObject.Properties['ExitEvidence'] -and $run.ConnectionBundle.ProtectedPath) 'Persisted deployment bundle remains public metadata summary without copying full signed/private bundle or evidence fields'
  $second=Complete-TCPairCandidate -Root $Root -EnrollmentId $Enrollment.EnrollmentId -EncryptedAuthorization $EncryptedGrant -Name 'V2 actual candidate intake' -ClientInspection $inspection
  $again=Get-TCDeploymentRun -Root $Root -RunId $Enrollment.EnrollmentId
  $peerRetry=Invoke-PairV2Fixture $ServerProcess authorize_external @{InviteId=$InviteId;PairRequest=$Enrollment.PairRequest}
  Assert-PairIntake ($second.Id -ceq $first.Id -and $again.RunId -ceq $run.RunId -and $again.ClientRequest.RequestId -ceq $Enrollment.RequestId -and @(Get-TCNodes -Root (Join-Path $Root 'Product')).Count -eq ($beforeNodes+1) -and $peerRetry.Fixture.PeersAfter -eq $peerRetry.Fixture.PeersBefore -and $peerRetry.Fixture.HttpCalls -eq 0) 'Repeated original real V2 grant preserves one device, one candidate line and original request without another Peer or server trace'
 }finally{
  & $boundary {${function:Invoke-TCProtocolComparison}=$script:PairIntakeOriginalComparison;Remove-Variable PairIntakeOriginalComparison,PairIntakeProbeCalls -Scope Script -ErrorAction SilentlyContinue}
 }
}

$script:Checks=New-Object 'Collections.Generic.List[string]'
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('tc-pair-intake-'+[guid]::NewGuid().ToString('N'))
$v2Process=$null
try{
 $f=New-PairIntakeFixture -PackageRoot $PackageRoot -FixtureRoot $testRoot
 foreach($row in @(@($f.Invite,'Invite','Client','JWS'),@($f.Created.PairRequest,'Request','Manager','JWS'),@($f.Grant,'Grant','Client','JWE'))){
  $info=Get-TCPairMaterialKind -Material (" `r`n"+$row[0]+"`r`n ")
  Assert-PairIntake ($info.Kind -ceq $row[1] -and $info.RequiredRole -ceq $row[2] -and $info.Format -ceq $row[3] -and $info.CanProcess -and -not $info.Trusted -and $info.Verification -ceq 'Unverified') ('Bounded '+$row[1]+' routing is explicitly unverified')
 }
 foreach($row in @(@('Invite',$f.Invite),@('PairRequest',$f.Created.PairRequest),@('EncryptedAuthorization',$f.Grant))){
  $wrapped=@{};$wrapped[$row[0]]=$row[1];$wrapped.Status='LocalFixture';$info=Get-TCPairMaterialKind -Material ($wrapped|ConvertTo-Json -Compress)
  Assert-PairIntake ($info.JsonWrapper -and $info.CanProcess -and $info.Material -ceq $row[1] -and -not $info.Trusted) ('JSON '+$row[0]+' wrapper unwraps without trusting it')
 }
 $unsigned=Get-TCPairMaterialKind -Material ($f.InviteBody|ConvertTo-Json -Depth 24 -Compress)
 Assert-PairIntake ($unsigned.Kind -ceq 'Invite' -and -not $unsigned.CanProcess) 'Unsigned JSON cannot become a trusted invitation'
 $ambiguous=Get-TCPairMaterialKind -Material (@{Invite=$f.Invite;PairRequest=$f.Created.PairRequest}|ConvertTo-Json -Compress)
 Assert-PairIntake ($ambiguous.Kind -ceq 'Unknown' -and -not $ambiguous.CanProcess) 'Conflicting JSON envelopes do not choose an arbitrary role'
 Assert-PairIntake ((Get-TCPairMaterialKind -Material $f.Signed).Reason -ceq 'EncryptedGrantRequired') 'Plain signed authorization is not an encrypted grant'
 Assert-PairIntake ((Get-TCPairMaterialKind -Material 'ABCD1234').Kind -ceq 'Unknown') 'Offline intake never invents an online short-code exchange'
 Assert-PairIntake ((Get-TCPairMaterialKind -Material ('{"Invite":'+('['*30))).Kind -ceq 'Unknown') 'Malformed and deeply nested JSON does not dispatch work'
 Assert-PairIntakeReject {Get-TCPairMaterialKind -Material ('x'*131073)} 'Text above 128 KiB rejected' PairingTooLarge
 Assert-PairIntakeReject {Get-TCPairMaterialKind -Material ('中'*50000)} 'UTF-8 byte limit applies to multibyte text' PairingTooLarge
 $file=Join-Path $testRoot 'explicit.tcgrant';[IO.File]::WriteAllText($file,$f.Grant,(New-Object Text.UTF8Encoding($true)))
 Assert-PairIntake ((Get-TCPairMaterialKind -Path $file).Material -ceq $f.Grant) 'Explicit UTF-8 BOM file opens as actual grant bytes'
 [IO.File]::WriteAllText($file,('x'*131073),(New-Object Text.UTF8Encoding($false)))
 Assert-PairIntakeReject {Get-TCPairMaterialKind -Path $file} 'Oversized file rejected before parsing' PairingTooLarge
 [IO.File]::WriteAllBytes($file,[byte[]]@(255,255));Assert-PairIntakeReject {Get-TCPairMaterialKind -Path $file} 'Invalid UTF-8 file rejected' InvalidPairing

 $parts=$f.Invite.Split('.');$parts[2]=if($parts[2][0] -ceq 'A'){'B'+$parts[2].Substring(1)}else{'A'+$parts[2].Substring(1)};$tampered=$parts -join '.'
 Assert-PairIntake ((Get-TCPairMaterialKind -Material $tampered).Kind -ceq 'Invite') 'Classification cannot certify a tampered signature'
 Assert-PairIntakeReject {Get-TCPairInvite -Invite $tampered -AllowUnconfirmed} 'Tampered invitation rejected by actual RSA verification' InvalidInvite
 Assert-PairIntakeReject {New-TCPairRequest -Invite $f.Invite -ConfirmedFingerprint ('SHA256:'+('A'*43)) -Root $testRoot -WgPath $f.Wg} 'First invitation still requires trusted source confirmation' InviteTrustRequired
 $parts=$f.Invite.Split('.');$parts[0]=[TradeChannel.Deployment.PairCrypto]::B64([Text.Encoding]::UTF8.GetBytes('{"alg":"none"}'))
 Assert-PairIntake (-not (Get-TCPairMaterialKind -Material ($parts -join '.')).CanProcess) 'JWS algorithm downgrade does not dispatch'
 $bad=Copy-PairFixture $f.InviteBody;$bad|Add-Member NoteProperty Unsupported $true
 Assert-PairIntakeReject {Get-TCPairInvite -Invite (Sign-PairFixture $bad $f.ServerPrivate) -AllowUnconfirmed} 'Even signed invitation with extra fields rejected'
 $bad=Copy-PairFixture $f.InviteBody;$binding=Copy-PairFixture $f.RequestInfo.Payload.ServerBinding;$binding|Add-Member NoteProperty Unsupported $true;$bad|Add-Member NoteProperty ServerBinding $binding
 Assert-PairIntakeReject {Get-TCPairInvite -Invite (Sign-PairFixture $bad $f.ServerPrivate) -AllowUnconfirmed} 'Signed invitation rejects extra nested server binding keys'
 $bad=Copy-PairFixture $f.RequestInfo.Payload;$bad.ServerBinding.NodeId=[guid]::NewGuid().ToString()
 $pairModule=Get-Module DeploymentPairing;$identityDir=Join-Path (Join-Path $testRoot 'identities') $f.Created.EnrollmentId
 $recipientPrivate=& $pairModule {param($Path) $secret=Read-TCPairState $Path;(ConvertFrom-TCPairJson (Unprotect-TCPairPrivate $secret.Protected)).RecipientPrivateKey} (Join-Path $identityDir 'private.dpapi.json')
 $wrongTargetRequest=Sign-PairFixture $bad $recipientPrivate
 Assert-PairIntakeReject {Protect-TCPairAuthorization -SignedAuthorization $f.Signed -PairRequest $wrongTargetRequest -Invite $f.Invite} 'Signed request aimed at another server cannot receive authorization'
 $retry=New-TCPairRequest -Invite $f.Invite -ConfirmedFingerprint $f.Fingerprint -Root $testRoot -WgPath $f.Wg
 Assert-PairIntake ($retry.EnrollmentId -ceq $f.Created.EnrollmentId -and $retry.DeviceId -ceq $f.Created.DeviceId) 'Retry and lost reply keep original enrollment and device'
 $lock=[IO.File]::Open((Join-Path $testRoot '.pair-enrollment.lock'),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
 try{Assert-PairIntakeReject {New-TCPairRequest -Invite $f.Invite -ConfirmedFingerprint $f.Fingerprint -Root $testRoot -WgPath $f.Wg} 'Concurrent creation cannot allocate a duplicate device' PairingBusy}finally{$lock.Dispose()}
 $enrollmentPath=Join-Path $identityDir 'enrollment.json';$original=Get-TCPairEnrollment -Root $testRoot -EnrollmentId $f.Created.EnrollmentId
 $changed=Copy-PairFixture $original;$changed.ClientRequest.DeviceId=[guid]::NewGuid().ToString()
 & $pairModule {param($Path,$Value) Write-TCPairState $Path $Value -Replace} $enrollmentPath $changed
 Assert-PairIntakeReject {Get-TCPairEnrollment -Root $testRoot -EnrollmentId $f.Created.EnrollmentId} 'Persisted enrollment cannot swap exact original device keys' EnrollmentMismatch
 & $pairModule {param($Path,$Value) Write-TCPairState $Path $Value -Replace} $enrollmentPath $original
 $changed=Copy-PairFixture $original;$changed|Add-Member NoteProperty CredentialRef 'must-never-be-read'
 & $pairModule {param($Path,$Value) Write-TCPairState $Path $Value -Replace} $enrollmentPath $changed
 Assert-PairIntakeReject {Get-TCPairEnrollment -Root $testRoot -EnrollmentId $f.Created.EnrollmentId} 'Enrollment rejects added credential or extension fields'
 & $pairModule {param($Path,$Value) Write-TCPairState $Path $Value -Replace} $enrollmentPath $original

 $past=Copy-PairFixture $f.InviteBody;$past.IssuedAtUtc=[DateTime]::UtcNow.AddDays(-2).ToString('o');$past.ExpiresAtUtc=[DateTime]::UtcNow.AddDays(-1).ToString('o');$expiredInvite=Sign-PairFixture $past $f.ServerPrivate
 Assert-PairIntakeReject {New-TCPairRequest -Invite $expiredInvite -ConfirmedFingerprint $f.Fingerprint -Root $testRoot -WgPath $f.Wg} 'Expired invitation cannot create a new enrollment' InviteExpired
 $historic=Copy-PairFixture $original;$historic.Invite=$expiredInvite
 & $pairModule {param($Path,$Value) Write-TCPairState $Path $Value -Replace} $enrollmentPath $historic
 Assert-PairIntake ((Resolve-TCPairEnrollment -Root $testRoot -EncryptedAuthorization $f.Grant).EnrollmentId -ceq $f.Created.EnrollmentId) 'Invitation expiry does not strand the already trusted original request'
 & $pairModule {param($Path,$Value) Write-TCPairState $Path $Value -Replace} $enrollmentPath $original

 $resolved=Resolve-TCPairEnrollment -Root $testRoot -EncryptedAuthorization $f.Grant
 Assert-PairIntake ($resolved.EnrollmentId -ceq $f.Created.EnrollmentId -and $resolved.Verification -ceq 'Verified' -and $resolved.RequestId -ceq $original.ClientRequest.RequestId -and -not [IO.File]::Exists((Join-Path $identityDir 'client.conf'))) 'Grant cryptographically resumes original enrollment without creating config'
 $bad=Copy-PairFixture $f.Authorization;$bad.ServerBinding|Add-Member NoteProperty Unsupported $true;$badSigned=Sign-PairFixture $bad $f.ServerPrivate
 $badGrant=[TradeChannel.Deployment.PairCrypto]::Encrypt($badSigned,($f.RequestInfo.Payload.RecipientJwk|ConvertTo-Json -Compress))
 Assert-PairIntakeReject {Resolve-TCPairEnrollment -Root $testRoot -EnrollmentId $f.Created.EnrollmentId -EncryptedAuthorization $badGrant} 'Signed grant rejects extra nested target binding keys' InvalidPairing
 $bad=Copy-PairFixture $f.Authorization;$bad.RequestId=[guid]::NewGuid().ToString();$badSigned=Sign-PairFixture $bad $f.ServerPrivate
 $badGrant=[TradeChannel.Deployment.PairCrypto]::Encrypt($badSigned,($f.RequestInfo.Payload.RecipientJwk|ConvertTo-Json -Compress))
 Assert-PairIntakeReject {Resolve-TCPairEnrollment -Root $testRoot -EnrollmentId $f.Created.EnrollmentId -EncryptedAuthorization $badGrant} 'Signed wrong outer RequestId rejected before candidate generation' AuthorizationMismatch
 $bad=Copy-PairFixture $f.Authorization;$bad.ClientPublicKey=('B'*43+'=');$badSigned=Sign-PairFixture $bad $f.ServerPrivate
 $badGrant=[TradeChannel.Deployment.PairCrypto]::Encrypt($badSigned,($f.RequestInfo.Payload.RecipientJwk|ConvertTo-Json -Compress))
 Assert-PairIntakeReject {Resolve-TCPairEnrollment -Root $testRoot -EnrollmentId $f.Created.EnrollmentId -EncryptedAuthorization $badGrant} 'Signed wrong device public key rejected' AuthorizationMismatch
 $bad=Copy-PairFixture $f.Authorization;$bad.ExpiresAtUtc=[DateTime]::UtcNow.AddSeconds(-1).ToString('o');$badSigned=Sign-PairFixture $bad $f.ServerPrivate
 $badGrant=[TradeChannel.Deployment.PairCrypto]::Encrypt($badSigned,($f.RequestInfo.Payload.RecipientJwk|ConvertTo-Json -Compress))
 Assert-PairIntakeReject {Resolve-TCPairEnrollment -Root $testRoot -EnrollmentId $f.Created.EnrollmentId -EncryptedAuthorization $badGrant} 'Expired grant requires manager to refresh original response' AuthorizationExpired
 $wrongSigner=[TradeChannel.Deployment.PairCrypto]::NewPrivateKey();$badGrant=[TradeChannel.Deployment.PairCrypto]::Encrypt((Sign-PairFixture $f.Authorization $wrongSigner),($f.RequestInfo.Payload.RecipientJwk|ConvertTo-Json -Compress))
 Assert-PairIntakeReject {Resolve-TCPairEnrollment -Root $testRoot -EnrollmentId $f.Created.EnrollmentId -EncryptedAuthorization $badGrant} 'Decryptable grant from another signer cannot replace pinned server' InvalidAuthorization
 $parts=$f.Grant.Split('.');$parts[4]=if($parts[4][0] -ceq 'A'){'B'+$parts[4].Substring(1)}else{'A'+$parts[4].Substring(1)}
 Assert-PairIntakeReject {Resolve-TCPairEnrollment -Root $testRoot -EncryptedAuthorization ($parts -join '.')} 'Tampered JWE tag cannot resume any original enrollment' EnrollmentMismatch

 # A second invitation creates new keys. Auto grant matching must not select the newest device.
 $secondInvite=Copy-PairFixture $f.InviteBody;$secondInvite.InviteId=[guid]::NewGuid().ToString()
 $second=New-TCPairRequest -Invite (Sign-PairFixture $secondInvite $f.ServerPrivate) -ConfirmedFingerprint $f.Fingerprint -Root $testRoot -WgPath $f.Wg
 $secondInfo=Get-TCPairRequestInfo -PairRequest $second.PairRequest
 Assert-PairIntake ($secondInfo.Payload.ClientRequest.ClientPublicKey -cne $original.ClientRequest.ClientPublicKey -and $second.DeviceId -cne $f.Created.DeviceId -and ($secondInfo.Payload.RecipientJwk.n -cne $f.RequestInfo.Payload.RecipientJwk.n)) 'New client uses fresh WireGuard and RSA keys rather than another device private key'
 Assert-PairIntake ((Resolve-TCPairEnrollment -Root $testRoot -EncryptedAuthorization $f.Grant).EnrollmentId -ceq $f.Created.EnrollmentId) 'Automatic matching chooses cryptographic original among multiple enrollments'
 Assert-PairIntakeReject {Resolve-TCPairEnrollment -Root $testRoot -EnrollmentId $second.EnrollmentId -EncryptedAuthorization $f.Grant} 'Explicit wrong enrollment cannot decrypt original grant' InvalidAuthorization
 $completed=Complete-TCPairAuthorization -Root $testRoot -EnrollmentId $f.Created.EnrollmentId -EncryptedAuthorization $f.Grant
 $resumed=Resume-TCPairAuthorization -Root $testRoot -EnrollmentId $f.Created.EnrollmentId
 Assert-PairIntake ($resumed.ConfigPath -ceq $completed.ConfigPath -and -not [IO.File]::Exists((Join-Path $identityDir 'client\client.key'))) 'Saved verified response resumes after a lost transfer without plaintext merge residue'
 Import-Module (Join-Path $PackageRoot 'DeploymentFlow.psm1') -DisableNameChecking
 Import-Module (Join-Path $PackageRoot 'LineStore.psm1') -DisableNameChecking
 $candidate=Complete-TCPairCandidate -Root $testRoot -EnrollmentId $f.Created.EnrollmentId -EncryptedAuthorization $f.Grant -Name '隔离配对线路'
 $again=Complete-TCPairCandidate -Root $testRoot -EnrollmentId $f.Created.EnrollmentId -Name '隔离配对线路'
 $line=Get-TCLine -Root $testRoot -Id $candidate.Id;$run=Get-TCDeploymentRun -Root $testRoot -RunId $f.Created.EnrollmentId
 Assert-PairIntake ($candidate.Id -ceq $again.Id -and $line.Profiles.Count -eq 2 -and -not $candidate.NetworkChanged -and @(Get-TCPairEnrollments -Root $testRoot).Count -eq 2) 'Real local backend publishes one UDP/TCP candidate and idempotently resumes it'
 Assert-PairIntake (-not $run.ExpectedExitIPv4 -and $run.ExpectedExitSource -cne 'ServerVerifiedTlsTrace') 'Missing trusted expected-exit evidence remains missing rather than forged'

 $v2Process=Start-PairV2Fixture -PackageRoot $PackageRoot -Directory $testRoot;$v2Errors=$v2Process.StandardError.ReadToEndAsync()
 $serverInvite=Invoke-PairV2Fixture $v2Process invite_create
 $trusted=Get-TCPairInvite -Invite $serverInvite.Invite -AllowUnconfirmed
 $v2Request=New-TCPairRequest -Invite $serverInvite.Invite -ConfirmedFingerprint $trusted.Fingerprint -Root $testRoot -WgPath $f.Wg -DeviceName 'V2 actual TLS boundary fixture'
 $v2RequestInfo=Get-TCPairRequestInfo $v2Request.PairRequest
 $authorized=Invoke-PairV2Fixture $v2Process authorize_external @{InviteId=$serverInvite.InviteId;PairRequest=$v2Request.PairRequest}
 $v2Body=& $pairModule {param($Signed,$Public) ConvertFrom-TCPairJson ([TradeChannel.Deployment.PairCrypto]::Verify($Signed,(ConvertTo-TCPairJson $Public)))} $authorized.Authorization $trusted.Payload.ManagementSigningPublicKey
 Assert-PairIntake ($v2Body.SchemaVersion -eq 2 -and $v2Body.ExitEvidence.Source -ceq 'ServerVerifiedTlsTrace' -and $v2Body.ExitEvidence.ObservedExitIPv4 -ceq '8.8.8.8' -and $v2Body.ExitEvidence.ObservedExitIPv4 -cne $trusted.Payload.PublicEndpoint.Split(':')[0]) 'Actual server status/direct TLS trace creates real OpenSSL signed V2 with observed egress rather than endpoint inference'
 Assert-PairIntake ($authorized.Fixture.HttpCalls -eq 2 -and $authorized.Fixture.PeersAfter -eq ($authorized.Fixture.PeersBefore+1) -and -not $authorized.Fixture.ServiceRestarted) 'V2 authorization adds only approved device and bounded readonly trace without service restart'
 $sealedV2=Protect-TCPairAuthorization -Invite $serverInvite.Invite -PairRequest $v2Request.PairRequest -SignedAuthorization $authorized.Authorization
 $verifiedV2=Resolve-TCPairEnrollment -Root $testRoot -EnrollmentId $v2Request.EnrollmentId -EncryptedAuthorization $sealedV2.EncryptedAuthorization
 Assert-PairIntake ($verifiedV2.EnrollmentId -ceq $v2Request.EnrollmentId -and $verifiedV2.Verification -ceq 'Verified') 'Real OpenSSL V2 crosses actual JWS/JWE to original trusted Windows enrollment'
 $completedV2=Complete-TCPairAuthorization -Root $testRoot -EnrollmentId $v2Request.EnrollmentId -EncryptedAuthorization $sealedV2.EncryptedAuthorization
 $bundleV2=Get-TCPairConnectionBundle -Root $testRoot -EnrollmentId $v2Request.EnrollmentId
 Assert-PairIntake ($bundleV2.ContractVersion -eq 2 -and $bundleV2.SignatureProtocol -ceq 'TradeChannel.PairAuthorization.V2' -and $bundleV2.Profiles.Udp.Id -ceq 'Udp' -and $bundleV2.Profiles.Tcp.Id -ceq 'Tcp' -and $bundleV2.ExitEvidence.RequestId -ceq $v2Request.RequestId -and $bundleV2.ExitEvidence.DeviceId -ceq $v2Request.DeviceId -and $bundleV2.ExitEvidence.ObservedExitIPv4 -ceq '8.8.8.8') 'Enrollment-verified V2 bundle preserves UDP/TCP and exposes only server-signed target/request/device-bound ExitEvidence'
 $v2Directory=Join-Path (Join-Path $testRoot 'identities') $v2Request.EnrollmentId;$v2BundlePath=Join-Path $v2Directory 'connection-bundle.dpapi.json'
 $tamperedBundle=Copy-PairFixture $bundleV2;$tamperedBundle.ExitEvidence.ObservedExitIPv4='8.8.4.4'
 & $pairModule {param($Path,$Bundle) Write-TCPairState $Path @{SchemaVersion=1;Kind='TradeChannel.ConnectionBundlePrivate';Protected=(Protect-TCPairPrivate (ConvertTo-TCPairJson $Bundle))} -Replace} $v2BundlePath $tamperedBundle
 Assert-PairIntakeReject {Get-TCPairConnectionBundle -Root $testRoot -EnrollmentId $v2Request.EnrollmentId} 'Local DPAPI bundle cannot substitute a different observed exit for the signed proof' InvalidBundle
 $null=Complete-TCPairAuthorization -Root $testRoot -EnrollmentId $v2Request.EnrollmentId -EncryptedAuthorization $sealedV2.EncryptedAuthorization
 foreach($case in @('Node','Owner','ServerKey','Request','Device','ClientKey','Digest','Invite','Source','Target','Samples','IPv4','Future','Expiry','Lifetime','Extra','V1Injection','Version','Missing')){
  $bad=Copy-PairFixture $v2Body
  switch($case){
   Node{$bad.ExitEvidence.ServerBinding.NodeId=[guid]::NewGuid().ToString()}
   Owner{$bad.ExitEvidence.ServerBinding.RemoteOwnerId=[guid]::NewGuid().ToString()}
   ServerKey{$bad.ExitEvidence.ServerBinding.ServerPublicKey=('B'*43+'=')}
   Request{$bad.ExitEvidence.RequestId=[guid]::NewGuid().ToString()}
   Device{$bad.ExitEvidence.DeviceId=[guid]::NewGuid().ToString()}
   ClientKey{$bad.ExitEvidence.ClientPublicKey=('B'*43+'=')}
   Digest{$bad.ExitEvidence.RequestDigest=('0'*64)}
   Invite{$bad.ExitEvidence.InviteId=[guid]::NewGuid().ToString()}
   Source{$bad.ExitEvidence.Source='EndpointAssumption'}
   Target{$bad.ExitEvidence.ProbeTarget='https://example.com/trace'}
   Samples{$bad.ExitEvidence.VerifiedSampleCount=1}
   IPv4{$bad.ExitEvidence.ObservedExitIPv4='10.0.0.1'}
   Future{$bad.ExitEvidence.ObservedAtUtc=[DateTime]::UtcNow.AddMinutes(10).ToString('o')}
   Expiry{$bad.ExitEvidence.ObservedAtUtc=[DateTime]::UtcNow.AddHours(-26).ToString('o');$bad.ExitEvidence.ExpiresAtUtc=[DateTime]::UtcNow.AddHours(-2).ToString('o')}
   Lifetime{$bad.ExitEvidence.ExpiresAtUtc=[DateTime]::UtcNow.AddDays(2).ToString('o')}
   Extra{$bad.ExitEvidence|Add-Member NoteProperty Unsupported $true}
   V1Injection{$bad.SchemaVersion=1}
   Version{$bad.SchemaVersion=3}
   Missing{$bad.PSObject.Properties.Remove('ExitEvidence')}
  }
  $invalid=Invoke-PairV2Fixture $v2Process FixtureSign $bad
  $cipher=[TradeChannel.Deployment.PairCrypto]::Encrypt($invalid.Authorization,($v2RequestInfo.Payload.RecipientJwk|ConvertTo-Json -Compress))
  Assert-PairIntakeReject {Resolve-TCPairEnrollment -Root $testRoot -EnrollmentId $v2Request.EnrollmentId -EncryptedAuthorization $cipher} ('Actually signed V2 rejects '+$case+' proof tampering before materialization')
 }
 $parts=$sealedV2.EncryptedAuthorization.Split('.');$parts[4]=if($parts[4][0] -ceq 'A'){'B'+$parts[4].Substring(1)}else{'A'+$parts[4].Substring(1)}
 Assert-PairIntakeReject {Resolve-TCPairEnrollment -Root $testRoot -EnrollmentId $v2Request.EnrollmentId -EncryptedAuthorization ($parts -join '.')} 'V2 encrypted grant still rejects actual JWE authentication-tag tampering' InvalidAuthorization
 foreach($mode in @('Inconsistent','Missing','Private','TlsFailed','HttpFailed')){
  $observation=Invoke-PairV2Fixture $v2Process FixtureTrace @{} $mode
  Assert-PairIntake (-not $observation.Trace -and $observation.FilesUnchanged -and $observation.Fixture.HttpCalls -eq 2 -and -not $observation.Fixture.ServiceRestarted) ('Actual readonly TLS parser with '+$mode+' HTTP boundary cannot create exit proof or mutate files')
 }
 $revision=$authorized.Fixture.ManifestRevision
 $refreshed=Invoke-PairV2Fixture $v2Process request_status @{RequestId=$v2Request.RequestId;RequestDigest=$v2Request.RequestDigest;RefreshAuthorization=$true} Inconsistent
 $fallback=& $pairModule {param($Signed,$Public) ConvertFrom-TCPairJson ([TradeChannel.Deployment.PairCrypto]::Verify($Signed,(ConvertTo-TCPairJson $Public)))} $refreshed.Authorization $trusted.Payload.ManagementSigningPublicKey
 Assert-PairIntake ($fallback.SchemaVersion -eq 1 -and -not $fallback.PSObject.Properties['ExitEvidence'] -and $refreshed.Fixture.ManifestRevision -eq $revision -and $refreshed.Fixture.PeersAfter -eq $authorized.Fixture.PeersAfter) 'Refresh with inconsistent real trace retains strict V1 and same original device/revision without stale proof'
 $refreshed=Invoke-PairV2Fixture $v2Process request_status @{RequestId=$v2Request.RequestId;RequestDigest=$v2Request.RequestDigest;RefreshAuthorization=$true}
 $updatedV2=Protect-TCPairAuthorization -Invite $serverInvite.Invite -PairRequest $v2Request.PairRequest -SignedAuthorization $refreshed.Authorization
 $null=Complete-TCPairAuthorization -Root $testRoot -EnrollmentId $v2Request.EnrollmentId -EncryptedAuthorization $updatedV2.EncryptedAuthorization
 $updatedBundle=Get-TCPairConnectionBundle -Root $testRoot -EnrollmentId $v2Request.EnrollmentId
 Assert-PairIntake ($updatedBundle.ExitEvidence.Source -ceq 'ServerVerifiedTlsTrace' -and $updatedBundle.ExitEvidence.RequestId -ceq $v2Request.RequestId -and $refreshed.Fixture.PeersAfter -eq $authorized.Fixture.PeersAfter -and -not $refreshed.Fixture.ServiceRestarted) 'Lost-reply refresh obtains fresh real signed V2 evidence for original enrollment without another device'
 $fallbackInvite=Invoke-PairV2Fixture $v2Process invite_create;$fallbackTrust=Get-TCPairInvite -Invite $fallbackInvite.Invite -AllowUnconfirmed
 $fallbackRequest=New-TCPairRequest -Invite $fallbackInvite.Invite -ConfirmedFingerprint $fallbackTrust.Fingerprint -Root $testRoot -WgPath $f.Wg -DeviceName 'V1 fallback same real server'
 $firstFallback=Invoke-PairV2Fixture $v2Process authorize_external @{InviteId=$fallbackInvite.InviteId;PairRequest=$fallbackRequest.PairRequest} Inconsistent
 $firstFallbackBody=& $pairModule {param($Signed,$Public) ConvertFrom-TCPairJson ([TradeChannel.Deployment.PairCrypto]::Verify($Signed,(ConvertTo-TCPairJson $Public)))} $firstFallback.Authorization $fallbackTrust.Payload.ManagementSigningPublicKey
 Assert-PairIntake ($firstFallbackBody.SchemaVersion -eq 1 -and -not $firstFallbackBody.PSObject.Properties['ExitEvidence'] -and $firstFallback.Fixture.PeersAfter -eq ($firstFallback.Fixture.PeersBefore+1) -and -not $firstFallback.Fixture.ServiceRestarted) 'Initial authorize_external with conflicting real TLS samples retains strict V1 without fabricated proof or extra device'
 $cached=Invoke-PairV2Fixture $v2Process authorize_external @{InviteId=$fallbackInvite.InviteId;PairRequest=$fallbackRequest.PairRequest}
 Assert-PairIntake ($cached.Authorization -ceq $firstFallback.Authorization -and $cached.Fixture.HttpCalls -eq 0 -and $cached.Fixture.PeersAfter -eq $firstFallback.Fixture.PeersAfter) 'Consumed invitation retries reuse original signed grant without another trace/mutation/device'
 Test-PairV2CandidateIntake -PackageRoot $PackageRoot -Root $testRoot -Enrollment $v2Request -EncryptedGrant $updatedV2.EncryptedAuthorization -VerifiedBundle $updatedBundle -ServerProcess $v2Process -InviteId $serverInvite.InviteId
 $result=[pscustomobject]@{Ok=$true;Runtime=$PSVersionTable.PSVersion.ToString();CheckCount=$script:Checks.Count;Checks=$script:Checks.ToArray();NetworkChanged=$false;FixtureScope='Explicit temporary Windows root + Linux MemoryFS/kernel fixtures; actual parser/status/signature/crypto/candidate materialization; HTTP/TLS boundary mocked and independent network comparison entry captured; no public network, production credentials, TUN or services'}
 if($TestOutputDirectory){$reportPath=[IO.Path]::GetFullPath($TestOutputDirectory);$null=[IO.Directory]::CreateDirectory($reportPath);[IO.File]::WriteAllText((Join-Path $reportPath 'pairing-intake-v2-result.json'),($result|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($true)))}
 $result|ConvertTo-Json -Depth 8
}finally{
 if($v2Process){try{$v2Process.StandardInput.Close();if(-not $v2Process.WaitForExit(3000)){$v2Process.Kill()}}catch{};$v2Process.Dispose()}
 $f=$null;$recipientPrivate=$null;$wrongSigner=$null
 $absolute=[IO.Path]::GetFullPath($testRoot);$tempPrefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if([IO.Directory]::Exists($absolute) -and $absolute.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($absolute).StartsWith('tc-pair-intake-')){Remove-Item -LiteralPath $absolute -Recurse -Force}
}
