#requires -Version 5.1
[CmdletBinding()]param([string]$PackageRoot)
$ErrorActionPreference='Stop';if(-not $PackageRoot){$PackageRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent}
Import-Module (Join-Path $PackageRoot 'DeploymentPairing.psm1') -Force -DisableNameChecking
$checks=New-Object 'Collections.Generic.List[string]'
function Assert-Check {param([bool]$Condition,[string]$Name)if(-not $Condition){throw ('FAILED: '+$Name)};$checks.Add($Name)}
$fixture=Join-Path $PackageRoot 'tests\pairing_fixture_backend.py';$start=New-Object Diagnostics.ProcessStartInfo;$start.FileName='python.exe';$start.Arguments='"'+$fixture+'"';$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true;$start.StandardOutputEncoding=New-Object Text.UTF8Encoding($false);$start.StandardErrorEncoding=New-Object Text.UTF8Encoding($false)
$process=New-Object Diagnostics.Process;$process.StartInfo=$start;$null=$process.Start();$stderr=$process.StandardError.ReadToEndAsync()
$root=Join-Path $PackageRoot ('deployment\test-runs\crosspair-'+[guid]::NewGuid().ToString('N'))
function Invoke-Fixture {param([string]$Action,$InputData=@{})
 $process.StandardInput.WriteLine((@{Action=$Action;Input=$InputData}|ConvertTo-Json -Depth 24 -Compress));$process.StandardInput.Flush();$line=$process.StandardOutput.ReadLineAsync()
 if(-not $line.Wait(30000)){throw ('Fixture timeout: '+$Action)};if(-not $line.Result){throw 'Fixture exited without a response.'};$line.Result|ConvertFrom-Json
}
try{
 $created=Invoke-Fixture invite_create @{DeviceName='Second Windows PC'};Assert-Check $created.Ok 'Python/OpenSSL server creates real signed invitation'
 $invite=$created.Data.Invite;$inspection=Get-TCPairInvite -Invite $invite -AllowUnconfirmed
 Assert-Check ($inspection.Payload.ManagementSigningPublicKey.kty -ceq 'RSA') 'Jose verifies actual OpenSSL RS256 server signature'
 $request=New-TCPairRequest -Invite $invite -ConfirmedFingerprint $inspection.Fingerprint -DeviceName 'Second Windows PC' -Root $root
 $authorized=Invoke-Fixture authorize_external @{InviteId=$created.Data.InviteId;PairRequest=$request.PairRequest}
 Assert-Check ($authorized.Ok -and $authorized.Data.RequestDigest -ceq $request.RequestDigest) 'OpenSSL validates Jose RSA3072 request and canonical digest'
 $duplicate=Invoke-Fixture authorize_external @{InviteId=$created.Data.InviteId;PairRequest=$request.PairRequest}
 $devices=Invoke-Fixture devices @{}
 Assert-Check ($duplicate.Ok -and $devices.Data.Total -eq 2) 'Repeated cross-platform authorization does not add another Peer'
 $sealed=Protect-TCPairAuthorization -SignedAuthorization $authorized.Data.Authorization -PairRequest $request.PairRequest -Invite $invite
 $complete=Complete-TCPairAuthorization -EncryptedAuthorization $sealed.EncryptedAuthorization -EnrollmentId $request.EnrollmentId -Root $root
 Assert-Check ((Test-Path -LiteralPath $complete.ConfigPath) -and $complete.DeviceId -ceq $request.DeviceId) 'OpenSSL server authorization crosses JWE to receiving Windows private key'
 Import-Module (Join-Path $PackageRoot 'DeploymentFlow.psm1') -DisableNameChecking
 Import-Module (Join-Path $PackageRoot 'DeploymentStore.psm1') -DisableNameChecking
 Import-Module (Join-Path $PackageRoot 'NodeStore.psm1') -DisableNameChecking
 $candidate=Complete-TCPairCandidate -Root $root -EnrollmentId $request.EnrollmentId -EncryptedAuthorization $sealed.EncryptedAuthorization -Name 'Invited fixture candidate'
 $retryCandidate=Complete-TCPairCandidate -Root $root -EnrollmentId $request.EnrollmentId -EncryptedAuthorization $sealed.EncryptedAuthorization -Name 'Invited fixture candidate'
 Assert-Check ($candidate.Id -ceq $retryCandidate.Id -and @(Get-TCNodes (Join-Path $root 'Product')).Count -eq 1) 'Invited candidate retry reuses one imported node'
 $registry=Import-Module (Join-Path $PackageRoot 'ServerRegistry.psm1') -PassThru -DisableNameChecking;$server=& $registry {param($Root,$Id) Get-TCServer $Root $Id} $root $candidate.ServerRecordId
 Assert-Check ($server.ManagementAccessState -ceq 'ConnectorOnly' -and -not $server.Connection -and -not $server.CredentialRef) 'Invitation supplies connector role without SSH or manager rights'
 $status=Invoke-Fixture request_status @{RequestId=$request.RequestId;RequestDigest=$request.RequestDigest}
 Assert-Check ($status.Ok -and $status.Data.ClientResponse.DeviceId -ceq $request.DeviceId) 'Lost authorization return can be queried without new identity'
 $tcpPlan=Invoke-Fixture transport_plan @{Transport=@{Type='tcp-reality';Port=443;ServerName='www.bing.com'}}
 $tcpApplied=Invoke-Fixture transport_apply @{PlanId=$tcpPlan.Data.PlanId;ApprovedChangeDigest=$tcpPlan.Data.ChangeDigest}
 Assert-Check ($tcpApplied.Ok -and -not $tcpApplied.Data.WireGuardRestarted) 'Incremental TCP preserves existing WireGuard service and identities'
 $refreshed=Invoke-Fixture request_status @{RequestId=$request.RequestId;RequestDigest=$request.RequestDigest;RefreshAuthorization=$true}
 $refreshedSeal=Protect-TCPairAuthorization -SignedAuthorization $refreshed.Data.Authorization -PairRequest $request.PairRequest -Invite $invite
 $flowModule=Get-Module DeploymentFlow;$nodeModule=& $flowModule {(Get-Command Set-TCTransportMode).Module}
 & $nodeModule {
  $script:OriginalPairingCheck=${function:Test-TCCheckedConfiguration};$script:FailTcpOnce=$true
  function script:Test-TCCheckedConfiguration {param($Engine,$Path)
   if($script:FailTcpOnce -and $Path.Contains('.transport-')){$script:FailTcpOnce=$false;throw 'Injected TCP candidate check failure'}
   & $script:OriginalPairingCheck $Engine $Path
  }
 }
 $failed=$false;$failureMessage='';try{$null=Complete-TCPairCandidate -Root $root -EnrollmentId $request.EnrollmentId -EncryptedAuthorization $refreshedSeal.EncryptedAuthorization -Name 'Invited fixture candidate'}catch{$failed=$true;$failureMessage=$_.Exception.Message}
 $pending=Get-TCDeploymentRun -Root $root -RunId $request.EnrollmentId
 Assert-Check ($failed -and $pending.Status -ceq 'Failed' -and $pending.Stage -ceq 'MaterializeCandidate' -and $pending.CandidateTransaction.State -ceq 'PreparingTransport') 'Failed TCP conversion remains incomplete and durable'
 $resumed=Invoke-TCDeploymentAdvance -Root $root -RunId $request.EnrollmentId -Command Continue
 $manifest=Read-TCDJson $resumed.CandidateManifestPath
 Assert-Check ($resumed.Stage -ceq 'ReadyInactive' -and $manifest.Transport.Type -ceq 'tcp-reality' -and @(Get-TCNodes (Join-Path $root 'Product')).Count -eq 1) 'Encrypted receipt resumes failed TCP conversion without duplicate Peer or node'
 $latest=Get-TCPairEnrollment -Root $root -EnrollmentId $request.EnrollmentId
 Assert-Check ($latest.ClientRequest.RequestId -ceq $request.RequestId) 'Current revision refresh retains original enrollment identity'
 $preview=Invoke-Fixture revoke_preview @{DeviceId=$request.DeviceId};$revoked=Invoke-Fixture revoke @{DeviceId=$request.DeviceId;ExpectedConfigRevision=$preview.Data.ConfigRevision;ApprovedChangeDigest=$preview.Data.ChangeDigest}
 Assert-Check $revoked.Ok 'Cross-platform authorized device can be independently revoked'
 $devices=Invoke-Fixture devices @{};$active=@($devices.Data.Devices|Where-Object State -eq 'Authorized');$removed=@($devices.Data.Devices|Where-Object {$_.DeviceId -eq $request.DeviceId})
 Assert-Check ($active.Count -eq 1 -and $removed.Count -eq 1 -and $removed[0].State -ceq 'Revoked') 'Revocation preserves original device and records removed identity'
 $second=Invoke-Fixture invite_create @{};$cancel=Invoke-Fixture invite_cancel @{InviteId=$second.Data.InviteId}
 Assert-Check ($cancel.Ok -and $cancel.Data.State -ceq 'Cancelled') 'Invitation cancellation is authoritative on server'
 [pscustomobject]@{Ok=$true;Runtime=$PSVersionTable.PSVersion.ToString();CheckCount=$checks.Count;Checks=$checks.ToArray();ServerKernel='MemoryFS/fake services; real OpenSSL signatures';NetworkScope='No network or host setting changes'}|ConvertTo-Json -Depth 8
}finally{
 try{$process.StandardInput.Close();if(-not $process.WaitForExit(3000)){$process.Kill()}}catch{};$process.Dispose()
 $absolute=[IO.Path]::GetFullPath($root);$allowed=[IO.Path]::GetFullPath((Join-Path $PackageRoot 'deployment\test-runs'))+'\';if((Test-Path -LiteralPath $absolute) -and $absolute.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $absolute -Recurse -Force}
}
