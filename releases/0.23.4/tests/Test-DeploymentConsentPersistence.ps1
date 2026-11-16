#requires -Version 5.1
#requires -PSEdition Desktop
[CmdletBinding()]param([string]$PackageRoot,[string]$ReportPath)
$ErrorActionPreference='Stop'
if(-not $PackageRoot){$PackageRoot=Split-Path $PSScriptRoot -Parent}
$root=Join-Path ([IO.Path]::GetTempPath()) ('tc-consent-d1-'+[guid]::NewGuid().ToString('N'))
$flow=Import-Module (Join-Path $PackageRoot 'DeploymentFlow.psm1') -PassThru -DisableNameChecking
$consentModule=Import-Module (Join-Path $PackageRoot 'DeploymentConsent.psm1') -PassThru -DisableNameChecking
Import-Module (Join-Path $PackageRoot 'DeploymentStore.psm1') -DisableNameChecking
Import-Module (Join-Path $PackageRoot 'ServerRegistry.psm1') -DisableNameChecking
$transport=Import-Module (Join-Path $PackageRoot 'DeploymentTransport.psm1') -PassThru -DisableNameChecking
& $transport {function script:Invoke-TCDeployPipe {throw 'Production executor forbidden in consent test'}}
& $flow {function script:Stop-TCDeploySession {param($SessionRef,[switch]$Cancel)[pscustomobject]@{Closed=$true;InstanceId=$SessionRef.InstanceId}}}
$checks=New-Object 'Collections.Generic.List[string]';$passed=$false;$failure='';$children=@()
function Check {param([bool]$Ok,[string]$Message)if(-not $Ok){throw $Message};$checks.Add($Message)}
function CopyValue {param($Value)$Value|ConvertTo-Json -Depth 35|ConvertFrom-Json}
function NewFixture {
 $run=New-TCDeploymentRun -Root $root -Connection @{Host='192.0.2.10';Port=22;User='root';IdentityFile=''} -Name 'Consent fixture'
 $server=Set-TCServerRecord -Root $root -Id $run.ServerRecordId -PinnedFingerprint ('SHA256:'+('A'*43))
 $submission=@{Host='192.0.2.10';Port=22;User='root';TcpPort=443;ServerName='www.bing.com';Transport='Auto'}
 $grant=Set-TCDeploymentPreparationConsent -Root $root -RunId $run.RunId -Submission $submission
 $run.ClientRequest=[pscustomobject]@{ClientPublicKey=('A'*43+'=')}
 $run.SessionRef=[pscustomobject]@{RunId=$run.RunId;InstanceId=[guid]::NewGuid().ToString('D');PipeName=('TCDeploy-'+[guid]::NewGuid().ToString('N'));ProcessId=2147483646;StartTimeUtcTicks='638000000000000000';Root=$root}
 $run.Plan=[pscustomobject]@{PlanId=[guid]::NewGuid().ToString('D');PlanExpiresAt=[DateTimeOffset]::UtcNow.AddMinutes(20).ToString('o');PublicEndpoint='192.0.2.10:51820'}
 & $flow {param($r,$v)Set-TCDeploymentReview $r $v Deploy $v.Plan 'Prepare' 'Fixture';$null=Save-TCDeploymentRun $r $v} $root $run
 [pscustomobject]@{Run=$run;Server=$server;Consent=$grant;Submission=$submission;Path=(Join-Path $root ('deployments\runs\'+$run.RunId+'\preparation-consent.json'))}
}
function SaveFixture {param($Fixture)Write-TCDJson (Join-Path (Split-Path $Fixture.Path -Parent) 'state.json') $Fixture.Run -Compact}
function UseFixture {param($Fixture)Use-TCDeploymentPreparationConsent -Root $root -RunId $Fixture.Run.RunId -ChangeDigest $Fixture.Run.Review.ChangeDigest -ConsentId $Fixture.Consent.ConsentId -SessionInstanceId $Fixture.Run.SessionRef.InstanceId}
try{
 $f=NewFixture
 $disk=[IO.File]::ReadAllText($f.Path)
 Check ($disk -match 'PreparationConsentEnvelope' -and $disk -notmatch '192\.0\.2\.10|PrepareUdpTcpAndLocalDevice|PinnedFingerprint|Password') 'Persisted consent uses a DPAPI user envelope without plaintext authority or credentials'
 $restored=Get-TCDeploymentPreparationConsent -Root $root -RunId $f.Run.RunId
 Check ($restored.ConsentId -ceq $f.Consent.ConsentId -and (Test-TCDeploymentPreparationConsent $restored $f.Run $f.Server -ForReview)) 'Original run restores exact target identity settings and current plan approval'
 $same=Set-TCDeploymentPreparationConsent -Root $root -RunId $f.Run.RunId -Submission $f.Submission
 Check ($same.ConsentId -ceq $restored.ConsentId -and $same.ExpiresAtUtc -ceq $restored.ExpiresAtUtc) 'Reopening or repeated submission never extends the original expiry'
 $receipt=UseFixture $f
 Check ($receipt.Consumed -and -not (UseFixture $f)) 'One plan digest is durably consumed once'
 Import-Module (Join-Path $PackageRoot 'DeploymentConsent.psm1') -Force -DisableNameChecking
 $consentModule=Get-Module DeploymentConsent
 $restored=Get-TCDeploymentPreparationConsent -Root $root -RunId $f.Run.RunId
 Check ($restored.ConsumedDigests.Count -eq 1 -and -not (UseFixture $f)) 'Module reload preserves consumed digests and cannot replay them'

 $pending=New-TCDeploymentRun -Root $root -Connection @{Host='192.0.2.99';Port=22;User='root';IdentityFile=''} -Name 'First authenticated identity'
 $grant=Set-TCDeploymentPreparationConsent -Root $root -RunId $pending.RunId -Submission @{Host='192.0.2.99';Port=22;User='root';TcpPort=443;ServerName='www.bing.com';Transport='Auto'}
 Check ($grant.State -ceq 'PendingIdentity' -and -not $grant.PinnedFingerprint) 'Preparation submission alone never invents first host trust'
 $session=[pscustomobject]@{RunId=$pending.RunId;InstanceId=[guid]::NewGuid().ToString('D');PipeName=('TCDeploy-'+[guid]::NewGuid().ToString('N'));ProcessId=2147483646;StartTimeUtcTicks='638000000000000000';Root=$root}
 $pending.AttemptSessionRef=$session
 & $flow {param($r,$v)$null=Save-TCDeploymentRun $r $v} $root $pending
 $observation=[pscustomobject]@{RunId=$session.RunId;InstanceId=$session.InstanceId;Status='Ready';HasSession=$true;ObservedFingerprint=('SHA256:'+('D'*43));AcceptedFingerprint=('SHA256:'+('D'*43));ObservedHostKeyAlgorithm='ssh-ed25519';AuthenticationGeneration=1;HasMutatingOperations=$false;Connection=@{Host='192.0.2.99';Port=22;User='root'}}
 & $transport {param($value)$script:ConsentObservation=$value;function script:Read-TCDeployObservation {param($SessionRef)$script:ConsentObservation}} $observation
 $null=Set-TCServerRecord -Root $root -Id $pending.ServerRecordId -PinnedFingerprint $observation.ObservedFingerprint -SessionRef $session
 $other=CopyValue $session;$other.InstanceId=[guid]::NewGuid().ToString('D');$rejected=$false
 try{$null=Confirm-TCDeploymentPreparationIdentity -Root $root -RunId $pending.RunId -SessionRef $other}catch{$rejected=$_.Exception.Message -like '*PreparationSessionMismatch*'}
 Check $rejected 'A late callback from another login attempt cannot attach a trusted identity to the consent'
 $bound=Confirm-TCDeploymentPreparationIdentity -Root $root -RunId $pending.RunId -SessionRef $session
 Check ($bound.State -ceq 'Active' -and $bound.PinnedFingerprint -ceq $observation.ObservedFingerprint -and $bound.ExpiresAtUtc -ceq $grant.ExpiresAtUtc) 'Only the original authenticated host observation binds first identity without extending expiry'
 $observation.AcceptedFingerprint='SHA256:'+('E'*43);$rejected=$false
 try{$null=Confirm-TCDeploymentPreparationIdentity -Root $root -RunId $pending.RunId -SessionRef $session}catch{$rejected=$true}
 Check $rejected 'Authenticated-pin mismatch still blocks a consent identity update'

 $f=NewFixture
 $expired=& $consentModule {param($p)Read-TCPreparationConsent $p} $f.Path
 $expired.SubmittedAtUtc=[DateTimeOffset]::UtcNow.AddDays(-2).ToString('o');$expired.ExpiresAtUtc=[DateTimeOffset]::UtcNow.AddDays(-1).ToString('o')
 & $consentModule {param($p,$c)Write-TCPreparationConsent $p $c} $f.Path $expired
 Check (-not (Get-TCDeploymentPreparationConsent -Root $root -RunId $f.Run.RunId) -and -not (UseFixture $f)) 'Expired persisted permission cannot restore or consume a review'
 $rejected=$false;try{$null=Set-TCDeploymentPreparationConsent -Root $root -RunId $f.Run.RunId -Submission $f.Submission}catch{$rejected=$_.Exception.Message -like '*PreparationConsentExpired*'}
 Check $rejected 'Repeated login/submission cannot silently renew an expired permission'
 $f=NewFixture;$f.Run.Plan.PlanExpiresAt=[DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o')
 & $flow {param($r,$v)Set-TCDeploymentReview $r $v Deploy $v.Plan 'Expired plan' 'Fixture';$null=Save-TCDeploymentRun $r $v} $root $f.Run
 Check (-not (UseFixture $f) -and (Get-TCDeploymentPreparationConsent -Root $root -RunId $f.Run.RunId).ConsumedDigests.Count -eq 0) 'An expired but internally consistent remote plan consumes no approval'

 $f=NewFixture
 $mutations=@{
  Run={param($c,$r,$s)$r.RunId=[guid]::NewGuid().ToString('D')}
  Server={param($c,$r,$s)$r.ServerRecordId=[guid]::NewGuid().ToString('D')}
  Target={param($c,$r,$s)$s.Connection.Host='192.0.2.11'}
  User={param($c,$r,$s)$s.Connection.User='other'}
  Port={param($c,$r,$s)$s.Connection.Port=2222}
  Pin={param($c,$r,$s)$s.PinnedHostKey='SHA256:'+('B'*43)}
  IdentityRevision={param($c,$r,$s)$s.IdentityTransitionRevision++}
  Parameters={param($c,$r,$s)$r.TcpPort=8443}
  ChangedPlan={param($c,$r,$s)$r.Plan.PublicEndpoint='192.0.2.11:51820'}
  ChangedReview={param($c,$r,$s)$r.Review.Details='Changed after approval'}
  WrongKind={param($c,$r,$s)$r.Review.Kind='Uninstall'}
  LocalNetwork={param($c,$r,$s)$r.Review.ChangesLocalNetwork=$true}
  Expired={param($c,$r,$s)$c.SubmittedAtUtc=[DateTimeOffset]::UtcNow.AddDays(-2).ToString('o');$c.ExpiresAtUtc=[DateTimeOffset]::UtcNow.AddDays(-1).ToString('o')}
  ExpiredPlan={param($c,$r,$s)$r.Plan.PlanExpiresAt=[DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o')}
  Recovery={param($c,$r,$s)$r.RecoveryRequired=$true}
  IdentityWait={param($c,$r,$s)$r.AccessIssue=@{Kind='IdentityChanged'}}
  Cancellation={param($c,$r,$s)$r.Status='Cancelled'}
 }
 foreach($name in @($mutations.Keys|Sort-Object)){$c=CopyValue $f.Consent;$r=CopyValue $f.Run;$s=CopyValue $f.Server;& $mutations[$name] $c $r $s;Check (-not (Test-TCDeploymentPreparationConsent $c $r $s -ForReview)) ('Reject changed or unsupported permission: '+$name)}
 Check (-not (Use-TCDeploymentPreparationConsent -Root $root -RunId $f.Run.RunId -ChangeDigest $f.Run.Review.ChangeDigest -SessionInstanceId ([guid]::NewGuid().ToString('D')))) 'A different session cannot consume this run approval'
 foreach($kind in @('Management','Authorize','PrepareTcp')){
  $f=NewFixture
  $plan=if($kind -eq 'Management'){[pscustomobject]@{PlanId=[guid]::NewGuid().ToString('D');PlanExpiresAt=[DateTimeOffset]::UtcNow.AddMinutes(10).ToString('o');ChangeDigest=('b'*64)}}else{[pscustomobject]@{ClientPublicKey=$f.Run.ClientRequest.ClientPublicKey}}
  if($kind -eq 'Management'){$f.Run.ManagementPlan=$plan}
  & $flow {param($r,$v,$k,$p)Set-TCDeploymentReview $r $v $k $p 'Prepare' 'Fixture'} $root $f.Run $kind $plan;SaveFixture $f
  Check ([bool](UseFixture $f)) ('Existing full preparation scope can consume '+$kind+' exactly once')
 }

 $f=NewFixture;$null=UseFixture $f
 $f.Run.ApprovedChangeDigest=$f.Run.Review.ChangeDigest;$f.Run.ApprovedTransportChoices=$f.Run.Review.OptionalTcpPreparation;$f.Run.TcpPort=8443;$f.Run.ServerName='www.microsoft.com';$f.Run.Stage='TcpPlan';$f.Run.Status='Running';SaveFixture $f
 Check ([bool](Get-TCDeploymentPreparationConsent -Root $root -RunId $f.Run.RunId)) 'Fallback port and TLS name already covered by a consumed exact review preserve permission'
 $f.Run.ServerName='unapproved.example';SaveFixture $f
 Check (-not (Get-TCDeploymentPreparationConsent -Root $root -RunId $f.Run.RunId)) 'An unapproved fallback target never inherits the preparation permission'

 $f=NewFixture;$null=Invoke-TCDeploymentAdvance -Root $root -RunId $f.Run.RunId -Command Cancel
 $sealed=& $consentModule {param($p)Read-TCPreparationConsent $p} $f.Path
 Check ($sealed.State -ceq 'Revoked' -and $sealed.RevocationReason -ceq 'Cancelled') 'Cancellation revokes durable permission before stopping the executor'
 $f.Run.Status='WaitingUser';SaveFixture $f
 Check (-not (Get-TCDeploymentPreparationConsent -Root $root -RunId $f.Run.RunId)) 'Restoring a cancelled run cannot revive its old approval'
 $f=NewFixture;$broken=Read-TCDJson $f.Path;$broken.Protected='invalid-cipher';Write-TCDJson $f.Path $broken
 $cancelled=Invoke-TCDeploymentAdvance -Root $root -RunId $f.Run.RunId -Command Cancel
 Check ($cancelled.Status -ceq 'Cancelled' -and $cancelled.PreparationConsentRevokedAtUtc -and $cancelled.ConsentCleanupPending) 'Corrupt consent cannot prevent cancellation; a separate durable run marker denies authority'

 $f=NewFixture;$null=Request-TCDeploymentPause -Root $root -RunId $f.Run.RunId
 Check (-not (UseFixture $f)) 'A checkpoint pause blocks automatic preparation until explicit continuation'

 $f=NewFixture
 $draft=[pscustomobject]@{SchemaVersion=1;Revision=2;Entries=@([pscustomobject]@{Id=('DeploymentRun:'+$f.Run.RunId);SourceKind='DeploymentRun';SourceId=$f.Run.RunId;ServerRecordId=$f.Run.ServerRecordId;Discarded=$false;DiscardedAtUtc=[DateTimeOffset]::UtcNow.ToString('o');RestoredAtUtc=[DateTimeOffset]::UtcNow.ToString('o')});Commits=@()}
 Write-TCDJson (Join-Path $root 'deployments\draft-dispositions.json') $draft
 Check (-not (Get-TCDeploymentPreparationConsent -Root $root -RunId $f.Run.RunId)) 'Discard and restore between reads invalidate the original lifecycle binding'

 $f=NewFixture;$journal=Join-Path $root ('local-cleanup\'+[guid]::NewGuid().ToString('D')+'\journal.json')
 Write-TCDJson $journal @{SchemaVersion=1;Id=[guid]::NewGuid().ToString('D');Status='RolledBack';TokenDigest=('f'*64);Result=@{SelectedIds=@('DeploymentRun:'+$f.Run.RunId);DeletedIds=@()}}
 Check (-not (Get-TCDeploymentPreparationConsent -Root $root -RunId $f.Run.RunId)) 'Cleanup rollback cannot restore authority from a quarantined consent file'

 $f=NewFixture;$copy=Join-Path $root ('deployments\runs\'+[guid]::NewGuid().ToString('D')+'\preparation-consent.json');$null=New-TCDDirectory (Split-Path $copy -Parent);[IO.File]::Copy($f.Path,$copy)
 $rejected=$false;try{$null=& $consentModule {param($p)Read-TCPreparationConsent $p} $copy}catch{$rejected=$true}
 Check $rejected 'Copying the envelope to another run path cannot decrypt it'

 $f=NewFixture;$ps51=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
 for($i=0;$i -lt 2;$i++){
  $out=Join-Path $root ('consumer-'+$i+'.json')
  $code='$ErrorActionPreference=''Stop'';Import-Module '''+(Join-Path $PackageRoot 'DeploymentConsent.psm1').Replace("'","''")+''' -DisableNameChecking;$r=Use-TCDeploymentPreparationConsent -Root '''+$root.Replace("'","''")+''' -RunId '''+$f.Run.RunId+''' -ChangeDigest '''+$f.Run.Review.ChangeDigest+''';[IO.File]::WriteAllText('''+$out.Replace("'","''")+''',([bool]$r|ConvertTo-Json))'
  $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
  $children+=Start-Process -FilePath $ps51 -ArgumentList @('-NoProfile','-NonInteractive','-EncodedCommand',$encoded) -WindowStyle Hidden -PassThru
 }
 foreach($child in $children){if(-not $child.WaitForExit(15000) -or $child.ExitCode -ne 0){throw 'Independent consent consumer did not finish'}}
 $a=[IO.File]::ReadAllText((Join-Path $root 'consumer-0.json'))|ConvertFrom-Json;$b=[IO.File]::ReadAllText((Join-Path $root 'consumer-1.json'))|ConvertFrom-Json
 Check (([int][bool]$a+[int][bool]$b) -eq 1) 'Two real PowerShell processes can consume a plan digest only once'
 $passed=$true
}catch{$failure=$_.Exception.Message;throw}
finally{
 foreach($child in $children){if(-not $child.HasExited){$child.Kill();$null=$child.WaitForExit(3000)};$child.Dispose()}
 $result=[pscustomobject]@{Passed=$passed;Count=$checks.Count;Checks=$checks.ToArray();Failure=$failure;PowerShell=$PSVersionTable.PSVersion.ToString();RealRemoteOperations=0;NetworkChanges=0;DPAPIExercised=$true;IndependentProcessConsumers=2}
 if($ReportPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($result|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($true))}
 $result|Select-Object Passed,Count,Failure|ConvertTo-Json
 $full=[IO.Path]::GetFullPath($root);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if($full.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($full) -cmatch '^tc-consent-d1-[a-f0-9]{32}$' -and [IO.Directory]::Exists($full)){Remove-Item -LiteralPath $full -Recurse -Force}
}
