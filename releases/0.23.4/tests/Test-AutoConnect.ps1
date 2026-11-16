#requires -Version 5.1
[CmdletBinding()]param([string]$ReportPath)
$ErrorActionPreference='Stop';$env:PSModulePath=Join-Path $PSHOME 'Modules'
$package=Split-Path $PSScriptRoot -Parent
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('TC-AutoConnect-'+[guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($fixture)
$module=Import-Module (Join-Path $package 'AutoConnect.psm1') -Force -PassThru -DisableNameChecking
$result=$null
try{
 $result=& $module {
  param($Root)
  $checks=New-Object 'Collections.Generic.List[string]'
  function Check($Condition,$Message){if(-not $Condition){throw $Message};$checks.Add($Message)}
  function Clone($Value){$Value|ConvertTo-Json -Depth 30|ConvertFrom-Json}
  function Denied([scriptblock]$Action,[string]$Pattern){try{& $Action|Out-Null;return $false}catch{return $_.Exception.Message -match $Pattern}}
  $settings=Get-TCUserSettings $Root
  Check (-not $settings.AutoConnectOnLogin -and $settings.AutoTrustFirstConnection) 'Defaults preserve manual connection and automatic first-use identity'
  foreach($kind in @('Manual','SelfTest','ReadOnly')){
   $args=@{StartupLaunch=($kind -ne 'Manual');SelfTest=($kind -eq 'SelfTest');ReadOnlyLaunch=($kind -eq 'ReadOnly')}
   Check ((New-TCAutoConnectLaunch @args).Status -eq 'Skipped') ($kind+' launch cannot auto-connect')
  }
  $overview=[pscustomobject]@{StateKey='Disconnected';ReadState='Current';Running=$false;NinjaRunning=$false}
  foreach($kind in @('Disabled','Trading','Connected','Unknown','UserInput','Timeout','WaitNetwork','WaitBusy','Ready')){
   $s=New-TCAutoConnectLaunch -StartupLaunch;$o=Clone $overview;$enabled=$true;$network=$true;$busy=$false;$manual=$false;$elapsed=3
   switch($kind){'Disabled'{$enabled=$false}'Trading'{$o.NinjaRunning=$true}'Connected'{$o.Running=$true}'Unknown'{$o.ReadState='Unknown'}'UserInput'{$manual=$true}'Timeout'{$elapsed=31}'WaitNetwork'{$network=$false}'WaitBusy'{$busy=$true}}
   $run=Get-TCAutoConnectLaunchDecision -State $s -Settings @{AutoConnectOnLogin=$enabled} -Overview $o -Busy $busy -NetworkReady $network -UserDisconnect $manual -ElapsedSeconds $elapsed
   Check ($run -eq ($kind -eq 'Ready')) ($kind+': correct login decision')
   if($kind -eq 'Ready'){Check (-not (Get-TCAutoConnectLaunchDecision -State $s -Settings @{AutoConnectOnLogin=$true} -Overview $o -Busy $false -NetworkReady $true -UserDisconnect $false -ElapsedSeconds 4)) 'A login launch tries only once'}
  }
  $candidate=Join-Path $Root 'candidate.json';$manifest=Join-Path $Root 'profile.json';$active=Join-Path $Root 'active.manifest'
  [IO.File]::WriteAllText($candidate,'inert fixture');[IO.File]::WriteAllText($manifest,'inert fixture manifest')
  $node=[guid]::NewGuid().ToString('D');$session=[guid]::NewGuid().ToString('D');$now=[DateTimeOffset]::UtcNow.ToString('o')
  $identity=[pscustomobject]@{SessionId=$session;SupervisorPid=101;SupervisorStartedAt=$now;EnginePid=102;EngineStartedAt=$now}
  $observed=Clone $identity
  $observed|Add-Member NoteProperty State 'Running';$observed|Add-Member NoteProperty OwnershipKnown $true;$observed|Add-Member NoteProperty ManifestPath $active;$observed|Add-Member NoteProperty CandidateSHA256 (ACHash $candidate)
  $tx=[pscustomobject]@{Id=[guid]::NewGuid().ToString('D');Status='Completed';LineId=$node;ProfileId='Tcp';ActiveManifestPath=$active;CandidateIdentity=$identity;TargetHash=(ACHash $candidate);Target=[pscustomobject]@{ManifestPath=$manifest;ManifestSHA256=(ACHash $manifest);CandidatePath=$candidate;CandidateSHA256=(ACHash $candidate)};TargetCheck=[pscustomobject]@{ExitHttp=$true;DnsHttps=$true;ExitVerified=$true;ProfileValidated=$true;ActualExit='hk'};Intent=[pscustomobject]@{Mode='Trading';Exit='HongKong';Daily='Direct';NodeId=$node;ProfileId='Tcp';ProviderId='';TradeProviderId='';Agents='Trade';AgentIds=@('fixture-app');AgentCustom=@()}}
  Check (Save-TCLastSuccessfulConnection -Root $Root -Transaction $tx -Observed $observed) 'Verified success saves the exact connection'
  $record=Get-TCLastSuccessfulConnection $Root
  Check ($record.NodeId -eq $node -and $record.ProfileId -eq 'Tcp' -and $record.Intent.Agents -eq 'Trade' -and $record.Intent.AgentIds[0] -eq 'fixture-app') 'Saved line, profile and application choices round-trip'
  $hash=ACHash (ACRecordPath $Root)
  $bad=Clone $tx;$bad.Status='RolledBack';Check (-not (Save-TCLastSuccessfulConnection $Root $bad $observed)) 'Failed transaction cannot replace last success'
  $bad=Clone $tx;$bad.TargetCheck.ExitVerified=$false
  Check (Denied {Save-TCLastSuccessfulConnection $Root $bad $observed} 'AutoConnectUnverified') 'Unverified forwarding cannot replace last success'
  $other=Clone $observed;$other.SessionId=[guid]::NewGuid().ToString('D')
  Check (Denied {Save-TCLastSuccessfulConnection $Root $tx $other} 'AutoConnectUnverified') 'A changed runtime session cannot be remembered'
  Check ((ACHash (ACRecordPath $Root)) -ceq $hash) 'Rejected saves leave original record bytes intact'
  $script:Calls=New-Object 'Collections.Generic.List[string]';$script:Blocked=$false;$script:Running=$false;$script:Trading=$false;$script:Committed=$null
  function Invoke-TCAutoConnectOperation {param($Operation,$Root,$Payload)
   $script:Calls.Add($Operation)
   switch($Operation){
    'Preflight'{if($script:Trading){throw '[TC:TradingSoftwareRunning] fixture'};return}
    'Pending'{return $script:Blocked}
    'Observe'{return [pscustomobject]@{State=$(if($script:Running){'Running'}else{'Stopped'});OwnershipKnown=$true}}
    'Preview'{return [pscustomobject]@{CanSwitch=$true;LineId=$Payload.NodeId;ProfileId=$Payload.ProfileId;PreviewToken=('ct1:123:'+('A'*64));Observed=[pscustomobject]@{State='Stopped'};Baseline=[pscustomobject]@{Target=$Payload.Binding;Intent=$Payload.Intent}}}
    'Commit'{$script:Committed=$Payload;return [pscustomobject]@{Activated=$true;Status='Completed'}}
    default{throw 'Unexpected adapter operation'}
   }
  }
  Check (Denied {Get-TCAutoConnectPreview $Root -StartupLaunch} 'AutoConnectDisabled') 'Preview refuses the default disabled switch'
  $null=Set-TCUserSetting $Root AutoConnectOnLogin $true
  Check (Denied {Get-TCAutoConnectPreview $Root} 'AutoConnectLaunch') 'Ordinary launch cannot invoke the automatic preview'
  $preview=Get-TCAutoConnectPreview $Root -StartupLaunch
  Check ($preview.Ready -and $preview.RecordSHA256 -ceq $hash) 'Login preview binds the saved record hash'
  foreach($case in @('Trading','Blocked','Running')){
   Set-Variable -Scope Script -Name $case -Value $true
   Check (Denied {Invoke-TCAutoConnectCommit $Root -StartupLaunch -RecordSHA256 $hash -PreviewToken $preview.PreviewToken -RequestId ([guid]::NewGuid().ToString('D'))} 'TradingSoftwareRunning|NeedsRecovery|AutoConnectState') ($case+': commit rechecks protection after preview')
   Set-Variable -Scope Script -Name $case -Value $false
  }
  $answer=Invoke-TCAutoConnectCommit $Root -StartupLaunch -RecordSHA256 $hash -PreviewToken $preview.PreviewToken -RequestId ([guid]::NewGuid().ToString('D'))
  Check ($answer.Activated -and $script:Committed.Record.NodeId -ceq $node -and $script:Committed.PreviewToken -ceq $preview.PreviewToken) 'Commit uses the original token and exact saved line'
  [IO.File]::AppendAllText($candidate,'changed')
  Check (Denied {Get-TCAutoConnectPreview $Root -StartupLaunch} 'AutoConnectBinding') 'Configuration changes require manual connection'
  $user=Get-Module UserSettings
  # Negative schema checks only. Real Startup + UserSettings opt-in, readback
  # and rollback coverage lives in Test-StartupSettingsIntegration.ps1.
  $invalidStates=@(
   @{Name='Legacy startup response without Verified';Value=[pscustomobject]@{Enabled=$false;Detail='legacy contract'}},
   @{Name='Missing enabled flag';Value=[pscustomobject]@{Verified=$true}},
   @{Name='String verification flag';Value=[pscustomobject]@{Enabled=$true;Verified='true'}},
   @{Name='String enabled flag';Value=[pscustomobject]@{Enabled='false';Verified=$true}},
   @{Name='Unverified startup state';Value=[pscustomobject]@{Enabled=$false;Verified=$false}},
   @{Name='Null startup response';Value=$null}
  )
  foreach($case in $invalidStates){
   $rejected=& $user {param($State) -not (Test-TCStartupStateVerified $State)} $case.Value
   Check $rejected ($case.Name+': rejected without strict-mode property access failure')
  }
  [pscustomobject]@{Passed=$true;Checks=$checks.Count;Assertions=$checks.ToArray();NetworkChanged=$false;SchedulerChanged=$false;RuntimeAdapter='FixtureOnly'}
 } $fixture
 if($ReportPath){$path=[IO.Path]::GetFullPath($ReportPath);$null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path));[IO.File]::WriteAllText($path,($result|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($true)))}
 $result|ConvertTo-Json -Depth 8
}finally{
 $full=[IO.Path]::GetFullPath($fixture);$prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if($full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($full) -cmatch '^TC-AutoConnect-[a-f0-9]{32}$'){Remove-Item -LiteralPath $full -Recurse -Force}
}
