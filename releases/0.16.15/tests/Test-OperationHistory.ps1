#requires -Version 5.1
[CmdletBinding()]
param([string]$SourceDirectory='')
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

# No caller-supplied data Root. Every write/delete is confined to a newly owned
# disposable workspace. Production guards run BEFORE any filesystem access.
if(-not $SourceDirectory){$SourceDirectory=Join-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) '..'}
$package=[IO.Path]::GetFullPath($SourceDirectory)
$nonce=[guid]::NewGuid().ToString('N')
$tempBase=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$workspace=Join-Path $tempBase ('tc-operation-history-'+$nonce)
$production=@([Environment]::GetFolderPath('CommonApplicationData'),$env:ProgramData,'C:\ProgramData')
$checks=New-Object 'Collections.Generic.List[string]'
$junctions=New-Object 'Collections.Generic.List[string]'
$script:ActorCalls=0

function GuardFixturePath {
    param([string]$Path,[switch]$AllowRoot)
    $p=[IO.Path]::GetFullPath($Path).TrimEnd('\')
    foreach($blocked in $production){
        if($blocked){$b=[IO.Path]::GetFullPath($blocked).TrimEnd('\');if($p.Equals($b,[StringComparison]::OrdinalIgnoreCase) -or $p.StartsWith($b+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Tests block production ProgramData.'}}
    }
    if(-not $p.StartsWith($workspace+'\',[StringComparison]::OrdinalIgnoreCase) -and -not ($AllowRoot -and $p -ceq $workspace)){throw 'Tests block paths outside their owned workspace.'}
    return $p
}
function Check {param([bool]$Condition,[string]$Label) if(-not $Condition){throw ('History assertion failed: '+$Label)};$checks.Add($Label)}
function Reject {
    param([scriptblock]$Action,[string]$Code,[string]$Label)
    $caught=$false
    try{$null=& $Action}catch{if($Code -and $_.Exception.Message -notmatch [regex]::Escape($Code)){throw};$caught=$true}
    Check $caught $Label
}
function JWrite {
    param([string]$Path,$Value)
    $p=GuardFixturePath $Path;$null=New-TCDDirectory ([IO.Path]::GetDirectoryName($p));Write-TCDJson $p $Value
}
function TextWrite {
    param([string]$Path,[string]$Value)
    $p=GuardFixturePath $Path;$null=New-TCDDirectory ([IO.Path]::GetDirectoryName($p));[IO.File]::WriteAllText($p,$Value,(New-Object Text.UTF8Encoding($false)))
}
function JRead {param([string]$Path) Read-TCDJson (GuardFixturePath $Path)}
function Hash {param([string]$Path) (Get-FileHash -LiteralPath (GuardFixturePath $Path) -Algorithm SHA256).Hash}
function Clone {param($Value) ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $Value -Depth 40)}
function Inventory {
    param([string]$Root,[switch]$SourcesOnly)
    $p=GuardFixturePath $Root
    $items=@(Get-ChildItem -LiteralPath $p -Recurse -Force -ErrorAction Stop|Where-Object {
        -not $SourcesOnly -or ($_.FullName -notmatch '\\operation-history(?:\\|$)' -and $_.Name -notlike '*.lock')
    }|Sort-Object FullName|ForEach-Object {
        if($_.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Snapshot refuses reparse points.'}
        [ordered]@{Path=$_.FullName;Directory=[bool]$_.PSIsContainer;Hash=$(if(-not $_.PSIsContainer){Hash $_.FullName}else{''});Acl=(Get-Acl -LiteralPath $_.FullName -ErrorAction Stop).Sddl}
    })
    ConvertTo-Json -InputObject $items -Depth 6 -Compress
}
function NewFixture {
    param([string]$Name)
    $root=GuardFixturePath (Join-Path $workspace $Name);$null=New-TCDDirectory $root
    $serverId=[guid]::NewGuid().ToString('D');$oldId=[guid]::NewGuid().ToString('D')
    $server=[pscustomobject]@{LocalRecordId=$serverId;RecordState='Active';Name='Fixture current';Connection=@{Host='192.0.2.10';Port=22;User='root';IdentityFile=''};RemoteOwnerId=[guid]::NewGuid().ToString('D');NodeId=[guid]::NewGuid().ToString('D');ServerPublicKey=('S'*43+'=');PinnedHostKey=('SHA256:'+'F'*43);LinkedNodeIds=@();SourceJobIds=@();ArchivedTasks=@()}
    $old=[pscustomobject]@{LocalRecordId=$oldId;RecordState='Archived';Name='Fixture old';Connection=@{Host='192.0.2.10';Port=22;User='root';IdentityFile=''};RemoteOwnerId=[guid]::NewGuid().ToString('D');NodeId=[guid]::NewGuid().ToString('D');ServerPublicKey=('O'*43+'=');PinnedHostKey=('SHA256:'+'G'*43);LinkedNodeIds=@();SourceJobIds=@();ArchivedTasks=@();ReplacedByServerId=$serverId}
    JWrite (Join-Path $root 'servers\registry.json') @{SchemaVersion=1;Revision=1;Servers=@($server,$old)}
    [pscustomobject]@{Root=$root;Server=$server;Old=$old}
}
function NewRun {
    param($Fixture,[string]$Status='Complete',[string]$Stage='Inspect',$Extras=@{},[string]$Id='')
    if(-not $Id){$Id=[guid]::NewGuid().ToString('D')}
    $run=[ordered]@{SchemaVersion=1;RunId=$Id;Revision=1;Intent='Deploy';Name='Fixture operation';ServerRecordId=$Fixture.Server.LocalRecordId;Status=$Status;Stage=$Stage;CreatedAtUtc=[DateTime]::UtcNow.ToString('o');UpdatedAtUtc=[DateTime]::UtcNow.ToString('o');PendingOperationId=$null;DispatchIntent=$null;ClientRequest=$null;ClientResponse=$null;CandidateTransaction=$null;CandidateNodeId=$null;CandidateManifestPath=$null;RecoveryRequired=$false;ProbeRecoveryRequired=$false;AttentionRequired=$false;NetworkChanged=$false}
    foreach($key in $Extras.Keys){$run[$key]=$Extras[$key]}
    $path=Join-Path $Fixture.Root ('deployments\runs\'+$Id+'\state.json');JWrite $path $run
    [pscustomobject]@{Id=('DeploymentRun:'+$Id);SourceId=$Id;Path=$path;Directory=(Split-Path $path -Parent);Value=(Clone $run)}
}
function NewLegacy {
    param($Fixture,[string]$Status='Completed',[string]$Operation='Inspect',$Extras=@{},[string]$Id='')
    if(-not $Id){$Id=[guid]::NewGuid().ToString('D')}
    $dir=Join-Path $Fixture.Root ('linux-jobs\'+$Id)
    $job=[ordered]@{SchemaVersion=1;JobId=$Id;Operation=$Operation;Name='Fixture legacy';Connection=$Fixture.Server.Connection;ParentJobId='';RequestJobId='';RequestId='';PlanId='';CreatedAtUtc=[DateTime]::UtcNow.AddDays(-1).ToString('o');DeadlineUtc=[DateTime]::UtcNow.AddHours(-23).ToString('o')}
    foreach($key in $Extras.Keys){$job[$key]=$Extras[$key]}
    JWrite (Join-Path $dir 'job.json') $job
    if($Status -ne 'Pending'){JWrite (Join-Path $dir 'result.json') @{SchemaVersion=1;JobId=$Id;Operation=$Operation;Status=$Status;OutcomeUnknown=$false;Data=$null;FinishedAtUtc=[DateTime]::UtcNow.AddHours(-23).ToString('o');Stage='Console';ExitCode=0}}
    [pscustomobject]@{Id=('LegacyLinuxJob:'+$Id);SourceId=$Id;Directory=$dir;Path=(Join-Path $dir 'job.json')}
}
function NewIntent {
    param($Fixture,[string]$State='Completed',[string]$Operation='device_rename',$Extras=@{},[string]$Id='')
    if(-not $Id){$Id=[guid]::NewGuid().ToString('D')}
    $v=[ordered]@{SchemaVersion=1;Kind='TradeChannel.ManagementIntent';OperationId=$Id;ServerRecordId=$Fixture.Server.LocalRecordId;ServerBinding=@{RemoteOwnerId=$Fixture.Server.RemoteOwnerId;NodeId=$Fixture.Server.NodeId;ServerPublicKey=$Fixture.Server.ServerPublicKey};Operation=$Operation;Purpose='Fixture';Input=@{};State=$State;CreatedAtUtc=[DateTime]::UtcNow.ToString('o');UpdatedAtUtc=[DateTime]::UtcNow.ToString('o');ResultCode=$null}
    foreach($key in $Extras.Keys){$v[$key]=$Extras[$key]}
    $path=Join-Path $Fixture.Root ('deployments\management-intents\'+$Id+'.json');JWrite $path $v
    [pscustomobject]@{Id=('ManagementIntent:'+$Id);SourceId=$Id;Path=$path}
}
function Record {
    param($Fixture,[string]$Id)
    $found=@(Get-TCOperationHistory -Root $Fixture.Root -IncludeHidden|Where-Object Id -ceq $Id)
    if($found.Count -ne 1){throw 'Expected one source record.'}
    return $found[0]
}
function NewPrepared {
    param($Fixture,[switch]$Attention)
    $lineId=[guid]::NewGuid().ToString('D');$client=('C'*43+'=');$requestId=[guid]::NewGuid().ToString('D');$deviceId=[guid]::NewGuid().ToString('D')
    $sourceDir=Join-Path $Fixture.Root ('Product\nodes\'+$lineId);$sourceConfig=Join-Path $sourceDir 'dual-mode.json';$sourcePath=Join-Path $sourceDir 'manifest.json'
    JWrite $sourceConfig @{FixtureOnly=$true;Mode='Udp'}
    $source=[ordered]@{SchemaVersion=1;node_id=$lineId;TCLineId=$lineId;TCManagedNodeId=$lineId;SyntaxValidated=$true;CandidatePath=$sourceConfig;CandidateSHA256=(Hash $sourceConfig);ServerPublicKey=$Fixture.Server.ServerPublicKey;ClientPublicKey=$client;PreviousManifestPath=$null}
    JWrite $sourcePath $source
    $profiles=@()
    foreach($mode in @('Udp','Tcp')){
        $dir=Join-Path $Fixture.Root ('Product\lines\'+$lineId+'\profiles\'+$mode+'-r1');$cfg=Join-Path $dir 'dual-mode.json';$mp=Join-Path $dir 'manifest.json'
        JWrite $cfg @{FixtureOnly=$true;Mode=$mode}
        $m=Clone $source;$m.CandidatePath=$cfg;$m.CandidateSHA256=Hash $cfg;$m|Add-Member NoteProperty TCProfileId $mode;$m|Add-Member NoteProperty TCSourceManifestPath $sourcePath
        JWrite $mp $m
        $profiles+=,[pscustomobject]@{Id=$mode;Revision=1;PreparationState='SyntaxValidated';ManifestPath=$mp;ManifestSHA256=(Hash $mp);CandidateSHA256=(Hash $cfg);Validation=@{Status='Passed';CleanupComplete=$true}}
    }
    $line=[pscustomobject]@{SchemaVersion=2;Revision=1;LineId=$lineId;SourceNodeId=$lineId;SourceManifestPath=$sourcePath;SourceManifestSHA256=(Hash $sourcePath);Profiles=$profiles;PreviousProfiles=@();PreferredProfileId='Udp';ServerPublicKey=$Fixture.Server.ServerPublicKey;ClientPublicKey=$client}
    $linePath=Join-Path $Fixture.Root ('Product\lines\'+$lineId+'\line.json');JWrite $linePath $line
    JWrite (Join-Path $Fixture.Root 'Product\index.json') @{schemaVersion=1;nodes=@(@{id=$lineId;name='Fixture line';kind='wireguard';manifestPath=$sourcePath;status='CandidateOnly'})}
    $run=NewRun $Fixture 'WaitingUser' 'ReadyInactive' @{CandidateNodeId=$lineId;CandidateManifestPath=$sourcePath;DeploymentCompleteness='Complete';ClientRequest=@{RequestId=$requestId;DeviceId=$deviceId;ClientPublicKey=$client};ClientResponse=@{RequestId=$requestId;DeviceId=$deviceId;ClientPublicKey=$client;ServerPublicKey=$Fixture.Server.ServerPublicKey};AutoSavedAtUtc=[DateTime]::UtcNow.ToString('o');AttentionRequired=[bool]$Attention;ServerInfo=@{RemoteOwnerId=$Fixture.Server.RemoteOwnerId;Node=@{NodeId=$Fixture.Server.NodeId;ServerPublicKey=$Fixture.Server.ServerPublicKey}}}
    [pscustomobject]@{Run=$run;LineId=$lineId;Line=$line;LinePath=$linePath;ManifestPath=$sourcePath;Profiles=$profiles}
}

$null=GuardFixturePath $workspace -AllowRoot
if([IO.Directory]::Exists($workspace)){throw 'Disposable workspace must not preexist.'}
Import-Module (Join-Path $package 'DeploymentStore.psm1') -DisableNameChecking
$null=New-TCDDirectory $workspace
[IO.File]::WriteAllText((Join-Path $workspace '.tc-fixture-owned'),$nonce)
$module=Import-Module (Join-Path $package 'OperationHistory.psm1') -Force -PassThru -DisableNameChecking

# Make external operations fatal inside the module, including old Linux query
# helpers that mutate timeout results. A call also fails the final actor counter.
& $module {
    $script:ActorCalls=0
    foreach($name in @('Start-Process','Stop-Process','Get-Process','Invoke-WebRequest','Invoke-RestMethod','Invoke-TCDeployOperation','Start-TCDeploySession','Get-TCDeploySession','Get-TCLinuxJob','Get-TCLinuxRecentJobs','Observe-TCRuntime','Start-TCConnection','Stop-TCConnection','Set-TCServerRecord','Set-TCServerLink')){
        Set-Item -Path ('Function:script:'+$name) -Value {$script:ActorCalls++;throw 'History test forbids actors, network and source writers.'}
    }
}
try{
    Reject {GuardFixturePath (Join-Path $env:ProgramData 'TradeChannel')} 'block production' 'Production paths blocked before filesystem access'
    Reject {GuardFixturePath (Join-Path $tempBase 'existing-data')} 'outside' 'Existing external roots cannot be fixtures'
    Reject {Get-TCOperationHistory -Root '.'} 'UnsafePath' 'Module rejects relative roots'
    $empty=NewFixture 'empty';$emptyBefore=Inventory $empty.Root
    $emptyPreview=New-TCHistoryClearPreview -Root $empty.Root
    Check ($emptyPreview.EligibleCount -eq 0 -and $emptyPreview.ProtectedCount -eq 0 -and (Inventory $empty.Root) -ceq $emptyBefore) 'Empty preview is read-only and creates no locks or index'

    $f=NewFixture 'unified';$sameId=[guid]::NewGuid().ToString('D')
    $run=NewRun $f -Id $sameId;$legacy=NewLegacy $f -Id $sameId;$intent=NewIntent $f -Id $sameId
    $reg=JRead (Join-Path $f.Root 'servers\registry.json');$reg.Servers[0].SourceJobIds=@($sameId);JWrite (Join-Path $f.Root 'servers\registry.json') $reg
    $before=Inventory $f.Root;$sourceBefore=Inventory $f.Root -SourcesOnly
    $preview=New-TCHistoryClearPreview -Root $f.Root
    Check ($preview.EligibleCount -eq 3 -and $preview.ProtectedCount -eq 0) 'Three ended source kinds share one unified preview'
    Check (@($preview.Eligible.Id|Select-Object -Unique).Count -eq 3) 'SourceKind plus SourceId prevents cross-store ID collisions'
    Check ((Inventory $f.Root) -ceq $before) 'Preview does not write timeout failures, locks, visibility or actor state'
    $first=Clear-TCOperationHistory -Root $f.Root -PreviewToken $preview.PreviewToken
    Check ($first.ClearedCount -eq 3 -and -not $first.AlreadyApplied -and -not $first.DataDeleted -and -not $first.ServerChanged) 'Clear hides ended summaries only'
    Check (@(Get-TCOperationHistory -Root $f.Root).Count -eq 0 -and @(Get-TCOperationHistory -Root $f.Root -IncludeHidden).Count -eq 3) 'Both history views share visibility while retaining source records'
    Check ((Inventory $f.Root -SourcesOnly) -ceq $sourceBefore) 'Source run/job/registry data and ACLs remain byte-identical'
    $indexPath=Join-Path $f.Root 'operation-history\visibility.json';$clearedHash=Hash $indexPath
    $second=Clear-TCOperationHistory -Root $f.Root -PreviewToken $preview.PreviewToken
    Check ($second.AlreadyApplied -and $second.ClearedCount -eq 0 -and (Hash $indexPath) -ceq $clearedHash) 'Replaying the same clear is idempotent and does not rewrite metadata'
    $newPreview=New-TCHistoryClearPreview -Root $f.Root
    Check ($newPreview.EligibleCount -eq 0 -and $newPreview.HiddenCount -eq 3) 'Repeated fresh clear finds no already-hidden candidates'
    $restored=Restore-TCOperationHistory -Root $f.Root -Id $legacy.Id
    Check ($restored.Restored -and -not $restored.Record.Hidden -and @(Get-TCOperationHistory -Root $f.Root).Count -eq 1) 'Restore exposes exactly one unified source'
    $restoreHash=Hash $indexPath;$againRestore=Restore-TCOperationHistory -Root $f.Root -Id $legacy.Id
    Check ($againRestore.AlreadyVisible -and -not $againRestore.Restored -and (Hash $indexPath) -ceq $restoreHash) 'Repeated restore is idempotent'
    $afterUndoReplay=Clear-TCOperationHistory -Root $f.Root -PreviewToken $preview.PreviewToken
    Check ($afterUndoReplay.AlreadyApplied -and -not (Record $f $legacy.Id).Hidden) 'A consumed clear token cannot hide a later undo'
    Reject {Clear-TCOperationHistory -Root $empty.Root -PreviewToken $preview.PreviewToken} 'HistoryPreviewInvalid' 'Preview token binds the exact data root'
    Reject {Clear-TCOperationHistory -Root $f.Root -PreviewToken 'not-a-token'} 'HistoryPreviewInvalid' 'Malformed clear tokens rejected'
    Reject {Restore-TCOperationHistory -Root $f.Root -Id 'LegacyLinuxJob:..\outside'} 'HistoryInvalidId' 'Restore rejects path-like source IDs'

    $subset=NewFixture 'selected-scope';$one=NewRun $subset;$two=NewLegacy $subset;$three=NewIntent $subset
    $busySelected=NewRun $subset 'Running' 'Apply';$unknownSelected=NewIntent $subset 'OutcomeUnknown'
    $subsetBefore=Inventory $subset.Root;$subsetRaw=Inventory $subset.Root -SourcesOnly
    $single=New-TCHistoryClearPreview -Root $subset.Root -Ids @($one.Id)
    Check ($single.Scope -ceq 'Selected' -and $single.SelectedIds.Count -eq 1 -and $single.EligibleCount -eq 1 -and $single.Eligible[0].Id -ceq $one.Id -and $single.ProtectedCount -eq 0) 'Single-row preview counts only its exact selected scope'
    Check ((Inventory $subset.Root) -ceq $subsetBefore) 'Selected preview remains actor-free and read-only'
    $singleContext=& $module {param($r,$t) OHReadToken (OHRoot $r) $t} $subset.Root $single.PreviewToken
    Check ($singleContext.SchemaVersion -eq 2 -and $singleContext.Scope -ceq 'Selected' -and $singleContext.SelectedIds.Count -eq 1 -and $singleContext.SelectedIds[0] -ceq $one.Id -and $singleContext.CandidateIds.Count -eq 1 -and $singleContext.CandidateIds[0] -ceq $one.Id) 'Sealed token binds both the requested IDs and eligible candidate subset'
    $singleClear=Clear-TCOperationHistory -Root $subset.Root -PreviewToken $single.PreviewToken
    Check ($singleClear.Scope -ceq 'Selected' -and $singleClear.SelectedIds.Count -eq 1 -and $singleClear.ClearedCount -eq 1 -and $singleClear.ClearedIds[0] -ceq $one.Id -and (Record $subset $one.Id).Hidden -and -not (Record $subset $two.Id).Hidden -and -not (Record $subset $three.Id).Hidden) 'Single clear cannot expand to other eligible source kinds'
    $singleHash=Hash (Join-Path $subset.Root 'operation-history\visibility.json')
    $singleReplay=Clear-TCOperationHistory -Root $subset.Root -PreviewToken $single.PreviewToken
    Check ($singleReplay.AlreadyApplied -and $singleReplay.ClearedCount -eq 0 -and $singleReplay.SelectedIds[0] -ceq $one.Id -and (Hash (Join-Path $subset.Root 'operation-history\visibility.json')) -ceq $singleHash) 'Selected clear replay remains idempotent within its original scope'
    $batch=New-TCHistoryClearPreview -Root $subset.Root -Ids @($three.Id,$two.Id,$two.Id,$busySelected.Id,$unknownSelected.Id,$one.Id)
    Check ($batch.SelectedIds.Count -eq 5 -and $batch.EligibleCount -eq 2 -and $batch.ProtectedCount -eq 2 -and $batch.HiddenCount -eq 1) 'Batch selection deduplicates IDs and distinguishes hidden, eligible and protected rows'
    $batchClear=Clear-TCOperationHistory -Root $subset.Root -PreviewToken $batch.PreviewToken
    Check ($batchClear.ClearedCount -eq 2 -and $batchClear.ProtectedCount -eq 2 -and $two.Id -in $batchClear.ClearedIds -and $three.Id -in $batchClear.ClearedIds -and -not (Record $subset $busySelected.Id).Hidden -and -not (Record $subset $unknownSelected.Id).Hidden) 'Batch clear hides only selected ended rows and keeps selected active/unknown rows visible'
    Check ((Inventory $subset.Root -SourcesOnly) -ceq $subsetRaw) 'Single and batch display clearing preserve all raw source files and ACLs'
    $hiddenPreview=New-TCHistoryClearPreview -Root $subset.Root -Ids @($one.Id)
    $hiddenClear=Clear-TCOperationHistory -Root $subset.Root -PreviewToken $hiddenPreview.PreviewToken
    Check ($hiddenPreview.EligibleCount -eq 0 -and $hiddenPreview.HiddenCount -eq 1 -and $hiddenClear.ClearedCount -eq 0) 'Selecting an already-hidden row performs no new clear'
    $undoSelected=Restore-TCOperationHistory -Root $subset.Root -Id $one.Id
    Check ($undoSelected.Restored -and -not $undoSelected.Record.Hidden) 'Restore contract is unchanged after selected clearing'
    $guardHash=Hash (Join-Path $subset.Root 'operation-history\visibility.json');$missingKey='DeploymentRun:'+([guid]::NewGuid().ToString('D'))
    Reject {New-TCHistoryClearPreview -Root $subset.Root -Ids @($one.Id,$missingKey)} 'HistoryRecordMissing' 'Unknown selected source IDs reject the entire preview'
    Reject {New-TCHistoryClearPreview -Root $subset.Root -Ids @('DeploymentRun:..\outside')} 'HistoryInvalidId' 'Selected source IDs cannot be path-like aliases'
    Reject {New-TCHistoryClearPreview -Root $subset.Root -Ids @()} 'HistorySelectionEmpty' 'Explicit empty selection cannot silently become all-record clear'
    Reject {New-TCHistoryClearPreview -Root $subset.Root -Ids $null} 'HistorySelectionEmpty' 'Explicit null selection cannot silently become all-record clear'
    Check ((Hash (Join-Path $subset.Root 'operation-history\visibility.json')) -ceq $guardHash -and -not (Record $subset $one.Id).Hidden) 'Invalid selections leave visibility untouched'

    $scopedStale=NewFixture 'selected-stale';$staleOne=NewRun $scopedStale;$staleOther=NewIntent $scopedStale
    $scopePreview=New-TCHistoryClearPreview -Root $scopedStale.Root -Ids @($staleOne.Id)
    $v=JRead $staleOther.Path;$v.State='OutcomeUnknown';JWrite $staleOther.Path $v
    Reject {Clear-TCOperationHistory -Root $scopedStale.Root -PreviewToken $scopePreview.PreviewToken} 'HistoryPreviewStale' 'Unselected state changes still invalidate the full-root snapshot of a selected preview'
    Check (-not (Record $scopedStale $staleOne.Id).Hidden) 'A stale selected preview does not partially hide its target'
    $sourceIdentity=NewFixture 'selected-identity';$identityRun=NewRun $sourceIdentity
    $identityPreview=New-TCHistoryClearPreview -Root $sourceIdentity.Root -Ids @($identityRun.Id)
    $v=JRead $identityRun.Path;$v.ServerRecordId=$sourceIdentity.Old.LocalRecordId;JWrite $identityRun.Path $v
    Reject {Clear-TCOperationHistory -Root $sourceIdentity.Root -PreviewToken $identityPreview.PreviewToken} 'HistoryPreviewStale' 'Selected source identity changes require a new preview even when the stable ID remains'
    $selectedActive=NewFixture 'selected-becomes-active';$activeTarget=NewIntent $selectedActive
    $activePreview=New-TCHistoryClearPreview -Root $selectedActive.Root -Ids @($activeTarget.Id)
    $v=JRead $activeTarget.Path;$v.State='Dispatched';JWrite $activeTarget.Path $v
    Reject {Clear-TCOperationHistory -Root $selectedActive.Root -PreviewToken $activePreview.PreviewToken} 'HistoryPreviewStale' 'Selected completed-to-active transition is rechecked before commit'

    $sealed=NewFixture 'selection-seal';$sealedOne=NewRun $sealed;$sealedOther=NewLegacy $sealed
    $sealedPreview=New-TCHistoryClearPreview -Root $sealed.Root -Ids @($sealedOne.Id)
    $context=& $module {param($r,$t) OHReadToken (OHRoot $r) $t} $sealed.Root $sealedPreview.PreviewToken
    $expanded=Clone $context;$expanded.CandidateIds=@($sealedOne.Id,$sealedOther.Id)
    $expandedToken=& $module {param($v) OHProtectToken $v} $expanded
    Reject {Clear-TCOperationHistory -Root $sealed.Root -PreviewToken $expandedToken} 'HistoryPreviewInvalid' 'A sealed payload whose candidates escape SelectedIds is rejected'
    $mismatched=Clone $context;$mismatched.SelectedIds=@(@($sealedOne.Id,$sealedOther.Id)|Sort-Object)
    $mismatchedToken=& $module {param($v) OHProtectToken $v} $mismatched
    Reject {Clear-TCOperationHistory -Root $sealed.Root -PreviewToken $mismatchedToken} 'HistoryPreviewStale' 'Eligible candidates must exactly match the sealed selected scope, not a partial list'
    $corrupted=[Convert]::FromBase64String($sealedPreview.PreviewToken);$corrupted[[int]($corrupted.Length/2)]=$corrupted[[int]($corrupted.Length/2)] -bxor 1
    Reject {Clear-TCOperationHistory -Root $sealed.Root -PreviewToken ([Convert]::ToBase64String($corrupted))} 'HistoryPreviewInvalid' 'Tampered encrypted subset tokens cannot authorize a different scope'
    Check (-not (Record $sealed $sealedOne.Id).Hidden -and -not (Record $sealed $sealedOther.Id).Hidden) 'Rejected scope expansion preserves every original row'
    $all=New-TCHistoryClearPreview -Root $sealed.Root
    Check ($all.Scope -ceq 'All' -and $all.SelectedIds.Count -eq 0 -and $all.EligibleCount -eq 2) 'Omitting Ids preserves the original all-record default'
    $v1=& $module {param($r,$t) OHReadToken (OHRoot $r) $t} $sealed.Root $all.PreviewToken
    $v1.SchemaVersion=1;$v1.PSObject.Properties.Remove('Scope');$v1.PSObject.Properties.Remove('SelectedIds')
    $oldToken=& $module {param($v) OHProtectToken $v} $v1
    $legacyTokenClear=Clear-TCOperationHistory -Root $sealed.Root -PreviewToken $oldToken
    Check ($legacyTokenClear.Scope -ceq 'All' -and $legacyTokenClear.ClearedCount -eq 2) 'Already-issued v1 all-record tokens retain their original meaning'

    $p=NewFixture 'classification';$draft=NewRun $p 'Failed' 'PrepareAccess' @{AccessIssue=@{Code='AuthenticationRejected';Password='FIXTURE_PRIVATE_SENTINEL'};AttemptSessionRef=@{RunId='do-not-export';Secret='FIXTURE_PRIVATE_SENTINEL'};Credential='FIXTURE_PRIVATE_SENTINEL'}
    # AttemptSessionRef is an executor/session locator, not a deployment source ID.
    $v=JRead $draft.Path;$v.AttemptSessionRef.RunId=[guid]::NewGuid().ToString('D');JWrite $draft.Path $v
    $plan=NewRun $p 'WaitingUser' 'PlanReady' @{Plan=@{PlanId=[guid]::NewGuid().ToString('D');ChangeDigest=('A'*64);PlanExpiresAt=[DateTime]::UtcNow.AddHours(1).ToString('o')};ServerInfo=@{RemoteOwnerId=$p.Server.RemoteOwnerId;Node=@{NodeId=$p.Server.NodeId;ServerPublicKey=$p.Server.ServerPublicKey}}}
    $candidate=NewRun $p 'Failed' 'MaterializeCandidate' @{ClientRequest=@{RequestId=[guid]::NewGuid().ToString('D');ClientPublicKey=('B'*43+'=')};ClientResponse=@{ServerPublicKey=$p.Server.ServerPublicKey;ClientPublicKey=('B'*43+'=')}}
    $ready=NewPrepared $p
    $attentionExtras=@{};foreach($property in $ready.Run.Value.PSObject.Properties){if($property.Name -notin @('RunId','Status','Revision')){$attentionExtras[$property.Name]=$property.Value}}
    $attentionExtras.AttentionRequired=$true;$attentionExtras.Validation=@{Status='Failed';CleanupComplete=$true};$attentionExtras.Recommendation=@{Status='Unavailable'}
    $attention=NewRun $p 'Complete' 'ReadyInactive' $attentionExtras
    $archived=NewRun $p 'WaitingUser' 'PlanReady' @{ServerRecordId=$p.Old.LocalRecordId;Plan=@{PlanId=[guid]::NewGuid().ToString('D')}}
    $history=NewIntent $p
    $centre=Get-TCDeploymentCenter -Root $p.Root
    Check ($draft.Id -in @($centre.Drafts.Id) -and $draft.Id -notin @($centre.ContinueRuns.Id)) 'Failed input-only access attempt stays a draft'
    Check ($plan.Id -in @($centre.ContinueRuns.Id)) 'Verified environment and real plan stay in continue list'
    Check ($candidate.Id -in @($centre.ContinueRuns.Id)) 'Failed materialization with authorization stays actionable'
    Check ($ready.Run.Id -in @($centre.PreparedRuns.Id) -and $ready.Run.Id -notin @($centre.ContinueRuns.Id)) 'Verified complete inactive candidate belongs to prepared lines'
    Check ($attention.Id -in @($centre.PreparedRuns.Id) -and $attention.Id -notin @($centre.ContinueRuns.Id) -and (Record $p $attention.Id).NextAction -ceq 'ViewLine' -and -not (Record $p $attention.Id).CanClear) 'Complete prepared assets lead to line management while existing CanClear protection remains'
    Check ($archived.Id -in @($centre.History.Id) -and -not (Record $p $archived.Id).CanResume -and $p.Old.LocalRecordId -notin @($centre.Servers.ServerRecordId)) 'Archived identity cannot resume or create an effective server card'
    Check (@($centre.Cards|Where-Object ServerRecordId -ceq $p.Server.LocalRecordId).Count -eq 1) 'One server identity has at most one primary card with separate source IDs'
    Check ((Record $p $draft.Id).AccessIssue -ceq 'AuthenticationRejected') 'Safe live-poll access issue code survives in summary'
    $public=ConvertTo-Json -InputObject $centre -Depth 12 -Compress
    Check ($public -notmatch 'FIXTURE_PRIVATE_SENTINEL|AttemptSessionRef|Credential|ClientResponse|ClientRequest|ServerPublicKey|PreviewToken') 'Public centre excludes credentials, sessions, replies and crypto data'

    $partial=NewFixture 'partial';$partialReady=NewPrepared $partial
    $line=JRead $partialReady.LinePath;$line.Profiles=@($line.Profiles|Where-Object Id -eq 'Udp');JWrite $partialReady.LinePath $line
    Check ((Record $partial $partialReady.Run.Id).Classification -ceq 'Continue' -and -not (Record $partial $partialReady.Run.Id).IsPrepared) 'ReadyInactive label cannot promote incomplete protocol assets'
    Check (-not (Record $partial $partialReady.Run.Id).CanClear -and (Record $partial $partialReady.Run.Id).NextAction -cne 'ViewLine') 'Incomplete preparation remains protected and does not inherit the completed-line action'
    $pendingPrepared=NewFixture 'prepared-but-unresolved';$pendingLine=NewPrepared $pendingPrepared
    $pendingValue=JRead $pendingLine.Run.Path;$pendingValue.Status='NeedsRecovery';$pendingValue|Add-Member NoteProperty RecoveryRequired $true -Force;$pendingValue|Add-Member NoteProperty DispatchIntent @{State='OutcomeUnknown';Mutating=$true;IntentId=[guid]::NewGuid().ToString('D')} -Force;JWrite $pendingLine.Run.Path $pendingValue
    Check (-not (Record $pendingPrepared $pendingLine.Run.Id).CanClear -and (Record $pendingPrepared $pendingLine.Run.Id).Classification -ceq 'Continue' -and (Record $pendingPrepared $pendingLine.Run.Id).NextAction -ceq 'Reconcile') 'Existing prepared files do not erase unresolved-operation recovery or enable clearing'
    $spoof=NewFixture 'spoof';$spoofReady=NewPrepared $spoof
    $mp=JRead $spoofReady.Profiles[0].ManifestPath;$mp.ClientPublicKey=('X'*43+'=');JWrite $spoofReady.Profiles[0].ManifestPath $mp
    Check ((Record $spoof $spoofReady.Run.Id).ProtectionReasons -contains 'CandidateBindingInvalid') 'Mismatched profile hash/device identity blocks prepared eligibility'

    $pro=NewFixture 'protection';$ordinary=NewIntent $pro
    $active=NewRun $pro 'Running' 'Apply';$unknown=NewRun $pro 'Failed' 'Apply' @{DispatchIntent=@{IntentId=[guid]::NewGuid().ToString('D');State='Dispatched';Mutating=$true};OutcomeUnknown=$true}
    $postMutation=NewRun $pro 'Failed' 'Inspect' @{LastRemoteMutation=@{State='Completed';Mutating=$true;Operation='authorize'}}
    $cleanup=NewRun $pro 'Complete' 'Inspect' @{Validation=@{CleanupComplete=$false;OwnershipKnown=$false}}
    $unique=NewLegacy $pro 'Pending' 'Authorize' @{RequestId=[guid]::NewGuid().ToString('D')};TextWrite (Join-Path $unique.Directory 'client.key') 'FIXTURE_PRIVATE_SENTINEL'
    $current=NewRun $pro;$rollback=NewRun $pro;$txRef=NewRun $pro;$opRef=NewLegacy $pro
    $currentManifest=Join-Path $current.Directory 'manifest.json';$oldManifest=Join-Path $rollback.Directory 'manifest.json'
    JWrite $oldManifest @{SchemaVersion=1;FixtureOnly=$true}
    JWrite $currentManifest @{SchemaVersion=1;PreviousManifestPath=$oldManifest;SourceKind='LegacyLinuxJob';SourceId=$opRef.SourceId}
    JWrite (Join-Path $pro.Root 'runtime.json') @{State='Running';ManifestPath=$currentManifest;OwnershipKnown=$true;CleanupError=$false;EnginePid=987654;FixtureOnly=$true}
    JWrite (Join-Path $pro.Root 'deployment.json') @{ManifestPath=$currentManifest;ProfileManifestPath=$currentManifest;Stage='Active'}
    JWrite (Join-Path $pro.Root 'Product\index.json') @{schemaVersion=1;nodes=@(@{id=[guid]::NewGuid().ToString('D');manifestPath=$currentManifest})}
    $txManifest=Join-Path $txRef.Directory 'manifest.json';JWrite $txManifest @{SchemaVersion=1;FixtureOnly=$true}
    JWrite (Join-Path $pro.Root ('connection-transactions\'+[guid]::NewGuid().ToString('N')+'.json')) @{SchemaVersion=1;Status='NeedsRecovery';Target=@{ManifestPath=$txManifest};Original=@{Manifest=@{Path=$oldManifest;Exists=$true;SHA256=(Hash $oldManifest);Bytes=[Convert]::ToBase64String([IO.File]::ReadAllBytes($oldManifest))}}}
    $protectedPreview=New-TCHistoryClearPreview -Root $pro.Root
    Check ($ordinary.Id -in @($protectedPreview.Eligible.Id)) 'Online server does not blanket-protect unrelated finished management logs'
    foreach($id in @($active.Id,$unknown.Id,$postMutation.Id,$cleanup.Id,$unique.Id,$current.Id,$rollback.Id,$txRef.Id,$opRef.Id)){Check ($id -in @($protectedPreview.Protected.Id)) ('Dependency or unresolved state protects '+($id.Split(':')[0]))}
    Check ((Record $pro $postMutation.Id).ProtectionReasons -contains 'UnconfirmedFailure') 'Failed read-only follow-up cannot disguise an unfinished earlier mutation'
    Check ((Record $pro $current.Id).ProtectionReasons -contains 'CurrentConnectionReference') 'Actual active manifest path protects its source record'
    Check ((Record $pro $rollback.Id).ProtectionReasons -contains 'RollbackReference') 'Previous manifest and transaction rollback snapshot protect actual source'
    Check ((Record $pro $txRef.Id).ProtectionReasons -contains 'ConnectionTransactionReference') 'Connection journal protects target source even without a current line'
    Check ((Record $pro $opRef.Id).ProtectionReasons -contains 'CurrentConnectionReference') 'Structured SourceKind/SourceId in active manifest protects legacy origin'
    $proBefore=Inventory $pro.Root -SourcesOnly
    $proClear=Clear-TCOperationHistory -Root $pro.Root -PreviewToken $protectedPreview.PreviewToken
    Check ($proClear.ClearedCount -eq 1 -and (Inventory $pro.Root -SourcesOnly) -ceq $proBefore) 'Protected clear preserves actual connection, identities and all source assets'
    Check ($active.Id -in @(Get-TCOperationHistory -Root $pro.Root|ForEach-Object {$_.Id}) -and $unknown.Id -in @(Get-TCOperationHistory -Root $pro.Root|ForEach-Object {$_.Id})) 'Active and failed-but-unknown operations remain visible after clear'

    $inactive=NewFixture 'completed-inactive';$saved=NewPrepared $inactive
    $rv=JRead $saved.Run.Path;$rv.Status='Complete';$rv.AutoSavedAtUtc=[DateTime]::UtcNow.ToString('o')
    $requestDir=Join-Path $saved.Run.Directory 'client';$rv|Add-Member NoteProperty RequestDirectory $requestDir;JWrite $saved.Run.Path $rv
    TextWrite (Join-Path $requestDir 'client.key') 'FIXTURE_PRIVATE_SENTINEL';JWrite (Join-Path $requestDir 'public.request.json') $rv.ClientRequest
    JWrite (Join-Path $saved.Run.Directory 'client-response.json') $rv.ClientResponse
    $reg=JRead (Join-Path $inactive.Root 'servers\registry.json');$reg.Servers[0].LinkedNodeIds=@($saved.LineId);JWrite (Join-Path $inactive.Root 'servers\registry.json') $reg
    $pastId=[guid]::NewGuid().ToString('N')
    JWrite (Join-Path $inactive.Root ('connection-transactions\'+$pastId+'.json')) @{SchemaVersion=1;Id=$pastId;Status='Completed';Target=@{ManifestPath=$saved.ManifestPath};Original=@{Manifest=@{Path=$saved.ManifestPath;Exists=$true;SHA256=(Hash $saved.ManifestPath);Bytes=[Convert]::ToBase64String([IO.File]::ReadAllBytes($saved.ManifestPath))}}}
    $inactivePreview=New-TCHistoryClearPreview -Root $inactive.Root;$inactiveRaw=Inventory $inactive.Root -SourcesOnly
    Check ($saved.Run.Id -in @($inactivePreview.Eligible.Id) -and (Record $inactive $saved.Run.Id).DataRetentionReasons -contains 'UniqueRecoveryData') 'Completed inactive deployment can hide despite real unique key/config references'
    $savedClear=Clear-TCOperationHistory -Root $inactive.Root -PreviewToken $inactivePreview.PreviewToken
    $savedCentre=Get-TCDeploymentCenter -Root $inactive.Root
    Check ($savedClear.ClearedCount -eq 1 -and (Record $inactive $saved.Run.Id).Hidden -and (Inventory $inactive.Root -SourcesOnly) -ceq $inactiveRaw) 'Inactive clear hides row while preserving every raw key/config/profile/receipt and old transaction'
    Check ($saved.LineId -in @($savedCentre.Servers.LinkedNodeIds) -and @($savedCentre.Cards|Where-Object {$_.ServerRecordId -ceq $inactive.Server.LocalRecordId -and $_.NextAction -ceq 'ViewLine'}).Count -eq 1 -and $saved.Run.Id -in @($savedCentre.Cards.SourceIds)) 'Prepared line and all source IDs survive through Server.LinkedNodeIds after row hiding'
    JWrite (Join-Path $inactive.Root 'deployment.json') @{ManifestPath=$saved.ManifestPath;LineId=$saved.LineId;ProfileId='Udp'}
    Check (-not (Record $inactive $saved.Run.Id).Hidden -and (Record $inactive $saved.Run.Id).ProtectionReasons -contains 'CurrentConnectionReference') 'A newly current source regains visibility and protection even after past hiding'

    $reinstalled=NewFixture 'trusted-reinstalled';$reg=JRead (Join-Path $reinstalled.Root 'servers\registry.json')
    $reg.Servers[0].RemoteOwnerId=$null;$reg.Servers[0].NodeId=$null;$reg.Servers[0].ServerPublicKey=$null
    $reg.Servers[0]|Add-Member NoteProperty Reinstall @{PreviousServerId=$reinstalled.Old.LocalRecordId;ConfirmedAtUtc=[DateTime]::UtcNow.ToString('o');FreshDeviceIdentityRequired=$true}
    $plain=Clone $reg.Servers[0];$plain.LocalRecordId=[guid]::NewGuid().ToString('D');$plain.Reinstall=$null;$plain.PinnedHostKey=$null;$plain.LinkedNodeIds=@([guid]::NewGuid().ToString('D'));$reg.Servers+=,$plain
    JWrite (Join-Path $reinstalled.Root 'servers\registry.json') $reg
    $reinstallCentre=Get-TCDeploymentCenter -Root $reinstalled.Root
    Check (@($reinstallCentre.Cards|Where-Object {$_.ServerRecordId -ceq $reinstalled.Server.LocalRecordId -and $_.Classification -ceq 'Continue' -and $_.NextAction -ceq 'BeginDeployment' -and $null -eq $_.PrimaryId}).Count -eq 1) 'Trusted fresh reinstall checkpoint gets BeginDeployment card without fabricating a Run'
    Check ($plain.LocalRecordId -in @($reinstallCentre.DraftServers.ServerRecordId) -and $plain.LocalRecordId -notin @($reinstallCentre.Servers.ServerRecordId)) 'Incomplete record without a trusted checkpoint stays folded'
    Check (@($reinstallCentre.Cards|Where-Object ServerRecordId -ceq $plain.LocalRecordId).Count -eq 0) 'A stale LinkedNodeIds hint cannot manufacture a prepared line card'

    $legacyProgress=NewFixture 'legacy-progress';$legacyPlan=NewLegacy $legacyProgress 'Completed' 'Plan'
    $result=JRead (Join-Path $legacyPlan.Directory 'result.json');$result.Data=@{PlanId=[guid]::NewGuid().ToString('D');PlanExpiresAt=[DateTime]::UtcNow.AddHours(1).ToString('o')};JWrite (Join-Path $legacyPlan.Directory 'result.json') $result
    $reg=JRead (Join-Path $legacyProgress.Root 'servers\registry.json');$reg.Servers[0].SourceJobIds=@($legacyPlan.SourceId);JWrite (Join-Path $legacyProgress.Root 'servers\registry.json') $reg
    Check ((Record $legacyProgress $legacyPlan.Id).Classification -ceq 'Continue' -and -not (Record $legacyProgress $legacyPlan.Id).CanClear) 'Completed legacy Plan with a live plan is an unfinished preparation checkpoint'
    $legacyAuth=NewLegacy $legacyProgress 'Completed' 'Authorize' @{RequestId=[guid]::NewGuid().ToString('D')}
    Check ((Record $legacyProgress $legacyAuth.Id).Classification -ceq 'Continue' -and -not (Record $legacyProgress $legacyAuth.Id).CanClear) 'Completed legacy authorization awaiting local configuration remains actionable'

    $stale=NewFixture 'stale';$staleRun=NewRun $stale;$stalePreview=New-TCHistoryClearPreview -Root $stale.Root
    JWrite (Join-Path $stale.Root 'deployment.json') @{ManifestPath=(Join-Path $staleRun.Directory 'missing-manifest.json')}
    Reject {Clear-TCOperationHistory -Root $stale.Root -PreviewToken $stalePreview.PreviewToken} 'HistoryPreviewStale' 'New actual reference invalidates a stale preview before any hide'
    Check (-not (Record $stale $staleRun.Id).Hidden) 'Rejected stale preview leaves candidate visible'
    $stale2=NewFixture 'stale-status';$staleIntent=NewIntent $stale2;$statusPreview=New-TCHistoryClearPreview -Root $stale2.Root
    $iv=JRead $staleIntent.Path;$iv.State='OutcomeUnknown';JWrite $staleIntent.Path $iv
    Reject {Clear-TCOperationHistory -Root $stale2.Root -PreviewToken $statusPreview.PreviewToken} 'HistoryPreviewStale' 'Completed-to-unknown transition invalidates a stale preview'
    $stale3=NewFixture 'stale-membership';$null=NewIntent $stale3;$membershipPreview=New-TCHistoryClearPreview -Root $stale3.Root;$null=NewRun $stale3
    Reject {Clear-TCOperationHistory -Root $stale3.Root -PreviewToken $membershipPreview.PreviewToken} 'HistoryPreviewStale' 'New source membership invalidates a stale preview'
    $expiryContext=& $module {param($r,$t) OHReadToken (OHRoot $r) $t} $stale3.Root $membershipPreview.PreviewToken
    $expiryContext.ExpiresAt=[DateTimeOffset]::UtcNow.AddMinutes(-1).ToUnixTimeSeconds()
    $expired=& $module {param($v) OHProtectToken $v} $expiryContext
    Reject {Clear-TCOperationHistory -Root $stale3.Root -PreviewToken $expired} 'HistoryPreviewStale' 'Expired previews are rejected'

    $leases=NewFixture 'leases';$leaseIntent=NewIntent $leases;$leasePath=GuardFixturePath (Join-Path $leases.Root ('servers\.task-'+$leases.Server.LocalRecordId+'.lock'))
    $lease=[IO.File]::Open($leasePath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try{
        $busy=New-TCHistoryClearPreview -Root $leases.Root
        Check ((Record $leases $leaseIntent.Id).ProtectionReasons -contains 'ActiveLease' -and $busy.EligibleCount -eq 0) 'Held server task lease protects even a terminal intent'
        Reject {Clear-TCOperationHistory -Root $leases.Root -PreviewToken $busy.PreviewToken} 'HistoryBusy' 'Commit never bypasses held task leases'
    }finally{$lease.Dispose()}
    Reject {Clear-TCOperationHistory -Root $leases.Root -PreviewToken $busy.PreviewToken} 'HistoryPreviewStale' 'Lease availability changes invalidate previews'

    $old=NewFixture 'legacy-visibility';$oldJob=NewLegacy $old
    $registry=JRead (Join-Path $old.Root 'servers\registry.json');$registry.Servers[1].SourceJobIds=@($oldJob.SourceId);JWrite (Join-Path $old.Root 'servers\registry.json') $registry
    $archivePath=Join-Path $oldJob.Directory 'archive.json';JWrite $archivePath @{SchemaVersion=1;JobId=$oldJob.SourceId;Archived=$true;UpdatedAtUtc=[DateTime]::UtcNow.ToString('o')}
    $oldBefore=Inventory $old.Root -SourcesOnly
    Check ((Record $old $oldJob.Id).Hidden -and (Record $old $oldJob.Id).IdentityState -ceq 'Archived') 'Legacy archive marker maps through unified query layer'
    $undo=Restore-TCOperationHistory -Root $old.Root -Id $oldJob.Id
    Check ($undo.Restored -and -not $undo.IdentityRevalidated -and -not $undo.Record.CanResume -and $undo.Record.IdentityState -ceq 'Archived') 'Undo visibility does not revalidate archived server generation'
    Check ((Inventory $old.Root -SourcesOnly) -ceq $oldBefore -and (JRead $archivePath).Archived) 'Unified legacy restore never edits archive marker or registry identity'
    $v=JRead $archivePath;$v.UpdatedAtUtc=[DateTime]::UtcNow.AddSeconds(2).ToString('o');JWrite $archivePath $v
    Check ((Record $old $oldJob.Id).Hidden) 'A later legacy visibility change supersedes an older unified override'
    $oldActive=NewLegacy $old 'Pending';$registry=JRead (Join-Path $old.Root 'servers\registry.json');$registry.Servers[0].SourceJobIds=@($oldActive.SourceId);JWrite (Join-Path $old.Root 'servers\registry.json') $registry
    JWrite (Join-Path $oldActive.Directory 'archive.json') @{SchemaVersion=1;JobId=$oldActive.SourceId;Archived=$true}
    Check (-not (Record $old $oldActive.Id).Hidden -and (Record $old $oldActive.Id).HiddenRequested) 'Legacy hidden-but-active work is forcibly discoverable'
    Check (-not [IO.File]::Exists((Join-Path $oldActive.Directory 'result.json'))) 'History does not materialize legacy deadline failure results'

    $incomplete=NewFixture 'unknown-reference';$incompleteRun=NewRun $incomplete
    JWrite (Join-Path $incomplete.Root 'runtime.json') @{State='Running';OwnershipKnown=$false;ManifestPath=$null}
    Check ((Record $incomplete $incompleteRun.Id).ProtectionReasons -contains 'RuntimeReferenceUnknown') 'Unbound active runtime protects all possible source records'
    $bad=NewFixture 'corrupt';$badRun=NewRun $bad;TextWrite (Join-Path $bad.Root 'Product\index.json') '{ malformed'
    Check ((New-TCHistoryClearPreview -Root $bad.Root).EligibleCount -eq 0 -and (Record $bad $badRun.Id).ProtectionReasons -contains 'ReferenceMetadataInvalid') 'Corrupt reference metadata fails closed instead of guessing orphanhood'
    $escaped=NewFixture 'escaped-reference';$escapedRun=NewRun $escaped
    JWrite (Join-Path $escaped.Root 'deployment.json') @{ManifestPath=(Join-Path $empty.Root 'never-read.json')}
    Check ((New-TCHistoryClearPreview -Root $escaped.Root).EligibleCount -eq 0 -and (Record $escaped $escapedRun.Id).ProtectionReasons -contains 'UnsafeReference') 'Out-of-root manifest reference is blocked without following it'
    $missing=NewFixture 'missing-source';$missingId=[guid]::NewGuid().ToString('D');$null=New-TCDDirectory (GuardFixturePath (Join-Path $missing.Root ('deployments\runs\'+$missingId)))
    Check (@(Get-TCOperationHistory -Root $missing.Root).Count -eq 1 -and (New-TCHistoryClearPreview -Root $missing.Root).EligibleCount -eq 0) 'Incomplete source directories remain visible and protected'

    $reparse=NewFixture 'reparse';$null=NewRun $reparse;$target=GuardFixturePath (Join-Path $workspace 'junction-target');$null=New-TCDDirectory $target
    $link=GuardFixturePath (Join-Path $reparse.Root 'identities');$null=New-Item -ItemType Junction -Path $link -Target $target -ErrorAction Stop;$junctions.Add($link)
    Reject {New-TCHistoryClearPreview -Root $reparse.Root} 'UnsafePath' 'Reparse reference stores cannot escape a checked data root'
    [IO.Directory]::Delete($link,$false);$junctions.Remove($link)|Out-Null

    $actorCalls=& $module {$script:ActorCalls}
    Check ($actorCalls -eq 0) 'All preview/query/clear/restore paths are actor-free'
    foreach($file in @('OperationHistory.psm1','tests\Test-OperationHistory.ps1')){
        $bytes=[IO.File]::ReadAllBytes((Join-Path $package $file));Check ($bytes.Length -gt 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) ('Windows PowerShell UTF8 BOM: '+$file)
    }
    [pscustomobject]@{Passed=$true;Checks=$checks.Count;PowerShell=$PSVersionTable.PSVersion.ToString();ActorCalls=$actorCalls;ProductionAccess=$false;Results=@($checks.ToArray())}|ConvertTo-Json -Depth 5
}finally{
    # Delete only this run's marker-verified workspace. Never recursively delete
    # a junction; if link removal fails, leave the fixture for inspection.
    $cleanupRoot=GuardFixturePath $workspace -AllowRoot
    foreach($link in @($junctions.ToArray())){$null=GuardFixturePath $link;[IO.Directory]::Delete($link,$false)}
    $marker=Join-Path $cleanupRoot '.tc-fixture-owned'
    if($cleanupRoot -cne (Join-Path $tempBase ('tc-operation-history-'+$nonce)) -or -not [IO.File]::Exists($marker) -or [IO.File]::ReadAllText($marker) -cne $nonce){throw 'Fixture cleanup ownership check failed.'}
    Remove-Item -LiteralPath $cleanupRoot -Recurse -Force -ErrorAction Stop
}
