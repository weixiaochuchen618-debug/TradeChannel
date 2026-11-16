#requires -Version 5.1
Set-StrictMode -Version 2.0
$script:TCPairOnlinePairModule=$null

function Stop-TCPairOnline {param([string]$Code,[string]$Message)throw [InvalidOperationException]::new('[TC:'+$Code+'] '+$Message)}
function Initialize-TCPairOnline {
    if(-not $script:TCPairOnlinePairModule){$script:TCPairOnlinePairModule=Import-Module (Join-Path $PSScriptRoot 'DeploymentPairing.psm1') -PassThru -DisableNameChecking -ErrorAction Stop}
    & $script:TCPairOnlinePairModule {Initialize-TCPairCrypto}
    if(-not ('TradeChannel.Deployment.PairingOnlineTransport' -as [type])){
        Import-Module (Join-Path $PSScriptRoot 'DeploymentDependencies.psm1') -DisableNameChecking
        $null=Test-TCDeploymentDependencies -PackageRoot $PSScriptRoot
        $library=Join-Path $PSScriptRoot 'assets\lib'
        foreach($file in @('System.Runtime.CompilerServices.Unsafe.dll','System.Memory.dll','System.Buffers.dll','System.Threading.Tasks.Extensions.dll','Microsoft.Bcl.AsyncInterfaces.dll','Microsoft.Extensions.Logging.Abstractions.dll','BouncyCastle.Cryptography.dll','Renci.SshNet.dll')){
            $null=[Reflection.Assembly]::LoadFrom((Join-Path $library $file))
        }
        # Packages ship the helper pre-compiled with the release version; a source tree compiles it once per process.
        $compiled=Join-Path $PSScriptRoot 'deployment\PairingOnlineTransport.dll'
        if([IO.File]::Exists($compiled)){$null=[Reflection.Assembly]::LoadFrom($compiled)}
        else{Add-Type -Path (Join-Path $PSScriptRoot 'deployment\PairingOnlineTransport.cs') -ReferencedAssemblies @('System.dll','System.Core.dll',(Join-Path $library 'Renci.SshNet.dll')) -ErrorAction Stop}
        [TradeChannel.Deployment.PairingOnlineTransport]::InitializeDependencies($library)
    }
}
function ConvertFrom-TCPairOnlineJson {
    param([string]$Text)
    if(-not $Text -or [Text.Encoding]::UTF8.GetByteCount($Text) -gt 256KB){Stop-TCPairOnline InvalidOnlineJson '邀请码数据为空或过长。'}
    try{return $Text|ConvertFrom-Json -ErrorAction Stop}catch{Stop-TCPairOnline InvalidOnlineJson '邀请码数据无法解析。'}
}
function Assert-TCPairOnlineFields {
    param($Value,[string[]]$Names)
    if($null -eq $Value -or $Value -isnot [pscustomobject]){Stop-TCPairOnline InvalidOnlineInput '邀请码对象格式无效。'}
    $fields=@($Value.PSObject.Properties.Name)
    if($fields.Count -ne $Names.Count){Stop-TCPairOnline InvalidOnlineInput '邀请码字段不完整。'}
    foreach($field in $fields){if($field -cnotin $Names){Stop-TCPairOnline InvalidOnlineInput '邀请码包含不支持的字段。'}}
}
function ConvertFrom-TCPairOnlineCode {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$InvitationCode,[switch]$AllowLoopback,[switch]$AllowRetry)
    Initialize-TCPairOnline
    $code=$InvitationCode.Trim()
    if($code.Length -gt 2048 -or $code -cnotmatch '^TCI1\.[A-Za-z0-9_-]+$'){Stop-TCPairOnline InvalidOnlineCode '请输入完整的一次性邀请码。'}
    try{$raw=[TradeChannel.Deployment.PairCrypto]::Unb64($code.Substring(5));$value=ConvertFrom-TCPairOnlineJson ((New-Object Text.UTF8Encoding($false,$true)).GetString($raw))}catch{Stop-TCPairOnline InvalidOnlineCode '邀请码编码无效。'}
    Assert-TCPairOnlineFields $value @('v','h','p','i','k','t','m','e')
    if($value.v -isnot [int] -or $value.v -ne 1 -or $value.p -isnot [int] -or $value.p -lt 1024 -or $value.p -gt 65535 -or $value.i -cnotmatch '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' -or $value.k -cnotmatch '^[A-Za-z0-9_-]{43}$' -or $value.t -cnotmatch '^[0-9a-f]{64}$' -or $value.m -cnotmatch '^SHA256:[A-Za-z0-9+/]{43}$' -or ($value.e -isnot [int] -and $value.e -isnot [long])){Stop-TCPairOnline InvalidOnlineCode '邀请码版本或身份字段无效。'}
    $address=$null
    if(-not [Net.IPAddress]::TryParse([string]$value.h,[ref]$address) -or $address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or $address.ToString() -cne $value.h){Stop-TCPairOnline InvalidOnlineHost '邀请码服务器地址无效。'}
    if([Net.IPAddress]::IsLoopback($address)){
        if(-not $AllowLoopback){Stop-TCPairOnline InvalidOnlineHost '回环邀请码只用于隔离测试。'}
    }else{
        & $script:TCPairOnlinePairModule {param($Address)$linux=Get-TCPairModule;& $linux {param($Ip)$null=ConvertTo-TCLinuxIPv4 $Ip -Public} $Address} ([string]$value.h)
    }
    $now=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds();$grace=if($AllowRetry){120}else{0}
    if([long]$value.e+$grace -le $now){Stop-TCPairOnline OnlineInviteExpired '邀请码已过期；原申请和离线交接资料仍保留。'}
    # 0.22.0 lets the management computer pick a lifetime up to 24 hours; the
    # 300 second slack covers clock skew between the two computers.
    if([long]$value.e -gt $now+86400+300){Stop-TCPairOnline InvalidOnlineCode '邀请码有效期超过登记上限（最长 24 小时）。'}
    [pscustomobject]@{Code=$code;InviteId=[string]$value.i;PublicHost=[string]$value.h;Port=[int]$value.p;Token=[string]$value.k;TlsSha256=[string]$value.t;ManagementFingerprint=[string]$value.m;ExpiresAtUtc=[DateTimeOffset]::FromUnixTimeSeconds([long]$value.e).UtcDateTime.ToString('o');ExpiresUnix=[long]$value.e;Url=('https://'+$value.h+':'+$value.p+'/v1/invitations/'+$value.i);RetryOnly=([long]$value.e -le $now)}
}
function Invoke-TCPairOnlineHttp {
    param($Code,[ValidateSet('GET','POST')][string]$Method,$Value)
    $url=$Code.Url;$body=''
    if($Method -ceq 'POST'){$url+='/consume';$body=$Value|ConvertTo-Json -Depth 16 -Compress}
    $reply=[TradeChannel.Deployment.PairingOnlineTransport]::Request($url,$Code.TlsSha256,$Code.Token,$Method,$body,60000)
    $envelope=ConvertFrom-TCPairOnlineJson $reply.Body
    if(-not $envelope.PSObject.Properties['Ok'] -or $envelope.Ok -isnot [bool]){Stop-TCPairOnline InvalidOnlineResponse '服务器未返回可验证的登记结果。'}
    if(-not $envelope.Ok){
        $reason='OnlineOperationFailed'
        if($envelope.PSObject.Properties['Code'] -and $envelope.Code -cmatch '^[A-Za-z][A-Za-z0-9]{0,63}$'){$reason=[string]$envelope.Code}
        Stop-TCPairOnline $reason '在线登记未完成；重试会沿用原申请，不会新建设备。'
    }
    if($reply.StatusCode -ne 200 -or -not $envelope.PSObject.Properties['Data']){Stop-TCPairOnline InvalidOnlineResponse '在线登记返回状态不一致。'}
    return $envelope.Data
}
function Get-TCPairOnlineInvitation {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$InvitationCode,[switch]$AllowLoopback)
    $code=ConvertFrom-TCPairOnlineCode -InvitationCode $InvitationCode -AllowLoopback:$AllowLoopback
    $result=Invoke-TCPairOnlineHttp $code GET
    Assert-TCPairOnlineFields $result @('Status','SignedDescriptor')
    try{
        $untrusted=ConvertFrom-TCPairOnlineJson ([TradeChannel.Deployment.PairCrypto]::UnverifiedPayload($result.SignedDescriptor))
        $verified=Get-TCPairInvite -Invite $untrusted.Invite -ConfirmedFingerprint $code.ManagementFingerprint
        $public=$verified.Payload.ManagementSigningPublicKey|ConvertTo-Json -Compress
        $descriptor=ConvertFrom-TCPairOnlineJson ([TradeChannel.Deployment.PairCrypto]::Verify($result.SignedDescriptor,$public))
    }catch{Stop-TCPairOnline OnlineInviteIdentityMismatch '服务器签名与邀请码固定的身份不一致。'}
    Assert-TCPairOnlineFields $descriptor @('SchemaVersion','Kind','InviteId','Invite','PublicHost','Port','TlsSha256','ManagementFingerprint','ExpiresAtUtc','RetryUntilUtc')
    $expires=[DateTimeOffset]::Parse($descriptor.ExpiresAtUtc).ToUnixTimeSeconds()
    $retry=[DateTimeOffset]::Parse($descriptor.RetryUntilUtc).ToUnixTimeSeconds()
    if($descriptor.SchemaVersion -ne 1 -or $descriptor.Kind -cne 'TradeChannel.OnlineInvite' -or $descriptor.InviteId -cne $code.InviteId -or $verified.Payload.InviteId -cne $code.InviteId -or $descriptor.PublicHost -cne $code.PublicHost -or $descriptor.Port -ne $code.Port -or $descriptor.TlsSha256 -cne $code.TlsSha256 -or $descriptor.ManagementFingerprint -cne $code.ManagementFingerprint -or $expires -ne $code.ExpiresUnix -or $retry -ne $expires+120 -or $descriptor.ExpiresAtUtc -cne $verified.Payload.ExpiresAtUtc){Stop-TCPairOnline OnlineInviteIdentityMismatch '在线入口、有效期和邀请签名绑定不一致。'}
    [pscustomobject]@{Status=$result.Status;InviteId=$code.InviteId;Invite=$descriptor.Invite;Fingerprint=$code.ManagementFingerprint;ServerBinding=$verified.ServerBinding;ExpiresAtUtc=$descriptor.ExpiresAtUtc;RetryUntilUtc=$descriptor.RetryUntilUtc;NetworkChanged=$false}
}
function New-TCPairOnlineEnrollment {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$InvitationCode,[Parameter(Mandatory=$true)][string]$Root,[string]$DeviceName=$env:COMPUTERNAME,[string]$WgPath,[switch]$AllowLoopback)
    if(-not $DeviceName -or $DeviceName.Length -gt 64 -or $DeviceName.Trim() -cne $DeviceName -or $DeviceName -match '[\p{C}\p{Zl}\p{Zp}]'){Stop-TCPairOnline InvalidDeviceName '设备名称须为 1 至 64 个可显示字符，首尾不能有空格。'}
    $code=ConvertFrom-TCPairOnlineCode -InvitationCode $InvitationCode -AllowLoopback:$AllowLoopback -AllowRetry
    $existing=@(Get-TCPairEnrollments -Root $Root|Where-Object {$_.InviteId -ceq $code.InviteId})
    if($existing.Count -gt 1){Stop-TCPairOnline OnlineEnrollmentConflict '同一邀请已有多份本机申请，请先恢复原申请。'}
    if($existing.Count -eq 1){
        $state=Get-TCPairEnrollment -Root $Root -EnrollmentId $existing[0].EnrollmentId
        if($state.ConfirmedFingerprint -cne $code.ManagementFingerprint){Stop-TCPairOnline OnlineInviteIdentityMismatch '原申请已固定另一管理签名身份。'}
        $enrollment=[pscustomobject]@{EnrollmentId=$state.EnrollmentId;RequestId=$state.ClientRequest.RequestId;DeviceId=$state.ClientRequest.DeviceId;RequestDigest=$state.RequestDigest;Status='ExistingRequest'}
    }else{
        if($code.RetryOnly){Stop-TCPairOnline OnlineInviteExpired '邀请码已过期，不能再生成新申请。'}
        $invitation=Get-TCPairOnlineInvitation -InvitationCode $InvitationCode -AllowLoopback:$AllowLoopback
        if($invitation.Status -cne 'InvitationReady'){Stop-TCPairOnline InviteConsumed '邀请码已被使用；请在原申请电脑上重试。'}
        $enrollment=New-TCPairRequest -Invite $invitation.Invite -ConfirmedFingerprint $invitation.Fingerprint -DeviceName $DeviceName -Root $Root -WgPath $WgPath
    }
    & $script:TCPairOnlinePairModule {
        param($Root,$EnrollmentId,$Code)
        $base=Resolve-TCPairRoot $Root;$path=Join-Path (Join-Path (Join-Path $base 'identities') $EnrollmentId) 'online.dpapi.json'
        if(Test-Path -LiteralPath $path){
            $previous=Read-TCPairState $path
            if($previous.Kind -cne 'TradeChannel.OnlineEnrollment' -or (Unprotect-TCPairPrivate $previous.Protected) -cne $Code){Stop-TCPair OnlineInviteIdentityMismatch '本机原申请已固定另一个在线入口。'}
        }else{Write-TCPairState $path @{SchemaVersion=1;Kind='TradeChannel.OnlineEnrollment';Protected=(Protect-TCPairPrivate $Code)}}
    } $Root $enrollment.EnrollmentId $code.Code
    [pscustomobject]@{Status=$enrollment.Status;EnrollmentId=$enrollment.EnrollmentId;RequestId=$enrollment.RequestId;DeviceId=$enrollment.DeviceId;RequestDigest=$enrollment.RequestDigest;InviteId=$code.InviteId;ExpiresAtUtc=$code.ExpiresAtUtc;NetworkChanged=$false}
}
function Complete-TCPairOnlineEnrollment {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][string]$EnrollmentId,[switch]$AllowLoopback)
    Initialize-TCPairOnline
    $state=Get-TCPairEnrollment -Root $Root -EnrollmentId $EnrollmentId
    $location=& $script:TCPairOnlinePairModule {param($Root,$Id)Join-Path (Join-Path (Resolve-TCPairRoot $Root) 'identities') $Id} $Root $EnrollmentId
    $lockPath=Join-Path $location '.online.lock'
    try{$guard=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}catch{Stop-TCPairOnline PairingBusy '本机正在完成此申请，请稍后重试。'}
    try{
        if($state.State -ceq 'Completed' -or (Test-Path -LiteralPath (Join-Path $location 'authorization.dpapi.json'))){
            $completed=Resume-TCPairAuthorization -Root $Root -EnrollmentId $EnrollmentId
        }else{
            $text=& $script:TCPairOnlinePairModule {param($Path)$saved=Read-TCPairState $Path;if($saved.SchemaVersion -ne 1 -or $saved.Kind -cne 'TradeChannel.OnlineEnrollment'){Stop-TCPair InvalidOnlineEnrollment '本机在线申请记录无效。'};Unprotect-TCPairPrivate $saved.Protected} (Join-Path $location 'online.dpapi.json')
            $code=ConvertFrom-TCPairOnlineCode -InvitationCode $text -AllowLoopback:$AllowLoopback -AllowRetry;$text=$null
            if($state.InviteId -cne $code.InviteId -or $state.ConfirmedFingerprint -cne $code.ManagementFingerprint){Stop-TCPairOnline OnlineInviteIdentityMismatch '在线邀请码与本机原申请不匹配。'}
            $answer=Invoke-TCPairOnlineHttp $code POST @{PairRequest=$state.PairRequest}
            Assert-TCPairOnlineFields $answer @('Status','RequestId','RequestDigest','EncryptedAuthorization')
            if($answer.Status -cne 'Authorized' -or $answer.RequestId -cne $state.ClientRequest.RequestId -or $answer.RequestDigest -cne $state.RequestDigest){Stop-TCPairOnline OnlineAuthorizationMismatch '授权返回不属于本机原申请。'}
            $completed=Complete-TCPairAuthorization -Root $Root -EnrollmentId $EnrollmentId -EncryptedAuthorization $answer.EncryptedAuthorization
        }
        $completed|Add-Member NoteProperty NetworkChanged $false -Force
        $completed|Add-Member NoteProperty OnlineStatus 'AuthorizationReceived' -Force
        $completed|Add-Member NoteProperty RequestId $state.ClientRequest.RequestId -Force
        $completed|Add-Member NoteProperty RequestDigest $state.RequestDigest -Force
        return $completed
    }finally{if($guard){$guard.Dispose()}}
}
function Invoke-TCPairOnlineEnrollment {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$InvitationCode,[Parameter(Mandatory=$true)][string]$Root,[string]$DeviceName=$env:COMPUTERNAME,[string]$WgPath,[switch]$AllowLoopback)
    $pending=New-TCPairOnlineEnrollment -InvitationCode $InvitationCode -Root $Root -DeviceName $DeviceName -WgPath $WgPath -AllowLoopback:$AllowLoopback
    Complete-TCPairOnlineEnrollment -Root $Root -EnrollmentId $pending.EnrollmentId -AllowLoopback:$AllowLoopback
}
function New-TCPairOnlineSshPayload {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][ValidateSet('create','status','cancel')][string]$Action,[Parameter(Mandatory=$true)]$InputData,[switch]$UseSudo)
    Initialize-TCPairOnline
    $sources=[ordered]@{}
    Import-Module (Join-Path $PSScriptRoot 'ConnectionMethods.psm1') -DisableNameChecking -ErrorAction Stop
    $sources['connection_methods.py']=Get-TCConnectionMethodPythonSource
    foreach($name in @('management_support.py','transport_support.py','tradechannel_linux.py','pairing_online.py')){
        $path=Join-Path (Join-Path $PSScriptRoot 'linux') $name
        if(-not [IO.File]::Exists($path) -or (Get-Item -LiteralPath $path).Length -gt 2MB){Stop-TCPairOnline OnlineSourceMissing '在线登记组件缺失。'}
        $sources[$name]=[IO.File]::ReadAllText($path)
    }
    $sourceJson=$sources|ConvertTo-Json -Depth 4 -Compress
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$digest=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($sourceJson)))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
    $payload=@{SourcesJson=$sourceJson;SourcesSHA256=$digest;Request=@{Action=$Action;Input=$InputData}}|ConvertTo-Json -Depth 16 -Compress
    if([Text.Encoding]::UTF8.GetByteCount($payload) -gt 4MB){Stop-TCPairOnline OnlineSourceTooLarge '在线登记安装载荷过大。'}
    # Fixed program; all variable data and source bytes travel over SSH stdin.
    $bootstrap=@'
