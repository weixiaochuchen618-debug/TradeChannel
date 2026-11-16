#requires -Version 5.1
[CmdletBinding()]
param([switch]$SelfTest,[string]$TestOutputDirectory,[switch]$ReadOnlyLaunch,[switch]$StartupLaunch)
$ErrorActionPreference='Stop'
# This process uses only Windows PowerShell inbox modules; do not inherit Core
# module autoload paths from a PowerShell 7 launcher. No machine setting changes.
$env:PSModulePath=Join-Path $PSHOME 'Modules'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Windows.Forms,System.Drawing
Import-Module (Join-Path $PSScriptRoot 'Version.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'DeploymentStore.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'UserSettings.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'AutoConnect.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'ProductText.psm1') -DisableNameChecking
$script:Version=Get-TCProductVersion -PackageRoot $PSScriptRoot
$script:PackageRoot=$PSScriptRoot
$script:UserDisconnectIntent=$false
# SelfTest owns a fresh temporary root. It never addresses the installed store.
$script:Root=if($SelfTest){Join-Path ([IO.Path]::GetTempPath()) ('TradeChannel-ui-fixture-'+[Guid]::NewGuid().ToString('N'))}else{Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'TradeChannel'}
$script:Store=Join-Path $script:Root 'Product';$script:JobRoot=Join-Path $script:Store 'jobs'
$script:Smoke=[bool]$SelfTest;$script:ReadOnly=[bool]$ReadOnlyLaunch
$script:UserSettings=Get-TCUserSettings -Root $script:Root
$script:LoginAutoConnect=New-TCAutoConnectLaunch -StartupLaunch:$StartupLaunch -SelfTest:$SelfTest -ReadOnlyLaunch:$ReadOnlyLaunch
$script:QueuedJob=$null;$script:UiMutex=$null;$script:WakeEvent=$null
if(-not $SelfTest -and -not $ReadOnlyLaunch){
 $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;$created=$false
 $script:UiMutex=New-Object Threading.Mutex($true,('Local\TradeChannel.UI.'+$sid),[ref]$created)
 $script:WakeEvent=New-Object Threading.EventWaitHandle($false,[Threading.EventResetMode]::AutoReset,('Local\TradeChannel.Wake.'+$sid))
 if(-not $created){$null=$script:WakeEvent.Set();$script:WakeEvent.Dispose();$script:UiMutex.Dispose();exit 0}
}
# Interaction model: what you see is what runs.
#  - Daily traffic choices never touch trading connections, so they apply at once.
#  - Changing the trading line interrupts trading sessions, so it is confirmed first.
#  - While disconnected, every choice is only saved for the next connection.
$script:Page='home';$script:Step=0;$script:Role='client';$script:Inspection=$null;$script:ServerPlan=$null
$script:Nodes=@();$script:Overview=$null;$script:Prefs=@{Mode='Trading';Exit='HongKong';Daily='Direct';NodeId=$null;ProviderId=$null;TradeProviderId=$null;Agents='Daily';AgentIds=$null;AgentCustom=@();OpenAtLogin=$false}
$script:Providers=$null;$script:ProvidersAt=[DateTime]::MinValue;$script:ProviderReadError=$null;$script:ProviderReports=@{};$script:ProviderNotice=$null
$script:ProviderFormOpen=$false;$script:ProviderForm=@{Kind='custom';Name='';Directory='';DailyPort='';TradePort=''}
$script:PendingProviderCheck=$null;$script:PendingTrade=$null
$script:AgentPresence=$null;$script:AgentPresenceAt=[DateTime]::MinValue
# 名单草稿：编辑期不提交，IsBusy 恒为 false，点多少下都是本地响应；保存才走一次 Apply。
$script:AgentDraft=$null;$script:AgentSaveState='Idle';$script:AgentPendingPage='';$script:AgentLeaveTarget='';$script:AgentHintBase=''
$script:Job=$null;$script:Pending=$null;$script:Checks=$null;$script:LastPoll=[DateTime]::MinValue;$script:Controls=@{};$script:Closing=$false;$script:DialogCallback=$null
$script:HomeSignature=$null;$script:StatusDetailsOpen=$false
$script:ScrollRestoreState=@{Generation=0;ViewKey=$null}
$script:ResponsiveLayouts=New-Object 'Collections.Generic.List[object]'
$script:Actions=New-Object 'System.Collections.Generic.List[object]'
$script:AllSelfTestRequests=New-Object 'System.Collections.Generic.List[object]'
$script:Wizard=@{Name='新的自建节点';Path='';Programs=@();Dns='';UseProvider=$false;Endpoint='';InterfaceAlias='';Subnet='10.78.0.0/24';PlanPath='';RequestPath='';Address=''}
if(-not $SelfTest){
 $principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
 if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){[Windows.MessageBox]::Show('请从 TradeChannel.exe 启动，并允许本机管理权限。','无法启动')|Out-Null;exit 1}
 $fresh=-not(Test-Path -LiteralPath $script:Root);$null=New-Item -ItemType Directory -Path $script:JobRoot -Force
 if(-not $ReadOnlyLaunch){
  $acl=New-Object Security.AccessControl.DirectorySecurity;$acl.SetAccessRuleProtection($true,$false)
  foreach($id in @('S-1-5-18','S-1-5-32-544')){$sid=New-Object Security.Principal.SecurityIdentifier($id);$acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow')))}
  Set-Acl -LiteralPath $script:Store -AclObject $acl;if($fresh){Set-Acl -LiteralPath $script:Root -AclObject $acl}
 }
}
[xml]$xaml=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'ui\Shell.xaml') -Encoding UTF8 -Raw
$reader=New-Object Xml.XmlNodeReader($xaml);$script:Window=[Windows.Markup.XamlReader]::Load($reader)
$markPath=Join-Path $PSScriptRoot 'assets\TradeChannel.png'
if(Test-Path -LiteralPath $markPath){$script:Window.Icon=[Windows.Media.Imaging.BitmapFrame]::Create((New-Object Uri($markPath)))}
$script:HostPanel=$script:Window.FindName('ContentHost');$script:Footer=$script:Window.FindName('FooterStatus')
function SetTCChromeDensity {
 [CmdletBinding()]param([Parameter(Mandatory=$true)][bool]$WebActive)
 # WebShell owns surface transitions: show/form => true, suspend/failure => false.
 # Keep launch-mode labels independent of the version hidden by the web surface.
 $script:TCWebChromeActive=$WebActive
 $modes=@()
 if($script:ReadOnly){$modes+='READ ONLY'}
 if($script:Smoke){$modes+='UI TEST'}
 $modeText=$modes -join ' / '
 $context='TradeChannel '+$script:Version
 if($modeText){$context+=' / '+$modeText}
 $script:Window.FindName('FooterContext').Text=$context
 $script:Window.FindName('FooterMode').Text=$modeText
 $fallbackVisibility=if($WebActive){'Collapsed'}else{'Visible'}
 foreach($name in @('StatusChip','FooterStatus','FooterContext')){
  $script:Window.FindName($name).Visibility=$fallbackVisibility
 }
 $script:Window.FindName('FooterMode').Visibility=if($WebActive -and $modeText){'Visible'}else{'Collapsed'}
 $showFooter=(-not $WebActive -or [bool]$modeText)
 $script:Window.FindName('ShellFooter').Visibility=if($showFooter){'Visible'}else{'Collapsed'}
 $script:Window.FindName('ShellFooterRow').Height=if($showFooter){[Windows.GridLength]30}else{[Windows.GridLength]0}
}
SetTCChromeDensity -WebActive $false
function SetTCChromeTheme {
 [CmdletBinding()]param([Parameter(Mandatory=$true)][ValidateSet('light','dark')][string]$Theme)
 $palette=if($Theme -eq 'dark'){
  @{ChromeSurface='#141E30';ChromeDivider='#28364C';ChromeTitle='#E5EBF7';ChromeIcon='#9BAAC2';ChromeNav='#9BAAC2';ChromeNavHover='#F4F7FC';ChromeHover='#1C2940';ChromeFocus='#91AAFF'}
 }else{
  @{ChromeSurface='#FFFFFF';ChromeDivider='#E6E8EB';ChromeTitle='#15181D';ChromeIcon='#4B5360';ChromeNav='#6B7280';ChromeNavHover='#15181D';ChromeHover='#E9EBEE';ChromeFocus='#2B59E8'}
 }
 $converter=New-Object Windows.Media.BrushConverter
 foreach($key in $palette.Keys){$script:Window.Resources[$key]=$converter.ConvertFromString($palette[$key])}
}
SetTCChromeTheme -Theme 'light'

