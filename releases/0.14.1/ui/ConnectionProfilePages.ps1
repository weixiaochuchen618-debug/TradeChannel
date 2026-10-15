# Presentation only. Runtime rechecks eligibility, ownership and preview freshness.
$script:LineProfileUI=$null
$script:ConnectionPreviewUI=$null
function ProfileUIField {param($Object,[string]$Key,$Default=$null)if($Object -is [Collections.IDictionary]){if($Object.Contains($Key)){return $Object[$Key]}}elseif($Object -and $Object.PSObject.Properties[$Key]){return $Object.$Key};$Default}
function UILineId {param($Line) [string](ProfileUIField $Line 'LineId' (ProfileUIField $Line 'id' (ProfileUIField $Line 'CandidateNodeId' '')))}
function UIProfileName {param([string]$Id) if($Id -in @('Udp','Tcp')){return $Id.ToUpperInvariant()};'方式待核对'}
function UIExpired {param($Value) if(-not $Value){return $false};try{return ([DateTimeOffset]::Parse([string]$Value) -le [DateTimeOffset]::UtcNow)}catch{return $true}}
function NodeProfileItems {param($Node)
 $profiles=@(ProfileUIField $Node 'Profiles' @()|Where-Object {$_})
 if($profiles.Count){return $profiles}
 $path=[string](ProfileUIField $Node 'manifestPath' (ProfileUIField $Node 'SourceManifestPath' ''))
 $m=$null;try{if($path){$m=Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json}}catch{}
 if($m){[pscustomobject]@{Id=$(if($m.Transport){'Tcp'}else{'Udp'});Mode=$(if($m.Transport){'Tcp'}else{'Udp'});ManifestPath=$path;PreparationState='Ready';Validation=$null}}
}
function ProfileValidationView {param($Validation)
 $result=$Validation;$layers=@();for($i=0;$result -and $i -lt 6;$i++){$layers+=,$result;$result=ProfileUIField $result 'Result'}
 $view=@{Status='NotTested';Code='';Origin='Candidate';ProfileId='';TransportPath='';ForwardingPassed=$false;EligibleForAutomaticSelection=$false;ExpiresAt=$null;CandidateSHA256='';ValidatedAt=$null;CheckedAtUtc=$null;Samples=@();Metrics=$null}
 foreach($key in @($view.Keys)){foreach($layer in $layers){$value=ProfileUIField $layer $key;if($null -ne $value -and [string]$value -ne ''){$view[$key]=$value;break}}}
 if($view.Status -eq 'NotTested'){
  foreach($layer in $layers){switch([string](ProfileUIField $layer 'PathValidation' '')){
   'Failed'{$view.Status='Failed'} 'Blocked'{$view.Status='Blocked'} 'Unknown'{$view.Status='Inconclusive'} 'Inconclusive'{$view.Status='Inconclusive'}
   'Stale'{$view.Status='Stale'} 'PhysicalDirectPassed'{$view.Status='Passed';$view.TransportPath='PhysicalDirect'} 'CurrentEnvironmentPassed'{$view.Status='Passed'}
  };if($view.Status -ne 'NotTested'){break}}
 }
 if($view.Status -eq 'Unknown'){$view.Status='Inconclusive'}
 if($view.Status -eq 'Passed' -and (UIExpired $view.ExpiresAt)){$view.Status='Stale';$view.EligibleForAutomaticSelection=$false}
 [pscustomobject]$view
}
function ProfileValidationReason {param($Validation)
 $v=ProfileValidationView $Validation
 $reasons=@{
  ForwardingPassedPhysicalPathUnverified='转发通过，但物理路径尚未证实';ExpectedExitUnverified='预期出口尚未核实';ActiveIdentity='设备身份正在使用，不能并行探测';ActiveIdentityInUse='设备身份正在使用，不能并行探测';IdentityInUse='设备身份正在使用，不能并行探测'
  ProbeCleanupFailed='探针清理未完成，需先核对恢复';ProbeIdentityUnknown='探针身份待核对';NeedsRecovery='上次任务需先恢复';NetworkChanged='网络环境已变化，请重试检查';ConfigurationChanged='配置已变化，请重试检查';EvidenceExpired='检查结果已过期'
  ForwardingFailed='外网转发检查失败';ProbeFailed='转发探测失败';Timeout='检查超时';NotTested='尚未完成检查'
  CandidateForwardingFailed='外网连接检查未通过';CandidateForwardingUnverified='检查尚未完成，暂不能确定是否可连接';CandidateReachabilityVerified='本次网络连接检查通过';RuntimeForwardingPassed='本次连接检查通过'
  NetworkChangedDuringComparison='检查期间网络环境变化，请重新检查';ProbeCancelled='本次检查已停止，连接资料保留';EngineMismatch='连接引擎与配置不一致，请重新准备';EngineChanged='连接引擎已更新，请重新准备并检查';ProbePreparationFailed='本机检查准备未完成，请重试';TimeBudgetExhausted='检查时间已用完，请重试'
 }
 if($v.Code -and $reasons.ContainsKey([string]$v.Code)){return $reasons[[string]$v.Code]}
 switch([string]$v.Status){'Failed'{'外网检查未通过'}'Inconclusive'{'证据不足，暂不能自动推荐'}'Blocked'{'检查被阻止，需先处理条件'}'Stale'{'检查结果已过期或与当前配置不符'}'NotTested'{'尚未完成检查'}default{''}}
}
function ProfileIsPrepared {param($Profile)
 $null -ne $Profile -and [string](ProfileUIField $Profile 'PreparationState' 'Missing') -in @('Ready','Prepared','SyntaxValidated')
}
function ProfilePreparationStatus {param($Profile)
 $state=[string](ProfileUIField $Profile 'PreparationState' 'Missing')
 switch($state){
  {$_ -in @('Ready','Prepared','SyntaxValidated')}{return '已准备'}
  {$_ -in @('Pending','Inspecting','Preparing')}{return '准备中'}
  {$_ -in @('Failed','Invalid')}{return '准备未完成'}
  {$_ -in @('OutcomeUnknown','NeedsRecovery')}{return '需恢复 / 核对'}
  default{return '未准备'}
 }
}
function ConnectionProfileStatus {param($Profile)
 $state=[string](ProfileUIField $Profile 'PreparationState' 'Missing')
 if($state -in @('Missing','NotConfigured')){return '未准备'}
 if($state -in @('Failed','Invalid')){return '准备未完成'}
 if($state -in @('OutcomeUnknown','NeedsRecovery')){return '状态待核对'}
 $v=ProfileValidationView (ProfileUIField $Profile 'Validation');$reason=ProfileValidationReason (ProfileUIField $Profile 'Validation')
 switch([string]$v.Status){
  'Passed'{if($v.Origin -eq 'Runtime'){return '运行会话检查通过（仅当前会话证据）'};if($v.TransportPath -eq 'PhysicalDirect'){return '本地直连检查通过'};return '当前环境检查通过'}
  'Failed'{return ('最近检查未通过 · '+$reason)}
  'Inconclusive'{return ('检查结论不足 · '+$reason)}
  'Blocked'{return ('检查受阻 · '+$reason)}
  'Stale'{return '历史检查已失效，启用前需重新核对'}
  {$_ -in @('Checking','Running')}{return '检查中'}
  'NotTested'{return '配置已准备，连通性待验证'}
  default{return ('检查状态待核对 · '+[string]$v.Status)}
 }
}
function NodeHasActiveProfile {param($Node)
 if(-not (IsRunning)){return $false}
 $activeId=[string](ProfileUIField $script:Overview 'ActiveLineId' '')
 if($activeId){return ($activeId -eq (UILineId $Node) -or $activeId -in @(ProfileUIField $Node 'AliasIds' @()))}
 $paths=@([string](ProfileUIField $Node 'manifestPath' ''),[string](ProfileUIField $Node 'SourceManifestPath' ''))+@((NodeProfileItems $Node)|ForEach-Object {[string]$_.ManifestPath})
 foreach($path in @($script:Overview.ManifestPath,(ProfileUIField $script:Overview 'ProfileManifestPath' ''))){if($path -and $path -in @($paths|Where-Object {$_})){return $true}}
 $false
}
function ActiveNodeProfileId {param($Node)
 if(-not (NodeHasActiveProfile $Node)){return ''}
 $id=[string](ProfileUIField $script:Overview 'ActiveProfileId' '')
 if($id -in @('Udp','Tcp')){return $id}
 $paths=@($script:Overview.ManifestPath,(ProfileUIField $script:Overview 'ProfileManifestPath' ''))|Where-Object {$_}
 $matched=@(NodeProfileItems $Node|Where-Object {$_.ManifestPath -and $_.ManifestPath -in $paths})
 if($matched.Count -eq 1){return [string]$matched[0].Id}
 return ''
}
function ActiveLineStatus {param($Node)
 $id=ActiveNodeProfileId $Node;if(-not (NodeHasActiveProfile $Node)){return ''}
 $prefix=if(IsProviderTag ([string]$script:Overview.Exit)){'通道运行中（交易走备用）'}else{'交易使用中'}
 $v=ProfileUIField $script:Overview 'RuntimeValidation'
 $bound=($v -and $id -and [string](ProfileUIField $v 'ProfileId' '') -eq $id -and [string](ProfileUIField $v 'LineId' '') -eq (UILineId $Node))
 foreach($key in @('SessionId','ConfigHash')){$current=ProfileUIField $script:Overview $key;if($current -and [string](ProfileUIField $v $key '') -ne [string]$current){$bound=$false}}
 $status='尚未完成检查'
 if($bound){
  switch([string](ProfileUIField $v 'Status' '')){
   'Passed'{if((ProfileUIField $v 'ForwardingPassed' $false) -eq $true){$status='本次连接检查通过'}else{$status='检查尚未完成'}}
   'Failed'{$status='检查未通过'}
   'Inconclusive'{$status='检查尚未完成'}
   'Blocked'{$status='检查受限'}
   'NotTested'{$status='尚未完成检查'}
   {$_ -in @('Checking','Running')}{$status='检查中'}
   'Stale'{$status='需要重新检查'}
  }
 }
 $prefix+' · '+(UIProfileName $id)+' · '+$status
}
function LegacyLineNeedsTcpMaintenance {param($Line)
 # Configuration availability is independent of reachability and performance.
 if(-not $Line -or -not (ProfileUIField $Line 'manifestPath' (ProfileUIField $Line 'SourceManifestPath' ''))){return $false}
 $run=ProfileUIField $script:DeployUI 'Run'
 if($run -and (UILineId $run) -eq (UILineId $Line) -and [string](ProfileUIField $run 'Intent' 'New') -ne 'Existing'){return $false}
 if([string](ProfileUIField $Line 'DeploymentCompleteness' '') -in @('Partial','NeedsRecovery')){return $false}
 $profiles=@(NodeProfileItems $Line);$udp=@($profiles|Where-Object Id -eq 'Udp')|Select-Object -First 1
 $tcp=@($profiles|Where-Object Id -eq 'Tcp')|Select-Object -First 1
 (ProfileIsPrepared $udp) -and (-not $tcp -or [string](ProfileUIField $tcp 'PreparationState' '') -in @('Missing','NotConfigured'))
}
function LineNeedsBackupPreparation {param($Line)
 # Existing line cards call this compatibility helper. Maintenance is offered
 # explicitly by ShowLineMaintenance, never as a daily connection action.
 return $false
}
function LineRecommendationView {param($Line)
 $r=ProfileUIField $Line 'Recommendation';$status=[string](ProfileUIField $r 'Status' 'Inconclusive');$source=[string](ProfileUIField $r 'Source' 'None')
 $userPreference=([string](ProfileUIField $Line 'PreferenceSource' '') -eq 'UserChoice')
 if($userPreference){$status='UserChoice';$source='UserChoice'}
 $id=[string](ProfileUIField $r 'RecommendedProfileId' '')
 $configuredDefault=(-not $r -and [string](ProfileUIField $Line 'PreferenceSource' '') -eq 'ConfiguredDefault' -and [string](ProfileUIField $Line 'PreferredProfileId' '') -in @('Udp','Tcp'))
 if($configuredDefault){$status='ConfiguredDefault';$source='ConfiguredDefault';$id=[string]$Line.PreferredProfileId}
 if($status -eq 'UserChoice'){$id=[string](ProfileUIField $Line 'PreferredProfileId' '');if(-not $id){$id=[string](ProfileUIField $r 'PreferredProfileId' '')};if(-not $id){$id=[string](ProfileUIField $r 'RequestedProfileId' '')}}
 $profile=@(NodeProfileItems $Line|Where-Object Id -eq $id)|Select-Object -First 1
 $v=ProfileValidationView (ProfileUIField $profile 'Validation');$can=$false;$reason=[string](ProfileUIField $r 'Reason' '')
 if($userPreference){$reason='已保留你指定的下次连接方式，其检查结果单独显示。'}
 if($configuredDefault){$reason='沿用已有连接配置；连接后自动检查，未作为新的检测推荐。'}
 if(-not $reason){$reason=if(-not $r){'尚无当前环境的推荐结果，请重试检查。'}else{ProfileValidationReason (ProfileUIField $profile 'Validation')}}
 if($status -in @('Recommended','UserChoice','ConfiguredDefault') -and $id -in @('Udp','Tcp') -and (ProfileIsPrepared $profile)){
  if($status -eq 'ConfiguredDefault'){$can=$configuredDefault}elseif($status -eq 'UserChoice'){$can=($source -eq 'UserChoice')}else{$can=($v.Status -eq 'Passed' -and $v.EligibleForAutomaticSelection -eq $true -and $v.ForwardingPassed -eq $true -and $v.Origin -ne 'Runtime' -and $source -in @('Reachability','PolicyDefault','Performance','Stability'))}
  if($status -eq 'Recommended' -and $v.Status -eq 'Passed' -and -not $can){$reason='检查通过，但缺少自动选择资格或转发证据，请重试检查。'}
  if($status -eq 'Recommended' -and $can -and ($v.ProfileId -ne $id -or -not $v.ExpiresAt -or $v.CandidateSHA256 -notmatch '^[a-fA-F0-9]{64}$')){$can=$false;$reason='推荐缺少有效的方式、配置或时效绑定，请重试检查。'}
  if($v.Status -in @('Failed','Blocked','Stale')){$can=$false;$reason=ConnectionProfileStatus $profile}
  if($status -eq 'Recommended' -and (UIExpired (ProfileUIField $r 'ExpiresAtUtc'))){$can=$false;$reason='推荐已过期，请重试检查。'}
  if($can -and $v.CandidateSHA256 -and (ProfileUIField $profile 'CandidateSHA256') -and $v.CandidateSHA256 -ne $profile.CandidateSHA256){$can=$false;$reason='配置已变化，请重试检查。'}
 }
 if($status -eq 'Recommended' -and -not (ProfileIsPrepared $profile)){$reason='推荐方式的本机配置尚未准备完成。'}
 $label=if($can){'下次默认方式：'+(UIProfileName $id)}else{switch($status){'Blocked'{'暂不能连接推荐方式'}'Unavailable'{'没有可推荐方式'}'UserChoice'{('手动默认方式：'+(UIProfileName $id)+' · 需先核对')}default{'暂不能确定推荐方式'}}}
 $performanceRanked=($source -eq 'Performance' -and (ProfileUIField $r 'PerformanceRanked' $false) -eq $true)
 $basis=switch($source){'Reachability'{'依据：当前环境可达性检查（未比较出最快方式）'}'Stability'{'依据：本次必需样本的可达性与稳定性（非最快结论）'}'PolicyDefault'{'依据：默认策略（未证明速度优胜，非最快结论）'}'Performance'{if($performanceRanked){'依据：本次性能对比（仅限本轮样本）'}else{'依据：默认策略（性能对比不足，非最快结论）'}}'UserChoice'{'依据：你手动指定的下次设置'}'ConfiguredDefault'{'依据：已有连接配置，非自动推荐'}default{'依据：尚无合格证据'}}
 if($source -eq 'Performance' -and -not $performanceRanked -and $can){$reason='性能对比尚不充分，当前方式按策略默认使用；未证明速度优胜。'}
 if(-not $can -and $status -eq 'Recommended' -and $v.Status -in @('NotTested','Inconclusive')){$reason='推荐证据尚不具备自动选择资格。'+(ProfileValidationReason (ProfileUIField $profile 'Validation'))}
 if(-not $can -and $v.Origin -eq 'Runtime'){$reason='当前运行的通过记录仅属于本次会话，不能用于新候选的自动推荐。'}
 [pscustomobject]@{CanConnect=$can;ProfileId=$id;Status=$status;Source=$source;Label=$label;Reason=$reason;Basis=$basis;Button=$(if($source -eq 'ConfiguredDefault'){'连接并检查'}elseif($source -eq 'UserChoice'){'连接指定方式'}else{'连接推荐方式'})}
}
function UIEvidenceTime {param($Value)
 if(-not $Value){return '尚无记录'}
 try{([DateTimeOffset]::Parse([string]$Value)).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss zzz')}catch{'时间待核对'}
}
function ProfileEvidenceSummary {param($Profile)
 $v=ProfileValidationView (ProfileUIField $Profile 'Validation');$metrics=$v.Metrics
 $samples=@($v.Samples|Where-Object {$_});$attempted=ProfileUIField $metrics 'Attempted';$planned=ProfileUIField $metrics 'Planned';$passed=ProfileUIField $metrics 'Passed'
 if($null -ne $attempted){$text='样本：已测 '+$attempted;if($null -ne $planned){$text+=' / '+$planned};if($null -ne $passed){$text+='，通过 '+$passed}}
 elseif($samples.Count){$text='样本：'+$samples.Count+' 条记录'}else{$text='样本：未记录'}
 foreach($key in @('MedianResponseMs','P95ResponseMs')){
  $value=ProfileUIField $metrics $key
  if($null -ne $value -and [string]$value -ne ''){$text+=' · '+$(if($key -eq 'MedianResponseMs'){'响应中位数'}else{'P95'})+' '+$value+' ms'}
 }
 $stamp=if($v.ValidatedAt){$v.ValidatedAt}else{$v.CheckedAtUtc}
 $text+' · 检查时间：'+(UIEvidenceTime $stamp)
}
function AddLineRecommendationEvidence {param($Parent,$Line,[string]$Prefix='Line')
 $r=ProfileUIField $Line 'Recommendation'
 $pairs=ProfileUIField $r 'PairedSampleCount' 0;$rounds=ProfileUIField $r 'PairedRoundCount' 0
 if($pairs -gt 0 -or [string](ProfileUIField $r 'Source' '') -eq 'Performance'){
  $comparison='性能对比：'+$pairs+' 对样本 / '+$rounds+' 轮'
  if((ProfileUIField $r 'PerformanceRanked' $false) -ne $true){$comparison+=' · 尚无足够一致优势，按策略默认（非最快）'}
  AddC $Parent (Margin (ControlName (T $comparison 12 $script:Text3) ($Prefix+'ComparisonSummary')) '0,6,0,0')
 }
 AddC $Parent (Margin (ControlName (T ('推荐记录时间：'+(UIEvidenceTime (ProfileUIField $r 'CheckedAtUtc'))) 12 $script:Text3) ($Prefix+'RecommendationTime')) '0,8,0,0')
 foreach($profile in @(NodeProfileItems $Line)){
  AddC $Parent (Margin (ControlName (T ((UIProfileName $profile.Id)+' '+(ProfileEvidenceSummary $profile)) 12 $script:Text3) ($Prefix+'Evidence'+$profile.Id)) '0,4,0,0')
 }
 foreach($target in @(ProfileUIField $r 'TargetComparisons' @()|Where-Object {$_.Name -in @('AddressHttps','DomainDnsHttps')})){
  $label=if($target.Name -eq 'AddressHttps'){'出口地址 HTTPS'}else{'域名与 HTTPS'}
  $text=$label+'：UDP '+$target.UdpMedianResponseMs+' ms；TCP '+$target.TcpMedianResponseMs+' ms；'+$target.PairedSamples+' 对样本 / '+$target.PairedRounds+' 轮'
  AddC $Parent (Margin (ControlName (T $text 12 $script:Text3) ($Prefix+'Target'+$target.Name)) '0,4,0,0')
 }
}
function LineConnectionsSummary {param($Node)
 $profiles=@(NodeProfileItems $Node);$labels=@();$activeId=ActiveNodeProfileId $Node
 foreach($id in @('Udp','Tcp')){if($id -eq $activeId){continue};$profile=@($profiles|Where-Object Id -eq $id)|Select-Object -First 1;$labels+=((UIProfileName $id)+'：'+$(if($profile){ConnectionProfileStatus $profile}else{'未准备'}))}
 $labels -join '  ·  '
}
function LoadLineConnections {param([string]$Id)
 if(IsBusy){return}
 $script:LineProfileUI=@{Id=$Id;Line=$null;Error='';SwitchResult=$null;MaintenanceMode=$false}
 StartJob @{Action='LineRegister';Id=$Id} {param($d)
  if(ProfileUIField $d 'Profiles'){$script:LineProfileUI.Line=$d;ShowLineConnections}
  else{StartJob @{Action='LineProfiles';Id=$script:LineProfileUI.Id} {param($line)$script:LineProfileUI.Line=$line;ShowLineConnections} '读取连接方式…'}
 } '读取这条线路的连接资料…' -Failed {param($message)$script:LineProfileUI.Error=$message;ShowLineConnections}
}
function SaveLineDefaultProfile {param([string]$ProfileId)
 if(IsBusy){return}
 if($script:ReadOnly){ErrorDialog '只读窗口不保存连接偏好。';return}
 $profile=@(NodeProfileItems $script:LineProfileUI.Line|Where-Object Id -eq $ProfileId)|Select-Object -First 1
 if($ProfileId -notin @('Udp','Tcp') -or -not (ProfileIsPrepared $profile)){ErrorDialog '只能选择这条线路已准备的连接方式。';return}
 StartJob @{Action='LinePreference';Id=$script:LineProfileUI.Id;ProfileId=$ProfileId} {param($line)
  $script:LineProfileUI.Line=$line;$script:LineProfileUI.Error='';ShowLineConnections;Toast '已保存下次默认方式，当前连接保持'
 } '保存下次默认方式…' -Failed {param($message)$script:LineProfileUI.Error=$message;ShowLineConnections}
}
function ShowLineConnections {
 $u=$script:LineProfileUI
 if($u -and (ProfileUIField $u 'MaintenanceMode' $false)){ShowLineMaintenancePage;return}
 PageHead '线路连接方式' '选择这条线路已准备的方式；设置默认只影响下次连接，立即连接需确认。' 'line-profiles'
 if(-not $u){ShowNodes;return}
 $line=$u.Line;$card=Card '24,20';$p=Stack;$card.Child=$p
 AddC $p (T ([string](ProfileUIField $line 'Name' '线路')) 17 $script:Ink 'SemiBold')
 if(NodeHasActiveProfile $line){AddC $p (Margin (T (ActiveLineStatus $line) 14 $script:Ink 'SemiBold') '0,8,0,0')}
 $r=LineRecommendationView $line
 AddC $p (Margin (ControlName (T $r.Label 15 $script:Ink 'SemiBold') 'LineDefaultLabel') '0,14,0,4');AddC $p (ControlName (T ($r.Basis+'。'+$r.Reason) 13 $script:Text2) 'LineRecommendationReason')
 AddLineRecommendationEvidence $p $line
 if(LegacyLineNeedsTcpMaintenance $line){AddC $p (Margin (ControlName (T '仅已准备UDP，维护后可增加TCP' 13 $script:Text2) 'LegacyLinePreparationHint') '0,12,0,0')}
 foreach($id in @('Udp','Tcp')){
  $profile=@(NodeProfileItems $line|Where-Object Id -eq $id)|Select-Object -First 1
  $row=Grid @('*','Auto');$row.Margin='0,14,0,12';$copy=Stack;AddC $copy (T (UIProfileName $id) 14 $script:Ink 'SemiBold');AddC $copy (ControlName (T ('准备：'+(ProfilePreparationStatus $profile)) 12.5 $script:Text2) ('ProfilePreparation'+$id))
  $status=if((ActiveNodeProfileId $line) -eq $id){ActiveLineStatus $line}elseif($profile){ConnectionProfileStatus $profile}else{'未准备'}
  AddC $copy (Margin (ControlName (T $status 12.5 $script:Text2) ('ProfileStatus'+$id)) '0,4,16,0');Cell $row $copy 0
  if(ProfileIsPrepared $profile){
   $actions=Stack
   $button=Btn $(if([string](ProfileUIField $line 'PreferredProfileId' '') -eq $id){'下次默认'}else{'设为下次默认'}) ('PreferProfile'+$id) {SaveLineDefaultProfile ([string]$this.Tag)} 'Btn';$button.Tag=$id;$button.IsEnabled=(-not (IsBusy) -and -not $script:ReadOnly -and [string](ProfileUIField $line 'PreferredProfileId' '') -ne $id);AddC $actions $button
   $active=(ActiveNodeProfileId $line) -eq $id
   $connect=Btn $(if($active){'当前使用'}elseif(NodeHasActiveProfile $line){'切换到 '+(UIProfileName $id)}else{'连接 '+(UIProfileName $id)}) ('ConnectProfile'+$id) {PreviewLineConnectionSwitch ([string]$this.Tag)} 'Ghost';$connect.Tag=$id;$connect.Margin='0,6,0,0';$connect.IsEnabled=(-not (IsBusy) -and -not $script:ReadOnly -and -not $active);AddC $actions $connect;Cell $row $actions 1
  }
  AddC $p $row
 }
 if($r.CanConnect -and -not (NodeHasActiveProfile $line)){$null=DeploymentActions $p $r.Button 'ConnectLineDefault' {PreviewDefaultLineConnection $script:LineProfileUI.Id}}
 elseif(-not (NodeHasActiveProfile $line)){$null=DeploymentActions $p '重试检查' 'LineProfilesRetry' {ShowConnectionRecovery $script:LineProfileUI.Id ''} 'Btn'}
 $null=DeploymentActions $p '管理 / 旧线路维护…' 'LineMaintenance' {ShowLineMaintenance} 'Ghost'
 if($u.Error){AddC $p (Margin (Notice 'warn' '需要处理' $u.Error) '0,12,0,0')}
 if($u.SwitchResult){AddC $p (Margin (T ([string](ProfileUIField $u.SwitchResult 'Message' '操作结果已记录，请核对实际运行状态。')) 13 $script:Text2) '0,12,0,0')}
 if($u.Error -match '\[TC:NeedsRecovery\]' -or [string](ProfileUIField $u.SwitchResult 'Status' '') -eq 'NeedsRecovery'){$null=DeploymentActions $p '核对失败任务…' 'CheckConnectionTransaction' {ShowConnectionTransactionRecoveryPrompt $script:LineProfileUI.Error} 'Btn'}
 $null=DeploymentActions $p '返回线路' 'LineProfilesBack' {ShowNodes;FetchNodes} 'Ghost';AddC $script:HostPanel $card
}
function ShowLineMaintenance {
 if(-not $script:LineProfileUI -or (IsBusy)){return}
 $script:LineProfileUI.MaintenanceMode=$true;ShowLineConnections
}
function ShowLineMaintenancePage {
 $u=$script:LineProfileUI;$line=$u.Line
 PageHead '管理 / 旧线路维护' '此入口管理服务器与缺失配置；日常连接使用已准备的方式。' 'line-profiles'
 $card=Card;$p=Stack;$card.Child=$p;AddC $p (T ([string](ProfileUIField $line 'Name' '线路')) 17 $script:Ink 'SemiBold')
 if(LegacyLineNeedsTcpMaintenance $line){
  AddC $p (Margin (T '仅已准备UDP，维护后可增加TCP' 14 $script:Ink) '0,12,0,0')
  AddC $p (Margin (Note '增加 TCP 需要服务器管理权限。先核对原服务器与设备，再预览需要的变更；完成后仍保留同一条线路和当前连接。') '0,12,0,0')
  $null=DeploymentActions $p '维护旧线路：增加 TCP…' 'PrepareMissingTcp' {OpenAutomaticTransport $script:LineProfileUI.Id} 'Btn'
 }else{AddC $p (Margin (Note '没有可在此补齐的旧线路 TCP 配置。未完成的新部署请从服务器台账继续原部署记录。') '0,12,0,0')}
 $null=DeploymentActions $p '我的服务器与部署记录' 'LineManageServers' {ShowServerManagement} 'Ghost'
 $null=DeploymentActions $p '返回连接方式' 'LineMaintenanceBack' {$script:LineProfileUI.MaintenanceMode=$false;ShowLineConnections} 'Ghost'
 AddC $script:HostPanel $card
}
function ShowConnectionTransactionRecoveryPrompt {param([string]$Message)
 OpenDialog '连接任务需要核对' '上次切换没有完成，需要先核对实际进程和已还原的配置。' '仅在已确认通道停止且原配置完整时结束故障任务；之后由你点击连接。' '核对当前状态' {
  StartJob @{Action='ConnectionTransactionReconcile'} {param($d)
   RefreshOverview -Silent
   if(ProfileUIField $d 'Resolved' $false){OpenDialog '故障任务已核对' '已结束符合条件的故障记录，当前连接状态保持。' '需要使用线路时，请重新点击连接；本次没有自动重连。' '知道了' $null ''}
   else{OpenDialog '仍需处理' '尚不能确认通道完全停止，或原配置资料已经变化。' '请查看运行报告中的实际状态，再处理恢复。' '知道了' $null ''}
  } '核对故障任务，不改变当前连接…'
 } '稍后处理'
}
function PreviewDefaultLineConnection {param([string]$LineId) StartLineConnectionPreview $LineId ''}
function PreviewLineConnectionSwitch {param([string]$ProfileId)
 if(-not $script:LineProfileUI){return}
 $profile=@(NodeProfileItems $script:LineProfileUI.Line|Where-Object Id -eq $ProfileId)|Select-Object -First 1
 if($ProfileId -notin @('Udp','Tcp') -or -not (ProfileIsPrepared $profile)){ErrorDialog '只能连接这条线路已准备的方式。';return}
 StartLineConnectionPreview $script:LineProfileUI.Id $ProfileId
}
function StartLineConnectionPreview {param([string]$LineId,[string]$ProfileId)
 if((IsBusy) -or $script:ConnectionPreviewUI -or (DialogOpenUI)){return}
 if($script:ReadOnly){ErrorDialog '当前为只读检查窗口，请在主窗口连接。';return}
 if(-not $LineId){ErrorDialog '尚未取得线路记录，请刷新线路后重试。';return}
 if($script:Overview.NinjaRunning){ErrorDialog '请先退出整个 NinjaTrader，再连接或切换方式。';return}
 $script:ConnectionPreviewUI=@{LineId=$LineId;ProfileId=$ProfileId;Preview=$null}
 $known=@($script:Nodes|Where-Object {[string](ProfileUIField $_ 'LineId' (ProfileUIField $_ 'id' '')) -eq $LineId})|Select-Object -First 1
 if(-not $ProfileId -and [int](ProfileUIField $known 'Revision' 0) -lt 1){
  StartJob @{Action='LineRegister';Id=$LineId} {param($line)
   if(-not $script:ConnectionPreviewUI){return}
   $id=[string](ProfileUIField $line 'LineId' '')
   if(-not $id -or [int](ProfileUIField $line 'Revision' 0) -lt 1){$script:ConnectionPreviewUI=$null;ErrorDialog '旧线路连接资料尚未准备完成，请重试。';return}
   $script:ConnectionPreviewUI.LineId=$id
   RequestLineConnectionPreview
  } '准备已有线路的连接资料，当前连接保持…' -Failed {param($message)$script:ConnectionPreviewUI=$null;ErrorDialog $message}
  return
 }
 RequestLineConnectionPreview
}
function RequestLineConnectionPreview {
 $u=$script:ConnectionPreviewUI;if(-not $u){return};$LineId=[string]$u.LineId;$ProfileId=[string]$u.ProfileId
 $request=@{Action='ConnectionDefaultPreview';LineId=$LineId};if($ProfileId){$request.Action='ConnectionSwitchPreview';$request.ProfileId=$ProfileId}
 StartJob $request {param($preview)
  $u=$script:ConnectionPreviewUI;if(-not $u){return}
  $allowed=(ProfileUIField $preview 'CanSwitch' $false) -eq $true
  if(-not $allowed){$reason=[string](ProfileUIField $preview 'Message' '');if(-not $reason){$reason=@(ProfileUIField $preview 'Reasons' @()) -join '；'};if(-not $reason){$reason='尚不具备启用资格，请重试检查。'};$script:ConnectionPreviewUI=$null;ErrorDialog $reason;return}
  if([string](ProfileUIField $preview 'LineId' '') -ne $u.LineId -or [string](ProfileUIField $preview 'ProfileId' '') -notin @('Udp','Tcp') -or -not (ProfileUIField $preview 'PreviewToken') -or ($u.ProfileId -and $preview.ProfileId -ne $u.ProfileId)){$script:ConnectionPreviewUI=$null;ErrorDialog '连接预览与目标线路不一致或缺少确认凭据，请重新检查。';return}
  $script:ConnectionPreviewUI=$null
  # The dialog owns this immutable request. Pass it as explicit callback data;
  # GetNewClosure creates a module scope that cannot resolve script helpers
  # when the packaged launcher invokes this script with '&'.
  $approved=@{Action='ConnectionSwitchCommit';LineId=[string]$preview.LineId;ProfileId=[string]$preview.ProfileId;PreviewToken=[string]$preview.PreviewToken}
  $confirm={param($approvedRequest) CommitLineConnectionPreview $approvedRequest}
  $reason=[string](ProfileUIField (ProfileUIField $preview 'Recommendation') 'Reason' '')
  OpenDialog '确认连接这条线路？' ('目标方式：'+(UIProfileName $preview.ProfileId)+'。'+$reason+[Environment]::NewLine+[string](ProfileUIField $preview 'Message' '连接后自动检查实际会话；若有原通道，切换会短暂中断连接。')) '失败时按事务结果报告恢复状态；行情、登录和订单仍需在交易软件中核对。' '连接并检查' $confirm '稍后使用' -Context $approved
 } '核对默认方式与连接预览…' -Failed {param($message)$script:ConnectionPreviewUI=$null;ErrorDialog $message}
}
function DialogOpenUI { $script:Window.FindName('Overlay').Visibility -eq 'Visible' }
function CommitLineConnectionPreview {param([hashtable]$Approved)
 if(IsBusy){return}
 StartJob $Approved {param($d)
  if($script:LineProfileUI){$script:LineProfileUI.SwitchResult=$d}
  $script:Pending=$null
  if([string](ProfileUIField $d 'Status' '') -eq 'NeedsRecovery'){ShowConnectionTransactionRecoveryPrompt ([string]$d.Message)}
  elseif(-not (ProfileUIField $d 'Activated' $false)){ErrorDialog ([string](ProfileUIField $d 'Message' '本次连接未完成，请核对实际状态。'))}
  else{Toast '连接操作已完成，正在读取本次会话检查结果'}
  $script:Role='client';$script:Step=0;ShowHome;RefreshOverview -Silent
 } '连接并检查实际会话…' 'Applying' -Failed {param($message)$script:Pending=$null;ErrorDialog $message;RefreshOverview -Silent}
}
