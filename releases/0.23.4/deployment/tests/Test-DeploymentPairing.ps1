#requires -Version 5.1
[CmdletBinding()]param([string]$PackageRoot)
$ErrorActionPreference='Stop';if(-not $PackageRoot){$PackageRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent}
Import-Module (Join-Path $PackageRoot 'DeploymentPairing.psm1') -Force -DisableNameChecking
$checks=New-Object 'Collections.Generic.List[string]'
function Assert-Check {param([bool]$Condition,[string]$Name)if(-not $Condition){throw ('FAILED: '+$Name)};$checks.Add($Name)}
function Assert-Reject {param([scriptblock]$Action,[string]$Name)$rejected=$false;try{& $Action|Out-Null}catch{$rejected=$true};Assert-Check $rejected $Name}
$module=Get-Module DeploymentPairing;& $module {Initialize-TCPairCrypto}
$serverPrivate=[TradeChannel.Deployment.PairCrypto]::NewPrivateKey();$serverJwk=[TradeChannel.Deployment.PairCrypto]::PublicJwk($serverPrivate)|ConvertFrom-Json;$fingerprint=[TradeChannel.Deployment.PairCrypto]::Fingerprint(($serverJwk|ConvertTo-Json -Compress))
$wg=Join-Path $PackageRoot 'assets\wg.exe';$clientModule=Import-Module (Join-Path $PackageRoot 'ServerSetup.psm1') -PassThru -DisableNameChecking;$serverPair=& $clientModule {param($Path) New-TCKeyPair $Path} $wg;$serverPublic=$serverPair.Public;$serverPair=$null
$nodeId=[guid]::NewGuid().ToString();$ownerId=[guid]::NewGuid().ToString();$inviteId=[guid]::NewGuid().ToString()
$inviteBody=[ordered]@{SchemaVersion=1;Kind='TradeChannel.PairInvite';InviteId=$inviteId;RemoteOwnerId=$ownerId;NodeId=$nodeId;ServerPublicKey=$serverPublic;ManagementSigningPublicKey=$serverJwk;PublicEndpoint='1.1.1.1:51820';IssuedAtUtc=[DateTime]::UtcNow.ToString('o');ExpiresAtUtc=[DateTime]::UtcNow.AddHours(24).ToString('o');Capabilities=@('authorize_external')}
$invite=[TradeChannel.Deployment.PairCrypto]::Sign(($inviteBody|ConvertTo-Json -Depth 12 -Compress),$serverPrivate)
$testRoot=Join-Path $PackageRoot ('deployment\test-runs\pairing-'+[guid]::NewGuid().ToString('N'))
try{
    $untrusted=Get-TCPairInvite -Invite $invite -AllowUnconfirmed;Assert-Check ($untrusted.RequiresTrustConfirmation -and $untrusted.Fingerprint -ceq $fingerprint) 'First invite trust shown explicitly'
    Assert-Reject {New-TCPairRequest -Invite $invite -ConfirmedFingerprint ('SHA256:'+('B'*43)) -Root $testRoot -WgPath $wg} 'Unconfirmed signing identity blocks enrollment'
    $created=New-TCPairRequest -Invite $invite -ConfirmedFingerprint $fingerprint -DeviceName 'Isolated second PC' -Root $testRoot -WgPath $wg
    $requestInfo=Get-TCPairRequestInfo $created.PairRequest;$request=$requestInfo.Payload.ClientRequest
    Assert-Check ($requestInfo.RequestDigest -ceq $created.RequestDigest -and $requestInfo.Payload.RecipientJwk.e -ceq 'AQAB') 'RSA3072 signed request binds canonical client digest'
    $again=New-TCPairRequest -Invite $invite -ConfirmedFingerprint $fingerprint -Root $testRoot -WgPath $wg
    Assert-Check ($again.EnrollmentId -ceq $created.EnrollmentId -and $again.PairRequest -ceq $created.PairRequest) 'Enrollment retry preserves device identity and RSA key'
    $directory=Join-Path (Join-Path $testRoot 'identities') $created.EnrollmentId
    Assert-Check (-not (Test-Path -LiteralPath (Join-Path $directory 'client\client.key'))) 'New-client WireGuard private key stored DPAPI only'
    $response=[ordered]@{SchemaVersion=1;Kind='TradeChannel.ClientResponse';Status='Authorized';RequestId=$request.RequestId;DeviceId=$request.DeviceId;NodeId=$nodeId;NodeName='Isolated fixture';ClientPublicKey=$request.ClientPublicKey;ClientAddress='10.78.0.2/32';ServerPublicKey=$serverPublic;PublicEndpoint='1.1.1.1:51820';TunnelSubnet='10.78.0.0/24';ServerAddress='10.78.0.1/24';AllowedIPs=@('0.0.0.0/0');PersistentKeepalive=25;AddressFamilies=@('IPv4');ConfigRevision=1;Validation=@{LocalAuthorization='Verified';CloudFirewall='NotVerified';Handshake='NotTested';ExternalConnectivity='NotTested'}}
    $authBody=[ordered]@{SchemaVersion=1;Kind='TradeChannel.PairAuthorization';InviteId=$inviteId;ServerBinding=$requestInfo.Payload.ServerBinding;RemoteOwnerId=$ownerId;NodeId=$nodeId;DeviceId=$request.DeviceId;ClientPublicKey=$request.ClientPublicKey;ClientAddress=$response.ClientAddress;ConfigRevision=1;ClientResponse=$response;IssuedAtUtc=[DateTime]::UtcNow.ToString('o');ExpiresAtUtc=[DateTime]::UtcNow.AddDays(7).ToString('o');RequestDigest=$created.RequestDigest;RequestDigestAlgorithm='TC-ClientRequest-v1'}
    $response.MTU=1380.5
    $invalidMtuSigned=[TradeChannel.Deployment.PairCrypto]::Sign(($authBody|ConvertTo-Json -Depth 24 -Compress),$serverPrivate)
    Assert-Reject {$invalidMtuSealed=Protect-TCPairAuthorization -SignedAuthorization $invalidMtuSigned -PairRequest $created.PairRequest -Invite $invite;Complete-TCPairAuthorization -EncryptedAuthorization $invalidMtuSealed.EncryptedAuthorization -EnrollmentId $created.EnrollmentId -Root $testRoot} 'Signed noninteger MTU rejected before configuration materialization'
    $response.MTU=1380
    $signed=[TradeChannel.Deployment.PairCrypto]::Sign(($authBody|ConvertTo-Json -Depth 24 -Compress),$serverPrivate)
    $sealed=Protect-TCPairAuthorization -SignedAuthorization $signed -PairRequest $created.PairRequest -Invite $invite
    $header=[Text.Encoding]::UTF8.GetString([TradeChannel.Deployment.PairCrypto]::Unb64($sealed.EncryptedAuthorization.Split('.')[0]))|ConvertFrom-Json
    Assert-Check ($header.alg -ceq 'RSA-OAEP-256' -and $header.enc -ceq 'A256CBC-HS512') 'Authorization uses approved JWE algorithms'
    Assert-Check (-not ($sealed.PSObject.Properties.Name -contains 'ConfigPath')) 'Management endpoint cannot materialize new client configuration'
    $parts=$sealed.EncryptedAuthorization.Split('.');$parts[4]=('A'+$parts[4].Substring(1));$tampered=$parts -join '.'
    Assert-Reject {Complete-TCPairAuthorization -EncryptedAuthorization $tampered -EnrollmentId $created.EnrollmentId -Root $testRoot} 'Tampered authorization tag rejected before materialization'
    $wrong=[TradeChannel.Deployment.PairCrypto]::NewPrivateKey();Assert-Reject {[TradeChannel.Deployment.PairCrypto]::Decrypt($sealed.EncryptedAuthorization,$wrong)} 'Different recipient cannot decrypt authorization'
    $changed=[ordered]@{};foreach($field in $authBody.Keys){$changed[$field]=$authBody[$field]};$changed.DeviceId=[guid]::NewGuid().ToString();$changedSigned=[TradeChannel.Deployment.PairCrypto]::Sign(($changed|ConvertTo-Json -Depth 24 -Compress),$serverPrivate)
    Assert-Reject {Protect-TCPairAuthorization -SignedAuthorization $changedSigned -PairRequest $created.PairRequest -Invite $invite} 'Signed wrong-device authorization rejected'
    $completed=Complete-TCPairAuthorization -EncryptedAuthorization $sealed.EncryptedAuthorization -EnrollmentId $created.EnrollmentId -Root $testRoot
    Assert-Check ((Test-Path -LiteralPath $completed.ConfigPath) -and $completed.DeviceId -ceq $request.DeviceId) 'Receiving PC completes configuration with local private key'
    Assert-Check (-not (Test-Path -LiteralPath (Join-Path $directory 'client\client.key'))) 'Temporary private merge file removed'
    $repeat=Complete-TCPairAuthorization -EncryptedAuthorization $sealed.EncryptedAuthorization -EnrollmentId $created.EnrollmentId -Root $testRoot
    Assert-Check ($repeat.ConfigPath -ceq $completed.ConfigPath) 'Repeated encrypted return completes idempotently'
    Assert-Check ([IO.File]::ReadAllText($completed.ConfigPath) -match '(?m)^MTU = 1380\r?$') 'Encrypted authorization carries server MTU into actual client configuration'
    # Simulate a process death after writing the temporary merge key and existing config.
    & $module {param($Directory)
        $secret=Read-TCPairState (Join-Path $Directory 'private.dpapi.json');$plain=ConvertFrom-TCPairJson (Unprotect-TCPairPrivate $secret.Protected);$linux=Get-TCPairModule
        & $linux {param($Path,$Key) $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);$stream.Dispose();Protect-TCLinuxPath $Path;[IO.File]::WriteAllText($Path,$Key,(New-Object Text.UTF8Encoding($false)))} (Join-Path $Directory 'client\client.key') $plain.WireGuardPrivateKey
    } $directory
    $resumed=Resume-TCPairAuthorization -Root $testRoot -EnrollmentId $created.EnrollmentId
    Assert-Check ($resumed.ConfigPath -ceq $completed.ConfigPath -and -not (Test-Path -LiteralPath (Join-Path $directory 'client\client.key'))) 'Process-death merge residue and existing config resume safely'
    Import-Module (Join-Path $PackageRoot 'ConnectionBundle.psm1') -DisableNameChecking
    $bundle=Get-TCPairConnectionBundle -Root $testRoot -EnrollmentId $created.EnrollmentId
    Assert-Check ($bundle.ContractVersion -eq 1 -and $bundle.SignatureProtocol -ceq 'TradeChannel.PairAuthorization.V1' -and $bundle.Profiles.Udp.Id -ceq 'Udp' -and -not $bundle.Profiles.PSObject.Properties['Tcp']) 'Old signed V1 authorization generates independent local UDP bundle without wire changes'
    $forged=$bundle|ConvertTo-Json -Depth 24|ConvertFrom-Json;$forged.Binding.ClientAddress='10.78.0.99/32'
    Assert-Reject {Assert-TCConnectionBundle $forged} 'Local bundle binding cannot replace real signed authorization identity or address'
    $forged=$bundle|ConvertTo-Json -Depth 24|ConvertFrom-Json;$forged.Source.SignedAuthorization=$changedSigned
    Assert-Reject {Assert-TCConnectionBundle $forged} 'Bundle loader re-verifies signature and signed original device binding'
    $unknown=[ordered]@{};foreach($field in $authBody.Keys){$unknown[$field]=$authBody[$field]};$unknown.VersionedConnectionBundle=@{Version=1}
    $unknownSigned=[TradeChannel.Deployment.PairCrypto]::Sign(($unknown|ConvertTo-Json -Depth 24 -Compress),$serverPrivate)
    Assert-Reject {Protect-TCPairAuthorization -SignedAuthorization $unknownSigned -PairRequest $created.PairRequest -Invite $invite} 'Strict V1 rejects added bundle fields instead of silently upgrading signed protocol'
    $dualResponse=[ordered]@{};foreach($field in $response.Keys){$dualResponse[$field]=$response[$field]};$dualResponse.ConfigRevision=2
    $dualResponse.Transport=@{Type='tcp-reality';Server='1.1.1.1';Port=8443;ServerName='www.bing.com';Uuid='aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';RealityPublicKey=('A'*43);RealityShortId='1234567890abcdef'}
    $dualAuth=[ordered]@{};foreach($field in $authBody.Keys){$dualAuth[$field]=$authBody[$field]};$dualAuth.ConfigRevision=2;$dualAuth.ClientResponse=$dualResponse
    $dualSigned=[TradeChannel.Deployment.PairCrypto]::Sign(($dualAuth|ConvertTo-Json -Depth 24 -Compress),$serverPrivate)
    $dualSealed=Protect-TCPairAuthorization -SignedAuthorization $dualSigned -PairRequest $created.PairRequest -Invite $invite
    $dualCompleted=Complete-TCPairAuthorization -EncryptedAuthorization $dualSealed.EncryptedAuthorization -EnrollmentId $created.EnrollmentId -Root $testRoot
    $dualBundle=Get-TCPairConnectionBundle -Root $testRoot -EnrollmentId $created.EnrollmentId
    Assert-Check ($dualBundle.Profiles.Udp.PublicEndpoint -ceq $response.PublicEndpoint -and $dualBundle.Profiles.Tcp.Transport.Port -eq 8443 -and $dualBundle.Binding.DeviceId -ceq $request.DeviceId) 'Existing V1 responseTransport provides both negotiated profiles for one independent device'
    $bundleText=[IO.File]::ReadAllText($dualCompleted.ConnectionBundle.ProtectedPath)
    Assert-Check (-not $bundleText.Contains('aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee') -and -not $bundleText.Contains('SignedAuthorization')) 'Local versioned bundle and signed TCP parameters persist in DPAPI only'
    Import-Module (Join-Path $PackageRoot 'DeploymentFlow.psm1') -DisableNameChecking
    Import-Module (Join-Path $PackageRoot 'LineStore.psm1') -DisableNameChecking
    Import-Module (Join-Path $PackageRoot 'NodeStore.psm1') -DisableNameChecking
    $candidate=Complete-TCPairCandidate -Root $testRoot -EnrollmentId $created.EnrollmentId -EncryptedAuthorization $dualSealed.EncryptedAuthorization -Name 'New PC one line'
    $line=Get-TCLine -Root $testRoot -Id $candidate.Id
    Assert-Check ($line.Profiles.Count -eq 2 -and $line.Name -ceq 'New PC one line' -and @(Get-TCNodes -Root (Join-Path $testRoot 'Product')).Count -eq 1) 'Receiving PC publishes real UDP and TCP profiles as one original named Line'
    $againDual=Complete-TCPairCandidate -Root $testRoot -EnrollmentId $created.EnrollmentId -EncryptedAuthorization $dualSealed.EncryptedAuthorization -Name 'New PC one line'
    Assert-Check ($againDual.Id -ceq $candidate.Id -and @(Get-ChildItem -LiteralPath (Join-Path $testRoot 'identities') -Directory).Count -eq 1) 'Repeated dual-profile authorization retains exactly one independent device identity'
    $password=ConvertTo-SecureString 'Isolated recovery passphrase 2026!' -AsPlainText -Force
    $record=@{RemoteOwnerId=$ownerId;NodeId=$nodeId;Name='Isolated fixture';Endpoints=@('1.1.1.1:51820');Connection=@{Host='1.1.1.1';Port=22;User='root';IdentityFile='ignored'};ManagementSigningPublicKey=$serverJwk;PinnedHostKey='SHA256:'+('C'*43)}
    $export=Export-TCManagementRecovery -ServerRecord $record -Credential @{Kind='Password';Password=(ConvertTo-SecureString 'Fixture management only' -AsPlainText -Force)} -Password $password
    $restored=Import-TCManagementRecovery -Recovery $export.Recovery -Password $password
    Assert-Check ($restored.Status -ceq 'AwaitIdentityVerification' -and -not $restored.Activated -and $restored.Credential.Password -is [Security.SecureString]) 'PBES2 recovery restores pending management only'
    Assert-Reject {Import-TCManagementRecovery -Recovery $export.Recovery -Password (ConvertTo-SecureString 'Wrong recovery passphrase' -AsPlainText -Force)} 'Wrong recovery password rejected'
    $parts=$export.Recovery.Split('.');$h=[Text.Encoding]::UTF8.GetString([TradeChannel.Deployment.PairCrypto]::Unb64($parts[0]))|ConvertFrom-Json;$h.p2c=2147483647;$parts[0]=[TradeChannel.Deployment.PairCrypto]::B64([Text.Encoding]::UTF8.GetBytes(($h|ConvertTo-Json -Compress)))
    Assert-Reject {Import-TCManagementRecovery -Recovery ($parts -join '.') -Password $password} 'Excessive KDF iteration rejected before decryption'
    $parts=$created.PairRequest.Split('.');$parts[0]=[TradeChannel.Deployment.PairCrypto]::B64([Text.Encoding]::UTF8.GetBytes('{"alg":"none"}'))
    Assert-Reject {Get-TCPairRequestInfo ($parts -join '.')} 'JWS none downgrade rejected'
    # Independent cryptography implementation validates actual JOSE bytes, via stdin only.
    $privateFixture=& $module {param($Path) $value=Read-TCPairState $Path;ConvertFrom-TCPairJson (Unprotect-TCPairPrivate $value.Protected)} (Join-Path $directory 'private.dpapi.json')
    $vectors=@{PairRequest=$created.PairRequest;RecipientJwk=$requestInfo.Payload.RecipientJwk;RecipientPrivateKey=$privateFixture.RecipientPrivateKey;Authorization=$sealed.EncryptedAuthorization;ServerJwk=$serverJwk;Recovery=$export.Recovery;RecoveryPassword='Isolated recovery passphrase 2026!'}
    $pythonStart=New-Object Diagnostics.ProcessStartInfo;$pythonStart.FileName='python.exe';$pythonStart.Arguments='"'+(Join-Path $PSScriptRoot 'verify_jose_vectors.py')+'"';$pythonStart.UseShellExecute=$false;$pythonStart.CreateNoWindow=$true;$pythonStart.RedirectStandardInput=$true;$pythonStart.RedirectStandardOutput=$true;$pythonStart.RedirectStandardError=$true
    $python=New-Object Diagnostics.Process;$python.StartInfo=$pythonStart
    try{$null=$python.Start();$errors=$python.StandardError.ReadToEndAsync();$output=$python.StandardOutput.ReadToEndAsync();$stdin=$python.StandardInput.BaseStream;$vectorBytes=[Text.Encoding]::UTF8.GetBytes(($vectors|ConvertTo-Json -Depth 24 -Compress));$stdin.Write($vectorBytes,0,$vectorBytes.Length);$stdin.Close();[Array]::Clear($vectorBytes,0,$vectorBytes.Length);if(-not $python.WaitForExit(30000)){$python.Kill();throw 'Independent JOSE check timed out.'};$independent=$output.Result|ConvertFrom-Json;Assert-Check ($python.ExitCode -eq 0 -and $independent.Ok -and $independent.RSA_OAEP_256 -and $independent.A256CBC_HS512 -and $independent.PBES2_HS512_A256KW) 'Independent Python validates RSA-OAEP, CBC-HMAC, PBES2 and JWS bytes'}finally{$python.Dispose();$privateFixture=$null;$vectors=$null}

    [pscustomobject]@{Ok=$true;Runtime=$PSVersionTable.PSVersion.ToString();CheckCount=$checks.Count;Checks=$checks.ToArray();NetworkScope='No network calls or setting changes'}|ConvertTo-Json -Depth 8
}finally{
    $absolute=[IO.Path]::GetFullPath($testRoot);$allowed=[IO.Path]::GetFullPath((Join-Path $PackageRoot 'deployment\test-runs'))+'\';if((Test-Path -LiteralPath $absolute) -and $absolute.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $absolute -Recurse -Force}
}
