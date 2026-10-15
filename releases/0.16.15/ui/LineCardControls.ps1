$script:LineCardControls=@{}
$script:LinePreferenceRequests=@{}
$script:LineCheckRequests=@{}
$script:LineCheckResults=@{}
function GetLineCardRuntimeUI {param($Line)
 $active=NodeHasActiveProfile $Line;$id=UILineId $Line
 $validation=ProfileUIField $script:Overview RuntimeValidation
 $currentContext=Get-TCExitCheckContext $script:Overview
 $latest=$script:LineCheckResults[$id]
 if($active -and (Test-TCLineCheckBinding $latest $currentContext $id (ActiveNodeProfileId $Line))){$validation=$latest}
 [pscustomobject]@{Running=[bool](IsRunning);LineId=$(if($active){$id}else{[string](ProfileUIField $script:Overview ActiveLineId '')});ProfileId=$(if($active){ActiveNodeProfileId $Line}else{''});TradeInUse=($active -and [string]$currentContext.Fields.Exit -ceq 'hk');SessionId=(ProfileUIField $script:Overview SessionId '');ConfigHash=(ProfileUIField $script:Overview ConfigHash '');CheckContext=$currentContext;Validation=$validation}
}
function GetLineCardStateUI {param($Line)
 $id=UILineId $Line;$pending=$script:LinePreferenceRequests[$id];if(-not $pending){$pending=$script:LineCheckRequests[$id]}
 $projection=$Line|ConvertTo-Json -Depth 40|ConvertFrom-Json
 $profiles=@(NodeProfileItems $Line|ForEach-Object {$p=$_|ConvertTo-Json -Depth 30|ConvertFrom-Json;$p|Add-Member NoteProperty Validation (ProfileValidationView (ProfileUIField $p Validation)) -Force;$p})
 $projection|Add-Member NoteProperty Profiles $profiles -Force
 if(-not $Line.PSObject.Properties['DefaultVerified']){
  $saved=ProfileUIField $Line SavedConnectionPreference;$verified=$false
  $selected=@($profiles|Where-Object Id -ceq ([string](ProfileUIField $saved ProfileId '')))|Select-Object -First 1
  if($saved -and $selected){try{Import-Module (Join-Path $script:PackageRoot 'ProtocolSelection.psm1') -DisableNameChecking;$verified=Test-TCSavedConnectionPreference -Preference $saved -LineId $id -Profile $selected -Manifest ([IO.File]::ReadAllText($selected.ManifestPath)|ConvertFrom-Json)}catch{}}
  $projection|Add-Member NoteProperty DefaultVerified $verified -Force
 }
 GetLineCardViewModel $projection (GetLineCardRuntimeUI $Line) $pending
}
function AddLineCard {param($Parent,$ViewModel)
 $id=$ViewModel.LineId;$key=$id.Replace('-','');$card=ControlName (Card '18,16') ('NodeCard'+$key);$card.Margin='0,0,0,10';$card.MinHeight=112
 $g=Grid @('*','260','Auto');foreach($i in 0..1){$r=New-Object Windows.Controls.RowDefinition;$r.Height='Auto';$g.RowDefinitions.Add($r)}
 $identity=Stack;$identity.Margin='0,0,18,0';$identity.VerticalAlignment='Center'
 $name=T $ViewModel.Name 15 $script:Ink 'SemiBold';$name.TextWrapping='NoWrap';$name.TextTrimming='CharacterEllipsis';$name.ToolTip=$ViewModel.Name;AddC $identity $name
 $badge=ControlName (T $ViewModel.RuntimeBadge 11.5 $script:Tone.ok.Fg 'SemiBold') ('NodeStatus'+$key);$badge.Margin='0,4,0,0';AddC $identity $badge
 $hostText=T $ViewModel.ServerHost 12 $script:Text3;$hostText.TextWrapping='NoWrap';$hostText.TextTrimming='CharacterEllipsis';$hostText.ToolTip=$ViewModel.ServerHost;AddC $identity (Margin $hostText '0,6,0,0')
 $protocols=Grid @('*','*');$protocols.Margin='0,0,12,0';$protocols.VerticalAlignment='Center'
 $radios=@{};$labels=@{};$healths=@{};$index=0
 foreach($p in $ViewModel.Protocols){
  $radio=ControlName (New-Object Windows.Controls.RadioButton) ('Default'+$p.Id+$key);$radio.GroupName='LineDefault'+$key;$radio.MinHeight=62;$radio.Margin='0,0,6,0';$radio.HorizontalContentAlignment='Stretch';$radio.VerticalContentAlignment='Center'
  $radio.Template=[Windows.Markup.XamlReader]::Parse('<ControlTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" TargetType="RadioButton"><Border x:Name="Frame" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" CornerRadius="12" Background="#F5F6F8" BorderBrush="#E6E8EB" BorderThickness="1" Padding="10,8"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border><ControlTemplate.Triggers><Trigger Property="IsChecked" Value="True"><Setter TargetName="Frame" Property="BorderBrush" Value="#3B6FF6"/><Setter TargetName="Frame" Property="Background" Value="#EEF3FE"/></Trigger><Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Frame" Property="BorderThickness" Value="2"/></Trigger></ControlTemplate.Triggers></ControlTemplate>')
  $copy=Stack;$label=T $p.Label 12 $script:Ink 'SemiBold';$label.TextWrapping='Wrap';$label.TextAlignment='Center';$h=T $p.Health 11.5 $script:Text2;$h.TextAlignment='Center';$h.Margin='0,4,0,0';AddC $copy $label;AddC $copy $h;$radio.Content=$copy
  $radio.Tag=@{LineId=$id;ProfileId=$p.Id;Revision=$ViewModel.Revision;Rendering=$true};$radio.IsChecked=$p.IsDefault
  $radio.Add_Checked({if(-not $this.Tag.Rendering){SaveLineDefaultProfileForLineUI ([string]$this.Tag.LineId) ([string]$this.Tag.ProfileId) ([long]$this.Tag.Revision) 'Card'}})
  $radio.Tag.Rendering=$false;$radios[$p.Id]=$radio;$labels[$p.Id]=$label;$healths[$p.Id]=$h;Cell $protocols $radio $index;$index++
 }
 $actions=Grid @('Auto','34','34');$actions.VerticalAlignment='Center'
 $primary=Btn $ViewModel.PrimaryLabel ('Node'+$key) {InvokeLineCardPrimaryUI ([string]$this.Tag)} 'Btn';$primary.Tag=$id;$primary.MinWidth=122;$primary.MinHeight=38;Cell $actions $primary 0
 $check=Btn '↻' ('DiagNode'+$key) {CheckLineCardProtocolUI ([string]$this.Tag)} 'Ghost';$check.Padding='0';$check.MinWidth=30;$check.MinHeight=38;$check.FontSize=18;$check.Tag=$id;$check.ToolTip='检查这条线路所选协议';[Windows.Automation.AutomationProperties]::SetName($check,'检查所选协议');Cell $actions $check 1
 $more=Btn '⋯' ('MoreNode'+$key) {$this.ContextMenu.PlacementTarget=$this;$this.ContextMenu.IsOpen=$true} 'Ghost';$more.Padding='0';$more.MinWidth=30;$more.MinHeight=38;$more.FontSize=20;$more.Tag=$id;$more.ToolTip='更多线路操作';[Windows.Automation.AutomationProperties]::SetName($more,'更多线路操作');Cell $actions $more 2
 $menu=New-Object Windows.Controls.ContextMenu;$delete=$null;$disconnect=$null
 foreach($spec in @(@('详情','线路详情与检查记录','Profiles'),@('服务器','服务器与设备管理','ManageNodeServer'),@('名称','修改名称','RenNode'),@('历史','还原历史配置','RollbackNode'),@('断开','断开当前连接','DisconnectNode'),@('分隔','',''),@('删除','删除线路及本机资料','DelNode'))){
  if($spec[0] -eq '分隔'){$menu.Items.Add((New-Object Windows.Controls.Separator))|Out-Null;continue}
  $item=ControlName (New-Object Windows.Controls.MenuItem) ($spec[2]+$key);$item.Header=$spec[1];$item.Tag=@{LineId=$id;Action=$spec[0]};$item.Add_Click({InvokeLineCardMenuUI $this.Tag});$menu.Items.Add($item)|Out-Null
  if($spec[0] -eq '删除'){$delete=$item;$item.Foreground=B $script:Tone.bad.Fg;[Windows.Controls.ToolTipService]::SetShowOnDisabled($item,$true)}
  if($spec[0] -eq '断开'){$disconnect=$item}
 }
 $more.ContextMenu=$menu;Cell $g $identity 0;Cell $g $protocols 1;Cell $g $actions 2;$card.Child=$g
 $script:LineCardControls[$id]=@{Card=$card;Grid=$g;Identity=$identity;Protocols=$protocols;Actions=$actions;Badge=$badge;Radios=$radios;Labels=$labels;Healths=$healths;Primary=$primary;Check=$check;Menu=$menu;Delete=$delete;Disconnect=$disconnect}
 $card.Tag=$id;$card.Add_SizeChanged({UpdateLineCardLayoutUI ([string]$this.Tag) $this.ActualWidth});AddC $Parent $card;UpdateLineCardControlUI $ViewModel
}
function UpdateLineCardLayoutUI {param([string]$Id,[double]$Width)
 $u=$script:LineCardControls[$Id];if(-not $u){return};$narrow=($Width -gt 0 -and $Width -lt 720)
 if($narrow){$u.Grid.ColumnDefinitions[1].Width='*';[Windows.Controls.Grid]::SetColumnSpan($u.Identity,3);[Windows.Controls.Grid]::SetRow($u.Protocols,1);[Windows.Controls.Grid]::SetColumn($u.Protocols,0);[Windows.Controls.Grid]::SetColumnSpan($u.Protocols,2);[Windows.Controls.Grid]::SetRow($u.Actions,1);$u.Protocols.Margin='0,12,12,0';$u.Actions.Margin='0,12,0,0'}
 else{$u.Grid.ColumnDefinitions[1].Width='260';[Windows.Controls.Grid]::SetColumnSpan($u.Identity,1);[Windows.Controls.Grid]::SetRow($u.Protocols,0);[Windows.Controls.Grid]::SetColumn($u.Protocols,1);[Windows.Controls.Grid]::SetColumnSpan($u.Protocols,1);[Windows.Controls.Grid]::SetRow($u.Actions,0);$u.Protocols.Margin='0,0,12,0';$u.Actions.Margin='0'}
}
function UpdateLineCardControlUI {param($View)
 $u=$script:LineCardControls[$View.LineId];if(-not $u){return}
 $u.Badge.Text=$View.RuntimeBadge;$u.Badge.Visibility=if($View.RuntimeBadge){'Visible'}else{'Collapsed'}
 foreach($p in $View.Protocols){$radio=$u.Radios[$p.Id];$radio.Tag.Rendering=$true;$radio.Tag.Revision=$View.Revision;$radio.IsChecked=$p.IsDefault;$radio.Tag.Rendering=$false
  $radio.IsEnabled=($p.CanSelect -and -not $script:ReadOnly -and -not (IsBusy));$u.Labels[$p.Id].Text=$p.Label;$u.Healths[$p.Id].Text=$p.Health;$u.Healths[$p.Id].Foreground=B $script:Tone[$p.Tone].Fg
  $radio.ToolTip=$p.BlockReason+$(if($p.CheckedAt){' 检查时间：'+(UIEvidenceTime $p.CheckedAt)}else{''});[Windows.Controls.ToolTipService]::SetShowOnDisabled($radio,$true)
  [Windows.Automation.AutomationProperties]::SetName($radio,($p.Label+'，'+$p.Health))
 }
 $u.Primary.Content=$View.PrimaryLabel;$u.Primary.IsEnabled=(-not $View.Pending -and -not (IsBusy) -and -not $script:ReadOnly)
 $u.Check.Visibility=if($View.PrimaryAction -eq 'Check'){'Hidden'}else{'Visible'};$u.Check.IsEnabled=($View.CheckProfileId -and -not $View.Pending -and -not (IsBusy) -and -not $script:ReadOnly)
 $u.Delete.IsEnabled=($View.CanDelete -and -not (IsBusy) -and -not $script:ReadOnly);$u.Delete.ToolTip=$View.DeleteReason
 $u.Disconnect.Visibility=if($View.ActiveProfileId){'Visible'}else{'Collapsed'};$u.Disconnect.IsEnabled=(-not (IsBusy) -and -not $script:ReadOnly)
}
function RefreshLineCardControlsUI {foreach($node in @($script:Nodes)){UpdateLineCardControlUI (GetLineCardStateUI $node)}}
function InvokeLineCardMenuUI {param($Target)
 $id=[string]$Target.LineId
 switch([string]$Target.Action){'详情'{LoadLineConnections $id}'服务器'{OpenLineServerManagement $id -ReturnKind Nodes}'名称'{OpenRenameNode $id}'历史'{ShowConfigurationRollback $id}'断开'{if(NodeHasActiveProfile (NodeEntry $id)){OpenDisconnect}}'删除'{OpenDeleteNode $id}}
}
function InvokeLineCardPrimaryUI {param([string]$Id)
 $node=NodeEntry $Id;if(-not $node){return};$view=GetLineCardStateUI $node
 switch($view.PrimaryAction){'Connect'{PreviewDefaultLineConnection $Id}'Check'{CheckLineCardProtocolUI $Id}'Repair'{RepairLineDefaultUI $Id}default{LoadLineConnections $Id}}
}
function RepairLineDefaultUI {param([string]$Id)
 if((IsBusy) -or $script:ReadOnly){return};$node=NodeEntry $Id;if(-not $node){return}
 if($script:LinePreferenceRequests.ContainsKey($Id)){return}
 $context=@{Type='Line';LineId=$Id;Id=$Id;ProfileId='';ExpectedRevision=[long]$node.Revision;UiRequestId=[guid]::NewGuid().ToString('N');Kind='Repair'};$script:LinePreferenceRequests[$Id]=$context;RefreshLineCardControlsUI
 StartJob @{Action='LinePreferenceRepair';Id=$Id;ExpectedRevision=$node.Revision;ExpectedDigest=[string](ProfileUIField $node.SavedConnectionPreference Digest '')} {param($result,$context)
  if([string](ProfileUIField $script:LinePreferenceRequests[$context.Id] UiRequestId '') -cne $context.UiRequestId){return}
  if($result.Code -in @('PreferenceRepaired','AlreadyCurrent')){FetchNodes;Toast '已核对原默认来源，当前连接保持'}else{LoadLineConnections $context.Id;Toast '原证据不足，请选择已准备的协议；无需重新部署'}
 } '核对旧默认来源…' -CallbackContext $context -Finalized {param($notice,$context) FinalizeLineRequestUI $notice $context}
}
function CheckLineCardProtocolUI {param([string]$Id)
 if((IsBusy) -or $script:ReadOnly){return};$node=NodeEntry $Id;if(-not $node){return};$view=GetLineCardStateUI $node
 if(-not $view.CheckProfileId){LoadLineConnections $Id;return}
 $request=[guid]::NewGuid().ToString('N');$context=@{Type='Line';LineId=$Id;Id=$Id;ProfileId=$view.CheckProfileId;ExpectedRevision=[long]$view.Revision;UiRequestId=$request;RequestId=$request;Kind='Check'};$script:LineCheckRequests[$Id]=$context;RefreshLineCardControlsUI
 StartJob @{Action='LineProfileCheck';Id=$Id;ProfileId=$context.ProfileId;ExpectedRevision=$view.Revision} {param($result,$context)
  if(-not $script:LineCheckRequests[$context.Id] -or $script:LineCheckRequests[$context.Id].RequestId -cne $context.RequestId){return}
  if($result.Check -and (ProfileUIField $result.Check SessionId '')){$script:LineCheckResults[$context.Id]=$result.Check};RefreshLineCardControlsUI
  Toast ([string]$result.Message);FetchNodes;RefreshOverview -Silent
 } '检查所选线路与协议…' -CallbackContext $context -Finalized {param($notice,$context) FinalizeLineRequestUI $notice $context} -Failed {param($message,$context)
  if($script:LineCheckRequests[$context.Id] -and $script:LineCheckRequests[$context.Id].RequestId -ceq $context.RequestId){ErrorDialog $message}
 }
}
