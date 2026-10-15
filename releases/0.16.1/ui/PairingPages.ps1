# Offline invitation/application/encrypted-return UI. No SSH credentials on new PC.
function InitializePairingUI {
 if(-not (ServerUIGet $script:DeployUI PairFields)){$script:DeployUI.PairFields=@{InviteText='';RequestText='';ReturnText='';DeviceName=[Environment]::MachineName;LineName='已有服务器的新电脑线路';Fingerprint='';RecoveryText='';RecoveryKeyPath=''}}
 if(-not (ServerUIGet $script:DeployUI PairIntake)){$script:DeployUI.PairIntake=@{Role='Client';Stage='Invite';Text='';Kind='Unknown';Error='';VerifiedText='';Grant=$null;RequestInfo=$null;PendingText='';TargetMatch='';TargetCandidates=@();TargetServerId='';TargetRequestDigest=''}}
 if($script:DeployUI.Invite -and -not $script:DeployUI.PairFields.InviteText){$script:DeployUI.PairFields.InviteText=[string]$script:DeployUI.Invite.Invite}
}
function ReceivePairMaterialUI {
 [CmdletBinding(DefaultParameterSetName='Text')]
 param([Parameter(Mandatory=$true,ParameterSetName='Text')][AllowEmptyString()][string]$Material,[Parameter(Mandatory=$true,ParameterSetName='File')][string]$Path)
 InitializePairingUI;$s=$script:DeployUI.PairIntake
 if($script:Role -ne 'product-pair' -and (Get-Command CaptureNavigationContext -ErrorAction SilentlyContinue)){$script:DeployUI.PairReturnContext=CaptureNavigationContext}
 try{
  Import-Module (UIProductPath 'DeploymentPairing.psm1') -DisableNameChecking
  $kind=if($PSCmdlet.ParameterSetName -eq 'File'){Get-TCPairMaterialKind -Path $Path}else{Get-TCPairMaterialKind -Material $Material}
  $s.Text=$kind.Material;$s.Kind=$kind.Kind;$s.Error='';$s.VerifiedText='';$s.Grant=$null;$s.RequestInfo=$null;$s.TargetMatch='';$s.TargetCandidates=@();$s.TargetServerId='';$s.TargetRequestDigest='';$script:Role='product-pair'
  if($kind.RequiredRole){$s.Role=$kind.RequiredRole}
  if(-not $kind.CanProcess){$s.Stage=if($s.Role -eq 'Manager'){'Review'}elseif($script:DeployUI.EnrollmentId){'Waiting'}else{'Invite'};$s.Error=if(-not $s.Text){''}elseif($kind.Reason -eq 'EncryptedGrantRequired'){'请取得管理电脑加密给原申请电脑的授权返回。'}elseif($kind.Kind -ne 'Unknown'){'这份 JSON 没有可核验的签名交接资料，请复制完整邀请或申请。'}else{'未识别为邀请、公开申请或加密授权；请粘贴完整资料或打开交接文件。'};ShowProductPairing;return}
  $s.Role=$kind.RequiredRole;$s.PendingText=$kind.Material;$script:DeployUI.PairCompletion=$null
  switch($kind.Kind){
   Invite{$s.Stage='Invite';$script:DeployUI.PairFields.InviteText=$kind.Material;$script:DeployUI.InviteInspection=$null;ShowProductPairing;InspectPairInviteUI}
   Request{$s.Stage='Review';$script:DeployUI.PairFields.RequestText=$kind.Material;$script:DeployUI.PairRequest=$kind.Material;$script:DeployUI.PairRequestInspection=$null;$script:DeployUI.EncryptedAuthorization=$null;ShowProductPairing;InspectPairRequestUI}
   Grant{$s.Stage='Grant';$script:DeployUI.PairFields.ReturnText=$kind.Material;ShowProductPairing;InspectPairGrantUI}
  }
 }catch{$s.Error=$_.Exception.Message;ShowProductPairing}
}
function QueuePairMaterialUI {
 param([string]$Text)
 InitializePairingUI;$s=$script:DeployUI.PairIntake;$s.Text=$Text;$s.VerifiedText='';$s.Grant=$null;$s.RequestInfo=$null;$s.Error='';$s.TargetMatch='';$s.TargetCandidates=@();$s.TargetServerId='';$s.TargetRequestDigest='';$script:DeployUI.InviteInspection=$null;$script:DeployUI.PairRequestInspection=$null
 if($s.Role -eq 'Manager'){$script:DeployUI.PairFields.RequestText=$Text;$script:DeployUI.PairRequest=$Text}else{if($s.Stage -in @('Invite','InviteTrust')){$script:DeployUI.PairFields.InviteText=$Text}else{$script:DeployUI.PairFields.ReturnText=$Text}}
 foreach($id in @('PairCreateRequest','PairCompleteReturn','PairAuthorize')){if($script:Controls.ContainsKey($id)){$script:Controls[$id].IsEnabled=$false}}
 if(-not (Get-Variable PairIntakeTimer -Scope Script -ErrorAction SilentlyContinue)){
  $script:PairIntakeTimer=New-Object Windows.Threading.DispatcherTimer;$script:PairIntakeTimer.Interval=[TimeSpan]::FromMilliseconds(350)
  $script:PairIntakeTimer.Add_Tick({$script:PairIntakeTimer.Stop();if($script:Role -ne 'product-pair'){return};if(IsBusy){$script:PairIntakeTimer.Start();return};ReceivePairMaterialUI -Material $script:DeployUI.PairIntake.Text})
 }
 $script:PairIntakeTimer.Stop();$script:PairIntakeTimer.Start()
}
function OpenPairMaterialFileUI {
 if($script:Smoke){return}
 $path=ChooseFile '打开邀请、公开申请或加密授权' '交接资料 (*.tcinvite;*.tcrequest;*.tcgrant;*.json;*.txt)|*.tcinvite;*.tcrequest;*.tcgrant;*.json;*.txt|所有文件 (*.*)|*.*'
 if($path){ReceivePairMaterialUI -Path $path}
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
 $script:DeployUI.PairIntake.Role='Client';$script:DeployUI.PairIntake.Stage='Invite'
 StartJob @{Action='PairInviteInspect';Invite=$script:DeployUI.PairFields.InviteText;AllowUnconfirmed=$true} {param($d)
  if((ServerUIGet $d Invite '') -and $d.Invite -cne $script:DeployUI.PairFields.InviteText){return}
  $script:DeployUI.InviteInspection=$d;$script:DeployUI.PairFields.Fingerprint=[string]$d.Fingerprint
  $script:DeployUI.PairIntake.Stage='InviteTrust';$script:DeployUI.PairIntake.VerifiedText=$script:DeployUI.PairFields.InviteText
  ShowProductPairing
 } '验证邀请签名和时效…'
}
function CreatePairRequestUI {
 if(ServerUIReadOnly){ErrorDialog '当前为只读检查窗口，未生成设备申请。';return}
 if(-not $script:Smoke -and ($script:DeployUI.PairIntake.VerifiedText -cne $script:DeployUI.PairFields.InviteText -or -not $script:DeployUI.InviteInspection)){ErrorDialog '邀请已变化，请重新核验来源。';return}
 StartJob @{Action='PairRequestCreate';Invite=$script:DeployUI.PairFields.InviteText;ConfirmedFingerprint=$script:DeployUI.PairFields.Fingerprint;DeviceName=$script:DeployUI.PairFields.DeviceName} {param($d)
  $script:DeployUI.EnrollmentId=[string]$d.EnrollmentId;$script:DeployUI.PairRequest=[string]$d.PairRequest;$script:DeployUI.PairFields.RequestText=[string]$d.PairRequest;$script:DeployUI.PairRequestResult=$d
  $script:DeployUI.PairIntake.Role='Client';$script:DeployUI.PairIntake.Stage='Waiting';$script:DeployUI.PairIntake.Text='';$script:DeployUI.PairIntake.VerifiedText='';$script:DeployUI.PairIntake.Kind='Unknown'
  ShowProductPairing;Toast '本机申请已保存，只把公开申请交给管理电脑'
 } '生成独立设备身份和接入申请…'
}
function InspectPairRequestUI {
 InitializePairingUI;$script:DeployUI.PairIntake.Role='Manager';$script:DeployUI.PairIntake.Stage='Review'
 $script:DeployUI.PairRequest=$script:DeployUI.PairFields.RequestText
 StartJob @{Action='PairRequestInspect';PairRequest=$script:DeployUI.PairRequest} {param($d)
  if((ServerUIGet $d PairRequest '') -and $d.PairRequest -cne $script:DeployUI.PairRequest){return}
  $script:DeployUI.PairRequestInspection=$d;$script:DeployUI.PairIntake.RequestInfo=$d
  ShowProductPairing;ContinuePairManagerReviewUI
 } '核对新电脑的公开申请…'
}
function AuthorizePairRequestUI {
 if(ServerUIReadOnly){ErrorDialog '当前为只读检查窗口，未批准设备。';return}
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
function ContinuePairManagerReviewUI {
 InitializePairingUI;InitializeServerUI;$m=$script:DeployUI.Management
 RestorePairManagerRequestUI
 if($script:DeployUI.PairIntake.Role -ne 'Manager' -or -not $script:DeployUI.PairRequestInspection){return}
 if(-not $m.Authenticated -or -not $m.Info){ResolvePairManagerTargetUI;ShowProductPairing;return}
 $request=ServerUIGet $script:DeployUI.PairRequestInspection Payload;$binding=ServerUIGet $request ServerBinding
 foreach($name in @('RemoteOwnerId','NodeId','ServerPublicKey')){$expected=if($name -eq 'RemoteOwnerId'){$m.Info.RemoteOwnerId}else{ServerUIGet $m.Info.Node $name ''};if([string](ServerUIGet $binding $name '') -cne [string]$expected){
  if((ServerUIGet $script:DeployUI.PairIntake TargetServerId '') -ceq [string]$m.ServerId){$script:DeployUI.PairIntake.TargetMatch='LiveMismatch';$script:DeployUI.PairIntake.Error='实际服务器身份与申请目标不匹配，未提交授权。';ShowProductPairing}
  else{ResolvePairManagerTargetUI;ShowProductPairing};return
 }}
 $script:DeployUI.PairIntake.Error='';$script:DeployUI.PairIntake.TargetMatch='Authenticated';$script:DeployUI.PairIntake.TargetServerId=[string]$m.ServerId;$script:DeployUI.PairIntake.TargetRequestDigest=[string]$script:DeployUI.PairRequestInspection.RequestDigest
 if(-not $script:DeployUI.PairFields.InviteText -or [string](ServerUIGet $script:DeployUI.Invite InviteId '') -cne [string]$request.InviteId){$script:DeployUI.PairFields.InviteText='';RestorePairInviteUI}
}
function GetPairManagerTargetsUI {
 # Registry records are only routing hints. Reading them does not authenticate SSH or an invitation.
 $info=ServerUIGet $script:DeployUI PairRequestInspection
 if(-not $info -or [string](ServerUIGet $info PairRequest '') -cne [string]$script:DeployUI.PairRequest){return}
 Import-Module (UIProductPath 'DeploymentPairing.psm1') -DisableNameChecking
 Import-Module (UIProductPath 'ServerRegistry.psm1') -DisableNameChecking
 $pair=Get-Module DeploymentPairing;$binding=$info.Payload.ServerBinding
 & $pair {param($Binding) Assert-TCPairBinding $Binding} $binding
 $records=@(Get-TCServers -Root $script:Root)
 if($records.Count -gt 500){throw '本机服务器记录超过匹配上限，请先整理并核对目标记录。'}
 foreach($record in $records){
  if((ServerUIGet $record RecordState 'Active') -cne 'Active' -or (ServerUIGet $record ManagementAccessState '') -ceq 'ConnectorOnly' -or -not (ServerUIGet $record Connection)){continue}
  try{
   $id=[string](ServerUIGet $record LocalRecordId '');$current=Get-TCServer -Root $script:Root -Id $id
   & $pair {param($Binding) Assert-TCPairBinding $Binding} ([pscustomobject]@{RemoteOwnerId=$current.RemoteOwnerId;NodeId=$current.NodeId;ServerPublicKey=$current.ServerPublicKey})
   $match=$true;foreach($name in @('RemoteOwnerId','NodeId','ServerPublicKey')){if([string](ServerUIGet $current $name '') -cne [string](ServerUIGet $binding $name '')){$match=$false;break}}
   if(-not $match){continue}
   $connection=$current.Connection
   $store=Get-Module DeploymentStore;& $store {param($Value) Assert-TCDFields $Value @('Host','Port','User','IdentityFile') @('Host','Port','User')} $connection
   $address=$null;$port=0
   if([string]$connection.Host -cnotmatch '^(?:0|[1-9][0-9]{0,2})(?:\.(?:0|[1-9][0-9]{0,2})){3}$' -or -not [Net.IPAddress]::TryParse([string]$connection.Host,[ref]$address) -or $address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or -not [int]::TryParse([string]$connection.Port,[ref]$port) -or $port -lt 1 -or $port -gt 65535 -or [string]$connection.User -cnotmatch '^[a-z_][a-z0-9_-]{0,31}$'){continue}
   if((ServerUIGet $current PinnedHostKey '') -and [string]$current.PinnedHostKey -cnotmatch '^SHA256:[A-Za-z0-9+/]{43}=?$'){continue}
   $current
  }catch{continue} # Invalid/archived/duplicate IDs cannot silently become a selected target.
 }
}
function SelectPairManagerTargetUI {param([string]$ServerId)
 InitializePairingUI;InitializeServerUI;$s=$script:DeployUI.PairIntake
 if($s.Role -ne 'Manager' -or -not $script:DeployUI.PairRequestInspection){return}
 try{
  $targets=@(GetPairManagerTargetsUI);$target=@($targets|Where-Object {$_.LocalRecordId -ceq $ServerId})
  if($target.Count -ne 1){throw '目标记录已变化或不再匹配原申请，请重新核对本机台账。'}
  $m=$script:DeployUI.Management
  if($script:DeployUI.PendingManagement -or (ServerUIGet $m ReinstallStage) -or ($script:DeployUI.Run -and $script:DeployUI.Run.Status -eq 'Running')){throw '当前服务器操作尚未结束，请完成或核对后再继续此申请。'}
  # Keep the existing server-selection/session lifecycle; supply only freshly read Root records.
  $records=@(Get-TCServers -Root $script:Root);$discovery=ServerUIGet $script:DeployUI Discovery
  if(-not $discovery){$script:DeployUI.Discovery=[pscustomobject]@{Servers=$records;ContinueRuns=@()}}
  elseif($discovery -is [Collections.IDictionary]){$discovery['Servers']=$records}
  else{$discovery|Add-Member NoteProperty Servers $records -Force}
  SelectServerUI $ServerId
  InitializePairingUI;RestorePairManagerRequestUI
  if([string]$script:DeployUI.Management.ServerId -cne $ServerId){throw '未完成目标选择，请先核对当前服务器操作。'}
  $s.TargetMatch='Unique';$s.TargetCandidates=$targets;$s.TargetServerId=$ServerId;$s.TargetRequestDigest=[string]$script:DeployUI.PairRequestInspection.RequestDigest;$s.Error='';$script:Role='product-pair';ShowProductPairing
 }catch{$s.TargetMatch='Blocked';$s.Error=$_.Exception.Message;$script:Role='product-pair';ShowProductPairing}
}
function ResolvePairManagerTargetUI {
 InitializePairingUI;$s=$script:DeployUI.PairIntake
 if($s.Role -ne 'Manager' -or -not $script:DeployUI.PairRequestInspection){return}
 try{
  $targets=@(GetPairManagerTargetsUI);$s.TargetCandidates=$targets;$s.TargetRequestDigest=[string]$script:DeployUI.PairRequestInspection.RequestDigest
  if($targets.Count -eq 1){
   if([string]$script:DeployUI.Management.ServerId -cne [string]$targets[0].LocalRecordId){SelectPairManagerTargetUI $targets[0].LocalRecordId}
   else{
    $m=$script:DeployUI.Management;$m.Server=$targets[0];$s.TargetMatch='Unique';$s.TargetServerId=[string]$targets[0].LocalRecordId;$s.Error=''
    if($m.Authenticated -and $m.Info){foreach($name in @('RemoteOwnerId','NodeId','ServerPublicKey')){$live=if($name -eq 'RemoteOwnerId'){ServerUIGet $m.Info $name ''}else{ServerUIGet $m.Info.Node $name ''};if([string]$live -cne [string](ServerUIGet $targets[0] $name '')){$s.TargetMatch='LiveMismatch';$s.Error='实际服务器身份与申请目标不匹配，未提交授权。';break}}}
   }
  }elseif($targets.Count -gt 1){$s.TargetMatch='Ambiguous';$s.TargetServerId='';$s.Error='';$script:DeployUI.Management.Info=$null}
  else{$s.TargetMatch='Missing';$s.TargetServerId='';$s.Error='这台电脑没有与申请身份匹配的可管理记录，请登记或核对目标服务器。'}
 }catch{$s.TargetMatch='Blocked';$s.Error=$_.Exception.Message}
}
function AddPairManagerLoginUI {param($Parent)
 $m=$script:DeployUI.Management
 AddC $Parent (T ('目标服务器：'+[string]$m.Server.Name+' · '+$m.Server.Connection.Host+':'+$m.Server.Connection.Port) 13 $script:Ink 'SemiBold')
 AddC $Parent (T '已按申请身份匹配本机台账；登录后仍会核对服务器真实身份。' 12 $script:Text3)
 $null=ServerField $Parent 'SSH 私钥文件（密码登录时留空）' 'ServerKeyPath' KeyPath
 AddC $Parent (Margin (T '服务器密码 / 私钥口令' 12.5 $script:Ink 'SemiBold') '0,12,0,5');$password=ControlName (New-Object Windows.Controls.PasswordBox) 'ServerPassword';$password.MinHeight=34;AddC $Parent $password
 if(ServerUIGet $m.Server CredentialRef ''){
  $saved=ControlName (New-Object Windows.Controls.CheckBox) 'PairUseSavedCredential';$saved.Content='使用该服务器已保存的管理凭据';$saved.IsChecked=[bool](ServerUIGet $m UseSavedCredential $false);$saved.Margin='0,8,0,0';$saved.Add_Checked({$script:DeployUI.Management.UseSavedCredential=$true});$saved.Add_Unchecked({$script:DeployUI.Management.UseSavedCredential=$false});AddC $Parent $saved
 }
}
function ConnectPairManagerUI {
 if(ServerUIReadOnly){ErrorDialog '当前为只读检查窗口，未启动管理登录。';return}
 $s=$script:DeployUI.PairIntake;$m=$script:DeployUI.Management
 if($s.Role -ne 'Manager' -or (ServerUIGet $s TargetMatch '') -ne 'Unique'){return}
 if($script:DeployUI.PendingManagement){ErrorDialog '当前登录或身份核对尚未完成，请等待原操作结果。';return}
 try{$targets=@(GetPairManagerTargetsUI|Where-Object {$_.LocalRecordId -ceq $s.TargetServerId})}catch{$s.TargetMatch='Blocked';$s.Error=$_.Exception.Message;ShowProductPairing;return}
 if($targets.Count -ne 1 -or [string]$m.ServerId -cne $s.TargetServerId){$s.TargetMatch='Blocked';$s.Error='目标记录已变化，请重新匹配原申请。';ShowProductPairing;return}
 foreach($name in @('Host','Port','User','IdentityFile')){if([string](ServerUIGet $m.Server.Connection $name '') -cne [string](ServerUIGet $targets[0].Connection $name '')){$s.TargetMatch='Blocked';$s.Error='管理入口已变化，请重新核对原申请对应的记录。';ShowProductPairing;return}}
 foreach($name in @('PinnedHostKey','CredentialRef')){if([string](ServerUIGet $m.Server $name '') -cne [string](ServerUIGet $targets[0] $name '')){$s.TargetMatch='Blocked';$s.Error='管理身份或凭据引用已变化，请重新核对目标记录。';ShowProductPairing;return}}
 $m.ReadContinuation='Pairing'
 if($m.Authenticated){StartServerOperation server_info @{} ServerInfo;return}
 # Credential handling stays in the existing authenticated management path; never in a pairing Worker request.
 ConnectServerUI
 $script:Role='product-pair';ShowProductPairing
}
function RestorePairManagerRequestUI {
 # Server selection may reset its old pairing fields. Keep the explicitly supplied public request.
 $s=$script:DeployUI.PairIntake;$cached=ServerUIGet $s RequestInfo
 if($s.Role -eq 'Manager' -and $s.Kind -eq 'Request' -and $cached -and [string](ServerUIGet $cached PairRequest '') -ceq $s.Text){
  $script:DeployUI.PairFields.RequestText=$s.Text;$script:DeployUI.PairRequest=$s.Text;$script:DeployUI.PairRequestInspection=$cached
 }
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
  if((ServerUIGet $info PairRequest '') -and $info.PairRequest -cne $script:DeployUI.PairRequest){throw '设备申请已变化，请重新核验。'}
  if($AllowExpired){
  $module=Get-Module DeploymentPairing
   $inviteBody=& $module {param($Text,$Public)Initialize-TCPairCrypto;$body=ConvertFrom-TCPairJson ([TradeChannel.Deployment.PairCrypto]::Verify($Text,(ConvertTo-TCPairJson $Public)));Assert-TCPairFields $body @('SchemaVersion','Kind','InviteId','RemoteOwnerId','NodeId','ServerPublicKey','ManagementSigningPublicKey','PublicEndpoint','IssuedAtUtc','ExpiresAtUtc','Capabilities','ServerBinding','DeviceName');if([TradeChannel.Deployment.PairCrypto]::Fingerprint((ConvertTo-TCPairJson $body.ManagementSigningPublicKey)) -cne [TradeChannel.Deployment.PairCrypto]::Fingerprint((ConvertTo-TCPairJson $Public))){Stop-TCPair InviteTrustChanged '原邀请签名身份与管理服务器不匹配。'};return $body} $script:DeployUI.PairFields.InviteText $m.Info.ManagementSigningPublicKey
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
function InspectPairGrantUI {
 StartJob @{Action='PairGrantInspect';EncryptedAuthorization=$script:DeployUI.PairFields.ReturnText} {param($d)
  if((ServerUIGet $d Verification '') -cne 'Verified'){ErrorDialog '加密返回尚未通过本机原申请核验。';return}
  if(ServerUIGet $d MaterialDigest ''){Import-Module (UIProductPath 'DeploymentPairing.psm1') -DisableNameChecking;if((Get-TCPairMaterialKind -Material $script:DeployUI.PairFields.ReturnText).MaterialDigest -cne $d.MaterialDigest){return}}
  $script:DeployUI.EnrollmentId=[string]$d.EnrollmentId;$script:DeployUI.PairRequest=[string]$d.PairRequest;$script:DeployUI.PairFields.RequestText=[string]$d.PairRequest;$script:DeployUI.PairRequestResult=$d
  $script:DeployUI.PairIntake.Role='Client';$script:DeployUI.PairIntake.Stage='GrantReady';$script:DeployUI.PairIntake.Grant=$d;$script:DeployUI.PairIntake.VerifiedText=$script:DeployUI.PairFields.ReturnText;ShowProductPairing
 } '核对加密返回与这台电脑的原申请…'
}
function CompletePairReturnUI {
 if(ServerUIReadOnly){ErrorDialog '当前为只读检查窗口，未生成候选线路。';return}
 if(-not $script:DeployUI.EnrollmentId){ErrorDialog '请选择本机保存的原申请，不能用另一台电脑的申请接收授权。';return}
 $script:DeployUI.PairIntake.Role='Client'
 if(-not $script:Smoke -and $script:DeployUI.PairFields.ReturnText -and ($script:DeployUI.PairIntake.VerifiedText -cne $script:DeployUI.PairFields.ReturnText -or -not $script:DeployUI.PairIntake.Grant)){InspectPairGrantUI;return}
 StartJob @{Action='PairComplete';EnrollmentId=$script:DeployUI.EnrollmentId;EncryptedAuthorization=$script:DeployUI.PairFields.ReturnText;Name=$script:DeployUI.PairFields.LineName} {param($d)
  $script:DeployUI.PairCompletion=$d;$script:DeployUI.PairIntake.Stage='Completed';ShowProductPairing;Toast '本机候选已生成，请查看线路检查结果'
 } '解密、核对本机身份并生成候选线路…'
}
function GetPairEnrollmentsUI {
 if($script:Smoke){return @()}
 Import-Module (UIProductPath 'DeploymentPairing.psm1') -DisableNameChecking
 return @(Get-TCPairEnrollments -Root $script:Root|Sort-Object CreatedAtUtc -Descending)
}
function ShowProductPairing {
 param([Alias('Role')][ValidateSet('Client','Manager')][string]$PairRole='', [string]$Material='', [string]$Path='')
 if(($PairRole -or -not (ServerUIGet $script:DeployUI PairReturnContext)) -and $script:Role -ne 'product-pair' -and (Get-Command CaptureNavigationContext -ErrorAction SilentlyContinue)){$script:DeployUI.PairReturnContext=CaptureNavigationContext}
 InitializePairingUI;InitializeServerUI;$s=$script:DeployUI.PairIntake
 if($PairRole){$s.Role=$PairRole;$s.Stage=if($PairRole -eq 'Manager'){'Review'}elseif($script:DeployUI.EnrollmentId){'Waiting'}else{'Invite'}}
 elseif($script:Role -eq 'servers'){$s.Role='Manager';$s.Stage='Review'}
 if($PSBoundParameters.ContainsKey('Material')){ReceivePairMaterialUI -Material $Material;return};if($Path){ReceivePairMaterialUI -Path $Path;return}
 RestorePairManagerRequestUI
 if(Get-Variable PairIntakeTimer -Scope Script -ErrorAction SilentlyContinue){$script:PairIntakeTimer.Stop()}
 $script:Role='product-pair';$script:Page='setup'
 if($s.Role -eq 'Manager' -and (ServerUIGet $script:DeployUI EncryptedAuthorization)){$s.Stage='Granted'}
 if($s.Role -eq 'Client' -and $s.Stage -eq 'Invite' -and -not $s.Text -and -not $script:DeployUI.EnrollmentId){
  try{$saved=@(GetPairEnrollmentsUI);if($saved.Count){SelectPairEnrollmentUI $saved[0] -NoRender}}catch{$s.Error=$_.Exception.Message}
 }
 $manager=$s.Role -eq 'Manager'
 Head '' $(if($manager){'核对并批准新电脑'}else{'连接已有服务器'}) $(if($manager){'核对设备申请，批准后把加密返回交给申请电脑。'}else{'使用管理电脑交接的资料，申请和授权保留这台电脑的独立身份。'})
 $card=Card;$p=Stack;$card.Child=$p
 $title=if($manager){if($s.Stage -eq 'Granted'){'加密授权已准备'}else{'核对设备申请'}}else{switch($s.Stage){InviteTrust{'核对邀请来源'} Waiting{'申请已保存，等待管理电脑授权'} Resume{'继续原申请的本机线路准备'} Grant{'核对加密返回'} GrantReady{'原申请已匹配，准备本机线路'} Completed{'查看本机线路结果'} default{'粘贴或打开服务器邀请'}}}
 SetupCardHeader $p $title '' $(if($manager){'key'}else{'laptop'})
 if($s.Stage -notin @('Completed','Granted')){
  $label=if($manager){'新电脑的公开申请'}elseif($s.Stage -in @('Waiting','Resume','Grant','GrantReady')){'管理电脑交回的加密授权'}else{'服务器邀请'}
  $fieldId=if($manager){'PairRequestText'}elseif($s.Stage -in @('Waiting','Resume','Grant','GrantReady')){'PairReturnText'}else{'PairInviteText'}
  $box=DeploymentField $p $label $fieldId $s.Text '粘贴完整资料会自动识别并核验；也可打开交接文件。' -Multiline;$box.MaxLength=128KB;$box.Height=96;$script:Controls.PairMaterialText=$box
  $box.Add_TextChanged({QueuePairMaterialUI $this.Text})
 }
 if($s.Error){AddC $p (ControlName (T $s.Error 13 '#A15C07') 'PairIntakeError')}
 $actions=Stack 'Horizontal'
 if($manager){
  if($s.Stage -eq 'Granted'){
   AddC $p (T '只把加密授权资料交给生成原申请的电脑。返回丢失时使用同一份公开申请取回，不新增设备。' 13 $script:Text2)
   $null=DeploymentActions $actions '复制加密授权给新电脑' 'PairCopyEncrypted' {if(-not $script:Smoke){[Windows.Clipboard]::SetText([string]$script:DeployUI.EncryptedAuthorization)};Toast '已复制加密授权'}
    $null=DeploymentActions $actions '返回这台服务器' 'PairManageServer' {ReturnFromServerChildUI} 'Ghost'
  }else{
   $info=ServerUIGet $script:DeployUI PairRequestInspection;$payload=ServerUIGet $info Payload
   if($payload){AddC $p (T ('设备：'+$payload.DeviceName) 14 $script:Ink 'SemiBold');AddC $p (T ('申请摘要：'+[string](ServerUIGet $info PairingCode '')) 13 $script:Text2);AddC $p (T '请与申请电脑核对设备名称和摘要。该摘要用于人工核对，资料通过文件或完整文本交接。' 12 $script:Text3)}
   $m=$script:DeployUI.Management;$valid=$false;$recover=$false
   if($payload -and $m.Authenticated -and $m.Info){AddC $p (T ('目标服务器：'+[string](ServerUIGet $m.Server Name '已登录的目标服务器')) 13 $script:Ink 'SemiBold')}
   if($payload -and $m.Authenticated -and $m.Info -and $script:DeployUI.PairFields.InviteText -and (ServerUIGet $s TargetMatch '') -notin @('Ambiguous','Missing','Blocked','LiveMismatch')){
    $invite=ServerUIGet $script:DeployUI Invite;$recover=(ServerUIGet $invite State '') -in @('Consumed','Expired')
    if(ServerUIGet $invite ExpiresAtUtc){try{$recover=$recover -or [DateTimeOffset]::Parse($invite.ExpiresAtUtc) -le [DateTimeOffset]::UtcNow}catch{}}
    try{$valid=AssertPairContextUI -AllowExpired:$recover}catch{AddC $p (T $_.Exception.Message 13 '#A15C07')}
   }
   if(-not $payload){$b=DeploymentActions $actions '核对公开申请' 'PairInspectRequest' {ReceivePairMaterialUI -Material $script:DeployUI.PairIntake.Text};$b.IsEnabled=[bool]$s.Text}
   elseif((ServerUIGet $s TargetMatch '') -eq 'Ambiguous'){
    AddC $p (T '本机有多个管理记录对应同一服务器身份，请选择这次使用的管理入口。' 13 $script:Text2)
    $choice=ControlName (New-Object Windows.Controls.ComboBox) 'PairManagerTargetChoice'
    foreach($target in $s.TargetCandidates){$item=New-Object Windows.Controls.ComboBoxItem;$item.Content=[string]$target.Name+' · '+$target.Connection.Host+':'+$target.Connection.Port;$item.Tag=$target.LocalRecordId;$null=$choice.Items.Add($item)}
    AddC $p $choice;$b=DeploymentActions $actions '选择此管理入口并登录' 'PairManageServer' {if($script:Controls.PairManagerTargetChoice.SelectedItem){SelectPairManagerTargetUI ([string]$script:Controls.PairManagerTargetChoice.SelectedItem.Tag)}};$b.IsEnabled=$false
    $choice.Add_SelectionChanged({$script:Controls.PairManageServer.IsEnabled=[bool]$this.SelectedItem})
   }
   elseif((ServerUIGet $s TargetMatch '') -eq 'Unique' -and (-not $m.Authenticated -or -not $m.Info)){
    if(-not $m.Authenticated){AddPairManagerLoginUI $p}
    else{AddC $p (T ('目标服务器：'+[string]$m.Server.Name+'，等待核对服务器真实身份。') 13 $script:Text2)}
    $b=DeploymentActions $actions $(if($m.Authenticated){'读取并核对服务器身份'}else{'登录并核对目标服务器'}) 'PairManageServer' {ConnectPairManagerUI};$b.IsEnabled=(-not $script:DeployUI.PendingManagement -and -not (ServerUIReadOnly))
   }
   elseif((ServerUIGet $s TargetMatch '') -in @('Blocked','LiveMismatch')){$null=DeploymentActions $actions '重新核对目标记录' 'PairManageServer' {ContinuePairManagerReviewUI}}
   elseif(-not $m.Authenticated -or -not $m.Info -or (ServerUIGet $s TargetMatch '') -eq 'Missing'){$null=DeploymentActions $actions '查看服务器记录并核对管理入口' 'PairManageServer' {$script:DeployUI.PairIntake.Role='Manager';OpenServerManagement -ReturnKind Context;LoadServersUI}}
   elseif(-not $script:DeployUI.PairFields.InviteText){$null=DeploymentActions $actions '取回原邀请并核对' 'PairRestoreInvite' {ContinuePairManagerReviewUI}}
   elseif($recover -and $valid){$null=DeploymentActions $actions '取回原申请的授权返回' 'PairRecoverReturn' {RecoverPairReturnUI}}
   else{$b=DeploymentActions $actions '批准这台设备' 'PairAuthorize' {AuthorizePairRequestUI};$b.IsEnabled=$valid}
   $null=DeploymentActions $actions '打开交接文件' 'PairOpenFile' {OpenPairMaterialFileUI} 'Ghost'
  }
 }else{
  switch($s.Stage){
   InviteTrust{
    $d=$script:DeployUI.InviteInspection;AddC $p (ControlName (T ('服务器签名指纹：'+[string](ServerUIGet $d Fingerprint '')) 12 $script:Ink) 'PairInviteFingerprint')
    if(ServerUIGet $d Payload){AddC $p (T ('服务器入口：'+[string](ServerUIGet $d.Payload PublicEndpoint '')) 13 $script:Text2)}
    AddC $p (Note '请与管理电脑核对指纹，或核对可信交接来源。签名完整性不能自行证明首次邀请的来源。')
    $null=PairField $p '这台电脑的名称' 'PairDeviceName' DeviceName
    $null=DeploymentActions $actions '来源已核对，生成申请' 'PairCreateRequest' {CreatePairRequestUI}
   }
   Waiting{
    $code=[string](ServerUIGet (ServerUIGet $script:DeployUI PairRequestResult) PairingCode '')
    AddC $p (T ('本机申请摘要：'+$code) 13 $script:Ink 'SemiBold');AddC $p (Note '把完整公开申请交给管理电脑。返回丢失时再次交接同一份申请，本机保留原设备身份。')
    $null=DeploymentActions $actions '复制公开申请给管理电脑' 'PairCopyRequest' {if(-not $script:Smoke){[Windows.Clipboard]::SetText([string]$script:DeployUI.PairRequest)};Toast '已复制原公开申请'}
   }
   GrantReady{
    AddC $p (T '已核验原申请、接收密钥、服务器签名与设备绑定。' 13 $script:Text2)
    $null=PairField $p '线路名称' 'PairLineName' LineName
    $null=DeploymentActions $actions '生成本机候选线路' 'PairCompleteReturn' {CompletePairReturnUI}
   }
   Resume{
    AddC $p (Note '原申请与已核验的授权保存在这台电脑。可以继续本机准备；收到更新的加密返回时直接粘贴或打开。')
    $null=DeploymentActions $actions '继续本机线路准备' 'PairCompleteReturn' {CompletePairReturnUI}
   }
   Completed{
    $completion=$script:DeployUI.PairCompletion;$state=[string](ServerUIGet $completion DeploymentCompleteness '')
    $missing=@(ServerUIGet $completion MissingProtocols @());$attention=[bool](ServerUIGet $completion AttentionRequired $false)
    $message=if($attention){'线路仍有待处理问题，请查看检查结果并继续处理。'}elseif($state -eq 'Complete'){'UDP / TCP 配置已备齐，网络检查与保存状态请在线路页查看。'}elseif($state -eq 'Partial'){'接入部分完成，缺少 '+(($missing|ForEach-Object {$_.ToUpperInvariant()}) -join ' / ')+'；请让管理电脑补齐后交回原申请的授权。'}else{'本机候选已生成，检查结果请在线路页查看。'}
    AddC $p (ControlName (T $message 13 $(if($attention -or $state -in @('Partial','NeedsRecovery')){'#A15C07'}else{$script:Ink})) 'PairCompletionSummary')
    $null=DeploymentActions $actions '查看这条线路与检查结果' 'PairToNodes' {ShowPairCompletionLineUI}
   }
   default{$b=DeploymentActions $actions '核对交接资料' 'PairInspectInvite' {ReceivePairMaterialUI -Material $script:DeployUI.PairIntake.Text};$b.IsEnabled=[bool]$s.Text}
  }
  $null=DeploymentActions $actions $(if($s.Stage -eq 'Waiting'){'打开加密返回文件'}else{'打开交接文件'}) 'PairOpenFile' {OpenPairMaterialFileUI} 'Ghost'
  try{$enrollments=@(GetPairEnrollmentsUI);if($enrollments.Count -gt 1 -and $s.Stage -in @('Invite','Waiting','Resume')){
   $selector=ControlName (New-Object Windows.Controls.ComboBox) 'PairEnrollmentChoice'
   foreach($entry in $enrollments){$item=New-Object Windows.Controls.ComboBoxItem;$item.Content=(ManagementTime $entry.CreatedAtUtc)+' · '+$entry.PairingCode;$item.Tag=$entry;$null=$selector.Items.Add($item);if($entry.EnrollmentId -eq $script:DeployUI.EnrollmentId){$selector.SelectedItem=$item}}
   $selector.Add_SelectionChanged({if($this.SelectedItem){SelectPairEnrollmentUI $this.SelectedItem.Tag}});AddC $p $selector
  }}catch{AddC $p (T $_.Exception.Message 12 '#A15C07')}
 }
 AddC $p $actions
 if($s.Stage -ne 'Granted'){$null=DeploymentActions $p '返回上一页，保留原申请' 'PairReturnToOrigin' {ReturnFromPairingUI} 'Ghost'}
 if(ServerUIReadOnly){foreach($id in @('PairCreateRequest','PairAuthorize','PairRecoverReturn','PairCompleteReturn')){if($script:Controls.ContainsKey($id)){$script:Controls[$id].IsEnabled=$false}}}
 AddC $script:HostPanel $card
}
function ShowPairCompletionLineUI {
 $id=[string](ServerUIGet $script:DeployUI.PairCompletion Id (ServerUIGet $script:DeployUI.PairCompletion NodeId ''))
 if($id){LoadLineConnections $id}else{ShowNodes;FetchNodes}
}
function ReturnFromPairingUI {
 if($script:DeployUI.PendingManagement){Toast '正在核对原操作，请等待结果后返回。';return}
 $script:DeployUI.Management.ReadContinuation=''
 $context=ServerUIGet $script:DeployUI PairReturnContext
 if($context -and (Get-Command ReturnNavigationContext -ErrorAction SilentlyContinue)){ReturnNavigationContext -Context $context}else{ShowSetupCenter}
}
function SelectPairEnrollmentUI {param($Entry,[switch]$NoRender)
 InitializePairingUI;$script:DeployUI.EnrollmentId=[string]$Entry.EnrollmentId;$script:DeployUI.PairRequest=[string]$Entry.PairRequest;$script:DeployUI.PairRequestResult=$Entry;$script:DeployUI.PairFields.RequestText=[string]$Entry.PairRequest;$script:DeployUI.PairFields.ReturnText=''
 $s=$script:DeployUI.PairIntake;$s.Role='Client';$s.Stage=if(ServerUIGet $Entry HasSavedAuthorization $false){'Resume'}else{'Waiting'};$s.Text='';$s.Grant=$null;$s.VerifiedText='';$s.Error=''
 if(-not $NoRender){ShowProductPairing}
}
function ShowManagementRecovery {
 param([ValidateSet('All','Import','Export')][string]$Mode='All')
 InitializePairingUI;InitializeServerUI
 if($PSBoundParameters.ContainsKey('Mode') -or -not (ServerUIGet $script:DeployUI RecoveryMode)){$script:DeployUI.RecoveryMode=$Mode};$Mode=$script:DeployUI.RecoveryMode
 if($script:Role -ne 'product-recovery' -and (Get-Command CaptureNavigationContext -ErrorAction SilentlyContinue)){$script:DeployUI.RecoveryReturnContext=CaptureNavigationContext}
 $script:Role='product-recovery';$script:Page='setup';Head '' '管理恢复资料' '导出加密资料供电脑丢失或重装时恢复管理；导入后仍需登录核对服务器。'
 $null=DeploymentActions $script:HostPanel '返回上一页' 'RecoveryBack' {$context=ServerUIGet $script:DeployUI RecoveryReturnContext;if($context -and (Get-Command ReturnNavigationContext -ErrorAction SilentlyContinue)){ReturnNavigationContext -Context $context}else{ReturnFromServerChildUI}} 'Ghost'
 $m=$script:DeployUI.Management
 if(-not $m.Server -and $script:DeployUI.Run -and -not $script:Smoke){try{Import-Module (UIProductPath 'ServerRegistry.psm1') -DisableNameChecking;$m.Server=Get-TCServer -Root $script:Root -Id $script:DeployUI.Run.ServerRecordId;$m.ServerId=$m.Server.LocalRecordId}catch{}}
 if($Mode -ne 'Import' -and $m.Server){
 $card=Card;$p=Stack;$card.Child=$p;SetupCardHeader $p '导出当前服务器的管理恢复包' '不包含服务器私钥、其他电脑私钥或交易账户。' 'key'
 AddC $p (T ('目标：'+$m.Server.Name) 13 $script:Ink 'SemiBold')
 AddC $p (Margin (T '恢复包密码（至少 12 个字符）' 12.5 $script:Ink 'SemiBold') '0,12,0,5');$password=ControlName (New-Object Windows.Controls.PasswordBox) 'RecoveryExportPassword';$password.MinHeight=34;AddC $p $password
 $include=ControlName (New-Object Windows.Controls.CheckBox) 'RecoveryIncludeCredential';$include.Content='我选择把 SSH 管理密码 / 私钥也包含在加密包中';$include.Margin='0,12,0,0';AddC $p $include
 $null=PairField $p 'SSH 私钥文件（包含密钥时填写，密码认证留空）' 'RecoveryKeyPath' RecoveryKeyPath
 AddC $p (Margin (T '要包含的 SSH 密码 / 私钥口令' 12.5 $script:Ink 'SemiBold') '0,12,0,5');$credential=ControlName (New-Object Windows.Controls.PasswordBox) 'RecoveryCredential';$credential.MinHeight=34;AddC $p $credential
 $null=DeploymentActions $p '加密导出并保存…' 'RecoveryExport' {ExportRecoveryUI}
 AddC $script:HostPanel (Margin $card '0,0,0,16')
 }
 if($Mode -eq 'Export' -and -not $m.Server){AddC $script:HostPanel (Note '请先在服务器管理中选择需要导出的服务器。');return}
 if($Mode -eq 'Export'){return}
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
