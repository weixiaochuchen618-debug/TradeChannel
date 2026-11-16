#requires -Version 5.1
#requires -PSEdition Desktop
[CmdletBinding()]param([string]$PackageRoot='')
$ErrorActionPreference='Stop'
if($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1){throw 'Run explicitly with Windows PowerShell 5.1.'}
$env:PSModulePath=Join-Path $PSHOME 'Modules'
if(-not $PackageRoot){$PackageRoot=Split-Path $PSScriptRoot -Parent}
$script:PackageRoot=[IO.Path]::GetFullPath($PackageRoot)
$script:Checks=New-Object 'Collections.Generic.List[string]'
$script:FixtureId=[guid]::NewGuid().ToString('N')
$script:FixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('tc-delete-ui-'+$script:FixtureId)
$lineA='11111111-1111-1111-1111-111111111111';$lineB='22222222-2222-2222-2222-222222222222'
$runA='33333333-3333-3333-3333-333333333333';$serverA='44444444-4444-4444-4444-444444444444'

function ImportPresentation {param([string]$Relative,[string[]]$Names=@())
 $path=Join-Path $script:PackageRoot $Relative;$tokens=$null;$errors=$null
 $ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
 if($errors.Count){throw ($Relative+': '+(($errors|ForEach-Object {$_.Message}) -join '; '))}
 foreach($definition in @($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst]},$false))){
  if($Names.Count -and $definition.Name -cnotin $Names){continue}
  $body=$definition.Body.Extent.Text;Set-Item -LiteralPath ('Function:script:'+$definition.Name) -Value ([scriptblock]::Create($body.Substring(1,$body.Length-2)))
 }
}
ImportPresentation 'ui\NavigationContext.ps1'
ImportPresentation 'ui\ConnectionProfilePages.ps1' @('ProfileUIField','UILineId')
ImportPresentation 'ui\DeploymentCenterPages.ps1' @('InvalidateDeploymentLists')
ImportPresentation 'TradeChannel.ps1' @('OpenDeleteNode','OpenDialog','CloseDialog')
ImportPresentation 'ui\OperationHistoryPages.ps1'
ImportPresentation 'ui\BackgroundJobs.ps1'
$script:ProductionStartJob=${function:StartJob}
ImportPresentation 'ui\WebShell.ps1'
Import-Module (Join-Path $script:PackageRoot 'WorkerContracts.psm1') -DisableNameChecking
Import-Module (Join-Path $script:PackageRoot 'DeploymentStore.psm1') -DisableNameChecking

