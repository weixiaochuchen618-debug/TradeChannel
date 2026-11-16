#requires -Version 5.1
[CmdletBinding()]param([string]$PackageRoot,[string]$ReportPath,[switch]$ExpectLegacyDefect,[string]$DownlevelPackageRoot)
$ErrorActionPreference='Stop';$checks=0;$failure=$null
if(-not $PackageRoot){$PackageRoot=Split-Path $PSScriptRoot -Parent}
$module=Import-Module (Join-Path $PackageRoot 'ProtocolSelection.psm1') -Force -PassThru -DisableNameChecking
function Check {param($Ok,$Name)if(-not $Ok){throw $Name};$script:checks++}
function CopyValue {param($Value)ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $Value -Depth 60)}
$now=[DateTimeOffset]::UtcNow;$context=[pscustomobject]@{Status='Available';Fingerprint=('C'*64)}
& $module {$script:NetworkContextReader={param($b)[pscustomobject]@{Status='Available';Fingerprint=('C'*64)}}}
$profile=[pscustomobject]@{Id='Udp';Revision=1;ManifestPath='C:\fixture\immutable\manifest.json';CandidateSHA256=('A'*64);ManifestSHA256=('B'*64);ProbeSHA256=('D'*64);Validation=$null}
$manifest=[pscustomobject]@{EnginePath='C:\fixture\inert.exe';EngineSHA256=('E'*64);ServerPublicKey=('S'*43+'=');ClientPublicKey=('K'*43+'=');ClientAddress='10.78.0.4';ServerEndpoint='192.0.2.20:51820'}
$binding=[pscustomobject]@{NetworkFingerprint=('C'*64);InterfaceId='fixture-only';InterfaceIndex=7;InterfaceName='Fixture';LocalAddress='192.0.2.20'}
$raw=[pscustomobject]@{Status='Passed';Code='CandidateReachabilityVerified';ForwardingPassed=$true;CleanupComplete=$true;CandidateHash=('A'*64);ManifestHash=('B'*64);ConfigHash=('D'*64);EngineSHA256=('E'*64);RunId='a584b46f-f602-439d-8f6a-ac6327889477';CheckedAtUtc=$now.ToString('o');ObservedExitIPv4='198.51.100.1';ExpectedExitIPv4='198.51.100.1';ExpectedExitSource='ServerVerifiedTlsTrace';NetworkFingerprint=('C'*64);ProbeDerivativeRequired=$true;ProbeDerivative=[pscustomobject]@{SchemaVersion=1;BaseCandidateSHA256=('A'*64);BaseManifestSHA256=('B'*64);ProbeSHA256=('D'*64);Binding=$binding;EvidenceId='a584b46f-f602-439d-8f6a-ac6327889477'};PathEvidence=[pscustomobject]@{Kind='PhysicalDirect';Verified=$true;EligibleForRecommendation=$true;NetworkFingerprint=('C'*64);Binding=$binding};Checks=@(@{Name='AddressHttps';Status='Passed'},@{Name='DomainDnsHttps';Status='Passed'})}
try{
 $profile.Validation=ConvertTo-TCProtocolEvidence -Result $raw -Profile $profile -NetworkContext $context -Now $now
 Check $profile.Validation.EligibleForAutomaticSelection 'fixture derived probe must qualify'
 $recommendation=Get-TCProtocolRecommendation -LineId 'fixture-line' -Profiles @($profile) -NetworkContext $context -Now $now
 Check (Test-TCProtocolRecommendationRecorded $recommendation @($profile) $now) 'original complete evidence must verify'
 $saved=New-TCSavedConnectionPreference -LineId 'fixture-line' -Profile $profile -Manifest $manifest -Profiles @($profile) -Recommendation $recommendation -NetworkContext $context -Now $now
 $readback=CopyValue $saved;$valid=Test-TCSavedConnectionPreference $readback 'fixture-line' $profile $manifest -Now $now
 if($ExpectLegacyDefect){Check (-not $valid -and -not $readback.Provenance.Profiles[0].PSObject.Properties['ManifestSHA256']) '0.16.11 must reproduce missing manifest hash readback defect'}
 else{
  Check $valid 'serialized saved preference must verify with derived probe'
  Check ($saved.Source -ceq $recommendation.Source -and $saved.Source -ne 'UserChoice') 'automatic provenance must remain automatic'
  $profile.Validation.Status='Failed';Check (Test-TCSavedConnectionPreference $readback 'fixture-line' $profile $manifest -Now $now.AddDays(2)) 'immutable saved provenance survives mutable health and evidence expiry'
  $bad=CopyValue $readback;$bad.Provenance.Profiles[0].ManifestSHA256=('F'*64)
  Check (-not (Test-TCSavedConnectionPreference $bad 'fixture-line' $profile $manifest)) 'tampered digest rejected'
  & $module {param($p)$p.Digest=PSelSavedDigest $p} $bad
  Check (-not (Test-TCSavedConnectionPreference $bad 'fixture-line' $profile $manifest)) 'even recomputed digest cannot authorize wrong original manifest hash'
  $legacy=CopyValue $readback;$legacy.Provenance.Profiles[0].PSObject.Properties.Remove('ManifestSHA256')
  & $module {param($p)$p.Digest=PSelSavedDigest $p} $legacy
  $repair=Repair-TCSavedConnectionPreferenceSnapshot $legacy 'fixture-line' $profile $manifest @($profile) -Now $now.AddDays(2)
  Check ($repair.Repaired -and $repair.Preference.Source -ceq $legacy.Source -and $repair.Preference.SavedAtUtc -ceq $legacy.SavedAtUtc) 'old missing field repaired with unchanged source and timestamp'
  Check ((Repair-TCSavedConnectionPreferenceSnapshot $repair.Preference 'fixture-line' $profile $manifest @($profile) -Now $now.AddDays(2)).Code -eq 'AlreadyCurrent') 'repair is idempotent'
  Check (-not (Repair-TCSavedConnectionPreferenceSnapshot $legacy 'fixture-line' $profile $manifest @()).Repaired) 'incomplete evidence cannot be repaired'
  $tampered=CopyValue $legacy;$tampered.SavedAtUtc=$now.AddMinutes(-3).ToString('o')
  Check (-not (Repair-TCSavedConnectionPreferenceSnapshot $tampered 'fixture-line' $profile $manifest @($profile)).Repaired) 'legacy invalid digest not washed by migration'
  if($DownlevelPackageRoot){
   $downlevel=@()
   foreach($entry in @(@{Name='new-saved-default';Value=$readback},@{Name='repaired-old-default';Value=$repair.Preference})){
    $shell=[PowerShell]::Create()
    try{
     $null=$shell.AddScript({param($path,$preference,$p,$m,$at)
      $ErrorActionPreference='Stop';Import-Module (Join-Path $path 'ProtocolSelection.psm1') -DisableNameChecking
      Test-TCSavedConnectionPreference -Preference $preference -LineId 'fixture-line' -Profile $p -Manifest $m -Now $at
     }).AddArgument($DownlevelPackageRoot).AddArgument($entry.Value).AddArgument($profile).AddArgument($manifest).AddArgument($now.AddDays(2))
     $value=@($shell.Invoke())
     Check (-not $shell.HadErrors -and $value.Count -eq 1 -and $value[0] -eq $true) ('Actual 0.16.11 validator reads '+$entry.Name+' in a fresh runspace')
     $downlevel+=,[pscustomobject]@{Case=$entry.Name;Accepted=[bool]$value[0];SourceSHA256=(Get-FileHash -LiteralPath (Join-Path $DownlevelPackageRoot 'ProtocolSelection.psm1')).Hash}
    }finally{$shell.Dispose()}
   }
  }
 }
}catch{$failure=$_.Exception.Message}
$result=[pscustomobject]@{Passed=(-not $failure);Checks=$checks;ExpectedLegacyDefect=[bool]$ExpectLegacyDefect;ReadbackValid=$valid;Error=$failure;PackageRoot=$PackageRoot;SourceSHA256=(Get-FileHash (Join-Path $PackageRoot 'ProtocolSelection.psm1')).Hash;NetworkCalls=0;Scope='pure evidence producer, serialization and actual readback validator'}
if($DownlevelPackageRoot){$result|Add-Member NoteProperty DownlevelReadback @($downlevel);$result|Add-Member NoteProperty DownlevelScope 'Saved default metadata only; not a full old client data migration or runtime rollback'}
if($ReportPath){$result|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $ReportPath -Encoding UTF8};$result|ConvertTo-Json -Compress
if($failure){exit 1}
