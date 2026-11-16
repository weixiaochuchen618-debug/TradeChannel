# Server management is a separate SSH management session, never a local activation.
# Secrets stay in GUI memory/secure pipe. Smoke captures intentions, no connections.
if(-not (Get-Command SetNavigationContext -ErrorAction SilentlyContinue)){
 $navigationHelper=Join-Path $PSScriptRoot 'NavigationContext.ps1'
 if(Test-Path -LiteralPath $navigationHelper){. $navigationHelper}
}
function ServerUIGet {param($Value,[string]$Name,$Default=$null)
 if($Value -is [Collections.IDictionary]){if($Value.Contains($Name)){return $Value[$Name]}}
 elseif($null -ne $Value -and $Value.PSObject.Properties[$Name]){return $Value.$Name};return $Default
}
function ServerUIReadOnly {$flag=Get-Variable -Name ReadOnly -Scope Script -ErrorAction SilentlyContinue;return ($flag -and [bool]$flag.Value)}
function UIProductPath {param([string]$Leaf) return Join-Path (Split-Path $PSScriptRoot -Parent) $Leaf}
function ManagementLabel {param([string]$Value)
 $labels=@{Applied='已部署';Uninstalled='服务已卸载';NotInstalled='尚未部署';OwnedNotInstalled='部署未完成';NeedsRecovery='需要恢复';AwaitIdentityVerification='等待身份核验';Unverified='尚未核验';Managed='已识别归属';Authenticated='管理账户已验证';NeedsAuthentication='需要管理登录';ConnectorOnly='仅有连接使用权';Authorized='已授权';Revoked='已撤销';Inactive='服务未启用';Open='待使用';Consumed='已使用';Cancelled='已取消';Expired='已过期';Prepared='已准备';Dispatched='已提交';Running='处理中';OutcomeUnknown='结果待确认';AuthorizedReturnPending='已授权，等待交接';Completed='已完成';Complete='已完成';Rejected='未执行成功';Failed='需要处理';WaitingUser='等待继续';ReadyInactive='已准备，尚未启用';MaterializeCandidate='准备本机线路';ProbeCandidate='检查待使用线路';Inspect='检查环境';PrepareAccess='准备登录';PlanReady='等待确认变更';ApplyOrAuthorize='部署或授权';ServerInfo='读取服务器状态';Devices='读取设备';Authenticate='管理登录';InviteCreate='生成邀请';InviteCancel='取消邀请';AuthorizeExternal='授权新电脑';TransportPlan='准备连接方式预览';TransportApply='添加连接方式';ReconcileServer='检查服务器结果';ReconcileInvite='检查原邀请';ReconcilePairInvite='检查原申请';ReconcileDevices='检查设备状态';Recover='恢复未完成操作';Rename='更新设备名称';Revoke='撤销指定设备';Uninstall='卸载自有服务';management_apply='启用管理能力';device_rename='更新设备名称';invite_create='生成邀请';invite_cancel='取消邀请';authorize_external='授权新电脑';transport_apply='添加连接方式';request_status='查询原申请'}
 $labels.Archived='重装前身份已归档';$labels.ReinstallObserve='检查新 SSH 身份';$labels.ReinstallTrust='等待确认新指纹';$labels.ReinstallAuthenticate='认证已确认的新指纹';$labels.ReinstallConfirm='建立新的管理记录'
 $labels.InvitationPinned='邀请接入';$labels.OnlineInviteCreate='生成邀请码';$labels.OnlineInviteStatus='查询邀请码';$labels.OnlineInviteCancel='取消邀请码';$labels.OnlineInviteReconcile='检查邀请码';$labels.pair_online_create='生成邀请码';$labels.pair_online_cancel='取消邀请码';$labels.pair_online_status='查询邀请码'
 if($labels.ContainsKey($Value)){return $labels[$Value]};return '需要检查'
}
function ManagementDetails {param($Parent,[string]$Text,[string]$Title='技术详情')
 $expand=New-Object Windows.Controls.Expander;$expand.Header=$Title;$expand.Margin='0,8,0,0';$expand.IsExpanded=$false;$expand.Content=T $Text 11.5 $script:Text3;AddC $Parent $expand;return $expand
}
function ManagementTime {param($Value)try{return ([DateTimeOffset]::Parse([string]$Value)).LocalDateTime.ToString('MM-dd HH:mm')}catch{return '时间未知'}}
function ServerErrorText {param([string]$Code)
 switch($Code){
  'MissingManagementDependency'{'服务器缺少 OpenSSL，请在组件准备步骤安装后重新预览。查询状态不会自动安装。'}
  'PlanExpired'{'预览已过期。请重新检查并生成预览，原设备申请保留。'}
  'RevisionConflict'{'服务器配置已变化，请刷新服务器与设备后重新确认变更。'}
  'ApprovalMismatch'{'确认信息与当前目标或配置不匹配，请重新预览。'}
  'InviteUnavailable'{'邀请已取消或过期，请由管理端重新生成邀请。'}
  'InviteConsumed'{'邀请已被其他申请使用，请检查原申请和设备列表，避免重复添加设备。'}
  'InvalidSignature'{'签名不匹配，请确认来源后重新复制完整邀请或申请。'}
  'NeedsRecovery'{'服务器有未完成操作，请先使用「检查与恢复未完成操作」检查结果。'}
  'TransportAlreadyEnabled'{'此服务器已配置 TCP。新增向导只处理 UDP 增加 TCP，不覆盖现有 TCP 认证和参数。'}
  'NodeUninstalled'{'服务已卸载。保留的记录和身份不能用于连接。'}
  'AuthorizationConflict'{'这份申请、设备或密钥已注册或已撤销，请查询原申请结果或按新身份流程处理。'}
  'AddressPoolExhausted'{'没有空闲设备地址。已退役地址不会自动复用，需要管理员安排网段维护。'}
  'OnlineOwnershipMismatch'{'服务器上的邀请码服务文件与本机记录不一致，为安全起见没有生成新邀请码；当前连接不受影响。可以改用下方的离线邀请，或把诊断代码发给维护人员。'}
  'OnlineMaintenanceDeferred'{'服务器上还有一张未到期的邀请码，本机没有它的内容。继续生成会作废那张邀请码，已经拿到它的电脑将无法加入。'}
  'OnlineTlsCertificateExpired'{'服务器的邀请服务证书剩余时间不足以覆盖这个有效期。请先取消未到期的邀请码再重新生成；仍然失败时，用 SSH 修复服务器上的邀请服务。'}
  'OnlineServiceStartFailed'{'服务器上的邀请码服务没有启动成功。请稍后重试；仍然失败时可以改用离线邀请。'}
  'OnlineEndpointMismatch'{'服务器的公开地址与本机记录不一致。请先点「刷新服务器与设备」，再生成邀请码。'}
  'OnlinePortConflict'{'邀请码使用的 TCP 18443 端口与服务器已有的连接端口冲突，没有生成邀请码。'}
  'OnlineInstallationConflict'{'服务器上已有的邀请码服务属于不同的地址或管理身份，没有覆盖它。'}
  'OnlineServerChanged'{'服务器身份或管理身份已变化。请重新登录并刷新服务器与设备后再生成。'}
  'OnlineSigningIdentityChanged'{'服务器的管理签名身份已变化。请重新登录并刷新服务器与设备后再生成。'}
  'OnlinePrivilegeRequired'{'当前 SSH 账户没有 root 权限，无法在服务器上启动邀请码服务。'}
  'InviteLimit'{'服务器上的邀请记录已达上限，需要先做管理维护才能继续生成。'}
  default{'操作未完成，请保留原资料并检查状态。具体原因见技术详情。'}
 }
}
function InitializeServerUI {
 if(-not $script:DeployUI.Management){$script:DeployUI.Management=@{ServerId=$null;Server=$null;Info=$null;SessionRef=$null;Credential=$null;Authenticated=$false;TrustShown=$null;LastPoll=[DateTime]::MinValue;Error='';Input=@{DeviceName='新电脑';TcpPort='443';ServerName='www.bing.com';RenameId='';RenameName='';KeyPath='';InviteLifetimeSeconds=$(if(Get-Command GetOnlineInviteLifetimePreferenceUI -ErrorAction SilentlyContinue){GetOnlineInviteLifetimePreferenceUI}else{1800});InviteLifetimeCustom=$false;InviteLifetimeAmount='';InviteLifetimeUnit='Minutes'};Preview=$null;InviteHistory=@();Driver='';LoginStage='';LoginMethod='';LoginReturn='';LoginSecret=$null;RecordStale=$false;RememberCredential=$true;SavedLoginInfo=$null;SavedLoginNotice='';PendingCredentialReplace=$null}}
}
function InitializeServerNavigationUI {
 if(-not (Get-Variable ServerNavigationUI -Scope Script -ErrorAction SilentlyContinue) -or -not $script:ServerNavigationUI){
  $script:ServerNavigationUI=@{View='server-list';ReturnKind='DeploymentCenter';ReturnContext=$null;LineId='';Line=$null;SelectedServerId='';DetailKind='Managed';Message='';Bindings=@();RequestId='';Loading=$false;ShowArchived=$false;OfflineOrigin='';PendingIntent=''}
 }
}
function SetServerNavigationPositionUI {
 InitializeServerNavigationUI
 if(Get-Command SetNavigationContext -ErrorAction SilentlyContinue){SetNavigationContext -Section nodes -View $script:ServerNavigationUI.View -TargetId $(if($script:ServerNavigationUI.SelectedServerId){$script:ServerNavigationUI.SelectedServerId}else{$script:ServerNavigationUI.LineId})}
}
function OpenServerManagement {param([ValidateSet('Nodes','LineProfiles','DeploymentCenter','Context')][string]$ReturnKind='DeploymentCenter')
 if((IsBusy) -or (Get-Variable QueuedJob -Scope Script -ValueOnly -ErrorAction SilentlyContinue)){return}
 if($script:DeployUI.PendingManagement){ErrorDialog '当前操作尚未结束，请确认结果后再切换服务器。';return};$script:AutoTCP=$null
 $context=$null;if(Get-Command CaptureNavigationContext -ErrorAction SilentlyContinue){$context=CaptureNavigationContext}
 $script:ServerNavigationUI=$null;InitializeServerNavigationUI
 $script:ServerNavigationUI.ReturnKind=$ReturnKind;$script:ServerNavigationUI.ReturnContext=$context
 InitializeServerUI;$script:DeployUI.Management.ReadContinuation='';$script:DeployUI.ManagementMode=$true
 ShowServerManagement
}
function ClearServerLoginStateUI {
 # 0.23.0: the login card's three fields belong to one visit of one page. Every entry
 # into a page that renders its own credential form clears them, so a leftover
 # LoginMethod can never decide where that page's credential comes from.
 $model=ServerUIGet $script:DeployUI Management $null
 if($model){$model.LoginStage='';$model.LoginMethod='';$model.LoginSecret=$null}
}
function ReturnFromServerManagement {
 InitializeServerNavigationUI;$n=$script:ServerNavigationUI
 ClearServerLoginStateUI
 # Invalidate read callbacks before leaving. It does not cancel or retry a mutation.
 $n.RequestId='';$n.Loading=$false
 switch($n.ReturnKind){
  LineProfiles{if($n.LineId){LoadLineConnections $n.LineId -MaintenanceMode:([string](ServerUIGet $n.ReturnContext View '') -ceq 'line-maintenance');return}}
  Nodes{ShowNodes;FetchNodes;return}
  Context{if($n.ReturnContext -and (Get-Command ReturnNavigationContext -ErrorAction SilentlyContinue)){ReturnNavigationContext -Context $n.ReturnContext;return}}
 }
 ShowSetupCenter
}
function ShowServerListUI {
 InitializeServerNavigationUI;$script:ServerNavigationUI.View='server-list';$script:ServerNavigationUI.DetailKind='Managed';$script:ServerNavigationUI.Message='';$script:ServerNavigationUI.Loading=$false;$script:ServerNavigationUI.RequestId='';$script:ServerNavigationUI.PendingIntent=''
 ClearServerLoginStateUI
 ShowServerManagement
}
function OpenLineServerManagement {param([string]$LineId,[ValidateSet('Nodes','LineProfiles')][string]$ReturnKind='LineProfiles')
 if((IsBusy) -or -not $LineId -or (Get-Variable QueuedJob -Scope Script -ValueOnly -ErrorAction SilentlyContinue)){return}
 if($script:DeployUI.PendingManagement){ErrorDialog '当前操作尚未结束，请确认结果后再切换服务器。';return};$script:AutoTCP=$null
 $context=$null;if(Get-Command CaptureNavigationContext -ErrorAction SilentlyContinue){$context=CaptureNavigationContext}
 $script:ServerNavigationUI=$null;InitializeServerNavigationUI;$n=$script:ServerNavigationUI
 $n.View='server-detail';$n.DetailKind='Binding';$n.ReturnKind=$ReturnKind;$n.ReturnContext=$context;$n.LineId=$LineId;$n.Loading=$true;$n.RequestId=[guid]::NewGuid().ToString('N');$n.PendingIntent=''
 $requestId=$n.RequestId
 InitializeServerUI;$script:DeployUI.Management.ReadContinuation='';$script:DeployUI.ManagementMode=$true
 ShowServerManagement
 $completeHandler=${function:CompleteLineServerNavigationUI};$failedHandler=${function:FailLineServerNavigationUI}
 $complete={param($line)& $completeHandler $line $requestId}.GetNewClosure()
 $failed={param($message)& $failedHandler $requestId '无法读取这条线路的服务器关联，请刷新后重试。'}.GetNewClosure()
 # Navigation uses the read-only view; it never registers, prepares or activates a line.
 StartJob @{Action='LineProfiles';Id=$LineId} $complete '读取这条线路的服务器关联…' '' -Failed $failed
}
function OpenServerOfflineInviteUI {
 param([ValidateSet('WebInvite','ServerDevices')][string]$Origin,[string]$ServerId='')
 if($Origin -ceq 'WebInvite'){
  # Clear only the online code/driver; ResetTCWebInvite is not called, so the
  # public web/invite + server id return context remains available.
  if(Get-Command ClearTCWebInvite -ErrorAction SilentlyContinue){ClearTCWebInvite}
  if(-not $ServerId){$ServerId=[string](ServerUIGet $script:DeployUI.Management ServerId '')}
  OpenServerRecordManagement $ServerId -ReturnKind Context -OfflineOrigin WebInvite
  return
 }
 InitializeServerNavigationUI;$script:ServerNavigationUI.OfflineOrigin='ServerDevices'
 if($ServerId -and [string](ServerUIGet $script:DeployUI.Management ServerId '') -cne $ServerId){SelectServerUI $ServerId}
 $script:DeployUI.Management.DetailTab='devices'
 ShowServerOfflineInviteUI
}
function ReturnFromServerOfflineInviteUI {
 InitializeServerNavigationUI
 if($script:ServerNavigationUI.OfflineOrigin -ceq 'WebInvite'){ReturnFromServerManagement;return}
 $script:ServerNavigationUI.OfflineOrigin='';$script:ServerNavigationUI.View='server-detail'
 $script:DeployUI.Management.DetailTab='devices';ShowServerManagement
}
function OpenServerRecordManagement {param([string]$ServerId,[ValidateSet('Context','DeploymentCenter','Nodes')][string]$ReturnKind='Context',[ValidateSet('','WebInvite','ServerDevices')][string]$OfflineOrigin='',[ValidateSet('','Login')][string]$Intent='')
 if((IsBusy) -or -not $ServerId -or (Get-Variable QueuedJob -Scope Script -ValueOnly -ErrorAction SilentlyContinue)){return}
 if($script:DeployUI.PendingManagement){ErrorDialog '当前操作尚未结束，请确认结果后再切换服务器。';return};$script:AutoTCP=$null
 ClearServerLoginStateUI
 $context=$null;if(Get-Command CaptureNavigationContext -ErrorAction SilentlyContinue){$context=CaptureNavigationContext}
 $script:ServerNavigationUI=$null;InitializeServerNavigationUI;$n=$script:ServerNavigationUI
 $n.View='server-detail';$n.DetailKind=$(if($Intent -ceq 'Login'){'Managed'}else{'Binding'});$n.ReturnKind=$ReturnKind;$n.ReturnContext=$context;$n.SelectedServerId=$ServerId;$n.OfflineOrigin=$OfflineOrigin;$n.Loading=$true;$n.RequestId=[guid]::NewGuid().ToString('N');$n.PendingIntent=$Intent
 $requestId=$n.RequestId;InitializeServerUI;if($Intent -ceq 'Login'){$script:DeployUI.Management.LoginStage='Method';$script:DeployUI.Management.LoginReturn='detail'};$script:DeployUI.Management.ReadContinuation='';$script:DeployUI.ManagementMode=$true
 # 登录直达的快路径：本机记录本来就能直接读（邀请页已经在读同一份注册表），
 # 不必再启动 Worker 重扫部署中心 —— 那一步要 3-5 秒，是登录前唯一的等待。
 if($Intent -ceq 'Login'){
  $local=@()
  if($script:DeployUI.Discovery){$local=@(ServerUIGet $script:DeployUI.Discovery Servers @()|Where-Object {$_.LocalRecordId -ceq $ServerId})}
  if($local.Count -ne 1){
   try{Import-Module (UIProductPath 'ServerRegistry.psm1') -DisableNameChecking;$local=@(Get-TCServers -Root $script:Root|Where-Object {$_.LocalRecordId -ceq $ServerId})}catch{$local=@()}
  }
  if($local.Count -eq 1 -and (ServerUIGet $local[0] RecordState 'Active') -cne 'Archived'){
   if(-not $script:DeployUI.Discovery){$script:DeployUI.Discovery=[pscustomobject]@{ManagementServers=@();Servers=@($local);Runs=@();ContinueRuns=@();HasLegacyRecords=$false;NetworkChanged=$false}}
   else{$script:DeployUI.Discovery.Servers=@(@(ServerUIGet $script:DeployUI.Discovery Servers @())+@($local)|Sort-Object LocalRecordId -Unique)}
   $n.Loading=$false
   SelectServerUI $ServerId
   return
  }
 }
 ShowServerManagement
 $completeHandler=${function:CompleteServerRecordNavigationUI};$failedHandler=${function:FailLineServerNavigationUI}
 $complete={param($data)& $completeHandler $data $requestId $ServerId}.GetNewClosure()
 $failed={param($message)& $failedHandler $requestId '服务器记录暂时无法读取，请返回来源重试。'}.GetNewClosure()
 StartJob @{Action='DeploymentDiscover'} $complete '' '' -Failed $failed
}
function CompleteServerRecordNavigationUI {param($Data,[string]$RequestId,[string]$ServerId)
 if(-not (TestServerNavigationRequestUI $RequestId)){return}
 $script:DeployUI.Discovery=$Data;$script:DeployUI.ServerDiscoveryAttempted=$true;$script:ServerNavigationUI.Loading=$false
 $matches=@(ServerUIGet $Data Servers @()|Where-Object {$_.LocalRecordId -ceq $ServerId})
 if($matches.Count -ne 1){$script:ServerNavigationUI.Message='指定服务器记录不唯一或已不存在，请返回来源刷新。';ShowServerManagement;return}
 if((ServerUIGet $matches[0] RecordState 'Active') -eq 'Archived'){OpenArchivedServerUI $ServerId}else{SelectServerUI $ServerId;if($script:ServerNavigationUI.OfflineOrigin){ShowServerOfflineInviteUI}}
}
function TestServerNavigationRequestUI {param([string]$RequestId)
 InitializeServerNavigationUI
 return ($RequestId -and $script:ServerNavigationUI.RequestId -ceq $RequestId -and $script:Role -eq 'servers' -and $script:ServerNavigationUI.View -eq 'server-detail')
}
function FailLineServerNavigationUI {param([string]$RequestId,[string]$Message)
 if(TestServerNavigationRequestUI $RequestId){$script:ServerNavigationUI.Loading=$false;$script:ServerNavigationUI.Message=$Message;ShowServerManagement}
}
function CompleteLineServerNavigationUI {param($Line,[string]$RequestId)
 if(-not (TestServerNavigationRequestUI $RequestId)){return}
 $n=$script:ServerNavigationUI
 if([string](ServerUIGet $Line LineId '') -cne $n.LineId){$n.Loading=$false;$n.Message='读取结果不属于原线路，未选择任何服务器。';ShowServerManagement;return}
 $n.Line=$Line;$n.Bindings=@(ServerUIGet $Line ServerBindings @());$block=[string](ServerUIGet $Line ServerConnectionBlock '')
 if($block -or $n.Bindings.Count -ne 1){
  $n.Loading=$false
  $n.Message=if($block){[string](ServerUIGet $Line ServerConnectionMessage '服务器关联需要确认。')}elseif(-not $n.Bindings.Count){'这条线路没有关联的管理记录，可继续连接。管理前需确认服务器身份，不能仅凭地址关联。'}else{'这条线路对应多个服务器记录，请检查后选择。'}
  ShowServerManagement;return
 }
 $binding=$n.Bindings[0]
 if((ServerUIGet $binding RecordState 'Active') -ne 'Active'){$n.Loading=$false;$n.Message='此线路属于已归档的服务器身份，旧线路不能继续原授权。';ShowServerManagement;return}
 $serverId=[string]$binding.LocalRecordId;$key=[string](ServerUIGet $Line ServerPublicKey '')
 $completeHandler=${function:CompleteLineServerDiscoveryUI};$failedHandler=${function:FailLineServerNavigationUI}
 $complete={param($d)& $completeHandler $d $RequestId $serverId $key}.GetNewClosure()
 $failed={param($message)& $failedHandler $RequestId '服务器记录暂时无法读取，请重试。'}.GetNewClosure()
 StartJob @{Action='DeploymentDiscover'} $complete '检查关联的服务器记录…' '' -Failed $failed
}
function CompleteLineServerDiscoveryUI {param($Data,[string]$RequestId,[string]$ServerId,[string]$ServerPublicKey)
 if(-not (TestServerNavigationRequestUI $RequestId)){return}
 $script:DeployUI.Discovery=$Data;$script:DeployUI.ServerDiscoveryAttempted=$true
 $matches=@(ServerUIGet $Data Servers @()|Where-Object {$_.LocalRecordId -ceq $ServerId -and (ServerUIGet $_ RecordState 'Active') -ceq 'Active' -and [string](ServerUIGet $_ ServerPublicKey '') -ceq $ServerPublicKey})
 $script:ServerNavigationUI.Loading=$false
 if($matches.Count -ne 1){$script:ServerNavigationUI.Message='服务器记录或身份已变化，请重新读取线路关联。';ShowServerManagement;return}
 SelectServerUI $ServerId
}
function OpenArchivedServerUI {param([string]$ServerId)
 InitializeServerNavigationUI
 $records=@(ServerUIGet $script:DeployUI.Discovery Servers @()|Where-Object {$_.LocalRecordId -ceq $ServerId -and (ServerUIGet $_ RecordState 'Active') -ceq 'Archived'})
 if($records.Count -ne 1){ErrorDialog '归档记录已变化，请刷新服务器列表。';return}
 $script:ServerNavigationUI.View='server-detail';$script:ServerNavigationUI.DetailKind='Archived';$script:ServerNavigationUI.SelectedServerId=$ServerId;$script:ServerNavigationUI.ArchivedRecord=$records[0];$script:ServerNavigationUI.RequestId=''
 ShowServerManagement
}
function ReturnFromServerChildUI {
 InitializeServerNavigationUI;$script:DeployUI.Management.ReadContinuation='';$script:DeployUI.ManagementMode=$true
 if($script:DeployUI.Management.Server){$script:ServerNavigationUI.View='server-detail';$script:ServerNavigationUI.DetailKind='Managed';$script:ServerNavigationUI.SelectedServerId=$script:DeployUI.Management.ServerId}
 ShowServerManagement
}
function ManagementMutation {param([string]$Operation,$InputData)
 return ($Operation -in @('management_apply','device_rename','invite_create','invite_cancel','pair_online_create','pair_online_cancel','authorize_external','revoke','uninstall','transport_apply','recover') -or ($Operation -eq 'request_status' -and (ServerUIGet $InputData RefreshAuthorization $false)))
}
function ManagementIntentDirectory {return Join-Path (Join-Path $script:Root 'deployments') 'management-intents'}
function SaveManagementIntent {param($Intent)
 if($script:Smoke){return}
 Import-Module (UIProductPath 'DeploymentStore.psm1') -DisableNameChecking
 $id=Assert-TCDId $Intent.OperationId;$Intent.UpdatedAtUtc=[DateTime]::UtcNow.ToString('o')
 Write-TCDJson (Join-Path (ManagementIntentDirectory) ($id+'.json')) $Intent
}
function NewManagementIntent {param([string]$Operation,[hashtable]$InputData,[string]$Purpose)
 $allowed=@{
  management_apply=@('PlanId','ApprovedChangeDigest');device_rename=@('DeviceId','Name','ExpectedConfigRevision');invite_create=@('InviteId','DeviceName','ExpiresInHours');invite_cancel=@('InviteId');pair_online_create=@('InviteId','DeviceName','ExpiresInSeconds','PublicHost','Port','ExpectedServerBinding','ExpectedManagementFingerprint');pair_online_cancel=@('InviteId','ExpectedServerBinding','ExpectedManagementFingerprint');
  authorize_external=@('InviteId','PairRequest');revoke=@('DeviceId','ExpectedConfigRevision','ApprovedChangeDigest');uninstall=@('ExpectedConfigRevision','ApprovedChangeDigest');transport_apply=@('PlanId','ApprovedChangeDigest');recover=@();request_status=@('RequestId','RequestDigest','IncludeTelemetry','RefreshAuthorization')
 }
 if(-not $allowed.ContainsKey($Operation)){throw '此动作不属于受支持的管理变更。'}
 foreach($key in $InputData.Keys){if($key -cnotin $allowed[$Operation]){throw '管理意图包含未支持字段，未保存或发送。'}}
 $m=$script:DeployUI.Management
 $intent=[pscustomobject]@{SchemaVersion=1;Kind='TradeChannel.ManagementIntent';OperationId=[guid]::NewGuid().ToString('D');ServerRecordId=$m.ServerId;
  ServerBinding=@{RemoteOwnerId=(ServerUIGet $m.Info RemoteOwnerId);NodeId=(ServerUIGet (ServerUIGet $m.Info Node) NodeId);ServerPublicKey=(ServerUIGet (ServerUIGet $m.Info Node) ServerPublicKey)};
  Operation=$Operation;Purpose=$Purpose;Input=$InputData.Clone();State='Prepared';CreatedAtUtc=[DateTime]::UtcNow.ToString('o');UpdatedAtUtc=[DateTime]::UtcNow.ToString('o');ResultCode=$null}
 SaveManagementIntent $intent;return $intent
}
function RestoreManagementIntent {
 $m=$script:DeployUI.Management;if($script:Smoke){return}
 $directory=ManagementIntentDirectory;if(-not [IO.Directory]::Exists($directory)){return}
 Import-Module (UIProductPath 'DeploymentStore.psm1') -DisableNameChecking
 $unknown=@(Get-ChildItem -LiteralPath $directory -Filter '*.json'|ForEach-Object {
  try{$i=Read-TCDJson $_.FullName;if($i.SchemaVersion -eq 1 -and $i.Kind -ceq 'TradeChannel.ManagementIntent' -and $i.ServerRecordId -eq $m.ServerId -and $i.State -in @('Prepared','Dispatched','OutcomeUnknown','NeedsRecovery','AuthorizedReturnPending')){$i}}catch{}
 }|Sort-Object UpdatedAtUtc -Descending)
 if($unknown.Count){$m.UnresolvedIntent=$unknown[0]}
}
function SetManagementIntentOutcome {param($Pending,[string]$State,[string]$Code='')
 $intent=ServerUIGet $Pending Intent
 if(-not $intent){return};$intent.State=$State;$intent.ResultCode=$Code;SaveManagementIntent $intent
 $m=$script:DeployUI.Management
 if($State -in @('OutcomeUnknown','NeedsRecovery','AuthorizedReturnPending')){$m.UnresolvedIntent=$intent}
 elseif((ServerUIGet $m UnresolvedIntent) -and $m.UnresolvedIntent.OperationId -eq $intent.OperationId){$m.UnresolvedIntent=$null}
}
function ReconcileManagementIntentUI {
 $m=$script:DeployUI.Management;$intent=ServerUIGet $m UnresolvedIntent
 if(-not $intent){return}
 if($intent.Operation -in @('invite_create','invite_cancel')){StartServerOperation invite_status @{InviteId=$intent.Input.InviteId} ReconcileInvite;return}
 if($intent.Operation -in @('pair_online_create','pair_online_cancel')){$m.OnlineInviteRetry=$intent.Input;StartServerOperation pair_online_status @{InviteId=$intent.Input.InviteId;ExpectedServerBinding=$intent.Input.ExpectedServerBinding;ExpectedManagementFingerprint=$intent.Input.ExpectedManagementFingerprint} OnlineInviteReconcile;return}
 if($intent.Operation -eq 'authorize_external'){
  if($script:Smoke){return}
  Import-Module (UIProductPath 'DeploymentPairing.psm1') -DisableNameChecking
  $info=Get-TCPairRequestInfo -PairRequest $intent.Input.PairRequest;$script:DeployUI.PairRequest=$intent.Input.PairRequest;$script:DeployUI.PairRequestInspection=$info
  InitializePairingUI;$script:DeployUI.PairFields.RequestText=$intent.Input.PairRequest
  StartServerOperation invite_status @{InviteId=$intent.Input.InviteId} ReconcilePairInvite;return
 }
 if($intent.Operation -in @('revoke','device_rename')){StartServerOperation devices @{Offset=0;Limit=100;IncludeRevoked=$true} ReconcileDevices;return}
 StartServerOperation server_info @{} ReconcileServer
}
function ResolveManagementIntentUI {
 $m=$script:DeployUI.Management;$intent=ServerUIGet $m UnresolvedIntent
 if(-not $intent){return}
 OpenDialog '已确认这次操作的实际结果？' ('动作：'+(ManagementLabel $intent.Operation)+'。确认后仅解除本机的重复提交限制，不改变服务器。') '服务器未完成的操作仍需恢复。下次变更需重新预览；授权继续使用原申请。' '已确认结果，解除限制' {
  $m=$script:DeployUI.Management;$intent=$m.UnresolvedIntent;$intent.State='ReconciledByUser';SaveManagementIntent $intent;$m.UnresolvedIntent=$null;ShowServerManagement
 }
}
function LoadServersUI {
 # This read belongs to a user navigation/refresh. Do not set a loading flag
 # unless the existing scheduler can start it or queue it behind a silent poll.
 if((ServerUIGet $script:DeployUI ServersLoading $false) -or (IsBusy) -or (Get-Variable QueuedJob -Scope Script -ValueOnly -ErrorAction SilentlyContinue)){return}
 $script:DeployUI.ServerDiscoveryAttempted=$true;$script:DeployUI.ServersLoading=$true
 StartJob @{Action='DeploymentDiscover'} {param($d)$script:DeployUI.ServersLoading=$false;$script:DeployUI.Discovery=$d;RefreshSelectedServerRecordUI;if($script:Role -in @('servers','devices')){ShowServerManagement}} '读取服务器记录…' '' -Failed {param($message)$script:DeployUI.ServersLoading=$false;InitializeServerUI;$script:DeployUI.Management.Error='记录暂时无法读取，请刷新重试。';if($script:Role -in @('servers','devices')){ShowServerManagement}}
}
function RefreshSelectedServerRecordUI {
 InitializeServerUI;$m=$script:DeployUI.Management;if(-not $m.ServerId){return}
 # A refresh must not replace the target of an operation already in flight.
 # Its existing completion path owns reconciliation against the live identity.
 if($script:DeployUI.PendingManagement){return}
 $matches=@(ServerUIGet $script:DeployUI.Discovery Servers @()|Where-Object {$_.LocalRecordId -ceq $m.ServerId})
 if($matches.Count -ne 1){$m.Authenticated=$false;$m.Info=$null;$m.Preview=$null;$m.RecordStale=$true;$m.Error='服务器记录不唯一或已不存在，请返回列表检查。';return}
 $fresh=$matches[0];$changed=(ServerUIGet $fresh RecordState 'Active') -cne 'Active'
 foreach($key in @('RemoteOwnerId','NodeId','ServerPublicKey','PinnedHostKey')){if([string](ServerUIGet $fresh $key '') -cne [string](ServerUIGet $m.Server $key '')){$changed=$true}}
 foreach($key in @('Host','Port','User','IdentityFile')){if([string](ServerUIGet (ServerUIGet $fresh Connection) $key '') -cne [string](ServerUIGet (ServerUIGet $m.Server Connection) $key '')){$changed=$true}}
 if($changed){$m.Authenticated=$false;$m.Credential=$null;$m.Info=$null;$m.Preview=$null;$m.ReadContinuation='';$m.RecordStale=$true;if(-not $script:DeployUI.PendingManagement){$m.SessionRef=$null};$script:DeployUI.DeviceResult=$null;$m.Error='服务器身份或记录状态已变化，请重新确认。'}
 $m.Server=$fresh
}
function SelectServerStateUI {param([string]$ServerId)
 # 0.22.0 A3: the state half of selecting a server, without touching the screen.
 # The server page renders immediately after it; the web invitation page keeps its
 # own page and refreshes its view instead, so the two halves are separated.
 InitializeServerUI;$pendingLogin=[string](ServerUIGet $script:ServerNavigationUI PendingIntent '') -ceq 'Login'
 # Result of the last attempt, read by both callers: a presentation stub that
 # happens to return a value must never be mistaken for a completed selection.
 $script:ServerSelectionStateUI=$false
 if($script:DeployUI.PendingManagement){$null=ShowManagementRefusalUI '请等待当前操作完成；结果未知时先检查原操作。' 'OperationPending';return $false}
 if((ServerUIGet $script:DeployUI.Management ReinstallStage) -and $script:DeployUI.Management.ServerId -cne $ServerId){$null=ShowManagementRefusalUI '请先退出这次重装身份核验，再选择其他服务器。' 'ReinstallInProgress';return $false}
 if($script:DeployUI.Run -and $script:DeployUI.Run.Status -eq 'Running'){$null=ShowManagementRefusalUI '部署正在执行，请确认结果后再登录管理。' 'DeploymentRunning';return $false}
 $matches=@(ServerUIGet $script:DeployUI.Discovery Servers @()|Where-Object {$_.LocalRecordId -ceq $ServerId})
 if($matches.Count -ne 1){$null=ShowManagementRefusalUI '服务器记录不唯一或不存在，请刷新列表。' 'ServerRecordMissing';return $false};$server=$matches[0]
 if((ServerUIGet $server RecordState 'Active') -ceq 'Archived'){$null=ShowManagementRefusalUI '此身份已归档，请选择重装后新建的服务器记录。' 'ArchivedRecord';return $false}
 if($script:DeployUI.Management.ServerId -ne $ServerId){
  $old=$script:DeployUI.Management.SessionRef
  # The driver belongs to the invitation page, not to the record, so it survives
  # the rebuild; other drivers ('' today) are unaffected.
  $driver=[string](ServerUIGet $script:DeployUI.Management Driver '')
  if($old -and -not $script:Smoke){CloseUiDeploymentSession $old}
  $script:DeployUI.Management=$null;InitializeServerUI;$script:DeployUI.Management.Driver=$driver;$script:DeployUI.DeviceResult=$null;$script:DeployUI.Invite=$null
 }else{RefreshSelectedServerRecordUI}
 $script:DeployUI.Management.ServerId=$ServerId;$script:DeployUI.Management.Server=$server;$script:DeployUI.ServerId=$ServerId
 $script:DeployUI.Management.RecordStale=$false
 $script:DeployUI.Management.ReadContinuation=''
 InitializeServerNavigationUI;$script:ServerNavigationUI.View='server-detail';$script:ServerNavigationUI.SelectedServerId=$ServerId;$script:ServerNavigationUI.DetailKind='Managed';$script:ServerNavigationUI.Message='';$script:ServerNavigationUI.Loading=$false;$script:ServerNavigationUI.RequestId='';$script:ServerNavigationUI.PendingIntent=''
 if($pendingLogin){$script:DeployUI.Management.LoginStage='Method';$script:DeployUI.Management.LoginReturn='detail'}
 RestoreManagementIntent
 $script:DeployUI.ManagementMode=$true
 $script:ServerSelectionStateUI=$true
 return $true
}
function SelectServerUI {param([string]$ServerId)
 $null=SelectServerStateUI $ServerId
 if(-not $script:ServerSelectionStateUI){return}
 $script:Role='servers';ShowServerManagement
}
function ServerField {param($Parent,[string]$Label,[string]$Id,[string]$Key,[string]$Hint='',[switch]$Multiline)
 $box=DeploymentField $Parent $Label $Id ([string]$script:DeployUI.Management.Input[$Key]) $Hint -Multiline:$Multiline
 $box.Tag=$Key;$box.Add_TextChanged({$script:DeployUI.Management.Input[[string]$this.Tag]=$this.Text});return $box
}
function ConnectServerUI {
 if(ServerUIReadOnly){ErrorDialog '当前是只读检查窗口，未启动服务器管理登录。';return}
 InitializeServerUI;$m=$script:DeployUI.Management
 if($script:Role -eq 'product-pair' -and (ServerUIGet (ServerUIGet $script:DeployUI PairIntake) Role '') -eq 'Manager'){$m.ReadContinuation='Pairing'}else{$m.ReadContinuation=''}
 if(ServerUIGet $m ReinstallStage){ConnectServerReinstallUI;return}
 if((ServerUIGet $m.Server RecordState 'Active') -ceq 'Archived'){ErrorDialog '原身份已归档，请选择重装后的新记录。';return}
 if(-not $m.Server -or -not $m.Server.Connection){ErrorDialog '邀请只授予连接使用权。管理服务器需要真实 SSH 管理资料。';return}
 if($script:Smoke){StartJob @{Action='ManagementSessionFixture';ServerId=$m.ServerId} {param($d)$script:DeployUI.Management.SessionRef=$d.SessionRef;$script:DeployUI.SessionRef=$d.SessionRef;$script:DeployUI.Management.Authenticated=$true;StartServerOperation server_info @{} ServerInfo} '测试管理认证';return}
 try{
  Import-Module (UIProductPath 'DeploymentTransport.psm1') -DisableNameChecking
  Import-Module (UIProductPath 'ServerRegistry.psm1') -DisableNameChecking
  $m.Server=Get-TCServer -Root $script:Root -Id $m.ServerId
  $method=[string](ServerUIGet $m LoginMethod '')
  # Only the login card may answer from the model: its credential step submits with
  # LoginStage='Credential', and its saved-credential button with LoginMethod='Saved'.
  # LoginMethod alone is not enough - it survives every page change, so a leftover
  # 'Password'/'Key' used to shadow the credential form the operator was typing in.
  $useModel=(((ServerUIGet $m LoginStage '') -ceq 'Credential') -or ($method -ceq 'Saved'))
  # An imported recovery credential still answers for this record when nothing was
  # typed. It is the only credential the operator never has to retype.
  $recovered=if((ServerUIGet $script:DeployUI RecoveryRecordId '') -eq $m.ServerId){ServerUIGet $script:DeployUI RecoveredCredential $null}else{$null}
  if($useModel){
   # 0.23.0: the login card owns the choice, so the credential follows from the
   # method the operator picked instead of being guessed from which box is filled.
   if($recovered -and -not (ServerUIGet $m LoginSecret $null) -and -not (ServerUIGet $m.Input KeyPath '')){$credential=$recovered}
   else{
    switch($method){
     'Saved'{
      $ref=GetServerSavedLoginRefUI $m.Server
      if(-not $ref){$m.SavedLoginInfo=$null;throw '这台服务器还没有保存登录资料，请改用密码或私钥。'}
      try{$credential=GetServerSavedCredentialUI $m.Server}
      catch{
       $code='';if($_.Exception.Message -match '^\[TC:([A-Za-z][A-Za-z0-9_]+)\]'){$code=$matches[1]}
       # The record no longer proves this envelope, so the cached verdict is
       # dropped and the method card stops offering the button on the next paint.
       $m.SavedLoginInfo=$null
       throw (GetServerSavedLoginFailureTextUI $code)
      }
     }
     'Key'{
      $key=[string](ServerUIGet $m.Input KeyPath '')
      if(-not $key -or -not [IO.File]::Exists($key) -or (Get-Item -LiteralPath $key).Length -gt 1MB){throw 'SSH 私钥文件不存在或超过 1 MiB。'}
      $pem=[IO.File]::ReadAllText($key,[Text.Encoding]::UTF8)
      $credential=@{Kind='PrivateKey';PrivateKeyPem=(ConvertTo-SecureString $pem -AsPlainText -Force);Passphrase=(ServerUIGet $m LoginSecret $null)};$pem=$null
     }
     'Password'{$credential=@{Kind='Password';Password=(ServerUIGet $m LoginSecret $null)}}
     default{throw '请先选择登录方式。'}
    }
   }
  }else{
   # TODO 0.23：自动 TCP 与配对授权页收敛到登录卡后删除本分支
   # 0.22.4 兼容：这两页仍在页面上直接渲染凭据表单，靠这里的旧逻辑继续能登录。
   if(-not $script:Controls.ContainsKey('ServerPassword')){ErrorDialog '请先选择登录方式。';return}
   $key=[string]$script:Controls.ServerKeyPath.Text;$secret=$script:Controls.ServerPassword.SecurePassword
   if(-not $key -and $secret.Length -eq 0 -and (ServerUIGet $script:DeployUI RecoveryRecordId '') -eq $m.ServerId -and (ServerUIGet $script:DeployUI RecoveredCredential)){
    $credential=$script:DeployUI.RecoveredCredential
   }elseif((ServerUIGet $m UseSavedCredential $false) -and (GetServerSavedLoginRefUI $m.Server)){
    $credential=GetServerSavedCredentialUI $m.Server
   }elseif($key){
    if(-not [IO.File]::Exists($key) -or (Get-Item -LiteralPath $key).Length -gt 1MB){throw 'SSH 私钥文件不存在或超过 1 MiB。'}
    $pem=[IO.File]::ReadAllText($key,[Text.Encoding]::UTF8)
    $credential=@{Kind='PrivateKey';PrivateKeyPem=(ConvertTo-SecureString $pem -AsPlainText -Force);Passphrase=$secret};$pem=$null
   }else{$credential=@{Kind='Password';Password=$secret}}
  }
  ConnectServerWithCredentialUI $credential
 }catch{
  $m.Credential=$null;$m.Error=$_.Exception.Message
  # A failed login-card attempt keeps the credential step on screen so the typed
  # value and the reason are readable together; the refill restores the box. A page
  # that owns its own credential form is left exactly as it was.
  $method=[string](ServerUIGet $m LoginMethod '')
  if($useModel){
   if($method -in @('Password','Key')){$m.LoginStage='Credential'}else{$m.LoginStage='Method';$m.LoginMethod=''}
  }
  if(TestServerPageRenderRoleUI){RenderServerManagementUI}
  ShowManagementRefusalUI $m.Error
 }
}
function ConnectServerWithCredentialUI {param($Credential)
 # 0.22.0 A3/A5: shared by the server page button and the web invitation page
 # (saved credentials only). Credential in, session start out - nothing else.
 InitializeServerUI;$m=$script:DeployUI.Management
 $m.Credential=$Credential;$m.Authenticated=$false;$m.TrustShown=$null;$m.Error=''
 if($m.CommandPending){return};$m.CommandPending=$true
 $script:DeployUI.PendingManagement=@{Purpose='Authenticate';Operation='';OperationId='';ServerId=$m.ServerId};RenderServerManagementUI
 StartUiCommand -Module 'DeploymentTransport.psm1' -Command 'Start-TCDeploySession' -Arguments @{Root=$script:Root;RunId=[guid]::NewGuid().ToString('D');Connection=$m.Server.Connection;Credential=$Credential;PinnedFingerprint=[string](ServerUIGet $m.Server PinnedHostKey '')} -Context @{Model=$m;ServerId=$m.ServerId} -Complete {
   param($started,$context);$context.Model.CommandPending=$false
   $current=$script:DeployUI.Management
   if(-not [object]::ReferenceEquals($current,$context.Model) -or $current.ServerId -cne $context.ServerId){CloseUiDeploymentSession $started.SessionRef;return}
   $current.SessionRef=$started.SessionRef;$script:DeployUI.SessionRef=$started.SessionRef;$script:DeployUI.SessionAttached=$true
   if(TestServerPageRenderRoleUI -Roles @('servers','devices','product-pair')){RenderServerManagementUI}
  } -Failed {
   param($message,$context);$context.Model.CommandPending=$false;$context.Model.Credential=$null;$context.Model.Error=$message
   # A failed login keeps the credential step and the typed secret, so the reason
   # and the input are readable together instead of being cleared by the repaint.
   if([string](ServerUIGet $context.Model LoginMethod '') -in @('Password','Key')){$context.Model.LoginStage='Credential'}
   if([object]::ReferenceEquals($script:DeployUI.Management,$context.Model) -and $script:DeployUI.Management.ServerId -ceq $context.ServerId){
    $script:DeployUI.PendingManagement=$null
    if(TestServerPageRenderRoleUI){RenderServerManagementUI}
    ShowManagementRefusalUI $message
   }
  } -Message '正在连接所选服务器…'
}
function ResetServerReinstallUI {param([string]$Message='已退出重装核验，原记录保留。')
 $m=$script:DeployUI.Management
 $m.ReinstallStage=$null;$m.ReinstallAttemptId=$null;$m.ReinstallVerificationToken=$null;$m.ReinstallPreview=$null;$m.ReinstallApprovalToken=$null;$m.Credential=$null;$m.SessionRef=$null;$m.Authenticated=$false;$m.TrustShown=$null;$m.Info=$null;$m.Input.KeyPath='';$m.CommandPending=$false;$m.LoginStage='';$m.LoginMethod='';$m.LoginSecret=$null
 $script:DeployUI.PendingManagement=$null;$script:DeployUI.SessionRef=$null;$script:DeployUI.SessionAttached=$false;$script:DeployUI.Credential=$null;$script:DeployUI.RecoveredCredential=$null;$script:DeployUI.DeviceResult=$null;$m.Error=$Message
 # Detach only. No process is stopped and no previous deployment is resumed.
 ShowServerManagement
}
function BeginServerReinstallUI {
 if(ServerUIReadOnly){ErrorDialog '当前是只读检查窗口，未启动服务器身份核验。';return}
 InitializeServerUI;$m=$script:DeployUI.Management
 if($script:DeployUI.PendingManagement){ErrorDialog '当前管理操作尚未完成，请先检查结果。';return}
 if(-not $m.Server -or -not $m.Server.Connection -or -not (ServerUIGet $m.Server PinnedHostKey) -or (ServerUIGet $m.Server RecordState 'Active') -ceq 'Archived'){ErrorDialog '请选择仍有效且已固定 SSH 指纹的服务器记录。';return}
 OpenDialog '这台服务器已重装？' ('目标：'+$m.Server.Name+' · '+$m.Server.Connection.Host+':'+$m.Server.Connection.Port) '下一步需重新输入登录资料，并从可信来源确认新的 SSH 指纹。确认后建立新记录，原身份和任务归档保留；设备密钥、授权和已保存密码不继承。当前连接保持。' '服务器已重装，开始核验' {
  param($context)
  $m=$script:DeployUI.Management
  if($m.ServerId -cne $context.ServerId -or $script:DeployUI.PendingManagement){ErrorDialog '选择的服务器已变化，请重新进入重装核验。';return}
  ResetServerReinstallUI '';$m.ReinstallStage='NeedsCredentials';$m.UseSavedCredential=$false;$script:DeployUI.Invite=$null;ShowServerManagement
 } '取消' 'Primary' @{ServerId=$m.ServerId}
}
function ConnectServerReinstallUI {
 if(ServerUIReadOnly){ErrorDialog '当前是只读检查窗口，未启动服务器身份核验。';return}
 $m=$script:DeployUI.Management
 if($m.ReinstallStage -cne 'NeedsCredentials' -or $script:DeployUI.PendingManagement){ErrorDialog '新身份核验正在进行，请等待或退出本次核验。';return}
 if($script:Smoke){
  $script:DeployUI.PendingManagement=@{Purpose='ReinstallObserve';ServerId=$m.ServerId}
  StartJob @{Action='ServerReinstallVerificationFixture';ServerId=$m.ServerId;DeclaredReinstalled=$true} {param($d)$m=$script:DeployUI.Management;$m.SessionRef=$d.SessionRef;$m.ReinstallVerificationToken=$d.VerificationToken;$m.ReinstallStage='Observing'} '测试重装只读身份核验';return
 }
 try{
  Import-Module (UIProductPath 'ServerRegistry.psm1') -DisableNameChecking
  $method=[string](ServerUIGet $m LoginMethod '')
  # Same gate as ConnectServerUI: only the login card's credential step may answer
  # from the model. A leftover LoginMethod must never shadow this page's own form.
  $useModel=((ServerUIGet $m LoginStage '') -ceq 'Credential')
  if($useModel){
   # Reinstall always wants fresh input, so 'Saved' is never offered here.
   switch($method){
    'Key'{
     $key=[string](ServerUIGet $m.Input KeyPath '')
     if(-not $key -or -not [IO.File]::Exists($key) -or (Get-Item -LiteralPath $key).Length -gt 1MB){throw 'SSH 私钥文件不存在或超过 1 MiB。'}
     $pem=[IO.File]::ReadAllText($key,[Text.Encoding]::UTF8);$credential=@{Kind='PrivateKey';PrivateKeyPem=(ConvertTo-SecureString $pem -AsPlainText -Force);Passphrase=(ServerUIGet $m LoginSecret $null)};$pem=$null
    }
    'Password'{
     $secret=ServerUIGet $m LoginSecret $null
     if(-not $secret -or $secret.Length -eq 0){throw '重装验证需重新输入管理密码或选择 SSH 私钥，不能使用旧登录资料。'}
     $credential=@{Kind='Password';Password=$secret}
    }
    # Unreachable today (the card never offers it here), but a wrong sentence on a
    # step the operator already chose would read as if they had not chosen at all.
    'Saved'{throw '重装验证不能使用已保存的登录资料，请重新输入管理密码或选择 SSH 私钥。'}
    default{throw '当前登录方式不支持重装核验。'}
   }
  }else{
   # TODO 0.23：自动 TCP 与配对授权页收敛到登录卡后删除本分支
   # 0.22.4 兼容：这两页仍在页面上直接渲染凭据表单，靠这里的旧逻辑继续能登录。
   if(-not $script:Controls.ContainsKey('ServerPassword')){ErrorDialog '请先选择登录方式。';return}
   $key=[string]$script:Controls.ServerKeyPath.Text;$secret=$script:Controls.ServerPassword.SecurePassword
   if($key){
    if(-not [IO.File]::Exists($key) -or (Get-Item -LiteralPath $key).Length -gt 1MB){throw 'SSH 私钥文件不存在或超过 1 MiB。'}
    $pem=[IO.File]::ReadAllText($key,[Text.Encoding]::UTF8);$credential=@{Kind='PrivateKey';PrivateKeyPem=(ConvertTo-SecureString $pem -AsPlainText -Force);Passphrase=$secret};$pem=$null
   }else{if($secret.Length -eq 0){throw '重装验证需重新输入管理密码或选择 SSH 私钥，不能使用旧登录资料。'};$credential=@{Kind='Password';Password=$secret}}
  }
  $m.Credential=$credential;$m.ReinstallAttemptId=[guid]::NewGuid().ToString('N');$m.ReinstallStage='Starting';$m.CommandPending=$true;$m.Error='';$m.Authenticated=$false
  $script:DeployUI.PendingManagement=@{Purpose='ReinstallObserve';ServerId=$m.ServerId};ShowServerManagement
  StartUiCommand -Module 'ServerRegistry.psm1' -Command 'Start-TCServerReinstallVerification' -Arguments @{Root=$script:Root;ServerId=$m.ServerId;Credential=$credential;DeclaredReinstalled=$true} -Context @{Model=$m;ServerId=$m.ServerId;AttemptId=$m.ReinstallAttemptId} -Complete {
   param($started,$context)
   $current=$script:DeployUI.Management
   if(-not [object]::ReferenceEquals($current,$context.Model) -or $current.ServerId -cne $context.ServerId -or $current.ReinstallAttemptId -cne $context.AttemptId){CloseUiDeploymentSession $started.SessionRef;return}
   $current.CommandPending=$false;$current.SessionRef=$started.SessionRef;$current.ReinstallVerificationToken=$started.VerificationToken;$current.ReinstallStage='Observing'
   $script:DeployUI.SessionRef=$started.SessionRef;$script:DeployUI.SessionAttached=$false
   if($script:Role -in @('servers','devices')){ShowServerManagement}
  } -Failed {
   param($message,$context)
   $current=$script:DeployUI.Management
   if([object]::ReferenceEquals($current,$context.Model) -and $current.ServerId -ceq $context.ServerId -and $current.ReinstallAttemptId -ceq $context.AttemptId){ResetServerReinstallUI $message;ErrorDialog $message}
  } -Message '正在只读核验重装后的服务器身份…'
 }catch{ResetServerReinstallUI $_.Exception.Message;ErrorDialog $_.Exception.Message}
}
function ShowServerReinstallTrustUI {
 if(ServerUIReadOnly){ErrorDialog '当前是只读检查窗口，未确认新的 SSH 身份。';return}
 $m=$script:DeployUI.Management;$preview=$m.ReinstallPreview
 if(-not $preview -or $m.ReinstallStage -cne 'AwaitingTrust'){return}
 OpenDialog '确认重装后的新 SSH 指纹' ('目标：'+$preview.Connection.Host+':'+$preview.Connection.Port+"`n原指纹："+$preview.PreviousFingerprint+"`n新指纹："+$preview.NewFingerprint) '请通过云控制台等可信来源确认新指纹。之后仅用此指纹登录并建立新管理记录；原记录和任务保留，旧授权不能继续使用。不会自动部署、重启服务或切换线路。' '确认新指纹，建立新记录' {
  param($context)
  if(ServerUIReadOnly){ErrorDialog '当前是只读检查窗口，未确认新的 SSH 身份。';return}
  $m=$script:DeployUI.Management;$preview=$m.ReinstallPreview
  if($m.ServerId -cne $context.ServerId -or -not $preview -or $preview.PreviewToken -cne $context.PreviewToken -or $m.ReinstallStage -cne 'AwaitingTrust'){ErrorDialog '目标或核验预览已变化，请重新核验。';return}
  try{
   if($script:Smoke){$m.ReinstallApprovalToken='fixture-approval';$m.Credential=$null;$m.ReinstallStage='Authenticating';$script:DeployUI.PendingManagement=@{Purpose='ReinstallAuthenticate';ServerId=$m.ServerId};ShowServerManagement;return}
   $credential=$m.Credential;$m.CommandPending=$true;$m.ReinstallStage='Approving';$script:DeployUI.PendingManagement=@{Purpose='ReinstallAuthenticate';ServerId=$m.ServerId};ShowServerManagement
   StartUiCommand -Module 'ServerRegistry.psm1' -Command 'Approve-TCServerReinstallFingerprint' -Arguments @{Root=$script:Root;ServerId=$m.ServerId;SessionRef=$m.SessionRef;PreviewToken=$preview.PreviewToken;ConfirmedFingerprint=$context.Fingerprint;Credential=$credential} -Context @{Model=$m;ServerId=$m.ServerId;AttemptId=$m.ReinstallAttemptId;InstanceId=$m.SessionRef.InstanceId} -Complete {
    param($approved,$context)
    $current=$script:DeployUI.Management
    if(-not [object]::ReferenceEquals($current,$context.Model) -or $current.ServerId -cne $context.ServerId -or $current.ReinstallAttemptId -cne $context.AttemptId -or -not $current.SessionRef -or $current.SessionRef.InstanceId -cne $context.InstanceId){return}
    $current.CommandPending=$false;$current.ReinstallApprovalToken=$approved.ApprovalToken;$current.Credential=$null;$current.ReinstallStage='Authenticating'
    if($script:Role -in @('servers','devices')){ShowServerManagement}
   } -Failed {
    param($message,$context)
    $current=$script:DeployUI.Management
    if([object]::ReferenceEquals($current,$context.Model) -and $current.ServerId -ceq $context.ServerId -and $current.ReinstallAttemptId -ceq $context.AttemptId){ResetServerReinstallUI $message;ErrorDialog $message}
   } -Message '正在验证已确认的新服务器身份…'
  }catch{ResetServerReinstallUI $_.Exception.Message;ErrorDialog $_.Exception.Message}
 } '取消' 'Primary' @{ServerId=$m.ServerId;PreviewToken=$preview.PreviewToken;Fingerprint=$preview.NewFingerprint}
}
function PollServerReinstallUI {param($Poll)
 if(ServerUIReadOnly){ResetServerReinstallUI '当前是只读检查窗口，已退出身份核验；原记录保留。';return}
 $m=$script:DeployUI.Management
 if($m.ReinstallStage -in @('Starting','Approving','Previewing','AwaitingTrust','Committing','NeedsCredentials')){return}
 if($m.ReinstallStage -ceq 'Observing' -and $Poll.Code -ceq 'HostTrustRequired'){
  $m.ReinstallStage='Previewing';$script:DeployUI.PendingManagement=@{Purpose='ReinstallTrust';ServerId=$m.ServerId}
  StartJob @{Action='ServerReinstallPreview';ServerId=$m.ServerId;SessionRef=$m.SessionRef;VerificationToken=$m.ReinstallVerificationToken} {
   param($d)
   $m=$script:DeployUI.Management;$m.ReinstallPreview=$d;$m.ReinstallStage='AwaitingTrust';$script:DeployUI.PendingManagement=$null;ShowServerManagement;ShowServerReinstallTrustUI
  } '准备新身份核验预览…' '' -Failed {param($message)ResetServerReinstallUI $message;ErrorDialog $message}
  return
 }
 if($m.ReinstallStage -ceq 'Authenticating' -and $Poll.HasSession -and $Poll.Code -ceq 'Authenticated'){
  $preview=$m.ReinstallPreview;$m.ReinstallStage='Committing';$script:DeployUI.PendingManagement=@{Purpose='ReinstallConfirm';ServerId=$m.ServerId}
  StartJob @{Action='ServerReinstallConfirm';ServerId=$m.ServerId;SessionRef=$m.SessionRef;ApprovalToken=$m.ReinstallApprovalToken;ConfirmedFingerprint=$preview.NewFingerprint;ApprovedChangeDigest=$preview.ChangeDigest} {
   param($d)
   $m=$script:DeployUI.Management;$previous=$m.ServerId
   $m.ServerId=$d.Server.LocalRecordId;$m.Server=$d.Server;$m.Info=$null;$m.Authenticated=$true;$m.Error='新管理记录已建立。设备授权尚未建立；新的部署需创建新的设备身份。';$m.UnresolvedIntent=$null;$m.Preview=$null;$m.InviteHistory=@();$m.InviteFingerprint=$null;$m.Input.RenameId='';$m.Input.RenameName=''
   $m.ReinstallStage=$null;$m.ReinstallVerificationToken=$null;$m.ReinstallPreview=$null;$m.ReinstallApprovalToken=$null;$m.Credential=$null;$m.LoginStage='';$m.LoginMethod='';$m.LoginSecret=$null;$script:DeployUI.PendingManagement=$null;$script:DeployUI.ServerId=$m.ServerId;$script:DeployUI.Server=$d.Server;$script:DeployUI.DeviceResult=$null;$script:DeployUI.Invite=$null
   $script:DeployUI.PairRequest=$null;$script:DeployUI.PairRequestInspection=$null;$script:DeployUI.EnrollmentId=$null;$script:DeployUI.PairFields=$null;$script:DeployUI.InviteFromServer=$false
   if($script:DeployUI.Run -and (ServerUIGet $script:DeployUI.Run ServerRecordId '') -ceq $previous){$script:DeployUI.Run=$null;$script:DeployUI.SessionAttached=$false}
   LoadServersUI;ShowServerManagement
  } '建立新管理记录，保留原身份和任务…' '' -Failed {param($message)ResetServerReinstallUI $message;ErrorDialog $message}
  return
 }
 if($Poll.Status -in @('Running','Connecting','AwaitingCredential')){return}
 if($Poll.Code -ceq 'HostKeyChanged'){ResetServerReinstallUI '验证时新指纹再次变化，已阻止登录。请通过可信来源重新确认；原记录保留。';return}
 ResetServerReinstallUI '新 SSH 身份验证未完成，原记录保留。请重新输入登录资料并验证。'
}
function FailServerDispatchUI {param($Context,[string]$Message,[bool]$NotDispatched=$false)
 $Context.Model.CommandPending=$false
 if($Context.Intent){
  $Context.Intent.State=if($NotDispatched){'Rejected'}else{'OutcomeUnknown'}
  if(-not $NotDispatched){$Context.Model.UnresolvedIntent=$Context.Intent}
  SaveManagementIntent $Context.Intent
 }
 $Context.Model.Error=$Message
 if(-not $NotDispatched){$Context.Model.Authenticated=$false;$Context.Model.Credential=$null}
 if([object]::ReferenceEquals($script:DeployUI.Management,$Context.Model) -and [object]::ReferenceEquals($script:DeployUI.PendingManagement,$Context.Pending)){
  $script:DeployUI.PendingManagement=$null
  if(TestServerPageRenderRoleUI){RenderServerManagementUI}
  ShowManagementRefusalUI $Message
 }
}
function StartServerOperation {param([string]$Operation,[hashtable]$InputData=@{},[string]$Purpose='')
 if(ServerUIReadOnly){ErrorDialog '当前是只读检查窗口，未执行远端管理操作。';return}
 InitializeServerUI;$m=$script:DeployUI.Management;if(-not $Purpose){$Purpose=$Operation}
 $continuation=''
 if($Purpose -eq 'ServerInfo'){
  if((ServerUIGet $m ReadContinuation '') -eq 'Pairing' -or ($script:Role -eq 'product-pair' -and (ServerUIGet (ServerUIGet $script:DeployUI PairIntake) Role '') -eq 'Manager')){$continuation='Pairing'}
  $m.ReadContinuation=''
 }
 if((ServerUIGet $m ReinstallStage) -or (ServerUIGet $m.Server RecordState 'Active') -ceq 'Archived'){ShowManagementRefusalUI '重装验证期间仅检查 SSH 身份；归档记录不能继续管理操作。' 'ArchivedRecord';return}
 if($script:DeployUI.PendingManagement){ShowManagementRefusalUI '当前操作尚未完成，请先检查结果。' 'OperationPending';return}
 $mutation=ManagementMutation $Operation $InputData
 if($mutation -and (ServerUIGet $m UnresolvedIntent) -and $Operation -notin @('recover','request_status')){ShowManagementRefusalUI '上次管理操作结果待确认，请先查询原操作。此次未重复发送。' 'OutcomePending';return}
 if($Operation -eq 'invite_create' -and -not $InputData.ContainsKey('InviteId')){$InputData.InviteId=[guid]::NewGuid().ToString('D')}
 $intent=$null
 if($script:Smoke){
  $script:DeployUI.PendingManagement=@{Operation=$Operation;Purpose=$Purpose;ServerId=$m.ServerId;InputData=$InputData;OperationId='fixture';Continuation=$continuation}
  StartJob @{Action='ServerOperation';ServerId=$m.ServerId;Operation=$Operation;Input=$InputData} {param($d)CompleteServerOperation $d} '测试服务器动作';return
 }
 $lease=$null;$submitted=$false
 try{
  if(-not $m.Authenticated -or -not $m.SessionRef){throw '请先在当前服务器卡片登录管理账户。'}
  Import-Module (UIProductPath 'ServerRegistry.psm1') -DisableNameChecking
  $lease=Open-TCServerTaskLease -Root $script:Root -ServerId $m.ServerId
  Import-Module (UIProductPath 'DeploymentTransport.psm1') -DisableNameChecking
  if($mutation){$intent=NewManagementIntent $Operation $InputData $Purpose}
  $arguments=@{SessionRef=$m.SessionRef;Operation=$Operation;Input=$InputData};if($intent){$arguments.OperationId=$intent.OperationId}
  $command='Invoke-TCDeployOperation'
  if($Operation -clike 'pair_online_*'){
   # Online invitations use their own fixed host command; the code is only a result, never request input.
   $online=if($intent){$intent.OperationId}else{[guid]::NewGuid().ToString('D')}
   $arguments=@{SessionRef=$m.SessionRef;Action=$Operation.Substring(12);InputData=$InputData;OperationId=$online};$command='Invoke-TCDeployPairOnlineOperation'
  }
  $m.CommandPending=$true
  $pending=@{Operation=$Operation;Purpose=$Purpose;ServerId=$m.ServerId;InputData=$InputData;OperationId=$(if($intent){$intent.OperationId}else{''});Intent=$intent;Continuation=$continuation}
  $script:DeployUI.PendingManagement=$pending
  $context=@{Model=$m;Pending=$pending;Intent=$intent;Lease=$lease};$lease=$null
  $submitted=$true
  StartUiCommand -Module 'DeploymentTransport.psm1' -Command $command -Arguments $arguments -Context $context -Complete {
   param($started,$context)
   try{
    if(-not $started.Ok){FailServerDispatchUI $context '服务器未接受此请求，请检查原步骤。' $true;return}
    if($context.Intent -and $started.OperationId -cne $context.Intent.OperationId){FailServerDispatchUI $context '管理请求返回的标识不一致，请先查询原操作。';return}
    $context.Pending.OperationId=$started.OperationId;$context.Model.CommandPending=$false;$context.Model.Error=''
    if($context.Intent){$context.Intent.State='Dispatched';SaveManagementIntent $context.Intent}
    if([object]::ReferenceEquals($script:DeployUI.Management,$context.Model) -and (TestServerPageRenderRoleUI)){RenderServerManagementUI}
   }finally{if($context.Lease){$context.Lease.Dispose();$context.Lease=$null}}
  } -Failed {
   param($message,$context,$failure)
   try{
    if(TestWebInviteDrivenUI){$context.Model.ErrorCode=[string](ServerUIGet $failure Code '')}
    if($failure -and $failure.Phase -eq 'BeforeDispatch'){FailServerDispatchUI $context '管理请求尚未提交，请处理提示后再试。' $true}
    else{FailServerDispatchUI $context '无法确认管理操作是否被接受，请先查询原申请或服务器状态。'}
   }finally{if($context.Lease){$context.Lease.Dispose();$context.Lease=$null}}
  } -Message '正在提交原管理操作，等待确认…'
  if(TestServerPageRenderRoleUI){RenderServerManagementUI}
 }catch{
  if($intent){$intent.State=if($submitted){'OutcomeUnknown'}else{'Rejected'};if($submitted){$m.UnresolvedIntent=$intent};SaveManagementIntent $intent}
  $m.Error=if($submitted){'无法确认管理操作是否被接受，请先查询原申请或服务器状态。'}else{'请求尚未提交，请检查登录状态和本机记录后重试。'}
  if(-not $submitted){$m.CommandPending=$false}
  if(TestServerPageRenderRoleUI){RenderServerManagementUI};ShowManagementRefusalUI $m.Error
 }finally{if($lease){$lease.Dispose()}}
}
function ClearStalePendingManagementUI {
 # 0.22.2: a management operation that never reports back must not lock the web
 # invitation page forever. Ninety seconds is well past a single SSH round trip, so
 # the operation is reported as 「结果未知」 and the operator is sent to the server
 # page to confirm - the same ending an explicit OutcomeUnknown gets. This is the
 # safety net behind the real fix (settling no longer depends on the visible page).
 InitializeServerUI
 $pending=$script:DeployUI.PendingManagement
 if(-not $pending){return $false}
 $since=ServerUIGet $pending SinceUtc $null
 if(-not $since){$pending.SinceUtc=[DateTime]::UtcNow;return $false}
 if(([DateTime]::UtcNow-[DateTime]$since).TotalSeconds -lt 90){return $false}
 $purpose=[string](ServerUIGet $pending Purpose '')
 try{SetManagementIntentOutcome $pending 'OutcomeUnknown' 'PendingTimeout'}catch{}
 $m=$script:DeployUI.Management
 if($m){
  $m.CommandPending=$false
  $m.ErrorCode='OutcomePending'
  $m.Error='上一步操作超过 90 秒没有结果，已停止等待；请到服务器页确认。'
 }
 $script:DeployUI.PendingManagement=$null
 if(Get-Command Write-TCPerfTrace -ErrorAction SilentlyContinue){Write-TCPerfTrace ('pending-timeout:'+$purpose)}
 if(Get-Command SyncTCWebState -ErrorAction SilentlyContinue){SyncTCWebState -Force}
 return $true
}
function PollServerOperation {param($Poll=$null)
 InitializeServerUI;$m=$script:DeployUI.Management
 if($m.CommandPending){return}
 if($script:Smoke -or -not $m.SessionRef -or (-not $Poll -and ((Get-Date)-$m.LastPoll).TotalSeconds -lt 2)){return}
 if(-not $Poll){
  $m.LastPoll=Get-Date
  StartJob @{Action='DeploymentSessionSnapshot';SessionRef=$m.SessionRef} {param($data)
   $m=$script:DeployUI.Management
   # 0.22.2: settling an operation no longer depends on which page is on screen.
   # The old guard dropped every result produced after the operator left the web
   # invitation page, so PendingManagement was never cleared and the page refused
   # to open again - the "one-shot feature" report. Painting stays conditional;
   # every render path below goes through TestServerPageRenderRoleUI.
   if(-not $m -or [string]$data.InstanceId -cne [string]$m.SessionRef.InstanceId){return}
   $m.LastSnapshot=$data.Poll;PollServerOperation $data.Poll
  } '读取服务器管理状态…' '' -Silent -Failed {param($message)if($script:DeployUI.Management){$script:DeployUI.Management.LastPoll=(Get-Date).AddSeconds(3);$script:DeployUI.Management.Error='管理会话暂不可核验，原操作保持；正在等待查询。'}}
  return
 }
 try{
  Import-Module (UIProductPath 'DeploymentTransport.psm1') -DisableNameChecking
  if(ServerUIGet $m ReinstallStage){PollServerReinstallUI $Poll;return}
  if($Poll.Code -eq 'HostTrustRequired'){
   if(TestWebInviteDrivenUI){
    # A3: the invitation page never trusts a fingerprint in place. Stop the headless
    # flow here and send the operator to the server page, which owns that decision.
    $m.TrustShown=$Poll.ObservedFingerprint;$m.ErrorCode='HostTrustRequired';$m.Error='服务器 SSH 身份已变化，请在服务器页重新确认指纹。';RenderServerManagementUI;return
   }
   # 0.22.2: the poll now finishes while the operator is on some other page. A trust
   # decision must never pop a modal over the lines page - record it, settle the
   # pending operation, and let the server page own the confirmation.
   if($script:Role -notin @('servers','devices','automatic-tcp','product-pair')){
    $m.TrustShown=$Poll.ObservedFingerprint;$m.ErrorCode='HostTrustRequired';$m.Error='服务器 SSH 身份已变化，请在服务器页重新确认指纹。'
    $script:DeployUI.PendingManagement=$null;$m.CommandPending=$false
    if(Get-Command SyncTCWebState -ErrorAction SilentlyContinue){SyncTCWebState -Force}
    return
   }
   if($m.TrustShown -ne $Poll.ObservedFingerprint){$m.TrustShown=$Poll.ObservedFingerprint
    OpenDialog '确认服务器 SSH 身份' ('服务器：'+$m.Server.Name+"`n指纹："+$m.TrustShown) '请通过云控制台等可信来源确认指纹。已知指纹变化会阻止登录，并保留原信任记录。' '确认指纹并信任' {
     param($context)
     $m=$script:DeployUI.Management
     if(-not [object]::ReferenceEquals($m,$context.Model) -or $m.ServerId -cne $context.ServerId -or -not $m.SessionRef -or $m.SessionRef.InstanceId -cne $context.InstanceId -or $m.TrustShown -cne $context.Fingerprint){ErrorDialog '服务器或身份信息已变化，请重新确认。';return}
     $m.CommandPending=$true
     StartUiCommand -Module 'DeploymentTransport.psm1' -Command 'Set-TCDeployCredential' -Arguments @{SessionRef=$m.SessionRef;Connection=$m.Server.Connection;Credential=$m.Credential;PinnedFingerprint=$context.Fingerprint} -Context $context -Complete {param($data,$context)$context.Model.CommandPending=$false} -Failed {param($message,$context)$context.Model.CommandPending=$false;$context.Model.Credential=$null;if([object]::ReferenceEquals($script:DeployUI.Management,$context.Model)){ErrorDialog $message}} -Message '正在按已确认的身份登录服务器…'
    } '取消' 'Primary' @{Model=$m;ServerId=$m.ServerId;InstanceId=$m.SessionRef.InstanceId;Fingerprint=$m.TrustShown}
   };return
  }
  if($Poll.Code -eq 'HostKeyChanged'){$m.Credential=$null;$script:DeployUI.RecoveredCredential=$null;$m.Authenticated=$false;$script:DeployUI.PendingManagement=$null;$m.Error='SSH 身份已变化，请确认目标。若服务器已重装，请使用“服务器身份变化”入口重新验证。';RenderServerManagementUI;return}
  if($Poll.HasSession -and -not $m.Authenticated){
   if($script:Smoke){$m.Authenticated=$true;$m.Credential=$null;$script:DeployUI.RecoveredCredential=$null;$script:DeployUI.PendingManagement=$null;StartServerOperation server_info @{} ServerInfo;return}
   $m.CommandPending=$true
   StartUiCommand -Module 'ServerRegistry.psm1' -Command 'Set-TCServerRecord' -Arguments @{Root=$script:Root;Id=$m.ServerId;PinnedFingerprint=[string]$Poll.ObservedFingerprint;SessionRef=$m.SessionRef} -Context @{Model=$m;ServerId=$m.ServerId;InstanceId=$m.SessionRef.InstanceId} -Complete {
    param($server,$context);$context.Model.CommandPending=$false
    $current=$script:DeployUI.Management
    if(-not [object]::ReferenceEquals($current,$context.Model) -or $current.ServerId -cne $context.ServerId -or $current.SessionRef.InstanceId -cne $context.InstanceId){return}
    $current.Server=$server;$current.Authenticated=$true
    # 0.23.0: this is the only moment the target is proven - the session holds the
    # verified key and the record was just re-registered - so the long-term
    # envelope is written here, before the secret leaves the model. A failure is a
    # notice only: the login the operator already has must not be taken away.
    if(-not $script:Smoke -and $current.Credential -and [bool](ServerUIGet $current RememberCredential $true) -and [string](ServerUIGet $current LoginMethod '') -cne 'Saved' -and -not (ServerUIGet $current ReinstallStage)){
     $kind=[string](ServerUIGet $current.Credential 'Kind' '')
     $existingRef=[string](ServerUIGet $server SavedLoginRef '')
     $storedKind=[string](ServerUIGet (ServerUIGet $current SavedLoginInfo $null) CredentialKind '')
     $agreed=[string](ServerUIGet (ServerUIGet $current PendingCredentialReplace $null) Kind '')
     # A different method is replaced only after the operator answered the card; an
     # unanswered one keeps the old envelope instead of overwriting it silently.
     if($kind -in @('Password','PrivateKey') -and -not ($existingRef -and $storedKind -and $storedKind -cne $kind -and $agreed -cne $kind)){
      $current.SavedLoginNotice=''
      StartUiCommand -Module 'ServerRegistry.psm1' -Command 'Save-TCServerCredential' -Arguments @{Root=$script:Root;Id=$current.ServerId;Credential=$current.Credential;CredentialKind=$kind;ReplaceRef=$existingRef;KeyPathHint=[string](ServerUIGet (ServerUIGet $current Input $null) KeyPath '')} -Context @{Model=$current;ServerId=$current.ServerId} -Complete {
       param($saved,$context)
       $now=$script:DeployUI.Management
       if(-not [object]::ReferenceEquals($now,$context.Model)){return}
       $now.PendingCredentialReplace=$null;$now.SavedLoginInfo=$null
       if($saved -and [string](ServerUIGet $saved SavedLoginRef '')){$now.Server|Add-Member NoteProperty SavedLoginRef ([string]$saved.SavedLoginRef) -Force}
       if(TestServerPageRenderRoleUI -Roles @('servers','devices','product-pair')){RenderServerManagementUI}
      } -Failed {param($message,$context)if([object]::ReferenceEquals($script:DeployUI.Management,$context.Model)){$script:DeployUI.Management.SavedLoginNotice='登录成功，但登录资料没有保存；本次可以继续，下次登录需要重新输入。';if(TestServerPageRenderRoleUI -Roles @('servers','devices','product-pair')){RenderServerManagementUI}}} -Message '正在保存这台电脑的登录资料…'
     }elseif($existingRef -and $storedKind -and $storedKind -cne $kind){
      $current.SavedLoginNotice='已保存的登录资料属于另一种登录方式，这次没有替换；需要时可以重新登录并选择替换。'
     }
    }
    $current.Credential=$null;$script:DeployUI.RecoveredCredential=$null;$script:DeployUI.PendingManagement=$null
    StartServerOperation server_info @{} ServerInfo
   } -Failed {param($message,$context)$context.Model.CommandPending=$false;$context.Model.Error=$message;if([object]::ReferenceEquals($script:DeployUI.Management,$context.Model)){$script:DeployUI.PendingManagement=$null;ErrorDialog $message}}
   return
  }
  if(-not $script:DeployUI.PendingManagement){return}
  if($Poll.Status -in @('Running','Connecting','AwaitingCredential')){return}
  $pending=$script:DeployUI.PendingManagement
  if($Poll.OperationId -and $pending.OperationId -and $Poll.OperationId -cne $pending.OperationId){throw '执行器返回不属于当前操作，已停止自动续接。'}
  if($Poll.Status -ne 'Completed'){
   $m.ErrorCode=[string]$Poll.Code
   SetManagementIntentOutcome $pending $(if($Poll.Status -eq 'OutcomeUnknown'){'OutcomeUnknown'}elseif($Poll.Code -eq 'NeedsRecovery'){'NeedsRecovery'}else{'Rejected'}) ([string]$Poll.Code)
   $script:DeployUI.PendingManagement=$null;$m.Error=if($Poll.Status -eq 'OutcomeUnknown'){'无法确认服务器变更结果。请重新登录后检查状态或恢复未完成操作，避免重复授权。'}else{ServerErrorText ([string]$Poll.Code)}
   if(-not $Poll.HasSession){$m.Authenticated=$false;$m.Credential=$null};RenderServerManagementUI
   # A failed 「取消并重试」 must not leave the follow-up create armed.
   if([string](ServerUIGet $pending Purpose '') -ceq 'OnlineInviteCancel'){$m.OnlineInviteRetryAfterCancel=$false}
   # 0.21.4: the note above renders at the top of the page while invitation
   # buttons sit far below it, so a refused invitation looked like no reaction.
   # 0.22.2: only the server page may raise that modal. A failure that settles while
   # the operator is elsewhere is reported by the web page, not by a dialog on top
   # of an unrelated screen.
   if([string](ServerUIGet $pending Purpose '') -in @('OnlineInviteCreate','OnlineInviteCancel','OnlineInviteStatus','InviteCreate','InviteCancel') -and $script:Role -in @('servers','devices')){ErrorDialog $m.Error}
   return
  }
  CompleteServerOperation $Poll.Data
 }catch{
  if(ServerUIGet $m ReinstallStage){ResetServerReinstallUI '无法确认本次 SSH 身份验证状态，原记录保留。请重新验证。';return}
  SetManagementIntentOutcome $script:DeployUI.PendingManagement OutcomeUnknown;$script:DeployUI.PendingManagement=$null;$m.Credential=$null;$m.Authenticated=$false;$m.Error='无法确认服务器结果，请重新登录并查看原操作。';RenderServerManagementUI
 }
}
function ServerHasPotentialSession {return ((IsRunning) -or [bool](ServerUIGet $script:Overview SessionPresent $false) -or [bool](ServerUIGet $script:Overview Running $false) -or ([string](ServerUIGet $script:Overview StateKey '') -in @('Fault','Connecting','Applying','Disconnecting') -and [bool](ServerUIGet $script:Overview ManifestPath '')))}
function ServerDeviceInUse {param([string]$PublicKey)
 if(-not (ServerHasPotentialSession)){return $false}
 if($script:Smoke){return ([string](ServerUIGet $script:DeployUI ActiveClientPublicKey '') -ceq $PublicKey)}
 try{
  Import-Module (UIProductPath 'DeploymentStore.psm1') -DisableNameChecking
  $path=[string](ServerUIGet $script:Overview ManifestPath '')
  if($path){$manifest=Read-TCDJson $path;return ([string](ServerUIGet $manifest ClientPublicKey '') -ceq $PublicKey)}
 }catch{}
 return (ServerCurrentlyInUse)
}
function ImportLegacyServersUI {
 StartJob @{Action='ServerImportLegacy'} {param($d)LoadServersUI;Toast '历史记录已登记，服务器身份仍需登录核验'} '登记历史服务器记录，不修改旧任务或当前连接…'
}
function ServerCurrentlyInUse {
 if(-not (ServerHasPotentialSession)){return $false};$m=$script:DeployUI.Management
 if(@($m.Server.LinkedNodeIds) -contains (ActiveNodeId)){return $true}
 if($script:Smoke){return ([bool](ServerUIGet $script:DeployUI UnknownActiveIdentity $false))}
 try{
  Import-Module (UIProductPath 'DeploymentStore.psm1') -DisableNameChecking
  $path=[string](ServerUIGet $script:Overview ManifestPath '')
  if($path){$manifest=Read-TCDJson $path;$public=[string](ServerUIGet $manifest ServerPublicKey '');$target=[string](ServerUIGet (ServerUIGet $m.Info Node) ServerPublicKey (ServerUIGet $m.Server ServerPublicKey ''));if($public -and $target){return ($public -ceq $target)}}
 }catch{}
 return $true # A possible session with unknown binding cannot prove a safe target.
}
function CompleteServerInfoNavigation {param($Pending)
 # A completed read is the end of the login: the card, the chosen method and the
 # in-memory secret are dropped here so no later repaint can show them again.
 $m=$script:DeployUI.Management
 if($m){$m.LoginStage='';$m.LoginMethod='';$m.LoginReturn='';$m.LoginSecret=$null}
 if((ServerUIGet $Pending Continuation '') -eq 'Pairing' -and $script:Role -in @('servers','product-pair')){ContinuePairManagerReviewUI;ShowProductPairing}
 else{StartServerOperation devices @{Offset=0;Limit=50;IncludeRevoked=$true} Devices}
}
function CompleteServerOperation {param($Data)
 $pending=$script:DeployUI.PendingManagement;$script:DeployUI.PendingManagement=$null;if(-not $pending){return}
 $m=$script:DeployUI.Management
 if((ServerUIGet $Data Ok $null) -is [bool]){if(-not $Data.Ok){$m.Error='服务器拒绝操作：'+[string](ServerUIGet $Data.Data Code 'RemoteRejected');RenderServerManagementUI;return};$Data=$Data.Data}
 try{
  SetManagementIntentOutcome $pending $(if($pending.Purpose -eq 'AuthorizeExternal'){'AuthorizedReturnPending'}else{'Completed'})
  if($script:AutoTCP -and (CompleteAutomaticTransportOperation $pending.Purpose $Data)){return}
  switch($pending.Purpose){
   'ServerInfo'{
    $m.Info=$Data
    if($script:Smoke){CompleteServerInfoNavigation $pending;return}
    $m.CommandPending=$true
    StartUiCommand -Module 'ServerRegistry.psm1' -Command 'Set-TCServerRecord' -Arguments @{Root=$script:Root;Id=$m.ServerId;ServerInfo=$Data;SessionRef=$m.SessionRef} -Context @{Model=$m;ServerId=$m.ServerId;InstanceId=$m.SessionRef.InstanceId;Pending=$pending} -Complete {
     param($server,$context);$context.Model.CommandPending=$false
     $current=$script:DeployUI.Management
     if(-not [object]::ReferenceEquals($current,$context.Model) -or $current.ServerId -cne $context.ServerId -or $current.SessionRef.InstanceId -cne $context.InstanceId){return}
     $current.Server=$server;CompleteServerInfoNavigation $context.Pending
    } -Failed {param($message,$context)$context.Model.CommandPending=$false;$context.Model.Error=$message;if([object]::ReferenceEquals($script:DeployUI.Management,$context.Model)){ErrorDialog $message}}
   }
   'Devices'{$script:DeployUI.DeviceResult=$Data;if(TestServerPageRenderRoleUI){RenderServerManagementUI}}
   'Rename'{Toast '设备名称已更新';StartServerOperation devices @{Offset=0;Limit=50;IncludeRevoked=$true} Devices}
   'InviteCreate'{
    $script:DeployUI.Invite=$Data
    if(ServerUIGet $script:DeployUI PairFields){$script:DeployUI.PairFields.InviteText=[string]$Data.Invite}
    if(-not $script:Smoke){Import-Module (UIProductPath 'DeploymentPairing.psm1') -DisableNameChecking;$verified=Get-TCPairInvite -Invite $Data.Invite -AllowUnconfirmed;$m.InviteFingerprint=$verified.Fingerprint}
    $m.InviteHistory=@(@($m.InviteHistory)+@([pscustomobject]@{InviteId=$Data.InviteId;State=$Data.State;ExpiresAtUtc=$Data.ExpiresAtUtc}));RenderServerManagementUI;Toast '邀请已生成，尚未添加设备'
   }
   'InviteCancel'{foreach($i in $m.InviteHistory){if($i.InviteId -eq $Data.InviteId){$i.State=$Data.State}};if($script:DeployUI.Invite -and $script:DeployUI.Invite.InviteId -eq $Data.InviteId){$script:DeployUI.Invite.State=$Data.State};RenderServerManagementUI;Toast '邀请已取消，已有设备授权不受影响'}
   'InviteStatus'{$m.LastInviteStatus=$Data;RenderServerManagementUI}
   'OnlineInviteCreate'{CompleteOnlineInviteUI $Data 'Create'}
   'OnlineInviteStatus'{CompleteOnlineInviteUI $Data 'Status'}
   'OnlineInviteCancel'{CompleteOnlineInviteUI $Data 'Cancel'}
   'OnlineInviteReconcile'{CompleteOnlineInviteUI $Data 'Reconcile'}
   'RestoreInvite'{$script:DeployUI.Invite=$Data;InitializePairingUI;$script:DeployUI.PairFields.InviteText=[string]$Data.Invite;$script:DeployUI.InviteFromServer=$true;ShowProductPairing;Toast '已取回原邀请，请检查对应的设备申请'}
   'ReconcileInvite'{$m.LastInviteStatus=$Data;RenderServerManagementUI;OpenDialog '原邀请的实际状态' ('状态：'+(ManagementLabel $Data.State)) '已取回原邀请；确认结果后可解除本机重复提交限制。' '知道了' $null ''}
   'ReconcilePairInvite'{$script:DeployUI.Invite=$Data;InitializePairingUI;$script:DeployUI.PairFields.InviteText=[string]$Data.Invite;$payload=$script:DeployUI.PairRequestInspection.Payload;StartServerOperation request_status @{RequestId=$payload.ClientRequest.RequestId;RequestDigest=$payload.RequestDigest;RefreshAuthorization=$true} AuthorizeExternal}
   'ReconcileDevices'{$script:DeployUI.DeviceResult=$Data;RenderServerManagementUI;Toast '已读取设备状态，请确认设备和配置版本后解除本机限制'}
   'ReconcileServer'{$m.Info=$Data;RenderServerManagementUI;OpenDialog '服务器实际状态已读取' ('状态：'+(ManagementLabel $Data.OwnershipState)) '未完成的操作需先恢复。解除本机限制不会执行原变更。' '知道了' $null ''}
   'ManagementPlan'{
    $m.Preview=$Data;RenderServerManagementUI
    if($Data.Status -eq 'AlreadyEnabled'){Toast '管理能力已启用';StartServerOperation server_info @{} ServerInfo;return}
    OpenDialog '启用服务器管理能力？' ('将建立管理身份和设备记录，保留现有连接、密钥和设备。OpenSSL 可用：'+[string]$Data.OpenSSLAvailable) '仅添加管理记录；本机不会获得连接授权，当前线路保持。' '启用管理' {StartServerOperation management_apply @{PlanId=$script:DeployUI.Management.Preview.PlanId;ApprovedChangeDigest=$script:DeployUI.Management.Preview.ChangeDigest} ManagementApply}
   }
   'ManagementApply'{Toast '管理能力已启用';StartServerOperation server_info @{} ServerInfo}
   'RevokePreview'{
    $m.Preview=$Data;RenderServerManagementUI
    $peer=@(ServerUIGet $script:DeployUI.DeviceResult Devices @()|Where-Object {$_.DeviceId -eq $Data.DeviceId})|Select-Object -First 1
    if($peer -and (ServerDeviceInUse $peer.ClientPublicKey)){ErrorDialog '此设备正在使用，或设备身份待确认。请先安排维护、退出交易软件并断开连接，再撤销授权，以免中断管理和交易连接。';return}
    OpenDialog '撤销这个设备的连接权限？' ('设备：'+[string](ServerUIGet $peer Name $Data.DeviceId)+"`n只有此设备失去 WireGuard 转发权限，其他设备保留。") 'TCP 外层 UUID 当前共享，不会自动轮换。撤销不能通过旧申请恢复。' '撤销指定设备' {StartServerOperation revoke @{DeviceId=$script:DeployUI.Management.Preview.DeviceId;ExpectedConfigRevision=$script:DeployUI.Management.Preview.ConfigRevision;ApprovedChangeDigest=$script:DeployUI.Management.Preview.ChangeDigest} Revoke} '取消' 'Danger'
   }
   'Revoke'{Toast '服务器已撤销指定设备';StartServerOperation devices @{Offset=0;Limit=50;IncludeRevoked=$true} Devices}
   'UninstallPreview'{
    $m.Preview=$Data;RenderServerManagementUI
    if(ServerCurrentlyInUse){ErrorDialog '这台服务器关联当前活动线路。请安排维护并停用当前连接后，再执行卸载。';return}
    OpenDialog '卸载这台服务器的通道服务？' ('影响设备：'+@($Data.AffectedDeviceIds).Count+' 台。将停止并移除本工具拥有的服务与规则，保留审计和身份。') '卸载不会退订云服务器，云服务商仍会计费。当前线路不会自动切换。' '卸载自有服务' {StartServerOperation uninstall @{ExpectedConfigRevision=$script:DeployUI.Management.Preview.ConfigRevision;ApprovedChangeDigest=$script:DeployUI.Management.Preview.ChangeDigest} Uninstall} '取消' 'Danger'
   }
   'Uninstall'{Toast '通道服务已卸载，云服务器未释放';StartServerOperation server_info @{} ServerInfo}
   'Recover'{Toast '恢复结果已确认';StartServerOperation server_info @{} ServerInfo}
   'TransportPlan'{
    $m.Preview=$Data;RenderServerManagementUI
    OpenDialog '为现有服务器增加 TCP 连接方式？' ('TCP '+$Data.Transport.Port+' · '+$Data.Transport.ServerName+"`n保留现有 UDP、WireGuard 密钥及所有设备，不重启隧道服务。") '请确认云端允许 TCP 入站；实际服务器与重启后的连接仍需验证。当前线路不会启用或切换。' '按此增量计划添加' {StartServerOperation transport_apply @{PlanId=$script:DeployUI.Management.Preview.PlanId;ApprovedChangeDigest=$script:DeployUI.Management.Preview.ChangeDigest} TransportApply}
   }
   'TransportApply'{Toast 'TCP 服务已添加，现有客户端需取得对应参数并验证';StartServerOperation server_info @{} ServerInfo}
   'AuthorizeExternal'{
    if($Data.Status -ne 'Authorized' -or -not $Data.Authorization){throw '设备授权无效，请检查邀请和设备记录。'}
    if($script:Smoke){StartJob @{Action='PairAuthorizationProtectFixture';EncryptedOnly=$true} {param($d)$script:DeployUI.EncryptedAuthorization=$d.EncryptedAuthorization;ShowProductPairing} '测试加密封装';return}
    Import-Module (UIProductPath 'DeploymentPairing.psm1') -DisableNameChecking
    $encrypted=Protect-TCPairAuthorization -SignedAuthorization $Data.Authorization -PairRequest $script:DeployUI.PairRequest -Invite $script:DeployUI.Invite.Invite
    $script:DeployUI.EncryptedAuthorization=$encrypted.EncryptedAuthorization;$Data=$null;ShowProductPairing;Toast '授权已加密，只分享密文返回'
    SetManagementIntentOutcome $pending Completed
   }
   default{$m.LastSummary='服务器操作已完成：'+$pending.Operation;RenderServerManagementUI}
  }
 }catch{$m.Error=$_.Exception.Message;$Data=$null;ErrorDialog $m.Error}
}
function GetServerNavigationBackLabelUI {
 $n=$script:ServerNavigationUI;$kind=[string](ServerUIGet $n ReturnKind '');$view=[string](ServerUIGet (ServerUIGet $n ReturnContext $null) View '')
 if($kind -ceq 'LineProfiles'){return '返回原线路'};if($kind -ceq 'Nodes'){return '返回线路列表'};if($kind -ceq 'DeploymentCenter'){return '返回部署中心'}
 if($kind -ceq 'Context'){
  if([string](ServerUIGet (ServerUIGet $n ReturnContext $null) Section '') -ceq 'web' -and $view -ceq 'invite'){return '返回邀请其他电脑'}
  if($view -ceq 'nodes'){return '返回线路列表'};if($view -ceq 'lines'){return '返回线路'};if($view -ceq 'server-detail'){return '返回服务器与设备'};if($view -ceq 'deployment-center'){return '返回部署中心'}
 }
 return '返回上一页'
}
function AddServerNavigationActionsUI {param($Parent,[switch]$Detail)
 # 0.23.0: 「所有服务器」 is gone (the back action already returns to the list) and
 # the list refresh belongs to the list. A detail page offers no second way out.
 $bar=New-Object Windows.Controls.WrapPanel
 if(-not $Detail){AddC $bar (Btn '刷新服务器列表' 'ServersRefresh' {LoadServersUI} 'Ghost')}
 $back=GetServerNavigationBackLabelUI
 AddC $bar (Btn $back 'MaintenanceBack' {ReturnFromServerManagement} 'Ghost')
 AddC $Parent (Margin $bar '0,0,0,16')
}
function AddServerSummaryUI {param($Parent,$Server)
 $connection=ServerUIGet $Server Connection
 KeyValue $Parent '服务器状态' (ManagementLabel ([string](ServerUIGet $Server OwnershipState 'Unverified')))
 KeyValue $Parent '管理入口' $(if($connection -and (ServerUIGet $connection Host '')){[string]$connection.Host+':'+[string]$connection.Port}else{'未登记 SSH 管理入口'})
 $access=if((ServerUIGet $Server ManagementAccessState '') -eq 'ConnectorOnly' -or -not $connection){'此电脑仅有线路使用权'}elseif($script:DeployUI.Management.Authenticated -and $script:DeployUI.Management.ServerId -ceq $Server.LocalRecordId){'管理会话已登录'}else{'已登记管理入口，登录后可查看状态'}
 KeyValue $Parent '此电脑的权限' $access
 if(ServerUIGet $Server LastCheckedUtc ''){KeyValue $Parent '最近检查时间' (ManagementTime $Server.LastCheckedUtc)}
 $knownNodes=Get-Variable Nodes -Scope Script -ErrorAction SilentlyContinue
 $linked=@(ServerUIGet $Server LinkedNodeIds @())
 $related=if($knownNodes){@($knownNodes.Value|Where-Object {$ids=@([string](ServerUIGet $_ LineId (ServerUIGet $_ id '')))+@(ServerUIGet $_ AliasIds @());@($ids|Where-Object {$_ -in $linked}).Count -gt 0})}else{@()}
 if($related.Count){
  AddC $Parent (Margin (T '关联的本机线路' 12.5 $script:Ink 'SemiBold') '0,12,0,4')
  foreach($line in $related){$id=[string](ServerUIGet $line LineId (ServerUIGet $line id ''));$b=Btn ([string](ServerUIGet $line name '线路')) ('ServerLine'+($id-replace '-','')) {LoadLineConnections ([string]$this.Tag)} 'Ghost';$b.Tag=$id;AddC $Parent $b}
 }elseif($linked.Count){AddC $Parent (Margin (T ('已登记 '+$linked.Count+' 个本机线路关联；在线路列表可查看现有资料。') 12 $script:Text3) '0,8,0,0')}
 AddC $Parent (Margin (T '其他电脑的授权设备需登录后查看。' 12 $script:Text3) '0,8,0,0')
}
function ShowServerBindingProblemUI {
 $n=$script:ServerNavigationUI
 SetServerNavigationPositionUI;Head '' '线路的服务器与设备' '查看关联服务器和授权设备。'
 AddServerNavigationActionsUI $script:HostPanel -Detail
 $card=Card;$p=Stack;$card.Child=$p
 SetupCardHeader $p ([string](ServerUIGet $n.Line Name '所选线路')) '' 'server'
 if($n.Loading){AddC $p (Note '正在读取原线路与服务器的身份关联…')}
 else{
  AddC $p (Note $n.Message 'amber')
  foreach($binding in $n.Bindings){AddC $p (Margin (T ([string](ServerUIGet $binding Name '服务器')+' · '+$(if((ServerUIGet $binding RecordState 'Active') -eq 'Archived'){'重装前身份已归档'}else{'关联待确认'})) 13 $script:Text2) '0,8,0,0')}
  if($n.LineId){$null=DeploymentActions $p '重新读取线路关联' 'RetryLineServerBinding' {OpenLineServerManagement $script:ServerNavigationUI.LineId -ReturnKind $script:ServerNavigationUI.ReturnKind} 'Ghost'}
  AddC $p (Margin (T '已有管理恢复包可从部署页导入；没有管理权限时，请由原管理电脑处理服务器。' 12.5 $script:Text3) '0,12,0,0')
 }
 AddC $script:HostPanel $card
}
function TestWebInviteDrivenUI {
 # 0.22.0 A3: the web invitation page drives this management model headlessly.
 # Driver is set only by ui/WebInvite.ps1 while that page owns the model; an
 # empty Driver is the pre-0.22.0 behaviour and nothing here changes it.
 $state=Get-Variable -Name DeployUI -Scope Script -ValueOnly -ErrorAction SilentlyContinue
 if(-not $state){return $false}
 $model=ServerUIGet $state Management
 if(-not $model -or [string](ServerUIGet $model Driver '') -cne 'WebInvite'){return $false}
 if([string](Get-Variable -Name WebPage -Scope Script -ValueOnly -ErrorAction SilentlyContinue) -cne 'invite'){return $false}
 return ([string](Get-Variable -Name Page -Scope Script -ValueOnly -ErrorAction SilentlyContinue) -ceq 'web')
}
function TestServerPageRenderRoleUI {param([string[]]$Roles=@('servers','devices'))
 # The invitation driver carries Role='client' (the web shell owns the screen), so
 # it is admitted explicitly at every place the server page used to repaint.
 return (($script:Role -in $Roles) -or (TestWebInviteDrivenUI))
}
function RenderServerManagementUI {
 # Every management completion, failure and poll ends here. The web invitation
 # page must not be replaced by the server page, so that one driver is handed to
 # ui/WebInvite.ps1 instead; every other caller keeps the original page.
 if(TestWebInviteDrivenUI){
  if(Get-Command UpdateTCWebInviteFromManagement -ErrorAction SilentlyContinue){$null=UpdateTCWebInviteFromManagement}
  if(Get-Command SyncTCWebState -ErrorAction SilentlyContinue){$null=SyncTCWebState -Force}
  return
 }
 ShowServerManagement
}
function ShowManagementRefusalUI {param([string]$Message,[string]$Code='')
 # The server page answers a refused action with a native dialog. The web
 # invitation page has none, so the same sentence is recorded on the management
 # model (and from there in the invitation view) instead of opening a modal.
 if(TestWebInviteDrivenUI){
  $m=$script:DeployUI.Management
  if($m){$m.Error=$Message;if($Code){$m.ErrorCode=$Code}}
  RenderServerManagementUI
  return
 }
 ErrorDialog $Message
}
function ShowServerManagement {
 if($script:AutoTCP){ShowAutomaticTransport;return}
 InitializeServerUI;InitializeServerNavigationUI
 $script:Page='setup';$script:Role='servers';$script:DeployUI.ManagementMode=$true
 $n=$script:ServerNavigationUI;$m=$script:DeployUI.Management
 if($n.View -eq 'server-offline'){ShowServerOfflineInviteUI;return}
 if($n.View -eq 'server-detail' -and $n.DetailKind -eq 'Binding'){ShowServerBindingProblemUI;return}
 if(-not $script:DeployUI.Discovery -and -not (ServerUIGet $script:DeployUI ServerDiscoveryAttempted $false)){LoadServersUI}
 if($n.View -eq 'server-detail'){ShowServerDetailUI;return}
 SetServerNavigationPositionUI;Head '' '服务器管理' '管理服务器与授权设备。未完成的安装请到部署中心继续。'
 AddServerNavigationActionsUI $script:HostPanel
 if($m.Error){AddC $script:HostPanel (Note $m.Error 'amber')}
 $all=@(ServerUIGet $script:DeployUI.Discovery Servers @());$servers=@(ServerUIGet $script:DeployUI.Discovery ManagementServers @())
 if(-not $servers.Count){
  AddC $script:HostPanel (Note $(if(ServerUIGet $script:DeployUI ServersLoading $false){'正在读取本机服务器记录…'}else{'尚未登记可管理的服务器。可到部署页添加线路或导入管理恢复资料。'}))
 }
 foreach($server in $servers){
  $card=Card '18,16';$p=Stack;$card.Child=$p;AddC $p (T ([string]$server.Name) 16 $script:Ink 'SemiBold')
  $endpoint=if($server.Connection){$server.Connection.Host+':'+$server.Connection.Port}else{'缺少管理地址'}
  AddC $p (Margin (T ($endpoint+' · '+(ManagementLabel ([string]$server.OwnershipState))) 12.5 $script:Text3) '0,5,0,0')
  AddC $p (Margin (T ('关联本机线路：'+@(ServerUIGet $server LinkedNodeIds @()).Count) 12 $script:Text3) '0,5,0,0')
  if(@($servers|Where-Object {$_.Name -ceq $server.Name -and [string](ServerUIGet (ServerUIGet $_ Connection) Host '') -ceq [string](ServerUIGet (ServerUIGet $server Connection) Host '')}).Count -gt 1){AddC $p (T ('记录标识：'+([string]$server.LocalRecordId).Substring(0,[Math]::Min(8,([string]$server.LocalRecordId).Length))) 12 $script:Text3)}
  $row=Stack 'Horizontal'
  $button=Btn '查看服务器与设备' ('ServerSelect'+($server.LocalRecordId-replace '-','')) {SelectServerUI ([string]$this.Tag)} 'Btn';$button.Tag=$server.LocalRecordId;AddC $row $button
  # 0.22.0 B4: destructive local cleanup moves into ⋯ so the card has one primary
  # action. The ContextMenu is mirrored as wf-menu by ui/WebForms.ps1.
  $more=Btn '⋯' ('ServerMore'+($server.LocalRecordId-replace '-','')) {$this.ContextMenu.PlacementTarget=$this;$this.ContextMenu.IsOpen=$true} 'Ghost'
  $menu=New-Object Windows.Controls.ContextMenu
  $remove=ControlName (New-Object Windows.Controls.MenuItem) ('ServerCleanup'+($server.LocalRecordId-replace '-',''));$remove.Header='删除本机部署资料…';$remove.Tag=$server.LocalRecordId;$remove.IsEnabled=(-not $script:ReadOnly)
  $remove.Add_Click({DeleteOperationRecordsUI -Ids @('ServerRecord:'+[string]$this.Tag)});$menu.Items.Add($remove)|Out-Null
  $more.ContextMenu=$menu;[Windows.Automation.AutomationProperties]::SetName($more,'更多服务器操作');AddC $row (Margin $more '6,0,0,0')
  AddC $p (Margin $row '0,12,0,0')
  AddC $script:HostPanel (Margin $card '0,0,0,12')
 }
 $archived=@($all|Where-Object {(ServerUIGet $_ RecordState 'Active') -ceq 'Archived'})
 if($archived.Count){
  $p=Stack;foreach($server in $archived){$button=Btn ([string]$server.Name+' · 查看归档身份') ('ArchivedServer'+($server.LocalRecordId-replace '-','')) {OpenArchivedServerUI ([string]$this.Tag)} 'Ghost';$button.Tag=$server.LocalRecordId;AddC $p $button}
  $exp=New-Object Windows.Controls.Expander;$exp.Header='已归档服务器（'+$archived.Count+'）';$exp.Content=$p;$exp.IsExpanded=[bool]$n.ShowArchived
  $exp.Add_Expanded({$script:ServerNavigationUI.ShowArchived=$true});$exp.Add_Collapsed({$script:ServerNavigationUI.ShowArchived=$false});AddC $script:HostPanel $exp
 }
}
function GetServerDetailTabUI {
 $tab=[string](ServerUIGet $script:DeployUI.Management DetailTab 'devices')
 if($tab -notin @('devices','maintenance','records')){$tab='devices'}
 return $tab
}
function AddServerDetailTabsUI {param($Parent)
 # 0.22.0 B4: three sections. Tag='TCTabs' serializes to Kind='tabs' (role=tablist
 # in the web shell); the degraded shell simply shows three buttons.
 $current=GetServerDetailTabUI
 $bar=New-Object Windows.Controls.WrapPanel;$bar.Tag='TCTabs'
 foreach($item in @(@('devices','设备与邀请'),@('maintenance','连接与维护'),@('records','管理资料'))){
  $active=([string]$item[0] -ceq $current)
  $b=Btn ([string]$item[1]) ('ServerTab'+[string]$item[0]) {$script:DeployUI.Management.DetailTab=[string]$this.Tag;ShowServerManagement} $(if($active){'Primary'}else{'Ghost'})
  $b.Tag=[string]$item[0]
  [Windows.Automation.AutomationProperties]::SetName($b,([string]$item[1])+$(if($active){'（当前）'}else{''}))
  AddC $bar $b
 }
 # 0.22.3: the section hint lives once, at the end of the tab strip, instead of
 # inside every card as a second title. One ⓘ for whichever tab is open.
 $hints=@{devices='用邀请码让其他电脑加入这条线路；新电脑粘贴后自动授权，不需要再批准。';maintenance='执行前会确认服务器身份与影响范围。';records='保存恢复资料，便于更换管理电脑后重新登录核验。'}
 if($hints.ContainsKey($current)){AddC $bar (Margin (HintIcon ([string]$hints[$current])) '8,0,0,0')}
 AddC $Parent $bar
}
function GetServerSummaryText {param($Server)
 # 0.22.3: one sentence answering the only three questions this page needs to
 # answer before the tabs - which machine, can I act on it, which line is it.
 # The deployment state moved to 管理资料, and the registry count is gone: it used
 # to be the fallback rendering of the very same LinkedNodeIds that the line
 # button above it showed, so one fact had two faces.
 $m=$script:DeployUI.Management
 $state=if($m.Authenticated -and [string]$m.ServerId -ceq [string]$Server.LocalRecordId){'管理已登录'}else{'未登录管理'}
 $linked=@(ServerUIGet $Server LinkedNodeIds @())
 $names=@()
 $knownNodes=Get-Variable Nodes -Scope Script -ErrorAction SilentlyContinue
 if($knownNodes){
  foreach($line in @($knownNodes.Value)){
   $ids=@([string](ServerUIGet $line LineId (ServerUIGet $line id '')))+@(ServerUIGet $line AliasIds @())
   if(@($ids|Where-Object {$_ -in $linked}).Count){$names+=[string](ServerUIGet $line name '')}
  }
 }
 $names=@($names|Where-Object {$_}|Select-Object -Unique)
 $text=([string](ServerUIGet $Server Name '服务器'))+' · '+$state
 if($names.Count){$text=$text+' · 关联线路 '+($names -join '、')}
 return $text
}
function GetServerSummaryHint {param($Server)
 # Everything that used to sit under the status line, in the one place where it
 # costs no layout: the management entry, the rights and the last check time.
 $m=$script:DeployUI.Management
 $access=if((ServerUIGet $Server ManagementAccessState '') -eq 'ConnectorOnly' -or -not (ServerUIGet $Server Connection)){'仅有线路使用权'}elseif($m.Authenticated -and $m.ServerId -ceq $Server.LocalRecordId){'管理会话已登录'}else{'已登记管理入口，登录后可查看状态'}
 $connection=ServerUIGet $Server Connection
 $hint='管理入口：'+$(if($connection -and (ServerUIGet $connection Host '')){[string]$connection.Host+':'+[string]$connection.Port}else{'未登记 SSH 管理入口'})+'；权限：'+$access
 if(ServerUIGet $Server LastCheckedUtc ''){$hint=$hint+'；最近检查：'+(ManagementTime $Server.LastCheckedUtc)}
 return $hint
}
function AddServerSummaryLineUI {param($Parent,$Server)
 $row=Stack 'Horizontal'
 AddC $row (T (GetServerSummaryText $Server) 12.5 $script:Text2)
 AddC $row (Margin (HintIcon (GetServerSummaryHint $Server)) '8,0,0,0')
 AddC $Parent (Margin $row '0,0,0,14')
}
function GetServerSavedLoginRefUI {param($Server)
 # SavedLoginRef is absent on records written before 0.23.0, so every read goes
 # through the tolerant accessor; a direct property read would throw under
 # Set-StrictMode -Version 2.0.
 return [string](ServerUIGet $Server SavedLoginRef '')
}
function GetServerLoginCredentialKindUI {param([string]$Method)
 if($Method -ceq 'Key'){return 'PrivateKey'}
 if($Method -ceq 'Password'){return 'Password'}
 return ''
}
function GetServerSavedLoginKindLabelUI {param([string]$Kind)
 if($Kind -ceq 'PrivateKey'){return 'SSH 私钥'}
 if($Kind -ceq 'Password'){return '服务器密码'}
 return '登录资料'
}
function GetServerSavedLoginStatusTextUI {param([string]$Status)
 # Only states the operator can act on carry a sentence. Missing/BindingChanged
 # are the two that explain why the button is absent; everything else is
 # presented as "never saved", exactly like a record that has no reference.
 switch($Status){
  'Missing'{return '这台服务器的登录资料已不在本机，请重新输入一次。'}
  'BindingChanged'{return '这台服务器的身份已经变化，已保存的登录资料不再适用。请重新验证身份后登录。'}
 }
 return ''
}
function GetServerSavedLoginFailureTextUI {param([string]$Code)
 # The code itself never reaches the screen. Each sentence ends with the same
 # instruction: type it again and keep going inside this card.
 switch($Code){
  'CredentialMissing'{return '这台服务器的登录资料已不在本机，请重新输入一次。'}
  'CredentialBindingChanged'{return '这台服务器的身份已经变化，已保存的登录资料不再适用。请重新验证身份后登录。'}
  'CredentialLegacy'{return '这份登录资料是旧格式，请重新输入一次。'}
  'CredentialUnavailable'{return '这台电脑无法读取已保存的登录资料。换 Windows 用户或换电脑需要重新输入一次。'}
  'CredentialRefInvalid'{return '已保存的登录资料引用无效，请重新输入一次。'}
  'ServerArchived'{return '这台服务器的身份已归档，请使用重装后新建的记录。'}
 }
 return '已保存的登录资料不可用，请改用密码或私钥。'
}
function GetServerSavedLoginInfoUI {param($Model)
 # <2 KB of plaintext metadata, no DPAPI, no network, no lock: the method card can
 # decide synchronously whether to offer the saved button. The six-field binding
 # is enough because the transport completes the login method from the envelope.
 $Model.SavedLoginInfo=$null
 if($script:Smoke -or -not $Model -or -not $Model.Server){return}
 $ref=GetServerSavedLoginRefUI $Model.Server
 if(-not $ref){return}
 try{
  Import-Module (UIProductPath 'DeploymentStore.psm1') -DisableNameChecking
  Import-Module (UIProductPath 'ServerRegistry.psm1') -DisableNameChecking
  Import-Module (UIProductPath 'DeploymentTransport.psm1') -DisableNameChecking
  $binding=Get-TCServerCredentialBinding -Record $Model.Server
  $signing=[string](ServerUIGet $Model.Server ManagementSigningPublicKey '')
  $digest=if($signing){Get-TCDDigest $signing}else{''}
  $Model.SavedLoginInfo=Get-TCDeploySavedCredentialInfo -Root $script:Root -CredentialRef $ref -Binding $binding -CurrentManagementSigningKeyDigest $digest
 }catch{$Model.SavedLoginInfo=$null}
}
function GetServerSavedCredentialUI {param($Server)
 # The single place that reads a saved envelope. Identity is proven from plaintext
 # metadata before any decryption, so a moved record reports
 # TC:CredentialBindingChanged instead of a generic "cannot decrypt", and the
 # method is completed by the transport from the envelope itself.
 $ref=GetServerSavedLoginRefUI $Server
 if(-not $ref){throw '[TC:CredentialMissing] 这台服务器的登录资料已不在本机，请重新输入一次。'}
 Import-Module (UIProductPath 'DeploymentStore.psm1') -DisableNameChecking
 Import-Module (UIProductPath 'ServerRegistry.psm1') -DisableNameChecking
 Import-Module (UIProductPath 'DeploymentTransport.psm1') -DisableNameChecking
 $signing=[string](ServerUIGet $Server ManagementSigningPublicKey '')
 return Get-TCDeploySavedCredential -Root $script:Root -CredentialRef $ref -Binding (Get-TCServerCredentialBinding -Record $Server) -CurrentManagementSigningKeyDigest $(if($signing){Get-TCDDigest $signing}else{''})
}
function TestServerSavedLoginUsableUI {param($Server,[string[]]$Status=@('Available'))
 # Plaintext-only gate for UI that offers a saved login. Returns $false when the
 # metadata cannot be read or the record no longer proves the envelope, so a gate
 # never advertises a login whose click could only fail.
 $ref=GetServerSavedLoginRefUI $Server
 if(-not $ref){return $false}
 if(-not (Get-Command Get-TCDeploySavedCredentialInfo -ErrorAction SilentlyContinue)){return $true}
 try{
  Import-Module (UIProductPath 'DeploymentStore.psm1') -DisableNameChecking
  Import-Module (UIProductPath 'ServerRegistry.psm1') -DisableNameChecking
  Import-Module (UIProductPath 'DeploymentTransport.psm1') -DisableNameChecking
  $signing=[string](ServerUIGet $Server ManagementSigningPublicKey '')
  $info=Get-TCDeploySavedCredentialInfo -Root $script:Root -CredentialRef $ref -Binding (Get-TCServerCredentialBinding -Record $Server) -CurrentManagementSigningKeyDigest $(if($signing){Get-TCDDigest $signing}else{''})
  return (([string](ServerUIGet $info Status '')) -in $Status)
 }catch{return $false}
}
function AddServerLoginEntryUI {param($Parent,$Server,[string]$Return='detail')
 # 0.23.0: a logged-out page carries one entry, not a credential form. Choosing a
 # method and typing a secret happen in the card, one step at a time.
 $m=$script:DeployUI.Management
 if($m.Authenticated){return}
 $loginHint='登录只读取服务器和设备状态，不会给本机新增授权。'
 $row=Stack 'Horizontal'
 $login=Btn '登录' 'ServerLogin' {
  $model=$script:DeployUI.Management
  $model.LoginStage='Method';$model.LoginMethod='';$model.LoginSecret=$null;$model.LoginReturn=[string]$this.Tag;$model.Error=''
  # One plaintext read per opened card, so the method step can answer immediately.
  $model.SavedLoginNotice='';$model.PendingCredentialReplace=$null;$model.RememberCredential=$true;$null=GetServerSavedLoginInfoUI $model
  ShowServerManagement
 } 'Primary'
 $login.Tag=$Return
 AddC $row $login
 AddC $row (Margin (HintIcon $loginHint) '4,0,0,0')
 AddC $Parent (Margin $row '0,0,0,10')
}
function AddServerLoginMethodStepUI {param($Parent,$Server)
 # Buttons, not radio buttons: the click channel is the one both surfaces carry,
 # and choosing a method is the whole action, so it needs no second confirmation.
 # 0.23.0: one method per line. Three Primary buttons in a row read as a toolbar,
 # which is the shape this change is removing; only the shortest path is primary.
 $m=$script:DeployUI.Management
 AddC $Parent (T '选择登录方式' 12.5 $script:Text2)
 # The saved button exists only when the plaintext check says the envelope is
 # readable AND belongs to this record. "Missing" and "BindingChanged" say why in
 # one line; every other state reads as "never saved" and says nothing at all.
 $savedRef=GetServerSavedLoginRefUI $Server
 $savedInfo=ServerUIGet $m SavedLoginInfo $null
 $savedStatus=if($savedInfo){[string](ServerUIGet $savedInfo Status '')}elseif($savedRef -and $script:Smoke){'Available'}else{''}
 $savedText=GetServerSavedLoginStatusTextUI $savedStatus
 if($savedText){AddC $Parent (Margin (Note $savedText 'amber') '0,10,0,0')}
 $list=Stack;$list.Margin='0,10,0,0'
 $methods=New-Object 'Collections.Generic.List[object]'
 if($savedStatus -ceq 'Available' -and -not (ServerUIGet $m ReinstallStage)){
  $methods.Add((Btn '用已保存的登录资料' 'ServerLoginSaved' {
   $model=$script:DeployUI.Management
   $model.LoginMethod='Saved';$model.LoginStage='';$model.LoginSecret=$null;$model.Error=''
   ConnectServerUI
  } 'Primary'))
 }
 $methods.Add((Btn '用服务器密码' 'ServerLoginPassword' {
  $model=$script:DeployUI.Management;$model.LoginMethod='Password';$model.LoginStage='Credential';$model.Error='';ShowServerManagement
 } 'Btn'))
 $methods.Add((Btn '用 SSH 私钥' 'ServerLoginKey' {
  $model=$script:DeployUI.Management;$model.LoginMethod='Key';$model.LoginStage='Credential';$model.Error='';ShowServerManagement
 } 'Btn'))
 # A vertical stack stretches its children, so each button would fill the card.
 # Left plus a minimum width keeps the native surface identical to the web one.
 foreach($method in $methods){$method.HorizontalAlignment='Left';$method.MinWidth=220;AddC $list (Margin $method '0,0,0,8')}
 $cancel=Btn '取消' 'ServerLoginBack' {ReturnFromServerLoginUI} 'Ghost'
 AddC $list $cancel
 # The envelope has no other surface: this entry is what keeps "remembered"
 # removable without leaving the page that offers it.
 if($savedRef -and -not (ServerUIGet $m ReinstallStage)){
  $forget=Btn '删除已保存的登录资料' 'ServerLoginForget' {
   if(ServerUIReadOnly){ErrorDialog '当前是只读检查窗口，未删除登录资料。';return}
   $model=$script:DeployUI.Management
   if(-not (GetServerSavedLoginRefUI $model.Server)){return}
   OpenDialog '删除这台电脑已保存的登录资料？' ('目标：'+[string](ServerUIGet $model.Server Name '服务器')) '删除只影响这台电脑上的加密文件；服务器账户、线路和授权都不受影响。下次登录需要重新输入。' '删除登录资料' {
    param($context)
    $current=$script:DeployUI.Management
    if(-not $current -or $current.ServerId -cne $context.ServerId){return}
    if($script:Smoke){$current.SavedLoginInfo=$null;$current.SavedLoginNotice='已删除这台电脑已保存的登录资料。';ShowServerManagement;return}
    StartUiCommand -Module 'ServerRegistry.psm1' -Command 'Remove-TCServerCredential' -Arguments @{Root=$script:Root;Id=$current.ServerId} -Context @{Model=$current;ServerId=$current.ServerId} -Complete {
     param($result,$context)
     $now=$script:DeployUI.Management
     if(-not [object]::ReferenceEquals($now,$context.Model)){return}
     $now.SavedLoginInfo=$null
     if($result.FileRemoved){$now.SavedLoginNotice='已删除这台电脑已保存的登录资料。'}
     elseif(@(ServerUIGet $result SharedWith @()).Count){$now.SavedLoginNotice='已停止使用这份登录资料；它仍被其他服务器记录共用，加密文件保留。'}
     else{$now.SavedLoginNotice='已移除登录资料引用；本机没有找到对应文件。'}
     if($now.Server){$now.Server|Add-Member NoteProperty SavedLoginRef $null -Force}
     if(TestServerPageRenderRoleUI -Roles @('servers','devices','product-pair')){RenderServerManagementUI}
    } -Failed {param($message,$context)if([object]::ReferenceEquals($script:DeployUI.Management,$context.Model)){ErrorDialog $message}} -Message '正在删除这台电脑已保存的登录资料…'
   } '取消' 'Primary' @{ServerId=$model.ServerId}
  }
  $forget.HorizontalAlignment='Left';$forget.MinWidth=220;AddC $list (Margin $forget '0,8,0,0')
 }
 AddC $Parent $list
}
function AddServerLoginCredentialStepUI {param($Parent,$Server)
 $m=$script:DeployUI.Management
 $method=[string](ServerUIGet $m LoginMethod 'Password')
 if($method -ceq 'Key'){
  $null=ServerField $Parent '私钥文件' 'ServerKeyPath' KeyPath
  AddC $Parent (Margin (Btn '选择文件…' 'ServerKeyPick' {
   $picked=ChooseFile '选择 SSH 私钥' '所有文件 (*.*)|*.*'
   if($picked){$script:DeployUI.Management.Input.KeyPath=[string]$picked;ShowServerManagement}
  } 'Ghost') '0,8,0,0')
  AddC $Parent (Margin (T '私钥口令（没有口令可留空）' 12.5 $script:Ink 'SemiBold') '0,12,0,5')
 }else{
  AddC $Parent (Margin (T '服务器密码' 12.5 $script:Ink 'SemiBold') '0,12,0,5')
 }
 $password=ControlName (New-Object Windows.Controls.PasswordBox) 'ServerPassword';$password.MinHeight=34;AddC $Parent $password
 # Every repaint between typing and submitting destroys this box (PageHead clears
 # the panel and $script:Controls), so the secret is kept on the model and written
 # back here. The web form keeps its own value from SecretPresent=true.
 $held=ServerUIGet $m LoginSecret $null
 if($held -and $held.Length -gt 0){
  $pointer=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($held)
  try{$password.Password=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)}finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)}
 }
 if((ServerUIGet $script:DeployUI RecoveryRecordId '') -ceq $m.ServerId -and (ServerUIGet $script:DeployUI RecoveredCredential)){AddC $Parent (Margin (Note '已导入的登录资料仅供本次使用，留空即可使用。') '0,8,0,0')}
 $remember=ControlName (New-Object Windows.Controls.CheckBox) 'ServerRememberCredential'
 $remember.Content='在这台电脑记住登录资料'
 $remember.IsChecked=[bool](ServerUIGet $m RememberCredential $true)
 $remember.Margin='0,14,0,0'
 $remember.Add_Click({$script:DeployUI.Management.RememberCredential=[bool]$this.IsChecked})
 AddC $Parent $remember
 AddC $Parent (Margin (T '只保存在这台电脑，用当前 Windows 用户解密。换电脑或换 Windows 用户需要重新输入。' 11.5 $script:Text3) '2,4,0,0')
 # D5: a different login method never overwrites the stored envelope on its own.
 # The question is asked here, before the secret is used, so no credential has to
 # stay alive on the model while a decision is pending.
 $storedKind=[string](ServerUIGet (ServerUIGet $m SavedLoginInfo $null) CredentialKind '')
 $choiceKind=GetServerLoginCredentialKindUI $method
 if($storedKind -and $choiceKind -and $storedKind -cne $choiceKind -and -not (ServerUIGet $m ReinstallStage) -and -not (ServerUIGet $m PendingCredentialReplace $null)){
  AddC $Parent (Margin (Note ('这台电脑保存的是'+(GetServerSavedLoginKindLabelUI $storedKind)+'方式的登录资料。替换会删除原来那份；也可以只在本次使用，保留原资料。') 'amber') '0,14,0,10')
  $choices=Stack
  $replace=Btn '改用这次的方式（替换已保存的资料）' 'ServerLoginReplaceSaved' {
   $model=$script:DeployUI.Management
   $model.PendingCredentialReplace=@{Kind=(GetServerLoginCredentialKindUI ([string](ServerUIGet $model LoginMethod 'Password')))}
   $model.RememberCredential=$true;$model.LoginSecret=$script:Controls.ServerPassword.SecurePassword
   ConnectServerUI
  } 'Primary'
  $replace.HorizontalAlignment='Left';$replace.MinWidth=280;AddC $choices (Margin $replace '0,0,0,8')
  $keep=Btn '保留原资料（本次不保存）' 'ServerLoginKeepSaved' {
   $model=$script:DeployUI.Management
   $model.PendingCredentialReplace=$null;$model.RememberCredential=$false;$model.LoginSecret=$script:Controls.ServerPassword.SecurePassword
   ConnectServerUI
  } 'Btn'
  $keep.HorizontalAlignment='Left';$keep.MinWidth=280;AddC $choices (Margin $keep '0,0,0,8')
  $back=Btn '上一步' 'ServerLoginPrev' {
   $model=$script:DeployUI.Management;$model.LoginStage='Method';$model.Error='';ShowServerManagement
  } 'Ghost'
  $back.HorizontalAlignment='Left';$back.MinWidth=280;AddC $choices $back
  AddC $Parent $choices
  return
 }
 $row=Stack 'Horizontal';$row.Margin='0,14,0,0'
 AddC $row (Btn '上一步' 'ServerLoginPrev' {
  $model=$script:DeployUI.Management;$model.LoginStage='Method';$model.Error='';ShowServerManagement
 } 'Ghost')
 $submit=Btn $(if(ServerUIGet $m ReinstallStage){'只读核验服务器 SSH 身份'}else{'登录并读取设备'}) 'ServerConnect' {
  $model=$script:DeployUI.Management
  $model.LoginSecret=$script:Controls.ServerPassword.SecurePassword
  ConnectServerUI
 } 'Primary'
 AddC $row (Margin $submit '8,0,0,0')
 AddC $Parent $row
}
function AddServerLoginCardUI {param($Parent,$Server)
 $m=$script:DeployUI.Management
 $card=Card;$p=Stack;$card.Child=$p
 # 页面标题与摘要行已经写明是哪台服务器、当前是否已登录；卡片只回答
 # 「这一步做什么」，不再重复名称、地址和「登录这台服务器」。
 if($m.Error){AddC $p (Margin (Note $m.Error 'amber') '0,0,0,10')}
 if((ServerUIGet $m LoginStage '') -ceq 'Credential'){AddServerLoginCredentialStepUI $p $Server}else{AddServerLoginMethodStepUI $p $Server}
 AddC $Parent (Margin $card '0,0,0,16')
}
function ReturnFromServerLoginUI {
 # Leaving the card returns to whichever page owns it; the model already knows.
 InitializeServerUI;$m=$script:DeployUI.Management
 $m.LoginStage='';$m.LoginMethod='';$m.LoginReturn='';$m.LoginSecret=$null;$m.Error=''
 ShowServerManagement
}
function AddServerNoticesUI {param($Parent,$Server,[switch]$NoError)
 # 0.22.0 B4: everything that must be read directly stays on top of the sections,
 # in the same order as 0.21.7 (error, pending result, unfinished runs, reinstall).
 # -NoError is for the login card, which already carries the same sentence.
 $m=$script:DeployUI.Management
 # The saved-login result outlives the card: it is the only confirmation the page
 # ever gives that "remembered on this computer" actually happened.
 if(ServerUIGet $m SavedLoginNotice ''){AddC $Parent (Note ([string](ServerUIGet $m SavedLoginNotice '')))}
 if($m.Error -and -not $NoError){AddC $Parent (Note $m.Error 'amber')}
 if(ServerUIGet $m ErrorCode){$null=ManagementDetails $Parent ('诊断代码：'+$m.ErrorCode)}
 # 0.23.0: a record that changed under the operator used to be a dead end. The
 # re-read is offered here, in the words of the record itself, not as a list refresh.
 if((ServerUIGet $m RecordStale $false) -and -not $m.Authenticated){
  AddC $Parent (Note '这台服务器的记录或身份已变化，需要重新读取。' 'amber')
  $null=DeploymentActions $Parent '重新读取服务器记录' 'ServerRecordReload' {LoadServersUI} 'Ghost'
 }
 if((ServerUIGet $m UnresolvedIntent) -and -not (ServerUIGet $m ReinstallStage)){
  AddC $Parent (Note ('上次管理操作结果待确认：'+(ManagementLabel $m.UnresolvedIntent.Operation)+'。请先检查原操作结果。') 'amber')
  $null=DeploymentActions $Parent '查询上次管理操作的实际结果' 'ManagementReconcile' {ReconcileManagementIntentUI} 'Ghost'
  $null=DeploymentActions $Parent '已确认结果，解除本机提交限制…' 'ManagementResolveIntent' {ResolveManagementIntentUI} 'Ghost'
 }
 $runs=@(ServerUIGet $script:DeployUI.Discovery ContinueRuns @()|Where-Object {(ServerUIGet $_ ServerRecordId '') -ceq $Server.LocalRecordId})
 if($runs.Count){
  AddC $Parent (Margin (T '这台服务器还有未完成的准备' 13 $script:Ink 'SemiBold') '0,12,0,0')
  foreach($run in $runs){$id=[string](ServerUIGet $run RunId '');if($id){$b=DeploymentActions $Parent ('继续原准备：'+(ManagementLabel ([string](ServerUIGet $run Stage '')))) ('ServerContinue'+($id-replace '-','')) {ResumeProductDeployment ([string]$this.Tag)} 'Ghost';$b.Tag=$id}}
 }
 if(ServerUIGet $m ReinstallStage){
  AddC $Parent (Note '正在核验服务器 SSH 身份。原指纹、任务和资料保留，当前线路保持。')
  if($m.ReinstallStage -ceq 'AwaitingTrust'){$null=DeploymentActions $Parent '确认新指纹并建立新记录…' 'ServerReinstallTrust' {ShowServerReinstallTrustUI}}
  if($m.ReinstallStage -notin @('Previewing','Committing')){$null=DeploymentActions $Parent '退出本次身份核验，保留原记录' 'ServerReinstallCancel' {ResetServerReinstallUI} 'Ghost'}
 }
 if($script:DeployUI.PendingManagement){AddC $Parent (Margin (Note ('正在处理：'+(ManagementLabel $script:DeployUI.PendingManagement.Purpose)+'。确认结果前不重复提交。')) '0,12,0,0')}
}
function AddServerOfflineInviteBodyUI {param($Parent,$Server)
 $m=$script:DeployUI.Management
 AddC $Parent (T '1. 生成 24 小时邀请，把邀请内容交给新电脑。' 12.5 $script:Text2)
 AddC $Parent (Margin (T '2. 新电脑生成申请后，回到这里批准。' 12.5 $script:Text2) '0,6,0,12')
 $null=DeploymentActions $Parent '生成一次性邀请（24 小时）' 'ServerCreateInvite' {StartServerOperation invite_create @{DeviceName=(GetTCInviteDeviceLabel);ExpiresInHours=24} InviteCreate}
 if($script:DeployUI.Invite){
  AddC $Parent (Margin (T ('邀请：'+(ManagementLabel $script:DeployUI.Invite.State)+' · 到期 '+(ManagementTime $script:DeployUI.Invite.ExpiresAtUtc)) 12 $script:Text3) '0,10,0,0')
  if(ServerUIGet $m InviteFingerprint){AddC $Parent (T ('请与新电脑确认签名指纹：'+$m.InviteFingerprint) 12 $script:Text3)}
  $null=DeploymentActions $Parent '复制邀请并打开交接页' 'ServerCopyInvite' {$null=CopyText ([string]$script:DeployUI.Invite.Invite) '已复制邀请';ShowProductPairing -Role Manager} 'Ghost'
  $null=DeploymentActions $Parent '取消这个邀请' 'ServerCancelInvite' {StartServerOperation invite_cancel @{InviteId=$script:DeployUI.Invite.InviteId} InviteCancel} 'Ghost'
 }
 $null=DeploymentActions $Parent '批准新电脑申请…' 'ServerPairAuthorize' {ShowProductPairing -Role Manager} 'Ghost'
}
function ShowServerOfflineInviteUI {
 InitializeServerUI;InitializeServerNavigationUI
 $n=$script:ServerNavigationUI;$m=$script:DeployUI.Management;$server=$m.Server
 if(-not $server){$n.View='server-detail';ShowServerDetailUI;return}
 $n.View='server-offline';$m.DetailTab='devices';$script:Page='setup';$script:Role='servers';$script:DeployUI.ManagementMode=$true
 SetServerNavigationPositionUI;Head '' '离线邀请（24 小时）' ([string](ServerUIGet $server Name '服务器'))
 AddC $script:HostPanel (Btn '返回' 'ServerOfflineInviteBack' {ReturnFromServerOfflineInviteUI} 'Ghost')
 # The login card owns the sentence when it is open, so the page does not repeat it.
 if((ServerUIGet $m LoginStage '') -and -not $m.Authenticated){AddServerLoginCardUI $script:HostPanel $server;return}
 if($m.Error){AddC $script:HostPanel (Note $m.Error 'amber')}
 $card=Card;$p=Stack;$card.Child=$p
 # 0.22.3: the page head already says 离线邀请（24 小时）; the card repeats it
 # nowhere and the two numbered steps below carry the explanation.
 if($m.Authenticated){AddServerOfflineInviteBodyUI $p $server}else{AddServerLoginEntryUI $p $server 'offline'}
 AddC $script:HostPanel (Margin $card '0,16,0,0')
}
function AddServerDevicesSectionUI {param($Parent,$Server)
 $m=$script:DeployUI.Management
 $info=$m.Info
 $signing=[bool](ServerUIGet $info ManagementSigningPublicKey)
 $webReady=$script:WebReady -and -not $script:WebFailed -and (Get-Command OpenTCWebInviteFromServerPageUI -ErrorAction SilentlyContinue)
 $card=Card;$p=Stack;$card.Child=$p
 # 0.22.3: one toolbar replaces three stacked headings. The tab already says
 # 设备与邀请, so the card carries no title of its own; the invite button is the
 # section's primary action and the counters are its metadata, not headings.
 if($signing -and -not $webReady -and (Get-Command AddOnlineInviteCardUI -ErrorAction SilentlyContinue)){AddOnlineInviteCardUI $p}
 $bar=Grid @('*','Auto')
 $left=Stack 'Horizontal'
 if($signing -and $webReady -and (Get-Command AddOnlineInviteCardUI -ErrorAction SilentlyContinue)){AddOnlineInviteCardUI $left}
 elseif(-not $signing){$null=DeploymentActions $left '启用设备与邀请管理…' 'ServerManagementUpgrade' {StartServerOperation management_plan @{} ManagementPlan} 'Ghost'}
 Cell $bar $left 0
 $right=Stack 'Horizontal';$right.HorizontalAlignment='Right';$right.VerticalAlignment='Center'
 $result=$script:DeployUI.DeviceResult
 if($result){
  $active=[int]$result.ActiveDeviceCount;$revoked=[int]$result.RevokedDeviceCount
  $t=T ('活跃 '+$active) 12 $script:Text3;$t.VerticalAlignment='Center';AddC $right (Margin $t '0,0,14,0')
  if($revoked -gt 0){$t2=T ('已撤销 '+$revoked) 12 $script:Text3;$t2.VerticalAlignment='Center';AddC $right (Margin $t2 '0,0,14,0')}
 }
 $refresh=Btn '刷新' 'ServerDevices' {StartServerOperation server_info @{} ServerInfo} 'Ghost'
 AddC $right $refresh
 Cell $bar $right 1
 AddC $p (Margin $bar '0,0,0,14')
 AddServerDevicesUI $p
 if($signing){$null=DeploymentActions $p '新电脑连不上 18443？使用离线邀请（24 小时）' 'ServerOfflineInvite' {OpenServerOfflineInviteUI -Origin ServerDevices} 'Ghost'}
 AddC $Parent (Margin $card '0,0,0,16')
}
function AddServerMaintenanceSectionUI {param($Parent,$Server)
 $m=$script:DeployUI.Management;$info=$m.Info;$n=$script:ServerNavigationUI
 $card=Card;$p=Stack;$card.Child=$p
 if($info){KeyValue $p '服务器实时状态' (ManagementLabel ([string](ServerUIGet $info OwnershipState 'Managed')));$null=ManagementDetails $p ('服务器身份：'+[string]$info.RemoteOwnerId+'；管理接口：'+[string]$info.ManagementApiVersion+'；配置修订：'+[string]$info.ConfigRevision)}
 if($n.Line -and (Get-Command LegacyLineNeedsTcpMaintenance -ErrorAction SilentlyContinue) -and (LegacyLineNeedsTcpMaintenance $n.Line)){$null=DeploymentActions $p '为原线路补齐 TCP 备用' 'ServerLineTcp' {OpenAutomaticTransport $script:ServerNavigationUI.LineId} 'Ghost'}
 $transport=Stack;$null=ServerField $transport '新增 TCP 服务端口' 'ServerTcpPort' TcpPort;$null=ServerField $transport 'Reality 握手域名' 'ServerTcpName' ServerName
 $null=DeploymentActions $transport '预览为现有 UDP 增加 TCP…' 'ServerTcpPreview' {$port=0;if(-not [int]::TryParse($script:DeployUI.Management.Input.TcpPort,[ref]$port)){ErrorDialog '请填写有效 TCP 端口。';return};StartServerOperation transport_plan @{Transport=@{Type='tcp-reality';Port=$port;ServerName=$script:DeployUI.Management.Input.ServerName}} TransportPlan} 'Ghost'
 $exp=New-Object Windows.Controls.Expander;$exp.Header='为服务器增加 TCP 连接方式';$exp.Content=$transport;AddC $p $exp
 $null=DeploymentActions $p '检查与恢复未完成操作…' 'ServerRecover' {OpenDialog '恢复未完成的服务器操作？' '将检查本工具管理的资源和原操作结果，再执行恢复；可能撤回未完成的服务器变更。' '不会替换本机线路；存在外部变更时停止并保留证据。' '检查并恢复' {StartServerOperation recover @{} Recover}} 'Ghost'
 if(-not (ServerUIGet $m ReinstallStage) -and (ServerUIGet $Server PinnedHostKey '')){$null=DeploymentActions $p '验证服务器身份变化…' 'ServerReinstall' {BeginDeploymentIdentityVerification ([string]$script:DeployUI.Management.ServerId)} 'Ghost'}
 AddC $Parent (Margin $card '0,0,0,16')
}
function AddServerRecordsSectionUI {param($Parent)
 $card=Card;$p=Stack;$card.Child=$p
 $null=DeploymentActions $p '导出或导入管理恢复资料' 'ServerRecovery' {ShowManagementRecovery -Mode All} 'Ghost'
 $danger=Stack;AddC $danger (Note '卸载会影响这台服务器的所有关联设备，不只是从哪条线路进入的这台电脑。' 'amber')
 $null=DeploymentActions $danger '预览卸载服务器服务…' 'ServerUninstallPreview' {StartServerOperation uninstall_preview @{} UninstallPreview} 'Ghost'
 $exp=New-Object Windows.Controls.Expander;$exp.Header='停用这台服务器的服务';$exp.Content=$danger;AddC $p (Margin $exp '0,16,0,0');AddC $Parent $card
}
function ShowServerDetailUI {
 $n=$script:ServerNavigationUI;$m=$script:DeployUI.Management
 if($n.Loading -and $n.PendingIntent -ceq 'Login'){
  SetServerNavigationPositionUI;Head '' '登录这台服务器' '正在准备登录…'
  AddServerNavigationActionsUI $script:HostPanel -Detail
  AddC $script:HostPanel (Note '正在读取服务器记录，完成后在本页选择登录方式。');return
 }
 if($n.Message -and $n.PendingIntent -ceq 'Login'){
  SetServerNavigationPositionUI;Head '' '登录这台服务器' ''
  AddServerNavigationActionsUI $script:HostPanel -Detail
  AddC $script:HostPanel (Note $n.Message 'amber')
  $null=DeploymentActions $script:HostPanel '重试' 'ServerLoginRetry' {$returnContext=$script:ServerNavigationUI.ReturnContext;OpenServerRecordManagement $script:ServerNavigationUI.SelectedServerId -ReturnKind $script:ServerNavigationUI.ReturnKind -Intent Login;$script:ServerNavigationUI.ReturnContext=$returnContext} 'Ghost';return
 }
 $server=if($n.DetailKind -eq 'Archived'){$n.ArchivedRecord}else{$m.Server}
 # 加载/失败分支已在上面用「登录这台服务器」承接；就绪后保持详情页标题，
 # 让卡片独占「登录这台服务器」，页标题与卡片标题不重复。
 SetServerNavigationPositionUI;Head '' '服务器与设备' ''
 AddServerNavigationActionsUI $script:HostPanel -Detail
 if(-not $server){AddC $script:HostPanel (Note '服务器记录暂不可用，请返回列表刷新。' 'amber');return}
 # 0.22.3: the server card is gone. Identity, login state and the related line are
 # one line under the title; the deployment state and the registry count were
 # removed because this page does not ask those questions.
 AddServerSummaryLineUI $script:HostPanel $server
 if((ServerUIGet $server RecordState 'Active') -eq 'Archived'){
  $card=Card;$p=Stack;$card.Child=$p
  AddC $p (Note '此身份已归档。旧设备、授权与任务保留为历史，不能用于重装后的服务器。')
  $replacement=[string](ServerUIGet $server ReplacedByServerId '')
  if($replacement){$b=DeploymentActions $p '查看重装后的服务器记录' 'ViewReplacementServer' {SelectServerUI ([string]$this.Tag)} 'Ghost';$b.Tag=$replacement}
  AddC $script:HostPanel $card;return
 }
 $connectorOnly=(ServerUIGet $server ManagementAccessState '') -eq 'ConnectorOnly' -or -not $server.Connection
 if($connectorOnly){
  $card=Card;$p=Stack;$card.Child=$p
  AddC $p (Note '此电脑只有线路使用权，设备与邀请由管理电脑处理。')
  if($n.LineId){$null=DeploymentActions $p '返回原线路查看连接方式' 'ConnectorBackToLine' {LoadLineConnections $script:ServerNavigationUI.LineId} 'Ghost'}
  AddC $script:HostPanel $card;return
 }
 # 0.23.0: while the login card is open it owns the page; a logged-out page shows
 # one entry and nothing else, so no section advertises a capability it cannot use.
 # A stale stage must never take over a page that is already logged in.
 if((ServerUIGet $m LoginStage '') -and -not $m.Authenticated){
  $card=Card;$p=Stack;$card.Child=$p
  AddServerNoticesUI $p $server -NoError
  if($p.Children.Count){AddC $script:HostPanel (Margin $card '0,0,0,16')}
  AddServerLoginCardUI $script:HostPanel $server
  return
 }
 if(-not $m.Authenticated){
  $card=Card;$p=Stack;$card.Child=$p
  AddServerNoticesUI $p $server
  if($p.Children.Count){AddC $script:HostPanel (Margin $card '0,0,0,16')}
  AddServerLoginEntryUI $script:HostPanel $server 'detail'
  # 0.23.0: a reissued host key blocks the login itself, so this entry cannot live
  # behind the tabs it used to sit in. A pinned key is not a change, though: only a
  # page that already reports an identity problem may say 变化, otherwise the wording
  # would tell every logged-out user that something changed when nothing did.
  if(-not (ServerUIGet $m ReinstallStage) -and (ServerUIGet $server PinnedHostKey '')){
   $label=if([string]$m.Error -match '身份|指纹|HostKey|Fingerprint'){'服务器身份已变化，重新验证…'}else{'服务器身份核验…'}
   $null=DeploymentActions $script:HostPanel $label 'ServerReinstall' {BeginDeploymentIdentityVerification ([string]$script:DeployUI.Management.ServerId)} 'Ghost'
  }
  return
 }
 # Login and notices keep a card, but only when they have something to say. A
 # healthy session used to open on a full-width card that carried nothing.
 $card=Card;$p=Stack;$card.Child=$p
 AddServerNoticesUI $p $server
 if($p.Children.Count){AddC $script:HostPanel (Margin $card '0,0,0,16')}
 AddServerDetailTabsUI $script:HostPanel
 switch(GetServerDetailTabUI){
  'devices'{AddServerDevicesSectionUI $script:HostPanel $server}
  'maintenance'{AddServerMaintenanceSectionUI $script:HostPanel $server}
  'records'{AddServerRecordsSectionUI $script:HostPanel}
 }
}
function AddServerDeviceRowUI {param($Parent,$Device)
 # 0.22.3: a row, not a card. Name, state, authorization time and the two actions
 # share one line; the device identity moved into the ⓘ so a list of ten devices
 # no longer means ten expanders and twenty stacked buttons.
 $m=$script:DeployUI.Management;$id=[string]$Device.DeviceId
 $state=[string]$Device.State
 $renaming=([string]$m.Input.RenameId -ceq $id)
 $row=Grid @('*','90','120','150');$row.Margin='0,0,0,10'
 $nameCell=Stack 'Horizontal'
 if($renaming){
  $box=ControlName (New-Object Windows.Controls.TextBox) 'DeviceNewName'
  $box.Text=[string]$m.Input.RenameName;$box.MinWidth=200;$box.MinHeight=30
  $box.Add_TextChanged({$script:DeployUI.Management.Input.RenameName=$this.Text})
  AddC $nameCell $box
 }else{
  AddC $nameCell (T ([string]$Device.Name) 13.5 $script:Ink 'SemiBold')
  AddC $nameCell (Margin (HintIcon ('设备身份：'+$id+'；隧道地址：'+[string]$Device.ClientAddress)) '6,0,0,0')
 }
 Cell $row $nameCell 0
 Cell $row (Pill (ManagementLabel $state) $(if($state -ceq 'Authorized'){'ok'}else{'idle'})) 1
 $when=if($Device.AuthorizedAtUtc){ManagementTime $Device.AuthorizedAtUtc}else{'—'}
 $t=T $when 12.5 $script:Text3;$t.VerticalAlignment='Center'
 Cell $row $t 2
 $actions=Stack 'Horizontal';$actions.HorizontalAlignment='Right';$actions.VerticalAlignment='Center'
 if($renaming){
  $save=Btn '保存' 'DeviceRenameSave' {StartServerOperation device_rename @{DeviceId=$script:DeployUI.Management.Input.RenameId;Name=$script:DeployUI.Management.Input.RenameName;ExpectedConfigRevision=[int]$script:DeployUI.DeviceResult.ConfigRevision} Rename} 'Primary'
  AddC $actions $save
  $cancel=Btn '取消' 'DeviceRenameCancel' {$script:DeployUI.Management.Input.RenameId='';$script:DeployUI.Management.Input.RenameName='';ShowServerManagement} 'Ghost'
  AddC $actions (Margin $cancel '6,0,0,0')
 }else{
  $rename=Btn '改名' ('DeviceRename'+($id-replace '-','')) {$script:DeployUI.Management.Input.RenameId=$this.Tag.Id;$script:DeployUI.Management.Input.RenameName=$this.Tag.Name;ShowServerManagement} 'Ghost'
  $rename.Tag=@{Id=$id;Name=[string]$Device.Name};AddC $actions $rename
  if($state -ceq 'Authorized'){
   $revoke=Btn '撤权' ('DeviceRevoke'+($id-replace '-','')) {StartServerOperation revoke_preview @{DeviceId=[string]$this.Tag} RevokePreview} 'Ghost'
   $revoke.Tag=$id;AddC $actions (Margin $revoke '6,0,0,0')
  }
 }
 Cell $row $actions 3
 AddC $Parent $row
 $sep=New-Object Windows.Controls.Border
 $sep.BorderBrush=B $script:Hair;$sep.BorderThickness='0,0,0,1';$sep.Margin='0,0,0,10'
 AddC $Parent $sep
}
function AddServerDevicesUI {param($Parent)
 $m=$script:DeployUI.Management;$result=$script:DeployUI.DeviceResult
 if(-not $result){
  # 0.22.3: the empty state carries the action instead of telling the operator to
  # do something this screen cannot do.
  $empty=Stack
  AddC $empty (T '还没有读取设备。' 12.5 $script:Text3)
  $b=Btn '读取设备' 'ServerDevicesEmpty' {StartServerOperation server_info @{} ServerInfo} 'Ghost'
  AddC $empty (Margin $b '0,8,0,0')
  AddC $Parent $empty;return
 }
 $all=@(ServerUIGet $result Devices @())
 $active=@($all|Where-Object {[string]$_.State -cne 'Revoked'})
 $revoked=@($all|Where-Object {[string]$_.State -ceq 'Revoked'})
 # Fixed column widths: each row is its own Grid, so Auto columns would size to
 # their own content and the header would stop lining up with the rows.
 $head=Grid @('*','90','120','150')
 AddC $head (T '设备' 12 $script:Text3 'SemiBold')
 Cell $head (T '状态' 12 $script:Text3 'SemiBold') 1
 Cell $head (T '授权时间' 12 $script:Text3 'SemiBold') 2
 $h4=T '操作' 12 $script:Text3 'SemiBold';$h4.HorizontalAlignment='Right';Cell $head $h4 3
 AddC $Parent (Margin $head '0,0,0,10')
 if(-not $active.Count){
  $empty=Stack
  AddC $empty (T '还没有其他电脑加入。' 12.5 $script:Text3)
  if($script:WebReady -and -not $script:WebFailed -and (Get-Command OpenTCWebInviteFromServerPageUI -ErrorAction SilentlyContinue)){
   $b=Btn '邀请其他电脑' 'ServerEmptyInvite' {OpenTCWebInviteFromServerPageUI} 'Primary'
   AddC $empty (Margin $b '0,10,0,0')
  }
  AddC $Parent (Margin $empty '0,4,0,12')
 }else{
  foreach($device in $active){AddServerDeviceRowUI $Parent $device}
 }
 if($revoked.Count){
  $exp=New-Object Windows.Controls.Expander;$exp.Header=('已撤销 '+$revoked.Count);$exp.IsExpanded=$false
  $rp=Stack;$exp.Content=$rp
  foreach($device in $revoked){AddServerDeviceRowUI $rp $device}
  AddC $Parent (Margin $exp '0,6,0,0')
 }
 if($null -ne $result.NextOffset){$null=DeploymentActions $Parent '查看下一页设备' 'DevicesNext' {StartServerOperation devices @{Offset=[int]$script:DeployUI.DeviceResult.NextOffset;Limit=50;IncludeRevoked=$true} Devices} 'Ghost'}
}