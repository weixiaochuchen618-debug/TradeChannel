#requires -Version 5.1
[CmdletBinding()]
param([string]$PackageRoot='',[string]$ReportDirectory='')

$ErrorActionPreference='Stop'
$env:PSModulePath=Join-Path $PSHOME 'Modules'
if(-not $PackageRoot){$PackageRoot=Split-Path $PSScriptRoot -Parent}
$script:PackageRoot=[IO.Path]::GetFullPath($PackageRoot)
if(-not $ReportDirectory){$ReportDirectory=Join-Path (Split-Path (Split-Path $script:PackageRoot -Parent) -Parent) 'reports\ux-feedback-20261016\disconnect-tests'}
$reportRoot=[IO.Path]::GetFullPath($ReportDirectory)
$null=[IO.Directory]::CreateDirectory($reportRoot)
$script:JobRoot=Join-Path $reportRoot ('fixture-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($script:JobRoot)
$script:Checks=New-Object 'Collections.Generic.List[string]'
$script:Extracted=New-Object 'Collections.Generic.List[object]'
$script:AllLaunches=New-Object 'Collections.Generic.List[object]'
$script:AllDialogs=New-Object 'Collections.Generic.List[string]'
$script:Sources=@{}
$passed=$false;$failure=$null

function Check {param([bool]$Condition,[string]$Message)
 if(-not $Condition){throw $Message};$script:Checks.Add($Message)
}
function HasUtf8Bom {param([string]$Path)
 $bytes=[IO.File]::ReadAllBytes($Path)
 return ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)
}
function ResetFixture {
 $script:Smoke=$false;$script:ReadOnly=$false;$script:Pending=$null;$script:Job=$null;$script:QueuedJob=$null
 $script:JobQueue=New-Object 'Collections.Generic.List[object]'
 $script:UiMemoryJobs=New-Object 'Collections.Generic.List[object]'
 $script:UncertainUiJobs=New-Object 'Collections.Generic.List[object]'
 $script:Actions=New-Object 'Collections.Generic.List[object]'
 $script:AllSelfTestRequests=New-Object 'Collections.Generic.List[object]'
 $script:Launches=New-Object 'Collections.Generic.List[object]'
 $script:LaunchAttempts=0;$script:FailLaunch=$false;$script:UiReadWorkerEnabled=$false
 $script:Dialogs=New-Object 'Collections.Generic.List[string]'
 $script:Errors=New-Object 'Collections.Generic.List[string]'
 $script:Toasts=New-Object 'Collections.Generic.List[string]'
 $script:Recoveries=New-Object 'Collections.Generic.List[object]'
 $script:Previews=New-Object 'Collections.Generic.List[object]'
 $script:Receipts=New-Object 'Collections.Generic.List[object]'
 $script:UserDisconnectIntent=$false;$script:LoginAutoConnect=@{Status='Waiting';Reason=''};$script:LastDialog=$null
 $script:UiDispatchFailures=New-Object 'Collections.Generic.List[object]'
 $script:Prefs=@{NodeId='fixture-line';ProfileId='Udp';Mode='Trading';Exit='HongKong';Daily='Provider';ProviderId='fixture-provider';TradeProviderId='fixture-backup';Agents='Trade';AgentIds=@('fixture-agent');AgentCustom=@()}
 $script:Nodes=@([pscustomobject]@{id='fixture-line';LineId='fixture-line';Name='Fixture line';manifestPath='inert-fixture'})
 $script:Overview=[pscustomobject]@{StateKey='Connected';ReadState='Current';Running=$true;PrimaryAction='Disconnect';PrimaryEnabled=$true;CanConnect=$false;GuardState='Protected';NinjaRunning=$true;NodeId='fixture-line';SessionId='fixture-session'}
 $script:Footer=[pscustomobject]@{Text=''};$script:HostPanel=[pscustomobject]@{IsEnabled=$true}
 $script:Overlay=[pscustomobject]@{Visibility='Collapsed'};$script:Window=[pscustomobject]@{}
 $script:Window|Add-Member ScriptMethod FindName {param($Name) $script:Overlay}
 $script:WebPendingConnection=$null;$script:RenderCount=0;$script:RefreshCount=0;$script:ShowConsoleCount=0;$script:ReentrantClick=$false
 $script:PendingRecoveryNodeId=''
}

