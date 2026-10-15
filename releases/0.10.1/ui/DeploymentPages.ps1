# Deployment pages: credentials only travel GUI memory -> SID-limited pipe.
$script:DeployUI=@{Intent='New';Screen='connect';Run=$null;Discovery=$null;SessionRef=$null;SessionAttached=$false;Credential=$null;RememberCredential=$false;LastPoll=[DateTime]::MinValue;TrustShown=$null;ServerId=$null;Server=$null;Management=$null;DeviceResult=$null;Invite=$null;PairRequest=$null;EnrollmentId=$null;PendingManagement=$null}
function DeploymentField {param($Parent,[string]$Label,[string]$Id,[string]$Value='',[string]$Hint='',[switch]$Multiline)
 AddC $Parent (Margin (T $Label 12.5 $script:Ink 'SemiBold') '0,12,0,5')
 $box=ControlName (New-Object Windows.Controls.TextBox) $Id;$box.Text=$Value;$box.MinHeight=34
 if($Multiline){$box.AcceptsReturn=$true;$box.TextWrapping='Wrap';$box.MinHeight=96;$box.MaxHeight=180;$box.VerticalScrollBarVisibility='Auto'}
 AddC $Parent $box;if($Hint){AddC $Parent (Margin (T $Hint 12 $script:Text3) '0,4,0,0')};return $box
}
function DeploymentActions {param($Parent,[string]$Label,[string]$Id,[scriptblock]$Action,[string]$Style='Primary')
 $button=Btn $Label $Id $Action $Style;$button.Margin='0,16,10,0';$button.HorizontalAlignment='Left';AddC $Parent $button;return $button
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
 $script:Page='setup';Head '' '准备连接' '完成服务器配置与本机候选准备；验证通过后由你明确启用。'
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
 $null=DeploymentField $p '服务器地址或接入信息' 'DeployConnectionText' $hostValue '可粘贴 IP、root@IP 或 ssh root@IP -p 22；不会执行粘贴文本。'
 $null=DeploymentField $p '线路名称' 'DeployName' $nameValue
 $null=DeploymentField $p 'SSH 用户名' 'DeployUser' $(if($server -and $server.Connection){[string]$server.Connection.User}else{'root'})
 $null=DeploymentField $p 'SSH 端口' 'DeployPort' $(if($server -and $server.Connection){[string]$server.Connection.Port}else{'22'})
 $null=DeploymentField $p 'SSH 私钥文件（可留空）' 'DeployKeyPath' $(if($server -and $server.Connection){[string]$server.Connection.IdentityFile}else{''})
 AddC $p (Margin (T '密码 / SSH 私钥口令' 12.5 $script:Ink 'SemiBold') '0,12,0,5')
 $password=ControlName (New-Object Windows.Controls.PasswordBox) 'DeployPassword';$password.MinHeight=34;AddC $p $password
 $remember=ControlName (New-Object Windows.Controls.CheckBox) 'DeployRemember';$remember.Content='加密记住管理凭据（当前 Windows 用户）';$remember.Margin='0,10,0,0';AddC $p $remember
 if($server -and $server.CredentialRef){$useSaved=ControlName (New-Object Windows.Controls.CheckBox) 'DeployUseSaved';$useSaved.Content='使用这台服务器已加密保存的管理凭据';$useSaved.IsChecked=$true;$useSaved.Margin='0,8,0,0';AddC $p $useSaved}
 $mode=ControlName (New-Object Windows.Controls.ComboBox) 'DeployTransport'
 foreach($option in @(@('自动准备 UDP，探测后选择备用方式','Auto'),@('UDP','Udp'),@('TCP / Reality','Tcp'))){$item=New-Object Windows.Controls.ComboBoxItem;$item.Content=$option[0];$item.Tag=$option[1];$null=$mode.Items.Add($item)};$mode.SelectedIndex=0
 AddC $p (Margin (T '连接方式' 12.5 $script:Ink 'SemiBold') '0,12,0,5');AddC $p $mode
 $null=DeploymentField $p 'TCP 端口（仅 TCP）' 'DeployTcpPort' '443'
 $null=DeploymentField $p 'TLS 域名（仅 TCP）' 'DeployServerName' 'www.bing.com'
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
 $request=@{Action='DeploymentProceed';RunId=$script:DeployUI.Run.RunId;Command=$Command}
 if($Command -eq 'Approve'){$request.ApprovedChangeDigest=$script:DeployUI.Run.Review.ChangeDigest}
 StartJob $request {param($run)$script:DeployUI.Run=$run;ShowProductDeployment} '处理部署阶段；现有线路保持…'
}
function PollProductDeployment {
 if($script:Smoke -or (IsBusy) -or -not $script:DeployUI.SessionRef -or ((Get-Date)-$script:DeployUI.LastPoll).TotalSeconds -lt 2){return}
 $script:DeployUI.LastPoll=Get-Date
 if($script:DeployUI.ManagementMode -or $script:DeployUI.PendingManagement){PollServerOperation;return}
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
  if($script:DeployUI.Run -and $script:DeployUI.Run.Status -eq 'Running'){StartJob @{Action='DeploymentPoll';RunId=$script:DeployUI.Run.RunId} {param($run)$script:DeployUI.Run=$run;if($script:Role -eq 'deployment'){ShowProductDeployment}} '读取部署进度…' '' -Silent}
 }catch{if($script:DeployUI.Run){$script:DeployUI.Run.Status='OutcomeUnknown'};$script:DeployUI.Credential=$null;$script:Footer.Text='无法确认服务器结果，请重新登录并核对原操作。'}
}
function ResumeProductDeployment {param([string]$RunId)
 if($script:ReadOnly){ErrorDialog '只读窗口不恢复执行操作。';return}
 StartJob @{Action='DeploymentGet';RunId=$RunId} {param($run)
  $script:DeployUI.Run=$run;$script:DeployUI.ServerId=$run.ServerRecordId;$script:DeployUI.SessionRef=$run.SessionRef;$script:DeployUI.SessionAttached=$false;$script:DeployUI.ManagementMode=$false;$script:DeployUI.TrustShown=$null;$script:Role='deployment';$script:Step=1
  if($run.SessionRef -and -not $script:Smoke){try{Import-Module (Join-Path $script:PackageRoot 'DeploymentTransport.psm1') -DisableNameChecking;$state=Get-TCDeploySession -SessionRef $run.SessionRef;if($state.HasSession){$script:DeployUI.SessionAttached=$true}}catch{}}
  if(-not $script:DeployUI.SessionAttached -and $run.Stage -ne 'ReadyInactive'){$script:DeployUI.Reauth=$true}else{$script:DeployUI.Reauth=$false}
  StartJob @{Action='DeploymentDiscover'} {param($d)$script:DeployUI.Discovery=$d;ShowProductDeployment} '恢复原服务器与申请引用…'
 } '读取原部署运行，不生成新申请…'
}
function DeploymentStageLabel {param([string]$Stage)
 $labels=@{PrepareAccess='等待服务器登录';Inspect='检查服务器环境';PlanReady='核对变更计划';Apply='部署服务器服务';ServerInfo='核对服务器身份';ManagementPlan='检查管理能力';ManagementApply='准备设备管理';Authorize='授权这台电脑';ServerExit='检查服务器出口';ReadyInactive='准备完成，尚未启用';Reconcile='核对上次操作结果';RequestStatus='核对原设备申请';NeedsRecovery='需要恢复服务器事务'}
 if($labels.ContainsKey($Stage)){return $labels[$Stage]};return '处理部署阶段'
}
function DeploymentStatusLabel {param([string]$Status)
 $labels=@{WaitingUser='等待你的操作';Running='正在处理';Idle='已保存';Failed='需要处理';OutcomeUnknown='结果需要核对';NeedsRecovery='需要恢复';Cancelled='已取消，记录保留';Complete='完成';Dispatching='正在提交'}
 if($labels.ContainsKey($Status)){return $labels[$Status]};return '核对状态中'
}
function ShowDeploymentRun {
 $run=$script:DeployUI.Run;$card=Card;$p=Stack;$card.Child=$p
 SetupCardHeader $p ([string]$run.Name) ((DeploymentStageLabel $run.Stage)+' · '+(DeploymentStatusLabel $run.Status)) 'server'
 AddC $p (Note '本机准备与启用分开；当前交易线路不会因部署进度而切换。')
 if(-not $script:DeployUI.SessionAttached){$null=DeploymentActions $p '重新核对登录 / 主机信任' 'DeployRetryTrust' {$script:DeployUI.Reauth=$true;$script:DeployUI.TrustShown=$null;$script:DeployUI.ServerId=$script:DeployUI.Run.ServerRecordId;ShowProductDeployment} 'Ghost'}
 if($run.LastError){AddC $p (Margin (T ([string]$run.LastError.Message) 13 '#B42318') '0,12,0,0')}
 if($run.Stage -eq 'PlanReady' -and $run.Review){
  AddC $p (Margin (T $run.Review.Title 17 $script:Ink 'SemiBold') '0,14,0,4');AddC $p (T $run.Review.Details 13 $script:Text2)
  if($run.Plan){AddC $p (Margin (T ('云端入口：'+$run.Plan.PublicEndpoint+'；'+$(if($run.Transport -eq 'Tcp'){'TCP '+$run.TcpPort}else{'UDP '+$run.VpnPort})+'。保留 SSH 管理端口。') 13 $script:Text2) '0,12,0,0')}
  $null=DeploymentActions $p '核对变更并开始部署 / 授权' 'DeployApprove' {OpenDialog '按这份预览执行？' $script:DeployUI.Run.Review.Details '仅处理此服务器和候选，不切换本机线路。请完成本次云规则。' '开始执行' {AdvanceDeploymentUI 'Approve'}}
 }
 elseif($run.Stage -eq 'ReadyInactive'){
  AddC $p (Margin (StatusLine 'ok' '线路已准备，尚未启用') '0,14,0,0')
  if($run.Validation){$resultText=switch([string]$run.Validation.Status){'Passed'{'测试通过'}'Failed'{'测试未通过，请查看原因'}'Inconclusive'{'部分检查通过，仍有项目需核验'}default{'尚未得到完整结果'}};$pathText=if($run.Validation.TransportPath -eq 'PhysicalDirect'){'本地直连路径已核验'}else{'测试沿用当前网络，不能据此确认本地直连'};AddC $p (Margin (T ('独立探测：'+$resultText+'；'+$pathText) 13 $script:Text2) '0,8,0,0')}
  $null=DeploymentActions $p '独立验证候选线路' 'DeployProbe' {AdvanceDeploymentUI 'Probe'}
  $null=DeploymentActions $p '前往线路页，选择启用时间' 'DeployToNodes' {$script:Step=0;ShowNodes;FetchNodes} 'Ghost'
  $null=DeploymentActions $p '导出管理恢复资料' 'DeployRecovery' {ShowManagementRecovery} 'Ghost'
 }
 elseif($run.Status -in @('Failed','OutcomeUnknown','NeedsRecovery','Cancelled')){
  $null=DeploymentActions $p '重新登录并续接此操作' 'DeployAuthenticateAgain' {$script:DeployUI.Reauth=$true;$script:DeployUI.ServerId=$script:DeployUI.Run.ServerRecordId;$script:DeployUI.Credential=$null;ShowProductDeployment} 'Ghost'
  $null=DeploymentActions $p '重新核对原操作结果' 'DeployReconcile' {AdvanceDeploymentUI 'Continue'} 'Ghost'
  AddC $p (Margin (T '会话失效时请重新认证；保留原申请，避免重复授权。' 12 $script:Text3) '0,10,0,0')
 }else{AddC $p (Margin (T '正在处理，进度会保存；长时间离开后可能需要重新认证。' 13 $script:Text2) '0,14,0,0')}
 $null=DeploymentActions $p '我的服务器' 'DeployManageServers' {ShowServerManagement} 'Ghost';AddC $script:HostPanel $card
}
