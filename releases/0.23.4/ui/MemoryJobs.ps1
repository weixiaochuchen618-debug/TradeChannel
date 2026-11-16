# Credentials stay as SecureString objects inside this process. Pipe waits run
# in disposable background runspaces; neither requests nor secrets reach jobs JSON.
$script:UiMemoryJobs=New-Object 'Collections.Generic.List[object]'
function StartUiCommand {
 param([string]$Module,[string]$Command,[hashtable]$Arguments,[scriptblock]$Complete,[scriptblock]$Failed,$Context,[string]$Message='正在联系管理会话…')
 if($script:Smoke){throw 'Real in-memory command is forbidden in UI fixtures'}
 $powershell=[PowerShell]::Create()
 try{
  $null=$powershell.AddScript({param($package,$moduleName,$commandName,$parameters)
   $ErrorActionPreference='Stop';$env:PSModulePath=Join-Path $PSHOME 'Modules'
   $phase='BeforeDispatch'
   try{
    Import-Module (Join-Path $package $moduleName) -DisableNameChecking
    $null=Get-Command $commandName -ErrorAction Stop
    $phase='Executing'
    [pscustomobject]@{Ok=$true;Data=(& $commandName @parameters)}
   }catch{
    $original=$_;Import-Module (Join-Path $package 'WorkerErrors.psm1') -DisableNameChecking
    $safe=Get-TCWorkerFailure -Failure $original -Action ManagementSession -Phase $phase -MayHaveChanged ($phase -eq 'Executing')
    [pscustomobject]@{Ok=$false;Message=$safe.Message;Code=$safe.Code;ErrorId=$safe.ErrorId;Phase=$phase;OutcomeUnknown=$safe.OutcomeUnknown}
   }finally{$parameters.Clear()}
  }).AddArgument($script:PackageRoot).AddArgument($Module).AddArgument($Command).AddArgument($Arguments.Clone())
  $handle=$powershell.BeginInvoke()
 }catch{
  $powershell.Commands.Clear();$powershell.Dispose()
  $failure=[pscustomobject]@{Ok=$false;Message='后台管理会话未能启动，操作尚未分发。';Code='CommandNotDispatched';Phase='BeforeDispatch';OutcomeUnknown=$false}
  if($Failed){& $Failed $failure.Message $Context $failure}else{ErrorDialog $failure.Message}
  return
 }
 $script:UiMemoryJobs.Add(@{PowerShell=$powershell;Handle=$handle;Complete=$Complete;Failed=$Failed;Context=$Context;Started=[DateTime]::UtcNow;Notified=$false})
 if($script:Footer){$script:Footer.Text=$Message}
}
function PollUiMemoryJobs {
 foreach($job in @($script:UiMemoryJobs.ToArray())){
  if(-not $job.Handle.IsCompleted){
   if(-not $job.Notified -and ([DateTime]::UtcNow-$job.Started).TotalSeconds -gt 45){$job.Notified=$true;if($script:Footer){$script:Footer.Text='原管理请求仍在等待结果；保留原操作，不重复提交'}}
   continue
  }
  $null=$script:UiMemoryJobs.Remove($job);$result=$null
  try{
   try{$items=@($job.PowerShell.EndInvoke($job.Handle));if($items.Count){$result=$items[-1]}}catch{}
   if(-not $result -or -not $result.PSObject.Properties['Ok']){
    $result=[pscustomobject]@{Ok=$false;Message='管理请求结束但结果暂不可核验，请核对原步骤。';Code='CommandOutcomeUnknown';Phase='Executing';OutcomeUnknown=$true}
   }
   # A presentation callback failing does not change the command's known result
   # or invoke the failure callback a second time. Never replay the command.
   try{
    if($result.Ok){if($job.Complete){& $job.Complete $result.Data $job.Context}}
    elseif($job.Failed){& $job.Failed $result.Message $job.Context $result}
    else{ErrorDialog $result.Message}
   }catch{ErrorDialog '管理请求已返回，但页面更新未完成。请重新打开原记录核对结果；没有重复提交。'}
  }finally{$job.PowerShell.Commands.Clear();$job.PowerShell.Dispose();$job.Handle=$null;$job.Context=$null;$job.Complete=$null;$job.Failed=$null}
 }
}
function CloseUiDeploymentSession {param($SessionRef)
 if($script:Smoke -or -not $SessionRef){return}
 StartUiCommand -Module 'DeploymentTransport.psm1' -Command 'Stop-TCDeploySession' -Arguments @{SessionRef=$SessionRef} -Complete {} -Failed {param($message)$script:Footer.Text='管理会话尚未确认关闭，请从原记录核对'} -Message '正在释放空闲管理会话…'
}
