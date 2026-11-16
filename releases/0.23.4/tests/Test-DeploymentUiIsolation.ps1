#requires -Version 5.1
[CmdletBinding()]param([string]$ReportPath)
$ErrorActionPreference='Stop'
$script:PackageRoot=Split-Path $PSScriptRoot -Parent
$script:Root=Join-Path ([IO.Path]::GetTempPath()) ('TC-UiIsolation-'+[guid]::NewGuid().ToString('N'))
. (Join-Path $script:PackageRoot 'ui/ConnectionProfilePages.ps1')
. (Join-Path $script:PackageRoot 'ui/DeploymentPages.ps1')
$script:Checks=New-Object 'Collections.Generic.List[string]'
$script:Failures=New-Object 'Collections.Generic.List[string]'
$script:Requests=New-Object 'Collections.Generic.List[object]'
function Check {param([bool]$Ok,[string]$Name)if($Ok){$script:Checks.Add($Name)}else{$script:Failures.Add($Name)}}
function IsBusy {$false}
function CaptureNavigationContext {[pscustomobject]@{Revision=1;View='deployment';TargetId='fixture'}}
function ShowProductDeployment {}
function ErrorDialog {param($Message)$script:Failures.Add('Unexpected error dialog: '+$Message)}
function Toast {param($Message)}
function Get-TCDeployAccessDiagnostic {param($Code)[pscustomobject]@{Code=$Code;Kind='Credentials';ClearCredential=$true;RetryWithCredential=$false}}
function Import-Module {param($Name,[switch]$DisableNameChecking)if([IO.Path]::GetFileName($Name) -notin @('DeploymentFlow.psm1','DeploymentTransport.psm1','ServerRegistry.psm1')){throw 'Unexpected module in UI isolation fixture'}}
function StartJob {param($Request,$Complete,$Message,$Transition,[switch]$Silent,$Failed,$OriginContext,$CallbackContext)
 $script:Requests.Add([pscustomobject]@{Request=$Request.Clone();Complete=$Complete;Failed=$Failed;CallbackContext=$CallbackContext})
}
function ResetFixture {
 $script:Requests.Clear();$script:Role='deployment';$script:Page='setup';$script:ReadOnly=$false;$script:Smoke=$false;$script:Job=$null
 $script:Controls=@{};$script:Footer=[pscustomobject]@{Text=''}
 $id='11111111-1111-4111-8111-111111111111'
 $script:DeployUI=@{Run=[pscustomobject]@{RunId=$id;ServerRecordId='22222222-2222-4222-8222-222222222222';Status='WaitingUser';Stage='MaterializeCandidate';RecoveryRequired=$false};SessionRef=[pscustomobject]@{RunId=$id;InstanceId='33333333-3333-4333-8333-333333333333'};Credential=@{Kind='Password';Password=(ConvertTo-SecureString 'FIXTURE_ONLY_MEMORY' -AsPlainText -Force)};SessionAttached=$false;LastPoll=[DateTime]::MinValue;LastAccessSignature='';Screen='run';Discovery=$null;TrustShown=$null}
}
ResetFixture
$old=$script:DeployUI;$oldRun=$old.Run;$oldRef=$old.SessionRef
BeginProductDeployment 'Auto'
Check (-not [object]::ReferenceEquals($old,$script:DeployUI)) 'new wizard owns a distinct flow identity'
Check (-not $script:DeployUI.Run -and -not $script:DeployUI.SessionRef -and -not $script:DeployUI.Credential) 'new wizard detaches old run session and credential'
Check ($oldRun.Stage -ceq 'MaterializeCandidate' -and $oldRef.RunId -ceq $oldRun.RunId) 'new wizard leaves old persisted-work references intact'
$script:Requests.Clear();PollProductDeployment
Check ($script:Requests.Count -eq 0) 'empty new form cannot poll an old session or emit an empty RunId'

ResetFixture
PollProductDeployment
$snapshot=$script:Requests[$script:Requests.Count-1];$old=$script:DeployUI;$oldRef=$old.SessionRef
BeginProductDeployment 'Auto';$script:Requests.Clear()
& $snapshot.Complete ([pscustomobject]@{InstanceId=$oldRef.InstanceId;Poll=[pscustomobject]@{RunId=$oldRef.RunId;HasSession=$false;Status='Failed';Code='AuthenticationRequired'}}) $snapshot.CallbackContext
Check ($script:Requests.Count -eq 0 -and -not $script:DeployUI.Run) 'late old-session failure cannot attach access state to a fresh form'

ResetFixture
PollProductDeployment
$snapshot=$script:Requests[$script:Requests.Count-1];$oldRef=$script:DeployUI.SessionRef
$script:DeployUI.SessionRef=[pscustomobject]@{RunId=$oldRef.RunId;InstanceId='44444444-4444-4444-8444-444444444444'}
$script:Requests.Clear()
& $snapshot.Complete ([pscustomobject]@{InstanceId=$oldRef.InstanceId;Poll=[pscustomobject]@{RunId=$oldRef.RunId;HasSession=$false;Status='Failed';Code='AuthenticationRequired'}}) $snapshot.CallbackContext
Check ($script:Requests.Count -eq 0) 'late snapshot cannot replace a newer instance for the same run'

ResetFixture
$script:DeployUI.SessionRef.RunId='55555555-5555-4555-8555-555555555555'
PollProductDeployment
Check ($script:Requests.Count -eq 0) 'a session belonging to another run is rejected before polling'

ResetFixture
BeginProductDeployment 'Auto';$discover=$script:Requests[$script:Requests.Count-1]
BeginProductDeployment 'Auto';$latest=$script:DeployUI
& $discover.Complete ([pscustomobject]@{Servers=@('stale-server');ContinueRuns=@()}) $discover.CallbackContext
Check ([object]::ReferenceEquals($latest,$script:DeployUI) -and -not $script:DeployUI.Discovery) 'late discovery cannot populate a subsequent new wizard'

$result=[pscustomobject]@{Passed=($script:Failures.Count -eq 0);Checks=$script:Checks.Count;Assertions=$script:Checks.ToArray();Failures=$script:Failures.ToArray();PowerShellVersion=$PSVersionTable.PSVersion.ToString();FixtureOnly=$true;WorkerLaunched=$false;NetworkChanges=0;RealCredentialsRead=0}
if($ReportPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($result|ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($true)))}
$result|ConvertTo-Json -Depth 5
if(-not $result.Passed){throw ('UI isolation regression: '+($script:Failures -join '; '))}
