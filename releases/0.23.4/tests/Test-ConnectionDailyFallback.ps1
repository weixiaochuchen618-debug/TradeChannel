#requires -Version 5.1
[CmdletBinding()]param([string]$PackageRoot='',[Parameter(Mandatory=$true)][string]$ReportPath)
$ErrorActionPreference='Stop';$env:PSModulePath=Join-Path $PSHOME 'Modules'
if(-not $PackageRoot){$PackageRoot=Split-Path $PSScriptRoot -Parent}
$module=Import-Module (Join-Path $PackageRoot 'RuntimeBridge.psm1') -PassThru -DisableNameChecking
$result=& $module {
 $script:FallbackChecks=New-Object 'Collections.Generic.List[string]'
 $script:FallbackTouches=0
 function CheckFallback {param([bool]$Condition,[string]$Name)if(-not $Condition){throw $Name};$script:FallbackChecks.Add($Name)}
 function script:Start-Process {$script:FallbackTouches++;throw 'External processes are forbidden.'}
 function script:Invoke-TCController {
  param($Manifest,[string]$Path,[string]$Method,$Data)
  if($script:FallbackCase.Restoring -and $Path -ceq '/proxies/daily-exit' -and $Method -ceq 'PUT' -and $Data.name -ceq 'provider2'){return}
  $script:FallbackTouches++;throw 'Unexpected trading selector mutation.'
 }
 function script:Resolve-TCProviderTarget {[pscustomobject]@{Tag='provider2';Id='22222222-2222-2222-2222-222222222222'}}
 function script:Read-TCAgentState {[pscustomobject]@{Fixture=$true}}
 function script:Test-TCAgentApplied {return (-not $script:FallbackCase.AgentMismatch)}
 function script:Get-TCOverview {
  $script:FallbackReads++
  $later=$script:FallbackReads -gt 1
  [pscustomobject]@{
   Running=$true;Mode=$(if($later -and $script:FallbackCase.ModeMismatch){'global'}else{'rule'})
   Exit=$(if($later -and $script:FallbackCase.ExitMismatch){'provider1'}else{'hk'})
   Daily=$(if($script:FallbackCase.OtherDaily){'provider1'}elseif($script:FallbackCase.Ready){'provider2'}else{'direct'})
   DailySupported=$true;AgentsSupported=[bool]$script:FallbackCase.AgentMismatch
   DailyReason=$script:FallbackCase.SupervisorReason;DailyIntent='Provider'
   DailyProviderId=$(if($script:FallbackCase.OtherIdentity){'33333333-3333-3333-3333-333333333333'}else{'22222222-2222-2222-2222-222222222222'})
  }
 }
 function script:Invoke-TCCommand {
  param([string]$Action)
  if($Action -eq 'DailyProvider'){
   [pscustomobject]@{Supported=$true;Requested='Provider';Applied=(-not $script:FallbackCase.CommandFallback);Effective=$(if($script:FallbackCase.CommandFallback){'direct'}else{'provider2'});Reason=$(if($script:FallbackCase.CommandFallback){'ForwardingFailed'}else{''});ProviderId='22222222-2222-2222-2222-222222222222';TradingConnectionsAffected=$false}
  }elseif($Action -eq 'Agents'){[pscustomobject]@{Supported=$true;Applied=$true}}
  else{$script:FallbackTouches++;throw 'Unexpected runtime action.'}
 }
 function RunFallbackCase {param([hashtable]$Case,[switch]$MustReject)
  $script:FallbackCase=$Case;$script:FallbackReads=0
  $intent=[pscustomobject]@{Mode='Trading';Exit='HongKong';Daily=$(if($Case.DirectIntent){'Direct'}else{'Provider'});Agents='Daily';ProviderId='22222222-2222-2222-2222-222222222222';AgentIds=@();AgentCustom=@()}
  $payload=[pscustomobject]@{Manifest=[pscustomobject]@{};Intent=$intent;Expected=$(if($Case.Restoring){[pscustomobject]@{Daily='provider2';Mode='rule';Exit='hk'}}else{$null});ProfileId='Udp'}
  $failed=$false;$value=$null
  try{$value=Set-TCConnectionIntent $payload}catch{$failed=$true}
  if($MustReject){CheckFallback $failed $Case.Name}else{CheckFallback (-not $failed) $Case.Name}
  if(-not $MustReject -and -not $Case.Ready -and -not $Case.DirectIntent){
   CheckFallback ($value.DailyApply.Applied -eq $false -and $value.DailyApply.Effective -ceq 'direct') ($Case.Name+' reports actual daily fallback')
   CheckFallback ($intent.Daily -ceq 'Provider' -and $intent.ProviderId -ceq '22222222-2222-2222-2222-222222222222') ($Case.Name+' preserves saved choice')
  }
 }
 try{
  RunFallbackCase @{Name='Ready daily provider retains the verified trading connection';Ready=$true}
  RunFallbackCase @{Name='Direct daily intent retains its exact setting';DirectIntent=$true}
  RunFallbackCase @{Name='Confirmed daily forwarding fallback does not undo the trading connection';CommandFallback=$true}
  RunFallbackCase @{Name='A concurrent supervisor check may retain daily direct';SupervisorReason='Checking'}
  RunFallbackCase @{Name='A confirmed supervisor forwarding failure may retain daily direct';SupervisorReason='ForwardingFailed'}
  RunFallbackCase @{Name='An unexplained daily mismatch is rejected'} -MustReject
  RunFallbackCase @{Name='A fallback for another provider identity is rejected';SupervisorReason='Checking';OtherIdentity=$true} -MustReject
  RunFallbackCase @{Name='Rollback preserves the exact original daily target';SupervisorReason='Checking';Restoring=$true} -MustReject
  RunFallbackCase @{Name='Trading exit mismatch remains rejected during daily fallback';CommandFallback=$true;ExitMismatch=$true} -MustReject
  RunFallbackCase @{Name='Trading mode mismatch remains rejected during daily fallback';CommandFallback=$true;ModeMismatch=$true} -MustReject
  RunFallbackCase @{Name='An unrelated daily provider is not accepted as direct fallback';CommandFallback=$true;OtherDaily=$true} -MustReject
  RunFallbackCase @{Name='Unapplied assistant rules remain rejected';CommandFallback=$true;AgentMismatch=$true} -MustReject
  CheckFallback ($script:FallbackTouches -eq 0) 'No real process, controller or trading mutation was used'
  [pscustomobject]@{Passed=$true;Checks=$script:FallbackChecks.Count;Assertions=$script:FallbackChecks.ToArray();RealMutations=0}
 }catch{[pscustomobject]@{Passed=$false;Checks=$script:FallbackChecks.Count;Assertions=$script:FallbackChecks.ToArray();Failure=$_.Exception.Message;RealMutations=$script:FallbackTouches}}
}
[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($result|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($true))
$result|ConvertTo-Json -Depth 6
if(-not $result.Passed){exit 1}
