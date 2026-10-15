#requires -Version 5.1
[CmdletBinding()]param([string]$ReportPath)
$ErrorActionPreference='Stop';$env:PSModulePath=Join-Path $PSHOME 'Modules'
$package=Split-Path $PSScriptRoot -Parent;$workspace=Split-Path (Split-Path $package -Parent) -Parent
if(-not $ReportPath){$ReportPath=Join-Path $workspace 'reports\release-0.15.0\deployment-journey.json'}
$parent=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($ReportPath));$null=[IO.Directory]::CreateDirectory($parent)
$fixture=Join-Path $parent ('.journey-fixture-'+[guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($fixture)
if($fixture.StartsWith([Environment]::GetFolderPath('CommonApplicationData'),[StringComparison]::OrdinalIgnoreCase)){throw 'Fixture cannot address ProgramData'}
$flow=Import-Module (Join-Path $package 'DeploymentFlow.psm1') -Force -PassThru -DisableNameChecking
$decision=Import-Module (Join-Path $package 'DeploymentDecision.psm1') -Force -PassThru -DisableNameChecking
$result=$null
try{
 $result=& $flow {
  param($Fixture,$Decision)
  $script:Checks=0;$script:NetworkTouches=0;$script:Poll=$null
  function script:AssertJourney {param([bool]$Condition,[string]$Message) $script:Checks++;if(-not $Condition){throw $Message}}
  function script:Get-TCDeploySession {param($SessionRef) $script:Poll}
  function script:Start-TCDeploySession {$script:NetworkTouches++;throw 'Real SSH forbidden in journey state tests'}
  function script:Invoke-TCDeployOperation {$script:NetworkTouches++;throw 'Real remote operation forbidden'}
  function script:Invoke-TCProtocolComparison {$script:NetworkTouches++;throw 'Real probe forbidden'}
  $inspection=[pscustomobject]@{EngineStaged=$true;WgHelperStaged=$true;ExistingDeployment=$true;NinjaTraderPaths=@();DirectDnsIPv4=@('192.0.2.53')}
  $connection=[pscustomobject]@{Host='198.51.100.21';Port=22;User='root';IdentityFile=''}
  $run=New-TCDeploymentRun -Root $Fixture -Intent Auto -Connection $connection -Name 'journey fixture' -ClientInspection $inspection
  AssertJourney ($run.Intent -eq 'Add' -and $run.ExperienceVersion -eq 1 -and $run.Stage -eq 'PrepareAccess') 'Auto intake did not reuse prepared computer semantics'
  $bad=$inspection|ConvertTo-Json|ConvertFrom-Json;$bad.EngineStaged=$false;$failed=$false
  try{$null=New-TCDeploymentRun -Root $Fixture -Intent Auto -Connection $connection -ClientInspection $bad}catch{$failed=($_.Exception.Message -match 'LocalComponentsMissing')}
  AssertJourney $failed 'Missing local engine was accepted before server preparation'
  $session=[pscustomobject]@{RunId=$run.RunId;InstanceId=[guid]::NewGuid().ToString('D');Root=(Join-Path $Fixture 'fixture-session');ProcessId=999999;StartTimeUtcTicks='123'}
  $script:Poll=[pscustomobject]@{Status='Connecting';Code='Connecting';HasSession=$false}
  $run=Set-TCDeploymentAccessState -Root $Fixture -RunId $run.RunId -SessionRef $session -AttemptOnly
  AssertJourney ($run.AttemptSessionRef.InstanceId -eq $session.InstanceId -and -not $run.AccessIssue) 'Attempt reference was not persisted'
  foreach($pair in @(@('HostKeyChanged','IdentityChanged','VerifyIdentity'),@('AuthenticationFailed','Credentials','RetryLogin'),@('ConnectionTimeout','Connection','RetryLogin'),@('InvalidPrivateKey','PrivateKey','RetryLogin'))){
   $script:Poll=[pscustomobject]@{Status='Failed';Code=$pair[0];HasSession=$false;ObservedFingerprint='SHA256:fixture-public-fingerprint';HostKeyAlgorithm='ssh-ed25519'}
   $run=Set-TCDeploymentAccessState -Root $Fixture -RunId $run.RunId -SessionRef $session
   AssertJourney ($run.AccessIssue.Kind -eq $pair[1] -and $run.AccessIssue.Code -eq $pair[0] -and $run.Status -eq 'WaitingUser') ('Access issue not persisted: '+$pair[0])
   $d=& $Decision {param($r)Get-TCDeploymentDecision -Run $r} $run
   AssertJourney ($d.PrimaryAction -eq $pair[2] -and $d.Blocked) ('Access problem has no correct inline action: '+$pair[0])
   $stored=Get-TCDeploymentRun $Fixture $run.RunId
   AssertJourney ($stored.AccessIssue.Code -eq $pair[0]) ('Reopen lost access cause: '+$pair[0])
  }
  $other=$session|ConvertTo-Json|ConvertFrom-Json;$other.InstanceId=[guid]::NewGuid().ToString('D');$failed=$false
  try{$null=Set-TCDeploymentAccessState -Root $Fixture -RunId $run.RunId -SessionRef $other}catch{$failed=($_.Exception.Message -match 'SessionBindingMismatch')}
  AssertJourney $failed 'Stale session callback overwrote a current problem'
  $script:Poll=[pscustomobject]@{Status='OutcomeUnknown';Code='AuthenticationRequired';HasSession=$false}
  $run=Set-TCDeploymentAccessState -Root $Fixture -RunId $run.RunId -SessionRef $session
  AssertJourney ($run.Status -eq 'OutcomeUnknown' -and $run.RecoveryRequired -and $run.Stage -eq 'Reconcile') 'Unknown write outcome was downgraded to ordinary login failure'
  $d=& $Decision {param($r)Get-TCDeploymentDecision -Run $r} $run
  AssertJourney ($d.PrimaryAction -eq 'RetryLogin' -and $d.Message -match '原操作结果') 'Unknown outcome does not request login before original result reconciliation'
  $script:Poll=[pscustomobject]@{Status='Ready';Code='Authenticated';HasSession=$true}
  $run=Set-TCDeploymentSession -Root $Fixture -RunId $run.RunId -SessionRef $session
  AssertJourney (-not $run.AccessIssue -and $run.Stage -eq 'Reconcile' -and $run.RecoveryRequired) 'Successful login discarded unknown-result recovery requirement'
  $run.Stage='ReadyInactive';$run.Status='WaitingUser';$run.PendingPurpose=$null;$run.PendingOperationId=$null;$run.RecoveryRequired=$false;$run.UnresolvedTcpMutation=$null
  $run.ProtocolPreparation.Udp.ServerPreparation='Configured';$run.ProtocolPreparation.Udp.LocalPreparation='SyntaxValidated';$run.ProtocolPreparation.Tcp.ServerPreparation='Configured';$run.ProtocolPreparation.Tcp.LocalPreparation='SyntaxValidated'
  $run.ProfileProbeState='Completed';$run.Recommendation=[pscustomobject]@{Status='Recommended'}
  $run=Save-TCDeploymentRun $Fixture $run
  AssertJourney ($run.AutoSavedAtUtc -and $run.Status -eq 'Complete' -and -not $run.AttentionRequired -and -not $run.NetworkChanged) 'Complete preparation still needs a separate Save click'
  $run.Recommendation=[pscustomobject]@{Status='Inconclusive'};$run=Save-TCDeploymentRun $Fixture $run
  AssertJourney ($run.AutoSavedAtUtc -and $run.AttentionRequired) 'Automatic save hid a required detection follow-up'
  $run.ProtocolPreparation.Tcp.LocalPreparation='Missing';$run.Status='WaitingUser';$run.AutoSavedAtUtc=$null;$run=Save-TCDeploymentRun $Fixture $run
  AssertJourney ($run.DeploymentCompleteness -eq 'Partial' -and $run.Status -ne 'Complete' -and -not $run.AutoSavedAtUtc) 'Partial TCP preparation was called complete'
  $run.ProtocolPreparation.Tcp.LocalPreparation='SyntaxValidated';$run.ProfileProbeState='Running';$run=Save-TCDeploymentRun $Fixture $run
  AssertJourney ($run.Status -ne 'Complete') 'An active candidate check was closed by autosave'
  $json=[IO.File]::ReadAllText((Join-Path (Get-TCDeploymentRunPath $Fixture $run.RunId) 'state.json'))
  AssertJourney ($json -notmatch '"Password"\s*:|"PrivateKeyPem"\s*:|"Credential"\s*:') 'Access record persisted a secret field'
  AssertJourney ($script:NetworkTouches -eq 0) 'Journey state regression touched real network'
  [pscustomobject]@{Passed=$true;Checks=$script:Checks;LiveServerOperations=0;RealConnectionOperations=0;NetworkChanges=0;FixtureScope='WorkspaceOnly'}
 } $fixture $decision
}finally{
 if($result){[IO.File]::WriteAllText($ReportPath,($result|ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($false)))}
 $resolved=[IO.Path]::GetFullPath($fixture);if(-not $resolved.StartsWith($parent.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^\.journey-fixture-[a-f0-9]{32}$'){throw 'Fixture cleanup rejected'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
}
$result|ConvertTo-Json
