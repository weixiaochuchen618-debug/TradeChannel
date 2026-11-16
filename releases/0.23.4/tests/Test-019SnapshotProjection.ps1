#requires -Version 5.1
# 0.19 host projection contract: the read-only fields the web shell now publishes.
# Pure functions are extracted from ui/WebShell.ps1; no window, worker, network or
# production data is touched. Run with Windows PowerShell 5.1.
[CmdletBinding()]
param([string]$PackageRoot='',[string]$ReportDirectory='')
$ErrorActionPreference='Stop'
$env:PSModulePath=Join-Path $PSHOME 'Modules'
if(-not $PackageRoot){$PackageRoot=Split-Path $PSScriptRoot -Parent}
$script:PackageRoot=[IO.Path]::GetFullPath($PackageRoot)
if(-not $ReportDirectory){$ReportDirectory=Join-Path (Split-Path $script:PackageRoot -Parent) 'reports\release-0.19.0\snapshot'}
$reportRoot=[IO.Path]::GetFullPath($ReportDirectory)
$null=[IO.Directory]::CreateDirectory($reportRoot)
$script:Checks=New-Object 'Collections.Generic.List[string]'
$passed=$false;$failure=$null

function Check {param([bool]$Condition,[string]$Message)
 if(-not $Condition){throw $Message}
 $script:Checks.Add($Message)
}
function ImportPresentationFunctions {param([string]$File,[string[]]$Names)
 $path=Join-Path $script:PackageRoot $File;$tokens=$null;$errors=$null
 $ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
 Check ($errors.Count -eq 0) ($File+' parses under PowerShell 5.1')
 foreach($name in $Names){
  $definitions=@($ast.FindAll({param($a)$a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -ceq $name},$false))
  Check ($definitions.Count -eq 1) ('exactly one '+$name+' definition')
  # Install the body (not the whole definition) into the script scope: passing the
  # full "function ... { }" text would only define a nested function and return null.
  $body=$definitions[0].Body.Extent.Text
  Set-Item -Path ('Function:script:'+$name) -Value ([scriptblock]::Create($body.Substring(1,$body.Length-2)))
 }
}

