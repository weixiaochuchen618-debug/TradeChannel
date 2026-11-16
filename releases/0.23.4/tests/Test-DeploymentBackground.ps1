#requires -Version 5.1
#requires -PSEdition Desktop
[CmdletBinding()]param([string]$ReportPath)
$ErrorActionPreference='Stop'
$script:PackageRoot=Split-Path $PSScriptRoot -Parent
$script:Root=Join-Path ([IO.Path]::GetTempPath()) ('tc-background-d4-'+[guid]::NewGuid().ToString('N'))
. (Join-Path $script:PackageRoot 'ui\ConnectionProfilePages.ps1')
. (Join-Path $script:PackageRoot 'ui\DeploymentPages.ps1')
. (Join-Path $script:PackageRoot 'ui\DeploymentBackground.ps1')
InitializeDeploymentBackgroundUI
Import-Module (Join-Path $script:PackageRoot 'DeploymentStore.psm1') -DisableNameChecking
Import-Module (Join-Path $script:PackageRoot 'ServerRegistry.psm1') -DisableNameChecking
$flowModule=Get-Module DeploymentFlow
$checks=New-Object 'Collections.Generic.List[string]';$passed=$false;$failure=''
$script:Captured=New-Object 'Collections.Generic.List[object]';$script:Shown=0;$script:Toasts=0;$script:Closed=0;$script:Connections=0
function Check {param([bool]$Ok,[string]$Label)if(-not $Ok){throw $Label};$checks.Add($Label)}
function CopyValue {param($Value)$Value|ConvertTo-Json -Depth 35|ConvertFrom-Json}
function ClearDeploymentCredentialUI {$script:DeployUI.Credential=$null}
function ShowProductDeployment {$script:Shown++}
function Toast {param($Message)$script:Toasts++}
function CloseUiDeploymentSession {param($SessionRef)$script:Closed++}
function ErrorDialog {param($Message)throw $Message}
function StartLineConnectionPreview {$script:Connections++;throw 'Connection forbidden in background test'}
function PreviewDefaultLineConnection {$script:Connections++;throw 'Connection forbidden in background test'}
function StartUiCommand {param($Module,$Command,$Arguments,$Complete,$Failed,$Context,$Message)
 $script:Captured.Add([pscustomobject]@{Module=$Module;Command=$Command;Arguments=$Arguments;Complete=$Complete;Failed=$Failed;Context=$Context})
}
function NewUiFixture {
 $script:Smoke=$false;$script:ReadOnly=$false;$script:Role='deployment';$script:Page='setup';$script:Job=$null;$script:UncertainUiJobs=@();$script:Tray=$null;$script:UiMemoryJobs=@()
 $id=[guid]::NewGuid().ToString('D');$ref=[pscustomobject]@{RunId=$id;InstanceId=[guid]::NewGuid().ToString('D')}
 $run=[pscustomobject]@{RunId=$id;Revision=1;Name='Background fixture';Stage='Apply';Status='Running';SessionRef=$ref;RecoveryRequired=$false;ProbeRecoveryRequired=$false;UnresolvedTcpMutation=$null;AccessIssue=$null;PausedContinuation=$null;AttentionRequired=$false;ProfileProbeState='NotStarted'}
 $script:DeployUI=@{Run=$run;SessionRef=$ref;SessionAttached=$true;Reauth=$false;LastPoll=[DateTime]::MinValue;Credential=$null}
 return $script:DeployUI
}
function NextTick {param($Entry)$Entry.LastPoll=[DateTime]::MinValue;$script:Captured.Clear();PollDeploymentBackgroundUI;if($script:Captured.Count){return $script:Captured[0]};return $null}
function TickResult {param($Entry,[string]$Stage='TcpPlan',[string]$Status='Running')
 $run=CopyValue $Entry.Run;$run.Revision++;$run.Stage=$Stage;$run.Status=$Status
 if($Status -eq 'Complete'){$run.ProfileProbeState='Completed'}
 [pscustomobject]@{Run=$run;RunId=$run.RunId;SessionInstanceId=$Entry.SessionInstanceId;Progress=(Get-TCDeploymentProgress $run);ContinuePolling=($Status -eq 'Running');ConnectionStarted=$false;NetworkChanged=$false}
}
try{
 $original=NewUiFixture
 $beforeFlow=ConvertTo-Json $original -Depth 20 -Compress;$beforeJobs=$script:DeploymentBackgroundJobs.Count;$savedRoot=$script:Root;$script:Root='Not-A-Filesystem-Root'
 Check ((TestDeploymentBackgroundAvailableUI) -and (TestDeploymentBackgroundAvailableUI)) 'Background snapshot availability works without a usable persistence root'
 $script:Root=$savedRoot
 Check ((ConvertTo-Json $original -Depth 20 -Compress) -ceq $beforeFlow -and $script:DeploymentBackgroundJobs.Count -eq $beforeJobs -and $script:Captured.Count -eq 0 -and $script:Toasts -eq 0) 'Repeated CanBackground projection does not register, mutate, dispatch, clear secrets or notify'
 Check (EnableDeploymentBackgroundUI) 'Authenticated original run can be registered for background continuation'
 Check (TestDeploymentBackgroundWorkPendingUI) 'Window lifetime sees a registered deployment after navigation'
 $entry=$script:DeploymentBackgroundJobs[$original.Run.RunId];$script:Role='client';$script:Page='nodes'
 $call=NextTick $entry
 Check ($call -and $call.Command -ceq 'Invoke-TCDeploymentBackgroundTick' -and $call.Context.Type -ceq 'DeploymentBackground' -and $entry.Pending) 'Leaving the page schedules one independent run-bound background command'
 PollDeploymentBackgroundUI
 Check ($script:Captured.Count -eq 1) 'A pending background request cannot be dispatched twice'
 $other=NewUiFixture;$script:Role='client';$script:Page='nodes';$shown=$script:Shown
 $result=TickResult $entry
 & $call.Complete $result $call.Context
 Check ([object]::ReferenceEquals($script:DeployUI,$other) -and $other.Run.RunId -cne $result.RunId -and $original.Run.Stage -ceq 'TcpPlan' -and $script:Shown -eq $shown) 'A completed callback updates only its registered original Flow while another task is displayed'
 $call=NextTick $entry;$result=TickResult $entry ReadyInactive Complete
 & $call.Complete $result $call.Context;& $call.Complete $result $call.Context
 Check ($script:DeploymentBackgroundNotifications.Count -eq 1 -and $script:Toasts -eq 1 -and $script:Closed -eq 1) 'Completion sends one notification and closes only the completed session even after duplicate delivery'
 Check ($script:Connections -eq 0 -and -not $script:DeploymentBackgroundNotifications[0].ConnectionStarted) 'A completed background deployment never connects a line'
 Check (-not (TestDeploymentBackgroundWorkPendingUI)) 'Completed background work no longer blocks an explicit interface exit'
 $summary=@(GetDeploymentBackgroundSummaryUI|Where-Object RunId -ceq $entry.RunId)[0]
 Check ($summary.State -ceq 'Complete' -and -not $summary.CanConnect -and $summary.Steps.Count -eq 4) 'Background summary exposes four plain-language steps without a connect command'
 $sequence=[pscustomobject]@{RunId='fixture-progress';Status='Running';Stage='PrepareAccess';ApprovedChangeDigest=('a'*64);DualPreparationRequired=$true}
 $previous=1
 foreach($stage in @('PrepareAccess','Inspect','Plan','PlanReady','Apply','ServerInfo','ManagementPlan','ManagementApply','Authorize','ServerExit','MaterializeCandidate','InspectTcp','TcpCandidates','TcpPlan','TcpApply','MaterializeTcp','PreparingProbePath','CheckingProfiles')){
  $sequence.Stage=$stage;$progress=Get-TCDeploymentProgress $sequence
  Check ($progress.CurrentStep -ge $previous -and $progress.Steps.Count -eq 4) ('Four-step progress does not go backwards at '+$stage)
  $previous=$progress.CurrentStep
 }
 Check (RestoreDeploymentBackgroundFlowUI $entry.RunId) 'Opening the notification resumes the original Flow object'
 Check ([object]::ReferenceEquals($script:DeployUI,$original) -and -not $entry.Enabled -and $script:Page -ceq 'setup') 'Foreground reopening takes polling ownership without creating another session'

 $owner=NewUiFixture;$null=EnableDeploymentBackgroundUI;$entry=$script:DeploymentBackgroundJobs[$owner.Run.RunId];$script:Role='client';$script:Page='nodes';$call=NextTick $entry
 $owner.SessionRef.InstanceId=[guid]::NewGuid().ToString('D');$before=$owner.Run.Revision
 & $call.Complete (TickResult $entry) $call.Context
 Check ($owner.Run.Revision -eq $before -and -not $entry.Pending -and -not $entry.Enabled) 'Changing the session rejects the stale callback and retires only its original pending request'

 $owner=NewUiFixture;$null=EnableDeploymentBackgroundUI;$entry=$script:DeploymentBackgroundJobs[$owner.Run.RunId];$script:Role='client';$call=NextTick $entry
 $entry.RequestId=[guid]::NewGuid().ToString('N')
 & $call.Complete (TickResult $entry) $call.Context
 Check ($entry.Pending -and $entry.Enabled) 'An obsolete request cannot clear a newer request pending flag'
 $entry.Pending=$false;$entry.Enabled=$false

 $owner=NewUiFixture;$null=EnableDeploymentBackgroundUI;$entry=$script:DeploymentBackgroundJobs[$owner.Run.RunId];$script:Role='client';$call=NextTick $entry
 $attention=TickResult $entry NeedsRecovery NeedsRecovery
 & $call.Complete $attention $call.Context
 Check (-not $entry.Enabled -and $script:DeploymentBackgroundNotifications[$script:DeploymentBackgroundNotifications.Count-1].State -ceq 'NeedsAttention') 'Unresolved transactions stop background advancement and notify once'
 $script:Job=@{Action='ConnectionSwitchCommit';RunId=''};$script:Captured.Clear();$entry.Enabled=$true;$entry.LastPoll=[DateTime]::MinValue;PollDeploymentBackgroundUI
 Check ($script:Captured.Count -eq 0) 'A foreground connection transaction retains scheduling priority'
 $entry.Enabled=$false;$script:Job=$null
 $owner=NewUiFixture;$owner.Run.AccessIssue=@{Kind='IdentityChanged'}
 Check (-not (EnableDeploymentBackgroundUI)) 'Navigation cannot background an identity-change approval step'
 $owner=NewUiFixture;$owner.SessionAttached=$false
 Check (-not (EnableDeploymentBackgroundUI)) 'Navigation waits for authentication and session attachment'
 $owner=NewUiFixture;$script:Job=@{Action='RecordDeleteCommit';RunId=$owner.Run.RunId}
 Check (-not (EnableDeploymentBackgroundUI)) 'A cleanup job is never waived by deployment navigation'
 $script:Job=$null

 # Real consent, run lock, review and durable mutation intent. Only the remote
 # executor observation/dispatch leaf is replaced; no Worker or SSH is started.
 & $flowModule {
  param($Root)
  $script:BgFixtureRoot=$Root;$script:BgCalls=New-Object 'Collections.Generic.List[object]';$script:BgPoll=$null
  function script:Invoke-TCDeployOperation {param($SessionRef,$Operation,[Alias('Input')]$OperationInput,$OperationId)
   $saved=Get-TCDeploymentRun -Root $script:BgFixtureRoot -RunId $SessionRef.RunId
   if($saved.Status -cne 'Dispatching' -or $saved.DispatchIntent.IntentId -cne $OperationId -or $saved.DispatchIntent.InputDigest -cne (Get-TCDDigest $OperationInput)){throw 'Original durable intent missing before background dispatch'}
   $script:BgCalls.Add([pscustomobject]@{Operation=$Operation;Input=$OperationInput;OperationId=$OperationId;RunId=$SessionRef.RunId})
   $script:BgPoll=[pscustomobject]@{Status='Running'}
   [pscustomobject]@{Ok=$true;OperationId=$OperationId}
  }
  function script:Get-TCDeploySession {param($SessionRef)$script:BgPoll}
 } $script:Root
 function NewEngineFixture {
  $run=New-TCDeploymentRun -Root $script:Root -Connection @{Host='192.0.2.31';Port=22;User='root';IdentityFile=''} -Name 'Background engine fixture'
  $null=Set-TCServerRecord -Root $script:Root -Id $run.ServerRecordId -PinnedFingerprint ('SHA256:'+('C'*43))
  $grant=Set-TCDeploymentPreparationConsent -Root $script:Root -RunId $run.RunId -Submission @{Host='192.0.2.31';Port=22;User='root';TcpPort=443;ServerName='www.bing.com';Transport='Auto'}
  $run.SessionRef=[pscustomobject]@{RunId=$run.RunId;InstanceId=[guid]::NewGuid().ToString('D')};$run.ClientRequest=@{ClientPublicKey=('A'*43+'=')}
  $run.Plan=[pscustomobject]@{PlanId=[guid]::NewGuid().ToString('D');PlanExpiresAt=[DateTimeOffset]::UtcNow.AddMinutes(20).ToString('o');PublicEndpoint='192.0.2.31:51820'}
  & $flowModule {param($root,$r)Set-TCDeploymentReview $root $r Deploy $r.Plan 'Prepare' 'Fixture';$null=Save-TCDeploymentRun $root $r} $script:Root $run
  [pscustomobject]@{Run=$run;Consent=$grant}
 }
 $f=NewEngineFixture
 $r=Invoke-TCDeploymentBackgroundTick -Root $script:Root -RunId $f.Run.RunId -SessionInstanceId $f.Run.SessionRef.InstanceId -ConsentId $f.Consent.ConsentId
 Check ($r.Run.Status -ceq 'Running' -and $r.Run.Stage -ceq 'Apply' -and $r.ContinuePolling -and (& $flowModule {$script:BgCalls.Count}) -eq 1) 'Background tick consumes durable preparation consent and dispatches exactly one original approved apply'
 $again=Invoke-TCDeploymentBackgroundTick -Root $script:Root -RunId $f.Run.RunId -SessionInstanceId $f.Run.SessionRef.InstanceId -ConsentId $f.Consent.ConsentId
 Check ((& $flowModule {$script:BgCalls.Count}) -eq 1 -and $again.Run.PendingOperationId -ceq $r.Run.PendingOperationId) 'Another tick polls the original operation rather than replaying its consumed approval'
 Check (-not $again.ConnectionStarted -and -not $again.NetworkChanged) 'Real background state engine preserves explicit connection as a separate action'

 $f=NewEngineFixture;$f.Run.Stage='Plan';$f.Run.Status='Running';$f.Run.Review=$null;$f.Run.PendingOperationId=[guid]::NewGuid().ToString('D');$f.Run.PendingPurpose='Plan'
 $f.Run.DispatchIntent=[pscustomobject]@{IntentId=$f.Run.PendingOperationId;State='Dispatched';Mutating=$false;Operation='plan'}
 & $flowModule {param($root,$r)$null=Save-TCDeploymentRun $root $r;$script:BgPoll=[pscustomobject]@{Status='Completed';OperationId=$r.PendingOperationId;Data=$r.Plan}} $script:Root $f.Run
 $r=Invoke-TCDeploymentBackgroundTick -Root $script:Root -RunId $f.Run.RunId -SessionInstanceId $f.Run.SessionRef.InstanceId -ConsentId $f.Consent.ConsentId
 Check ($r.Run.Stage -ceq 'Apply' -and $r.ContinuePolling -and (& $flowModule {$script:BgCalls.Count}) -eq 2) 'A plan arriving during a background poll immediately consumes its original permission instead of stopping for a redundant click'

 $f=NewEngineFixture
 $r=Invoke-TCDeploymentBackgroundTick -Root $script:Root -RunId $f.Run.RunId -SessionInstanceId $f.Run.SessionRef.InstanceId -ConsentId ([guid]::NewGuid().ToString('D'))
 Check (-not $r.ContinuePolling -and $r.Progress.NeedsAttention -and (& $flowModule {$script:BgCalls.Count}) -eq 2) 'A different or absent durable consent stops at the plan without remote dispatch'
 $idle=CopyValue $f.Run;$idle.Stage='Inspect';$idle.Status='Idle';$idle.Review=$null
 & $flowModule {param($root,$v)$null=Save-TCDeploymentRun $root $v} $script:Root $idle
 $idleResult=Invoke-TCDeploymentBackgroundTick -Root $script:Root -RunId $idle.RunId -SessionInstanceId $idle.SessionRef.InstanceId -ConsentId ''
 Check (-not $idleResult.ContinuePolling -and $idleResult.Progress.NeedsAttention -and (& $flowModule {$script:BgCalls.Count}) -eq 2) 'Idle work without usable permission stops and notifies instead of polling forever'
 & $flowModule {param($root,$v)$null=Save-TCDeploymentRun $root $v} $script:Root $f.Run
 $bad=$false;try{Invoke-TCDeploymentBackgroundTick -Root $script:Root -RunId $f.Run.RunId -SessionInstanceId ([guid]::NewGuid().ToString('D')) -ConsentId $f.Consent.ConsentId|Out-Null}catch{$bad=$_.Exception.Message -like '*BackgroundSessionChanged*'}
 Check $bad 'Backend rejects a changed original session before mutation'
 $null=Request-TCDeploymentPause -Root $script:Root -RunId $f.Run.RunId
 $r=Invoke-TCDeploymentBackgroundTick -Root $script:Root -RunId $f.Run.RunId -SessionInstanceId $f.Run.SessionRef.InstanceId -ConsentId $f.Consent.ConsentId
 Check (-not $r.ContinuePolling -and (& $flowModule {$script:BgCalls.Count}) -eq 2) 'A persisted checkpoint pause cannot be crossed by a background tick'
 $f=NewEngineFixture;$f.Run.Stage='Inspect';$f.Run.Status='Idle';$f.Run.Review=$null
 & $flowModule {param($root,$v)$null=Save-TCDeploymentRun $root $v} $script:Root $f.Run
 $r=Invoke-TCDeploymentBackgroundTick -Root $script:Root -RunId $f.Run.RunId -SessionInstanceId $f.Run.SessionRef.InstanceId -ConsentId $f.Consent.ConsentId
 $last=& $flowModule {$script:BgCalls[$script:BgCalls.Count-1]}
 Check ($r.ContinuePolling -and $last.Operation -ceq 'inspect' -and $last.Input.Count -eq 0) 'Registered inspection preserves an empty dictionary input through the original durable executor contract'
 $passed=$true
}catch{$failure=$_.Exception.Message;throw}
finally{
 $result=[pscustomobject]@{Passed=$passed;Count=$checks.Count;Checks=$checks.ToArray();Failure=$failure;RealRemoteOperations=0;ConnectionsStarted=$script:Connections;NetworkChanges=0;PowerShell=$PSVersionTable.PSVersion.ToString()}
 if($ReportPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($result|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($true))}
 $result|Select-Object Passed,Count,Failure|ConvertTo-Json
 $full=[IO.Path]::GetFullPath($script:Root);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if($full.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($full) -cmatch '^tc-background-d4-[a-f0-9]{32}$' -and [IO.Directory]::Exists($full)){Remove-Item -LiteralPath $full -Recurse -Force}
}
