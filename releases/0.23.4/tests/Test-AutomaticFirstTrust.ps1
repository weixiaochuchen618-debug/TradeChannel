#requires -Version 5.1
[CmdletBinding()]param([string]$PackageRoot,[string]$ReportPath)
$ErrorActionPreference='Stop';$env:PSModulePath=Join-Path $PSHOME 'Modules'
if(-not $PackageRoot){$PackageRoot=Split-Path $PSScriptRoot -Parent}
$script:PackageRoot=[IO.Path]::GetFullPath($PackageRoot)
$script:Root=Join-Path ([IO.Path]::GetTempPath()) ('TC-AutoTrust-'+[guid]::NewGuid().ToString('N'))
$flow=Import-Module (Join-Path $PackageRoot 'DeploymentFlow.psm1') -PassThru -DisableNameChecking
$registry=Import-Module (Join-Path $PackageRoot 'ServerRegistry.psm1') -PassThru -DisableNameChecking
$null=Import-Module (Join-Path $PackageRoot 'DeploymentTransport.psm1') -DisableNameChecking
$null=Import-Module (Join-Path $PackageRoot 'UserSettings.psm1') -DisableNameChecking
$transportModule=Get-Module DeploymentTransport
$trustModule=Import-Module (Join-Path $PackageRoot 'DeploymentTrust.psm1') -PassThru -DisableNameChecking
$null=Import-Module (Join-Path $PackageRoot 'DeploymentDecision.psm1') -DisableNameChecking
. (Join-Path $PackageRoot 'ui\ConnectionProfilePages.ps1')
. (Join-Path $PackageRoot 'ui\NavigationContext.ps1')
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
 $script:Authentications.Add(@{AccessContext=$Arguments.AccessContext;Pin=$Arguments.PinnedFingerprint;Host=$Arguments.Connection.Host;Credential=$Arguments.Credential;SessionRef=$Arguments.SessionRef})
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
 $script:Page='setup';$script:Role='deployment';$script:ReadOnly=$false;$script:Smoke=$false;$script:Job=$null;$script:Controls=@{};$script:Footer=[pscustomobject]@{Text=''}
 $script:Dialogs=0;$script:Renders=0;$script:IdentityFlows=0;$script:OverrideHost=''
 $script:Jobs=New-Object 'Collections.Generic.List[string]';$script:Errors=New-Object 'Collections.Generic.List[string]';$script:Authentications=New-Object 'Collections.Generic.List[object]'
 $script:DeployUI=@{Run=$Run;SessionRef=$Ref;SessionAttached=$false;Credential=@{Kind='Password';Password=(ConvertTo-SecureString 'ISOLATED_FIRST_TRUST_SECRET' -AsPlainText -Force)};CredentialExpiresAt=[DateTimeOffset]::UtcNow.AddMinutes(30);TrustShown=$null;TrustShownInstanceId='';LastAccessSignature='';LastPoll=[DateTime]::MinValue;ReconnectMessage='正在恢复服务器连接';PollError='';WorkerFailure=$null;AutomaticLoginRetries=2;Reauth=$false}
 $script:DeployUI.CredentialBinding=DeploymentCredentialScopeUI (Get-TCServer $script:Root $Run.ServerRecordId)
}
function Toast {param([string]$Message)$script:Toasts.Add($Message)}
$passed=$false;$failure=''
try{
 $script:Toasts=New-Object 'Collections.Generic.List[string]'
 $run=New-TCDeploymentRun -Root $script:Root -Connection @{Host='192.0.2.10';Port=22;User='root';IdentityFile=''} -Name 'Automatic trust fixture'
 $ref=[pscustomobject]@{RunId=$run.RunId;InstanceId=[guid]::NewGuid().ToString();PipeName=('TCDeploy-'+[guid]::NewGuid().ToString('N'));ProcessId=999999;StartTimeUtcTicks='123';Root=(Join-Path $script:Root 'fixture-session')}
 $run=SaveFixture $run;PollFixture
 $run=BindFixture $run $ref -AttemptOnly
 $settings=Get-TCUserSettings -Root $script:Root
 Check ($settings.AutoTrustFirstConnection -eq $true -and $settings.AutoConnectOnLogin -eq $false -and $settings.Source -ceq 'Default') 'Defaults remember a first-seen identity automatically and never reconnect after login'
 ResetUiFixture $run $ref;PollFixture
 $fingerprint='SHA256:'+('A'*43)
 RegisterDeploymentAccessAttemptUI
 Check ($script:Dialogs -eq 0 -and $script:Authentications.Count -eq 1 -and $script:Authentications[0].Pin -ceq $fingerprint) 'Default setting authenticates once with the exact observed fingerprint and shows no dialog'
 Check ($script:Toasts.Count -eq 1 -and $script:Toasts[0] -like '*已记住*' -and $script:Toasts[0] -like '*SHA256:AAAAAAAA*') 'The remembered identity is shown to the user'
 $decision=$script:DeploymentTrustDecisions[[string]$script:DeployUI.Run.RunId]
 Check ($decision -and $decision.Origin -ceq 'AutomaticFirstUse' -and $decision.Fingerprint -ceq $fingerprint) 'The decision is recorded honestly as automatic, not as an explicit confirmation'
 $context=$script:Authentications[0].AccessContext
 Check ($context.TrustOrigin -ceq 'AutomaticFirstUse' -and $context.TrustDecisionId -ceq $decision.TrustDecisionId) 'The access context carries the automatic origin'
 $accepted=$true;try{$null=& $transportModule {param($v)ConvertTo-TCDeployAccessContext $v} $context}catch{$accepted=$false}
 Check $accepted 'Transport validation accepts the automatic origin'
 $forged=@{TrustDecisionId=$decision.TrustDecisionId;TrustOrigin='Bogus';RetryReason='InitialAttempt';RetryCount=0;PriorInstanceId=''};$rejected=$false
 try{$null=& $transportModule {param($v)ConvertTo-TCDeployAccessContext $v} $forged}catch{$rejected=$true}
 Check $rejected 'An unknown origin is still rejected'
 $server=Get-TCServer $script:Root $run.ServerRecordId
 Check (-not $server.PinnedHostKey) 'Nothing is pinned until authentication succeeds'
 Check ((& $trustModule {param($d,$r,$s,$c)Test-TCFirstTrustDecision $d $r $s $c} $decision $run.RunId $run.ServerRecordId $server.Connection)) 'The automatic decision is valid for the same run, server and target'
 $other=@{Host='192.0.2.99';Port=22;User='root'}
 Check (-not (& $trustModule {param($d,$r,$s,$c)Test-TCFirstTrustDecision $d $r $s $c} $decision $run.RunId $run.ServerRecordId $other)) 'The automatic decision cannot be used for another target'
 $null=Set-TCUserSetting -Root $script:Root -Name AutoTrustFirstConnection -Value $false
 $run2=New-TCDeploymentRun -Root $script:Root -Connection @{Host='192.0.2.11';Port=22;User='root';IdentityFile=''} -Name 'Manual trust fixture'
 $ref2=[pscustomobject]@{RunId=$run2.RunId;InstanceId=[guid]::NewGuid().ToString();PipeName=('TCDeploy-'+[guid]::NewGuid().ToString('N'));ProcessId=999999;StartTimeUtcTicks='124';Root=(Join-Path $script:Root 'fixture-session2')}
 $run2=SaveFixture $run2;PollFixture;$run2=BindFixture $run2 $ref2 -AttemptOnly
 ResetUiFixture $run2 $ref2;PollFixture;$script:Toasts.Clear()
 RegisterDeploymentAccessAttemptUI
 Check ($script:Dialogs -eq 1 -and $script:Authentications.Count -eq 0 -and $script:Toasts.Count -eq 0) 'Turning the setting off restores the explicit confirmation dialog'
 Check ((Get-TCUserSettings -Root $script:Root).AutoTrustFirstConnection -eq $false) 'The switch persists'
 [IO.File]::WriteAllText((Join-Path $script:Root 'ui-settings.json'),'{"AutoTrustFirstConnection":"yes"}')
 $bad=Get-TCUserSettings -Root $script:Root
 Check ($bad.Source -ceq 'Corrupt' -and $bad.AutoTrustFirstConnection -eq $true -and $bad.AutoConnectOnLogin -eq $false -and $bad.Warning) 'A malformed settings file falls back to defaults with a warning and is left in place'
 Check ($evidence.ForbiddenCalls -eq 0) 'No live server operation is invoked'
 $passed=$true
}catch{$failure=$_.Exception.Message;throw}finally{
 $result=[ordered]@{Passed=$passed;Version=(Get-Content -LiteralPath (Join-Path $PackageRoot 'version.json') -Raw|ConvertFrom-Json).Version;Checks=$checks.Count;Assertions=$checks.ToArray();Failure=$failure}
 if($ReportPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($result|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($true))}
 $path=[IO.Path]::GetFullPath($script:Root);$boundary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('')+''
 if($path.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($path) -cmatch '^TC-AutoTrust-[a-f0-9]{32}$' -and (Test-Path -LiteralPath $path)){Remove-Item -LiteralPath $path -Recurse -Force}
}
$result|ConvertTo-Json -Depth 6
