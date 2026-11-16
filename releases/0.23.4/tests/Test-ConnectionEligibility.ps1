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
Check (-not (Get-TCSavedConnectionPreferenceBlock $line $udp)) '0.18.4: an old exit-mismatch test result is a notice, not a block; the transaction re-verifies the exit after connecting and rolls back'
$udp.Validation.Status='Failed';$udp.Validation.Code='ProbeTimeout'
Check (-not (Get-TCSavedConnectionPreferenceBlock $line $udp)) 'A timed out check must allow an explicit checked attempt'
$d=Get-TCConnectionEligibility -Line $line -Profile $udp
Check ($d.State -eq 'ReadyWithNotice' -and $d.NextAction -eq 'PreviewConnection' -and $d.ProfileId -eq 'Udp') 'A warning must preserve the exact connection target'
$d=Get-TCConnectionEligibility -Line $line
Check ($d.State -eq 'NeedsCompletion' -and $d.NextAction -eq 'ChooseProfile') 'Missing choice must navigate to existing profiles'
$missing=@{Id='Udp';PreparationState='Missing'}
$d=Get-TCConnectionEligibility -Line $line -Profile $missing
Check ($d.NextAction -eq 'CompleteProfile' -and $d.ProfileId -eq 'Udp') 'Missing configuration must retain line and protocol'
# --- 0.18.4: a test that did not run, or an old test result, never blocks a connection ------------
foreach($pair in @(@('Failed','ConfigurationChanged'),@('Failed','ProbePreparationFailed'),@('Inconclusive','LocalCheckUnavailable'),@('Failed','EngineMismatch'),@('Failed','HashMismatch'),@('Inconclusive','NetworkChangedDuringComparison'))){
 $udp.Validation.Status=$pair[0];$udp.Validation.Code=$pair[1];$tcp.Validation.Status=$pair[0];$tcp.Validation.Code=$pair[1]
 $d=Get-TCConnectionEligibility -Line $line -Profile $udp
 Check ($d.CanConnect -and $d.State -eq 'ReadyWithNotice' -and $d.Message -match '连接时会自动测试') ('evidence '+$pair[1]+' only produces a notice')
}
$udp.Validation.Status='Passed';$udp.Validation.Code='CandidateReachabilityVerified';$tcp.Validation.Status='Passed';$tcp.Validation.Code='CandidateReachabilityVerified'
$blockedLine=[pscustomobject]@{LineId='fixture';Profiles=@($udp,$tcp);Recommendation=@{Status='Inconclusive'};ServerConnectionBlock='ServerArchived';ServerConnectionMessage='archived'}
$d=Get-TCConnectionEligibility -Line $blockedLine -Profile $udp
Check (-not $d.CanConnect -and $d.NextAction -eq 'CheckServerIdentity') 'server identity archived/changed still blocks'
foreach($code in @('ActiveIdentity','IdentityInUse')){$udp.Validation.Code=$code;$udp.Validation.Status='Blocked';Check (-not (Get-TCConnectionEligibility -Line $line -Profile $udp).CanConnect) ('device identity in use still blocks: '+$code)}
$udp.Validation.Status='Failed';$udp.Validation.Code='ProbeCleanupFailed';$udp.Validation.CleanupComplete=$false
Check ((Get-TCConnectionEligibility -Line $line -Profile $udp).Code -eq 'NeedsRecovery') 'incomplete probe cleanup still needs recovery'
$udp.Validation.CleanupComplete=$true;$udp.Validation.Status='OutcomeUnknown';$udp.Validation.Code='X'
Check ((Get-TCConnectionEligibility -Line $line -Profile $udp).Code -eq 'NeedsRecovery') 'unknown outcome still needs recovery'
$udp.Validation.Status='Passed';$udp.Validation.Code='CandidateReachabilityVerified'
$d=Get-TCConnectionEligibility -Line $line -Profile ([pscustomobject]@{Id='Udp';PreparationState='Missing'})
Check (-not $d.CanConnect -and $d.NextAction -eq 'CompleteProfile') 'unprepared configuration still blocks'
[pscustomobject]@{Passed=$true;Checks=$checks;NetworkChanged=$false}|ConvertTo-Json -Compress
