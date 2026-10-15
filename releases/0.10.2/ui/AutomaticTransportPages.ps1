# Automatic transport prepares a separate candidate. It never applies a local
# Session/selector change. Server secrets stay in the authenticated management
# channel and restricted Worker files, never displayed as beginner inputs.
$script:AutoTCP=$null
function OfferConnectionRecovery {param([string]$Message,[string]$Id)
 if($Id -and $Message -match 'LineForwardingUnverified|外网|转发|节点启用失败|候选会话'){
  $script:RecoveryContext=@{Id=$Id;Message=$Message}
  OpenDialog '线路转发尚未通过检查' $Message '下一步先检查实际出口和服务器授权。需要时自动准备 TCP 备用；不会因为失败而静默切换协议。' '检查并给出下一步' {ShowConnectionRecovery $script:RecoveryContext.Id $script:RecoveryContext.Message} '稍后处理'
 }else{ErrorDialog $Message}
}
function OpenAutomaticTransport {param([string]$Id)
 if(IsBusy){return}
 StartJob @{Action='AutoTransportContext';Id=$Id} {param($d)
  $script:AutoTCP=@{Id=[string]$d.Id;Context=$d;Stage='Access';Result=$null;Error='';User=[string](ServerUIGet $d.Connection User 'root');Port=[string](ServerUIGet $d.Connection Port 22)}
  $script:Role='automatic-tcp'
  if($d.HasSettings -and -not $d.NeedsAuthentication){PrepareAutomaticTransportSaved}else{ShowAutomaticTransport}
 } '读取这条线路与对应服务器；当前连接保持…'
}
function ShowAutomaticTransport {
 if(-not $script:AutoTCP){ShowNodes;return}
 $a=$script:AutoTCP;$context=$a.Context
 PageHead '自动准备 TCP 备用' '软件负责读取或部署服务器参数，再生成本机备用线路。当前连接保持。' 'automatic-tcp'
 $card=Card '24,20';$p=Stack;$card.Child=$p
 AddC $p (T ([string]$context.Name) 17 $script:Ink 'SemiBold')
 AddC $p (Margin (T ('服务器：'+[string]$context.DefaultServer) 13 $script:Text2) '0,6,0,12')
 AddC $p (Note '先检查服务器是否已有 TCP 服务；已有则直接取得本设备参数，没有则展示增量部署计划。无需填写 UUID、公钥、ShortId 或伪装域名。')
 if($a.Stage -eq 'Access'){
  AddC $p (Margin (T '登录这台服务器' 14 $script:Ink 'SemiBold') '0,20,0,6')
  AddC $p (T '为了核对原设备并取得连接参数，需要一次服务器管理登录。密码不会保存到聊天或日志。' 12.5 $script:Text3)
  $user=New-Object Windows.Controls.TextBox;$user.Text=$a.User;$user.Tag='User';$user.Add_TextChanged({$script:AutoTCP.User=$this.Text});AddC $p (Margin (T '用户名' 12.5) '0,10,0,4');AddC $p $user
  $null=ControlName $user 'AutomaticTcpUser'
  $port=New-Object Windows.Controls.TextBox;$port.Text=$a.Port;$port.Add_TextChanged({$script:AutoTCP.Port=$this.Text});AddC $p (Margin (T 'SSH 端口' 12.5) '0,10,0,4');AddC $p $port
  $null=ControlName $port 'AutomaticTcpSshPort'
  AddC $p (Margin (T '服务器密码，或下方私钥对应的口令' 12.5) '0,10,0,4')
  $password=ControlName (New-Object Windows.Controls.PasswordBox) 'ServerPassword';$password.MinHeight=38;AddC $p $password
  $key=ControlName (New-Object Windows.Controls.TextBox) 'ServerKeyPath';$key.MinHeight=38
  $exp=New-Object Windows.Controls.Expander;$exp.Header='使用 SSH 私钥（可选）';$exp.Content=$key;$exp.Margin='0,10,0,0';AddC $p $exp
  $null=DeploymentActions $p '安全登录并自动检查' 'AutomaticTcpLogin' {StartAutomaticTransportLogin}
 }elseif($a.Stage -eq 'Ready'){
  AddC $p (Margin (T 'TCP 备用配置已准备' 16 $script:Ink 'SemiBold') '0,18,0,8')
  AddC $p (T '服务器和本机配置已核对；当前网络未切换。' 13 $script:Text2)
  if($a.Result.ProbeRequiresInactiveIdentity){AddC $p (Margin (Note '这条备用配置沿用当前设备身份。该身份正在使用时不并行探测，避免抢占现有连接。稍后在维护窗口确认启用并检查实际出口。' 'amber') '0,12,0,0')}
  $null=DeploymentActions $p '查看准备好的线路' 'AutomaticTcpToNodes' {$script:AutoTCP=$null;$script:Role='client';ShowNodes;FetchNodes}
 }else{
  AddC $p (Margin (T '正在核对服务器与本机配置…' 14 $script:Ink 'SemiBold') '0,18,0,6')
  AddC $p (T '已有 TCP 服务会直接使用；新增服务先展示计划，完成后自动准备本机备用。' 12.5 $script:Text3)
 }
 if($a.Error){AddC $p (Margin (Notice 'warn' '需要处理' $a.Error) '0,16,0,0')}
 if($script:DeployUI.Management -and $script:DeployUI.Management.Error){AddC $p (Margin (Notice 'warn' '服务器检查未完成' $script:DeployUI.Management.Error) '0,16,0,0')}
 if(($a.Error -or ($script:DeployUI.Management -and $script:DeployUI.Management.Error)) -and -not $script:DeployUI.PendingManagement){$null=DeploymentActions $p '重新登录并核对' 'AutomaticTcpRetry' {$script:AutoTCP.Stage='Access';$script:AutoTCP.Error='';$script:DeployUI.Management.Error='';ShowAutomaticTransport} 'Btn'}
 $bar=New-Object Windows.Controls.WrapPanel;$bar.Margin='0,16,0,0'
 $advanced=Btn '高级：手工配置…' 'AutomaticTcpAdvanced' {$id=$script:AutoTCP.Id;$script:AutoTCP=$null;$script:Role='client';LoadTransportForm $id} 'Ghost';$advanced.IsEnabled=(-not $script:DeployUI.PendingManagement);AddC $bar $advanced
 $back=Btn '返回线路' 'AutomaticTcpBack' {if($script:DeployUI.PendingManagement){Toast '检查仍在进行，请等待结果';return};$script:AutoTCP=$null;$script:Role='client';ShowNodes;FetchNodes} 'Btn';AddC $bar $back;AddC $p $bar
 AddC $script:HostPanel $card
}
function StartAutomaticTransportLogin {
 if(-not $script:AutoTCP -or $script:ReadOnly){return}
 $a=$script:AutoTCP
 $script:AutomaticTcpCredential=if($script:Smoke){$null}else{$script:Controls.ServerPassword.SecurePassword}
 $script:AutomaticTcpKey=[string]$script:Controls.ServerKeyPath.Text
 StartJob @{Action='AutoTransportBind';Id=$a.Id;User=$a.User;Port=$a.Port} {param($server)
  InitializeServerUI
  $m=$script:DeployUI.Management
  if($m.SessionRef -and $m.ServerId -ne $server.LocalRecordId -and -not $script:Smoke){try{Import-Module (UIProductPath 'DeploymentTransport.psm1') -DisableNameChecking;$null=Stop-TCDeploySession $m.SessionRef}catch{}}
  $m.ServerId=$server.LocalRecordId;$m.Server=$server;$m.Authenticated=$false;$m.Error='';$m.SessionRef=$null
  $script:DeployUI.ServerId=$server.LocalRecordId;$script:DeployUI.ManagementMode=$true
  if(-not $script:Smoke){
   # Do not rebuild the access page between capturing and passing credentials.
   $script:Controls.ServerKeyPath.Text=$script:AutomaticTcpKey
   $ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($script:AutomaticTcpCredential)
   try{$script:Controls.ServerPassword.Password=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)}finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)}
  }
  $script:AutoTCP.Stage='Inspect';ConnectServerUI
  $script:AutomaticTcpCredential=$null;$script:AutomaticTcpKey=$null
 } '核对目标服务器记录，保留原设备…' -Failed {param($message)$script:AutomaticTcpCredential=$null;$script:AutomaticTcpKey=$null;$script:AutoTCP.Error=$message;ShowAutomaticTransport}
}
function PrepareAutomaticTransportSaved {
 $script:AutoTCP.Stage='Preparing';ShowAutomaticTransport
 StartJob @{Action='AutoTransportSaved';Id=$script:AutoTCP.Id} {param($d)CompleteAutomaticTransportCandidate $d} '自动准备已有 TCP 参数，当前连接保持…' -Failed {param($message)$script:AutoTCP.Error=$message;$script:AutoTCP.Stage='Access';ShowAutomaticTransport}
}
function CompleteAutomaticTransportCandidate {param($Result)
 $script:AutoTCP.Result=$Result;$script:AutoTCP.Stage='Ready';$script:AutoTCP.Error=''
 ShowAutomaticTransport;Toast 'TCP 备用已准备，尚未启用'
}
function CompleteAutomaticTransportOperation {param([string]$Purpose,$Data)
 if(-not $script:AutoTCP){return $false}
 $a=$script:AutoTCP;$m=$script:DeployUI.Management
 switch($Purpose){
  'ServerInfo'{
   if($Data.Node.ServerPublicKey -cne $a.Context.ServerPublicKey){throw '服务器隧道身份与原线路不同，已停止自动配置。'}
   if($Data.OwnershipState -cne 'Applied'){throw '服务器部署状态需要恢复，先在服务器管理页核对原事务。'}
   $m.Info=$Data
   if(-not $script:Smoke){Import-Module (UIProductPath 'ServerRegistry.psm1') -DisableNameChecking;$m.Server=Set-TCServerRecord -Root $script:Root -Id $m.ServerId -ServerInfo $Data}
   StartServerOperation transport_info @{ClientPublicKey=$a.Context.ClientPublicKey;ServerPublicKey=$a.Context.ServerPublicKey} AutomaticTransportInfo
  }
  'AutomaticTransportInfo'{
   if($Data.Status -eq 'NotConfigured'){
    $a.Stage='Plan';StartServerOperation transport_plan @{Transport=@{Type='tcp-reality';Port=443;ServerName='www.bing.com'}} AutomaticTransportPlan
   }elseif($Data.Status -eq 'Available'){
    $a.Stage='Preparing';ShowAutomaticTransport
    StartJob @{Action='AutoTransportPrepare';Id=$a.Id;TransportInfo=$Data} {param($d)CompleteAutomaticTransportCandidate $d} '自动校验并准备本机 TCP 备用…' -Failed {param($message)$script:AutoTCP.Error=$message;ShowAutomaticTransport}
   }else{throw '服务器 TCP 服务尚未通过检查，请查看服务器诊断。'}
  }
  'AutomaticTransportPlan'{
   $a.Plan=$Data;$a.Stage='Review';ShowAutomaticTransport
   OpenDialog '为这台服务器添加 TCP 备用？' ('服务器：'+$a.Context.DefaultServer+"`nTCP 端口："+$Data.Transport.Port+"`n保留 UDP、原设备和当前连接。") '云端需要放行此 TCP 入站端口。完成后自动准备本机备用配置，暂不切换线路。' '按计划准备' {StartServerOperation transport_apply @{PlanId=$script:AutoTCP.Plan.PlanId;ApprovedChangeDigest=$script:AutoTCP.Plan.ChangeDigest} AutomaticTransportApply}
  }
  'AutomaticTransportApply'{
   $a.Stage='Inspect';StartServerOperation transport_info @{ClientPublicKey=$a.Context.ClientPublicKey;ServerPublicKey=$a.Context.ServerPublicKey} AutomaticTransportInfo
  }
  default{return $false}
 }
 return $true
}
function ShowConnectionRecovery {param([string]$Id,[string]$Message)
 $script:RecoveryContext=@{Id=$Id;Message=$Message}
 StartJob @{Action='LineRecovery';Id=$Id} {param($d)
  $script:RecoveryResult=$d;ShowConnectionRecoveryPage
 } '分层检查原线路与实际出口，不切换网络…' -Failed {param($message)$script:RecoveryResult=[pscustomobject]@{Summary=$message;Code='DiagnosticsIncomplete';Checks=@();CanPrepareTcp=$true};ShowConnectionRecoveryPage}
}
function ShowConnectionRecoveryPage {
 $d=$script:RecoveryResult;PageHead '线路连接检查' '先确定失败发生在哪一层，再准备合适的连接方式。' 'line-recovery'
 $card=Card;$p=Stack;$card.Child=$p
 AddC $p (T ([string]$d.Summary) 16 $script:Ink 'SemiBold')
 if($script:RecoveryContext.Message){AddC $p (Margin (T $script:RecoveryContext.Message 12.5 $script:Text3) '0,8,0,0')}
 foreach($check in @($d.Checks)){KeyValue $p ([string]$check.Label) ([string]$check.Message)}
 AddC $p (Margin (Note '进程已启动、TCP 端口可达和隧道能转发是不同结果。单次失败不直接判定 UDP 被阻断，也不会自动切换协议。') '0,16,0,0')
 if($d.Code -eq 'ActiveForwardingPassed'){AddC $p (Margin (T '这次实际出口检查已通过，可继续使用当前方式。' 13 $script:Text2) '0,12,0,0')}
 else{$null=DeploymentActions $p '自动准备 TCP 备用' 'RecoveryPrepareTcp' {OpenAutomaticTransport $script:RecoveryContext.Id}}
 $null=DeploymentActions $p '返回线路' 'RecoveryBack' {ShowNodes;FetchNodes} 'Ghost'
 AddC $script:HostPanel $card
}
