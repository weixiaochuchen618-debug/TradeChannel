#requires -Version 5.1
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'DeploymentStore.psm1') -DisableNameChecking

# Discard is a local lifecycle decision, independent of history visibility and
# server identity archive. Source files and approvals are not edited; a discarded
# task's temporary credential envelope is revoked and is not restored later.
function DDFail {param([string]$Code) throw ('[TC:'+$Code+'] 草稿未修改，请刷新记录后重试。')}
function DDId {
 param([string]$Id)
 if($Id -cnotmatch '^(DeploymentRun|ServerRecord):([0-9a-f-]{36})$'){DDFail DraftInvalidId}
 $kind=$matches[1];$source=Assert-TCDId $matches[2]
 if($Id -cne ($kind+':'+$source)){DDFail DraftInvalidId}
 return $Id
}
function DDReadIndex {
 param([string]$Root)
 $store=Read-TCDJson (Join-Path (Assert-TCDPath $Root) 'deployments\draft-dispositions.json') -AllowMissing
 if(-not $store){return [pscustomobject]@{SchemaVersion=1;Revision=0;Entries=@();Commits=@()}}
 if((Get-TCDField $store SchemaVersion 0) -ne 1 -or (Get-TCDField $store Revision -1) -lt 0 -or -not $store.PSObject.Properties['Entries'] -or -not $store.PSObject.Properties['Commits'] -or $store.Entries -isnot [array] -or $store.Commits -isnot [array]){DDFail DraftDispositionInvalid}
 $seen=@{}
 foreach($entry in $store.Entries){
  try{$id=DDId ([string](Get-TCDField $entry Id ''))}catch{DDFail DraftDispositionInvalid}
  if($seen.ContainsKey($id) -or (Get-TCDField $entry Discarded) -isnot [bool] -or (Get-TCDField $entry SourceKind '') -cne $id.Split(':')[0] -or (Get-TCDField $entry SourceId '') -cne $id.Split(':')[1]){DDFail DraftDispositionInvalid}
  $serverId=[string](Get-TCDField $entry ServerRecordId '')
  if($serverId){try{if((Assert-TCDId $serverId) -cne $serverId){throw 'id'}}catch{DDFail DraftDispositionInvalid}}
  $seen[$id]=$true
 }
 return $store
}
function Test-TCDraftDiscarded {
 [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][string]$Id)
 $key=DDId $Id;$store=DDReadIndex $Root
 return @($store.Entries|Where-Object {$_.Id -ceq $key -and $_.Discarded}).Count -eq 1
}
function Assert-TCDraftActive {
 [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][string]$Id)
 if(Test-TCDraftDiscarded -Root $Root -Id $Id){throw '[TC:DraftDiscarded] 这次添加已放弃，请先从操作历史恢复填写并重新核对。'}
}
function DDSessionReason {
 param($Context,$Session,[string]$RunId,$HistoryModule)
 if(-not $Session){return ''}
 $processId=0;$ticks=0L
 if((Get-TCDField $Session RunId '') -cne $RunId -or -not [int]::TryParse([string](Get-TCDField $Session ProcessId ''),[ref]$processId) -or $processId -le 0 -or -not [long]::TryParse([string](Get-TCDField $Session StartTimeUtcTicks ''),[ref]$ticks) -or $ticks -le 0){return 'ExecutorIdentityUnknown'}
 try{
  $instance=Assert-TCDId ([string](Get-TCDField $Session InstanceId ''))
  $expected=Assert-TCDPath (Join-Path $Context.Root ('deployments\hosts\'+$instance))
  if((Assert-TCDPath ([string](Get-TCDField $Session Root ''))).TrimEnd('\') -ine $expected.TrimEnd('\')){return 'ExecutorIdentityUnknown'}
  $receipt=& $HistoryModule {param($c,$p) OHRead $c $p} $Context (Join-Path $expected 'receipt.json')
  if($Context.GlobalReasons.Count){return 'ExecutorOutcomeUnresolved'}
  if($receipt){
   if((Get-TCDField $receipt Mutating $false) -or (Get-TCDField $receipt Operation '') -notin @('','inspect','plan','status','server_info') -or (Get-TCDField $receipt Status '') -in @('Running','OutcomeUnknown','NeedsRecovery')){return 'ExecutorOutcomeUnresolved'}
  }
 }catch{return 'ExecutorIdentityUnknown'}
 $process=Get-Process -Id $processId -ErrorAction SilentlyContinue
 if($process){try{if([string]$process.StartTime.ToUniversalTime().Ticks -ceq [string]$ticks){return 'ExecutorActive'}}catch{return 'ExecutorIdentityUnknown'}finally{$process.Dispose()}}
 return ''
}
function DDRunReason {
 param($Context,$Record,$HistoryModule)
 if($Context.GlobalReasons.Count){return 'ReferenceStateUnknown'}
 if($Record.SourceKind -cne 'DeploymentRun'){return 'NotInputDraft'}
 $d=$Record.Doc
 if(-not $d -or $Record.Status -notin @('WaitingUser','Idle','Failed','Cancelled','Rejected') -or $Record.Stage -notin @('PrepareAccess','Inspect','Console','Transport','')){return 'NotInputDraft'}
 if($Record.IdentityState -notin @('Active','Missing')){return 'ServerIdentityRequiresReview'}
 if($Record.HasCheckpoint){return 'DeploymentEvidencePresent'}
 foreach($field in @('PendingOperationId','PendingPurpose','DispatchIntent','LastRemoteMutation','UnresolvedTcpMutation','CandidateTransaction','ClientRequest','ClientResponse','RequestDirectory','RequestJobId','RequestId','Plan','ManagementPlan','ServerInfo','CandidateNodeId','CandidateManifestPath','RecoveryRequired','ProbeRecoveryRequired','ExistingDevice','ApprovedChangeDigest','AllowDeviceAuthorize','AllowManagementInitialize','NetworkChanged','AttentionRequired')){if(Get-TCDField $d $field){return 'DeploymentEvidencePresent'}}
 $allowed=@('InputDraft','NotFinished','IdentityReference','RetainedOperationReference','RetainedTransactionReference')
 if(@($Record.Reasons|Where-Object {$_ -notin $allowed}).Count){return 'ReferencedOrUnresolved'}
 foreach($field in @('SessionRef','AttemptSessionRef')){$reason=DDSessionReason $Context (Get-TCDField $d $field) $Record.SourceId $HistoryModule;if($reason){return $reason}}
 return ''
}
function DDServerReason {
 param($Context,$Server,[string[]]$DiscardIds=@())
 if($Context.GlobalReasons.Count){return 'ReferenceStateUnknown'}
 if((Get-TCDField $Server RecordState 'Active') -cne 'Active'){return 'ServerIdentityRequiresReview'}
 foreach($field in @('RemoteOwnerId','NodeId','ServerPublicKey','ManagementSigningPublicKey','CredentialRef','ExpectedExitIPv4','Reinstall')){if(Get-TCDField $Server $field){return 'ServerEvidencePresent'}}
 foreach($field in @('LinkedNodeIds','Endpoints','SourceJobIds','ArchivedTasks','IdentityTransitionTasks','LegacyCheckpoints')){if(@(Get-TCDField $Server $field @()).Count){return 'ServerEvidencePresent'}}
 if((Get-TCDField $Server OwnershipState 'Unverified') -notin @('Unverified','NotInstalled','AwaitIdentityVerification')){return 'ServerEvidencePresent'}
 if(@($Context.LinkedNodes[$Server.LocalRecordId]).Count){return 'ServerEvidencePresent'}
 $related=@($Context.Records|Where-Object {$Server.LocalRecordId -in $_.ServerIds})
 if(@($related|Where-Object {$_.Id -notin $DiscardIds}).Count){return 'OtherRecordsRemain'}
 if(@($Context.Locks.Values|Where-Object {$_.Busy -and $_.ServerId -ceq $Server.LocalRecordId}).Count){return 'ExecutorActive'}
 return ''
}
function DDSnapshot {
 param([string]$Root,[string[]]$OwnedLocks=@())
 $history=Import-Module (Join-Path $PSScriptRoot 'OperationHistory.psm1') -PassThru -DisableNameChecking
 $context=& $history {param($r,$locks) OHSnapshot $r $locks} $Root $OwnedLocks
 $index=DDReadIndex $context.Root;$entries=@{};foreach($entry in $index.Entries){$entries[$entry.Id]=$entry}
 $discardIds=@($index.Entries|Where-Object Discarded|ForEach-Object {$_.Id})
 $records=@();$servers=@();$byId=@{}
 foreach($r in @($context.Records|Where-Object SourceKind -ceq 'DeploymentRun')){
  $reason=DDRunReason $context $r $history;$entry=$entries[$r.Id]
  $row=[pscustomobject]@{Id=$r.Id;SourceKind=$r.SourceKind;SourceId=$r.SourceId;ServerRecordId=$(if($r.ServerIds.Count -eq 1){$r.ServerIds[0]}else{$null});Name=[string](Get-TCDField $r.Doc Name '未完成的添加');UpdatedAtUtc=$r.UpdatedAtUtc;DiscardedAtUtc=[string](Get-TCDField $entry DiscardedAtUtc '');Discarded=[bool](Get-TCDField $entry Discarded $false);CanDiscardDraft=(-not $reason);DiscardBlockReason=$reason}
  $records+=,$row;$byId[$row.Id]=$row
 }
 foreach($s in $context.Servers){
  $id='ServerRecord:'+$s.LocalRecordId;$entry=$entries[$id];$reason=DDServerReason $context $s $discardIds
  $row=[pscustomobject]@{Id=$id;SourceKind='ServerRecord';SourceId=$s.LocalRecordId;ServerRecordId=$s.LocalRecordId;Name=[string](Get-TCDField $s Name '未完成的服务器登记');UpdatedAtUtc=[string](Get-TCDField $s LastCheckedUtc (Get-TCDField $s CreatedAtUtc ''));DiscardedAtUtc=[string](Get-TCDField $entry DiscardedAtUtc '');Discarded=[bool](Get-TCDField $entry Discarded $false);Suppressed=([bool](Get-TCDField $entry Discarded $false) -and -not $reason);CanDiscardDraft=(-not $reason);DiscardBlockReason=$reason}
  $servers+=,$row;$byId[$id]=$row
 }
 if($context.GlobalReasons.Count){foreach($row in @($records)+@($servers)){$row.CanDiscardDraft=$false;$row.DiscardBlockReason='ReferenceStateUnknown';if($row.PSObject.Properties['Suppressed']){$row.Suppressed=$false}}}
 # Extra executor receipt reads above join the sealed snapshot. Recheck them.
 & $history {param($c) foreach($f in @($c.Files.Values)){if((OHFileStamp $c $f.Path -PresenceOnly:$f.PresenceOnly) -cne $f.Stamp){OHFail HistorySnapshotChanged}}} $context
 $digest=Get-TCDDigest @{HistoryDigest=$context.Digest;Files=@($context.Files.Values|Sort-Object Path);Index=$index;Records=$records;Servers=$servers}
 return [pscustomobject]@{Context=$context;History=$history;Index=$index;Records=$records;Servers=$servers;ById=$byId;Digest=$digest}
}
function Get-TCDraftDisposition {
 [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root)
 $ErrorActionPreference='Stop';$s=DDSnapshot $Root
 [pscustomobject]@{SchemaVersion=1;Records=@($s.Records);Servers=@($s.Servers);Diagnostics=@($s.Context.GlobalReasons);DataDeleted=$false;NetworkChanged=$false;RemoteChanges=$false}
}
function Get-TCDeploymentReadView {
 [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][ValidateSet('Center','Detail')][string]$View,[string]$Id='')
 $ErrorActionPreference='Stop'
 # A read request owns one snapshot. It stays inside this call; only the public
 # projection leaves the module. Preview, commit and restore keep fresh reads.
 $s=DDSnapshot $Root
 $value=if($View -eq 'Center'){
  & $s.History {param($c) OHDeploymentCenterView $c} $s.Context
 }else{
  & $s.History {param($c,$id) OHOperationRecordDetailView $c $id} $s.Context $Id
 }
 $byId=@{};foreach($entry in @($s.Records)+@($s.Servers)){if($entry.Id){$byId[[string]$entry.Id]=$entry}}
 $items=@($value)
 foreach($field in @('AttentionItems','ContinueItems','DraftItems','PreparedItems','Cards')){
  if($value.PSObject.Properties[$field]){$items+=@($value.$field)}
 }
 foreach($item in @($items)){
  if($item -and $item.PSObject.Properties['TaskItems']){$items+=@($item.TaskItems)}
 }
 foreach($item in $items){
  if(-not $item -or -not $item.PSObject.Properties['Id']){continue}
  $entry=$byId[[string]$item.Id]
  foreach($field in @('CanDiscardDraft','DiscardBlockReason','Discarded')){
   $v=if($entry){$entry.$field}elseif($field -eq 'DiscardBlockReason'){'此记录不属于可放弃的空草稿。'}else{$false}
   $item|Add-Member -NotePropertyName $field -NotePropertyValue $v -Force
  }
 }
 return $value
}
function DDSelection {
 param([string[]]$Ids,$Snapshot)
 if(-not $Ids -or -not $Ids.Count){DDFail DraftSelectionEmpty}
 $keys=@(foreach($id in $Ids){$key=DDId $id;if(-not $Snapshot.ById.ContainsKey($key)){DDFail DraftRecordMissing};$key})
 return @($keys|Sort-Object -Unique)
}
function DDPlan {
 param($Snapshot,[string[]]$SelectedIds)
 $eligible=@();$protected=@()
 foreach($id in $SelectedIds){$r=$Snapshot.ById[$id];if($r.CanDiscardDraft -and -not $r.Discarded){$eligible+=,$r}elseif(-not $r.CanDiscardDraft){$protected+=,$r}}
 $ids=@($eligible|ForEach-Object {$_.Id});$previous=@($Snapshot.Index.Entries|Where-Object Discarded|ForEach-Object {$_.Id});$suppress=@()
 foreach($sid in @($eligible|ForEach-Object {$_.ServerRecordId}|Where-Object {$_}|Sort-Object -Unique)){
  $server=$Snapshot.Context.ServersById[$sid]
  if($server -and -not (DDServerReason $Snapshot.Context $server @($previous+$ids))){$suppress+=,$sid;if(('ServerRecord:'+$sid) -notin $ids){$ids+=,('ServerRecord:'+$sid)}}
 }
 [pscustomobject]@{Eligible=$eligible;Protected=$protected;DiscardIds=@($ids|Sort-Object -Unique);SuppressIds=@($suppress|Sort-Object -Unique)}
}
function DDProtect {
 param($Value)
 Add-Type -AssemblyName System.Security
 $bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Value -Depth 10 -Compress))
 try{[Convert]::ToBase64String([Security.Cryptography.ProtectedData]::Protect($bytes,[Text.Encoding]::UTF8.GetBytes('TradeChannel.DraftDisposition.v1'),[Security.Cryptography.DataProtectionScope]::CurrentUser))}finally{[Array]::Clear($bytes,0,$bytes.Length)}
}
function DDReadToken {
 param([string]$Root,[string]$Token)
 $bytes=$null
 try{
  if(-not $Token -or $Token.Length -gt 1048576){throw 'size'}
  Add-Type -AssemblyName System.Security
  $bytes=[Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($Token),[Text.Encoding]::UTF8.GetBytes('TradeChannel.DraftDisposition.v1'),[Security.Cryptography.DataProtectionScope]::CurrentUser)
  $v=[Text.Encoding]::UTF8.GetString($bytes)|ConvertFrom-Json -ErrorAction Stop
  if($v.SchemaVersion -ne 1 -or $v.RootDigest -cne (Get-TCDDigest (Assert-TCDPath $Root).TrimEnd('\').ToLowerInvariant()) -or $v.SelectedIds -isnot [array] -or -not $v.SelectedIds.Count -or $v.DiscardIds -isnot [array] -or $v.SuppressIds -isnot [array] -or $v.SnapshotDigest -cnotmatch '^[a-f0-9]{64}$'){throw 'binding'}
  foreach($id in @($v.SelectedIds)+@($v.DiscardIds)){$null=DDId $id}
  return $v
 }catch{Write-Verbose ('Draft preview validation failed: '+$_.Exception.Message);DDFail DraftPreviewInvalid}finally{if($bytes){[Array]::Clear($bytes,0,$bytes.Length)}}
}
function New-TCDraftDiscardPreview {
 [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][AllowEmptyCollection()][string[]]$Ids)
 $ErrorActionPreference='Stop';$s=DDSnapshot $Root;$selected=@(DDSelection $Ids $s);$plan=DDPlan $s $selected
 $expires=[DateTimeOffset]::UtcNow.AddMinutes(10).ToUnixTimeSeconds()
 $token=DDProtect @{SchemaVersion=1;RootDigest=(Get-TCDDigest $s.Context.Root.ToLowerInvariant());SnapshotDigest=$s.Digest;SelectedIds=$selected;DiscardIds=$plan.DiscardIds;SuppressIds=$plan.SuppressIds;ExpiresAt=$expires}
 [pscustomobject]@{SchemaVersion=1;PreviewToken=$token;SelectedIds=$selected;Eligible=@($plan.Eligible);Protected=@($plan.Protected);EligibleCount=$plan.Eligible.Count;ProtectedCount=$plan.Protected.Count;WillSuppressServerIds=@($plan.SuppressIds);ExpiresAtUtc=[DateTimeOffset]::FromUnixTimeSeconds($expires).UtcDateTime.ToString('o');DataDeleted=$false;NetworkChanged=$false;RemoteChanges=$false}
}
function DDWrite {
 param($Snapshot,[string[]]$Ids,[bool]$Discarded,$Receipt)
 $entries=@($Snapshot.Index.Entries|Where-Object {$_.Id -notin $Ids});$now=[DateTime]::UtcNow.ToString('o')
 foreach($id in $Ids){$r=$Snapshot.ById[$id];$entries+=,[pscustomobject]@{Id=$id;SourceKind=$r.SourceKind;SourceId=$r.SourceId;ServerRecordId=$r.ServerRecordId;Discarded=$Discarded;DiscardedAtUtc=$(if($Discarded){$now}else{$r.DiscardedAtUtc});UpdatedAtUtc=$now}}
 $commits=@($Snapshot.Index.Commits);if($Receipt){$commits+=,$Receipt}
 Write-TCDJson (Join-Path $Snapshot.Context.Root 'deployments\draft-dispositions.json') @{SchemaVersion=1;Revision=([long]$Snapshot.Index.Revision+1);Entries=@($entries|Sort-Object Id);Commits=$commits}
}
function DDClearTaskCredentials {
 param([string]$Root,[string[]]$Ids,$History)
 $removed=0;$discarded=@((DDReadIndex $Root).Entries|Where-Object Discarded|ForEach-Object Id)
 foreach($id in @($Ids|Sort-Object -Unique)){
  # A replay of an already-consumed discard must not revoke credentials saved
  # after the user explicitly restored the task and started a new attempt.
  if($id -cnotin $discarded){continue}
  if((DDId $id) -cnotmatch '^DeploymentRun:([0-9a-f-]{36})$'){continue}
  $source=$matches[1];$path=& $History {param($r,$p) OHPath $r $p} $Root (Join-Path $Root ('deployments\credentials\'+$source+'.json'))
  if([IO.Directory]::Exists($path)){throw '[TC:DraftCredentialCleanupRequired] 已放弃本次添加，但任务凭据路径异常；原资料保留，请使用本机资料清理入口核对。'}
  if([IO.File]::Exists($path)){try{[IO.File]::Delete($path);$removed++}catch{throw '[TC:DraftCredentialCleanupRequired] 已放弃本次添加，但临时登录凭据尚未清理；请重试本次放弃操作。'}}
 }
 return $removed
}
function DDResult {param($Receipt,[bool]$AlreadyApplied,[int]$CredentialsDeleted=0) [pscustomobject]@{DiscardedIds=@($Receipt.DiscardedIds);SuppressedServerIds=@($Receipt.SuppressedServerIds);DiscardedCount=$(if($AlreadyApplied){0}else{@($Receipt.DiscardedIds).Count});AlreadyApplied=$AlreadyApplied;DataDeleted=($CredentialsDeleted -gt 0);SourceDataDeleted=$false;TaskCredentialsDeletedCount=$CredentialsDeleted;TaskCredentialCleanupComplete=$true;NetworkChanged=$false;RemoteChanges=$false}}
function Discard-TCDeploymentDraft {
 [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][string]$PreviewToken)
 $ErrorActionPreference='Stop';$token=DDReadToken $Root $PreviewToken;$before=DDSnapshot $Root;$locks=$null;$gate=$null
 try{
  # Credential writers and physical cleanup share this gate. A discard cannot
  # race with a late credential save and leave a usable secret for an old task.
  $gate=Open-TCDLock (Join-Path $before.Context.Root '.local-cleanup.lock') -TimeoutMs 0
  $locks=& $before.History {param($c) OHOpenLocks $c} $before.Context
  $s=DDSnapshot $Root $locks.Paths;$hash=Get-TCDDigest $PreviewToken
  $receipts=@($s.Index.Commits|Where-Object {(Get-TCDField $_ TokenDigest '') -ceq $hash})
  if($receipts.Count -eq 1){$removed=DDClearTaskCredentials $s.Context.Root @($receipts[0].DiscardedIds) $s.History;return DDResult $receipts[0] $true $removed};if($receipts.Count -gt 1){DDFail DraftDispositionInvalid}
  if($token.ExpiresAt -lt [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() -or $token.ExpiresAt -gt [DateTimeOffset]::UtcNow.AddMinutes(11).ToUnixTimeSeconds() -or $token.SnapshotDigest -cne $s.Digest){DDFail DraftPreviewStale}
  $selected=@(DDSelection $token.SelectedIds $s);$plan=DDPlan $s $selected
  if((Get-TCDDigest $plan.DiscardIds) -cne (Get-TCDDigest $token.DiscardIds) -or (Get-TCDDigest $plan.SuppressIds) -cne (Get-TCDDigest $token.SuppressIds)){DDFail DraftPreviewStale}
  $again=DDSnapshot $Root $locks.Paths;if($again.Digest -cne $s.Digest){DDFail DraftPreviewStale}
  $receipt=[pscustomobject]@{TokenDigest=$hash;SelectedIds=$selected;DiscardedIds=$plan.DiscardIds;SuppressedServerIds=$plan.SuppressIds;AppliedAtUtc=[DateTime]::UtcNow.ToString('o')}
  if($plan.DiscardIds.Count){DDWrite $s $plan.DiscardIds $true $receipt}
  $removed=DDClearTaskCredentials $s.Context.Root @($plan.DiscardIds) $s.History
  return DDResult $receipt $false $removed
 }finally{if($locks){& $before.History {param($l) OHCloseLocks $l} $locks};if($gate){$gate.Dispose()}}
}
function Restore-TCDeploymentDraft {
 [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][string]$Id)
 $ErrorActionPreference='Stop';$key=DDId $Id;$before=DDSnapshot $Root;$locks=$null
 if(-not $before.ById.ContainsKey($key)){DDFail DraftRecordMissing}
 try{
  $locks=& $before.History {param($c) OHOpenLocks $c} $before.Context;$s=DDSnapshot $Root $locks.Paths
  if(-not $s.ById.ContainsKey($key)){DDFail DraftRecordMissing}
  $r=$s.ById[$key];$ids=@($key)
  if($r.SourceKind -ceq 'DeploymentRun' -and $r.ServerRecordId){$serverKey='ServerRecord:'+$r.ServerRecordId;if($s.ById.ContainsKey($serverKey) -and $s.ById[$serverKey].Discarded){$ids+=,$serverKey}}
  $restored=[bool]$r.Discarded;if($restored){DDWrite $s $ids $false $null}
  [pscustomobject]@{Id=$key;Restored=$restored;AlreadyActive=(-not $restored);RestoredIds=$(if($restored){$ids}else{@()});RequiresReview=$true;ApprovalsRestored=$false;DataDeleted=$false;NetworkChanged=$false;RemoteChanges=$false}
 }finally{if($locks){& $before.History {param($l) OHCloseLocks $l} $locks}}
}
Export-ModuleMember -Function Get-TCDraftDisposition,Get-TCDeploymentReadView,New-TCDraftDiscardPreview,Discard-TCDeploymentDraft,Restore-TCDeploymentDraft,Assert-TCDraftActive,Test-TCDraftDiscarded
