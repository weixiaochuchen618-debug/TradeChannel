#requires -Version 5.1
$ErrorActionPreference='Stop';$env:PSModulePath=Join-Path $PSHOME 'Modules'
$root=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'LineRecovery.psm1') -Force -DisableNameChecking
$checks=0
function Check {param([bool]$Ok,[string]$Label)if(-not $Ok){throw $Label};$script:checks++}
$r=Get-TCRecoveryDecision -ActiveTarget $true -ActiveCheck @{ExitHttp=$true;ObservedIP='1.1.1.1'}
# The real bridge returns a PSCustomObject, not untyped remote JSON maps.
$r=Get-TCRecoveryDecision -ActiveTarget $true -ActiveCheck ([pscustomobject]@{ExitHttp=$true;ObservedIP='1.1.1.1'})
Check ($r.Code -eq 'ActiveForwardingPassed' -and -not $r.CanPrepareTcp) 'working UDP is not classified as requiring TCP'
$r=Get-TCRecoveryDecision -ActiveTarget $true -ActiveCheck ([pscustomobject]@{ExitHttp=$true;ObservedIP=$null})
Check ($r.Code -eq 'ActiveForwardingUnverified') 'HTTP success without exit trace does not claim verified forwarding'
$r=Get-TCRecoveryDecision -ActiveTarget $false -CandidateCheck ([pscustomobject]@{Code='ActiveIdentity'})
Check ($r.Code -eq 'IdentityInUse' -and -not $r.NetworkChanged) 'active peer is not probed concurrently'
$r=Get-TCRecoveryDecision -ActiveTarget $false -CandidateCheck ([pscustomobject]@{Code='ForwardingPassedPhysicalPathUnverified';ObservedExitIPv4='192.0.2.40';Checks=@([pscustomobject]@{Name='AddressHttps';Status='Passed'},[pscustomobject]@{Name='DomainDnsHttps';Status='Passed'})})
Check ($r.Code -eq 'CandidateForwardingPassed' -and $r.Summary -like '*物理*') 'candidate forwarding and switched physical route remain distinct'
$r=Get-TCRecoveryDecision -ActiveTarget $false -CandidateCheck ([pscustomobject]@{Code='ExpectedExitUnverified';ObservedExitIPv4='1.1.1.1';Checks=@([pscustomobject]@{Name='AddressHttps';Status='Passed'},[pscustomobject]@{Name='DomainDnsHttps';Status='Passed'})})
Check ($r.Code -eq 'CandidateForwardingPassed' -and $r.Summary -like '*归属*未核验*') 'successful forwarding is not hidden when authoritative egress identity is unavailable'
$r=Get-TCRecoveryDecision -ActiveTarget $false -CandidateCheck ([pscustomobject]@{Code='CandidateForwardingFailed'})
Check ($r.Code -eq 'ForwardingNotVerified' -and $r.Summary -like '*不能证明 UDP*') 'timeout does not claim UDP blocking'
# Exercise the production dispatcher through a private disposable I/O seam.
$recovery=Get-Module LineRecovery
$dispatch=& $recovery {
 $script:Ops=New-Object 'Collections.Generic.List[string]';$script:RecoveryChecks=0
 function script:AssertRecovery {param($Ok,$Message)if(-not $Ok){throw $Message};$script:RecoveryChecks++}
 $line=[pscustomobject]@{LineId='11111111-1111-1111-1111-111111111111';SourceNodeId='11111111-1111-1111-1111-111111111111';Name='isolated';Profiles=@([pscustomobject]@{Id='Udp';ManifestPath='fixture-original.manifest'})}
 $script:LineFixture=$line;$script:Drift=$false
 $script:View=[pscustomobject]@{Overview=[pscustomobject]@{Running=$true;SessionPresent=$true;ProfileBindingVerified=$true;ActiveLineId=$line.LineId;ActiveProfileId='Udp';Exit='hk';ManifestPath='approved-clone.manifest'};Identity=[pscustomobject]@{SessionId='fixture-session';EnginePid=202;EngineStartedAt='2026-01-01T00:00:01Z';SupervisorPid=201;SupervisorStartedAt='2026-01-01T00:00:00Z';ManifestPath='approved-clone.manifest';CandidateSHA256=('A'*64)};ServerPublicKey='fixture-server';ClientPublicKey='fixture-device';ClientAddress='10.9.0.2/32'}
 $script:RecoveryTestAdapter={param($Operation,$Root,$Payload)
  if($Root -cne 'fixture'){throw 'Recovery adapter rejected non-fixture root'}
  $script:Ops.Add($Operation)
  switch($Operation){
   'Line'{return $script:LineFixture}
   'Observe'{return ($script:View|ConvertTo-Json -Depth 12|ConvertFrom-Json)}
   'TargetIdentity'{return [pscustomobject]@{ServerPublicKey='fixture-server';ClientPublicKey='fixture-device';ClientAddress='10.9.0.2/32'}}
   'ActiveCheck'{if($script:Drift){$script:View.Identity.EngineStartedAt='2026-01-01T01:00:00Z'};return [pscustomobject]@{ExitHttp=$true;ObservedIP='192.0.2.40';TradingViewHttp=$false}}
   default{throw ('Forbidden candidate/preparation operation: '+$Operation)}
  }
 }
 try{
  foreach($path in @('approved-clone.manifest','original.manifest','registered-profile.manifest')){
   $script:View.Overview.ManifestPath=$path;$script:View.Identity.ManifestPath=$path;$script:Ops.Clear()
   $r=Get-TCConnectionRecovery -Root 'fixture' -Id $line.LineId
   AssertRecovery ($r.Code -eq 'ActiveForwardingPassed' -and $r.NextAction -eq 'None' -and -not $r.CanPrepareTcp -and $r.Layers.Identity -eq 'VerifiedActiveSession' -and $r.Layers.Application -eq 'UserVerificationRequired') 'Bound running profile did not use current diagnostics'
   AssertRecovery ($script:Ops -notcontains 'Candidate' -and $script:Ops -notcontains 'Preparation') 'Active identity launched or prepared a candidate'
  }
  $script:View.Overview.ActiveLineId='another-line';$r=Get-TCConnectionRecovery -Root 'fixture' -Id $line.LineId
  AssertRecovery ($r.Code -eq 'IdentityInUse' -and -not $r.ActiveTarget -and -not $r.CanPrepareTcp) 'Same identity falsely attributed different config to target line'
  $script:View.Overview.ActiveLineId=$line.LineId;$script:Drift=$true
  $r=Get-TCConnectionRecovery -Root 'fixture' -Id $line.LineId
  AssertRecovery ($r.Code -eq 'NeedsRecovery' -and $r.NextAction -eq 'ResolveSession') 'Process birth drift during diagnostics accepted'
  $script:Drift=$false;$script:View.Overview.Exit='provider';$r=Get-TCConnectionRecovery -Root 'fixture' -Id $line.LineId
  AssertRecovery ($r.Code -eq 'CurrentExitNotTarget' -and -not $r.CanPrepareTcp) 'Provider forwarding blessed UDP'
  $script:View.Overview.Running=$false;$script:Ops.Clear();$r=Get-TCConnectionRecovery -Root 'fixture' -Id $line.LineId
  AssertRecovery ($r.Code -eq 'NeedsRecovery' -and $script:Ops -notcontains 'Candidate' -and $script:Ops -notcontains 'ActiveCheck') 'Unknown ownership started a diagnostic candidate'
  $script:RecoveryChecks
 }finally{$script:RecoveryTestAdapter=$null}
}
$checks+=$dispatch
$r=Get-TCRecoveryDecision -CandidateCheck ([pscustomobject]@{Code='ForwardingPassedPhysicalPathUnverified'})
Check ($r.Code -eq 'ForwardingNotVerified') 'a favorable code without forwarding checks is not proof'
$r=Get-TCRecoveryDecision -CandidateCheck ([pscustomobject]@{Result=[pscustomobject]@{Code='ExpectedExitUnverified';ObservedExitIPv4='192.0.2.40';CleanupComplete=$false;Checks=@([pscustomobject]@{Name='AddressHttps';Status='Passed'},[pscustomobject]@{Name='DomainDnsHttps';Status='Passed'})}})
Check ($r.Code -eq 'NeedsRecovery' -and -not $r.CanPrepareTcp -and $r.NextAction -eq 'ResolveSession') 'cleanup failure was hidden by forwarding'
$r=Get-TCRecoveryDecision -CandidateCheck ([pscustomobject]@{ObservedExitIPv4='192.0.2.40';ExpectedExitIPv4='192.0.2.41';ExpectedExitSource='ServerVerifiedTlsTrace';CleanupComplete=$true;Checks=@([pscustomobject]@{Name='AddressHttps';Status='Passed'},[pscustomobject]@{Name='DomainDnsHttps';Status='Passed'})})
Check ($r.Code -eq 'CandidateExitMismatch' -and $r.Layers.Forwarding -eq 'Passed' -and $r.Layers.ExitBinding -eq 'Failed' -and $r.NextAction -eq 'CheckServerIdentity') 'exit attribution mismatch lost its layer'
# A bound-interface observation is narrower than physical-directness proof.
$bound=Get-TCRecoveryDecision -CandidateCheck ([pscustomobject]@{ObservedExitIPv4='192.0.2.40';CleanupComplete=$true;Checks=@([pscustomobject]@{Name='AddressHttps';Status='Passed'},[pscustomobject]@{Name='DomainDnsHttps';Status='Passed'});PathEvidence=[pscustomobject]@{Kind='BoundInterfaceObserved';Verified=$true;EligibleForRecommendation=$true}})
Check ($bound.Layers.PhysicalPath -eq 'BoundInterfaceObserved' -and $bound.Layers.PhysicalPath -ne 'PhysicalDirect') 'bound interface observation is not a physical directness claim'
# Check that actual exit validation retries the network check without calling
# any mutation. Fake reader scripts and module function replacements are scoped
# to this disposable test and never execute a production channel command.
$fixtureParent=Join-Path (Split-Path (Split-Path $root -Parent) -Parent) 'reports\release-0.12.0'
$null=[IO.Directory]::CreateDirectory($fixtureParent)
$work=Join-Path $fixtureParent ('TC-LineReadiness-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path (Join-Path $work 'runtime') -Force
$reader=@'
param([string]$Url='https://1.1.1.1/cdn-cgi/trace',[string]$Lane='Trade')
if($Url -like '*1.1.1.1*'){[pscustomobject]@{CurlExit=28;HTTPStatus=0;ObservedIP=$null}}
elseif($Url -like '*cloudflare*'){[pscustomobject]@{CurlExit=0;HTTPStatus=200;ObservedIP='1.1.1.1'}}
else{[pscustomobject]@{CurlExit=0;HTTPStatus=200;ObservedIP=$null}}
'@
[IO.File]::WriteAllText((Join-Path $work 'runtime\Test-SelectedTradeExit.ps1'),$reader,[Text.Encoding]::UTF8)
$module=Import-Module (Join-Path $root 'RuntimeBridge.psm1') -Force -PassThru -DisableNameChecking
try{
 $result=& $module {
  param($Fixture)
  $script:Package=$Fixture;$script:Root=$Fixture
  function script:Assert-TCConnectionDiagnosticRoot {if($script:Root -cne $script:Package -or [IO.Path]::GetFileName($script:Root) -notmatch '^TC-LineReadiness-[a-f0-9]{32}$'){throw 'Diagnostic fixture root mismatch'}}
  function script:Get-CimInstance {throw 'Real process inventory forbidden'}
  function script:Start-Process {throw 'Real process start forbidden'}
  function script:Stop-Process {throw 'Real process stop forbidden'}
  function script:Invoke-WebRequest {throw 'Real HTTP forbidden'}
  function script:Invoke-RestMethod {throw 'Real HTTP forbidden'}
  function script:Get-TCOverview {[pscustomobject]@{Running=$true;DailySupported=$false;Mode='rule';Daily='direct';AgentsSupported=$false;Agents='Daily'}}
  function script:Get-TCInstalledDeployment {$null}
  function script:Get-TCExitLatency {$null}
  function script:Invoke-TCCommand {throw 'readiness must not change network'}
  Test-TCActiveConnection
 } $work
 Check ($result.ExitHttp -and $result.ObservedIP -eq '1.1.1.1' -and $result.ExitChecks.Count -eq 2) 'cold connection timeout retries another trusted trace and preserves evidence'
 Check ($result.TradingViewHttp -and $result.Control -eq '通过') 'exit retry still checks the application target'
 [pscustomobject]@{Passed=$true;Checks=$checks;RealNetworkChanges=0}|ConvertTo-Json -Compress
}finally{
 Remove-Module RuntimeBridge -ErrorAction SilentlyContinue
 $full=[IO.Path]::GetFullPath($work);$base=[IO.Path]::GetFullPath($fixtureParent).TrimEnd('\')+'\'
 if(-not $full.StartsWith($base,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -cnotmatch '^TC-LineReadiness-[a-f0-9]{32}$'){throw 'Unexpected fixture cleanup boundary.'}
 Remove-Item -LiteralPath $full -Recurse -Force
}