# Execute production callbacks. UI objects, asynchronous dispatch and receipts
# are in-memory boundaries. No installed app, Worker, network or process actor.
function Start-Process {throw 'This semantic suite forbids external processes.'}
function Stop-Process {throw 'This semantic suite forbids process changes.'}
function Get-CimInstance {throw 'This semantic suite forbids live process inventory.'}
function Get-Process {
 [CmdletBinding()]param([int]$Id)
 if($Id -ne 424242){throw 'This semantic suite forbids live process lookup.'}
 if($script:ExecutorFixture -ceq 'Unknown'){throw [UnauthorizedAccessException]::new('Fixture executor identity cannot be read.')}
 if($script:ExecutorFixture -ceq 'Exited'){
  $record=New-Object Management.Automation.ErrorRecord ([InvalidOperationException]::new('Fixture process has exited.')),'NoProcessFoundForGivenId',([Management.Automation.ErrorCategory]::ObjectNotFound),$Id
  $PSCmdlet.ThrowTerminatingError($record)
 }
 $at=$script:ExecutorStartedUtc;if($script:ExecutorFixture -ceq 'Reused'){$at=$at.AddSeconds(1)}
 $process=[pscustomobject]@{Id=$Id;StartTime=$at;HasExited=$false};$process|Add-Member ScriptMethod Dispose {};return $process
}
function Invoke-WebRequest {throw 'This semantic suite forbids network requests.'}
function Invoke-RestMethod {throw 'This semantic suite forbids network requests.'}
function IsBusy {return ($script:ForcedBusy -or ($script:Job -and -not $script:Job.Silent))}
function Toast {param([string]$Text)$script:Toasts.Add($Text);$script:LastToast=$Text}
function ErrorDialog {param([string]$Text)$script:Errors.Add($Text)}
function SetChromeEnabled {param($Enabled)}
function UpdateChrome {}
function UpdateReadPresentation {param([switch]$DataChanged)$script:ReadUpdates++}
function StartNextUiJob {}
function CompleteUiJobFiles {}
function UpdateUiJobUncertaintyBinding {}
function SaveUiJobReceipt {param($Job,$Status)$Job.ReceiptSaved=$true;$script:ReceiptStatuses.Add($Status)}
function RefreshUiJobReceipts {$script:ReceiptRefreshes++}
function RestoreUiJobReceipts {}
function ShowUiReceiptDetail {param($Entry)$script:OpenedReceipt=$Entry}
function ClearDeploymentCredentialUI {param([switch]$KeepDraft)$script:CredentialsCleared++}
function SyncTCWebState {param([switch]$Force)$script:Events.Add('Snapshot')}
function FetchNodes {$script:FetchNodesCalls++}
function ShowNodes {$script:Page='nodes';$script:Role='client';SetNavigationContext 'nodes' 'nodes';$script:ReturnView='nodes'}
function ShowHome {$script:Page='home';$script:Role='client';SetNavigationContext 'home' 'home';$script:ReturnView='home'}
function ShowTCWebShell {param($Page)$script:Page='web';$script:WebPage=$Page;$script:Role='client';SetNavigationContext 'web' $Page;$script:ReturnView='web/'+$Page;return $true}
function ShowUnifiedOperationHistory {$script:Page='setup';$script:Role='operation-history';SetNavigationContext 'setup' 'operation-history';$script:ReturnView='history'}
function ShowSetupCenter {$script:Page='setup';$script:Role='deployment-center';SetNavigationContext 'setup' 'deployment-center';$script:ReturnView='setup'}
function LoadLineConnections {param($Id,[switch]$MaintenanceMode)$script:LineProfileUI=@{Id=$Id};$script:Page='line-profiles';SetNavigationContext 'nodes' 'line-profiles' $Id}
function Get-TCTextCatalog {return @{}}
function Get-TCConnectionMethods {return @()}
function Get-TCLineQualityContext {param($Overview)return @{Eligible=$false;Key=''}}
function StateKey {return 'Disconnected'}
function DailyLaneValue {return 'Direct'}
function StartJob {
 param([hashtable]$Request,[scriptblock]$Complete,[string]$Message='',[string]$Transition='',[switch]$Silent,[scriptblock]$Failed,$OriginContext=$null,$CallbackContext=$null,[scriptblock]$Finalized,[switch]$PassThru,$Lifecycle=$null)
 $id=[guid]::NewGuid().ToString('N');$uiId=[string](ProfileUIField $CallbackContext UiRequestId $id)
 if(-not $OriginContext){$OriginContext=CaptureNavigationContext}
 if(-not $Lifecycle){$Lifecycle=@{UiRequestId=$uiId;RequestId=$id;Finalized=$Finalized;CallbackContext=$CallbackContext;FinalizedDelivered=$false}}
 $job=@{RequestData=$Request.Clone();Action=$Request.Action;Complete=$Complete;Failed=$Failed;Message=$Message;Silent=[bool]$Silent;RequestId=$id;UiRequestId=$uiId;OriginContext=$OriginContext;CallbackContext=$CallbackContext;Lifecycle=$Lifecycle;Policy=(Get-TCWorkerActionContract $Request.Action);CompletionDelivered=$false;OutcomeUnknown=$false;Process=$null;Request='memory.request';Result='memory.result';CleanupEpoch=[long](ProfileUIField $script:DeployUI CleanupEpoch 0)}
 if($Request.Action -eq 'RecordDeleteCommit' -and $CallbackContext){$CallbackContext.Pending.CommitRequestId=$id;$job.WorkerProcessId=424242;$job.ProcessStartedTicks=$script:ExecutorStartedUtc.Ticks;$CallbackContext.Pending.CommitJob=$job}
 $script:Requests.Add($job);$script:Events.Add('Dispatch:'+ $Request.Action);$script:Job=$job
 if($PassThru){return @{Accepted=$true;UiRequestId=$uiId;Disposition='Started'}}
}
function StartUiCommand {param($Module,$Command,$Arguments,$Context,$Complete,$Failed,$Message)
 $script:Commands.Add(@{Module=$Module;Command=$Command;Arguments=$Arguments;Context=$Context;Complete=$Complete;Failed=$Failed;Message=$Message})
}
function Check {param([bool]$Condition,[string]$Name)if(-not $Condition){throw ('UI semantic assertion: '+$Name)};$script:Checks.Add($Name)}
function NewLine {param($Id,$Name,$Hash='A')
 return [pscustomobject]@{id=$Id;LineId=$Id;Name=$Name;Revision=7;AliasIds=@();SavedConnectionPreference=@{ProfileId='Tcp'};PreferredProfileId='Tcp';Profiles=@([pscustomobject]@{Id='Tcp';Revision=2;CandidateSHA256=($Hash*64);ManifestSHA256=('B'*64);PreparationState='Ready'})}
}
function ResetFixture {
 $script:Smoke=$true;$script:ReadOnly=$false;$script:ForcedBusy=$false;$script:Page='web';$script:WebPage='home';$script:Role='client';$script:NavigationContext=$null
 $script:Root=$script:FixtureRoot;$script:JobRoot=Join-Path $script:Root 'Product\jobs';$script:DeployUI=@{};$script:Job=$null;$script:Pending=$null;$script:LineProfileUI=$null;$script:ConnectionCompletionUI=$null
 $script:Nodes=@((NewLine $lineA '模拟测试线路'),(NewLine $lineB '模拟香港主线' 'C'));$script:Prefs=@{NodeId=$lineB;OpenAtLogin=$false}
 $script:Overview=[pscustomobject]@{Running=$false;StateKey='Disconnected';ReadState='Known';NinjaRunning=$false;ActiveLineId='';NodeId=$lineB;Exit='hk';GuardState='Protected'}
 $script:Requests=New-Object 'Collections.Generic.List[object]';$script:Commands=New-Object 'Collections.Generic.List[object]';$script:Toasts=New-Object 'Collections.Generic.List[string]';$script:Errors=New-Object 'Collections.Generic.List[string]';$script:Events=New-Object 'Collections.Generic.List[string]';$script:ReceiptStatuses=New-Object 'Collections.Generic.List[string]'
 $script:JobQueue=New-Object 'Collections.Generic.List[object]';$script:UncertainUiJobs=New-Object 'Collections.Generic.List[object]';$script:QueuedJob=$null;$script:Controls=@{}
 $script:ReadUpdates=0;$script:FetchNodesCalls=0;$script:ReceiptRefreshes=0;$script:CredentialsCleared=0;$script:ReturnView='';$script:OpenedReceipt=$null
 $script:ExecutorFixture='Exited';$script:ExecutorStartedUtc=[DateTime]::Parse('2026-10-16T00:00:00Z').ToUniversalTime()
 $script:WebAck=0;$script:WebDialogId='';$script:WebLastDialog='';$script:DialogCallback=$null;$script:DialogContext=$null;$script:WebConnectionAttempts=@{};$script:WebFormActive=$false;$script:WebQuality=$null;$script:WebStandby=$null;$script:WebTasks=@();$script:Version='0.18.3-preview';$script:LastToast=''
 $script:HostPanel=[pscustomobject]@{IsEnabled=$true};$script:Footer=[pscustomobject]@{Text=''}
 $script:Elements=@{Overlay=[pscustomobject]@{Visibility='Collapsed'};DialogTitle=[pscustomobject]@{Text=''};DialogBody=[pscustomobject]@{Text='';Parent=$null};DialogNote=[pscustomobject]@{Text=''};DialogNoteBox=[pscustomobject]@{Visibility='Collapsed'};DialogConfirm=[pscustomobject]@{Content='';Style=''};DialogCancel=[pscustomobject]@{Content='';Visibility='Collapsed'}}
 foreach($key in @('DialogConfirm','DialogCancel')){$script:Elements[$key]|Add-Member ScriptMethod Focus {return $true}}
 $script:Window=[pscustomobject]@{};$script:Window|Add-Member ScriptMethod FindName {param($Name)return $script:Elements[$Name]};$script:Window|Add-Member ScriptMethod FindResource {param($Name)return $Name}
 foreach($cache in @('LinePreferenceRequests','LineCheckRequests','LineCheckResults','LineCardControls')){Set-Variable $cache -Scope Script -Value @{}}
 $script:CleanupDialogDetailsControl=$null
 SetNavigationContext 'web' 'home'
}
function LastJob {param([string]$Action)return @($script:Requests|Where-Object Action -CEQ $Action|Select-Object -Last 1)[0]}
function CountJobs {param([string]$Action)return @($script:Requests|Where-Object Action -CEQ $Action).Count}
function Preview {param([string[]]$Ids=@('Line:'+$lineA),[switch]$Blocked)
 return [pscustomobject]@{SelectedIds=@($Ids);Scope='Line';BusinessState=$(if($Blocked){'PreviewBlocked'}else{'PreviewReady'});PreviewToken=$(if($Blocked){''}else{'sealed-preview'});EligibleCount=$(if($Blocked){0}else{$Ids.Count});Targets=@([pscustomobject]@{Name='模拟测试线路'});OperationCount=0;LineCount=1;FileCount=4;Blocked=$(if($Blocked){@([pscustomobject]@{Code='StopUnverified';Message='上次停止资料还需核对';TransactionId=('a'*32)})}else{@()});Warnings=@();TransactionIds=@('a'*32);Timings=@{TotalMs=18000}}
}
function DeletedResult {param([string]$Id=$lineA)
 return [pscustomobject]@{DataDeleted=$true;BusinessState='Deleted';SelectedIds=@('Line:'+$Id);DeletedIds=@();DeletedLineIds=@($Id)}
}
function Deliver {param($Job,$Data,[switch]$Fail,[switch]$Unknown)
 CompleteUiJob $Job ([pscustomobject]@{Ok=(-not $Fail);Data=$Data;Message='operation returned';Code=$(if($Unknown){'WorkerOutcomeUnknown'}else{''});OutcomeUnknown=[bool]$Unknown})
}
function ConfirmDialog {
 $action=$script:DialogCallback;$context=$script:DialogContext;CloseDialog;if($action){& $action $context}
}
function BeginConfirmedDeletion {
 OpenDeleteNode $lineA;Deliver (LastJob RecordDeletePreview) (Preview);ConfirmDialog;return (LastJob RecordDeleteCommit)
}
function SendWeb {param([string]$Type,[string]$Id)
 InvokeTCWebMessage (@{Type=$Type;Id=$Id;Sequence=($script:WebAck+1)}|ConvertTo-Json -Compress) 'https://tradechannel.local/index.html'
}

