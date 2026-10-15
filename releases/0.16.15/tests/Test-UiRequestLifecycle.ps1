#requires -Version 5.1
[CmdletBinding()]param([string]$PackageRoot,[string]$ReportPath)
$ErrorActionPreference='Stop';$env:PSModulePath=Join-Path $PSHOME 'Modules'
if(-not $PackageRoot){$PackageRoot=Split-Path $PSScriptRoot -Parent};$script:PackageRoot=[IO.Path]::GetFullPath($PackageRoot)
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('tc-ui-lifecycle-'+[guid]::NewGuid().ToString('N'))
$script:Root=$fixture;$script:JobRoot=Join-Path $fixture 'jobs';$null=[IO.Directory]::CreateDirectory($script:JobRoot)
. (Join-Path $PackageRoot 'ui\BackgroundJobs.ps1')
. (Join-Path $PackageRoot 'ui\ConnectionProfilePages.ps1')
. (Join-Path $PackageRoot 'ui\LineCardState.ps1')
. (Join-Path $PackageRoot 'ui\LineCardControls.ps1')
. (Join-Path $PackageRoot 'ui\NavigationContext.ps1')
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PackageRoot 'ui\DeploymentPages.ps1'),[ref]$tokens,[ref]$errors)
foreach($name in @('TestDeploymentCallbackContext','NewDeploymentCallbackContext')){$n=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true);Set-Item ('Function:script:'+$name) ([scriptblock]::Create($n.Body.Extent.Text.Substring(1,$n.Body.Extent.Text.Length-2)))}
$script:Smoke=$false;$script:ReadOnly=$false;$script:UiReadWorkerEnabled=$false;$script:UiJobRecoveryLoaded=$true
$script:Role='client';$script:Page='nodes';$script:DeployUI=@{Run=$null};$script:Job=$null;$script:Pending=$null
$script:HostPanel=[pscustomobject]@{IsEnabled=$true};$script:Footer=[pscustomobject]@{Text=''};$script:Overlay=[pscustomobject]@{Visibility='Collapsed'}
$script:Window=[pscustomobject]@{};$script:Window|Add-Member ScriptMethod FindName {param($n)$script:Overlay}
$script:Checks=New-Object 'Collections.Generic.List[string]';$script:Actors=New-Object 'Collections.Generic.List[object]';$script:Finals=New-Object 'Collections.Generic.List[object]'
$script:Messages=New-Object 'Collections.Generic.List[string]';$script:WorkerStartFails=$false;$script:RefreshReads=0;$script:Dialogs=0
function Check {param($ok,$text) if(-not $ok){throw $text};$script:Checks.Add($text)}
function Start-Process {param($FilePath,$ArgumentList,[switch]$PassThru,$WindowStyle)
 if($WindowStyle -cne 'Hidden' -or [IO.Path]::GetFileName($FilePath) -ine 'powershell.exe'){throw 'Unexpected Worker launch'}
 $requestFile=[string]$ArgumentList[([array]::IndexOf($ArgumentList,'-RequestPath')+1)];$requestFile=$requestFile.Trim('"')
 if(-not [IO.Path]::GetFullPath($requestFile).StartsWith(($script:JobRoot+'\'),[StringComparison]::OrdinalIgnoreCase)){throw 'Worker left isolated job directory'}
 $r=[IO.File]::ReadAllText($requestFile)|ConvertFrom-Json;$script:Actors.Add($r)
 if($script:WorkerStartFails){throw 'Injected OS startup failure'}
 $p=[pscustomobject]@{Id=(1900000000+$script:Actors.Count);StartTime=[DateTime]::UtcNow;HasExited=$false;Disposed=$false}
 $p|Add-Member ScriptMethod Dispose {$this.Disposed=$true};return $p
}
function Get-CimInstance {throw 'No real OS worker access in lifecycle fixture'}
function Get-Process {throw 'No real process access in lifecycle fixture'}
function ErrorDialog {param($message)$script:Messages.Add($message);$script:Dialogs++}
function Toast {param($message)$script:Messages.Add($message)}
function OpenDialog {param($Title,$Body,$Note,$Confirm,$Action,$Cancel,$Context,[switch]$SafeDefault)$script:Dialogs++}
function UpdateChrome {}
function Render {}
function IsBusy {return [bool]$script:Job}
function IsRunning {return [bool]$script:Overview.Running}
function DialogOpenUI {return $false}
function TradeLaneValue {if($script:Overview.Exit -eq 'hk'){'node:'+$script:Overview.ActiveLineId}else{'provider:'+ $script:Overview.TradeProviderId}}
function FetchNodes {$script:RefreshReads++}
function RefreshOverview {param([switch]$Silent)$script:RefreshReads++}
function NodeEntry {param($id)@($script:Nodes|Where-Object LineId -ceq $id)|Select-Object -First 1}
function ShowLineConnections {}
function ShowRuntimeReport {}
function MakeLine {
 [pscustomobject]@{LineId='11111111-1111-1111-1111-111111111111';Revision=1;Name='isolated line';Endpoint='192.0.2.10:443';Profiles=@([pscustomobject]@{Id='Udp';PreparationState='Ready'},[pscustomobject]@{Id='Tcp';PreparationState='Ready'});DefaultVerified=$true;SavedConnectionPreference=[pscustomobject]@{ProfileId='Udp';Digest='fixture'}}
}
$script:Nodes=@(MakeLine);$id=$script:Nodes[0].LineId
$script:Overview=[pscustomobject]@{Running=$false;NinjaRunning=$false}
function CompleteCurrent {param($Data=$null,[bool]$Ok=$true,[string]$Code='FixtureResult')
 $j=$script:Job;if(-not $j){throw 'Expected actual dispatcher Job'}
 $r=@{Ok=$Ok;Action=$j.Action;RequestId=$j.RequestId;PageGeneration=$j.OriginContext.Revision;Data=$Data;Code=$Code;Message='isolated failure detail'}
 [IO.File]::WriteAllText($j.Result,($r|ConvertTo-Json -Depth 20 -Compress),[Text.UTF8Encoding]::new($true));PollBackgroundJob
 return $j
}
function NewLineContext {param($Profile='Tcp',$Kind='Preference')@{Type='Line';LineId=$id;Id=$id;ProfileId=$Profile;ExpectedRevision=1;UiRequestId=[guid]::NewGuid().ToString('N');Kind=$Kind}}
function Admit {param($Request,$Context=$null,[switch]$Silent)
 StartJob -Request $Request -Complete {} -CallbackContext $Context -Silent:$Silent -Finalized {param($n,$c)$script:Finals.Add($n)} -PassThru
}
function Navigate {param($page)$script:Page=$page;$null=CaptureNavigationContext}
$passed=$false;$failure='';$stack=''
try{
 $output=@(SaveLineDefaultProfileForLineUI $id Tcp 1 Card)
 Check ($output.Count -eq 0 -and $script:Job.Action -ceq 'LinePreference' -and $script:Job.CallbackContext.Type -ceq 'Line') 'Real default-save entry dispatches with typed context and has no default output'
 $rid=$script:Job.UiRequestId;$saved=MakeLine;$saved.Revision=2;$saved.SavedConnectionPreference.ProfileId='Tcp'
 $j=CompleteCurrent $saved
 Check (-not $script:LinePreferenceRequests.ContainsKey($id) -and $script:Nodes[0].SavedConnectionPreference.ProfileId -ceq 'Tcp' -and $j.Lifecycle.Terminal.UiRequestId -ceq $rid) 'Successful save persists UI selection and finalizes exact request'
 SaveLineDefaultProfileForLineUI $id Udp 2 Card;$j=CompleteCurrent $null $false
 Check (-not $script:LinePreferenceRequests.ContainsKey($id) -and $script:Nodes[0].SavedConnectionPreference.ProfileId -ceq 'Tcp') 'Failed save clears pending and retains the persisted default'
 CheckLineCardProtocolUI $id
 Check ($script:Job.Action -ceq 'LineProfileCheck') 'Real line-check entry reaches the Worker boundary'
 $null=CompleteCurrent @{Message='fixture blocked';Code='TargetNotSelectedExit';Status='Blocked'}
 Check ($script:LineCheckRequests.Count -eq 0) 'Line check terminal callback clears only its pending owner'
 RepairLineDefaultUI $id
 Check ($script:Job.Action -ceq 'LinePreferenceRepair' -and $script:LinePreferenceRequests.ContainsKey($id)) 'Real repair entry dispatches and owns a pending request'
 $null=CompleteCurrent @{Code='AlreadyCurrent'}
 Check ($script:LinePreferenceRequests.Count -eq 0) 'Repair finalizes its exact request'
 Check (@($script:Actors|Where-Object {$_.Action -match 'Session|Connect|Probe|Deploy'}).Count -eq 0) 'Default/repair/check controls do not dispatch connection or deployment commands'
 $a=Admit @{Action='LineProfiles';Id=$id}
 Check ($a.Disposition -ceq 'Started' -and $a.Accepted) 'PassThru reports Started'
 $c=NewLineContext;$script:Nodes=@(MakeLine)
 $q=Admit @{Action='LinePreference';Id=$id;ProfileId='Tcp';ExpectedRevision=1} $c
 Check ($q.Disposition -ceq 'Queued' -and $q.UiRequestId -ceq $c.UiRequestId) 'Queued request preserves its UI identity'
 $null=CompleteCurrent
 Check ($script:Job.UiRequestId -ceq $q.UiRequestId -and $script:Job.RequestData.UiRequestId -ceq $q.UiRequestId -and $script:Job.RequestId -ne $q.UiRequestId) 'Dequeue retains UI identity and maps a separate Worker request identity'
 $null=CompleteCurrent
 Check (@($script:Finals|Where-Object UiRequestId -ceq $q.UiRequestId).Count -eq 1) 'Queued completion finalizes once'
 $null=Admit @{Action='LineProfiles';Id=$id} -Silent
 $co=Admit @{Action='LineProfiles';Id=$id} -Silent
 Check ($co.Disposition -ceq 'Coalesced' -and $script:Finals[-1].Status -ceq 'Coalesced') 'Silent coalescing returns disposition and terminates the duplicate owner'
 $null=CompleteCurrent
 foreach($bad in @(@{Type='Unknown';UiRequestId=[guid]::NewGuid().ToString('N')},@{Id=$id},@{Type='Line';LineId=$id;ProfileId='Tcp';ExpectedRevision=1;UiRequestId='bad'})){
  $before=$script:Actors.Count;$r=Admit @{Action='LinePreference';Id=$id;ProfileId='Tcp';ExpectedRevision=1} $bad
  Check ($r.Code -ceq 'ContextInvalid' -and -not $r.Accepted -and $script:Actors.Count -eq $before -and $script:Finals[-1].UiRequestId -ceq $r.UiRequestId) 'Malformed or unknown context is visibly rejected and finalized without dispatch'
 }
 $script:ReadOnly=$true;$r=Admit @{Action='LinePreference';Id=$id;ProfileId='Tcp';ExpectedRevision=1} (NewLineContext)
 Check ($r.Code -ceq 'ReadOnly' -and $script:Finals[-1].Code -ceq 'ReadOnly') 'Read-only refusal finalizes before queue/dispatch'
 $script:ReadOnly=$false;$script:WorkerStartFails=$true
 SaveLineDefaultProfileForLineUI $id Tcp 1 Card
 Check (-not $script:Job -and $script:LinePreferenceRequests.Count -eq 0) 'OS startup failure clears the real line pending marker'
 $script:WorkerStartFails=$false
 $null=Admit @{Action='LineProfiles';Id=$id}
 for($i=0;$i -lt 32;$i++){$null=Admit @{Action='LineProfiles';Id=('q'+$i)}}
 $r=Admit @{Action='LineProfiles';Id='overflow'}
 Check ($r.Code -ceq 'QueueFull' -and $script:Finals[-1].Code -ceq 'QueueFull') 'Full queue rejects and finalizes the unaccepted owner'
 foreach($entry in @($script:JobQueue.ToArray())){CancelQueuedUiRequest $entry.Lifecycle.UiRequestId}
 Check ($script:JobQueue.Count -eq 0) 'Explicit cancellation finalizes each undispatched read'
 $null=CompleteCurrent
 $null=Admit @{Action='LineProfiles';Id=$id};$c=NewLineContext;$q=Admit @{Action='LinePreference';Id=$id;ProfileId='Tcp';ExpectedRevision=1} $c;$c.ProfileId='Udp'
 $null=CompleteCurrent
 Check (-not $script:Job -and @($script:Finals|Where-Object {$_.UiRequestId -ceq $q.UiRequestId -and $_.Code -ceq 'ContextInvalid'}).Count -eq 1) 'The same context validator rejects changed context at dequeue'
 $null=Admit @{Action='LineProfiles';Id=$id};$q=Admit @{Action='ConnectionDefaultPreview';LineId=$id;SelectionMode='SavedDefault'}
 Navigate home;$null=CompleteCurrent
 Check (-not $script:Job -and @($script:Finals|Where-Object {$_.UiRequestId -ceq $q.UiRequestId -and $_.Code -ceq 'NavigationChanged'}).Count -eq 1) 'Navigation cancels a queued page request with terminal notification'
 Navigate nodes
 $u=Admit @{Action='FixtureMutation'};$old=$script:Job;$old.Clock=[pscustomobject]@{Elapsed=[pscustomobject]@{TotalSeconds=601}}
 PollBackgroundJob
 Check (-not $script:Job -and $script:UncertainUiJobs.Contains($old) -and $old.Lifecycle.Terminal.Status -ceq 'OutcomeUnknown') 'Mutation timeout releases UI lifecycle while keeping the uncertain operation'
 $receipt=[IO.File]::ReadAllText((Join-Path $script:JobRoot ($old.RequestId+'.receipt.json')))|ConvertFrom-Json
 Check ($receipt.Status -ceq 'OutcomeUnknown' -and -not $old.Process.Disposed) 'Mutation timeout retains durable receipt and original executor handle'
 $r=Admit @{Action='LinePreference';Id=$id;ProfileId='Tcp';ExpectedRevision=1} (NewLineContext)
 Check ($r.Code -ceq 'MutationBlocked' -and $script:Finals[-1].Code -ceq 'MutationBlocked') 'Unknown mutation barrier rejects and finalizes a conflicting request'
 CompleteUiJob $old ([pscustomobject]@{Ok=$true;Data=$null})
 Check ($script:UncertainUiJobs.Count -eq 0 -and @($script:Finals|Where-Object UiRequestId -ceq $u.UiRequestId).Count -eq 1) 'Late terminal mutation resolves receipt without finalizing UI twice'
 $r=StartJob @{Action='LineProfiles';Id=$id} {throw 'Injected callback error'} -Finalized {param($n)$script:Finals.Add($n)} -PassThru
 $j=CompleteCurrent
 Check ($j.CallbackFailed -and $j.Lifecycle.Terminal.Code -ceq 'UiCallbackFailed' -and @($script:Finals|Where-Object UiRequestId -ceq $r.UiRequestId).Count -eq 1) 'Callback exception still runs exact finalizer once'
 CompleteUiJob $j ([pscustomobject]@{Ok=$true;Data=$null});Check (@($script:Finals|Where-Object UiRequestId -ceq $r.UiRequestId).Count -eq 1) 'Duplicate completion is idempotent'
 $r=Admit @{Action='LineProfiles';Id=$id};$timed=$script:Job;$timed.Clock=[pscustomobject]@{Elapsed=[pscustomobject]@{TotalSeconds=31}}
 PollBackgroundJob
 Check (-not $script:Job -and $script:HostPanel.IsEnabled -and $timed.Lifecycle.Terminal.Code -ceq 'ReadOwnershipUnknown' -and [IO.File]::Exists($timed.Request)) 'Unverified read timeout ends UI waiting without killing any process or erasing evidence'
 Check (@($script:Finals|Where-Object UiRequestId -ceq $r.UiRequestId).Count -eq 1) 'Read timeout finalizer is emitted once'
 # The preview owner is global, but its callbacks and finalizer are per request.
 $script:Nodes=@(MakeLine);Navigate nodes;StartLineConnectionPreview $id ''; $previewOld=$script:Job;$oldDialogs=$script:Dialogs
 Navigate home;Navigate nodes;StartLineConnectionPreview $id '';$previewNewId=$script:ConnectionPreviewUI.UiRequestId
 Check ($script:JobQueue.Count -eq 1 -and $previewNewId -cne $previewOld.UiRequestId) 'Returning from another page can enqueue a new preview while the old read finishes'
 $null=CompleteCurrent @{CanSwitch=$true;LineId=$id;ProfileId='Udp';PreviewToken='old';SelectionMode='SavedDefault'}
 Check ($script:Dialogs -eq $oldDialogs -and $script:ConnectionPreviewUI.UiRequestId -ceq $previewNewId -and $script:Job.UiRequestId -ceq $previewNewId) 'Late old preview neither opens its dialog nor clears the new preview'
 $null=CompleteCurrent @{CanSwitch=$true;LineId=$id;ProfileId='Udp';PreviewToken='new';SelectionMode='SavedDefault'}
 Check (-not $script:ConnectionPreviewUI -and $script:Dialogs -eq ($oldDialogs+1)) 'Current preview finishes and opens only its own confirmation'
 StartLineConnectionPreview $id '';Navigate home;$null=CompleteCurrent $null $false
 Check (-not $script:ConnectionPreviewUI) 'Off-page failed preview releases the latch without a stale dialog'
 Navigate nodes;StartLineConnectionPreview $id '';Check ($script:Job.Action -ceq 'ConnectionDefaultPreview') 'Re-entering after failed preview starts another request'
 $null=CompleteCurrent @{CanSwitch=$false;Message='unavailable'}
 # Real new/legacy deployment validators remain supported, including resume.
 $script:Role='deployment';$script:DeployUI=@{Run=@{RunId='22222222-2222-2222-2222-222222222222'};AccessAttemptId='attempt-1';SessionRef=@{RunId='22222222-2222-2222-2222-222222222222';InstanceId='33333333-3333-3333-3333-333333333333'}}
 $c=NewDeploymentCallbackContext -Session;$r=Admit @{Action='DeploymentSessionSnapshot';SessionRef=$script:DeployUI.SessionRef} $c
 Check ($r.Accepted -and $r.Disposition -ceq 'Started') 'New typed deployment context preserves Flow/Run/Attempt/Instance contract'
 $null=CompleteCurrent
 $legacy=@{Flow=$script:DeployUI;RunId=$script:DeployUI.Run.RunId;AttemptId='attempt-1';InstanceId=''};$r=Admit @{Action='DeploymentDiscover'} $legacy
 Check ($r.Accepted) 'Legacy real deployment-shaped context remains compatible'
 $null=CompleteCurrent
 $script:DeployUI.Run=$null;$c=NewDeploymentCallbackContext;$c.RequestedRunId='22222222-2222-2222-2222-222222222222';$r=Admit @{Action='DeploymentGet';RunId=$c.RequestedRunId} $c
 Check ($r.Accepted) 'Resume request binds RequestedRunId while current Flow has not loaded a Run yet'
 $null=CompleteCurrent
 $c=NewDeploymentCallbackContext;$script:DeployUI=@{Run=$null};$r=Admit @{Action='DeploymentDiscover'} $c
 Check ($r.Code -ceq 'ContextInvalid') 'A replaced deployment flow cannot dispatch a stale request'
 Check (@($script:Actors|Where-Object {$_.Action -in @('Session','ConnectionSwitchCommit','DeploymentProceed','CandidateProbe')}).Count -eq 0) 'All lifecycle tests perform zero connection/deployment/network actors'
 $passed=$true
}catch{$failure=$_.Exception.Message;$stack=$_.ScriptStackTrace}
finally{
 $report=[pscustomobject]@{Passed=$passed;Assertions=$script:Checks.Count;Checks=@($script:Checks.ToArray());Failure=$failure;Stack=$stack;Smoke=$script:Smoke;ActualDispatcher=$true;ActualQueue=$true;ActualNavigationContext=$true;ActualDeploymentContext=$true;WorkerBoundary='isolated process adapter';Dispatched=@($script:Actors.ToArray());Finalized=@($script:Finals.ToArray());ProductionWrites=0;NetworkOperations=0;PowerShellVersion=$PSVersionTable.PSVersion.ToString()}
 if($ReportPath){$report|ConvertTo-Json -Depth 20|Set-Content -LiteralPath $ReportPath -Encoding UTF8};$report|Select-Object Passed,Assertions,Failure,Stack,Smoke,ActualDispatcher,ActualQueue,ProductionWrites,NetworkOperations|ConvertTo-Json -Depth 4
 $full=[IO.Path]::GetFullPath($fixture);$prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if(-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -cnotmatch '^tc-ui-lifecycle-[a-f0-9]{32}$'){throw 'Cleanup boundary rejected'}
 Remove-Item -LiteralPath $full -Recurse -Force
}
if(-not $passed){throw $failure}
