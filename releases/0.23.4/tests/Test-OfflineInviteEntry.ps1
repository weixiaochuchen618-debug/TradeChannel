#requires -Version 5.1
# 0.22.0 T04b (A6 / A-13): the offline invitation (24 hours) is reachable from both
# entry points - the invite page footer and the 「设备与邀请」 section - and neither
# of them asks for a device name any more: the host labels the device itself.
#
# Renders the real ui/ServerPages.ps1 detail page (the same scaffolding
# Test-DeploymentManagementUI.ps1 uses) and loads the real ui/WebInvite.ps1 so the
# web page's Offline phase is exercised through its own message entry.
# No window, no worker, no network, no file write.
[CmdletBinding()]param([string]$PackageRoot='')
if([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw 'Run this isolated regression with Windows PowerShell -Sta.'}
$ErrorActionPreference='Stop';Add-Type -AssemblyName PresentationFramework
if(-not $PackageRoot){$PackageRoot=Split-Path $PSScriptRoot -Parent}
$script:PackageRoot=[IO.Path]::GetFullPath($PackageRoot)
$script:Smoke=$true;$script:Root=Join-Path ([IO.Path]::GetTempPath()) ('tc-offline-invite-'+[guid]::NewGuid().ToString('N'))
$script:Controls=@{};$script:Requests=New-Object 'Collections.Generic.List[object]';$checks=New-Object 'Collections.Generic.List[string]'
$script:HostPanel=New-Object Windows.Controls.StackPanel;$script:Ink='#141414';$script:Text2='#333333';$script:Text3='#666666';$script:Role='servers';$script:Page='setup'
$script:Overview=[pscustomobject]@{ManifestPath='not-read-in-smoke'};$script:Dialog=$null;$script:WebAck=0
function Check {param([bool]$Condition,[string]$Name)if(-not $Condition){throw ('FAILED: '+$Name)};$checks.Add($Name)}
function Start-Process {throw 'UI regression must not launch processes.'}
function AddC($p,$c){$null=$p.Children.Add($c)}
function T($text,$size=13,$color='black',$weight='Normal'){$c=New-Object Windows.Controls.TextBlock;$c.Text=[string]$text;$c.TextWrapping='Wrap';return $c}
function Card($padding='20'){$c=New-Object Windows.Controls.Border;return $c}
function Stack($orientation='Vertical'){$s=New-Object Windows.Controls.StackPanel;$s.Orientation=$orientation;return $s}
function Grid($columns){$g=New-Object Windows.Controls.Grid;foreach($w in $columns){$c=New-Object Windows.Controls.ColumnDefinition;$c.Width=$w;$null=$g.ColumnDefinitions.Add($c)};return $g}
function Cell($grid,$child,$column=0){[Windows.Controls.Grid]::SetColumn($child,[int]$column);AddC $grid $child}
function Pill($text,$tone='idle'){$b=New-Object Windows.Controls.Border;$b.Child=T $text;return $b}
function Margin($control,$margin){return $control}
function B($hex){return $null}
function ControlName($control,$name){$script:Controls[$name]=$control;return $control}
function Btn($text,$id,$action,$style='Btn'){$b=New-Object Windows.Controls.Button;$b.Content=$text;$b.Add_Click($action);if($id){$script:Controls[$id]=$b};return $b}
function Head($kicker,$title,$description){$script:HostPanel.Children.Clear();$script:Controls=@{}}
function SetupCardHeader($p,$title,$description,$icon,$Hint=''){AddC $p (T $title)}
# 0.22.0 B4/B5: the detail page attaches its explanations through these two.
function HintIcon($text,$id=''){$b=New-Object Windows.Controls.Button;$b.Content='i';$b.Tag=[pscustomobject]@{TCHint=$text};if($id){$script:Controls[$id]=$b};return $b}
function TitleWithHint($title,$hint,$size=18){return (T $title $size)}
function Note($text,$tone='blue'){return T $text}
function SectionLabel($p,$text,$hint){AddC $p (T $text)}
function KeyValue($p,$key,$value){AddC $p (T ($key+':'+$value))}
function StatusLine($tone,$text){return T $text}
function Toast($text){$script:LastToast=[string]$text}
function ErrorDialog($message){$script:Dialog=@{Title='error';Body=$message}}
function OpenDialog($title,$body,$note,$confirm='确定',$action=$null,$cancel='取消',$style='Primary'){$script:Dialog=@{Title=$title;Body=$body;Note=$note;Action=$action}}
function StartJob($request,$complete,$message='',$transition='',[switch]$Silent,$failed=$null){$script:Requests.Add([pscustomobject]@{Request=$request.Clone();Complete=$complete})}
function IsRunning {return $true}
function ActiveNodeId {return '11111111-1111-1111-1111-111111111111'}
function IsBusy {return $false}
function FetchNodes {}
function ShowNodes {}
function BeginProductDeployment {}
function CopyText {param([string]$Text,[string]$Message='')$script:Copied=[string]$Text}
function B {param([string]$Hex)return $null}
function SyncTCWebState {param([switch]$Force)return}
function Write-TCPerfTrace {param([string]$Mark)return}
function Click($id){Check ($null -ne $script:Controls[$id]) ('control '+$id);$script:Controls[$id].RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))}
function Complete($data){$last=$script:Requests[$script:Requests.Count-1];& $last.Complete $data}
function Last {return $script:Requests[$script:Requests.Count-1].Request}
function Get-Texts {param($Node)
 $out=New-Object 'Collections.Generic.List[string]'
 if($null -eq $Node){return $out}
 if($Node -is [Windows.Controls.TextBlock]){$out.Add([string]$Node.Text);return $out}
 foreach($property in @('Children','Content','Child','Items')){
  if(-not $Node.PSObject.Properties[$property]){continue}
  $value=$Node.PSObject.Properties[$property].Value
  if($null -eq $value){continue}
  foreach($child in @($value)){foreach($entry in @(Get-Texts $child)){$out.Add([string]$entry)}}
 }
 return $out}