# ---------- Design system ----------
$script:Ink='#15181D';$script:Text2='#4B5360';$script:Text3='#858C97';$script:Hair='#E6E8EB'
$script:Tone=@{
 ok=@{Fg='#15803D';Bg='#ECF8F0';Dot='#22A55B'};warn=@{Fg='#A15C07';Bg='#FDF5E8';Dot='#E19A1D'}
 bad=@{Fg='#B42318';Bg='#FEF1F0';Dot='#E5484D'};info=@{Fg='#1D4ED8';Bg='#EEF3FE';Dot='#3B6FF6'};idle=@{Fg='#4B5360';Bg='#F2F3F5';Dot='#A9AFB8'}
}
function B {param([string]$Hex);if(-not $Hex){throw ('EMPTY COLOR: '+((Get-PSCallStack|Select-Object -Skip 1 -First 4|ForEach-Object {$_.Command+':'+$_.ScriptLineNumber}) -join ' <- '))};$c=New-Object Windows.Media.BrushConverter;return $c.ConvertFromString($Hex)}
function AddC {param($Parent,$Child);$null=$Parent.Children.Add($Child)}
function T {param([string]$Text,[double]$Size=13,[string]$Color=$script:Ink,[string]$Weight='Normal')
 $t=New-Object Windows.Controls.TextBlock;$t.Text=$Text;$t.FontSize=$Size;$t.Foreground=B $Color;$t.TextWrapping='Wrap';$t.FontWeight=$Weight
 $t.LineHeight=[Math]::Round($Size*1.55);return $t
}
function Stack {param([string]$Orientation='Vertical');$s=New-Object Windows.Controls.StackPanel;$s.Orientation=$Orientation;return $s}
function Card {param([string]$Padding='22,20');$b=New-Object Windows.Controls.Border;$b.Background=B '#FFFFFF';$b.BorderBrush=B $script:Hair;$b.BorderThickness='1';$b.CornerRadius='14';$b.Padding=[Windows.Thickness]$Padding;return $b}
function Margin {param($Element,[string]$Value);$Element.Margin=[Windows.Thickness]$Value;return $Element}
function Grid {param([string[]]$Columns);$g=New-Object Windows.Controls.Grid;foreach($w in $Columns){$c=New-Object Windows.Controls.ColumnDefinition;$c.Width=$w;$g.ColumnDefinitions.Add($c)};return $g}
function Cell {param($Grid,$Child,[int]$Column=0);[Windows.Controls.Grid]::SetColumn($Child,$Column);AddC $Grid $Child}
function ControlName {param($Control,[string]$Id);$Control.Name=$Id;[Windows.Automation.AutomationProperties]::SetAutomationId($Control,$Id);$script:Controls[$Id]=$Control;return $Control}
function Btn {param([string]$Text,[string]$Id,[scriptblock]$Click,[string]$Style='Btn');$b=New-Object Windows.Controls.Button;$b.Content=$Text;$b.Style=$script:Window.FindResource($Style);$b.Add_Click($Click);if($Id){$b=ControlName $b $Id};return $b}
# 0.22.0 B2：说明通道。HelpTip 把说明同时写进 ToolTip 与 AutomationProperties.HelpText，
# 序列化器（ui/WebForms.ps1）据此给节点挂 Hint，网页渲染成 ⓘ 悬浮说明；降级壳直接用 ToolTip。
function HelpTip {param($Control,[string]$Text)
 if(-not $Control -or -not $Text){return $Control}
 $Control.ToolTip=$Text
 [Windows.Automation.AutomationProperties]::SetHelpText($Control,$Text)
 [Windows.Controls.ToolTipService]::SetShowOnDisabled($Control,$true)
 [Windows.Controls.ToolTipService]::SetInitialShowDelay($Control,300)
 return $Control
}
function HintIcon {param([string]$Text,[string]$Id='')
 $b=New-Object Windows.Controls.Button
 $b.Content=[string][char]0x24D8
 $b.Style=$script:Window.FindResource('Ghost')
 $b.MinWidth=24;$b.Padding=[Windows.Thickness]'4,0';$b.FontSize=12;$b.VerticalAlignment='Center'
 $b.Tag=[pscustomobject]@{TCHint=$Text}
 $null=HelpTip $b $Text
 [Windows.Automation.AutomationProperties]::SetName($b,'说明')
 if($Id){$b=ControlName $b $Id}
 # 键盘用户按 Enter/空格也能看到说明：Popup 点外部即关，不影响任何业务状态。
 # GetNewClosure 会新建独立 session state，闭包内 $script:Hair/$script:Ink 取不到，
 # 所以在闭包外先把颜色取成局部变量，由闭包捕获值。
 $hintHair=if($script:Hair){[string]$script:Hair}else{'#E6E8EB'}
 $hintInk=if($script:Ink){[string]$script:Ink}else{'#15181D'}
 $b.Add_Click({
  $popup=New-Object Windows.Controls.Primitives.Popup
  $popup.StaysOpen=$false;$popup.PlacementTarget=$b;$popup.Placement='Top';$popup.AllowsTransparency=$true
  $border=New-Object Windows.Controls.Border
  $border.Background=B '#FFFFFF';$border.BorderBrush=B $hintHair;$border.BorderThickness='1'
  $border.CornerRadius='10';$border.Padding=[Windows.Thickness]'12,10';$border.MaxWidth=320
  $border.Child=(T $Text 12.5 $hintInk)
  $popup.Child=$border;$popup.IsOpen=$true
  $b|Add-Member -NotePropertyName HintPopup -NotePropertyValue $popup -Force
 }.GetNewClosure())
 return $b
}
function TitleWithHint {param([string]$Title,[string]$Hint,[double]$Size=18)
 $row=Stack 'Horizontal'
 AddC $row (T $Title $Size $script:Ink 'SemiBold')
 if($Hint){AddC $row (Margin (HintIcon $Hint) '6,2,0,0')}
 return $row
}
function Icon {param([string]$Name,[int]$Size=18,[string]$Color=$script:Text2)
 $paths=@{
  trade='M 3 17 L 9 11 L 13 15 L 21 7 M 15 7 L 21 7 L 21 13'
  globe='M 21 12 A 9 9 0 1 1 3 12 A 9 9 0 1 1 21 12 M 3 12 L 21 12 M 12 3 C 7 8 7 16 12 21 C 17 16 17 8 12 3'
  shield='M 12 3 L 19.5 6 L 19 13 C 18.5 17.5 15.5 20 12 21.5 C 8.5 20 5.5 17.5 5 13 L 4.5 6 Z M 8.8 12.2 L 11 14.4 L 15.4 9.8'
  pulse='M 3 12 L 7 12 L 9.5 6 L 14 18 L 16.5 12 L 21 12'
  server='M 4 4 L 20 4 L 20 10 L 4 10 Z M 4 14 L 20 14 L 20 20 L 4 20 Z M 7.5 7 L 7.6 7 M 7.5 17 L 7.6 17'
  laptop='M 5 5 L 19 5 L 19 15 L 5 15 Z M 2.5 19 L 21.5 19'
  key='M 14.5 3.5 A 5 5 0 1 1 9.5 8.5 A 5 5 0 0 1 14.5 3.5 M 10.5 12.5 L 3.5 19.5 L 3.5 21 L 6.5 21 L 6.5 18.5 L 9 18.5 L 11.5 16'
  folder='M 3 6.5 L 3 19 L 21 19 L 21 8 L 11.5 8 L 9.5 5 L 3 5 Z'
  document='M 6 3 L 14.5 3 L 19 7.5 L 19 21 L 6 21 Z M 14.5 3 L 14.5 7.5 L 19 7.5 M 9 12.5 L 16 12.5 M 9 16 L 16 16'
  move='M 4 8 L 18 8 M 14.5 4.5 L 18 8 L 14.5 11.5 M 20 16 L 6 16 M 9.5 12.5 L 6 16 L 9.5 19.5'
  info='M 21 12 A 9 9 0 1 1 3 12 A 9 9 0 1 1 21 12 M 12 11 L 12 16.5 M 12 7.6 L 12 7.8'
  alert='M 12 3.5 L 21.5 20 L 2.5 20 Z M 12 9.5 L 12 14 M 12 17 L 12 17.2'
  check='M 5 12.5 L 10 17 L 19.5 7'
  power='M 12 3 L 12 11.5 M 7 6.2 A 7.8 7.8 0 1 0 17 6.2'
  plus='M 12 5 L 12 19 M 5 12 L 19 12'
  arrow='M 5 12 L 19 12 M 13.5 6.5 L 19 12 L 13.5 17.5'
  settings='M 4 7 L 20 7 M 4 17 L 20 17 M 9 4.5 L 9 9.5 M 15 14.5 L 15 19.5'
  agent='M 4 5 L 20 5 L 20 16 L 11 16 L 6.5 20 L 6.5 16 L 4 16 Z M 8.5 10.5 L 8.6 10.5 M 12 10.5 L 12.1 10.5 M 15.5 10.5 L 15.6 10.5'
 }
 if(-not $paths.ContainsKey($Name)){$Name='info'}
 $canvas=New-Object Windows.Controls.Canvas;$canvas.Width=24;$canvas.Height=24
 $p=New-Object Windows.Shapes.Path;$p.Data=[Windows.Media.Geometry]::Parse($paths[$Name]);$p.Stroke=B $Color;$p.StrokeThickness=1.7;$p.StrokeStartLineCap='Round';$p.StrokeEndLineCap='Round';$p.StrokeLineJoin='Round';AddC $canvas $p
 $v=New-Object Windows.Controls.Viewbox;$v.Width=$Size;$v.Height=$Size;$v.Child=$canvas
 # 0.23.0：Path 是 Shape，网页投影会丢弃它；只把白名单里的名字带过线，前端还原同一份几何。
 $v.Tag=[pscustomobject]@{TCIcon=$Name}
 return $v
}
function IconTile {param([string]$Name,[int]$Size=38,[string]$Bg='#F2F3F5',[string]$Color=$script:Ink)
 $tile=New-Object Windows.Controls.Border;$tile.Width=$Size;$tile.Height=$Size;$tile.CornerRadius='10';$tile.Background=B $Bg;$tile.VerticalAlignment='Top';$tile.Child=Icon $Name ([int]($Size*0.5)) $Color;$tile.Tag=[pscustomobject]@{TCRole='tile'};return $tile
}
function Dot {param([string]$Tone='idle',[int]$Size=8)
 $c=$script:Tone[$Tone];$g=New-Object Windows.Controls.Grid;$g.Width=$Size*2.2;$g.Height=$Size*2.2;$g.VerticalAlignment='Center'
 $halo=New-Object Windows.Shapes.Ellipse;$halo.Fill=B $c.Bg;AddC $g $halo
 $core=New-Object Windows.Shapes.Ellipse;$core.Width=$Size;$core.Height=$Size;$core.Fill=B $c.Dot;AddC $g $core;return $g
}
function Pill {param([string]$Text,[string]$Tone='idle',[string]$Bg='');$c=if($Tone.StartsWith('#')){@{Fg=$Tone;Bg=$(if($Bg){$Bg}else{'#F2F3F5'})}}elseif($script:Tone.ContainsKey($Tone)){$script:Tone[$Tone]}else{$script:Tone.idle};$b=New-Object Windows.Controls.Border;$b.CornerRadius='10';$b.Background=B $c.Bg;$b.Padding='9,3';$b.HorizontalAlignment='Left';$b.VerticalAlignment='Center';$b.Child=T $Text 11.5 $c.Fg 'SemiBold';$b.Tag=[pscustomobject]@{TCRole='chip'};return $b}
function Rule {param([string]$Margin='0,16,0,16');$b=New-Object Windows.Controls.Border;$b.Height=1;$b.Background=B '#EEF0F2';$b.Margin=[Windows.Thickness]$Margin;return $b}
function PageHead {param([string]$Title,[string]$Description,[string]$Page)
 $webForm=($script:WebReady -and -not $script:WebFailed -and (-not $script:Smoke -or $script:WebFormsFixture))
 if(-not $webForm -and (Get-Command SuspendTCWebShell -ErrorAction SilentlyContinue)){SuspendTCWebShell}
 if(($Page -ne 'setup' -or $script:Role -ne 'deployment') -and (Get-Command SetDeploymentPasswordVisibilityUI -ErrorAction SilentlyContinue)){SetDeploymentPasswordVisibilityUI $false}
 $scroll=$script:Window.FindName('Scroll');$state=$script:ScrollRestoreState
 if(Get-Command SyncNavigationContext -ErrorAction SilentlyContinue){SyncNavigationContext -Page $Page -Title $Title}
 $target=if(Get-Command NavigationVariable -ErrorAction SilentlyContinue){NavigationField (NavigationVariable 'NavigationContext') 'TargetId' ''}else{''}
 $viewKey=@($Page,$Title,$script:Role,$script:Step,$script:DeployUI.Screen,$target) -join '|'
 $sameView=($state.ViewKey -ceq $viewKey);$offset=$scroll.VerticalOffset
 $atBottom=($scroll.ScrollableHeight -gt 1 -and [Math]::Abs($offset-$scroll.ScrollableHeight) -lt 2)
 $state.Generation++;$generation=$state.Generation;$state.ViewKey=$viewKey
 $script:HostPanel.Children.Clear();$script:ResponsiveLayouts.Clear();$script:Controls=@{};$script:Page=$Page
 # 页面操作条只属于当前页面：换页即清空，不让任何页面依赖「记得自己清理」。
 $actionHost=$script:Window.FindName('PageActionHost');if($actionHost){$actionHost.Children.Clear()}
 $actionBar=$script:Window.FindName('PageActionBar');if($actionBar){$actionBar.Visibility='Collapsed'}
 if($webForm){StartTCWebFormView -Title $Title -Description $Description -Page $Page;ShowTCWebFormSurface}
 if(-not $sameView){$scroll.ScrollToTop()}
 if($Title){AddC $script:HostPanel (T $Title 24 $script:Ink 'SemiBold')};if($Description){AddC $script:HostPanel (Margin (T $Description 13 $script:Text3) '0,4,0,22')}
 UpdateTabs;UpdateChrome
 if($webForm){$null=$script:Window.Dispatcher.BeginInvoke([Action]{SyncTCWebState -Force},[Windows.Threading.DispatcherPriority]::Loaded)}
 # Children are rebuilt after PageHead returns. Restore only the newest view,
 # after layout, and retain the bottom anchor when the user was reading there.
 $restore={
  if($state.Generation -ne $generation -or $state.ViewKey -cne $viewKey){return}
  $scroll.UpdateLayout()
  if(-not $sameView){$scroll.ScrollToTop()}elseif($atBottom){$scroll.ScrollToEnd()}else{$scroll.ScrollToVerticalOffset([Math]::Min($offset,$scroll.ScrollableHeight))}
 }.GetNewClosure()
 $null=$scroll.Dispatcher.BeginInvoke([Action]$restore,[Windows.Threading.DispatcherPriority]::Loaded)
}
function AddResponsiveLayout {param($Grid,[ValidateSet('Lane','Cards')][string]$Kind)
 $script:ResponsiveLayouts.Add([pscustomobject]@{Grid=$Grid;Kind=$Kind})
 UpdateResponsiveLayouts
}
function UpdateResponsiveLayouts {param([double]$Width=0)
 if($Width -le 0){$Width=$script:HostPanel.ActualWidth};if($Width -le 0){$Width=$script:Window.Width-84}
 $compact=($Width -lt 1040)
 foreach($layout in $script:ResponsiveLayouts){
  $g=$layout.Grid
  if($g.Tag -eq [string]$compact){continue};$g.Tag=[string]$compact
  if($layout.Kind -eq 'Lane'){
   $choices=$g.Children[2];$g.RowDefinitions.Clear()
   if($compact){
    foreach($n in 0..1){$r=New-Object Windows.Controls.RowDefinition;$r.Height='Auto';$g.RowDefinitions.Add($r)}
    [Windows.Controls.Grid]::SetRow($choices,1);[Windows.Controls.Grid]::SetColumn($choices,0);[Windows.Controls.Grid]::SetColumnSpan($choices,3);$choices.Margin='0,14,0,0';$choices.HorizontalAlignment='Left'
   }else{
    [Windows.Controls.Grid]::SetRow($choices,0);[Windows.Controls.Grid]::SetColumn($choices,2);[Windows.Controls.Grid]::SetColumnSpan($choices,1);$choices.Margin='20,0,0,0';$choices.HorizontalAlignment='Stretch'
   }
  }else{
   $g.RowDefinitions.Clear();$g.ColumnDefinitions.Clear()
   $widths=if($compact){@('*','16','*')}else{@('*','16','*','16','*')}
   foreach($w in $widths){$c=New-Object Windows.Controls.ColumnDefinition;$c.Width=$w;$g.ColumnDefinitions.Add($c)}
   for($index=0;$index -lt $g.Children.Count;$index++){
    $child=$g.Children[$index];[Windows.Controls.Grid]::SetRow($child,0);[Windows.Controls.Grid]::SetColumn($child,$index*2);[Windows.Controls.Grid]::SetColumnSpan($child,1);$child.Margin='0'
   }
   if($compact){
    foreach($n in 0..1){$r=New-Object Windows.Controls.RowDefinition;$r.Height='Auto';$g.RowDefinitions.Add($r)}
    $last=$g.Children[2];[Windows.Controls.Grid]::SetRow($last,1);[Windows.Controls.Grid]::SetColumn($last,0);[Windows.Controls.Grid]::SetColumnSpan($last,3);$last.Margin='0,16,0,0'
   }
  }
 }
}
$script:HostPanel.Add_SizeChanged({param($sender,$e)if([Math]::Abs($e.NewSize.Width-$e.PreviousSize.Width) -gt 0.5){UpdateResponsiveLayouts $e.NewSize.Width}})
# 0.22.0 B5：-Hint 是必须直接显示的状态；-Tip 是概念/默认行为说明，走 ⓘ（B3）。
function SectionLabel {param($Parent,[string]$Text,[string]$Hint='',[string]$Tip='',[string]$HintId='')
 $row=Grid @('*','Auto');$row.Margin='2,26,2,10'
 $head=Stack 'Horizontal';AddC $head (T $Text 12 $script:Text3 'SemiBold')
 if($Tip){AddC $head (Margin (HintIcon $Tip) '5,0,0,0')}
 Cell $row $head 0
 if($Hint){$h=T $Hint 12 $script:Text3;$h.HorizontalAlignment='Right';$h.VerticalAlignment='Center';if($HintId){$h=ControlName $h $HintId};Cell $row $h 1}
 AddC $Parent $row}
