#requires -Version 5.1
[CmdletBinding()]param([string]$ReportPath)
$ErrorActionPreference='Stop'
$script:PackageRoot=Split-Path $PSScriptRoot -Parent
$script:Root=Join-Path ([IO.Path]::GetTempPath()) ('TC-UiRecovery-'+[guid]::NewGuid().ToString('N'))
Import-Module (Join-Path $script:PackageRoot 'DeploymentFlow.psm1') -DisableNameChecking
Import-Module (Join-Path $script:PackageRoot 'ServerRegistry.psm1') -DisableNameChecking
. (Join-Path $script:PackageRoot 'ui/ConnectionProfilePages.ps1')
. (Join-Path $script:PackageRoot 'ui/DeploymentPages.ps1')
. (Join-Path $script:PackageRoot 'ui/BackgroundJobs.ps1')
$flow=Get-Module DeploymentFlow;$checks=New-Object 'Collections.Generic.List[string]'
$script:Job=$null;$script:JobRoot=Join-Path $script:Root 'Product/jobs';$script:ReadOnly=$false;$script:Role='deployment';$script:Controls=@{}
$script:Captured=New-Object 'Collections.Generic.List[object]'
function Check {param([bool]$Ok,[string]$Name)if(-not $Ok){throw $Name};$checks.Add($Name)}
function Save {param($Run)& $flow {param($Root,$Run)Save-TCDeploymentRun $Root $Run} $script:Root $Run}
function StartJob {param($Request,$Complete,$Message,$Transition,[switch]$Silent,$Failed,$OriginContext,$CallbackContext)$script:Captured.Add([pscustomobject]@{Request=$Request;Complete=$Complete;CallbackContext=$CallbackContext})}
function IsBusy {$false}
function ShowProductDeployment {}
function ErrorDialog {param($Message)throw $Message}
function SaveUiJobReceipt {param($Job,$Status)$Job.ReceiptState=$Status}
try{
 $a=New-TCDeploymentRun -Root $script:Root -Connection @{Host='192.0.2.10';Port=22;User='root';IdentityFile=''}
 $b=New-TCDeploymentRun -Root $script:Root -Connection @{Host='192.0.2.20';Port=22;User='root';IdentityFile=''}
 $a.LastRemoteMutation=[pscustomobject]@{IntentId=[guid]::NewGuid().ToString();Operation='management_apply';State='Dispatched';Mutating=$true};$a.RecoveryRequired=$true;$a.Status='OutcomeUnknown';$a=Save $a
 $scope=GetUiJobResourceScope @{Action='DeploymentProceed';RunId=$a.RunId;Command='Continue'}
 Check ($scope.Kind -ceq 'DeploymentServer' -and $scope.ServerRecordId -ceq $a.ServerRecordId) 'Scope comes from persisted run and server registry'
 $pending=@{RequestId=[guid]::NewGuid().ToString('N');Action='DeploymentProceed';RunId=$a.RunId;ResourceScope=$scope;Process=$null;Result=$null;DeploymentMutation=@{RunId=$a.RunId;ServerRecordId=$a.ServerRecordId;MutationIntentId=$a.LastRemoteMutation.IntentId;Operation='management_apply'}}
 $script:UncertainUiJobs.Add($pending)
 Check (TestUiMutationBlocked @{Action='DeploymentProceed';RunId=$a.RunId;Command='Continue'}) 'Unknown operation blocks the same server continuation'
 Check (-not (TestUiMutationBlocked @{Action='DeploymentCreate';Connection=@{Host='192.0.2.30';Port=22;User='root'}})) 'Independent new server remains available'
 Check (TestUiMutationBlocked @{Action='DeploymentCreate';Connection=@{Host='192.0.2.10';Port=2222;User='another'}}) 'Same host conflicts even with another SSH account or port'
 Check (-not (TestUiMutationBlocked @{Action='DeploymentProceed';RunId=$a.RunId;Command='Reconcile'})) 'Explicit read-only reconciliation bypasses mutation lock'
 Check (-not (TestUiMutationBlocked @{Action='DeploymentPoll';RunId=$a.RunId;ReconciliationIntentId=$a.LastRemoteMutation.IntentId})) 'Bound read-only reconciliation polling remains available'
 Check (TestUiMutationBlocked @{Action='DeploymentPoll';RunId=$a.RunId}) 'Unbound polling cannot advance normal mutation while uncertain'
 Check (TestUiMutationBlocked @{Action='DeploymentProceed';RunId=$b.RunId;Command='Probe'}) 'A local probe retains shared-resource protection'
 $a.ProbeRecoveryRequired=$true;$a=Save $a
 $probeScope=GetUiJobResourceScope @{Action='DeploymentProceed';RunId=$a.RunId;Command='Continue'}
 Check ($probeScope.Kind -ceq 'Global') 'Unfinished local probe cleanup always widens scope to global'
 $pending.ResourceScope=$probeScope
 Check (TestUiMutationBlocked @{Action='DeploymentCreate';Connection=@{Host='192.0.2.30';Port=22;User='root'}}) 'Independent remote work cannot bypass unknown shared local cleanup'
 $pending.ResourceScope=$scope;$a.ProbeRecoveryRequired=$false
 $a.LastRemoteMutation.State='Completed';$a.Status='WaitingUser';$a.RecoveryRequired=$false
 $a|Add-Member NoteProperty RecoveryVerification ([pscustomobject]@{Status='Verified';CompletedAtUtc=[DateTimeOffset]::UtcNow.ToString('o');RunId=$a.RunId;ServerRecordId=$a.ServerRecordId;MutationIntentId=[guid]::NewGuid().ToString();Operation='management_apply'}) -Force
 ResolveUiDeploymentUncertainty $a
 Check ($script:UncertainUiJobs.Count -eq 1) 'A proof for another mutation cannot clear the pending receipt'
 $a.RecoveryVerification.MutationIntentId=$a.LastRemoteMutation.IntentId;$a.ProbeRecoveryRequired=$true
 ResolveUiDeploymentUncertainty $a
 Check ($script:UncertainUiJobs.Count -eq 1) 'A matching remote proof cannot clear local probe recovery'
 $a.ProbeRecoveryRequired=$false;$a.StopTransaction=@{State='OutcomeUnknown'}
 ResolveUiDeploymentUncertainty $a
 Check ($script:UncertainUiJobs.Count -eq 1) 'Unrelated stop transaction still protects pending receipt'
 $a.StopTransaction=$null;ResolveUiDeploymentUncertainty $a
 Check ($script:UncertainUiJobs.Count -eq 0 -and $pending.ReceiptState -ceq 'Reconciled') 'Only matching completed evidence clears the original receipt'
 $script:UncertainUiJobs.Add($pending);$a.LastRemoteMutation.State='NotApplied'
 ResolveUiDeploymentUncertainty $a
 Check ($script:UncertainUiJobs.Count -eq 1) 'NotApplied without an explicit matching outcome cannot clear the receipt'
 $a.RecoveryVerification|Add-Member NoteProperty Outcome 'NotApplied' -Force;ResolveUiDeploymentUncertainty $a
 Check ($script:UncertainUiJobs.Count -eq 0) 'Verified NotApplied resolves the original management receipt without claiming success'
 $script:DeployUI=@{Run=$a;SessionRef=$null;SessionAttached=$true;PollError='';WorkerFailure=$null}
 $a.LastRemoteMutation.State='Dispatched';$a.RecoveryRequired=$true;$a.RecoveryVerification.Status='Checking';$script:Captured.Clear()
 AdvanceDeploymentUI Continue
 Check ($script:Captured.Count -eq 1 -and $script:Captured[0].Request.Command -ceq 'Reconcile') 'Remote recovery button uses the dedicated reconciliation command'
 $script:Captured.Clear();PollDeploymentRunUI
 Check ($script:Captured[0].Request.ReconciliationIntentId -ceq $a.LastRemoteMutation.IntentId) 'Recovery polling includes the exact original mutation id'
 $a.LastRemoteMutation.State='Completed';$a.ProbeRecoveryRequired=$true;$a.RecoveryVerification.Status='Verified';$script:Captured.Clear()
 AdvanceDeploymentUI Continue
 Check ($script:Captured[0].Request.Command -ceq 'RecoverProbe') 'Local probe recovery uses an explicit cleanup-only command'
 Check (-not (TestUiMutationBlocked @{Action='DeploymentProceed';RunId=$a.RunId;Command='RecoverProbe'})) 'Cleanup-only command can reach the owned-probe recovery gate'
 $a.CandidateNodeId=[guid]::NewGuid().ToString();$a.ProbeAttemptId=[guid]::NewGuid().ToString('N');$a.ProbeRecoveryRequired=$false;$a.RecoveryRequired=$false
 $a|Add-Member NoteProperty ProbeRecovery ([pscustomobject]@{CleanupComplete=$true;CompletedAtUtc=[DateTimeOffset]::UtcNow.ToString('o');RunId=$a.RunId;CandidateNodeId=$a.CandidateNodeId;ProbeAttemptId=$a.ProbeAttemptId}) -Force
 $probePending=@{RunId=$a.RunId;Process=$null;Result=$null;DeploymentProbe=@{RunId=$a.RunId;CandidateNodeId=$a.CandidateNodeId;ProbeAttemptId=[guid]::NewGuid().ToString('N')}}
 $script:UncertainUiJobs.Add($probePending);ResolveUiProbeUncertainty $a
 Check ($script:UncertainUiJobs.Count -eq 1) 'Probe cleanup evidence cannot clear another attempt'
 $probePending.DeploymentProbe.ProbeAttemptId=$a.ProbeAttemptId;ResolveUiProbeUncertainty $a
 Check ($script:UncertainUiJobs.Count -eq 0 -and $probePending.ReceiptState -ceq 'Reconciled') 'Owned cleanup evidence clears only the exact probe receipt'
 $script:UncertainUiJobs.Clear();$script:UncertainUiJobs.Add(@{ResourceScope=$null;RunId='';Action='Unknown'})
 Check (TestUiMutationBlocked @{Action='DeploymentCreate';Connection=@{Host='192.0.2.30';Port=22;User='root'}}) 'Legacy receipt without verified scope remains conservative'
 $result=[pscustomobject]@{Passed=$true;Checks=$checks.Count;Assertions=$checks.ToArray();ProductionWrites=0;WorkerLaunched=$false;NetworkChanges=0}
 if($ReportPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($result|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($true))}
 $result|ConvertTo-Json -Compress
}finally{
 $full=[IO.Path]::GetFullPath($script:Root);$boundary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if($full.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($full) -cmatch '^TC-UiRecovery-[a-f0-9]{32}$' -and (Test-Path -LiteralPath $full)){Remove-Item -LiteralPath $full -Recurse -Force}
}
