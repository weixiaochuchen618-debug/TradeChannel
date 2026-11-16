#requires -Version 5.1
<#
ConnectionMethods.json is the shared UI/Linux/client capability declaration.
Import is read-only. Dispatch accepts registered IDs and operations only; no
command name, module path, script, or executable is accepted from request JSON.
Deploy uses the existing authenticated DeploymentTransport session and its
approval/operation context. Probe uses CandidateProbe with an explicit Root.
Neither operation creates approval or activates/switches a connection.
#>
Set-StrictMode -Version 2.0
$script:CMRegistry = $null
$script:CMAllowedHandlers = @{
    ValidateTransport = @('direct-transport-v1','reality-transport-v1')
    ConfigureClient = @('wireguard-direct-v1','wireguard-reality-v1')
    DeploymentRequest = @('linux-backend-v1')
    Deploy = @('linux-backend-v1')
    Probe = @('candidate-profile-v1')
}
$script:CMLinuxHandlers = @{
    ValidatePlan = @('direct-plan-v1','reality-plan-v1')
    ConfigureServer = @('wireguard-direct-v1','wireguard-reality-v1')
    PublicParameters = @('direct-parameters-v1','reality-parameters-v1')
}
$script:CMActions = @{Inspect='inspect';Plan='plan';Apply='apply';Probe='status';AddPlan='transport_plan';AddApply='transport_apply';Parameters='transport_info';Options='transport_options'}

function Stop-CM { param([string]$Code,[string]$Message) throw [InvalidOperationException]::new('[TC:'+$Code+'] '+$Message) }
function CMField {
    param($Value,[string]$Name,$Default=$null)
    if($Value -is [Collections.IDictionary]){if($Value.Contains($Name)){return $Value[$Name]}}
    elseif($null -ne $Value -and $Value.PSObject.Properties[$Name]){return $Value.$Name}
    return $Default
}
function CMKeys {
    param($Value)
    if($Value -is [Collections.IDictionary]){return @($Value.Keys)}
    if($Value -is [pscustomobject]){return @($Value.PSObject.Properties.Name)}
    Stop-CM InvalidConnectionParameters '连接方式参数必须是对象。'
}
function CMFields {
    param($Value,[string[]]$Required=@(),[string[]]$Optional=@())
    $keys=@(CMKeys $Value)
    foreach($name in $Required){if($keys -cnotcontains $name){Stop-CM InvalidConnectionParameters ('连接方式参数缺少 '+$name+'。')}}
    foreach($name in $keys){if(($Required+$Optional) -cnotcontains $name){Stop-CM InvalidConnectionParameters ('连接方式不接受参数 '+$name+'。')}}
}
function CMClone {param($Value) if($null -eq $Value){return $null};ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $Value -Depth 60 -Compress)}
function Copy-CMConfigurationValue {
    param($Value,[int]$Depth=0)
    if($Depth -gt 60){Stop-CM InvalidConfiguration '配置层级超过支持范围。'}
    if($null -eq $Value){return $null}
    # Pipeline and parameter binding wrap values in PSObject. A wrapped string or
    # number also satisfies -is [pscustomobject], and `.PSObject.BaseObject` on a
    # wrapped array enumerates its elements, so classify by type in a fixed order
    # (containers first, then scalars) before treating anything as a custom object.
    if($Value -is [Collections.IDictionary]){
        $copy=if($Value -is [Collections.Specialized.OrderedDictionary]){[ordered]@{}}else{@{}}
        foreach($key in $Value.Keys){$copy[$key]=Copy-CMConfigurationValue $Value[$key] ($Depth+1)}
        return $copy
    }
    if($Value -is [array]){
        $items=[Array]::CreateInstance([object],$Value.Length)
        for($i=0;$i -lt $Value.Length;$i++){$items[$i]=Copy-CMConfigurationValue $Value[$i] ($Depth+1)}
        return ,$items
    }
    if($Value -is [string]){return [string]$Value}
    if($Value -is [ValueType]){return $Value}
    if($Value -is [pscustomobject]){
        $properties=[ordered]@{}
        foreach($property in $Value.PSObject.Properties){$properties[$property.Name]=Copy-CMConfigurationValue $property.Value ($Depth+1)}
        return [pscustomobject]$properties
    }
    return $Value
}
function Set-CMField {
    param($Value,[string]$Name,$Item)
    if($Value -is [Collections.IDictionary]){$Value[$Name]=$Item}else{$Value|Add-Member NoteProperty $Name $Item -Force}
}
function Remove-CMField {
    param($Value,[string]$Name)
    if($Value -is [Collections.IDictionary]){$null=$Value.Remove($Name)}else{$Value.PSObject.Properties.Remove($Name)}
}

