#requires -Version 5.1
# 0.22.0 T05 B4 (B-07 / B-08 / B-11): the 「服务器与设备」 detail page is split into
# three sections (设备与邀请 / 连接与维护 / 管理资料). This test walks the 7.4 去向表
# and proves every capability of 0.21.7 still exists, in exactly one section, that
# switching sections issues no remote request, and that the page no longer explains
# itself in long paragraphs.
#
# Renders the real ui/ServerPages.ps1 detail page. No window, no worker, no network.
[CmdletBinding()]param([string]$PackageRoot='')
if([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw 'Run with Windows PowerShell -Sta.'}
$ErrorActionPreference='Stop';Add-Type -AssemblyName PresentationFramework
# Section 4 stubs Import-Module to keep the product modules out of this fixture.
# ConvertTo-SecureString lives in Microsoft.PowerShell.Security, so load it first:
# otherwise the suite would only pass on a host that happened to autoload it.
Import-Module Microsoft.PowerShell.Security -ErrorAction SilentlyContinue
if(-not $PackageRoot){$PackageRoot=Split-Path $PSScriptRoot -Parent}
$script:PackageRoot=[IO.Path]::GetFullPath($PackageRoot)
$script:WebReady=$true;$script:WebFailed=$false
function OpenTCWebInviteFromServerPageUI {param([string]$ServerId='')}
$script:Smoke=$true;$script:Root=Join-Path ([IO.Path]::GetTempPath()) ('tc-server-sections-'+[guid]::NewGuid().ToString('N'))
$script:Controls=@{};$script:Requests=New-Object 'Collections.Generic.List[object]';$checks=New-Object 'Collections.Generic.List[string]'
$script:HostPanel=New-Object Windows.Controls.StackPanel;$script:Ink='#141414';$script:Text2='#333333';$script:Text3='#666666';$script:Hair='#E5E5E5';$script:Role='servers';$script:Page='setup'
$script:Overview=[pscustomobject]@{ManifestPath='not-read-in-smoke'};$script:Dialog=$null;$script:WebAck=0
function Check {param([bool]$Condition,[string]$Name)if(-not $Condition){throw ('FAILED: '+$Name)};$checks.Add($Name)}
function Start-Process {throw 'UI regression must not launch processes.'}
function AddC($p,$c){$null=$p.Children.Add($c)}
function T($text,$size=13,$color='black',$weight='Normal'){$c=New-Object Windows.Controls.TextBlock;$c.Text=[string]$text;$c.TextWrapping='Wrap';return $c}
function Card($padding='20'){$c=New-Object Windows.Controls.Border;return $c}
function Stack($orientation='Vertical'){$s=New-Object Windows.Controls.StackPanel;$s.Orientation=$orientation;return $s}
function Grid($columns){$g=New-Object Windows.Controls.Grid;foreach($w in $columns){$c=New-Object Windows.Controls.ColumnDefinition;$c.Width=$w;$null=$g.ColumnDefinitions.Add($c)};return $g}
function Cell($grid,$child,$column=0){[Windows.Controls.Grid]::SetColumn($child,$column);AddC $grid $child}
function Pill($text,$tone='idle'){$b=New-Object Windows.Controls.Border;$b.Child=T $text;return $b}
function Margin($control,$margin){return $control}
function B($hex){return $null}
function ControlName($control,$name){$script:Controls[$name]=$control;return $control}
function Btn($text,$id,$action,$style='Btn'){$b=New-Object Windows.Controls.Button;$b.Content=$text;$b.Add_Click($action);if($id){$script:Controls[$id]=$b};return $b}
function Head($kicker,$title,$description){$script:HostPanel.Children.Clear();$script:Controls=@{}}
function HintIcon($text,$id=''){$b=New-Object Windows.Controls.Button;$b.Content='i';$b.Tag=[pscustomobject]@{TCHint=$text};if($id){$script:Controls[$id]=$b};return $b}
function TitleWithHint($title,$hint,$size=18){$row=Stack 'Horizontal';AddC $row (T $title $size);if($hint){AddC $row (HintIcon $hint)};return $row}
function SetupCardHeader($p,$title,$description,$icon,$Hint=''){AddC $p (TitleWithHint $title $Hint 20)}
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
function WebField {param($Value,[string]$Name,$Default=$null)
 if($Value -is [Collections.IDictionary]){if($Value.Contains($Name)){return $Value[$Name]}}
 elseif($null -ne $Value -and $Value.PSObject.Properties[$Name]){return $Value.$Name};return $Default}
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
. (Join-Path $script:PackageRoot 'ui\ServerPages.ps1')
. (Join-Path $script:PackageRoot 'ui\DeploymentPages.ps1')
. (Join-Path $script:PackageRoot 'ui\PairingPages.ps1')
. (Join-Path $script:PackageRoot 'ui\OnlinePairingPages.ps1')
function ShowProductPairing {param([string]$Role)}
function OpenServerRecordManagement {param([string]$ServerId,[string]$ReturnKind='Context')}

$server=[pscustomobject]@{LocalRecordId='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';Name='分区服务器';Connection=[pscustomobject]@{Host='1.1.1.1';Port=22;User='root'};RemoteOwnerId='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';NodeId='cccccccc-cccc-cccc-cccc-cccccccccccc';ServerPublicKey=('A'*43+'=');PinnedHostKey=('SHA256:'+('B'*43)+'=');OwnershipState='Applied';LastCheckedUtc='2026-10-23T02:00:00Z';LinkedNodeIds=@();ManagementSigningPublicKey=@{kty='RSA';n='fixture';e='AQAB'};CredentialRef='fixture-ref';SavedLoginRef='dddddddd-dddd-dddd-dddd-dddddddddddd'}
$script:DeployUI=@{Run=$null;Management=$null;Discovery=[pscustomobject]@{ManagementServers=@($server);Servers=@($server);ContinueRuns=@()};PendingManagement=$null;DeviceResult=$null;Invite=$null;PairRequest=$null;EnrollmentId=$null}

# ---- 1. unauthenticated: one login entry, no credential form, no sections -------
ShowServerManagement
Click ('ServerSelect'+($server.LocalRecordId-replace '-',''))
$m=$script:DeployUI.Management
Check ($null -ne $script:Controls['ServerLogin'] -and $script:Controls['ServerLogin'] -is [Windows.Controls.Button]) 'N1 a logged-out detail carries one 登录 button'
Check ($null -eq $script:Controls['ServerPassword'] -and $null -eq $script:Controls['ServerKeyPath'] -and $null -eq $script:Controls['ServerUseSavedCredential']) 'N1 no credential input is rendered before a method is chosen'
Check ($null -eq $script:Controls['ServerTabdevices'] -and $null -eq $script:Controls['ServerTabmaintenance'] -and $null -eq $script:Controls['ServerTabrecords']) 'N2 the logged-out detail publishes no section tabs'
Check ($null -eq $script:Controls['ServerCreateInvite'] -and $null -eq $script:Controls['ServerRecover'] -and $null -eq $script:Controls['ServerRecovery']) 'a logged-out detail exposes no remote capability'
# N3: the entry opens the method step; nothing is typed yet.
Click ServerLogin
Check ([string]$m.LoginStage -ceq 'Method' -and $null -ne $script:Controls['ServerLoginPassword'] -and $null -ne $script:Controls['ServerLoginKey']) 'N3 登录 opens the method step with the password and key choices'
Check ($null -ne $script:Controls['ServerLoginSaved']) 'N3 a saved credential is offered when the record carries one'
# N4: password asks for the password only.
Click ServerLoginPassword
Check ([string]$m.LoginStage -ceq 'Credential' -and [string]$m.LoginMethod -ceq 'Password' -and $null -ne $script:Controls['ServerPassword'] -and $null -eq $script:Controls['ServerKeyPath']) 'N4 the password step asks for the password alone'
# N6: 上一步 returns to the method step and keeps the choice.
Click ServerLoginPrev
Check ([string]$m.LoginStage -ceq 'Method' -and [string]$m.LoginMethod -ceq 'Password') 'N6 上一步 returns to the method step and keeps the choice'
# N5: key asks for the file, the picker and the passphrase.
Click ServerLoginKey
Check ([string]$m.LoginStage -ceq 'Credential' -and $null -ne $script:Controls['ServerKeyPath'] -and $null -ne $script:Controls['ServerKeyPick'] -and $null -ne $script:Controls['ServerPassword']) 'N5 the key step asks for the file, the picker and the passphrase'
Click ServerLoginPrev
Check ([string]$m.LoginStage -ceq 'Method' -and [string]$m.LoginMethod -ceq 'Key') 'N6 上一步 keeps the method that was chosen'
Click ServerLoginBack
Check ([string]$m.LoginStage -ceq '' -and $null -ne $script:Controls['ServerLogin'] -and $null -eq $script:Controls['ServerLoginPassword']) '取消 closes the card and restores the single entry'
# N7: neither the detail page nor the binding problem page offers a list refresh.
Check ($null -eq $script:Controls['ServerAllRecords'] -and $null -eq $script:Controls['ServersRefresh']) 'N7 the detail page has no 所有服务器 and no 刷新服务器列表'
$script:ServerNavigationUI.DetailKind='Binding';$script:ServerNavigationUI.View='server-detail';$script:ServerNavigationUI.LineId='line-fixture';$script:ServerNavigationUI.Line=[pscustomobject]@{Name='原线路（夹具）'};$script:ServerNavigationUI.Loading=$true;$script:ServerNavigationUI.Message=''
ShowServerManagement
Check ($null -eq $script:Controls['ServerAllRecords'] -and $null -eq $script:Controls['ServersRefresh']) 'N7 the binding problem page has no 所有服务器 and no 刷新服务器列表'
$script:ServerNavigationUI.DetailKind='Managed';$script:ServerNavigationUI.Loading=$false;ShowServerManagement
function Get-HintTexts {param($Node)
 $out=New-Object 'Collections.Generic.List[string]'
 if($null -eq $Node){return $out}
 if($Node -is [Windows.FrameworkElement] -and $Node.Tag -and $Node.Tag.PSObject.Properties['TCHint']){$out.Add([string]$Node.Tag.TCHint)}
 foreach($property in @('Children','Content','Child','Items')){
  if(-not $Node.PSObject.Properties[$property]){continue}
  $value=$Node.PSObject.Properties[$property].Value
  if($null -eq $value){continue}
  foreach($child in @($value)){foreach($entry in @(Get-HintTexts $child)){$out.Add([string]$entry)}}
 }
 return $out}
$headerHints=@(Get-HintTexts $script:HostPanel)
Check (@($headerHints|Where-Object {$_ -match '管理入口'}).Count -eq 1) 'the summary hint carries the management entry and last check time'
# 0.22.3: the page no longer opens with a card that repeats the tab name and the
# deployment state. These four guard the de-duplication itself.
$headerTexts=@(Get-Texts $script:HostPanel)
Check (@($headerTexts|Where-Object {$_ -ceq '设备与邀请'}).Count -eq 0) 'the tab name is not repeated as a card title'
Check (@($headerTexts|Where-Object {$_ -match '已授权设备'}).Count -eq 0) 'the second device heading is gone'
Check (@($headerTexts|Where-Object {$_ -match '服务器状态：'}).Count -eq 0) 'the deployment state is not repeated above the tabs'
Check (@($headerTexts|Where-Object {$_ -match '个本机线路关联'}).Count -eq 0) 'the registry count is gone'

# ---- 2. authenticated: the three sections, walked in order ---------------------
Click ServerLogin
Click ServerLoginPassword
Click ServerConnect
Complete ([pscustomobject]@{SessionRef=[pscustomobject]@{RunId='dddddddd-dddd-dddd-dddd-dddddddddddd'}})
$info=[pscustomobject]@{RemoteOwnerId=$server.RemoteOwnerId;Node=[pscustomobject]@{NodeId=$server.NodeId;ServerPublicKey=$server.ServerPublicKey};ManagementApiVersion=2;ManagementSigningPublicKey=$server.ManagementSigningPublicKey;ConfigRevision=3}
Complete $info
Complete ([pscustomobject]@{Devices=@();Total=0;NextOffset=$null;ActiveDeviceCount=0;RevokedDeviceCount=0;ConfigRevision=3})

ShowServerManagement
# N8: the completed login drops the entry, the method and the tabs' absence.
Check ($null -eq $script:Controls['ServerLogin'] -and [string]$m.LoginStage -ceq '' -and [string]$m.LoginMethod -ceq '') 'N8 a completed login drops the entry and the chosen method'
$devTexts=@(Get-Texts $script:HostPanel)
Check (@($devTexts|Where-Object {$_ -ceq '授权时间'}).Count -eq 1) 'the device table exposes 授权时间'
Check (@($devTexts|Where-Object {$_ -ceq '操作'}).Count -eq 1) 'the device table exposes 操作'
Check (@($devTexts|Where-Object {$_ -match '还没有其他电脑加入'}).Count -eq 1) 'the empty device list says so in place'
Check (@($devTexts|Where-Object {$_ -match '用邀请码添加新电脑'}).Count -eq 0) 'the invite flow paragraph is not in the body'
Check ($null -ne $script:Controls['ServerTabdevices'] -and $null -ne $script:Controls['ServerTabmaintenance'] -and $null -ne $script:Controls['ServerTabrecords']) 'three sections are published as tabs'
Check ((GetServerDetailTabUI) -ceq 'devices') '设备与邀请 is the default section'
$tabBar=$null
foreach($child in $script:HostPanel.Children){foreach($entry in @(Get-Texts $child)){}}
Check ($null -ne $script:Controls['ServerTabdevices'].Parent -and [string]$script:Controls['ServerTabdevices'].Parent.Tag -ceq 'TCTabs') 'the tab strip carries Tag=TCTabs for the web tablist'

# 设备与邀请
Check ($null -ne $script:Controls['ServerDevices']) '设备与邀请 owns the device refresh'
Check ($null -ne $script:Controls['ServerOfflineInvite']) '设备与邀请 owns the offline handoff link'
Check ($null -eq $script:Controls['ServerCreateInvite'] -and $null -eq $script:Controls['ServerPairAuthorize']) 'B4 the invitation actions live in their own sub-view, not inside the section'
Check ($null -eq $script:Controls['ServerRecover'] -and $null -eq $script:Controls['ServerRecovery']) 'the other two sections are not rendered at the same time'
$before=$script:Requests.Count
Click ServerTabmaintenance
Check ($script:Requests.Count -eq $before) 'B-11 switching a section issues no remote request'
Check ($null -ne $script:Controls['ServerRecover']) '连接与维护 owns check-and-recover'
Check ($null -ne $script:Controls['ServerTcpPreview'] -and $null -ne $script:Controls['ServerTcpPort'] -and $null -ne $script:Controls['ServerTcpName']) '连接与维护 owns the incremental TCP transport'
Check ($null -ne $script:Controls['ServerReinstall']) '连接与维护 owns identity re-verification'
Check ($null -eq $script:Controls['ServerCreateInvite'] -and $null -eq $script:Controls['ServerRecovery']) 'switching hides the previous section'
$before=$script:Requests.Count
Click ServerTabrecords
Check ($script:Requests.Count -eq $before) 'B-11 switching to 管理资料 issues no remote request'
Check ($null -ne $script:Controls['ServerRecovery']) '管理资料 owns the recovery-data export/import'
Check ($null -ne $script:Controls['ServerUninstallPreview']) '管理资料 owns the uninstall preview'
Check ($null -eq $script:Controls['ServerRecover']) 'the maintenance section is gone while 管理资料 is open'
Click ServerTabdevices
Check ($null -ne $script:Controls['ServerDevices'] -and $null -ne $script:Controls['ServerOfflineInvite']) 'returning to 设备与邀请 restores it'
# ---- 2b. B4: the offline invitation is a sub-view, reached from this section ----
$before=$script:Requests.Count
Click ServerOfflineInvite
Check ($script:Requests.Count -eq $before) 'B4 opening the offline sub-view issues no remote request'
Check ($null -ne $script:Controls['ServerCreateInvite'] -and $null -ne $script:Controls['ServerPairAuthorize']) 'B4 the sub-view owns generate and approve'
Check ($null -ne $script:Controls['ServerOfflineInviteBack']) 'B4 the sub-view offers its own way back'
Click ServerOfflineInviteBack
Check ($null -ne $script:Controls['ServerOfflineInvite'] -and $null -eq $script:Controls['ServerCreateInvite']) 'B4 the return button restores the devices section'

# ---- 3. B-08: the page stopped explaining itself in paragraphs ------------------
$texts=@(Get-Texts $script:HostPanel)|Where-Object {$_}
$paragraphs=@($texts|Where-Object { $_.Length -ge 16 -and $_ -notmatch '^[12]\. ' -and $_ -notmatch '^(邀请：|请与新电脑确认|已登记 \d+ 个本机线路关联|服务器状态：|设备身份：|授权时间：|到期 |剩余 )' })
Check ($paragraphs.Count -le 4) ('B-08 direct explanation paragraphs on the page: '+$paragraphs.Count+' -> '+($paragraphs -join ' | '))

# ---- 4. only the login card may answer from the model --------------------------
# QA found this gate uncovered. LoginMethod is a model field that survives every
# page change, so a leftover 'Password'/'Key' used to shadow the credential the
# operator had just typed into a page that renders its own form (自动 TCP / 配对).
function Import-Module {param($Name,[switch]$DisableNameChecking)return}
function Get-TCServer {param($Root,$Id)return $script:DeployUI.Management.Server}
function ConnectServerWithCredentialUI {param($Credential)$script:CapturedCredential=$Credential}
function Get-ServerLoginSecretText {param($Credential)
 $secret=$null
 if($Credential -is [Collections.IDictionary]){$secret=$Credential['Password']}elseif($Credential.Password){$secret=$Credential.Password}
 if(-not $secret){return ''}
 $pointer=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($secret)
 try{return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)}finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)}
}
$script:Smoke=$false
$m=$script:DeployUI.Management
$m.ServerId=[string]$server.LocalRecordId;$m.Server=$server;$m.Authenticated=$false;$m.ReinstallStage=$null;$m.UseSavedCredential=$false
$m.LoginMethod='Password';$m.LoginStage='';$m.LoginSecret=(ConvertTo-SecureString 'STALE-from-another-page' -AsPlainText -Force)
$script:Controls=@{ServerPassword=@{SecurePassword=(ConvertTo-SecureString 'FRESH-typed-here' -AsPlainText -Force)};ServerKeyPath=@{Text=''}}
$script:CapturedCredential=$null
ConnectServerUI
Check ((Get-ServerLoginSecretText $script:CapturedCredential) -ceq 'FRESH-typed-here') 'a LoginMethod left over from another page cannot shadow the credential typed on this page'
$m.LoginMethod='Password';$m.LoginStage='Credential';$m.LoginSecret=(ConvertTo-SecureString 'MODEL-from-login-card' -AsPlainText -Force)
$script:CapturedCredential=$null
ConnectServerUI
Check ((Get-ServerLoginSecretText $script:CapturedCredential) -ceq 'MODEL-from-login-card') 'the login card credential step is still answered from the model'
$script:Smoke=$true

