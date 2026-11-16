#requires -Version 5.1
[CmdletBinding()]param([string]$ReportPath)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$script:PackageRoot=Split-Path $PSScriptRoot -Parent
. (Join-Path $script:PackageRoot 'ui\BackgroundJobs.ps1')
. (Join-Path $script:PackageRoot 'ui\NavigationContext.ps1')
$script:Window=New-Object Windows.Window;$script:Window.Width=520;$script:Window.Height=320
[Windows.NameScope]::SetNameScope($script:Window,(New-Object Windows.NameScope))
$root=New-Object Windows.Controls.Grid;$script:Window.Content=$root
$scroll=New-Object Windows.Controls.ScrollViewer;$root.Children.Add($scroll)|Out-Null
$panel=New-Object Windows.Controls.StackPanel;$scroll.Content=$panel
$overlay=New-Object Windows.Controls.Border;$overlay.Name='Overlay';$overlay.Visibility='Collapsed';$root.Children.Add($overlay)|Out-Null;$script:Window.RegisterName('Overlay',$overlay)
$input=New-Object Windows.Controls.TextBox;$input.Text='unsaved server address';$panel.Children.Add($input)|Out-Null
$password=New-Object Windows.Controls.PasswordBox;$password.Password='in-memory-fixture';$panel.Children.Add($password)|Out-Null
$list=New-Object Windows.Controls.ListBox;$list.SelectionMode='Multiple';foreach($name in @('first','second','third')){$list.Items.Add($name)|Out-Null};$list.SelectedItems.Add('first');$list.SelectedItems.Add('third');$panel.Children.Add($list)|Out-Null
$badge=New-Object Windows.Controls.TextBlock;$panel.Children.Add($badge)|Out-Null
$spacer=New-Object Windows.Controls.Border;$spacer.Height=800;$panel.Children.Add($spacer)|Out-Null
$script:Footer=New-Object Windows.Controls.TextBlock;$script:Controls=@{NodeStatusfixture=$badge;ProfileStatusUdp=$badge}
$script:Page='nodes';$script:Role='client';$script:Step=0;$script:DeployUI=@{Screen='connect'};$script:ProviderFormOpen=$true;$script:QueuedJob=$null;$script:ReadOnly=$false;$script:Prefs=@{};$script:AgentPresenceAt=Get-Date;$script:ProvidersAt=Get-Date
$script:LineProfileUI=@{Id='fixture';Line=@{id='fixture'}};$script:Nodes=@(@{id='fixture'});$script:Overview=@{Running=$false};$script:Updates=0;$script:HostPanel=$panel
function ObserveTrayState {param($d)}
function UpdateChrome {$script:Updates++}
function ShowNodes {throw 'Background callback rebuilt the edit page'}
function ShowLineConnections {throw 'Background callback rebuilt connection choices'}
function ReadProviders {param($d)$script:Providers=$d;$script:ProvidersAt=Get-Date}
function NodeHasActiveProfile {param($n)[bool]$script:Overview.Running}
function ActiveLineStatus {param($n)'connected fixture'}
function LineRecommendationView {param($n)[pscustomobject]@{Label='saved fixture'}}
function NodeProfileItems {param($n)[pscustomobject]@{Id='Udp'}}
function ActiveNodeProfileId {param($n)if($script:Overview.Running){'Udp'}}
function ConnectionProfileStatus {param($p)'prepared fixture'}
function StartJob {param($Request,$Complete,$Message,$Transition,[switch]$Silent,$Failed)
 $d=switch($Request.Action){'Overview'{[pscustomobject]@{Running=$true;NodeId='fixture'}}'Providers'{[pscustomobject]@{Items=@()}}'Agents'{[pscustomobject]@{Entries=@()}}default{throw 'Unexpected refresh request'}};& $Complete $d
}
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $script:PackageRoot 'TradeChannel.ps1'),[ref]$tokens,[ref]$errors)
foreach($name in @('RefreshOverview','FetchProviders','FetchAgents')){$definition=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true);. ([scriptblock]::Create($definition.Extent.Text))}
$checks=0
function Check {param([bool]$ok,[string]$message)if(-not $ok){throw $message};$script:checks++}
try{
 $script:Window.Show();$script:Window.UpdateLayout();$null=$input.Focus();$scroll.ScrollToVerticalOffset(0)
 foreach($scenario in @('provider-editor','protocol-choice','server-input','history-selection','dialog')){
  $script:Page=if($scenario -eq 'protocol-choice'){'line-profiles'}elseif($scenario -in @('server-input','history-selection')){'setup'}else{'nodes'}
  $overlay.Visibility=if($scenario -eq 'dialog'){'Visible'}else{'Collapsed'}
  $context=SetNavigationContext 'nodes' 'nodes-editor:fixture'
  $focused=[Windows.Input.Keyboard]::FocusedElement;$offset=$scroll.VerticalOffset;$children=$panel.Children.Count
  foreach($i in 1..30){RefreshOverview -Silent;FetchProviders -Silent;FetchAgents}
  Check ($input.Text -ceq 'unsaved server address' -and $password.SecurePassword.Length -eq 17) ($scenario+': input retained')
  Check ($list.SelectedItems.Count -eq 2 -and $list.SelectedItems.Contains('first') -and $list.SelectedItems.Contains('third')) ($scenario+': selection retained')
  Check ([object]::ReferenceEquals($focused,[Windows.Input.Keyboard]::FocusedElement) -and $panel.Children.Count -eq $children -and $scroll.VerticalOffset -eq $offset) ($scenario+': focus, controls and scroll retained')
 }
 Check ($badge.Text -eq 'connected fixture' -and $script:Updates -ge 450) 'Live state continued updating during edit preservation'
 $result=[pscustomobject]@{Passed=$true;Checks=$checks;Callbacks=450;WpfControls=$true;PasswordPersisted=$false;NetworkChanges=0}
 if($ReportPath){[IO.File]::WriteAllText($ReportPath,($result|ConvertTo-Json),[Text.UTF8Encoding]::new($true))};$result|ConvertTo-Json -Compress
}finally{$script:Window.Close()}