function Assert-CMRegistry {
    param($Value)
    if((CMField $Value Kind '') -cne 'TradeChannel.ConnectionMethods' -or (CMField $Value SchemaVersion 0) -ne 1 -or (CMField $Value ContractVersion 0) -ne 1){Stop-CM ConnectionRegistryInvalid '连接方式能力声明版本无效。'}
    $architectures=@(CMField $Value Architectures @());$archIds=@();$aliases=@()
    foreach($arch in $architectures){
        $id=[string](CMField $arch Id '');$expected=if($id -ceq 'amd64'){62}elseif($id -ceq 'arm64'){183}else{0}
        $approved=if($id -ceq 'amd64'){@('amd64','x86_64')}else{@('arm64','aarch64')}
        if(-not $expected -or $archIds -ccontains $id -or (CMField $arch ElfMachine 0) -ne $expected){Stop-CM ConnectionRegistryInvalid '服务器架构声明无效。'}
        $archIds+=@($id)
        foreach($alias in @(CMField $arch Aliases @())){if($approved -cnotcontains $alias -or $aliases -ccontains $alias){Stop-CM ConnectionRegistryInvalid '服务器架构别名无效。'};$aliases+=@($alias)}
    }
    if(($archIds|Sort-Object)-join ',' -cne 'amd64,arm64' -or ($aliases|Sort-Object)-join ',' -cne 'aarch64,amd64,arm64,x86_64'){Stop-CM ConnectionRegistryInvalid '服务器架构声明不完整。'}
    $targets=@(CMField $Value LinuxTargets @()|ForEach-Object {([string](CMField $_ Id ''))+':'+([string](CMField $_ Version ''))})
    if(($targets -join ',') -cne 'ubuntu:24.04,debian:13'){Stop-CM ConnectionRegistryInvalid 'Linux 目标系统声明无效。'}
    $ids=@();$types=@()
    foreach($method in @(CMField $Value Methods @())){
        $id=[string](CMField $method Id '');$type=[string](CMField $method TransportType '');$reality=$type -ceq 'tcp-reality'
        if($id -cnotmatch '^[A-Z][A-Za-z0-9]{0,31}$' -or $id -ceq 'Auto' -or $ids -ccontains $id -or $types -ccontains $type -or $type -cnotin @('udp-direct','tcp-reality')){Stop-CM ConnectionRegistryInvalid '连接方式标识重复或无效。'}
        $ids+=@($id);$types+=@($type)
        $requires=CMField $method RequiresTransport
        if($requires -isnot [bool] -or $requires -ne $reality -or (CMField $method NetworkProtocol '') -cne $(if($reality){'Tcp'}else{'Udp'}) -or (@(CMField $method ServerPlatforms @()) -join ',') -cne 'linux' -or (@(CMField $method ServerArchitectures @()) -join ',') -cne 'amd64,arm64' -or -not (CMField $method DisplayName '') -or -not (CMField $method TechnicalName '') -or (CMField $method PreferenceOrder) -isnot [int]){Stop-CM ConnectionRegistryInvalid '连接方式能力声明不一致。'}
        foreach($section in @('Handlers','LinuxHandlers')){
            $handlers=CMField $method $section;$allowed=if($section -ceq 'Handlers'){$script:CMAllowedHandlers}else{$script:CMLinuxHandlers}
            if(@(CMKeys $handlers).Count -ne $allowed.Count){Stop-CM ConnectionRegistryInvalid '连接方式处理器声明不完整。'}
            foreach($operation in $allowed.Keys){if($allowed[$operation] -cnotcontains (CMField $handlers $operation '')){Stop-CM ConnectionHandlerRejected '连接方式引用了未允许的处理器。'}}
        }
        $h=$method.Handlers;$l=$method.LinuxHandlers
        if($h.ValidateTransport -cne $(if($reality){'reality-transport-v1'}else{'direct-transport-v1'}) -or $h.ConfigureClient -cne $(if($reality){'wireguard-reality-v1'}else{'wireguard-direct-v1'}) -or $l.ConfigureServer -cne $h.ConfigureClient -or $l.ValidatePlan -cne $(if($reality){'reality-plan-v1'}else{'direct-plan-v1'}) -or $l.PublicParameters -cne $(if($reality){'reality-parameters-v1'}else{'direct-parameters-v1'})){Stop-CM ConnectionHandlerRejected '连接方式处理器与传输类型不一致。'}
        $probe=CMField $method Probe
        if((CMField $probe ProfileId '') -cne $id -or (CMField $probe Handler '') -cne 'candidate-profile-v1' -or (CMField $probe Transport '') -cne $(if($reality){'WireGuardOverVlessReality'}else{'WireGuardUdp'}) -or (CMField $probe ChangesActiveConnection) -ne $false -or (CMField $probe RequiresBoundPathEvidence) -ne $true){Stop-CM ConnectionRegistryInvalid '连接方式探测声明不一致。'}
        $phases=CMField $method Deployment;$expected=if($reality){@($script:CMActions.Keys)}else{@('Inspect','Plan','Apply','Probe')}
        if(@(CMKeys $phases).Count -ne $expected.Count){Stop-CM ConnectionRegistryInvalid '连接方式部署声明不完整。'}
        foreach($phase in @(CMKeys $phases)){
            $contract=CMField $phases $phase;$required=@(CMField $contract Required @());$optional=@(CMField $contract Optional @());$keys=$required+$optional
            if($expected -cnotcontains $phase -or (CMField $contract Action '') -cne $script:CMActions[$phase] -or (CMField $contract Mutates) -ne ($phase -cin @('Plan','Apply','AddPlan','AddApply')) -or @($keys|Select-Object -Unique).Count -ne $keys.Count){Stop-CM ConnectionHandlerRejected '连接方式部署动作不在允许范围内。'}
        }
    }
    if(($ids|Sort-Object)-join ',' -cne 'Tcp,Udp' -or ($types|Sort-Object)-join ',' -cne 'tcp-reality,udp-direct'){Stop-CM ConnectionRegistryInvalid '现有连接方式声明缺失。'}
}

