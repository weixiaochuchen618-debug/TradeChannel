#requires -Version 5.1
[CmdletBinding()]param([string]$PackageRoot,[string]$ReportPath)
if(-not $PackageRoot){$PackageRoot=Split-Path $PSScriptRoot -Parent}
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$script:PackageRoot=$PackageRoot
$script:Root='C:\ISOLATED-NO-PRODUCTION-ACCESS'
Import-Module (Join-Path $PackageRoot 'DeploymentTransport.psm1') -DisableNameChecking
. (Join-Path $PackageRoot 'ui\ConnectionProfilePages.ps1')
. (Join-Path $PackageRoot 'ui\DeploymentPages.ps1')
. (Join-Path $PackageRoot 'ui\NavigationContext.ps1')
$script:Dialogs=New-Object 'Collections.Generic.List[object]'
$script:Commands=New-Object 'Collections.Generic.List[object]'
$script:Errors=New-Object 'Collections.Generic.List[string]'
$script:Closed=0
$script:Role='deployment';$script:ReadOnly=$false;$script:Smoke=$false;$script:Controls=@{}
$script:Footer=[pscustomobject]@{Text=''}
$script:ExpectedFingerprint='SHA256:'+('A'*43)
$script:Server=[pscustomobject]@{LocalRecordId=[guid]::NewGuid().ToString();Connection=@{Host='192.0.2.10';Port=22;User='root';IdentityFile=''};PinnedHostKey='';CredentialRef=$null}
$script:RunId=[guid]::NewGuid().ToString()
function NewRef {
 [pscustomobject]@{RunId=$script:RunId;InstanceId=[guid]::NewGuid().ToString();PipeName='FIXTURE-NO-PIPE';ProcessId=999999;StartTimeUtcTicks='1';Root=$script:Root}
}
function NewPoll {param([string]$Code,[string]$Status,[int]$Generation)
 [pscustomobject]@{Code=$Code;Status=$Status;AuthenticationGeneration=$Generation;HasSession=$false;ObservedFingerprint=$script:ExpectedFingerprint}
}
function IsBusy {$false}
function ShowProductDeployment {}
function ErrorDialog {param($Message)$script:Errors.Add([string]$Message)}
function Get-TCServer {param($Root,$Id)if($Root -cne $script:Root -or $Id -cne $script:Server.LocalRecordId){throw 'Unexpected production access'};return $script:Server}
function Import-Module {param($Name,[switch]$DisableNameChecking)
 if([IO.Path]::GetFileName($Name) -notin @('ServerRegistry.psm1','DeploymentTransport.psm1')){throw 'Unexpected import'}
}
function OpenDialog {param($Title,$Body,$Note,$Confirm,$Action,$Cancel,$ConfirmStyle,$Context)
 $script:Dialog=@{Title=$Title;Action=$Action;Context=$Context}
 $script:Dialogs.Add(@{InstanceId=$Context.InstanceId;Fingerprint=$Context.Fingerprint})
}
function CloseUiDeploymentSession {param($SessionRef)$script:Closed++}
function StartJob {param($Request,$Complete,$Message,$Transition,[switch]$Silent,$Failed,$CallbackContext)
 if($Request.Action -ne 'DeploymentAccessState'){throw ('Unexpected actor: '+$Request.Action)}
 $r=$script:DeployUI.Run;$p=$script:Poll
 if($p.Code -eq 'HostTrustRequired'){
  $r.AccessIssue=@{Kind='FirstTrust';Code=$p.Code;SessionInstanceId=$script:DeployUI.SessionRef.InstanceId;AuthenticationGeneration=$p.AuthenticationGeneration;ObservedFingerprint=$script:ExpectedFingerprint;Connection=$script:Server.Connection}
 }elseif($p.Code -eq 'ConnectionTimeout'){
  $r.AccessIssue=@{Kind='Connection';Code=$p.Code;SessionInstanceId=$script:DeployUI.SessionRef.InstanceId;AuthenticationGeneration=$p.AuthenticationGeneration}
 }else{$r.AccessIssue=$null}
 & $Complete $r $CallbackContext
}
function StartUiCommand {param($Module,$Command,$Arguments,$Complete,$Failed,$Context,$Message)
 if($Module -ne 'DeploymentTransport.psm1' -or $Command -notin @('Set-TCDeployCredential','Start-TCDeploySession')){throw ('Unexpected actor: '+$Command)}
 $script:Commands.Add(@{Command=$Command;PinnedFingerprint=[string]$Arguments.PinnedFingerprint;AccessContext=$Arguments.AccessContext})
 if($Command -eq 'Set-TCDeployCredential'){
  $script:Poll=NewPoll 'Connecting' 'Connecting' 2
  & $Complete ([pscustomobject]@{Ok=$true;Status='Connecting'}) $Context
 }else{
  $script:Poll=if($Arguments.PinnedFingerprint){NewPoll 'Connecting' 'Connecting' 1}else{NewPoll 'HostTrustRequired' 'AwaitingTrust' 1}
  & $Complete ([pscustomobject]@{SessionRef=(NewRef)}) $Context
 }
}
$ref=NewRef
$run=@{RunId=$script:RunId;ServerRecordId=$script:Server.LocalRecordId;Stage='PrepareAccess';Status='WaitingUser';AccessIssue=@{Kind='FirstTrust';Code='HostTrustRequired';SessionInstanceId=$ref.InstanceId;AuthenticationGeneration=1;ObservedFingerprint=$script:ExpectedFingerprint;Connection=$script:Server.Connection}}
$script:DeployUI=@{Run=$run;SessionRef=$ref;Credential=@{Kind='Password';Password=(ConvertTo-SecureString 'FAKE-LOCAL-ONLY' -AsPlainText -Force)};CredentialExpiresAt=[DateTimeOffset]::UtcNow.AddMinutes(30);TrustShown=$null;TrustShownInstanceId='';LastAccessSignature='';LastPoll=[DateTime]::MinValue;Reauth=$false;AutomaticLoginRetries=0}
$script:DeployUI.CredentialBinding=DeploymentCredentialScopeUI $script:Server
$script:Poll=NewPoll 'HostTrustRequired' 'AwaitingTrust' 1
$failure='';$evidence=$null
try{
 ShowDeploymentFirstTrustUI -Automatic
 $initialCount=$script:Dialogs.Count
 1..3|ForEach-Object {ApplyDeploymentSessionSnapshot ([pscustomobject]@{InstanceId=$ref.InstanceId;Poll=$script:Poll}) (NewDeploymentCallbackContext -Session)}
 $sameSessionCount=$script:Dialogs.Count
 & $script:Dialog.Action $script:Dialog.Context
 $acceptedPin=$script:Commands[0].PinnedFingerprint
 $afterConfirmation=$script:Dialogs.Count
 $script:Poll=NewPoll 'ConnectionTimeout' 'Failed' 2
 ApplyDeploymentSessionSnapshot ([pscustomobject]@{InstanceId=$ref.InstanceId;Poll=$script:Poll}) (NewDeploymentCallbackContext -Session)
 $retries=@($script:Commands|Where-Object {$_.Command -eq 'Start-TCDeploySession'})
 $reproduced=($initialCount -eq 1 -and $sameSessionCount -eq 1 -and $acceptedPin -ceq $script:ExpectedFingerprint -and $afterConfirmation -eq 1 -and $retries.Count -eq 1 -and $retries[0].PinnedFingerprint -ceq $acceptedPin -and $script:Dialogs.Count -eq 1 -and $script:Errors.Count -eq 0)
 $confirmedContext=$script:Commands[0].AccessContext;$retryContext=$retries[0].AccessContext
 if(-not $confirmedContext.TrustDecisionId -or $retryContext.TrustDecisionId -cne $confirmedContext.TrustDecisionId -or $retryContext.TrustOrigin -cne 'ExplicitUserConfirmation' -or $retryContext.RetryReason -cne 'ConnectionTimeout' -or $retryContext.RetryCount -ne 1 -or $retryContext.PriorInstanceId -cne $ref.InstanceId){throw 'Explicit decision and reconnect cause must reach the diagnostic request context without changing authorization'}
 $evidence=[ordered]@{Passed=$reproduced;Version=(Get-Content -LiteralPath (Join-Path $PackageRoot 'version.json') -Raw -Encoding UTF8|ConvertFrom-Json).Version;SourceSHA256=(Get-FileHash -LiteralPath (Join-Path $PackageRoot 'ui\DeploymentPages.ps1')).Hash;InitialDialogCount=$initialCount;AfterThreeDuplicatePolls=$sameSessionCount;AfterExplicitConfirmation=$afterConfirmation;ConfirmedFingerprint=$acceptedPin;RetryCount=$retries.Count;RetryPinnedFingerprint=$retries[0].PinnedFingerprint;FinalDialogCount=$script:Dialogs.Count;DialogFingerprints=@($script:Dialogs|ForEach-Object {$_.Fingerprint});DifferentExecutor=($ref.InstanceId -cne $script:DeployUI.SessionRef.InstanceId);AutomaticLoginRetries=$script:DeployUI.AutomaticLoginRetries;MockedBoundaries=@('IsBusy','OpenDialog','StartJob','StartUiCommand','Get-TCServer','CloseUiDeploymentSession');RealCallbacks=@('ShowDeploymentFirstTrustUI','ApplyDeploymentSessionSnapshot','RetryDeploymentConnectionUI','UseDeploymentRetryCredentialUI','StartDeploymentSessionUI');InjectedFailure='ConnectionTimeout after explicit trust before authentication';HistoricalFailureProven=$false;RemoteCommands=0;ActualSshConnections=0;UserSecretsRead=0;ProductionWrites=0;Errors=$script:Errors.ToArray()}
 $evidence.AccessContext=$retryContext;$evidence.ConfirmedAccessContext=$confirmedContext
 if(-not $reproduced){throw 'Confirmed trust was lost when executor changed'}
}catch{$failure=$_.Exception.GetType().FullName;if(-not $evidence){$evidence=@{Reproduced=$false;FailureType=$failure;RemoteCommands=0;ProductionWrites=0}}}finally{
 if($ReportPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($evidence|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($true))}
}
$evidence|ConvertTo-Json -Depth 6
if($failure){exit 1}
