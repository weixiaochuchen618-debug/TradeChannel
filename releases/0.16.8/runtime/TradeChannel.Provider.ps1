#requires -Version 5.1
# Read-only provider health checks shared by the supervisor, the daily exit
# command and the console. Nothing here changes routes, proxies or selectors.
# Provider identity (which client, which port, which folders) comes from the
# profile module; this file only answers "is that provider usable right now".
if (-not (Get-Command Get-TCManifestProviders -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'TradeChannel.Providers.ps1') }
# Native listener ownership is compiled into the protected package.
function Initialize-TCNetTable {
    if('TCNetTable' -as [type]){return}
    . (Join-Path $PSScriptRoot 'TradeChannel.Components.ps1')
    Initialize-TCRuntimeComponent -Name TCDevicePath
}
function Get-TCListenerOwnerIds {
    param([int]$Port)
    Initialize-TCNetTable
    @([TCNetTable]::ListenerOwners($Port))
}
function Get-TCProcessImagePath {
    param([int]$Id)
    if('TCNetTable' -as [type]){return [TCNetTable]::ImagePath($Id)}
    try{(Get-Process -Id $Id -ErrorAction Stop).Path}catch{$null}
}

# The provider's install directory. Derived only when it is the folder of one of
# the provider programs, so a shared parent such as ...\Programs is never trusted.
function Get-TCProviderDirectory {
    param($Manifest)
    if(-not $Manifest){return $null}
    if($Manifest.PSObject.Properties['ProviderDirectory'] -and $Manifest.ProviderDirectory){return ([IO.Path]::GetFullPath([string]$Manifest.ProviderDirectory)).TrimEnd('\')}
    $paths=@($Manifest.ProviderProgramPaths|Where-Object {$_})
    if(-not $paths.Count){return $null}
    $dirs=@(foreach($path in $paths){[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath([string]$path))})
    $common=$dirs[0]
    foreach($dir in $dirs){
        while($common -and -not ($dir.Equals($common,[StringComparison]::OrdinalIgnoreCase) -or $dir.StartsWith($common+'\',[StringComparison]::OrdinalIgnoreCase))){$common=[IO.Path]::GetDirectoryName($common)}
    }
    if(-not $common -or @($common.TrimEnd('\').Split('\')).Count -lt 3){return $null}
    if(-not @($dirs|Where-Object {$_.Equals($common,[StringComparison]::OrdinalIgnoreCase)}).Count){return $null}
    return $common.TrimEnd('\')
}

function Test-TCPathWithin {
    param([string]$Path,[string]$Directory)
    Test-TCProviderPathWithin $Path $Directory
}
function Get-TCProviderListenerAddresses {
    param([int]$Port)
    @([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() | Where-Object {$_.Port -eq $Port} | ForEach-Object {$_.Address.ToString()} | Select-Object -Unique)
}

# Another virtual adapter (BatVPN's own TUN mode, an old WireGuard tunnel) would
# compete with TradeChannel for the default route.
function Get-TCForeignTunnel {
    $adapters=@([Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()|Where-Object {$_.OperationalStatus -eq 'Up' -and $_.Name -ne 'TradeChannel'})
    foreach($adapter in $adapters){
        if($adapter.Name -like 'BatVPN*' -or [string]$adapter.Description -match 'Wintun|WireGuard|sing-tun|TAP-Windows'){return [string]$adapter.Name}
    }
    return $null
}

# -Provider addresses one specific registered client. Without it the manifest's
# first provider is used, which is what pre-profile configurations had.
function Get-TCProviderHealth {
    param($Manifest,$Provider,[AllowNull()][AllowEmptyString()][string]$ProviderId,[switch]$SkipTunnelCheck,[switch]$ForTrade)
    $target=$Provider
    if(-not $target -and $Manifest){$target=Resolve-TCProviderTarget $Manifest $ProviderId -ForTrade:$ForTrade}
    elseif($ProviderId -and (Get-TCProviderValue $target 'Id') -ne $ProviderId){throw '服务商 ID 与检查对象不一致。'}
    if($ProviderId -and -not $target){throw '未知服务商 ID。'}
    $port=Get-TCProviderValue $target 'Port';$tag=Get-TCProviderValue $target 'Tag'
    if($target -and $ForTrade){$trade=Get-TCProviderValue $target 'TradePort';if($trade){$port=$trade};$tradeTag=Get-TCProviderValue $target 'TradeTag';if($tradeTag){$tag=$tradeTag}}
    $directories=@(Get-TCProviderValue $target 'Directories' @());if(-not $directories.Count){$directory=Get-TCProviderValue $target 'Directory';if($directory){$directories=@($directory)}}
    $programs=@(Get-TCProviderValue $target 'Programs' @())
    if(-not $directories.Count -and $Manifest){$legacy=Get-TCProviderDirectory $Manifest;if($legacy){$directories=@($legacy)}}
    $result=[ordered]@{Configured=[bool]($port -and $directories.Count);Port=$port;Name=(Get-TCProviderValue $target 'Name');Tag=$tag;Id=(Get-TCProviderValue $target 'Id')
        Listening=$false;OwnerPath=$null;OwnerPaths=@();OwnerIds=@();IdentityVerified=$false;LoopbackReachable=$false;ForeignTunnel=$null;Healthy=$false;TradingEgressVerified=$false;Reason='NotConfigured'}
    if(-not $result.Configured){return [pscustomobject]$result}
    try{$port=ConvertTo-TCProviderPort $port -Required}catch{$result.Reason='PortConflict';return [pscustomobject]$result}
    $reserved=@(17890,17891,(Get-TCProviderValue $Manifest 'ControlPort'),(Get-TCProviderValue $Manifest 'ProbePort'))
    if($port -in $reserved){$result.Reason='LoopbackRisk';return [pscustomobject]$result}
    try{
        foreach($directory in $directories){$null=Get-TCProviderSafeDirectory $directory}
        $owners=@(Get-TCListenerOwnerIds $port);$result.OwnerIds=$owners;$result.Listening=$owners.Count -gt 0
        if(-not $result.Listening){$result.Reason='NotListening';return [pscustomobject]$result}
        $paths=New-Object 'Collections.Generic.List[string]';$known=$true
        foreach($owner in $owners){
            $path=Get-TCProcessImagePath ([int]$owner)
            if(-not $path){$known=$false;continue}
            $full=[IO.Path]::GetFullPath($path);$paths.Add($full);Assert-TCProviderNoReparse $full
            $engine=Get-TCProviderValue $Manifest 'EnginePath'
            if(($engine -and $full -eq [IO.Path]::GetFullPath([string]$engine)) -or [IO.Path]::GetFileName($full) -eq 'TradeChannel.exe' -or $full -match '(?i)\\TradeChannel\\bin\\'){$result.Reason='LoopbackRisk';return [pscustomobject]$result}
            if(-not @($directories|Where-Object {Test-TCProviderPathWithin $full $_}).Count){$known=$false}
            if($programs.Count -and -not @($programs|Where-Object {[IO.Path]::GetFullPath([string]$_) -eq $full}).Count){$known=$false}
        }
        $result.OwnerPaths=$paths.ToArray();if($paths.Count){$result.OwnerPath=$paths[0]}
        $result.IdentityVerified=($known -and $paths.Count -eq $owners.Count)
        if(-not $result.IdentityVerified){$result.Reason='UnknownOwner';return [pscustomobject]$result}
        $addresses=@(Get-TCProviderListenerAddresses $port)
        $result.LoopbackReachable=(@($addresses|Where-Object {$_ -in @('127.0.0.1','0.0.0.0')}).Count -gt 0)
        if(-not $result.LoopbackReachable){$result.Reason='LoopbackUnavailable';return [pscustomobject]$result}
        if(-not $SkipTunnelCheck){$result.ForeignTunnel=Get-TCForeignTunnel;if($result.ForeignTunnel){$result.Reason='ForeignTunnel';return [pscustomobject]$result}}
    }catch{$result.Reason='InspectionFailed';return [pscustomobject]$result}
    $result.Healthy=$true;$result.Reason=$null;[pscustomobject]$result
}

# Proves forwarding through the provider's local SOCKS port (no credentials or
# node keys are read). Started detached so a caller loop never blocks on it.
function Start-TCProviderPreflight {
    param([int]$Port,[string]$OutFile,[int]$TimeoutSeconds=8)
    $curl=Join-Path $env:WINDIR 'System32\curl.exe'
    if(-not (Test-Path -LiteralPath $curl)){return $null}
    if(Test-Path -LiteralPath $OutFile){Remove-Item -LiteralPath $OutFile -Force}
    $si=New-Object Diagnostics.ProcessStartInfo
    $si.FileName=$curl
    $si.Arguments='--proxy socks5h://127.0.0.1:'+$Port+' --noproxy .invalid --silent --connect-timeout 4 --max-time '+$TimeoutSeconds+' --output "'+$OutFile+'" https://1.1.1.1/cdn-cgi/trace'
    $si.UseShellExecute=$false;$si.CreateNoWindow=$true
    [Diagnostics.Process]::Start($si)
}
function Read-TCProviderPreflight {
    param($Process,[string]$OutFile)
    $ip=$null
    try{if($Process.ExitCode -eq 0 -and (Test-Path -LiteralPath $OutFile)){$text=[IO.File]::ReadAllText($OutFile);if($text -match '(?m)^ip=([^\r\n]+)'){$ip=$matches[1].Trim()}}}
    finally{$Process.Dispose();if(Test-Path -LiteralPath $OutFile){Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue}}
    [pscustomobject]@{Ok=[bool]$ip;IP=$ip;TradingEgressVerified=$false}
}
function Test-TCProviderForwarding {
    param([int]$Port,[int]$TimeoutSeconds=8)
    $out=Join-Path ([IO.Path]::GetTempPath()) ('tc-preflight-'+[Guid]::NewGuid().ToString('N')+'.txt')
    $process=Start-TCProviderPreflight -Port $Port -OutFile $out -TimeoutSeconds $TimeoutSeconds
    if(-not $process){return [pscustomobject]@{Ok=$false;IP=$null;TradingEgressVerified=$false}}
    if(-not $process.WaitForExit(($TimeoutSeconds+3)*1000)){try{$process.Kill()}catch{};$process.Dispose();return [pscustomobject]@{Ok=$false;IP=$null;TradingEgressVerified=$false}}
    Read-TCProviderPreflight $process $out
}
function Get-TCProviderReasonText {
    param([string]$Reason,[string]$Name)
    $who=if($Name){$Name}else{'服务商'}
    switch($Reason){
        'NotConfigured'{'线路配置中还没有服务商'}
        'NotListening'{$who+' 未运行'}
        'UnknownOwner'{'代理端口被其他程序占用或无法确认所有者'}
        'PortConflict'{'端口无效或与 TradeChannel 自身端口冲突'}
        'LoopbackRisk'{'该端口指向 TradeChannel 自身，可能形成回环'}
        'LoopbackUnavailable'{'端口没有监听本机 IPv4 回环地址'}
        'InspectionFailed'{'无法可靠检查端口归属或网络状态'}
        'ForeignTunnel'{'检测到其他虚拟网卡（例如服务商的 VPN／TUN 模式）'}
        'ForwardingFailed'{$who+' 已运行，但暂时无法转发'}
        'Unsupported'{'当前线路配置需要更新'}
        default{''}
    }
}

# Read-only trading gate. No successful HTTP request alone proves a remote exit.
# Controller access is authenticated, literal loopback, no redirects/system proxy.
function Invoke-TCProviderControllerRead {
    param([string]$Endpoint,[string]$Secret,[ValidateSet('/configs','/proxies','/connections')][string]$Path)
    if($Endpoint -notmatch '^(127\.0\.0\.1|\[::1\]):([0-9]{1,5})$' -or -not $Secret -or $Secret -match '[\r\n]'){throw '缺少经过认证的回环控制接口。'}
    $null=ConvertTo-TCProviderPort $matches[2] -Required
    Add-Type -AssemblyName System.Net.Http
    $handler=New-Object Net.Http.HttpClientHandler;$handler.UseProxy=$false;$handler.AllowAutoRedirect=$false
    $client=New-Object Net.Http.HttpClient($handler);$client.Timeout=[TimeSpan]::FromSeconds(4);$client.MaxResponseContentBufferSize=4194304
    try{
        $client.DefaultRequestHeaders.Authorization=New-Object Net.Http.Headers.AuthenticationHeaderValue('Bearer',$Secret)
        $response=$client.GetAsync(('http://'+$Endpoint+$Path)).GetAwaiter().GetResult()
        try{if(-not $response.IsSuccessStatusCode){throw '控制接口拒绝读取。'};$body=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult();if($body.Length -gt 4194304){throw '控制接口响应过大。'};ConvertFrom-Json -InputObject $body}finally{$response.Dispose()}
    }finally{$client.Dispose();$handler.Dispose()}
}
function Test-TCProviderProcessConfig {
    param([int]$OwnerId,[string]$ConfigPath)
    # A generated file is not necessarily loaded. Prove the process was started
    # with this exact file after its last write. Otherwise require live evidence.
    try{
        $process=Get-Process -Id $OwnerId -ErrorAction Stop
        if((Get-Item -LiteralPath $ConfigPath).LastWriteTimeUtc -gt $process.StartTime.ToUniversalTime()){return $false}
        $info=Get-CimInstance Win32_Process -Filter ('ProcessId = '+$OwnerId) -ErrorAction Stop
        $command=[string]$info.CommandLine
        if($command -match '(?i)(?:^|\s)(?:-config|--config)\s+[^"\s]+' -and $command -notmatch '(?i)\.json(?:\s|$|\x22)'){return $false}
        $args=[regex]::Matches($command,'(?i)(?:^|\s)(?:-f|--config|-config|-c)(?:\s+|=)(?:"([^"]+)"|([^\s]+))')
        if($args.Count -ne 1){return $false}
        $selected=if($args[0].Groups[1].Success){$args[0].Groups[1].Value}else{$args[0].Groups[2].Value}
        return $selected -match '^[A-Za-z]:[\\/]' -and [IO.Path]::GetFullPath($selected) -eq [IO.Path]::GetFullPath($ConfigPath)
    }catch{$false}
}
function Test-TCProviderRemoteServer {
    param([string]$Server)
    if(-not $Server -or $Server -in @('localhost','localhost.localdomain','0.0.0.0','::') -or $Server -match '(?i)\.(localhost|local)$'){return $false}
    $ip=$null;if([Net.IPAddress]::TryParse($Server,[ref]$ip)){return -not [Net.IPAddress]::IsLoopback($ip)}
    try{$null=ConvertTo-TCProviderDomains @($Server);$true}catch{$false}
}
function Test-TCClashProxyChain {
    param($Proxies,[string]$Name,[string[]]$Ancestors=@())
    if(-not $Name -or $Name -in @('DIRECT','REJECT','REJECT-DROP','PASS','COMPATIBLE','GLOBAL') -or $Name -cin $Ancestors -or $Ancestors.Count -ge 24){return [pscustomobject]@{Verified=$false;Reason='UnsafeOrCyclicChain';Chain=@()}}
    # Proxy names are case-sensitive in mihomo. Do not let PowerShell collapse them.
    $node=$null
    if($Proxies -is [Collections.IDictionary]){foreach($key in $Proxies.Keys){if([string]$key -ceq $Name){$node=$Proxies[$key];break}}}
    elseif($Proxies){foreach($property in $Proxies.PSObject.Properties){if($property.Name -ceq $Name){$node=$property.Value;break}}}
    if(-not $node){return [pscustomobject]@{Verified=$false;Reason='UnknownChainNode';Chain=@()}}
    $type=[string](Get-TCProviderValue $node 'type');$now=[string](Get-TCProviderValue $node 'now')
    if($type -in @('Direct','Reject','RejectDrop','Pass','Compatible','DNS') -or (Get-TCProviderValue $node 'alive' $true) -eq $false){return [pscustomobject]@{Verified=$false;Reason='DirectOrUnavailable';Chain=@($Name)}}
    $next=@();$all=@(Get-TCProviderValue $node 'all' @())
    switch($type){
        'Selector' {if(-not $now -or $now -cnotin $all){return [pscustomobject]@{Verified=$false;Reason='UnknownSelection';Chain=@($Name)}};$next=@($now)}
        {$_ -in @('Fallback','URLTest','LoadBalance','Relay')} {
            # Automatic switching/load balancing must have no unsafe possible leaf.
            if(-not $all.Count){return [pscustomobject]@{Verified=$false;Reason='UnknownAutomaticGroup';Chain=@($Name)}}
            $next=$all
        }
        {$_ -in @('Shadowsocks','ShadowsocksR','Snell','Socks5','Http','Vmess','Vless','Trojan','Hysteria','Hysteria2','Tuic','WireGuard','SSH','AnyTLS','Mieru')} {
            if($all.Count -or $now){return [pscustomobject]@{Verified=$false;Reason='AmbiguousLeaf';Chain=@($Name)}}
        }
        default {return [pscustomobject]@{Verified=$false;Reason='UnknownProxyType';Chain=@($Name)}}
    }
    $chain=@($Name)
    foreach($child in $next){$proof=Test-TCClashProxyChain $Proxies ([string]$child) (@($Ancestors)+@($Name));if(-not $proof.Verified){return $proof};$chain+=@($proof.Chain)}
    [pscustomobject]@{Verified=$true;Reason=$null;Chain=@($chain|Select-Object -Unique)}
}
# V2Fly routing: ip items OR together; other fields are AND conditions.
# https://www.v2fly.org/en_US/config/routing.html
function Test-TCPrivateDestinationRule {
    param($Rule)
    if((Get-TCProviderValue $Rule 'type' 'field') -ne 'field' -or (Get-TCProviderValue $Rule 'balancerTag') -or @(Get-TCProviderValue $Rule 'domain' @()).Count -or @(Get-TCProviderValue $Rule 'domains' @()).Count){return $false}
    $ranges=@(Get-TCProviderValue $Rule 'ip' @());if(-not $ranges.Count){return $false}
    foreach($range in $ranges){
        if([string]$range -ceq 'geoip:private'){continue}
        $parts=@(([string]$range) -split '/');$address=$null
        if($parts.Count -gt 2 -or -not [Net.IPAddress]::TryParse($parts[0],[ref]$address)){return $false}
        $bytes=$address.GetAddressBytes();$prefix=$bytes.Length*8
        if($parts.Count -eq 2){if($parts[1] -notmatch '^\d+$' -or -not [int]::TryParse($parts[1],[ref]$prefix) -or $prefix -lt 0 -or $prefix -gt $bytes.Length*8){return $false}}
        $private=$false
        foreach($allowed in @('10.0.0.0/8','172.16.0.0/12','192.168.0.0/16','127.0.0.0/8','169.254.0.0/16','::1/128','fc00::/7','fe80::/10')){
            $pair=$allowed -split '/';$network=[Net.IPAddress]::Parse($pair[0]);$networkBytes=$network.GetAddressBytes();$bits=[int]$pair[1]
            if($networkBytes.Length -ne $bytes.Length -or $prefix -lt $bits){continue}
            $same=$true
            for($index=0;$bits -gt 0;$index++){$used=[Math]::Min(8,$bits);$mask=(255 -shl (8-$used)) -band 255;if(($bytes[$index] -band $mask) -ne ($networkBytes[$index] -band $mask)){$same=$false;break};$bits-=$used}
            if($same){$private=$true;break}
        }
        if(-not $private){return $false}
    }
    $true
}
function Test-TCProviderTradingPolicy {
    param([Parameter(Mandatory=$true)]$Provider)
    $result=[ordered]@{Allowed=$false;Reason='Unverified';ReasonText='尚未可靠验证该服务商的交易出口，保留当前出口。';TradingEgressVerified=$false;Chain=@();Evidence=$null}
    try{
        $kind=([string](Get-TCProviderValue $Provider 'Kind')).ToLowerInvariant();$port=ConvertTo-TCProviderPort (Get-TCProviderValue $Provider 'Port') -Required
        $settings=[string](Get-TCProviderValue $Provider 'SettingsDirectory')
        if(-not $settings){
            if($kind -eq 'batvpn'){$settings=Join-Path $env:APPDATA 'BatVPN'}
            elseif($kind -in @('clashverge','clash-verge')){$settings=Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev'}
        }
        if($kind -notin @('batvpn','clashverge','clash-verge','clash')){$result.Reason='ManualUnverified';$result.ReasonText='自定义客户端无法自动验证交易路由，本版保留当前出口。';return [pscustomobject]$result}
        $settings=Get-TCProviderSafeDirectory $settings -MustExist
        $configPath=Join-Path $settings $(if($kind -eq 'batvpn'){'config.json'}elseif($kind -eq 'clash'){'config.yaml'}else{'clash-verge.yaml'})
        $text=Read-TCProviderTextFile $configPath;if(-not $text){return [pscustomobject]$result}
        if($kind -eq 'batvpn'){
            $doc=ConvertFrom-Json -InputObject $text;$outbounds=@(Get-TCProviderValue $doc 'outbounds' @());$routing=Get-TCProviderValue $doc 'routing' @{};$rules=@(Get-TCProviderValue $routing 'rules' @());$outboundMap=@{}
            foreach($outbound in $outbounds){$tag=[string](Get-TCProviderValue $outbound 'tag');if(-not $tag -or $outboundMap.ContainsKey($tag)){return [pscustomobject]$result};$outboundMap[$tag]=$outbound}
            if(-not $outbounds.Count -or @(Get-TCProviderValue $routing 'balancers' @()).Count){return [pscustomobject]$result}
            $targets=@([string](Get-TCProviderValue $outbounds[0] 'tag'))
            foreach($rule in $rules){
                $tag=[string](Get-TCProviderValue $rule 'outboundTag');if(-not $tag){return [pscustomobject]$result}
                if($outboundMap.ContainsKey($tag) -and (Get-TCProviderValue $outboundMap[$tag] 'protocol') -eq 'freedom' -and (Test-TCPrivateDestinationRule $rule)){continue}
                $targets+=@($tag)
            }
            foreach($tag in @($targets|Select-Object -Unique)){
                if(-not $outboundMap.ContainsKey($tag)){return [pscustomobject]$result}
                $outbound=$outboundMap[$tag];$protocol=[string](Get-TCProviderValue $outbound 'protocol')
                if($protocol -in @('freedom','blackhole','dns','loopback')){$result.Reason='DirectOrRejectRoute';$result.ReasonText='BatVPN 当前存在公网直连、拒绝或无法证明仅限私网的规则。请使用全局代理，并将直连例外限制为 geoip:private 或明确私网 CIDR 后重新检查。';return [pscustomobject]$result}
                if($protocol -notin @('vmess','vless','trojan','shadowsocks','socks','http') -or (Get-TCProviderValue $outbound 'proxySettings')){return [pscustomobject]$result}
                $config=Get-TCProviderValue $outbound 'settings';$servers=@(Get-TCProviderValue $config 'vnext' @())+@(Get-TCProviderValue $config 'servers' @())
                if(-not $servers.Count){return [pscustomobject]$result};foreach($server in $servers){if(-not (Test-TCProviderRemoteServer ([string](Get-TCProviderValue $server 'address')))){return [pscustomobject]$result}}
            }
            $inbounds=@(@(Get-TCProviderValue $doc 'inbounds' @())|Where-Object {(Get-TCProviderValue $_ 'port') -eq $port -and (Get-TCProviderValue $_ 'protocol') -eq 'socks'})
            if($inbounds.Count -ne 1){return [pscustomobject]$result}
            $health=Get-TCProviderHealth -Provider $Provider
            if(-not $health.Healthy -or $health.OwnerIds.Count -ne 1 -or -not (Test-TCProviderProcessConfig $health.OwnerIds[0] $configPath)){$result.Reason='RuntimeConfigUnproven';$result.ReasonText='BatVPN 文件策略可代理，但尚不能确认当前进程加载的是这份配置，暂不切换。';return [pscustomobject]$result}
            $result.Chain=$targets;$result.Evidence='ProcessConfigAndRouting'
        }else{
            $facts=Get-TCClashRuntimeFacts @($text -split '\r?\n');$listener=$facts.Listener
            if(-not $listener -or $listener.Port -ne $port -or $port -in @($facts.MixedPort,$facts.SocksPort) -or $listener.Type -ne 'socks' -or $listener.Listen -ne '127.0.0.1' -or -not $listener.NoAuth -or -not $listener.Proxy){$result.Reason='DedicatedListenerRequired';$result.ReasonText='尚未加载独立 SOCKS 备用监听器，不能把规则端口当作交易专用出口。';return [pscustomobject]$result}
            $endpoint=[string](Get-TCProviderValue $facts.Document 'external-controller');$pipePath=[string](Get-TCProviderValue $facts.Document 'external-controller-pipe');$secret=[string](Get-TCProviderValue $facts.Document 'secret')
            $pipeValid=$pipePath -match '^\\\\\.\\pipe\\([^\\/\x00-\x1f]{1,200})$'
            $tcpValid=$endpoint -match '^(127\.0\.0\.1|\[::1\]):([0-9]{1,5})$';$controllerPort=$null
            if($tcpValid){$controllerPort=ConvertTo-TCProviderPort $matches[2] -Required}
            if((-not $pipeValid -and -not $tcpValid) -or -not $secret -or $secret -match '[\r\n]'){$result.Reason='AuthenticatedControllerRequired';$result.ReasonText='需要客户端已有的认证本机管道或回环 controller，才能验证实际代理链；本工具不修改其设置。';return [pscustomobject]$result}
            $health=Get-TCProviderHealth -Provider $Provider
            if(-not $health.Healthy -or $health.OwnerIds.Count -ne 1){$result.Reason='UnknownOwner';return [pscustomobject]$result}
            if(-not $pipeValid){
                $pipePath=$null;$owners=@(Get-TCListenerOwnerIds $controllerPort)
                if($owners.Count -ne 1 -or $owners[0] -ne $health.OwnerIds[0]){$result.Reason='ControllerOwnerMismatch';return [pscustomobject]$result}
            }
            $controlArgs=@{Endpoint=$endpoint;PipePath=$pipePath;Secret=$secret;OwnerId=$health.OwnerIds[0]}
            $running=Invoke-TCProviderControlRead @controlArgs -Path '/configs'
            if((Get-TCProviderValue $running 'mode') -ne 'rule' -or (Get-TCProviderValue $running 'mixed-port') -ne $facts.MixedPort -or (Get-TCProviderValue (Get-TCProviderValue $running 'tun') 'enable') -eq $true){$result.Reason='RuntimeConfigMismatch';$result.ReasonText='客户端当前模式、TUN 或日常端口与所检查配置不一致，暂不切换。';return [pscustomobject]$result}
            $response=Invoke-TCProviderControlRead @controlArgs -Path '/proxies';$proxies=Get-TCProviderValue $response 'proxies'
            $proof=Test-TCClashProxyChain $proxies $listener.Proxy
            if(-not $proof.Verified){$result.Reason=$proof.Reason;$result.ReasonText='当前代理链含直连、拒绝、未知节点或不安全自动回退，暂不切换交易。';return [pscustomobject]$result}
            # The API omits listener definitions. Corroborate file/load identity,
            # or an existing live connection carrying this listener's specialProxy.
            $loaded=Test-TCProviderProcessConfig $health.OwnerIds[0] $configPath
            if(-not $loaded){
                $snapshot=Invoke-TCProviderControlRead @controlArgs -Path '/connections'
                foreach($connection in @(Get-TCProviderValue $snapshot 'connections' @())){
                    $meta=Get-TCProviderValue $connection 'metadata';$chain=@(Get-TCProviderValue $connection 'chains' @())
                    if((Get-TCProviderValue $meta 'inboundName') -ceq $script:TCClashListener -and (Get-TCProviderValue $meta 'inboundPort') -eq $port -and (Get-TCProviderValue $meta 'specialProxy') -ceq $listener.Proxy -and (Get-TCProviderValue $meta 'inboundIP') -eq '127.0.0.1' -and $chain.Count){
                        $safe=$true;foreach($name in $chain){if(-not (Test-TCClashProxyChain $proxies ([string]$name)).Verified){$safe=$false}};if($safe){$loaded=$true;break}
                    }
                }
            }
            if(-not $loaded){$result.Reason='RuntimeConfigUnproven';$result.ReasonText='代理链已读取，但无法确认专用监听器已加载；请在维护窗口加载后检查，或提供该端口的实时诊断证据。';return [pscustomobject]$result}
            # Static chained transports may hide another client on localhost.
            foreach($name in $proof.Chain){
                if($name -cin $facts.Groups){continue}
                $definitions=@($facts.Proxies|Where-Object {(Get-TCProviderValue $_ 'name') -ceq $name})
                if($definitions.Count -ne 1 -or -not (Test-TCProviderRemoteServer ([string](Get-TCProviderValue $definitions[0] 'server'))) -or (Get-TCProviderValue $definitions[0] 'dialer-proxy')){return [pscustomobject]$result}
            }
            $result.Chain=$proof.Chain;$result.Evidence='AuthenticatedControllerChainAndListener'
        }
        if((Read-TCProviderTextFile $configPath) -cne $text){$result.Reason='ConfigChanged';return [pscustomobject]$result}
        $result.Allowed=$true;$result.TradingEgressVerified=$true;$result.Reason=$null;$result.ReasonText='已验证当前代理策略不走 DIRECT/REJECT；仍需端口转发检查和交易软件验收。'
    }catch{
        $result.Allowed=$false;$result.TradingEgressVerified=$false;$result.Reason='VerificationUnavailable';$result.ReasonText='无法可靠读取当前配置或认证控制接口，保留当前交易出口。'
    }
    [pscustomobject]$result
}
function Initialize-TCProviderPipeIdentity {
    if('TCProviderPipeIdentity' -as [type]){return}
    . (Join-Path $PSScriptRoot 'TradeChannel.Components.ps1')
    Initialize-TCRuntimeComponent -Name TCDevicePath
}
function Get-TCProviderPipeServerId {
    param($Pipe)
    Initialize-TCProviderPipeIdentity
    [uint32]$serverId=0
    if(-not [TCProviderPipeIdentity]::GetNamedPipeServerProcessId($Pipe.SafePipeHandle,[ref]$serverId) -or $serverId -eq 0){throw '无法验证控制管道的服务端进程。'}
    [int]$serverId
}
function Open-TCProviderControlPipe {
    param([string]$Name,[int]$TimeoutMilliseconds=2000)
    $stream=New-Object IO.Pipes.NamedPipeClientStream('.',$Name,[IO.Pipes.PipeDirection]::InOut,[IO.Pipes.PipeOptions]::Asynchronous)
    try{$stream.Connect($TimeoutMilliseconds);return $stream}catch{$stream.Dispose();throw '无法连接本机控制管道。'}
}
function Read-TCProviderControlResponse {
    param([IO.Stream]$Stream,[int]$TimeoutMilliseconds=4000,[int]$MaxBytes=4194304)
    $watch=[Diagnostics.Stopwatch]::StartNew();$memory=New-Object IO.MemoryStream;$buffer=New-Object byte[] 8192
    try{
        while($true){
            $remaining=$TimeoutMilliseconds-[int]$watch.ElapsedMilliseconds;if($remaining -le 0){throw '控制接口读取超时。'}
            $task=$Stream.ReadAsync($buffer,0,$buffer.Length)
            if(-not $task.Wait($remaining)){throw '控制接口读取超时。'}
            $count=$task.GetAwaiter().GetResult();if($count -eq 0){break}
            if($memory.Length+$count -gt $MaxBytes+32768){throw '控制接口响应超过大小限制。'}
            $memory.Write($buffer,0,$count)
        }
        $bytes=$memory.ToArray();$headerEnd=-1
        for($i=0;$i -lt [Math]::Min($bytes.Length-3,32768);$i++){if($bytes[$i] -eq 13 -and $bytes[$i+1] -eq 10 -and $bytes[$i+2] -eq 13 -and $bytes[$i+3] -eq 10){$headerEnd=$i;break}}
        if($headerEnd -lt 0){throw '控制接口 HTTP 标头无效。'}
        $headers=[Text.Encoding]::ASCII.GetString($bytes,0,$headerEnd)
        if($headers -notmatch '^HTTP/1\.[01] 200(?: |\r\n)' -or $headers -match '(?im)^Transfer-Encoding\s*:'){throw '控制接口拒绝读取或返回了不支持的分块响应。'}
        $length=$bytes.Length-$headerEnd-4;if($length -gt $MaxBytes){throw '控制接口 JSON 超过大小限制。'}
        $declared=[regex]::Matches($headers,'(?im)^Content-Length:\s*(\d+)\s*$')
        if($declared.Count -gt 1 -or ($declared.Count -eq 1 -and [long]$declared[0].Groups[1].Value -ne $length)){throw '控制接口响应不完整。'}
        $json=(New-Object Text.UTF8Encoding($false,$true)).GetString($bytes,$headerEnd+4,$length)
        ConvertFrom-Json -InputObject $json
    }finally{$memory.Dispose();$watch.Stop()}
}
function Invoke-TCProviderPipeRead {
    param([string]$PipePath,[string]$Secret,[int]$OwnerId,[ValidateSet('/configs','/proxies','/connections')][string]$Path)
    if($PipePath -notmatch '^\\\\\.\\pipe\\([^\\/\x00-\x1f]{1,200})$' -or $OwnerId -le 0 -or -not $Secret -or $Secret -match '[\r\n]'){throw '缺少有效的本机认证控制管道。'}
    $name=$matches[1];$pipe=$null
    try{
        $pipe=Open-TCProviderControlPipe $name
        # Never send the bearer secret before proving this is the SOCKS core PID.
        if((Get-TCProviderPipeServerId $pipe) -ne $OwnerId){throw '控制管道和 SOCKS 端口不属于同一进程。'}
        $request=[Text.Encoding]::UTF8.GetBytes(('GET '+$Path+" HTTP/1.0`r`nHost: localhost`r`nAuthorization: Bearer "+$Secret+"`r`nConnection: close`r`nAccept: application/json`r`n`r`n"))
        $write=$pipe.WriteAsync($request,0,$request.Length);if(-not $write.Wait(2000)){throw '控制管道写入超时。'};$null=$write.GetAwaiter().GetResult()
        Read-TCProviderControlResponse $pipe
    }finally{if($pipe){$pipe.Dispose()}}
}
function Invoke-TCProviderControlRead {
    param([string]$Endpoint,[string]$PipePath,[string]$Secret,[int]$OwnerId,[ValidateSet('/configs','/proxies','/connections')][string]$Path)
    if($PipePath){Invoke-TCProviderPipeRead -PipePath $PipePath -Secret $Secret -OwnerId $OwnerId -Path $Path}
    else{Invoke-TCProviderControllerRead -Endpoint $Endpoint -Secret $Secret -Path $Path}
}