function Get-CMRegistry {
    if($null -eq $script:CMRegistry){
        $path=Join-Path $PSScriptRoot 'ConnectionMethods.json'
        if(-not [IO.File]::Exists($path) -or (Get-Item -LiteralPath $path).Length -gt 65536){Stop-CM ConnectionRegistryMissing '缺少连接方式能力声明，请使用完整产品包。'}
        $value=ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($path,[Text.Encoding]::UTF8))
        Assert-CMRegistry $value
        $script:CMRegistry=$value
    }
    return $script:CMRegistry
}

function Get-TCConnectionMethods {
    [CmdletBinding()]param()
    foreach($method in @((Get-CMRegistry).Methods|Sort-Object PreferenceOrder,Id)){CMClone $method}
}
function Get-TCConnectionMethod {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Id)
    $found=@((Get-CMRegistry).Methods|Where-Object {$_.Id -ceq $Id})
    if($found.Count -ne 1){Stop-CM UnknownConnectionMethod '该连接方式尚未注册。'}
    CMClone $found[0]
}
function Get-TCConnectionMethodIds {
    [CmdletBinding()]param([switch]$IncludeAuto)
    if($IncludeAuto){'Auto'}
    foreach($method in @((Get-CMRegistry).Methods|Sort-Object PreferenceOrder,Id)){$method.Id}
}
function Resolve-TCConnectionMethod {
    [CmdletBinding(DefaultParameterSetName='Transport')]param(
        [Parameter(ParameterSetName='Transport')][AllowNull()]$Transport,
        [Parameter(Mandatory=$true,ParameterSetName='Type')][string]$TransportType)
    if($PSCmdlet.ParameterSetName -eq 'Transport'){$TransportType=if($null -eq $Transport){'udp-direct'}else{[string](CMField $Transport Type 'tcp-reality')}}
    $found=@((Get-CMRegistry).Methods|Where-Object {$_.TransportType -ceq $TransportType})
    if($found.Count -ne 1){Stop-CM UnknownConnectionMethod '该传输类型尚未注册。'}
    CMClone $found[0]
}

