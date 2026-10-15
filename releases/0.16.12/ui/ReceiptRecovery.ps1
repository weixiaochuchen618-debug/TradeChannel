# Compatibility for the shipped access-state bookkeeping failure. This action
# validates a persisted RunId before any update and never dispatches remote or
# local network changes. A missing request is NOT generalized to other actions.
function GetUiLegacyReceiptResolution {param($Receipt,$Result,$Process,$Request=$null)
 if($Process -and -not $Process.HasExited){return $null}
 if((UiJobField $Receipt SchemaVersion 0) -ne 1 -or [string](UiJobField $Receipt RequestId '') -cnotmatch '^[a-f0-9]{32}$' -or (UiJobField $Receipt Action '') -cne 'DeploymentAccessState' -or (UiJobField $Receipt Status '') -notin @('Dispatched','OutcomeUnknown')){return $null}
 foreach($field in @('RunId','LineId','TransactionId','DeploymentMutation','DeploymentProbe','ResourceScope')){if(UiJobField $Receipt $field){return $null}}
 if(-not $Result -or (UiJobField $Result RequestId '') -cne $Receipt.RequestId -or (UiJobField $Result Action '') -cne $Receipt.Action -or (UiJobField $Result Ok $true) -ne $false -or (UiJobField $Result Code '') -cne 'WorkerStepFailed' -or (UiJobField $Result Phase '') -cne 'Executing' -or (UiJobField $Result Data)){return $null}
 # If an original request still exists, only the invalid empty-RunId case is
 # eligible. A valid or conflicting reference keeps its recovery requirement.
 if($Request -and ((UiJobField $Request RequestId '') -cne $Receipt.RequestId -or (UiJobField $Request Action '') -cne $Receipt.Action -or (UiJobField $Request RunId '') -or (UiJobField (UiJobField $Request SessionRef) RunId ''))){return $null}
 [pscustomobject]@{Kind='FailedLocalBookkeeping';OriginalStatus=$Receipt.Status;VerifiedAtUtc=[DateTimeOffset]::UtcNow.ToString('o');Reason='DeploymentAccessState validates the persisted run before updating local access state and cannot submit deployment or network mutations. The matching failed result and exited executor were verified.';RemoteMutation=$false;NetworkMutation=$false}
}
function GetUiCleanupReceiptResolution {param($Receipt,$Process,$Request)
 if($Process -and -not $Process.HasExited){return $null}
 $action=[string](UiJobField $Receipt Action '')
 if((UiJobField $Receipt SchemaVersion 0) -ne 1 -or $action -notin @('RecordDeleteCommit','RecordCleanupRecover') -or (UiJobField $Receipt Status '') -notin @('Dispatched','OutcomeUnknown') -or [string](UiJobField $Receipt RequestId '') -cnotmatch '^[a-f0-9]{32}$'){return $null}
 if(-not $Request -or (UiJobField $Request RequestId '') -cne $Receipt.RequestId -or (UiJobField $Request Action '') -cne $action){return $null}
 foreach($field in @('RunId','LineId','TransactionId','DeploymentMutation','DeploymentProbe')){if((UiJobField $Receipt $field) -or (UiJobField $Request $field)){return $null}}
 if((UiJobField (UiJobField $Receipt ResourceScope) Kind '') -notin @('','Global')){return $null}
 try{
  Import-Module (Join-Path $script:PackageRoot 'OperationHistory.psm1') -DisableNameChecking
  if($action -eq 'RecordDeleteCommit'){$outcome=Get-TCLocalDeploymentCleanupOutcome -Root $script:Root -PreviewToken ([string](UiJobField $Request PreviewToken ''))}
  else{$outcome=Get-TCLocalDeploymentCleanupOutcome -Root $script:Root -Recovery}
  if(-not $outcome){return $null}
  [pscustomobject]@{Kind='LocalCleanupReconciled';Outcome=$outcome.Outcome;CleanupId=(UiJobField $outcome CleanupId '');ReceiptStatus=$(if($outcome.Outcome -in @('NotApplied','RolledBack')){'Failed'}else{'Reconciled'});OriginalStatus=$Receipt.Status;VerifiedAtUtc=[DateTimeOffset]::UtcNow.ToString('o');RemoteMutation=$false;NetworkMutation=$false}
 }catch{return $null}
}
function SaveUiLegacyReceiptResolution {param([string]$Path,$Receipt,$Resolution)
 $Receipt.Status=[string](UiJobField $Resolution ReceiptStatus 'Failed');$Receipt|Add-Member NoteProperty Resolution $Resolution -Force
 $Receipt|Add-Member NoteProperty UpdatedAtUtc ([DateTimeOffset]::UtcNow.ToString('o')) -Force
 $temp=$Path+'.partial';[IO.File]::WriteAllText($temp,($Receipt|ConvertTo-Json -Depth 12 -Compress),[Text.UTF8Encoding]::new($true));[IO.File]::Replace($temp,$Path,[NullString]::Value)
}
function RemoveUiResolvedReceiptEntry {param([string]$Id)
 foreach($entry in @($script:UncertainUiJobs.ToArray())){if($entry.RequestId -ceq $Id){
  if($entry.Process -and -not $entry.Process.HasExited){continue}
  if($entry.Process){$entry.Process.Dispose();$entry.Process=$null};$null=$script:UncertainUiJobs.Remove($entry)
 }}
}
function RefreshUiJobReceipts {$script:UiJobRecoveryLoaded=$false;RestoreUiJobReceipts}
function ShowUiReceiptDetail {param($Entry)
 PageHead '后台操作核对' '查看导致阻断的具体记录；核对结果不会重复提交部署。' 'receipt-detail'
 AddC $script:HostPanel (Note '本次新操作尚未提交。下面是需要先处理的旧操作。' 'amber')
 AddC $script:HostPanel (T ('操作：'+[string]$Entry.Action+' · '+[string]$Entry.RequestId) 13 $script:Ink)
 $scope=UiJobField $Entry ResourceScope;$target=[string](UiJobField $scope Host '')
 AddC $script:HostPanel (T $(if($target){'目标：'+$target}else{'旧回执缺少目标信息，需要核对原记录。'}) 13 $script:Text2)
 if((UiJobField $Entry Action '') -in @('RecordDeleteCommit','RecordCleanupRecover')){
  AddC $script:HostPanel (Note '本机清理的执行结果尚未交回。恢复会核对持久日志、回退未提交的文件变更或完成已提交的清理，并核对原后台回执。' 'amber')
  AddC $script:HostPanel (Btn '恢复并核对本机清理' 'ReceiptRecoverCleanup' {StartJob @{Action='RecordCleanupRecover'} {param($data)CompleteLocalCleanupRecoveryUI $data} '恢复并核对本机清理…'} 'Btn')
 }
 elseif(UiJobField $Entry RunId ''){$b=Btn '打开原部署并核对' 'ReceiptOpenRun' {ResumeProductDeployment ([string]$this.Tag)} 'Btn';$b.Tag=$Entry.RunId;AddC $script:HostPanel $b}
 else{
  AddC $script:HostPanel (Note '此记录没有可直接打开的部署任务。刷新会核验原结果和执行进程；能证明只发生本机登记失败时会解除阻断，真正未决的变更继续保留。' 'amber')
  AddC $script:HostPanel (Btn '重新核对本机回执' 'ReceiptRecheck' {RefreshUiJobReceipts;ShowPendingUiOperation} 'Btn')
 }
 AddC $script:HostPanel (Btn '返回部署中心' 'ReceiptBack' {ShowSetupCenter} 'Ghost')
}
function ShowUiMutationBlocked {param($Request,$Scope)
 $entries=@($script:UncertainUiJobs.ToArray()|Where-Object {TestUiJobScopesConflict $Scope (UiJobField $_ ResourceScope)})
 if($script:Job -and $script:Job.OutcomeUnknown -and (TestUiJobScopesConflict $Scope (UiJobField $script:Job ResourceScope))){$entries+=,$script:Job}
 $script:Footer.Text='尚未提交：请先核对关联的旧操作。'
 if($entries.Count){
  $entry=$entries[0]
  OpenDialog '尚未提交：旧操作结果待核对' ('阻断操作：'+$entry.Action+[Environment]::NewLine+'记录编号：'+$entry.RequestId) '本次资料尚未派发。打开此记录处理后，再提交新部署。' '查看并处理' {param($item) ShowUiReceiptDetail $item} '返回继续填写' 'Btn' $entry
 }else{ErrorDialog '本次操作尚未提交，请在运行状况中核对旧操作。'}
}
