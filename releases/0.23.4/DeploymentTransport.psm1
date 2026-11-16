#requires -Version 5.1
Set-StrictMode -Version 2.0
$script:TCDeployLinux = $null
$script:TCDeployPipeIdentityReady=$false
function Get-TCDeployLinuxModule {
    if (-not $script:TCDeployLinux) { $script:TCDeployLinux = Import-Module (Join-Path $PSScriptRoot 'LinuxServerSetup.psm1') -PassThru -DisableNameChecking -ErrorAction Stop }
    $script:TCDeployLinux
}
function Stop-TCDeploy { param([string]$Code,[string]$Message) throw [InvalidOperationException]::new('[TC:'+$Code+'] '+$Message) }
function Get-TCDeployProperty { param($Value,[string]$Name,$Default=$null) if($Value -is [Collections.IDictionary]){if($Value.Contains($Name)){return $Value[$Name]}}elseif($Value -and $Value.PSObject.Properties[$Name]){return $Value.$Name};return $Default }
function Get-TCDeployAccessDiagnostic {
    [CmdletBinding()]param([string]$Code)
    if($Code -cnotmatch '^[A-Za-z][A-Za-z0-9_]{0,63}$'){$Code='AccessStateUnknown'}
    $kind='Unknown';$category='Unknown';$retry=$false;$clear=$false
    switch -Regex ($Code){
        '^(HostKeyChanged)$' {$kind='IdentityChanged';$category='HostTrust';break}
        '^(HostTrustRequired|HostKeyUnknown)$' {$kind='FirstTrust';$category='HostTrust';break}
        '^(AuthenticationFailed|AuthenticationRejected|InvalidCredential)$' {$kind='Credentials';$category='Authentication';$clear=$true;break}
        '^(InvalidPrivateKey|PrivateKeyRejected|PrivateKeyParseFailed|PrivateKeyPassphraseRequired)$' {$kind='PrivateKey';$category='Credential';$clear=$true;break}
        # Saved long-term login material: the local envelope is gone, is a legacy
        # v1 file, or cannot be decrypted by the current Windows user.
        '^(CredentialMissing|CredentialLegacy|CredentialUnavailable)$' {$kind='Credentials';$category='Credential';$clear=$true;break}
        # The record identity (fingerprint/revision/address/signing key) moved on,
        # so the saved envelope no longer belongs to this server.
        '^(CredentialBindingChanged)$' {$kind='IdentityChanged';$category='Credential';$clear=$true;break}
        '^(CredentialRefInvalid)$' {$kind='InvalidCredential';$category='Credential';break}
        '^(AuthenticationRequired|AwaitingCredential)$' {$kind='AuthenticationRequired';$category='Session';$retry=$true;break}
        '^(ConnectionTimeout|ConnectionRefused|HostUnreachable|NetworkUnreachable|SocketFailed|ConnectionClosed|SshConnectionFailed|SshNegotiationFailed|ConnectionFailed)$' {$kind='Connection';$category='Connection';$retry=$true;break}
        '^(CommandStart|SendPayload|WaitResult)_(SshConnectionException|SshOperationTimeoutException|SocketException|TimeoutException|IOException)$' {$kind='Connection';$category='Connection';$retry=$true;break}
        '^ExecutorBusy$' {$kind='ExecutorBusy';$category='Executor';break}
        '^(RemotePrerequisiteMissing|RemotePrivilegeDenied)$' {$kind='Prerequisite';$category='Prerequisite';break}
    }
    [pscustomobject]@{Code=$Code;Kind=$kind;Category=$category;RetryWithCredential=$retry;ClearCredential=$clear}
}
function Assert-TCDeployFields { param($Value,[string[]]$Names) if($null -eq $Value){Stop-TCDeploy InvalidRequest '缺少请求对象。'};$fields=if($Value -is [Collections.IDictionary]){@($Value.Keys)}else{@($Value.PSObject.Properties.Name)};foreach($name in $fields){if($name -notin $Names){Stop-TCDeploy InvalidRequest '请求包含未支持的字段。'}} }
function Resolve-TCDeployRoot { param([string]$Root) if(-not $Root){$Root=Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'TradeChannel'}; $module=Get-TCDeployLinuxModule; & $module {param($Path) Get-TCLinuxPath $Path} $Root }
function New-TCDeployPrivateDirectory { param([string]$Path) $module=Get-TCDeployLinuxModule;& $module {param($Path) New-TCLinuxDirectory $Path} $Path }
function ConvertTo-TCDeploySecret {
    param($Value)
    if($Value -is [Security.SecureString]){ $ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value);try{return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)}finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)} }
    if($Value -is [string]){return $Value};Stop-TCDeploy InvalidCredential '凭据必须来自程序内密码或密钥输入。'
}
function ConvertTo-TCDeployCredential {
    param($Credential)
    if($Credential -is [Management.Automation.PSCredential]){return @{Kind='Password';Password=(ConvertTo-TCDeploySecret $Credential.Password)}}
    Assert-TCDeployFields $Credential @('Kind','Password','PrivateKeyPem','Passphrase')
    $kind=[string](Get-TCDeployProperty $Credential Kind '')
    if($kind -ceq 'Password'){Assert-TCDeployFields $Credential @('Kind','Password');$value=ConvertTo-TCDeploySecret (Get-TCDeployProperty $Credential Password);if(-not $value -or $value.Length -gt 4096){Stop-TCDeploy InvalidCredential '密码为空或超限。'};return @{Kind=$kind;Password=$value}}
    if($kind -ceq 'PrivateKey'){Assert-TCDeployFields $Credential @('Kind','PrivateKeyPem','Passphrase');$pem=ConvertTo-TCDeploySecret (Get-TCDeployProperty $Credential PrivateKeyPem);if($pem.Length -gt 1MB -or $pem -notmatch '^-----BEGIN '){Stop-TCDeploy InvalidCredential 'SSH 私钥格式或长度无效。'};$phrase=Get-TCDeployProperty $Credential Passphrase '';return @{Kind=$kind;PrivateKeyPem=$pem;Passphrase=(ConvertTo-TCDeploySecret $phrase)}}
    Stop-TCDeploy InvalidCredential '仅支持密码或内存 SSH 私钥。'
}
function Assert-TCDeploySessionRef {
    param($SessionRef)
    Assert-TCDeployFields $SessionRef @('PipeName','RunId','InstanceId','ProcessId','StartTimeUtcTicks','Root')
    foreach($name in @('RunId','InstanceId')){if([string](Get-TCDeployProperty $SessionRef $name '') -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'){Stop-TCDeploy SessionMismatch '会话标识无效。'}}
    if([string](Get-TCDeployProperty $SessionRef PipeName '') -cnotmatch '^TCDeploy-[0-9a-f]{32}$'){Stop-TCDeploy SessionMismatch '会话通道无效。'}
    $processId=0;$ticks=0L
    if(-not [int]::TryParse([string](Get-TCDeployProperty $SessionRef ProcessId ''),[ref]$processId) -or $processId -le 0 -or -not [long]::TryParse([string](Get-TCDeployProperty $SessionRef StartTimeUtcTicks ''),[ref]$ticks) -or $ticks -le 0){Stop-TCDeploy SessionMismatch '执行器进程身份无效。'}
    $null=Resolve-TCDeployRoot ([string]$SessionRef.Root)
}
function Initialize-TCDeployPipeIdentity {
    if(-not $script:TCDeployPipeIdentityReady){
        . (Join-Path $PSScriptRoot 'runtime\TradeChannel.Components.ps1')
        Initialize-TCRuntimeComponent -Name TCDevicePath -PackageRoot $PSScriptRoot
        $script:TCDeployPipeIdentityReady=$true
    }
}
function Assert-TCDeployPipeOwner {
    param([IO.Pipes.NamedPipeClientStream]$Pipe,$SessionRef)
    Initialize-TCDeployPipeIdentity
    $ownerId=[uint32]0;$process=$null
    try{
        if(-not [TCProviderPipeIdentity]::GetNamedPipeServerProcessId($Pipe.SafePipeHandle,[ref]$ownerId) -or $ownerId -ne [uint32]$SessionRef.ProcessId){Stop-TCDeploy SessionMismatch '会话通道不属于绑定的执行器。'}
        $process=Get-Process -Id ([int]$ownerId) -ErrorAction Stop
        if($process.Path -ine (Join-Path $PSScriptRoot 'deployment\TradeChannelDeployHost.exe') -or [string]$process.StartTime.ToUniversalTime().Ticks -cne [string]$SessionRef.StartTimeUtcTicks){Stop-TCDeploy SessionMismatch '执行器路径或启动身份已经变化。'}
    }catch{Stop-TCDeploy SessionMismatch '不能验证会话执行器身份。'}finally{if($process){$process.Dispose()}}
}
function Get-TCDeployPipeWaitMilliseconds {
    param([int]$PhaseTimeout,[Diagnostics.Stopwatch]$Watch,[int]$TotalTimeoutMs)
    if($TotalTimeoutMs -le 0){return $PhaseTimeout}
    $remaining=$TotalTimeoutMs-[int]$Watch.ElapsedMilliseconds
    if($remaining -le 0){Stop-TCDeploy PipeTimeout '部署执行器响应超时。'}
    return [math]::Min($PhaseTimeout,$remaining)
}
function Read-TCDeployPipeBytes {
    param([IO.Stream]$Pipe,[int]$Length,[ValidateRange(1,30000)][int]$TimeoutMs=10000,[Diagnostics.Stopwatch]$Watch,[int]$TotalTimeoutMs=0)
    $bytes=New-Object byte[] $Length;$offset=0
    while($offset -lt $Length){$wait=Get-TCDeployPipeWaitMilliseconds $TimeoutMs $Watch $TotalTimeoutMs;$async=$Pipe.BeginRead($bytes,$offset,$Length-$offset,$null,$null);if(-not $async.AsyncWaitHandle.WaitOne($wait)){Stop-TCDeploy PipeTimeout '部署执行器响应超时。'};$got=$Pipe.EndRead($async);if($got -le 0){Stop-TCDeploy PipeClosed '部署执行器通道关闭。'};$offset+=$got}
    return ,$bytes
}
function Invoke-TCDeployPipe {
    param($SessionRef,[hashtable]$Body,[int]$ConnectTimeout=3000,[ValidateRange(1,30000)][int]$ReadTimeoutMs=10000,[ValidateRange(0,30000)][int]$TotalTimeoutMs=0)
    $watch=[Diagnostics.Stopwatch]::StartNew();$bytes=$null;$text=$null
    Assert-TCDeploySessionRef $SessionRef
    $Body.RunId=[string]$SessionRef.RunId;$Body.InstanceId=[string]$SessionRef.InstanceId
    $pipe=New-Object IO.Pipes.NamedPipeClientStream('.',[string]$SessionRef.PipeName,[IO.Pipes.PipeDirection]::InOut,[IO.Pipes.PipeOptions]::Asynchronous,[Security.Principal.TokenImpersonationLevel]::Impersonation)
    try {
        $pipe.Connect((Get-TCDeployPipeWaitMilliseconds $ConnectTimeout $watch $TotalTimeoutMs))
        # Check the actual OS pipe owner before transmitting any credential.
        Assert-TCDeployPipeOwner $pipe $SessionRef
        $text=$Body|ConvertTo-Json -Depth 32 -Compress;$bytes=[Text.Encoding]::UTF8.GetBytes($text);if($bytes.Length -gt 4MB){Stop-TCDeploy InputTooLarge '会话请求超限。'}
        $length=[BitConverter]::GetBytes([int]$bytes.Length)
        foreach($segment in @($length,$bytes)){
            $wait=Get-TCDeployPipeWaitMilliseconds $ReadTimeoutMs $watch $TotalTimeoutMs
            $pending=$pipe.BeginWrite($segment,0,$segment.Length,$null,$null)
            if(-not $pending.AsyncWaitHandle.WaitOne($wait)){Stop-TCDeploy PipeTimeout '部署执行器响应超时。'}
            $pipe.EndWrite($pending)
        }
        [Array]::Clear($bytes,0,$bytes.Length);$text=$null
        $count=[BitConverter]::ToInt32((Read-TCDeployPipeBytes $pipe 4 $ReadTimeoutMs $watch $TotalTimeoutMs),0);if($count -lt 2 -or $count -gt 4MB){Stop-TCDeploy InvalidEnvelope '会话响应大小无效。'}
        $response=[Text.Encoding]::UTF8.GetString((Read-TCDeployPipeBytes $pipe $count $ReadTimeoutMs $watch $TotalTimeoutMs))|ConvertFrom-Json -ErrorAction Stop
        if((Get-TCDeployProperty $response Ok) -isnot [bool]){Stop-TCDeploy InvalidEnvelope '会话响应无效。'}
        return $response
    } finally { $pipe.Dispose();if($bytes){[Array]::Clear($bytes,0,$bytes.Length)};if($Body.ContainsKey('Credential')){if($Body.Credential -is [Collections.IDictionary]){$Body.Credential.Clear()};$Body.Remove('Credential')} }
}
function Start-TCDeploySession {
    [CmdletBinding()]
    param([string]$Root,[Parameter(Mandatory=$true)][string]$RunId,$Connection,$Credential,[string]$PinnedFingerprint='',$AccessContext=$null)
    if($null -ne $AccessContext){$null=ConvertTo-TCDeployAccessContext $AccessContext}
    Import-Module (Join-Path $PSScriptRoot 'DeploymentDependencies.psm1') -DisableNameChecking;$null=Test-TCDeploymentDependencies -PackageRoot $PSScriptRoot
    # Reject a missing or mismatched packaged helper before creating an executor.
    Initialize-TCDeployPipeIdentity
    $rootPath=Resolve-TCDeployRoot $Root
    Import-Module (Join-Path $PSScriptRoot 'DeploymentStore.psm1') -DisableNameChecking
    $cleanupGate=Open-TCDLock (Join-Path $rootPath '.local-cleanup.lock') -TimeoutMs 0
    try{
    Assert-TCLocalCleanupReady $rootPath
    if($RunId -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'){Stop-TCDeploy InvalidId '运行标识必须是规范 GUID。'}
    $hostsRoot=Join-Path (Join-Path $rootPath 'deployments') 'hosts';New-TCDeployPrivateDirectory $rootPath;New-TCDeployPrivateDirectory (Join-Path $rootPath 'deployments');New-TCDeployPrivateDirectory $hostsRoot
    $instance=[guid]::NewGuid().ToString();$directory=Join-Path $hostsRoot $instance;New-TCDeployPrivateDirectory $directory
    $pipeName='TCDeploy-'+[guid]::NewGuid().ToString('N');$exe=Join-Path $PSScriptRoot 'deployment\TradeChannelDeployHost.exe'
    if(-not (Test-Path -LiteralPath $exe -PathType Leaf)){Stop-TCDeploy ExecutorMissing '缺少部署执行器，请重新解压完整产品包。'}
    $args=@($pipeName,$RunId,$instance,$directory,$PSScriptRoot);$module=Get-TCDeployLinuxModule
    $commandLine=& $module {param($Arguments) ($Arguments|ForEach-Object {ConvertTo-TCLinuxArgument $_}) -join ' '} $args
    $process=Start-Process -FilePath $exe -ArgumentList $commandLine -WindowStyle Hidden -PassThru -ErrorAction Stop
    try{$ref=[pscustomobject]@{PipeName=$pipeName;RunId=$RunId;InstanceId=$instance;ProcessId=$process.Id;StartTimeUtcTicks=[string]$process.StartTime.ToUniversalTime().Ticks;Root=$directory}}finally{$process.Dispose()}
    $ready=$false;for($i=0;$i -lt 20;$i++){try{$null=Invoke-TCDeployPipe $ref @{Command='Poll'} 300;$ready=$true;break}catch{Start-Sleep -Milliseconds 100}}
    if(-not $ready){Stop-TCDeploy ExecutorFailed '部署执行器未能启动。'}
    $status='AwaitingCredential';if($Credential){$null=Set-TCDeployCredential -SessionRef $ref -Connection $Connection -Credential $Credential -PinnedFingerprint $PinnedFingerprint -AccessContext $AccessContext;$status='Connecting'}
    [pscustomobject]@{Ok=$true;Code='SessionStarted';Status=$status;SessionRef=$ref}
    }finally{$cleanupGate.Dispose()}
}
function ConvertTo-TCDeployAccessContext {
    # Diagnostic metadata is bounded and never substitutes for host-key or
    # credential validation. In particular a received pin does not mean the
    # user just confirmed it. No arbitrary client text enters the receipt.
    param($Value)
    Assert-TCDeployFields $Value @('TrustDecisionId','TrustOrigin','RetryReason','RetryCount','PriorInstanceId')
    $decision=[string](Get-TCDeployProperty $Value TrustDecisionId '')
    $prior=[string](Get-TCDeployProperty $Value PriorInstanceId '')
    foreach($id in @($decision,$prior)){if($id -and $id -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'){Stop-TCDeploy InvalidAccessContext '接入诊断标识无效。'}}
    $origin=[string](Get-TCDeployProperty $Value TrustOrigin 'None')
    $reason=[string](Get-TCDeployProperty $Value RetryReason 'InitialAttempt')
    $count=Get-TCDeployProperty $Value RetryCount 0
    if($origin -cnotin @('None','ExplicitUserConfirmation','AutomaticFirstUse','AuthenticatedPin') -or ($decision -and $origin -cnotin @('ExplicitUserConfirmation','AutomaticFirstUse')) -or $reason -cnotmatch '^[A-Za-z][A-Za-z0-9_]{0,63}$' -or $count -isnot [int] -or $count -lt 0 -or $count -gt 2){Stop-TCDeploy InvalidAccessContext '接入诊断字段无效。'}
    @{TrustDecisionId=$decision;TrustOrigin=$origin;RetryReason=$reason;RetryCount=$count;PriorInstanceId=$prior}
}
function Set-TCDeployCredential {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$SessionRef,[Parameter(Mandatory=$true)]$Connection,[Parameter(Mandatory=$true)]$Credential,[string]$PinnedFingerprint='',$AccessContext=$null)
    Assert-TCDeployFields $Connection @('Host','Port','User','IdentityFile')
    $connectionValue=@{Host=[string](Get-TCDeployProperty $Connection Host '');Port=[int](Get-TCDeployProperty $Connection Port 22);User=[string](Get-TCDeployProperty $Connection User 'root')}
    if($PinnedFingerprint -and $PinnedFingerprint -cnotmatch '^SHA256:[A-Za-z0-9+/]{43}$'){Stop-TCDeploy InvalidFingerprint '主机指纹必须是 SHA256 格式。'}
    $body=@{Command='Authenticate';Connection=$connectionValue;PinnedFingerprint=$PinnedFingerprint}
    if($null -ne $AccessContext){$body.AccessContext=ConvertTo-TCDeployAccessContext $AccessContext}
    $body.Credential=ConvertTo-TCDeployCredential $Credential
    Invoke-TCDeployPipe $SessionRef $body
}
function Get-TCDeploySession {
    [CmdletBinding()]param([Parameter(Mandatory=$true)]$SessionRef,[ValidateRange(0,30000)][int]$TotalTimeoutMs=0)
    Assert-TCDeploySessionRef $SessionRef
    try{return Invoke-TCDeployPipe $SessionRef @{Command='Poll'} -TotalTimeoutMs $TotalTimeoutMs}catch{
        if($TotalTimeoutMs -gt 0){throw}
        if($_.Exception.Message -match '^\[TC:SessionMismatch\]'){return [pscustomobject]@{Ok=$false;Status='Failed';Stage='PrepareAccess';Code='SessionMismatch';HasSession=$false;Data=$null}}
        $alive=$false;try{$process=Get-Process -Id ([int]$SessionRef.ProcessId) -ErrorAction Stop;try{$alive=([string]$process.StartTime.ToUniversalTime().Ticks -ceq [string]$SessionRef.StartTimeUtcTicks -and $process.Path -ieq (Join-Path $PSScriptRoot 'deployment\TradeChannelDeployHost.exe'))}finally{$process.Dispose()}}catch{}
        if($alive){return [pscustomobject]@{Ok=$false;Status='Running';Stage='Executor';Code='ExecutorBusy';HasSession=$false;Data=$null}}
        $receipt=$null;$file=Join-Path $SessionRef.Root 'receipt.json';$module=Get-TCDeployLinuxModule
        if(Test-Path -LiteralPath $file){try{$receipt=& $module {param($Path) Read-TCLinuxJson $Path} $file}catch{}}
        $mutating=[bool](Get-TCDeployProperty $receipt Mutating ([string](Get-TCDeployProperty $receipt Operation '') -in @('apply','authorize','recover','finalize','management_apply','device_rename','invite_create','invite_cancel','authorize_external','revoke','uninstall','transport_apply')))
        $status=if($mutating -and [string](Get-TCDeployProperty $receipt Status '') -ceq 'Running'){'OutcomeUnknown'}else{'Failed'}
        [pscustomobject]@{Ok=$false;Status=$status;Stage=[string](Get-TCDeployProperty $receipt Stage 'PrepareAccess');Code='AuthenticationRequired';OperationId=[string](Get-TCDeployProperty $receipt OperationId '');HasSession=$false;Data=$null}
    }
}
function Assert-TCDeployLiveIdentity {
    param($SessionRef,$Poll,[switch]$AllowMutatingHistory)
    $fingerprint=[string](Get-TCDeployProperty $Poll ObservedFingerprint '')
    $algorithm=[string](Get-TCDeployProperty $Poll ObservedHostKeyAlgorithm '')
    if((Get-TCDeployProperty $Poll RunId '') -cne [string]$SessionRef.RunId -or (Get-TCDeployProperty $Poll InstanceId '') -cne [string]$SessionRef.InstanceId){Stop-TCDeploy IdentitySessionMismatch '身份读取与当前会话不匹配。'}
    if((Get-TCDeployProperty $Poll HasSession) -isnot [bool] -or -not $Poll.HasSession -or $fingerprint -cnotmatch '^SHA256:[A-Za-z0-9+/]{43}$' -or (Get-TCDeployProperty $Poll AcceptedFingerprint '') -cne $fingerprint -or $algorithm -cnotmatch '^[A-Za-z0-9][A-Za-z0-9@._+-]{0,79}$' -or [int](Get-TCDeployProperty $Poll AuthenticationGeneration 0) -le 0){Stop-TCDeploy IdentityAuthenticationRequired '需要已验证主机密钥的实际 SSH 登录会话。'}
    $history=Get-TCDeployProperty $Poll HasMutatingOperations
    if($history -isnot [bool] -or (-not $AllowMutatingHistory -and $history)){Stop-TCDeploy IdentitySessionUsed '此会话已执行变更或缺少只读证明，请重新建立核验会话。'}
    $connection=Get-TCDeployProperty $Poll Connection
    Assert-TCDeployFields $connection @('Host','Port','User')
    if(-not (Get-TCDeployProperty $connection Host '') -or -not (Get-TCDeployProperty $connection User '') -or [int](Get-TCDeployProperty $connection Port 0) -le 0){Stop-TCDeploy IdentitySessionMismatch '会话未证明接入地址。'}
}
function Read-TCDeployObservation {
    # Private fixture seam: replace this leaf ONLY inside an isolated test module
    # instance. Production always reads the OS-bound live executor pipe. All
    # public evidence getters validate the returned observation independently.
    param($SessionRef)
    return Get-TCDeploySession -SessionRef $SessionRef
}
function Get-TCDeployVerifiedHostIdentity {
    [CmdletBinding()]param([Parameter(Mandatory=$true)]$SessionRef)
    Assert-TCDeploySessionRef $SessionRef
    $poll=Read-TCDeployObservation $SessionRef
    Assert-TCDeployLiveIdentity $SessionRef $poll -AllowMutatingHistory
    if($poll.Status -notin @('Ready','Completed','Failed')){Stop-TCDeploy IdentityAuthenticationRequired '当前 SSH 登录尚未完成。'}
    return [pscustomobject]@{Connection=$poll.Connection;ObservedFingerprint=$poll.ObservedFingerprint;ObservedHostKeyAlgorithm=$poll.ObservedHostKeyAlgorithm}
}
function Get-TCDeployVerifiedOperation {
    [CmdletBinding()]param([Parameter(Mandatory=$true)]$SessionRef,[string]$Operation,[string]$OperationId)
    Assert-TCDeploySessionRef $SessionRef
    $poll=Read-TCDeployObservation $SessionRef
    Assert-TCDeployLiveIdentity $SessionRef $poll -AllowMutatingHistory
    if($poll.Status -cne 'Completed' -or $poll.Code -cne 'Completed' -or $poll.Operation -cne $Operation -or -not $OperationId -or $poll.OperationId -cne $OperationId -or -not (Get-TCDeployProperty $poll Data)){Stop-TCDeploy IdentityReadRequired '核对结果必须属于当前已认证会话的原读取操作。'}
    return $poll
}
function Get-TCDeployVerifiedServerInfo {
    [CmdletBinding()]param([Parameter(Mandatory=$true)]$SessionRef)
    Assert-TCDeploySessionRef $SessionRef
    $poll=Read-TCDeployObservation $SessionRef
    Assert-TCDeployLiveIdentity $SessionRef $poll -AllowMutatingHistory
    if($poll.Status -cne 'Completed' -or $poll.Code -cne 'Completed' -or $poll.Operation -cne 'server_info' -or -not (Get-TCDeployProperty $poll OperationId '') -or -not (Get-TCDeployProperty $poll Data)){Stop-TCDeploy IdentityReadRequired '只有当前会话实际完成的 server_info 可以登记已验证身份。'}
    return [pscustomobject]@{ServerInfo=$poll.Data;Connection=$poll.Connection;ObservedFingerprint=$poll.ObservedFingerprint;ObservedHostKeyAlgorithm=$poll.ObservedHostKeyAlgorithm}
}
function Get-TCDeployServerIdentityEvidence {
    # Input is ONLY a verified executor reference. No caller-provided server_info,
    # inspection, fingerprint, or declaration is accepted as remote evidence.
    [CmdletBinding()]param([Parameter(Mandatory=$true)]$SessionRef,[ValidateRange(1,180)][int]$TimeoutSeconds=180)
    $initial=Get-TCDeploySession $SessionRef;Assert-TCDeployLiveIdentity $SessionRef $initial
    if($initial.Status -notin @('Ready','Completed','Failed')){Stop-TCDeploy IdentitySessionBusy 'SSH 会话仍在执行任务。'}
    $results=@{}
    $firstInfo=$null
    foreach($action in @('server_info','inspect','server_info')){
        $id=[guid]::NewGuid().ToString('D')
        # Empty inspect input disables NetworkProbe/capture and any optional probe.
        $started=Invoke-TCDeployOperation -SessionRef $SessionRef -Operation $action -OperationInput @{} -OperationId $id
        if(-not $started.Ok -or $started.OperationId -cne $id -or $started.Operation -cne $action){Stop-TCDeploy IdentityReadRejected '服务器只读核验未接受，原记录保留。'}
        $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        do{
            $poll=Get-TCDeploySession $SessionRef;Assert-TCDeployLiveIdentity $SessionRef $poll
            if($poll.AuthenticationGeneration -ne $initial.AuthenticationGeneration -or $poll.ObservedFingerprint -cne $initial.ObservedFingerprint -or $poll.ObservedHostKeyAlgorithm -cne $initial.ObservedHostKeyAlgorithm -or $poll.Connection.Host -cne $initial.Connection.Host -or [int]$poll.Connection.Port -ne [int]$initial.Connection.Port -or $poll.Connection.User -cne $initial.Connection.User -or $poll.OperationId -cne $id -or $poll.Operation -cne $action){Stop-TCDeploy IdentityObservationChanged '身份核验期间会话、主机密钥或操作发生变化。'}
            if($poll.Status -cne 'Running'){break}
            if([DateTime]::UtcNow -ge $deadline){Stop-TCDeploy IdentityReadTimeout '服务器只读核验尚未完成，原记录保留。'}
            Start-Sleep -Milliseconds 100
        }while($true)
        if($poll.Status -cne 'Completed' -or $poll.Code -cne 'Completed' -or -not $poll.Ok -or -not (Get-TCDeployProperty $poll Data)){Stop-TCDeploy IdentityReadRejected '服务器只读核验失败或归属未知，原记录保留。'}
        if($action -ceq 'server_info'){
            if($firstInfo -and (ConvertTo-Json -InputObject $firstInfo -Depth 32 -Compress) -cne (ConvertTo-Json -InputObject $poll.Data -Depth 32 -Compress)){Stop-TCDeploy IdentityObservationChanged '只读检查前后的 server_info 已变化。'}
            $firstInfo=$poll.Data
        }
        $results[$action]=$poll.Data
    }
    [pscustomobject]@{Connection=$initial.Connection;ObservedFingerprint=$initial.ObservedFingerprint;ObservedHostKeyAlgorithm=$initial.ObservedHostKeyAlgorithm;AuthenticationGeneration=$initial.AuthenticationGeneration;ServerInfo=$results.server_info;Inspection=$results.inspect}
}
function Invoke-TCDeployOperation {
    [CmdletBinding()]param([Parameter(Mandatory=$true)]$SessionRef,[Parameter(Mandatory=$true)][string]$Operation,[Alias('Input')]$OperationInput=@{},[string]$OperationId='')
    $aliases=@{Inspect='inspect';Plan='plan';Apply='apply';Status='status';Authorize='authorize';Recover='recover';Finalize='finalize';Capabilities='capabilities';ServerInfo='server_info';Devices='devices';DeviceRename='device_rename';ManagementPlan='management_plan';ManagementApply='management_apply';InviteCreate='invite_create';InviteCancel='invite_cancel';InviteStatus='invite_status';AuthorizeExternal='authorize_external';RequestStatus='request_status';RevokePreview='revoke_preview';Revoke='revoke';UninstallPreview='uninstall_preview';Uninstall='uninstall';TransportPlan='transport_plan';TransportApply='transport_apply';TransportInfo='transport_info'}
    $aliases.TransportCandidates='transport_candidates';$aliases.TransportOptions='transport_options';$aliases.DeploymentState='deployment_state';$aliases.ManagementRecoveryState='management_recovery_state';$aliases.OperationResult='operation_result'
    $action=if($aliases.ContainsKey($Operation)){$aliases[$Operation]}else{$Operation};if($action -cnotin @($aliases.Values)){Stop-TCDeploy InvalidOperation '未支持的部署操作。'}
    if($action -ceq 'operation_result'){Assert-TCDeployFields $OperationInput @('Operation','IntentId','OriginalInput','TransactionId','OriginalFailureCode','ServerBinding')}
    $body=@{Command='Execute';Operation=$action;Input=$OperationInput};if($OperationId){if($OperationId -cnotmatch '^[0-9a-f-]{36}$'){Stop-TCDeploy InvalidId '操作幂等标识无效。'};$body.OperationId=$OperationId}
    Invoke-TCDeployPipe $SessionRef $body
}
function Invoke-TCDeployPairOnlineOperation {
    # Only fixed business fields cross the public boundary. The source package
    # is built here and independently checked against package files by the host.
    [CmdletBinding()]param([Parameter(Mandatory=$true)]$SessionRef,
        [Parameter(Mandatory=$true)][ValidateSet('create','status','cancel')][string]$Action,
        [Parameter(Mandatory=$true)]$InputData,
        [Parameter(Mandatory=$true)][string]$OperationId,[switch]$Retry)
    if($OperationId -cnotmatch '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$'){Stop-TCDeploy InvalidId '在线操作需要固定的规范 OperationId。'}
    $allowed=@('InviteId','ExpectedServerBinding','ExpectedManagementFingerprint')
    if($Action -ceq 'create'){$allowed+=@('DeviceName','ExpiresInSeconds','PublicHost','Port')}
    Assert-TCDeployFields $InputData $allowed
    foreach($name in $allowed){if($null -eq (Get-TCDeployProperty $InputData $name)){Stop-TCDeploy InvalidRequest '在线操作缺少必要业务字段。'}}
    $poll=Get-TCDeploySession -SessionRef $SessionRef
    Assert-TCDeployLiveIdentity $SessionRef $poll -AllowMutatingHistory
    if($poll.Status -notin @('Ready','Completed','Failed','OutcomeUnknown','Running')){Stop-TCDeploy IdentityAuthenticationRequired '需要现有的已认证管理会话。'}
    Import-Module (Join-Path $PSScriptRoot 'PairingOnline.psm1') -DisableNameChecking -ErrorAction Stop
    $package=New-TCPairOnlineSshPayload -Action $Action -InputData $InputData
    $wire=$package.Stdin|ConvertFrom-Json -ErrorAction Stop
    $expected=@{AuthenticationGeneration=[int]$poll.AuthenticationGeneration;HostFingerprint=[string]$poll.AcceptedFingerprint;Connection=$poll.Connection}
    Invoke-TCDeployPipe $SessionRef @{Command='PairOnline';Action=$Action;Input=$InputData;OperationId=$OperationId;Retry=[bool]$Retry;ExpectedSession=$expected;Sources=@{SourcesJson=$wire.SourcesJson;SourcesSHA256=$wire.SourcesSHA256}}
}
function Stop-TCDeploySession {
    [CmdletBinding()]param([Parameter(Mandatory=$true)]$SessionRef,[switch]$Cancel,[ValidateRange(1,30000)][int]$ReadTimeoutMs=10000,[ValidateRange(0,30000)][int]$TotalTimeoutMs=0)
    $command=if($Cancel){'Cancel'}else{'Close'};$result=Invoke-TCDeployPipe $SessionRef @{Command=$command} -ReadTimeoutMs $ReadTimeoutMs -TotalTimeoutMs $TotalTimeoutMs
    # The host's Close response predates the UI's convenience flag. Normalize
    # the protocol here so every caller observes the same terminal contract.
    if(-not $Cancel){
        $accepted=((Get-TCDeployProperty $result Ok) -is [bool] -and $result.Ok -and [string](Get-TCDeployProperty $result Code '') -ceq 'SessionClosed' -and [string](Get-TCDeployProperty $result Status '') -ceq 'Closed')
        $result|Add-Member NoteProperty Closed ([bool]$accepted) -Force
    }
    return $result
}
function Get-TCDeploySavedCredentialPath {
    # The envelope file name is the only accepted reference shape. A strict GUID
    # keeps malformed persisted values from concatenating into a file name.
    param([string]$Root,[string]$CredentialRef)
    if($CredentialRef -cnotmatch '^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$'){Stop-TCDeploy InvalidId '凭据引用无效。'}
    Import-Module (Join-Path $PSScriptRoot 'DeploymentStore.psm1') -DisableNameChecking
    return Assert-TCDPath (Join-Path (Join-Path (Assert-TCDPath (Resolve-TCDeployRoot $Root)) 'credentials') ($CredentialRef+'.json'))
}
function Read-TCDeploySavedCredentialEnvelope {
    # Plaintext envelope only. This helper never touches DPAPI, so it is safe on
    # render paths. A missing or unreadable file returns $null; the caller then
    # decides whether that means "gone" or "unreadable" instead of inheriting a
    # misleading task-file message from the generic JSON reader.
    param([string]$Path)
    if(-not [IO.File]::Exists($Path)){return $null}
    $module=Get-TCDeployLinuxModule
    try{$value=& $module {param($Path) Read-TCLinuxJson $Path 2MB} $Path}catch{return $null}
    return $value
}
function Get-TCDeployComparableBinding {
    # The login method is only stored inside the envelope, so a caller that must
    # judge availability before decrypting cannot know it. Such a binding carries
    # the six identity fields and is completed here with the stored kind; a
    # binding that already names a kind is compared exactly, so a mismatched
    # method still fails the digest instead of being silently accepted.
    param([hashtable]$Binding,[string]$StoredKind)
    if($null -eq $Binding){return $null}
    if($Binding.ContainsKey('CredentialKind')){return $Binding}
    $copy=@{}
    foreach($name in @($Binding.Keys)){$copy[[string]$name]=$Binding[$name]}
    $copy['CredentialKind']=$StoredKind
    return $copy
}
function Save-TCDeployCredential {
    # With -Binding the envelope is written as v2 and bound to the server record
    # identity; without it the legacy v1 envelope is written unchanged so that
    # existing callers keep their contract.
    # -GateHeld means the caller already holds '.local-cleanup.lock' (repeated
    # exclusive opens of the same lock file fail inside one process), so this
    # function then only takes its own 'deployments\.credentials.lock'.
    [CmdletBinding()]param([string]$Root,[Parameter(Mandatory=$true)]$Credential,[hashtable]$Binding,[string]$ManagementSigningKeyDigest='',[string]$KeyPathHint='',[switch]$GateHeld)
    Import-Module (Join-Path $PSScriptRoot 'DeploymentStore.psm1') -DisableNameChecking
    $base=Assert-TCDPath (Resolve-TCDeployRoot $Root);$directory=Join-Path $base 'credentials'
    $isV2=$null -ne $Binding;$bindingDigest='';$metadata=@{}
    if($isV2){
        $expected=@('ServerRecordId','Host','Port','User','PinnedHostKey','IdentityTransitionRevision','CredentialKind')
        $actual=@($Binding.Keys)
        if($actual.Count -ne $expected.Count -or @($expected|Where-Object {$_ -cnotin $actual}).Count){Stop-TCDeploy InvalidRequest '登录资料绑定信息不完整或包含未支持字段。'}
        $credentialKind=[string]$Binding['CredentialKind']
        if($credentialKind -cnotin @('Password','PrivateKey')){Stop-TCDeploy InvalidCredential '登录资料绑定方式无效。'}
        if([string]$Binding['ServerRecordId'] -cnotmatch '^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$' -or -not [string]$Binding['Host'] -or -not [string]$Binding['User'] -or [string]$Binding['PinnedHostKey'] -cnotmatch '^SHA256:[A-Za-z0-9+/]{43}=?$'){Stop-TCDeploy InvalidRequest '登录资料绑定信息无效。'}
        $bindingDigest=Get-TCDDigest $Binding
        $metadata=@{Kind='TradeChannel.DeploymentCredential';SchemaVersion=2;Protection='DPAPI.CurrentUser';CredentialKind=$credentialKind;SavedAtUtc=[DateTime]::UtcNow.ToString('o');BindingDigest=$bindingDigest}
        if($ManagementSigningKeyDigest){$metadata['ManagementSigningKeyDigest']=$ManagementSigningKeyDigest}
        if($KeyPathHint){$metadata['KeyPathHint']=$KeyPathHint}
    }
    $private=$null;$bytes=$null;$gate=$null;$credentialLock=$null;$id=$null
    try{
        $private=ConvertTo-TCDeployCredential $Credential
        if($isV2 -and $private.Kind -cne [string]$metadata['CredentialKind']){Stop-TCDeploy InvalidCredential '登录资料方式与绑定不一致。'}
        if(-not $GateHeld){$gate=Open-TCDLock (Join-Path $base '.local-cleanup.lock');Assert-TCLocalCleanupReady $base}
        $credentialLock=Open-TCDLock (Join-Path $base 'deployments\.credentials.lock')
        New-TCDeployPrivateDirectory $base;New-TCDeployPrivateDirectory $directory
        $id=[guid]::NewGuid().ToString();$bytes=[Text.Encoding]::UTF8.GetBytes(($private|ConvertTo-Json -Compress));Add-Type -AssemblyName System.Security
        $entropy=if($isV2){'TradeChannel.DeploymentCredential.v2:'+$bindingDigest}else{'TradeChannel.DeploymentCredential.v1'}
        $cipher=[Security.Cryptography.ProtectedData]::Protect($bytes,[Text.Encoding]::UTF8.GetBytes($entropy),[Security.Cryptography.DataProtectionScope]::CurrentUser)
        $payload=if($isV2){$metadata}else{@{Kind='TradeChannel.DeploymentCredential';SchemaVersion=1}}
        $payload['Protected']=[Convert]::ToBase64String($cipher)
        $module=Get-TCDeployLinuxModule
        & $module {param($Path,$Value) Write-TCLinuxJson $Path $Value} (Join-Path $directory ($id+'.json')) $payload
    }finally{if($bytes){[Array]::Clear($bytes,0,$bytes.Length)};if($private){$private.Clear()};if($credentialLock){$credentialLock.Dispose()};if($gate){$gate.Dispose()}}
    return [pscustomobject]@{CredentialRef=$id;Protection='DPAPI.CurrentUser'}
}
function Get-TCDeploySavedCredential {
    # Classification happens on plaintext metadata BEFORE any decryption, so a
    # moved identity reports CredentialBindingChanged instead of a generic
    # "cannot decrypt", and a legacy v1 file is never silently reused.
    [CmdletBinding()]param([string]$Root,[Parameter(Mandatory=$true)][string]$CredentialRef,[hashtable]$Binding,[string]$CurrentManagementSigningKeyDigest='')
    $file=Get-TCDeploySavedCredentialPath $Root $CredentialRef
    if(-not [IO.File]::Exists($file)){Stop-TCDeploy CredentialMissing '这台服务器的登录资料已不在本机，请重新输入一次。'}
    $value=Read-TCDeploySavedCredentialEnvelope $file
    if($null -eq $value){Stop-TCDeploy CredentialUnavailable '这台电脑无法读取已保存的登录资料。换 Windows 用户或换电脑需要重新输入一次。'}
    if([string](Get-TCDeployProperty $value Kind '') -cne 'TradeChannel.DeploymentCredential'){Stop-TCDeploy InvalidCredential '凭据格式无效。'}
    $schema=Get-TCDeployProperty $value SchemaVersion 0;$expectedKind='';$storedDigest='';$entropy=''
    if($schema -eq 1){
        # v1 files are readable only by callers that do not claim a binding.
        if($null -ne $Binding){Stop-TCDeploy CredentialLegacy '这份登录资料是旧格式，请重新输入一次。'}
        $entropy='TradeChannel.DeploymentCredential.v1'
    }elseif($schema -eq 2){
        $expectedKind=[string](Get-TCDeployProperty $value CredentialKind '')
        $storedDigest=[string](Get-TCDeployProperty $value BindingDigest '')
        if($expectedKind -cnotin @('Password','PrivateKey') -or $storedDigest -cnotmatch '^[a-f0-9]{64}$'){Stop-TCDeploy InvalidCredential '凭据格式无效。'}
        if($null -ne $Binding){$compare=Get-TCDeployComparableBinding $Binding $expectedKind;if((Get-TCDDigest $compare) -cne $storedDigest){Stop-TCDeploy CredentialBindingChanged '这台服务器的身份已经变化，已保存的登录资料不再适用。'}}
        $storedSigning=[string](Get-TCDeployProperty $value ManagementSigningKeyDigest '')
        if($storedSigning -and $CurrentManagementSigningKeyDigest -and $storedSigning -cne $CurrentManagementSigningKeyDigest){Stop-TCDeploy CredentialBindingChanged '这台服务器的身份已经变化，已保存的登录资料不再适用。'}
        $entropy='TradeChannel.DeploymentCredential.v2:'+$storedDigest
    }else{Stop-TCDeploy InvalidCredential '凭据格式无效。'}
    $cipherText=[string](Get-TCDeployProperty $value Protected '')
    if(-not $cipherText){Stop-TCDeploy InvalidCredential '凭据格式无效。'}
    $plain=$null
    try{
        Add-Type -AssemblyName System.Security
        $plain=[Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($cipherText),[Text.Encoding]::UTF8.GetBytes($entropy),[Security.Cryptography.DataProtectionScope]::CurrentUser)
        $credential=[Text.Encoding]::UTF8.GetString($plain)|ConvertFrom-Json -ErrorAction Stop
        $kind=[string](Get-TCDeployProperty $credential Kind '')
        if($kind -cnotin @('Password','PrivateKey') -or ($expectedKind -and $kind -cne $expectedKind)){throw 'Envelope kind'}
        $out=@{Kind=$kind}
        foreach($name in @('Password','PrivateKeyPem','Passphrase')){$present=Get-TCDeployProperty $credential $name $null;if($null -ne $present){$out[$name]=if([string]$present){ConvertTo-SecureString ([string]$present) -AsPlainText -Force}else{New-Object Security.SecureString}}}
        return $out
    }catch{Stop-TCDeploy CredentialUnavailable '无法解密该凭据；请重新认证。'}finally{if($plain){[Array]::Clear($plain,0,$plain.Length)}}
}
function Get-TCDeploySavedCredentialInfo {
    # Read-only status for UI decisions. Never decrypts and never removes the
    # file, so it cannot retire a credential that a later save still owns.
    [CmdletBinding()]param([string]$Root,[Parameter(Mandatory=$true)][string]$CredentialRef,[hashtable]$Binding,[string]$CurrentManagementSigningKeyDigest='')
    $file=Get-TCDeploySavedCredentialPath $Root $CredentialRef
    $result=[pscustomobject]@{Status='Invalid';CredentialKind='';SavedAtUtc=$null;KeyPathHint=$null;BindingDigest=$null}
    try{
        if(-not [IO.File]::Exists($file)){$result.Status='Missing';return $result}
        $value=Read-TCDeploySavedCredentialEnvelope $file
        if($null -eq $value){$result.Status='Invalid';return $result}
        if([string](Get-TCDeployProperty $value Kind '') -cne 'TradeChannel.DeploymentCredential'){$result.Status='Invalid';return $result}
        $result.CredentialKind=[string](Get-TCDeployProperty $value CredentialKind '')
        $savedAt=Get-TCDeployProperty $value SavedAtUtc $null
        $result.SavedAtUtc=if($savedAt -is [DateTime]){$savedAt.ToUniversalTime().ToString('o')}elseif($savedAt){[string]$savedAt}else{$null}
        $hint=Get-TCDeployProperty $value KeyPathHint $null;$result.KeyPathHint=if($hint){[string]$hint}else{$null}
        $digest=Get-TCDeployProperty $value BindingDigest $null;$result.BindingDigest=if($digest){[string]$digest}else{$null}
        $schema=Get-TCDeployProperty $value SchemaVersion 0
        if($schema -eq 1){$result.Status='Legacy';return $result}
        if($schema -ne 2){$result.Status='Invalid';return $result}
        $storedDigest=[string](Get-TCDeployProperty $value BindingDigest '')
        if($result.CredentialKind -cnotin @('Password','PrivateKey') -or $storedDigest -cnotmatch '^[a-f0-9]{64}$' -or -not [string](Get-TCDeployProperty $value Protected '')){$result.Status='Invalid';return $result}
        if($null -ne $Binding){$compare=Get-TCDeployComparableBinding $Binding $result.CredentialKind;if((Get-TCDDigest $compare) -cne $storedDigest){$result.Status='BindingChanged';return $result}}
        $storedSigning=[string](Get-TCDeployProperty $value ManagementSigningKeyDigest '')
        if($storedSigning -and $CurrentManagementSigningKeyDigest -and $storedSigning -cne $CurrentManagementSigningKeyDigest){$result.Status='BindingChanged';return $result}
        $result.Status='Available'
        return $result
    }catch{$result.Status='Invalid';return $result}
}
function Remove-TCDeploySavedCredential {
    # -GateHeld exists because an orchestrator that already holds the cleanup
    # gate cannot open the same lock file twice in one process.
    [CmdletBinding()]param([string]$Root,[Parameter(Mandatory=$true)][string]$CredentialRef,[switch]$AllowMissing,[switch]$GateHeld)
    $file=Get-TCDeploySavedCredentialPath $Root $CredentialRef
    $base=Assert-TCDPath (Resolve-TCDeployRoot $Root)
    $gate=$null;$credentialLock=$null
    try{
        if(-not $GateHeld){$gate=Open-TCDLock (Join-Path $base '.local-cleanup.lock')}
        $credentialLock=Open-TCDLock (Join-Path $base 'deployments\.credentials.lock')
        if(-not [IO.File]::Exists($file)){if($AllowMissing){return $false};Stop-TCDeploy CredentialMissing '这台服务器的登录资料已不在本机，请重新输入一次。'}
        [IO.File]::Delete((Assert-TCDPath $file))
        return $true
    }finally{if($credentialLock){$credentialLock.Dispose()};if($gate){$gate.Dispose()}}
}
function Get-TCDeployTaskCredentialPath {param([string]$Root,[string]$RunId)
    Import-Module (Join-Path $PSScriptRoot 'DeploymentStore.psm1') -DisableNameChecking
    $id=Assert-TCDId $RunId;$base=Assert-TCDPath (Resolve-TCDeployRoot $Root)
    return Assert-TCDPath (Join-Path (Join-Path $base 'deployments\credentials') ($id+'.json'))
}
function Get-TCDeployTaskCredentialBinding {param([string]$Root,[string]$RunId,[string]$CredentialKind)
    Import-Module (Join-Path $PSScriptRoot 'ServerRegistry.psm1') -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'DraftDisposition.psm1') -DisableNameChecking
    $id=Assert-TCDId $RunId;$base=Resolve-TCDeployRoot $Root
    Assert-TCDraftActive -Root $base -Id ('DeploymentRun:'+$id)
    $run=Read-TCDJson (Join-Path (Join-Path $base ('deployments\runs\'+$id)) 'state.json')
    if([string]$run.RunId -cne $id -or [string]$run.Status -in @('Complete','Cancelled') -or ([string]$run.Stage -eq 'ReadyInactive' -and [string](Get-TCDeployProperty $run DeploymentCompleteness '') -eq 'Complete')){Stop-TCDeploy CredentialTaskEnded '该任务已结束，登录资料不再续接。'}
    $server=Assert-TCServerTaskActive -Root $base -RunId $id
    if(@(Get-TCDeployProperty $server IdentityTransitionTasks @()|Where-Object {[string]$_.Kind -ceq 'Deployment' -and [string]$_.Id -ceq $id}).Count){Stop-TCDeploy CredentialTargetChanged '原任务的服务器身份已经变化，登录资料不能绑定到新身份；请按核验后的任务继续。'}
    if([string](Get-TCDeployProperty $server RecordState 'Active') -cne 'Active' -or [string]$server.PinnedHostKey -cnotmatch '^SHA256:[A-Za-z0-9+/]{43}$'){Stop-TCDeploy CredentialTargetChanged '服务器身份未确认或已变化，请重新登录。'}
    if($CredentialKind -notin @('Password','PrivateKey')){Stop-TCDeploy InvalidCredential '任务登录方式无效。'}
    return [ordered]@{RunId=$id;ServerRecordId=[string]$server.LocalRecordId;Host=[string]$server.Connection.Host;Port=[int]$server.Connection.Port;User=[string]$server.Connection.User;PinnedFingerprint=[string]$server.PinnedHostKey;IdentityRevision=[int](Get-TCDeployProperty $server IdentityTransitionRevision 0);CredentialKind=$CredentialKind}
}
function Save-TCDeployTaskCredential {
    [CmdletBinding()]param([string]$Root,[Parameter(Mandatory=$true)][string]$RunId,[Parameter(Mandatory=$true)]$Credential,[Parameter(Mandatory=$true)][string]$CredentialRevision)
    $path=Get-TCDeployTaskCredentialPath $Root $RunId;$revision=Assert-TCDId $CredentialRevision;$base=Resolve-TCDeployRoot $Root
    $gate=Open-TCDLock (Join-Path $base '.local-cleanup.lock');$credentialLock=$null;$private=$null;$bytes=$null
    try{
        $credentialLock=Open-TCDLock (Join-Path $base 'deployments\.credentials.lock')
        Assert-TCLocalCleanupReady $base
        $private=ConvertTo-TCDeployCredential $Credential;$binding=Get-TCDeployTaskCredentialBinding $base $RunId $private.Kind
        $now=[DateTimeOffset]::UtcNow;$expires=$now.AddHours(24)
        $previous=Read-TCDJson $path -AllowMissing
        if($previous -and [string](Get-TCDeployProperty $previous CredentialRevision '') -ceq $revision){
            $originalExpiry=[DateTimeOffset]::MinValue
            if([DateTimeOffset]::TryParse([string](Get-TCDeployProperty $previous ExpiresAtUtc ''),[ref]$originalExpiry) -and $originalExpiry -gt $now -and $originalExpiry -lt $expires){$expires=$originalExpiry}
        }
        $bindingDigest=Get-TCDDigest $binding
        $payload=@{Binding=$binding;CredentialRevision=$revision;ExpiresAtUtc=$expires.ToString('o');Credential=$private}
        $bytes=[Text.Encoding]::UTF8.GetBytes(($payload|ConvertTo-Json -Depth 8 -Compress));Add-Type -AssemblyName System.Security
        $entropy=[Text.Encoding]::UTF8.GetBytes('TradeChannel.TaskCredential.v1:'+$bindingDigest+':'+$revision)
        $cipher=[Security.Cryptography.ProtectedData]::Protect($bytes,$entropy,[Security.Cryptography.DataProtectionScope]::CurrentUser)
        Write-TCDJson $path @{Kind='TradeChannel.TaskCredential';SchemaVersion=1;Binding=$binding;CredentialRevision=$revision;ExpiresAtUtc=$expires.ToString('o');Protected=[Convert]::ToBase64String($cipher)} -Compact
        return [pscustomobject]@{Saved=$true;CredentialRevision=$revision;ExpiresAtUtc=$expires.ToString('o');Protection='DPAPI.CurrentUser'}
    }finally{if($bytes){[Array]::Clear($bytes,0,$bytes.Length)};if($private){$private.Clear()};if($credentialLock){$credentialLock.Dispose()};$gate.Dispose()}
}
function Get-TCDeployTaskCredentialState {
    # Read-only classification: neither metadata inspection nor temporary I/O
    # failure can retire a credential. The compatibility getter conditionally
    # invalidates a proved stale revision after this snapshot has been released.
    [CmdletBinding()]param([string]$Root,[Parameter(Mandatory=$true)][string]$RunId,[switch]$InfoOnly)
    $path=Get-TCDeployTaskCredentialPath $Root $RunId;$base=Resolve-TCDeployRoot $Root
    $result=[pscustomobject]@{Status='Missing';Available=$false;ReasonCode='CredentialMissing';Retryable=$false;CredentialRevision='';Binding=$null;ExpiresAtUtc=$null;Credential=$null}
    $gate=$null;$credentialLock=$null;$plain=$null;$phase='Read'
    try{
        $gate=Open-TCDLock (Join-Path $base '.local-cleanup.lock') -TimeoutMs 0
        $credentialLock=Open-TCDLock (Join-Path $base 'deployments\.credentials.lock') -TimeoutMs 0
        Assert-TCLocalCleanupReady $base
        $stored=Read-TCDJson $path -AllowMissing
        if(-not $stored){return $result}
        $phase='Envelope'
        if([string](Get-TCDeployProperty $stored Kind '') -cne 'TradeChannel.TaskCredential' -or (Get-TCDeployProperty $stored SchemaVersion 0) -ne 1){throw 'Envelope kind'}
        $result.CredentialRevision=Assert-TCDId ([string](Get-TCDeployProperty $stored CredentialRevision ''))
        $expires=[DateTimeOffset]::MinValue
        if(-not [DateTimeOffset]::TryParse([string](Get-TCDeployProperty $stored ExpiresAtUtc ''),[ref]$expires) -or $expires -gt [DateTimeOffset]::UtcNow.AddHours(24)){throw 'Envelope expiry'}
        $result.ExpiresAtUtc=$stored.ExpiresAtUtc
        $storedBinding=Get-TCDeployProperty $stored Binding
        $kind=[string](Get-TCDeployProperty $storedBinding CredentialKind '')
        if($kind -notin @('Password','PrivateKey') -or -not [string](Get-TCDeployProperty $stored Protected '')){throw 'Envelope credential'}
        $phase='Binding'
        $binding=Get-TCDeployTaskCredentialBinding $base $RunId $kind
        $result.Binding=$binding
        if((Get-TCDDigest $binding) -cne (Get-TCDDigest $storedBinding)){$result.Status='BindingChanged';$result.ReasonCode='CredentialTargetChanged';return $result}
        if($expires -le [DateTimeOffset]::UtcNow){$result.Status='Expired';$result.ReasonCode='CredentialExpired';return $result}
        if(-not $InfoOnly){
            $phase='Decrypt';Add-Type -AssemblyName System.Security
            $entropy=[Text.Encoding]::UTF8.GetBytes('TradeChannel.TaskCredential.v1:'+(Get-TCDDigest $binding)+':'+$stored.CredentialRevision)
            $plain=[Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($stored.Protected),$entropy,[Security.Cryptography.DataProtectionScope]::CurrentUser)
            $payload=[Text.Encoding]::UTF8.GetString($plain)|ConvertFrom-Json -ErrorAction Stop
            if((Get-TCDDigest $payload.Binding) -cne (Get-TCDDigest $binding) -or [string]$payload.CredentialRevision -cne [string]$stored.CredentialRevision -or [string]$payload.ExpiresAtUtc -cne [string]$stored.ExpiresAtUtc -or [string]$payload.Credential.Kind -cne $kind){throw 'Binding mismatch'}
            $out=@{Kind=$kind}
            foreach($name in @('Password','PrivateKeyPem','Passphrase')){if($payload.Credential.PSObject.Properties[$name]){$out[$name]=if([string]$payload.Credential.$name){ConvertTo-SecureString ([string]$payload.Credential.$name) -AsPlainText -Force}else{New-Object Security.SecureString}}}
            $result.Credential=$out
        }
        $result.Status='Available';$result.Available=$true;$result.ReasonCode='CredentialAvailable'
        return $result
    }catch{
        $code='';if($_.Exception.Message -match '^\[TC:([A-Za-z][A-Za-z0-9_]+)\]'){$code=$matches[1]}
        if($phase -eq 'Binding' -and $code -in @('CredentialTargetChanged','CredentialTaskEnded','DraftDiscarded','ServerTaskIdentityChanged','ServerArchived')){
            $result.Status='BindingChanged';$result.ReasonCode=$code
        }elseif($phase -in @('Envelope','Decrypt') -or ($phase -eq 'Read' -and $code -in @('InvalidData','DataTooLarge'))){
            $result.Status='InvalidEnvelope';$result.ReasonCode='CredentialUnavailable'
        }else{
            # Missing/inaccessible run or registry data is not evidence that
            # the target has changed. Keep the original DPAPI bytes untouched.
            $result.Status='TemporarilyUnavailable';$result.ReasonCode='CredentialTemporarilyUnavailable';$result.Retryable=$true
        }
        return $result
    }finally{if($plain){[Array]::Clear($plain,0,$plain.Length)};if($credentialLock){$credentialLock.Dispose()};if($gate){$gate.Dispose()}}
}
function Get-TCDeployTaskCredential {
    [CmdletBinding()]param([string]$Root,[Parameter(Mandatory=$true)][string]$RunId,[switch]$InfoOnly)
    $result=Get-TCDeployTaskCredentialState -Root $Root -RunId $RunId -InfoOnly:$InfoOnly
    if($result.Available){return $result}
    if($InfoOnly){return $null}
    if($result.Status -eq 'TemporarilyUnavailable'){Stop-TCDeploy CredentialTemporarilyUnavailable '本机登录资料暂时被占用，可重试读取；输入内容和已保存资料均保留。'}
    if($result.Status -in @('Expired','BindingChanged','InvalidEnvelope') -and $result.CredentialRevision){
        # Another explicit save may win between observation and invalidation.
        # Remove only the exact revision observed, under the existing locks.
        $null=Remove-TCDeployTaskCredential -Root $Root -RunId $RunId -CredentialRevision $result.CredentialRevision
    }
    if($result.Status -eq 'InvalidEnvelope'){Stop-TCDeploy CredentialUnavailable '任务登录资料无法解密或格式无效，请重新输入。'}
    return $null
}
function Remove-TCDeployTaskCredential {
    [CmdletBinding()]param([string]$Root,[Parameter(Mandatory=$true)][string]$RunId,[string]$CredentialRevision='',[switch]$StateInvalidated)
    $path=Get-TCDeployTaskCredentialPath $Root $RunId
    $base=Resolve-TCDeployRoot $Root;$gate=$null;$credentialLock=$null
    try{
        # Terminal run/identity writes already hold their task lease. Do not
        # invert cleanup gate -> task lease by acquiring the gate here.
        if(-not $StateInvalidated){$gate=Open-TCDLock (Join-Path $base '.local-cleanup.lock')}
        $credentialLock=Open-TCDLock (Join-Path $base 'deployments\.credentials.lock')
        $stored=Read-TCDJson $path -AllowMissing;if(-not $stored){return $false}
        # A late failure may revoke only the submitted revision it belongs to.
        if($CredentialRevision -and [string]$stored.CredentialRevision -cne $CredentialRevision){return $false}
        [IO.File]::Delete((Assert-TCDPath $path));return $true
    }finally{if($credentialLock){$credentialLock.Dispose()};if($gate){$gate.Dispose()}}
}
function Close-TCDeployIdleSessionsForCleanup {
    [CmdletBinding()]param([string]$Root,[Parameter(Mandatory=$true)][object[]]$Executors,[ValidateRange(1,10)][int]$WaitSeconds=5)
    Import-Module (Join-Path $PSScriptRoot 'DeploymentStore.psm1') -DisableNameChecking
    $base=Resolve-TCDeployRoot $Root;$watch=[Diagnostics.Stopwatch]::StartNew();$closed=0
    foreach($entry in $Executors){
        $ref=Get-TCDeployProperty $entry SessionRef;Assert-TCDeploySessionRef $ref
        $runId=Assert-TCDId ([string]$entry.RunId)
        $expectedRoot=Join-Path $base ('deployments\hosts\'+[string]$ref.InstanceId)
        if($ref.RunId -cne $runId -or (Assert-TCDPath ([string]$ref.Root)).TrimEnd('\') -ine $expectedRoot.TrimEnd('\')){Stop-TCDeploy CleanupExecutorMismatch '待结束会话与这份记录不匹配，请刷新清理范围。'}
        $run=Read-TCDJson (Join-Path $base ('deployments\runs\'+$runId+'\state.json'))
        $refs=@((Get-TCDeployProperty $run SessionRef),(Get-TCDeployProperty $run AttemptSessionRef)|Where-Object {$_})
        if(-not @($refs|Where-Object {(Get-TCDDigest $_) -ceq (Get-TCDDigest $ref)}).Count){Stop-TCDeploy CleanupExecutorMismatch '记录的登录会话已变化，请重新核对。'}
        $remaining=[math]::Max(0,($WaitSeconds*1000)-[int]$watch.ElapsedMilliseconds)
        if($remaining -lt 1){Stop-TCDeploy CleanupExecutorTimeout '会话核对已达到等待期限，原资料保留。'}
        try{$poll=Get-TCDeploySession $ref -TotalTimeoutMs $remaining}catch{if($_.Exception.Message -match '\[TC:PipeTimeout\]' -or $watch.ElapsedMilliseconds -ge ($WaitSeconds*1000)){Stop-TCDeploy CleanupExecutorTimeout '会话核对已达到等待期限，原资料保留。'};throw}
        if([string](Get-TCDeployProperty $poll RunId '') -cne $runId -or [string](Get-TCDeployProperty $poll InstanceId '') -cne [string]$ref.InstanceId -or [string]$poll.Status -notin @('AwaitingCredential','AwaitingTrust','Failed','Ready','Completed') -or (Get-TCDeployProperty $poll HasMutatingOperations) -isnot [bool] -or [string]$run.Status -in @('Running','Dispatching') -or (Get-TCDeployProperty $run PendingOperationId)){
            Stop-TCDeploy CleanupExecutorActive '服务器步骤仍在执行或状态尚不能确认。此次没有关闭会话；请等待当前步骤结束或核对原结果。'
        }
        $remainingBeforeClose=[math]::Max(0,($WaitSeconds*1000)-[int]$watch.ElapsedMilliseconds)
        if($remainingBeforeClose -lt 1){Stop-TCDeploy CleanupExecutorTimeout '已请求结束空闲会话，但 5 秒内未确认退出。原资料保留，可稍后重新核对清理范围。'}
        try{$result=Stop-TCDeploySession $ref -TotalTimeoutMs $remainingBeforeClose}catch{if($_.Exception.Message -match '\[TC:PipeTimeout\]' -or $watch.ElapsedMilliseconds -ge ($WaitSeconds*1000)){Stop-TCDeploy CleanupExecutorTimeout '已请求结束空闲会话，但 5 秒内未确认退出。原资料保留，可稍后重新核对清理范围。'};throw}
        if(-not (Get-TCDeployProperty $result Closed $false)){Stop-TCDeploy CleanupExecutorActive '执行器没有接受空闲关闭；原资料保留，请查看当前步骤。'}
        $process=$null
        try{
            $process=Get-Process -Id ([int]$ref.ProcessId) -ErrorAction SilentlyContinue
            if($process -and [string]$process.StartTime.ToUniversalTime().Ticks -ceq [string]$ref.StartTimeUtcTicks -and $process.Path -ieq (Join-Path $PSScriptRoot 'deployment\TradeChannelDeployHost.exe')){
                $remaining=[math]::Max(0,($WaitSeconds*1000)-[int]$watch.ElapsedMilliseconds)
                if(-not $process.WaitForExit($remaining)){Stop-TCDeploy CleanupExecutorTimeout '已请求结束空闲会话，但 5 秒内未确认退出。原资料保留，可稍后重新核对清理范围。'}
            }
        }finally{if($process){$process.Dispose()}}
        $closed++
    }
    return [pscustomobject]@{ClosedCount=$closed;RemoteChanges=$false;ElapsedMilliseconds=$watch.ElapsedMilliseconds}
}
Export-ModuleMember -Function Get-TCDeployVerifiedOperation,Start-TCDeploySession,Set-TCDeployCredential,Get-TCDeploySession,Invoke-TCDeployOperation,Invoke-TCDeployPairOnlineOperation,Stop-TCDeploySession,Save-TCDeployCredential,Get-TCDeploySavedCredential,Get-TCDeploySavedCredentialInfo,Remove-TCDeploySavedCredential,Save-TCDeployTaskCredential,Get-TCDeployTaskCredentialState,Get-TCDeployTaskCredential,Remove-TCDeployTaskCredential,Close-TCDeployIdleSessionsForCleanup,Get-TCDeployVerifiedHostIdentity,Get-TCDeployVerifiedServerInfo,Get-TCDeployServerIdentityEvidence,Get-TCDeployAccessDiagnostic
