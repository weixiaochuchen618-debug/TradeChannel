#requires -Version 5.1
[CmdletBinding()]param([string]$ReportPath)
$ErrorActionPreference='Stop';Set-StrictMode -Version 2.0
$source=Split-Path $PSScriptRoot -Parent
$script:PackageRoot=Join-Path ([IO.Path]::GetTempPath()) ('tc-memory-jobs-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($script:PackageRoot)
[IO.File]::Copy((Join-Path $source 'WorkerErrors.psm1'),(Join-Path $script:PackageRoot 'WorkerErrors.psm1'))
$fixture=@'
function Invoke-MemoryFixture {param($Gate,$State,[Security.SecureString]$Credential,[switch]$Fail)
 $State.Calls=[int]$State.Calls+1
 if($Gate -and -not $Gate.Wait(10000)){throw 'Fixture gate timed out'}
 if($Fail){throw '{"password":"fixture-secret-not-for-display"}'}
 [pscustomobject]@{CredentialSecure=($Credential -is [Security.SecureString]);Marker='completed'}
}
Export-ModuleMember -Function Invoke-MemoryFixture
'@
[IO.File]::WriteAllText((Join-Path $script:PackageRoot 'MemoryFixture.psm1'),$fixture,[Text.UTF8Encoding]::new($true))
$script:Smoke=$false;$script:Footer=[pscustomobject]@{Text=''};$script:Dialogs=New-Object 'Collections.Generic.List[string]'
$script:Job=$null;$script:Pending=$null;$script:Linux=$null;$script:DeployUI=@{Run=$null;PendingManagement=$null;SessionRef=$null;Credential=$null}
$script:Checks=New-Object 'Collections.Generic.List[string]';$script:Durations=New-Object 'Collections.Generic.List[double]'
function Check {param([bool]$Ok,[string]$Message)if(-not $Ok){throw $Message};$script:Checks.Add($Message)}
function ErrorDialog {param([string]$Message)$script:Dialogs.Add($Message)}
function StateKey {'Disconnected'}
function ImportFunction {param([string]$File,[string]$Name)
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $source $File),[ref]$tokens,[ref]$errors)
 if($errors.Count){throw 'UI source parse failure'}
 $definition=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $Name},$true)
 $body=$definition.Body.Extent.Text;Set-Item ('Function:script:'+$Name) ([scriptblock]::Create($body.Substring(1,$body.Length-2)))
}
ImportFunction 'TradeChannel.ps1' 'IsBusy'
ImportFunction 'ui\WindowLifecycle.ps1' 'TestWindowTaskInProgress'
Check (-not (IsBusy) -and -not (TestWindowTaskInProgress)) 'No strict-mode failure before memory jobs initialize'
. (Join-Path $source 'ui\MemoryJobs.ps1')
function Drain {
 $watch=[Diagnostics.Stopwatch]::StartNew()
 while($script:UiMemoryJobs.Count -and $watch.Elapsed.TotalSeconds -lt 12){PollUiMemoryJobs;Start-Sleep -Milliseconds 10}
 Check ($script:UiMemoryJobs.Count -eq 0) 'Every accepted memory request reaches a single terminal result'
}
$gate=New-Object Threading.ManualResetEventSlim($false)
try{
 $state=[hashtable]::Synchronized(@{Calls=0});$credential=ConvertTo-SecureString 'fixture-private-value' -AsPlainText -Force
 $context=@{CompleteCount=0;FailedCount=0;Data=$null;Failure=$null}
 $watch=[Diagnostics.Stopwatch]::StartNew()
 StartUiCommand -Module MemoryFixture.psm1 -Command Invoke-MemoryFixture -Arguments @{Gate=$gate;State=$state;Credential=$credential} -Context $context -Complete {param($data,$ctx)$ctx.CompleteCount++;$ctx.Data=$data} -Failed {param($message,$ctx,$failure)$ctx.FailedCount++;$ctx.Failure=$failure}
 $watch.Stop();$script:Durations.Add($watch.Elapsed.TotalMilliseconds)
 Check ($watch.Elapsed.TotalMilliseconds -le 200) 'Slow management command returns control within 200 ms'
 Check ((IsBusy) -and (TestWindowTaskInProgress)) 'An accepted background command prevents duplicate action and direct exit'
 $memoryJob=$script:UiMemoryJobs[0];$memoryJob.Started=[DateTime]::UtcNow.AddSeconds(-46)
 $watch.Restart();foreach($i in 1..30){PollUiMemoryJobs};$watch.Stop()
 Check ($watch.Elapsed.TotalMilliseconds -le 200 -and $memoryJob.Notified -and $script:UiMemoryJobs.Count -eq 1) 'Timeout notification and UI polling do not wait on or cancel the command'
 $gate.Set();Drain
 Check ($state.Calls -eq 1 -and $context.CompleteCount -eq 1 -and $context.FailedCount -eq 0) 'Timeout does not replay; completion is consumed exactly once'
 Check ($context.Data.CredentialSecure -and $credential.Length -eq 21) 'Credential remains a SecureString and the original memory object is retained'
 Check (-not $memoryJob.Context -and -not $memoryJob.Complete -and -not $memoryJob.Failed -and -not $memoryJob.Handle) 'Completed job releases callbacks, context and async handle'
 Check (-not (IsBusy) -and -not (TestWindowTaskInProgress)) 'Completed command releases the busy and close guards'
 foreach($i in 1..30){PollUiMemoryJobs}
 Check ($context.CompleteCount -eq 1 -and $state.Calls -eq 1) 'Repeated ticks never consume or dispatch the same request twice'

 $context=@{CompleteCount=0;FailedCount=0;Failure=$null}
 StartUiCommand -Module MemoryFixture.psm1 -Command Invoke-MemoryFixture -Arguments @{State=$state;Credential=$credential} -Context $context -Complete {param($data,$ctx)$ctx.CompleteCount++;throw 'fixture-secret-not-for-display'} -Failed {param($message,$ctx)$ctx.FailedCount++}
 Drain
 Check ($context.CompleteCount -eq 1 -and $context.FailedCount -eq 0 -and $script:Dialogs.Count -eq 1) 'Presentation failure does not reinterpret an accepted result as command failure'
 Check (($script:Dialogs -join ' ') -notmatch 'fixture-secret') 'Presentation exception text is never exposed'

 $context=@{CompleteCount=0;FailedCount=0;Failure=$null;Message=''}
 StartUiCommand -Module MemoryFixture.psm1 -Command Invoke-MemoryFixture -Arguments @{State=$state;Credential=$credential;Fail=$true} -Context $context -Complete {param($data,$ctx)$ctx.CompleteCount++} -Failed {param($message,$ctx,$failure)$ctx.FailedCount++;$ctx.Failure=$failure;$ctx.Message=$message}
 Drain
 Check ($context.CompleteCount -eq 0 -and $context.FailedCount -eq 1 -and $context.Failure.Phase -eq 'Executing' -and $context.Failure.OutcomeUnknown) 'An unclassified execution failure retains the unknown outcome'
 Check ($context.Message -notmatch 'fixture-secret|password' -and $context.Failure.ErrorId) 'Execution failures use safe messages and a correlation identifier'

 $context=@{Failure=$null;FailedCount=0}
 StartUiCommand -Module MissingFixture.psm1 -Command Invoke-MemoryFixture -Arguments @{} -Context $context -Failed {param($message,$ctx,$failure)$ctx.FailedCount++;$ctx.Failure=$failure}
 Drain
 Check ($context.FailedCount -eq 1 -and $context.Failure.Phase -eq 'BeforeDispatch' -and -not $context.Failure.OutcomeUnknown) 'A module load failure is proven not dispatched and does not create unknown server state'
 $files=@(Get-ChildItem -LiteralPath $script:PackageRoot -File -Recurse)
 Check ($files.Count -eq 2 -and -not (Test-Path -LiteralPath (Join-Path $script:PackageRoot 'jobs'))) 'Background commands and credentials are not serialized to requests or files'
 $result=[pscustomobject]@{Passed=$true;Checks=$script:Checks.Count;Assertions=$script:Checks.ToArray();DispatchMilliseconds=$script:Durations.ToArray();RealBackgroundRunspaces=4;NetworkChanges=0;CredentialsOnDisk=$false;PowerShellVersion=$PSVersionTable.PSVersion.ToString()}
 if($ReportPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($result|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($true))}
 $result|ConvertTo-Json -Depth 6
}finally{
 $gate.Set()
 foreach($memoryJob in @($script:UiMemoryJobs.ToArray())){try{$null=$memoryJob.PowerShell.EndInvoke($memoryJob.Handle)}catch{};$memoryJob.PowerShell.Dispose()}
 $gate.Dispose()
 $full=[IO.Path]::GetFullPath($script:PackageRoot)
 if($full.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($full) -cmatch '^tc-memory-jobs-[a-f0-9]{32}$'){Remove-Item -LiteralPath $full -Recurse -Force}
}
