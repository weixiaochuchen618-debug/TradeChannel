#requires -Version 5.1
[CmdletBinding()]param([string]$SourceDirectory='')
$ErrorActionPreference='Stop';Set-StrictMode -Version 2.0
if(-not $SourceDirectory){$SourceDirectory=Join-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) '..'}
$package=[IO.Path]::GetFullPath($SourceDirectory)
$nonce=[guid]::NewGuid().ToString('N');$tempBase=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\');$workspace=Join-Path $tempBase ('tc-draft-disposition-'+$nonce)
$checks=New-Object 'Collections.Generic.List[string]'
function Guard {param([string]$Path,[switch]$Root) $p=[IO.Path]::GetFullPath($Path).TrimEnd('\');foreach($blocked in @($env:ProgramData,[Environment]::GetFolderPath('CommonApplicationData'),'C:\ProgramData')){if($blocked){$b=[IO.Path]::GetFullPath($blocked).TrimEnd('\');if($p.Equals($b,[StringComparison]::OrdinalIgnoreCase) -or $p.StartsWith($b+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Production data is forbidden.'}}};if(-not $p.StartsWith($workspace+'\',[StringComparison]::OrdinalIgnoreCase) -and -not ($Root -and $p -ceq $workspace)){throw 'Outside owned fixture.'};return $p}
function Check {param([bool]$Value,[string]$Name) if(-not $Value){throw ('Draft assertion failed: '+$Name)};$checks.Add($Name)}
function Reject {param([scriptblock]$Action,[string]$Code,[string]$Name) $caught=$false;try{$null=& $Action}catch{if($_.Exception.Message -notmatch [regex]::Escape($Code)){throw};$caught=$true};Check $caught $Name}
function JWrite {param([string]$Path,$Value) Write-TCDJson (Guard $Path) $Value}
function JRead {param([string]$Path) Read-TCDJson (Guard $Path)}
function Clone {param($Value) ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $Value -Depth 40)}
function Inventory {param([string]$Root) @(Get-ChildItem -LiteralPath (Guard $Root) -Recurse -File -Force|Where-Object {$_.Name -notlike '*.lock' -and $_.Name -cne 'draft-dispositions.json'}|Sort-Object FullName|ForEach-Object {($_.FullName+'|'+(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash+'|'+(Get-Acl -LiteralPath $_.FullName).Sddl)}) -join "`n"}
function Fixture {
 param([string]$Name)
 $root=Guard (Join-Path $workspace $Name);$null=New-TCDDirectory $root;$id=[guid]::NewGuid().ToString('D')
 $server=[pscustomobject]@{LocalRecordId=$id;Name='尚未开始的服务器';Connection=@{Host='192.0.2.10';Port=22;User='root';IdentityFile=''};RecordState='Active';RemoteOwnerId=$null;NodeId=$null;ServerPublicKey=$null;PinnedHostKey=$null;CredentialRef=$null;OwnershipState='Unverified';LinkedNodeIds=@();SourceJobIds=@();Endpoints=@();ArchivedTasks=@();CreatedAtUtc=[DateTime]::UtcNow.ToString('o')}
 JWrite (Join-Path $root 'servers\registry.json') @{SchemaVersion=1;Revision=1;Servers=@($server)}
 [pscustomobject]@{Root=$root;Server=$server}
}
function NewRun {
 param($Fixture,$Extras=@{})
 $id=[guid]::NewGuid().ToString('D');$run=[ordered]@{SchemaVersion=1;RunId=$id;Revision=1;Intent='New';Name='保存的添加草稿';ServerRecordId=$Fixture.Server.LocalRecordId;Status='WaitingUser';Stage='PrepareAccess';CreatedAtUtc=[DateTime]::UtcNow.ToString('o');UpdatedAtUtc=[DateTime]::UtcNow.ToString('o');PendingOperationId=$null;DispatchIntent=$null;ClientRequest=$null;ClientResponse=$null;CandidateTransaction=$null;CandidateNodeId=$null;CandidateManifestPath=$null;RecoveryRequired=$false;ProbeRecoveryRequired=$false;AttentionRequired=$false;NetworkChanged=$false}
 foreach($key in $Extras.Keys){$run[$key]=$Extras[$key]};$path=Join-Path $Fixture.Root ('deployments\runs\'+$id+'\state.json');JWrite $path $run
 [pscustomobject]@{Id=('DeploymentRun:'+$id);SourceId=$id;Path=$path;Value=(Clone $run)}
}
function Row {param($Fixture,[string]$Id) $dto=Get-TCDraftDisposition -Root $Fixture.Root;@(@($dto.Records)+@($dto.Servers)|Where-Object Id -ceq $Id)|Select-Object -First 1}
$null=Guard $workspace -Root
if([IO.Directory]::Exists($workspace)){throw 'Fixture must not preexist.'}
Import-Module (Join-Path $package 'DeploymentStore.psm1') -DisableNameChecking
$null=New-TCDDirectory $workspace;[IO.File]::WriteAllText((Join-Path $workspace '.tc-fixture-owned'),$nonce)
$module=Import-Module (Join-Path $package 'DraftDisposition.psm1') -PassThru -Force -DisableNameChecking
$history=Import-Module (Join-Path $package 'OperationHistory.psm1') -PassThru -DisableNameChecking
& $module {function script:Start-TCDeploySession {throw 'Network forbidden.'};function script:Get-TCDeploySession {throw 'Executor contact forbidden.'};function script:Stop-TCDeploySession {throw 'Process mutation forbidden.'}}
try{
 $f=Fixture 'simple';$run=NewRun $f;$serverKey='ServerRecord:'+$f.Server.LocalRecordId;$sourceBefore=Inventory $f.Root
 $public=Get-TCDraftDisposition -Root $f.Root
 Check ((Row $f $run.Id).CanDiscardDraft -and -not (Row $f $serverKey).CanDiscardDraft) 'Input task is eligible while server cannot independently discard its task'
 $preview=New-TCDraftDiscardPreview -Root $f.Root -Ids @($run.Id)
 Check ($preview.EligibleCount -eq 1 -and $preview.WillSuppressServerIds.Count -eq 1 -and (Inventory $f.Root) -ceq $sourceBefore) 'Preview is read only and includes the orphan provisional server'
 $result=Discard-TCDeploymentDraft -Root $f.Root -PreviewToken $preview.PreviewToken
 Check ($result.DiscardedIds.Count -eq 2 -and -not $result.DataDeleted -and -not $result.RemoteChanges -and (Inventory $f.Root) -ceq $sourceBefore) 'Discard atomically marks task and empty server without source or ACL changes'
 Check ((Row $f $run.Id).Discarded -and (Row $f $serverKey).Suppressed -and (Row $f $run.Id).Name -ceq '保存的添加草稿' -and (Row $f $run.Id).DiscardedAtUtc) 'Refresh exposes named discarded entries and suppresses empty server'
 $again=Discard-TCDeploymentDraft -Root $f.Root -PreviewToken $preview.PreviewToken
 Check ($again.AlreadyApplied -and $again.DiscardedCount -eq 0) 'Repeated commit is idempotent'
 Reject {Assert-TCDraftActive -Root $f.Root -Id $run.Id} DraftDiscarded 'Discarded run refuses direct continuation'
 $restored=Restore-TCDeploymentDraft -Root $f.Root -Id $run.Id
 Check ($restored.Restored -and $restored.RequiresReview -and -not $restored.ApprovalsRestored -and -not (Row $f $run.Id).Discarded -and -not (Row $f $serverKey).Suppressed -and (Inventory $f.Root) -ceq $sourceBefore) 'Restore reveals input and server but changes no authorization'
 $replay=Discard-TCDeploymentDraft -Root $f.Root -PreviewToken $preview.PreviewToken
 Check ($replay.AlreadyApplied -and -not (Row $f $run.Id).Discarded) 'Consumed discard token cannot undo a later restore'
 Check ((Restore-TCDeploymentDraft -Root $f.Root -Id $run.Id).AlreadyActive) 'Repeated restore is idempotent'

 $credentialFixture=Fixture 'task-credentials';$credentialRun=NewRun $credentialFixture;$siblingRun=NewRun $credentialFixture
 $credentialPath=Join-Path $credentialFixture.Root ('deployments\credentials\'+$credentialRun.SourceId+'.json');$siblingCredential=Join-Path $credentialFixture.Root ('deployments\credentials\'+$siblingRun.SourceId+'.json')
 JWrite $credentialPath @{RunId=$credentialRun.SourceId;Protected='isolated-envelope'};JWrite $siblingCredential @{RunId=$siblingRun.SourceId;Protected='sibling-envelope'}
 $p=New-TCDraftDiscardPreview $credentialFixture.Root @($credentialRun.Id);$r=Discard-TCDeploymentDraft $credentialFixture.Root $p.PreviewToken
 Check ($r.TaskCredentialCleanupComplete -and $r.TaskCredentialsDeletedCount -eq 1 -and -not $r.SourceDataDeleted -and -not (Test-Path $credentialPath) -and (Test-Path $siblingCredential)) 'Discard revokes only the selected task credential while retaining editable source and sibling credentials'
 $null=Restore-TCDeploymentDraft $credentialFixture.Root $credentialRun.Id;JWrite $credentialPath @{RunId=$credentialRun.SourceId;Protected='new-attempt-envelope'}
 $newCredentialDigest=Get-TCDDigest (JRead $credentialPath);$replayed=Discard-TCDeploymentDraft $credentialFixture.Root $p.PreviewToken
 Check ($replayed.AlreadyApplied -and $replayed.TaskCredentialsDeletedCount -eq 0 -and (Get-TCDDigest (JRead $credentialPath)) -ceq $newCredentialDigest) 'Consumed discard token cannot revoke a new credential after explicit restoration'
 $p=New-TCDraftDiscardPreview $credentialFixture.Root @($credentialRun.Id);$heldCredential=[IO.File]::Open($credentialPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
 try{Reject {Discard-TCDeploymentDraft $credentialFixture.Root $p.PreviewToken} DraftCredentialCleanupRequired 'Failed credential deletion is reported rather than silently claiming full cleanup'}finally{$heldCredential.Dispose()}
 Check ((Row $credentialFixture $credentialRun.Id).Discarded -and (Test-Path $credentialPath)) 'Credential cleanup failure preserves a retryable local abandonment marker'
 $r=Discard-TCDeploymentDraft $credentialFixture.Root $p.PreviewToken
 Check ($r.AlreadyApplied -and $r.TaskCredentialCleanupComplete -and -not (Test-Path $credentialPath)) 'Retry of the same confirmed discard completes a previously failed credential revocation'
 $p=New-TCDraftDiscardPreview $credentialFixture.Root @($siblingRun.Id);$credentialLease=Open-TCDLock (Join-Path $credentialFixture.Root 'deployments\.credentials.lock')
 try{Reject {Discard-TCDeploymentDraft $credentialFixture.Root $p.PreviewToken} HistoryBusy 'Draft discard respects the shared credential revocation lock';Check ((Test-Path $siblingCredential) -and -not (Row $credentialFixture $siblingRun.Id).Discarded) 'Blocked credential cleanup leaves the task and its credential unchanged'}finally{$credentialLease.Dispose()}

 $historical=Fixture 'retained-reference';$old=NewRun $historical @{Status='Complete';Stage='Inspect';RequestJobId=[guid]::NewGuid().ToString('D')};$new=NewRun $historical
 $center=Get-TCDeploymentCenter $historical.Root
 Check ($center.HistoricalDiagnostics -contains 'HistoricalReferenceTargetMissing' -and $center.Diagnostics -notcontains 'ReferenceTargetMissing' -and (Row $historical $new.Id).CanDiscardDraft) 'Missing reference in a completed old summary does not disable an unrelated fresh input draft'
 $p=New-TCDraftDiscardPreview $historical.Root @($new.Id);$null=Discard-TCDeploymentDraft $historical.Root $p.PreviewToken
 Check ((Row $historical $new.Id).Discarded -and -not @((Get-TCDeploymentCenter $historical.Root).DraftItems|Where-Object Id -ceq $new.Id).Count) 'Historical gaps cannot revive an explicitly discarded new draft'

 $shared=Fixture 'shared';$a=NewRun $shared;$b=NewRun $shared;$p=New-TCDraftDiscardPreview -Root $shared.Root -Ids @($a.Id);$r=Discard-TCDeploymentDraft -Root $shared.Root -PreviewToken $p.PreviewToken
 Check ($r.DiscardedIds.Count -eq 1 -and $r.SuppressedServerIds.Count -eq 0 -and -not (Row $shared $b.Id).Discarded) 'Discarding one task leaves same-server sibling and registry visible'
 $p=New-TCDraftDiscardPreview -Root $shared.Root -Ids @($b.Id);$null=Discard-TCDeploymentDraft -Root $shared.Root -PreviewToken $p.PreviewToken
 Check ((Row $shared ('ServerRecord:'+$shared.Server.LocalRecordId)).Suppressed) 'Last discarded input also suppresses its empty server'
 $null=Restore-TCDeploymentDraft -Root $shared.Root -Id $a.Id
 Check (-not (Row $shared $a.Id).Discarded -and (Row $shared $b.Id).Discarded) 'Restoring one input does not restore sibling approvals or tasks'

 $orphan=Fixture 'orphan';$oid='ServerRecord:'+$orphan.Server.LocalRecordId;$p=New-TCDraftDiscardPreview -Root $orphan.Root -Ids @($oid);$null=Discard-TCDeploymentDraft -Root $orphan.Root -PreviewToken $p.PreviewToken
 Check ((Row $orphan $oid).Suppressed -and (Row $orphan $oid).Name -ceq '尚未开始的服务器') 'Standalone empty registration is discardable and restorable by name'
 Import-Module (Join-Path $package 'ServerRegistry.psm1') -DisableNameChecking
 Reject {Get-TCServer -Root $orphan.Root -Id $orphan.Server.LocalRecordId} DraftDiscarded 'Suppressed registration cannot obtain management object'
 $fresh=Set-TCServerRecord -Root $orphan.Root -Connection $orphan.Server.Connection -Name '主动重新添加'
 Check ($fresh.LocalRecordId -cne $orphan.Server.LocalRecordId -and (Row $orphan $oid).Discarded) 'Explicitly adding same endpoint creates a new registration without reviving old input'
 $null=Restore-TCDeploymentDraft -Root $orphan.Root -Id $oid
 Check (-not (Row $orphan $oid).Discarded) 'Standalone registration restore is available'

 foreach($case in @(
  @{Name='unknown';Fields=@{Status='OutcomeUnknown';RecoveryRequired=$true}},
  @{Name='mutation';Fields=@{LastRemoteMutation=@{Mutating=$true;Operation='apply';State='Completed'}}},
  @{Name='response';Fields=@{ClientResponse=@{RequestId=[guid]::NewGuid().ToString('D')}}},
  @{Name='candidate';Fields=@{CandidateNodeId=[guid]::NewGuid().ToString('D')}},
  @{Name='approval';Fields=@{ApprovedChangeDigest=('a'*64);AllowDeviceAuthorize=$true}},
  @{Name='running';Fields=@{Status='Running';PendingOperationId=[guid]::NewGuid().ToString('D')}},
  @{Name='cleanup';Fields=@{Validation=@{CleanupComplete=$false}}},
  @{Name='broken-session';Fields=@{AttemptSessionRef=@{RunId='invalid'}}}
 )){$caseFixture=Fixture $case.Name;$danger=NewRun $caseFixture $case.Fields;$p=New-TCDraftDiscardPreview -Root $caseFixture.Root -Ids @($danger.Id);Check ($p.EligibleCount -eq 0 -and $p.ProtectedCount -eq 1) ('Protected '+$case.Name+' is never discarded')}

 $stale=Fixture 'stale';$item=NewRun $stale;$p=New-TCDraftDiscardPreview -Root $stale.Root -Ids @($item.Id);$v=JRead $item.Path;$v.Status='OutcomeUnknown';$v.RecoveryRequired=$true;JWrite $item.Path $v
 Reject {Discard-TCDeploymentDraft -Root $stale.Root -PreviewToken $p.PreviewToken} DraftPreviewStale 'Changed remote outcome invalidates preview before marking'
 $bound=Fixture 'root-binding';Reject {Discard-TCDeploymentDraft -Root $bound.Root -PreviewToken $p.PreviewToken} DraftPreviewInvalid 'Preview cannot move to another root'
 Reject {New-TCDraftDiscardPreview -Root $bound.Root -Ids @()} DraftSelectionEmpty 'Empty selection never expands into bulk discard'
 Reject {New-TCDraftDiscardPreview -Root $bound.Root -Ids @('ServerRecord:..\outside')} DraftInvalidId 'Path-like selection is rejected'
 Reject {Discard-TCDeploymentDraft -Root $bound.Root -PreviewToken 'garbage'} DraftPreviewInvalid 'Malformed preview token is rejected'

 $busy=Fixture 'busy';$item=NewRun $busy;$p=New-TCDraftDiscardPreview -Root $busy.Root -Ids @($item.Id)
 $held=Open-TCDLock (Join-Path $busy.Root ('servers\.task-'+$busy.Server.LocalRecordId+'.lock'))
 try{Reject {Discard-TCDeploymentDraft -Root $busy.Root -PreviewToken $p.PreviewToken} HistoryBusy 'Commit respects an active task lease';Check (-not (Row $busy $item.Id).CanDiscardDraft) 'Busy execution disables discard eligibility'}finally{$held.Dispose()}

 $active=Fixture 'executor';$item=NewRun $active;$instance=[guid]::NewGuid().ToString('D');$process=Get-Process -Id $PID;$ref=@{RunId=$item.SourceId;InstanceId=$instance;ProcessId=$PID;StartTimeUtcTicks=[string]$process.StartTime.ToUniversalTime().Ticks;Root=(Join-Path $active.Root ('deployments\hosts\'+$instance))};$process.Dispose();$v=JRead $item.Path;$v|Add-Member NoteProperty AttemptSessionRef $ref;JWrite $item.Path $v
 Check ((Row $active $item.Id).DiscardBlockReason -ceq 'ExecutorActive') 'Live exact process identity blocks discard without contacting executor'

 $corrupt=Fixture 'corrupt';$bad=NewRun $corrupt;JWrite (Join-Path $corrupt.Root 'deployments\draft-dispositions.json') @{SchemaVersion=1;Revision=1;Entries=@(@{Id=$bad.Id;SourceKind='DeploymentRun';SourceId=$bad.SourceId;Discarded=$true},@{Id=$bad.Id;SourceKind='DeploymentRun';SourceId=$bad.SourceId;Discarded=$true});Commits=@()}
 Reject {Get-TCDraftDisposition -Root $corrupt.Root} DraftDispositionInvalid 'Duplicate disposition IDs fail closed'

 $json=ConvertTo-Json -InputObject $public -Depth 8 -Compress
 Check ($json -notmatch 'Connection|SessionRef|ClientResponse|ClientRequest|Credential|ServerPublicKey|PreviewToken') 'Public eligibility DTO excludes connection secrets and authorization material'
 [pscustomobject]@{Passed=$true;Checks=$checks.Count;Assertions=@($checks);SourceDirectory=$package;ProductionDataTouched=$false;NetworkUsed=$false;ProcessesStartedOrStopped=$false}|ConvertTo-Json -Depth 8
}finally{
 $clean=Guard $workspace -Root;$marker=Join-Path $clean '.tc-fixture-owned'
 if($clean -cne (Join-Path $tempBase ('tc-draft-disposition-'+$nonce)) -or -not [IO.File]::Exists($marker) -or [IO.File]::ReadAllText($marker) -cne $nonce){throw 'Fixture ownership check failed.'}
 Remove-Item -LiteralPath $clean -Recurse -Force -ErrorAction Stop
}
