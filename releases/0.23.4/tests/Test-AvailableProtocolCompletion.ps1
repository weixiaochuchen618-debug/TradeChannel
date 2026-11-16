#requires -Version 5.1
[CmdletBinding()]param([string]$ReportPath,[string]$PackageRoot='')
$ErrorActionPreference='Stop';$env:PSModulePath=Join-Path $PSHOME 'Modules'
$package=if($PackageRoot){[IO.Path]::GetFullPath($PackageRoot)}else{Split-Path $PSScriptRoot -Parent}
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('TC-AvailableProtocol-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($fixture)
$flow=Import-Module (Join-Path $package 'DeploymentFlow.psm1') -Force -PassThru -DisableNameChecking
$decision=Import-Module (Join-Path $package 'DeploymentDecision.psm1') -Force -PassThru -DisableNameChecking
$result=$null
try{
 $result=& $flow {
  param($Root,$Decision)
  $checks=New-Object 'Collections.Generic.List[string]'
  function Check($Condition,[string]$Message){if(-not $Condition){throw $Message};$checks.Add($Message)}
  function Clone($Value){$Value|ConvertTo-Json -Depth 40|ConvertFrom-Json}
  function Invoke-TCDeployOperation {throw 'Remote operation forbidden'}
  function Invoke-TCProtocolComparison {throw 'Real probe forbidden'}
  $context=[pscustomobject]@{Status='Known';Fingerprint=('C'*64)}
  foreach($id in @('Udp','Tcp')){
   $run=New-TCDeploymentRun -Root $Root -Connection @{Host='192.0.2.21';Port=22;User='root';IdentityFile=''} -Name ('only '+$id)
   $run|Add-Member NoteProperty ExperienceVersion 1 -Force
   $run.CandidateNodeId=[guid]::NewGuid().ToString('D');$run.Stage='ReadyInactive';$run.Status='WaitingUser'
   $run.ProtocolPreparation.$id.ServerPreparation='Configured';$run.ProtocolPreparation.$id.LocalPreparation='SyntaxValidated'
   $profile=[pscustomobject]@{Id=$id;PreparationState='SyntaxValidated';CandidateSHA256=('A'*64);Validation=$null}
   $now=[DateTimeOffset]::UtcNow
   $raw=[pscustomobject]@{Status='Passed';Code='Passed';CandidateHash=$profile.CandidateSHA256;CheckedAtUtc=$now.ToString('o');ForwardingPassed=$true;CleanupComplete=$true;ObservedExitIPv4='192.0.2.40';ExpectedExitIPv4='192.0.2.40';ExpectedExitSource='ServerVerifiedTlsTrace';TransportPath='BoundInterfaceObserved';NetworkFingerprint=$context.Fingerprint;PathEvidence=[pscustomobject]@{Kind='BoundInterfaceObserved';Verified=$true;EligibleForRecommendation=$true;NetworkFingerprint=$context.Fingerprint};Checks=@([pscustomobject]@{Name='AddressHttps';Status='Passed'},[pscustomobject]@{Name='DomainDnsHttps';Status='Passed'})}
   $profile.Validation=ConvertTo-TCProtocolEvidence -Result $raw -Profile $profile -NetworkContext $context -Now $now
   $run|Add-Member NoteProperty Profiles @($profile) -Force
   $run.NetworkContext=$context;$run.Recommendation=Get-TCProtocolRecommendation -Profiles @($profile) -NetworkContext $context -LineId $run.CandidateNodeId -Now $now
   $run|Add-Member NoteProperty SavedConnectionPreference ([pscustomobject]@{ProfileId=$id;Binding=[pscustomobject]@{CandidateSHA256=$profile.CandidateSHA256}}) -Force
   $run.ProfileProbeState='Completed';Set-TCDeploymentReadyState $run
   $before=Clone $run
   Complete-TCDeploymentAvailableProtocol $run
   Check ($run.PartialUseAccepted -and $run.PartialUseOrigin -eq 'AutomaticAvailableConnection') ($id+': usable method accepted without another click')
   $run=Save-TCDeploymentRun $Root $run
   Check ($run.Status -eq 'Complete' -and $run.AutoSavedAtUtc -and -not $run.AttentionRequired) ($id+': deployment completed and saved')
   Check ($run.DeploymentCompleteness -eq 'Partial' -and @($run.MissingProtocols).Count -eq 1) ($id+': missing method remains accurately recorded')
   $reopened=Get-TCDeploymentRun $Root $run.RunId
   Check ($reopened.Status -eq 'Complete' -and $reopened.PartialUseAccepted) ($id+': completion survives reopening')
   Check (-not $run.NetworkChanged) ($id+': completing deployment does not activate the line')
   $d=& $Decision {param($r)Get-TCDeploymentDecision -Run $r} $run
   Check ($d.PrimaryAction -eq 'ConnectRecommended' -and -not $d.Blocked) ($id+': primary action directly offers connection')
   foreach($case in @('Pending','Interrupted','Blocked','Recovery','ProbeRecovery','RemoteUnknown','PendingOperation','IdentityChanged','NoEvidence','WrongHash','OtherLine','NoSavedDefault','Expired','Legacy','ManualUnverified','NetworkChanged')){
    $test=Clone $before
    switch($case){
     'Pending'{$test.ProfileProbeState='Pending'}
     'Interrupted'{$test.ProfileProbeState='Interrupted'}
     'Blocked'{$test.ProfileProbeState='Blocked'}
     'Recovery'{$test.RecoveryRequired=$true}
     'ProbeRecovery'{$test.ProbeRecoveryRequired=$true}
     'RemoteUnknown'{$test.UnresolvedTcpMutation=[pscustomobject]@{Operation='transport_apply'}}
     'PendingOperation'{$test.PendingOperationId=[guid]::NewGuid().ToString('D')}
     'IdentityChanged'{$test|Add-Member NoteProperty AccessIssue ([pscustomobject]@{Kind='IdentityChanged'}) -Force}
     'NoEvidence'{$test.Profiles[0].Validation=$null}
     'WrongHash'{$test.Profiles[0].CandidateSHA256='B'*64}
     'OtherLine'{$test.CandidateNodeId=[guid]::NewGuid().ToString('D')}
     'NoSavedDefault'{$test.SavedConnectionPreference=$null}
     'Expired'{$test.Recommendation.ExpiresAtUtc=$now.AddMinutes(-1).ToString('o')}
     'Legacy'{$test.ExperienceVersion=0}
     'ManualUnverified'{$test.Recommendation.Status='UserChoice'}
     'NetworkChanged'{$test.NetworkContext.Fingerprint='D'*64}
    }
    Complete-TCDeploymentAvailableProtocol $test
    Check (-not $test.PartialUseAccepted) ($id+': '+$case+' does not automatically complete')
   }
   $reopened.ProtocolPreparation.$id.LocalPreparation='Missing';Initialize-TCDeploymentProtocolState $reopened
   Check (-not $reopened.PartialUseAccepted -and $reopened.Status -ne 'Complete') ($id+': changed preparation invalidates completion')
  }
  [pscustomobject]@{Passed=$true;Checks=$checks.Count;Assertions=$checks.ToArray();NetworkChanged=$false}
 } $fixture $decision
 if($ReportPath){$path=[IO.Path]::GetFullPath($ReportPath);$null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path));[IO.File]::WriteAllText($path,($result|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($true)))}
 $result|ConvertTo-Json -Depth 8
}finally{
 $full=[IO.Path]::GetFullPath($fixture);$boundary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if($full.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($full) -cmatch '^TC-AvailableProtocol-[0-9a-f]{32}$'){Remove-Item -LiteralPath $full -Force -Recurse}
}
