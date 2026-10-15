#requires -Version 5.1
[CmdletBinding()]param([string]$PackageRoot,[string]$ReportPath)
$ErrorActionPreference='Stop';$env:PSModulePath=Join-Path $PSHOME 'Modules'
if(-not $PackageRoot){$PackageRoot=Split-Path $PSScriptRoot -Parent}
$script:PackageRoot=[IO.Path]::GetFullPath($PackageRoot)
$script:Root=Join-Path ([IO.Path]::GetTempPath()) ('TC-FirstTrust-'+[guid]::NewGuid().ToString('N'))
$flow=Import-Module (Join-Path $PackageRoot 'DeploymentFlow.psm1') -PassThru -DisableNameChecking
$registry=Import-Module (Join-Path $PackageRoot 'ServerRegistry.psm1') -PassThru -DisableNameChecking
$null=Import-Module (Join-Path $PackageRoot 'DeploymentDecision.psm1') -DisableNameChecking
. (Join-Path $PackageRoot 'ui\ConnectionProfilePages.ps1')
. (Join-Path $PackageRoot 'ui\DeploymentPages.ps1')
$checks=New-Object 'Collections.Generic.List[string]'
$evidence=@{Poll=$null;Reads=0;ForbiddenCalls=0}
& $flow {
 param($Evidence)
 $script:TrustEvidence=$Evidence
 function script:Get-TCDeploySession {param($SessionRef)$script:TrustEvidence.Reads++;return $script:TrustEvidence.Poll}
 function script:Invoke-TCDeployOperation {$script:TrustEvidence.ForbiddenCalls++;throw 'Live server commands forbidden'}
 function script:Start-TCDeploySession {$script:TrustEvidence.ForbiddenCalls++;throw 'Live SSH forbidden'}
} $evidence
function Check {param([bool]$Ok,[string]$Name)if(-not $Ok){throw ('FAILED: '+$Name)};$checks.Add($Name)}
function SaveFixture {param($Run)& $flow {param($Root,$Run)Save-TCDeploymentRun $Root $Run} $script:Root $Run}
function PollFixture {param([string]$Code='HostTrustRequired',[string]$Status='Failed')
 $evidence.Poll=[pscustomobject]@{Code=$Code;Status=$Status;HasSession=$false;ObservedFingerprint=('SHA256:'+('A'*43));HostKeyAlgorithm='ssh-ed25519'}
}
function BindFixture {param($Run,$Ref,[switch]$AttemptOnly)Set-TCDeploymentAccessState -Root $script:Root -RunId $Run.RunId -SessionRef $Ref -AttemptOnly:$AttemptOnly}
function IsBusy {$false}
function ShowProductDeployment {$script:Renders++}
function BeginDeploymentIdentityVerification {$script:IdentityFlows++;throw 'First trust must not start identity replacement'}
function ErrorDialog {param($Message)$script:Errors.Add($Message)}
function OpenDialog {param($Title,$Body,$Note,$Confirm,$Action,$Cancel,$ConfirmStyle,$Context)
 $script:Dialogs++;$script:Dialog=@{Title=$Title;Body=$Body;Action=$Action;Context=$Context;Visible=$true}
}
function StartJob {param($Request,$Complete,$Message,$Transition,[switch]$Silent,$Failed,$CallbackContext)
 $script:Jobs.Add([string]$Request.Action)
 if($Request.Action -ne 'DeploymentAccessState'){throw ('Unexpected actor: '+$Request.Action)}
 $saved=Set-TCDeploymentAccessState -Root $script:Root -RunId $Request.RunId -SessionRef $Request.SessionRef -AttemptOnly:([bool]$Request.AttemptOnly)
 & $Complete $saved $CallbackContext
}
function StartUiCommand {param($Module,$Command,$Arguments,$Complete,$Failed,$Context,$Message)
 if($Command -ne 'Set-TCDeployCredential'){throw ('Unexpected memory actor: '+$Command)}
 $script:Authentications.Add(@{Pin=$Arguments.PinnedFingerprint;Host=$Arguments.Connection.Host;Credential=$Arguments.Credential;SessionRef=$Arguments.SessionRef})
 PollFixture 'Connecting' 'Connecting'
 & $Complete ([pscustomobject]@{Ok=$true;Status='Connecting'}) $Context
}
function ResetUiFixture {param($Run,$Ref)
 function script:Import-Module {param($Name,[switch]$DisableNameChecking,[switch]$PassThru)
  $loaded=Get-Module ([IO.Path]::GetFileNameWithoutExtension($Name)) -All|Select-Object -First 1;if(-not $loaded){throw ('Unexpected unloaded UI module: '+$Name)};if($PassThru){return $loaded}
 }
 function script:Get-TCServer {param($Root,$Id)
  $server=& $registry {param($Root,$Id)Get-TCServer -Root $Root -Id $Id} $Root $Id
  if($script:OverrideHost){$server.Connection.Host=$script:OverrideHost};return $server
 }
 $script:Role='deployment';$script:ReadOnly=$false;$script:Smoke=$false;$script:Job=$null;$script:Controls=@{};$script:Footer=[pscustomobject]@{Text=''}
 $script:Dialogs=0;$script:Renders=0;$script:IdentityFlows=0;$script:OverrideHost=''
 $script:Jobs=New-Object 'Collections.Generic.List[string]';$script:Errors=New-Object 'Collections.Generic.List[string]';$script:Authentications=New-Object 'Collections.Generic.List[object]'
 $script:DeployUI=@{Run=$Run;SessionRef=$Ref;SessionAttached=$false;Credential=@{Kind='Password';Password=(ConvertTo-SecureString 'ISOLATED_FIRST_TRUST_SECRET' -AsPlainText -Force)};CredentialExpiresAt=[DateTimeOffset]::UtcNow.AddMinutes(30);TrustShown=$null;TrustShownInstanceId='';LastAccessSignature='';LastPoll=[DateTime]::MinValue;ReconnectMessage='正在恢复服务器连接';PollError='';WorkerFailure=$null;AutomaticLoginRetries=2;Reauth=$false}
 $script:DeployUI.CredentialBinding=DeploymentCredentialScopeUI (Get-TCServer $script:Root $Run.ServerRecordId)
}
$passed=$false;$failure=''
try{
 $run=New-TCDeploymentRun -Root $script:Root -Connection @{Host='192.0.2.10';Port=22;User='root';IdentityFile=''} -Name 'First trust fixture'
 $ref=[pscustomobject]@{RunId=$run.RunId;InstanceId=[guid]::NewGuid().ToString();PipeName=('TCDeploy-'+[guid]::NewGuid().ToString('N'));ProcessId=999999;StartTimeUtcTicks='123';Root=(Join-Path $script:Root 'fixture-session')}
 $run.LastError=[pscustomobject]@{Code='ConnectionTimeout';Message='Previous timeout'};$run=SaveFixture $run
 PollFixture
 $run=BindFixture $run $ref -AttemptOnly
 Check ($run.AccessIssue -and $run.AccessIssue.Kind -ceq 'FirstTrust' -and -not $run.LastError) 'Fast first-trust result is persisted during attempt registration and clears only the obsolete timeout'
 $stored=Get-TCDeploymentRun $script:Root $run.RunId
 Check ($stored.AccessIssue.SessionInstanceId -ceq $ref.InstanceId -and $stored.AccessIssue.Connection.Host -ceq '192.0.2.10' -and $stored.Status -ceq 'WaitingUser') 'First-trust wait survives reload with the exact session and target'
 $decision=Get-TCDeploymentDecision -Run $stored
 Check ($decision.PrimaryAction -ceq 'VerifyIdentity' -and $decision.Title -eq '等待确认服务器身份') 'First trust offers an explicit confirmation action instead of an in-progress claim'
 PollFixture 'Connecting' 'Connecting';$run=BindFixture $run $ref -AttemptOnly
 Check (-not $run.AccessIssue -and -not $run.LastError) 'A real new connection attempt removes the obsolete access issue'
 PollFixture 'ConnectionTimeout';$run=BindFixture $run $ref -AttemptOnly
 Check ($run.AccessIssue.Kind -eq 'Connection' -and $run.LastError.Message -like '*本次尝试已结束*') 'A fast timeout is consumed immediately without waiting for another poll'
 $decision=Get-TCDeploymentDecision -Run $run
 Check ($decision.Title -eq '服务器连接超时' -and $decision.Message -like '*当前没有继续重试*') 'Exhausted timeout says the attempt ended and offers manual retry'
 $run.AccessIssue=$null;$decision=Get-TCDeploymentDecision -Run $run
 Check ($decision.Code -eq 'ServerAccessStopped' -and $decision.Title -notlike '*正在*') 'Legacy PrepareAccess errors without AccessIssue do not claim active work'
 $run=SaveFixture $run;PollFixture 'HostTrustRequired' 'AwaitingTrust';$run=BindFixture $run $ref -AttemptOnly
 Check ($run.AccessIssue.Kind -eq 'FirstTrust' -and -not $run.LastError) 'New AwaitingTrust native status and old Failed status share the same persistent wait'
 $stale=$ref|ConvertTo-Json|ConvertFrom-Json;$stale.InstanceId=[guid]::NewGuid().ToString();$rejected=$false
 try{$null=BindFixture $run $stale}catch{$rejected=$_.Exception.Message -match 'SessionBindingMismatch'}
 Check $rejected 'A late observation from another executor cannot overwrite the current attempt'
 $run.Stage='MaterializeCandidate';$run.Status='Failed';$run.LastError=[pscustomobject]@{Code='CandidateBuildFailed';Message='Preserved local business failure'};$run.AccessIssue=$null;$run=SaveFixture $run
 PollFixture 'Connecting' 'Connecting';$run=BindFixture $run $ref -AttemptOnly
 Check ($run.Stage -eq 'MaterializeCandidate' -and $run.Status -eq 'Failed' -and $run.LastError.Code -ceq 'CandidateBuildFailed') 'Retry registration preserves an unrelated local candidate failure'
 $run.Stage='Reconcile';$run.Status='OutcomeUnknown';$run.RecoveryRequired=$true;$run.LastError=@{Code='DispatchOutcomeUnknown';Message='Unresolved original operation'};$run.LastRemoteMutation=@{IntentId=[guid]::NewGuid().ToString();Mutating=$true;State='Dispatched'};$run=SaveFixture $run
 $unknownId=$run.LastRemoteMutation.IntentId
 $run=BindFixture $run $ref -AttemptOnly;PollFixture;$run=BindFixture $run $ref
 Check ($run.Status -eq 'OutcomeUnknown' -and $run.RecoveryRequired -and $run.Stage -eq 'Reconcile' -and $run.LastError.Code -ceq 'DispatchOutcomeUnknown' -and $run.LastRemoteMutation.IntentId -ceq $unknownId) 'Connecting and trust wait cannot erase the original unknown remote outcome'
 $run.Status='WaitingUser';$run.Stage='PrepareAccess';$run.RecoveryRequired=$false;$run.LastRemoteMutation=$null;$run.LastError=@{Code='ConnectionTimeout';Message='Old failure'};$run=SaveFixture $run
 ResetUiFixture $run $ref;PollFixture
 $credential=$script:DeployUI.Credential
 RegisterDeploymentAccessAttemptUI
 Check ($script:Dialogs -eq 1 -and $script:DeployUI.Run.AccessIssue.Kind -eq 'FirstTrust' -and -not $script:DeployUI.ReconnectMessage -and -not $script:DeployUI.Run.LastError) 'Actual UI callback saves the wait and removes the old error and reconnect banner before opening the dialog'
 $script:Dialog.Visible=$false
 $snapshot=[pscustomobject]@{InstanceId=$ref.InstanceId;Poll=$evidence.Poll}
 ApplyDeploymentSessionSnapshot $snapshot (NewDeploymentCallbackContext -Session)
 ApplyDeploymentSessionSnapshot $snapshot (NewDeploymentCallbackContext -Session)
 Check ($script:Dialogs -eq 1 -and -not $script:Dialog.Visible -and $script:Authentications.Count -eq 0 -and $script:DeployUI.Run.AccessIssue.Kind -eq 'FirstTrust') 'Dismissal keeps a persistent actionable wait without reopening automatically or authenticating'
 Check (-not (DeploymentAccessInProgressUI)) 'First trust is never presented as a running connection'
 InvokeDeploymentDecisionUI 'VerifyIdentity'
 Check ($script:Dialogs -eq 2 -and $script:Dialog.Visible -and $script:IdentityFlows -eq 0 -and $script:Dialog.Body.Contains('192.0.2.10:22')) 'The actual page action reopens first trust for the original target without identity-replacement flow'
 Check ([object]::ReferenceEquals($credential,$script:DeployUI.Credential)) 'Closing and reopening the trust dialog retains the same valid in-memory credential'
 $dialog=$script:Dialog
 $original=$script:DeployUI.Run.AccessIssue.ObservedFingerprint;$script:DeployUI.Run.AccessIssue.ObservedFingerprint='SHA256:'+('B'*43)
 & $dialog.Action $dialog.Context
 Check ($script:Authentications.Count -eq 0 -and $script:Errors.Count -eq 1) 'A changed displayed fingerprint rejects the old confirmation callback'
 $script:DeployUI.Run.AccessIssue.ObservedFingerprint=$original;$script:OverrideHost='192.0.2.20'
 & $dialog.Action $dialog.Context
 Check ($script:Authentications.Count -eq 0 -and $script:Errors.Count -eq 2) 'A changed registry target rejects the old confirmation callback'
 $script:OverrideHost='';$script:ReadOnly=$true;& $dialog.Action $dialog.Context;$script:ReadOnly=$false
 Check ($script:Authentications.Count -eq 0) 'Read-only state reached while the dialog is open prevents authentication'
 $savedRef=$script:DeployUI.SessionRef;$script:DeployUI.SessionRef=$stale;& $dialog.Action $dialog.Context;$script:DeployUI.SessionRef=$savedRef
 Check ($script:Authentications.Count -eq 0 -and $script:Errors.Count -eq 3) 'A newer executor rejects the old confirmation callback'
 $oldFlow=$script:DeployUI;$script:DeployUI=@{Run=$run;SessionRef=$ref};& $dialog.Action $dialog.Context;$script:DeployUI=$oldFlow
 Check ($script:Authentications.Count -eq 0 -and $script:Errors.Count -eq 4) 'A replacement wizard rejects the old confirmation callback'
 $script:Errors.Clear();& $dialog.Action $dialog.Context
 Check ($script:Authentications.Count -eq 1 -and $script:Authentications[0].Pin -ceq $original -and [object]::ReferenceEquals($credential,$script:Authentications[0].Credential)) 'Explicit current confirmation authenticates once with the exact reviewed fingerprint and retained credential'
 Check (-not $script:DeployUI.Run.AccessIssue -and (DeploymentAccessInProgressUI) -and $script:Jobs -notcontains 'DeploymentProceed') 'Accepted confirmation enters actual authentication state without dispatching deployment'
 Check (-not (Get-TCServer $script:Root $run.ServerRecordId).PinnedHostKey) 'Trust preview or submitted authentication does not persist a pin before authenticated evidence'
 PollFixture; $run=BindFixture $script:DeployUI.Run $ref;ResetUiFixture $run $ref
 $script:DeployUI.CredentialExpiresAt=[DateTimeOffset]::UtcNow.AddSeconds(-1);ShowDeploymentFirstTrustUI
 Check ($script:DeployUI.Reauth -and -not $script:DeployUI.Credential -and $script:Dialogs -eq 0 -and $script:Authentications.Count -eq 0) 'Expired credentials return to the same login form with an explanation and no authentication'
 $files=@(Get-ChildItem -LiteralPath $script:Root -Recurse -File)
 $leaks=@($files|Where-Object {([IO.File]::ReadAllText($_.FullName)).Contains('ISOLATED_FIRST_TRUST_SECRET')})
 Check ($leaks.Count -eq 0 -and $evidence.ForbiddenCalls -eq 0) 'No credential enters persistent records and no live server operation is invoked'
 $passed=$true
}catch{$failure=$_.Exception.Message;throw}finally{
 $result=[ordered]@{Passed=$passed;Version=(Get-Content -LiteralPath (Join-Path $PackageRoot 'version.json') -Raw|ConvertFrom-Json).Version;PowerShellVersion=$PSVersionTable.PSVersion.ToString();Checks=$checks.Count;Assertions=$checks.ToArray();Failure=$failure;RealCredentialsRead=0;ProductionWrites=0;LiveServerOperations=0;SourceSHA256=(Get-FileHash -LiteralPath (Join-Path $PackageRoot 'ui\DeploymentPages.ps1')).Hash}
 if($ReportPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($result|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($true))}
 $path=[IO.Path]::GetFullPath($script:Root);$boundary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if($path.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($path) -cmatch '^TC-FirstTrust-[a-f0-9]{32}$' -and (Test-Path -LiteralPath $path)){Remove-Item -LiteralPath $path -Recurse -Force}
}
$result|ConvertTo-Json -Depth 6
