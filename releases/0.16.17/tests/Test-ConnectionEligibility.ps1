#requires -Version 5.1
[CmdletBinding()]param([string]$PackageRoot)
$ErrorActionPreference='Stop'
if(-not $PackageRoot){$PackageRoot=Split-Path $PSScriptRoot -Parent}
Import-Module (Join-Path $PackageRoot 'ProtocolSelection.psm1') -Force -DisableNameChecking
$checks=0
function Check {param([bool]$Ok,[string]$Name) if(-not $Ok){throw $Name};$script:checks++}
$udp=[pscustomobject]@{Id='Udp';PreparationState='Ready';Validation=[pscustomobject]@{Status='Inconclusive';Code='ExpectedExitUnverified';CleanupComplete=$true}}
$tcp=[pscustomobject]@{Id='Tcp';PreparationState='Ready';Validation=[pscustomobject]@{Status='Failed';Code='CandidateForwardingFailed';CleanupComplete=$true}}
$line=[pscustomobject]@{LineId='fixture';Profiles=@($udp,$tcp);Recommendation=@{Status='Inconclusive'}}
Check (-not (Get-TCSavedConnectionPreferenceBlock $line $udp)) 'ExpectedExitUnverified must not revoke an explicit UDP choice'
$udp.Validation.Status='Passed';$udp.Validation.Code='CandidateReachabilityVerified'
Check (-not (Get-TCSavedConnectionPreferenceBlock $line $udp)) 'An unused TCP failure must not block UDP'
$tcp.Validation.CleanupComplete=$false
Check ((Get-TCSavedConnectionPreferenceBlock $line $udp) -eq 'NeedsRecovery') 'Global incomplete cleanup must block every protocol'
$tcp.Validation.CleanupComplete=$true
$udp.Validation.Status='Failed';$udp.Validation.Code='CandidateExitMismatch'
Check ([bool](Get-TCSavedConnectionPreferenceBlock $line $udp)) 'A known exit identity mismatch must block'
$udp.Validation.Status='Failed';$udp.Validation.Code='ProbeTimeout'
Check (-not (Get-TCSavedConnectionPreferenceBlock $line $udp)) 'A timed out check must allow an explicit checked attempt'
$d=Get-TCConnectionEligibility -Line $line -Profile $udp
Check ($d.State -eq 'ReadyWithNotice' -and $d.NextAction -eq 'PreviewConnection' -and $d.ProfileId -eq 'Udp') 'A warning must preserve the exact connection target'
$d=Get-TCConnectionEligibility -Line $line
Check ($d.State -eq 'NeedsCompletion' -and $d.NextAction -eq 'ChooseProfile') 'Missing choice must navigate to existing profiles'
$missing=@{Id='Udp';PreparationState='Missing'}
$d=Get-TCConnectionEligibility -Line $line -Profile $missing
Check ($d.NextAction -eq 'CompleteProfile' -and $d.ProfileId -eq 'Udp') 'Missing configuration must retain line and protocol'
[pscustomobject]@{Passed=$true;Checks=$checks;NetworkChanged=$false}|ConvertTo-Json -Compress
