# Executed only by TradeChannel.ps1 -SelfTest. Every worker request is captured,
# never dispatched. Fixtures intentionally do not represent the user's network.
if(-not $script:Smoke -or -not $SelfTest){throw 'Only TradeChannel.ps1 -SelfTest may execute these fixtures.'}
# A second boundary: even an accidental UI launch helper cannot spawn a worker.
function Start-Process {throw 'SelfTest forbids starting any external process.'}
$qa=if($TestOutputDirectory){[IO.Path]::GetFullPath($TestOutputDirectory)}else{Join-Path $script:Root 'screenshots'}
$common=[IO.Path]::GetFullPath([Environment]::GetFolderPath('CommonApplicationData')).TrimEnd('\')+'\'
if(($qa.TrimEnd('\')+'\').StartsWith($common,[StringComparison]::OrdinalIgnoreCase)){throw 'SelfTest output cannot use ProgramData.'}
$liveProduct=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\product')).TrimEnd('\')+'\'
if(($qa.TrimEnd('\')+'\').StartsWith($liveProduct,[StringComparison]::OrdinalIgnoreCase)){throw 'SelfTest output cannot use the live product directory.'}
if(-not $script:Root.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase)){throw 'SelfTest requires an isolated temporary root.'}
$null=New-Item -ItemType Directory -Path $qa -Force
$script:Assertions=New-Object 'System.Collections.Generic.List[string]'
$hk='11111111-1111-1111-1111-111111111111';$us='22222222-2222-2222-2222-222222222222'
function AssertUI {param([bool]$Condition,[string]$Name);if(-not $Condition){throw ('UI assertion failed: '+$Name)};$script:Assertions.Add($Name)}
function SegId {param([string]$Group,[string]$Value);return ('Seg'+$Group+($Value -replace '[^A-Za-z0-9]',''))}
function ClickUI {param([string]$Name);$button=$script:Controls[$Name];if(-not $button){throw ('Control missing: '+$Name)};$button.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))}
function ClickDialog {param([string]$Name);$script:Window.FindName($Name).RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))}
function DialogOpen {return ($script:Window.FindName('Overlay').Visibility -eq 'Visible')}
function Requests {return @($script:Actions|Where-Object {$_.Request})}
function CompleteUI {param($Data,[int]$Index=-1)
 $requests=@(Requests);if($Index -lt 0){$Index=$requests.Count-1};$script:Pending=$null;& $requests[$Index].Complete $Data $requests[$Index].CallbackContext
}
function ScrollToUI {param([string]$Id)
 $script:Window.UpdateLayout();$y=$script:Controls[$Id].TransformToAncestor($script:HostPanel).Transform((New-Object Windows.Point(0,0))).Y
 $script:Window.FindName('Scroll').ScrollToVerticalOffset($y);$script:Window.UpdateLayout()
}
function FailUI {param([string]$Message,[int]$Index=-1)
 $requests=@(Requests);if($Index -lt 0){$Index=$requests.Count-1};$script:Pending=$null;& $requests[$Index].Failed $Message $requests[$Index].CallbackContext
}
function ChooseProviderUI {param([string]$Id,[string]$Control='ProviderChoice')
 $box=$script:Controls[$Control];$item=@($box.Items|Where-Object {$_.Tag -eq $Id})[0];$box.SelectedItem=$item
}
function AssertNoRouteFields {param($Request,[string]$Name)
 foreach($key in @('Exit','NodeId','TradeProviderId','Agents','AgentIds','AgentCustom')){AssertUI (-not $Request.ContainsKey($key)) ($Name+' omits '+$key)}
}
function PendingProviderFixture {
 Fixture;$script:Overview.PolicyVersion=3;$script:Providers.Items[1].Applied=$false;$script:Providers.RequiresUpgrade=$true
 $script:Overview.Providers=@($script:Overview.Providers[0])
}
function Fixture {param([string]$State='Connected',[hashtable]$Extra=@{})
 $script:Pending=$null;$script:Actions.Clear();$script:Checks=$null;$script:LastToast=$null;CloseDialog
 $script:ToastTimer.Stop();$script:Window.FindName('Toast').Visibility='Collapsed'
 $script:ProvidersAt=Get-Date;$script:ProviderReadError=$null;$script:ProviderReports=@{};$script:ProviderNotice=$null;$script:PendingProviderCheck=$null;$script:PendingTrade=$null;$script:ProviderFormOpen=$false
 $script:Prefs=@{Mode='Trading';Exit='HongKong';Daily='Direct';NodeId=$hk;ProviderId='pv-bat';TradeProviderId='pv-bat';Agents='Daily';AgentIds=@(Get-TCAgentCatalog|ForEach-Object {$_.Id});AgentCustom=@();OpenAtLogin=$false}
 $script:Providers=[pscustomobject]@{Items=@(
  [pscustomobject]@{Id='pv-bat';Name='BatVPN';Kind='batvpn';Directory=(Join-Path $script:Root 'clients\BatVPN');DailyPort=10823;TradePort=10823;Registered=$true;Applied=$true;Health=[pscustomobject]@{Healthy=$true;ReasonText='SOCKS 转发检查通过'};ClientState=[pscustomobject]@{TunMode=$false;SnifferReady=$true}},
  [pscustomobject]@{Id='pv-clash';Name='工作用 Clash';Kind='clashverge';Directory=(Join-Path $script:Root 'clients\Clash Verge');DailyPort=7897;TradePort=7898;Registered=$true;Applied=$true;Health=[pscustomobject]@{Healthy=$true;ReasonText='SOCKS 转发检查通过'};ClientState=[pscustomobject]@{TunMode=$false;SystemProxy=$false;ProxyGuard=$false;SnifferReady=$false}}
 );Candidates=@([pscustomobject]@{Name='BatVPN';Kind='batvpn';Directory=(Join-Path $script:Root 'clients\BatVPN');DailyPort=10823;Detected=$true},[pscustomobject]@{Name='Clash Verge';Kind='clashverge';Directory=(Join-Path $script:Root 'clients\Clash Verge');DailyPort=7897;Detected=$true});SelectedProviderId='pv-bat';ActiveProviderName='BatVPN';RequiresUpgrade=$false}
 $script:Nodes=@([pscustomobject]@{id=$hk;name='香港主线';endpoint='203.0.113.10:51820';manifestPath='fixture-hk';status='Registered';Revision=1},[pscustomobject]@{id=$us;name='美国备用';endpoint='198.51.100.20:51820';manifestPath='fixture-us';status='CandidateOnly';Revision=1})
 foreach($n in $script:Nodes){
  $n|Add-Member NoteProperty PreferredProfileId 'Udp' -Force
  $n|Add-Member NoteProperty PreferenceSource 'ConfiguredDefault' -Force
  $n|Add-Member NoteProperty Profiles @([pscustomobject]@{Id='Udp';Mode='Udp';ManifestPath=$n.manifestPath;PreparationState='SyntaxValidated';CandidateSHA256=('A'*64);Validation=$null}) -Force
 }
 $running=($State -eq 'Connected')
 $o=[ordered]@{StateKey=$State;Running=$running;PrimaryAction=$(if($running){'Disconnect'}else{'Connect'});PrimaryEnabled=$true;CanConnect=($State -eq 'Disconnected')
  Mode=$(if($running){'rule'}else{$null});Exit=$(if($running){'hk'}else{$null});Daily=$(if($running){'direct'}else{$null});DailySupported=$true;DesiredMode='Trading';DesiredExit='HongKong';DesiredDaily='Direct';DailyReason=$null;ForeignTunnel=$null
  AgentsSupported=$true;Agents=$(if($running){'Daily'}else{$null});DesiredAgents='Daily';AgentIds=@($script:Prefs.AgentIds);AgentCustom=@();AgentNames=@('Mirasim','Claude Code','Codex','Antigravity','CC Switch','Claude 网页版','ChatGPT 网页版','Gemini 网页版')
  Provider=[pscustomobject]@{Name='BatVPN';Configured=$true;Port=10823;Listening=$true;IdentityVerified=$true;Healthy=$true;Reason=$null;ReasonText=''};PolicyVersion=4;UpgradeAvailable=$false
  ProviderId='pv-bat';TradeProviderId='pv-bat';Providers=@([pscustomobject]@{Id='pv-bat';Name='BatVPN';Kind='batvpn';Tag='provider';TradeTag='provider-trade';Port=10823;TradePort=10823},[pscustomobject]@{Id='pv-clash';Name='工作用 Clash';Kind='clashverge';Tag='provider2';TradeTag='provider2-trade';Port=7897;TradePort=7898})
  ConnectedSince=(Get-Date).AddMinutes(-133).ToString('o');ProxyEvents=0;LastProxyKind=$null;LastProxyAt=$null;LastProxySummary=$null
  TradePrograms=@('NinjaTrader.exe');TradeDomains=@('tradingview.com','tradingview-widget.com','tradovate.com','tradovateapi.com','ninjatrader.com');AuxDomains=@('launchdarkly.com','statsigapi.net')
  Connections=42;NodeName='香港主线';ManifestPath='fixture-hk';GuardState='Protected';BootRestartDetected=$false;ProviderConfigured=$true;NinjaRunning=$false;Error='';NodeId=$hk}
 foreach($k in $Extra.Keys){$o[$k]=$Extra[$k]}
 $script:Overview=[pscustomobject]$o
}
function Snapshot {param([string]$Name)
 $script:Footer.Text='界面验证 · 模拟状态，不改变实际网络';$script:Window.FindName('FooterContext').Text=$script:Version+' / UI TEST'
 $script:Window.UpdateLayout();$null=$script:Window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Render)
 $content=$script:Window.Content;$width=[int]$content.ActualWidth;$height=[int]$content.ActualHeight
 $bitmap=New-Object Windows.Media.Imaging.RenderTargetBitmap($width,$height,96,96,[Windows.Media.PixelFormats]::Pbgra32);$bitmap.Render($content)
 $encoder=New-Object Windows.Media.Imaging.PngBitmapEncoder;$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap));$stream=[IO.File]::Open((Join-Path $qa ($Name+'.png')),[IO.FileMode]::Create)
 try{$encoder.Save($stream)}finally{$stream.Dispose()}
 AssertUI ($width -ge 990 -and $height -ge 670) ('render '+$Name)
}
function IsOn {param([string]$Id);return ($script:Controls[$Id].Style -eq $script:Window.FindResource('SegOn'))}