try{
 ImportPresentationFunctions 'ui\WebShell.ps1' @('WebField','ConvertTCWebUtcStamp','GetTCWebOutcomeCopy','GetTCWebLastOutcome','GetTCWebPendingView','GetTCWebExitEvidence','GetTCWebOperationKind','NewTCWebOperation','GetTCWebOperation','GetTCWebRecentConnectionFailure','GetTCWebPairView','GetTCWebQuality30m','GetTCWebPairErrorCopy')

 # --- Timestamp normalisation -------------------------------------------------
 $stamp=ConvertTCWebUtcStamp ([DateTime]::SpecifyKind([DateTime]::UtcNow,[DateTimeKind]::Utc))
 $parseOk=$false
 try{$null=[DateTimeOffset]::Parse([string]$stamp);$parseOk=$true}catch{$parseOk=$false}
 Check $parseOk 'timestamps normalise to a parseable ISO value'
 Check ($stamp -match '(Z|[+-]\d{2}:\d{2})$') 'timestamps keep an explicit UTC offset'
 Check ($null -eq (ConvertTCWebUtcStamp 'not-a-time')) 'unparseable timestamps degrade to null instead of throwing'

 # --- Five terminal outcomes --------------------------------------------------
 $statuses=@('Completed','RolledBack','Aborted','ResolvedStopped','NeedsRecovery')
 $messages=@{}
 foreach($status in $statuses){
  $copy=GetTCWebOutcomeCopy $status
  Check ([bool]$copy.Label -and [bool]$copy.Message -and [bool]$copy.NextAction) ($status+' has a label, a sentence and a next action')
  Check ($copy.Message -notmatch '已恢复') ($status+' does not claim a restore')
  $messages[$status]=$copy.Message
 }
 Check (@($messages.Values|Select-Object -Unique).Count -eq 5) 'the five outcomes have five distinct sentences'
 Check ((GetTCWebOutcomeCopy 'RolledBack').Message -match '已回到切换前') 'only RolledBack describes returning to the previous state'
 Check ((GetTCWebOutcomeCopy 'Completed').NextAction -ceq 'Details') 'Completed offers details'

 # --- Waiting deadline is derived from the single budget ----------------------
 $script:WebPendingBudgetSeconds=300
 $script:WebPendingConnection=@{Id='l1';Name='主线';CreatedAt=[DateTime]::UtcNow.AddSeconds(-10);SessionId='s1'}
 $pending=GetTCWebPendingView
 Check ($pending.Name -ceq '主线' -and $pending.SessionId -ceq 's1') 'pending view carries name and session'
 $due=[DateTimeOffset]::Parse($pending.DeadlineUtc)
 Check ([Math]::Abs(($due-[DateTimeOffset]::UtcNow.AddSeconds(290)).TotalSeconds) -lt 5) 'deadline is CreatedAt plus the budget constant'
 Check ($pending.SecondsRemaining -ge 285 -and $pending.SecondsRemaining -le 300) 'remaining seconds is bounded by the same budget'
 $script:WebPendingConnection=$null
 Check ($null -eq (GetTCWebPendingView)) 'no waiting object yields no pending view'

 # --- Exit evidence degrades honestly ----------------------------------------
 $degraded=GetTCWebExitEvidence ([pscustomobject]@{})
 Check ($degraded.Verified -eq $false -and $degraded.Status -ceq 'Unknown' -and $degraded.Attribution -ceq 'Unknown') 'missing validation renders as unknown, not verified'
 $selfHosted=GetTCWebExitEvidence ([pscustomobject]@{RuntimeValidation=[pscustomobject]@{ServerAttributionVerified=$false;ExitAttribution='SelectedTradeExit';Status='Passed';Code='ForwardingPassed';CheckedAt=[DateTime]::UtcNow}})
 Check ($selfHosted.Verified -eq $false -and $selfHosted.Status -ceq 'Passed') 'self-hosted forwarding stays unverified'
 Check ([bool]$selfHosted.CheckedAtUtc) 'degraded validation objects keep their CheckedAt stamp'
 $authoritative=GetTCWebExitEvidence ([pscustomobject]@{RuntimeValidation=[pscustomobject]@{ServerAttributionVerified=$true;ExitAttribution='ServerVerifiedTlsTrace';Status='Passed';Code='ForwardingPassed';ValidatedAt=[DateTime]::UtcNow}})
 Check ($authoritative.Verified -eq $true -and $authoritative.Attribution -ceq 'ServerVerifiedTlsTrace') 'authoritative proof is the only verified case'

 # --- Per-line last outcome ---------------------------------------------------
 $line=[pscustomobject]@{LineId='l1';Revision=3;Profiles=@([pscustomobject]@{Id='Udp';CandidateSHA256=('A'*64);ManifestSHA256=('B'*64);Revision=2})}
 $script:WebConnectionAttempts=@{}
 # Both stamps derive from the same instant: the contract rejects a window wider
 # than one hour, so two separate UtcNow calls would make the fixture invalid.
 $attemptAt=[DateTimeOffset]::UtcNow.AddMinutes(-1)
 $script:WebConnectionAttempts['l1']=@{LineId='l1';ProfileId='Udp';Status='RolledBack';HasFailure=$true;CandidateSHA256=('A'*64);ManifestSHA256=('B'*64);ProfileRevision=2;LineRevision=3;AtUtc=$attemptAt.ToString('o');ExpiresAtUtc=$attemptAt.AddMinutes(59).ToString('o')}
 $outcome=GetTCWebLastOutcome $line 'Udp'
 Check ($outcome.Status -ceq 'RolledBack' -and $outcome.NextAction -ceq 'Details') 'rolled back attempt publishes its own status'
 $script:WebConnectionAttempts['l1'].Status='NeedsRecovery'
 $outcome=GetTCWebLastOutcome $line 'Udp'
 Check ($outcome.Status -ceq 'NeedsRecovery' -and $outcome.NextAction -ceq 'Diagnostics') 'needs recovery without a pending operation points at diagnostics'
 $script:WebConnectionAttempts['l1'].Status='Completed';$script:WebConnectionAttempts['l1'].HasFailure=$false
 $outcome=GetTCWebLastOutcome $line 'Udp'
 Check ($outcome.Status -ceq 'Completed') 'a completed attempt is published as completed'
 $script:WebConnectionAttempts['l1'].CandidateSHA256=('C'*64)
 Check ($null -eq (GetTCWebLastOutcome $line 'Udp')) 'a changed configuration hides the old outcome'
 $script:WebConnectionAttempts=@{}
 Check ($null -eq (GetTCWebLastOutcome $line 'Udp')) 'no attempt yields no outcome'

 # --- 0.19.1: interrupted transactions keep their outcome card -----------------
 # Crashed transactions never pass through the in-process catch, so the journal
 # has no Failure property. The card must still be published.
 $base=@{LineId='l1';ProfileId='Udp';CandidateSHA256=('A'*64);ManifestSHA256=('B'*64);ProfileRevision=2;LineRevision=3;AtUtc=$attemptAt.ToString('o');ExpiresAtUtc=$attemptAt.AddMinutes(59).ToString('o')}
 foreach($case in @(
  @{Status='ResolvedStopped';HasFailure=$false;HasFailureKnown=$true;Next='ChooseLine'},
  @{Status='NeedsRecovery';HasFailure=$false;HasFailureKnown=$true;Next='Diagnostics'},
  @{Status='Aborted';HasFailure=$false;HasFailureKnown=$true;Next='Connect'}
 )){
  $script:WebConnectionAttempts['l1']=$base.Clone();$script:WebConnectionAttempts['l1'].Status=$case.Status
  $script:WebConnectionAttempts['l1'].HasFailure=$case.HasFailure;$script:WebConnectionAttempts['l1'].HasFailureKnown=$case.HasFailureKnown
  $outcome=GetTCWebLastOutcome $line 'Udp'
  Check ($null -ne $outcome -and $outcome.Status -ceq $case.Status) ($case.Status+' without a Failure property still publishes its card')
  Check ($outcome.NextAction -ceq $case.Next) ($case.Status+' keeps its next action')
 }
 $script:WebConnectionAttempts['l1']=$base.Clone();$script:WebConnectionAttempts['l1'].Status='ResolvedStopped'
 $outcome=GetTCWebLastOutcome $line 'Udp'
 Check ($null -ne $outcome -and $outcome.Status -ceq 'ResolvedStopped') 'missing HasFailure metadata is treated as unknown, not as a mismatch'
 $script:WebConnectionAttempts['l1']=$base.Clone();$script:WebConnectionAttempts['l1'].Status='Completed';$script:WebConnectionAttempts['l1'].HasFailure=$true;$script:WebConnectionAttempts['l1'].HasFailureKnown=$true
 Check ($null -eq (GetTCWebLastOutcome $line 'Udp')) 'a completed attempt with a failure record is still rejected'
 $script:WebConnectionAttempts['l1']=$base.Clone();$script:WebConnectionAttempts['l1'].Status='RolledBack';$script:WebConnectionAttempts['l1'].HasFailure=$false;$script:WebConnectionAttempts['l1'].HasFailureKnown=$true
 Check ($null -eq (GetTCWebLastOutcome $line 'Udp')) 'a rolled back attempt without a failure record is still rejected'
 $script:WebConnectionAttempts=@{}

 # --- 0.19.1: snapshot stamp must not depend on the regional calendar ----------
 $shellText=[IO.File]::ReadAllText((Join-Path $script:PackageRoot 'ui\WebShell.ps1'))
 Check ($shellText -match "ToString\('yyyy-MM-ddTHH:mm:ssZ',\[Globalization\.CultureInfo\]::InvariantCulture\)") 'snapshot stamp pins InvariantCulture in the product source'
 $stamps=@{}
 foreach($culture in @('zh-CN','ar-SA','fa-IR','th-TH')){
  $old=[Threading.Thread]::CurrentThread.CurrentCulture
  try{
   [Threading.Thread]::CurrentThread.CurrentCulture=[Globalization.CultureInfo]::GetCultureInfo($culture)
   $stamps[$culture]=[DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ',[Globalization.CultureInfo]::InvariantCulture)
  }finally{[Threading.Thread]::CurrentThread.CurrentCulture=$old}
 }
 Check (@($stamps.Values|Select-Object -Unique).Count -eq 1) 'the snapshot stamp is identical in every tested regional calendar'
 Check ($stamps['ar-SA'] -match '^\d{4}-\d{2}-\d{2}T') 'the snapshot stamp keeps a four-digit Gregorian year under ar-SA'

 # --- In-flight operation -----------------------------------------------------
 $script:Nodes=@([pscustomobject]@{LineId='l1';id='l1';Name='主线'})
 $script:JobQueue=@();$script:Job=$null
 Check ($null -eq (GetTCWebOperation)) 'idle host publishes no operation'
 $script:Job=@{Action='ConnectionSwitchCommit';LineId='l1';Message='正在切换线路…';Started=(Get-Date).AddSeconds(-12);Silent=$false;Request=@{Action='ConnectionSwitchCommit';LineId='l1'}}
 $operation=GetTCWebOperation
 Check ($operation.Kind -ceq 'Switch' -and $operation.Name -ceq '主线') 'switch job becomes a named switch operation'
 Check ([bool]$operation.StartedAtUtc) 'a running operation carries its start time'
 $script:Job=@{Action='Nodes';LineId='';Message='读取线路';Started=(Get-Date);Silent=$true;Request=@{Action='Nodes'}}
 Check ($null -eq (GetTCWebOperation)) 'silent reads never become an operation'
 $script:Job=$null
 $script:JobQueue=@(@{Action='Session';SessionAction='Disconnect';Silent=$false;Message='正在断开…';LineId='l1';Request=@{Action='Session';SessionAction='Disconnect'}})
 $operation=GetTCWebOperation
 Check ($operation.Kind -ceq 'Disconnect' -and $null -eq $operation.StartedAtUtc) 'a queued disconnect is published without a start time'
 $script:JobQueue=@()
 $script:LineCheckRequests=@{'l1'=$true}
 $operation=GetTCWebOperation
 Check ($operation.Kind -ceq 'Test' -and $operation.LineId -ceq 'l1') 'a single line test is published as a test operation'

 $passed=$true
}catch{
 $failure=[pscustomobject]@{Message=$_.Exception.Message;Position=$_.InvocationInfo.PositionMessage;Stack=$_.ScriptStackTrace}
}finally{
 $result=[ordered]@{Passed=$passed;Checks=$script:Checks.Count;Assertions=@($script:Checks);Failure=$failure;PowerShellVersion=$PSVersionTable.PSVersion.ToString();Scope='Extracted projection functions; no window, worker, network or production data'}
 $json=$result|ConvertTo-Json -Depth 8
 [IO.File]::WriteAllText((Join-Path $reportRoot 'Test-019SnapshotProjection.json'),$json,(New-Object Text.UTF8Encoding($false)))
 Write-Output ($json -replace "`r?`n",' ')
}