function KeyValue {param($Parent,[string]$Label,[string]$Value,[string]$Color=$script:Ink,[string]$Id='')
 $g=Grid @('128','*');$g.Margin='0,5,0,5';Cell $g (T $Label 12.5 $script:Text3) 0;$v=T $Value 12.5 $Color 'SemiBold';if($Id){$v=ControlName $v $Id};Cell $g $v 1;AddC $Parent $g
}
# Banner for states that need attention before (or instead of) the normal flow.
function Notice {param([string]$Tone,[string]$Title,[string]$Text,[string]$ActionText='',[scriptblock]$Action=$null,[string]$Id='')
 $c=$script:Tone[$Tone];$b=New-Object Windows.Controls.Border;$b.Background=B $c.Bg;$b.CornerRadius='12';$b.Padding='16,13';$b.Margin='0,0,0,12'
 $g=Grid @('Auto','*','Auto');$icon=Icon $(if($Tone -in @('warn','bad')){'alert'}else{'info'}) 18 $c.Fg;$icon.Margin='0,1,12,0';$icon.VerticalAlignment='Top';Cell $g $icon 0
 $copy=Stack;AddC $copy (T $Title 13 $c.Fg 'SemiBold');if($Text){AddC $copy (Margin (T $Text 12.5 $script:Text2) '0,3,0,0')};Cell $g $copy 1
 if($ActionText){$btn=Btn $ActionText $Id $Action 'Btn';$btn.Margin='16,0,0,0';$btn.VerticalAlignment='Center';Cell $g $btn 2}
 $b.Child=$g;return $b
}
# Segmented control. Options: @{Label;Value;Enabled;Tip}. Click handlers receive Tag @{Group;Value}.
function Segments {param([string]$Group,[object[]]$Options,[string]$Selected,[bool]$Enabled=$true)
 $box=New-Object Windows.Controls.Border;$box.Background=B '#EEF0F3';$box.CornerRadius='9';$box.Padding='3';$box.HorizontalAlignment='Right';$box.VerticalAlignment='Center'
 $row=Stack 'Horizontal'
 foreach($o in $Options){
  $id='Seg'+$Group+(([string]$o.Value) -replace '[^A-Za-z0-9]','')
  $btn=Btn ([string]$o.Label) $id {OnSegment $this.Tag.Group $this.Tag.Value} $(if([string]$o.Value -eq $Selected){'SegOn'}else{'Seg'})
  $btn.Tag=@{Group=$Group;Value=[string]$o.Value};$btn.MinWidth=104;$btn.IsEnabled=($Enabled -and $o.Enabled -ne $false);if($o.Tip){$btn.ToolTip=[string]$o.Tip;[Windows.Controls.ToolTipService]::SetShowOnDisabled($btn,$true)}
  AddC $row $btn
 }
 $box.Child=$row;$box.Tag=[pscustomobject]@{TCRole='group'};return $box
}
function UpdateTabs {
 $ink=B $script:Ink;$clear=[Windows.Media.Brushes]::Transparent
 $section=if(Get-Command NavigationVariable -ErrorAction SilentlyContinue){NavigationField (NavigationVariable 'NavigationContext') 'Section' $script:Page}else{$script:Page}
 foreach($pair in @(@('NavHome','home'),@('NavNodes','nodes'),@('NavSetup','setup'),@('NavSettings','settings'))){
  $b=$script:Window.FindName($pair[0]);$on=($section -eq $pair[1])
  $b.Tag=$(if($on){$ink}else{$clear});$b.Foreground=B $(if($on){$script:Ink}else{'#6B7280'});$b.FontWeight=$(if($on){'SemiBold'}else{'Normal'})
 }
}
function Field {param($Parent,[string]$Label,[string]$Key,[string]$Hint='',[switch]$ReadOnly)
 AddC $Parent (Margin (T $Label 12.5 $script:Ink 'SemiBold') '0,12,0,7');$box=New-Object Windows.Controls.TextBox;$box.Text=[string]$script:Wizard[$Key];$box.IsReadOnly=[bool]$ReadOnly;$box.Tag=$Key
 $box.Add_TextChanged({$script:Wizard[[string]$this.Tag]=$this.Text});$box=ControlName $box ('Field'+$Key);AddC $Parent $box;if($Hint){AddC $Parent (Margin (T $Hint 12 $script:Text3) '0,6,0,4')};return $box
}
function Row {param($Parent,[string]$Label,[string]$Value,[string]$Color=$script:Ink);KeyValue $Parent $Label $Value $Color}

# ---------- Dialog & toast ----------
function SetChromeEnabled {param([bool]$Enabled);foreach($id in @('NavHome','NavNodes','NavSetup','NavSettings')){$script:Window.FindName($id).IsEnabled=$Enabled}}
function OpenDialog {param([string]$Title,[string]$Body,[string]$Note,[string]$Confirm='确定',[scriptblock]$Action=$null,[string]$Cancel='取消',[string]$ConfirmStyle='Primary',$Context=$null,[switch]$SafeDefault)
 $script:Window.FindName('DialogTitle').Text=$Title;$script:Window.FindName('DialogBody').Text=$Body;$script:Window.FindName('DialogNote').Text=$Note
 $script:Window.FindName('DialogNoteBox').Visibility=$(if($Note){'Visible'}else{'Collapsed'})
 $confirmButton=$script:Window.FindName('DialogConfirm');$confirmButton.Content=$Confirm;$confirmButton.Style=$script:Window.FindResource($ConfirmStyle)
 $cancelButton=$script:Window.FindName('DialogCancel');$cancelButton.Content=$Cancel;$cancelButton.Visibility=$(if($Cancel){'Visible'}else{'Collapsed'})
 $script:WebDialogId=[guid]::NewGuid().ToString('N');$script:WebLastDialog=@($Title,$Body,$Confirm) -join '|'
 $script:DialogCallback=$Action;$script:DialogContext=$Context;$script:Window.FindName('Overlay').Visibility='Visible'
 # Destructive confirmations, and any that interrupt trading sessions, start on
 # the safe choice; Enter never disconnects or switches the trading line by accident.
 if(($ConfirmStyle -eq 'Danger' -or $SafeDefault) -and $Cancel){$null=$cancelButton.Focus()}else{$null=$confirmButton.Focus()}
 $script:HostPanel.IsEnabled=$false;SetChromeEnabled $false
}
function CloseDialog {
 $script:Window.FindName('Overlay').Visibility='Collapsed';$script:DialogCallback=$null;$script:DialogContext=$null;$script:HostPanel.IsEnabled=(-not $script:Job -or $script:Job.Silent);SetChromeEnabled $true
 if($script:Footer.Text -like '正在*'){$script:Footer.Text='状态就绪 · '+(Get-Date -Format 'HH:mm:ss')}
}
$script:Window.FindName('DialogCancel').Add_Click({CloseDialog})
$script:Window.FindName('DialogConfirm').Add_Click({$action=$script:DialogCallback;$context=$script:DialogContext;CloseDialog;if($action){& $action $context}})
function ErrorDialog {param([string]$Message)
 if($Message -match '\[TC:NeedsRecovery\]' -and (Get-Command ShowConnectionTransactionRecoveryPrompt -ErrorAction SilentlyContinue)){ShowConnectionTransactionRecoveryPrompt $Message;return}
 # A leading internal tag such as [TC:ProbeRouteUnverified] is for support, not for the
 # person reading the dialog: show the plain sentence and keep the code in the folded details.
 $details='';if($Message -match '^\s*\[TC:([A-Za-z][A-Za-z0-9_]{0,63})\]\s*'){$details='错误代码：'+$Matches[1];$Message=$Message.Substring($Matches[0].Length)}
 OpenDialog '操作未完成' $Message '这次操作没有被标记为成功。可以修正后重试，或先查看实际状态。' '知道了' $null '' -Context @{Details=$details}
}
function ResultDialog {param($Value,[string]$Title='操作完成')
 $lines=New-Object 'System.Collections.Generic.List[string]';if($Value.Friendly){$lines.Add([string]$Value.Friendly)}elseif($Value.Next){$lines.Add([string]$Value.Next)}
 if($Value.NextStep){$lines.Add([string]$Value.NextStep)}elseif($Value.RestartRequired){$lines.Add('请在维护窗口由客户端重新载入配置，再重新检查出口；此步骤未重启客户端或通道。')}
 foreach($warning in @($Value.Warnings|Where-Object {$_})){if($warning -is [string]){$lines.Add($warning)}elseif($warning.Text){$lines.Add([string]$warning.Text)}}
 $labels=[ordered]@{PlanPath='计划文件';RequestPath='公开设备申请';KeyPath='本机私钥（勿分享）';RequestDirectory='申请目录';ResponsePath='返回授权文件';ConfigPath='客户端配置';BackupPath='备份位置';MergePath='客户端扩展配置';TradePort='交易备用端口';RollbackPath='回退记录';path='保存位置'}
 foreach($k in $labels.Keys){if($Value.$k){$lines.Add($labels[$k]+'：'+[string]$Value.$k)}}
 if($Value.Plan){$p=$Value.Plan;$lines.Add('节点：'+$p.Name);$lines.Add('公网入口：'+$p.PublicEndpoint);$lines.Add('隧道网段：'+$p.TunnelSubnet);$lines.Add('新增 NAT：'+$p.NatName);$lines.Add('云端请放行：'+$p.RequiredCloudRule)}
 if(-not $lines.Count){$lines.Add('操作已完成。交易连接、行情和订单仍需在交易软件中分别确认。')};OpenDialog $Title ($lines.ToArray() -join "`n") '' '知道了' $null ''
}
$script:ToastTimer=New-Object Windows.Threading.DispatcherTimer;$script:ToastTimer.Interval=[TimeSpan]::FromMilliseconds(2600)
$script:ToastTimer.Add_Tick({$script:ToastTimer.Stop();$script:Window.FindName('Toast').Visibility='Collapsed'})
function Toast {param([string]$Text);$script:LastToast=$Text;$script:Window.FindName('ToastText').Text=$Text;$script:Window.FindName('Toast').Visibility='Visible';$script:ToastTimer.Stop();$script:ToastTimer.Start()}
# Copy buttons never throw: a busy clipboard used to surface as "操作未完成" and
# stopped whatever the button did next. The text stays visible on the page.
function CopyText {param([string]$Text,[string]$Done='已复制')
 if($script:Smoke){$script:LastCopiedText=$Text;Toast $Done;return $true}
 try{
  if(-not ('TradeChannel.UI.ClipboardNative' -as [type])){Add-Type -Path (Join-Path $script:PackageRoot 'BrandNative.cs')}
  $owner=[IntPtr]::Zero;try{$owner=(New-Object Windows.Interop.WindowInteropHelper($script:Window)).Handle}catch{}
  $deadline=[DateTime]::UtcNow.AddSeconds(2)
  do{if([TradeChannel.UI.ClipboardNative]::TrySetText($owner,$Text)){Toast $Done;return $true};Start-Sleep -Milliseconds 60}while([DateTime]::UtcNow -lt $deadline)
 }catch{}
 Toast '剪贴板被其他程序占用，没有复制成功；请在页面上选中后手动复制'
 return $false
}
function ChooseFile {param([string]$Title,[string]$Filter,[switch]$Save,[string]$Name='');$d=if($Save){New-Object Microsoft.Win32.SaveFileDialog}else{New-Object Microsoft.Win32.OpenFileDialog};$d.Title=$Title;$d.Filter=$Filter;$d.FileName=$Name;if($d.ShowDialog($script:Window)){return $d.FileName}}
function ChooseFolder {param([string]$Text);$d=New-Object Windows.Forms.FolderBrowserDialog;$d.Description=$Text;try{if($d.ShowDialog() -eq 'OK'){return $d.SelectedPath}}finally{$d.Dispose()}}