# ---- the real pages ------------------------------------------------------------
# WebField lives in ui/WebShell.ps1, which builds the real window; the page modules
# only use it to read one property, so the same three-line reader stands in for it.
function WebField {param($Value,[string]$Name,$Default=$null)
 if($Value -is [Collections.IDictionary]){if($Value.Contains($Name)){return $Value[$Name]}}
 elseif($null -ne $Value -and $Value.PSObject.Properties[$Name]){return $Value.$Name};return $Default}
. (Join-Path $script:PackageRoot 'ui\ServerPages.ps1')
. (Join-Path $script:PackageRoot 'ui\DeploymentPages.ps1')
. (Join-Path $script:PackageRoot 'ui\PairingPages.ps1')
. (Join-Path $script:PackageRoot 'ui\OnlinePairingPages.ps1')
. (Join-Path $script:PackageRoot 'ui\WebInvite.ps1')

# ---- boundaries that only exist in the running application ---------------------
# Declared after the pages load so they win over the real navigation helpers.
# 0.22.1 B4: the record read is skipped, but the navigation result it produces
# is reproduced, so the Offline phase is still proven to land on the sub-view.
function OpenServerRecordManagement {param([string]$ServerId,[string]$ReturnKind='Context',[string]$OfflineOrigin='')
 $script:OpenedRecord=[string]$ServerId;$script:OpenedOfflineOrigin=[string]$OfflineOrigin
 if($OfflineOrigin){
  InitializeServerNavigationUI
  $script:ServerNavigationUI.OfflineOrigin=$OfflineOrigin
  $script:ServerNavigationUI.SelectedServerId=[string]$ServerId
  ShowServerOfflineInviteUI
 }
}
function ShowProductPairing {param([string]$Role)}

# ---- the device label is the only answer to 「名称」 (A6 / A-13) ----------------
$label=GetTCInviteDeviceLabel
Check ($label -cmatch '^邀请 \d{2}-\d{2} \d{2}:\d{2}$') 'A-13 the device label is 邀请 MM-dd HH:mm'
Check ($label.Length -le 64) 'A-13 the label stays inside the strictest limit (64)'
Check ($label.Trim() -ceq $label -and $label -notmatch '[\x00-\x1f\x7f]') 'A-13 the label satisfies the deployment host validation'

# ---- render the real server detail page ----------------------------------------
$server=[pscustomobject]@{LocalRecordId='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';Name='隔离服务器';Connection=[pscustomobject]@{Host='1.1.1.1';Port=22;User='root'};RemoteOwnerId='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';NodeId='cccccccc-cccc-cccc-cccc-cccccccccccc';ServerPublicKey=('A'*43+'=');PinnedHostKey=$null;OwnershipState='Applied';LinkedNodeIds=@();ManagementSigningPublicKey=@{kty='RSA';n='fixture';e='AQAB'}}
$script:DeployUI=@{Run=$null;Management=$null;Discovery=[pscustomobject]@{ManagementServers=@($server);Servers=@($server);ContinueRuns=@()};PendingManagement=$null;DeviceResult=$null;Invite=$null;PairRequest=$null;EnrollmentId=$null}
ShowServerManagement
Click ('ServerSelect'+($server.LocalRecordId-replace '-',''))
Click ServerLogin
Click ServerLoginPassword
Click ServerConnect
Complete ([pscustomobject]@{SessionRef=[pscustomobject]@{RunId='dddddddd-dddd-dddd-dddd-dddddddddddd'}})
$info=[pscustomobject]@{RemoteOwnerId=$server.RemoteOwnerId;Node=[pscustomobject]@{NodeId=$server.NodeId;ServerPublicKey=$server.ServerPublicKey};ManagementApiVersion=2;ManagementSigningPublicKey=$server.ManagementSigningPublicKey;ConfigRevision=3}
Complete $info
$devices=[pscustomobject]@{Devices=@();Total=0;NextOffset=$null;ActiveDeviceCount=0;RevokedDeviceCount=0;ConfigRevision=3}
Complete $devices

