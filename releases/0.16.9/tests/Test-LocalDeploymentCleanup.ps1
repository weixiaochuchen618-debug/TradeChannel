#requires -Version 5.1
#requires -PSEdition Desktop
param([string]$SourceDirectory=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';Set-StrictMode -Version 2.0
$workspace=Join-Path ([IO.Path]::GetTempPath()) ('tc-cleanup-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($workspace);$checks=New-Object 'Collections.Generic.List[string]'
Import-Module (Join-Path $SourceDirectory 'DeploymentStore.psm1') -DisableNameChecking
$module=Import-Module (Join-Path $SourceDirectory 'OperationHistory.psm1') -Force -PassThru -DisableNameChecking
Import-Module (Join-Path $SourceDirectory 'ServerRegistry.psm1') -DisableNameChecking
function Check {param($Value,[string]$Label) if(-not $Value){throw ('FAIL: '+$Label)};$checks.Add($Label)}
function Reject {param([scriptblock]$Action,[string]$Code) $caught=$false;try{$null=& $Action}catch{if($_.Exception.Message -notmatch [regex]::Escape($Code)){throw};$caught=$true};Check $caught ('Reject '+$Code)}
function Put {param([string]$Path,$Value) if(-not [IO.Path]::GetFullPath($Path).StartsWith($workspace+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Fixture path escape'};Write-TCDJson $Path $Value}
function Hash {param([string]$Path) (Get-FileHash -LiteralPath $Path).Hash}
function Fixture {param([string]$Name)
 $root=New-TCDDirectory (Join-Path $workspace $Name)
 $connection=@{Host='192.0.2.10';Port=22;User='root';IdentityFile=''}
 $info=@{RemoteOwnerId=[guid]::NewGuid().ToString('D');Node=@{NodeId=[guid]::NewGuid().ToString('D');ServerPublicKey=('S'*43+'=')}}
 $server=Set-TCServerRecord -Root $root -Connection $connection -ServerInfo $info -Name '待清理服务器' -PinnedFingerprint ('SHA256:'+('A'*43))
 $other=Set-TCServerRecord -Root $root -Connection @{Host='192.0.2.10';Port=2222;User='admin';IdentityFile=''} -Name '同 IP 不同入口'
 $line=[guid]::NewGuid().ToString('D');$run=[guid]::NewGuid().ToString('D');$client='C'*43+'='
 $manifest=Join-Path $root ('Product\nodes\'+$line+'\manifest.json')
 Put $manifest @{TCLineId=$line;TCManagedNodeId=$line;ServerPublicKey=$info.Node.ServerPublicKey;ClientPublicKey=$client}
 Put (Join-Path $root ('Product\lines\'+$line+'\line.json')) @{SchemaVersion=2;LineId=$line;ServerPublicKey=$info.Node.ServerPublicKey;Profiles=@()}
 Put (Join-Path $root 'Product\index.json') @{schemaVersion=1;nodes=@(@{id=$line;name='测试线路';manifestPath=$manifest})}
 $state=@{SchemaVersion=1;RunId=$run;ServerRecordId=$server.LocalRecordId;Revision=1;Intent='New';Name='测试准备';Status='Complete';Stage='ReadyInactive';RecoveryRequired=$false;ProbeRecoveryRequired=$false;PendingOperationId=$null;DispatchIntent=$null;LastRemoteMutation=@{State='Completed';Mutating=$true};CandidateNodeId=$line;CandidateManifestPath=$manifest;CreatedAtUtc=[DateTime]::UtcNow.ToString('o');UpdatedAtUtc=[DateTime]::UtcNow.ToString('o')}
 $statePath=Join-Path $root ('deployments\runs\'+$run+'\state.json');Put $statePath $state
 $null=Set-TCServerLink -Root $root -ServerId $server.LocalRecordId -NodeId $line
 $probe=[guid]::NewGuid().ToString('D');Put (Join-Path $root ('probes\'+$probe+'\result.json')) @{NodeId=$line;CleanupComplete=$true}
 $request=[guid]::NewGuid().ToString('N');Put (Join-Path $root ('Product\jobs\'+$request+'.request.json')) @{Action='DeploymentProceed';RunId=$run;RequestId=$request}
 Put (Join-Path $root ('Product\jobs\'+$request+'.receipt.json')) @{SchemaVersion=1;Action='DeploymentProceed';RunId=$run;RequestId=$request;Status='Completed';ProcessId=0}
 Put (Join-Path $root ('Product\jobs\'+$request+'.receipt.json.partial')) @{SchemaVersion=1;Action='DeploymentProceed';RunId=$run;RequestId=$request;Status='Completed';ProcessId=0}
 $hostId=[guid]::NewGuid().ToString('D');$hostDirectory=Join-Path $root ('deployments\hosts\'+$hostId)
 Put (Join-Path $hostDirectory 'receipt.json') @{InstanceId=$hostId;RunId=[guid]::NewGuid().ToString('D');OperationId=$run;Status='Closed';ProcessId=0;Mutating=$false}
 Put (Join-Path $root 'operation-history\removed-records.json') @{SchemaVersion=1;Revision=1;Entries=@();Commits=@(@{SelectedIds=@('DeploymentRun:'+$run);DeletedIds=@('DeploymentRun:'+$run)})}
 [pscustomobject]@{Root=$root;Server=$server;Other=$other;Line=$line;Run=$run;State=$state;StatePath=$statePath;Manifest=$manifest;Request=$request;HostDirectory=$hostDirectory;Id=('ServerRecord:'+$server.LocalRecordId)}
}
try{
 Reject {Set-TCServerRecord -Root (Join-Path $workspace 'pin-only') -PinnedFingerprint ('SHA256:'+('P'*43))} 'ServerTargetMissing'
 $f=Fixture complete;$otherHash=Get-TCDDigest (Get-TCServer $f.Root $f.Other.LocalRecordId)
 $shell=[guid]::NewGuid().ToString('D');$registryPath=Join-Path $f.Root 'servers\registry.json';$registry=Read-TCDJson $registryPath
 $registry.Servers+=,[pscustomobject]@{LocalRecordId=$shell;RecordState='Active';Name='空壳';Connection=$null;RemoteOwnerId=$null;NodeId=$null;ServerPublicKey=$null;LinkedNodeIds=@();SourceJobIds=@()};Put $registryPath $registry
 $center=Get-TCDeploymentCenter $f.Root
 Check ($center.ManagedServers.Count -eq 1 -and $center.AvailableServers.Count -eq $center.ManagedServers.Count -and $center.ManagedServers[0].LocalRecordId -eq $f.Server.LocalRecordId) 'Managed server directory and entry count agree; shell and unfinished endpoint excluded'
 $connector=Set-TCServerRecord -Root $f.Root -ConnectorOnly -ServerInfo @{RemoteOwnerId=[guid]::NewGuid().ToString('D');Node=@{NodeId=[guid]::NewGuid().ToString('D');ServerPublicKey=('I'*43+'=')}} -Name '真实邀请'
 Check ((Get-TCServer $f.Root $connector.LocalRecordId).ManagementAccessState -eq 'ConnectorOnly') 'Real invitation identity remains available for its line'
 $preview=New-TCLocalDeploymentCleanupPreview $f.Root @($f.Id)
 Check ($preview.EligibleCount -eq 1 -and -not $preview.DisplayOnly -and $preview.FileCount -ge 6) 'Preview covers complete owned local assets'
 $result=Remove-TCLocalDeploymentData $f.Root $preview.PreviewToken
 Check ($result.DataDeleted -and -not (Test-Path -LiteralPath $f.StatePath) -and -not (Test-Path -LiteralPath (Split-Path $f.Manifest -Parent))) 'Commit physically removes run, client material and caches'
 Check (-not (Test-Path -LiteralPath (Join-Path $f.Root ('Product\lines\'+$f.Line))) -and @(Read-TCDJson (Join-Path $f.Root 'Product\index.json')|ForEach-Object nodes).Count -eq 0) 'Profile directory and index entry are both removed'
 Check (-not (Test-Path -LiteralPath $f.HostDirectory)) 'Closed executor caches linked only by OperationId are removed'
 Check (-not (Test-Path -LiteralPath (Join-Path $f.Root ('Product\jobs\'+$f.Request+'.receipt.json.partial')))) 'Owned interrupted receipt writes are removed with their exact request family'
 Check (@((Read-TCDJson (Join-Path $f.Root 'operation-history\removed-records.json')).Commits).Count -eq 0) 'Singleton history commit arrays are filtered without string concatenation'
 Check ((Get-TCDDigest (Get-TCServer $f.Root $f.Other.LocalRecordId)) -ceq $otherHash) 'Same IP different SSH port/account remains byte-equivalent'
 Check ((Get-TCServer $f.Root $connector.LocalRecordId).ManagementAccessState -eq 'ConnectorOnly') 'Unrelated invitation survives cleanup'
 $retry=Remove-TCLocalDeploymentData $f.Root $preview.PreviewToken;Check $retry.AlreadyApplied 'Repeated commit is idempotent'
 $fresh=Set-TCServerRecord -Root $f.Root -Connection $f.Server.Connection -Name '新的开始'
 Reject {Set-TCServerRecord -Root $f.Root -Id $f.Server.LocalRecordId -Connection $f.Server.Connection} ServerMissing
 Check ($fresh.LocalRecordId -ne $f.Server.LocalRecordId -and -not $fresh.PinnedHostKey -and -not $fresh.CredentialRef -and $fresh.SourceJobIds.Count -eq 0) 'Same endpoint gets fresh identity, pin and credential state'
 Check (@(Get-TCDeploymentCenter $f.Root|ForEach-Object ContinueRuns|Where-Object SourceId -eq $f.Run).Count -eq 0) 'Deleted operation cannot be rediscovered'
 $f=Fixture stale;$preview=New-TCLocalDeploymentCleanupPreview $f.Root @($f.Id)
 Put (Join-Path (Split-Path $f.StatePath -Parent) 'new-cache.json') @{Changed=$true}
 Reject {Remove-TCLocalDeploymentData $f.Root $preview.PreviewToken} CleanupPreviewStale
 Check (Test-Path -LiteralPath $f.StatePath) 'Stale preview leaves original data intact'
 $f=Fixture active;Put (Join-Path $f.Root 'deployment.json') @{LineId=$f.Line;ManifestPath=$f.Manifest}
 $preview=New-TCLocalDeploymentCleanupPreview $f.Root @($f.Id);Check (@($preview.Blocked|Where-Object Code -eq CurrentLine).Count -gt 0 -and -not $preview.PreviewToken) 'Current connection cannot be deleted'
 $f=Fixture unresolved;$f.State.LastRemoteMutation.State='Dispatched';Put $f.StatePath $f.State
 $preview=New-TCLocalDeploymentCleanupPreview $f.Root @($f.Id);Check (@($preview.Blocked|Where-Object Code -eq Unresolved).Count -gt 0) 'Unresolved remote transaction is retained'
 $f=Fixture running;$lease=Open-TCDLock (Join-Path $f.Root ('servers\.task-'+$f.Server.LocalRecordId+'.lock'))
 try{$preview=New-TCLocalDeploymentCleanupPreview $f.Root @($f.Id);Check (@($preview.Blocked|Where-Object Code -eq ExecutorActive).Count -gt 0) 'Active server executor lease prevents cleanup'}finally{$lease.Dispose()}
 $f=Fixture receipt;$rp=Join-Path $f.Root ('Product\jobs\'+$f.Request+'.receipt.json');$r=Read-TCDJson $rp;$r.Status='OutcomeUnknown';Put $rp $r
 $preview=New-TCLocalDeploymentCleanupPreview $f.Root @($f.Id);Check (@($preview.Blocked|Where-Object Code -eq ReceiptUnresolved).Count -gt 0) 'Bound uncertain UI receipt is retained'
 $f=Fixture shared;$credential=[guid]::NewGuid().ToString('D');$null=Set-TCServerRecord $f.Root -Id $f.Server.LocalRecordId -CredentialRef $credential;$null=Set-TCServerRecord $f.Root -Id $f.Other.LocalRecordId -CredentialRef $credential
 Put (Join-Path $f.Root ('credentials\'+$credential+'.json')) @{Protected='fixture'}
 $preview=New-TCLocalDeploymentCleanupPreview $f.Root @($f.Id);$null=Remove-TCLocalDeploymentData $f.Root $preview.PreviewToken
 Check (Test-Path -LiteralPath (Join-Path $f.Root ('credentials\'+$credential+'.json'))) 'Shared credential survives and is disclosed in preview'
 Check ($preview.Preserved -contains '另一台服务器仍引用的共享登录凭据') 'Shared retention is explicit'
 $f=Fixture retired;$jobId=[guid]::NewGuid().ToString('D');$job=@{SchemaVersion=1;JobId=$jobId;Operation='Authorize';Connection=$f.Server.Connection;CreatedAtUtc=[DateTime]::UtcNow.AddDays(-2).ToString('o')}
 Put (Join-Path $f.Root ('linux-jobs\'+$jobId+'\job.json')) $job
 Put (Join-Path $f.Root ('linux-jobs\'+$jobId+'\result.json')) @{SchemaVersion=1;JobId=$jobId;Operation='Authorize';Status='Failed';OutcomeUnknown=$true;FinishedAtUtc=[DateTime]::UtcNow.AddDays(-2).ToString('o')}
 $registryPath=Join-Path $f.Root 'servers\registry.json';$registry=Read-TCDJson $registryPath;$old=@($registry.Servers|Where-Object LocalRecordId -eq $f.Server.LocalRecordId)[0];$replacement=$old|ConvertTo-Json -Depth 30|ConvertFrom-Json
 $replacement.LocalRecordId=[guid]::NewGuid().ToString('D');$when=[DateTime]::UtcNow.AddDays(-1).ToString('o');$old.RecordState='Archived';$old.ArchivedAtUtc=$when;$old.ReplacedByServerId=$replacement.LocalRecordId;$old.ArchivedTasks=@(@{Kind='Legacy';Id=$jobId;Digest=(Get-TCDDigest $job)})
 $replacement.Reinstall=@{PreviousServerId=$old.LocalRecordId;ConfirmedAtUtc=$when;ChangeDigest=('a'*64)};$replacement.LinkedNodeIds=@();$registry.Servers=@($old,$replacement,$f.Other);Put $registryPath $registry
 $preview=New-TCLocalDeploymentCleanupPreview $f.Root @('ServerRecord:'+$replacement.LocalRecordId)
 Check ($preview.EligibleCount -eq 1 -and $preview.ServerCount -eq 2) 'Confirmed reset retires only the exact digest-bound old task; both identities are disclosed'
 $job.CreatedAtUtc=[DateTime]::UtcNow.ToString('o');Put (Join-Path $f.Root ('linux-jobs\'+$jobId+'\job.json')) $job
 $preview=New-TCLocalDeploymentCleanupPreview $f.Root @('ServerRecord:'+$replacement.LocalRecordId)
 Check (@($preview.Blocked|Where-Object Code -eq Unresolved).Count -gt 0) 'Changed archived task cannot borrow reset evidence'
 $f=Fixture wrongroot;$preview=New-TCLocalDeploymentCleanupPreview $f.Root @($f.Id);$otherFixture=Fixture tokenother
 Reject {Remove-TCLocalDeploymentData $otherFixture.Root $preview.PreviewToken} CleanupPreviewInvalid
 $f=Fixture failedprobe;$probePath=@(Get-ChildItem -LiteralPath (Join-Path $f.Root 'probes') -Directory)[0].FullName
 Put (Join-Path $probePath 'result.json') @{NodeId=$f.Line;CleanupComplete=$false}
 $preview=New-TCLocalDeploymentCleanupPreview $f.Root @($f.Id);Check (@($preview.Blocked|Where-Object Code -eq ProbeCleanup).Count -gt 0) 'Unreleased local probe stays protected independently of remote retirement'
 $f=Fixture rollback;$hash=Hash $f.StatePath;$registryHash=Hash (Join-Path $f.Root 'servers\registry.json');$preview=New-TCLocalDeploymentCleanupPreview $f.Root @($f.Id)
 & $module {$script:MoveCount=0;function script:LCMove {param($From,$To) $script:MoveCount++;if($script:MoveCount -eq 3){throw 'InjectedMoveFailure'};[IO.File]::Move($From,$To)}}
 Reject {Remove-TCLocalDeploymentData $f.Root $preview.PreviewToken} CleanupRolledBack
 & $module {function script:LCMove {param($From,$To) [IO.File]::Move($From,$To)}}
 Check ((Hash $f.StatePath) -ceq $hash -and (Hash (Join-Path $f.Root 'servers\registry.json')) -ceq $registryHash) 'Mid-cleanup failure rolls back source and registry exactly'
 $f=Fixture interrupted;$registryPath=Join-Path $f.Root 'servers\registry.json';$registryHash=Hash $registryPath
 & $module {param($Root)
  $id=[guid]::NewGuid().ToString('D');$source=Join-Path $Root 'servers\registry.json';$original=LCRead $Root $source;$hash=(Get-FileHash $source).Hash
  $changed=$original|ConvertTo-Json -Depth 30|ConvertFrom-Json;$changed.Servers=@();$base=Split-Path (LCJournalPath $Root $id) -Parent;$stash=New-TCDDirectory (Join-Path $base 'stash')
  $journal=@{SchemaVersion=1;Id=$id;RootDigest=(Get-TCDDigest $Root.ToLowerInvariant());UserSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;Status='Preparing';TokenDigest='fixture';Items=@(@{Path=$source;Hash=$hash;Stash='000000.stash';Replace=$true;Value=$changed});Result=@{DataDeleted=$false}}
  Write-TCDJson (LCJournalPath $Root $id) $journal;[IO.File]::Move($source,(Join-Path $stash '000000.stash'));Write-TCDJson $source $changed
 } $f.Root
 Reject {Set-TCServerRecord -Root $f.Root -Connection $f.Server.Connection} CleanupRecoveryRequired
 $recovery=Repair-TCLocalDeploymentCleanup $f.Root
 Check ($recovery.RecoveredCount -eq 1 -and (Hash $registryPath) -ceq $registryHash) 'Interrupted transaction recovery restores exact original registry'
 $f=Fixture traversal;$dir=Split-Path $f.StatePath -Parent;$outside=New-TCDDirectory (Join-Path $workspace outside);Put (Join-Path $outside 'keep.json') @{Keep=$true}
 $junction=Join-Path $dir 'redirect';$null=New-Item -ItemType Junction -Path $junction -Target $outside
 try{Reject {New-TCLocalDeploymentCleanupPreview $f.Root @($f.Id)} UnsafePath;Check (Test-Path -LiteralPath (Join-Path $outside 'keep.json')) 'Reparse point cannot erase external files'}finally{[IO.Directory]::Delete($junction,$false)}
 [pscustomobject]@{Passed=$checks.Count;Checks=$checks.ToArray();RemoteActors=0;Workspace=$workspace}|ConvertTo-Json -Depth 4
}catch{ Write-Output $_.ScriptStackTrace; throw }finally{
 # Fixture ownership and every descendant are checked before recursive cleanup.
 $full=[IO.Path]::GetFullPath($workspace);if(-not $full.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -cnotmatch '^tc-cleanup-[a-f0-9]{32}$'){throw 'Unsafe fixture cleanup'}
 $unsafe=@(Get-ChildItem -LiteralPath $full -Recurse -Force|Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint});if(-not $unsafe.Count){Remove-Item -LiteralPath $full -Recurse -Force}
}
