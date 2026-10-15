# Inline host trust and application identity assessment. This flow never
# changes a local connection; remote actions are the backend's readonly evidence.
function BeginDeploymentIdentityVerification {param([string]$ServerId)
 if($script:ReadOnly -or (IsBusy)){return}
 $id=if($ServerId){$ServerId}else{[string]$script:DeployUI.Run.ServerRecordId}
 if(-not $id){ErrorDialog '请选择这次准备的目标服务器。';return}
 $script:DeployUI.Identity=@{Stage='Credentials';ServerId=$id;OriginalRun=$script:DeployUI.Run;Name=$(if($script:DeployUI.Run){$script:DeployUI.Run.Name}else{'服务器线路'});SessionRef=$null;VerificationToken='';Preview=$null;ApprovalToken='';Assessment=$null;Credential=$null;CredentialExpiresAt=$null;Error='';LastPoll=[DateTime]::MinValue;Completed=$false}
 $script:DeployUI.ManagementMode=$false;$script:DeployUI.Reauth=$false;$script:Role='deployment';$script:DeployUI.Screen='identity'
 if(-not $script:Smoke -and $script:DeployUI.SessionRef -and $script:DeployUI.Credential -and $script:DeployUI.CredentialFresh){
  try{
   Import-Module (Join-Path $script:PackageRoot 'ServerRegistry.psm1') -DisableNameChecking
   $start=Start-TCServerIdentityVerification -Root $script:Root -ServerId $id -SessionRef $script:DeployUI.SessionRef
   $s=$script:DeployUI.Identity;$s.Credential=$script:DeployUI.Credential;$s.CredentialExpiresAt=$script:DeployUI.CredentialExpiresAt;$s.SessionRef=$start.SessionRef;$s.VerificationToken=$start.VerificationToken;$s.Stage='Observing'
  }catch{$script:DeployUI.Identity.Error='需要为此次目标重新提供凭据，原进度保持。'}
 }
 ShowProductDeployment
}
function ShowDeploymentIdentity {
 $s=$script:DeployUI.Identity;$card=Card;$p=Stack;$card.Child=$p
 SetupCardHeader $p '在这里核对服务器，随后继续准备' '登录身份与隧道环境分别检查，当前电脑线路保持。' 'server'
 AddC $p (T ('目标：'+[string]$s.Name) 14 $script:Ink 'SemiBold')
 if($s.Error){AddC $p (Margin (Note $s.Error 'amber') '0,10,0,0')}
 switch([string]$s.Stage){
  'Credentials'{
   AddC $p (Margin (T '请输入此次服务器的最新登录凭据。密码登录时私钥路径留空。' 13 $script:Text2) '0,12,0,0')
   $null=DeploymentField $p 'SSH 私钥文件（密码登录留空）' 'IdentityKeyPath' ''
   AddC $p (Margin (T '服务器密码；使用私钥时填写解密口令' 12.5 $script:Ink 'SemiBold') '0,12,0,5')
   $box=ControlName (New-Object Windows.Controls.PasswordBox) 'IdentityPassword';$box.MinHeight=36;AddC $p $box
   $null=DeploymentActions $p '登录并核对身份' 'IdentityStart' {StartDeploymentIdentityUI}
  }
  'AwaitingTrust'{
   $preview=$s.Preview
   AddC $p (Margin (T '请与云控制台等可信来源核对下面的新指纹。' 13 $script:Text2) '0,12,0,0')
   KeyValue $p '服务器' ([string]$preview.Connection.Host+':'+[string]$preview.Connection.Port)
   KeyValue $p '算法' ([string]$preview.HostKeyAlgorithm)
   KeyValue $p '原指纹' ([string]$preview.PreviousFingerprint);KeyValue $p '本次指纹' ([string]$preview.NewFingerprint)
   $help=New-Object Windows.Controls.Expander;$help.Header='如何从云控制台核对指纹';$help.Margin='0,14,0,0'
   $algorithm=[string]$preview.HostKeyAlgorithm
   $leaf=if($algorithm -match 'ed25519'){'ssh_host_ed25519_key.pub'}elseif($algorithm -match 'ecdsa'){'ssh_host_ecdsa_key.pub'}elseif($algorithm -match 'rsa'){'ssh_host_rsa_key.pub'}else{''}
   $instruction='打开服务器厂商的控制台终端，查看该服务器的 SSH 主机公钥指纹，再与本页比较。'
   if($leaf){$instruction+=[Environment]::NewLine+'只读命令：ssh-keygen -lf /etc/ssh/'+$leaf+' -E sha256'}
   $help.Content=T $instruction 12 $script:Text2;AddC $p $help
   $null=DeploymentActions $p '已核对，继续检查服务器环境' 'IdentityTrust' {ApproveDeploymentIdentityUI}
  }
  'Assessed'{
   $assessment=$s.Assessment
   if(-not $assessment.CanCommit){AddC $p (Margin (Note '实际环境尚不能安全确认，已保留原记录。请查看原因后处理。' 'amber') '0,12,0,0');$null=ManagementDetails $p ([string]$assessment.ReasonCode) '核验原因';$null=DeploymentActions $p '重新核对此服务器' 'IdentityRetry' {$script:DeployUI.Identity.Stage='Credentials';ShowProductDeployment}}
   else{
    $text=switch([string]$assessment.Classification){'ApplicationReset'{'原隧道环境已重置。将归档原身份，为新环境准备独立授权与连接。'}'UndeployedTarget'{'这台服务器尚未完成隧道部署，将按已核验的目标继续准备。'}'FreshTarget'{'这台服务器尚未完成隧道部署，将按已核验的目标继续准备。'}'HostKeyUpdate'{'SSH 主机密钥已更新，隧道身份一致；保留已有设备与线路。'}default{'SSH 与隧道身份一致，继续使用已有环境和授权检查点。'}}
    AddC $p (Margin (T $text 14 $script:Ink 'SemiBold') '0,14,0,0')
    AddC $p (Margin (T '此处只登记核验结果，服务器安装仍由后续的准备范围确认控制；当前电脑连接保持。' 13 $script:Text2) '0,8,0,0')
    $null=DeploymentActions $p '按核验结果继续准备' 'IdentityCommit' {ConfirmDeploymentIdentityUI}
   }
  }
  default{AddC $p (Margin (T '正在核对登录与实际服务器环境，结果会保留在这一步。' 13 $script:Text2) '0,14,0,0')}
 }
 $null=DeploymentActions $p '稍后继续，保留当前连接' 'IdentityLater' {PauseDeploymentIdentityUI} 'Ghost'
 AddC $script:HostPanel $card
}
function StartDeploymentIdentityUI {
 if($script:ReadOnly -or (IsBusy)){return}
 $s=$script:DeployUI.Identity
 try{
  $key=[string]$script:Controls.IdentityKeyPath.Text;$password=$script:Controls.IdentityPassword.SecurePassword
  if($key){if(-not [IO.File]::Exists($key) -or (Get-Item -LiteralPath $key).Length -gt 1MB){throw 'SSH 私钥文件不存在或超过大小限制。'};$pem=[IO.File]::ReadAllText($key);$credential=@{Kind='PrivateKey';PrivateKeyPem=(ConvertTo-SecureString $pem -AsPlainText -Force);Passphrase=$password};$pem=$null}
  else{if(-not $script:Smoke -and $password.Length -eq 0){throw '请提供此次服务器的最新密码。'};$credential=@{Kind='Password';Password=$password}}
  $s.Credential=$credential;$s.CredentialExpiresAt=[DateTimeOffset]::UtcNow.AddMinutes(30);$s.Error='';$s.Stage='Observing'
  if($script:Smoke){StartJob @{Action='IdentitySessionFixture';ServerId=$s.ServerId} {param($data)$script:DeployUI.Identity.SessionRef=$data.SessionRef;$script:DeployUI.Identity.VerificationToken=$data.VerificationToken} '隔离身份会话';ShowProductDeployment;return}
  Import-Module (Join-Path $script:PackageRoot 'ServerRegistry.psm1') -DisableNameChecking
  $start=Start-TCServerIdentityVerification -Root $script:Root -ServerId $s.ServerId -Credential $credential
  $s.SessionRef=$start.SessionRef;$s.VerificationToken=$start.VerificationToken;$s.LastPoll=[DateTime]::MinValue
  ShowProductDeployment
 }catch{$s.Credential=$null;$s.Stage='Credentials';$s.Error=$_.Exception.Message;ShowProductDeployment}
}
function PollDeploymentIdentity {
 $s=$script:DeployUI.Identity;if(-not $s -or $script:Smoke -or (IsBusy)){return}
 if($s.Credential -and $s.CredentialExpiresAt -and [DateTimeOffset]$s.CredentialExpiresAt -le [DateTimeOffset]::UtcNow){$s.Credential=$null}
 if($s.Stage -notin @('Observing','Authenticating')){return}
 if(((Get-Date)-$s.LastPoll).TotalSeconds -lt 2){return};$s.LastPoll=Get-Date
 try{
  Import-Module (Join-Path $script:PackageRoot 'DeploymentTransport.psm1') -DisableNameChecking
  $poll=Get-TCDeploySession -SessionRef $s.SessionRef
  if($poll.Status -eq 'Connecting' -or $poll.Code -eq 'ExecutorBusy'){return}
  if($s.Stage -eq 'Observing'){
   if($poll.HasSession){RequestDeploymentIdentityAssessment;return}
   if($poll.Code -in @('HostKeyChanged','HostTrustRequired')){
    $s.Stage='ReadingTrust'
    StartJob @{Action='ServerIdentityTrustPreview';ServerId=$s.ServerId;SessionRef=$s.SessionRef;VerificationToken=$s.VerificationToken} {param($data)$s=$script:DeployUI.Identity;$s.Preview=$data;$s.Stage='AwaitingTrust';ShowProductDeployment} '读取本次实际 SSH 身份…' -Failed {param($message)$s=$script:DeployUI.Identity;$s.Error=$message;$s.Stage='Credentials';ShowProductDeployment}
    return
   }
  }elseif($poll.HasSession){RequestDeploymentIdentityAssessment;return}
  $s.Error='这次身份登录未完成，请核对最新凭据与服务器入口。';$s.Credential=$null;$s.Stage='Credentials';ShowProductDeployment
 }catch{$s.Error='身份核对暂未完成，请保留资料后重试。';$s.Stage='Credentials';ShowProductDeployment}
}
function ApproveDeploymentIdentityUI {
 if($script:ReadOnly -or (IsBusy)){return}
 $s=$script:DeployUI.Identity;$preview=$s.Preview
 try{
  if($script:Smoke){$s.ApprovalToken='fixture-approved';$s.Stage='Authenticating';StartJob @{Action='IdentityTrustFixture';ServerId=$s.ServerId;Fingerprint=$preview.NewFingerprint} {} '隔离身份确认';ShowProductDeployment;return}
  Import-Module (Join-Path $script:PackageRoot 'ServerRegistry.psm1') -DisableNameChecking
  $approved=Approve-TCServerIdentityFingerprint -Root $script:Root -ServerId $s.ServerId -SessionRef $s.SessionRef -PreviewToken $preview.PreviewToken -ConfirmedFingerprint $preview.NewFingerprint -Credential $s.Credential
  $s.ApprovalToken=$approved.ApprovalToken;$s.Stage='Authenticating';ShowProductDeployment
 }catch{$s.Error=$_.Exception.Message;$s.Stage='Credentials';ShowProductDeployment}
}
function RequestDeploymentIdentityAssessment {
 $s=$script:DeployUI.Identity;$s.Stage='Assessing'
 $request=@{Action='ServerIdentityAssessment';ServerId=$s.ServerId;SessionRef=$s.SessionRef}
 if($s.ApprovalToken){$request.ApprovalToken=$s.ApprovalToken}else{$request.VerificationToken=$s.VerificationToken}
 StartJob $request {param($data)$s=$script:DeployUI.Identity;$s.Assessment=$data;$s.Stage='Assessed';ShowProductDeployment} '只读核对实际隧道环境…' -Failed {param($message)$s=$script:DeployUI.Identity;$s.Error=$message;$s.Stage='Credentials';ShowProductDeployment}
}
function ConfirmDeploymentIdentityUI {
 if($script:ReadOnly -or (IsBusy)){return}
 $s=$script:DeployUI.Identity;$assessment=$s.Assessment;if(-not $assessment.CanCommit){return}
 $s.Stage='Committing'
 StartJob @{Action='ServerIdentityTransition';ServerId=$s.ServerId;SessionRef=$s.SessionRef;AssessmentToken=$assessment.AssessmentToken;ConfirmedFingerprint=$assessment.NewFingerprint;ApprovedChangeDigest=$assessment.ChangeDigest;DeclaredApplicationReset=[bool]$assessment.RequiresResetDeclaration} {param($data)
  $s=$script:DeployUI.Identity;$credential=$s.Credential;$name=$s.Name
  if($s.CredentialExpiresAt -and [DateTimeOffset]$s.CredentialExpiresAt -le [DateTimeOffset]::UtcNow){$credential=$null}
  if($data.Classification -eq 'Unchanged' -and $s.OriginalRun){
   $script:DeployUI.Run=$s.OriginalRun;$script:DeployUI.Identity=$null;$script:DeployUI.Credential=$credential;$script:DeployUI.CredentialExpiresAt=[DateTimeOffset]::UtcNow.AddMinutes(30);$script:DeployUI.Screen='connect';$script:DeployUI.ManagementMode=$false;$script:DeployUI.SessionAttached=$false
   if(-not $script:Smoke -and $s.SessionRef){try{Import-Module (Join-Path $script:PackageRoot 'DeploymentTransport.psm1') -DisableNameChecking;$null=Stop-TCDeploySession -SessionRef $s.SessionRef}catch{}}
   ShowProductDeployment;StartDeploymentSessionUI;return
  }
  $script:DeployUI.Identity=$null;$script:DeployUI.ServerId=$data.Server.LocalRecordId;$script:DeployUI.Server=$data.Server;$script:DeployUI.Run=$null;$script:DeployUI.SessionAttached=$false;$script:DeployUI.ManagementMode=$false;$script:DeployUI.Reauth=$false;$script:DeployUI.Screen='connect';$script:DeployUI.FormDraft=@{};$script:DeployUI.Credential=$credential;$script:DeployUI.CredentialExpiresAt=[DateTimeOffset]::UtcNow.AddMinutes(30)
  $script:DeployUI.CenterLoaded=$false;$script:DeployUI.Role='deployment';$script:Role='deployment'
  $request=@{Action='DeploymentCreate';Intent='Auto';ServerId=$data.Server.LocalRecordId;Name=$name;Transport='Auto';TcpPort=443;ServerName='www.bing.com'}
  if($data.Classification -eq 'HostKeyUpdate' -and $s.OriginalRun -and $s.OriginalRun.ClientRequest -and -not $s.OriginalRun.CandidateNodeId){
   $request.ReuseSourceRunId=$s.OriginalRun.RunId;$request.IdentitySessionRef=$s.SessionRef;$request.IdentityTargetToken=$data.TargetToken
  }
  $script:DeployUI.IdentitySessionToClose=$s.SessionRef
  $script:DeployUI.IdentityResume=$s
  StartJob $request {param($run)
   $ref=$script:DeployUI.IdentitySessionToClose;$script:DeployUI.IdentitySessionToClose=$null
   if(-not $script:Smoke -and $ref){try{Import-Module (Join-Path $script:PackageRoot 'DeploymentTransport.psm1') -DisableNameChecking;$null=Stop-TCDeploySession -SessionRef $ref}catch{}}
   $script:DeployUI.IdentityResume=$null;$script:DeployUI.Run=$run;ShowProductDeployment;StartDeploymentSessionUI
  } '接回已核验身份的部署准备…' -Failed {param($message)
   $saved=$script:DeployUI.IdentityResume;$script:DeployUI.IdentityResume=$null
   if($saved){$saved.Error=$message;$saved.Stage='Assessed';$script:DeployUI.Identity=$saved;$script:DeployUI.Run=$saved.OriginalRun;$script:DeployUI.Screen='identity';ShowProductDeployment}else{ErrorDialog $message}
  }
 } '保存核验结果并继续原向导…' -Failed {param($message)$s=$script:DeployUI.Identity;$s.Error=$message;$s.Stage='Assessed';ShowProductDeployment}
}
function PauseDeploymentIdentityUI {
 $s=$script:DeployUI.Identity;if($s){
  $s.Credential=$null
  if(-not $script:Smoke -and $s.SessionRef){
   try{Import-Module (Join-Path $script:PackageRoot 'DeploymentTransport.psm1') -DisableNameChecking;$null=Stop-TCDeploySession -SessionRef $s.SessionRef}catch{}
   if($script:DeployUI.SessionRef -and $script:DeployUI.SessionRef.InstanceId -ceq $s.SessionRef.InstanceId){$script:DeployUI.SessionRef=$null;$script:DeployUI.SessionAttached=$false}
  }
 }
 $script:DeployUI.Credential=$null
 if($script:DeployUI.PasswordControl){$script:DeployUI.PasswordControl.Clear()}
 $script:DeployUI.Identity=$null;$script:DeployUI.CenterLoaded=$false;ShowSetupCenter
}
