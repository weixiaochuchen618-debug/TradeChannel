#requires -Version 5.1
#requires -PSEdition Desktop
[CmdletBinding()]param([string]$ReportPath,[string]$PackageRoot)
$ErrorActionPreference='Stop';$env:PSModulePath=Join-Path $PSHOME 'Modules'
$script:PackageRoot=if($PackageRoot){[IO.Path]::GetFullPath($PackageRoot)}else{Split-Path $PSScriptRoot -Parent}
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('tc-169-recovery-'+[guid]::NewGuid().ToString('N'))
$script:Root=$fixture;$script:JobRoot=Join-Path $fixture 'Product\jobs'
Import-Module (Join-Path $script:PackageRoot 'DeploymentStore.psm1') -DisableNameChecking
$null=New-TCDDirectory $script:JobRoot
. (Join-Path $script:PackageRoot 'ui\BackgroundJobs.ps1')
. (Join-Path $script:PackageRoot 'ui\ConnectionProfilePages.ps1')
. (Join-Path $script:PackageRoot 'ui\DeploymentPages.ps1')
. (Join-Path $script:PackageRoot 'ui\NavigationContext.ps1')
$script:Smoke=$false;$script:ReadOnly=$false;$script:Role='deployment';$script:Controls=@{}
$script:HostPanel=[pscustomobject]@{IsEnabled=$true};$script:Footer=[pscustomobject]@{Text=''}
$script:Window=[pscustomobject]@{};$script:Window|Add-Member ScriptMethod FindName {param($name)[pscustomobject]@{Visibility='Collapsed'}}
$script:Callbacks=0;$script:UiErrors=0;$checks=New-Object 'Collections.Generic.List[string]'
function Check {param($Condition,[string]$Name)if(-not $Condition){throw $Name};$checks.Add($Name)}
function StartNextUiJob {}
function UpdateChrome {}
function Toast {param($Message)}
function ErrorDialog {param($Message)$script:UiErrors++}
function NewJob {
 $id=[guid]::NewGuid().ToString('N');$uiId=[guid]::NewGuid().ToString('N');$runId=[guid]::NewGuid().ToString()
 $script:Page='setup';$script:DeployUI=@{Run=@{RunId=$runId};AccessAttemptId='fixture-attempt';SessionRef=@{RunId=$runId;InstanceId=[guid]::NewGuid().ToString()}}
 $context=NewDeploymentCallbackContext -Session;$origin=CaptureNavigationContext;$request=@{Action='DeploymentAttach';RunId=$runId;SessionRef=$script:DeployUI.SessionRef}
 $caseJob=@{RequestId=$id;Action='DeploymentAttach';RunId=$runId;UiRequestId=$uiId;RequestData=$request;WorkerProcessId=0;Process=$null;ProcessStartedTicks=0;Started=Get-Date;Policy=(GetUiJobPolicy DeploymentAttach);OriginContext=$origin;CallbackContext=$context;Silent=$true;Request=(Join-Path $script:JobRoot ($id+'.request.json'));Result=(Join-Path $script:JobRoot ($id+'.result.json'));Complete={param($data)$script:Callbacks++;$script:ObservedRun=$data};OutcomeUnknown=$false}
 [IO.File]::WriteAllText($caseJob.Request,'{}');[IO.File]::WriteAllText($caseJob.Result,'{}')
 SaveUiJobReceipt $caseJob 'Dispatched';return $caseJob
}
$locked=$null
try{
 $result=[pscustomobject]@{Ok=$true;OutcomeUnknown=$false;Data=[pscustomobject]@{Stage='MaterializeCandidate';Status='Failed'}}
 $caseJob=NewJob;SaveUiJobReceipt $caseJob 'Completed';$script:Job=$caseJob
 $receiptPath=Join-Path $script:JobRoot ($caseJob.RequestId+'.receipt.json')
 $locked=[IO.File]::Open($receiptPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
 CompleteUiJob $caseJob $result
 Check ($script:Callbacks -eq 1 -and $script:ObservedRun.Status -eq 'Failed') 'A locked Worker terminal receipt still delivers the actual failed deployment state'
 Check ($script:UiReceiptRetries.Count -eq 0 -and $caseJob.ReceiptSaved) 'A confirmed terminal receipt is consumed without redundant replacement'
 CompleteUiJob $caseJob $result;Check ($script:Callbacks -eq 1) 'Duplicate result delivery does not repeat the business callback'
 $locked.Dispose();$locked=$null

 $caseJob=NewJob;$script:Job=$caseJob;$receiptPath=Join-Path $script:JobRoot ($caseJob.RequestId+'.receipt.json')
 $locked=[IO.File]::Open($receiptPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
 CompleteUiJob $caseJob $result
 Check ($script:Callbacks -eq 2 -and $script:UiReceiptRetries.Count -eq 1 -and [IO.File]::Exists($caseJob.Result)) 'A blocked local receipt write preserves the result and updates the page immediately'
 Check ($script:UncertainUiJobs.Count -eq 0) 'Receipt I/O failure does not turn a known business outcome into an unknown remote mutation'
 $locked.Dispose();$locked=$null;$script:UiReceiptRetries[$caseJob.RequestId].NextAt=[DateTimeOffset]::MinValue
 RetryUiJobReceipts
 Check ($script:Callbacks -eq 2 -and $script:UiReceiptRetries.Count -eq 0 -and -not [IO.File]::Exists($caseJob.Result)) 'Deferred persistence finishes cleanup without rerunning the callback'
 Check (([IO.File]::ReadAllText($receiptPath)|ConvertFrom-Json).Status -eq 'Completed') 'Deferred receipt has the correct operation outcome'

 $caseJob=NewJob;$script:Job=$caseJob;$receiptPath=Join-Path $script:JobRoot ($caseJob.RequestId+'.receipt.json')
 $locked=[IO.File]::Open($receiptPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
 CompleteUiJob $caseJob $result;$script:UiReceiptRetries[$caseJob.RequestId].Deadline=[DateTimeOffset]::MinValue;$script:UiReceiptRetries[$caseJob.RequestId].NextAt=[DateTimeOffset]::MinValue
 RetryUiJobReceipts
 Check ($script:Callbacks -eq 3 -and $script:UiReceiptRetries.Count -eq 0 -and [IO.File]::Exists($caseJob.Result)) 'Persistent contention is bounded and retains the obtained result for recovery'
 $locked.Dispose();$locked=$null
 Check (@(Get-ChildItem -LiteralPath $script:JobRoot -Filter '*.partial').Count -eq 0) 'Each failed receipt attempt cleans its own temporary file'

 $caseJob=NewJob;$caseJob.Complete={throw 'SENSITIVE_DIAGNOSTIC_CANARY_password_private_key'};$script:Job=$caseJob
 CompleteUiJob $caseJob $result
 Check ($script:UiErrors -eq 1 -and [IO.File]::Exists($caseJob.Result)) 'A page callback exception is contained and retains its result'
 $diagnostics=@(Get-ChildItem -LiteralPath (Join-Path $fixture 'diagnostics\failures') -File)
 Check ($diagnostics.Count -ge 1) 'Callback failure emits a private structural diagnostic'
 $diagnostic=[IO.File]::ReadAllText($diagnostics[0].FullName)
 Check ($diagnostic -notmatch 'SENSITIVE_DIAGNOSTIC_CANARY|password_private_key' -and $diagnostic -match 'ExceptionChain') 'Exception messages and secret canaries never enter diagnostics'

 Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Threading;
public sealed class TC169Lock : IDisposable {
 private FileStream stream; private Timer timer;
 public TC169Lock(string path, int milliseconds) {
  stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
  if (milliseconds > 0) timer = new Timer(delegate { Release(); }, null, milliseconds, Timeout.Infinite);
 }
 private void Release() { var value = Interlocked.Exchange(ref stream, null); if (value != null) value.Dispose(); }
 public void Dispose() { if (timer != null) timer.Dispose(); Release(); }
}
'@
 $statePath=Join-Path $fixture 'state.json';Write-TCDJson $statePath @{Value=1}
 $locked=New-Object TC169Lock($statePath,100)
 Write-TCDJson $statePath @{Value=2};$locked.Dispose();$locked=$null
 Check ((Read-TCDJson $statePath).Value -eq 2) 'Atomic state publication survives a transient sharing violation'
 $locked=New-Object TC169Lock($statePath,0);$caught=$null;$watch=[Diagnostics.Stopwatch]::StartNew()
 try{Write-TCDJson $statePath @{Value=3}}catch{$caught=$_.Exception.Message}
 $watch.Stop();$locked.Dispose();$locked=$null
 Check ($caught -like '[[]TC:LocalStateBusy[]]*' -and $watch.Elapsed.TotalSeconds -lt 2 -and (Read-TCDJson $statePath).Value -eq 2) 'Permanent state contention stops within a bounded interval and preserves the prior state'
 $node=Import-Module (Join-Path $script:PackageRoot 'NodeStore.psm1') -PassThru -DisableNameChecking
 $locked=New-Object TC169Lock($statePath,100)
 & $node {param($Path)Write-TCAtomicJson $Path @{Value=4}} $statePath
 $locked.Dispose();$locked=$null
 Check ((Read-TCDJson $statePath).Value -eq 4) 'Candidate store atomic publication also survives transient sharing violations'

 Import-Module (Join-Path $script:PackageRoot 'DeploymentFlow.psm1') -DisableNameChecking
 $flow=Get-Module DeploymentFlow
 $run=New-TCDeploymentRun -Root $fixture -Connection @{Host='192.0.2.10';Port=22;User='root';IdentityFile=''}
 $run.Stage='MaterializeCandidate';$run.Status='Idle'
 try{throw (New-Object IO.IOException('SENSITIVE_DIAGNOSTIC_CANARY'))}catch{$failure=$_}
 $failed=& $flow {param($Root,$Run,$Failure)Set-TCDeploymentFailure $Root $Run $Failure} $fixture $run $failure
 Check ($failed.Status -eq 'Failed' -and $failed.LastError.Code -eq 'CandidatePreparationFailed' -and $failed.LastError.DiagnosticId) 'A local candidate failure has a concrete terminal outcome and diagnostic reference'
 $run.DispatchIntent=[pscustomobject]@{Mutating=$true;State='Dispatched'};$run.Status='Idle'
 $unknown=& $flow {param($Root,$Run,$Failure)Set-TCDeploymentFailure $Root $Run $Failure} $fixture $run $failure
 Check ($unknown.Status -eq 'OutcomeUnknown') 'A genuinely unsettled remote operation still requires reconciliation'

 . (Join-Path $script:PackageRoot 'ui\ConnectionProfilePages.ps1')
 . (Join-Path $script:PackageRoot 'ui\DeploymentPages.ps1')
 $script:Captured=New-Object 'Collections.Generic.List[object]';$script:Shown=0
 function StartJob {param($Request,$Complete,$Message,$Transition,[switch]$Silent,$Failed,$OriginContext,$CallbackContext)$script:Captured.Add(@{Request=$Request;Complete=$Complete;Context=$CallbackContext})}
 function ShowProductDeployment {$script:Shown++}
 $run=Get-TCDeploymentRun $fixture $run.RunId;$run.SessionRef=@{RunId=$run.RunId;InstanceId=[guid]::NewGuid().ToString()};$run.Status='Failed'
 ResumeProductDeployment $run.RunId
 $get=$script:Captured[0];& $get.Complete $run $get.Context
 $snapshot=@($script:Captured|Where-Object {$_.Request.Action -eq 'DeploymentSessionSnapshot'})[0]
 $discover=@($script:Captured|Where-Object {$_.Request.Action -eq 'DeploymentDiscover'})[0]
 & $snapshot.Complete @{InstanceId=$run.SessionRef.InstanceId;Poll=@{HasSession=$false}} $snapshot.Context
 Check ($script:Shown -eq 0) 'A fast session callback cannot render an empty resume form before target hydration'
 Import-Module (Join-Path $script:PackageRoot 'ServerRegistry.psm1') -DisableNameChecking
 $server=Get-TCServer $fixture $run.ServerRecordId
 & $discover.Complete @{Servers=@($server)} $discover.Context
 Check ($script:Shown -eq 1 -and $script:DeployUI.FormDraft.DeployConnectionText -eq '192.0.2.10' -and $script:DeployUI.FormDraft.DeployUser -eq 'root' -and $script:DeployUI.FormDraft.DeployPort -eq '22') 'Resume populates the original address, account and port before the first form display'
 Check ($script:DeployUI.Run.RunId -eq $run.RunId -and $script:DeployUI.Reauth) 'Resume preserves the original task and represents expired login explicitly'
 Check ((DeploymentStatusLabel Failed) -eq '失败，已停止') 'A failed task is explicitly labeled stopped'

 $report=[pscustomobject]@{Passed=$true;Checks=$checks.Count;Names=$checks.ToArray();NetworkActivationPerformed=$false;ServerCommandsExecuted=0;AtUtc=[DateTimeOffset]::UtcNow.ToString('o')}
 if($ReportPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($true))}
 $report|ConvertTo-Json -Depth 5
}finally{
 if($locked){$locked.Dispose()}
 $full=[IO.Path]::GetFullPath($fixture);$boundary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if(-not $full.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -cnotmatch '^tc-169-recovery-[a-f0-9]{32}$'){throw 'Unsafe fixture cleanup target'}
 Remove-Item -LiteralPath $full -Recurse -Force
}