function ConvertTo-CMDomain {
    param($Value)
    if($Value -isnot [string] -or $Value.Length -gt 253 -or $Value -cnotmatch '^[a-zA-Z0-9.-]+$'){Stop-CM InvalidTransport '请输入 ASCII 或 punycode 完整域名。'}
    $domain=$Value.ToLowerInvariant().TrimEnd('.')
    if(-not $domain.Contains('.')){Stop-CM InvalidTransport '请输入完整域名。'}
    foreach($label in $domain.Split('.')){if($label.Length -gt 63 -or $label -cnotmatch '^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$'){Stop-CM InvalidTransport '域名格式无效。'}}
    $ip=$null
    if([Net.IPAddress]::TryParse($domain,[ref]$ip) -or $domain -match '^[0-9.]+$'){Stop-CM InvalidTransport '此处需要域名。'}
    return $domain
}
function ConvertTo-CMTransport {
    param($Method,$Value)
    if($Method.Handlers.ValidateTransport -ceq 'direct-transport-v1'){
        if($null -ne $Value){Stop-CM ConnectionMethodMismatch '标准连接不接受兼容连接参数。'}
        return $null
    }
    if($null -eq $Value){Stop-CM InvalidTransport '兼容连接需要服务器提供的连接参数。'}
    CMFields $Value @('Server','Port','Uuid','ServerName','RealityPublicKey') @('Type','RealityShortId')
    if((CMField $Value Type 'tcp-reality') -cne $Method.TransportType){Stop-CM ConnectionMethodMismatch '连接参数与所选方式不一致。'}
    $server=[string](CMField $Value Server '');$ip=$null
    if([Net.IPAddress]::TryParse($server,[ref]$ip)){$server=$ip.ToString()}else{$server=ConvertTo-CMDomain $server}
    $port=0;$portText=[string](CMField $Value Port '')
    if($portText -cnotmatch '^\d{1,5}$' -or -not [int]::TryParse($portText,[ref]$port) -or $port -lt 1 -or $port -gt 65535){Stop-CM InvalidTransport '端口必须是 1–65535 的整数。'}
    $id=[guid]::Empty
    if(-not [guid]::TryParseExact([string](CMField $Value Uuid ''),'D',[ref]$id) -or $id -eq [guid]::Empty){Stop-CM InvalidTransport 'TCP 用户 UUID 无效。'}
    $public=[string](CMField $Value RealityPublicKey '')
    if($public -cnotmatch '^[A-Za-z0-9_-]{43}$'){Stop-CM InvalidTransport 'Reality 公钥必须为 43 位 base64url。'}
    try{$bytes=[Convert]::FromBase64String($public.Replace('-','+').Replace('_','/')+'=');if($bytes.Length -ne 32){throw 'Invalid key'}}catch{Stop-CM InvalidTransport 'Reality 公钥格式无效。'}
    $short=[string](CMField $Value RealityShortId '')
    if($short -cnotmatch '^(?:[0-9a-fA-F]{2}){0,8}$'){Stop-CM InvalidTransport 'Reality ShortId 必须是最多 16 位的偶数长度十六进制。'}
    $name=[string](CMField $Value ServerName '')
    if($name -cne 'localhost'){$name=ConvertTo-CMDomain $name}
    # NodeOperations and the existing bundle/line callers require IDictionary,
    # including Contains(), index access and deterministic JSON field ordering.
    [ordered]@{Type=$Method.TransportType;Server=$server;Port=$port;Uuid=$id.ToString('D');ServerName=$name;RealityPublicKey=$public;RealityShortId=$short.ToLowerInvariant()}
}

