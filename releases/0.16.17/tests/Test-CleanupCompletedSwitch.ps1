#requires -Version 5.1
#requires -PSEdition Desktop
[CmdletBinding()]param([string]$SourceDirectory=(Split-Path $PSScriptRoot -Parent),[Parameter(Mandatory=$true)][string]$ReportPath,[switch]$ExpectLegacyDefect)
$ErrorActionPreference='Stop';$env:PSModulePath=Join-Path $PSHOME 'Modules'
# Reuse the private-root, exact Worker invocation and two independent line
# fixtures. All persisted contents below are synthetic, never a production copy.
$base=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Test-CleanupObservation.ps1'),[Text.Encoding]::UTF8)
$start=$base.IndexOf("Import-Module (Join-Path")
$end=$base.IndexOf("try{`r`n "+'$f=Fixture;');if($end -lt 0){$end=$base.IndexOf("try{`n "+'$f=Fixture;')}
if($start -lt 0 -or $end -lt $start){throw 'Observation fixture boundaries changed'}
. ([scriptblock]::Create($base.Substring($start,$end-$start)))
$ct=Import-Module (Join-Path $SourceDirectory 'ConnectionTransactions.psm1') -PassThru -DisableNameChecking
function Hash {param([string]$Path) (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash}
function Snapshot {param([string]$Path) & $ct {param($p) CTSnapshotFile $p} $Path}
function SwitchFixture {
 $f=Fixture;$txid=[guid]::NewGuid().ToString('N');$oldId=[guid]::NewGuid().ToString('N');$txRoot=Join-Path $f.Root 'connection-transactions'
 foreach($node in $f.Nodes){
  $mp=$node.manifestPath;$config=Join-Path (Split-Path $mp) 'config.json';Put $config @{SyntheticOnly=$true;LineId=$node.id}
  $m=Read-TCDJson $mp;$m|Add-Member NoteProperty SyntaxValidated $true;$m|Add-Member NoteProperty CandidatePath $config;$m|Add-Member NoteProperty CandidateSHA256 (Hash $config);Put $mp $m
 }
 $oldApproved=Join-Path $txRoot ($oldId+'-approved.manifest');$oldManifest=Read-TCDJson $f.TargetManifest
 $oldManifest|Add-Member NoteProperty TCTransactionId $oldId;Put $oldApproved $oldManifest
 Put (Join-Path $txRoot ($oldId+'.json')) @{SchemaVersion=1;Id=$oldId;Status='Completed';Phase='Completed';LineId=$f.Target;Target=@{ManifestPath=$f.TargetManifest};ActiveManifestPath=$oldApproved;Original=$null}
 Put (Join-Path $f.Root 'deployment.json') @{LineId=$f.Target;ManifestPath=$oldApproved;TransactionId=$oldId}
 Put (Join-Path $f.Root 'ui-preferences.json') @{NodeId=$f.Target;Mode='Rule';Exit='HongKong';Daily='Direct';Agents='Trade';ProfileId='Udp'}
 $original=@{WasRunning=$true;Observed=@{ManifestPath=$oldApproved;LineId=$f.Target};Identity=@{ManifestPath=$oldApproved};Preferences=@{NodeId=$f.Target};References=@(@{Id=$f.Target;ManifestPath=$f.TargetManifest});Manifest=(Snapshot $oldApproved);Deployment=(Snapshot (Join-Path $f.Root 'deployment.json'));Index=(Snapshot (Join-Path $f.Root 'Product\index.json'));PreferenceFile=(Snapshot (Join-Path $f.Root 'ui-preferences.json'))}
 $approved=Join-Path $txRoot ($txid+'-approved.manifest');$b=Read-TCDJson $f.Nodes[0].manifestPath
 $b|Add-Member NoteProperty TCTransactionId $txid;$b|Add-Member NoteProperty TCProfileManifestPath $f.Nodes[0].manifestPath;Put $approved $b
 $path=Join-Path $txRoot ($txid+'.json')
 $tx=@{SchemaVersion=1;Id=$txid;Root=$f.Root;JournalPath=$path;Status='Completed';Phase='Completed';LineId=$f.Active;ProfileId='Udp';SourceNodeId=$f.Active;ActiveManifestPath=$approved;ActiveManifestSHA256=(Hash $approved);Original=$original;Target=@{ManifestPath=$f.Nodes[0].manifestPath;ManifestSHA256=(Hash $f.Nodes[0].manifestPath);Manifest=$b;CandidateSHA256=$b.CandidateSHA256;CandidatePath=$b.CandidatePath};Intent=@{NodeId=$f.Active;Mode='Rule';Exit='HongKong';Daily='Direct';Agents='Trade'};TargetHash=$b.CandidateSHA256;TargetCheck=@{ExitVerified=$true;ServerAttributionVerified=$true};ConfigurationRestored=$false;ConnectionRestored=$false;RecoveryCheck=$null;Error=$null}
 Put $path $tx
 Put (Join-Path $f.Root 'deployment.json') @{LineId=$f.Active;TransactionId=$txid;ManifestPath=$approved;ProfileManifestPath=$f.Nodes[0].manifestPath}
 Put (Join-Path $f.Root 'runtime.json') @{State='Disconnected';CleanupError=$false;OwnershipKnown=$true;ManifestPath=$approved;SessionId=[guid]::NewGuid().ToString('N')}
 Put (Join-Path $f.Root 'ui-preferences.json') $tx.Intent
 $f.Overview.Running=$false;$f.Overview.StateKey='Disconnected';$f.Overview.ManifestPath=$approved
 $null=Observe-TCRuntimeState -Root $f.Root -Overview $f.Overview
 $f|Add-Member NoteProperty TransactionPath $path;$f|Add-Member NoteProperty TransactionId $txid;$f|Add-Member NoteProperty Approved $approved;$f|Add-Member NoteProperty OldApproved $oldApproved
 return $f
}
function NewPreview {param($f)
 $r=Worker $f @{Action='RecordDeletePreview';Ids=@('Line:'+$f.Target);AbandonLocalTracking=$false}
 Check $r.Ok 'Actual Worker returns a cleanup preview';return $r.Data
}
function AssertRemainingConnectable {param($f)
 $proof=& $ct {param($r,$mp)
  $script:TestAdapter={param($op,$root,$data)
   switch($op){
    'Preflight'{return $true}
    'Observe'{$d=CTRead (Join-Path $root 'deployment.json');return [pscustomobject]@{State='Stopped';OwnershipKnown=$true;ManifestPath=$d.ManifestPath}}
    'Preferences'{return CTRead (Join-Path $root 'ui-preferences.json')}
    'ValidateIntent'{return [pscustomobject]@{ExitEvidence='SyntheticOnly'}}
    default{throw ('Real operation forbidden: '+$op)}
   }
  }
  try{$baseline=CTBaseline $r '' '' $mp $null;[pscustomobject]@{Digest=$baseline.Digest;Manifest=$baseline.Original.Manifest.Path;Hash=$baseline.Target.CandidateSHA256;Pending=[bool](CTPending $r)}}finally{$script:TestAdapter=$null}
 } $f.Root $f.Approved
 Check ($proof.Digest -and $proof.Manifest -ieq $f.Approved -and -not $proof.Pending) 'Real CTBaseline accepts retained B configuration with simulated runtime observation only'
 $center=Get-TCDeploymentCenter $f.Root
 Check ($center.Diagnostics.Count -eq 0) ('No hard dangling references after cleanup: '+($center.Diagnostics -join ','))
}
try{
 $f=SwitchFixture;$preview=NewPreview $f
 if($ExpectLegacyDefect){Check (-not $preview.PreviewToken -and @($preview.Blocked|Where-Object Code -ceq CurrentTransaction).Count -eq 1) 'Old Worker blocks completed A-to-B rollback history even though B is disconnected'}
 else{
  Check ($preview.PreviewToken -and $preview.EligibleCount -eq 1) 'Completed A-to-B switch allows deleting A while B is disconnected'
  $protect=@(ProtectedHashes $f)+@([pscustomobject]@{Path=$f.Approved;Hash=(Hash $f.Approved)},[pscustomobject]@{Path=(Join-Path $f.Root 'ui-preferences.json');Hash=(Hash (Join-Path $f.Root 'ui-preferences.json'))})
  $result=Worker $f @{Action='RecordDeleteCommit';PreviewToken=$preview.PreviewToken}
  Check ($result.Ok -and $result.Data.DataDeleted) 'Actual Worker commits precise A cleanup'
  Check (-not (Test-Path $f.TargetManifest) -and -not (Test-Path $f.OldApproved)) 'A profile and obsolete approved artifact are removed'
  foreach($p in $protect){Check ((Hash $p.Path) -ceq $p.Hash) 'B runtime, preferences, profile, key and approved manifest retain their exact bytes'}
  $saved=Read-TCDJson $f.TransactionPath
  Check ($null -eq $saved.Original -and $saved.OriginalRetention.State -ceq 'RemovedByLocalCleanup' -and $saved.Status -ceq 'Completed') 'B transaction remains completed and only obsolete Original snapshots retire'
  Check (-not ([IO.File]::ReadAllText($f.TransactionPath).Contains($f.Target))) 'Retained transaction contains no deleted A identity or snapshot'
  AssertRemainingConnectable $f
  $again=Worker $f @{Action='RecordDeleteCommit';PreviewToken=$preview.PreviewToken};Check ($again.Ok -and $again.Data.AlreadyApplied) 'Repeated cleanup remains idempotent'
  foreach($case in @('NeedsRecovery','InProgress','UnknownSchema','UnknownPhase','ActiveTarget','SnapshotOnlyPending','SnapshotOnlyCompleted','RuntimeOnlyReference','CurrentChanged','AfterReplacementFailure')){
   $f=SwitchFixture;$tx=Read-TCDJson $f.TransactionPath
   switch($case){
    'NeedsRecovery'{$tx.Status='NeedsRecovery';$tx.Phase='RestoreOriginalReferences';Put $f.TransactionPath $tx}
    'InProgress'{$tx.Status='InProgress';$tx.Phase='VerifyTarget';Put $f.TransactionPath $tx}
    'UnknownSchema'{$tx.SchemaVersion=99;Put $f.TransactionPath $tx}
    'UnknownPhase'{$tx.Phase='VerifyTarget';Put $f.TransactionPath $tx}
    'ActiveTarget'{$d=Read-TCDJson (Join-Path $f.Root 'deployment.json');$d.LineId=$f.Target;$d.ManifestPath=$f.TargetManifest;Put (Join-Path $f.Root 'deployment.json') $d}
    'SnapshotOnlyPending'{$tx.Status='NeedsRecovery';$tx.Original=[pscustomobject]@{Deployment=$tx.Original.Deployment};Put $f.TransactionPath $tx}
    'SnapshotOnlyCompleted'{$tx.Original=[pscustomobject]@{Deployment=$tx.Original.Deployment};Put $f.TransactionPath $tx}
    'RuntimeOnlyReference'{$tx.SchemaVersion=99;Put $f.TransactionPath $tx;$d=Read-TCDJson (Join-Path $f.Root 'deployment.json');$d.PSObject.Properties.Remove('TransactionId');Put (Join-Path $f.Root 'deployment.json') $d}
   }
   $preview=New-TCLocalDeploymentCleanupPreview $f.Root @('Line:'+$f.Target)
   if($case -eq 'SnapshotOnlyCompleted'){
    Check ([bool]$preview.PreviewToken) 'Known completed legacy byte-only Original may retire';$null=Remove-TCLocalDeploymentData $f.Root $preview.PreviewToken;AssertRemainingConnectable $f
   }elseif($case -eq 'CurrentChanged'){
    Check ([bool]$preview.PreviewToken) 'Completed transaction has an initial preview';$tx.Status='NeedsRecovery';Put $f.TransactionPath $tx
    $rejected=$false;try{$null=Remove-TCLocalDeploymentData $f.Root $preview.PreviewToken}catch{$rejected=$_.Exception.Message -match 'CleanupPreviewStale'}
    Check ($rejected -and (Test-Path $f.TargetManifest)) 'New recovery state after preview rejects commit without deletion'
   }elseif($case -eq 'AfterReplacementFailure'){
    Check ([bool]$preview.PreviewToken) 'Replacement rollback fixture starts eligible';$before=Hash $f.TransactionPath;$aHash=Hash $f.TargetManifest
    $originalAssert=& $history {(Get-Item Function:LCAssertRetained).ScriptBlock}
    & $history {function script:LCAssertRetained {param($Plan) throw 'Injected failure after all replacements'}}
    $rejected=$false
    try{$null=Remove-TCLocalDeploymentData $f.Root $preview.PreviewToken}catch{$rejected=$_.Exception.Message -match 'CleanupRolledBack'}finally{& $history {param($s)Set-Item Function:script:LCAssertRetained $s} $originalAssert}
    Check ($rejected -and (Hash $f.TransactionPath) -ceq $before -and (Hash $f.TargetManifest) -ceq $aHash) 'Failure after snapshot retirement rolls back transaction and deleted A bytes exactly'
    Check ((Repair-TCLocalDeploymentCleanup $f.Root).RecoveredCount -eq 0) 'Already rolled-back cleanup does not repeat recovery'
   }else{Check (-not $preview.PreviewToken -and $preview.Blocked.Count -gt 0) ('Unresolved or active reference stays protected: '+$case)}
   $cases.Add([pscustomobject]@{Case=$case;Blocked=@($preview.Blocked|ForEach-Object Code)})
  }
 }
}catch{$failure=$_.Exception.Message;$stack=$_.ScriptStackTrace}
$report=[pscustomobject]@{Passed=(-not $failure);ExpectLegacyDefect=[bool]$ExpectLegacyDefect;Checks=$checks.Count;Assertions=$checks.ToArray();Cases=$cases.ToArray();Error=$failure;Stack=$stack;SourceDirectory=$SourceDirectory;PowerShellVersion=$PSVersionTable.PSVersion.ToString();ActualCleanupWorker=$true;ActualConnectionBaseline=$true;NetworkUsed=$false;ProductionWrites=0;Fixtures=$fixtures.ToArray()}
[IO.File]::WriteAllText($ReportPath,($report|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($true));$report|Select-Object Passed,Checks,ExpectLegacyDefect,Error,Stack|ConvertTo-Json
if(-not $failure){foreach($root in $fixtures){$full=[IO.Path]::GetFullPath($root);if(-not $full.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -cnotmatch '^TradeChannel-worker-fixture-[a-f0-9]{32}$' -or @(Get-ChildItem -LiteralPath $full -Recurse -Force|Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count){throw 'Unsafe fixture cleanup'};Remove-Item -LiteralPath $full -Recurse -Force}}
if($failure){exit 1}
