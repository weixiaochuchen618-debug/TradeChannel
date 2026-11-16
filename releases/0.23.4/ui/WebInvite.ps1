#requires -Version 5.1
# ---- Web-native invitation host model (0.22.0 A2, A3, A5) ----------------------
# ui/WebShell.ps1 owns pages and snapshots; ui/ServerPages.ps1 owns the SSH
# management session. This file is the model that lets the web page drive that
# session without ever taking over the screen, and it holds the one and only copy
# of a full invitation code.
#
# Boundaries kept on purpose:
#   * only the non-secret invite lifetime is written through Save-TCPreferences;
#   * the full code lives in $script:WebInviteCode only - never in the model, the
#     snapshot, an operation input or a management intent;
#   * every step is a management operation the server page already performs, so
#     PendingManagement, the task lease, the intent record and the binding checks
#     all keep working exactly as before (A3 item 7).
$script:WebInvite=$null
$script:WebInviteCode=''
$script:WebInviteEpoch=0
# 0.22.2: where the page was entered from. 「返回」 has to go back to that page, not
# always to 线路 - the server page entry used to drop the operator on the lines list.
$script:WebInviteOrigin='lines'
# Why the last Resolve refused. The caller turns this into three different sentences.
$script:TCWebInviteResolveReason=''
$script:WebInviteLifetimeDefault=1800
$script:WebInviteLifetimeMin=600
$script:WebInviteLifetimeMax=86400
# The four presets the page offers. 10 分钟 .. 24 小时, matching the server page.
$script:WebInviteLifetimePresets=@(600,1800,7200,86400)
# A1: above half an hour the receiving computer may still run the older build, so
# the page shows the same compatibility note the server page shows.
$script:WebInviteCompatSeconds=1800
# Registry reads for the line projection. GetTCWebSnapshot runs four times a
# second, so the server registry is read at most once every five seconds; no
# snapshot ever blocks on disk.
$script:WebInviteServers=@{At=[DateTime]::MinValue;Records=@()}
$script:WebInviteServerTtlSeconds=5
# A4: the reachability probe is advisory, so it never delays the invitation.
$script:WebInviteReachabilityTimeoutSeconds=5

function CopyTCWebInviteValue {param($Value)
 if($Value -is [Collections.IDictionary]){$copy=@{};foreach($key in $Value.Keys){$copy[$key]=CopyTCWebInviteValue $Value[$key]};return $copy}
 if($Value -is [Array]){return @($Value|ForEach-Object {CopyTCWebInviteValue $_})}
 return $Value
}
function CopyTCWebInviteInput {param([hashtable]$InputData)
 # Retry state is detached from operation/intent callbacks, including the nested
 # server-binding object. It contains only the existing management whitelist.
 return (CopyTCWebInviteValue $InputData)
}
function GetTCWebInviteLifetimePreference {
 $value=$null
 $prefs=Get-Variable -Name Prefs -Scope Script -ErrorAction SilentlyContinue
 if($prefs){$value=ServerUIGet $prefs.Value InviteLifetimeSeconds $null}
 if(($value -is [int] -or $value -is [long]) -and $value -ge $script:WebInviteLifetimeMin -and $value -le $script:WebInviteLifetimeMax){return [int]$value}
 return $script:WebInviteLifetimeDefault
}
function SyncTCWebInviteLifetimePreference {param([int]$Seconds)
 $prefs=Get-Variable -Name Prefs -Scope Script -ErrorAction SilentlyContinue
 if($prefs){
  if($prefs.Value -is [Collections.IDictionary]){$prefs.Value['InviteLifetimeSeconds']=$Seconds}
  elseif($prefs.Value.PSObject.Properties['InviteLifetimeSeconds']){$prefs.Value.InviteLifetimeSeconds=$Seconds}
  else{$prefs.Value|Add-Member -NotePropertyName InviteLifetimeSeconds -NotePropertyValue $Seconds}
 }
}
function SetTCWebInviteLifetime {param($Value,[switch]$Quiet)
 if(($Value -isnot [int] -and $Value -isnot [long]) -or $Value -lt $script:WebInviteLifetimeMin -or $Value -gt $script:WebInviteLifetimeMax){
  if(-not $Quiet){SetTCWebInviteFailure '邀请码有效期必须是 10 分钟到 24 小时之间的整数。' 'InvalidInviteLifetime' 'None'}
  return $false
 }
 $seconds=[int]$Value
 if(Get-Command Save-TCPreferences -ErrorAction SilentlyContinue){
  try{
   $saved=Save-TCPreferences -InviteLifetimeSeconds $seconds
   if($null -eq $saved -or [int]$saved.InviteLifetimeSeconds -ne $seconds){throw '偏好保存结果不一致'}
  }catch{
   if(-not $Quiet){SetTCWebInviteFailure '邀请码有效期未能保存，请检查本机设置文件后重试。' 'InvitePreferenceSaveFailed' 'None'}
   return $false
  }
 }
 SyncTCWebInviteLifetimePreference $seconds
 if($script:WebInvite){$script:WebInvite.LifetimeSeconds=$seconds}
 return $true
}

