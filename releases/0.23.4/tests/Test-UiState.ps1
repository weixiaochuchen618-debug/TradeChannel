#requires -Version 5.1
$ErrorActionPreference='Stop';$env:PSModulePath=Join-Path $PSHOME 'Modules'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'UiState.psm1') -Force -DisableNameChecking
$count=0
function Check {param([bool]$Pass,[string]$Name);if(-not $Pass){throw $Name};$script:count++}
function Fixture {
 [pscustomobject]@{StateKey='Connected';Running=$true;SessionId='s1';ConfigHash=('A'*64);EnginePid=123;ManifestPath='C:\fixture\current.json';ActiveLineId='line1';ActiveProfileId='Tcp';Mode='rule';Exit='hk';Daily='provider';Agents='Daily';ProviderId='pv1';TradeProviderId='';DesiredDaily='Provider';AgentsSupported=$true;DailySupported=$true;AgentIds=@('claude','chatgpt');AgentCustom=@()}
}
foreach($case in @(@('Connected',$true,'connected'),@('Connected',$false,'idle'),@('Connecting',$false,'busy'),@('Applying',$false,'busy'),@('Disconnecting',$false,'busy'),@('Disconnected',$false,'idle'),@('Unconfigured',$false,'idle'),@('Loading',$false,'idle'),@('Fault',$false,'fault'),@('Unknown',$false,'idle'))){
 $v=Get-TCVisualState -State $case[0] -Running $case[1]
 Check ($v.Icon -eq $case[2]) ('State '+$case[0])
 Check ($v.Title -notmatch '全部正常|业务可用|已停止') 'Visual state cannot invent business health or a stopped process'
}
$o=Fixture;$context=Get-TCExitCheckContext $o
Check $context.Eligible 'A complete active-session context is eligible'
$check=@{Data=[pscustomobject]@{Time=[DateTimeOffset]::UtcNow.ToString('o');ObservedIP='203.0.113.10';ExitHttp=$true;DailyHttp=$true;DailyIP='198.51.100.20';DailyLane='provider';CheckContext=$context;ContextChanged=$false}}
$view=Get-TCExitCheckView $check $o
Check ($view.Current -and $view.TradeIP -eq '203.0.113.10' -and $view.DailyIP -eq '198.51.100.20') 'Current exit facts remain scoped to their own lanes'
foreach($key in @('SessionId','ConfigHash','EnginePid','ManifestPath','ActiveLineId','ActiveProfileId','Mode','Exit','Daily','Agents','ProviderId','TradeProviderId','DesiredDaily')){
 $changed=Fixture
 $changed.$key=if($key -eq 'ConfigHash'){'B'*64}elseif($key -eq 'EnginePid'){124}else{'changed'}
 $result=Get-TCExitCheckView $check $changed
 Check (-not $result.Current -and $result.Status -eq 'Stale' -and -not $result.TradeIP -and -not $result.DailyIP) ('Changed '+$key+' cannot reuse exit facts')
}
$changed=Fixture;$changed.AgentIds=@('claude');Check (-not (Get-TCExitCheckView $check $changed).Current) 'Changed AI list invalidates the inferred-route context'
$changed=Fixture;$changed.AgentIds=@('chatgpt','claude');Check (Get-TCExitCheckView $check $changed).Current 'Reordering the same AI list does not invent a route change'
$check.Data.ContextChanged=$true;Check (-not (Get-TCExitCheckView $check $o).Current) 'A change during measurement rejects the result';$check.Data.ContextChanged=$false
$check.Data.Time=[DateTimeOffset]::UtcNow.AddMinutes(-11).ToString('o');Check (-not (Get-TCExitCheckView $check $o).Current) 'Expired measurements cannot remain green'
$check.Data.Time=[DateTimeOffset]::UtcNow.AddMinutes(2).ToString('o');Check (-not (Get-TCExitCheckView $check $o).Current) 'Future timestamps cannot validate a measurement'
$check.Data.Time=[DateTimeOffset]::UtcNow.ToString('o');$check.Data.ObservedIP='invalid';$result=Get-TCExitCheckView $check $o
Check ($result.Current -and $result.Status -eq 'Failed' -and -not $result.TradeIP) 'A failed measurement is distinct from an incomplete one'
$check.Data.ObservedIP='203.0.113.10';$check.Data.DailyLane='trade';$check.Data.DailyHttp=$false;$result=Get-TCExitCheckView $check $o
Check ($result.DailyPassed -and $result.DailyIP -eq $result.TradeIP) 'Global daily traffic explicitly inherits the measured trade exit'
$check.Data.CheckContext=$null;Check (-not (Get-TCExitCheckView $check $o).Current) 'Legacy unbound exit facts stay historical'
$changed=Fixture;$changed.Running=$false;Check (-not (Get-TCExitCheckView $check $changed).Current) 'Disconnected sessions cannot reuse active exit facts'
[pscustomobject]@{Passed=$true;Assertions=$count;NetworkOperations=0}|ConvertTo-Json
