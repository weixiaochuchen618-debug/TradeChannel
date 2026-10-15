#requires -Version 5.1
[CmdletBinding()]
param([string]$SourceDirectory='',[string]$TestOutputDirectory='')
$ErrorActionPreference='Stop'
if([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw 'Run Test-016UI.ps1 with PowerShell -Sta.'}
if(-not $SourceDirectory){$SourceDirectory=Join-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) '..'}
$script:PackageRoot=[IO.Path]::GetFullPath($SourceDirectory).TrimEnd('\')
$testId=[guid]::NewGuid().ToString('N')
$script:Root=Join-Path ([IO.Path]::GetTempPath()) ('tc-ui-016-data-'+$testId)
$script:JobRoot=Join-Path $script:Root 'Product\jobs'
$qa=if($TestOutputDirectory){[IO.Path]::GetFullPath($TestOutputDirectory).TrimEnd('\')}else{Join-Path ([IO.Path]::GetTempPath()) ('tc-ui-016-evidence-'+$testId)}
$production=@([Environment]::GetFolderPath('CommonApplicationData'),$env:ProgramData,'C:\ProgramData')
function SafeLocalPath {
 param([string]$Path)
 if($Path -notmatch '^[A-Za-z]:[\\/]' -or $Path.Substring(2).Contains(':')){throw 'UI tests require absolute local disk paths.'}
 $full=[IO.Path]::GetFullPath($Path).TrimEnd('\');$cursor=$full
 foreach($blocked in $production){if($blocked){$p=[IO.Path]::GetFullPath($blocked).TrimEnd('\');if($full.Equals($p,[StringComparison]::OrdinalIgnoreCase) -or $full.StartsWith($p+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'UI tests block production ProgramData before access.'}}}
 while($cursor){
  if(Test-Path -LiteralPath $cursor){$item=Get-Item -LiteralPath $cursor -Force;if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'UI test paths cannot cross a reparse point.'}}
  $parent=[IO.Path]::GetDirectoryName($cursor);if($parent -eq $cursor){break};$cursor=$parent
 }
 return $full
}
function FixturePath {param([string]$Path) $p=SafeLocalPath $Path;if(-not $p.StartsWith($script:Root+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Fixture write escaped the disposable root.'};return $p}
$script:PackageRoot=SafeLocalPath $script:PackageRoot;$script:Root=SafeLocalPath $script:Root;$qa=SafeLocalPath $qa
if($qa -eq $script:PackageRoot -or $qa.StartsWith($script:PackageRoot+'\ui',[StringComparison]::OrdinalIgnoreCase) -or $qa.StartsWith($script:Root,[StringComparison]::OrdinalIgnoreCase)){throw 'Evidence output cannot replace source UI or disposable data.'}
if([IO.Directory]::Exists($script:Root)){throw 'UI test data root must be new.'}
$null=[IO.Directory]::CreateDirectory($script:Root);[IO.File]::WriteAllText((Join-Path $script:Root '.owned-ui-016'),$testId)
$null=[IO.Directory]::CreateDirectory($qa)
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$script:Smoke=$true;$script:ReadOnly=$false;$script:Pending=$null;$script:Job=$null;$script:Window=$null
$script:Controls=@{};$script:Requests=New-Object 'Collections.Generic.List[object]';$script:AllRequests=New-Object 'Collections.Generic.List[object]'
$script:Checks=New-Object 'Collections.Generic.List[string]';$script:Shots=New-Object 'Collections.Generic.List[object]';$script:DeniedActors=New-Object 'Collections.Generic.List[string]'
$script:LoadedSources=New-Object 'Collections.Generic.List[object]';$script:DialogCount=0;$script:DialogCallback=$null;$script:DialogContext=$null;$script:LastToast=''
$script:Ink='#15181D';$script:Text2='#4B5360';$script:Text3='#858C97';$script:Hair='#E6E8EB'
$script:Tone=@{ok=@{Fg='#15803D';Bg='#ECF8F0'};warn=@{Fg='#A15C07';Bg='#FDF5E8'};bad=@{Fg='#B42318';Bg='#FEF1F0'};info=@{Fg='#1D4ED8';Bg='#EEF3FE'};idle=@{Fg='#4B5360';Bg='#F2F3F5'}}
$actorNames=@('Start-Process','Stop-Process','Get-Process','Start-Job','Invoke-WebRequest','Invoke-RestMethod','Invoke-TCDeployPipe','Start-TCDeploySession','Set-TCDeployCredential','Get-TCDeploySession','Invoke-TCDeployOperation','Stop-TCDeploySession','Save-TCDeployCredential','Get-TCDeploySavedCredential','Observe-TCRuntime','Start-TCConnection','Stop-TCConnection','ChooseFile','ChooseSave','PollJob','RunWorker')
foreach($name in $actorNames){Set-Item -Path ('Function:script:'+$name) -Value {$script:DeniedActors.Add($MyInvocation.MyCommand.Name);throw ('Forbidden real actor: '+$MyInvocation.MyCommand.Name)}}
function CheckUI {param([bool]$Ok,[string]$Label) if(-not $Ok){throw ('016 UI assertion failed: '+$Label)};$script:Checks.Add($Label)}
function ReadSourceAst {
 param([string]$Relative)
 $path=SafeLocalPath (Join-Path $script:PackageRoot $Relative);$hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
 if(@($errors).Count){throw ('UI source has parser errors: '+$Relative)}
 $script:LoadedSources.Add([pscustomobject]@{File=$Relative;Path=$path;SHA256=$hash})
 return $ast
}
function ImportNamedPresentation {
 param([string]$Relative,[string[]]$Names)
 $ast=ReadSourceAst $Relative
 foreach($name in $Names){
  $nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)|Where-Object Name -eq $name)
  if($nodes.Count -ne 1){throw ('Missing real presentation function: '+$name)}
  $body=$nodes[0].Body.Extent.Text;Set-Item -Path ('Function:script:'+$name) -Value ([scriptblock]::Create($body.Substring(1,$body.Length-2)))
 }
}
function GuardModuleActors {
 param($Module)
 & $Module {param($denied,$names)
  $script:UI016Denied=$denied
  foreach($name in $names){Set-Item -Path ('Function:script:'+$name) -Value {$script:UI016Denied.Add($MyInvocation.MyCommand.Name);throw ('Forbidden module actor: '+$MyInvocation.MyCommand.Name)}}
 } $script:DeniedActors $actorNames
}
function PageHead {param([string]$Title,[string]$Description,[string]$Page)
 $script:Page=$Page;if(Get-Command SyncNavigationContext -ErrorAction SilentlyContinue){SyncNavigationContext $Page};$script:Controls=@{};$script:HostPanel.Children.Clear();$script:Window.FindName('Scroll').ScrollToTop()
 if($Title){AddC $script:HostPanel (T $Title 24 $script:Ink 'SemiBold')};if($Description){AddC $script:HostPanel (Margin (T $Description 13 $script:Text3) '0,4,0,22')}
}
function OpenDialog {param($Title,$Body,$Note,$Confirm='确定',$Action=$null,$Cancel='取消',$ConfirmStyle='Primary',$Context=$null)
 $script:DialogCount++;$script:DialogCallback=$Action;$script:DialogContext=$Context
 $script:Window.FindName('DialogTitle').Text=[string]$Title;$script:Window.FindName('DialogBody').Text=[string]$Body;$script:Window.FindName('DialogNote').Text=[string]$Note
 $script:Window.FindName('DialogConfirm').Content=$Confirm;$script:Window.FindName('DialogCancel').Content=$Cancel;$script:Window.FindName('Overlay').Visibility='Visible'
}
function CloseDialog {$script:Window.FindName('Overlay').Visibility='Collapsed';$script:DialogCallback=$null;$script:DialogContext=$null}
function ErrorDialog {param([string]$Message) $script:LastErrorDialog=$Message;OpenDialog '夹具中的错误提示' $Message '' '知道了' $null ''}
# The real Worker is never loaded. Only callbacks supplied by real UI functions
# enter this queue; tests explicitly deliver data, not an imagined worker result.
function StartJob {param([hashtable]$Request,[scriptblock]$Complete,[string]$Message='',[string]$Transition='',[switch]$Silent,[scriptblock]$Failed=$null,$CallbackContext=$null)
 if(-not $script:Smoke){throw 'Worker capture requires Smoke.'}
 $entry=[pscustomobject]@{Request=$Request.Clone();Complete=$Complete;Failed=$Failed;CallbackContext=$CallbackContext;Delivered=$false}
 $script:Requests.Add($entry);$script:AllRequests.Add($entry.Request)
}
function IsBusy {return $false}
function IsRunning {return [bool]$script:Overview.Running}
function IsProviderTag {param([string]$Tag) return ($Tag -like 'provider*')}
function Toast {param([string]$Text) $script:LastToast=$Text}
function ShowNodes {PageHead '线路（夹具目的地）' '只记录页面跳转，不连接。' 'nodes'}
function FetchNodes {StartJob @{Action='Nodes'} {} 'fixture read'}
function ShowHome {PageHead '当前连接（夹具）' '' 'home'}
function RefreshOverview {param([switch]$Silent) StartJob @{Action='Overview'} {} 'fixture read'}
function RunCheck {StartJob @{Action='CheckActive'} {} 'fixture request'}
function ShowConnectionRecovery {param([string]$Id,[string]$Message) StartJob @{Action='LineRecovery';Id=$Id} {} 'fixture destination'}
function ShowLinux {PageHead '历史技术诊断（夹具目的地）' '' 'setup'}
function ResumeLinux {param([string]$Id) StartJob @{Action='LinuxResumeFixture';Id=$Id} {} 'fixture destination'}
function StopIntakeTimer {if(Get-Variable PairIntakeTimer -Scope Script -ErrorAction SilentlyContinue){$script:PairIntakeTimer.Stop()}}
function ClickUI {
 param([string]$Id)
 $control=$script:Controls[$Id];CheckUI ($null -ne $control -and $control.IsEnabled) ('Enabled actual control '+$Id)
 $control.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)));StopIntakeTimer
}
function LastRequest {if(-not $script:Requests.Count){throw 'Expected a captured UI request.'};return $script:Requests[$script:Requests.Count-1].Request}
function DeliverUI {
 param($Data,[int]$Index=-1)
 if($Index -lt 0){$Index=$script:Requests.Count-1};$entry=$script:Requests[$Index]
 if($entry.Delivered){throw 'A UI callback may only be delivered once.'};$entry.Delivered=$true;& $entry.Complete $Data $entry.CallbackContext;StopIntakeTimer
}
function FailUI {param([string]$Message) $entry=$script:Requests[$script:Requests.Count-1];if(-not $entry.Failed){throw 'Expected a UI failure callback.'};$entry.Delivered=$true;& $entry.Failed $Message $entry.CallbackContext;StopIntakeTimer}
function Descendants {
 param([Windows.DependencyObject]$Node)
 if($null -eq $Node){return};$Node
 for($i=0;$i -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($Node);$i++){Descendants ([Windows.Media.VisualTreeHelper]::GetChild($Node,$i))}
}
function VisibleText {
 $script:Window.UpdateLayout()
 return (@(Descendants $script:HostPanel|Where-Object {$_ -is [Windows.Controls.TextBlock] -and $_.IsVisible}|ForEach-Object {$_.Text}) -join "`n")
}
function Shot {
 param([string]$Name,[string]$Focus='')
 StopIntakeTimer
 if($Focus){$script:Controls[$Focus].BringIntoView()}
 $script:Footer.Text='隔离 WPF · 夹具状态 · 不证明服务器部署或网络结果';$script:Window.FindName('FooterContext').Text='0.16.1 / SMOKE / FIXTURE'
 $script:Window.UpdateLayout();$null=$script:Window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Render)
 $content=$script:Window.Content;$width=[int]$content.ActualWidth;$height=[int]$content.ActualHeight
 CheckUI ($width -ge 990 -and $height -ge 670) ('Actual WPF dimensions '+$Name)
 $bitmap=New-Object Windows.Media.Imaging.RenderTargetBitmap($width,$height,96,96,[Windows.Media.PixelFormats]::Pbgra32);$bitmap.Render($content)
 $encoder=New-Object Windows.Media.Imaging.PngBitmapEncoder;$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
 $path=SafeLocalPath (Join-Path $qa ($Name+'.png'));$stream=[IO.File]::Open($path,[IO.FileMode]::Create)
 try{$encoder.Save($stream)}finally{$stream.Dispose()}
 CheckUI ((Get-Item -LiteralPath $path).Length -gt 10000) ('Nonempty WPF screenshot '+$Name)
 $script:Shots.Add([pscustomobject]@{Name=$Name;Path=$path;Width=$width;Height=$height;SHA256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash;Page=$script:Page;Role=$script:Role;FixtureOnly=$true})
}
function ResetUI {
 StopIntakeTimer;CloseDialog;$script:Requests.Clear();$script:DialogCount=0;$script:LastToast='';$script:LastErrorDialog=''
 if($script:DeployUI.PasswordControl){$script:DeployUI.PasswordControl.Clear()}
 $script:Controls=@{};$script:Nodes=@();$script:Step=0;$script:Role='client';$script:ReadOnly=$false
 $script:Wizard=@{Name='导入线路（夹具）';Path='';Programs=@();Dns='';UseProvider=$false;Endpoint='';InterfaceAlias='';Subnet='10.78.0.0/24';PlanPath='';RequestPath='';Address=''};$script:Inspection=$null;$script:ServerInspection=$null
 $script:ConnectionPreviewUI=$null;$script:LineProfileUI=$null
 $script:DeployUI=@{Intent='Auto';Screen='connect';Run=$null;Discovery=$null;Identity=$null;SessionRef=$null;SessionAttached=$false;Credential=$null;RememberCredential=$false;LastPoll=[DateTime]::MinValue;TrustShown=$null;ServerId=$null;Server=$null;Management=$null;DeviceResult=$null;Invite=$null;PairRequest=$null;EnrollmentId=$null;PendingManagement=$null;Reauth=$false;ChooseNetwork=$false;PollError='';ManagementMode=$false;CenterLoaded=$true;HistoryLoaded=$true;FormDraft=@{};PasswordControl=$null}
 $script:Overview=[pscustomobject]@{Running=$true;StateKey='Connected';NodeName='正在用的线路（夹具）';NinjaRunning=$false;ActiveLineId='fixture-current';ActiveProfileId='Udp';ManifestPath=(Join-Path $script:Root 'current-fixture.manifest');SessionPresent=$true;Exit='hk';SessionId='fixture-current-session';ConfigHash=('A'*64)}
}
function BaseRun {
 param([string]$Stage='Inspect',[string]$Status='WaitingUser')
 [pscustomobject]@{SchemaVersion=1;ExperienceVersion=1;RunId='11111111-2222-4333-8444-555555555555';ServerRecordId='aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';Name='测试目标（夹具）';Intent='Auto';Stage=$Stage;Status=$Status;Profiles=@();ProtocolPreparation=$null;CandidateNodeId=$null;CandidateManifestPath=$null;ClientRequest=$null;Plan=$null;Review=$null;DispatchIntent=$null;PendingOperationId=$null;LastError=$null;CloudRuleList=@();RecoveryRequired=$false;ProbeRecoveryRequired=$false;DeploymentCompleteness='Partial';MissingProtocols=@('Udp','Tcp');PartialUseAccepted=$false;ProfileProbeState='NotStarted';Recommendation=$null;SavedConnectionPreference=$null;PreferredProfileId=$null;PreferenceSource=$null;ProbePreparation=$null;ProbeProgress=$null;ProbeInterfaceIndex=0;ValidationProfiles=$null;AutoSavedAtUtc=$null;AttentionRequired=$false;AccessIssue=$null;VpnPort=51820;TcpPort=443;FixtureOnly=$true}
}
function RenderRun {param($Run) $script:DeployUI.Run=$Run;$script:DeployUI.Reauth=$false;$script:Role='deployment';ShowProductDeployment}
function WriteFixtureJson {
 param([string]$Path,$Value)
 $p=FixturePath $Path;Write-TCDJson $p $Value
}
function ReadyFixture {
 $id=[guid]::NewGuid().ToString('D');$dir=FixturePath (Join-Path $script:Root ('profiles\'+$id));$null=[IO.Directory]::CreateDirectory($dir)
 $engine=Join-Path $dir 'engine.fixture.bin';[IO.File]::WriteAllText($engine,'NOT AN EXECUTABLE: UI016 FIXTURE');$engineHash=(Get-FileHash -LiteralPath $engine -Algorithm SHA256).Hash
 $profiles=@();$manifests=@{};$bindings=@();$now=[DateTimeOffset]::UtcNow.AddSeconds(-5)
 foreach($mode in @('Udp','Tcp')){
  $cfg=Join-Path $dir ($mode+'.config.json');$probe=Join-Path $dir ($mode+'.probe.json');$mp=Join-Path $dir ($mode+'.manifest.json')
  WriteFixtureJson $cfg @{FixtureOnly=$true;Mode=$mode};WriteFixtureJson $probe @{FixtureOnly=$true;Mode=$mode;Purpose='No engine is executed'}
  $ch=(Get-FileHash -LiteralPath $cfg -Algorithm SHA256).Hash;$ph=(Get-FileHash -LiteralPath $probe -Algorithm SHA256).Hash
  $manifest=[pscustomobject]@{SchemaVersion=1;FixtureOnly=$true;TCLineId=$id;TCManagedNodeId=$id;TCProfileId=$mode;TCProfileRevision=1;SyntaxValidated=$true;CandidatePath=$cfg;ProbePath=$probe;EnginePath=$engine;CandidateSHA256=$ch;ProbeSHA256=$ph;EngineSHA256=$engineHash;ServerPublicKey=('S'*43+'=');ClientPublicKey=('C'*43+'=');ClientAddress='10.78.0.2/32';ServerEndpoint='192.0.2.10:51820';DeviceId='99999999-2222-4333-8444-555555555555';RequestId='88888888-2222-4333-8444-555555555555'}
  WriteFixtureJson $mp $manifest;$mh=(Get-FileHash -LiteralPath $mp -Algorithm SHA256).Hash
  $profile=[pscustomobject]@{Id=$mode;Mode=$mode;Revision=1;PreparationState='SyntaxValidated';ManifestPath=$mp;ManifestSHA256=$mh;CandidateSHA256=$ch;ProbeSHA256=$ph;EngineSHA256=$engineHash;EnginePath=$engine;Validation=$null;FixtureOnly=$true}
  $checks=@([pscustomobject]@{Name='AddressHttps';Status='Passed'},[pscustomobject]@{Name='DomainDnsHttps';Status='Passed'},[pscustomobject]@{Name='ExitConsistency';Status='Passed'})
  $raw=[pscustomobject]@{FixtureOnly=$true;Status='Passed';Code='CandidateReachabilityVerified';ForwardingPassed=$true;CleanupComplete=$true;OwnershipKnown=$true;Checks=$checks;CandidateHash=$ch;ManifestHash=$mh;EngineSHA256=$engineHash;ObservedExitIPv4='203.0.113.10';ExpectedExitIPv4='203.0.113.10';ExpectedExitSource='ServerVerifiedTlsTrace';NetworkFingerprint=('F'*64);CheckedAtUtc=$now.ToString('o');PathEvidence=@{Kind='BoundInterfaceObserved';Verified=$true;EligibleForRecommendation=$true;NetworkFingerprint=('F'*64)};Samples=@();Metrics=@{Planned=2;Attempted=2;Passed=2;Failed=0;TimedOut=0}}
  $profile.Validation=ConvertTo-TCProtocolEvidence -Result $raw -Profile $profile -NetworkContext $script:FixtureNetwork -Now $now
  $profiles+=,$profile;$manifests[$mode]=$manifest
  $bindings+=,[pscustomobject]@{ProfileId=$mode;BindingState='Prepared';ReasonCode='BindingsPrepared';ProfileRevision=1;CandidateSHA256=$ch;ManifestSHA256=$mh;BindingDigest=('E'*64);NextAction='None';Interfaces=@()}
 }
 # Real pure modules construct AND validate provenance against actual fixture
 # manifest/config hashes. This is UI input, not a backend auto-save assertion.
 $recommendation=Get-TCProtocolRecommendation -Profiles $profiles -LineId $id -NetworkContext $script:FixtureNetwork -Now $now
 CheckUI ($recommendation.Status -eq 'Recommended' -and (Test-TCProtocolRecommendationRecorded -Recommendation $recommendation -Profiles $profiles -RecordedAt $now)) 'Actual protocol module accepts fixture-bound recommendation provenance'
 $selected=@($profiles|Where-Object Id -eq $recommendation.RecommendedProfileId)[0]
 $saved=New-TCSavedConnectionPreference -LineId $id -Profile $selected -Manifest $manifests[$selected.Id] -Profiles $profiles -Recommendation $recommendation -NetworkContext $script:FixtureNetwork -LineRevision 1 -Now $now
 CheckUI (Test-TCSavedConnectionPreference -Preference $saved -LineId $id -Profile $selected -Manifest $manifests[$selected.Id] -Now $now) 'Actual saved-default validator reads fixture manifest identity and hashes'
 $line=[pscustomobject]@{LineId=$id;id=$id;Name='双连接已保存（夹具）';Revision=1;Profiles=$profiles;SavedConnectionPreference=$saved;Recommendation=$recommendation;PreferredProfileId=$selected.Id;PreferenceSource=$saved.Source;SourceManifestPath=$profiles[0].ManifestPath;manifestPath=$profiles[0].ManifestPath;DeploymentCompleteness='Complete'}
 $run=BaseRun 'ReadyInactive' 'Complete';$run.Name=$line.Name;$run.CandidateNodeId=$id;$run.CandidateManifestPath=$profiles[0].ManifestPath;$run.Profiles=$profiles;$run.DeploymentCompleteness='Complete';$run.MissingProtocols=@();$run.ProfileProbeState='Completed';$run.Recommendation=$recommendation;$run.SavedConnectionPreference=$saved;$run.PreferredProfileId=$selected.Id;$run.PreferenceSource=$saved.Source;$run.AutoSavedAtUtc=$now.ToString('o');$run.ValidationProfiles=[pscustomobject]@{Udp=$profiles[0].Validation;Tcp=$profiles[1].Validation};$run.ProbePreparation=@{State='Ready';Code='BindingsPrepared';Results=$bindings};$run.ProtocolPreparation=@{Udp=@{LocalPreparation='SyntaxValidated';ServerPreparation='Configured'};Tcp=@{LocalPreparation='SyntaxValidated';ServerPreparation='Configured'}}
 $script:Nodes=@($line);[pscustomobject]@{Run=$run;Line=$line;Selected=$selected;Manifests=$manifests}
}
function HistoryRow {
 param([string]$Kind,[string]$Guid,[bool]$Hidden=$false,[bool]$Protected=$false)
 [pscustomobject]@{SchemaVersion=1;Id=($Kind+':'+$Guid);SourceKind=$Kind;SourceId=$Guid;ServerRecordId='aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';ServerRecordIds=@('aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee');IdentityState='Active';Name='历史来源（夹具）';Operation='Inspect';Status='Complete';Stage='Inspect';UpdatedAtUtc=[DateTime]::UtcNow.ToString('o');AutoSavedAtUtc='';AccessIssue='';AttentionRequired=$false;IsPrepared=$false;Classification='History';NextAction='ViewHistory';Hidden=$Hidden;HiddenRequested=$Hidden;Archived=$Hidden;LegacyArchived=$Hidden;Protected=$Protected;CanClear=(-not $Protected);CanResume=$false;ProtectionReasons=$(if($Protected){@('CurrentConnectionReference')}else{@()});DataRetentionReasons=@()}
}
function SelectHistoryFilter {
 param([string]$ControlId,[string]$Tag)
 $item=@($script:Controls[$ControlId].Items|Where-Object {[string]$_.Tag -ceq $Tag})
 if($item.Count -ne 1){throw ('Expected actual filter item: '+$ControlId)}
 $script:Controls[$ControlId].SelectedItem=$item[0]
}

$passed=$false;$failure='';$protocolModule=$null;$baseOverview=''
try{
 ImportNamedPresentation 'TradeChannel.ps1' @('B','AddC','T','Stack','Card','Margin','Grid','Cell','ControlName','Btn','Icon','IconTile','Rule','KeyValue','Notice','SectionLabel','Field','Row','Pill')
 ImportNamedPresentation 'ui\Pages.ps1' @('TwoColumns','Tx','Head','Note')
 $shell=SafeLocalPath (Join-Path $script:PackageRoot 'ui\Shell.xaml');$script:LoadedSources.Add([pscustomobject]@{File='ui\Shell.xaml';Path=$shell;SHA256=(Get-FileHash -LiteralPath $shell -Algorithm SHA256).Hash})
 [xml]$xaml=Get-Content -LiteralPath $shell -Raw -Encoding UTF8;$reader=New-Object Xml.XmlNodeReader($xaml)
 try{$script:Window=[Windows.Markup.XamlReader]::Load($reader)}finally{$reader.Close()}
 $script:HostPanel=$script:Window.FindName('ContentHost');$script:Footer=$script:Window.FindName('FooterStatus')
 $script:Window.ShowInTaskbar=$false;$script:Window.ShowActivated=$false;$script:Window.Left=-16000;$script:Window.Top=-16000
 foreach($relative in @('ui\ConnectionProfilePages.ps1','ui\SetupPages.ps1','ui\DeploymentPages.ps1','ui\ServerPages.ps1','ui\PairingPages.ps1','ui\OperationHistoryPages.ps1','ui\DeploymentIdentityPages.ps1')){
  $null=ReadSourceAst $relative;. (Join-Path $script:PackageRoot $relative)
 }
 foreach($relative in @('DeploymentDecision.psm1','ProtocolSelection.psm1')){$null=ReadSourceAst $relative}
 $protocolModule=Import-Module (Join-Path $script:PackageRoot 'ProtocolSelection.psm1') -PassThru -DisableNameChecking
 $decisionModule=Import-Module (Join-Path $script:PackageRoot 'DeploymentDecision.psm1') -PassThru -DisableNameChecking
 GuardModuleActors $protocolModule;GuardModuleActors $decisionModule
 $script:FixtureNetwork=[pscustomobject]@{Status='Available';Fingerprint=('F'*64);FixtureOnly=$true}
 & $protocolModule {param($context)$script:UI016Network=$context;function script:Get-TCProtocolNetworkContext {return $script:UI016Network}} $script:FixtureNetwork
 $script:Window.FindName('DialogConfirm').Add_Click({$action=$script:DialogCallback;$context=$script:DialogContext;CloseDialog;if($action){& $action $context}})
 $script:Window.FindName('DialogCancel').Add_Click({CloseDialog})
 $script:Window.Show();ResetUI;$baseOverview=ConvertTo-Json -InputObject $script:Overview -Compress

 # Backend state and real WPF presentation share one disposable root.
 Import-Module (Join-Path $script:PackageRoot 'DeploymentStore.psm1') -DisableNameChecking
 Import-Module (Join-Path $script:PackageRoot 'OperationHistory.psm1') -DisableNameChecking
 Import-Module (Join-Path $script:PackageRoot 'DraftDisposition.psm1') -DisableNameChecking
 function ReadCenter {
  $c=Get-TCDeploymentCenter -Root $script:Root;$d=Get-TCDraftDisposition -Root $script:Root
  foreach($item in @($c.DraftItems)+@($c.ContinueItems)+@($c.AttentionItems)){
   $row=@(@($d.Records)+@($d.Servers)|Where-Object Id -ceq $item.Id)|Select-Object -First 1
   if($row){$item.CanDiscardDraft=$row.CanDiscardDraft;$item.DiscardBlockReason=$row.DiscardBlockReason}
  };return $c
 }
 function ReadDetail {param([string]$Id)
  $record=Get-TCOperationRecordDetail -Root $script:Root -Id $Id;$d=Get-TCDraftDisposition -Root $script:Root
  $row=@(@($d.Records)+@($d.Servers)|Where-Object Id -ceq $Id)|Select-Object -First 1
  if($row){$record.CanDiscardDraft=$row.CanDiscardDraft;$record.DiscardBlockReason=$row.DiscardBlockReason};return $record
 }
 $serverId=[guid]::NewGuid().ToString('D');$runId=[guid]::NewGuid().ToString('D');$legacyId=[guid]::NewGuid().ToString('D')
 $server=@{LocalRecordId=$serverId;RecordState='Active';Name='保存的服务器资料（夹具）';Connection=@{Host='192.0.2.10';Port=22;User='root';IdentityFile=''};RemoteOwnerId=$null;NodeId=$null;ServerPublicKey=$null;PinnedHostKey=$null;CredentialRef=$null;OwnershipState='Unverified';LinkedNodeIds=@();SourceJobIds=@();ArchivedTasks=@();CreatedAtUtc=[DateTime]::UtcNow.ToString('o')}
 WriteFixtureJson (Join-Path $script:Root 'servers\registry.json') @{SchemaVersion=1;Revision=1;Servers=@($server)}
 $run=@{SchemaVersion=1;RunId=$runId;Revision=1;Intent='Auto';Name='尚未开始的添加（夹具）';ServerRecordId=$serverId;Status='WaitingUser';Stage='PrepareAccess';CreatedAtUtc=[DateTime]::UtcNow.ToString('o');UpdatedAtUtc=[DateTime]::UtcNow.ToString('o');PendingOperationId=$null;DispatchIntent=$null;ClientRequest=$null;ClientResponse=$null;CandidateTransaction=$null;CandidateNodeId=$null;CandidateManifestPath=$null;RecoveryRequired=$false;ProbeRecoveryRequired=$false;AttentionRequired=$false;NetworkChanged=$false}
 $runPath=Join-Path $script:Root ('deployments\runs\'+$runId+'\state.json');WriteFixtureJson $runPath $run
 WriteFixtureJson (Join-Path $script:Root ('linux-jobs\'+$legacyId+'\job.json')) @{SchemaVersion=1;JobId=$legacyId;Operation='Apply';Name='Linux 新服务器（无关联夹具）';Connection=@{Host='192.0.2.50';Port=22;User='root'};CreatedAtUtc=[DateTime]::UtcNow.AddDays(-1).ToString('o')}
 WriteFixtureJson (Join-Path $script:Root ('linux-jobs\'+$legacyId+'\result.json')) @{SchemaVersion=1;JobId=$legacyId;Operation='Apply';Status='Failed';Stage='Backend';FinishedAtUtc=[DateTime]::UtcNow.ToString('o');Data=$null}
 $runKey='DeploymentRun:'+$runId;$legacyKey='LegacyLinuxJob:'+$legacyId;$sourceHash=(Get-FileHash $runPath).Hash

 ResetUI;$script:DeployUI.Center=ReadCenter;ShowSetupCenter;Shot '016-01-center-visible-tools'
 foreach($id in @('DeployAddLine','CentrePurchase','OpenMigration','SetupWinServer','CentreRecoveryImport','UnifiedOperationHistory')){CheckUI ($script:Controls.ContainsKey($id)) ('Visible named tool '+$id)}
 CheckUI (@($script:DeployUI.Center.DraftItems).Count -eq 1 -and $script:DeployUI.Center.DraftItems[0].Id -ceq $runKey) 'One addition is one draft, without its empty server duplicate'
 CheckUI ($script:Controls.DeploymentDrafts.Header -eq '已保存草稿（1）' -and -not $script:Controls.DeploymentDrafts.IsExpanded) 'Draft group has a clear count and starts folded'
 $legacyControl='CentreAction'+($legacyKey-replace '[^A-Za-z0-9]','');ClickUI $legacyControl
 CheckUI ((LastRequest).Action -eq 'OperationRecordDetail' -and (LastRequest).Id -ceq $legacyKey) 'Orphan legacy opens a read-only exact record instead of Linux resume'
 DeliverUI (ReadDetail $legacyKey);Shot '016-02-orphan-record'
 CheckUI (-not $script:Controls.ContainsKey('RecordNext') -and $script:Controls.ContainsKey('RecordAddNew') -and $script:Role -eq 'operation-record') 'No misleading continuation is offered for unidentified legacy work'
 ClickUI 'RecordBack';CheckUI ($script:Role -eq 'deployment-center') 'Read-only record returns to its deployment center origin'

 $script:DeployUI.DraftsExpanded=$true;ShowSetupCenter;Shot '016-03-draft-expanded' 'DeploymentDrafts'
 ClickUI ('DiscardDraft'+($runKey-replace '[^A-Za-z0-9]',''));CheckUI ((LastRequest).Action -eq 'DraftDiscardPreview' -and (LastRequest).Ids[0] -ceq $runKey) 'Draft abandonment first previews exactly one addition'
 $preview=New-TCDraftDiscardPreview -Root $script:Root -Ids @($runKey);DeliverUI $preview
 CheckUI ($script:Window.FindName('DialogConfirm').Content -eq '放弃本次添加' -and $script:Window.FindName('DialogNote').Text -like '*恢复填写*') 'Draft confirmation explains reversible local consequences'
 Shot '016-04-abandon-confirmation';$script:Window.FindName('DialogConfirm').RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
 CheckUI ((LastRequest).Action -eq 'DraftDiscardCommit' -and (LastRequest).PreviewToken -ceq $preview.PreviewToken -and -not (LastRequest).ContainsKey('Ids')) 'Confirmation commits only the state-bound backend preview'
 DeliverUI (Discard-TCDeploymentDraft -Root $script:Root -PreviewToken $preview.PreviewToken)
 $script:DeployUI.Center=ReadCenter;ShowSetupCenter
 CheckUI (@($script:DeployUI.Center.DraftItems).Count -eq 0 -and -not $script:Controls.ContainsKey('DeploymentDrafts')) 'Refresh after abandonment does not resurrect task or empty registration'
 $script:DeployUI.DraftHistory=Get-TCDraftDisposition -Root $script:Root;$script:DeployUI.HistoryRecords=@(Get-TCOperationHistory -Root $script:Root);ShowUnifiedOperationHistory;Shot '016-05-abandoned-history'
 $restoreControls=@($script:Controls.Keys|Where-Object {$_ -like 'RestoreDraft*'})
 CheckUI ($restoreControls.Count -eq 1) 'History offers one restore per abandoned addition, not a duplicate server row'
 CheckUI (@(GetFilteredOperationHistoryUI|Where-Object Id -ceq $runKey).Count -eq 0) 'Abandoned draft is not duplicated among normal operation-history rows'
 ClickUI $restoreControls[0];CheckUI ((LastRequest).Action -eq 'DraftRestore' -and (LastRequest).Id -ceq $runKey) 'Restore targets the exact original draft'
 DeliverUI (Restore-TCDeploymentDraft -Root $script:Root -Id $runKey)
 $script:DeployUI.Center=ReadCenter;ShowSetupCenter;Shot '016-06-restored-draft' 'DeploymentDrafts'
 CheckUI ($script:Role -eq 'deployment-center' -and $script:Controls.DeploymentDrafts.IsExpanded -and @($script:DeployUI.Center.DraftItems).Count -eq 1 -and (Get-FileHash $runPath).Hash -ceq $sourceHash) 'Restoring returns to expanded input with original run unchanged and no automatic deployment'

 # A detail result arriving after navigation must not seize the page.
 $script:Requests.Clear();ShowOperationRecordDetail $legacyKey;ShowHome;DeliverUI (ReadDetail $legacyKey)
 CheckUI ($script:Page -eq 'home') 'Late record read preserves the user current page'
 ShowSetupCenter;ShowOperationRecordDetail $legacyKey;DeliverUI (ReadDetail $legacyKey);$originalDetail=CaptureNavigationContext
 $script:Role='servers';$script:Page='setup';SetNavigationContext nodes server-detail $serverId;ReturnNavigationContext $originalDetail;DeliverUI (ReadDetail $legacyKey)
 ClickUI 'RecordBack';CheckUI ($script:Role -eq 'deployment-center') 'Returning from server to record preserves the record original parent instead of forming a navigation loop'
 ShowSetupCenter;$item=@($script:DeployUI.Center.DraftItems)[0];$script:Requests.Clear();InvokeDeploymentCenterAction $item;ShowHome;DeliverUI (ReadDetail $runKey)
 CheckUI ($script:Page -eq 'home' -and $script:Requests.Count -eq 1) 'Late refreshed entry cannot start preparation after user leaves'
 ShowSetupCenter;$a=CaptureNavigationContext;ShowHome;$null=CaptureNavigationContext;ShowSetupCenter
 CheckUI (-not (TestNavigationContext $a)) 'Leaving and returning to same page invalidates old continuation context'
 ShowUnifiedOperationHistory;RestoreDeploymentDraftUI $runKey;ShowHome;DeliverUI @{Restored=$true}
 CheckUI ($script:Page -eq 'home') 'Late restore completion invalidates caches without stealing the current page'

 # The stored preview becomes stale if execution progressed before confirmation.
 ShowSetupCenter;DiscardDeploymentDraftUI $runKey;$p=New-TCDraftDiscardPreview -Root $script:Root -Ids @($runKey);DeliverUI $p
 $run.Status='OutcomeUnknown';$run.RecoveryRequired=$true;WriteFixtureJson $runPath $run
 $script:Window.FindName('DialogConfirm').RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
 $rejected=$false;try{$null=Discard-TCDeploymentDraft -Root $script:Root -PreviewToken $p.PreviewToken}catch{$rejected=$true;FailUI $_.Exception.Message}
 CheckUI ($rejected -and -not (@((Get-TCDraftDisposition -Root $script:Root).Records|Where-Object Id -ceq $runKey)[0].Discarded)) 'Changed deployment outcome rejects stale abandon confirmation without hiding it'
 CloseDialog

 # Actual backend deletion and WPF controls share the isolated fixture.
 function RefreshRemovalHistory {
  $script:DeployUI.HistoryRecords=@(Get-TCOperationHistory -Root $script:Root -IncludeHidden -IncludeServerRecords);$script:DeployUI.HistoryLoaded=$true;ShowUnifiedOperationHistory
 }
 function ConfirmRemovalPreview {
  $req=LastRequest;CheckUI ($req.Action -eq 'RecordDeletePreview' -and @($req.Ids).Count -gt 0) 'Actual control supplies a nonempty exact deletion scope'
  $p=New-TCRecordDeletePreview -Root $script:Root -Ids @($req.Ids);DeliverUI $p
  return $p
 }
 function CommitRemovalPreview {param($Preview)
  $script:Window.FindName('DialogConfirm').RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
  CheckUI ((LastRequest).Action -eq 'RecordDeleteCommit' -and (LastRequest).PreviewToken -ceq $Preview.PreviewToken -and -not (LastRequest).ContainsKey('Ids')) 'Actual confirmation submits only its sealed token'
  DeliverUI (Remove-TCDisplayRecord -Root $script:Root -PreviewToken $Preview.PreviewToken)
 }
 $legacy2Id=[guid]::NewGuid().ToString('D');$legacy2Key='LegacyLinuxJob:'+$legacy2Id
 WriteFixtureJson (Join-Path $script:Root ('linux-jobs\'+$legacy2Id+'\job.json')) @{SchemaVersion=1;JobId=$legacy2Id;Operation='Apply';Name='Linux 新服务器 2（夹具）';CreatedAtUtc=[DateTime]::UtcNow.ToString('o')}
 WriteFixtureJson (Join-Path $script:Root ('linux-jobs\'+$legacy2Id+'\result.json')) @{SchemaVersion=1;JobId=$legacy2Id;Operation='Apply';Status='Failed';Stage='Backend';FinishedAtUtc=[DateTime]::UtcNow.ToString('o')}
 $standalone=$server|ConvertTo-Json -Depth 8|ConvertFrom-Json;$standalone.LocalRecordId=[guid]::NewGuid().ToString('D');$standalone.Name='乾龙云线路（独立登记夹具）';$standaloneKey='ServerRecord:'+$standalone.LocalRecordId
 WriteFixtureJson (Join-Path $script:Root 'servers\registry.json') @{SchemaVersion=1;Revision=2;Servers=@($server,$standalone)}
 $keptPaths=@($runPath,(Join-Path $script:Root 'servers\registry.json'),(Join-Path $script:Root ('linux-jobs\'+$legacyId+'\result.json')))
 $keptHashes=@($keptPaths|ForEach-Object {(Get-FileHash -LiteralPath $_).Hash})
 ResetUI;$script:DeployUI.Center=ReadCenter;ShowSetupCenter
 ClickUI ('CentreDelete'+($legacyKey-replace '[^A-Za-z0-9]',''));$p=ConfirmRemovalPreview
 CheckUI ($p.EligibleCount -eq 1 -and $script:Window.FindName('DialogNote').Text -like '*线路和密钥保留*') 'Legacy center row has a usable single delete with accurate retained-data explanation'
 Shot '0161-01-delete-confirmation'
 $count=$script:Requests.Count;$script:Window.FindName('DialogCancel').RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
 CheckUI ($script:Requests.Count -eq $count -and -not (ReadDetail $legacyKey).Deleted) 'Cancelling center deletion leaves the real record visible'
 ClickUI ('CentreDelete'+($legacyKey-replace '[^A-Za-z0-9]',''));$p=ConfirmRemovalPreview;CommitRemovalPreview $p
 $script:DeployUI.Center=ReadCenter;ShowSetupCenter
 CheckUI (-not $script:Controls.ContainsKey('CentreDelete'+($legacyKey-replace '[^A-Za-z0-9]','')) -and $script:Controls.ContainsKey('CentreDelete'+($legacy2Key-replace '[^A-Za-z0-9]',''))) 'Single deletion removes only the chosen Linux card after a fresh center read'
 RefreshRemovalHistory;SelectHistoryFilter 'HistorySourceFilter' 'LegacyLinuxJob';ClickUI 'ApplyHistoryFilters';ClickUI 'SelectAllHistory'
 CheckUI ($script:DeployUI.HistorySelectedIds.Count -eq 1 -and $script:DeployUI.HistorySelectedIds[0] -ceq $legacy2Key) 'Select all current results excludes filtered preparations and already deleted rows'
 SelectHistoryFilter 'HistorySourceFilter' '';ClickUI 'ApplyHistoryFilters'
 CheckUI ($script:DeployUI.HistorySelectedIds.Count -eq 0 -and -not $script:Controls.DeleteSelectedRecords.IsEnabled) 'Changing filters clears previous selections'
 foreach($id in @($runKey,$legacy2Key)){$pick='HistoryPick'+($id-replace '[^A-Za-z0-9]','');$script:Controls[$pick].IsChecked=$true;ClickUI $pick}
 CheckUI ($script:Controls.DeleteSelectedRecords.Content -eq '删除所选（2）') 'Multiple real checkboxes report the exact selected count'
 Shot '0161-02-history-multiselect';ClickUI 'DeleteSelectedRecords';$p=ConfirmRemovalPreview
 CheckUI ($p.EligibleCount -eq 2 -and $standaloneKey -notin $p.SelectedIds) 'Batch confirmation includes checked preparation and Linux history only'
 CommitRemovalPreview $p;RefreshRemovalHistory
 CheckUI ($script:DeployUI.HistoryVisibleRecords.Count -eq 1 -and $script:DeployUI.HistoryVisibleRecords[0].Id -ceq $standaloneKey) 'After batch deletion only the unselected standalone server record remains'
 CheckUI (@((ReadCenter).DraftItems|Where-Object ServerRecordId -ceq $serverId).Count -eq 0) 'Deleted preparation does not create a replacement empty server card'
 $script:Controls.ShowClearedHistory.IsChecked=$true;ClickUI 'ShowClearedHistory'
 CheckUI (@($script:Controls.Keys|Where-Object {$_ -like 'RestoreHistory*'}).Count -eq 3) 'Deleted-record switch exposes all three exact restore entries'
 Shot '0161-03-deleted-records';ClickUI ('RestoreHistory'+($legacyKey-replace '[^A-Za-z0-9]',''))
 CheckUI ((LastRequest).Action -eq 'RecordRestore' -and (LastRequest).Id -ceq $legacyKey) 'Restore button targets one original deleted Linux record'
 DeliverUI (Restore-TCDisplayRecord -Root $script:Root -Id $legacyKey);RefreshRemovalHistory
 CheckUI (-not (ReadDetail $legacyKey).Deleted -and (ReadDetail $runKey).Deleted) 'Restoring one row leaves the other deleted records untouched'
 ClickUI ('ViewHistory'+($runKey-replace '[^A-Za-z0-9]',''));DeliverUI (ReadDetail $runKey)
 CheckUI ($script:Controls.ContainsKey('RecordRestoreHistory') -and -not $script:Controls.ContainsKey('RecordNext') -and -not $script:Controls.ContainsKey('RecordAddNew')) 'Deleted detail offers restore without continuing or restarting work'
 ClickUI 'RecordBack';RefreshRemovalHistory;ClickUI 'SelectAllHistory'
 CheckUI ($script:DeployUI.HistorySelectedIds.Count -eq 2 -and $standaloneKey -in $script:DeployUI.HistorySelectedIds -and $legacyKey -in $script:DeployUI.HistorySelectedIds) 'Full selection includes an independent server and all remaining normal records'
 ClickUI 'DeleteSelectedRecords';$p=ConfirmRemovalPreview;CommitRemovalPreview $p
 $script:DeployUI.HistoryIncludeHidden=$false;RefreshRemovalHistory
 CheckUI ($script:DeployUI.HistoryVisibleRecords.Count -eq 0 -and $script:Controls.ContainsKey('ShowClearedHistory') -and -not $script:Controls.SelectAllHistory.IsEnabled) 'Deleting all current results leaves a recoverable empty list with no enabled destructive action'
 Shot '0161-04-empty-history'
 $script:Controls.ShowClearedHistory.IsChecked=$true;ClickUI 'ShowClearedHistory'
 CheckUI ($script:Controls.ContainsKey('RestoreHistory'+($standaloneKey-replace '[^A-Za-z0-9]',''))) 'Standalone server deletion also has a recovery entry'
 ClickUI ('RestoreHistory'+($standaloneKey-replace '[^A-Za-z0-9]',''));ShowHome;DeliverUI (Restore-TCDisplayRecord -Root $script:Root -Id $standaloneKey)
 CheckUI ($script:Page -eq 'home') 'Late record restoration invalidates lists without stealing the current page'
 RefreshRemovalHistory;$count=$script:DialogCount;DeleteOperationRecordsUI -Ids @($standaloneKey);$req=LastRequest;ShowHome
 DeliverUI (New-TCRecordDeletePreview -Root $script:Root -Ids @($req.Ids))
 CheckUI ($script:Page -eq 'home' -and $script:DialogCount -eq $count) 'Late delete preview cannot open a confirmation on another page'
 $script:ReadOnly=$true;RefreshRemovalHistory;$count=$script:Requests.Count;DeleteOperationRecordsUI -Ids @($standaloneKey)
 CheckUI (-not $script:Controls.SelectAllHistory.IsEnabled -and -not $script:Controls['DeleteHistory'+($standaloneKey-replace '[^A-Za-z0-9]','')].IsEnabled -and $script:Requests.Count -eq $count) 'Read-only UI disables record mutations and direct handlers dispatch nothing'
 $script:ReadOnly=$false
 RefreshRemovalHistory;$count=$script:DialogCount;RestoreOperationHistoryUI $standaloneKey;ShowHome;FailUI '[TC:Busy] fixture late failure'
 CheckUI ($script:Page -eq 'home' -and $script:DialogCount -eq $count) 'Late record mutation failure does not open a dialog over another page'
 CheckUI ((@($keptPaths|ForEach-Object {(Get-FileHash -LiteralPath $_).Hash}) -join ',') -ceq ($keptHashes -join ',')) 'Single batch all-delete and recovery preserve original run server and legacy result bytes'
 # Abandoned additions participate in the same selection and deletion scope.
 $run.Status='WaitingUser';$run.Stage='PrepareAccess';$run.RecoveryRequired=$false;WriteFixtureJson $runPath $run
 $p=New-TCDraftDiscardPreview -Root $script:Root -Ids @($runKey);$null=Discard-TCDeploymentDraft -Root $script:Root -PreviewToken $p.PreviewToken
 $script:DeployUI.HistoryIncludeHidden=$false;RefreshRemovalHistory
 CheckUI ($script:Controls.ContainsKey('DeleteHistory'+($runKey-replace '[^A-Za-z0-9]','')) -and $script:Controls.ContainsKey('RestoreDraft'+($runKey-replace '[^A-Za-z0-9]',''))) 'Abandoned group offers both record deletion and explicit restore-filling'
 SelectHistoryFilter 'HistorySourceFilter' 'DeploymentRun';ClickUI 'ApplyHistoryFilters';ClickUI 'SelectAllHistory';ClickUI 'DeleteSelectedRecords';$p=ConfirmRemovalPreview;CommitRemovalPreview $p;RefreshRemovalHistory
 CheckUI ($script:DeployUI.HistoryVisibleRecords.Count -eq 0 -and -not $script:Controls.ContainsKey('RestoreDraft'+($runKey-replace '[^A-Za-z0-9]',''))) 'Deleting abandoned record removes it from the lower group as well'
 $script:Controls.ShowClearedHistory.IsChecked=$true;ClickUI 'ShowClearedHistory';ClickUI ('RestoreHistory'+($runKey-replace '[^A-Za-z0-9]',''))
 DeliverUI (Restore-TCDisplayRecord -Root $script:Root -Id $runKey);RefreshRemovalHistory
 CheckUI ((ReadDetail $runKey).Discarded -and $script:Controls.ContainsKey('RestoreDraft'+($runKey-replace '[^A-Za-z0-9]',''))) 'Record restore returns an abandoned draft to its original group without automatically resuming it'
 SelectHistoryFilter 'HistorySourceFilter' '';ClickUI 'ApplyHistoryFilters'
 CheckUI ($script:Controls.SelectAllHistory.Content -eq '全选当前结果' -and $script:Controls.ShowClearedHistory.Content -eq '显示已删除记录') 'History management entry uses direct delete selection and restore wording'
 ClickUI 'HistoryBack';ClickUI 'OpenMigration';CheckUI ($script:Role -eq 'migration') 'Migration receives its own stable role';ClickUI 'MigrationBack'
 CheckUI ($script:Role -eq 'deployment-center') 'Migration returns to the deployment center'
 ClickUI 'CentrePurchase';CheckUI ($script:Role -eq 'purchase' -and $script:Controls.ContainsKey('PurchaseReturn')) 'Visible purchase tool opens practical preparation instructions'
 ShowSetupCenter;ClickUI 'CentreRecoveryImport'
 CheckUI ($script:DeployUI.RecoveryMode -eq 'Import' -and (CaptureNavigationContext).Section -eq 'setup' -and -not $script:Controls.ContainsKey('RecoveryExport')) 'Recovery import keeps deployment origin and exposes only import scope'
 ClickUI 'RecoveryBack';CheckUI ($script:Role -eq 'deployment-center') 'Recovery tool returns to its actual origin'

 # The visible material picker routes existing configurations to the original
 # import wizard. Dummy bytes are never parsed here: ImportNode owns validation.
 $blockedFilePicker=${function:ChooseFile}
 Set-Item Function:script:ChooseFile {param([string]$Title,[string]$Filter)$script:FixturePickerFilter=$Filter;return $script:FixturePickerPath}
 try{
  foreach($extension in @('.conf','.ZIP')){
   $config=FixturePath (Join-Path $script:Root ('existing-config'+$extension));$stream=[IO.File]::Create($config);try{$stream.SetLength(1MB+32)}finally{$stream.Dispose()}
   ResetUI;$script:FixturePickerPath=$config;ShowSetupCenter;ClickUI 'OpenConnectionMaterial'
   CheckUI ($script:FixturePickerFilter -like '*;*.zip;*' -and $script:Role -ceq 'client' -and $script:Step -eq 2 -and $script:Wizard.Path -ceq $config -and (LastRequest).Action -ceq 'InspectClient' -and -not $script:LastErrorDialog) ('Visible picker routes existing '+$extension+' above handoff limit to its exact import path')
   DeliverUI @{NinjaTraderPaths=@('C:\Fixture\NinjaTrader.exe');DirectDnsIPv4=@('192.0.2.53');RegisteredProviders=@()}
   CheckUI ($script:Step -eq 2 -and $script:Controls.FieldPath.Text -ceq $config -and $script:Wizard.Dns -ceq '192.0.2.53') ('Client inspection preserves the selected '+$extension+' configuration step')
   ClickUI 'WizardNext';ClickUI 'WizardNext'
   CheckUI ((LastRequest).Action -ceq 'ImportNode' -and (LastRequest).Path -ceq $config) ('Existing '+$extension+' is passed unchanged to backend validation only after explicit save')
  }
  $handoff=FixturePath (Join-Path $script:Root 'oversized-handoff.json');[IO.File]::WriteAllText($handoff,('x'*(1MB+32)))
  ResetUI;$script:FixturePickerPath=$handoff;ShowSetupCenter;ClickUI 'OpenConnectionMaterial'
  CheckUI ($script:Requests.Count -eq 0 -and $script:LastErrorDialog -like '*超过允许大小*' -and $script:Role -ceq 'deployment-center') 'Handoff JSON retains its size limit before parsing or dispatch'
 }finally{Set-Item Function:script:ChooseFile $blockedFilePicker}
 ResetUI;ShowSetupCenter;BeginWizard 'client';ShowHome
 DeliverUI @{NinjaTraderPaths=@('C:\Fixture\stale.exe');DirectDnsIPv4=@('192.0.2.54')}
 CheckUI ($script:Page -ceq 'home' -and -not $script:Inspection -and -not $script:Wizard.Dns) 'Late client inspection cannot reopen a departed wizard or change its fields'
 ResetUI;ShowSetupCenter;ClickUI 'SetupWinServer';ShowHome
 DeliverUI @{OS=@{Supported=$true};Friendly='fixture';ManagementDefaultRoutes=@(@{DestinationPrefix='0.0.0.0/0';InterfaceIndex=7});Adapters=@(@{InterfaceIndex=7;Name='FixtureEthernet'})}
 CheckUI ($script:Page -ceq 'home' -and -not $script:ServerInspection -and -not $script:Wizard.InterfaceAlias) 'Late server inspection cannot reopen a departed wizard or change its fields'
 ResetUI;ShowSetupCenter;ClickUI 'SetupWinServer'
 DeliverUI @{OS=@{Supported=$true};Friendly='fixture';ManagementDefaultRoutes=@(@{DestinationPrefix='0.0.0.0/0';InterfaceIndex=7});Adapters=@(@{InterfaceIndex=7;Name='FixtureEthernet'})}
 CheckUI ($script:Role -ceq 'server' -and $script:Step -eq 1 -and $script:Wizard.InterfaceAlias -ceq 'FixtureEthernet' -and $script:Controls.ContainsKey('WizardNext')) 'Current server inspection still advances its own wizard and supplies detected interface'
 ResetUI;ShowSetupCenter;BeginWizard 'client';ShowHome;FailUI 'fixture late inspection failure'
 CheckUI ($script:Page -ceq 'home' -and -not $script:LastErrorDialog) 'Late inspection failure does not interrupt another page'

 ResetUI;$script:Window.Width=1000;$script:Window.Height=680;$script:DeployUI.Center=ReadCenter;ShowSetupCenter;Shot '016-07-minimum-center'
 foreach($id in @('DeployAddLine','CentrePurchase','OpenMigration','SetupWinServer','CentreRecoveryImport')){
  $c=$script:Controls[$id];$c.BringIntoView();$script:Window.UpdateLayout();$p=$c.TranslatePoint((New-Object Windows.Point(0,0)),$script:Window.Content)
  CheckUI ($c.ActualWidth -gt 40 -and $p.X -ge 0 -and $p.X+$c.ActualWidth -le $script:Window.Content.ActualWidth) ('Minimum width reaches '+$id)
 }
 CheckUI ((ConvertTo-Json -InputObject $script:Overview -Compress) -ceq $baseOverview -and $script:DeniedActors.Count -eq 0 -and -not [IO.Directory]::Exists($script:JobRoot)) 'Whole local journey preserves current-session fixture and invokes no process/network actor'
 foreach($source in $script:LoadedSources){CheckUI ((Get-FileHash -LiteralPath $source.Path -Algorithm SHA256).Hash -ceq $source.SHA256) ('Tested source stayed unchanged: '+$source.File)}
 $passed=$true

}catch{$failure=$_.Exception.Message;throw}
finally{
 StopIntakeTimer;if($script:Window){$script:Window.Close()}
 $requestSummary=@($script:AllRequests|ForEach-Object {[ordered]@{Action=$_.Action;Command=$_.Command;Operation=$_.Operation;RunId=$_.RunId;ServerId=$_.ServerId}})
 $summary=[ordered]@{Passed=$passed;Suite='UI-0.16.1';Checks=$script:Checks.Count;Assertions=@($script:Checks.ToArray());Failure=$failure;LastErrorDialog=$script:LastErrorDialog;WpfRendered=($script:Shots.Count -gt 0);Screenshots=@($script:Shots.ToArray());SourceVersions=@($script:LoadedSources|ForEach-Object {[ordered]@{File=$_.File;SHA256=$_.SHA256}});Requests=$requestSummary;WorkerLaunched=$false;RealActorAttempts=@($script:DeniedActors.ToArray());ProductionAccess=$false;FixtureOnly=$true;BackendAutoSaveVerified=$false;RemoteSignaturesVerified=$false;NetworkMeasured=$false;OutputDirectory=$qa;PowerShellVersion=$PSVersionTable.PSVersion.ToString()}
 [IO.File]::WriteAllText((Join-Path $qa 'ui-016-result.json'),(ConvertTo-Json -InputObject $summary -Depth 12),(New-Object Text.UTF8Encoding($true)))
 $cleanupRoot=SafeLocalPath $script:Root;$marker=Join-Path $cleanupRoot '.owned-ui-016'
 if($cleanupRoot -cne (Join-Path ([IO.Path]::GetTempPath()) ('tc-ui-016-data-'+$testId)) -or -not [IO.File]::Exists($marker) -or [IO.File]::ReadAllText($marker) -cne $testId){throw 'UI fixture cleanup ownership check failed.'}
 Remove-Item -LiteralPath $cleanupRoot -Recurse -Force -ErrorAction Stop
 if($passed){[pscustomobject]@{Passed=$true;Checks=$script:Checks.Count;Screenshots=$script:Shots.Count;WpfRendered=$true;WorkerLaunched=$false;FixtureOnly=$true;BackendAutoSaveVerified=$false;OutputDirectory=$qa}|ConvertTo-Json}
}
