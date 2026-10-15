#requires -Version 5.1
# Standalone QA helper: definition only. No application initialization or production Actor.
# All private/signing/transport material is newly generated inside an explicit temporary fixture root.
function New-PairIntakeFixture {
 [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$PackageRoot,[Parameter(Mandatory=$true)][string]$FixtureRoot)
 $PackageRoot=[IO.Path]::GetFullPath($PackageRoot);$FixtureRoot=[IO.Path]::GetFullPath($FixtureRoot).TrimEnd('\')
 $tempPrefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 $leaf=[IO.Path]::GetFileName($FixtureRoot)
 if(-not $FixtureRoot.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase) -or $leaf -cnotmatch '^tc-pair-(?:ui-015|intake)-[0-9a-f]{32}$'){throw 'Pairing fixtures require an isolated, explicitly named temporary root.'}
 Import-Module (Join-Path $PackageRoot 'DeploymentPairing.psm1') -Force -DisableNameChecking
 $pairModule=Get-Module DeploymentPairing;& $pairModule {Initialize-TCPairCrypto}
 $wg=Join-Path $PackageRoot 'assets\wg.exe'
 $clientModule=Import-Module (Join-Path $PackageRoot 'ServerSetup.psm1') -PassThru -DisableNameChecking
 $serverKeys=& $clientModule {param($Path) New-TCKeyPair $Path} $wg
 $transportKeys=& $clientModule {param($Path) New-TCKeyPair $Path} $wg
 $realityPublic=[string]$transportKeys.Public;$realityPublic=$realityPublic.TrimEnd('=').Replace('+','-').Replace('/','_');$transportKeys=$null
 $random=New-Object byte[] 8;$rng=[Security.Cryptography.RandomNumberGenerator]::Create()
 try{$rng.GetBytes($random);$shortId=([BitConverter]::ToString($random)).Replace('-','').ToLowerInvariant()}finally{$rng.Dispose();[Array]::Clear($random,0,$random.Length)}
 $private=[TradeChannel.Deployment.PairCrypto]::NewPrivateKey();$jwk=[TradeChannel.Deployment.PairCrypto]::PublicJwk($private)|ConvertFrom-Json
 $fingerprint=[TradeChannel.Deployment.PairCrypto]::Fingerprint(($jwk|ConvertTo-Json -Compress))
 $owner=[guid]::NewGuid().ToString();$node=[guid]::NewGuid().ToString();$inviteId=[guid]::NewGuid().ToString()
 $inviteBody=[ordered]@{SchemaVersion=1;Kind='TradeChannel.PairInvite';InviteId=$inviteId;RemoteOwnerId=$owner;NodeId=$node;ServerPublicKey=$serverKeys.Public;ManagementSigningPublicKey=$jwk;PublicEndpoint='1.1.1.1:51820';IssuedAtUtc=[DateTime]::UtcNow.ToString('o');ExpiresAtUtc=[DateTime]::UtcNow.AddHours(24).ToString('o');Capabilities=@('authorize_external')}
 $invite=[TradeChannel.Deployment.PairCrypto]::Sign(($inviteBody|ConvertTo-Json -Depth 24 -Compress),$private)
 $created=New-TCPairRequest -Invite $invite -ConfirmedFingerprint $fingerprint -DeviceName '隔离新电脑' -Root $FixtureRoot -WgPath $wg
 $requestInfo=Get-TCPairRequestInfo -PairRequest $created.PairRequest;$request=$requestInfo.Payload.ClientRequest
 $response=[ordered]@{SchemaVersion=1;Kind='TradeChannel.ClientResponse';Status='Authorized';RequestId=$request.RequestId;DeviceId=$request.DeviceId;NodeId=$node;NodeName='隔离测试服务器';ClientPublicKey=$request.ClientPublicKey;ClientAddress='10.78.0.2/32';ServerPublicKey=$serverKeys.Public;PublicEndpoint='1.1.1.1:51820';TunnelSubnet='10.78.0.0/24';ServerAddress='10.78.0.1/24';AllowedIPs=@('0.0.0.0/0');PersistentKeepalive=25;AddressFamilies=@('IPv4');ConfigRevision=1;MTU=1380;Validation=@{LocalAuthorization='Verified';CloudFirewall='NotVerified';Handshake='NotTested';ExternalConnectivity='NotTested'};Transport=@{Type='tcp-reality';Server='1.1.1.1';Port=8443;ServerName='www.bing.com';Uuid=[guid]::NewGuid().ToString();RealityPublicKey=$realityPublic;RealityShortId=$shortId}}
 $authorization=[ordered]@{SchemaVersion=1;Kind='TradeChannel.PairAuthorization';InviteId=$inviteId;ServerBinding=$requestInfo.Payload.ServerBinding;RemoteOwnerId=$owner;NodeId=$node;DeviceId=$request.DeviceId;ClientPublicKey=$request.ClientPublicKey;ClientAddress=$response.ClientAddress;ConfigRevision=1;ClientResponse=$response;IssuedAtUtc=[DateTime]::UtcNow.ToString('o');ExpiresAtUtc=[DateTime]::UtcNow.AddDays(7).ToString('o');RequestDigest=$created.RequestDigest;RequestDigestAlgorithm='TC-ClientRequest-v1';RequestId=$request.RequestId}
 $signed=[TradeChannel.Deployment.PairCrypto]::Sign(($authorization|ConvertTo-Json -Depth 24 -Compress),$private)
 $grant=(Protect-TCPairAuthorization -SignedAuthorization $signed -PairRequest $created.PairRequest -Invite $invite).EncryptedAuthorization
 $serverKeys=$null
 [pscustomobject]@{Invite=$invite;InviteBody=$inviteBody;Created=$created;RequestInfo=$requestInfo;Response=$response;Authorization=$authorization;Signed=$signed;Grant=$grant;ServerPrivate=$private;ServerJwk=$jwk;Fingerprint=$fingerprint;Wg=$wg;Root=$FixtureRoot}
}
