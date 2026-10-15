#requires -Version 5.1
param([string]$SourceDirectory=(Join-Path $PSScriptRoot '..'),[string]$TestOutputDirectory='')
$ErrorActionPreference='Stop'
if([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw 'Run this isolated WPF test with PowerShell -Sta.'}
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$script:PackageRoot=[IO.Path]::GetFullPath($SourceDirectory)
$script:Root=Join-Path ([IO.Path]::GetTempPath()) ('tc-ui-0142-'+[guid]::NewGuid().ToString('N'))
$script:JobRoot=Join-Path $script:Root 'Product\jobs'
$qa=if($TestOutputDirectory){[IO.Path]::GetFullPath($TestOutputDirectory)}else{Join-Path $script:Root 'screenshots'}
$common=[IO.Path]::GetFullPath([Environment]::GetFolderPath('CommonApplicationData')).TrimEnd('\')+'\'
if(($qa.TrimEnd('\')+'\').StartsWith($common,[StringComparison]::OrdinalIgnoreCase)){throw 'UI verification output cannot use ProgramData'}
$null=[IO.Directory]::CreateDirectory($qa)
$script:Smoke=$true;$script:ReadOnly=$false;$script:Pending=$null;$script:Job=$null;$script:DialogCallback=$null
$script:Controls=@{};$script:Requests=New-Object 'Collections.Generic.List[object]';$script:AllRequests=New-Object 'Collections.Generic.List[object]';$script:Assertions=New-Object 'Collections.Generic.List[string]'
$script:Ink='#15181D';$script:Text2='#4B5360';$script:Text3='#858C97';$script:Hair='#E6E8EB'
$script:Tone=@{ok=@{Fg='#15803D';Bg='#ECF8F0'};warn=@{Fg='#A15C07';Bg='#FDF5E8'};bad=@{Fg='#B42318';Bg='#FEF1F0'};info=@{Fg='#1D4ED8';Bg='#EEF3FE'};idle=@{Fg='#4B5360';Bg='#F2F3F5'}}
function Start-Process {throw 'UI tests forbid all external process launches.'}
function Stop-Process {throw 'UI tests forbid stopping real processes.'}
function Invoke-WebRequest {throw 'UI tests forbid real network requests.'}
function Invoke-RestMethod {throw 'UI tests forbid real network requests.'}
function AssertUI {param([bool]$Condition,[string]$Name) if(-not $Condition){throw ('0142 UI regression failed: '+$Name)};$script:Assertions.Add($Name)}
# Import only named presentation functions by AST. Never execute TradeChannel.ps1.
function ImportPresentationFunctions {param([string]$Path,[string[]]$Names)
 $tokens=$null;$parseErrors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$parseErrors)
 if($parseErrors.Count){throw 'Source presentation script failed parsing.'}
 foreach($name in $Names){$nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)|Where-Object Name -eq $name);if($nodes.Count -ne 1){throw ('Presentation function missing: '+$name)};Set-Item -Path ('Function:script:'+$name) -Value ([scriptblock]::Create($nodes[0].Body.Extent.Text.TrimStart('{').TrimEnd('}')))}
}
ImportPresentationFunctions (Join-Path $script:PackageRoot 'TradeChannel.ps1') @('B','AddC','T','Stack','Card','Margin','Grid','Cell','ControlName','Btn','Icon','IconTile','Rule','KeyValue','Notice')
ImportPresentationFunctions (Join-Path $script:PackageRoot 'ui/Pages.ps1') @('TwoColumns','Tx','Head','Note')
[xml]$xaml=Get-Content -LiteralPath (Join-Path $script:PackageRoot 'ui/Shell.xaml') -Raw -Encoding UTF8
$reader=New-Object Xml.XmlNodeReader($xaml);$script:Window=[Windows.Markup.XamlReader]::Load($reader)
$script:HostPanel=$script:Window.FindName('ContentHost');$script:Footer=$script:Window.FindName('FooterStatus')
$script:Window.ShowInTaskbar=$false;$script:Window.ShowActivated=$false;$script:Window.Left=-16000;$script:Window.Top=-16000
function PageHead {param([string]$Title,[string]$Description,[string]$Page)
 $script:Page=$Page;$script:Controls=@{};$script:HostPanel.Children.Clear();$script:Window.FindName('Scroll').ScrollToTop()
 if($Title){AddC $script:HostPanel (T $Title 24 $script:Ink 'SemiBold')};if($Description){AddC $script:HostPanel (Margin (T $Description 13 $script:Text3) '0,4,0,22')}
}
function OpenDialog {param($Title,$Body,$Note,$Confirm='确定',$Action=$null,$Cancel='取消',$ConfirmStyle='Primary',$Context=$null)
 $script:DialogTitle=[string]$Title;$script:DialogCallback=$Action;$script:DialogContext=$Context
 $script:Window.FindName('DialogTitle').Text=[string]$Title;$script:Window.FindName('DialogBody').Text=[string]$Body;$script:Window.FindName('DialogNote').Text=[string]$Note
 $script:Window.FindName('DialogConfirm').Content=$Confirm;$script:Window.FindName('DialogCancel').Content=$Cancel;$script:Window.FindName('Overlay').Visibility='Visible'
}
function CloseDialog {$script:Window.FindName('Overlay').Visibility='Collapsed';$script:DialogCallback=$null;$script:DialogContext=$null}
function ErrorDialog {param([string]$Message) OpenDialog 'error' $Message '' '知道了' $null ''}
$script:Window.FindName('DialogConfirm').Add_Click({$action=$script:DialogCallback;$context=$script:DialogContext;CloseDialog;if($action){& $action $context}})
$script:Window.FindName('DialogCancel').Add_Click({CloseDialog})
function StartJob {param([hashtable]$Request,[scriptblock]$Complete,[string]$Message='',[string]$Transition='',[switch]$Silent,[scriptblock]$Failed=$null)
 $script:Requests.Add([pscustomobject]@{Request=$Request.Clone();Complete=$Complete;Failed=$Failed})
 $script:AllRequests.Add($Request.Clone())
}
function IsBusy {return $false}
function IsRunning {return $script:Overview.Running}
function IsProviderTag {param([string]$Tag) $Tag -like 'provider*'}
function Toast {param([string]$Text) $script:LastToast=$Text}
function ShowNodes {PageHead '线路' '' 'nodes'}
function FetchNodes {StartJob @{Action='Nodes'} {} 'fixture read'}
function ShowHome {PageHead '当前连接' '' 'home'}
function RefreshOverview {param([switch]$Silent) StartJob @{Action='Overview'} {} 'fixture read'}
function RunCheck {StartJob @{Action='CheckActive'} {} 'fixture current check'}
function ShowServerManagement {PageHead '我的服务器' '' 'servers'}
function ShowConnectionRecovery {param([string]$Id,[string]$Message) StartJob @{Action='LineRecovery';Id=$Id} {} 'fixture diagnostics'}
function ShowProductPairing {PageHead '已有服务器' '' 'setup'}
function ShowMigration {PageHead '迁移' '' 'setup'}
. (Join-Path $script:PackageRoot 'ui/ConnectionProfilePages.ps1')
. (Join-Path $script:PackageRoot 'ui/SetupPages.ps1')
. (Join-Path $script:PackageRoot 'ui/DeploymentPages.ps1')
. (Join-Path $script:PackageRoot 'ui/OperationHistoryPages.ps1')
. (Join-Path $script:PackageRoot 'ui/DeploymentIdentityPages.ps1')
ImportPresentationFunctions (Join-Path $script:PackageRoot 'ui/Test-0120UI.ps1') @('InitializeUI0120ProtocolFixtures','ReadUI0120Json','NewUI0120Evidence','SaveUI0120Default','NewUI0120ComparisonEvidence','NewUI0120Line')
InitializeUI0120ProtocolFixtures
function ClickUI {param([string]$Id)
 $control=$script:Controls[$Id];AssertUI ($null -ne $control) ('control '+$Id);$control.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
}
function ClickDialog {param([string]$Id) $script:Window.FindName($Id).RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))}
function CompleteUI {param($Data) & $script:Requests[$script:Requests.Count-1].Complete $Data}
function LastRequest {$script:Requests[$script:Requests.Count-1].Request}
function ResetUI {
 CloseDialog;$script:Requests.Clear();$script:ConnectionPreviewUI=$null;$script:LineProfileUI=$null;$script:ReadOnly=$false;$script:Step=0;$script:Role='client'
 $script:DeployUI=@{Run=$null;Reauth=$false;SessionAttached=$false;ChooseNetwork=$false;PollError='';ManagementMode=$false;LastPoll=[DateTime]::MinValue}
 $script:Overview=[pscustomobject]@{Running=$true;StateKey='Connected';NodeName='香港主线（模拟）';NinjaRunning=$false;ActiveLineId='fixture-current';ActiveProfileId='Udp';ManifestPath='fixture-current';SessionPresent=$true}
}
function NewUI0142Fixture {param([string]$Kind='Stability',[switch]$NoSaved,[switch]$Legacy,[DateTimeOffset]$At=[DateTimeOffset]::UtcNow)
 $line=NewUI0120Line -SelectionKind $Kind -Winner Tcp -NoSaved:($NoSaved -or $Legacy) -At $At;$line.Name='新线路（模拟）';$profiles=$line.Profiles
 $bindings=@($profiles|ForEach-Object {[pscustomobject]@{ProfileId=$_.Id;BindingState='Reused';ReasonCode='StoredBindingUnchanged';ProfileRevision=$_.Revision;CandidateSHA256=$_.CandidateSHA256;ManifestSHA256=$_.ManifestSHA256;BindingDigest=('E'*64);NextAction='None';Interfaces=@()}})
 $run=[pscustomobject]@{ExperienceVersion=$(if($Legacy){0}else{1});AutoSavedAtUtc=$(if($line.SavedConnectionPreference){$line.SavedConnectionPreference.SavedAtUtc}else{$null});AttentionRequired=(-not $line.SavedConnectionPreference);RunId='fixture-run';CandidateNodeId=$line.LineId;Name=$line.Name;Stage='ReadyInactive';Status=$(if($line.SavedConnectionPreference){'Complete'}else{'Completed'});DeploymentCompleteness='Complete';MissingProtocols=@();Profiles=$profiles;ValidationProfiles=[pscustomobject]@{Udp=$profiles[0].Validation;Tcp=$profiles[1].Validation};SavedConnectionPreference=$line.SavedConnectionPreference;Recommendation=$line.Recommendation;PreferredProfileId=$line.PreferredProfileId;PreferenceSource=$line.PreferenceSource;CandidateManifestPath=$profiles[0].ManifestPath;ProfileProbeState='Completed';RecoveryRequired=$false;PartialUseAccepted=$false;ProbePreparation=[pscustomobject]@{State='Ready';Code='BindingsPrepared';Results=$bindings};ProbeProgress=$null;ProbeInterfaceIndex=0;LastError=$null;CloudRuleList=@([pscustomobject]@{Protocol='Udp';Port=51820;Purpose='UDP'},[pscustomobject]@{Protocol='Tcp';Port=443;Purpose='TCP'});ServerRecordId='fixture-server';ProtocolPreparation=[pscustomobject]@{Udp=[pscustomobject]@{LocalPreparation='SyntaxValidated';ServerPreparation='Configured'};Tcp=[pscustomobject]@{LocalPreparation='SyntaxValidated';ServerPreparation='Configured'}}}
 $line|Add-Member NoteProperty DeploymentCompleteness 'Complete' -Force
 $script:Nodes=@($line);[pscustomobject]@{Run=$run;Line=$line}
}
function RenderRun {param($Run) $script:DeployUI.Run=$Run;$script:Role='deployment';$script:DeployUI.Reauth=$false;ShowProductDeployment}
function RenderLine {param($Line) $script:LineProfileUI=@{Id=$Line.LineId;Line=$Line;Error='';SwitchResult=$null;MaintenanceMode=$false};ShowLineConnections}
function SnapshotUI {param([string]$Name)
 $script:Footer.Text='隔离 UI 验证 · 模拟状态，网络保持';$script:Window.FindName('FooterContext').Text='0.14.2 / UI TEST'
 $script:Window.UpdateLayout();$null=$script:Window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Render)
 $content=$script:Window.Content;$width=[int]$content.ActualWidth;$height=[int]$content.ActualHeight
 $bitmap=New-Object Windows.Media.Imaging.RenderTargetBitmap($width,$height,96,96,[Windows.Media.PixelFormats]::Pbgra32);$bitmap.Render($content)
 $encoder=New-Object Windows.Media.Imaging.PngBitmapEncoder;$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap));$stream=[IO.File]::Open((Join-Path $qa ($Name+'.png')),[IO.FileMode]::Create)
 try{$encoder.Save($stream)}finally{$stream.Dispose()};AssertUI ($width -ge 990 -and $height -ge 670) ('WPF render '+$Name)
}
function AssertReachable {param([string]$Id)
 $script:Window.UpdateLayout();$control=$script:Controls[$Id];$y=$control.TransformToAncestor($script:HostPanel).Transform((New-Object Windows.Point(0,0))).Y
 $script:Window.FindName('Scroll').ScrollToVerticalOffset($y);$script:Window.UpdateLayout();$point=$control.TranslatePoint((New-Object Windows.Point(0,0)),$script:Window.Content)
 AssertUI ($control.ActualWidth -gt 60 -and $point.X -ge 0 -and $point.X+$control.ActualWidth -le $script:Window.Content.ActualWidth -and $point.Y -ge 0 -and $point.Y+$control.ActualHeight -le $script:Window.Content.ActualHeight) ('minimum window reaches '+$Id)
}
try{
 $script:Window.Show()
 ResetUI;ShowSetup;SnapshotUI '0142-01-scenarios'
 AssertUI ($script:Requests.Count -eq 0 -and $script:Controls.ContainsKey('DeployAddLine') -and -not $script:Controls.ContainsKey('DeployNew') -and -not $script:Controls.ContainsKey('DeployAdd') -and $script:Controls.ContainsKey('OpenConnectionMaterial')) 'scenario has one add-line entry and explicit material import without forced environment choices or dispatch'
 ClickUI 'DeployAddLine';AssertUI ($script:DeployUI.Intent -eq 'Auto' -and (LastRequest).Action -eq 'DeploymentDiscover') 'add-line entry delegates environment classification through Auto discovery'
 AssertUI ($script:Controls.DeployTransport.SelectedItem.Tag -eq 'Auto' -and -not $script:Controls.DeploymentAdvanced.IsExpanded) 'automatic default is selected and manual protocol choices stay in advanced settings'
 ResetUI;$f=NewUI0142Fixture -Legacy
 RenderRun $f.Run;SnapshotUI '0142-02-tcp-recommended'
 AssertUI ($script:Controls.DeployOutcomeTitle.Text -eq '部署完成，推荐 TCP' -and $script:Controls.DeployPreparationStatus.Text -like '*已备齐*' -and $script:Controls.DeployActivationStatus.Text -like '*尚未启用*香港主线*继续使用*') 'configuration recommendation and current activation are distinct'
 AssertUI ($script:Controls.DeployLater.Content -eq '完成，保留当前连接' -and $script:Controls.DeployConnectRecommended.Content -eq '连接 TCP…' -and $script:Requests.Count -eq 0) 'normal completion offers save and a separate confirmed connection without activation'
 AssertUI ($script:Controls.DeployDiagnosticSummary.Text -like '*通过 17 / 18*超时 1*' -and $script:Controls.DeployApplicationTcp.Text -like '*403*不影响隧道*') 'required requests and optional app limits are displayed independently'
 ClickUI 'DeployLater';AssertUI ($script:Requests.Count -eq 1 -and (LastRequest).Action -eq 'DeploymentProceed' -and (LastRequest).Command -eq 'Save' -and (LastRequest).RunId -eq 'fixture-run') 'finish submits Save on the original run and waits for completion'
 AssertUI ($script:Page -eq 'setup' -and $script:Overview.ActiveLineId -eq 'fixture-current') 'Save request does not prematurely leave the page or change the session'
 CompleteUI $f.Run;AssertUI ($script:Page -eq 'nodes' -and (LastRequest).Action -eq 'Nodes' -and $script:Overview.ActiveLineId -eq 'fixture-current') 'successful Save returns to line cards and preserves current connection'
 ResetUI;$f=NewUI0142Fixture -Legacy;$f.Line.Recommendation.Status='Inconclusive';$f.Run.ProbePreparation.Results[0].ReasonCode='StoredBindingMissing';RenderRun $f.Run;SnapshotUI '0142-03-path-preparation'
 AssertUI ($script:Controls.DeployProbe.Content -eq '自动准备检测路径并重新检查' -and $script:Controls.DeployPreparedProfiles.Content -like '*已准备*' -and -not $script:Controls.ContainsKey('DeployRetryTrust')) 'missing binding has a local preparation exit and no repeated SSH login'
 ClickUI 'DeployProbe';AssertUI ((LastRequest).Action -eq 'DeploymentProceed' -and (LastRequest).Command -eq 'Probe' -and (LastRequest).Count -eq 3) 'path preparation uses the unified original-run Probe command'
 ResetUI;$f=NewUI0142Fixture;$f.Run.Stage='PreparingProbePath';$f.Run.ProbePreparation.State='Preparing';$f.Run.ProfileProbeState='Running';RenderRun $f.Run;SnapshotUI '0142-04-preparing'
 AssertUI ($script:Controls.DeployCheckProgress.Text -like '*准备检测路径*' -and $script:Controls.ContainsKey('DeployStopCheck') -and -not $script:Controls.ContainsKey('DeployConnectRecommended') -and -not $script:Controls.ContainsKey('DeployPreparedProfiles')) 'path preparation displays real progress with no trial or duplicate probe'
 ClickUI 'DeployStopCheck';AssertUI ((LastRequest).Action -eq 'DeploymentCancelProbe') 'preparation can capture the bounded cancellation request without running a worker'
 $f.Run.Stage='CheckingProfiles';$f.Run.ProbePreparation.State='Ready';$f.Run.ProbeProgress=[pscustomobject]@{Stage='CheckingProfiles';ProfileId='Tcp';Round=2;UpdatedAtUtc=[DateTimeOffset]::UtcNow.ToString('o')};RenderRun $f.Run
 AssertUI ($script:Controls.DeployCheckProgress.Text -like '*TCP 2/3*') 'live ProbeProgress supplies the actual protocol and round'
 ResetUI;$f=NewUI0142Fixture -Legacy;$f.Line.Recommendation.Status='Inconclusive';$f.Run.ProbePreparation.State='NeedsNetworkSelection'
 foreach($binding in $f.Run.ProbePreparation.Results){$binding.BindingState='NeedsNetworkSelection';$binding.Interfaces=@([pscustomobject]@{Index=7;Name='以太网';Type='Ethernet';LocalAddress='192.0.2.20'},[pscustomobject]@{Index=9;Name='无线网络';Type='WiFi';LocalAddress='198.51.100.30'})}
 RenderRun $f.Run;ClickUI 'DeployChooseNetwork';SnapshotUI '0142-05-choose-network'
 AssertUI ($script:Controls.DeployProbeNetwork.Items.Count -eq 2 -and $script:Controls.DeployProbeNetwork.SelectedIndex -eq -1 -and $script:Requests.Count -eq 0) 'selection lists interface name type and address and never silently chooses a network'
 ClickUI 'DeployProbeSelectedNetwork';AssertUI ($script:DialogTitle -eq 'error' -and $script:Requests.Count -eq 0) 'selection must be explicit before a probe request'
 CloseDialog;$script:Controls.DeployProbeNetwork.SelectedIndex=1;ClickUI 'DeployProbeSelectedNetwork'
 AssertUI ((LastRequest).Action -eq 'DeploymentProceed' -and (LastRequest).Command -eq 'Probe' -and (LastRequest).InterfaceIndex -eq 9 -and (LastRequest).Count -eq 4) 'selected network is sent only as InterfaceIndex on the unified Probe command'
 ResetUI;$f=NewUI0142Fixture -Legacy;$f.Line.Recommendation.Status='Inconclusive';$f.Line.Profiles[1].Validation.Status='Inconclusive';$f.Line.Profiles[1].Validation.Code='ForwardingPassedPhysicalPathUnverified';RenderRun $f.Run;SnapshotUI '0142-06-path-limited'
 AssertUI ($script:Controls.DeployOutcomeTitle.Text -eq '配置已备齐，网络检查需要处理' -and $script:Controls.DeployDiagnostics.Content -eq '查看检测限制' -and -not $script:Controls.ContainsKey('DeployConnectRecommended')) 'forwarding without verified path shows actionable limitations without an automatic choice'
 ClickUI 'DeployPreparedProfiles';SnapshotUI '0142-07-manual-profiles'
 AssertUI ($script:Controls.ConnectProfileTcp.Content -eq '手动试用 TCP（尚未完整验证）' -and $script:Controls.ConnectProfileTcp.IsEnabled -and $script:Controls.LineManualTryNotice.Text -like '*NinjaTrader*' -and $script:Requests.Count -eq 0) 'manual trial shares the line profile page and explains preflight before dispatch'
 ClickUI 'ConnectProfileTcp';AssertUI ($script:Requests.Count -eq 1 -and (LastRequest).Action -eq 'ConnectionSwitchPreview' -and (LastRequest).ProfileId -eq 'Tcp') 'manual choice requests only the existing explicit-profile preview'
 CompleteUI ([pscustomobject]@{CanSwitch=$true;LineId=$f.Line.LineId;ProfileId='Tcp';PreviewToken='isolated-token';Message='模拟影响：核对交易出口；失败恢复原配置及会话。'})
 AssertUI ($script:Requests.Count -eq 1 -and $script:Window.FindName('DialogBody').Text -like '*香港主线*新线路*TCP*检测路径未能核验*' -and $script:Window.FindName('DialogConfirm').Content -eq '连接并检查') 'preview shows current target checks and recovery before confirmation'
 ClickDialog 'DialogCancel';AssertUI ($script:Requests.Count -eq 1) 'cancelled manual preview never commits a connection'
 ClickUI 'ConnectProfileTcp';CompleteUI ([pscustomobject]@{CanSwitch=$true;LineId=$f.Line.LineId;ProfileId='Tcp';PreviewToken='isolated-token-2'})
 ClickDialog 'DialogConfirm';AssertUI ((LastRequest).Action -eq 'ConnectionSwitchCommit' -and (LastRequest).PreviewToken -eq 'isolated-token-2' -and (LastRequest).ProfileId -eq 'Tcp') 'explicit confirmation captures exactly the approved immutable transaction'
 ResetUI;$f=NewUI0142Fixture;RenderLine $f.Line;$script:Overview.NinjaRunning=$true;ClickUI 'ConnectProfileTcp'
 AssertUI ($script:Requests.Count -eq 0 -and $script:DialogTitle -eq 'error') 'NinjaTrader protection blocks the preview before any dispatch'
 CloseDialog;$script:Overview.NinjaRunning=$false;ClickUI 'ConnectProfileTcp';CompleteUI ([pscustomobject]@{CanSwitch=$true;LineId=$f.Line.LineId;ProfileId='Tcp';PreviewToken='ninja-token'});$script:Overview.NinjaRunning=$true;$before=$script:Requests.Count;ClickDialog 'DialogConfirm'
 AssertUI ($script:Requests.Count -eq $before -and $script:DialogTitle -eq 'error') 'NinjaTrader is checked again when confirming a prepared preview'
 foreach($reason in @('ActiveIdentity','ProbeCleanupFailed','ProbeIdentityUnknown')){
  ResetUI;$f=NewUI0142Fixture;$f.Run.ProbePreparation.State='Blocked';$f.Run.ProbePreparation.Results[0].BindingState='Blocked';$f.Run.ProbePreparation.Results[0].ReasonCode=$reason;RenderRun $f.Run
  AssertUI (-not $script:Controls.ContainsKey('DeployConnectRecommended') -and -not $script:Controls.ContainsKey('DeployProbe') -and -not $script:Controls.ContainsKey('DeployPreparedProfiles')) ($reason+' suppresses probes and trials even with old good evidence')
  RenderLine $f.Line;AssertUI (-not $script:Controls.ConnectProfileUdp.IsEnabled -and -not $script:Controls.ConnectProfileTcp.IsEnabled) ($reason+' also blocks the shared profile trial controls')
  PreviewLineConnectionSwitch 'Tcp';AssertUI ($script:Requests.Count -eq 0) ($reason+' cannot bypass the controls by calling the preview helper')
 }
 ResetUI;$f=NewUI0142Fixture;$f.Run.ProbePreparation.State='Blocked';$f.Run.ProbePreparation.Results[0].BindingState='Blocked';$f.Run.ProbePreparation.Results[0].ReasonCode='ActiveIdentity';RenderRun $f.Run;ClickUI 'DeployCheckActive'
 AssertUI ((LastRequest).Action -eq 'CheckActive' -and $script:Requests.Count -eq 1) 'active identity exit checks the existing connection instead of starting a candidate'
 ResetUI;$f=NewUI0142Fixture;$f.Line.Recommendation.Status='Unavailable';foreach($p in $f.Line.Profiles){$p.Validation.Status='Failed';$p.Validation.Code='ForwardingFailed'};RenderRun $f.Run
 AssertUI ($script:Controls.DeployDiagnostics.Content -eq '检查连接问题' -and $script:Controls.DeployConnectRecommended.Content -like '*TCP*' -and $script:Controls.DeployConnectRecommended.IsEnabled -and $script:Controls.DeployDiagnosticSummary.Text -like '*失败*') 'network failures remain visible while the saved TCP choice has an explicit connection attempt'
 $f.Run.LastError=[pscustomobject]@{Code='InboundCheckFailed';Message='never-copy-fixture-secret'};$f.Run|Add-Member NoteProperty Credential 'never-copy-fixture-secret';$f.Run|Add-Member NoteProperty Authorization 'never-copy-fixture-secret';$f.Line.Profiles[0].Validation.Samples[0]|Add-Member NoteProperty Body 'never-copy-fixture-secret';RenderRun $f.Run
 AssertUI (-not ([string]$script:Controls.DeployCopyDiagnostics.Tag).Contains('never-copy') -and $script:Controls.DeployCopyDiagnostics.Tag -like '*UDP 51820*TCP 443*') 'copiable summary contains port rules and excludes raw credentials authorization error bodies and sample content'
 ResetUI;$f=NewUI0142Fixture -Legacy;$f.Run.Recommendation.Status='Inconclusive';$f.Run.ProbePreparation.State='Unsupported';foreach($binding in $f.Run.ProbePreparation.Results){$binding.BindingState='Unsupported';$binding.ReasonCode='IPv6NotSupported'};RenderRun $f.Run
 AssertUI ($script:Controls.DeployDecisionMessage.Text -like '*IPv6*暂不支持*' -and $script:Controls.DeployDiagnosticSummary.Text -like '*IPv6NotSupported*') 'unsupported preparation displays a specific capability limit and its public reason code'
 ResetUI;$f=NewUI0142Fixture -Kind PolicyDefault;$f.Run.DeploymentCompleteness='Partial';$f.Run.MissingProtocols=@('Tcp');$f.Run.Profiles=@($f.Run.Profiles|Where-Object Id -eq 'Udp');$f.Line.Profiles=$f.Run.Profiles;$f.Run.Recommendation=Get-TCProtocolRecommendation -Profiles $f.Run.Profiles -NetworkContext $script:Fixture0120Network -LineId $f.Line.LineId;$f.Line.Recommendation=$f.Run.Recommendation;$f.Run.PreferredProfileId=$f.Run.Recommendation.PreferredProfileId;RenderRun $f.Run;SnapshotUI '0142-08-partial'
 AssertUI ($script:Controls.ContainsKey('DeployCompleteRemaining') -and $script:Controls.ContainsKey('DeployUsePrepared') -and -not $script:Controls.ContainsKey('DeployConnectRecommended')) 'partial keeps original completion and explicit prepared-use actions'
 ClickUI 'DeployUsePrepared';AssertUI ((LastRequest).Command -eq 'UsePrepared' -and -not $f.Run.PartialUseAccepted) 'partial acceptance waits for persisted backend result'
 $f.Run.PartialUseAccepted=$true;CompleteUI $f.Run;AssertUI ($script:Controls.ContainsKey('DeployConnectRecommended') -and $script:Controls.DeployPreparationStatus.Text -like '*部分完成*') 'acceptance does not hide missing protocols or silently connect'
 ResetUI;$f=NewUI0142Fixture -Kind PolicyDefault;SaveUI0120Default $f.Line Udp -Manual;$f.Run.SavedConnectionPreference=$f.Line.SavedConnectionPreference;$f.Run.PreferenceSource='UserChoice';$f.Run.PreferredProfileId='Udp';$f.Run.Recommendation=Get-TCProtocolRecommendation -Profiles $f.Run.Profiles -RequestedMode Udp -NetworkContext $script:Fixture0120Network -LineId $f.Line.LineId;$f.Line.Recommendation=$f.Run.Recommendation;RenderRun $f.Run
 AssertUI ($script:Controls.DeployDefaultLabel.Text -like '*默认方式*UDP*' -and $f.Run.SavedConnectionPreference.Provenance.Kind -eq 'ManualChoice' -and $script:Controls.DeployRecommendationReason.Text -like '*手动指定*' -and $null -eq $f.Run.Recommendation.RecommendedProfileId) 'chosen default is never presented as an automatic recommendation'
 ResetUI;$f=NewUI0142Fixture;RenderRun $f.Run;ClickUI 'DeployConnectRecommended';CompleteUI ([pscustomobject]@{CanSwitch=$true;LineId='wrong-line';ProfileId='Tcp';PreviewToken='wrong-token'})
 AssertUI ($script:DialogTitle -eq 'error' -and $script:Requests.Count -eq 1) 'mismatched preview remains rejected without a commit'
 ResetUI;$f=NewUI0142Fixture;$script:ReadOnly=$true;RenderRun $f.Run
 AssertUI (-not $script:Controls.DeployConnectRecommended.IsEnabled) 'read-only completion disables connection dispatch'
 InvokeDeploymentDecisionUI 'Probe';AssertUI ($script:Requests.Count -eq 0) 'read-only handler also rejects a direct probe call'
 ResetUI;$f=NewUI0142Fixture;RenderLine $f.Line;$before=$script:Overview.ActiveProfileId;ClickUI 'PreferProfileUdp'
 AssertUI ((LastRequest).Action -eq 'LinePreference' -and (LastRequest).ProfileId -eq 'Udp' -and $script:Overview.ActiveProfileId -eq $before) 'saving the next default retains the existing session'
 ResetUI;$f=NewUI0142Fixture;$f.Run.Status='NeedsRecovery';$f.Run.RecoveryRequired=$true;RenderRun $f.Run;ClickUI 'DeployReconcile'
 AssertUI ((LastRequest).Command -eq 'Continue') 'deployment recovery preserves the original reconciliation command'
 $script:Window.Width=1000;$script:Window.Height=680;ResetUI;$f=NewUI0142Fixture;RenderRun $f.Run
 foreach($id in @('DeployLeave','DeployConnectRecommended','DeployPreparedProfiles')){AssertReachable $id};SnapshotUI '0142-09-minimum-completion'
 ResetUI;$f=NewUI0142Fixture -Legacy;$f.Line.Recommendation.Status='Inconclusive';$f.Line.Profiles[1].Validation.Status='Inconclusive';RenderRun $f.Run;ClickUI 'DeployPreparedProfiles'
 foreach($id in @('ConnectProfileUdp','ConnectProfileTcp','LineProfilesBack')){AssertReachable $id};SnapshotUI '0142-10-minimum-profiles'
 AssertUI (-not (Test-Path -LiteralPath $script:JobRoot) -and (Get-Command Start-Process).CommandType -eq 'Function') 'standalone harness creates no worker queue and forbids process launches'
 $allowed=@('DeploymentDiscover','DeploymentProceed','DeploymentCancelProbe','ConnectionSwitchPreview','ConnectionDefaultPreview','ConnectionSwitchCommit','LinePreference','Nodes','Overview','CheckActive')
 AssertUI (@($script:AllRequests|Where-Object {$_.Action -notin $allowed -or $_.ContainsKey('SessionAction') -or $_.ContainsKey('Credential') -or $_.ContainsKey('Authorization')}).Count -eq 0) 'every captured request stays within local UI contracts and excludes credentials direct sessions and server actions'
 # Current saved-default contract, including the new ExperienceVersion=1 run.
 ResetUI;$f=NewUI0142Fixture -Kind Performance
 $f.Run|Add-Member NoteProperty ExperienceVersion 1 -Force;$f.Run|Add-Member NoteProperty AutoSavedAtUtc ([DateTimeOffset]::UtcNow.ToString('o')) -Force
 $f.Run|Add-Member NoteProperty AttentionRequired $false -Force;$f.Run.Status='Complete';RenderRun $f.Run
 $view=LineRecommendationView $f.Line
 AssertUI ($view.CanConnect -and $view.SelectionMode -eq 'SavedDefault' -and $view.Source -eq 'Performance' -and $view.RecommendationCurrent -and $f.Line.SavedConnectionPreference.Provenance.Kind -eq 'Recommendation' -and $f.Line.SavedConnectionPreference.Provenance.Recommendation.Source -eq 'Performance') 'new experience uses real original performance provenance for its saved default'
 AssertUI ($script:Controls.DeployOutcomeTitle.Text -eq '服务器与本机连接已准备' -and $script:Controls.DeployConnectRecommended.Content -like '*TCP*检查*' -and $script:Controls.DeployLeave.Content -eq '稍后使用' -and $script:Requests.Count -eq 0) ('new ready result contract: title='+$script:Controls.DeployOutcomeTitle.Text+'; connect='+$script:Controls.DeployConnectRecommended.Content+'; later='+$script:Controls.DeployLeave.Content+'; requests='+$script:Requests.Count)
 ClickUI 'DeployLeave';AssertUI ((LastRequest).Action -eq 'Nodes' -and $script:Requests.Count -eq 1 -and @($script:Requests|Where-Object {$_.Request.Action -eq 'DeploymentProceed' -and $_.Request.Command -eq 'Save'}).Count -eq 0 -and $f.Run.AutoSavedAtUtc -and $script:Overview.ActiveLineId -eq 'fixture-current') 'new later action reads lines and preserves the auto-saved run and original session'
 ResetUI;$f=NewUI0142Fixture -Kind Performance;RenderLine $f.Line
 AssertUI ($script:Controls.LineDefaultLabel.Text -like '*TCP*' -and $script:Controls.LineCurrentRecommendationLabel.Text -like '*TCP*' -and $script:Controls.LineCurrentConnectionLabel.Text -like '*未启用*' -and $script:Controls.ConnectProfileTcp.IsEnabled -and $script:Controls.PreferProfileUdp.IsEnabled) 'line separates current connection and saved default while retaining prepared-protocol controls'
 ClickUI 'ConnectProfileTcp';AssertUI ((LastRequest).Action -eq 'ConnectionDefaultPreview' -and (LastRequest).SelectionMode -eq 'SavedDefault' -and -not (LastRequest).ContainsKey('ProfileId') -and $script:Requests.Count -eq 1) 'normal visible saved TCP requests the controlled default preview without direct session or SSH calls'
 ResetUI;$f=NewUI0142Fixture -Kind Performance -At ([DateTimeOffset]::UtcNow.AddDays(-1));RenderLine $f.Line
 $view=LineRecommendationView $f.Line
 AssertUI ($view.CanConnect -and -not $view.RecommendationCurrent -and $view.OldRecommendationLabel -like '*已过期*' -and $script:Controls.LineOldRecommendationLabel.Text -like '*已过期*' -and $script:Controls.ConnectProfileTcp.IsEnabled -and $f.Line.SavedConnectionPreference.Source -eq 'Performance') 'expired original recommendation remains visibly old while its legitimate saved default is selectable'
 foreach($status in @('Failed','Blocked','OutcomeUnknown')){
  ResetUI;$f=NewUI0142Fixture -Kind Performance -At ([DateTimeOffset]::UtcNow.AddDays(-1));$f.Line.Profiles[1].Validation.Status=$status
  if($status -eq 'Blocked'){$f.Line.Profiles[1].Validation.Code='ActiveIdentity'}
  if($status -eq 'OutcomeUnknown'){$f.Line.Profiles[1].Validation.CleanupComplete=$false}
  RenderLine $f.Line
  AssertUI (-not (LineRecommendationView $f.Line).CanConnect -and -not $script:Controls.ContainsKey('ConnectLineDefault') -and $script:Requests.Count -eq 0) ('saved expiry never bypasses current '+$status+' evidence or incomplete cleanup')
 }
 ResetUI;$f=NewUI0142Fixture -Kind Performance;$f.Line.SavedConnectionPreference.Source='UserChoice';RenderLine $f.Line
 AssertUI (-not (LineRecommendationView $f.Line).CanConnect -and -not $script:Controls.ContainsKey('ConnectLineDefault') -and $script:Controls.PreferProfileUdp.IsEnabled -and $script:Requests.Count -eq 0) 'tampered recommendation source cannot become a genuine manual default; explicit preference controls remain available'
 ResetUI;$f=NewUI0142Fixture -Kind Performance -NoSaved;RenderLine $f.Line
 AssertUI (-not (LineRecommendationView $f.Line).CanConnect -and -not (LineRecommendationView $f.Line).ProfileId -and -not $script:Controls.ContainsKey('ConnectLineDefault') -and $script:Controls.ContainsKey('PreferProfileUdp') -and $script:Controls.ContainsKey('PreferProfileTcp') -and $script:Requests.Count -eq 0) 'an unset default never invents UDP while preserving explicit prepared-profile choice controls'
 ResetUI;$f=NewUI0142Fixture -Kind Performance;SaveUI0120Default $f.Line Udp -Manual;RenderLine $f.Line
 AssertUI ((LineRecommendationView $f.Line).Source -eq 'UserChoice' -and $f.Line.SavedConnectionPreference.Provenance.Kind -eq 'ManualChoice' -and -not $f.Line.SavedConnectionPreference.Provenance.Recommendation -and $f.Line.Recommendation.Source -eq 'Performance' -and $script:Controls.LineDefaultLabel.Text -like '*UDP*' -and $script:Controls.LineCurrentRecommendationLabel.Text -like '*TCP*') 'genuine manual default is distinct from the untouched automatic recommendation and its original evidence'
 ResetUI;$f=NewUI0142Fixture -Kind Performance;$f.Line|Add-Member NoteProperty ServerConnectionBlock 'ServerArchived';$f.Line|Add-Member NoteProperty ServerConnectionMessage '关联服务器世代已归档，请使用新身份线路。';RenderLine $f.Line
 AssertUI (-not (LineRecommendationView $f.Line).CanConnect -and -not $script:Controls.ConnectProfileTcp.IsEnabled -and (LineRecommendationView $f.Line).Reason -like '*归档*' -and $script:Requests.Count -eq 0) 'archived generation visibly blocks saved and explicit profile controls'
 # Legacy current-recommendation presentation still loses current qualification
 # on expiry; do not forge a new expiry on an already stored origin snapshot.
 ResetUI;$f=NewUI0142Fixture -Kind Performance -NoSaved;RenderRun $f.Run
 $script:ProtocolExpiryRefreshKey='';$old=NewUI0142Fixture -Kind Performance -NoSaved -At ([DateTimeOffset]::UtcNow.AddHours(-1))
 $script:DeployUI.Run=$old.Run;RefreshExpiredProtocolPresentation
 AssertUI (-not (LineRecommendationView $old.Line).RecommendationCurrent -and -not $script:Controls.ContainsKey('DeployConnectRecommended') -and $script:Requests.Count -eq 0) 'already-open unsaved recommendation loses current qualification without a probe or connection request'
 $expiryKey=$script:ProtocolExpiryRefreshKey;RefreshExpiredProtocolPresentation
 AssertUI ($script:ProtocolExpiryRefreshKey -eq $expiryKey -and $script:Requests.Count -eq 0) 'expired presentation refreshes once and never dispatches a worker'
 $summary=[ordered]@{Passed=$true;Suite='UI-0.14.2';Checks=$script:Assertions.Count;Assertions=@($script:Assertions);WorkerLaunched=$false;NetworkChanged=$false;WpfRendered=$true;OutputDirectory=$qa;PowerShellVersion=[string]$PSVersionTable.PSVersion}
 [IO.File]::WriteAllText((Join-Path $qa 'ui-0142-result.json'),($summary|ConvertTo-Json -Depth 6),(New-Object Text.UTF8Encoding($true)))
 [pscustomobject]@{Passed=$true;Checks=$script:Assertions.Count;WpfRendered=$true;WorkerLaunched=$false;NetworkChanged=$false;OutputDirectory=$qa}|ConvertTo-Json
}finally{$script:Window.Close()}
