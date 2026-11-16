#requires -Version 5.1
[CmdletBinding()]param([string]$SourceDirectory=(Join-Path $PSScriptRoot '..'),[string]$TestOutputDirectory='')
$ErrorActionPreference='Stop'
if([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw 'Run with Windows PowerShell -Sta.'}
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$script:PackageRoot=[IO.Path]::GetFullPath($SourceDirectory)
$script:Root=Join-Path ([IO.Path]::GetTempPath()) ('tc-maintenance-nav-'+[guid]::NewGuid().ToString('N'))
$qa=if($TestOutputDirectory){[IO.Path]::GetFullPath($TestOutputDirectory)}else{Join-Path $script:Root 'evidence'}
$common=[IO.Path]::GetFullPath([Environment]::GetFolderPath('CommonApplicationData')).TrimEnd('\')+'\'
if(($qa.TrimEnd('\')+'\').StartsWith($common,[StringComparison]::OrdinalIgnoreCase) -or ($qa.TrimEnd('\')+'\').StartsWith($script:PackageRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Evidence must be outside source and installed state.'}
$null=[IO.Directory]::CreateDirectory($qa)
$script:Smoke=$true;$script:ReadOnly=$false;$script:AutoTCP=$null;$script:Controls=@{};$script:Nodes=@();$script:Page='nodes';$script:Role='client';$script:Step=0
$script:Ink='#15181D';$script:Text2='#4B5360';$script:Text3='#858C97';$script:Hair='#E6E8EB'
$script:Tone=@{ok=@{Fg='#15803D';Bg='#ECF8F0'};warn=@{Fg='#A15C07';Bg='#FDF5E8'};bad=@{Fg='#B42318';Bg='#FEF1F0'};info=@{Fg='#1D4ED8';Bg='#EEF3FE'};idle=@{Fg='#4B5360';Bg='#F2F3F5'}}
$script:Checks=New-Object 'Collections.Generic.List[string]';$script:Requests=New-Object 'Collections.Generic.List[object]';$script:AllRequests=New-Object 'Collections.Generic.List[object]';$script:Shots=New-Object 'Collections.Generic.List[string]'
foreach($actor in @('Start-Process','Invoke-WebRequest','Invoke-RestMethod','Start-TCDeploySession','Invoke-TCDeployOperation','Get-TCDeploySavedCredential','Stop-TCDeploySession','RunWorker')){Set-Item ('Function:script:'+$actor) {throw ('Forbidden real actor: '+$MyInvocation.MyCommand.Name)}}
function Check {param([bool]$Condition,[string]$Name)if(-not $Condition){throw ('Maintenance navigation FAILED: '+$Name)};$script:Checks.Add($Name)}
function CollectText {param($Node)
 $texts=New-Object 'System.Collections.Generic.List[string]'
 $walk={param($n)
  if($n -is [Windows.Controls.TextBlock]){$texts.Add([string]$n.Text);return}
  if($n -is [Windows.Controls.Panel]){foreach($c in $n.Children){& $walk $c};return}
  if($n -is [Windows.Controls.Decorator] -and $n.Child){& $walk $n.Child;return}
  if($n -is [Windows.Controls.ContentControl] -and $n.Content -is [Windows.DependencyObject]){& $walk $n.Content}
 }
 & $walk $Node
 return @($texts)
}
function ImportPresentation {param([string]$Relative,[string[]]$Names)
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $script:PackageRoot $Relative),[ref]$tokens,[ref]$errors)
 if($errors.Count){throw ('Invalid source: '+$Relative)}
 foreach($name in $Names){$nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)|Where-Object Name -eq $name);if($nodes.Count -ne 1){throw ('Missing presentation function: '+$name)};$body=$nodes[0].Body.Extent.Text;Set-Item ('Function:script:'+$name) ([scriptblock]::Create($body.Substring(1,$body.Length-2)))}
}
ImportPresentation 'TradeChannel.ps1' @('B','AddC','T','Stack','Card','Margin','Grid','Cell','ControlName','Btn','Icon','IconTile','SectionLabel','KeyValue','HelpTip','HintIcon','TitleWithHint')
ImportPresentation 'ui/Pages.ps1' @('Tx','Head','Note')
ImportPresentation 'ui/SetupPages.ps1' @('SetupCardHeader')
ImportPresentation 'ui/DeploymentPages.ps1' @('DeploymentField','DeploymentActions')
. (Join-Path $script:PackageRoot 'ui/ServerPages.ps1')
. (Join-Path $script:PackageRoot 'ui/PairingPages.ps1')
. (Join-Path $script:PackageRoot 'ui/ConnectionProfilePages.ps1')
$script:ActualLoadLineConnections=${function:LoadLineConnections}
Import-Module (Join-Path $script:PackageRoot 'ProtocolSelection.psm1') -DisableNameChecking
[xml]$xaml=Get-Content -LiteralPath (Join-Path $script:PackageRoot 'ui/Shell.xaml') -Raw -Encoding UTF8
$reader=New-Object Xml.XmlNodeReader($xaml);$script:Window=[Windows.Markup.XamlReader]::Load($reader)
$script:Window.ShowInTaskbar=$false;$script:Window.ShowActivated=$false;$script:Window.Left=-16000;$script:Window.Top=-16000
$script:HostPanel=$script:Window.FindName('ContentHost')
function PageHead {param([string]$Title,[string]$Description,[string]$Page)
 $script:Page=$Page;SyncNavigationContext $Page $Title;$script:Controls=@{};$script:HostPanel.Children.Clear();$script:Window.FindName('Scroll').ScrollToTop()
 AddC $script:HostPanel (T $Title 24 $script:Ink 'SemiBold');AddC $script:HostPanel (Margin (T $Description 13 $script:Text3) '0,4,0,22')
}
function StartJob {param([hashtable]$Request,[scriptblock]$Complete,[string]$Message='',[string]$Transition='',[switch]$Silent,[scriptblock]$Failed=$null)
 $script:Requests.Add([pscustomobject]@{Request=$Request.Clone();Complete=$Complete;Failed=$Failed});$script:AllRequests.Add($Request.Clone())
}
function IsBusy {return $false}
function IsRunning {return $false}
function ActiveNodeId {return ''}
function Toast {param([string]$Message)$script:LastToast=$Message}
function ErrorDialog {param([string]$Message)$script:LastError=$Message}
function OpenDialog {param($Title,$Body,$Note,$Confirm,$Action)$script:Dialog=@{Title=$Title;Body=$Body;Action=$Action}}
function ShowNodes {$script:Role='client';PageHead '线路（隔离目的页）' '' 'nodes'}
function FetchNodes {StartJob @{Action='Nodes'} {} 'fixture read'}
function ShowSetupCenter {$script:Role='deployment-center';PageHead '部署中心（隔离目的页）' '' 'setup'}
function LoadLineConnections {param([string]$Id,[switch]$MaintenanceMode)$script:ReturnedLineId=$Id;$script:LineProfileUI=@{Id=$Id;MaintenanceMode=[bool]$MaintenanceMode};$script:Role='client';PageHead '线路连接方式（隔离目的页）' '' 'line-profiles'}
function ResumeProductDeployment {param([string]$Id)$script:ResumedRunId=$Id;StartJob @{Action='DeploymentGet';RunId=$Id} {} 'fixture exact resume'}
function LegacyLineNeedsTcpMaintenance {param($Line)return $false}
function Click {param([string]$Id)Check ($script:Controls.ContainsKey($Id)) ('Control '+$Id);$script:Controls[$Id].RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))}
function Deliver {param($Data,[int]$Index=-1)if($Index -lt 0){$Index=$script:Requests.Count-1};& $script:Requests[$Index].Complete $Data}
function Last {return $script:Requests[$script:Requests.Count-1].Request}
function Shot {param([string]$Name)
 $script:Window.FindName('FooterContext').Text='0.16.0 / ISOLATED FIXTURE';$script:Window.UpdateLayout();$null=$script:Window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Render)
 $content=$script:Window.Content;$bitmap=New-Object Windows.Media.Imaging.RenderTargetBitmap([int]$content.ActualWidth,[int]$content.ActualHeight,96,96,[Windows.Media.PixelFormats]::Pbgra32);$bitmap.Render($content)
 $encoder=New-Object Windows.Media.Imaging.PngBitmapEncoder;$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap));$path=Join-Path $qa ($Name+'.png');$stream=[IO.File]::Create($path);try{$encoder.Save($stream)}finally{$stream.Dispose()};$script:Shots.Add($path)
}
function ResetFixture {
 $script:Requests.Clear();$script:ServerNavigationUI=$null;$script:NavigationContext=$null;$script:ReturnedLineId='';$script:ResumedRunId='';$script:LastError='';$script:LineProfileUI=$null;$script:Nodes=@();$script:Role='client';$script:Page='nodes'
 if(Get-Variable JobQueue -Scope Script -ErrorAction SilentlyContinue){$script:JobQueue.Clear()};$script:QueuedJob=$null
 $script:Overview=@{Running=$false;StateKey='Disconnected'}
 $script:DeployUI=@{Run=$null;Screen='connect';Management=$null;Discovery=$null;PendingManagement=$null;DeviceResult=$null;Invite=$null;PairRequest=$null;EnrollmentId=$null;ManagementMode=$false;ServerDiscoveryAttempted=$false}
 InitializeServerUI;SetNavigationContext nodes nodes
}
function NewServer {param([string]$Id,[string]$PublicKey,[string[]]$Links,[string]$Access='NeedsAuthentication',[string]$State='Active')
 [pscustomobject]@{LocalRecordId=$Id;Name='同名服务器（夹具）';RecordState=$State;Connection=$(if($Access -ne 'ConnectorOnly'){@{Host='192.0.2.10';Port=22;User='root';IdentityFile=''}}else{$null});RemoteOwnerId=('owner-'+$Id);NodeId=('remote-'+$Id);ServerPublicKey=$PublicKey;PinnedHostKey=$null;OwnershipState=$(if($Access -eq 'ConnectorOnly'){'InvitationPinned'}else{'Applied'});ManagementAccessState=$Access;LinkedNodeIds=@($Links);ManagementSigningPublicKey=$null;CredentialRef='fixture-credential-reference';SavedLoginRef='dddddddd-dddd-dddd-dddd-dddddddddddd';ReplacedByServerId='';LastCheckedUtc='2026-10-12T01:00:00Z'}
}
function LineView {param([string]$Id,[string]$Key,$Registry,[string[]]$Aliases=@())
 $state=Get-TCLineServerBindingState -LineId $Id -AliasIds $Aliases -ServerPublicKey $Key -Registry $Registry
 [pscustomobject]@{LineId=$Id;Name='原线路（夹具）';ServerPublicKey=$Key;AliasIds=@($Aliases);Profiles=@();ServerConnectionBlock=$state.Code;ServerConnectionMessage=$state.Message;ServerBindings=@($state.NavigationBindings)}
}
function VerifyNavigationScheduler {param($Line,$ServerA,$ServerB)
 # Exercise the actual non-smoke scheduler while a fake silent Overview job
 # is always present. Its queue branch cannot write requests or launch Worker.
 $captureStart=${function:StartJob};$captureBusy=${function:IsBusy}
 $script:JobRoot=Join-Path $script:Root 'forbidden-worker-requests'
 $script:Footer=[pscustomobject]@{Text=''};$script:Pending=$null
 $poll=@{Silent=$true;Action='Overview';FixtureOnly=$true}
 ImportPresentation 'TradeChannel.ps1' @('StateKey','IsBusy')
 Import-Module (Join-Path $script:PackageRoot 'WorkerContracts.psm1') -DisableNameChecking
 ImportPresentation 'ui/BackgroundJobs.ps1' @('StartJob','UiJobField','GetUiJobPolicy','TestUiJobCallbackContext','CompleteUiRequestLifecycle','TestUiMutationBlocked','RestoreUiJobReceipts','GetUiRequestDisposition')
 $script:JobQueue=New-Object 'Collections.Generic.List[object]';$script:UncertainUiJobs=New-Object 'Collections.Generic.List[object]';$script:UiJobRecoveryLoaded=$true
 function TakeNavigationRead {
  $next=$script:QueuedJob
  Check ($next -and $script:JobQueue.Count -eq 1 -and [object]::ReferenceEquals($script:JobQueue[0],$next)) 'Captured navigation callback belongs to the actual accepted queue entry'
  $script:JobQueue.RemoveAt(0);$script:QueuedJob=$null;return $next
 }
 $script:Smoke=$false
 try{
  ResetFixture;$script:Job=$poll;$script:QueuedJob=$null;$script:HostPanel.IsEnabled=$true
  & $script:ActualLoadLineConnections $Line.LineId
  Check ($script:QueuedJob.Request.Action -ceq 'LineProfiles' -and $script:QueuedJob.Request.Id -ceq $Line.LineId -and [object]::ReferenceEquals($script:Job,$poll)) 'Real scheduler queues line detail behind a silent overview instead of dropping it'
  $queued=TakeNavigationRead;& $queued.Failed 'fixture read failure'
  Check (-not $script:LineProfileUI.Loading -and $script:LineProfileUI.Error) 'Queued line read failure clears loading state'
  ResetFixture;$script:Job=$poll;$script:QueuedJob=$null
  OpenLineServerManagement $Line.LineId
  Check ($script:QueuedJob.Request.Action -ceq 'LineProfiles' -and $script:ServerNavigationUI.Loading) 'Real scheduler queues the line-to-server navigation read'
  $queued=TakeNavigationRead;& $queued.Complete $Line
  Check ($script:QueuedJob.Request.Action -ceq 'DeploymentDiscover' -and $script:ServerNavigationUI.Loading) 'Chained server discovery also queues behind an intervening silent poll'
  $queued=TakeNavigationRead;& $queued.Complete @{ManagementServers=@($ServerA,$ServerB);Servers=@($ServerA,$ServerB);ContinueRuns=@()}
  Check (-not $script:ServerNavigationUI.Loading -and $script:DeployUI.Management.ServerId -ceq $ServerA.LocalRecordId) 'Queued chained discovery opens the exact server and clears loading'
  ResetFixture;$script:Job=$poll;$script:QueuedJob=$null
  OpenServerRecordManagement $ServerA.LocalRecordId
  Check ($script:QueuedJob.Request.Action -ceq 'DeploymentDiscover' -and $script:ServerNavigationUI.SelectedServerId -ceq $ServerA.LocalRecordId) 'Real scheduler queues exact-record server navigation'
  $queued=TakeNavigationRead;& $queued.Failed 'fixture discovery failure'
  Check (-not $script:ServerNavigationUI.Loading -and $script:ServerNavigationUI.Message) 'Queued exact-record failure leaves a retryable detail instead of perpetual loading'
  ResetFixture;$script:Job=$poll;$script:QueuedJob=$null
  OpenServerManagement -ReturnKind Nodes
  Check ($script:QueuedJob.Request.Action -ceq 'DeploymentDiscover' -and $script:DeployUI.ServersLoading) 'Real scheduler queues first server-list discovery behind a silent overview'
  $queued=$script:QueuedJob;LoadServersUI
  Check ([object]::ReferenceEquals($queued,$script:QueuedJob)) 'Repeated list rendering preserves the already queued discovery'
  $queued=TakeNavigationRead;& $queued.Complete @{ManagementServers=@($ServerA,$ServerB);Servers=@($ServerA,$ServerB);ContinueRuns=@()}
  Check (-not $script:DeployUI.ServersLoading -and $script:DeployUI.Discovery) 'Queued server-list success clears loading'
  LoadServersUI;$queued=TakeNavigationRead;& $queued.Failed 'fixture list failure'
  Check (-not $script:DeployUI.ServersLoading -and $script:DeployUI.Management.Error) 'Queued server-list failure clears loading and keeps refresh available'
  ResetFixture;$script:Job=$poll;$script:QueuedJob=@{Request=@{Action='Nodes'}};$script:JobQueue.Add($script:QueuedJob)
  LoadServersUI;& $script:ActualLoadLineConnections $Line.LineId;OpenLineServerManagement $Line.LineId;OpenServerRecordManagement $ServerA.LocalRecordId;OpenServerManagement
  Check (-not $script:DeployUI.ServersLoading -and -not $script:LineProfileUI -and -not $script:ServerNavigationUI -and $script:QueuedJob.Request.Action -ceq 'Nodes' -and $script:JobQueue.Count -eq 1) 'An occupied user queue is preserved without creating new loading states'
  $script:QueuedJob=$null;$script:JobQueue.Clear();$script:Job=@{Silent=$false;Action='fixture-user-operation'};LoadServersUI
  Check (-not $script:DeployUI.ServersLoading -and -not $script:QueuedJob) 'A foreground operation prevents server-list loading from being set without an accepted read'
  Check (-not (Test-Path -LiteralPath $script:JobRoot)) 'Real scheduler verification creates no worker requests and launches no process'
 }finally{
  Set-Item Function:script:StartJob $captureStart;Set-Item Function:script:IsBusy $captureBusy
  $script:Smoke=$true;$script:Job=$null;$script:QueuedJob=$null;$script:JobQueue.Clear();$script:HostPanel.IsEnabled=$true
 }
}
$lineA='11111111-1111-4111-8111-111111111111';$lineB='22222222-2222-4222-8222-222222222222';$alias='33333333-3333-4333-8333-333333333333'
$serverA='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';$serverB='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';$keyA=('A'*43+'=');$keyB=('B'*43+'=')
try{
 $script:Window.Show();ResetFixture
 $a=NewServer $serverA $keyA @($lineA,$lineB);$b=NewServer $serverB $keyB @();$registry=@{SchemaVersion=1;Servers=@($b,$a)}
 $view=LineView $lineA $keyA $registry
 & $script:ActualLoadLineConnections $lineA
 Check ($script:Requests.Count -eq 1 -and (Last).Action -ceq 'LineProfiles' -and $script:Page -ceq 'line-profiles') 'Opening connection details reads legacy-capable view without registration'
 $pendingLineIndex=$script:Requests.Count-1;ShowNodes;Deliver $view $pendingLineIndex
 Check ($script:Page -ceq 'nodes' -and -not $script:LineProfileUI.Line) 'Late connection-details callback cannot reopen a page after navigation'
 ResetFixture
 & $script:ActualLoadLineConnections $lineA
 Deliver (LineView $lineB $keyA $registry)
 Check (-not $script:LineProfileUI.Line -and $script:LineProfileUI.Error -match '原线路') 'Connection detail callback rejects another line identity'
 ResetFixture
 Check ($view.ServerBindings.Count -eq 1 -and $view.ServerBindings[0].LocalRecordId -ceq $serverA) 'Same name and IP never select the other application identity'
 $dto=$view.ServerBindings|ConvertTo-Json -Depth 8
 Check ($dto -notmatch 'CredentialRef|SavedLoginRef|IdentityFile|PinnedHostKey' -and $dto -match 'ManagementAccessState') 'Navigation DTO includes public access state without management credential references'
 Check ((($registry|ConvertTo-Json -Depth 10) -match 'dddddddd-dddd-dddd-dddd-dddddddddddd') -and ($dto -notmatch 'dddddddd-dddd-dddd-dddd-dddddddddddd')) 'The saved login pointer value is on the record but never reaches the browser DTO'
 $a.LinkedNodeIds=@($alias);$aliased=LineView $lineA $keyA $registry @($alias)
 Check ($aliased.ServerBindings.Count -eq 1 -and -not $aliased.ServerConnectionBlock) 'Canonical line and verified protocol alias route to one server'
 $a.LinkedNodeIds=@($lineA,$lineB);$shared=LineView $lineB $keyA $registry
 Check ($shared.ServerBindings[0].LocalRecordId -ceq $serverA) 'Two local lines can share one server without merging their device identities'
 OpenLineServerManagement $lineA -ReturnKind LineProfiles
 Check ($script:Requests.Count -eq 1 -and (Last).Action -ceq 'LineProfiles' -and (Last).Id -ceq $lineA) 'Line maintenance starts with read-only exact line view'
 Deliver $view;Check ($script:Requests.Count -eq 2 -and (Last).Action -ceq 'DeploymentDiscover') 'Bound identity is re-read before opening management'
 Deliver @{ManagementServers=@($b,$a);Servers=@($b,$a);ContinueRuns=@()}
 Check ($script:DeployUI.Management.ServerId -ceq $serverA -and $script:ServerNavigationUI.View -ceq 'server-detail' -and $script:NavigationContext.TargetId -ceq $serverA) 'Actual line entry opens exact server detail and sets stable navigation target'
 Check (-not $script:Controls.ContainsKey('ServersAdd') -and $script:Controls.ContainsKey('ServerLogin') -and [string]$script:DeployUI.Management.LoginStage -ceq '') 'Detail has no new deployment action and the login card is closed'
 Shot '01-bound-server-login';Click MaintenanceBack
 Check ($script:ReturnedLineId -ceq $lineA -and $script:NavigationContext.View -ceq 'line-profiles') 'Return preserves original line ID'
 ResetFixture;& $script:ActualLoadLineConnections $lineA -MaintenanceMode
 Check ($script:LineProfileUI.MaintenanceMode -and $script:LineProfileUI.Loading -and $script:NavigationContext.View -ceq 'line-maintenance' -and -not $script:Controls.ContainsKey('LineManageServers')) 'Restored maintenance view waits for its own read before showing target actions'
 Deliver $view;OpenLineServerManagement $lineA -ReturnKind LineProfiles;Deliver $view;Deliver @{ManagementServers=@($a,$b);Servers=@($a,$b);ContinueRuns=@()};ReturnFromServerManagement
 Check ($script:ReturnedLineId -ceq $lineA -and $script:LineProfileUI.MaintenanceMode -and $script:NavigationContext.View -ceq 'line-maintenance') 'Server management returns to the exact maintenance subview of its original line'
 ResetFixture;$script:DeployUI.Discovery=@{ManagementServers=@($a,$b);Servers=@($a,$b);ContinueRuns=@()};OpenServerManagement -ReturnKind Nodes
 Check ($script:Controls.ContainsKey('ServerSelect'+($serverA-replace '-','')) -and -not $script:Controls.ContainsKey('ServerConnect')) 'Server list and selected detail are separate views'
 Shot '02-server-list'
 $script:AutoTCP=@{Id=$lineB;Stage='Access'};OpenServerManagement -ReturnKind Nodes
 Check (-not $script:AutoTCP -and $script:ServerNavigationUI.View -ceq 'server-list') 'Explicit management entry cannot reopen an abandoned TCP preparation page'
 # 0.23.0: the detail page no longer carries 刷新服务器列表 or 所有服务器. The list
 # keeps the refresh; the detail page keeps only the way back.
 Check ($script:Controls.ContainsKey('ServersRefresh') -and -not $script:Controls.ContainsKey('ServerAllRecords')) 'The server list keeps 刷新服务器列表 and has no 所有服务器'
 SelectServerUI $serverA;$script:DeployUI.Management.LoginStage='Method';ShowServerManagement
 Check (-not $script:Controls.ContainsKey('ServersRefresh') -and -not $script:Controls.ContainsKey('ServerAllRecords')) 'The server detail has neither 刷新服务器列表 nor 所有服务器'
 LoadServersUI;Deliver @{ManagementServers=@($b,$a);Servers=@($b,$a);ContinueRuns=@()}
 Check ($script:DeployUI.Management.ServerId -ceq $serverA -and [string]$script:DeployUI.Management.LoginStage -ceq 'Method' -and $script:ServerNavigationUI.ReturnKind -ceq 'Nodes') 'Refresh preserves exact selection, login stage and return origin'
 ResetFixture;$connector=NewServer $serverA $keyA @($lineA) ConnectorOnly;$connector.CredentialRef=$null
 OpenLineServerManagement $lineA -ReturnKind Nodes;Deliver (LineView $lineA $keyA @{SchemaVersion=1;Servers=@($connector)});Deliver @{ManagementServers=@();Servers=@($connector);ContinueRuns=@()}
 Check (-not $script:Controls.ContainsKey('ServerPassword') -and -not $script:Controls.ContainsKey('ServerCreateInvite') -and -not $script:Controls.ContainsKey('ServerUninstallPreview') -and $script:Controls.ContainsKey('ConnectorBackToLine')) 'Invitation-only user has no management or deployment controls'
 Shot '03-connector-only'
 ResetFixture;$a.OwnershipState='OwnedNotInstalled';$runId='44444444-4444-4444-8444-444444444444';$script:DeployUI.Discovery=@{ManagementServers=@($a);Servers=@($a);ContinueRuns=@(@{RunId=$runId;ServerRecordId=$serverA;Stage='MaterializeCandidate';Status='Failed'})};OpenServerManagement;SelectServerUI $serverA
 Click ('ServerContinue'+($runId-replace '-',''));Check ($script:ResumedRunId -ceq $runId -and (Last).Action -ceq 'DeploymentGet') 'Partial deployment resumes original run without creating another deployment'
 Shot '04-partial-server'
 ResetFixture;$archived=NewServer $serverA $keyA @($lineA) NeedsAuthentication Archived;$archived.ReplacedByServerId=$serverB
 OpenServerRecordManagement $serverA -ReturnKind Context;Deliver @{ManagementServers=@($b);Servers=@($archived,$b);ContinueRuns=@()}
 Check ($script:ServerNavigationUI.DetailKind -ceq 'Archived' -and -not $script:Controls.ContainsKey('ServerConnect') -and $script:Controls.ContainsKey('ViewReplacementServer')) 'Exact archived record is a read-only detail with explicit replacement link'
 Shot '05-archived-server'
 Check ($script:Controls.MaintenanceBack.Content -ceq '返回线路列表') 'A source-context return names its line-list destination instead of a generic previous page'
 ReturnFromServerManagement;Check ($script:Page -ceq 'nodes') 'The generic source-context return reaches its captured origin'
 ResetFixture
 OpenServerRecordManagement $serverA -ReturnKind Context -Intent Login
 Check ($script:ServerNavigationUI.DetailKind -ceq 'Managed' -and $script:ServerNavigationUI.Loading -and $script:ServerNavigationUI.PendingIntent -ceq 'Login') 'Login intent opens a managed loading state instead of the binding page'
 Check ([string]$script:DeployUI.Management.LoginStage -ceq 'Method') 'Login intent prepares the method step before the first render'
 Check ($script:HostPanel.Children[0].Text -ceq '登录这台服务器') 'Login loading uses the login title rather than the binding title'
 Check ($script:Controls.MaintenanceBack.Content -ceq '返回线路列表') 'Login loading keeps a single destination-labelled return'
 & $script:Requests[$script:Requests.Count-1].Failed 'fixture discovery failure'
 Check (-not $script:ServerNavigationUI.Loading -and $script:Controls.ContainsKey('ServerLoginRetry')) 'Login read failure keeps a retry inside the login context'
 Check ($script:HostPanel.Children[0].Text -ceq '登录这台服务器') 'Login failure keeps the login title'
 ResetFixture
 OpenServerRecordManagement $serverA -ReturnKind Context -Intent Login
 Deliver @{ManagementServers=@($a);Servers=@($a);ContinueRuns=@()}
 Check ($script:Controls.ContainsKey('ServerLoginPassword') -and $script:Controls.ContainsKey('ServerLoginSaved')) 'Login discovery lands directly on the method choice'
 Check (-not $script:ServerNavigationUI.Loading -and [string]$script:DeployUI.Management.LoginStage -ceq 'Method') 'Login method stage survives the record selection rebuild'
 Check ($script:HostPanel.Children[0].Text -ceq '服务器与设备') 'Ready login card keeps the detail title and does not duplicate the card heading'
 Shot '09-login-direct-method'
 ResetFixture;$script:DeployUI.Discovery=@{ManagementServers=@($a);Servers=@($a);ContinueRuns=@();Runs=@()}
 OpenServerRecordManagement $serverA -ReturnKind Context -Intent Login
 Check ($script:Requests.Count -eq 0) 'A locally known server needs no worker read before the login card'
 Check ($script:Controls.ContainsKey('ServerLoginPassword')) 'A locally known server lands on the method choice without a loading page'
 Check (-not $script:ServerNavigationUI.Loading -and [string]$script:DeployUI.Management.LoginStage -ceq 'Method') 'The fast login path keeps the method stage and leaves no loading state'
 $pageTexts=@(CollectText $script:HostPanel)
 Check (@($pageTexts|Where-Object {$_ -ceq '登录这台服务器'}).Count -eq 0) 'The login card no longer repeats its own heading'
 Check (@($pageTexts|Where-Object {$_ -like '*同名服务器*'}).Count -eq 1) ('The server name appears once, in the summary line only -> '+(@($pageTexts|Where-Object {$_ -like '*同名服务器*'}) -join ' / '))
 Check (@($pageTexts|Where-Object {$_ -ceq '选择登录方式'}).Count -eq 1) 'The method step carries the single instruction'
 ResetFixture;$bad=LineView $lineA $keyA @{SchemaVersion=1;Servers=@($archived)}
 OpenLineServerManagement $lineA;Deliver $bad
 Check ($script:Requests.Count -eq 1 -and -not $script:DeployUI.Management.ServerId -and $script:ServerNavigationUI.DetailKind -ceq 'Binding') 'Archived line cannot route into a new application identity'
 Shot '06-archived-line-block'
 ResetFixture;$duplicate=NewServer $serverB $keyA @($lineA);$ambiguous=LineView $lineA $keyA @{SchemaVersion=1;Servers=@($a,$duplicate)}
 OpenLineServerManagement $lineA;Deliver $ambiguous
 Check ($ambiguous.ServerConnectionBlock -ceq 'ServerBindingAmbiguous' -and $script:Requests.Count -eq 1 -and -not $script:DeployUI.Management.ServerId) 'Ambiguous public bindings cannot silently pick a server'
 ResetFixture;OpenLineServerManagement $lineA;$oldIndex=$script:Requests.Count-1;ShowNodes;Deliver $view $oldIndex
 Check ($script:Requests.Count -eq 1 -and $script:Page -ceq 'nodes') 'Late line read cannot steal focus after leaving management'
 ResetFixture;OpenServerRecordManagement $serverA;ShowNodes;Deliver @{ManagementServers=@($a,$b);Servers=@($a,$b);ContinueRuns=@()}
 Check ($script:Page -ceq 'nodes' -and -not $script:DeployUI.Management.ServerId) 'Late exact-record discovery cannot select a hidden server'
 ResetFixture;$a.OwnershipState='Applied';$script:DeployUI.Discovery=@{ManagementServers=@($a);Servers=@($a);ContinueRuns=@()};OpenServerManagement;SelectServerUI $serverA
 InitializePairingUI;$script:DeployUI.PairIntake.Role='Manager';$m=$script:DeployUI.Management;$m.Authenticated=$true;$m.SessionRef=@{RunId='fixture'}
 $info=@{RemoteOwnerId=$a.RemoteOwnerId;Node=@{NodeId=$a.NodeId;ServerPublicKey=$keyA};ManagementApiVersion=2;OwnershipState='Applied';ManagementSigningPublicKey=@{kty='RSA';n='fixture';e='AQAB'};ConfigRevision=3}
 StartServerOperation server_info @{} ServerInfo;Deliver $info
 Check ((Last).Operation -ceq 'devices' -and $script:Role -ceq 'servers') 'Stale manager pairing role does not hijack normal server refresh'
 Deliver @{Devices=@();NextOffset=$null;ActiveDeviceCount=0;RevokedDeviceCount=0;ConfigRevision=3}
 # 0.22.0 B4: the detail page is split into three sections, so each capability is
 # asserted in the section that owns it instead of all three on one long page.
 Check ($script:Controls.ContainsKey('ServerTabdevices') -and $script:Controls.ContainsKey('ServerTabmaintenance') -and $script:Controls.ContainsKey('ServerTabrecords')) 'Authenticated detail publishes the three sections as tabs'
 Check ($script:Controls.ContainsKey('ServerOfflineInvite') -and -not $script:Controls.ContainsKey('ServerRecover')) 'Devices section owns the offline invitation entry'
 Shot '07-authenticated-devices'
 $script:DeployUI.Invite=[pscustomobject]@{InviteId='ffffffff-ffff-ffff-ffff-ffffffffffff';State='Open';Invite='PUBLIC-INVITE';ExpiresAtUtc=[DateTimeOffset]::UtcNow.AddHours(24).ToString('o')}
 Click ServerOfflineInvite
 Deliver @{ManagementServers=@($a);Servers=@($a);ContinueRuns=@()}
 Check ($script:ServerNavigationUI.View -ceq 'server-offline' -and $script:Controls.ContainsKey('ServerCreateInvite') -and $script:Controls.ContainsKey('ServerCopyInvite') -and $script:Controls.ContainsKey('ServerCancelInvite') -and $script:Controls.ContainsKey('ServerPairAuthorize') -and $script:Controls.ContainsKey('ServerOfflineInviteBack')) 'Offline invitation is an independent sub-view with two steps and four actions'
 Click ServerOfflineInviteBack
 Check ($script:ServerNavigationUI.View -ceq 'server-detail' -and $script:Controls.ContainsKey('ServerTabdevices')) 'Offline sub-view has its own return to the server detail'
 Click ServerTabmaintenance
 Check ($script:Controls.ContainsKey('ServerRecover') -and -not $script:Controls.ContainsKey('ServerOfflineInvite')) 'Maintenance section owns the recovery capability'
 Shot '08-maintenance-and-recovery'
 Click ServerTabrecords
 Check ($script:Controls.ContainsKey('ServerRecovery') -and -not $script:Controls.ContainsKey('ServerRecover')) 'Records section owns the recovery-data capability'
 Click ServerTabdevices
 Check ($script:Controls.ContainsKey('ServerOfflineInvite') -and -not $script:Controls.ContainsKey('ServerRecovery')) 'Returning to devices restores its capability and hides the others'
 ShowManagementRecovery -Mode Import
 Check ($script:Controls.ContainsKey('RecoveryImport') -and -not $script:Controls.ContainsKey('RecoveryExport')) 'Import-only recovery is available without an unrelated export form'
 Click RecoveryBack;Check ($script:DeployUI.Management.ServerId -ceq $serverA -and $script:ServerNavigationUI.View -ceq 'server-detail') 'Recovery returns to the original server detail'
 Check (@($script:AllRequests|Where-Object {$_.Action -notin @('LineProfiles','DeploymentDiscover','DeploymentGet','Nodes','ServerOperation')}).Count -eq 0) 'Navigation captures only permitted reads and exact existing-run resume'
 Check (@($script:AllRequests|Where-Object {$_.Action -eq 'ServerOperation' -and $_.Operation -notin @('server_info','devices')}).Count -eq 0) 'Navigation never authorizes, prepares transports, uninstalls or activates a line'
 VerifyNavigationScheduler $view $a $b
 $report=[ordered]@{Passed=$true;Suite='MaintenanceNavigation';Runtime=$PSVersionTable.PSVersion.ToString();Checks=$script:Checks.Count;Assertions=@($script:Checks);Screenshots=@($script:Shots);RealSchedulerQueueVerified=$true;NetworkRequests=0;WorkerLaunched=$false;ProductionStateRead=$false;FixtureOnly=$true}
 [IO.File]::WriteAllText((Join-Path $qa 'maintenance-navigation.json'),($report|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($true)))
 $report|ConvertTo-Json -Depth 8
}finally{if(Get-Variable PairIntakeTimer -Scope Script -ErrorAction SilentlyContinue){$script:PairIntakeTimer.Stop()};$script:Window.Close()}
