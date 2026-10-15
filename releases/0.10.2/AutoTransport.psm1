#requires -Version 5.1
Set-StrictMode -Version 2

# Root is the TradeChannel data root (the parent of Product). Only New writes:
# Product/.staging, Product/nodes, Product/index.json and the store lock.
# TransportInfo is a trust boundary: the caller supplies an authenticated SSH
# response, or the envelope returned by Get-TCSavedTransportInfo. No SSH here.
$script:TCAutoNodes = Import-Module (Join-Path $PSScriptRoot 'NodeStore.psm1') -PassThru -DisableNameChecking
$script:TCAutoImplementation = {
    param([string]$Root,[string]$Id,[string]$Operation,$TransportInfo)
    $ErrorActionPreference = 'Stop'
    $lock=$null; $stage=$null; $final=$null; $newId=$null; $committed=$false

    function Resolve-AutoPath {
        param($Path,[switch]$Directory)
        if($Path -isnot [string] -or -not [IO.Path]::IsPathRooted($Path)){Stop-TCError '自动 TCP 需要绝对本机路径。'}
        $p=Get-TCFullPath $Path; Assert-TCNoReparse $p
        if($Directory){if(-not [IO.Directory]::Exists($p)){Stop-TCError '自动 TCP 数据目录不存在。'}}
        elseif(-not [IO.File]::Exists($p)){Stop-TCError '自动 TCP 所需文件不存在。'}
        return $p
    }
    function Get-AutoHash {param([string]$Path) (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash}
    function Read-AutoJson {
        param([string]$Path)
        $raw=Read-TCBoundedText $Path
        try{
            if((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')){$v=ConvertFrom-Json -InputObject $raw -DateKind String -ErrorAction Stop}
            else{$v=ConvertFrom-Json -InputObject $raw -ErrorAction Stop}
        }catch{Stop-TCError '自动 TCP JSON 格式无效；内容未输出。'}finally{$raw=$null}
        if($null -eq $v -or $v -isnot [pscustomobject]){Stop-TCError '自动 TCP JSON 顶层必须是对象。'}
        $v
    }
    function Get-AutoDigest {
        param($Value)
        $bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Value -Depth 40 -Compress))
        $sha=[Security.Cryptography.SHA256]::Create()
        try{([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','')}
        finally{$sha.Dispose();[Array]::Clear($bytes,0,$bytes.Length)}
    }
    function Read-AutoCheckedJson {
        param([string]$Path,[string]$Hash)
        $p=Resolve-AutoPath $Path
        if($Hash -cnotmatch '^[A-Fa-f0-9]{64}$' -or (Get-AutoHash $p) -ine $Hash){Stop-TCError '自动 TCP 配置完整性核验失败。'}
        $value=Read-AutoJson $p
        if((Get-AutoHash $p) -ine $Hash){Stop-TCError '读取期间配置发生变化，请重试。'}
        $value
    }
    function Read-AutoIndex {
        param([string]$Store)
        # PS 7 ConvertFrom-Json returns Int64; NodeStore's PS 5 reader expects Int32.
        # Validate the same schema in memory; never rewrite a legacy index in Get.
        $path=Resolve-AutoPath (Join-Path $Store 'index.json');$index=Read-AutoJson $path
        Assert-TCFields $index @('schemaVersion','nodes','tradeDomains') @('providerReferences')
        if(($index.schemaVersion -isnot [int] -and $index.schemaVersion -isnot [long]) -or $index.schemaVersion -ne 1){Stop-TCError '不支持此节点库版本。'}
        if($index.nodes -isnot [array] -or $index.nodes.Count -gt 1000){Stop-TCError '节点列表格式无效或超过 1000 个节点。'}
        $index.tradeDomains=@(ConvertTo-TCDomains $index.tradeDomains)
        if($index.PSObject.Properties['providerReferences']){$index.providerReferences=@(ConvertTo-TCProviderReferences $index.providerReferences)}
        $ids=@{}
        foreach($n in $index.nodes){
            Assert-TCFields $n @('id','name','kind','endpoint','manifestPath','registeredAt','status')
            $id=ConvertTo-TCId $n.id;if($ids.ContainsKey($id)){Stop-TCError '节点库包含重复 ID。'};$ids[$id]=$true
            $n.id=$id;$n.name=ConvertTo-TCName $n.name;$n.endpoint=(ConvertTo-TCEndpoint $n.endpoint).text
            if($n.kind -cnotin @('wireguard','existing') -or $n.status -cnotin @('CandidateOnly','Registered','PendingAuthorization')){Stop-TCError '节点类型或状态无效。'}
            $date=[DateTimeOffset]::MinValue
            if($n.registeredAt -isnot [string] -or -not [DateTimeOffset]::TryParse($n.registeredAt,[ref]$date)){Stop-TCError '节点登记时间无效。'}
            if($n.status -ceq 'PendingAuthorization'){if($null -ne $n.manifestPath){Stop-TCError '待授权节点不能携带 manifest。'}}
            elseif($n.manifestPath -isnot [string] -or -not [IO.Path]::IsPathRooted($n.manifestPath)){Stop-TCError '节点 manifest 路径无效。'}
        }
        $index
    }
    function ConvertTo-AutoAddress {
        param($Value)
        if($Value -isnot [string] -or $Value -cnotmatch '^([0-9.]+)(?:/32)?$'){Stop-TCError '自动 TCP 客户端地址必须是 IPv4 或 IPv4/32。'}
        $ip=$null
        if(-not [Net.IPAddress]::TryParse($matches[1],[ref]$ip) -or $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork){Stop-TCError '自动 TCP 客户端地址无效。'}
        $ip.ToString()
    }
    function Assert-AutoIdentity {
        param($Config,$Manifest,$Endpoint,[string]$Wg)
        $wgEndpoints=@(Get-TCProperty $Config 'endpoints' @() | Where-Object {(Get-TCProperty $_ 'type' '') -ceq 'wireguard'})
        if($wgEndpoints.Count -ne 1 -or (Get-TCProperty $wgEndpoints[0] 'tag' '') -cne 'hk' -or (Get-TCProperty $wgEndpoints[0] 'system' $true) -ne $false){Stop-TCError '自动 TCP 需要唯一的用户态 WireGuard hk 身份。'}
        $e=$wgEndpoints[0];$peers=@(Get-TCProperty $e 'peers' @());$addresses=@(Get-TCProperty $e 'address' @())
        if($peers.Count -ne 1 -or $addresses.Count -ne 1){Stop-TCError '自动 TCP 不支持多 Peer 或多地址身份。'}
        $p=$peers[0];$hostAddress=[string](Get-TCProperty $p 'address' '')
        $peerText=if($hostAddress.Contains(':')){'['+$hostAddress+']:'+[string]$p.port}else{$hostAddress+':'+[string]$p.port}
        if((ConvertTo-TCEndpoint $peerText).text -cne $Endpoint.text -or [string]$p.public_key -cne [string]$Manifest.ServerPublicKey){Stop-TCError 'WireGuard Peer 与原 manifest 的服务器不一致。'}
        if((ConvertTo-AutoAddress $addresses[0]) -cne (ConvertTo-AutoAddress $Manifest.ClientAddress)){Stop-TCError 'WireGuard 客户端地址与原 manifest 不一致。'}
        $key=[string](Get-TCProperty $e 'private_key' '');Assert-TCKey $key
        $derived=Invoke-TCNative -FilePath $Wg -ArgumentList @('pubkey') -InputText $key
        if($derived.ExitCode -ne 0 -or $derived.StandardOutput.Trim() -cne [string]$Manifest.ClientPublicKey){Stop-TCError '私钥推导的客户端公钥与原 manifest 不一致。'}
        $derived=$null;$key=$null
        Assert-TCConfigurationDependencies $Config
    }
    function Read-AutoNode {
        param($Node)
        if(-not $Node.manifestPath){Stop-TCError '线路尚无可准备的候选配置。'}
        $mp=Resolve-AutoPath $Node.manifestPath;$mh=Get-AutoHash $mp;$m=Read-AutoJson $mp
        if($m.SchemaVersion -ne 1 -or (Get-AutoHash $mp) -cne $mh){Stop-TCError 'manifest 版本无效或读取期间发生变化。'}
        foreach($field in @('ClientPublicKey','ServerPublicKey','ClientAddress','ServerEndpoint','CandidatePath','CandidateSHA256','ProbePath','ProbeSHA256','EnginePath','WgPath')){
            if(-not (Get-TCProperty $m $field)){Stop-TCError 'manifest 缺少身份、完整性或探测资产字段。'}
        }
        Assert-TCKey ([string]$m.ClientPublicKey);Assert-TCKey ([string]$m.ServerPublicKey)
        if($m.ClientPublicKey -ceq $m.ServerPublicKey){Stop-TCError '客户端和服务器公钥不能相同。'}
        if(($Node.kind -ceq 'wireguard' -and (ConvertTo-TCId ([string](Get-TCProperty $m 'node_id' ''))) -cne $Node.id) -or ((Get-TCProperty $m 'TCManagedNodeId') -and (ConvertTo-TCId $m.TCManagedNodeId) -cne $Node.id)){Stop-TCError 'manifest 不属于选中的节点 ID。'}
        $endpoint=ConvertTo-TCEndpoint $m.ServerEndpoint
        if($endpoint.text -cne (ConvertTo-TCEndpoint $Node.endpoint).text){Stop-TCError '索引端点与 manifest 不一致。'}
        $engine=Resolve-AutoPath $m.EnginePath;$wg=Resolve-AutoPath $m.WgPath
        if([IO.Path]::GetFileName($engine) -ine 'sing-box.exe' -or [IO.Path]::GetFileName($wg) -ine 'wg.exe'){Stop-TCError '自动 TCP 仅允许 sing-box 和 wg 的离线校验程序。'}
        $cfg=Read-AutoCheckedJson $m.CandidatePath $m.CandidateSHA256
        $probe=Read-AutoCheckedJson $m.ProbePath $m.ProbeSHA256
        Assert-AutoIdentity $cfg $m $endpoint $wg;Assert-AutoIdentity $probe $m $endpoint $wg
        if(@($probe.inbounds).Count -eq 0){Stop-TCError '缺少独立探测入口。'}
        foreach($entry in @($probe.inbounds)){
            if($entry.type -notin @('mixed','socks','http') -or $entry.listen -cne '127.0.0.1'){Stop-TCError '探测资产必须使用回环入口。'}
            # Old jobs have an unauthenticated probe. Get remains read-only;
            # New adds authentication to the copied stage, preserving the source.
            foreach($u in @(Get-TCProperty $entry 'users' @())){if(-not (Get-TCProperty $u 'username') -or ([string](Get-TCProperty $u 'password' '')).Length -lt 32){Stop-TCError '探测资产认证不完整。'}}
        }
        [pscustomobject]@{Node=$Node;Manifest=$m;ManifestPath=$mp;ManifestHash=$mh;Config=$cfg;Probe=$probe;Endpoint=$endpoint;Engine=$engine;Wg=$wg}
    }
    function Get-AutoConnection {
        param($Value,[string]$Source,[string]$Verification)
        if(-not $Value){return $null}
        $hostAddress=[string](Get-TCProperty $Value 'Host' '')
        $hostEndpoint=if($hostAddress.Contains(':')){'['+$hostAddress+']:22'}else{$hostAddress+':22'}
        $address=(ConvertTo-TCEndpoint $hostEndpoint).address
        $port=ConvertTo-TCPort (Get-TCProperty $Value 'Port' 22);$user=[string](Get-TCProperty $Value 'User' 'root')
        if($user -cnotmatch '^[a-z_][a-z0-9_-]{0,31}$'){Stop-TCError 'SSH 登录建议的用户名无效。'}
        $identity=[string](Get-TCProperty $Value 'IdentityFile' '')
        if($identity){$identity=Get-TCFullPath $identity;Assert-TCNoReparse $identity}
        [pscustomobject]@{Host=$address;Port=$port;User=$user;IdentityFile=$identity;Source=$Source;Verification=$Verification;Unverified=($Verification -ceq 'Unverified')}
    }
    function Find-AutoServer {
        param($Source)
        $path=Join-Path $dataRoot 'servers\registry.json';$found=@()
        if([IO.File]::Exists($path)){
            $registry=Read-AutoJson (Resolve-AutoPath $path)
            if($registry.SchemaVersion -ne 1){Stop-TCError '服务器台账版本无效。'}
            foreach($s in @($registry.Servers)){
                $linked=@(Get-TCProperty $s 'LinkedNodeIds' @()) -contains $Source.Node.id
                $key=[string](Get-TCProperty $s 'ServerPublicKey' '')
                if($linked -and $key -and $key -cne $Source.Manifest.ServerPublicKey){Stop-TCError '关联服务器公钥与原节点冲突，不能使用该登录记录。'}
                if($linked -or ($key -and $key -ceq $Source.Manifest.ServerPublicKey)){$found+=,$s}
            }
        }
        if($found.Count -gt 1){Stop-TCError '服务器身份对应多个台账记录，请先消除歧义。'}
        if($found.Count -eq 1){
            $s=$found[0];$null=ConvertTo-TCId ([string]$s.LocalRecordId)
            $c=Get-AutoConnection (Get-TCProperty $s 'Connection') 'ServerRegistry' 'Bound'
            if($c -and $c.Host -cne $Source.Endpoint.address){Stop-TCError '关联服务器 SSH Host 与原节点端点不一致。'}
            foreach($e in @(Get-TCProperty $s 'Endpoints' @())){if((ConvertTo-TCEndpoint $e).address -cne $Source.Endpoint.address){Stop-TCError '服务器台账端点与原节点不一致。'}}
            return [pscustomobject]@{Server=$s;Connection=$c;ServerId=$s.LocalRecordId}
        }
        $suggestions=@();$jobs=Join-Path $dataRoot 'linux-jobs'
        if([IO.Directory]::Exists($jobs)){
            $null=Resolve-AutoPath $jobs -Directory
            foreach($dir in @(Get-ChildItem -LiteralPath $jobs -Directory -Force)){
                Assert-TCNoReparse $dir.FullName;$p=Join-Path $dir.FullName 'job.json'
                if(-not [IO.File]::Exists($p)){continue}
                $j=Read-AutoJson (Resolve-AutoPath $p);$v=Get-TCProperty $j 'Connection'
                if(-not $v){continue}
                $c=Get-AutoConnection $v 'LegacyJob' 'Unverified'
                if($c.Host -cne $Source.Endpoint.address){continue}
                $key=[string](Get-TCProperty $j 'ServerPublicKey' '')
                if($key -and $key -cne $Source.Manifest.ServerPublicKey){continue}
                $suggestions+=,$c
            }
        }
        $unique=@($suggestions | Group-Object {Get-AutoDigest $_} | ForEach-Object {$_.Group[0]})
        # Ambiguous old jobs do not choose credentials arbitrarily.
        $c=if($unique.Count -eq 1){$unique[0]}else{$null}
        [pscustomobject]@{Server=$null;Connection=$c;ServerId=$null}
    }
    function Assert-AutoEnvelope {
        param($Info,$Source,$Binding)
        if((Get-TCProperty $Info 'Kind' '') -cne 'TradeChannel.TransportInfo' -or (Get-TCProperty $Info 'Status' '') -cne 'Available'){Stop-TCError '需要经认证的 Available TransportInfo。'}
        $remoteNode=ConvertTo-TCId ([string](Get-TCProperty $Info 'NodeId' ''));$owner=ConvertTo-TCId ([string](Get-TCProperty $Info 'RemoteOwnerId' ''))
        foreach($field in @('ServerPublicKey','ClientPublicKey')){
            if([string](Get-TCProperty $Info $field '') -cne [string]$Source.Manifest.$field){Stop-TCError 'TCP 返回的服务器或客户端身份不属于原节点。'}
        }
        $address=ConvertTo-AutoAddress (Get-TCProperty $Info 'ClientAddress')
        if($address -cne (ConvertTo-AutoAddress $Source.Manifest.ClientAddress)){Stop-TCError 'TCP 返回的客户端地址不属于原节点。'}
        foreach($expected in @($Binding.Server,$Source.Manifest)){
            if(-not $expected){continue}
            $expectedOwner=[string](Get-TCProperty $expected 'RemoteOwnerId' (Get-TCProperty $expected 'AutoTransportRemoteOwnerId' ''))
            $expectedNode=if($expected -eq $Binding.Server){[string](Get-TCProperty $expected 'NodeId' '')}else{[string](Get-TCProperty $expected 'AutoTransportRemoteNodeId' (Get-TCProperty $expected 'ServerNodeId' ''))}
            if(($expectedOwner -and $expectedOwner -cne $owner) -or ($expectedNode -and $expectedNode -cne $remoteNode)){Stop-TCError 'TCP 返回的远端归属或节点 ID 与已知服务器不一致。'}
        }
        $raw=Get-TCProperty $Info 'Transport'
        foreach($field in @('Type','Server','Port','Uuid','RealityPublicKey','RealityShortId','ServerName')){if($null -eq (Get-TCProperty $raw $field)){Stop-TCError 'TCP 返回缺少传输字段。'}}
        if((Get-TCProperty $raw 'Type') -cne 'tcp-reality'){Stop-TCError '仅支持 TCP Reality 传输。'}
        $t=ConvertTo-TCTransport $raw
        if($t.Server -cne $Source.Endpoint.address){Stop-TCError 'TCP Host 与原 WireGuard 服务器端点不一致。'}
        [pscustomobject][ordered]@{Kind='TradeChannel.TransportInfo';Status='Available';NodeId=$remoteNode;RemoteOwnerId=$owner;ServerPublicKey=$Source.Manifest.ServerPublicKey;ClientPublicKey=$Source.Manifest.ClientPublicKey;ClientAddress=$address;Transport=$t}
    }
    function Get-AutoTcpSettings {
        param($Source)
        $m=$Source.Manifest;$cfg=$Source.Config
        $detours=@($cfg.endpoints|Where-Object {(Get-TCProperty $_ 'detour' '') -ceq 'tc-transport'})
        $actual=$null
        if($detours.Count){
            # Read actual VLESS settings rather than trusting manifest.Transport.
            $actual=Get-TCTransportFromConfiguration ([pscustomobject]@{}) $cfg
            foreach($other in @((Get-TCProperty $m 'Transport'),(Get-TCProperty $m 'TransportSettings'))){if($other -and (Get-AutoDigest (ConvertTo-TCTransport $other)) -cne (Get-AutoDigest $actual)){Stop-TCError '已保存 TCP 参数与候选配置不一致。'}}
            $probeActual=Get-TCTransportFromConfiguration ([pscustomobject]@{}) $Source.Probe
            if(-not $probeActual -or (Get-AutoDigest $probeActual) -cne (Get-AutoDigest $actual)){Stop-TCError '主配置和探测配置的 TCP 参数不一致。'}
        }else{
            if(Get-TCProperty $m 'Transport'){Stop-TCError 'manifest 声称 TCP 但配置没有 TCP binding。'}
            $saved=Get-TCProperty $m 'TransportSettings';if($saved){$actual=ConvertTo-TCTransport $saved}
        }
        if($actual -and $actual.Server -cne $Source.Endpoint.address){Stop-TCError '已保存 TCP 参数来自不同服务器。'}
        return $actual
    }
    function Find-AutoSaved {
        param($Source,$Binding,$Index)
        $candidates=@([pscustomobject]@{Source=$Source;Kind='Manifest'})
        foreach($n in @($Index.nodes)){
            if($n.id -ceq $Source.Node.id -or -not $n.manifestPath){continue}
            $mp=Resolve-AutoPath $n.manifestPath;$m=Read-AutoJson $mp
            if((Get-TCProperty $m 'AutoTransportSourceNodeId' '') -cne $Source.Node.id){continue}
            $s=Read-AutoNode $n
            foreach($field in @('ServerPublicKey','ClientPublicKey','ClientAddress','ServerEndpoint')){if([string]$s.Manifest.$field -cne [string]$Source.Manifest.$field){Stop-TCError 'TCP 备用节点的来源身份不一致。'}}
            $candidates+=,[pscustomobject]@{Source=$s;Kind='AutoTransportSibling'}
        }
        $saved=@()
        foreach($candidate in $candidates){
            $s=$candidate.Source;$t=Get-AutoTcpSettings $s;if(-not $t){continue}
            $owner=[string](Get-TCProperty $s.Manifest 'AutoTransportRemoteOwnerId' (Get-TCProperty $s.Manifest 'RemoteOwnerId' (Get-TCProperty $Binding.Server 'RemoteOwnerId' '')))
            $remote=[string](Get-TCProperty $s.Manifest 'AutoTransportRemoteNodeId' (Get-TCProperty $s.Manifest 'ServerNodeId' (Get-TCProperty $Binding.Server 'NodeId' '')))
            # Valid local settings can exist before a registry/remote-owner link.
            # Report their presence, but never invent an authenticated identity.
            if(-not $owner -or -not $remote){$saved+=,[pscustomobject]@{Info=$null;Kind=$candidate.Kind;Transport=$t};continue}
            $info=Assert-AutoEnvelope ([pscustomobject]@{Kind='TradeChannel.TransportInfo';Status='Available';NodeId=$remote;RemoteOwnerId=$owner;ServerPublicKey=$s.Manifest.ServerPublicKey;ClientPublicKey=$s.Manifest.ClientPublicKey;ClientAddress=$s.Manifest.ClientAddress;Transport=$t}) $Source $Binding
            if($candidate.Kind -ceq 'AutoTransportSibling'){
                if((Get-TCProperty $s.Manifest 'SourceConfigSHA256' '') -ine $Source.Manifest.CandidateSHA256){continue}
                if((Get-TCProperty $s.Manifest 'TCPBindingDigest' '') -cne (Get-AutoDigest $info)){Stop-TCError 'TCP 备用节点 binding 完整性无效。'}
            }
            $saved+=,[pscustomobject]@{Info=$info;Kind=$candidate.Kind;Transport=$t}
        }
        $digests=@($saved|ForEach-Object {Get-AutoDigest $_.Transport}|Select-Object -Unique)
        if($digests.Count -gt 1){Stop-TCError '本节点存在多套 TCP 参数，请登录核验当前参数。'}
        if($saved.Count){$recoverable=@($saved|Where-Object {$_.Info});if($recoverable.Count){return $recoverable[0]};return $saved[0]};return $null
    }
    function Test-AutoActive {
        param($Source)
        $runtime=Join-Path $dataRoot 'runtime.json';$dep=Join-Path $dataRoot 'deployment.json';$rt=$null;$mp=$null;$busy=$false
        if([IO.File]::Exists($runtime)){
            $rt=Read-AutoJson (Resolve-AutoPath $runtime);$busy=([string](Get-TCProperty $rt 'State' 'Unknown') -notin @('Disconnected','Stopped','StoppedWithError') -or [bool](Get-TCProperty $rt 'CleanupError' $false));$mp=Get-TCProperty $rt 'ManifestPath'
        }
        if(-not $mp -and [IO.File]::Exists($dep)){$mp=Get-TCProperty (Read-AutoJson (Resolve-AutoPath $dep)) 'ManifestPath'}
        if($busy){
            if(-not $mp){return $true}
            $m=Read-AutoJson (Resolve-AutoPath $mp)
            if((Test-TCSamePath $mp $Source.ManifestPath) -or [string](Get-TCProperty $m 'ClientPublicKey' '') -ceq $Source.Manifest.ClientPublicKey){return $true}
        }
        foreach($p in @(Get-CimInstance Win32_Process -Filter "Name='sing-box.exe'" -ErrorAction Stop)){
            if(-not (Test-TCSamePath $p.ExecutablePath $Source.Engine)){continue}
            if(-not $p.CommandLine){return $true}
            if(([string]$p.CommandLine).IndexOf([string]$Source.Manifest.CandidatePath,[StringComparison]::OrdinalIgnoreCase) -ge 0 -and [string]$p.CommandLine -match '(?:^|\s)run(?:\s|$)'){return $true}
        }
        return $false
    }
    function New-AutoResult {
        param($Node,[bool]$Reused,[bool]$Active)
        [pscustomobject]@{Kind='TradeChannel.AutomaticTransportCandidate';Status='ReadyInactive';Id=$Node.id;NodeId=$Node.id;Name=$Node.name;ManifestPath=$Node.manifestPath;SourceNodeId=$source.Node.id;TransportMode='Tcp';Reused=$Reused;CurrentNetworkChanged=$false;Activated=$false;SourceActive=$Active;ProbeRequiresInactiveIdentity=$true}
    }
    try{
        $dataRoot=Resolve-AutoPath $Root -Directory;$store=Resolve-AutoPath (Join-Path $dataRoot 'Product') -Directory;$nodeId=ConvertTo-TCId $Id
        $index=Read-AutoIndex $store
        if($Operation -ceq 'New'){$lock=Open-TCLock $store;$index=Read-AutoIndex $store}
        $found=@($index.nodes|Where-Object {$_.id -ceq $nodeId})
        if($found.Count -ne 1){Stop-TCError '找不到唯一的指定线路。'}
        $source=Read-AutoNode $found[0];$binding=Find-AutoServer $source
        if($Operation -cne 'New'){
            $saved=Find-AutoSaved $source $binding $index
            if($Operation -ceq 'Saved'){if($saved){return $saved.Info};return $null}
            $remoteOwner=[string](Get-TCProperty $binding.Server 'RemoteOwnerId' (Get-TCProperty $source.Manifest 'AutoTransportRemoteOwnerId' (Get-TCProperty $source.Manifest 'RemoteOwnerId' '')))
            $remoteNode=[string](Get-TCProperty $binding.Server 'NodeId' (Get-TCProperty $source.Manifest 'AutoTransportRemoteNodeId' (Get-TCProperty $source.Manifest 'ServerNodeId' '')))
            return [pscustomobject]@{Id=$source.Node.id;Name=$source.Node.name;DefaultServer=$source.Endpoint.address;ClientPublicKey=$source.Manifest.ClientPublicKey;ServerPublicKey=$source.Manifest.ServerPublicKey;ClientAddress=(ConvertTo-AutoAddress $source.Manifest.ClientAddress);RemoteOwnerId=$(if($remoteOwner){$remoteOwner}else{$null});RemoteNodeId=$(if($remoteNode){$remoteNode}else{$null});Active=[bool](Test-AutoActive $source);HasSettings=[bool]$saved;Connection=$binding.Connection;ServerId=$binding.ServerId;NeedsAuthentication=(-not [bool]($saved -and $saved.Info));SettingsSource=$(if($saved){$saved.Kind}else{'None'})}
        }
        $info=Assert-AutoEnvelope $TransportInfo $source $binding;$digest=Get-AutoDigest $info;$active=[bool](Test-AutoActive $source)
        foreach($n in @($index.nodes)){
            if(-not $n.manifestPath -or $n.id -ceq $source.Node.id){continue}
            $m=Read-AutoJson (Resolve-AutoPath $n.manifestPath)
            if((Get-TCProperty $m 'AutoTransportSourceNodeId' '') -cne $source.Node.id -or (Get-TCProperty $m 'SourceConfigSHA256' '') -ine $source.Manifest.CandidateSHA256 -or (Get-TCProperty $m 'TCPBindingDigest' '') -cne $digest){continue}
            $s=Read-AutoNode $n;$t=Get-AutoTcpSettings $s
            foreach($field in @('ClientPublicKey','ServerPublicKey','ClientAddress','ServerEndpoint')){if([string]$s.Manifest.$field -cne [string]$source.Manifest.$field){Stop-TCError '已有 TCP 备用节点身份不一致。'}}
            if(-not $t -or (Get-AutoDigest $t) -cne (Get-AutoDigest $info.Transport) -or $n.status -cne 'CandidateOnly'){Stop-TCError '已有 TCP 备用节点状态或 binding 无效。'}
            Test-TCCheckedConfiguration $s.Engine $s.Manifest.CandidatePath;Test-TCCheckedConfiguration $s.Engine $s.Manifest.ProbePath
            return New-AutoResult $n $true $active
        }
        if($index.nodes.Count -ge 1000){Stop-TCError '节点库最多支持 1000 个节点。'}
        $newId=[guid]::NewGuid().ToString('D');$stage=Join-Path (Join-Path $store '.staging') $newId;$final=Join-Path (Join-Path $store 'nodes') $newId
        foreach($parent in @((Join-Path $store '.staging'),(Join-Path $store 'nodes'))){$null=Resolve-AutoPath $parent -Directory}
        Assert-TCNoReparse $final;New-TCPrivateDirectory $stage
        $cfg=Set-TCConfigurationTransport $source.Config $info.Transport;$probe=Set-TCConfigurationTransport $source.Probe $info.Transport
        foreach($entry in @($probe.inbounds)){
            if(@(Get-TCProperty $entry 'users' @()).Count){continue}
            $random=New-Object byte[] 32;$rng=[Security.Cryptography.RandomNumberGenerator]::Create()
            try{$rng.GetBytes($random);$secret=[Convert]::ToBase64String($random)}finally{$rng.Dispose();[Array]::Clear($random,0,$random.Length)}
            $entry|Add-Member NoteProperty users @([pscustomobject]@{username='tradechannel-probe';password=$secret}) -Force;$secret=$null
        }
        Write-TCAtomicJson (Join-Path $stage 'dual-mode.json') $cfg -NewOnly -NoBom;Write-TCAtomicJson (Join-Path $stage 'probe.json') $probe -NewOnly -NoBom
        foreach($path in @((Join-Path $stage 'dual-mode.json'),(Join-Path $stage 'probe.json'))){Set-TCPrivateAcl $path;Test-TCCheckedConfiguration $source.Engine $path}
        # Recheck the immutable inputs before publishing a sibling.
        if((Get-AutoHash $source.ManifestPath) -cne $source.ManifestHash -or (Get-AutoHash $source.Manifest.CandidatePath) -ine $source.Manifest.CandidateSHA256 -or (Get-AutoHash $source.Manifest.ProbePath) -ine $source.Manifest.ProbeSHA256){Stop-TCError '准备期间原配置发生变化，请重试。'}
        $m=$source.Manifest;$created=[DateTimeOffset]::UtcNow.ToString('o')
        foreach($field in @('PreviousManifestPath','UpgradedFrom','AutoTransportSourceNodeId','SourceConfigSHA256','TCPBindingDigest')){$m.PSObject.Properties.Remove($field)}
        $updates=[ordered]@{node_id=$newId;nodeGuid=$newId;TCManagedNodeId=$newId;CreatedAt=$created;Status='CandidateOnly';CandidatePath=(Join-Path $final 'dual-mode.json');ProbePath=(Join-Path $final 'probe.json');CandidateSHA256=(Get-AutoHash (Join-Path $stage 'dual-mode.json'));ProbeSHA256=(Get-AutoHash (Join-Path $stage 'probe.json'));Transport=$info.Transport;TransportSettings=$info.Transport;AutoTransportSourceNodeId=$source.Node.id;AutoTransportSourceManifestPath=$source.ManifestPath;SourceConfigSHA256=$source.Manifest.CandidateSHA256;TCPBindingDigest=$digest;AutoTransportRemoteOwnerId=$info.RemoteOwnerId;AutoTransportRemoteNodeId=$info.NodeId;SyntaxValidated=$true;DeploymentApproved=$false;ServerForwardingVerified=$false;ProcessRoutingVerified=$false;IndependentGuardVerified=$false;ProbeRequiresInactiveIdentity=$true}
        foreach($key in $updates.Keys){$m|Add-Member NoteProperty $key $updates[$key] -Force}
        Write-TCAtomicJson (Join-Path $stage 'manifest.json') $m -NewOnly;Set-TCPrivateAcl (Join-Path $stage 'manifest.json')
        $name=ConvertTo-TCName ($source.Node.name+' TCP备用')
        $n=[pscustomobject][ordered]@{id=$newId;name=$name;kind='wireguard';endpoint=$source.Node.endpoint;manifestPath=(Join-Path $final 'manifest.json');registeredAt=$created;status='CandidateOnly'}
        [IO.Directory]::Move($stage,$final);$stage=$null;$index.nodes=@($index.nodes)+@($n)
        Write-TCAtomicJson (Join-Path $store 'index.json') $index;$committed=$true
        New-AutoResult $n $false $active
    }catch{Stop-TCOperation $_ '自动 TCP 准备失败；原节点和当前连接保留，原始诊断已隐藏。'}
    finally{
        try{if(-not $committed -and $newId){foreach($path in @($stage,$final)|Where-Object {$_}){Remove-TCOwnedDirectory -Root $store -Path $path -Id $newId}}}
        finally{if($lock){$lock.Dispose()};$TransportInfo=$null;$info=$null;$source=$null;$cfg=$null;$probe=$null}
    }
}

function Get-TCTransportPreparation {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][string]$Id)
    & $script:TCAutoNodes $script:TCAutoImplementation $Root $Id 'Preparation' $null
}
function Get-TCSavedTransportInfo {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][string]$Id)
    # Deliberately secret-bearing; pass to New, never log or return through UI.
    # Null means no locally recoverable envelope with known remote identity.
    & $script:TCAutoNodes $script:TCAutoImplementation $Root $Id 'Saved' $null
}
function New-TCAutomaticTransportCandidate {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][string]$Id,[Parameter(Mandatory=$true)]$TransportInfo)
    & $script:TCAutoNodes $script:TCAutoImplementation $Root $Id 'New' $TransportInfo
}
Export-ModuleMember -Function Get-TCTransportPreparation,Get-TCSavedTransportInfo,New-TCAutomaticTransportCandidate
