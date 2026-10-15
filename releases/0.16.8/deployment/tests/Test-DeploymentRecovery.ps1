#requires -Version 5.1
[CmdletBinding()]param([string]$PackageRoot,[string]$ReportDirectory)
$ErrorActionPreference='Stop';Set-StrictMode -Version 2.0
if(-not $PackageRoot){$PackageRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent}
if(-not $ReportDirectory){$ReportDirectory=Join-Path (Split-Path (Split-Path $PackageRoot -Parent) -Parent) 'reports/release-0.16.7'}
if($PSVersionTable.PSEdition -eq 'Desktop'){$env:PSModulePath=Join-Path $PSHOME 'Modules'}
Import-Module (Join-Path $PackageRoot 'DeploymentFlow.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PackageRoot 'DeploymentStore.psm1') -DisableNameChecking
Import-Module (Join-Path $PackageRoot 'ServerRegistry.psm1') -DisableNameChecking
$flow=Get-Module DeploymentFlow;$registry=Get-Module ServerRegistry;$transport=Import-Module (Join-Path $PackageRoot 'DeploymentTransport.psm1') -PassThru -DisableNameChecking
$checks=New-Object 'Collections.Generic.List[string]';$dispatches=New-Object 'Collections.Generic.List[object]'
$fixture=[pscustomobject]@{Poll=$null;Ref=$null;Reads=0;ForbiddenCalls=0;Dispatches=$dispatches}
$hashes=[ordered]@{};foreach($file in @('DeploymentFlow.psm1','DeploymentTransport.psm1','ServerRegistry.psm1')){$hashes[$file]=(Get-FileHash -LiteralPath (Join-Path $PackageRoot $file)).Hash}
$realPolicy=@{};foreach($name in @('Get-TCDeployVerifiedOperation','Assert-TCDeployLiveIdentity','Assert-TCDeploySessionRef')){$realPolicy[$name]=& $transport {param($Name)(Get-Command $Name).Definition} $name}
# Only remote dispatch and the read-only observation leaf are simulated. The
# identity binding, registry, intent digests and state machine are production code.
& $transport {param($Fixture)
 $script:RecoveryFixture=$Fixture
 function script:Read-TCDeployObservation {param($SessionRef)
  if((ConvertTo-Json $SessionRef -Compress) -cne (ConvertTo-Json $script:RecoveryFixture.Ref -Compress)){throw 'Unbound fixture observation'}
  $script:RecoveryFixture.Reads++;$script:RecoveryFixture.Poll
 }
 function script:Invoke-TCDeployPipe {$script:RecoveryFixture.ForbiddenCalls++;throw 'Live pipe forbidden'}
} $fixture
& $flow {param($Fixture)
 $script:RecoveryFixture=$Fixture
 function script:Invoke-TCDeployOperation {param($SessionRef,$Operation,[Alias('Input')]$OperationInput,$OperationId)
  if($Operation -notin @('status','server_info','request_status','deployment_state','transport_info','management_recovery_state')){throw ('Mutation or unapproved read during recovery: '+$Operation)}
  if($OperationInput.ContainsKey('NetworkProbe') -or $OperationInput.ContainsKey('RefreshAuthorization')){throw 'Network or authorization refresh forbidden'}
  $script:RecoveryFixture.Dispatches.Add([pscustomobject]@{Operation=$Operation;InputData=$OperationInput;OperationId=$OperationId})
  [pscustomobject]@{Ok=$true;OperationId=$OperationId}
 }
 function script:Get-TCDeploySession {param($SessionRef)$script:RecoveryFixture.Poll}
} $fixture
$tempBase=Join-Path ([IO.Path]::GetTempPath()) 'tc-recovery-tests';$root=Join-Path $tempBase ('recovery-'+[guid]::NewGuid().ToString('N'))
function Check {param([bool]$Condition,[string]$Name)if(-not $Condition){throw ('FAILED: '+$Name)};$checks.Add($Name)}
function Clone {param($Value)ConvertFrom-Json (ConvertTo-Json -InputObject $Value -Depth 30 -Compress)}
function Save {param($Run)& $flow {param($Root,$Run)Save-TCDeploymentRun $Root $Run} $root $Run}
function Begin {param($Run,[string]$Command='Reconcile')Invoke-TCDeploymentAdvance -Root $root -RunId $Run.RunId -Command $Command}
function New-Case {param([string]$Operation='management_apply',[string]$ConnectionHost='192.0.2.25')
 $r=New-TCDeploymentRun -Root $root -Connection @{Host=$ConnectionHost;Port=22;User='root';IdentityFile=''} -Name ('Recovery '+[guid]::NewGuid().ToString('N'))
 $r.SessionRef=[pscustomobject]@{RunId=$r.RunId;InstanceId=[guid]::NewGuid().ToString();PipeName=('TCDeploy-'+[guid]::NewGuid().ToString('N'));ProcessId=240001;StartTimeUtcTicks='638000000000000000';Root=$root}
 $r.ClientRequest=[pscustomobject]@{RequestId=[guid]::NewGuid().ToString();DeviceId=[guid]::NewGuid().ToString();ClientPublicKey=('C'*43+'=')}
 $server=Get-TCServer $root $r.ServerRecordId
 $nodeId=if($server.NodeId){$server.NodeId}else{[guid]::NewGuid().ToString()};$owner=if($server.RemoteOwnerId){$server.RemoteOwnerId}else{[guid]::NewGuid().ToString()}
 $r.ClientResponse=[pscustomobject]@{RequestId=$r.ClientRequest.RequestId;DeviceId=$r.ClientRequest.DeviceId;ClientPublicKey=$r.ClientRequest.ClientPublicKey;ServerPublicKey=('A'*43+'=');NodeId=$nodeId;PublicEndpoint='192.0.2.25:51820';ClientAddress='10.78.0.2/32'}
 $r.Plan=[pscustomobject]@{PlanId=[guid]::NewGuid().ToString()}
 $r.ManagementPlan=[pscustomobject]@{PlanId=[guid]::NewGuid().ToString();ChangeDigest=('a'*64);ConfigRevision=1;ExpiresAtUtc='2026-10-01T00:00:00Z';ServerBinding=@{NodeId=$nodeId;RemoteOwnerId=$owner;ServerPublicKey=$r.ClientResponse.ServerPublicKey}}
 $r.TcpPlan=[pscustomobject]@{PlanId=[guid]::NewGuid().ToString();ChangeDigest=('b'*64);BaseConfigRevision=1;BasePlanId=$r.Plan.PlanId;NodeId=$nodeId;RemoteOwnerId=$owner;ServerPublicKey=$r.ClientResponse.ServerPublicKey;AffectedDeviceIds=@($r.ClientRequest.DeviceId);Transport=@{Type='tcp-reality';Port=8443;ServerName='www.bing.com'}}
 $r.ServerInfo=[pscustomobject]@{Node=@{NodeId=$nodeId;ServerPublicKey=$r.ClientResponse.ServerPublicKey};RemoteOwnerId=$owner;ManagementSigningPublicKey=$null;ManagementApiVersion=1;OwnershipState='Applied'}
 $null=Set-TCServerRecord -Root $root -Id $r.ServerRecordId -ServerInfo $r.ServerInfo -PinnedFingerprint ('SHA256:'+('A'*43))
 $inputData=switch($Operation){'management_apply'{@{PlanId=$r.ManagementPlan.PlanId;ApprovedChangeDigest=$r.ManagementPlan.ChangeDigest}}'transport_apply'{@{PlanId=$r.TcpPlan.PlanId;ApprovedChangeDigest=$r.TcpPlan.ChangeDigest}}'apply'{@{PlanId=$r.Plan.PlanId}}'authorize'{@{ClientRequest=$r.ClientRequest}}}
 $r.LastRemoteMutation=[pscustomobject]@{IntentId=[guid]::NewGuid().ToString();Operation=$Operation;Mutating=$true;State='Dispatched';InputDigest=(Get-TCDDigest $inputData)}
 $r.RecoveryRequired=$true;$r.Status='OutcomeUnknown';$r.Stage='Reconcile'
 if($Operation -eq 'transport_apply'){$r.UnresolvedTcpMutation=Clone $r.LastRemoteMutation}
 Save $r
}
function ServerInfo {param($Run)
 [pscustomobject]@{Node=$Run.ServerInfo.Node;RemoteOwnerId=$Run.ServerInfo.RemoteOwnerId;ManagementSigningPublicKey=@{kty='RSA';n=('A'*512);e='AQAB'};ManagementApiVersion=2;ManagementRevision=1;OwnershipState='Applied';PendingOperation=$null;Health=@{LocalConfiguration='Verified'};ActivePlanId=$(if($Run.LastRemoteMutation.Operation -eq 'transport_apply'){$Run.TcpPlan.PlanId}else{$Run.Plan.PlanId});ConfigRevision=$(if($Run.LastRemoteMutation.Operation -eq 'transport_apply'){2}else{1})}
}
function UdpState {param($Run)
 [pscustomobject]@{Kind='TradeChannel.DeploymentState';Status='Settled';Transaction=$null;NodeId=$Run.ClientResponse.NodeId;RemoteOwnerId=$Run.ServerInfo.RemoteOwnerId;ServerPublicKey=$Run.ClientResponse.ServerPublicKey;ClientPublicKey=$Run.ClientResponse.ClientPublicKey;TcpConfigured=$true;Udp=@{Status='Healthy';ClientAddress=$Run.ClientResponse.ClientAddress;ClientResponse=$Run.ClientResponse}}
}
function TcpInfo {param($Run)
 [pscustomobject]@{Kind='TradeChannel.TransportInfo';Status='Available';NodeId=$Run.ClientResponse.NodeId;RemoteOwnerId=$Run.ServerInfo.RemoteOwnerId;ServerPublicKey=$Run.ClientResponse.ServerPublicKey;ClientPublicKey=$Run.ClientResponse.ClientPublicKey;ClientAddress=$Run.ClientResponse.ClientAddress;Transport=@{Type='tcp-reality';Server='192.0.2.25';Port=8443;ServerName='www.bing.com';Uuid=[guid]::NewGuid().ToString();RealityPublicKey=('A'*43);RealityShortId='1234567890abcdef'}}
}
function LegacyInfo {param($Run)
 $info=ServerInfo $Run;$info.ManagementSigningPublicKey=$null;$info.ManagementApiVersion=1;$info.ManagementRevision=$null;$info
}
function AbsenceState {param($Run)
 [pscustomobject]@{SchemaVersion=1;Kind='TradeChannel.ManagementRecoveryState';Outcome='NotApplied';ManagementHistoryAbsent=$true;ReadOnly=$true;PlanExpired=$true;PlanId=$Run.ManagementPlan.PlanId;ApprovedChangeDigest=$Run.ManagementPlan.ChangeDigest;ServerBinding=(Clone $Run.ManagementPlan.ServerBinding);ConfigRevision=1;PlanExpiresAtUtc=$Run.ManagementPlan.ExpiresAtUtc;ObservedAtUtc=[DateTimeOffset]::UtcNow.ToString('o');FilesAbsent=@{State=$true;PrivateKey=$true;PublicKey=$true};PendingOperation=$null;Health=@{LocalConfiguration='Verified'}}
}
function Finish {param($Run,$Data,[scriptblock]$EditPoll)
 $c=(Get-TCServer $root $Run.ServerRecordId).Connection
 $poll=[pscustomobject]@{Status='Completed';Code='Completed';Operation=$Run.DispatchIntent.Operation;OperationId=$Run.PendingOperationId;Data=$Data;RunId=$Run.RunId;InstanceId=$Run.SessionRef.InstanceId;HasSession=$true;HasMutatingOperations=$true;AuthenticationGeneration=1;Connection=@{Host=$c.Host;Port=$c.Port;User=$c.User};ObservedFingerprint=('SHA256:'+('A'*43));AcceptedFingerprint=('SHA256:'+('A'*43));ObservedHostKeyAlgorithm='ssh-ed25519'}
 if($EditPoll){& $EditPoll $poll}
 $fixture.Poll=$poll;$fixture.Ref=$Run.SessionRef
 Sync-TCDeploymentRun $root $Run.RunId -ReconciliationIntentId $Run.RecoveryVerification.MutationIntentId
}
function Finish-All {param($Run)
 for($i=0;$i -lt 6 -and $Run.Status -eq 'Running';$i++){
  $data=switch($Run.PendingPurpose){
   'RecoveryStatus'{@{Status='Applied'}}
   'RecoveryRequest'{@{Status='Authorized';RequestId=$Run.ClientRequest.RequestId;ClientResponse=$Run.ClientResponse}}
   'RecoveryServerInfo'{ServerInfo $Run}
   'RecoveryFinalInfo'{ServerInfo $Run}
   'RecoveryUdp'{UdpState $Run}
   'RecoveryTcp'{TcpInfo $Run}
   default{throw ('Unexpected continuation: '+$Run.PendingPurpose)}
  }
  $Run=Finish $Run $data
 }
 $Run
}
$passed=$false;$failure=$null
try{
 foreach($operation in @('apply','authorize','management_apply','transport_apply')){
  $r=New-Case $operation;$id=$r.LastRemoteMutation.IntentId;$before=$dispatches.Count;$r=Begin $r;$r=Finish-All $r
  Check ($r.Stage -ceq 'RecoveryVerified' -and $r.Status -ceq 'WaitingUser' -and -not $r.RecoveryRequired -and $r.RecoveryVerification.Status -ceq 'Verified' -and $r.RecoveryVerification.MutationIntentId -ceq $id -and $r.LastRemoteMutation.State -ceq 'Completed' -and -not $r.UnresolvedTcpMutation) ($operation+' converges without replay')
  Check ($dispatches.Count-$before -le 5 -and -not $r.CandidateNodeId -and -not $r.NetworkChanged) ($operation+' stops before new configuration or probes')
  $registered=Get-TCServer $root $r.ServerRecordId
  Check ($registered.ManagementAccessState -ceq 'Authenticated' -and $registered.ManagementSigningPublicKey.e -ceq 'AQAB' -and (Get-TCDDigest $registered.ManagementSigningPublicKey) -ceq (Get-TCDDigest $r.ServerInfo.ManagementSigningPublicKey)) ($operation+' commits authenticated registry alongside run snapshot')
  $count=$dispatches.Count;$polled=Sync-TCDeploymentRun $root $r.RunId
  Check ($dispatches.Count -eq $count -and $polled.Stage -ceq 'RecoveryVerified') ($operation+' does not auto advance from verified checkpoint')
 }
 foreach($case in @('Pending','FailedHealth','MissingHealth','WrongExponent','ShortModulus','ExtraKeyField','NoRevision','WrongApi','WrongOwner','WrongConfig','MissingBinding','ChangedIntent')){
  $r=New-Case;$info=ServerInfo $r
  switch($case){
   Pending{$info.PendingOperation=@{Action='management_apply'}} FailedHealth{$info.Health.LocalConfiguration='Failed'} MissingHealth{$info.Health=$null}
   WrongExponent{$info.ManagementSigningPublicKey.e='Aw'} ShortModulus{$info.ManagementSigningPublicKey.n='A'*256} ExtraKeyField{$info.ManagementSigningPublicKey['d']='invalid'}
   NoRevision{$info.ManagementRevision=0} WrongApi{$info.ManagementApiVersion=1} WrongOwner{$info.RemoteOwnerId=[guid]::NewGuid().ToString()} WrongConfig{$info.ConfigRevision=2}
   MissingBinding{$r.ManagementPlan.ServerBinding=$null;$r=Save $r} ChangedIntent{$r.LastRemoteMutation.InputDigest='f'*64;$r=Save $r}
  }
  $r=Begin $r;if($r.Status -eq 'Running'){$r=Finish $r $info}
  Check ($r.Status -ceq 'NeedsRecovery' -and $r.RecoveryRequired -and $r.LastRemoteMutation.State -ceq 'Dispatched') ('Management rejects '+$case)
  $count=$dispatches.Count;$r=Begin $r Continue
  Check ($r.Status -ceq 'NeedsRecovery' -and $dispatches.Count -eq $count) ('No repeated auto dispatch after '+$case)
 }
 foreach($case in @('WrongPlan','WrongRevision','WrongDevice','PendingUdp','UnhealthyUdp','TcpNotConfigured','WrongTcpPort','WrongTcpName','WrongTcpClient','LateConfigChange')){
  $r=Begin (New-Case transport_apply);$info=ServerInfo $r
  switch($case){WrongPlan{$info.ActivePlanId=[guid]::NewGuid().ToString()} WrongRevision{$info.ConfigRevision=3} WrongDevice{$r.TcpPlan.AffectedDeviceIds=@();$r=Save $r}}
  $r=Finish $r $info
  if($r.Status -eq 'Running'){$state=UdpState $r;switch($case){PendingUdp{$state.Transaction=@{Action='transport_add'}}UnhealthyUdp{$state.Udp.Status='Failed'}TcpNotConfigured{$state.TcpConfigured=$false}};$r=Finish $r $state}
  if($r.Status -eq 'Running'){$tcp=TcpInfo $r;switch($case){WrongTcpPort{$tcp.Transport.Port=443}WrongTcpName{$tcp.Transport.ServerName='other.example'}WrongTcpClient{$tcp.ClientPublicKey='Z'*43+'='}};$r=Finish $r $tcp}
  if($r.Status -eq 'Running'){$info=ServerInfo $r;$info.ConfigRevision=3;$r=Finish $r $info}
  Check ($r.Status -ceq 'NeedsRecovery' -and $r.UnresolvedTcpMutation -and $r.RecoveryRequired) ('TCP rejects '+$case)
 }
 foreach($edit in @({param($p)$p.InstanceId=[guid]::NewGuid().ToString()},{param($p)$p.HasSession=$false},{param($p)$p.Connection.Host='192.0.2.99'},{param($p)$p.ObservedFingerprint='SHA256:'+('B'*43)},{param($p)$p.Operation='inspect'})){
  $r=Begin (New-Case);$r=Finish $r (ServerInfo $r) $edit
  Check ($r.Status -ceq 'NeedsRecovery' -and $r.RecoveryRequired) 'Reject unrelated, unauthenticated or changed executor evidence'
 }
 $r=New-Case;$r.ProbeRecoveryRequired=$true;$r=Begin (Save $r);$r=Finish-All $r
 Check ($r.RecoveryVerification.Status -ceq 'Verified' -and $r.ProbeRecoveryRequired -and $r.RecoveryRequired -and $r.Status -ceq 'NeedsRecovery') 'Remote proof preserves outstanding local probe cleanup'
 $r=New-Case;$r.StopTransaction=@{State='OutcomeUnknown';DispatchIntent=@{IntentId=[guid]::NewGuid().ToString()}};$r=Finish-All (Begin (Save $r))
 Check ($r.RecoveryRequired -and $r.StopTransaction.State -ceq 'OutcomeUnknown') 'Remote proof preserves unrelated stop transaction'
 $r=New-Case;$r.StopTransaction=@{State='StopRequested';DispatchIntent=$r.LastRemoteMutation};$r=Finish-All (Begin (Save $r))
 Check (-not $r.RecoveryRequired -and $r.StopTransaction.State -ceq 'Reconciled') 'Matching remote stop is reconciled by exact mutation proof'
 $r=Begin (New-Case);$r.RecoveryAttempt.DeadlineUtc=[DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o');$r=Save $r;$r=Sync-TCDeploymentRun $root $r.RunId
 Check ($r.Status -ceq 'NeedsRecovery' -and $r.LastError.Code -ceq 'RecoveryReadTimeout') 'Stuck read has a durable time bound'
 $r=Finish-All (Begin $r)
 Check ($r.Stage -ceq 'RecoveryVerified') 'Explicit Reconcile can start a fresh attempt after timeout'
 $r=Begin (New-Case);$r=Finish $r (ServerInfo $r) {param($p)$p.OperationId=[guid]::NewGuid().ToString()}
 Check ($r.RecoveryRequired -and $r.Status -ceq 'NeedsRecovery') 'Late reply from another operation never clears the barrier'
 $r=Begin (New-Case);$before=Get-FileHash (Join-Path $root ('deployments/runs/'+$r.RunId+'/state.json'));$rejected=$false
 try{$null=Sync-TCDeploymentRun $root $r.RunId -ReconciliationIntentId ([guid]::NewGuid().ToString())}catch{$rejected=$_.Exception.Message.StartsWith('[TC:RecoveryBindingChanged]')}
 $after=Get-FileHash (Join-Path $root ('deployments/runs/'+$r.RunId+'/state.json'))
 Check ($rejected -and $before.Hash -ceq $after.Hash) 'Recovery-only poll cannot target another intent or modify its run'
 $r=Finish-All $r;$count=$dispatches.Count;$r=Sync-TCDeploymentRun $root $r.RunId -ReconciliationIntentId $r.RecoveryVerification.MutationIntentId
 Check ($r.Stage -ceq 'RecoveryVerified' -and $dispatches.Count -eq $count) 'Recovery-only poll returns settled proof without advancing normal deployment'
 $r=Begin (New-Case);$info=ServerInfo $r;$info.ManagementSigningPublicKey.n='B'*512;$r=Finish $r $info
 Check ($r.RecoveryRequired -and $r.LastRemoteMutation.State -ceq 'Dispatched' -and $r.LastError.Code -ceq 'ManagementIdentityChanged' -and (Get-TCServer $root $r.ServerRecordId).ManagementSigningPublicKey.n -ceq ('A'*512)) 'Registry pin failure cannot commit recovery or replace existing key'
 $r=Begin (New-Case transport_apply);$r=Finish $r (ServerInfo $r);$r=Finish $r (UdpState $r) {param($p)$p.AuthenticationGeneration=2}
 Check ($r.RecoveryRequired -and $r.Status -ceq 'NeedsRecovery') 'Authentication generation change between reads invalidates proof'
 $r=Begin (New-Case);$newRef=Clone $r.SessionRef;$newRef.InstanceId=[guid]::NewGuid().ToString();$newRef.PipeName='TCDeploy-'+[guid]::NewGuid().ToString('N');$r=Set-TCDeploymentSession $root $r.RunId $newRef
 $count=$dispatches.Count;$r=Begin $r Continue
 Check ($dispatches.Count -eq $count -and $r.RecoveryRequired) 'Reauthentication retains the previous attempt barrier until explicit check'
 $r=Finish-All (Begin $r);Check ($r.Stage -ceq 'RecoveryVerified') 'Fresh authenticated attempt settles the original mutation after restart'
 $r=New-Case;$rejected=$false
 try{$null=Begin $r RecoverProbe}catch{$rejected=$_.Exception.Message.StartsWith('[TC:ProbeRecoveryNotReady]')}
 Check $rejected 'Cleanup-only command cannot advance an unresolved remote mutation'
 $r.LastRemoteMutation.State='Completed';$r.ProbeRecoveryRequired=$true;$r.CandidateNodeId=[guid]::NewGuid().ToString();$r.ProbeAttemptId=[guid]::NewGuid().ToString('N');$r=Save $r;$count=$dispatches.Count
 $r=Begin $r RecoverProbe
 Check (-not $r.RecoveryRequired -and -not $r.ProbeRecoveryRequired -and $r.ProbeRecovery.CleanupComplete -and $r.ProbeRecovery.ProbeAttemptId -ceq $r.ProbeAttemptId -and $r.ProbeRecovery.RunId -ceq $r.RunId -and $dispatches.Count -eq $count) 'Actual owned cleanup gate returns bound evidence without remote dispatch'
 $r=New-Case;$r.SessionRef=Clone $r.SessionRef;$r=Save $r
 $null=& $flow {param($Root,$Run)Write-TCDJson (Join-Path (Get-TCDeploymentRunPath $Root $Run.RunId) 'pause-at-checkpoint.json') @{RunId=$Run.RunId;InstanceId=$Run.SessionRef.InstanceId}} $root $r
 $r=Finish-All (Begin $r)
 Check ($r.Stage -ceq 'RecoveryVerified' -and -not $r.RecoveryRequired) 'An old pause marker cannot trap a read-only reconciliation'
 $r=New-Case -ConnectionHost '192.0.2.126';$r.AllowManagementInitialize=$true;$r.ApprovedChangeDigest='c'*64;$r=Save $r
 $original=Clone $r;$before=$dispatches.Count;$r=Begin $r;$r=Finish $r (LegacyInfo $r)
 Check ($r.PendingPurpose -ceq 'RecoveryManagementState' -and $dispatches[$dispatches.Count-1].InputData.PlanId -ceq $original.ManagementPlan.PlanId) 'Missing management identity requests proof for the original plan'
 $r=Finish $r (AbsenceState $r)
 Check ($r.PendingPurpose -ceq 'RecoveryManagementUdp') 'Absence proof still requires the original device and UDP verification'
 $r=Finish $r (UdpState $r);$r=Finish $r (LegacyInfo $r)
 Check ($r.Stage -ceq 'RecoveryVerified' -and $r.LastRemoteMutation.State -ceq 'NotApplied' -and $r.RecoveryVerification.Outcome -ceq 'NotApplied' -and -not $r.RecoveryRequired) 'Expired unused management proposal resolves as NotApplied, never Completed'
 Check ($dispatches.Count-$before -eq 4 -and $r.LastRemoteMutation.IntentId -ceq $original.LastRemoteMutation.IntentId -and (Get-TCDDigest $r.ClientRequest) -ceq (Get-TCDDigest $original.ClientRequest)) 'Four authenticated reads retain the exact original intent and client identity'
 Check (-not $r.AllowManagementInitialize -and -not $r.ApprovedChangeDigest -and $r.ResolvedMutationHistory.Count -eq 1 -and $r.ResolvedMutationHistory[0].ManagementPlan.PlanId -ceq $original.ManagementPlan.PlanId -and $r.ResolvedMutationHistory[0].Mutation.InputDigest -ceq $original.LastRemoteMutation.InputDigest) 'Old approval is invalidated and the resolved proposal remains in durable history'
 $newRead=Begin $r Continue
 Check ($newRead.PendingPurpose -ceq 'ServerInfo' -and $newRead.ResolvedMutationHistory[0].Mutation.State -ceq 'NotApplied') 'Explicit continuation starts a fresh read while retaining original resolution'
 foreach($case in @('WrongPlan','WrongDigest','WrongOwner','WrongRevision','NotExpired','MissingFileCheck','PartialFile','Pending','Health','ExpiryMismatch','ObservedBeforeExpiry')){
  $r=Begin (New-Case -ConnectionHost '192.0.2.126');$r=Finish $r (LegacyInfo $r);$evidence=AbsenceState $r
  switch($case){
   WrongPlan{$evidence.PlanId=[guid]::NewGuid().ToString()} WrongDigest{$evidence.ApprovedChangeDigest='f'*64} WrongOwner{$evidence.ServerBinding.RemoteOwnerId=[guid]::NewGuid().ToString()} WrongRevision{$evidence.ConfigRevision=2}
   NotExpired{$evidence.PlanExpired=$false} MissingFileCheck{$evidence.FilesAbsent.Remove('PrivateKey')} PartialFile{$evidence.FilesAbsent.PublicKey=$false}
   Pending{$evidence.PendingOperation=@{Action='management_apply'}} Health{$evidence.Health.LocalConfiguration='Failed'}
   ExpiryMismatch{$evidence.PlanExpiresAtUtc='2026-09-01T00:00:00Z'} ObservedBeforeExpiry{$evidence.ObservedAtUtc='2026-09-01T00:00:00Z'}
  }
  $r=Finish $r $evidence
  Check ($r.RecoveryRequired -and $r.LastRemoteMutation.State -ceq 'Dispatched' -and $r.Status -ceq 'NeedsRecovery') ('Absence proof rejects '+$case)
 }
 $r=Begin (New-Case -ConnectionHost '192.0.2.126');$r=Finish $r (LegacyInfo $r);$r=Finish $r (AbsenceState $r);$state=UdpState $r;$state.Udp.ClientResponse=Clone $state.Udp.ClientResponse;$state.Udp.ClientResponse.DeviceId=[guid]::NewGuid().ToString();$r=Finish $r $state
 Check ($r.RecoveryRequired -and $r.LastError.Code -ceq 'UdpRecoveryNotVerified') 'Absence proof cannot replace the original authorized device'
 $r=Begin (New-Case -ConnectionHost '192.0.2.126');$r=Finish $r (LegacyInfo $r);$r=Finish $r (AbsenceState $r);$r=Finish $r (UdpState $r);$r=Finish $r (ServerInfo $r)
 Check ($r.RecoveryRequired -and $r.LastError.Code -ceq 'ManagementStateChanged') 'Management appearing during the final read invalidates absence proof'
 $r=Begin (New-Case);$r=Finish $r (LegacyInfo $r)
 Check ($r.RecoveryRequired -and $r.LastError.Code -ceq 'ManagementIdentityMissing') 'Previously registered signing identity cannot be treated as never initialized'
 $r=New-Case -ConnectionHost '192.0.2.126';$r.ProbeRecoveryRequired=$true;$r=Begin (Save $r);$r=Finish $r (LegacyInfo $r);$r=Finish $r (AbsenceState $r);$r=Finish $r (UdpState $r);$r=Finish $r (LegacyInfo $r)
 Check ($r.RecoveryRequired -and $r.ProbeRecoveryRequired -and $r.LastRemoteMutation.State -ceq 'NotApplied') 'Confirmed absence retains independent local cleanup barriers'
 foreach($name in $realPolicy.Keys){Check ((& $transport {param($Name)(Get-Command $Name).Definition} $name) -ceq $realPolicy[$name]) ('Production policy retained: '+$name)}
 foreach($file in $hashes.Keys){Check ((Get-FileHash -LiteralPath (Join-Path $PackageRoot $file)).Hash -ceq $hashes[$file]) ('Source stable: '+$file)}
 Check ($fixture.ForbiddenCalls -eq 0) 'No live SSH pipe used'
 $passed=$true
}catch{$failure=[pscustomobject]@{Message=$_.Exception.Message;Line=$_.InvocationInfo.ScriptLineNumber;Stack=$_.ScriptStackTrace}}
finally{
 $absolute=[IO.Path]::GetFullPath($root);$allowed=[IO.Path]::GetFullPath($tempBase)+'\'
 if((Test-Path -LiteralPath $absolute) -and $absolute.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($absolute) -cmatch '^recovery-[a-f0-9]{32}$'){Remove-Item -LiteralPath $absolute -Recurse -Force}
 $null=[IO.Directory]::CreateDirectory($ReportDirectory)
 $report=[ordered]@{Passed=$passed;Assertions=$checks.Count;Checks=$checks.ToArray();SourceSHA256=$hashes;TestSHA256=(Get-FileHash $PSCommandPath).Hash;FixtureRemoved=(-not (Test-Path -LiteralPath $root));EvidenceReads=$fixture.Reads;DispatchCount=$dispatches.Count;ForbiddenCalls=$fixture.ForbiddenCalls;Failure=$failure;Scope='Isolated fake transport; real identity, registry and recovery policies; no production credentials or network changes'}
 [IO.File]::WriteAllText((Join-Path $ReportDirectory 'deployment-recovery.json'),($report|ConvertTo-Json -Depth 12),(New-Object Text.UTF8Encoding($false)))
}
Write-Output ('Recovery tests: Passed='+$passed+' Assertions='+$checks.Count)
if($failure){Write-Output ($failure|ConvertTo-Json -Compress);exit 1}
