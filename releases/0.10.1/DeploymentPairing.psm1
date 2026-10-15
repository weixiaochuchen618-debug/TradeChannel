#requires -Version 5.1
Set-StrictMode -Version 2.0
$script:TCPairLinux=$null
function Stop-TCPair {param([string]$Code,[string]$Message)throw [InvalidOperationException]::new('[TC:'+$Code+'] '+$Message)}
function Get-TCPairModule {if(-not $script:TCPairLinux){$script:TCPairLinux=Import-Module (Join-Path $PSScriptRoot 'LinuxServerSetup.psm1') -PassThru -DisableNameChecking -ErrorAction Stop};$script:TCPairLinux}
function Initialize-TCPairCrypto {
    if(-not ('TradeChannel.Deployment.PairCrypto' -as [type])){
        Import-Module (Join-Path $PSScriptRoot 'DeploymentDependencies.psm1') -DisableNameChecking;$null=Test-TCDeploymentDependencies -PackageRoot $PSScriptRoot
        Add-Type -AssemblyName System.Web.Extensions;Add-Type -AssemblyName System.Security
        [Reflection.Assembly]::LoadFrom((Join-Path $PSScriptRoot 'assets\lib\jose-jwt.dll'))|Out-Null
        [Reflection.Assembly]::LoadFrom((Join-Path $PSScriptRoot 'deployment\TradeChannelPairCrypto.dll'))|Out-Null
    }
}
function Get-TCPairProperty {param($Value,[string]$Name,$Default=$null)if($Value -is [Collections.IDictionary]){if($Value.Contains($Name)){return $Value[$Name]}}elseif($null -ne $Value -and $Value.PSObject.Properties[$Name]){return $Value.$Name};return $Default}
function Assert-TCPairFields {param($Value,[string[]]$Fields)if($null -eq $Value -or ($Value -isnot [Collections.IDictionary] -and $Value -isnot [pscustomobject])){Stop-TCPair InvalidPairing '交接对象格式无效。'};$names=if($Value -is [Collections.IDictionary]){@($Value.Keys)}else{@($Value.PSObject.Properties.Name)};foreach($name in $names){if($name -cnotin $Fields){Stop-TCPair InvalidPairing '交接资料包含未支持字段。'}}}
function Assert-TCPairId {param([string]$Id)if($Id -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'){Stop-TCPair InvalidPairing '交接身份标识无效。'}}
function ConvertFrom-TCPairJson {param([string]$Text)if(-not $Text -or [Text.Encoding]::UTF8.GetByteCount($Text) -gt 128KB){Stop-TCPair PairingTooLarge '交接资料为空或超出 128 KiB。'};try{return ($Text|ConvertFrom-Json -ErrorAction Stop)}catch{Stop-TCPair InvalidPairing '交接资料无法解析。'}}
function ConvertTo-TCPairJson {param($Value)$text=$Value|ConvertTo-Json -Depth 24 -Compress;if([Text.Encoding]::UTF8.GetByteCount($text) -gt 128KB){Stop-TCPair PairingTooLarge '交接资料超出 128 KiB。'};return $text}
function Get-TCPairTime {param($Value)$module=Get-TCPairModule;& $module {param($Time) ConvertTo-TCLinuxUtcTime $Time} $Value}
function Assert-TCPairBinding {param($Value)Assert-TCPairFields $Value @('RemoteOwnerId','NodeId','ServerPublicKey');Assert-TCPairId $Value.RemoteOwnerId;Assert-TCPairId $Value.NodeId;if($Value.ServerPublicKey -cnotmatch '^[A-Za-z0-9+/]{43}=$'){Stop-TCPair InvalidPairing '服务器 WireGuard 身份无效。'}}
function Compare-TCPairBinding {param($Left,$Right)foreach($name in @('RemoteOwnerId','NodeId','ServerPublicKey')){if([string](Get-TCPairProperty $Left $name '') -cne [string](Get-TCPairProperty $Right $name '')){Stop-TCPair PairingMismatch '交接资料的服务器身份不匹配。'}}}
function Get-TCPairDigest {
    param($ClientRequest)
    Assert-TCPairFields $ClientRequest @('SchemaVersion','Kind','RequestId','DeviceId','CreatedAtUtc','ClientPublicKey','AddressFamilies')
    if($ClientRequest.SchemaVersion -ne 1 -or $ClientRequest.Kind -cne 'TradeChannel.ClientRequest' -or (@($ClientRequest.AddressFamilies)-join ',') -cne 'IPv4' -or $ClientRequest.ClientPublicKey -cnotmatch '^[A-Za-z0-9+/]{43}=$'){Stop-TCPair InvalidPairing '设备公开申请不符合 v1 契约。'}
    Assert-TCPairId $ClientRequest.RequestId;Assert-TCPairId $ClientRequest.DeviceId;$null=Get-TCPairTime $ClientRequest.CreatedAtUtc
    # Exact signed timestamp string; do not normalize after signing. Shared with Linux.
    $tuple=@('1','TradeChannel.ClientRequest',[string]$ClientRequest.RequestId,[string]$ClientRequest.DeviceId,[string]$ClientRequest.CreatedAtUtc,[string]$ClientRequest.ClientPublicKey,'IPv4') -join "`n"
    $sha=[Security.Cryptography.SHA256]::Create();try{return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($tuple)))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
}
function Get-TCPairInvite {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Invite,[string]$ConfirmedFingerprint='',[switch]$AllowUnconfirmed)
    Initialize-TCPairCrypto
    try{$unverified=ConvertFrom-TCPairJson ([TradeChannel.Deployment.PairCrypto]::UnverifiedPayload($Invite));$jwk=ConvertTo-TCPairJson $unverified.ManagementSigningPublicKey;$fingerprint=[TradeChannel.Deployment.PairCrypto]::Fingerprint($jwk);$payload=ConvertFrom-TCPairJson ([TradeChannel.Deployment.PairCrypto]::Verify($Invite,$jwk))}catch{Stop-TCPair InvalidInvite '邀请签名、算法或服务器公钥校验失败。'}
    Assert-TCPairFields $payload @('SchemaVersion','Kind','InviteId','RemoteOwnerId','NodeId','ServerPublicKey','ManagementSigningPublicKey','PublicEndpoint','IssuedAtUtc','ExpiresAtUtc','Capabilities','ServerBinding','DeviceName')
    if($payload.SchemaVersion -ne 1 -or $payload.Kind -cne 'TradeChannel.PairInvite'){Stop-TCPair InvalidInvite '邀请协议版本无效。'};Assert-TCPairId $payload.InviteId
    $binding=[pscustomobject]@{RemoteOwnerId=$payload.RemoteOwnerId;NodeId=$payload.NodeId;ServerPublicKey=$payload.ServerPublicKey};Assert-TCPairBinding $binding
    if($payload.PSObject.Properties['ServerBinding']){Compare-TCPairBinding $payload.ServerBinding $binding}
    if((Get-TCPairTime $payload.ExpiresAtUtc) -le [DateTimeOffset]::UtcNow -or (Get-TCPairTime $payload.IssuedAtUtc) -gt [DateTimeOffset]::UtcNow.AddMinutes(5)){Stop-TCPair InviteExpired '邀请已过期或时间不可信，请重新取得邀请。'}
    $module=Get-TCPairModule;& $module {param($Endpoint) $parts=$Endpoint -split ':';if($parts.Count -ne 2){Stop-TCLinux InvalidEndpoint '邀请入口格式无效。'};$null=ConvertTo-TCLinuxIPv4 $parts[0] -Public;if($parts[1] -cnotmatch '^[1-9][0-9]{0,4}$' -or [int]$parts[1] -gt 65535){Stop-TCLinux InvalidEndpoint '邀请端口无效。'}} ([string]$payload.PublicEndpoint)
    $trusted=$ConfirmedFingerprint -ceq $fingerprint
    if(-not $trusted -and -not $AllowUnconfirmed){Stop-TCPair InviteTrustRequired ('请通过可信交接核对邀请签名身份：'+$fingerprint)}
    [pscustomobject]@{Invite=$Invite;Payload=$payload;ServerBinding=$binding;Fingerprint=$fingerprint;Trusted=$trusted;RequiresTrustConfirmation=(-not $trusted)}
}
function Get-TCPairRequestInfo {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$PairRequest)
    Initialize-TCPairCrypto
    try{$unverified=ConvertFrom-TCPairJson ([TradeChannel.Deployment.PairCrypto]::UnverifiedPayload($PairRequest));$jwk=ConvertTo-TCPairJson $unverified.RecipientJwk;$body=ConvertFrom-TCPairJson ([TradeChannel.Deployment.PairCrypto]::Verify($PairRequest,$jwk))}catch{Stop-TCPair InvalidPairRequest '设备申请签名、接收密钥或算法校验失败。'}
    Assert-TCPairFields $body @('SchemaVersion','Kind','InviteId','ServerBinding','ClientRequest','DeviceName','RecipientJwk','RequestDigest','RequestDigestAlgorithm','CreatedAtUtc')
    if($body.SchemaVersion -ne 1 -or $body.Kind -cne 'TradeChannel.PairRequest' -or $body.RequestDigestAlgorithm -cne 'TC-ClientRequest-v1'){Stop-TCPair InvalidPairRequest '设备申请协议无效。'}
    Assert-TCPairId $body.InviteId;Assert-TCPairBinding $body.ServerBinding
    $digest=Get-TCPairDigest $body.ClientRequest;if($body.RequestDigest -cne $digest){Stop-TCPair PairingMismatch '设备申请摘要不匹配。'}
    if(-not $body.DeviceName -or $body.DeviceName.Length -gt 64 -or $body.DeviceName -match '[\x00-\x1f\x7f]' -or (Get-TCPairTime $body.CreatedAtUtc) -gt [DateTimeOffset]::UtcNow.AddMinutes(5)){Stop-TCPair InvalidPairRequest '设备名称或申请时间无效。'}
    [pscustomobject]@{PairRequest=$PairRequest;Payload=$body;RequestId=$body.ClientRequest.RequestId;DeviceId=$body.ClientRequest.DeviceId;RequestDigest=$digest;PairingCode=$digest.Substring(0,12).ToUpperInvariant()}
}
function Resolve-TCPairRoot {param([string]$Root)if(-not $Root){$Root=Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'TradeChannel'};$module=Get-TCPairModule;& $module {param($Path) Get-TCLinuxPath $Path} $Root}
function New-TCPairDirectory {param([string]$Path)$module=Get-TCPairModule;& $module {param($Path) New-TCLinuxDirectory $Path} $Path}
function Write-TCPairState {param([string]$Path,$Value,[switch]$Replace)$module=Get-TCPairModule;if(-not $Replace){& $module {param($Path,$Value) Write-TCLinuxJson $Path $Value} $Path $Value;return}
    & $module {param($Path,$Value) Assert-TCLinuxPrivatePath $Path;$temp=$Path+'.'+[guid]::NewGuid().ToString('N');$backup=$Path+'.previous-'+[guid]::NewGuid().ToString('N');try{Write-TCLinuxJson $temp $Value;[IO.File]::Replace($temp,$Path,$backup)}finally{foreach($candidate in @($temp,$backup)){if(Test-Path -LiteralPath $candidate){Remove-Item -LiteralPath $candidate -Force}}}} $Path $Value
}
function Read-TCPairState {param([string]$Path)$module=Get-TCPairModule;& $module {param($Path) Read-TCLinuxJson $Path 256KB} $Path}
function Protect-TCPairPrivate {param([string]$Plain)Add-Type -AssemblyName System.Security;$bytes=[Text.Encoding]::UTF8.GetBytes($Plain);try{return [Convert]::ToBase64String([Security.Cryptography.ProtectedData]::Protect($bytes,[Text.Encoding]::UTF8.GetBytes('TradeChannel.Pairing.v1'),[Security.Cryptography.DataProtectionScope]::CurrentUser))}finally{[Array]::Clear($bytes,0,$bytes.Length)}}
function Unprotect-TCPairPrivate {param([string]$Protected)Add-Type -AssemblyName System.Security;try{$bytes=[Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($Protected),[Text.Encoding]::UTF8.GetBytes('TradeChannel.Pairing.v1'),[Security.Cryptography.DataProtectionScope]::CurrentUser);return [Text.Encoding]::UTF8.GetString($bytes)}catch{Stop-TCPair PrivateKeyUnavailable '本机交接私钥无法解密，请使用原电脑或重新申请。'}finally{if($bytes){[Array]::Clear($bytes,0,$bytes.Length)}}}
function New-TCPairRequest {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Invite,[Parameter(Mandatory=$true)][string]$ConfirmedFingerprint,[string]$DeviceName=$env:COMPUTERNAME,[string]$Root,[string]$WgPath)
    $verified=Get-TCPairInvite -Invite $Invite -ConfirmedFingerprint $ConfirmedFingerprint
    if(-not $DeviceName -or $DeviceName.Length -gt 64 -or $DeviceName -match '[\x00-\x1f\x7f]'){Stop-TCPair InvalidDeviceName '设备名称必须是 1 至 64 个可显示字符。'}
    $base=Resolve-TCPairRoot $Root;New-TCPairDirectory $base;$identities=Join-Path $base 'identities';New-TCPairDirectory $identities
    # Reuse the original pending application rather than silently consuming a new identity on retry.
    foreach($entry in @(Get-ChildItem -LiteralPath $identities -Directory)){if($entry.Name -cnotmatch '^[0-9a-f-]{36}$'){continue};$file=Join-Path $entry.FullName 'enrollment.json';if(Test-Path -LiteralPath $file){$existing=Read-TCPairState $file;if($existing.InviteId -ceq $verified.Payload.InviteId -and $existing.State -in @('Requested','Completed')){Compare-TCPairBinding $existing.ServerBinding $verified.ServerBinding;return [pscustomobject]@{EnrollmentId=$existing.EnrollmentId;PairRequest=$existing.PairRequest;RequestId=$existing.ClientRequest.RequestId;DeviceId=$existing.ClientRequest.DeviceId;RequestDigest=$existing.RequestDigest;PairingCode=$existing.RequestDigest.Substring(0,12).ToUpperInvariant();Status='ExistingRequest'}}}}
    $id=[guid]::NewGuid().ToString();$directory=Join-Path $identities $id;New-TCPairDirectory $directory;$requestDirectory=Join-Path $directory 'client';if(-not $WgPath){$WgPath=Join-Path $PSScriptRoot 'assets\wg.exe'}
    $module=Get-TCPairModule;$created=& $module {param($Directory,$WgPath) New-TCLinuxClientRequest $Directory $WgPath} $requestDirectory $WgPath
    $request=Read-TCPairState (Join-Path $requestDirectory 'public.request.json');$digest=Get-TCPairDigest $request;$private=[TradeChannel.Deployment.PairCrypto]::NewPrivateKey();$jwk=ConvertFrom-TCPairJson ([TradeChannel.Deployment.PairCrypto]::PublicJwk($private))
    $body=[ordered]@{SchemaVersion=1;Kind='TradeChannel.PairRequest';InviteId=$verified.Payload.InviteId;ServerBinding=$verified.ServerBinding;ClientRequest=$request;DeviceName=$DeviceName;RecipientJwk=$jwk;RequestDigest=$digest;RequestDigestAlgorithm='TC-ClientRequest-v1';CreatedAtUtc=[DateTime]::UtcNow.ToString('o')}
    $signed=[TradeChannel.Deployment.PairCrypto]::Sign((ConvertTo-TCPairJson $body),$private)
    $keyPath=Join-Path $requestDirectory 'client.key';$wgPrivate=[IO.File]::ReadAllText($keyPath).Trim()
    try{Write-TCPairState (Join-Path $directory 'private.dpapi.json') @{SchemaVersion=1;Kind='TradeChannel.PairingPrivate';Protected=(Protect-TCPairPrivate (ConvertTo-TCPairJson @{RecipientPrivateKey=$private;WireGuardPrivateKey=$wgPrivate}))};Remove-Item -LiteralPath $keyPath -Force}finally{$private=$null;$wgPrivate=$null}
    $state=[ordered]@{SchemaVersion=1;Kind='TradeChannel.Enrollment';EnrollmentId=$id;InviteId=$verified.Payload.InviteId;Invite=$Invite;ServerBinding=$verified.ServerBinding;ManagementSigningPublicKey=$verified.Payload.ManagementSigningPublicKey;ConfirmedFingerprint=$ConfirmedFingerprint;ClientRequest=$request;RequestDigest=$digest;PairRequest=$signed;State='Requested';CreatedAtUtc=[DateTime]::UtcNow.ToString('o')}
    Write-TCPairState (Join-Path $directory 'enrollment.json') $state
    [pscustomobject]@{EnrollmentId=$id;PairRequest=$signed;RequestId=$request.RequestId;DeviceId=$request.DeviceId;RequestDigest=$digest;PairingCode=$digest.Substring(0,12).ToUpperInvariant();Status='RequestCreated'}
}
function Assert-TCPairAuthorization {
    param($Authorization,$Request,$Invite)
    Assert-TCPairFields $Authorization @('SchemaVersion','Kind','InviteId','ServerBinding','RemoteOwnerId','NodeId','DeviceId','ClientPublicKey','ClientAddress','ConfigRevision','ClientResponse','IssuedAtUtc','ExpiresAtUtc','RequestDigest','RequestDigestAlgorithm','RequestId')
    if($Authorization.SchemaVersion -ne 1 -or $Authorization.Kind -cne 'TradeChannel.PairAuthorization' -or $Authorization.RequestDigestAlgorithm -cne 'TC-ClientRequest-v1' -or $Authorization.InviteId -cne $Request.InviteId -or $Authorization.RequestDigest -cne $Request.RequestDigest){Stop-TCPair AuthorizationMismatch '服务器授权与设备申请不匹配。'}
    Compare-TCPairBinding $Authorization.ServerBinding $Request.ServerBinding;Compare-TCPairBinding $Authorization.ServerBinding $Invite.ServerBinding
    if($Authorization.NodeId -cne $Request.ServerBinding.NodeId -or $Authorization.RemoteOwnerId -cne $Request.ServerBinding.RemoteOwnerId -or $Authorization.DeviceId -cne $Request.ClientRequest.DeviceId -or $Authorization.ClientPublicKey -cne $Request.ClientRequest.ClientPublicKey -or $Authorization.ClientResponse.RequestId -cne $Request.ClientRequest.RequestId -or $Authorization.ClientResponse.DeviceId -cne $Request.ClientRequest.DeviceId -or $Authorization.ClientResponse.ClientPublicKey -cne $Request.ClientRequest.ClientPublicKey -or $Authorization.ClientResponse.ServerPublicKey -cne $Request.ServerBinding.ServerPublicKey -or $Authorization.ClientResponse.NodeId -cne $Request.ServerBinding.NodeId){Stop-TCPair AuthorizationMismatch '授权返回的设备或服务器身份不匹配。'}
    if((Get-TCPairTime $Authorization.ExpiresAtUtc) -le [DateTimeOffset]::UtcNow -or (Get-TCPairTime $Authorization.IssuedAtUtc) -gt [DateTimeOffset]::UtcNow.AddMinutes(5)){Stop-TCPair AuthorizationExpired '授权交接已过期；管理端应核对原申请并重新取得返回，不新增设备。'}
}
function Protect-TCPairAuthorization {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$SignedAuthorization,[Parameter(Mandatory=$true)][string]$PairRequest,[Parameter(Mandatory=$true)][string]$Invite)
    $request=Get-TCPairRequestInfo $PairRequest
    # The management endpoint already authenticated this invitation via SSH. Still verify signature and binding.
    Initialize-TCPairCrypto;$unverified=ConvertFrom-TCPairJson ([TradeChannel.Deployment.PairCrypto]::UnverifiedPayload($Invite));$jwk=ConvertTo-TCPairJson $unverified.ManagementSigningPublicKey
    try{$inviteBody=ConvertFrom-TCPairJson ([TradeChannel.Deployment.PairCrypto]::Verify($Invite,$jwk));$authorization=ConvertFrom-TCPairJson ([TradeChannel.Deployment.PairCrypto]::Verify($SignedAuthorization,$jwk))}catch{Stop-TCPair InvalidAuthorization '服务器授权签名校验失败。'}
    $binding=[pscustomobject]@{RemoteOwnerId=$inviteBody.RemoteOwnerId;NodeId=$inviteBody.NodeId;ServerPublicKey=$inviteBody.ServerPublicKey};Assert-TCPairBinding $binding
    if($inviteBody.InviteId -cne $request.Payload.InviteId){Stop-TCPair AuthorizationMismatch '邀请与设备申请不匹配。'}
    Assert-TCPairAuthorization $authorization $request.Payload @{ServerBinding=$binding}
    $cipher=[TradeChannel.Deployment.PairCrypto]::Encrypt($SignedAuthorization,(ConvertTo-TCPairJson $request.Payload.RecipientJwk))
    [pscustomobject]@{EncryptedAuthorization=$cipher;RequestId=$request.RequestId;RequestDigest=$request.RequestDigest;Status='AuthorizationEncrypted'}
}
function Get-TCPairEnrollment {
    [CmdletBinding()]param([string]$Root,[Parameter(Mandatory=$true)][string]$EnrollmentId)
    Assert-TCPairId $EnrollmentId;$path=Join-Path (Join-Path (Join-Path (Resolve-TCPairRoot $Root) 'identities') $EnrollmentId) 'enrollment.json';$value=Read-TCPairState $path
    if($value.SchemaVersion -ne 1 -or $value.Kind -cne 'TradeChannel.Enrollment' -or $value.EnrollmentId -cne $EnrollmentId){Stop-TCPair InvalidEnrollment '本机接入申请记录无效。'};return $value
}
function Complete-TCPairAuthorization {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$EncryptedAuthorization,[Parameter(Mandatory=$true)][string]$EnrollmentId,[string]$Root)
    Initialize-TCPairCrypto;$state=Get-TCPairEnrollment -Root $Root -EnrollmentId $EnrollmentId;$directory=Join-Path (Join-Path (Resolve-TCPairRoot $Root) 'identities') $EnrollmentId
    $secret=Read-TCPairState (Join-Path $directory 'private.dpapi.json');$private=ConvertFrom-TCPairJson (Unprotect-TCPairPrivate $secret.Protected)
    try{$signed=[TradeChannel.Deployment.PairCrypto]::Decrypt($EncryptedAuthorization,$private.RecipientPrivateKey);$authorization=ConvertFrom-TCPairJson ([TradeChannel.Deployment.PairCrypto]::Verify($signed,(ConvertTo-TCPairJson $state.ManagementSigningPublicKey)))}catch{Stop-TCPair InvalidAuthorization '授权密文、服务器签名或接收身份校验失败。'}
    $request=(Get-TCPairRequestInfo $state.PairRequest).Payload;Assert-TCPairAuthorization $authorization $request $state
    if([TradeChannel.Deployment.PairCrypto]::Fingerprint((ConvertTo-TCPairJson $state.ManagementSigningPublicKey)) -cne $state.ConfirmedFingerprint){Stop-TCPair InviteTrustChanged '已固定的服务器签名身份发生变化。'}
    $requestDirectory=Join-Path $directory 'client';$responsePath=Join-Path $directory 'public.response.json';$destination=Join-Path $directory 'client.conf';$keyPath=Join-Path $requestDirectory 'client.key'
    if(-not (Test-Path -LiteralPath $responsePath)){Write-TCPairState $responsePath $authorization.ClientResponse}else{
        $existing=Read-TCPairState $responsePath
        foreach($field in @('RequestId','DeviceId','NodeId','ClientPublicKey','ServerPublicKey','ClientAddress','ServerAddress','TunnelSubnet','PublicEndpoint','PersistentKeepalive')){if([string](Get-TCPairProperty $existing $field '') -cne [string](Get-TCPairProperty $authorization.ClientResponse $field '')){Stop-TCPair ResponseChanged '本机已有不同设备、服务器或连接地址的返回，请先核对原身份。'}}
        if([int]$authorization.ClientResponse.ConfigRevision -lt [int]$existing.ConfigRevision){Stop-TCPair ResponseChanged '授权返回的配置修订早于本机记录，请取得当前返回。'}
        $store=Import-Module (Join-Path $PSScriptRoot 'DeploymentStore.psm1') -PassThru -DisableNameChecking
        $oldDigest=& $store {param($Value) Get-TCDDigest $Value} $existing;$newDigest=& $store {param($Value) Get-TCDDigest $Value} $authorization.ClientResponse
        if($oldDigest -cne $newDigest){
            if([int]$authorization.ClientResponse.ConfigRevision -eq [int]$existing.ConfigRevision){Stop-TCPair ResponseChanged '相同修订号的授权内容发生变化，请核对服务器状态。'}
            Write-TCPairState $responsePath $authorization.ClientResponse -Replace
        }
    }
    $receiptPath=Join-Path $directory 'authorization.dpapi.json'
    $receipt=@{SchemaVersion=1;Kind='TradeChannel.PairAuthorizationPrivate';Protected=(Protect-TCPairPrivate $signed)}
    Write-TCPairState $receiptPath $receipt -Replace:(Test-Path -LiteralPath $receiptPath)
    $module=Get-TCPairModule
    try {
        & $module {param($Path,$Key) $null=Get-TCLinuxPath $Path
            if(Test-Path -LiteralPath $Path){Assert-TCLinuxPrivatePath $Path;if((Get-Item -LiteralPath $Path).Length -gt 256 -or [IO.File]::ReadAllText($Path).Trim() -cne $Key){Stop-TCLinux PrivateKeyChanged '中断遗留的本机合成密钥与原申请不匹配，未覆盖。'}}
            else{$file=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);$file.Dispose();Protect-TCLinuxPath $Path;[IO.File]::WriteAllText($Path,($Key+"`r`n"),(New-Object Text.UTF8Encoding($false)))}
        } $keyPath $private.WireGuardPrivateKey
        $clientModule=Import-Module (Join-Path $PSScriptRoot 'ServerSetup.psm1') -PassThru -DisableNameChecking
        $result=& $clientModule {param($Directory,$Response,$Destination) Complete-TCClientConfig -RequestDirectory $Directory -ResponsePath $Response -Destination $Destination} $requestDirectory $responsePath $destination
    } finally {if(Test-Path -LiteralPath $keyPath){Remove-Item -LiteralPath $keyPath -Force};$private=$null}
    $state.State='Completed';if(-not $state.PSObject.Properties['CompletedAtUtc']){$state|Add-Member NoteProperty CompletedAtUtc ([DateTime]::UtcNow.ToString('o'))};Write-TCPairState (Join-Path $directory 'enrollment.json') $state -Replace
    $out=[pscustomobject]@{Status='ConfigCompleted';ConfigPath=$result.ConfigPath;NodeId=$authorization.NodeId;DeviceId=$authorization.DeviceId;ResponsePath=$responsePath;RequestDirectory=$requestDirectory;EnrollmentId=$EnrollmentId;NodeName=$authorization.ClientResponse.NodeName;ExternalConnectivity='NotTested'}
    if($authorization.ClientResponse.PSObject.Properties['Transport']){$out|Add-Member NoteProperty Transport $authorization.ClientResponse.Transport};return $out
}
function Resume-TCPairAuthorization {
    [CmdletBinding()]param([string]$Root,[Parameter(Mandatory=$true)][string]$EnrollmentId)
    Initialize-TCPairCrypto;$state=Get-TCPairEnrollment -Root $Root -EnrollmentId $EnrollmentId;$directory=Join-Path (Join-Path (Resolve-TCPairRoot $Root) 'identities') $EnrollmentId
    $receipt=Read-TCPairState (Join-Path $directory 'authorization.dpapi.json')
    if($receipt.Kind -cne 'TradeChannel.PairAuthorizationPrivate' -or $receipt.SchemaVersion -ne 1){Stop-TCPair AuthorizationUnavailable '本机没有可恢复的已验签授权，请重新取得对应返回。'}
    $signed=Unprotect-TCPairPrivate $receipt.Protected;$request=Get-TCPairRequestInfo $state.PairRequest
    # The normal completion path verifies server signature, request binding and expiry again.
    try{$encrypted=[TradeChannel.Deployment.PairCrypto]::Encrypt($signed,(ConvertTo-TCPairJson $request.Payload.RecipientJwk));Complete-TCPairAuthorization -Root $Root -EnrollmentId $EnrollmentId -EncryptedAuthorization $encrypted}finally{$signed=$null;$encrypted=$null}
}
function Export-TCManagementRecovery {
    [CmdletBinding()]param([Parameter(Mandatory=$true)]$ServerRecord,$Credential,[Parameter(Mandatory=$true)][Security.SecureString]$Password,[ValidateRange(10000,120000)][int]$Iterations=120000)
    Initialize-TCPairCrypto;Assert-TCPairFields $ServerRecord @('LocalRecordId','RemoteOwnerId','NodeId','ServerPublicKey','Name','Endpoints','Connection','PinnedHostKey','ManagementSigningPublicKey','CapabilityVersion','OwnershipState','ManagementAccessState','LinkedNodeIds','SourceJobIds','LastCheckedUtc','CredentialRef','Protocols','ObservedExit','ExpectedExitIPv4','ExpectedExitSource','CreatedAtUtc','UpdatedAtUtc')
    $allowed=[ordered]@{};foreach($name in @('RemoteOwnerId','NodeId','ServerPublicKey','Name','Endpoints','Connection','PinnedHostKey','ManagementSigningPublicKey','Protocols','CapabilityVersion')){$value=Get-TCPairProperty $ServerRecord $name;if($null -ne $value){$allowed[$name]=$value}}
    if($allowed.Contains('Connection')){Assert-TCPairFields $allowed.Connection @('Host','Port','User','IdentityFile');$allowed.Connection=@{Host=$allowed.Connection.Host;Port=$allowed.Connection.Port;User=$allowed.Connection.User}}
    $bundle=[ordered]@{SchemaVersion=1;Kind='TradeChannel.ManagementRecovery';Server=$allowed;CreatedAtUtc=[DateTime]::UtcNow.ToString('o');IncludesCredential=($null -ne $Credential)}
    $transport=Import-Module (Join-Path $PSScriptRoot 'DeploymentTransport.psm1') -PassThru -DisableNameChecking
    if($Credential){$bundle.Credential=& $transport {param($Value) ConvertTo-TCDeployCredential $Value} $Credential}
    $pass=& $transport {param($Value) ConvertTo-TCDeploySecret $Value} $Password
    try{$encrypted=[TradeChannel.Deployment.PairCrypto]::EncryptRecovery((ConvertTo-TCPairJson $bundle),$pass,$Iterations);return [pscustomobject]@{Recovery=$encrypted;IncludesCredential=$bundle.IncludesCredential;Status='RecoveryEncrypted';Iterations=$Iterations}}finally{$pass=$null;if($bundle.Contains('Credential')){$bundle.Credential.Clear()}}
}
function Import-TCManagementRecovery {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Recovery,[Parameter(Mandatory=$true)][Security.SecureString]$Password)
    Initialize-TCPairCrypto;$transport=Import-Module (Join-Path $PSScriptRoot 'DeploymentTransport.psm1') -PassThru -DisableNameChecking;$pass=& $transport {param($Value) ConvertTo-TCDeploySecret $Value} $Password
    try{$bundle=ConvertFrom-TCPairJson ([TradeChannel.Deployment.PairCrypto]::DecryptRecovery($Recovery,$pass))}catch{Stop-TCPair RecoveryInvalid '恢复包密码、完整性、算法或 KDF 参数校验失败。'}finally{$pass=$null}
    Assert-TCPairFields $bundle @('SchemaVersion','Kind','Server','CreatedAtUtc','IncludesCredential','Credential');if($bundle.SchemaVersion -ne 1 -or $bundle.Kind -cne 'TradeChannel.ManagementRecovery' -or $bundle.IncludesCredential -isnot [bool]){Stop-TCPair RecoveryInvalid '恢复包格式无效。'}
    Assert-TCPairFields $bundle.Server @('RemoteOwnerId','NodeId','ServerPublicKey','Name','Endpoints','Connection','PinnedHostKey','ManagementSigningPublicKey','Protocols','CapabilityVersion')
    $credential=$null;if($bundle.IncludesCredential){$credential=@{Kind=$bundle.Credential.Kind};foreach($name in @('Password','PrivateKeyPem','Passphrase')){if($bundle.Credential.PSObject.Properties[$name]){$credential[$name]=ConvertTo-SecureString $bundle.Credential.$name -AsPlainText -Force;$bundle.Credential.$name=$null}}}
    [pscustomobject]@{Status='AwaitIdentityVerification';ServerRecord=$bundle.Server;Credential=$credential;IncludesCredential=$bundle.IncludesCredential;RequiresRemoteVerification=$true;Activated=$false}
}
Export-ModuleMember -Function Get-TCPairInvite,New-TCPairRequest,Get-TCPairRequestInfo,Get-TCPairEnrollment,Protect-TCPairAuthorization,Complete-TCPairAuthorization,Resume-TCPairAuthorization,Export-TCManagementRecovery,Import-TCManagementRecovery
