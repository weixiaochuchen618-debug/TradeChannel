# UI lifetime is independent of the tunnel supervisor. Never issue a Session
# operation while hiding, waking or closing the console.
Import-Module (Join-Path $script:PackageRoot 'WindowPreferences.psm1') -DisableNameChecking
$script:WindowPrefs=Get-TCWindowPreferences -Root $script:Root
$script:CloseIntent='';$script:HiddenWindowState=[Windows.WindowState]::Normal
function UpdateWindowCloseHint {
 $script:Window.FindName('WindowClose').ToolTip=$(if($script:WindowPrefs.CloseBehavior -eq 'ExitInterface'){'退出界面，连接保持'}else{'收起到托盘，连接保持'})
}
function SetWindowCloseBehavior {param([string]$Behavior)
 if($script:ReadOnly){ErrorDialog '当前为只读窗口，未保存窗口偏好。';return}
 try{
  $script:WindowPrefs=Set-TCWindowPreferences -Root $script:Root -CloseBehavior $Behavior
  UpdateWindowCloseHint
  if($script:Controls.ContainsKey('CloseBehaviorSummary')){$script:Controls.CloseBehaviorSummary.Text=WindowCloseDescription}
  Toast '关闭方式已保存，连接保持'
 }catch{
  if($script:Controls.ContainsKey('CloseBehaviorChoice')){
   $box=$script:Controls.CloseBehaviorChoice
   $script:ChangingCloseChoice=$true
   try{$box.SelectedItem=@($box.Items|Where-Object Tag -eq $script:WindowPrefs.CloseBehavior)[0]}finally{$script:ChangingCloseChoice=$false}
  }
  ErrorDialog '关闭方式未保存，原设置仍有效。请检查配置目录权限。'
 }
}
function WindowCloseDescription {
 if($script:WindowPrefs.CloseBehavior -eq 'ExitInterface'){return '关闭管理界面，后台连接继续。下次打开时重新读取当前状态。'}
 '保留当前页面和窗口；从托盘或桌面再次打开时直接恢复，后台连接继续。'
}
function ShowExistingConsole {
 $wasHidden=-not $script:Window.IsVisible
 $script:Window.Show()
 if($wasHidden -or $script:Window.WindowState -eq 'Minimized'){$script:Window.WindowState=$script:HiddenWindowState}
 $null=$script:Window.Activate()
}
function TestWindowTaskInProgress {
 $memoryJobs=Get-Variable UiMemoryJobs -Scope Script -ValueOnly -ErrorAction SilentlyContinue
 if($memoryJobs -and $memoryJobs.Count){return $true}
 if($script:Job -and -not $script:Job.Silent){return $true}
 if($script:Pending -in @('Connecting','Disconnecting','Applying','ApplyingDaily','ApplyingAgents','CheckingProvider')){return $true}
 if($script:Linux -and $script:Linux.Busy){return $true}
 if($script:DeployUI.Run -and $script:DeployUI.Run.Status -in @('Running','Dispatching')){return $true}
 if($script:DeployUI.PendingManagement){return $true}
 if($script:DeployUI.SessionRef -and -not $script:DeployUI.SessionAttached -and $script:DeployUI.Credential){return $true}
 $false
}
function HandleWindowClosing {param($EventArgs)
 if($script:Closing){return}
 $behavior=if($script:CloseIntent){$script:CloseIntent}else{$script:WindowPrefs.CloseBehavior}
 $plan=Get-TCWindowClosePlan -CloseBehavior $behavior -TaskInProgress (TestWindowTaskInProgress)
 $script:CloseIntent=''
 if($plan.Action -eq 'Exit'){
  $script:Closing=$true
  return
 }
 $EventArgs.Cancel=$true
 $script:HiddenWindowState=$(if($script:Window.WindowState -eq 'Maximized'){[Windows.WindowState]::Maximized}else{[Windows.WindowState]::Normal})
 $script:Window.Hide()
 $message=if($plan.TaskBlocked){'任务仍在进行，已收起到托盘。完成后可再次退出界面，连接保持。'}else{'已收起到托盘，连接保持。双击托盘或桌面快捷方式可恢复当前页面。'}
 $script:LastCloseMessage=$message
 if(-not $script:Smoke){$script:Tray.ShowBalloonTip(2500,'TradeChannel',$message,[Windows.Forms.ToolTipIcon]::Info)}
}
function RequestInterfaceExit {
 $script:CloseIntent='ExitInterface'
 $script:Window.Close()
}
function ReleaseWindowManagementSession {
 ClearDeploymentCredentialUI
 $pendingIdentity=$script:DeployUI.IdentityResume
 if($pendingIdentity){$pendingIdentity.Credential=$null}
 $pendingRef=$script:DeployUI.IdentitySessionToClose
 if(-not $script:Smoke -and $pendingRef -and (-not $script:DeployUI.SessionRef -or $script:DeployUI.SessionRef.InstanceId -cne $pendingRef.InstanceId)){
  try{Import-Module (Join-Path $script:PackageRoot 'DeploymentTransport.psm1') -DisableNameChecking;$null=Stop-TCDeploySession -SessionRef $pendingRef}catch{}
 }
 $identity=$script:DeployUI.Identity
 if($identity){
  $identity.Credential=$null
  if(-not $script:Smoke -and $identity.SessionRef -and (-not $script:DeployUI.SessionRef -or $script:DeployUI.SessionRef.InstanceId -cne $identity.SessionRef.InstanceId)){
   try{Import-Module (Join-Path $script:PackageRoot 'DeploymentTransport.psm1') -DisableNameChecking;$null=Stop-TCDeploySession -SessionRef $identity.SessionRef}catch{}
  }
 }
 if(-not $script:Smoke -and $script:DeployUI.SessionRef){
  try{
   Import-Module (Join-Path $script:PackageRoot 'DeploymentTransport.psm1') -DisableNameChecking
   $null=Stop-TCDeploySession -SessionRef $script:DeployUI.SessionRef
  }catch{}
 }
}
UpdateWindowCloseHint
