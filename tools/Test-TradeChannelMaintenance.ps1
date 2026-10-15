#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot 'TradeChannel.Maintenance.psm1') -Force -PassThru -DisableNameChecking
$root=Join-Path ([IO.Path]::GetTempPath()) ('TC-MaintenanceTest-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($root)
try{
 & $module {
  param($fixture,$engine)
  $script:Checks=0;$script:Calls=New-Object 'System.Collections.Generic.List[string]'
  function script:Assert-M {param([bool]$Value,[string]$Label)if(-not $Value){throw ('Maintenance test: '+$Label)};$script:Checks++}
  $nativeConfig=Join-Path $fixture 'native.json'
  Write-TCMJson $nativeConfig @{outbounds=@(@{type='direct';tag='direct'})} -NoBom
  Assert-TCMEngineConfig $engine $nativeConfig
  Assert-M $true 'native configuration is accepted by real sing-box without a BOM'
  $globalOnly=[pscustomobject]@{route=@{rules=@(@{clash_mode='global';action='route';outbound='direct'})};dns=@{rules=@()}}
  $caught=$false;try{Assert-TCMDeclaredModes $globalOnly}catch{$caught=$true}
  Assert-M $caught 'maintenance rejects a valid syntax config that has only the global mode'
  $globalOnly.dns.rules=@(@{clash_mode='rule';action='route';server='dns-direct'})
  Assert-TCMDeclaredModes $globalOnly
  Assert-M $true 'explicit rule fallback survives a global startup default'
  $up={$script:Calls.Add('upgrade')};$verify={$script:Calls.Add('verify');[pscustomobject]@{Exit='hk'}};$commit={$script:Calls.Add('commit')};$recover={$script:Calls.Add('recover');[pscustomobject]@{Exit='hk-old'}}
  $r=Invoke-TCMTransaction $up $verify $commit $recover
  Assert-M ($r.State -eq 'Complete' -and ($script:Calls -join ',') -eq 'upgrade,verify,commit') 'success commits only after verification'
  $script:Calls.Clear();$r=Invoke-TCMTransaction {$script:Calls.Add('upgrade');throw 'failure'} $verify $commit $recover
  Assert-M ($r.State -eq 'RolledBack' -and ($script:Calls -join ',') -eq 'upgrade,recover') 'upgrade failure invokes local recovery'
  $script:Calls.Clear();$r=Invoke-TCMTransaction $up {$script:Calls.Add('verify');throw 'failure'} $commit $recover
  Assert-M ($r.State -eq 'RolledBack' -and ($script:Calls -join ',') -eq 'upgrade,verify,recover') 'bad exit never commits'
  $script:Calls.Clear();$r=Invoke-TCMTransaction $up $verify {$script:Calls.Add('commit');throw 'failure'} $recover
  Assert-M ($r.State -eq 'RolledBack' -and $script:Calls[-1] -eq 'recover') 'metadata failure also restores network'
  $r=Invoke-TCMTransaction {throw 'failure'} $verify $commit {throw 'recovery failure'}
  Assert-M ($r.State -eq 'RecoveryFailed' -and -not $r.Evidence) 'recovery failure is explicit, never claimed success'
  function script:Get-Process {param($Name,$Id,$ErrorAction)if($script:Ninja){[pscustomobject]@{Name='NinjaTrader'}}}
  $script:Ninja=$true;$caught=$false;try{Assert-TCMNinjaClosed}catch{$caught=$true};Assert-M $caught 'running NinjaTrader blocks maintenance'
  $script:Ninja=$false;Assert-TCMNinjaClosed;Assert-M $true 'closed NinjaTrader passes gate'
  $dir=Join-Path $fixture ('maintenance\'+[guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($dir)
  $old=Join-Path $fixture 'old.json';$candidate=Join-Path $fixture 'candidate.json';$sealed=Join-Path $dir 'candidate-manifest-sealed.json';$rec=Join-Path $dir 'recovery.json'
  Write-TCMJson $candidate @{DeploymentApproved=$false;PolicyVersion=4;EnginePath='fixture'}
  Copy-Item -LiteralPath $candidate -Destination $sealed
  Write-TCMJson $old @{};Write-TCMJson $rec @{}
  $plan=[pscustomobject]@{Id=[IO.Path]::GetFileName($dir);SchemaVersion=1;Root=$fixture;Directory=$dir;Package=(Join-Path $dir 'app');RollbackPackage=(Join-Path $dir 'old-app');CandidateManifest=$candidate;OldManifest=$old;RecoveryManifest=$rec;ExpiresAt=(Get-Date).AddHours(1).ToString('o');Files=@(@{Path=$sealed;Hash=(Get-FileHash $sealed).Hash});Baseline=@(@{Name='Old';Path=$old;Hash=(Get-FileHash $old).Hash})}
  $path=Join-Path $dir 'plan.json';Write-TCMJson $path $plan
  function script:Assert-TCMPackage {param($Package)}
  $null=Read-TCMPlan $path -BeforeUpgrade;Assert-M $true 'prepared plan validates with package boundary mocked'
  $c=Read-TCMJson $candidate;$c.DeploymentApproved=$true;Write-TCMJson $candidate $c
  $null=Read-TCMPlan $path;Assert-M $true 'authorized approval flag does not break watchdog recovery'
  $c.EnginePath='tampered';Write-TCMJson $candidate $c;$caught=$false;try{$null=Read-TCMPlan $path}catch{$caught=$true}
  Assert-M $caught 'candidate changes other than approval are rejected'
  Copy-Item -LiteralPath $sealed -Destination $candidate -Force
  Write-TCMJson $old @{Changed=$true};$caught=$false;try{$null=Read-TCMPlan $path -BeforeUpgrade}catch{$caught=$true}
  Assert-M $caught 'preparation drift stops upgrade before network work'
  $null=Read-TCMPlan $path;Assert-M $true 'recovery does not depend on old selection remaining current'
  $caught=$false;try{Assert-TCMBelow (Join-Path $fixture '..\outside.json') $fixture}catch{$caught=$true};Assert-M $caught 'path escape rejected'
  $terminal=Set-TCMState $plan RolledBack 'fixture' @{Exit='hk'}
  Assert-M ((Get-TCMState $path).State -eq 'RolledBack') 'local terminal status survives worker exit'
  # Watchdog: no actual process or network can be touched by these mocks.
  $script:RecoveryCalls=0;$script:KillCalls=0;$script:OwnerTicks=[datetime]::UtcNow.Ticks
  function script:Read-TCMPlan {param($PlanPath,[switch]$BeforeUpgrade)$plan}
  function script:Get-TCMState {param($PlanPath)[pscustomobject]@{State=$script:WatchState}}
  function script:Get-Process {
   param($Name,$Id,$ErrorAction)
   if($script:OwnerAbsent){return}
   $obj=[pscustomobject]@{ProcessName='powershell';StartTime=(New-Object DateTime($script:ObservedTicks,[DateTimeKind]::Utc))}
   $obj|Add-Member ScriptMethod Kill {$script:KillCalls++}
   $obj|Add-Member ScriptMethod WaitForExit {param($Ms)$true}
   $obj|Add-Member ScriptMethod Dispose {}
   $obj
  }
  function script:Invoke-TCMMaintenance {param($PlanPath,[switch]$Recover)if(-not $Recover){throw 'Watchdog may only recover'};$script:RecoveryCalls++}
  $script:WatchState='Applying';$script:OwnerAbsent=$false;$script:ObservedTicks=$script:OwnerTicks
  Watch-TCMMaintenance $path 991 $script:OwnerTicks 0|Out-Null
  Assert-M ($script:KillCalls -eq 1 -and $script:RecoveryCalls -eq 1) 'timeout stops only owned maintenance worker and starts recovery'
  $script:ObservedTicks=$script:OwnerTicks+100000;$script:KillCalls=0;$script:RecoveryCalls=0
  Watch-TCMMaintenance $path 991 $script:OwnerTicks 0|Out-Null
  Assert-M ($script:KillCalls -eq 0 -and $script:RecoveryCalls -eq 1) 'reused PID is never killed'
  $script:WatchState='Complete';$script:RecoveryCalls=0
  Watch-TCMMaintenance $path 991 $script:OwnerTicks 1|Out-Null
  Assert-M ($script:RecoveryCalls -eq 0) 'successful completion disarms watchdog'
  $script:WatchState='Prepared'
  Watch-TCMMaintenance $path 991 $script:OwnerTicks 0|Out-Null
  Assert-M ($script:RecoveryCalls -eq 0) 'preflight failure never triggers a disruptive rollback'
  [pscustomobject]@{Passed=$true;Checks=$script:Checks;RealNetworkChanges=0;RealProcessesStopped=0;Scope='Failure ordering, drift, approved metadata, recovery status, watchdog ownership'}
 } $root (Join-Path (Split-Path $PSScriptRoot -Parent) 'product\assets\sing-box.exe')
}finally{
 Remove-Module TradeChannel.Maintenance -ErrorAction SilentlyContinue
 $full=[IO.Path]::GetFullPath($root);$base=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if(-not $full.StartsWith($base,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notlike 'TC-MaintenanceTest-*'){throw 'Cleanup outside fixture refused'}
 Remove-Item -LiteralPath $full -Recurse -Force
}
