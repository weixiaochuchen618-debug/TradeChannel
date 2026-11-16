#requires -Version 5.1
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'DeploymentStore.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'ServerRegistry.psm1') -DisableNameChecking

# Preparation permission is not SSH trust and never contains a credential. Keep
# it beside its run so physical cleanup includes it. Use the existing run lock,
# not a new unknown lock that cleanup would have to preserve indefinitely.
function Get-TCPreparationConsentPath {param([string]$Root,[string]$RunId)
 $base=Assert-TCDPath $Root;$id=Assert-TCDId $RunId
 Assert-TCDPath (Join-Path $base ('deployments\runs\'+$id+'\preparation-consent.json'))
}
function Get-TCPreparationSettings {param($Run)
 [ordered]@{Intent=[string](Get-TCDField $Run Intent '');Transport=[string](Get-TCDField $Run Transport '');TcpPort=[int](Get-TCDField $Run TcpPort 0);ServerName=[string](Get-TCDField $Run ServerName '');VpnPort=[int](Get-TCDField $Run VpnPort 0);TemplateNodeId=[string](Get-TCDField $Run TemplateNodeId '');ExistingDevice=[bool](Get-TCDField $Run ExistingDevice $false)}
}
function Get-TCPreparationLifecycle {param([string]$Root,[string]$RunId,[string]$ServerRecordId)
 $ids=@(('DeploymentRun:'+$RunId),('ServerRecord:'+$ServerRecordId))
 $draft=Read-TCDJson (Join-Path $Root 'deployments\draft-dispositions.json') -AllowMissing
 $entries=@(Get-TCDField $draft Entries @()|Where-Object {[string](Get-TCDField $_ Id '') -cin $ids}|Sort-Object Id)
 $cleanup=@();$directory=Join-Path $Root 'local-cleanup'
 if([IO.Directory]::Exists($directory)){
  $journals=@(Get-ChildItem -LiteralPath $directory -Directory -ErrorAction Stop)
  if($journals.Count -gt 2000){throw '[TC:PreparationHistoryUnavailable] 本机清理记录过多，请先整理操作记录。'}
  foreach($item in $journals){
   $journal=Read-TCDJson (Join-Path $item.FullName 'journal.json') -AllowMissing
   $result=Get-TCDField $journal Result
   $selected=@(Get-TCDField $result SelectedIds @())+@(Get-TCDField $result DeletedIds @())
   if(@($selected|Where-Object {$_ -cin $ids}).Count){$cleanup+=,[ordered]@{Id=[string](Get-TCDField $journal Id '');TokenDigest=[string](Get-TCDField $journal TokenDigest '')}}
  }
 }
 # Discard -> restore and cleanup -> rollback both change this binding, even
 # when nobody opened the consent while the task was discarded/quarantined.
 Get-TCDDigest @{Drafts=$entries;Cleanup=@($cleanup|Sort-Object Id)}
}
function Read-TCPreparationContext {param([string]$Root,[string]$RunId)
 Assert-TCLocalCleanupReady $Root
 $run=Read-TCDJson (Join-Path (Split-Path (Get-TCPreparationConsentPath $Root $RunId) -Parent) 'state.json')
 if((Get-TCDField $run SchemaVersion 0) -ne 1 -or [string](Get-TCDField $run RunId '') -cne $RunId){throw '[TC:PreparationRunMismatch] 原任务记录不匹配。'}
 if([string](Get-TCDField $run Status '') -in @('Cancelled','Complete') -or (Get-TCDField $run PreparationConsentRevokedAtUtc)){throw '[TC:PreparationTaskEnded] 本次准备已结束，原批准已失效。'}
 $server=Assert-TCServerTaskActive -Root $Root -RunId $RunId
 if(@(Get-TCDField $server IdentityTransitionTasks @()|Where-Object {[string](Get-TCDField $_ Kind '') -ceq 'Deployment' -and [string](Get-TCDField $_ Id '') -ceq $RunId}).Count){throw '[TC:PreparationIdentityChanged] 服务器身份变化后不能继承原批准。'}
 [pscustomobject]@{Run=$run;Server=$server;Lifecycle=(Get-TCPreparationLifecycle $Root $RunId $run.ServerRecordId)}
}
function Test-TCDeploymentPreparationConsent {
 [CmdletBinding()]param($Consent,$Run,$Server,[string]$Lifecycle='', [switch]$ForReview)
 try{
  if(-not $Consent -or (Get-TCDField $Consent Kind '') -cne 'TradeChannel.PreparationConsent' -or (Get-TCDField $Consent SchemaVersion 0) -ne 1 -or (Get-TCDField $Consent State '') -notin @('PendingIdentity','Active') -or (Get-TCDField $Consent Scope '') -cne 'PrepareUdpTcpAndLocalDevice'){return $false}
  $now=[DateTimeOffset]::UtcNow;$submitted=[DateTimeOffset]::MinValue;$expires=[DateTimeOffset]::MinValue
  if(-not [DateTimeOffset]::TryParse([string](Get-TCDField $Consent SubmittedAtUtc ''),[ref]$submitted) -or -not [DateTimeOffset]::TryParse([string](Get-TCDField $Consent ExpiresAtUtc ''),[ref]$expires) -or $submitted -gt $now.AddMinutes(1) -or $expires -le $now -or $expires -gt $submitted.AddHours(24) -or $expires -le $submitted){return $false}
  foreach($field in @('RunId','ServerRecordId')){if(-not (Get-TCDField $Consent $field '') -or [string](Get-TCDField $Consent $field '') -cne [string](Get-TCDField $Run $field '')){return $false}}
  if([string](Get-TCDField $Consent RunCreatedAtUtc '') -cne [string](Get-TCDField $Run CreatedAtUtc '') -or [string](Get-TCDField $Run Status '') -in @('Cancelled','Complete') -or (Get-TCDField $Run PreparationConsentRevokedAtUtc) -or (Get-TCDField $Run RecoveryRequired $false) -or (Get-TCDField $Run ProbeRecoveryRequired $false) -or (Get-TCDField $Run UnresolvedTcpMutation) -or [string](Get-TCDField $Run Status '') -in @('NeedsRecovery','OutcomeUnknown')){return $false}
  if($Lifecycle -and [string](Get-TCDField $Consent LifecycleDigest '') -cne $Lifecycle){return $false}
  $settings=Get-TCPreparationSettings $Run
  if((Get-TCDDigest $settings) -cne [string](Get-TCDField $Consent SettingsDigest '')){
   # The flow may choose only a fallback already included in the exact review
   # that consumed this consent. An arbitrary edit cannot enlarge that scope.
   $choices=Get-TCDField $Run ApprovedTransportChoices;$original=Get-TCDField $Consent Settings
   $consumed=@(Get-TCDField $Consent ConsumedReviews @()|Where-Object {[string](Get-TCDField $_ Digest '') -ceq [string](Get-TCDField $Run ApprovedChangeDigest '')})
   if($consumed.Count -ne 1 -or -not $choices -or [string](Get-TCDField $consumed[0] ChoicesDigest '') -cne (Get-TCDDigest $choices) -or [int]$settings.TcpPort -notin @(Get-TCDField $choices CandidatePorts @()) -or [string]$settings.ServerName -cnotin @(Get-TCDField $choices CandidateServerNames @())){return $false}
   $settings.TcpPort=[int](Get-TCDField $original TcpPort 0);$settings.ServerName=[string](Get-TCDField $original ServerName '')
   if((Get-TCDDigest $settings) -cne [string]$Consent.SettingsDigest){return $false}
  }
  $target=Get-TCDField $Consent Target
  if($Server){
   if([string](Get-TCDField $Server LocalRecordId '') -cne [string]$Consent.ServerRecordId -or [string](Get-TCDField $Server RecordState 'Active') -cne 'Active' -or [int](Get-TCDField $Server IdentityTransitionRevision 0) -ne [int](Get-TCDField $Consent IdentityRevision -1)){return $false}
   foreach($field in @('Host','Port','User')){if([string](Get-TCDField (Get-TCDField $Server Connection) $field '') -cne [string](Get-TCDField $target $field '')){return $false}}
   $pin=[string](Get-TCDField $Consent PinnedFingerprint '')
   if($pin -and $pin -cne [string](Get-TCDField $Server PinnedHostKey '')){return $false}
   foreach($field in @('RemoteOwnerId','NodeId','ServerPublicKey')){$value=[string](Get-TCDField (Get-TCDField $Consent ServerIdentity) $field '');if($value -and $value -cne [string](Get-TCDField $Server $field '')){return $false}}
  }
  if(-not $ForReview){return $true}
  $review=Get-TCDField $Run Review;$identity=Get-TCDField $review TargetIdentity
  if((Get-TCDField $Consent State '') -cne 'Active' -or [string](Get-TCDField $Run Stage '') -cne 'PlanReady' -or [string](Get-TCDField $Run Status '') -cne 'WaitingUser' -or (Get-TCDField $Run AccessIssue) -or (Get-TCDField $Run PausedContinuation) -or (Get-TCDField $Run PendingOperationId) -or (Get-TCDField $Run PendingPurpose)){return $false}
  if([string](Get-TCDField $review Kind '') -cnotin @('Deploy','Management','Authorize','PrepareTcp') -or (Get-TCDField $review ChangesLocalNetwork) -isnot [bool] -or [bool]$review.ChangesLocalNetwork){return $false}
  $pin=[string](Get-TCDField $Consent PinnedFingerprint '')
  if($pin -cnotmatch '^SHA256:[A-Za-z0-9+/]{43}$' -or [string](Get-TCDField $identity PinnedHostKey '') -cne $pin){return $false}
  foreach($field in @('Host','Port','User')){if([string](Get-TCDField (Get-TCDField $identity Connection) $field '') -cne [string](Get-TCDField $target $field '')){return $false}}
  if([string](Get-TCDField $review ServerRecordId '') -cne [string]$Consent.ServerRecordId){return $false}
  if($Server){foreach($field in @('RemoteOwnerId','NodeId','ServerPublicKey')){if([string](Get-TCDField $identity $field '') -cne [string](Get-TCDField $Server $field '')){return $false}}}
  $digest=[string](Get-TCDField $review ChangeDigest '');if($digest -cnotmatch '^[a-f0-9]{64}$' -or $digest -cin @(Get-TCDField $Consent ConsumedDigests @())){return $false}
  $body=@{};if($review -is [Collections.IDictionary]){foreach($key in $review.Keys){if($key -cne 'ChangeDigest'){$body[$key]=$review[$key]}}}else{foreach($p in $review.PSObject.Properties){if($p.Name -cne 'ChangeDigest'){$body[$p.Name]=$p.Value}}}
  if((Get-TCDDigest $body) -cne $digest){return $false}
  $plan=Get-TCDField $review Plan
  switch([string]$review.Kind){
   'Deploy'{if((Get-TCDDigest $plan) -cne (Get-TCDDigest (Get-TCDField $Run Plan))){return $false}}
   'Management'{if((Get-TCDDigest $plan) -cne (Get-TCDDigest (Get-TCDField $Run ManagementPlan))){return $false}}
   default{if([string](Get-TCDField $plan ClientPublicKey '') -cne [string](Get-TCDField (Get-TCDField $Run ClientRequest) ClientPublicKey '')){return $false}}
  }
  foreach($key in @('PlanExpiresAt','ExpiresAtUtc')){
   $value=[string](Get-TCDField $plan $key '');if($value){$deadline=[DateTimeOffset]::MinValue;if(-not [DateTimeOffset]::TryParse($value,[ref]$deadline) -or $deadline -le $now){return $false}}
  }
  if(@(Get-TCDField $Consent ConsumedDigests @()).Count -ge 32){return $false}
  return $true
 }catch{return $false}
}
function Write-TCPreparationConsent {param([string]$Path,$Consent)
 # Integrity detects partial/manual corruption; ACL and DPAPI bind the actual
 # permission to this Windows user. The visible envelope grants no authority.
 Add-Type -AssemblyName System.Security
 $bytes=[Text.Encoding]::UTF8.GetBytes(($Consent|ConvertTo-Json -Depth 30 -Compress))
 try{
  $entropy=[Text.Encoding]::UTF8.GetBytes('TradeChannel.PreparationConsent.v1|'+$Path.ToLowerInvariant())
  $cipher=[Security.Cryptography.ProtectedData]::Protect($bytes,$entropy,[Security.Cryptography.DataProtectionScope]::CurrentUser)
  Write-TCDJson $Path ([ordered]@{Kind='TradeChannel.PreparationConsentEnvelope';SchemaVersion=1;RunId=$Consent.RunId;State=$Consent.State;ExpiresAtUtc=$Consent.ExpiresAtUtc;Protected=[Convert]::ToBase64String($cipher)}) -Compact
 }finally{[Array]::Clear($bytes,0,$bytes.Length)}
}
function Read-TCPreparationConsent {param([string]$Path)
 $value=Read-TCDJson $Path -AllowMissing -MaxBytes 131072;if(-not $value){return $null}
 if((Get-TCDField $value Kind '') -cne 'TradeChannel.PreparationConsentEnvelope' -or (Get-TCDField $value SchemaVersion 0) -ne 1){throw '[TC:PreparationConsentInvalid] 原批准记录不可用，请重新核对计划。'}
 Add-Type -AssemblyName System.Security;$bytes=$null
 try{
  $entropy=[Text.Encoding]::UTF8.GetBytes('TradeChannel.PreparationConsent.v1|'+$Path.ToLowerInvariant())
  $bytes=[Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String([string]$value.Protected),$entropy,[Security.Cryptography.DataProtectionScope]::CurrentUser)
  $consent=[Text.Encoding]::UTF8.GetString($bytes)|ConvertFrom-Json
  if([string]$consent.RunId -cne [string]$value.RunId){throw 'BindingMismatch'}
  return $consent
 }catch{throw '[TC:PreparationConsentInvalid] 原批准记录不可用，请重新核对计划。'}finally{if($bytes){[Array]::Clear($bytes,0,$bytes.Length)}}
}
function Set-TCDeploymentPreparationConsent {
 [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][string]$RunId,[Parameter(Mandatory=$true)]$Submission)
 $path=Get-TCPreparationConsentPath $Root $RunId;$gate=$null;$lock=$null
 try{
  $gate=Open-TCDLock (Join-Path (Assert-TCDPath $Root) '.local-cleanup.lock');$context=Read-TCPreparationContext $Root $RunId
  $lock=Open-TCDLock (Join-Path (Split-Path $path -Parent) '.run.lock');$context=Read-TCPreparationContext $Root $RunId
  $run=$context.Run;$server=$context.Server
  foreach($field in @('Host','Port','User')){if([string](Get-TCDField $Submission $field '') -cne [string](Get-TCDField $server.Connection $field '')){throw '[TC:PreparationTargetChanged] 服务器目标与提交内容不一致。'}}
  foreach($field in @('TcpPort','ServerName','Transport')){if([string](Get-TCDField $Submission $field '') -cne [string](Get-TCDField $run $field '')){throw '[TC:PreparationPlanChanged] 准备参数已变化，请重新核对。'}}
  if((Get-TCDField $run RecoveryRequired $false) -or (Get-TCDField $run AccessIssue) -or [string]$run.Status -in @('Running','Dispatching','OutcomeUnknown','NeedsRecovery')){throw '[TC:PreparationNotReady] 请先处理原任务当前步骤。'}
  $previous=Read-TCPreparationConsent $path
  if($previous){
   if(Test-TCDeploymentPreparationConsent $previous $run $server $context.Lifecycle){return $previous}
   # Login/reopen never renews an expired, revoked or changed permission.
   throw '[TC:PreparationConsentExpired] 原批准已失效，请在当前计划页明确确认。'
  }
  $now=[DateTimeOffset]::UtcNow;$settings=Get-TCPreparationSettings $run
  $consent=[pscustomobject][ordered]@{Kind='TradeChannel.PreparationConsent';SchemaVersion=1;ConsentId=[guid]::NewGuid().ToString('D');Scope='PrepareUdpTcpAndLocalDevice';RunId=$RunId;RunCreatedAtUtc=[string]$run.CreatedAtUtc;ServerRecordId=[string]$run.ServerRecordId;Target=[ordered]@{Host=[string]$server.Connection.Host;Port=[int]$server.Connection.Port;User=[string]$server.Connection.User};PinnedFingerprint=[string]$server.PinnedHostKey;IdentityRevision=[int](Get-TCDField $server IdentityTransitionRevision 0);ServerIdentity=[ordered]@{RemoteOwnerId=[string]$server.RemoteOwnerId;NodeId=[string]$server.NodeId;ServerPublicKey=[string]$server.ServerPublicKey};Settings=$settings;SettingsDigest=(Get-TCDDigest $settings);LifecycleDigest=$context.Lifecycle;State=$(if($server.PinnedHostKey){'Active'}else{'PendingIdentity'});SubmittedAtUtc=$now.ToString('o');ExpiresAtUtc=$now.AddHours(24).ToString('o');ConsumedDigests=@();ConsumedReviews=@();RevokedAtUtc=$null;RevocationReason=$null}
  Write-TCPreparationConsent $path $consent;return $consent
 }finally{if($lock){$lock.Dispose()};if($gate){$gate.Dispose()}}
}
function Get-TCDeploymentPreparationConsent {
 [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][string]$RunId)
 $path=Get-TCPreparationConsentPath $Root $RunId
 if(-not [IO.File]::Exists($path)){return $null}
 $consent=Read-TCPreparationConsent $path
 if([string](Get-TCDField $consent State '') -ceq 'Revoked'){return $null}
 try{$context=Read-TCPreparationContext $Root $RunId}
 catch{if($_.Exception.Message -match '^\[TC:(PreparationTaskEnded|DataMissing|DraftDiscarded|ServerArchived|ServerTaskIdentityChanged|PreparationIdentityChanged)\]'){return $null};throw}
 if(Test-TCDeploymentPreparationConsent $consent $context.Run $context.Server $context.Lifecycle){return $consent}
 return $null
}
function Confirm-TCDeploymentPreparationIdentity {
 [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][string]$RunId,[Parameter(Mandatory=$true)]$SessionRef)
 $path=Get-TCPreparationConsentPath $Root $RunId;if(-not [IO.File]::Exists($path)){return $null}
 $gate=$null;$lock=$null
 try{
  $gate=Open-TCDLock (Join-Path (Assert-TCDPath $Root) '.local-cleanup.lock')
  $lock=Open-TCDLock (Join-Path (Split-Path $path -Parent) '.run.lock')
  $context=Read-TCPreparationContext $Root $RunId;$consent=Read-TCPreparationConsent $path
  if(-not (Test-TCDeploymentPreparationConsent $consent $context.Run $context.Server $context.Lifecycle)){return $null}
  if([string](Get-TCDField $SessionRef RunId '') -cne $RunId){throw '[TC:PreparationSessionMismatch] 登录会话不属于原任务。'}
  $attempt=Get-TCDField $context.Run AttemptSessionRef (Get-TCDField $context.Run SessionRef)
  if(-not $attempt -or [string](Get-TCDField $attempt InstanceId '') -cne [string](Get-TCDField $SessionRef InstanceId '')){throw '[TC:PreparationSessionMismatch] 登录尝试已经变化，原回调不能绑定批准。'}
  Import-Module (Join-Path $PSScriptRoot 'DeploymentTransport.psm1') -DisableNameChecking
  $identity=Get-TCDeployVerifiedHostIdentity -SessionRef $SessionRef
  if([string](Get-TCDField $identity ObservedFingerprint '') -cne [string]$context.Server.PinnedHostKey){throw '[TC:PreparationIdentityChanged] 登录身份与原服务器不一致。'}
  foreach($field in @('Host','Port','User')){if([string](Get-TCDField (Get-TCDField $identity Connection) $field '') -cne [string](Get-TCDField $consent.Target $field '')){throw '[TC:PreparationIdentityChanged] 登录目标与原批准不一致。'}}
  if($consent.PinnedFingerprint -and $consent.PinnedFingerprint -cne $identity.ObservedFingerprint){throw '[TC:PreparationIdentityChanged] 身份变化后不能继承原批准。'}
  $consent.PinnedFingerprint=[string]$identity.ObservedFingerprint;$consent.State='Active'
  Write-TCPreparationConsent $path $consent;return $consent
 }finally{if($lock){$lock.Dispose()};if($gate){$gate.Dispose()}}
}
function Use-TCDeploymentPreparationConsent {
 [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][string]$RunId,[Parameter(Mandatory=$true)][string]$ChangeDigest,[string]$ConsentId='',[string]$SessionInstanceId='')
 $path=Get-TCPreparationConsentPath $Root $RunId;if(-not [IO.File]::Exists($path)){return $null}
 $gate=$null;$lock=$null
 try{
  $gate=Open-TCDLock (Join-Path (Assert-TCDPath $Root) '.local-cleanup.lock')
  $lock=Open-TCDLock (Join-Path (Split-Path $path -Parent) '.run.lock')
  $context=Read-TCPreparationContext $Root $RunId;$consent=Read-TCPreparationConsent $path;$run=$context.Run
  if($ConsentId -and $ConsentId -cne [string](Get-TCDField $consent ConsentId '')){return $null}
  if($SessionInstanceId -and $SessionInstanceId -cne [string](Get-TCDField (Get-TCDField $run SessionRef) InstanceId '')){return $null}
  if($ChangeDigest -cne [string](Get-TCDField (Get-TCDField $run Review) ChangeDigest '') -or -not (Test-TCDeploymentPreparationConsent $consent $run $context.Server $context.Lifecycle -ForReview)){return $null}
  if([IO.File]::Exists((Join-Path (Split-Path $path -Parent) 'pause-at-checkpoint.json'))){return $null}
  $review=$run.Review;$plan=Get-TCDField $review Plan
  $consent.ConsumedDigests=@($consent.ConsumedDigests)+@($ChangeDigest)
  $consent.ConsumedReviews=@($consent.ConsumedReviews)+@([ordered]@{Digest=$ChangeDigest;Kind=[string]$review.Kind;PlanId=[string](Get-TCDField $plan PlanId '');PlanDigest=(Get-TCDDigest $plan);ChoicesDigest=(Get-TCDDigest (Get-TCDField $review OptionalTcpPreparation));ConsumedAtUtc=[DateTimeOffset]::UtcNow.ToString('o')})
  # Persist before the caller dispatches. A crash between the two cannot replay
  # a remote mutation; the original plan remains available for explicit review.
  Write-TCPreparationConsent $path $consent
  [pscustomobject]@{ConsentId=$consent.ConsentId;RunId=$RunId;ChangeDigest=$ChangeDigest;Consumed=$true;ExpiresAtUtc=$consent.ExpiresAtUtc}
 }finally{if($lock){$lock.Dispose()};if($gate){$gate.Dispose()}}
}
function Revoke-TCDeploymentPreparationConsent {
 [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][string]$RunId,[ValidateSet('Cancelled','Completed','Paused','IdentityChanged','Cleanup','Expired')][string]$Reason='Cancelled',[switch]$RunLocked)
 $path=Get-TCPreparationConsentPath $Root $RunId;if(-not [IO.File]::Exists($path)){return}
 $gate=$null;$lock=$null
 try{
  if(-not $RunLocked){$gate=Open-TCDLock (Join-Path (Assert-TCDPath $Root) '.local-cleanup.lock');$lock=Open-TCDLock (Join-Path (Split-Path $path -Parent) '.run.lock')}
  $consent=Read-TCPreparationConsent $path
  if($consent.State -ceq 'Revoked'){return}
  $consent.State='Revoked';$consent.RevokedAtUtc=[DateTimeOffset]::UtcNow.ToString('o');$consent.RevocationReason=$Reason
  Write-TCPreparationConsent $path $consent
 }finally{if($lock){$lock.Dispose()};if($gate){$gate.Dispose()}}
}
Export-ModuleMember -Function Set-TCDeploymentPreparationConsent,Get-TCDeploymentPreparationConsent,Test-TCDeploymentPreparationConsent,Confirm-TCDeploymentPreparationIdentity,Use-TCDeploymentPreparationConsent,Revoke-TCDeploymentPreparationConsent
