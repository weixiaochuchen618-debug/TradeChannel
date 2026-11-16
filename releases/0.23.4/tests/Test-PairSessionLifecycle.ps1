#requires -Version 5.1
# 0.21.8 A0 field case: after a computer joined a line with an invitation code,
# 「＋ 添加线路」and「用邀请码加入」both reopened the previous result page, so the
# first step was unreachable and no further line could be added.
#
# Root cause on this side: a finished session stayed in $script:PairSession and
# every snapshot kept publishing its Pair; only Cancel/Reset/another Verify ever
# cleared it. The page now asks the host to begin (BeginChoose/BeginCode), the host
# clears a finished session silently, and leaving the page clears it too.
#
# Loads the real ui/BackgroundJobs.ps1, ui/WebShell.ps1 and ui/OnlinePairingPages.ps1.
# StartJob/StartUiCommand are replaced only to record what the pages hand them and to
# ask the real TestUiJobCallbackContext about admission. No worker, network or data.
[CmdletBinding()]param([string]$PackageRoot='')
$ErrorActionPreference='Stop'
if(-not $PackageRoot){$PackageRoot=Split-Path $PSScriptRoot -Parent}
$script:PackageRoot=[IO.Path]::GetFullPath($PackageRoot)
$script:Root=Join-Path ([IO.Path]::GetTempPath()) ('tc-pair-lifecycle-'+[guid]::NewGuid().ToString('N'))  # Named only; never created.
$checks=New-Object 'Collections.Generic.List[string]'
function Check {param([bool]$Condition,[string]$Name)if(-not $Condition){throw ('FAILED: '+$Name)};$checks.Add($Name)}

. (Join-Path $script:PackageRoot 'ui\BackgroundJobs.ps1')
. (Join-Path $script:PackageRoot 'ui\WebShell.ps1')
. (Join-Path $script:PackageRoot 'ui\OnlinePairingPages.ps1')

# ---- stubs: every side effect that needs a live WebView2 window or a worker ----
$script:Started=New-Object 'Collections.Generic.List[object]'
$script:Commands=New-Object 'Collections.Generic.List[object]'
$script:Toasts=New-Object 'Collections.Generic.List[string]'
$script:Syncs=0
$script:ShownPage=''
$script:Busy=$false
$script:ReadOnly=$false
$script:WebPage='lines'
$script:WebFormActive=$false
$script:PairEpoch=0
$script:PairSession=$null
$script:WebAck=0
function StartJob {param([hashtable]$Request,[scriptblock]$Complete,[string]$Message='',[string]$Transition='',[switch]$Silent,[scriptblock]$Failed=$null,$OriginContext=$null,$CallbackContext=$null,[scriptblock]$Finalized=$null,[switch]$PassThru,$Lifecycle=$null)
 $script:Started.Add([pscustomobject]@{Request=$Request;Complete=$Complete;Failed=$Failed;Finalized=$Finalized;Context=$CallbackContext;Admitted=[bool](TestUiJobCallbackContext $Request $CallbackContext $null ([guid]::NewGuid().ToString('N')))})
}
function StartUiCommand {param([string]$Module,[string]$Command,$Arguments,[object]$Context,[scriptblock]$Complete,[scriptblock]$Failed,[string]$Message='')
 $script:Commands.Add([pscustomobject]@{Module=$Module;Command=$Command;Arguments=$Arguments;Context=$Context;Complete=$Complete;Failed=$Failed;Message=$Message})
}
function Toast {param([string]$Text)$script:Toasts.Add([string]$Text)}
function SyncTCWebState {param([switch]$Force)$script:Syncs=$script:Syncs+1}
function Write-TCPerfTrace {param([string]$Name)}
function ShowTCWebShell {param([string]$Page='home')$script:ShownPage=$Page;$script:WebPage=$Page;return $true}
function ShowOnlinePairingUI {}
function FetchNodes {}
function IsBusy {return [bool]$script:Busy}
function ErrorDialog {param([string]$Text)$script:LastError=$Text}
# The message gate reads the dialog overlay before it reaches the pair branches.
$script:Window=New-Object psobject
$script:Window|Add-Member -MemberType ScriptMethod -Name FindName -Value {param([string]$Name)[pscustomobject]@{Visibility='Collapsed';Text='';Content='';Style=$null}}

$script:Sequence=100
function Send-WebMessage {param([hashtable]$Message)
 $script:Sequence=$script:Sequence+1
 $payload=[ordered]@{}
 foreach($key in $Message.Keys){$payload[$key]=$Message[$key]}
 $payload['Sequence']=$script:Sequence
 InvokeTCWebMessage ($payload|ConvertTo-Json -Compress) 'https://tradechannel.local/index.html'
}
function NewPairSession {param([string]$Phase='Complete',[string]$EnrollmentId='')
 $session=NewTCWebPairSession 'EXAMPLE-PC'
 if($EnrollmentId){$session.EnrollmentId=$EnrollmentId}
 SetTCWebPairPhase $Phase
 return $session
}
$script:ValidCode='TCI1.'+('A'*40)
$enrollment='fd78026c-1111-4222-8333-444455556666'

