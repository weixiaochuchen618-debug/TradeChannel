#requires -Version 5.1
#requires -PSEdition Desktop
[CmdletBinding()]param([string]$PackageRoot,[string]$ReportDirectory)
$ErrorActionPreference='Stop';$env:PSModulePath=Join-Path $PSHOME 'Modules'
if(-not $PackageRoot){$PackageRoot=Split-Path $PSScriptRoot -Parent}
if(-not $ReportDirectory){$ReportDirectory=Join-Path ([IO.Path]::GetTempPath()) ('tc-line-request-wpf-'+[guid]::NewGuid().ToString('N'))}
$harness=[IO.File]::ReadAllText((Join-Path (Split-Path $PSScriptRoot -Parent) 'ui\Test-015UI.ps1'),[Text.Encoding]::UTF8)
$preambleEnd=$harness.IndexOf('$passed=$false;$failure=''''',$harness.IndexOf('function SelectHistoryFilter'))
$setupStart=$harness.IndexOf(" ImportNamedPresentation 'TradeChannel.ps1'")
$setupEnd=$harness.IndexOf(" ResetUI;ShowSetup;Shot '015-01-single-add-line'")
if($preambleEnd -lt 0 -or $setupStart -lt 0 -or $setupEnd -le $setupStart){throw 'WPF harness initialization changed'}
. ([scriptblock]::Create($harness.Substring(0,$preambleEnd))) -SourceDirectory $PackageRoot -TestOutputDirectory $ReportDirectory
$passed=$false;$failure='';$failureStack='';$lineModule=$null
try{
 . ([scriptblock]::Create($harness.Substring($setupStart,$setupEnd-$setupStart)))
 . (Join-Path $script:PackageRoot 'ui\NavigationContext.ps1')
 . (Join-Path $script:PackageRoot 'ui\BackgroundJobs.ps1')
 . (Join-Path $script:PackageRoot 'ui\LineCardState.ps1')
 . (Join-Path $script:PackageRoot 'ui\LineCardControls.ps1')
 ImportNamedPresentation 'TradeChannel.ps1' @('StateKey','IsRunning','IsBusy','NodeEntry','ActiveNodeId','TradeLaneValue')
 $script:Smoke=$false;$script:UiReadWorkerEnabled=$false;$script:UiJobRecoveryLoaded=$true
 $null=[IO.Directory]::CreateDirectory($script:JobRoot);$script:Actors=New-Object 'Collections.Generic.List[object]'
 $script:LineCardControls=@{};$script:UiMemoryJobs=$null
 # External Worker process is the only dispatcher seam. Every page handler,
 # context validator, admission, queue, poll and finalizer stays production code.
 function Start-Process {param($FilePath,$ArgumentList,[switch]$PassThru,$WindowStyle)
  if($WindowStyle -cne 'Hidden' -or [IO.Path]::GetFileName($FilePath) -ine 'powershell.exe'){throw 'Unexpected launch'}
  $at=[array]::IndexOf($ArgumentList,'-RequestPath');if($at -lt 0){throw 'Expected bounded Worker invocation'}
  $path=FixturePath ([string]$ArgumentList[$at+1]).Trim('"')
  $request=[IO.File]::ReadAllText($path)|ConvertFrom-Json;$script:Actors.Add($request)
  $p=[pscustomobject]@{Id=1800000000+$script:Actors.Count;StartTime=[DateTime]::UtcNow;HasExited=$false}
  $p|Add-Member ScriptMethod Dispose {};return $p
 }
 function UpdateChrome {$script:Window.FindName('ChipText').Text='隔离测试界面'}
 function Render {}
 function CompleteFixtureJob {param($Data=$null,[bool]$Ok=$true,[string]$Message='隔离回归：保存未完成，请重试。')
  $j=$script:Job;if(-not $j){throw 'Expected real dispatcher job'}
  $r=@{Ok=$Ok;Action=$j.Action;RequestId=$j.RequestId;PageGeneration=$j.OriginContext.Revision;Code='FixtureResult';Data=$Data;Message=$Message}
  [IO.File]::WriteAllText((FixturePath $j.Result),($r|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($true))
  PollBackgroundJob;return $j
 }
 function DrainFixtureReads {
  for($i=0;$script:Job -and $i -lt 8;$i++){
   if($script:Job.Action -notin @('Nodes','Overview')){throw ('Unexpected dependent actor '+$script:Job.Action)}
   $null=CompleteFixtureJob
  }
  CheckUI (-not $script:Job -and $script:JobQueue.Count -eq 0) 'Ancillary reads drain through real queue'
  RefreshLineCardControlsUI
 }
 function RenderCards {
  PageHead '线路' '本页使用真实请求派发、队列、上下文和卡片控件；外部 Worker 在隔离夹具中返回。' 'nodes'
  $script:LineCardControls=@{}
  foreach($line in $script:Nodes){AddLineCard $script:HostPanel (GetLineCardStateUI $line)}
 }
 function ClickShell {param([string]$Name)$control=$script:Window.FindName($Name);$control.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))}
 function ClickRadio {param($Radio)
  CheckUI $Radio.IsEnabled 'Real protocol radio is enabled before click'
  $Radio.GetType().GetMethod('OnClick',[Reflection.BindingFlags]'Instance,NonPublic').Invoke($Radio,$null)
 }
 $shot=(Get-Command Shot).Definition.Replace('隔离 WPF · 夹具状态 · 不证明服务器部署或网络结果','隔离 WPF · Smoke=false · 真实队列与回调 · 外部 Worker 夹具').Replace(' / SMOKE / FIXTURE',' / REAL DISPATCH / FIXTURE')
 Set-Item Function:script:Shot ([scriptblock]::Create($shot))
 $script:Window.FindName('NavHome').Add_Click({ShowHome})
 $script:Window.FindName('NavNodes').Add_Click({RenderCards})
 $id='11111111-1111-1111-1111-111111111111';$key=$id.Replace('-','')
 $script:Nodes=@([pscustomobject]@{id=$id;LineId=$id;Name='香港历史主线（隔离夹具）';Endpoint='192.0.2.10:443';Revision=1;DefaultVerified=$true;SavedConnectionPreference=[pscustomobject]@{ProfileId='Udp';Digest='fixture'};Profiles=@([pscustomobject]@{Id='Udp';PreparationState='Ready';SyntaxValidated=$true},[pscustomobject]@{Id='Tcp';PreparationState='Ready';SyntaxValidated=$true})})
 $script:Overview=[pscustomobject]@{StateKey='Disconnected';Running=$false;NinjaRunning=$false;ActiveLineId=$id;ActiveProfileId='Tcp';SessionId='fixture-session';ConfigHash=('A'*64);EnginePid=123;ManifestPath=(Join-Path $script:Root 'current.manifest');Mode='rule';Exit='hk';Daily='direct';Agents='Daily';ProviderId='fixture-provider';TradeProviderId='';DesiredDaily='Direct';AgentsSupported=$false;DailySupported=$false;AgentIds=@();AgentCustom=@()}
 $script:Prefs=@{Exit='HongKong';NodeId=$id}
 RenderCards
 ClickRadio $script:LineCardControls[$id].Radios.Tcp
 CheckUI ($script:Job.Action -ceq 'LinePreference' -and $script:Job.CallbackContext.Type -ceq 'Line' -and $script:Smoke -eq $false) 'Actual TCP radio click dispatches default save through real typed context'
 $saved=$script:Nodes[0]|ConvertTo-Json -Depth 20|ConvertFrom-Json;$saved.Revision=2;$saved.SavedConnectionPreference.ProfileId='Tcp'
 $j=CompleteFixtureJob $saved
 CheckUI ($script:LineCardControls[$id].Radios.Tcp.IsChecked -and -not $script:LineCardControls[$id].Radios.Udp.IsChecked -and $script:LinePreferenceRequests.Count -eq 0) 'Successful save selects persisted TCP and ends pending'
 Shot '01-default-save-success'
 ClickRadio $script:LineCardControls[$id].Radios.Udp
 $null=CompleteFixtureJob $null $false
 CheckUI ($script:LineCardControls[$id].Radios.Tcp.IsChecked -and -not $script:LineCardControls[$id].Radios.Udp.IsChecked -and $script:LinePreferenceRequests.Count -eq 0) 'Failed save restores persisted radio choice and clears pending'
 Shot '02-default-save-failure'
 CloseDialog;$script:HostPanel.IsEnabled=$true
 CheckUI (@($script:Actors|Where-Object {$_.Action -match 'Connect|Session|Deploy|Probe|Check'}).Count -eq 0) 'Saving a default performs zero connection/check/deployment requests'
 # Navigate through actual shell controls while the first preview is running.
 ClickUI ('Node'+$key);$old=$script:Job
 CheckUI ($old.Action -ceq 'ConnectionDefaultPreview') 'Actual connect button starts only default preflight'
 ClickShell 'NavHome';$dialogs=$script:DialogCount
 $null=CompleteFixtureJob @{CanSwitch=$true;LineId=$id;ProfileId='Tcp';PreviewToken='stale-preview';SelectionMode='SavedDefault'}
 CheckUI (-not $script:ConnectionPreviewUI -and $script:DialogCount -eq $dialogs) 'Off-page completion clears preview owner without presenting stale dialog'
 ClickShell 'NavNodes';ClickUI ('Node'+$key);$fresh=$script:Job
 CheckUI ($fresh.UiRequestId -cne $old.UiRequestId) 'Returning and clicking creates a fresh independent preview'
 $null=CompleteFixtureJob @{CanSwitch=$true;LineId=$id;ProfileId='Tcp';PreviewToken='current-preview';SelectionMode='SavedDefault'}
 CheckUI (-not $script:ConnectionPreviewUI -and $script:Window.FindName('Overlay').Visibility -eq 'Visible' -and $script:DialogContext.PreviewToken -ceq 'current-preview') 'Only current preview owns the actual confirmation'
 Shot '03-preview-after-navigation'
 ClickShell 'DialogConfirm'
 CheckUI ($script:Job.Action -ceq 'ConnectionSwitchCommit' -and $script:Job.RequestData.PreviewToken -ceq 'current-preview') 'Current confirmation submits only its bound connection token'
 $null=CompleteFixtureJob @{Activated=$true;Status='Completed';Message='isolated';Check=@{ForwardingPassed=$true}}
 DrainFixtureReads
 CheckUI (@($script:Actors|Where-Object Action -eq 'ConnectionSwitchCommit').Count -eq 1 -and @($script:Actors|Where-Object {$_.Action -match '^Deployment|CandidateProbe|Compare'}).Count -eq 0) 'Prepared line connects with one commit and zero deployment/comparison requests'
 # Runtime/check functions are real; only external state readers are fixture
 # adapters. The same identity is deliberately running on a provider exit.
 $script:Overview.Running=$true;$script:Overview.StateKey='Connected'
 $context=Get-TCExitCheckContext $script:Overview
 $script:LineCheckResults[$id]=[pscustomobject]@{LineId=$id;ProfileId='Tcp';SessionId=$context.Fields.SessionId;ConfigHash=$context.Fields.ConfigHash;Status='Passed';ForwardingPassed=$true;MeasuredContext=$context;CheckContext=$context;ContextChanged=$false;ProofVersion=2;Time=[DateTimeOffset]::UtcNow.ToString('o');ServerAttributionVerified=$false}
 $script:Overview.Exit='provider-trade';$script:Overview.TradeProviderId='fixture-provider'
 $lineModule=Import-Module (Join-Path $script:PackageRoot 'LineConnectionCheck.psm1') -PassThru -DisableNameChecking
 & $lineModule {
  param($Root,$Package,$Line,$Overview)
  $script:FixtureRoot=$Root;$script:FixturePackage=$Package;$script:FixtureLine=$Line;$script:FixtureOverview=$Overview
  function script:Import-Module {param($Name,[switch]$DisableNameChecking)if([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Name)) -cne $script:FixturePackage -or [IO.Path]::GetFileName($Name) -notin @('LineStore.psm1','RuntimeBridge.psm1')){throw 'Unexpected import'}}
  function script:Get-TCLine {param($Root,$Id)if($Root -cne $script:FixtureRoot -or $Id -cne $script:FixtureLine.LineId){throw 'Fixture target changed'};$script:FixtureLine}
  function script:Get-TCOverview {$script:FixtureOverview}
  function script:Test-TCActiveConnection {throw 'Provider must not be probed as a self-hosted line'}
  function script:Test-TCCandidateProbe {throw 'Same identity candidate must not be started'}
 } $script:Root $script:PackageRoot $script:Nodes[0] $script:Overview
 ClickShell 'NavNodes'
 CheckUI ($script:LineCardControls[$id].Healths.Tcp.Text -ne '检查通过') 'Provider change invalidates old green measurement immediately'
 ClickUI ('Node'+$key)
 CheckUI ($script:Job.Action -ceq 'LineProfileCheck') 'Current running protocol click reaches actual line check action'
 $result=& $lineModule {param($Root,$Id,$Revision)Invoke-TCLineProfileCheck -Root $Root -Id $Id -ProfileId Tcp -ExpectedRevision $Revision} $script:Root $id $script:Nodes[0].Revision
 $null=CompleteFixtureJob $result;DrainFixtureReads
 CheckUI ($result.Code -ceq 'TargetNotSelectedExit' -and $script:LineCheckRequests.Count -eq 0 -and $script:LineCardControls[$id].Healths.Tcp.Text -ne '检查通过' -and $script:LineCardControls[$id].Radios.Tcp.IsChecked) 'Actual provider refusal preserves default and never paints line green'
 Shot '04-provider-is-not-line-proof'
 # The legacy repair entry is an actual card button and real mutation job.
 $script:Nodes[0].DefaultVerified=$false;RenderCards
 ClickUI ('Node'+$key)
 CheckUI ($script:Job.Action -ceq 'LinePreferenceRepair' -and $script:Job.CallbackContext.Type -ceq 'Line') 'Legacy default repair button dispatches with the real typed context'
 $script:Nodes[0].DefaultVerified=$true
 $null=CompleteFixtureJob @{Code='PreferenceRepaired'};DrainFixtureReads
 CheckUI ($script:LinePreferenceRequests.Count -eq 0 -and $script:LastToast -like '*已核对原默认来源*' -and $script:LineCardControls[$id].Radios.Tcp.IsChecked) 'Repair returns an explicit result and restores the same original default'
 AddC $script:HostPanel (T $script:LastToast 14 $script:Text2)
 Shot '05-legacy-default-repaired'
 # Feed real DeploymentPoll results through production callback validation.
 $run=BaseRun 'Inspect' 'Running';$script:DeployUI.SessionAttached=$true
 RenderRun $run;PollDeploymentRunUI
 CheckUI ($script:Job.Action -ceq 'DeploymentPoll' -and $script:Job.CallbackContext.Type -ceq 'Deployment') 'Deployment poll uses real typed dispatch before terminal presentation'
 $failed=$run|ConvertTo-Json -Depth 20|ConvertFrom-Json;$failed.Status='Failed';$failed.LastError=[pscustomobject]@{Code='FixtureServerInspectFailed';Message='服务器检查失败：系统组件缺失，请核对后重试。'}
 $null=CompleteFixtureJob $failed
 $text=VisibleText
 CheckUI ($text -like '*服务器检查失败：系统组件缺失*' -and $script:Controls.ContainsKey('DeployReconcile') -and -not $script:Job -and -not $script:Pending) 'Known failed deployment displays its actual cause and retry entry with no pending job'
 CheckUI (-not $script:Controls.ContainsKey('DeployReconnectStatus') -and @((Descendants $script:HostPanel)|Where-Object {$_ -is [Windows.Controls.ProgressBar] -and $_.IsIndeterminate}).Count -eq 0 -and $text -notmatch '正在连接服务器|正在核对服务器登录|正在检查服务器环境') 'Known failure stops stale connecting/checking presentation and indeterminate animation'
 Shot '06-known-deployment-failure-stopped'
 ClickUI 'DeployReconcile'
 CheckUI ($script:Job.Action -ceq 'DeploymentProceed' -and $script:Job.RequestData.RunId -ceq $run.RunId) 'Known failure retry continues the original run instead of creating another'
 $unknown=$failed|ConvertTo-Json -Depth 20|ConvertFrom-Json;$unknown.Status='OutcomeUnknown';$unknown.RecoveryRequired=$true;$unknown.LastError=[pscustomobject]@{Code='OutcomeUnknown';Message='服务器原变更结果待核对，尚未确认是否完成。'}
 $unknown|Add-Member NoteProperty LastRemoteMutation ([pscustomobject]@{IntentId=[guid]::NewGuid().ToString();State='Dispatched';Operation='management_apply';Mutating=$true})
 $pendingJob=CompleteFixtureJob $unknown
 CheckUI ($script:UncertainUiJobs.Contains($pendingJob) -and -not $script:Job -and -not $script:Pending -and $pendingJob.Lifecycle.Terminal.Status -ceq 'OutcomeUnknown') 'Unknown mutation ends UI waiting but retains its original durable barrier'
 $text=VisibleText
 CheckUI ($text -match '待核对|核对原部署|需要恢复' -and -not $script:Controls.ContainsKey('DeployApprove') -and -not $script:Controls.ContainsKey('ProductDeployInspect')) 'Unknown result shows recovery wording and offers no new deployment approval'
 $beforeActors=$script:Actors.Count
 $denied=StartJob @{Action='DeploymentProceed';RunId=$run.RunId;Command='Approve';ApprovedChangeDigest=('A'*64)} {} -CallbackContext (NewDeploymentCallbackContext) -PassThru
 CheckUI ($denied.Code -ceq 'MutationBlocked' -and $script:Actors.Count -eq $beforeActors -and $script:UncertainUiJobs.Contains($pendingJob)) 'Actual dispatcher blocks repeated remote mutation while the original is unknown'
 Shot '07-unknown-deployment-barrier'
 ClickUI 'DeployReconcile'
 CheckUI ($script:Job.Action -ceq 'DeploymentProceed' -and $script:Job.RequestData.Command -ceq 'Reconcile' -and $script:Job.RequestData.RunId -ceq $run.RunId) 'Unknown result permits only the explicit original-operation reconciliation request'
 $null=CompleteFixtureJob $unknown
 CheckUI ($script:DeniedActors.Count -eq 0 -and $script:Smoke -eq $false) 'WPF regression uses real dispatcher with no forbidden production actor'
 $passed=$true
}catch{$failure=$_.Exception.Message;$failureStack=$_.ScriptStackTrace}
finally{
 StopIntakeTimer
 if($script:Window){$script:Window.Close()}
 $report=[pscustomobject]@{Passed=$passed;Assertions=$script:Checks.Count;Checks=@($script:Checks.ToArray());Failure=$failure;Stack=$failureStack;Smoke=$script:Smoke;ActualDispatcher=$true;ActualQueue=$true;ActualControls=$true;ProductionWrites=0;NetworkOperations=0;Requests=@($script:Actors.ToArray());Screenshots=@($script:Shots.ToArray());Sources=@($script:LoadedSources.ToArray());PowerShellVersion=$PSVersionTable.PSVersion.ToString()}
 $report|ConvertTo-Json -Depth 20|Set-Content -LiteralPath (Join-Path $qa 'line-request-wpf.json') -Encoding UTF8
 $report|Select-Object Passed,Assertions,Failure,Stack,Smoke,ActualDispatcher,ActualQueue,ActualControls|ConvertTo-Json
 if($lineModule){Remove-Module LineConnectionCheck -ErrorAction SilentlyContinue}
 $full=SafeLocalPath $script:Root;$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if(-not $full.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -cnotmatch '^tc-ui-015-data-[a-f0-9]{32}$' -or -not [IO.File]::Exists((Join-Path $full '.owned-ui-015'))){throw 'Fixture cleanup rejected'}
 Remove-Item -LiteralPath $full -Recurse -Force
}
if(-not $passed){throw $failure}

