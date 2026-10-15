# Deployment pages: credentials only travel GUI memory -> SID-limited pipe.
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'DeploymentTrust.psm1') -DisableNameChecking
$script:DeployUI=@{Intent='New';Screen='connect';Run=$null;Discovery=$null;SessionRef=$null;SessionAttached=$false;Credential=$null;RememberCredential=$false;LastPoll=[DateTime]::MinValue;TrustShown=$null;ServerId=$null;Server=$null;Management=$null;DeviceResult=$null;Invite=$null;PairRequest=$null;EnrollmentId=$null;PendingManagement=$null}
function NewDeploymentCallbackContext {param([switch]$Session)
 $context=@{Type='Deployment';PageGeneration=(CaptureNavigationContext).Revision;Flow=$script:DeployUI;RunId=[string](ProfileUIField $script:DeployUI.Run 'RunId' '');InstanceId='';AttemptId=[string](ProfileUIField $script:DeployUI 'AccessAttemptId' '')}
 if($Session){$context.InstanceId=[string](ProfileUIField $script:DeployUI.SessionRef 'InstanceId' '')}
 return $context
}
function TestDeploymentCallbackContext {param($Context,[switch]$Session,[switch]$AllowOtherPage)
 if(-not $Context -or -not [object]::ReferenceEquals($script:DeployUI,$Context.Flow)){return $false}
 if(-not $AllowOtherPage -and $script:Role -ne 'deployment'){return $false}
 if([string](ProfileUIField $script:DeployUI.Run 'RunId' '') -cne [string]$Context.RunId){return $false}
 if((ProfileUIField $Context 'AttemptId' '') -and [string]$Context.AttemptId -cne [string](ProfileUIField $script:DeployUI 'AccessAttemptId' '')){return $false}
 if($Session -or $Context.InstanceId){
  if(-not $script:DeployUI.Run -or -not $script:DeployUI.SessionRef -or -not $Context.InstanceId){return $false}
  if([string]$script:DeployUI.SessionRef.RunId -cne [string]$Context.RunId -or [string]$script:DeployUI.SessionRef.InstanceId -cne [string]$Context.InstanceId){return $false}
 }
 return $true
}
function TestDeploymentRunResult {param($Run,$Context)
 return ((TestDeploymentCallbackContext $Context) -and $Run -and [string]$Run.RunId -ceq [string]$Context.RunId)
}
function SetDeploymentWorkerFailure {param([string]$Message,$Context,$Failure)
 if(-not (TestDeploymentCallbackContext $Context)){return}
 $script:DeployUI.PollError=$Message;$script:DeployUI.WorkerFailure=$Failure
 ShowProductDeployment
}
function RetryDeploymentTaskCredentialUI {param($Context)
 if($script:ReadOnly -or (IsBusy) -or -not (TestDeploymentCallbackContext $Context) -or -not $script:DeployUI.Run){return}
 # This is a single nonblocking metadata read. It never decrypts a saved
 # credential, starts a login, or replaces the current editing draft.
 try{
  Import-Module (Join-Path $script:PackageRoot 'DeploymentTransport.psm1') -DisableNameChecking
  $state=Get-TCDeployTaskCredentialState -Root $script:Root -RunId $script:DeployUI.Run.RunId -InfoOnly
 }catch{$state=[pscustomobject]@{Status='TemporarilyUnavailable';Available=$false;Retryable=$true;ReasonCode='CredentialTemporarilyUnavailable'}}
 $script:DeployUI.TaskCredentialReadState=$state;$script:DeployUI.TaskCredentialReadRetried=$true
 $script:DeployUI.TaskCredentialAvailable=[bool]$state.Available
 ShowProductDeployment
}
function AddDeploymentTaskCredentialReadNoticeUI {param($Parent)
 $state=ProfileUIField $script:DeployUI 'TaskCredentialReadState'
 if(-not $state){return}
 if([string]$state.Status -ceq 'TemporarilyUnavailable'){
  AddC $Parent (ControlName (Notice 'warn' '本机登录资料暂不可读' '本机登录资料暂时被占用，已保存资料和正在输入的内容均保留。可重试读取，或继续输入本次登录资料。') 'DeployCredentialReadNotice')
  $retry=DeploymentActions $Parent '重试读取登录资料' 'DeployRetryTaskCredential' {RetryDeploymentTaskCredentialUI $this.Tag} 'Ghost'
  $retry.Tag=NewDeploymentCallbackContext;$retry.IsEnabled=(-not $script:ReadOnly)
 }elseif(ProfileUIField $script:DeployUI 'TaskCredentialReadRetried' $false){
  if($state.Available){AddC $Parent (ControlName (Notice 'info' '登录资料已可用' '已重新读取本任务保存的登录资料。当前输入和选择保持不变，点击登录后才会使用。') 'DeployCredentialReadNotice')}
  else{AddC $Parent (ControlName (Notice 'warn' '请填写本次登录资料' '原登录资料已过期、不可用或与当前目标不符。当前输入保留，请使用本次密码或私钥继续。') 'DeployCredentialReadNotice')}
 }
}
function GetDeploymentCredentialDraftUI {
 if(-not $script:DeployUI.CredentialDraft){$script:DeployUI.CredentialDraft=@{Secret=(New-Object Security.SecureString);Revision=0;Revealed=$false;Updating=$false;SelectionStart=0;SelectionLength=0}}
 return $script:DeployUI.CredentialDraft
}
function GetDeploymentPasswordSelectionUI {param($Box)
 # WPF exposes no public PasswordBox caret API. Inspect only selection offsets,
 # never its text; an unfamiliar WPF version falls back to the end of the input.
 $start=$Box.SecurePassword.Length;$length=0
 try{
  $flags=[Reflection.BindingFlags]'Instance,Public,NonPublic'
  $selection=$Box.GetType().GetProperty('Selection',$flags).GetValue($Box,$null)
  $a=$selection.GetType().GetProperty('System.Windows.Documents.ITextSelection.AnchorPosition',$flags).GetValue($selection,$null)
  $b=$selection.GetType().GetProperty('System.Windows.Documents.ITextSelection.MovingPosition',$flags).GetValue($selection,$null)
  $anchor=[int]$a.GetType().GetProperty('Offset',$flags).GetValue($a,$null);$moving=[int]$b.GetType().GetProperty('Offset',$flags).GetValue($b,$null)
  $start=[math]::Min($anchor,$moving);$length=[math]::Abs($moving-$anchor)
 }catch{}
 return @{Start=$start;Length=$length}
}
function SetDeploymentPasswordVisibilityUI {param([bool]$Visible,[switch]$Focus)
 $draft=$script:DeployUI.CredentialDraft;$box=$script:DeployUI.PasswordControl;$plainBox=$script:DeployUI.PasswordRevealControl
 if(-not $draft -or -not $box -or -not $plainBox){return}
 $draft.Updating=$true
 try{
  if($Visible){
   $selection=GetDeploymentPasswordSelectionUI $box;$draft.SelectionStart=$selection.Start;$draft.SelectionLength=$selection.Length
   $pointer=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($box.SecurePassword)
   try{$plainBox.Text=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)}finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)}
   $box.Visibility='Collapsed';$plainBox.Visibility='Visible';$plainBox.Select($draft.SelectionStart,$draft.SelectionLength)
   if($Focus){$null=$plainBox.Focus()}
  }else{
   if($draft.Revealed){$draft.SelectionStart=$plainBox.SelectionStart;$draft.SelectionLength=$plainBox.SelectionLength}
   $plainBox.Visibility='Collapsed';$box.Visibility='Visible';$plainBox.Clear()
   try{$flags=[Reflection.BindingFlags]'Instance,NonPublic';$null=$box.GetType().GetMethod('Select',$flags).Invoke($box,@([int]$draft.SelectionStart,[int]$draft.SelectionLength))}catch{}
   if($Focus){$null=$box.Focus()}
  }
  $draft.Revealed=$Visible
  if($script:DeployUI.PasswordRevealButton){$script:DeployUI.PasswordRevealButton.Content=if($Visible){'隐藏密码'}else{'显示密码'};[Windows.Automation.AutomationProperties]::SetName($script:DeployUI.PasswordRevealButton,[string]$script:DeployUI.PasswordRevealButton.Content)}
 }finally{$draft.Updating=$false}
}
function ClearDeploymentCredentialDraftUI {
 SetDeploymentPasswordVisibilityUI $false
 $draft=$script:DeployUI.CredentialDraft;if($draft){$draft.Updating=$true}
 try{
  if($script:DeployUI.PasswordControl){$script:DeployUI.PasswordControl.Clear()}
  if($script:DeployUI.PasswordRevealControl){$script:DeployUI.PasswordRevealControl.Clear()}
  if($draft){if($draft.Secret){$draft.Secret.Dispose()};$draft.Secret=New-Object Security.SecureString;$draft.Revision++;$draft.SelectionStart=0;$draft.SelectionLength=0}
 }finally{if($draft){$draft.Updating=$false}}
}
function AddDeploymentPasswordEditorUI {param($Parent)
 $draft=GetDeploymentCredentialDraftUI
 if(-not $script:DeployUI.PasswordEditor){
  $editor=New-Object Windows.Controls.Grid
  $inputColumn=New-Object Windows.Controls.ColumnDefinition;$inputColumn.Width='*';$editor.ColumnDefinitions.Add($inputColumn)
  $buttonColumn=New-Object Windows.Controls.ColumnDefinition;$buttonColumn.Width='Auto';$editor.ColumnDefinitions.Add($buttonColumn)
  $box=New-Object Windows.Controls.PasswordBox;$box.MinHeight=34;$box.MaxLength=4096;$box.Tag=$script:DeployUI
  $plain=New-Object Windows.Controls.TextBox;$plain.MinHeight=34;$plain.MaxLength=4096;$plain.Visibility='Collapsed';$plain.Tag=$script:DeployUI
  $box.Add_PasswordChanged({
   if(-not [object]::ReferenceEquals($script:DeployUI,$this.Tag)){return};$d=GetDeploymentCredentialDraftUI;if($d.Updating){return}
   if($d.Secret){$d.Secret.Dispose()};$d.Secret=$this.SecurePassword.Copy();$d.Revision++
  })
  $plain.Add_TextChanged({
   if(-not [object]::ReferenceEquals($script:DeployUI,$this.Tag)){return};$d=GetDeploymentCredentialDraftUI;if($d.Updating){return}
   $d.Updating=$true
   try{$script:DeployUI.PasswordControl.Password=$this.Text;if($d.Secret){$d.Secret.Dispose()};$d.Secret=$script:DeployUI.PasswordControl.SecurePassword.Copy();$d.Revision++}finally{$d.Updating=$false}
  })
  $toggle=Btn '显示密码' 'DeployPasswordReveal' {SetDeploymentPasswordVisibilityUI (-not (GetDeploymentCredentialDraftUI).Revealed) -Focus} 'Btn';$toggle.Margin='8,0,0,0';$toggle.MinWidth=88
  [Windows.Controls.Grid]::SetColumn($toggle,1);$editor.Children.Add($box)|Out-Null;$editor.Children.Add($plain)|Out-Null;$editor.Children.Add($toggle)|Out-Null
  $script:DeployUI.PasswordEditor=$editor;$script:DeployUI.PasswordControl=$box;$script:DeployUI.PasswordRevealControl=$plain;$script:DeployUI.PasswordRevealButton=$toggle
 }
 $editor=$script:DeployUI.PasswordEditor;if($editor.Parent -is [Windows.Controls.Panel]){$editor.Parent.Children.Remove($editor)}
 $null=ControlName $script:DeployUI.PasswordControl 'DeployPassword';$null=ControlName $script:DeployUI.PasswordRevealControl 'DeployPasswordPlainText';$null=ControlName $script:DeployUI.PasswordRevealButton 'DeployPasswordReveal'
 AddC $Parent $editor
}
function ClearDeploymentCredentialUI {param([switch]$KeepDraft,[switch]$ForgetTask)
 if($ForgetTask -and $script:DeployUI.Run -and -not $script:Smoke){
  try{Import-Module (Join-Path $script:PackageRoot 'DeploymentTransport.psm1') -DisableNameChecking;$null=Remove-TCDeployTaskCredential -Root $script:Root -RunId $script:DeployUI.Run.RunId -CredentialRevision ([string](ProfileUIField $script:DeployUI 'CredentialRevision' ''))}catch{$script:DeployUI.CredentialStorageError='任务登录资料未能清除，请通过本机资料清理重试。'}
 }
  if($ForgetTask){$script:DeployUI.TaskCredentialAvailable=$false;if($script:Controls -and $script:Controls.ContainsKey('DeployUseTaskCredential')){$script:Controls.DeployUseTaskCredential.IsChecked=$false;$script:Controls.DeployUseTaskCredential.IsEnabled=$false}}
 $script:DeployUI.Credential=$null;$script:DeployUI.CredentialBinding=$null;$script:DeployUI.CredentialExpiresAt=$null
 if(-not $KeepDraft){ClearDeploymentCredentialDraftUI}
}
function SetDeploymentAccessFailureUI {param($Issue)
 if(-not $Issue){return}
 Import-Module (Join-Path $script:PackageRoot 'DeploymentTransport.psm1') -DisableNameChecking
 $instance=[string](ProfileUIField $Issue 'SessionInstanceId' (ProfileUIField $script:DeployUI.SessionRef 'InstanceId' ''))
 $generation=[int](ProfileUIField $Issue 'AuthenticationGeneration' 0)
 $signature=[string](ProfileUIField $script:DeployUI.Run 'RunId' '')+':'+$instance+':'+$generation+':'+[string](ProfileUIField $Issue 'Code' '')
 if([string](ProfileUIField $script:DeployUI 'AppliedCredentialFailure' '') -ceq $signature){return}
 $script:DeployUI.AppliedCredentialFailure=$signature
 $diagnostic=Get-TCDeployAccessDiagnostic -Code ([string](ProfileUIField $Issue 'Code' ''))
 if($diagnostic.ClearCredential -or ($diagnostic.Kind -eq 'IdentityChanged' -and -not $script:DeployUI.CredentialFresh)){ClearDeploymentCredentialUI -KeepDraft -ForgetTask}
}
function DeploymentAccessInProgressUI {
 if($script:DeployUI.SessionStarting -or $script:DeployUI.TrustAuthenticating -or $script:DeployUI.SessionAttaching){return $true}
 if((ProfileUIField $script:DeployUI.Run 'AccessIssue') -or $script:DeployUI.PollError -or $script:DeployUI.WorkerFailure){return $false}
 $snapshot=ProfileUIField $script:DeployUI 'AccessSnapshot'
 return ($snapshot -and $script:DeployUI.SessionRef -and [string]$snapshot.InstanceId -ceq [string]$script:DeployUI.SessionRef.InstanceId -and [string]$snapshot.Status -in @('Starting','Connecting','Authenticating'))
}
function SetDeploymentAccessRunUI {param($Run,$Context)
 if(-not (TestDeploymentRunResult $Run $Context)){return}
 $script:DeployUI.Run=$Run;$script:DeployUI.PollError='';$script:DeployUI.WorkerFailure=$null
 $issue=ProfileUIField $Run 'AccessIssue'
 if($issue){$script:DeployUI.ReconnectMessage='';$script:DeployUI.AccessSnapshot=$null;SetDeploymentAccessFailureUI $issue}
 ShowProductDeployment
 if([string](ProfileUIField $issue 'Kind' '') -eq 'FirstTrust'){ShowDeploymentFirstTrustUI -Automatic}
}
function RegisterDeploymentAccessAttemptUI {
 $script:DeployUI.LastAccessSignature=''
 StartJob @{Action='DeploymentAccessState';RunId=$script:DeployUI.Run.RunId;SessionRef=$script:DeployUI.SessionRef;AttemptOnly=$true} {param($run,$context)SetDeploymentAccessRunUI $run $context} '读取本次服务器登录状态…' -CallbackContext (NewDeploymentCallbackContext -Session) -Failed {param($message,$context,$failure)SetDeploymentWorkerFailure $message $context $failure}
}
function ResolveDeploymentTrustUI {param($Server)
 if(-not (Get-Variable -Name DeploymentTrustDecisions -Scope Script -ErrorAction SilentlyContinue)){$script:DeploymentTrustDecisions=@{}}
 $id=[string]$script:DeployUI.Run.RunId;$decision=$script:DeploymentTrustDecisions[$id]
 if($decision -and -not (Test-TCFirstTrustDecision $decision $id $Server.LocalRecordId $Server.Connection)){$script:DeploymentTrustDecisions.Remove($id);$decision=$null}
 Resolve-TCDeploymentPinnedFingerprint -SavedPin ([string]$Server.PinnedHostKey) -Decision $decision -RunId $id -ServerRecordId $Server.LocalRecordId -Connection $Server.Connection
}
function DeploymentAccessContextUI {param($Server,[string]$Reason='InitialAttempt',$Previous=$null)
 # ResolveDeploymentTrustUI must have already checked conflicts and expiry.
 $decision=$null
 if(Get-Variable DeploymentTrustDecisions -Scope Script -ErrorAction SilentlyContinue){$decision=$script:DeploymentTrustDecisions[[string]$script:DeployUI.Run.RunId]}
 $id='';$origin='None'
 if($Server.PinnedHostKey){$origin='AuthenticatedPin'}elseif($decision){$id=[string]$decision.TrustDecisionId;$origin='ExplicitUserConfirmation'}
 @{TrustDecisionId=$id;TrustOrigin=$origin;RetryReason=$Reason;RetryCount=[int](ProfileUIField $script:DeployUI 'AutomaticLoginRetries' 0);PriorInstanceId=[string](ProfileUIField $Previous 'InstanceId' '')}
}
function ShowDeploymentFirstTrustUI {param([switch]$Automatic)
 if($script:ReadOnly -or (IsBusy) -or -not $script:DeployUI.Run){return}
 $issue=ProfileUIField $script:DeployUI.Run 'AccessIssue';$ref=$script:DeployUI.SessionRef
 if([string](ProfileUIField $issue 'Kind' '') -ne 'FirstTrust'){return}
 if(-not $ref -or [string](ProfileUIField $issue 'SessionInstanceId' '') -cne [string]$ref.InstanceId -or -not $script:DeployUI.Credential -or -not $script:DeployUI.CredentialExpiresAt -or [DateTimeOffset]$script:DeployUI.CredentialExpiresAt -le [DateTimeOffset]::UtcNow){
  if(-not $Automatic){ClearDeploymentCredentialUI -KeepDraft;$script:DeployUI.Reauth=$true;$script:DeployUI.PollError='登录会话已结束或资料已过期，请重新登录后核对服务器身份。';ShowProductDeployment}
  return
 }
 $fingerprint=[string](ProfileUIField $issue 'ObservedFingerprint' '');$target=ProfileUIField $issue 'Connection'
 if($fingerprint -cnotmatch '^SHA256:[A-Za-z0-9+/]{43}$' -or -not $target){$script:DeployUI.PollError='服务器身份信息尚不完整，请重新读取本次登录状态。';$script:DeployUI.LastAccessSignature='';return}
 if($Automatic -and $script:DeployUI.TrustShown -ceq $fingerprint -and [string]$script:DeployUI.TrustShownInstanceId -ceq [string]$ref.InstanceId){return}
 $script:DeployUI.TrustShown=$fingerprint;$script:DeployUI.TrustShownInstanceId=[string]$ref.InstanceId
 $context=NewDeploymentCallbackContext -Session
 $context.ServerRecordId=[string]$script:DeployUI.Run.ServerRecordId;$context.Fingerprint=$fingerprint
 $context.Connection=@{Host=[string]$target.Host;Port=[int]$target.Port;User=[string]$target.User}
 OpenDialog '确认首次服务器身份' ('目标：'+$target.User+'@'+$target.Host+':'+$target.Port+[Environment]::NewLine+'SSH 指纹：'+$fingerprint) '通过云控制台等可信来源核对；没有来源时，这是明确的首次信任决定。关闭窗口会继续等待，不会自动登录。' '我已核对，信任此目标' {
  param($context)
  if($script:ReadOnly -or (IsBusy)){return}
  $current=ProfileUIField $script:DeployUI.Run 'AccessIssue'
  if(-not (TestDeploymentCallbackContext $context -Session) -or [string]$script:DeployUI.Run.ServerRecordId -cne $context.ServerRecordId -or [string](ProfileUIField $current 'Kind' '') -ne 'FirstTrust' -or [string](ProfileUIField $current 'SessionInstanceId' '') -cne $context.InstanceId -or [string](ProfileUIField $current 'ObservedFingerprint' '') -cne $context.Fingerprint){ErrorDialog '服务器或身份预览已变化，请重新核对。';return}
  Import-Module (Join-Path $script:PackageRoot 'ServerRegistry.psm1') -DisableNameChecking
  $server=Get-TCServer -Root $script:Root -Id $context.ServerRecordId
  foreach($key in @('Host','Port','User')){if([string]$server.Connection.$key -cne [string]$context.Connection[$key]){ErrorDialog '登录目标已变化，请重新核对服务器身份。';return}}
  if($server.PinnedHostKey){ErrorDialog '服务器已经有已保存身份，请刷新当前接入状态。';return}
  if(-not (TestDeploymentCredentialUI $server)){ClearDeploymentCredentialUI -KeepDraft;$script:DeployUI.Reauth=$true;$script:DeployUI.PollError='登录资料已过期，请重新登录后继续。';ShowProductDeployment;return}
  try{
   $pin=ResolveDeploymentTrustUI $server
   if($pin -and $pin -cne $context.Fingerprint){throw '[TC:TrustIdentityConflict] 本次服务器指纹与刚才确认的身份不同，请核对目标。'}
   if(-not $pin){$script:DeploymentTrustDecisions[$context.RunId]=New-TCFirstTrustDecision -RunId $context.RunId -ServerRecordId $context.ServerRecordId -Connection $server.Connection -Fingerprint $context.Fingerprint}
  }catch{ErrorDialog $_.Exception.Message;return}
  $script:DeployUI.AccessAttemptId=[guid]::NewGuid().ToString();$context.AttemptId=$script:DeployUI.AccessAttemptId
  $script:DeployUI.MinimumAuthenticationGeneration=[int](ProfileUIField $current 'AuthenticationGeneration' 0)+1
  $script:DeployUI.TrustAuthenticating=$true;$script:DeployUI.AccessSnapshot=$null;$script:DeployUI.ReconnectMessage='';$script:DeployUI.PollError=''
  ShowProductDeployment
  $accessContext=DeploymentAccessContextUI $server 'FirstTrustConfirmed'
  StartUiCommand -Module 'DeploymentTransport.psm1' -Command 'Set-TCDeployCredential' -Arguments @{SessionRef=$script:DeployUI.SessionRef;Connection=$server.Connection;Credential=$script:DeployUI.Credential;PinnedFingerprint=$context.Fingerprint;AccessContext=$accessContext} -Context $context -Complete {
   param($result,$context);$context.Flow.TrustAuthenticating=$false
   if(-not (TestDeploymentCallbackContext $context -Session)){return}
   $script:DeployUI.AccessSnapshot=@{InstanceId=$context.InstanceId;Status='Authenticating'};$script:DeployUI.LastPoll=[DateTime]::MinValue
   RegisterDeploymentAccessAttemptUI
  } -Failed {
   param($message,$context);$context.Flow.TrustAuthenticating=$false
   if(TestDeploymentCallbackContext $context -Session){$script:DeployUI.AccessSnapshot=$null;$script:DeployUI.PollError=$message;$script:DeployUI.LastAccessSignature='';ShowProductDeployment;ErrorDialog $message}
  } -Message '正在按已确认的身份登录服务器…'
 } '稍后确认' 'Primary' $context
}
function DeploymentCredentialScopeUI {param($Server)
 [ordered]@{RunId=[string]$script:DeployUI.Run.RunId;ServerRecordId=[string]$Server.LocalRecordId;Host=[string]$Server.Connection.Host;Port=[int]$Server.Connection.Port;User=[string]$Server.Connection.User;PinnedFingerprint=[string]$Server.PinnedHostKey}
}
function TestDeploymentCredentialUI {param($Server)
 if(-not $script:DeployUI.Credential -or -not $script:DeployUI.CredentialExpiresAt){return $false}
 if([DateTimeOffset]$script:DeployUI.CredentialExpiresAt -le [DateTimeOffset]::UtcNow){ClearDeploymentCredentialUI -KeepDraft;return $false}
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
 if($script:DeployUI.CredentialBinding){ClearDeploymentCredentialUI -KeepDraft;return $false}
 if($script:DeployUI.Credential){ClearDeploymentCredentialUI -KeepDraft}
 try{
  $task=Get-TCDeployTaskCredential -Root $script:Root -RunId $script:DeployUI.Run.RunId
  if($task){$script:DeployUI.Credential=$task.Credential;$script:DeployUI.CredentialFresh=$false;$script:DeployUI.CredentialRevision=$task.CredentialRevision;$script:DeployUI.RememberCredential=$true;$script:DeployUI.CredentialBinding=DeploymentCredentialScopeUI $server;$script:DeployUI.CredentialExpiresAt=[DateTimeOffset]$task.ExpiresAtUtc;return $true}
 }catch{if($_.Exception.Message -like '*CredentialTemporarilyUnavailable*'){$script:DeployUI.PollError='本机登录资料暂时被占用，可重试读取';return $false}}
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
 $script:DeployUI.RetryReasonCode=[string](ProfileUIField (ProfileUIField $script:DeployUI.Run 'AccessIssue') 'Code' 'UserRetry')
 $script:DeployUI.Reauth=$false;$script:DeployUI.ReconnectMessage='正在重新连接服务器；已完成步骤会保留。'
 StartDeploymentSessionUI -ReuseCredential
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
function AddDeploymentWorkerFailure {param($Parent)
 $failure=ProfileUIField $script:DeployUI 'WorkerFailure';if(-not $failure){return}
 $context=@{RunId=[string](ProfileUIField $script:DeployUI.Run 'RunId' '');LineId=[string](ProfileUIField $script:DeployUI.Run 'CandidateNodeId' '');Flow=$script:DeployUI}
 $button=DeploymentActions $Parent '查看处理办法与技术详情' 'DeployWorkerFailure' {ShowUiWorkerFailure $this.Tag.Failure $this.Tag.Context} 'Btn'
 $button.Tag=@{Failure=$failure;Context=$context}
}
function AddDeploymentCredentialNoticeUI {param($Parent)
 $message=[string](ProfileUIField $script:DeployUI 'CredentialStorageError' '')
 $cleanup=[string](ProfileUIField $script:DeployUI 'CredentialCleanupNotice' '')
 if($cleanup){$message=(@($message,$cleanup|Where-Object {$_}) -join [Environment]::NewLine)}
 if($message){AddC $Parent (ControlName (Notice 'warn' '任务登录资料需要处理' $message) 'DeployCredentialStorageNotice')}
}
function AddDeploymentAbandonActionUI {param($Parent)
 $run=$script:DeployUI.Run
 if(-not $run -or $run.Stage -eq 'ReadyInactive' -or (DeploymentLocalCheckPending $run) -or (DeploymentAccessInProgressUI)){return}
 if(-not $script:DeployUI.Reauth -and $run.Status -notin @('Idle','WaitingUser','Failed','OutcomeUnknown','NeedsRecovery','Cancelled')){return}
 $button=DeploymentActions $Parent '放弃本次准备并清理本机资料…' 'DeployAbandonLocal' {
  if((IsBusy) -or $script:ReadOnly -or [string](ProfileUIField $script:DeployUI.Run 'RunId' '') -cne [string]$this.Tag){return}
  DeleteOperationRecordsUI -Ids @('DeploymentRun:'+ [string]$this.Tag)
 } 'Ghost'
 $button.Tag=[string]$run.RunId;$button.IsEnabled=(-not $script:ReadOnly)
}
function BeginProductDeployment {param([string]$Intent='Auto',[string]$ServerId)
 if($script:DeployUI.Run -and $script:DeployUI.Run.Status -in @('Running','Dispatching')){ErrorDialog '当前部署尚未完成，请先查询结果或安全取消。';return}
 $returnContext=if($script:Role -ne 'deployment'){CaptureNavigationContext}else{$script:DeployUI.DeploymentReturnContext}
 ClearDeploymentCredentialUI
 # A wizard owns its callbacks. Detaching it never changes the old run or
 # closes an executor whose remote operation may still be unsettled.
 $script:DeployUI=@{Intent=$Intent;Screen='connect';Run=$null;Discovery=$null;SessionRef=$null;SessionAttached=$false;Credential=$null;RememberCredential=$false;LastPoll=[DateTime]::MinValue;TrustShown=$null;ServerId=$ServerId;Server=$null;Management=$null;PendingManagement=$null;ManagementMode=$false;Reauth=$false;LastAccessSignature='';ReconnectMessage='';AutomaticLoginRetries=0;PasswordControl=$null;FormDraft=@{};ChooseNetwork=$false;DeploymentReturnContext=$returnContext}
 $script:Role='deployment';$script:Step=1
 # A new form is immediately editable. Discovery supplies context, not a new
 # form: replacing its controls interrupts keyboard focus and IME composition.
 # A selected server needs its defaults first; do not offer a blank form that
 # will either lose edits or overwrite the discovered address with that blank.
 if($ServerId){$script:Page='setup';Head '' '读取服务器资料' '正在恢复所选服务器的地址与登录设置…'}else{ShowProductDeployment}
 StartJob @{Action='DeploymentDiscover'} {
  param($d,$context)
  if(-not (TestDeploymentCallbackContext $context)){return}
  $script:DeployUI.Discovery=$d
  if($script:DeployUI.ServerId){ShowProductDeployment}
 } '读取已有线路与部署进度…' '' -Silent -CallbackContext (NewDeploymentCallbackContext) -Failed {
  param($message,$context,$failure)
  if(-not (TestDeploymentCallbackContext $context)){return}
  if($script:DeployUI.ServerId){SetDeploymentWorkerFailure $message $context $failure}
  else{ErrorDialog $message}
 }
}
function FocusDeploymentField {
 # Bring a validation target into view and focus it. The dialog covers the form,
 # so without this a beginner closes the dialog and still cannot find the field.
 param([string]$Id)
 if(-not $Id -or -not $script:Controls.ContainsKey($Id)){return}
 $control=$script:Controls[$Id]
 try{
  $script:Window.UpdateLayout()
  $control.BringIntoView()
  $script:Window.UpdateLayout()
  $null=$control.Focus()
 }catch{}
}
function ShowProductDeployment {
 if($script:Controls.ContainsKey('DeployConnectionText') -and [object]::ReferenceEquals($script:DeploymentRenderedFlow,$script:DeployUI)){
  $draft=@{};foreach($key in @('DeployConnectionText','DeployName','DeployUser','DeployPort','DeployKeyPath','DeployTcpPort','DeployServerName')){if($script:Controls.ContainsKey($key)){$draft[$key]=$script:Controls[$key].Text}}
  if($script:Controls.ContainsKey('DeployLoginMethod')){$draft.LoginMethod=$script:Controls.DeployLoginMethod.SelectedIndex}
  if($script:Controls.ContainsKey('DeployRemember')){$draft.RememberTask=[bool]$script:Controls.DeployRemember.IsChecked}
  if($script:Controls.ContainsKey('DeployUseTaskCredential')){$draft.UseTaskCredential=[bool]$script:Controls.DeployUseTaskCredential.IsChecked}
  if($script:Controls.ContainsKey('DeployUseSaved')){$draft.UseSavedCredential=[bool]$script:Controls.DeployUseSaved.IsChecked}
  if($script:Controls.ContainsKey('DeployTransport')){$draft.TransportIndex=$script:Controls.DeployTransport.SelectedIndex};$script:DeployUI.FormDraft=$draft
  if($script:Controls.ContainsKey('DeployPassword')){$script:DeployUI.PasswordControl=$script:Controls.DeployPassword}
 }
 $script:Page='setup';$script:Role='deployment';$pageTitle='准备连接'
 if($script:DeployUI.Reauth){$pageTitle='修改登录资料'}
 if($script:DeployUI.Run -and -not $script:DeployUI.Reauth){
  $access=ProfileUIField $script:DeployUI.Run 'AccessIssue'
  if(DeploymentAccessInProgressUI){$pageTitle='正在连接服务器'}
  elseif($access -or $script:DeployUI.Run.Stage -eq 'PrepareAccess'){$pageTitle=(ProfileDeploymentDecision (DeploymentLineView $script:DeployUI.Run) $script:DeployUI.Run).Title}
  elseif($script:DeployUI.Run.Status -eq 'Failed'){$pageTitle='部署已停止'}
 }
 Head '' $pageTitle '同一条线路准备 UDP 和 TCP，准备状态与网络检查分别显示。'
 if(ProfileUIField $script:DeployUI 'Identity'){ShowDeploymentIdentity;return}
 if($script:DeployUI.Run -and -not $script:DeployUI.Reauth){SetDeploymentPasswordVisibilityUI $false;ShowDeploymentRun;return}
 $card=Card;$p=Stack;$card.Child=$p
 if($script:DeployUI.Intent -in @('New','Auto')){
  if($script:DeployUI.Run){SetupCardHeader $p '继续原部署' '已恢复服务器资料；登录后从已保存的步骤继续。' 'laptop'}else{SetupCardHeader $p '添加线路' '软件检查本机和服务器状态，自动准备两端连接。' 'laptop'}
  if(-not $script:DeployUI.Run){
   AddC $p (Note '推荐环境：Ubuntu 24.04 或 Debian 13 x64 专用 VPS，管理员或已有免交互 sudo 的账户。购买和云端规则在厂商控制台完成。')
   $null=DeploymentActions $p '我还没有服务器：查看购买准备' 'PurchasePreparation' {ShowPurchasePreparation} 'Ghost'
  }
 }else{SetupCardHeader $p '准备这条线路' '复用已有组件和有效偏好，现有连接继续使用。' 'server'}
 $issue=ProfileUIField $script:DeployUI.Run 'AccessIssue'
 if($issue){
  $decision=ProfileDeploymentDecision (DeploymentLineView $script:DeployUI.Run) $script:DeployUI.Run
  $reason=[string](ProfileUIField (ProfileUIField $script:DeployUI.Run 'LastError') 'Message' $decision.Message)
  AddC $p (ControlName (Notice 'warn' $decision.Title $reason) 'DeployLoginFailure')
  $target=ProfileUIField $issue 'Connection';if($target){AddC $p (ControlName (T ('本次目标：'+$target.User+'@'+$target.Host+':'+$target.Port) 12.5 $script:Text2) 'DeployLoginTarget')}
  $diagnostic=ControlName (New-Object Windows.Controls.Expander) 'DeployLoginDetails';$diagnostic.Header='本次登录详情';$diagnostic.Margin='0,6,0,0'
  $diagnostic.Content=ControlName (T ('错误编号：'+[string](ProfileUIField $issue 'Code' '')+' · '+[string](ProfileUIField $issue 'RecordedAtUtc' '')) 11.5 $script:Text3) 'DeployLoginErrorCode';AddC $p $diagnostic
 }elseif($script:DeployUI.Run -and $script:DeployUI.Run.Status -eq 'Failed'){AddC $p (Notice 'warn' '上次部署已停止' ((DeploymentStageLabel $script:DeployUI.Run.Stage)+'未完成。已有进度保留，恢复登录后继续原任务。'))}
 if(ProfileUIField $script:DeployUI 'PollError'){AddC $p (ControlName (Notice 'warn' '此步骤未完成' $script:DeployUI.PollError) 'DeployStepError');AddDeploymentWorkerFailure $p}
 AddDeploymentCredentialNoticeUI $p
 AddDeploymentTaskCredentialReadNoticeUI $p
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
 AddDeploymentPasswordEditorUI $p
 $method.Add_SelectionChanged({if($script:Controls.ContainsKey('DeployCredentialLabel')){$script:Controls.DeployCredentialLabel.Text=if($this.SelectedIndex -eq 1){'SSH 私钥解密口令（密钥未加密时留空）'}else{'服务器登录密码'};ClearDeploymentCredentialUI -ForgetTask}})
 $remember=ControlName (New-Object Windows.Controls.CheckBox) 'DeployRemember';$remember.Content='任务期间记住登录，完成后清除（最长 24 小时）';$remember.IsChecked=$(if($form.ContainsKey('RememberTask')){[bool]$form.RememberTask}else{$true});$remember.Margin='0,10,0,0';AddC $p $remember
  if($script:DeployUI.TaskCredentialAvailable -or ((ProfileUIField (ProfileUIField $script:DeployUI 'TaskCredentialReadState') 'Status' '') -eq 'TemporarilyUnavailable' -and $form.ContainsKey('UseTaskCredential'))){$savedTask=ControlName (New-Object Windows.Controls.CheckBox) 'DeployUseTaskCredential';$savedTask.Content='使用本任务已加密保存的登录资料；重新输入或选择密钥将替换它';$savedTask.IsChecked=$(if($form.ContainsKey('UseTaskCredential')){[bool]$form.UseTaskCredential}else{-not [bool](ProfileUIField $script:DeployUI 'TaskCredentialKeyChanged' $false)});$savedTask.IsEnabled=[bool]$script:DeployUI.TaskCredentialAvailable;if(-not $savedTask.IsEnabled){$savedTask.ToolTip='登录资料暂不可读，请先重试读取。'};$savedTask.Margin='0,8,0,0';AddC $p $savedTask}
  if($server -and $server.CredentialRef){$useSaved=ControlName (New-Object Windows.Controls.CheckBox) 'DeployUseSaved';$useSaved.Content='使用这台服务器已加密保存的管理凭据';$useSaved.IsChecked=$(if($form.ContainsKey('UseSavedCredential')){[bool]$form.UseSavedCredential}else{[string](ProfileUIField (ProfileUIField $script:DeployUI.Run 'AccessIssue') 'Kind' '') -notin @('Credentials','PrivateKey','IdentityChanged')});$useSaved.Margin='0,8,0,0';AddC $accessPanel $useSaved}
 $accessExpander=ControlName (New-Object Windows.Controls.Expander) 'DeployAccessAdvanced';$accessExpander.Header='登录账户、密钥与名称';$accessExpander.Content=$accessPanel;$accessExpander.Margin='0,14,0,0';$accessExpander.IsExpanded=($method.SelectedIndex -eq 1);AddC $p $accessExpander
 $method.Add_SelectionChanged({if($script:Controls.ContainsKey('DeployAccessAdvanced') -and $this.SelectedIndex -eq 1){$script:Controls.DeployAccessAdvanced.IsExpanded=$true}})
 $mode=ControlName (New-Object Windows.Controls.ComboBox) 'DeployTransport'
 foreach($option in @(@('自动推荐（默认）','Auto'),@('默认 UDP（手动指定）','Udp'),@('默认 TCP（手动指定）','Tcp'))){$item=New-Object Windows.Controls.ComboBoxItem;$item.Content=$option[0];$item.Tag=$option[1];$null=$mode.Items.Add($item)};$mode.SelectedIndex=0
 if($form.ContainsKey('TransportIndex')){$mode.SelectedIndex=[int]$form.TransportIndex}
 AddC $p (Margin (Note '部署始终在同一条线路内准备 UDP 和 TCP。这里的协议选择只设置初始偏好；网络检查与推荐另行显示，未完成性能对比时使用策略默认，不能据此判断最快。') '0,14,0,0')
 AddC $p (Margin (T '默认连接方式：自动推荐。需要指定 UDP / TCP 时可展开高级设置；指定只设置初始偏好。' 13 $script:Text2) '0,8,0,0')
 $advancedPanel=Stack;AddC $advancedPanel (Margin (T '默认连接方式' 12.5 $script:Ink 'SemiBold') '0,12,0,5');AddC $advancedPanel $mode
 AddC $advancedPanel (Margin (T 'TCP 首选端口' 12.5 $script:Ink 'SemiBold') '0,12,0,5')
 $tcpChoice=ControlName (New-Object Windows.Controls.ComboBox) 'DeployTcpPort';$tcpChoice.IsEditable=$true;$tcpChoice.IsReadOnly=$true
 foreach($candidate in @('443','8443','2443')){$null=$tcpChoice.Items.Add($candidate)};$tcpChoice.SelectedItem='443';AddC $advancedPanel $tcpChoice
 $null=DeploymentField $advancedPanel 'TCP 握手目标' 'DeployServerName' 'www.bing.com'
 $advanced=ControlName (New-Object Windows.Controls.Expander) 'DeploymentAdvanced';$advanced.Header='高级部署设置';$advanced.Content=$advancedPanel;$advanced.Margin='0,14,0,0';AddC $p $advanced
 $draft=ProfileUIField $script:DeployUI 'FormDraft' @{}
 foreach($key in @('DeployConnectionText','DeployName','DeployUser','DeployPort','DeployKeyPath','DeployTcpPort','DeployServerName')){if($draft.ContainsKey($key)){$script:Controls[$key].Text=[string]$draft[$key]}}
  $script:Controls.DeployKeyPath.Tag=$script:DeployUI
  $script:Controls.DeployKeyPath.Add_TextChanged({
   if(-not [object]::ReferenceEquals($script:DeployUI,$this.Tag) -or -not $script:DeployUI.TaskCredentialAvailable){return}
   $script:DeployUI.TaskCredentialKeyChanged=$true
   if($script:Controls.ContainsKey('DeployUseTaskCredential')){$script:Controls.DeployUseTaskCredential.IsChecked=$false}
  })
 if($script:Controls.DeployTcpPort.Text -notin @('443','8443','2443')){AddC $advancedPanel (Notice 'warn' '请选择支持端口' ('原草稿保存的端口 '+$script:Controls.DeployTcpPort.Text+' 不受支持；请选择 443、8443 或 2443。'))}
 if($draft.ContainsKey('LoginMethod') -and $method.SelectedIndex -ne [int]$draft.LoginMethod){$method.SelectedIndex=[int]$draft.LoginMethod}
 $actionHost=$script:Window.FindName('DeploymentActionHost');$actionBar=$script:Window.FindName('DeploymentActionBar')
 if($actionHost -and $actionBar){
  $actionHost.Children.Clear()
  $visibility=New-Object Windows.Data.Binding('IsVisible');$visibility.Source=$card;$visibility.Converter=New-Object Windows.Controls.BooleanToVisibilityConverter
  $null=$actionBar.SetBinding([Windows.UIElement]::VisibilityProperty,$visibility)
 }else{$actionHost=$p}
 AddC $p (Margin (Note '点击后将在这台服务器准备 UDP / TCP、授权本机并保存配置；完成后继续使用当前线路。正常部署会自动推进，身份变化或恢复原操作时再由你处理。') '0,14,0,0')
 $submit=DeploymentActions $actionHost $(if($script:DeployUI.Reauth){'登录并继续部署'}else{'部署这台服务器'}) 'ProductDeployInspect' {StartProductDeployment}
 $back=DeploymentActions $actionHost '返回上一页' 'ProductServers' {ReturnNavigationContext $script:DeployUI.DeploymentReturnContext} 'Ghost'
 if($actionBar){$submit.Margin='0,0,10,0';$back.Margin='0,0,10,0'}
  AddDeploymentAbandonActionUI $p
 $script:DeploymentRenderedFlow=$script:DeployUI
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
  if($tcp -notin @(443,8443,2443)){throw 'TCP 首选端口仅支持 443、8443、2443，请修改原草稿的端口。'}
  $keyPath=[string]$script:Controls.DeployKeyPath.Text;if($script:Controls.ContainsKey('DeployLoginMethod') -and $script:Controls.DeployLoginMethod.SelectedIndex -eq 0){$keyPath=''}
  $connection=ConvertTo-TCDeploymentConnection -Text $script:Controls.DeployConnectionText.Text -User $script:Controls.DeployUser.Text -Port $port -IdentityFile $keyPath
  # A newly typed password or a chosen key always wins over the (collapsed,
  # default-on) saved-credential option, so "修改登录资料" really changes it.
  $useSaved=($script:Controls.ContainsKey('DeployUseSaved') -and $script:Controls.DeployUseSaved.IsChecked -and -not $connection.IdentityFile -and $script:Controls.DeployPassword.SecurePassword.Length -eq 0)
  $useTask=($script:DeployUI.TaskCredentialAvailable -and $script:Controls.ContainsKey('DeployUseTaskCredential') -and $script:Controls.DeployUseTaskCredential.IsChecked -and -not [bool](ProfileUIField $script:DeployUI 'TaskCredentialKeyChanged' $false) -and $script:Controls.DeployPassword.SecurePassword.Length -eq 0)
  $script:DeployUI.CredentialRevision=[guid]::NewGuid().ToString()
  if($useTask){
   Import-Module (Join-Path $script:PackageRoot 'DeploymentTransport.psm1') -DisableNameChecking
   $saved=Get-TCDeployTaskCredential -Root $script:Root -RunId $script:DeployUI.Run.RunId
   if(-not $saved){$script:DeployUI.TaskCredentialAvailable=$false;throw '任务登录资料已过期或目标已变化，请重新输入密码或私钥。'}
   foreach($field in @('Host','Port','User')){if([string]$saved.Binding.$field -cne [string]$connection.$field){throw '已保存登录资料属于原目标；修改服务器地址或账户后，请输入对应的密码或私钥。'}}
   $methodKind=if($script:Controls.DeployLoginMethod.SelectedIndex -eq 1){'PrivateKey'}else{'Password'}
   if($methodKind -cne [string]$saved.Binding.CredentialKind){throw '登录方式已变化，请输入本次密码或私钥。'}
   $script:DeployUI.Credential=$saved.Credential;$script:DeployUI.CredentialRevision=$saved.CredentialRevision
  }
  elseif($useSaved){Import-Module (Join-Path $script:PackageRoot 'DeploymentTransport.psm1') -DisableNameChecking;Import-Module (Join-Path $script:PackageRoot 'ServerRegistry.psm1') -DisableNameChecking;$savedServer=Get-TCServer $script:Root $script:DeployUI.ServerId;$script:DeployUI.Credential=Get-TCDeploySavedCredential -Root $script:Root -CredentialRef $savedServer.CredentialRef}
  elseif($connection.IdentityFile){$pem=[IO.File]::ReadAllText($connection.IdentityFile,[Text.Encoding]::UTF8);$script:DeployUI.Credential=@{Kind='PrivateKey';PrivateKeyPem=(ConvertTo-SecureString $pem -AsPlainText -Force);Passphrase=$script:Controls.DeployPassword.SecurePassword.Copy()};$pem=$null}
  else{if($script:Controls.ContainsKey('DeployLoginMethod') -and $script:Controls.DeployLoginMethod.SelectedIndex -eq 1){throw '请选择 SSH 私钥文件；服务器密码与私钥口令分别填写。'};if(-not $script:Smoke -and $script:Controls.DeployPassword.SecurePassword.Length -eq 0){throw '请提供服务器登录密码，或选择 SSH 私钥登录。'};$script:DeployUI.Credential=@{Kind='Password';Password=$script:Controls.DeployPassword.SecurePassword.Copy()}}
  foreach($secretName in @('Password','PrivateKeyPem','Passphrase')){if($script:DeployUI.Credential[$secretName] -is [Security.SecureString]){$script:DeployUI.Credential[$secretName].MakeReadOnly()}}
  $script:DeployUI.RememberCredential=[bool]$script:Controls.DeployRemember.IsChecked
  if(-not $script:DeployUI.RememberCredential -and $script:DeployUI.Run -and -not $script:Smoke){
   try{Import-Module (Join-Path $script:PackageRoot 'DeploymentTransport.psm1') -DisableNameChecking;$null=Remove-TCDeployTaskCredential -Root $script:Root -RunId $script:DeployUI.Run.RunId;$script:DeployUI.TaskCredentialAvailable=$false;$script:DeployUI.CredentialStorageError=''}catch{$script:DeployUI.CredentialStorageError='已关闭任务保存，但原登录资料尚未清除；请通过本机资料清理重试。'}
  }
  $script:DeployUI.CredentialFresh=(-not ($useSaved -or $useTask))
  $script:DeployUI.CredentialExpiresAt=[DateTimeOffset]::UtcNow.AddMinutes(30);$script:DeployUI.AutomaticLoginRetries=0;$script:DeployUI.CredentialBinding=$null;$script:DeployUI.ReconnectMessage=''
  SetDeploymentPasswordVisibilityUI $false
  $script:DeployUI.PreparationConsent=@{Host=[string]$connection.Host;Port=[int]$connection.Port;User=[string]$connection.User;RunId='';ServerRecordId='';PinnedFingerprint='';TcpPort=$tcp;ServerName=[string]$script:Controls.DeployServerName.Text;Transport=[string]$script:Controls.DeployTransport.SelectedItem.Tag;SubmittedAtUtc=[DateTimeOffset]::UtcNow;Scope='PrepareUdpTcpAndLocalDevice';ConsumedDigests=@()}
  if($script:DeployUI.Reauth -and $script:DeployUI.Run){
   $same=$script:Smoke
   if(-not $script:Smoke){Import-Module (Join-Path $script:PackageRoot 'ServerRegistry.psm1') -DisableNameChecking;$prior=(Get-TCServer $script:Root $script:DeployUI.Run.ServerRecordId).Connection;$same=($prior.Host -eq $connection.Host -and [int]$prior.Port -eq $connection.Port -and $prior.User -eq $connection.User)}
   if($same){$script:DeployUI.PreparationConsent.RunId=$script:DeployUI.Run.RunId;$script:DeployUI.PreparationConsent.ServerRecordId=$script:DeployUI.Run.ServerRecordId;$script:DeployUI.Reauth=$false;ShowProductDeployment;StartDeploymentSessionUI;return}
   if($script:DeployUI.Run.ClientRequest -or $script:DeployUI.Run.Plan -or $script:DeployUI.Run.DispatchIntent -or $script:DeployUI.Run.CandidateNodeId){throw '原步骤已有部署成果或操作记录，请先核对原结果；不能把原批准套到新目标。'}
   $script:DeployUI.ServerId=$null;$script:DeployUI.Reauth=$false;$script:DeployUI.Run=$null
  }
  $name=[string]$script:Controls.DeployName.Text;if([string]::IsNullOrWhiteSpace($name)){$name='服务器 '+$connection.Host}
  $request=@{Action='DeploymentCreate';Intent=$script:DeployUI.Intent;Connection=$connection;Name=$name;Transport=[string]$script:Controls.DeployTransport.SelectedItem.Tag;TcpPort=$tcp;ServerName=$script:Controls.DeployServerName.Text}
  if($script:DeployUI.Intent -eq 'Existing' -and $script:DeployUI.LegacySeed -and $script:DeployUI.LegacySeed.TemplateNodeId){$request.TemplateNodeId=$script:DeployUI.LegacySeed.TemplateNodeId}
  if($script:DeployUI.ServerId){$request.ServerId=$script:DeployUI.ServerId}
  StartJob $request {param($run,$context)if(-not (TestDeploymentCallbackContext $context) -or -not $run.RunId){return};$script:DeployUI.Run=$run;$script:DeployUI.PreparationConsent.RunId=$run.RunId;$script:DeployUI.PreparationConsent.ServerRecordId=$run.ServerRecordId;ShowProductDeployment;StartDeploymentSessionUI} '创建可恢复部署记录…' -CallbackContext (NewDeploymentCallbackContext) -Failed {param($message,$context,$failure)SetDeploymentWorkerFailure $message $context $failure}
 }catch{
  # Point at what the user must fix before showing why.
  $message=$_.Exception.Message
  if($message -like '*CredentialTemporarilyUnavailable*'){
   $script:DeployUI.TaskCredentialReadState=[pscustomobject]@{Status='TemporarilyUnavailable';Available=$false;Retryable=$true}
   ShowProductDeployment;$message='本机登录资料暂时被占用，可重试读取'
  }
  if($message -match '密码|私钥'){FocusDeploymentField 'DeployPassword'}
  elseif($message -match '端口'){FocusDeploymentField 'DeployPort'}
  elseif($message -match '地址|接入'){FocusDeploymentField 'DeployConnectionText'}
  elseif($message -match '域名'){FocusDeploymentField 'DeployServerName'}
  ErrorDialog $message
 }
}
function StartDeploymentSessionUI {param([switch]$ReuseCredential)
 if($script:DeployUI.SessionStarting -or -not $script:DeployUI.Run){return}
 try{
  if($script:Smoke){StartJob @{Action='DeploymentSessionFixture';RunId=$script:DeployUI.Run.RunId} {param($s,$context)if(TestDeploymentCallbackContext $context){$script:DeployUI.SessionRef=$s.SessionRef}} '测试会话' -CallbackContext (NewDeploymentCallbackContext);return}
  Import-Module (Join-Path $script:PackageRoot 'DeploymentTransport.psm1') -DisableNameChecking
  Import-Module (Join-Path $script:PackageRoot 'ServerRegistry.psm1') -DisableNameChecking
  $server=Get-TCServer -Root $script:Root -Id $script:DeployUI.Run.ServerRecordId
  $pin=ResolveDeploymentTrustUI $server
  if(-not $script:DeployUI.Credential -or ($ReuseCredential -and -not (TestDeploymentCredentialUI $server))){ClearDeploymentCredentialUI -KeepDraft;$script:DeployUI.Reauth=$true;ShowProductDeployment;return}
  if(-not $ReuseCredential){$script:DeployUI.CredentialBinding=DeploymentCredentialScopeUI $server}
  $previous=$script:DeployUI.SessionRef
  $reason=if($ReuseCredential){[string](ProfileUIField $script:DeployUI 'RetryReasonCode' 'UserRetry')}elseif($previous){'CredentialResubmitted'}else{'InitialAttempt'}
  $accessContext=DeploymentAccessContextUI $server $reason $previous
  $script:DeployUI.AccessAttemptId=[guid]::NewGuid().ToString();$script:DeployUI.MinimumAuthenticationGeneration=1;$script:DeployUI.AppliedCredentialFailure=''
  $script:DeployUI.SessionStarting=$true;$script:DeployUI.AccessSnapshot=$null;$script:DeployUI.PollError='';$script:DeployUI.WorkerFailure=$null
  ShowProductDeployment
  $context=@{Flow=$script:DeployUI;RunId=$script:DeployUI.Run.RunId;Previous=$previous;ClosePrevious=$true;AttemptId=$script:DeployUI.AccessAttemptId}
  StartUiCommand -Module 'DeploymentTransport.psm1' -Command 'Start-TCDeploySession' -Arguments @{Root=$script:Root;RunId=$script:DeployUI.Run.RunId;Connection=$server.Connection;Credential=$script:DeployUI.Credential;PinnedFingerprint=$pin;AccessContext=$accessContext} -Context $context -Complete {
   param($started,$context)
   $context.Flow.SessionStarting=$false
   if(-not (TestDeploymentCallbackContext $context) -or [string]$started.SessionRef.RunId -cne [string]$context.RunId){CloseUiDeploymentSession $started.SessionRef;return}
   $script:DeployUI.SessionRef=$started.SessionRef;$script:DeployUI.SessionAttached=$false;$script:DeployUI.LastPoll=[DateTime]::MinValue
   $script:DeployUI.AccessSnapshot=@{InstanceId=$started.SessionRef.InstanceId;Status='Connecting'}
   if($context.ClosePrevious -and $context.Previous){CloseUiDeploymentSession $context.Previous}
   RegisterDeploymentAccessAttemptUI
  } -Failed {param($message,$context)$context.Flow.SessionStarting=$false;if(TestDeploymentCallbackContext $context){$script:DeployUI.AccessSnapshot=$null;$script:DeployUI.ReconnectMessage='';$script:DeployUI.PollError=$message;ShowProductDeployment;ErrorDialog $message}} -Message '正在连接服务器…'
 }catch{$script:DeployUI.SessionStarting=$false;$script:DeployUI.AccessSnapshot=$null;$script:DeployUI.ReconnectMessage='';$script:DeployUI.PollError=$_.Exception.Message;ShowProductDeployment;ErrorDialog $_.Exception.Message}
}
function AdvanceDeploymentUI {param([string]$Command='Continue',[int]$InterfaceIndex=0)
 if((IsBusy) -or -not $script:DeployUI.Run){return}
 if($script:ReadOnly){ErrorDialog '只读窗口不推进部署。';return}
 $mutation=ProfileUIField $script:DeployUI.Run 'LastRemoteMutation'
 if($Command -eq 'Continue' -and ([string](ProfileUIField $mutation 'State' '') -in @('Prepared','Dispatched') -or (ProfileUIField $script:DeployUI.Run 'UnresolvedTcpMutation'))){$Command='Reconcile'}
 elseif($Command -eq 'Continue' -and (ProfileUIField $script:DeployUI.Run 'ProbeRecoveryRequired' $false)){$Command='RecoverProbe'}
 if($Command -eq 'Probe' -and (ProfileDeploymentDecision (DeploymentLineView $script:DeployUI.Run) $script:DeployUI.Run).Blocked){ErrorDialog (ProfileDeploymentDecision (DeploymentLineView $script:DeployUI.Run) $script:DeployUI.Run).Message;return}
 if($Command -eq 'UsePrepared'){
  $state=DeploymentCompletenessView $script:DeployUI.Run
  $prepared=@((DeploymentLineView $script:DeployUI.Run).Profiles|Where-Object {ProfileIsPrepared $_})
  if($state.State -ne 'Partial' -or -not $prepared.Count){ErrorDialog '当前没有可确认先使用的部分部署；请先核对准备状态。';return}
 }
 $request=@{Action='DeploymentProceed';RunId=$script:DeployUI.Run.RunId;Command=$Command}
 if($InterfaceIndex -gt 0){if($Command -ne 'Probe'){ErrorDialog '网络选择只能用于本次检查。';return};$request.InterfaceIndex=$InterfaceIndex}
 if($Command -eq 'Approve'){$request.ApprovedChangeDigest=$script:DeployUI.Run.Review.ChangeDigest}
 StartJob $request {param($run,$context)if(-not (TestDeploymentRunResult $run $context)){return};$script:DeployUI.Run=$run;$script:DeployUI.PollError='';$script:DeployUI.WorkerFailure=$null;ShowProductDeployment;$null=ContinueDeploymentPreparationUI} '处理部署阶段；现有线路保持…' -CallbackContext (NewDeploymentCallbackContext) -Failed {param($message,$context,$failure)SetDeploymentWorkerFailure $message $context $failure}
}
function ContinueDeploymentPreparationUI {
 $run=$script:DeployUI.Run;$consent=$script:DeployUI.PreparationConsent
 if($script:ReadOnly -or $script:Role -ne 'deployment' -or (IsBusy) -or $script:DeployUI.Reauth -or $script:DeployUI.PauseAtCheckpoint -or -not $run -or -not $consent -or -not $script:DeployUI.SessionAttached){return $false}
 if($run.Stage -ne 'PlanReady' -or $run.Status -ne 'WaitingUser' -or -not $run.Review -or (ProfileUIField $run 'RecoveryRequired' $false) -or (ProfileUIField $run 'AccessIssue')){return $false}
 if($consent.Scope -cne 'PrepareUdpTcpAndLocalDevice' -or $consent.RunId -cne $run.RunId -or $consent.ServerRecordId -cne $run.ServerRecordId -or [DateTimeOffset]$consent.SubmittedAtUtc -le [DateTimeOffset]::UtcNow.AddHours(-24)){return $false}
 foreach($field in @('TcpPort','ServerName','Transport')){if([string](ProfileUIField $run $field '') -cne [string](ProfileUIField $consent $field '')){return $false}}
 $review=$run.Review;$identity=ProfileUIField $review 'TargetIdentity';$target=ProfileUIField $identity 'Connection'
 if(-not $target -or [string]$review.Kind -notin @('Deploy','Management','Authorize','PrepareTcp') -or (ProfileUIField $review 'ChangesLocalNetwork' $true) -ne $false -or -not $consent.PinnedFingerprint -or [string](ProfileUIField $identity 'PinnedHostKey' '') -cne [string]$consent.PinnedFingerprint){return $false}
 foreach($field in @('Host','Port','User')){if([string]$target.$field -cne [string]$consent[$field]){return $false}}
 $digest=[string](ProfileUIField $review 'ChangeDigest' '')
 if(-not $digest -or $digest -in @($consent.ConsumedDigests)){return $false}
 $consent.ConsumedDigests+=,$digest
 AdvanceDeploymentUI 'Approve'
 return $true
}
function DeploymentLocalCheckPending {param($Run)
 $Run -and ([string](ProfileUIField $Run 'Stage' '') -in @('PreparingProbePath','CheckingProfiles') -or [string](ProfileUIField (ProfileUIField $Run 'ProbePreparation') 'State' '') -eq 'Preparing' -or ([string](ProfileUIField $Run 'Stage' '') -eq 'ReadyInactive' -and [string](ProfileUIField $Run 'ProfileProbeState' '') -in @('Pending','Running')))
}
function PollDeploymentRunUI {
 if(-not $script:DeployUI.Run){return}
 $request=@{Action='DeploymentPoll';RunId=$script:DeployUI.Run.RunId};$proof=ProfileUIField $script:DeployUI.Run 'RecoveryVerification'
 if($proof -and $proof.Status -eq 'Checking'){$request.ReconciliationIntentId=[string]$proof.MutationIntentId}
 StartJob $request {param($run,$context)if(-not (TestDeploymentRunResult $run $context)){return};$script:DeployUI.Run=$run;$script:DeployUI.PollError='';$script:DeployUI.WorkerFailure=$null;ShowProductDeployment;if($script:DeployUI.PauseAtCheckpoint -and $run.Status -notin @('Running','Dispatching','OutcomeUnknown','NeedsRecovery')){DeploymentLater}else{$null=ContinueDeploymentPreparationUI}} '读取部署与检查进度…' '' -Silent -CallbackContext (NewDeploymentCallbackContext) -Failed {param($message,$context,$failure)SetDeploymentWorkerFailure $message $context $failure}
}
function TestDeploymentAccessIdleUI {
 # Stop remote polling only after a terminal access result belongs to the
 # current attempt and has been consumed. New attempts resume automatically.
 if($script:DeployUI.SessionStarting -or $script:DeployUI.TrustAuthenticating -or $script:DeployUI.SessionAttaching -or $script:DeployUI.SessionAttached){return $false}
 $run=$script:DeployUI.Run;$ref=$script:DeployUI.SessionRef;$issue=ProfileUIField $run 'AccessIssue'
 if(-not $run -or -not $ref -or -not $issue -or -not $script:DeployUI.LastAccessSignature -or $run.Status -in @('Running','Dispatching') -or (ProfileUIField $run 'PendingOperationId')){return $false}
 if([string](ProfileUIField $issue 'SessionInstanceId' '') -cne [string]$ref.InstanceId -or [string]$ref.RunId -cne [string]$run.RunId){return $false}
 if([int](ProfileUIField $issue 'AuthenticationGeneration' 0) -lt [int](ProfileUIField $script:DeployUI 'MinimumAuthenticationGeneration' 0)){return $false}
 return ([string](ProfileUIField $issue 'Kind' '') -in @('Credentials','PrivateKey','FirstTrust','IdentityChanged','Connection','AuthenticationRequired','RemoteEnvironment'))
}
function PollProductDeployment {
 if($script:DeployUI.SessionStarting){return}
 if($script:Smoke -or ((Get-Date)-$script:DeployUI.LastPoll).TotalSeconds -lt 2){return}
 $script:DeployUI.LastPoll=Get-Date
 if(ProfileUIField $script:DeployUI 'Identity'){PollDeploymentIdentity;return}
 if($script:Job -and $script:Job.Action -in @('DeploymentPoll','DeploymentProceed') -and $script:DeployUI.Run){
  try{
   Import-Module (Join-Path $script:PackageRoot 'DeploymentFlow.psm1') -DisableNameChecking
   $progress=Get-TCDeploymentRun -Root $script:Root -RunId ([string]$script:DeployUI.Run.RunId)
    if($progress.Revision -ge $script:DeployUI.Run.Revision -and ($progress.Stage -in @('PreparingProbePath','CheckingProfiles') -or $progress.Status -in @('Failed','OutcomeUnknown','NeedsRecovery','Cancelled','Complete'))){$script:DeployUI.Run=$progress;if($script:Role -eq 'deployment'){ShowProductDeployment;$script:HostPanel.IsEnabled=$true}}
  }catch{}
  return
 }
 if(IsBusy){return}
 if($script:DeployUI.ManagementMode -or $script:DeployUI.PendingManagement){PollServerOperation;return}
 if($script:Role -ne 'deployment' -or -not $script:DeployUI.Run){return}
 if($script:DeployUI.Credential -and $script:DeployUI.CredentialExpiresAt -and [DateTimeOffset]$script:DeployUI.CredentialExpiresAt -le [DateTimeOffset]::UtcNow){ClearDeploymentCredentialUI -KeepDraft}
 if($script:DeployUI.Run -and (($script:DeployUI.Run.Stage -eq 'ReadyInactive' -and [string](ProfileUIField $script:DeployUI.Run 'DeploymentCompleteness' '') -eq 'Complete') -or $script:DeployUI.Run.Status -in @('Complete','Cancelled'))){ClearDeploymentCredentialUI -ForgetTask}
 if($script:DeployUI.Reauth){return}
  if(ContinueDeploymentPreparationUI){return}
 if(DeploymentLocalCheckPending $script:DeployUI.Run){PollDeploymentRunUI;return}
 if($script:DeployUI.Run -and $script:DeployUI.Run.Stage -eq 'ReadyInactive'){
  if($script:DeployUI.SessionRef){StartJob @{Action='DeploymentClose';SessionRef=$script:DeployUI.SessionRef} {param($result,$context)if((TestDeploymentCallbackContext $context -Session) -and $result.Closed -and $result.InstanceId -ceq $context.InstanceId){$script:DeployUI.SessionRef=$null;$script:DeployUI.SessionAttached=$false}} '关闭已完成的管理会话…' '' -Silent -CallbackContext (NewDeploymentCallbackContext -Session)}
  if($script:ConnectionCompletionUI -and $script:ConnectionCompletionUI.LineId -ceq $script:DeployUI.Run.CandidateNodeId -and $script:ConnectionCompletionUI.Action -eq 'CompleteProfile' -and $script:Role -eq 'deployment' -and -not $script:DeployUI.SessionRef){$script:Role='client';LoadLineConnections $script:ConnectionCompletionUI.LineId}
  return
 }
 if(-not $script:DeployUI.SessionRef -or [string]$script:DeployUI.SessionRef.RunId -cne [string]$script:DeployUI.Run.RunId){return}
 if(TestDeploymentAccessIdleUI){
  if([string](ProfileUIField (ProfileUIField $script:DeployUI.Run 'AccessIssue') 'Kind' '') -eq 'FirstTrust'){ShowDeploymentFirstTrustUI -Automatic}
  return
 }
 try{
  Import-Module (Join-Path $script:PackageRoot 'DeploymentTransport.psm1') -DisableNameChecking
  StartJob @{Action='DeploymentSessionSnapshot';SessionRef=$script:DeployUI.SessionRef} {param($data,$context)if(TestDeploymentCallbackContext $context -Session){ApplyDeploymentSessionSnapshot $data $context}} '读取管理会话状态…' '' -Silent -CallbackContext (NewDeploymentCallbackContext -Session) -Failed {param($message,$context)if(TestDeploymentCallbackContext $context -Session){$script:DeployUI.PollError='管理会话暂不可核验';$script:DeployUI.LastPoll=(Get-Date).AddSeconds(3)}}
 }catch{$script:DeployUI.PollError='管理会话状态读取未完成'}
}
function ApplyDeploymentSessionSnapshot {param($Data,$Context)
 if(-not (TestDeploymentCallbackContext $Context -Session)){return}
 if(-not $script:DeployUI.SessionRef -or [string]$Data.InstanceId -cne [string]$script:DeployUI.SessionRef.InstanceId){return}
 if($script:Role -ne 'deployment'){return}
 if($script:DeployUI.Reauth){return}
 try{
  Import-Module (Join-Path $script:PackageRoot 'DeploymentTransport.psm1') -DisableNameChecking
  $poll=$Data.Poll
  $generation=[int](ProfileUIField $poll 'AuthenticationGeneration' 0)
  if($generation -gt 0 -and $generation -lt [int](ProfileUIField $script:DeployUI 'MinimumAuthenticationGeneration' 0)){return}
  if($generation -gt 0){$script:DeployUI.MinimumAuthenticationGeneration=$generation}
  $script:DeployUI.AccessSnapshot=@{InstanceId=$Data.InstanceId;Status=[string]$poll.Status;AuthenticationGeneration=$generation}
  if($poll.Code -in @('HostTrustRequired','HostKeyUnknown') -or $poll.Status -in @('HostTrustRequired','AwaitingTrust')){
   $script:DeployUI.SessionAttached=$false;$script:DeployUI.ReconnectMessage=''
   $signature=[string]$script:DeployUI.SessionRef.InstanceId+':FirstTrust:'+ [string]$poll.ObservedFingerprint
   if($script:DeployUI.LastAccessSignature -cne $signature){
    $script:DeployUI.LastAccessSignature=$signature
    StartJob @{Action='DeploymentAccessState';RunId=$script:DeployUI.Run.RunId;SessionRef=$script:DeployUI.SessionRef} {param($run,$context)SetDeploymentAccessRunUI $run $context} '等待确认首次服务器身份…' -CallbackContext (NewDeploymentCallbackContext -Session) -Failed {param($message,$context,$failure)if(TestDeploymentCallbackContext $context -Session){$script:DeployUI.LastAccessSignature='';SetDeploymentWorkerFailure $message $context $failure}}
   }else{ShowDeploymentFirstTrustUI -Automatic}
   return
  }
  if($poll.HasSession -and -not $script:DeployUI.SessionAttached){
   if($script:DeployUI.SessionAttaching){return}
   $script:DeployUI.SessionAttaching=$true
   StartUiCommand -Module 'ServerRegistry.psm1' -Command 'Set-TCServerRecord' -Arguments @{Root=$script:Root;Id=$script:DeployUI.Run.ServerRecordId;PinnedFingerprint=[string]$poll.ObservedFingerprint;SessionRef=$script:DeployUI.SessionRef} -Context @{Flow=$script:DeployUI;RunId=$script:DeployUI.Run.RunId;InstanceId=$script:DeployUI.SessionRef.InstanceId;Fingerprint=[string]$poll.ObservedFingerprint;AttemptId=[string](ProfileUIField $script:DeployUI 'AccessAttemptId' '')} -Complete {
    param($server,$context);$context.Flow.SessionAttaching=$false
    if(-not (TestDeploymentCallbackContext $context -Session)){return}
    $script:DeployUI.SessionAttached=$true;$script:DeployUI.AccessSnapshot=$null
    if(Get-Variable -Name DeploymentTrustDecisions -Scope Script -ErrorAction SilentlyContinue){$script:DeploymentTrustDecisions.Remove([string]$context.RunId)}
    if($script:DeployUI.CredentialBinding){$script:DeployUI.CredentialBinding.PinnedFingerprint=$context.Fingerprint};$script:DeployUI.ReconnectMessage=''
    if($script:DeployUI.PreparationConsent){$script:DeployUI.PreparationConsent.PinnedFingerprint=$context.Fingerprint}
    if(-not $script:Smoke){
     try{
      if($script:DeployUI.RememberCredential -and $script:DeployUI.Credential){$saved=Save-TCDeployTaskCredential -Root $script:Root -RunId $context.RunId -Credential $script:DeployUI.Credential -CredentialRevision $script:DeployUI.CredentialRevision;$script:DeployUI.CredentialExpiresAt=[DateTimeOffset]$saved.ExpiresAtUtc;$script:DeployUI.TaskCredentialAvailable=$true}
       else{$null=Remove-TCDeployTaskCredential -Root $script:Root -RunId $context.RunId;$script:DeployUI.TaskCredentialAvailable=$false}
       $script:DeployUI.CredentialStorageError=''
     }catch{$script:DeployUI.CredentialStorageError='登录成功，但本任务的登录资料未能保存；本次可以继续，重开后需要重新输入。'}
    }
    StartJob @{Action='DeploymentAttach';RunId=$context.RunId;SessionRef=$script:DeployUI.SessionRef} {param($run,$context)if(-not (TestDeploymentRunResult $run $context)){return};$script:DeployUI.Run=$run;AdvanceDeploymentUI} '认证完成，开始只读检查…' -CallbackContext (NewDeploymentCallbackContext -Session) -Failed {param($message,$context,$failure)SetDeploymentWorkerFailure $message $context $failure}
   } -Failed {param($message,$context)$context.Flow.SessionAttaching=$false;$context.Flow.PollError=$message;if([object]::ReferenceEquals($script:DeployUI,$context.Flow) -and $script:Role -eq 'deployment'){ErrorDialog $message}}
   return
  }
  if(-not $poll.HasSession -and $poll.Status -notin @('Starting','Connecting','Authenticating','HostTrustRequired','AwaitingTrust') -and $poll.Code -notin @('HostTrustRequired','HostKeyUnknown')){
   $script:DeployUI.SessionAttached=$false;$script:DeployUI.ReconnectMessage=''
   $diagnostic=Get-TCDeployAccessDiagnostic -Code ([string]$poll.Code)
   $signature=[string]$script:DeployUI.Run.RunId+':'+[string]$script:DeployUI.SessionRef.InstanceId+':'+$generation+':'+[string]$poll.Code
   if($script:DeployUI.LastAccessSignature -ne $signature){
    $script:DeployUI.LastAccessSignature=$signature
    SetDeploymentAccessFailureUI @{Code=[string]$poll.Code;SessionInstanceId=[string]$script:DeployUI.SessionRef.InstanceId;AuthenticationGeneration=$generation}
    StartJob @{Action='DeploymentAccessState';RunId=$script:DeployUI.Run.RunId;SessionRef=$script:DeployUI.SessionRef} {param($run,$context)
     if(-not (TestDeploymentRunResult $run $context)){return}
     $script:DeployUI.Run=$run
     if($script:Role -ne 'deployment'){return}
     $d=Get-TCDeployAccessDiagnostic -Code ([string](ProfileUIField (ProfileUIField $run 'AccessIssue') 'Code' ''))
     if(-not $script:DeployUI.Reauth -and $d.RetryWithCredential -and (RetryDeploymentConnectionUI -Automatic)){return}
     $script:DeployUI.ReconnectMessage='';$script:DeployUI.AccessSnapshot=$null;ShowProductDeployment
    } '读取本次连接结果…' -CallbackContext (NewDeploymentCallbackContext -Session) -Failed {param($message,$context,$failure)if(TestDeploymentCallbackContext $context -Session){$script:DeployUI.LastAccessSignature='';SetDeploymentWorkerFailure $message $context $failure}}
   }
   return
  }
  if($script:DeployUI.Run -and $script:DeployUI.Run.Status -eq 'Running'){PollDeploymentRunUI}
 }catch{$script:DeployUI.PollError='状态读取未完成：'+$_.Exception.Message;$script:Footer.Text=$script:DeployUI.PollError}
}
function ResumeProductDeployment {param([string]$RunId)
 if($script:ReadOnly){ErrorDialog '只读窗口不恢复执行操作。';return}
 $returnContext=CaptureNavigationContext;ClearDeploymentCredentialUI
 $script:DeployUI=@{Intent='Auto';Screen='run';Run=$null;Discovery=$null;SessionRef=$null;SessionAttached=$false;Credential=$null;RememberCredential=$false;LastPoll=[DateTime]::MinValue;TrustShown=$null;ServerId=$null;Server=$null;Management=$null;PendingManagement=$null;ManagementMode=$false;Reauth=$false;LastAccessSignature='';ReconnectMessage='';AutomaticLoginRetries=0;PasswordControl=$null;FormDraft=@{};ChooseNetwork=$false;DeploymentReturnContext=$returnContext}
 $script:Role='deployment';$script:Step=1
 $context=NewDeploymentCallbackContext;$context.RequestedRunId=$RunId
 StartJob @{Action='DeploymentGet';RunId=$RunId} {param($run,$context)
  if(-not (TestDeploymentCallbackContext $context) -or [string]$run.RunId -cne [string]$context.RequestedRunId){return}
  $script:DeployUI.Run=$run;$script:DeployUI.ServerId=$run.ServerRecordId;$script:DeployUI.SessionRef=$run.SessionRef;$script:DeployUI.SessionAttached=$false;$script:DeployUI.ManagementMode=$false;$script:DeployUI.TrustShown=$null;$script:Role='deployment';$script:Step=1
  $script:DeployUI.PollError='';$script:DeployUI.AutomaticLoginRetries=0
  $script:DeployUI.Reauth=($run.Stage -notin @('ReadyInactive','PreparingProbePath','CheckingProfiles') -and -not $script:DeployUI.SessionAttached)
  if($run.SessionRef -and -not $script:Smoke){
   StartJob @{Action='DeploymentSessionSnapshot';SessionRef=$run.SessionRef} {param($data,$context)
    if(-not (TestDeploymentCallbackContext $context -Session) -or [string]$data.InstanceId -cne [string]$context.InstanceId){return}
    $script:DeployUI.SessionAttached=[bool]$data.Poll.HasSession
    $script:DeployUI.Reauth=($script:DeployUI.Run.Stage -notin @('ReadyInactive','PreparingProbePath','CheckingProfiles') -and -not $script:DeployUI.SessionAttached)
     if($script:DeployUI.Discovery){ShowProductDeployment}
   } '读取原管理会话，不自动登录或继续…' '' -Silent -CallbackContext (NewDeploymentCallbackContext -Session)
  }
  # Opening a record only shows it. Logging in again and continuing remote
  # steps needs an explicit click, even when a saved credential exists;
  # bounded automatic reconnects apply only to a drop inside this session.
   StartJob @{Action='DeploymentDiscover'} {param($d,$context)
    if(-not (TestDeploymentCallbackContext $context)){return}
    $script:DeployUI.Discovery=$d
    $server=@($d.Servers|Where-Object LocalRecordId -eq $script:DeployUI.ServerId)|Select-Object -First 1
    if(-not $server -or -not $server.Connection){$script:DeployUI.PollError='原服务器接入资料未能恢复，请刷新此记录。';ShowProductDeployment;return}
    $script:DeployUI.Server=$server
    $run=$script:DeployUI.Run
    $script:DeployUI.TaskCredentialAvailable=$false;$saved=$null
    if(-not $script:Smoke){try{Import-Module (Join-Path $script:PackageRoot 'DeploymentTransport.psm1') -DisableNameChecking;$credentialState=Get-TCDeployTaskCredentialState -Root $script:Root -RunId $run.RunId -InfoOnly;$script:DeployUI.TaskCredentialReadState=$credentialState;$script:DeployUI.TaskCredentialAvailable=[bool]$credentialState.Available;if($credentialState.Available){$saved=$credentialState}}catch{$script:DeployUI.TaskCredentialReadState=[pscustomobject]@{Status='TemporarilyUnavailable';Available=$false;Retryable=$true}}}
    $loginMethod=if($saved){if($saved.Binding.CredentialKind -eq 'PrivateKey'){1}else{0}}elseif($server.Connection.IdentityFile){1}else{0}
    $transportIndex=switch([string]$run.Transport){'Udp'{1};'Tcp'{2};default{0}}
    $script:DeployUI.TaskCredentialKeyChanged=$false
    $script:DeployUI.FormDraft=@{DeployConnectionText=[string]$server.Connection.Host;DeployName=[string]$run.Name;DeployUser=[string]$server.Connection.User;DeployPort=[string]$server.Connection.Port;DeployKeyPath=[string]$server.Connection.IdentityFile;DeployTcpPort=[string]$run.TcpPort;DeployServerName=[string]$run.ServerName;LoginMethod=$loginMethod;TransportIndex=$transportIndex}
    ShowProductDeployment
   } '恢复原服务器与申请引用…' -CallbackContext (NewDeploymentCallbackContext) -Failed {param($message,$context,$failure)SetDeploymentWorkerFailure $message $context $failure}
 } '读取原部署运行，不生成新申请…' -CallbackContext $context -Failed {param($message,$context,$failure)SetDeploymentWorkerFailure $message $context $failure}
}
function DeploymentStageLabel {param([string]$Stage)
 $labels=@{PrepareAccess='等待服务器登录';Inspect='检查服务器环境';PlanReady='核对变更计划';Apply='部署服务器服务';ServerInfo='核对服务器身份';ManagementPlan='检查管理能力';ManagementApply='准备设备管理';Authorize='授权这台电脑';ServerExit='检查服务器出口';CheckingProfiles='自动检查连接方式';ReadyInactive='准备完成，尚未启用';Reconcile='核对上次操作结果';RequestStatus='核对原设备申请';NeedsRecovery='需要恢复服务器事务'}
 $labels.PreparingProbePath='准备检测路径'
 $labels.RecoveryVerified='原操作已核对，等待继续';$labels.RecoveryOperationResult='核对原操作归档与实际资源'
 $labels.MaterializeCandidate='为这台电脑生成连接配置';$labels.MaterializeTcp='保存 TCP 本机连接';$labels.InspectTcp='核对 TCP 准备';$labels.TcpCandidates='自动选择可用 TCP 参数';$labels.TcpPlan='准备双协议配置';$labels.TcpApply='准备 TCP 服务';$labels.TcpParameters='保存本机 TCP 参数';$labels.RecheckUdp='核对已完成的 UDP 成果';$labels.ExistingUdp='复用本机已有授权'
 if($labels.ContainsKey($Stage)){return $labels[$Stage]};return '处理部署阶段'
}
function DeploymentStatusLabel {param([string]$Status)
 $labels=@{WaitingUser='等待你的操作';Running='正在处理';Idle='已保存';Failed='失败，已停止';OutcomeUnknown='结果需要核对';NeedsRecovery='需要恢复';Cancelled='已取消，记录保留';Complete='完成';Completed='完成';CompletedWithWarnings='有项目需处理';PartialDeployment='部分完成';Dispatching='正在提交'}
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
 if($script:DeployUI.SessionRef){
  StartJob @{Action='DeploymentClose';SessionRef=$script:DeployUI.SessionRef} {param($result,$context)
   if(-not (TestDeploymentCallbackContext $context -Session)){return}
   if(-not $result.Closed){ShowDeploymentLeaveChoices;return}
   if($result.InstanceId -and $result.InstanceId -cne $script:DeployUI.SessionRef.InstanceId){return}
   $script:DeployUI.SessionRef=$null;$script:DeployUI.SessionAttached=$false
   CompleteDeploymentLater
  } '保存原进度并关闭空闲管理会话…' -CallbackContext (NewDeploymentCallbackContext -Session)
 }else{CompleteDeploymentLater}
}
function CompleteDeploymentLater {
 ClearDeploymentCredentialUI;$script:DeployUI.PreparationConsent=$null;$script:DeployUI.ReconnectMessage='';$script:DeployUI.PauseAtCheckpoint=$false
 $script:Step=0;$script:Role='client';ShowNodes;FetchNodes
}
function ShowDeploymentLeaveChoices {
 OpenDialog '当前服务器步骤仍在进行' '返回列表会保留原操作并继续读取结果。也可以留在这里，等待当前步骤完成后暂停；不会强行中止已经提交的服务器变更。' '暂停后会保存结果并关闭空闲管理会话。结果未知时仍需核对，不显示为已暂停。' '返回列表，操作继续' {
  $script:Step=0;$script:Role='client';ShowNodes;FetchNodes;Toast '服务器操作继续，进度保留在准备记录中'
 } '留在此页'
}
function PauseDeploymentAtCheckpoint {
 if(-not $script:DeployUI.Run){return}
 StartJob @{Action='DeploymentPause';RunId=$script:DeployUI.Run.RunId} {param($result,$context)
  if(-not (TestDeploymentRunResult $result $context)){return};$script:DeployUI.PauseAtCheckpoint=$true;Toast '已请求在当前步骤完成后暂停，正在核对结果'
 } '登记安全步骤暂停请求…' -CallbackContext (NewDeploymentCallbackContext)
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
 StartJob @{Action='DeploymentProceed';RunId=$run.RunId;Command='Save'} {param($saved,$context)
  if(-not (TestDeploymentRunResult $saved $context)){return};$script:DeployUI.Run=$saved;$script:DeployUI.PollError='';$script:DeployUI.WorkerFailure=$null;DeploymentLater
 } '保存完成；保留当前连接…' -CallbackContext (NewDeploymentCallbackContext) -Failed {param($message,$context,$failure)SetDeploymentWorkerFailure $message $context $failure}
}
function InvokeDeploymentDecisionUI {param([string]$Action)
 switch($Action){
  'RetryLogin'{$script:DeployUI.Reauth=$true;ShowProductDeployment;return}
  'RetryConnection'{$null=RetryDeploymentConnectionUI;return}
  'VerifyIdentity'{if([string](ProfileUIField (ProfileUIField $script:DeployUI.Run 'AccessIssue') 'Kind' '') -eq 'FirstTrust'){ShowDeploymentFirstTrustUI}else{BeginDeploymentIdentityVerification};return}
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
 AddDeploymentCredentialNoticeUI $p
 $checking=DeploymentLocalCheckPending $run;$local=($run.Stage -in @('PreparingProbePath','CheckingProfiles','ReadyInactive'));$line=DeploymentLineView $run
 $decision=ProfileDeploymentDecision $line $run
 $accessInProgress=DeploymentAccessInProgressUI
 if($accessInProgress){
  SetupCardHeader $p ([string]$run.Name) ('登录完成后继续：'+(DeploymentStageLabel $run.Stage)) 'server'
  $progress=if($script:DeployUI.SessionAttaching){'登录已通过，正在读取服务器状态。'}elseif($script:DeployUI.TrustAuthenticating){'已确认服务器身份，正在提交登录。'}elseif($script:DeployUI.ReconnectMessage){$script:DeployUI.ReconnectMessage}else{'正在连接服务器并检查登录结果。'}
  AddC $p (ControlName (T $progress 17 $script:Ink 'SemiBold') 'DeployReconnectStatus')
  $retryCount=[int](ProfileUIField $script:DeployUI 'AutomaticLoginRetries' 0)
  AddC $p (Margin (T ('单次连接超时 20 秒；最多自动重试 2 次，目前已重试 '+$retryCount+' 次。需要确认身份或连接失败时，本页会显示处理入口。') 13 $script:Text2) '0,8,0,0')
  AddC $script:HostPanel $card;return
 }
 $completeness=DeploymentCompletenessView $run;$outcome=($local -or $completeness.State -eq 'NeedsRecovery')
 if(ProfileUIField $run 'AccessIssue'){
  $issue=ProfileUIField $run 'AccessIssue'
  $accessSubtitle=if($issue.Kind -eq 'FirstTrust'){'等待你的确认；当前尚未登录服务器。'}else{'中断步骤：'+(DeploymentStageLabel ([string]$issue.ResumeStage))+'；当前线路保持。'}
  SetupCardHeader $p ([string]$run.Name) $accessSubtitle 'server'
  AddC $p (ControlName (T $decision.Title 19 $script:Ink 'SemiBold') 'DeployAccessTitle');AddC $p (Margin (T $decision.Message 13 $script:Text2) '0,8,0,0')
  if($issue.Kind -eq 'FirstTrust'){
   $target=ProfileUIField $issue 'Connection'
   if($target){AddC $p (Margin (ControlName (T ('登录目标：'+$target.User+'@'+$target.Host+':'+$target.Port) 14 $script:Ink 'SemiBold') 'DeployTrustTarget') '0,14,0,0')}
   AddC $p (Margin (ControlName (T ('SSH 指纹：'+[string]$issue.ObservedFingerprint) 13 $script:Text2) 'DeployTrustFingerprint') '0,6,0,0')
  }
  if($completeness.PreparedProtocols.Count){AddC $p (Margin (ControlName (T ('本机已保存配置：'+($completeness.PreparedProtocols.ToUpperInvariant() -join ' / ')) 13 $script:Ink 'SemiBold') 'DeployResumeProgress') '0,8,0,0')}
  $bar=New-Object Windows.Controls.WrapPanel;AddDeploymentDecisionAction $bar ([pscustomobject]@{Action=$decision.PrimaryAction;Label=$decision.PrimaryLabel}) $true
  foreach($action in $decision.SecondaryActions){AddDeploymentDecisionAction $bar $action};AddC $p $bar
  AddDeploymentAbandonActionUI $p
  $null=ManagementDetails $p ('诊断：'+[string]$issue.Code+'；从 '+(DeploymentStageLabel ([string]$issue.ResumeStage))+' 继续。') '接入详情'
  AddC $script:HostPanel $card;return
 }
 if($run.Stage -eq 'PrepareAccess'){
  SetupCardHeader $p ([string]$run.Name) '登录完成后才会开始检查服务器。' 'server'
  $title=if($script:DeployUI.PollError){'服务器状态未能读取'}else{$decision.Title}
  $message=if($script:DeployUI.PollError){$script:DeployUI.PollError}else{$decision.Message}
  AddC $p (ControlName (T $title 19 $script:Ink 'SemiBold') 'DeployAccessTitle');AddC $p (Margin (T $message 13 $script:Text2) '0,8,0,0')
  AddDeploymentWorkerFailure $p
  $bar=New-Object Windows.Controls.WrapPanel;AddDeploymentDecisionAction $bar ([pscustomobject]@{Action=$decision.PrimaryAction;Label=$decision.PrimaryLabel}) $true
  foreach($action in $decision.SecondaryActions){AddDeploymentDecisionAction $bar $action};AddC $p $bar
  AddDeploymentAbandonActionUI $p
  AddC $script:HostPanel $card;return
 }
 $subtitle=if($outcome){$completeness.Label}else{(DeploymentStageLabel $run.Stage)+' · '+(DeploymentStatusLabel $run.Status)}
 SetupCardHeader $p ([string]$run.Name) $subtitle 'server'
 if($run.Status -eq 'Failed'){
  AddC $p (Notice 'warn' '部署已停止' ((DeploymentStageLabel $run.Stage)+'未完成。已完成进度保留，请从原任务继续。'))
  $diagnosticId=[string](ProfileUIField (ProfileUIField $run 'LastError') 'DiagnosticId' '')
  if($diagnosticId){AddC $p (Margin (T ('错误记录：'+$diagnosticId) 12 $script:Text3) '0,6,0,0')}
 }
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
 if(ProfileUIField $script:DeployUI 'PollError'){AddC $p (Margin (Notice 'warn' '本步骤需要处理' $script:DeployUI.PollError) '0,10,0,0');AddDeploymentWorkerFailure $p;$null=DeploymentActions $p '重试读取状态' 'DeployRetryStatus' {PollDeploymentRunUI} 'Btn'}
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
  $savedComplete=($completeness.State -eq 'Complete' -and (ProfileUIField $run 'AutoSavedAtUtc') -and -not $decision.Blocked)
  if($savedComplete){AddDeploymentDecisionAction $actions ([pscustomobject]@{Action='Leave';Label='完成并返回，保持当前连接'}) $true}
  AddDeploymentDecisionAction $actions ([pscustomobject]@{Action=$decision.PrimaryAction;Label=$decision.PrimaryLabel}) (-not $savedComplete)
  foreach($action in $decision.SecondaryActions){if(($savedComplete -and $action.Action -eq 'Leave') -or ($action.Action -eq 'ConnectRecommended' -and (NodeHasActiveProfile $line))){continue};AddDeploymentDecisionAction $actions $action}
  if($completeness.State -eq 'Partial' -and -not $decision.Blocked -and (ProfileUIField $run 'PartialUseAccepted' $false) -ne $true -and $completeness.PreparedProtocols.Count){$null=DeploymentActions $actions '确认先保存已准备方式' 'DeployUsePrepared' {AdvanceDeploymentUI 'UsePrepared'} 'Btn'}
  if($decision.CanManualTry -and (UILineId $line)){$null=DeploymentActions $actions '查看已准备连接方式 / 手动试用…' 'DeployPreparedProfiles' {ShowDeploymentPreparedProfiles} 'Ghost'}
  if(NodeHasActiveProfile $line){$null=DeploymentActions $actions '继续使用当前连接' 'DeployContinueCurrent' {ShowHome;RefreshOverview -Silent} 'Btn'}
 }
 elseif($run.Stage -eq 'RecoveryVerified'){
  $recoveryOutcome=ProfileUIField (ProfileUIField $run 'RecoveryVerification') 'Outcome'
  if($recoveryOutcome -eq 'NotApplied'){AddC $p (Notice 'ok' '原管理初始化未生效，已完成核对' '原计划已过期，服务器没有残留管理文件，原设备配置已核实。继续后将生成新计划供核对。')}
  else{AddC $p (Notice 'ok' '原操作结果已核对' '已确认原变更的实际结果。继续后会恢复后续准备；当前电脑线路保持。')}
  $null=DeploymentActions $actions '继续原部署' 'DeployContinueVerified' {AdvanceDeploymentUI 'Continue'}
  $null=DeploymentActions $actions '稍后继续' 'DeployLeave' {DeploymentLater} 'Ghost'
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
   $resumeLabel=if($run.Status -eq 'Failed' -and $run.Stage -in @('MaterializeCandidate','MaterializeTcp')){'继续生成本机连接配置'}else{'重新核对原操作结果'}
   $null=DeploymentActions $actions $resumeLabel 'DeployReconcile' {AdvanceDeploymentUI 'Continue'} 'Btn'
  AddC $p (Margin (T '保留原申请与部署记录，从原操作继续核对。' 12 $script:Text3) '0,10,0,0')
 }
 else{
  $description=if($run.Status -in @('Running','Dispatching')){'正在'+(DeploymentStageLabel $run.Stage)+'，进度自动保存。'}else{'等待本步骤的结果或必要操作，已完成进度保留。'}
  AddC $p (Margin (T $description 13 $script:Text2) '0,14,0,0')
  if($run.Status -in @('Running','Dispatching')){
   $null=DeploymentActions $actions '返回列表，操作继续' 'DeployLeaveRunning' {ShowDeploymentLeaveChoices} 'Ghost'
   $null=DeploymentActions $actions '当前步骤完成后暂停' 'DeployPauseAtCheckpoint' {PauseDeploymentAtCheckpoint} 'Ghost'
  }elseif(ProfileUIField $run PausedContinuation){$null=DeploymentActions $actions '继续原步骤' 'DeployResumeCheckpoint' {AdvanceDeploymentUI 'Continue'}}
 }
 AddC $p $actions
  AddDeploymentAbandonActionUI $p
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
