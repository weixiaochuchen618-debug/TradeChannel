# Deployment pages: credentials only travel GUI memory -> SID-limited pipe.
$script:DeployUI=@{Intent='New';Screen='connect';Run=$null;Discovery=$null;SessionRef=$null;SessionAttached=$false;Credential=$null;RememberCredential=$false;LastPoll=[DateTime]::MinValue;TrustShown=$null;ServerId=$null;Server=$null;Management=$null;DeviceResult=$null;Invite=$null;PairRequest=$null;EnrollmentId=$null;PendingManagement=$null}
function DeploymentField {param($Parent,[string]$Label,[string]$Id,[string]$Value='',[string]$Hint='',[switch]$Multiline)
 AddC $Parent (Margin (T $Label 12.5 $script:Ink 'SemiBold') '0,12,0,5')
 $box=ControlName (New-Object Windows.Controls.TextBox) $Id;$box.Text=$Value;$box.MinHeight=34
 if($Multiline){$box.AcceptsReturn=$true;$box.TextWrapping='Wrap';$box.MinHeight=96;$box.MaxHeight=180;$box.VerticalScrollBarVisibility='Auto'}
 AddC $Parent $box;if($Hint){AddC $Parent (Margin (T $Hint 12 $script:Text3) '0,4,0,0')};return $box
}
function DeploymentActions {param($Parent,[string]$Label,[string]$Id,[scriptblock]$Action,[string]$Style='Primary')
 $button=Btn $Label $Id $Action $Style;$button.MinWidth=96;$button.Margin='0,16,10,0';$button.HorizontalAlignment='Left';AddC $Parent $button;return $button
}
function BeginProductDeployment {param([string]$Intent='New',[string]$ServerId)
 if($script:DeployUI.Run -and $script:DeployUI.Run.Status -in @('Running','Dispatching')){ErrorDialog '当前部署尚未完成，请先查询结果或安全取消。';return}
 $script:DeployUI.ManagementMode=$false;$script:DeployUI.Reauth=$false
 $script:Role='deployment';$script:Step=1;$script:DeployUI.Intent=$Intent;$script:DeployUI.Screen='connect';$script:DeployUI.ServerId=$ServerId
 $script:DeployUI.Run=$null;$script:DeployUI.SessionAttached=$false;$script:DeployUI.Credential=$null;$script:DeployUI.TrustShown=$null
 ShowProductDeployment
 StartJob @{Action='DeploymentDiscover'} {param($d)$script:DeployUI.Discovery=$d;if($script:Role -eq 'deployment'){ShowProductDeployment}} '读取已有线路与部署进度…' '' -Silent
}
function ShowProductDeployment {
 $script:Page='setup';Head '' '准备连接' '同一条线路准备 UDP 和 TCP，准备状态与网络检查分别显示。'
 if($script:DeployUI.Run -and -not $script:DeployUI.Reauth){ShowDeploymentRun;return}
 $card=Card;$p=Stack;$card.Child=$p
 if($script:DeployUI.Intent -eq 'New'){
  SetupCardHeader $p '第一次配置' '先检查准备条件，再开始部署。' 'laptop'
  AddC $p (Note '推荐环境：Ubuntu 24.04 或 Debian 13 x64 专用 VPS，管理员或已有免交互 sudo 的账户。购买和云端规则在厂商控制台完成。')
  $null=DeploymentActions $p '我还没有服务器：查看购买准备' 'PurchasePreparation' {ShowPurchasePreparation} 'Ghost'
 }else{SetupCardHeader $p '新增或更换线路' '旧线路继续使用，新候选独立准备。' 'server'}
 $server=$null
 if($script:DeployUI.ServerId -and $script:DeployUI.Discovery){$server=@($script:DeployUI.Discovery.Servers|Where-Object {$_.LocalRecordId -eq $script:DeployUI.ServerId})|Select-Object -First 1}
 $hostValue=if($server -and $server.Connection){[string]$server.Connection.Host}else{''}
 $nameValue=if($server){[string]$server.Name}else{'新的服务器线路'}
 $seed=ProfileUIField $script:DeployUI 'LegacySeed'
 if(-not $server -and $seed){$hostValue=[string]$seed.Host;$nameValue=[string]$seed.Name}
 $null=DeploymentField $p '服务器地址或接入信息' 'DeployConnectionText' $hostValue '可粘贴 IP、root@IP 或 ssh root@IP -p 22；不会执行粘贴文本。'
 $null=DeploymentField $p '线路名称' 'DeployName' $nameValue
 $null=DeploymentField $p 'SSH 用户名' 'DeployUser' $(if($server -and $server.Connection){[string]$server.Connection.User}else{'root'})
 $null=DeploymentField $p 'SSH 端口' 'DeployPort' $(if($server -and $server.Connection){[string]$server.Connection.Port}else{'22'})
 $null=DeploymentField $p 'SSH 私钥文件（可留空）' 'DeployKeyPath' $(if($server -and $server.Connection){[string]$server.Connection.IdentityFile}else{''})
 if(-not $server -and $seed){$script:Controls.DeployUser.Text=[string]$seed.User;$script:Controls.DeployPort.Text=[string]$seed.Port;$script:Controls.DeployKeyPath.Text=[string]$seed.IdentityFile}
 AddC $p (Margin (T '密码 / SSH 私钥口令' 12.5 $script:Ink 'SemiBold') '0,12,0,5')
 $password=ControlName (New-Object Windows.Controls.PasswordBox) 'DeployPassword';$password.MinHeight=34;AddC $p $password
 $remember=ControlName (New-Object Windows.Controls.CheckBox) 'DeployRemember';$remember.Content='加密记住管理凭据（当前 Windows 用户）';$remember.Margin='0,10,0,0';AddC $p $remember
 if($server -and $server.CredentialRef){$useSaved=ControlName (New-Object Windows.Controls.CheckBox) 'DeployUseSaved';$useSaved.Content='使用这台服务器已加密保存的管理凭据';$useSaved.IsChecked=$true;$useSaved.Margin='0,8,0,0';AddC $p $useSaved}
 $mode=ControlName (New-Object Windows.Controls.ComboBox) 'DeployTransport'
 foreach($option in @(@('自动推荐初始方式','Auto'),@('初始偏好 UDP','Udp'),@('初始偏好 TCP','Tcp'))){$item=New-Object Windows.Controls.ComboBoxItem;$item.Content=$option[0];$item.Tag=$option[1];$null=$mode.Items.Add($item)};$mode.SelectedIndex=0
 AddC $p (Margin (Note '部署始终在同一条线路内准备 UDP 和 TCP。这里的协议选择只设置初始偏好；网络检查与推荐另行显示，未完成性能对比时使用策略默认，不能据此判断最快。') '0,14,0,0')
 $advancedPanel=Stack;AddC $advancedPanel (Margin (T '初始连接偏好' 12.5 $script:Ink 'SemiBold') '0,12,0,5');AddC $advancedPanel $mode
 $null=DeploymentField $advancedPanel 'TCP 首选端口' 'DeployTcpPort' '443'
 $null=DeploymentField $advancedPanel 'TCP 握手目标' 'DeployServerName' 'www.bing.com'
 $advanced=ControlName (New-Object Windows.Controls.Expander) 'DeploymentAdvanced';$advanced.Header='高级部署设置';$advanced.Content=$advancedPanel;$advanced.Margin='0,14,0,0';AddC $p $advanced
 if($script:DeployUI.Reauth){foreach($id in @('DeployConnectionText','DeployUser','DeployPort','DeployName','DeployTcpPort','DeployServerName')){$script:Controls[$id].IsReadOnly=$true};$script:Controls.DeployTransport.IsEnabled=$false}
 $null=DeploymentActions $p '连接并检查，暂不安装' 'ProductDeployInspect' {StartProductDeployment}
 $null=DeploymentActions $p '我的服务器与未完成操作' 'ProductServers' {ShowServerManagement} 'Ghost'
 AddC $script:HostPanel $card
}
function ShowPurchasePreparation {
 $script:Page='setup';$script:Role='purchase';Head '' '购买前准备' '按受支持环境准备，再把接入资料带回软件。'
 $card=Card;$p=Stack;$card.Child=$p
 SetupTasks $p @('选择 Ubuntu 24.04 或 Debian 13、x86_64/amd64 的完整 VPS；不选共享 NAT、仅 IPv6或受限容器。','取得公网 IPv4、SSH 账户和密码或私钥；应具备管理员安装权限。','检查发行版软件源可访问；TCP 还需要对应组件下载源。','确认厂商有控制台等恢复入口，允许所需 UDP/TCP 入站。','购买后复制接入资料。费用和云规则在厂商控制台管理，软件不自动付款。')
 AddC $p (Note '套餐与线路需实测；未验收的模板不会标为认证，不按 ping 或地区直接保证可用。')
 $null=DeploymentActions $p '资料已准备，返回连接检查' 'PurchaseReturn' {BeginProductDeployment 'New'};AddC $script:HostPanel $card
}
function StartProductDeployment {
 if(IsBusy){return}
 try{
  Import-Module (Join-Path $script:PackageRoot 'DeploymentFlow.psm1') -DisableNameChecking
  $port=0;$tcp=0
  if(-not [int]::TryParse($script:Controls.DeployPort.Text,[ref]$port) -or -not [int]::TryParse($script:Controls.DeployTcpPort.Text,[ref]$tcp)){throw '请填写有效端口。'}
  $connection=ConvertTo-TCDeploymentConnection -Text $script:Controls.DeployConnectionText.Text -User $script:Controls.DeployUser.Text -Port $port -IdentityFile $script:Controls.DeployKeyPath.Text
  if($script:Controls.ContainsKey('DeployUseSaved') -and $script:Controls.DeployUseSaved.IsChecked){Import-Module (Join-Path $script:PackageRoot 'DeploymentTransport.psm1') -DisableNameChecking;Import-Module (Join-Path $script:PackageRoot 'ServerRegistry.psm1') -DisableNameChecking;$savedServer=Get-TCServer $script:Root $script:DeployUI.ServerId;$script:DeployUI.Credential=Get-TCDeploySavedCredential -Root $script:Root -CredentialRef $savedServer.CredentialRef}
  elseif($connection.IdentityFile){$pem=[IO.File]::ReadAllText($connection.IdentityFile,[Text.Encoding]::UTF8);$script:DeployUI.Credential=@{Kind='PrivateKey';PrivateKeyPem=(ConvertTo-SecureString $pem -AsPlainText -Force);Passphrase=$script:Controls.DeployPassword.SecurePassword};$pem=$null}
  else{$script:DeployUI.Credential=@{Kind='Password';Password=$script:Controls.DeployPassword.SecurePassword}}
  $script:DeployUI.RememberCredential=[bool]$script:Controls.DeployRemember.IsChecked
  if($script:DeployUI.Reauth -and $script:DeployUI.Run){$script:DeployUI.Reauth=$false;ShowProductDeployment;StartDeploymentSessionUI;return}
  $request=@{Action='DeploymentCreate';Intent=$script:DeployUI.Intent;Connection=$connection;Name=$script:Controls.DeployName.Text;Transport=[string]$script:Controls.DeployTransport.SelectedItem.Tag;TcpPort=$tcp;ServerName=$script:Controls.DeployServerName.Text}
  if($script:DeployUI.Intent -eq 'Existing' -and $script:DeployUI.LegacySeed -and $script:DeployUI.LegacySeed.TemplateNodeId){$request.TemplateNodeId=$script:DeployUI.LegacySeed.TemplateNodeId}
  if($script:DeployUI.ServerId){$request.ServerId=$script:DeployUI.ServerId}
  StartJob $request {param($run)$script:DeployUI.Run=$run;ShowProductDeployment;StartDeploymentSessionUI} '创建可恢复部署记录…'
 }catch{ErrorDialog $_.Exception.Message}
}
function StartDeploymentSessionUI {
 try{
  if($script:Smoke){StartJob @{Action='DeploymentSessionFixture';RunId=$script:DeployUI.Run.RunId} {param($s)$script:DeployUI.SessionRef=$s.SessionRef} '测试会话';return}
  Import-Module (Join-Path $script:PackageRoot 'DeploymentTransport.psm1') -DisableNameChecking
  Import-Module (Join-Path $script:PackageRoot 'ServerRegistry.psm1') -DisableNameChecking
  $server=Get-TCServer -Root $script:Root -Id $script:DeployUI.Run.ServerRecordId
  $started=Start-TCDeploySession -Root $script:Root -RunId $script:DeployUI.Run.RunId -Connection $server.Connection -Credential $script:DeployUI.Credential -PinnedFingerprint ([string]$server.PinnedHostKey)
  $script:DeployUI.SessionRef=$started.SessionRef;$script:DeployUI.SessionAttached=$false;$script:DeployUI.LastPoll=[DateTime]::MinValue
 }catch{$script:DeployUI.Credential=$null;ErrorDialog $_.Exception.Message}
}
function AdvanceDeploymentUI {param([string]$Command='Continue')
 if(IsBusy){return}
 if($script:ReadOnly){ErrorDialog '只读窗口不推进部署。';return}
 if($Command -eq 'UsePrepared'){
  $state=DeploymentCompletenessView $script:DeployUI.Run
  $prepared=@((DeploymentLineView $script:DeployUI.Run).Profiles|Where-Object {ProfileIsPrepared $_})
  if($state.State -ne 'Partial' -or -not $prepared.Count){ErrorDialog '当前没有可确认先使用的部分部署；请先核对准备状态。';return}
 }
 $request=@{Action='DeploymentProceed';RunId=$script:DeployUI.Run.RunId;Command=$Command}
 if($Command -eq 'Approve'){$request.ApprovedChangeDigest=$script:DeployUI.Run.Review.ChangeDigest}
 StartJob $request {param($run)$script:DeployUI.Run=$run;$script:DeployUI.PollError='';ShowProductDeployment} '处理部署阶段；现有线路保持…' -Failed {param($message)$script:DeployUI.PollError=$message;ShowProductDeployment}
}
function DeploymentLocalCheckPending {param($Run)
 $Run -and ([string](ProfileUIField $Run 'Stage' '') -eq 'CheckingProfiles' -or ([string](ProfileUIField $Run 'Stage' '') -eq 'ReadyInactive' -and [string](ProfileUIField $Run 'ProfileProbeState' '') -in @('Pending','Running')))
}
function PollDeploymentRunUI {
 StartJob @{Action='DeploymentPoll';RunId=$script:DeployUI.Run.RunId} {param($run)$script:DeployUI.Run=$run;$script:DeployUI.PollError='';if($script:Role -eq 'deployment'){ShowProductDeployment}} '读取部署与检查进度…' '' -Silent -Failed {param($message)$script:DeployUI.PollError=$message;if($script:Role -eq 'deployment'){ShowProductDeployment}}
}
function PollProductDeployment {
 if($script:Smoke -or ((Get-Date)-$script:DeployUI.LastPoll).TotalSeconds -lt 2){return}
 $script:DeployUI.LastPoll=Get-Date
 if($script:Job -and $script:Job.Action -in @('DeploymentPoll','DeploymentProceed') -and $script:DeployUI.Run){
  try{
   Import-Module (Join-Path $script:PackageRoot 'DeploymentFlow.psm1') -DisableNameChecking
   $progress=Get-TCDeploymentRun -Root $script:Root -RunId ([string]$script:DeployUI.Run.RunId)
   if($progress.Stage -eq 'CheckingProfiles'){$script:DeployUI.Run=$progress;if($script:Role -eq 'deployment'){ShowProductDeployment;$script:HostPanel.IsEnabled=$true}}
  }catch{}
  return
 }
 if(IsBusy){return}
 if($script:DeployUI.ManagementMode -or $script:DeployUI.PendingManagement){PollServerOperation;return}
 if(DeploymentLocalCheckPending $script:DeployUI.Run){PollDeploymentRunUI;return}
 if($script:DeployUI.Run -and $script:DeployUI.Run.Stage -eq 'ReadyInactive'){return}
 if(-not $script:DeployUI.SessionRef){return}
 try{
  Import-Module (Join-Path $script:PackageRoot 'DeploymentTransport.psm1') -DisableNameChecking
  $poll=Get-TCDeploySession -SessionRef $script:DeployUI.SessionRef
  if($poll.Code -in @('HostTrustRequired','HostKeyUnknown') -or $poll.Status -in @('HostTrustRequired','AwaitingTrust')){
   if($script:DeployUI.TrustShown -ne $poll.ObservedFingerprint){
    $script:DeployUI.TrustShown=$poll.ObservedFingerprint
    OpenDialog '确认首次服务器身份' ('目标：'+[string]$script:DeployUI.Run.Name+[Environment]::NewLine+'SSH 指纹：'+[string]$poll.ObservedFingerprint) '通过云控制台等可信来源核对；没有来源时，这是明确的首次信任决定。指纹变化不会自动忽略。' '我已核对，信任此目标' {
     $server=Get-TCServer -Root $script:Root -Id $script:DeployUI.Run.ServerRecordId
     $null=Set-TCDeployCredential -SessionRef $script:DeployUI.SessionRef -Connection $server.Connection -Credential $script:DeployUI.Credential -PinnedFingerprint $script:DeployUI.TrustShown
    }
   };return
  }
  if($poll.HasSession -and -not $script:DeployUI.SessionAttached){
   $script:DeployUI.SessionAttached=$true
   if($script:DeployUI.RememberCredential -and $script:DeployUI.Credential){$saved=Save-TCDeployCredential -Root $script:Root -Credential $script:DeployUI.Credential;$null=Set-TCServerRecord -Root $script:Root -Id $script:DeployUI.Run.ServerRecordId -CredentialRef $saved.CredentialRef}
   if($poll.ObservedFingerprint){$null=Set-TCServerRecord -Root $script:Root -Id $script:DeployUI.Run.ServerRecordId -PinnedFingerprint $poll.ObservedFingerprint}
   $script:DeployUI.Credential=$null
   StartJob @{Action='DeploymentAttach';RunId=$script:DeployUI.Run.RunId;SessionRef=$script:DeployUI.SessionRef} {param($run)$script:DeployUI.Run=$run;AdvanceDeploymentUI} '认证完成，开始只读检查…';return
  }
  if(-not $script:DeployUI.SessionAttached -and $poll.Status -eq 'Failed' -and $poll.Code -notin @('HostTrustRequired','HostKeyUnknown')){$script:DeployUI.Credential=$null;$script:Footer.Text=('认证未完成：'+$poll.Code+'，请重新核对凭据或服务器身份。');return}
  if($script:DeployUI.Run -and $script:DeployUI.Run.Status -eq 'Running'){PollDeploymentRunUI}
 }catch{$script:DeployUI.PollError='状态读取未完成：'+$_.Exception.Message;$script:Footer.Text=$script:DeployUI.PollError}
}
function ResumeProductDeployment {param([string]$RunId)
 if($script:ReadOnly){ErrorDialog '只读窗口不恢复执行操作。';return}
 StartJob @{Action='DeploymentGet';RunId=$RunId} {param($run)
  $script:DeployUI.Run=$run;$script:DeployUI.ServerId=$run.ServerRecordId;$script:DeployUI.SessionRef=$run.SessionRef;$script:DeployUI.SessionAttached=$false;$script:DeployUI.ManagementMode=$false;$script:DeployUI.TrustShown=$null;$script:Role='deployment';$script:Step=1
  if($run.SessionRef -and -not $script:Smoke){try{Import-Module (Join-Path $script:PackageRoot 'DeploymentTransport.psm1') -DisableNameChecking;$state=Get-TCDeploySession -SessionRef $run.SessionRef;if($state.HasSession){$script:DeployUI.SessionAttached=$true}}catch{}}
  $script:DeployUI.PollError=''
  $script:DeployUI.Reauth=($run.Stage -eq 'PrepareAccess' -and -not $script:DeployUI.SessionAttached)
  StartJob @{Action='DeploymentDiscover'} {param($d)$script:DeployUI.Discovery=$d;ShowProductDeployment} '恢复原服务器与申请引用…'
 } '读取原部署运行，不生成新申请…'
}
function DeploymentStageLabel {param([string]$Stage)
 $labels=@{PrepareAccess='等待服务器登录';Inspect='检查服务器环境';PlanReady='核对变更计划';Apply='部署服务器服务';ServerInfo='核对服务器身份';ManagementPlan='检查管理能力';ManagementApply='准备设备管理';Authorize='授权这台电脑';ServerExit='检查服务器出口';CheckingProfiles='自动检查连接方式';ReadyInactive='准备完成，尚未启用';Reconcile='核对上次操作结果';RequestStatus='核对原设备申请';NeedsRecovery='需要恢复服务器事务'}
 if($labels.ContainsKey($Stage)){return $labels[$Stage]};return '处理部署阶段'
}
function DeploymentStatusLabel {param([string]$Status)
 $labels=@{WaitingUser='等待你的操作';Running='正在处理';Idle='已保存';Failed='需要处理';OutcomeUnknown='结果需要核对';NeedsRecovery='需要恢复';Cancelled='已取消，记录保留';Complete='完成';Completed='完成';CompletedWithWarnings='有项目需处理';PartialDeployment='部分完成';Dispatching='正在提交'}
 if($labels.ContainsKey($Status)){return $labels[$Status]};return '核对状态中'
}
function DeploymentLineView {param($Run)
 $profiles=@(ProfileUIField $Run 'Profiles' @()|Where-Object {$_})
 if(-not $profiles.Count){
  foreach($id in @('Udp','Tcp')){
   $prep=ProfileUIField (ProfileUIField $Run 'ProtocolPreparation') $id
   $validation=ProfileUIField (ProfileUIField $Run 'ValidationProfiles') $id
   if($prep -or $validation){
    $local=[string](ProfileUIField $prep 'LocalPreparation' 'Missing')
    $profiles+=,[pscustomobject]@{Id=$id;PreparationState=$(if($local -in @('Ready','SyntaxValidated')){'Ready'}else{$local});CandidateSHA256=(ProfileUIField $validation 'CandidateSHA256');Validation=$validation}
   }
  }
 }
 [pscustomobject]@{LineId=(UILineId $Run);Name=$Run.Name;Profiles=$profiles;Recommendation=(ProfileUIField $Run 'Recommendation');PreferredProfileId=(ProfileUIField $Run 'PreferredProfileId');PreferenceSource=(ProfileUIField $Run 'PreferenceSource' (ProfileUIField (ProfileUIField $Run 'Recommendation') 'Source'));SourceManifestPath=(ProfileUIField $Run 'CandidateManifestPath')}
}
function DeploymentCompletenessView {param($Run)
 $line=DeploymentLineView $Run;$prepared=@($line.Profiles|Where-Object {ProfileIsPrepared $_}|ForEach-Object {$_.Id})
 $state=[string](ProfileUIField $Run 'DeploymentCompleteness' '')
 $missing=@(ProfileUIField $Run 'MissingProtocols' @()|Where-Object {$_ -in @('Udp','Tcp')})
 if(-not $state -or ($state -eq 'Partial' -and -not $missing.Count)){$missing=@('Udp','Tcp'|Where-Object {$_ -notin $prepared})}
 if((ProfileUIField $Run 'RecoveryRequired' $false) -eq $true -or [string](ProfileUIField $Run 'Status' '') -in @('NeedsRecovery','OutcomeUnknown') -or [string](ProfileUIField $Run 'Stage' '') -eq 'NeedsRecovery'){$state='NeedsRecovery'}
 elseif(-not $state){$state=if($missing.Count){'Partial'}else{'Complete'}}
 elseif($state -eq 'Complete' -and $missing.Count){$state='Partial'}
 $prepared=@($prepared|Where-Object {$_ -notin $missing})
 $label=switch($state){
  'Complete'{'准备完成：UDP / TCP 已备齐'}
  'Partial'{if($prepared.Count){'部分完成：仅已准备 '+($prepared.ToUpperInvariant() -join ' / ')}else{'部分完成：连接配置尚未备齐'}}
  'NeedsRecovery'{'准备需要恢复：先核对原部署事务'}
  default{'准备状态待核对'}
 }
 [pscustomobject]@{State=$state;MissingProtocols=$missing;PreparedProtocols=$prepared;Label=$label}
}
function DeploymentLater {
 $script:Step=0;$script:Role='client';ShowNodes;FetchNodes
}
function StopDeploymentLocalCheck {
 if($script:ReadOnly){ErrorDialog '只读窗口不停止检查。';return}
 $id=[string](ProfileUIField $script:DeployUI.Run 'RunId' '')
 if(-not $id){return}
 if($script:Smoke){StartJob @{Action='DeploymentCancelProbe';RunId=$id} {param($d)Toast '已请求停止本次检查，已准备资料保留'} '请求停止本机检查…';return}
 try{
  Import-Module (Join-Path $script:PackageRoot 'DeploymentFlow.psm1') -DisableNameChecking
  $result=Request-TCDeploymentProbeStop -Root $script:Root -RunId $id
  if($result.Accepted){Toast '已请求停止；当前请求结束后清理探针，现有连接保持'}else{Toast '当前没有正在运行的本机检查'}
 }catch{ErrorDialog '停止请求未能保存，请等待本次有时限的检查结束。'}
}
function ShowDeploymentRun {
 $run=$script:DeployUI.Run;$card=Card;$p=Stack;$card.Child=$p
 $checking=DeploymentLocalCheckPending $run;$local=($run.Stage -in @('CheckingProfiles','ReadyInactive'));$line=DeploymentLineView $run
 $completeness=DeploymentCompletenessView $run;$outcome=($local -or $completeness.State -eq 'NeedsRecovery')
 $subtitle=if($outcome){$completeness.Label}else{(DeploymentStageLabel $run.Stage)+' · '+(DeploymentStatusLabel $run.Status)}
 SetupCardHeader $p ([string]$run.Name) $subtitle 'server'
 if($outcome){
  AddC $p (ControlName (T $completeness.Label 15 $script:Ink 'SemiBold') 'DeployPreparationStatus')
  if($completeness.MissingProtocols.Count){AddC $p (Margin (ControlName (T ('缺少协议：'+($completeness.MissingProtocols.ToUpperInvariant() -join ' / ')) 13 '#A15C07') 'DeployMissingProtocols') '0,6,0,0')}
  if($completeness.State -eq 'Partial'){
   AddC $p (Margin (T '本次部署尚未完整完成。网络检查通过也不代表缺少的协议已准备。' 13 $script:Text2) '0,6,0,0')
   if((ProfileUIField $run 'PartialUseAccepted' $false) -eq $true){AddC $p (Margin (ControlName (T '已确认先使用已准备方式；部署仍为部分完成。' 13 '#A15C07') 'DeployPartialUseAccepted') '0,6,0,0')}
  }
 }
 if($completeness.State -eq 'NeedsRecovery'){
  AddC $p (Margin (T '先核对上次部署的实际结果，再继续准备；暂不能先使用候选配置。' 13 $script:Text2) '0,8,0,0')
 }
 elseif($checking){
  AddC $p (Margin (ControlName (T '网络检查：正在检查已准备的连接方式，随后显示推荐与依据。' 14 $script:Ink 'SemiBold') 'DeployCheckProgress') '0,10,0,0')
  AddC $p (Margin (T '检查按顺序运行，当前连接保持。准备状态与网络结果分别记录。' 13 $script:Text2) '0,6,0,0')
 }
 elseif($run.Stage -eq 'ReadyInactive'){
  if(NodeHasActiveProfile $line){AddC $p (Margin (ControlName (T (ActiveLineStatus $line) 15 $script:Ink 'SemiBold') 'DeployActiveStatus') '0,10,0,0')}
  $r=LineRecommendationView $line
  AddC $p (Margin (ControlName (T $r.Label 17 $script:Ink 'SemiBold') 'DeployDefaultLabel') '0,10,0,0')
  AddC $p (Margin (ControlName (T ($r.Basis+'。'+$r.Reason) 13 $script:Text2) 'DeployRecommendationReason') '0,6,0,0')
  if([string](ProfileUIField $run 'ProfileProbeState' '') -eq 'Interrupted'){AddC $p (Margin (T '上次检查已中断，已准备资料保留；请重试检查。' 13 '#A15C07') '0,6,0,0')}
  if($r.ProfileId){$selected=@($line.Profiles|Where-Object Id -eq $r.ProfileId)|Select-Object -First 1;AddC $p (Margin (ControlName (T ((UIProfileName $r.ProfileId)+' 检查汇总：'+(ConnectionProfileStatus $selected)) 13 $script:Text2) 'DeployValidationSummary') '0,6,0,0')}
  AddLineRecommendationEvidence $p $line 'Deploy'
 }
 else{AddC $p (Note 'UDP / TCP 准备状态与网络检查单独显示，备齐后再确定初始连接方式。')}
 AddDeploymentProtocolResults $p $run
 if($run.LastError){AddC $p (Margin (T ([string]$run.LastError.Message) 13 '#B42318') '0,10,0,0')}
 if(ProfileUIField $script:DeployUI 'PollError'){AddC $p (Margin (Notice 'warn' '状态读取未完成' $script:DeployUI.PollError) '0,10,0,0');$null=DeploymentActions $p '重试读取状态' 'DeployRetryStatus' {PollDeploymentRunUI} 'Btn'}
 $actions=New-Object Windows.Controls.WrapPanel
 if($completeness.State -eq 'NeedsRecovery'){
  $null=DeploymentActions $actions '核对原部署并继续恢复' 'DeployReconcile' {AdvanceDeploymentUI 'Continue'} 'Btn'
  $null=DeploymentActions $actions '稍后' 'DeployLater' {DeploymentLater} 'Ghost'
 }
 elseif($checking){
  $null=DeploymentActions $actions '停止本次检查' 'DeployStopCheck' {StopDeploymentLocalCheck} 'Btn'
  $null=DeploymentActions $actions '稍后使用' 'DeployLater' {DeploymentLater} 'Ghost'
 }
 elseif($run.Stage -eq 'ReadyInactive'){
  if($completeness.State -eq 'Partial'){
   $null=DeploymentActions $actions '继续完成部署' 'DeployCompleteRemaining' {AdvanceDeploymentUI 'Recheck'}
   if((ProfileUIField $run 'PartialUseAccepted' $false) -eq $true){
    if(NodeHasActiveProfile $line){$null=DeploymentActions $actions '继续使用已准备方式' 'DeployContinueCurrent' {ShowHome;RefreshOverview -Silent} 'Btn'}
    elseif($r.CanConnect -and (UILineId $line)){$null=DeploymentActions $actions '连接已准备方式' 'DeployConnectRecommended' {PreviewDefaultLineConnection (UILineId $script:DeployUI.Run)} 'Btn'}
    else{$null=DeploymentActions $actions '重试网络检查' 'DeployProbe' {AdvanceDeploymentUI 'Probe'} 'Btn'}
   }elseif($completeness.PreparedProtocols.Count){$null=DeploymentActions $actions '先使用已准备方式' 'DeployUsePrepared' {AdvanceDeploymentUI 'UsePrepared'} 'Btn'}
   $null=DeploymentActions $actions '稍后' 'DeployLater' {DeploymentLater} 'Ghost'
  }else{
   if(NodeHasActiveProfile $line){$null=DeploymentActions $actions '继续使用' 'DeployContinueCurrent' {ShowHome;RefreshOverview -Silent}}
   elseif($r.CanConnect -and (UILineId $line)){$null=DeploymentActions $actions $r.Button 'DeployConnectRecommended' {PreviewDefaultLineConnection (UILineId $script:DeployUI.Run)}}
   else{$null=DeploymentActions $actions '重试检查' 'DeployProbe' {AdvanceDeploymentUI 'Probe'}}
   $null=DeploymentActions $actions '稍后使用' 'DeployLater' {DeploymentLater} 'Ghost'
  }
 }
 elseif($run.Stage -eq 'PlanReady' -and $run.Review){
  AddC $p (Margin (T $run.Review.Title 17 $script:Ink 'SemiBold') '0,14,0,4');AddC $p (T $run.Review.Details 13 $script:Text2)
  if($run.Plan){AddC $p (Margin (T ('云端入口：'+$run.Plan.PublicEndpoint+'；UDP '+$run.VpnPort+' / TCP '+$run.TcpPort+'。保留 SSH 管理端口。') 13 $script:Text2) '0,12,0,0')}
  $null=DeploymentActions $actions '核对变更并开始部署 / 授权' 'DeployApprove' {OpenDialog '按这份预览执行？' $script:DeployUI.Run.Review.Details '仅处理此服务器和候选，不切换本机线路。请完成本次云规则。' '开始执行' {AdvanceDeploymentUI 'Approve'}}
 }
 elseif($run.Status -in @('Failed','OutcomeUnknown','NeedsRecovery','Cancelled')){
  $null=DeploymentActions $actions '重新核对原操作结果' 'DeployReconcile' {AdvanceDeploymentUI 'Continue'} 'Btn'
  AddC $p (Margin (T '保留原申请与部署记录，从原操作继续核对。' 12 $script:Text3) '0,10,0,0')
 }
 else{AddC $p (Margin (T '正在处理，进度会保存。' 13 $script:Text2) '0,14,0,0')}
 AddC $p $actions
 # Network checks and ordinary connection failures never imply expired SSH.
 $authCode=[string](ProfileUIField (ProfileUIField $run 'LastError') 'Code' '')
 if(-not $local -and -not $script:DeployUI.SessionAttached -and ($run.Stage -eq 'PrepareAccess' -or $authCode -match 'Auth|SessionExpired|HostTrust|HostKey')){
  $null=DeploymentActions $p '重新核对登录 / 主机信任' 'DeployRetryTrust' {$script:DeployUI.Reauth=$true;$script:DeployUI.TrustShown=$null;$script:DeployUI.ServerId=$script:DeployUI.Run.ServerRecordId;ShowProductDeployment} 'Ghost'
 }
 if(-not $local){
  $details=Stack
  $rules=@(ProfileUIField $run 'CloudRuleList' @()|Where-Object {$_})
  if($rules.Count){
   $text=(@($rules|ForEach-Object {([string]$_.Purpose+': '+([string]$_.Protocol).ToUpperInvariant()+' '+[string]$_.Port)}) -join [Environment]::NewLine)
   $copy=Btn '复制本次云规则清单' 'CopyDeploymentCloudRules' {[Windows.Clipboard]::SetText([string]$this.Tag);Toast '规则清单已复制'} 'Btn';$copy.Tag=$text;AddC $details $copy
   AddC $details (Margin (T $text 12 $script:Text3) '0,6,0,0')
  }
  $null=DeploymentActions $details '我的服务器' 'DeployManageServers' {ShowServerManagement} 'Ghost'
  $exp=New-Object Windows.Controls.Expander;$exp.Header='服务器与部署资料';$exp.Content=$details;$exp.Margin='0,18,0,0';AddC $p $exp
 }
 AddC $script:HostPanel $card
}
function AddDeploymentProtocolResults {param($Parent,$Run)
 $line=DeploymentLineView $Run
 if(-not $line.Profiles.Count -and -not (ProfileUIField $Run 'ProtocolPreparation')){return}
 AddC $Parent (Rule)
 foreach($id in @('Udp','Tcp')){
  $profile=@($line.Profiles|Where-Object Id -eq $id)|Select-Object -First 1
  $prep=ProfileUIField (ProfileUIField $Run 'ProtocolPreparation') $id
  $preparation=ProfilePreparationStatus $profile
  if([string](ProfileUIField $prep 'ServerPreparation' '') -in @('Failed','Invalid')){$preparation='准备未完成'}
  if([string](ProfileUIField $prep 'ServerPreparation' '') -in @('OutcomeUnknown','NeedsRecovery')){$preparation='需恢复 / 核对'}
  KeyValue $Parent ((UIProfileName $id)+' 准备') $preparation $script:Text2 ('DeployPreparation'+$id)
  $text=if((ActiveNodeProfileId $line) -eq $id){ActiveLineStatus $line}elseif(ProfileIsPrepared $profile){ConnectionProfileStatus $profile}else{'尚未检查（配置未准备）'}
  if((DeploymentLocalCheckPending $Run) -and (ProfileIsPrepared $profile) -and (ProfileValidationView $profile.Validation).Status -eq 'NotTested'){$text='等待自动检查'}
  KeyValue $Parent ((UIProfileName $id)+' 网络检查') $text $script:Text2 ('DeployProfile'+$id)
  $error=ProfileUIField $prep 'Error'
  if($error){AddC $Parent (Margin (T ([string](ProfileUIField $error 'Message' '该阶段未完成，请核对服务器或云规则。')) 12 '#A15C07') '0,3,0,5')}
 }
}