# ---------- Background jobs (Worker.ps1, one at a time) ----------
. (Join-Path $PSScriptRoot 'ui\BackgroundJobs.ps1')
. (Join-Path $PSScriptRoot 'ui\MemoryJobs.ps1')
function StopLoginAutoConnectUI {
 if($script:LoginAutoConnect.Status -in @('Waiting','Previewing')){$script:LoginAutoConnect.Status='Skipped';$script:LoginAutoConnect.Reason='已选择手动操作'}
}
function InvokeLoginAutoConnectTick {
 if($script:LoginAutoConnect.Status -cne 'Waiting'){return}
 if($script:Smoke -or $script:ReadOnly -or -not $StartupLaunch){StopLoginAutoConnectUI;return}
 $busy=[bool]($script:Job -or $script:JobQueue.Count -or $script:UncertainUiJobs.Count -or $script:Pending)
 # A user mutation wins over the pending login attempt, including a disconnect.
 if($script:UncertainUiJobs.Count -or ($script:Job -and -not $script:Job.Policy.ReadOnly)){StopLoginAutoConnectUI;return}
 $network=$false
 try{$network=[Net.NetworkInformation.NetworkInterface]::GetIsNetworkAvailable()}catch{}
 if(-not (Get-TCAutoConnectLaunchDecision -State $script:LoginAutoConnect -Settings $script:UserSettings -Overview $script:Overview -Busy $busy -NetworkReady $network -UserDisconnect $script:UserDisconnectIntent -ElapsedSeconds $script:LoginAutoConnect.Watch.Elapsed.TotalSeconds)){return}
 if(-not (Get-TCWorkerActionContract AutoConnectPreview).Known -or -not (Get-TCWorkerActionContract AutoConnectCommit).Known){
  $script:LoginAutoConnect.Status='Skipped';$script:LoginAutoConnect.Reason='此安装包尚未接入自动连接执行器';return
 }
 StartJob @{Action='AutoConnectPreview';StartupLaunch=$true;SelfTest=$false;ReadOnlyLaunch=$false} {param($preview)
  if($script:LoginAutoConnect.Status -cne 'Previewing' -or $script:UserDisconnectIntent -or $script:ReadOnly -or $script:Smoke){return}
  if(-not $preview.Ready){$script:LoginAutoConnect.Status='Done';Toast '本次自动连接未通过核对，请手动处理';return}
  $script:LoginAutoConnect.Status='Committing'
  StartJob @{Action='AutoConnectCommit';StartupLaunch=$true;SelfTest=$false;ReadOnlyLaunch=$false;RecordSHA256=$preview.RecordSHA256;PreviewToken=$preview.PreviewToken} {param($result)
   $script:LoginAutoConnect.Status='Done';$script:Pending=$null
   Toast $(if($result.Status -eq 'Completed'){'已连接上次成功线路'}else{'本次自动连接未完成，请查看连接状态；不会自动重试'})
   RefreshOverview -Silent
  } '正在连接上次成功线路…' 'Connecting' -Failed {param($message)
   $script:LoginAutoConnect.Status='Done';$script:Pending=$null;$script:LoginAutoConnect.Reason=[string]$message
   Toast '本次自动连接已停止，请查看连接状态；不会自动重试';RefreshOverview -Silent
  } -Finalized {if($script:LoginAutoConnect.Status -eq 'Committing'){$script:LoginAutoConnect.Status='Done'}}
 } '正在核对上次成功线路…' -Silent -Failed {param($message)
  $script:LoginAutoConnect.Status='Done';$script:LoginAutoConnect.Reason=[string]$message
  Toast '本次自动连接已停止，请手动查看原线路'
 } -Finalized {if($script:LoginAutoConnect.Status -eq 'Previewing'){$script:LoginAutoConnect.Status='Done'}}
}
function Render {switch($script:Page){'home'{ShowHome}'nodes'{ShowNodes}'automatic-tcp'{ShowAutomaticTransport}'line-recovery'{ShowConnectionRecoveryPage}'line-profiles'{ShowLineConnections}'settings'{ShowSettings}'runtime'{ShowRuntimeReport}'rollback'{ShowConfigurationRollbackResult}'installation'{ShowInstallationInformation}'setup'{switch($script:Role){'deployment'{ShowProductDeployment}'deployment-center'{ShowSetupCenter}'operation-history'{ShowUnifiedOperationHistory}'operation-record'{ShowOperationRecordDetail $script:DeployUI.RecordDetailId -RenderOnly}'servers'{ShowServerManagement}'product-pair'{ShowProductPairing}'product-recovery'{ShowManagementRecovery}'migration'{ShowMigration}'purchase'{ShowPurchasePreparation}default{ShowSetup}}}default{}};UpdateChrome}
function RefreshOverview {param([switch]$Silent)
 StartJob @{Action='Overview'} {param($data)
   ObserveTrayState $data
   $script:Overview=$data;$script:Pending=$null;$script:LastPoll=Get-Date
  if($data.DesiredMode){$script:Prefs.Mode=$data.DesiredMode};if($data.DesiredExit){$script:Prefs.Exit=$data.DesiredExit};if($data.DesiredDaily){$script:Prefs.Daily=$data.DesiredDaily};$script:Prefs.NodeId=$data.NodeId
  foreach($key in @('ProviderId','TradeProviderId')){if($data.PSObject.Properties[$key]){$script:Prefs[$key]=$data.$key}}
   UpdateReadPresentation
  $script:Footer.Text='状态更新于 '+(Get-Date -Format 'HH:mm:ss')
  if($script:ReadOnly -and $TestOutputDirectory){SaveLiveSnapshot}
  # Provider discovery parses the full client profile (seconds of CPU). Only
  # pages that show it refresh it in the background; actions refresh at once.
  elseif($script:Window.IsVisible -and $script:Page -in @('home','nodes') -and ((Get-Date)-$script:ProvidersAt).TotalSeconds -gt 120 -and -not $script:QueuedJob){FetchProviders -Silent}
 } '正在读取真实连接状态…' '' -Silent:$Silent
}
function SaveLiveSnapshot {
 $out=[IO.Path]::GetFullPath($TestOutputDirectory);$null=[IO.Directory]::CreateDirectory($out)
 $script:Footer.Text='实际状态 · 只读检查，未更改网络';$script:Window.FindName('FooterContext').Text=$script:Version+' / READ ONLY'
 $script:Window.UpdateLayout();$null=$script:Window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Render)
 $content=$script:Window.Content;$bitmap=New-Object Windows.Media.Imaging.RenderTargetBitmap([int]$content.ActualWidth,[int]$content.ActualHeight,96,96,[Windows.Media.PixelFormats]::Pbgra32);$bitmap.Render($content)
 $encoder=New-Object Windows.Media.Imaging.PngBitmapEncoder;$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap));$stream=[IO.File]::Open((Join-Path $out 'live-console.png'),[IO.FileMode]::Create);try{$encoder.Save($stream)}finally{$stream.Dispose()}
 $o=$script:Overview;$safe=[ordered]@{StateKey=$o.StateKey;Mode=$o.Mode;Exit=$o.Exit;Daily=$o.Daily;DesiredDaily=$o.DesiredDaily;PolicyVersion=$o.PolicyVersion;GuardState=$o.GuardState;NinjaRunning=$o.NinjaRunning;ObservedAt=$o.ObservedAt;RealNetworkChanged=$false}
 [IO.File]::WriteAllText((Join-Path $out 'live-state.json'),($safe|ConvertTo-Json),(New-Object Text.UTF8Encoding($true)))
 $script:Closing=$true;$script:Window.Close()
}
function FetchNodes {StartJob @{Action='Nodes'} {param($data)$script:Nodes=@($data|Where-Object {$_});UpdateReadPresentation -DataChanged;FetchProviders -Silent} '正在读取线路…' '' -Silent}

# ---------- Providers: discovery and registration never activate a policy ----------
function ProviderEntry {param([string]$Id='')
 if(-not $Id){$Id=[string]$script:Prefs.ProviderId;if(-not $Id -and $script:Providers){$Id=[string]$script:Providers.SelectedProviderId}}
 if(-not $Id -or -not $script:Providers){return $null}
 @($script:Providers.Items|Where-Object {$_ -and $_.Id -eq $Id})|Select-Object -First 1
}
function ProviderName {param([string]$Id='');$p=ProviderEntry $Id;if($p -and $p.Name){return [string]$p.Name};return '当前代理软件'}
function ManifestProviderForTag {param([string]$Tag)
 if(-not $Tag){return $null}
 @($script:Overview.Providers|Where-Object {$_ -and ($_.Tag -eq $Tag -or $_.TradeTag -eq $Tag)})|Select-Object -First 1
}
function IsProviderTag {param([string]$Tag);return ([bool](ManifestProviderForTag $Tag) -or $Tag -match '^provider\d*(-trade)?$')}
function ActiveDailyProviderName {
 $actual=ManifestProviderForTag ([string]$script:Overview.Daily);if($actual -and $actual.Name){return [string]$actual.Name}
 if($script:Overview.DailyProviderName){return [string]$script:Overview.DailyProviderName}
 if($script:Providers.ActiveProviderName){return [string]$script:Providers.ActiveProviderName}
 return ProviderName
}
function ProviderApplied {param($Entry);return ($Entry -and $Entry.Registered -eq $true -and $Entry.Applied -eq $true)}
function ProviderSupportsTrading {param($Entry);return ($Entry -and $Entry.Kind -in @('batvpn','clashverge','clash-verge','Clash'))}
function ExplainDailyOnlyProvider {OpenDialog '自定义 SOCKS 当前仅供日常上网' '当前无法自动验证这类客户端的外部交易路由，填写端口并不代表已具备交易备用能力。' '交易备用建议 Clash Verge/BatVPN；检查通过后仍需确认切换。当前交易出口保持。' '知道了' $null ''}
function ProviderHealthOk {param($Report)
 if($null -eq $Report){return $false}
 if($Report -is [bool]){return $Report}
 if($Report.PSObject.Properties['Healthy']){return ($Report.Healthy -is [bool] -and $Report.Healthy)}
 if($Report.PSObject.Properties['Health']){return ProviderHealthOk $Report.Health}
 return $false
}
function ProviderDailyReady {param($Entry)
 if(-not (ProviderApplied $Entry)){return $false}
 # Discovery is refreshed periodically; a historical check must not keep a
 # reconnected client disabled, or keep an exited client falsely ready.
 return (ProviderHealthOk $Entry.Health)
}
function ProviderHealthText {param($Report)
 if($null -eq $Report){return '尚未检查'}
 if($Report.Friendly){return [string]$Report.Friendly}
 if($Report.ReasonText){return [string]$Report.ReasonText}
 if($Report.Health){return ProviderHealthText $Report.Health}
 if(ProviderHealthOk $Report){return '本机代理端口就绪'}
 if($Report -is [string]){return [string]$Report}
 return '未确认代理可用，请检查客户端连接与端口'
}
function ProviderCheckPassed {param($Data,[bool]$ForTrade=$false)
 if($null -eq $Data -or $Data.Applied -isnot [bool] -or -not $Data.Applied){return $false}
 if($ForTrade){return ($Data.ForTrade -is [bool] -and $Data.ForTrade -and (ProviderHealthOk $Data.TradeHealth) -and $Data.TradePolicy.Allowed -is [bool] -and $Data.TradePolicy.Allowed -and $Data.TradeForwarding -is [bool] -and $Data.TradeForwarding -and $Data.TradeReadyBeforeSwitch -is [bool] -and $Data.TradeReadyBeforeSwitch)}
 return ((ProviderHealthOk $Data.Health) -and $Data.DailyForwarding -is [bool] -and $Data.DailyForwarding)
}
function ProviderInUse {param([string]$Id)
 if(-not (IsRunning)){return $false}
 foreach($tag in @($script:Overview.Exit,$script:Overview.Daily)){$actual=ManifestProviderForTag ([string]$tag);if($actual -and $actual.Id -eq $Id){return $true}}
 return $false
}
function ReadProviders {param($Data)
 $script:Providers=$Data;$script:ProvidersAt=Get-Date;$script:ProviderReadError=$null
 if($Data.PSObject.Properties['SelectedProviderId']){$script:Prefs.ProviderId=[string]$Data.SelectedProviderId}
}
function FetchProviders {param([switch]$Silent)
 StartJob @{Action='Providers'} {param($d)
   ReadProviders $d;UpdateReadPresentation -DataChanged
  if($script:Page -eq 'nodes' -and -not $script:QueuedJob -and ((Get-Date)-$script:AgentPresenceAt).TotalSeconds -gt 60){FetchAgents}
  } '正在发现本机代理软件…' '' -Silent:$Silent -Failed {param($message)$script:ProviderReadError=[string]$message;$script:ProvidersAt=Get-Date;UpdateReadPresentation}
}
function SelectProvider {param([string]$Id)
 if((IsBusy) -or $script:ProviderReadError){return}
 if([string]::IsNullOrEmpty($Id)){
  if(-not [string]::IsNullOrEmpty([string]$script:Prefs.ProviderId)){
   if(IsRunning){
    ApplyRunning @{ProviderId='';Daily='Direct'} 'ApplyingDaily' '已取消代理软件，日常上网已改走本地直连'
   }else{
    SavePrefs @{ProviderId='';Daily='Direct'} '已取消代理软件，日常上网使用本地直连'
   }
  }
  return
 }
 $p=ProviderEntry $Id;if(-not $p -or -not $p.Registered -or $Id -eq [string]$script:Prefs.ProviderId){return}
 if((IsRunning) -and (ProviderApplied $p)){
  # ProviderId is daily/default identity; NEVER resubmit Exit or TradeProviderId here.
  ApplyRunning @{ProviderId=$Id} 'ApplyingDaily' ('已选择 '+$p.Name+'；当前交易出口保持');return
 }
 SavePrefs @{ProviderId=$Id} $(if(ProviderApplied $p){'已保存代理软件选择，下次连接时使用'}else{'已选择 '+$p.Name+'；需维护窗口更新配置，当前连接保持'})
}
function ProviderNeedsMaintenance {
 OpenDialog '代理软件已登记，配置待更新' '当前线路来自旧版本，需要更新一次配置才能使用新的代理接入方式。' '当前连接保持。请先退出交易软件，再从设置页主动执行「更新线路配置」。' '知道了' $null ''
}
function CheckProvider {param([string]$Id,[switch]$ForTrade)
 if(IsBusy){return};$p=ProviderEntry $Id;if(-not $p){return}
 if($ForTrade -and -not (ProviderSupportsTrading $p)){ExplainDailyOnlyProvider;return}
 $script:PendingProviderCheck=@{Id=$Id;ForTrade=[bool]$ForTrade;Name=[string]$p.Name;Kind=[string]$p.Kind}
 $request=@{Action='ProviderCheck';Id=$Id};if($ForTrade){$request.ForTrade=$true}
 StartJob $request {param($d)CompleteProviderCheck $d} '正在检查代理软件；当前交易出口保持…' 'CheckingProvider' -Failed {param($message)ProviderCheckFailed $message}
}
function ProviderCheckFailed {param([string]$Message)
 $script:Pending=$null;$script:PendingTrade=$null;$script:PendingProviderCheck=$null;Render
 OpenDialog '检查未通过，交易线路保持' $Message '未发送交易切换请求；当前交易出口和当前线路保持。检查客户端连接后可以重试。' '知道了' $null ''
}
function CompleteProviderCheck {param($Data)
 $check=$script:PendingProviderCheck;$script:PendingProviderCheck=$null;$script:Pending=$null;if(-not $check){return}
 if($Data.Id -and [string]$Data.Id -ne $check.Id){ProviderCheckFailed '检查结果与所选代理软件不一致。';return}
 if($Data){$Data|Add-Member -NotePropertyName UiForTrade -NotePropertyValue ([bool]$check.ForTrade) -Force}
 $script:ProviderReports[$check.Id]=$Data;Render
 if(-not (ProviderCheckPassed $Data ([bool]$check.ForTrade))){
  $reason=ProviderHealthText $Data
  if($check.ForTrade -and $Data.TradePolicy.ReasonText){$reason=[string]$Data.TradePolicy.ReasonText}
  if($check.ForTrade -and (ProviderHealthOk $Data) -and $Data.Applied){$reason='交易备用尚未通过独立端口转发检查。'+$reason}
  ProviderCheckFailed $reason;return
 }
 if(-not $check.ForTrade){OpenDialog ($check.Name+' · 检查通过') (ProviderHealthText $Data) '仅完成代理软件检查。当前交易出口与当前连接保持，未应用新的线路配置。' '知道了' $null '';return}
 if(-not (IsRunning) -or -not (ProviderApplied (ProviderEntry $check.Id))){ProviderCheckFailed '当前连接或代理软件配置已变化，请刷新状态后重试。';return}
 $script:PendingTrade=@{Exit='Provider';TradeProviderId=$check.Id}
 $script:PendingTradeName=$check.Name
 $modeHint=if($check.Kind -eq 'batvpn'){'请先确认 BatVPN 已切到全局模式，白名单模式不能保证所有交易流量经节点。'}else{'请确认客户端的交易端口可以转发全部交易流量。'}
 OpenDialog ('把交易切到 '+$check.Name+' 备用？') ("交易备用端口的本机与网络转发检查已通过。交易软件的现有连接会短暂中断，完成后需重新连接。`n`n"+$modeHint+"`n`n切换完成后，请检查行情是否恢复。") '仅在自建线路故障时使用备用；取消保留当前出口。恢复后可快捷返回当前自建线路。日常代理软件选择与 AI 工具设置保持。' '切换交易备用' {ApplyRunning $script:PendingTrade 'Applying' ('交易已切到 '+$script:PendingTradeName+'，请在交易软件中重新连接')} -SafeDefault
}

