#requires -Version 5.1
$script:OnlinePairUI=$null
function GetOnlinePairErrorCopy {param([string]$Code,[string]$Detail='')
    # 0.20: one table for both surfaces. The native three-step page reads the
    # same rows through GetTCWebPairErrorCopy, so the two can no longer drift.
    if(Get-Command GetTCWebPairErrorCopy -ErrorAction SilentlyContinue){return (GetTCWebPairErrorCopy $Code $Detail)}
    switch($Code){
        'InvalidOnlineInput'{return @{Message='这张邀请码不是本产品生成的，请让给你的人重新生成。';Action='重新输入';NextAction='Reenter'}}
        'InvalidOnlineCode'{return @{Message='邀请码不完整或已损坏，请复制完整的一次性邀请码。';Action='重新输入';NextAction='Reenter'}}
        'InvalidOnlineJson'{return @{Message='邀请码内容无法识别，请重新复制完整的一次性邀请码。';Action='重新输入';NextAction='Reenter'}}
        'InvalidOnlineHost'{return @{Message='邀请码里的服务器地址无效，请让管理员重新生成。';Action='重新输入';NextAction='Reenter'}}
        'OnlineInviteExpired'{return @{Message='邀请码已过期，请让管理电脑重新生成（可以设更长的有效期）。';Action='重新输入';NextAction='Reenter'}}
        'InviteConsumed'{return @{Message='这张邀请码已经被用过了，请在原申请电脑上重试或索取新码。';Action='继续加入';NextAction='Reenter'}}
        'OnlineInviteIdentityMismatch'{return @{Message='邀请码与本机原申请不匹配，请使用同一张邀请码重试。';Action='继续加入';NextAction='Retry'}}
        'PairingBusy'{return @{Message='本机正在完成这个申请，请稍后再试。';Action='重试';NextAction='Retry'}}
    }
    # The old fallback claimed the failure was a network problem. A host sentence
    # is preferred; only then does the neutral fallback appear.
    return @{Message=$(if($Detail -and $Detail.Trim()){$Detail.Trim()}else{'这一步没有完成'});Action='重试';NextAction='Retry'}
}
# ---- Invitation lifetime (0.22.0 A1) -------------------------------------------
# The management computer picks how long the invitation stays valid; the server
# keeps the authoritative bounds (60..86400 seconds). The choice is pure UI
# state: it lives in $script:DeployUI.Management.Input, which never reaches
# ui-preferences.json, is never read by the supervisor and is never part of an
# operation input schema. Only the resulting number is sent, as ExpiresInSeconds.
$script:OnlineInviteLifetimePresets=@(
    @{Label='10 分钟';Seconds=600}
    @{Label='30 分钟（默认）';Seconds=1800}
    @{Label='2 小时';Seconds=7200}
    @{Label='24 小时';Seconds=86400}
)
$script:OnlineInviteLifetimeCustom=0
$script:OnlineInviteLifetimeDefaultSeconds=1800
$script:OnlineInviteLifetimeMinSeconds=600
$script:OnlineInviteLifetimeMaxSeconds=86400
# A receiver older than 0.22.0 refuses a code whose deadline is beyond
# "now + 35 minutes"; 30 minutes is the longest preset that still works there.
$script:OnlineInviteLifetimeCompatLimitSeconds=1800
$script:OnlineInviteLifetimeCompatText='超过 30 分钟的邀请码，新电脑需要 0.22.0 或更高版本；旧版本会提示有效期超过上限。'
$script:OnlineInviteLifetimeRiskText='有效期越长，邀请码被转发或泄露后可用的时间越长。邀请码只能用一次；有效期间服务器会一直开着 18443 接收服务，「取消邀请码」始终可见。'
function GetTCInviteDeviceLabel {
    # 0.22.0 A6: the management computer no longer asks for a name. The device
    # label is generated here, and this is the only place that decides it, so the
    # web page, the WPF card and the offline handoff all register the same shape.
    # Three parties disagree on the limit - this host reads 64, the deployment
    # host truncates at 64 (TradeChannelDeployHost.cs name=Str(args,"DeviceName",64)),
    # the server accepts 80 - so the strictest one (64) is enforced here.
    $label=('邀请 '+(Get-Date).ToString('MM-dd HH:mm',[Globalization.CultureInfo]::InvariantCulture)).Trim()
    if($label.Length -gt 64){$label=$label.Substring(0,64).Trim()}
    return $label
}
function GetOnlineInviteReachabilityTextUI {param($Probe)
    # The same six sentences the web page renders (web/app.js inviteReachability),
    # so the two surfaces cannot describe one probe result differently.
    if(-not $Probe){return ''}
    $port=[int](ServerUIGet $Probe Port 18443);if($port -le 0){$port=18443}
    switch([string](ServerUIGet $Probe Status '')){
        'Checking'{return ('正在检查 '+$port+' 能否连通')}
        'Reachable'{return '已从这台电脑确认 '+[string]$port+' 可以连接'}
        'Refused'{return ([string]$port+' 连不上（连接被拒绝）：请在云服务器防火墙放行 TCP '+$port)}
        'Timeout'{return ([string]$port+' 没有响应：请检查云服务器防火墙是否放行 TCP '+$port)}
        'TlsMismatch'{return ([string]$port+' 的证书与邀请码不一致：端口可能被其他服务占用，或服务与这张邀请码不匹配')}
        'TlsFailed'{return ([string]$port+' 的加密握手没有完成，请稍后重试')}
    }
    return ([string]$port+' 检查没有完成，可以先复制邀请码试试')
}
function Format-OnlineInviteLifetime {param([int]$Seconds)
    # 600 -> "10 分钟", 7200 -> "2 小时", 5400 -> "1 小时 30 分钟".
    # Round to whole minutes first, so a deadline 86399 seconds away still reads
    # "24 小时" instead of "23 小时 60 分钟".
    $minutes=[int][Math]::Round([Math]::Max(60,[int]$Seconds)/60.0)
    if(($minutes % 60) -eq 0){return ([string][int]($minutes/60)+' 小时')}
    if($minutes -lt 60){return ([string]$minutes+' 分钟')}
    return ([string][int][Math]::Floor($minutes/60)+' 小时 '+[string]($minutes % 60)+' 分钟')
}
function ConvertTo-OnlineInviteLifetimeSeconds {param([string]$Amount,[string]$Unit='Minutes')
    # Custom entry is an integer only: 10–1440 minutes or 1–24 hours.
    $hours=($Unit -ceq 'Hours')
    $low=if($hours){1}else{10};$high=if($hours){24}else{1440}
    $hint=if($hours){'请填写 1–24 的整数小时。'}else{'请填写 10–1440 的整数分钟。'}
    $text=([string]$Amount).Trim()
    if($text -cnotmatch '^[0-9]{1,4}$'){return [pscustomobject]@{Seconds=0;Error=$hint}}
    $number=[int]$text
    if($number -lt $low -or $number -gt $high){return [pscustomobject]@{Seconds=0;Error=$hint}}
    return [pscustomobject]@{Seconds=$(if($hours){$number*3600}else{$number*60});Error=''}
}
function GetOnlineInviteLifetimeUI {
    # Single source of truth for the page: what would be sent, and whether it is usable.
    $m=$script:DeployUI.Management;$input=ServerUIGet $m Input
    $custom=[bool](ServerUIGet $input InviteLifetimeCustom $false)
    $seconds=[int](ServerUIGet $input InviteLifetimeSeconds $script:OnlineInviteLifetimeDefaultSeconds)
    if($null -ne $input -and -not [bool](ServerUIGet $input InviteLifetimeInitialized $false)){
        # Preserve a value already chosen in this model; otherwise start from the
        # preference saved by either the WPF card or the web invitation page.
        if(-not $custom -and $seconds -eq $script:OnlineInviteLifetimeDefaultSeconds){$seconds=GetOnlineInviteLifetimePreferenceUI}
        if($input -is [Collections.IDictionary]){$input['InviteLifetimeSeconds']=$seconds;$input['InviteLifetimeInitialized']=$true}
        elseif($input.PSObject.Properties['InviteLifetimeSeconds']){$input.InviteLifetimeSeconds=$seconds;$input.InviteLifetimeInitialized=$true}
    }
    $amount=[string](ServerUIGet $input InviteLifetimeAmount '')
    $unit=[string](ServerUIGet $input InviteLifetimeUnit 'Minutes')
    $error=''
    if($custom){
        $parsed=ConvertTo-OnlineInviteLifetimeSeconds $amount $unit
        $error=[string]$parsed.Error
        if(-not $error){$seconds=[int]$parsed.Seconds}
    }elseif($seconds -lt $script:OnlineInviteLifetimeMinSeconds -or $seconds -gt $script:OnlineInviteLifetimeMaxSeconds){
        $seconds=$script:OnlineInviteLifetimeDefaultSeconds
    }
    return [pscustomobject]@{Seconds=$seconds;Custom=$custom;Amount=$amount;Unit=$unit;Valid=(-not $error);Error=$error;
        Label=(Format-OnlineInviteLifetime $seconds);Compat=($seconds -gt $script:OnlineInviteLifetimeCompatLimitSeconds)}
}
function FormatOnlineInviteRemaining {param($ExpiresAtUtc,[DateTimeOffset]$Now=[DateTimeOffset]::UtcNow)
    # Remaining validity the server actually granted, never negative.
    $stamp=[DateTimeOffset]::MinValue
    if(-not $ExpiresAtUtc -or -not [DateTimeOffset]::TryParse([string]$ExpiresAtUtc,[ref]$stamp)){return ''}
    $remaining=[int][Math]::Floor(($stamp-$Now).TotalSeconds)
    if($remaining -le 0){return ''}
    if($remaining -lt 3600){return ([string][int][Math]::Max(1,[Math]::Round($remaining/60.0))+' 分钟')}
    return (Format-OnlineInviteLifetime $remaining)
}
function GetOnlineInviteLifetimePreferenceUI {
 $value=$null;$prefs=Get-Variable -Name Prefs -Scope Script -ErrorAction SilentlyContinue
 if($prefs){$value=ServerUIGet $prefs.Value InviteLifetimeSeconds $null}
 if(($value -is [int] -or $value -is [long]) -and $value -ge $script:OnlineInviteLifetimeMinSeconds -and $value -le $script:OnlineInviteLifetimeMaxSeconds){return [int]$value}
 return $script:OnlineInviteLifetimeDefaultSeconds
}
function SaveOnlineInviteLifetimeSelectionUI {
 $life=GetOnlineInviteLifetimeUI
 if(-not $life.Valid){if($life.Error){Toast $life.Error};return $false}
 if(Get-Command Save-TCPreferences -ErrorAction SilentlyContinue){
  try{$saved=Save-TCPreferences -InviteLifetimeSeconds ([int]$life.Seconds);if([int]$saved.InviteLifetimeSeconds -ne [int]$life.Seconds){throw '偏好保存结果不一致'}}
  catch{ErrorDialog '邀请码有效期未能保存，请检查本机设置文件后重试。';return $false}
 }
 $prefs=Get-Variable -Name Prefs -Scope Script -ErrorAction SilentlyContinue
 if($prefs){
  if($prefs.Value -is [Collections.IDictionary]){$prefs.Value['InviteLifetimeSeconds']=[int]$life.Seconds}
  elseif($prefs.Value.PSObject.Properties['InviteLifetimeSeconds']){$prefs.Value.InviteLifetimeSeconds=[int]$life.Seconds}
  else{$prefs.Value|Add-Member -NotePropertyName InviteLifetimeSeconds -NotePropertyValue ([int]$life.Seconds)}
 }
 return $true
}
function SetOnlineInviteLifetimeSelectionUI {
    # ComboBox selection: a preset stores its seconds, 自定义… only flips the flag.
    $choice=$script:Controls.OnlineInviteLifetime
    if(-not $choice -or $choice.SelectedItem -isnot [Windows.Controls.ComboBoxItem]){return}
    $m=$script:DeployUI.Management;$input=ServerUIGet $m Input
    if($null -eq $input){return}
    $seconds=[int]$choice.SelectedItem.Tag
    if($seconds -le 0){$input.InviteLifetimeCustom=$true
    }else{$input.InviteLifetimeCustom=$false;$input.InviteLifetimeSeconds=$seconds;if(-not (SaveOnlineInviteLifetimeSelectionUI)){return}}
    if(Get-Command ShowServerManagement -ErrorAction SilentlyContinue){ShowServerManagement}
}
function UpdateOnlineInviteLifetimeInputUI {
    # Typing in the custom box must not rebuild the page (focus would be lost),
    # so the copy that depends on the value is refreshed in place instead.
    $m=$script:DeployUI.Management;$input=ServerUIGet $m Input
    if($null -eq $input){return}
    if($script:Controls.ContainsKey('OnlineInviteLifetimeAmount')){$input.InviteLifetimeAmount=[string]$script:Controls.OnlineInviteLifetimeAmount.Text}
    if($script:Controls.ContainsKey('OnlineInviteLifetimeUnit') -and $script:Controls.OnlineInviteLifetimeUnit.SelectedItem -is [Windows.Controls.ComboBoxItem]){$input.InviteLifetimeUnit=[string]$script:Controls.OnlineInviteLifetimeUnit.SelectedItem.Tag}
    $life=GetOnlineInviteLifetimeUI
    if($script:Controls.ContainsKey('OnlineInviteLifetimeCompat')){
        $note=$script:Controls.OnlineInviteLifetimeCompat
        $note.Text=$(if($life.Compat){$script:OnlineInviteLifetimeCompatText}else{''})
        $note.Visibility=$(if($life.Compat){[Windows.Visibility]::Visible}else{[Windows.Visibility]::Collapsed})
    }
    if($script:Controls.ContainsKey('OnlineInviteLifetimeHint')){
        $hint=$script:Controls.OnlineInviteLifetimeHint
        $hint.Text=$(if($life.Valid){''}else{$life.Error})
        $hint.Visibility=$(if($life.Valid){[Windows.Visibility]::Collapsed}else{[Windows.Visibility]::Visible})
    }
    if($script:Controls.ContainsKey('OnlineInviteCreate')){$script:Controls.OnlineInviteCreate.Content='生成邀请码（'+$life.Label+'）';$script:Controls.OnlineInviteCreate.IsEnabled=$life.Valid}
}
function CancelAndRetryOnlineInviteUI {
    # OnlineMaintenanceDeferred means an invitation still blocks the receiver
    # update. Cancel the one this computer remembers, then run the same create
    # again: create is idempotent on InviteId and digest, so it either returns
    # the same invitation or starts the receiver for the stored input.
    $m=$script:DeployUI.Management
    if(-not $m -or [bool](ServerUIGet $m CommandPending $false)){return}
    $invite=ServerUIGet $m OnlineInvite
    $open=($invite -and [string](ServerUIGet $invite State '') -ceq 'Open' -and [string](ServerUIGet $invite InviteId ''))
    if($open){
        try{
            $m.OnlineInviteRetryAfterCancel=$true
            StartServerOperation pair_online_cancel (GetOnlineInviteBindingUI $invite) OnlineInviteCancel
        }catch{$m.OnlineInviteRetryAfterCancel=$false;ErrorDialog $_.Exception.Message}
        return
    }
    $retry=ServerUIGet $m OnlineInviteRetry
    if(-not $retry){$retry=ServerUIGet $m OnlineInviteLastInput}
    if(-not $retry){Toast '本机没有保存这次邀请的输入，请重新生成邀请码';return}
    try{$m.Error='';$m.ErrorCode='';StartServerOperation pair_online_create $retry OnlineInviteCreate}catch{ErrorDialog $_.Exception.Message}
}
function OpenOnlinePairingUI {
    if((IsBusy) -or $script:ReadOnly){return}
    # 0.21.8 A0: a finished flow used to be kept forever, so reopening 加入已有线路
    # landed on the old "线路已加入" page (same defect as the web page). Complete and
    # NeedsCheck start over. Retry is kept on purpose: 继续加入 reuses the enrollment
    # already registered on disk, and rebuilding it would throw that away.
    if(-not $script:OnlinePairUI -or $script:OnlinePairUI.Stage -in @('Complete','NeedsCheck')){
        $script:OnlinePairUI=@{Id=[guid]::NewGuid().ToString('N');Stage='Input';DeviceName=[Environment]::MachineName;EnrollmentId='';NodeId='';NodeName='';RunId='';Error='';ErrorCode=''}
    }
    ShowOnlinePairingUI
}
function TestOnlinePairContextUI {param($Context)return ($Context -and [object]::ReferenceEquals($script:OnlinePairUI,$Context.Model) -and $Context.Id -ceq $script:OnlinePairUI.Id)}
function StartOnlinePairingUI {
    if((IsBusy) -or $script:ReadOnly){return}
    $flow=$script:OnlinePairUI;$code=[string]$script:Controls.OnlineInvitationCode.Password
    if(-not $code -or $code.Length -gt 2048 -or $code.Trim() -cnotmatch '^TCI1\.[A-Za-z0-9_-]+$'){Toast '请粘贴完整的一次性邀请码';return}
    $flow.DeviceName=[string]$script:Controls.OnlineDeviceName.Text
    if(-not $flow.DeviceName -or $flow.DeviceName.Length -gt 64){Toast '电脑名称请使用 1–64 个字符';return}
    $script:Controls.OnlineInvitationCode.Clear();$flow.Stage='Creating';$flow.Error='';$flow.ErrorCode='';ShowOnlinePairingUI
    # The invitation is a short-lived secret. Keep it out of worker JSON,
    # receipts and outbound snapshots, just like a server password.
    StartUiCommand -Module 'PairingOnline.psm1' -Command 'New-TCPairOnlineEnrollment' -Arguments @{InvitationCode=$code.Trim();Root=$script:Root;DeviceName=$flow.DeviceName;WgPath=(Join-Path $script:PackageRoot 'assets\wg.exe')} -Context @{Model=$flow;Id=$flow.Id} -Complete {
        param($data,$context)
        if(-not (TestOnlinePairContextUI $context)){return}
        $context.Model.EnrollmentId=[string]$data.EnrollmentId;ContinueOnlinePairingUI
    } -Failed {
        param($message,$context,$failure)
        if(-not (TestOnlinePairContextUI $context)){return}
        $context.Model.Stage='Input';$context.Model.ErrorCode=[string](WebField $failure Code 'OnlineInvitationUnavailable');$copy=GetOnlinePairErrorCopy $context.Model.ErrorCode ([string](WebField $failure Message ''));$context.Model.Error=[string]$copy.Message;ShowOnlinePairingUI
    } -Message '正在确认邀请码并准备这台电脑…'
    $code=$null
}
function ContinueOnlinePairingUI {
    param([string]$EnrollmentId='')
    $flow=$script:OnlinePairUI
    if($EnrollmentId){$flow.EnrollmentId=$EnrollmentId}
    if(-not $flow.EnrollmentId -or $script:ReadOnly){return}
    $flow.Stage='Authorizing';$flow.Error='';$flow.ErrorCode='';ShowOnlinePairingUI
    StartJob @{Action='PairOnlineFinish';EnrollmentId=$flow.EnrollmentId} {
        param($data,$context)
        if(-not (TestOnlinePairContextUI $context) -or $data.EnrollmentId -cne $context.Model.EnrollmentId){return}
        $context.Model.NodeName=[string]$data.NodeName;$context.Model.Stage='Preparing';ShowOnlinePairingUI
        $name=if($context.Model.NodeName){$context.Model.NodeName}else{'加入的线路'}
        StartJob @{Action='PairComplete';EnrollmentId=$context.Model.EnrollmentId;Name=$name} {
            param($result,$inner)
            if(-not (TestOnlinePairContextUI $inner) -or $result.EnrollmentId -cne $inner.Model.EnrollmentId){return}
            $inner.Model.NodeId=[string]$result.NodeId;$inner.Model.RunId=[string]$result.RunId
            $inner.Model.Stage=if($result.DeploymentCompleteness -ceq 'Complete'){'Complete'}else{'NeedsCheck'}
            ShowOnlinePairingUI;FetchNodes;Toast $(if($inner.Model.Stage -eq 'Complete'){'线路已加入'}else{'线路已保存，请完成连接检查'})
        } '正在设置并检查这台电脑的线路…' -CallbackContext $context -Failed {param($message,$inner,$failure)FailOnlinePairingUI $message $inner $failure}
    } '正在为这台电脑开通线路…' -CallbackContext @{Type='Pair';Model=$flow;Id=$flow.Id} -Failed {param($message,$context,$failure)FailOnlinePairingUI $message $context $failure}
}
function FailOnlinePairingUI {param([string]$Message,$Context,$Failure)
    if(-not (TestOnlinePairContextUI $Context)){return}
    $Context.Model.Stage='Retry';$Context.Model.ErrorCode=[string](WebField $Failure Code 'OnlineEnrollmentIncomplete');$copy=GetOnlinePairErrorCopy $Context.Model.ErrorCode ([string](WebField $Failure Message ''));$Context.Model.Error=[string]$copy.Message;ShowOnlinePairingUI
}
function ConnectOnlinePairLineUI {
    $flow=$script:OnlinePairUI
    if((IsBusy) -or -not $flow.NodeId){return}
    $context=@{Type='Pair';Model=$flow;Id=$flow.Id}
    StartJob @{Action='Nodes'} {param($nodes,$context)
        if(-not (TestOnlinePairContextUI $context)){return}
        $script:Nodes=@($nodes|Where-Object {$_});$null=ShowTCWebShell 'home';RequestTCLineConnection $context.Model.NodeId
    } '正在读取新线路…' -CallbackContext $context
}
function ShowOnlinePairingUI {
    $flow=$script:OnlinePairUI;if(-not $flow){return}
    $script:Role='online-pair';PageHead '加入已有线路' '' 'online-pair'
    $card=Card '24,22';$p=Stack;$card.Child=$p
    if($flow.Error){AddC $p (Notice 'warn' '还需要完成一步' $flow.Error)}
    switch($flow.Stage){
        'Input'{
            AddC $p (T '一次性邀请码' 14 $script:Ink 'SemiBold')
            AddC $p (Margin (T '请在管理电脑上打开这条线路的“服务器与设备”，生成邀请码后复制到这里。' 12.5 $script:Text2) '0,5,0,14')
            $code=ControlName (New-Object Windows.Controls.PasswordBox) 'OnlineInvitationCode';$code.MaxLength=2048;[Windows.Automation.AutomationProperties]::SetName($code,'一次性邀请码');AddC $p $code
            $advanced=Stack;AddC $advanced (T '这台电脑的名称' 12.5 $script:Text2)
            $name=ControlName (New-Object Windows.Controls.TextBox) 'OnlineDeviceName';$name.Text=$flow.DeviceName;$name.MaxLength=64;AddC $advanced $name
            $details=New-Object Windows.Controls.Expander;$details.Header='电脑名称';$details.Content=$advanced;AddC $p (Margin $details '0,14,0,0')
            AddC $p (Margin (Btn '加入线路' 'OnlinePairJoin' {StartOnlinePairingUI} 'Primary') '0,18,0,0')
        }
        {$_ -in @('Creating','Authorizing','Preparing')}{
            AddC $p (T $(switch($flow.Stage){Creating{'正在确认邀请码'}Authorizing{'正在开通这台电脑'}Preparing{'正在设置与测试线路'}}) 18 $script:Ink 'SemiBold')
            $progress=New-Object Windows.Controls.ProgressBar;$progress.IsIndeterminate=$true;$progress.Height=4;AddC $p (Margin $progress '0,18,0,0')
        }
        'Complete'{
            AddC $p (T '线路已加入' 18 $script:Ink 'SemiBold');AddC $p (Margin (T $flow.NodeName 13 $script:Text2) '0,6,0,16')
            AddC $p (Btn '用它连接' 'OnlinePairConnect' {ConnectOnlinePairLineUI} 'Primary')
        }
        'NeedsCheck'{
            AddC $p (T '线路已保存' 18 $script:Ink 'SemiBold');AddC $p (Margin (T '还需要完成这台电脑的连接检查。' 13 $script:Text2) '0,6,0,16')
            AddC $p (Btn '继续检查' 'OnlinePairCheck' {ResumeProductDeployment $script:OnlinePairUI.RunId} 'Primary')
        }
        'Retry'{AddC $p (Btn '继续加入' 'OnlinePairRetry' {ContinueOnlinePairingUI} 'Primary')}
    }
    if($flow.ErrorCode){$details=New-Object Windows.Controls.Expander;$details.Header='技术详情';$details.Content=T $flow.ErrorCode 11.5 $script:Text3;AddC $p (Margin $details '0,14,0,0')}
    AddC $script:HostPanel $card
    if($flow.Stage -notin @('Creating','Authorizing','Preparing')){
        $actions=New-Object Windows.Controls.WrapPanel
        AddC $actions (Btn '使用离线交接资料' 'OnlinePairOffline' {ShowProductPairing -PairRole Client} 'Ghost')
        AddC $actions (Btn '返回线路' 'OnlinePairBack' {$null=ShowTCWebShell 'lines'} 'Ghost');AddC $script:HostPanel (Margin $actions '0,16,0,0')
    }
}

