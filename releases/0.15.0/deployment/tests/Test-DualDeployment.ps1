#requires -Version 5.1
[CmdletBinding()]param([string]$PackageRoot)
$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition -eq 'Desktop'){$env:PSModulePath=Join-Path $PSHOME 'Modules'}
if(-not $PackageRoot){$PackageRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent}
Import-Module (Join-Path $PackageRoot 'DeploymentFlow.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PackageRoot 'DeploymentStore.psm1') -DisableNameChecking
Import-Module (Join-Path $PackageRoot 'DeploymentPairing.psm1') -DisableNameChecking
Import-Module (Join-Path $PackageRoot 'ServerRegistry.psm1') -DisableNameChecking
Import-Module (Join-Path $PackageRoot 'LineStore.psm1') -DisableNameChecking
Import-Module (Join-Path $PackageRoot 'NodeStore.psm1') -DisableNameChecking
$flow=Get-Module DeploymentFlow;$pairing=Get-Module DeploymentPairing
$checks=New-Object 'Collections.Generic.List[string]'
function Assert-Check {param([bool]$Condition,[string]$Name)if(-not $Condition){throw ('FAILED: '+$Name)};$checks.Add($Name)}
function Assert-Reject {param([scriptblock]$Action,[string]$Name)$rejected=$false;try{& $Action|Out-Null}catch{$rejected=$true};Assert-Check $rejected $Name}
# Exercise the actual import/adapter against AgentB's module export, replacing
# only its invocation in memory before any profile or network can be examined.
$comparisonModule=Import-Module (Join-Path $PackageRoot 'ProtocolComparison.psm1') -PassThru -DisableNameChecking
& $comparisonModule {
 $script:FixtureOriginalComparison=${function:Invoke-TCProtocolComparison}
 function script:Invoke-TCProtocolComparison {
  [CmdletBinding()]param($Root,$NodeId,$ExpectedExitIPv4,$ExpectedExitSource,$CancellationPath)
  [pscustomobject]@{FixtureAdapter=$true;Root=$Root;NodeId=$NodeId;ExpectedExitIPv4=$ExpectedExitIPv4;ExpectedExitSource=$ExpectedExitSource;CancellationPath=$CancellationPath;Results=@()}
 }
}
try{
 $adapterRoot=Join-Path ([IO.Path]::GetTempPath()) ('tc-comparison-adapter-'+[guid]::NewGuid().ToString('N'))
 $adapterRun=[pscustomobject]@{CandidateNodeId=[guid]::NewGuid().ToString();ExpectedExitIPv4='192.0.2.40';ExpectedExitSource='ServerVerifiedTlsTrace';ProbeCancellationPath=(Join-Path $adapterRoot 'cancel.json')}
 $adapter=& $flow {param($Root,$Run)Invoke-TCDeploymentProtocolComparison $Root $Run} $adapterRoot $adapterRun
 Assert-Check ($adapter.FixtureAdapter -and $adapter.Root -ceq $adapterRoot -and $adapter.NodeId -ceq $adapterRun.CandidateNodeId -and $adapter.ExpectedExitIPv4 -ceq $adapterRun.ExpectedExitIPv4 -and $adapter.ExpectedExitSource -ceq $adapterRun.ExpectedExitSource -and $adapter.CancellationPath -ceq $adapterRun.ProbeCancellationPath) 'Production comparison adapter imports AgentB module and forwards all five parameters without individual probes'
}finally{& $comparisonModule {${function:Invoke-TCProtocolComparison}=$script:FixtureOriginalComparison}}
& $flow {
 $script:PairRemoteCalls=0;$script:PairComparisonCalls=0
 function script:Invoke-TCDeployOperation {$script:PairRemoteCalls++;throw 'Pairing fixture forbids every remote operation'}
 function script:Get-TCProtocolNetworkContext {param($Binding)[pscustomobject]@{Status='Unavailable';Fingerprint=$null}}
 function script:Import-TCDeploymentProtocolComparison {}
 function script:Invoke-TCProtocolComparison {
  param($Root,$NodeId,$ExpectedExitIPv4,$ExpectedExitSource,$CancellationPath)
  $script:PairComparisonCalls++
  $comparison=[pscustomobject]@{ComparisonId=[guid]::NewGuid().ToString();CompletedPairRounds=0;Completed=$false;SameNetwork=$false;SameBudget=$true;CleanupComplete=$true;StopCode='NetworkContextUnavailable';CancellationRequested=$false}
  $line=Get-TCLine -Root $Root -Id $NodeId
  $results=@(foreach($profile in $line.Profiles){[pscustomobject]@{ProfileId=$profile.Id;Result=[pscustomobject]@{Status='Inconclusive';Code='NetworkContextUnavailable';CheckedAtUtc=[DateTimeOffset]::UtcNow.ToString('o');CandidateHash=$profile.CandidateSHA256;Checks=@();CleanupComplete=$true;ForwardingPassed=$false;Samples=@();Metrics=$null;Comparison=$comparison}}})
  [pscustomobject]@{Results=$results;ComparisonId=$comparison.ComparisonId;Comparison=$comparison}
 }
}
$dualTempBase=Join-Path ([IO.Path]::GetTempPath()) 'tc-dual-deployment'
$root=Join-Path $dualTempBase ('pairing-'+[guid]::NewGuid().ToString('N'))
try{
 # Offline signed invitations use fresh fixture keys. A public-shaped endpoint
 # is required by the V1 contract; it is never contacted or used by an engine.
 & $pairing {Initialize-TCPairCrypto}
 $private=[TradeChannel.Deployment.PairCrypto]::NewPrivateKey()
 $jwk=[TradeChannel.Deployment.PairCrypto]::PublicJwk($private)|ConvertFrom-Json
 $fingerprint=[TradeChannel.Deployment.PairCrypto]::Fingerprint(($jwk|ConvertTo-Json -Compress))
 $serverModule=Import-Module (Join-Path $PackageRoot 'ServerSetup.psm1') -PassThru -DisableNameChecking
 $wg=Join-Path $PackageRoot 'assets/wg.exe'
 $key=& $serverModule {param($Path)New-TCKeyPair $Path} $wg;$serverPublic=$key.Public;$key=$null
 $owner=[guid]::NewGuid().ToString();$node=[guid]::NewGuid().ToString()
 function New-PairFixture {param([bool]$WithMtu=$false)
  $inviteId=[guid]::NewGuid().ToString()
  $inviteBody=[ordered]@{SchemaVersion=1;Kind='TradeChannel.PairInvite';InviteId=$inviteId;RemoteOwnerId=$owner;NodeId=$node;ServerPublicKey=$serverPublic;ManagementSigningPublicKey=$jwk;PublicEndpoint='1.1.1.1:51820';IssuedAtUtc=[DateTime]::UtcNow.ToString('o');ExpiresAtUtc=[DateTime]::UtcNow.AddHours(24).ToString('o');Capabilities=@('authorize_external')}
  $invite=[TradeChannel.Deployment.PairCrypto]::Sign(($inviteBody|ConvertTo-Json -Depth 24 -Compress),$private)
  $created=New-TCPairRequest -Invite $invite -ConfirmedFingerprint $fingerprint -DeviceName 'Isolated dual fixture' -Root $root -WgPath $wg
  $request=Get-TCPairRequestInfo $created.PairRequest;$client=$request.Payload.ClientRequest
  $response=[ordered]@{SchemaVersion=1;Kind='TradeChannel.ClientResponse';Status='Authorized';RequestId=$client.RequestId;DeviceId=$client.DeviceId;NodeId=$node;NodeName='Isolated dual fixture';ClientPublicKey=$client.ClientPublicKey;ClientAddress=$(if($WithMtu){'10.78.0.3/32'}else{'10.78.0.2/32'});ServerPublicKey=$serverPublic;PublicEndpoint='1.1.1.1:51820';TunnelSubnet='10.78.0.0/24';ServerAddress='10.78.0.1/24';AllowedIPs=@('0.0.0.0/0');PersistentKeepalive=25;AddressFamilies=@('IPv4');ConfigRevision=1}
  if($WithMtu){$response.MTU=1380}
  $body=[ordered]@{SchemaVersion=1;Kind='TradeChannel.PairAuthorization';InviteId=$inviteId;ServerBinding=$request.Payload.ServerBinding;RemoteOwnerId=$owner;NodeId=$node;DeviceId=$client.DeviceId;ClientPublicKey=$client.ClientPublicKey;ClientAddress=$response.ClientAddress;ConfigRevision=1;ClientResponse=$response;IssuedAtUtc=[DateTime]::UtcNow.ToString('o');ExpiresAtUtc=[DateTime]::UtcNow.AddDays(7).ToString('o');RequestDigest=$created.RequestDigest;RequestDigestAlgorithm='TC-ClientRequest-v1'}
  [pscustomobject]@{Invite=$invite;Created=$created;Body=$body;Response=$response}
 }
 function Import-PairFixture {param($Fixture)
  $signed=[TradeChannel.Deployment.PairCrypto]::Sign(($Fixture.Body|ConvertTo-Json -Depth 30 -Compress),$private)
  $sealed=Protect-TCPairAuthorization -SignedAuthorization $signed -PairRequest $Fixture.Created.PairRequest -Invite $Fixture.Invite
  Complete-TCPairCandidate -Root $root -EnrollmentId $Fixture.Created.EnrollmentId -EncryptedAuthorization $sealed.EncryptedAuthorization -Name 'Isolated paired line'
 }
 function Add-FixtureTcp {param($Fixture)
  $Fixture.Response.Transport=@{Type='tcp-reality';Server='1.1.1.1';Port=8443;ServerName='www.bing.com';Uuid='aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';RealityPublicKey=('A'*43);RealityShortId='1234567890abcdef'}
  $Fixture.Response.ConfigRevision=2;$Fixture.Body.ConfigRevision=2
 }
 $singleFixture=New-PairFixture
 $single=Import-PairFixture $singleFixture
 $run=Get-TCDeploymentRun -Root $root -RunId $single.RunId
 $server=Get-TCServer -Root $root -Id $single.ServerRecordId
 Assert-Check ($single.Status -ceq 'PartialDeployment' -and $single.DeploymentCompleteness -ceq 'Partial' -and ($single.MissingProtocols -join ',') -ceq 'Tcp' -and -not $single.DualPreparationRequired -and -not $single.PartialUseAccepted -and $run.Transport -ceq 'Auto') 'UDP-only signed V1 import reports honest PartialDeployment with initial Auto preference'
 Assert-Check ($server.ManagementAccessState -ceq 'ConnectorOnly' -and -not $server.Connection -and -not $run.SessionRef -and -not $run.AllowManagementInitialize -and -not $run.AllowDeviceAuthorize) 'Pairing import grants connection access without SSH or management authorization'
 $udp=Get-TCLineProfile -Root $root -Id $single.Id -ProfileId Udp;$udpHash=(Get-FileHash $udp.ManifestPath).Hash
 $request=[pscustomobject]@{Action='DeploymentProceed';RunId=$run.RunId;Command='UsePrepared'}
 $accepted=Invoke-TCDeploymentAdvance -Root $root -RunId $request.RunId -Command $request.Command
 Assert-Check ($accepted.PartialUseAccepted -and $accepted.Status -ceq 'PartialDeployment' -and $accepted.DeploymentCompleteness -ceq 'Partial' -and -not $accepted.NetworkChanged -and (& $flow {$script:PairComparisonCalls}) -eq 0) 'Pairing partial UsePrepared records consent through existing proceed command without checking or switching network'
 $repeat=Import-PairFixture $singleFixture
 Assert-Check ($repeat.Id -ceq $single.Id -and $repeat.Status -ceq 'PartialDeployment' -and $repeat.PartialUseAccepted -and @(Get-TCNodes -Root (Join-Path $root 'Product')).Count -eq 1 -and (Get-FileHash $udp.ManifestPath).Hash -ceq $udpHash) 'Repeated UDP-only import retains one identity profile and explicit acceptance'
 $checked=Invoke-TCDeploymentAdvance -Root $root -RunId $run.RunId -Command Recheck
 Assert-Check ($checked.Status -ceq 'PartialDeployment' -and $checked.DeploymentCompleteness -ceq 'Partial' -and $checked.ValidationProfiles.Udp.Status -ceq 'Inconclusive' -and -not $checked.RecommendedProfileId -and -not $checked.PendingPurpose -and (& $flow {$script:PairRemoteCalls}) -eq 0 -and (& $flow {$script:PairComparisonCalls}) -eq 1) 'Connector-only Recheck compares local prepared data without deploying missing TCP or fabricating reachability'
 Assert-Reject {Invoke-TCDeploymentAdvance -Root $root -RunId $run.RunId -Command Approve} 'Pairing has no implicit server change approval'
 Add-FixtureTcp $singleFixture
 $dual=Import-PairFixture $singleFixture;$dualRun=Get-TCDeploymentRun -Root $root -RunId $dual.RunId
 $line=Get-TCLine -Root $root -Id $dual.Id
 Assert-Check ($dual.Status -ceq 'ReadyInactive' -and $dual.DeploymentCompleteness -ceq 'Complete' -and @($dual.MissingProtocols).Count -eq 0 -and -not $dual.PartialUseAccepted -and $dual.Id -ceq $single.Id -and $line.Profiles.Count -eq 2 -and @($line.Profiles|Where-Object PreparationState -cne 'SyntaxValidated').Count -eq 0) 'Signed TCP parameters complete the original paired line and clear partial acceptance without a second identity'
 Assert-Check (-not $dualRun.TcpInfo.PSObject.Properties['MTU']) 'TransportInfo projected from a response without MTU does not invent an MTU value'
 $again=Import-PairFixture $singleFixture
 Assert-Check ($again.Id -ceq $dual.Id -and @(Get-TCNodes -Root (Join-Path $root 'Product')).Count -eq 1) 'Repeated dual-profile import remains idempotent'
 $dualChecked=Invoke-TCDeploymentAdvance -Root $root -RunId $dual.RunId -Command Probe
 Assert-Check ($dualChecked.DeploymentCompleteness -ceq 'Complete' -and @($dualChecked.MissingProtocols).Count -eq 0 -and -not $dualChecked.RecommendedProfileId -and $dualChecked.ValidationProfiles.Udp.Status -ceq 'Inconclusive' -and $dualChecked.ValidationProfiles.Tcp.Status -ceq 'Inconclusive') 'Network-unavailable comparison leaves both syntax-valid paired profiles complete'
 $mtuFixture=New-PairFixture -WithMtu $true;Add-FixtureTcp $mtuFixture
 $mtu=Import-PairFixture $mtuFixture;$mtuRun=Get-TCDeploymentRun -Root $root -RunId $mtu.RunId
 Assert-Check ($mtu.DeploymentCompleteness -ceq 'Complete' -and $mtuRun.TcpInfo.MTU -eq 1380 -and [IO.File]::ReadAllText($mtu.ConfigPath) -match '(?m)^MTU = 1380\r?$') 'Existing valid ClientResponse MTU flows into local configuration and projected TransportInfo unchanged'
 $server=Get-TCServer -Root $root -Id $mtu.ServerRecordId
 Assert-Check ((& $flow {$script:PairRemoteCalls}) -eq 0 -and -not $server.Connection -and $server.ManagementAccessState -ceq 'ConnectorOnly' -and -not $mtuRun.AllowManagementInitialize -and -not $mtuRun.AllowDeviceAuthorize -and -not $mtu.NetworkChanged) 'All single and dual pairing paths preserve connector-only permissions and perform zero remote operations'
 [pscustomobject]@{Ok=$true;Runtime=$PSVersionTable.PSVersion.ToString();CheckCount=$checks.Count;Checks=$checks.ToArray();NetworkScope='Temporary root; offline signed fixture identities; mocked comparison; wg keygen/pubkey and sing-box check only'}|ConvertTo-Json -Depth 8
}finally{
 $absolute=[IO.Path]::GetFullPath($root);$allowed=[IO.Path]::GetFullPath($dualTempBase)+'\'
 if((Test-Path -LiteralPath $absolute) -and $absolute.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $absolute -Recurse -Force}
 $private=$null
}
