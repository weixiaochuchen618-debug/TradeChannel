#requires -Version 5.1
[CmdletBinding()]param([string]$SourceDirectory='',[string]$ReportPath='')
$ErrorActionPreference='Stop';Set-StrictMode -Version 2.0
if(-not $SourceDirectory){$SourceDirectory=Join-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) '..'}
$package=[IO.Path]::GetFullPath($SourceDirectory);$nonce=[guid]::NewGuid().ToString('N')
$workspace=Join-Path ([IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')) ('tc-read-view-'+$nonce)
$checks=New-Object 'Collections.Generic.List[string]';$secret='fixture-private-'+[guid]::NewGuid().ToString('N')
function Guard {param([string]$Path,[switch]$Root) $p=[IO.Path]::GetFullPath($Path).TrimEnd('\');foreach($blocked in @($env:ProgramData,[Environment]::GetFolderPath('CommonApplicationData'),'C:\ProgramData')){if($blocked){$b=[IO.Path]::GetFullPath($blocked).TrimEnd('\');if($p.Equals($b,[StringComparison]::OrdinalIgnoreCase) -or $p.StartsWith($b+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Production data is forbidden.'}}};if(-not $p.StartsWith($workspace+'\',[StringComparison]::OrdinalIgnoreCase) -and -not ($Root -and $p -ceq $workspace)){throw 'Outside owned fixture.'};return $p}
function Check {param([bool]$Value,[string]$Name) if(-not $Value){throw ('Read-view assertion failed: '+$Name)};$checks.Add($Name)}
function JWrite {param([string]$Path,$Value) Write-TCDJson (Guard $Path) $Value}
function SnapshotCount {& $history {$script:ReadViewTestSnapshotCount}}
function AssertPublic {param($Value,[string]$Name) $json=ConvertTo-Json -InputObject $Value -Depth 40 -Compress;Check ($json.IndexOf($secret,[StringComparison]::Ordinal) -lt 0 -and $json -notmatch '"(?:Context|Documents|Doc|ServersById|Files|Root|Password|PrivateKey|CredentialRef)"\s*:') $Name}
function Fixture {
 param([string]$Name)
 $root=Guard (Join-Path $workspace $Name);$serverId=[guid]::NewGuid().ToString('D');$runId=[guid]::NewGuid().ToString('D')
 $server=[pscustomobject]@{LocalRecordId=$serverId;Name='Input server';Connection=@{Host='192.0.2.60';Port=22;User='root';IdentityFile=''};RecordState='Active';OwnershipState='Unverified';LinkedNodeIds=@();SourceJobIds=@();Endpoints=@();ArchivedTasks=@();CreatedAtUtc=[DateTime]::UtcNow.ToString('o')}
 $run=[pscustomobject]@{SchemaVersion=1;RunId=$runId;Revision=1;Intent='New';Name='First input';ServerRecordId=$serverId;Status='WaitingUser';Stage='PrepareAccess';CreatedAtUtc=[DateTime]::UtcNow.ToString('o');UpdatedAtUtc=[DateTime]::UtcNow.ToString('o');AttentionRequired=$false;RecoveryRequired=$false;NetworkChanged=$false;PrivateFixture=@{Password=$secret;PrivateKey=$secret}}
 JWrite (Join-Path $root 'servers\registry.json') @{SchemaVersion=1;Revision=1;Servers=@($server)}
 $runPath=Join-Path $root ('deployments\runs\'+$runId+'\state.json');JWrite $runPath $run
 [pscustomobject]@{Root=$root;ServerId=$serverId;Id=('DeploymentRun:'+$runId);Run=$run;RunPath=$runPath}
}
$null=Guard $workspace -Root;if([IO.Directory]::Exists($workspace)){throw 'Fixture must not preexist.'}
Import-Module (Join-Path $package 'DeploymentStore.psm1') -DisableNameChecking
$null=New-TCDDirectory $workspace;[IO.File]::WriteAllText((Join-Path $workspace '.tc-fixture-owned'),$nonce)
$module=Import-Module (Join-Path $package 'DraftDisposition.psm1') -PassThru -Force -DisableNameChecking
$history=Import-Module (Join-Path $package 'OperationHistory.psm1') -PassThru -DisableNameChecking
$originalSnapshot=& $history {${function:OHSnapshot}}
& $history {
 param($Implementation)
 $script:ReadViewTestSnapshotImplementation=$Implementation;$script:ReadViewTestSnapshotCount=0
 function script:OHSnapshot {param([string]$Root,[string[]]$OwnedLocks=@()) $script:ReadViewTestSnapshotCount++;& $script:ReadViewTestSnapshotImplementation $Root $OwnedLocks}
} $originalSnapshot
try{
 $f=Fixture 'first';$sourceHash=(Get-FileHash -LiteralPath $f.RunPath -Algorithm SHA256).Hash
 $before=SnapshotCount;$center=Get-TCDeploymentReadView -Root $f.Root -View Center
 Check (((SnapshotCount)-$before) -eq 1) 'Center uses exactly one reference snapshot'
 Check (@($center.DraftItems).Count -eq 1 -and $center.DraftItems[0].Id -ceq $f.Id -and $center.DraftItems[0].CanDiscardDraft) 'Center decorates the public input item from the same snapshot'
 $before=SnapshotCount;$detail=Get-TCDeploymentReadView -Root $f.Root -View Detail -Id $f.Id
 Check (((SnapshotCount)-$before) -eq 1 -and $detail.Id -ceq $f.Id -and $detail.CanDiscardDraft) 'Detail uses exactly one snapshot and preserves draft eligibility'
 AssertPublic $center 'Center contains no raw documents, internal context or private fixture material'
 AssertPublic $detail 'Detail contains no raw documents, internal context or private fixture material'
 Check ((Get-FileHash -LiteralPath $f.RunPath -Algorithm SHA256).Hash -ceq $sourceHash) 'Read projections leave their source bytes unchanged'
 Check (-not (Get-Command Get-TCDeploymentReadView).Parameters.ContainsKey('Context') -and -not (Get-Command Get-TCDeploymentReadView).Parameters.ContainsKey('Snapshot')) 'Public read API cannot accept an external cached snapshot'

 $f.Run.Name='Changed input';$f.Run.Status='OutcomeUnknown';$f.Run.RecoveryRequired=$true;$f.Run.AttentionRequired=$true;JWrite $f.RunPath $f.Run
 $before=SnapshotCount;$changed=Get-TCDeploymentReadView -Root $f.Root -View Detail -Id $f.Id
 Check (((SnapshotCount)-$before) -eq 1 -and $changed.Name -ceq 'Changed input' -and -not $changed.CanDiscardDraft) 'A later request reads changed data and unresolved protection afresh'
 Check ($detail.Name -ceq 'First input' -and $detail.CanDiscardDraft) 'Previously returned DTO is not shared mutable request state'
 $before=SnapshotCount;$protected=New-TCDraftDiscardPreview -Root $f.Root -Ids @($f.Id)
 Check (((SnapshotCount)-$before) -eq 1 -and $protected.EligibleCount -eq 0 -and $protected.ProtectedCount -eq 1) 'Preview performs its own fresh protected-state snapshot'

 $f.Run.Status='WaitingUser';$f.Run.RecoveryRequired=$false;$f.Run.AttentionRequired=$false;JWrite $f.RunPath $f.Run
 $held=Open-TCDLock (Join-Path $f.Root ('servers\.task-'+$f.ServerId+'.lock'))
 try{$before=SnapshotCount;$busy=Get-TCDeploymentReadView -Root $f.Root -View Detail -Id $f.Id;Check (((SnapshotCount)-$before) -eq 1 -and -not $busy.CanDiscardDraft) 'Shared read snapshot still observes active task locks'}finally{$held.Dispose()}
 $before=SnapshotCount;$preview=New-TCDraftDiscardPreview -Root $f.Root -Ids @($f.Id)
 Check (((SnapshotCount)-$before) -eq 1 -and $preview.EligibleCount -eq 1) 'A subsequent preview rereads after the lock is released'
 $before=SnapshotCount;$discard=Discard-TCDeploymentDraft -Root $f.Root -PreviewToken $preview.PreviewToken
 Check (((SnapshotCount)-$before) -eq 3 -and $f.Id -in @($discard.DiscardedIds)) 'Commit retains its before-lock, locked and final fresh snapshots'
 $before=SnapshotCount;$discarded=Get-TCDeploymentReadView -Root $f.Root -View Center
 Check (((SnapshotCount)-$before) -eq 1 -and @($discarded.DraftItems).Count -eq 0) 'The next center request observes the new disposition'
 $before=SnapshotCount;$restore=Restore-TCDeploymentDraft -Root $f.Root -Id $f.Id
 Check (((SnapshotCount)-$before) -eq 2 -and $restore.Restored -and -not $restore.ApprovalsRestored) 'Restore retains its before-lock and locked fresh snapshots'
 $before=SnapshotCount;$restored=Get-TCDeploymentReadView -Root $f.Root -View Detail -Id $f.Id
 Check (((SnapshotCount)-$before) -eq 1 -and -not $restored.Discarded -and $restored.CanDiscardDraft) 'A later detail request observes restoration without stale caching'
 $other=Fixture 'second';$before=SnapshotCount;$otherView=Get-TCDeploymentReadView -Root $other.Root -View Center
 Check (((SnapshotCount)-$before) -eq 1 -and @($otherView.DraftItems).Count -eq 1 -and $otherView.DraftItems[0].Id -ceq $other.Id) 'Separate roots never share snapshot state'
 AssertPublic $restored 'Restored public detail still excludes internal source material'
 $report=[pscustomobject]@{Passed=$true;Checks=$checks.Count;Cases=@($checks);SnapshotCalls=(SnapshotCount);FixtureScope='DisposableTempOnly';ProductionDataChanged=$false;RealNetworkChanges=0;Timestamp=[DateTimeOffset]::UtcNow.ToString('o')}
 if($ReportPath){$reportRoot=[IO.Path]::GetFullPath((Join-Path (Split-Path (Split-Path $package -Parent) -Parent) 'reports\release-0.16.1')).TrimEnd('\');$reportFull=[IO.Path]::GetFullPath($ReportPath);if(-not $reportFull.StartsWith($reportRoot+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Report must stay in release-0.16.1 reports.'};[IO.File]::WriteAllText($reportFull,($report|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($true)))}
 $report
}finally{
 & $history {param($Implementation) Set-Item -LiteralPath Function:script:OHSnapshot -Value $Implementation;Remove-Variable -Name ReadViewTestSnapshotImplementation,ReadViewTestSnapshotCount -Scope Script -ErrorAction SilentlyContinue} $originalSnapshot
 $owned=Guard $workspace -Root;if([IO.File]::Exists((Join-Path $owned '.tc-fixture-owned')) -and [IO.File]::ReadAllText((Join-Path $owned '.tc-fixture-owned')) -ceq $nonce){Remove-Item -LiteralPath $owned -Recurse -Force}
}