# 1. The section link itself; 0.22.1 B4 makes this navigation into a real
#    sub-view instead of an Expander that pretends to be one.
Check ($null -ne $script:Controls['ServerOfflineInvite']) 'the 设备与邀请 section keeps a link to the offline invitation'
Check ([string]$script:Controls['ServerOfflineInvite'].Content -ceq '新电脑连不上 18443？使用离线邀请（24 小时）') 'the link reads 新电脑连不上 18443？使用离线邀请（24 小时）'
Check ([string]$script:ServerNavigationUI.View -ceq 'server-detail') 'the offline sub-view stays closed until it is asked for'
Click ServerOfflineInvite
Check ([string]$script:ServerNavigationUI.View -ceq 'server-offline') 'the link opens the dedicated offline sub-view'
Check ([string]$script:ServerNavigationUI.OfflineOrigin -ceq 'ServerDevices') 'the sub-view remembers it was opened from the devices page'
Check ($null -ne $script:Controls['ServerOfflineInviteBack']) 'the sub-view offers its own way back'
$texts=@(Get-Texts $script:HostPanel)
Check (@($texts|Where-Object {$_ -match '^1\. '}).Count -eq 1) 'the sub-view states step 1 directly'
Check (@($texts|Where-Object {$_ -match '^2\. '}).Count -eq 1) 'the sub-view states step 2 directly'

# 2. A6: no name field, and the generated invitation carries the automatic label.
Check ($null -eq $script:Controls['ServerInviteName']) 'A6 the offline section has no name input'
Check (@($texts|Where-Object {$_ -match '新电脑的名称'}).Count -eq 0) 'A6 no offline sentence asks for a name'
Click ServerCreateInvite
Check ((Last).Operation -eq 'invite_create') 'the offline entry creates the 24 hour invitation'
Check ([int](Last).Input.ExpiresInHours -eq 24) 'the offline invitation keeps the 24 hour lifetime'
Check ([string](Last).Input.DeviceName -cmatch '^邀请 \d{2}-\d{2} \d{2}:\d{2}$') 'A-13 the offline invitation uses the automatic label'
Check ([string](Last).Input.DeviceName.Length -le 64) 'A-13 the offered label fits the 64 character limit'

# 3. The invite page footer reaches the same sub-view, opened.
$null=ResetTCWebInvite $server.LocalRecordId
InvokeTCWebInviteMessage ([pscustomobject]@{Type='invite';Phase='Offline';Sequence=1})
Check ([string]$script:OpenedRecord -ceq $server.LocalRecordId) 'the footer opens this invitation'"'"'s server record'
Check ([string]$script:OpenedOfflineOrigin -ceq 'WebInvite') 'the footer asks for the offline sub-view, not the detail page'
Check ([string]$script:ServerNavigationUI.View -ceq 'server-offline') 'the invite page footer opens the offline sub-view'
Check ([string]$script:ServerNavigationUI.OfflineOrigin -ceq 'WebInvite') 'the sub-view keeps the invite page as its return context'
Check ([string]$script:LastToast -ceq '已打开离线邀请（24 小时）子视图。') 'the footer says what it opened'
ShowServerManagement
Check ([string]$script:ServerNavigationUI.View -ceq 'server-offline') 'the opened sub-view survives the next render'

# 4. A-13 second half: the invited computer still registers its own name.
#    The receiving side owns that field; the manager never types it.
$joinSource=[IO.File]::ReadAllText((Join-Path $script:PackageRoot 'ui\OnlinePairingPages.ps1'),[Text.Encoding]::UTF8)
Check ($joinSource -match 'OnlineDeviceName') 'A-13 the joining computer keeps its own name field'
$serverSource=[IO.File]::ReadAllText((Join-Path $script:PackageRoot 'ui\ServerPages.ps1'),[Text.Encoding]::UTF8)
Check ($serverSource -cnotmatch 'ServerInviteName') 'A6 no management surface names the new computer'

[pscustomobject]@{Passed=$true;Checks=$checks.Count;Assertions=$checks.ToArray();WindowShown=$false;NetworkAccess=$false;FilesWritten=0}|ConvertTo-Json -Depth 4
