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
 $labels=@{Applied='已部署';Uninstalled='服务已卸载';NotInstalled='尚未部署';OwnedNotInstalled='部署未完成';NeedsRecovery='需要恢复';AwaitIdentityVerification='等待身份核验';Unverified='尚未核验';Managed='已识别归属';Authenticated='管理账户已验证';NeedsAuthentication='需要管理登录';ConnectorOnly='仅有连接使用权';Authorized='已授权';Revoked='已撤销';Inactive='服务未启用';Open='待使用';Consumed='已使用';Cancelled='已取消';Expired='已过期';Prepared='已准备';Dispatched='已提交';Running='处理中';OutcomeUnknown='结果待核对';AuthorizedReturnPending='已授权，等待交接';Completed='已完成';Complete='已完成';Rejected='未执行成功';Failed='需要处理';WaitingUser='等待继续';ReadyInactive='已准备，尚未启用';MaterializeCandidate='准备本机线路';ProbeCandidate='验证候选线路';Inspect='检查环境';PrepareAccess='准备登录';PlanReady='等待核对变更';ApplyOrAuthorize='部署或授权';ServerInfo='读取服务器状态';Devices='读取设备';Authenticate='管理登录';InviteCreate='生成邀请';InviteCancel='取消邀请';AuthorizeExternal='授权新电脑';TransportPlan='准备连接方式预览';TransportApply='添加连接方式';ReconcileServer='核对服务器结果';ReconcileInvite='核对原邀请';ReconcilePairInvite='核对原申请';ReconcileDevices='核对设备状态';Recover='恢复未完成操作';Rename='更新设备名称';Revoke='撤销指定设备';Uninstall='卸载自有服务';management_apply='启用管理能力';device_rename='更新设备名称';invite_create='生成邀请';invite_cancel='取消邀请';authorize_external='授权新电脑';transport_apply='添加连接方式';request_status='查询原申请'}
 $labels.Archived='重装前身份已归档';$labels.ReinstallObserve='只读核验新 SSH 身份';$labels.ReinstallTrust='等待核对新指纹';$labels.ReinstallAuthenticate='认证已确认的新指纹';$labels.ReinstallConfirm='建立新的管理记录'
 $labels.InvitationPinned='邀请接入'
 if($labels.ContainsKey($Value)){return $labels[$Value]};return '需要核对'
}
function ManagementDetails {param($Parent,[string]$Text,[string]$Title='技术详情')
 $expand=New-Object Windows.Controls.Expander;$expand.Header=$Title;$expand.Margin='0,8,0,0';$expand.IsExpanded=$false;$expand.Content=T $Text 11.5 $script:Text3;AddC $Parent $expand;return $expand
}
function ManagementTime {param($Value)try{return ([DateTimeOffset]::Parse([string]$Value)).LocalDateTime.ToString('MM-dd HH:mm')}catch{return '时间未知'}}
function ServerErrorText {param([string]$Code)
 switch($Code){
  'MissingManagementDependency'{'服务器缺少 OpenSSL。管理查询没有自动安装；请在明确的组件准备阶段安装发行版 openssl 后重新预览。'}
  'PlanExpired'{'预览已过期。请重新检查并生成预览，原设备申请保留。'}
  'RevisionConflict'{'服务器配置在预览后发生变化。请刷新设备和服务器，再核对新的变更。'}
  'ApprovalMismatch'{'批准摘要与目标或配置修订不匹配，请重新预览。'}
  'InviteUnavailable'{'邀请已取消或过期，请由管理端重新生成邀请。'}
  'InviteConsumed'{'邀请已被其他申请消费。请核对原申请和设备列表，不要重复新增设备。'}
  'InvalidSignature'{'交接签名不匹配，请重新复制原邀请或原申请，核对来源。'}
  'NeedsRecovery'{'服务器有未完成事务，请使用「检查与恢复事务」核对实际结果，再继续。'}
  'TransportAlreadyEnabled'{'此服务器已配置 TCP。新增向导只处理 UDP 增加 TCP，不覆盖现有 TCP 认证和参数。'}
  'NodeUninstalled'{'服务器服务已卸载，保留的台账和身份不代表服务仍可连接。'}
  'AuthorizationConflict'{'这份申请、设备或密钥已注册或已撤销，请查询原申请结果或按新身份流程处理。'}
  'AddressPoolExhausted'{'没有空闲设备地址。已退役地址不会自动复用，需要管理员安排网段维护。'}
  default{'服务器未完成此操作。请保留原资料并核对实际状态，具体原因可展开技术详情。'}
 }
}
function InitializeServerUI {
 if(-not $script:DeployUI.Management){$script:DeployUI.Management=@{ServerId=$null;Server=$null;Info=$null;SessionRef=$null;Credential=$null;Authenticated=$false;TrustShown=$null;LastPoll=[DateTime]::MinValue;Error='';Input=@{DeviceName='新电脑';TcpPort='443';ServerName='www.bing.com';RenameId='';RenameName='';KeyPath=''};Preview=$null;InviteHistory=@()}}
}
function InitializeServerNavigationUI {
 if(-not (Get-Variable ServerNavigationUI -Scope Script -ErrorAction SilentlyContinue) -or -not $script:ServerNavigationUI){
  $script:ServerNavigationUI=@{View='server-list';ReturnKind='DeploymentCenter';ReturnContext=$null;LineId='';Line=$null;SelectedServerId='';DetailKind='Managed';Message='';Bindings=@();RequestId='';Loading=$false;ShowArchived=$false}
 }
}
function SetServerNavigationPositionUI {
 InitializeServerNavigationUI
 if(Get-Command SetNavigationContext -ErrorAction SilentlyContinue){SetNavigationContext -Section nodes -View $script:ServerNavigationUI.View -TargetId $(if($script:ServerNavigationUI.SelectedServerId){$script:ServerNavigationUI.SelectedServerId}else{$script:ServerNavigationUI.LineId})}
}
function OpenServerManagement {param([ValidateSet('Nodes','LineProfiles','DeploymentCenter','Context')][string]$ReturnKind='DeploymentCenter')
 if((IsBusy) -or (Get-Variable QueuedJob -Scope Script -ValueOnly -ErrorAction SilentlyContinue)){return}
 if($script:DeployUI.PendingManagement){ErrorDialog '当前服务器操作尚未结束，请核对结果后再切换管理入口。';return};$script:AutoTCP=$null
 $context=$null;if(Get-Command CaptureNavigationContext -ErrorAction SilentlyContinue){$context=CaptureNavigationContext}
 $script:ServerNavigationUI=$null;InitializeServerNavigationUI
 $script:ServerNavigationUI.ReturnKind=$ReturnKind;$script:ServerNavigationUI.ReturnContext=$context
 InitializeServerUI;$script:DeployUI.Management.ReadContinuation='';$script:DeployUI.ManagementMode=$true
 ShowServerManagement
}
function ReturnFromServerManagement {
 InitializeServerNavigationUI;$n=$script:ServerNavigationUI
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
 InitializeServerNavigationUI;$script:ServerNavigationUI.View='server-list';$script:ServerNavigationUI.DetailKind='Managed';$script:ServerNavigationUI.Message='';$script:ServerNavigationUI.Loading=$false;$script:ServerNavigationUI.RequestId=''
 ShowServerManagement
}
function OpenLineServerManagement {param([string]$LineId,[ValidateSet('Nodes','LineProfiles')][string]$ReturnKind='LineProfiles')
 if((IsBusy) -or -not $LineId -or (Get-Variable QueuedJob -Scope Script -ValueOnly -ErrorAction SilentlyContinue)){return}
 if($script:DeployUI.PendingManagement){ErrorDialog '当前服务器操作尚未结束，请核对结果后再切换管理入口。';return};$script:AutoTCP=$null
 $context=$null;if(Get-Command CaptureNavigationContext -ErrorAction SilentlyContinue){$context=CaptureNavigationContext}
 $script:ServerNavigationUI=$null;InitializeServerNavigationUI;$n=$script:ServerNavigationUI
 $n.View='server-detail';$n.DetailKind='Binding';$n.ReturnKind=$ReturnKind;$n.ReturnContext=$context;$n.LineId=$LineId;$n.Loading=$true;$n.RequestId=[guid]::NewGuid().ToString('N')
 $requestId=$n.RequestId
 InitializeServerUI;$script:DeployUI.Management.ReadContinuation='';$script:DeployUI.ManagementMode=$true
 ShowServerManagement
 $completeHandler=${function:CompleteLineServerNavigationUI};$failedHandler=${function:FailLineServerNavigationUI}
 $complete={param($line)& $completeHandler $line $requestId}.GetNewClosure()
 $failed={param($message)& $failedHandler $requestId '无法读取这条线路的服务器关联，请刷新后重试。'}.GetNewClosure()
 # Navigation uses the read-only view; it never registers, prepares or activates a line.
 StartJob @{Action='LineProfiles';Id=$LineId} $complete '读取这条线路的服务器关联…' '' -Failed $failed
}
function OpenServerRecordManagement {param([string]$ServerId,[ValidateSet('Context','DeploymentCenter','Nodes')][string]$ReturnKind='Context')
 if((IsBusy) -or -not $ServerId -or (Get-Variable QueuedJob -Scope Script -ValueOnly -ErrorAction SilentlyContinue)){return}
 if($script:DeployUI.PendingManagement){ErrorDialog '当前服务器操作尚未结束，请核对结果后再切换管理入口。';return};$script:AutoTCP=$null
 $context=$null;if(Get-Command CaptureNavigationContext -ErrorAction SilentlyContinue){$context=CaptureNavigationContext}
 $script:ServerNavigationUI=$null;InitializeServerNavigationUI;$n=$script:ServerNavigationUI
 $n.View='server-detail';$n.DetailKind='Binding';$n.ReturnKind=$ReturnKind;$n.ReturnContext=$context;$n.SelectedServerId=$ServerId;$n.Loading=$true;$n.RequestId=[guid]::NewGuid().ToString('N')
 $requestId=$n.RequestId;InitializeServerUI;$script:DeployUI.Management.ReadContinuation='';$script:DeployUI.ManagementMode=$true;ShowServerManagement
 $completeHandler=${function:CompleteServerRecordNavigationUI};$failedHandler=${function:FailLineServerNavigationUI}
 $complete={param($data)& $completeHandler $data $requestId $ServerId}.GetNewClosure()
 $failed={param($message)& $failedHandler $requestId '服务器记录暂时无法读取，请返回来源重试。'}.GetNewClosure()
 StartJob @{Action='DeploymentDiscover'} $complete '读取指定服务器记录…' '' -Failed $failed
}
function CompleteServerRecordNavigationUI {param($Data,[string]$RequestId,[string]$ServerId)
 if(-not (TestServerNavigationRequestUI $RequestId)){return}
 $script:DeployUI.Discovery=$Data;$script:DeployUI.ServerDiscoveryAttempted=$true;$script:ServerNavigationUI.Loading=$false
 $matches=@(ServerUIGet $Data Servers @()|Where-Object {$_.LocalRecordId -ceq $ServerId})
 if($matches.Count -ne 1){$script:ServerNavigationUI.Message='指定服务器记录不唯一或已不存在，请返回来源刷新。';ShowServerManagement;return}
 if((ServerUIGet $matches[0] RecordState 'Active') -eq 'Archived'){OpenArchivedServerUI $ServerId}else{SelectServerUI $ServerId}
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
  $n.Message=if($block){[string](ServerUIGet $Line ServerConnectionMessage '服务器关联需要核对。')}elseif(-not $n.Bindings.Count){'此线路尚未绑定本机服务器管理记录。可以继续使用已准备的连接；管理前需核对服务器身份，不能仅凭地址关联。'}else{'此线路对应多个服务器记录，请先核对台账，未自动选择。'}
  ShowServerManagement;return
 }
 $binding=$n.Bindings[0]
 if((ServerUIGet $binding RecordState 'Active') -ne 'Active'){$n.Loading=$false;$n.Message='此线路属于已归档的服务器身份，旧线路不能继续原授权。';ShowServerManagement;return}
 $serverId=[string]$binding.LocalRecordId;$key=[string](ServerUIGet $Line ServerPublicKey '')
 $completeHandler=${function:CompleteLineServerDiscoveryUI};$failedHandler=${function:FailLineServerNavigationUI}
 $complete={param($d)& $completeHandler $d $RequestId $serverId $key}.GetNewClosure()
 $failed={param($message)& $failedHandler $RequestId '服务器台账暂时无法读取，请重试。'}.GetNewClosure()
 StartJob @{Action='DeploymentDiscover'} $complete '核对已绑定的服务器记录…' '' -Failed $failed
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
 return ($Operation -in @('management_apply','device_rename','invite_create','invite_cancel','authorize_external','revoke','uninstall','transport_apply','recover') -or ($Operation -eq 'request_status' -and (ServerUIGet $InputData RefreshAuthorization $false)))
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
  management_apply=@('PlanId','ApprovedChangeDigest');device_rename=@('DeviceId','Name','ExpectedConfigRevision');invite_create=@('InviteId','DeviceName','ExpiresInHours');invite_cancel=@('InviteId');
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
 OpenDialog '已核对这次管理操作的真实结果？' ('动作：'+(ManagementLabel $intent.Operation)+'。此按钮只解除本机的重复提交阻止，不改变服务器。') '未完成远端事务仍必须恢复。下一次变更需重新生成预览；授权始终复用原申请。' '结果已核对，解除本机阻止' {
  $m=$script:DeployUI.Management;$intent=$m.UnresolvedIntent;$intent.State='ReconciledByUser';SaveManagementIntent $intent;$m.UnresolvedIntent=$null;ShowServerManagement
 }
}
function LoadServersUI {
 # This read belongs to a user navigation/refresh. Do not set a loading flag
 # unless the existing scheduler can start it or queue it behind a silent poll.
 if((ServerUIGet $script:DeployUI ServersLoading $false) -or (IsBusy) -or (Get-Variable QueuedJob -Scope Script -ValueOnly -ErrorAction SilentlyContinue)){return}
 $script:DeployUI.ServerDiscoveryAttempted=$true;$script:DeployUI.ServersLoading=$true
 StartJob @{Action='DeploymentDiscover'} {param($d)$script:DeployUI.ServersLoading=$false;$script:DeployUI.Discovery=$d;RefreshSelectedServerRecordUI;if($script:Role -in @('servers','devices')){ShowServerManagement}} '读取服务器台账…' '' -Failed {param($message)$script:DeployUI.ServersLoading=$false;InitializeServerUI;$script:DeployUI.Management.Error='台账暂时无法读取，请点击刷新重试。';if($script:Role -in @('servers','devices')){ShowServerManagement}}
}
function RefreshSelectedServerRecordUI {
 InitializeServerUI;$m=$script:DeployUI.Management;if(-not $m.ServerId){return}
 # A refresh must not replace the target of an operation already in flight.
 # Its existing completion path owns reconciliation against the live identity.
 if($script:DeployUI.PendingManagement){return}
 $matches=@(ServerUIGet $script:DeployUI.Discovery Servers @()|Where-Object {$_.LocalRecordId -ceq $m.ServerId})
 if($matches.Count -ne 1){$m.Authenticated=$false;$m.Info=$null;$m.Preview=$null;$m.Error='所选服务器记录不再唯一或已不存在，请返回列表核对。';return}
 $fresh=$matches[0];$changed=(ServerUIGet $fresh RecordState 'Active') -cne 'Active'
 foreach($key in @('RemoteOwnerId','NodeId','ServerPublicKey','PinnedHostKey')){if([string](ServerUIGet $fresh $key '') -cne [string](ServerUIGet $m.Server $key '')){$changed=$true}}
 foreach($key in @('Host','Port','User','IdentityFile')){if([string](ServerUIGet (ServerUIGet $fresh Connection) $key '') -cne [string](ServerUIGet (ServerUIGet $m.Server Connection) $key '')){$changed=$true}}
 if($changed){$m.Authenticated=$false;$m.Credential=$null;$m.Info=$null;$m.Preview=$null;$m.ReadContinuation='';if(-not $script:DeployUI.PendingManagement){$m.SessionRef=$null};$script:DeployUI.DeviceResult=$null;$m.Error='服务器身份或记录状态已变化，请重新核对。'}
 $m.Server=$fresh
}
function SelectServerUI {param([string]$ServerId)
 InitializeServerUI
 if($script:DeployUI.PendingManagement){ErrorDialog '请等当前服务器操作完成；结果未知时先核对原操作。';return}
 if((ServerUIGet $script:DeployUI.Management ReinstallStage) -and $script:DeployUI.Management.ServerId -cne $ServerId){ErrorDialog '请先退出这次重装身份核验，再选择其他服务器。';return}
 if($script:DeployUI.Run -and $script:DeployUI.Run.Status -eq 'Running'){ErrorDialog '部署正在执行，请完成或核对该操作后再打开管理会话。';return}
 $matches=@(ServerUIGet $script:DeployUI.Discovery Servers @()|Where-Object {$_.LocalRecordId -ceq $ServerId})
 if($matches.Count -ne 1){ErrorDialog '服务器记录不唯一或不存在，请刷新台账。';return};$server=$matches[0]
 if((ServerUIGet $server RecordState 'Active') -ceq 'Archived'){ErrorDialog '此身份已归档，请选择重装后新建的服务器记录。';return}
 if($script:DeployUI.Management.ServerId -ne $ServerId){
  $old=$script:DeployUI.Management.SessionRef
  if($old -and -not $script:Smoke){CloseUiDeploymentSession $old}
  $script:DeployUI.Management=$null;InitializeServerUI;$script:DeployUI.DeviceResult=$null;$script:DeployUI.Invite=$null
 }else{RefreshSelectedServerRecordUI}
 $script:DeployUI.Management.ServerId=$ServerId;$script:DeployUI.Management.Server=$server;$script:DeployUI.ServerId=$ServerId
 $script:DeployUI.Management.ReadContinuation=''
 InitializeServerNavigationUI;$script:ServerNavigationUI.View='server-detail';$script:ServerNavigationUI.SelectedServerId=$ServerId;$script:ServerNavigationUI.DetailKind='Managed';$script:ServerNavigationUI.Message='';$script:ServerNavigationUI.Loading=$false;$script:ServerNavigationUI.RequestId=''
 RestoreManagementIntent
 $script:DeployUI.ManagementMode=$true;$script:Role='servers';ShowServerManagement
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
  $key=[string]$script:Controls.ServerKeyPath.Text;$secret=$script:Controls.ServerPassword.SecurePassword
  if(-not $key -and $secret.Length -eq 0 -and (ServerUIGet $script:DeployUI RecoveryRecordId '') -eq $m.ServerId -and (ServerUIGet $script:DeployUI RecoveredCredential)){
   $credential=$script:DeployUI.RecoveredCredential
  }elseif((ServerUIGet $m UseSavedCredential $false) -and (ServerUIGet $m.Server CredentialRef '')){
   $credential=Get-TCDeploySavedCredential -Root $script:Root -CredentialRef ([string]$m.Server.CredentialRef)
  }elseif($key){
   if(-not [IO.File]::Exists($key) -or (Get-Item -LiteralPath $key).Length -gt 1MB){throw 'SSH 私钥文件不存在或超过 1 MiB。'}
   $pem=[IO.File]::ReadAllText($key,[Text.Encoding]::UTF8)
   $credential=@{Kind='PrivateKey';PrivateKeyPem=(ConvertTo-SecureString $pem -AsPlainText -Force);Passphrase=$secret};$pem=$null
  }else{$credential=@{Kind='Password';Password=$secret}}
  $m.Credential=$credential;$m.Authenticated=$false;$m.TrustShown=$null;$m.Error=''
  if($m.CommandPending){return};$m.CommandPending=$true
  $script:DeployUI.PendingManagement=@{Purpose='Authenticate';Operation='';OperationId='';ServerId=$m.ServerId};ShowServerManagement
  StartUiCommand -Module 'DeploymentTransport.psm1' -Command 'Start-TCDeploySession' -Arguments @{Root=$script:Root;RunId=[guid]::NewGuid().ToString('D');Connection=$m.Server.Connection;Credential=$credential;PinnedFingerprint=[string](ServerUIGet $m.Server PinnedHostKey '')} -Context @{Model=$m;ServerId=$m.ServerId} -Complete {
   param($started,$context);$context.Model.CommandPending=$false
   $current=$script:DeployUI.Management
   if(-not [object]::ReferenceEquals($current,$context.Model) -or $current.ServerId -cne $context.ServerId){CloseUiDeploymentSession $started.SessionRef;return}
   $current.SessionRef=$started.SessionRef;$script:DeployUI.SessionRef=$started.SessionRef;$script:DeployUI.SessionAttached=$true
   if($script:Role -in @('servers','devices','product-pair')){ShowServerManagement}
  } -Failed {
   param($message,$context);$context.Model.CommandPending=$false;$context.Model.Credential=$null;$context.Model.Error=$message
   if([object]::ReferenceEquals($script:DeployUI.Management,$context.Model) -and $script:DeployUI.Management.ServerId -ceq $context.ServerId){$script:DeployUI.PendingManagement=$null;ErrorDialog $message}
  } -Message '正在连接所选服务器…'
 }catch{$m.Credential=$null;$m.Error=$_.Exception.Message;ErrorDialog $m.Error}
}
function ResetServerReinstallUI {param([string]$Message='已退出重装核验，原记录保留。')
 $m=$script:DeployUI.Management
 $m.ReinstallStage=$null;$m.ReinstallAttemptId=$null;$m.ReinstallVerificationToken=$null;$m.ReinstallPreview=$null;$m.ReinstallApprovalToken=$null;$m.Credential=$null;$m.SessionRef=$null;$m.Authenticated=$false;$m.TrustShown=$null;$m.Info=$null;$m.Input.KeyPath='';$m.CommandPending=$false
 $script:DeployUI.PendingManagement=$null;$script:DeployUI.SessionRef=$null;$script:DeployUI.SessionAttached=$false;$script:DeployUI.Credential=$null;$script:DeployUI.RecoveredCredential=$null;$script:DeployUI.DeviceResult=$null;$m.Error=$Message
 # Detach only. No process is stopped and no previous deployment is resumed.
 ShowServerManagement
}
function BeginServerReinstallUI {
 if(ServerUIReadOnly){ErrorDialog '当前是只读检查窗口，未启动服务器身份核验。';return}
 InitializeServerUI;$m=$script:DeployUI.Management
 if($script:DeployUI.PendingManagement){ErrorDialog '当前管理动作尚未完成，请先核对结果。';return}
 if(-not $m.Server -or -not $m.Server.Connection -or -not (ServerUIGet $m.Server PinnedHostKey) -or (ServerUIGet $m.Server RecordState 'Active') -ceq 'Archived'){ErrorDialog '请选择仍有效且已固定 SSH 指纹的服务器记录。';return}
 OpenDialog '这台服务器已重装？' ('目标：'+$m.Server.Name+' · '+$m.Server.Connection.Host+':'+$m.Server.Connection.Port) '下一步重新输入管理凭据，只读核验新 SSH 身份。核对新指纹并明确确认后，建立新记录，原身份和任务归档保留；设备密钥、授权和已保存密码均不导入。当前线路保持。' '服务器已重装，开始核验' {
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
  $key=[string]$script:Controls.ServerKeyPath.Text;$secret=$script:Controls.ServerPassword.SecurePassword
  if($key){
   if(-not [IO.File]::Exists($key) -or (Get-Item -LiteralPath $key).Length -gt 1MB){throw 'SSH 私钥文件不存在或超过 1 MiB。'}
   $pem=[IO.File]::ReadAllText($key,[Text.Encoding]::UTF8);$credential=@{Kind='PrivateKey';PrivateKeyPem=(ConvertTo-SecureString $pem -AsPlainText -Force);Passphrase=$secret};$pem=$null
  }else{if($secret.Length -eq 0){throw '重装核验需要重新输入管理密码或明确选择 SSH 私钥，不使用旧保存凭据。'};$credential=@{Kind='Password';Password=$secret}}
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
 OpenDialog '核对重装后的新 SSH 指纹' ('目标：'+$preview.Connection.Host+':'+$preview.Connection.Port+"`n原指纹："+$preview.PreviousFingerprint+"`n新指纹："+$preview.NewFingerprint) '请与云控制台等可信来源核对新指纹。确认后只用这枚指纹认证并建立新管理记录；原记录、旧任务和资料保留为历史，旧授权不能续接。不会自动部署、重启服务或切换线路。' '已核对新指纹，建立新管理记录' {
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
   } -Message '正在认证已核对的新服务器身份…'
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
   $m.ReinstallStage=$null;$m.ReinstallVerificationToken=$null;$m.ReinstallPreview=$null;$m.ReinstallApprovalToken=$null;$m.Credential=$null;$script:DeployUI.PendingManagement=$null;$script:DeployUI.ServerId=$m.ServerId;$script:DeployUI.Server=$d.Server;$script:DeployUI.DeviceResult=$null;$script:DeployUI.Invite=$null
   $script:DeployUI.PairRequest=$null;$script:DeployUI.PairRequestInspection=$null;$script:DeployUI.EnrollmentId=$null;$script:DeployUI.PairFields=$null;$script:DeployUI.InviteFromServer=$false
   if($script:DeployUI.Run -and (ServerUIGet $script:DeployUI.Run ServerRecordId '') -ceq $previous){$script:DeployUI.Run=$null;$script:DeployUI.SessionAttached=$false}
   LoadServersUI;ShowServerManagement
  } '建立新管理记录，保留原身份和任务…' '' -Failed {param($message)ResetServerReinstallUI $message;ErrorDialog $message}
  return
 }
 if($Poll.Status -in @('Running','Connecting','AwaitingCredential')){return}
 if($Poll.Code -ceq 'HostKeyChanged'){ResetServerReinstallUI '核验时新指纹再次变化，已阻断。请重新核对可信来源；原记录保留。';return}
 ResetServerReinstallUI '未完成新 SSH 身份认证，原记录保留。请重新输入凭据并核验。'
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
  if($script:Role -in @('servers','devices')){ShowServerManagement}
  ErrorDialog $Message
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
 if((ServerUIGet $m ReinstallStage) -or (ServerUIGet $m.Server RecordState 'Active') -ceq 'Archived'){ErrorDialog '重装核验期间仅核对 SSH 身份；归档记录不能续接管理动作。';return}
 if($script:DeployUI.PendingManagement){ErrorDialog '当前操作尚未完成，请先核对结果。';return}
 $mutation=ManagementMutation $Operation $InputData
 if($mutation -and (ServerUIGet $m UnresolvedIntent) -and $Operation -notin @('recover','request_status')){ErrorDialog '上次管理变更结果尚未核对。请先查询原操作，未重复发送。';return}
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
  $m.CommandPending=$true
  $pending=@{Operation=$Operation;Purpose=$Purpose;ServerId=$m.ServerId;InputData=$InputData;OperationId=$(if($intent){$intent.OperationId}else{''});Intent=$intent;Continuation=$continuation}
  $script:DeployUI.PendingManagement=$pending
  $context=@{Model=$m;Pending=$pending;Intent=$intent;Lease=$lease};$lease=$null
  $submitted=$true
  StartUiCommand -Module 'DeploymentTransport.psm1' -Command 'Invoke-TCDeployOperation' -Arguments $arguments -Context $context -Complete {
   param($started,$context)
   try{
    if(-not $started.Ok){FailServerDispatchUI $context '服务器未接受此管理请求，请核对原步骤。' $true;return}
    if($context.Intent -and $started.OperationId -cne $context.Intent.OperationId){FailServerDispatchUI $context '管理请求返回的标识不一致，请先查询原操作。';return}
    $context.Pending.OperationId=$started.OperationId;$context.Model.CommandPending=$false;$context.Model.Error=''
    if($context.Intent){$context.Intent.State='Dispatched';SaveManagementIntent $context.Intent}
    if([object]::ReferenceEquals($script:DeployUI.Management,$context.Model) -and $script:Role -in @('servers','devices')){ShowServerManagement}
   }finally{if($context.Lease){$context.Lease.Dispose();$context.Lease=$null}}
  } -Failed {
   param($message,$context,$failure)
   try{
    if($failure -and $failure.Phase -eq 'BeforeDispatch'){FailServerDispatchUI $context '管理请求尚未提交，请处理提示后再试。' $true}
    else{FailServerDispatchUI $context '无法确认管理操作是否被接受，请先查询原申请或服务器状态。'}
   }finally{if($context.Lease){$context.Lease.Dispose();$context.Lease=$null}}
  } -Message '正在提交原管理请求，等待执行器确认…'
  if($script:Role -in @('servers','devices')){ShowServerManagement}
 }catch{
  if($intent){$intent.State=if($submitted){'OutcomeUnknown'}else{'Rejected'};if($submitted){$m.UnresolvedIntent=$intent};SaveManagementIntent $intent}
  $m.Error=if($submitted){'无法确认管理操作是否被接受，请先查询原申请或服务器状态。'}else{'管理请求尚未提交，请核对登录状态和本地记录后再试。'}
  if(-not $submitted){$m.CommandPending=$false}
  if($script:Role -in @('servers','devices')){ShowServerManagement};ErrorDialog $m.Error
 }finally{if($lease){$lease.Dispose()}}
}
function PollServerOperation {param($Poll=$null)
 InitializeServerUI;$m=$script:DeployUI.Management
 if($m.CommandPending){return}
 if($script:Smoke -or -not $m.SessionRef -or (-not $Poll -and ((Get-Date)-$m.LastPoll).TotalSeconds -lt 2)){return}
 if(-not $Poll){
  $m.LastPoll=Get-Date
  StartJob @{Action='DeploymentSessionSnapshot';SessionRef=$m.SessionRef} {param($data)
   $m=$script:DeployUI.Management
   if(-not $m -or [string]$data.InstanceId -cne [string]$m.SessionRef.InstanceId -or $script:Role -notin @('servers','devices','automatic-tcp','product-pair')){return}
   $m.LastSnapshot=$data.Poll;PollServerOperation $data.Poll
  } '读取服务器管理状态…' '' -Silent -Failed {param($message)if($script:DeployUI.Management){$script:DeployUI.Management.LastPoll=(Get-Date).AddSeconds(3);$script:DeployUI.Management.Error='管理会话暂不可核验，原操作保持；正在等待查询。'}}
  return
 }
 try{
  Import-Module (UIProductPath 'DeploymentTransport.psm1') -DisableNameChecking
  if(ServerUIGet $m ReinstallStage){PollServerReinstallUI $Poll;return}
  if($Poll.Code -eq 'HostTrustRequired'){
   if($m.TrustShown -ne $Poll.ObservedFingerprint){$m.TrustShown=$Poll.ObservedFingerprint
    OpenDialog '核对这台服务器的 SSH 身份' ('服务器：'+$m.Server.Name+"`n指纹："+$m.TrustShown) '请与云控制台等可信来源核对。已知指纹变化会阻断，不自动删除旧信任。' '已核对并信任' {
     param($context)
     $m=$script:DeployUI.Management
     if(-not [object]::ReferenceEquals($m,$context.Model) -or $m.ServerId -cne $context.ServerId -or -not $m.SessionRef -or $m.SessionRef.InstanceId -cne $context.InstanceId -or $m.TrustShown -cne $context.Fingerprint){ErrorDialog '服务器或身份预览已变化，请重新核对。';return}
     $m.CommandPending=$true
     StartUiCommand -Module 'DeploymentTransport.psm1' -Command 'Set-TCDeployCredential' -Arguments @{SessionRef=$m.SessionRef;Connection=$m.Server.Connection;Credential=$m.Credential;PinnedFingerprint=$context.Fingerprint} -Context $context -Complete {param($data,$context)$context.Model.CommandPending=$false} -Failed {param($message,$context)$context.Model.CommandPending=$false;$context.Model.Credential=$null;if([object]::ReferenceEquals($script:DeployUI.Management,$context.Model)){ErrorDialog $message}} -Message '正在按已核对的身份连接服务器…'
    } '取消' 'Primary' @{Model=$m;ServerId=$m.ServerId;InstanceId=$m.SessionRef.InstanceId;Fingerprint=$m.TrustShown}
   };return
  }
  if($Poll.Code -eq 'HostKeyChanged'){$m.Credential=$null;$script:DeployUI.RecoveredCredential=$null;$m.Authenticated=$false;$script:DeployUI.PendingManagement=$null;$m.Error='SSH 主机身份发生变化。请核对目标；确认已重装时，使用“服务器已重装，重新核验身份”入口。';ShowServerManagement;return}
  if($Poll.HasSession -and -not $m.Authenticated){
   if($script:Smoke){$m.Authenticated=$true;$m.Credential=$null;$script:DeployUI.RecoveredCredential=$null;$script:DeployUI.PendingManagement=$null;StartServerOperation server_info @{} ServerInfo;return}
   $m.CommandPending=$true
   StartUiCommand -Module 'ServerRegistry.psm1' -Command 'Set-TCServerRecord' -Arguments @{Root=$script:Root;Id=$m.ServerId;PinnedFingerprint=[string]$Poll.ObservedFingerprint;SessionRef=$m.SessionRef} -Context @{Model=$m;ServerId=$m.ServerId;InstanceId=$m.SessionRef.InstanceId} -Complete {
    param($server,$context);$context.Model.CommandPending=$false
    $current=$script:DeployUI.Management
    if(-not [object]::ReferenceEquals($current,$context.Model) -or $current.ServerId -cne $context.ServerId -or $current.SessionRef.InstanceId -cne $context.InstanceId){return}
    $current.Server=$server;$current.Authenticated=$true;$current.Credential=$null;$script:DeployUI.RecoveredCredential=$null;$script:DeployUI.PendingManagement=$null
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
   $script:DeployUI.PendingManagement=$null;$m.Error=if($Poll.Status -eq 'OutcomeUnknown'){'无法确认服务器变更是否完成；重新登录后先查看状态或恢复事务，不要重复授权。'}else{ServerErrorText ([string]$Poll.Code)}
   if(-not $Poll.HasSession){$m.Authenticated=$false;$m.Credential=$null};ShowServerManagement;return
  }
  CompleteServerOperation $Poll.Data
 }catch{
  if(ServerUIGet $m ReinstallStage){ResetServerReinstallUI '无法核对独立 SSH 核验会话，原记录保留。请重新核验。';return}
  SetManagementIntentOutcome $script:DeployUI.PendingManagement OutcomeUnknown;$script:DeployUI.PendingManagement=$null;$m.Credential=$null;$m.Authenticated=$false;$m.Error='无法核对服务器结果，请重新认证并查看原操作。';ShowServerManagement
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
 if((ServerUIGet $Pending Continuation '') -eq 'Pairing' -and $script:Role -in @('servers','product-pair')){ContinuePairManagerReviewUI;ShowProductPairing}
 else{StartServerOperation devices @{Offset=0;Limit=50;IncludeRevoked=$true} Devices}
}
function CompleteServerOperation {param($Data)
 $pending=$script:DeployUI.PendingManagement;$script:DeployUI.PendingManagement=$null;if(-not $pending){return}
 $m=$script:DeployUI.Management
 if((ServerUIGet $Data Ok $null) -is [bool]){if(-not $Data.Ok){$m.Error='服务器拒绝操作：'+[string](ServerUIGet $Data.Data Code 'RemoteRejected');ShowServerManagement;return};$Data=$Data.Data}
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
   'Devices'{$script:DeployUI.DeviceResult=$Data;if($script:Role -in @('servers','devices')){ShowServerManagement}}
   'Rename'{Toast '设备名称已更新';StartServerOperation devices @{Offset=0;Limit=50;IncludeRevoked=$true} Devices}
   'InviteCreate'{
    $script:DeployUI.Invite=$Data
    if(ServerUIGet $script:DeployUI PairFields){$script:DeployUI.PairFields.InviteText=[string]$Data.Invite}
    if(-not $script:Smoke){Import-Module (UIProductPath 'DeploymentPairing.psm1') -DisableNameChecking;$verified=Get-TCPairInvite -Invite $Data.Invite -AllowUnconfirmed;$m.InviteFingerprint=$verified.Fingerprint}
    $m.InviteHistory=@(@($m.InviteHistory)+@([pscustomobject]@{InviteId=$Data.InviteId;State=$Data.State;ExpiresAtUtc=$Data.ExpiresAtUtc}));ShowServerManagement;Toast '邀请已生成，尚未添加设备'
   }
   'InviteCancel'{foreach($i in $m.InviteHistory){if($i.InviteId -eq $Data.InviteId){$i.State=$Data.State}};if($script:DeployUI.Invite -and $script:DeployUI.Invite.InviteId -eq $Data.InviteId){$script:DeployUI.Invite.State=$Data.State};ShowServerManagement;Toast '邀请已取消，已有设备授权不受影响'}
   'InviteStatus'{$m.LastInviteStatus=$Data;ShowServerManagement}
   'RestoreInvite'{$script:DeployUI.Invite=$Data;InitializePairingUI;$script:DeployUI.PairFields.InviteText=[string]$Data.Invite;$script:DeployUI.InviteFromServer=$true;ShowProductPairing;Toast '已取回原邀请，请核对同一份设备申请'}
   'ReconcileInvite'{$m.LastInviteStatus=$Data;ShowServerManagement;OpenDialog '原邀请的实际状态' ('状态：'+(ManagementLabel $Data.State)) '已经取回的是原邀请，未生成第二个邀请。核对后可以解除本机阻止。' '知道了' $null ''}
   'ReconcilePairInvite'{$script:DeployUI.Invite=$Data;InitializePairingUI;$script:DeployUI.PairFields.InviteText=[string]$Data.Invite;$payload=$script:DeployUI.PairRequestInspection.Payload;StartServerOperation request_status @{RequestId=$payload.ClientRequest.RequestId;RequestDigest=$payload.RequestDigest;RefreshAuthorization=$true} AuthorizeExternal}
   'ReconcileDevices'{$script:DeployUI.DeviceResult=$Data;ShowServerManagement;Toast '已读取服务器设备状态，请核对原设备和修订后解除本机阻止'}
   'ReconcileServer'{$m.Info=$Data;ShowServerManagement;OpenDialog '服务器实际状态已读取' ('状态：'+(ManagementLabel $Data.OwnershipState)) '有待恢复事务时先恢复。只解除本机阻止不会执行原变更。' '知道了' $null ''}
   'ManagementPlan'{
    $m.Preview=$Data;ShowServerManagement
    if($Data.Status -eq 'AlreadyEnabled'){Toast '管理能力已启用';StartServerOperation server_info @{} ServerInfo;return}
    OpenDialog '启用服务器管理能力？' ('新增独立签名身份与设备台账；保留隧道、密钥和现有设备。依赖 OpenSSL 可用：'+[string]$Data.OpenSSLAvailable) '只变更服务器旁路元数据，不授权本机，不切换线路。' '按此计划启用' {StartServerOperation management_apply @{PlanId=$script:DeployUI.Management.Preview.PlanId;ApprovedChangeDigest=$script:DeployUI.Management.Preview.ChangeDigest} ManagementApply}
   }
   'ManagementApply'{Toast '管理能力已启用';StartServerOperation server_info @{} ServerInfo}
   'RevokePreview'{
    $m.Preview=$Data;ShowServerManagement
    $peer=@(ServerUIGet $script:DeployUI.DeviceResult Devices @()|Where-Object {$_.DeviceId -eq $Data.DeviceId})|Select-Object -First 1
    if($peer -and (ServerDeviceInUse $peer.ClientPublicKey)){ErrorDialog '此设备正在承载当前连接，或当前设备身份尚无法核对。请在维护窗口核对并停用后再撤销，避免中断当前管理及交易连接。';return}
    OpenDialog '撤销这个设备的连接权限？' ('设备：'+[string](ServerUIGet $peer Name $Data.DeviceId)+"`n只有此设备失去 WireGuard 转发权限，其他设备保留。") 'TCP 外层 UUID 当前共享，不会自动轮换。撤销不能通过旧申请恢复。' '撤销指定设备' {StartServerOperation revoke @{DeviceId=$script:DeployUI.Management.Preview.DeviceId;ExpectedConfigRevision=$script:DeployUI.Management.Preview.ConfigRevision;ApprovedChangeDigest=$script:DeployUI.Management.Preview.ChangeDigest} Revoke} '取消' 'Danger'
   }
   'Revoke'{Toast '服务器已撤销指定设备';StartServerOperation devices @{Offset=0;Limit=50;IncludeRevoked=$true} Devices}
   'UninstallPreview'{
    $m.Preview=$Data;ShowServerManagement
    if(ServerCurrentlyInUse){ErrorDialog '这台服务器关联当前活动线路。请安排维护并停用当前连接后，再执行卸载。';return}
    OpenDialog '卸载这台服务器的通道服务？' ('影响设备：'+@($Data.AffectedDeviceIds).Count+' 台。将停止并移除本工具拥有的服务与规则，保留审计和身份。') '卸载不释放云服务器，云服务商仍会计费。当前本机线路不会自动切换。' '卸载自有服务' {StartServerOperation uninstall @{ExpectedConfigRevision=$script:DeployUI.Management.Preview.ConfigRevision;ApprovedChangeDigest=$script:DeployUI.Management.Preview.ChangeDigest} Uninstall} '取消' 'Danger'
   }
   'Uninstall'{Toast '通道服务已卸载，云服务器未释放';StartServerOperation server_info @{} ServerInfo}
   'Recover'{Toast '恢复结果已核对';StartServerOperation server_info @{} ServerInfo}
   'TransportPlan'{
    $m.Preview=$Data;ShowServerManagement
    OpenDialog '为现有服务器增加 TCP 连接方式？' ('TCP '+$Data.Transport.Port+' · '+$Data.Transport.ServerName+"`n保留现有 UDP、WireGuard 密钥及所有设备，不重启隧道服务。") '请核对云端 TCP 入站；实体 VPS 与重启验收仍待验证。本机不启用或换线。' '按此增量计划添加' {StartServerOperation transport_apply @{PlanId=$script:DeployUI.Management.Preview.PlanId;ApprovedChangeDigest=$script:DeployUI.Management.Preview.ChangeDigest} TransportApply}
   }
   'TransportApply'{Toast 'TCP 服务已添加，现有客户端需取得对应参数并验证';StartServerOperation server_info @{} ServerInfo}
   'AuthorizeExternal'{
    if($Data.Status -ne 'Authorized' -or -not $Data.Authorization){throw '设备未处于有效授权状态，请核对邀请和设备记录。'}
    if($script:Smoke){StartJob @{Action='PairAuthorizationProtectFixture';EncryptedOnly=$true} {param($d)$script:DeployUI.EncryptedAuthorization=$d.EncryptedAuthorization;ShowProductPairing} '测试加密封装';return}
    Import-Module (UIProductPath 'DeploymentPairing.psm1') -DisableNameChecking
    $encrypted=Protect-TCPairAuthorization -SignedAuthorization $Data.Authorization -PairRequest $script:DeployUI.PairRequest -Invite $script:DeployUI.Invite.Invite
    $script:DeployUI.EncryptedAuthorization=$encrypted.EncryptedAuthorization;$Data=$null;ShowProductPairing;Toast '授权已加密，只分享密文返回'
    SetManagementIntentOutcome $pending Completed
   }
   default{$m.LastSummary='服务器操作已完成：'+$pending.Operation;ShowServerManagement}
  }
 }catch{$m.Error=$_.Exception.Message;$Data=$null;ErrorDialog $m.Error}
}
function AddServerNavigationActionsUI {param($Parent,[switch]$Detail)
 $bar=New-Object Windows.Controls.WrapPanel
 if($Detail){AddC $bar (Btn '所有服务器' 'ServerAllRecords' {ShowServerListUI} 'Ghost')}
 AddC $bar (Btn '刷新本机记录' 'ServersRefresh' {LoadServersUI} 'Ghost')
 $back=if($script:ServerNavigationUI.ReturnKind -eq 'LineProfiles'){'返回原线路'}elseif($script:ServerNavigationUI.ReturnKind -eq 'Nodes'){'返回线路列表'}elseif($script:ServerNavigationUI.ReturnKind -eq 'Context'){'返回上一页'}else{'返回部署中心'}
 AddC $bar (Btn $back 'MaintenanceBack' {ReturnFromServerManagement} 'Ghost')
 AddC $Parent (Margin $bar '0,0,0,16')
}
function AddServerSummaryUI {param($Parent,$Server)
 $connection=ServerUIGet $Server Connection
 KeyValue $Parent '服务器状态' (ManagementLabel ([string](ServerUIGet $Server OwnershipState 'Unverified')))
 KeyValue $Parent '管理入口' $(if($connection -and (ServerUIGet $connection Host '')){[string]$connection.Host+':'+[string]$connection.Port}else{'未登记 SSH 管理入口'})
 $access=if((ServerUIGet $Server ManagementAccessState '') -eq 'ConnectorOnly' -or -not $connection){'此电脑仅有线路使用权'}elseif($script:DeployUI.Management.Authenticated -and $script:DeployUI.Management.ServerId -ceq $Server.LocalRecordId){'管理会话已登录'}else{'已登记管理入口，登录后核对实时状态'}
 KeyValue $Parent '此电脑的权限' $access
 if(ServerUIGet $Server LastCheckedUtc ''){KeyValue $Parent '最近记录核对' (ManagementTime $Server.LastCheckedUtc)}
 $knownNodes=Get-Variable Nodes -Scope Script -ErrorAction SilentlyContinue
 $linked=@(ServerUIGet $Server LinkedNodeIds @())
 $related=if($knownNodes){@($knownNodes.Value|Where-Object {$ids=@([string](ServerUIGet $_ LineId (ServerUIGet $_ id '')))+@(ServerUIGet $_ AliasIds @());@($ids|Where-Object {$_ -in $linked}).Count -gt 0})}else{@()}
 if($related.Count){
  AddC $Parent (Margin (T '关联的本机线路' 12.5 $script:Ink 'SemiBold') '0,12,0,4')
  foreach($line in $related){$id=[string](ServerUIGet $line LineId (ServerUIGet $line id ''));$b=Btn ([string](ServerUIGet $line name '线路')) ('ServerLine'+($id-replace '-','')) {LoadLineConnections ([string]$this.Tag)} 'Ghost';$b.Tag=$id;AddC $Parent $b}
 }elseif($linked.Count){AddC $Parent (Margin (T ('已登记 '+$linked.Count+' 个本机线路关联；在线路列表可查看现有资料。') 12 $script:Text3) '0,8,0,0')}
 AddC $Parent (Margin (T '本机线路与服务器授权设备分别记录；其他电脑的设备需要登录后查看。' 12 $script:Text3) '0,8,0,0')
}
function ShowServerBindingProblemUI {
 $n=$script:ServerNavigationUI
 SetServerNavigationPositionUI;Head '' '线路的服务器与设备' '按线路身份定位服务器；查看记录不会新增部署或授权。'
 AddServerNavigationActionsUI $script:HostPanel -Detail
 $card=Card;$p=Stack;$card.Child=$p
 SetupCardHeader $p ([string](ServerUIGet $n.Line Name '所选线路')) '' 'server'
 if($n.Loading){AddC $p (Note '正在读取原线路与服务器的身份关联…')}
 else{
  AddC $p (Note $n.Message 'amber')
  foreach($binding in $n.Bindings){AddC $p (Margin (T ([string](ServerUIGet $binding Name '服务器')+' · '+$(if((ServerUIGet $binding RecordState 'Active') -eq 'Archived'){'重装前身份已归档'}else{'关联需核对'})) 13 $script:Text2) '0,8,0,0')}
  if($n.LineId){$null=DeploymentActions $p '重新读取线路关联' 'RetryLineServerBinding' {OpenLineServerManagement $script:ServerNavigationUI.LineId -ReturnKind $script:ServerNavigationUI.ReturnKind} 'Ghost'}
  AddC $p (Margin (T '已有管理恢复包可从部署页导入；没有管理权限时，请由原管理电脑处理服务器。' 12.5 $script:Text3) '0,12,0,0')
 }
 AddC $script:HostPanel $card
}
function ShowServerManagement {
 if($script:AutoTCP){ShowAutomaticTransport;return}
 InitializeServerUI;InitializeServerNavigationUI
 $script:Page='setup';$script:Role='servers';$script:DeployUI.ManagementMode=$true
 $n=$script:ServerNavigationUI;$m=$script:DeployUI.Management
 if($n.View -eq 'server-detail' -and $n.DetailKind -eq 'Binding'){ShowServerBindingProblemUI;return}
 if(-not $script:DeployUI.Discovery -and -not (ServerUIGet $script:DeployUI ServerDiscoveryAttempted $false)){LoadServersUI}
 if($n.View -eq 'server-detail'){ShowServerDetailUI;return}
 SetServerNavigationPositionUI;Head '' '服务器管理' '管理已识别服务器的设备、授权和维护。未完成的安装在部署中心继续；收到邀请后，在线路中查看使用权。'
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
  $button=Btn '查看服务器与设备' ('ServerSelect'+($server.LocalRecordId-replace '-','')) {SelectServerUI ([string]$this.Tag)} 'Btn';$button.Tag=$server.LocalRecordId;AddC $p (Margin $button '0,12,0,0')
  $remove=Btn '删除本机部署资料…' ('ServerCleanup'+($server.LocalRecordId-replace '-','')) {DeleteOperationRecordsUI -Ids @('ServerRecord:'+[string]$this.Tag)} 'Ghost';$remove.Tag=$server.LocalRecordId;$remove.IsEnabled=(-not $script:ReadOnly);AddC $p (Margin $remove '0,6,0,0')
  AddC $script:HostPanel (Margin $card '0,0,0,12')
 }
 $archived=@($all|Where-Object {(ServerUIGet $_ RecordState 'Active') -ceq 'Archived'})
 if($archived.Count){
  $p=Stack;foreach($server in $archived){$button=Btn ([string]$server.Name+' · 查看归档身份') ('ArchivedServer'+($server.LocalRecordId-replace '-','')) {OpenArchivedServerUI ([string]$this.Tag)} 'Ghost';$button.Tag=$server.LocalRecordId;AddC $p $button}
  $exp=New-Object Windows.Controls.Expander;$exp.Header='已归档服务器（'+$archived.Count+'）';$exp.Content=$p;$exp.IsExpanded=[bool]$n.ShowArchived
  $exp.Add_Expanded({$script:ServerNavigationUI.ShowArchived=$true});$exp.Add_Collapsed({$script:ServerNavigationUI.ShowArchived=$false});AddC $script:HostPanel $exp
 }
}
function ShowServerDetailUI {
 $n=$script:ServerNavigationUI;$m=$script:DeployUI.Management
 $server=if($n.DetailKind -eq 'Archived'){$n.ArchivedRecord}else{$m.Server}
 SetServerNavigationPositionUI;Head '' '服务器与设备' '服务器级维护会先核对目标与影响；日常连接仍在线路页操作。'
 AddServerNavigationActionsUI $script:HostPanel -Detail
 if(-not $server){AddC $script:HostPanel (Note '服务器记录暂不可用，请返回列表刷新。' 'amber');return}
 $card=Card;$p=Stack;$card.Child=$p;SetupCardHeader $p ([string]$server.Name) '' 'server';AddServerSummaryUI $p $server
 if($n.Line){AddC $p (Margin (T ('从线路进入：'+[string](ServerUIGet $n.Line Name $n.LineId)) 12.5 $script:Text2) '0,8,0,0')}
 if((ServerUIGet $server RecordState 'Active') -eq 'Archived'){
  AddC $p (Note '此服务器身份已归档。旧设备、授权与任务保留用于核对，不能续接到重装后的服务器。')
  $replacement=[string](ServerUIGet $server ReplacedByServerId '')
  if($replacement){$b=DeploymentActions $p '查看重装后的服务器记录' 'ViewReplacementServer' {SelectServerUI ([string]$this.Tag)} 'Ghost';$b.Tag=$replacement}
  AddC $script:HostPanel $card;return
 }
 if($m.Error){AddC $p (Note $m.Error 'amber')}
 if(ServerUIGet $m ErrorCode){$null=ManagementDetails $p ('诊断代码：'+$m.ErrorCode)}
 if((ServerUIGet $m UnresolvedIntent) -and -not (ServerUIGet $m ReinstallStage)){
  AddC $p (Note ('上次管理操作结果待核对：'+(ManagementLabel $m.UnresolvedIntent.Operation)+'。保留原目标和申请，先核对再继续。') 'amber')
  $null=DeploymentActions $p '查询上次管理操作的实际结果' 'ManagementReconcile' {ReconcileManagementIntentUI} 'Ghost'
  $null=DeploymentActions $p '结果已核对：解除本机重复提交阻止…' 'ManagementResolveIntent' {ResolveManagementIntentUI} 'Ghost'
 }
 $connectorOnly=(ServerUIGet $server ManagementAccessState '') -eq 'ConnectorOnly' -or -not $server.Connection
 if($connectorOnly){
  AddC $p (Note '此电脑只有线路使用权。设备授权、邀请和服务器维护由管理电脑处理；这里不会要求你重新部署服务器。')
  if($n.LineId){$null=DeploymentActions $p '返回原线路查看连接方式' 'ConnectorBackToLine' {LoadLineConnections $script:ServerNavigationUI.LineId} 'Ghost'}
  AddC $script:HostPanel $card;return
 }
 $runs=@(ServerUIGet $script:DeployUI.Discovery ContinueRuns @()|Where-Object {(ServerUIGet $_ ServerRecordId '') -ceq $server.LocalRecordId})
 if($runs.Count){
  AddC $p (Margin (T '这台服务器还有未完成的准备' 13 $script:Ink 'SemiBold') '0,12,0,0')
  foreach($run in $runs){$id=[string](ServerUIGet $run RunId '');if($id){$b=DeploymentActions $p ('继续原准备：'+(ManagementLabel ([string](ServerUIGet $run Stage '')))) ('ServerContinue'+($id-replace '-','')) {ResumeProductDeployment ([string]$this.Tag)} 'Ghost';$b.Tag=$id}}
 }
 if(ServerUIGet $m ReinstallStage){
  AddC $p (Note '正在核验服务器 SSH 身份。原指纹、任务和资料保留，当前线路保持。')
  if($m.ReinstallStage -ceq 'AwaitingTrust'){$null=DeploymentActions $p '核对新指纹并确认新记录…' 'ServerReinstallTrust' {ShowServerReinstallTrustUI}}
  if($m.ReinstallStage -notin @('Previewing','Committing')){$null=DeploymentActions $p '退出本次身份核验，保留原记录' 'ServerReinstallCancel' {ResetServerReinstallUI} 'Ghost'}
 }
 if(-not $m.Authenticated -and (-not (ServerUIGet $m ReinstallStage) -or $m.ReinstallStage -ceq 'NeedsCredentials')){
  $login=Stack;AddC $login (Note '登录只读取服务器和设备状态，不会给本机新增授权。')
  $null=ServerField $login 'SSH 私钥文件（密码登录时留空）' 'ServerKeyPath' KeyPath
  if(ServerUIGet $server CredentialRef ''){
   $saved=ControlName (New-Object Windows.Controls.CheckBox) 'ServerUseSavedCredential';$saved.Content='使用此服务器已加密保存的管理凭据';$saved.IsChecked=[bool](ServerUIGet $m UseSavedCredential $false)
   $saved.Add_Checked({$script:DeployUI.Management.UseSavedCredential=$true});$saved.Add_Unchecked({$script:DeployUI.Management.UseSavedCredential=$false});AddC $login $saved
  }
  if((ServerUIGet $script:DeployUI RecoveryRecordId '') -ceq $m.ServerId -and (ServerUIGet $script:DeployUI RecoveredCredential)){AddC $login (Note '本次导入的管理凭据仅保存在内存；输入框留空可用于登录核验。')}
  AddC $login (Margin (T '服务器密码 / 私钥口令' 12.5 $script:Ink 'SemiBold') '0,12,0,5');$password=ControlName (New-Object Windows.Controls.PasswordBox) 'ServerPassword';$password.MinHeight=34;AddC $login $password
  if(ServerUIGet $m ReinstallStage){$null=DeploymentActions $login '只读核验服务器 SSH 身份' 'ServerReinstallConnect' {ConnectServerUI}}else{$null=DeploymentActions $login '登录并读取设备' 'ServerConnect' {ConnectServerUI}}
  $exp=ControlName (New-Object Windows.Controls.Expander) 'ServerLogin';$exp.Header='登录管理，读取设备与维护状态';$exp.Content=$login;$exp.IsExpanded=[bool](ServerUIGet $m LoginExpanded $false)
  $exp.Add_Expanded({$script:DeployUI.Management.LoginExpanded=$true});$exp.Add_Collapsed({$script:DeployUI.Management.LoginExpanded=$false});AddC $p (Margin $exp '0,16,0,0')
 }
 if($script:DeployUI.PendingManagement){AddC $p (Margin (Note ('正在处理：'+(ManagementLabel $script:DeployUI.PendingManagement.Purpose)+'。结果核对前不重复提交。')) '0,14,0,0')}
 AddC $script:HostPanel (Margin $card '0,0,0,16')
 if(-not $m.Authenticated){
  if(-not (ServerUIGet $m ReinstallStage) -and (ServerUIGet $server PinnedHostKey '')){$null=DeploymentActions $script:HostPanel '服务器身份发生变化？核对身份…' 'ServerReinstall' {BeginDeploymentIdentityVerification ([string]$script:DeployUI.Management.ServerId)} 'Ghost'}
  return
 }
 $info=$m.Info
 $card=Card;$p=Stack;$card.Child=$p;SetupCardHeader $p '设备与邀请' '服务器的授权设备包括其他电脑，本机线路列表不能代表全部设备。' 'laptop'
 $null=DeploymentActions $p '刷新服务器与设备' 'ServerDevices' {StartServerOperation server_info @{} ServerInfo} 'Ghost'
 AddServerDevicesUI $p
 if(-not (ServerUIGet $info ManagementSigningPublicKey)){$null=DeploymentActions $p '启用设备与邀请管理…' 'ServerManagementUpgrade' {StartServerOperation management_plan @{} ManagementPlan} 'Ghost'}
 else{
  $null=ServerField $p '新电脑的名称' 'ServerInviteName' DeviceName
  $null=DeploymentActions $p '生成一次性邀请（24 小时）' 'ServerCreateInvite' {StartServerOperation invite_create @{DeviceName=$script:DeployUI.Management.Input.DeviceName;ExpiresInHours=24} InviteCreate}
  if($script:DeployUI.Invite){
   AddC $p (Margin (T ('邀请：'+(ManagementLabel $script:DeployUI.Invite.State)+' · 到期 '+(ManagementTime $script:DeployUI.Invite.ExpiresAtUtc)) 12 $script:Text3) '0,10,0,0')
   if(ServerUIGet $m InviteFingerprint){AddC $p (T ('与新电脑核对的签名指纹：'+$m.InviteFingerprint) 12 $script:Text3)}
   $null=DeploymentActions $p '复制邀请并打开交接页' 'ServerCopyInvite' {if(-not $script:Smoke){[Windows.Clipboard]::SetText([string]$script:DeployUI.Invite.Invite)};ShowProductPairing -Role Manager} 'Ghost'
   $null=DeploymentActions $p '取消这个邀请' 'ServerCancelInvite' {StartServerOperation invite_cancel @{InviteId=$script:DeployUI.Invite.InviteId} InviteCancel} 'Ghost'
  }
  $null=DeploymentActions $p '批准新电脑申请…' 'ServerPairAuthorize' {ShowProductPairing -Role Manager} 'Ghost'
 }
 AddC $script:HostPanel (Margin $card '0,0,0,16')
 $card=Card;$p=Stack;$card.Child=$p;SetupCardHeader $p '服务与恢复' '这些操作作用于当前服务器；执行前会核对实际身份和影响。' 'server'
 if($info){KeyValue $p '服务器实时状态' (ManagementLabel ([string](ServerUIGet $info OwnershipState 'Managed')));$null=ManagementDetails $p ('服务器身份：'+[string]$info.RemoteOwnerId+'；管理接口：'+[string]$info.ManagementApiVersion+'；配置修订：'+[string]$info.ConfigRevision)}
 if($n.Line -and (Get-Command LegacyLineNeedsTcpMaintenance -ErrorAction SilentlyContinue) -and (LegacyLineNeedsTcpMaintenance $n.Line)){$null=DeploymentActions $p '为原线路补齐 TCP 备用' 'ServerLineTcp' {OpenAutomaticTransport $script:ServerNavigationUI.LineId} 'Ghost'}
 $transport=Stack;$null=ServerField $transport '新增 TCP 服务端口' 'ServerTcpPort' TcpPort;$null=ServerField $transport 'Reality 握手域名' 'ServerTcpName' ServerName
 $null=DeploymentActions $transport '预览为现有 UDP 增加 TCP…' 'ServerTcpPreview' {$port=0;if(-not [int]::TryParse($script:DeployUI.Management.Input.TcpPort,[ref]$port)){ErrorDialog '请填写有效 TCP 端口。';return};StartServerOperation transport_plan @{Transport=@{Type='tcp-reality';Port=$port;ServerName=$script:DeployUI.Management.Input.ServerName}} TransportPlan} 'Ghost'
 $exp=New-Object Windows.Controls.Expander;$exp.Header='为服务器增加 TCP 连接方式';$exp.Content=$transport;AddC $p $exp
 $null=DeploymentActions $p '检查与恢复未完成事务…' 'ServerRecover' {OpenDialog '检查并恢复未完成服务器事务？' '服务器会核对自有资源与实际结果，再完成恢复。恢复可能撤回未完成的服务器变更。' '不会替换本机线路；存在外部变更时停止并保留证据。' '核对并恢复' {StartServerOperation recover @{} Recover}} 'Ghost'
 if(-not (ServerUIGet $m ReinstallStage) -and (ServerUIGet $server PinnedHostKey '')){$null=DeploymentActions $p '核对服务器身份变化…' 'ServerReinstall' {BeginDeploymentIdentityVerification ([string]$script:DeployUI.Management.ServerId)} 'Ghost'}
 AddC $script:HostPanel (Margin $card '0,0,0,16')
 $card=Card;$p=Stack;$card.Child=$p;SetupCardHeader $p '管理资料' '保存恢复资料，便于更换管理电脑后重新登录核验。' 'key'
 $null=DeploymentActions $p '导出或导入管理恢复资料' 'ServerRecovery' {ShowManagementRecovery -Mode All} 'Ghost'
 $danger=Stack;AddC $danger (Note '卸载会影响这台服务器的所有关联设备，不只是从哪条线路进入的这台电脑。' 'amber')
 $null=DeploymentActions $danger '预览卸载服务器服务…' 'ServerUninstallPreview' {StartServerOperation uninstall_preview @{} UninstallPreview} 'Ghost'
 $exp=New-Object Windows.Controls.Expander;$exp.Header='停用这台服务器的服务';$exp.Content=$danger;AddC $p (Margin $exp '0,16,0,0');AddC $script:HostPanel $card
}
function AddServerDevicesUI {param($Parent)
 $m=$script:DeployUI.Management;$result=$script:DeployUI.DeviceResult
 if(-not $result){AddC $Parent (T '尚未读取设备，请刷新服务器与设备。' 12.5 $script:Text3);return}
 SectionLabel $Parent '设备台账' ('活跃 '+$result.ActiveDeviceCount+' · 已撤销 '+$result.RevokedDeviceCount)
 foreach($device in @(ServerUIGet $result Devices @())){
  $card=Card '18,15';$p=Stack;$card.Child=$p;AddC $p (T ($device.Name+' · '+(ManagementLabel $device.State)) 14 $script:Ink 'SemiBold')
  $null=ManagementDetails $p ('设备身份：'+$device.DeviceId+'；隧道地址：'+$device.ClientAddress)
  AddC $p (Margin (T ('授权时间：'+$(if($device.AuthorizedAtUtc){ManagementTime $device.AuthorizedAtUtc}else{'未知（历史记录未保存）'})+'；未请求握手状态。') 12 $script:Text3) '0,4,0,0')
  $rename=Btn '改名' ('DeviceRename'+($device.DeviceId-replace '-','')) {$script:DeployUI.Management.Input.RenameId=$this.Tag.Id;$script:DeployUI.Management.Input.RenameName=$this.Tag.Name;ShowServerManagement} 'Ghost';$rename.Tag=@{Id=$device.DeviceId;Name=$device.Name};AddC $p $rename
  if($device.State -eq 'Authorized'){$revoke=Btn '预览撤权…' ('DeviceRevoke'+($device.DeviceId-replace '-','')) {StartServerOperation revoke_preview @{DeviceId=[string]$this.Tag} RevokePreview} 'Ghost';$revoke.Tag=$device.DeviceId;AddC $p $revoke}
  AddC $Parent (Margin $card '0,0,0,10')
 }
 if($null -ne $result.NextOffset){$null=DeploymentActions $Parent '查看下一页设备' 'DevicesNext' {StartServerOperation devices @{Offset=[int]$script:DeployUI.DeviceResult.NextOffset;Limit=50;IncludeRevoked=$true} Devices} 'Ghost'}
 if($m.Input.RenameId){$null=ServerField $Parent '设备名称' 'DeviceNewName' RenameName;$null=DeploymentActions $Parent '保存名称' 'DeviceRenameSave' {StartServerOperation device_rename @{DeviceId=$script:DeployUI.Management.Input.RenameId;Name=$script:DeployUI.Management.Input.RenameName;ExpectedConfigRevision=[int]$script:DeployUI.DeviceResult.ConfigRevision} Rename}}
}
