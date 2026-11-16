#requires -Version 5.1
# 0.21.7 field case: a new computer confirmed its invite code, but 「加入这台电脑」
# never started the redeem task. StartJob refused the join's untyped callback
# context before dispatch, so the page spun on nothing and the code expired
# unused. The same refusal kept line quality history loading forever. Loads the
# real UI scripts; StartJob is replaced only to record what the pages hand it
# and to ask the real admission check about it. No worker, network or data.
[CmdletBinding()]param([string]$PackageRoot='')
$ErrorActionPreference='Stop'
if(-not $PackageRoot){$PackageRoot=Split-Path $PSScriptRoot -Parent}
$script:PackageRoot=[IO.Path]::GetFullPath($PackageRoot)
$script:Root=Join-Path ([IO.Path]::GetTempPath()) ('tc-pair-dispatch-'+[guid]::NewGuid().ToString('N'))  # Named only; never created.
$checks=New-Object 'Collections.Generic.List[string]'
function Check {param([bool]$Condition,[string]$Name)if(-not $Condition){throw ('FAILED: '+$Name)};$checks.Add($Name)}

. (Join-Path $script:PackageRoot 'ui\BackgroundJobs.ps1')
. (Join-Path $script:PackageRoot 'ui\WebShell.ps1')
. (Join-Path $script:PackageRoot 'ui\OnlinePairingPages.ps1')
. (Join-Path $script:PackageRoot 'ui\ConnectionProfilePages.ps1')

$script:Started=New-Object 'Collections.Generic.List[object]'
function StartJob {param([hashtable]$Request,[scriptblock]$Complete,[string]$Message='',[string]$Transition='',[switch]$Silent,[scriptblock]$Failed=$null,$OriginContext=$null,$CallbackContext=$null,[scriptblock]$Finalized=$null,[switch]$PassThru,$Lifecycle=$null)
 $script:Started.Add([pscustomobject]@{Request=$Request;Complete=$Complete;Failed=$Failed;Finalized=$Finalized;Context=$CallbackContext;Admitted=[bool](TestUiJobCallbackContext $Request $CallbackContext $null ([guid]::NewGuid().ToString('N')))})
}
function Last {$script:Started[$script:Started.Count-1]}
function Toast {param([string]$Text)$script:LastToast=$Text}
function SyncTCWebState {param([switch]$Force)}
function FetchNodes {}
function IsBusy {return $false}
function ErrorDialog {param([string]$Text)$script:LastError=$Text}
function ShowOnlinePairingUI {}
$script:ReadOnly=$false
$enrollment='fd78026c-1111-4222-8333-444455556666'
function NewJoin {
 $script:PairSession=$null
 $session=NewTCWebPairSession 'EXAMPLE-PC';$session.EnrollmentId=$enrollment
 SetTCWebPairPhase 'Authorizing' '邀请码已确认，可以加入这台电脑'
 InvokeTCWebPairOnline @{Phase='Join';Id=$session.PairId;Name='香港线路'}
 $session
}

# 1. Confirmed code -> join -> redeem -> set up the line.
$session=NewJoin;$finish=Last
Check ($finish.Request.Action -ceq 'PairOnlineFinish' -and $finish.Request.EnrollmentId -ceq $enrollment) 'Joining starts the redeem task for this enrollment'
Check $finish.Admitted 'The task launcher admits the join instead of refusing it before dispatch'
& $finish.Complete ([pscustomobject]@{EnrollmentId=$enrollment;NodeName='HK';OnlineStatus='AuthorizationReceived'}) $finish.Context
$complete=Last
Check ($session.Phase -ceq 'Preparing' -and $complete.Request.Action -ceq 'PairComplete' -and $complete.Request.EnrollmentId -ceq $enrollment) 'A redeemed code moves on to setting up the line'
Check ($complete.Admitted -and (TestUiJobCallbackContext $complete.Request $complete.Context $null 'x')) 'Setting up the line is admitted and its result reaches the page'
& $complete.Complete ([pscustomobject]@{EnrollmentId=$enrollment;NodeName='HK';DeploymentCompleteness='Complete'}) $complete.Context
& $complete.Finalized ([pscustomobject]@{Status='Completed';Code='Completed'}) $complete.Context
& $finish.Finalized ([pscustomobject]@{Status='Completed';Code='Completed'}) $finish.Context
Check ($session.Phase -ceq 'Complete') 'The joined line is shown and the ending requests do not overwrite it'

