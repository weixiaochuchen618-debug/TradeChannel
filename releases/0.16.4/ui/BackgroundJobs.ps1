# One mutation at a time. Read timeouts may terminate only the owned worker.
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'WorkerContracts.psm1') -DisableNameChecking
$script:JobQueue=New-Object 'Collections.Generic.List[object]'
$script:UncertainUiJobs=New-Object 'Collections.Generic.List[object]'
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
function RestoreUiJobReceipts {
 if($script:UiJobRecoveryLoaded){return};$script:UiJobRecoveryLoaded=$true
 foreach($file in @(Get-ChildItem -LiteralPath $script:JobRoot -File -Filter '*.receipt.json' -ErrorAction SilentlyContinue)){
  try{
   $r=[IO.File]::ReadAllText($file.FullName)|ConvertFrom-Json
   if($r.SchemaVersion -ne 1 -or $r.RequestId -cnotmatch '^[a-f0-9]{32}$' -or $r.Status -notin @('Dispatched','OutcomeUnknown')){continue}
   $resultPath=Join-Path $script:JobRoot ($r.RequestId+'.result.json');$resolved=$null
   if([IO.File]::Exists($resultPath)){$resolved=[IO.File]::ReadAllText($resultPath)|ConvertFrom-Json}
   $matched=($resolved -and $resolved.RequestId -ceq $r.RequestId -and $resolved.Action -ceq $r.Action)
   if($matched -and -not (TestUiJobUnknownResult $resolved)){continue}
   $p=$null;try{$p=Get-Process -Id ([int]$r.ProcessId) -ErrorAction Stop;if($p.StartTime.ToUniversalTime().Ticks -ne [long]$r.ProcessStartedTicks){$p.Dispose();$p=$null}}catch{$p=$null}
   $script:UncertainUiJobs.Add(@{RequestId=$r.RequestId;Action=$r.Action;RunId=$r.RunId;LineId=$r.LineId;TransactionId=$r.TransactionId;Started=[datetime]::Parse($r.StartedAtUtc);Process=$p;WorkerProcessId=$r.ProcessId;ProcessStartedTicks=$r.ProcessStartedTicks;Result=$resultPath;Request=(Join-Path $script:JobRoot ($r.RequestId+'.request.json'));Dead=($null -eq $p);ResultConsumed=[bool]$matched;OutcomeUnknown=$true;Policy=@{ReadOnly=$false;Global=$false};Silent=$true;OriginContext=$null;Complete={};Failed=$null})
  }catch{$script:Footer.Text='存在无法读取的后台操作记录，请在运行状况中核对'}
 }
}
function SaveUiJobReceipt {param($Job,[string]$Status)
 $processId=if($Job.WorkerProcessId){$Job.WorkerProcessId}elseif($Job.Process){$Job.Process.Id}else{0}
 $receipt=[pscustomobject]@{SchemaVersion=1;RequestId=$Job.RequestId;OperationId=$Job.RequestId;Action=$Job.Action;RunId=$Job.RunId;LineId=$Job.LineId;TransactionId=$Job.TransactionId;Status=$Status;ErrorId=$Job.ErrorId;Code=$Job.ErrorCode;Phase=$Job.ErrorPhase;StartedAtUtc=$Job.Started.ToUniversalTime().ToString('o');UpdatedAtUtc=[DateTimeOffset]::UtcNow.ToString('o');ProcessId=$processId;ProcessStartedTicks=$Job.ProcessStartedTicks}
 $path=Join-Path $script:JobRoot ($Job.RequestId+'.receipt.json');$temp=$path+'.partial'
 [IO.File]::WriteAllText($temp,($receipt|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($true))
 if([IO.File]::Exists($path)){[IO.File]::Replace($temp,$path,[NullString]::Value)}else{[IO.File]::Move($temp,$path)}
 $script:LastJobReceipt=$receipt
}
function GetUiJobPolicy {param([string]$Action)
 Get-TCWorkerActionContract $Action
}
function TestUiRecoveryRequest {param($Request)
 if($Request.Action -in @('ConnectionTransactionReconcile','DeploymentAccessState','DeploymentPause','DeploymentClose')){return $true}
 if($Request.Action -eq 'Session' -and $Request.SessionAction -eq 'Disconnect'){return $true}
 if($Request.Action -eq 'Command' -and $Request.Command -eq 'Disconnect'){return $true}
 if($Request.Action -eq 'RepairState' -and -not $Request.ClearProviders){return $true}
 return $false
}
function StartJob {param([hashtable]$Request,[scriptblock]$Complete,[string]$Message='正在处理…',[string]$Transition='',[switch]$Silent,[scriptblock]$Failed=$null,$OriginContext=$null)
 if($script:Smoke){$script:Actions.Add([pscustomobject]@{Request=$Request.Clone();Transition=$Transition;Complete=$Complete;Failed=$Failed});$script:AllSelfTestRequests.Add([pscustomobject]@{Request=$Request.Clone();Transition=$Transition});if($Transition){$script:Pending=$Transition;Render};return}
 RestoreUiJobReceipts
 $policy=GetUiJobPolicy ([string]$Request.Action)
 if($script:UncertainUiJobs.Count -and -not $policy.ReadOnly -and -not (TestUiRecoveryRequest $Request)){Toast '原操作结果待核对，请从运行状况查看原记录；本次变更尚未接受';return}
 if(-not $OriginContext){$OriginContext=CaptureNavigationContext}
 if($script:Job){
  if($script:Job.OutcomeUnknown -and -not $policy.ReadOnly -and -not (TestUiRecoveryRequest $Request)){Toast '原操作结果仍待核对，尚未接受新的变更';return}
  $key=@($Request.Action,$Request.Id,$Request.LineId,$Request.RunId,$Request.SessionRef.InstanceId) -join '|'
  if($Silent -and ($script:Job.Key -ceq $key -or @($script:JobQueue|Where-Object Key -ceq $key).Count)){return}
  if($script:JobQueue.Count -ge 32){Toast '等待的操作较多，本次尚未接受，请稍后重试';return}
  $item=@{Request=$Request.Clone();Complete=$Complete;Message=$Message;Transition=$Transition;Failed=$Failed;Silent=[bool]$Silent;OriginContext=$OriginContext;Key=$key}
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
 }catch{[IO.File]::Delete($req);if($Failed){& $Failed '后台任务未能启动，操作尚未分发。'}else{ErrorDialog '后台任务未能启动，操作尚未分发。'};StartNextUiJob;return}
 $script:Job=@{Process=$p;WorkerProcessId=$p.Id;ProcessStartedTicks=$p.StartTime.ToUniversalTime().Ticks;Request=$req;Result=$out;RequestId=$id;OwnershipPath=$ownershipPath;ReusedReadWorker=$reuseRead;Complete=$Complete;Failed=$Failed;Started=Get-Date;Action=$Request.Action;RunId=[string]$Request.RunId;LineId=[string]$(if($Request.LineId){$Request.LineId}else{$Request.Id});Silent=[bool]$Silent;Message=$Message;Policy=$policy;OriginContext=$OriginContext;OutcomeUnknown=$false;Key=(@($Request.Action,$Request.Id,$Request.LineId,$Request.RunId,$Request.SessionRef.InstanceId) -join '|')}
 if(-not $policy.ReadOnly){SaveUiJobReceipt $script:Job 'Dispatched'}
 if(-not $Silent){$script:Footer.Text=$Message};if($Transition){$script:Pending=$Transition;Render}elseif(-not $Silent){$script:HostPanel.IsEnabled=$false}
}
function StartNextUiJob {
 if($script:Job -or -not $script:JobQueue.Count){$script:QueuedJob=$null;return}
 $next=$script:JobQueue[0];$script:JobQueue.RemoveAt(0);$script:QueuedJob=if($script:JobQueue.Count){$script:JobQueue[0]}else{$null}
 $policy=GetUiJobPolicy $next.Request.Action
 if($script:UncertainUiJobs.Count -and -not $policy.ReadOnly -and -not (TestUiRecoveryRequest $next.Request)){Toast '前一操作的结果待核对，已取消这项尚未分发的排队变更';StartNextUiJob;return}
 if(-not $policy.Global -and -not (TestNavigationContext $next.OriginContext)){Toast '页面或目标已变化，尚未分发的原页面操作已取消';StartNextUiJob;return}
 StartJob -Request $next.Request -Complete $next.Complete -Message $next.Message -Transition $next.Transition -Silent:$next.Silent -Failed $next.Failed -OriginContext $next.OriginContext
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
  $editing=($script:ProviderFormOpen -or $view -ne 'nodes' -or [Windows.Input.Keyboard]::FocusedElement -is [Windows.Controls.Primitives.TextBoxBase] -or [Windows.Input.Keyboard]::FocusedElement -is [Windows.Controls.PasswordBox] -or [Windows.Input.Keyboard]::FocusedElement -is [Windows.Controls.ComboBox])
  if($DataChanged -and -not $dialog -and -not $editing){ShowNodes}
  else{
   foreach($node in @($script:Nodes)){
    $key='NodeStatus'+([string]$node.id).Replace('-','')
    if($script:Controls[$key]){$script:Controls[$key].Text=if(NodeHasActiveProfile $node){ActiveLineStatus $node}else{(LineRecommendationView $node).Label}}
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
 $Job.ErrorId=[string]$Result.ErrorId;$Job.ErrorCode=[string]$Result.Code;$Job.ErrorPhase=[string]$Result.Phase
 if($script:Job -eq $Job){$script:Job=$null;$script:Pending=$null;$script:HostPanel.IsEnabled=$true}
 $unknown=(-not $Job.Policy.ReadOnly -and (TestUiJobUnknownResult $Result))
 if($unknown){
  $Job.OutcomeUnknown=$true;$Job.ResultConsumed=$true
  if($Result.Data.TransactionId){$Job.TransactionId=[string]$Result.Data.TransactionId}
  elseif($Result.Data.ConnectionTransaction.TransactionId){$Job.TransactionId=[string]$Result.Data.ConnectionTransaction.TransactionId}
  if(-not $script:UncertainUiJobs.Contains($Job)){$script:UncertainUiJobs.Add($Job)}
 }else{$null=$script:UncertainUiJobs.Remove($Job)}
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
  elseif($Result.Ok){& $Job.Complete $Result.Data}
  else{
   if($Job.Action -eq 'Overview'){SetOverviewReadUnknown $Result.Message}
   elseif($Job.Failed){& $Job.Failed $Result.Message}
   elseif(-not $Job.Silent){ErrorDialog $Result.Message}
  }
 }catch{ErrorDialog '结果已收到，但页面未能显示。请刷新原记录核对。'}
 $remove=@($Job.Request,($Job.Result+'.partial'));if(-not $unknown){$remove+=,$Job.Result}
 foreach($path in $remove){if([IO.File]::Exists($path)){[IO.File]::Delete($path)}}
 if(-not $unknown -and $Job.Process){if(-not $Job.ReusedReadWorker){$Job.Process.Dispose()};$Job.Process=$null}
 if($unknown -and -not $Job.Process){$Job.Dead=$true}
 StartNextUiJob
 if($script:Window.FindName('Overlay').Visibility -eq 'Visible'){$script:HostPanel.IsEnabled=$false}
 UpdateChrome
}
function PollBackgroundJob {
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
 if(((Get-Date)-$j.Started).TotalSeconds -lt $j.Policy.TimeoutSeconds){return}
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
  $button=Btn '查看原操作记录' ('Pending'+$entry.RequestId) {if($this.Tag.RunId){ResumeProductDeployment $this.Tag.RunId}else{ShowRuntimeReport}} 'Ghost';$button.Tag=$entry;AddC $script:HostPanel $button
 }
}
