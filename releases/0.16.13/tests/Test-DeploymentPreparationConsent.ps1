#requires -Version 5.1
#requires -PSEdition Desktop
[CmdletBinding()]param([string]$PackageRoot,[string]$ReportPath)
$ErrorActionPreference='Stop';if(-not $PackageRoot){$PackageRoot=Split-Path $PSScriptRoot -Parent};$script:PackageRoot=$PackageRoot
. (Join-Path $PackageRoot 'ui\ConnectionProfilePages.ps1')
. (Join-Path $PackageRoot 'ui\DeploymentPages.ps1')
$script:Approvals=New-Object 'Collections.Generic.List[string]';$checks=New-Object 'Collections.Generic.List[string]'
function IsBusy {$script:FixtureBusy}
function AdvanceDeploymentUI {param([string]$Command)if($Command -cne 'Approve'){throw 'Unexpected advancement'};$script:Approvals.Add([string]$script:DeployUI.Run.Review.ChangeDigest)}
function Check {param([bool]$Ok,[string]$Message)if(-not $Ok){throw $Message};$checks.Add($Message)}
function ResetFixture {
 $script:ReadOnly=$false;$script:Role='deployment';$script:Approvals.Clear();$script:FixtureBusy=$false;$script:Smoke=$false;$script:Job=$null
 $runId=[guid]::NewGuid().ToString();$serverId=[guid]::NewGuid().ToString();$fingerprint='SHA256:'+('A'*43)
 $connection=@{Host='192.0.2.10';User='root';Port=22}
 $run=[pscustomobject]@{RunId=$runId;ServerRecordId=$serverId;Stage='PlanReady';Status='WaitingUser';RecoveryRequired=$false;AccessIssue=$null;TcpPort=443;ServerName='www.bing.com';Transport='Auto';Review=@{Kind='Deploy';TargetIdentity=@{Connection=$connection;PinnedHostKey=$fingerprint};ChangesLocalNetwork=$false;ChangeDigest=('A'*64)}}
 $script:DeployUI=@{Run=$run;SessionAttached=$true;Reauth=$false;LastPoll=[DateTime]::MinValue;PreparationConsent=@{Host='192.0.2.10';Port=22;User='root';RunId=$runId;ServerRecordId=$serverId;PinnedFingerprint=$fingerprint;TcpPort=443;ServerName='www.bing.com';Transport='Auto';Scope='PrepareUdpTcpAndLocalDevice';SubmittedAtUtc=[DateTimeOffset]::UtcNow;ConsumedDigests=@()}}
}
$passed=$false;$failure=''
try{
 ResetFixture
 Check (ContinueDeploymentPreparationUI) 'The explicitly submitted normal deployment continues without a second click'
 Check (-not (ContinueDeploymentPreparationUI) -and $script:Approvals.Count -eq 1) 'Repeating the same review cannot dispatch approval twice'
 ResetFixture;$script:FixtureBusy=$true
 Check (-not (ContinueDeploymentPreparationUI) -and $script:Approvals.Count -eq 0) 'An in-flight UI command defers automatic advancement without consuming approval'
 $script:FixtureBusy=$false;PollProductDeployment
 Check ($script:Approvals.Count -eq 1) 'The next idle polling turn continues a deferred approved preparation'
 $script:DeployUI.LastPoll=[DateTime]::MinValue;PollProductDeployment
 Check ($script:Approvals.Count -eq 1) 'Idle polling cannot approve the same digest again'
 foreach($kind in @('Management','Authorize','PrepareTcp')){ResetFixture;$script:DeployUI.Run.Review.Kind=$kind;Check (ContinueDeploymentPreparationUI) ('The original preparation scope includes '+$kind)}
 $mutations=@{
  Target={ $script:DeployUI.Run.Review.TargetIdentity.Connection.Host='192.0.2.11' }
  Account={ $script:DeployUI.Run.Review.TargetIdentity.Connection.User='another' }
  Port={ $script:DeployUI.Run.Review.TargetIdentity.Connection.Port=2222 }
  Fingerprint={ $script:DeployUI.Run.Review.TargetIdentity.PinnedHostKey='SHA256:'+('B'*43) }
  Run={ $script:DeployUI.Run.RunId=[guid]::NewGuid().ToString() }
  Server={ $script:DeployUI.Run.ServerRecordId=[guid]::NewGuid().ToString() }
  Parameters={ $script:DeployUI.Run.ServerName='changed.example' }
  LocalNetwork={ $script:DeployUI.Run.Review.ChangesLocalNetwork=$true }
  UnsupportedScope={ $script:DeployUI.Run.Review.Kind='Uninstall' }
  Recovery={ $script:DeployUI.Run.RecoveryRequired=$true }
  IdentityWait={ $script:DeployUI.Run.AccessIssue=@{Kind='IdentityChanged'} }
  Paused={ $script:DeployUI.PauseAtCheckpoint=$true }
  Editing={ $script:DeployUI.Reauth=$true }
  Expired={ $script:DeployUI.PreparationConsent.SubmittedAtUtc=[DateTimeOffset]::UtcNow.AddDays(-2) }
  ReadOnly={ $script:ReadOnly=$true }
  LeftPage={ $script:Role='client' }
  NoSubmission={ $script:DeployUI.PreparationConsent=$null }
 }
 foreach($name in @($mutations.Keys|Sort-Object)){ResetFixture;& $mutations[$name];Check (-not (ContinueDeploymentPreparationUI) -and $script:Approvals.Count -eq 0) ('Changed or absent approval remains explicit: '+$name)}
 $passed=$true
}catch{$failure=$_.Exception.Message;throw}
finally{
 $result=[pscustomobject]@{Passed=$passed;Count=$checks.Count;Checks=@($checks.ToArray());Failure=$failure;RemoteOperations=0}
 if($ReportPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($result|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($true))}
 $result|Select-Object Passed,Count,Failure|ConvertTo-Json
}