# 2. Refused before it ran: stop the spinner and ask for the same code again.
$session=NewJoin;$refused=Last
& $refused.Finalized ([pscustomobject]@{Status='Rejected';Code='MutationBlocked'}) $refused.Context
Check ($session.Phase -ceq 'Failed' -and $session.ErrorCode -ceq 'PairJoinUnfinished' -and $session.NextAction -ceq 'Reenter') 'A refused join says so and offers to paste the same code again'

# 3. The redeem step ends without reaching the page (timed out).
$session=NewJoin;$finish=Last
& $finish.Finalized ([pscustomobject]@{Status='OutcomeUnknown';Code='WorkerOutcomeUnknown'}) $finish.Context
Check ($session.Phase -ceq 'Failed' -and $session.ErrorCode -ceq 'PairJoinUnfinished') 'A redeem step without a result does not leave the page spinning'

# 4. Setting up the line outlives its time limit.
$session=NewJoin;$finish=Last
& $finish.Complete ([pscustomobject]@{EnrollmentId=$enrollment;NodeName='HK'}) $finish.Context
$complete=Last
& $complete.Finalized ([pscustomobject]@{Status='OutcomeUnknown';Code='WorkerOutcomeUnknown'}) $complete.Context
Check ($session.Phase -ceq 'Failed' -and $session.ErrorCode -ceq 'OnlineEnrollmentIncomplete' -and $session.NextAction -ceq 'ContinueJoin') 'A setup that times out says the line is not finished and offers to continue'

# 5. Only the live join and its own enrollment are admitted.
$stale=$complete.Context
ClearTCWebPairSession
Check (-not (TestUiJobCallbackContext $complete.Request $stale $null 'x')) 'A cancelled join cannot deliver into a later page'
$session=NewTCWebPairSession 'EXAMPLE-PC';$session.EnrollmentId=$enrollment;$live=@{Type='Pair';Model=$session;Id=$session.PairId}
Check (-not (TestUiJobCallbackContext @{Action='PairOnlineFinish';EnrollmentId='00000000-1111-4222-8333-444455556666'} $live $null 'x')) 'A join context admits only its own enrollment'
Check (-not (TestUiJobCallbackContext @{Action='Session';SessionAction='Connect'} $live $null 'x')) 'A join context does not admit unrelated actions'

# 6. The older join form (WPF mirror).
$script:OnlinePairUI=@{Id=[guid]::NewGuid().ToString('N');Stage='Input';DeviceName='EXAMPLE-PC';EnrollmentId=$enrollment;NodeId='';NodeName='';RunId='';Error='';ErrorCode=''}
ContinueOnlinePairingUI
$finish=Last
Check ($finish.Request.Action -ceq 'PairOnlineFinish' -and $finish.Admitted) 'The older join form is admitted too'
& $finish.Complete ([pscustomobject]@{EnrollmentId=$enrollment;NodeName='HK'}) $finish.Context
$complete=Last
Check ($complete.Request.Action -ceq 'PairComplete' -and $complete.Admitted) 'Its line setup is admitted'
& $complete.Complete ([pscustomobject]@{EnrollmentId=$enrollment;NodeId='node-1';RunId=$enrollment;DeploymentCompleteness='Complete'}) $complete.Context
ConnectOnlinePairLineUI
$read=Last
Check ($read.Request.Action -ceq 'Nodes' -and $read.Admitted) 'Connecting the joined line from that form reads the lines first'

# 7. Line quality history in the line drawer.
$script:Nodes=@([pscustomobject]@{id='line-1';LineId='line-1';Name='HK'})
LoadTCWebQualityHistory 'line-1' 'Day'
$history=Last
Check ($history.Request.Action -ceq 'LineQualityHistory' -and $history.Admitted) 'Opening a line drawer reads its quality history'
LoadTCWebQualityHistory 'line-1' 'Close'
Check (-not (TestUiJobCallbackContext $history.Request $history.Context $null 'x')) 'A closed drawer no longer receives that history'

[pscustomobject]@{Passed=$true;Checks=$checks.Count;Assertions=$checks.ToArray();NetworkChanged=$false}|ConvertTo-Json
