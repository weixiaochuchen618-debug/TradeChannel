#requires -Version 5.1
[CmdletBinding()]param([Parameter(Mandatory=$true)][string]$SourceDirectory,[string]$ReportPath='')
$ErrorActionPreference='Stop';Set-StrictMode -Version 2.0
$workspace=Join-Path ([IO.Path]::GetTempPath()) ('tc-removal-0161-'+[guid]::NewGuid().ToString('N'))
$checks=New-Object 'Collections.Generic.List[string]'
Import-Module (Join-Path $SourceDirectory 'DeploymentStore.psm1') -Force -DisableNameChecking
$history=Import-Module (Join-Path $SourceDirectory 'OperationHistory.psm1') -Force -DisableNameChecking -PassThru
Import-Module (Join-Path $SourceDirectory 'DraftDisposition.psm1') -Force -DisableNameChecking
function Check {param([bool]$Ok,[string]$Label) if(-not $Ok){throw ('Record removal regression: '+$Label)};$checks.Add($Label)}
function Safe {param([string]$Path) $p=[IO.Path]::GetFullPath($Path);if(-not $p.StartsWith($workspace+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Outside owned fixture'};return $p}
function Put {param([string]$Path,$Value) Write-TCDJson (Safe $Path) $Value}
function Hash {param([string]$Path) (Get-FileHash -LiteralPath (Safe $Path) -Algorithm SHA256).Hash}
function Read {param([string]$Path) Read-TCDJson (Safe $Path)}
function Inventory {param([string]$Root) @((Get-ChildItem -LiteralPath (Safe $Root) -Recurse -File|Where-Object {$_.FullName -notlike '*\operation-history\*'}|Sort-Object FullName|ForEach-Object {$_.FullName+':'+(Hash $_.FullName)})) -join '|'}
function Reject {param([scriptblock]$Action,[string]$Code,[string]$Label) $caught='';try{& $Action|Out-Null}catch{$caught=$_.Exception.Message};Check ($caught -like ('*'+$Code+'*')) $Label}
function Fixture {param([string]$Name)
 $root=Join-Path $workspace $Name;$id=[guid]::NewGuid().ToString('D');$now=[DateTime]::UtcNow.ToString('o')
 $server=[pscustomobject]@{LocalRecordId=$id;RecordState='Active';Name='Server fixture';Connection=@{Host='192.0.2.11';Port=22;User='root'};RemoteOwnerId=$null;NodeId=$null;ServerPublicKey=$null;LinkedNodeIds=@();SourceJobIds=@();CreatedAtUtc=$now}
 Put (Join-Path $root 'servers\registry.json') @{SchemaVersion=1;Revision=1;Servers=@($server)}
 [pscustomobject]@{Root=$root;Server=$server}
}
function Run {param($Fixture,[string]$Status='WaitingUser',$Extra=@{})
 $id=[guid]::NewGuid().ToString('D');$now=[DateTime]::UtcNow.ToString('o');$path=Join-Path $Fixture.Root ('deployments\runs\'+$id+'\state.json')
 $value=[ordered]@{SchemaVersion=1;RunId=$id;Revision=1;Name='Preparation fixture';Intent='New';Status=$Status;Stage='PrepareAccess';ServerRecordId=$Fixture.Server.LocalRecordId;UpdatedAtUtc=$now;CreatedAtUtc=$now}
 foreach($k in $Extra.Keys){$value[$k]=$Extra[$k]};Put $path $value
 [pscustomobject]@{Id=('DeploymentRun:'+$id);SourceId=$id;Path=$path;Value=$value}
}
function Legacy {param($Fixture,[string]$Status='Failed')
 $id=[guid]::NewGuid().ToString('D');$dir=Join-Path $Fixture.Root ('linux-jobs\'+$id);$now=[DateTime]::UtcNow.ToString('o')
 Put (Join-Path $dir 'job.json') @{SchemaVersion=1;JobId=$id;Name='Linux fixture';Operation='Apply';CreatedAtUtc=$now}
 Put (Join-Path $dir 'result.json') @{SchemaVersion=1;JobId=$id;Operation='Apply';Status=$Status;Stage='Backend';OutcomeUnknown=$true;FinishedAtUtc=$now}
 [pscustomobject]@{Id=('LegacyLinuxJob:'+$id);SourceId=$id;Path=(Join-Path $dir 'result.json')}
}
function Detail {param($Fixture,[string]$Id) Get-TCOperationRecordDetail -Root $Fixture.Root -Id $Id}
function Delete {param($Fixture,[string[]]$Ids) $p=New-TCRecordDeletePreview -Root $Fixture.Root -Ids $Ids;Remove-TCDisplayRecord -Root $Fixture.Root -PreviewToken $p.PreviewToken}
function CenterItems {param($Fixture) $c=Get-TCDeploymentCenter $Fixture.Root;@($c.AttentionItems)+@($c.ContinueItems)+@($c.DraftItems)+@($c.PreparedItems)+@($c.AvailableServers)}
try{
 $f=Fixture 'legacy-and-progress';$one=Legacy $f;$two=Legacy $f;$run=Run $f WaitingUser @{Plan=@{PlanId='fixture'};SourceRunId=[guid]::NewGuid().ToString('D')}
 $bad=Join-Path $f.Root ('connection-transactions\'+[guid]::NewGuid().ToString('D')+'.json');Put $bad @{};[IO.File]::WriteAllText((Safe $bad),'{invalid')
 $key=Join-Path ([IO.Path]::GetDirectoryName($run.Path)) 'client.key';[IO.File]::WriteAllText((Safe $key),'FIXTURE_PRIVATE_SENTINEL')
 $detail=Detail $f $one.Id
 Check ($detail.CanDeleteRecord -and -not $detail.CanClear -and $detail.IdentityState -eq 'Missing') 'Unidentified legacy failure can be deleted while old retention protection remains'
 Check ($detail.ProtectionReasons -contains 'ReferenceMetadataInvalid' -and $detail.ProtectionReasons -contains 'ReferenceTargetMissing') 'Reproduces the installed historical reference diagnostics'
 Check (-not $detail.CanResume -and $detail.EntryAction -eq 'ViewRecord') 'List deletion eligibility grants no deployment permission'
 $before=Inventory $f.Root;$preview=New-TCRecordDeletePreview -Root $f.Root -Ids @($one.Id)
 Check ($preview.EligibleCount -eq 1 -and $preview.ProtectedCount -eq 0 -and $preview.Eligible[0].Id -ceq $one.Id) 'Single preview binds exactly the selected historical record'
 Check ((Inventory $f.Root) -ceq $before -and -not (Test-Path -LiteralPath (Join-Path $f.Root 'operation-history'))) 'Preview does not create metadata or edit source files'
 Check ((($preview.Eligible|ConvertTo-Json -Depth 15) -notmatch 'FIXTURE_PRIVATE_SENTINEL|CredentialRef|SessionRef|ClientResponse|SourceFingerprint')) 'Public preview excludes credentials and private source facts'
 $result=Remove-TCDisplayRecord $f.Root $preview.PreviewToken
 Check ($result.DeletedCount -eq 1 -and -not $result.DataDeleted -and -not $result.RemoteChanges) 'Deletion changes only local list state'
 Check (@(Get-TCOperationHistory $f.Root|Where-Object Id -ceq $one.Id).Count -eq 0 -and @(Get-TCOperationHistory $f.Root|Where-Object Id -ceq $two.Id).Count -eq 1) 'Deleting one row leaves the other Linux record visible'
 Check ((Detail $f $one.Id).Deleted -and (Detail $f $one.Id).EntryAction -eq 'ViewRecord') 'Deleted record detail is still available read-only'
 Check (@(Get-TCOperationHistory $f.Root -IncludeHidden|Where-Object {$_.Id -ceq $one.Id -and $_.Deleted}).Count -eq 1) 'Deleted-record view includes the exact original record'
 Check ((Inventory $f.Root) -ceq $before) 'Deletion preserves original operations, registry, and key bytes'
 $null=Restore-TCDisplayRecord $f.Root $one.Id;$replay=Remove-TCDisplayRecord $f.Root $preview.PreviewToken
 Check ($replay.AlreadyApplied -and $replay.DeletedCount -eq 0 -and -not (Detail $f $one.Id).Deleted) 'Replaying a used confirmation cannot delete a restored record'
 $preview=New-TCRecordDeletePreview $f.Root @($one.Id,$one.Id,$two.Id,$run.Id)
 Check ($preview.EligibleCount -eq 3 -and $preview.SelectedIds.Count -eq 3) 'Multi-selection deduplicates IDs and includes unfinished preparation'
 $result=Remove-TCDisplayRecord $f.Root $preview.PreviewToken
 Check ($result.DeletedCount -eq 3 -and @(Get-TCOperationHistory $f.Root).Count -eq 0) 'Batch deletion removes all selected visible operations'
 Check (@(CenterItems $f).Count -eq 0) 'Deleting the last linked preparation does not resurrect an empty server card'
 Check (@(Get-TCOperationHistory $f.Root -IncludeServerRecords).Count -eq 0) 'Hidden linked operations do not become duplicate server history'
 Check ((Inventory $f.Root) -ceq $before) 'Batch deletion preserves all original data despite corrupt references'
 $run.Value.Revision=2;$run.Value.Stage='Inspect';Put $run.Path $run.Value
 Check (-not (Detail $f $run.Id).Deleted -and @(CenterItems $f|Where-Object Id -ceq $run.Id).Count -eq 1) 'New progress invalidates a prior deletion and resurfaces preparation'
 $v=Read $one.Path;$v.FinishedAtUtc=[DateTime]::UtcNow.ToString('o');$v.Status='Completed';Put $one.Path $v
 Check (-not (Detail $f $one.Id).Deleted -and (Detail $f $two.Id).Deleted) 'New legacy result revives only its own deleted row'

 $serverOnly=Fixture 'standalone-server';$sid='ServerRecord:'+$serverOnly.Server.LocalRecordId
 Check (@(Get-TCOperationHistory $serverOnly.Root).Count -eq 0 -and @(Get-TCOperationHistory $serverOnly.Root -IncludeServerRecords).Count -eq 1) 'Server history is opt-in for legacy API compatibility'
 $before=Inventory $serverOnly.Root;$null=Delete $serverOnly @($sid)
 Check (@(CenterItems $serverOnly).Count -eq 0 -and (Detail $serverOnly $sid).Deleted) 'Standalone saved server record can be removed from the center'
 Check (@(Get-TCOperationHistory $serverOnly.Root -IncludeServerRecords -IncludeHidden|Where-Object Id -ceq $sid).Count -eq 1) 'Standalone deleted server has a discoverable recovery entry'
 Check ((Inventory $serverOnly.Root) -ceq $before) 'Server deletion preserves the registry and connection material'
 $null=Restore-TCDisplayRecord $serverOnly.Root $sid
 Check (@(CenterItems $serverOnly|Where-Object Id -ceq $sid).Count -eq 1) 'Server restore returns the original preparation entry'
 $null=Delete $serverOnly @($sid);$new=Run $serverOnly
 Check (-not (Detail $serverOnly $sid).Deleted -and @(CenterItems $serverOnly|Where-Object Id -ceq $new.Id).Count -eq 1) 'New related work invalidates a deleted server marker'

 $active=Fixture 'active';$running=Run $active Running;$waiting=Legacy $active
 Check ((Detail $active $running.Id).CanDeleteRecord) 'A saved running label alone allows opening the cleanup preview instead of asserting a live process'
 $process=[Diagnostics.Process]::GetCurrentProcess()
 try{$running.Value.SessionRef=@{RunId=$running.SourceId;ProcessId=$process.Id;StartTimeUtcTicks=$process.StartTime.ToUniversalTime().Ticks};Put $running.Path $running.Value}finally{$process.Dispose()}
 $p=New-TCRecordDeletePreview $active.Root @($running.Id,$waiting.Id)
 Check ($p.EligibleCount -eq 1 -and $p.ProtectedCount -eq 1 -and $p.Protected[0].DeleteBlockReason -eq 'ExecutorActive') 'An exact live task is reported separately from deletable history'
 $r=Remove-TCDisplayRecord $active.Root $p.PreviewToken
 Check ($r.DeletedCount -eq 1 -and -not (Detail $active $running.Id).Deleted) 'Mixed batch leaves active work visible'
 Check (-not (Detail $active ('ServerRecord:'+$active.Server.LocalRecordId)).CanDeleteRecord) 'Server record cannot be removed while its related task runs'
 $running.Value.Status='WaitingUser';$running.Value.Remove('SessionRef');Put $running.Path $running.Value
 $p=New-TCRecordDeletePreview $active.Root @($running.Id);$lease=Open-TCDLock (Join-Path ([IO.Path]::GetDirectoryName($running.Path)) '.run.lock')
 try{
  Check (-not (Detail $active $running.Id).CanDeleteRecord) 'An active run lease disables record deletion'
  Reject {Remove-TCDisplayRecord $active.Root $p.PreviewToken} HistoryPreviewStale 'Task starting after preview rejects the entire stale commit'
 }finally{$lease.Dispose()}
 $process=[Diagnostics.Process]::GetCurrentProcess()
 try{$running.Value.SessionRef=@{RunId=$running.SourceId;ProcessId=$process.Id;StartTimeUtcTicks=$process.StartTime.ToUniversalTime().Ticks};Put $running.Path $running.Value;Check ((Detail $active $running.Id).DeleteBlockReason -eq 'ExecutorActive') 'A live matching executor cannot be hidden by an idle run status'}finally{$process.Dispose()}
 $running.Value.Remove('SessionRef');Put $running.Path $running.Value
 $runtimeLock=Open-TCDLock (Join-Path $active.Root '.session.lock')
 try{Check ((Detail $active $running.Id).CanDeleteRecord) 'Current connection lock does not prevent unrelated list management';$null=Delete $active @($running.Id);Check ((Detail $active $running.Id).Deleted) 'List deletion can complete while the current connection remains locked'}finally{$runtimeLock.Dispose()}

 $stale=Fixture 'stale';$a=Run $stale;$b=Legacy $stale;$p=New-TCRecordDeletePreview $stale.Root @($a.Id)
 $a.Value.Revision=2;Put $a.Path $a.Value
 Reject {Remove-TCDisplayRecord $stale.Root $p.PreviewToken} HistoryPreviewStale 'Source change between preview and commit requires fresh confirmation'
 Check (-not (Detail $stale $a.Id).Deleted) 'Stale confirmation never removes the newer record'
 $p=New-TCRecordDeletePreview $stale.Root @($a.Id);$v=Read $b.Path;$v.Status='Completed';Put $b.Path $v
 $null=Remove-TCDisplayRecord $stale.Root $p.PreviewToken
 Check ((Detail $stale $a.Id).Deleted) 'Unrelated historical updates do not invalidate an exact selection'
 $null=Restore-TCDisplayRecord $stale.Root $a.Id;$p=New-TCRecordDeletePreview $stale.Root @($a.Id)
 Reject {Remove-TCDisplayRecord $active.Root $p.PreviewToken} HistoryPreviewInvalid 'Confirmation is bound to its data root'
 Reject {Remove-TCDisplayRecord $stale.Root 'not-a-token'} HistoryPreviewInvalid 'Malformed confirmation cannot change list state'
 $v=& $history {param($r,$t) OHRemovalToken -Root (OHRoot $r) -Token $t} $stale.Root $p.PreviewToken;$v.ExpiresAt=[DateTimeOffset]::UtcNow.AddMinutes(-1).ToUnixTimeSeconds()
 $expired=& $history {param($v) OHRemovalToken -Value $v} $v
 Reject {Remove-TCDisplayRecord $stale.Root $expired} HistoryPreviewStale 'Expired confirmation is rejected'
 Reject {New-TCRecordDeletePreview $stale.Root @()} HistorySelectionEmpty 'Empty selection never expands into all history'
 Reject {New-TCRecordDeletePreview $stale.Root @('Line:'+([guid]::NewGuid().ToString('D')))} HistoryInvalidId 'Line assets are excluded from record deletion'
 Reject {New-TCRecordDeletePreview $stale.Root @('DeploymentRun:'+([guid]::NewGuid().ToString('D')))} HistoryRecordMissing 'Unknown selection rejects the whole preview'

 $draft=Fixture 'discarded';$d=Run $draft;$p=New-TCDraftDiscardPreview $draft.Root @($d.Id);$null=Discard-TCDeploymentDraft $draft.Root $p.PreviewToken
 $null=Delete $draft @($d.Id)
 Check (@(Get-TCOperationHistory $draft.Root -IncludeServerRecords).Count -eq 0) 'Deleted abandoned addition cannot reappear through its paired server'
 Check ((Detail $draft $d.Id).Deleted -and (Test-TCDraftDiscarded $draft.Root $d.Id)) 'Deleting an abandoned draft preserves the separate lifecycle decision'
 $null=Restore-TCDisplayRecord $draft.Root $d.Id
 Check (-not (Detail $draft $d.Id).Deleted -and (Detail $draft $d.Id).Discarded -and (Detail $draft $d.Id).EntryAction -eq 'ViewRecord') 'Restoring a deleted draft does not resume deployment or undo abandonment'

 $legacy=Fixture 'legacy-visibility';$done=Run $legacy Complete @{Intent='Inspect';Stage='Inspect'}
 $p=New-TCHistoryClearPreview $legacy.Root @($done.Id);$null=Clear-TCOperationHistory $legacy.Root $p.PreviewToken
 Check ((Detail $legacy $done.Id).Hidden) 'Old history hiding is still readable'
 $null=Restore-TCDisplayRecord $legacy.Root $done.Id
 Check (-not (Detail $legacy $done.Id).Hidden -and @(Get-TCOperationHistory $legacy.Root).Count -eq 1) 'New restore entry also recovers rows hidden by the old API'
 $result=[pscustomobject]@{Passed=$true;Suite='RecordRemoval-0.16.1';Checks=$checks.Count;Results=@($checks.ToArray());ProductionAccess=$false;NetworkChanged=$false;RemoteChanges=$false;PowerShellVersion=[string]$PSVersionTable.PSVersion}
 if($ReportPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($result|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($true)))}
 $result|ConvertTo-Json -Depth 8
}finally{
 $full=[IO.Path]::GetFullPath($workspace);$boundary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if(-not $full.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notmatch '^tc-removal-0161-[a-f0-9]{32}$'){throw 'Fixture cleanup rejected'}
 if(Test-Path -LiteralPath $full){Remove-Item -LiteralPath $full -Recurse -Force}
}
