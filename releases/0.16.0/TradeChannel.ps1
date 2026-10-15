#requires -Version 5.1
[CmdletBinding()]
param([switch]$SelfTest,[string]$TestOutputDirectory,[switch]$ReadOnlyLaunch)
$ErrorActionPreference='Stop'
# This process uses only Windows PowerShell inbox modules; do not inherit Core
# module autoload paths from a PowerShell 7 launcher. No machine setting changes.
$env:PSModulePath=Join-Path $PSHOME 'Modules'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Windows.Forms,System.Drawing
Import-Module (Join-Path $PSScriptRoot 'Version.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'DeploymentStore.psm1') -DisableNameChecking
$script:Version=Get-TCProductVersion -PackageRoot $PSScriptRoot
$script:PackageRoot=$PSScriptRoot
$script:UserDisconnectIntent=$false
# SelfTest owns a fresh temporary root. It never addresses the installed store.
$script:Root=if($SelfTest){Join-Path ([IO.Path]::GetTempPath()) ('TradeChannel-ui-fixture-'+[Guid]::NewGuid().ToString('N'))}else{Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'TradeChannel'}
$script:Store=Join-Path $script:Root 'Product';$script:JobRoot=Join-Path $script:Store 'jobs'
$script:Smoke=[bool]$SelfTest;$script:ReadOnly=[bool]$ReadOnlyLaunch
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
$script:Window.FindName('FooterContext').Text='TradeChannel '+$script:Version

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
 $v=New-Object Windows.Controls.Viewbox;$v.Width=$Size;$v.Height=$Size;$v.Child=$canvas;return $v
}
function IconTile {param([string]$Name,[int]$Size=38,[string]$Bg='#F2F3F5',[string]$Color=$script:Ink)
 $tile=New-Object Windows.Controls.Border;$tile.Width=$Size;$tile.Height=$Size;$tile.CornerRadius='10';$tile.Background=B $Bg;$tile.VerticalAlignment='Top';$tile.Child=Icon $Name ([int]($Size*0.5)) $Color;return $tile
}
function Dot {param([string]$Tone='idle',[int]$Size=8)
 $c=$script:Tone[$Tone];$g=New-Object Windows.Controls.Grid;$g.Width=$Size*2.2;$g.Height=$Size*2.2;$g.VerticalAlignment='Center'
 $halo=New-Object Windows.Shapes.Ellipse;$halo.Fill=B $c.Bg;AddC $g $halo
 $core=New-Object Windows.Shapes.Ellipse;$core.Width=$Size;$core.Height=$Size;$core.Fill=B $c.Dot;AddC $g $core;return $g
}
function Pill {param([string]$Text,[string]$Tone='idle',[string]$Bg='');$c=if($Tone.StartsWith('#')){@{Fg=$Tone;Bg=$(if($Bg){$Bg}else{'#F2F3F5'})}}elseif($script:Tone.ContainsKey($Tone)){$script:Tone[$Tone]}else{$script:Tone.idle};$b=New-Object Windows.Controls.Border;$b.CornerRadius='10';$b.Background=B $c.Bg;$b.Padding='9,3';$b.HorizontalAlignment='Left';$b.VerticalAlignment='Center';$b.Child=T $Text 11.5 $c.Fg 'SemiBold';return $b}
function Rule {param([string]$Margin='0,16,0,16');$b=New-Object Windows.Controls.Border;$b.Height=1;$b.Background=B '#EEF0F2';$b.Margin=[Windows.Thickness]$Margin;return $b}
function PageHead {param([string]$Title,[string]$Description,[string]$Page)
 $scroll=$script:Window.FindName('Scroll');$state=$script:ScrollRestoreState
 if(Get-Command SyncNavigationContext -ErrorAction SilentlyContinue){SyncNavigationContext -Page $Page -Title $Title}
 $target=if(Get-Command NavigationVariable -ErrorAction SilentlyContinue){NavigationField (NavigationVariable 'NavigationContext') 'TargetId' ''}else{''}
 $viewKey=@($Page,$Title,$script:Role,$script:Step,$script:DeployUI.Screen,$target) -join '|'
 $sameView=($state.ViewKey -ceq $viewKey);$offset=$scroll.VerticalOffset
 $atBottom=($scroll.ScrollableHeight -gt 1 -and [Math]::Abs($offset-$scroll.ScrollableHeight) -lt 2)
 $state.Generation++;$generation=$state.Generation;$state.ViewKey=$viewKey
 $script:HostPanel.Children.Clear();$script:ResponsiveLayouts.Clear();$script:Controls=@{};$script:Page=$Page
 if(-not $sameView){$scroll.ScrollToTop()}
 if($Title){AddC $script:HostPanel (T $Title 24 $script:Ink 'SemiBold')};if($Description){AddC $script:HostPanel (Margin (T $Description 13 $script:Text3) '0,4,0,22')}
 UpdateTabs;UpdateChrome
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
function SectionLabel {param($Parent,[string]$Text,[string]$Hint='');$row=Grid @('*','Auto');$row.Margin='2,26,2,10';Cell $row (T $Text 12 $script:Text3 'SemiBold') 0;if($Hint){$h=T $Hint 12 $script:Text3;$h.HorizontalAlignment='Right';Cell $row $h 1};AddC $Parent $row}
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
 $box.Child=$row;return $box
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
function OpenDialog {param([string]$Title,[string]$Body,[string]$Note,[string]$Confirm='确定',[scriptblock]$Action=$null,[string]$Cancel='取消',[string]$ConfirmStyle='Primary',$Context=$null)
 $script:Window.FindName('DialogTitle').Text=$Title;$script:Window.FindName('DialogBody').Text=$Body;$script:Window.FindName('DialogNote').Text=$Note
 $script:Window.FindName('DialogNoteBox').Visibility=$(if($Note){'Visible'}else{'Collapsed'})
 $confirmButton=$script:Window.FindName('DialogConfirm');$confirmButton.Content=$Confirm;$confirmButton.Style=$script:Window.FindResource($ConfirmStyle)
 $cancelButton=$script:Window.FindName('DialogCancel');$cancelButton.Content=$Cancel;$cancelButton.Visibility=$(if($Cancel){'Visible'}else{'Collapsed'})
 $script:DialogCallback=$Action;$script:DialogContext=$Context;$script:Window.FindName('Overlay').Visibility='Visible'
 # Destructive confirmations start on the safe choice; Enter never disconnects by accident.
 if($ConfirmStyle -eq 'Danger' -and $Cancel){$null=$cancelButton.Focus()}else{$null=$confirmButton.Focus()}
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
 OpenDialog '操作未完成' $Message '这次操作没有被标记为成功。可以修正后重试，或先查看实际状态。' '知道了' $null ''
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
function ChooseFile {param([string]$Title,[string]$Filter,[switch]$Save,[string]$Name='');$d=if($Save){New-Object Microsoft.Win32.SaveFileDialog}else{New-Object Microsoft.Win32.OpenFileDialog};$d.Title=$Title;$d.Filter=$Filter;$d.FileName=$Name;if($d.ShowDialog($script:Window)){return $d.FileName}}
function ChooseFolder {param([string]$Text);$d=New-Object Windows.Forms.FolderBrowserDialog;$d.Description=$Text;try{if($d.ShowDialog() -eq 'OK'){return $d.SelectedPath}}finally{$d.Dispose()}}

# ---------- Background jobs (Worker.ps1, one at a time) ----------
function StartJob {param([hashtable]$Request,[scriptblock]$Complete,[string]$Message='正在处理…',[string]$Transition='',[switch]$Silent,[scriptblock]$Failed=$null)
 if($script:Smoke){$script:Actions.Add([pscustomobject]@{Request=$Request.Clone();Transition=$Transition;Complete=$Complete;Failed=$Failed});$script:AllSelfTestRequests.Add([pscustomobject]@{Request=$Request.Clone();Transition=$Transition});if($Transition){$script:Pending=$Transition;Render};return}
 if($script:Job){
  if(-not $Silent -and $script:Job.Silent -and -not $script:QueuedJob){$script:QueuedJob=@{Request=$Request.Clone();Complete=$Complete;Message=$Message;Transition=$Transition;Failed=$Failed};$script:HostPanel.IsEnabled=$false;$script:Footer.Text='正在完成状态读取，随后执行你的操作…'}
  return
 }
 if($script:ReadOnly -and $Request.Action -notin @('Overview','Nodes','Preferences','Providers','Agents','StartupStatus','InspectClient','InspectServer','ProviderCheck','RuntimeReport','InstallationInfo','DeploymentDiscover','DeploymentGet','DeploymentCenter','OperationHistory','OperationRecordDetail','DraftDisposition','LineProfiles','HistoryClearPreview','ServerList','ConfigurationRollbackPreview')){ErrorDialog '当前为只读检查窗口，未执行操作。';return}
 if(($Request.Action -eq 'Session' -and $Request.SessionAction -eq 'Disconnect') -or $Request.Action -in @('RepairState','RemoveProtection')){$script:UserDisconnectIntent=$true}
 $id=[Guid]::NewGuid().ToString('N');$req=Join-Path $script:JobRoot ($id+'.request.json');$out=Join-Path $script:JobRoot ($id+'.result.json');[IO.File]::WriteAllText($req,($Request|ConvertTo-Json -Depth 10),(New-Object Text.UTF8Encoding($true)))
 $exe=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe';$arguments=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',('"'+(Join-Path $PSScriptRoot 'Worker.ps1')+'"'),'-RequestPath',('"'+$req+'"'),'-ResultPath',('"'+$out+'"'))
 try{$p=Start-Process -FilePath $exe -ArgumentList $arguments -PassThru -WindowStyle Hidden}catch{if($Failed){& $Failed $_.Exception.Message}else{ErrorDialog $_.Exception.Message};return}
 $script:Job=@{Process=$p;Request=$req;Result=$out;Complete=$Complete;Failed=$Failed;Started=Get-Date;Action=$Request.Action;Silent=[bool]$Silent}
 if(-not $Silent){$script:Footer.Text=$Message};if($Transition){$script:Pending=$Transition;Render}elseif(-not $Silent){$script:HostPanel.IsEnabled=$false}
}
function Render {switch($script:Page){'home'{ShowHome}'nodes'{ShowNodes}'automatic-tcp'{ShowAutomaticTransport}'line-recovery'{ShowConnectionRecoveryPage}'line-profiles'{ShowLineConnections}'settings'{ShowSettings}'runtime'{ShowRuntimeReport}'rollback'{ShowConfigurationRollbackResult}'installation'{ShowInstallationInformation}'setup'{switch($script:Role){'deployment'{ShowProductDeployment}'deployment-center'{ShowSetupCenter}'operation-history'{ShowUnifiedOperationHistory}'operation-record'{ShowOperationRecordDetail $script:DeployUI.RecordDetailId -RenderOnly}'servers'{ShowServerManagement}'product-pair'{ShowProductPairing}'product-recovery'{ShowManagementRecovery}'migration'{ShowMigration}'purchase'{ShowPurchasePreparation}default{ShowSetup}}}default{}};UpdateChrome}
function RefreshOverview {param([switch]$Silent)
 StartJob @{Action='Overview'} {param($data)
   ObserveTrayState $data
   $script:Overview=$data;$script:Pending=$null;$script:LastPoll=Get-Date
  if($data.DesiredMode){$script:Prefs.Mode=$data.DesiredMode};if($data.DesiredExit){$script:Prefs.Exit=$data.DesiredExit};if($data.DesiredDaily){$script:Prefs.Daily=$data.DesiredDaily};$script:Prefs.NodeId=$data.NodeId
  foreach($key in @('ProviderId','TradeProviderId')){if($data.PSObject.Properties[$key]){$script:Prefs[$key]=$data.$key}}
  if($script:Page -eq 'home'){$sig=HomeSignature;if($sig -ne $script:HomeSignature){ShowHome}else{UpdateOverviewMetrics}}
  elseif($script:Page -eq 'nodes'){ShowNodes}
  elseif($script:Page -eq 'line-profiles'){ShowLineConnections}
  UpdateChrome
  $script:Footer.Text='状态更新于 '+(Get-Date -Format 'HH:mm:ss')
  if($script:ReadOnly -and $TestOutputDirectory){SaveLiveSnapshot}
  elseif(((Get-Date)-$script:ProvidersAt).TotalSeconds -gt 30 -and -not $script:QueuedJob){FetchProviders -Silent}
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
function FetchNodes {StartJob @{Action='Nodes'} {param($data)$script:Nodes=@($data|Where-Object {$_});if($script:Page -in @('nodes','home')){Render};FetchProviders -Silent} '正在读取线路…' '' -Silent}

# ---------- Providers: discovery and registration never activate a policy ----------
function ProviderEntry {param([string]$Id='')
 if(-not $Id){$Id=[string]$script:Prefs.ProviderId;if(-not $Id -and $script:Providers){$Id=[string]$script:Providers.SelectedProviderId}}
 if(-not $Id -or -not $script:Providers){return $null}
 @($script:Providers.Items|Where-Object {$_ -and $_.Id -eq $Id})|Select-Object -First 1
}
function ProviderName {param([string]$Id='');$p=ProviderEntry $Id;if($p -and $p.Name){return [string]$p.Name};return '当前服务商'}
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
  ReadProviders $d;if($script:Page -in @('home','nodes')){Render}
  if($script:Page -eq 'nodes' -and -not $script:QueuedJob -and ((Get-Date)-$script:AgentPresenceAt).TotalSeconds -gt 60){FetchAgents}
 } '正在发现本机服务商…' '' -Silent:$Silent -Failed {param($message)$script:ProviderReadError=[string]$message;$script:ProvidersAt=Get-Date;if($script:Page -in @('home','nodes')){Render}}
}
function SelectProvider {param([string]$Id)
 if((IsBusy) -or $script:ProviderReadError){return}
 if([string]::IsNullOrEmpty($Id)){
  if(-not [string]::IsNullOrEmpty([string]$script:Prefs.ProviderId)){
   if(IsRunning){
    ApplyRunning @{ProviderId='';Daily='Direct'} 'ApplyingDaily' '已取消服务商，日常上网已改走本地直连'
   }else{
    SavePrefs @{ProviderId='';Daily='Direct'} '已取消服务商，日常上网使用本地直连'
   }
  }
  return
 }
 $p=ProviderEntry $Id;if(-not $p -or -not $p.Registered -or $Id -eq [string]$script:Prefs.ProviderId){return}
 if((IsRunning) -and (ProviderApplied $p)){
  # ProviderId is daily/default identity; NEVER resubmit Exit or TradeProviderId here.
  ApplyRunning @{ProviderId=$Id} 'ApplyingDaily' ('已选择 '+$p.Name+'；当前交易出口保持');return
 }
 SavePrefs @{ProviderId=$Id} $(if(ProviderApplied $p){'已保存服务商选择，下次连接时使用'}else{'已选择 '+$p.Name+'；需维护窗口更新配置，香港连接保持'})
}
function ProviderNeedsMaintenance {
 OpenDialog '服务商已登记，配置待更新' '新增服务商需要在维护窗口更新线路配置至 v4，才能用于日常上网或交易备用。登记与选择只保存资料。' '当前香港连接保持。请先退出 NinjaTrader，再从设置页主动执行「更新线路配置」。' '知道了' $null ''
}
function CheckProvider {param([string]$Id,[switch]$ForTrade)
 if(IsBusy){return};$p=ProviderEntry $Id;if(-not $p){return}
 if($ForTrade -and -not (ProviderSupportsTrading $p)){ExplainDailyOnlyProvider;return}
 $script:PendingProviderCheck=@{Id=$Id;ForTrade=[bool]$ForTrade;Name=[string]$p.Name;Kind=[string]$p.Kind}
 $request=@{Action='ProviderCheck';Id=$Id};if($ForTrade){$request.ForTrade=$true}
 StartJob $request {param($d)CompleteProviderCheck $d} '正在检查服务商；当前交易出口保持…' 'CheckingProvider' -Failed {param($message)ProviderCheckFailed $message}
}
function ProviderCheckFailed {param([string]$Message)
 $script:Pending=$null;$script:PendingTrade=$null;$script:PendingProviderCheck=$null;Render
 OpenDialog '检查未通过，交易线路保持' $Message '未发送交易切换请求；当前交易出口和香港通道保持。检查客户端连接后可以重试。' '知道了' $null ''
}
function CompleteProviderCheck {param($Data)
 $check=$script:PendingProviderCheck;$script:PendingProviderCheck=$null;$script:Pending=$null;if(-not $check){return}
 if($Data.Id -and [string]$Data.Id -ne $check.Id){ProviderCheckFailed '检查结果与所选服务商不一致。';return}
 if($Data){$Data|Add-Member -NotePropertyName UiForTrade -NotePropertyValue ([bool]$check.ForTrade) -Force}
 $script:ProviderReports[$check.Id]=$Data;Render
 if(-not (ProviderCheckPassed $Data ([bool]$check.ForTrade))){
  $reason=ProviderHealthText $Data
  if($check.ForTrade -and $Data.TradePolicy.ReasonText){$reason=[string]$Data.TradePolicy.ReasonText}
  if($check.ForTrade -and (ProviderHealthOk $Data) -and $Data.Applied){$reason='交易备用尚未通过独立端口转发检查。'+$reason}
  ProviderCheckFailed $reason;return
 }
 if(-not $check.ForTrade){OpenDialog ($check.Name+' · 检查通过') (ProviderHealthText $Data) '仅完成服务商检查。当前交易出口与香港连接保持，未应用新的线路配置。' '知道了' $null '';return}
 if(-not (IsRunning) -or -not (ProviderApplied (ProviderEntry $check.Id))){ProviderCheckFailed '当前连接或服务商配置已变化，请刷新状态后重试。';return}
 $script:PendingTrade=@{Exit='Provider';TradeProviderId=$check.Id}
 $script:PendingTradeName=$check.Name
 $modeHint=if($check.Kind -eq 'batvpn'){'请先确认 BatVPN 已切到全局模式，白名单模式不能保证所有交易流量经节点。'}else{'请确认客户端的交易端口可以转发全部交易流量。'}
 OpenDialog ('把交易切到 '+$check.Name+' 备用？') ("交易备用端口的本机与网络转发检查已通过。NinjaTrader、TradingView 和 Tradovate 的现有交易连接可能中断，切换后需要重新连接。`n`n"+$modeHint+"`n`n本轮尚未完整验证交易出口、行情、历史数据和订单，切换后需分别验收。") '仅在自建线路故障时使用备用；取消保留当前出口。恢复后可快捷返回当前自建线路。日常服务商选择与 AI 助手设置保持。' '切换交易备用' {ApplyRunning $script:PendingTrade 'Applying' ('交易已切到 '+$script:PendingTradeName+'，请在交易软件中重新连接')}
}

# ---------- State presentation ----------
function StateKey {if($script:Pending -in @('Connecting','Disconnecting','Applying')){return $script:Pending};if($script:Overview){return [string]$script:Overview.StateKey};return 'Loading'}
function IsRunning {return [bool]($script:Overview -and $script:Overview.Running -and $script:Pending -notin @('Connecting','Disconnecting','Applying'))}
function IsBusy {return ((StateKey) -in @('Loading','Connecting','Disconnecting','Applying') -or $script:Pending -in @('ApplyingDaily','ApplyingAgents','CheckingProvider') -or ($script:Job -and -not $script:Job.Silent))}
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
  return '当前交易服务商（备用）'
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
  'Unconfigured'{$x.Title='还没有交易线路';$x.Detail='先在部署页添加线路，之后在这里一键连接。';$x.Button='开始配置';$x.Style='Primary';$x.Enabled=$true;if(@($script:Nodes|Where-Object {$_.manifestPath}).Count){$x.Title='线路已保存';$x.Detail='请先退出 NinjaTrader，再连接。';$x.Button='连接'}}
  'Disconnected'{$x.Title='未连接';$x.Detail='先连接，再打开 NinjaTrader。断开期间 NinjaTrader 无法联网，避免误走本地网络。';$x.Button='连接';$x.Style='Primary';$x.Enabled=$true;if($o.BootRestartDetected){$x.Detail='电脑重启后，上次的连接已经结束。先连接，再打开 NinjaTrader。'}}
  'Connected'{$x.Tone='ok';$x.Title='通道运行中';$daily=switch(DailyLaneValue){'Trade'{'日常也走交易线路'}'Provider'{if((IsProviderTag ([string]$o.Daily))){'日常走 '+(ActiveDailyProviderName)}else{'日常暂时直连'}}default{'日常本地直连'}};$protocol=[string](ProfileUIField $o 'ActiveProfileId' '');$x.Detail=(TradeLabel)+$(if($protocol -in @('Udp','Tcp')){' · '+$protocol.ToUpperInvariant()}else{''})+' · '+$daily;$x.Button='断开';$x.Enabled=$true}
  'Connecting'{$x.Tone='warn';$x.Title='正在连接';$x.Detail='正在建立通道并核对状态。不会自动打开 NinjaTrader。';$x.Button='连接中…'}
  'Disconnecting'{$x.Tone='warn';$x.Title='正在断开';$x.Detail='正在停止通道；NinjaTrader 的保护会保留。';$x.Button='断开中…'}
  'Applying'{$x.Tone='warn';$x.Title='正在切换';$x.Detail='切换交易线路会中断现有交易连接，完成后请在 NinjaTrader 中重新连接。';$x.Button='切换中…'}
  'Fault'{$x.Tone='bad';$x.Title='连接状态需要处理';$x.Detail=$(if($o.Error){[string]$o.Error}else{'暂时无法核对通道状态，请查看诊断。'});$x.Button=$(if($o.PrimaryAction -eq 'Disconnect'){'断开'}elseif($o.PrimaryEnabled -and $o.CanConnect){'重新连接'}else{'重新检查'});$x.Enabled=$true}
 }
 if($k -in @('Disconnected','Unconfigured')){
  $node=@($script:Nodes|Where-Object {$_.id -eq $script:Prefs.NodeId})|Select-Object -First 1
  if($node -and (ProfileUIField $node 'Recommendation')){$r=LineRecommendationView $node;$x.Detail=$r.Label+'。'+$r.Basis+'。'+$r.Reason;$x.Button=if($r.CanConnect){$r.Button}else{'重试检查'}}
 }
 return $x
}
function UpdateChrome {
 $h=Hero;$c=$script:Tone[$h.Tone]
 $script:Window.FindName('ChipDot').Fill=B $c.Dot;$script:Window.FindName('StatusChip').Background=B $c.Bg
 $chip=switch(StateKey){'Connected'{'通道运行 · '+(TradeLabel)}'Disconnected'{'未连接'}'Unconfigured'{'未配置'}'Fault'{'需要处理'}'Loading'{'正在核对'}default{$h.Title}}
 $script:Window.FindName('ChipText').Text=$chip;$script:Window.FindName('ChipText').Foreground=B $(if($h.Tone -eq 'idle'){$script:Text2}else{$c.Fg})
 UpdateTrayPresentation
}
function HomeSignature {
 $o=$script:Overview;if(-not $o){return 'none'}
 @($o.StateKey,$o.Mode,$o.Exit,$o.Daily,$o.DesiredDaily,$o.DailyReason,$o.Agents,$o.DesiredAgents,$o.AgentsSupported,(@($o.AgentNames) -join ','),$o.ManifestPath,$o.GuardState,$o.UpgradeAvailable,$o.ForeignTunnel,$o.LastProxyAt,[string]$o.Provider.Reason,[string]$o.Provider.Healthy,$o.BootRestartDetected,$o.ProviderId,$o.TradeProviderId,$o.TradeProviderName,$o.DailyProviderName,$script:Prefs.ProviderId,$script:Providers.RequiresUpgrade,$script:Pending,(ProfileUIField $o 'ActiveLineId'),(ProfileUIField $o 'ActiveProfileId'),((ProfileUIField $o 'RuntimeValidation')|ConvertTo-Json -Compress -Depth 4),(CurrentExitCheck).Status,(Get-TCExitCheckContext $o).Key) -join '|'
}
function UpdateOverviewMetrics {
 if((StateKey) -eq 'Connected' -and $script:Controls.ContainsKey('StatusMeta')){
  $o=$script:Overview;$meta=@((DurationText $o.ConnectedSince),([string]$o.Connections+' 个连接'),$(if($o.GuardState -eq 'Protected'){'交易保护已核验'}elseif($o.GuardState -eq 'Unprotected'){'交易保护不完整，请查看诊断'}else{'保护状态待确认'}))|Where-Object {$_}
  $script:Controls.StatusMeta.Text=$meta -join '  ·  '
  $script:Controls.StatusMeta.Foreground=B $(if($o.GuardState -eq 'Unprotected'){$script:Tone.bad.Fg}elseif($o.GuardState -ne 'Protected'){$script:Tone.warn.Fg}else{$script:Text3})
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
function ApplyRunning {param([hashtable]$Changes,[string]$Transition,[string]$Done)
 $script:DoneToast=$Done
 $script:PendingRecoveryNodeId=if($Changes.ContainsKey('NodeId')){[string]$Changes.NodeId}else{[string](ActiveNodeId)}
 StartJob (SessionRequest 'Apply' $Changes) {param($d)
  foreach($k in @('Mode','Exit','Daily')){if($d.("Desired$k")){$script:Prefs[$k]=$d.("Desired$k")}}
  if($d.DesiredAgents){$script:Prefs.Agents=[string]$d.DesiredAgents};if($null -ne $d.AgentIds){$script:Prefs.AgentIds=@($d.AgentIds|ForEach-Object {[string]$_})};if($null -ne $d.AgentCustom){$script:Prefs.AgentCustom=@($d.AgentCustom|Where-Object {$_})}
  foreach($key in @('ProviderId','TradeProviderId')){if($d.PSObject.Properties[$key]){$script:Prefs[$key]=$d.$key}}
  $script:Overview=$d;$script:Pending=$null
  $msg=$script:DoneToast;if($d.DailyApply -and -not $d.DailyApply.Applied -and $d.DailyApply.ReasonText){$msg=((ProviderName)+' 暂不可用：'+$d.DailyApply.ReasonText+'，日常上网暂时直连')}
  Render;Toast $msg;RefreshOverview -Silent
 } '正在应用…' $Transition -Failed {param($message)OfferConnectionRecovery $message $script:PendingRecoveryNodeId}
}
function SavePrefs {param([hashtable]$Changes,[string]$Done)
 $script:PrefsBeforeSave=$script:Prefs.Clone()
 foreach($k in $Changes.Keys){$script:Prefs[$k]=$Changes[$k]};$script:DoneToast=$Done
 $r=@{Action='SavePreferences'};foreach($k in $Changes.Keys){$r[$k]=$Changes[$k]}
 if(@($Changes.Keys|Where-Object {$_ -in @('Agents','AgentIds','AgentCustom')}).Count){AddAgentFields $r}
 StartJob $r {param($d)foreach($k in @('Mode','Exit','Daily','NodeId','ProviderId','TradeProviderId','ProfileId')){if($d.PSObject.Properties[$k]){$script:Prefs[$k]=$d.$k}};ReadAgentPrefs $d;Render;Toast $script:DoneToast} '正在保存…' -Failed {param($message)$script:Prefs=$script:PrefsBeforeSave;Render;ErrorDialog $message}
 if($script:Smoke){Render}
}
function OnSegment {param([string]$Group,[string]$Value)
 if(IsBusy){return}
 switch($Group){'Daily'{OnDaily $Value}'Agents'{OnAgents $Value}default{OnTrade $Value}}
}
# AI assistants: the list moves between lanes at once, like daily traffic. Trading
# connections never move, so no confirmation is needed.
function ChangeAgents {param([hashtable]$Changes,[string]$Done)
 if((IsRunning) -and $script:Overview.AgentsSupported){ApplyRunning $Changes 'ApplyingAgents' $Done;return}
 $suffix=if(IsRunning){'；升级线路配置后生效'}else{'；下次连接时生效'}
 SavePrefs $Changes ($Done+$suffix)
}
function OnAgents {param([string]$Value)
 if($Value -eq (AgentLaneValue)){return}
 if((IsRunning) -and -not $script:Overview.AgentsSupported){OpenUpgrade;return}
 ChangeAgents @{Agents=$Value} $(if($Value -eq 'Trade'){'AI 助手已改走交易线路'}else{'AI 助手已改为跟随日常上网'})
}
function OnAgentToggle {param([string]$Id,[bool]$On)
 if((IsBusy) -or $null -eq $script:Prefs.AgentIds){Render;return}
 $entry=@(Get-TCAgentCatalog|Where-Object {$_.Id -eq $Id});if(-not $entry.Count){return}
 $ids=@(@($script:Prefs.AgentIds)|Where-Object {$_ -ne $Id});if($On){$ids+=$Id}
 ChangeAgents @{AgentIds=@($ids)} $(if($On){'已加入名单：'+$entry[0].Short}else{'已移出名单：'+$entry[0].Short})
}
function AddAgentCustom {param([string]$Kind,[string]$Value)
 if((IsBusy) -or $null -eq $script:Prefs.AgentIds){return}
 try{$clean=if($Kind -eq 'Site'){ConvertTo-TCAgentSite $Value}else{ConvertTo-TCAgentProgram $Value}}catch{ErrorDialog $_.Exception.Message;return}
 $label=if($Kind -eq 'Site'){$clean}else{[IO.Path]::GetFileName($clean)}
 if(@($script:Prefs.AgentCustom|Where-Object {$_.Kind -eq $Kind -and ([string]$_.Value).Equals($clean,[StringComparison]::OrdinalIgnoreCase)}).Count){Toast ('名单里已有：'+$label);return}
 if(@($script:Prefs.AgentCustom).Count -ge $script:TCAgentCustomLimit){ErrorDialog ('自定义项最多 '+$script:TCAgentCustomLimit+' 个。');return}
 ChangeAgents @{AgentCustom=@(@($script:Prefs.AgentCustom)+@([pscustomobject]@{Kind=$Kind;Value=$clean}))} ('已加入名单：'+$label)
}
function RemoveAgentCustom {param([string]$Key)
 if(IsBusy){return}
 $rest=@($script:Prefs.AgentCustom|Where-Object {([string]$_.Kind+'|'+[string]$_.Value) -ne $Key});$value=$Key.Substring($Key.IndexOf('|')+1)
 ChangeAgents @{AgentCustom=$rest} ('已移出名单：'+$(if($Key.StartsWith('Program|')){[IO.Path]::GetFileName($value)}else{$value}))
}
function FetchAgents {StartJob @{Action='Agents'} {param($d)$script:AgentPresence=@{};foreach($e in @($d.Entries)){$script:AgentPresence[[string]$e.Id]=[string]$e.Presence};$script:AgentPresenceAt=Get-Date;if($script:Page -eq 'nodes'){Render}} '正在读取 AI 助手…' '' -Silent}
function OnDaily {param([string]$Value)
 if($Value -eq (DailyLaneValue)){return}
 if($Value -eq 'Provider' -and -not (ProviderApplied (ProviderEntry))){ProviderNeedsMaintenance;return}
 if($Value -eq 'Provider' -and (IsRunning) -and -not (ProviderDailyReady (ProviderEntry))){
  OpenDialog '服务商当前未就绪' ((ProviderName)+' 的本机代理端口未通过检查。请启动并连接该客户端，保持 TUN 关闭，再到「线路」页重新发现或检查。') '本次没有改变香港交易主线，日常上网保持原出口。「已应用」仅表示端口已写入配置。' '知道了' $null ''
  return
 }
 $label=switch($Value){'Trade'{'走交易线路'}'Provider'{'走 '+(ProviderName)}default{'走本地网络'}}
 if(-not (IsRunning)){
  $changes=if($Value -eq 'Trade'){@{Mode='Global'}}else{@{Mode='Trading';Daily=$Value}};if($Value -eq 'Provider'){$changes.ProviderId=[string]$script:Prefs.ProviderId}
  SavePrefs $changes ('已保存：下次连接时日常上网'+$label);return
 }
 if($Value -eq 'Trade' -and $script:Overview.Exit -eq 'hk'){
  # Global mode shares the Hong Kong server bandwidth with trading; say so once.
  OpenDialog '日常上网也走交易线路？' '其他应用和网站会经香港服务器转发，与 NinjaTrader 共用服务器带宽。看视频、下载时可能影响行情和订单。' '保留当前交易出口和 AI 助手设置。日常上网不需要香港出口时，可选「本地直连」或「当前服务商」。' '仍然切换' {ApplyRunning @{Mode='Global'} 'ApplyingDaily' '日常上网已改走交易线路'}
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
 $body=if($sameNode){"交易将切回 $target。NinjaTrader、TradingView 的现有连接会中断，需要重新连接。"}else{"将启用线路「$target」。通道会重新启动（约 10 秒），所有连接都会中断。`n`n请先退出整个 NinjaTrader，再继续。"}
 $script:PendingTrade=$changes
 $script:PendingTradeName=$target
 OpenDialog ('把交易切到 '+$target+'？') $body '只切换线路，不会下单或改动订单。切换后请核对 NinjaTrader 的账户与持仓。' '切换交易线路' {ApplyRunning $script:PendingTrade 'Applying' ('交易已切到 '+$script:PendingTradeName+'，请在 NinjaTrader 中重新连接')}
}
# Compatibility name: HongKong/hk is the engine's historical self-hosted enum,
# independent of the current server's country. Never choose another NodeId.
function CanReturnHongKong {return ((IsRunning) -and [bool]$script:Overview.ManifestPath)}
function QuickHongKong {if((IsBusy) -or -not (CanReturnHongKong)){return};OnTrade ('node:'+(ActiveNodeId))}
function QuickTradingOnly {
 if((IsBusy) -or -not (IsRunning)){return}
 ApplyRunning @{Mode='Trading';Daily='Direct'} 'ApplyingDaily' '已设为仅交易：日常直连，交易出口与 AI 助手设置保持'
}
function StartSession {param([string]$Action);if($Action -eq 'Connect'){ConnectDefaultSelection;return};$script:PendingRecoveryNodeId=[string]$script:Prefs.NodeId;$transition=switch($Action){'Disconnect'{'Disconnecting'}default{'Applying'}};StartJob (SessionRequest $Action) {param($d)$script:Overview=$d;$script:Pending=$null;Render;if($d.PSObject.Properties['PreferenceFallback'] -and $d.PreferenceFallback){Toast ([string]$d.PreferenceFallback)};RefreshOverview -Silent} '正在处理连接操作…' $transition -Failed {param($message)OfferConnectionRecovery $message $script:PendingRecoveryNodeId}}
function ConnectDefaultSelection {
 if(IsBusy){return}
 $id=[string]$script:Prefs.NodeId
 if(-not $id){$ready=@($script:Nodes|Where-Object {$_.manifestPath});if($ready.Count -eq 1){$id=[string]$ready[0].id}else{ShowNodes;return}}
 $node=@($script:Nodes|Where-Object {$_.id -eq $id})|Select-Object -First 1
 if($node -and (ProfileUIField $node 'Recommendation') -and -not (LineRecommendationView $node).CanConnect){ShowConnectionRecovery $id '';return}
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
 $n=NodeEntry $Id;$name=if($n){$n.name}else{'此线路'}
 $script:PendingDeleteNodeId=$Id;$script:PendingDeleteNodeName=$name
 OpenDialog "移除本机线路「$name」？" "将从本机列表中移除「$name」及其配置文件。`n`n删除后如需再次使用，需重新导入配置。" "此操作不可逆。删除不会影响服务器上已部署的远程服务。" "移除本机线路" {
  $targetId=if($script:PendingDeleteNodeId){$script:PendingDeleteNodeId}else{$Id}
  $targetName=if($script:PendingDeleteNodeName){$script:PendingDeleteNodeName}else{$name}
  if(-not $targetId){ErrorDialog '未能确定要删除的线路 ID。';return}
  StartJob @{Action='DeleteNode';Id=$targetId} {param($d)FetchNodes;Toast $d.Message} ("正在删除线路「$targetName」...")
 } "取消" 'Danger'
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
 $n=NodeEntry $Id;$oldName=if($n){$n.name}else{''}
 Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction SilentlyContinue
 $newName=[Microsoft.VisualBasic.Interaction]::InputBox("请输入线路的新名称：", "重命名自建线路", $oldName)
 if(-not [string]::IsNullOrWhiteSpace($newName) -and $newName -ne $oldName){
  StartJob @{Action='RenameNode';Id=$Id;Name=$newName} {param($d)FetchNodes;Toast ("线路已重命名为「"+[string]$d.name+"」")} "正在重命名..."
 }
}

function PrimaryAction {
 switch((StateKey)){
  'Unconfigured'{if(@($script:Nodes|Where-Object {$_.manifestPath}).Count){StartSession 'Connect'}else{$script:Step=0;ShowSetup}}
  'Disconnected'{StartSession 'Connect'}
  'Connected'{OpenDisconnect}
  'Fault'{if($script:Overview.PrimaryAction -eq 'Disconnect'){OpenDisconnect}elseif($script:Overview.PrimaryEnabled -and $script:Overview.CanConnect){StartSession 'Connect'}else{RefreshOverview}}
 }
}
function OpenDisconnect {OpenDialog '断开交易通道？' "NinjaTrader、TradingView 等经过通道的连接会立即中断。`n`n断开后普通网络照常可用；NinjaTrader 仍被保护，不能直接联网，直到再次连接。" '如果有挂单或持仓，请先在交易软件中核对。关闭窗口不会断开通道。' '断开通道' {StartSession 'Disconnect'} '保持连接' 'Danger'}
function OpenUpgrade {OpenDialog '维护窗口：更新线路配置' "重新生成线路配置，补齐交易/全局模式及已登记的服务商。`n`n本操作通过检查后重新连接，原配置保留用于回退。配置维护会短暂中断经过通道的交易、AI 助手连接。" '请先退出整个 NinjaTrader。取消后当前连接保持；仅更新界面不会重新加载引擎配置。' '更新并重新连接' {StartJob @{Action='UpgradeActive'} {param($d)$script:Pending=$null;FetchNodes;Toast '线路配置维护已完成，请重新检查连接状态'} '正在更新线路配置…' 'Applying'}}
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
. (Join-Path $PSScriptRoot 'ui\LinuxPages.ps1')
. (Join-Path $PSScriptRoot 'ui\NavigationContext.ps1')
. (Join-Path $PSScriptRoot 'ui\TransportPages.ps1')
. (Join-Path $PSScriptRoot 'ui\ManagementPages.ps1')
. (Join-Path $PSScriptRoot 'ui\RuntimePages.ps1')
. (Join-Path $PSScriptRoot 'ui\DeploymentPages.ps1')
. (Join-Path $PSScriptRoot 'ui\ServerPages.ps1')
. (Join-Path $PSScriptRoot 'ui\PairingPages.ps1')
. (Join-Path $PSScriptRoot 'ui\WindowLifecycle.ps1')
. (Join-Path $PSScriptRoot 'ui\AutomaticTransportPages.ps1')
. (Join-Path $PSScriptRoot 'ui\ConnectionProfilePages.ps1')
. (Join-Path $PSScriptRoot 'ui\OperationHistoryPages.ps1')
. (Join-Path $PSScriptRoot 'ui\DeploymentIdentityPages.ps1')
foreach($name in @('Home','Nodes','Setup','Settings')){$button=$script:Window.FindName('Nav'+$name);$button.Add_Click({
 if($script:Job -and -not $script:Job.Silent){return}
 switch([string]$this.Name){'NavHome'{ShowHome;RefreshOverview -Silent}'NavNodes'{ShowNodes;FetchNodes}'NavSetup'{$script:Step=0;ShowSetup}'NavSettings'{ShowSettings;StartJob @{Action='StartupStatus'} {param($d)$script:Prefs.OpenAtLogin=[bool]$d.Enabled;if($script:Page -eq 'settings'){ShowSettings}} '读取启动设置…' '' -Silent}}
})}
$script:Timer=New-Object Windows.Threading.DispatcherTimer;$script:Timer.Interval=[TimeSpan]::FromMilliseconds(250)
$script:Timer.Add_Tick({
 if($script:WakeEvent -and $script:WakeEvent.WaitOne(0)){ShowExistingConsole}
 if($script:Job){$j=$script:Job;if(Test-Path -LiteralPath $j.Result){
  try{$r=Get-Content -LiteralPath $j.Result -Raw -Encoding UTF8|ConvertFrom-Json}catch{return};$script:Job=$null;$script:HostPanel.IsEnabled=$true
  $wasPending=$script:Pending;$script:Pending=$null
  if($r.Ok){
   try{
    & $j.Complete $r.Data
    if(-not $j.Silent -and ($script:Footer.Text -eq $j.Message -or $script:Footer.Text -like '正在*')){$script:Footer.Text='状态就绪 · '+(Get-Date -Format 'HH:mm:ss')}
   }catch{ErrorDialog $_.Exception.Message}
  }
  else{$script:Footer.Text='未完成：'+$r.Message;if($j.Failed){& $j.Failed $r.Message}elseif(-not $j.Silent){ErrorDialog $r.Message}
   if($j.Action -eq 'Overview'){$script:Overview=[pscustomobject]@{StateKey='Fault';Running=$false;Error=('状态读取未完成：'+$r.Message);PrimaryAction='Retry';PrimaryEnabled=$false;CanConnect=$false;GuardState='Unknown'};ObserveTrayState $script:Overview;UpdateChrome;if($script:Page -eq 'home'){ShowHome}}
   elseif($j.Action -in @('Session','RemoveProtection','UpgradeActive')){RefreshOverview -Silent}elseif($j.Action -eq 'SetStartup' -and $script:Page -eq 'settings'){ShowSettings}elseif($wasPending -and $script:Page -eq 'home'){ShowHome}}
  foreach($p in @($j.Request,$j.Result)){if(Test-Path -LiteralPath $p){Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue}};$j.Process.Dispose()
  if($script:QueuedJob){$queued=$script:QueuedJob;$script:QueuedJob=$null;StartJob -Request $queued.Request -Complete $queued.Complete -Message $queued.Message -Transition $queued.Transition -Failed $queued.Failed}
  if($script:Window.FindName('Overlay').Visibility -eq 'Visible'){$script:HostPanel.IsEnabled=$false}
  UpdateChrome
 }elseif($j.Process.HasExited){
  $script:Job=$null;$script:Pending=$null;$script:QueuedJob=$null;$script:HostPanel.IsEnabled=$true;$script:Footer.Text='未取得后台结果，请查看实际状态。'
  if($j.Failed){& $j.Failed '后台未返回结果，请重新检查；未继续执行后续操作。'}else{
   $script:Overview=[pscustomobject]@{StateKey='Fault';Running=$false;Error='后台未返回结果，尚不能确认当前状态。';PrimaryAction='Retry';PrimaryEnabled=$false;CanConnect=$false;GuardState='Unknown'}
   if($script:Page -eq 'home'){ShowHome};if(-not $j.Silent){ErrorDialog '后台未返回结果，不能确认本次操作是否生效。请重新检查状态。'}
  };UpdateChrome
  if(Test-Path -LiteralPath $j.Request){Remove-Item -LiteralPath $j.Request -Force -ErrorAction SilentlyContinue};$j.Process.Dispose()
 };return}
 if(-not $script:Smoke -and $script:Linux.Busy -and $script:Linux.JobId -and ((Get-Date)-$script:Linux.PollAt).TotalSeconds -gt 2){PollLinux;return}
 if(-not $script:Smoke -and ($script:DeployUI.SessionRef -or $script:DeployUI.Identity -or (DeploymentLocalCheckPending $script:DeployUI.Run))){PollProductDeployment}
 if(-not $script:Smoke){RefreshExpiredProtocolPresentation}
 $observationSeconds=if($script:Window.IsVisible){5}else{15}
 if(-not $script:Smoke -and -not $script:Job -and ((Get-Date)-$script:LastPoll).TotalSeconds -gt $observationSeconds){$script:LastPoll=Get-Date;RefreshOverview -Silent}
})
$script:Tray=New-Object Windows.Forms.NotifyIcon;$trayIconPath=Join-Path $PSScriptRoot 'assets\TradeChannel.ico';if(Test-Path -LiteralPath $trayIconPath){$script:AppTrayIcon=New-Object Drawing.Icon($trayIconPath);$script:Tray.Icon=$script:AppTrayIcon}else{$script:Tray.Icon=[Drawing.SystemIcons]::Application};$script:Tray.Text='TradeChannel';$script:Tray.Visible=(-not $SelfTest)
$menu=New-Object Windows.Forms.ContextMenuStrip;$script:TraySummary=New-Object Windows.Forms.ToolStripMenuItem('正在核对状态');$script:TraySummary.Enabled=$false;$null=$menu.Items.Add($script:TraySummary);$null=$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator));$openItem=$menu.Items.Add('打开控制台');$openItem.Add_Click({ShowExistingConsole});$diagnoseItem=$menu.Items.Add('查看运行诊断');$diagnoseItem.Add_Click({ShowExistingConsole;ShowRuntimeReport});$null=$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator));$exitItem=$menu.Items.Add('退出界面（连接保持）');$exitItem.Add_Click({RequestInterfaceExit});$script:Tray.ContextMenuStrip=$menu
$script:Tray.Add_DoubleClick({ShowExistingConsole})
$script:NormalTrayIcon=$script:Tray.Icon
$script:Tray.Add_BalloonTipClicked({$script:Window.Show();$script:Window.WindowState='Normal';$script:Page='home';ShowHome;RefreshOverview -Silent;$null=$script:Window.Activate()})
$script:Window.Add_Closing({param($sender,$e)HandleWindowClosing $e})
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
  StartJob @{Action='Preferences'} {param($d)
   foreach($k in @('Mode','Exit','Daily','NodeId','ProviderId','TradeProviderId','ProfileId')){if($d.PSObject.Properties[$k]){$script:Prefs[$k]=$d.$k}};ReadAgentPrefs $d;$script:Prefs.OpenAtLogin=[bool]$d.OpenAtLogin
   StartJob @{Action='Nodes'} {param($nodes)
    $script:Nodes=@($nodes|Where-Object {$_})
    StartJob @{Action='Providers'} {param($providers)ReadProviders $providers;RefreshOverview} '正在读取服务商…' -Failed {param($message)$script:ProviderReadError=[string]$message;$script:ProvidersAt=Get-Date;RefreshOverview}
   } '正在读取线路…'
  } '正在读取连接偏好…'
 })
 # A modal ShowDialog loop ends when Hide() is called. Keep a modeless
 # dispatcher alive while the window is in the tray, and end it only on Closed.
 $script:Window.Add_Closed({$script:Window.Dispatcher.BeginInvokeShutdown([Windows.Threading.DispatcherPriority]::Background)})
 try{$script:Window.Show();[Windows.Threading.Dispatcher]::Run()}
 finally{$script:Timer.Stop();ReleaseWindowManagementSession;ReleaseBrandResources;if($script:WakeEvent){$script:WakeEvent.Dispose()};if($script:UiMutex){$script:UiMutex.ReleaseMutex();$script:UiMutex.Dispose()}}
}