# 1. A0-01: a finished join no longer survives 「＋ 添加线路」, and the clear is silent.
$session=NewPairSession 'Complete'
$finishedId=$session.PairId
$before=$script:PairEpoch
Send-WebMessage @{Type='pairOnline';Phase='BeginChoose'}
Check ($null -eq $script:PairSession) 'A0-01 BeginChoose drops the finished session'
Check ($script:PairEpoch -eq $before+1) 'A0-01 the session generation moves so late callbacks are inert'
Check ($script:ShownPage -ceq 'add-line') 'A0-01 the host opens the add-line page itself'
Check ($script:Toasts.Count -eq 0) 'A0-01 the finished session is cleared without a toast'
Check (-not (TestUiJobCallbackContext @{Action='PairOnlineFinish';EnrollmentId=$enrollment} @{Type='Pair';Model=$session;Id=$finishedId} $null 'x')) 'A0-01 the cleared session no longer admits its old callbacks'

# 2. A0-02: 「用邀请码加入」 behaves the same and opens step 2.
$session=NewPairSession 'NeedsCheck'
$before=$script:PairEpoch
Send-WebMessage @{Type='pairOnline';Phase='BeginCode'}
Check ($null -eq $script:PairSession -and $script:PairEpoch -eq $before+1) 'A0-02 BeginCode drops the finished session'
Check ($script:ShownPage -ceq 'add-line') 'A0-02 BeginCode opens the add-line page'
Check ($script:Toasts.Count -eq 0) 'A0-02 BeginCode does not claim the join was cancelled'

# 3. A0-04: a running join is kept, says so, and its callbacks stay admitted.
$session=NewPairSession 'Preparing' $enrollment
$runningId=$session.PairId
$toastCount=$script:Toasts.Count
Send-WebMessage @{Type='pairOnline';Phase='BeginChoose'}
Check ([object]::ReferenceEquals($script:PairSession,$session)) 'A0-04 a running join is kept instead of being cleared'
Check ($session.Phase -ceq 'Preparing') 'A0-04 the running phase is unchanged'
Check ($script:Toasts.Count -eq $toastCount+1 -and $script:Toasts[$script:Toasts.Count-1] -ceq '上一条线路还在加入中，完成后可以继续添加') 'A0-04 the user is told the previous join is still running'
Check ($script:ShownPage -ceq 'add-line') 'A0-04 the page still opens while the join runs'
Check ([bool](TestUiJobCallbackContext @{Action='PairOnlineFinish';EnrollmentId=$enrollment} @{Type='Pair';Model=$session;Id=$runningId} $null ([guid]::NewGuid().ToString('N')))) 'A0-04 the running join keeps its admission'
Send-WebMessage @{Type='pairOnline';Phase='Verify';Id=$runningId;Code=$script:ValidCode;Name='EXAMPLE-PC'}
Check ($script:Commands.Count -eq 0 -and $script:Toasts.Count -eq $toastCount+2) 'A0-04 a Verify during a running join is refused with an answer'
Check ([object]::ReferenceEquals($script:PairSession,$session)) 'A0-04 the refused Verify leaves the running join alone'

# 4. A0-05: after a failed join, the same code starts the next attempt cleanly.
ClearTCWebPairSession -Silent
$session=NewPairSession 'Authorizing' $enrollment
$session.ErrorCode='PairJoinUnfinished';$session.ErrorMessage='这次加入还没有完成，请在有效期内重新粘贴同一张邀请码。';$session.NextAction='Reenter'
SetTCWebPairPhase 'Failed'
$failedId=$session.PairId
$toastCount=$script:Toasts.Count;$before=$script:PairEpoch
Send-WebMessage @{Type='pairOnline';Phase='BeginCode'}
Check ($null -eq $script:PairSession -and $script:PairEpoch -eq $before+1) 'A0-05 the failed session is cleared before the new attempt'
Check ($script:Toasts.Count -eq $toastCount) 'A0-05 the failed session is cleared without a toast'
Send-WebMessage @{Type='pairOnline';Phase='Verify';Code=$script:ValidCode;Name='EXAMPLE-PC'}
Check ($script:Commands.Count -eq 1 -and $script:Commands[0].Command -ceq 'New-TCPairOnlineEnrollment') 'A0-05 the same code starts a fresh verification'
Check ([string]$script:Commands[0].Arguments.InvitationCode -ceq $script:ValidCode) 'A0-05 the invitation code reaches the worker unchanged so the original application resumes'
Check ($null -ne $script:PairSession -and $script:PairSession.Phase -ceq 'Creating') 'A0-05 the new attempt is in the confirm phase'
Check ($script:PairSession.PairId -cne $failedId) 'A0-05 the new attempt gets its own session identity'

