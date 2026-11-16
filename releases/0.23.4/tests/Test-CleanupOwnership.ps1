#requires -Version 5.1
#requires -PSEdition Desktop
[CmdletBinding()]param([string]$SourceDirectory=(Split-Path $PSScriptRoot -Parent),[string]$ReportPath)
$ErrorActionPreference='Stop';Set-StrictMode -Version 2.0
$work=Join-Path ([IO.Path]::GetTempPath()) ('tc-cleanup-ownership-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($work);$checks=New-Object 'Collections.Generic.List[string]';$failure=$null
Import-Module (Join-Path $SourceDirectory 'DeploymentStore.psm1') -DisableNameChecking
Import-Module (Join-Path $SourceDirectory 'ServerRegistry.psm1') -DisableNameChecking
$module=Import-Module (Join-Path $SourceDirectory 'OperationHistory.psm1') -DisableNameChecking -PassThru
Import-Module (Join-Path $SourceDirectory 'DeploymentFlow.psm1') -DisableNameChecking
function Put {param([string]$Path,$Value)
 if(-not [IO.Path]::GetFullPath($Path).StartsWith($work+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Fixture path escape'}
 Write-TCDJson $Path $Value
}
function Check {param($Condition,[string]$Name) if(-not $Condition){throw $Name};$checks.Add($Name)}
function Hash {param($Path)(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash}
function Reject {param([scriptblock]$Action,[string]$Code) $caught=$false;try{$null=& $Action}catch{if($_.Exception.Message -notmatch [regex]::Escape($Code)){throw};$caught=$true};Check $caught ('Reject '+$Code)}
function RunRecord {param([string]$RunId,[string]$ServerId)
 [ordered]@{SchemaVersion=1;RunId=$RunId;ServerRecordId=$ServerId;Revision=1;Intent='New';Status='Complete';Stage='ReadyInactive';CreatedAtUtc=[DateTimeOffset]::UtcNow.ToString('o');UpdatedAtUtc=[DateTimeOffset]::UtcNow.ToString('o')}
}
function Node {param([string]$Root,[string]$Id)
 $mp=Join-Path $Root ('Product\nodes\'+$Id+'\manifest.json');$key=Join-Path (Split-Path $mp) 'device.key';Put $key @{PrivateFixtureMaterial=$Id}
 Put $mp @{TCLineId=$Id;TCManagedNodeId=$Id;ServerPublicKey=('S'*43+'=');ClientPublicKey=('C'*43+'=');SyntaxValidated=$true}
 Put (Join-Path $Root ('Product\lines\'+$Id+'\line.json')) @{SchemaVersion=2;LineId=$Id;Profiles=@();SourceManifestPath=$mp;ServerPublicKey=('S'*43+'=');SavedPreference=@{Mode='Udp';Revision=7}}
 [pscustomobject]@{id=$Id;name='Existing line';kind='wireguard';endpoint='192.0.2.10:51820';manifestPath=$mp;registeredAt=[DateTimeOffset]::UtcNow.ToString('o');status='CandidateOnly'}
}
function Fixture {param([string]$Name,[switch]$Shared)
 $root=Join-Path $work $Name;$server=Set-TCServerRecord -Root $root -Connection @{Host='192.0.2.10';Port=22;User='root';IdentityFile=''} -Name 'Fixture' -ServerInfo @{RemoteOwnerId=[guid]::NewGuid().ToString('D');Node=@{NodeId=[guid]::NewGuid().ToString('D');ServerPublicKey=('S'*43+'=')}}
 $line=[guid]::NewGuid().ToString('D');$node=Node $root $line
 Put (Join-Path $root 'Product\index.json') @{schemaVersion=1;nodes=@($node);tradeDomains=@('example.com')};$null=Set-TCServerLink -Root $root -ServerId $server.LocalRecordId -NodeId $line
 $a=[guid]::NewGuid().ToString('D');$state=RunRecord $a $server.LocalRecordId;$state.CandidateNodeId=$line;$state.CandidateManifestPath=$node.manifestPath
 $statePath=Join-Path $root ('deployments\runs\'+$a+'\state.json');Put $statePath $state
 $request=Join-Path $root ('deployments\runs\'+$a+'\client');$sharedPath=Join-Path $request 'public.request.json';Put $sharedPath @{RequestId=[guid]::NewGuid().ToString('D');ClientPublicKey=('C'*43+'=')}
 $otherPath='';$otherId=''
 if($Shared){$otherId=[guid]::NewGuid().ToString('D');$b=RunRecord $otherId $server.LocalRecordId;$b.Stage='PrepareAccess';$b.Status='WaitingUser';$b.RequestDirectory=$request;$b.ReusedRequestSourceRunId=$a;$b.ClientRequest=@{ClientPublicKey=('C'*43+'=')};$otherPath=Join-Path $root ('deployments\runs\'+$otherId+'\state.json');Put $otherPath $b}
 [pscustomobject]@{Root=$root;Server=$server;Line=$line;Node=$node;RunId=$a;State=$state;StatePath=$statePath;Shared=$sharedPath;OtherState=$otherPath;OtherId=$otherId}
}
try{
 foreach($variant in @('no-old-task','old-task','active','aliases','same-server')){
  $f=Fixture ('existing-'+$variant)
  if($variant -eq 'no-old-task'){$oldTask=[IO.Path]::GetFullPath((Split-Path $f.StatePath));if(-not $oldTask.StartsWith($work+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe fixture path'};Remove-Item -LiteralPath $oldTask -Recurse -Force}
  if($variant -eq 'active'){Put (Join-Path $f.Root 'deployment.json') @{LineId=$f.Line;ManifestPath=$f.Node.manifestPath};Put (Join-Path $f.Root 'runtime.json') @{State='Connected';LineId=$f.Line;ManifestPath=$f.Node.manifestPath;OwnershipKnown=$true}}
  if($variant -in @('aliases','same-server')){
   $other=[guid]::NewGuid().ToString('D');$otherNode=Node $f.Root $other;$index=Read-TCDJson (Join-Path $f.Root 'Product\index.json');$index.nodes+=,$otherNode;Put (Join-Path $f.Root 'Product\index.json') $index;$null=Set-TCServerLink -Root $f.Root -ServerId $f.Server.LocalRecordId -NodeId $other
   if($variant -eq 'aliases'){$lp=Join-Path $f.Root ('Product\lines\'+$f.Line+'\line.json');$line=Read-TCDJson $lp;$line|Add-Member NoteProperty AliasIds @($other);Put $lp $line}
  }
  $protect=@(Get-ChildItem -LiteralPath (Join-Path $f.Root Product) -Recurse -File|Where-Object {$_.Name -notlike '*.lock'}|ForEach-Object {[pscustomobject]@{Path=$_.FullName;Hash=(Hash $_.FullName)}})
  $run=New-TCDeploymentRun -Root $f.Root -Intent Existing -ServerId $f.Server.LocalRecordId -ExistingNodeId $f.Line -Name 'Add transport'
  $preview=New-TCLocalDeploymentCleanupPreview -Root $f.Root -Ids @('DeploymentRun:'+$run.RunId) -Scope DeploymentTask
  Check ($preview.PreviewToken -and $preview.PlanVersion -eq 3 -and $preview.LineCount -eq 0 -and $preview.RetainedLineIds -contains $f.Line) ('Existing '+$variant+' preview retains input line explicitly')
  $result=Remove-TCLocalDeploymentData -Root $f.Root -PreviewToken $preview.PreviewToken
  Check ($result.DataDeleted -and -not [IO.File]::Exists((Join-Path $f.Root ('deployments\runs\'+$run.RunId+'\state.json')))) ('Existing '+$variant+' task removal completes')
  Check (@($protect|Where-Object {-not [IO.File]::Exists($_.Path) -or (Hash $_.Path) -cne $_.Hash}).Count -eq 0) ('Existing '+$variant+' manifest, index, defaults and private material preserve exact bytes')
 }
 $f=Fixture published;$before=Hash $f.Node.manifestPath;$preview=New-TCLocalDeploymentCleanupPreview $f.Root @('DeploymentRun:'+$f.RunId);$result=Remove-TCLocalDeploymentData $f.Root $preview.PreviewToken
 Check ($result.LineCount -eq 0 -and (Hash $f.Node.manifestPath) -ceq $before) 'Published legacy line survives task scope'
 $preview=New-TCLocalDeploymentCleanupPreview $f.Root @('Line:'+$f.Line);$result=Remove-TCLocalDeploymentData $f.Root $preview.PreviewToken
 Check ($result.LineCount -eq 1 -and -not [IO.File]::Exists($f.Node.manifestPath)) 'Published line remains removable through exact Line scope'
 foreach($kind in @('proof','self-asserted','preexisting')){
  $f=Fixture ('candidate-'+$kind);$requestId=[guid]::NewGuid().ToString('D');$m=Read-TCDJson $f.Node.manifestPath;$m|Add-Member NoteProperty ExportSHA256 ('A'*64);Put $f.Node.manifestPath $m
  $f.State.Status='Failed';$f.State.Stage='MaterializeCandidate';$f.State.ClientRequest=@{RequestId=$requestId;ClientPublicKey=('C'*43+'=')};$f.State.ClientResponse=@{ServerPublicKey=('S'*43+'=')};$f.State.ResourceRelations=@{Version=1;InputLineIds=@();OwnedCandidateIds=@($f.Line);PublishedLineIds=@();SharedSourceRefs=@()}
  if($kind -ne 'self-asserted'){$f.State.CandidateTransaction=@{State='Imported';RequestId=$requestId;ConfigHash=('A'*64);NodeId=$f.Line;BeforeNodeIds=$(if($kind -eq 'preexisting'){@($f.Line)}else{@()})}}
  Put $f.StatePath $f.State;$preview=New-TCLocalDeploymentCleanupPreview $f.Root @('DeploymentRun:'+$f.RunId);$result=Remove-TCLocalDeploymentData $f.Root $preview.PreviewToken
  Check ([IO.File]::Exists($f.Node.manifestPath) -eq ($kind -ne 'proof')) ('Candidate '+$kind+' enforces transaction proof independent of self-reported ownership')
 }
 $f=Fixture shared-commit -Shared;$before=Hash $f.Shared;$other=Hash $f.OtherState;$preview=New-TCLocalDeploymentCleanupPreview $f.Root @('Line:'+$f.Line)
 Check ($preview.RetainedItems.Count -eq 1 -and $preview.RetainedItems[0].Hash -ceq $before -and $preview.RetainedItems[0].ReferenceIds -contains ('DeploymentRun:'+$f.OtherId)) 'PlanVersion 3 binds shared source hash and exact outside reference'
 $result=Remove-TCLocalDeploymentData $f.Root $preview.PreviewToken
 Check ($result.DataDeleted -and $result.RetainedItems.Count -eq 1 -and (Hash $f.Shared) -ceq $before -and (Hash $f.OtherState) -ceq $other -and -not [IO.File]::Exists($f.Node.manifestPath)) 'Shared source survives real successful cleanup while target material is removed'
 Check ([IO.File]::Exists((Join-Path (Split-Path $f.StatePath) '.run.lock'))) 'Shared source parent retains its own exact run lease file'
 Check (@(Get-TCOperationHistory $f.Root|Where-Object Id -ceq ('DeploymentRun:'+$f.RunId)).Count -eq 0) 'Completed cleanup receipt prevents a retained source directory from resurfacing as a broken task'
 Put (Join-Path (Split-Path $f.StatePath) 'unexpected-after-cleanup.json') @{Untracked=$true}
 Check (@(Get-TCOperationHistory $f.Root|Where-Object Id -ceq ('DeploymentRun:'+$f.RunId)).Count -eq 1) 'Untracked residual data is not hidden by a historical cleanup receipt'
 [IO.File]::Delete((Join-Path (Split-Path $f.StatePath) 'unexpected-after-cleanup.json'))
 $again=Remove-TCLocalDeploymentData $f.Root $preview.PreviewToken;Check ($again.AlreadyApplied -and (Hash $f.Shared) -ceq $before) 'Repeated shared cleanup only reads the completed receipt'
 foreach($change in @('unknown-file','shared-bytes','reference-revision')){
  $f=Fixture ('stale-'+$change) -Shared;$before=Hash $f.Node.manifestPath;$preview=New-TCLocalDeploymentCleanupPreview $f.Root @('Line:'+$f.Line)
  switch($change){'unknown-file'{Put (Join-Path (Split-Path $f.StatePath) 'new.json') @{New=$true}} 'shared-bytes'{Put $f.Shared @{Changed=$true}} 'reference-revision'{$d=Read-TCDJson $f.OtherState;$d.Revision++;Put $f.OtherState $d}}
  Reject {Remove-TCLocalDeploymentData $f.Root $preview.PreviewToken} CleanupPreviewStale
  Check ((Hash $f.Node.manifestPath) -ceq $before) ('Stale '+$change+' preview never begins destructive moves')
 }
 $moveDefinition=& $module {(Get-Item Function:LCMove).ScriptBlock.ToString()}
 foreach($change in @('unexpected-file','unexpected-lock','move-failure')){
  $f=Fixture ('during-'+$change) -Shared;$before=Hash $f.Node.manifestPath;$stateHash=Hash $f.StatePath;$sharedHash=Hash $f.Shared;$registryHash=Hash (Join-Path $f.Root 'servers\registry.json');$preview=New-TCLocalDeploymentCleanupPreview $f.Root @('Line:'+$f.Line)
  & $module {param($Root,$Kind)
   $script:FixtureMoveCount=0;$script:FixtureMoveRoot=$Root;$script:FixtureMoveKind=$Kind
   function script:LCMove {param($From,$To)
    $script:FixtureMoveCount++;[IO.File]::Move($From,$To)
    if($script:FixtureMoveCount -eq 1){
     if($script:FixtureMoveKind -eq 'move-failure'){throw 'InjectedMidCleanupFailure'}
     $leaf=if($script:FixtureMoveKind -eq 'unexpected-lock'){'unexpected.lock'}else{'unexpected.json'}
     Write-TCDJson (Join-Path $script:FixtureMoveRoot $leaf) @{New=$true}
    }
   }
  } (Split-Path $f.StatePath) $change
  try{Reject {Remove-TCLocalDeploymentData $f.Root $preview.PreviewToken} CleanupRolledBack}finally{& $module {param($Definition) Set-Item Function:script:LCMove ([scriptblock]::Create($Definition))} $moveDefinition}
  Check ((Hash $f.Node.manifestPath) -ceq $before -and (Hash $f.StatePath) -ceq $stateHash -and (Hash $f.Shared) -ceq $sharedHash -and (Hash (Join-Path $f.Root 'servers\registry.json')) -ceq $registryHash) ('During '+$change+' rollback restores original files and references')
  $recovery=Repair-TCLocalDeploymentCleanup $f.Root;Check ($recovery.RecoveredCount -eq 0) ('During '+$change+' repeat recovery is idempotent')
 }
 $f=Fixture retained-change -Shared;$before=Hash $f.Node.manifestPath;$preview=New-TCLocalDeploymentCleanupPreview $f.Root @('Line:'+$f.Line)
 & $module {param($Path)$script:FixtureRetainedPath=$Path;$script:FixtureMoved=$false;function script:LCMove {param($From,$To)[IO.File]::Move($From,$To);if(-not $script:FixtureMoved){$script:FixtureMoved=$true;Write-TCDJson $script:FixtureRetainedPath @{ExternalEdit=$true}}}} $f.Shared
 try{Reject {Remove-TCLocalDeploymentData $f.Root $preview.PreviewToken} CleanupRolledBack}finally{& $module {param($Definition) Set-Item Function:script:LCMove ([scriptblock]::Create($Definition))} $moveDefinition}
 Check ((Hash $f.Node.manifestPath) -ceq $before -and (Read-TCDJson $f.Shared).ExternalEdit) 'Unexpected shared-file mutation rolls back deletion without overwriting the new shared value'
 $f=Fixture shared-interrupted -Shared;$before=Hash $f.Node.manifestPath;$stateHash=Hash $f.StatePath;$sharedHash=Hash $f.Shared;$preview=New-TCLocalDeploymentCleanupPreview $f.Root @('Line:'+$f.Line)
 $rollbackDefinition=& $module {(Get-Item Function:LCRollback).ScriptBlock.ToString()}
 & $module {function script:LCMove {param($From,$To)[IO.File]::Move($From,$To);throw 'InjectedJournalInterruption'};function script:LCRollback {param($Root,$Journal)throw 'InjectedProcessLossBeforeRollback'}}
 try{Reject {Remove-TCLocalDeploymentData $f.Root $preview.PreviewToken} CleanupRecoveryRequired}finally{& $module {param($Move,$Rollback)Set-Item Function:script:LCMove ([scriptblock]::Create($Move));Set-Item Function:script:LCRollback ([scriptblock]::Create($Rollback))} $moveDefinition $rollbackDefinition}
 Check (@(Get-TCLocalCleanupPending $f.Root).Count -eq 1) 'Interrupted shared cleanup leaves an explicit durable pending journal'
 $recovery=Repair-TCLocalDeploymentCleanup $f.Root
 Check ($recovery.RecoveredCount -eq 1 -and (Hash $f.Node.manifestPath) -ceq $before -and (Hash $f.StatePath) -ceq $stateHash -and (Hash $f.Shared) -ceq $sharedHash) 'Interrupted PlanVersion 3 cleanup restores original Items/stash while preserving shared files'
 Check ((Repair-TCLocalDeploymentCleanup $f.Root).RecoveredCount -eq 0) 'Repeated PlanVersion 3 cleanup recovery is idempotent'
 $f=Fixture unknown-lock -Shared;$lock=Join-Path (Split-Path $f.StatePath) 'third-party.lock';Put $lock @{Owner='Unknown'};$before=Hash $lock;$preview=New-TCLocalDeploymentCleanupPreview $f.Root @('Line:'+$f.Line);$result=Remove-TCLocalDeploymentData $f.Root $preview.PreviewToken
 Check ((Hash $lock) -ceq $before -and @($result.RetainedItems|Where-Object Path -like '*third-party.lock').Count -eq 1) 'Preexisting unowned lock is retained explicitly instead of extension-based deletion'
}catch{$failure=$_.Exception.Message;Write-Output $_.ScriptStackTrace}
$report=[pscustomobject]@{Passed=(-not $failure);Checks=$checks.Count;Results=$checks.ToArray();Failure=$failure;SourceDirectory=$SourceDirectory;PowerShell=$PSVersionTable.PSVersion.ToString();FixtureRoot=$work;NetworkCalls=0;ProductionRootTouched=$false}
if($ReportPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 10),(New-Object Text.UTF8Encoding($true)))}
$report|ConvertTo-Json -Depth 10
if(-not $failure){$full=[IO.Path]::GetFullPath($work);if(-not $full.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -cnotmatch '^tc-cleanup-ownership-[a-f0-9]{32}$'){throw 'Unsafe fixture cleanup'};Remove-Item -LiteralPath $full -Recurse -Force}else{exit 1}
