#requires -Version 5.1
Set-StrictMode -Version 2.0
$script:TCDeployLinux = $null
function Get-TCDeployLinuxModule {
    if (-not $script:TCDeployLinux) { $script:TCDeployLinux = Import-Module (Join-Path $PSScriptRoot 'LinuxServerSetup.psm1') -PassThru -DisableNameChecking -ErrorAction Stop }
    $script:TCDeployLinux
}
function Stop-TCDeploy { param([string]$Code,[string]$Message) throw [InvalidOperationException]::new('[TC:'+$Code+'] '+$Message) }
function Get-TCDeployProperty { param($Value,[string]$Name,$Default=$null) if($Value -is [Collections.IDictionary]){if($Value.Contains($Name)){return $Value[$Name]}}elseif($Value -and $Value.PSObject.Properties[$Name]){return $Value.$Name};return $Default }
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
    $null=Resolve-TCDeployRoot ([string]$SessionRef.Root)
}
function Read-TCDeployPipeBytes {
    param([IO.Stream]$Pipe,[int]$Length)
    $bytes=New-Object byte[] $Length;$offset=0
    while($offset -lt $Length){$async=$Pipe.BeginRead($bytes,$offset,$Length-$offset,$null,$null);if(-not $async.AsyncWaitHandle.WaitOne(10000)){Stop-TCDeploy PipeTimeout '部署执行器响应超时。'};$got=$Pipe.EndRead($async);if($got -le 0){Stop-TCDeploy PipeClosed '部署执行器通道关闭。'};$offset+=$got}
    return ,$bytes
}
function Invoke-TCDeployPipe {
    param($SessionRef,[hashtable]$Body,[int]$ConnectTimeout=3000)
    Assert-TCDeploySessionRef $SessionRef
    $Body.RunId=[string]$SessionRef.RunId;$Body.InstanceId=[string]$SessionRef.InstanceId
    $pipe=New-Object IO.Pipes.NamedPipeClientStream('.',[string]$SessionRef.PipeName,[IO.Pipes.PipeDirection]::InOut,[IO.Pipes.PipeOptions]::Asynchronous,[Security.Principal.TokenImpersonationLevel]::Impersonation)
    try {
        $pipe.Connect($ConnectTimeout)
        $text=$Body|ConvertTo-Json -Depth 32 -Compress;$bytes=[Text.Encoding]::UTF8.GetBytes($text);if($bytes.Length -gt 4MB){Stop-TCDeploy InputTooLarge '会话请求超限。'}
        $length=[BitConverter]::GetBytes([int]$bytes.Length);$pipe.Write($length,0,4);$pipe.Write($bytes,0,$bytes.Length);$pipe.Flush();[Array]::Clear($bytes,0,$bytes.Length);$text=$null
        $count=[BitConverter]::ToInt32((Read-TCDeployPipeBytes $pipe 4),0);if($count -lt 2 -or $count -gt 4MB){Stop-TCDeploy InvalidEnvelope '会话响应大小无效。'}
        $response=[Text.Encoding]::UTF8.GetString((Read-TCDeployPipeBytes $pipe $count))|ConvertFrom-Json -ErrorAction Stop
        if((Get-TCDeployProperty $response Ok) -isnot [bool]){Stop-TCDeploy InvalidEnvelope '会话响应无效。'}
        return $response
    } finally { $pipe.Dispose();if($Body.ContainsKey('Credential')){if($Body.Credential -is [Collections.IDictionary]){$Body.Credential.Clear()};$Body.Remove('Credential')} }
}
function Start-TCDeploySession {
    [CmdletBinding()]
    param([string]$Root,[Parameter(Mandatory=$true)][string]$RunId,$Connection,$Credential,[string]$PinnedFingerprint='')
    Import-Module (Join-Path $PSScriptRoot 'DeploymentDependencies.psm1') -DisableNameChecking;$null=Test-TCDeploymentDependencies -PackageRoot $PSScriptRoot
    $rootPath=Resolve-TCDeployRoot $Root
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
    $status='AwaitingCredential';if($Credential){$null=Set-TCDeployCredential -SessionRef $ref -Connection $Connection -Credential $Credential -PinnedFingerprint $PinnedFingerprint;$status='Connecting'}
    [pscustomobject]@{Ok=$true;Code='SessionStarted';Status=$status;SessionRef=$ref}
}
function Set-TCDeployCredential {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$SessionRef,[Parameter(Mandatory=$true)]$Connection,[Parameter(Mandatory=$true)]$Credential,[string]$PinnedFingerprint='')
    Assert-TCDeployFields $Connection @('Host','Port','User','IdentityFile')
    $connectionValue=@{Host=[string](Get-TCDeployProperty $Connection Host '');Port=[int](Get-TCDeployProperty $Connection Port 22);User=[string](Get-TCDeployProperty $Connection User 'root')}
    if($PinnedFingerprint -and $PinnedFingerprint -cnotmatch '^SHA256:[A-Za-z0-9+/]{43}$'){Stop-TCDeploy InvalidFingerprint '主机指纹必须是 SHA256 格式。'}
    $private=ConvertTo-TCDeployCredential $Credential
    Invoke-TCDeployPipe $SessionRef @{Command='Authenticate';Connection=$connectionValue;Credential=$private;PinnedFingerprint=$PinnedFingerprint}
}
function Get-TCDeploySession {
    [CmdletBinding()]param([Parameter(Mandatory=$true)]$SessionRef)
    Assert-TCDeploySessionRef $SessionRef
    try{return Invoke-TCDeployPipe $SessionRef @{Command='Poll'}}catch{
        $alive=$false;try{$process=Get-Process -Id ([int]$SessionRef.ProcessId) -ErrorAction Stop;try{$alive=([string]$process.StartTime.ToUniversalTime().Ticks -ceq [string]$SessionRef.StartTimeUtcTicks -and $process.Path -ieq (Join-Path $PSScriptRoot 'deployment\TradeChannelDeployHost.exe'))}finally{$process.Dispose()}}catch{}
        if($alive){return [pscustomobject]@{Ok=$false;Status='Running';Stage='Executor';Code='ExecutorBusy';HasSession=$false;Data=$null}}
        $receipt=$null;$file=Join-Path $SessionRef.Root 'receipt.json';$module=Get-TCDeployLinuxModule
        if(Test-Path -LiteralPath $file){try{$receipt=& $module {param($Path) Read-TCLinuxJson $Path} $file}catch{}}
        $mutating=[bool](Get-TCDeployProperty $receipt Mutating ([string](Get-TCDeployProperty $receipt Operation '') -in @('apply','authorize','recover','finalize','management_apply','device_rename','invite_create','invite_cancel','authorize_external','revoke','uninstall','transport_apply')))
        $status=if($mutating -and [string](Get-TCDeployProperty $receipt Status '') -ceq 'Running'){'OutcomeUnknown'}else{'Failed'}
        [pscustomobject]@{Ok=$false;Status=$status;Stage=[string](Get-TCDeployProperty $receipt Stage 'PrepareAccess');Code='AuthenticationRequired';OperationId=[string](Get-TCDeployProperty $receipt OperationId '');HasSession=$false;Data=$null}
    }
}
function Invoke-TCDeployOperation {
    [CmdletBinding()]param([Parameter(Mandatory=$true)]$SessionRef,[Parameter(Mandatory=$true)][string]$Operation,[Alias('Input')]$OperationInput=@{},[string]$OperationId='')
    $aliases=@{Inspect='inspect';Plan='plan';Apply='apply';Status='status';Authorize='authorize';Recover='recover';Finalize='finalize';Capabilities='capabilities';ServerInfo='server_info';Devices='devices';DeviceRename='device_rename';ManagementPlan='management_plan';ManagementApply='management_apply';InviteCreate='invite_create';InviteCancel='invite_cancel';InviteStatus='invite_status';AuthorizeExternal='authorize_external';RequestStatus='request_status';RevokePreview='revoke_preview';Revoke='revoke';UninstallPreview='uninstall_preview';Uninstall='uninstall';TransportPlan='transport_plan';TransportApply='transport_apply';TransportInfo='transport_info'}
    $action=if($aliases.ContainsKey($Operation)){$aliases[$Operation]}else{$Operation};if($action -cnotin @($aliases.Values)){Stop-TCDeploy InvalidOperation '未支持的部署操作。'}
    $body=@{Command='Execute';Operation=$action;Input=$OperationInput};if($OperationId){if($OperationId -cnotmatch '^[0-9a-f-]{36}$'){Stop-TCDeploy InvalidId '操作幂等标识无效。'};$body.OperationId=$OperationId}
    Invoke-TCDeployPipe $SessionRef $body
}
function Stop-TCDeploySession { [CmdletBinding()]param([Parameter(Mandatory=$true)]$SessionRef,[switch]$Cancel) $command=if($Cancel){'Cancel'}else{'Close'};Invoke-TCDeployPipe $SessionRef @{Command=$command} }
function Save-TCDeployCredential {
    [CmdletBinding()]param([string]$Root,[Parameter(Mandatory=$true)]$Credential)
    $base=Resolve-TCDeployRoot $Root;$directory=Join-Path $base 'credentials';New-TCDeployPrivateDirectory $base;New-TCDeployPrivateDirectory $directory
    $private=ConvertTo-TCDeployCredential $Credential;$id=[guid]::NewGuid().ToString();$bytes=[Text.Encoding]::UTF8.GetBytes(($private|ConvertTo-Json -Compress));Add-Type -AssemblyName System.Security
    try{$cipher=[Security.Cryptography.ProtectedData]::Protect($bytes,[Text.Encoding]::UTF8.GetBytes('TradeChannel.DeploymentCredential.v1'),[Security.Cryptography.DataProtectionScope]::CurrentUser);$module=Get-TCDeployLinuxModule;& $module {param($Path,$Value) Write-TCLinuxJson $Path $Value} (Join-Path $directory ($id+'.json')) @{Kind='TradeChannel.DeploymentCredential';SchemaVersion=1;Protected=[Convert]::ToBase64String($cipher)}}finally{[Array]::Clear($bytes,0,$bytes.Length);$private.Clear()}
    [pscustomobject]@{CredentialRef=$id;Protection='DPAPI.CurrentUser'}
}
function Get-TCDeploySavedCredential {
    [CmdletBinding()]param([string]$Root,[Parameter(Mandatory=$true)][string]$CredentialRef)
    if($CredentialRef -cnotmatch '^[0-9a-f-]{36}$'){Stop-TCDeploy InvalidId '凭据引用无效。'};$module=Get-TCDeployLinuxModule;$file=Join-Path (Join-Path (Resolve-TCDeployRoot $Root) 'credentials') ($CredentialRef+'.json');$value=& $module {param($Path) Read-TCLinuxJson $Path 2MB} $file
    if($value.Kind -cne 'TradeChannel.DeploymentCredential' -or $value.SchemaVersion -ne 1){Stop-TCDeploy InvalidCredential '凭据格式无效。'};Add-Type -AssemblyName System.Security
    try{$plain=[Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($value.Protected),[Text.Encoding]::UTF8.GetBytes('TradeChannel.DeploymentCredential.v1'),[Security.Cryptography.DataProtectionScope]::CurrentUser);$credential=[Text.Encoding]::UTF8.GetString($plain)|ConvertFrom-Json;$out=@{Kind=$credential.Kind};foreach($name in @('Password','PrivateKeyPem','Passphrase')){if($credential.PSObject.Properties[$name]){$out[$name]=ConvertTo-SecureString $credential.$name -AsPlainText -Force}};return $out}catch{Stop-TCDeploy CredentialUnavailable '无法解密该凭据；请重新认证。'}finally{if($plain){[Array]::Clear($plain,0,$plain.Length)}}
}
Export-ModuleMember -Function Start-TCDeploySession,Set-TCDeployCredential,Get-TCDeploySession,Invoke-TCDeployOperation,Stop-TCDeploySession,Save-TCDeployCredential,Get-TCDeploySavedCredential
