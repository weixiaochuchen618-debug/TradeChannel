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
 $abandonPreview=New-TCLocalDeploymentCleanupPreview $f.Root @($f.Id) -AbandonLocalTracking
 Check (-not $abandonPreview.PreviewToken -and @($abandonPreview.Blocked|Where-Object Code -eq ProbeCleanup).Count -gt 0) 'Explicit local abandonment cannot bypass unfinished local network cleanup'

 $authRoot=New-TCDDirectory (Join-Path $workspace closedauthentication);$authServer=Set-TCServerRecord -Root $authRoot -Connection @{Host='192.0.2.35';Port=22;User='root';IdentityFile=''} -Name '认证失败夹具'
 $authRun=[guid]::NewGuid().ToString('D');$authInstance=[guid]::NewGuid().ToString('D');$authHost=Join-Path $authRoot ('deployments\hosts\'+$authInstance);$authState=Join-Path $authRoot ('deployments\runs\'+$authRun+'\state.json')
 $authRef=@{RunId=$authRun;InstanceId=$authInstance;ProcessId=2147483646;StartTimeUtcTicks='1';PipeName=('TCDeploy-'+[guid]::NewGuid().ToString('N'));Root=$authHost}
 Put $authState @{SchemaVersion=1;RunId=$authRun;ServerRecordId=$authServer.LocalRecordId;Revision=5;Intent='New';Status='WaitingUser';Stage='PrepareAccess';AttemptSessionRef=$authRef;LastError=@{Code='AuthenticationFailed'};AccessIssue=@{Kind='Credentials';Code='AuthenticationFailed'};CreatedAtUtc=[DateTime]::UtcNow.ToString('o');UpdatedAtUtc=[DateTime]::UtcNow.ToString('o')}
 Put (Join-Path $authHost 'receipt.json') @{SchemaVersion=1;RunId=$authRun;InstanceId=$authInstance;ProcessId=2147483646;StartTimeUtcTicks='1';Status='Failed';Code='AuthenticationFailed';Mutating=$false}
 $authCredential=Join-Path $authRoot ('deployments\credentials\'+$authRun+'.json');Put $authCredential @{Protected='authentication-fixture-envelope'}
 $preview=New-TCLocalDeploymentCleanupPreview $authRoot @('DeploymentRun:'+$authRun)
 Check ($preview.EligibleCount -eq 1 -and -not $preview.RemoteOutcomeUnverified -and $preview.Executors.Count -eq 0) 'A closed authentication-failure attempt is an ordinary removable draft, not an executing deployment'
 $result=Remove-TCLocalDeploymentData $authRoot $preview.PreviewToken
 Check ($result.DataDeleted -and -not (Test-Path $authState) -and -not (Test-Path $authHost) -and -not (Test-Path $authCredential)) 'Removing an authentication-failure draft clears its run, closed host cache and task credential together'
 $newAuthServer=Set-TCServerRecord -Root $authRoot -Connection $authServer.Connection -Name '重新添加认证目标'
 Check ($newAuthServer.LocalRecordId -cne $authServer.LocalRecordId -and -not $newAuthServer.PinnedHostKey) 'The same failed authentication target can start with a new local identity and no old pin'

 $f=Fixture localcandidate;$f.State.Status='Failed';$f.State.Stage='MaterializeCandidate';$f.State.CandidateNodeId=$null;$f.State.CandidateManifestPath=$null
 $requestId=[guid]::NewGuid().ToString('D');$imported=[guid]::NewGuid().ToString('D');$older=[guid]::NewGuid().ToString('D');$sourceHash='a'*64
 $f.State.ClientRequest=@{RequestId=$requestId;ClientPublicKey=('C'*43+'=')};$f.State.ClientResponse=@{ServerPublicKey=('S'*43+'=')}
 $f.State.CandidateTransaction=@{State='Prepared';RequestId=$requestId;NodeId=$null;ConfigHash=$sourceHash;BeforeNodeIds=@($older)};Put $f.StatePath $f.State
 foreach($node in @($imported,$older)){Put (Join-Path $f.Root ('Product\nodes\'+$node+'\manifest.json')) @{node_id=$node;ExportSHA256=$sourceHash;ClientPublicKey=('C'*43+'=');ServerPublicKey=('S'*43+'=')}}
 $importedPath=Join-Path $f.Root ('Product\nodes\'+$imported);$olderPath=Join-Path $f.Root ('Product\nodes\'+$older)
 $keyPath=Join-Path (Split-Path $f.StatePath -Parent) 'client\client.key';Put $keyPath @{FixturePrivateMaterial=$true}
 $credentialPath=Join-Path $f.Root ('deployments\credentials\'+$f.Run+'.json');$foreignCredential=Join-Path $f.Root ('deployments\credentials\'+[guid]::NewGuid().ToString('D')+'.json')
 Put $credentialPath @{SchemaVersion=1;RunId=$f.Run;Protected='isolated-envelope'};Put $foreignCredential @{Protected='unrelated-envelope'};$foreignHash=Hash $foreignCredential
 $preview=New-TCLocalDeploymentCleanupPreview $f.Root @('DeploymentRun:'+$f.Run)
 Check ($preview.EligibleCount -eq 1 -and $preview.LocalCandidateAbandonment -and -not $preview.RemoteOutcomeUnverified -and $preview.Warnings.Code -contains 'LocalCandidateAbandonment') 'Prepared local candidate failure can be abandoned without claiming a remote unknown operation'
 Check (@($preview.Files|Where-Object Kind -ceq TaskCredential).Count -eq 1) 'Preview includes exactly the selected task credential envelope'
 $result=Remove-TCLocalDeploymentData $f.Root $preview.PreviewToken
 Check ($result.LocalCandidateAbandoned -and -not $result.RemoteRollbackConfirmed -and -not (Test-Path $keyPath) -and -not (Test-Path $credentialPath)) 'Local candidate abandonment erases private request material and task credential without reporting server rollback'
 Check (-not (Test-Path $importedPath) -and (Test-Path $olderPath)) 'Interrupted imported candidate is located by source hash and both keys while preexisting nodes are excluded'
 Check ((Hash $foreignCredential) -ceq $foreignHash -and $result.TaskCredentialsDeletedCount -eq 1) 'Other tasks retain their credentials and only one envelope was deleted'
 Check (-not @((Get-TCDeploymentCenter $f.Root).ContinueRuns|Where-Object SourceId -ceq $f.Run).Count) 'Abandoned local candidate no longer appears as an unfinished deployment'

 $f=Fixture unknownlocal;$f.State.Status='OutcomeUnknown';$f.State.Stage='Apply';$f.State.RecoveryRequired=$true;$f.State.PendingOperationId=[guid]::NewGuid().ToString('D');$f.State.LastRemoteMutation.State='Dispatched';Put $f.StatePath $f.State
 $receiptPath=Join-Path $f.Root ('Product\jobs\'+$f.Request+'.receipt.json');$receipt=Read-TCDJson $receiptPath;$receipt.Status='OutcomeUnknown';Put $receiptPath $receipt
 $unrelatedId=[guid]::NewGuid().ToString('N');$unrelatedPath=Join-Path $f.Root ('Product\jobs\'+$unrelatedId+'.receipt.json');Put $unrelatedPath @{RunId=[guid]::NewGuid().ToString('D');Status='OutcomeUnknown';ProcessId=0};$unrelatedHash=Hash $unrelatedPath
 $preview=New-TCLocalDeploymentCleanupPreview $f.Root @($f.Id)
 Check (-not $preview.PreviewToken -and $preview.RemoteOutcomeUnverified -and $preview.CanAbandonLocalTracking) 'An unknown remote result requires an explicit separate local-tracking abandonment choice'
 $preview=New-TCLocalDeploymentCleanupPreview $f.Root @($f.Id) -AbandonLocalTracking
 Check ($preview.PreviewToken -and $preview.AbandonLocalTracking -and $preview.RemoteOutcomeUnverified -and $preview.Warnings.Code -contains 'RemoteOutcomeUnverified') 'Explicit preview records unknown remote outcome and explains local-only scope'
 $result=Remove-TCLocalDeploymentData $f.Root $preview.PreviewToken
 Check ($result.AbandonedLocalTracking -and $result.RemoteOutcomeUnverified -and -not $result.RemoteRollbackConfirmed -and -not $result.RemoteChanges -and -not $result.NetworkChanged) 'Physical local cleanup never forges remote success, rollback or a network mutation'
 Check (-not (Test-Path $receiptPath) -and (Hash $unrelatedPath) -ceq $unrelatedHash) 'Only the selected request family is removed; unrelated unknown receipts survive'
 $fresh=Set-TCServerRecord -Root $f.Root -Connection $f.Server.Connection -Name '明确放弃后的新任务'
 Check ($fresh.LocalRecordId -cne $f.Server.LocalRecordId -and @(Get-TCLocalCleanupPending $f.Root).Count -eq 0) 'Abandoned remote tracking cannot block a fresh registration through an old cleanup journal'
 $outcome=Get-TCLocalDeploymentCleanupOutcome -Root $f.Root -PreviewToken $preview.PreviewToken
 Check ($outcome.Outcome -ceq 'Completed' -and -not $outcome.RemoteChanges) 'Unknown-result cleanup remains recoverable by its intent-bound completion journal'

 $f=Fixture staleexecutor;$f.State.Status='Running';$f.State.Stage='Inspect';$process=[Diagnostics.Process]::GetCurrentProcess();$instance=[guid]::NewGuid().ToString('D')
 try{$f.State.SessionRef=@{RunId=$f.Run;InstanceId=$instance;ProcessId=$process.Id;StartTimeUtcTicks=[string]($process.StartTime.ToUniversalTime().Ticks-1);PipeName=('TCDeploy-'+[guid]::NewGuid().ToString('N'));Root=(Join-Path $f.Root ('deployments\hosts\'+$instance))}}finally{$process.Dispose()};Put $f.StatePath $f.State
 Check ((Get-TCOperationRecordDetail $f.Root ('DeploymentRun:'+$f.Run)).CanDeleteRecord) 'Persisted running text and a reused PID do not permanently hide the cleanup entry'
 $preview=New-TCLocalDeploymentCleanupPreview $f.Root @($f.Id)
 Check ($preview.CanAbandonLocalTracking -and $preview.Executors.Count -eq 0 -and -not @($preview.Blocked|Where-Object Code -eq ExecutorActive).Count) 'Expired exact executor identity is treated as an unknown result rather than a live process'

 $f=Fixture liveexecutor;$process=[Diagnostics.Process]::GetCurrentProcess();$instance=[guid]::NewGuid().ToString('D')
 try{$f.State.SessionRef=@{RunId=$f.Run;InstanceId=$instance;ProcessId=$process.Id;StartTimeUtcTicks=[string]$process.StartTime.ToUniversalTime().Ticks;PipeName=('TCDeploy-'+[guid]::NewGuid().ToString('N'));Root=(Join-Path $f.Root ('deployments\hosts\'+$instance))}}finally{$process.Dispose()};Put $f.StatePath $f.State
 $preview=New-TCLocalDeploymentCleanupPreview $f.Root @($f.Id) -AbandonLocalTracking
 Check (-not $preview.PreviewToken -and -not $preview.CanAbandonLocalTracking -and @($preview.Blocked|Where-Object Code -eq ExecutorActive).Count -gt 0) 'Explicit abandonment cannot delete a live exact process or its files'
 Check ($preview.ExecutorWaitSeconds -eq 5 -and $preview.Executors.Count -eq 1 -and $preview.Executors[0].RequiresLiveIdleCheck -and $preview.Executors[0].SessionRef.RunId -ceq $f.Run) 'Preview supplies a target-bound idle-check reference and a finite close-wait contract'
 Check (Test-Path $f.StatePath) 'Read-only active-executor preview does not mutate or terminate the process'

 $f=Fixture unrelatedlease;$foreignRun=[guid]::NewGuid().ToString('D');$foreignPath=Join-Path $f.Root ('deployments\runs\'+$foreignRun+'\state.json')
 Put $foreignPath @{SchemaVersion=1;RunId=$foreignRun;ServerRecordId=$f.Other.LocalRecordId;Revision=1;Intent='New';Status='Running';Stage='Inspect';CreatedAtUtc=[DateTime]::UtcNow.ToString('o');UpdatedAtUtc=[DateTime]::UtcNow.ToString('o')};$foreignHash=Hash $foreignPath
 $foreignRunLease=Open-TCDLock (Join-Path (Split-Path $foreignPath -Parent) '.run.lock');$foreignServerLease=Open-TCDLock (Join-Path $f.Root ('servers\.task-'+$f.Other.LocalRecordId+'.lock'))
 try{$preview=New-TCLocalDeploymentCleanupPreview $f.Root @($f.Id);$result=Remove-TCLocalDeploymentData $f.Root $preview.PreviewToken;Check ($result.DataDeleted -and (Hash $foreignPath) -ceq $foreignHash) 'Active leases for another exact server target do not prevent this cleanup or change the other task'}finally{$foreignRunLease.Dispose();$foreignServerLease.Dispose()}

 $f=Fixture credentiallease;$credentialPath=Join-Path $f.Root ('deployments\credentials\'+$f.Run+'.json');Put $credentialPath @{Protected='credential-lock-fixture'}
 $preview=New-TCLocalDeploymentCleanupPreview $f.Root @($f.Id);$credentialLease=Open-TCDLock (Join-Path $f.Root 'deployments\.credentials.lock')
 try{Reject {Remove-TCLocalDeploymentData $f.Root $preview.PreviewToken} HistoryBusy;Check ((Test-Path $credentialPath) -and (Test-Path $f.StatePath)) 'A concurrent credential revocation cannot race cleanup into an incomplete deletion'}finally{$credentialLease.Dispose()}

 $f=Fixture nestedprobe;$f.State.Validation=@{Status='Failed';CleanupComplete=$false};Put $f.StatePath $f.State
 $preview=New-TCLocalDeploymentCleanupPreview $f.Root @($f.Id) -AbandonLocalTracking
 Check (@($preview.Blocked|Where-Object Code -eq ProbeCleanup).Count -gt 0) 'Nested validation cleanup failures are protected even when remote tracking is abandoned'

 $f=Fixture hongkong;$hk=Set-TCServerRecord -Root $f.Root -Connection @{Host='192.0.2.254';Port=22;User='root';IdentityFile=''} -ServerInfo @{RemoteOwnerId=[guid]::NewGuid().ToString('D');Node=@{NodeId=[guid]::NewGuid().ToString('D');ServerPublicKey=('H'*43+'=')}} -Name '香港主线夹具'
 $hkLine=[guid]::NewGuid().ToString('D');$hkManifest=Join-Path $f.Root ('Product\nodes\'+$hkLine+'\manifest.json');$hkConfig=Join-Path (Split-Path $hkManifest -Parent) 'dual-mode.json'
 Put $hkManifest @{TCLineId=$hkLine;ServerPublicKey=('H'*43+'=')};Put $hkConfig @{FixtureCurrentLine=$true};$index=Read-TCDJson (Join-Path $f.Root 'Product\index.json');$index.nodes+=,@{id=$hkLine;name='香港主线';manifestPath=$hkManifest};Put (Join-Path $f.Root 'Product\index.json') $index
 $null=Set-TCServerLink $f.Root $hk.LocalRecordId $hkLine
 $sharedId=[guid]::NewGuid().ToString('D');$null=Set-TCServerRecord $f.Root -Id $hk.LocalRecordId -CredentialRef $sharedId;$null=Set-TCServerRecord $f.Root -Id $f.Server.LocalRecordId -CredentialRef $sharedId
 $sharedPath=Join-Path $f.Root ('credentials\'+$sharedId+'.json');Put $sharedPath @{Protected='hongkong-shared-fixture'}
 Put (Join-Path $f.Root 'deployment.json') @{LineId=$hkLine;ManifestPath=$hkManifest};Put (Join-Path $f.Root 'runtime.json') @{State='Connected';OwnershipKnown=$true;LineId=$hkLine;ManifestPath=$hkManifest}
 $protectedPaths=@($hkManifest,$hkConfig,$sharedPath,(Join-Path $f.Root 'deployment.json'),(Join-Path $f.Root 'runtime.json'));$protectedHashes=@($protectedPaths|ForEach-Object {Hash $_});$hkDigest=Get-TCDDigest (Get-TCServer $f.Root $hk.LocalRecordId)
 $preview=New-TCLocalDeploymentCleanupPreview $f.Root @($f.Id);$result=Remove-TCLocalDeploymentData $f.Root $preview.PreviewToken
 Check ((Get-TCDDigest @($protectedPaths|ForEach-Object {Hash $_})) -ceq (Get-TCDDigest $protectedHashes) -and (Get-TCDDigest (Get-TCServer $f.Root $hk.LocalRecordId)) -ceq $hkDigest) 'Cleanup preserves Hong Kong runtime, config, registry identity and shared credential byte for byte'
 Check (@((Read-TCDJson (Join-Path $f.Root 'Product\index.json')).nodes|Where-Object id -ceq $hkLine).Count -eq 1 -and -not $result.NetworkChanged) 'Hong Kong remains indexed and its connection is not changed'

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
