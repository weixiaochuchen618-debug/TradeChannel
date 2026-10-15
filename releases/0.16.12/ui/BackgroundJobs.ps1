# One mutation at a time. Read timeouts may terminate only the owned worker.
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'WorkerContracts.psm1') -DisableNameChecking
. (Join-Path $PSScriptRoot 'ReceiptRecovery.ps1')
$script:JobQueue=New-Object 'Collections.Generic.List[object]'
$script:UncertainUiJobs=New-Object 'Collections.Generic.List[object]'
$script:UiReceiptRetries=@{}
$script:UiJobRecoveryLoaded=$false
$script:UiReadWorkerEnabled=$true
$script:UiReadWorker=$null
function StopUiReadWorker {
 $reader=$script:UiReadWorker;$script:UiReadWorker=$null
 if(-not $reader){return}
 # Never wait on the UI thread. The idle reader also exits when its owner exits.
 try{
  if(-not $reader.Process.HasExited){[IO.File]::WriteAllText(($reader.Inbox+'.stop'),'stop');$null=$reader.Wake.Set()}
  elseif($reader.Id -cmatch '^[a-f0-9]{32}$' -and [IO.Path]::GetFullPath($reader.Inbox) -ieq [IO.Path]::GetFullPath((Join-Path $script:JobRoot ('read-'+$reader.Id+'.inbox.json')))){
   # A terminated reader cannot run its finally block. Remove only this
   # window's exact mailbox files after observing its owned process exit.
   foreach($path in @($reader.Inbox,($reader.Inbox+'.stop'),($reader.Inbox+'.partial'))){if([IO.File]::Exists($path)){[IO.File]::Delete($path)}}
  }
 }catch{}
 $reader.Wake.Dispose();$reader.Process.Dispose()
}
function StartUiReadRequest {param([string]$RequestId)
 $reader=$script:UiReadWorker
 if($reader -and $reader.Process.HasExited){StopUiReadWorker;$reader=$null}
 if(-not $reader){
  $readerId=[guid]::NewGuid().ToString('N');$inbox=Join-Path $script:JobRoot ('read-'+$readerId+'.inbox.json')
  $wake=New-Object Threading.EventWaitHandle($false,[Threading.EventResetMode]::AutoReset,('Local\TradeChannel.Read.'+$readerId))
  $owner=[Diagnostics.Process]::GetCurrentProcess();$ownerTicks=$owner.StartTime.ToUniversalTime().Ticks;$owner.Dispose()
  $args=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',('"'+(Join-Path $script:PackageRoot 'runtime\Read-TradeChannel.ps1')+'"'),'-InboxPath',('"'+$inbox+'"'),'-OwnerProcessId',$PID,'-OwnerStartedTicks',$ownerTicks)
  try{$p=Start-Process -FilePath (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $args -PassThru -WindowStyle Hidden}catch{$wake.Dispose();throw}
  $reader=@{Id=$readerId;Inbox=$inbox;Wake=$wake;Process=$p};$script:UiReadWorker=$reader
 }
 $temporary=$reader.Inbox+'.partial'
 [IO.File]::WriteAllText($temporary,(@{ReaderId=$reader.Id;RequestId=$RequestId}|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($true))
 if([IO.File]::Exists($reader.Inbox)){[IO.File]::Replace($temporary,$reader.Inbox,[NullString]::Value)}else{[IO.File]::Move($temporary,$reader.Inbox)}
 $null=$reader.Wake.Set()
 return $reader
}
function TestUiJobUnknownResult {param($Result)
 if($Result.OutcomeUnknown){return $true}
 return ($Result.Data -and $Result.Data.Status -in @('OutcomeUnknown','NeedsRecovery','RecoveryRequired'))
}
function UiJobField {param($Value,[string]$Name,$Default=$null)
 if($Value -is [Collections.IDictionary]){if($Value.Contains($Name)){return $Value[$Name]}}
 elseif($null -ne $Value -and $Value.PSObject.Properties[$Name]){return $Value.$Name};return $Default
}
function ShowUiWorkerFailure {param($Failure,$Context)
 $next=[string](UiJobField $Failure NextAction 'ReviewOperation')
 $labels=@{EditCredentials='修改登录资料';ReconcileOperation='核对原操作';ReviewIdentity='查看服务器身份';RepairInstallation='查看安装与设置';ChooseNetwork='选择网络';UpdateNetworkBinding='更新网络绑定';ChooseProfile='选择连接方式';CompleteProfile='查看线路准备';ReviewOperation='查看原记录'}
 $label=if($labels.ContainsKey($next)){$labels[$next]}else{'查看原记录'}
 $technical=[string](UiJobField $Failure TechnicalId '')
 $note='已保留原操作记录。'+$(if(UiJobField $Failure OutcomeUnknown $false){'实际结果尚未核对，不要重复部署。'}else{'按提示处理后再继续。'})
 if($technical){$note+=[Environment]::NewLine+$technical}
 $request=@{NextAction=$next;RunId=[string](UiJobField $Context RunId '');LineId=[string](UiJobField $Context LineId '');Flow=(UiJobField $Context Flow)}
 OpenDialog '此步骤需要处理' ([string](UiJobField $Failure Message '请查看原记录。')) $note $label {param($request)InvokeUiWorkerFailureAction $request} '稍后处理' -Context $request -SafeDefault
}
function InvokeUiWorkerFailureAction {param($Request)
 $runId=[string]$Request.RunId;$lineId=[string]$Request.LineId
 $same=($Request.Flow -and [object]::ReferenceEquals($Request.Flow,$script:DeployUI) -and $script:Role -eq 'deployment' -and [string](UiJobField $script:DeployUI.Run RunId '') -ceq $runId)
 if($Request.NextAction -eq 'EditCredentials' -and $same){$script:DeployUI.Reauth=[bool]$script:DeployUI.Run;ShowProductDeployment;FocusDeploymentField 'DeployPassword';return}
 if($Request.NextAction -eq 'ReconcileOperation' -and $same -and $script:DeployUI.Run -and $script:DeployUI.SessionAttached){AdvanceDeploymentUI 'Reconcile';return}
 if($runId){ResumeProductDeployment $runId;return}
 if($lineId -and (Get-Command LoadLineConnections -ErrorAction SilentlyContinue)){LoadLineConnections $lineId;return}
 if($Request.NextAction -eq 'RepairInstallation' -and (Get-Command ShowSettings -ErrorAction SilentlyContinue)){ShowSettings;return}
 ShowRuntimeReport
}
function GetUiJobResourceScope {param($Request)
 $global=@{Kind='Global';ServerRecordId='';Host='';RunId=''}
 $action=[string](UiJobField $Request Action '');$policy=GetUiJobPolicy $action
 if($policy.MutationScope -ne 'DeploymentServer' -or ($action -eq 'DeploymentProceed' -and [string](UiJobField $Request Command '') -eq 'Probe')){return $global}
 try{
  $runId=[string](UiJobField $Request RunId (UiJobField (UiJobField $Request SessionRef) RunId ''))
  $serverId=[string](UiJobField $Request ServerId '');$connection=UiJobField $Request Connection
  if($runId){
   if(-not $script:Root){return $global}
   Import-Module (Join-Path $script:PackageRoot 'DeploymentFlow.psm1') -DisableNameChecking
   $run=Get-TCDeploymentRun -Root $script:Root -RunId $runId
   $serverId=[string]$run.ServerRecordId
   # Candidate path observation owns shared trace/adapter resources. A hung
   # local probe must not be treated as merely another independent VPS.
   if([string]$run.Stage -in @('PreparingProbePath','CheckingProfiles') -or [string](UiJobField $run ProfileProbeState '') -eq 'Running' -or (UiJobField $run ProbeRecoveryRequired $false)){return $global}
  }
  if($serverId){
   if(-not $script:Root){return $global}
   Import-Module (Join-Path $script:PackageRoot 'ServerRegistry.psm1') -DisableNameChecking
   $server=Get-TCServer -Root $script:Root -Id $serverId -IncludeArchived
   $connection=$server.Connection
  }
  $address=$null
  if(-not $connection -or -not [Net.IPAddress]::TryParse([string](UiJobField $connection Host ''),[ref]$address) -or $address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork){return $global}
  # Sharing an IP conflicts even if the SSH account or port differs. Scope
  # does not grant trust, approval, or permission to replay an operation.
  return @{Kind='DeploymentServer';ServerRecordId=$serverId;Host=$address.ToString();RunId=$runId}
 }catch{return $global}
}
function TestUiJobScopesConflict {param($Left,$Right)
 if([string](UiJobField $Left Kind '') -ne 'DeploymentServer' -or [string](UiJobField $Right Kind '') -ne 'DeploymentServer'){return $true}
 $leftHost=[string](UiJobField $Left Host '');$rightHost=[string](UiJobField $Right Host '')
 $leftAddress=$null;$rightAddress=$null
 if(-not [Net.IPAddress]::TryParse($leftHost,[ref]$leftAddress) -or -not [Net.IPAddress]::TryParse($rightHost,[ref]$rightAddress) -or $leftAddress.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or $rightAddress.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork){return $true}
 if($leftAddress.Equals($rightAddress)){return $true}
 $leftServer=[string](UiJobField $Left ServerRecordId '');$rightServer=[string](UiJobField $Right ServerRecordId '')
 return ($leftServer -and $rightServer -and $leftServer -ceq $rightServer)
}
function TestUiMutationBlocked {param($Request,$Scope)
 $policy=GetUiJobPolicy ([string]$Request.Action)
 if($policy.ReadOnly -or (TestUiRecoveryRequest $Request)){return $false}
 if(-not $Scope){$Scope=GetUiJobResourceScope $Request}
 foreach($pending in @($script:UncertainUiJobs.ToArray())){
  if(TestUiJobScopesConflict $Scope (UiJobField $pending ResourceScope)){return $true}
 }
 if($script:Job -and $script:Job.OutcomeUnknown -and (TestUiJobScopesConflict $Scope (UiJobField $script:Job ResourceScope))){return $true}
 return $false
}
function GetUiJobDeploymentMutation {param($Job)
 if($Job.Action -notin @('DeploymentProceed','DeploymentPoll','DeploymentAttach','DeploymentAccessState') -or -not $Job.RunId -or -not $script:Root){return $null}
 try{
  Import-Module (Join-Path $script:PackageRoot 'DeploymentFlow.psm1') -DisableNameChecking
  $run=Get-TCDeploymentRun -Root $script:Root -RunId $Job.RunId;$mutation=UiJobField $run LastRemoteMutation
  if(-not $mutation -or [string]$mutation.State -notin @('Prepared','Dispatched') -or -not $mutation.IntentId){return $null}
  return @{RunId=[string]$run.RunId;ServerRecordId=[string]$run.ServerRecordId;MutationIntentId=[string]$mutation.IntentId;Operation=[string]$mutation.Operation}
 }catch{return $null}
}
function UpdateUiJobUncertaintyBinding {param($Job)
 if(-not (UiJobField $Job DeploymentMutation)){$Job.DeploymentMutation=GetUiJobDeploymentMutation $Job}
 if(-not (UiJobField $Job DeploymentProbe) -and $Job.Action -in @('DeploymentProceed','DeploymentPoll','DeploymentCancelProbe') -and $Job.RunId){
  try{
   Import-Module (Join-Path $script:PackageRoot 'DeploymentFlow.psm1') -DisableNameChecking
   $probeRun=Get-TCDeploymentRun -Root $script:Root -RunId $Job.RunId
   if($probeRun.ProbeAttemptId -and $probeRun.CandidateNodeId -and ($probeRun.ProbeRecoveryRequired -or $probeRun.ProfileProbeState -eq 'Running')){$Job.DeploymentProbe=@{RunId=$probeRun.RunId;CandidateNodeId=$probeRun.CandidateNodeId;ProbeAttemptId=$probeRun.ProbeAttemptId}}
  }catch{}
 }
 # An operation may enter shared local probe work after its first request.
 # Once uncertain, its scope can become more conservative, never narrower.
 if([string](UiJobField (UiJobField $Job ResourceScope) Kind '') -eq 'DeploymentServer'){
  try{
   if(-not $Job.Request -or -not [IO.File]::Exists($Job.Request)){throw 'Original request unavailable'}
   $current=GetUiJobResourceScope ([IO.File]::ReadAllText($Job.Request)|ConvertFrom-Json)
   if([string](UiJobField $current Kind '') -ne 'DeploymentServer'){$Job.ResourceScope=@{Kind='Global';ServerRecordId='';Host='';RunId=''}}
  }catch{$Job.ResourceScope=@{Kind='Global';ServerRecordId='';Host='';RunId=''}}
 }
}
function ResolveUiDeploymentUncertainty {param($Run)
 ResolveUiProbeUncertainty $Run
 $proof=UiJobField $Run RecoveryVerification;$mutation=UiJobField $Run LastRemoteMutation
 if(-not $proof -or $proof.Status -cne 'Verified' -or -not $proof.CompletedAtUtc -or $Run.RecoveryRequired -or (UiJobField $Run ProbeRecoveryRequired $false) -or [string]$Run.Status -in @('NeedsRecovery','OutcomeUnknown') -or -not $mutation -or $mutation.State -cnotin @('Completed','NotApplied')){return}
 if($mutation.State -ceq 'NotApplied' -and ($mutation.Operation -cne 'management_apply' -or (UiJobField $proof Outcome '') -cne 'NotApplied')){return}
 $stop=UiJobField $Run StopTransaction
 if(($stop -and [string](UiJobField $stop State '') -cne 'Reconciled') -or (UiJobField $Run UnresolvedTcpMutation)){return}
 if([string]$proof.RunId -cne [string]$Run.RunId -or [string]$proof.ServerRecordId -cne [string]$Run.ServerRecordId -or [string]$proof.MutationIntentId -cne [string]$mutation.IntentId -or [string]$proof.Operation -cne [string]$mutation.Operation){return}
 foreach($pending in @($script:UncertainUiJobs.ToArray())){
  $binding=UiJobField $pending DeploymentMutation
  if(-not $binding -or $pending.RunId -cne $Run.RunId -or $binding.RunId -cne $proof.RunId -or $binding.ServerRecordId -cne $proof.ServerRecordId -or $binding.MutationIntentId -cne $proof.MutationIntentId -or $binding.Operation -cne $proof.Operation){continue}
  if($pending.Process -and -not $pending.Process.HasExited){continue}
  SaveUiJobReceipt $pending 'Reconciled';$null=$script:UncertainUiJobs.Remove($pending)
  if($pending.Process){$pending.Process.Dispose();$pending.Process=$null}
  if($pending.Result -and [IO.File]::Exists($pending.Result)){[IO.File]::Delete($pending.Result)}
 }
}
function ResolveUiProbeUncertainty {param($Run)
 $proof=UiJobField $Run ProbeRecovery
 if(-not $proof -or -not $proof.CleanupComplete -or -not (UiJobField $proof CompletedAtUtc) -or $Run.RecoveryRequired -or (UiJobField $Run ProbeRecoveryRequired $false) -or (UiJobField $Run UnresolvedTcpMutation) -or $Run.Status -in @('NeedsRecovery','OutcomeUnknown') -or [string](UiJobField (UiJobField $Run LastRemoteMutation) State '') -in @('Prepared','Dispatched')){return}
 if([string]$proof.RunId -cne [string]$Run.RunId -or [string]$proof.CandidateNodeId -cne [string]$Run.CandidateNodeId -or [string]$proof.ProbeAttemptId -cne [string]$Run.ProbeAttemptId){return}
 foreach($pending in @($script:UncertainUiJobs.ToArray())){
  $binding=UiJobField $pending DeploymentProbe
  if(-not $binding -or $binding.RunId -cne $proof.RunId -or $binding.CandidateNodeId -cne $proof.CandidateNodeId -or $binding.ProbeAttemptId -cne $proof.ProbeAttemptId -or (UiJobField $pending DeploymentMutation)){continue}
  if($pending.Process -and -not $pending.Process.HasExited){continue}
  SaveUiJobReceipt $pending 'Reconciled';$null=$script:UncertainUiJobs.Remove($pending)
  if($pending.Process){$pending.Process.Dispose();$pending.Process=$null}
  if($pending.Result -and [IO.File]::Exists($pending.Result)){[IO.File]::Delete($pending.Result)}
 }
}
function RestoreUiJobReceipts {
 if($script:UiJobRecoveryLoaded){return};$script:UiJobRecoveryLoaded=$true
 foreach($file in @(Get-ChildItem -LiteralPath $script:JobRoot -File -Filter '*.receipt.json' -ErrorAction SilentlyContinue)){
  try{
   $r=[IO.File]::ReadAllText($file.FullName)|ConvertFrom-Json
   if($r.SchemaVersion -ne 1 -or $r.RequestId -cnotmatch '^[a-f0-9]{32}$' -or $r.Status -notin @('Dispatched','OutcomeUnknown')){continue}
   $resultPath=Join-Path $script:JobRoot ($r.RequestId+'.result.json');$resolved=$null
   if([IO.File]::Exists($resultPath)){$resolved=[IO.File]::ReadAllText($resultPath)|ConvertFrom-Json}
   $matched=($resolved -and $resolved.RequestId -ceq $r.RequestId -and $resolved.Action -ceq $r.Action)
   $p=$null;try{$p=Get-Process -Id ([int]$r.ProcessId) -ErrorAction Stop;if($p.StartTime.ToUniversalTime().Ticks -ne [long]$r.ProcessStartedTicks){$p.Dispose();$p=$null}}catch{$p=$null}
   $requestPath=Join-Path $script:JobRoot ($r.RequestId+'.request.json');$resourceScope=UiJobField $r ResourceScope
   $originalRequest=$null
   if([IO.File]::Exists($requestPath)){$originalRequest=[IO.File]::ReadAllText($requestPath)|ConvertFrom-Json}
   $resolution=GetUiLegacyReceiptResolution $r $resolved $p $originalRequest
   if(-not $resolution){$resolution=GetUiCleanupReceiptResolution $r $p $originalRequest}
   if($resolution -and -not $script:ReadOnly){SaveUiLegacyReceiptResolution $file.FullName $r $resolution;RemoveUiResolvedReceiptEntry $r.RequestId;if($p){$p.Dispose()};continue}
   if($matched -and -not (TestUiJobUnknownResult $resolved)){RemoveUiResolvedReceiptEntry $r.RequestId;if($p){$p.Dispose()};continue}
   if(@($script:UncertainUiJobs.ToArray()|Where-Object {$_.RequestId -ceq $r.RequestId}).Count){if($p){$p.Dispose()};continue}
   if(-not $resourceScope -and [IO.File]::Exists($requestPath)){try{$resourceScope=GetUiJobResourceScope ([IO.File]::ReadAllText($requestPath)|ConvertFrom-Json)}catch{}}
   $entry=@{RequestId=$r.RequestId;Action=$r.Action;RunId=$r.RunId;LineId=$r.LineId;TransactionId=$r.TransactionId;DeploymentMutation=(UiJobField $r DeploymentMutation);DeploymentProbe=(UiJobField $r DeploymentProbe);ResourceScope=$resourceScope;Started=[datetime]::Parse($r.StartedAtUtc);Process=$p;WorkerProcessId=$r.ProcessId;ProcessStartedTicks=$r.ProcessStartedTicks;Result=$resultPath;Request=$requestPath;Dead=($null -eq $p);ResultConsumed=[bool]$matched;OutcomeUnknown=$true;Policy=@{ReadOnly=$false;Global=$false};Silent=$true;OriginContext=$null;Complete={};Failed=$null}
   UpdateUiJobUncertaintyBinding $entry
   $script:UncertainUiJobs.Add($entry)
  }catch{$script:Footer.Text='存在无法读取的后台操作记录，请在运行状况中核对'}
 }
}
function SaveUiJobReceipt {param($Job,[string]$Status)
 $processId=if($Job.WorkerProcessId){$Job.WorkerProcessId}elseif($Job.Process){$Job.Process.Id}else{0}
 $receipt=[pscustomobject]@{SchemaVersion=1;RequestId=$Job.RequestId;OperationId=$Job.RequestId;Action=$Job.Action;RunId=$Job.RunId;LineId=$Job.LineId;TransactionId=$Job.TransactionId;DeploymentMutation=(UiJobField $Job DeploymentMutation);DeploymentProbe=(UiJobField $Job DeploymentProbe);ResourceScope=(UiJobField $Job ResourceScope);Status=$Status;ErrorId=$Job.ErrorId;Code=$Job.ErrorCode;Phase=$Job.ErrorPhase;StartedAtUtc=$Job.Started.ToUniversalTime().ToString('o');UpdatedAtUtc=[DateTimeOffset]::UtcNow.ToString('o');ProcessId=$processId;ProcessStartedTicks=$Job.ProcessStartedTicks}
 $path=Join-Path $script:JobRoot ($Job.RequestId+'.receipt.json');$temp=$path+'.ui-'+[guid]::NewGuid().ToString('N')+'.partial'
 $Job.ReceiptSaved=$false
 try{
  # The Worker publishes its terminal receipt before its result. Consume that
  # receipt without becoming a second writer (also works with older workers).
  $existing=$null
  if([IO.File]::Exists($path)){try{$existing=[IO.File]::ReadAllText($path)|ConvertFrom-Json}catch{}}
  $matches=$existing -and $existing.RequestId -ceq $Job.RequestId -and $existing.Action -ceq $Job.Action
  if($matches -and (($existing.Status -ceq $Status -and $Status -in @('Completed','Failed','Reconciled')) -or ($Status -in @('Dispatched','OutcomeUnknown') -and $existing.Status -in @('Completed','Failed','Reconciled')))){
   $receipt=$existing
  }else{
   [IO.File]::WriteAllText($temp,($receipt|ConvertTo-Json -Depth 12 -Compress),[Text.UTF8Encoding]::new($true))
   if([IO.File]::Exists($path)){[IO.File]::Replace($temp,$path,[NullString]::Value)}else{[IO.File]::Move($temp,$path)}
  }
  $Job.ReceiptSaved=$true;$script:LastJobReceipt=$receipt
  $script:UiReceiptRetries.Remove($Job.RequestId)
 }catch{
  # A local receipt failure must never prevent delivery of an obtained result.
  # Retry on later timer ticks, without sleeping or replaying the operation.
  $Job.ReceiptFailure=$_
  $entry=$script:UiReceiptRetries[$Job.RequestId]
  if(-not $entry){$entry=@{Job=$Job;Status=$Status;Deadline=[DateTimeOffset]::UtcNow.AddSeconds(5);NextAt=[DateTimeOffset]::UtcNow};$script:UiReceiptRetries[$Job.RequestId]=$entry}
  $entry.Status=$Status;$entry.NextAt=[DateTimeOffset]::UtcNow.AddMilliseconds(250)
  $script:Footer.Text='操作结果已保留，正在重试保存本机回执…'
 }finally{if([IO.File]::Exists($temp)){try{[IO.File]::Delete($temp)}catch{}}}
}
function CompleteUiJobFiles {param($Job)
 if($Job.CallbackFailed){return}
 foreach($path in @($Job.CleanupPaths)){if($path -and [IO.File]::Exists($path)){try{[IO.File]::Delete($path)}catch{$Job.CleanupFailed=$true}}}
}
function RetryUiJobReceipts {
 foreach($id in @($script:UiReceiptRetries.Keys)){
  $entry=$script:UiReceiptRetries[$id];$now=[DateTimeOffset]::UtcNow
  if($now -lt $entry.NextAt){continue}
  if($now -gt $entry.Deadline){
   $script:UiReceiptRetries.Remove($id)
   $script:Footer.Text='操作结果已保留，但本机回执未能更新。请重新打开原记录核对。'
   continue
  }
  SaveUiJobReceipt $entry.Job $entry.Status
  if($entry.Job.ReceiptSaved){CompleteUiJobFiles $entry.Job}
 }
}
function GetUiJobPolicy {param([string]$Action)
 Get-TCWorkerActionContract $Action
}
function TestUiRecoveryRequest {param($Request)
 if($Request.Action -in @('RecordDeleteCommit','RecordCleanupRecover')){return $true} # Local cleanup performs its own target and live-state validation.
 if($Request.Action -eq 'DeploymentProceed' -and $Request.Command -eq 'Reconcile' -and [string]$Request.RunId -cmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'){return $true}
 if($Request.Action -eq 'DeploymentProceed' -and $Request.Command -eq 'RecoverProbe' -and [string]$Request.RunId -cmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'){return $true}
 if($Request.Action -eq 'DeploymentPoll' -and [string](UiJobField $Request ReconciliationIntentId '') -cmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'){return $true}
 if($Request.Action -in @('ConnectionTransactionReconcile','DeploymentAccessState','DeploymentPause','DeploymentClose')){return $true}
 if($Request.Action -eq 'Session' -and $Request.SessionAction -eq 'Disconnect'){return $true}
 if($Request.Action -eq 'Command' -and $Request.Command -eq 'Disconnect'){return $true}
 if($Request.Action -eq 'RepairState' -and -not $Request.ClearProviders){return $true}
 return $false
}
function StartJob {param([hashtable]$Request,[scriptblock]$Complete,[string]$Message='正在处理…',[string]$Transition='',[switch]$Silent,[scriptblock]$Failed=$null,$OriginContext=$null,$CallbackContext=$null)
 if($script:Smoke){$script:Actions.Add([pscustomobject]@{Request=$Request.Clone();Transition=$Transition;Complete=$Complete;Failed=$Failed;CallbackContext=$CallbackContext});$script:AllSelfTestRequests.Add([pscustomobject]@{Request=$Request.Clone();Transition=$Transition});if($Transition){$script:Pending=$Transition;Render};return}
 RestoreUiJobReceipts
 $policy=GetUiJobPolicy ([string]$Request.Action)
 if($CallbackContext -and (Get-Command TestDeploymentCallbackContext -ErrorAction SilentlyContinue) -and -not (TestDeploymentCallbackContext $CallbackContext)){return}
 $resourceScope=if($policy.ReadOnly){$null}else{GetUiJobResourceScope $Request}
 if(TestUiMutationBlocked $Request $resourceScope){ShowUiMutationBlocked $Request $resourceScope;return}
 if(-not $OriginContext){$OriginContext=CaptureNavigationContext}
 if($script:Job){
  $key=@($Request.Action,$Request.Id,$Request.LineId,$Request.RunId,$Request.SessionRef.InstanceId) -join '|'
  if($Silent -and ($script:Job.Key -ceq $key -or @($script:JobQueue|Where-Object Key -ceq $key).Count)){return}
  if($script:JobQueue.Count -ge 32){Toast '等待的操作较多，本次尚未接受，请稍后重试';return}
  $item=@{Request=$Request.Clone();Complete=$Complete;Message=$Message;Transition=$Transition;Failed=$Failed;Silent=[bool]$Silent;OriginContext=$OriginContext;CallbackContext=$CallbackContext;Key=$key}
  if($Silent){$script:JobQueue.Add($item)}else{$position=@($script:JobQueue|Where-Object {-not $_.Silent}).Count;$script:JobQueue.Insert($position,$item);Toast '操作已排队，当前步骤结束后继续'}
  $script:QueuedJob=$script:JobQueue[0];return
 }
 if($script:ReadOnly -and -not $policy.ReadOnly -and $Request.Action -notin @('InspectClient','InspectServer','ProviderCheck','DeploymentDiscover','DeploymentGet','OperationRecordDetail','DraftDisposition','HistoryClearPreview','RecordDeletePreview','ConfigurationRollbackPreview','LineNetworkPreview')){ErrorDialog '当前为只读检查窗口，未执行操作。';return}
 if(($Request.Action -eq 'Session' -and $Request.SessionAction -eq 'Disconnect') -or $Request.Action -in @('RepairState','RemoveProtection')){$script:UserDisconnectIntent=$true}
 $id=[Guid]::NewGuid().ToString('N');$Request=$Request.Clone();$Request.RequestId=$id;$Request.PageGeneration=$OriginContext.Revision
 $req=Join-Path $script:JobRoot ($id+'.request.json');$out=Join-Path $script:JobRoot ($id+'.result.json')
 [IO.File]::WriteAllText($req,($Request|ConvertTo-Json -Depth 12 -Compress),(New-Object Text.UTF8Encoding($true)))
 $exe=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
 $arguments=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',('"'+(Join-Path $script:PackageRoot 'Worker.ps1')+'"'),'-RequestPath',('"'+$req+'"'),'-ResultPath',('"'+$out+'"'))
 $reuseRead=($script:UiReadWorkerEnabled -and $policy.ReuseReadProcess);$ownershipPath=$req
 try{
  if($reuseRead){$reader=StartUiReadRequest $id;$p=$reader.Process;$ownershipPath=$reader.Inbox}
  else{$p=Start-Process -FilePath $exe -ArgumentList $arguments -PassThru -WindowStyle Hidden}
 }catch{[IO.File]::Delete($req);if($Failed){& $Failed '后台任务未能启动，操作尚未分发。' $CallbackContext ([pscustomobject]@{Ok=$false;Message='后台任务未能启动，操作尚未分发。';Code='WorkerStartFailed';Phase='BeforeDispatch';OutcomeUnknown=$false;NextAction='ReviewOperation'})}else{ErrorDialog '后台任务未能启动，操作尚未分发。'};StartNextUiJob;return}
 $script:Job=@{Process=$p;WorkerProcessId=$p.Id;ProcessStartedTicks=$p.StartTime.ToUniversalTime().Ticks;Request=$req;Result=$out;RequestId=$id;OwnershipPath=$ownershipPath;ReusedReadWorker=$reuseRead;Complete=$Complete;Failed=$Failed;CallbackContext=$CallbackContext;ResourceScope=$resourceScope;Started=Get-Date;Clock=[Diagnostics.Stopwatch]::StartNew();Action=$Request.Action;RunId=[string]$Request.RunId;LineId=[string]$(if($Request.LineId){$Request.LineId}else{$Request.Id});Silent=[bool]$Silent;Message=$Message;Policy=$policy;OriginContext=$OriginContext;OutcomeUnknown=$false;Key=(@($Request.Action,$Request.Id,$Request.LineId,$Request.RunId,$Request.SessionRef.InstanceId) -join '|')}
 if(-not $policy.ReadOnly){SaveUiJobReceipt $script:Job 'Dispatched'}
 if(-not $Silent){$script:Footer.Text=$Message};if($Transition){$script:Pending=$Transition;Render}elseif(-not $Silent){$script:HostPanel.IsEnabled=$false}
}
function StartNextUiJob {
 if($script:Job -or -not $script:JobQueue.Count){$script:QueuedJob=$null;return}
 $next=$script:JobQueue[0];$script:JobQueue.RemoveAt(0);$script:QueuedJob=if($script:JobQueue.Count){$script:JobQueue[0]}else{$null}
 $policy=GetUiJobPolicy $next.Request.Action
 if(TestUiMutationBlocked $next.Request){Toast '同一目标的原操作结果待核对，已取消这项尚未分发的排队变更';StartNextUiJob;return}
 if($next.CallbackContext -and (Get-Command TestDeploymentCallbackContext -ErrorAction SilentlyContinue) -and -not (TestDeploymentCallbackContext $next.CallbackContext)){StartNextUiJob;return}
 if(-not $policy.Global -and -not (TestNavigationContext $next.OriginContext)){Toast '页面或目标已变化，尚未分发的原页面操作已取消';StartNextUiJob;return}
 StartJob -Request $next.Request -Complete $next.Complete -Message $next.Message -Transition $next.Transition -Silent:$next.Silent -Failed $next.Failed -OriginContext $next.OriginContext -CallbackContext $next.CallbackContext
}
function SetOverviewReadUnknown {param([string]$Message)
 # Preserve the last observed session instead of inventing a disconnection.
 $script:Overview|Add-Member NoteProperty ReadState 'Unknown' -Force
 $script:Overview|Add-Member NoteProperty ReadWarning $Message -Force
 $script:Footer.Text='状态暂不可核验 · 保留上次显示；连接操作会重新核对'
 UpdateChrome
}
function UpdateReadPresentation {param([switch]$DataChanged)
 $dialog=($script:Window.FindName('Overlay').Visibility -eq 'Visible')
 if($script:Page -eq 'home'){
  if(-not $dialog -and (HomeSignature) -ne $script:HomeSignature){ShowHome}else{UpdateOverviewMetrics}
 }elseif($script:Page -eq 'nodes'){
  $view=[string](NavigationField (NavigationVariable 'NavigationContext') View '')
  if(Get-Command RefreshLineCardControlsUI -ErrorAction SilentlyContinue){
   # Update existing controls during polling. Menus and keyboard selection keep
   # their objects and focus; structural changes render only when interaction is idle.
   $cardInteraction=@($script:LineCardControls.Values|Where-Object {$_.Menu.IsOpen -or $_.Card.IsKeyboardFocusWithin}).Count -gt 0
   $cardPending=($script:LinePreferenceRequests.Count -gt 0 -or $script:LineCheckRequests.Count -gt 0)
   RefreshLineCardControlsUI
  }else{$cardInteraction=$false;$cardPending=$false}
  $editing=($script:ProviderFormOpen -or $view -ne 'nodes' -or [Windows.Input.Keyboard]::FocusedElement -is [Windows.Controls.Primitives.TextBoxBase] -or [Windows.Input.Keyboard]::FocusedElement -is [Windows.Controls.PasswordBox] -or [Windows.Input.Keyboard]::FocusedElement -is [Windows.Controls.ComboBox])
  if($DataChanged -and -not $dialog -and -not $editing -and -not $cardInteraction -and -not $cardPending){ShowNodes}
  else{
   foreach($node in @($script:Nodes)){
    $key='NodeStatus'+([string]$node.id).Replace('-','')
    if($script:Controls[$key] -and -not (Get-Command RefreshLineCardControlsUI -ErrorAction SilentlyContinue)){$script:Controls[$key].Text=if(NodeHasActiveProfile $node){ActiveLineStatus $node}else{(LineRecommendationView $node).Label}}
   }
   if($DataChanged -and $editing){$script:Footer.Text='资料已更新；保留当前输入，提交时重新核对'}
  }
 }elseif($script:Page -eq 'line-profiles' -and $script:LineProfileUI -and $script:LineProfileUI.Line){
  foreach($profile in @(NodeProfileItems $script:LineProfileUI.Line)){
   $control=$script:Controls['ProfileStatus'+$profile.Id]
   if($control){$control.Text=if((ActiveNodeProfileId $script:LineProfileUI.Line) -eq $profile.Id){ActiveLineStatus $script:LineProfileUI.Line}else{ConnectionProfileStatus $profile}}
  }
 }
 UpdateChrome
}
function CompleteUiJob {param($Job,$Result)
 if($Job.CompletionDelivered -and -not $Job.OutcomeUnknown){return}
 $Job.ErrorId=[string]$Result.ErrorId;$Job.ErrorCode=[string]$Result.Code;$Job.ErrorPhase=[string]$Result.Phase
 if($script:Job -eq $Job){$script:Job=$null;$script:Pending=$null;$script:HostPanel.IsEnabled=$true}
 $unknown=(-not $Job.Policy.ReadOnly -and (TestUiJobUnknownResult $Result))
 if($unknown){
  UpdateUiJobUncertaintyBinding $Job
  $Job.OutcomeUnknown=$true;$Job.ResultConsumed=$true
  if($Result.Data.TransactionId){$Job.TransactionId=[string]$Result.Data.TransactionId}
  elseif($Result.Data.ConnectionTransaction.TransactionId){$Job.TransactionId=[string]$Result.Data.ConnectionTransaction.TransactionId}
  if(-not $script:UncertainUiJobs.Contains($Job)){$script:UncertainUiJobs.Add($Job)}
 }else{$Job.OutcomeUnknown=$false;$null=$script:UncertainUiJobs.Remove($Job)}
 if($Result.Ok -and $Job.Action -in @('DeploymentProceed','DeploymentPoll','DeploymentGet')){ResolveUiDeploymentUncertainty $Result.Data}
 $current=($Job.Policy.Global -or (TestNavigationContext $Job.OriginContext))
 $script:LastJobReceipt=[pscustomobject]@{RequestId=$Job.RequestId;Action=$Job.Action;Status=$(if($unknown){'OutcomeUnknown'}elseif($Result.Ok){'Completed'}elseif($Job.Policy.ReadOnly){'ReadFailed'}else{'Failed'});AtUtc=[DateTimeOffset]::UtcNow.ToString('o');OriginalPageCurrent=$current}
 if(-not $Job.Policy.ReadOnly){SaveUiJobReceipt $Job $(if($unknown){'OutcomeUnknown'}elseif($Result.Ok){'Completed'}else{'Failed'})}
 if($Result.Ok -and $Job.Action -eq 'ConnectionTransactionReconcile'){
  $resolvedRows=if($Result.Data.PSObject.Properties['Results']){@($Result.Data.Results)}else{@($Result.Data)}
  foreach($resolved in $resolvedRows){
   if($resolved.TransactionId -and $resolved.Status -in @('Completed','RolledBack','ResolvedStopped','Aborted')){
    foreach($pending in @($script:UncertainUiJobs.ToArray()|Where-Object {($_.TransactionId -and $_.TransactionId -ceq $resolved.TransactionId) -or ($resolved.RequestId -and $_.RequestId -ceq $resolved.RequestId -and $_.Action -in @('Session','ConnectionSwitchCommit'))})){
     SaveUiJobReceipt $pending 'Reconciled';$null=$script:UncertainUiJobs.Remove($pending)
     if($pending.Process){$pending.Process.Dispose();$pending.Process=$null}
     if([IO.File]::Exists($pending.Result)){[IO.File]::Delete($pending.Result)}
    }
   }
  }
 }
 try{
  if(-not $current){if(-not $Job.Silent){Toast $(if($Result.Ok){'原页面操作已完成，当前页面保持'}else{'原页面操作未能确认，请查看原记录'})}}
  elseif($Result.Ok){& $Job.Complete $Result.Data $Job.CallbackContext}
  else{
   if($Job.Action -eq 'Overview'){SetOverviewReadUnknown $Result.Message}
   elseif($Job.Failed){& $Job.Failed $Result.Message $Job.CallbackContext $Result}
   elseif(-not $Job.Silent){ShowUiWorkerFailure $Result @{RunId=$Job.RunId;LineId=$Job.LineId;Flow=(UiJobField $Job.CallbackContext Flow)}}
  }
  }catch{
   $Job.CallbackFailed=$true
   try{Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'WorkerErrors.psm1') -DisableNameChecking;$null=Write-TCFailureDiagnostic -Root $script:Root -Failure $_ -Action 'UiCallback' -RunId $Job.RunId -RequestId $Job.RequestId}catch{}
   ErrorDialog '结果已保存，但页面未能更新。请重新打开原记录查看实际状态。'
  }
  $Job.CompletionDelivered=$true
 $remove=@($Job.Request,($Job.Result+'.partial'));if(-not $unknown){$remove+=,$Job.Result}
 $Job.CleanupPaths=$remove
 if(($Job.Policy.ReadOnly -or $Job.ReceiptSaved) -and -not $Job.CallbackFailed){CompleteUiJobFiles $Job}
 if(-not $unknown -and $Job.Process){if(-not $Job.ReusedReadWorker){$Job.Process.Dispose()};$Job.Process=$null}
 if($unknown -and -not $Job.Process){$Job.Dead=$true}
 StartNextUiJob
 if($script:Window.FindName('Overlay').Visibility -eq 'Visible'){$script:HostPanel.IsEnabled=$false}
 UpdateChrome
}
function PollBackgroundJob {
 RetryUiJobReceipts
 foreach($pending in @($script:UncertainUiJobs.ToArray())){
  if($pending.Dead){continue}
  if(-not $pending.ResultConsumed -and [IO.File]::Exists($pending.Result)){
   try{$late=[IO.File]::ReadAllText($pending.Result)|ConvertFrom-Json;if($late.RequestId -ceq $pending.RequestId -and $late.Action -ceq $pending.Action -and (-not $pending.OriginContext -or [int]$late.PageGeneration -eq [int]$pending.OriginContext.Revision)){CompleteUiJob $pending $late;continue}}catch{}
  }
  if(-not $pending.Process -or $pending.Process.HasExited){$pending.Dead=$true;SaveUiJobReceipt $pending 'OutcomeUnknown';if($pending.Process){$pending.Process.Dispose();$pending.Process=$null};$script:Footer.Text='原操作已退出，结果仍待核对；请查看运行状况中的原记录'}
 }
 $j=$script:Job;if(-not $j){StartNextUiJob;return}
 if([IO.File]::Exists($j.Result)){
  $r=$null
  try{$r=[IO.File]::ReadAllText($j.Result)|ConvertFrom-Json;if([string]$r.RequestId -cne $j.RequestId -or [string]$r.Action -cne $j.Action -or [int]$r.PageGeneration -ne [int]$j.OriginContext.Revision){throw 'Mismatched worker result'}}catch{$r=$null;if($j.Process.HasExited -and $j.Policy.ReadOnly){$r=[pscustomobject]@{Ok=$false;Message='后台结果损坏或不属于原请求，尚不能确认操作是否生效。'}}}
  if($r){CompleteUiJob $j $r;return}
 }
 if($j.Process.HasExited){
  if($j.Policy.ReadOnly){CompleteUiJob $j ([pscustomobject]@{Ok=$false;Message='后台已退出但未返回结果，请重试读取。'})}
  else{SetUiJobOutcomeUnknown $j}
  return
 }
 if($j.Action -in @('ConnectionSwitchCommit','Session') -and $script:Root){
  try{
   Import-Module (Join-Path $script:PackageRoot 'ConnectionTransactions.psm1') -DisableNameChecking
   $progress=Get-TCConnectionTransactionProgress -Root $script:Root -RequestId $j.RequestId
   if($progress){$j.TransactionId=$progress.TransactionId;$j.Progress=$progress;$elapsed=if($j.Clock){[int]$j.Clock.Elapsed.TotalSeconds}else{[int]((Get-Date)-$j.Started).TotalSeconds};$script:Footer.Text=(UIProfileName $progress.ProfileId)+' · '+$progress.Label+' · 已过 '+$elapsed+' 秒'+$(if($progress.Progress){' · '+$(if($progress.Progress.Recovery){'恢复'}else{'连接'})+'阶段上限 '+$progress.Progress.BudgetSeconds+' 秒'}else{''})}
  }catch{}
 }
 $jobElapsed=if($j.Clock){$j.Clock.Elapsed.TotalSeconds}else{((Get-Date)-$j.Started).TotalSeconds}
 if($jobElapsed -lt $j.Policy.TimeoutSeconds){return}
 if($j.Policy.ReadOnly){
  try{
   $owned=Get-CimInstance Win32_Process -Filter ('ProcessId='+$j.Process.Id) -Property ProcessId,CommandLine,ExecutablePath -ErrorAction Stop
   $live=Get-Process -Id $j.Process.Id -ErrorAction Stop
   $expectedPath=if($j.OwnershipPath){$j.OwnershipPath}else{$j.Request}
   try{if($live.StartTime.ToUniversalTime().Ticks -ne $j.ProcessStartedTicks -or [string]$owned.CommandLine -notlike ('*'+$expectedPath+'*') -or [IO.Path]::GetFileName([string]$owned.ExecutablePath) -ine 'powershell.exe'){throw 'Worker ownership unverified'}}finally{$live.Dispose()}
   $j.Process.Kill();if(-not $j.Process.WaitForExit(100)){return}
   CompleteUiJob $j ([pscustomobject]@{Ok=$false;Message='状态读取超时，已结束本次读取；当前连接保持。'})
  }catch{$j.TimeoutErrorType=$_.Exception.GetType().FullName;if(-not $j.OutcomeUnknown){$j.OutcomeUnknown=$true;$script:Footer.Text='读取超时且任务归属暂不可核验，正在等待原任务结束'}}
 }elseif(-not $j.OutcomeUnknown){
  SetUiJobOutcomeUnknown $j
  $script:Footer.Text='原操作仍在运行，结果待核对；不会自动取消或重复提交'
  if(-not $j.Silent){Toast '操作超过预计时间，保留原任务并继续核对结果'}
 }
}
function SetUiJobOutcomeUnknown {param($Job)
 UpdateUiJobUncertaintyBinding $Job
 $Job.OutcomeUnknown=$true;if(-not $script:UncertainUiJobs.Contains($Job)){$script:UncertainUiJobs.Add($Job)};SaveUiJobReceipt $Job 'OutcomeUnknown'
 $script:Job=$null;$script:Pending=$null;$script:HostPanel.IsEnabled=$true;StartNextUiJob
}
function ShowPendingUiOperation {
 $entries=@(foreach($file in @(Get-ChildItem -LiteralPath $script:JobRoot -Filter '*.receipt.json' -File)){
  try{$r=[IO.File]::ReadAllText($file.FullName)|ConvertFrom-Json;if($r.Status -in @('Dispatched','OutcomeUnknown')){$r}}catch{}
 })
 PageHead '待核对的后台操作' '记录原请求与目标，超时不会自动重复执行。' 'pending-operations'
 if(-not $entries.Count){AddC $script:HostPanel (T '当前没有待核对的操作记录。' 13 $script:Text2)}
 foreach($entry in $entries){
  AddC $script:HostPanel (T ('操作：'+$entry.Action+' · 结果待核对') 14 $script:Ink)
  AddC $script:HostPanel (T ('记录编号：'+$entry.OperationId) 12 $script:Text3)
  $button=Btn '查看并处理该记录' ('Pending'+$entry.RequestId) {ShowUiReceiptDetail $this.Tag} 'Ghost';$button.Tag=$entry;AddC $script:HostPanel $button
 }
}
