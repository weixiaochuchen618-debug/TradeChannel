#requires -Version 5.1
[CmdletBinding()]
param([string]$SourceDirectory='',[string]$TestOutputDirectory='')
$ErrorActionPreference='Stop'
if([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw 'Run Test-015UI.ps1 with PowerShell -Sta.'}
if(-not $SourceDirectory){$SourceDirectory=Join-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) '..'}
$script:PackageRoot=[IO.Path]::GetFullPath($SourceDirectory).TrimEnd('\')
$testId=[guid]::NewGuid().ToString('N')
$script:Root=Join-Path ([IO.Path]::GetTempPath()) ('tc-ui-015-data-'+$testId)
$script:JobRoot=Join-Path $script:Root 'Product\jobs'
$qa=if($TestOutputDirectory){[IO.Path]::GetFullPath($TestOutputDirectory).TrimEnd('\')}else{Join-Path ([IO.Path]::GetTempPath()) ('tc-ui-015-evidence-'+$testId)}
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
$null=[IO.Directory]::CreateDirectory($script:Root);[IO.File]::WriteAllText((Join-Path $script:Root '.owned-ui-015'),$testId)
$null=[IO.Directory]::CreateDirectory($qa)
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$script:Smoke=$true;$script:ReadOnly=$false;$script:Pending=$null;$script:Job=$null;$script:Window=$null
$script:Controls=@{};$script:Requests=New-Object 'Collections.Generic.List[object]';$script:AllRequests=New-Object 'Collections.Generic.List[object]'
$script:Checks=New-Object 'Collections.Generic.List[string]';$script:Shots=New-Object 'Collections.Generic.List[object]';$script:DeniedActors=New-Object 'Collections.Generic.List[string]'
$script:LoadedSources=New-Object 'Collections.Generic.List[object]';$script:DialogCount=0;$script:DialogCallback=$null;$script:DialogContext=$null;$script:LastToast=''
$script:Ink='#15181D';$script:Text2='#4B5360';$script:Text3='#858C97';$script:Hair='#E6E8EB'
$script:Tone=@{ok=@{Fg='#15803D';Bg='#ECF8F0';Dot='#22A55B'};warn=@{Fg='#A15C07';Bg='#FDF5E8';Dot='#E19A1D'};bad=@{Fg='#B42318';Bg='#FEF1F0';Dot='#E5484D'};info=@{Fg='#1D4ED8';Bg='#EEF3FE';Dot='#3B6FF6'};idle=@{Fg='#4B5360';Bg='#F2F3F5';Dot='#A9AFB8'}}
$actorNames=@('Start-Process','Stop-Process','Get-Process','Start-Job','Invoke-WebRequest','Invoke-RestMethod','Invoke-TCDeployPipe','Start-TCDeploySession','Set-TCDeployCredential','Get-TCDeploySession','Invoke-TCDeployOperation','Stop-TCDeploySession','Save-TCDeployCredential','Get-TCDeploySavedCredential','Observe-TCRuntime','Start-TCConnection','Stop-TCConnection','ChooseFile','ChooseSave','PollJob','RunWorker')
foreach($name in $actorNames){Set-Item -Path ('Function:script:'+$name) -Value {$script:DeniedActors.Add($MyInvocation.MyCommand.Name);throw ('Forbidden real actor: '+$MyInvocation.MyCommand.Name)}}
function CheckUI {param([bool]$Ok,[string]$Label) if(-not $Ok){throw ('015 UI assertion failed: '+$Label)};$script:Checks.Add($Label)}
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
  $script:UI015Denied=$denied
  foreach($name in $names){Set-Item -Path ('Function:script:'+$name) -Value {$script:UI015Denied.Add($MyInvocation.MyCommand.Name);throw ('Forbidden module actor: '+$MyInvocation.MyCommand.Name)}}
 } $script:DeniedActors $actorNames
}
function PageHead {param([string]$Title,[string]$Description,[string]$Page)
 $script:Page=$Page;$script:Controls=@{};$script:HostPanel.Children.Clear();$script:Window.FindName('Scroll').ScrollToTop()
 if($Title){AddC $script:HostPanel (T $Title 24 $script:Ink 'SemiBold')};if($Description){AddC $script:HostPanel (Margin (T $Description 13 $script:Text3) '0,4,0,22')}
}
function OpenDialog {param($Title,$Body,$Note,$Confirm='确定',$Action=$null,$Cancel='取消',$ConfirmStyle='Primary',$Context=$null,[switch]$SafeDefault)
 $script:DialogCount++;$script:DialogCallback=$Action;$script:DialogContext=$Context
 $script:Window.FindName('DialogTitle').Text=[string]$Title;$script:Window.FindName('DialogBody').Text=[string]$Body;$script:Window.FindName('DialogNote').Text=[string]$Note
 $script:Window.FindName('DialogConfirm').Content=$Confirm;$script:Window.FindName('DialogCancel').Content=$Cancel;$script:Window.FindName('Overlay').Visibility='Visible'
}
function CloseDialog {$script:Window.FindName('Overlay').Visibility='Collapsed';$script:DialogCallback=$null;$script:DialogContext=$null}
function ErrorDialog {param([string]$Message) $script:LastErrorDialog=$Message;OpenDialog '夹具中的错误提示' $Message '' '知道了' $null ''}
# The real Worker is never loaded. Only callbacks supplied by real UI functions
# enter this queue; tests explicitly deliver data, not an imagined worker result.
function StartJob {param([hashtable]$Request,[scriptblock]$Complete,[string]$Message='',[string]$Transition='',[switch]$Silent,[scriptblock]$Failed=$null,$CallbackContext=$null,[scriptblock]$Finalized=$null)
 if(-not $script:Smoke){throw 'Worker capture requires Smoke.'}
 $entry=[pscustomobject]@{Request=$Request.Clone();Complete=$Complete;Failed=$Failed;CallbackContext=$CallbackContext;Finalized=$Finalized;Delivered=$false}
 $script:Requests.Add($entry);$script:AllRequests.Add($entry.Request)
}
function IsBusy {return $false}
function IsRunning {return [bool]$script:Overview.Running}
function IsProviderTag {param([string]$Tag) return ($Tag -like 'provider*')}
function Toast {param([string]$Text) $script:LastToast=$Text}
if(-not (Get-Command CopyText -ErrorAction SilentlyContinue)){function script:CopyText {param([string]$Text,[string]$Done='已复制')$script:LastCopiedText=$Text;Toast $Done;$true}}
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
 if($entry.Delivered){throw 'A UI callback may only be delivered once.'};$entry.Delivered=$true;& $entry.Complete $Data $entry.CallbackContext
 if($entry.Finalized){& $entry.Finalized @{Status='Completed'} $entry.CallbackContext};StopIntakeTimer
}
function FailUI {param([string]$Message) $entry=$script:Requests[$script:Requests.Count-1];if($entry.Delivered -or -not $entry.Failed){throw 'Expected an undelivered UI failure callback.'};$entry.Delivered=$true;& $entry.Failed $Message $entry.CallbackContext
 if($entry.Finalized){& $entry.Finalized @{Status='Failed'} $entry.CallbackContext};StopIntakeTimer
}
function Descendants {
 param([Windows.DependencyObject]$Node)
 if($null -eq $Node){return};$Node
 for($i=0;$i -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($Node);$i++){Descendants ([Windows.Media.VisualTreeHelper]::GetChild($Node,$i))}
}
function VisibleText {
 $script:Window.UpdateLayout()
 return (@(Descendants $script:HostPanel|Where-Object {$_ -is [Windows.Controls.TextBlock] -and $_.IsVisible}|ForEach-Object {$_.Text}) -join "`n")
}
function CleanupDetailsText {
 $details=$script:CleanupDialogDetailsControl
 CheckUI ($details -is [Windows.Controls.Expander] -and $details.Parent -eq $script:Window.FindName('DialogBody').Parent -and $details.Header -ceq '查看详情') 'Cleanup scope is available in the actual dialog details control'
 $details.IsExpanded=$true;$script:Window.UpdateLayout()
 CheckUI ($details.IsVisible -and $details.Content.IsVisible) 'Expanded cleanup scope is visible to the user'
 return [string]$details.Content.Text
}
function DeliverCleanupNodes {param([object[]]$Nodes=@())
 $reads=@($script:Requests|Where-Object {-not $_.Delivered -and $_.Request.Action -ceq 'Nodes' -and $_.CallbackContext.Type -ceq 'LocalCleanupRefresh'})
 CheckUI ($reads.Count -eq 1 -and $script:DeployUI.CleanupRefresh.Phase -ceq 'Loading') 'Cleanup schedules exactly one authoritative asynchronous line-list refresh'
 DeliverUI -Data $Nodes -Index ($script:Requests.IndexOf($reads[0]))
 CheckUI ($script:DeployUI.CleanupRefresh.Phase -ceq 'Completed' -and (ConvertTo-Json -InputObject @($script:Nodes) -Depth 30 -Compress) -ceq (ConvertTo-Json -InputObject @($Nodes) -Depth 30 -Compress)) 'The real Nodes callback finishes with the expected retained lines'
}
function Shot {
 param([string]$Name,[string]$Focus='')
 StopIntakeTimer
 if($Focus){$script:Controls[$Focus].BringIntoView()}
 $script:Footer.Text='隔离 WPF · 夹具状态 · 不证明服务器部署或网络结果';$script:Window.FindName('FooterContext').Text=((Get-Content -LiteralPath (Join-Path $script:PackageRoot 'version.json') -Raw|ConvertFrom-Json).Version+' / SMOKE / FIXTURE')
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
 $p=FixturePath $Path;$null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($p));[IO.File]::WriteAllText($p,(ConvertTo-Json -InputObject $Value -Depth 30),(New-Object Text.UTF8Encoding($false)))
}
function ReadyFixture {
 $id=[guid]::NewGuid().ToString('D');$dir=FixturePath (Join-Path $script:Root ('profiles\'+$id));$null=[IO.Directory]::CreateDirectory($dir)
 $engine=Join-Path $dir 'engine.fixture.bin';[IO.File]::WriteAllText($engine,'NOT AN EXECUTABLE: UI015 FIXTURE');$engineHash=(Get-FileHash -LiteralPath $engine -Algorithm SHA256).Hash
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
 ImportNamedPresentation 'TradeChannel.ps1' @('B','AddC','T','Stack','Card','Margin','Grid','Cell','ControlName','Btn','Icon','IconTile','Rule','KeyValue','Notice')
 ImportNamedPresentation 'ui\Pages.ps1' @('TwoColumns','Tx','Head','Note')
 $shell=SafeLocalPath (Join-Path $script:PackageRoot 'ui\Shell.xaml');$script:LoadedSources.Add([pscustomobject]@{File='ui\Shell.xaml';Path=$shell;SHA256=(Get-FileHash -LiteralPath $shell -Algorithm SHA256).Hash})
 [xml]$xaml=Get-Content -LiteralPath $shell -Raw -Encoding UTF8;$reader=New-Object Xml.XmlNodeReader($xaml)
 try{$script:Window=[Windows.Markup.XamlReader]::Load($reader)}finally{$reader.Close()}
 # Serial self-tests inherit the real chrome/tray refresh functions.
 $script:Window.TaskbarItemInfo=New-Object Windows.Shell.TaskbarItemInfo
 # Own this fixture window's caches instead of inheriting a disposed tray.
 $script:BrandWindowIcons=@{};$script:BrandTaskbarOverlays=@{};$script:Tray=$null
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
 & $protocolModule {param($context)$script:UI015Network=$context;function script:Get-TCProtocolNetworkContext {return $script:UI015Network}} $script:FixtureNetwork
 $script:Window.FindName('DialogConfirm').Add_Click({$action=$script:DialogCallback;$context=$script:DialogContext;CloseDialog;if($action){& $action $context}})
 $script:Window.FindName('DialogCancel').Add_Click({CloseDialog})
 $script:Window.Show();ResetUI;$baseOverview=ConvertTo-Json -InputObject $script:Overview -Compress

 ResetUI;ShowSetup;Shot '015-01-single-add-line'
 $addButtons=@(Descendants $script:HostPanel|Where-Object {$_ -is [Windows.Controls.Button] -and [string]$_.Content -eq '添加线路'})
 CheckUI ($addButtons.Count -eq 1 -and $script:Controls.ContainsKey('DeployAddLine') -and -not $script:Controls.ContainsKey('DeployNew') -and -not $script:Controls.ContainsKey('DeployAdd') -and $script:Requests.Count -eq 0) 'Setup has one AddLine entry and no scenario dispatch'
 ClickUI 'DeployAddLine';CheckUI ((LastRequest).Action -eq 'DeploymentDiscover' -and $script:DeployUI.Intent -eq 'Auto') 'AddLine enters actual automatic deployment and captures discovery only'
 CheckUI ($script:Controls.DeployLoginMethod.SelectedIndex -eq 0 -and $script:Controls.DeployCredentialLabel.Text -eq '服务器登录密码' -and -not $script:Controls.DeployAccessAdvanced.IsExpanded) 'First authentication offers password with private-key details folded'
 $script:Controls.DeployConnectionText.Text='ssh root@192.0.2.10 -p 22';$script:Controls.DeployName.Text='测试输入线路（夹具）'
 $fixturePassword='UI015_ONLY_Aa12!';$script:Controls.DeployPassword.Password=$fixturePassword;$passwordBox=$script:Controls.DeployPassword
 DeliverUI ([pscustomobject]@{Servers=@();ContinueRuns=@();Runs=@()})
 CheckUI ([Object]::ReferenceEquals($passwordBox,$script:Controls.DeployPassword) -and $script:Controls.DeployPassword.Password -ceq $fixturePassword -and $script:Controls.DeployConnectionText.Text -eq 'ssh root@192.0.2.10 -p 22') 'Discovery callback rerender preserves actual PasswordBox and entered connection'
  CheckUI ([bool]$script:Controls.DeployRemember.IsChecked) 'Task-scoped remembering defaults on with a visible lifetime'
  $script:Controls.DeployRemember.IsChecked=$false
  ShowProductDeployment;CheckUI ($script:Controls.DeployPassword.Password -ceq $fixturePassword -and -not $script:Controls.DeployRemember.IsChecked) 'Repeated render preserves password and the explicit opt-out from task storage'
 Shot '015-02-password-preserved' 'ProductDeployInspect'
 $script:Controls.DeployLoginMethod.SelectedIndex=1
 CheckUI ($script:Controls.DeployCredentialLabel.Text -like '*私钥解密口令*' -and $script:Controls.DeployPassword.SecurePassword.Length -eq 0 -and $script:Controls.DeployAccessAdvanced.IsExpanded) 'Changing authentication kind separates passphrase and clears previous password'
 Shot '015-03-private-key-method' 'DeployKeyPath'

 ResetUI;$run=BaseRun 'PlanReady' 'Failed';$run.AccessIssue=@{Kind='Credentials';Code='AuthenticationRejected';ResumeStage='PlanReady'};$run.Review=@{ChangeDigest='fixture-approved-scope'}
 $server=[pscustomobject]@{LocalRecordId=$run.ServerRecordId;Name=$run.Name;Connection=@{Host='192.0.2.10';User='root';Port=22;IdentityFile=''};CredentialRef=$null}
 $script:DeployUI.ServerId=$run.ServerRecordId;$script:DeployUI.Discovery=@{Servers=@($server)};RenderRun $run;Shot '015-04-inline-access-issue'
 CheckUI ($script:Controls.DeployAccessTitle.Text -eq '服务器登录失败' -and $script:Controls.ContainsKey('DeployRetryLogin') -and -not $script:Controls.ContainsKey('DeployApprove') -and $script:DialogCount -eq 0) 'AccessIssue renders inline with one credential correction, before scope approval'
 ClickUI 'DeployRetryLogin';$script:Controls.DeployPassword.Password=$fixturePassword;ClickUI 'ProductDeployInspect'
 CheckUI ($script:Requests.Count -eq 1 -and (LastRequest).Action -eq 'DeploymentSessionFixture' -and (LastRequest).RunId -eq $run.RunId -and $script:DeployUI.Run.Review.ChangeDigest -eq 'fixture-approved-scope' -and $script:DialogCount -eq 0) 'Same-page login preserves original Run and approval scope, creates no replacement run'
 DeliverUI (@{SessionRef=@{RunId=$run.RunId;InstanceId='fixture-session'}})

 ResetUI;$run=BaseRun 'TcpPlan' 'Failed';$run.AccessIssue=@{Kind='Connection';Code='SshConnectionFailed';ResumeStage='TcpPlan'}
 $run.Profiles=@([pscustomobject]@{Id='Udp';PreparationState='SyntaxValidated'});$run.MissingProtocols=@('Tcp')
 RenderRun $run;Shot '0162-01-connection-retry'
 CheckUI ($script:Controls.ContainsKey('DeployRetryConnection') -and $script:Controls.ContainsKey('DeployRetryLogin') -and -not $script:Controls.ContainsKey('DeployPassword') -and $script:Controls.DeployAccessTitle.Text -eq '服务器管理连接中断') 'Connection interruption offers retry separately from editing credentials'
 CheckUI ($script:Controls.DeployResumeProgress.Text -eq '本机已保存配置：UDP' -and (VisibleText).Contains('中断步骤：准备双协议配置')) 'Connection interruption retains visible prepared configuration and the continuation step'
 $script:DeployUI.ReconnectMessage='正在恢复服务器连接；已完成步骤会保留。';ShowProductDeployment
 CheckUI (-not $script:Controls.ContainsKey('DeployReconnectStatus') -and (VisibleText) -notlike '*正在恢复服务器连接*') 'A residual reconnect string cannot turn a terminal connection error into active work'
 $script:DeployUI.SessionStarting=$true;ShowProductDeployment;Shot '0162-02-reconnecting'
 CheckUI ($script:Controls.ContainsKey('DeployReconnectStatus') -and -not $script:Controls.ContainsKey('DeployPassword')) 'Automatic reconnection keeps progress on the existing task page'
 $script:DeployUI.SessionStarting=$false;$script:DeployUI.ReconnectMessage='';ShowProductDeployment;ClickUI 'DeployRetryLogin'
 CheckUI ($script:Controls.ContainsKey('DeployPassword') -and $script:DeployUI.Run.RunId -ceq $run.RunId -and $script:Requests.Count -eq 0) 'Editing credentials is an explicit action and retains the run'

 ResetUI;$run=BaseRun 'PrepareAccess' 'WaitingUser'
 $run.AccessIssue=@{Kind='FirstTrust';Code='HostTrustRequired';ResumeStage='PrepareAccess';SessionInstanceId='fixture-first-trust';ObservedFingerprint=('SHA256:'+('A'*43));Connection=@{Host='192.0.2.10';User='root';Port=22}}
 $run.LastError=@{Code='ConnectionTimeout';Message='服务器接入需要处理，准备进度和当前线路保持。'}
 $script:DeployUI.SessionRef=@{RunId=$run.RunId;InstanceId='fixture-first-trust'};$script:DeployUI.Credential=@{Kind='Password';Password=(ConvertTo-SecureString $fixturePassword -AsPlainText -Force)};$script:DeployUI.CredentialExpiresAt=[DateTimeOffset]::UtcNow.AddMinutes(30)
 $script:DeployUI.ReconnectMessage='正在恢复服务器连接；已完成步骤会保留。';RenderRun $run;Shot '01610-01-first-trust-wait'
 CheckUI ($script:Controls.DeployAccessTitle.Text -eq '等待确认服务器身份' -and $script:Controls.DeployTrustTarget.Text.Contains('192.0.2.10:22') -and $script:Controls.DeployTrustFingerprint.Text.Contains('SHA256:') -and $script:Controls.ContainsKey('DeployVerifyIdentity')) 'First trust renders a permanent target fingerprint and confirmation action'
 CheckUI ((VisibleText) -notmatch '正在核对|正在恢复|服务器接入需要处理' -and -not $script:Controls.ContainsKey('DeployReconnectStatus')) 'First-trust wait hides all obsolete timeout and in-progress messages'
 ClickUI 'DeployVerifyIdentity'
 CheckUI ($script:DialogCount -eq 1 -and $script:Window.FindName('DialogBody').Text.Contains('192.0.2.10:22') -and $script:Requests.Count -eq 0 -and -not $script:DeployUI.Identity) 'Actual first-trust button opens only a review dialog and no identity-replacement flow'
 $script:Window.FindName('DialogCancel').RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
 ShowProductDeployment;Shot '01610-02-first-trust-dismissed'
 CheckUI ($script:Controls.ContainsKey('DeployVerifyIdentity') -and $script:DeployUI.Run.AccessIssue.Kind -eq 'FirstTrust' -and $script:Requests.Count -eq 0) 'Closing the real WPF dialog leaves the actionable wait on the page without a worker request'
 ClickUI 'DeployVerifyIdentity';CheckUI ($script:DialogCount -eq 2 -and $script:Requests.Count -eq 0) 'The same first-trust dialog can be reopened from the actual WPF button'
 CloseDialog
 ResetUI;$run=BaseRun 'PrepareAccess' 'WaitingUser';$run.AccessIssue=@{Kind='Connection';Code='ConnectionTimeout';ResumeStage='PrepareAccess'};$run.LastError=@{Code='ConnectionTimeout';Message='服务器连接超时，本次尝试已结束。'}
 $script:DeployUI.ReconnectMessage='正在恢复服务器连接';RenderRun $run;Shot '01610-03-connection-timeout'
 CheckUI ($script:Controls.DeployAccessTitle.Text -eq '服务器连接超时' -and (VisibleText) -like '*本次连接尝试已结束*' -and (VisibleText) -notmatch '正在连接|正在核对|正在恢复' -and $script:Controls.ContainsKey('DeployRetryConnection')) 'Timeout page clearly ends the attempt and keeps manual retry without contradictory progress'
 $run.AccessIssue=$null;RenderRun $run;Shot '01610-04-legacy-access-failure'
 CheckUI ($script:Controls.DeployAccessTitle.Text -eq '服务器接入已停止' -and (VisibleText) -notmatch '正在核对|正在恢复' -and $script:Controls.ContainsKey('DeployRetryConnection')) 'Legacy errors without AccessIssue also render a stopped state'
 $script:DeployUI.SessionStarting=$true;$script:DeployUI.AutomaticLoginRetries=1;ShowProductDeployment;Shot '01610-05-active-access-attempt'
 CheckUI ($script:Controls.ContainsKey('DeployReconnectStatus') -and -not $script:Controls.ContainsKey('DeployAccessTitle') -and @((Descendants $script:HostPanel)|Where-Object {$_ -is [Windows.Controls.Expander] -and $_.Header -ceq '连接详情' -and $_.Content.Text -like '*20 秒*最多自动重试 2 次*已重试 1 次*'}).Count -eq 1) 'Only a real starting attempt displays connection progress and its retry budget'

 ResetUI;$f=ReadyFixture;$script:Nodes=@($f.Line);$script:LineProfileUI=@{Id=$f.Line.LineId;Line=$f.Line}
 $script:ConnectionPreviewUI=@{LineId=$f.Line.LineId;ProfileId='';Preview=$null};RequestLineConnectionPreview
 CheckUI ((LastRequest).Action -ceq 'ConnectionDefaultPreview') 'Home default uses the real connection preview request'
 DeliverUI ([pscustomobject]@{CanSwitch=$false;Code='SavedDefaultMissing';NextAction='ChooseProfile';LineId=$f.Line.LineId;ProfileId='';Message='technical fixture message'})
 CheckUI ($script:DialogCount -eq 0 -and -not $script:LastErrorDialog -and $script:ConnectionCompletionUI.LineId -ceq $f.Line.LineId) 'Missing default navigates directly to an existing choice without an extra acknowledgement'
 Shot '0164-03-choose-default'
 CheckUI ((LastRequest).Action -ceq 'LineProfiles' -and (LastRequest).Id -ceq $f.Line.LineId) 'Default choice leads to the same line and its prepared protocols'

 ResetUI;$run=BaseRun 'PlanReady';$run.Review=@{ChangeDigest='fixture-single-scope-015';Details='夹具范围：目标双协议、本机独立授权和配置；保留已有设备。';TargetIdentity=@{Connection=@{Host='192.0.2.10';User='root';Port=22}}};$run.Plan=@{PublicEndpoint='192.0.2.10:51820'}
 RenderRun $run;Shot '015-05-single-scoped-approval' 'DeployApprove'
 CheckUI ($script:Controls.ContainsKey('DeployApprove') -and @((Descendants $script:HostPanel)|Where-Object {$_ -is [Windows.Controls.Button] -and $_.Name -eq 'DeployApprove'}).Count -eq 1 -and (VisibleText) -like '*将在目标服务器准备 UDP / TCP*这台电脑授权*' -and $script:Requests.Count -eq 0) 'First PlanReady renders exactly one inline business scope approval'
 ClickUI 'DeployApprove'
 CheckUI ($script:DialogCount -eq 0 -and $script:Requests.Count -eq 1 -and (LastRequest).Action -eq 'DeploymentProceed' -and (LastRequest).Command -eq 'Approve' -and (LastRequest).ApprovedChangeDigest -ceq $run.Review.ChangeDigest) 'Single approval submits exact scoped digest without a second modal'
 $run.Stage='ManagementApply';$run.Status='Running';DeliverUI $run
 CheckUI (-not $script:Controls.ContainsKey('DeployApprove') -and $script:Requests.Count -eq 1 -and $script:DialogCount -eq 0) 'Authorized child step renders progress without another UI approval'

 ResetUI;$f=ReadyFixture;RenderRun $f.Run;Shot '015-06-real-saved-default'
 $view=LineRecommendationView $f.Line
 CheckUI ($view.CanConnect -and $view.ProfileId -eq $f.Selected.Id -and $view.Label -like '下次默认方式：*' -and $view.Status -eq 'SavedDefault') 'New LineRecommendationView uses CanConnect and actual saved binding/manifest'
 CheckUI ($script:Controls.DeployOutcomeTitle.Text -eq '部署完成，线路测试通过' -and $script:Controls.DeployDecisionMessage.Text -match '自动保存|已保存' -and $script:Controls.DeployPreparationStatus.Text -like '*标准与兼容连接均已保存*' -and $script:Controls.DeployActivationStatus.Text -like '*尚未启用*夹具*继续使用*') 'Complete auto-saved input shows saved preparation separately from current activation'
 CheckUI ($script:Controls.ContainsKey('DeployConnectRecommended') -and $script:Controls.ContainsKey('DeployLeave') -and -not $script:Controls.ContainsKey('DeployLater') -and $script:Requests.Count -eq 0) 'Auto-saved outcome has Connect and Later, with no required Save request'
 ClickUI 'DeployLeave';CheckUI ($script:Page -eq 'nodes' -and (LastRequest).Action -eq 'Nodes' -and @($script:Requests|Where-Object {$_.Request.Action -eq 'DeploymentProceed'}).Count -eq 0) 'Later leaves prepared state without pretending to execute Save or connect'
 ResetUI;$f=ReadyFixture;$f.Run.AttentionRequired=$true;$f.Run.Recommendation=[pscustomobject]@{Status='Unavailable';Reason='夹具中的检查失败'};$f.Line.Recommendation=$f.Run.Recommendation
 foreach($p in $f.Line.Profiles){$p.Validation.Status='Failed';$p.Validation.Code='CandidateForwardingFailed';$p.Validation.EligibleForAutomaticSelection=$false};RenderRun $f.Run;Shot '0164-07-saved-needs-attention'
 CheckUI ($script:Controls.DeployOutcomeTitle.Text -notlike '*部署完成*' -and $script:Controls.ContainsKey('DeployConnectRecommended') -and $script:Controls.ContainsKey('DeployDiagnostics') -and (VisibleText) -match '未通过|失败' -and $script:Requests.Count -eq 0) 'Ordinary failed checks remain visible while a valid saved choice offers an explicit checked connection'

 ResetUI;$protected=HistoryRow 'DeploymentRun' '11111111-2222-4333-8444-555555555555' $false $true;$hidden=HistoryRow 'LegacyLinuxJob' '22222222-2222-4333-8444-555555555555' $true $false
 $protected.Name='正在执行的任务（夹具）';$protected.Status='Running';$protected.Stage='Apply';$protected.Classification='Continue';$protected.AttentionRequired=$true
 $hidden.Name='已删除记录（夹具）';$script:DeployUI.HistoryIncludeHidden=$true;$script:DeployUI.HistoryRecords=@($protected,$hidden);ShowUnifiedOperationHistory;Shot '015-08-protected-history'
 CheckUI (-not $script:Controls.SelectAllHistory.IsEnabled -and -not $script:Controls.DeleteSelectedRecords.IsEnabled) 'All-active or removed view disables empty batch actions'
  CheckUI ($script:Controls['DeleteHistory'+(DeploymentItemControlId $protected)].IsEnabled -and $script:Controls.ContainsKey('RestoreHistory'+(DeploymentItemControlId $hidden))) 'A stored running label permits live cleanup preview while removed records offer restore'
  ClearSelectedOperationHistoryUI;CheckUI ($script:Requests.Count -eq 0 -and $script:DialogCount -eq 0 -and -not $script:DeployUI.RecordDeletePending -and $script:Window.FindName('Overlay').Visibility -eq 'Collapsed' -and $script:LastToast -match '选择') 'Empty selection cannot preview, confirm or fall back to global deletion'
 $ended=HistoryRow 'DeploymentRun' '44444444-2222-4333-8444-555555555555';$ended.Name='东京查询（夹具）'
 $maintenance=HistoryRow 'ManagementIntent' '55555555-2222-4333-8444-555555555555';$maintenance.Name='管理查询（夹具）'
 $script:DeployUI.HistoryRecords=@($protected,$hidden,$ended,$maintenance);ShowUnifiedOperationHistory
 ClickUI 'SelectAllHistory'
 CheckUI ($script:DeployUI.HistorySelectedIds.Count -eq 2 -and $protected.Id -notin $script:DeployUI.HistorySelectedIds -and $hidden.Id -notin $script:DeployUI.HistorySelectedIds -and $script:Controls.DeleteSelectedRecords.Content -eq '删除所选（2）') 'Select all binds only currently deletable visible rows and updates the count'
 ClickUI 'SelectAllHistory';CheckUI ($script:DeployUI.HistorySelectedIds.Count -eq 0 -and -not $script:Controls.DeleteSelectedRecords.IsEnabled) 'Cancel select all clears the checked set and disables delete'
 ClickUI ('RestoreHistory'+(DeploymentItemControlId $hidden));CheckUI ((LastRequest).Action -eq 'RecordRestore' -and (LastRequest).Id -ceq $hidden.Id) 'Restore sends the exact legacy hidden record to the unified recovery action'
 $script:Requests.Clear();SelectHistoryFilter 'HistorySourceFilter' 'DeploymentRun';SelectHistoryFilter 'HistoryStatusFilter' 'Ended';$script:Controls.HistorySearch.Text='东京';ClickUI 'ApplyHistoryFilters'
 CheckUI ($script:DeployUI.HistoryVisibleRecords.Count -eq 1 -and $script:DeployUI.HistoryVisibleRecords[0].Id -ceq $ended.Id -and $script:DeployUI.HistorySelectedIds.Count -eq 0) 'Source name and status filters restrict the exact public result and clear selection'
 Shot '015-19-history-source-name-status';ClickUI ('DeleteHistory'+(DeploymentItemControlId $ended))
 CheckUI ((LastRequest).Action -eq 'RecordDeletePreview' -and (LastRequest).Ids.Count -eq 1 -and (LastRequest).Ids[0] -ceq $ended.Id) 'Single delete first previews its exact ID'
  DeliverUI @{PlanVersion=3;Scope='DeploymentTask';BusinessState='PreviewReady';SelectedIds=@($ended.Id);EligibleCount=1;ProtectedCount=0;Blocked=@();PreviewToken='fixture-single-record-token';Targets=@(@{Name=$ended.Name;Endpoint='192.0.2.10:22:root'});ServerCount=1;OperationCount=1;LineCount=0;FileCount=4}
  $details=CleanupDetailsText
  CheckUI ($script:Requests.Count -eq 1 -and $script:DialogContext.CleanupDialog -ceq 'Confirm' -and $script:DeployUI.RecordDeletePending.Phase -ceq 'Ready' -and $script:Window.FindName('DialogTitle').Text.Contains($ended.Name) -and $script:Window.FindName('DialogBody').Text -like '*清理所选任务记录*已保存线路和服务器上的服务会保留*' -and $details.Contains($ended.Id) -and $details -like '*线路 0 条*本机文件 4 个*') 'Preview explains the exact local task cleanup and retained lines and remote service without automatically deleting'
 $script:Window.FindName('DialogCancel').RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
  CheckUI ($script:Requests.Count -eq 1 -and $script:Window.FindName('Overlay').Visibility -eq 'Collapsed') 'Cancelling confirmation dispatches no mutation'
  ClickUI ('DeleteHistory'+(DeploymentItemControlId $ended));DeliverUI @{PlanVersion=3;Scope='DeploymentTask';BusinessState='PreviewReady';SelectedIds=@($ended.Id);EligibleCount=1;ProtectedCount=0;Blocked=@();PreviewToken='fixture-stale-record-token';Eligible=@($ended)}
 $script:Window.FindName('DialogConfirm').RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
 CheckUI ((LastRequest).Action -eq 'RecordDeleteCommit' -and (LastRequest).PreviewToken -ceq 'fixture-stale-record-token' -and (LastRequest).Count -eq 2) 'Confirmation sends only the sealed backend token'
  FailUI '记录已变化，请刷新后重新选择；未删除任何记录。';$details=CleanupDetailsText;Shot '015-09-stale-clear-response'
  CheckUI ($script:DeployUI.RecordDeletePending.Phase -ceq 'OutcomeUnknown' -and $script:DeployUI.RecordDeletePending.Submitted -and $script:Window.FindName('DialogBody').Text -like '*删除结果待确认*请勿重复删除*' -and $details -like '*记录已变化*' -and $script:LastToast -notlike '*已删除*') 'Failed deletion preserves the original error and requires checking its result without claiming success'
  $count=$script:Requests.Count;SubmitLocalCleanupUI $script:DeployUI.RecordDeletePending;DeleteOperationRecordsUI -Ids @($ended.Id)
  CheckUI ($script:Requests.Count -eq $count -and @($script:Requests|Where-Object {$_.Request.Action -ceq 'RecordDeleteCommit'}).Count -eq 1) 'An uncertain deletion cannot be resubmitted or replaced by a new delete request'
  # Keep the failed operation latched above; the independent filter/batch case
  # starts with a fresh UI fixture rather than pretending it was recovered.
  ResetUI;$script:DeployUI.HistoryIncludeHidden=$true;$script:DeployUI.HistoryRecords=@($protected,$hidden,$ended,$maintenance);ShowUnifiedOperationHistory
  SelectHistoryFilter 'HistorySourceFilter' '';SelectHistoryFilter 'HistoryStatusFilter' 'Protected';$script:Controls.HistorySearch.Text='';ClickUI 'ApplyHistoryFilters'
 CheckUI ($script:DeployUI.HistoryVisibleRecords.Count -eq 1 -and $script:DeployUI.HistoryVisibleRecords[0].Id -ceq $protected.Id) 'Executing filter retains the active task and its explanation'
 SelectHistoryFilter 'HistoryStatusFilter' 'Attention';ClickUI 'ApplyHistoryFilters'
 CheckUI ($script:DeployUI.HistoryVisibleRecords.Count -eq 1 -and $script:DeployUI.HistoryVisibleRecords[0].Id -ceq $protected.Id) 'Attention filter retains the actionable preparation'
 SelectHistoryFilter 'HistoryStatusFilter' 'Ended';$script:Controls.HistorySearch.Text='查询';ClickUI 'ApplyHistoryFilters'
 $requestCount=$script:Requests.Count;ClickUI 'ExportOperationHistory';$export=$script:ExportedHistoryFixture;$exportJson=ConvertTo-Json -InputObject $export -Depth 12
 CheckUI ($export.Kind -ceq 'TradeChannel.OperationHistorySummary' -and -not $export.ContainsCredentials -and $export.Records.Count -eq 2 -and $script:Requests.Count -eq $requestCount) 'Export includes only the current filtered public records'
 CheckUI ($exportJson -notmatch '"(?:Password|PrivateKeyPem|CredentialRef|SavedLoginRef|SessionRef|ClientRequest|ClientResponse|RequestDirectory|PreviewToken)"\s*:') 'History export excludes credentials source replies and confirmation tokens'
 [IO.File]::WriteAllText((SafeLocalPath (Join-Path $qa '015-history-export-fixture.json')),(ConvertTo-Json -InputObject ([ordered]@{FixtureOnly=$true;Summary=$export}) -Depth 14),(New-Object Text.UTF8Encoding($true)))
 foreach($record in @($ended,$maintenance)){$pick='HistoryPick'+(DeploymentItemControlId $record);$script:Controls[$pick].IsChecked=$true;ClickUI $pick}
 CheckUI ($script:Controls.DeleteSelectedRecords.Content -eq '删除所选（2）') 'Independent checkbox clicks update the multi-selection count'
 Shot '015-20-history-visible-batch';ClickUI 'DeleteSelectedRecords'
 CheckUI ((LastRequest).Action -eq 'RecordDeletePreview' -and (LastRequest).Ids.Count -eq 2 -and $ended.Id -in (LastRequest).Ids -and $maintenance.Id -in (LastRequest).Ids) 'Multi-selection previews exactly the checked visible IDs'
  DeliverUI @{PlanVersion=3;Scope='DeploymentTask';BusinessState='PreviewReady';SelectedIds=@($ended.Id,$maintenance.Id);EligibleCount=2;ProtectedCount=0;Blocked=@();PreviewToken='fixture-batch-record-token';Eligible=@($ended,$maintenance)}
  $batchPending=$script:DeployUI.RecordDeletePending
 $script:Window.FindName('DialogConfirm').RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
 CheckUI ((LastRequest).Action -eq 'RecordDeleteCommit' -and (LastRequest).PreviewToken -ceq 'fixture-batch-record-token') 'Multi-selection commits only its reviewed backend token'
  $script:Window.FindName('DialogConfirm').RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)));SubmitLocalCleanupUI $batchPending
  CheckUI (@($script:Requests|Where-Object {$_.Request.Action -ceq 'RecordDeleteCommit'}).Count -eq 1) 'One reviewed batch confirmation permits exactly one commit even after repeated confirmation'
  $retainedNodes=@([pscustomobject]@{id='66666666-2222-4333-8444-555555555555';LineId='66666666-2222-4333-8444-555555555555';Name='任务清理保留的线路（夹具）'});$script:Nodes=$retainedNodes
  DeliverUI @{BusinessState='Deleted';SelectedIds=@($ended.Id,$maintenance.Id);DeletedCount=2;DeletedIds=@($ended.Id,$maintenance.Id);DeletedLineIds=@();ProtectedCount=0;DataDeleted=$true}
  CheckUI ($batchPending.Phase -ceq 'Deleted' -and $script:LastToast -ceq ('已删除'+$batchPending.Label+'。') -and $script:DeployUI.HistorySelectedIds.Count -eq 0 -and @($script:DeployUI.HistoryRecords|Where-Object {$_.Id -in @($ended.Id,$maintenance.Id)}).Count -eq 0 -and $script:DeployUI.HistoryRecords.Count -eq 2) 'Physical cleanup completion removes only the reviewed records, reports success and clears the old selection'
  DeliverCleanupNodes $retainedNodes
 ResetUI;InitializePairingUI;$script:Role='product-pair';$script:DeployUI.PairIntake.Role='Client';$script:DeployUI.PairIntake.Stage='InviteTrust';$script:DeployUI.PairIntake.Text='fixture-invite-015'
 $script:DeployUI.PairFields.InviteText='fixture-invite-015';$script:DeployUI.PairFields.Fingerprint='fixture-signing-fingerprint';$script:DeployUI.InviteInspection=@{Fingerprint='fixture-signing-fingerprint';Payload=@{PublicEndpoint='192.0.2.10:51820'}}
 ShowProductPairing;Shot '015-10-client-invite'
 CheckUI ($script:Controls.ContainsKey('PairCreateRequest') -and -not $script:Controls.ContainsKey('PairAuthorize') -and -not $script:Controls.ContainsKey('PairRequestText') -and -not $script:Controls.ContainsKey('DeployPassword')) 'Client invitation view contains only this computer role and no management credentials'
 ClickUI 'PairCreateRequest';CheckUI ((LastRequest).Action -eq 'PairRequestCreate' -and (LastRequest).ConfirmedFingerprint -ceq 'fixture-signing-fingerprint') 'Client approval captures independent request creation for the checked invite'
 DeliverUI (@{EnrollmentId='33333333-2222-4333-8444-555555555555';PairRequest='fixture-public-request-015';PairingCode='FIXTURE015'})
 Shot '015-11-client-waiting';CheckUI ($script:Controls.ContainsKey('PairCopyRequest') -and $script:Controls.ContainsKey('PairReturnText') -and -not $script:Controls.ContainsKey('PairCreateRequest') -and -not $script:Controls.ContainsKey('PairAuthorize')) 'Request callback advances only the client waiting/return step'
 ClickUI 'PairCopyRequest';CheckUI ($script:Requests.Count -eq 1) 'Copying public request in Smoke does not touch clipboard or send a message'
 $script:DeployUI.PairIntake.Stage='GrantReady';$script:DeployUI.PairFields.ReturnText='fixture-encrypted-return-015';ShowProductPairing;ClickUI 'PairCompleteReturn'
 CheckUI ((LastRequest).Action -eq 'PairComplete' -and (LastRequest).EnrollmentId -ceq '33333333-2222-4333-8444-555555555555') 'Client return binds candidate preparation to its original enrollment'
 DeliverUI (@{DeploymentCompleteness='Partial';MissingProtocols=@('Tcp');AttentionRequired=$true});Shot '015-12-pair-partial-attention'
 CheckUI ($script:Controls.PairCompletionSummary.Text -like '*待处理问题*' -and $script:Controls.PairCompletionSummary.Text -notlike '*已备齐*') 'Partial pairing callback retains attention instead of claiming complete deployment'
 ResetUI;InitializePairingUI;InitializeServerUI;$script:Role='product-pair';$script:DeployUI.PairIntake.Role='Manager';$script:DeployUI.PairIntake.Stage='Review';$script:DeployUI.PairIntake.Text='fixture-public-request-015'
 $binding=@{RemoteOwnerId='fixture-owner';NodeId='fixture-remote-node';ServerPublicKey='fixture-public-key'}
 $script:DeployUI.Management.ServerId='aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';$script:DeployUI.Management.Server=@{Name='批准目标（夹具）';RecordState='Active'};$script:DeployUI.Management.Authenticated=$true;$script:DeployUI.Management.Info=@{RemoteOwnerId=$binding.RemoteOwnerId;Node=@{NodeId=$binding.NodeId;ServerPublicKey=$binding.ServerPublicKey}}
 $script:DeployUI.PairFields.InviteText='fixture-invite-015';$script:DeployUI.PairRequest='fixture-public-request-015';$script:DeployUI.PairRequestInspection=@{PairingCode='FIXTURE015';Payload=@{InviteId='fixture-invite-id';DeviceName='申请电脑（夹具）';ServerBinding=$binding;ClientRequest=@{RequestId='fixture-original-request';DeviceId='fixture-original-device'}}}
 ShowProductPairing;Shot '015-13-manager-only'
 CheckUI ($script:Controls.ContainsKey('PairAuthorize') -and $script:Controls.PairAuthorize.IsEnabled -and $script:Controls.ContainsKey('PairRequestText') -and -not $script:Controls.ContainsKey('PairCreateRequest') -and -not $script:Controls.ContainsKey('PairReturnText')) 'Manager view contains approval for the bound device, with no client generation step'
 ClickUI 'PairAuthorize';CheckUI ((LastRequest).Action -eq 'ServerOperation' -and (LastRequest).Operation -eq 'authorize_external' -and (LastRequest).Input.PairRequest -ceq 'fixture-public-request-015' -and (LastRequest).Input.InviteId -ceq 'fixture-invite-id') 'Manager signals authorization of exact checked original request only'

 ResetUI;$run=BaseRun 'PlanReady' 'Failed';$run.AccessIssue=@{Kind='IdentityChanged';Code='HostKeyChanged';ResumeStage='PlanReady'};RenderRun $run
 CheckUI ($script:Controls.ContainsKey('DeployVerifyIdentity') -and $script:DialogCount -eq 0) 'Changed identity has an inline identity-verification action'
 ClickUI 'DeployVerifyIdentity';Shot '015-14-identity-credentials'
 CheckUI ($script:DeployUI.Identity.OriginalRun -eq $run -and $script:Controls.ContainsKey('IdentityStart') -and $script:DeployUI.Identity.ServerId -ceq $run.ServerRecordId -and $script:Requests.Count -eq 0) 'Identity page preserves original run and target without backend actions on render'
 $script:Controls.IdentityPassword.Password=$fixturePassword;ClickUI 'IdentityStart'
 CheckUI ((LastRequest).Action -eq 'IdentitySessionFixture' -and (LastRequest).ServerId -ceq $run.ServerRecordId) 'Identity credentials signal only the isolated session seam'
 DeliverUI (@{SessionRef=@{RunId='fixture-identity-session';InstanceId='fixture-identity-instance'};VerificationToken='fixture-verification-token'})
 $state=$script:DeployUI.Identity;$state.Stage='AwaitingTrust';$state.Preview=@{Connection=@{Host='192.0.2.10';Port=22};HostKeyAlgorithm='ssh-ed25519';PreviousFingerprint=('SHA256:'+'P'*43);NewFingerprint=('SHA256:'+'N'*43);PreviewToken='fixture-identity-preview'}
 ShowProductDeployment;Shot '015-15-identity-trust'
 CheckUI ($script:Controls.ContainsKey('IdentityTrust') -and (VisibleText) -like '*本次指纹*SHA256:*' -and $script:DialogCount -eq 0) 'New host fingerprint is presented inline without silently treating it as reinstallation'
 ClickUI 'IdentityTrust';CheckUI ((LastRequest).Action -eq 'IdentityTrustFixture' -and (LastRequest).Fingerprint -ceq $state.Preview.NewFingerprint) 'Trust action signals exactly the observed new fingerprint'
 RequestDeploymentIdentityAssessment;CheckUI ((LastRequest).Action -eq 'ServerIdentityAssessment' -and (LastRequest).ServerId -ceq $run.ServerRecordId) 'Application identity assessment remains separate from SSH trust'
 $assessment=@{CanCommit=$true;Classification='ApplicationReset';AssessmentToken='fixture-assessment-token';NewFingerprint=$state.Preview.NewFingerprint;ChangeDigest='fixture-identity-change-digest';RequiresResetDeclaration=$true}
 DeliverUI $assessment;Shot '015-16-application-reset' 'IdentityCommit'
 CheckUI ((VisibleText) -like '*原隧道环境已重置*独立授权*' -and $script:Controls.ContainsKey('IdentityCommit')) 'Confirmed application reset presents new identity scope and preserves current connection'
 $state.Assessment.Classification='HostKeyUpdate';ShowProductDeployment;Shot '015-17-key-update-preserves-device'
 CheckUI ((VisibleText) -like '*隧道身份一致*保留已有设备与线路*') 'Host key update with unchanged application identity does not imply device recreation'
 $state.Assessment.Classification='ApplicationReset';ShowProductDeployment;ClickUI 'IdentityCommit'
 CheckUI ((LastRequest).Action -eq 'ServerIdentityTransition' -and (LastRequest).AssessmentToken -ceq 'fixture-assessment-token' -and (LastRequest).ApprovedChangeDigest -ceq 'fixture-identity-change-digest' -and (LastRequest).DeclaredApplicationReset) 'Identity commit sends the exact assessed transition scope, not a deployment approval'
 $newServerId='bbbbbbbb-bbbb-4ccc-8ddd-eeeeeeeeeeee';DeliverUI (@{Server=@{LocalRecordId=$newServerId;Name='新身份（夹具）';RecordState='Active'}})
 CheckUI ((LastRequest).Action -eq 'DeploymentCreate' -and (LastRequest).ServerId -ceq $newServerId -and $script:DeployUI.Identity -eq $null -and $script:DialogCount -eq 0) 'Transition callback returns to automatic deployment under the new server ID without a broad approval'

 # 0.23.0 D6: the two save scopes are two controls with two different sentences,
 # and the long-term opt-out reaches the model the non-smoke dispatch reads.
 ResetUI;ShowSetup;ClickUI 'DeployAddLine'
 CheckUI ($script:Controls.ContainsKey('DeployRememberSaved') -and $script:Controls.ContainsKey('DeployRemember')) 'The deployment form offers both the long-term and the task-scoped save scope'
 $savedScope=[string]$script:Controls.DeployRememberSaved.Content;$taskScope=[string]$script:Controls.DeployRemember.Content
 CheckUI ([bool]$script:Controls.DeployRememberSaved.IsChecked -and [bool]$script:Controls.DeployRemember.IsChecked) 'Both save scopes default to on'
 CheckUI ($savedScope -cne $taskScope -and $savedScope.StartsWith('在这台电脑') -and $taskScope.StartsWith('本任务中断后')) ('The two save scopes never share wording (long-term: "'+$savedScope+'" | task: "'+$taskScope+'")')
 Shot '015-19-two-save-scopes'
 $script:Controls.DeployRememberSaved.IsChecked=$false
 $script:Controls.DeployConnectionText.Text='192.0.2.10';$script:Controls.DeployPort.Text='22';$script:Controls.DeployUser.Text='root';$script:Controls.DeployPassword.Password=$fixturePassword
 StartProductDeployment
 CheckUI ([bool]$script:DeployUI.RememberSaved -eq $false) 'Turning long-term saving off reaches the model that gates the save dispatch'
 CheckUI (@($script:AllRequests|Where-Object {$_.Action -like '*Credential*' -or $_.ContainsKey('SavedLoginRef')}).Count -eq 0) 'Entering deployment with long-term saving off dispatches no credential save request and no saved reference'

