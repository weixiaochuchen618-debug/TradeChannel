#requires -Version 5.1
# 0.22.0 A1 on the WPF surface: the invitation card must offer the lifetime
# presets, show the compatibility warning directly, block an unusable custom
# value, and recover from OnlineMaintenanceDeferred with 「取消并重试」.
#
# Loads the real ui/ServerPages.ps1, ui/DeploymentPages.ps1 and
# ui/OnlinePairingPages.ps1. Only the window primitives and the side effects
# (worker dispatch, toast, clipboard, dialogs) are replaced. No window is shown,
# no server is contacted and no file is written.
[CmdletBinding()]param([string]$PackageRoot='')
$ErrorActionPreference='Stop'
if(-not $PackageRoot){$PackageRoot=Split-Path $PSScriptRoot -Parent}
$script:PackageRoot=[IO.Path]::GetFullPath($PackageRoot)
$checks=New-Object 'Collections.Generic.List[string]'
function Check {param([bool]$Condition,[string]$Name)if(-not $Condition){throw ('FAILED: '+$Name)};$checks.Add($Name)}
if(-not ('Windows.Controls.StackPanel' -as [type])){Add-Type -AssemblyName PresentationFramework}

# ---- window primitives, as TradeChannel.ps1 defines them ----------------------
$script:Ink='#111827';$script:Text2='#4B5360';$script:Text3='#6B7280';$script:Hair='#E5E7EB'
$script:Tone=@{ok=@{Fg='#15803D';Bg='#ECF8F0';Dot='#22A55B'};warn=@{Fg='#A15C07';Bg='#FDF5E8';Dot='#E19A1D'};bad=@{Fg='#B42318';Bg='#FEF1F0';Dot='#E5484D'};info=@{Fg='#1D4ED8';Bg='#EEF3FE';Dot='#3B6FF6'};idle=@{Fg='#4B5360';Bg='#F2F3F5';Dot='#A9AFB8'}}
$script:Controls=@{}
$script:Window=New-Object psobject
$script:Window|Add-Member -MemberType ScriptMethod -Name FindResource -Value {param([string]$Name)return $null}
function B {param([string]$Hex)$c=New-Object Windows.Media.BrushConverter;return $c.ConvertFromString($Hex)}
function AddC {param($Parent,$Child)$null=$Parent.Children.Add($Child)}
function T {param([string]$Text,[double]$Size=13,[string]$Color=$script:Ink,[string]$Weight='Normal')
 $t=New-Object Windows.Controls.TextBlock;$t.Text=$Text;$t.FontSize=$Size;$t.Foreground=B $Color;$t.TextWrapping='Wrap';$t.FontWeight=$Weight
 $t.LineHeight=[Math]::Round($Size*1.55);return $t}
function Stack {param([string]$Orientation='Vertical')$s=New-Object Windows.Controls.StackPanel;$s.Orientation=$Orientation;return $s}
function Card {param([string]$Padding='22,20')
 $b=New-Object Windows.Controls.Border;$b.Background=B '#FFFFFF';$b.BorderBrush=B $script:Hair;$b.BorderThickness='1';$b.CornerRadius='14';$b.Padding=[Windows.Thickness]$Padding;return $b}
function Margin {param($Element,[string]$Value)$Element.Margin=[Windows.Thickness]$Value;return $Element}
function ControlName {param($Control,[string]$Id)$Control.Name=$Id;[Windows.Automation.AutomationProperties]::SetAutomationId($Control,$Id);$script:Controls[$Id]=$Control;return $Control}
function Btn {param([string]$Text,[string]$Id,[scriptblock]$Click,[string]$Style='Btn')
 $b=New-Object Windows.Controls.Button;$b.Content=$Text;$b.Style=$script:Window.FindResource($Style);$b.Add_Click($Click);if($Id){$b=ControlName $b $Id};return $b}

# ---- load the real pages -----------------------------------------------------
. (Join-Path $script:PackageRoot 'ui\ServerPages.ps1')
. (Join-Path $script:PackageRoot 'ui\DeploymentPages.ps1')
. (Join-Path $script:PackageRoot 'ui\OnlinePairingPages.ps1')
InitializeServerUI

# ---- side effects ------------------------------------------------------------
$script:ServerOperations=New-Object 'Collections.Generic.List[object]'
$script:Toasts=New-Object 'Collections.Generic.List[string]'
$script:Renders=0
$script:ReadOnly=$false
function StartServerOperation {param([string]$Operation,$InputData,$Purpose)
 $script:ServerOperations.Add([pscustomobject]@{Operation=$Operation;InputData=$InputData;Purpose=$Purpose})}