$passed=$false;$failure='';$fixtureRemoved=$false
try{
 $null=New-TCDDirectory $script:FixtureRoot
 Write-TCDJson (Join-Path $script:FixtureRoot '.owned.json') @{Id=$script:FixtureId}

 ResetFixture;OpenDeleteNode $lineA
 Check ($script:Elements.DialogTitle.Text -ceq '正在检查「模拟测试线路」是否可删除' -and $script:Elements.DialogBody.Text -match '10–20 秒') 'Immediate waiting copy names the exact target and the observed 10–20 second budget'
 Check ($script:Events[0] -ceq 'Snapshot' -and $script:Events[1] -ceq 'Dispatch:RecordDeletePreview') 'Cancellation UI is published before worker dispatch'
 Check ($script:Elements.DialogConfirm.Content -ceq '取消检查' -and (CountJobs RecordDeleteCommit) -eq 0) 'Waiting is cancellable and does not submit deletion'
 OpenDeleteNode $lineA;Check ((CountJobs RecordDeletePreview) -eq 1) 'Repeated delete intent cannot duplicate the pending preview'
 $previewJob=LastJob RecordDeletePreview;$pending=$script:DeployUI.RecordDeletePending;ConfirmDialog
 Check ($pending.Phase -ceq 'Cancelled' -and -not $pending.PreviewToken) 'The waiting cancel action invalidates its original preview'
 Deliver $previewJob (Preview)
 Check ((CountJobs RecordDeleteCommit) -eq 0 -and $script:Elements.Overlay.Visibility -ceq 'Collapsed' -and $script:Nodes.Count -eq 2) 'A cancelled preview late result cannot reopen confirmation or delete data'

 ResetFixture;OpenDeleteNode $lineA;Deliver (LastJob RecordDeletePreview) (Preview)
 Check ($script:Elements.DialogTitle.Text -ceq '删除「模拟测试线路」？' -and $script:Elements.DialogConfirm.Content -ceq '删除线路') 'A line has one concise object-specific deletion confirmation'
 Check ($script:Elements.DialogBody.Text -ceq '将移除此电脑上的线路及仅供它使用的资料。服务器上的服务会保留。') 'Line copy describes the local scope without technical counts'
 $snapshot=GetTCWebSnapshot
 Check ($snapshot.Dialog.Details -match '本机文件 4 个' -and -not $snapshot.Dialog.Danger.Equals($false) -and -not $snapshot.Dialog.Progress) 'Technical diagnostics are a separate foldable dialog payload'
 SendWeb cancelDialog $script:WebDialogId
 Check ((CountJobs RecordDeleteCommit) -eq 0 -and $script:DeployUI.RecordDeletePending.Cancelled) 'Cancelling final confirmation invalidates the token without committing'

 ResetFixture;OpenDeleteNode $lineA;Deliver (LastJob RecordDeletePreview) (Preview)
 $action=$script:DialogCallback;$context=$script:DialogContext;CloseDialog;& $action $context;& $action $context
 Check ((CountJobs RecordDeleteCommit) -eq 1 -and $script:DeployUI.RecordDeletePending.Submitted) 'A confirmation is latched before dispatch and cannot submit twice'
 $bad=DeletedResult;$bad.DataDeleted=$false;Deliver (LastJob RecordDeleteCommit) $bad
 Check ($script:Nodes.Count -eq 2 -and $script:DeployUI.RecordDeletePending.Phase -ceq 'OutcomeUnknown') 'Worker Ok with DataDeleted false is never deletion success'
 Check (@($script:Toasts|Where-Object {$_ -clike '已删除*'}).Count -eq 0 -and (CountJobs Nodes) -eq 1) 'Unverified deletion retains caches and requests only a read'
 $before=$script:Requests.Count;$script:Job=$null;OpenDeleteNode $lineB
 Check ($script:Requests.Count -eq $before) 'Unknown deletion blocks a new deletion instead of authorizing replay'

 ResetFixture;$commit=BeginConfirmedDeletion;$wrong=DeletedResult $lineB;Deliver $commit $wrong
 Check ($script:Nodes.Count -eq 2 -and $script:DeployUI.RecordDeletePending.Phase -ceq 'OutcomeUnknown') 'DataDeleted with different selected/deleted IDs cannot remove the intended target'
 ResetFixture;$commit=BeginConfirmedDeletion;$wrong=DeletedResult;$wrong.BusinessState='PreviewReady';Deliver $commit $wrong
 Check ($script:Nodes.Count -eq 2 -and $script:DeployUI.RecordDeletePending.Phase -ceq 'OutcomeUnknown') 'BusinessState disagreement cannot be presented as successful deletion'

 ResetFixture;$commit=BeginConfirmedDeletion
 foreach($cache in @('LinePreferenceRequests','LineCheckRequests','LineCheckResults','LineCardControls')){
  $dictionary=Get-Variable $cache -Scope Script -ValueOnly;$dictionary[$lineA]=[pscustomobject]@{RequestId='deleted';Menu=[pscustomobject]@{IsOpen=$true}};$dictionary[$lineB]=[pscustomobject]@{RequestId='kept';Menu=[pscustomobject]@{IsOpen=$true}}
 }
 $script:LineProfileUI=@{Id=$lineB};$script:ConnectionCompletionUI=@{LineId=$lineB};Deliver $commit (DeletedResult)
 Check ($script:Nodes.Count -eq 1 -and $script:Nodes[0].LineId -ceq $lineB -and $script:Prefs.NodeId -ceq $lineB) 'Successful deletion removes just the proven target and preserves the other line and saved preference'
 foreach($cache in @('LinePreferenceRequests','LineCheckRequests','LineCheckResults','LineCardControls')){$dictionary=Get-Variable $cache -Scope Script -ValueOnly;Check (-not $dictionary.ContainsKey($lineA) -and $dictionary[$lineB].RequestId -ceq 'kept') ('Exact cache invalidation preserves other targets in '+$cache)}
 Check ($script:LineProfileUI.Id -ceq $lineB -and $script:ConnectionCompletionUI.LineId -ceq $lineB) 'Other line detail/completion state survives deletion'
 Check ($script:ReturnView -ceq 'web/home' -and (CountJobs Nodes) -eq 1 -and $script:FetchNodesCalls -eq 0) 'Web home uses exactly one authoritative list refresh after deletion'
 $read=LastJob Nodes;Deliver $read $null -Fail
 Check ($script:DeployUI.RecordDeletePending.Phase -ceq 'Deleted' -and $script:DeployUI.CleanupRefresh.Phase -ceq 'Failed' -and $script:Nodes.Count -eq 1) 'A failed list read preserves known deletion and the remaining cache'
 Check ($script:Elements.DialogConfirm.Content -ceq '重试刷新') 'Refresh failure offers a read-only retry'
 ConfirmDialog;Check ((CountJobs Nodes) -eq 2 -and (CountJobs RecordDeleteCommit) -eq 1) 'Refresh retry dispatches Nodes and never replays deletion'
 Deliver (LastJob Nodes) @((NewLine $lineB '模拟香港主线' 'C'))
 Check ($script:DeployUI.CleanupRefresh.Phase -ceq 'Completed' -and $script:Nodes.Count -eq 1) 'A retried authoritative list read completes normally'
 Deliver $commit (DeletedResult);Check ((CountJobs Nodes) -eq 2) 'Repeated delivery of the original commit result does not apply completion twice'

 ResetFixture;OpenDeleteNode $lineA;$job=LastJob RecordDeletePreview;$null=ShowTCWebShell 'lines';Deliver $job (Preview -Blocked)
 Check ($script:Elements.Overlay.Visibility -ceq 'Collapsed' -and (CountJobs RecordDeleteCommit) -eq 0 -and $script:Toasts[-1] -ceq '「模拟测试线路」尚未删除，需要检查处理。') 'Cross-page blocked preview reports the business state and never reopens confirmation'
 $state=GetTCWebDeleteState;Check ($state.CanCheck -and $state.Id -ceq $script:DeployUI.RecordDeletePending.OperationId -and $state.Phase -ceq 'Blocked') 'Cross-page notice retains a target-bound check action'
 SendWeb checkDelete ('f'*32);Check ($script:Commands.Count -eq 0) 'A check action cannot substitute another operation ID'
 SendWeb checkDelete $state.Id
 Check ($script:Commands.Count -eq 1 -and $script:Commands[0].Command -ceq 'Get-TCConnectionUsageEvidence' -and $script:Commands[0].Arguments.Root -ceq $script:FixtureRoot) 'Checking a blocked line first uses the read-only ownership evidence boundary'
 $command=$script:Commands[0];& $command.Complete @{State='Unknown';OwnershipKnown=$false} $command.Context
 Check ((CountJobs RecordDeletePreview) -eq 2 -and @((LastJob RecordDeletePreview).RequestData.Ids)[0] -ceq ('Line:'+$lineA)) 'Post-observation preview remains bound to the original selected target'
 Check (@($script:Requests|Where-Object {$_.Action -in @('ConnectionSwitchCommit','Session','ConnectionTransactionReconcile')}).Count -eq 0) 'Delete inspection never reconnects or starts unscoped reconciliation'

 ResetFixture;$commit=BeginConfirmedDeletion;$null=ShowTCWebShell 'settings';Deliver $commit (DeletedResult)
 Check ($script:ReturnView -ceq 'web/settings' -and $script:Nodes.Count -eq 1 -and $script:Nodes[0].LineId -ceq $lineB -and (CountJobs Nodes) -eq 1) 'Cross-page commit completion updates shared data without returning to the origin page'
 Check ($script:Toasts[-1] -clike '已删除*' -and $script:LastJobReceipt.BusinessStatus -ceq 'Deleted') 'Cross-page commit success requires the verified business result'

 ResetFixture;$commit=BeginConfirmedDeletion;$originalCleanup=$script:DeployUI.RecordDeletePending
 $unrelatedJob=@{RequestId=('e'*32);Action='FixtureMutation';RunId=$runA;OutcomeUnknown=$true;Phase='OriginalUnknown';Process=$null};$script:UncertainUiJobs.Add($unrelatedJob)
 Deliver $commit (DeletedResult)
 Check ([object]::ReferenceEquals($script:DeployUI.RecordDeletePending,$originalCleanup) -and $originalCleanup.Phase -ceq 'Deleted' -and -not $originalCleanup.PreviewToken -and $originalCleanup.Message -ceq '已删除「模拟测试线路」。') 'An unrelated uncertain job cannot overwrite the original cleanup pending or completion message'
 Check ([object]::ReferenceEquals($script:DeployUI.CleanupRefresh.Pending,$originalCleanup) -and $script:DeployUI.CleanupRefresh.OperationId -ceq $originalCleanup.OperationId -and $script:UncertainUiJobs.Count -eq 1 -and $unrelatedJob.Phase -ceq 'OriginalUnknown' -and -not $unrelatedJob.ContainsKey('PreviewToken')) 'Authoritative refresh stays bound to the original target and preserves an unrelated uncertain operation'

 ResetFixture;OpenDeleteNode $lineA;$old=LastJob RecordDeletePreview;CancelLocalCleanupPreviewUI $script:DeployUI.RecordDeletePending.OperationId;OpenDeleteNode $lineB;$latest=$script:DeployUI.RecordDeletePending
 Deliver $old (Preview)
 Check ([object]::ReferenceEquals($latest,$script:DeployUI.RecordDeletePending) -and $script:Elements.DialogTitle.Text -match '模拟香港主线') 'A cancelled older target cannot replace the newer pending target or dialog'
 $old.Failed.Invoke('late failure',$old.CallbackContext,@{Code='ReadTimeout'})|Out-Null
 Check ([object]::ReferenceEquals($latest,$script:DeployUI.RecordDeletePending) -and $latest.Phase -ceq 'Previewing') 'An old failure callback cannot clear the newer pending source'

 ResetFixture;OpenDeleteNode $lineA;$job=LastJob RecordDeletePreview;$context=$job.CallbackContext
 Check (TestUiJobCallbackContext $job.RequestData $context $job.OriginContext $job.UiRequestId) 'The original pending source/selected IDs pass callback admission'
 Check (-not (TestUiJobCallbackContext @{Action='RecordDeletePreview';Ids=@('Line:'+$lineB)} $context $job.OriginContext $job.UiRequestId)) 'Different selected IDs fail callback admission'
 $copy=$context.Clone();Check (-not (TestUiJobCallbackContext $job.RequestData $copy $job.OriginContext $job.UiRequestId)) 'A copied context cannot impersonate the pending source'
 $badPreview=Preview -Ids @('Line:'+$lineB);Deliver $job $badPreview
 Check ($script:DeployUI.RecordDeletePending.Phase -ceq 'Blocked' -and -not $script:DeployUI.RecordDeletePending.PreviewToken) 'A preview for different selected IDs cannot become a confirmation'

 ResetFixture;$script:Overview.Running=$true;$script:Overview.ActiveLineId=$lineA
 $availability=GetTCWebLineDeleteAvailability $script:Nodes[0] $script:Overview
 Check (-not $availability.CanDelete -and $availability.Message -ceq '断开后可删除') 'An active target exposes the current-use deletion reason'
 SendWeb delete $lineA;Check ($script:Requests.Count -eq 0 -and $script:Toasts[-1] -ceq '断开后可删除') 'The web deletion intent does not disconnect or submit an active target'
 SendWeb delete $lineB;Check ((CountJobs RecordDeletePreview) -eq 1) 'An independent idle target remains inspectable while another line runs'

 foreach($view in @('web-home','web-lines','legacy-home','legacy-nodes','legacy-detail','history')){
  ResetFixture
  switch($view){'web-lines'{$null=ShowTCWebShell 'lines'}'legacy-home'{ShowHome}'legacy-nodes'{ShowNodes}'legacy-detail'{LoadLineConnections $lineA}'history'{ShowUnifiedOperationHistory}}
  $pending=NewLocalCleanupTargetUI @('Line:'+$lineA);$pending.Submitted=$true;$script:DeployUI.RecordDeletePending=$pending
  $null=CompleteLocalCleanupUI (DeletedResult) $pending
  Check ((CountJobs Nodes) -eq 1 -and $script:Nodes.Count -eq 1 -and $script:Nodes[0].LineId -ceq $lineB) ($view+' shares authoritative reread and preserves the other cached line')
 }

 ResetFixture;StartJob @{Action='Nodes'} {$script:Nodes=@($args[0]);$script:OldReadApplied=$true} -Silent;$stale=LastJob Nodes;$script:OldReadApplied=$false
 $pending=NewLocalCleanupTargetUI @('Line:'+$lineA);$pending.Submitted=$true;$script:DeployUI.RecordDeletePending=$pending;$null=CompleteLocalCleanupUI (DeletedResult) $pending
 Deliver $stale @((NewLine $lineA '模拟测试线路'),(NewLine $lineB '模拟香港主线' 'C'))
 Check (-not $script:OldReadApplied -and $script:Nodes.Count -eq 1 -and $stale.Lifecycle.Terminal.Code -ceq 'LineListSuperseded') 'A pre-deletion list result cannot resurrect the deleted line'

 ResetFixture;$pending=NewLocalCleanupTargetUI @('Line:'+$lineA);$script:DeployUI.RecordDeletePending=$pending
 RequestLocalCleanupRefreshUI $pending;$oldRefresh=$script:DeployUI.CleanupRefresh;$oldRead=LastJob Nodes
 $script:DeployUI.CleanupEpoch=1;RequestLocalCleanupRefreshUI $pending;$newRefresh=$script:DeployUI.CleanupRefresh;$newRead=LastJob Nodes
 Check ($oldRefresh.Phase -ceq 'Superseded' -and -not [object]::ReferenceEquals($oldRefresh,$newRefresh) -and (CountJobs Nodes) -eq 2) 'A cleanup epoch change schedules a new read instead of keeping an obsolete Loading marker'
 Deliver $oldRead @((NewLine $lineA '模拟测试线路'))
 Check ($newRefresh.Phase -ceq 'Loading' -and $script:Nodes.Count -eq 2) 'An obsolete refresh cannot finish or fail the newer authoritative read'
 Deliver $newRead @((NewLine $lineB '模拟香港主线' 'C'))
 Check ($newRefresh.Phase -ceq 'Completed' -and $script:Nodes.Count -eq 1) 'The replacement authoritative read reaches completion'

 # Exercise the real StartJob admission/queue logic without reaching its
 # process/file dispatch branch. A normal read cannot coalesce typed callbacks.
 ResetFixture;$pending=NewLocalCleanupTargetUI @('Line:'+$lineA);$script:DeployUI.RecordDeletePending=$pending
 RequestLocalCleanupRefreshUI $pending;$refreshJob=LastJob Nodes
 $script:Job=@{Action='Nodes';Key='Nodes||||';Silent=$true};$script:Smoke=$false
 $admission=& $script:ProductionStartJob -Request $refreshJob.RequestData -Complete $refreshJob.Complete -Silent -CallbackContext $refreshJob.CallbackContext -Finalized $refreshJob.Lifecycle.Finalized -PassThru
 Check ($admission.Disposition -ceq 'Queued' -and $script:JobQueue.Count -eq 1 -and $script:DeployUI.CleanupRefresh.Phase -ceq 'Loading') 'A typed post-delete refresh is queued with its own callback even when Nodes is already running'
 $script:Smoke=$true
 ResetFixture;OpenDeleteNode $lineA;CancelLocalCleanupPreviewUI $script:DeployUI.RecordDeletePending.OperationId;OpenDeleteNode $lineB;$newPreview=LastJob RecordDeletePreview
 $script:Job=@{Action='RecordDeletePreview';Key='RecordDeletePreview||||';Silent=$true};$script:Smoke=$false
 $admission=& $script:ProductionStartJob -Request $newPreview.RequestData -Complete $newPreview.Complete -Silent -CallbackContext $newPreview.CallbackContext -Finalized $newPreview.Lifecycle.Finalized -PassThru
 Check ($admission.Disposition -ceq 'Queued' -and $script:JobQueue.Count -eq 1 -and @($script:JobQueue[0].Request.Ids)[0] -ceq ('Line:'+$lineB)) 'A cancelled older preview cannot coalesce away the next target inspection'
 $script:Smoke=$true

 ResetFixture;CompleteLocalCleanupRecoveryUI @{CompletedResults=@(@{DeletedLineIds=@($lineA);DeletedIds=@()})}
 Check ($script:Nodes.Count -eq 2) 'Recovery entries lacking actual DataDeleted proof do not mutate caches'
 ResetFixture;CompleteLocalCleanupRecoveryUI @{CompletedResults=@((DeletedResult))}
 Check ($script:Nodes.Count -eq 1 -and $script:Nodes[0].LineId -ceq $lineB -and (CountJobs Nodes) -eq 1) 'Committed recovery uses the same precise invalidation and reread'

 foreach($scope in @('DeploymentRun','ServerRecord')){
  ResetFixture;$key=if($scope -eq 'DeploymentRun'){$runA}else{$serverA};$id=$scope+':'+$key;$script:DeployUI.HistoryRecords=@([pscustomobject]@{Id=$id;Name='所选测试资料'})
  DeleteOperationRecordsUI -Ids @($id);$preview=Preview -Ids @($id);Deliver (LastJob RecordDeletePreview) $preview
  Check ($script:Elements.DialogConfirm.Content -ceq $(if($scope -eq 'DeploymentRun'){'删除任务记录'}else{'删除服务器资料'})) ($scope+' has a scope-specific confirmation label')
 }
 ResetFixture;DeleteOperationRecordsUI -Ids @(('Line:'+$lineA),('DeploymentRun:'+$runA))
 Check ($script:Requests.Count -eq 0) 'Mixed object scopes cannot enter a misleading shared confirmation'

 # Real private fixture files exercise the shared Read-TCDJson boundary. Only
 # compact public fields leave the journal reader, even with extra test data.
 ResetFixture;$transactionId='a'*32;$directory=New-TCDDirectory (Join-Path $script:FixtureRoot 'connection-transactions');$path=Join-Path $directory ($transactionId+'.json')
 $transaction=@{SchemaVersion=1;Id=$transactionId;Root=$script:FixtureRoot;JournalPath=$path;LineId=$lineA;ProfileId='Tcp';RequestId=('b'*32);Status='RolledBack';UpdatedAt=[DateTimeOffset]::UtcNow.AddMinutes(-5).ToString('o');Failure=@{Code='LineForwardingUnverified'};Target=@{CandidateSHA256=('A'*64);ManifestSHA256=('B'*64);Manifest=@{TCProfileRevision=2}};Original=@{FixturePrivate='UI-MUST-NOT-EXPORT-THIS'}}
 Write-TCDJson $path $transaction;UpdateTCWebPersistedConnectionAttemptsUI
 $attempt=ReadTCWebConnectionAttempt $transactionId $lineA
 Check ($attempt -and -not $attempt.ContainsKey('Original') -and -not $attempt.ContainsKey('Target')) 'Persisted transaction IO projects only whitelisted display fields'
 Check ($null -eq (ReadTCWebConnectionAttempt $transactionId $lineB)) 'The exact journal reader rejects a different line binding'
 $notice=GetTCWebRecentConnectionFailure $script:Nodes[0] 'Tcp'
 Check ($notice -and $notice.Count -eq 2 -and $notice.ProfileId -ceq 'Tcp') 'A current failed transaction emits exactly ProfileId and UTC expiry'
 $snapshot=GetTCWebSnapshot
 Check ($snapshot.Lines[0].RecentConnectionFailure -and ($snapshot|ConvertTo-Json -Depth 30 -Compress) -notmatch 'UI-MUST-NOT-EXPORT-THIS') 'The browser payload includes the bound recent failure without private transaction data'
 Check ($null -eq (GetTCWebRecentConnectionFailure $script:Nodes[0] 'Udp')) 'A connection-method change suppresses the old failure notice'
 foreach($field in @('CandidateSHA256','ManifestSHA256','Revision')){
  $profile=$script:Nodes[0].Profiles[0];$value=$profile.$field;$profile.$field=if($field -eq 'Revision'){99}else{'F'*64}
  Check ($null -eq (GetTCWebRecentConnectionFailure $script:Nodes[0] 'Tcp')) ($field+' change suppresses the old failure notice');$profile.$field=$value
 }
 Check ($null -eq (GetTCWebRecentConnectionFailure $script:Nodes[0] 'Tcp' ([DateTimeOffset]::UtcNow.AddHours(2)))) 'Expiry suppresses a formerly bound failure notice'
 $script:WebConnectionAttempts[$lineA].LineRevision=7;$script:Nodes[0].Revision=8
 Check ($null -eq (GetTCWebRecentConnectionFailure $script:Nodes[0] 'Tcp')) 'An explicit transaction line revision must match the current revision'
 $script:Nodes[0].Revision=7;$transaction.Status='Completed';$transaction.Failure=$null;$transaction.UpdatedAt=[DateTimeOffset]::UtcNow.ToString('o');Write-TCDJson $path $transaction;UpdateTCWebPersistedConnectionAttemptsUI
 Check ($null -eq (GetTCWebRecentConnectionFailure $script:Nodes[0] 'Tcp')) 'The latest successful attempt clears the old failed attempt notice'

 $originalAcl=[IO.File]::GetAccessControl($path)
 try{
  $openAcl=[IO.File]::GetAccessControl($path);$openAcl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule ([Security.Principal.SecurityIdentifier]::new('S-1-1-0')),([Security.AccessControl.FileSystemRights]::Read),([Security.AccessControl.AccessControlType]::Allow)));[IO.File]::SetAccessControl($path,$openAcl)
  Check ($null -eq (ReadTCWebConnectionAttempt $transactionId $lineA)) 'The shared journal reader refuses a fixture file opened to other accounts'
 }finally{[IO.File]::SetAccessControl($path,$originalAcl)}
 [IO.File]::WriteAllText($path,(' '*4194305),[Text.UTF8Encoding]::new($true))
 Check ($null -eq (ReadTCWebConnectionAttempt $transactionId $lineA)) 'The shared journal reader refuses an oversized transaction before projection'
 Write-TCDJson $path $transaction

 # Unknown commit checks read the original sealed outcome and journal, never
 # reissue RecordDeleteCommit. The UI releases its latch only after proof.
 foreach($executorState in @('Running','Unknown')){
  ResetFixture;$commit=BeginConfirmedDeletion;Deliver $commit @{DataDeleted=$false} -Unknown;$pending=$script:DeployUI.RecordDeletePending;$script:Job=$null;$script:ExecutorFixture=$executorState
  CheckOriginalLocalCleanupResultUI $pending
  Check ($script:Commands.Count -eq 0 -and $script:ReceiptRefreshes -eq 0 -and $pending.Phase -ceq 'OutcomeUnknown' -and $pending.Submitted -and $pending.PreviewToken -ceq 'sealed-preview' -and $script:Nodes.Count -eq 2) ($executorState+' original executor cannot be unlocked by a no-journal NotApplied snapshot')
  OpenDeleteNode $lineB;Check ((CountJobs RecordDeleteCommit) -eq 1 -and (CountJobs RecordDeletePreview) -eq 1) ($executorState+' original executor keeps the duplicate submission barrier')
 }
 ResetFixture;$commit=BeginConfirmedDeletion;Deliver $commit @{DataDeleted=$false} -Unknown;$pending=$script:DeployUI.RecordDeletePending;$script:Job=$null
 CheckOriginalLocalCleanupResultUI $pending;$command=$script:Commands[0];$script:ExecutorFixture='Unknown';& $command.Complete @{Outcome='NotApplied';DataDeleted=$false} $command.Context
 Check ($pending.Phase -ceq 'OutcomeUnknown' -and $pending.Submitted -and $pending.PreviewToken -ceq 'sealed-preview') 'Loss of executor evidence before outcome delivery keeps the original submission unresolved'

 ResetFixture;$commit=BeginConfirmedDeletion;Deliver $commit @{DataDeleted=$false} -Unknown
 $pending=$script:DeployUI.RecordDeletePending;$script:Job=$null;SendWeb checkDelete $pending.OperationId
 Check ($script:Commands.Count -eq 1 -and $script:Commands[0].Command -ceq 'Get-TCLocalDeploymentCleanupOutcome' -and $script:Commands[0].Arguments.PreviewToken -ceq 'sealed-preview') 'Unknown-result checking reads the original sealed deletion outcome'
 $command=$script:Commands[0];& $command.Complete @{Outcome='NotApplied';DataDeleted=$false} $command.Context
 Check ($pending.Phase -ceq 'NotApplied' -and -not $pending.Submitted -and -not $pending.PreviewToken -and (CountJobs RecordDeleteCommit) -eq 1) 'Verified NotApplied releases the latch without replaying deletion'

 ResetFixture;$commit=BeginConfirmedDeletion;Deliver $commit @{DataDeleted=$false} -Unknown;$pending=$script:DeployUI.RecordDeletePending;$script:Job=$null;$pending.CommitJob=$null
 Write-TCDJson (Join-Path $script:JobRoot ($pending.CommitRequestId+'.request.json')) @{RequestId=$pending.CommitRequestId;Action='RecordDeleteCommit';PreviewToken='sealed-preview'}
 Write-TCDJson (Join-Path $script:JobRoot ($pending.CommitRequestId+'.receipt.json')) @{SchemaVersion=1;RequestId=$pending.CommitRequestId;OperationId=$pending.CommitRequestId;Action='RecordDeleteCommit';Status='Completed';ProcessId=424242;ProcessStartedTicks=$script:ExecutorStartedUtc.Ticks}
 $script:ExecutorFixture='Running';CheckOriginalLocalCleanupResultUI $pending
 Check ($script:Commands.Count -eq 0 -and $pending.Submitted) 'A terminal-looking receipt cannot override a live original executor'
 $script:ExecutorFixture='Unknown';CheckOriginalLocalCleanupResultUI $pending
 Check ($script:Commands.Count -eq 0 -and $pending.Submitted) 'Unreadable original PID identity cannot be treated as an exited process'
 $script:ExecutorFixture='Reused';CheckOriginalLocalCleanupResultUI $pending
 Check ($script:Commands.Count -eq 1 -and $pending.Submitted) 'A reused PID proves the bound original birth ended without touching the replacement process'
 $command=$script:Commands[0];& $command.Complete @{Outcome='NotApplied';DataDeleted=$false} $command.Context
 Check ($pending.Phase -ceq 'NotApplied' -and -not $pending.Submitted -and (CountJobs RecordDeleteCommit) -eq 1) 'Bound persisted request, receipt and ended executor can resolve NotApplied without replay'

 ResetFixture;$commit=BeginConfirmedDeletion;Deliver $commit @{DataDeleted=$false} -Fail -Unknown;$pending=$script:DeployUI.RecordDeletePending;$script:Job=$null
 Check ($pending.Phase -ceq 'OutcomeUnknown' -and $pending.Submitted) 'An unverified commit error keeps the original confirmation bound for receipt checking'
 OpenDeleteNode $lineB;Check ((CountJobs RecordDeletePreview) -eq 1) 'A commit error cannot silently replace the submitted target'

 ResetFixture;$commit=BeginConfirmedDeletion;Deliver $commit @{DataDeleted=$false} -Unknown;$pending=$script:DeployUI.RecordDeletePending;$script:Job=$null
 $null=New-TCDDirectory $script:JobRoot;Write-TCDJson (Join-Path $script:JobRoot ($pending.CommitRequestId+'.receipt.json')) @{SchemaVersion=1;RequestId=$pending.CommitRequestId;Action='RecordDeleteCommit';Status='OutcomeUnknown'}
 CheckOriginalLocalCleanupResultUI $pending;$command=$script:Commands[0];& $command.Complete @{Outcome='Committed';CleanupId=[guid]::NewGuid().ToString('D');DataDeleted=$false} $command.Context
 Check ($script:Elements.DialogConfirm.Content -ceq '恢复并检查' -and $pending.Phase -ceq 'OutcomeUnknown' -and $pending.Submitted) 'An unfinished outcome with an ended executor exposes bounded recovery and retains the submission latch'
 ConfirmDialog;Check ((CountJobs RecordCleanupRecover) -eq 1 -and (CountJobs RecordDeleteCommit) -eq 1) 'Incomplete recovery has a next action without replaying deletion'

 ResetFixture;$commit=BeginConfirmedDeletion;Deliver $commit @{DataDeleted=$false} -Unknown;$pending=$script:DeployUI.RecordDeletePending;$script:Job=$null
 $null=New-TCDDirectory $script:JobRoot;Write-TCDJson (Join-Path $script:JobRoot ($pending.CommitRequestId+'.receipt.json')) @{SchemaVersion=1;RequestId=$pending.CommitRequestId;Action='RecordDeleteCommit';Status='OutcomeUnknown'}
 $script:ExecutorFixture='Running';CheckOriginalLocalCleanupResultUI $pending
 Check ($script:Elements.DialogConfirm.Content -ceq '查看原删除记录' -and $pending.Submitted) 'A still-running original operation offers its receipt without authorizing cleanup'
 ConfirmDialog;Check ($script:OpenedReceipt.RequestId -ceq $pending.CommitRequestId -and (CountJobs RecordDeleteCommit) -eq 1) 'The receipt entry opens only the original request without another delete'

 ResetFixture;$commit=BeginConfirmedDeletion;Deliver $commit @{DataDeleted=$false} -Unknown;$pending=$script:DeployUI.RecordDeletePending;$script:Job=$null
 $cleanupId=[guid]::NewGuid().ToString('D');$root=(Assert-TCDPath $script:Root).TrimEnd('\');$journalPath=Join-Path $script:Root ('local-cleanup\'+$cleanupId+'\journal.json')
 Write-TCDJson $journalPath @{SchemaVersion=1;Id=$cleanupId;Status='Completed';UserSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;RootDigest=(Get-TCDDigest $root.ToLowerInvariant());TokenDigest=(Get-TCDDigest 'sealed-preview');Result=(DeletedResult)}
 CheckOriginalLocalCleanupResultUI $pending;$command=$script:Commands[0];& $command.Complete @{Outcome='Completed';CleanupId=$cleanupId;DataDeleted=$true} $command.Context
 Check ($pending.Phase -ceq 'Deleted' -and $script:Nodes.Count -eq 1 -and $script:Nodes[0].LineId -ceq $lineB -and (CountJobs RecordDeleteCommit) -eq 1) 'Matching original completed journal finalizes deletion without replay'

 $passed=$true
}catch{$failure=$_.Exception.Message;throw}
finally{
 if([IO.Directory]::Exists($script:FixtureRoot)){
  $full=[IO.Path]::GetFullPath($script:FixtureRoot);$expected=Join-Path ([IO.Path]::GetTempPath()) ('tc-delete-ui-'+$script:FixtureId)
  if($full -cne $expected -or -not $full.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase)){throw 'Fixture cleanup target escaped the owned temporary directory.'}
  $marker=Read-TCDJson (Join-Path $full '.owned.json');if($marker.Id -cne $script:FixtureId){throw 'Fixture cleanup owner mismatch.'}
  if(@(Get-ChildItem -LiteralPath $full -Recurse -Force|Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count){throw 'Fixture cleanup refuses reparse points.'}
  Remove-Item -LiteralPath $full -Recurse -Force;$fixtureRemoved=(-not [IO.Directory]::Exists($full))
 }
 [pscustomobject]@{Passed=$passed;PowerShell=$PSVersionTable.PSVersion.ToString();Checks=$script:Checks.Count;EvidenceScope='Production UI callbacks with in-memory window, worker and receipt boundaries; private fixture journal IO only. Not a real WebView2 or Worker integration test.';ProductionWrites=0;WorkersStarted=0;NetworkActions=0;FixtureRemoved=$fixtureRemoved;Failure=$failure;Assertions=@($script:Checks.ToArray())}|ConvertTo-Json -Depth 5
}
