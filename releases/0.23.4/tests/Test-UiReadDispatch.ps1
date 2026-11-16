#requires -Version 5.1
[CmdletBinding()]param([string]$PackageRoot,[string]$ReportPath)
$ErrorActionPreference='Stop';$env:PSModulePath=Join-Path $PSHOME 'Modules'
if(-not $PackageRoot){$PackageRoot=Split-Path $PSScriptRoot -Parent}
$script:PackageRoot=[IO.Path]::GetFullPath($PackageRoot)
$script:Root=Join-Path ([IO.Path]::GetTempPath()) ('TradeChannel-worker-fixture-'+[guid]::NewGuid().ToString('N'))
$script:JobRoot=Join-Path $script:Root 'Product\jobs';$null=[IO.Directory]::CreateDirectory($script:JobRoot)
Import-Module (Join-Path $PackageRoot 'DeploymentStore.psm1') -DisableNameChecking
Import-Module (Join-Path $PackageRoot 'NodeStore.psm1') -DisableNameChecking
$null=Initialize-TCStore -Root (Join-Path $script:Root 'Product')
. (Join-Path $PackageRoot 'ui\BackgroundJobs.ps1')
if(-not (Get-Variable UiDispatchFailures -Scope Script -ErrorAction SilentlyContinue)){$script:UiDispatchFailures=New-Object 'Collections.Generic.List[object]'}
$script:Smoke=$false;$script:ReadOnly=$false;$script:UiJobRecoveryLoaded=$true
$script:Job=$null;$script:Pending=$null;$script:DeployUI=@{CleanupEpoch=0};$script:Page='home'
$script:Overview=[pscustomobject]@{StateKey='Connected';Running=$true;ActiveLineId='11111111-1111-1111-1111-111111111111'}
$script:HostPanel=[pscustomobject]@{IsEnabled=$true};$script:Footer=[pscustomobject]@{Text=''}
$script:Overlay=[pscustomobject]@{Visibility='Collapsed'};$script:Window=[pscustomobject]@{}
$script:Window|Add-Member ScriptMethod FindName {param($name)$script:Overlay}
$script:Children=New-Object 'Collections.Generic.List[object]';$script:Launches=New-Object 'Collections.Generic.List[object]'
$script:Dialogs=New-Object 'Collections.Generic.List[object]';$script:Finals=New-Object 'Collections.Generic.List[object]'
$script:Received=New-Object 'Collections.Generic.List[object]';$checks=New-Object 'Collections.Generic.List[string]'
$script:FailLaunch=$false;$script:Generation=1
function Check {param($Condition,[string]$Name)if(-not $Condition){throw $Name};$checks.Add($Name)}
function CaptureNavigationContext {[pscustomobject]@{Revision=$script:Generation}}
function TestNavigationContext {param($Context)$Context.Revision -eq $script:Generation}
function UpdateChrome {}
function UpdateReadPresentation {}
function Toast {param($Text)}
function Render {}
function ErrorDialog {param($Text)$script:Dialogs.Add(@{Title='GenericError';Body=$Text})}
function OpenDialog {param($Title,$Body,$Note,$Confirm,$Action,$Cancel,$Context,[switch]$SafeDefault)
 $script:Dialogs.Add(@{Title=$Title;Body=$Body;Note=$Note;Confirm=$Confirm;Action=$Action;Context=$Context})
}
function Start-Process {param($FilePath,$ArgumentList,[switch]$PassThru,$WindowStyle)
 if($WindowStyle -cne 'Hidden' -or [IO.Path]::GetFileName($FilePath) -ine 'powershell.exe'){throw 'Unexpected Worker executable'}
 $isReader=([string]$ArgumentList[5] -like '*Read-TradeChannel.ps1*')
 if($ArgumentList -notcontains '-File' -or (-not $isReader -and [string]$ArgumentList[5] -notlike '*Worker.ps1*')){throw 'Unexpected Worker script'}
 $script:Launches.Add(@{Reader=$isReader;InjectedFailure=[bool]$script:FailLaunch})
 if($script:FailLaunch){throw [ComponentModel.Win32Exception]::new(5,'DO_NOT_RETAIN_UI_DISPATCH_SECRET')}
 if(-not $isReader){
  $path=([string]$ArgumentList[([array]::IndexOf($ArgumentList,'-RequestPath')+1)]).Trim('"')
  if(-not [IO.Path]::GetFullPath($path).StartsWith(($script:JobRoot+'\'),[StringComparison]::OrdinalIgnoreCase)){throw 'Worker left isolated fixture'}
 }
 $isolatedArgs=@($ArgumentList)+@('-IsolatedTest','-TestRoot',('"'+$script:Root+'"'))
 $process=Microsoft.PowerShell.Management\Start-Process -FilePath $FilePath -ArgumentList $isolatedArgs -PassThru -WindowStyle Hidden
 $script:Children.Add(@{Id=$process.Id;Ticks=$process.StartTime.ToUniversalTime().Ticks})
 return $process
}
function ReadNow {param([string]$Action='Overview',[switch]$Visible,[scriptblock]$Failed=$null)
 StartJob -Request @{Action=$Action} -Complete {param($Data)$script:Received.Add($Data)} -Silent:(-not $Visible) -Failed $Failed -Finalized {param($Final)$script:Finals.Add($Final)} -PassThru
}
function Drain {
 $clock=[Diagnostics.Stopwatch]::StartNew()
 while(($script:Job -or $script:JobQueue.Count) -and $clock.Elapsed.TotalSeconds -lt 20){PollBackgroundJob;Start-Sleep -Milliseconds 20}
 Check (-not $script:Job -and -not $script:JobQueue.Count) 'The real dispatched read reaches a terminal result within its budget'
}
$passed=$false;$failure='';$stack='';$lock=$null;$retained=$null
try{
 $first=ReadNow;Drain
 Check ($first.Accepted -and $script:Received.Count -eq 1 -and $script:Received[0].StateKey -ceq 'Unconfigured') 'Actual UI dispatcher reads real isolated Overview through the real reusable Worker'
 $originalReaderId=$script:UiReadWorker.Id
 for($i=0;$i -lt 20;$i++){$null=ReadNow;Drain}
 Check ($script:Launches.Count -eq 1 -and $script:UiReadWorker.Id -ceq $originalReaderId -and $script:Received.Count -eq 21) 'Twenty repeated reads reuse one real process without stale state or extra launches'
 $lock=[IO.File]::Open($script:UiReadWorker.Inbox,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
 try{$allowed=ReadNow;Drain}finally{$lock.Dispose();$lock=$null}
 Check ($allowed.Accepted -and $script:Launches.Count -eq 1) 'An open snapshot with delete sharing does not block atomic mailbox publication'
 # Deterministically hold the mailbox without delete sharing. The old UI
 # catches this as a generic startup failure and loses this silent read.
 $before=$script:Received.Count
 $lock=[IO.File]::Open($script:UiReadWorker.Inbox,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
 try{$fallback=ReadNow}finally{$lock.Dispose();$lock=$null}
 Drain
 Check ($fallback.Accepted -and $script:Received.Count -eq ($before+1) -and $script:Launches.Count -eq 2 -and -not $script:Launches[1].Reader) 'A mailbox sharing failure recovers once through a real independent read Worker'
 Check ($script:Dialogs.Count -eq 0 -and $script:UncertainUiJobs.Count -eq 0) 'Automatic read recovery opens no dialog and creates no mutation recovery barrier'
 $sharing=$script:UiDispatchFailures|Where-Object Stage -ceq 'PublishReadMailbox'|Select-Object -Last 1
 Check ($sharing.Action -ceq 'Overview' -and $sharing.DiagnosticSaved) 'The recovered sharing failure retains its exact action and publication stage'
 $diagnostic=Read-TCDJson (Join-Path $script:Root ('diagnostics\failures\'+$sharing.ErrorId+'.json'))
 Check ($diagnostic.Action -ceq 'Overview' -and $diagnostic.RequestId -ceq $sharing.RequestId -and $diagnostic.Stage -ceq 'PublishReadMailbox') 'Persisted structural diagnostic binds the original request, action and failed phase'
 $null=ReadNow;Drain
 $script:UiReadWorker.Wake.Dispose();$before=$script:Received.Count;$launchesBefore=$script:Launches.Count
 $afterPublication=ReadNow
 Check ($afterPublication.Accepted -and $script:Job -and [IO.File]::Exists($script:Job.Request)) 'A failed wake after publication retains the original request and waiting job'
 Drain
 Check ($script:Received.Count -eq ($before+1) -and $script:Launches.Count -eq $launchesBefore -and $script:Dialogs.Count -eq 0) 'The same reader completes by polling after wake failure, without replay or a modal'
 Check (@($script:UiDispatchFailures|Where-Object {$_.Stage -ceq 'WakeReadWorker' -and $_.DiagnosticSaved}).Count -eq 1) 'Wake failure remains diagnosable even though the read completes'
 StopUiReadWorker
 $script:FailLaunch=$true;$finalsBefore=$script:Finals.Count
 $failed=ReadNow Nodes
 Check (-not $failed.Accepted -and $failed.Code -ceq 'WorkerStartFailed' -and -not $script:Job -and $script:Dialogs.Count -eq 0) 'A failed automatic list refresh ends cleanly without a modal or false success'
 Check ($script:Finals.Count -eq ($finalsBefore+1) -and $script:LastJobReceipt.Status -ceq 'NotDispatched' -and $script:LastJobReceipt.Action -ceq 'Nodes') 'Failed launch finalizes once with its actual operation and undispatched status'
 # Nodes now dispatches through the shared reader (WorkerContracts ReuseReadProcess),
 # so a refused launch is recorded at the reader start or its independent fallback
 # stage instead of the plain per-job StartWorker stage. The diagnostic must still
 # exist and still name Nodes; only the stage label moved.
 $launchFailure=$script:UiDispatchFailures|Where-Object {$_.Stage -in @('StartWorker','StartReadWorker','StartFallbackRead') -and $_.Action -ceq 'Nodes'}|Select-Object -Last 1
 $rawDiagnostic=[IO.File]::ReadAllText((Join-Path $script:Root ('diagnostics\failures\'+$launchFailure.ErrorId+'.json')))
 Check (-not $rawDiagnostic.Contains('DO_NOT_RETAIN_UI_DISPATCH_SECRET') -and -not (($script:UiDispatchFailures.ToArray()|ConvertTo-Json -Depth 10).Contains('DO_NOT_RETAIN_UI_DISPATCH_SECRET'))) 'Persistent and in-memory diagnostics omit exception text and secret-like content'
 $failedOverview=ReadNow
 Check (-not $failedOverview.Accepted -and $script:Overview.Running -and $script:Overview.ReadState -ceq 'Unknown' -and $script:Dialogs.Count -eq 0) 'Failed Overview launch preserves last session and marks its reading stale without a modal'
 $visible=ReadNow Nodes -Visible
 $dialog=$script:Dialogs[-1]
 Check (-not $visible.Accepted -and $dialog.Title -match '读取线路列表' -and $dialog.Confirm -ceq '重新读取' -and $dialog.Note -match '错误编号') 'Explicit read failure names the failed operation and offers a real retry with a diagnostic ID'
 $script:FailLaunch=$false;$before=$script:Received.Count
 & $dialog.Action $dialog.Context
 Drain
 Check ($script:Received.Count -eq ($before+1) -and $script:LastJobReceipt.Status -ceq 'Completed') 'The visible retry action dispatches a real isolated read and obtains its result'
 $script:FailLaunch=$true;$launchesBefore=$script:Launches.Count
 $mutation=StartJob @{Action='LinePreference';Id='11111111-1111-1111-1111-111111111111';ProfileId='Udp';ExpectedRevision=1} {} -PassThru
 Check (-not $mutation.Accepted -and $script:Launches.Count -eq ($launchesBefore+1) -and -not $script:Job) 'Failed mutation startup is not automatically replayed by read fallback'
 Check ($script:Dialogs[-1].Title -match '保存连接方式' -and $script:Dialogs[-1].Confirm -ceq '知道了') 'A mutation failure does not offer a generic automatic replay button'
 $passed=$true
}catch{$failure=$_.Exception.Message;$stack=$_.ScriptStackTrace}
finally{
 if($lock){$lock.Dispose()}
 StopUiReadWorker
 foreach($child in $script:Children){
  $owned=Get-Process -Id $child.Id -ErrorAction SilentlyContinue
  if($owned){try{if($owned.StartTime.ToUniversalTime().Ticks -eq $child.Ticks -and -not $owned.HasExited){if(-not $owned.WaitForExit(1500)){$owned.Kill();$null=$owned.WaitForExit(3000)}}}finally{$owned.Dispose()}}
 }
 $report=[pscustomobject]@{Passed=$passed;Assertions=$checks.Count;Checks=$checks.ToArray();Failure=$failure;Stack=$stack;RealReadProcesses=$script:Children.Count;ActualDispatcher=$true;ActualReadWorker=$true;ActualReadModules=$true;InjectedFailureBoundary='Only OS launch refusal and mailbox/wake handles';ProductionAccess=$false;NetworkChanges=0;DispatchFailures=$script:UiDispatchFailures.ToArray();Finalized=$script:Finals.ToArray();PowerShellVersion=$PSVersionTable.PSVersion.ToString()}
 if($ReportPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 14),[Text.UTF8Encoding]::new($true))}
 $report|Select-Object Passed,Assertions,Failure,Stack,RealReadProcesses,ActualDispatcher,ActualReadWorker,ActualReadModules,ProductionAccess,NetworkChanges|ConvertTo-Json -Depth 5
 $full=[IO.Path]::GetFullPath($script:Root);$prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if(-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -cnotmatch '^TradeChannel-worker-fixture-[a-f0-9]{32}$'){throw 'Fixture cleanup boundary rejected'}
 Remove-Item -LiteralPath $full -Recurse -Force
}
if(-not $passed){throw $failure}
