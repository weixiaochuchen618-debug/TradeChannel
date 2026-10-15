#requires -Version 5.1
param([string]$ReportPath)
$ErrorActionPreference='Stop';$checks=0
$module=Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'ProtocolSelection.psm1') -Force -DisableNameChecking -PassThru
& $module {$script:NetworkContextReader={param($binding)[pscustomobject]@{Status='Available';Fingerprint=('C'*64)}}}
function Check {param($ok,$name)if(-not $ok){throw $name};$script:checks++}
function Clone {param($o)$o|ConvertTo-Json -Depth 20|ConvertFrom-Json}
$now=[DateTimeOffset]::UtcNow;$context=@{Status='Available';Fingerprint=('C'*64)}
$profile=[pscustomobject]@{Id='Udp';CandidateSHA256=('A'*64);ManifestSHA256=('B'*64)}
$binding=[pscustomobject]@{NetworkFingerprint=('C'*64);InterfaceId='f809fc82-6586-4627-a1b5-fbd68fb578ea';InterfaceIndex=7;InterfaceName='Fixture';LocalAddress='192.0.2.20'}
$raw=[pscustomobject]@{Status='Passed';Code='CandidateReachabilityVerified';ForwardingPassed=$true;CleanupComplete=$true;CandidateHash=('A'*64);ManifestHash=('B'*64);ConfigHash=('D'*64);RunId='a584b46f-f602-439d-8f6a-ac6327889477';CheckedAtUtc=$now.ToString('o');ObservedExitIPv4='198.51.100.1';ExpectedExitIPv4='198.51.100.1';ExpectedExitSource='ServerVerifiedTlsTrace';NetworkFingerprint=('C'*64);ProbeDerivativeRequired=$true;ProbeDerivative=[pscustomobject]@{SchemaVersion=1;BaseCandidateSHA256=('A'*64);BaseManifestSHA256=('B'*64);ProbeSHA256=('D'*64);Binding=$binding;EvidenceId='a584b46f-f602-439d-8f6a-ac6327889477'};PathEvidence=@{Kind='PhysicalDirect';Verified=$true;EligibleForRecommendation=$true;NetworkFingerprint=('C'*64);Binding=$binding};Checks=@(@{Name='AddressHttps';Status='Passed'},@{Name='DomainDnsHttps';Status='Passed'})}
$evidence=ConvertTo-TCProtocolEvidence -Result $raw -Profile $profile -NetworkContext $context -Now $now
Check ($evidence.EligibleForAutomaticSelection -and $evidence.ProbeDerivativeDigest -and (Test-TCProtocolEvidenceCurrent $evidence $profile $context -Now $now)) 'valid derivative qualifies only for its own base profile'
foreach($field in @('BaseCandidateSHA256','BaseManifestSHA256','ProbeSHA256','EvidenceId')){
 $bad=Clone $raw;$bad.ProbeDerivative.$field='invalid'
 Check (-not (ConvertTo-TCProtocolEvidence $bad $profile $context -Now $now).EligibleForAutomaticSelection) ('changed derivative '+$field+' rejected during conversion')
 $bad=Clone $evidence;$bad.Result.ProbeDerivative.$field='invalid'
 Check (-not (Test-TCProtocolEvidenceCurrent $bad $profile $context -Now $now)) ('changed recorded derivative '+$field+' rejected')
}
$bad=Clone $raw;$bad.ProbeDerivative=$null
Check (-not (ConvertTo-TCProtocolEvidence $bad $profile $context -Now $now).EligibleForAutomaticSelection) 'new probe cannot drop its required derivation'
$bad=Clone $evidence;$bad.Result.ProbeDerivative=$null;$bad.Result.ProbeDerivativeRequired=$false
Check (-not (Test-TCProtocolEvidenceCurrent $bad $profile $context -Now $now)) 'removing derivative and its flag cannot retain recorded qualification'
$bad=Clone $raw;$bad.ProbeDerivative.Binding.LocalAddress='192.0.2.21'
Check (-not (ConvertTo-TCProtocolEvidence $bad $profile $context -Now $now).EligibleForAutomaticSelection) 'binding and path evidence must refer to the same probe network'
$bad=Clone $profile;$bad.ManifestSHA256='E'*64
Check (-not (Test-TCProtocolEvidenceCurrent $evidence $bad $context -Now $now)) 'new manifest cannot inherit the old probe result'
$result=[pscustomobject]@{Passed=$true;Checks=$checks;NetworkRequests=0;Scope='actual evidence conversion and recorded qualification'}
if($ReportPath){$result|ConvertTo-Json|Set-Content -LiteralPath $ReportPath -Encoding UTF8};$result|ConvertTo-Json -Compress