# 5. A0-07: leaving the add-line page clears a finished session, silently.
$session=NewPairSession 'Complete'
$script:WebPage='add-line'
$toastCount=$script:Toasts.Count
Send-WebMessage @{Type='navigate';Page='lines'}
Check ($null -eq $script:PairSession) 'A0-07 leaving add-line clears the finished session'
Check ($script:Toasts.Count -eq $toastCount) 'A0-07 leaving the page does not claim the join was cancelled'
Check ($script:ShownPage -ceq 'lines') 'A0-07 the requested page is opened'

# The same departure while a join is running keeps it: its callbacks are still live.
$session=NewPairSession 'Preparing' $enrollment
$script:WebPage='add-line'
Send-WebMessage @{Type='navigate';Page='home'}
Check ([object]::ReferenceEquals($script:PairSession,$session)) 'A0-07 a running join survives leaving the page'
Check ($script:ShownPage -ceq 'home') 'A0-07 the page still changes while a join runs'

# Navigating anywhere else with a finished session does not touch it: only the
# departure from add-line is this rule's business.
$session=NewPairSession 'Complete'
$script:WebPage='lines'
Send-WebMessage @{Type='navigate';Page='settings'}
Check ([object]::ReferenceEquals($script:PairSession,$session)) 'A0-07 navigating between other pages leaves the session alone'

# 6. Cancel and Reset keep their toast; only the new callers are silent.
$toastCount=$script:Toasts.Count
ClearTCWebPairSession
Check ($script:Toasts.Count -eq $toastCount+1 -and $script:Toasts[$script:Toasts.Count-1] -ceq '已取消这次加入') 'Cancel still tells the user what happened'
$script:PairSession=NewPairSession 'Complete'
$toastCount=$script:Toasts.Count
Send-WebMessage @{Type='pairReset'}
Check ($null -eq $script:PairSession -and $script:Toasts.Count -eq $toastCount+1) 'Reset still clears and tells the user'

# 7. A busy mirrored form cannot swallow the entry: the refusal answers.
$script:PairSession=NewPairSession 'Complete'
$script:WebFormActive=$true;$script:Busy=$true
$script:ShownPage=''
$toastCount=$script:Toasts.Count
Send-WebMessage @{Type='pairOnline';Phase='BeginChoose'}
Check ($script:Toasts.Count -eq $toastCount+1 -and $script:Toasts[$script:Toasts.Count-1] -ceq '上一步还没有结束，请稍等') 'A0-01 a busy form answers instead of dropping the entry'
Check ($script:ShownPage -ceq '' -and $null -ne $script:PairSession) 'A0-01 the busy refusal neither navigates nor clears'
$script:WebFormActive=$false;$script:Busy=$false

# 8. A0-08: the older join form starts over after a finished join, keeps Retry.
$script:OnlinePairUI=@{Id=[guid]::NewGuid().ToString('N');Stage='Complete';DeviceName='EXAMPLE-PC';EnrollmentId=$enrollment;NodeId='node-1';NodeName='HK';RunId='';Error='';ErrorCode=''}
$finished=$script:OnlinePairUI
OpenOnlinePairingUI
Check ($script:OnlinePairUI.Stage -ceq 'Input' -and $script:OnlinePairUI.Id -cne $finished.Id -and -not $script:OnlinePairUI.EnrollmentId) 'A0-08 the older form reopens at the code input after a finished join'
$script:OnlinePairUI.Stage='NeedsCheck'
$finished=$script:OnlinePairUI
OpenOnlinePairingUI
Check ($script:OnlinePairUI.Stage -ceq 'Input' -and $script:OnlinePairUI.Id -cne $finished.Id) 'A0-08 NeedsCheck also starts over'
$script:OnlinePairUI.Stage='Retry';$script:OnlinePairUI.EnrollmentId=$enrollment
$retry=$script:OnlinePairUI
OpenOnlinePairingUI
Check ([object]::ReferenceEquals($script:OnlinePairUI,$retry) -and $script:OnlinePairUI.Stage -ceq 'Retry' -and $script:OnlinePairUI.EnrollmentId -ceq $enrollment) 'A0-08 Retry keeps the flow so 继续加入 can reuse the enrollment'

[pscustomobject]@{Passed=$true;Checks=$checks.Count;Assertions=$checks.ToArray();NetworkChanged=$false}|ConvertTo-Json