# ---- Management side: one-time online invitation codes -------------------------
# The code is a result of the authenticated management session. It lives only in
# memory ($m.OnlineInvite), is never part of an operation input or an intent file,
# and disappears when the management view is reset.
function GetOnlineInviteFingerprintUI {
    $m=$script:DeployUI.Management
    Import-Module (UIProductPath 'DeploymentPairing.psm1') -DisableNameChecking
    $pair=Get-Module DeploymentPairing
    $key=ServerUIGet $m.Info ManagementSigningPublicKey
    return & $pair {param($Key)Initialize-TCPairCrypto;[TradeChannel.Deployment.PairCrypto]::Fingerprint(($Key|ConvertTo-Json -Compress))} $key
}
function StartOnlineInviteUI {
    if(ServerUIReadOnly){ErrorDialog '当前是只读检查窗口，未生成邀请码。';return}
    InitializeServerUI;$m=$script:DeployUI.Management
    $existing=ServerUIGet $m OnlineInvite
    if($existing -and [string](ServerUIGet $existing State '') -ceq 'Open' -and [string](ServerUIGet $existing InvitationCode '')){
        try{if([DateTimeOffset]::Parse([string]$existing.ExpiresAtUtc) -gt [DateTimeOffset]::UtcNow){Toast '已有一个未过期的邀请码';return}}catch{}
    }
    try{
        if(-not $m.Authenticated -or -not $m.SessionRef -or -not $m.Info -or -not (ServerUIGet $m.Info ManagementSigningPublicKey)){throw '请先登录服务器并启用管理能力。'}
        # 0.22.0 A6: no name is asked for. The label is generated here and never
        # read from a field, so a stale $m.Input.DeviceName cannot leak into a new
        # invitation.
        $name=GetTCInviteDeviceLabel
        # 0.22.0 A1: the page decides the lifetime; the server keeps 60..86400.
        $lifetime=GetOnlineInviteLifetimeUI
        if(-not $lifetime.Valid){throw $lifetime.Error}
        if(-not (SaveOnlineInviteLifetimeSelectionUI)){return}
        $node=ServerUIGet $m.Info Node;$endpoint=[string](ServerUIGet $node PublicEndpoint '')
        if($endpoint -cnotmatch '^((?:\d{1,3}\.){3}\d{1,3}):\d{1,5}$'){throw '没有读取到服务器的公开地址，请先刷新服务器状态。'}
        $publicHost=$matches[1]
        $inputData=@{
            InviteId=[guid]::NewGuid().ToString('D');DeviceName=$name;ExpiresInSeconds=$lifetime.Seconds;PublicHost=$publicHost;Port=18443
            ExpectedServerBinding=@{RemoteOwnerId=[string]$m.Info.RemoteOwnerId;NodeId=[string]$node.NodeId;ServerPublicKey=[string]$node.ServerPublicKey}
            ExpectedManagementFingerprint=(GetOnlineInviteFingerprintUI)
        }
    }catch{ErrorDialog $_.Exception.Message;return}
    $m.OnlineInviteRetry=$null
    # Kept for 「取消并重试」: the same input re-runs create, which is idempotent
    # on InviteId and digest, so it never registers a second device.
    $m.OnlineInviteLastInput=$inputData.Clone()
    $m.Error='';$m.ErrorCode='';$m.OnlineInviteRetryAfterCancel=$false
    StartServerOperation pair_online_create $inputData OnlineInviteCreate
}
function GetOnlineInviteBindingUI {param($Invite)
    $m=$script:DeployUI.Management;$node=ServerUIGet $m.Info Node
    return @{InviteId=[string]$Invite.InviteId;ExpectedServerBinding=@{RemoteOwnerId=[string]$m.Info.RemoteOwnerId;NodeId=[string]$node.NodeId;ServerPublicKey=[string]$node.ServerPublicKey};ExpectedManagementFingerprint=(GetOnlineInviteFingerprintUI)}
}
function CompleteOnlineInviteUI {param($Data,[string]$Kind)
    $m=$script:DeployUI.Management
    $previous=ServerUIGet $m OnlineInvite
    switch($Kind){
        'Create'{
            $last=ServerUIGet $m OnlineInviteLastInput
            if($previous -and $last -and [string](ServerUIGet $previous InviteId '') -ceq [string](ServerUIGet $last InviteId '') -and [string](ServerUIGet $Data InviteId '') -ceq [string](ServerUIGet $previous InviteId '')){
                $sameExpiry=([string](ServerUIGet $previous ExpiresAtUtc '') -ceq [string](ServerUIGet $Data ExpiresAtUtc ''))
                if(-not $sameExpiry){try{$sameExpiry=([DateTimeOffset]::Parse([string]$previous.ExpiresAtUtc) -eq [DateTimeOffset]::Parse([string]$Data.ExpiresAtUtc))}catch{$sameExpiry=$false}}
                if(-not $sameExpiry){$m.ErrorCode='InviteRearmContractMismatch';$m.Error='重新开启接收服务返回的有效期已变化，未按恢复成功处理。';Toast $m.Error;break}
            }
            # 0.22.0 A1: the toast reports the lifetime the server actually granted.
            $m.OnlineInvite=$Data;$m.OnlineInviteRetry=$null;$m.Error='';$m.ErrorCode=''
            $duration=FormatOnlineInviteRemaining (ServerUIGet $Data ExpiresAtUtc '')
            if(-not $duration){$duration=(GetOnlineInviteLifetimeUI).Label}
            Toast ('邀请码已生成，'+$duration+'内有效，只能使用一次')
        }
        'Cancel'{
            $m.OnlineInvite=$Data
            if([string](ServerUIGet $Data State '') -ceq 'Cancelled'){
                Toast '邀请码已取消，已加入的电脑不受影响'
                # 「取消并重试」 cancelled the blocking invitation; now run the
                # stored create again so the receiver starts for the new lifetime.
                if([bool](ServerUIGet $m OnlineInviteRetryAfterCancel $false)){
                    $m.OnlineInviteRetryAfterCancel=$false
                    $retry=ServerUIGet $m OnlineInviteRetry
                    if(-not $retry){$retry=ServerUIGet $m OnlineInviteLastInput}
                    if($retry){$m.Error='';$m.ErrorCode='';StartServerOperation pair_online_create $retry OnlineInviteCreate}
                }
            }
        }
        default{
            # Status replies never contain the code. Keep the original only while it is the same open invitation.
            $keep=if($previous -and [string](ServerUIGet $previous InviteId '') -ceq [string](ServerUIGet $Data InviteId '') -and [string](ServerUIGet $Data State '') -ceq 'Open'){[string](ServerUIGet $previous InvitationCode '')}else{''}
            if($keep -and -not (ServerUIGet $Data InvitationCode '')){$Data|Add-Member NoteProperty InvitationCode $keep -Force}
            $m.OnlineInvite=$Data
            if($Kind -ceq 'Reconcile'){Toast '已核对邀请码的实际状态'}
        }
    }
    # 0.22.0 A3: the same result must reach the web invitation page without
    # repainting the server page over it.
    if(TestServerPageRenderRoleUI){RenderServerManagementUI}
}
function GetOnlineInviteProbeIdentityUI {
    # The pinned TLS identity and the public endpoint of the invitation this
    # computer holds. Both exist only in the create reply - a status reply refuses
    # those fields - so they are read from the reply and, as a fallback, from the
    # stored input (which carries the host and the port but never the code).
    $m=$script:DeployUI.Management;$invite=ServerUIGet $m OnlineInvite
    $publicHost=[string](ServerUIGet $invite PublicHost '')
    $tls=[string](ServerUIGet $invite TlsSha256 '')
    $port=[int](ServerUIGet $invite Port 18443)
    if(-not $publicHost){
        $last=ServerUIGet $m OnlineInviteLastInput
        if($last){$publicHost=[string](ServerUIGet $last PublicHost '');$port=[int](ServerUIGet $last Port 18443)}
    }
    if($port -le 0){$port=18443}
    return [pscustomobject]@{PublicHost=$publicHost;TlsSha256=$tls;Port=$port;Usable=([bool]$publicHost -and $tls -match '^[A-Fa-f0-9]{64}$')}
}
function RefreshOnlineInviteCardUI {
    # The card lives on the server page, so a result redraws that page through the
    # same role-aware entry every other completion uses (A3): under the web driver
    # it republishes the web projection instead of replacing the page.
    if(Get-Command RenderServerManagementUI -ErrorAction SilentlyContinue){RenderServerManagementUI;return}
    if(Get-Command ShowServerManagement -ErrorAction SilentlyContinue){ShowServerManagement}
}
function StartOnlineInviteReachabilityUI {
    # A4 on the WPF surface: the same shared probe and the same context as the web
    # page (PairingOnline.psm1 Test-TCPairOnlineReachability). No token and no code
    # are sent; the result is advisory, so a refused port never cancels an
    # invitation this computer already holds.
    if(ServerUIReadOnly){return}
    $m=$script:DeployUI.Management;$invite=ServerUIGet $m OnlineInvite
    $identity=GetOnlineInviteProbeIdentityUI
    if(-not $identity.Usable){Toast '这次邀请没有记录证书指纹，无法自检 18443';return}
    $m.OnlineInviteReachability=@{Status='Checking';CheckedAtUtc=$null;Port=[int]$identity.Port}
    RefreshOnlineInviteCardUI
    $context=@{Type='Invite';ServerId=[string](ServerUIGet $m ServerId '');InviteId=[string](ServerUIGet $invite InviteId '');Port=[int]$identity.Port}
    StartUiCommand -Module 'PairingOnline.psm1' -Command 'Test-TCPairOnlineReachability' -Arguments @{PublicHost=[string]$identity.PublicHost;Port=[int]$identity.Port;TlsSha256=[string]$identity.TlsSha256;TimeoutSeconds=5} -Context $context -Complete {
        param($data,$inner)
        $current=$script:DeployUI.Management
        if(-not $current){return}
        if([string](ServerUIGet $inner InviteId '') -cne [string](ServerUIGet (ServerUIGet $current OnlineInvite) InviteId '')){return}
        $current.OnlineInviteReachability=@{Status=[string](ServerUIGet $data Status 'Error');CheckedAtUtc=((Get-Date).ToUniversalTime().ToString('o'));Port=[int](ServerUIGet $inner Port 18443)}
        RefreshOnlineInviteCardUI
    } -Failed {
        param($message,$inner,$failure)
        $current=$script:DeployUI.Management
        if(-not $current){return}
        $current.OnlineInviteReachability=@{Status='Error';CheckedAtUtc=((Get-Date).ToUniversalTime().ToString('o'));Port=[int](ServerUIGet $inner Port 18443)}
        RefreshOnlineInviteCardUI
    } -Message '正在检查 18443 能否连通…'
}
function RestartOnlineInviteReceiverUI {
    # A-11: after a server restart the 18443 receiver is gone while the invitation
    # record survives. create is idempotent on InviteId and digest, so re-running
    # it with the stored input brings the receiver back and returns the same
    # InviteId instead of registering a second device.
    if(ServerUIReadOnly){ErrorDialog '当前是只读检查窗口，没有执行这个操作。';return}
    $m=$script:DeployUI.Management
    if(-not $m){return}
    if($script:DeployUI.PendingManagement){Toast '上一步还没有结束，请稍候';return}
    $retry=ServerUIGet $m OnlineInviteLastInput
    if(-not $retry){Toast '本机没有保存这次邀请的输入，请重新生成邀请码';return}
    $m.Error='';$m.ErrorCode='';$m.OnlineInviteRetryAfterCancel=$false
    StartServerOperation pair_online_create $retry OnlineInviteCreate
}
function AddOnlineInviteCardUI {param($Parent)
    InitializeServerUI;$m=$script:DeployUI.Management;$invite=ServerUIGet $m OnlineInvite;$life=GetOnlineInviteLifetimeUI
    # 0.22.3: with the web shell this contributes ONE control. The three paragraphs
    # that explained the flow moved into the ⓘ next to the button - they answer
    # "what is this" for someone whose purpose here is to press one button.
    if($script:WebReady -and -not $script:WebFailed -and (Get-Command OpenTCWebInviteFromServerPageUI -ErrorAction SilentlyContinue)){
        $row=Stack 'Horizontal'
        AddC $row (Btn '邀请其他电脑' 'ServerWebInvite' {OpenTCWebInviteFromServerPageUI} 'Primary')
        AddC $row (Margin (HintIcon '一次只能有一张有效的邀请码，生成后按所选有效期失效。新电脑在「线路」页点「用邀请码加入」，粘贴即可，不需要服务器密码；它会先记作「邀请 MM-dd HH:mm」，加入后可改名。') '6,0,0,0')
        AddC $Parent $row
        return
    }
    # Degraded shell (no WebView2): the inline form keeps its own explanation.
    $tone=Get-Variable -Name Tone -Scope Script -ErrorAction SilentlyContinue
    $warnColor=if($tone -and $tone.Value.ContainsKey('warn')){[string]$tone.Value['warn'].Fg}else{$script:Text2}
    AddC $Parent (Margin (T '用邀请码添加新电脑' 13.5 $script:Ink 'SemiBold') '0,0,0,0')
    AddC $Parent (T ('生成后 '+(Format-OnlineInviteLifetime $life.Seconds)+'内有效，只能用一次。新电脑在“线路”页点“用邀请码加入”，粘贴即可，不需要服务器密码。') 12 $script:Text3)
    AddC $Parent (T '新电脑在设备列表里会自动记作「邀请 MM-dd HH:mm」，加入后可以改名；这里不需要填名称。' 12 $script:Text3)
    $state=if($invite){[string](ServerUIGet $invite State '')}else{''};$code=if($invite){[string](ServerUIGet $invite InvitationCode '')}else{''}
    $open=($invite -and $state -ceq 'Open')
    # 0.21.4: the server only reports expiry when asked, so a code past its
    # deadline used to stay "待使用" with no way to make a new one.
    if($open){try{if([DateTimeOffset]::Parse([string](ServerUIGet $invite ExpiresAtUtc '')) -le [DateTimeOffset]::UtcNow){$open=$false;$state='Expired';$code=''}}catch{}}
    if($invite){
        $line='邀请码：'+(ManagementLabel $state)+' · 到期 '+(ManagementTime (ServerUIGet $invite ExpiresAtUtc ''))
        if($open){$remaining=FormatOnlineInviteRemaining (ServerUIGet $invite ExpiresAtUtc '');if($remaining){$line=$line+' · 剩余 '+$remaining}}
        AddC $Parent (Margin (T $line 12 $script:Text3) '0,10,0,0')
    }
    if($open -and $code){
        $box=ControlName (New-Object Windows.Controls.TextBox) 'OnlineInviteCode';$box.Text=$code;$box.IsReadOnly=$true;$box.TextWrapping='Wrap';$box.MinHeight=64;$box.Margin='0,8,0,0'
        [Windows.Automation.AutomationProperties]::SetName($box,'一次性邀请码');AddC $Parent $box
        $port=[int](ServerUIGet $invite Port 18443)
        AddC $Parent (Margin (T ('新电脑需要能连到服务器的 TCP '+$port+' 端口。连不上时，请在云服务器防火墙放行该端口，或改用下方的离线方式。') 12 $script:Text3) '0,8,0,0')
        $row=Stack 'Horizontal'
        $null=DeploymentActions $row '复制邀请码' 'OnlineInviteCopy' {$null=CopyText ([string]$script:DeployUI.Management.OnlineInvite.InvitationCode) '已复制邀请码'}
        $null=DeploymentActions $row '刷新状态' 'OnlineInviteStatus' {try{StartServerOperation pair_online_status (GetOnlineInviteBindingUI $script:DeployUI.Management.OnlineInvite) OnlineInviteStatus}catch{ErrorDialog $_.Exception.Message}} 'Ghost'
        $null=DeploymentActions $row '取消这个邀请码' 'OnlineInviteCancel' {try{StartServerOperation pair_online_cancel (GetOnlineInviteBindingUI $script:DeployUI.Management.OnlineInvite) OnlineInviteCancel}catch{ErrorDialog $_.Exception.Message}} 'Ghost'
        AddC $Parent (Margin $row '0,10,0,0')
    }else{
        # 0.22.0 A1: the lifetime is chosen here. Presets plus an integer custom
        # entry; the choice is UI state only and never leaves this window.
        AddC $Parent (Margin (T '邀请码有效期' 12.5 $script:Ink 'SemiBold') '0,16,0,6')
        $choice=ControlName (New-Object Windows.Controls.ComboBox) 'OnlineInviteLifetime';$choice.MinHeight=34;$choice.Width=240;$choice.HorizontalAlignment='Left'
        # The security trade-off of a long lifetime goes into the hover text and
        # never replaces the compatibility warning, which must stay visible.
        $choice.ToolTip=$script:OnlineInviteLifetimeRiskText
        $presetItem=$null
        foreach($preset in $script:OnlineInviteLifetimePresets){
            $item=New-Object Windows.Controls.ComboBoxItem;$item.Content=[string]$preset.Label;$item.Tag=[int]$preset.Seconds;$null=$choice.Items.Add($item)
            if(-not $life.Custom -and [int]$preset.Seconds -eq $life.Seconds){$presetItem=$item}
        }
        $customItem=New-Object Windows.Controls.ComboBoxItem;$customItem.Content='自定义…';$customItem.Tag=$script:OnlineInviteLifetimeCustom;$null=$choice.Items.Add($customItem)
        if($life.Custom){$choice.SelectedItem=$customItem}elseif($presetItem){$choice.SelectedItem=$presetItem}else{$choice.SelectedIndex=1}
        # Attached after the initial selection, so rebuilding the page never
        # re-enters the handler.
        $choice.Add_SelectionChanged({SetOnlineInviteLifetimeSelectionUI})
        AddC $Parent $choice
        if($life.Custom){
            $custom=Stack 'Horizontal';$custom.Margin='0,8,0,0'
            $amount=ControlName (New-Object Windows.Controls.TextBox) 'OnlineInviteLifetimeAmount';$amount.Text=[string]$life.Amount;$amount.Width=110;$amount.MinHeight=34
            $amount.ToolTip='分钟填 10–1440 的整数，小时填 1–24 的整数。'
            $amount.Add_TextChanged({UpdateOnlineInviteLifetimeInputUI});AddC $custom $amount
            $unit=ControlName (New-Object Windows.Controls.ComboBox) 'OnlineInviteLifetimeUnit';$unit.MinHeight=34;$unit.Width=100;$unit.Margin='8,0,0,0'
            foreach($entry in @(@('分钟','Minutes'),@('小时','Hours'))){
                $item=New-Object Windows.Controls.ComboBoxItem;$item.Content=[string]$entry[0];$item.Tag=[string]$entry[1];$null=$unit.Items.Add($item)
                if([string]$entry[1] -ceq [string]$life.Unit){$unit.SelectedItem=$item}
            }
            if($unit.SelectedItem -isnot [Windows.Controls.ComboBoxItem]){$unit.SelectedIndex=0}
            $unit.Add_SelectionChanged({UpdateOnlineInviteLifetimeInputUI});AddC $custom $unit
            AddC $Parent $custom
            $null=DeploymentActions $Parent '使用这个有效期' 'OnlineInviteLifetimeApply' {if(SaveOnlineInviteLifetimeSelectionUI){Toast '已记住邀请码有效期';ShowServerManagement}} 'Ghost'
        }
        # Shown directly, not in a hover text: an old receiver rejects these codes.
        $compat=ControlName (T $script:OnlineInviteLifetimeCompatText 12 $warnColor) 'OnlineInviteLifetimeCompat'
        $compat.Visibility=$(if($life.Compat){'Visible'}else{'Collapsed'})
        AddC $Parent (Margin $compat '0,8,0,0')
        $hint=ControlName (T $life.Error 12 $warnColor) 'OnlineInviteLifetimeHint'
        $hint.Visibility=$(if($life.Valid){'Collapsed'}else{'Visible'})
        AddC $Parent (Margin $hint '0,6,0,0')
        if($open -and -not $code){
            AddC $Parent (Margin (T '这个邀请码仍有效，但本机没有保存它的内容。可以取回原邀请码，不会生成第二个。' 12 $script:Text3) '0,8,0,0')
            $retry=ServerUIGet $m OnlineInviteRetry
            if($retry){$null=DeploymentActions $Parent '取回原邀请码' 'OnlineInviteRestore' {StartServerOperation pair_online_create $script:DeployUI.Management.OnlineInviteRetry OnlineInviteCreate} 'Ghost'}
        }
        # A deferred receiver update blocks the next code; offer the local
        # recovery next to the button instead of only at the top of the page.
        if((ServerUIGet $m ErrorCode '') -ceq 'OnlineMaintenanceDeferred' -and -not $script:ReadOnly -and -not ($open -and $code)){
            AddC $Parent (Margin (T (ServerErrorText 'OnlineMaintenanceDeferred') 12 $warnColor) '0,8,0,0')
            $null=DeploymentActions $Parent '取消并重试' 'OnlineInviteCancelRetry' {CancelAndRetryOnlineInviteUI} 'Ghost'
        }
        $create=DeploymentActions $Parent ('生成邀请码（'+$life.Label+'）') 'OnlineInviteCreate' {StartOnlineInviteUI}
        if($create){$create.IsEnabled=$life.Valid}
    }
    # While an unexpired invitation is on screen it is the one blocking the
    # update, so the same recovery must be reachable from that branch too.
    if($open -and $code -and (ServerUIGet $m ErrorCode '') -ceq 'OnlineMaintenanceDeferred' -and -not $script:ReadOnly){
        AddC $Parent (Margin (T (ServerErrorText 'OnlineMaintenanceDeferred') 12 $warnColor) '0,8,0,0')
        $null=DeploymentActions $Parent '取消并重试' 'OnlineInviteCancelRetry' {CancelAndRetryOnlineInviteUI} 'Ghost'
    }
    # 0.22.0 A8: the 18443 self-check and 「重新开启接收服务」 are reachable from
    # both states, because a server restart leaves the invitation record behind
    # without a working receiver - and in that state the local copy of the code is
    # still on screen. Both act on this invitation only.
    if($invite -and -not $script:ReadOnly){
        AddC $Parent (Margin (T '这台电脑能不能连到这个邀请码的 18443' 12.5 $script:Ink 'SemiBold') '0,18,0,6')
        $probe=Stack 'Horizontal'
        $null=DeploymentActions $probe '检查 18443 能否连通' 'OnlineInviteReachability' {StartOnlineInviteReachabilityUI} 'Ghost'
        $null=DeploymentActions $probe '重新开启接收服务' 'OnlineInviteReopen' {RestartOnlineInviteReceiverUI} 'Ghost'
        AddC $Parent $probe
        $reach=GetOnlineInviteReachabilityTextUI (ServerUIGet $m OnlineInviteReachability)
        if($reach){
            $reachRow=Stack 'Horizontal';AddC $reachRow (T $reach 12 $script:Text3)
            if([string](ServerUIGet (ServerUIGet $m OnlineInviteReachability) Status '') -ceq 'Reachable' -and (Get-Command HintIcon -ErrorAction SilentlyContinue)){AddC $reachRow (Margin (HintIcon '新电脑所在网络可能另有限制') '6,0,0,0')}
            AddC $Parent (Margin $reachRow '0,6,0,0')
        }
    }
}