# Producer-backed fixtures shared by the standalone supplemental UI harness.
# Only inert files under the isolated root and supplied sensor/context data run.
function InitializeUI0120ProtocolFixtures {
 if(-not $script:Root.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase)){throw 'Protocol UI assets require a temporary root.'}
 $script:UIFixtureProtocol=Import-Module (Join-Path $script:PackageRoot 'ProtocolSelection.psm1') -PassThru -DisableNameChecking -Global
 $script:Fixture0120Network=[pscustomobject]@{Status='Available';Fingerprint=('F'*64)}
 & $script:UIFixtureProtocol {param($Context)
  $script:UIFixtureContext=$Context
  $script:NetworkContextReader={param($Binding)$script:UIFixtureContext}
 } $script:Fixture0120Network
 $assetRoot=Join-Path $script:Root 'ui-protocol-assets';$null=[IO.Directory]::CreateDirectory($assetRoot)
 $engine=Join-Path $assetRoot 'sing-box.exe';$wg=Join-Path $assetRoot 'wg.exe'
 foreach($path in @($engine,$wg)){if(-not [IO.File]::Exists($path)){[IO.File]::WriteAllText($path,'Inert UI fixture. Never launch.',(New-Object Text.UTF8Encoding($true)))}}
 $script:Fixture0120Udp=Join-Path $assetRoot 'Udp.manifest.json';$script:Fixture0120Tcp=Join-Path $assetRoot 'Tcp.manifest.json'
 foreach($id in @('Udp','Tcp')){
  $manifestPath=Join-Path $assetRoot ($id+'.manifest.json');if([IO.File]::Exists($manifestPath)){continue}
  $server=[Convert]::ToBase64String([byte[]](65..96));$client=[Convert]::ToBase64String([byte[]](1..32))
  $peer=[ordered]@{public_key=$server;address='127.0.0.1';port=51820;allowed_ips=@('0.0.0.0/0')}
  $endpoint=[ordered]@{type='wireguard';tag='hk';system=$false;address=@('10.78.0.4/32');private_key=[Convert]::ToBase64String([byte[]](33..64));peers=@($peer);mtu=1400}
  $transport=$null;$outbounds=@([ordered]@{type='direct';tag='direct'})
  if($id -eq 'Tcp'){
   $endpoint.detour='tc-transport';$transport=[ordered]@{Type='tcp-reality';Server='127.0.0.1';Port=443;Uuid='aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';RealityPublicKey='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';RealityShortId='1234567890abcdef';ServerName='fixture.example.invalid'}
   $outbounds+=,[ordered]@{type='vless';tag='tc-transport';server='127.0.0.1';server_port=443;uuid=$transport.Uuid;tls=[ordered]@{enabled=$true;server_name=$transport.ServerName;reality=[ordered]@{enabled=$true;public_key=$transport.RealityPublicKey;short_id=$transport.RealityShortId}}}
  }
  $config=[ordered]@{inbounds=@([ordered]@{type='mixed';tag='probe';listen='127.0.0.1';listen_port=17890;users=@([ordered]@{username='ui-fixture';password=('fixture-only-'+('X'*32))})});endpoints=@($endpoint);outbounds=$outbounds;dns=[ordered]@{servers=@([ordered]@{type='udp';tag='dns-direct';server='127.0.0.1'})};route=[ordered]@{final='hk'}}
  $candidate=Join-Path $assetRoot ($id+'.candidate.json');$probe=Join-Path $assetRoot ($id+'.probe.json')
  foreach($path in @($candidate,$probe)){[IO.File]::WriteAllText($path,($config|ConvertTo-Json -Depth 30),(New-Object Text.UTF8Encoding($false)))}
  $manifest=[ordered]@{SchemaVersion=1;node_id='11111111-1111-1111-1111-111111111111';TCLineId='11111111-1111-1111-1111-111111111111';TCProfileId=$id;TCManagedNodeId='11111111-1111-1111-1111-111111111111';TCProfileRevision=2;CreatedAt='2026-01-01T00:00:00Z';ServerPublicKey=$server;ClientPublicKey=$client;ClientAddress='10.78.0.4';ServerEndpoint='127.0.0.1:51820';CandidatePath=$candidate;CandidateSHA256=(Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash;ProbePath=$probe;ProbeSHA256=(Get-FileHash -LiteralPath $probe -Algorithm SHA256).Hash;EnginePath=$engine;EngineSHA256=(Get-FileHash -LiteralPath $engine -Algorithm SHA256).Hash;WgPath=$wg;Transport=$transport;SyntaxValidated=$true;DeploymentApproved=$false;FixtureOnly=$true}
  [IO.File]::WriteAllText($manifestPath,($manifest|ConvertTo-Json -Depth 30),(New-Object Text.UTF8Encoding($true)))
 }
}
function ReadUI0120Json {param([string]$Path)
 $json=[IO.File]::ReadAllText($Path)
 if((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')){ConvertFrom-Json -InputObject $json -DateKind String}else{ConvertFrom-Json -InputObject $json}
}
function NewUI0120Evidence {param($Profile,[string]$Status,[DateTimeOffset]$At=[DateTimeOffset]::UtcNow)
 $manifest=ReadUI0120Json $Profile.ManifestPath;$passed=($Status -eq 'Passed');$physical=($Status -notin @('Inconclusive','NotTested'))
 $stamp=if($Status -eq 'Stale'){$At.AddDays(-1)}else{$At}
 $raw=[pscustomobject]@{SchemaVersion=2;FixtureOnly=$true;Status=$(if($Status -eq 'Stale'){'Passed'}else{$Status});Code=$(switch($Status){'Passed'{'CandidateReachabilityVerified'}'Failed'{'CandidateForwardingFailed'}'Inconclusive'{'ForwardingPassedPhysicalPathUnverified'}'Blocked'{'ActiveIdentity'}'NotTested'{'NotTested'}default{'CandidateReachabilityVerified'}});NodeId=$manifest.TCLineId;ProfileId=$Profile.Id;CandidateHash=$Profile.CandidateSHA256;ManifestHash=$Profile.ManifestSHA256;EngineSHA256=$manifest.EngineSHA256;CheckedAtUtc=$stamp.ToString('o');CleanupComplete=$true;ForwardingPassed=($passed -or $Status -in @('Stale','Inconclusive'));ExpectedExitSource='ServerVerifiedTlsTrace';ExpectedExitIPv4='127.0.0.2';ObservedExitIPv4='127.0.0.2';Checks=@([pscustomobject]@{Name='AddressHttps';Status=$(if($Status -eq 'Failed'){'Failed'}else{'Passed'})},[pscustomobject]@{Name='DomainDnsHttps';Status=$(if($Status -eq 'Failed'){'Failed'}else{'Passed'})});Samples=@();Metrics=$null;PathEvidence=[pscustomobject]@{Kind='BoundInterfaceObserved';Verified=$physical;EligibleForRecommendation=$physical;NetworkFingerprint=$script:Fixture0120Network.Fingerprint;Binding=[pscustomobject]@{Scope='UIFixtureOnly';InterfaceId='fixture-only'}}}
 ConvertTo-TCProtocolEvidence -Result $raw -Profile $Profile -NetworkContext $script:Fixture0120Network -Now $At
}
function SaveUI0120Default {param($Line,[string]$ProfileId,[switch]$Manual,[DateTimeOffset]$At=[DateTimeOffset]::UtcNow)
 $profile=@($Line.Profiles|Where-Object Id -eq $ProfileId)[0];$manifest=ReadUI0120Json $profile.ManifestPath
 $saved=New-TCSavedConnectionPreference -LineId $Line.LineId -Profile $profile -Manifest $manifest -Profiles @($Line.Profiles) -Recommendation $Line.Recommendation -NetworkContext $script:Fixture0120Network -ManualChoice:$Manual -LineRevision $Line.Revision -Now $At
 $Line|Add-Member NoteProperty SavedConnectionPreference $saved -Force
 $Line.PreferredProfileId=$saved.ProfileId;$Line.PreferenceSource=$saved.Source
}
function NewUI0120ComparisonEvidence {param([object[]]$Profiles,[ValidateSet('Performance','Stability','PolicyDefault')][string]$Kind,[string]$Winner='Tcp',[DateTimeOffset]$At=[DateTimeOffset]::UtcNow)
 $comparison=Import-Module (Join-Path $script:PackageRoot 'ProtocolComparison.psm1') -PassThru -DisableNameChecking
 & $comparison {
  param($Root,$Profiles,$Context,$Kind,$Winner,$At)
  $script:UIFixture=[pscustomobject]@{Root=$Root;Profiles=$Profiles;Context=$Context;Kind=$Kind;Winner=$Winner;At=$At;FailureInjected=$false}
  function script:Prepare-TCProtocolComparisonBinding {param($Root,$NodeId,$InterfaceIndex)
   if($Root -cne $script:UIFixture.Root){throw 'UI comparison refuses external roots.'}
   [pscustomobject]@{LineId=$NodeId;State='Ready';Code='BindingsPrepared';Results=@($script:UIFixture.Profiles|ForEach-Object {[pscustomobject]@{ProfileId=$_.Id;BindingState='Reused';CandidateSHA256=$_.CandidateSHA256;ManifestSHA256=$_.ManifestSHA256}})}
  }
  function script:Get-TCProtocolComparisonContext {$script:UIFixture.Context}
  function script:Get-TCProtocolComparisonProfile {param($Root,$NodeId,$ProfileId)if($Root -cne $script:UIFixture.Root){throw 'UI profile refuses external roots.'};@($script:UIFixture.Profiles|Where-Object Id -eq $ProfileId)[0]}
  function script:Invoke-TCProtocolComparisonProbe {
   param($Root,$NodeId,$ProfileId,$ExpectedExitIPv4,$ExpectedExitSource,$CancellationPath,$TimeoutSeconds)
   $f=$script:UIFixture;if($Root -cne $f.Root){throw 'UI sensor refuses external roots.'}
   $p=@($f.Profiles|Where-Object Id -eq $ProfileId)[0];$m=[IO.File]::ReadAllText($p.ManifestPath)|ConvertFrom-Json
   $failed=($f.Kind -eq 'Stability' -and $ProfileId -ne $f.Winner -and -not $f.FailureInjected)
   if($failed){$f.FailureInjected=$true}
   $duration=if($f.Kind -eq 'PolicyDefault'){100}elseif($ProfileId -eq $f.Winner){60}else{200};$samples=@()
   foreach($round in 1..3){foreach($t in @(@('AddressHttps','https://1.1.1.1/cdn-cgi/trace'),@('DomainDnsHttps','https://www.cloudflare.com/cdn-cgi/trace'))){
    $bad=($failed -and $round -eq 2 -and $t[0] -eq 'DomainDnsHttps')
    $samples+=,[pscustomobject]@{Name=$t[0];TargetUrl=$t[1];Round=$round;Required=$true;Attempted=$true;RequestBudgetSeconds=6;Status=$(if($bad){'Failed'}else{'Passed'});Code=$(if($bad){'ProbeTimeout'}else{'HttpsReached'});DurationMs=$duration;TlsVerified=(-not $bad);ObservedExitIPv4=$(if(-not $bad){$ExpectedExitIPv4}else{$null});HttpStatus=200}
   }}
   $samples+=,[pscustomobject]@{Name='ChatGPTWeb';TargetUrl='https://chatgpt.com/';Round=1;Required=$false;Attempted=$true;RequestBudgetSeconds=6;Status='UserVerificationRequired';Code='HttpForbidden';HttpStatus=403;TlsVerified=$true;DurationMs=99}
   [pscustomobject]@{SchemaVersion=2;FixtureOnly=$true;NodeId=$NodeId;ProfileId=$ProfileId;CandidateHash=$p.CandidateSHA256;ManifestHash=$p.ManifestSHA256;EngineSHA256=$m.EngineSHA256;RunId=[guid]::NewGuid().ToString('D');ProbeId=[guid]::NewGuid().ToString('D');Status=$(if($failed){'Failed'}else{'Passed'});Code=$(if($failed){'CandidateForwardingFailed'}else{'CandidateReachabilityVerified'});ForwardingPassed=(-not $failed);ExitServerVerifiedTrace=(-not $failed);ExpectedExitIPv4=$ExpectedExitIPv4;ExpectedExitSource=$ExpectedExitSource;ObservedExitIPv4=$ExpectedExitIPv4;NetworkFingerprint=$f.Context.Fingerprint;SnapshotFingerprint=$f.Context.Fingerprint;CheckedAtUtc=$f.At.ToString('o');CleanupComplete=$true;ContextChanged=$false;NetworkChanged=$false;CancellationRequested=$false;PathEvidence=[pscustomobject]@{Verified=$true;EligibleForRecommendation=(-not $failed);Kind='BoundInterfaceObserved';NetworkFingerprint=$f.Context.Fingerprint;Binding=[pscustomobject]@{Scope='UIFixtureOnly';InterfaceId='fixture-only'}};TransportPath='BoundInterfaceObserved';PathStatus='Passed';Samples=$samples;Metrics=$null;Checks=@();EvidencePath=$null;DurationMs=10}
  }
 } $script:Root $Profiles $script:Fixture0120Network $Kind $Winner $At
 $batch=Invoke-TCProtocolComparison -Root $script:Root -NodeId '11111111-1111-1111-1111-111111111111' -ExpectedExitIPv4 '127.0.0.2' -ExpectedExitSource ServerVerifiedTlsTrace
 if($batch.Status -ne 'Completed'){throw 'UI comparison producer did not complete its fixture schedule.'}
 foreach($profile in $Profiles){$raw=@($batch.Results|Where-Object ProfileId -eq $profile.Id)[0].Result;# Align the aggregate header with the supplied sensor clock before recording evidence.
  $raw.CheckedAtUtc=$At.ToString('o');$raw.Comparison.CheckedAtUtc=$At.ToString('o');$profile.Validation=ConvertTo-TCProtocolEvidence -Result $raw -Profile $profile -NetworkContext $script:Fixture0120Network -Now $At}
}
InitializeUI0120ProtocolFixtures
function Fixture0120 {param([string]$State='Disconnected',[hashtable]$Extra=@{})
 Fixture $State $Extra
 $script:LineProfileUI=$null;$script:ConnectionPreviewUI=$null;$script:AutoTCP=$null;$script:RecoveryResult=$null;$script:Role='client';$script:Step=0
 $script:DeployUI=@{Intent='New';Screen='connect';Run=$null;Reauth=$false;SessionRef=$null;SessionAttached=$false;ManagementMode=$false;Management=$null;PendingManagement=$null;LastPoll=[DateTime]::MinValue;PollError=''}
 $script:Overview.ManifestPath=$script:Fixture0120Udp
}
function NewUI0120Line {param([string]$Udp='Passed',[string]$Tcp='Passed',[ValidateSet('Evidence','Performance','Stability','PolicyDefault')][string]$SelectionKind='Evidence',[string]$Winner='Tcp',[switch]$NoSaved,[DateTimeOffset]$At=[DateTimeOffset]::UtcNow)
 $profiles=@()
 foreach($id in @('Udp','Tcp')){
  $path=if($id -eq 'Udp'){$script:Fixture0120Udp}else{$script:Fixture0120Tcp};$m=ReadUI0120Json $path
  $p=[pscustomobject]@{Id=$id;Mode=$id;ManifestPath=$path;ManifestSHA256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash;CandidateSHA256=$m.CandidateSHA256;ProbeSHA256=$m.ProbeSHA256;EngineSHA256=$m.EngineSHA256;PreparationState='Ready';Revision=2;Validation=$null}
  $p.Validation=NewUI0120Evidence $p $(if($id -eq 'Udp'){$Udp}else{$Tcp}) $At;$profiles+=,$p
 }
 if($SelectionKind -ne 'Evidence'){NewUI0120ComparisonEvidence -Profiles $profiles -Kind $SelectionKind -Winner $Winner -At $At}
 $recommendation=Get-TCProtocolRecommendation -Profiles $profiles -NetworkContext $script:Fixture0120Network -LineId '11111111-1111-1111-1111-111111111111' -Now $At
 $line=[pscustomobject]@{id='11111111-1111-1111-1111-111111111111';LineId='11111111-1111-1111-1111-111111111111';Name='测试单线路';Endpoint='127.0.0.1:51820';manifestPath=$script:Fixture0120Udp;SourceManifestPath=$script:Fixture0120Udp;status='Registered';Profiles=$profiles;PreferredProfileId=$recommendation.PreferredProfileId;PreferenceSource=$recommendation.Source;Recommendation=$recommendation;SavedConnectionPreference=$null;Revision=2}
 if(-not $NoSaved -and $recommendation.Status -eq 'Recommended'){SaveUI0120Default $line $recommendation.RecommendedProfileId -At $At}
 $line
}
function NewUI0120Run {param($Line,[switch]$Legacy)
 # Legacy preparation predates automatic saved-default persistence. New ready
 # fixtures carry the actual preference snapshot and its completed checkpoint.
 $saved=if($Legacy){$null}else{$Line.SavedConnectionPreference}
 [pscustomobject]@{ExperienceVersion=$(if($Legacy){0}else{1});AutoSavedAtUtc=$(if($saved){$saved.SavedAtUtc}else{$null});AttentionRequired=(-not $saved);RunId='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';CandidateNodeId=$Line.LineId;Name=$Line.Name;Stage='ReadyInactive';Status=$(if($saved){'Complete'}else{'Completed'});ProfileProbeState='Completed';Profiles=$Line.Profiles;PreferredProfileId=$Line.PreferredProfileId;SavedConnectionPreference=$saved;PreferenceSource=$Line.PreferenceSource;Recommendation=$Line.Recommendation;Validation=$Line.Profiles[0].Validation;LastError=$null;CandidateManifestPath=$Line.manifestPath;ServerRecordId='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';SessionRef=$null;ProtocolPreparation=[pscustomobject]@{Udp=[pscustomobject]@{ServerPreparation='Configured';LocalPreparation='SyntaxValidated';Error=$null};Tcp=[pscustomobject]@{ServerPreparation='Configured';LocalPreparation='SyntaxValidated';Error=$null}}}
}
function RenderUI0120Run {param($Run)
 $script:DeployUI.Run=$Run;$script:Role='deployment';$script:DeployUI.Reauth=$false;ShowProductDeployment
}
function UI0120Text {
 ($script:Controls.Values|Where-Object {$_ -is [Windows.Controls.TextBlock]}|ForEach-Object {$_.Text}) -join [Environment]::NewLine
}
function AssertUI0120OnlyOutcomeActions {param([string[]]$Expected)
 $buttons=@($script:Controls.Keys|Where-Object {$script:Controls[$_] -is [Windows.Controls.Button]})
 AssertUI (@($buttons|Where-Object {$_ -notin $Expected}).Count -eq 0 -and @($Expected|Where-Object {$_ -notin $buttons}).Count -eq 0) ('completion actions expected: '+($Expected -join ', ')+'; actual: '+(@($buttons|Sort-Object) -join ', '))
}
try{
 $script:Window.Show()
 $script:Window.Width=1180;$script:Window.Height=800
 # Reading and rendering never asks the UI to run a probe or a connection.
 Fixture0120
 $line=NewUI0120Line 'Failed' 'Failed';$run=NewUI0120Run $line;RenderUI0120Run $run
 AssertUI (-not $script:Controls.ContainsKey('DeployConnectRecommended') -and -not (LineRecommendationView $line).CanConnect -and $line.Recommendation.Status -eq 'Unavailable' -and $script:Controls.DeployDefaultLabel.Text -like '*尚未设置*') 'two failed profiles produce no recommended connection button'
 AssertUI ($script:Controls.DeployProfileUdp.Text -like '*未通过*' -and $script:Controls.DeployProfileTcp.Text -like '*未通过*') 'both failed profile results remain visibly failed'
 AssertUI0120OnlyOutcomeActions @('DeployDiagnostics','DeployProbe','DeployLater','DeployPreparedProfiles','DeployCopyDiagnostics')
 AssertUI (@(Requests).Count -eq 0) 'rendering failed completion dispatches nothing'
 Snapshot '01-both-failed'
 ClickUI 'DeployProbe';$r=@(Requests)[0].Request
 AssertUI ($r.Action -eq 'DeploymentProceed' -and $r.Command -eq 'Probe' -and -not $r.ContainsKey('SessionAction')) 'retry uses the existing run probe without server login'
 # A partially proved TCP cannot rescue a failed UDP as an automatic default.
 Fixture0120
 $line=NewUI0120Line 'Failed' 'Inconclusive';RenderUI0120Run (NewUI0120Run $line)
 AssertUI (-not $script:Controls.ContainsKey('DeployConnectRecommended') -and $script:Controls.DeployProfileTcp.Text -like '*检测路径未能核验*') 'failed plus inconclusive gives a concrete reason and no recommendation button'
 Snapshot '02-insufficient-evidence'
 foreach($state in @('Blocked','Stale','NotTested')){
  Fixture0120;$line=NewUI0120Line $state $state;RenderUI0120Run (NewUI0120Run $line)
  AssertUI (-not $script:Controls.ContainsKey('DeployConnectRecommended') -and -not $script:Controls.ContainsKey('DeployRetryTrust')) ($state+' does not imply recommendation or expired SSH credentials')
 }
 # TCP wins from the actual pure selection contract; ignore a stale UDP summary.
 Fixture0120
 $line=NewUI0120Line 'Failed' 'Passed';$run=NewUI0120Run $line;$script:Nodes=@($line);RenderUI0120Run $run
 AssertUI ($line.Recommendation.RecommendedProfileId -eq 'Tcp' -and $script:Controls.DeployDefaultLabel.Text -like '*TCP*' -and $script:Controls.DeployValidationSummary.Text -like 'TCP*通过*') 'TCP recommendation and completion summary refer to the same profile despite old UDP aggregate'
 AssertUI ($script:Controls.DeployProfileUdp.Text -like '*未通过*' -and $script:Controls.DeployProfileTcp.Text -like '*通过*') 'each profile keeps its own result'
 AssertUI0120OnlyOutcomeActions @('DeployConnectRecommended','DeployLeave','DeployDiagnostics','DeployPreparedProfiles','DeployCopyDiagnostics')
 AssertUI (@(Requests).Count -eq 0) 'recommendation never auto-probes or auto-connects'
 Snapshot '03-tcp-recommended'
 # NEW auto-saved completion navigates away without a Save worker request.
 ClickUI 'DeployLeave';$r=@(Requests)[0].Request
 AssertUI ($run.ExperienceVersion -eq 1 -and $run.AutoSavedAtUtc -and $r.Action -eq 'Nodes' -and @(Requests).Count -eq 1 -and $script:Page -eq 'nodes' -and @(Requests|Where-Object {$_.Request.Action -eq 'DeploymentProceed' -and $_.Request.Command -eq 'Save'}).Count -eq 0) 'new saved completion later action only reads lines, never saves again or connects'
 # The unsaved legacy checkpoint still uses the real Save callback contract.
 Fixture0120;$legacyLine=NewUI0120Line 'Failed' 'Passed' -NoSaved;$legacyRun=NewUI0120Run $legacyLine -Legacy;RenderUI0120Run $legacyRun
 AssertUI ($legacyRun.ExperienceVersion -eq 0 -and -not $legacyRun.AutoSavedAtUtc -and -not $legacyRun.SavedConnectionPreference -and $script:Controls.ContainsKey('DeployLater') -and -not $script:Controls.ContainsKey('DeployLeave')) 'unsaved legacy preparation retains its explicit Save action'
 ClickUI 'DeployLater';$r=@(Requests)[0].Request
 AssertUI ($r.Action -eq 'DeploymentProceed' -and $r.Command -eq 'Save' -and $r.RunId -eq $legacyRun.RunId -and $r.Count -eq 3 -and @(Requests).Count -eq 1 -and $script:Page -eq 'setup') 'legacy completion waits for original-run Save without starting a connection'
 $saved=NewUI0120Run $legacyLine -Legacy;$saved.Status='Complete';$saved|Add-Member NoteProperty SavedForLaterAtUtc ([DateTimeOffset]::UtcNow.ToString('o'))
 CompleteUI $saved
 AssertUI ($script:Page -eq 'nodes' -and $script:DeployUI.Run.Status -eq 'Complete' -and $script:DeployUI.Run.Stage -eq 'ReadyInactive' -and $script:DeployUI.Run.SavedForLaterAtUtc -and @(Requests|Where-Object {$_.Request.Action -like 'Connection*' -or $_.Request.ContainsKey('SessionAction')}).Count -eq 0) 'legacy saved Complete remains inactive and returns to lines without activation'
 Fixture0120;$script:Nodes=@($line);$run=NewUI0120Run $line;RenderUI0120Run $run
 ClickUI 'DeployConnectRecommended';$r=@(Requests)[0].Request
 AssertUI ($r.Action -eq 'ConnectionDefaultPreview' -and $r.LineId -eq $hk -and -not $r.ContainsKey('ProfileId')) 'completion uses default preview API without hardcoding UDP or radio selection'
 PreviewDefaultLineConnection $hk
 AssertUI (@(Requests).Count -eq 1) 'a pending preview cannot be requested twice'
 CompleteUI ([pscustomobject]@{LineId=$hk;ProfileId='Tcp';PreviewToken='fixture-bound-token';CanSwitch=$true;Recommendation=$line.Recommendation;SavedConnectionPreference=$line.SavedConnectionPreference;SelectionMode='SavedDefault';DefaultSource=$line.SavedConnectionPreference.Source})
 AssertUI ((DialogOpen) -and @(Requests).Count -eq 1 -and $script:Window.FindName('DialogBody').Text -like '*TCP*') 'preview shows TCP and waits for explicit confirmation'
 Snapshot '04-preview-confirmation'
 ClickDialog 'DialogCancel'
 AssertUI (@(Requests).Count -eq 1) 'cancelling a recommended connection submits nothing'
 ClickUI 'DeployConnectRecommended'
 CompleteUI ([pscustomobject]@{LineId=$hk;ProfileId='Tcp';PreviewToken='fixture-second-token';CanSwitch=$true;Recommendation=$line.Recommendation;SavedConnectionPreference=$line.SavedConnectionPreference;SelectionMode='SavedDefault';DefaultSource=$line.SavedConnectionPreference.Source})
 $script:DeployUI.Run.Recommendation.RecommendedProfileId='Udp'
 ClickDialog 'DialogConfirm'
 $r=@(Requests)[-1].Request
 AssertUI ($r.Action -eq 'ConnectionSwitchCommit' -and $r.LineId -eq $hk -and $r.ProfileId -eq 'Tcp' -and $r.PreviewToken -eq 'fixture-second-token') 'confirmed commit stays bound to shown preview after recommendation changes'
 ClickDialog 'DialogConfirm'
 AssertUI (@(Requests|Where-Object {$_.Request.Action -eq 'ConnectionSwitchCommit'}).Count -eq 1) 'confirmation cannot submit twice'
 # Contract errors: no token, wrong line, missing CanSwitch, and stale evidence.
 foreach($bad in @(
  [pscustomobject]@{LineId=$hk;ProfileId='Tcp';CanSwitch=$true;PreviewToken=$null},
  [pscustomobject]@{LineId=$us;ProfileId='Tcp';CanSwitch=$true;PreviewToken='bad-line'},
  [pscustomobject]@{LineId=$hk;ProfileId='Tcp';PreviewToken='missing-can-switch'},
  [pscustomobject]@{LineId=$hk;ProfileId='Other';CanSwitch=$true;PreviewToken='bad-profile'}
 )){
  Fixture0120;PreviewDefaultLineConnection $hk;CompleteUI $bad
  AssertUI ((DialogOpen) -and $script:Window.FindName('DialogConfirm').Content -eq '知道了' -and @(Requests).Count -eq 1) 'malformed preview remains an error, never a commit approval'
 }
 Fixture0120;$line=NewUI0120Line -At ([DateTimeOffset]::UtcNow.AddDays(-1));$view=LineRecommendationView $line;RenderUI0120Run (NewUI0120Run $line)
 AssertUI ($view.CanConnect -and -not $view.RecommendationCurrent -and $view.OldRecommendationLabel -like '*已过期*' -and $script:Controls.ContainsKey('DeployConnectRecommended') -and $script:Controls.DeployConnectRecommended.Content -like '*UDP*检查*') 'expired original evidence retains explicit saved default and is never a current recommendation'
 Fixture0120;$line=NewUI0120Line 'Failed' 'Passed';$line.Profiles[1].CandidateSHA256='C'*64;RenderUI0120Run (NewUI0120Run $line)
 AssertUI (-not $script:Controls.ContainsKey('DeployConnectRecommended') -and -not (LineRecommendationView $line).CanConnect -and $script:Controls.DeployRecommendationReason.Text -like '*配置*核对*') 'changed configuration cannot use old recommendation evidence'
 Fixture0120;$line=NewUI0120Line 'Failed' 'Passed' -NoSaved;$runtimeResult=$line.Profiles[1].Validation.Result;foreach($flag in @('ExitHttp','DnsHttps','ExitVerified')){$runtimeResult|Add-Member NoteProperty $flag $true -Force};$line.Profiles[1].Validation=ConvertTo-TCProtocolEvidence -Result $runtimeResult -Profile $line.Profiles[1] -NetworkContext $script:Fixture0120Network -Origin Runtime;$line.Recommendation=Get-TCProtocolRecommendation -Profiles $line.Profiles -NetworkContext $script:Fixture0120Network -LineId $hk;RenderUI0120Run (NewUI0120Run $line)
 AssertUI (-not $script:Controls.ContainsKey('DeployConnectRecommended') -and $script:Controls.DeployProfileTcp.Text -like '*仅当前会话*' -and $line.Profiles[1].Validation.Status -eq 'Passed' -and -not $line.Profiles[1].Validation.EligibleForAutomaticSelection) ('runtime origin contract: connect='+$script:Controls.ContainsKey('DeployConnectRecommended')+'; text='+$script:Controls.DeployProfileTcp.Text+'; status='+$line.Profiles[1].Validation.Status+'; origin='+$line.Profiles[1].Validation.Origin+'; eligible='+$line.Profiles[1].Validation.EligibleForAutomaticSelection+'; recommendation='+$line.Recommendation.Status)
 Fixture0120;$line=NewUI0120Line 'Failed' 'Passed' -NoSaved;$line.Profiles[1].Validation.EligibleForAutomaticSelection=$false;RenderUI0120Run (NewUI0120Run $line)
 AssertUI (-not $script:Controls.ContainsKey('DeployConnectRecommended') -and -not (LineRecommendationView $line).CanConnect -and -not $line.SavedConnectionPreference) 'Passed without eligibility gives its actual qualification reason'
 Fixture0120;$line=NewUI0120Line 'Failed' 'Passed' -NoSaved;$line.Profiles[1].Validation.ProfileId='Udp';RenderUI0120Run (NewUI0120Run $line)
 AssertUI (-not $script:Controls.ContainsKey('DeployConnectRecommended') -and -not (LineRecommendationView $line).CanConnect -and -not $line.SavedConnectionPreference) 'mismatched validation profile cannot produce a recommended button'
 # Flow persists per-mode ValidationProfiles rather than a Run.Profiles list.
 Fixture0120;$line=NewUI0120Line 'Failed' 'Passed';$run=NewUI0120Run $line
 $run.PSObject.Properties.Remove('Profiles');$run.PSObject.Properties.Remove('PreferredProfileId')
 $run|Add-Member NoteProperty ValidationProfiles ([pscustomobject]@{Udp=$line.Profiles[0].Validation;Tcp=$line.Profiles[1].Validation})
 RenderUI0120Run $run
 AssertUI ($script:Controls.ContainsKey('DeployConnectRecommended') -and $script:Controls.DeployProfileTcp.Text -like '*通过*' -and $run.SavedConnectionPreference.Provenance.Recommendation.RecommendedProfileId -eq 'Tcp') 'actual Flow ValidationProfiles preserves prepared TCP results and original saved provenance'
 Snapshot '10-flow-contract-completion'
 # Policy default and user default are explicitly different sources.
 Fixture0120;$line=NewUI0120Line;RenderUI0120Run (NewUI0120Run $line)
 AssertUI ($script:Controls.DeployDefaultLabel.Text -like '*UDP*' -and $line.SavedConnectionPreference.Source -eq 'PolicyDefault' -and $script:Controls.DeployRecommendationReason.Text -like '*策略选择*未证明最快*') 'equally eligible profiles label UDP as policy default without speed claim'
 Snapshot '05-policy-default'
 $line.Recommendation=Get-TCProtocolRecommendation -Profiles $line.Profiles -RequestedMode Tcp -NetworkContext $script:Fixture0120Network -LineId $hk;$line.PreferredProfileId='Tcp';$line.PreferenceSource='UserChoice';SaveUI0120Default $line Tcp -Manual;RenderUI0120Run (NewUI0120Run $line)
 AssertUI ($null -eq $line.Recommendation.RecommendedProfileId -and $script:Controls.DeployConnectRecommended.Content -like '*TCP*检查*' -and $script:Controls.DeployDefaultLabel.Text -like '*下次默认方式*TCP*' -and $script:Controls.DeployRecommendationReason.Text -like '*手动指定*' -and $line.SavedConnectionPreference.Provenance.Kind -eq 'ManualChoice') 'UserChoice resolves PreferredProfileId without inventing an automatic recommendation'
 # Old PathValidation + nested Result failures, unknown and runtime origins.
 Fixture0120
 $line=NewUI0120Line 'Failed' 'Failed';$line.Profiles[0].Validation=[pscustomobject]@{PathValidation='Failed';Result=[pscustomobject]@{Status='Failed';Code='ForwardingFailed'}}
 RenderUI0120Run (NewUI0120Run $line)
 AssertUI ($script:Controls.DeployProfileUdp.Text -like '*最近检查未通过*' -and $script:Controls.DeployProfileUdp.Text -notlike '*待验证*') 'old nested Failed stays failed in actual WPF text'
 $script:Nodes=@($line);ShowNodes
 AssertUI (-not $script:Controls.ContainsKey('Node'+$hk.Replace('-','')) -and -not $script:Controls.ContainsKey('Proto'+$hk.Replace('-',''))) 'both failed line card offers neither recommendation nor unnecessary TCP preparation'
 Snapshot '06-failed-line-card'
 # Local pending/running checks progress through Poll, not another automatic Probe.
 foreach($stage in @('ReadyInactive','CheckingProfiles')){
  Fixture0120;$line=NewUI0120Line 'NotTested' 'NotTested';$run=NewUI0120Run $line;$run.Stage=$stage;$run.Status='Running';$run.ProfileProbeState='Pending'
  RenderUI0120Run $run
  AssertUI ($script:Controls.ContainsKey('DeployCheckProgress') -and -not $script:Controls.ContainsKey('DeployProbe') -and -not $script:Controls.ContainsKey('DeployRetryTrust')) ($stage+' shows automatic check progress without Probe/login actions')
  AssertUI (@(Requests).Count -eq 0) 'rendering pending state does not start another probe'
  PollDeploymentRunUI
  AssertUI (@(Requests)[0].Request.Action -eq 'DeploymentPoll') 'background completion is continued only by Flow Poll'
  $ready=NewUI0120Run (NewUI0120Line 'Failed' 'Passed');CompleteUI $ready
  AssertUI ($script:Controls.ContainsKey('DeployConnectRecommended') -and @(Requests).Count -eq 1) 'Poll completes directly on recommendation without extra pages or actions'
 }
 Fixture0120;$run=NewUI0120Run (NewUI0120Line 'NotTested' 'NotTested');$run.Stage='CheckingProfiles';$run.ProfileProbeState='Running';RenderUI0120Run $run
 Snapshot '07-checking-profiles'
 PollDeploymentRunUI;FailUI '临时状态读取错误'
 AssertUI ($script:Controls.ContainsKey('DeployRetryStatus') -and -not $script:Controls.ContainsKey('DeployRetryTrust') -and $script:DeployUI.Run.Stage -eq 'CheckingProfiles') 'poll error keeps progress and offers status retry without forcing SSH login'
 Fixture0120;$run=NewUI0120Run (NewUI0120Line 'NotTested' 'NotTested');$run.ProfileProbeState='Interrupted';RenderUI0120Run $run
 AssertUI ($script:Controls.ContainsKey('DeployProbe') -and -not $script:Controls.ContainsKey('DeployConnectRecommended')) 'interrupted probe keeps data and offers a bounded retry'
 # Restore local progress without an authenticated management session.
 Fixture0120;ResumeProductDeployment 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
 $run=NewUI0120Run (NewUI0120Line 'NotTested' 'NotTested');$run.Stage='CheckingProfiles';$run.ProfileProbeState='Running'
 CompleteUI $run;CompleteUI ([pscustomobject]@{Servers=@()})
 AssertUI (-not $script:DeployUI.Reauth -and $script:Controls.ContainsKey('DeployCheckProgress')) 'resuming local profile checks never requests renewed authorization'
 # Active legacy UDP: IDs + runtime evidence bind to the current session.
 Fixture0120 'Connected'
 $legacy=[pscustomobject]@{id=$hk;Name='旧 UDP 主线';Endpoint='203.0.113.10:51820';manifestPath=$script:Fixture0120Udp;status='Registered'}
 $script:Nodes=@($legacy)
 $runtime=[pscustomobject]@{Status='Passed';Code='RuntimeForwardingPassed';CheckedAt=[DateTimeOffset]::UtcNow.ToString('o');ConfigHash=('A'*64);SessionId='fixture-session';ForwardingPassed=$true;ProfileId='Udp';LineId=$hk}
 $script:Overview|Add-Member NoteProperty RuntimeValidation $runtime -Force
 foreach($pair in @(@('SessionId','fixture-session'),@('ConfigHash',('A'*64)),@('ActiveLineId',$hk),@('ActiveProfileId','Udp'))){$script:Overview|Add-Member NoteProperty $pair[0] $pair[1] -Force}
 ShowNodes
 AssertUI ($script:Controls[('NodeStatus'+$hk.Replace('-',''))].Text -eq '交易使用中 · UDP · 本次连接检查通过') 'legacy active UDP uses existing manifest binding and bound runtime evidence'
 AssertUI (-not $script:Controls.ContainsKey('DiagNode'+$hk.Replace('-',''))) 'active line is not instructed to repeat its completed checks'
 Snapshot '08-active-legacy-udp'
 ShowHome
 AssertUI ($script:Controls.TradeLaneStatus.Text -eq '交易使用中 · UDP' -and $script:Controls.TradeLaneEvidence.Text -like '*连接时网络检查通过*') 'overview separates current usage from bound connection-time validation'
 # Approved clone paths differ; trusted Active IDs win over stale preference/path.
 $line=NewUI0120Line;$script:Nodes=@($line);$script:Overview.ManifestPath=Join-Path $script:Root 'approved-clone.manifest'
 $script:Overview|Add-Member NoteProperty ActiveLineId $hk -Force;$script:Overview|Add-Member NoteProperty ActiveProfileId 'Tcp' -Force
 $runtime.ProfileId='Tcp';$runtime.ConfigHash='B'*64;$script:Overview.ConfigHash='B'*64
 ShowNodes
 AssertUI ($script:Controls[('NodeStatus'+$hk.Replace('-',''))].Text -eq '交易使用中 · TCP · 本次连接检查通过') 'approved-clone identity reports active TCP instead of source UDP'
 $other=NewUI0120Line;$other.id=$us;$other.LineId=$us;$script:Nodes=@($other,$line);ShowNodes
 $cards=@($script:HostPanel.Children|Where-Object {$_.Name -like 'NodeCard*'})
 AssertUI ($cards.Count -eq 2 -and $cards[0].Name -eq ('NodeCard'+$hk.Replace('-',''))) 'active line is first even when stored node order puts it last'
 $script:Nodes=@($line)
 $runtime.Status='Failed';ShowNodes
 AssertUI ($script:Controls[('NodeStatus'+$hk.Replace('-',''))].Text -like '*TCP · 检查未通过') 'active failed runtime evidence is never pending validation'
 $runtime.Status='Running';ShowNodes
 AssertUI ($script:Controls[('NodeStatus'+$hk.Replace('-',''))].Text -like '*TCP · 检查中') 'active ongoing runtime check is explicit'
 $runtime.Status='Passed';$runtime.ProfileId='Udp';ShowNodes
 AssertUI ($script:Controls[('NodeStatus'+$hk.Replace('-',''))].Text -notlike '*本次连接检查通过*') 'another profile runtime result cannot authorize the active TCP label'
 $runtime.ProfileId='Tcp';$script:Overview|Add-Member NoteProperty SessionId 'new-fixture-session' -Force;ShowNodes
 AssertUI ($script:Controls[('NodeStatus'+$hk.Replace('-',''))].Text -notlike '*本次连接检查通过*') 'old session evidence cannot pass the new current session'
 $script:Overview.PSObject.Properties.Remove('SessionId')
 $script:Overview.ActiveLineId=$us
 AssertUI (-not (NodeHasActiveProfile $line)) 'explicit active line identity overrides coincident old paths'
 # Diagnostic success is a continue action; errors never force adding TCP.
 Fixture0120 'Connected';$script:Nodes=@((NewUI0120Line));$script:RecoveryContext=@{Id=$hk;Message='上次外网检查失败'}
 $script:RecoveryResult=[pscustomobject]@{Code='ActiveForwardingPassed';Summary='当前实际出口已通过检查';Checks=@();CanPrepareTcp=$true}
 ShowConnectionRecoveryPage
 AssertUI ($script:Controls.ContainsKey('RecoveryContinue') -and -not $script:Controls.ContainsKey('RecoveryPrepareTcp') -and -not $script:Controls.ContainsKey('RecoveryRetry') -and -not $script:Controls.ContainsKey('RecoveryBack')) 'diagnostic success offers only continue using even if an old CanPrepareTcp flag is true'
 Snapshot '09-diagnostic-success'
 $script:Actions.Clear();ClickUI 'RecoveryContinue'
 AssertUI (@(Requests).Count -eq 1 -and @(Requests)[0].Request.Action -eq 'Overview') 'continue using only refreshes overview'
 $script:RecoveryResult=[pscustomobject]@{Code='ActiveForwardingUnverified';Summary='转发未通过';Checks=@();CanPrepareTcp=$true};ShowConnectionRecoveryPage
 AssertUI (-not $script:Controls.ContainsKey('RecoveryPrepareTcp') -and $script:Controls.ContainsKey('RecoveryRetry')) 'two prepared configs with failed checks never imply missing TCP'
 $incomplete=NewUI0120Line 'Passed' 'NotTested';$incomplete.Profiles[1].PreparationState='Missing'
 AssertUI (-not (LineNeedsBackupPreparation $incomplete)) 'new deployment recommendation never exposes a legacy backup-repair action'
 $script:Nodes=@($legacy);ShowConnectionRecoveryPage
 AssertUI (-not $script:Controls.ContainsKey('RecoveryPrepareTcp') -and -not $script:Controls.ContainsKey('ServerPassword')) 'legacy missing configuration stays out of daily failure recovery'
 $script:Actions.Clear();ShowConnectionRecovery $hk '';FailUI '诊断未取得结果'
 AssertUI (-not $script:Controls.ContainsKey('RecoveryPrepareTcp')) 'diagnostics errors cannot invent a TCP requirement'
 # Overview connect honors recommendation preview rather than stale Prefs.ProfileId.
 Fixture0120;$line=NewUI0120Line 'Failed' 'Passed';$script:Nodes=@($line);$script:Prefs.ProfileId='Udp';ShowHome;ClickUI 'Primary'
 AssertUI (@(Requests).Count -eq 1 -and @(Requests)[0].Request.Action -eq 'ConnectionDefaultPreview' -and -not @(Requests)[0].Request.ContainsKey('ProfileId')) 'overview connection ignores stale selected profile and asks Runtime for default preview'
 . (Join-Path $PSScriptRoot 'Test-0110UI.ps1')
 # Layout at supported minimum; actual WPF tree, screenshots and bounds.
 Fixture0120;$script:Window.Width=1000;$script:Window.Height=680
 RenderUI0120Run (NewUI0120Run (NewUI0120Line 'Failed' 'Passed'))
 $script:Window.UpdateLayout();$null=$script:Window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ContextIdle);$script:Window.UpdateLayout()
 foreach($id in @('DeployConnectRecommended','DeployLeave')){
  $control=$script:Controls[$id];$point=$control.TranslatePoint((New-Object Windows.Point(0,0)),$script:Window.Content)
  AssertUI ($control.ActualWidth -gt 60 -and $point.X -ge 0 -and $point.X+$control.ActualWidth -le $script:Window.Content.ActualWidth) ('minimum width keeps '+$id+' inside window')
 }
 Snapshot '14-minimum-completion'
 Fixture0120 'Disconnected'
 $script:Nodes[0].Revision=0
 PreviewDefaultLineConnection $hk
 AssertUI (@(Requests).Count -eq 1 -and @(Requests)[0].Request.Action -eq 'LineRegister' -and -not (DialogOpen)) 'first legacy connection prepares metadata before asking for runtime preview'
 CompleteUI ([pscustomobject]@{LineId=$hk;Revision=1})
 AssertUI (@(Requests).Count -eq 2 -and @(Requests)[1].Request.Action -eq 'ConnectionDefaultPreview') 'legacy metadata preparation continues directly into the default preview'
 CompleteUI ([pscustomobject]@{CanSwitch=$true;LineId=$hk;ProfileId='Udp';PreviewToken='legacy-inactive-token';Message='沿用已有 UDP 配置，连接后检查'})
 AssertUI ((DialogOpen) -and @(Requests|Where-Object {$_.Request.Action -eq 'ConnectionSwitchCommit'}).Count -eq 0) 'preparing legacy metadata cannot activate a tunnel'
 ClickDialog 'DialogCancel'
 AssertUI (@(Requests|Where-Object {$_.Request.Action -eq 'ConnectionSwitchCommit'}).Count -eq 0) 'legacy default preview cancellation keeps connection untouched'
 Fixture0120
 $line=NewUI0120Line 'NotTested' 'NotTested';$run=NewUI0120Run $line;$run.Stage='CheckingProfiles';$run.Status='Running';$run.ProfileProbeState='Running';$script:DeployUI.Run=$run
 ShowDeploymentRun
 ClickUI 'DeployStopCheck'
 AssertUI (@(Requests).Count -eq 1 -and @(Requests)[0].Request.Action -eq 'DeploymentCancelProbe' -and -not @(Requests)[0].Request.ContainsKey('SessionAction')) 'stop local comparison requests only its cancellation marker, never disconnect or SSH cancellation'
 if($script:UI013Enabled){InvokeUI013Tests}
 if($script:UI014Enabled){InvokeUI014Tests}
 AssertUI (-not (Test-Path -LiteralPath $script:JobRoot)) 'SelfTest never creates production Worker job files'
 AssertUI (-not $script:Timer.IsEnabled -and $script:Smoke) 'SelfTest never starts production polling'
 AssertUI (@($script:AllSelfTestRequests|Where-Object {$_.Request.ContainsKey('SessionAction') -or $_.Request.Action -in @('DeploymentAttach','ServerOperation','AutoTransportPrepare','UpgradeActive')}).Count -eq 0) '0.12.0 suite emits no Connect/Disconnect/Apply or server authorization requests'
 $result=[ordered]@{Passed=$true;Suite=$(if($script:UI013Enabled){'0.13.0'}else{'0.12.0'});Assertions=$script:Assertions.Count;Checks=$script:Assertions.ToArray();Screenshots=$qa;FixtureRoot=$script:Root;PowerShellVersion=[string]$PSVersionTable.PSVersion;RealNetworkChanged=$false;WorkerLaunched=$false;WpfRendered=$true;CapturedRequests=$script:AllSelfTestRequests.Count}
 [IO.File]::WriteAllText((Join-Path $qa 'ui-result.json'),($result|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($true)))
 [IO.File]::WriteAllText((Join-Path $qa 'worker-requests.json'),($script:AllSelfTestRequests.ToArray()|ConvertTo-Json -Depth 10),(New-Object Text.UTF8Encoding($true)))
 $result|ConvertTo-Json -Depth 8
}catch{
 $failure=[ordered]@{Passed=$false;Error=$_.Exception.Message;ScriptStackTrace=$_.ScriptStackTrace;Assertions=$script:Assertions.Count;WorkerLaunched=$false}
 [IO.File]::WriteAllText((Join-Path $qa 'ui-result.json'),($failure|ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($true)))
 throw
}finally{$script:Closing=$true;$script:Window.Close();ReleaseBrandResources;$script:ToastTimer.Stop()}