import sys,json,hashlib,types,os
os.umask(0o077)
p=json.loads(sys.stdin.buffer.read(4194305).decode("utf-8"))
s=p["SourcesJson"]
assert hashlib.sha256(s.encode("utf-8")).hexdigest()==p["SourcesSHA256"]
sources=json.loads(s)
assert set(sources)=={"connection_methods.py","management_support.py","transport_support.py","tradechannel_linux.py","pairing_online.py"}
for name in ("connection_methods","management_support","transport_support","tradechannel_linux","pairing_online"):
 m=types.ModuleType(name);m.__file__=name+".py";sys.modules[name]=m;exec(compile(sources[name+".py"],m.__file__,"exec"),m.__dict__)
result=sys.modules["pairing_online"].ssh_entry(p["Request"],sources)
sys.stdout.write(json.dumps(result,separators=(",",":")));sys.stdout.flush()
sys.exit(0 if result["Ok"] else 1)
'@
    $command="python3 -I -c '"+$bootstrap+"'"
    if($UseSudo){$command='LC_ALL=C sudo -n -- '+$command}
    [pscustomobject]@{Action=$Action;Command=$command;Stdin=$payload;SourcesSHA256=$digest;ContainsSecret=($Action -eq 'create');RequiresPinnedSsh=$true}
}
function Invoke-TCPairOnlineSession {
    [CmdletBinding()]param([Parameter(Mandatory=$true)]$SessionRef,
        [Parameter(Mandatory=$true)][ValidateSet('create','status','cancel')][string]$Action,
        [Parameter(Mandatory=$true)]$InputData,[Parameter(Mandatory=$true)][string]$OperationId,[switch]$Retry)
    Import-Module (Join-Path $PSScriptRoot 'DeploymentTransport.psm1') -DisableNameChecking -ErrorAction Stop
    Invoke-TCDeployPairOnlineOperation -SessionRef $SessionRef -Action $Action -InputData $InputData -OperationId $OperationId -Retry:$Retry
}
function Get-TCPairOnlineSessionResult {
    [CmdletBinding()]param([Parameter(Mandatory=$true)]$SessionRef,
        [Parameter(Mandatory=$true)][ValidateSet('create','status','cancel')][string]$Action,
        [Parameter(Mandatory=$true)][string]$OperationId)
    Import-Module (Join-Path $PSScriptRoot 'DeploymentTransport.psm1') -DisableNameChecking -ErrorAction Stop
    $verified=Get-TCDeployVerifiedOperation -SessionRef $SessionRef -Operation ('pair_online_'+$Action) -OperationId $OperationId
    return $verified.Data
}
function Invoke-TCPairOnlineSsh {
    [CmdletBinding(DefaultParameterSetName='Credential')]param(
        [Parameter(Mandatory=$true)][ValidateSet('create','status','cancel')][string]$Action,
        [Parameter(Mandatory=$true)]$InputData,
        [Parameter(Mandatory=$true,ParameterSetName='Credential')]$Connection,
        [Parameter(Mandatory=$true,ParameterSetName='Credential')]$Credential,
        [Parameter(Mandatory=$true,ParameterSetName='Credential')][string]$PinnedHostKey,
        [Parameter(Mandatory=$true,ParameterSetName='Existing')]$SshClient)
    Initialize-TCPairOnline
    $user=if($PSCmdlet.ParameterSetName -ceq 'Existing'){$SshClient.ConnectionInfo.Username}else{$Connection.User}
    $payload=New-TCPairOnlineSshPayload -Action $Action -InputData $InputData -UseSudo:($user -cne 'root')
    if($PSCmdlet.ParameterSetName -ceq 'Existing'){$text=[TradeChannel.Deployment.PairingOnlineTransport]::ExecuteExisting($SshClient,$payload.Command,$payload.Stdin)}else{
        $transport=Import-Module (Join-Path $PSScriptRoot 'DeploymentTransport.psm1') -PassThru -DisableNameChecking
        $plain=& $transport {param($Value)ConvertTo-TCDeployCredential $Value} $Credential
        $secret=if($plain.Kind -ceq 'Password'){$plain.Password}else{$plain.PrivateKeyPem}
        $phrase=if($plain.ContainsKey('Passphrase')){$plain.Passphrase}else{''}
        try{$text=[TradeChannel.Deployment.PairingOnlineTransport]::ExecuteSsh($Connection.Host,[int]$Connection.Port,$user,$plain.Kind,$secret,$phrase,$PinnedHostKey,$payload.Command,$payload.Stdin)}finally{$secret=$null;$phrase=$null;$plain.Clear()}
    }
    $result=ConvertFrom-TCPairOnlineJson $text
    if(-not $result.PSObject.Properties['Ok'] -or $result.Ok -isnot [bool] -or $result.Action -cne $Action){Stop-TCPairOnline InvalidOnlineSshReply 'SSH 返回无法绑定到本次邀请码操作。'}
    if(-not $result.Ok){$code='OnlineOperationFailed';if($result.Data.Code -cmatch '^[A-Za-z][A-Za-z0-9]{0,63}$'){$code=$result.Data.Code};Stop-TCPairOnline $code '服务器未完成邀请码操作；请使用同一 InviteId 重试或查询。'}
    return $result.Data
}
function Test-TCPairOnlineReachability {
    # 0.22.0 A4: can this computer reach the invitation receiver at all?
    # Only a TCP connect and a TLS handshake run here. No application data and
    # no token are sent, so the check cannot consume or extend an invitation.
    # The certificate is compared by the leaf DER SHA-256, the same value the
    # invitation code pins. The result describes this computer's network only.
    [CmdletBinding()]param(
        [Parameter(Mandatory=$true)][string]$PublicHost,
        [Parameter(Mandatory=$true)][int]$Port,
        [Parameter(Mandatory=$true)][string]$TlsSha256,
        [int]$TimeoutSeconds=5)
    $address=$null
    if(-not [Net.IPAddress]::TryParse($PublicHost,[ref]$address) -or $address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork){Stop-TCPairOnline InvalidOnlineHost '可达性检查只接受 IPv4 地址。'}
    if($Port -lt 1 -or $Port -gt 65535){Stop-TCPairOnline InvalidOnlinePort '可达性检查的端口不在有效范围内。'}
    if($TlsSha256 -cnotmatch '^[A-Fa-f0-9]{64}$'){Stop-TCPairOnline InvalidOnlineTls '可达性检查需要证书的 SHA-256（64 位十六进制）。'}
    $expected=$TlsSha256.ToLowerInvariant()
    $timeoutMs=[int][Math]::Max(200,[Math]::Min(120000,$TimeoutSeconds*1000))
    $observation=@{Sha256=''}
    $status='Error';$connected=$false
    $watch=[Diagnostics.Stopwatch]::StartNew()
    $client=$null;$stream=$null
    try{
        $client=New-Object Net.Sockets.TcpClient
        $client.NoDelay=$true
        $pending=$client.BeginConnect($PublicHost,$Port,$null,$null)
        if(-not $pending.AsyncWaitHandle.WaitOne($timeoutMs)){$status='Timeout'}
        else{
            try{$client.EndConnect($pending);$connected=$true}
            catch [Net.Sockets.SocketException]{
                $socketError=[string]$_.Exception.SocketErrorCode
                $status=if($socketError -in @('TimedOut','HostUnreachable','HostDown','NetworkDown','TryAgain')){'Timeout'}else{'Refused'}
            }
        }
        if($connected){
            # The handshake runs synchronously on this thread on purpose: an
            # asynchronous handshake invokes the validation callback on a pool
            # thread that has no runspace, and the scriptblock delegate cannot
            # run there. ReadTimeout/WriteTimeout bound the synchronous wait.
            $callback=[Net.Security.RemoteCertificateValidationCallback]{
                param($sender,$certificate,$chain,$errors)
                try{
                    $leaf=if($certificate -is [Security.Cryptography.X509Certificates.X509Certificate2]){$certificate}else{New-Object Security.Cryptography.X509Certificates.X509Certificate2($certificate)}
                    $sha=[Security.Cryptography.SHA256]::Create()
                    $observation.Sha256=(($sha.ComputeHash($leaf.GetRawCertData())|ForEach-Object {$_.ToString('x2')}) -join '');$sha.Dispose()
                }catch{$observation.Sha256=''}
                return $true
            }
            $stream=New-Object Net.Security.SslStream($client.GetStream(),$false,$callback)
            $stream.ReadTimeout=$timeoutMs;$stream.WriteTimeout=$timeoutMs
            $handshake=[Diagnostics.Stopwatch]::StartNew()
            try{
                $stream.AuthenticateAsClient($PublicHost,$null,[Security.Authentication.SslProtocols]::Tls12,$false)
                $status=if($observation.Sha256 -ceq $expected){'Reachable'}else{'TlsMismatch'}
            }catch{
                # A peer that stops answering trips the socket timeout instead of
                # an authentication error; anything else failed during TLS.
                $authentication=$false;$current=$_.Exception
                while($current){if($current -is [Security.Authentication.AuthenticationException]){$authentication=$true};$current=$current.InnerException}
                $status=if(-not $authentication -and $handshake.ElapsedMilliseconds -ge [Math]::Max(500,[int]($timeoutMs*0.8))){'Timeout'}else{'TlsFailed'}
            }finally{$handshake.Stop()}
        }
    }catch [Net.Sockets.SocketException]{if($status -eq 'Error'){$status='Refused'}
    }catch{if($status -eq 'Error'){$status='Error'}
    }finally{
        $watch.Stop()
        if($stream){try{$stream.Dispose()}catch{}}
        if($client){try{$client.Close()}catch{}}
    }
    [pscustomobject]@{Status=$status;ElapsedMs=[int]$watch.ElapsedMilliseconds;CheckedAtUtc=[DateTime]::UtcNow.ToString('o')}
}
Export-ModuleMember -Function Get-TCPairOnlineInvitation,New-TCPairOnlineEnrollment,Complete-TCPairOnlineEnrollment,Invoke-TCPairOnlineEnrollment,New-TCPairOnlineSshPayload,Invoke-TCPairOnlineSsh,Invoke-TCPairOnlineSession,Get-TCPairOnlineSessionResult,Test-TCPairOnlineReachability
