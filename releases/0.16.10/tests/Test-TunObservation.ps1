#requires -Version 5.1
$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'runtime\Run-TradeChannel.ps1') -LoadFunctionsOnly
$at=[DateTimeOffset]::UtcNow;$state=$null;$checks=0
function Check {param([bool]$Ok,[string]$Name)if(-not $Ok){throw $Name};$script:checks++}
foreach($i in 0..9){$state=Update-TCTunObservation $state Unknown $at.AddMilliseconds(750*$i);Check (-not $state.MustStop -and $state.AbsentSamples -eq 0) 'Read failure became adapter absence'}
Check $state.ShowUncertain 'Prolonged unknown must be visible'
$state=Update-TCTunObservation $state Present $at.AddSeconds(10)
Check (-not $state.MustStop -and -not $state.UnknownSince) 'Trusted observation must reset uncertainty'
foreach($i in 0..7){$state=Update-TCTunObservation $state Absent $at.AddSeconds(11+$i)}
Check ($state.MustStop -and $state.Reason -eq 'TunAbsent') 'Confirmed missing adapter must stop'
$state=Update-TCTunObservation $null IdentityMismatch $at
Check ($state.MustStop -and $state.Reason -eq 'TunIdentityChanged') 'Replaced adapter must stop immediately'
$state=Update-TCTunObservation $null Unknown $at
$state=Update-TCTunObservation $state Unknown $at.AddSeconds(31)
Check ($state.MustStop -and $state.Reason -eq 'TunUnverifiable') 'Unverifiable identity cannot be trusted forever'
[pscustomobject]@{Passed=$true;Checks=$checks;NetworkChanged=$false}|ConvertTo-Json -Compress