function GetTCWebInviteStamp {
    return [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ',[Globalization.CultureInfo]::InvariantCulture)
}
function NewTCWebInviteModel {
    # Exactly the fields the host model defines, plus three private bookkeeping
    # fields that never reach the snapshot (PendingStep, LoginRetried, UpdatedAtUtc).
    $stamp=GetTCWebInviteStamp
    $script:WebInvite=[ordered]@{
        SessionId=[guid]::NewGuid().ToString('N');Epoch=[int]$script:WebInviteEpoch
        Phase='Idle';StageLabel='';StageChangedAtUtc=$stamp
        ServerId='';LifetimeSeconds=[int]$script:WebInviteLifetimeDefault
        InviteId='';State='';ExpiresAtUtc=$null;RetryUntilUtc=$null;Reachability=$null
        ErrorCode='';ErrorMessage='';NextAction='None'
        CodePresent=$false;CodePreview=''
        PendingStep='';RetryCreateInput=$null;RetryAction='';LoginRetried=$false;UpdatedAtUtc=$stamp
        # Private bookkeeping. None of these leaves the host: PublicHost and
        # TlsSha256 are what the A4 probe needs, AfterLogin remembers which step a
        # silent re-login has to resume, and the three clocks drive the status poll.
        PublicHost='';TlsSha256='';InvitePort=18443;AfterLogin=''
        PollAt=[DateTime]::MinValue;StartedAtUtc=$stamp;ExpiryRefreshDone=$false
    }
    return $script:WebInvite
}
function InitializeTCWebInvite {
    if(-not $script:WebInvite){$null=NewTCWebInviteModel}
}
function GetTCWebInviteStageLabel {param([string]$Phase)
    switch -CaseSensitive ($Phase){
        'Loading'{return '正在读取服务器'}
        'LoggingIn'{return '正在登录服务器'}
        'Creating'{return '正在生成邀请码'}
        'Checking'{return '正在检查 18443 能否连通'}
        'Open'{return '邀请码已生成'}
        'Ended'{return '邀请已结束'}
        'Failed'{return '这一步没有完成'}
    }
    return ''
}
function SetTCWebInvitePhase {param([string]$Phase,[string]$Label='')
    $w=$script:WebInvite;if(-not $w){return}
    $stamp=GetTCWebInviteStamp
    $w.Phase=$Phase
    $w.StageLabel=$(if($Label){$Label}else{GetTCWebInviteStageLabel $Phase})
    $w.StageChangedAtUtc=$stamp;$w.UpdatedAtUtc=$stamp
    if(Get-Command SyncTCWebState -ErrorAction SilentlyContinue){$null=SyncTCWebState -Force}
}
function SetTCWebInviteDriver {
    # A3: from here until ClearTCWebInviteDriver the management model belongs to the
    # invitation page. RenderServerManagementUI then refreshes this model instead of
    # repainting the server page; an empty Driver keeps the 0.21.8 behaviour.
    InitializeServerUI
    $m=$script:DeployUI.Management
    if(-not $m){return $false}
    $m.Driver='WebInvite'
    # The timer polls the management session only while this flag is set (or an
    # operation is pending), which is exactly what the invitation page needs.
    $script:DeployUI.ManagementMode=$true
    return $true
}
function ClearTCWebInviteDriver {
    $state=Get-Variable -Name DeployUI -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    $m=if($state){ServerUIGet $state Management}else{$null}
    if($m){$m.Driver=''}
}
function ResetTCWebInvite {param([string]$ServerId='',[int]$LifetimeSeconds=0)
    # A new visit to the page: the previous invitation, its result and its code all
    # die here, and the epoch moves so a late callback cannot revive them.
    $script:WebInviteEpoch=[int]$script:WebInviteEpoch+1
    $script:WebInviteCode=''
    $null=NewTCWebInviteModel
    $w=$script:WebInvite
    $w.ServerId=[string]$ServerId
    $w.LifetimeSeconds=$(if($LifetimeSeconds -ge $script:WebInviteLifetimeMin -and $LifetimeSeconds -le $script:WebInviteLifetimeMax){$LifetimeSeconds}else{GetTCWebInviteLifetimePreference})
    SetTCWebInvitePhase 'Idle'
    return $w
}
function ClearTCWebInvite {param([string]$Notice='')
    # Leaving the page. 0.22.2: the invitation itself survives the visit - only the
    # driver is released and the epoch moves, so a late management callback cannot
    # paint this page. The code stays in memory so coming back to the same open
    # invitation shows it again instead of a blank form (the "one-shot feature"
    # complaint). It is dropped when the invitation ends, when another server is
    # chosen, or when the program exits - never by simply walking away.
    $script:WebInviteEpoch=[int]$script:WebInviteEpoch+1
    $w=$script:WebInvite
    if($w){$w.Epoch=[int]$script:WebInviteEpoch;$w.PendingStep=''}
    ClearTCWebInviteDriver
    # Stop the management poll unless a management page is on screen (the operator
    # may have gone to the server page precisely to finish this invitation).
    if($script:Role -notin @('servers','devices','automatic-tcp','product-pair')){$script:DeployUI.ManagementMode=$false}
    if($Notice -and (Get-Command Toast -ErrorAction SilentlyContinue)){Toast $Notice}
}
function GetTCWebInviteCodePreview {param([string]$Code)
    if(-not $Code){return ''}
    $tail=$Code.Substring([Math]::Max(0,$Code.Length-4))
    return ('TCI1.'+([string]([string][char]0x2022)*8)+$tail)
}
function SetTCWebInviteCode {param([string]$Code)
    # $script:WebInviteCode is the only place a full code exists. The model keeps a
    # masked preview so the snapshot can be logged without redaction.
    $script:WebInviteCode=[string]$Code
    $w=$script:WebInvite
    if($w){
        $w.CodePresent=[bool]$script:WebInviteCode
        $w.CodePreview=$(if($script:WebInviteCode){GetTCWebInviteCodePreview $script:WebInviteCode}else{''})
    }
}
function GetTCWebInviteCode {return [string]$script:WebInviteCode}
function GetTCWebInviteFailureCopy {param([string]$Code,[string]$Message)
    # A trust decision belongs to the server page, so the invitation page never
    # phrases it as a local retry.
    if($Code -cin @('HostTrustRequired','HostKeyChanged')){return '服务器身份需要核对，请在服务器页处理。'}
    if($Code -ceq 'OutcomePending'){return '上次操作结果待确认，请到服务器页处理。'}
    if($Code -ceq 'SavedLoginRequired'){return '这台服务器没有保存登录资料，请到服务器页登录。'}
    if($Code -ceq 'SavedLoginUnavailable'){return '已保存的登录资料无法使用，请到服务器页重新登录。'}
    if($Message){return $Message}
    if($Code -and (Get-Command ServerErrorText -ErrorAction SilentlyContinue)){return (ServerErrorText $Code)}
    return '这一步没有完成，请重试。'
}
function GetTCWebInviteNextAction {param([string]$Code,$Model)
    # OpenServer means "only the server page can finish this"; Retry means the page
    # can simply run the same step again.
    if($Code -ceq 'OnlineMaintenanceDeferred'){return 'CancelRetry'}
    if($Code -cin @('HostTrustRequired','HostKeyChanged','OutcomePending','SavedLoginRequired','SavedLoginUnavailable','ManagementLoginRequired','ArchivedRecord','ServerRecordMissing')){return 'OpenServer'}
    if(TestTCWebInviteSessionLost $Code){return 'OpenServer'}
    if($Model -and [bool](ServerUIGet $Model Authenticated $false)){return 'Retry'}
    return 'OpenServer'
}
function TestTCWebInviteSessionLost {param([string]$Code)
    # The deployment host ends an idle session after ten minutes; these codes mean
    # "there is no session any more", not "the server refused the change".
    return ($Code -cin @('SessionMismatch','PipeClosed','ExecutorMissing','IdentitySessionUsed','IdentitySessionBusy'))
}
function SetTCWebInviteFailure {param([string]$Message,[string]$Code='',[string]$NextAction='')
    InitializeTCWebInvite
    $w=$script:WebInvite
    $w.ErrorCode=[string]$Code
    $w.ErrorMessage=[string](GetTCWebInviteFailureCopy $Code $Message)
    $w.NextAction=$(if($NextAction){$NextAction}else{'Retry'})
    SetTCWebInvitePhase 'Failed'
}
function UpdateTCWebInviteFromManagement {
    # A3: the single funnel for every management completion, failure and status
    # reply. It reads the management model, never renders and never sends a change.
    InitializeTCWebInvite
    $w=$script:WebInvite
    $state=Get-Variable -Name DeployUI -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    $m=if($state){ServerUIGet $state Management}else{$null}
    if(-not $m){return}
    $pending=if($state){ServerUIGet $state PendingManagement}else{$null}
    $invite=ServerUIGet $m OnlineInvite
    $code=[string](ServerUIGet $m ErrorCode '')
    $message=[string](ServerUIGet $m Error '')
    $intent=ServerUIGet $m UnresolvedIntent
    # Rearm is not a second create: a changed id or deadline is a contract error,
    # and the original web model/code must survive for diagnosis and retry.
    if($invite -and [string]$w.PendingStep -ceq 'Create' -and [string]$w.RetryAction -ceq 'Rearm'){
        $sameId=([string](ServerUIGet $invite InviteId '') -ceq [string]$w.InviteId)
        $sameExpiry=([string](ServerUIGet $invite ExpiresAtUtc '') -ceq [string]$w.ExpiresAtUtc)
        if(-not $sameExpiry){
            try{$sameExpiry=([DateTimeOffset]::Parse([string]$invite.ExpiresAtUtc) -eq [DateTimeOffset]::Parse([string]$w.ExpiresAtUtc))}catch{$sameExpiry=$false}
        }
        if(-not $sameId -or -not $sameExpiry){$w.PendingStep='';SetTCWebInviteFailure '重新开启接收服务返回的邀请身份或有效期已变化，未按恢复成功处理。' 'InviteRearmContractMismatch' 'Retry';return}
    }
    # 1. Mirror whatever the invitation record says. A code the server returned is
    # only kept while it is this invitation's own code.
    if($invite){
        $w.InviteId=[string](ServerUIGet $invite InviteId '')
        $w.State=[string](ServerUIGet $invite State '')
        $w.ExpiresAtUtc=(ServerUIGet $invite ExpiresAtUtc $null)
        $w.RetryUntilUtc=(ServerUIGet $invite RetryUntilUtc $null)
        $full=[string](ServerUIGet $invite InvitationCode '')
        if($full){SetTCWebInviteCode $full}elseif([string]$w.State -cne 'Open'){SetTCWebInviteCode ''}
        # A4 needs the endpoint and the pinned TLS identity to prove this computer
        # can reach 18443. A status reply does not carry them, so the values the
        # create reply produced are kept until the next attempt.
        if(ServerUIGet $invite PublicHost ''){$w.PublicHost=[string]$invite.PublicHost}
        if(ServerUIGet $invite TlsSha256 ''){$w.TlsSha256=[string]$invite.TlsSha256}
        if(ServerUIGet $invite Port ''){$w.InvitePort=[int]$invite.Port}
    }
    # 2. An unresolved mutation blocks the next one; only the server page can
    # reconcile it, so the flow stops instead of asking the server again.
    if($intent){$w.PendingStep='';SetTCWebInviteFailure '上次操作结果待确认，请到服务器页处理。' 'OutcomePending' 'OpenServer';return}
    $step=[string]$w.PendingStep
    # 3. A step that is still in flight has nothing to report yet.
    if($pending){return}
    # 4. A refusal or a failed poll costs the page one sentence, and the invitation
    # record (if any) stays exactly as the server reported it. The one exception is
    # A5's single silent re-login, which must run before the failure is published.
    $relogin=($step -in @('Create','Status') -and -not [bool]$w.LoginRetried -and (TestTCWebInviteSessionLost $code))
    if($code -and -not $relogin){
        $w.PendingStep=''
        $w.ErrorCode=$code;$w.ErrorMessage=(GetTCWebInviteFailureCopy $code $message);$w.NextAction=(GetTCWebInviteNextAction $code $m)
        SetTCWebInvitePhase 'Failed'
        return
    }
    if($invite -and [string]$w.State){
        $w.ErrorCode='';$w.ErrorMessage='';$w.NextAction='None'
        if([string]$w.State -ceq 'Open'){SetTCWebInvitePhase 'Open'}
        else{SetTCWebInviteCode '';SetTCWebInvitePhase 'Ended'}
    }
    # 5. Advance the step this page is waiting for. The page is already showing the
    # result, so a following step starts from a truthful state.
    if($step){
        $w.PendingStep=''
        ContinueTCWebInviteUI $step
        return
    }
    # 6. Last resort: the model carries a sentence without a code (for example a
    # login that never started). It is shown instead of a page with no reaction.
    if($message -and -not $m.Authenticated -and -not $w.InviteId){
        $w.ErrorCode='ManagementFailed';$w.ErrorMessage=$message
        $w.NextAction=(GetTCWebInviteNextAction 'ManagementFailed' $m);SetTCWebInvitePhase 'Failed'
    }
}
function NewTCWebInviteCreateInput {param([int]$Seconds)
    # Same input contract the server page sends. A6 removes the name field, so the
    # host fills the label itself; it stays well under the server's 80 characters.
    $m=$script:DeployUI.Management
    if(-not $m.Authenticated -or -not $m.SessionRef -or -not $m.Info){throw '请先登录服务器并启用管理能力。'}
    if(-not (ServerUIGet $m.Info ManagementSigningPublicKey)){throw '服务器还没有启用管理能力，请先到服务器页启用。'}
    $node=ServerUIGet $m.Info Node
    $endpoint=[string](ServerUIGet $node PublicEndpoint '')
    if($endpoint -cnotmatch '^((?:\d{1,3}\.){3}\d{1,3}):\d{1,5}$'){throw '没有读取到服务器的公开地址，请先刷新服务器状态。'}
    $publicHost=$matches[1]
    return @{
        InviteId=[guid]::NewGuid().ToString('D')
        # 0.22.0 A6: one label function for all three paths (web, WPF card, offline
        # handoff). Falls back to the same shape if that file is not loaded.
        DeviceName=$(if(Get-Command GetTCInviteDeviceLabel -ErrorAction SilentlyContinue){GetTCInviteDeviceLabel}else{('邀请 '+(Get-Date).ToString('MM-dd HH:mm',[Globalization.CultureInfo]::InvariantCulture))})
        ExpiresInSeconds=[int]$Seconds
        PublicHost=$publicHost
        Port=18443
        ExpectedServerBinding=@{RemoteOwnerId=[string]$m.Info.RemoteOwnerId;NodeId=[string]$node.NodeId;ServerPublicKey=[string]$node.ServerPublicKey}
        ExpectedManagementFingerprint=(GetOnlineInviteFingerprintUI)
    }
}
function ConnectTCWebInviteSessionUI {
    # A5: reuse the live session for this server; otherwise log in silently with the
    # credential this computer already saved. No new place ever stores a password.
    $w=$script:WebInvite;$m=$script:DeployUI.Management
    if(-not $w -or -not $m){return 'Failed'}
    if([string]$m.ServerId -ceq [string]$w.ServerId -and $m.Authenticated -and $m.SessionRef){return 'Reused'}
    $ref=[string](ServerUIGet (ServerUIGet $m Server) SavedLoginRef '')
    if(-not $ref){SetTCWebInviteFailure '这台服务器没有保存登录资料，请到服务器页登录。' 'SavedLoginRequired' 'OpenServer';return 'Failed'}
    $credential=$null
    try{
        # Identity is proven before any decryption: a moved record reports
        # BindingChanged instead of a generic "unusable", and never touches DPAPI.
        $credential=GetServerSavedCredentialUI (ServerUIGet $m Server)
    }catch{
        $code='';if($_.Exception.Message -match '^\[TC:([A-Za-z][A-Za-z0-9_]+)\]'){$code=$matches[1]}
        if($code -ceq 'CredentialBindingChanged'){SetTCWebInviteFailure '这台服务器的身份已经变化，请到服务器页重新验证后登录。' 'SavedLoginUnavailable' 'OpenServer';return 'Failed'}
        $copy=GetServerSavedLoginFailureTextUI $code
        if(-not $copy){$copy='已保存的登录资料无法使用，请到服务器页重新登录。'}
        SetTCWebInviteFailure $copy 'SavedLoginUnavailable' 'OpenServer';return 'Failed'
    }
    $w.PendingStep='Login'
    SetTCWebInvitePhase 'LoggingIn'
    $null=ConnectServerWithCredentialUI $credential
    $credential=$null
    if(-not $script:DeployUI.PendingManagement){
        $w.PendingStep=''
        if(-not $w.ErrorCode){SetTCWebInviteFailure '没有发出登录请求，请到服务器页登录。' 'ManagementLoginRequired' 'OpenServer'}
        return 'Failed'
    }
    return 'Started'
}
function StartTCWebInviteCreate {
    param([hashtable]$InputData=$null,[ValidateSet('CreateNew','Rearm','Retry')][string]$Action='CreateNew')
    InitializeTCWebInvite
    $w=$script:WebInvite;$m=$script:DeployUI.Management
    if(-not $m -or -not $m.ServerId){SetTCWebInviteFailure '请先选择服务器。' 'NoServerSelected' 'None';return}
    $seconds=[int]$w.LifetimeSeconds
    if($seconds -lt $script:WebInviteLifetimeMin -or $seconds -gt $script:WebInviteLifetimeMax){SetTCWebInviteFailure '邀请码有效期必须在 10 分钟到 24 小时之间。' 'InvalidOnlineLifetime' 'None';return}
    if(ServerUIGet $m UnresolvedIntent){SetTCWebInviteFailure '上次操作结果待确认，请到服务器页处理。' 'OutcomePending' 'OpenServer';return}
    if($Action -ceq 'Rearm'){
        if([string]$w.State -cne 'Open' -or -not $InputData -or [string]$InputData.InviteId -cne [string]$w.InviteId){SetTCWebInviteFailure '只能为当前有效邀请重新开启接收服务。' 'InviteRearmUnavailable' 'None';return}
    }elseif($Action -ceq 'Retry' -and -not $InputData){SetTCWebInviteFailure '本机没有保存这次邀请的输入，请重新生成邀请码。' 'InviteRetryUnavailable' 'None';return}
    $w.ErrorCode='';$w.ErrorMessage='';$w.NextAction='None';$m.Error='';$m.ErrorCode=''
    $w.AfterLogin=$Action;$w.RetryAction=$Action
    if($Action -ceq 'CreateNew'){
        # CreateNew alone changes identity and clears the previous presentation.
        # The GUID is generated only after a usable session is available.
        SetTCWebInviteCode ''
        $w.InviteId='';$w.State='';$w.ExpiresAtUtc=$null;$w.RetryUntilUtc=$null
        $w.RetryCreateInput=$null;$w.Reachability=$null;$w.PublicHost='';$w.TlsSha256=''
        $w.InvitePort=18443;$w.ExpiryRefreshDone=$false
    }
    if($InputData){$w.RetryCreateInput=CopyTCWebInviteInput $InputData}
    $session=ConnectTCWebInviteSessionUI
    if($session -in @('Failed','Started')){return}
    if($Action -ceq 'CreateNew'){
        try{$InputData=NewTCWebInviteCreateInput $seconds}
        catch{SetTCWebInviteFailure $_.Exception.Message 'InviteInputUnavailable' 'Retry';return}
    }elseif(-not $InputData){$InputData=CopyTCWebInviteInput $w.RetryCreateInput}
    $w.RetryCreateInput=CopyTCWebInviteInput $InputData
    $m.OnlineInviteLastInput=CopyTCWebInviteInput $InputData
    $w.PendingStep='Create';SetTCWebInvitePhase $(if($Action -ceq 'Rearm'){'Creating'}else{'Creating'}) $(if($Action -ceq 'Rearm'){'正在重新开启接收服务'}else{'正在生成邀请码'})
    StartServerOperation pair_online_create $InputData OnlineInviteCreate
    if(-not $script:DeployUI.PendingManagement){
        $w.PendingStep=''
        if(-not $w.ErrorCode -and -not $w.ErrorMessage){SetTCWebInviteFailure '没有发出生成请求，请重试。' 'InviteNotDispatched' 'Retry'}
    }
}
function StartTCWebInviteUI {param([int]$LifetimeSeconds=0,[string]$ServerId='')
    InitializeTCWebInvite;$w=$script:WebInvite
    if($w.Phase -in @('Loading','LoggingIn','Creating','Checking')){SetTCWebInviteFailure '上一步还没有结束，请稍候。' 'InviteBusy' 'None';return}
    if([string]$w.State -ceq 'Open'){SetTCWebInviteFailure '当前邀请码仍有效；如需更换，请先取消。' 'InviteAlreadyOpen' 'None';return}
    $target=if($ServerId){[string]$ServerId}else{[string]$w.ServerId}
    if(-not $target){SetTCWebInviteFailure '请先选择服务器。' 'NoServerSelected' 'None';return}
    $seconds=if($LifetimeSeconds){[int]$LifetimeSeconds}else{[int]$w.LifetimeSeconds}
    if(-not (SetTCWebInviteLifetime $seconds)){return}
    if($target -cne [string]$w.ServerId){SetTCWebInviteCode '';$w.InviteId='';$w.State='';$w.ExpiresAtUtc=$null;$w.RetryUntilUtc=$null}
    $w.ServerId=$target;$w.LifetimeSeconds=$seconds;$w.LoginRetried=$false
    # 0.22.2: the first status read used to fire the moment the code appeared (the
    # sentinel was MinValue, which the poller reads as "never polled"). That read
    # raced the operator leaving the page and is what stranded the pending flag.
    # The create reply already carries the authoritative state, so the first poll
    # can wait one interval.
    $w.StartedAtUtc=GetTCWebInviteStamp;$w.PollAt=[DateTime]::UtcNow;$w.ExpiryRefreshDone=$false
    SetTCWebInvitePhase 'Loading'
    if(-not (SetTCWebInviteDriver)){SetTCWebInviteFailure '还没有可管理的服务器记录。' 'NoServerSelected' 'OpenServer';return}
    if([string]($script:DeployUI.Management.ServerId) -cne $target){
        $null=SelectServerStateUI $target
        if(-not $script:ServerSelectionStateUI){$null=SetTCWebInviteDriver;return}
    }
    $resolved=ResolveTCWebInviteServerUI $target
    if(-not $script:DeployUI.Management.Authenticated -and $resolved -and -not $resolved.SavedLogin){SetTCWebInviteFailure '这台服务器没有保存登录资料' 'SavedLoginRequired' 'OpenServer';return}
    StartTCWebInviteCreate -Action CreateNew
}
function RearmTCWebInviteUI {
    InitializeTCWebInvite;$w=$script:WebInvite;$m=$script:DeployUI.Management
    if($w.Phase -in @('Loading','LoggingIn','Creating','Checking')){SetTCWebInviteFailure '上一步还没有结束，请稍候。' 'InviteBusy' 'None';return}
    $inputData=ServerUIGet $m OnlineInviteLastInput
    if([string]$w.State -cne 'Open' -or -not $w.InviteId -or -not $inputData -or [string]$inputData.InviteId -cne [string]$w.InviteId){SetTCWebInviteFailure '本机没有与当前有效邀请匹配的原输入，无法恢复接收服务。' 'InviteRearmUnavailable' 'None';return}
    $w.LoginRetried=$false;SetTCWebInvitePhase 'Loading'
    StartTCWebInviteCreate -InputData (CopyTCWebInviteInput $inputData) -Action Rearm
}
function RetryTCWebInviteUI {
    InitializeTCWebInvite;$w=$script:WebInvite
    if($w.Phase -in @('Loading','LoggingIn','Creating','Checking')){SetTCWebInviteFailure '上一步还没有结束，请稍候。' 'InviteBusy' 'None';return}
    if(-not $w.RetryCreateInput){SetTCWebInviteFailure '本机没有保存这次邀请的输入，请重新生成邀请码。' 'InviteRetryUnavailable' 'None';return}
    $w.LoginRetried=$false;SetTCWebInvitePhase 'Loading'
    StartTCWebInviteCreate -InputData (CopyTCWebInviteInput $w.RetryCreateInput) -Action Retry
}
function DispatchTCWebInviteStatusUI {
    $w=$script:WebInvite
    try{$binding=GetOnlineInviteBindingUI @{InviteId=[string]$w.InviteId}}
    catch{SetTCWebInviteFailure $_.Exception.Message 'InviteInputUnavailable' 'Retry';return}
    $w.PendingStep='Status';StartServerOperation pair_online_status $binding OnlineInviteStatus
    if(-not $script:DeployUI.PendingManagement){$w.PendingStep='';if(-not $w.ErrorCode -and -not $w.ErrorMessage){SetTCWebInviteFailure '没有发出查询请求，请重试。' 'InviteNotDispatched' 'Retry'}}
}
function RefreshTCWebInviteStatusUI {
    # Refresh is only pair_online_status. A needed login is resumed as Refresh,
    # never silently converted into create/rearm.
    InitializeTCWebInvite;$w=$script:WebInvite;$m=$script:DeployUI.Management
    if(-not $w -or -not $m -or -not $w.InviteId){SetTCWebInviteFailure '当前没有可查询的邀请。' 'InviteStatusUnavailable' 'None';return}
    if($w.Phase -in @('Loading','LoggingIn','Creating','Checking')){SetTCWebInviteFailure '上一步还没有结束，请稍候。' 'InviteBusy' 'None';return}
    $null=SetTCWebInviteDriver;$w.AfterLogin='Refresh';$w.ErrorCode='';$w.ErrorMessage='';$w.NextAction='None'
    $session=ConnectTCWebInviteSessionUI
    if($session -in @('Failed','Started')){return}
    DispatchTCWebInviteStatusUI
}
function CancelTCWebInviteUI {
    # 「取消邀请码」: ends this invitation only; already joined computers keep their
    # authorization, exactly like the server page's cancel.
    InitializeTCWebInvite
    $w=$script:WebInvite;$m=$script:DeployUI.Management
    if(-not $w -or -not $m){return}
    if([string]$w.State -cne 'Open' -or -not [string]$w.InviteId){return}
    if($w.Phase -in @('Loading','LoggingIn','Creating','Checking')){return}
    $binding=$null
    try{$binding=GetOnlineInviteBindingUI @{InviteId=[string]$w.InviteId}}
    catch{SetTCWebInviteFailure $_.Exception.Message 'InviteInputUnavailable' 'Retry';return}
    $w.PendingStep='Cancel'
    SetTCWebInvitePhase 'Creating' '正在取消邀请码'
    StartServerOperation pair_online_cancel $binding OnlineInviteCancel
    if(-not $script:DeployUI.PendingManagement){
        $w.PendingStep=''
        if(-not $w.ErrorCode -and -not $w.ErrorMessage){SetTCWebInviteFailure '没有发出取消请求，请重试。' 'InviteNotDispatched' 'Retry'}
    }
}
function CancelAndRetryTCWebInviteUI {
    InitializeTCWebInvite;$w=$script:WebInvite;$m=$script:DeployUI.Management
    if([string]$w.ErrorCode -cne 'OnlineMaintenanceDeferred' -or -not $w.RetryCreateInput){SetTCWebInviteFailure '当前没有可取消后重试的邀请创建。' 'InviteRetryUnavailable' 'None';return}
    if([string]$w.State -cne 'Open' -or -not $w.InviteId){SetTCWebInviteFailure '没有可先取消的有效邀请，未重试创建。' 'InviteCancelUnavailable' 'None';return}
    if($w.Phase -in @('Loading','LoggingIn','Creating','Checking')){SetTCWebInviteFailure '上一步还没有结束，请稍候。' 'InviteBusy' 'None';return}
    try{$binding=GetOnlineInviteBindingUI @{InviteId=[string]$w.InviteId}}
    catch{SetTCWebInviteFailure $_.Exception.Message 'InviteInputUnavailable' 'Retry';return}
    $w.ErrorCode='';$w.ErrorMessage='';$w.NextAction='None';$m.Error='';$m.ErrorCode=''
    $w.PendingStep='CancelRetry';SetTCWebInvitePhase 'Creating' '正在取消原邀请，确认后重试'
    StartServerOperation pair_online_cancel $binding OnlineInviteCancel
    if(-not $script:DeployUI.PendingManagement){$w.PendingStep='';if(-not $w.ErrorCode){SetTCWebInviteFailure '取消请求没有完成，未重试创建。' 'InviteCancelFailed' 'Retry'}}
}
function ContinueTCWebInviteUI {param([string]$Step)
    # The single place that decides what happens after a management step ends.
    $w=$script:WebInvite;$m=$script:DeployUI.Management
    if(-not $w -or -not $m){return}
    switch -CaseSensitive ($Step){
        'Login'{
            if(-not $m.Authenticated -or -not $m.Info){SetTCWebInviteFailure '登录服务器没有完成，请到服务器页处理。' 'ManagementLoginRequired' 'OpenServer';return}
            # A5: a re-login resumes whichever step lost the session, never a new one.
            $resume=[string]$w.AfterLogin;$w.AfterLogin=''
            if($resume -ceq 'Refresh'){DispatchTCWebInviteStatusUI;return}
            if($resume -in @('Rearm','Retry')){StartTCWebInviteCreate -InputData (CopyTCWebInviteInput $w.RetryCreateInput) -Action $resume;return}
            StartTCWebInviteCreate -Action CreateNew
            return
        }
        'Create'{
            $code=[string](ServerUIGet $m ErrorCode '')
            if($code -and -not [bool]$w.LoginRetried -and (TestTCWebInviteSessionLost $code)){
                # A5: one silent re-login for a session the host ended, then the
                # second failure is reported with 「去服务器页登录」.
                $w.LoginRetried=$true;$w.AfterLogin='Retry'
                $m.Authenticated=$false;$m.SessionRef=$null;$m.ErrorCode=''
                $null=ConnectTCWebInviteSessionUI
                return
            }
            if($code){SetTCWebInviteFailure '' $code (GetTCWebInviteNextAction $code $m);return}
            if(-not [string]$w.InviteId){SetTCWebInviteFailure '生成邀请码没有完成，请重试。' 'InviteCreateIncomplete' 'Retry';return}
            # A4: the code exists, so the last stage of the flow is whether this
            # computer can reach TCP 18443. The probe never re-sends the invitation.
            StartTCWebInviteReachabilityUI
            return
        }
        'Cancel'{
            # Nothing follows a cancel: the mapping already published the new state, and
            # a refusal was published with its own sentence.
            return
        }
        'CancelRetry'{
            # Only a confirmed Cancelled reply may replay the original create input.
            # Error and OutcomeUnknown paths return before this continuation.
            if([string]$w.State -cne 'Cancelled' -or -not $w.RetryCreateInput){SetTCWebInviteFailure '取消结果未确认，未重试创建。' 'InviteCancelFailed' 'OpenServer';return}
            StartTCWebInviteCreate -InputData (CopyTCWebInviteInput $w.RetryCreateInput) -Action Retry
            return
        }
        'Status'{
            # A poll that lost the management session is recovered once, silently,
            # before the page tells the operator to go and log in.
            $code=[string](ServerUIGet $m ErrorCode '')
            if($code -and -not [bool]$w.LoginRetried -and (TestTCWebInviteSessionLost $code)){
                $w.LoginRetried=$true;$w.AfterLogin='Refresh'
                $w.ErrorCode='';$w.ErrorMessage='';$w.NextAction='None'
                $m.Authenticated=$false;$m.SessionRef=$null;$m.ErrorCode=''
                $null=ConnectTCWebInviteSessionUI
                return
            }
            return
        }
    }
}

# ---- T04a: page, projection, A4 and the status poll ----------------------------
# Everything below is the web page itself: which servers can invite, what the
# snapshot carries, and the three stages of one attempt. None of it opens a
# window, sends a change without a user action, or keeps a full code in a snapshot.

function ResetTCWebInviteServerCache {
    # Called after any operation that can change a server record (login, create,
    # cancel) so the next snapshot stops offering a server that is gone.
    $script:WebInviteServers=@{At=[DateTime]::MinValue;Records=@()}
}
function GetTCWebInviteServerRecordsUI {
    # The line projection and the page both need "which server owns this line".
    # GetTCWebSnapshot runs several times a second, so the registry file is read at
    # most once per TTL and never in the middle of a keystroke.
    $now=[DateTime]::UtcNow
    if(($now-[DateTime]$script:WebInviteServers.At).TotalSeconds -lt $script:WebInviteServerTtlSeconds){return @($script:WebInviteServers.Records)}
    $records=@()
    try{
        Import-Module (UIProductPath 'ServerRegistry.psm1') -DisableNameChecking
        $records=@(Get-TCServers -Root $script:Root)
    }catch{$records=@()}
    $script:WebInviteServers=@{At=$now;Records=$records}
    return $records
}
function TestTCWebInviteServerManageable {param($Server)
    # A4/A2 precondition, stated once: a real SSH management entry, management
    # rights that are not 使用权 only, and a pinned management signing identity.
    if(-not $Server){return $false}
    if([string](ServerUIGet $Server RecordState 'Active') -cne 'Active'){return $false}
    $connection=ServerUIGet $Server Connection
    if(-not $connection -or -not [string](ServerUIGet $connection Host '')){return $false}
    if([string](ServerUIGet $Server ManagementAccessState '') -ceq 'ConnectorOnly'){return $false}
    if(-not (ServerUIGet $Server ManagementSigningPublicKey)){return $false}
    return $true
}
function TestTCWebInviteSavedLoginUI {param($Server)
    # Boolean only: the browser never learns the reference, the save time or any
    # digest (Q5). "Saved" now means the envelope is readable AND belongs to this
    # record, so the page stops advertising a login that could only fail.
    # Only "Available" counts: a legacy v1 envelope is refused by the reader as soon
    # as a binding is supplied (TC:CredentialLegacy), so advertising it would show a
    # login that can only fail. Production never wrote a v1 file.
    return [bool](TestServerSavedLoginUsableUI $Server @('Available'))
}
function GetTCWebInviteTargetsUI {
    # Fixed public projection: no connection user, credential reference, key path
    # or probe identity crosses into the browser snapshot.
    $nodesVariable=Get-Variable -Name Nodes -Scope Script -ErrorAction SilentlyContinue
    $nodeItems=if($nodesVariable){@($nodesVariable.Value)}else{@()}
    $items=@(foreach($server in @(GetTCWebInviteServerRecordsUI)){
        if(-not (TestTCWebInviteServerManageable $server)){continue}
        $linked=@(ServerUIGet $server LinkedNodeIds @())
        $lineNames=@(foreach($node in @($nodeItems)){
            $ids=@([string](ServerUIGet $node LineId (ServerUIGet $node id '')))+@(ServerUIGet $node AliasIds @())
            if(@($ids|Where-Object {$_ -and $_ -in $linked}).Count){[string](ServerUIGet $node name '')}
        })
        $lines=@($lineNames|Where-Object {$_}|Sort-Object -Unique)
        [pscustomobject]@{Id=[string](ServerUIGet $server LocalRecordId '');Name=[string](ServerUIGet $server Name '服务器');Host=[string](ServerUIGet (ServerUIGet $server Connection) Host '');Lines=@($lines);SavedLogin=[bool](TestTCWebInviteSavedLoginUI $server)}
    })
    return @($items)
}
function GetTCWebInviteLineIdsUI {param([string]$LineId)
    # A line can be known under more than one id (rename keeps the alias), and the
    # server record links the id it was registered with.
    $ids=@($LineId)
    try{
        $nodes=Get-Variable -Name Nodes -Scope Script -ValueOnly -ErrorAction SilentlyContinue
        foreach($node in @($nodes)){
            $id=[string](WebField $node LineId (WebField $node id ''))
            if($id -cne $LineId){continue}
            foreach($alias in @(WebField $node AliasIds @())){if($alias){$ids+=[string]$alias}}
        }
    }catch{}
    return @($ids|Where-Object {$_}|Select-Object -Unique)
}
function GetTCWebLineInviteBindingUI {param([string]$LineId)
    # A2 line projection: does this line have exactly one manageable server, and
    # which record is it? Two linked records is an ambiguity, not an invitation.
    # 0.22.2: the record name travels with the binding so the line picker can say
    # 「服务器 X（N 条线路）」 when one server owns more than one line.
    $result=@{CanInvite=$false;ServerRecordId='';ServerName=''}
    if(-not $LineId){return $result}
    $ids=@(GetTCWebInviteLineIdsUI $LineId)
    $linked=@(foreach($server in @(GetTCWebInviteServerRecordsUI)){
        if([string](ServerUIGet $server RecordState 'Active') -cne 'Active'){continue}
        $links=@(ServerUIGet $server LinkedNodeIds @())
        if(@($ids|Where-Object {$_ -in $links}).Count -eq 0){continue}
        $server
    })
    if($linked.Count -ne 1){return $result}
    $result.ServerRecordId=[string](ServerUIGet $linked[0] LocalRecordId '')
    $result.ServerName=[string](ServerUIGet $linked[0] Name '')
    $result.CanInvite=(TestTCWebInviteServerManageable $linked[0])
    return $result
}
function ResolveTCWebInviteServerUI {param([string]$ServerId='',[string]$LineId='')
    # 0.22.2: a refusal states which refusal it is. The caller used to see only
    # $null and told every operator "没有可管理的服务器" - wrong whenever the real
    # reason was "more than one server, pick a line first".
    $script:TCWebInviteResolveReason=''
    $targets=@(GetTCWebInviteTargetsUI)
    if($ServerId){
        $match=@($targets|Where-Object {$_.Id -ceq $ServerId})
        if($match.Count -eq 1){return $match[0]}
        $script:TCWebInviteResolveReason='NoRecord';return $null
    }
    if($LineId){
        $binding=GetTCWebLineInviteBindingUI $LineId
        if([bool]$binding.CanInvite){
            $match=@($targets|Where-Object {$_.Id -ceq [string]$binding.ServerRecordId})
            if($match.Count -eq 1){return $match[0]}
        }
        $script:TCWebInviteResolveReason='NotManageable';return $null
    }
    # One管理服务器: no choice to make, so the page selects it.
    if($targets.Count -eq 1){return $targets[0]}
    $script:TCWebInviteResolveReason=$(if($targets.Count -eq 0){'NoRecord'}else{'Ambiguous'})
    return $null
}
function GetTCWebInviteCompatNoteVisible {param($Model)
    # A1: past half an hour the receiving computer may still run an older build.
    return ([int](ServerUIGet $Model LifetimeSeconds 0) -gt $script:WebInviteCompatSeconds)
}
function GetTCWebInviteView {
    # The snapshot projection. The full code never appears here: CodePresent and a
    # masked preview are enough for the page to render, and Reveal carries the code
    # in its own one-shot message.
    $w=$script:WebInvite
    if(-not $w){return $null}
    $reachability=$null
    if(ServerUIGet $w Reachability){
        $reachability=[ordered]@{
            Status=[string](ServerUIGet $w.Reachability Status '')
            CheckedAtUtc=(ServerUIGet $w.Reachability CheckedAtUtc $null)
            Port=[int](ServerUIGet $w.Reachability Port ([int](ServerUIGet $w InvitePort 18443)))
        }
    }
    $servers=@(foreach($target in @(GetTCWebInviteTargetsUI)){[ordered]@{Id=[string]$target.Id;Name=[string]$target.Name;Host=[string]$target.Host;Lines=@($target.Lines);SavedLogin=[bool]$target.SavedLogin}})
    return [ordered]@{
        InviteSessionId=[string](ServerUIGet $w SessionId '');Epoch=[int](ServerUIGet $w Epoch 0)
        Phase=[string](ServerUIGet $w Phase 'Idle');StageLabel=[string](ServerUIGet $w StageLabel '')
        StageChangedAtUtc=(ServerUIGet $w StageChangedAtUtc $null)
        ServerId=[string](ServerUIGet $w ServerId '');LifetimeSeconds=[int](ServerUIGet $w LifetimeSeconds $script:WebInviteLifetimeDefault)
        LifetimePresets=@($script:WebInviteLifetimePresets);LifetimeMin=[int]$script:WebInviteLifetimeMin;LifetimeMax=[int]$script:WebInviteLifetimeMax
        InviteId=[string](ServerUIGet $w InviteId '');State=[string](ServerUIGet $w State '')
        ExpiresAtUtc=(ServerUIGet $w ExpiresAtUtc $null);RetryUntilUtc=(ServerUIGet $w RetryUntilUtc $null)
        Reachability=$reachability;CodePresent=[bool](ServerUIGet $w CodePresent $false);CodePreview=[string](ServerUIGet $w CodePreview '')
        CompatNoteVisible=(GetTCWebInviteCompatNoteVisible $w)
        Servers=$servers
        # 0.22.2: where this visit came from, so 「完成」 can go back there.
        Origin=[string]$script:WebInviteOrigin
        ErrorCode=[string](ServerUIGet $w ErrorCode '');ErrorMessage=[string](ServerUIGet $w ErrorMessage '')
        NextAction=[string](ServerUIGet $w NextAction 'None')
    }
}
function DenyTCWebInvite {param([string]$Message='这一步没有生效，请重试',$Sequence=$null)
    # Same contract as DenyTCWebPair: a dropped intent would leave pendingIntent
    # set, every button disabled, and nothing on screen explaining why.
    if($null -ne $Sequence){
        $value=0
        if(($Sequence -is [int] -or $Sequence -is [long]) -and [long]$Sequence -ge 1 -and [long]$Sequence -le 2147483647){$value=[long]$Sequence}
        if($value -gt $script:WebAck){$script:WebAck=$value;Write-TCPerfTrace 'first-ack'}
    }
    Toast $Message;SyncTCWebState -Force
}
function SendTCWebInviteCodeUI {
    # A2 Reveal: the code leaves the host exactly once, in its own message. It is
    # never part of a snapshot, so a logged snapshot cannot contain it.
    $code=GetTCWebInviteCode
    if(-not $code){return $false}
    if(-not $script:WebReady -or -not $script:WebShell){return $false}
    try{
        $core=$script:WebShell.CoreWebView2
        if(-not $core){return $false}
        $json=@{Type='inviteCode';Id=[string](ServerUIGet $script:WebInvite InviteId '');Code=$code}|ConvertTo-Json -Depth 4 -Compress
        $core.PostWebMessageAsJson($json)
        return $true
    }catch{return $false}
}
function StartTCWebInviteReachabilityUI {
    # A4: stage three of the flow. TCP connect + TLS handshake only; no token and no
    # application data, so the probe can neither consume nor extend an invitation.
    # The result describes this computer's network, never the server's health.
    $w=$script:WebInvite;$m=$script:DeployUI.Management
    if(-not $w){return}
    $port=[int](ServerUIGet $w InvitePort 18443)
    $publicHost=[string](ServerUIGet $w PublicHost '')
    $tls=[string](ServerUIGet $w TlsSha256 '')
    if(-not $publicHost -or $tls -cnotmatch '^[A-Fa-f0-9]{64}$' -or -not (Get-Command Test-TCPairOnlineReachability -ErrorAction SilentlyContinue)){
        # Without a pinned TLS identity there is nothing honest to compare, so the
        # stage is skipped instead of showing a made-up result.
        $w.Reachability=$null
        SetTCWebInvitePhase 'Open'
        return
    }
    $context=@{Type='Invite';SessionId=[string]$w.SessionId;InviteId=[string]$w.InviteId;Port=$port}
    $w.Reachability=@{Status='Checking';CheckedAtUtc=$null;Port=$port}
    SetTCWebInvitePhase 'Checking'
    try{
        StartUiCommand -Module 'PairingOnline.psm1' -Command 'Test-TCPairOnlineReachability' -Arguments @{PublicHost=$publicHost;Port=$port;TlsSha256=$tls;TimeoutSeconds=$script:WebInviteReachabilityTimeoutSeconds} -Context $context -Complete {
            param($data,$inner)
            $current=$script:WebInvite
            if(-not $current -or [string](ServerUIGet $inner SessionId '') -cne [string](ServerUIGet $current SessionId '') -or [string](ServerUIGet $inner InviteId '') -cne [string](ServerUIGet $current InviteId '')){return}
            # 0.22.0 A4: the invitation exists either way, so a failed probe lowers
            # the phase to Open and keeps its own sentence in Reachability.
            $current.Reachability=@{Status=[string](WebField $data Status 'Error');CheckedAtUtc=(ConvertTCWebUtcStamp (WebField $data CheckedAtUtc $null));Port=[int](ServerUIGet $inner Port 18443)}
            SetTCWebInvitePhase 'Open'
        } -Failed {
            param($message,$inner,$failure)
            $current=$script:WebInvite
            if(-not $current -or [string](ServerUIGet $inner SessionId '') -cne [string](ServerUIGet $current SessionId '')){return}
            $current.Reachability=@{Status='Error';CheckedAtUtc=(GetTCWebInviteStamp);Port=[int](ServerUIGet $inner Port 18443)}
            SetTCWebInvitePhase 'Open'
        } -Message '正在检查 18443 能否连通…'
    }catch{
        $w.Reachability=@{Status='Error';CheckedAtUtc=(GetTCWebInviteStamp);Port=$port}
        SetTCWebInvitePhase 'Open'
    }
}
function RecheckTCWebInviteUI {
    InitializeTCWebInvite;$w=$script:WebInvite
    if([string]$w.State -cne 'Open' -or -not $w.InviteId){SetTCWebInviteFailure '只有当前有效邀请可以重新检查。' 'InviteRecheckUnavailable' 'None';return}
    if($w.Phase -in @('Loading','LoggingIn','Creating','Checking')){SetTCWebInviteFailure '上一步还没有结束，请稍候。' 'InviteBusy' 'None';return}
    if(-not [string]$w.PublicHost -or [string]$w.TlsSha256 -cnotmatch '^[A-Fa-f0-9]{64}$'){SetTCWebInviteFailure '本机没有这个邀请的探测身份，无法重新检查。' 'InviteRecheckUnavailable' 'None';return}
    StartTCWebInviteReachabilityUI
}
function ConvertTCWebInviteUtc {param($Value)
    # StartedAtUtc is stored as a '<utc>Z' string. Casting that to [DateTime] yields a
    # Local-kind value, so `UtcNow - that` would be off by the machine's UTC offset:
    # the 30 s/60 s cadence would never slow down and the two hour stop would never
    # trip east of UTC. Parse to UTC ticks instead.
    if($null -eq $Value){return $null}
    if($Value -is [DateTime]){
        if($Value.Kind -eq [DateTimeKind]::Utc){return $Value}
        return $Value.ToUniversalTime()
    }
    $text=[string]$Value
    if(-not $text){return $null}
    $parsed=[DateTimeOffset]::MinValue
    $styles=[Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
    if([DateTimeOffset]::TryParse($text,[Globalization.CultureInfo]::InvariantCulture,$styles,[ref]$parsed)){return $parsed.UtcDateTime}
    return $null
}
function PollTCWebInviteUI {
    # 0.22.0 §6.3 cadence, driven by the main timer:
    #   entered -> one read; deadline reached -> one read;
    #   open and visible -> every 30 s for the first 10 minutes, then every 60 s;
    #   after 2 hours the automatic read stops and only 「刷新状态」 remains;
    #   leaving the page or hiding the window stops it.
    $w=$script:WebInvite
    if(-not $w){return}
    if([string](Get-Variable -Name Page -Scope Script -ValueOnly -ErrorAction SilentlyContinue) -cne 'web'){return}
    if([string](Get-Variable -Name WebPage -Scope Script -ValueOnly -ErrorAction SilentlyContinue) -cne 'invite'){return}
    $window=Get-Variable -Name Window -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if($window){
        if($window.WindowState -eq 'Minimized'){return}
        if(-not $window.IsVisible){return}
    }
    if([string](ServerUIGet $w State '') -cne 'Open' -or [string](ServerUIGet $w Phase '') -cne 'Open'){return}
    $now=[DateTime]::UtcNow
    $age=0
    $started=ConvertTCWebInviteUtc (ServerUIGet $w StartedAtUtc $null)
    if($started){$age=($now-$started).TotalSeconds}
    if($age -gt 7200){return}
    $expires=[DateTimeOffset]::MinValue
    if([string](ServerUIGet $w ExpiresAtUtc '') -and [DateTimeOffset]::TryParse([string]$w.ExpiresAtUtc,[ref]$expires)){
        if($expires -le [DateTimeOffset]$now -and -not [bool](ServerUIGet $w ExpiryRefreshDone $false)){
            # The countdown reached zero: ask once whether it really expired, then
            # leave the state to the server.
            $w.ExpiryRefreshDone=$true
            RefreshTCWebInviteStatusUI
            return
        }
        if($expires -le [DateTimeOffset]$now){return}
    }
    if($script:DeployUI.PendingManagement){return}
    $interval=if($age -le 600){30}else{60}
    $last=[DateTime](ServerUIGet $w PollAt ([DateTime]::MinValue))
    if(($now-$last).TotalSeconds -lt $interval){return}
    $w.PollAt=$now
    RefreshTCWebInviteStatusUI
}
function OpenTCWebInvitePageUI {param([string]$ServerId='',[string]$LineId='',[int]$LifetimeSeconds=0,[ValidateSet('','lines','server')][string]$Origin='')
    # The page entry: resolve the one server, reset the model, take the driver and
    # show the page. A create is never started here - the operator picks the
    # lifetime and presses 生成邀请码.
    if($script:ReadOnly){DenyTCWebInvite '当前是只读检查窗口，没有打开邀请页。';return $false}
    if($script:DeployUI.PendingManagement){
        # 0.22.2: this used to be a permanent refusal, and the previous visit could
        # leave the flag set forever. The page now says it is settling and retries.
        DenyTCWebInvite '上一步还在收尾，请稍候…';return $false
    }
    $target=ResolveTCWebInviteServerUI $ServerId $LineId
    if(-not $target){
        switch([string]$script:TCWebInviteResolveReason){
            'Ambiguous'{DenyTCWebInvite '这台电脑可以邀请的服务器不止一台，请先选择一条线路。'}
            'NotManageable'{DenyTCWebInvite '这条线路没有可管理的服务器记录，或这台电脑只有使用权。'}
            default{DenyTCWebInvite '没有可管理的服务器；请先在服务器与设备里登录并启用管理能力。'}
        }
        return $false
    }
    if($Origin){$script:WebInviteOrigin=$Origin}
    # 0.22.2 WP-5: coming back to the same still-open invitation resumes it. The
    # model and the code survive the visit (ClearTCWebInvite no longer drops them),
    # so a second entry must not reset them - that is what made the feature look
    # one-shot.
    $existing=$script:WebInvite
    $live=ServerUIGet $script:DeployUI.Management OnlineInvite
    $openHere=($existing -and [string]$existing.ServerId -ceq [string]$target.Id -and [string]$existing.InviteId -and [string]$existing.State -ceq 'Open')
    # The completion may have arrived while the page was closed (that is the fix in
    # WP-4), so the management model can be ahead of this one. Both count as "this
    # invitation is still open"; the model is caught up instead of being reset.
    $openThere=($live -and [string]$live.State -ceq 'Open' -and $existing -and [string]$existing.ServerId -ceq [string]$target.Id)
    if($openHere -or $openThere){
        if(-not $openHere -and $live){
            $existing.InviteId=[string](ServerUIGet $live InviteId '')
            $existing.State=[string](ServerUIGet $live State '')
            $existing.ExpiresAtUtc=(ServerUIGet $live ExpiresAtUtc $null)
            $existing.RetryUntilUtc=(ServerUIGet $live RetryUntilUtc $null)
            if([string](ServerUIGet $live InvitationCode '')){SetTCWebInviteCode ([string]$live.InvitationCode)}
        }
        $null=SetTCWebInviteDriver
        if(Get-Command NavigateTCWebPage -ErrorAction SilentlyContinue){$null=NavigateTCWebPage 'invite'}
        if(-not $existing.Epoch){$existing.Epoch=[int]$script:WebInviteEpoch}
        SyncTCWebState -Force
        return $true
    }
    $lifetime=if($LifetimeSeconds){[int]$LifetimeSeconds}elseif($script:WebInvite){[int](ServerUIGet $script:WebInvite LifetimeSeconds (GetTCWebInviteLifetimePreference))}else{GetTCWebInviteLifetimePreference}
    ClearTCWebInvite
    $w=ResetTCWebInvite $target.Id $lifetime
    $null=SetTCWebInviteDriver
    if(Get-Command NavigateTCWebPage -ErrorAction SilentlyContinue){$null=NavigateTCWebPage 'invite'}
    # An invitation this computer still owns is adopted from the management model,
    # so coming back to the page shows the open invitation instead of a blank form.
    $m=$script:DeployUI.Management
    if($m -and [string]$m.ServerId -ceq [string]$target.Id -and $m.Authenticated -and $m.SessionRef){UpdateTCWebInviteFromManagement}
    elseif(-not [bool]$target.SavedLogin){
        $w.ErrorCode='SavedLoginRequired';$w.ErrorMessage='这台服务器没有保存登录资料';$w.NextAction='OpenServer'
        SetTCWebInvitePhase 'Idle'
    }
    if(-not $w.Epoch){$w.Epoch=[int]$script:WebInviteEpoch}
    SyncTCWebState -Force
    # 进入刷新一次: only a read, and only when an invitation is actually open.
    if([string](ServerUIGet $w InviteId '') -and [string](ServerUIGet $w State '') -ceq 'Open'){RefreshTCWebInviteStatusUI}
    return $true
}
function SelectTCWebInviteServerUI {param([string]$ServerId)
    # 多台服务器时的单选。切服务器等于换一张邀请：上一张的码、结果和重登额度都不留下。
    InitializeTCWebInvite
    $w=$script:WebInvite
    if(-not $w -or -not $ServerId){DenyTCWebInvite '这一步没有生效，请重试';return}
    if($w.Phase -in @('Loading','LoggingIn','Creating','Checking')){DenyTCWebInvite '上一步还没有结束，请稍候';return}
    $target=ResolveTCWebInviteServerUI $ServerId
    if(-not $target){DenyTCWebInvite '这台服务器现在不能管理，请先在服务器与设备里登录。';return}
    if([string]$w.ServerId -ceq [string]$target.Id){SyncTCWebState -Force;return}
    $lifetime=[int](ServerUIGet $w LifetimeSeconds $script:WebInviteLifetimeDefault)
    ClearTCWebInvite
    $w=ResetTCWebInvite $target.Id $lifetime
    $null=SetTCWebInviteDriver
    $null=SelectServerStateUI $target.Id
    if(-not $script:ServerSelectionStateUI){$null=SetTCWebInviteDriver;SyncTCWebState -Force;return}
    if((-not $script:DeployUI.Management.Authenticated -or -not $script:DeployUI.Management.SessionRef) -and -not [bool]$target.SavedLogin){
        $w.ErrorCode='SavedLoginRequired';$w.ErrorMessage='这台服务器没有保存登录资料';$w.NextAction='OpenServer'
        SetTCWebInvitePhase 'Idle'
    }
    SyncTCWebState -Force
    if($w.InviteId){RefreshTCWebInviteStatusUI}
}
function CopyTCWebInviteUI {
    $code=GetTCWebInviteCode
    if(-not $code){DenyTCWebInvite '邀请码不在这台电脑上，请重新生成';return $false}
    if(Get-Command CopyText -ErrorAction SilentlyContinue){$null=CopyText -Text $code -Done '已复制邀请码'}
    return $true
}
function OpenTCWebInviteServerPageUI {param([string]$Notice='',[switch]$Offline,[ValidateSet('','Login')][string]$Intent='')
    # Login and offline navigation both preserve the public invite return context.
    $w=$script:WebInvite
    $serverId=if($w){[string](ServerUIGet $w ServerId '')}else{''}
    if(-not $serverId){DenyTCWebInvite '还没有选择服务器。';return $false}
    if($Offline){
        if(Get-Command OpenServerOfflineInviteUI -ErrorAction SilentlyContinue){
            OpenServerOfflineInviteUI -Origin WebInvite -ServerId $serverId
            if($Notice){Toast $Notice}
            return $true
        }
        DenyTCWebInvite '离线邀请子视图暂不可用。';return $false
    }
    ClearTCWebInvite
    InitializeServerUI
    if($Intent -ceq 'Login'){
        # 登录直达：登录阶段必须在渲染前给出，加载由登录页自己承接，
        # 不再先落到「线路的服务器与设备」这个绑定中间页。
        $script:DeployUI.Management.LoginStage='Method'
        $script:DeployUI.Management.LoginReturn='detail'
    }
    if(Get-Command OpenServerRecordManagement -ErrorAction SilentlyContinue){OpenServerRecordManagement $serverId -ReturnKind Context -Intent $Intent}
    # Set after the navigation: the record entry clears any half-finished login so a
    # previous page cannot answer for this one, and this request is the newest one.
    # 非登录入口保持原有的导航后设置，行为与 0.22.4 一致。
    if($Intent -cne 'Login'){
        $script:DeployUI.Management.LoginStage='Method'
        $script:DeployUI.Management.LoginReturn='detail'
    }
    if($Notice){Toast $Notice}
    return $true
}
function OpenTCWebInviteFromServerPageUI {
    # Entry 3: 「服务器与设备」 → 「邀请其他电脑」. It hands the current server to the
    # web page instead of growing a second copy of the flow on the WPF surface.
    $m=$script:DeployUI.Management
    if(-not $m -or -not [string]$m.ServerId){return}
    $null=OpenTCWebInvitePageUI ([string]$m.ServerId) -Origin 'server'
}
function OpenLineServerInviteUI {param([string]$LineId)
    # 0.22.0 A8: the degraded shell's line-card menu entry. The 「设备与邀请」 card is
    # the first card on the server page, so opening that page for this line is
    # landing on the invitation area; B4 adds real section anchors later. The
    # entry only exists where an invitation can actually be created (A-16).
    if(-not $LineId){return}
    $binding=@{CanInvite=$false;ServerRecordId=''}
    try{$binding=GetTCWebLineInviteBindingUI $LineId}catch{$binding=@{CanInvite=$false;ServerRecordId=''}}
    if(-not [bool]$binding.CanInvite){if(Get-Command Toast -ErrorAction SilentlyContinue){Toast '这条线路没有可管理的服务器记录'};return}
    if(Get-Command OpenLineServerManagement -ErrorAction SilentlyContinue){OpenLineServerManagement $LineId -ReturnKind Nodes}
}
function InvokeTCWebInviteMessage {param($Message)
    # Every public action has one meaning; refused intents advance Ack and publish
    # an error instead of leaving the browser's pendingIntent stuck.
    $phase=[string](WebField $Message Phase '');$id=[string](WebField $Message Id '');$value=WebField $Message Value $null;$sequence=WebField $Message Sequence $null
    if($phase -cnotin @('Begin','SelectServer','Create','CreateNew','SetLifetime','Copy','Reveal','Refresh','Recheck','Cancel','CancelRetry','Rearm','Retry','OpenServer','Offline','Close')){
        DenyTCWebInvite '这一步没有生效，请重试' $sequence;return
    }
    if($phase -ceq 'Close'){
        # 0.22.2: 「完成」 means "leave, the invitation stays". It also has to go back
        # to where the operator came from - the server page entry used to be dumped
        # on the lines list.
        $origin=[string]$script:WebInviteOrigin
        $serverId=[string](ServerUIGet $script:WebInvite ServerId '')
        ClearTCWebInvite
        $script:WebInviteOrigin='lines'
        if($origin -ceq 'server' -and $serverId -and -not $script:DeployUI.PendingManagement -and (Get-Command OpenServerRecordManagement -ErrorAction SilentlyContinue)){
            OpenServerRecordManagement $serverId -ReturnKind Context
        }elseif(Get-Command NavigateTCWebPage -ErrorAction SilentlyContinue){$null=NavigateTCWebPage 'lines'}
        SyncTCWebState -Force;return
    }
    if($script:ReadOnly -and $phase -notin @('Copy','Reveal','Refresh','OpenServer','Offline')){
        DenyTCWebInvite '当前是只读检查窗口，没有执行这个操作。' $sequence;return
    }
    switch -CaseSensitive ($phase){
        'Begin'{
            $serverId=if($value){[string]$value}else{''};$lineId=if($id){[string]$id}else{''}
            # The web entries all come from 线路; only the server page passes -Origin.
            $script:WebInviteOrigin='lines'
            if(-not (OpenTCWebInvitePageUI $serverId $lineId)){return}
            return
        }
        'SelectServer'{SelectTCWebInviteServerUI $(if($value){[string]$value}else{[string]$id});SyncTCWebState -Force;return}
        {$_ -in @('Create','CreateNew')}{
            $seconds=0
            if($value -is [int] -or $value -is [long]){$seconds=[int]$value}
            elseif([string]$value -match '^\d{1,6}$'){$seconds=[int]$value}
            if($seconds -lt $script:WebInviteLifetimeMin -or $seconds -gt $script:WebInviteLifetimeMax){DenyTCWebInvite '邀请码有效期必须在 10 分钟到 24 小时之间。' $sequence;return}
            StartTCWebInviteUI -LifetimeSeconds $seconds;SyncTCWebState -Force;return
        }
        'SetLifetime'{
            $seconds=0
            if($value -is [int] -or $value -is [long]){$seconds=[int]$value}
            elseif([string]$value -match '^\d{1,6}$'){$seconds=[int]$value}
            if(-not (SetTCWebInviteLifetime $seconds)){DenyTCWebInvite '邀请码有效期未能保存。' $sequence;return}
            SyncTCWebState -Force;return
        }
        'Copy'{if(CopyTCWebInviteUI){SyncTCWebState -Force}else{DenyTCWebInvite '邀请码不在这台电脑上，请重新生成' $sequence};return}
        'Reveal'{if(-not (SendTCWebInviteCodeUI)){DenyTCWebInvite '邀请码不在这台电脑上，请重新生成' $sequence;return};SyncTCWebState -Force;return}
        'Refresh'{RefreshTCWebInviteStatusUI;SyncTCWebState -Force;return}
        'Recheck'{RecheckTCWebInviteUI;SyncTCWebState -Force;return}
        'Cancel'{CancelTCWebInviteUI;SyncTCWebState -Force;return}
        'CancelRetry'{CancelAndRetryTCWebInviteUI;SyncTCWebState -Force;return}
        'Rearm'{RearmTCWebInviteUI;SyncTCWebState -Force;return}
        'Retry'{RetryTCWebInviteUI;SyncTCWebState -Force;return}
        'OpenServer'{
            # 只有「需要登录」这一类错误走登录直达；身份核对、结果待确认等仍进服务器页。
            $intent=if([string](ServerUIGet $script:WebInvite ErrorCode '') -cin @('SavedLoginRequired','SavedLoginUnavailable','ManagementLoginRequired')){'Login'}else{''}
            if(-not (OpenTCWebInviteServerPageUI -Intent $intent)){DenyTCWebInvite '服务器页暂时无法打开。' $sequence};return
        }
        'Offline'{if(-not (OpenTCWebInviteServerPageUI -Offline -Notice '已打开离线邀请（24 小时）子视图。')){DenyTCWebInvite '离线邀请子视图暂时无法打开。' $sequence};return}
    }
    DenyTCWebInvite '这一步没有生效，请重试' $sequence
}
