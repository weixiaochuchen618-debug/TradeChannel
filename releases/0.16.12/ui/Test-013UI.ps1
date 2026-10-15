# 0.13.0 WPF suite. TradeChannel.ps1 -SelfTest dispatches this file.
# The original harness captures all requests and owns rendering/cleanup/results.
# Only fixtures below run: no production Worker, SSH, real identity or network.
if(-not $script:Smoke -or -not $SelfTest){throw 'Only TradeChannel.ps1 -SelfTest may execute these fixtures.'}
$env:PSModulePath=Join-Path $PSHOME 'Modules'
$script:UI013Enabled=$true
function NewUI013Line {param([string]$Udp='Passed',[string]$Tcp='Passed',[ValidateSet('Evidence','Performance','Stability','PolicyDefault')][string]$SelectionKind='Evidence',[DateTimeOffset]$At=[DateTimeOffset]::UtcNow)
 $line=NewUI0120Line $Udp $Tcp -SelectionKind $SelectionKind -NoSaved -At $At
 if($SelectionKind -eq 'Evidence'){
  foreach($profile in $line.Profiles){
   $rows=@();for($i=0;$i -lt 6;$i++){$rows+=,[pscustomobject]@{Name='FixtureHttps';Required=$true;Status=$profile.Validation.Status;DurationMs=$(if($profile.Id -eq 'Udp'){160+$i}else{85+$i});TargetUrl='https://127.0.0.1/fixture-only'}}
   $raw=$profile.Validation.Result;$raw.Samples=$rows;$raw.Metrics=[pscustomobject]@{Planned=6;Attempted=6;Passed=$(if($profile.Validation.Status -eq 'Passed'){6}else{0});MedianResponseMs=$(if($profile.Id -eq 'Udp'){163}else{88});P95ResponseMs=$(if($profile.Id -eq 'Udp'){165}else{90});PerformanceRanked=$false}
   $profile.Validation=ConvertTo-TCProtocolEvidence -Result $raw -Profile $profile -NetworkContext $script:Fixture0120Network -Now $At
  }
 }
 $line.Recommendation=Get-TCProtocolRecommendation -Profiles $line.Profiles -NetworkContext $script:Fixture0120Network -LineId $line.LineId -Now $At
 if($line.Recommendation.Status -eq 'Recommended'){SaveUI0120Default $line $line.Recommendation.RecommendedProfileId -At $At}
 $line
}
function NewUI013Run {param($Line,[string]$Completeness='Complete',[string[]]$Missing=@())
 $run=NewUI0120Run $Line -Legacy:($Completeness -ne 'Complete')
 $run|Add-Member NoteProperty Intent 'New' -Force
 $run|Add-Member NoteProperty DeploymentCompleteness $Completeness -Force
 $run|Add-Member NoteProperty MissingProtocols @($Missing) -Force
 $run|Add-Member NoteProperty PartialUseAccepted $false -Force
 $run|Add-Member NoteProperty RecoveryRequired ($Completeness -eq 'NeedsRecovery') -Force
 foreach($id in $Missing){
  $run.ProtocolPreparation.$id.LocalPreparation='Missing';$run.ProtocolPreparation.$id.ServerPreparation='Failed'
  $run.ProtocolPreparation.$id.Error=[pscustomobject]@{Code='FixturePreparationFailed';Message=((UIProfileName $id)+' 准备未完成（模拟）')}
 }
 if($Completeness -eq 'Partial'){$run.Status='CompletedWithWarnings'}
 if($Completeness -eq 'NeedsRecovery'){$run.Status='NeedsRecovery';$run.LastError=[pscustomobject]@{Code='NeedsRecovery';Message='原部署结果需要恢复（模拟）'}}
 $run
}
function NewUI013PartialLine {param([string]$Prepared='Udp')
 $line=NewUI013Line
 $line.Profiles=@($line.Profiles|Where-Object Id -eq $Prepared)
 $line.Recommendation=Get-TCProtocolRecommendation -Profiles $line.Profiles -NetworkContext $script:Fixture0120Network -LineId $hk
 $line.PreferredProfileId=$Prepared;$line.PreferenceSource=$line.Recommendation.Source;SaveUI0120Default $line $Prepared
 $line
}
function RenderUI013Line {param($Line)
 $script:Nodes=@($Line);$script:LineProfileUI=@{Id=$Line.LineId;Line=$Line;Error='';SwitchResult=$null;MaintenanceMode=$false}
 ShowLineConnections
}
function AssertUI013LocalRequests {param([string]$Name)
 $forbidden=@(Requests|Where-Object {$_.Request.ContainsKey('SessionAction') -or $_.Request.Action -in @('ServerOperation','AutoTransportBind','AutoTransportSaved','AutoTransportPrepare','SetTransportMode','DeploymentAttach','UpgradeActive','ImportNode')})
 AssertUI ($forbidden.Count -eq 0) ($Name+' emits no server action or direct network mutation')
}
function InvokeUI013Tests {
 $beforeAssertions=$script:Assertions.Count;$beforeRequests=$script:AllSelfTestRequests.Count
 $script:Window.Width=1180;$script:Window.Height=800
 # Complete deployment and failed reachability are independent outcomes.
 Fixture0120;$line=NewUI013Line;$script:Nodes=@($line);RenderUI0120Run (NewUI013Run $line)
 AssertUI ($script:Controls.DeployPreparationStatus.Text -eq '准备完成：UDP / TCP 已备齐') '013 complete explicitly means both protocols are prepared'
 AssertUI ($script:Controls.DeployPreparationUdp.Text -eq '已准备' -and $script:Controls.DeployPreparationTcp.Text -eq '已准备') '013 protocol preparation is shown separately from network checks'
 AssertUI (-not $script:Controls.ContainsKey('DeployUsePrepared') -and -not $script:Controls.ContainsKey('DeployCompleteRemaining') -and @(Requests).Count -eq 0) '013 complete rendering needs no partial acceptance or worker action'
 ShowNodes
 AssertUI (@($script:HostPanel.Children|Where-Object {$_.Name -like 'NodeCard*'}).Count -eq 1 -and $script:Nodes.Count -eq 1) '013 UDP and TCP remain profiles of one logical line'
 RenderUI0120Run (NewUI013Run $line);Snapshot '013-01-dual-complete'
 Fixture0120;$line=NewUI013Line 'Failed' 'Failed';RenderUI0120Run (NewUI013Run $line)
 AssertUI ($script:Controls.DeployPreparationStatus.Text -like '*已备齐*' -and $script:Controls.DeployProfileUdp.Text -like '*未通过*' -and $script:Controls.DeployProfileTcp.Text -like '*未通过*') '013 reachability failure never changes Complete into Partial'
 AssertUI (-not $script:Controls.ContainsKey('DeployRetryTrust') -and -not $script:Controls.ContainsKey('DeployUsePrepared')) '013 failed reachability never adds login or deployment repair'
 # A missing protocol requires explicit acceptance before a connection entry.
 foreach($prepared in @('Udp','Tcp')){
  Fixture0120;$line=NewUI013PartialLine $prepared;$script:Nodes=@($line)
  $missing=if($prepared -eq 'Udp'){'Tcp'}else{'Udp'};$run=NewUI013Run $line 'Partial' @($missing);RenderUI0120Run $run
  AssertUI ($script:Controls.DeployPreparationStatus.Text -like '部分完成*' -and $script:Controls.DeployMissingProtocols.Text -eq ('缺少协议：'+$missing.ToUpperInvariant())) ('013 Partial lists the actual missing '+$missing+' array entry')
  AssertUI ($script:Controls.DeployUsePrepared.Content -eq '确认先保存已准备方式' -and $script:Controls.DeployCompleteRemaining.Content -eq '继续完成另一种配置' -and $script:Controls.DeployLater.Content -eq '保存配置，稍后使用') '013 Partial exposes completion, later save and explicit prepared-use decisions'
  AssertUI (-not $script:Controls.ContainsKey('DeployConnectRecommended') -and -not $script:Controls.ContainsKey('DeployRetryTrust') -and -not $script:Controls.ContainsKey('ServerPassword')) '013 Partial has no silent connection or automatic login'
  ClickUI 'DeployUsePrepared';$request=@(Requests)[0].Request
  AssertUI ($request.Action -eq 'DeploymentProceed' -and $request.Command -eq 'UsePrepared' -and $request.RunId -eq $run.RunId -and $request.Count -eq 3) '013 UsePrepared uses the real Worker deployment command and original run'
  AssertUI (-not $run.PartialUseAccepted -and @(Requests).Count -eq 1) '013 clicking UsePrepared waits for persisted Worker acceptance and cannot connect'
  AssertUI013LocalRequests '013 UsePrepared'
  $run.PartialUseAccepted=$true;CompleteUI $run
  AssertUI ($script:Controls.ContainsKey('DeployPartialUseAccepted') -and $script:Controls.DeployPreparationStatus.Text -like '部分完成*' -and $run.DeploymentCompleteness -eq 'Partial' -and $run.MissingProtocols.Count -eq 1) '013 accepted partial use remains visibly Partial with its missing protocol'
  AssertUI ($script:Controls.ContainsKey('DeployConnectRecommended') -and -not $script:Controls.ContainsKey('DeployUsePrepared') -and @(Requests).Count -eq 1) '013 acceptance only reveals a separate confirmed connection entry'
  ClickUI 'DeployConnectRecommended'
  AssertUI (@(Requests).Count -eq 2 -and @(Requests)[-1].Request.Action -eq 'ConnectionSwitchPreview' -and @(Requests)[-1].Request.ProfileId -eq $prepared -and @(Requests)[-1].Request.LineId -eq $hk) ('013 accepted partial uses the same controlled transaction with its explicitly accepted profile: prepared='+$prepared+'; actions='+(@(Requests|ForEach-Object {$_.Request.Action}) -join ',')+'; dialog='+$script:Window.FindName('DialogBody').Text)
  CompleteUI ([pscustomobject]@{CanSwitch=$true;LineId=$hk;ProfileId=$prepared;PreviewToken=('partial-'+$prepared)})
  ClickDialog 'DialogCancel'
  AssertUI (@(Requests).Count -eq 2) '013 cancelling prepared connection keeps the current network'
 }
 Fixture0120;$line=NewUI013PartialLine;$run=NewUI013Run $line 'Partial' @('Tcp');RenderUI0120Run $run
 Snapshot '013-02-partial-udp'
 ClickUI 'DeployCompleteRemaining';$request=@(Requests)[0].Request
 AssertUI ($request.Action -eq 'DeploymentProceed' -and $request.Command -eq 'Recheck' -and $request.RunId -eq $run.RunId -and -not $run.PartialUseAccepted) '013 continue deployment resumes the original run without accepting partial use'
 FailUI 'TCP 准备仍未完成（模拟）'
 AssertUI ($script:Controls.DeployPreparationStatus.Text -like '部分完成*' -and $script:Controls.ContainsKey('DeployUsePrepared') -and -not $script:Controls.ContainsKey('DeployRetryTrust')) '013 retry failure keeps Partial and does not force credentials'
 Fixture0120;$line=NewUI013PartialLine;$run=NewUI013Run $line 'Partial' @('Tcp');RenderUI0120Run $run;ClickUI 'DeployLater'
 $request=@(Requests)[0].Request
 AssertUI (@(Requests).Count -eq 1 -and $request.Action -eq 'DeploymentProceed' -and $request.Command -eq 'Save' -and $request.RunId -eq $run.RunId -and $request.Count -eq 3 -and -not $run.PartialUseAccepted -and $script:Page -eq 'setup') '013 later requests only Save and waits without accepting partial use or starting a connection'
 $saved=NewUI013Run $line 'Partial' @('Tcp');$saved|Add-Member NoteProperty SavedForLaterAtUtc ([DateTimeOffset]::UtcNow.ToString('o'));CompleteUI $saved
 AssertUI ($script:Page -eq 'nodes' -and $script:DeployUI.Run.DeploymentCompleteness -eq 'Partial' -and $script:DeployUI.Run.MissingProtocols.Count -eq 1 -and -not $script:DeployUI.Run.PartialUseAccepted -and $script:DeployUI.Run.SavedForLaterAtUtc -and @(Requests|Where-Object {$_.Request.Action -like 'Connection*' -or ($_.Request.Action -eq 'DeploymentProceed' -and $_.Request.Command -ne 'Save')}).Count -eq 0) '013 saved partial remains partial and returns to lines without UsePrepared or connection dispatch'
 # NeedsRecovery blocks prepared use even when an old validation passed.
 Fixture0120;$line=NewUI013PartialLine;RenderUI0120Run (NewUI013Run $line 'NeedsRecovery' @('Tcp'))
 AssertUI ($script:Controls.DeployPreparationStatus.Text -like '*需要恢复*' -and -not $script:Controls.ContainsKey('DeployUsePrepared') -and -not $script:Controls.ContainsKey('DeployConnectRecommended') -and -not $script:Controls.ContainsKey('DeployProbe')) '013 recovery cannot bypass the deployment transaction through prepared use or a probe'
 Snapshot '013-03-needs-recovery'
 ClickUI 'DeployReconcile';AssertUI (@(Requests).Count -eq 1 -and @(Requests)[0].Request.Command -eq 'Continue') '013 deployment recovery keeps the original reconciliation command'
 # Active identity blocks candidate probing; existing session evidence is separate.
 Fixture0120 'Connected' @{ActiveLineId=$hk;ActiveProfileId='Udp'}
 $line=NewUI013Line 'Blocked' 'Blocked';$script:Nodes=@($line)
 $line.Profiles[0].Validation.Code='IdentityInUse';$line.Profiles[1].Validation.Code='IdentityInUse'
 $script:Overview|Add-Member NoteProperty RuntimeValidation ([pscustomobject]@{LineId=$hk;ProfileId='Udp';Status='Passed';ForwardingPassed=$true}) -Force
 RenderUI0120Run (NewUI013Run $line)
 AssertUI ($script:Controls.DeployPreparationStatus.Text -like '*已备齐*' -and $script:Controls.DeployProfileTcp.Text -like '*身份正在使用*') '013 identity occupancy affects the network check rather than deployment completeness'
 AssertUI ($script:Controls.DeployActiveStatus.Text -like '*UDP*本次连接检查通过*' -and -not $script:Controls.ContainsKey('DeployRetryTrust') -and @(Requests).Count -eq 0) '013 occupied identity retains the active session and never launches a parallel probe or login'
 Snapshot '013-04-identity-in-use'
 # Verified non-application renders an explicit continuation, never auto-runs.
 Fixture0120;$line=NewUI013Line;$run=NewUI013Run $line
 $run.Stage='RecoveryVerified';$run.Status='WaitingUser'
 $run|Add-Member NoteProperty RecoveryVerification ([pscustomobject]@{Status='Verified';Outcome='NotApplied'}) -Force
 RenderUI0120Run $run
 AssertUI ($script:Controls.ContainsKey('DeployContinueVerified') -and -not $script:Controls.ContainsKey('DeployConnectRecommended') -and @(Requests).Count -eq 0) '0166 verified non-application displays continuation without automatic connection or submission'
 Snapshot '0166-01-management-not-applied'
 ClickUI 'DeployContinueVerified';$request=@(Requests)[0].Request
 AssertUI ($request.Action -eq 'DeploymentProceed' -and $request.Command -eq 'Continue' -and $request.RunId -eq $run.RunId) '0166 continuation targets the original recovered deployment'
 # Real comparison production supplies ranking, measured samples and provenance.
 Fixture0120;$line=NewUI013Line -SelectionKind Performance;RenderUI0120Run (NewUI013Run $line)
 AssertUI ($line.Recommendation.Source -eq 'Performance' -and $line.SavedConnectionPreference.Source -eq 'Performance' -and $line.SavedConnectionPreference.Provenance.Kind -eq 'Recommendation' -and $script:Controls.DeployRecommendationReason.Text -like '*性能样本选择*原轮次*' -and $script:Controls.DeployDefaultLabel.Text -like '*TCP*') '013 original performance evidence remains a saved recommendation origin, never a fabricated manual choice'
 AssertUI ($script:Controls.DeployEvidenceUdp.Text -like '*已测 18 / 18*200 ms*检查时间*' -and $script:Controls.DeployEvidenceTcp.Text -like '*已测 18 / 18*60 ms*检查时间*' -and $script:Controls.DeployRecommendationTime.Text -notlike '*尚无记录*') '013 performance displays the original comparison measurements and timestamps'
 AssertUI ($script:Controls.ContainsKey('DeployConnectRecommended') -and $script:Controls.DeployComparisonSummary.Text -like '*18 对样本 / 3 轮*' -and @(Requests).Count -eq 0) '013 ranked comparison shows actual paired sample rounds without automatic activation'
 AssertUI ($script:Controls.DeployTargetAddressHttps.Text -like '*200 ms*60 ms*9 对样本 / 3 轮*') '013 original address HTTPS comparison is displayed independently'
 AssertUI ($script:Controls.DeployTargetDomainDnsHttps.Text -like '*200 ms*60 ms*9 对样本 / 3 轮*') '013 original domain HTTPS comparison is displayed independently'
 $script:Controls.DeployTechnicalDetails.IsExpanded=$true;ScrollToUI 'DeployComparisonSummary';Snapshot '013-05-performance-evidence'
 Fixture0120;$line=NewUI013Line -SelectionKind PolicyDefault;RenderUI0120Run (NewUI013Run $line)
 AssertUI ($line.Recommendation.Source -eq 'PolicyDefault' -and -not $line.Recommendation.PerformanceRanked -and $script:Controls.DeployRecommendationReason.Text -like '*策略选择*未证明最快*' -and $script:Controls.DeployComparisonSummary.Text -like '*非最快*') '013 actual tied comparison is a policy default with no invented speed winner'
 Fixture0120;$line=NewUI013Line -SelectionKind PolicyDefault -At ([DateTimeOffset]::UtcNow.AddHours(-1));RenderUI0120Run (NewUI013Run $line);$view=LineRecommendationView $line
 AssertUI ($view.CanConnect -and -not $view.RecommendationCurrent -and $view.OldRecommendationLabel -like '*已过期*' -and $script:Controls.DeployConnectRecommended.Content -like '*UDP*检查*') '013 original comparison expiry preserves saved default but cannot be current recommendation evidence'
 Fixture0120;$line=NewUI013Line;RenderUI0120Run (NewUI013Run $line)
 AssertUI ($script:Controls.DeployRecommendationReason.Text -like '*策略选择*未证明最快*') '013 equally qualified configs retain an explicit strategy origin without a fastest claim'
 Fixture0120;$line=NewUI013Line -SelectionKind Stability;RenderUI0120Run (NewUI013Run $line)
 AssertUI ($script:Controls.ContainsKey('DeployConnectRecommended') -and $line.Recommendation.Source -eq 'Stability' -and $script:Controls.DeployRecommendationReason.Text -like '*必需样本稳定性选择*') '013 original required-sample failure produces a stability default without inventing provenance'
 # The deployment protocol field is an initial preference; all choices use one line.
 foreach($mode in @('Auto','Udp','Tcp')){
  Fixture0120;ShowProductDeployment
  $option=@($script:Controls.DeployTransport.Items|Where-Object Tag -eq $mode)[0];$script:Controls.DeployTransport.SelectedItem=$option
  $script:Controls.DeployConnectionText.Text='127.0.0.1';$script:Controls.DeployName.Text='仅回环模拟';$script:Controls.DeployPassword.Password='fixture-only'
  AssertUI ($option.Content -notlike '*只准备*' -and $option.Content -notlike '*必须准备*') ('013 '+$mode+' option describes an initial preference instead of deployment scope')
  StartProductDeployment;$request=@(Requests)[0].Request
  AssertUI ($request.Action -eq 'DeploymentCreate' -and $request.Transport -eq $mode -and $request.Connection.Host -eq '127.0.0.1' -and -not $request.ContainsKey('Password')) '013 preference uses the deployment contract with a loopback-only fixture and no captured secret'
  $line=NewUI013Line;CompleteUI (NewUI013Run $line)
  AssertUI ($script:Controls.DeployPreparationUdp.Text -eq '已准备' -and $script:Controls.DeployPreparationTcp.Text -eq '已准备' -and @(Requests)[-1].Request.Action -eq 'DeploymentSessionFixture') ('013 every initial preference renders dual preparation with only a synthetic session; actions='+(@(Requests|ForEach-Object {$_.Request.Action}) -join ',')+'; role='+$script:Role+'; run='+[string]$script:DeployUI.Run.RunId+'; dialog='+$script:Window.FindName('DialogBody').Text)
  AssertUI013LocalRequests '013 deployment fixture'
 }
 # Saving UDP/TCP defaults cannot perform a server operation or change an active profile.
 foreach($state in @('Disconnected','Connected')){foreach($id in @('Udp','Tcp')){
  Fixture0120 $state @{ActiveLineId=$hk;ActiveProfileId='Udp'};$line=NewUI013Line;SaveUI0120Default $line $(if($id -eq 'Udp'){'Tcp'}else{'Udp'}) -Manual
  RenderUI013Line $line;$beforeActive=$script:Overview.ActiveProfileId;ClickUI ('PreferProfile'+$id)
  $request=@(Requests)[0].Request
  AssertUI ($request.Action -eq 'LinePreference' -and $request.Id -eq $hk -and $request.ProfileId -eq $id -and $request.ExpectedRevision -eq $line.Revision -and $request.Count -eq 4) ('013 '+$state+' manual '+$id+' sends only the version-bound local profile preference')
  SaveUI0120Default $line $id -Manual;CompleteUI $line
  AssertUI ($script:Overview.ActiveProfileId -eq $beforeActive -and $script:Nodes.Count -eq 1 -and @(Requests).Count -eq 1) '013 saving preference keeps active identity and one line'
  AssertUI013LocalRequests '013 manual preference'
 }}
 # Explicit immediate switches use the original transaction for either profile.
 foreach($id in @('Udp','Tcp')){
  $other=if($id -eq 'Udp'){'Tcp'}else{'Udp'}
  Fixture0120 'Connected' @{ActiveLineId=$hk;ActiveProfileId=$other};$line=NewUI013Line;RenderUI013Line $line
  ClickUI ('ConnectProfile'+$id);$request=@(Requests)[0].Request
  AssertUI ($request.LineId -eq $hk -and (($id -eq $line.SavedConnectionPreference.ProfileId -and $request.Action -eq 'ConnectionDefaultPreview' -and $request.SelectionMode -eq 'SavedDefault' -and -not $request.ContainsKey('ProfileId')) -or ($id -ne $line.SavedConnectionPreference.ProfileId -and $request.Action -eq 'ConnectionSwitchPreview' -and $request.ProfileId -eq $id))) ('013 visible '+$id+' uses saved-default preview for the saved mode and explicit preview for the other prepared profile')
  CompleteUI ([pscustomobject]@{LineId=$hk;ProfileId=$id;CanSwitch=$true;PreviewToken=('013-'+$id);Message='模拟切换，失败时原线路回退。'})
  AssertUI ((DialogOpen) -and @(Requests).Count -eq 1) '013 immediate switch requires the existing confirmation token'
  ClickDialog 'DialogCancel';AssertUI (@(Requests).Count -eq 1) '013 cancelling manual switch is inert'
  ClickUI ('ConnectProfile'+$id);CompleteUI ([pscustomobject]@{LineId=$hk;ProfileId=$id;CanSwitch=$true;PreviewToken=('013-commit-'+$id);Message='模拟切换'})
  ClickDialog 'DialogConfirm';$request=@(Requests)[-1].Request
  AssertUI ($request.Action -eq 'ConnectionSwitchCommit' -and $request.LineId -eq $hk -and $request.ProfileId -eq $id -and $request.PreviewToken -eq ('013-commit-'+$id)) '013 explicit manual commit stays bound to the shown existing profile'
  CompleteUI ([pscustomobject]@{Status='RolledBack';Activated=$false;Message='切换未完成，已恢复原线路（模拟）'})
  AssertUI ((DialogOpen) -and $script:Window.FindName('DialogBody').Text -like '*已恢复原线路*' -and $script:Overview.ActiveProfileId -eq $other) '013 failed switch reports rollback while retaining the original active profile'
  AssertUI013LocalRequests '013 existing profile transaction'
 }
 Fixture0120 'Connected' @{NinjaRunning=$true};$line=NewUI013Line;RenderUI013Line $line;PreviewLineConnectionSwitch 'Tcp'
 AssertUI ((DialogOpen) -and @(Requests).Count -eq 0) '013 NinjaTrader guard blocks manual existing-profile preview before dispatch'
 Fixture0120;$line=NewUI013PartialLine;RenderUI013Line $line;PreviewLineConnectionSwitch 'Tcp'
 AssertUI ((DialogOpen) -and @(Requests).Count -eq 0 -and -not $script:Controls.ContainsKey('ConnectProfileTcp')) '013 missing TCP cannot become a profile switch or automatic server deployment'
 Fixture0120;$line=NewUI013Line;RenderUI013Line $line;$script:ReadOnly=$true
 try{SaveLineDefaultProfile 'Tcp';AssertUI (@(Requests).Count -eq 0) '013 read-only page cannot change profile preference';CloseDialog;PreviewLineConnectionSwitch 'Tcp';AssertUI (@(Requests).Count -eq 0) '013 read-only page cannot preview an immediate connection'}finally{$script:ReadOnly=$false}
 # Daily selection/failure cannot prompt credentials. Maintenance has its own entry.
 Fixture0120
 $legacy=[pscustomobject]@{id=$hk;LineId=$hk;Name='模拟旧 UDP 线路';manifestPath=$script:Fixture0120Udp;Profiles=@((NewUI013Line).Profiles[0]);PreferredProfileId='Udp';PreferenceSource='ConfiguredDefault';Revision=1;status='Registered'}
 RenderUI013Line $legacy
 AssertUI ($script:Controls.LegacyLinePreparationHint.Text -eq '仅已准备UDP，维护后可增加TCP' -and -not $script:Controls.ContainsKey('PrepareMissingTcp') -and -not $script:Controls.ContainsKey('ServerPassword')) '013 legacy daily page explains UDP-only availability without deployment or login controls'
 ShowNodes;AssertUI (-not $script:Controls.ContainsKey('Proto'+$hk.Replace('-',''))) '013 daily line cards cannot turn missing TCP into the normal-use deployment path'
 RenderUI013Line $legacy;ClickUI 'LineMaintenance'
 AssertUI (@(Requests).Count -eq 1 -and @(Requests)[0].Request.Action -eq 'LineProfiles') '016 server entry reads the exact original line before choosing any maintenance target'
 CompleteUI $legacy
 AssertUI ($script:Controls.ContainsKey('RetryLineServerBinding') -and -not $script:Controls.ContainsKey('ServerPassword') -and -not $script:Controls.ContainsKey('PrepareMissingTcp')) '016 missing server binding exposes its reason without requesting deployment credentials'
 $script:Actions.Clear();ShowLineMaintenance
 AssertUI ($script:Controls.ContainsKey('PrepareMissingTcp') -and $script:Controls.PrepareMissingTcp.Content -like '*维护旧线路*' -and @(Requests).Count -eq 0) '013 explicit management entry alone reveals legacy TCP maintenance'
 Snapshot '013-06-legacy-maintenance'
 ClickUI 'PrepareMissingTcp';AssertUI (@(Requests).Count -eq 1 -and @(Requests)[0].Request.Action -eq 'AutoTransportContext') '013 explicit legacy maintenance first reads context without a server operation'
 CompleteUI ([pscustomobject]@{Id=$hk;Name='模拟旧线路';DefaultServer='127.0.0.1';ClientPublicKey='fixture-client';ServerPublicKey='fixture-server';HasSettings=$false;NeedsAuthentication=$true;Connection=[pscustomobject]@{User='root';Port=22}})
 AssertUI ($script:Controls.ContainsKey('AutomaticTcpLogin') -and @(Requests).Count -eq 1) '013 server login appears only after explicitly entering legacy maintenance'
 foreach($useLegacy in @($false,$true)){
  Fixture0120;$script:Nodes=@($(if($useLegacy){$legacy}else{NewUI013Line 'Failed' 'Failed'}));$script:RecoveryContext=@{Id=$hk;Message='模拟连接失败'}
  $script:RecoveryResult=[pscustomobject]@{Code='ActiveForwardingUnverified';Summary='模拟转发未通过';Checks=@();CanPrepareTcp=$true};ShowConnectionRecoveryPage
  AssertUI (-not $script:Controls.ContainsKey('RecoveryPrepareTcp') -and -not $script:Controls.ContainsKey('AutomaticTcpLogin') -and -not $script:Controls.ContainsKey('ServerPassword') -and @(Requests).Count -eq 0) '013 ordinary connection failure never offers login or supplemental deployment'
  ClickUI 'RecoveryRetry';FailUI '模拟诊断错误';AssertUI013LocalRequests '013 ordinary diagnostics'
 }
 # Automatic maintenance cannot accept a fabricated sibling node response.
 Fixture0120;$script:AutoTCP=@{Id=$hk;Context=[pscustomobject]@{Name='模拟旧线路';DefaultServer='127.0.0.1'};Stage='Preparing';Result=$null;Error=''}
 $rejected=$false;try{CompleteAutomaticTransportCandidate ([pscustomobject]@{Id=$us})}catch{$rejected=$_.Exception.Message -like '*未绑定原线路*'}
 AssertUI ($rejected -and $script:AutoTCP.Stage -ne 'Ready') '013 maintenance rejects a sibling-node result instead of claiming same-line readiness'
 CompleteAutomaticTransportCandidate ([pscustomobject]@{Id=$hk;ProbeRequiresInactiveIdentity=$true;Activated=$false;CurrentNetworkChanged=$false})
 AssertUI ($script:AutoTCP.Stage -eq 'Ready' -and $script:AutoTCP.Id -eq $hk -and @(Requests).Count -eq 0) '013 prepared maintenance keeps the original line and never starts an identity probe'
 # Fixed deployment actions remain visible while long form contents scroll.
 # LayoutTransform exercises an additional scale without changing system DPI.
 foreach($scale in @(1.0,1.5)){
  Fixture0120;$script:Window.Width=1000;$script:Window.Height=680
  $script:Window.Content.LayoutTransform=New-Object Windows.Media.ScaleTransform($scale,$scale)
  ShowProductDeployment
  foreach($method in @(0,1)){
   $script:Controls.DeployLoginMethod.SelectedIndex=$method;$script:Controls.DeploymentAdvanced.IsExpanded=$true
   $script:Window.UpdateLayout();$script:Window.FindName('Scroll').ScrollToTop();$script:Window.UpdateLayout()
   $bar=$script:Window.FindName('DeploymentActionBar');$button=$script:Controls.ProductDeployInspect
   $top=$button.TranslatePoint((New-Object Windows.Point(0,0)),$script:Window)
   $bottom=$button.TranslatePoint((New-Object Windows.Point($button.ActualWidth,$button.ActualHeight)),$script:Window)
   AssertUI ($bar.IsVisible -and $button.Focusable -and $top.X -ge 0 -and $top.Y -ge 0 -and $bottom.X -le $script:Window.ActualWidth -and $bottom.Y -le $script:Window.ActualHeight) ('0165 fixed submit is visible at minimum window; scale='+$scale+' method='+$method)
   $script:Window.FindName('Scroll').ScrollToBottom();$script:Window.UpdateLayout()
   $scrolled=$button.TranslatePoint((New-Object Windows.Point(0,0)),$script:Window)
   AssertUI ([Math]::Abs($scrolled.Y-$top.Y) -lt 1) '0165 submit remains fixed while advanced form scrolls'
  }
  if($scale -eq 1.0){Snapshot '0165-01-fixed-key-form'}
  $script:Controls.DeployConnectionText.Text='192.0.2.99';$script:Controls.DeployPassword.Password='ISOLATED_FORM_SECRET'
  BeginProductDeployment Auto
  AssertUI (-not $script:Controls.DeployConnectionText.Text -and -not $script:Controls.DeployPassword.Password -and -not $script:DeployUI.SessionRef) '0165 a new form cannot inherit a previous form target or password'
  ShowHome;$script:Window.UpdateLayout()
  AssertUI (-not $script:Window.FindName('DeploymentActionBar').IsVisible) '0165 form actions disappear on leaving deployment'
 }
 $script:Window.Content.LayoutTransform=[Windows.Media.Transform]::Identity
 # Partial actions remain reachable at the supported minimum WPF window size.
 Fixture0120;$script:Window.Width=1000;$script:Window.Height=680;$line=NewUI013PartialLine;RenderUI0120Run (NewUI013Run $line 'Partial' @('Tcp'))
 ScrollToUI 'DeployUsePrepared';Snapshot '013-07-minimum-partial'
 foreach($id in @('DeployCompleteRemaining','DeployUsePrepared','DeployLater')){
  ScrollToUI $id;$control=$script:Controls[$id];$point=$control.TranslatePoint((New-Object Windows.Point(0,0)),$script:Window.Content)
  AssertUI ($control.ActualWidth -gt 60 -and $point.X -ge 0 -and $point.X+$control.ActualWidth -le $script:Window.Content.ActualWidth -and $point.Y -ge 0 -and $point.Y+$control.ActualHeight -le $script:Window.Content.ActualHeight) ('013 minimum WPF window keeps '+$id+' scroll-reachable')
 }
 $script:Window.Width=1180;$script:Window.Height=800
 foreach($case in @(@('Complete','UDP / TCP 配置已备齐'),@('Partial','接入部分完成'),@('NeedsRecovery','线路仍有待处理问题'))){
  Fixture0120;InitializePairingUI
  $script:DeployUI.PairIntake.Role='Connector';$script:DeployUI.PairIntake.Stage='Completed'
  $script:DeployUI.PairCompletion=[pscustomobject]@{DeploymentCompleteness=$case[0];MissingProtocols=$(if($case[0] -eq 'Complete'){@()}else{@('Tcp')});AttentionRequired=($case[0] -eq 'NeedsRecovery')}
  ShowProductPairing
  AssertUI ($script:Controls.PairCompletionSummary.Text -like ('*'+$case[1]+'*') -and @(Requests).Count -eq 0) ('013 pairing '+$case[0]+' reports configuration completeness without management operations')
 }
 $captured=@($script:AllSelfTestRequests.ToArray()|Select-Object -Skip $beforeRequests)
 $allowed=@('DeploymentProceed','DeploymentCreate','DeploymentDiscover','DeploymentSessionFixture','ConnectionDefaultPreview','ConnectionSwitchPreview','ConnectionSwitchCommit','LinePreference','LineProfiles','LineRecovery','AutoTransportContext','Overview','Nodes','Providers','Agents')
 AssertUI (@($captured|Where-Object {$_.Request.Action -notin $allowed -or $_.Request.ContainsKey('SessionAction')}).Count -eq 0) '013 captured requests contain no production server action, direct session change or configuration rewrite'
 AssertUI (-not (Test-Path -LiteralPath $script:JobRoot) -and -not $script:Timer.IsEnabled -and (Get-Command Start-Process).CommandType -eq 'Function') '013 isolated harness forbids process launch and creates no Worker job directory'
 $summary=[ordered]@{Passed=$true;Suite='0.13.0';Assertions=($script:Assertions.Count-$beforeAssertions);Checks=@($script:Assertions.ToArray()|Select-Object -Skip $beforeAssertions);CapturedRequests=$captured.Count;RealNetworkChanged=$false;WorkerLaunched=$false;WpfRendered=$true;FixtureRoot=$script:Root;PowerShellVersion=[string]$PSVersionTable.PSVersion}
 [IO.File]::WriteAllText((Join-Path $qa 'ui-013-result.json'),($summary|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($true)))
 [IO.File]::WriteAllText((Join-Path $qa 'worker-013-requests.json'),($captured|ConvertTo-Json -Depth 10),(New-Object Text.UTF8Encoding($true)))
 Fixture0120
}
. (Join-Path $PSScriptRoot 'Test-0120UI.ps1')
