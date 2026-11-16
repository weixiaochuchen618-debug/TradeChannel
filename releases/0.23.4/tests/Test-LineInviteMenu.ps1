#requires -Version 5.1
# 0.22.0 T04b (A8 / A-16): the degraded shell's line card menu carries 「邀请其他电脑」.
# ui/LineCardControls.ps1 is a red-line file, so the four lines this release added
# get their own guard: the item exists in the agreed place, it is hidden (not
# disabled) where no invitation can be created, and choosing it lands on the same
# server page the web page opens. No window, no worker, no network, no file write.
[CmdletBinding()]param([string]$PackageRoot='')
if([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw 'Run this isolated regression with Windows PowerShell -Sta.'}
$ErrorActionPreference='Stop';Add-Type -AssemblyName PresentationFramework
if(-not $PackageRoot){$PackageRoot=Split-Path $PSScriptRoot -Parent}
$script:PackageRoot=[IO.Path]::GetFullPath($PackageRoot)
$script:Root=Join-Path ([IO.Path]::GetTempPath()) ('tc-lineinvite-'+[guid]::NewGuid().ToString('N'))
$script:Smoke=$true;$script:ReadOnly=$false;$script:Busy=$false
$script:Ink='#141414';$script:Text2='#333333';$script:Text3='#666666'
$script:Tone=@{ok=@{Fg='#2E7D32'};bad=@{Fg='#C62828'};warn=@{Fg='#B26A00'}}
$script:Controls=@{};$checks=New-Object 'Collections.Generic.List[string]'
function Check([bool]$Condition,[string]$Name){if(-not $Condition){throw ('FAILED: '+$Name)};$checks.Add($Name)}
function IsBusy {return $false}
function Card($padding='20'){$c=New-Object Windows.Controls.Border;return $c}
function Grid($columns){$g=New-Object Windows.Controls.Grid;foreach($c in $columns){$null=$g.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition))};return $g}
function Stack($orientation='Vertical'){$s=New-Object Windows.Controls.StackPanel;$s.Orientation=$orientation;return $s}
function T($text,$size=13,$color='black',$weight='Normal'){$c=New-Object Windows.Controls.TextBlock;$c.Text=[string]$text;return $c}
function ControlName($control,$name){$script:Controls[$name]=$control;return $control}
function Btn($text,$id,$action,$style='Btn'){$b=New-Object Windows.Controls.Button;$b.Content=$text;$b.Add_Click($action);if($id){$script:Controls[$id]=$b};return $b}
function B($hex){return $null}
function Margin($control,$margin){$control.Margin=$margin;return $control}
function AddC($parent,$child){if($parent -is [Windows.Controls.Border]){$parent.Child=$child}else{$null=$parent.Children.Add($child)}}
function Cell($grid,$control,$index){[Windows.Controls.Grid]::SetColumn($control,[int]$index);$null=$grid.Children.Add($control)}
function Pill($text,$tone='idle'){$b=New-Object Windows.Controls.Border;$b.Child=T $text;return $b}
function UpdateLineCardLayoutUI {param($id,$width)return}
function ProfileUIField {param($v,$n,$d=$null)return $d}
function NodeHasActiveProfile {param($line)return $false}
function UILineId {param($line)return [string]$line.LineId}
function ActiveNodeProfileId {param($line)return 'Udp'}
function NodeProfileItems {param($line)return @()}
function Get-TCExitCheckContext {param($o)return [pscustomobject]@{Fields=@{Exit='hk'}}}
function Test-TCLineCheckBinding {return $false}
function GetUiPendingOperationViews {return @()}
function StateKey {param($o)return 'AllStopped'}
function GetLineCardViewModel {param($p,$r,$pending)return $p}
function OpenLineServerManagement {param([string]$LineId,[string]$ReturnKind='Context')$script:OpenedServer=$LineId}
function OpenRenameNode {param($id)}
function ShowConfigurationRollback {param($id)}
function LoadLineConnections {param($id)}
function OpenDeleteNode {param($id)}
# ---- the two ends of the A8 entry ----------------------------------------------
$script:InviteBinding=@{CanInvite=$true;ServerRecordId='server-a'}
function GetTCWebLineInviteBindingUI {param([string]$LineId)return $script:InviteBinding}
$script:Routed=$null
function OpenLineServerInviteUI {param([string]$LineId)$script:Routed=$LineId}

. (Join-Path $script:PackageRoot 'ui\LineCardControls.ps1')
Remove-Item Function:\GetLineCardViewModel -ErrorAction SilentlyContinue

$lineId='11111111-1111-1111-1111-111111111111'
function New-View {param([string]$Id)
 [pscustomobject]@{LineId=$Id;Name='主线路';Revision=7;RuntimeBadge='已连接';ServerHost='203.0.113.10';Protocols=@();PrimaryLabel='断开';PrimaryAction='Disconnect';CheckProfileId='Udp';ActiveProfileId='Udp';CanDelete=$true;DeleteReason='';Pending=$false}}
$panel=New-Object Windows.Controls.StackPanel

# 1. The item is on the menu and disabled nowhere - it is collapsed instead.
AddLineCard $panel (New-View $lineId)
$key=$lineId.Replace('-','')
$item=$script:Controls['InviteNode'+$key]
Check ($null -ne $item) 'A8 the line card menu carries an invitation item'
Check ([string]$item.Header -ceq '邀请其他电脑') 'A8 the item reads 邀请其他电脑'
Check ([string]$item.Tag.Action -ceq '邀请' -and [string]$item.Tag.LineId -ceq $lineId) 'A8 the item carries the line, not a server'
$headers=@($script:Controls['MoreNode'+$key].ContextMenu.Items|Where-Object {$_ -is [Windows.Controls.MenuItem]}|ForEach-Object {[string]$_.Header})
Check (($headers -join '|') -ceq '线路详情与检查记录|服务器与设备管理|邀请其他电脑|修改名称|还原历史配置|断开当前连接|删除线路及本机资料') ('A8 the item sits right after 服务器 and before 名称, got '+($headers -join '|'))
Check ([string]$item.Visibility -ceq 'Visible') 'A8 a line that can invite shows the item'

# 2. A-16: a line with no manageable server has no entry at all.
$invite=$script:LineCardControls[$lineId].Invite
$script:InviteBinding=@{CanInvite=$false;ServerRecordId=''}
UpdateLineCardControlUI (New-View $lineId)
Check ([string]$invite.Visibility -ceq 'Collapsed') 'A-16 a line that cannot invite hides the item'
$script:InviteBinding=@{CanInvite=$true;ServerRecordId='server-a'}
UpdateLineCardControlUI (New-View $lineId)
Check ([string]$invite.Visibility -ceq 'Visible') 'A-16 the item comes back when the server becomes manageable'

# 3. Choosing it lands on the server page for that line - same entry as the web page.
InvokeLineCardMenuUI $item.Tag
Check ([string]$script:Routed -ceq $lineId) 'A8 choosing it routes to the line server page'
$item.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.MenuItem]::ClickEvent)))
Check ([string]$script:Routed -ceq $lineId) 'A8 clicking the menu item routes there too'

# 4. Without the invitation surface (a build without ui/WebInvite.ps1) the item
#    stays hidden rather than failing open.
Remove-Item Function:\GetTCWebLineInviteBindingUI
UpdateLineCardControlUI (New-View $lineId)
Check ([string]$invite.Visibility -ceq 'Collapsed') 'A8 without the invitation surface the item stays hidden'

[pscustomobject]@{Passed=$true;Checks=$checks.Count;Assertions=$checks.ToArray()}|ConvertTo-Json -Depth 3
