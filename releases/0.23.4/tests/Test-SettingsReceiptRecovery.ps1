#requires -Version 5.1
[CmdletBinding()]param([string]$SourceDirectory='',[string]$EvidenceDirectory,[string]$ReportPath)
$ErrorActionPreference='Stop';$env:PSModulePath=Join-Path $PSHOME 'Modules'
if(-not $SourceDirectory){$SourceDirectory=Split-Path $PSScriptRoot -Parent}
$owned=Join-Path ([IO.Path]::GetTempPath()) ('tc-settings-receipt-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($owned)
$script:PackageRoot=$SourceDirectory;$script:ReadOnly=$false;$script:Smoke=$false;$script:Job=$null;$script:Pending=''
$script:Footer=[pscustomobject]@{Text=''};$script:HostPanel=[pscustomobject]@{IsEnabled=$true}
. (Join-Path $SourceDirectory 'ui\BackgroundJobs.ps1')
$script:UiReadWorkerEnabled=$false;$checks=New-Object 'Collections.Generic.List[string]';$script:Admitted=0;$script:LastDialog=$null
function Check {param($Value,[string]$Text)if(-not $Value){throw ('Settings receipt regression: '+$Text)};$checks.Add($Text)}
function Clone {param($Value)ConvertFrom-Json -InputObject ($Value|ConvertTo-Json -Depth 16)}
function WriteJson {param([string]$Path,$Value)$null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path));[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 16),(New-Object Text.UTF8Encoding($true)))}
function CaptureNavigationContext {[pscustomobject]@{Revision=1}}
function TestNavigationContext {param($Context)$Context.Revision -eq 1}
function Render {}
function ErrorDialog {param($Message)$script:LastDialog=@{Body=$Message}}
function OpenDialog {param($Title,$Body,$Note,$Confirm,$Callback,$Cancel,$Style,$Context)$script:LastDialog=@{Title=$Title;Body=$Body;Note=$Note;Context=$Context}}
function Start-Process {
 param($FilePath,$ArgumentList,[switch]$PassThru,$WindowStyle)
 $script:Admitted++;[pscustomobject]@{Id=$PID;StartTime=[DateTime]::Now;HasExited=$true}
}
$process=Get-Process -Id $PID
$oldTicks=[string]($process.StartTime.ToUniversalTime().Ticks-1);$liveTicks=[string]$process.StartTime.ToUniversalTime().Ticks;$process.Dispose()
$id=[guid]::NewGuid().ToString('N');$errorId=[guid]::NewGuid().ToString('N');$diagnosticId=[guid]::NewGuid().ToString('N');$at=[DateTimeOffset]::UtcNow.AddMinutes(-5)
$seedReceipt=[pscustomobject]@{SchemaVersion=1;RequestId=$id;OperationId=$id;Action='SetUserSetting';RunId='';LineId='';TransactionId=$null;DeploymentMutation=$null;DeploymentProbe=$null;ResourceScope=@{Kind='Global';Host='';ServerRecordId='';RunId=''};Status='OutcomeUnknown';Code='WorkerStepFailed';Phase='Executing';ErrorId=$errorId;StartedAtUtc=$at.ToString('o');ProcessId=$PID;ProcessStartedTicks=$oldTicks}
$seedResult=[pscustomobject]@{Ok=$false;RequestId=$id;Action='SetUserSetting';Code='WorkerStepFailed';Phase='Executing';OutcomeUnknown=$true;ErrorId=$errorId;DiagnosticId=$diagnosticId;At=$at.AddSeconds(2).ToString('o');ReadMetrics=@{ProcessId=$PID;ProcessStartedUtcTicks=$oldTicks}}
$seedDiagnostic=[pscustomobject]@{SchemaVersion=2;ErrorId=$diagnosticId;RequestId=$id;Action='SetUserSetting';RunId='';AtUtc=$at.AddSeconds(1).ToString('o');FailureContext=@{Code=''};ExceptionChain=@(@{Type='System.Management.Automation.RuntimeException';HResult=-2146233087});OriginalFailures=@();Frames=@(@{Function='Invocation';File='UserSettings.psm1';Line=66},@{Function='Set-TCLoginAutoConnect';File='UserSettings.psm1';Line=66},@{Function='<ScriptBlock>';File='Worker.ps1';Line=192})}
function NewCase {param([string]$Name)
 $script:Root=Join-Path $owned $Name;$script:JobRoot=Join-Path $script:Root 'Product\jobs';$null=[IO.Directory]::CreateDirectory($script:JobRoot)
 $script:UncertainUiJobs.Clear();$script:UiJobRecoveryLoaded=$false;$script:Job=$null;$script:LastDialog=$null;$script:ReadOnly=$false
 [pscustomobject]@{Receipt=(Clone $seedReceipt);Result=(Clone $seedResult);Diagnostic=(Clone $seedDiagnostic)}
}
function Publish {param($Case)
 WriteJson (Join-Path $script:JobRoot ($Case.Receipt.RequestId+'.receipt.json')) $Case.Receipt
 WriteJson (Join-Path $script:JobRoot ($Case.Receipt.RequestId+'.result.json')) $Case.Result
 WriteJson (Join-Path $script:Root ('diagnostics\failures\'+$Case.Diagnostic.ErrorId+'.json')) $Case.Diagnostic
}
function ReadReceipt {param($Case)Get-Content -LiteralPath (Join-Path $script:JobRoot ($Case.Receipt.RequestId+'.receipt.json')) -Raw -Encoding UTF8|ConvertFrom-Json}
function Blocked {TestUiMutationBlocked @{Action='Session';SessionAction='Connect'} @{Kind='Global'}}
try{
 $case=NewCase proven;Publish $case
 $resultPath=Join-Path $script:JobRoot ($id+'.result.json');$resultHash=(Get-FileHash -LiteralPath $resultPath).Hash
 RestoreUiJobReceipts;$resolved=ReadReceipt $case
 Check ($resolved.Status -ceq 'Failed' -and $resolved.Resolution.Kind -ceq 'LegacyStartupVerificationReadFailed' -and -not $resolved.Resolution.StartupMutation -and -not $resolved.Resolution.NetworkMutation -and -not (Blocked)) 'The exact pre-write settings failure stops blocking connection without claiming settings were saved'
 Check ((Get-FileHash -LiteralPath $resultPath).Hash -ceq $resultHash) 'The original failure result is retained byte for byte'
 $receiptHash=(Get-FileHash -LiteralPath (Join-Path $script:JobRoot ($id+'.receipt.json'))).Hash
 RefreshUiJobReceipts
 Check ($script:UncertainUiJobs.Count -eq 0 -and (Get-FileHash -LiteralPath (Join-Path $script:JobRoot ($id+'.receipt.json'))).Hash -ceq $receiptHash) 'Recovery survives reopening and is idempotent'
 $admission=StartJob @{Action='Session';SessionAction='Connect'} {} -PassThru
 Check ($admission.Accepted -and $admission.Disposition -ceq 'Started' -and $script:Admitted -eq 1) 'The real StartJob admission gate accepts connection after recovery; process launch is intercepted'
 foreach($scenario in @('MissingDiagnostic','WrongDiagnosticRequest','WrongDiagnosticAction','WrongDiagnosticId','MutatingSourceLine','WrongWorkerFrame','WrongException','WrongResultRequest','WrongResultError','WrongMetrics','LiveExecutor','UnboundExecutor','RemoteMutation','BoundRun','BoundTransaction','BoundScope','ResultData','InvalidTimestamp','MissingResult')){
  $case=NewCase $scenario
  switch($scenario){
   WrongDiagnosticRequest {$case.Diagnostic.RequestId=[guid]::NewGuid().ToString('N')}
   WrongDiagnosticAction {$case.Diagnostic.Action='Session'}
   WrongDiagnosticId {$case.Result.DiagnosticId=[guid]::NewGuid().ToString('N')}
   MutatingSourceLine {$case.Diagnostic.Frames[1].Line=68}
   WrongWorkerFrame {$case.Diagnostic.Frames[2].Line=2000}
   WrongException {$case.Diagnostic.ExceptionChain[0].Type='System.IO.IOException'}
   WrongResultRequest {$case.Result.RequestId=[guid]::NewGuid().ToString('N')}
   WrongResultError {$case.Result.ErrorId=[guid]::NewGuid().ToString('N')}
   WrongMetrics {$case.Result.ReadMetrics.ProcessId=$PID+1}
   LiveExecutor {$case.Receipt.ProcessStartedTicks=$liveTicks;$case.Result.ReadMetrics.ProcessStartedUtcTicks=$liveTicks}
   UnboundExecutor {$case.Receipt.ProcessId=0}
   RemoteMutation {$case.Receipt.Action='DeploymentProceed';$case.Result.Action='DeploymentProceed';$case.Diagnostic.Action='DeploymentProceed'}
   BoundRun {$case.Receipt.RunId=[guid]::NewGuid().ToString('D')}
   BoundTransaction {$case.Receipt.TransactionId=[guid]::NewGuid().ToString('D')}
   BoundScope {$case.Receipt.ResourceScope.Kind='DeploymentServer';$case.Receipt.ResourceScope.Host='192.0.2.50'}
   ResultData {$case.Result|Add-Member NoteProperty Data @{Status='OutcomeUnknown'}}
   InvalidTimestamp {$case.Diagnostic.AtUtc=$at.AddSeconds(-1).ToString('o')}
  }
  Publish $case
  if($scenario -eq 'MissingDiagnostic'){[IO.File]::Delete((Join-Path $script:Root ('diagnostics\failures\'+$diagnosticId+'.json')))}
  if($scenario -eq 'MissingResult'){[IO.File]::Delete((Join-Path $script:JobRoot ($id+'.result.json')))}
  RestoreUiJobReceipts
  Check ((Blocked) -and (ReadReceipt $case).Status -ceq 'OutcomeUnknown') ('Unproven outcome still blocks: '+$scenario)
  foreach($pending in @($script:UncertainUiJobs.ToArray())){if($pending.Process){$pending.Process.Dispose()}}
 }
 $case=NewCase conflictingrequest;Publish $case
 WriteJson (Join-Path $script:JobRoot ($id+'.request.json')) @{Action='SetUserSetting';RequestId=$id;Name='AutoTrustFirstConnection';Value=$true}
 RestoreUiJobReceipts;Check ((Blocked)) 'A surviving conflicting request cannot borrow the legacy diagnosis'
 ShowUiMutationBlocked @{Action='Session';SessionAction='Connect'} @{Kind='Global'}
 Check ($script:LastDialog.Body -match '保存启动与连接设置' -and $script:LastDialog.Body -notmatch ('SetUserSetting|'+$id) -and $script:LastDialog.Note -notmatch '旧连接操作' -and $script:LastDialog.Context.RequestId -ceq $id) 'The blocking dialog names the actual setting and preserves its exact action context'
 $case=NewCase readonly;Publish $case;$script:ReadOnly=$true;RestoreUiJobReceipts
 Check ((ReadReceipt $case).Status -ceq 'OutcomeUnknown') 'A read-only console never rewrites the original receipt'
 if($EvidenceDirectory){
  $case=NewCase actual-upgrade-record
  $files=@(Get-ChildItem -LiteralPath $EvidenceDirectory -Filter '*.receipt.json' -File)
  if($files.Count -ne 1){throw 'Use one captured non-credential settings failure.'}
  $case.Receipt=Get-Content -LiteralPath $files[0].FullName -Raw -Encoding UTF8|ConvertFrom-Json
  $case.Result=Get-Content -LiteralPath (Join-Path $EvidenceDirectory ($case.Receipt.RequestId+'.result.json')) -Raw -Encoding UTF8|ConvertFrom-Json
  $case.Diagnostic=Get-Content -LiteralPath (Join-Path $EvidenceDirectory ($case.Result.DiagnosticId+'.json')) -Raw -Encoding UTF8|ConvertFrom-Json
  Publish $case;RestoreUiJobReceipts
  Check ((ReadReceipt $case).Status -ceq 'Failed' -and -not (Blocked)) 'The exact captured upgrade failure is safely resolved in an isolated store'
  $before=$script:Admitted;$admission=StartJob @{Action='Session';SessionAction='Connect'} {} -PassThru
  Check ($admission.Accepted -and $script:Admitted -eq $before+1) 'The captured upgrade data can pass the real connection admission gate'
 }
 $report=[pscustomobject]@{Passed=$true;Checks=$checks.Count;Assertions=$checks.ToArray();RealNetworkChanges=0;ProductionWrites=0;RealWorkersLaunched=0;CapturedFailureReproduced=[bool]$EvidenceDirectory;PowerShell=$PSVersionTable.PSVersion.ToString()}
 if($ReportPath){WriteJson $ReportPath $report};$report|ConvertTo-Json -Depth 5
}finally{
 $absolute=[IO.Path]::GetFullPath($owned);$boundary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if(-not $absolute.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($absolute) -cnotmatch '^tc-settings-receipt-[a-f0-9]{32}$'){throw 'Unexpected test cleanup target'}
 foreach($entry in @($script:UncertainUiJobs.ToArray())){if($entry.Process){$entry.Process.Dispose()}}
 Remove-Item -LiteralPath $absolute -Recurse -Force
}