# ---------- State presentation ----------
function StateKey {if($script:Pending -in @('Connecting','Disconnecting','Applying')){return $script:Pending};if($script:Overview){if($script:Overview.ReadState -eq 'Unknown'){return 'ReadUnknown'};return [string]$script:Overview.StateKey};return 'Loading'}
function IsRunning {return [bool]($script:Overview -and $script:Overview.Running -and $script:Pending -notin @('Connecting','Disconnecting','Applying'))}
function IsBusy {
 $memoryJobs=Get-Variable UiMemoryJobs -Scope Script -ValueOnly -ErrorAction SilentlyContinue
 return ((StateKey) -in @('Loading','Connecting','Disconnecting','Applying') -or $script:Pending -in @('ApplyingDaily','ApplyingAgents','CheckingProvider') -or ($script:Job -and -not $script:Job.Silent) -or ($memoryJobs -and $memoryJobs.Count -gt 0))
}
function NodeLabel {param([string]$Id);$node=@($script:Nodes|Where-Object {$_.id -eq $Id});if($node.Count){return [string]$node[0].name};if($script:Overview.NodeName){return [string]$script:Overview.NodeName};return '自建线路'}
function ActiveNodeId {$o=$script:Overview;if(IsRunning){$active=[string](ProfileUIField $o 'ActiveLineId' '');if($active){return $active};$m=@($script:Nodes|Where-Object {NodeHasActiveProfile $_});if($m.Count -eq 1){return [string]$m[0].id}};return [string]$script:Prefs.NodeId}
# Lane values shown = what runs now; while disconnected = what the next connection uses.
function TradeLaneValue {if(IsRunning){if((IsProviderTag ([string]$script:Overview.Exit))){return 'Provider'};return 'node:'+(ActiveNodeId)};if($script:Prefs.Exit -eq 'Provider'){return 'Provider'};return 'node:'+$script:Prefs.NodeId}
function DailyLaneValue {if(IsRunning){if($script:Overview.Mode -eq 'global'){return 'Trade'};return [string]$script:Overview.DesiredDaily};if($script:Prefs.Mode -eq 'Global'){return 'Trade'};return [string]$script:Prefs.Daily}
# Global mode already sends every application, assistants included, over the trading line.
function AgentLaneValue {if((DailyLaneValue) -eq 'Trade'){return 'Trade'};if((IsRunning) -and $script:Overview.Agents){return [string]$script:Overview.Agents};return [string]$script:Prefs.Agents}
function TradeLabel {
 if((TradeLaneValue) -eq 'Provider'){
  if(IsRunning){$actual=ManifestProviderForTag ([string]$script:Overview.Exit);if($actual -and $actual.Name){return [string]$actual.Name+' 备用'}}
  if((IsRunning) -and $script:Overview.TradeProviderName){return [string]$script:Overview.TradeProviderName+' 备用'}
  $id=if(IsRunning){[string]$script:Overview.TradeProviderId}else{[string]$script:Prefs.TradeProviderId}
  if($id){$p=ProviderEntry $id;if($p){return [string]$p.Name+' 备用'}}
  return '当前交易代理软件（备用）'
 };return NodeLabel ((TradeLaneValue).Substring(5))
}
function DurationText {param($Since)
 try{$span=(Get-Date)-([DateTimeOffset]$Since).LocalDateTime}catch{return ''}
 if($span.TotalMinutes -lt 1){return '刚刚连接'};if($span.TotalHours -lt 1){return ('已运行 '+[int]$span.TotalMinutes+' 分钟')}
 if($span.TotalDays -lt 1){return ('已运行 '+[int][Math]::Floor($span.TotalHours)+' 小时 '+$span.Minutes+' 分')};return ('已运行 '+[int][Math]::Floor($span.TotalDays)+' 天 '+$span.Hours+' 小时')
}
function Hero {
 $o=$script:Overview;$k=StateKey
 $x=@{Tone='idle';Title='正在读取';Detail='正在核对通道进程与控制接口。';Button='请稍候';Style='Btn';Enabled=$false}
 switch($k){
  'ReadUnknown'{$x.Tone='warn';$x.Title='状态暂不可核验';$x.Detail=$(if($o.Running){'上次显示已连接；本次读取失败，尚未确认最新状态。'}else{'尚未取得连接状态，本次未执行连接变更。'})+' '+[string]$o.ReadWarning;$x.Button='重试读取';$x.Enabled=$true}
  'Unconfigured'{$x.Title='还没有线路';$x.Detail='添加一条线路，之后在这里一键连接。';$x.Button='开始配置';$x.Style='Primary';$x.Enabled=$true;if(@($script:Nodes|Where-Object {$_.manifestPath}).Count){$x.Title='线路已保存';$x.Detail='请先退出交易软件，再连接。';$x.Button='连接'}}
  'Disconnected'{$x.Title='未连接';$x.Detail='先连接，再打开交易软件。断开期间名单中的交易程序无法联网，避免误走本地网络。';$x.Button='连接';$x.Style='Primary';$x.Enabled=$true;if($o.BootRestartDetected){$x.Detail='电脑重启后，上次的连接已经结束。先连接，再打开交易软件。'}}
  'Connected'{$x.Tone='ok';$x.Title='已连接';$daily=switch(DailyLaneValue){'Trade'{'日常也走交易线路'}'Provider'{if((IsProviderTag ([string]$o.Daily))){'日常走 '+(ActiveDailyProviderName)}else{'日常暂时直连'}}default{'日常本地直连'}};$protocol=[string](ProfileUIField $o 'ActiveProfileId' '');$x.Detail=(TradeLabel)+$(if($protocol -in @('Udp','Tcp')){' · '+$protocol.ToUpperInvariant()}else{''})+' · '+$daily;$x.Button='断开';$x.Enabled=$true}
  'Connecting'{$x.Tone='warn';$x.Title='正在连接';$x.Detail='正在连接并检查可用性。';$x.Button='连接中…'}
  'Disconnecting'{$x.Tone='warn';$x.Title='正在断开';$x.Detail='正在停止通道；交易软件的保护会保留。';$x.Button='断开中…'}
  'Applying'{$x.Tone='warn';$x.Title='正在切换';$x.Detail='切换交易线路会中断现有交易连接，完成后请在交易软件中重新连接。';$x.Button='切换中…'}
  'Fault'{$x.Tone='bad';$x.Title='连接状态需要处理';$x.Detail=$(if($o.Error){[string]$o.Error}else{'暂时无法核对通道状态，请查看诊断。'});$x.Button=$(if($o.PrimaryAction -eq 'Disconnect'){'断开'}elseif($o.PrimaryEnabled -and $o.CanConnect){'重新连接'}else{'重新检查'});$x.Enabled=$true}
 }
 if($k -in @('Disconnected','Unconfigured')){
  $node=@($script:Nodes|Where-Object {$_.id -eq $script:Prefs.NodeId})|Select-Object -First 1
  if($node -and (ProfileUIField $node 'Recommendation')){$r=LineRecommendationView $node;$x.Detail=$r.Label+'。'+$r.Basis+'。'+$r.Reason;$x.Button=if($r.CanConnect){$r.Button}else{'重试检查'}}
 }
 return $x
}
function UpdateChrome {
 SetTCChromeDensity -WebActive ([bool]$script:TCWebChromeActive)
 $h=Hero;$c=$script:Tone[$h.Tone]
 $script:Window.FindName('ChipDot').Fill=B $c.Dot;$script:Window.FindName('StatusChip').Background=B $c.Bg
 $chip=switch(StateKey){'Connected'{'已连接 · '+(TradeLabel)}'Disconnected'{'未连接'}'Unconfigured'{'还没有线路'}'Fault'{'需要处理'}'Loading'{'正在核对'}default{$h.Title}}
 $script:Window.FindName('ChipText').Text=$chip;$script:Window.FindName('ChipText').Foreground=B $(if($h.Tone -eq 'idle'){$script:Text2}else{$c.Fg})
 UpdateTrayPresentation
}
function HomeSignature {
 $o=$script:Overview;if(-not $o){return 'none'}
 # A read failure and recovery must update the existing view even when the
 # last successful connection snapshot itself has not changed.
 @($o.ReadState,$o.ReadWarning,$o.StateKey,$o.Mode,$o.Exit,$o.Daily,$o.DesiredDaily,$o.DailyReason,$o.Agents,$o.DesiredAgents,$o.AgentsSupported,(@($o.AgentNames) -join ','),$o.ManifestPath,$o.GuardState,$o.UpgradeAvailable,$o.ForeignTunnel,$o.LastProxyAt,[string]$o.Provider.Reason,[string]$o.Provider.Healthy,$o.BootRestartDetected,$o.ProviderId,$o.TradeProviderId,$o.TradeProviderName,$o.DailyProviderName,$script:Prefs.ProviderId,$script:Providers.RequiresUpgrade,$script:Pending,(ProfileUIField $o 'ActiveLineId'),(ProfileUIField $o 'ActiveProfileId'),((ProfileUIField $o 'RuntimeValidation')|ConvertTo-Json -Compress -Depth 4),(CurrentExitCheck).Status,(Get-TCExitCheckContext $o).Key) -join '|'
}
function UpdateOverviewMetrics {
 if((StateKey) -eq 'Connected' -and $script:Controls.ContainsKey('StatusMeta')){
  $o=$script:Overview;$meta=@((DurationText $o.ConnectedSince),([string]$o.Connections+' 个连接'),$(if($o.GuardState -eq 'Protected'){'交易保护已核验'}elseif($o.GuardState -eq 'Unprotected'){'交易保护不完整，请查看诊断'}else{'保护状态待确认'}))|Where-Object {$_}
  $script:Controls.StatusMeta.Text=$meta -join '  ·  '
  $script:Controls.StatusMeta.Foreground=B $(if($o.GuardState -eq 'Unprotected'){'#F87171'}elseif($o.GuardState -ne 'Protected'){'#F5A524'}else{'#8590AE'})
 }
}

