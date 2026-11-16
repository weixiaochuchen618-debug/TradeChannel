#requires -Version 5.1
$ErrorActionPreference='Stop'
$script:PackageRoot=Join-Path ([IO.Path]::GetTempPath()) ('tc-jobs-'+[guid]::NewGuid().ToString('N'))
$script:JobRoot=Join-Path $script:PackageRoot 'jobs';$null=[IO.Directory]::CreateDirectory($script:JobRoot)
$actual=Split-Path $PSScriptRoot -Parent
$worker=@'
param($RequestPath,$ResultPath)
$ErrorActionPreference='Stop'
$r=Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8|ConvertFrom-Json
[IO.File]::WriteAllText(($RequestPath+'.accepted'),'accepted')
if($r.Mode -eq 'Corrupt'){[IO.File]::WriteAllText($ResultPath,'{broken')}
if($r.Mode -in @('Hang','Corrupt')){Start-Sleep -Seconds 60;exit}
$result=@{Ok=$true;Action=$r.Action;RequestId=$r.RequestId;PageGeneration=$r.PageGeneration;Data=@{Marker=$r.Action}}
[IO.File]::WriteAllText($ResultPath,($result|ConvertTo-Json -Depth 8))
'@
[IO.File]::WriteAllText((Join-Path $script:PackageRoot 'Worker.ps1'),$worker,[Text.UTF8Encoding]::new($true))
. (Join-Path $actual 'ui\BackgroundJobs.ps1')
$script:UiReadWorkerEnabled=$false
$script:Smoke=$false;$script:ReadOnly=$false;$script:Job=$null;$script:Pending=$null;$script:Generation=1
$script:Footer=[pscustomobject]@{Text=''};$script:HostPanel=[pscustomobject]@{IsEnabled=$true}
$script:Overlay=[pscustomobject]@{Visibility='Collapsed'};$script:Window=[pscustomobject]@{}
$script:Window|Add-Member ScriptMethod FindName {param($name)$script:Overlay}
$script:Overview=[pscustomobject]@{Running=$true};$script:messages=New-Object 'Collections.Generic.List[string]';$script:received=New-Object 'Collections.Generic.List[string]'
$script:children=New-Object 'Collections.Generic.List[object]';$checks=0
function CaptureNavigationContext {[pscustomobject]@{Revision=$script:Generation}}
function TestNavigationContext {param($context)$context.Revision -eq $script:Generation}
function Toast {param($message)$script:messages.Add($message)}
function ErrorDialog {param($message)$script:messages.Add($message)}
function OpenDialog {param($title,$body,$hint,$label,$callback,$cancel,$style,$context)$script:messages.Add($title+' '+$body)}
function UpdateChrome {}
function Render {}
function Check {param($ok,$name)if(-not $ok){throw $name};$script:checks++}
function Launch {param($action,$mode='Hang')
 StartJob @{Action=$action;Mode=$mode} {param($d)$script:received.Add($d.Marker)} -Silent;$script:children.Add(@{Id=$script:Job.Process.Id;Ticks=$script:Job.ProcessStartedTicks})
 $clock=[Diagnostics.Stopwatch]::StartNew()
 while(-not [IO.File]::Exists($script:Job.Request+'.accepted') -and $clock.Elapsed.TotalSeconds -lt 5 -and -not $script:Job.Process.HasExited){Start-Sleep -Milliseconds 20}
 if(-not [IO.File]::Exists($script:Job.Request+'.accepted')){throw 'Fixture worker did not acknowledge the original request'}
}
function Drain {for($i=0;$i -lt 160 -and ($script:Job -or $script:JobQueue.Count);$i++){PollBackgroundJob;Start-Sleep -Milliseconds 25};Check (-not $script:Job -and -not $script:JobQueue.Count) 'queued reads reach terminal result'}
try{
 Launch Overview
 StartJob @{Action='Nodes'} {param($d)$script:received.Add($d.Marker)}
 StartJob @{Action='Providers'} {param($d)$script:received.Add($d.Marker)} -Silent
 StartJob @{Action='Providers'} {throw 'duplicate silent callback must not run'} -Silent
 Check ($script:JobQueue.Count -eq 2) 'user requests queue and silent reads coalesce'
 $script:Job.Started=(Get-Date).AddSeconds(-20);$hung=$script:Job.Process;$hungId=$hung.Id
 PollBackgroundJob
 Check ($script:Job -and -not $hung.HasExited) 'UTC jump does not expire an active monotonic read budget'
 $script:Job.Clock=[pscustomobject]@{Elapsed=[pscustomobject]@{TotalSeconds=20}}
 PollBackgroundJob
 for($wait=0;$wait -lt 15 -and -not $hung.HasExited;$wait++){Start-Sleep -Milliseconds 100;PollBackgroundJob}
 Check (-not (Get-Process -Id $hungId -ErrorAction SilentlyContinue)) 'only the owned hung read is terminated'
 Drain;Check (($script:received -join ',') -eq 'Nodes,Providers') 'accepted user work runs before queued background read'
 Check ($script:Overview.Running -and $script:Overview.ReadState -eq 'Unknown') 'read failure preserves last connected state as uncertain'
 Launch Overview Corrupt;Start-Sleep -Milliseconds 900;$script:Job.Clock=[pscustomobject]@{Elapsed=[pscustomobject]@{TotalSeconds=20}}
 PollBackgroundJob;Check (-not $script:Job) 'corrupt result while worker lives still obeys read deadline'
 Launch LineProfiles;$late=$script:Job;$script:Generation++
 [IO.File]::WriteAllText($late.Result,(@{Ok=$true;Action=$late.Action;RequestId=$late.RequestId;PageGeneration=$late.OriginContext.Revision;Data=@{Marker='stale'}}|ConvertTo-Json -Depth 5))
 PollBackgroundJob;Check (-not $script:received.Contains('stale')) 'late scoped result cannot rewrite another page'
 Launch FixtureMutation;$mutation=$script:Job;$mutation.Clock=[pscustomobject]@{Elapsed=[pscustomobject]@{TotalSeconds=601}}
 PollBackgroundJob;Check (-not $script:Job -and $script:UncertainUiJobs.Count -eq 1 -and -not $mutation.Process.HasExited) 'mutation timeout retains live original operation and frees read slot'
 StartJob @{Action='FixtureMutation'} {throw 'duplicate mutation ran'}
 Check (-not $script:Job -and $script:messages[-1] -like '*尚未提交*') 'unknown mutation cannot be replayed and exposes its blocking operation'
 Launch Nodes Complete;Drain;Check ($script:received.Contains('Nodes')) 'read status remains available during unknown mutation'
 [IO.File]::WriteAllText($mutation.Result,(@{Ok=$true;Action=$mutation.Action;RequestId=$mutation.RequestId;PageGeneration=$mutation.OriginContext.Revision;Data=@{Marker='mutation'}}|ConvertTo-Json -Depth 5))
 PollBackgroundJob;Check ($script:UncertainUiJobs.Count -eq 0 -and $script:received.Contains('mutation')) 'late mutation result completes original request without replay'
 $receipt=Get-Content -LiteralPath (Join-Path $script:JobRoot ($mutation.RequestId+'.receipt.json')) -Raw|ConvertFrom-Json
 Check ($receipt.Status -eq 'Completed' -and $receipt.OperationId -ceq $mutation.RequestId) 'public operation receipt retains correlation and terminal status'
 Launch FixtureMutation;$unknown=$script:Job
 [IO.File]::WriteAllText($unknown.Result,(@{Ok=$false;OutcomeUnknown=$true;Message='Await original result';Action=$unknown.Action;RequestId=$unknown.RequestId;PageGeneration=$unknown.OriginContext.Revision}|ConvertTo-Json -Depth 5))
 PollBackgroundJob
 Check ($script:UncertainUiJobs.Count -eq 1 -and -not $script:Job) 'explicit unknown result keeps mutation barrier while releasing UI slot'
 StartJob @{Action='FixtureMutation'} {throw 'unknown result was replayed'}
 Check (-not $script:Job) 'receiving unknown result never authorizes replay'
 StartJob @{Action='Session';SessionAction='Disconnect';Mode='Complete'} {param($d)$script:received.Add('safe-disconnect')}
 $script:children.Add(@{Id=$script:Job.Process.Id;Ticks=$script:Job.ProcessStartedTicks});Drain
 Check ($script:received.Contains('safe-disconnect') -and $script:UncertainUiJobs.Count -eq 1) 'unknown result still permits owned safe disconnect without erasing original uncertainty'
 Check (-not (TestUiRecoveryRequest @{Action='RemoveProtection'}) -and -not (TestUiRecoveryRequest @{Action='RepairState';ClearProviders=$true}) -and -not (TestUiRecoveryRequest @{Action='Session';SessionAction='Connect'})) 'recovery bypass never permits protection removal or a new connection'
 $script:UncertainUiJobs.Clear();$script:UiJobRecoveryLoaded=$false;RestoreUiJobReceipts
 Check ($script:UncertainUiJobs.Count -eq 1 -and $script:UncertainUiJobs[0].RequestId -ceq $unknown.RequestId -and $script:UncertainUiJobs[0].ResultConsumed) ('restart with an existing unknown result retains original operation; count='+$script:UncertainUiJobs.Count+'; footer='+$script:Footer.Text+'; receipts='+((Get-ChildItem -LiteralPath $script:JobRoot -Filter '*.receipt.json'|ForEach-Object {[IO.File]::ReadAllText($_.FullName)|ConvertFrom-Json}|ForEach-Object {$_.Action+':'+$_.Status}) -join ','))
 PollBackgroundJob
 Check ($script:UncertainUiJobs.Count -eq 1) 'same unknown result is not repeatedly delivered or cleared'
 $script:UncertainUiJobs.Clear()
 $unknown.TransactionId='fixture-transaction';CompleteUiJob $unknown ([pscustomobject]@{Ok=$true;OutcomeUnknown=$true;Data=@{TransactionId='fixture-transaction';Status='NeedsRecovery'}})
 Launch ConnectionTransactionReconcile;$reconcile=$script:Job
 CompleteUiJob $reconcile ([pscustomobject]@{Ok=$true;Data=[pscustomobject]@{Results=@([pscustomobject]@{TransactionId='different-transaction';Status='ResolvedStopped'})}})
 Check ($script:UncertainUiJobs.Count -eq 1) 'another transaction resolution cannot clear the pending request'
 Launch ConnectionTransactionReconcile;$reconcile=$script:Job
 CompleteUiJob $reconcile ([pscustomobject]@{Ok=$true;Data=[pscustomobject]@{Results=@([pscustomobject]@{TransactionId='fixture-transaction';Status='ResolvedStopped'})}})
 Check ($script:UncertainUiJobs.Count -eq 0) 'matching durable terminal transaction releases the original barrier'
 $unknown.Action='ConnectionSwitchCommit';$unknown.TransactionId='';CompleteUiJob $unknown ([pscustomobject]@{Ok=$false;OutcomeUnknown=$true;Message='Worker exited before returning transaction ID'})
 Launch ConnectionTransactionReconcile;$reconcile=$script:Job
 CompleteUiJob $reconcile ([pscustomobject]@{Ok=$true;Data=[pscustomobject]@{Results=@([pscustomobject]@{TransactionId='journal-transaction';RequestId=$unknown.RequestId;Status='Completed'})}})
 Check ($script:UncertainUiJobs.Count -eq 0) 'durable request ID association recovers a missing result transaction ID'
 $unknown.Action='Session';$unknown.TransactionId='';$unknown.OutcomeUnknown=$true
 $script:UncertainUiJobs.Add($unknown)
 [IO.File]::WriteAllText($unknown.Result,'{"OriginalFailurePreserved":true}')
 $originalResult=[IO.File]::ReadAllText($unknown.Result)
 $row=[pscustomobject]@{Action='Session';RequestId=('f'*32);Status='ResolvedStopped';ReconciliationKind='LocalSession';Resolution=[pscustomobject]@{Kind='StandaloneStopOverflowReconciled'}}
 Launch ConnectionTransactionReconcile;$reconcile=$script:Job
 CompleteUiJob $reconcile ([pscustomobject]@{Ok=$true;Data=[pscustomobject]@{Results=@($row)}})
 Check ($script:UncertainUiJobs.Count -eq 1) 'local session resolution never clears a different request'
 $row.RequestId=$unknown.RequestId;$row.Resolution.Kind='Unverified'
 Launch ConnectionTransactionReconcile;$reconcile=$script:Job
 CompleteUiJob $reconcile ([pscustomobject]@{Ok=$true;Data=[pscustomobject]@{Results=@($row)}})
 Check ($script:UncertainUiJobs.Count -eq 1) 'local session resolution requires verified recovery kind'
 $row.Resolution.Kind='StandaloneStopOverflowReconciled'
 Launch ConnectionTransactionReconcile;$reconcile=$script:Job
 CompleteUiJob $reconcile ([pscustomobject]@{Ok=$true;Data=[pscustomobject]@{Results=@($row)}})
 Check ($script:UncertainUiJobs.Count -eq 0 -and [IO.File]::ReadAllText($unknown.Result) -ceq $originalResult) 'verified stopped session unblocks only its request and preserves original failure'
 # --- 0.18.4: an unresolved operation blocks only what it can actually conflict with -----------------
 $script:UncertainUiJobs.Clear();$script:Overview=[pscustomobject]@{Running=$true}
 $lineA='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';$lineB='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';$lineC='cccccccc-cccc-4ccc-8ccc-cccccccccccc'
 $scopeB=GetUiJobResourceScope @{Action='LinePreference';Id=$lineB;ProfileId='Udp'}
 Check ($scopeB.Kind -ceq 'Line' -and $scopeB.LineIds -ccontains $lineB) 'a saved default is scoped to its own line'
 foreach($a in @('LinePreferenceRepair','LineProfileCheck','LineNetworkUpdate','LineNetworkRollback','RenameNode')){Check ((GetUiJobResourceScope @{Action=$a;Id=$lineB}).Kind -ceq 'Line') ('local one-line action is line scoped: '+$a)}
 Check ((GetUiJobResourceScope @{Action='LinePreference';Id='not-a-guid'}).Kind -ceq 'Global' -and (GetUiJobResourceScope @{Action='LinePreference'}).Kind -ceq 'Global') 'an unreadable line id falls back to the conservative global scope'
 Check ((GetUiJobResourceScope @{Action='SetUserSetting';Name='AutoConnectOnLogin';Value=$true}).Kind -ceq 'Global' -and (GetUiJobResourceScope @{Action='RepairState'}).Kind -ceq 'Global') 'other mutations stay global'
 $connectionA=GetUiJobResourceScope @{Action='ConnectionSwitchCommit';LineId=$lineA;ProfileId='Udp'}
 Check ($connectionA.Kind -ceq 'Connection' -and $connectionA.TargetLineIds -ccontains $lineA) 'a connection carries its target line'
 $script:Overview=[pscustomobject]@{Running=$true;ActiveLineId=$lineC}
 $connectionActive=GetUiJobResourceScope @{Action='Session';SessionAction='Connect';NodeId=$lineA}
 Check ($connectionActive.ActiveLineIds -ccontains $lineC -and $connectionActive.TargetLineIds -ccontains $lineA) 'a connection also carries the currently active line'
 $script:Overview=[pscustomobject]@{Running=$true}
 $autoConnect=GetUiJobResourceScope @{Action='AutoConnectCommit'}
 $scopeA=GetUiJobResourceScope @{Action='LinePreference';Id=$lineA}
 Check (-not (TestUiJobScopesConflict $scopeA $scopeB) -and (TestUiJobScopesConflict $scopeB $scopeB)) 'two line scopes conflict only on the same line'
 Check (-not (TestUiJobScopesConflict $scopeB $connectionA) -and (TestUiJobScopesConflict $scopeA $connectionA)) 'a line and a connection conflict only when the line is the connection target'
 Check ((TestUiJobScopesConflict $scopeB $connectionActive) -eq $false -and (TestUiJobScopesConflict (GetUiJobResourceScope @{Action='LinePreference';Id=$lineC}) $connectionActive)) 'the active line conflicts with a switch away from it'
 Check ((TestUiJobScopesConflict $scopeB $autoConnect) -and (TestUiJobScopesConflict $connectionA $autoConnect)) 'an unknown connection target stays conservative; two connections never overlap'
 Check ((TestUiJobScopesConflict @{Kind='Global'} $scopeB) -and (TestUiJobScopesConflict $scopeB @{Kind='Global'}) -and (TestUiJobScopesConflict $scopeB @{Kind='DeploymentServer';Host='192.0.2.9'})) 'global and deployment scopes keep conflicting with a line'
 Check ((TestUiJobScopesConflict ([pscustomobject]@{Kind='Line';LineIds=@($lineB)}) ([pscustomobject]@{Kind='Connection';TargetLineIds=@($lineA);ActiveLineIds=@()})) -eq $false) 'stored scopes (JSON objects) are understood too'
 function LaunchLine {param([string]$action,[string]$id,[string]$mode='Hang')
  StartJob @{Action=$action;Id=$id;ProfileId='Udp';ExpectedRevision=1;Mode=$mode} {param($d)$script:received.Add($d.Marker)} -Silent
  $script:children.Add(@{Id=$script:Job.Process.Id;Ticks=$script:Job.ProcessStartedTicks})
  $clock=[Diagnostics.Stopwatch]::StartNew()
  while(-not [IO.File]::Exists($script:Job.Request+'.accepted') -and $clock.Elapsed.TotalSeconds -lt 5 -and -not $script:Job.Process.HasExited){Start-Sleep -Milliseconds 20}
 }
 LaunchLine LinePreference $lineB;$pendingB=$script:Job;$pendingB.Clock=[pscustomobject]@{Elapsed=[pscustomobject]@{TotalSeconds=601}};PollBackgroundJob
 Check (-not $script:Job -and $script:UncertainUiJobs.Count -eq 1 -and $script:UncertainUiJobs[0].ResourceScope.Kind -ceq 'Line' -and $script:UncertainUiJobs[0].ResourceScope.LineIds -ccontains $lineB) 'an unresolved saved default is held with its own line scope'
 $receiptB=Get-Content -LiteralPath (Join-Path $script:JobRoot ($pendingB.RequestId+'.receipt.json')) -Raw|ConvertFrom-Json
 Check ($receiptB.Status -ceq 'OutcomeUnknown' -and $receiptB.ResourceScope.Kind -ceq 'Line' -and $receiptB.LineId -ceq $lineB) 'the durable receipt keeps the line scope and the line id'
 $messagesBefore=$script:messages.Count
 StartJob @{Action='ConnectionSwitchCommit';LineId=$lineA;ProfileId='Udp';PreviewToken='fixture';Mode='Complete'} {param($d)$script:received.Add('connect-A')}
 $script:children.Add(@{Id=$script:Job.Process.Id;Ticks=$script:Job.ProcessStartedTicks});Drain
 Check ($script:received.Contains('connect-A') -and $script:messages.Count -eq $messagesBefore -and $script:UncertainUiJobs.Count -eq 1) 'line B unresolved does not stop connecting line A and does not clear line B'
 StartJob @{Action='LinePreference';Id=$lineA;ProfileId='Tcp';ExpectedRevision=1;Mode='Complete'} {param($d)$script:received.Add('prefer-A')}
 $script:children.Add(@{Id=$script:Job.Process.Id;Ticks=$script:Job.ProcessStartedTicks});Drain
 Check ($script:received.Contains('prefer-A')) 'line B unresolved does not stop a saved default for line A'
 $count=$script:messages.Count
 StartJob @{Action='LinePreference';Id=$lineB;ProfileId='Tcp';ExpectedRevision=1;Mode='Complete'} {throw 'same-line operation was replayed'}
 Check (-not $script:Job -and $script:messages.Count -gt $count -and $script:messages[-1] -like '*尚未提交*') 'the same line stays blocked and says so'
 $count=$script:messages.Count
 StartJob @{Action='ConnectionSwitchCommit';LineId=$lineB;ProfileId='Udp';PreviewToken='fixture';Mode='Complete'} {throw 'connection to the unresolved line was started'}
 Check (-not $script:Job -and $script:messages.Count -gt $count) 'connecting the line that has an unresolved operation stays blocked'
 $script:Overview=[pscustomobject]@{Running=$true;ActiveLineId=$lineB}
 $count=$script:messages.Count
 StartJob @{Action='Session';SessionAction='Connect';NodeId=$lineA;Mode='Complete'} {throw 'switch away from the unresolved active line was started'}
 Check (-not $script:Job -and $script:messages.Count -gt $count) 'switching away from the active line that has an unresolved operation stays blocked'
 $script:Overview=[pscustomobject]@{Running=$true};$script:UncertainUiJobs.Clear()
 # A recovery result still belongs to its original cleanup after navigation.
 # Only its exact pending context may receive that late result.
 $script:RecoveryPending=@{Submitted=$true;Phase='OutcomeUnknown';PreviewToken='original-cleanup'}
 function TestLocalCleanupRequestUI {param($Context)
  [object]::ReferenceEquals($Context.Pending,$script:RecoveryPending) -and [object]::ReferenceEquals($Context,$script:RecoveryPending.RequestContext)
 }
 $recoveryUiId=[guid]::NewGuid().ToString('N')
 $recoveryContext=@{Type='LocalCleanup';Action='RecordCleanupRecover';UiRequestId=$recoveryUiId;Pending=$script:RecoveryPending;PreviewToken='original-cleanup'}
 $script:RecoveryPending.RequestContext=$recoveryContext
 $recoveryOrigin=CaptureNavigationContext;$script:Generation++
 $recoveryId=[guid]::NewGuid().ToString('N')
 $recoveryJob=@{Action='RecordCleanupRecover';RequestData=@{Action='RecordCleanupRecover'};CallbackContext=$recoveryContext;OriginContext=$recoveryOrigin;UiRequestId=$recoveryUiId;RequestId=$recoveryId;Policy=(GetUiJobPolicy 'RecordCleanupRecover');Started=(Get-Date);Request=(Join-Path $script:JobRoot ($recoveryId+'.request.json'));Result=(Join-Path $script:JobRoot ($recoveryId+'.result.json'));Silent=$true;OutcomeUnknown=$false;Complete={param($data,$context)$script:received.Add('recovery-after-navigation')};Lifecycle=@{UiRequestId=$recoveryUiId;RequestId=$recoveryId;FinalizedDelivered=$false}}
 Check ((TestUiJobCallbackContext $recoveryJob.RequestData $recoveryContext $recoveryOrigin $recoveryUiId) -and -not (TestNavigationContext $recoveryOrigin)) 'cleanup recovery retains its exact target after leaving the original page'
 CompleteUiJob $recoveryJob ([pscustomobject]@{Ok=$true;Data=[pscustomobject]@{RecoveredCount=1;CompletedResults=@()}})
 Check ($script:received.Contains('recovery-after-navigation') -and -not $recoveryJob.CallbackFailed) 'late cleanup recovery delivers its next-step callback after navigation'
 $recoveryContext.Pending=@{Submitted=$true;Phase='OutcomeUnknown';PreviewToken='original-cleanup'}
 Check (-not (TestUiJobCallbackContext $recoveryJob.RequestData $recoveryContext $recoveryOrigin $recoveryUiId)) 'a superseded cleanup target cannot consume the recovery result'
 [pscustomobject]@{Passed=$true;Checks=$checks;RealOwnedWorkers=$script:children.Count;NetworkChanges=0}|ConvertTo-Json -Compress
}finally{
 foreach($entry in $script:children){try{$p=Get-Process -Id $entry.Id -ErrorAction Stop;if($p.StartTime.ToUniversalTime().Ticks -eq $entry.Ticks){$p.Kill();$null=$p.WaitForExit(3000)};$p.Dispose()}catch{}}
 $full=[IO.Path]::GetFullPath($script:PackageRoot);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
 if($full.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($full) -match '^tc-jobs-[a-f0-9]{32}$'){Remove-Item -LiteralPath $full -Recurse -Force}
}
