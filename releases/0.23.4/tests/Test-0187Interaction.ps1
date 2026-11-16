#requires -Version 5.1
[CmdletBinding()]param([string]$PackageRoot='',[Parameter(Mandatory=$true)][string]$ReportDirectory)
$ErrorActionPreference='Stop'
if([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw 'Use Windows PowerShell -Sta.'}
if(-not $PackageRoot){$PackageRoot=Split-Path $PSScriptRoot -Parent}
$script:FixturePackageRoot=[IO.Path]::GetFullPath($PackageRoot)
$script:ReportRoot=[IO.Path]::GetFullPath($ReportDirectory)
if($script:ReportRoot.StartsWith('C:\ProgramData\',[StringComparison]::OrdinalIgnoreCase) -or $script:ReportRoot.StartsWith('C:\tradechannel',[StringComparison]::OrdinalIgnoreCase)){throw 'Use a workspace report directory.'}
$null=[IO.Directory]::CreateDirectory($script:ReportRoot)
function Start-Process {throw 'Workflow tests forbid external process launches.'}
function Stop-Process {throw 'Workflow tests forbid stopping real processes.'}
function Invoke-WebRequest {throw 'Workflow tests forbid network access.'}
function Invoke-RestMethod {throw 'Workflow tests forbid network access.'}

# Initialize exactly the production presentation and business callbacks. Stop
# before startup, timers or worker dispatch; SelfTest owns a new temporary store.
$SelfTest=$true;$ReadOnlyLaunch=$false;$StartupLaunch=$false;$TestOutputDirectory=''
$source=[IO.File]::ReadAllText((Join-Path $script:FixturePackageRoot 'TradeChannel.ps1'))
$begin=$source.IndexOf('$ErrorActionPreference=')
$end=$source.IndexOf("foreach(`$name in @('Home','Nodes','Setup','Settings'))")
if($begin -lt 0 -or $end -le $begin){throw 'Presentation bootstrap boundary changed.'}
$bootstrap=$source.Substring($begin,$end-$begin).Replace('$PSScriptRoot','$script:FixturePackageRoot')
Invoke-Expression $bootstrap
$script:WebFormsFixture=$true
$script:Tray=New-Object Windows.Forms.NotifyIcon
$script:Window.ShowInTaskbar=$false;$script:Window.ShowActivated=$false
$script:Window.Left=-16000;$script:Window.Top=-16000;$script:Window.Width=1280;$script:Window.Height=900
$script:TestChecks=New-Object 'Collections.Generic.List[string]'
$script:CompletedJobs=New-Object 'Collections.Generic.HashSet[object]'
$hk='11111111-1111-1111-1111-111111111111';$us='22222222-2222-2222-2222-222222222222'
$tokens=$null;$parseErrors=$null
$fixtureAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $script:PackageRoot 'ui\SelfTest.ps1'),[ref]$tokens,[ref]$parseErrors)
$fixtureFunction=@($fixtureAst.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst]},$false)|Where-Object Name -eq 'Fixture')[0]
Set-Item Function:script:Fixture ([scriptblock]::Create($fixtureFunction.Body.Extent.Text.Substring(1,$fixtureFunction.Body.Extent.Text.Length-2)))
Fixture
foreach($node in $script:Nodes){$node|Add-Member NoteProperty LineId $node.id -Force}
$script:Overview|Add-Member NoteProperty ActiveLineId $hk -Force
$script:Overview|Add-Member NoteProperty ActiveProfileId 'Udp' -Force
$script:Overview|Add-Member NoteProperty ReadState 'Known' -Force
$script:Overview|Add-Member NoteProperty SessionId 'workflow-fixture' -Force
$script:UserSettings=@{AutoTrustFirstConnection=$true;AutoConnectOnLogin=$false}
$script:WebTasksAt=[DateTime]::UtcNow
function Check {param([bool]$Condition,[string]$Name)if(-not $Condition){throw ('Workflow assertion: '+$Name)};$script:TestChecks.Add($Name)}
function Pump {[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 15}
function Await {param($Task)$deadline=[DateTime]::UtcNow.AddSeconds(20);while(-not $Task.IsCompleted){Pump;if([DateTime]::UtcNow -gt $deadline){throw 'WebView operation exceeded deadline'}};$Task.GetAwaiter().GetResult()}
function Js {param([string]$Code)Await ($script:WebShell.CoreWebView2.ExecuteScriptAsync($Code))}
function WaitDom {param([string]$Expression)$deadline=[DateTime]::UtcNow.AddSeconds(12);do{Pump;if((Js $Expression) -ceq 'true'){return}}while([DateTime]::UtcNow -lt $deadline);throw ('DOM condition: '+$Expression)}
function Click {param([string]$Selector)
 $literal=$Selector|ConvertTo-Json -Compress
 WaitDom ("!!document.querySelector("+$literal+") && !document.querySelector("+$literal+").disabled")
 $null=Js ("document.querySelector("+$literal+").click()")
 for($i=0;$i -lt 3;$i++){Pump}
}
function FieldValue {param([string]$Name,[string]$Value)
 $selector=('[data-control-name="'+$Name+'"]')|ConvertTo-Json -Compress;$literal=$Value|ConvertTo-Json -Compress
 $null=Js ("(() => {const input=document.querySelector("+$selector+"); input.focus(); input.value="+$literal+"; input.dispatchEvent(new Event('input',{bubbles:true}));})()")
 for($i=0;$i -lt 3;$i++){Pump}
}
function CompleteJob {param([string]$Action,$Data)
 $job=@($script:Actions|Where-Object {$_.Request.Action -ceq $Action -and -not $script:CompletedJobs.Contains($_)}|Select-Object -Last 1)
 if($job.Count -ne 1){throw ('No pending isolated action: '+$Action)}
 $job=$job[0];$null=$script:CompletedJobs.Add($job);$script:Pending=$null
 if($job.Complete){& $job.Complete $Data $job.CallbackContext}
 if($job.Lifecycle.Finalized){& $job.Lifecycle.Finalized ([pscustomobject]@{UiRequestId=$job.Lifecycle.UiRequestId;Status='Completed'}) $job.CallbackContext}
 $script:HostPanel.IsEnabled=$true;SyncTCWebState -Force
}
function CheckWeb {param([string]$Name)
 Check ($script:WebShell.Visibility -eq 'Visible' -and $script:Window.FindName('Scroll').Parent.Visibility -eq 'Collapsed' -and $script:Window.FindName('NavHome').Parent.Visibility -eq 'Collapsed') ($Name+' stays in the web shell')
 Check ((Js "document.body.textContent.includes('此控件暂不支持') || document.body.textContent.includes('此内容暂不支持')") -ceq 'false') ($Name+' has no unsupported controls')
}
function Shot {param([string]$Name)
 [IO.File]::WriteAllText((Join-Path $script:ReportRoot ($Name+'.snapshot.json')),(@{Type='snapshot';State=(GetTCWebSnapshot);Page=$script:WebPage}|ConvertTo-Json -Depth 48),[Text.UTF8Encoding]::new($true))
 $stream=[IO.File]::Open((Join-Path $script:ReportRoot ($Name+'.png')),[IO.FileMode]::Create)
 try{$null=Await ($script:WebShell.CoreWebView2.CapturePreviewAsync([Microsoft.Web.WebView2.Core.CoreWebView2CapturePreviewImageFormat]::Png,$stream))}finally{$stream.Dispose()}
}
function MainPage {param([string]$Name)Click ('nav [data-page="'+$Name+'"]');WaitDom ('!document.querySelector(".workflow") && document.querySelector("nav .active").dataset.page === '+($Name|ConvertTo-Json -Compress))}
function ChooseFile {param($Title,$Filter,[switch]$Save,$Name)if($Filter -like '*.exe*'){Join-Path $script:Root 'terminal64.exe'}else{Join-Path $script:Root 'fixture-diagnostics.json'}}

$script:MemoryActions=New-Object 'Collections.Generic.List[object]'
function StartUiCommand {param($Module,$Command,$Arguments,$Context,$Complete,$Failed,$Message)
 if($Module -cnotin @('OperationHistory.psm1','RuntimeBridge.psm1')){throw 'Unexpected isolated read module'}
 $script:MemoryActions.Add(@{Module=$Module;Command=$Command;Arguments=$Arguments;Context=$Context;Complete=$Complete;Failed=$Failed})
}
function GetUiCleanupExecutorState {param($Pending) return $script:FixtureExecutorState}
function FailJob {param([string]$Action,[string]$Code,[bool]$Unknown)
 $job=@($script:Actions|Where-Object {$_.Request.Action -ceq $Action -and -not $script:CompletedJobs.Contains($_)}|Select-Object -Last 1)[0]
 $null=$script:CompletedJobs.Add($job);$script:Pending=$null
 & $job.Failed 'isolated failure' $job.CallbackContext ([pscustomobject]@{Ok=$false;Code=$Code;OutcomeUnknown=$Unknown;Phase='Executing'})
 if($job.Lifecycle.Finalized){& $job.Lifecycle.Finalized ([pscustomobject]@{UiRequestId=$job.Lifecycle.UiRequestId;Status='Failed';Code=$Code}) $job.CallbackContext}
 SyncTCWebState -Force
}
function LatestCapture {param([string]$Action)@($script:Actions|Where-Object {$_.Request.Action -ceq $Action -and -not $script:CompletedJobs.Contains($_)}|Select-Object -Last 1)[0]}
function PreferenceResult {param([string]$Mode,[string]$Profile='Udp',[switch]$NeedsCheck)
 $result=$script:Nodes[0].PSObject.Copy();$result.Revision++
 $saved=if($NeedsCheck){$null}else{[pscustomobject]@{ProfileId=$Profile;Source=$(if($Mode -eq 'Auto'){'Reachability'}else{'UserChoice'});Digest=('B'*64)}}
 foreach($entry in @{SavedConnectionPreference=$saved;PreferenceMode=$Mode;PreferenceSource=$(if($saved){$saved.Source}else{''});PreferredProfileId=$(if($saved){$Profile}else{''});DefaultVerified=(!$NeedsCheck);PreferenceOutcome=$(if($NeedsCheck){'NeedsCheck'}elseif($Mode -eq 'Auto'){'AutomaticRecommendation'}else{'Manual'});PreferenceNextAction=$(if($NeedsCheck){'CheckLineProfiles'}else{''})}.GetEnumerator()){$result|Add-Member NoteProperty $entry.Key $entry.Value -Force}
 return $result
}
function PreviewFor {param($Pending) [pscustomobject]@{BusinessState='PreviewReady';SelectedIds=@($Pending.Ids);EligibleCount=$Pending.Ids.Count;PreviewToken='fixture-confirmation';Blocked=@();Warnings=@();Preserved=@();TransactionIds=@();LineCount=1;FileCount=2;OperationCount=0}}
function BeginDelete {
 MainPage 'lines';Click ('[data-detail="'+$us+'"]');Click '[data-action="delete"]'
}
function CommitCount {@($script:Actions|Where-Object {$_.Request.Action -ceq 'RecordDeleteCommit'}).Count}
$passed=$false;$failure=''
try{
 $script:Window.Show();[Threading.SynchronizationContext]::SetSynchronizationContext((New-Object Windows.Threading.DispatcherSynchronizationContext($script:Window.Dispatcher)))
 InitializeTCWebShell -DataFolder (Join-Path $script:Root 'browser') -Fixture
 $deadline=[DateTime]::UtcNow.AddSeconds(25)
 while(-not $script:WebReady -and -not $script:WebFailed -and [DateTime]::UtcNow -lt $deadline){Pump}
 Check ($script:WebReady -and -not $script:WebFailed) ('WebView2 initialized: '+$script:WebFailureMessage)
 $tcp=$script:Nodes[0].Profiles[0].PSObject.Copy();$tcp.Id='Tcp';$tcp.Mode='Tcp';$tcp.ManifestPath='fixture-tcp'
 $script:Nodes[0].Profiles=@($script:Nodes[0].Profiles[0],$tcp)
 $script:Nodes[0]|Add-Member NoteProperty SavedConnectionPreference ([pscustomobject]@{ProfileId='Udp';Source='Reachability';Digest=('A'*64)}) -Force
 $script:Nodes[0]|Add-Member NoteProperty DefaultVerified $true -Force
 SyncTCWebState -Force;MainPage 'lines';Click ('[data-detail="'+$hk+'"]')
 WaitDom "!document.querySelector('[data-value=Auto]').disabled && document.querySelector('[data-value=Auto]').getAttribute('aria-pressed') === 'true'"
 Check $true 'Automatic selection is available in the actual line drawer'
 Click '[data-value="Udp"]';$manual=LatestCapture LinePreference
 Check ($manual.Request.ProfileId -ceq 'Udp') 'Selecting the currently recommended standard method explicitly saves a manual pin'
 CompleteJob LinePreference (PreferenceResult Manual)
 WaitDom "document.querySelector('[data-value=Udp]').getAttribute('aria-pressed') === 'true'"
 Click '[data-value="Auto"]';$reset=LatestCapture LinePreferenceReset
 Check ($reset.Request.Id -ceq $hk -and $reset.Request.ExpectedRevision -eq $script:Nodes[0].Revision -and $reset.Request.ExpectedDigest -ceq $script:Nodes[0].SavedConnectionPreference.Digest) 'Automatic reset retains the exact line, CAS revision and prior preference digest'
 Check (TestUiJobCallbackContext $reset.Request $reset.CallbackContext (CaptureNavigationContext) $reset.Lifecycle.UiRequestId) 'The actual automatic-reset callback passes the production request binding gate'
 $mismatch=$reset.Request.Clone();$mismatch.ExpectedDigest=('F'*64)
 Check (-not (TestUiJobCallbackContext $mismatch $reset.CallbackContext (CaptureNavigationContext) $reset.Lifecycle.UiRequestId)) 'A reset callback cannot consume a different preference digest'
 Check ($script:Window.FindName('Overlay').Visibility -ne 'Visible') 'Changing to automatic does not require an extra confirmation'
 CompleteJob LinePreferenceReset (PreferenceResult Auto)
 WaitDom "document.querySelector('[data-value=Auto]').getAttribute('aria-pressed') === 'true' && !document.querySelector('[data-value=Auto]').disabled"
 Check ($script:Overview.Running -and $script:Overview.ActiveLineId -ceq $hk -and $script:Overview.ActiveProfileId -ceq 'Udp') 'Changing the next preference preserves the connected line and current method'
 Check (@($script:Actions|Where-Object {$_.Request.Action -in @('Session','ConnectionSwitchCommit','AutoConnectCommit')}).Count -eq 0) 'Preference edits dispatch no connection, stop or hot-switch command'
 Shot '01-automatic-light'
 Click '[data-value="Tcp"]';CompleteJob LinePreference (PreferenceResult Manual Tcp)
 Click '[data-value="Auto"]';CompleteJob LinePreferenceReset (PreferenceResult Auto -NeedsCheck)
 WaitDom "document.querySelector('.drawer').textContent.includes('请先测试线路') && !document.querySelector('[data-action=testLine]').disabled"
 Check $true 'Automatic without a recommendation gives a usable test entry and selects neither manual method'
 Shot '02-automatic-needs-check'
 $null=Js "document.querySelector('[data-close=drawer]').click()";Pump

 BeginDelete
 WaitDom "!!document.querySelector('.cleanup-progress') && !!document.querySelector('[aria-busy=true]')"
 Check ((Js "document.querySelector('[role=alertdialog] .spinner') === null && document.querySelectorAll('.cleanup-step').length === 3") -ceq 'true') 'Deletion checks show three stable steps instead of a spinning title glyph'
 Check ((Js "getComputedStyle(document.querySelector('.cleanup-track span')).animationName === 'cleanup-sweep'") -ceq 'true') 'Deletion activity uses a subtle progress track'
 Shot '03-delete-check-light'
 $null=Js "document.documentElement.dataset.theme='dark'";Shot '04-delete-check-dark'
 $deleteAttempt=$script:DeployUI.RecordDeletePending
 CompleteJob RecordDeletePreview (PreviewFor $deleteAttempt)
 WaitDom "document.querySelector('[data-action=confirmDialog]')?.textContent === '删除线路'"
 Click '[data-action="confirmDialog"]';$firstCommit=LatestCapture RecordDeleteCommit
 Check ((CommitCount) -eq 1 -and $script:DeployUI.RecordDeletePending.Submitted) 'Deletion requires one confirmation and submits only once'
 FailJob RecordDeleteCommit CleanupPreviewStale $false
 WaitDom "document.querySelector('[data-action=confirmDialog]')?.textContent === '重新检查并删除'"
 Check ($deleteAttempt.Phase -ceq 'NotApplied' -and -not $deleteAttempt.Submitted -and -not $deleteAttempt.PreviewToken) 'A definite stale-preview refusal releases the old confirmation without claiming an unknown deletion'
 Check ((Js "document.querySelector('[role=alertdialog]').textContent.includes('尚未删除') && !document.querySelector('[role=alertdialog]').textContent.includes('结果待确认')") -ceq 'true') 'The refusal explains that the target remains and offers the next action'
 Shot '05-delete-not-applied'
 Click '[data-action="confirmDialog"]'
 Check ($script:DeployUI.RecordDeletePending.OperationId -cne $deleteAttempt.OperationId -and (CommitCount) -eq 1) 'Retry creates a fresh preview identity and never replays the old deletion'
 Check (@($script:Actions|Where-Object Request -NE $null|Where-Object {$_.Request.Action -ceq 'RecordDeletePreview'}).Count -eq 2) 'Retry reaches the real preview action instead of a dialog loop'
 $retry=$script:DeployUI.RecordDeletePending;CompleteJob RecordDeletePreview (PreviewFor $retry);Click '[data-action="cancelDialog"]'
 Check ((CommitCount) -eq 1 -and $script:Overview.Running -and $script:Nodes.Count -eq 2) 'Cancelling a renewed confirmation preserves both lines and the active connection'

 # A lost result remains latched until a bound, exited executor is reconciled.
 BeginDelete;$unknown=$script:DeployUI.RecordDeletePending;CompleteJob RecordDeletePreview (PreviewFor $unknown);Click '[data-action="confirmDialog"]'
 $script:FixtureExecutorState='Running';FailJob RecordDeleteCommit WorkerStepFailed $true
 Check ($unknown.Phase -ceq 'OutcomeUnknown' -and $unknown.Submitted -and $unknown.PreviewToken) 'An uncertain result keeps its original token and submission latch'
 $script:FixtureExecutorState='Exited';$unknown.CommitRequestId=('c'*32)
 CloseDialog;CheckOriginalLocalCleanupResultUI $unknown
 $read=$script:MemoryActions[-1]
 Check ($read.Command -ceq 'Get-TCLocalDeploymentCleanupOutcome' -and $read.Arguments.PreviewToken -ceq $unknown.PreviewToken) 'Checking a result reads the exact original deletion instead of submitting a new one'
 & $read.Complete $null $read.Context;SyncTCWebState -Force
 WaitDom "document.querySelector('[data-action=confirmDialog]')?.textContent === '恢复并检查'"
 Click '[data-action="confirmDialog"]';$recovery=LatestCapture RecordCleanupRecover
 Check (TestUiJobCallbackContext $recovery.Request $recovery.CallbackContext (CaptureNavigationContext) $recovery.Lifecycle.UiRequestId) 'Interrupted cleanup recovery retains its original target and passes the production callback gate'
 Check ($unknown.Submitted -and (CommitCount) -eq 2) 'Recovery does not release the unknown latch or repeat the delete request'
 CompleteJob RecordCleanupRecover ([pscustomobject]@{RecoveredCount=1;CompletedResults=@()})
 $read=$script:MemoryActions[-1]
 & $read.Complete ([pscustomobject]@{Outcome='NotApplied';DataDeleted=$false}) $read.Context
 SyncTCWebState -Force
 WaitDom "document.querySelector('[data-action=confirmDialog]')?.textContent === '重新检查并删除'"
 Check ($unknown.Phase -ceq 'NotApplied' -and -not $unknown.Submitted -and (CommitCount) -eq 2) 'Verified not-applied result leads to a fresh-check entry without another commit'
 Click '[data-action="cancelDialog"]'
 WaitDom "!!document.querySelector('[data-action=retryDelete]')"
 Check $true 'Closing the result dialog keeps an actionable retry entry on the page'
 Shot '06-delete-retry-entry'
 Check ((GetLocalCleanupResultStateUI ([pscustomobject]@{BusinessState='NotApplied';Outcome='NotApplied';DataDeleted=$false})) -ceq 'NotApplied') 'A not-applied business result cannot be mistaken for an uncertain deletion'

 # An unrelated old operation is named explicitly beside the live connection.
 $entry=@{RequestId=('d'*32);Action='LinePreferenceReset';LineId=$us;ResourceScope=@{Kind='Line';LineIds=@($us)}}
 $script:UncertainUiJobs.Add($entry);MainPage 'home';SyncTCWebState -Force
 WaitDom "!!document.querySelector('[data-action=reviewOperation]') && document.querySelector('.signal-title').textContent.includes('已连接')"
 Check ((Js "document.body.textContent.includes('恢复自动选择') && document.body.textContent.includes('当前线路仍在使用')") -ceq 'true') 'The home page identifies the pending task while retaining the connected state'
 Click '[data-action="reviewOperation"]'
 WaitDom "document.querySelector('#dialog-title')?.textContent === '恢复自动选择结果待确认'"
 Check ($script:Window.FindName('DialogNote').Text -like '*当前线路仍在使用*' -and $script:Window.FindName('DialogConfirm').Content -ceq '检查原操作') 'The receipt dialog explains the exact task and does not promise automatic resubmission'
 Shot '07-connected-pending-task'
 $passed=$true
}catch{
 $failure=$_.Exception.Message
 try{Shot 'failure';[IO.File]::WriteAllText((Join-Path $script:ReportRoot 'failure-dom.txt'),(Js 'document.body.innerText'),[Text.UTF8Encoding]::new($true))}catch{}
 throw
}finally{
 $result=[ordered]@{Passed=$passed;Checks=$script:TestChecks.Count;Assertions=$script:TestChecks.ToArray();Failure=$failure;NetworkChanged=$false;WorkersStarted=0;BrowserRuntime='WebView2';CapturedWorkerActions=@($script:AllSelfTestRequests|ForEach-Object {$_.Request.Action})}
 [IO.File]::WriteAllText((Join-Path $script:ReportRoot 'result.json'),($result|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($true))
 if($script:WebShell){$script:WebShell.Dispose()};$script:Window.Close();$script:Tray.Dispose();$script:ToastTimer.Stop()
 if(Get-Command ClearDeploymentCredentialUI -ErrorAction SilentlyContinue){ClearDeploymentCredentialUI}
 $full=[IO.Path]::GetFullPath($script:Root);$boundary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if($full.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($full) -cmatch '^TradeChannel-ui-fixture-[0-9a-f]{32}$'){try{Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop}catch{}}
}
$result|ConvertTo-Json -Depth 10