# ---------- Actions ----------
# The assistant list is sent only once the saved one has been read: an empty
# list from an unloaded console must never overwrite the user's list.
function AddAgentFields {param([hashtable]$Request)
 if($null -ne $script:Prefs.AgentIds){$Request.Agents=$script:Prefs.Agents;$Request.AgentIds=@($script:Prefs.AgentIds);$Request.AgentCustom=@($script:Prefs.AgentCustom)}
}
function ReadAgentPrefs {param($Data)
 if($Data.PSObject.Properties['ProfileId']){$script:Prefs.ProfileId=[string]$Data.ProfileId}
 if($Data.PSObject.Properties['Agents'] -and $Data.Agents){$script:Prefs.Agents=[string]$Data.Agents}
 if($Data.PSObject.Properties['AgentIds'] -and $null -ne $Data.AgentIds){$script:Prefs.AgentIds=@($Data.AgentIds|ForEach-Object {[string]$_})}
 if($Data.PSObject.Properties['AgentCustom'] -and $null -ne $Data.AgentCustom){$script:Prefs.AgentCustom=@($Data.AgentCustom|Where-Object {$_})}
}
function SessionRequest {param([string]$Action,[hashtable]$Changes=@{})
 $r=@{Action='Session';SessionAction=$Action}
 # An Apply is a patch. Resubmitting a saved Exit/NodeId can move a live trade
 # connection; resubmitting the agent lane can move the running assistant.
 if($Action -eq 'Connect'){
  foreach($k in @('Mode','Exit','Daily','NodeId','ProviderId','TradeProviderId','ProfileId')){if($null -ne $script:Prefs[$k]){$r[$k]=$script:Prefs[$k]}};AddAgentFields $r
 }elseif(@($Changes.Keys|Where-Object {$_ -in @('Agents','AgentIds','AgentCustom')}).Count){AddAgentFields $r}
 foreach($k in $Changes.Keys){$r[$k]=$Changes[$k]};return $r
}
function ApplyRunning {param([hashtable]$Changes,[string]$Transition,[string]$Done,[scriptblock]$OnSaved=$null,[scriptblock]$OnNotApplied=$null)
 $script:DoneToast=$Done
 $script:PendingRecoveryNodeId=if($Changes.ContainsKey('NodeId')){[string]$Changes.NodeId}else{[string](ActiveNodeId)}
 StartJob (SessionRequest 'Apply' $Changes) {param($d)
  foreach($k in @('Mode','Exit','Daily')){if($d.("Desired$k")){$script:Prefs[$k]=$d.("Desired$k")}}
  if($d.DesiredAgents){$script:Prefs.Agents=[string]$d.DesiredAgents};if($null -ne $d.AgentIds){$script:Prefs.AgentIds=@($d.AgentIds|ForEach-Object {[string]$_})};if($null -ne $d.AgentCustom){$script:Prefs.AgentCustom=@($d.AgentCustom|Where-Object {$_})}
  foreach($key in @('ProviderId','TradeProviderId')){if($d.PSObject.Properties[$key]){$script:Prefs[$key]=$d.$key}}
  $script:Overview=$d;$script:Pending=$null
  $msg=$script:DoneToast;if($d.DailyApply -and -not $d.DailyApply.Applied -and $d.DailyApply.ReasonText){$msg=((ProviderName)+' 暂不可用：'+$d.DailyApply.ReasonText+'，日常上网暂时直连')}
  Render;Toast $msg;RefreshOverview -Silent
  if($OnSaved -or $OnNotApplied){
   # 内容级回读：判据只能是 Test-TCAgentApplied 的规范化比较。
   # AgentApply.Changed 只表示规则集字节有没有变（Lane=Daily 时恒为 false），
   # AgentApply 缺失只表示「本来已生效、无需下发」，两者都不是成败判据。
   $applied=$true
   try{$applied=[bool](Test-TCAgentApplied (Read-TCAgentState $script:Root) (Get-TCAgentSelection $script:Prefs))}catch{$applied=$true}
   if($applied){if($OnSaved){& $OnSaved}}elseif($OnNotApplied){& $OnNotApplied}
  }
 } '正在应用…' $Transition -Failed {param($message)
  OfferConnectionRecovery $message $script:PendingRecoveryNodeId
  # Apply 先落盘再下发：失败时磁盘已是新名单，界面不能停在旧名单。
  if($OnNotApplied){& $OnNotApplied}
 }
}
function SavePrefs {param([hashtable]$Changes,[string]$Done,[scriptblock]$OnSaved=$null,[scriptblock]$OnFailed=$null)
 $script:PrefsBeforeSave=$script:Prefs.Clone()
 foreach($k in $Changes.Keys){$script:Prefs[$k]=$Changes[$k]};$script:DoneToast=$Done
 $r=@{Action='SavePreferences'};foreach($k in $Changes.Keys){$r[$k]=$Changes[$k]}
 if(@($Changes.Keys|Where-Object {$_ -in @('Agents','AgentIds','AgentCustom')}).Count){AddAgentFields $r}
 StartJob $r {param($d)foreach($k in @('Mode','Exit','Daily','NodeId','ProviderId','TradeProviderId','ProfileId')){if($d.PSObject.Properties[$k]){$script:Prefs[$k]=$d.$k}};ReadAgentPrefs $d;Render;Toast $script:DoneToast;if($OnSaved){& $OnSaved}} '正在保存…' -Failed {param($message)$script:Prefs=$script:PrefsBeforeSave;Render;ErrorDialog $message;if($OnFailed){& $OnFailed}}
 if($script:Smoke){Render}
}
function OnSegment {param([string]$Group,[string]$Value)
 if(IsBusy){return}
 switch($Group){'Daily'{OnDaily $Value}'Agents'{OnAgents $Value}default{OnTrade $Value}}
}
# AI assistants: the list moves between lanes at once, like daily traffic. Trading
# connections never move, so no confirmation is needed.
function ChangeAgents {param([hashtable]$Changes,[string]$Done,[scriptblock]$OnSaved=$null,[scriptblock]$OnNotApplied=$null,[scriptblock]$OnFailed=$null)
 if((IsRunning) -and $script:Overview.AgentsSupported){ApplyRunning $Changes 'ApplyingAgents' $Done $OnSaved $OnNotApplied;return}
 $suffix=if(IsRunning){'；升级线路配置后生效'}else{'；下次连接时生效'}
 SavePrefs $Changes ($Done+$suffix) $OnSaved $OnFailed
}
function OnAgents {param([string]$Value)
 if($Value -eq (AgentLaneValue)){return}
 if((IsRunning) -and -not $script:Overview.AgentsSupported){OpenUpgrade;return}
 ChangeAgents @{Agents=$Value} $(if($Value -eq 'Trade'){'AI 工具已改走交易线路'}else{'AI 工具已改为跟随日常上网'})
}

# ---------- AI 工具名单草稿 ----------
# 编辑期只改草稿、不提交：IsBusy 恒为 false，勾多少下都是本地响应，保存才走一次 Apply。
function AgentDraftEffective {
 if(-not $script:AgentDraft){return $null}
 $removed=@($script:AgentDraft.RemovedCustom)
 [pscustomobject]@{
  Ids=@($script:AgentDraft.Ids|Where-Object {$_})
  Custom=@($script:AgentDraft.Custom|Where-Object {$_ -and ($removed -notcontains ([string]$_.Kind+'|'+[string]$_.Value))})
 }
}
function AgentDraftDiff {
 $empty=[pscustomobject]@{Added=@();Removed=@();AddedCustom=@();RemovedCustom=@();Count=0}
 if(-not $script:AgentDraft){return $empty}
 $effective=AgentDraftEffective
 $baseIds=@($script:Prefs.AgentIds|Where-Object {$_});$draftIds=@($effective.Ids)
 $baseKeys=@(@($script:Prefs.AgentCustom)|Where-Object {$_}|ForEach-Object {[string]$_.Kind+'|'+[string]$_.Value})
 $draftKeys=@($effective.Custom|ForEach-Object {[string]$_.Kind+'|'+[string]$_.Value})
 $added=@($draftIds|Where-Object {$baseIds -notcontains $_});$removed=@($baseIds|Where-Object {$draftIds -notcontains $_})
 $addedCustom=@($draftKeys|Where-Object {$baseKeys -notcontains $_});$removedCustom=@($baseKeys|Where-Object {$draftKeys -notcontains $_})
 [pscustomobject]@{Added=$added;Removed=$removed;AddedCustom=$addedCustom;RemovedCustom=$removedCustom;Count=($added.Count+$removed.Count+$addedCustom.Count+$removedCustom.Count)}
}
function AgentDraftBegin {
 if($null -ne $script:AgentDraft){return}
 $script:AgentDraft=@{Ids=@($script:Prefs.AgentIds|Where-Object {$_});Custom=@($script:Prefs.AgentCustom|Where-Object {$_});RemovedCustom=@()}
}
function AgentDraftClear {$script:AgentDraft=$null;$script:AgentSaveState='Idle';$script:AgentPendingPage=''}
function AgentDraftDirty {return [bool]($script:AgentDraft -and ((AgentDraftDiff).Count -gt 0))}
function AgentDraftCount {if(-not $script:AgentDraft){return 0};return (AgentDraftDiff).Count}
function AgentDraftBarText {
 $n=AgentDraftCount
 switch($script:AgentSaveState){
  'Saving'{return '正在应用名单…'}
  'Failed'{return '没有保存成功，改动还在'}
  'NotApplied'{return '已记录，这次没有应用成功'}
  default{return $(if($n -gt 0){'已改 '+$n+' 项，尚未生效'}else{''})}
 }
}
function AgentDraftHintText {
 $n=AgentDraftCount
 if($n -gt 0 -and $script:AgentSaveState -in @('Dirty','Saving','Failed')){return ([string]$n+' 项改动未保存')}
 return $script:AgentHintBase
}
function UpdateAgentDraftUI {param([switch]$SkipSync)
 $bar=$script:Window.FindName('PageActionBar');$controls=$script:Controls
 if(-not $bar -or -not $controls -or -not $controls.Contains('AgentsDraftCount')){return}
 $state=$script:AgentSaveState
 if($state -eq 'Dirty' -and (AgentDraftCount) -le 0){$state='Idle';$script:AgentSaveState='Idle'}
 $bar.Visibility=$(if($state -eq 'Idle'){'Collapsed'}else{'Visible'})
 $controls['AgentsDraftCount'].Text=AgentDraftBarText
 $save=$controls['AgentsSaveButton'];$second=$controls['AgentsDiscardButton'];$busy=((IsBusy) -or $state -eq 'Saving')
 if($save){
  switch($state){'Failed'{$save.Content='重试'}'NotApplied'{$save.Content='重试应用'}default{$save.Content='保存'}}
  $save.IsEnabled=(-not $busy)
 }
 if($second){
  if($state -eq 'NotApplied'){$second.Content='知道了'}else{$second.Content='放弃修改'}
  $second.IsEnabled=(-not $busy)
 }
 $hint=$controls['AgentsSectionHint'];if($hint){$hint.Text=AgentDraftHintText}
 # 只改具名控件文本 → 快照差量 → reconcile 就地打补丁；不触发 Render / 新 Generation。
 if(-not $SkipSync -and (Get-Command SyncTCWebState -ErrorAction SilentlyContinue)){SyncTCWebState -Force}
}
function NavigateAgentPending {
 $target=$script:AgentPendingPage;$script:AgentPendingPage=''
 if(-not $target){return}
 if($target.StartsWith('Nav')){
  switch($target){'NavHome'{ShowHome;RefreshOverview -Silent}'NavNodes'{ShowNodes;FetchNodes}'NavSetup'{$script:Step=0;ShowSetup}'NavSettings'{ShowSettings}}
  return
 }
 if(Get-Command NavigateTCWebPage -ErrorAction SilentlyContinue){NavigateTCWebPage $target}
}
function AgentDraftSaved {
 $script:AgentDraft=$null;$script:AgentSaveState='Idle'
 UpdateAgentDraftUI;NavigateAgentPending
}
function AgentDraftFailed {
 $script:AgentSaveState='Failed'
 UpdateAgentDraftUI
}
function AgentDraftNotApplied {
 # Apply 先落盘再下发：磁盘已经是新名单，界面必须跟着磁盘走，不能说「没有保存」。
 $disk=$null
 try{$disk=Read-TCAgentPreferences $script:Root}catch{}
 if($disk){
  if($disk.PSObject.Properties['AgentIds'] -and $null -ne $disk.AgentIds){$script:Prefs.AgentIds=@($disk.AgentIds|ForEach-Object {[string]$_})}
  if($disk.PSObject.Properties['AgentCustom'] -and $null -ne $disk.AgentCustom){$script:Prefs.AgentCustom=@($disk.AgentCustom|Where-Object {$_})}
  if($disk.PSObject.Properties['Agents'] -and $disk.Agents){$script:Prefs.Agents=[string]$disk.Agents}
 }
 $script:AgentDraft=$null;$script:AgentSaveState='NotApplied'
 Render;UpdateAgentDraftUI
}
function SaveAgentDraft {
 if($script:ReadOnly -or (IsBusy) -or -not $script:AgentDraft){return}
 $diff=AgentDraftDiff
 if($diff.Count -le 0){$script:AgentDraft=$null;$script:AgentSaveState='Idle';Render;return}
 $effective=AgentDraftEffective
 $script:AgentSaveState='Saving';UpdateAgentDraftUI
 $parts=@();$added=$diff.Added.Count+$diff.AddedCustom.Count;$removed=$diff.Removed.Count+$diff.RemovedCustom.Count
 if($added -gt 0){$parts+=('加入 '+$added+' 项')}
 if($removed -gt 0){$parts+=('移除 '+$removed+' 项')}
 $done='名单已保存：'+($parts -join '，')
 ChangeAgents @{AgentIds=@($effective.Ids);AgentCustom=@($effective.Custom)} $done {AgentDraftSaved} {AgentDraftNotApplied} {AgentDraftFailed}
}
function DiscardAgentDraft {
 if($script:ReadOnly -or -not $script:AgentDraft){return}
 $n=AgentDraftCount
 if($n -le 0){AgentDraftClear;Render;return}
 OpenDialog '放弃这些改动？' ('这 '+$n+' 项改动不会生效，名单保持现在这样。') '正在连接的线路和交易软件不受影响。' '放弃修改' {AgentDraftClear;Render} '留在此页' -ConfirmStyle Danger
}
function AgentDraftSecondary {
 # 已记录未应用：撤销需要一次反向 Apply，属于新事务，所以只给「知道了」。
 if($script:AgentSaveState -eq 'NotApplied'){AgentDraftClear;Render;return}
 DiscardAgentDraft
}
function SaveAgentDraftAndGo {param([string]$Page)
 if(-not (AgentDraftDirty)){if(Get-Command NavigateTCWebPage -ErrorAction SilentlyContinue){NavigateTCWebPage $Page};return}
 $script:AgentPendingPage=$Page
 SaveAgentDraft
}
function OnAgentToggle {param([string]$Id,[bool]$On)
 if($script:ReadOnly){return}
 if($null -eq $script:Prefs.AgentIds -or (IsBusy)){Render;return}
 $entry=@(Get-TCAgentCatalog|Where-Object {$_.Id -eq $Id});if(-not $entry.Count){return}
 AgentDraftBegin
 $ids=@(@($script:AgentDraft.Ids)|Where-Object {$_ -ne $Id});if($On){$ids+=$Id}
 $script:AgentDraft.Ids=@($ids)
 $script:AgentSaveState='Dirty'
 UpdateAgentDraftUI
}
function AddAgentCustom {param([string]$Kind,[string]$Value)
 if($script:ReadOnly){return}
 if((IsBusy) -or $null -eq $script:Prefs.AgentIds){return}
 try{$clean=if($Kind -eq 'Site'){ConvertTo-TCAgentSite $Value}else{ConvertTo-TCAgentProgram $Value}}catch{ErrorDialog $_.Exception.Message;return}
 $label=if($Kind -eq 'Site'){$clean}else{[IO.Path]::GetFileName($clean)}
 AgentDraftBegin
 $effective=AgentDraftEffective
 if(@($effective.Custom|Where-Object {$_.Kind -eq $Kind -and ([string]$_.Value).Equals($clean,[StringComparison]::OrdinalIgnoreCase)}).Count){Toast ('名单里已有：'+$label);return}
 if(@($effective.Custom).Count -ge $script:TCAgentCustomLimit){ErrorDialog ('自定义项最多 '+$script:TCAgentCustomLimit+' 个。');return}
 $script:AgentDraft.Custom=@(@($script:AgentDraft.Custom)+@([pscustomobject]@{Kind=$Kind;Value=$clean}))
 $script:AgentSaveState='Dirty'
 Render;UpdateAgentDraftUI;Toast ('已加入待保存的名单：'+$label)
}
function RemoveAgentCustom {param([string]$Key)
 if($script:ReadOnly){return}
 if((IsBusy) -or $null -eq $script:Prefs.AgentIds){return}
 AgentDraftBegin
 if(@($script:AgentDraft.RemovedCustom) -notcontains $Key){$script:AgentDraft.RemovedCustom=@(@($script:AgentDraft.RemovedCustom)+$Key)}
 $script:AgentSaveState='Dirty'
 Render;UpdateAgentDraftUI
}
function RestoreAgentCustom {param([string]$Key)
 if($script:ReadOnly){return}
 if($null -eq $script:Prefs.AgentIds){return}
 AgentDraftBegin
 $script:AgentDraft.RemovedCustom=@(@($script:AgentDraft.RemovedCustom)|Where-Object {$_ -ne $Key})
 $script:AgentSaveState='Dirty'
 Render;UpdateAgentDraftUI
}
function FetchAgents {StartJob @{Action='Agents'} {param($d)$script:AgentPresence=@{};foreach($e in @($d.Entries)){$script:AgentPresence[[string]$e.Id]=[string]$e.Presence};$script:AgentPresenceAt=Get-Date;UpdateReadPresentation} '正在读取 AI 工具…' '' -Silent}
function OnDaily {param([string]$Value)
 if($Value -eq (DailyLaneValue)){return}
 if($Value -eq 'Provider' -and -not (ProviderApplied (ProviderEntry))){ProviderNeedsMaintenance;return}
 if($Value -eq 'Provider' -and (IsRunning) -and -not (ProviderDailyReady (ProviderEntry))){
  OpenDialog '代理软件当前未就绪' ((ProviderName)+' 的本机代理端口未通过检查。请启动并连接该客户端，保持 TUN 关闭，再到「线路」页重新发现或检查。') '本次没有改变当前交易线路，日常上网保持原出口。「已应用」仅表示端口已写入配置。' '知道了' $null ''
  return
 }
 $label=switch($Value){'Trade'{'走交易线路'}'Provider'{'走 '+(ProviderName)}default{'走本地网络'}}
 if(-not (IsRunning)){
  $changes=if($Value -eq 'Trade'){@{Mode='Global'}}else{@{Mode='Trading';Daily=$Value}};if($Value -eq 'Provider'){$changes.ProviderId=[string]$script:Prefs.ProviderId}
  SavePrefs $changes ('已保存：下次连接时日常上网'+$label);return
 }
 if($Value -eq 'Trade' -and $script:Overview.Exit -eq 'hk'){
  # Global mode shares the Hong Kong server bandwidth with trading; say so once.
  OpenDialog '日常上网也走交易线路？' '其他应用和网站会经当前交易线路转发，与交易软件共用线路带宽。看视频、下载时可能影响行情和订单。' '日常上网无需这条线路时，可以选择「本地直连」或已接入的代理软件。' '仍然切换' {ApplyRunning @{Mode='Global'} 'ApplyingDaily' '日常上网已改走交易线路'}
  return
 }
 $changes=if($Value -eq 'Trade'){@{Mode='Global'}}else{@{Mode='Trading';Daily=$Value}};if($Value -eq 'Provider'){$changes.ProviderId=[string]$script:Prefs.ProviderId}
 ApplyRunning $changes 'ApplyingDaily' ('日常上网已改为'+$label)
}
function OnTrade {param([string]$Value)
 if(IsBusy){return}
 if($Value -eq (TradeLaneValue) -and ($Value -ne 'Provider' -or [string]$script:Prefs.ProviderId -eq [string]$script:Overview.TradeProviderId)){return}
 $isProvider=($Value -eq 'Provider');$nodeId=if($isProvider){$script:Prefs.NodeId}else{$Value.Substring(5)}
 $target=if($isProvider){ProviderName}else{NodeLabel $nodeId}
 $changes=@{Exit=$(if($isProvider){'Provider'}else{'HongKong'})};if($nodeId -ne (ActiveNodeId)){$changes.NodeId=$nodeId}
 if($isProvider){if((ProviderEntry) -and -not (ProviderSupportsTrading (ProviderEntry))){ExplainDailyOnlyProvider;return};if(-not (ProviderApplied (ProviderEntry))){ProviderNeedsMaintenance;return};$changes.TradeProviderId=[string]$script:Prefs.ProviderId}
 if(-not (IsRunning)){SavePrefs $changes ('已保存：下次连接时交易经'+$target);return}
 if($isProvider){
  CheckProvider ([string]$script:Prefs.ProviderId) -ForTrade;return
 }
 $sameNode=($nodeId -eq (ActiveNodeId))
 if(-not $sameNode){PreviewDefaultLineConnection $nodeId;return}
 $body=if($sameNode){"交易将切回 $target。现有交易连接会短暂中断，完成后需重新连接。"}else{"将启用线路「$target」。通道会重新启动（约 10 秒），所有连接都会中断。`n`n请先退出交易软件，再继续。"}
 $script:PendingTrade=$changes
 $script:PendingTradeName=$target
 OpenDialog ('把交易切到 '+$target+'？') $body '只切换线路，不会下单或改动订单。切换后请核对交易软件的账户与持仓。' '切换交易线路' {ApplyRunning $script:PendingTrade 'Applying' ('交易已切到 '+$script:PendingTradeName+'，请在交易软件中重新连接')} -SafeDefault
}
# Compatibility name: HongKong/hk is the engine's historical self-hosted enum,
# independent of the current server's country. Never choose another NodeId.
function CanReturnHongKong {return ((IsRunning) -and [bool]$script:Overview.ManifestPath)}
function QuickHongKong {if((IsBusy) -or -not (CanReturnHongKong)){return};OnTrade ('node:'+(ActiveNodeId))}
function QuickTradingOnly {
 if((IsBusy) -or -not (IsRunning)){return}
 ApplyRunning @{Mode='Trading';Daily='Direct'} 'ApplyingDaily' '已设为仅交易：日常直连，交易出口与 AI 工具设置保持'
}
function StartSession {param([string]$Action);if($Action -eq 'Connect'){ConnectDefaultSelection;return};$script:PendingRecoveryNodeId=[string]$script:Prefs.NodeId;$transition=switch($Action){'Disconnect'{'Disconnecting'}default{'Applying'}};StartJob (SessionRequest $Action) {param($d)$script:Overview=$d;$script:Pending=$null;Render;if($d.PSObject.Properties['PreferenceFallback'] -and $d.PreferenceFallback){Toast ([string]$d.PreferenceFallback)};RefreshOverview -Silent} '正在处理连接操作…' $transition -Failed {param($message)OfferConnectionRecovery $message $script:PendingRecoveryNodeId}}
function ConnectDefaultSelection {
 if(IsBusy){return}
 $id=[string]$script:Prefs.NodeId
 if(-not $id){$ready=@($script:Nodes|Where-Object {$_.manifestPath});if($ready.Count -eq 1){$id=[string]$ready[0].id}else{ShowNodes;return}}
 $node=@($script:Nodes|Where-Object {$_.id -eq $id})|Select-Object -First 1
 PreviewDefaultLineConnection $id
}