# The 18443 self-check runs through the shared in-memory command runner.
$script:UiCommands=New-Object 'Collections.Generic.List[object]'
function StartUiCommand {param([string]$Module,[string]$Command,[hashtable]$Arguments,[scriptblock]$Complete,[scriptblock]$Failed,$Context,[string]$Message='')
 $script:UiCommands.Add([pscustomobject]@{Module=$Module;Command=$Command;Arguments=$Arguments;Complete=$Complete;Failed=$Failed;Context=$Context;Message=$Message})}
function ShowServerManagement {$script:Renders=$script:Renders+1}
function ShowServerDetailUI {$script:Renders=$script:Renders+1}
function Toast {param([string]$Text)$script:Toasts.Add([string]$Text)}
function CopyText {param([string]$Text,[string]$Message='')}
function ErrorDialog {param([string]$Text)$script:LastError=$Text}
function IsBusy {return $false}
# The management signing identity comes from the live server; its fingerprint
# computation is not part of this card.
function GetOnlineInviteFingerprintUI {return 'SHA256:'+('A'*43)}

function Get-Card {
    $parent=Stack
    $null=AddOnlineInviteCardUI $parent
    return [pscustomobject]@{Parent=$parent;Controls=$script:Controls}
}
function Clear-Controls {$script:Controls=@{}}
function Reset-UiCommands {$script:UiCommands.Clear()}
function Get-CardTexts {param($Node)
    # Every visible sentence on the card, so copy can be asserted without giving
    # each TextBlock an automation name it does not need in production.
    $out=New-Object 'Collections.Generic.List[string]'
    if($null -eq $Node){return $out}
    if($Node -is [Windows.Controls.TextBlock]){$out.Add([string]$Node.Text);return $out}
    $children=@()
    if($Node.PSObject.Properties['Children']){$children=@($Node.Children)}
    foreach($child in $children){foreach($entry in @(Get-CardTexts $child)){$out.Add([string]$entry)}}
    return $out
}
function Select-Lifetime {param([int]$Seconds)
    # As the ComboBox selection handler does: store the preset and re-render.
    $item=$null
    foreach($entry in $script:Controls.OnlineInviteLifetime.Items){if([int]$entry.Tag -eq $Seconds){$item=$entry}}
    $script:Controls.OnlineInviteLifetime.SelectedItem=$item
}
function Reset-Invite {param([int]$Seconds=1800,[bool]$Custom=$false,[string]$Amount='',[string]$Unit='Minutes')
    $script:DeployUI.Management.Input.InviteLifetimeSeconds=$Seconds
    $script:DeployUI.Management.Input.InviteLifetimeCustom=$Custom
    $script:DeployUI.Management.Input.InviteLifetimeAmount=$Amount
    $script:DeployUI.Management.Input.InviteLifetimeUnit=$Unit
    $script:DeployUI.Management.OnlineInvite=$null
    $script:DeployUI.Management.OnlineInviteLastInput=$null
    $script:DeployUI.Management.OnlineInviteRetry=$null
    $script:DeployUI.Management.ErrorCode=''
    $script:DeployUI.Management.Error=''
    $script:ServerOperations.Clear()
    Clear-Controls
}
# 1. Default: four presets plus a custom entry, 30 minutes selected, no warning.
Reset-Invite
$card=Get-Card
$combo=$script:Controls.OnlineInviteLifetime
Check ($combo.Items.Count -eq 5) 'the lifetime selector offers four presets and a custom entry'
$labels=@($combo.Items|ForEach-Object {[string]$_.Content})
Check (($labels[0..3] -join '|') -eq '10 分钟|30 分钟（默认）|2 小时|24 小时') 'the presets read ten minutes, thirty minutes, two hours and twenty four hours'
Check ([int]$combo.Items[0].Tag -eq 600 -and [int]$combo.Items[1].Tag -eq 1800 -and [int]$combo.Items[2].Tag -eq 7200 -and [int]$combo.Items[3].Tag -eq 86400) 'each preset carries its seconds'
Check ([string]$combo.SelectedItem.Content -eq '30 分钟（默认）') 'an untouched card selects thirty minutes'
Check ($script:Controls.OnlineInviteLifetimeCompat.Visibility -eq 'Collapsed') 'thirty minutes shows no compatibility warning'
Check ([string]$script:Controls.OnlineInviteCreate.Content -eq '生成邀请码（30 分钟）') 'the button states the lifetime it will ask for'
Check ([string]$combo.ToolTip -like '*18443*') 'the security trade-off is available as hover text'