# 0.23.0: the saved-login choice is driven by plaintext metadata, and the delete
# entry lives on the same card. A read-only window must refuse before dispatching.
$script:Smoke=$true
$m=$script:DeployUI.Management
$m.LoginStage='Method';$m.LoginMethod='';$m.SavedLoginInfo=[pscustomobject]@{Status='Missing';CredentialKind='';SavedAtUtc=$null;KeyPathHint=$null;BindingDigest=$null}
ShowServerManagement
Check ($null -eq $script:Controls['ServerLoginSaved']) 'N3 a Missing saved login is not offered'
# A dangling pointer is exactly what the operator must be able to clear, so the
# delete entry stays; only the login offer is withdrawn.
Check ($null -ne $script:Controls['ServerLoginForget']) 'a Missing saved login can still be cleared from the card'
$m.LoginStage='Method';$m.SavedLoginInfo=[pscustomobject]@{Status='Available';CredentialKind='Password';SavedAtUtc='2026-10-25T00:00:00.0000000Z';KeyPathHint=$null;BindingDigest=('0'*64)}
ShowServerManagement
Check ($null -ne $script:Controls['ServerLoginSaved']) 'N3 an Available saved login is offered'
Check ([object]::ReferenceEquals($script:Controls['ServerLoginSaved'].Parent.Children[0],$script:Controls['ServerLoginSaved'])) 'the saved login is the first choice offered'
Check ($null -ne $script:Controls['ServerLoginForget']) 'an Available saved login can be deleted from the same card'
$script:ReadOnly=$true;$script:Dialog=$null
Click ServerLoginForget
Check ($null -ne $script:Dialog -and [string]$script:Dialog.Body -match '\u53ea\u8bfb') 'a read-only window refuses to delete the saved login'
$script:ReadOnly=$false
[pscustomobject]@{Passed=$true;Checks=$checks.Count;Assertions=$checks.ToArray();DirectParagraphs=$paragraphs.Count;WindowShown=$false;NetworkAccess=$false;FilesWritten=0}|ConvertTo-Json -Depth 4
