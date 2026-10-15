#requires -Version 5.1
[CmdletBinding()]param([string]$PackageRoot)
$ErrorActionPreference='Stop';if(-not $PackageRoot){$PackageRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent}
Import-Module (Join-Path $PackageRoot 'DeploymentFlow.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PackageRoot 'ServerRegistry.psm1') -DisableNameChecking
Import-Module (Join-Path $PackageRoot 'DeploymentStore.psm1') -DisableNameChecking
Import-Module (Join-Path $PackageRoot 'NodeStore.psm1') -DisableNameChecking
Import-Module (Join-Path $PackageRoot 'LineStore.psm1') -DisableNameChecking
$flow=Get-Module DeploymentFlow;$registry=Get-Module ServerRegistry;$checks=New-Object 'Collections.Generic.List[string]'
& $flow {
 $script:OriginalProtocolProbe=${function:Invoke-TCDeploymentProfileProbe}
 $script:ProtocolProbeCase='Passed';$script:ProtocolProbeCalls=0
 function script:Get-TCProtocolNetworkContext {[pscustomobject]@{Status='Known';Fingerprint=('C'*64);ObservedAt=[DateTimeOffset]::UtcNow.ToString('o')}}
 function script:Initialize-TCDeploymentProbeBindings {param($Root,$Run) [pscustomobject]@{LineId=$Run.CandidateNodeId;Prepared=$false;Code='FixtureBindingTestedSeparately';Results=@();NetworkChanged=$false}}
 function script:Invoke-TCDeploymentProfileProbe {
  param($Root,$Run,$ProfileId)
  $script:ProtocolProbeCalls++
  $profile=Get-TCLineProfile -Root $Root -Id $Run.CandidateNodeId -ProfileId $ProfileId
  if($script:ProtocolProbeCase -eq 'Cancel'){
   $stop=Request-TCDeploymentProbeStop -Root $Root -RunId $Run.RunId
   if(-not $stop.Accepted){throw 'Local cancellation marker was rejected while run lock is held.'}
   return [pscustomobject]@{Status='Inconclusive';Code='ProbeCancelled';ForwardingPassed=$false;CleanupComplete=$true;CheckedAtUtc=[DateTimeOffset]::UtcNow.ToString('o');CandidateHash=$profile.CandidateSHA256}
  }
  $status=if($script:ProtocolProbeCase -eq 'BothFailed' -or ($script:ProtocolProbeCase -eq 'UdpFailed' -and $ProfileId -eq 'Udp')){'Failed'}else{'Inconclusive'}
  $qualified=$script:ProtocolProbeCase -ne 'Unknown'
  [pscustomobject]@{Status=$status;Code='FixtureBoundPath';CheckedAtUtc=[DateTimeOffset]::UtcNow.ToString('o');CandidateHash=$profile.CandidateSHA256;ForwardingPassed=($status -ne 'Failed');CleanupComplete=$true;ObservedExitIPv4='192.0.2.40';ExpectedExitIPv4='192.0.2.40';ExpectedExitSource='ServerVerifiedTlsTrace';NetworkFingerprint=('C'*64);PathEvidence=[pscustomobject]@{Kind='BoundInterfaceObserved';Verified=$qualified;EligibleForRecommendation=$qualified;NetworkFingerprint=('C'*64)};Checks=@([pscustomobject]@{Name='AddressHttps';Status=$(if($status -eq 'Failed'){'Failed'}else{'Passed'})},[pscustomobject]@{Name='DomainDnsHttps';Status=$(if($status -eq 'Failed'){'Failed'}else{'Passed'})})}
 }
}
function Assert-Check {param([bool]$Condition,[string]$Name)if(-not $Condition){throw ('FAILED: '+$Name)};$checks.Add($Name)}
function Assert-Reject {param([scriptblock]$Action,[string]$Name)$rejected=$false;try{& $Action|Out-Null}catch{$rejected=$true};Assert-Check $rejected $Name}
$root=Join-Path $PackageRoot ('deployment\test-runs\workflow-'+[guid]::NewGuid().ToString('N'))
try{
 $connection=@{Host='1.1.1.1';Port=22;User='root';IdentityFile=''}
 $a=Set-TCServerRecord -Root $root -Connection $connection -Name 'First';$b=Set-TCServerRecord -Root $root -Connection $connection -Name 'Second'
 Assert-Check ($a.LocalRecordId -ceq $b.LocalRecordId -and @(Get-TCServers $root).Count -eq 1) 'Repeated endpoint preparation keeps one provisional card'
 $jwk=@{kty='RSA';n=('A'*512);e='AQAB'};$owner=[guid]::NewGuid().ToString();$node=[guid]::NewGuid().ToString();$public=[Convert]::ToBase64String((New-Object byte[] 32))
 $info=@{RemoteOwnerId=$owner;Node=@{NodeId=$node;ServerPublicKey=$public};ManagementSigningPublicKey=$jwk;OwnershipState='Applied';ManagementApiVersion=2}
 $null=Set-TCServerRecord -Root $root -Id $a.LocalRecordId -ServerInfo $info
 $changed=@{RemoteOwnerId=$owner;Node=@{NodeId=$node;ServerPublicKey=$public};ManagementSigningPublicKey=@{kty='RSA';n=('B'*512);e='AQAB'};OwnershipState='Applied';ManagementApiVersion=2}
 Assert-Reject {Set-TCServerRecord -Root $root -Id $a.LocalRecordId -ServerInfo $changed} 'Pinned management signing identity cannot be replaced'
 $info.ManagementSigningPublicKey=$null;$null=Set-TCServerRecord -Root $root -Id $a.LocalRecordId -ServerInfo $info
 Assert-Check ((Get-TCServer $root $a.LocalRecordId).ManagementSigningPublicKey.n -ceq ('A'*512)) 'Null management response does not erase existing pin'
 $run=New-TCDeploymentRun -Root $root -Connection $connection -Name 'Workflow candidate'
 # Private test seam replaces only a read-only local inventory, never calls network setters.
 & $flow {function script:Get-TCDeploymentLocalNetworks { @('0.0.0.0/0','10.0.0.0/8','172.20.0.0/16','192.168.20.0/24') }}
 $subnet=& $flow {param($Root,$Run) Select-TCDeploymentSubnet $Root $Run @{ConflictNetworks=@('172.21.0.0/16')}} $root $run
 Assert-Check ($subnet -ceq '172.22.0.0/24') 'Remote/local supernet overlap excluded with 172 fallback'
 & $flow {function script:Get-TCDeploymentLocalNetworks { @('0.0.0.0/0') }}
 $subnet=& $flow {param($Root,$Run) Select-TCDeploymentSubnet $Root $Run @{ConflictNetworks=@('10.78.0.0/24')}} $root $run
 Assert-Check ($subnet -ceq '10.79.0.0/24') 'Remote inspection networks participate in selection; default route ignored'
 $ref=@{RunId=$run.RunId;PipeName='TCDeploy-'+('A'*32);InstanceId=[guid]::NewGuid().ToString();ProcessId=0;StartTimeUtcTicks='0';Root=$root};$run.SessionRef=$ref
 & $flow {
  $script:TestDispatchRoot=$null;$script:TestDispatchRun=$null
  function script:Invoke-TCDeployOperation {param($SessionRef,$Operation,$Input,[string]$OperationId)
   $saved=Get-TCDeploymentRun $script:TestDispatchRoot $script:TestDispatchRun
   if($saved.Status -ne 'Dispatching' -or $saved.DispatchIntent.IntentId -cne $OperationId){throw 'Intent was not durable before transport call.'}
   throw 'Injected lost pipe response after accepted mutation'
  }
 } 
 & $flow {param($Root,$Run) $script:TestDispatchRoot=$Root;$script:TestDispatchRun=$Run.RunId} $root $run
 Assert-Reject {& $flow {param($Root,$Run) Start-TCDeploymentRemote $Root $Run authorize Authorize @{ClientRequest=@{}}} $root $run} 'Lost dispatch response is not retried blindly'
 $unknown=Get-TCDeploymentRun $root $run.RunId
 Assert-Check ($unknown.Status -ceq 'OutcomeUnknown' -and $unknown.DispatchIntent.Mutating -and $unknown.PendingOperationId -ceq $unknown.DispatchIntent.IntentId) 'Mutation intent is persisted before dispatch and retained unknown'
 $resumed=Set-TCDeploymentSession -Root $root -RunId $run.RunId -SessionRef $ref
 Assert-Check ($resumed.Stage -ceq 'Reconcile') 'Reauthentication preserves mutation reconciliation'
 # Use real wg.exe and real sing-box check to prepare candidate files without running a tunnel.
 $run=New-TCDeploymentRun -Root $root -Connection @{Host='8.8.8.8';Port=22;User='root';IdentityFile=''} -Name 'Actual isolated candidate'
 & $flow {param($Root,$Run) Initialize-TCDeploymentRequest $Root $Run} $root $run
 $originalId=$run.ClientRequest.RequestId;$run.ClientRequest=$null;$run.RequestDirectory=$null
 & $flow {param($Root,$Run) Initialize-TCDeploymentRequest $Root $Run} $root $run
 Assert-Check ($run.ClientRequest.RequestId -ceq $originalId) 'Local request created before run-save crash is recovered without new identity'
 $server=Import-Module (Join-Path $PackageRoot 'ServerSetup.psm1') -PassThru -DisableNameChecking;$pair=& $server {param($Wg) New-TCKeyPair $Wg} (Join-Path $PackageRoot 'assets\wg.exe')
 $response=[pscustomobject]@{SchemaVersion=1;Kind='TradeChannel.ClientResponse';Status='Authorized';RequestId=$run.ClientRequest.RequestId;DeviceId=$run.ClientRequest.DeviceId;NodeId=[guid]::NewGuid().ToString();NodeName='Actual isolated candidate';ClientPublicKey=$run.ClientRequest.ClientPublicKey;ClientAddress='10.78.0.2/32';ServerPublicKey=$pair.Public;PublicEndpoint='8.8.8.8:51820';TunnelSubnet='10.78.0.0/24';ServerAddress='10.78.0.1/24';AllowedIPs=@('0.0.0.0/0');PersistentKeepalive=25;AddressFamilies=@('IPv4');ConfigRevision=1}
 $pair=$null;$run.ClientResponse=$response;$run.ServerInfo=[pscustomobject]@{RemoteOwnerId=[guid]::NewGuid().ToString();Node=@{NodeId=$response.NodeId;ServerPublicKey=$response.ServerPublicKey};ManagementSigningPublicKey=$jwk;OwnershipState='Applied';ManagementApiVersion=2};$null=Set-TCServerRecord -Root $root -Id $run.ServerRecordId -ServerInfo $run.ServerInfo;$null=& $flow {param($Root,$Run) Save-TCDeploymentRun $Root $Run} $root $run
 & $flow {
  $script:OriginalWorkflowSave=${function:Save-TCDeploymentRun};$script:CrashAfterImport=$true
  function script:Save-TCDeploymentRun {param($Root,$Run)
   if($script:CrashAfterImport -and $Run.CandidateTransaction -and $Run.CandidateTransaction.State -eq 'Imported'){$script:CrashAfterImport=$false;throw 'Injected process crash after importer commit'}
   & $script:OriginalWorkflowSave $Root $Run
  }
 }
 Assert-Reject {& $flow {param($Root,$Run) Complete-TCDeploymentCandidate $Root $Run} $root $run} 'Crash injected after real import before run ID commit'
 $disk=Get-TCDeploymentRun $root $run.RunId
 Assert-Check (-not $disk.CandidateNodeId -and $disk.CandidateTransaction.State -ceq 'Prepared' -and @(Get-TCNodes (Join-Path $root 'Product')).Count -eq 1) 'Candidate transaction identifies unrecorded importer result'
 & $flow {param($Root,$Run) Complete-TCDeploymentCandidate $Root $Run;$null=Save-TCDeploymentRun $Root $Run} $root $disk
 $done=Get-TCDeploymentRun $root $run.RunId
 Assert-Check (@(Get-TCNodes (Join-Path $root 'Product')).Count -eq 1 -and $done.Stage -ceq 'ReadyInactive' -and $done.CandidateTransaction.State -ceq 'Completed') 'Import recovery adopts original candidate without duplicate'
 Assert-Check ((Get-TCServer $root $done.ServerRecordId).LinkedNodeIds -contains $done.CandidateNodeId) 'Ready candidate has durable server association'
 $templateManifest=Read-TCDJson $done.CandidateManifestPath;Assert-Check ($templateManifest.DirectDns -ceq '1.1.1.1') 'Actual candidate DNS is stored under DirectDns'
 $subnet=& $flow {param($Root,$Run) Select-TCDeploymentSubnet $Root $Run @{ConflictNetworks=@()}} $root $done
 Assert-Check ($subnet -ceq '10.79.0.0/24') 'Existing manifest ClientAddress /32 protects its enclosing /24'
 Assert-Check (-not $done.NetworkChanged) 'Preparation never activates candidate or changes current network'
 # Remote replies are isolated fixtures. Every candidate/profile publish below
 # uses the actual importer, LineStore, wg pubkey and sing-box check.
 & $flow {
  $script:FixtureDispatches=New-Object 'Collections.Generic.List[object]';$script:FixturePoll=$null
  function script:Invoke-TCDeployOperation {param($SessionRef,$Operation,[Alias('Input')]$OperationInput,[string]$OperationId)
   $script:FixtureDispatches.Add([pscustomobject]@{SessionRef=$SessionRef;Operation=$Operation;Input=$OperationInput;OperationId=$OperationId})
   [pscustomobject]@{Ok=$true;OperationId=$OperationId}
  }
  function script:Get-TCDeploySession {param($SessionRef) $script:FixturePoll}
 }
 function Start-Fixture {param($Run,[string]$Operation,[string]$Purpose,$InputData=@{})
  & $flow {param($Root,$Run,$Operation,$Purpose,$InputData) Start-TCDeploymentRemote $Root $Run $Operation $Purpose $InputData;$null=Save-TCDeploymentRun $Root $Run} $root $Run $Operation $Purpose $InputData
  Get-TCDeploymentRun $root $Run.RunId
 }
 function Finish-Fixture {param($Run,$Data,[string]$Status='Completed',[string]$Code='')
  & $flow {param($Run,$Data,$Status,$Code) $script:FixturePoll=[pscustomobject]@{Status=$Status;OperationId=$Run.PendingOperationId;Data=$Data;Code=$Code}} $Run $Data $Status $Code
  Sync-TCDeploymentRun $root $Run.RunId
 }
 function Get-FixtureDispatches { & $flow {$script:FixtureDispatches.ToArray()} }
 function State-Fixture {param($Run,[string]$Status='Settled',[string]$Udp='Healthy')
  [pscustomobject]@{Kind='TradeChannel.DeploymentState';Status=$Status;NodeId=$Run.ClientResponse.NodeId;RemoteOwnerId=$Run.ServerInfo.RemoteOwnerId;ServerPublicKey=$Run.ClientResponse.ServerPublicKey;ClientPublicKey=$Run.ClientResponse.ClientPublicKey;Transaction=$(if($Status -eq 'Settled'){$null}else{@{Action='transport_add';Phase='Pending'}});Udp=@{Status=$Udp;ClientAddress=$Run.ClientResponse.ClientAddress;ClientResponse=$Run.ClientResponse}}
 }
 function Info-Fixture {param($Run,[switch]$Available)
  $value=[pscustomobject]@{Kind='TradeChannel.TransportInfo';Status=$(if($Available){'Available'}else{'NotConfigured'});NodeId=$Run.ClientResponse.NodeId;RemoteOwnerId=$Run.ServerInfo.RemoteOwnerId;ServerPublicKey=$Run.ClientResponse.ServerPublicKey;ClientPublicKey=$Run.ClientResponse.ClientPublicKey;ClientAddress=$Run.ClientResponse.ClientAddress}
  if($Available){$value|Add-Member NoteProperty Transport ([pscustomobject]@{Type='tcp-reality';Server=$Run.ClientResponse.PublicEndpoint.Split(':')[0];Port=8443;ServerName='www.bing.com';Uuid='aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';RealityPublicKey=('A'*43);RealityShortId='1234567890abcdef'})};$value
 }
 function Existing-Fixture {param($Source)
  $r=New-TCDeploymentRun -Root $root -Intent Existing -ServerId $Source.ServerRecordId -ExistingNodeId $Source.CandidateNodeId -Transport Auto
  $r.SessionRef=[pscustomobject]@{RunId=$r.RunId;InstanceId=[guid]::NewGuid().ToString();Root=$root};$r.ServerInfo=$Source.ServerInfo;$r.ClientResponse=$Source.ClientResponse
  $r.ProtocolPreparation.Udp.ServerPreparation='Configured';$r.ApprovedChangeDigest='fixture-approved-scope'
  & $flow {param($Root,$Run) $null=Save-TCDeploymentRun $Root $Run} $root $r
  $r
 }
 # Execute a complete new Auto base phase before attempting incremental TCP.
 $auto=New-TCDeploymentRun -Root $root -Transport Auto -Connection @{Host='9.9.9.9';Port=2222;User='root';IdentityFile=''}
 $auto.SessionRef=[pscustomobject]@{RunId=$auto.RunId;InstanceId=[guid]::NewGuid().ToString();Root=$root}
 $auto=Start-Fixture $auto inspect Inspect
 $auto=Finish-Fixture $auto @{Supported=$true;AlreadyDeployed=$false;OwnedDeployment=$false;ConflictNetworks=@()}
 $dispatch=@(Get-FixtureDispatches)[-1]
 Assert-Check ($dispatch.Operation -ceq 'plan' -and -not $dispatch.Input.ContainsKey('Transport')) 'Auto base UDP plan excludes TCP download and apply rollback scope'
 $auto=Finish-Fixture $auto @{PlanId=[guid]::NewGuid().ToString();PlanExpiresAt=[DateTime]::UtcNow.AddHours(1).ToString('o')}
 Assert-Check ($auto.Review.OptionalTcpPreparation.CandidatePorts.Count -eq 3) 'One approved standard summary covers supported optional TCP candidates'
 $auto=Invoke-TCDeploymentAdvance -Root $root -RunId $auto.RunId -Command Approve -ApprovedChangeDigest $auto.Review.ChangeDigest
 Assert-Check (($auto.ApprovedTransportChoices.CandidateServerNames -join ',') -ceq 'www.bing.com,www.microsoft.com') 'Approved default TLS target choices are saved with exact order and scope'
 $autoResponse=$done.ClientResponse|ConvertTo-Json -Depth 20|ConvertFrom-Json
 $autoServerPair=& $server {param($Wg) New-TCKeyPair $Wg} (Join-Path $PackageRoot 'assets\wg.exe');$autoResponse.ServerPublicKey=$autoServerPair.Public;$autoServerPair=$null
 $autoResponse.RequestId=$auto.ClientRequest.RequestId;$autoResponse.DeviceId=$auto.ClientRequest.DeviceId;$autoResponse.ClientPublicKey=$auto.ClientRequest.ClientPublicKey;$autoResponse.NodeId=[guid]::NewGuid().ToString();$autoResponse.PublicEndpoint='9.9.9.9:51820'
 $autoInfo=[pscustomobject]@{RemoteOwnerId=[guid]::NewGuid().ToString();Node=@{NodeId=$autoResponse.NodeId;ServerPublicKey=$autoResponse.ServerPublicKey;PublicEndpoint=$autoResponse.PublicEndpoint};ManagementSigningPublicKey=$jwk;OwnershipState='Applied';ManagementApiVersion=2}
 $auto=Finish-Fixture $auto @{ClientResponse=$autoResponse};$auto=Finish-Fixture $auto $autoInfo
 $auto=Finish-Fixture $auto @{Status='Applied';NetworkProbe=@{ServerHttps=@()}}
 if($auto.PendingPurpose -cne 'InspectTcp'){throw ('Auto stopped: '+$auto.Status+' / '+$auto.Stage+' / '+($auto.LastError|ConvertTo-Json -Compress))}
 Assert-Check ($auto.PendingPurpose -ceq 'InspectTcp' -and $auto.CandidateNodeId -and $auto.ProtocolPreparation.Udp.LocalPreparation -ceq 'SyntaxValidated') 'UDP server and local profile complete before same-session TCP inspection'
 $udpProfile=Get-TCLineProfile -Root $root -Id $auto.CandidateNodeId -ProfileId Udp;$udpHash=(Get-FileHash $udpProfile.ManifestPath).Hash
 $auto=Finish-Fixture $auto (Info-Fixture $auto)
 $optionsDispatch=@(Get-FixtureDispatches)[-1]
 Assert-Check ($optionsDispatch.Operation -ceq 'transport_options' -and ($optionsDispatch.Input.CandidateServerNames -join ',') -ceq 'www.bing.com,www.microsoft.com') 'TLS options API receives only previously approved default choices'
 $auto=Finish-Fixture $auto @{Status='Selected';Port=8443;SelectedServerName='www.microsoft.com';HandshakeValidation='TlsEndpointReachable';HandshakeChecks=@(@{ServerName='www.bing.com';Status='Failed';ErrorCode='TlsCertificateInvalid'},@{ServerName='www.microsoft.com';Status='TlsEndpointReachable';ErrorCode=$null});Candidates=@(@{Port=443;Busy=$true},@{Port=8443;Busy=$false})}
 Assert-Check (@(Get-FixtureDispatches)[-1].Input.Transport.ServerName -ceq 'www.microsoft.com' -and $auto.ServerName -ceq 'www.microsoft.com') 'Selected reachable TLS fallback is forwarded to transport_plan'
 $tcpPlan=@{NodeId=$autoResponse.NodeId;RemoteOwnerId=$autoInfo.RemoteOwnerId;ServerPublicKey=$autoResponse.ServerPublicKey;PlanId=[guid]::NewGuid().ToString();ChangeDigest='fixture-tcp-plan';Transport=@{Type='tcp-reality';Port=8443;ServerName='www.microsoft.com'}}
 $auto=Finish-Fixture $auto $tcpPlan
 $auto=Finish-Fixture $auto @{Code='RolledBack';FailureCode='TransportDownloadFailed'} Failed RolledBack
 Assert-Check ($auto.PendingPurpose -ceq 'RecheckUdp' -and $auto.Status -ceq 'Running') 'Ordinary TCP failure requires UDP recheck before warning delivery'
 $auto=Finish-Fixture $auto (State-Fixture $auto)
 Assert-Check ($auto.Status -ceq 'CompletedWithWarnings' -and $auto.Stage -ceq 'ReadyInactive' -and $auto.TcpFailure.Code -ceq 'RolledBack') ('Safely restored TCP failure delivers inactive UDP with structured warning: '+($auto|Select-Object Status,Stage,ProfileProbeState,ProbeError|ConvertTo-Json -Depth 5 -Compress))
 Assert-Check ((Get-FileHash $udpProfile.ManifestPath).Hash -ceq $udpHash -and $auto.RecommendedProfileId -ceq 'Udp') 'TCP failure retains immutable UDP profile and recommends UDP'
 $sameSession=@(Get-FixtureDispatches|Where-Object {$_.SessionRef.RunId -ceq $auto.RunId})
 Assert-Check (@($sameSession|Where-Object {$_.SessionRef.InstanceId -cne $auto.SessionRef.InstanceId}).Count -eq 0) 'Base deployment management and TCP operations reuse one session'
 Assert-Check (($auto.CloudRuleList|ForEach-Object {$_.Protocol+':'+$_.Port}) -join ',' -ceq 'tcp:2222,udp:51820,tcp:8443') 'Merged cloud checklist includes SSH UDP and final selected TCP port'
 Assert-Check (($auto.CloudRuleList|Where-Object Purpose -eq 'TCP').ServerName -ceq 'www.microsoft.com' -and $auto.TransportOptions.HandshakeValidation -ceq 'TlsEndpointReachable') 'Final TCP cloud record retains selected target and separate TLS endpoint evidence'
 $beforeRetry=@(Get-FixtureDispatches).Count;$retry=Invoke-TCDeploymentAdvance -Root $root -RunId $auto.RunId -Command Recheck
 Assert-Check ($retry.PendingPurpose -ceq 'InspectTcp' -and @(Get-FixtureDispatches|Select-Object -Skip $beforeRetry|Where-Object {$_.Operation -in @('plan','apply','authorize')}).Count -eq 0) 'Explicit retry after warning resumes only TCP stage and retains original UDP identity'
 $retry=Finish-Fixture $retry @{Code='TransportPortBusy'} Failed TransportPortBusy;$auto=Finish-Fixture $retry (State-Fixture $retry)
 # Existing device: no local request creation or remote authorize/apply.
 $beforeCount=@(Get-TCNodes (Join-Path $root 'Product')).Count;$beforeDispatch=@(Get-FixtureDispatches).Count
 $reuse=Existing-Fixture $done;$reuse=Start-Fixture $reuse transport_info InspectTcp @{ClientPublicKey=$reuse.ClientRequest.ClientPublicKey;ServerPublicKey=$reuse.ClientResponse.ServerPublicKey}
 $available=Info-Fixture $reuse -Available;$reuse=Finish-Fixture $reuse $available
 $line=Get-TCLine -Root $root -Id $reuse.CandidateNodeId
 Assert-Check ($line.Profiles.Count -eq 2 -and ($line.Profiles.Id -join ',') -ceq 'Udp,Tcp' -and $line.LineId -ceq $done.CandidateNodeId) 'Real LineStore publishes two immutable profiles under original LineId'
 Assert-Check (@(Get-TCNodes (Join-Path $root 'Product')).Count -eq $beforeCount -and -not $reuse.RequestDirectory) 'Existing TCP original device creates no additional node private identity or Peer'
 Assert-Check (@(Get-FixtureDispatches|Select-Object -Skip $beforeDispatch|Where-Object {$_.Operation -in @('apply','authorize','transport_apply','transport_plan')}).Count -eq 0) 'Already configured TCP obtains parameters directly without incremental apply'
 $maintain=New-TCDeploymentRun -Root $root -Intent Existing -ServerId $done.ServerRecordId -ExistingNodeId $done.CandidateNodeId -Transport Auto
 $maintain.SessionRef=[pscustomobject]@{RunId=$maintain.RunId;InstanceId=[guid]::NewGuid().ToString();Root=$root}
 $maintain=Start-Fixture $maintain inspect Inspect;$maintain=Finish-Fixture $maintain @{Supported=$true;AlreadyDeployed=$true;OwnedDeployment=$true}
 $maintain=Finish-Fixture $maintain $done.ServerInfo
 Assert-Check ($maintain.PendingPurpose -ceq 'ExistingUdp' -and -not $maintain.RequestDirectory) 'Full existing-node inspection reads original authorization without generating any local identity'
 $maintain=Finish-Fixture $maintain (State-Fixture $reuse)
 $maintain=Invoke-TCDeploymentAdvance -Root $root -RunId $maintain.RunId -Command Approve -ApprovedChangeDigest $maintain.Review.ChangeDigest
 $maintain=Finish-Fixture $maintain $available
 Assert-Check ($maintain.Stage -ceq 'ReadyInactive' -and $maintain.ClientRequest.DeviceId -ceq $done.ClientRequest.DeviceId -and $maintain.CandidateNodeId -ceq $done.CandidateNodeId) 'Existing maintenance end-to-end uses original authorized device and LineId'
 $tcpProfile=Get-TCLineProfile -Root $root -Id $reuse.CandidateNodeId -ProfileId Tcp;$tcpHash=(Get-FileHash $tcpProfile.ManifestPath).Hash
 & $flow {param($Root,$Run,$Info) Complete-TCDeploymentProfiles $Root $Run $Info} $root $reuse $available
 Assert-Check ((Get-FileHash (Get-TCLineProfile -Root $root -Id $reuse.CandidateNodeId -ProfileId Tcp).ManifestPath).Hash -ceq $tcpHash) 'Repeated TCP preparation reuses exact original profile revision'
 # Unknown remote mutation remains blocked even with positive UDP evidence.
 $blocked=Existing-Fixture $auto;$blocked=Start-Fixture $blocked transport_apply TcpApply @{PlanId=[guid]::NewGuid().ToString();ApprovedChangeDigest='fixture'}
 $lostId=$blocked.PendingOperationId;$blocked=Finish-Fixture $blocked $null OutcomeUnknown ConnectionLost
 $blocked=Finish-Fixture $blocked (State-Fixture $blocked NeedsRecovery)
 Assert-Check ($blocked.Status -ceq 'NeedsRecovery' -and $blocked.UnresolvedTcpMutation.IntentId -ceq $lostId -and $blocked.UdpRecheck.Udp.Status -ceq 'Healthy') 'Unknown TCP commit retains mutation ID and UDP evidence without packaging success'
 $beforeDispatch=@(Get-FixtureDispatches).Count;$blocked=Invoke-TCDeploymentAdvance -Root $root -RunId $blocked.RunId
 Assert-Check (@(Get-FixtureDispatches|Select-Object -Skip $beforeDispatch|Where-Object {$_.Operation -ne 'deployment_state'}).Count -eq 0) 'Unknown commit continuation only reads actual state and never retries mutation'
 $blocked=Finish-Fixture $blocked (State-Fixture $blocked)
 Assert-Check ($blocked.Status -ceq 'OutcomeUnknown' -and $blocked.Stage -ceq 'NeedsRecovery') 'Settled UDP evidence alone cannot resolve unknown TCP submission'
 Assert-Reject {Invoke-TCDeploymentAdvance -Root $root -RunId $blocked.RunId -Command Probe} 'Recovery barrier blocks profile Probe'
 $badUdp=Existing-Fixture $auto;$badUdp=Start-Fixture $badUdp transport_plan TcpPlan @{Transport=@{}}
 $badUdp=Finish-Fixture $badUdp @{Code='TransportPortBusy'} Failed TransportPortBusy
 $badUdp=Finish-Fixture $badUdp (State-Fixture $badUdp Settled Failed)
 Assert-Check ($badUdp.Status -ceq 'NeedsRecovery') 'Ordinary TCP failure with failed UDP verification cannot deliver success'
 $race=Existing-Fixture $auto;$race=Start-Fixture $race transport_apply TcpApply @{PlanId=[guid]::NewGuid().ToString();ApprovedChangeDigest='fixture'}
 $race=Finish-Fixture $race @{Code='TransportPortBusy'} Failed TransportPortBusy;$race=Finish-Fixture $race (State-Fixture $race)
 Assert-Check ($race.Status -ceq 'CompletedWithWarnings' -and $race.TcpFailure.Code -ceq 'TransportPortBusy') 'Port competition preserves UDP and records warning after server verification'
 $udpUnknown=Existing-Fixture $auto;$udpUnknown=Start-Fixture $udpUnknown transport_plan TcpPlan @{Transport=@{}}
 $udpUnknown=Finish-Fixture $udpUnknown @{Code='TransportPortBusy'} Failed TransportPortBusy
 $udpUnknown=Finish-Fixture $udpUnknown $null Failed AuthenticationRequired
 Assert-Check ($udpUnknown.Status -ceq 'NeedsRecovery' -and -not $udpUnknown.RecommendedProfileId) 'Unavailable real UDP state blocks warning delivery and clears recommendation'
 $required=Existing-Fixture $auto;$required.Transport='Tcp';$required=Start-Fixture $required transport_plan TcpPlan @{Transport=@{}}
 $required=Finish-Fixture $required @{Code='TransportPortBusy'} Failed TransportPortBusy;$required=Finish-Fixture $required (State-Fixture $required)
 Assert-Check ($required.Status -ceq 'Failed' -and $required.Stage -ceq 'TcpRequired') 'Explicit advanced TCP mode never downgrades failed TCP requirement to UDP success'
 $tlsFailure=Existing-Fixture $auto;$tlsFailure=Start-Fixture $tlsFailure transport_info InspectTcp @{ClientPublicKey=$tlsFailure.ClientRequest.ClientPublicKey;ServerPublicKey=$tlsFailure.ClientResponse.ServerPublicKey}
 $tlsFailure=Finish-Fixture $tlsFailure (Info-Fixture $tlsFailure);$beforeTlsFailure=@(Get-FixtureDispatches).Count
 $tlsFailure=Finish-Fixture $tlsFailure @{Status='Unavailable';Code='TransportHandshakeUnavailable';SelectedServerName=$null;HandshakeValidation='Failed';HandshakeChecks=@(@{ServerName='www.bing.com';Status='Failed';ErrorCode='TlsTimeout'})}
 $tlsFailure=Finish-Fixture $tlsFailure (State-Fixture $tlsFailure)
 Assert-Check ($tlsFailure.Status -ceq 'CompletedWithWarnings' -and $tlsFailure.TcpFailure.Code -ceq 'TransportHandshakeUnavailable' -and $tlsFailure.TcpFailure.HandshakeChecks[0].ErrorCode -ceq 'TlsTimeout' -and (Get-FileHash $udpProfile.ManifestPath).Hash -ceq $udpHash) 'All outbound TLS targets failed: UDP remains ready with precise handshake failure reason'
 Assert-Check (@(Get-FixtureDispatches|Select-Object -Skip $beforeTlsFailure|Where-Object {$_.Operation -in @('transport_plan','transport_apply','apply','authorize')}).Count -eq 0) 'No successful TLS candidate sends neither transport_plan nor transport_apply'
 $custom=Existing-Fixture $auto;$custom.ServerName='custom.example.com';$custom.ApprovedTransportChoices=[pscustomobject]@{CandidatePorts=@(443,8443,2443);ServerName='custom.example.com';CandidateServerNames=@('custom.example.com')}
 $custom=Start-Fixture $custom transport_info InspectTcp @{ClientPublicKey=$custom.ClientRequest.ClientPublicKey;ServerPublicKey=$custom.ClientResponse.ServerPublicKey};$custom=Finish-Fixture $custom (Info-Fixture $custom)
 Assert-Check ((@(Get-FixtureDispatches)[-1].Input.CandidateServerNames -join ',') -ceq 'custom.example.com') 'Custom TLS target remains the single approved choice'
 $beforeCustom=@(Get-FixtureDispatches).Count
 $custom=Finish-Fixture $custom @{Status='Selected';Port=443;SelectedServerName='www.microsoft.com';HandshakeValidation='TlsEndpointReachable'}
 $custom=Finish-Fixture $custom (State-Fixture $custom)
 Assert-Check ($custom.ServerName -ceq 'custom.example.com' -and $custom.TcpFailure.Code -ceq 'TransportOptionsMismatch' -and @(Get-FixtureDispatches|Select-Object -Skip $beforeCustom|Where-Object {$_.Operation -in @('transport_plan','transport_apply')}).Count -eq 0) 'TLS-reachable unapproved replacement cannot silently change custom target or submit TCP'
 $noProof=Existing-Fixture $auto;$noProof=Start-Fixture $noProof transport_options TcpCandidates @{ServerPublicKey=$noProof.ClientResponse.ServerPublicKey;ServerName='www.bing.com'}
 $beforeProof=@(Get-FixtureDispatches).Count;$noProof=Finish-Fixture $noProof @{Status='Selected';Port=443;SelectedServerName='www.bing.com';HandshakeValidation='NotTested'}
 $noProof=Finish-Fixture $noProof (State-Fixture $noProof)
 Assert-Check ($noProof.TcpFailure.Code -ceq 'TransportOptionsMismatch' -and @(Get-FixtureDispatches|Select-Object -Skip $beforeProof|Where-Object {$_.Operation -in @('transport_plan','transport_apply')}).Count -eq 0) 'Port selection without certificate-verified TLS evidence cannot submit TCP'
 # Actual probe reads both published profiles but active guard returns before
 # binding listeners, running engines or making any network request.
 Assert-Check ($auto.ProfileProbeState -ceq 'Completed' -and (& $flow {$script:ProtocolProbeCalls}) -gt 0) 'Standard deployment automatically checks prepared profiles without another UI step'
 & $flow {$script:ProtocolProbeCase='UdpFailed'}
 $reuse=Invoke-TCDeploymentAdvance -Root $root -RunId $reuse.RunId -Command Probe
 Assert-Check ($reuse.RecommendedProfileId -ceq 'Tcp' -and $reuse.Recommendation.Source -ceq 'Reachability' -and $reuse.Validation.ProfileId -ceq 'Tcp' -and $reuse.Validation.Status -ceq 'Passed') 'Qualified TCP recommendation and displayed summary reference the same profile'
 $choice=Get-TCLineDefaultProfile -Root $root -Id $reuse.CandidateNodeId -NetworkContext ([pscustomobject]@{Status='Known';Fingerprint=('C'*64)})
 Assert-Check ($choice.ProfileId -ceq 'Tcp' -and $choice.Source -ceq 'Reachability') 'Deployment recommendation persists into the actual default-profile consumer'
 & $flow {$script:ProtocolProbeCase='BothFailed'}
 $reuse=Invoke-TCDeploymentAdvance -Root $root -RunId $reuse.RunId -Command Probe
 $choice=Get-TCLineDefaultProfile -Root $root -Id $reuse.CandidateNodeId -NetworkContext ([pscustomobject]@{Status='Known';Fingerprint=('C'*64)})
 Assert-Check (-not $reuse.RecommendedProfileId -and $reuse.Recommendation.Status -ceq 'Unavailable' -and $reuse.Validation.Status -ceq 'Failed' -and -not $choice.ProfileId -and $choice.RequiresCheck) 'Both failed leaves no default recommendation and preserves failure display'
 & $flow {$script:ProtocolProbeCase='Unknown'}
 $reuse=Invoke-TCDeploymentAdvance -Root $root -RunId $reuse.RunId -Command Probe
 Assert-Check (-not $reuse.RecommendedProfileId -and $reuse.Recommendation.Status -ceq 'Inconclusive') 'Unknown paths never silently fall back to UDP'
 $callsBefore=& $flow {$script:ProtocolProbeCalls}; & $flow {$script:ProtocolProbeCase='Cancel'}
 $reuse=Invoke-TCDeploymentAdvance -Root $root -RunId $reuse.RunId -Command Probe
 Assert-Check ($reuse.Status -ceq 'Cancelled' -and $reuse.ProfileProbeState -ceq 'Cancelled' -and -not $reuse.RecommendedProfileId -and (& $flow {$script:ProtocolProbeCalls}) -eq ($callsBefore+1)) 'Local cancellation works under held run lock and does not start second profile'
 Assert-Check (-not (Request-TCDeploymentProbeStop -Root $root -RunId $reuse.RunId).Accepted) 'Completed local cancellation cannot stop any unrelated activity'
 $null=Set-TCLinePreferredProfile -Root $root -Id $reuse.CandidateNodeId -ProfileId Tcp
 & $flow {$script:ProtocolProbeCase='Passed'}
 $reuse=Invoke-TCDeploymentAdvance -Root $root -RunId $reuse.RunId -Command Probe
 Assert-Check ($reuse.Recommendation.Status -ceq 'UserChoice' -and $reuse.Recommendation.PreferredProfileId -ceq 'Tcp' -and -not $reuse.RecommendedProfileId) 'Explicit user preference remains distinct from new automatic comparison'
 & $flow {${function:Invoke-TCDeploymentProfileProbe}=$script:OriginalProtocolProbe}
 $probe=Import-Module (Join-Path $PackageRoot 'CandidateProbe.psm1') -PassThru -DisableNameChecking
 & $probe {param($Key) $script:FixtureActiveKey=$Key;function script:Get-TCProbeActiveIdentity {param($Root) [pscustomobject]@{PublicKey=$script:FixtureActiveKey;PrivateKeys=@()}}} $done.ClientResponse.ClientPublicKey
 $reuse=Invoke-TCDeploymentAdvance -Root $root -RunId $reuse.RunId -Command Probe
 Assert-Check ($reuse.ValidationProfiles.Udp.Code -ceq 'ActiveIdentity' -and $reuse.ValidationProfiles.Tcp.Code -ceq 'ActiveIdentity') 'Active same identity blocks both profiles before any probe listener starts'
 & $probe {
  $script:FixtureProbeOrder=New-Object 'Collections.Generic.List[string]'
  function script:Get-TCProbeActiveIdentity {param($Root) $script:FixtureProbeOrder.Add('IdentityChecked');return $null}
  function script:Get-TCCandidateProbeEngine {throw 'Fixture stops before any listener or network call'}
 }
 $reuse=Invoke-TCDeploymentAdvance -Root $root -RunId $reuse.RunId -Command Probe
 $probeOrder=& $probe {$script:FixtureProbeOrder.ToArray()}
 Assert-Check ($probeOrder.Count -eq 2 -and $reuse.ValidationProfiles.Udp.Result.CleanupComplete -and $reuse.ValidationProfiles.Tcp.Result.CleanupComplete) 'Two profile probes execute sequentially with complete cleanup using real profile inputs'
 & $flow {function script:Invoke-TCDeploymentProfileProbe {param($Root,$Run,$ProfileId) [pscustomobject]@{Status='Failed';Code='ProbeCleanupFailed';CleanupComplete=$false}}}
 $reuse=Invoke-TCDeploymentAdvance -Root $root -RunId $reuse.RunId -Command Probe
 Assert-Check ($reuse.Status -ceq 'NeedsRecovery' -and $reuse.ValidationProfiles.Tcp.Code -ceq 'ProbeCleanupFailed') 'Failed first probe cleanup blocks second identity and requires recovery'
 # Cancel intent is durable before executor cancellation; cancellation is not
 # evidence that a remotely submitted transaction was reverted.
 $stop=Existing-Fixture $auto;$stop=Start-Fixture $stop transport_apply TcpApply @{PlanId=[guid]::NewGuid().ToString();ApprovedChangeDigest='fixture'}
 & $flow {function script:Stop-TCDeploySession {param($SessionRef,[switch]$Cancel) $saved=Get-TCDeploymentRun $SessionRef.Root $SessionRef.RunId;if($saved.StopTransaction.State -ne 'Prepared'){throw 'Stop intent missing'};[pscustomobject]@{Status='OutcomeUnknown'}}}
 $stop=Invoke-TCDeploymentAdvance -Root $root -RunId $stop.RunId -Command Cancel
 Assert-Check ($stop.Status -ceq 'OutcomeUnknown' -and $stop.StopTransaction.State -ceq 'StopRequested' -and $stop.StopTransaction.DispatchIntent.Operation -ceq 'transport_apply') 'Stop transaction persists original mutation before requesting cancellation'
 # Older run records retain their schema; fields are added locally on read.
 $legacy=Get-TCDeploymentRun $root $done.RunId
 foreach($field in @('ProtocolPreparation','ValidationProfiles','CloudRuleList','RecommendedProfileId')){$legacy.PSObject.Properties.Remove($field)}
 Write-TCDJson (Join-Path (Join-Path (Join-Path $root 'deployments\runs') $done.RunId) 'state.json') $legacy
 $legacy=Get-TCDeploymentRun $root $done.RunId
 Assert-Check ($legacy.ProtocolPreparation.Udp.LocalPreparation -ceq 'Missing' -and $legacy.ValidationProfiles.Tcp.PathValidation -ceq 'NotTested' -and $legacy.SchemaVersion -eq 1) 'Legacy V1 run missing new dictionaries remains readable with fallback defaults'
 [pscustomobject]@{Ok=$true;Runtime=$PSVersionTable.PSVersion.ToString();CheckCount=$checks.Count;Checks=$checks.ToArray();NetworkScope='Read-only inventories, temporary files, engine check only'}|ConvertTo-Json -Depth 8
}finally{
 $absolute=[IO.Path]::GetFullPath($root);$allowed=[IO.Path]::GetFullPath((Join-Path $PackageRoot 'deployment\test-runs'))+'\';if((Test-Path -LiteralPath $absolute) -and $absolute.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $absolute -Recurse -Force}
}
