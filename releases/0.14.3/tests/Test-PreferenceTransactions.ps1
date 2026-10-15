#requires -Version 5.1
# All channel actions are mocked; only a disposable preference file is written.
$ErrorActionPreference='Stop';$env:PSModulePath=Join-Path $PSHOME 'Modules'
$module=Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'RuntimeBridge.psm1') -Force -PassThru -DisableNameChecking
$fixtureParent=Join-Path (Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent) 'reports\release-0.11.0';$null=[IO.Directory]::CreateDirectory($fixtureParent)
$work=Join-Path $fixtureParent ('.preferences-fixture-'+[guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($work)
try {
 & $module {
  param($FixtureRoot)
  $script:Root=$FixtureRoot;$script:Checks=0;$script:PriorId='11111111-1111-1111-1111-111111111111';$script:NewId='22222222-2222-2222-2222-222222222222'
  $script:A='33333333-3333-3333-3333-333333333333';$script:B='44444444-4444-4444-4444-444444444444'
  $script:Old=Join-Path $FixtureRoot 'old.json';$script:New=Join-Path $FixtureRoot 'new.json';$script:Current=$script:Old;$script:Failure=$false;$script:ExitNow='hk'
  function script:Check {param($Ok,$Text) if(-not $Ok){throw $Text};$script:Checks++}
  function script:Get-Process {param($Name,$ErrorAction)}
  function script:Get-TCRegisteredNodes {@([pscustomobject]@{id=$script:PriorId;manifestPath=$script:Old},[pscustomobject]@{id=$script:NewId;manifestPath=$script:New})}
  function script:Get-TCOverview {[pscustomobject]@{Running=$true;CanConnect=$false;StateKey='Connected';Mode='rule';ControllerModes=@('rule','global');Exit=$script:ExitNow;Daily='direct';DailySupported=$true;AgentsSupported=$false;ManifestPath=$script:Current;ConnectedSince='fixture-session'}}
  function script:Invoke-TCCommand {param($Action) if($Action -notin @('DailyDirect','HongKong')){throw 'Unexpected channel action.'}}
  function script:Invoke-TCManifestConnectionSwitch {param($ManifestPath,$Intent,[switch]$SessionLockHeld) if($script:Failure){throw 'Injected candidate failure'};$save=@{};foreach($property in $Intent.PSObject.Properties){$save[$property.Name]=$property.Value};$null=Save-TCPreferences @save;$script:Current=$ManifestPath;$script:ExitNow=if($Intent.Exit -eq 'HongKong'){'hk'}else{'provider-trade'};[pscustomobject]@{Status='Completed';Message='simulated'}}
  Write-TCSessionJson $script:Old @{Providers=@()}
  Write-TCSessionJson $script:New @{Providers=@()}
  $null=Save-TCPreferences -NodeId $script:PriorId -Mode Trading -Exit HongKong -Daily Provider -ProviderId $script:A -TradeProviderId $script:A
  $script:Failure=$true;$caught=$false;try{$null=Invoke-TCSession Apply -NodeId $script:NewId}catch{$caught=$true}
  $p=Get-TCPreferences
  Check ($caught -and $p.NodeId -eq $script:PriorId -and $p.Daily -eq 'Provider' -and $p.ProviderId -eq $script:A -and $p.TradeProviderId -eq $script:A) 'Failed node activation did not restore all previous preferences.'
  $script:Failure=$false
  $r=Invoke-TCSession Apply -NodeId $script:NewId
  Check ((Get-TCPreferences).Daily -eq 'Direct' -and $r.PreferenceFallback) 'Missing daily provider did not downgrade with a visible reason.'
  $script:Current=$script:Old;$script:ExitNow='hk'
  Write-TCSessionJson $script:New @{Providers=@(@{Id=$script:B;Slot=1;Tag='provider';TradeTag='provider-trade';Name='different-provider';Kind='custom';Port=12081;TradePort=12082;Directory='C:\Fixture\Provider';Programs=@()})}
  $null=Save-TCPreferences -NodeId $script:PriorId -Exit Provider -Daily Provider -ProviderId $script:A -TradeProviderId $script:A
  $null=Invoke-TCSession Apply -NodeId $script:NewId -Exit Provider
  Check ($script:ExitNow -eq 'hk' -and -not (Get-TCPreferences).TradeProviderId) 'Missing trade identity silently selected another provider.'
  $prior=Get-Content -LiteralPath (Join-Path $FixtureRoot 'ui-preferences.json') -Raw;$caught=$false
  try{$null=Invoke-TCSession Apply -ProviderId $script:A}catch{$caught=$true}
  Check ($caught -and (Get-Content -LiteralPath (Join-Path $FixtureRoot 'ui-preferences.json') -Raw) -ceq $prior) 'Explicit unknown identity was silently downgraded or saved.'
  [pscustomobject]@{Passed=$true;Checks=$script:Checks;RealNetworkChanges=0;FullRollback=$true;ImplicitTradeReplacement=$false}
 } $work
}finally{
 Remove-Module RuntimeBridge -ErrorAction SilentlyContinue
 $full=[IO.Path]::GetFullPath($work);$base=[IO.Path]::GetFullPath($fixtureParent).TrimEnd('\')+'\'
 if(-not $full.StartsWith($base,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notmatch '^\.preferences-fixture-[0-9a-f]{32}$'){throw 'Cleanup rejected.'}
 Remove-Item -LiteralPath $full -Recurse -Force
}
