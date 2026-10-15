#requires -Version 5.1
[CmdletBinding()]param([string]$SourceDirectory=(Join-Path $PSScriptRoot '..'),[string]$ReportPath='')
$ErrorActionPreference='Stop';Set-StrictMode -Version 2.0
$workspace=Join-Path ([IO.Path]::GetTempPath()) ('tc-center-016-'+[guid]::NewGuid().ToString('N'))
$checks=New-Object 'Collections.Generic.List[string]'
function Check {param([bool]$Value,[string]$Name) if(-not $Value){throw ('Center regression failed: '+$Name)};$checks.Add($Name)}
function SafePath {param([string]$Path) $p=[IO.Path]::GetFullPath($Path);if(-not $p.StartsWith($workspace+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Fixture path escaped'};return $p}
Import-Module (Join-Path $SourceDirectory 'DeploymentStore.psm1') -Force -DisableNameChecking
$module=Import-Module (Join-Path $SourceDirectory 'OperationHistory.psm1') -Force -PassThru -DisableNameChecking
$null=New-TCDDirectory $workspace
function WriteFixture {param([string]$Path,$Value) Write-TCDJson (SafePath $Path) $Value}
function ReadFixture {param([string]$Path) Read-TCDJson (SafePath $Path)}
function Hash {param([string]$Path) (Get-FileHash -LiteralPath (SafePath $Path) -Algorithm SHA256).Hash}
function Inventory {param([string]$Root) (@(Get-ChildItem -LiteralPath (SafePath $Root) -Recurse -File|Sort-Object FullName|ForEach-Object {$_.FullName+':'+(Hash $_.FullName)}) -join '|')}
function Fixture {param([string]$Name,[switch]$Verified)
 $root=Join-Path $workspace $Name;$null=New-TCDDirectory $root;$id=[guid]::NewGuid().ToString('D')
 $server=[pscustomobject]@{LocalRecordId=$id;RecordState='Active';Name='同名服务器';Connection=@{Host='192.0.2.11';Port=22;User='root';IdentityFile=''};RemoteOwnerId=$null;NodeId=$null;ServerPublicKey=$null;PinnedHostKey=$null;LinkedNodeIds=@();SourceJobIds=@();ArchivedTasks=@();CreatedAtUtc=[DateTime]::UtcNow.ToString('o')}
 if($Verified){$server.RemoteOwnerId=[guid]::NewGuid().ToString('D');$server.NodeId=[guid]::NewGuid().ToString('D');$server.ServerPublicKey='S'*43+'='}
 WriteFixture (Join-Path $root 'servers\registry.json') @{SchemaVersion=1;Revision=1;Servers=@($server)}
 [pscustomobject]@{Root=$root;Server=$server}
}
function Run {param($Fixture,[string]$Stage='PrepareAccess',[string]$Status='WaitingUser',$Extras=@{})
 $id=[guid]::NewGuid().ToString('D');$value=[ordered]@{SchemaVersion=1;RunId=$id;Revision=1;Name='一次添加';Intent='New';ServerRecordId=$Fixture.Server.LocalRecordId;Stage=$Stage;Status=$Status;CreatedAtUtc=[DateTime]::UtcNow.ToString('o');UpdatedAtUtc=[DateTime]::UtcNow.ToString('o')}
 foreach($key in $Extras.Keys){$value[$key]=$Extras[$key]};$path=Join-Path $Fixture.Root ('deployments\runs\'+$id+'\state.json');WriteFixture $path $value
 [pscustomobject]@{Id=('DeploymentRun:'+$id);SourceId=$id;Path=$path;Value=$value}
}
function Items {param($Center) @($Center.AttentionItems)+@($Center.ContinueItems)+@($Center.DraftItems)+@($Center.PreparedItems)+@($Center.AvailableServers)}
function Prepared {param($Fixture)
 $lineId=[guid]::NewGuid().ToString('D');$requestId=[guid]::NewGuid().ToString('D');$client='C'*43+'='
 $dir=Join-Path $Fixture.Root ('Product\nodes\'+$lineId);$cfg=Join-Path $dir 'candidate.json';$mp=Join-Path $dir 'manifest.json';WriteFixture $cfg @{FixtureOnly=$true}
 $manifest=[ordered]@{SchemaVersion=1;node_id=$lineId;TCLineId=$lineId;TCManagedNodeId=$lineId;SyntaxValidated=$true;CandidatePath=$cfg;CandidateSHA256=(Hash $cfg);ServerPublicKey=$Fixture.Server.ServerPublicKey;ClientPublicKey=$client};WriteFixture $mp $manifest
 $profiles=@()
 foreach($mode in @('Udp','Tcp')){
  $pdir=Join-Path $Fixture.Root ('Product\lines\'+$lineId+'\profiles\'+$mode);$pc=Join-Path $pdir 'candidate.json';$pm=Join-Path $pdir 'manifest.json';WriteFixture $pc @{FixtureOnly=$true;Mode=$mode}
  $doc=$manifest|ConvertTo-Json|ConvertFrom-Json;$doc.CandidatePath=$pc;$doc.CandidateSHA256=Hash $pc;$doc|Add-Member NoteProperty TCProfileId $mode;WriteFixture $pm $doc
  $profiles+=,[pscustomobject]@{Id=$mode;Revision=1;PreparationState='SyntaxValidated';CandidateSHA256=(Hash $pc);ManifestPath=$pm;ManifestSHA256=(Hash $pm);Validation=@{Status='Passed';CleanupComplete=$true}}
 }
 $line=[pscustomobject]@{SchemaVersion=2;Revision=1;LineId=$lineId;SourceNodeId=$lineId;SourceManifestPath=$mp;Profiles=$profiles;SavedConnectionPreference=@{ProfileId='Udp';Binding=@{CandidateSHA256=$profiles[0].CandidateSHA256}}}
 $linePath=Join-Path $Fixture.Root ('Product\lines\'+$lineId+'\line.json');WriteFixture $linePath $line
 $indexPath=Join-Path $Fixture.Root 'Product\index.json';$nodes=@();if(Test-Path -LiteralPath $indexPath){$nodes=@((ReadFixture $indexPath).nodes)}
 WriteFixture $indexPath @{schemaVersion=1;nodes=($nodes+@(@{id=$lineId;name='已保存线路';kind='wireguard';manifestPath=$mp}))}
 $Fixture.Server.LinkedNodeIds=@($Fixture.Server.LinkedNodeIds)+@($lineId);WriteFixture (Join-Path $Fixture.Root 'servers\registry.json') @{SchemaVersion=1;Revision=2;Servers=@($Fixture.Server)}
 $run=Run $Fixture ReadyInactive Complete @{CandidateNodeId=$lineId;CandidateManifestPath=$mp;DeploymentCompleteness='Complete';MissingProtocols=@();ClientRequest=@{RequestId=$requestId;ClientPublicKey=$client};ClientResponse=@{RequestId=$requestId;ClientPublicKey=$client;ServerPublicKey=$Fixture.Server.ServerPublicKey}}
 [pscustomobject]@{Run=$run;LineId=$lineId;LinePath=$linePath}
}
& $module {
 foreach($name in @('Start-Process','Stop-Process','Get-Process','Invoke-WebRequest','Invoke-RestMethod','Get-TCLinuxJob','Get-TCLinuxRecentJobs','Start-TCDeploySession','Get-TCDeploySession','Invoke-TCDeployOperation','Set-TCServerRecord','Set-TCServerLink')){Set-Item -Path ('Function:script:'+$name) -Value {throw 'Center queries forbid actors or source writers'}}
}
try{
 $f=Fixture 'draft';$run=Run $f;$center=Get-TCDeploymentCenter $f.Root
 Check ($center.DraftItems.Count -eq 1 -and $center.DraftItems[0].Id -eq $run.Id -and $center.DraftServers.Count -eq 0) 'one draft and its provisional server render once'
 Check ($center.DraftItems[0].EntryAction -eq 'EditDraft' -and $center.DraftItems[0].TargetLabel -eq '192.0.2.11:22') 'draft entry retains its exact original run and target'
 $second=Run $f;$center=Get-TCDeploymentCenter $f.Root
 Check ($center.DraftItems.Count -eq 2 -and @($center.DraftItems.SourceId|Select-Object -Unique).Count -eq 2) 'independent same-server drafts are not silently collapsed'
 $value=ReadFixture $run.Path;$value|Add-Member NoteProperty AccessIssue @{Kind='Credentials';Code='AuthenticationFailed';Password='PRIVATE_SENTINEL'};WriteFixture $run.Path $value;$center=Get-TCDeploymentCenter $f.Root
 Check ($run.Id -in @($center.AttentionItems.Id) -and $second.Id -in @($center.DraftItems.Id)) 'login failure has a distinct attention item beside another draft'
 Check ((($center|ConvertTo-Json -Depth 20) -notmatch 'PRIVATE_SENTINEL|Password|SessionRef|ClientResponse|ServerPublicKey')) 'public center exports only safe presentation fields'
 $unknown=Run $f FutureStage WaitingUser;$center=Get-TCDeploymentCenter $f.Root
 Check (@($center.AttentionItems|Where-Object {$_.Id -eq $unknown.Id -and $_.EntryAction -eq 'ViewRecord'}).Count -eq 1) 'unknown stage is read-only rather than a default resume'
 $running=Run $f Apply Running;$center=Get-TCDeploymentCenter $f.Root
 Check (@($center.ContinueItems|Where-Object {$_.Id -eq $running.Id -and $_.EntryAction -eq 'OpenRun' -and -not $_.CanResume}).Count -eq 1) 'running task exposes progress without claiming resumability'
 $orphan=Fixture 'orphan';$jid=[guid]::NewGuid().ToString('D');$jdir=Join-Path $orphan.Root ('linux-jobs\'+$jid)
 WriteFixture (Join-Path $jdir 'job.json') @{SchemaVersion=1;JobId=$jid;Name='Linux 新服务器';Operation='Apply';Connection=$orphan.Server.Connection;CreatedAtUtc=[DateTime]::UtcNow.ToString('o')}
 WriteFixture (Join-Path $jdir 'result.json') @{SchemaVersion=1;JobId=$jid;Operation='Apply';Status='Failed';Stage='Backend';OutcomeUnknown=$true;FinishedAtUtc=[DateTime]::UtcNow.ToString('o')}
 $detail=Get-TCOperationRecordDetail $orphan.Root ('LegacyLinuxJob:'+$jid);$center=Get-TCDeploymentCenter $orphan.Root
 Check ($detail.IdentityState -eq 'Missing' -and $detail.Stage -eq 'Backend' -and $detail.EntryAction -eq 'ViewRecord' -and -not $detail.CanResume) 'orphan Backend failure has no fabricated identity repair or resume'
 Check (@($center.AttentionItems|Where-Object Id -eq $detail.Id).Count -eq 1) 'orphan action remains discoverable'
 $before=Inventory $orphan.Root;$null=Get-TCOperationRecordDetail $orphan.Root $detail.Id;$null=Get-TCDeploymentCenter $orphan.Root
 Check ((Inventory $orphan.Root) -ceq $before) 'center and detail do not create files or mutate old job results'
 $endedId=[guid]::NewGuid().ToString('D');$endedDir=Join-Path $orphan.Root ('linux-jobs\'+$endedId)
 WriteFixture (Join-Path $endedDir 'job.json') @{SchemaVersion=1;JobId=$endedId;Name='已结束的检查';Operation='Inspect';CreatedAtUtc=[DateTime]::UtcNow.ToString('o')}
 WriteFixture (Join-Path $endedDir 'result.json') @{SchemaVersion=1;JobId=$endedId;Operation='Inspect';Status='Completed';Stage='Console';OutcomeUnknown=$false;FinishedAtUtc=[DateTime]::UtcNow.ToString('o')}
 $detail=Get-TCOperationRecordDetail $orphan.Root ('LegacyLinuxJob:'+$endedId);$center=Get-TCDeploymentCenter $orphan.Root
 Check ($detail.Group -eq 'History' -and $detail.Id -notin @($center.AttentionItems.Id)) 'safe ended unbound legacy logs stay in history'
 Check ($detail.CanClear -and -not $detail.Hidden -and -not $detail.Protected) 'record detail exposes existing history-clear eligibility'
 $old=Fixture 'archived' -Verified;$old.Server.RecordState='Archived';WriteFixture (Join-Path $old.Root 'servers\registry.json') @{SchemaVersion=1;Revision=2;Servers=@($old.Server)};$oldRun=Run $old PlanReady WaitingUser @{Plan=@{PlanId=[guid]::NewGuid().ToString('D')}}
 $center=Get-TCDeploymentCenter $old.Root;$detail=Get-TCOperationRecordDetail $old.Root $oldRun.Id
 Check (@(Items $center).Count -eq 0 -and $detail.StateCode -eq 'ArchivedIdentity' -and $detail.EntryAction -eq 'ViewRecord') 'archived identity remains history and cannot create an active task'
 $fresh=Fixture 'new-generation';$fresh.Server.PinnedHostKey='SHA256:'+'F'*43;$fresh.Server|Add-Member NoteProperty Reinstall @{ConfirmedAtUtc=[DateTime]::UtcNow.ToString('o')};WriteFixture (Join-Path $fresh.Root 'servers\registry.json') @{SchemaVersion=1;Revision=2;Servers=@($fresh.Server)};$center=Get-TCDeploymentCenter $fresh.Root
 Check ($center.ContinueItems.Count -eq 1 -and $center.ContinueItems[0].StateCode -eq 'VerifiedTargetUndeployed' -and $center.ContinueItems[0].EntryAction -eq 'BeginDeployment') 'trusted fresh identity explicitly still needs deployment'
 $ready=Fixture 'ready' -Verified;$prepared=Prepared $ready;$center=Get-TCDeploymentCenter $ready.Root
 Check ($center.PreparedItems.Count -eq 1 -and $center.PreparedItems[0].LineId -eq $prepared.LineId -and $center.PreparedItems[0].EntryAction -eq 'OpenLine') 'complete preparation navigates to its exact line'
 $preview=New-TCHistoryClearPreview -Root $ready.Root -Ids @($prepared.Run.Id);$null=Clear-TCOperationHistory $ready.Root $preview.PreviewToken;$center=Get-TCDeploymentCenter $ready.Root
 Check ($center.PreparedItems.Count -eq 1 -and $center.PreparedItems[0].LineId -eq $prepared.LineId) 'hiding a completed operation retains exact saved-line navigation'
 $hiddenDetail=Get-TCOperationRecordDetail $ready.Root $prepared.Run.Id
 Check ($hiddenDetail.Hidden -and $hiddenDetail.CanClear -and -not $hiddenDetail.Protected) 'hidden record detail retains clear and restore facts'
 $null=Restore-TCOperationHistory $ready.Root $prepared.Run.Id;$value=ReadFixture $prepared.Run.Path;$value|Add-Member NoteProperty AttentionRequired $true;$value|Add-Member NoteProperty Validation @{Status='Failed'};WriteFixture $prepared.Run.Path $value;$center=Get-TCDeploymentCenter $ready.Root
 Check ($center.AttentionItems.Count -eq 1 -and $center.AttentionItems[0].Id -eq $prepared.Run.Id -and $center.PreparedItems.Count -eq 0) 'complete assets with failed checks remain an explicit attention task'
 $multi=Fixture 'multiple-lines' -Verified;$firstLine=Prepared $multi;$secondLine=Prepared $multi
 $preview=New-TCHistoryClearPreview -Root $multi.Root -Ids @($firstLine.Run.Id,$secondLine.Run.Id);$null=Clear-TCOperationHistory $multi.Root $preview.PreviewToken
 $pending=Run $multi PlanReady WaitingUser @{Plan=@{PlanId=[guid]::NewGuid().ToString('D')};Review=@{ChangeDigest='fixture'}};$center=Get-TCDeploymentCenter $multi.Root
 Check ($center.PreparedItems.Count -eq 2 -and @($center.PreparedItems.LineId|Select-Object -Unique).Count -eq 2 -and $pending.Id -in @($center.ContinueItems.Id)) 'pending work cannot hide other saved lines on the same server'
 $discard=Fixture 'discard';$discardRun=Run $discard;$now=[DateTime]::UtcNow.ToString('o')
 $entries=@(@{Id=$discardRun.Id;SourceKind='DeploymentRun';SourceId=$discardRun.SourceId;ServerRecordId=$discard.Server.LocalRecordId;Discarded=$true;UpdatedAtUtc=$now},@{Id=('ServerRecord:'+$discard.Server.LocalRecordId);SourceKind='ServerRecord';SourceId=$discard.Server.LocalRecordId;ServerRecordId=$discard.Server.LocalRecordId;Discarded=$true;UpdatedAtUtc=$now})
 WriteFixture (Join-Path $discard.Root 'deployments\draft-dispositions.json') @{SchemaVersion=1;Revision=1;Entries=$entries;Commits=@()};$center=Get-TCDeploymentCenter $discard.Root;$detail=Get-TCOperationRecordDetail $discard.Root $discardRun.Id
 Check (@(Items $center).Count -eq 0 -and $detail.Discarded -and $detail.StateCode -eq 'DraftDiscarded') 'discarded draft and empty server do not reappear on refresh'
 $value=ReadFixture $discardRun.Path;$value.Stage='Reconcile';$value.Status='OutcomeUnknown';WriteFixture $discardRun.Path $value;$center=Get-TCDeploymentCenter $discard.Root
 Check (@($center.AttentionItems|Where-Object {$_.Id -eq $discardRun.Id -and $_.Discarded -and $_.EntryAction -eq 'ViewRecord'}).Count -eq 1) 'external risk after discard resurfaces read-only'
 $unbound=Fixture 'discard-unbound';$unboundRun=Run $unbound PrepareAccess WaitingUser @{ServerRecordId=$null}
 WriteFixture (Join-Path $unbound.Root 'servers\registry.json') @{SchemaVersion=1;Revision=2;Servers=@()}
 WriteFixture (Join-Path $unbound.Root 'deployments\draft-dispositions.json') @{SchemaVersion=1;Revision=1;Entries=@(@{Id=$unboundRun.Id;SourceKind='DeploymentRun';SourceId=$unboundRun.SourceId;ServerRecordId=$null;Discarded=$true;UpdatedAtUtc=$now});Commits=@()}
 $center=Get-TCDeploymentCenter $unbound.Root;$detail=Get-TCOperationRecordDetail $unbound.Root $unboundRun.Id
 Check (@(Items $center).Count -eq 0 -and $detail.Discarded -and $detail.StateCode -eq 'DraftDiscarded') 'unbound pure-input draft accepts its null binding when discarded'
 WriteFixture (Join-Path $unbound.Root 'servers\registry.json') @{SchemaVersion=1;Revision=3;Servers=@($unbound.Server)}
 $value=ReadFixture $unboundRun.Path;$value.ServerRecordId=$unbound.Server.LocalRecordId;WriteFixture $unboundRun.Path $value
 $center=Get-TCDeploymentCenter $unbound.Root;$detail=Get-TCOperationRecordDetail $unbound.Root $unboundRun.Id
 Check (@($center.AttentionItems|Where-Object {$_.Id -eq $unboundRun.Id -and $_.EntryAction -eq 'ViewRecord'}).Count -eq 1 -and -not $detail.Discarded) 'discard marker cannot suppress a draft whose server binding changed'
 $retention=Fixture 'unrelated-retention-diagnostic';$retention.Server.PinnedHostKey='SHA256:'+'F'*43;$retention.Server|Add-Member NoteProperty Reinstall @{ConfirmedAtUtc=[DateTime]::UtcNow.ToString('o')}
 $emptyServer=$retention.Server|ConvertTo-Json -Depth 8|ConvertFrom-Json;$emptyServer.LocalRecordId=[guid]::NewGuid().ToString('D');$emptyServer.PinnedHostKey=$null;$emptyServer.Reinstall=$null
 WriteFixture (Join-Path $retention.Root 'servers\registry.json') @{SchemaVersion=1;Revision=2;Servers=@($retention.Server,$emptyServer)}
 $ended=Run $retention Inspect Complete @{SourceRunId=[guid]::NewGuid().ToString('D')}
 $badId=[guid]::NewGuid().ToString('D');$badPath=Join-Path $retention.Root ('linux-jobs\'+$badId+'\job.json');WriteFixture $badPath @{SchemaVersion=1};[IO.File]::WriteAllText((SafePath $badPath),'{invalid',(New-Object Text.UTF8Encoding($true)))
 $center=Get-TCDeploymentCenter $retention.Root;$detail=Get-TCOperationRecordDetail $retention.Root $ended.Id
 Check ($center.Diagnostics -contains 'ReferenceMetadataInvalid' -and $center.Diagnostics -notcontains 'ReferenceTargetMissing' -and $center.HistoricalDiagnostics -contains 'HistoricalReferenceTargetMissing' -and $detail.Group -eq 'History' -and -not $detail.CanClear -and $detail.Protected) 'malformed source retains protection while stale ended references are historical diagnostics'
 Check ($center.ContinueItems.Count -eq 1 -and $center.ContinueItems[0].StateCode -eq 'VerifiedTargetUndeployed' -and $center.DraftItems.Count -eq 1 -and $center.DraftItems[0].ServerRecordId -eq $emptyServer.LocalRecordId) 'unrelated invalid history cannot hide fresh-server or input-draft navigation'
 Check ($center.AttentionItems.Count -eq 1 -and $center.AttentionItems[0].Id -eq ('LegacyLinuxJob:'+$badId) -and $center.AttentionItems[0].EntryAction -eq 'ViewRecord') 'the invalid source itself still requires read-only inspection'
 $historical=Fixture 'historical-missing-reference';$historicalRun=Run $historical Inspect Complete @{SourceRunId=[guid]::NewGuid().ToString('D')}
 $center=Get-TCDeploymentCenter $historical.Root;$detail=Get-TCOperationRecordDetail $historical.Root $historicalRun.Id
 Check ($center.Diagnostics.Count -eq 0 -and $center.HistoricalDiagnostics -contains 'HistoricalReferenceTargetMissing' -and $detail.CanClear -and -not $detail.Protected -and $detail.Group -eq 'History') 'an ended summary whose source was removed does not permanently block cleanup'
 $currentReference=Fixture 'current-missing-reference';$currentRun=Run $currentReference Inspect Complete
 WriteFixture (Join-Path $currentReference.Root 'deployment.json') @{SourceRunId=[guid]::NewGuid().ToString('D')}
 $center=Get-TCDeploymentCenter $currentReference.Root;$detail=Get-TCOperationRecordDetail $currentReference.Root $currentRun.Id
 Check ($center.Diagnostics -contains 'ReferenceTargetMissing' -and $center.HistoricalDiagnostics.Count -eq 0 -and -not $detail.CanClear -and $detail.Protected) 'a missing current-connection reference still blocks destructive cleanup'
 $rollbackReference=Fixture 'rollback-missing-reference';$rollbackRun=Run $rollbackReference Inspect Complete
 WriteFixture (Join-Path $rollbackReference.Root ('connection-transactions\'+[guid]::NewGuid().ToString('N')+'.json')) @{SchemaVersion=1;Status='Preparing';Target=@{};Original=@{SourceRunId=[guid]::NewGuid().ToString('D')}}
 $center=Get-TCDeploymentCenter $rollbackReference.Root;$detail=Get-TCOperationRecordDetail $rollbackReference.Root $rollbackRun.Id
 Check ($center.Diagnostics -contains 'ReferenceTargetMissing' -and $center.HistoricalDiagnostics.Count -eq 0 -and -not $detail.CanClear -and $detail.Protected) 'a pending rollback transaction retains strict protection for its missing source'
 $bom=Fixture 'retained-bom-snapshot';$bomRun=Run $bom Inspect Complete;$snapshotPath=Join-Path $bom.Root 'retained.json';WriteFixture $snapshotPath @{SourceRunId=$bomRun.SourceId};[IO.File]::WriteAllText((SafePath $snapshotPath),[IO.File]::ReadAllText((SafePath $snapshotPath)),(New-Object Text.UTF8Encoding($true)))
 $transactionPath=Join-Path $bom.Root ('connection-transactions\'+[guid]::NewGuid().ToString('N')+'.json');$snapshot=@{Path=$snapshotPath;Exists=$true;SHA256=(Hash $snapshotPath);Bytes=[Convert]::ToBase64String([IO.File]::ReadAllBytes((SafePath $snapshotPath)))}
 WriteFixture $transactionPath @{SchemaVersion=1;Status='Completed';Target=@{};Original=@{Deployment=$snapshot}};$center=Get-TCDeploymentCenter $bom.Root;$detail=Get-TCOperationRecordDetail $bom.Root $bomRun.Id
 Check ($center.Diagnostics.Count -eq 0 -and $detail.CanClear -and $detail.DataRetentionReasons -contains 'RetainedTransactionReference') 'valid UTF-8 BOM transaction snapshots parse after their original hash is verified'
 $transaction=ReadFixture $transactionPath;$transaction.Original.Deployment.SHA256='0'*64;WriteFixture $transactionPath $transaction;$center=Get-TCDeploymentCenter $bom.Root;$detail=Get-TCOperationRecordDetail $bom.Root $bomRun.Id
 Check ($center.Diagnostics -contains 'ReferenceMetadataInvalid' -and -not $detail.CanClear) 'BOM normalization never bypasses transaction snapshot hash verification'
 $serverDetail=Get-TCOperationRecordDetail $f.Root ('ServerRecord:'+$f.Server.LocalRecordId)
 Check ($serverDetail.TaskItems.Count -eq 4 -and @($serverDetail.TaskItems.SourceId|Select-Object -Unique).Count -eq 4) 'server detail preserves every independent task'
 Check (-not $serverDetail.CanClear -and -not $serverDetail.Hidden -and $serverDetail.Protected) 'server assets never inherit operation-history clear actions'
 $null=Restore-TCOperationHistory $multi.Root $firstLine.Run.Id;$null=Restore-TCOperationHistory $multi.Root $secondLine.Run.Id
 $lineHashes=@((Hash $firstLine.LinePath),(Hash $secondLine.LinePath));$preview=New-TCRecordDeletePreview -Root $multi.Root -Ids @($firstLine.Run.Id,$secondLine.Run.Id)
 $null=Remove-TCDisplayRecord -Root $multi.Root -PreviewToken $preview.PreviewToken;$center=Get-TCDeploymentCenter $multi.Root
 Check ($center.PreparedItems.Count -eq 2 -and $pending.Id -in @($center.ContinueItems.Id)) 'record deletion preserves every saved line and independent pending task'
 Check (@($center.PreparedItems|Where-Object {$_.CanDeleteRecord -or $_.Deleted}).Count -eq 0) 'saved-line entries never inherit record deletion controls or markers'
 Check ((Hash $firstLine.LinePath) -ceq $lineHashes[0] -and (Hash $secondLine.LinePath) -ceq $lineHashes[1]) 'deleting operation rows preserves line profile bytes'
 $result=[pscustomobject]@{Passed=$true;Suite='DeploymentCenter-0.16.11';Checks=$checks.Count;PowerShellVersion=[string]$PSVersionTable.PSVersion;NetworkChanged=$false;ProductionAccess=$false;Results=@($checks.ToArray())}
 if($ReportPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($result|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($true)))}
 $result|ConvertTo-Json -Depth 8
}finally{
 $full=[IO.Path]::GetFullPath($workspace);$base=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if(-not $full.StartsWith($base,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notmatch '^tc-center-016-[a-f0-9]{32}$'){throw 'Fixture cleanup rejected'}
 Remove-Item -LiteralPath $full -Recurse -Force
}
