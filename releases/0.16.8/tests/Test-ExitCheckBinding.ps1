#requires -Version 5.1
$ErrorActionPreference='Stop';$env:PSModulePath=Join-Path $PSHOME 'Modules'
$package=Split-Path $PSScriptRoot -Parent
$root=Join-Path ([IO.Path]::GetTempPath()) ('TC-ExitCheckBinding-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory((Join-Path $root 'runtime'))
Copy-Item -LiteralPath (Join-Path $package 'UiState.psm1') -Destination $root
$fixtureRunner=@'
param([string]$Url,[string]$Lane)
[pscustomobject]@{CurlExit=0;HTTPStatus=200;ObservedIP=$(if($Lane -eq 'Daily'){'198.51.100.20'}else{'203.0.113.10'})}
'@
[IO.File]::WriteAllText((Join-Path $root 'runtime\Test-SelectedTradeExit.ps1'),$fixtureRunner,(New-Object Text.UTF8Encoding($true)))
[IO.File]::WriteAllText((Join-Path $root 'manifest.json'),'{}',[Text.Encoding]::UTF8)
$module=Import-Module (Join-Path $package 'RuntimeBridge.psm1') -PassThru -Force -DisableNameChecking
try{
 & $module {
  param($FixtureRoot)
  $script:Package=$FixtureRoot;$script:Root=$FixtureRoot;$script:Checks=0
  function script:Assert-TCRealRuntimeContext {}
  function script:Assert-TCConnectionDiagnosticRoot {}
  function script:Invoke-TCController {throw 'Live controller access is forbidden'}
  function script:Get-CimInstance {throw 'Process access is forbidden'}
  function script:Get-Process {throw 'Process access is forbidden'}
  function script:Start-Process {throw 'Process launch is forbidden'}
  function script:Get-TCInstalledDeployment {[pscustomobject]@{ManifestPath=(Join-Path $script:Root 'manifest.json')}}
  function script:Get-TCExitLatency {158}
  function script:Get-TCOverview {
   $script:Reads++
   $o=[pscustomobject]@{StateKey='Connected';Running=$true;SessionId='s1';ConfigHash=('A'*64);EnginePid=123;ManifestPath=(Join-Path $script:Root 'manifest.json');ActiveLineId='line1';ActiveProfileId='Udp';Mode='rule';Exit='hk';Daily='provider';Agents='Daily';ProviderId='pv';TradeProviderId='';DesiredDaily='Provider';AgentsSupported=$true;DailySupported=$true;AgentIds=@('claude');AgentCustom=@()}
   if($script:Reads -gt 1 -and $script:Change){$o.($script:Change)=$script:ChangeValue}
   $o
  }
  foreach($case in @(@('',''),@('SessionId','new-session'),@('ActiveProfileId','Tcp'),@('ConfigHash',('B'*64)),@('Exit','provider-trade'),@('Daily','direct'),@('Running',$false))){
   $script:Reads=0;$script:Change=$case[0];$script:ChangeValue=$case[1]
   $result=Test-TCActiveConnection
   $script:Checks++
   if($result.ContextChanged -ne [bool]$script:Change -or $result.AgentEvidenceSource -ne 'RuleInference' -or $result.BusinessValidation -ne 'NotTested'){throw 'Actual CheckActive did not preserve its before/after evidence contract'}
   $script:Reads=0;$script:Change='';$o=Get-TCOverview
   $view=Get-TCExitCheckView @{Data=$result} $o
   $script:Checks++
   if($view.Current -eq [bool]$case[0]){throw 'Measurement during a context change was accepted'}
  }
  [pscustomobject]@{Passed=$true;Assertions=$script:Checks;ActualCheckActiveExercised=$true;NetworkOperations=0}
 } $root|ConvertTo-Json
}finally{
 Remove-Module RuntimeBridge -ErrorAction SilentlyContinue
 $full=[IO.Path]::GetFullPath($root);$boundary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if(-not $full.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notmatch '^TC-ExitCheckBinding-[a-f0-9]{32}$'){throw 'Fixture cleanup boundary rejected'}
 Remove-Item -LiteralPath $full -Recurse -Force
}
