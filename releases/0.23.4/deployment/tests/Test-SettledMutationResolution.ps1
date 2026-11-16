#requires -Version 5.1
#requires -PSEdition Desktop
[CmdletBinding()]param([Parameter(Mandatory=$true)][string]$PackageRoot,[Parameter(Mandatory=$true)][string]$BackendEvidence,[Parameter(Mandatory=$true)][string]$ReportPath,[string]$LegacyPackageRoot)
$ErrorActionPreference='Stop';Set-StrictMode -Version 2
$env:PSModulePath=Join-Path $PSHOME 'Modules'
$root=Join-Path ([IO.Path]::GetTempPath()) ('tc-audit-deploy-'+[guid]::NewGuid().ToString('N'))
$flow=Import-Module (Join-Path $PackageRoot 'DeploymentFlow.psm1') -PassThru -DisableNameChecking
Import-Module (Join-Path $PackageRoot 'DeploymentStore.psm1') -DisableNameChecking
Import-Module (Join-Path $PackageRoot 'ServerRegistry.psm1') -DisableNameChecking
$transport=Import-Module (Join-Path $PackageRoot 'DeploymentTransport.psm1') -PassThru -DisableNameChecking
$fixture=[pscustomobject]@{Poll=$null;Ref=$null;Dispatches=(New-Object 'Collections.Generic.List[object]');Reads=0;ForbiddenCalls=0}
& $transport {param($Fixture)
 $script:AuditFixture=$Fixture
 function script:Read-TCDeployObservation {param($SessionRef)
  if((ConvertTo-Json $SessionRef -Compress) -cne (ConvertTo-Json $script:AuditFixture.Ref -Compress)){throw 'Unbound fixture'}
  $script:AuditFixture.Reads++;return $script:AuditFixture.Poll
 }
 function script:Invoke-TCDeployPipe {$script:AuditFixture.ForbiddenCalls++;throw 'No live pipe allowed'}
} $fixture
& $flow {param($Fixture)
 $script:AuditFixture=$Fixture
 function script:Invoke-TCDeployOperation {param($SessionRef,$Operation,[Alias('Input')]$OperationInput,$OperationId)
  if($Operation -notin @('status','request_status','server_info','operation_result','inspect')){throw ('Unexpected dispatch: '+$Operation)}
  $script:AuditFixture.Dispatches.Add([pscustomobject]@{Operation=$Operation;OperationId=$OperationId})
  [pscustomobject]@{Ok=$true;OperationId=$OperationId}
 }
 function script:Get-TCDeploySession {param($SessionRef)return $script:AuditFixture.Poll}
} $fixture
function Set-Poll {param($Run,$Data,[string]$Status='Completed',[string]$Code='Completed')
 $fixture.Ref=$Run.SessionRef
 $fixture.Poll=[pscustomobject]@{Ok=($Status -eq 'Completed');Status=$Status;Code=$Code;Operation=$Run.DispatchIntent.Operation;OperationId=$Run.PendingOperationId;Data=$Data;RunId=$Run.RunId;InstanceId=$Run.SessionRef.InstanceId;HasSession=$true;HasMutatingOperations=$true;AuthenticationGeneration=1;Connection=@{Host='192.0.2.70';Port=22;User='root'};ObservedFingerprint=('SHA256:'+('A'*43));AcceptedFingerprint=('SHA256:'+('A'*43));ObservedHostKeyAlgorithm='ssh-ed25519'}
}
$rows=New-Object 'Collections.Generic.List[object]'
try{
 $backend=Get-Content -LiteralPath $BackendEvidence -Raw -Encoding UTF8|ConvertFrom-Json
 foreach($case in $backend.Cases){
  $run=New-TCDeploymentRun -Root $root -Connection @{Host='192.0.2.70';Port=22;User='root';IdentityFile=''} -Name ('Audit '+$case.Case)
  $run.SessionRef=[pscustomobject]@{RunId=$run.RunId;InstanceId=[guid]::NewGuid().ToString();PipeName=('TCDeploy-'+[guid]::NewGuid().ToString('N'));ProcessId=240001;StartTimeUtcTicks='638000000000000000';Root=$root}
  $run.ClientRequest=$case.ClientRequest;$run.Plan=[pscustomobject]@{PlanId=$case.PlanId}
  $purpose=if($case.Operation -eq 'apply'){'Apply'}else{'Authorize'}
  $run.DispatchIntent=[pscustomobject]@{IntentId=$case.IntentId;Operation=$case.Operation;Purpose=$purpose;InputDigest=(Get-TCDDigest $case.Input);State='Dispatched';Mutating=$true;CreatedAtUtc=[DateTimeOffset]::UtcNow.ToString('o')}
  $run.LastRemoteMutation=$run.DispatchIntent;$run.PendingOperationId=$run.DispatchIntent.IntentId;$run.PendingPurpose=$purpose;$run.Stage=$purpose;$run.Status='Running'
  $run=& $flow {param($Root,$Run)Save-TCDeploymentRun $Root $Run} $root $run
  Set-Poll $run $case.Reply.Data Failed $case.Reply.Data.Code
  $null=Set-TCServerRecord -Root $root -Id $run.ServerRecordId -PinnedFingerprint ('SHA256:'+('A'*43)) -SessionRef $run.SessionRef
  $failed=Sync-TCDeploymentRun -Root $root -RunId $run.RunId
  $run=Invoke-TCDeploymentAdvance -Root $root -RunId $run.RunId -Command Reconcile
  Set-Poll $run $case.ResolutionReply.Data
  $run=Sync-TCDeploymentRun -Root $root -RunId $run.RunId -ReconciliationIntentId $run.RecoveryVerification.MutationIntentId
  $before=$fixture.Dispatches.Count
  $again=Invoke-TCDeploymentAdvance -Root $root -RunId $run.RunId -Command Continue
  $row=[pscustomobject]@{Case=$case.Case;BackendFailure=$case.Reply.Data.Code;BackendPendingJournal=$case.PendingJournal;InitialLocalStatus=$failed.Status;ReconciledLocalStatus=$run.Status;ReconciledLocalStage=$run.Stage;RecoveryRequired=$run.RecoveryRequired;LastMutationState=$run.LastRemoteMutation.State;Outcome=$run.RecoveryVerification.OperationResolution.Outcome;ContinueStatus=$again.Status;ContinueDispatchCount=($fixture.Dispatches.Count-$before);ExpectedMode='Acceptance';ExpectedBehaviorSatisfied=($run.Stage -eq 'RecoveryVerified' -and -not $run.RecoveryRequired -and $run.LastRemoteMutation.State -eq 'NotApplied' -and $run.ResolvedMutationHistory.Count -eq 1 -and $again.Status -eq 'Running' -and ($fixture.Dispatches.Count-$before) -eq 1);OriginalErrorPreserved=($run.ResolvedMutationHistory[0].OriginalError.Code -ceq $case.Reply.Data.Code);OriginalRequestPreserved=((Get-TCDDigest $again.ClientRequest) -ceq (Get-TCDDigest $case.ClientRequest));UnexpectedActors=$fixture.ForbiddenCalls}
  if(-not $row.ExpectedBehaviorSatisfied -or -not $row.OriginalErrorPreserved -or -not $row.OriginalRequestPreserved){throw ('Expected recovery failed: '+($row|ConvertTo-Json -Compress))}
  if($again.DispatchIntent.IntentId -ceq $case.IntentId){throw 'Retry reused the old mutation ID'}
  # Restore the exact resolved checkpoint for an independent old-version read;
  # no real worker was started by this fixture's next-read acceptance check.
  $null=& $flow {param($Root,$Run)Save-TCDeploymentRun $Root $Run} $root $run
  $rows.Add($row)
 }
 if($LegacyPackageRoot){
  $legacyReport=Join-Path (Split-Path ([IO.Path]::GetFullPath($ReportPath)) -Parent) 'legacy-resolved-read.json'
  & (Join-Path $PSHOME 'powershell.exe') -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Read-LegacyResolvedMutation.ps1') -LegacyPackageRoot $LegacyPackageRoot -Root $root -ReportPath $legacyReport
  if($LASTEXITCODE -ne 0){throw 'Old-version read-only compatibility failed'}
 }
 $report=[pscustomobject]@{Passed=$true;Meaning='Acceptance: real backend failures resolve without replaying mutation';PowerShellVersion=$PSVersionTable.PSVersion.ToString();Source=$PackageRoot;Cases=$rows.ToArray();PublicFlowEntrypoints=$true;LivePipeCalls=$fixture.ForbiddenCalls;ObservationReads=$fixture.Reads;ProductionStateTouched=$false;FixtureRoot=$root}
 [IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($true))
 $report|ConvertTo-Json -Depth 12
}finally{
 $full=[IO.Path]::GetFullPath($root);$boundary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if(-not $full.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -cnotmatch '^tc-audit-deploy-[a-f0-9]{32}$'){throw 'Unsafe cleanup target'}
 if(Test-Path -LiteralPath $full){Remove-Item -LiteralPath $full -Recurse -Force}
}
