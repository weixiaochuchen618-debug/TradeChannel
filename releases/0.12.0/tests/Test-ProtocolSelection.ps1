#requires -Version 5.1
[CmdletBinding()]param([string]$ReportPath)
$ErrorActionPreference='Stop';$env:PSModulePath=Join-Path $PSHOME 'Modules'
$package=Split-Path $PSScriptRoot -Parent
$module=Import-Module (Join-Path $package 'ProtocolSelection.psm1') -Force -PassThru -DisableNameChecking
$checks=0
function Check {param($Condition,[string]$Message) $script:checks++;if(-not $Condition){throw $Message}}
function Clone {param($Value) $Value|ConvertTo-Json -Depth 20|ConvertFrom-Json}
$now=[DateTimeOffset]::UtcNow
$context=[pscustomobject]@{Status='Known';Fingerprint=('C'*64)}
$udp=[pscustomobject]@{Id='Udp';CandidateSHA256=('A'*64);Validation=$null}
$tcp=[pscustomobject]@{Id='Tcp';CandidateSHA256=('B'*64);Validation=$null}
function Result {param($Profile,[string]$Status='Inconclusive',[bool]$PathVerified=$true)
 [pscustomobject]@{Status=$Status;Code='ForwardingPassedPhysicalPathUnverified';CandidateHash=$Profile.CandidateSHA256;CheckedAtUtc=$now.ToString('o');ForwardingPassed=$true;CleanupComplete=$true;ObservedExitIPv4='192.0.2.40';ExpectedExitIPv4='192.0.2.40';ExpectedExitSource='ServerVerifiedTlsTrace';TransportPath='BoundInterfaceObserved';NetworkFingerprint=$context.Fingerprint;PathEvidence=[pscustomobject]@{Kind='BoundInterfaceObserved';Verified=$PathVerified;EligibleForRecommendation=$PathVerified;NetworkFingerprint=$context.Fingerprint};Checks=@([pscustomobject]@{Name='AddressHttps';Status='Passed'},[pscustomobject]@{Name='DomainDnsHttps';Status='Passed'})}
}
foreach($p in @($udp,$tcp)){$p.Validation=ConvertTo-TCProtocolEvidence -Result (Result $p) -Profile $p -NetworkContext $context -Now $now}
Check ($udp.Validation.Status -ceq 'Passed' -and $udp.Validation.ForwardingPassed -and $udp.Validation.EligibleForAutomaticSelection) 'Layered proof did not qualify a current bound-path result'
$decision=Get-TCProtocolRecommendation -Profiles @($udp,$tcp) -NetworkContext $context -LineId 'fixture' -Now $now
Check ($decision.RecommendedProfileId -ceq 'Udp' -and $decision.Source -ceq 'PolicyDefault' -and -not $decision.PerformanceRanked -and $decision.RequiresUserActivation) 'Two qualified profiles must use explicit default policy, never claim performance ranking or auto activation'
Check (Test-TCProtocolRecommendationCurrent -Recommendation $decision -Profiles @($udp,$tcp) -NetworkContext $context -Now $now) 'Fresh recommendation failed binding'
$failedUdp=Clone $udp;$failedUdp.Validation=ConvertTo-TCProtocolEvidence -Result (Result $failedUdp Failed) -Profile $failedUdp -NetworkContext $context -Now $now
$tcpOnly=Get-TCProtocolRecommendation -Profiles @($failedUdp,$tcp) -NetworkContext $context -LineId 'fixture' -Now $now
Check ($tcpOnly.RecommendedProfileId -ceq 'Tcp' -and $tcpOnly.Source -ceq 'Reachability') 'Qualified TCP must beat known failed UDP'
$failedTcp=Clone $tcp;$failedTcp.Validation=ConvertTo-TCProtocolEvidence -Result (Result $failedTcp Failed) -Profile $failedTcp -NetworkContext $context -Now $now
$none=Get-TCProtocolRecommendation -Profiles @($failedUdp,$failedTcp) -NetworkContext $context -Now $now
Check ($none.Status -ceq 'Unavailable' -and -not $none.RecommendedProfileId -and -not $none.PreferredProfileId) 'Both failed silently fell back to UDP'
$unknownTcp=Clone $tcp;$unknownTcp.Validation=ConvertTo-TCProtocolEvidence -Result (Result $unknownTcp Inconclusive $false) -Profile $unknownTcp -NetworkContext $context -Now $now
$none=Get-TCProtocolRecommendation -Profiles @($failedUdp,$unknownTcp) -NetworkContext $context -Now $now
Check ($none.Status -ceq 'Inconclusive' -and -not $none.RecommendedProfileId) 'Path-unknown TCP or known-failed UDP was automatically selected'
$manual=Get-TCProtocolRecommendation -Profiles @($failedUdp,$unknownTcp) -RequestedMode Tcp -NetworkContext $context -Now $now
Check ($manual.Status -ceq 'UserChoice' -and $manual.PreferredProfileId -ceq 'Tcp' -and -not $manual.RecommendedProfileId) 'User choice was disguised as verified automatic recommendation'
foreach($change in @('Context','Hash','Expired','Future','MissingTimestamp','ExitMismatch','ExitUnknown','ExitPool','Cleanup','Active','PathUnverified','WrongPath','EvidenceId')){
 $p=Clone $udp;$raw=Result $p;$ctx=Clone $context
 switch($change){
  'Context'{$ctx.Fingerprint='D'*64}
  'Hash'{$raw.CandidateHash='D'*64}
  'Expired'{$raw.CheckedAtUtc=$now.AddMinutes(-31).ToString('o')}
  'Future'{$raw.CheckedAtUtc=$now.AddMinutes(5).ToString('o')}
  'MissingTimestamp'{$raw.CheckedAtUtc=''}
  'ExitMismatch'{$raw.ExpectedExitIPv4='192.0.2.41'}
  'ExitUnknown'{$raw.ExpectedExitSource='ConfiguredAddress'}
  'ExitPool'{$raw.Checks+=,[pscustomobject]@{Name='ExitConsistency';Status='Inconclusive'}}
  'Cleanup'{$raw.CleanupComplete=$false}
  'Active'{$raw.Code='ActiveIdentity'}
  'PathUnverified'{$raw.PathEvidence.Verified=$false}
  'WrongPath'{$raw.PathEvidence.Kind='ExistingSystemRoute'}
  'EvidenceId'{$raw.CheckedAtUtc=$now.AddSeconds(-2).ToString('o')}
 }
 $p.Validation=ConvertTo-TCProtocolEvidence -Result $raw -Profile $p -NetworkContext $ctx -Now $now
 if($change -ne 'EvidenceId'){Check (-not $p.Validation.EligibleForAutomaticSelection) ('Invalid evidence qualified: '+$change)}
 Check (-not (Test-TCProtocolRecommendationCurrent -Recommendation $decision -Profiles @($p,$tcp) -NetworkContext $ctx -Now $now)) ('Old decision survived changed evidence: '+$change)
}
$legacy=[pscustomobject]@{PathValidation='Failed';Code='CandidateForwardingFailed';ValidatedAt=$now.ToString('o');Result=(Result $udp Failed)}
$converted=ConvertTo-TCProtocolEvidence -Result $legacy -Profile $udp -NetworkContext $context -Now $now
Check ($converted.Status -ceq 'Failed') 'Legacy nested failure lost its failure status'
$blocked=Clone $udp;$blocked.Validation=ConvertTo-TCProtocolEvidence -Result ([pscustomobject]@{Status='Failed';Code='ProbeCleanupFailed';CleanupComplete=$false}) -Profile $blocked -NetworkContext $context -Now $now
$no=Get-TCProtocolRecommendation -Profiles @($blocked,$tcp) -NetworkContext $context -Now $now
Check ($no.Status -ceq 'Blocked' -and -not $no.RecommendedProfileId) 'Cleanup barrier allowed other candidate recommendation'
$cancelled=Clone $udp;$cancel=Result $cancelled;$cancel.Code='ProbeCancelled'
$cancelled.Validation=ConvertTo-TCProtocolEvidence -Result $cancel -Profile $cancelled -NetworkContext $context -Now $now
$cancelDecision=Get-TCProtocolRecommendation -Profiles @($cancelled,$tcp) -NetworkContext $context -Now $now
Check (-not $cancelled.Validation.EligibleForAutomaticSelection -and -not $cancelDecision.RecommendedProfileId) 'Explicit cancellation cannot leave or create an automatic recommendation'
$runtime=ConvertTo-TCProtocolEvidence -Result ([pscustomobject]@{ExitHttp=$true;DnsHttps=$true;ExitVerified=$true;ObservedIP='192.0.2.40';CheckedAtUtc=$now.ToString('o')}) -Profile $udp -Origin Runtime -NetworkContext $context -Now $now
Check ($runtime.Status -ceq 'Passed' -and -not $runtime.EligibleForAutomaticSelection) 'Current-session proof was promoted into next-network automatic eligibility'
$bound=Clone $udp;$bound.Validation.PathEvidence|Add-Member NoteProperty Binding ([pscustomobject]@{SchemaVersion=2;Scope='BoundPhysicalIPv4.v1';InterfaceIndex=7})
& $module {$script:PhysicalFixtureFingerprint='C'*64;$script:NetworkContextReader={param($Binding) if(-not $Binding){throw 'Expected the evidence-bound context'};[pscustomobject]@{Status='Available';Scope=$Binding.Scope;Fingerprint=$script:PhysicalFixtureFingerprint}}}
$globalSnapshot=[pscustomobject]@{Status='Available';Fingerprint=('E'*64)}
$underlay=Get-TCProtocolRecommendation -Profiles @($bound) -NetworkContext $globalSnapshot -LineId 'bound-fixture' -Now $now
Check ($underlay.Status -ceq 'Recommended' -and $underlay.NetworkFingerprint -ceq ('C'*64)) 'Recommendation must bind the tested underlay, not the global TUN snapshot'
$globalSnapshot.Fingerprint='F'*64
Check (Test-TCProtocolRecommendationCurrent -Recommendation $underlay -Profiles @($bound) -NetworkContext $globalSnapshot -Now $now) 'Expected own TUN change invalidated unchanged underlay'
& $module {$script:PhysicalFixtureFingerprint='D'*64}
Check (-not (Test-TCProtocolRecommendationCurrent -Recommendation $underlay -Profiles @($bound) -NetworkContext $globalSnapshot -Now $now)) 'Changed physical underlay kept the old recommendation'
& $module {$script:NetworkContextReader=$null}
$out=[pscustomobject]@{Passed=$true;Checks=$checks;NetworkRequests=0;ProductionModulesInvoked=$false;Cases='Qualification, no recommendation, TCP choice, policy default, user override, stale/context/hash/path/exit/cleanup barriers, old nested schema, runtime scope'}
if($ReportPath){[IO.File]::WriteAllText($ReportPath,($out|ConvertTo-Json),(New-Object Text.UTF8Encoding($false)))}
$out|ConvertTo-Json
