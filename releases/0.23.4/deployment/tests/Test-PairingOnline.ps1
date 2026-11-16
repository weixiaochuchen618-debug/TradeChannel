#requires -Version 5.1
[CmdletBinding()]param([string]$PackageRoot,[string]$TestDependencyRoot)
$ErrorActionPreference='Stop'
if(-not $PackageRoot){$PackageRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent}
Import-Module (Join-Path $PackageRoot 'PairingOnline.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PackageRoot 'DeploymentPairing.psm1') -DisableNameChecking
$checks=New-Object 'Collections.Generic.List[string]'
function Assert-Check {param([bool]$Condition,[string]$Name)if(-not $Condition){throw ('FAILED: '+$Name)};$checks.Add($Name)}
function Assert-Reject {param([scriptblock]$Action,[string]$Code,[string]$Name)$matched=$false;try{& $Action|Out-Null}catch{$matched=$_.Exception.Message.Contains('[TC:'+$Code+']');if(-not $matched){throw ('Unexpected error for '+$Name+': '+$_.Exception.Message)}};Assert-Check $matched $Name}
$isolatedRoot=Join-Path ([IO.Path]::GetTempPath()) ('tc-online-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $isolatedRoot
$start=New-Object Diagnostics.ProcessStartInfo
$fixtureSource=Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'tests\pairing_online_loopback.py'
$start.FileName='python.exe';$start.Arguments='-B "'+$fixtureSource+'" "'+$isolatedRoot+'"'
$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
$start.StandardOutputEncoding=New-Object Text.UTF8Encoding($false);$start.StandardErrorEncoding=New-Object Text.UTF8Encoding($false)
if($TestDependencyRoot){$start.EnvironmentVariables['TC_PAIR_ONLINE_TEST_DEPS']=[IO.Path]::GetFullPath($TestDependencyRoot)}
$process=New-Object Diagnostics.Process;$process.StartInfo=$start
$null=$process.Start();$stderr=$process.StandardError.ReadToEndAsync()
function Read-FixtureLine {
    $pending=$process.StandardOutput.ReadLineAsync()
    if(-not $pending.Wait(30000)){throw 'Online loopback fixture timed out.'}
    if(-not $pending.Result){throw ('Online loopback fixture stopped: '+$stderr.Result)}
    $pending.Result|ConvertFrom-Json
}
function Invoke-Fixture {param([string]$Action,$Extra=@{})
    $value=@{Action=$Action};foreach($key in $Extra.Keys){$value[$key]=$Extra[$key]}
    $bytes=[Text.Encoding]::UTF8.GetBytes(($value|ConvertTo-Json -Depth 20 -Compress)+"`n")
    $stream=$process.StandardInput.BaseStream;$stream.Write($bytes,0,$bytes.Length);$stream.Flush();Read-FixtureLine
}
function Change-Code {param([string]$Original,[string]$Field,$Value)
    $decoded=[Text.Encoding]::UTF8.GetString([TradeChannel.Deployment.PairCrypto]::Unb64($Original.Substring(5)))|ConvertFrom-Json
    $decoded.$Field=$Value
    'TCI1.'+[TradeChannel.Deployment.PairCrypto]::B64([Text.Encoding]::UTF8.GetBytes(($decoded|ConvertTo-Json -Compress)))
}
try{
    $target=Read-FixtureLine
    $connection=@{Host='127.0.0.1';Port=[int]$target.SshPort;User='root'}
    $credential=@{Kind='Password';Password=(ConvertTo-SecureString 'TC_Online_Loopback_Only!' -AsPlainText -Force)}
    $inputData=@{InviteId=[guid]::NewGuid().ToString();DeviceName='Isolated new Windows PC';ExpiresInSeconds=600;PublicHost=$target.PublicHost;Port=[int]$target.Port;ExpectedServerBinding=$target.ExpectedServerBinding;ExpectedManagementFingerprint=$target.ExpectedManagementFingerprint}
    Assert-Reject {Invoke-TCPairOnlineSsh -Action create -InputData $inputData -Connection $connection -Credential $credential -PinnedHostKey ('SHA256:'+('A'*43))} OnlineSshHostChanged 'SSH host key change rejected before invitation creation'
    $created=Invoke-TCPairOnlineSsh -Action create -InputData $inputData -Connection $connection -Credential $credential -PinnedHostKey $target.SshFingerprint
    $again=Invoke-TCPairOnlineSsh -Action create -InputData $inputData -Connection $connection -Credential $credential -PinnedHostKey $target.SshFingerprint
    Assert-Check ($created.InvitationCode -ceq $again.InvitationCode -and $created.ExpiresAtUtc -ceq $again.ExpiresAtUtc) 'Real pinned SSH create and retry preserve one code and original lifetime'
    $stats=(Invoke-Fixture stats).Data
    Assert-Check ($stats.SshCommands -eq 2 -and $stats.HashVerified -and $stats.SourcesCompiled -and $stats.PeerCount -eq 1) 'SSH stdin carries hashed production modules and invokes isolated real installation core'
    Assert-Check $stats.EmbeddedMethodsVerified 'SSH source embeds the shared connection registry before transport and backend imports'
    Assert-Reject {Get-TCPairOnlineInvitation -InvitationCode $created.InvitationCode} InvalidOnlineHost 'Production API refuses loopback unless explicitly enabled for tests'
    $badTls=Change-Code $created.InvitationCode t ('0'*64)
    Assert-Reject {Get-TCPairOnlineInvitation -InvitationCode $badTls -AllowLoopback} OnlineTlsPinMismatch 'TLS identity mismatch stops before bearer or public request is sent'
    $badSigning=Change-Code $created.InvitationCode m ('SHA256:'+('A'*43))
    Assert-Reject {Get-TCPairOnlineInvitation -InvitationCode $badSigning -AllowLoopback} OnlineInviteIdentityMismatch 'Management signature identity is independently pinned'
    $view=Get-TCPairOnlineInvitation -InvitationCode $created.InvitationCode -AllowLoopback
    Assert-Check ($view.Fingerprint -ceq $target.ExpectedManagementFingerprint -and -not $view.NetworkChanged) 'Signed descriptor binds endpoint certificate and offline invitation'
    $clientRoot=Join-Path $isolatedRoot 'client'
    $request=New-TCPairOnlineEnrollment -InvitationCode $created.InvitationCode -Root $clientRoot -DeviceName 'New Windows client' -AllowLoopback
    $retry=New-TCPairOnlineEnrollment -InvitationCode $created.InvitationCode -Root $clientRoot -DeviceName 'Ignored retry name' -AllowLoopback
    Assert-Check ($request.EnrollmentId -ceq $retry.EnrollmentId -and $request.DeviceId -ceq $retry.DeviceId) 'Saved online retry reuses the same locally generated client keys'
    $enrollment=Get-TCPairEnrollment -Root $clientRoot -EnrollmentId $request.EnrollmentId
    $directory=Join-Path (Join-Path $clientRoot 'identities') $request.EnrollmentId
    Assert-Check (-not (Test-Path -LiteralPath (Join-Path $directory 'client\client.key'))) 'Local WireGuard private key stays in existing DPAPI storage'
    $saved=[IO.File]::ReadAllText((Join-Path $directory 'online.dpapi.json'))
    Assert-Check (-not $saved.Contains($created.InvitationCode) -and $saved.Contains('Protected')) 'Bearer invitation is DPAPI protected rather than plaintext at rest'
    $null=Invoke-Fixture drop_next
    Assert-Reject {Complete-TCPairOnlineEnrollment -Root $clientRoot -EnrollmentId $request.EnrollmentId -AllowLoopback} OnlineConnectionFailed 'Lost HTTPS response leaves original enrollment retryable'
    $stats=(Invoke-Fixture stats).Data
    Assert-Check ($stats.PeerCount -eq 2 -and $stats.DroppedResponses -eq 1) 'Server atomically authorized and consumed once before response loss'
    $completed=Complete-TCPairOnlineEnrollment -Root $clientRoot -EnrollmentId $request.EnrollmentId -AllowLoopback
    Assert-Check ($completed.Status -ceq 'ConfigCompleted' -and $completed.EnrollmentId -ceq $request.EnrollmentId -and $completed.RequestId -ceq $request.RequestId -and -not $completed.NetworkChanged -and (Test-Path -LiteralPath $completed.ConfigPath)) 'Windows 5.1 receives OpenSSL JWE and materializes the original device configuration'
    $bundle=Get-TCPairConnectionBundle -Root $clientRoot -EnrollmentId $request.EnrollmentId
    Assert-Check ($bundle.Profiles.Udp.Id -ceq 'Udp' -and $bundle.Profiles.Tcp.Id -ceq 'Tcp' -and $bundle.Binding.DeviceId -ceq $request.DeviceId) 'The new device receives both existing UDP and TCP line profiles'
    Assert-Check ([IO.File]::ReadAllText($completed.ConfigPath) -match '(?m)^MTU = 1380\r?$') 'Signed server MTU reaches the real client configuration'
    $stats=(Invoke-Fixture stats).Data
    Assert-Check ($stats.PeerCount -eq 2 -and $stats.NoClientPrivateKey -and $stats.HttpAuthorizations -eq 2) 'Retry added no duplicate peer and no client private key reached the server'
    $local=Complete-TCPairOnlineEnrollment -Root $clientRoot -EnrollmentId $request.EnrollmentId -AllowLoopback
    $after=(Invoke-Fixture stats).Data
    Assert-Check ($local.ConfigPath -ceq $completed.ConfigPath -and $after.HttpAuthorizations -eq $stats.HttpAuthorizations) 'Completed enrollment resumes locally without another network authorization'
    $pairModule=Get-Module DeploymentPairing
    & $pairModule {param($Root,$Id)$state=Get-TCPairEnrollment -Root $Root -EnrollmentId $Id;$state.State='Requested';$path=Join-Path (Join-Path (Join-Path (Resolve-TCPairRoot $Root) 'identities') $Id) 'enrollment.json';Write-TCPairState $path $state -Replace} $clientRoot $request.EnrollmentId
    $savedCodePath=Join-Path $directory 'online.dpapi.json'
    $savedCodeBytes=[IO.File]::ReadAllBytes($savedCodePath)
    Remove-Item -LiteralPath $savedCodePath -Force
    $resumed=Complete-TCPairOnlineEnrollment -Root $clientRoot -EnrollmentId $request.EnrollmentId -AllowLoopback
    [IO.File]::WriteAllBytes($savedCodePath,$savedCodeBytes)
    Assert-Check ($resumed.ConfigPath -ceq $completed.ConfigPath -and (Invoke-Fixture stats).Data.HttpAuthorizations -eq $after.HttpAuthorizations) 'Crash after saving authorization resumes from DPAPI without needing the online code'
    Assert-Reject {New-TCPairOnlineEnrollment -InvitationCode $created.InvitationCode -Root (Join-Path $isolatedRoot 'unrelated-client') -AllowLoopback} InviteConsumed 'Another computer cannot reuse the consumed code'
    $fallback=(Invoke-Fixture offline_authorize @{Input=@{InviteId=$created.InviteId;PairRequest=$enrollment.PairRequest}}).Data
    $sealed=Protect-TCPairAuthorization -SignedAuthorization $fallback.Authorization -PairRequest $enrollment.PairRequest -Invite $enrollment.Invite
    $offline=Complete-TCPairAuthorization -Root $clientRoot -EnrollmentId $request.EnrollmentId -EncryptedAuthorization $sealed.EncryptedAuthorization
    Assert-Check ($offline.ConfigPath -ceq $completed.ConfigPath) 'Existing offline request and encrypted handoff remain usable for the same enrollment'
    $cancelInput=@{};foreach($key in $inputData.Keys){$cancelInput[$key]=$inputData[$key]};$cancelInput.InviteId=[guid]::NewGuid().ToString()
    $cancelled=Invoke-TCPairOnlineSsh -Action create -InputData $cancelInput -Connection $connection -Credential $credential -PinnedHostKey $target.SshFingerprint
    $lookup=@{InviteId=$cancelled.InviteId;ExpectedServerBinding=$target.ExpectedServerBinding;ExpectedManagementFingerprint=$target.ExpectedManagementFingerprint}
    $status=Invoke-TCPairOnlineSsh -Action status -InputData $lookup -Connection $connection -Credential $credential -PinnedHostKey $target.SshFingerprint
    Assert-Check ($status.State -ceq 'Open' -and -not $status.PSObject.Properties['Invite']) 'SSH status returns safe state without invitation material'
    $null=Invoke-TCPairOnlineSsh -Action cancel -InputData $lookup -Connection $connection -Credential $credential -PinnedHostKey $target.SshFingerprint
    Assert-Reject {Get-TCPairOnlineInvitation -InvitationCode $cancelled.InvitationCode -AllowLoopback} InviteUnavailable 'SSH cancellation disables HTTPS redemption immediately'
    $expiresInput=@{};foreach($key in $inputData.Keys){$expiresInput[$key]=$inputData[$key]};$expiresInput.InviteId=[guid]::NewGuid().ToString();$expiresInput.ExpiresInSeconds=60
    $expires=Invoke-TCPairOnlineSsh -Action create -InputData $expiresInput -Connection $connection -Credential $credential -PinnedHostKey $target.SshFingerprint
    $null=Invoke-Fixture advance @{Seconds=61}
    Assert-Reject {Get-TCPairOnlineInvitation -InvitationCode $expires.InvitationCode -AllowLoopback} OnlineInviteExpired 'Server deadline rejects an unused code even if client clock has not advanced'
    [pscustomobject]@{Ok=$true;Runtime=$PSVersionTable.PSVersion.ToString();Framework=[Runtime.InteropServices.RuntimeEnvironment]::GetSystemVersion();CheckCount=$checks.Count;Checks=$checks.ToArray();NetworkScope='127.0.0.1 SSH + pinned TLS only';KernelScope='MemoryFS + fake WireGuard/systemd';ProductDirectoriesTouched=$false;ClientPrivateKeyLeavesClient=$false;ExternalConnectivity='NotTested'}|ConvertTo-Json -Depth 8
}finally{
    if(-not $process.HasExited){$process.StandardInput.Close();if(-not $process.WaitForExit(10000)){$process.Kill()}}
    $process.Dispose()
    $absolute=[IO.Path]::GetFullPath($isolatedRoot);$allowed=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if($absolute.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($absolute) -match '^tc-online-[0-9a-f]{32}$' -and (Test-Path -LiteralPath $absolute)){Remove-Item -LiteralPath $absolute -Recurse -Force}
}