# 2. Selecting 24 hours shows the compatibility warning directly.
Reset-Invite
$card=Get-Card
Select-Lifetime 86400
$card=Get-Card
Check ($script:DeployUI.Management.Input.InviteLifetimeSeconds -eq 86400 -and -not $script:DeployUI.Management.Input.InviteLifetimeCustom) 'a preset selection is stored as seconds'
Check ($script:Controls.OnlineInviteLifetimeCompat.Visibility -eq 'Visible') 'a lifetime above thirty minutes shows the warning'
Check ([string]$script:Controls.OnlineInviteLifetimeCompat.Text -eq '超过 30 分钟的邀请码，新电脑需要 0.22.0 或更高版本；旧版本会提示有效期超过上限。') 'the warning is the agreed sentence'
Check ([string]$script:Controls.OnlineInviteCreate.Content -eq '生成邀请码（24 小时）') 'the button follows the selected lifetime'
Check ($script:Controls.OnlineInviteLifetimeHint.Visibility -eq 'Collapsed') 'a valid preset shows no input error'

# 3. Custom entry: number plus unit, with an integer range check.
Reset-Invite -Custom $true -Amount '45' -Unit 'Minutes'
$card=Get-Card
Check ($null -ne $script:Controls.OnlineInviteLifetimeAmount -and $null -ne $script:Controls.OnlineInviteLifetimeUnit) 'selecting custom reveals the number and unit controls'
Check ([string]$script:Controls.OnlineInviteCreate.Content -eq '生成邀请码（45 分钟）') 'a custom 45 minutes is sent as 45 minutes'
Check ($script:Controls.OnlineInviteLifetimeCompat.Visibility -eq 'Visible') 'a custom value above thirty minutes shows the warning'
$script:Controls.OnlineInviteLifetimeAmount.Text='5'
Check ($script:DeployUI.Management.Input.InviteLifetimeAmount -eq '5') 'typing in the custom box updates the stored value'
Check ($script:Controls.OnlineInviteLifetimeHint.Visibility -eq 'Visible') 'an out of range custom value shows an inline error'
Check (-not [bool]$script:Controls.OnlineInviteCreate.IsEnabled) 'an out of range custom value disables generation'
$script:Controls.OnlineInviteLifetimeAmount.Text='90'
Check ([bool]$script:Controls.OnlineInviteCreate.IsEnabled) 'a corrected custom value enables generation again'
Check ([string]$script:Controls.OnlineInviteCreate.Content -eq '生成邀请码（1 小时 30 分钟）') 'the button states the corrected lifetime'
$script:Controls.OnlineInviteLifetimeAmount.Text='abc'
Check (-not [bool]$script:Controls.OnlineInviteCreate.IsEnabled) 'a non numeric entry disables generation'

# 4. OnlineMaintenanceDeferred offers 「取消并重试」 with the stored input.
Reset-Invite -Seconds 86400
$script:DeployUI.Management.ErrorCode='OnlineMaintenanceDeferred'
$script:DeployUI.Management.OnlineInviteLastInput=@{InviteId='5a5a5a5a-1111-4222-8333-444444444444';DeviceName='新电脑';ExpiresInSeconds=86400;PublicHost='1.2.3.4';Port=18443;ExpectedServerBinding=@{};ExpectedManagementFingerprint='SHA256:x'}
$card=Get-Card
Check ($null -ne $script:Controls.OnlineInviteCancelRetry) 'the deferred error offers the recovery button'
Check ([string]$script:Controls.OnlineInviteCancelRetry.Content -eq '取消并重试') 'the recovery button is labelled 取消并重试'
$script:Controls.OnlineInviteCancelRetry.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
Check ($script:ServerOperations.Count -eq 1 -and $script:ServerOperations[0].Operation -eq 'pair_online_create') 'retrying re-runs the same create instead of building a new device'
Check ($script:ServerOperations[0].InputData.InviteId -eq '5a5a5a5a-1111-4222-8333-444444444444') 'the retry reuses the stored input including the InviteId'

