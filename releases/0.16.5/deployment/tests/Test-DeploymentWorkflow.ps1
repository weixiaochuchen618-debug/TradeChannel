#requires -Version 5.1
[CmdletBinding()]param([string]$PackageRoot,[ValidatePattern('^deployment-workflow(?:-[a-zA-Z0-9-]+)?$')][string]$ReportName='deployment-workflow-integration')
$ErrorActionPreference='Stop';if(-not $PackageRoot){$PackageRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent}
if($PSVersionTable.PSEdition -eq 'Desktop'){$env:PSModulePath=Join-Path $PSHOME 'Modules'}
Import-Module (Join-Path $PackageRoot 'DeploymentFlow.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PackageRoot 'ServerRegistry.psm1') -DisableNameChecking
Import-Module (Join-Path $PackageRoot 'DeploymentStore.psm1') -DisableNameChecking
Import-Module (Join-Path $PackageRoot 'NodeStore.psm1') -DisableNameChecking
Import-Module (Join-Path $PackageRoot 'LineStore.psm1') -DisableNameChecking
$flow=Get-Module DeploymentFlow;$registry=Get-Module ServerRegistry;$transport=Import-Module (Join-Path $PackageRoot 'DeploymentTransport.psm1') -PassThru -DisableNameChecking;$checks=New-Object 'Collections.Generic.List[string]'
$workspace=Split-Path (Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent) -Parent
$reportDirectory=Join-Path $workspace 'reports/release-0.16.5';$passed=$false;$removed=$false;$failure=$null
$evidence=[pscustomobject]@{Poll=$null;SessionRef=$null;Reads=0;ForbiddenCalls=0}
$testSHA256=(Get-FileHash -LiteralPath $PSCommandPath).Hash;$sourceBefore=[ordered]@{};$sourceAfter=[ordered]@{}
foreach($name in @('DeploymentFlow.psm1','DeploymentTransport.psm1','ServerRegistry.psm1','LineStore.psm1','ProtocolSelection.psm1','NodeStore.psm1','ServerSetup.psm1')){$sourceBefore[$name]=(Get-FileHash -LiteralPath (Join-Path $PackageRoot $name)).Hash}
$lines=Get-Module LineStore
& $lines {function script:Get-CimInstance {param($ClassName,$Filter)if($ClassName -cne 'Win32_Process'){throw 'Unsupported fixture process inventory'};@()}}
$realPolicy=@{}
foreach($entry in @(@($registry,'Set-TCServerRecord'),@($transport,'Get-TCDeployVerifiedServerInfo'),@($transport,'Assert-TCDeployLiveIdentity'),@($transport,'Assert-TCDeploySessionRef'))){$realPolicy[$entry[1]]=& $entry[0] {param($Name)(Get-Command $Name).Definition} $entry[1]}
# Replace only the private observation leaf; public transport and registry policy stays real.
& $transport {
 param($Evidence)
 $script:FixtureEvidence=$Evidence
 function script:Read-TCDeployObservation {param($SessionRef)
  if(-not $script:FixtureEvidence.Poll -or (ConvertTo-Json $SessionRef -Compress) -cne (ConvertTo-Json $script:FixtureEvidence.SessionRef -Compress)){throw 'No executor fixture is bound to this session'}
  $script:FixtureEvidence.Reads++;$script:FixtureEvidence.Poll
 }
 function script:Invoke-TCDeployPipe {$script:FixtureEvidence.ForbiddenCalls++;throw 'Live executor pipe forbidden'}
 function script:Start-TCDeploySession {$script:FixtureEvidence.ForbiddenCalls++;throw 'Live SSH executor forbidden'}
} $evidence
& $flow {
 $script:ProtocolProbeCase='Passed';$script:ProtocolProbeCalls=0;$script:ComparisonArguments=$null
 function script:Get-TCProtocolNetworkContext {param($Binding) [pscustomobject]@{Status='Known';Fingerprint=('C'*64);ObservedAt=[DateTimeOffset]::UtcNow.ToString('o')}}
 function script:Import-TCDeploymentProtocolComparison {}
 function script:Invoke-TCProtocolComparison {
  param($Root,$NodeId,$ExpectedExitIPv4,$ExpectedExitSource,$CancellationPath)
  $script:ProtocolProbeCalls++
  $script:ComparisonArguments=[pscustomobject]@{Root=$Root;NodeId=$NodeId;ExpectedExitIPv4=$ExpectedExitIPv4;ExpectedExitSource=$ExpectedExitSource;CancellationPath=$CancellationPath}
  if($script:ProtocolProbeCase -eq 'Throw'){throw 'Fixture comparison interrupted before any network call'}
  $line=Get-TCLine -Root $Root -Id $NodeId
  $cancel=$script:ProtocolProbeCase -in @('Cancel','CancelCleanupFailed')
  if($cancel){
   $saved=Read-TCDJson (Join-Path ([IO.Path]::GetDirectoryName($CancellationPath)) 'state.json')
   $stop=Request-TCDeploymentProbeStop -Root $Root -RunId $saved.RunId
   if(-not $stop.Accepted){throw 'Local cancellation marker was rejected while run lock is held.'}
  }
  $clean=$script:ProtocolProbeCase -notin @('CleanupFailed','CancelCleanupFailed')
  $stopCode=if(-not $clean){'ProbeCleanupFailed'}elseif($cancel){'ProbeCancelled'}elseif($script:ProtocolProbeCase -eq 'Active'){'ActiveIdentity'}else{$null}
  $comparison=[pscustomobject]@{ComparisonId=[guid]::NewGuid().ToString('D');PlannedPairRounds=3;CompletedPairRounds=1;Completed=$false;SameNetwork=$true;SameBudget=$true;CleanupComplete=$clean;StopCode=$stopCode;CancellationRequested=$cancel;PerformanceRanked=$false;ProtocolOrder=@(@{Round=1;Order=@('Udp','Tcp')})}
  $results=@(foreach($profile in $line.Profiles){
   $profileId=$profile.Id
   $status=if($script:ProtocolProbeCase -eq 'BothFailed' -or ($script:ProtocolProbeCase -eq 'UdpFailed' -and $profileId -eq 'Udp')){'Failed'}elseif($script:ProtocolProbeCase -eq 'Active'){'Passed'}else{'Inconclusive'}
   $qualified=$script:ProtocolProbeCase -ne 'Unknown'
   $checks=@(foreach($target in @('AddressHttps','DomainDnsHttps')){[pscustomobject]@{Name=$target;Status=$(if($status -eq 'Failed'){'Failed'}else{'Passed'})}})
   $samples=@(foreach($target in @('AddressHttps','DomainDnsHttps')){[pscustomobject]@{Name=$target;Round=1;ComparisonRound=1;ComparisonId=$comparison.ComparisonId;Required=$true;Status=$(if($status -eq 'Failed'){'Failed'}else{'Passed'});DurationMs=25}})
   $result=[pscustomobject]@{Status=$status;Code=$(if($cancel){'ProbeCancelled'}elseif($stopCode){$stopCode}elseif($status -eq 'Failed'){'CandidateForwardingFailed'}else{'FixtureBoundPath'});CheckedAtUtc=[DateTimeOffset]::UtcNow.ToString('o');CandidateHash=$profile.CandidateSHA256;ManifestHash=$profile.ManifestSHA256;EngineSHA256=(Read-TCDJson $profile.ManifestPath).EngineSHA256;ForwardingPassed=($status -ne 'Failed');CleanupComplete=$clean;ObservedExitIPv4='192.0.2.40';ExpectedExitIPv4='192.0.2.40';ExpectedExitSource='ServerVerifiedTlsTrace';NetworkFingerprint=('C'*64);PathEvidence=[pscustomobject]@{Kind='BoundInterfaceObserved';Verified=$qualified;EligibleForRecommendation=$qualified;NetworkFingerprint=('C'*64)};Checks=$checks;Samples=$samples;Metrics=@{ResponseMedianMs=25;SampleCount=2};Comparison=$comparison;ProbeRuns=@(@{PairRound=1;ProfileId=$profileId;Result=@{Status=$status;Checks=$checks}});CancellationRequested=$cancel}
   [pscustomobject]@{ProfileId=$profileId;Result=$result}
  })
  [pscustomobject]@{ComparisonId=$comparison.ComparisonId;Status=$(if($cancel){'Cancelled'}elseif($stopCode){'Stopped'}else{'Incomplete'});Code=$stopCode;Results=$results;Comparison=$comparison}
 }
}
function Assert-Check {param([bool]$Condition,[string]$Name)if(-not $Condition){throw ('FAILED: '+$Name)};$checks.Add($Name)}
function Assert-Reject {param([scriptblock]$Action,[string]$Name)$rejected=$false;try{& $Action|Out-Null}catch{$rejected=$true};Assert-Check $rejected $Name}
function Assert-RejectCode {param([scriptblock]$Action,[string]$Code,[string]$Name)$rejected=$false;try{& $Action|Out-Null}catch{$rejected=$_.Exception.Message.StartsWith('[TC:'+$Code+']')};Assert-Check $rejected $Name}
function New-FixtureSession {param($Run)
 [pscustomobject]@{RunId=$Run.RunId;PipeName=('TCDeploy-'+[guid]::NewGuid().ToString('N'));InstanceId=[guid]::NewGuid().ToString('D');ProcessId=240001;StartTimeUtcTicks='638000000000000000';Root=$root}
}
$workflowTempBase=Join-Path ([IO.Path]::GetTempPath()) 'tc-deployment-workflow'
$root=Join-Path $workflowTempBase ('workflow-'+[guid]::NewGuid().ToString('N'))
try{
 $connection=@{Host='192.0.2.10';Port=22;User='root';IdentityFile=''}
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
 Assert-Check ($run.Transport -ceq 'Auto' -and $run.DualPreparationRequired -and $run.DeploymentCompleteness -ceq 'Partial' -and ($run.MissingProtocols -join ',') -ceq 'Udp,Tcp' -and -not $run.PartialUseAccepted) 'New standard run defaults to Auto with explicit dual preparation and missing protocol array'
 # Private test seam replaces only a read-only local inventory, never calls network setters.
 & $flow {function script:Get-TCDeploymentLocalNetworks { @('0.0.0.0/0','10.0.0.0/8','172.20.0.0/16','192.168.20.0/24') }}
 $subnet=& $flow {param($Root,$Run) Select-TCDeploymentSubnet $Root $Run @{ConflictNetworks=@('172.21.0.0/16')}} $root $run
 Assert-Check ($subnet -ceq '172.22.0.0/24') 'Remote/local supernet overlap excluded with 172 fallback'
 & $flow {function script:Get-TCDeploymentLocalNetworks { @('0.0.0.0/0') }}
 $subnet=& $flow {param($Root,$Run) Select-TCDeploymentSubnet $Root $Run @{ConflictNetworks=@('10.78.0.0/24')}} $root $run
 Assert-Check ($subnet -ceq '10.79.0.0/24') 'Remote inspection networks participate in selection; default route ignored'
 $ref=New-FixtureSession $run;$run.SessionRef=$ref
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
 $run=New-TCDeploymentRun -Root $root -Connection @{Host='192.0.2.20';Port=22;User='root';IdentityFile=''} -Name 'Actual isolated candidate'
 & $flow {param($Root,$Run) Initialize-TCDeploymentRequest $Root $Run} $root $run
 $originalId=$run.ClientRequest.RequestId;$run.ClientRequest=$null;$run.RequestDirectory=$null
 & $flow {param($Root,$Run) Initialize-TCDeploymentRequest $Root $Run} $root $run
 Assert-Check ($run.ClientRequest.RequestId -ceq $originalId) 'Local request created before run-save crash is recovered without new identity'
 $server=Import-Module (Join-Path $PackageRoot 'ServerSetup.psm1') -PassThru -DisableNameChecking;$pair=& $server {param($Wg) New-TCKeyPair $Wg} (Join-Path $PackageRoot 'assets\wg.exe')
 $response=[pscustomobject]@{SchemaVersion=1;Kind='TradeChannel.ClientResponse';Status='Authorized';RequestId=$run.ClientRequest.RequestId;DeviceId=$run.ClientRequest.DeviceId;NodeId=[guid]::NewGuid().ToString();NodeName='Actual isolated candidate';ClientPublicKey=$run.ClientRequest.ClientPublicKey;ClientAddress='10.78.0.2/32';ServerPublicKey=$pair.Public;PublicEndpoint='192.0.2.20:51820';TunnelSubnet='10.78.0.0/24';ServerAddress='10.78.0.1/24';AllowedIPs=@('0.0.0.0/0');PersistentKeepalive=25;AddressFamilies=@('IPv4');ConfigRevision=1}
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
  $c=(Get-TCServer $root $Run.ServerRecordId).Connection
  $poll=[pscustomobject]@{Ok=($Status -eq 'Completed');Status=$Status;OperationId=$Run.PendingOperationId;Operation=$Run.DispatchIntent.Operation;Data=$Data;Code=$(if($Status -eq 'Completed' -and -not $Code){'Completed'}else{$Code});RunId=$Run.RunId;InstanceId=$Run.SessionRef.InstanceId;HasSession=($Code -ne 'AuthenticationRequired');HasMutatingOperations=[bool]$Run.LastRemoteMutation;AuthenticationGeneration=1;Connection=@{Host=$c.Host;Port=$c.Port;User=$c.User};ObservedFingerprint=('SHA256:'+('A'*43));AcceptedFingerprint=('SHA256:'+('A'*43));ObservedHostKeyAlgorithm='ssh-ed25519'}
  $evidence.SessionRef=$Run.SessionRef;$evidence.Poll=$poll
  & $flow {param($Poll) $script:FixturePoll=$Poll} $poll
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
  $r.SessionRef=New-FixtureSession $r;$r.ServerInfo=$Source.ServerInfo;$r.ClientResponse=$Source.ClientResponse
  $r.ProtocolPreparation.Udp.ServerPreparation='Configured';$r.ApprovedChangeDigest='fixture-approved-scope'
  & $flow {param($Root,$Run) $null=Save-TCDeploymentRun $Root $Run} $root $r
  $r
 }
 # Execute a complete new Auto base phase before attempting incremental TCP.
 $auto=New-TCDeploymentRun -Root $root -Transport Auto -Connection @{Host='192.0.2.30';Port=2222;User='root';IdentityFile=''}
 $auto.SessionRef=New-FixtureSession $auto
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
 $autoResponse.RequestId=$auto.ClientRequest.RequestId;$autoResponse.DeviceId=$auto.ClientRequest.DeviceId;$autoResponse.ClientPublicKey=$auto.ClientRequest.ClientPublicKey;$autoResponse.NodeId=[guid]::NewGuid().ToString();$autoResponse.PublicEndpoint='192.0.2.30:51820'
 $autoInfo=[pscustomobject]@{RemoteOwnerId=[guid]::NewGuid().ToString();Node=@{NodeId=$autoResponse.NodeId;ServerPublicKey=$autoResponse.ServerPublicKey;PublicEndpoint=$autoResponse.PublicEndpoint};ManagementSigningPublicKey=$jwk;OwnershipState='Applied';ManagementApiVersion=2}
 $auto=Finish-Fixture $auto @{ClientResponse=$autoResponse};$auto=Finish-Fixture $auto $autoInfo
 $originalObservation=$evidence.Poll;$registryBefore=(Get-FileHash -LiteralPath (Join-Path $root 'servers/registry.json')).Hash
 foreach($badCase in @('Session','Authentication','Connection','Operation','Data')){
  $bad=$originalObservation|ConvertTo-Json -Depth 30|ConvertFrom-Json
  $expected=switch($badCase){Session{$bad.RunId=[guid]::NewGuid().ToString('D');'IdentitySessionMismatch'}Authentication{$bad.AcceptedFingerprint='SHA256:'+('B'*43);'IdentityAuthenticationRequired'}Connection{$bad.Connection.Port++;'HostChanged'}Operation{$bad.Operation='status';'IdentityReadRequired'}Data{$bad.Data.Node.NodeId=[guid]::NewGuid().ToString('D');'IdentityObservationChanged'}}
  $evidence.Poll=$bad
  Assert-RejectCode {Set-TCServerRecord -Root $root -Id $auto.ServerRecordId -ServerInfo $autoInfo -SessionRef $auto.SessionRef} $expected ('Real registry/transport rejects invalid '+$badCase+' observation')
  Assert-Check ((Get-FileHash -LiteralPath (Join-Path $root 'servers/registry.json')).Hash -ceq $registryBefore) ('Rejected '+$badCase+' evidence leaves registry byte-identical')
 }
 $evidence.Poll=$originalObservation
 Assert-Check ((Get-TCServer $root $auto.ServerRecordId).ManagementAccessState -ceq 'Authenticated' -and $evidence.Reads -gt 0) 'Actual authenticated server_info registers verified access through private observation seam'
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
 Assert-Check ($auto.Status -ceq 'PartialDeployment' -and $auto.DeploymentCompleteness -ceq 'Partial' -and ($auto.MissingProtocols -join ',') -ceq 'Tcp' -and -not $auto.PartialUseAccepted -and $auto.Stage -ceq 'ReadyInactive' -and $auto.TcpFailure.Code -ceq 'RolledBack') ('Restored TCP failure honestly publishes PartialDeployment: '+($auto|Select-Object Status,Stage,ProfileProbeState,ProbeError|ConvertTo-Json -Depth 5 -Compress))
 Assert-Check ((Get-FileHash $udpProfile.ManifestPath).Hash -ceq $udpHash -and $auto.RecommendedProfileId -ceq 'Udp') 'TCP failure retains immutable UDP profile and recommends UDP'
 $sameSession=@(Get-FixtureDispatches|Where-Object {$_.SessionRef.RunId -ceq $auto.RunId})
 Assert-Check (@($sameSession|Where-Object {$_.SessionRef.InstanceId -cne $auto.SessionRef.InstanceId}).Count -eq 0) 'Base deployment management and TCP operations reuse one session'
 Assert-Check (($auto.CloudRuleList|ForEach-Object {$_.Protocol+':'+$_.Port}) -join ',' -ceq 'tcp:2222,udp:51820,tcp:8443') 'Merged cloud checklist includes SSH UDP and final selected TCP port'
 Assert-Check (($auto.CloudRuleList|Where-Object Purpose -eq 'TCP').ServerName -ceq 'www.microsoft.com' -and $auto.TransportOptions.HandshakeValidation -ceq 'TlsEndpointReachable') 'Final TCP cloud record retains selected target and separate TLS endpoint evidence'
 $beforeAccept=@(Get-FixtureDispatches).Count;$checksBefore=& $flow {$script:ProtocolProbeCalls}
 $acceptRequest=[pscustomobject]@{Action='DeploymentProceed';RunId=$auto.RunId;Command='UsePrepared'}
 $accepted=Invoke-TCDeploymentAdvance -Root $root -RunId $acceptRequest.RunId -Command $acceptRequest.Command
 Assert-Check ($accepted.PartialUseAccepted -and $accepted.Status -ceq 'PartialDeployment' -and $accepted.DeploymentCompleteness -ceq 'Partial' -and ($accepted.MissingProtocols -join ',') -ceq 'Tcp' -and -not $accepted.NetworkChanged -and @(Get-FixtureDispatches).Count -eq $beforeAccept -and (& $flow {$script:ProtocolProbeCalls}) -eq $checksBefore -and (Get-FileHash $udpProfile.ManifestPath).Hash -ceq $udpHash) 'DeploymentProceed UsePrepared records explicit acceptance without dispatch probing activation or fake completion'
 $acceptedAgain=Invoke-TCDeploymentAdvance -Root $root -RunId $auto.RunId -Command UsePrepared
 Assert-Check ($acceptedAgain.PartialUseAccepted -and $acceptedAgain.CandidateNodeId -ceq $auto.CandidateNodeId) 'Repeated partial acceptance is durable and idempotent'
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
 $maintain.SessionRef=New-FixtureSession $maintain
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
 Assert-Check ($blocked.Status -ceq 'NeedsRecovery' -and $blocked.DeploymentCompleteness -ceq 'NeedsRecovery' -and -not $blocked.PartialUseAccepted -and $blocked.UnresolvedTcpMutation.IntentId -ceq $lostId -and $blocked.UdpRecheck.Udp.Status -ceq 'Healthy') 'Unknown TCP commit retains mutation ID and UDP evidence without packaging success'
 $beforeDispatch=@(Get-FixtureDispatches).Count;$blocked=Invoke-TCDeploymentAdvance -Root $root -RunId $blocked.RunId
 Assert-Check (@(Get-FixtureDispatches|Select-Object -Skip $beforeDispatch|Where-Object {$_.Operation -ne 'deployment_state'}).Count -eq 0) 'Unknown commit continuation only reads actual state and never retries mutation'
 $blocked=Finish-Fixture $blocked (State-Fixture $blocked)
 Assert-Check ($blocked.Status -ceq 'NeedsRecovery' -and $blocked.Stage -ceq 'NeedsRecovery' -and $blocked.UnresolvedTcpMutation -and $blocked.LastError.Code -ceq 'MutationProofUnavailable') 'Settled UDP evidence alone cannot resolve unknown TCP submission'
 Assert-Reject {Invoke-TCDeploymentAdvance -Root $root -RunId $blocked.RunId -Command Probe} 'Recovery barrier blocks profile Probe'
 Assert-Reject {Invoke-TCDeploymentAdvance -Root $root -RunId $blocked.RunId -Command UsePrepared} 'Recovery barrier blocks acceptance of prepared UDP'
 $badUdp=Existing-Fixture $auto;$badUdp=Start-Fixture $badUdp transport_plan TcpPlan @{Transport=@{}}
 $badUdp=Finish-Fixture $badUdp @{Code='TransportPortBusy'} Failed TransportPortBusy
 $badUdp=Finish-Fixture $badUdp (State-Fixture $badUdp Settled Failed)
 Assert-Check ($badUdp.Status -ceq 'NeedsRecovery') 'Ordinary TCP failure with failed UDP verification cannot deliver success'
 $race=Existing-Fixture $auto;$race=Start-Fixture $race transport_apply TcpApply @{PlanId=[guid]::NewGuid().ToString();ApprovedChangeDigest='fixture'}
 $race=Finish-Fixture $race @{Code='TransportPortBusy'} Failed TransportPortBusy;$race=Finish-Fixture $race (State-Fixture $race)
 Assert-Check ($race.Status -ceq 'PartialDeployment' -and $race.DeploymentCompleteness -ceq 'Partial' -and $race.TcpFailure.Code -ceq 'TransportPortBusy') 'Port competition preserves UDP as a partial deployment after server verification'
 $udpUnknown=Existing-Fixture $auto;$udpUnknown=Start-Fixture $udpUnknown transport_plan TcpPlan @{Transport=@{}}
 $udpUnknown=Finish-Fixture $udpUnknown @{Code='TransportPortBusy'} Failed TransportPortBusy
 $udpUnknown=Finish-Fixture $udpUnknown $null Failed AuthenticationRequired
 Assert-Check ($udpUnknown.Status -ceq 'NeedsRecovery' -and -not $udpUnknown.RecommendedProfileId) 'Unavailable real UDP state blocks warning delivery and clears recommendation'
 $required=Existing-Fixture $auto;$required.Transport='Tcp';$required=Start-Fixture $required transport_plan TcpPlan @{Transport=@{}}
 $required=Finish-Fixture $required @{Code='TransportPortBusy'} Failed TransportPortBusy;$required=Finish-Fixture $required (State-Fixture $required)
 Assert-Check ($required.Status -ceq 'PartialDeployment' -and $required.DeploymentCompleteness -ceq 'Partial' -and ($required.MissingProtocols -join ',') -ceq 'Tcp' -and $required.Transport -ceq 'Tcp' -and -not $required.PartialUseAccepted) 'Initial TCP preference retains prepared UDP as explicit partial deployment without silent acceptance'
 $tlsFailure=Existing-Fixture $auto;$tlsFailure=Start-Fixture $tlsFailure transport_info InspectTcp @{ClientPublicKey=$tlsFailure.ClientRequest.ClientPublicKey;ServerPublicKey=$tlsFailure.ClientResponse.ServerPublicKey}
 $tlsFailure=Finish-Fixture $tlsFailure (Info-Fixture $tlsFailure);$beforeTlsFailure=@(Get-FixtureDispatches).Count
 $tlsFailure=Finish-Fixture $tlsFailure @{Status='Unavailable';Code='TransportHandshakeUnavailable';SelectedServerName=$null;HandshakeValidation='Failed';HandshakeChecks=@(@{ServerName='www.bing.com';Status='Failed';ErrorCode='TlsTimeout'})}
 $tlsFailure=Finish-Fixture $tlsFailure (State-Fixture $tlsFailure)
 Assert-Check ($tlsFailure.Status -ceq 'PartialDeployment' -and $tlsFailure.TcpFailure.Code -ceq 'TransportHandshakeUnavailable' -and $tlsFailure.TcpFailure.HandshakeChecks[0].ErrorCode -ceq 'TlsTimeout' -and (Get-FileHash $udpProfile.ManifestPath).Hash -ceq $udpHash) 'All simulated TLS targets failed: UDP remains ready with precise handshake failure reason'
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
 # The production adapter forwards one bounded comparison, whose raw receipts
 # are simulated. No probe engine/listener or external request is started.
 Assert-Check ($auto.ProfileProbeState -ceq 'Completed' -and (& $flow {$script:ProtocolProbeCalls}) -gt 0) 'Standard deployment automatically checks prepared profiles without another UI step'
 & $flow {$script:ProtocolProbeCase='UdpFailed'}
 $reuse=Invoke-TCDeploymentAdvance -Root $root -RunId $reuse.RunId -Command Probe
 Assert-Check ($reuse.RecommendedProfileId -ceq 'Tcp' -and $reuse.Recommendation.Source -ceq 'Reachability' -and $reuse.Validation.ProfileId -ceq 'Tcp' -and $reuse.Validation.Status -ceq 'Passed' -and $reuse.DeploymentCompleteness -ceq 'Complete' -and @($reuse.MissingProtocols).Count -eq 0) 'Qualified TCP recommendation and displayed summary reference the same profile without conflating UDP path failure with missing configuration'
 $args=& $flow {$script:ComparisonArguments}
 Assert-Check ($args.Root -ceq $root -and $args.NodeId -ceq $reuse.CandidateNodeId -and $args.ExpectedExitIPv4 -ceq $reuse.ExpectedExitIPv4 -and $args.ExpectedExitSource -ceq $reuse.ExpectedExitSource -and $args.CancellationPath -ceq $reuse.ProbeCancellationPath) 'Unified comparison receives the exact Root NodeId expected exit binding and durable cancellation path'
 $ev=$reuse.ValidationProfiles.Tcp
 Assert-Check ($ev.ComparisonId -ceq $ev.Result.Comparison.ComparisonId -and $ev.RoundCount -eq 1 -and $ev.Result.Status -ceq 'Inconclusive' -and $ev.Result.Checks.Count -eq 2 -and $ev.Result.CandidateHash -ceq (Get-TCLineProfile -Root $root -Id $reuse.CandidateNodeId -ProfileId Tcp).CandidateSHA256 -and $ev.Result.EngineSHA256 -ceq (Get-FileHash -LiteralPath (Join-Path $PackageRoot 'assets/sing-box.exe')).Hash -and $ev.Result.ObservedExitIPv4 -ceq '192.0.2.40' -and $ev.Result.PathEvidence.Verified -and $ev.Samples.Count -eq 2 -and $ev.Metrics.ResponseMedianMs -eq 25 -and $ev.Result.ProbeRuns.Count -eq 1) 'Paired evidence preserves raw status checks hashes exit path samples metrics comparison identity and round data'
 $choice=Get-TCLineDefaultProfile -Root $root -Id $reuse.CandidateNodeId -NetworkContext ([pscustomobject]@{Status='Known';Fingerprint=('C'*64)})
 $currentChoice=Get-TCLineDefaultProfile -Root $root -Id $reuse.CandidateNodeId -NetworkContext ([pscustomobject]@{Status='Known';Fingerprint=('C'*64)}) -SelectionMode CurrentRecommendation
 Assert-Check ($choice.SavedConnectionPreference.ProfileId -ceq 'Udp' -and $choice.ProfileId -ceq 'Udp' -and -not $choice.RequiresCheck -and $choice.Code -ceq 'SavedDefault' -and $currentChoice.ProfileId -ceq 'Tcp' -and $currentChoice.Source -ceq 'Reachability') 'Ordinary path failure preserves the original saved UDP default while the current TCP recommendation stays separate'
 & $flow {$script:ProtocolProbeCase='BothFailed'}
 $reuse=Invoke-TCDeploymentAdvance -Root $root -RunId $reuse.RunId -Command Probe
 $choice=Get-TCLineDefaultProfile -Root $root -Id $reuse.CandidateNodeId -NetworkContext ([pscustomobject]@{Status='Known';Fingerprint=('C'*64)})
 Assert-Check (-not $reuse.RecommendedProfileId -and $reuse.Recommendation.Status -ceq 'Unavailable' -and $reuse.Validation.Status -ceq 'Failed' -and $choice.ProfileId -ceq 'Udp' -and -not $choice.RequiresCheck -and $choice.SavedConnectionPreference -and $reuse.DeploymentCompleteness -ceq 'Complete' -and @($reuse.MissingProtocols).Count -eq 0 -and $reuse.Status -ceq 'Complete' -and $reuse.AttentionRequired) 'Both ordinary path failures preserve the saved choice and autosave complete configuration with attention required'
 & $flow {$script:ProtocolProbeCase='Unknown'}
 $reuse=Invoke-TCDeploymentAdvance -Root $root -RunId $reuse.RunId -Command Probe
 Assert-Check (-not $reuse.RecommendedProfileId -and $reuse.Recommendation.Status -ceq 'Inconclusive') 'Unknown paths never silently fall back to UDP'
 $callsBefore=& $flow {$script:ProtocolProbeCalls}; & $flow {$script:ProtocolProbeCase='Cancel'}
 $reuse=Invoke-TCDeploymentAdvance -Root $root -RunId $reuse.RunId -Command Probe
 Assert-Check ($reuse.Status -ceq 'Complete' -and $reuse.AttentionRequired -and $reuse.ProfileProbeState -ceq 'Cancelled' -and -not $reuse.RecommendedProfileId -and $reuse.DeploymentCompleteness -ceq 'Complete' -and $reuse.ValidationProfiles.Udp.Code -ceq 'ProbeCancelled' -and $reuse.ValidationProfiles.Tcp.Code -ceq 'ProbeCancelled' -and (& $flow {$script:ProtocolProbeCalls}) -eq ($callsBefore+1)) 'Local cancellation remains distinct while complete configuration autosaves with attention required'
 Assert-Check (-not (Request-TCDeploymentProbeStop -Root $root -RunId $reuse.RunId).Accepted) 'Completed local cancellation cannot stop any unrelated activity'
 $null=Set-TCLinePreferredProfile -Root $root -Id $reuse.CandidateNodeId -ProfileId Tcp
 & $flow {$script:ProtocolProbeCase='Passed'}
 $reuse=Invoke-TCDeploymentAdvance -Root $root -RunId $reuse.RunId -Command Probe
 Assert-Check ($reuse.Recommendation.Status -ceq 'UserChoice' -and $reuse.Recommendation.PreferredProfileId -ceq 'Tcp' -and -not $reuse.RecommendedProfileId) 'Explicit user preference remains distinct from new automatic comparison'
 & $flow {$script:ProtocolProbeCase='Active'}
 $reuse=Invoke-TCDeploymentAdvance -Root $root -RunId $reuse.RunId -Command Probe
 Assert-Check ($reuse.ValidationProfiles.Udp.Code -ceq 'ActiveIdentity' -and $reuse.ValidationProfiles.Tcp.Code -ceq 'ActiveIdentity' -and $reuse.ValidationProfiles.Udp.Status -ceq 'Blocked' -and $reuse.ValidationProfiles.Tcp.Status -ceq 'Blocked' -and -not $reuse.ValidationProfiles.Udp.EligibleForAutomaticSelection -and -not $reuse.ValidationProfiles.Tcp.EligibleForAutomaticSelection -and -not $reuse.RecommendedProfileId -and $reuse.DeploymentCompleteness -ceq 'Complete' -and -not $reuse.RecoveryRequired) 'Active identity overrides raw Passed and performance data as blocked evidence without corrupting configuration completeness'
 & $flow {$script:ProtocolProbeCase='Throw'}
 $reuse=Invoke-TCDeploymentAdvance -Root $root -RunId $reuse.RunId -Command Probe
 Assert-Check ($reuse.ProfileProbeState -ceq 'Interrupted' -and $reuse.DeploymentCompleteness -ceq 'Complete' -and $reuse.ValidationProfiles.Udp.Code -ceq 'ProfileCheckInterrupted' -and $reuse.ValidationProfiles.Tcp.Code -ceq 'ProfileCheckInterrupted' -and -not $reuse.RecommendedProfileId) 'Interrupted comparison replaces stale automatic evidence while retaining both prepared configurations'
 & $flow {$script:ProtocolProbeCase='CleanupFailed'}
 $reuse=Invoke-TCDeploymentAdvance -Root $root -RunId $reuse.RunId -Command Probe
 Assert-Check ($reuse.Status -ceq 'NeedsRecovery' -and $reuse.DeploymentCompleteness -ceq 'NeedsRecovery' -and $reuse.ValidationProfiles.Tcp.Code -ceq 'ProbeCleanupFailed' -and -not $reuse.PartialUseAccepted -and @($reuse.MissingProtocols).Count -eq 0) 'Comparison cleanup failure requires recovery independently of both prepared protocol configurations'
 Assert-Reject {Invoke-TCDeploymentAdvance -Root $root -RunId $reuse.RunId -Command Probe} 'Cleanup barrier prevents a new comparison'
 $cancelDirty=Existing-Fixture $done
 & $flow {param($Root,$Run,$Info) Complete-TCDeploymentProfiles $Root $Run $Info;$null=Save-TCDeploymentRun $Root $Run} $root $cancelDirty $available
 & $flow {$script:ProtocolProbeCase='CancelCleanupFailed'}
 $cancelDirty=Invoke-TCDeploymentAdvance -Root $root -RunId $cancelDirty.RunId -Command Probe
 Assert-Check ($cancelDirty.ProfileProbeState -ceq 'Cancelled' -and $cancelDirty.Status -ceq 'NeedsRecovery' -and $cancelDirty.DeploymentCompleteness -ceq 'NeedsRecovery' -and $cancelDirty.ValidationProfiles.Udp.Code -ceq 'ProbeCleanupFailed' -and -not $cancelDirty.RecommendedProfileId) 'Cancellation with incomplete cleanup requires recovery and cannot become usable partial success'
 # Cancel intent is durable before executor cancellation; cancellation is not
 # evidence that a remotely submitted transaction was reverted.
 $stop=Existing-Fixture $auto;$stop=Start-Fixture $stop transport_apply TcpApply @{PlanId=[guid]::NewGuid().ToString();ApprovedChangeDigest='fixture'}
 & $flow {function script:Stop-TCDeploySession {param($SessionRef,[switch]$Cancel) $saved=Get-TCDeploymentRun $SessionRef.Root $SessionRef.RunId;if($saved.StopTransaction.State -ne 'Prepared'){throw 'Stop intent missing'};[pscustomobject]@{Status='OutcomeUnknown'}}}
 $stop=Invoke-TCDeploymentAdvance -Root $root -RunId $stop.RunId -Command Cancel
 Assert-Check ($stop.Status -ceq 'OutcomeUnknown' -and $stop.StopTransaction.State -ceq 'StopRequested' -and $stop.StopTransaction.DispatchIntent.Operation -ceq 'transport_apply') 'Stop transaction persists original mutation before requesting cancellation'
 # Older run records retain their schema; fields are added locally on read.
 $legacyComplete=Get-TCDeploymentRun $root $maintain.RunId
 foreach($field in @('DualPreparationRequired','DeploymentCompleteness','MissingProtocols','PartialUseAccepted')){$legacyComplete.PSObject.Properties.Remove($field)}
 Write-TCDJson (Join-Path (Join-Path (Join-Path $root 'deployments/runs') $maintain.RunId) 'state.json') $legacyComplete
 $legacyComplete=Get-TCDeploymentRun $root $maintain.RunId
 Assert-Check ($legacyComplete.DeploymentCompleteness -ceq 'Complete' -and $legacyComplete.DualPreparationRequired -and $legacyComplete.MissingProtocols -is [array] -and @($legacyComplete.MissingProtocols).Count -eq 0 -and -not $legacyComplete.PartialUseAccepted) 'Legacy run with both preparation dictionaries infers complete readiness without requiring new fields'
 $legacyPreference=Get-TCDeploymentRun $root $auto.RunId;$legacyPreference.Transport='Udp'
 foreach($field in @('DualPreparationRequired','DeploymentCompleteness','MissingProtocols','PartialUseAccepted')){$legacyPreference.PSObject.Properties.Remove($field)}
 Write-TCDJson (Join-Path (Join-Path (Join-Path $root 'deployments/runs') $auto.RunId) 'state.json') $legacyPreference
 $legacyPreference=Invoke-TCDeploymentAdvance -Root $root -RunId $auto.RunId -Command Recheck
 Assert-Check ($legacyPreference.Transport -ceq 'Udp' -and $legacyPreference.DualPreparationRequired -and $legacyPreference.PendingPurpose -ceq 'InspectTcp') 'Legacy UDP preference also resumes TCP preparation instead of staying a single-protocol deployment'
 $legacy=Get-TCDeploymentRun $root $done.RunId
 foreach($field in @('ProtocolPreparation','ValidationProfiles','CloudRuleList','RecommendedProfileId','DualPreparationRequired','DeploymentCompleteness','MissingProtocols','PartialUseAccepted')){$legacy.PSObject.Properties.Remove($field)}
 Write-TCDJson (Join-Path (Join-Path (Join-Path $root 'deployments\runs') $done.RunId) 'state.json') $legacy
 $legacy=Get-TCDeploymentRun $root $done.RunId
 Assert-Check ($legacy.ProtocolPreparation.Udp.LocalPreparation -ceq 'Missing' -and $legacy.ValidationProfiles.Tcp.PathValidation -ceq 'NotTested' -and $legacy.SchemaVersion -eq 1 -and $legacy.DualPreparationRequired -and $legacy.DeploymentCompleteness -ceq 'Partial' -and $legacy.MissingProtocols -is [array] -and ($legacy.MissingProtocols -join ',') -ceq 'Udp,Tcp' -and -not $legacy.PartialUseAccepted) 'Legacy V1 run missing new dictionaries remains readable with conservative completeness arrays and no invented acceptance'
 # New, additional-device and original-device maintenance all prepare both
 # protocols for every initial preference. Only offline syntax checks run.
 & $flow {$script:ProtocolProbeCase='Passed'}
 $matrixIndex=0
 foreach($intent in @('New','Add','Existing')){foreach($preference in @('Auto','Udp','Tcp')){
  $matrixIndex++;$beforeMatrix=@(Get-FixtureDispatches).Count;$nodeCount=@(Get-TCNodes (Join-Path $root 'Product')).Count
  $parameters=@{Root=$root;Intent=$intent;Transport=$preference;Name=('Fixture '+$intent+' '+$preference)}
  if($intent -eq 'New'){$parameters.Connection=@{Host=('192.0.2.'+(70+$matrixIndex));Port=22;User='root';IdentityFile=''}}
  else{$parameters.ServerId=$done.ServerRecordId;if($intent -eq 'Existing'){$parameters.ExistingNodeId=$done.CandidateNodeId}else{$parameters.TemplateNodeId=$done.CandidateNodeId}}
  $matrix=New-TCDeploymentRun @parameters
   $matrix.SessionRef=New-FixtureSession $matrix
  $matrix=Start-Fixture $matrix inspect Inspect
  $matrix=Finish-Fixture $matrix @{Supported=$true;AlreadyDeployed=($intent -ne 'New');OwnedDeployment=($intent -ne 'New');ConflictNetworks=@()}
  $matrixResponse=$done.ClientResponse|ConvertTo-Json -Depth 20|ConvertFrom-Json
  if($intent -eq 'New'){
   $dispatch=@(Get-FixtureDispatches)[-1]
   Assert-Check ($dispatch.Operation -ceq 'plan' -and -not $dispatch.Input.ContainsKey('Transport')) ('Initial '+$preference+' preference still starts isolated UDP base plan')
   $matrix=Finish-Fixture $matrix @{PlanId=[guid]::NewGuid().ToString();PlanExpiresAt=[DateTime]::UtcNow.AddHours(1).ToString('o')}
   $matrix=Invoke-TCDeploymentAdvance -Root $root -RunId $matrix.RunId -Command Approve -ApprovedChangeDigest $matrix.Review.ChangeDigest
   $matrixPair=& $server {param($Wg) New-TCKeyPair $Wg} (Join-Path $PackageRoot 'assets\wg.exe')
   $matrixResponse.ServerPublicKey=$matrixPair.Public;$matrixPair=$null;$matrixResponse.NodeId=[guid]::NewGuid().ToString()
   $matrixResponse.PublicEndpoint=$parameters.Connection.Host+':51820';$matrixResponse.TunnelSubnet=$matrix.TunnelSubnet
   $prefix=$matrix.TunnelSubnet -replace '\.0/24$','';$matrixResponse.ClientAddress=$prefix+'.2/32';$matrixResponse.ServerAddress=$prefix+'.1/24'
   $matrixResponse.RequestId=$matrix.ClientRequest.RequestId;$matrixResponse.DeviceId=$matrix.ClientRequest.DeviceId;$matrixResponse.ClientPublicKey=$matrix.ClientRequest.ClientPublicKey
   $matrixInfo=[pscustomobject]@{RemoteOwnerId=[guid]::NewGuid().ToString();Node=@{NodeId=$matrixResponse.NodeId;ServerPublicKey=$matrixResponse.ServerPublicKey;PublicEndpoint=$matrixResponse.PublicEndpoint};ManagementSigningPublicKey=$jwk;OwnershipState='Applied';ManagementApiVersion=2}
   $matrix=Finish-Fixture $matrix @{ClientResponse=$matrixResponse};$matrix=Finish-Fixture $matrix $matrixInfo
  }else{
   $matrix=Finish-Fixture $matrix $done.ServerInfo
   if($intent -eq 'Existing'){$matrix=Finish-Fixture $matrix (State-Fixture $done)}
   Assert-Check ($matrix.Review.OptionalTcpPreparation -and $matrix.Review.DualPreparationRequired -and $matrix.Review.InitialTransportPreference -ceq $preference) ($intent+' '+$preference+' review covers both protocols with separate initial preference')
   $matrix=Invoke-TCDeploymentAdvance -Root $root -RunId $matrix.RunId -Command Approve -ApprovedChangeDigest $matrix.Review.ChangeDigest
   if($intent -eq 'Add'){
    $matrixResponse.RequestId=$matrix.ClientRequest.RequestId;$matrixResponse.DeviceId=$matrix.ClientRequest.DeviceId;$matrixResponse.ClientPublicKey=$matrix.ClientRequest.ClientPublicKey;$matrixResponse.ClientAddress='10.78.0.'+(10+$matrixIndex)+'/32'
    $matrix=Finish-Fixture $matrix @{ClientResponse=$matrixResponse}
   }
  }
  if($intent -ne 'Existing'){
   $matrix=Finish-Fixture $matrix @{Status='Applied';NetworkProbe=@{ServerHttps=@(@{ExitEvidence='VerifiedTlsTrace';ObservedExitIPv4='192.0.2.40'})}}
   Assert-Check ($matrix.PendingPurpose -ceq 'InspectTcp' -and $matrix.ProtocolPreparation.Udp.LocalPreparation -ceq 'SyntaxValidated') ($intent+' '+$preference+' prepares UDP before same-session TCP inspection')
   $matrix=Finish-Fixture $matrix (Info-Fixture $matrix)
   $matrix=Finish-Fixture $matrix @{Status='Selected';Port=8443;SelectedServerName='www.bing.com';HandshakeValidation='TlsEndpointReachable'}
   $matrix=Finish-Fixture $matrix @{NodeId=$matrix.ClientResponse.NodeId;RemoteOwnerId=$matrix.ServerInfo.RemoteOwnerId;ServerPublicKey=$matrix.ClientResponse.ServerPublicKey;PlanId=[guid]::NewGuid().ToString();ChangeDigest='fixture-dual-tcp';Transport=@{Type='tcp-reality';Port=8443;ServerName='www.bing.com'}}
   $matrix=Finish-Fixture $matrix @{Status='Applied'}
  }
  $matrix=Finish-Fixture $matrix (Info-Fixture $matrix -Available)
  $matrixLine=Get-TCLine -Root $root -Id $matrix.CandidateNodeId
  $matrixDispatches=@(Get-FixtureDispatches|Select-Object -Skip $beforeMatrix)
   Assert-Check ($matrix.Stage -ceq 'ReadyInactive' -and $matrix.DeploymentCompleteness -ceq 'Complete' -and $matrix.Status -ceq 'Complete' -and $matrix.AutoSavedAtUtc -and $matrix.DualPreparationRequired -and @($matrix.MissingProtocols).Count -eq 0 -and -not $matrix.PartialUseAccepted -and $matrix.Transport -ceq $preference -and $matrixLine.Profiles.Count -eq 2 -and @($matrixLine.Profiles|Where-Object PreparationState -cne 'SyntaxValidated').Count -eq 0 -and -not $matrix.NetworkChanged) ($intent+' '+$preference+' automatically saves both syntax-valid profiles with complete configuration')
  Assert-Check (@($matrixDispatches|Where-Object {$_.SessionRef.InstanceId -cne $matrix.SessionRef.InstanceId}).Count -eq 0) ($intent+' '+$preference+' reuses one approved remote session for both protocols')
  if($intent -eq 'Existing'){
   Assert-Check (@(Get-TCNodes (Join-Path $root 'Product')).Count -eq $nodeCount -and -not $matrix.RequestDirectory -and $matrix.ClientRequest.DeviceId -ceq $done.ClientRequest.DeviceId -and @($matrixDispatches|Where-Object {$_.Operation -in @('apply','authorize','transport_plan','transport_apply')}).Count -eq 0) ('Existing '+$preference+' preserves original identity and retrieves already configured TCP without mutation')
  }
  Assert-Reject {Invoke-TCDeploymentAdvance -Root $root -RunId $matrix.RunId -Command UsePrepared} ($intent+' '+$preference+' complete configuration does not fabricate partial acceptance')
 }}
 foreach($entry in @(@($registry,'Set-TCServerRecord'),@($transport,'Get-TCDeployVerifiedServerInfo'),@($transport,'Assert-TCDeployLiveIdentity'),@($transport,'Assert-TCDeploySessionRef'))){Assert-Check ((& $entry[0] {param($Name)(Get-Command $Name).Definition} $entry[1]) -ceq $realPolicy[$entry[1]]) ($entry[1]+' real policy was never replaced')}
 Assert-Check ($evidence.ForbiddenCalls -eq 0) 'No live executor or SSH process was invoked'
 foreach($name in @($sourceBefore.Keys)){$sourceAfter[$name]=(Get-FileHash -LiteralPath (Join-Path $PackageRoot $name)).Hash}
 Assert-Check (($sourceBefore|ConvertTo-Json -Compress) -ceq ($sourceAfter|ConvertTo-Json -Compress)) 'Production source stayed stable for the entire fixture workflow'
 Assert-Check ((Get-FileHash -LiteralPath $PSCommandPath).Hash -ceq $testSHA256) 'Test source stayed identical to the loaded script'
 $passed=$true
}catch{
 $failure=[pscustomobject]@{Message=([regex]::Replace($_.Exception.Message,'[A-Za-z0-9+/]{43}=','[redacted-key]'));SourceLine=$_.InvocationInfo.ScriptLineNumber;ExceptionType=$_.Exception.GetType().FullName}
}finally{
  $absolute=[IO.Path]::GetFullPath($root);$allowed=[IO.Path]::GetFullPath($workflowTempBase)+'\';if((Test-Path -LiteralPath $absolute) -and $absolute.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($absolute) -cmatch '^workflow-[a-f0-9]{32}$'){Remove-Item -LiteralPath $absolute -Recurse -Force};$removed=-not (Test-Path -LiteralPath $absolute)
  $null=[IO.Directory]::CreateDirectory($reportDirectory)
  $report=[ordered]@{Kind='TradeChannel.DeploymentWorkflowIntegration';Passed=($passed -and $removed);Runtime=$PSVersionTable.PSVersion.ToString();TestSHA256=$testSHA256;SourceSHA256=$sourceBefore;SourceSHA256After=$sourceAfter;SourcesStable=(($sourceBefore|ConvertTo-Json -Compress) -ceq ($sourceAfter|ConvertTo-Json -Compress));PassedCount=$checks.Count;Checks=$checks.ToArray();EvidenceReads=$evidence.Reads;ForbiddenCalls=$evidence.ForbiddenCalls;FixtureRemoved=$removed;PackageRoot=$PackageRoot;Failure=$failure;NetworkScope='Disposable fixture only; simulated executor/OS process observations and comparison; real registry policy/importer/wg keys/sing-box check'}
  [IO.File]::WriteAllText((Join-Path $reportDirectory ($ReportName+'.json')),($report|ConvertTo-Json -Depth 12),(New-Object Text.UTF8Encoding($false)))
  $lines=@($checks.ToArray())+@(('RESULT Passed={0} Checks={1} FixtureRemoved={2}' -f $report.Passed,$checks.Count,$removed));if($failure){$lines+=('FAIL '+$failure.Message)}
  [IO.File]::WriteAllLines((Join-Path $reportDirectory ($ReportName+'.log')),$lines,(New-Object Text.UTF8Encoding($false)))
}
Write-Output ('Deployment workflow: Passed={0}; assertions={1}; fixture removed={2}; report={3}' -f $report.Passed,$checks.Count,$removed,(Join-Path $reportDirectory ($ReportName+'.json')))
if(-not $report.Passed){exit 1}
