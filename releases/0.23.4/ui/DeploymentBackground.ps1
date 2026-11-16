# Background deployment owns a run/session, never the current navigation page.
# The host loads this after DeploymentPages and calls PollDeploymentBackgroundUI
# before its timer's foreground-job early return. No worker contract is widened.
function InitializeDeploymentBackgroundUI {
 if(-not (Get-Variable DeploymentBackgroundJobs -Scope Script -ErrorAction SilentlyContinue)){$script:DeploymentBackgroundJobs=@{}}
 if(-not (Get-Variable DeploymentBackgroundNotifications -Scope Script -ErrorAction SilentlyContinue)){$script:DeploymentBackgroundNotifications=New-Object 'Collections.Generic.List[object]'}
 Import-Module (Join-Path $script:PackageRoot 'DeploymentFlow.psm1') -DisableNameChecking
}
function TestDeploymentBackgroundRegisteredUI {param($Flow)
 if(-not (Get-Variable DeploymentBackgroundJobs -Scope Script -ErrorAction SilentlyContinue)){return $false}
 $id=[string](ProfileUIField (ProfileUIField $Flow 'Run') 'RunId' '');$entry=$script:DeploymentBackgroundJobs[$id]
 return ($entry -and [object]::ReferenceEquals($entry.Flow,$Flow) -and ($entry.Enabled -or $entry.Pending))
}
function TestDeploymentBackgroundPendingUI {param([string]$RunId)
 if(-not (Get-Variable DeploymentBackgroundJobs -Scope Script -ErrorAction SilentlyContinue)){return $false}
 $entry=$script:DeploymentBackgroundJobs[$RunId];return ($entry -and [bool]$entry.Pending)
}
function TestDeploymentBackgroundWorkPendingUI {
 if(-not (Get-Variable DeploymentBackgroundJobs -Scope Script -ErrorAction SilentlyContinue)){return $false}
 return (@($script:DeploymentBackgroundJobs.Values|Where-Object {$_.Enabled -or $_.Pending}).Count -gt 0)
}
function TestDeploymentBackgroundAvailableUI {
 # Snapshot-only predicate. No module import, file/pipe access, registration,
 # credential disposal, notification or mutation of Flow/Run is allowed here.
 if($script:ReadOnly -or $script:Smoke -or -not $script:DeployUI.Run -or $script:Role -ne 'deployment'){return $false}
 $flow=$script:DeployUI;$run=$flow.Run;$session=$flow.SessionRef
 if($flow.Reauth -or $flow.Identity -or $flow.ManagementMode -or $flow.PendingManagement -or $flow.SessionStarting -or $flow.SessionAttaching -or $flow.TrustAuthenticating -or $flow.PauseAtCheckpoint){return $false}
 if(-not $session -or -not $flow.SessionAttached -or [string]$session.RunId -cne [string]$run.RunId -or -not [string]$session.InstanceId){return $false}
 if((ProfileUIField $run 'RecoveryRequired' $false) -or (ProfileUIField $run 'ProbeRecoveryRequired' $false) -or (ProfileUIField $run 'UnresolvedTcpMutation') -or (ProfileUIField $run 'AccessIssue') -or $run.Status -in @('OutcomeUnknown','NeedsRecovery','Cancelled','Complete','Failed') -or (ProfileUIField $run 'PausedContinuation') -or $run.Stage -eq 'RecoveryVerified'){return $false}
 if($script:UncertainUiJobs -and $script:UncertainUiJobs.Count){return $false}
 if($script:Job -and ([string]$script:Job.Action -notin @('DeploymentPoll','DeploymentProceed','DeploymentSessionSnapshot') -or ([string](ProfileUIField $script:Job 'RunId' '') -and [string]$script:Job.RunId -cne [string]$run.RunId))){return $false}
 foreach($memory in @($script:UiMemoryJobs)){
  if($memory -and [string](ProfileUIField (ProfileUIField $memory 'Context') 'Type' '') -cne 'DeploymentBackground'){return $false}
 }
 if(Get-Variable DeploymentBackgroundJobs -Scope Script -ErrorAction SilentlyContinue){
  $existing=$script:DeploymentBackgroundJobs[[string]$run.RunId]
  if($existing -and ($existing.Enabled -or $existing.Pending) -and (-not [object]::ReferenceEquals($existing.Flow,$flow) -or [string]$existing.SessionInstanceId -cne [string]$session.InstanceId)){return $false}
  if(-not $existing -and $script:DeploymentBackgroundJobs.Count -ge 8 -and -not @($script:DeploymentBackgroundJobs.Values|Where-Object {-not $_.Enabled -and -not $_.Pending}).Count){return $false}
 }
 if($run.Status -in @('Running','Dispatching') -or (DeploymentLocalCheckPending $run)){return $true}
 $consent=ProfileUIField $flow 'PreparationConsent'
 if($run.Stage -eq 'PlanReady' -and $run.Status -eq 'WaitingUser'){return [bool](Test-TCDeploymentPreparationConsent -Consent $consent -Run $run -ForReview)}
 if($run.Status -eq 'Idle' -and $run.Stage -in @('Inspect','ServerInfo','InspectTcp','MaterializeCandidate','MaterializeTcp')){return ([string](ProfileUIField $consent 'State' '') -ceq 'Active' -and [bool](Test-TCDeploymentPreparationConsent -Consent $consent -Run $run))}
 return $false
}
function EnableDeploymentBackgroundUI {
 if(-not (TestDeploymentBackgroundAvailableUI)){return $false}
 $flow=$script:DeployUI;$run=$flow.Run;$session=$flow.SessionRef
 InitializeDeploymentBackgroundUI
 $id=[string]$run.RunId;$entry=$script:DeploymentBackgroundJobs[$id]
 if($entry -and ($entry.Pending -or $entry.Enabled)){
  if(-not [object]::ReferenceEquals($entry.Flow,$flow) -or [string]$entry.SessionInstanceId -cne [string]$session.InstanceId){return $false}
  $entry.Enabled=$true;return $true
 }
 $consent=$null;try{$consent=Get-TCDeploymentPreparationConsent -Root $script:Root -RunId $id}catch{}
 if(-not $entry -and $script:DeploymentBackgroundJobs.Count -ge 8){
  $old=@($script:DeploymentBackgroundJobs.Values|Where-Object {-not $_.Enabled -and -not $_.Pending}|Sort-Object CreatedAtUtc|Select-Object -First 1)
  if(-not $old.Count){return $false};$script:DeploymentBackgroundJobs.Remove([string]$old[0].RunId)
 }
 $entry=@{RunId=$id;Flow=$flow;Run=$run;SessionRef=$session;SessionInstanceId=[string]$session.InstanceId;ConsentId=[string](ProfileUIField $consent 'ConsentId' '');Token=[guid]::NewGuid().ToString('N');Pending=$false;Enabled=$true;RequestId='';LastPoll=[DateTime]::MinValue;CreatedAtUtc=[DateTimeOffset]::UtcNow.ToString('o');Progress=(Get-TCDeploymentProgress $run);Notifications=@{};Error='';CompletedSessionClosed=$false}
 $script:DeploymentBackgroundJobs[$id]=$entry
 # The authenticated executor owns the live SSH session. Background work never
 # needs the login secret or a visible password editor retained by the page.
 ClearDeploymentCredentialUI
 return $true
}
function SendDeploymentToBackgroundUI {
 if(-not (EnableDeploymentBackgroundUI)){return $false}
 $script:Step=0;$script:Role='client'
 if(-not ((Get-Command ShowTCWebShell -ErrorAction SilentlyContinue) -and (ShowTCWebShell 'lines'))){ShowNodes}
 FetchNodes;Toast '部署在后台继续，完成或需要处理时会提醒你'
 return $true
}
function TestDeploymentBackgroundCallbackUI {param($Context)
 if(-not $Context -or [string](ProfileUIField $Context 'Type' '') -cne 'DeploymentBackground' -or -not (Get-Variable DeploymentBackgroundJobs -Scope Script -ErrorAction SilentlyContinue)){return $false}
 $entry=$script:DeploymentBackgroundJobs[[string]$Context.RunId]
 if(-not $entry -or -not [object]::ReferenceEquals($entry,$Context.Entry) -or -not [object]::ReferenceEquals($entry.Flow,$Context.Flow)){return $false}
 if([string]$entry.Token -cne [string]$Context.Token -or [string]$entry.RequestId -cne [string]$Context.RequestId -or [string]$entry.SessionInstanceId -cne [string]$Context.SessionInstanceId){return $false}
 if([string](ProfileUIField (ProfileUIField $entry.Flow 'Run') 'RunId' '') -cne [string]$Context.RunId -or [string](ProfileUIField (ProfileUIField $entry.Flow 'SessionRef') 'InstanceId' '') -cne [string]$Context.SessionInstanceId){return $false}
 return $true
}
function RetireDeploymentBackgroundCallbackUI {param($Context)
 if(-not $Context -or -not (Get-Variable DeploymentBackgroundJobs -Scope Script -ErrorAction SilentlyContinue)){return}
 $entry=$script:DeploymentBackgroundJobs[[string](ProfileUIField $Context 'RunId' '')]
 if($entry -and [object]::ReferenceEquals($entry,(ProfileUIField $Context 'Entry')) -and [string]$entry.Token -ceq [string](ProfileUIField $Context 'Token' '') -and [string]$entry.RequestId -ceq [string](ProfileUIField $Context 'RequestId' '')){
  $entry.Pending=$false;$entry.Enabled=$false;$entry.Error='原部署会话已变化，请打开任务查看。'
 }
}
function PublishDeploymentBackgroundNotificationUI {param($Entry,[string]$State,[string]$Message='')
 if($State -notin @('Complete','NeedsAttention','Paused','Cancelled')){return}
 $run=$Entry.Run
 $signature=(@($State,[string](ProfileUIField $run 'Stage' ''),[string](ProfileUIField (ProfileUIField $run 'LastError') 'Code' ''),[string](ProfileUIField (ProfileUIField $run 'AccessIssue') 'Kind' '')) -join '|')
 if($Entry.Notifications.ContainsKey($signature)){return};$Entry.Notifications[$signature]=$true
 $title=if($State -eq 'Complete'){'线路已准备好'}elseif($State -eq 'Paused'){'部署已暂停'}elseif($State -eq 'Cancelled'){'部署已取消'}else{'部署需要处理'}
 if(-not $Message){$Message=if($State -eq 'Complete'){'打开任务后可选择连接。'}elseif($State -eq 'Paused'){'进度已保存，打开任务可继续。'}elseif($State -eq 'Cancelled'){'原任务记录已保留。'}else{'打开原任务查看下一步。'}}
 $notice=[pscustomobject]@{RunId=$Entry.RunId;Name=[string](ProfileUIField $run 'Name' '线路');State=$State;Title=$title;Message=$Message;AtUtc=[DateTimeOffset]::UtcNow.ToString('o');ConnectionStarted=$false}
 if($script:DeploymentBackgroundNotifications.Count -ge 64){$script:DeploymentBackgroundNotifications.RemoveAt(0)}
 $script:DeploymentBackgroundNotifications.Add($notice);$script:LastDeploymentBackgroundNotification=$notice
 if(Get-Command Toast -ErrorAction SilentlyContinue){Toast ($notice.Name+' · '+$title)}
 if($script:Tray -and $script:Tray.Visible){$script:DeploymentTrayNotificationRunId=$notice.RunId;$script:Tray.ShowBalloonTip(5000,'TradeChannel · '+$title,($notice.Name+'。'+$Message),[Windows.Forms.ToolTipIcon]::Info)}
}
function CompleteDeploymentBackgroundTickUI {param($Result,$Context)
 if(-not (TestDeploymentBackgroundCallbackUI $Context)){RetireDeploymentBackgroundCallbackUI $Context;return}
 $entry=$Context.Entry;$entry.Pending=$false
 if(-not $Result -or [string](ProfileUIField $Result 'RunId' '') -cne [string]$entry.RunId -or [string](ProfileUIField $Result 'SessionInstanceId' '') -cne [string]$entry.SessionInstanceId -or [string](ProfileUIField (ProfileUIField $Result 'Run') 'RunId' '') -cne [string]$entry.RunId){
  $entry.Enabled=$false;$entry.Error='后台结果不属于原任务，请打开原任务查看。';PublishDeploymentBackgroundNotificationUI $entry NeedsAttention $entry.Error;return
 }
 if([long](ProfileUIField $Result.Run 'Revision' 0) -lt [long](ProfileUIField $entry.Flow.Run 'Revision' 0)){return}
 $entry.Run=$Result.Run;$entry.Flow.Run=$Result.Run;$entry.Progress=$Result.Progress;$entry.Error=''
 $entry.Enabled=([bool]$entry.Enabled -and [bool]$Result.ContinuePolling)
 $state=[string]$Result.Progress.State
 PublishDeploymentBackgroundNotificationUI $entry $state
 if($state -in @('Complete','Cancelled') -and -not $entry.CompletedSessionClosed){
  $entry.CompletedSessionClosed=$true;CloseUiDeploymentSession $entry.SessionRef
 }
 if([object]::ReferenceEquals($script:DeployUI,$entry.Flow) -and $script:Role -eq 'deployment' -and $script:Page -eq 'setup'){
  $script:DeployUI.PollError='';$script:DeployUI.WorkerFailure=$null;ShowProductDeployment
 }
}
function FailDeploymentBackgroundTickUI {param([string]$Message,$Context,$Failure)
 if(-not (TestDeploymentBackgroundCallbackUI $Context)){RetireDeploymentBackgroundCallbackUI $Context;return}
 $entry=$Context.Entry;$entry.Pending=$false
 if([string](ProfileUIField $Failure 'Code' '') -in @('Busy','LocalStateBusy','ExecutorBusy')){$entry.LastPoll=Get-Date;return}
 $entry.Enabled=$false;$entry.Error='后台部署已停在原步骤，请打开任务查看。'
 PublishDeploymentBackgroundNotificationUI $entry NeedsAttention $entry.Error
 if([object]::ReferenceEquals($script:DeployUI,$entry.Flow) -and $script:Role -eq 'deployment' -and $script:Page -eq 'setup'){$script:DeployUI.PollError=$entry.Error;ShowProductDeployment}
}
function PollDeploymentBackgroundUI {
 if($script:Smoke -or $script:ReadOnly -or -not (Get-Variable DeploymentBackgroundJobs -Scope Script -ErrorAction SilentlyContinue)){return}
 # Foreground workers have their own resource/uncertainty contract. Wait for
 # them, including a live original deployment poll, rather than duplicating it.
 if($script:Job -or ($script:UncertainUiJobs -and $script:UncertainUiJobs.Count)){return}
 foreach($memory in @($script:UiMemoryJobs)){if($memory -and [string](ProfileUIField (ProfileUIField $memory 'Context') 'Type' '') -cne 'DeploymentBackground'){return}}
 foreach($entry in @($script:DeploymentBackgroundJobs.Values|Sort-Object CreatedAtUtc)){
  if(-not $entry.Enabled -or $entry.Pending -or ((Get-Date)-$entry.LastPoll).TotalSeconds -lt 2){continue}
  if(@($script:DeploymentBackgroundJobs.Values|Where-Object Pending).Count){return}
  $entry.Pending=$true;$entry.LastPoll=Get-Date;$entry.RequestId=[guid]::NewGuid().ToString('N')
  $context=@{Type='DeploymentBackground';Entry=$entry;Flow=$entry.Flow;RunId=$entry.RunId;Token=$entry.Token;RequestId=$entry.RequestId;SessionInstanceId=$entry.SessionInstanceId}
  StartUiCommand -Module 'DeploymentFlow.psm1' -Command 'Invoke-TCDeploymentBackgroundTick' -Arguments @{Root=$script:Root;RunId=$entry.RunId;SessionInstanceId=$entry.SessionInstanceId;ConsentId=$entry.ConsentId} -Context $context -Complete {param($result,$context)CompleteDeploymentBackgroundTickUI $result $context} -Failed {param($message,$context,$failure)FailDeploymentBackgroundTickUI $message $context $failure} -Message '后台部署正在继续…'
  return
 }
}
function GetDeploymentBackgroundSummaryUI {
 if(-not (Get-Variable DeploymentBackgroundJobs -Scope Script -ErrorAction SilentlyContinue)){return @()}
 return @(foreach($entry in @($script:DeploymentBackgroundJobs.Values|Sort-Object CreatedAtUtc)){
  $progress=$entry.Progress
  [pscustomobject]@{RunId=$entry.RunId;Name=[string](ProfileUIField $entry.Run 'Name' '线路');State=$(if($entry.Error){'NeedsAttention'}else{$progress.State});Summary=$(if($entry.Error){'部署需要处理'}else{$progress.Summary});CurrentStep=$progress.CurrentStep;Steps=$progress.Steps;Running=([bool]$entry.Enabled -or [bool]$entry.Pending);CanConnect=$false}
 })
}
function RestoreDeploymentBackgroundFlowUI {param([string]$RunId)
 if(-not (Get-Variable DeploymentBackgroundJobs -Scope Script -ErrorAction SilentlyContinue)){return $false}
 $entry=$script:DeploymentBackgroundJobs[$RunId];if(-not $entry){return $false}
 if($script:ReadOnly){return $false}
 $entry.Enabled=$false
 if(-not [object]::ReferenceEquals($script:DeployUI,$entry.Flow)){ClearDeploymentCredentialUI}
 $script:DeployUI=$entry.Flow;$script:DeployUI.Run=$entry.Run;$script:Role='deployment';$script:Page='setup';$script:Step=1
 $script:DeployUI.LastPoll=[DateTime]::MinValue
 if($entry.Error){$script:DeployUI.PollError=$entry.Error}
 ShowProductDeployment;return $true
}
function OpenDeploymentBackgroundRunUI {param([Parameter(Mandatory=$true)][string]$RunId)
 if($script:ReadOnly){return}
 if(-not (RestoreDeploymentBackgroundFlowUI $RunId)){ResumeProductDeployment $RunId}
}
function OpenLastDeploymentBackgroundNotificationUI {
 $notice=Get-Variable LastDeploymentBackgroundNotification -Scope Script -ValueOnly -ErrorAction SilentlyContinue
 $owner=[string](Get-Variable DeploymentTrayNotificationRunId -Scope Script -ValueOnly -ErrorAction SilentlyContinue)
 if(-not $notice -or -not $owner -or $owner -cne [string]$notice.RunId){return $false}
 $script:LastDeploymentBackgroundNotification=$null;$script:DeploymentTrayNotificationRunId=''
 if(Get-Command ShowExistingConsole -ErrorAction SilentlyContinue){ShowExistingConsole}
 OpenDeploymentBackgroundRunUI -RunId $notice.RunId;return $true
}
function ReleaseDeploymentBackgroundSessionsUI {
 if($script:Smoke -or -not (Get-Variable DeploymentBackgroundJobs -Scope Script -ErrorAction SilentlyContinue)){return}
 Import-Module (Join-Path $script:PackageRoot 'DeploymentTransport.psm1') -DisableNameChecking
 foreach($entry in @($script:DeploymentBackgroundJobs.Values)){
  if($entry.Pending -or $entry.Enabled -or $entry.CompletedSessionClosed -or -not $entry.SessionRef){continue}
  if([string]$entry.SessionRef.RunId -cne [string]$entry.RunId -or [string]$entry.SessionRef.InstanceId -cne [string]$entry.SessionInstanceId){continue}
  try{$result=Stop-TCDeploySession -SessionRef $entry.SessionRef -ReadTimeoutMs 1000 -TotalTimeoutMs 1500;if($result.Closed){$entry.CompletedSessionClosed=$true}}catch{}
 }
}
