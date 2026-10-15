#requires -Version 5.1
[CmdletBinding()]param([string]$ReportPath)
$ErrorActionPreference='Stop';$env:PSModulePath=Join-Path $PSHOME 'Modules'
$script:PackageRoot=Split-Path $PSScriptRoot -Parent
$script:Root=Join-Path ([IO.Path]::GetTempPath()) ('TC-Reconnect-'+[guid]::NewGuid().ToString('N'))
$transport=Import-Module (Join-Path $script:PackageRoot 'DeploymentTransport.psm1') -PassThru -DisableNameChecking
. (Join-Path $script:PackageRoot 'ui/ConnectionProfilePages.ps1')
. (Join-Path $script:PackageRoot 'ui/DeploymentPages.ps1')
$script:Checks=New-Object 'Collections.Generic.List[string]'
$script:Calls=New-Object 'Collections.Generic.List[string]'
function Check {param([bool]$Ok,[string]$Name)if(-not $Ok){throw $Name};$script:Checks.Add($Name)}
# Only I/O leaves are fixtures. The real poller, classification, credential
# lifetime/binding, retry budget and UI action functions execute unchanged.
function Import-Module {param($Name,[switch]$DisableNameChecking)if([IO.Path]::GetFileName($Name) -notin @('DeploymentTransport.psm1','ServerRegistry.psm1','DeploymentFlow.psm1')){throw 'Unexpected module load in fixture'}}
function Get-TCServer {param($Root,$Id)if($Id -cne $script:Server.LocalRecordId){throw 'Wrong fixture server'};$script:Server}
function Get-TCDeploySavedCredential {param($Root,$CredentialRef)$script:Calls.Add('DecryptSaved');@{Kind='Password';Password=(ConvertTo-SecureString 'ISOLATED_SAVED_SECRET' -AsPlainText -Force)}}
function Start-TCDeploySession {param($Root,$RunId,$Connection,$Credential,$PinnedFingerprint)
 Check ([object]::ReferenceEquals($Credential,$script:DeployUI.Credential)) 'Executor receives the retained in-memory credential'
 Check ($Connection.Host -ceq $script:Server.Connection.Host -and $PinnedFingerprint -ceq $script:Server.PinnedHostKey) 'Executor retains exact target and trusted pin'
 $script:Calls.Add('StartSession');[pscustomobject]@{SessionRef=[pscustomobject]@{InstanceId=[guid]::NewGuid().ToString('D');RunId=$RunId}}
}
function Stop-TCDeploySession {param($SessionRef)$script:Calls.Add('CloseFailedSession')}
function Get-TCDeploySession {param($SessionRef)$script:Poll}
function Set-TCServerRecord {param($Root,$Id,$PinnedFingerprint,$SessionRef,$CredentialRef)$script:Calls.Add('RecordVerifiedIdentity')}
function IsBusy {$false}
function ShowProductDeployment {$script:Calls.Add('Render')}
function CaptureNavigationContext {$null}
function ErrorDialog {param($Message)throw ('Unexpected error dialog: '+$Message)}
function OpenDialog {throw 'Unexpected trust dialog'}
function StartJob {param($Request,$Complete,$Message,$Transition,[switch]$Silent,$Failed)
 $script:Calls.Add([string]$Request.Action)
 $run=$script:DeployUI.Run
 switch($Request.Action){
  'DeploymentAccessState'{
   if($Request.AttemptOnly){$run.AccessIssue=$null}else{$diag=Get-TCDeployAccessDiagnostic -Code $script:Poll.Code;$run.AccessIssue=[pscustomobject]@{Kind=$diag.Kind;Code=$diag.Code};if($script:Poll.Status -eq 'OutcomeUnknown'){$run.Stage='Reconcile';$run.RecoveryRequired=$true}}
  }
  'DeploymentAttach'{$run.AccessIssue=$null}
  'DeploymentProceed'{}
  'DeploymentPoll'{}
  'DeploymentGet'{}
  'DeploymentDiscover'{}
  default{throw ('Unexpected actor request '+$Request.Action)}
 }
 if($script:Defer){$script:Deferred=$Complete;return}
 & $Complete $run
}
function ResetFixture {
 $script:Calls.Clear();$script:Defer=$false;$script:Deferred=$null
 $script:Server=[pscustomobject]@{LocalRecordId='fixture-server';Connection=[pscustomobject]@{Host='192.0.2.10';Port=22;User='root'};PinnedHostKey=('SHA256:'+('A'*43));CredentialRef=$null}
 $run=[pscustomobject]@{RunId='fixture-run';ServerRecordId='fixture-server';Stage='TcpPlan';Status='Running';AccessIssue=$null;RecoveryRequired=$false}
 $script:DeployUI=@{Run=$run;SessionRef=[pscustomobject]@{RunId=$run.RunId;InstanceId='old-session'};SessionAttached=$true;Credential=@{Kind='Password';Password=(ConvertTo-SecureString 'ISOLATED_MEMORY_SECRET' -AsPlainText -Force)};CredentialExpiresAt=[DateTimeOffset]::UtcNow.AddMinutes(30);CredentialFresh=$true;AutomaticLoginRetries=0;LastAccessSignature='';LastPoll=[DateTime]::MinValue;RememberCredential=$false;Reauth=$false}
 $script:DeployUI.CredentialBinding=DeploymentCredentialScopeUI $script:Server
 $script:Poll=[pscustomobject]@{Status='Failed';Code='WaitResult_SshConnectionException';HasSession=$false;ObservedFingerprint=$script:Server.PinnedHostKey}
 $script:Role='deployment';$script:ReadOnly=$false;$script:Smoke=$false;$script:Job=$null
}
function PollFixture {$script:DeployUI.LastPoll=[DateTime]::MinValue;PollProductDeployment}
ResetFixture
$originalCredential=$script:DeployUI.Credential
PollFixture
Check ($script:DeployUI.AutomaticLoginRetries -eq 1 -and -not $script:DeployUI.Reauth -and [object]::ReferenceEquals($originalCredential,$script:DeployUI.Credential)) 'First dropped connection reuses credential without login form'
PollFixture
Check ($script:DeployUI.AutomaticLoginRetries -eq 2 -and -not $script:DeployUI.Reauth) 'Second dropped connection stays inside bounded automatic recovery'
PollFixture
Check (@($script:Calls|Where-Object {$_ -eq 'StartSession'}).Count -eq 2 -and $script:DeployUI.Run.AccessIssue.Kind -eq 'Connection') 'Third failure stops automatic retries and retains a connection issue'
$null=RetryDeploymentConnectionUI
Check (@($script:Calls|Where-Object {$_ -eq 'StartSession'}).Count -eq 3 -and -not $script:DeployUI.Reauth) 'Explicit retry reconnects with retained credentials'
ResetFixture;$script:Poll.Status='OutcomeUnknown';PollFixture
Check ($script:DeployUI.Run.RecoveryRequired -and $script:DeployUI.Run.Stage -eq 'Reconcile' -and $script:Calls -notcontains 'DeploymentProceed') 'Unknown write outcome is recorded before reconnect; no repeated deployment is dispatched'
foreach($code in @('AuthenticationFailed','AuthenticationRejected','PrivateKeyParseFailed','PrivateKeyPassphraseRequired','InvalidCredential')){
 ResetFixture;$script:Poll.Code=$code;PollFixture
 Check (-not $script:DeployUI.Credential -and $script:Calls -notcontains 'StartSession') ($code+' invalidates credentials without an automatic password retry')
}
ResetFixture;$script:Poll.Code='HostKeyChanged';PollFixture
Check ($script:Calls -notcontains 'StartSession' -and $script:DeployUI.Run.AccessIssue.Kind -eq 'IdentityChanged') 'Changed fingerprint is not automatically trusted'
ResetFixture;$script:Poll.Code='BackendUnexpected';PollFixture
Check ($script:Calls -notcontains 'StartSession' -and $script:DeployUI.Credential -and $script:DeployUI.Run.AccessIssue.Kind -eq 'Unknown') 'Unknown errors do not become password errors'
ResetFixture;$script:Poll.HasSession=$true;$script:Poll.Code='RemotePrerequisiteMissing';PollFixture
Check ($script:Calls -contains 'DeploymentPoll' -and $script:Calls -notcontains 'StartSession' -and $script:DeployUI.Credential) 'Remote prerequisite failure with live SSH stays in deployment result handling'
ResetFixture;$script:DeployUI.CredentialExpiresAt=[DateTimeOffset]::UtcNow.AddSeconds(-1)
$null=RetryDeploymentConnectionUI
Check (-not $script:DeployUI.Credential -and $script:DeployUI.Reauth -and $script:Calls -notcontains 'StartSession') 'Expired memory without saved credentials requests login on explicit retry'
ResetFixture;ClearDeploymentCredentialUI;$script:Server.CredentialRef='saved-fixture'
$null=RetryDeploymentConnectionUI
Check ($script:Calls -contains 'DecryptSaved' -and $script:Calls -contains 'StartSession' -and -not $script:DeployUI.Reauth) 'Previously encrypted credential can restore the same trusted server'
foreach($change in @('Host','User','PinnedFingerprint','RunId')){
 ResetFixture
 switch($change){'Host'{$script:Server.Connection.Host='192.0.2.20'}'User'{$script:Server.Connection.User='admin'}'PinnedFingerprint'{$script:Server.PinnedHostKey='SHA256:'+('B'*43)}'RunId'{$script:DeployUI.Run.RunId='other-run'}}
 $script:Server.CredentialRef='saved-fixture';$null=RetryDeploymentConnectionUI
 Check ($script:Calls -notcontains 'StartSession' -and $script:Calls -notcontains 'DecryptSaved' -and $script:DeployUI.Reauth) ($change+' change cannot borrow a prior run credential or saved replacement')
}
ResetFixture;$script:ReadOnly=$true;$null=RetryDeploymentConnectionUI
Check ($script:Calls -notcontains 'StartSession') 'Read-only windows never reconnect'
ResetFixture;$script:Defer=$true;PollFixture;$script:Role='client';$script:Defer=$false;ClearDeploymentCredentialUI;& $script:Deferred $script:DeployUI.Run
Check ($script:Calls -notcontains 'StartSession' -and -not $script:DeployUI.Credential) 'Late failure callback after leaving cannot reconnect or retain a secret'
ResetFixture;$script:DeployUI.Run.Stage='ReadyInactive';$script:DeployUI.Run.Status='Complete';PollFixture
Check (-not $script:DeployUI.Credential -and -not $script:DeployUI.CredentialBinding) 'Completed preparation clears the in-memory credential and target binding'
ResetFixture;ClearDeploymentCredentialUI;$script:Server.CredentialRef='saved-fixture';$script:DeployUI.SessionAttached=$false
ResumeProductDeployment $script:DeployUI.Run.RunId
Check ($script:DeployUI.Reauth -and $script:Calls -contains 'Render' -and $script:Calls -notcontains 'DecryptSaved' -and $script:Calls -notcontains 'StartSession' -and $script:Calls -notcontains 'DeploymentAttach' -and $script:Calls -notcontains 'DeploymentProceed') 'Opening an interrupted run never logs in or continues remote steps by itself'
ResetFixture;$script:DeployUI.SessionAttached=$false;$script:DeployUI.AutomaticLoginRetries=2
ResumeProductDeployment $script:DeployUI.Run.RunId
Check ($script:DeployUI.AutomaticLoginRetries -eq 0) 'Opening a run restores the bounded automatic reconnect budget'
ResetFixture;ClearDeploymentCredentialUI;$script:Server.CredentialRef='saved-fixture';$script:DeployUI.SessionAttached=$false
ResumeProductDeployment $script:DeployUI.Run.RunId
$null=RetryDeploymentConnectionUI
Check ($script:Calls -contains 'DecryptSaved' -and $script:Calls -contains 'StartSession' -and -not $script:DeployUI.Reauth) 'Explicit retry after opening a run reuses the saved credential'
$result=[pscustomobject]@{Passed=$true;PowerShellVersion=$PSVersionTable.PSVersion.ToString();Checks=$script:Checks.Count;Assertions=$script:Checks.ToArray();RemoteOperations=0;RealCredentialsRead=0;FixtureOnly=$true}
if($ReportPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($result|ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($true)))}
$result|ConvertTo-Json -Depth 5
