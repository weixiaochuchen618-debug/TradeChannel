#requires -Version 5.1
[CmdletBinding()]param([string]$PackageRoot,[string]$ReportPath)
$ErrorActionPreference='Stop';$env:PSModulePath=Join-Path $PSHOME 'Modules'
if($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5){throw 'Use Windows PowerShell 5.1.'}
if(-not $PackageRoot){$PackageRoot=Split-Path $PSScriptRoot -Parent}
$script:PackageRoot=[IO.Path]::GetFullPath($PackageRoot)
$script:Root=Join-Path ([IO.Path]::GetTempPath()) ('tc-inline-'+[guid]::NewGuid().ToString('N'))
$script:JobRoot=Join-Path $script:Root 'jobs';$null=[IO.Directory]::CreateDirectory($script:JobRoot)
. (Join-Path $script:PackageRoot 'ui\ConnectionProfilePages.ps1')
. (Join-Path $script:PackageRoot 'ui\LineCardControls.ps1')
. (Join-Path $script:PackageRoot 'ui\BackgroundJobs.ps1')
$script:WebReady=$true;$script:WebFailed=$false;$script:Smoke=$false;$script:ReadOnly=$false
$script:Busy=$false;$script:Page='web';$script:Generation=1;$script:Syncs=0;$script:Fetches=0;$script:Overviews=0
$script:Jobs=New-Object 'Collections.Generic.List[object]';$script:Checks=New-Object 'Collections.Generic.List[string]'
$script:Dialogs=New-Object 'Collections.Generic.List[string]';$script:Toasts=New-Object 'Collections.Generic.List[string]'
$script:Footer=[pscustomobject]@{Text=''};$script:HostPanel=[pscustomobject]@{IsEnabled=$true};$script:Overlay=[pscustomobject]@{Visibility='Collapsed'}
$script:Window=[pscustomobject]@{};$script:Window|Add-Member ScriptMethod FindName {param($Name)$script:Overlay}
$id='11111111-1111-1111-1111-111111111111';$other='22222222-2222-2222-2222-222222222222'
$script:Nodes=@([pscustomobject]@{LineId=$id;Name='主线路';Revision=7;Profiles=@([pscustomobject]@{Id='Udp';Revision=2;PreparationState='Ready';CandidateSHA256=('A'*64)},[pscustomobject]@{Id='Tcp';Revision=3;PreparationState='Ready';CandidateSHA256=('B'*64)});DefaultVerified=$true;SavedConnectionPreference=@{ProfileId='Udp';Source='UserChoice';Digest=('C'*64)}})
$script:Overview=[pscustomobject]@{StateKey='Connected';Running=$true;ReadState='Known';NodeName='主线路';ActiveLineId=$id}
function IsBusy {$script:Busy}
function NodeEntry {param($Id)@($script:Nodes|Where-Object LineId -ceq $Id)|Select-Object -First 1}
function TradeLabel {$script:Overview.NodeName}
function RefreshLineCardControlsUI {}
function GetLineCardStateUI {param($Node)[pscustomobject]@{CheckProfileId='Udp';Revision=$Node.Revision}}
function SyncTCWebState {param([switch]$Force)$script:Syncs++}
function FetchNodes {$script:Fetches++}
function RefreshOverview {param([switch]$Silent)$script:Overviews++}
function UpdateChrome {}
function StartNextUiJob {}
function TestNavigationContext {param($Context)$Context.Revision -eq $script:Generation}
function ErrorDialog {param($Message)$script:Dialogs.Add($Message)}
function Toast {param($Message)$script:Toasts.Add($Message)}
function RefreshUiJobReceipts {}
function OpenUiReceiptDialog {param($Entry)$script:OpenedReceipt=$Entry.RequestId}
function Start-Process {throw 'Real process start forbidden'}
function Stop-Process {throw 'Real process stop forbidden'}
function Invoke-WebRequest {throw 'Network forbidden'}
function Invoke-RestMethod {throw 'Network forbidden'}
# Capture only the process boundary; dispatch completion and lifecycle stay real.
function StartJob {param($Request,$Complete,$Message,$Transition,[switch]$Silent,$Failed,$OriginContext,$CallbackContext,$Finalized)
 $workerId=[guid]::NewGuid().ToString('N');$uiId=$CallbackContext.UiRequestId
 $job=@{RequestId=$workerId;UiRequestId=$uiId;Action=$Request.Action;LineId=$Request.Id;RequestData=$Request.Clone();Request=(Join-Path $script:JobRoot ($workerId+'.request.json'));Result=(Join-Path $script:JobRoot ($workerId+'.result.json'));Complete=$Complete;Failed=$Failed;CallbackContext=$CallbackContext;OriginContext=@{Revision=$script:Generation};Policy=(GetUiJobPolicy $Request.Action);Silent=$false;Started=(Get-Date);OutcomeUnknown=$false;ResourceScope=@{Kind='Line';Id=$Request.Id};Lifecycle=@{UiRequestId=$uiId;RequestId=$workerId;Finalized=$Finalized;CallbackContext=$CallbackContext;FinalizedDelivered=$false}}
 $script:Jobs.Add($job)
}
function Check {param([bool]$Ok,[string]$Name)if(-not $Ok){throw $Name};$script:Checks.Add($Name)}
function Finish {param($Job,[bool]$Ok,$Data=$null,[string]$Code='',[bool]$Unknown=$false)
 CompleteUiJob $Job ([pscustomobject]@{Ok=$Ok;Data=$Data;Code=$Code;Message=('[TC:'+$(if($Code){$Code}else{'FixtureFailure'})+'] 检查超时，请重试。');OutcomeUnknown=$Unknown})
}
function Feedback {param([string]$Kind='Preference')$script:LineActionFeedback[$id][$Kind]}
$passed=$false;$failure=''
try{
 SaveLineDefaultProfileForLineUI $id Tcp -Origin Card;$j=$script:Jobs[-1]
 Check ($j.RequestData.ExpectedRevision -eq 7 -and $j.RequestData.ProfileId -ceq 'Tcp') 'save targets the exact line, method and current revision'
 $script:Generation++ # The user visits another page while the worker runs.
 Finish $j $false -Code PreferenceRevisionChanged
 $f=Feedback
 Check ($f.Status -ceq 'RefreshRequired' -and $f.CanRetry -and -not $f.NeedsReview -and $script:Fetches -eq 1) 'cross-page save refusal remains attached to its line with a retry'
 Check ($script:Dialogs.Count -eq 0 -and $script:Toasts.Count -eq 0 -and $script:Nodes[0].SavedConnectionPreference.ProfileId -ceq 'Udp') 'refused save neither opens a dialog nor changes the saved selection'
 $script:Nodes[0].Revision=9;$count=$script:Jobs.Count
 RetryLineActionUI $id 'wrong-feedback-id'
 Check ($script:Jobs.Count -eq $count) 'stale feedback identity cannot submit a retry'
 RetryLineActionUI $id $f.Id;$new=$script:Jobs[-1]
 Check ($new.RequestData.ExpectedRevision -eq 9 -and $new.RequestData.ProfileId -ceq 'Tcp') 'retry reloads the latest revision while retaining the attempted method'
 RetryLineActionUI $id $f.Id
 Check ($script:Jobs.Count -eq ($count+1)) 'double click cannot duplicate the retry'
 & $j.Failed 'late failure' $j.CallbackContext @{Code='Late'}
 Check (-not (Feedback)) 'old callback cannot overwrite a new request'
 $saved=$script:Nodes[0].PSObject.Copy();$saved.SavedConnectionPreference=@{ProfileId='Tcp';Source='UserChoice';Digest=('D'*64)}
 Finish $new $true $saved
 Check ((Feedback).Status -ceq 'Succeeded' -and -not (Feedback).CanRetry -and $script:Nodes[0].SavedConnectionPreference.ProfileId -ceq 'Tcp') 'success replaces the old error and updates only the verified selection'
 ResetLineDefaultProfileForLineUI $id;$reset=$script:Jobs[-1]
 Finish $reset $false -Code PreferenceDigestChanged
 $f=Feedback
 Check ($f.Status -ceq 'RefreshRequired' -and $f.Action -ceq 'PreferenceReset') 'automatic selection refusal has its own recoverable feedback'
 $script:Nodes[0].Revision=11;$script:Nodes[0].SavedConnectionPreference.Digest=('E'*64)
 RetryLineActionUI $id $f.Id;$auto=$script:Jobs[-1]
 Check ($auto.RequestData.ExpectedRevision -eq 11 -and $auto.RequestData.ExpectedDigest -ceq ('E'*64)) 'automatic retry uses the fresh digest and revision'
 $autoLine=$script:Nodes[0].PSObject.Copy();$autoLine|Add-Member NoteProperty PreferenceMode Auto;$autoLine|Add-Member NoteProperty PreferenceOutcome NeedsCheck;$autoLine.SavedConnectionPreference=$null
 Finish $auto $true $autoLine
 Check ((Feedback).Status -ceq 'Succeeded' -and (Feedback).Message.Contains('测试线路')) 'automatic selection without evidence explains the next required test'
 foreach($case in @(@{Status='Failed';Code='ProbeTimeout';Expected='Failed'},@{Status='Blocked';Code='ActiveIdentityInUse';Expected='Inconclusive'},@{Status='Inconclusive';Code='NetworkChanged';Expected='Inconclusive'})){
  CheckLineCardProtocolUI $id -ProfileId Tcp;$test=$script:Jobs[-1]
  Finish $test $true @{LineId=$id;ProfileId='Tcp';Status=$case.Status;Code=$case.Code;Check=@{Status=$case.Status;Code=$case.Code;ForwardingPassed=$false}}
  $f=Feedback Check
  Check ($f.Status -ceq $case.Expected -and $f.CanRetry -and $f.ProfileId -ceq 'Tcp') ('Ok worker with '+$case.Status+' network result never reports test success')
 }
 $f=Feedback Check;RetryLineActionUI $id $f.Id;$test=$script:Jobs[-1]
 Check ($test.RequestData.ProfileId -ceq 'Tcp') 'test retry retains the tested method'
 Finish $test $true @{LineId=$id;ProfileId='Tcp';Status='Passed';Check=@{ForwardingPassed=$false}}
 Check ((Feedback Check).Status -cne 'Succeeded') 'Passed without forwarding evidence never asserts success'
 CheckLineCardProtocolUI $id -ProfileId Tcp;$test=$script:Jobs[-1]
 Finish $test $true @{LineId=$other;ProfileId='Tcp';Status='Passed';Check=@{ForwardingPassed=$true}}
 Check ((Feedback Check).Code -ceq 'LineCheckTargetMismatch' -and (Feedback Check).Status -ceq 'Failed') 'another line result cannot become success for this line'
 CheckLineCardProtocolUI $id -ProfileId Tcp;$test=$script:Jobs[-1]
 Finish $test $true @{LineId=$id;ProfileId='Tcp';Status='Passed';Check=@{ForwardingPassed=$true}}
 Check ((Feedback Check).Status -ceq 'Succeeded') 'confirmed forwarding success replaces previous test failure'
 SaveLineDefaultProfileForLineUI $id Udp -Origin Card;$unknown=$script:Jobs[-1]
 Finish $unknown $false -Code WorkerOutcomeUnknown -Unknown $true
 $f=Feedback;$unknownId=$f.Id;$count=$script:Jobs.Count
 Check ($f.NeedsReview -and -not $f.CanRetry -and $f.RequestId -ceq $unknown.RequestId) 'unknown result exposes only review and binds the real worker request'
 RetryLineActionUI $id $f.Id
 Check ($script:Jobs.Count -eq $count) 'unknown result never authorizes replay'
 ReviewLineActionUI $id $f.Id
 Check ($script:OpenedReceipt -ceq $unknown.RequestId) 'review opens the original matching operation'
 $script:UncertainUiJobs.Clear();ReviewLineActionUI $id $f.Id
 Check ((Feedback).NeedsReview -and (Feedback).CanDiagnose) 'missing memory entry cannot erase uncertainty and offers diagnostics'
 $terminal=@{RequestId=$unknown.RequestId;Action='LinePreference';LineId=$other;Status='Completed'}
 [IO.File]::WriteAllText((Join-Path $script:JobRoot ($unknown.RequestId+'.receipt.json')),($terminal|ConvertTo-Json))
 ReviewLineActionUI $id $f.Id
 Check ((Feedback).NeedsReview) 'a terminal receipt for another line cannot clear the review'
 $terminal.LineId=$id;[IO.File]::WriteAllText((Join-Path $script:JobRoot ($unknown.RequestId+'.receipt.json')),($terminal|ConvertTo-Json))
 ReviewLineActionUI $id $f.Id
 Check (-not (Feedback).NeedsReview -and (Feedback).Status -ceq 'Info' -and $script:Jobs.Count -eq $count) 'matching durable completion refreshes state without replay'
 SaveLineDefaultProfileForLineUI $id Udp -Origin Card;$timeout=$script:Jobs[-1]
 CompleteUiRequestLifecycle $timeout 'OutcomeUnknown' WorkerOutcomeUnknown
 Check ((Feedback).NeedsReview -and -not $script:LinePreferenceRequests.ContainsKey($id)) 'worker silence finalization also exposes a review and clears the spinner'
 $lateLine=$saved.PSObject.Copy();$lateLine.SavedConnectionPreference=@{ProfileId='Udp';Source='UserChoice';Digest=('F'*64)}
 Finish $timeout $true $lateLine
 Check ((Feedback).Status -ceq 'Succeeded') 'late verified result updates the original unknown feedback'
 $views=@(GetLineActionFeedbackViewsUI $id);$json=$views|ConvertTo-Json -Depth 15
 Check (-not $json.Contains('CandidateSHA256') -and -not $json.Contains('RequestId') -and -not $json.Contains($script:Root)) 'browser feedback omits worker envelopes, binding hashes and local paths'
 Check ($views[0].ConnectionMessage.Contains('当前仍连接')) 'feedback describes the actual connected state'
 $script:Overview.Running=$false;$script:Overview.StateKey='Disconnected'
 Check ((GetLineActionConnectionTextUI) -ceq '当前未连接。') 'disconnected feedback never claims a kept connection'
 $script:Overview.ReadState='Unknown'
 Check ((GetLineActionConnectionTextUI).Contains('尚未更新')) 'unknown overview does not reuse an old connected claim'
 CheckLineCardProtocolUI $id -ProfileId Tcp;$guarded=$script:Jobs[-1]
 Finish $guarded $false -Code ProbeTimeout
 $f=Feedback Check;$count=$script:Jobs.Count
 Check ($f.CanRetry -and -not $f.NeedsReview) 'busy and read-only guards exercise a normally retryable feedback'
 $script:ReadOnly=$true;RetryLineActionUI $id $f.Id;$script:ReadOnly=$false;$script:Busy=$true;RetryLineActionUI $id $f.Id;$script:Busy=$false
 Check ($script:Jobs.Count -eq $count) 'read-only and busy guards prevent retry submission'
 Check ($script:Dialogs.Count -eq 0) 'save, reset, test and uncertainty paths never create a failure popup'
 $passed=$true
}catch{$failure=$_.Exception.Message;throw}finally{
 $result=[ordered]@{Passed=$passed;Checks=$script:Checks.Count;Assertions=$script:Checks.ToArray();Failure=$failure;RealProcessesStarted=0;NetworkCalls=0;ProductionWrites=0}
 if($ReportPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($result|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($true))}
 $full=[IO.Path]::GetFullPath($script:Root);$boundary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if($full.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($full) -cmatch '^tc-inline-[a-f0-9]{32}$'){Remove-Item -LiteralPath $full -Recurse -Force}
}
$result|ConvertTo-Json -Depth 10
