# Offline invitation/application/encrypted-return UI. No SSH credentials on new PC.
function InitializePairingUI {
 if(-not (ServerUIGet $script:DeployUI PairFields)){$script:DeployUI.PairFields=@{InviteText='';RequestText='';ReturnText='';DeviceName=[Environment]::MachineName;LineName='已有服务器的新电脑线路';Fingerprint='';RecoveryText='';RecoveryKeyPath=''}}
 if($script:DeployUI.Invite -and -not $script:DeployUI.PairFields.InviteText){$script:DeployUI.PairFields.InviteText=[string]$script:DeployUI.Invite.Invite}
}
function PairField {param($Parent,[string]$Label,[string]$Id,[string]$Key,[string]$Hint='',[switch]$Multiline)
 $box=DeploymentField $Parent $Label $Id ([string]$script:DeployUI.PairFields[$Key]) $Hint -Multiline:$Multiline
 $box.Tag=$Key;$box.Add_TextChanged({$script:DeployUI.PairFields[[string]$this.Tag]=$this.Text});return $box
}
function PastePairField {param([string]$Key)
 if($script:Smoke){return};try{$script:DeployUI.PairFields[$Key]=[Windows.Clipboard]::GetText();ShowProductPairing}catch{ErrorDialog '无法读取剪贴板，请直接粘贴资料。'}
}
function InspectPairInviteUI {
 InitializePairingUI
 StartJob @{Action='PairInviteInspect';Invite=$script:DeployUI.PairFields.InviteText;AllowUnconfirmed=$true} {param($d)
  $script:DeployUI.InviteInspection=$d;$script:DeployUI.PairFields.Fingerprint=[string]$d.Fingerprint
  OpenDialog '确认邀请来自预期的管理电脑？' ('服务器签名指纹：'+[string]$d.Fingerprint+"`n请与管理电脑显示的指纹核对，或确认邀请通过可信方式交接。") '签名可证明资料完整，首次邀请中的公钥不能自行证明来源。此操作只生成本机申请，不切换线路。' '来源已核对，生成申请' {CreatePairRequestUI}
 } '验证邀请签名和时效…'
}
function CreatePairRequestUI {
 StartJob @{Action='PairRequestCreate';Invite=$script:DeployUI.PairFields.InviteText;ConfirmedFingerprint=$script:DeployUI.PairFields.Fingerprint;DeviceName=$script:DeployUI.PairFields.DeviceName} {param($d)
  $script:DeployUI.EnrollmentId=[string]$d.EnrollmentId;$script:DeployUI.PairRequest=[string]$d.PairRequest;$script:DeployUI.PairFields.RequestText=[string]$d.PairRequest;$script:DeployUI.PairRequestResult=$d
  ShowProductPairing;Toast '本机申请已保存，只把公开申请交给管理电脑'
 } '生成独立设备身份和接入申请…'
}
function InspectPairRequestUI {
 $script:DeployUI.PairRequest=$script:DeployUI.PairFields.RequestText
 StartJob @{Action='PairRequestInspect';PairRequest=$script:DeployUI.PairRequest} {param($d)
  $script:DeployUI.PairRequestInspection=$d
  try{$null=AssertPairContextUI}catch{ErrorDialog $_.Exception.Message;return}
  $payload=ServerUIGet $d Payload $d;$name=[string](ServerUIGet $payload DeviceName '新电脑');$code=[string](ServerUIGet $d PairingCode '')
  OpenDialog '授权这台新电脑？' ('设备：'+$name+"`n配对摘要："+$code+"`n请与新电脑的申请摘要核对。") '只有管理端需要 SSH 权限；不复制已有电脑私钥，不为管理电脑新增 Peer。本机不会换线。' '批准该设备申请' {AuthorizePairRequestUI}
 } '核对新电脑的公开申请…'
}
function AuthorizePairRequestUI {
 InitializeServerUI;$m=$script:DeployUI.Management
 if(-not $script:Smoke -and -not $m.Authenticated){ErrorDialog '请先在「我的服务器」登录对应服务器的管理账户。';return}
 try{$null=AssertPairContextUI}catch{ErrorDialog $_.Exception.Message;return}
 $info=ServerUIGet $script:DeployUI PairRequestInspection;$payload=ServerUIGet $info Payload $info
 $inviteId=[string](ServerUIGet $payload InviteId '')
 if(-not $inviteId){ErrorDialog '没有可验证的邀请编号，请重新检查申请。';return}
 $script:DeployUI.Invite=@{Invite=$script:DeployUI.PairFields.InviteText;InviteId=$inviteId}
 StartServerOperation authorize_external @{InviteId=$inviteId;PairRequest=$script:DeployUI.PairRequest} AuthorizeExternal
}
function RecoverPairReturnUI {
 $info=ServerUIGet $script:DeployUI PairRequestInspection;$payload=ServerUIGet $info Payload $info;$request=ServerUIGet $payload ClientRequest
 if(-not $request){ErrorDialog '请先核对原申请，使用原 RequestId 取回结果。';return}
 try{$null=AssertPairContextUI -AllowExpired}catch{ErrorDialog $_.Exception.Message;return}
 StartServerOperation request_status @{RequestId=$request.RequestId;RequestDigest=$payload.RequestDigest;RefreshAuthorization=$true} AuthorizeExternal
}
function RestorePairInviteUI {
 $info=ServerUIGet $script:DeployUI PairRequestInspection;$payload=ServerUIGet $info Payload $info;$id=[string](ServerUIGet $payload InviteId '')
 if(-not $id){ErrorDialog '请先粘贴并检查原设备申请，管理端按其邀请编号取回原邀请。';return}
 StartServerOperation invite_status @{InviteId=$id} RestoreInvite
}
function AssertPairContextUI {param([switch]$AllowExpired)
 InitializePairingUI;InitializeServerUI;$m=$script:DeployUI.Management
 $info=ServerUIGet $script:DeployUI PairRequestInspection;$request=ServerUIGet $info Payload $info
 if(-not $script:DeployUI.PairFields.InviteText){throw '请粘贴与申请对应的原邀请，或登录管理端取回原邀请，再批准设备。'}
 $binding=ServerUIGet $request ServerBinding
 if(-not $binding -or -not $m.Info){throw '请先核对设备申请，并登录目标服务器读取真实身份。'}
 $expected=@{RemoteOwnerId=$m.Info.RemoteOwnerId;NodeId=$m.Info.Node.NodeId;ServerPublicKey=$m.Info.Node.ServerPublicKey}
 foreach($name in @('RemoteOwnerId','NodeId','ServerPublicKey')){if([string](ServerUIGet $binding $name '') -cne [string]$expected[$name]){throw '设备申请指向另一台服务器；没有提交授权。'}}
 if($script:Smoke){return $true}
 Import-Module (UIProductPath 'DeploymentPairing.psm1') -DisableNameChecking
 if($AllowExpired){
  $module=Get-Module DeploymentPairing
  $inviteBody=& $module {param($Text,$Public)Initialize-TCPairCrypto;ConvertFrom-TCPairJson ([TradeChannel.Deployment.PairCrypto]::Verify($Text,(ConvertTo-TCPairJson $Public)))} $script:DeployUI.PairFields.InviteText $m.Info.ManagementSigningPublicKey
 }else{
  $verified=Get-TCPairInvite -Invite $script:DeployUI.PairFields.InviteText -AllowUnconfirmed
  $trusted=[TradeChannel.Deployment.PairCrypto]::Fingerprint(($m.Info.ManagementSigningPublicKey|ConvertTo-Json -Compress))
  if($verified.Fingerprint -cne $trusted){throw '邀请签名身份与已登录服务器不匹配；没有提交授权。'}
  $inviteBody=$verified.Payload
 }
 if($inviteBody.InviteId -cne $request.InviteId -or $inviteBody.Kind -cne 'TradeChannel.PairInvite' -or $inviteBody.SchemaVersion -ne 1){throw '邀请和设备申请不对应；没有提交授权。'}
 foreach($name in @('RemoteOwnerId','NodeId','ServerPublicKey')){if([string](ServerUIGet $inviteBody $name '') -cne [string]$expected[$name]){throw '原邀请的服务器绑定不匹配；没有提交授权。'}}
 return $true
}
function CompletePairReturnUI {
 if(-not $script:DeployUI.EnrollmentId){ErrorDialog '请选择本机保存的原申请，不能用另一台电脑的申请接收授权。';return}
 StartJob @{Action='PairComplete';EnrollmentId=$script:DeployUI.EnrollmentId;EncryptedAuthorization=$script:DeployUI.PairFields.ReturnText;Name=$script:DeployUI.PairFields.LineName} {param($d)
  $script:DeployUI.PairCompletion=$d;ShowProductPairing;Toast '新电脑线路已准备，尚未启用';FetchNodes
 } '解密、核对本机身份并生成候选线路…'
}
function GetPairEnrollmentsUI {
 if($script:Smoke){return @()}
 $base=Join-Path $script:Root 'identities';if(-not [IO.Directory]::Exists($base)){return @()}
 Import-Module (UIProductPath 'DeploymentPairing.psm1') -DisableNameChecking
 $rows=@()
 foreach($directory in @(Get-ChildItem -LiteralPath $base -Directory|Select-Object -First 500)){
  if($directory.Name -cnotmatch '^[0-9a-f-]{36}$'){continue}
  try{$e=Get-TCPairEnrollment -Root $script:Root -EnrollmentId $directory.Name;$rows+=[pscustomobject]@{EnrollmentId=$e.EnrollmentId;State=$e.State;CreatedAtUtc=$e.CreatedAtUtc;PairRequest=$e.PairRequest;DeviceId=$e.ClientRequest.DeviceId}}catch{}
 }
 return @($rows|Sort-Object CreatedAtUtc -Descending)
}
function ShowProductPairing {
 InitializePairingUI;$script:Role='product-pair';$script:Page='setup';Head '' '连接已有服务器' '新电脑只交接邀请、公开申请和加密授权；无需服务器密码。'
 $card=Card;$p=Stack;$card.Child=$p;SetupCardHeader $p '1 · 新电脑：取得邀请并生成申请' '管理电脑在服务器页生成一次性邀请。' 'laptop'
 $null=PairField $p '粘贴服务器邀请' 'PairInviteText' InviteText '邀请不含服务器管理凭据，仍需核对来源。' -Multiline
 $null=PairField $p '这台电脑的名称' 'PairDeviceName' DeviceName
 $null=DeploymentActions $p '从剪贴板粘贴邀请' 'PairPasteInvite' {PastePairField InviteText} 'Ghost'
 $null=DeploymentActions $p '检查邀请并生成本机申请…' 'PairInspectInvite' {InspectPairInviteUI}
 if($script:DeployUI.PairRequestResult){AddC $p (Margin (T ('本机申请摘要：'+$script:DeployUI.PairRequestResult.PairingCode) 13 $script:Ink 'SemiBold') '0,12,0,0');$null=DeploymentActions $p '复制公开申请给管理电脑' 'PairCopyRequest' {if(-not $script:Smoke){[Windows.Clipboard]::SetText([string]$script:DeployUI.PairRequest)};Toast '已复制公开申请'} 'Ghost'}
 AddC $script:HostPanel (Margin $card '0,0,0,16')
 $card=Card;$p=Stack;$card.Child=$p;SetupCardHeader $p '2 · 管理电脑：核对并批准申请' '管理电脑登录服务器，新电脑保持自己的独立身份。' 'key'
 AddC $p (Note '这一步在拥有服务器管理权限的电脑完成。先在「我的服务器」选中目标并登录，再粘贴新电脑申请。')
 $null=PairField $p '新电脑的公开申请' 'PairRequestText' RequestText '' -Multiline
 $null=DeploymentActions $p '选择服务器并登录管理' 'PairManageServer' {ShowServerManagement;LoadServersUI} 'Ghost'
 $null=DeploymentActions $p '核对申请并授权…' 'PairInspectRequest' {InspectPairRequestUI}
 $null=DeploymentActions $p '管理端取回与申请对应的原邀请' 'PairRestoreInvite' {RestorePairInviteUI} 'Ghost'
 $null=DeploymentActions $p '返回丢失 / 过期：取回原授权' 'PairRecoverReturn' {RecoverPairReturnUI} 'Ghost'
 if(ServerUIGet $script:DeployUI EncryptedAuthorization){
  AddC $p (Margin (T '服务器已授权，返回资料已加密给申请电脑。' 13 $script:Ink 'SemiBold') '0,14,0,0')
  $null=DeploymentActions $p '复制加密授权给新电脑' 'PairCopyEncrypted' {if(-not $script:Smoke){[Windows.Clipboard]::SetText([string]$script:DeployUI.EncryptedAuthorization)};Toast '已复制授权密文'} 'Ghost'
 }
 AddC $script:HostPanel (Margin $card '0,0,0,16')
 $card=Card;$p=Stack;$card.Child=$p;SetupCardHeader $p '3 · 新电脑：接收加密返回' '只在生成原申请的这台电脑解密和合成。' 'check'
 $enrollments=@(GetPairEnrollmentsUI)
 if($enrollments.Count){
  $selector=ControlName (New-Object Windows.Controls.ComboBox) 'PairEnrollmentChoice'
  foreach($entry in $enrollments){$item=New-Object Windows.Controls.ComboBoxItem;$item.Content=(ManagementTime $entry.CreatedAtUtc)+' · '+$(if($entry.State -eq 'Completed'){'已完成接入'}else{'等待接收授权'});$item.Tag=$entry.EnrollmentId;$null=$selector.Items.Add($item);if($entry.EnrollmentId -eq $script:DeployUI.EnrollmentId){$selector.SelectedItem=$item}}
  $selector.Add_SelectionChanged({if($this.SelectedItem){$script:DeployUI.EnrollmentId=[string]$this.SelectedItem.Tag}});AddC $p $selector
 }
 if($script:DeployUI.EnrollmentId){AddC $p (T '已选中这台电脑保存的原申请' 12 $script:Text3);$null=ManagementDetails $p ('本机申请编号：'+$script:DeployUI.EnrollmentId)}
 $null=PairField $p '加密授权返回' 'PairReturnText' ReturnText '' -Multiline
 $null=PairField $p '新线路名称' 'PairLineName' LineName
 $null=DeploymentActions $p '粘贴加密返回' 'PairPasteReturn' {PastePairField ReturnText} 'Ghost'
 $null=DeploymentActions $p '核对并生成本机候选线路' 'PairCompleteReturn' {CompletePairReturnUI}
 if(ServerUIGet $script:DeployUI PairCompletion){AddC $p (Margin (StatusLine 'ok' '新线路已准备，尚未启用') '0,14,0,0');$null=DeploymentActions $p '前往线路页，先验证再安排启用' 'PairToNodes' {ShowNodes;FetchNodes} 'Ghost'}
 AddC $script:HostPanel $card
}
function ShowManagementRecovery {
 InitializePairingUI;InitializeServerUI;$script:Role='product-recovery';$script:Page='setup';Head '' '管理恢复资料' '导出加密资料供电脑丢失或重装时恢复管理；导入后仍需登录核对服务器。'
 $card=Card;$p=Stack;$card.Child=$p;SetupCardHeader $p '导出当前服务器的管理恢复包' '不包含服务器私钥、其他电脑私钥或交易账户。' 'key'
 $m=$script:DeployUI.Management
 if(-not $m.Server -and $script:DeployUI.Run -and -not $script:Smoke){try{Import-Module (UIProductPath 'ServerRegistry.psm1') -DisableNameChecking;$m.Server=Get-TCServer -Root $script:Root -Id $script:DeployUI.Run.ServerRecordId;$m.ServerId=$m.Server.LocalRecordId}catch{}}
 AddC $p (T ('目标：'+$(if($m.Server){$m.Server.Name}else{'请先在「我的服务器」选择目标'})) 13 $script:Ink 'SemiBold')
 AddC $p (Margin (T '恢复包密码（至少 12 个字符）' 12.5 $script:Ink 'SemiBold') '0,12,0,5');$password=ControlName (New-Object Windows.Controls.PasswordBox) 'RecoveryExportPassword';$password.MinHeight=34;AddC $p $password
 $include=ControlName (New-Object Windows.Controls.CheckBox) 'RecoveryIncludeCredential';$include.Content='我选择把 SSH 管理密码 / 私钥也包含在加密包中';$include.Margin='0,12,0,0';AddC $p $include
 $null=PairField $p 'SSH 私钥文件（包含密钥时填写，密码认证留空）' 'RecoveryKeyPath' RecoveryKeyPath
 AddC $p (Margin (T '要包含的 SSH 密码 / 私钥口令' 12.5 $script:Ink 'SemiBold') '0,12,0,5');$credential=ControlName (New-Object Windows.Controls.PasswordBox) 'RecoveryCredential';$credential.MinHeight=34;AddC $p $credential
 $null=DeploymentActions $p '加密导出并保存…' 'RecoveryExport' {ExportRecoveryUI}
 AddC $script:HostPanel (Margin $card '0,0,0,16')
 $card=Card;$p=Stack;$card.Child=$p;SetupCardHeader $p '导入已有加密恢复包' '还原管理资料不会启用线路，也不能绕过管理授权。' 'server'
 $null=PairField $p '粘贴加密恢复资料' 'RecoveryText' RecoveryText '' -Multiline
 AddC $p (Margin (T '恢复包密码' 12.5 $script:Ink 'SemiBold') '0,12,0,5');$password=ControlName (New-Object Windows.Controls.PasswordBox) 'RecoveryImportPassword';$password.MinHeight=34;AddC $p $password
 $null=DeploymentActions $p '选择恢复包文件' 'RecoveryChooseFile' {if($script:Smoke){return};$path=ChooseFile '选择加密管理恢复资料' '加密资料 (*.tcrecovery)|*.tcrecovery|所有文件 (*.*)|*.*';if($path){if((Get-Item -LiteralPath $path).Length -gt 128KB){ErrorDialog '恢复包超过 128 KiB。';return};$script:DeployUI.PairFields.RecoveryText=[IO.File]::ReadAllText($path);ShowManagementRecovery}} 'Ghost'
 $null=DeploymentActions $p '解密并登记待核验服务器' 'RecoveryImport' {ImportRecoveryUI}
 AddC $script:HostPanel $card
}
function ExportRecoveryUI {
 if(ServerUIReadOnly){ErrorDialog '当前是只读检查窗口，未导出管理资料。';return}
 InitializeServerUI;$m=$script:DeployUI.Management
 if(-not $m.Server){ErrorDialog '请先选择要导出恢复资料的服务器。';return}
 if($script:Smoke){StartJob @{Action='ManagementRecoveryExportFixture';ServerId=$m.ServerId;IncludesCredential=[bool]$script:Controls.RecoveryIncludeCredential.IsChecked;EncryptedOnly=$true} {param($d)Toast '恢复包已加密'} '测试恢复导出';return}
 try{
  Import-Module (UIProductPath 'DeploymentPairing.psm1') -DisableNameChecking
  $credential=$null
  if($script:Controls.RecoveryIncludeCredential.IsChecked){
   $key=$script:DeployUI.PairFields.RecoveryKeyPath
   if($key){if(-not [IO.File]::Exists($key) -or (Get-Item -LiteralPath $key).Length -gt 1MB){throw 'SSH 私钥不存在或超限。'};$pem=[IO.File]::ReadAllText($key);$credential=@{Kind='PrivateKey';PrivateKeyPem=(ConvertTo-SecureString $pem -AsPlainText -Force);Passphrase=$script:Controls.RecoveryCredential.SecurePassword};$pem=$null}
   else{$credential=@{Kind='Password';Password=$script:Controls.RecoveryCredential.SecurePassword}}
  }
  $result=Export-TCManagementRecovery -ServerRecord $m.Server -Credential $credential -Password $script:Controls.RecoveryExportPassword.SecurePassword
  $path=ChooseFile '保存加密管理恢复资料' '加密资料 (*.tcrecovery)|*.tcrecovery' -Save -Name 'TradeChannel-management.tcrecovery'
  if($path){[IO.File]::WriteAllText($path,$result.Recovery,(New-Object Text.UTF8Encoding($false)));Toast '加密恢复包已保存，请妥善保存密码'}
 }catch{ErrorDialog $_.Exception.Message}finally{$credential=$null}
}
function ImportRecoveryUI {
 if(ServerUIReadOnly){ErrorDialog '当前是只读检查窗口，未导入管理资料。';return}
 if($script:Smoke){StartJob @{Action='ManagementRecoveryImportFixture';EncryptedOnly=$true} {param($d)Toast '等待实际登录核验'} '测试恢复导入';return}
 try{
  Import-Module (UIProductPath 'DeploymentPairing.psm1') -DisableNameChecking
  Import-Module (UIProductPath 'ServerRegistry.psm1') -DisableNameChecking
  $result=Import-TCManagementRecovery -Recovery $script:DeployUI.PairFields.RecoveryText -Password $script:Controls.RecoveryImportPassword.SecurePassword
  $server=Import-TCServerRecoveryRecord -Root $script:Root -ServerRecord $result.ServerRecord
  $script:DeployUI.RecoveredCredential=$result.Credential;$script:DeployUI.RecoveryExpected=$result.ServerRecord;$script:DeployUI.RecoveryRecordId=$server.LocalRecordId
  $script:DeployUI.Discovery=[pscustomobject]@{Servers=@(Get-TCServers $script:Root)};SelectServerUI $server.LocalRecordId
  Toast '管理资料已登记，实际登录与服务器身份仍待核验'
 }catch{ErrorDialog $_.Exception.Message}
}