# Side-effect boundaries only. Application/session/queue logic is loaded from ASTs below.
function Start-Process {param($FilePath,$ArgumentList,[switch]$PassThru,$WindowStyle)
 $script:LaunchAttempts++
 if($WindowStyle -ne 'Hidden'){throw 'Unexpected visible worker launch'}
 $items=[string[]]$ArgumentList;$index=[Array]::IndexOf($items,'-RequestPath')
 if($index -lt 0){throw 'Unexpected process launch without an isolated request'}
 $requestPath=[IO.Path]::GetFullPath($items[$index+1].Trim('"'))
 if([IO.Path]::GetDirectoryName($requestPath) -ine $script:JobRoot -or [IO.Path]::GetFileName($requestPath) -notmatch '^[a-f0-9]{32}\.request\.json$'){throw 'Request escaped the test fixture'}
 $request=[IO.File]::ReadAllText($requestPath)|ConvertFrom-Json
 if($request.Action -ne 'Session' -or $request.SessionAction -ne 'Disconnect'){throw 'Unexpected worker action; no real process was started'}
 if($script:FailLaunch){throw 'Fixture: worker creation failed before dispatch'}
 $script:Launches.Add($request);$script:AllLaunches.Add($request)
 # This object has no operating-system process behind it.
 return [pscustomobject]@{Id=424242;StartTime=[datetime]::UtcNow;HasExited=$false}
}
function RestoreUiJobReceipts {}
function SaveUiJobReceipt {param($Job,$Status) $script:Receipts.Add(@{RequestId=$Job.RequestId;Status=$Status})}
# Diagnostic writers only record evidence; they must not touch the real profile
# directory while the dispatch-failure path is exercised in isolation.
function SaveUiDispatchDiagnostic {param($Failure,[string]$Action,[string]$RequestId,[string]$Stage)
 [pscustomobject]@{ErrorId=('fixture'+[guid]::NewGuid().ToString('N').Substring(0,19));Action=$Action;RequestId=$RequestId;Stage=$Stage}
}
function UiDispatchOperationLabel {param([string]$Action) return '断开连接'}
function CaptureNavigationContext {[pscustomobject]@{Revision=1}}
function TestNavigationContext {param($Context) return ($Context.Revision -eq 1)}
function ShowUiMutationBlocked {throw 'Unexpected mutation barrier during a safe disconnect'}
function StartUiReadRequest {throw 'A real read worker is forbidden in this test'}
function OpenDialog {param($Title,$Body,$Note,$Confirm,$Callback,$Cancel,$Tone,[switch]$SafeDefault)
 $script:Dialogs.Add([string]$Title);$script:AllDialogs.Add([string]$Title)
 # Hold the callback: the test asserts the dialog comes first, then approves it
 # explicitly, exactly like a user pressing the confirm button.
 $script:LastDialog=[pscustomobject]@{Title=[string]$Title;Body=[string]$Body;Note=[string]$Note;Confirm=[string]$Confirm;Cancel=[string]$Cancel;Tone=[string]$Tone;SafeDefault=[bool]$SafeDefault;Callback=$Callback}
}
function ApproveDialog {
 $pending=$script:LastDialog;if(-not $pending -or -not $pending.Callback){return}
 $script:LastDialog=$null;& $pending.Callback @{}
}
function ErrorDialog {param($Message) $script:Errors.Add([string]$Message)}
function Toast {param($Message) $script:Toasts.Add([string]$Message)}
function Render {$script:RenderCount++;if($script:ReentrantClick){$script:ReentrantClick=$false;OpenDisconnect}}
function RefreshOverview {param([switch]$Silent) $script:RefreshCount++}
function OfferConnectionRecovery {param($Message,$NodeId) $script:Recoveries.Add(@{Message=$Message;NodeId=$NodeId})}
function SyncTCWebState {param([switch]$Force)}
function ShowExistingConsole {$script:ShowConsoleCount++}
function PreviewDefaultLineConnection {param($Id) $script:Previews.Add(@{Kind='Default';Id=$Id})}
function StartLineConnectionPreview {param($Id,$Profile) $script:Previews.Add(@{Kind='Web';Id=$Id;Profile=$Profile})}
function UILineId {param($Line) return $Line.LineId}
function Invoke-WebRequest {throw 'Network access is forbidden in this test'}
function Invoke-RestMethod {throw 'Network access is forbidden in this test'}