# 5. An open invitation is cancelled first, then the same create runs again.
Reset-Invite -Seconds 600
$script:DeployUI.Management.Info=@{RemoteOwnerId='5a5a5a5a-1111-4222-8333-444444444444';Node=@{NodeId='6b6b6b6b-1111-4222-8333-444444444444';ServerPublicKey=('A'*43)};ManagementSigningPublicKey=@{kty='RSA';n='x';e='AQAB'}}
$script:DeployUI.Management.ErrorCode='OnlineMaintenanceDeferred'
$script:DeployUI.Management.OnlineInvite=[pscustomobject]@{InviteId='7c7c7c7c-1111-4222-8333-444444444444';State='Open';InvitationCode='TCI1.abcdefghijklmnopqrstuvwxyz';ExpiresAtUtc=[DateTimeOffset]::UtcNow.AddMinutes(25).ToString('o');Port=18443}
$script:DeployUI.Management.OnlineInviteLastInput=@{InviteId='7c7c7c7c-1111-4222-8333-444444444444';DeviceName='新电脑';ExpiresInSeconds=600;PublicHost='1.2.3.4';Port=18443}
$card=Get-Card
$script:Controls.OnlineInviteCancelRetry.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
Check ($script:ServerOperations.Count -eq 1 -and $script:ServerOperations[0].Operation -eq 'pair_online_cancel') 'the blocking invitation is cancelled first'
Check ([bool]$script:DeployUI.Management.OnlineInviteRetryAfterCancel) 'the follow-up create is armed only after a successful cancel'
CompleteOnlineInviteUI ([pscustomobject]@{InviteId='7c7c7c7c-1111-4222-8333-444444444444';State='Cancelled'}) 'Cancel'
Check ($script:ServerOperations.Count -eq 2 -and $script:ServerOperations[1].Operation -eq 'pair_online_create') 'a completed cancel reruns the stored create'
Check (-not [bool]$script:DeployUI.Management.OnlineInviteRetryAfterCancel) 'the follow-up is disarmed once it ran'

# 5b. O-1: the Create toast must state the lifetime the server actually granted,
# not the one the page asked for. A 24 hour grant has to read 24 小时 even when
# the deadline is 86399 seconds away (the formatter rounds to whole minutes
# first). This is the sentence the user sees; it was previously covered only by
# reading the code plus unit tests on the formatter.
$script:Toasts.Clear()
CompleteOnlineInviteUI ([pscustomobject]@{InviteId='8d8d8d8d-1111-4222-8333-444444444444';State='Open';ExpiresAtUtc=[DateTimeOffset]::UtcNow.AddHours(24).ToString('o')}) 'Create'
Check (@($script:Toasts|Where-Object {$_ -match '24 小时'}).Count -eq 1) ('O-1 the create toast states the granted lifetime, got '+(@($script:Toasts) -join ' | '))
Check (@($script:Toasts|Where-Object {$_ -match '只能使用一次'}).Count -eq 1) 'O-1 the create toast still says the code is single use'

# 6. A6: no name input anywhere, and the host labels the device itself.
Reset-Invite -Seconds 1800
$script:DeployUI.Management.Info=@{RemoteOwnerId='5a5a5a5a-1111-4222-8333-444444444444';Node=@{NodeId='6b6b6b6b-1111-4222-8333-444444444444';ServerPublicKey=('A'*43);PublicEndpoint='203.0.113.9:443'};ManagementSigningPublicKey=@{kty='RSA';n='x';e='AQAB'}}
$script:DeployUI.Management.Authenticated=$true;$script:DeployUI.Management.SessionRef=@{InstanceId='s1'}
$card=Get-Card
Check ($null -eq $script:Controls['ServerInviteName']) 'A6 the invitation card has no name input'
$texts=@(Get-CardTexts $card.Parent)
Check (@($texts|Where-Object {$_ -match '邀请 MM-dd HH:mm'}).Count -ge 1) 'A-13 the card states the automatic device label'
Check (@($texts|Where-Object {$_ -match '名称' -and $_ -notmatch '不需要填名称'}).Count -eq 0) 'A-13 no remaining field asks for a name'
# The stored field may even be empty; it is no longer read.
$script:DeployUI.Management.Input.DeviceName=''
StartOnlineInviteUI
$created=@($script:ServerOperations|Where-Object {$_.Operation -ceq 'pair_online_create'})|Select-Object -Last 1
Check ($null -ne $created) 'A6 生成邀请码 works with no name typed'
Check ([string]$created.InputData.DeviceName -cmatch '^邀请 \d{2}-\d{2} \d{2}:\d{2}$') 'A-13 the host fills 邀请 MM-dd HH:mm'
Check ([string]$created.InputData.DeviceName.Length -le 64) 'A-13 the automatic label stays inside the strictest 64 character limit'
Check ([int]$created.InputData.ExpiresInSeconds -eq 1800) 'A8 the button still sends the selected lifetime'

