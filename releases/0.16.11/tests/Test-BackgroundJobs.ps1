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
 for($wait=0;$wait -lt 15 -and -not $hung.HasExited;$wait++){Start-Sleep -Milliseconds 100;PollBackgroundJob}
 Check (-not (Get-Process -Id $hungId -ErrorAction SilentlyContinue)) 'only the owned hung read is terminated'
 Drain;Check (($script:received -join ',') -eq 'Nodes,Providers') 'accepted user work runs before queued background read'
 Check ($script:Overview.Running -and $script:Overview.ReadState -eq 'Unknown') 'read failure preserves last connected state as uncertain'
 Launch Overview Corrupt;Start-Sleep -Milliseconds 900;$script:Job.Started=(Get-Date).AddSeconds(-20)
 PollBackgroundJob;Check (-not $script:Job) 'corrupt result while worker lives still obeys read deadline'
 Launch LineProfiles;$late=$script:Job;$script:Generation++
 [IO.File]::WriteAllText($late.Result,(@{Ok=$true;Action=$late.Action;RequestId=$late.RequestId;PageGeneration=$late.OriginContext.Revision;Data=@{Marker='stale'}}|ConvertTo-Json -Depth 5))
 PollBackgroundJob;Check (-not $script:received.Contains('stale')) 'late scoped result cannot rewrite another page'
 Launch FixtureMutation;$mutation=$script:Job;$mutation.Started=(Get-Date).AddSeconds(-601)
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
 [pscustomobject]@{Passed=$true;Checks=$checks;RealOwnedWorkers=$script:children.Count;NetworkChanges=0}|ConvertTo-Json -Compress
}finally{
 foreach($entry in $script:children){try{$p=Get-Process -Id $entry.Id -ErrorAction Stop;if($p.StartTime.ToUniversalTime().Ticks -eq $entry.Ticks){$p.Kill();$null=$p.WaitForExit(3000)};$p.Dispose()}catch{}}
 $full=[IO.Path]::GetFullPath($script:PackageRoot);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
 if($full.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($full) -match '^tc-jobs-[a-f0-9]{32}$'){Remove-Item -LiteralPath $full -Recurse -Force}
}