try{
 # Import only the reviewed, declarative worker metadata; never import RuntimeBridge or dot-source the app.
 Import-Module (Join-Path $script:PackageRoot 'WorkerContracts.psm1') -Force -DisableNameChecking
 $groups=@(
  @{Path='TradeChannel.ps1';Names=@('OpenDisconnect','StartSession','SessionRequest','StateKey','IsBusy','StopLoginAutoConnectUI','PrimaryAction','ConnectDefaultSelection')},
  @{Path='ui\BackgroundJobs.ps1';Names=@('SaveUiDispatchDiagnostic','UiJobField','GetUiJobPolicy','GetUiLineIdentityList','GetUiActiveLineIdentityList','GetUiLocalLineScope','GetUiConnectionScope','TestUiLineIdsIntersect','GetUiJobResourceScope','TestUiJobScopesConflict','TestUiMutationBlocked','TestUiRecoveryRequest','TestUiJobCallbackContext','CompleteUiRequestLifecycle','GetUiRequestDisposition','StartJob','StartNextUiJob')},
  @{Path='ui\WebShell.ps1';Names=@('WebField','InvokeTCWebMessage','RequestTCLineConnection')}
 )
 foreach($group in $groups){
  $path=Join-Path $script:PackageRoot $group.Path;$tokens=$null;$parseErrors=$null
  $ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$parseErrors)
  Check ($parseErrors.Count -eq 0) ($group.Path+': source parses without executing startup')
  $script:Sources[$group.Path]=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
  foreach($name in $group.Names){
   $definitions=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$false))
   if($definitions.Count -ne 1){throw ('Expected one real function: '+$name)}
   $definition=$definitions[0]
   $script:Extracted.Add([pscustomobject]@{Path=$group.Path;Name=$name;Line=$definition.Extent.StartLineNumber})
   . ([scriptblock]::Create($definition.Extent.Text))
  }
  if($group.Path -eq 'TradeChannel.ps1'){$appAst=$ast}
 }
 Check (HasUtf8Bom (Join-Path $script:PackageRoot 'TradeChannel.ps1')) 'Application retains UTF-8 BOM'
 Check (HasUtf8Bom $PSCommandPath) 'Isolation test uses UTF-8 BOM'
 $trayHandlers=@($appAst.FindAll({param($node)
  $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Member.Value -eq 'Add_Click' -and $node.Expression -is [Management.Automation.Language.VariableExpressionAst] -and $node.Expression.VariablePath.UserPath -in @('connItem','script:TrayConnectItem')
 },$true))
 Check ($trayHandlers.Count -eq 1) 'Exactly one real tray connection callback is extracted'
 $trayText=$trayHandlers[0].Arguments[0].ScriptBlock.Extent.Text
 $trayClick=[scriptblock]::Create($trayText.Substring(1,$trayText.Length-2))

 foreach($entry in @('Direct','NativeHome','Tray','WebHome','Fault')){
  ResetFixture
  $preferencesBefore=$script:Prefs|ConvertTo-Json -Depth 5 -Compress
  switch($entry){
   'Direct'{OpenDisconnect}
   'NativeHome'{PrimaryAction}
   'Tray'{& $trayClick}
   'WebHome'{InvokeTCWebMessage '{"Type":"disconnect"}' 'https://tradechannel.local/index.html'}
   'Fault'{$script:Overview.StateKey='Fault';PrimaryAction}
  }
  Check ($script:Dialogs.Count -eq 1 -and $script:Launches.Count -eq 0 -and $script:Errors.Count -eq 0) ($entry+': asks once before disconnecting and dispatches nothing yet')
  $prompt=$script:LastDialog
  Check ($prompt -and $prompt.Confirm -eq '断开连接' -and $prompt.Cancel -eq '继续交易' -and $prompt.Tone -eq 'Danger' -and $prompt.SafeDefault) ($entry+': confirmation keeps trading as the default choice')
  Check ($prompt -and $prompt.Body -match '中断' -and $prompt.Body -match '保护' -and $prompt.Body -match '持仓') ($entry+': confirmation states interruption, retained protection and open positions')
  ApproveDialog
  Check ($script:Launches.Count -eq 1 -and $script:Job.RequestData.Action -eq 'Session' -and $script:Job.RequestData.SessionAction -eq 'Disconnect') ($entry+': one original Session Disconnect dispatch after confirmation')
  Check ($script:Pending -eq 'Disconnecting' -and (IsBusy)) ($entry+': original transition immediately blocks a second dispatch')
  Check ($script:UserDisconnectIntent -and $script:LoginAutoConnect.Status -eq 'Skipped') ($entry+': manual disconnect cancels pending login auto-connect')
  Check ($script:Overview.GuardState -eq 'Protected' -and ($script:Prefs|ConvertTo-Json -Depth 5 -Compress) -ceq $preferencesBefore) ($entry+': protection presentation and connection preferences are retained')
  Check (@($script:Job.RequestData.Keys|Where-Object {$_ -notin @('Action','SessionAction','RequestId','UiRequestId','PageGeneration')}).Count -eq 0) ($entry+': stop request carries no route, profile or protection-removal fields')
  Check ($script:PendingRecoveryNodeId -eq 'fixture-line' -and $script:Receipts.Count -eq 1) ($entry+': existing recovery target and dispatch receipt are retained')
  OpenDisconnect;PrimaryAction;& $trayClick;InvokeTCWebMessage '{"Type":"disconnect"}' 'https://tradechannel.local/index.html'
  Check ($script:Launches.Count -eq 1 -and $script:JobQueue.Count -eq 0) ($entry+': repeated clicks across entry points never duplicate the stop')
 }

 foreach($smokeMode in @($false,$true)){
  ResetFixture;$script:ReadOnly=$true;$script:Smoke=$smokeMode;OpenDisconnect
  Check ($script:LaunchAttempts -eq 0 -and $script:Actions.Count -eq 0 -and $script:JobQueue.Count -eq 0 -and $script:Errors.Count -eq 1 -and $script:Dialogs.Count -eq 0) ('Read-only rejected before dispatch; Smoke='+$smokeMode)
  Check (-not $script:UserDisconnectIntent -and $script:LoginAutoConnect.Status -eq 'Waiting') ('Read-only rejection leaves manual intent untouched; Smoke='+$smokeMode)
 }
 foreach($busy in @('Loading','Connecting','Disconnecting','Applying','ApplyingDaily','ApplyingAgents','CheckingProvider','ForegroundJob','MemoryJob')){
  ResetFixture
  switch($busy){
   'Loading'{$script:Overview=$null}
   'ForegroundJob'{$script:Job=@{Silent=$false}}
   'MemoryJob'{$script:UiMemoryJobs.Add(@{Id='memory-fixture'})}
   default{$script:Pending=$busy}
  }
  Check (IsBusy) ($busy+': real busy detector recognizes the fixture')
  OpenDisconnect;OpenDisconnect
  Check ($script:LaunchAttempts -eq 0 -and $script:JobQueue.Count -eq 0 -and -not $script:UserDisconnectIntent -and $script:Dialogs.Count -eq 0) ($busy+': busy state rejects disconnect without queuing or changing intent')
 }

 foreach($readAction in @('Overview','LineQuality')){
  ResetFixture;$script:LoginAutoConnect.Status='Previewing'
  $script:Job=@{Silent=$true;Policy=(GetUiJobPolicy $readAction);Key=($readAction+'||||');OutcomeUnknown=$false}
  StartJob @{Action='Nodes'} {} 'Fixture queued read' '' -Silent
  Check (-not (IsBusy)) ($readAction+': a silent read allows the first user disconnect')
  OpenDisconnect
  ApproveDialog
  Check ($script:LaunchAttempts -eq 0 -and $script:JobQueue.Count -eq 2 -and $script:JobQueue[0].Request.SessionAction -eq 'Disconnect' -and -not $script:JobQueue[0].Silent -and $script:JobQueue[1].Request.Action -eq 'Nodes') ($readAction+': first disconnect queues once ahead of pending silent reads')
  Check ($script:UserDisconnectIntent -and $script:LoginAutoConnect.Status -eq 'Skipped' -and -not $script:Pending -and -not (IsBusy)) ($readAction+': manual intent is recorded before queued dispatch, without a fake busy state')
  foreach($click in 1..5){OpenDisconnect;PrimaryAction;& $trayClick;InvokeTCWebMessage '{"Type":"disconnect"}' 'https://tradechannel.local/index.html'}
  Check ($script:JobQueue.Count -eq 2 -and $script:LaunchAttempts -eq 0) ($readAction+': repeated clicks cannot enqueue a second disconnect while IsBusy is false')
  $script:Job=$null;StartNextUiJob
  Check ($script:Launches.Count -eq 1 -and $script:Pending -eq 'Disconnecting' -and $script:JobQueue.Count -eq 1 -and $script:JobQueue[0].Request.Action -eq 'Nodes') ($readAction+': releasing the read slot dispatches the accepted stop exactly once')
  OpenDisconnect;StartNextUiJob
  Check ($script:Launches.Count -eq 1 -and $script:JobQueue.Count -eq 1) ($readAction+': active disconnect stays unique and preserves unrelated queued work')
 }

 ResetFixture;$script:Job=@{Silent=$true;Key='Overview||||';OutcomeUnknown=$false}
 StartJob @{Action='Session';SessionAction='Apply'} {} 'Fixture queued apply' 'Applying'
 OpenDisconnect;ApproveDialog;OpenDisconnect
 Check ($script:JobQueue.Count -eq 2 -and $script:JobQueue[0].Request.SessionAction -eq 'Apply' -and $script:JobQueue[1].Request.SessionAction -eq 'Disconnect') 'An unrelated queued Session action does not swallow the first disconnect'

 ResetFixture;$script:ReentrantClick=$true;OpenDisconnect;ApproveDialog
 Check ($script:Launches.Count -eq 1 -and $script:Pending -eq 'Disconnecting') 'A click re-entering through Render cannot duplicate dispatch'

 ResetFixture;$script:FailLaunch=$true;OpenDisconnect;ApproveDialog
 Check ($script:LaunchAttempts -eq 1 -and $script:Launches.Count -eq 0 -and -not $script:Job -and -not $script:Pending -and $script:Recoveries.Count -eq 1 -and $script:Recoveries[0].NodeId -eq 'fixture-line') 'Worker creation failure uses original recovery callback without leaving a busy latch'
 Check ($script:UserDisconnectIntent -and $script:LoginAutoConnect.Status -eq 'Skipped') 'Failed dispatch still preserves the explicit intent not to auto-connect'
 $script:FailLaunch=$false;OpenDisconnect;ApproveDialog
 Check ($script:LaunchAttempts -eq 2 -and $script:Launches.Count -eq 1 -and $script:Pending -eq 'Disconnecting') 'A deliberate retry after startup failure is accepted once despite sticky user intent'

 ResetFixture;OpenDisconnect;ApproveDialog;$complete=$script:Job.Complete
 $script:Job=$null
 $stopped=[pscustomobject]@{StateKey='Disconnected';ReadState='Current';Running=$false;GuardState='Protected';PrimaryAction='Connect';PrimaryEnabled=$true;CanConnect=$true}
 & $complete $stopped
 Check ([object]::ReferenceEquals($script:Overview,$stopped) -and -not $script:Pending -and $script:RefreshCount -eq 1 -and $script:Launches.Count -eq 1) 'Original success callback consumes the stopped overview and refreshes without reconnecting'
 Check ($script:Overview.GuardState -eq 'Protected' -and $script:UserDisconnectIntent) 'Protected stopped state and manual intent survive completion'

 ResetFixture;$script:Overview.StateKey='Disconnected';$script:Overview.Running=$false;PrimaryAction
 Check ($script:Previews.Count -eq 1 -and $script:Previews[0].Kind -eq 'Default' -and $script:LaunchAttempts -eq 0) 'Native connect still enters its existing default preview flow'
 ResetFixture;$script:Overview.NinjaRunning=$false
 InvokeTCWebMessage '{"Type":"connect","Id":"fixture-line"}' 'https://tradechannel.local/index.html'
 Check ($script:Previews.Count -eq 1 -and $script:Previews[0].Kind -eq 'Web' -and $script:LaunchAttempts -eq 0) 'Web connect/switch still enters its existing preview flow'
 ResetFixture;$script:ReadOnly=$true
 InvokeTCWebMessage '{"Type":"disconnect"}' 'https://tradechannel.local/index.html'
 Check ($script:LaunchAttempts -eq 0 -and -not $script:UserDisconnectIntent) 'Web read-only guard also refuses disconnect'
 ResetFixture
 InvokeTCWebMessage '{"Type":"disconnect"}' 'https://other.invalid/index.html'
 Check ($script:LaunchAttempts -eq 0 -and -not $script:UserDisconnectIntent) 'Foreign-origin web messages cannot request disconnect'

 Check (@($script:AllDialogs|Where-Object {$_ -ceq '断开连接？'}).Count -ge 5) 'Every disconnect path asks before dispatching'
 Check (@($script:AllLaunches|Where-Object {$_.Action -ne 'Session' -or $_.SessionAction -ne 'Disconnect'}).Count -eq 0) 'Every simulated worker dispatch uses only the original safe stop contract'
 $passed=$true
}catch{
 $failure=[pscustomobject]@{Message=$_.Exception.Message;Position=$_.InvocationInfo.PositionMessage;Stack=$_.ScriptStackTrace}
}finally{
 # Delete only this run's positively identified fixture under the report directory.
 $fixtureFull=[IO.Path]::GetFullPath($script:JobRoot)
 if([IO.Path]::GetDirectoryName($fixtureFull) -ine $reportRoot -or [IO.Path]::GetFileName($fixtureFull) -notmatch '^fixture-[a-f0-9]{32}$'){throw 'Refusing fixture cleanup outside the report directory'}
 if(Test-Path -LiteralPath $fixtureFull){Remove-Item -LiteralPath $fixtureFull -Recurse -Force}
 $result=[pscustomobject][ordered]@{
  Passed=$passed;Checks=$script:Checks.Count;PowerShellVersion=$PSVersionTable.PSVersion.ToString();PowerShellEdition=$PSVersionTable.PSEdition
  PackageRoot=$script:PackageRoot;CompletedAtUtc=[DateTimeOffset]::UtcNow.ToString('o');ExtractedFunctions=@($script:Extracted.ToArray());SourceSHA256=$script:Sources
  SimulatedWorkerDispatches=$script:AllLaunches.Count;RealWorkers=0;NetworkRequests=0;FixtureRemoved=(-not (Test-Path -LiteralPath $fixtureFull))
  Assertions=@($script:Checks.ToArray());Failure=$failure
 }
 $json=$result|ConvertTo-Json -Depth 8
 [IO.File]::WriteAllText((Join-Path $reportRoot 'Test-ImmediateDisconnect.json'),$json,(New-Object Text.UTF8Encoding($true)))
 $log=@('Passed: '+$passed,'PowerShell: '+$PSVersionTable.PSVersion.ToString())+@($script:Checks|ForEach-Object {'PASS '+$_})
 if($failure){$log+=('FAIL '+$failure.Message);$log+=$failure.Position;$log+=$failure.Stack}
 [IO.File]::WriteAllLines((Join-Path $reportRoot 'Test-ImmediateDisconnect.log'),[string[]]$log,(New-Object Text.UTF8Encoding($true)))
 $result|Select-Object Passed,Checks,PowerShellVersion,SimulatedWorkerDispatches,RealWorkers,NetworkRequests,FixtureRemoved,Failure|ConvertTo-Json -Depth 4 -Compress
}
if(-not $passed){exit 1}