function Assert-CMConfigurationLinks {
    param($Config)
    $entries=@(CMField $Config endpoints @())+@(CMField $Config outbounds @());$tags=@{};$references=New-Object 'Collections.Generic.List[string]'
    foreach($entry in $entries){
        $tag=[string](CMField $entry tag '')
        if(-not $tag -or $tags.ContainsKey($tag)){Stop-CM InvalidConfiguration '配置包含空标签或重复出站标签。'}
        $tags[$tag]=$true
        foreach($field in @('detour','default')){$reference=[string](CMField $entry $field '');if($reference){$references.Add($reference)}}
        foreach($reference in @(CMField $entry outbounds @())){if($reference -is [string]){$references.Add($reference)}}
    }
    $route=CMField $Config route;$final=[string](CMField $route final '');if($final){$references.Add($final)}
    $walk={param($rule) $target=[string](CMField $rule outbound '');if($target){$references.Add($target)};foreach($child in @(CMField $rule rules @())){& $walk $child}}
    foreach($rule in @(CMField $route rules @())){& $walk $rule}
    foreach($server in @(CMField (CMField $Config dns) servers @())){$reference=[string](CMField $server detour '');if($reference){$references.Add($reference)}}
    foreach($reference in $references){if(-not $tags.ContainsKey($reference)){Stop-CM InvalidConfiguration '连接方式生成后存在未定义的出站引用。'}}
}
function New-CMConfiguration {
    param($Method,$Config,$Transport)
    $normalized=ConvertTo-CMTransport $Method $Transport
    $copy=Copy-CMConfigurationValue $Config
    $endpoints=@(CMField $copy endpoints @()|Where-Object {(CMField $_ type '') -ceq 'wireguard'})
    if(-not $endpoints.Count){Stop-CM InvalidConfiguration '配置缺少 WireGuard endpoint。'}
    $old=@(CMField $copy outbounds @()|Where-Object {(CMField $_ tag '') -ceq 'tc-transport'})
    if($old.Count -gt 1 -or ($old.Count -eq 1 -and (CMField $old[0] type '') -cne 'vless')){Stop-CM InvalidConfiguration '传输标签已被其他出站使用。'}
    foreach($endpoint in $endpoints){
        $existing=[string](CMField $endpoint detour '')
        if($existing -and $existing -cne 'tc-transport'){Stop-CM InvalidConfiguration '线路含有其他传输依赖，不能自动覆盖。'}
        if($normalized){Set-CMField $endpoint detour 'tc-transport'}
        elseif($existing -ceq 'tc-transport'){Remove-CMField $endpoint detour}
    }
    $outbounds=@(CMField $copy outbounds @()|Where-Object {(CMField $_ tag '') -cne 'tc-transport'})
    if($normalized){
        $transit=[ordered]@{type='vless';tag='tc-transport';server=$normalized.Server;server_port=$normalized.Port;uuid=$normalized.Uuid;domain_resolver=@{server='dns-direct';strategy='prefer_ipv4'};
            tls=[ordered]@{enabled=$true;server_name=$normalized.ServerName;utls=@{enabled=$true;fingerprint='chrome'};reality=@{enabled=$true;public_key=$normalized.RealityPublicKey;short_id=$normalized.RealityShortId}}}
        $outbounds=@($transit)+$outbounds
    }
    Set-CMField $copy outbounds $outbounds
    Assert-CMConfigurationLinks $copy
    return $copy
}

function New-CMDeploymentRequest {
    param($Method,[string]$Phase,$InputObject)
    if(@(CMKeys $Method.Deployment) -cnotcontains $Phase){Stop-CM UnsupportedConnectionOperation '此连接方式不支持该部署阶段。'}
    $contract=CMField $Method.Deployment $Phase
    if($null -eq $contract){Stop-CM UnsupportedConnectionOperation '此连接方式不支持该部署阶段。'}
    CMFields $InputObject @($contract.Required) @($contract.Optional)
    if($Phase -cin @('Plan','AddPlan')){
        $transport=CMField $InputObject Transport
        if($Method.RequiresTransport){
            CMFields $transport @('Type','Port','ServerName')
            $port=CMField $transport Port;$name=CMField $transport ServerName
            if((CMField $transport Type '') -cne $Method.TransportType -or ($port -isnot [int] -and $port -isnot [long]) -or $port -notin @(443,8443,2443) -or $name -isnot [string] -or $name.Length -gt 253 -or $name -cnotmatch '^(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$'){Stop-CM InvalidTransport '服务器兼容连接参数无效。'}
        }elseif($null -ne $transport){Stop-CM ConnectionMethodMismatch '标准连接部署不接受兼容连接参数。'}
    }
    [pscustomobject][ordered]@{Kind='TradeChannel.ConnectionMethodRequest';ContractVersion=1;MethodId=$Method.Id;Phase=$Phase;Operation=$contract.Action;Input=(CMClone $InputObject);Mutates=$contract.Mutates}
}