# 7. Status line: deadline plus remaining minutes.
$script:DeployUI.Management.OnlineInvite=[pscustomobject]@{InviteId='7c7c7c7c-1111-4222-8333-444444444444';State='Open';InvitationCode='TCI1.abcdefghijklmnopqrstuvwxyz';ExpiresAtUtc=[DateTimeOffset]::UtcNow.AddMinutes(25).ToString('o');Port=18443;PublicHost='203.0.113.9';TlsSha256=('B'*64)}
$card=Get-Card
$texts=@(Get-CardTexts $card.Parent)
Check (@($texts|Where-Object {$_ -match '到期\s' -and $_ -match '剩余\s\d+\s分钟'}).Count -ge 1) 'A8 the status line shows the deadline and the remaining minutes'

# 8. A8: the 18443 self-check reuses the shared probe and carries no code.
Reset-UiCommands
Check ($null -ne $script:Controls['OnlineInviteReachability'] -and $null -ne $script:Controls['OnlineInviteReopen']) 'A8 the 18443 check and 重新开启接收服务 are both reachable'
$script:Controls.OnlineInviteReachability.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
Check ($script:UiCommands.Count -eq 1 -and $script:UiCommands[0].Command -ceq 'Test-TCPairOnlineReachability' -and $script:UiCommands[0].Module -ceq 'PairingOnline.psm1') 'A8 the check is the shared reachability probe'
Check ([string]$script:UiCommands[0].Arguments.PublicHost -ceq '203.0.113.9' -and [int]$script:UiCommands[0].Arguments.Port -eq 18443) 'A8 the probe targets this invitation end point'
Check ([string]$script:UiCommands[0].Arguments.TlsSha256 -ceq ('B'*64)) 'A8 the probe compares the certificate this invitation pins'
Check (-not $script:UiCommands[0].Arguments.ContainsKey('Token') -and -not $script:UiCommands[0].Arguments.ContainsKey('InvitationCode')) 'A8 the probe sends no token and no code'
Check ([string]$script:UiCommands[0].Context.Type -ceq 'Invite') 'A8 the result is bound to this invitation'
& $script:UiCommands[0].Complete ([pscustomobject]@{Status='Reachable';ElapsedMs=9;CheckedAtUtc=(Get-Date).ToUniversalTime().ToString('o')}) $script:UiCommands[0].Context
Check ([string]$script:DeployUI.Management.OnlineInviteReachability.Status -ceq 'Reachable') 'A8 the probe result is kept for the card'
$card=Get-Card
$texts=@(Get-CardTexts $card.Parent)
Check (@($texts|Where-Object {$_ -eq '已从这台电脑确认 18443 可以连接'}).Count -eq 1) 'A8 the card shows the 18443 result without claiming the new computer can connect'
# A refused port is advisory: the invitation stays usable.
$script:DeployUI.Management.OnlineInviteReachability=@{Status='Refused';CheckedAtUtc=(Get-Date).ToUniversalTime().ToString('o');Port=18443}
$card=Get-Card
$texts=@(Get-CardTexts $card.Parent)
Check (@($texts|Where-Object {$_ -match '18443 连不上（连接被拒绝）'}).Count -eq 1) 'A8 a refused port is explained, not fatal'
Check ([string]$script:DeployUI.Management.OnlineInvite.State -ceq 'Open') 'A8 a refused port never cancels the invitation'

# 9. A-11: 重新开启接收服务 re-runs the same create, so the InviteId survives.
$script:ServerOperations.Clear()
$script:DeployUI.Management.OnlineInviteLastInput=@{InviteId='7c7c7c7c-1111-4222-8333-444444444444';DeviceName='邀请 10-23 13:45';ExpiresInSeconds=1800;PublicHost='203.0.113.9';Port=18443}
$card=Get-Card
$script:Controls.OnlineInviteReopen.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
Check ($script:ServerOperations.Count -eq 1 -and $script:ServerOperations[0].Operation -ceq 'pair_online_create') 'A-11 reopening the receiver reuses the create operation'
Check ([string]$script:ServerOperations[0].InputData.InviteId -ceq '7c7c7c7c-1111-4222-8333-444444444444') 'A-11 the same InviteId is returned, no second device is registered'
# Without a stored input the button explains itself instead of failing silently.
$script:ServerOperations.Clear();$script:Toasts.Clear()
$script:DeployUI.Management.OnlineInviteLastInput=$null
$card=Get-Card
$script:Controls.OnlineInviteReopen.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
Check ($script:ServerOperations.Count -eq 0 -and @($script:Toasts|Where-Object {$_ -match '重新生成邀请码'}).Count -eq 1) 'A-11 without a stored input the page says what to do'

[pscustomobject]@{Passed=$true;CheckCount=$checks.Count;Checks=$checks.ToArray();WindowShown=$false;NetworkAccess=$false;FilesWritten=0}|ConvertTo-Json -Depth 4
