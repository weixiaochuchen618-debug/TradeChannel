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
# --- 0.18.4: a local preparation failure is not "ConfigurationChanged" -------------------------
$prep=Clone $raw;$prep.Status='Failed';$prep.Code='ProbePreparationFailed';$prep.ForwardingPassed=$false;$prep|Add-Member NoteProperty Samples @() -Force;$prep|Add-Member NoteProperty ConfigHash $null -Force;$prep.ProbeDerivative.ProbeSHA256=$null
$localEvidence=ConvertTo-TCProtocolEvidence $prep $profile $context -Now $now
Check ($localEvidence.Status -ceq 'Inconclusive' -and $localEvidence.Code -ceq 'LocalCheckUnavailable' -and $localEvidence.RawCode -ceq 'ProbePreparationFailed' -and -not $localEvidence.EligibleForAutomaticSelection) 'a preparation that sent nothing is LocalCheckUnavailable and keeps its raw code'
$stale=Clone $prep;$stale.Code='NetworkChangedDuringComparison';$stale.Status='Inconclusive'
Check ((ConvertTo-TCProtocolEvidence $stale $profile $context -Now $now).Code -ceq 'LocalCheckUnavailable') 'a binding change before any request is also only a local check problem'
$changedHash=Clone $prep;$changedHash.CandidateHash=('F'*64)
Check ((ConvertTo-TCProtocolEvidence $changedHash $profile $context -Now $now).Code -ceq 'ConfigurationChanged') 'a really different candidate hash is still ConfigurationChanged'
$changedManifest=Clone $prep;$changedManifest.ManifestHash=('F'*64)
Check ((ConvertTo-TCProtocolEvidence $changedManifest $profile $context -Now $now).Code -ceq 'ConfigurationChanged') 'a really different manifest hash is still ConfigurationChanged'
$attempted=Clone $prep;$attempted|Add-Member NoteProperty Samples @([pscustomobject]@{Name='AddressHttps';Attempted=$true}) -Force
Check ((ConvertTo-TCProtocolEvidence $attempted $profile $context -Now $now).Code -ceq 'ConfigurationChanged') 'a run that sent requests with a broken derivative is never excused as local'
# --- 0.18.4: the saved binding is recomputed in the mode that produced it -------------
# An AutomaticDefaultRoute binding carries SelectionMode/DefaultRoute fields. Replaying it
# with the resolved adapter index (an explicit plan) always differed, so every probe of a
# newly deployed line stopped before sending a request. Fake network context, no requests.
$pathModule=Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'ProbePath.psm1') -Force -PassThru -DisableNameChecking
function Reset-DerivativeNetwork {
 & $pathModule {
  $script:DerivativeNetwork=[pscustomobject]@{Interfaces=@();Routes=@()}
  foreach($index in @(7,8)){
   $script:DerivativeNetwork.Interfaces+=,[pscustomobject]@{Index=$index;Id=('nic-'+$index);Name=('Physical '+$index);Status='Up';Type='Ethernet';Hardware=$true;Metric=$(if($index -eq 7){100}else{10});Addresses=@([pscustomobject]@{Address=('192.0.2.'+$index);Family='InterNetwork';PrefixLength=24;State='Preferred'});Gateways=@('192.0.2.1');DnsServers=@('192.0.2.53')}
   $script:DerivativeNetwork.Routes+=,[pscustomobject]@{InterfaceIndex=$index;DestinationPrefix='0.0.0.0/0';NextHop='192.0.2.1';RouteMetric=$(if($index -eq 7){5}else{20});AddressFamily='IPv4'}
  }
  function script:Read-TCProbeNetworkState {$script:DerivativeNetwork}
 }
}
function New-DerivativeCandidate {
 [pscustomobject]@{endpoints=@([pscustomobject]@{type='wireguard';tag='hk';peers=@([pscustomobject]@{address='198.51.100.10';port=51820})});dns=[pscustomobject]@{servers=@([pscustomobject]@{tag='dns-direct';type='udp';server='192.0.2.53';server_port=53})}}
}
function Invoke-Derivative {param($Candidate,$Binding)
 $failure='';$derived=$null
 try{$derived=& $pathModule {param($c,$m,$b)New-TCProbeDerivative $c $m $b} $Candidate ([pscustomobject]@{}) $Binding}catch{$failure=[string]$_.Exception.Message}
 [pscustomobject]@{Derived=$derived;Failure=$failure}
}
Reset-DerivativeNetwork
$candidate=New-DerivativeCandidate
$auto=& $pathModule {param($c)Get-TCProbeBindingPlan -Candidate $c -DirectDnsIPv4 '192.0.2.53' -InterfaceIndex 0} $candidate
Check ($auto.Status -ceq 'Ready' -and $auto.Binding.SelectionMode -ceq 'AutomaticDefaultRoute' -and $auto.Binding.DefaultRouteFingerprint -cmatch '^[A-F0-9]{64}$' -and $auto.Binding.InterfaceIndex -eq 8) 'automatic fixture binding records the default-route selection'
$replay=Invoke-Derivative $candidate $auto.Binding
Check (-not $replay.Failure -and $replay.Derived.endpoints[0].bind_interface -ceq 'Physical 8' -and $replay.Derived.endpoints[0].inet4_bind_address -ceq '192.0.2.8' -and $replay.Derived.dns.servers[0].bind_interface -ceq 'Physical 8') 'an automatic binding is derived without ProbeBindingChanged and binds the selected adapter'
$explicit=& $pathModule {param($c)Get-TCProbeBindingPlan -Candidate $c -DirectDnsIPv4 '192.0.2.53' -InterfaceIndex 7} $candidate
$explicitReplay=Invoke-Derivative $candidate $explicit.Binding
Check ($explicit.Binding.SelectionMode -ceq 'ExplicitInterface' -and -not $explicitReplay.Failure -and $explicitReplay.Derived.endpoints[0].bind_interface -ceq 'Physical 7') 'an explicit binding still derives in explicit mode'
Check ((Invoke-Derivative $candidate $explicit.Binding).Failure -ceq '' ) 'explicit binding is not switched by the default-route rank'
# The default route really changed: adapter 7 now has the lowest total metric.
& $pathModule {$script:DerivativeNetwork.Interfaces[0].Metric=0}
$changed=Invoke-Derivative $candidate $auto.Binding
Check ($changed.Failure -ceq 'ProbeBindingChanged' -and -not $changed.Derived) 'a changed default route still yields ProbeBindingChanged'
$stillExplicit=Invoke-Derivative $candidate $explicit.Binding
Check (-not $stillExplicit.Failure) 'an explicit binding survives a default-route change because it never followed the default route'
Reset-DerivativeNetwork
& $pathModule {$script:DerivativeNetwork.Interfaces[1].Addresses=@([pscustomobject]@{Address='192.0.2.88';Family='InterNetwork';PrefixLength=24;State='Preferred'})}
Check ((Invoke-Derivative $candidate $auto.Binding).Failure -ceq 'ProbeBindingChanged') 'a changed source address still yields ProbeBindingChanged'
# Path assessment must reconstruct the complete selection contract. Omitting
# its route metadata used to invalidate a successful probe during normalization.
Reset-DerivativeNetwork
$tcpCandidate=New-DerivativeCandidate
$tcpCandidate.endpoints[0]|Add-Member NoteProperty detour 'tc-transport'
$tcpCandidate|Add-Member NoteProperty outbounds @([pscustomobject]@{type='vless';tag='tc-transport';server='198.51.100.10';server_port=443})
function Assess-DerivativeBinding {param($Candidate,$Binding,$Config)
 if(-not $Config){$Config=& $pathModule {param($c,$b)New-TCProbeDerivative $c ([pscustomobject]@{}) $b} $Candidate $Binding}
 $ctx=Get-TCProbeNetworkContext -Binding $Binding
 $observation=[pscustomobject]@{Status='Available';ProcessId=42;ProcessStartTicks=123;Reads=2;Errors=0;Overflow=$false;NetworkChanges=0;Rows=@([pscustomobject]@{ProcessId=42;LocalAddress=$Binding.LocalAddress;LocalPort=50000;RemoteAddress='198.51.100.10';RemotePort=443;AddressFamily='IPv4';State=5;Source='GetExtendedTcpTable'})}
 & $pathModule {param($c,$b,$ctx,$o)Get-TCProbePathAssessment $c ([pscustomobject]@{ProbeBinding=$b}) ([pscustomobject]@{Id='Tcp'}) @($ctx,$ctx) $o $true} $Config $Binding $ctx $observation
}
foreach($mode in @('AutomaticDefaultRoute','ExplicitInterface')){
 $index=if($mode -ceq 'AutomaticDefaultRoute'){0}else{7}
 $plan=Get-TCProbeBindingPlan -Candidate $tcpCandidate -DirectDnsIPv4 '192.0.2.53' -InterfaceIndex $index
 $derived=& $pathModule {param($c,$b)New-TCProbeDerivative $c ([pscustomobject]@{}) $b} $tcpCandidate $plan.Binding
 $assessment=Assess-DerivativeBinding $tcpCandidate $plan.Binding $derived
 Check ($assessment.Verified -and ($assessment.Binding|ConvertTo-Json -Depth 20 -Compress) -ceq ($plan.Binding|ConvertTo-Json -Depth 20 -Compress)) ($mode+' path proof preserves the complete independently reconstructed binding')
 if($mode -ceq 'AutomaticDefaultRoute'){
  $autoBinding=Clone $plan.Binding;$autoConfig=Clone $derived
  foreach($field in @('NextHop','InterfaceId','EffectiveMetric')){
   $bad=Clone $plan.Binding
   if($field -ceq 'EffectiveMetric'){$bad.DefaultRoute.$field++}else{$bad.DefaultRoute.$field='tampered'}
   $rejected=Assess-DerivativeBinding $tcpCandidate $bad $derived
   Check (-not $rejected.Verified -and $rejected.Reason -ceq 'StoredBindingContextMismatch') ('saved default-route '+$field+' is verified from the snapshot')
  }
  $bad=Clone $plan.Binding;$bad.DefaultRouteFingerprint='F'*64
  Check (-not (Assess-DerivativeBinding $tcpCandidate $bad $derived).Verified) 'changed automatic route fingerprint is rejected'
 }else{
  $explicitBinding=Clone $plan.Binding;$explicitConfig=Clone $derived
  Check ($null -eq $assessment.Binding.DefaultRoute -and $null -eq $assessment.Binding.DefaultRouteFingerprint) 'explicit evidence has no fabricated automatic-route metadata'
 }
 $bad=Clone $plan.Binding;$bad.SelectionMode='Unrecognized'
 Check (-not (Assess-DerivativeBinding $tcpCandidate $bad $derived).Verified) 'unknown selection mode cannot verify a path'
}
& $pathModule {$script:DerivativeNetwork.Interfaces[0].Metric=0}
Check (-not (Assess-DerivativeBinding $tcpCandidate $autoBinding $autoConfig).Verified) 'default-route change invalidates automatic path assessment'
Check ((Assess-DerivativeBinding $tcpCandidate $explicitBinding $explicitConfig).Verified) 'explicit path assessment survives an unrelated default-route rank change'
$result=[pscustomobject]@{Passed=$true;Checks=$checks;NetworkRequests=0;Scope='actual evidence conversion and recorded qualification; automatic and explicit probe derivation and complete path-binding provenance'}
if($ReportPath){$result|ConvertTo-Json|Set-Content -LiteralPath $ReportPath -Encoding UTF8};$result|ConvertTo-Json -Compress