# 0.23.0 修 1（QA 终审条件一）：预检失败一律不放行。
# 记录上明明有 SavedLoginRef，但只要读取状态这一步失败（异常或读不出状态），
# 页面就不能放出"使用这台服务器保存的登录资料"——少一个入口只是让操作员手输一次
# 密码，而一个点了必错的入口正是本方案要消灭的体验（设计 §5 已否决的方案①）。
# 这里显式模拟"预检不可用"：模块导入桩成空，Get-TCDeploySavedCredentialInfo 桩成
# 抛异常（连同它前面求值的绑定/摘要两个实参一并桩掉），旧写法
# else{[bool]$savedLoginRef} 在本断言下会错误地放出入口，因此断言不是空转。
$script:Smoke=$false;$script:PreflightCalls=0
$savedLoginStubs=@('Import-Module','Get-TCServerCredentialBinding','Get-TCDDigest','Get-TCDeploySavedCredentialInfo')
Set-Item -Path Function:script:Import-Module -Value {param($Name,[switch]$DisableNameChecking,[switch]$PassThru)}
Set-Item -Path Function:script:Get-TCServerCredentialBinding -Value {param($Record,[string]$CredentialKind='') [ordered]@{ServerRecordId='aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';Host='192.0.2.10';Port=22;User='root';PinnedHostKey='';IdentityTransitionRevision=0}}
Set-Item -Path Function:script:Get-TCDDigest -Value {param($Value) ('F'*64)}
Set-Item -Path Function:script:Get-TCDeploySavedCredentialInfo -Value {param($Root,$CredentialRef,$Binding,$CurrentManagementSigningKeyDigest) $script:PreflightCalls++;throw 'fixture: the saved-login preflight cannot be consulted'}
try{
 ResetUI
 $script:DeployUI.Intent='Auto';$script:DeployUI.ServerId='aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'
 $script:DeployUI.Discovery=@{Servers=@([pscustomobject]@{LocalRecordId='aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';Name='夹具服务器';SavedLoginRef='dddddddd-dddd-dddd-dddd-dddddddddddd';ManagementSigningPublicKey='';Connection=@{Host='192.0.2.10';Port=22;User='root';IdentityFile=''}})}
 ShowProductDeployment;Shot '015-20-preflight-unavailable'
 CheckUI ($script:PreflightCalls -eq 1) 'The saved-login preflight is actually reached and actually fails when the credential store cannot be consulted'
 CheckUI (-not $script:Controls.ContainsKey('DeployUseSaved')) 'A failed saved-login preflight offers no use-saved-login entry even though the record carries the pointer'
}finally{
 foreach($stubName in $savedLoginStubs){Remove-Item -Path ('Function:'+$stubName) -ErrorAction SilentlyContinue}
 $script:Smoke=$true
}
 CheckUI (((Get-Command Import-Module -ErrorAction SilentlyContinue).CommandType -eq 'Cmdlet') -and -not (Get-Command Get-TCDeploySavedCredentialInfo -ErrorAction SilentlyContinue) -and $script:Smoke) 'The preflight probe restores the real command set and Smoke mode for the rest of the suite'

 ResetUI;$script:Window.Width=1000;$script:Window.Height=680;$f=ReadyFixture;RenderRun $f.Run;Shot '015-18-minimum-ready' 'DeployConnectRecommended'
 $button=$script:Controls.DeployConnectRecommended;$point=$button.TranslatePoint((New-Object Windows.Point(0,0)),$script:Window.Content)
 CheckUI ($button.ActualWidth -gt 60 -and $point.X -ge 0 -and $point.X+$button.ActualWidth -le $script:Window.Content.ActualWidth -and $point.Y -ge 0 -and $point.Y+$button.ActualHeight -le $script:Window.Content.ActualHeight) 'Minimum window reaches the actual saved-default connection action'
 CheckUI ((ConvertTo-Json -InputObject $script:Overview -Compress) -ceq $baseOverview) 'All UI transitions preserve the simulated current session identity'
 CheckUI (-not [IO.Directory]::Exists($script:JobRoot) -and $script:DeniedActors.Count -eq 0) 'No real worker queue, process, HTTP, session actor or runtime operation was invoked'
 $allowed=@('DeploymentDiscover','DeploymentCreate','DeploymentSessionFixture','DeploymentProceed','Nodes','RecordDeletePreview','RecordDeleteCommit','RecordRestore','PairRequestCreate','PairComplete','ServerOperation','IdentitySessionFixture','IdentityTrustFixture','ServerIdentityAssessment','ServerIdentityTransition','ConnectionDefaultPreview','LineProfiles')
 CheckUI (@($script:AllRequests|Where-Object {$_.Action -notin $allowed -or $_.ContainsKey('Credential') -or $_.ContainsKey('Password') -or $_.ContainsKey('PrivateKeyPem')}).Count -eq 0) 'Captured worker requests stay within expected fixture signals and exclude credentials'
 foreach($source in $script:LoadedSources){CheckUI ((Get-FileHash -LiteralPath $source.Path -Algorithm SHA256).Hash -ceq $source.SHA256) ('Tested source stayed unchanged: '+$source.File)}
 $passed=$true
}catch{$failure=$_.Exception.Message;throw}
finally{
 StopIntakeTimer;if($script:Window){$script:Window.Close()}
 $requestSummary=@($script:AllRequests|ForEach-Object {[ordered]@{Action=$_.Action;Command=$_.Command;Operation=$_.Operation;RunId=$_.RunId;ServerId=$_.ServerId}})
 $summary=[ordered]@{Passed=$passed;Suite='UI-0.15.0';Checks=$script:Checks.Count;Assertions=@($script:Checks.ToArray());Failure=$failure;LastErrorDialog=$script:LastErrorDialog;WpfRendered=($script:Shots.Count -gt 0);Screenshots=@($script:Shots.ToArray());SourceVersions=@($script:LoadedSources|ForEach-Object {[ordered]@{File=$_.File;SHA256=$_.SHA256}});Requests=$requestSummary;WorkerLaunched=$false;RealActorAttempts=@($script:DeniedActors.ToArray());ProductionAccess=$false;FixtureOnly=$true;BackendAutoSaveVerified=$false;RemoteSignaturesVerified=$false;NetworkMeasured=$false;OutputDirectory=$qa;PowerShellVersion=$PSVersionTable.PSVersion.ToString()}
 [IO.File]::WriteAllText((Join-Path $qa 'ui-015-result.json'),(ConvertTo-Json -InputObject $summary -Depth 12),(New-Object Text.UTF8Encoding($true)))
 $cleanupRoot=SafeLocalPath $script:Root;$marker=Join-Path $cleanupRoot '.owned-ui-015'
 if($cleanupRoot -cne (Join-Path ([IO.Path]::GetTempPath()) ('tc-ui-015-data-'+$testId)) -or -not [IO.File]::Exists($marker) -or [IO.File]::ReadAllText($marker) -cne $testId){throw 'UI fixture cleanup ownership check failed.'}
 Remove-Item -LiteralPath $cleanupRoot -Recurse -Force -ErrorAction Stop
 if($passed){[pscustomobject]@{Passed=$true;Checks=$script:Checks.Count;Screenshots=$script:Shots.Count;WpfRendered=$true;WorkerLaunched=$false;FixtureOnly=$true;BackendAutoSaveVerified=$false;OutputDirectory=$qa}|ConvertTo-Json}
}