# Private seams for offline tests; callers cannot select or supply an executor.
$script:CMExecutors = @{
    Deploy = {
        param($Parameters)
        $module=Import-Module (Join-Path $PSScriptRoot 'DeploymentTransport.psm1') -PassThru -DisableNameChecking -ErrorAction Stop
        & $module {param($p) Invoke-TCDeployOperation @p} $Parameters
    }
    Probe = {
        param($Parameters)
        $module=Import-Module (Join-Path $PSScriptRoot 'CandidateProbe.psm1') -PassThru -DisableNameChecking -ErrorAction Stop
        & $module {param($p) Test-TCCandidateProbe @p} $Parameters
    }
}
function Invoke-TCConnectionMethod {
    [CmdletBinding()]param(
        [Parameter(Mandatory=$true)][string]$Id,
        [Parameter(Mandatory=$true)][ValidateSet('ValidateTransport','ConfigureClient','DeploymentRequest','Deploy','Probe')][string]$Operation,
        [hashtable]$Parameters=@{})
    $method=Get-TCConnectionMethod -Id $Id
    $Operation=@($script:CMAllowedHandlers.Keys|Where-Object {$_ -ieq $Operation})[0]
    $handler=[string](CMField $method.Handlers $Operation '')
    if($script:CMAllowedHandlers[$Operation] -cnotcontains $handler){Stop-CM ConnectionHandlerRejected '连接方式处理器未获允许。'}
    switch -CaseSensitive ($handler){
        {$_ -cin @('direct-transport-v1','reality-transport-v1')} {
            CMFields $Parameters @() @('Value')
            return ConvertTo-CMTransport $method (CMField $Parameters Value)
        }
        {$_ -cin @('wireguard-direct-v1','wireguard-reality-v1')} {
            CMFields $Parameters @('Config') @('Transport')
            return New-CMConfiguration $method $Parameters.Config (CMField $Parameters Transport)
        }
        'linux-backend-v1' {
            if($Operation -ceq 'DeploymentRequest'){CMFields $Parameters @('Phase','Input')}
            else{CMFields $Parameters @('Phase','Input','SessionRef') @('OperationId')}
            $request=New-CMDeploymentRequest $method ([string]$Parameters.Phase) $Parameters.Input
            if($Operation -ceq 'DeploymentRequest'){return $request}
            if($null -eq $Parameters.SessionRef){Stop-CM InvalidConnectionParameters '部署需要已有的已认证服务器会话。'}
            $arguments=@{SessionRef=$Parameters.SessionRef;Operation=$request.Operation;OperationInput=$request.Input;OperationId=[string](CMField $Parameters OperationId '')}
            return & $script:CMExecutors.Deploy $arguments
        }
        'candidate-profile-v1' {
            CMFields $Parameters @('Root','NodeId') @('ExpectedExitIPv4','ExpectedExitSource','TimeoutSeconds','CancellationPath','FixedRequestBudget','ProbeBinding')
            if(-not ($Parameters.Root -is [string]) -or [string]::IsNullOrWhiteSpace($Parameters.Root) -or -not ($Parameters.NodeId -is [string]) -or [string]::IsNullOrWhiteSpace($Parameters.NodeId)){Stop-CM InvalidConnectionParameters '测试线路需要明确的本机数据目录和线路标识。'}
            $arguments=@{};foreach($key in $Parameters.Keys){$arguments[$key]=$Parameters[$key]}
            $arguments.ProfileId=$method.Probe.ProfileId
            return & $script:CMExecutors.Probe $arguments
        }
        default {Stop-CM ConnectionHandlerRejected '连接方式处理器未实现。'}
    }
}

function Get-TCConnectionMethodPythonSource {
    [CmdletBinding()]param()
    $declaration=ConvertTo-Json -InputObject (Get-CMRegistry) -Depth 30 -Compress
    $path=Join-Path $PSScriptRoot 'linux\connection_methods.py'
    if(-not [IO.File]::Exists($path) -or (Get-Item -LiteralPath $path).Length -gt 131072){Stop-CM ConnectionRegistryMissing '缺少 Linux 连接方式能力组件。'}
    $source=[IO.File]::ReadAllText($path,[Text.Encoding]::UTF8)
    $data=ConvertTo-Json -InputObject $declaration -Compress
    return ('_DECLARATION_JSON = '+$data+"`n"+$source)
}
function Get-TCConnectionMethodBootstrap {
    [CmdletBinding()]param()
    $literal=ConvertTo-Json -InputObject (Get-TCConnectionMethodPythonSource) -Compress
    return ('import sys,types; _cm=types.ModuleType("connection_methods"); _cm.__file__="connection_methods.py"; sys.modules["connection_methods"]=_cm; exec(compile('+$literal+',"connection_methods.py","exec"),_cm.__dict__)'+"`n")
}

Export-ModuleMember -Function Get-TCConnectionMethods,Get-TCConnectionMethod,Get-TCConnectionMethodIds,Resolve-TCConnectionMethod,Invoke-TCConnectionMethod,Get-TCConnectionMethodBootstrap,Get-TCConnectionMethodPythonSource
