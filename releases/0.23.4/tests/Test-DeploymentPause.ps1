#requires -Version 5.1
$ErrorActionPreference='Stop'
$root=Join-Path ([IO.Path]::GetTempPath()) ('tc-pause-test-'+[guid]::NewGuid().ToString('N'))
$module=Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'DeploymentFlow.psm1') -Force -PassThru -DisableNameChecking
try{
 & $module {
  param($Root)
  $script:PauseCalls=0;$script:PauseChecks=0
  $script:PauseServer=[pscustomobject]@{LocalRecordId='fixture';Connection=@{Host='192.0.2.1';User='fixture';Port=22};ServerPublicKey='fixture-key';PinnedHostKey='fixture-pin'}
  $script:PauseRun=[pscustomobject]@{RunId=[guid]::NewGuid().ToString();ServerRecordId='fixture';SessionRef=@{InstanceId=[guid]::NewGuid().ToString()};Status='Idle';Stage='Apply';PendingOperationId=$null;PendingPurpose=$null;DispatchIntent=$null;LastRemoteMutation=$null;LastError=$null;UserActions=@()}
  function Check {param($ok,$name)if(-not $ok){throw $name};$script:PauseChecks++}
  function Get-TCServer {param($Root,$Id)$script:PauseServer}
  function Get-TCDeploymentRun {param($Root,$RunId)$script:PauseRun}
  function Save-TCDeploymentRun {param($Root,$Run)$Run}
  function Assert-TCServerTaskActive {param($Root,$RunId)$script:PauseServer}
  function Open-TCServerTaskLease {param($Root,$ServerId)New-Object IO.MemoryStream}
  function Assert-TCDraftActive {param($Root,$Id)}
  function Invoke-TCDeployOperation {param($SessionRef,$Operation,$Input,$OperationId)$script:PauseCalls++;[pscustomobject]@{Ok=$true;OperationId=$OperationId}}
  Initialize-TCDeploymentProtocolState $script:PauseRun
  $null=New-TCDDirectory (Get-TCDeploymentRunPath $Root $script:PauseRun.RunId)
  $requested=Request-TCDeploymentPause $Root $script:PauseRun.RunId
  Check ($requested.PauseRequested -and -not $requested.Paused) 'pause request does not claim an in-flight operation stopped'
  Start-TCDeploymentRemote $Root $script:PauseRun server_info ServerInfo @{}
  Check ($script:PauseCalls -eq 0 -and $script:PauseRun.Status -eq 'WaitingUser' -and $script:PauseRun.PausedContinuation.Operation -eq 'server_info') 'next step persists as a continuation without remote dispatch'
  $null=Invoke-TCDeploymentAdvance $Root $script:PauseRun.RunId Continue
  Check ($script:PauseCalls -eq 1 -and $script:PauseRun.Status -eq 'Running' -and -not $script:PauseRun.PausedContinuation) 'explicit resume submits exactly one original continuation'
  $script:PauseRun.Status='Idle';$null=Request-TCDeploymentPause $Root $script:PauseRun.RunId
  Start-TCDeploymentRemote $Root $script:PauseRun server_info ServerInfo @{}
  $script:PauseServer.PinnedHostKey='different';$rejected=$false
  try{$null=Invoke-TCDeploymentAdvance $Root $script:PauseRun.RunId Continue}catch{$rejected=$_.Exception.Message -match 'ApprovalTargetChanged'}
  Check ($rejected -and $script:PauseCalls -eq 1) 'changed server identity cannot inherit paused approval'
  [pscustomobject]@{Passed=$true;Checks=$script:PauseChecks;RealServerOperations=0}|ConvertTo-Json -Compress
 } $root
}finally{
 $full=[IO.Path]::GetFullPath($root);if($full.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($full) -match '^tc-pause-test-[a-f0-9]{32}$'){Remove-Item -LiteralPath $full -Recurse -Force}
}
