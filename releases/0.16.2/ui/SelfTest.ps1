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
 $requests=@(Requests);if($Index -lt 0){$Index=$requests.Count-1};$script:Pending=$null;& $requests[$Index].Complete $Data
}
function ScrollToUI {param([string]$Id)
 $script:Window.UpdateLayout();$y=$script:Controls[$Id].TransformToAncestor($script:HostPanel).Transform((New-Object Windows.Point(0,0))).Y
 $script:Window.FindName('Scroll').ScrollToVerticalOffset($y);$script:Window.UpdateLayout()
}
function FailUI {param([string]$Message,[int]$Index=-1)
 $requests=@(Requests);if($Index -lt 0){$Index=$requests.Count-1};$script:Pending=$null;& $requests[$Index].Failed $Message
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
 $script:ConnectionPreviewUI=$null;$script:LineProfileUI=$null
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
function VisualTextUI {param($Element)
 if($Element -is [Windows.Controls.TextBlock]){$Element.Text}
 for($i=0;$i -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($Element);$i++){VisualTextUI ([Windows.Media.VisualTreeHelper]::GetChild($Element,$i))}
}
try{
 $script:Window.Show()
 # Connected overview: one status, two lanes, three status cards.
 Fixture;ShowHome;UpdateChrome;Snapshot '01-overview-connected'
 AssertUI ($script:Controls.Primary.Content -eq '断开' -and $script:Controls.StatusTitle.Text -eq '通道运行中') 'connected hero offers disconnect'
 AssertUI ($script:Controls.StatusDetail.Text -like '*香港主线*本地直连*') 'hero sentence names both lanes'
 AssertUI ((IsOn (SegId 'Trade' ('node:'+$hk))) -and (IsOn (SegId 'Daily' 'Direct'))) 'lanes show what actually runs'
 AssertUI ($script:Window.FindName('ChipText').Text -like '通道运行*香港主线*') 'header chip mirrors the session'
 AssertUI ($script:Controls.StatusMeta.Text -like '*已运行 2 小时*42 个连接*') 'connected meta shows age and connections'
 # Daily choices apply at once (no dialog) and lock the lanes while applying.
 ClickUI (SegId 'Daily' 'Provider')
 $r=@(Requests)
 AssertUI ($r.Count -eq 1 -and $r[0].Request.Action -eq 'Session' -and $r[0].Request.SessionAction -eq 'Apply' -and $r[0].Request.Daily -eq 'Provider' -and $r[0].Request.Mode -eq 'Trading' -and -not (DialogOpen)) 'daily BatVPN applies immediately without confirmation'
 AssertNoRouteFields $r[0].Request 'daily change';AssertUI ($r[0].Request.ProviderId -eq 'pv-bat') 'daily request carries selected provider only'
 Snapshot '02-daily-switching'
 AssertUI (-not $script:Controls[(SegId 'Daily' 'Direct')].IsEnabled) 'lanes are locked while a change applies'
 ClickUI (SegId 'Daily' 'Direct');AssertUI (@(Requests).Count -eq 1) 'no duplicate change while applying'
 # Daily via the trading line: warn about shared server bandwidth first.
 Fixture;ShowHome;ClickUI (SegId 'Daily' 'Trade')
 AssertUI ((DialogOpen) -and $script:Window.FindName('DialogBody').Text -like '*带宽*' -and @(Requests).Count -eq 0) 'global mode explains bandwidth sharing first'
 ClickDialog 'DialogCancel';AssertUI (@(Requests).Count -eq 0) 'cancel keeps the daily lane'
 ClickUI (SegId 'Daily' 'Trade');ClickDialog 'DialogConfirm'
 $r=@(Requests);AssertUI ($r.Count -eq 1 -and $r[0].Request.Mode -eq 'Global') 'confirmed global mode is one request'
 # Trading backup is checked first; confirmation alone can request a switch.
 Fixture;ShowHome;ClickUI (SegId 'Trade' 'Provider')
 AssertUI (@(Requests).Count -eq 1 -and @(Requests)[0].Request.Action -eq 'ProviderCheck' -and -not (DialogOpen)) 'backup starts with a check and leaves Hong Kong intact'
 AssertUI (@(Requests)[0].Request.ForTrade -eq $true) 'backup preflight explicitly asks to probe the trade port'
 CompleteUI ([pscustomobject]@{Id='pv-bat';Applied=$true;Health=[pscustomobject]@{Healthy=$true};DailyForwarding=$true;ForTrade=$true;TradeHealth=[pscustomobject]@{Healthy=$true};TradePolicy=[pscustomobject]@{Allowed=$true;ReasonText=''};TradeForwarding=$true;TradeReadyBeforeSwitch=$true;TradingValidated=$false;Friendly='交易备用端口检查通过'})
 Snapshot '03-trade-switch-confirm'
 AssertUI ((DialogOpen) -and $script:Window.FindName('DialogBody').Text -like '*全局*' -and @(Requests).Count -eq 1) 'backup asks to confirm after successful check'
 ClickDialog 'DialogConfirm';$r=@(Requests);AssertUI ($r.Count -eq 2 -and $r[1].Request.Exit -eq 'Provider' -and $r[1].Request.TradeProviderId -eq 'pv-bat' -and $r[1].Transition -eq 'Applying') 'confirmed backup names the trade provider explicitly'
 AssertUI (-not $r[1].Request.ContainsKey('ProviderId') -and -not $r[1].Request.ContainsKey('Agents') -and -not $r[1].Request.ContainsKey('NodeId')) 'backup switch leaves daily provider and assistant settings alone'
 Fixture;ShowHome;ClickUI (SegId 'Trade' 'Provider')
 CompleteUI ([pscustomobject]@{Id='pv-bat';Healthy=$false;Friendly='客户端未连接，端口检查失败'})
 AssertUI ((DialogOpen) -and $script:Window.FindName('DialogTitle').Text -like '*交易线路保持*' -and $script:Window.FindName('DialogBody').Text -eq '客户端未连接，端口检查失败') 'failed check shows friendly report and preserves Hong Kong'
 Snapshot '20-provider-check-failed';ClickDialog 'DialogConfirm';AssertUI (@(Requests).Count -eq 1 -and $script:Overview.Exit -eq 'hk') 'failed backup check never sends a session request'
 Fixture;ShowHome;ClickUI (SegId 'Trade' ('node:'+$us))
 $r=@(Requests);AssertUI ($r.Count -eq 1 -and $r[0].Request.Action -eq 'ConnectionDefaultPreview' -and $r[0].Request.LineId -eq $us) 'node change first requests default-profile preview'
 CompleteUI ([pscustomobject]@{CanSwitch=$true;LineId=$us;ProfileId='Udp';PreviewToken='legacy-ui-token';Message='请先退出整个 NinjaTrader；切换后检查出口。'})
 AssertUI ((DialogOpen) -and $script:Window.FindName('DialogBody').Text -like '*NinjaTrader*') 'node change asks to close NinjaTrader'
 ClickDialog 'DialogConfirm';$r=@(Requests);AssertUI ($r.Count -eq 2 -and $r[1].Request.Action -eq 'ConnectionSwitchCommit' -and $r[1].Request.LineId -eq $us) 'node change commits the confirmed chosen line'
 # Disconnected: choices are saved for the next connection only.
 Fixture 'Disconnected';ShowHome;UpdateChrome;Snapshot '04-disconnected'
 AssertUI ($script:Controls.Primary.Content -eq '连接' -and $script:Controls.TradeLaneStatus.Text -eq '下次连接时使用') 'disconnected offers connect and explains choices'
 ClickUI (SegId 'Daily' 'Provider');$r=@(Requests)
 AssertUI ($r.Count -eq 1 -and $r[0].Request.Action -eq 'SavePreferences' -and $r[0].Request.Daily -eq 'Provider') 'disconnected daily choice is only saved'
 AssertUI (IsOn (SegId 'Daily' 'Provider')) 'saved choice is shown at once'
 $script:Actions.Clear();ClickUI 'Primary';$r=@(Requests)
 AssertUI ($r.Count -eq 1 -and $r[0].Request.Action -eq 'ConnectionDefaultPreview' -and $script:Prefs.Daily -eq 'Provider') 'connect previews default while preserving saved daily selection'
 PrimaryAction;AssertUI (@(Requests).Count -eq 1) 'pending preview blocks duplicate connect'
 CompleteUI ([pscustomobject]@{CanSwitch=$true;LineId=$hk;ProfileId='Udp';PreviewToken='legacy-connect-token';Message='连接并检查'})
 ClickDialog 'DialogConfirm';PrimaryAction;AssertUI (@(Requests).Count -eq 2) 'connecting blocks a duplicate connect';Snapshot '05-connecting'
 Fixture;ShowHome;ClickUI 'Primary'
 AssertUI ((DialogOpen) -and $script:Window.FindName('DialogConfirm').Content -eq '断开通道') 'disconnect is confirmed'
 ClickDialog 'DialogConfirm';$r=@(Requests);AssertUI ($r.Count -eq 1 -and $r[0].Request.SessionAction -eq 'Disconnect') 'disconnect sends one stop request'
 PrimaryAction;AssertUI (@(Requests).Count -eq 1) 'disconnecting blocks duplicates';Snapshot '06-disconnecting'
 Fixture 'Disconnected' @{BootRestartDetected=$true};ShowHome;AssertUI ($script:Controls.StatusDetail.Text -like '*重启*') 'reboot shows manual reconnect guidance'
 Fixture 'Fault' @{PrimaryAction='Retry';CanConnect=$false;PrimaryEnabled=$false;Error='无法核对控制接口。请重新检查当前连接。'};ShowHome;UpdateChrome;Snapshot '07-fault'
 ClickUI 'Primary';AssertUI (@(Requests)[0].Request.Action -eq 'Overview') 'unverified fault rechecks without starting'
 Fixture 'Unconfigured';$script:Nodes=@();ShowHome;AssertUI ($script:Controls.Primary.Content -eq '开始配置') 'fresh install offers setup'
 # Provider fallback is visible in the daily lane, with the reason.
 Fixture 'Connected' @{DesiredDaily='Provider';Daily='direct';DailyReason='NotListening';Provider=[pscustomobject]@{Configured=$true;Port=10823;Listening=$false;Healthy=$false;Reason='NotListening';ReasonText='BatVPN 未连接'}}
 ShowHome;Snapshot '08-daily-fallback'
 AssertUI ((IsOn (SegId 'Daily' 'Provider')) -and $script:Controls.DailyLaneStatus.Text -like '*BatVPN 未连接*暂时直连*') 'daily lane keeps the intent and states the fallback'
 AssertUI ($script:Controls.StatusDetail.Text -like '*日常暂时直连*') 'hero states the effective daily route, not the intent'
 Fixture 'Connected' @{Mode='global';DesiredDaily='Provider';Daily='direct';DailyReason='NotListening';Provider=[pscustomobject]@{Configured=$true;Port=10823;Listening=$false;Healthy=$false;Reason='NotListening';ReasonText='BatVPN 未连接'}};$script:Providers.Items[0].Health=[pscustomobject]@{Healthy=$false;Reason='NotListening';ReasonText='BatVPN 未连接'}
  ShowHome
  $disabled=(-not $script:Controls[(SegId 'Daily' 'Provider')].IsEnabled)
  AssertUI $disabled 'unavailable provider cannot trigger a mode switch'
  $script:Actions.Clear()
  OnDaily 'Provider'
  $dialogIsOpen=[bool](DialogOpen);$actionCount=[int]$script:Actions.Count
  AssertUI ($dialogIsOpen -and ($actionCount -eq 0)) 'unavailable provider explains without touching the trading mode';CloseDialog
  $script:ProviderReports['pv-bat']=[pscustomobject]@{Healthy=$false;Reason='NotListening'}
  $script:Providers.Items[0].Health=[pscustomobject]@{Healthy=$true}
  ShowHome;AssertUI $script:Controls[(SegId 'Daily' 'Provider')].IsEnabled 'client reconnected: fresh discovery overrides a historical failed check'
  $script:ProviderReports['pv-bat']=[pscustomobject]@{Healthy=$true}
  $script:Providers.Items[0].Health=[pscustomobject]@{Healthy=$false;Reason='NotListening'}
  ShowHome;AssertUI (-not $script:Controls[(SegId 'Daily' 'Provider')].IsEnabled) 'client exited: historical check cannot keep daily switch enabled'
 # Long line names: short segment label, full name on hover; colliding short labels fall back to full names.
 Fixture 'Connected';$script:Nodes[0].name='香港主线（现有已验证配置）';ShowHome;$seg=$script:Controls[(SegId 'Trade' ('node:'+$hk))]
 AssertUI ($seg.Content -eq '香港主线' -and [string]$seg.ToolTip -like '香港主线（现有已验证配置）*') 'long line name shows a short label and the full name on hover'
 $script:Nodes[1].name='香港主线（备用机房）';ShowHome;AssertUI ($script:Controls[(SegId 'Trade' ('node:'+$hk))].Content -ne $script:Controls[(SegId 'Trade' ('node:'+$us))].Content) 'short labels never make two lines look alike'
 # Policy v1: upgrade offered; BatVPN daily option unavailable until then.
 Fixture 'Connected' @{PolicyVersion=1;UpgradeAvailable=$true;DailySupported=$false;Daily=$null};ShowHome;Snapshot '09-upgrade-available'
 AssertUI (-not $script:Controls[(SegId 'Daily' 'Provider')].IsEnabled) 'v1 line cannot select daily BatVPN'
 ClickUI 'UpgradeNotice';AssertUI ((DialogOpen) -and $script:Window.FindName('DialogBody').Text -like '*原配置保留*') 'upgrade explains rollback'
 ClickDialog 'DialogConfirm';$r=@(Requests);AssertUI ($r.Count -eq 1 -and $r[0].Request.Action -eq 'UpgradeActive') 'upgrade is one explicit request'
 Fixture 'Connected' @{Mode='global';ControllerModes=@('global');ModeSwitchSupported=$false;UpgradeAvailable=$true}
 ShowHome;Snapshot '28-missing-rule-mode'
 AssertUI ($script:Controls.ContainsKey('UpgradeNotice') -and $script:Overview.Mode -eq 'global' -and @(Requests).Count -eq 0) 'global-only runtime offers repair without starting maintenance'
 ClickUI 'UpgradeNotice';AssertUI ((DialogOpen) -and $script:Window.FindName('DialogBody').Text -like '*补齐交易/全局模式*') 'same-policy-version repair explains the required reload';CloseDialog
 Fixture 'Connected' @{ForeignTunnel='BatVPN';LastProxyKind='Unknown';LastProxyAt=(Get-Date).AddMinutes(-3).ToString('o');LastProxySummary='127.0.0.1:9999'};ShowHome;Snapshot '10-warnings'
 AssertUI (@($script:HostPanel.Children).Count -ge 6) 'tunnel and proxy notices render above the hero'
 Fixture;foreach($pair in @(@('SessionId','legacy-fixture-session'),@('ConfigHash',('A'*64)),@('ActiveLineId',$hk),@('ActiveProfileId','Udp'))){$script:Overview|Add-Member NoteProperty $pair[0] $pair[1] -Force};$script:Checks=@{At='21:45:12';Data=[pscustomobject]@{ObservedIP='203.0.113.10';ExitHttp=$true;TradingViewHttp=$true;DailyLane='provider';DailyHttp=$true;DailyIP='198.51.100.88';TradeLatencyMs=158;Time=[DateTimeOffset]::UtcNow.ToString('o');CheckContext=(Get-TCExitCheckContext $script:Overview)}};ShowHome;$script:Controls.StatusDetails.IsExpanded=$true;Snapshot '11-check-results'
 AssertUI ($script:Controls.CheckTradeIP.Text -eq '203.0.113.10' -and $script:Controls.CheckDailyIP.Text -eq '198.51.100.88') 'check card shows both exits'
 AssertUI (@(VisualTextUI $script:HostPanel) -contains '158 ms') 'exit check card retains measured response'
 # AI assistants: a third lane that applies at once; trading is never touched.
 Fixture;ShowHome
 AssertUI ($script:Controls.ContainsKey((SegId 'Agents' 'Trade')) -and $script:Controls[(SegId 'Agents' 'Trade')].IsEnabled -and (IsOn (SegId 'Agents' 'Daily'))) 'assistant lane shows the applied choice'
 AssertUI ($script:Controls.AgentLaneSubtitle.Text -eq 'Mirasim、Claude Code、Codex 等 22 项' -and $script:Controls.AgentLaneStatus.Text -eq '跟随日常上网：本地直连') 'assistant lane names the list and where it goes'
 ClickUI (SegId 'Agents' 'Trade');$r=@(Requests)
 AssertUI ($r.Count -eq 1 -and $r[0].Request.SessionAction -eq 'Apply' -and $r[0].Request.Agents -eq 'Trade' -and $r[0].Transition -eq 'ApplyingAgents' -and -not (DialogOpen)) 'assistants move to the trading line at once, without a dialog'
 AssertUI (-not $r[0].Request.ContainsKey('Exit') -and -not $r[0].Request.ContainsKey('Mode') -and -not $r[0].Request.ContainsKey('NodeId') -and @($r[0].Request.AgentIds).Count -eq 22) 'assistant change patches only the assistant list'
 AssertUI (-not $script:Controls[(SegId 'Agents' 'Daily')].IsEnabled -and $script:Controls.AgentLaneStatus.Text -eq '正在切换…') 'lanes lock while the assistant change applies'
 Fixture 'Connected' @{Agents='Trade';DesiredAgents='Trade'};$script:Prefs.Agents='Trade';ShowHome;Snapshot '18-agents-trade'
 AssertUI ((IsOn (SegId 'Agents' 'Trade')) -and $script:Controls.AgentLaneStatus.Text -like '经 香港主线 转发*' -and $script:Controls.AgentLaneEvidence.Text -like '*跟随交易出口*') 'the applied trading lane and AI evidence identify the selected route'
 Fixture 'Connected' @{Mode='global'};ShowHome
 AssertUI ((IsOn (SegId 'Agents' 'Trade')) -and -not $script:Controls[(SegId 'Agents' 'Daily')].IsEnabled) 'global mode shows assistants on the trading line and locks the choice'
 Fixture 'Connected' @{AgentsSupported=$false;PolicyVersion=2;UpgradeAvailable=$true};ShowHome
 AssertUI (-not $script:Controls[(SegId 'Agents' 'Trade')].IsEnabled -and $script:Controls.AgentLaneStatus.Text -like '升级线路配置后*') 'a v2 line explains the upgrade instead of offering the lane'
 Fixture 'Disconnected';ShowHome;ClickUI (SegId 'Agents' 'Trade');$r=@(Requests)
 AssertUI ($r.Count -eq 1 -and $r[0].Request.Action -eq 'SavePreferences' -and $r[0].Request.Agents -eq 'Trade' -and @($r[0].Request.AgentIds).Count -eq 22) 'disconnected assistant choice is only saved, with the list'
 # The list on the lines page: switches apply at once; custom sites are checked before sending.
 Fixture;$script:AgentPresence=@{mirasim='Running';'claude-code'='Running';codex='Running';antigravity='NotFound';'cc-switch'='Running'};$script:Prefs.AgentCustom=@([pscustomobject]@{Kind='Site';Value='perplexity.ai'},[pscustomobject]@{Kind='Program';Value='C:\Tools\Agent\agent.exe'});ShowNodes
 # 12-lines shows the top of this page; scroll so the web group, a custom item and the add row are in view.
 $scroll=$script:Window.FindName('Scroll');$script:Window.UpdateLayout()
 $y=$script:Controls.AgentSiteInput.TransformToAncestor($scroll).Transform((New-Object Windows.Point(0,0))).Y
 $scroll.ScrollToVerticalOffset([math]::Max(0,$y-$scroll.ViewportHeight+170));Snapshot '19-agents-list'
 AssertUI ($scroll.VerticalOffset -gt 0 -and $script:Controls.ContainsKey('RemoveAgent0')) 'the list scrolls to custom items and the add row'
 AssertUI ($script:Controls.ContainsKey('Agentmirasim') -and $script:Controls.Agentmirasim.IsChecked -and $script:Controls.ContainsKey('Agentgeminiweb')) 'every built-in assistant has a switch'
 $box=$script:Controls.Agentcodex;$box.IsChecked=$false;$box.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)));$r=@(Requests)
 AssertUI ($r.Count -eq 1 -and $r[0].Request.Action -eq 'Session' -and -not (@($r[0].Request.AgentIds) -contains 'codex') -and @($r[0].Request.AgentIds).Count -eq 21 -and $r[0].Transition -eq 'ApplyingAgents') 'unchecking an assistant applies at once'
 Fixture;ShowNodes;$script:Controls.AgentSiteInput.Text='1.2.3.4';ClickUI 'AddAgentSite'
 AssertUI ((DialogOpen) -and @(Requests).Count -eq 0) 'an invalid site is explained and nothing is sent';CloseDialog
 $script:Controls.AgentSiteInput.Text='https://Perplexity.ai/search';ClickUI 'AddAgentSite';$r=@(Requests)
 AssertUI ($r.Count -eq 1 -and @($r[0].Request.AgentCustom).Count -eq 1 -and $r[0].Request.AgentCustom[0].Kind -eq 'Site' -and $r[0].Request.AgentCustom[0].Value -eq 'perplexity.ai') 'a custom site is normalized and applied'
 Fixture;$script:Prefs.AgentCustom=@([pscustomobject]@{Kind='Site';Value='perplexity.ai'});ShowNodes;ClickUI 'RemoveAgent0';$r=@(Requests)
 AssertUI ($r.Count -eq 1 -and @($r[0].Request.AgentCustom).Count -eq 0) 'removing a custom item applies at once'
 # Lines and settings.
 Fixture;ShowNodes;Snapshot '12-lines'
 ClickUI ('Node'+$us.Replace('-',''));AssertUI (@(Requests).Count -eq 1 -and @(Requests)[0].Request.Action -eq 'ConnectionDefaultPreview') 'line page connection previews before any activation'
 CompleteUI ([pscustomobject]@{CanSwitch=$true;LineId=$us;ProfileId='Udp';PreviewToken='legacy-line-token';Message='核对连接'})
 ClickDialog 'DialogCancel';AssertUI (@(Requests|Where-Object {$_.Request.Action -eq 'ConnectionSwitchCommit'}).Count -eq 0) 'cancelled line change never commits'
 Fixture;ShowSettings;Snapshot '13-settings';AssertUI (-not $script:Controls.OpenAtLogin.IsChecked) 'open at login default off'
 $script:Controls.OpenAtLogin.IsChecked=$true;$script:Controls.OpenAtLogin.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
 AssertUI (@(Requests).Count -eq 1 -and @(Requests)[0].Request.Action -eq 'SetStartup') 'login preference never connects'
 $script:Actions.Clear();ClickUI 'RemoveProtection';AssertUI ((DialogOpen) -and @(Requests).Count -eq 0) 'protection removal is confirmed';ClickDialog 'DialogCancel'
 $script:Actions.Clear();ClickUI 'DesktopShortcut';AssertUI (@(Requests)[0].Request.Action -eq 'DesktopShortcut') 'desktop entry request'
 # Deployment wizard keeps every step reachable.
 Fixture;$script:Page='setup';$script:Step=0;ShowSetup;Snapshot '14-setup'
 $script:Inspection=[pscustomobject]@{OS='Windows 11';Elevated=$true;EngineStaged=$true;ExistingDeployment=$true;NinjaTraderPaths=@('C:\Program Files\NinjaTrader 8\bin\NinjaTrader.exe');DirectDnsIPv4=@('192.168.1.1');Provider=[pscustomobject]@{Name='BatVPN';Kind='batvpn';SocksPort=10823;TradePort=10823};ProviderCandidates=@($script:Providers.Candidates);RegisteredProviders=@($script:Providers.Items)}
 $script:ServerInspection=[pscustomobject]@{Friendly='Windows Server 2022，组件已就绪。';OS=[pscustomobject]@{Supported=$true}}
 $script:ServerPlan=[pscustomobject]@{PlanPath='fixture-plan';Plan=[pscustomobject]@{Name='美国备用';PublicEndpoint='203.0.113.10:51820';TunnelSubnet='10.78.0.0/24';NatName='TC-SERVER';RequiredCloudRule='UDP 51820'}}
 foreach($role in @('client','server')){for($step=1;$step -le 4;$step++){$script:Role=$role;$script:Step=$step;$script:Page='setup';ShowSetup;$script:Window.UpdateLayout();AssertUI ($script:Controls.ContainsKey('WizardNext')) ('wizard '+$role+'/'+$step)}}
 $script:Role='client';$script:Step=2;ShowSetup;Snapshot '15-client-import'
 $script:Role='server';$script:Step=1;ShowSetup;AssertUI ($script:Controls.ContainsKey('InstallWireGuard') -and $script:Controls.ContainsKey('InstallWireGuardOnline')) 'server wizard offers bundled and official installers'
 $script:Actions.Clear();ClickUI 'InstallWireGuard';ClickDialog 'DialogConfirm';AssertUI (@(Requests).Count -eq 1 -and @(Requests)[0].Request.Source -eq 'Bundled') 'bundled installer request names its source'
 $script:Role='server';$script:Step=3;ShowSetup;Snapshot '16-server-review'
 ShowPairing;AssertUI ($script:Controls.ContainsKey('DeviceRequest')) 'pairing page renders';ShowAuthorize;AssertUI ($script:Controls.ContainsKey('Authorize')) 'authorization page renders';ShowMigration;AssertUI ($script:Controls.ContainsKey('ExportSettings')) 'migration page renders'
 # Provider contracts: daily/default identity is independent of the live trade.
 Fixture 'Connected' @{Exit='provider-trade';DesiredExit='Provider';Mode='global';Agents='Trade';DesiredAgents='Trade'}
 $script:Prefs.Exit='Provider';$script:Prefs.Mode='Global';$script:Prefs.Agents='Trade';ShowHome
 ChooseProviderUI 'pv-clash';$r=@(Requests)
 AssertUI ($r.Count -eq 1 -and $r[0].Request.Action -eq 'Session' -and $r[0].Request.SessionAction -eq 'Apply' -and $r[0].Request.ProviderId -eq 'pv-clash' -and $r[0].Request.Count -eq 3) 'choosing a daily provider during a trade backup sends exactly one sparse Apply'
 AssertNoRouteFields $r[0].Request 'select provider during backup'
 AssertUI ($script:Overview.Exit -eq 'provider-trade' -and $script:Overview.TradeProviderId -eq 'pv-bat' -and $script:Prefs.Agents -eq 'Trade') 'provider selection preserves live trade identity and assistant preference'
 Fixture 'Connected' @{Exit='provider2-trade';Daily='provider2';DesiredDaily='Provider'};ShowHome;Snapshot '21-multiple-provider-tags'
 AssertUI ($script:Controls.TradeLaneStatus.Text -like '*工作用 Clash*备用*' -and $script:Controls.DailyLaneStatus.Text -like '*工作用 Clash*') 'actual trade and daily names are mapped from manifest tags'
 AssertUI ($script:Controls.StatusDetail.Text -like '*工作用 Clash*' -and $script:Controls.StatusDetail.Text -notlike '*BatVPN*') 'hero never labels provider2 using the selected daily identity'
 Fixture;$script:Providers.Items[0].Name='我的 SOCKS';$script:Overview.Providers[0].Name='我的 SOCKS';$script:Providers.ActiveProviderName='我的 SOCKS';ShowHome
 AssertUI ($script:Controls[(SegId 'Daily' 'Provider')].Content -eq '当前服务商' -and $script:Controls.ProviderState.Text -like '我的 SOCKS*') 'provider labels are generic and use the profile name'
 # Registering/selecting a pending provider never upgrades policy3 or touches HK.
 PendingProviderFixture;ShowHome;ChooseProviderUI 'pv-clash';$r=@(Requests)
 AssertUI ($r.Count -eq 1 -and $r[0].Request.Action -eq 'SavePreferences' -and $r[0].Request.ProviderId -eq 'pv-clash' -and $r[0].Request.Count -eq 2) 'pending provider selection is preferences only'
 AssertUI ($script:Overview.PolicyVersion -eq 3 -and $script:Overview.Exit -eq 'hk' -and $script:Controls.ProviderSelectionHint.Text -like '*待更新*香港连接保持*') 'policy3 and Hong Kong remain unchanged with a visible pending label'
 Snapshot '22-provider-pending-policy3'
 AssertUI (-not $script:Controls[(SegId 'Daily' 'Provider')].IsEnabled -and -not $script:Controls[(SegId 'Trade' 'Provider')].IsEnabled) 'pending provider cannot take daily or trading traffic'
 $script:Actions.Clear();OnTrade 'Provider';AssertUI ((DialogOpen) -and @(Requests).Count -eq 0) 'pending backup explains maintenance without an upgrade request';CloseDialog
 PendingProviderFixture;ShowNodes;Snapshot '23-providers-lines'
 ScrollToUI 'ProviderCardpvclash';Snapshot '26-clash-provider-card'
 AssertUI ($script:Controls.ContainsKey('PrepareProviderpvclash') -and $script:Controls.ContainsKey('RestoreProviderpvclash') -and $script:Controls.ContainsKey('CheckProviderpvbat')) 'each registered provider has independent controls'
 AssertUI (-not $script:Controls.ContainsKey('RegisterCandidate0') -and -not $script:Controls.ContainsKey('RegisterCandidate1')) 'detected registered clients are not duplicated as new candidates'
 ClickUI 'DiscoverProviders';AssertUI (@(Requests).Count -eq 1 -and @(Requests)[0].Request.Action -eq 'Providers') 'discovery is a read-only worker action'
 CompleteUI $script:Providers;AssertUI (@(Requests|Where-Object {$_.Request.Action -notin @('Providers','Agents')}).Count -eq 0) 'discovery completion never registers or updates anything'
 Fixture;ShowNodes;ClickUI 'DiscoverProviders';FailUI '检测器暂时不可用'
 AssertUI ($script:ProviderReadError -eq '检测器暂时不可用' -and -not $script:Controls.NodesProviderChoice.IsEnabled -and $script:Overview.Exit -eq 'hk') 'discovery failure explains the error and preserves the live route'
 Fixture;$script:Providers.Items=@();$script:Providers.SelectedProviderId=$null;$script:Prefs.ProviderId=$null;ShowNodes;ClickUI 'RegisterCandidate1'
 AssertUI ($script:ProviderForm.Kind -eq 'clashverge' -and $script:Controls.ProviderFieldDailyPort.Text -eq '7897' -and @(Requests).Count -eq 0) 'Clash discovery prefills a reviewable form without registration'
 ClickUI 'RegisterProvider';$r=@(Requests)
 AssertUI ($r.Count -eq 1 -and $r[0].Request.Action -eq 'ProviderRegister' -and $r[0].Request.Kind -eq 'clashverge' -and $r[0].Request.Directory.StartsWith($script:Root)) 'discovered registration carries the isolated directory and kind'
 CompleteUI ([pscustomobject]@{Id='new-clash';Friendly='登记成功'})
 AssertUI (@(Requests|Where-Object {$_.Request.Action -notin @('ProviderRegister','Providers')}).Count -eq 0 -and $script:Overview.Exit -eq 'hk') 'register completion only refreshes the provider inventory'
 Fixture;ShowNodes;ClickUI 'AddProvider';$script:Controls.ProviderFieldName.Text='其他 SOCKS';$script:Controls.ProviderFieldDirectory.Text=(Join-Path $script:Root 'clients\Other');$script:Controls.ProviderFieldDailyPort.Text='70000';ClickUI 'RegisterProvider'
 AssertUI ((DialogOpen) -and @(Requests).Count -eq 0) 'out-of-range SOCKS port is rejected before dispatch';CloseDialog
 $script:Controls.ProviderFieldDailyPort.Text='1080';ScrollToUI 'ProviderFormCard';Snapshot '24-manual-provider'
 AssertUI (-not $script:Controls.ContainsKey('ProviderFieldTradePort')) 'custom SOCKS registration offers no unverified trading port'
 ClickUI 'RegisterProvider';$r=@(Requests)
 AssertUI ($r.Count -eq 1 -and $r[0].Request.Kind -eq 'custom' -and $r[0].Request.DailyPort -eq 1080 -and -not $r[0].Request.ContainsKey('TradePort')) 'manual SOCKS registration carries only the validated daily port'
 Fixture;$script:Providers.Items[0].Kind='custom';$script:Providers.Items[0].Name='其他 SOCKS';ShowHome
 AssertUI ($script:Controls[(SegId 'Daily' 'Provider')].IsEnabled -and -not $script:Controls[(SegId 'Trade' 'Provider')].IsEnabled -and $script:Controls.ProviderSelectionHint.Text -like '*当前仅供日常上网*') 'custom SOCKS remains usable for daily traffic but cannot be offered as a trading backup'
 OnTrade 'Provider';AssertUI ((DialogOpen) -and @(Requests).Count -eq 0 -and $script:Window.FindName('DialogNote').Text -like '*Clash Verge/BatVPN*') 'custom trading entry explains the supported alternatives without a worker request'
 # Prepare/restore may write client settings only after their own confirmation.
 PendingProviderFixture;ShowNodes;ClickUI 'PrepareProviderpvclash';Snapshot '25-clash-prepare-confirm'
 AssertUI ((DialogOpen) -and @(Requests).Count -eq 0 -and $script:Window.FindName('DialogBody').Text -like '*备份*') 'Clash preparation states its reversible changes before dispatch'
 ClickDialog 'DialogCancel';AssertUI (@(Requests).Count -eq 0) 'cancelling Clash preparation is inert'
 ClickUI 'PrepareProviderpvclash';ClickDialog 'DialogConfirm';$r=@(Requests)
 AssertUI ($r.Count -eq 1 -and $r[0].Request.Action -eq 'ProviderPrepare' -and $r[0].Request.Id -eq 'pv-clash') 'Clash preparation dispatches only ProviderPrepare'
 CompleteUI ([pscustomobject]@{Friendly='已准备域名识别，请在 Clash 重新载入配置。';BackupPath=(Join-Path $script:Root 'backups\clash.yaml')})
 AssertUI ((DialogOpen) -and $script:Window.FindName('DialogBody').Text -like '*备份位置*' -and @(Requests|Where-Object {$_.Request.Action -in @('Session','UpgradeActive')}).Count -eq 0) 'prepare result shows the backup location and never applies a policy'
 PendingProviderFixture;ShowNodes;ClickUI 'RestoreProviderpvclash';ClickDialog 'DialogConfirm';$r=@(Requests)
 AssertUI ($r.Count -eq 1 -and $r[0].Request.Action -eq 'ProviderRestore' -and $r[0].Request.Id -eq 'pv-clash') 'rollback dispatches only ProviderRestore with the provider ID'
 # Health is fail-closed and errors do not turn into a trading request.
 foreach($report in @([pscustomobject]@{Friendly='没有布尔健康结果'},[pscustomobject]@{Healthy='true';Friendly='非布尔结果'},[pscustomobject]@{Id='different-provider';Healthy=$true;Friendly='身份不符'})){
  Fixture;ShowHome;ClickUI (SegId 'Trade' 'Provider');CompleteUI $report
  AssertUI ((DialogOpen) -and @(Requests).Count -eq 1 -and $script:Overview.Exit -eq 'hk') ('untrusted health result keeps HK: '+$report.Friendly)
 }
 Fixture;ShowHome;ClickUI (SegId 'Trade' 'Provider');FailUI '本机端口未监听'
 AssertUI ((DialogOpen) -and @(Requests).Count -eq 1 -and $script:PendingTrade -eq $null) 'worker check failure cannot leave a pending switch'
 Fixture;ShowHome;ClickUI (SegId 'Trade' 'Provider');CompleteUI ([pscustomobject]@{Applied=$true;Health=[pscustomobject]@{Healthy=$true};ForTrade=$true;TradeHealth=[pscustomobject]@{Healthy=$true};TradePolicy=[pscustomobject]@{Allowed=$true;ReasonText=''};TradeForwarding=$true;TradeReadyBeforeSwitch=$true;TradingValidated=$false;Friendly='代理转发可用'});ClickDialog 'DialogCancel'
 AssertUI (@(Requests).Count -eq 1 -and $script:Overview.Exit -eq 'hk') 'cancelling a healthy backup leaves Hong Kong intact'
 foreach($case in @(@{Applied=$true;DailyForwarding=$true;TradeForwarding=$false;TradeReadyBeforeSwitch=$false},@{Applied=$true;DailyForwarding=$true;TradeForwarding=$null;TradeReadyBeforeSwitch=$null},@{Applied=$false;DailyForwarding=$true;TradeForwarding=$true;TradeReadyBeforeSwitch=$true},@{Applied=$true;DailyForwarding=$true;TradeForwarding=$true;TradeReadyBeforeSwitch=$false})){
  Fixture;ShowHome;ClickUI (SegId 'Trade' 'Provider');$case.Health=[pscustomobject]@{Healthy=$true};$case.ForTrade=$true;$case.TradeHealth=[pscustomobject]@{Healthy=$true};$case.TradePolicy=[pscustomobject]@{Allowed=$true;ReasonText=''};$case.Friendly='检查结果摘要';CompleteUI ([pscustomobject]$case)
  AssertUI (@(Requests).Count -eq 1 -and $script:PendingTrade -eq $null -and $script:Window.FindName('DialogTitle').Text -eq '检查未通过，交易线路保持') 'daily forwarding and port ownership cannot authorize a trade switch'
 }
 Fixture;ShowNodes;ClickUI 'CheckProviderpvclash';CompleteUI ([pscustomobject]@{Applied=$true;Health=[pscustomobject]@{Healthy=$true};DailyForwarding=$false;Friendly='日常转发失败'})
 AssertUI ($script:Window.FindName('DialogTitle').Text -eq '检查未通过，交易线路保持' -and @(Requests).Count -eq 1) 'port ownership alone cannot pass a daily provider check'
 Fixture;ShowNodes;ClickUI 'CheckProviderpvclash';CompleteUI ([pscustomobject]@{Applied=$true;Health=[pscustomobject]@{Healthy=$true};DailyForwarding=$true;TradingValidated=$false;Friendly='日常端口转发通过，交易仍待验收'})
 AssertUI ($script:Window.FindName('DialogTitle').Text -like '*检查通过' -and $script:Window.FindName('DialogBody').Text -eq '日常端口转发通过，交易仍待验收' -and @(Requests).Count -eq 1) 'daily check uses its own real forwarding result and friendly summary'
 Fixture;ShowHome;ClickUI (SegId 'Trade' 'Provider');CompleteUI ([pscustomobject]@{Applied=$true;Health=[pscustomobject]@{Healthy=$true};DailyForwarding=$false;ForTrade=$true;TradeHealth=[pscustomobject]@{Healthy=$true};TradePolicy=[pscustomobject]@{Allowed=$true;ReasonText=''};TradeForwarding=$true;TradeReadyBeforeSwitch=$true;TradingValidated=$false;Friendly='独立交易端口检查通过'})
 AssertUI ($script:PendingTrade -ne $null -and $script:Window.FindName('DialogBody').Text -like '*本轮尚未完整验证*') 'trade preflight uses TradeForwarding and explicitly leaves full trading acceptance pending'
 foreach($blocked in @('Health','Policy')){
  Fixture;ShowHome;ClickUI (SegId 'Trade' 'Provider')
  $report=[pscustomobject]@{Applied=$true;Health=[pscustomobject]@{Healthy=$true};ForTrade=$true;TradeHealth=[pscustomobject]@{Healthy=($blocked -ne 'Health')};TradePolicy=[pscustomobject]@{Allowed=($blocked -ne 'Policy');ReasonText='交易端口或客户端分流条件不满足'};TradeForwarding=$true;TradeReadyBeforeSwitch=$true;TradingValidated=$false;Friendly='日常端口可用'}
  CompleteUI $report
  AssertUI ($script:PendingTrade -eq $null -and @(Requests).Count -eq 1 -and $script:Window.FindName('DialogBody').Text -like '*交易端口或客户端分流条件不满足*') ('trade preflight gates the dedicated '+$blocked+' contract')
 }
 Fixture 'Connected' @{Exit='provider2-trade';TradeProviderId='pv-clash'};ShowNodes;ClickUI 'PrepareProviderpvclash'
 AssertUI ((DialogOpen) -and @(Requests).Count -eq 0) 'a provider carrying trading traffic cannot be prepared';CloseDialog;ClickUI 'RestoreProviderpvclash'
 AssertUI ((DialogOpen) -and @(Requests).Count -eq 0) 'a provider carrying trading traffic cannot be restored'
 # Quick actions patch the current session, never selecting another node.
 Fixture 'Connected' @{Exit='provider2-trade';TradeProviderId='pv-clash';Mode='global';Agents='Trade';DesiredAgents='Trade'};$script:Prefs.Agents='Trade';ShowHome;ClickUI 'QuickHongKong'
 AssertUI ((DialogOpen) -and @(Requests).Count -eq 0) 'return to Hong Kong is a confirmed trading change'
 ClickDialog 'DialogConfirm';$r=@(Requests)
 AssertUI ($r.Count -eq 1 -and $r[0].Request.SessionAction -eq 'Apply' -and $r[0].Request.Exit -eq 'HongKong' -and $r[0].Request.Count -eq 3) 'return to Hong Kong applies only Exit on the current node'
 Fixture 'Connected' @{Mode='global';Agents='Trade';DesiredAgents='Trade'};$script:Prefs.Agents='Trade';ShowHome;ClickUI 'QuickTradingOnly';$r=@(Requests)
 AssertUI ($r.Count -eq 1 -and $r[0].Request.SessionAction -eq 'Apply' -and $r[0].Request.Mode -eq 'Trading' -and $r[0].Request.Daily -eq 'Direct' -and $r[0].Request.Count -eq 4) 'only trading changes only Mode and Daily'
 AssertNoRouteFields $r[0].Request 'only trading shortcut'
 Fixture 'Connected' @{NodeName='美国备用';ManifestPath='fixture-us';NodeId=$us;Exit='provider2-trade';TradeProviderId='pv-clash'};$script:Prefs.NodeId=$us;ShowHome
 AssertUI ($script:Controls.QuickHongKong.IsEnabled -and $script:Controls.QuickHongKong.Content -eq '回到 美国备用') 'self-hosted shortcut uses the actual non-Hong-Kong server name'
 ClickUI 'QuickHongKong';AssertUI ((DialogOpen) -and $script:Window.FindName('DialogBody').Text -like '*美国备用*' -and @(Requests).Count -eq 0) 'return to the current US server is confirmed without choosing Hong Kong'
 ClickDialog 'DialogConfirm';$r=@(Requests);AssertUI ($r.Count -eq 1 -and $r[0].Request.Exit -eq 'HongKong' -and $r[0].Request.Count -eq 3) 'historical HongKong enum returns to the currently loaded self-hosted node only'
 # Preferences errors restore the previous choice instead of pretending success.
 PendingProviderFixture;ShowHome;ChooseProviderUI 'pv-clash';FailUI '保存失败'
 AssertUI ($script:Prefs.ProviderId -eq 'pv-bat' -and (DialogOpen)) 'failed preference save rolls the selection back'
 # Import optionally includes all registered providers; detection alone is not registration.
 Fixture;$script:Role='client';$script:Step=3;$script:Inspection.RegisteredProviders=@($script:Providers.Items);$script:Wizard.UseProvider=$true;ShowSetup;ClickUI 'WizardNext'
 AssertUI (@(Requests)[0].Request.Action -eq 'ImportNode' -and @(Requests)[0].Request.UseProvider -eq $true) 'wizard opt-in imports all registered providers through the existing contract'
 Fixture;$script:Inspection.RegisteredProviders=@();$script:Wizard.UseProvider=$true;ShowSetup
 AssertUI (-not $script:Controls.UseProvider.IsEnabled -and -not $script:Controls.UseProvider.IsChecked) 'detected clients without registrations cannot be silently included'
 ClickUI 'WizardNext';AssertUI (@(Requests)[0].Request.UseProvider -eq $false) 'Hong Kong import is still possible without a provider'
 . (Join-Path $PSScriptRoot 'Test-LinuxUI.ps1')
 . (Join-Path $PSScriptRoot 'Test-092UI.ps1')
 . (Join-Path $PSScriptRoot 'Test-093UI.ps1')
 . (Join-Path $PSScriptRoot 'Test-010UI.ps1')
 # Minimum window: the primary action and all lanes stay usable.
 Fixture;$script:Window.Width=1000;$script:Window.Height=680;ShowHome;Snapshot '17-minimum-window'
 foreach($id in @('Primary','ProviderChoice',(SegId 'Daily' 'Trade'),(SegId 'Trade' 'Provider'),(SegId 'Agents' 'Trade'))){$c=$script:Controls[$id];$pt=$c.TranslatePoint((New-Object Windows.Point(0,0)),$script:Window.Content);AssertUI ($pt.X -ge 0 -and $pt.X+$c.ActualWidth -le $script:Window.Content.ActualWidth -and $c.ActualWidth -ge 60) ('visible at minimum width: '+$id)}
 ScrollToUI 'ProviderChoice';Snapshot '27-minimum-provider-choice'
 $combo=$script:Controls.ProviderChoice;$null=$combo.Focus();$combo.IsDropDownOpen=$true;$script:Window.UpdateLayout();AssertUI ($combo.IsKeyboardFocusWithin -and $combo.IsDropDownOpen) 'provider selector is keyboard reachable and expands with the shared theme';$combo.IsDropDownOpen=$false
 $script:Window.Width=1180;$script:Window.Height=800
 $null=$script:Window.FindName('NavSetup').Focus();AssertUI ($script:Window.FindName('NavSetup').IsKeyboardFocused) 'tabs are keyboard reachable'
 $script:Window.FindName('WindowMaximize').RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)));AssertUI ($script:Window.WindowState -eq 'Maximized') 'title bar maximizes'
 $script:Window.FindName('WindowMaximize').RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)));AssertUI ($script:Window.WindowState -eq 'Normal') 'title bar restores'
 $script:Window.FindName('WindowMinimize').RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)));AssertUI ($script:Window.WindowState -eq 'Minimized') 'title bar minimizes';$script:Window.WindowState='Normal'
 . (Join-Path $PSScriptRoot 'Test-011UI.ps1')
 . (Join-Path $PSScriptRoot 'Test-012UI.ps1')
 # New profile/selection regressions run in Test-0120UI, with its own fixtures.
 AssertUI (-not (Test-Path -LiteralPath $script:JobRoot)) 'isolated self-test never creates Worker job files'
 AssertUI (-not $script:Timer.IsEnabled -and $script:Smoke) 'self-test does not start polling or the Worker dispatcher'
 $result=[ordered]@{Passed=$true;Assertions=$script:Assertions.Count;Checks=$script:Assertions.ToArray();Screenshots=$qa;FixtureRoot=$script:Root;PowerShellVersion=[string]$PSVersionTable.PSVersion;RealNetworkChanged=$false;WorkerLaunched=$false;PhysicalRebootTested=$false}
 [IO.File]::WriteAllText((Join-Path $qa 'ui-result.json'),($result|ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($true)))
 $result|ConvertTo-Json -Depth 5
}finally{$script:Closing=$true;$script:Window.Close();ReleaseBrandResources}
