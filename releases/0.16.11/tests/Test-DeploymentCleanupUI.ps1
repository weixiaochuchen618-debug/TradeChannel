#requires -Version 5.1
#requires -PSEdition Desktop
[CmdletBinding()]
param([Alias('SourceDirectory')][string]$PackageRoot,[string]$ReportPath,[string]$ReportDirectory)
$ErrorActionPreference='Stop';$env:PSModulePath=Join-Path $PSHOME 'Modules'
if(-not $PackageRoot){$PackageRoot=Split-Path $PSScriptRoot -Parent}
if(-not $ReportDirectory){$ReportDirectory=if($ReportPath){[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($ReportPath))}else{Join-Path ([IO.Path]::GetTempPath()) ('tc-cleanup-ui-report-'+[guid]::NewGuid().ToString('N'))}}
$harness=[IO.File]::ReadAllText((Join-Path $PackageRoot 'ui\Test-015UI.ps1'),[Text.Encoding]::UTF8)
$preambleEnd=$harness.IndexOf('$passed=$false;$failure=''''',$harness.IndexOf('function SelectHistoryFilter'))
$setupStart=$harness.IndexOf(" ImportNamedPresentation 'TradeChannel.ps1'")
$setupEnd=$harness.IndexOf(" ResetUI;ShowSetup;Shot '015-01-single-add-line'")
if($preambleEnd -lt 0 -or $setupStart -lt $preambleEnd -or $setupEnd -lt $setupStart){throw 'WPF fixture initialization boundaries changed'}
. ([scriptblock]::Create($harness.Substring(0,$preambleEnd))) -SourceDirectory $PackageRoot -TestOutputDirectory $ReportDirectory
if(-not $ReportPath){$ReportPath=Join-Path $qa 'deployment-cleanup-ui-result.json'}
$ReportPath=SafeLocalPath ([IO.Path]::GetFullPath($ReportPath))
if([IO.Path]::GetExtension($ReportPath) -ine '.json' -or [IO.Path]::GetDirectoryName($ReportPath) -ine $qa){throw 'ReportPath must be a JSON file in the evidence directory'}
$script:CommandRequests=New-Object 'Collections.Generic.List[object]'
$script:SimulatedActorCalls=New-Object 'Collections.Generic.List[object]'
$script:FixtureProcesses=@{};$script:FixtureSequence=0
$script:UncertainUiJobs=New-Object 'Collections.Generic.List[object]'
$script:JobQueue=New-Object 'Collections.Generic.List[object]'
$actorNames+=@('Get-CimInstance','Get-WmiObject','New-PSSession','Invoke-Command')
foreach($name in @('Get-CimInstance','Get-WmiObject','New-PSSession','Invoke-Command')){Set-Item -Path ('Function:script:'+$name) -Value {$script:DeniedActors.Add($MyInvocation.MyCommand.Name);throw ('Forbidden real actor: '+$MyInvocation.MyCommand.Name)}}

# UI callbacks remain real. Only the asynchronous command dispatcher is a
# capture queue; the real close command runs against the boundary fakes below.
function StartUiCommand {
 param([string]$Module,[string]$Command,[hashtable]$Arguments,$Context,[scriptblock]$Complete,[scriptblock]$Failed,[string]$Message)
 if(-not $script:Smoke -or $Module -cne 'DeploymentTransport.psm1' -or $Command -cne 'Close-TCDeployIdleSessionsForCleanup'){throw ('Unexpected in-memory command: '+$Module+'/'+$Command)}
 $script:CommandRequests.Add([pscustomobject]@{Module=$Module;Command=$Command;Arguments=$Arguments.Clone();Context=$Context;Complete=$Complete;Failed=$Failed;Delivered=$false;Result=$null;Error=''})
}
function ConfirmCleanupDialog {
 CheckUI ($script:Window.FindName('Overlay').Visibility -eq 'Visible' -and $null -ne $script:DialogCallback) 'A visible actionable dialog precedes each cleanup confirmation'
 $script:Window.FindName('DialogConfirm').RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
 StopIntakeTimer
}
function CancelCleanupDialog {$script:Window.FindName('DialogCancel').RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)));StopIntakeTimer}
function ResetCleanupUI {ResetUI;$script:CommandRequests.Clear();$script:UncertainUiJobs.Clear();$script:JobQueue.Clear();$script:QueuedJob=$null}
function WriteFixtureJson {param([string]$Path,$Value) Write-TCDJson (FixturePath $Path) $Value}
function ShowCleanupHistory {
 $script:DeployUI.HistoryRecords=@(Get-TCOperationHistory -Root $script:Root -IncludeHidden -IncludeServerRecords)
 $script:DeployUI.HistoryLoaded=$true;ShowUnifiedOperationHistory
}
function ClickCleanupHistory {param([string]$Id) ShowCleanupHistory;ClickUI ('DeleteHistory'+($Id -replace '[^A-Za-z0-9]',''))}
function DeliverCleanupPreview {
 $request=LastRequest
 CheckUI ($request.Action -ceq 'RecordDeletePreview' -and @($request.Ids).Count -eq 1) 'The real UI requests a preview for exactly the chosen record'
 $preview=New-TCLocalDeploymentCleanupPreview -Root $script:Root -Ids @($request.Ids) -AbandonLocalTracking:([bool]$request.AbandonLocalTracking)
 DeliverUI $preview
 return $preview
}
function ExecuteCleanupCommand {
 $entry=$script:CommandRequests[$script:CommandRequests.Count-1]
 if($entry.Delivered){throw 'An in-memory callback may be delivered only once'}
 $entry.Delivered=$true
 try{
  $entry.Result=& $script:CleanupTransport {param($arguments) Close-TCDeployIdleSessionsForCleanup @arguments} $entry.Arguments
 }catch{
  $entry.Error=$_.Exception.Message
  if(-not $entry.Failed){throw}; & $entry.Failed $entry.Error $entry.Context;return $entry
 }
 & $entry.Complete $entry.Result $entry.Context
 return $entry
}
function CommitCleanupPreview {
 param($Preview)
 ConfirmCleanupDialog
 $request=LastRequest
 CheckUI ($request.Action -ceq 'RecordDeleteCommit' -and $request.PreviewToken -ceq $Preview.PreviewToken -and $request.Count -eq 2) 'Commit carries only the sealed preview token, never a second unbound abandonment flag'
 $result=Remove-TCLocalDeploymentData -Root $script:Root -PreviewToken $request.PreviewToken
 DeliverUI $result
 return $result
}
function NewCleanupFixture {
 param([string]$Name,[ValidateSet('None','Idle','Active','Timeout')][string]$Executor='None',[switch]$Unknown)
 $script:FixtureSequence++
 $connection=@{Host=('192.0.2.'+(10+$script:FixtureSequence));Port=22;User='root';IdentityFile=''}
 $server=Set-TCServerRecord -Root $script:Root -Connection $connection -Name $Name -PinnedFingerprint ('SHA256:'+('A'*43))
 $run=BaseRun 'PrepareAccess' 'WaitingUser';$run.RunId=[guid]::NewGuid().ToString('D');$run.ServerRecordId=$server.LocalRecordId;$run.Name=$Name
 foreach($field in @(@{Name='Revision';Value=1},@{Name='SessionRef';Value=$null},@{Name='AttemptSessionRef';Value=$null},@{Name='LastRemoteMutation';Value=$null},@{Name='CandidateTransaction';Value=$null},@{Name='CreatedAtUtc';Value=[DateTime]::UtcNow.ToString('o')},@{Name='UpdatedAtUtc';Value=[DateTime]::UtcNow.ToString('o')})){$run|Add-Member NoteProperty $field.Name $field.Value -Force}
 $run.LastError=@{Code='AuthenticationFailed';Message='服务器已响应，但拒绝了本次登录认证。本次登录已结束，尚未开始部署。'}
 $run.AccessIssue=@{Kind='Credentials';Code='AuthenticationFailed';Connection=$connection;AuthenticationGeneration=1}
 $process=$null
 if($Executor -ne 'None'){
  $instance=[guid]::NewGuid().ToString('D');$number=2000000000+$script:FixtureSequence;$start=[DateTime]::UtcNow.AddMinutes(-5)
  $ref=[pscustomobject]@{RunId=$run.RunId;InstanceId=$instance;ProcessId=$number;StartTimeUtcTicks=[string]$start.Ticks;PipeName=('TCDeploy-'+[guid]::NewGuid().ToString('N'));Root=(Join-Path $script:Root ('deployments\hosts\'+$instance))}
  $run.SessionRef=$ref;$run.AccessIssue.SessionInstanceId=$instance
  $process=[pscustomobject]@{Id=$number;StartTime=$start;Path=(Join-Path $script:PackageRoot 'deployment\TradeChannelDeployHost.exe');HasExited=$false;ExitOnClose=($Executor -ne 'Timeout');CloseRequested=$false;WaitMilliseconds=-1;PollStatus=$(if($Executor -eq 'Active'){'Running'}else{'Failed'});Mutating=($Executor -eq 'Active');Ref=$ref}
  $process|Add-Member ScriptMethod Dispose {}
  $process|Add-Member ScriptMethod WaitForExit {param([int]$milliseconds) $this.WaitMilliseconds=$milliseconds;if($this.ExitOnClose -and $this.CloseRequested){$this.HasExited=$true;return $true};return $false}
  $script:FixtureProcesses[[string]$number]=$process
  WriteFixtureJson (Join-Path $ref.Root 'receipt.json') @{RunId=$run.RunId;InstanceId=$instance;Status='Failed';ProcessId=$number;StartTimeUtcTicks=$ref.StartTimeUtcTicks;Mutating=$false}
 }
 if($Unknown){$run.Stage='Apply';$run.Status='OutcomeUnknown';$run.RecoveryRequired=$true;$run.PendingOperationId=[guid]::NewGuid().ToString('D');$run.LastRemoteMutation=@{State='Dispatched';Mutating=$true};$run.AccessIssue=$null}
 $path=Join-Path $script:Root ('deployments\runs\'+$run.RunId+'\state.json');WriteFixtureJson $path $run
 $credentialId=[guid]::NewGuid().ToString('D');$server=Set-TCServerRecord -Root $script:Root -Id $server.LocalRecordId -CredentialRef $credentialId
 $credentialPath=Join-Path $script:Root ('credentials\'+$credentialId+'.json');WriteFixtureJson $credentialPath @{Protected='NOT-A-REAL-DPAPI-ENVELOPE';FixtureOnly=$true}
 $taskCredentialPath=Join-Path $script:Root ('deployments\credentials\'+$run.RunId+'.json');WriteFixtureJson $taskCredentialPath @{Protected='NOT-A-REAL-TASK-SECRET';FixtureOnly=$true}
 return [pscustomobject]@{Server=$server;Connection=$connection;Run=$run;Id=('DeploymentRun:'+$run.RunId);Path=$path;CredentialPath=$credentialPath;TaskCredentialPath=$taskCredentialPath;Process=$process}
}
function CheckHongKongFixture {
 param([string]$Label)
 $actual=@($script:HongKongPaths|ForEach-Object {(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash})
 CheckUI ((Get-TCDDigest $actual) -ceq $script:HongKongDigest -and (Get-TCDDigest (Get-TCServer -Root $script:Root -Id $script:HongKong.LocalRecordId)) -ceq $script:HongKongRegistryDigest) $Label
}

$passed=$false;$failure='';$failureStack=''
try{
 . ([scriptblock]::Create($harness.Substring($setupStart,$setupEnd-$setupStart)))
 $script:CleanupHistory=Import-Module (Join-Path $script:PackageRoot 'OperationHistory.psm1') -PassThru -DisableNameChecking
 $script:CleanupTransport=Import-Module (Join-Path $script:PackageRoot 'DeploymentTransport.psm1') -PassThru -DisableNameChecking
 $stopSessionDefinition=& $script:CleanupTransport {(Get-Command Stop-TCDeploySession).Definition}
 $store=Import-Module (Join-Path $script:PackageRoot 'DeploymentStore.psm1') -PassThru -DisableNameChecking
 $registry=Import-Module (Join-Path $script:PackageRoot 'ServerRegistry.psm1') -PassThru -DisableNameChecking
 $flow=Import-Module (Join-Path $script:PackageRoot 'DeploymentFlow.psm1') -PassThru -DisableNameChecking
 foreach($module in @($script:CleanupHistory,$script:CleanupTransport,$store,$registry,$flow)){GuardModuleActors $module}
 # The close wrapper is the unit under test; its pipe/OS boundary remains the
 # fixture below. Reinstall only this wrapper after the actor guard.
 & $script:CleanupTransport {param($definition)Set-Item Function:script:Stop-TCDeploySession ([scriptblock]::Create($definition))} $stopSessionDefinition
 foreach($relative in @('OperationHistory.psm1','LocalDeploymentCleanup.ps1','DeploymentTransport.psm1','ServerRegistry.psm1','DeploymentFlow.psm1','ui\NavigationContext.ps1')){$null=ReadSourceAst $relative}
 & $script:CleanupHistory {
  param($processes,$calls)
  $script:CleanupUIProcesses=$processes;$script:CleanupUICalls=$calls
  function script:Get-CleanupFixtureProcessById {param([int]$Id)
   $script:CleanupUICalls.Add([pscustomobject]@{Actor='FixtureProcessLookup';Id=$Id})
   if(-not $script:CleanupUIProcesses.ContainsKey([string]$Id)){throw [ArgumentException]::new('Fixture process is not running')}
   return $script:CleanupUIProcesses[[string]$Id]
  }
  function script:Get-CimInstance {param($ClassName,$Filter,$ErrorAction) $script:CleanupUICalls.Add([pscustomobject]@{Actor='FixtureProcessInventory';Id=0});return @()}
  # Replace only the hard-coded OS process accessor. All process identity,
  # lease, current-line and cleanup decision logic remains the source code.
  foreach($name in @('LCProcessAlive','OHRemovalBlock')){
   $body=(Get-Item ('Function:'+$name)).ScriptBlock.ToString()
   $pattern='\[Diagnostics\.Process\]::GetProcessById\((\$\w+)\)'
   if([regex]::Matches($body,$pattern).Count -ne 1){throw ('Process boundary changed: '+$name)}
   $body=[regex]::Replace($body,$pattern,'(Get-CleanupFixtureProcessById -Id $1)')
   Set-Item ('Function:script:'+$name) ([scriptblock]::Create($body))
  }
 } $script:FixtureProcesses $script:SimulatedActorCalls
 & $script:CleanupTransport {
  param($processes,$calls)
  $script:CleanupUIProcesses=$processes;$script:CleanupUICalls=$calls
  function script:Get-TCDeploySession {param($SessionRef,[int]$TotalTimeoutMs=0)
   $script:CleanupUICalls.Add([pscustomobject]@{Actor='FixturePoll';Id=$SessionRef.ProcessId})
   $p=$script:CleanupUIProcesses[[string]$SessionRef.ProcessId]
   if(-not $p -or $p.Ref.InstanceId -cne $SessionRef.InstanceId){throw 'Unknown fixture session'}
   return [pscustomobject]@{RunId=$SessionRef.RunId;InstanceId=$SessionRef.InstanceId;Status=$p.PollStatus;HasMutatingOperations=[bool]$p.Mutating}
  }
  function script:Invoke-TCDeployPipe {param($SessionRef,[hashtable]$Body,[int]$ConnectTimeout=3000,[int]$ReadTimeoutMs=10000,[int]$TotalTimeoutMs=0)
   $script:CleanupUICalls.Add([pscustomobject]@{Actor='FixtureGracefulClose';Id=$SessionRef.ProcessId})
   if([string]$Body.Command -cne 'Close'){throw 'The cleanup fixture only permits a graceful Close'}
   $p=$script:CleanupUIProcesses[[string]$SessionRef.ProcessId];if(-not $p -or $p.Mutating){throw 'The fixture forbids closing an active session'}
   $p.CloseRequested=$true
   # Match the shipped host protocol: terminal close has Code/Status, not a
   # UI convenience Closed flag. Stop-TCDeploySession must normalize it.
   return [pscustomobject]@{Ok=$true;Code='SessionClosed';Status='Closed'}
  }
  function script:Get-Process {param([int]$Id,$ErrorAction) $script:CleanupUICalls.Add([pscustomobject]@{Actor='FixtureWaitLookup';Id=$Id});return $script:CleanupUIProcesses[[string]$Id]}
 } $script:FixtureProcesses $script:SimulatedActorCalls

 # The active Hong Kong line is synthetic but remains byte-identical through
 # every other case. Its address and all paths belong to this fixture only.
 $script:HongKong=Set-TCServerRecord -Root $script:Root -Connection @{Host='192.0.2.254';Port=22;User='root';IdentityFile=''} -Name '香港主线夹具' -ServerInfo @{RemoteOwnerId=[guid]::NewGuid().ToString('D');Node=@{NodeId=[guid]::NewGuid().ToString('D');ServerPublicKey=('H'*43+'=')}}
 $hkLine=[guid]::NewGuid().ToString('D');$hkManifest=Join-Path $script:Root ('Product\nodes\'+$hkLine+'\manifest.json')
 $hkConfig=Join-Path (Split-Path $hkManifest -Parent) 'dual-mode.json';$hkRuntime=Join-Path $script:Root 'runtime.json';$hkDeployment=Join-Path $script:Root 'deployment.json'
 WriteFixtureJson $hkManifest @{TCLineId=$hkLine;ServerPublicKey=('H'*43+'=')};WriteFixtureJson $hkConfig @{FixtureOnly=$true;Purpose='Keep active Hong Kong configuration'}
 WriteFixtureJson (Join-Path $script:Root 'Product\index.json') @{schemaVersion=1;nodes=@(@{id=$hkLine;name='香港主线夹具';manifestPath=$hkManifest})}
 $script:HongKong=Set-TCServerLink -Root $script:Root -ServerId $script:HongKong.LocalRecordId -NodeId $hkLine
 WriteFixtureJson $hkDeployment @{LineId=$hkLine;ManifestPath=$hkManifest}
 WriteFixtureJson $hkRuntime @{State='Connected';OwnershipKnown=$true;LineId=$hkLine;ManifestPath=$hkManifest}
 $script:HongKongPaths=@($hkManifest,$hkConfig,$hkRuntime,$hkDeployment)
 $script:HongKongDigest=Get-TCDDigest @($script:HongKongPaths|ForEach-Object {(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash})
 $script:HongKongRegistryDigest=Get-TCDDigest (Get-TCServer -Root $script:Root -Id $script:HongKong.LocalRecordId)

 ResetCleanupUI;$idle=NewCleanupFixture '登录已结束的测试准备' Idle
 $script:DeployUI.ServerId=$idle.Server.LocalRecordId;$script:DeployUI.SessionRef=$idle.Run.SessionRef;$script:DeployUI.AccessAttemptId=[guid]::NewGuid().ToString('D')
 $script:DeployUI.Discovery=@{Servers=@($idle.Server)}
 RenderRun $idle.Run;ClickUI DeployRetryLogin
 $script:Controls.DeployPassword.Password='FAKE_EDITING_DRAFT'
 $script:DeployUI.Credential=@{Kind='Password';Password=(ConvertTo-SecureString 'FAKE_SUBMITTED' -AsPlainText -Force)}
 $script:DeployUI.RecoveredCredential=@{Kind='Password';Password=(ConvertTo-SecureString 'FAKE_RECOVERED' -AsPlainText -Force)}
 $script:DeployUI.PreparationConsent=@{RunId=$idle.Run.RunId};$script:DeployUI.TaskCredentialAvailable=$true
 $oldContext=NewDeploymentCallbackContext -Session;$oldAttempt=$script:DeployUI.AccessAttemptId
 CheckUI ($script:Controls.ContainsKey('DeployAbandonLocal')) 'The actual failed-login page offers local cleanup without requiring a history detour'
 ClickUI DeployAbandonLocal;$p=DeliverCleanupPreview
 CheckUI ($p.EligibleCount -eq 0 -and -not $p.PreviewToken -and $p.Executors.Count -eq 1) 'An exact live idle executor requires a separate live-state check before deletion'
 CheckUI ($script:Window.FindName('DialogTitle').Text -ceq '核对并结束旧登录会话' -and $script:Window.FindName('DialogNote').Text -match '5 秒') 'The first dialog explains normal closure and its five-second bound'
 Shot '01-idle-session-check'
 ConfirmCleanupDialog;$command=$script:CommandRequests[0]
 CheckUI ($command.Arguments.Root -ceq $script:Root -and $command.Arguments.WaitSeconds -eq 5 -and $command.Arguments.Executors[0].RunId -ceq $idle.Run.RunId) 'The actual callback sends the exact executor identity and bounded wait'
 $closed=ExecuteCleanupCommand
 CheckUI (-not $closed.Error -and $closed.Result.ClosedCount -eq 1 -and $idle.Process.HasExited -and $idle.Process.CloseRequested -and $idle.Process.WaitMilliseconds -ge 0 -and $idle.Process.WaitMilliseconds -le 5000) 'The real transport closes only the idle fake session and confirms exit within its budget'
 CheckUI (-not $script:DeployUI.SessionRef -and -not $script:DeployUI.Credential -and $script:DeployUI.AccessAttemptId -cne $oldAttempt -and $script:DeployUI.PasswordControl.SecurePassword.Length -gt 0) 'Closing the idle executor invalidates submitted credentials and callbacks while preserving the editing draft until cleanup'
 CheckUI ((LastRequest).Action -ceq 'RecordDeletePreview' -and -not (LastRequest).AbandonLocalTracking) 'Normal session closure automatically obtains a fresh ordinary cleanup preview'
 $p=DeliverCleanupPreview
 CheckUI ($p.EligibleCount -eq 1 -and $p.PreviewToken -and $p.Executors.Count -eq 0) 'After verified exit the real backend supplies a new eligible preview'
 CheckUI ($script:Window.FindName('DialogTitle').Text -ceq '删除本机部署资料？' -and $script:Window.FindName('DialogBody').Text.Contains($idle.Connection.Host) -and $script:Window.FindName('DialogBody').Text.Contains([string]$p.FileCount) -and $script:Window.FindName('DialogNote').Text -match '不会卸载服务器') 'The final confirmation names the target, cleanup extent and remote preservation'
 Shot '02-specific-cleanup-confirmation'
 $before=$script:Requests.Count;$stateHash=(Get-FileHash -LiteralPath $idle.Path).Hash;CancelCleanupDialog
 CheckUI ($script:Requests.Count -eq $before -and (Get-FileHash -LiteralPath $idle.Path).Hash -ceq $stateHash) 'Cancelling the concrete confirmation sends no commit and preserves source data'
 ClickUI DeployAbandonLocal;$p=DeliverCleanupPreview
 $script:UncertainUiJobs.Add([pscustomobject]@{RunId=$idle.Run.RunId;Process=$null})
 $script:UncertainUiJobs.Add([pscustomobject]@{RunId='unrelated-run';Process=$null})
 foreach($request in @(@{Action='DeploymentGet';RunId=$idle.Run.RunId},@{Action='ServerInfo';ServerId=$idle.Server.LocalRecordId},@{Action='DeploymentGet';RunId='unrelated-run'})){$script:JobQueue.Add([pscustomobject]@{Request=$request})}
 $result=CommitCleanupPreview $p
 CheckUI ($result.DataDeleted -and -not (Test-Path -LiteralPath $idle.Path) -and -not (Test-Path -LiteralPath $idle.CredentialPath) -and -not (Test-Path -LiteralPath $idle.TaskCredentialPath) -and -not (Test-Path -LiteralPath $idle.Run.SessionRef.Root)) 'The UI commit physically deletes the task, independent credentials and exited executor cache'
 CheckUI (-not $script:DeployUI.Run -and -not $script:DeployUI.SessionRef -and -not $script:DeployUI.Credential -and -not $script:DeployUI.RecoveredCredential -and -not $script:DeployUI.PreparationConsent -and -not $script:DeployUI.TaskCredentialAvailable -and $script:DeployUI.PasswordControl.SecurePassword.Length -eq 0) 'Cleanup clears the current run, both in-memory credential sources, consent and editable secret'
 CheckUI ($script:UncertainUiJobs.Count -eq 1 -and $script:UncertainUiJobs[0].RunId -ceq 'unrelated-run' -and $script:JobQueue.Count -eq 1 -and $script:QueuedJob.Request.RunId -ceq 'unrelated-run') 'Only callbacks and queued requests owned by the deleted task or server are removed'
 $before=$script:Requests.Count;$script:Role='deployment';$script:DeployUI.Reauth=$false
 SetDeploymentAccessRunUI $idle.Run $oldContext
 ApplyDeploymentSessionSnapshot @{InstanceId=$idle.Run.SessionRef.InstanceId;Poll=@{Status='Ready';HasSession=$true;ObservedFingerprint=('SHA256:'+('A'*43))}} $oldContext
 CheckUI (-not $script:DeployUI.Run -and -not $script:DeployUI.SessionRef -and $script:Requests.Count -eq $before) 'Late run and session callbacks cannot resurrect deleted data even on the deployment page'
 $fresh=New-TCDeploymentRun -Root $script:Root -Connection $idle.Connection -Name '同一目标的新任务' -Intent New
 $freshServer=Get-TCServer -Root $script:Root -Id $fresh.ServerRecordId
 CheckUI ($fresh.RunId -cne $idle.Run.RunId -and $fresh.ServerRecordId -cne $idle.Server.LocalRecordId -and -not $freshServer.PinnedHostKey -and -not $freshServer.CredentialRef -and $fresh.Stage -ceq 'PrepareAccess') 'The real backend creates a clean new task and server identity for the same endpoint'
 $script:DeployUI.Run=$fresh;$script:DeployUI.AccessAttemptId=[guid]::NewGuid().ToString('D')
 SetDeploymentAccessRunUI $idle.Run $oldContext
 CheckUI ($script:DeployUI.Run.RunId -ceq $fresh.RunId -and $script:Requests.Count -eq $before) 'An old callback cannot overwrite the replacement task for the same endpoint'
 CheckHongKongFixture 'Ordinary cleanup and same-endpoint recreation preserve Hong Kong configuration and registry identity'

 ResetCleanupUI;$unknown=NewCleanupFixture '结果未知的测试准备' -Unknown
 ClickCleanupHistory $unknown.Id;$p=DeliverCleanupPreview
 CheckUI ($p.EligibleCount -eq 0 -and $p.CanAbandonLocalTracking -and $p.RemoteOutcomeUnverified -and -not $p.PreviewToken) 'Unknown remote outcome blocks ordinary deletion and offers a separate local abandonment choice'
 CheckUI ($script:Window.FindName('DialogTitle').Text -ceq '只放弃本机跟踪？' -and $script:Window.FindName('DialogNote').Text -match '服务器上已执行.*保留.*不会.*远端回滚') 'The actual unknown-outcome dialog distinguishes local abandonment from remote rollback'
 Shot '03-explicit-local-abandonment';ConfirmCleanupDialog
 CheckUI ((LastRequest).Action -ceq 'RecordDeletePreview' -and (LastRequest).AbandonLocalTracking -and -not (LastRequest).ContainsKey('PreviewToken')) 'Explicit abandonment requests a new preview rather than committing the blocked result'
 $p=DeliverCleanupPreview
 CheckUI ($p.EligibleCount -eq 1 -and $p.PreviewToken -and $p.AbandonLocalTracking -and $p.RemoteOutcomeUnverified) 'The fresh preview token binds the explicit abandonment decision'
 CheckUI ($script:Window.FindName('DialogBody').Text -match '原操作结果仍未核对.*仅放弃本机跟踪') 'The final concrete confirmation still exposes the unresolved remote result'
 $result=CommitCleanupPreview $p
 CheckUI ($result.AbandonedLocalTracking -and $result.RemoteOutcomeUnverified -and -not $result.RemoteRollbackConfirmed -and -not $result.RemoteChanges -and -not $result.NetworkChanged -and -not (Test-Path -LiteralPath $unknown.Path)) 'The completed UI operation records local deletion without claiming a rollback or remote mutation'
 $freshUnknown=New-TCDeploymentRun -Root $script:Root -Connection $unknown.Connection -Name '未知结果后的新任务' -Intent New
 CheckUI ($freshUnknown.RunId -cne $unknown.Run.RunId -and $freshUnknown.ServerRecordId -cne $unknown.Server.LocalRecordId) 'Explicitly abandoned local tracking does not block a new task for the same endpoint'
 CheckHongKongFixture 'Abandoning another target leaves the Hong Kong line byte-identical'

 ResetCleanupUI;$candidate=NewCleanupFixture '未发布的本机候选准备'
 $candidate.Run.Stage='MaterializeCandidate';$candidate.Run.AccessIssue=$null
 $candidate.Run.CandidateTransaction=@{State='Prepared'}
 WriteFixtureJson $candidate.Path $candidate.Run
 ClickCleanupHistory $candidate.Id;$p=DeliverCleanupPreview
 $candidateWarning=@($p.Warnings|Where-Object Code -eq 'LocalCandidateAbandonment')
 CheckUI ($p.EligibleCount -eq 1 -and $p.LocalCandidateAbandonment -and -not $p.RemoteOutcomeUnverified -and $candidateWarning.Count -eq 1) 'An unpublished local candidate receives a specific local-only abandonment warning'
 CheckUI ($script:Window.FindName('DialogTitle').Text -ceq '删除本机部署资料？' -and $script:Window.FindName('DialogBody').Text.Contains([string]$candidateWarning[0].Message)) 'The final concrete dialog renders the backend local-candidate warning without dropping its preservation scope'
 Shot '05-local-candidate-cleanup-warning'
 $result=CommitCleanupPreview $p
 CheckUI ($result.LocalCandidateAbandoned -and $result.DataDeleted -and -not $result.RemoteOutcomeUnverified -and -not (Test-Path -LiteralPath $candidate.Path)) 'Local candidate cleanup succeeds without manufacturing remote uncertainty'

 ResetCleanupUI;$active=NewCleanupFixture '仍在执行服务器步骤' Active
 ClickCleanupHistory $active.Id;$p=DeliverCleanupPreview
 CheckUI ($p.EligibleCount -eq 0 -and -not $p.CanAbandonLocalTracking -and $p.Executors.Count -eq 1) 'A live executor cannot bypass inspection by choosing local abandonment'
 ConfirmCleanupDialog;$before=$script:Requests.Count;$command=ExecuteCleanupCommand
 CheckUI ($command.Error -match '\[TC:CleanupExecutorActive\]' -and -not $active.Process.CloseRequested -and -not $active.Process.HasExited) 'Live status refuses normal closure while a server step is active'
 CheckUI ($script:Requests.Count -eq $before -and $script:LastErrorDialog -match '仍在执行|不能确认' -and (Test-Path -LiteralPath $active.Path) -and (Test-Path -LiteralPath $active.TaskCredentialPath)) 'An active executor leaves an explicit error and intact material with no follow-up commit'
 Shot '04-active-executor-protected'

 ResetCleanupUI;$timeout=NewCleanupFixture '空闲会话退出超时' Timeout
 ClickCleanupHistory $timeout.Id;$p=DeliverCleanupPreview;ConfirmCleanupDialog;$before=$script:Requests.Count;$command=ExecuteCleanupCommand
 CheckUI ($command.Error -match '\[TC:CleanupExecutorTimeout\]' -and $timeout.Process.CloseRequested -and -not $timeout.Process.HasExited -and $timeout.Process.WaitMilliseconds -le 5000) 'A bounded normal-close timeout never becomes forced termination or successful deletion'
 CheckUI ($script:Requests.Count -eq $before -and $script:LastErrorDialog -match '5 秒.*保留' -and (Test-Path -LiteralPath $timeout.Path)) 'Timeout is visibly terminal for this attempt and retains the cleanup target'

 ResetCleanupUI;ClickCleanupHistory ('ServerRecord:'+$script:HongKong.LocalRecordId);$p=DeliverCleanupPreview
 CheckUI ($p.EligibleCount -eq 0 -and -not $p.PreviewToken -and -not $p.CanAbandonLocalTracking -and $p.Blocked.Code -contains 'CurrentLine') 'The active Hong Kong reference blocks cleanup and has no abandonment bypass'
 CheckUI ($script:LastErrorDialog -match '当前|线路' -and $null -eq $script:DialogCallback -and $script:CommandRequests.Count -eq 0) 'The current-line error offers no destructive confirm or executor close'
 CloseDialog;DeleteOperationRecordsUI -Ids @('ServerRecord:'+$script:HongKong.LocalRecordId) -AbandonLocalTracking;$p=DeliverCleanupPreview
 CheckUI ($p.EligibleCount -eq 0 -and -not $p.PreviewToken -and $p.Blocked.Code -contains 'CurrentLine') 'Even an explicit abandonment request cannot remove the active Hong Kong line'
 CheckHongKongFixture 'All protected-reference attempts preserve the Hong Kong data exactly'

 ResetCleanupUI;$navigation=NewCleanupFixture '已离开页面的确认'
 ClickCleanupHistory $navigation.Id;$request=LastRequest;$p=New-TCLocalDeploymentCleanupPreview -Root $script:Root -Ids @($request.Ids)
 ShowHome;$null=CaptureNavigationContext;DeliverUI $p
 CheckUI ($script:DialogCount -eq 0 -and $script:Page -ceq 'home' -and $script:Requests.Count -eq 1 -and (Test-Path -LiteralPath $navigation.Path)) 'A preview arriving after navigation cannot reopen a cleanup dialog or start deletion'
 CheckUI ($script:DeniedActors.Count -eq 0) 'The complete suite used only isolated local data and simulated OS/session actors'
 CheckUI (@($script:SimulatedActorCalls|Where-Object Actor -eq 'FixtureGracefulClose').Count -eq 2) 'Only the idle and timeout simulations received a graceful-close request'
 $passed=$true
}catch{$failure=$_.Exception.Message;$failureStack=$_.ScriptStackTrace;throw}
finally{
 StopIntakeTimer
 if($script:Window){$script:Window.Close()}
 $version=(Get-Content -LiteralPath (Join-Path $script:PackageRoot 'version.json') -Raw -Encoding UTF8|ConvertFrom-Json).Version
 $result=[pscustomobject]@{Passed=$passed;Version=$version;Count=$script:Checks.Count;Checks=@($script:Checks.ToArray());Failure=$failure;FailureStack=$failureStack;RealActorAttempts=@($script:DeniedActors.ToArray());ProductionDataAccess=0;RemoteActors=0;SimulatedActorCalls=@($script:SimulatedActorCalls.ToArray());LoadedSources=@($script:LoadedSources.ToArray());Screenshots=@($script:Shots.ToArray());FixtureRemoved=$false}
 $owned=SafeLocalPath $script:Root;$marker=Join-Path $owned '.owned-ui-015'
 if($owned -cne (Join-Path ([IO.Path]::GetTempPath()) ('tc-ui-015-data-'+$testId)) -or -not [IO.File]::Exists($marker) -or [IO.File]::ReadAllText($marker) -cne $testId){throw 'Fixture cleanup ownership check failed'}
 $reparse=@(Get-ChildItem -LiteralPath $owned -Recurse -Force|Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint})
 if($reparse.Count){throw 'Fixture cleanup refuses reparse points'}
 Remove-Item -LiteralPath $owned -Recurse -Force;$result.FixtureRemoved=(-not (Test-Path -LiteralPath $owned))
 [IO.File]::WriteAllText($ReportPath,($result|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($true))
 $result|Select-Object Passed,Version,Count,Failure,FixtureRemoved|ConvertTo-Json
}
