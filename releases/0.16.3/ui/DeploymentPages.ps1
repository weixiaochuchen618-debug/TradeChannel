# Deployment pages: credentials only travel GUI memory -> SID-limited pipe.
$script:DeployUI=@{Intent='New';Screen='connect';Run=$null;Discovery=$null;SessionRef=$null;SessionAttached=$false;Credential=$null;RememberCredential=$false;LastPoll=[DateTime]::MinValue;TrustShown=$null;ServerId=$null;Server=$null;Management=$null;DeviceResult=$null;Invite=$null;PairRequest=$null;EnrollmentId=$null;PendingManagement=$null}
function ClearDeploymentCredentialUI {
 $script:DeployUI.Credential=$null;$script:DeployUI.CredentialBinding=$null;$script:DeployUI.CredentialExpiresAt=$null
 if($script:DeployUI.PasswordControl){$script:DeployUI.PasswordControl.Clear()}
}
function DeploymentCredentialScopeUI {param($Server)
 [ordered]@{RunId=[string]$script:DeployUI.Run.RunId;ServerRecordId=[string]$Server.LocalRecordId;Host=[string]$Server.Connection.Host;Port=[int]$Server.Connection.Port;User=[string]$Server.Connection.User;PinnedFingerprint=[string]$Server.PinnedHostKey}
}
function TestDeploymentCredentialUI {param($Server)
 if(-not $script:DeployUI.Credential -or -not $script:DeployUI.CredentialExpiresAt){return $false}
 if([DateTimeOffset]$script:DeployUI.CredentialExpiresAt -le [DateTimeOffset]::UtcNow){ClearDeploymentCredentialUI;return $false}
 $bound=$script:DeployUI.CredentialBinding;if(-not $bound){return $false};$current=DeploymentCredentialScopeUI $Server
 foreach($key in $current.Keys){if([string]$current[$key] -cne [string]$bound[$key]){return $false}}
 return $true
}
function UseDeploymentRetryCredentialUI {
 Import-Module (Join-Path $script:PackageRoot 'ServerRegistry.psm1') -DisableNameChecking
 Import-Module (Join-Path $script:PackageRoot 'DeploymentTransport.psm1') -DisableNameChecking
 $server=Get-TCServer -Root $script:Root -Id $script:DeployUI.Run.ServerRecordId
 $kind=[string](ProfileUIField (ProfileUIField $script:DeployUI.Run 'AccessIssue') 'Kind' '')
 if($kind -in @('Credentials','PrivateKey','IdentityChanged','FirstTrust','ApplicationReset','ApplicationMismatch')){return $false}
 if(TestDeploymentCredentialUI $server){return $true}
 # A retained credential belongs to exactly one run, target, account and pin.
 # A changed binding must never be silently replaced by another saved secret.
 if($script:DeployUI.CredentialBinding){ClearDeploymentCredentialUI;return $false}
 if($script:DeployUI.Credential){ClearDeploymentCredentialUI}
 if($server.CredentialRef -and $server.PinnedHostKey){
  try{$credential=Get-TCDeploySavedCredential -Root $script:Root -CredentialRef $server.CredentialRef}catch{return $false}
  $script:DeployUI.Credential=$credential;$script:DeployUI.CredentialFresh=$false
  $script:DeployUI.CredentialBinding=DeploymentCredentialScopeUI $server;$script:DeployUI.CredentialExpiresAt=[DateTimeOffset]::UtcNow.AddMinutes(30)
  return $true
 }
 return $false
}
function RetryDeploymentConnectionUI {param([switch]$Automatic)
 if($script:ReadOnly -or (IsBusy) -or -not $script:DeployUI.Run){return $false}
 if($Automatic -and [int](ProfileUIField $script:DeployUI 'AutomaticLoginRetries' 0) -ge 2){return $false}
 if(-not (UseDeploymentRetryCredentialUI)){
  if(-not $Automatic){$script:DeployUI.Reauth=$true;$script:DeployUI.ReconnectMessage='需要有效登录才能恢复原步骤。';ShowProductDeployment}
  return $false
 }
 if($Automatic){$script:DeployUI.AutomaticLoginRetries=[int](ProfileUIField $script:DeployUI 'AutomaticLoginRetries' 0)+1}else{$script:DeployUI.AutomaticLoginRetries=0}
 $script:DeployUI.Reauth=$false;$script:DeployUI.ReconnectMessage='正在恢复服务器连接；已完成步骤会保留。'
 ShowProductDeployment;StartDeploymentSessionUI -ReuseCredential
 return $true
}
function DeploymentField {param($Parent,[string]$Label,[string]$Id,[string]$Value='',[string]$Hint='',[switch]$Multiline)
 AddC $Parent (Margin (T $Label 12.5 $script:Ink 'SemiBold') '0,12,0,5')
 $box=ControlName (New-Object Windows.Controls.TextBox) $Id;$box.Text=$Value;$box.MinHeight=34
 if($Multiline){$box.AcceptsReturn=$true;$box.TextWrapping='Wrap';$box.MinHeight=96;$box.MaxHeight=180;$box.VerticalScrollBarVisibility='Auto'}
 AddC $Parent $box;if($Hint){AddC $Parent (Margin (T $Hint 12 $script:Text3) '0,4,0,0')};return $box
}
function DeploymentActions {param($Parent,[string]$Label,[string]$Id,[scriptblock]$Action,[string]$Style='Primary')
 $button=Btn $Label $Id $Action $Style;$button.MinWidth=96;$button.Margin='0,16,10,0';$button.HorizontalAlignment='Left';AddC $Parent $button;return $button
}
function BeginProductDeployment {param([string]$Intent='Auto',[string]$ServerId)
 if($script:DeployUI.Run -and $script:DeployUI.Run.Status -in @('Running','Dispatching')){ErrorDialog '当前部署尚未完成，请先查询结果或安全取消。';return}
 if($script:Role -ne 'deployment'){$script:DeployUI.DeploymentReturnContext=CaptureNavigationContext}
 $script:DeployUI.ManagementMode=$false;$script:DeployUI.Reauth=$false
 $script:Role='deployment';$script:Step=1;$script:DeployUI.Intent=$Intent;$script:DeployUI.Screen='connect';$script:DeployUI.ServerId=$ServerId
 ClearDeploymentCredentialUI
 $script:DeployUI.Run=$null;$script:DeployUI.SessionAttached=$false;$script:DeployUI.TrustShown=$null;$script:DeployUI.ReconnectMessage='';$script:DeployUI.AutomaticLoginRetries=0
 $script:DeployUI.LastAccessSignature='';$script:DeployUI.Reauth=$false
 if($script:DeployUI.PasswordControl){$script:DeployUI.PasswordControl.Clear()};$script:DeployUI.PasswordControl=$null;$script:DeployUI.FormDraft=@{}
 $script:DeployUI.ChooseNetwork=$false
 ShowProductDeployment
 StartJob @{Action='DeploymentDiscover'} {param($d)$script:DeployUI.Discovery=$d;if($script:Role -eq 'deployment'){ShowProductDeployment}} '读取已有线路与部署进度…' '' -Silent
}
function ShowProductDeployment {
 if($script:Controls.ContainsKey('DeployConnectionText')){
  $draft=@{};foreach($key in @('DeployConnectionText','DeployName','DeployUser','DeployPort','DeployKeyPath','DeployTcpPort','DeployServerName')){if($script:Controls.ContainsKey($key)){$draft[$key]=$script:Controls[$key].Text}}
  if($script:Controls.ContainsKey('DeployLoginMethod')){$draft.LoginMethod=$script:Controls.DeployLoginMethod.SelectedIndex};$script:DeployUI.FormDraft=$draft
  if($script:Controls.ContainsKey('DeployPassword')){$script:DeployUI.PasswordControl=$script:Controls.DeployPassword}
 }
 $script:Page='setup';Head '' '准备连接' '同一条线路准备 UDP 和 TCP，准备状态与网络检查分别显示。'
 if(ProfileUIField $script:DeployUI 'Identity'){ShowDeploymentIdentity;return}
 if($script:DeployUI.Run -and -not $script:DeployUI.Reauth){ShowDeploymentRun;return}
 $card=Card;$p=Stack;$card.Child=$p
 if($script:DeployUI.Intent -in @('New','Auto')){
  SetupCardHeader $p '添加线路' '软件检查本机和服务器状态，自动准备两端连接。' 'laptop'
  AddC $p (Note '推荐环境：Ubuntu 24.04 或 Debian 13 x64 专用 VPS，管理员或已有免交互 sudo 的账户。购买和云端规则在厂商控制台完成。')
  $null=DeploymentActions $p '我还没有服务器：查看购买准备' 'PurchasePreparation' {ShowPurchasePreparation} 'Ghost'
 }else{SetupCardHeader $p '准备这条线路' '复用已有组件和有效偏好，现有连接继续使用。' 'server'}
 $server=$null
 if($script:DeployUI.ServerId -and $script:DeployUI.Discovery){$server=@($script:DeployUI.Discovery.Servers|Where-Object {$_.LocalRecordId -eq $script:DeployUI.ServerId})|Select-Object -First 1}
 $hostValue=if($server -and $server.Connection){[string]$server.Connection.Host}else{''}
 $nameValue=if($script:DeployUI.Run){$script:DeployUI.Run.Name}elseif($server){[string]$server.Name}else{''}
 $seed=ProfileUIField $script:DeployUI 'LegacySeed'
 if(-not $server -and $seed){$hostValue=[string]$seed.Host;$nameValue=[string]$seed.Name}
 $null=DeploymentField $p '服务器地址或接入信息' 'DeployConnectionText' $hostValue '可粘贴 IP、root@IP 或 ssh root@IP -p 22；不会执行粘贴文本。'
 $accessPanel=Stack
 $null=DeploymentField $accessPanel '线路名称（留空自动命名）' 'DeployName' $nameValue
 $null=DeploymentField $accessPanel '登录账户' 'DeployUser' $(if($server -and $server.Connection){[string]$server.Connection.User}else{'root'})
 $null=DeploymentField $accessPanel 'SSH 端口' 'DeployPort' $(if($server -and $server.Connection){[string]$server.Connection.Port}else{'22'})
 $null=DeploymentField $accessPanel 'SSH 私钥文件（密码登录留空）' 'DeployKeyPath' $(if($server -and $server.Connection){[string]$server.Connection.IdentityFile}else{''})
 if(-not $server -and $seed){$script:Controls.DeployUser.Text=[string]$seed.User;$script:Controls.DeployPort.Text=[string]$seed.Port;$script:Controls.DeployKeyPath.Text=[string]$seed.IdentityFile}
 $method=ControlName (New-Object Windows.Controls.ComboBox) 'DeployLoginMethod';$method.MinHeight=34
 foreach($choice in @('服务器密码','SSH 私钥')){$null=$method.Items.Add($choice)}
 $form=ProfileUIField $script:DeployUI 'FormDraft' @{};$method.SelectedIndex=$(if($form.ContainsKey('LoginMethod')){[int]$form.LoginMethod}elseif($server -and $server.Connection.IdentityFile){1}else{0})
 AddC $p (Margin (T '登录方式' 12.5 $script:Ink 'SemiBold') '0,12,0,5');AddC $p $method
 $credentialLabel=ControlName (T $(if($method.SelectedIndex -eq 1){'SSH 私钥解密口令（密钥未加密时留空）'}else{'服务器登录密码'}) 12.5 $script:Ink 'SemiBold') 'DeployCredentialLabel';AddC $p (Margin $credentialLabel '0,12,0,5')
 $password=$script:DeployUI.PasswordControl
 if($password -and $password.Parent -is [Windows.Controls.Panel]){$password.Parent.Children.Remove($password)}
 if(-not $password){$password=New-Object Windows.Controls.PasswordBox}
 $password=ControlName $password 'DeployPassword';$script:DeployUI.PasswordControl=$password;$password.MinHeight=34;AddC $p $password
 $method.Add_SelectionChanged({if($script:Controls.ContainsKey('DeployCredentialLabel')){$script:Controls.DeployCredentialLabel.Text=if($this.SelectedIndex -eq 1){'SSH 私钥解密口令（密钥未加密时留空）'}else{'服务器登录密码'};$script:Controls.DeployPassword.Clear()}})
 $remember=ControlName (New-Object Windows.Controls.CheckBox) 'DeployRemember';$remember.Content='加密记住管理凭据（当前 Windows 用户）';$remember.Margin='0,10,0,0';AddC $accessPanel $remember
 if($server -and $server.CredentialRef){$useSaved=ControlName (New-Object Windows.Controls.CheckBox) 'DeployUseSaved';$useSaved.Content='使用这台服务器已加密保存的管理凭据';$useSaved.IsChecked=([string](ProfileUIField (ProfileUIField $script:DeployUI.Run 'AccessIssue') 'Kind' '') -notin @('Credentials','PrivateKey','IdentityChanged'));$useSaved.Margin='0,8,0,0';AddC $accessPanel $useSaved}
 $accessExpander=ControlName (New-Object Windows.Controls.Expander) 'DeployAccessAdvanced';$accessExpander.Header='登录账户、密钥与名称';$accessExpander.Content=$accessPanel;$accessExpander.Margin='0,14,0,0';$accessExpander.IsExpanded=($method.SelectedIndex -eq 1);AddC $p $accessExpander
 $method.Add_SelectionChanged({if($script:Controls.ContainsKey('DeployAccessAdvanced') -and $this.SelectedIndex -eq 1){$script:Controls.DeployAccessAdvanced.IsExpanded=$true}})
 $mode=ControlName (New-Object Windows.Controls.ComboBox) 'DeployTransport'
 foreach($option in @(@('自动推荐（默认）','Auto'),@('默认 UDP（手动指定）','Udp'),@('默认 TCP（手动指定）','Tcp'))){$item=New-Object Windows.Controls.ComboBoxItem;$item.Content=$option[0];$item.Tag=$option[1];$null=$mode.Items.Add($item)};$mode.SelectedIndex=0
 AddC $p (Margin (Note '部署始终在同一条线路内准备 UDP 和 TCP。这里的协议选择只设置初始偏好；网络检查与推荐另行显示，未完成性能对比时使用策略默认，不能据此判断最快。') '0,14,0,0')
 AddC $p (Margin (T '默认连接方式：自动推荐。需要指定 UDP / TCP 时可展开高级设置；指定只设置初始偏好。' 13 $script:Text2) '0,8,0,0')
 $advancedPanel=Stack;AddC $advancedPanel (Margin (T '默认连接方式' 12.5 $script:Ink 'SemiBold') '0,12,0,5');AddC $advancedPanel $mode
 $null=DeploymentField $advancedPanel 'TCP 首选端口' 'DeployTcpPort' '443'
 $null=DeploymentField $advancedPanel 'TCP 握手目标' 'DeployServerName' 'www.bing.com'
 $advanced=ControlName (New-Object Windows.Controls.Expander) 'DeploymentAdvanced';$advanced.Header='高级部署设置';$advanced.Content=$advancedPanel;$advanced.Margin='0,14,0,0';AddC $p $advanced
 $draft=ProfileUIField $script:DeployUI 'FormDraft' @{}
 foreach($key in @('DeployConnectionText','DeployName','DeployUser','DeployPort','DeployKeyPath','DeployTcpPort','DeployServerName')){if($draft.ContainsKey($key)){$script:Controls[$key].Text=[string]$draft[$key]}}
 if($draft.ContainsKey('LoginMethod') -and $method.SelectedIndex -ne [int]$draft.LoginMethod){$method.SelectedIndex=[int]$draft.LoginMethod}
 $null=DeploymentActions $p $(if($script:DeployUI.Reauth){'登录并继续原步骤'}else{'提交资料并检查'}) 'ProductDeployInspect' {StartProductDeployment}
 $null=DeploymentActions $p '返回上一页' 'ProductServers' {ReturnNavigationContext $script:DeployUI.DeploymentReturnContext} 'Ghost'
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
 if($script:ReadOnly){ErrorDialog '只读窗口不开始部署准备。';return}
 try{
  if(DispatchUnifiedConnectionMaterial ([string]$script:Controls.DeployConnectionText.Text)){return}
  Import-Module (Join-Path $script:PackageRoot 'DeploymentFlow.psm1') -DisableNameChecking
  $port=0;$tcp=0
  if(-not [int]::TryParse($script:Controls.DeployPort.Text,[ref]$port) -or -not [int]::TryParse($script:Controls.DeployTcpPort.Text,[ref]$tcp)){throw '请填写有效端口。'}
  $keyPath=[string]$script:Controls.DeployKeyPath.Text;if($script:Controls.ContainsKey('DeployLoginMethod') -and $script:Controls.DeployLoginMethod.SelectedIndex -eq 0){$keyPath=''}
  $connection=ConvertTo-TCDeploymentConnection -Text $script:Controls.DeployConnectionText.Text -User $script:Controls.DeployUser.Text -Port $port -IdentityFile $keyPath
  # A newly typed password or a chosen key always wins over the (collapsed,
  # default-on) saved-credential option, so "修改登录资料" really changes it.
  $useSaved=($script:Controls.ContainsKey('DeployUseSaved') -and $script:Controls.DeployUseSaved.IsChecked -and -not $connection.IdentityFile -and $script:Controls.DeployPassword.SecurePassword.Length -eq 0)
  if($useSaved){Import-Module (Join-Path $script:PackageRoot 'DeploymentTransport.psm1') -DisableNameChecking;Import-Module (Join-Path $script:PackageRoot 'ServerRegistry.psm1') -DisableNameChecking;$savedServer=Get-TCServer $script:Root $script:DeployUI.ServerId;$script:DeployUI.Credential=Get-TCDeploySavedCredential -Root $script:Root -CredentialRef $savedServer.CredentialRef}
  elseif($connection.IdentityFile){$pem=[IO.File]::ReadAllText($connection.IdentityFile,[Text.Encoding]::UTF8);$script:DeployUI.Credential=@{Kind='PrivateKey';PrivateKeyPem=(ConvertTo-SecureString $pem -AsPlainText -Force);Passphrase=$script:Controls.DeployPassword.SecurePassword};$pem=$null}
  else{if($script:Controls.ContainsKey('DeployLoginMethod') -and $script:Controls.DeployLoginMethod.SelectedIndex -eq 1){throw '请选择 SSH 私钥文件；服务器密码与私钥口令分别填写。'};if(-not $script:Smoke -and $script:Controls.DeployPassword.SecurePassword.Length -eq 0){throw '请提供服务器登录密码，或选择 SSH 私钥登录。'};$script:DeployUI.Credential=@{Kind='Password';Password=$script:Controls.DeployPassword.SecurePassword}}
  $script:DeployUI.RememberCredential=[bool]$script:Controls.DeployRemember.IsChecked
  $script:DeployUI.CredentialFresh=(-not $useSaved)
  $script:DeployUI.CredentialExpiresAt=[DateTimeOffset]::UtcNow.AddMinutes(30);$script:DeployUI.AutomaticLoginRetries=0;$script:DeployUI.CredentialBinding=$null;$script:DeployUI.ReconnectMessage=''
  if($script:DeployUI.Reauth -and $script:DeployUI.Run){
   $same=$script:Smoke
   if(-not $script:Smoke){Import-Module (Join-Path $script:PackageRoot 'ServerRegistry.psm1') -DisableNameChecking;$prior=(Get-TCServer $script:Root $script:DeployUI.Run.ServerRecordId).Connection;$same=($prior.Host -eq $connection.Host -and [int]$prior.Port -eq $connection.Port -and $prior.User -eq $connection.User)}
   if($same){$script:DeployUI.Reauth=$false;ShowProductDeployment;StartDeploymentSessionUI;return}
   if($script:DeployUI.Run.ClientRequest -or $script:DeployUI.Run.Plan -or $script:DeployUI.Run.DispatchIntent -or $script:DeployUI.Run.CandidateNodeId){throw '原步骤已有部署成果或操作记录，请先核对原结果；不能把原批准套到新目标。'}
   $script:DeployUI.ServerId=$null;$script:DeployUI.Reauth=$false;$script:DeployUI.Run=$null
  }
  $name=[string]$script:Controls.DeployName.Text;if([string]::IsNullOrWhiteSpace($name)){$name='服务器 '+$connection.Host}
  $request=@{Action='DeploymentCreate';Intent=$script:DeployUI.Intent;Connection=$connection;Name=$name;Transport=[string]$script:Controls.DeployTransport.SelectedItem.Tag;TcpPort=$tcp;ServerName=$script:Controls.DeployServerName.Text}
  if($script:DeployUI.Intent -eq 'Existing' -and $script:DeployUI.LegacySeed -and $script:DeployUI.LegacySeed.TemplateNodeId){$request.TemplateNodeId=$script:DeployUI.LegacySeed.TemplateNodeId}
  if($script:DeployUI.ServerId){$request.ServerId=$script:DeployUI.ServerId}
  StartJob $request {param($run)$script:DeployUI.Run=$run;ShowProductDeployment;StartDeploymentSessionUI} '创建可恢复部署记录…'
 }catch{ErrorDialog $_.Exception.Message}
}
function StartDeploymentSessionUI {param([switch]$ReuseCredential)
 try{
  if($script:Smoke){StartJob @{Action='DeploymentSessionFixture';RunId=$script:DeployUI.Run.RunId} {param($s)$script:DeployUI.SessionRef=$s.SessionRef} '测试会话';return}
  Import-Module (Join-Path $script:PackageRoot 'DeploymentTransport.psm1') -DisableNameChecking
  Import-Module (Join-Path $script:PackageRoot 'ServerRegistry.psm1') -DisableNameChecking
  $server=Get-TCServer -Root $script:Root -Id $script:DeployUI.Run.ServerRecordId
  if(-not $script:DeployUI.Credential -or ($ReuseCredential -and -not (TestDeploymentCredentialUI $server))){ClearDeploymentCredentialUI;$script:DeployUI.Reauth=$true;ShowProductDeployment;return}
  if(-not $ReuseCredential){$script:DeployUI.CredentialBinding=DeploymentCredentialScopeUI $server}
  $previous=$script:DeployUI.SessionRef
  $started=Start-TCDeploySession -Root $script:Root -RunId $script:DeployUI.Run.RunId -Connection $server.Connection -Credential $script:DeployUI.Credential -PinnedFingerprint ([string]$server.PinnedHostKey)
  $script:DeployUI.SessionRef=$started.SessionRef;$script:DeployUI.SessionAttached=$false;$script:DeployUI.LastPoll=[DateTime]::MinValue
  if($ReuseCredential -and $previous){try{$null=Stop-TCDeploySession -SessionRef $previous}catch{}}
  $script:DeployUI.LastAccessSignature='';StartJob @{Action='DeploymentAccessState';RunId=$script:DeployUI.Run.RunId;SessionRef=$started.SessionRef;AttemptOnly=$true} {param($run)$script:DeployUI.Run=$run;ShowProductDeployment} '正在连接服务器，原线路保持…'
 }catch{$script:DeployUI.ReconnectMessage='连接未能恢复，原准备进度已保留。';ErrorDialog $_.Exception.Message}
}
function AdvanceDeploymentUI {param([string]$Command='Continue',[int]$InterfaceIndex=0)
 if(IsBusy){return}
 if($script:ReadOnly){ErrorDialog '只读窗口不推进部署。';return}
 if($Command -eq 'Probe' -and (ProfileDeploymentDecision (DeploymentLineView $script:DeployUI.Run) $script:DeployUI.Run).Blocked){ErrorDialog (ProfileDeploymentDecision (DeploymentLineView $script:DeployUI.Run) $script:DeployUI.Run).Message;return}
 if($Command -eq 'UsePrepared'){
  $state=DeploymentCompletenessView $script:DeployUI.Run
  $prepared=@((DeploymentLineView $script:DeployUI.Run).Profiles|Where-Object {ProfileIsPrepared $_})
  if($state.State -ne 'Partial' -or -not $prepared.Count){ErrorDialog '当前没有可确认先使用的部分部署；请先核对准备状态。';return}
 }
 $request=@{Action='DeploymentProceed';RunId=$script:DeployUI.Run.RunId;Command=$Command}
 if($InterfaceIndex -gt 0){if($Command -ne 'Probe'){ErrorDialog '网络选择只能用于本次检查。';return};$request.InterfaceIndex=$InterfaceIndex}
 if($Command -eq 'Approve'){$request.ApprovedChangeDigest=$script:DeployUI.Run.Review.ChangeDigest}
 StartJob $request {param($run)$script:DeployUI.Run=$run;$script:DeployUI.PollError='';ShowProductDeployment} '处理部署阶段；现有线路保持…' -Failed {param($message)$script:DeployUI.PollError=$message;ShowProductDeployment}
}
function DeploymentLocalCheckPending {param($Run)
 $Run -and ([string](ProfileUIField $Run 'Stage' '') -in @('PreparingProbePath','CheckingProfiles') -or [string](ProfileUIField (ProfileUIField $Run 'ProbePreparation') 'State' '') -eq 'Preparing' -or ([string](ProfileUIField $Run 'Stage' '') -eq 'ReadyInactive' -and [string](ProfileUIField $Run 'ProfileProbeState' '') -in @('Pending','Running')))
}
function PollDeploymentRunUI {
 StartJob @{Action='DeploymentPoll';RunId=$script:DeployUI.Run.RunId} {param($run)$script:DeployUI.Run=$run;$script:DeployUI.PollError='';if($script:Role -eq 'deployment'){ShowProductDeployment}} '读取部署与检查进度…' '' -Silent -Failed {param($message)$script:DeployUI.PollError=$message;if($script:Role -eq 'deployment'){ShowProductDeployment}}
}
function PollProductDeployment {
 if($script:Smoke -or ((Get-Date)-$script:DeployUI.LastPoll).TotalSeconds -lt 2){return}
 $script:DeployUI.LastPoll=Get-Date
 if(ProfileUIField $script:DeployUI 'Identity'){PollDeploymentIdentity;return}
 if($script:Job -and $script:Job.Action -in @('DeploymentPoll','DeploymentProceed') -and $script:DeployUI.Run){
  try{
   Import-Module (Join-Path $script:PackageRoot 'DeploymentFlow.psm1') -DisableNameChecking
   $progress=Get-TCDeploymentRun -Root $script:Root -RunId ([string]$script:DeployUI.Run.RunId)
   if($progress.Stage -in @('PreparingProbePath','CheckingProfiles')){$script:DeployUI.Run=$progress;if($script:Role -eq 'deployment'){ShowProductDeployment;$script:HostPanel.IsEnabled=$true}}
  }catch{}
  return
 }
 if(IsBusy){return}
 if($script:DeployUI.ManagementMode -or $script:DeployUI.PendingManagement){PollServerOperation;return}
 if($script:DeployUI.Credential -and $script:DeployUI.CredentialExpiresAt -and [DateTimeOffset]$script:DeployUI.CredentialExpiresAt -le [DateTimeOffset]::UtcNow){ClearDeploymentCredentialUI}
 if($script:DeployUI.Run -and $script:DeployUI.Run.Stage -eq 'ReadyInactive'){ClearDeploymentCredentialUI}
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
   if($script:DeployUI.RememberCredential -and $script:DeployUI.Credential){$saved=Save-TCDeployCredential -Root $script:Root -Credential $script:DeployUI.Credential;$null=Set-TCServerRecord -Root $script:Root -Id $script:DeployUI.Run.ServerRecordId -CredentialRef $saved.CredentialRef;$script:DeployUI.RememberCredential=$false}
   if($poll.ObservedFingerprint){$null=Set-TCServerRecord -Root $script:Root -Id $script:DeployUI.Run.ServerRecordId -PinnedFingerprint $poll.ObservedFingerprint -SessionRef $script:DeployUI.SessionRef}
   if($script:DeployUI.CredentialBinding){$script:DeployUI.CredentialBinding.PinnedFingerprint=[string]$poll.ObservedFingerprint}
   $script:DeployUI.ReconnectMessage=''
   # Retain only in this wizard's memory for a bounded session retry. Completion,
   # changed identity, or closing the interface clears it; it never enters JSON.
   StartJob @{Action='DeploymentAttach';RunId=$script:DeployUI.Run.RunId;SessionRef=$script:DeployUI.SessionRef} {param($run)$script:DeployUI.Run=$run;AdvanceDeploymentUI} '认证完成，开始只读检查…';return
  }
  if(-not $poll.HasSession -and $poll.Status -in @('Failed','OutcomeUnknown') -and $poll.Code -notin @('HostTrustRequired','HostKeyUnknown')){
   $script:DeployUI.SessionAttached=$false
   $diagnostic=Get-TCDeployAccessDiagnostic -Code ([string]$poll.Code)
   if($diagnostic.ClearCredential -or ($poll.Code -eq 'HostKeyChanged' -and -not $script:DeployUI.CredentialFresh)){ClearDeploymentCredentialUI}
   $signature=[string]$script:DeployUI.SessionRef.InstanceId+':'+[string]$poll.Code
   if($script:DeployUI.LastAccessSignature -ne $signature){
    $script:DeployUI.LastAccessSignature=$signature
    StartJob @{Action='DeploymentAccessState';RunId=$script:DeployUI.Run.RunId;SessionRef=$script:DeployUI.SessionRef} {param($run)
     if(-not $script:DeployUI.Run -or $run.RunId -ne $script:DeployUI.Run.RunId){return}
     $script:DeployUI.Run=$run
     if($script:Role -ne 'deployment'){return}
     $d=Get-TCDeployAccessDiagnostic -Code ([string](ProfileUIField (ProfileUIField $run 'AccessIssue') 'Code' ''))
     if($d.RetryWithCredential -and (RetryDeploymentConnectionUI -Automatic)){return}
     $script:DeployUI.ReconnectMessage='';ShowProductDeployment
    } '核对连接状态，保留原准备进度…'
   }
   return
  }
  if($script:DeployUI.Run -and $script:DeployUI.Run.Status -eq 'Running'){PollDeploymentRunUI}
 }catch{$script:DeployUI.PollError='状态读取未完成：'+$_.Exception.Message;$script:Footer.Text=$script:DeployUI.PollError}
}
function ResumeProductDeployment {param([string]$RunId)
 if($script:ReadOnly){ErrorDialog '只读窗口不恢复执行操作。';return}
 $script:DeployUI.DeploymentReturnContext=CaptureNavigationContext
 StartJob @{Action='DeploymentGet';RunId=$RunId} {param($run)
  $script:DeployUI.Run=$run;$script:DeployUI.ServerId=$run.ServerRecordId;$script:DeployUI.SessionRef=$run.SessionRef;$script:DeployUI.SessionAttached=$false;$script:DeployUI.ManagementMode=$false;$script:DeployUI.TrustShown=$null;$script:Role='deployment';$script:Step=1
  if($run.SessionRef -and -not $script:Smoke){try{Import-Module (Join-Path $script:PackageRoot 'DeploymentTransport.psm1') -DisableNameChecking;$state=Get-TCDeploySession -SessionRef $run.SessionRef;if($state.HasSession){$script:DeployUI.SessionAttached=$true}}catch{}}
  $script:DeployUI.PollError='';$script:DeployUI.AutomaticLoginRetries=0
  $script:DeployUI.Reauth=($run.Stage -notin @('ReadyInactive','PreparingProbePath','CheckingProfiles') -and -not $script:DeployUI.SessionAttached)
  # Opening a record only shows it. Logging in again and continuing remote
  # steps needs an explicit click, even when a saved credential exists;
  # bounded automatic reconnects apply only to a drop inside this session.
  StartJob @{Action='DeploymentDiscover'} {param($d)$script:DeployUI.Discovery=$d;ShowProductDeployment} '恢复原服务器与申请引用…'
 } '读取原部署运行，不生成新申请…'
}
function DeploymentStageLabel {param([string]$Stage)
 $labels=@{PrepareAccess='等待服务器登录';Inspect='检查服务器环境';PlanReady='核对变更计划';Apply='部署服务器服务';ServerInfo='核对服务器身份';ManagementPlan='检查管理能力';ManagementApply='准备设备管理';Authorize='授权这台电脑';ServerExit='检查服务器出口';CheckingProfiles='自动检查连接方式';ReadyInactive='准备完成，尚未启用';Reconcile='核对上次操作结果';RequestStatus='核对原设备申请';NeedsRecovery='需要恢复服务器事务'}
 $labels.PreparingProbePath='准备检测路径'
 $labels.MaterializeCandidate='为这台电脑生成连接配置';$labels.MaterializeTcp='保存 TCP 本机连接';$labels.InspectTcp='核对 TCP 准备';$labels.TcpCandidates='自动选择可用 TCP 参数';$labels.TcpPlan='准备双协议配置';$labels.TcpApply='准备 TCP 服务';$labels.TcpParameters='保存本机 TCP 参数';$labels.RecheckUdp='核对已完成的 UDP 成果';$labels.ExistingUdp='复用本机已有授权'
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
 [pscustomobject]@{LineId=(UILineId $Run);Name=$Run.Name;Profiles=$profiles;SavedConnectionPreference=(ProfileUIField $Run 'SavedConnectionPreference');Recommendation=(ProfileUIField $Run 'Recommendation');PreferredProfileId=(ProfileUIField $Run 'PreferredProfileId');PreferenceSource=(ProfileUIField $Run 'PreferenceSource' (ProfileUIField (ProfileUIField $Run 'Recommendation') 'Source'));SourceManifestPath=(ProfileUIField $Run 'CandidateManifestPath')}
}
function DeploymentCompletenessView {param($Run)
 $line=DeploymentLineView $Run;$prepared=@($line.Profiles|Where-Object {ProfileIsPrepared $_}|ForEach-Object {$_.Id})
 $state=[string](ProfileUIField $Run 'DeploymentCompleteness' '')
 $missing=@(ProfileUIField $Run 'MissingProtocols' @()|Where-Object {$_ -in @('Udp','Tcp')})
 if(-not $state -or ($state -in @('Complete','Partial') -and -not $missing.Count)){$missing=@('Udp','Tcp'|Where-Object {$_ -notin $prepared})}
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
 ClearDeploymentCredentialUI;$script:DeployUI.ReconnectMessage=''
 $script:Step=0;$script:Role='client';ShowNodes;FetchNodes
}
function RefreshExpiredProtocolPresentation {
 if(IsBusy){return}
 if(-not $script:Window.IsVisible -or $script:Window.FindName('Overlay').Visibility -eq 'Visible'){return}
 $recommendation=$null;$target=''
 if($script:Page -eq 'setup' -and $script:Role -eq 'deployment' -and $script:DeployUI.Run.Stage -eq 'ReadyInactive'){
  $recommendation=$script:DeployUI.Run.Recommendation;$target='run:'+ $script:DeployUI.Run.RunId
 }elseif($script:Page -eq 'line-profiles' -and $script:LineProfileUI){$recommendation=$script:LineProfileUI.Line.Recommendation;$target='line:'+ $script:LineProfileUI.Id}
 if(-not $recommendation -or $recommendation.Status -ne 'Recommended' -or -not $recommendation.ExpiresAtUtc -or -not (UIExpired $recommendation.ExpiresAtUtc)){return}
 $key=$target+':'+[string]$recommendation.ExpiresAtUtc
 if($script:ProtocolExpiryRefreshKey -ceq $key){return};$script:ProtocolExpiryRefreshKey=$key
 # Presentation only. Do not run a probe, save a setting or perform any network
 # operation when a recommendation's lifetime ends on an already-open page.
 if($script:Page -eq 'line-profiles'){ShowLineConnections}else{ShowProductDeployment}
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
function DeploymentDiagnosticCount {param($Value)
 $number=0;if([int]::TryParse([string]$Value,[ref]$number) -and $number -ge 0){return [string]$number};'未记录'
}
function DeploymentDiagnosticSummary {param($Run)
 $line=DeploymentLineView $Run;$d=ProfileDeploymentDecision $line $Run
 $lines=@('部署检查摘要（已脱敏）','处理原因：'+$d.Code,(DeploymentCompletenessView $Run).Label)
 $prep=ProfileUIField $Run 'ProbePreparation';$state=[string](ProfileUIField $prep 'State' '')
 if($state -in @('Preparing','Ready','Partial','NeedsNetworkSelection','Unsupported','Blocked','Failed')){$lines+='检测准备：'+$state}
 $known=@('CandidateReachabilityVerified','CandidateForwardingFailed','CandidateForwardingUnverified','ForwardingFailed','ForwardingPassedPhysicalPathUnverified','StoredBindingMissing','BindingsRequired','ProbeTimeout','Timeout','DnsFailed','TlsFailed','ProbeCleanupFailed','ProbeIdentityUnknown','NeedsRecovery','ActiveIdentity','ActiveIdentityInUse','IdentityInUse','ExpectedExitUnverified','NetworkChanged','NetworkChangedDuringComparison','ConfigurationChanged','EvidenceExpired','NotTested','HttpsReached','HttpForbidden','BrowserChallenge','AuthenticationRequired','HttpRedirect','HttpError','TimeBudgetExhausted','RequiredSampleFailed','RequiredSamplesIncomplete','Unsupported','NoSupportedPhysicalInterface','AmbiguousPhysicalInterface','IPv6NotSupported','BindingsPrepared','BindingReused','BindingPrepared','BoundInterfaceObserved')
 foreach($profile in $line.Profiles){
  $id=[string](ProfileUIField $profile 'Id' '');if($id -notin @('Udp','Tcp')){continue}
  $v=ProfileValidationView (ProfileUIField $profile 'Validation');$code=if($v.Code -in $known){$v.Code}else{'Other'}
  $binding=@(ProfileUIField $prep 'Results' @()|Where-Object {[string](ProfileUIField $_ 'ProfileId' '') -eq $id})|Select-Object -First 1
  $bindingState=[string](ProfileUIField $binding 'BindingState' '');if($bindingState -notin @('Prepared','Reused','Unsupported','NeedsNetworkSelection','Blocked','Failed')){$bindingState='未记录'}
  $bindingReason=[string](ProfileUIField $binding 'ReasonCode' '');if($bindingReason -notin ($known+@('StoredBindingUnchanged','SavedOuterAndDnsBinding','UdpEtwUnavailable','BindingOnlyBootstrapDnsRemoteUnobservable'))){$bindingReason='Other'}
  $lines+=($id.ToUpperInvariant()+'：'+(ProfilePreparationStatus $profile)+'；检测原因 '+$code+'；路径准备 '+$bindingState+' / '+$bindingReason+'；版本 '+(DeploymentDiagnosticCount (ProfileUIField $binding 'ProfileRevision')))
  $lines+=('必需 HTTPS：通过 '+(DeploymentDiagnosticCount (ProfileUIField $v.Metrics 'Passed'))+' / '+(DeploymentDiagnosticCount (ProfileUIField $v.Metrics 'Planned'))+'；失败 '+(DeploymentDiagnosticCount (ProfileUIField $v.Metrics 'Failed'))+'；超时 '+(DeploymentDiagnosticCount (ProfileUIField $v.Metrics 'TimedOut')))
  $layers=$profile.Validation;for($i=0;$layers -and $i -lt 6;$i++){
   $path=ProfileUIField $layers 'PathEvidence';if([string](ProfileUIField $path 'Kind' '') -in @('BoundInterfaceObserved','PhysicalDirect')){$lines+='路径观测范围：BoundInterfaceObserved（仅本次绑定接口观测）';break};$layers=ProfileUIField $layers 'Result'
  }
  foreach($sample in @($v.Samples|Where-Object {$_})){
   $target=switch([string](ProfileUIField $sample 'Name' '')){'AddressHttps'{'出口地址 HTTPS'}'DomainDnsHttps'{'域名与 HTTPS'}default{'可选应用或其他目标'}}
   $sampleCode=[string](ProfileUIField $sample 'Code' '');if($sampleCode -notin $known){$sampleCode='Other'}
   $lines+=($target+'：'+$sampleCode+'，'+(DeploymentDiagnosticCount (ProfileUIField $sample 'DurationMs'))+' ms，HTTP '+(DeploymentDiagnosticCount (ProfileUIField $sample 'HttpStatus')))
  }
 }
 foreach($rule in @(ProfileUIField $Run 'CloudRuleList' @()|Where-Object {$_})){
  $protocol=[string](ProfileUIField $rule 'Protocol' '');$port=0
  if($protocol -in @('Udp','Tcp') -and [int]::TryParse([string](ProfileUIField $rule 'Port'),[ref]$port) -and $port -gt 0 -and $port -le 65535){$lines+=('本次入站规则：'+$protocol.ToUpperInvariant()+' '+$port)}
 }
 $lines -join [Environment]::NewLine
}
function ShowDeploymentDiagnostics {
 $run=$script:DeployUI.Run;$decision=ProfileDeploymentDecision (DeploymentLineView $run) $run
 OpenDialog $decision.PrimaryLabel ($decision.Message+[Environment]::NewLine+[Environment]::NewLine+(DeploymentDiagnosticSummary $run)) '摘要只包含状态、失败次数与本次端口规则。没有可信云规则读取证据时，不能确定安全组是否有误。' '知道了' $null ''
}
function ShowDeploymentPreparedProfiles {
 $run=$script:DeployUI.Run;$line=DeploymentLineView $run
 $script:LineProfileUI=@{Id=(UILineId $line);Line=$line;Error='';SwitchResult=$null;MaintenanceMode=$false}
 ShowLineConnections
}
function SaveDeploymentForLater {
 if(IsBusy){return}
 $run=$script:DeployUI.Run;$decision=ProfileDeploymentDecision (DeploymentLineView $run) $run
 if($script:ReadOnly -or $decision.Blocked -or [string](ProfileUIField $run 'Stage' '') -ne 'ReadyInactive'){DeploymentLater;return}
 StartJob @{Action='DeploymentProceed';RunId=$run.RunId;Command='Save'} {param($saved)
  $script:DeployUI.Run=$saved;$script:DeployUI.PollError='';DeploymentLater
 } '保存完成；保留当前连接…' -Failed {param($message)$script:DeployUI.PollError='保存完成状态尚未确认，请重试读取状态。';ShowProductDeployment}
}
function InvokeDeploymentDecisionUI {param([string]$Action)
 switch($Action){
  'RetryLogin'{$script:DeployUI.Reauth=$true;ShowProductDeployment;return}
  'RetryConnection'{$null=RetryDeploymentConnectionUI;return}
  'VerifyIdentity'{BeginDeploymentIdentityVerification;return}
  'RetryServer'{if($script:DeployUI.SessionAttached){AdvanceDeploymentUI 'Continue'}else{$null=RetryDeploymentConnectionUI};return}
  'ApprovePreparation'{AdvanceDeploymentUI 'Approve';return}
  'Leave'{DeploymentLater;return}
  'Probe'{AdvanceDeploymentUI 'Probe'}
  'ChooseNetwork'{$script:DeployUI.ChooseNetwork=$true;ShowProductDeployment}
  'Diagnostics'{ShowDeploymentDiagnostics}
  'CompleteRemaining'{AdvanceDeploymentUI 'Recheck'}
  'Recover'{AdvanceDeploymentUI 'Continue'}
  'CheckActive'{ShowHome;RunCheck}
  'Save'{SaveDeploymentForLater}
  'ConnectRecommended'{
   $line=DeploymentLineView $script:DeployUI.Run;$decision=ProfileDeploymentDecision $line $script:DeployUI.Run
   if($decision.Code -eq 'SavedDefaultReady'){PreviewDefaultLineConnection (UILineId $script:DeployUI.Run)}
   elseif($decision.ProfileId -in @('Udp','Tcp')){StartLineConnectionPreview (UILineId $script:DeployUI.Run) $decision.ProfileId}
   else{ErrorDialog '尚无可核对的连接方式，请完成本页必要检查。'}
  }
 }
}
function AddDeploymentDecisionAction {param($Parent,$Action,[bool]$Primary=$false)
 $id=switch([string]$Action.Action){'Probe'{'DeployProbe'}'ChooseNetwork'{'DeployChooseNetwork'}'Diagnostics'{'DeployDiagnostics'}'CompleteRemaining'{'DeployCompleteRemaining'}'Recover'{'DeployReconcile'}'CheckActive'{'DeployCheckActive'}'Save'{'DeployLater'}'ConnectRecommended'{'DeployConnectRecommended'}'RetryLogin'{'DeployRetryLogin'}'RetryConnection'{'DeployRetryConnection'}'VerifyIdentity'{'DeployVerifyIdentity'}'RetryServer'{'DeployRetryServer'}'ApprovePreparation'{'DeployApprove'}'Leave'{'DeployLeave'}}
 if(-not $id){return}
 $style=if($Primary){'Primary'}elseif($Action.Action -eq 'Save'){'Ghost'}else{'Btn'}
 $button=DeploymentActions $Parent $Action.Label $id {InvokeDeploymentDecisionUI ([string]$this.Tag)} $style;$button.Tag=[string]$Action.Action
 if($Action.Action -notin @('Save','Diagnostics')){$button.IsEnabled=(-not $script:ReadOnly -and -not (IsBusy))}
}
function AddDeploymentNetworkSelection {param($Parent,$Run)
 $decision=ProfileDeploymentDecision (DeploymentLineView $Run) $Run
 AddC $Parent (Margin (T '选择本次检测使用的网络' 17 $script:Ink 'SemiBold') '0,14,0,6')
 AddC $Parent (T '按网卡名称、连接类型和当前地址选择。选择只写入候选检测计划，不启用、禁用或修改网卡；当前连接保持。' 13 $script:Text2)
 $box=ControlName (New-Object Windows.Controls.ComboBox) 'DeployProbeNetwork';$box.MinHeight=38;$box.Margin='0,14,0,0';$box.IsEditable=$true;$box.IsReadOnly=$true;$box.Text='请选择检测网络…'
 $choices=@();foreach($result in @(ProfileUIField (ProfileUIField $Run 'ProbePreparation') 'Results' @())){$choices+=@(ProfileUIField $result 'Interfaces' @()|Where-Object {$_})}
 $seen=@{};foreach($choice in $choices){
  $index=0;if(-not [int]::TryParse([string](ProfileUIField $choice 'Index'),[ref]$index) -or $index -lt 1 -or $seen.ContainsKey($index)){continue};$seen[$index]=$true
  $item=New-Object Windows.Controls.ComboBoxItem;$item.Tag=$index;$item.Content=([string](ProfileUIField $choice 'Name' '网络')+' · '+[string](ProfileUIField $choice 'Type' '类型待核对')+' · '+[string](ProfileUIField $choice 'LocalAddress' '地址待核对'));$null=$box.Items.Add($item)
 }
 $box.SelectedIndex=-1;AddC $Parent $box
 if(-not $box.Items.Count){AddC $Parent (Margin (T '尚无可选择的受支持网络。可查看检测限制，或保存配置稍后检查。' 13 '#A15C07') '0,8,0,0')}
 $button=DeploymentActions $Parent '使用所选网络并重新检查' 'DeployProbeSelectedNetwork' {
  $item=$script:Controls.DeployProbeNetwork.SelectedItem;if(-not $item){ErrorDialog '请先选择本次检测使用的网络。';return}
  $script:DeployUI.ChooseNetwork=$false;AdvanceDeploymentUI -Command 'Probe' -InterfaceIndex ([int]$item.Tag)
 };$button.IsEnabled=$false
 $box.Add_SelectionChanged({param($sender,$event)$button=$script:Controls.DeployProbeSelectedNetwork;if($button){$button.IsEnabled=($null -ne $sender.SelectedItem -and -not $script:ReadOnly)}})
 $null=DeploymentActions $Parent '返回完成页' 'DeployNetworkBack' {$script:DeployUI.ChooseNetwork=$false;ShowProductDeployment} 'Ghost'
 $null=DeploymentActions $Parent '保存配置，稍后使用' 'DeployLater' {SaveDeploymentForLater} 'Ghost'
}
function ShowDeploymentRun {
 $run=$script:DeployUI.Run;$card=Card;$p=Stack;$card.Child=$p
 $checking=DeploymentLocalCheckPending $run;$local=($run.Stage -in @('PreparingProbePath','CheckingProfiles','ReadyInactive'));$line=DeploymentLineView $run
 $decision=ProfileDeploymentDecision $line $run
 if($script:DeployUI.ReconnectMessage){AddC $p (ControlName (Note $script:DeployUI.ReconnectMessage) 'DeployReconnectStatus')}
 $completeness=DeploymentCompletenessView $run;$outcome=($local -or $completeness.State -eq 'NeedsRecovery')
 if(ProfileUIField $run 'AccessIssue'){
  $issue=ProfileUIField $run 'AccessIssue'
  SetupCardHeader $p ([string]$run.Name) ('中断步骤：'+(DeploymentStageLabel ([string]$issue.ResumeStage))+'；当前线路保持。') 'server'
  AddC $p (ControlName (T $decision.Title 19 $script:Ink 'SemiBold') 'DeployAccessTitle');AddC $p (Margin (T $decision.Message 13 $script:Text2) '0,8,0,0')
  if($completeness.PreparedProtocols.Count){AddC $p (Margin (ControlName (T ('本机已保存配置：'+($completeness.PreparedProtocols.ToUpperInvariant() -join ' / ')) 13 $script:Ink 'SemiBold') 'DeployResumeProgress') '0,8,0,0')}
  $bar=New-Object Windows.Controls.WrapPanel;AddDeploymentDecisionAction $bar ([pscustomobject]@{Action=$decision.PrimaryAction;Label=$decision.PrimaryLabel}) $true
  foreach($action in $decision.SecondaryActions){AddDeploymentDecisionAction $bar $action};AddC $p $bar
  $null=ManagementDetails $p ('诊断：'+[string]$issue.Code+'；从 '+(DeploymentStageLabel ([string]$issue.ResumeStage))+' 继续。') '接入详情'
  AddC $script:HostPanel $card;return
 }
 $subtitle=if($outcome){$completeness.Label}else{(DeploymentStageLabel $run.Stage)+' · '+(DeploymentStatusLabel $run.Status)}
 SetupCardHeader $p ([string]$run.Name) $subtitle 'server'
 if($local -and (ProfileUIField $script:DeployUI 'ChooseNetwork' $false) -and $decision.PrimaryAction -eq 'ChooseNetwork'){
  AddDeploymentNetworkSelection $p $run;AddC $script:HostPanel $card;return
 }
 if($outcome){
  AddC $p (ControlName (T $decision.Title 19 $script:Ink 'SemiBold') 'DeployOutcomeTitle')
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
  $progress=if($decision.Code -eq 'PreparingProbePath'){'检查已准备配置 → 准备检测路径'}else{'自动检查连接方式'}
  $probeProgress=ProfileUIField $run 'ProbeProgress'
  $current=[string](ProfileUIField $probeProgress 'ProfileId' (ProfileUIField $run 'CheckingProfileId' ''));$round=ProfileUIField $probeProgress 'Round' (ProfileUIField $run 'CheckingRound' (ProfileUIField $run 'ProbeRound'))
  if($current -in @('Udp','Tcp')){$progress='检查 '+(UIProfileName $current);if($round -in @(1,2,3)){$progress+=' '+$round+'/3'}}
  AddC $p (Margin (ControlName (T ('网络检查：'+$progress+'；随后汇总默认建议。') 14 $script:Ink 'SemiBold') 'DeployCheckProgress') '0,10,0,0')
  AddC $p (Margin (T '检查按顺序运行，当前连接保持。准备状态与网络结果分别记录。' 13 $script:Text2) '0,6,0,0')
 }
 elseif($run.Stage -eq 'ReadyInactive'){
  if(NodeHasActiveProfile $line){AddC $p (Margin (ControlName (T (ActiveLineStatus $line) 15 $script:Ink 'SemiBold') 'DeployActiveStatus') '0,10,0,0')}
  $r=LineRecommendationView $line
  AddC $p (Margin (ControlName (T $r.Label 17 $script:Ink 'SemiBold') 'DeployDefaultLabel') '0,10,0,0')
  AddC $p (Margin (ControlName (T ($r.Basis+'。'+$r.Reason) 13 $script:Text2) 'DeployRecommendationReason') '0,6,0,0')
  if([string](ProfileUIField $run 'ProfileProbeState' '') -eq 'Interrupted'){AddC $p (Margin (T '上次检查已中断，已准备资料保留；请重试检查。' 13 '#A15C07') '0,6,0,0')}
  if($r.ProfileId){$selected=@($line.Profiles|Where-Object Id -eq $r.ProfileId)|Select-Object -First 1;AddC $p (Margin (ControlName (T ((UIProfileName $r.ProfileId)+' 检查汇总：'+(ConnectionProfileStatus $selected)) 13 $script:Text2) 'DeployValidationSummary') '0,6,0,0')}
  AddC $p (Margin (ControlName (T $decision.Message 13 $script:Text2) 'DeployDecisionMessage') '0,8,0,0')
 }
 else{AddC $p (Note 'UDP / TCP 准备状态与网络检查单独显示，备齐后再确定初始连接方式。')}
 if($local){
  $activation=if(NodeHasActiveProfile $line){ActiveLineStatus $line}elseif(IsRunning){'尚未启用；当前 '+[string](ProfileUIField $script:Overview 'NodeName' '线路')+'继续使用'}elseif([string](ProfileUIField $script:Overview 'StateKey' '') -eq 'Fault'){'尚未启用；当前连接状态待核对'}else{'尚未启用；当前连接保持原状态'}
  AddC $p (Margin (ControlName (T $activation 14 $script:Ink 'SemiBold') 'DeployActivationStatus') '0,10,0,0')
 }
 AddDeploymentProtocolResults $p $run
 if($run.LastError -and -not $local){AddC $p (Margin (T ([string]$run.LastError.Message) 13 '#B42318') '0,10,0,0')}
 if(ProfileUIField $script:DeployUI 'PollError'){AddC $p (Margin (Notice 'warn' '状态读取未完成' $script:DeployUI.PollError) '0,10,0,0');$null=DeploymentActions $p '重试读取状态' 'DeployRetryStatus' {PollDeploymentRunUI} 'Btn'}
 $actions=New-Object Windows.Controls.WrapPanel
 if($completeness.State -eq 'NeedsRecovery'){
  AddDeploymentDecisionAction $actions ([pscustomobject]@{Action=$decision.PrimaryAction;Label=$decision.PrimaryLabel}) $true
  foreach($action in $decision.SecondaryActions){AddDeploymentDecisionAction $actions $action}
 }
 elseif($checking){
  $null=DeploymentActions $actions '停止本次检查' 'DeployStopCheck' {StopDeploymentLocalCheck} 'Btn'
  $null=DeploymentActions $actions '稍后使用' 'DeployLater' {DeploymentLater} 'Ghost'
 }
 elseif($run.Stage -eq 'ReadyInactive'){
  AddDeploymentDecisionAction $actions ([pscustomobject]@{Action=$decision.PrimaryAction;Label=$decision.PrimaryLabel}) $true
  foreach($action in $decision.SecondaryActions){if($action.Action -eq 'ConnectRecommended' -and (NodeHasActiveProfile $line)){continue};AddDeploymentDecisionAction $actions $action}
  if($completeness.State -eq 'Partial' -and -not $decision.Blocked -and (ProfileUIField $run 'PartialUseAccepted' $false) -ne $true -and $completeness.PreparedProtocols.Count){$null=DeploymentActions $actions '确认先保存已准备方式' 'DeployUsePrepared' {AdvanceDeploymentUI 'UsePrepared'} 'Btn'}
  if($decision.CanManualTry -and (UILineId $line)){$null=DeploymentActions $actions '查看已准备连接方式 / 手动试用…' 'DeployPreparedProfiles' {ShowDeploymentPreparedProfiles} 'Ghost'}
  if(NodeHasActiveProfile $line){$null=DeploymentActions $actions '继续使用当前连接' 'DeployContinueCurrent' {ShowHome;RefreshOverview -Silent} 'Btn'}
 }
 elseif($run.Stage -eq 'PlanReady' -and $run.Review){
  AddC $p (Margin (T '确认准备这条线路' 17 $script:Ink 'SemiBold') '0,14,0,4')
  $target=ProfileUIField (ProfileUIField $run.Review 'TargetIdentity') 'Connection';if($target){AddC $p (T ('目标：'+[string]$target.Host+' · '+[string]$target.User+':'+[string]$target.Port) 13 $script:Text2)}
  AddC $p (T '将在目标服务器准备 UDP / TCP，为这台电脑授权并保存配置；现有服务器设备和当前电脑线路保留。' 13 $script:Text2)
  $null=ManagementDetails $p $run.Review.Details '完整准备范围'
  if($run.Plan){AddC $p (Margin (T ('云端入口：'+$run.Plan.PublicEndpoint+'；UDP '+$run.VpnPort+' / TCP '+$run.TcpPort+'。保留 SSH 管理端口。') 13 $script:Text2) '0,12,0,0')}
  $null=DeploymentActions $actions '开始准备这条线路' 'DeployApprove' {AdvanceDeploymentUI 'Approve'}
  $null=DeploymentActions $actions '稍后继续' 'DeployLeave' {DeploymentLater} 'Ghost'
 }
 elseif($run.Status -in @('Failed','OutcomeUnknown','NeedsRecovery','Cancelled')){
  $null=DeploymentActions $actions '重新核对原操作结果' 'DeployReconcile' {AdvanceDeploymentUI 'Continue'} 'Btn'
  AddC $p (Margin (T '保留原申请与部署记录，从原操作继续核对。' 12 $script:Text3) '0,10,0,0')
 }
 else{
  $description=if($run.Status -in @('Running','Dispatching')){'正在'+(DeploymentStageLabel $run.Stage)+'，进度自动保存。'}elseif($run.Stage -eq 'PrepareAccess'){'正在核对服务器登录；需要操作时会在本页显示。'}else{'等待本步骤的结果或必要操作，已完成进度保留。'}
  AddC $p (Margin (T $description 13 $script:Text2) '0,14,0,0')
 }
 AddC $p $actions
 if($outcome){
  $details=Stack;$summary=DeploymentDiagnosticSummary $run
  $copy=Btn '复制脱敏诊断摘要' 'DeployCopyDiagnostics' {[Windows.Clipboard]::SetText([string]$this.Tag);Toast '脱敏诊断摘要已复制'} 'Btn';$copy.Tag=$summary;AddC $details $copy
  AddLineRecommendationEvidence $details $line 'Deploy'
  foreach($profile in $line.Profiles){AddProfileCheckDetails $details $profile 'Deploy'}
  AddC $details (Margin (ControlName (T $summary 12 $script:Text3) 'DeployDiagnosticSummary') '0,10,0,0')
  $exp=ControlName (New-Object Windows.Controls.Expander) 'DeployTechnicalDetails';$exp.Header='技术详情与本次端口规则';$exp.Content=$details;$exp.Margin='0,18,0,0';AddC $p $exp
 }
 # Network checks and ordinary connection failures never imply expired SSH.
 $authCode=[string](ProfileUIField (ProfileUIField $run 'LastError') 'Code' '')
 if(-not $local -and -not (ProfileUIField $run 'AccessIssue') -and -not $script:DeployUI.SessionAttached -and ($run.Stage -eq 'PrepareAccess' -or $authCode -match 'Auth|SessionExpired|HostTrust|HostKey')){
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
  $null=DeploymentActions $details '返回上一页' 'DeployManageServers' {ReturnNavigationContext $script:DeployUI.DeploymentReturnContext} 'Ghost'
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
  if($profile){
   $metrics=(ProfileValidationView (ProfileUIField $profile 'Validation')).Metrics
   if($metrics){KeyValue $Parent '本轮必需 HTTPS' ('通过 '+(DeploymentDiagnosticCount (ProfileUIField $metrics 'Passed'))+' / '+(DeploymentDiagnosticCount (ProfileUIField $metrics 'Planned'))+'；超时 '+(DeploymentDiagnosticCount (ProfileUIField $metrics 'TimedOut'))+' 次') $script:Text3 ('DeployRequests'+$id)}
  }
  $error=ProfileUIField $prep 'Error'
  if($error){AddC $Parent (Margin (T ([string](ProfileUIField $error 'Message' '该阶段未完成，请核对服务器或云规则。')) 12 '#A15C07') '0,3,0,5')}
 }
}
