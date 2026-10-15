#requires -Version 5.1
[CmdletBinding()]param([string]$PackageRoot,[string]$ReportPath)
$ErrorActionPreference='Stop';$env:PSModulePath=Join-Path $PSHOME 'Modules'
if(-not $PackageRoot){$PackageRoot=Split-Path $PSScriptRoot -Parent};$PackageRoot=[IO.Path]::GetFullPath($PackageRoot)
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('tc-line-attribution-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory((Join-Path $fixture 'runtime'))
Copy-Item -LiteralPath (Join-Path $PackageRoot 'UiState.psm1') -Destination $fixture
[IO.File]::WriteAllText((Join-Path $fixture 'manifest.json'),'{}',[Text.UTF8Encoding]::new($true))
$runner=@'
param([string]$Url,[string]$Lane,[int]$TimeoutSeconds,[int]$ConnectTimeoutSeconds)
[IO.File]::AppendAllText((Join-Path $PSScriptRoot 'calls.txt'),($Url+[Environment]::NewLine))
[pscustomobject]@{CurlExit=0;HTTPStatus=200;ObservedIP='198.51.100.20'}
'@
[IO.File]::WriteAllText((Join-Path $fixture 'runtime\Test-SelectedTradeExit.ps1'),$runner,[Text.UTF8Encoding]::new($true))
$bridge=Import-Module (Join-Path $PackageRoot 'RuntimeBridge.psm1') -PassThru -Force -DisableNameChecking
$lineCheck=Import-Module (Join-Path $PackageRoot 'LineConnectionCheck.psm1') -PassThru -Force -DisableNameChecking
. (Join-Path $PackageRoot 'ui\LineCardState.ps1')
$script:Checks=New-Object 'Collections.Generic.List[string]';$script:Cases=New-Object 'Collections.Generic.List[object]'
function Check {param($ok,$text)if(-not $ok){throw $text};$script:Checks.Add($text)}
function Overview {
 [pscustomobject]@{StateKey='Connected';Running=$true;SessionId='audit-session';ConfigHash=('A'*64);EnginePid=123;ManifestPath=(Join-Path $fixture 'manifest.json');ActiveLineId='audit-line';ActiveProfileId='Tcp';Mode='rule';Exit='hk';Daily='direct';Agents='Daily';ProviderId='audit-provider';TradeProviderId='';DesiredDaily='Direct';AgentsSupported=$false;DailySupported=$false;AgentIds=@();AgentCustom=@()}
}
$line=[pscustomobject]@{LineId='audit-line';Name='Audit line';Revision=8;Endpoint='203.0.113.10:443';DefaultVerified=$true;SavedConnectionPreference=@{ProfileId='Tcp'};ServerConnectionBlock='';Profiles=@([pscustomobject]@{Id='Tcp';PreparationState='Ready';Validation=$null})}
& $bridge {
 param($FixtureRoot)
 $script:Package=$FixtureRoot;$script:Root=$FixtureRoot
 function script:Assert-TCRealRuntimeContext {}
 function script:Assert-TCConnectionDiagnosticRoot {}
 function script:Get-TCOverview {
  $script:Reads++;$v=$script:AuditOverview|ConvertTo-Json -Depth 12|ConvertFrom-Json
  if($script:DriftAt -gt 0 -and $script:Reads -ge $script:DriftAt){$v.($script:DriftKey)=$script:DriftValue}
  return $v
 }
 function script:Get-TCInstalledDeployment {[pscustomobject]@{ManifestPath=(Join-Path $script:Root 'manifest.json')}}
 function script:Get-TCExitLatency {10}
 foreach($actor in @('Invoke-TCController','Get-CimInstance','Get-Process','Start-Process','Stop-Process','Invoke-TCCommand','Invoke-WebRequest','Invoke-RestMethod')){Set-Item ('Function:script:'+$actor) {throw 'Production actor forbidden in attribution fixture'}}
} $fixture
& $lineCheck {
 param($FixtureRoot,$Package,$Bridge,$Line)
 $script:AuditRoot=$FixtureRoot;$script:AuditPackage=$Package;$script:AuditBridge=$Bridge;$script:AuditLine=$Line
 function script:Import-Module {param([string]$Name,[switch]$DisableNameChecking)
  if([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Name)) -cne $script:AuditPackage -or [IO.Path]::GetFileName($Name) -notin @('LineStore.psm1','RuntimeBridge.psm1')){throw 'Unexpected module outside active check fixture'}
 }
 function script:Get-TCLine {param($Root,$Id)if($Root -cne $script:AuditRoot -or $Id -cne $script:AuditLine.LineId){throw 'Fixture boundary rejected'};$script:AuditLine}
 function script:Get-TCOverview {& $script:AuditBridge {Get-TCOverview}}
 function script:Test-TCActiveConnection {& $script:AuditBridge {Test-TCActiveConnection}}
 function script:Test-TCCandidateProbe {throw 'No candidate probe may run on the active identity'}
 function script:Set-TCLineProfileValidation {throw 'No persistence may run for an active check'}
} $fixture $PackageRoot $bridge $line
function Configure {param($State,[int]$DriftAt=0,[string]$Key='',$Value=$null)
 & $bridge {param($o,$at,$key,$value)$script:AuditOverview=$o;$script:Reads=0;$script:DriftAt=$at;$script:DriftKey=$key;$script:DriftValue=$value} $State $DriftAt $Key $Value
 $log=Join-Path $fixture 'runtime\calls.txt';if([IO.File]::Exists($log)){[IO.File]::Delete($log)}
}
function RunActual {& $lineCheck {param($Root) Invoke-TCLineProfileCheck -Root $Root -Id 'audit-line' -ProfileId 'Tcp' -ExpectedRevision 8} $fixture}
function Card {param($CheckResult,$State)
 $runtime=[pscustomobject]@{Running=$State.Running;LineId=$State.ActiveLineId;ProfileId=$State.ActiveProfileId;TradeInUse=($State.Exit -eq 'hk');SessionId=$State.SessionId;ConfigHash=$State.ConfigHash;CheckContext=(Get-TCExitCheckContext $State);Validation=$CheckResult}
 GetLineCardViewModel $line $runtime $null
}
$passed=$false;$failure='';$stack=''
try{
 foreach($exit in @('provider-trade','direct')){
  $o=Overview;$o.Exit=$exit;$o.TradeProviderId='audit-provider';Configure $o;$r=RunActual;$v=Card $r.Check $o
  Check ($r.Code -ceq 'TargetNotSelectedExit' -and $r.Status -ceq 'Blocked' -and -not [IO.File]::Exists((Join-Path $fixture 'runtime\calls.txt'))) ('Same line/profile with '+$exit+' blocks before any network actor')
  Check (@($v.Protocols|Where-Object Tone -eq 'ok').Count -eq 0 -and $v.SavedDefaultProfileId -ceq 'Tcp') 'Provider/direct state stays uncolored and preserves default'
  $script:Cases.Add([pscustomobject]@{Case=$exit;Code=$r.Code;RequestedTarget=$r.RequestedTarget;Health=@($v.Protocols|Where-Object Id -eq Tcp)[0].Health;MeasuredNetworkCalls=0})
 }
 $o=Overview;Configure $o;$r=RunActual;$good=$r.Check;$v=Card $good $o
 Check ($r.Status -ceq 'Passed' -and (Test-TCLineCheckBinding $good (Get-TCExitCheckContext $o) 'audit-line' Tcp)) 'Real check and wrapper preserve a complete current measurement'
 Check (@($v.Protocols|Where-Object {$_.Id -ceq 'Tcp' -and $_.Tone -eq 'ok'}).Count -eq 1) 'Only full current self-hosted context gives a green protocol card'
 Check ($good.ServerAttributionVerified -eq $false -and $good.ExitAttribution -ceq 'SelectedTradeExit') 'Fresh context does not invent authoritative server attribution'
 Check ($r.RequestedTarget.LineId -ceq 'audit-line' -and $r.MeasuredContext.Fields.ActiveLineId -ceq 'audit-line') 'Requested target is separated from measured context'
 foreach($key in @('SessionId','ConfigHash','EnginePid','ManifestPath','ActiveLineId','ActiveProfileId','Mode','Exit','Daily','Agents','ProviderId','TradeProviderId','DesiredDaily','AgentsSupported','DailySupported','AgentIds','AgentCustom')){
  $changed=Overview
  $value=switch($key){'ConfigHash'{'B'*64}'EnginePid'{124}'ActiveProfileId'{'Udp'}'Mode'{'global'}'AgentsSupported'{$true}'DailySupported'{$true}'AgentIds'{,@('changed')}'AgentCustom'{,@([pscustomobject]@{Kind='Program';Value='changed.exe'})}default{'changed'}}
  $changed.$key=$value;$v=Card $good $changed
  Check (-not (Test-TCLineCheckBinding $good (Get-TCExitCheckContext $changed) 'audit-line' Tcp) -and @($v.Protocols|Where-Object Tone -eq 'ok').Count -eq 0) ('Changing '+$key+' immediately invalidates old green evidence')
 }
 foreach($field in @('MeasuredContext','Time','ProofVersion','ContextChanged')){
  $bad=$good|ConvertTo-Json -Depth 20|ConvertFrom-Json;$bad.PSObject.Properties.Remove($field);$v=Card $bad $o
  Check (@($v.Protocols|Where-Object Tone -eq 'ok').Count -eq 0) ('Missing '+$field+' remains historical evidence')
 }
 foreach($field in @('EnginePid','TradeProviderId','AgentCustom')){
  $bad=$good|ConvertTo-Json -Depth 20|ConvertFrom-Json;$bad.MeasuredContext.Fields.PSObject.Properties.Remove($field)
  Check (-not (Test-TCLineCheckBinding $bad (Get-TCExitCheckContext $o) 'audit-line' Tcp)) ('Copied key with incomplete measured '+$field+' cannot pass binding')
 }
 foreach($time in @([DateTimeOffset]::UtcNow.AddMinutes(-11),[DateTimeOffset]::UtcNow.AddMinutes(2))){$bad=$good|ConvertTo-Json -Depth 20|ConvertFrom-Json;$bad.Time=$time.ToString('o');Check (-not (Test-TCLineCheckBinding $bad (Get-TCExitCheckContext $o) 'audit-line' Tcp)) 'Expired/future measurement is not current'}
 $legacy=[pscustomobject]@{LineId='audit-line';ProfileId='Tcp';SessionId=$o.SessionId;ConfigHash=$o.ConfigHash;Status='Passed';ForwardingPassed=$true;ServerAttributionVerified=$false};$v=Card $legacy $o
 Check (@($v.Protocols|Where-Object Tone -eq 'ok').Count -eq 0 -and $v.SavedDefaultProfileId -ceq 'Tcp' -and $legacy.ServerAttributionVerified -eq $false) 'Legacy result does not clear default, force deployment, or upgrade evidence'
 Configure (Overview) 2 'ActiveLineId' 'other-line';$r=RunActual
 Check ($r.Status -ceq 'Inconclusive' -and $r.Check.LineId -ceq 'other-line' -and $r.Check.MeasuredContext.Fields.ActiveLineId -ceq 'other-line' -and $r.RequestedTarget.LineId -ceq 'audit-line') 'Race before measurement preserves actual identity instead of overwriting it from the plan'
 Configure (Overview) 3 'Exit' 'provider-trade';$r=RunActual
 Check ($r.Status -ceq 'Inconclusive' -and $r.Check.ContextChanged -and -not $r.Check.ForwardingPassed -and $r.Check.MeasuredContext.Fields.Exit -ceq 'hk') 'Mid-measurement change keeps measured context and marks changed/inconclusive'
 $script:Cases.Add([pscustomobject]@{Case='MidMeasurementProviderChange';Code=$r.Code;ContextChanged=$r.Check.ContextChanged;RequestedTarget=$r.RequestedTarget;MeasuredContext=$r.MeasuredContext})
 $passed=$true
}catch{$failure=$_.Exception.Message;$stack=$_.ScriptStackTrace}
finally{
 $report=[pscustomobject]@{Passed=$passed;Assertions=$script:Checks.Count;Checks=@($script:Checks.ToArray());Cases=@($script:Cases.ToArray());Failure=$failure;Stack=$stack;ActualLineCheck=$true;ActualRuntimeCheck=$true;ActualCardProjection=$true;NetworkOperations=0;ProductionWrites=0;PowerShellVersion=$PSVersionTable.PSVersion.ToString()}
 if($ReportPath){$report|ConvertTo-Json -Depth 20|Set-Content -LiteralPath $ReportPath -Encoding UTF8};$report|Select-Object Passed,Assertions,Failure,Stack,ActualLineCheck,ActualRuntimeCheck,ActualCardProjection|ConvertTo-Json
 Remove-Module RuntimeBridge,LineConnectionCheck -ErrorAction SilentlyContinue
 $full=[IO.Path]::GetFullPath($fixture);$boundary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if(-not $full.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -cnotmatch '^tc-line-attribution-[a-f0-9]{32}$'){throw 'Cleanup boundary rejected'}
 Remove-Item -LiteralPath $full -Recurse -Force
}
if(-not $passed){throw $failure}

