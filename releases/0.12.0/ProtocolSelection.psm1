#requires -Version 5.1
Set-StrictMode -Version 2.0
$script:NetworkContextReader=$null
function PSelField {param($Value,[string]$Name,$Default=$null)
 if($Value -is [Collections.IDictionary]){if($Value.Contains($Name)){return $Value[$Name]}}
 elseif($null -ne $Value -and $Value.PSObject.Properties[$Name]){return $Value.$Name};$Default
}
function PSelDigest {param($Value)
 $sha=[Security.Cryptography.SHA256]::Create()
 try{([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($Value|ConvertTo-Json -Depth 25 -Compress))))).Replace('-','')}finally{$sha.Dispose()}
}
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
 $eligible=[bool]($Origin -eq 'Candidate' -and $forward -and $clean -and $sameConfig -and $boundExit -and $consistent -and $fresh -and $sameNetwork -and $pathQualified)
 if(-not $raw){$status='NotTested'}
 elseif($code -in @('ActiveIdentity','ProbeCleanupFailed','ProbeIdentityUnknown') -or -not $clean){$status='Blocked';$eligible=$false;if(-not $clean){$code='ProbeCleanupFailed'}}
 elseif($code -eq 'ProbeCancelled'){$status='Inconclusive';$eligible=$false}
 elseif(-not $sameConfig){$status='Failed';$code='ConfigurationChanged';$eligible=$false}
 elseif($status -eq 'Failed' -or @($required|Where-Object {(PSelField $_ Status '') -eq 'Failed'}).Count){$status='Failed';$eligible=$false}
 elseif(-not $fresh){$status='Stale';$code='EvidenceExpired';$eligible=$false}
 elseif($Origin -eq 'Runtime' -and $forward){$status='Passed';$code='RuntimeForwardingPassed'}
 elseif($eligible){$status='Passed';$code='CandidateReachabilityVerified'}
 else{$status='Inconclusive'}
 $engineHash=[string](PSelField $raw EngineSHA256 '')
 $evidenceId=PSelDigest ([ordered]@{ProfileId=$id;Hash=$hash;EngineHash=$engineHash;At=$checked.ToString('o');Origin=$Origin;Code=$code;Network=$fingerprint;Path=$pathKind;Exit=$observed})
 [pscustomobject][ordered]@{SchemaVersion=1;EvidenceId=$evidenceId;Origin=$Origin;Status=$status;Code=$code;ProfileId=$id;CandidateSHA256=$hash;EngineSHA256=$engineHash;ForwardingPassed=$forward;EligibleForAutomaticSelection=$eligible;TransportPath=$pathKind;PathEvidence=$path;NetworkFingerprint=$fingerprint;ValidatedAt=$checked.ToString('o');ExpiresAt=$expiry.ToString('o');CleanupComplete=$clean;ExitConsistency=$consistent;ExitBindingVerified=$boundExit;ObservedExitIPv4=$observed;Samples=@(PSelField $raw Samples @());Metrics=(PSelField $raw Metrics);Result=$raw}
}
function Test-TCProtocolEvidenceCurrent {
 [CmdletBinding()]param($Evidence,$Profile,$NetworkContext,[DateTimeOffset]$Now=[DateTimeOffset]::UtcNow)
 if(-not $Evidence -or -not (PSelField $Evidence EligibleForAutomaticSelection $false) -or (PSelField $Evidence Status '') -ne 'Passed' -or -not (PSelField $Evidence CleanupComplete $false)){return $false}
 if([string](PSelField $Evidence CandidateSHA256 '') -ine [string](PSelField $Profile CandidateSHA256 '') -or [string](PSelField $Evidence ProfileId '') -cne [string](PSelField $Profile Id '')){return $false}
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
 if($blocked){$status='Blocked';$reason='设备身份正在使用或探针未完成清理；核对状态后再检查。'}
 elseif(@($Profiles|Where-Object {(PSelField (PSelField $_ Validation) Code '') -eq 'ProbeCancelled'}).Count){$status='Inconclusive';$reason='检查已停止，已准备的连接资料保留；需要时重新检查。'}
 elseif($RequestedMode -ne 'Auto'){
  if($ids.ContainsKey($RequestedMode)){$preferred=$RequestedMode;$status='UserChoice';$source='UserChoice';$reason='保留你指定的连接方式；其检查结果单独显示，未把手动选择作为自动推荐。'}
  else{$status='Unavailable';$reason='你指定的连接方式尚未准备完成。'}
 }elseif($eligible.Count -gt 0){
  $preferred=[string]$eligible[0].Id
  if($eligible.Count -eq 2){$preferred='Udp';$source='PolicyDefault';$reason='两种方式均满足当前可达性要求，按默认策略使用 UDP；尚未根据性能排名。'}
  else{$source='Reachability';$reason=('已确认 '+$preferred.ToUpperInvariant()+' 在本次检查中可连接，设为下次默认方式；不代表它的速度更快。')}
  $recommend=$preferred;$status='Recommended'
 }elseif($Profiles.Count -gt 0 -and $failed.Count -eq $Profiles.Count){$status='Unavailable';$reason='已准备的连接方式均未通过检查，当前没有可自动推荐的方式。'}
 $hash=$null;$expires=$Now.AddMinutes(30);$evidenceIds=@()
 if($preferred){$hash=[string]$ids[$preferred].CandidateSHA256}
 foreach($p in $eligible){$e=PSelField $p Validation;$evidenceIds+=,[string](PSelField $e EvidenceId '');$until=[DateTimeOffset](PSelField $e ExpiresAt);if($until -lt $expires){$expires=$until}}
 $networkValues=@($eligible|ForEach-Object {[string](PSelField (PSelField $_ Validation) NetworkFingerprint '')}|Sort-Object -Unique)
 $selectionNetwork=if($networkValues.Count -eq 1){$networkValues[0]}elseif($networkValues.Count -gt 1){PSelDigest $networkValues}else{[string](PSelField $NetworkContext Fingerprint '')}
 $r=[ordered]@{SchemaVersion=1;LineId=$LineId;Status=$status;RecommendedProfileId=$recommend;PreferredProfileId=$preferred;RequestedProfileId=$(if($RequestedMode -ne 'Auto'){$RequestedMode}else{$null});Source=$source;CandidateSHA256=$hash;NetworkFingerprint=$selectionNetwork;NetworkScope='EvidenceBoundUnderlay';CheckedAtUtc=$Now.ToString('o');ExpiresAtUtc=$expires.ToString('o');EvidenceIds=@($evidenceIds|Sort-Object);Reason=$reason;EligibleForDefaultSelection=($status -eq 'Recommended');RequiresUserActivation=$true;PerformanceRanked=$false}
 $r.EvidenceDigest=PSelDigest ([ordered]@{LineId=$LineId;ProfileId=$preferred;Source=$source;Hash=$hash;Network=$r.NetworkFingerprint;EvidenceIds=$r.EvidenceIds})
 [pscustomobject]$r
}
function Test-TCProtocolRecommendationCurrent {
 [CmdletBinding()]param($Recommendation,[Parameter(Mandatory=$true)][object[]]$Profiles,$NetworkContext,[DateTimeOffset]$Now=[DateTimeOffset]::UtcNow)
 if(-not $Recommendation -or (PSelField $Recommendation Status '') -ne 'Recommended'){return $false}
 $until=[DateTimeOffset]::MinValue
 if(-not [DateTimeOffset]::TryParse([string](PSelField $Recommendation ExpiresAtUtc ''),[ref]$until) -or $until -le $Now){return $false}
 $fresh=Get-TCProtocolRecommendation -Profiles $Profiles -NetworkContext $NetworkContext -LineId ([string](PSelField $Recommendation LineId '')) -Now $Now
 [bool]($fresh.Status -eq 'Recommended' -and $fresh.EvidenceDigest -ceq [string](PSelField $Recommendation EvidenceDigest '') -and $fresh.RecommendedProfileId -ceq [string](PSelField $Recommendation RecommendedProfileId ''))
}
Export-ModuleMember -Function Get-TCProtocolNetworkContext,ConvertTo-TCProtocolEvidence,Test-TCProtocolEvidenceCurrent,Get-TCProtocolRecommendation,Test-TCProtocolRecommendationCurrent