# ---------- Node Management Handlers (0.9.0) ----------
function NodeEntry {param([string]$Id) return @($script:Nodes|Where-Object {$_.id -eq $Id})[0]}

function DiagnoseNode {param([string]$Id)
 if(IsBusy){return}
 if([string]::IsNullOrWhiteSpace($Id)){ErrorDialog '未获取到有效的线路 ID。';return}
 if($Id -like 'node:*'){$Id=$Id.Substring(5)}
 $n=NodeEntry $Id;$name=if($n){$n.name}else{'线路'}
 StartJob @{Action='DiagnoseNode';Id=$Id} {param($d)
  $name=[string]$d.Name
  $msg="线路名称：$name`n服务器地址：$($d.Endpoint)`n`n连通状态：$($d.Summary)`n"
  if($null -ne $d.LatencyMs){$msg+="TCP 建连耗时：$($d.LatencyMs) ms`n"}
  foreach($check in @($d.Checks)){$msg+="$($check.Label)：$($check.Message)`n"}
  $msg+="`n提示：本测试探测服务器 SSH/Web 端口与网络路由；实际交易数据流需在连接后经通道测试。"
  $script:Footer.Text="线路「$name」诊断完成 · "+(Get-Date -Format 'HH:mm:ss')
  OpenDialog ("线路诊断：$name") $msg '' '确定' $null ''
 } ("正在诊断线路 $name...")
}

$script:PendingDeleteNodeId=$null;$script:PendingDeleteNodeName=$null
function OpenDeleteNode {param([string]$Id)
 if(IsBusy){return}
 if([string]::IsNullOrWhiteSpace($Id)){ErrorDialog '未获取到有效的线路 ID。';return}
 if($Id -like 'node:*'){$Id=$Id.Substring(5)}
 DeleteOperationRecordsUI -Ids @('Line:'+$Id);return

}

$script:PendingToggleNodeId=$null;$script:PendingToggleTargetMode=$null
function OpenToggleTransport {param([string]$Id,[string]$TargetMode)
 if(IsBusy){return}
 if([string]::IsNullOrWhiteSpace($Id)){ErrorDialog '未获取到有效的线路 ID。';return}
 if($Id -like 'node:*'){$Id=$Id.Substring(5)}
 if($TargetMode -eq 'Tcp'){OpenAutomaticTransport $Id;return}
 $n=NodeEntry $Id;$name=if($n){$n.name}else{'线路'}
 $script:PendingToggleNodeId=$Id;$script:PendingToggleTargetMode=$TargetMode
 $modeName=if($TargetMode -eq 'Tcp'){'TCP 备用连接方式'}else{'UDP 连接方式'}
 $desc=if($TargetMode -eq 'Tcp'){"将该线路的 WireGuard 隧道数据包封装进 TCP 443 传输，适用于 CN2 GIA 等 UDP 受阻的国际专线。`n`n切换会自动重构配置并检验语法。"}else{"将该线路恢复为纯 UDP WireGuard 原生直连模式。"}
 OpenDialog ("切换「$name」为 $modeName？") $desc "请先断开正在使用的这条线路。保存后原配置保留，重新连接生效。" "立即切换" {
  $targetId=if($script:PendingToggleNodeId){$script:PendingToggleNodeId}else{$Id}
  $targetMode=if($script:PendingToggleTargetMode){$script:PendingToggleTargetMode}else{$TargetMode}
  if(-not $targetId){ErrorDialog '未能确定要切换的线路 ID。';return}
  StartJob @{Action='SetTransportMode';Id=$targetId;Mode=$targetMode} {param($d)
   FetchNodes
   Toast $d.Message
  } "正在切换传输模式…"
 } "取消"
}

function OpenRenameNode {param([string]$Id)
 if(IsBusy){return}
 if($script:WebReady -and -not $script:WebFailed -and (-not $script:Smoke -or $script:WebFormsFixture)){ShowTCWebRename $Id;return}
 $n=NodeEntry $Id;$oldName=if($n){$n.name}else{''}
 Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction SilentlyContinue
 $newName=[Microsoft.VisualBasic.Interaction]::InputBox("请输入线路的新名称：", "重命名自建线路", $oldName)
 if(-not [string]::IsNullOrWhiteSpace($newName) -and $newName -ne $oldName){
  StartJob @{Action='RenameNode';Id=$Id;Name=$newName} {param($d)FetchNodes;Toast ("线路已重命名为「"+[string]$d.name+"」")} "正在重命名..."
 }
}

function PrimaryAction {
 StopLoginAutoConnectUI
 switch((StateKey)){
  'ReadUnknown'{RefreshOverview;return}
  'Unconfigured'{if(@($script:Nodes|Where-Object {$_.manifestPath}).Count){StartSession 'Connect'}else{BeginProductDeployment 'Auto'}}
  'Disconnected'{StartSession 'Connect'}
  'Connected'{OpenDisconnect}
  'Fault'{if($script:Overview.PrimaryAction -eq 'Disconnect'){OpenDisconnect}elseif($script:Overview.PrimaryEnabled -and $script:Overview.CanConnect){StartSession 'Connect'}else{RefreshOverview}}
 }
}
function OpenDisconnect {
 if($script:ReadOnly){ErrorDialog '当前为只读检查窗口，未执行操作。';return}
 if(IsBusy){return}
 # A silent read can queue the stop before Disconnecting is visible.
 if(@($script:JobQueue|Where-Object {$_.Request.Action -eq 'Session' -and $_.Request.SessionAction -eq 'Disconnect'}).Count){return}
 StopLoginAutoConnectUI
 # Disconnecting always interrupts the trading session, so it always asks once.
 # The cancel button holds the default focus: Enter never stops trading by accident.
 $approve={param($unused) $script:UserDisconnectIntent=$true; StartSession 'Disconnect'}
 OpenDialog '断开连接？' '行情与下单会立刻中断；交易保护仍然生效；有持仓请先在交易软件处理。' '断开后名单中的交易程序仍会被阻止直连。需要重新连接时，请重新选择线路并点击连接。' '断开连接' $approve '继续交易' 'Danger' -SafeDefault
}
function OpenUpgrade {OpenDialog '更新线路配置？' "应用已保存的程序、网站与代理接入设置。`n`n本操作通过检查后重新连接，原配置保留用于回退。配置维护会短暂中断经过通道的交易、AI 工具连接。" '请先退出交易软件。取消后当前连接保持；仅更新界面不会重新加载引擎配置。' '更新并重新连接' {StartJob @{Action='UpgradeActive'} {param($d)$script:Pending=$null;FetchNodes;Toast '线路配置维护已完成，请重新检查连接状态'} '正在更新线路配置…' 'Applying'} -SafeDefault}
function RunCheck {StartJob @{Action='CheckActive'} {param($d)$script:Checks=@{At=(Get-Date -Format 'HH:mm:ss');Data=$d};if($script:Page -eq 'home'){ShowHome};$view=Get-TCExitCheckView $script:Checks $script:Overview;Toast $view.Reason} '正在检查出口…'}
function OpenHelp {$p=Join-Path $PSScriptRoot '快速部署.html';if(Test-Path -LiteralPath $p){Start-Process -FilePath $p}}

