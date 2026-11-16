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
function GetUiSettingsReceiptResolution {param($Receipt,$Result,$Process,$Request=$null)
 # 0.17.x/0.18.0 check Startup.Verified before their first settings/task write.
 # Their pre-write refusal was not classified and became OutcomeUnknown.
 # Recover only its bound diagnostic, never an arbitrary settings/network error.
 if($Process -and -not $Process.HasExited){return $null}
 if((UiJobField $Receipt SchemaVersion 0) -ne 1 -or (UiJobField $Receipt Action '') -cne 'SetUserSetting' -or (UiJobField $Receipt Status '') -notin @('Dispatched','OutcomeUnknown')){return $null}
 $id=[string](UiJobField $Receipt RequestId '')
 if($id -cnotmatch '^[a-f0-9]{32}$'){return $null}
 if((UiJobField $Receipt OperationId '') -and (UiJobField $Receipt OperationId '') -cne $id){return $null}
 foreach($field in @('RunId','LineId','TransactionId','DeploymentMutation','DeploymentProbe')){if(UiJobField $Receipt $field){return $null}}
 $scope=UiJobField $Receipt ResourceScope
 if((UiJobField $scope Kind '') -notin @('','Global') -or (UiJobField $scope Host '') -or (UiJobField $scope ServerRecordId '') -or (UiJobField $scope RunId '')){return $null}
 if(-not $Result -or (UiJobField $Result RequestId '') -cne $id -or (UiJobField $Result Action '') -cne 'SetUserSetting' -or (UiJobField $Result Ok) -isnot [bool] -or $Result.Ok -or (UiJobField $Result Code '') -cne 'WorkerStepFailed' -or (UiJobField $Result Phase '') -cne 'Executing' -or (UiJobField $Result Data)){return $null}
 if((UiJobField $Receipt ErrorId '') -cne (UiJobField $Result ErrorId '') -or [string](UiJobField $Result ErrorId '') -cnotmatch '^[a-f0-9]{32}$'){return $null}
 if($Request -and ((UiJobField $Request RequestId '') -cne $id -or (UiJobField $Request Action '') -cne 'SetUserSetting' -or (UiJobField $Request Name '') -cne 'AutoConnectOnLogin' -or (UiJobField $Request Value) -isnot [bool] -or -not $Request.Value)){return $null}
 $workerId=0;$workerTicks=0L
 if(-not [int]::TryParse([string](UiJobField $Receipt ProcessId ''),[ref]$workerId) -or $workerId -le 0 -or -not [long]::TryParse([string](UiJobField $Receipt ProcessStartedTicks ''),[ref]$workerTicks) -or $workerTicks -le 0){return $null}
 $metrics=UiJobField $Result ReadMetrics
 if(-not $metrics -or [string](UiJobField $metrics ProcessId '') -cne [string]$workerId -or [string](UiJobField $metrics ProcessStartedUtcTicks '') -cne [string]$workerTicks){return $null}
 $observed=$null
 try{
  $observed=Get-Process -Id $workerId -ErrorAction Stop
  if($observed.StartTime.ToUniversalTime().Ticks -eq $workerTicks -and -not $observed.HasExited){return $null}
 }catch{
  if($_.FullyQualifiedErrorId -notlike 'NoProcessFoundForGivenId*'){return $null}
 }finally{if($observed){$observed.Dispose()}}
 $diagnosticId=[string](UiJobField $Result DiagnosticId '')
 if($diagnosticId -cnotmatch '^[a-f0-9]{32}$' -or -not $script:Root){return $null}
 try{
  $path=Join-Path $script:Root ('diagnostics\failures\'+$diagnosticId+'.json')
  $item=Get-Item -LiteralPath $path -Force -ErrorAction Stop
  if($item.PSIsContainer -or $item.Length -gt 65536){return $null}
  $cursor=$item.FullName
  while($cursor){if((Get-Item -LiteralPath $cursor -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint){return $null};$cursor=[IO.Path]::GetDirectoryName($cursor)}
  $d=[IO.File]::ReadAllText($path)|ConvertFrom-Json -ErrorAction Stop
  if($d.SchemaVersion -ne 2 -or $d.ErrorId -cne $diagnosticId -or $d.RequestId -cne $id -or $d.Action -cne 'SetUserSetting' -or (UiJobField $d RunId '') -or (UiJobField (UiJobField $d FailureContext) Code '') -or @(UiJobField $d OriginalFailures @()).Count){return $null}
  $chain=@(UiJobField $d ExceptionChain @());$frames=@(UiJobField $d Frames @())
  if($chain.Count -ne 1 -or $chain[0].Type -cne 'System.Management.Automation.RuntimeException' -or [long]$chain[0].HResult -ne -2146233087){return $null}
  $origin=@($frames|Where-Object {$_.File -ceq 'UserSettings.psm1' -and $_.Function -ceq 'Set-TCLoginAutoConnect'})
  if($origin.Count -ne 1 -or [int]$origin[0].Line -ne 66 -or @($frames|Where-Object {$_.File -ceq 'UserSettings.psm1' -and [int]$_.Line -ne 66}).Count -or @($frames|Where-Object {$_.File -ceq 'Worker.ps1' -and [int]$_.Line -in @(192,209)}).Count -ne 1){return $null}
  $started=[DateTimeOffset]::Parse([string]$Receipt.StartedAtUtc);$failed=[DateTimeOffset]::Parse([string]$d.AtUtc);$finished=[DateTimeOffset]::Parse([string]$Result.At)
  if($failed -lt $started -or $finished -lt $failed){return $null}
 }catch{return $null}
 [pscustomobject]@{Kind='LegacyStartupVerificationReadFailed';ReceiptStatus='Failed';OriginalStatus=$Receipt.Status;DiagnosticId=$diagnosticId;VerifiedAtUtc=[DateTimeOffset]::UtcNow.ToString('o');Reason='Matching legacy diagnostic proves Startup.Verified was read before the first startup-task or settings write; the original executor has ended.';SettingsMutation=$false;StartupMutation=$false;RemoteMutation=$false;NetworkMutation=$false}
}
function GetUiCleanupReceiptResolution {param($Receipt,$Process,$Request)
 if($Process -and -not $Process.HasExited){return $null}
 $action=[string](UiJobField $Receipt Action '')
 if((UiJobField $Receipt SchemaVersion 0) -ne 1 -or $action -notin @('RecordDeleteCommit','RecordCleanupRecover') -or (UiJobField $Receipt Status '') -notin @('Dispatched','OutcomeUnknown') -or [string](UiJobField $Receipt RequestId '') -cnotmatch '^[a-f0-9]{32}$'){return $null}
 if(-not $Request -or (UiJobField $Request RequestId '') -cne $Receipt.RequestId -or (UiJobField $Request Action '') -cne $action){return $null}
 # RestoreUiJobReceipts may have no Process when identity lookup failed. Only
 # a positively ended original PID/birth can release an unresolved submission.
 if((GetUiProcessIdentityState (UiJobField $Receipt ProcessId) (UiJobField $Receipt ProcessStartedTicks)) -cne 'Exited'){return $null}
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
# --- trade-app list edits -----------------------------------------------------
# A list edit validates every input before its atomic saves, so an unclassified
# refusal leaves the saved list untouched. Only "neither target written since the
# request began" is accepted: a later write may belong to another operation and
# keeps the receipt unresolved rather than guessing.
function GetUiTradeApplicationReceiptResolution {param($Receipt,$Result,$Process,$Request=$null)
 if($Process -and -not $Process.HasExited){return $null}
 $action=[string](UiJobField $Receipt Action '')
 if((UiJobField $Receipt SchemaVersion 0) -ne 1 -or $action -cne 'TradeApplicationEdit' -or (UiJobField $Receipt Status '') -notin @('Dispatched','OutcomeUnknown')){return $null}
 $id=[string](UiJobField $Receipt RequestId '')
 if($id -cnotmatch '^[a-f0-9]{32}$' -or ((UiJobField $Receipt OperationId '') -and (UiJobField $Receipt OperationId '') -cne $id)){return $null}
 foreach($field in @('RunId','LineId','TransactionId','DeploymentMutation','DeploymentProbe')){if(UiJobField $Receipt $field){return $null}}
 $scope=UiJobField $Receipt ResourceScope
 if((UiJobField $scope Kind '') -notin @('','Global') -or (UiJobField $scope Host '') -or (UiJobField $scope ServerRecordId '') -or (UiJobField $scope RunId '')){return $null}
 if($Request -and ((UiJobField $Request RequestId '') -cne $id -or (UiJobField $Request Action '') -cne $action)){return $null}
 if((GetUiProcessIdentityState (UiJobField $Receipt ProcessId) (UiJobField $Receipt ProcessStartedTicks)) -cne 'Exited'){return $null}
 $started=[DateTimeOffset]::MinValue
 if(-not [DateTimeOffset]::TryParse([string](UiJobField $Receipt StartedAtUtc ''),[ref]$started) -or -not $script:Root){return $null}
 # A program edit rewrites trade-programs.json; a domain edit rewrites Product\index.json.
 foreach($relative in @('trade-programs.json','Product\index.json')){
  $path=Join-Path $script:Root $relative
  try{
   $cursor=$path
   while($cursor){$item=Get-Item -LiteralPath $cursor -Force -ErrorAction SilentlyContinue;if($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){return $null};$cursor=[IO.Path]::GetDirectoryName($cursor)}
   if([IO.File]::Exists($path) -and [DateTimeOffset][IO.File]::GetLastWriteTimeUtc($path) -ge $started){return $null}
  }catch{return $null}
 }
 [pscustomobject]@{Kind='LocalAtomicNotApplied';ReceiptStatus='Failed';OriginalStatus=[string](UiJobField $Receipt Status '');VerifiedAtUtc=[DateTimeOffset]::UtcNow.ToString('o');Reason='TradeApplicationTargetNotWrittenSinceStart';Target='trade-programs.json/index.json';StartedAtUtc=$started.ToString('o');ExecutorExited=$true;OperationReplayed=$false;RemoteMutation=$false;NetworkMutation=$false}
}
# --- 0.18.4: local atomic operations ------------------------------------------------------------
# These actions rewrite ONE local file under a lock, as their last step (the line record, or the
# node index for a rename). They send nothing to a server and change no network setting. When the
# original executor has provably exited, the file itself tells whether the write happened: a record
# not written since the operation began was never changed; one written later is shown as it is now.
# The original receipt, result and diagnostic files are kept; only a Resolution is appended and the
# operation is never replayed.
$script:UiLocalAtomicActions=@('LinePreference','LinePreferenceReset','LinePreferenceRepair','LineProfileCheck','LineNetworkUpdate','LineNetworkRollback','RenameNode')
function GetUiLocalAtomicTarget {param($Receipt)
 if(-not $script:Root){return $null}
 $action=[string](UiJobField $Receipt Action '')
 if($action -ceq 'RenameNode'){return [pscustomobject]@{Name='index.json';Path=(Join-Path $script:Root 'Product\index.json')}}
 $id=[string](UiJobField $Receipt LineId '')
 if($id -cnotmatch '^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$'){return $null}
 [pscustomobject]@{Name='line.json';Path=(Join-Path $script:Root ('Product\lines\'+$id+'\line.json'))}
}
function GetUiAutomaticPreferenceResetResolution {param($Receipt,$Request,$Target,[DateTimeOffset]$Started)
 if(-not $Request -or [string](UiJobField $Request Action '') -cne 'LinePreferenceReset' -or [string](UiJobField $Request Id '') -cne [string](UiJobField $Receipt LineId '')){return $null}
 $expectedRevision=0L;$expectedDigest=[string](UiJobField $Request ExpectedDigest '')
 if(-not [long]::TryParse([string](UiJobField $Request ExpectedRevision ''),[ref]$expectedRevision) -or $expectedRevision -lt 0 -or $expectedDigest -cnotmatch '^[A-Fa-f0-9]{64}$'){return $null}
 try{
  $cursor=$Target.Path
  while($cursor){$item=Get-Item -LiteralPath $cursor -Force -ErrorAction SilentlyContinue;if($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){return $null};$cursor=[IO.Path]::GetDirectoryName($cursor)}
  $file=Get-Item -LiteralPath $Target.Path -Force -ErrorAction Stop
  if($file.PSIsContainer -or $file.Length -gt 1048576){return $null}
  $line=[IO.File]::ReadAllText($Target.Path)|ConvertFrom-Json -ErrorAction Stop
 }catch{return $null}
 if([long](UiJobField $line Revision -1) -lt 0 -or [string](UiJobField $line LineId '') -cne [string](UiJobField $Receipt LineId '')){return $null}
 $transition=UiJobField $line AutomaticPreferenceTransition
 if([string](UiJobField $transition RequestId '') -ceq [string](UiJobField $Receipt RequestId '')){
  $fields=@('SchemaVersion','Kind','RequestId','LineId','FromRevision','ToRevision','FromDigest','AtUtc','Outcome','SelectedProfileId','ToDigest','PreferenceMode','NextAction','RecommendationDigest','Digest')
  if($transition -isnot [pscustomobject] -or @($transition.PSObject.Properties).Count -ne $fields.Count -or @($transition.PSObject.Properties|Where-Object {$_.Name -cnotin $fields}).Count){return $null}
  $canonical=[ordered]@{};foreach($name in $fields[0..($fields.Count-2)]){if(-not $transition.PSObject.Properties[$name]){return $null};$canonical[$name]=$transition.$name}
  $bytes=$null;$sha=$null
  try{$bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $canonical -Depth 40 -Compress));$sha=[Security.Cryptography.SHA256]::Create();$digest=([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','')}catch{return $null}finally{if($sha){$sha.Dispose()};if($bytes){[Array]::Clear($bytes,0,$bytes.Length)}}
  $selected=[string](UiJobField $transition SelectedProfileId '');$toDigest=[string](UiJobField $transition ToDigest '');$recommendationDigest=[string](UiJobField $transition RecommendationDigest '')
  $outcome=[string](UiJobField $transition Outcome '');$next=[string](UiJobField $transition NextAction '')
  $at=[DateTimeOffset]::MinValue
  if((UiJobField $transition SchemaVersion 0) -ne 1 -or [string](UiJobField $transition Kind '') -cne 'ManualPreferenceCleared' -or [string](UiJobField $transition LineId '') -cne [string](UiJobField $Receipt LineId '') -or [long](UiJobField $transition FromRevision -1) -ne $expectedRevision -or [long](UiJobField $transition ToRevision -1) -ne ($expectedRevision+1) -or [string](UiJobField $transition FromDigest '') -cne $expectedDigest -or [string](UiJobField $transition PreferenceMode '') -cne 'Auto' -or [string](UiJobField $transition Digest '') -cne $digest -or -not [DateTimeOffset]::TryParse([string](UiJobField $transition AtUtc ''),[ref]$at)){return $null}
  if($outcome -ceq 'AutomaticRecommendation'){$valid=($selected -in @('Udp','Tcp') -and $toDigest -cmatch '^[A-Fa-f0-9]{64}$' -and $recommendationDigest -cmatch '^[A-Fa-f0-9]{64}$' -and $next -ceq 'PreviewConnection')}
  elseif($outcome -ceq 'SinglePreparedProfile'){$valid=($selected -in @('Udp','Tcp') -and $toDigest -cmatch '^[A-Fa-f0-9]{64}$' -and -not $recommendationDigest -and $next -ceq 'PreviewConnection')}
  elseif($outcome -ceq 'NeedsCheck'){$valid=(-not $selected -and -not $toDigest -and -not $recommendationDigest -and $next -ceq 'CheckLineProfiles')}
  else{$valid=$false}
  if(-not $valid -or $at -lt $Started -or [string](UiJobField $line PreferenceUpdatedAt '') -cne $at.ToString('o') -or [long](UiJobField $line Revision -1) -lt ($expectedRevision+1)){return $null}
  if($selected){$saved=UiJobField $line SavedConnectionPreference;if(-not $saved -or [string](UiJobField $saved ProfileId '') -cne $selected -or [string](UiJobField $saved Digest '') -cne $toDigest -or [string](UiJobField $saved Source '') -ceq 'UserChoice' -or [string](UiJobField $line PreferredProfileId '') -cne $selected){return $null}}
  elseif((UiJobField $line SavedConnectionPreference) -or [string](UiJobField $line PreferredProfileId '') -or [string](UiJobField $line PreferenceSource '') -cne 'None'){return $null}
  return [pscustomobject]@{Kind='LocalAtomicObserved';ReceiptStatus='Completed';OriginalStatus=[string](UiJobField $Receipt Status '');VerifiedAtUtc=[DateTimeOffset]::UtcNow.ToString('o');Reason='MatchingAutomaticPreferenceTransition';Target=$Target.Name;StartedAtUtc=$Started.ToString('o');ExecutorExited=$true;OperationReplayed=$false;RemoteMutation=$false;NetworkMutation=$false}
 }
 if([long](UiJobField $line Revision -1) -eq $expectedRevision -and [string](UiJobField (UiJobField $line SavedConnectionPreference) Digest '') -ceq $expectedDigest){
  return [pscustomobject]@{Kind='LocalAtomicNotApplied';ReceiptStatus='Failed';OriginalStatus=[string](UiJobField $Receipt Status '');VerifiedAtUtc=[DateTimeOffset]::UtcNow.ToString('o');Reason='PreferenceResetCompareAndSwapUnchanged';Target=$Target.Name;StartedAtUtc=$Started.ToString('o');ExecutorExited=$true;OperationReplayed=$false;RemoteMutation=$false;NetworkMutation=$false}
 }
 return $null
}
function GetUiLocalAtomicReceiptResolution {param($Receipt,$Process,$Request=$null)
 if($Process -and -not $Process.HasExited){return $null}
 $action=[string](UiJobField $Receipt Action '')
 if((UiJobField $Receipt SchemaVersion 0) -ne 1 -or $action -cnotin $script:UiLocalAtomicActions -or (UiJobField $Receipt Status '') -notin @('Dispatched','OutcomeUnknown')){return $null}
 $id=[string](UiJobField $Receipt RequestId '')
 if($id -cnotmatch '^[a-f0-9]{32}$' -or ((UiJobField $Receipt OperationId '') -and (UiJobField $Receipt OperationId '') -cne $id)){return $null}
 foreach($field in @('RunId','TransactionId','DeploymentMutation','DeploymentProbe')){if(UiJobField $Receipt $field){return $null}}
 $scope=UiJobField $Receipt ResourceScope
 if((UiJobField $scope Kind '') -notin @('','Global','Line') -or (UiJobField $scope Host '') -or (UiJobField $scope ServerRecordId '') -or (UiJobField $scope RunId '')){return $null}
 if($Request -and ((UiJobField $Request RequestId '') -cne $id -or (UiJobField $Request Action '') -cne $action)){return $null}
 # Only a positively ended original executor (process id AND start time) can release the record.
 if((GetUiProcessIdentityState (UiJobField $Receipt ProcessId) (UiJobField $Receipt ProcessStartedTicks)) -cne 'Exited'){return $null}
 $started=[DateTimeOffset]::MinValue
 if(-not [DateTimeOffset]::TryParse([string](UiJobField $Receipt StartedAtUtc ''),[ref]$started)){return $null}
 $target=GetUiLocalAtomicTarget $Receipt
 if(-not $target){return $null}
 $lastWrite=$null;$reason=''
 try{
  $cursor=$target.Path
  while($cursor){
   $item=Get-Item -LiteralPath $cursor -Force -ErrorAction SilentlyContinue
   if($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){return $null}
   $cursor=[IO.Path]::GetDirectoryName($cursor)
  }
  if([IO.File]::Exists($target.Path)){$lastWrite=[IO.File]::GetLastWriteTimeUtc($target.Path)}
 }catch{return $null}
 if($action -ceq 'LinePreferenceReset'){return GetUiAutomaticPreferenceResetResolution $Receipt $Request $target $started}
 $kind='LocalAtomicObserved';$status='Completed'
 if(-not $lastWrite){$reason='TargetMissing'}
 elseif([DateTimeOffset]$lastWrite -lt $started){$kind='LocalAtomicNotApplied';$status='Failed';$reason='TargetNotWrittenSinceStart'}
 elseif($action -ceq 'LinePreference'){
  # Someone else wrote the record after the start. The saved-default fields still say whether
  # THIS request changed it: an automatic default last updated before the start was not replaced.
  try{
   $line=[IO.File]::ReadAllText($target.Path)|ConvertFrom-Json -ErrorAction Stop
   $updated=[DateTimeOffset]::MinValue
   if([string](UiJobField $line PreferenceSource '') -cne 'UserChoice' -and [DateTimeOffset]::TryParse([string](UiJobField $line PreferenceUpdatedAt ''),[ref]$updated) -and $updated -lt $started){$kind='LocalAtomicNotApplied';$status='Failed';$reason='PreferenceNotUpdatedSinceStart'}
   else{$reason='TargetWrittenAfterStart'}
  }catch{$reason='TargetWrittenAfterStart'}
 }else{$reason='TargetWrittenAfterStart'}
 [pscustomobject]@{Kind=$kind;ReceiptStatus=$status;OriginalStatus=[string](UiJobField $Receipt Status '');VerifiedAtUtc=[DateTimeOffset]::UtcNow.ToString('o');Reason=$reason;Target=$target.Name;TargetLastWriteUtc=$(if($lastWrite){([DateTimeOffset]$lastWrite).ToString('o')}else{$null});StartedAtUtc=$started.ToString('o');ExecutorExited=$true;OperationReplayed=$false;RemoteMutation=$false;NetworkMutation=$false}
}
function ResolveUiLocalAtomicEntries {param($Scope)
 # Resolve every in-memory unresolved local operation that would block $Scope. True when any was.
 $resolvedAny=$false
 foreach($entry in @($script:UncertainUiJobs.ToArray())){
  if($Scope -and -not (TestUiJobScopesConflict $Scope (UiJobField $entry ResourceScope))){continue}
  $id=[string](UiJobField $entry RequestId '')
  if($id -cnotmatch '^[a-f0-9]{32}$' -or [string](UiJobField $entry Action '') -cnotin $script:UiLocalAtomicActions){continue}
  $process=UiJobField $entry Process
  if($process -and -not $process.HasExited){continue}
  $path=Join-Path $script:JobRoot ($id+'.receipt.json')
  try{
   if(-not [IO.File]::Exists($path)){continue}
   $receipt=[IO.File]::ReadAllText($path)|ConvertFrom-Json
   $resolution=GetUiLocalAtomicReceiptResolution $receipt $null $null
   if($resolution -and -not $script:ReadOnly){SaveUiLegacyReceiptResolution $path $receipt $resolution;RemoveUiResolvedReceiptEntry $id;$resolvedAny=$true}
  }catch{}
 }
 $resolvedAny
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
# One central label table: every write-type action has a plain name; nothing else shows an internal id.
$script:UiOperationLabels=@{
 LinePreference='保存默认连接方式';LinePreferenceReset='恢复自动选择';LinePreferenceRepair='修复默认连接方式';LineProfileCheck='测试线路';LineNetworkUpdate='更新本机网络';LineNetworkRollback='回退本机网络';LineRegister='登记线路连接方式'
 RenameNode='重命名线路';DeleteNode='删除线路';RecordDeleteCommit='删除线路';RecordCleanupRecover='恢复本机清理';RecordRestore='恢复记录';HistoryClearCommit='清理操作记录';HistoryRestore='恢复操作记录'
 DraftDiscardCommit='放弃添加';DraftRestore='恢复添加'
 DeploymentCreate='创建部署';DeploymentAttach='继续部署';DeploymentAccessState='保存部署登录状态';DeploymentProceed='部署新线路';DeploymentPoll='读取部署进度';DeploymentPause='暂停部署';DeploymentCancelProbe='停止线路检查';DeploymentClose='关闭部署会话'
 ServerIdentityAssessment='检查服务器身份';ServerIdentityTransition='确认服务器身份变化';ServerReinstallConfirm='确认服务器重装';ServerImportLegacy='导入旧服务器记录'
 PairRequestCreate='加入线路';PairComplete='加入线路';PairOnlineFinish='加入线路'
 CandidateProbe='检查线路';SavePreferences='保存连接偏好';UpgradeActive='更新连接策略'
 Session='连接或切换线路';ConnectionSwitchCommit='连接或切换线路';AutoConnectCommit='连接上次线路';ConnectionTransactionReconcile='检查连接任务'
 SetUserSetting='保存启动与连接设置';SetStartup='保存登录启动设置';DesktopShortcut='创建桌面快捷方式'
 ProviderRegister='接入代理软件';ProviderPrepare='接入代理软件';ProviderRestore='恢复代理软件设置';ProviderUpdate='更新代理软件';ProviderRemove='移除代理软件';ProviderConnect='接入代理软件';ProviderApply='接入代理软件'
 TradeDomainEdit='更新交易网站名单';TradeApplicationEdit='更新交易软件名单';TradeApplicationApply='更新交易软件名单'
 ProxyRecoveryCommit='恢复代理设置';ConfigurationRollbackApply='回退线路配置';RemoveProtection='解除交易保护';RepairState='修复本机状态';InstallWireGuard='安装 WireGuard'
 ImportNode='导入线路';ActivateNode='启用线路';Adopt='接管本机通道';SetTransportMode='切换传输方式';ExportSettings='导出设置';ImportSettings='导入设置'
}
function GetUiOperationLabel {param([string]$Action)
 if($Action -and $script:UiOperationLabels.ContainsKey($Action)){return [string]$script:UiOperationLabels[$Action]}
 '一项后台操作'
}
function GetUiReceiptTargetName {param($Entry)
 $pending=UiJobField (UiJobField $Entry CallbackContext) Pending
 if($pending -and [string](UiJobField $pending Name '')){return [string]$pending.Name}
 $id=[string](UiJobField $Entry LineId '')
 if(-not $id){$scope=UiJobField $Entry ResourceScope;$ids=@(UiJobField $scope LineIds @());if($ids.Count){$id=[string]$ids[0]}}
 if($id -and (Get-Variable Nodes -Scope Script -ErrorAction SilentlyContinue)){
  foreach($node in @($script:Nodes)){
   $canonical=[string](UiJobField $node LineId (UiJobField $node id ''))
   if($canonical -ceq $id -or @(UiJobField $node AliasIds @()) -ccontains $id){return [string](UiJobField $node Name '')}
  }
 }
 ''
}
function GetUiReceiptKind {param($Entry)
 $action=[string](UiJobField $Entry Action '')
 if($action -in $script:UiConnectionActions){return 'Connection'}
 if($action -in @('RecordDeleteCommit','RecordCleanupRecover')){return 'Cleanup'}
 if(UiJobField $Entry RunId ''){return 'Deployment'}
 if($action -in $script:UiLocalAtomicActions -or $action -ceq 'TradeApplicationEdit'){return 'Local'}
 'Other'
}
function GetUiPendingOperationViews {
 if(-not (Get-Variable UncertainUiJobs -Scope Script -ErrorAction SilentlyContinue)){return}
 $seen=@{}
 foreach($entry in @($script:UncertainUiJobs.ToArray())){
  $id=[string](UiJobField $entry RequestId '')
  if($id -cnotmatch '^[a-f0-9]{32}$' -or $seen.ContainsKey($id)){continue};$seen[$id]=$true
  $name=GetUiReceiptTargetName $entry;$label=GetUiOperationLabel ([string](UiJobField $entry Action ''))
  [pscustomobject]@{Id=$id;Label=$label;Target=$name;Kind=(GetUiReceiptKind $entry);Message=('上次'+$label+$(if($name){'「'+$name+'」'}else{''})+'的结果待确认。')}
 }
}
function OpenUiReceiptDialog {param($Entry,$Request=$null)
 $action=[string](UiJobField $Entry Action '');$label=GetUiOperationLabel $action;$name=GetUiReceiptTargetName $Entry
 $subject=$label+$(if($name){'（'+$name+'）'}else{''})
 $kind=GetUiReceiptKind $Entry
 $status=switch($kind){
  'Connection'{'实际通道进程和清理记录需要先检查，检查本身不会连接或换线。'}
  'Cleanup'{'本机清理的结果需要先检查，不会重复删除。'}
  'Deployment'{'这是一次部署，需要先打开原部署检查服务器上的实际结果。'}
  'Local'{'这是一次本机设置保存，系统会自动确认保存结果。'}
  default{'系统会检查它的实际结果，不会重复提交。'}
 }
 $connection=([string](UiJobField $Request Action '') -in $script:UiConnectionActions)
 $hint=if($connection){'本次连接尚未开始。检查完成后，请再点一次连接。'}elseif($Request){'本次操作尚未提交。检查完成后可再试一次。'}elseif($kind -in @('Local','Cleanup') -and (Get-Variable Overview -Scope Script -ErrorAction SilentlyContinue) -and (UiJobField $script:Overview Running $false)){'当前线路仍在使用；这里检查的是上次操作的结果。'}else{'检查不会重新提交原操作。'}
 $scope=UiJobField $Entry ResourceScope
 $details=('操作：'+$action+"`n请求："+[string](UiJobField $Entry RequestId '')+"`n状态：待检查`n范围：" + [string](UiJobField $scope Kind 'Global'))
 $title=$(if($Request){'本次尚未提交：'}else{''})+$label+'结果待确认'
 OpenDialog $title ('上次的「'+$subject+'」还需要确认结果。'+[Environment]::NewLine+$status) $hint '检查原操作' {param($context) InvokeUiReceiptReconcile $context.Entry} '稍后' 'Primary' @{Entry=$Entry;RequestId=[string](UiJobField $Entry RequestId '');Details=$details} -SafeDefault
}
function InvokeUiReceiptReconcile {param($Entry)
 $kind=GetUiReceiptKind $Entry;$id=[string](UiJobField $Entry RequestId '')
 if($kind -eq 'Connection'){
  StartJob @{Action='ConnectionTransactionReconcile'} {param($data)
   RefreshUiJobReceipts
   if($data.Resolved){if(Get-Command RefreshOverview -ErrorAction SilentlyContinue){RefreshOverview -Silent};Toast '已检查原操作，可以重新连接线路'}
   elseif([int](UiJobField $data Reviewed 0) -eq 0){if(Get-Command RefreshOverview -ErrorAction SilentlyContinue){RefreshOverview -Silent};Toast '没有待处理的故障记录'}
   else{OpenDialog '仍需处理' '尚不能确认通道已完全停止，或原配置资料已经变化。' '请先查看运行状况里的实际状态。' '知道了' $null ''}
  } '检查原连接与清理结果…'
  return
 }
 if($kind -eq 'Cleanup'){
  $pending=UiJobField $script:DeployUI RecordDeletePending
  if($pending -and [string](UiJobField $pending CommitRequestId '') -ceq $id){CheckOriginalLocalCleanupResultUI $pending;return}
  StartJob @{Action='RecordCleanupRecover'} {param($data)CompleteLocalCleanupRecoveryUI $data;RefreshUiJobReceipts} '恢复并检查本机清理…';return
 }
 if($kind -eq 'Deployment'){ResumeProductDeployment ([string](UiJobField $Entry RunId ''));return}
 RefreshUiJobReceipts
 $left=@($script:UncertainUiJobs.ToArray()|Where-Object {[string](UiJobField $_ RequestId '') -ceq $id}).Count
 if($left){OpenDialog '仍需处理' '这项操作的执行进程可能还在运行，或结果还不能自动确认。' '请稍后再试，或查看运行状况。' '知道了' $null ''}
 else{Toast '已检查，可以继续操作'}
}
function ShowUiReceiptDetail {param($Entry)
 OpenUiReceiptDialog $Entry
}
function ShowUiMutationBlocked {param($Request,$Scope)
 $null=ResolveUiLocalAtomicEntries $Scope
 $entries=@($script:UncertainUiJobs.ToArray()|Where-Object {TestUiJobScopesConflict $Scope (UiJobField $_ ResourceScope)})
 if($script:Job -and $script:Job.OutcomeUnknown -and (TestUiJobScopesConflict $Scope (UiJobField $script:Job ResourceScope))){$entries+=,$script:Job}
 $script:Footer.Text='尚未提交：请先检查关联的旧操作。'
 if($entries.Count){OpenUiReceiptDialog $entries[0] $Request}
 else{Toast '旧操作已自动检查，请再点一次'}
}
