#requires -Version 5.1
[CmdletBinding()]param([string]$PackageRoot,[string]$ReportPath)
$ErrorActionPreference='Stop'
if(-not $PackageRoot){$PackageRoot=Split-Path $PSScriptRoot -Parent}
Import-Module (Join-Path $PackageRoot 'DeploymentTrust.psm1') -Force -DisableNameChecking
$now=[DateTimeOffset]::Parse('2026-10-15T00:00:00Z');$run=[guid]::NewGuid().ToString('D');$server=[guid]::NewGuid().ToString('D');$pin='SHA256:'+('A'*43)
$target=@{Host='EXAMPLE.INVALID.';Port=22;User='root'};$checks=New-Object 'Collections.Generic.List[string]';$failure=''
function Check {param([bool]$Ok,[string]$Message)if(-not $Ok){throw $Message};$checks.Add($Message)}
function CopyDecision {param($Value)$Value|ConvertTo-Json -Depth 6|ConvertFrom-Json}
try{
 $decision=New-TCFirstTrustDecision -RunId $run -ServerRecordId $server -Connection $target -Fingerprint $pin -Now $now
 Check ($decision.ExpiresAtUtc -ceq $now.AddMinutes(30).ToString('o') -and $decision.Origin -ceq 'ExplicitUserConfirmation') 'Explicit decision has an exact fixed 30-minute lifetime'
 $canonical=@{Host='example.invalid';Port=22;User='root'}
 Check (Test-TCFirstTrustDecision $decision $run $server $canonical -Now $now.AddMinutes(29)) 'Canonical same target remains valid before expiry'
 $expiry=$decision.ExpiresAtUtc
 Check ((Resolve-TCDeploymentPinnedFingerprint '' $decision $run $server $canonical -Now $now.AddMinutes(29)) -ceq $pin -and $decision.ExpiresAtUtc -ceq $expiry) 'Read and retry reuse the pin without extending the decision'
 Check (-not (Test-TCFirstTrustDecision $decision $run $server $canonical -Now $now.AddMinutes(30))) 'Decision is invalid at the exact expiration boundary'
 Check ((Resolve-TCDeploymentPinnedFingerprint '' $decision $run $server $canonical -Now $now.AddMinutes(31)) -ceq '') 'Expired decision returns no bypass or replacement pin'
 foreach($field in @('Run','Server','Host','Port','User')){
  $r=$run;$s=$server;$t=$canonical.Clone()
  switch($field){'Run'{$r=[guid]::NewGuid().ToString('D')}'Server'{$s=[guid]::NewGuid().ToString('D')}'Host'{$t.Host='other.invalid'}'Port'{$t.Port=2222}'User'{$t.User='admin'}}
  Check (-not (Test-TCFirstTrustDecision $decision $r $s $t -Now $now)) ($field+' change cannot borrow the old explicit trust')
 }
 foreach($mutation in @('Origin','LongLifetime','FutureConfirmation','MalformedFingerprint')){
  $bad=CopyDecision $decision
  switch($mutation){'Origin'{$bad.Origin='InferredFromPin'}'LongLifetime'{$bad.ExpiresAtUtc=$now.AddHours(1).ToString('o')}'FutureConfirmation'{$bad.ConfirmedAtUtc=$now.AddMinutes(1).ToString('o')}'MalformedFingerprint'{$bad.Fingerprint='ignored'}}
  Check (-not (Test-TCFirstTrustDecision $bad $run $server $canonical -Now $now)) ('Invalid '+$mutation+' cannot authorize connection')
 }
 Check ((Resolve-TCDeploymentPinnedFingerprint $pin $null $run $server $canonical -Now $now.AddDays(1)) -ceq $pin) 'Authenticated persistent pin remains available after UI restart'
 Check ((Resolve-TCDeploymentPinnedFingerprint '' $null $run $server $canonical -Now $now) -ceq '') 'Restart without authenticated pin requires ordinary first trust again'
 $blocked=$false;try{$null=Resolve-TCDeploymentPinnedFingerprint ('SHA256:'+('B'*43)) $decision $run $server $canonical -Now $now}catch{$blocked=$_.Exception.Message -match 'TrustIdentityConflict'}
 Check $blocked 'Valid explicit decision conflicting with saved identity is blocked'
 $blocked=$false;try{$null=Resolve-TCDeploymentPinnedFingerprint 'ignore-host-key' $decision $run $server $canonical -Now $now}catch{$blocked=$_.Exception.Message -match 'TrustPinInvalid'}
 Check $blocked 'Malformed persistent pin is rejected instead of ignored'
}catch{$failure=$_.Exception.Message}
$result=[pscustomobject]@{Passed=(-not $failure);CheckCount=$checks.Count;Checks=$checks.ToArray();Failure=$failure;PackageRoot=$PackageRoot;NetworkCalls=0;Writes=0;Clock='fixed injected UTC boundary';SourceSHA256=(Get-FileHash -LiteralPath (Join-Path $PackageRoot 'DeploymentTrust.psm1')).Hash}
if($ReportPath){[IO.File]::WriteAllText($ReportPath,($result|ConvertTo-Json -Depth 6),(New-Object Text.UTF8Encoding($true)))}
$result|ConvertTo-Json -Depth 6
if($failure){exit 1}