$script:Window.FindName('HeaderHelp').Add_Click({OpenHelp})
$script:Window.FindName('WindowMinimize').Add_Click({$script:Window.WindowState='Minimized'})
$script:Window.FindName('WindowMaximize').Add_Click({$script:Window.WindowState=$(if($script:Window.WindowState -eq 'Maximized'){'Normal'}else{'Maximized'})})
$script:Window.FindName('WindowClose').Add_Click({$script:Window.Close()})
# Catalog and input checks for the AI assistant list (no network or process access at load).
. (Join-Path $PSScriptRoot 'runtime\TradeChannel.Agents.ps1')
. (Join-Path $PSScriptRoot 'ui\Branding.ps1')
. (Join-Path $PSScriptRoot 'ui\FlowEvidence.ps1')
. (Join-Path $PSScriptRoot 'ui\Pages.ps1')
. (Join-Path $PSScriptRoot 'ui\SetupPages.ps1')
. (Join-Path $PSScriptRoot 'ui\ProviderConnectionPages.ps1')
. (Join-Path $PSScriptRoot 'ui\LinuxPages.ps1')
. (Join-Path $PSScriptRoot 'ui\NavigationContext.ps1')
. (Join-Path $PSScriptRoot 'ui\TransportPages.ps1')
. (Join-Path $PSScriptRoot 'ui\ManagementPages.ps1')
. (Join-Path $PSScriptRoot 'ui\TradeApplicationPages.ps1')
. (Join-Path $PSScriptRoot 'ui\RuntimePages.ps1')
. (Join-Path $PSScriptRoot 'ui\DeploymentPages.ps1')
. (Join-Path $PSScriptRoot 'ui\DeploymentBackground.ps1')
. (Join-Path $PSScriptRoot 'ui\LineCardState.ps1')
. (Join-Path $PSScriptRoot 'ui\LineCardControls.ps1')
. (Join-Path $PSScriptRoot 'ui\ServerPages.ps1')
. (Join-Path $PSScriptRoot 'ui\PairingPages.ps1')
. (Join-Path $PSScriptRoot 'ui\OnlinePairingPages.ps1')
. (Join-Path $PSScriptRoot 'ui\WindowLifecycle.ps1')
. (Join-Path $PSScriptRoot 'ui\AutomaticTransportPages.ps1')
. (Join-Path $PSScriptRoot 'ui\ConnectionProfilePages.ps1')
. (Join-Path $PSScriptRoot 'ui\OperationHistoryPages.ps1')
. (Join-Path $PSScriptRoot 'ui\DeploymentIdentityPages.ps1')
. (Join-Path $PSScriptRoot 'ui\WebShell.ps1')
. (Join-Path $PSScriptRoot 'ui\WebInvite.ps1')
foreach($name in @('Home','Nodes','Setup','Settings')){$button=$script:Window.FindName('Nav'+$name);$button.Add_Click({
 if($script:Job -and -not $script:Job.Silent){return}
 # 有未保存的名单改动时先拦一次：两条轨道拦在同一个入口，前端不另做「未保存」概念。
 if(Get-Command AgentDraftDirty -ErrorAction SilentlyContinue){
  if(AgentDraftDirty){$script:AgentPendingPage=[string]$this.Name;OpenDialog '名单还有改动没保存' '这些改动还没有生效，离开后需要重新勾选。' '要放弃改动，先点「放弃修改」。' '保存并离开' {SaveAgentDraft} '留在此页' -SafeDefault;return}
 }
 switch([string]$this.Name){'NavHome'{ShowHome;RefreshOverview -Silent}'NavNodes'{ShowNodes;FetchNodes}'NavSetup'{$script:Step=0;ShowSetup}'NavSettings'{ShowSettings;StartJob @{Action='StartupStatus'} {param($d)$script:Prefs.OpenAtLogin=[bool]$d.Enabled;if($script:Page -eq 'settings'){ShowSettings}} '读取启动设置…' '' -Silent}}
})}
$script:Timer=New-Object Windows.Threading.DispatcherTimer;$script:Timer.Interval=[TimeSpan]::FromMilliseconds(250)
$script:WebSyncTick=0
$script:Timer.Add_Tick({
 # 隐藏到托盘或最小化时界面不可见，快照重建与 JSON 序列化纯属浪费。
 # 与下方 RefreshOverview 的可见性分档（8s/45s）同一套口径；门控读实时可见性，
 # 不用锁存标志：Show() 之后第一个 tick 就会重建，无需补偿逻辑。
 # 最小化时 IsVisible 仍为 true，必须一并排除。
 if($script:Window.IsVisible -and $script:Window.WindowState -ne 'Minimized'){
  # 周期兜底刷新降到 2 个 tick（500ms）；状态变化仍由各处的 SyncTCWebState -Force 立即推送。
  # 计数取奇数时刷新，配合隐藏态清零，保证恢复可见后的第一个 tick 就重建。
  $script:WebSyncTick=[int]$script:WebSyncTick+1
  if(($script:WebSyncTick -band 1) -eq 1){SyncTCWebState}
 }
 else{$script:WebSyncTick=0}
 ContinueTCWebConnection
 InvokeLoginAutoConnectTick
 if($script:UiMemoryJobs.Count){PollUiMemoryJobs}
 # 0.22.0 A2: the invitation page owns its own cadence (30 s, then 60 s; stop after
 # two hours, on leaving the page or on hiding the window). It only ever reads.
 if(Get-Command PollTCWebInviteUI -ErrorAction SilentlyContinue){PollTCWebInviteUI}
 if(Get-Command PollDeploymentBackgroundUI -ErrorAction SilentlyContinue){PollDeploymentBackgroundUI}
 if($script:WakeEvent -and $script:WakeEvent.WaitOne(0)){ShowExistingConsole}
 if($script:Job -or $script:UncertainUiJobs.Count){PollBackgroundJob;if($script:Job){return}}
 if(-not $script:Smoke -and $script:Linux.Busy -and $script:Linux.JobId -and ((Get-Date)-$script:Linux.PollAt).TotalSeconds -gt 2){PollLinux;return}
 # 0.22.2: an operation that never reports back is released here, not by the page
 # that started it. It runs before the deployment poll because that poll is skipped
 # entirely when no deployment session exists - which is exactly the case where the
 # invitation page used to stay locked.
 if(-not $script:Smoke -and $script:DeployUI.PendingManagement){$null=ClearStalePendingManagementUI}
 if(-not $script:Smoke -and ($script:DeployUI.SessionRef -or $script:DeployUI.Identity -or (DeploymentLocalCheckPending $script:DeployUI.Run))){PollProductDeployment}
 if(-not $script:Smoke){RefreshExpiredProtocolPresentation}
 UpdateTCLineQuality
 $observationSeconds=if($script:Window.IsVisible){8}else{45}
 if(-not $script:Smoke -and -not $script:Job -and ((Get-Date)-$script:LastPoll).TotalSeconds -gt $observationSeconds){$script:LastPoll=Get-Date;RefreshOverview -Silent}
})
$script:Tray=New-Object Windows.Forms.NotifyIcon;$trayIconPath=Join-Path $PSScriptRoot 'assets\TradeChannel.ico';if(Test-Path -LiteralPath $trayIconPath){$script:AppTrayIcon=New-Object Drawing.Icon($trayIconPath);$script:Tray.Icon=$script:AppTrayIcon}else{$script:Tray.Icon=[Drawing.SystemIcons]::Application};$script:Tray.Text='TradeChannel';$script:Tray.Visible=(-not $SelfTest)
$menu=New-Object Windows.Forms.ContextMenuStrip;$script:TraySummary=New-Object Windows.Forms.ToolStripMenuItem('正在核对状态');$script:TraySummary.Enabled=$false;$null=$menu.Items.Add($script:TraySummary);$null=$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator));$openItem=$menu.Items.Add('打开控制台');$openItem.Add_Click({ShowExistingConsole});$diagnoseItem=$menu.Items.Add('查看运行诊断');$diagnoseItem.Add_Click({ShowExistingConsole;ShowRuntimeReport});$null=$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator));$script:TrayConnectItem=$menu.Items.Add('连接');$script:TrayConnectItem.Add_Click({ShowExistingConsole;if(WebField $script:Overview Running $false){OpenDisconnect}else{$target=if($script:Prefs.NodeId){$script:Prefs.NodeId}elseif($script:Nodes.Count){UILineId $script:Nodes[0]}else{''};if($target){RequestTCLineConnection $target}else{ShowHome}}});$script:TrayLineMenu=New-Object Windows.Forms.ToolStripMenuItem('选择线路');$null=$menu.Items.Add($script:TrayLineMenu);$menu.Add_Opening({UpdateTCTrayLines});$null=$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator));$exitItem=$menu.Items.Add('退出界面（连接保持）');$exitItem.Add_Click({RequestInterfaceExit});$script:Tray.ContextMenuStrip=$menu
$script:Tray.Add_DoubleClick({ShowExistingConsole})
$script:NormalTrayIcon=$script:Tray.Icon
$script:Tray.Add_BalloonTipClicked({if((Get-Command OpenLastDeploymentBackgroundNotificationUI -ErrorAction SilentlyContinue) -and (OpenLastDeploymentBackgroundNotificationUI)){return};$script:Window.Show();$script:Window.WindowState='Normal';$script:Page='home';ShowHome;RefreshOverview -Silent;$null=$script:Window.Activate()})
$script:Window.Add_Closing({param($sender,$e)HandleWindowClosing $e})
$script:Window.Add_Deactivated({SetDeploymentPasswordVisibilityUI $false})
$script:Window.Add_PreviewMouseDown({StopLoginAutoConnectUI})
$script:Window.Add_PreviewKeyDown({StopLoginAutoConnectUI})
$script:Window.Add_KeyDown({param($sender,$e)if($e.Key -eq 'Escape' -and $script:Window.FindName('Overlay').Visibility -eq 'Visible'){CloseDialog;$e.Handled=$true}})
ShowHome;UpdateChrome
if($SelfTest){
 $selfTestPackageRoot=$PSScriptRoot;$selfTestOutputRoot=$TestOutputDirectory
 . (Join-Path $PSScriptRoot 'ui\Test-014UI.ps1')
 $supplementOutput=if($selfTestOutputRoot){Join-Path $selfTestOutputRoot 'ui-0142'}else{''}
 . (Join-Path $selfTestPackageRoot 'ui\Test-0142UI.ps1') -SourceDirectory $selfTestPackageRoot -TestOutputDirectory $supplementOutput
 # Standalone journey harnesses own their fixture scope and window. Execute
 # them as scripts, so their actors cannot replace the main harness state.
 foreach($suite in @('015UI','015PairUI','016UI','016MaintenanceUI')){
  $journeyOutput=if($selfTestOutputRoot){Join-Path $selfTestOutputRoot ('ui-'+$suite.ToLowerInvariant())}else{''}
  & (Join-Path $selfTestPackageRoot ('ui\Test-'+$suite+'.ps1')) -SourceDirectory $selfTestPackageRoot -TestOutputDirectory $journeyOutput
 }
}
else{
 $script:InitialLoadStarted=$false
 $script:Timer.Start();$script:Window.Add_ContentRendered({
  if($script:InitialLoadStarted){return};$script:InitialLoadStarted=$true
  InitializeTCWebShell
  StartJob @{Action='Preferences'} {param($d)
   foreach($k in @('Mode','Exit','Daily','NodeId','ProviderId','TradeProviderId','ProfileId')){if($d.PSObject.Properties[$k]){$script:Prefs[$k]=$d.$k}};ReadAgentPrefs $d;$script:Prefs.OpenAtLogin=[bool]$d.OpenAtLogin
   StartJob @{Action='Nodes'} {param($nodes)
    $script:Nodes=@($nodes|Where-Object {$_})
    StartJob @{Action='Providers'} {param($providers)ReadProviders $providers;RefreshOverview} '正在读取代理软件…' -Failed {param($message)$script:ProviderReadError=[string]$message;$script:ProvidersAt=Get-Date;RefreshOverview}
   } '正在读取线路…'
  } '正在读取连接偏好…'
 })
 # A modal ShowDialog loop ends when Hide() is called. Keep a modeless
 # dispatcher alive while the window is in the tray, and end it only on Closed.
 $script:Window.Add_Closed({$script:Window.Dispatcher.BeginInvokeShutdown([Windows.Threading.DispatcherPriority]::Background)})
 try{$script:Window.Show();Write-TCPerfTrace 'window-shown';[Windows.Threading.Dispatcher]::Run()}
 finally{$script:Timer.Stop();StopUiReadWorker;ReleaseWindowManagementSession;ReleaseBrandResources;if($script:WakeEvent){$script:WakeEvent.Dispose()};if($script:UiMutex){$script:UiMutex.ReleaseMutex();$script:UiMutex.Dispose()}}
}
