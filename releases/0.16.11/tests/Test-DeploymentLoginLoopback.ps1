#requires -Version 5.1
#requires -PSEdition Desktop
[CmdletBinding()]param([string]$PackageRoot,[string]$ReportPath,[switch]$ExpectLegacyInputLoss)
$ErrorActionPreference='Stop';$env:PSModulePath=Join-Path $PSHOME 'Modules'
if(-not $PackageRoot){$PackageRoot=Split-Path $PSScriptRoot -Parent}
$PackageRoot=[IO.Path]::GetFullPath($PackageRoot)
if(-not $ReportPath){$ReportPath=Join-Path ([IO.Path]::GetTempPath()) ('tc-login-loopback-'+[guid]::NewGuid().ToString('N')+'.json')}
$ReportPath=[IO.Path]::GetFullPath($ReportPath)
$reportDirectory=[IO.Path]::GetDirectoryName($ReportPath)
$harness=[IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\ui\Test-015UI.ps1'),[Text.Encoding]::UTF8)
$preambleEnd=$harness.IndexOf('$passed=$false;$failure=''''',$harness.IndexOf('function SelectHistoryFilter'))
$setupStart=$harness.IndexOf(" ImportNamedPresentation 'TradeChannel.ps1'")
$setupEnd=$harness.IndexOf(" ResetUI;ShowSetup;Shot '015-01-single-add-line'")
if($preambleEnd -lt 0 -or $setupStart -lt $preambleEnd -or $setupEnd -lt $setupStart){throw 'WPF fixture initialization boundaries changed'}
. ([scriptblock]::Create($harness.Substring(0,$preambleEnd))) -SourceDirectory $PackageRoot -TestOutputDirectory $reportDirectory
$passed=$false;$failure='';$failureCode='';$legacyReproduced=$false;$fixtureProcess=$null
$script:LoopbackSessions=New-Object 'Collections.Generic.List[object]'
$script:LoopbackStartedProcesses=New-Object 'Collections.Generic.List[object]'
$script:LoopbackRunIds=New-Object 'Collections.Generic.List[string]'
$script:LoopbackUiCommands=New-Object 'Collections.Generic.List[string]'
$script:LoopbackEdits=New-Object 'Collections.Generic.List[object]'
$script:LoopbackAttachIntercepted=$false;$script:LoopbackFirstPoll=$null;$script:LoopbackFinalPoll=$null
$script:LoopbackExpectedPassword='TC_Identity_Local_Fixture_Only!'
$script:LoopbackWrongPassword='TC_Identity_Deliberately_Wrong!'
$script:LoopbackTarget=$null;$script:LoopbackTransport=$null;$script:LoopbackFlow=$null;$script:LoopbackRegistry=$null

function Assert-LoopbackArguments {param([hashtable]$Arguments)
 if([string]$Arguments.Root -cne $script:Root){throw 'Loopback request escaped the owned fixture root'}
 if($Arguments.ContainsKey('Connection')){
  if([string]$Arguments.Connection.Host -cne '127.0.0.1' -or [int]$Arguments.Connection.Port -ne [int]$script:LoopbackTarget.Port -or [string]$Arguments.Connection.User -cne 'root'){throw 'Loopback request escaped the generated SSH endpoint'}
 }
}
function Get-LoopbackPoll {param($SessionRef)
 if(-not @($script:LoopbackSessions|Where-Object {$_.InstanceId -ceq $SessionRef.InstanceId -and $_.ProcessId -eq $SessionRef.ProcessId}).Count){throw 'Unknown fixture executor'}
 return (& $script:LoopbackTransport {param($Ref) Get-TCDeploySession -SessionRef $Ref} $SessionRef)
}
function Wait-LoopbackAuthentication {param($SessionRef)
 $deadline=[DateTime]::UtcNow.AddSeconds(15)
 do{$poll=Get-LoopbackPoll $SessionRef;if($poll.Status -notin @('Connecting','Starting')){return $poll};Start-Sleep -Milliseconds 25}while([DateTime]::UtcNow -lt $deadline)
 throw 'Loopback authentication deadline expired'
}
function CloseUiDeploymentSession {param($SessionRef)
 if(-not $SessionRef){return}
 if(-not @($script:LoopbackSessions|Where-Object InstanceId -CEQ $SessionRef.InstanceId).Count){throw 'Refusing to close a nonfixture executor'}
 & $script:LoopbackTransport {param($Ref) $null=Stop-TCDeploySession -SessionRef $Ref} $SessionRef
}
function StartUiCommand {param([string]$Module,[string]$Command,[hashtable]$Arguments,$Context,[scriptblock]$Complete,[scriptblock]$Failed,[string]$Message)
 Assert-LoopbackArguments $Arguments
 $script:LoopbackUiCommands.Add($Module+'/'+$Command)
 if($Module -ceq 'DeploymentTransport.psm1' -and $Command -ceq 'Start-TCDeploySession'){
  $started=& $script:LoopbackTransport {param($p) Start-TCDeploySession @p} $Arguments
  $script:LoopbackSessions.Add($started.SessionRef)
  & $Complete $started $Context
  return
 }
 if($Module -ceq 'ServerRegistry.psm1' -and $Command -ceq 'Set-TCServerRecord'){
  $server=& $script:LoopbackRegistry {param($p) Set-TCServerRecord @p} $Arguments
  & $Complete $server $Context
  return
 }
 $script:DeniedActors.Add('StartUiCommand/'+$Module+'/'+$Command)
 throw 'Only actual isolated authentication and host identity recording are allowed'
}
function StartJob {param([hashtable]$Request,[scriptblock]$Complete,[string]$Message='',[string]$Transition='',[switch]$Silent,[scriptblock]$Failed=$null,$CallbackContext=$null)
 $serialized=ConvertTo-Json -InputObject $Request -Depth 20 -Compress
 if($serialized.Contains($script:LoopbackExpectedPassword) -or $serialized.Contains($script:LoopbackWrongPassword) -or $Request.ContainsKey('Credential')){throw 'A login secret entered the file-worker request'}
 $entry=[pscustomobject]@{Request=$Request.Clone();Complete=$Complete;Failed=$Failed;CallbackContext=$CallbackContext;Delivered=$false}
 $script:Requests.Add($entry);$script:AllRequests.Add($entry.Request)
 switch -Exact ([string]$Request.Action){
  'DeploymentCreate'{
   $arguments=$Request.Clone();$arguments.Remove('Action');$arguments.Root=$script:Root;Assert-LoopbackArguments $arguments
   $data=& $script:LoopbackFlow {param($p) New-TCDeploymentRun @p} $arguments
   $script:LoopbackRunIds.Add([string]$data.RunId)
   # The generated localhost fixture owns this key. Seed that explicit pin so
   # this journey isolates password retry instead of first-host trust.
   $server=& $script:LoopbackRegistry {param($r,$id,$pin) Set-TCServerRecord -Root $r -Id $id -PinnedFingerprint $pin} $script:Root $data.ServerRecordId ([string]$script:LoopbackTarget.Fingerprint)
   $script:DeployUI.Discovery=@{Servers=@($server)};$script:DeployUI.ServerId=$data.ServerRecordId
  }
  'DeploymentAccessState'{
   $arguments=@{Root=$script:Root;RunId=$Request.RunId;SessionRef=$Request.SessionRef;AttemptOnly=[bool]$Request.AttemptOnly}
   $data=& $script:LoopbackFlow {param($p) Set-TCDeploymentAccessState @p} $arguments
  }
  'DeploymentSessionSnapshot'{
   $data=[pscustomobject]@{InstanceId=$Request.SessionRef.InstanceId;Poll=(Get-LoopbackPoll $Request.SessionRef)}
  }
  'DeploymentAttach'{
   $script:LoopbackAttachIntercepted=$true
   # Authentication has succeeded and UI would now enter read-only inspect.
   # Do not deliver Attach or run any remote command/backend in this test.
   return
  }
  default{
   $script:DeniedActors.Add('Worker/'+[string]$Request.Action)
   throw ('Worker action is outside the login-only journey: '+$Request.Action)
  }
 }
 $entry.Delivered=$true;& $Complete $data $CallbackContext;StopIntakeTimer
}
try{
 . ([scriptblock]::Create($harness.Substring($setupStart,$setupEnd-$setupStart)))
 $script:LoopbackFlow=Import-Module (Join-Path $script:PackageRoot 'DeploymentFlow.psm1') -PassThru -DisableNameChecking
 $script:LoopbackTransport=Import-Module (Join-Path $script:PackageRoot 'DeploymentTransport.psm1') -PassThru -DisableNameChecking
 $script:LoopbackRegistry=Import-Module (Join-Path $script:PackageRoot 'ServerRegistry.psm1') -PassThru -DisableNameChecking
 # The presentation harness creates its disposable directory before modules
 # load. Give only that owned directory the same private ACL the app requires.
 $fixtureLinux=Import-Module (Join-Path $script:PackageRoot 'LinuxServerSetup.psm1') -PassThru -DisableNameChecking
 & $fixtureLinux {param($Path) Protect-TCLinuxPath $Path -Directory} (SafeLocalPath $script:Root)
 # Even an accidental journey advance cannot send Linux commands from this
 # fixture. Authentication uses the real product executor and named pipe.
 & $script:LoopbackTransport {
  param($denied,$root,$package,$runIds,$processes)
  $script:LoopbackDenied=$denied;$script:LoopbackOwnedRoot=$root;$script:LoopbackPackage=$package;$script:LoopbackRunIds=$runIds;$script:LoopbackProcesses=$processes
  function script:Invoke-TCDeployOperation {$script:LoopbackDenied.Add('RemoteOperation');throw 'Login fixture cannot execute a remote operation'}
  function script:Start-Process {
   [CmdletBinding()]param([string]$FilePath,[string]$ArgumentList,[string]$WindowStyle,[switch]$PassThru)
   $parts=[regex]::Match($ArgumentList,'^"(TCDeploy-[0-9a-f]{32})" "([0-9a-f-]{36})" "([0-9a-f-]{36})" "([^"]+)" "([^"]+)"$')
   if($FilePath -cne (Join-Path $script:LoopbackPackage 'deployment\TradeChannelDeployHost.exe') -or -not $parts.Success -or -not $script:LoopbackRunIds.Contains($parts.Groups[2].Value) -or $parts.Groups[4].Value -cne (Join-Path $script:LoopbackOwnedRoot ('deployments\hosts\'+$parts.Groups[3].Value)) -or $parts.Groups[5].Value -cne $script:LoopbackPackage -or $WindowStyle -cne 'Hidden' -or -not $PassThru){
    $script:LoopbackDenied.Add('ProcessLaunch');throw 'Executor launch escaped the owned login fixture'
   }
   $p=Microsoft.PowerShell.Management\Start-Process @PSBoundParameters
   $script:LoopbackProcesses.Add([pscustomobject]@{ProcessId=$p.Id;StartTimeUtcTicks=[string]$p.StartTime.ToUniversalTime().Ticks})
   return $p
  }
  function script:Get-Process {
   [CmdletBinding()]param([int]$Id)
   $known=@($script:LoopbackProcesses|Where-Object ProcessId -EQ $Id)
   if($known.Count -ne 1){$script:LoopbackDenied.Add('ProcessRead');throw 'Executor query escaped the owned login fixture'}
   $p=Microsoft.PowerShell.Management\Get-Process @PSBoundParameters
   if($p -and ($p.Path -cne (Join-Path $script:LoopbackPackage 'deployment\TradeChannelDeployHost.exe') -or [string]$p.StartTime.ToUniversalTime().Ticks -cne $known[0].StartTimeUtcTicks)){$p.Dispose();$script:LoopbackDenied.Add('ProcessIdentity');throw 'Fixture executor identity changed'}
   return $p
  }
 } $script:DeniedActors $script:Root $script:PackageRoot $script:LoopbackRunIds $script:LoopbackStartedProcesses
 $metadata=FixturePath (Join-Path $script:Root 'ssh.json');$remoteLog=FixturePath (Join-Path $script:Root 'ssh-log.json')
 $fixture=Join-Path $PSScriptRoot 'login_ssh_fixture.py'
 $fixtureProcess=Microsoft.PowerShell.Management\Start-Process -FilePath 'python.exe' -ArgumentList ('-B "'+$fixture+'" "'+$metadata+'" "'+$remoteLog+'"') -WindowStyle Hidden -PassThru -RedirectStandardError (Join-Path $script:Root 'fixture.stderr')
 $deadline=[DateTime]::UtcNow.AddSeconds(15)
 while(-not [IO.File]::Exists($metadata)){if($fixtureProcess.HasExited -or [DateTime]::UtcNow -ge $deadline){throw 'Local SSH fixture failed to start'};Start-Sleep -Milliseconds 25}
 $script:LoopbackTarget=[IO.File]::ReadAllText($metadata,[Text.Encoding]::UTF8)|ConvertFrom-Json
 ResetUI;$script:Smoke=$false;$script:Role='deployment';ShowProductDeployment
 $script:Controls.DeployConnectionText.Text='127.0.0.1';$script:Controls.DeployPort.Text=[string]$script:LoopbackTarget.Port;$script:Controls.DeployUser.Text='root';$script:Controls.DeployName.Text='Loopback login journey'
 $script:Controls.DeployRemember.IsChecked=$false;$script:Controls.DeployPassword.Password=$script:LoopbackWrongPassword
 StartProductDeployment
 CheckUI ([bool]$script:DeployUI.SessionRef) ('Actual StartProductDeployment starts a product executor: '+$script:LastErrorDialog)
 $firstRef=$script:DeployUI.SessionRef;$script:LoopbackFirstPoll=Wait-LoopbackAuthentication $firstRef
 CheckUI ($script:LoopbackFirstPoll.Code -ceq 'AuthenticationFailed' -and -not $script:LoopbackFirstPoll.HasSession) 'Actual loopback SSH rejects the deliberately wrong submitted password'
 $oldContext=NewDeploymentCallbackContext -Session
 ApplyDeploymentSessionSnapshot ([pscustomobject]@{InstanceId=$firstRef.InstanceId;Poll=$script:LoopbackFirstPoll}) $oldContext
 CheckUI ($script:DeployUI.Run.AccessIssue.Code -ceq 'AuthenticationFailed') 'Actual Flow records the executor authentication failure in the isolated task'
 ClickUI 'DeployRetryLogin'
 $reasonVisible=(VisibleText) -match '拒绝.*登录认证'
 $box=$script:Controls.DeployPassword
 # Repeated real polls and explicitly late callbacks cross the same editing
 # boundary as the reported bug. Only comparisons/lengths enter the report.
 foreach($n in 1..30){
  $expected=$script:LoopbackExpectedPassword.Substring(0,[Math]::Min($n,$script:LoopbackExpectedPassword.Length));$box.Password=$expected
  $script:DeployUI.LastPoll=[DateTime]::MinValue;PollProductDeployment
  $oldPoll=Get-LoopbackPoll $firstRef
  ApplyDeploymentSessionSnapshot ([pscustomobject]@{InstanceId=$firstRef.InstanceId;Poll=$oldPoll}) $oldContext
  $retained=($box.Password -ceq $expected)
  $script:LoopbackEdits.Add([pscustomobject]@{Iteration=$n;ExpectedLength=$expected.Length;ActualLength=$box.SecurePassword.Length;Retained=$retained;AuthenticationGeneration=$oldPoll.AuthenticationGeneration})
  if(-not $retained){$failureCode='LoginDraftClearedByOldFailure';$legacyReproduced=$true;throw 'Repeated real authentication failure cleared the actual retry PasswordBox'}
  $null=$script:Window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Background)
 }
 if($ExpectLegacyInputLoss){$failureCode='LegacyRegressionNotReproduced';throw 'The explicitly expected legacy input-loss regression was not reproduced'}
 CheckUI $reasonVisible 'The real authentication reason remains visible on the retry form'
 CheckUI ($script:Controls.ContainsKey('DeployPasswordReveal')) 'The retry form offers a password reveal control'
 $box.Password=$script:LoopbackExpectedPassword;ClickUI 'DeployPasswordReveal'
 CheckUI ($script:Controls.DeployPasswordPlainText.Text -ceq $script:LoopbackExpectedPassword) 'Show password exposes exactly the edited test draft for checking'
 $oldPoll=Get-LoopbackPoll $firstRef;ApplyDeploymentSessionSnapshot ([pscustomobject]@{InstanceId=$firstRef.InstanceId;Poll=$oldPoll}) $oldContext
 CheckUI ($script:Controls.DeployPasswordPlainText.Text -ceq $script:LoopbackExpectedPassword -and $box.Password -ceq $script:LoopbackExpectedPassword) 'A late failure preserves both displayed and hidden representations'
 ClickUI 'DeployPasswordReveal'
 CheckUI ($box.Password -ceq $script:LoopbackExpectedPassword -and $script:Controls.DeployPasswordPlainText.Text -ceq '') 'Hiding keeps the corrected password and removes visible clear text'
 $script:Controls.DeployRemember.IsChecked=$false;StartProductDeployment
 CheckUI ($script:LoopbackSessions.Count -eq 2 -and $script:DeployUI.SessionRef.InstanceId -cne $firstRef.InstanceId) ('Actual resubmission starts one new login attempt: '+$script:LastErrorDialog)
 $script:LoopbackFinalPoll=Wait-LoopbackAuthentication $script:DeployUI.SessionRef
 CheckUI ($script:LoopbackFinalPoll.Code -ceq 'Authenticated' -and $script:LoopbackFinalPoll.HasSession) 'Actual SSH accepts the corrected credential snapshot submitted by the real UI'
 ApplyDeploymentSessionSnapshot ([pscustomobject]@{InstanceId=$script:DeployUI.SessionRef.InstanceId;Poll=$script:LoopbackFinalPoll}) (NewDeploymentCallbackContext -Session)
 CheckUI ($script:LoopbackAttachIntercepted -and $script:DeployUI.SessionAttached) 'The real success callback reaches Attach and the fixture stops before remote inspection'
 $stats=[IO.File]::ReadAllText($remoteLog,[Text.Encoding]::UTF8)|ConvertFrom-Json
 CheckUI ($stats.Authenticated -eq 1 -and $stats.RemoteCommandAttempts -eq 0) 'The endpoint accepted the exact expected test password once and received zero remote commands'
 CheckUI ($stats.AuthenticationAttempts.Count -eq 2 -and $stats.AuthenticationAttempts[0].MatchesInitialTestPassword -and -not $stats.AuthenticationAttempts[0].Accepted -and $stats.AuthenticationAttempts[1].MatchesCorrectedTestPassword -and $stats.AuthenticationAttempts[1].Accepted) 'Received-credential equality proves the executor submitted the initial password then the corrected password'
 CheckUI ($script:DeniedActors.Count -eq 0) 'No production Worker networking or unapproved actor was attempted'
 $passed=$true
}catch{
 $failure=$_.Exception.Message
 if(-not ($ExpectLegacyInputLoss -and $legacyReproduced)){throw}
}finally{
 foreach($ref in $script:LoopbackSessions.ToArray()){
  try{& $script:LoopbackTransport {param($r)$null=Stop-TCDeploySession -SessionRef $r -Cancel;$null=Stop-TCDeploySession -SessionRef $r} $ref}catch{}
 }
 foreach($ref in $script:LoopbackStartedProcesses.ToArray()){
  $process=Microsoft.PowerShell.Management\Get-Process -Id ([int]$ref.ProcessId) -ErrorAction SilentlyContinue
  if($process){try{if([string]$process.StartTime.ToUniversalTime().Ticks -ceq [string]$ref.StartTimeUtcTicks){if(-not $process.WaitForExit(3000)){$process.Kill();$null=$process.WaitForExit(3000)}}}finally{$process.Dispose()}}
 }
 if($fixtureProcess){if(-not $fixtureProcess.HasExited){$fixtureProcess.Kill();$null=$fixtureProcess.WaitForExit(3000)};$fixtureProcess.Dispose()}
 $authEvidence=$null;if($remoteLog -and [IO.File]::Exists($remoteLog)){$authEvidence=[IO.File]::ReadAllText($remoteLog,[Text.Encoding]::UTF8)|ConvertFrom-Json}
 if($script:Window){$script:Window.Close()}
 $requestJson=ConvertTo-Json -InputObject $script:AllRequests.ToArray() -Depth 20 -Compress
 $result=[pscustomobject]@{Passed=$passed;LegacyInputLossReproduced=$legacyReproduced;ExpectedLegacyFailure=[bool]$ExpectLegacyInputLoss;FailureCode=$failureCode;Failure=$failure;Version=([IO.File]::ReadAllText((Join-Path $script:PackageRoot 'version.json'),[Text.Encoding]::UTF8)|ConvertFrom-Json).Version;Runtime=$PSVersionTable.PSVersion.ToString();Checks=$script:Checks.ToArray();EditingPolls=$script:LoopbackEdits.ToArray();SessionCount=$script:LoopbackSessions.Count;FirstAuthenticationCode=$script:LoopbackFirstPoll.Code;FinalAuthenticationCode=$script:LoopbackFinalPoll.Code;AuthenticationEvidence=$authEvidence;CredentialEvidenceFormat='Equality booleans only; no received credentials recorded';StoppedBeforeRemoteInspection=$script:LoopbackAttachIntercepted;UiCommands=$script:LoopbackUiCommands.ToArray();WorkerActions=@($script:AllRequests.ToArray()|ForEach-Object Action);SecretsInWorkerRequests=($requestJson.Contains($script:LoopbackExpectedPassword) -or $requestJson.Contains($script:LoopbackWrongPassword));DeniedActors=$script:DeniedActors.ToArray();NetworkScope='127.0.0.1 only';ProductionDataAccess=0;RealRemoteServersTouched=$false;UiSourceSHA256=(Get-FileHash -LiteralPath (Join-Path $script:PackageRoot 'ui\DeploymentPages.ps1')).Hash;HostBinarySHA256=(Get-FileHash -LiteralPath (Join-Path $script:PackageRoot 'deployment\TradeChannelDeployHost.exe')).Hash}
 [IO.File]::WriteAllText($ReportPath,($result|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($true)))
 $owned=SafeLocalPath $script:Root;$marker=Join-Path $owned '.owned-ui-015'
 if($owned -cne (Join-Path ([IO.Path]::GetTempPath()) ('tc-ui-015-data-'+$testId)) -or -not [IO.File]::Exists($marker) -or [IO.File]::ReadAllText($marker) -cne $testId){throw 'Fixture cleanup ownership check failed'}
 Remove-Item -LiteralPath $owned -Recurse -Force
 $result|Select-Object Passed,LegacyInputLossReproduced,ExpectedLegacyFailure,FailureCode,Failure,Version,SessionCount,FirstAuthenticationCode,FinalAuthenticationCode,StoppedBeforeRemoteInspection|ConvertTo-Json
}
