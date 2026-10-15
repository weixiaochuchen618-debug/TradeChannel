#requires -Version 5.1
[CmdletBinding()]param([string]$PackageRoot,[string]$ReportPath,[switch]$ExpectLegacyDefect)
if(-not $PackageRoot){$PackageRoot=Split-Path $PSScriptRoot -Parent}
$ErrorActionPreference='Stop'
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('tc-runtime-budget-repro-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($fixture)
$script:Root=$fixture;$script:Package=$PackageRoot
. (Join-Path $PackageRoot 'runtime\Invoke-TradeChannel.ps1') -LoadFunctionsOnly
function Assert-TCRuntimeElevation {}
function Open-TCSessionLock {param($Name) New-Object IO.MemoryStream}
function Get-TCPreferences {[pscustomobject]@{ProviderId='';TradeProviderId=''}}
function Get-Process {param($Name) if($Name -eq 'NinjaTrader'){return};throw 'Real process access forbidden by repro fixture'}
function Get-CimInstance {throw 'Real process inventory forbidden by repro fixture'}
function Start-Process {throw 'Real process creation forbidden by repro fixture'}
function Stop-Process {throw 'Real process stop forbidden by repro fixture'}
function Start-Sleep {param($Milliseconds)}
function Start-TCSupervisor {param($ManifestPath) $script:FixtureStarted=$true;[pscustomobject]@{Id=789;HasExited=$false}}
function Stop-TCIdentifiedEngine {param($Identity,$WaitMilliseconds) $script:FixtureEngineStopped=$true}
function Write-TCSessionJson {param($Path,$Value) if(-not $Path.StartsWith($fixture+'\')){throw 'Write escaped fixture'}}
function Get-TCSessionPresentation {param($Evidence,$Preferences) [pscustomobject]@{State='Disconnected'}}
function Get-TCOverview {[pscustomobject]@{State='Connected'}}
function Set-TCRunningSelection {param($Action,$Deployment,$Manifest,$TimeoutSeconds)}
function Get-TCSessionEvidence {
 param([switch]$SkipController)
 $script:Reads++
 $running=$script:Case -eq 'Start' -and $script:FixtureStarted
 $supervisor=$running -or ($script:Case -eq 'StopSupervisor' -and $script:Reads -eq 1)
 $engine=$running -or ($script:Case -eq 'StopEngine' -and $script:Reads -eq 1)
 [pscustomobject]@{
  Identity=[pscustomobject]@{Untracked=$false;Current=$true;SupervisorAlive=$supervisor;EngineAlive=$engine;SessionPresent=($supervisor -or $engine);Engine=[pscustomobject]@{ProcessId=456}}
  Snapshot=[pscustomobject]@{State=$(if($running){'Running'}else{'Disconnected'});SupervisorPid=789;CleanupError=$false}
  Deployment=[pscustomobject]@{ManifestPath=(Join-Path $fixture 'manifest.json')}
  Manifest=[pscustomobject]@{SyntaxValidated=$true;DeploymentApproved=$true}
  Fault=$null;ControlAvailable=$running
 }
}
$rows=@()
try{
 foreach($case in @('Start','StopSupervisor','StopEngine')){
  foreach($budget in @(0,120)){
   $script:Case=$case;$script:Reads=0;$script:FixtureStarted=$false;$script:FixtureEngineStopped=$false
   $action=if($case -eq 'Start'){'Connect'}else{'Disconnect'}
   $failure=$null;$chain=@()
   try{$null=Invoke-TCRuntimeAction -Action $action -TimeoutSeconds $budget}catch{
    $failure=$_.Exception.Message;$ex=$_.Exception
    while($ex){$chain+=$ex.GetType().FullName;$ex=$ex.InnerException}
   }
   $overflow=$chain -contains 'System.OverflowException'
   if(($ExpectLegacyDefect -and (($budget -eq 0 -and -not $overflow) -or ($budget -gt 0 -and $failure))) -or (-not $ExpectLegacyDefect -and $failure)){throw ('Unexpected reproduction result: '+$case+' / '+$budget+' / '+$failure)}
   $rows+=[pscustomobject]@{Scenario=$case;TimeoutSeconds=$budget;OverflowReproduced=$overflow;ExceptionChain=$chain;Failure=$failure;SourceEntry='Invoke-TCRuntimeAction';RealProcessesTouched=0;Writes='Owned temporary fixture only'}
  }
 }
 # Execute the production budget expressions of sibling standalone actions.
 # No controller, registry or network operation from those scripts is invoked.
 . (Join-Path $PackageRoot 'runtime\TradeChannel.OperationBudget.ps1')
 foreach($case in @(@{File='Set-TradeChannelAgents.ps1';Variable='sleepMs';Expected=1800},@{File='Set-TradeChannelDaily.ps1';Variable='left';Expected=8},@{File='Set-TradeChannelExit.ps1';Variable='left';Expected=12})){
  $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PackageRoot ('runtime\'+$case.File)),[ref]$tokens,[ref]$errors)
  $variable=$case.Variable
  $assignment=$ast.Find({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq ('$'+$variable)},$true)
  if(-not $assignment){throw 'Missing production standalone expression'}
  foreach($seconds in @(0,120)){
   $operationBudget=New-TCOperationBudget $seconds;$failure=$null;$value=$null
   try{$value=& ([scriptblock]::Create($assignment.Right.Extent.Text))}catch{$failure=$_.Exception.Message}
   $expectedFailure=[bool]($ExpectLegacyDefect -and $seconds -eq 0)
   if(([bool]$failure -ne $expectedFailure) -or (-not $failure -and $value -ne $case.Expected)){throw ('Sibling budget regression: '+$case.File+' / '+$seconds)}
   $rows+=[pscustomobject]@{Scenario=$case.File;TimeoutSeconds=$seconds;Failure=$failure;Value=$value;SourceEntry='Actual parsed production expression';RealProcessesTouched=0}
  }
 }
 $result=[pscustomobject]@{Passed=$true;ExpectedLegacyDefectConfirmed=[bool]$ExpectLegacyDefect;Cases=$rows;PackageRoot=$PackageRoot;PowerShellVersion=$PSVersionTable.PSVersion.ToString();RealRuntimeModified=$false}
 if($ReportPath){[IO.File]::WriteAllText($ReportPath,($result|ConvertTo-Json -Depth 7),(New-Object Text.UTF8Encoding($true)))}
 $result|ConvertTo-Json -Depth 7
}finally{
 $resolved=[IO.Path]::GetFullPath($fixture)
 if(-not $resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^tc-runtime-budget-repro-[a-f0-9]{32}$'){throw 'Fixture cleanup path rejected'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
}
