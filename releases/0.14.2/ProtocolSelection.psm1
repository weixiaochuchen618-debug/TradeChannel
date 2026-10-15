#requires -Version 5.1
Set-StrictMode -Version 2.0
$script:NetworkContextReader=$null
$script:TCProtocolPolicyVersion='PairedHttpsEngineering.v1'
function PSelField {param($Value,[string]$Name,$Default=$null)
 if($Value -is [Collections.IDictionary]){if($Value.Contains($Name)){return $Value[$Name]}}
 elseif($null -ne $Value -and $Value.PSObject.Properties[$Name]){return $Value.$Name};$Default
}
function PSelDigest {param($Value)
 $sha=[Security.Cryptography.SHA256]::Create()
 try{$json=ConvertTo-Json -InputObject $Value -Depth 25 -Compress;([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($json)))).Replace('-','')}finally{$sha.Dispose()}
}
function PSelComparisonDigest {param($Raw) PSelDigest $Raw }
function Get-TCProtocolNetworkContext {
 [CmdletBinding()]param($Binding)
 if($script:NetworkContextReader){return & $script:NetworkContextReader $Binding}
 try{
  Import-Module (Join-Path $PSScriptRoot 'ProbePath.psm1') -DisableNameChecking -ErrorAction Stop
  if($Binding){Get-TCProbeNetworkContext -Binding $Binding}else{Get-TCProbeNetworkContext}
 }catch{[pscustomobject]@{Status='Unavailable';Fingerprint=$null;ObservedAt=[DateTimeOffset]::UtcNow.ToString('o');Reason='无法核对当前网络环境；不根据历史结果自动选择。'}}
}
function PSelEvidenceContext {param($Evidence,$Context)
 $binding=PSelField (PSelField $Evidence PathEvidence) Binding
 if($binding){return Get-TCProtocolNetworkContext -Binding $binding}
 $Context
}
function PSelMedian {param($Values)
 $v=@($Values|Sort-Object);if(-not $v.Count){return $null};$n=$v.Count
 if($n%2){return [double]$v[[int][Math]::Floor($n/2)]};([double]$v[$n/2-1]+[double]$v[$n/2])/2.0
}
function PSelRecommendationDigest {param($Recommendation)
 PSelDigest ([ordered]@{PolicyVersion=(PSelField $Recommendation PolicyVersion '');LineId=(PSelField $Recommendation LineId '');ProfileId=(PSelField $Recommendation PreferredProfileId);Source=(PSelField $Recommendation Source '');Hash=(PSelField $Recommendation CandidateSHA256);Network=(PSelField $Recommendation NetworkFingerprint);EvidenceIds=@(PSelField $Recommendation EvidenceIds @());SelectionData=@(PSelField $Recommendation SelectionData @());PerformanceRanked=[bool](PSelField $Recommendation PerformanceRanked $false);PerformanceReason=(PSelField $Recommendation PerformanceReason);PerformanceThresholds=(PSelField $Recommendation PerformanceThresholds);PairedSampleCount=(PSelField $Recommendation PairedSampleCount 0);PairedRoundCount=(PSelField $Recommendation PairedRoundCount 0);TargetComparisons=@(PSelField $Recommendation TargetComparisons @())})
}
function PSelPerformanceAssessment {param($UdpEvidence,$TcpEvidence,[DateTimeOffset]$Now)
 $thresholds=[pscustomobject]@{PolicyVersion=$script:TCProtocolPolicyVersion;PolicyKind='EngineeringScreen';MinimumPairedRounds=3;MinimumPairsPerTarget=9;MinimumAbsoluteAdvantageMs=20;MinimumRelativeAdvantage=0.20;RequiredRoundWinFraction=1.0;TargetConsensus='EveryRequiredTarget';IndependentUnit='ComparisonRound';PairingUnit='ComparisonRound, TargetUrl, SampleRound';Measurement='Bounded HTTPS response; not transaction latency or packet loss'}
 $out=[pscustomobject]@{PerformanceRanked=$false;Winner=$null;Reason='ComparisonDataInsufficient';PairedRoundCount=0;PairedSampleCount=0;Thresholds=$thresholds;TargetComparisons=@()}
 $uRaw=PSelField $UdpEvidence Result;$tRaw=PSelField $TcpEvidence Result
 $u=PSelField $uRaw Comparison;$t=PSelField $tRaw Comparison
 if(-not $u -or -not $t){return $out}
 $guid=[guid]::Empty
 if(-not [guid]::TryParse([string](PSelField $u ComparisonId ''),[ref]$guid) -or $guid -eq [guid]::Empty -or (PSelField $u ComparisonId '') -cne (PSelField $t ComparisonId '') -or (PSelDigest $u) -cne (PSelDigest $t)){ $out.Reason='ComparisonIdentityMismatch';return $out }
 if((PSelField $u SchemaVersion 0) -ne 1 -or -not (PSelField $u Completed $false) -or (PSelField $u PlannedPairRounds 0) -ne 3 -or (PSelField $u CompletedPairRounds 0) -ne 3 -or (PSelField $u CompletedProbes 0) -ne 6){return $out}
 if(-not (PSelField $u CleanupComplete $false) -or -not (PSelField $u SameNetwork $false) -or -not (PSelField $u SameBudget $false) -or (PSelField $u StopCode '') -or (PSelField $u CancellationRequested $false) -or (PSelField $u Concurrency 0) -ne 1 -or (PSelField $u RequestRetries -1) -ne 0 -or (PSelField $u RequestBudgetSeconds 0) -ne 6 -or (PSelField $u MaxRequests 0) -ne 42 -or (PSelField $u RequestsAttempted 0) -ne 42 -or (PSelField $u MaxProbes 0) -ne 6 -or (PSelField $u SampleBudgetPerProbe 0) -ne 6 -or (PSelField $u ApplicationBudgetPerProbe 0) -ne 1){$out.Reason='ComparisonSafetyOrBudgetUnverified';return $out}
 $snapshot=[string](PSelField $u SnapshotFingerprint '')
 if($snapshot -notmatch '^[A-Fa-f0-9]{64}$' -or (PSelField $UdpEvidence ObservedExitIPv4 '') -cne (PSelField $TcpEvidence ObservedExitIPv4 '')){$out.Reason='ComparisonNetworkOrExitMismatch';return $out}
 $targets=@(PSelField $u FixedTargets @());$required=@($targets|Where-Object {(PSelField $_ Trace $false) -and (PSelField $_ Name '') -in @('AddressHttps','DomainDnsHttps')})
 if($targets.Count -ne 3 -or $required.Count -ne 2 -or @($required|ForEach-Object {PSelField $_ Name ''}|Sort-Object -Unique).Count -ne 2){return $out}
 $uRuns=@(PSelField $uRaw ProbeRuns @());$tRuns=@(PSelField $tRaw ProbeRuns @())
 if($uRuns.Count -ne 3 -or $tRuns.Count -ne 3){return $out}
 $all=@($uRuns)+@($tRuns);$sequence=@($all|Sort-Object Sequence)
 $expected=@('Udp','Tcp','Tcp','Udp','Udp','Tcp');$engine=[string](PSelField $UdpEvidence EngineSHA256 '')
 if($engine -notmatch '^[A-Fa-f0-9]{64}$' -or $engine -cne (PSelField $TcpEvidence EngineSHA256 '')){$out.Reason='ComparisonEngineUnverified';return $out}
 for($i=0;$i -lt 6;$i++){
  $run=$sequence[$i];$raw=PSelField $run Result;$profileId=$expected[$i];$evidence=if($profileId -eq 'Udp'){$UdpEvidence}else{$TcpEvidence};$path=PSelField $raw PathEvidence
  if((PSelField $run Sequence 0) -ne ($i+1) -or (PSelField $run PairRound 0) -ne ([int][Math]::Floor($i/2)+1) -or (PSelField $run OrderPosition 0) -ne ($i%2+1) -or (PSelField $run ProfileId '') -cne $profileId -or (PSelField $raw ProfileId '') -cne $profileId){$out.Reason='AlternatingSerialOrderUnverified';return $out}
  $at=[DateTimeOffset]::MinValue
  if(-not [DateTimeOffset]::TryParse([string](PSelField $raw CheckedAtUtc ''),[ref]$at) -or $at -gt $Now.AddMinutes(1) -or $at.AddMinutes(30) -le $Now){$out.Reason='ComparisonRoundExpired';return $out}
  if(-not (PSelField $raw CleanupComplete $false) -or (PSelField $raw CancellationRequested $false) -or (PSelField $raw ContextChanged $false) -or (PSelField $raw NetworkChanged $false) -or (PSelField $raw Status '') -ne 'Passed' -or -not (PSelField $raw ForwardingPassed $false) -or -not (PSelField $raw ExitServerVerifiedTrace $false)){$out.Reason='ComparisonRoundUnqualified';return $out}
  if((PSelField $raw CandidateHash '') -ine (PSelField $evidence CandidateSHA256 '') -or [string](PSelField $raw ManifestHash '') -notmatch '^[A-Fa-f0-9]{64}$' -or (PSelField $raw ManifestHash '') -cne (PSelField (PSelField $evidence Result) ManifestHash '') -or (PSelField $raw EngineSHA256 '') -cne $engine -or (PSelField $raw SnapshotFingerprint '') -cne $snapshot -or (PSelField $raw NodeId '') -cne (PSelField $u NodeId '')){$out.Reason='ComparisonRoundBindingMismatch';return $out}
  if(-not (PSelField $path Verified $false) -or -not (PSelField $path EligibleForRecommendation $false) -or (PSelField $path Kind '') -notin @('PhysicalDirect','BoundInterfaceObserved','InterfaceBoundObserved') -or (PSelField $raw NetworkFingerprint '') -cne (PSelField $evidence NetworkFingerprint '') -or (PSelField $path NetworkFingerprint '') -cne (PSelField $evidence NetworkFingerprint '') -or (PSelField $raw ExpectedExitSource '') -cne 'ServerVerifiedTlsTrace' -or (PSelField $raw ExpectedExitIPv4 '') -cne (PSelField $evidence ObservedExitIPv4 '') -or (PSelField $raw ObservedExitIPv4 '') -cne (PSelField $evidence ObservedExitIPv4 '')){$out.Reason='ComparisonRoundPathOrExitUnqualified';return $out}
  $samples=@(PSelField $raw Samples @())
  if($samples.Count -ne 7){$out.Reason='ComparisonRequestBudgetMismatch';return $out}
  foreach($target in $targets){
   $rows=@($samples|Where-Object {(PSelField $_ Name '') -ceq (PSelField $target Name '')});$isRequired=[bool](PSelField $target Trace $false);$count=if($isRequired){3}else{1}
   if($rows.Count -ne $count){$out.Reason='ComparisonTargetMismatch';return $out}
   for($round=1;$round -le $count;$round++){
    $row=@($rows|Where-Object {(PSelField $_ Round 0) -eq $round})
    if($row.Count -ne 1 -or (PSelField $row[0] TargetUrl '') -cne (PSelField $target Url '') -or (PSelField $row[0] RequestBudgetSeconds 0) -ne 6 -or -not (PSelField $row[0] Attempted $false) -or [bool](PSelField $row[0] Required $false) -ne $isRequired){$out.Reason='ComparisonRequestBudgetMismatch';return $out}
    if($isRequired){
     $duration=0.0;$validDuration=[double]::TryParse([string](PSelField $row[0] DurationMs ''),[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$duration)
     if((PSelField $row[0] Status '') -ne 'Passed' -or -not (PSelField $row[0] TlsVerified $false) -or (PSelField $row[0] ObservedExitIPv4 '') -cne (PSelField $evidence ObservedExitIPv4 '') -or -not $validDuration -or [double]::IsNaN($duration) -or [double]::IsInfinity($duration) -or $duration -lt 0){$out.Reason='ComparisonSuccessfulPairsInsufficient';return $out}
    }
   }
  }
 }
 $targetResults=New-Object 'Collections.Generic.List[object]';$winner=$null;$consensus=$true
 foreach($target in $required){
  $pairs=New-Object 'Collections.Generic.List[object]';$roundDeltas=@()
  for($pairRound=1;$pairRound -le 3;$pairRound++){
   $ur=@($uRuns|Where-Object {$_.PairRound -eq $pairRound})[0].Result;$tr=@($tRuns|Where-Object {$_.PairRound -eq $pairRound})[0].Result;$deltas=@()
   for($sampleRound=1;$sampleRound -le 3;$sampleRound++){
    $us=@($ur.Samples|Where-Object {$_.Name -ceq $target.Name -and $_.Round -eq $sampleRound})[0];$ts=@($tr.Samples|Where-Object {$_.Name -ceq $target.Name -and $_.Round -eq $sampleRound})[0]
    $delta=[double]$us.DurationMs-[double]$ts.DurationMs;$deltas+=,$delta
    $pairs.Add([pscustomobject]@{ComparisonRound=$pairRound;SampleRound=$sampleRound;UdpResponseMs=[double]$us.DurationMs;TcpResponseMs=[double]$ts.DurationMs;UdpMinusTcpMs=$delta;RequestBudgetSeconds=6})
   };$roundDeltas+=,(PSelMedian $deltas)
  }
  $medianDelta=PSelMedian @($pairs|ForEach-Object {$_.UdpMinusTcpMs});$targetWinner=if($medianDelta -gt 0){'Tcp'}elseif($medianDelta -lt 0){'Udp'}else{$null}
  $udpMedian=PSelMedian @($pairs|ForEach-Object {$_.UdpResponseMs});$tcpMedian=PSelMedian @($pairs|ForEach-Object {$_.TcpResponseMs});$slower=[Math]::Max($udpMedian,$tcpMedian)
  $absolute=[Math]::Abs($medianDelta);$relative=if($slower -gt 0){$absolute/$slower}else{0}
  $wins=@($roundDeltas|Where-Object {($targetWinner -eq 'Tcp' -and $_ -gt 0) -or ($targetWinner -eq 'Udp' -and $_ -lt 0)}).Count
  $advantage=[bool]($pairs.Count -ge 9 -and $absolute -ge 20 -and $relative -ge 0.20 -and $wins -eq 3)
  $targetResults.Add([pscustomobject]@{Name=$target.Name;TargetUrl=$target.Url;PairedSamples=$pairs.Count;PairedRounds=3;UdpSuccessful=$pairs.Count;TcpSuccessful=$pairs.Count;UdpFailed=0;TcpFailed=0;UdpTimedOut=0;TcpTimedOut=0;UdpMedianResponseMs=$udpMedian;TcpMedianResponseMs=$tcpMedian;MedianPairedAdvantageMs=$absolute;RelativePairedAdvantage=$relative;RoundMedianUdpMinusTcpMs=$roundDeltas;WinningRounds=$wins;Winner=$targetWinner;ThresholdsMet=$advantage;Pairs=$pairs.ToArray()})
  if(-not $advantage -or ($winner -and $targetWinner -cne $winner)){$consensus=$false};if(-not $winner){$winner=$targetWinner}
 }
 $out.PairedRoundCount=3;$out.PairedSampleCount=18;$out.TargetComparisons=$targetResults.ToArray()
 if($consensus -and $winner){$out.PerformanceRanked=$true;$out.Winner=$winner;$out.Reason='ConsistentPairedHttpsResponseAdvantage'}else{$out.Reason='NoConsistentPairedResponseAdvantage'}
 $out
}
function ConvertTo-TCProtocolEvidence {
 [CmdletBinding()]param($Result,[Parameter(Mandatory=$true)]$Profile,$NetworkContext,[ValidateSet('Candidate','Runtime')][string]$Origin='Candidate',[DateTimeOffset]$Now=[DateTimeOffset]::UtcNow)
 $id=[string](PSelField $Profile Id '');$hash=[string](PSelField $Profile CandidateSHA256 '')
 if($id -notin @('Udp','Tcp') -or $hash -notmatch '^[A-Fa-f0-9]{64}$'){throw '连接方式验证缺少明确的方式或配置哈希。'}
 $raw=$Result
 if($Result -and (PSelField $Result Result)){$raw=PSelField $Result Result}
 $code=[string](PSelField $raw Code 'NotTested');$status=[string](PSelField $raw Status 'NotTested')
 $checks=@(PSelField $raw Checks @())
 $required=@($checks|Where-Object {(PSelField $_ Name '') -in @('AddressHttps','DomainDnsHttps')})
 $observed=[string](PSelField $raw ObservedExitIPv4 (PSelField $raw ObservedIP ''))
 $forward=[bool](PSelField $raw ForwardingPassed $false)
 if(-not $forward){$forward=($required.Count -eq 2 -and @($required|Where-Object {(PSelField $_ Status '') -ne 'Passed'}).Count -eq 0 -and [bool]$observed)}
 if($Origin -eq 'Runtime'){$forward=[bool]((PSelField $raw ExitHttp $false) -and (PSelField $raw DnsHttps $false) -and (PSelField $raw ExitVerified $false) -and $observed)}
 $clean=[bool](PSelField $raw CleanupComplete ($Origin -eq 'Runtime'))
 $path=PSelField $raw PathEvidence
 $pathKind=[string](PSelField $path Kind (PSelField $raw TransportPath 'Unknown'))
 $fingerprint=[string](PSelField $path NetworkFingerprint (PSelField $raw NetworkFingerprint ''))
 $currentFingerprint=[string](PSelField $NetworkContext Fingerprint '')
 $checked=[DateTimeOffset]::MinValue
 $stamp=[string](PSelField $raw CheckedAtUtc (PSelField $Result ValidatedAt ''))
 $validTime=[DateTimeOffset]::TryParse($stamp,[ref]$checked)
 if(-not $validTime){$checked=$Now}
 $expiry=$checked.AddMinutes(30)
 $fresh=($validTime -and $checked -le $Now.AddMinutes(1) -and $expiry -gt $Now)
 $sameNetwork=($fingerprint -match '^[A-Fa-f0-9]{64}$' -and $currentFingerprint -ceq $fingerprint)
 $candidateHash=[string](PSelField $raw CandidateHash (PSelField $raw CandidateSHA256 $hash))
 $sameConfig=($candidateHash -ieq $hash)
 $boundExit=([string](PSelField $raw ExpectedExitSource '') -ceq 'ServerVerifiedTlsTrace' -and [string](PSelField $raw ExpectedExitIPv4 '') -ceq $observed -and [bool]$observed)
 $consistent=@($checks|Where-Object {(PSelField $_ Name '') -eq 'ExitConsistency' -and (PSelField $_ Status '') -ne 'Passed'}).Count -eq 0
 $pathQualified=[bool]((PSelField $path Verified $false) -and (PSelField $path EligibleForRecommendation $false) -and $pathKind -in @('PhysicalDirect','BoundInterfaceObserved','InterfaceBoundObserved'))
 $comparison=PSelField $raw Comparison
 $contextChanged=[bool]((PSelField $raw ContextChanged $false) -or (PSelField $raw NetworkChanged $false))
 $comparisonSafe=[bool](-not $comparison -or ((PSelField $comparison CleanupComplete $false) -and (PSelField $comparison SameNetwork $false) -and (PSelField $comparison SameBudget $false) -and -not (PSelField $comparison StopCode '') -and -not (PSelField $comparison CancellationRequested $false)))
 $eligible=[bool]($Origin -eq 'Candidate' -and $forward -and $clean -and $sameConfig -and $boundExit -and $consistent -and $fresh -and $sameNetwork -and $pathQualified -and -not $contextChanged -and $comparisonSafe)
 if(-not $raw){$status='NotTested'}
 elseif($code -in @('ActiveIdentity','ProbeCleanupFailed','ProbeIdentityUnknown','IdentityBlocked') -or -not $clean){$status='Blocked';$eligible=$false;if(-not $clean){$code='ProbeCleanupFailed'}}
 elseif($code -eq 'ProbeCancelled' -or (PSelField $raw CancellationRequested $false)){$status='Inconclusive';$code='ProbeCancelled';$eligible=$false}
 elseif($status -eq 'NotTested' -and $code -eq 'ProfileUnavailable'){$eligible=$false}
 elseif(-not $sameConfig){$status='Failed';$code='ConfigurationChanged';$eligible=$false}
 elseif($status -eq 'Failed' -or @($required|Where-Object {(PSelField $_ Status '') -eq 'Failed'}).Count){$status='Failed';$eligible=$false}
 elseif(-not $fresh){$status='Stale';$code='EvidenceExpired';$eligible=$false}
 elseif($Origin -eq 'Runtime' -and $forward){$status='Passed';$code='RuntimeForwardingPassed'}
 elseif($eligible){$status='Passed';$code='CandidateReachabilityVerified'}
 else{$status='Inconclusive'}
 $engineHash=[string](PSelField $raw EngineSHA256 '')
 $comparisonDigest=if($comparison){PSelComparisonDigest $raw}else{$null}
 $evidenceId=PSelDigest ([ordered]@{ProfileId=$id;Hash=$hash;EngineHash=$engineHash;At=$checked.ToString('o');Origin=$Origin;Code=$code;Network=$fingerprint;Path=$pathKind;Exit=$observed;ComparisonDigest=$comparisonDigest})
 [pscustomobject][ordered]@{SchemaVersion=1;EvidenceId=$evidenceId;Origin=$Origin;Status=$status;Code=$code;ProfileId=$id;CandidateSHA256=$hash;EngineSHA256=$engineHash;ForwardingPassed=$forward;EligibleForAutomaticSelection=$eligible;TransportPath=$pathKind;PathEvidence=$path;NetworkFingerprint=$fingerprint;ValidatedAt=$checked.ToString('o');ExpiresAt=$expiry.ToString('o');CleanupComplete=$clean;ExitConsistency=$consistent;ExitBindingVerified=$boundExit;ObservedExitIPv4=$observed;Samples=@(PSelField $raw Samples @());Metrics=(PSelField $raw Metrics);Comparison=$comparison;ComparisonDigest=$comparisonDigest;Result=$raw}
}
function Test-TCProtocolEvidenceCurrent {
 [CmdletBinding()]param($Evidence,$Profile,$NetworkContext,[DateTimeOffset]$Now=[DateTimeOffset]::UtcNow)
 if(-not $Evidence -or -not (PSelField $Evidence EligibleForAutomaticSelection $false) -or (PSelField $Evidence Status '') -ne 'Passed' -or -not (PSelField $Evidence CleanupComplete $false)){return $false}
 if([string](PSelField $Evidence CandidateSHA256 '') -ine [string](PSelField $Profile CandidateSHA256 '') -or [string](PSelField $Evidence ProfileId '') -cne [string](PSelField $Profile Id '')){return $false}
 $raw=PSelField $Evidence Result;$comparison=PSelField $raw Comparison
 if($comparison){
  if(-not (PSelField $comparison CleanupComplete $false) -or -not (PSelField $comparison SameNetwork $false) -or -not (PSelField $comparison SameBudget $false) -or (PSelField $comparison StopCode '') -or (PSelField $comparison CancellationRequested $false)){return $false}
  $digest=PSelComparisonDigest $raw
  if($digest -cne (PSelField $Evidence ComparisonDigest '')){return $false}
  if((PSelDigest (PSelField $Evidence Metrics)) -cne (PSelDigest (PSelField $raw Metrics)) -or (PSelDigest @(PSelField $Evidence Samples @())) -cne (PSelDigest @(PSelField $raw Samples @())) -or (PSelDigest (PSelField $Evidence Comparison)) -cne (PSelDigest $comparison)){return $false}
 }
 $context=PSelEvidenceContext $Evidence $NetworkContext
 $fp=[string](PSelField $context Fingerprint '')
 if(-not $fp -or $fp -cne [string](PSelField $Evidence NetworkFingerprint '')){return $false}
 $expiry=[DateTimeOffset]::MinValue;$at=[DateTimeOffset]::MinValue
 if(-not [DateTimeOffset]::TryParse([string](PSelField $Evidence ExpiresAt ''),[ref]$expiry) -or -not [DateTimeOffset]::TryParse([string](PSelField $Evidence ValidatedAt ''),[ref]$at)){return $false}
 if($at -gt $Now.AddMinutes(1) -or $expiry -le $Now -or $expiry -gt $at.AddMinutes(30)){return $false}
 return $true
}
function Get-TCProtocolRecommendation {
 [CmdletBinding()]param([Parameter(Mandatory=$true)][object[]]$Profiles,[ValidateSet('Auto','Udp','Tcp')][string]$RequestedMode='Auto',$NetworkContext,[string]$LineId='',[DateTimeOffset]$Now=[DateTimeOffset]::UtcNow)
 $ids=@{};foreach($profile in $Profiles){$id=[string](PSelField $profile Id '');if($id -notin @('Udp','Tcp') -or $ids.ContainsKey($id)){throw '连接方式集合缺失标识或包含重复方式。'};$ids[$id]=$profile}
 $eligible=@($Profiles|Where-Object {Test-TCProtocolEvidenceCurrent -Evidence (PSelField $_ Validation) -Profile $_ -NetworkContext $NetworkContext -Now $Now})
 $recommend=$null;$preferred=$null;$source='None';$status='Inconclusive';$reason='尚无足够的当前网络验证证据，暂不自动推荐。'
 $blocked=@($Profiles|Where-Object {(PSelField (PSelField $_ Validation) Status '') -eq 'Blocked'}).Count -gt 0
 $failed=@($Profiles|Where-Object {(PSelField (PSelField $_ Validation) Status '') -eq 'Failed'})
 $performance=PSelPerformanceAssessment $(if($ids.ContainsKey('Udp')){PSelField $ids.Udp Validation}) $(if($ids.ContainsKey('Tcp')){PSelField $ids.Tcp Validation}) $Now
 if($RequestedMode -ne 'Auto'){
  if($ids.ContainsKey($RequestedMode)){$preferred=$RequestedMode;$status='UserChoice';$source='UserChoice';$reason='保留你指定的连接方式；其检查结果单独显示，未把手动选择作为自动推荐。'}
  else{$status='Unavailable';$reason='你指定的连接方式尚未准备完成。'}
 }elseif($blocked){$status='Blocked';$reason='设备身份正在使用或探针未完成清理；核对状态后再检查。'}
 elseif(@($Profiles|Where-Object {(PSelField (PSelField $_ Validation) Code '') -eq 'ProbeCancelled'}).Count){$status='Inconclusive';$reason='检查已停止，已准备的连接资料保留；需要时重新检查。'}
 elseif($eligible.Count -gt 0){
  $preferred=[string]$eligible[0].Id
  if($eligible.Count -eq 2){
   $preferred='Udp';$source='PolicyDefault';$reason='两种方式均满足当前可达性要求；配对响应优势相近或数据不足，按默认策略使用 UDP。'
   if($performance.PerformanceRanked){$preferred=$performance.Winner;$source='Performance';$reason=($preferred.ToUpperInvariant()+' 在两个 HTTPS 目标各 9 对样本、3 个交替轮次中响应更快；达到工程初筛阈值：各目标中位配对优势至少 20ms 和 20%，且每轮方向一致。')}
  }else{
   $source='Reachability';$reason=('已确认 '+$preferred.ToUpperInvariant()+' 在本次检查中可连接，设为下次默认方式；不代表它的速度更快。')
   $other=@($Profiles|Where-Object {$_.Id -cne $preferred})
   if($other.Count -eq 1){$e=PSelField $ids[$preferred] Validation;$o=PSelField $other[0] Validation;$c=PSelField (PSelField $e Result) Comparison;$oc=PSelField (PSelField $o Result) Comparison
    if($c -and $oc -and (PSelField $c Completed $false) -and (PSelField $c ComparisonId '') -ceq (PSelField $oc ComparisonId '') -and (PSelField $o Status '') -eq 'Failed'){$source='Stability';$reason=($preferred.ToUpperInvariant()+' 通过全部必需样本；另一方式出现失败或超时，先按可达性稳定性选择。')}
   }
  }
  $recommend=$preferred;$status='Recommended'
 }elseif($Profiles.Count -gt 0 -and $failed.Count -eq $Profiles.Count){$status='Unavailable';$reason='已准备的连接方式均未通过检查，当前没有可自动推荐的方式。'}
 $hash=$null;$expires=$Now.AddMinutes(30);$evidenceIds=@()
 if($preferred){$hash=[string]$ids[$preferred].CandidateSHA256}
 foreach($p in $eligible){$e=PSelField $p Validation;$evidenceIds+=,[string](PSelField $e EvidenceId '');$until=[DateTimeOffset](PSelField $e ExpiresAt);if($until -lt $expires){$expires=$until}}
 $networkValues=@($eligible|ForEach-Object {[string](PSelField (PSelField $_ Validation) NetworkFingerprint '')}|Sort-Object -Unique)
 $selectionNetwork=if($networkValues.Count -eq 1){$networkValues[0]}elseif($networkValues.Count -gt 1){PSelDigest $networkValues}else{[string](PSelField $NetworkContext Fingerprint '')}
 $ranked=[bool]($status -eq 'Recommended' -and $eligible.Count -eq 2 -and $source -eq 'Performance' -and $performance.PerformanceRanked)
 $selectionData=@(foreach($p in @($Profiles|Sort-Object Id)){
  $e=PSelField $p Validation;$raw=PSelField $e Result;$c=PSelField $raw Comparison
  [pscustomobject]@{ProfileId=$p.Id;CandidateSHA256=(PSelField $p CandidateSHA256);Status=(PSelField $e Status);Code=(PSelField $e Code);EvidenceId=(PSelField $e EvidenceId);ComparisonQualityDigest=$(if($c){PSelDigest $c}else{$null});ComparisonDataDigest=$(if($c){PSelComparisonDigest $raw}else{$null});MetricsDigest=$(if($c){PSelDigest (PSelField $e Metrics)}else{$null})}
 })
 $r=[ordered]@{SchemaVersion=1;PolicyVersion=$script:TCProtocolPolicyVersion;LineId=$LineId;Status=$status;RecommendedProfileId=$recommend;PreferredProfileId=$preferred;RequestedProfileId=$(if($RequestedMode -ne 'Auto'){$RequestedMode}else{$null});Source=$source;CandidateSHA256=$hash;NetworkFingerprint=$selectionNetwork;NetworkScope='EvidenceBoundUnderlay';CheckedAtUtc=$Now.ToString('o');ExpiresAtUtc=$expires.ToString('o');EvidenceIds=@($evidenceIds|Sort-Object);SelectionData=$selectionData;Reason=$reason;EligibleForDefaultSelection=($status -eq 'Recommended');RequiresUserActivation=$true;PerformanceRanked=$ranked;PerformanceReason=$performance.Reason;PairedSampleCount=$performance.PairedSampleCount;PairedRoundCount=$performance.PairedRoundCount;PerformanceThresholds=$performance.Thresholds;TargetComparisons=$performance.TargetComparisons}
 $r.EvidenceDigest=PSelRecommendationDigest $r
 [pscustomobject]$r
}
function Test-TCProtocolRecommendationCurrent {
 [CmdletBinding()]param($Recommendation,[Parameter(Mandatory=$true)][object[]]$Profiles,$NetworkContext,[DateTimeOffset]$Now=[DateTimeOffset]::UtcNow)
 if(-not $Recommendation -or (PSelField $Recommendation Status '') -ne 'Recommended'){return $false}
 if((PSelField $Recommendation PolicyVersion '') -cne $script:TCProtocolPolicyVersion -or (PSelRecommendationDigest $Recommendation) -cne (PSelField $Recommendation EvidenceDigest '')){return $false}
 $until=[DateTimeOffset]::MinValue
 if(-not [DateTimeOffset]::TryParse([string](PSelField $Recommendation ExpiresAtUtc ''),[ref]$until) -or $until -le $Now){return $false}
 $fresh=Get-TCProtocolRecommendation -Profiles $Profiles -NetworkContext $NetworkContext -LineId ([string](PSelField $Recommendation LineId '')) -Now $Now
 [bool]($fresh.Status -eq 'Recommended' -and $fresh.EvidenceDigest -ceq [string](PSelField $Recommendation EvidenceDigest '') -and $fresh.RecommendedProfileId -ceq [string](PSelField $Recommendation RecommendedProfileId ''))
}
Export-ModuleMember -Function Get-TCProtocolNetworkContext,ConvertTo-TCProtocolEvidence,Test-TCProtocolEvidenceCurrent,Get-TCProtocolRecommendation,Test-TCProtocolRecommendationCurrent
