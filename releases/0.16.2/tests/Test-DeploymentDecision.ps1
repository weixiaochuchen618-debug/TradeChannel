#requires -Version 5.1
param([string]$SourceDirectory=(Join-Path $PSScriptRoot '..'))
$ErrorActionPreference='Stop'
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('tc-decision-0142-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($testRoot)
$checks=New-Object 'Collections.Generic.List[string]'
function AssertDecision {param([bool]$Condition,[string]$Name) if(-not $Condition){throw ('Decision regression failed: '+$Name)};$checks.Add($Name)}
function Start-Process {throw 'Decision tests forbid external processes.'}
function Stop-Process {throw 'Decision tests forbid stopping processes.'}
function NewDecisionFixture {
 $profiles=@();$bindings=@()
 foreach($id in @('Udp','Tcp')){
  $hash=if($id -eq 'Udp'){'A'*64}else{'B'*64};$manifest=if($id -eq 'Udp'){'C'*64}else{'D'*64}
  $validation=[pscustomobject]@{Status='Passed';Code='CandidateReachabilityVerified';Origin='Candidate';ProfileId=$id;CandidateSHA256=$hash;ManifestSHA256=$manifest;ProfileRevision=2;ForwardingPassed=$true;EligibleForAutomaticSelection=$true;CleanupComplete=$true;EvidenceId=('fixture-'+$id);NetworkFingerprint=('F'*64);ValidatedAt=[DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o');ExpiresAt=[DateTimeOffset]::UtcNow.AddMinutes(25).ToString('o');Result=$null}
  $profiles+=,[pscustomobject]@{Id=$id;PreparationState='SyntaxValidated';CandidateSHA256=$hash;ManifestSHA256=$manifest;Revision=2;Validation=$validation}
  $bindings+=,[pscustomobject]@{ProfileId=$id;BindingState='Prepared';ReasonCode='BindingPrepared';ProfileRevision=2;CandidateSHA256=$hash;ManifestSHA256=$manifest;BindingDigest=('E'*64);NextAction='Probe';Interfaces=@()}
 }
 $r=[pscustomobject]@{Status='Recommended';Source='PolicyDefault';RecommendedProfileId='Udp';PreferredProfileId='Udp';CandidateSHA256=('A'*64);LineId='fixture-line';ExpiresAtUtc=[DateTimeOffset]::UtcNow.AddMinutes(25).ToString('o');Reason='fixture'}
 $line=[pscustomobject]@{LineId='fixture-line';Profiles=$profiles;Recommendation=$r;PreferenceSource='PolicyDefault';PreferredProfileId='Udp'}
 $run=[pscustomobject]@{CandidateNodeId='fixture-line';Stage='ReadyInactive';Status='Completed';DeploymentCompleteness='Complete';MissingProtocols=@();Profiles=$profiles;ValidationProfiles=[pscustomobject]@{Udp=$profiles[0].Validation;Tcp=$profiles[1].Validation};Recommendation=$r;PreferenceSource='PolicyDefault';PreferredProfileId='Udp';ProbePreparation=[pscustomobject]@{State='Ready';Code='BindingsPrepared';Results=$bindings};ProfileProbeState='Completed';RecoveryRequired=$false;PartialUseAccepted=$false;LastError=$null}
 [pscustomobject]@{Run=$run;Line=$line}
}
function DecisionOf {param($Fixture) Get-TCDeploymentDecision -Run $Fixture.Run -Line $Fixture.Line}
function SetRealDecisionRecommendation {param($Fixture,[string]$Mode='Auto')
 $r=Get-TCProtocolRecommendation -Profiles $Fixture.Line.Profiles -NetworkContext ([pscustomobject]@{Status='Available';Fingerprint=('F'*64)}) -LineId $Fixture.Line.LineId -RequestedMode $Mode
 $Fixture.Line.Recommendation=$r;$Fixture.Run.Recommendation=$r
 $Fixture.Line.PreferenceSource=$r.Source;$Fixture.Run.PreferenceSource=$r.Source
 $Fixture.Line.PreferredProfileId=$r.PreferredProfileId;$Fixture.Run.PreferredProfileId=$r.PreferredProfileId
}
function AssertContract {param($Decision,[string]$Name)
 AssertDecision (($Decision.PSObject.Properties.Name -join ',') -eq 'Code,Title,Message,PrimaryAction,PrimaryLabel,SecondaryActions,CanManualTry,Blocked,ProfileId') ($Name+' exact contract')
 AssertDecision ($Decision.PrimaryAction -in @('Probe','ChooseNetwork','Diagnostics','CompleteRemaining','Recover','CheckActive','Save','ConnectRecommended')) ($Name+' supported action')
 AssertDecision ($Decision.CanManualTry -is [bool] -and $Decision.Blocked -is [bool] -and $Decision.SecondaryActions -is [array]) ($Name+' stable value types')
 foreach($action in $Decision.SecondaryActions){AssertDecision (($action.PSObject.Properties.Name -join ',') -eq 'Action,Label') ($Name+' secondary contract')}
}
try{
 $module=Import-Module (Join-Path $SourceDirectory 'DeploymentDecision.psm1') -Force -PassThru -DisableNameChecking
 AssertDecision (($module.ExportedFunctions.Keys -join ',') -eq 'Get-TCDeploymentDecision') 'only the pure decision entry is exported'
 $f=NewDecisionFixture;$before=$f|ConvertTo-Json -Depth 30 -Compress;$d=DecisionOf $f
 AssertContract $d 'dual qualified'
 AssertDecision ($d.Code -eq 'RecommendationReady' -and $d.PrimaryAction -eq 'Save' -and $d.ProfileId -eq 'Udp' -and $d.Message -like '*默认策略*') 'dual qualified uses saved recommendation without declaring a speed winner'
 AssertDecision (($f|ConvertTo-Json -Depth 30 -Compress) -ceq $before) 'decision does not mutate supplied records'
 # Use the production recommendation producer, with an explicit isolated context.
 $selectionModule=Import-Module (Join-Path $SourceDirectory 'ProtocolSelection.psm1') -Force -PassThru -DisableNameChecking
 & $selectionModule {$script:NetworkContextReader={throw 'Decision contract tests forbid live network lookup.'}}
 $f=NewDecisionFixture;SetRealDecisionRecommendation $f;$d=DecisionOf $f
 AssertDecision ($f.Line.Recommendation.Status -eq 'Recommended' -and $f.Line.Recommendation.SelectionData.Count -eq 2 -and $d.Code -eq 'RecommendationReady' -and $d.ProfileId -eq 'Udp') 'real Get-TCProtocolRecommendation policy output passes the decision contract'
 $f=NewDecisionFixture;$f.Line.Profiles[0].Validation.Status='Failed';$f.Line.Profiles[0].Validation.Code='ProbeTimeout';$f.Line.Profiles[0].Validation.ForwardingPassed=$false;$f.Line.Profiles[0].Validation.EligibleForAutomaticSelection=$false;SetRealDecisionRecommendation $f;$d=DecisionOf $f
 AssertDecision ($f.Line.Recommendation.Source -eq 'Reachability' -and $f.Line.Recommendation.RecommendedProfileId -eq 'Tcp' -and $d.Code -eq 'RecommendationReady' -and $d.ProfileId -eq 'Tcp') 'real Get-TCProtocolRecommendation TCP-only output passes the decision contract'
 $aggregate=& $selectionModule {param($profiles) PSelDigest @($profiles|Sort-Object Id|ForEach-Object {[pscustomobject]@{ProfileId=$_.Id;CandidateSHA256=$_.CandidateSHA256}})} $f.Line.Profiles
 AssertDecision ($aggregate -ne $f.Line.Profiles[1].CandidateSHA256) 'group digest differs from the selected TCP configuration hash'
 $f.Line.Recommendation.CandidateSHA256=$aggregate;$before=$f|ConvertTo-Json -Depth 30 -Compress;$d=DecisionOf $f
 AssertDecision ($d.Code -eq 'RecommendationReady' -and $d.ProfileId -eq 'Tcp') 'group digest cannot be mistaken for a selected-profile hash when SelectionData is current'
 AssertDecision (($f|ConvertTo-Json -Depth 30 -Compress) -ceq $before) 'group-digest decision never rewrites recommendation evidence'
 foreach($change in @('SelectedHash','OtherHash','DuplicateProfile','MissingSelected','EmptySelection','NullSelection','EvidenceId','Revision','CurrentOtherHash')){
  $f=NewDecisionFixture;SetRealDecisionRecommendation $f
  $selectedRow=@($f.Line.Recommendation.SelectionData|Where-Object ProfileId -eq $f.Line.Recommendation.RecommendedProfileId)[0]
  $otherRow=@($f.Line.Recommendation.SelectionData|Where-Object ProfileId -ne $f.Line.Recommendation.RecommendedProfileId)[0]
  switch($change){
   'SelectedHash'{$selectedRow.CandidateSHA256='9'*64}
   'OtherHash'{$otherRow.CandidateSHA256='9'*64}
   'DuplicateProfile'{$otherRow.ProfileId=$selectedRow.ProfileId}
   'MissingSelected'{$f.Line.Recommendation.SelectionData=@($otherRow)}
   'EmptySelection'{$f.Line.Recommendation.SelectionData=@()}
   'NullSelection'{$f.Line.Recommendation.SelectionData=$null}
   'EvidenceId'{$selectedRow.EvidenceId='another-evidence'}
   'Revision'{$selectedRow|Add-Member NoteProperty ProfileRevision 3}
   'CurrentOtherHash'{@($f.Line.Profiles|Where-Object Id -eq $otherRow.ProfileId)[0].CandidateSHA256='9'*64}
  }
  $d=DecisionOf $f;AssertDecision ($d.Code -ne 'RecommendationReady' -and @($d.SecondaryActions|Where-Object Action -eq 'ConnectRecommended').Count -eq 0) ('real selection '+$change+' invalidates the recommendation')
 }
 $f=NewDecisionFixture;SetRealDecisionRecommendation $f 'Tcp';$d=DecisionOf $f
 AssertDecision ($d.Code -eq 'UserChoice' -and $d.ProfileId -eq 'Tcp' -and $null -eq $f.Line.Recommendation.RecommendedProfileId) 'real producer manual output remains a user choice rather than automatic selection'
 $f=NewDecisionFixture;$f.Line.Profiles[0].Validation.Status='Failed';$f.Line.Profiles[0].Validation.Code='ProbeTimeout';$f.Line.Profiles[0].Validation.ForwardingPassed=$false;$f.Line.Profiles[0].Validation.EligibleForAutomaticSelection=$false
 $f.Line.Recommendation.RecommendedProfileId='Tcp';$f.Line.Recommendation.PreferredProfileId='Tcp';$f.Line.Recommendation.CandidateSHA256='B'*64;$f.Line.Recommendation.Source='Reachability';$d=DecisionOf $f
 AssertDecision ($d.Code -eq 'RecommendationReady' -and $d.ProfileId -eq 'Tcp' -and $d.Title -like '*推荐 TCP*') 'one UDP timeout and qualified TCP recommends TCP'
 $f=NewDecisionFixture;foreach($result in $f.Run.ProbePreparation.Results){$result.BindingState='Reused';$result|Add-Member NoteProperty Prepared $false};$d=DecisionOf $f
 AssertDecision ($d.Code -eq 'RecommendationReady') 'Prepared false with Reused bindings remains ready'
 $f.Run.ProbePreparation.State='Partial';$f.Run.ProbePreparation.Results[1].BindingState='Unsupported';$f.Run.ProbePreparation.Results[1].ReasonCode='IPv6NotSupported';$d=DecisionOf $f
 AssertDecision ($d.ProfileId -eq 'Udp' -and $d.Code -eq 'RecommendationReady') 'a supported qualified profile can be recommended independently'
 $f.Run.ProbePreparation.Results[0].BindingState='Unsupported';$d=DecisionOf $f
 AssertDecision ($d.Code -eq 'DetectionLimited' -and $null -eq $d.ProfileId -and @($d.SecondaryActions|Where-Object Action -eq 'ConnectRecommended').Count -eq 0) 'top Ready never promotes an Unsupported recommended binding'
 $f=NewDecisionFixture;$f.Run.ProbePreparation.Results=@();$d=DecisionOf $f
 AssertDecision ($d.Code -ne 'RecommendationReady') 'top preparation state cannot replace per-profile binding results'
 foreach($change in @('Expired','HashChanged','ManifestChanged','RevisionChanged','BindingHashChanged','BindingRevisionChanged','Runtime','NoEligibility','NoForwarding','WrongProfile','WrongLine')){
  $f=NewDecisionFixture;$v=$f.Line.Profiles[0].Validation
  switch($change){
   'Expired'{$v.ExpiresAt=[DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o')}
   'HashChanged'{$f.Line.Profiles[0].CandidateSHA256='9'*64}
   'ManifestChanged'{$f.Line.Profiles[0].ManifestSHA256='9'*64}
   'RevisionChanged'{$f.Line.Profiles[0].Revision=3}
   'BindingHashChanged'{$f.Run.ProbePreparation.Results[0].CandidateSHA256='9'*64}
   'BindingRevisionChanged'{$f.Run.ProbePreparation.Results[0].ProfileRevision=3}
   'Runtime'{$v.Origin='Runtime'} 'NoEligibility'{$v.EligibleForAutomaticSelection=$false} 'NoForwarding'{$v.ForwardingPassed=$false}
   'WrongProfile'{$v.ProfileId='Tcp'} 'WrongLine'{$f.Line.Recommendation.LineId='another-line'}
  }
  $d=DecisionOf $f;AssertDecision ($d.Code -ne 'RecommendationReady' -and @($d.SecondaryActions|Where-Object Action -eq 'ConnectRecommended').Count -eq 0) ($change+' never exposes an automatic connection')
 }
 foreach($case in @(@('NeedsRecovery','RecoveryRequired'),@('NeedsRecovery','ProbeRecoveryRequired'),@('NeedsRecovery','CleanupFalse'),@('NeedsRecovery','NestedCleanupFalse'),@('NeedsRecovery','ComparisonCleanupFalse'),@('NeedsRecovery','OutcomeUnknown'),@('NeedsRecovery','ProbeIdentityUnknown'),@('ActiveIdentity','ActiveIdentityInUse'),@('ActiveIdentity','IdentityInUse'))){
  $f=NewDecisionFixture
  switch($case[1]){
   'RecoveryRequired'{$f.Run.RecoveryRequired=$true}
   'ProbeRecoveryRequired'{$f.Run|Add-Member NoteProperty ProbeRecoveryRequired $true}
   'CleanupFalse'{$f.Line.Profiles[1].Validation.CleanupComplete=$false}
   'NestedCleanupFalse'{$f.Line.Profiles[1].Validation.Result=[pscustomobject]@{CleanupComplete=$false}}
   'ComparisonCleanupFalse'{$f.Line.Profiles[1].Validation.Result=[pscustomobject]@{Comparison=[pscustomobject]@{CleanupComplete=$false}}}
   'OutcomeUnknown'{$f.Run.Status='OutcomeUnknown'}
   default{$f.Run.ProbePreparation.Results[1].BindingState='Blocked';$f.Run.ProbePreparation.Results[1].ReasonCode=$case[1]}
  }
  $d=DecisionOf $f;AssertContract $d $case[1]
  AssertDecision ($d.Code -eq $case[0] -and $d.Blocked -and -not $d.CanManualTry -and $d.PrimaryAction -in @('Recover','CheckActive')) ($case[1]+' overrides an otherwise qualified recommendation')
 }
 foreach($stage in @('PreparingProbePath','CheckingProfiles')){
  $f=NewDecisionFixture;$f.Run.Stage=$stage;$d=DecisionOf $f
  AssertDecision ($d.Code -eq $stage -and $d.Blocked -and -not $d.CanManualTry -and $d.PrimaryAction -ne 'Probe') ($stage+' stops duplicate probes and manual trials')
 }
 $f=NewDecisionFixture;$f.Run.ProbePreparation.State='Preparing';$d=DecisionOf $f
 AssertDecision ($d.Code -eq 'PreparingProbePath') 'preparation state drives progress even while the stage is updating'
 foreach($reason in @('StoredBindingMissing','BindingExpired','NetworkChanged','ConfigurationChanged','EvidenceExpired','EngineChanged')){
  $f=NewDecisionFixture;$f.Line.Recommendation.Status='Inconclusive';$f.Run.ProbePreparation.Results[0].ReasonCode=$reason;$d=DecisionOf $f
  AssertDecision ($d.PrimaryAction -eq 'Probe' -and $d.PrimaryLabel -like '*自动准备*' -and $d.Title -like '*已备齐*') ($reason+' repairs only the local detection path')
 }
 $f=NewDecisionFixture;$f.Line.Recommendation.Status='Inconclusive';$f.Run.ProbePreparation.State='NeedsNetworkSelection';$f.Run.ProbePreparation.Results[0].BindingState='NeedsNetworkSelection';$d=DecisionOf $f
 AssertDecision ($d.PrimaryAction -eq 'ChooseNetwork' -and $d.Message -like '*当前连接保持*') 'multiple interfaces have an explicit local selection action'
 foreach($reason in @('ForwardingPassedPhysicalPathUnverified','NoSupportedPhysicalInterface','IPv6NotSupported','UdpEtwUnavailable')){
  $f=NewDecisionFixture;$f.Line.Recommendation.Status='Inconclusive';$f.Line.Profiles[0].Validation.Status='Inconclusive';$f.Line.Profiles[0].Validation.Code=$reason;$d=DecisionOf $f
  AssertDecision ($d.PrimaryAction -eq 'Diagnostics' -and $d.CanManualTry -and $null -eq $d.ProfileId) ($reason+' gives limits and a controlled manual choice without selecting TCP')
  if($reason -eq 'IPv6NotSupported'){AssertDecision ($d.Message -like '*IPv6*暂不支持*') 'IPv6 capability limit is explained explicitly'}
  if($reason -eq 'NoSupportedPhysicalInterface'){AssertDecision ($d.Message -like '*未找到*受支持网络*') 'missing supported interface is explained explicitly'}
 }
 $f=NewDecisionFixture;$f.Line.Profiles[1].PreparationState='OutcomeUnknown';$d=DecisionOf $f
 AssertDecision ($d.PrimaryAction -eq 'Recover' -and $d.Blocked -and -not $d.CanManualTry) 'unknown profile preparation cannot be treated as ordinary missing configuration'
 $f=NewDecisionFixture;$f.Line.Recommendation.Status='Unavailable';foreach($p in $f.Line.Profiles){$p.Validation.Status='Failed';$p.Validation.Code='ForwardingFailed'};$d=DecisionOf $f
 AssertDecision ($d.Code -eq 'NetworkCheckFailed' -and $d.PrimaryAction -eq 'Diagnostics' -and $d.Title -like '*已备齐*' -and $d.CanManualTry) 'both failed network checks preserve configuration completeness'
 $f=NewDecisionFixture;$f.Line.Recommendation.Status='Inconclusive';$f.Run.LastError=[pscustomobject]@{Code='InboundCheckFailed';Message='DO-NOT-PRINT'};$d=DecisionOf $f
 AssertDecision ($d.Code -eq 'EntryCheckUnverified' -and $d.Message -like '*不能确定*' -and -not (($d|ConvertTo-Json).Contains('DO-NOT-PRINT'))) 'unverified entrance shows cloud rule uncertainty without copying raw errors'
 $f=NewDecisionFixture;$f.Run.DeploymentCompleteness='Partial';$f.Run.MissingProtocols=@('Tcp');$f.Line.Profiles=$f.Line.Profiles|Where-Object Id -eq 'Udp';$f.Run.Profiles=$f.Line.Profiles;$d=DecisionOf $f
 AssertDecision ($d.PrimaryAction -eq 'CompleteRemaining' -and -not $d.CanManualTry -and $d.Code -eq 'PartialDeployment') 'partial configuration requires an explicit prepared-use acceptance'
 $f.Run.PartialUseAccepted=$true;$d=DecisionOf $f
 AssertDecision ($d.Code -eq 'PartialDeployment' -and $d.CanManualTry -and @($d.SecondaryActions|Where-Object Action -eq 'ConnectRecommended').Count -eq 1) 'accepted partial remains partial and exposes a separate connection preview'
 $f=NewDecisionFixture;$f.Line.PreferenceSource='UserChoice';$f.Line.PreferredProfileId='Tcp';$f.Line.Recommendation.Status='UserChoice';$f.Line.Recommendation.Source='UserChoice';$f.Line.Recommendation.RecommendedProfileId=$null;$d=DecisionOf $f
 AssertDecision ($d.Code -eq 'UserChoice' -and $d.ProfileId -eq 'Tcp' -and $d.Title -like '*你选择 TCP*' -and $null -eq $f.Line.Recommendation.RecommendedProfileId) 'manual preference never becomes an automatic recommendation'
 $f=NewDecisionFixture;$f.Run.Profiles=@();$f.Run|Add-Member NoteProperty ProtocolPreparation ([pscustomobject]@{Udp=[pscustomobject]@{LocalPreparation='SyntaxValidated'};Tcp=[pscustomobject]@{LocalPreparation='Ready'}})
 $d=Get-TCDeploymentDecision -Run $f.Run -Line $null
 AssertDecision ($d.Code -eq 'RecommendationReady') 'legacy Flow ValidationProfiles and ProtocolPreparation shapes remain readable'
 $f=NewDecisionFixture;$f.Line.Profiles[0].Validation.Result=[pscustomobject]@{Samples=@([pscustomobject]@{Required=$false;HttpStatus=403;Status='UserVerificationRequired';Code='HttpForbidden'})};$d=DecisionOf $f
 AssertDecision ($d.Code -eq 'RecommendationReady') 'optional application HTTP 403 cannot veto a tunnel recommendation'
 $legacy=[pscustomobject]@{LineId='legacy';Profiles=@([pscustomobject]@{Id='Udp';PreparationState='Ready';Validation=$null});PreferredProfileId='Udp';PreferenceSource='ConfiguredDefault'};$d=Get-TCDeploymentDecision -Line $legacy
 AssertDecision ($d.CanManualTry -and -not $d.Blocked) 'saved legacy UDP remains manually usable without pretending a new dual deployment'
 $f=NewDecisionFixture;$hashtable=$f.Run|ConvertTo-Json -Depth 25|ConvertFrom-Json;$dictionary=@{};foreach($p in $hashtable.PSObject.Properties){$dictionary[$p.Name]=$p.Value};$d=Get-TCDeploymentDecision -Run $dictionary -Line $f.Line
 AssertDecision ($d.Code -eq 'RecommendationReady') 'dictionary records use the same contract'
 foreach($stage in @('Inspect','Apply','Authorize','TcpApply')){
  $f=NewDecisionFixture;$f.Run.Stage=$stage;$f.Run.Status='Running';$d=DecisionOf $f
  AssertDecision ($d.Code -eq 'ServerPreparationRunning' -and $d.PrimaryAction -eq 'Diagnostics' -and -not $d.CanManualTry) ($stage+' exposes progress without resubmission')
 }
 $context=@{SourceKind='DeploymentRun';IdentityState='Active';Classification='Continue';CanResume=$true;IsPrepared=$false;AttentionRequired=$false;ProtectionReasons=@();Diagnostics=@()}
 $f=NewDecisionFixture;$f.Run.Stage='PlanReady';$f.Run|Add-Member NoteProperty Review @{ChangeDigest='fixture'}
 $d=Get-TCDeploymentDecision -Run $f.Run -Line $f.Line -Context $context
 AssertDecision ($d.Group -eq 'Continue' -and $d.EntryAction -eq 'OpenRun' -and $d.EntryLabel -eq '查看准备计划') 'center opens the review before a preparation approval'
 foreach($identity in @('Missing','Mismatch','Ambiguous','Unverified','Archived')){
  $context.IdentityState=$identity;$d=Get-TCDeploymentDecision -Run $f.Run -Line $f.Line -Context $context
  AssertDecision ($d.EntryAction -eq 'ViewRecord' -and $d.Group -eq $(if($identity -eq 'Archived'){'History'}else{'Attention'})) ($identity+' never exposes a resume action')
 }
 $context.IdentityState='Active';$context.SourceKind='LegacyLinuxJob';$context.CanResume=$false;$f.Run.Stage='Backend';$d=Get-TCDeploymentDecision -Run $f.Run -Context $context
 AssertDecision ($d.EntryAction -eq 'ViewRecord' -and $d.Group -eq 'Attention') 'blocked legacy record has a real read-only entry'
 $context.CanResume=$true;$d=Get-TCDeploymentDecision -Run $f.Run -Context $context
 AssertDecision ($d.EntryAction -eq 'OpenLegacy') 'verified eligible legacy checkpoint retains its own entry'
 $context.SourceKind='DeploymentRun';$f.Run.Stage='FutureUnknownStage';$d=Get-TCDeploymentDecision -Run $f.Run -Context $context
 AssertDecision ($d.EntryAction -eq 'ViewRecord' -and $d.Code -eq 'UnknownDeploymentStage') 'unknown stage never falls back to resume'
 $context.Classification='Draft';$f.Run.Stage='PrepareAccess';$f.Run.Status='WaitingUser';$d=Get-TCDeploymentDecision -Run $f.Run -Context $context
 AssertDecision ($d.Group -eq 'Drafts' -and $d.EntryAction -eq 'EditDraft') 'input-only draft has an edit entry'
 $f.Run|Add-Member NoteProperty AccessIssue @{Kind='Credentials';Code='AuthenticationFailed';Password='DO-NOT-EXPORT'};$d=Get-TCDeploymentDecision -Run $f.Run -Context $context
 AssertDecision ($d.Group -eq 'Attention' -and $d.EntryAction -eq 'OpenRun' -and ($d|ConvertTo-Json) -notmatch 'DO-NOT-EXPORT') 'credential problem gets the same explanation without raw input'
 $context.Discarded=$true;$context.DiscardedEffective=$true;$d=Get-TCDeploymentDecision -Run $f.Run -Context $context
 AssertDecision ($d.Group -eq 'History' -and $d.EntryAction -eq 'ViewRecord') 'discarded safe draft remains viewable history'
 $context.DiscardedEffective=$false;$d=Get-TCDeploymentDecision -Run $f.Run -Context $context
 AssertDecision ($d.Group -eq 'Attention' -and $d.EntryAction -eq 'ViewRecord') 'changed discarded record resurfaces without resumption'
 $d=Get-TCDeploymentDecision -Context @{SourceKind='ServerRecord';IdentityState='Active';ServerState='NeedsDeployment'}
 AssertDecision ($d.Group -eq 'Continue' -and $d.Code -eq 'VerifiedTargetUndeployed' -and $d.EntryAction -eq 'BeginDeployment') 'verified new server is explicitly not yet deployed'
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceDirectory 'DeploymentDecision.psm1'),[ref]$tokens,[ref]$errors)
 AssertDecision ($errors.Count -eq 0) 'decision module parses in the running PowerShell version'
 $forbidden=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -match '^(Import-Module|Get-Content|Set-Content|Get-ChildItem|Start-Process|Stop-Process|Invoke-WebRequest|Get-Net.*|Set-Net.*|Remove-Item|StartJob)$'},$true))
 AssertDecision ($forbidden.Count -eq 0) 'decision module has no IO network or worker command dependency'
 [pscustomobject]@{Passed=$true;Suite='DeploymentDecision-0.14.2';Checks=$checks.Count;WorkerLaunched=$false;NetworkChanged=$false;PowerShellVersion=[string]$PSVersionTable.PSVersion}|ConvertTo-Json
}finally{
 $absolute=[IO.Path]::GetFullPath($testRoot);$temporary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if($absolute.StartsWith($temporary,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($absolute).StartsWith('tc-decision-0142-')){Remove-Item -LiteralPath $absolute -Recurse -Force}
}
