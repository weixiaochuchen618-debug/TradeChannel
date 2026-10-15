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
$legacyPerformance=@((Clone $udp),(Clone $tcp))
foreach($p in $legacyPerformance){$raw=Result $p;$raw|Add-Member NoteProperty Metrics ([pscustomobject]@{MedianResponseMs=$(if($p.Id -eq 'Udp'){1000}else{1});P95ResponseMs=1;PerformanceRanked=$true});$p.Validation=ConvertTo-TCProtocolEvidence -Result $raw -Profile $p -NetworkContext $context -Now $now}
$legacyChoice=Get-TCProtocolRecommendation -Profiles $legacyPerformance -NetworkContext $context -Now $now
Check ($legacyChoice.RecommendedProfileId -eq 'Udp' -and $legacyChoice.Source -eq 'PolicyDefault' -and -not $legacyChoice.PerformanceRanked) 'Old pooled median/p95 and a claimed ranking cannot replace paired same-target data'
$partial=@((Clone $udp),(Clone $tcp));$comparisonId=[guid]::NewGuid().ToString('D')
foreach($p in $partial){
 $raw=Result $p
 $raw|Add-Member NoteProperty Comparison ([pscustomobject]@{SchemaVersion=1;ComparisonId=$comparisonId;Completed=$false;PlannedPairRounds=3;CompletedPairRounds=1;CompletedProbes=2;SameNetwork=$true;SameBudget=$true;CleanupComplete=$true;StopCode=$null;CancellationRequested=$false})
 $raw|Add-Member NoteProperty Metrics ([pscustomobject]@{TargetMetrics=@([pscustomobject]@{Name='AddressHttps';Successful=[pscustomobject]@{MedianResponseMs=1};Failed=0;TimedOut=0})})
 $p.Validation=ConvertTo-TCProtocolEvidence -Result $raw -Profile $p -NetworkContext $context -Now $now
}
$partialDecision=Get-TCProtocolRecommendation -Profiles $partial -NetworkContext $context -Now $now
Check ($partialDecision.RecommendedProfileId -eq 'Udp' -and -not $partialDecision.PerformanceRanked -and $partialDecision.PerformanceReason -eq 'ComparisonDataInsufficient') 'Insufficient independent pair rounds keep the UDP policy default'
Check ($partialDecision.PolicyVersion -ceq 'PairedHttpsEngineering.v1' -and $partialDecision.PerformanceThresholds.PolicyKind -eq 'EngineeringScreen' -and (Test-TCProtocolRecommendationCurrent $partialDecision $partial $context -Now $now)) 'Recommendation includes a current engineering policy version even without ranking'
foreach($change in @('Quality','PairSamples','Metrics','Budget','Network','Cancellation','Cleanup')){
 $p=Clone $partial;$raw=$p[0].Validation.Result
 switch($change){
  'Quality'{$raw.Comparison.CompletedPairRounds=2}
  'PairSamples'{$raw|Add-Member NoteProperty Samples @([pscustomobject]@{Name='AddressHttps';DurationMs=999})}
  'Metrics'{$raw.Metrics.TargetMetrics[0].Successful.MedianResponseMs=999}
  'Budget'{$raw.Comparison.SameBudget=$false}
  'Network'{$raw.Comparison.SameNetwork=$false}
  'Cancellation'{$raw.Comparison.CancellationRequested=$true}
  'Cleanup'{$raw.Comparison.CleanupComplete=$false}
 }
 Check (-not (Test-TCProtocolRecommendationCurrent $partialDecision $p $context -Now $now)) ('Recommendation cannot survive comparison '+$change+' tampering')
}
$changedContext=Result $udp;$changedContext|Add-Member NoteProperty ContextChanged $true
Check (-not (ConvertTo-TCProtocolEvidence $changedContext $udp $context -Now $now).EligibleForAutomaticSelection) 'An explicit context-change latch overrides superficially matching fingerprints'
$budgetMismatch=Clone $partial[0].Validation.Result;$budgetMismatch.Comparison.SameBudget=$false
Check (-not (ConvertTo-TCProtocolEvidence $budgetMismatch $partial[0] $context -Now $now).EligibleForAutomaticSelection) 'A freshly normalized budget mismatch cannot acquire automatic eligibility'
$notPrepared=[pscustomobject]@{Status='NotTested';Code='ProfileUnavailable';CandidateHash=$null;CleanupComplete=$true;CheckedAtUtc=$now.ToString('o')}
$notPreparedEvidence=ConvertTo-TCProtocolEvidence -Result $notPrepared -Profile $tcp -NetworkContext $context -Now $now
Check ($notPreparedEvidence.Status -eq 'NotTested' -and $notPreparedEvidence.Code -eq 'ProfileUnavailable' -and -not $notPreparedEvidence.EligibleForAutomaticSelection) 'An absent prepared profile is not mislabeled as a configuration hash drift'
$blockedManual=Get-TCProtocolRecommendation -Profiles @($blocked,$tcp) -RequestedMode Tcp -NetworkContext $context -Now $now
Check ($blockedManual.Status -eq 'UserChoice' -and $blockedManual.PreferredProfileId -eq 'Tcp' -and -not $blockedManual.RecommendedProfileId -and -not $blockedManual.PerformanceRanked) 'Manual preference remains visible even when automatic selection is blocked'
$policyTamper=Clone $decision;$policyTamper.PolicyVersion='old'
Check (-not (Test-TCProtocolRecommendationCurrent $policyTamper @($udp,$tcp) $context -Now $now)) 'Old policy version cannot retain a current recommendation digest'
$thresholdTamper=Clone $decision;$thresholdTamper.PerformanceThresholds.MinimumAbsoluteAdvantageMs=1
Check (-not (Test-TCProtocolRecommendationCurrent $thresholdTamper @($udp,$tcp) $context -Now $now)) 'Changed engineering threshold cannot retain a current recommendation digest'
$out=[pscustomobject]@{Passed=$true;Checks=$checks;NetworkRequests=0;ProductionModulesInvoked=$false;PolicyVersion='PairedHttpsEngineering.v1';ComparisonDigestBound=$true;Cases='Qualification, old result reachability, policy default, manual priority, timestamp/hash/path/exit/cleanup barriers, engineering thresholds, comparison quality/samples/metrics/budget/network tampering, runtime scope'}
if($ReportPath){[IO.File]::WriteAllText($ReportPath,($out|ConvertTo-Json),(New-Object Text.UTF8Encoding($false)))}
$out|ConvertTo-Json
