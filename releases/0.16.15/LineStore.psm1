#requires -Version 5.1
Set-StrictMode -Version 2

# Root is the data root, not Product. Get never initializes directories or locks.
# Only immutable profiles and SchemaVersion 2 line metadata are published.
# Legacy index, manifests, deployment, preferences and runtime are never written.
# Lock order: data/.session.lock -> Product/.store.lock -> lines/<LineId>/.line.lock.
# No RuntimeBridge/AutoTransport imports. Native work is pubkey/check only.
$script:TCLineNodes = Import-Module (Join-Path $PSScriptRoot 'NodeStore.psm1') -PassThru -DisableNameChecking
$script:PreferenceClock=$null
function LSPreferenceNow {if($script:PreferenceClock){return & $script:PreferenceClock};[DateTimeOffset]::UtcNow}
$script:TCLineWg = Join-Path $PSScriptRoot 'assets\wg.exe'
$script:TCLineImplementation = {
    param([string]$Root,[string]$Id,[string]$Operation,$TransportInfo,[string]$ProfileId,$Validation,[string]$FallbackWg)
    $ErrorActionPreference='Stop'
    $sessionLock=$null;$indexLock=$null;$lineLock=$null
    $owned=New-Object 'Collections.Generic.List[string]'
    $created=New-Object 'Collections.Generic.List[string]'
    $committed=$false
    $derivedKeys=@{} # Per-call only; Get never creates a cache file.
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
        if($Value -isnot [string] -or $Value -cnotmatch '^([0-9.]+)(?:/(?:[0-9]|[12][0-9]|3[0-2]))?$'){Stop-TCError '自动 TCP 客户端地址必须是 IPv4 地址及有效 CIDR 前缀。'}
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
        $keyDigest=Get-AutoDigest ([ordered]@{Wg=$Wg;Key=$key})
        if(-not $derivedKeys.ContainsKey($keyDigest)){
            $derived=Invoke-TCNative -FilePath $Wg -ArgumentList @('pubkey') -InputText $key
            if($derived.ExitCode -ne 0){Stop-TCError '私钥公钥推导失败。'}
            $derivedKeys[$keyDigest]=$derived.StandardOutput.Trim();$derived=$null
        }
        if($derivedKeys[$keyDigest] -cne [string]$Manifest.ClientPublicKey){Stop-TCError '私钥推导的客户端公钥与原 manifest 不一致。'}
        $key=$null
        Assert-TCConfigurationDependencies $Config
    }
    function Read-AutoNode {
        param($Node)
        if(-not $Node.manifestPath){Stop-TCError '线路尚无可准备的候选配置。'}
        $mp=Resolve-AutoPath $Node.manifestPath;$mh=Get-AutoHash $mp;$m=Read-AutoJson $mp
        if($m.SchemaVersion -ne 1 -or (Get-AutoHash $mp) -cne $mh){Stop-TCError 'manifest 版本无效或读取期间发生变化。'}
        foreach($field in @('ClientPublicKey','ServerPublicKey','ClientAddress','ServerEndpoint','CandidatePath','CandidateSHA256','ProbePath','EnginePath')){
            if(-not (Get-TCProperty $m $field)){Stop-TCError 'manifest 缺少身份、完整性或探测资产字段。'}
        }
        Assert-TCKey ([string]$m.ClientPublicKey);Assert-TCKey ([string]$m.ServerPublicKey)
        if($m.ClientPublicKey -ceq $m.ServerPublicKey){Stop-TCError '客户端和服务器公钥不能相同。'}
        if(($Node.kind -ceq 'wireguard' -and (ConvertTo-TCId ([string](Get-TCProperty $m 'node_id' ''))) -cne $Node.id) -or ((Get-TCProperty $m 'TCManagedNodeId') -and (ConvertTo-TCId $m.TCManagedNodeId) -cne $Node.id)){Stop-TCError 'manifest 不属于选中的节点 ID。'}
        $endpoint=ConvertTo-TCEndpoint $m.ServerEndpoint
        if($endpoint.text -cne (ConvertTo-TCEndpoint $Node.endpoint).text){Stop-TCError '索引端点与 manifest 不一致。'}
        # Legacy existing manifests may lack these fields. Derive in memory only;
        # publication writes them into the new immutable copy, never the source.
        if(-not (Get-TCProperty $m 'WgPath')){$m|Add-Member NoteProperty WgPath (Resolve-AutoPath $FallbackWg) -Force}
        if(-not (Get-TCProperty $m 'ProbeSHA256')){$m|Add-Member NoteProperty ProbeSHA256 (Get-AutoHash (Resolve-AutoPath $m.ProbePath)) -Force}
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
        $result=[ordered]@{Kind='TradeChannel.TransportInfo';Status='Available';NodeId=$remoteNode;RemoteOwnerId=$owner;ServerPublicKey=$Source.Manifest.ServerPublicKey;ClientPublicKey=$Source.Manifest.ClientPublicKey;ClientAddress=$address;Transport=$t}
        if($Info.PSObject.Properties['MTU']){
            $mtu=$Info.MTU
            if(($mtu -isnot [int] -and $mtu -isnot [long]) -or $mtu -lt 1280 -or $mtu -gt 1420){Stop-TCError '经认证的 MTU 必须为 1280–1420 的整数。'}
            $result.MTU=[int]$mtu
        }
        [pscustomobject]$result
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

    function Copy-LineObject {
        param($Value)
        $json=ConvertTo-Json -InputObject $Value -Depth 40
        if((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')){ConvertFrom-Json -InputObject $json -DateKind String}else{ConvertFrom-Json -InputObject $json}
    }
    function ConvertTo-LineCanonical {
        param($Value)
        if($null -eq $Value -or $Value -is [string] -or $Value -is [ValueType]){return $Value}
        if($Value -is [Collections.IDictionary]){
            $result=[ordered]@{};foreach($key in @($Value.Keys|Sort-Object)){$result[$key]=ConvertTo-LineCanonical $Value[$key]};return $result
        }
        if($Value -is [Collections.IEnumerable]){
            $result=@();foreach($item in $Value){$result+=,(ConvertTo-LineCanonical $item)};return ,$result
        }
        $result=[ordered]@{};foreach($key in @($Value.PSObject.Properties.Name|Sort-Object)){$result[$key]=ConvertTo-LineCanonical $Value.$key};return $result
    }
    function Get-LineDigest {param($Value)Get-AutoDigest (ConvertTo-LineCanonical $Value)}
    function Get-LineMode {
        param($Source)
        if(Get-TCTransportFromConfiguration ([pscustomobject]@{}) $Source.Config){return 'Tcp'};return 'Udp'
    }
    function Get-LineEnvelope {
        param($Source,$Binding,$Original)
        $t=Get-AutoTcpSettings $Source;if(-not $t){return $null}
        $m=$Source.Manifest
        $owner=[string](Get-TCProperty $m 'AutoTransportRemoteOwnerId' (Get-TCProperty $m 'RemoteOwnerId' (Get-TCProperty $Binding.Server 'RemoteOwnerId' '')))
        $remote=[string](Get-TCProperty $m 'AutoTransportRemoteNodeId' (Get-TCProperty $m 'ServerNodeId' (Get-TCProperty $Binding.Server 'NodeId' '')))
        if(-not $owner -or -not $remote){return $null}
        $info=[ordered]@{Kind='TradeChannel.TransportInfo';Status='Available';NodeId=$remote;RemoteOwnerId=$owner;ServerPublicKey=$m.ServerPublicKey;ClientPublicKey=$m.ClientPublicKey;ClientAddress=$m.ClientAddress;Transport=$t}
        if($m.PSObject.Properties['TCServerMTU']){$info.MTU=$m.TCServerMTU}
        Assert-AutoEnvelope ([pscustomobject]$info) $Original $Binding
    }
    function Get-LinePolicyDigest {
        param($Source,$AnchorForBinding)
        $config=Set-TCConfigurationTransport (Copy-LineObject $Source.Config) $null
        $probe=Set-TCConfigurationTransport (Copy-LineObject $Source.Probe) $null
        if($AnchorForBinding -and $Source.Manifest.PSObject.Properties['TCServerMTU']){
            $mtu=$Source.Manifest.TCServerMTU
            if(($mtu -isnot [int] -and $mtu -isnot [long]) -or $mtu -lt 1280 -or $mtu -gt 1420){Stop-TCError '保存的服务器 MTU 无效。'}
            # Normalize only this declared, checked MTU change for policy identity.
            # Every unrelated route/DNS/program/key field is still compared exactly.
            foreach($pair in @(@($config,$AnchorForBinding.Config),@($probe,$AnchorForBinding.Probe))){
                $value=$pair[0];$original=$pair[1]
                $v=@($value.endpoints|Where-Object tag -ceq 'hk');$o=@($original.endpoints|Where-Object tag -ceq 'hk')
                if($v.Count -ne 1 -or $o.Count -ne 1 -or $v[0].mtu -ne $mtu){Stop-TCError 'MTU 声明与端点配置不一致。'}
                $v[0].mtu=$o[0].mtu
                $vt=@($value.inbounds|Where-Object type -ceq 'tun');$ot=@($original.inbounds|Where-Object type -ceq 'tun')
                if($vt.Count -ne $ot.Count){Stop-TCError 'MTU 维护不能更改 TUN 数量。'}
                for($i=0;$i -lt $vt.Count;$i++){if($vt[$i].mtu -ne $mtu){Stop-TCError 'MTU 声明与 TUN 配置不一致。'};$vt[$i].mtu=$ot[$i].mtu}
            }
        }
        if($AnchorForBinding -and (Get-TCProperty $Source.Manifest 'ProbeBinding')){
            # Restore only the explicitly scoped dial fields to the immutable
            # provenance source for policy comparison. Route/DNS rules stay exact.
            foreach($pair in @(@($config,$AnchorForBinding.Config),@($probe,$AnchorForBinding.Probe))){
                $value=$pair[0];$original=Set-TCConfigurationTransport (Copy-LineObject $pair[1]) $null
                foreach($tag in @('hk','dns-direct')){
                    $v=@(if($tag -eq 'hk'){$value.endpoints|Where-Object tag -ceq $tag}else{$value.dns.servers|Where-Object tag -ceq $tag})
                    $o=@(if($tag -eq 'hk'){$original.endpoints|Where-Object tag -ceq $tag}else{$original.dns.servers|Where-Object tag -ceq $tag})
                    if($tag -ceq 'dns-direct' -and [object]::ReferenceEquals($value,$probe) -and $o.Count -eq 0 -and $v.Count -eq 1){
                        # A legacy probe may gain ONLY the anchor candidate's
                        # existing bootstrap DNS. Prove that exact server before
                        # removing the added entry for the original-policy digest.
                        $bootstrap=@($AnchorForBinding.Config.dns.servers|Where-Object tag -ceq 'dns-direct')
                        if($bootstrap.Count -ne 1 -or (Get-TCProperty $bootstrap[0] 'type') -cne 'udp' -or (Get-TCProperty $bootstrap[0] 'detour')){Stop-TCError '旧检测副本的 bootstrap DNS 来源无法核验。'}
                        $restored=Copy-LineObject $v[0]
                        foreach($field in @('bind_interface','inet4_bind_address','domain_resolver')){
                            $restored.PSObject.Properties.Remove($field)
                            if($bootstrap[0].PSObject.Properties[$field]){$restored|Add-Member NoteProperty $field (Copy-LineObject $bootstrap[0].$field) -Force}
                        }
                        if((Get-LineDigest $restored) -cne (Get-LineDigest $bootstrap[0])){Stop-TCError '旧检测副本新增的 bootstrap DNS 与原配置不一致。'}
                        $value.dns.servers=@($value.dns.servers|Where-Object tag -cne 'dns-direct');continue
                    }
                    if($v.Count -ne 1 -or $o.Count -ne 1){Stop-TCError '指定网卡的配置缺少原始端点。'}
                    foreach($field in @('bind_interface','inet4_bind_address','domain_resolver')){
                        $v[0].PSObject.Properties.Remove($field)
                        if($o[0].PSObject.Properties[$field]){$v[0]|Add-Member NoteProperty $field (Copy-LineObject $o[0].$field) -Force}
                    }
                }
            }
        }
        foreach($entry in @($probe.inbounds)){$entry.PSObject.Properties.Remove('users')}
        $fields=[ordered]@{}
        foreach($key in @('TradeProgramPaths','Providers','PolicyVersion','TradeDomainSuffixes','TradeDnsOnlySuffixes','ProviderEnabled','ProviderProgramPaths','ProviderDirectory','ProviderSocksPort','ProviderTradePort','ProviderHttpPort','ProviderPacPort','ProviderBootstrapDomains','IPv6Policy','UnidentifiedPublicProcessPolicy','ModeSwitchPolicy','ExitSwitchPolicy','StartupMode','HasPSK','AgentRuleSetPath','AgentDnsRuleSetPath')){
            $fields[$key]=Get-TCProperty $Source.Manifest $key
        }
        Get-LineDigest ([ordered]@{Config=$config;Probe=$probe;Policy=$fields})
    }
    function Read-LineAnchoredSource {
        param($Node,$Index)
        $recordPath=Join-Path (Join-Path (Join-Path $store 'lines') $Node.id) 'line.json'
        if(-not [IO.File]::Exists($recordPath)){return Read-AutoNode $Node}
        $record=Read-AutoJson (Resolve-AutoPath $recordPath)
        if($record.SchemaVersion -ne 2 -or $record.LineId -cne $Node.id -or $record.SourceNodeId -cne $Node.id -or $record.Profiles -isnot [array]){Stop-TCError '线路来源锚点记录无效。'}
        $anchorPath=[string](Get-TCProperty $record 'SourceManifestPath' '')
        if(-not $anchorPath){
            # Older SchemaVersion 2 records omitted the original path. Only
            # explicit lineage and the standard original location may recover it,
            # and every candidate must match the already recorded manifest hash.
            $candidates=@($Node.manifestPath,(Join-Path (Join-Path (Join-Path $store 'nodes') $Node.id) 'manifest.json'))
            foreach($aliasId in @($record.AliasIds)){
                $aliasNodes=@($Index.nodes|Where-Object {$_.id -ceq $aliasId})
                if($aliasNodes.Count -ne 1 -or -not $aliasNodes[0].manifestPath){continue}
                $am=Read-AutoJson (Resolve-AutoPath $aliasNodes[0].manifestPath)
                if((Get-TCProperty $am 'AutoTransportSourceNodeId' '') -ceq $Node.id){$candidates+=,[string](Get-TCProperty $am 'AutoTransportSourceManifestPath' '')}
            }
            foreach($p in @($record.Profiles)){
                $mp=Resolve-AutoPath $p.ManifestPath
                if((Get-AutoHash $mp) -ine $p.ManifestSHA256){Stop-TCError '线路 profile manifest 完整性核验失败。'}
                $pm=Read-AutoJson $mp
                $candidates+=,[string](Get-TCProperty $pm 'TCSourceManifestPath' '')
            }
            $matches=@()
            foreach($candidate in @($candidates|Where-Object {$_}|Select-Object -Unique)){
                $path=Get-TCFullPath $candidate;Assert-TCNoReparse $path
                if([IO.File]::Exists($path) -and (Get-AutoHash $path) -ieq $record.SourceManifestSHA256){$matches+=,$path}
            }
            if($matches.Count -ne 1){Stop-TCError '无法唯一核验原线路锚点，请核对原资料。'}
            $anchorPath=$matches[0]
        }
        $anchorPath=Resolve-AutoPath $anchorPath
        if((Get-AutoHash $anchorPath) -ine $record.SourceManifestSHA256){Stop-TCError '原线路 manifest 锚点发生变化。'}
        $anchorNode=Copy-LineObject $Node;$anchorNode.manifestPath=$anchorPath
        $source=Read-AutoNode $anchorNode
        if($source.Manifest.CandidateSHA256 -ine $record.SourceConfigSHA256 -or $source.Manifest.ProbeSHA256 -ine $record.SourceProbeSHA256){Stop-TCError '原线路配置或 probe 锚点发生变化。'}
        foreach($key in @('ServerPublicKey','ClientPublicKey')){if($record.$key -cne $source.Manifest.$key){Stop-TCError '原线路锚点身份不一致。'}}
        if((ConvertTo-AutoAddress $record.ClientAddress) -cne (ConvertTo-AutoAddress $source.Manifest.ClientAddress)){Stop-TCError '原线路锚点地址不一致。'}
        if(-not (Test-TCSamePath $Node.manifestPath $anchorPath)){
            # A CT commit may move the legacy pointer, but may not replace the
            # provenance anchor. Accept exact registered immutable references only.
            $profiles=@((@($record.Profiles)+@(Get-TCProperty $record 'PreviousProfiles' @()))|Where-Object {Test-TCSamePath $_.ManifestPath $Node.manifestPath})
            if($profiles.Count -ne 1){Stop-TCError '当前节点引用不是该线路已登记的 profile。'}
            $null=Read-LineProfileSource $profiles[0] $Node.id -Stored
        }
        return $source
    }
    function Get-LineGroups {
        param($Index)
        $sources=@{};$groups=@{};$aliasMap=@{};$eligible=@{}
        foreach($n in @($Index.nodes)){
            $groups[$n.id]=@();$aliasMap[$n.id]=$n.id
            if(-not $n.manifestPath){continue}
            try{$sources[$n.id]=Read-LineAnchoredSource $n $Index}catch{continue}
        }
        foreach($n in @($Index.nodes)){
            if(-not $sources.ContainsKey($n.id)){continue}
            $s=$sources[$n.id];$parent=[string](Get-TCProperty $s.Manifest 'AutoTransportSourceNodeId' '')
            if(-not $parent -or $parent -ceq $n.id -or -not $sources.ContainsKey($parent)){continue}
            $original=$sources[$parent]
            if(Get-TCProperty $original.Manifest 'AutoTransportSourceNodeId'){continue}
            try{
                if((Get-LineMode $s) -cne 'Tcp' -or (Get-LineMode $original) -cne 'Udp'){continue}
                if((Get-TCProperty $s.Manifest 'SourceConfigSHA256' '') -ine $original.Manifest.CandidateSHA256){continue}
                if(-not (Test-TCSamePath (Get-TCProperty $s.Manifest 'AutoTransportSourceManifestPath' '') $original.ManifestPath)){continue}
                foreach($key in @('ServerPublicKey','ClientPublicKey','ServerEndpoint')){
                    if([string]$s.Manifest.$key -cne [string]$original.Manifest.$key){throw 'Binding mismatch'}
                }
                if((ConvertTo-AutoAddress $s.Manifest.ClientAddress) -cne (ConvertTo-AutoAddress $original.Manifest.ClientAddress)){continue}
                $b=Find-AutoServer $original;$envelope=Get-LineEnvelope $s $b $original
                if(-not $envelope -or (Get-TCProperty $s.Manifest 'TCPBindingDigest' '') -cne (Get-AutoDigest $envelope)){continue}
                if((Get-LinePolicyDigest $s) -cne (Get-LinePolicyDigest $original)){continue}
                if(-not $eligible.ContainsKey($parent)){$eligible[$parent]=@()}
                $eligible[$parent]+=[pscustomobject]@{Source=$s;Digest=(Get-AutoDigest $envelope)}
            }catch{continue}
        }
        foreach($parent in @($eligible.Keys)){
            # Conflicting TCP parameter sets have no automatic winner.
            if(@($eligible[$parent]|ForEach-Object {$_.Digest}|Select-Object -Unique).Count -ne 1){continue}
            foreach($match in @($eligible[$parent]|Sort-Object {$_.Source.Node.id})){
                $alias=$match.Source.Node.id;$groups[$parent]+=,$match.Source;$aliasMap[$alias]=$parent
            }
        }
        [pscustomobject]@{Sources=$sources;Groups=$groups;Aliases=$aliasMap}
    }
    function New-LineProfileRecord {
        param($Source,[string]$Mode,[int]$Revision=0)
        [pscustomobject][ordered]@{Id=$Mode;Mode=$Mode;ManifestPath=$Source.ManifestPath;CandidateSHA256=$Source.Manifest.CandidateSHA256;ProbeSHA256=$Source.Manifest.ProbeSHA256;ManifestSHA256=$Source.ManifestHash;Revision=$Revision;PreparationState='SyntaxValidated';Validation=$null;SourceNodeId=$Source.Node.id}
    }
    function Read-LineProfileSource {
        param($Profile,[string]$LineId,[switch]$Stored)
        if($Profile.Id -cnotin @('Udp','Tcp') -or $Profile.Mode -cne $Profile.Id){Stop-TCError '线路 profile 标识无效。'}
        $p=Resolve-AutoPath $Profile.ManifestPath
        if($Stored -and -not (Test-TCPathWithin $p (Join-Path (Join-Path (Join-Path $store 'lines') $LineId) 'profiles'))){Stop-TCError '线路 profile 引用越出线路目录。'}
        if((Get-AutoHash $p) -ine $Profile.ManifestSHA256){Stop-TCError '线路 profile manifest 完整性核验失败。'}
        $n=[pscustomobject]@{id=$LineId;kind='wireguard';endpoint=$node.endpoint;manifestPath=$p}
        $s=Read-AutoNode $n
        if($Stored){
            $revisionRoot=Split-Path $p -Parent
            foreach($path in @($s.Manifest.CandidatePath,$s.Manifest.ProbePath)){
                if(-not (Test-TCPathWithin (Get-TCFullPath $path) $revisionRoot)){Stop-TCError 'profile 资产越出不可变目录。'}
            }
            if((Get-TCProperty $s.Manifest 'TCLineId' '') -cne $LineId -or (Get-TCProperty $s.Manifest 'TCProfileId' '') -cne $Profile.Id){Stop-TCError 'profile manifest 线路绑定无效。'}
        }
        if($s.Manifest.CandidateSHA256 -ine $Profile.CandidateSHA256 -or $s.Manifest.ProbeSHA256 -ine $Profile.ProbeSHA256 -or (Get-LineMode $s) -cne $Profile.Id){Stop-TCError 'profile 配置 hash 或连接方式不一致。'}
        foreach($key in @('ServerPublicKey','ClientPublicKey','ServerEndpoint')){if($s.Manifest.$key -cne $source.Manifest.$key){Stop-TCError 'profile 服务器/设备绑定无效。'}}
        if((ConvertTo-AutoAddress $s.Manifest.ClientAddress) -cne (ConvertTo-AutoAddress $source.Manifest.ClientAddress)){Stop-TCError 'profile 地址绑定无效。'}
        if((Get-LinePolicyDigest $s $source) -cne (Get-LinePolicyDigest $source)){Stop-TCError 'profile 用途或规则发生漂移。'}
        if($Profile.Id -ceq 'Tcp'){
            $null=Get-AutoTcpSettings $s
            $bindingDigest=Get-TCProperty $s.Manifest 'TCPBindingDigest'
            if($bindingDigest){
                $boundInfo=Get-LineEnvelope $s (Find-AutoServer $source) $source
                if(-not $boundInfo -or (Get-AutoDigest $boundInfo) -cne $bindingDigest){Stop-TCError 'profile TCP envelope binding 完整性无效。'}
            }
        }
        if($Profile.Validation -and (Get-TCProperty $Profile.Validation 'CandidateSHA256' '') -ine $Profile.CandidateSHA256){Stop-TCError '验证证据不属于 profile 配置 hash。'}
        $s
    }
    function Read-LineRecord {
        $path=Join-Path $lineRoot 'line.json'
        if(-not [IO.File]::Exists($path)){return $null}
        $record=Read-AutoJson (Resolve-AutoPath $path)
        if($record.SchemaVersion -ne 2 -or $record.LineId -cne $node.id -or $record.SourceNodeId -cne $node.id -or $record.Revision -lt 1 -or $record.Profiles -isnot [array]){Stop-TCError '线路元数据版本或来源无效。'}
        if($record.SourceConfigSHA256 -ine $source.Manifest.CandidateSHA256 -or $record.SourceManifestSHA256 -ine $source.ManifestHash -or $record.SourceProbeSHA256 -ine $source.Manifest.ProbeSHA256){Stop-TCError '线路来源资料发生变化，需重新核对。'}
        if((Get-LineDigest @($record.AliasIds|Sort-Object)) -cne (Get-LineDigest @($aliases|Sort-Object))){Stop-TCError '线路 alias 关系发生变化，需重新核对。'}
        $ids=@{}
        foreach($p in @($record.Profiles)){
            if($ids.ContainsKey($p.Id)){Stop-TCError '线路包含重复 profile。'};$ids[$p.Id]=$true
            $null=Read-LineProfileSource $p $node.id -Stored
        }
        if($record.PreferredProfileId){if(-not $ids.ContainsKey($record.PreferredProfileId)){Stop-TCError '线路推荐 profile 不存在。'}}
        elseif((Get-TCProperty (Get-TCProperty $record 'Recommendation') 'Status' '') -notin @('Unavailable','Inconclusive','Blocked','UserChoice') -and -not ($record.PSObject.Properties['SavedConnectionPreference'] -and $null -eq $record.SavedConnectionPreference)){Stop-TCError '线路缺少明确的默认方式或无推荐原因。'}
        $record
    }
    function New-LineRecord {
        [pscustomobject][ordered]@{SchemaVersion=2;LineId=$node.id;SourceNodeId=$node.id;Name=$node.name;Endpoint=$node.endpoint;AliasIds=@($aliases);Revision=0;Profiles=@();PreferredProfileId=(Get-LineMode $source);PreferenceSource='ConfiguredDefault';PreferenceUpdatedAt=$null;SavedConnectionPreference=$null;Recommendation=$null;SourceManifestPath=$source.ManifestPath;SourceManifestSHA256=$source.ManifestHash;SourceConfigSHA256=$source.Manifest.CandidateSHA256;SourceProbeSHA256=$source.Manifest.ProbeSHA256;ServerPublicKey=$source.Manifest.ServerPublicKey;ClientPublicKey=$source.Manifest.ClientPublicKey;ClientAddress=(ConvertTo-AutoAddress $source.Manifest.ClientAddress)}
    }
    function New-LineSavedPreference {
        param($Record,[string]$SelectedId,$Decision,[switch]$Manual,[switch]$Historical,[switch]$Configured,[DateTimeOffset]$At=[DateTimeOffset]::UtcNow)
        $selected=@($Record.Profiles|Where-Object Id -ceq $SelectedId)
        if($selected.Count -ne 1){Stop-TCError '默认方式不属于已准备的线路。'}
        $s=Read-LineProfileSource $selected[0] $node.id -Stored
        $selection=Import-Module (Join-Path (Split-Path (Split-Path $FallbackWg -Parent) -Parent) 'ProtocolSelection.psm1') -PassThru -DisableNameChecking
        & $selection {param($Id,$Profile,$Manifest,$Profiles,$Recommendation,$Context,$Manual,$Historical,$Configured,$Revision,$At)
            New-TCSavedConnectionPreference -LineId $Id -Profile $Profile -Manifest $Manifest -Profiles $Profiles -Recommendation $Recommendation -NetworkContext $Context -ManualChoice:$Manual -Historical:$Historical -ConfiguredDefault:$Configured -LineRevision $Revision -Now $At
        } $node.id $selected[0] $s.Manifest @($Record.Profiles) $Decision $TransportInfo ([bool]$Manual) ([bool]$Historical) ([bool]$Configured) ([long]$Record.Revision+1) $At
    }
    function Get-LineSavedPreference {
        param($Record)
        # Presence of the new field is authoritative, including explicit null.
        # Never repair a tampered record by falling back to its old recommendation.
        if($Record.PSObject.Properties['SavedConnectionPreference']){return $Record.SavedConnectionPreference}
        $r=Get-TCProperty $Record 'Recommendation';$sourceKind=[string](Get-TCProperty $Record 'PreferenceSource' '')
        # Pre-saved-default releases recorded a real configured protocol without
        # a recommendation. Preserve only that explicit choice, with immutable
        # profile/identity binding and its own origin (never fake a manual choice).
        if($Record.Revision -ge 1 -and $sourceKind -ceq 'ConfiguredDefault' -and -not $r -and $Record.PreferredProfileId -ceq (Get-LineMode $source)){
            $selected=@($Record.Profiles|Where-Object Id -ceq $Record.PreferredProfileId)
            if($selected.Count -eq 1 -and $selected[0].PreparationState -in @('Ready','SyntaxValidated','Prepared')){
                $at=[DateTimeOffset]([IO.File]::GetLastWriteTimeUtc((Join-Path $lineRoot 'line.json')))
                return New-LineSavedPreference $Record $Record.PreferredProfileId $null -Configured -Historical -At $at
            }
        }
        $at=[DateTimeOffset]::MinValue;$checked=[DateTimeOffset]::MinValue
        if(-not $r -or $r.SchemaVersion -ne 1 -or $r.LineId -cne $node.id -or $r.Source -cne $sourceKind -or -not [DateTimeOffset]::TryParse([string](Get-TCProperty $Record 'PreferenceUpdatedAt' ''),[ref]$at) -or $at -gt [DateTimeOffset]::UtcNow -or -not [DateTimeOffset]::TryParse([string](Get-TCProperty $r 'CheckedAtUtc' ''),[ref]$checked) -or $checked -gt $at.AddMinutes(1)){return $null}
        try{
            if($sourceKind -eq 'UserChoice'){
                $p=@($Record.Profiles|Where-Object Id -ceq $Record.PreferredProfileId)
                if($r.Status -cne 'UserChoice' -or $r.RecommendedProfileId -or $r.PreferredProfileId -cne $Record.PreferredProfileId -or $r.RequestedProfileId -cne $Record.PreferredProfileId -or $p.Count -ne 1 -or $r.CandidateSHA256 -cne $p[0].CandidateSHA256){return $null}
                $selection=Import-Module (Join-Path (Split-Path (Split-Path $FallbackWg -Parent) -Parent) 'ProtocolSelection.psm1') -PassThru -DisableNameChecking
                $manualOrigin=& $selection {param($Profiles,$Decision,$At) $replayed=Get-TCProtocolRecommendation -Profiles $Profiles -LineId $Decision.LineId -RequestedMode $Decision.RequestedProfileId -NetworkContext ([pscustomobject]@{Fingerprint=$Decision.NetworkFingerprint}) -Now $At -RecordedNetwork;[bool]($replayed.Status -ceq 'UserChoice' -and $replayed.PolicyVersion -ceq $Decision.PolicyVersion -and $replayed.EvidenceDigest -ceq $Decision.EvidenceDigest)} @($Record.Profiles) $r $checked
                if(-not $manualOrigin){return $null}
                return New-LineSavedPreference $Record $Record.PreferredProfileId $null -Manual -Historical -At $at
            }
            if($sourceKind -notin @('Reachability','PolicyDefault','Performance','Stability') -or $r.RecommendedProfileId -cne $Record.PreferredProfileId){return $null}
            New-LineSavedPreference $Record $Record.PreferredProfileId $r -Historical -At $at
        }catch{return $null}
    }
    function Get-LineServerConnectionState {
        $selection=Import-Module (Join-Path (Split-Path (Split-Path $FallbackWg -Parent) -Parent) 'ProtocolSelection.psm1') -PassThru -DisableNameChecking
        $registryPath=Join-Path $dataRoot 'servers\registry.json';$registry=$null
        if([IO.File]::Exists($registryPath)){$registry=Read-AutoJson (Resolve-AutoPath $registryPath)}
        & $selection {param($Id,$Aliases,$Key,$Registry) Get-TCLineServerBindingState -LineId $Id -AliasIds $Aliases -ServerPublicKey $Key -Registry $Registry} $node.id @($aliases) $source.Manifest.ServerPublicKey $registry
    }
    function Get-LineView {
        $record=Read-LineRecord
        if(-not $record){
            $profiles=@(New-LineProfileRecord $source (Get-LineMode $source))
            if($aliases.Count){$profiles+=,(New-LineProfileRecord $model.Groups[$node.id][0] 'Tcp')}
            $record=New-LineRecord;$record.Profiles=@($profiles)
        }
        $serverState=Get-LineServerConnectionState
        $saved=Get-LineSavedPreference $record;$defaultVerified=$false
        if($saved){try{
            $p=@($record.Profiles|Where-Object Id -ceq $saved.ProfileId)
            if($p.Count -eq 1){$s=Read-LineProfileSource $p[0] $node.id -Stored;$selection=Import-Module (Join-Path (Split-Path (Split-Path $FallbackWg -Parent) -Parent) 'ProtocolSelection.psm1') -PassThru -DisableNameChecking
                $defaultVerified=& $selection {param($v,$id,$p,$m)Test-TCSavedConnectionPreference $v $id $p $m} $saved $node.id $p[0] $s.Manifest
            }
        }catch{$defaultVerified=$false}}
        [pscustomobject][ordered]@{HasNetworkPolicyRollback=[bool](Get-TCProperty $record NetworkPolicyMigration);ServerConnectionBlock=$serverState.Code;ServerConnectionMessage=$serverState.Message;ServerBindings=@($serverState.NavigationBindings);LineId=$node.id;Name=$node.name;Endpoint=$node.endpoint;SourceNodeId=$node.id;AliasIds=@($aliases);Revision=$record.Revision;Profiles=@($record.Profiles);PreferredProfileId=$record.PreferredProfileId;PreferenceSource=(Get-TCProperty $record 'PreferenceSource' 'ConfiguredDefault');PreferenceUpdatedAt=(Get-TCProperty $record 'PreferenceUpdatedAt');SavedConnectionPreference=$saved;DefaultVerified=[bool]$defaultVerified;Recommendation=(Get-TCProperty $record 'Recommendation');ServerPublicKey=$source.Manifest.ServerPublicKey;ClientPublicKey=$source.Manifest.ClientPublicKey;ClientAddress=(ConvertTo-AutoAddress $source.Manifest.ClientAddress);SourceManifestPath=(Get-TCProperty $record 'SourceManifestPath' $source.ManifestPath)}
    }
    function Write-LineRecord {
        param($Record)
        $target=Join-Path $lineRoot 'line.json'
        $temp=Join-Path $lineRoot ('.metadata-'+[guid]::NewGuid().ToString('N')+'.json')
        try{
            Write-TCAtomicJson $temp $Record -NewOnly;Set-TCPrivateAcl $temp
            if([IO.File]::Exists($target)){[IO.File]::Replace($temp,$target,[NullString]::Value)}
            else{[IO.File]::Move($temp,$target)}
        }finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
    }
    function New-LineDirectory {
        param([string]$Path)
        Assert-TCNoReparse $Path
        if(-not [IO.Directory]::Exists($Path)){New-TCPrivateDirectory $Path;$created.Add($Path)}
    }
    function Assert-LineInputs {
        param($Inputs)
        foreach($s in @($Inputs)){
            if((Get-AutoHash $s.ManifestPath) -ine $s.ManifestHash -or (Get-AutoHash $s.Manifest.CandidatePath) -ine $s.Manifest.CandidateSHA256 -or (Get-AutoHash $s.Manifest.ProbePath) -ine $s.Manifest.ProbeSHA256){Stop-TCError '准备期间来源资料发生变化，请重试。'}
        }
    }
    function New-LineImmutableProfile {
        param($InputSource,[string]$Mode,[int]$Revision,$Envelope,$ProbeBinding)
        New-LineDirectory (Join-Path $lineRoot 'profiles')
        New-LineDirectory (Join-Path $lineRoot '.staging')
        $token=[guid]::NewGuid().ToString('N')
        $stage=Join-Path (Join-Path $lineRoot '.staging') $token
        $final=Join-Path (Join-Path $lineRoot 'profiles') ($Mode+'-r'+$Revision+'-'+$token)
        New-TCPrivateDirectory $stage;$owned.Add($stage)
        $transport=if($Mode -ceq 'Tcp'){if($Envelope){$Envelope.Transport}else{Get-AutoTcpSettings $InputSource}}else{$null}
        # Transport construction adds dictionaries. Normalize before adding
        # dial fields, otherwise ETS note properties disappear on JSON output.
        $cfg=Copy-LineObject (Set-TCConfigurationTransport (Copy-LineObject $InputSource.Config) $transport)
        $probe=Copy-LineObject (Set-TCConfigurationTransport (Copy-LineObject $InputSource.Probe) $transport)
        if($Envelope -and $Envelope.PSObject.Properties['MTU']){
            foreach($value in @($cfg,$probe)){
                $hk=@($value.endpoints|Where-Object tag -ceq 'hk')
                if($hk.Count -ne 1){Stop-TCError '无法将服务器 MTU 绑定至唯一 WireGuard 端点。'}
                $hk[0]|Add-Member NoteProperty mtu ([int]$Envelope.MTU) -Force
                foreach($tun in @($value.inbounds|Where-Object type -ceq 'tun')){$tun|Add-Member NoteProperty mtu ([int]$Envelope.MTU) -Force}
            }
        }
        if($ProbeBinding){
            # Shipped legacy probes resolve application DNS through dns-hk and
            # have no bootstrap server. Add the main configuration's verified
            # direct DNS to the NEW probe copy, retaining its tunnel DNS final.
            if(@($probe.dns.servers|Where-Object tag -ceq 'dns-direct').Count -eq 0){
                $bootstrap=@($cfg.dns.servers|Where-Object tag -ceq 'dns-direct')
                if($bootstrap.Count -ne 1 -or (Get-TCProperty $bootstrap[0] 'type') -cne 'udp' -or (Get-TCProperty $bootstrap[0] 'detour') -or (Get-TCProperty $bootstrap[0] 'server') -cne $ProbeBinding.BootstrapDns.Server){Stop-TCError '原配置缺少可沿用的直接 bootstrap DNS。'}
                $probe.dns.servers=@($probe.dns.servers)+@(Copy-LineObject $bootstrap[0])
            }
            foreach($value in @($cfg,$probe)){
                $outer=@(if($Mode -ceq 'Tcp'){$value.outbounds|Where-Object tag -ceq 'tc-transport'}else{$value.endpoints|Where-Object tag -ceq 'hk'})
                $dns=@($value.dns.servers|Where-Object tag -ceq 'dns-direct')
                if($outer.Count -ne 1 -or $dns.Count -ne 1 -or (Get-TCProperty $outer[0] 'detour') -or (Get-TCProperty $dns[0] 'detour')){Stop-TCError '无法为该连接方式绑定实际外层和 bootstrap DNS。'}
                foreach($dial in @($outer[0],$dns[0])){
                    foreach($field in @('inet6_bind_address','network_strategy','network_type','fallback_network_type','tcp_multi_path','routing_mark','netns')){if(Get-TCProperty $dial $field){Stop-TCError '已有高级拨号选项不支持自动指定网卡。'}}
                    $dial|Add-Member NoteProperty bind_interface $ProbeBinding.InterfaceName -Force
                    if([object]::ReferenceEquals($value,$probe)){$dial|Add-Member NoteProperty inet4_bind_address $ProbeBinding.LocalAddress -Force}
                    else{$dial.PSObject.Properties.Remove('inet4_bind_address')}
                }
                $outer[0]|Add-Member NoteProperty domain_resolver ([pscustomobject]@{server='dns-direct';strategy='ipv4_only'}) -Force
                if($Mode -ceq 'Tcp'){
                    $inner=@($value.endpoints|Where-Object tag -ceq 'hk')[0]
                    foreach($field in @('bind_interface','inet4_bind_address')){$inner.PSObject.Properties.Remove($field)}
                }
            }
        }
        foreach($entry in @($probe.inbounds)){
            if(@(Get-TCProperty $entry 'users' @()).Count){continue}
            $bytes=New-Object byte[] 32;$rng=[Security.Cryptography.RandomNumberGenerator]::Create()
            try{$rng.GetBytes($bytes);$secret=[Convert]::ToBase64String($bytes)}finally{$rng.Dispose();[Array]::Clear($bytes,0,$bytes.Length)}
            $entry|Add-Member NoteProperty users @([pscustomobject]@{username='tradechannel-probe';password=$secret}) -Force;$secret=$null
        }
        $profileEngine=Resolve-AutoPath (Join-Path (Split-Path $FallbackWg -Parent) 'sing-box.exe')
        $profileEngineHash=Get-AutoHash $profileEngine
        foreach($asset in @([pscustomobject]@{Name='dual-mode.json';Value=$cfg},[pscustomobject]@{Name='probe.json';Value=$probe})){
            $path=Join-Path $stage $asset.Name;Write-TCAtomicJson $path $asset.Value -NewOnly -NoBom;Set-TCPrivateAcl $path;Test-TCCheckedConfiguration $profileEngine $path
        }
        $m=Copy-LineObject $InputSource.Manifest
        foreach($field in @('PreviousManifestPath','UpgradedFrom','AutoTransportSourceNodeId','AutoTransportSourceManifestPath','Transport','TransportSettings','TCPBindingDigest','AutoTransportRemoteOwnerId','AutoTransportRemoteNodeId')){$m.PSObject.Properties.Remove($field)}
        $updates=[ordered]@{node_id=$node.id;nodeGuid=$node.id;TCManagedNodeId=$node.id;TCLineId=$node.id;TCProfileId=$Mode;TCProfileRevision=$Revision;CreatedAt=[DateTimeOffset]::UtcNow.ToString('o');Status='CandidateOnly';CandidatePath=(Join-Path $final 'dual-mode.json');ProbePath=(Join-Path $final 'probe.json');CandidateSHA256=(Get-AutoHash (Join-Path $stage 'dual-mode.json'));ProbeSHA256=(Get-AutoHash (Join-Path $stage 'probe.json'));TCSourceManifestPath=$source.ManifestPath;SourceConfigSHA256=$source.Manifest.CandidateSHA256;SyntaxValidated=$true;DeploymentApproved=$false;ServerForwardingVerified=$false;ProcessRoutingVerified=$false;IndependentGuardVerified=$false;ProbeRequiresInactiveIdentity=$true}
        if($transport){$updates.Transport=$transport;$updates.TransportSettings=$transport}
        if($Envelope){$updates.TCPBindingDigest=Get-AutoDigest $Envelope;$updates.AutoTransportRemoteOwnerId=$Envelope.RemoteOwnerId;$updates.AutoTransportRemoteNodeId=$Envelope.NodeId}
        if($Envelope -and $Envelope.PSObject.Properties['MTU']){$updates.TCServerMTU=[int]$Envelope.MTU}
        $updates.EnginePath=$profileEngine;$updates.EngineSHA256=$profileEngineHash;$updates.WgPath=$FallbackWg
        if($ProbeBinding){$updates.ProbeBinding=$ProbeBinding;$updates.DirectDns=$ProbeBinding.BootstrapDns.Server;$updates.NetworkPolicy=[pscustomobject]@{SchemaVersion=1;Kind='PhysicalInterface';InterfaceId=$ProbeBinding.InterfaceId;InterfaceName=$ProbeBinding.InterfaceName;AddressPolicy='CurrentIPv4';Source='TradeChannel.0.16.4'}}
        foreach($key in $updates.Keys){$m|Add-Member NoteProperty $key $updates[$key] -Force}
        $mp=Join-Path $stage 'manifest.json';Write-TCAtomicJson $mp $m -NewOnly;Set-TCPrivateAcl $mp
        Assert-LineInputs @($source,$InputSource)
        Assert-TCNoReparse $final;[IO.Directory]::Move($stage,$final);$owned.Add($final)
        [pscustomobject][ordered]@{Id=$Mode;Mode=$Mode;ManifestPath=(Join-Path $final 'manifest.json');CandidateSHA256=$m.CandidateSHA256;ProbeSHA256=$m.ProbeSHA256;ManifestSHA256=(Get-AutoHash (Join-Path $final 'manifest.json'));Revision=$Revision;PreparationState='SyntaxValidated';Validation=$null;SourceNodeId=$node.id}
    }
    function Get-LineCurrentProfile {
        param($View)
        $rtPath=Join-Path $dataRoot 'runtime.json'
        if(-not [IO.File]::Exists($rtPath)){return $null}
        $rt=Read-AutoJson (Resolve-AutoPath $rtPath)
        if([string](Get-TCProperty $rt 'State' '') -cnotin @('Running','Connected')){return $null}
        $mp=[string](Get-TCProperty $rt 'ManifestPath' '')
        # A saved preference or deployment without a running session is not current.
        foreach($p in @($View.Profiles)){if(Test-TCSamePath $mp $p.ManifestPath){return $p.Id}}
        foreach($s in @($source)+@($model.Groups[$node.id])){if(Test-TCSamePath $mp $s.ManifestPath){return Get-LineMode $s}}
        if($View.Revision -lt 1 -or (Get-TCProperty $rt 'CleanupError' $false)){return $null}
        # CT runs an approved clone, not the immutable registered manifest. This
        # is a conservative record association; the bridge verifies live identity.
        try{
            $clonePath=Resolve-AutoPath $mp
            $transactions=Get-TCFullPath (Join-Path $dataRoot 'connection-transactions');Assert-TCNoReparse $transactions
            if(-not (Test-TCSamePath (Split-Path $clonePath -Parent) $transactions)){return $null}
            $cloneHash=Get-AutoHash $clonePath;$clone=Read-AutoJson $clonePath
            $tx=[string](Get-TCProperty $clone 'TCTransactionId' '')
            if($tx -cnotmatch '^[0-9a-f]{32}$' -or -not (Test-TCSamePath $clonePath (Join-Path $transactions ($tx+'-approved.manifest')))){return $null}
            if((Get-TCProperty $clone 'TCLineId' '') -cne $View.LineId -or (Get-TCProperty $clone 'DeploymentApproved') -isnot [bool] -or $clone.DeploymentApproved -ne $true){return $null}
            $profileId=[string](Get-TCProperty $clone 'TCProfileId' '')
            $matches=@($View.Profiles|Where-Object {$_.Id -ceq $profileId -and (Test-TCSamePath $_.ManifestPath (Get-TCProperty $clone 'TCProfileManifestPath' ''))})
            if($matches.Count -ne 1){return $null}
            $profile=$matches[0];$profileSource=Read-LineProfileSource $profile $View.LineId -Stored
            if((Get-TCProperty $clone 'CandidateSHA256' '') -ine $profile.CandidateSHA256 -or (Get-AutoHash $profileSource.Manifest.CandidatePath) -ine $profile.CandidateSHA256){return $null}
            # Check the complete cloned binding (paths, server/device keys,
            # address, policy and hashes), permitting only CT's three additions.
            $normalized=Copy-LineObject $clone
            foreach($field in @('TCTransactionId','TCProfileManifestPath')){$normalized.PSObject.Properties.Remove($field)}
            $normalized.DeploymentApproved=$profileSource.Manifest.DeploymentApproved
            if((Get-LineDigest $normalized) -cne (Get-LineDigest $profileSource.Manifest)){return $null}
            foreach($pair in @(@('LineId',$View.LineId),@('ProfileId',$profileId),@('CandidateSHA256',$profile.CandidateSHA256))){
                if($rt.PSObject.Properties[$pair[0]] -and [string]$rt.($pair[0]) -ine [string]$pair[1]){return $null}
            }
            if($rt.PSObject.Properties['ConfigPath'] -and -not (Test-TCSamePath $rt.ConfigPath $profileSource.Manifest.CandidatePath)){return $null}
            $deploymentPath=Join-Path $dataRoot 'deployment.json'
            if([IO.File]::Exists($deploymentPath)){
                $dep=Read-AutoJson (Resolve-AutoPath $deploymentPath)
                if(-not (Test-TCSamePath (Get-TCProperty $dep 'ManifestPath' '') $clonePath) -or -not (Test-TCSamePath (Get-TCProperty $dep 'ProfileManifestPath' '') $profile.ManifestPath) -or (Get-TCProperty $dep 'LineId' '') -cne $View.LineId -or (Get-TCProperty $dep 'ProfileId' '') -cne $profileId -or (Get-TCProperty $dep 'CandidateSHA256' '') -ine $profile.CandidateSHA256){return $null}
                if($dep.PSObject.Properties['TransactionId'] -and $dep.TransactionId -cne $tx){return $null}
            }
            if((Get-AutoHash $clonePath) -ine $cloneHash){return $null}
            return $profileId
        }catch{return $null}
    }
    function Get-LineSaved {
        param($View,$Binding)
        $saved=@()
        foreach($p in @($View.Profiles|Where-Object {$_.Id -ceq 'Tcp'})){
            if($View.Revision -gt 0){$s=Read-LineProfileSource $p $node.id -Stored}else{$s=$source;if($aliases.Count){$s=$model.Groups[$node.id][0]}}
            $info=Get-LineEnvelope $s $Binding $source
            if($info){$saved+=,[pscustomobject]@{Info=$info;Kind=$(if($View.Revision -gt 0){'LineProfile'}elseif($aliases.Count){'AutoTransportSibling'}else{'Manifest'});Transport=$info.Transport}}
        }
        if(-not $saved.Count){
            $t=Get-AutoTcpSettings $source
            if($t){$info=Get-LineEnvelope $source $Binding $source;$saved+=,[pscustomobject]@{Info=$info;Kind='Manifest';Transport=$t}}
        }
        if($saved.Count){return $saved[0]};return $null
    }
    try{
        $dataRoot=Resolve-AutoPath $Root -Directory
        $store=Resolve-AutoPath (Join-Path $dataRoot 'Product') -Directory
        $index=Read-AutoIndex $store
        $model=Get-LineGroups $index
        if($Operation -ceq 'Cards'){
            $cards=@()
            foreach($n in @($index.nodes)){
                if($model.Aliases[$n.id] -cne $n.id){continue}
                $node=$n;$lineRoot=Join-Path (Join-Path $store 'lines') $node.id;$aliases=@($model.Groups[$node.id]|ForEach-Object {$_.Node.id})
                $source=$null;$view=$null
                if($model.Sources.ContainsKey($node.id)){$source=$model.Sources[$node.id];$view=Get-LineView}
                elseif([IO.File]::Exists((Join-Path $lineRoot 'line.json'))){Stop-TCError '已登记线路的来源无法核验。'}
                $profiles=@();$preferred=$null;$current=$null
                if($view){$profiles=@($view.Profiles);$preferred=$view.PreferredProfileId;$current=Get-LineCurrentProfile $view}
                $hasTcp=@($profiles|Where-Object {$_.Id -ceq 'Tcp'}).Count -gt 0
                $cards+=,[pscustomobject][ordered]@{id=$node.id;name=$node.name;endpoint=$node.endpoint;manifestPath=$node.manifestPath;status=$node.status;kind=$node.kind;registeredAt=$node.registeredAt;LineId=$node.id;Revision=(Get-TCProperty $view 'Revision' 0);Profiles=@($profiles);AliasIds=@($aliases);PreferredProfileId=$preferred;PreferenceSource=(Get-TCProperty $view 'PreferenceSource' 'ConfiguredDefault');SavedConnectionPreference=(Get-TCProperty $view 'SavedConnectionPreference');DefaultVerified=[bool](Get-TCProperty $view 'DefaultVerified' $false);ServerConnectionBlock=(Get-TCProperty $view 'ServerConnectionBlock');ServerConnectionMessage=(Get-TCProperty $view 'ServerConnectionMessage');Recommendation=(Get-TCProperty $view 'Recommendation');SourceManifestPath=(Get-TCProperty $view 'SourceManifestPath');CurrentProfileId=$current;HasTcp=$hasTcp;MissingBackup=(-not $hasTcp)}
            }
            return $cards
        }
        $requestedId=ConvertTo-TCId $Id
        if(-not $model.Aliases.ContainsKey($requestedId)){Stop-TCError '找不到指定线路或 alias。'}
        $lineId=$model.Aliases[$requestedId]
        $node=@($index.nodes|Where-Object {$_.id -ceq $lineId})[0]
        $source=Read-LineAnchoredSource $node $index
        $lineRoot=Join-Path (Join-Path $store 'lines') $node.id
        Assert-TCNoReparse $lineRoot
        $aliases=@($model.Groups[$node.id]|ForEach-Object {$_.Node.id})
        $view=Get-LineView
        if($Operation -ceq 'Get'){return $view}
        if($Operation -ceq 'Profile'){
            $p=@($view.Profiles|Where-Object {$_.Id -ceq $ProfileId})
            if($p.Count -ne 1){Stop-TCError '线路尚未准备指定 profile。'};return $p[0]
        }
        if($Operation -cin @('Preparation','Saved')){
            $binding=Find-AutoServer $source;$saved=Get-LineSaved $view $binding
            if($Operation -ceq 'Saved'){if($saved){return $saved.Info};return $null}
            $remoteOwner=[string](Get-TCProperty $binding.Server 'RemoteOwnerId' (Get-TCProperty $source.Manifest 'AutoTransportRemoteOwnerId' (Get-TCProperty $source.Manifest 'RemoteOwnerId' '')))
            $remoteNode=[string](Get-TCProperty $binding.Server 'NodeId' (Get-TCProperty $source.Manifest 'AutoTransportRemoteNodeId' (Get-TCProperty $source.Manifest 'ServerNodeId' '')))
            if($saved -and $saved.Info){$remoteOwner=$saved.Info.RemoteOwnerId;$remoteNode=$saved.Info.NodeId}
            return [pscustomobject]@{Id=$node.id;Name=$node.name;DefaultServer=$source.Endpoint.address;ClientPublicKey=$source.Manifest.ClientPublicKey;ServerPublicKey=$source.Manifest.ServerPublicKey;ClientAddress=(ConvertTo-AutoAddress $source.Manifest.ClientAddress);RemoteOwnerId=$(if($remoteOwner){$remoteOwner}else{$null});RemoteNodeId=$(if($remoteNode){$remoteNode}else{$null});Active=[bool](Test-AutoActive $source);HasSettings=[bool]$saved;Connection=$binding.Connection;ServerId=$binding.ServerId;NeedsAuthentication=(-not [bool]($saved -and $saved.Info));SettingsSource=$(if($saved){$saved.Kind}else{'None'})}
        }
        $info=$null;$active=$false
        if($Operation -ceq 'Prepare'){$active=[bool](Test-AutoActive $source);$info=Assert-AutoEnvelope $TransportInfo $source (Find-AutoServer $source)}
        elseif($Operation -cnotin @('Register','Validation','Recommendation','Preference','RepairPreference','Binding','NetworkPlan','NetworkMigrate','NetworkRollbackPlan','NetworkRollback')){Stop-TCError '未知线路操作。'}
        # Validate before opening locks; then reload all immutable references under locks.
        $sessionLock=Open-TCNodeSessionLock $store
        $indexLock=Open-TCLock $store
        $index=Read-AutoIndex $store;$model=Get-LineGroups $index
        if(-not $model.Aliases.ContainsKey($requestedId) -or $model.Aliases[$requestedId] -cne $lineId){Stop-TCError '线路来源关系在准备期间变化。'}
        $node=@($index.nodes|Where-Object {$_.id -ceq $lineId})[0];$source=Read-LineAnchoredSource $node $index
        $aliases=@($model.Groups[$node.id]|ForEach-Object {$_.Node.id})
        New-LineDirectory (Join-Path $store 'lines');New-LineDirectory $lineRoot
        $lp=Join-Path $lineRoot '.line.lock';Assert-TCNoReparse $lp
        $lineLock=[IO.File]::Open($lp,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        Set-TCPrivateAcl $lp
        $record=Read-LineRecord
        if($Operation -ceq 'RepairPreference'){
            if(-not $record){return [pscustomobject]@{Code='NotApplicable';Repaired=$false}}
            $saved=Get-LineSavedPreference $record
            if([long]$record.Revision -ne [long](Get-TCProperty $TransportInfo ExpectedRevision -1) -or [string](Get-TCProperty $saved Digest '') -cne [string](Get-TCProperty $TransportInfo ExpectedDigest '')){Stop-TCError '[TC:PreferenceRevisionChanged] 默认或线路已变化，请刷新后重试。'}
            $selected=@($record.Profiles|Where-Object Id -ceq (Get-TCProperty $saved ProfileId ''))
            if($selected.Count -ne 1){return [pscustomobject]@{Code='PreferenceRepairNeedsSelection';Repaired=$false;Message='请选择已准备的协议，无需重新部署。'}}
            $selectedSource=Read-LineProfileSource $selected[0] $node.id -Stored
            $originalProfiles=@();$inputs=@($source,$selectedSource)
            foreach($p in @($record.Profiles)){
                $s=Read-LineProfileSource $p $node.id -Stored;$inputs+=,$s
                foreach($key in @('ServerPublicKey','ClientPublicKey','ClientAddress')){if((Get-TCProperty $s.Manifest $key '') -cne (Get-TCProperty $selectedSource.Manifest $key '')){Stop-TCError '原配置身份不能相互核验，默认未修改。'}}
                $originalProfiles+=,$p
            }
            $selection=Import-Module (Join-Path (Split-Path (Split-Path $FallbackWg -Parent) -Parent) 'ProtocolSelection.psm1') -PassThru -DisableNameChecking
            $repair=& $selection {param($s,$id,$p,$m,$all)Repair-TCSavedConnectionPreferenceSnapshot -Preference $s -LineId $id -Profile $p -Manifest $m -OriginalProfiles $all} $saved $node.id $selected[0] $selectedSource.Manifest $originalProfiles
            if(-not $repair.Repaired){$committed=$true;return $repair}
            Assert-LineInputs $inputs
            $backup=Join-Path $lineRoot ('preference-before-repair-'+$saved.Digest+'.json')
            if(-not [IO.File]::Exists($backup)){Write-TCAtomicJson $backup $saved -NewOnly;Set-TCPrivateAcl $backup}
            $record.SavedConnectionPreference=$repair.Preference
            $record|Add-Member NoteProperty PreferenceRepair ([pscustomobject]@{Code='MissingOriginManifestHash';AtUtc=[DateTimeOffset]::UtcNow.ToString('o');OldDigest=$saved.Digest;NewDigest=$repair.Preference.Digest}) -Force
            $record.Revision=[long]$record.Revision+1;Write-LineRecord $record;$committed=$true
            return $repair
        }
        if($Operation -in @('NetworkRollbackPlan','NetworkRollback')){
            $migration=Get-TCProperty $record NetworkPolicyMigration
            if(-not $migration -or $migration.SchemaVersion -ne 1){Stop-TCError '没有可回退的本机网络更新。'}
            $state=Get-LineServerConnectionState;if(-not $state.Allowed){Stop-TCError ('[TC:'+$state.Code+'] '+$state.Message)}
            if(Test-AutoActive $source){Stop-TCError '[TC:ActiveIdentity] 请断开这条线路后回退本机配置。'}
            $backup=Resolve-AutoPath $migration.BackupPath
            if(-not $backup.StartsWith((Join-Path $lineRoot 'network-policy-backups')+'\',[StringComparison]::OrdinalIgnoreCase) -or (Get-AutoHash $backup) -cne $migration.BackupSHA256){Stop-TCError '原网络版本备份无法核验。'}
            $before=Read-AutoJson $backup
            if($before.LineId -cne $record.LineId){Stop-TCError '回退资料不属于原线路。'}
            $wanted=[string]$migration.ProfileId
            $oldProfile=@($before.Profiles|Where-Object Id -ceq $wanted);$current=@($record.Profiles|Where-Object Id -ceq $wanted)
            if($oldProfile.Count -ne 1 -or $current.Count -ne 1 -or $current[0].ManifestSHA256 -cne $migration.NewManifestSHA256){Stop-TCError '当前版本已变化，不能使用这份网络回退记录。'}
            $oldSource=Read-LineProfileSource $oldProfile[0] $node.id -Stored
            $newSource=Read-LineProfileSource $current[0] $node.id -Stored
            $expiry=[DateTimeOffset]::UtcNow.AddMinutes(10).ToUnixTimeSeconds();$approved=[string](Get-TCProperty $TransportInfo PreviewToken '')
            if($Operation -eq 'NetworkRollback'){
                if($approved -notmatch '^nr1:(\d+):([A-Fa-f0-9]{64})$'){Stop-TCError '请先预览网络回退。'};$expiry=[long]$matches[1]
                if($expiry -le [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() -or $expiry -gt [DateTimeOffset]::UtcNow.AddMinutes(10).ToUnixTimeSeconds()){Stop-TCError '网络回退预览已过期。'}
            }
            $token='nr1:'+$expiry+':'+(Get-LineDigest ([ordered]@{Record=$record;BackupHash=$migration.BackupSHA256;ExpiresAt=$expiry}))
            if($Operation -eq 'NetworkRollbackPlan'){return [pscustomobject]@{LineId=$node.id;ProfileId=$wanted;CanRestore=$true;PreviewToken=$token;Message='恢复这条线路上一次网络更新前的 '+$wanted.ToUpperInvariant()+' 配置和对应默认绑定。其他连接方式保持；本次不会连接。旧网卡或地址已失效时，仍需更新网络后才能连接。'}}
            if($approved -cne $token){Stop-TCError '线路资料已变化，请重新预览回退。'}
            $currentChoice=Get-LineSavedPreference $record
            $record.Profiles=@($record.Profiles|ForEach-Object {if($_.Id -ceq $wanted){$oldProfile[0]}else{$_}})
            $record|Add-Member NoteProperty PreviousProfiles (@(Get-TCProperty $record PreviousProfiles @())+@($current[0])) -Force
            if($currentChoice -and $currentChoice.ProfileId -ceq $wanted){
                $oldChoice=Get-LineSavedPreference $before
                if($oldChoice -and $oldChoice.ProfileId -ceq $wanted){$record.SavedConnectionPreference=$oldChoice;$record.PreferredProfileId=$before.PreferredProfileId;$record.PreferenceSource=$before.PreferenceSource}
                else{$record.SavedConnectionPreference=New-LineSavedPreference $record $wanted $null -Manual;$record.PreferredProfileId=$wanted;$record.PreferenceSource='UserChoice'}
            }
            $record.Recommendation=$null;$record.Revision=[int]$record.Revision+1
            $record|Add-Member NoteProperty NetworkPolicyMigration (Get-TCProperty $before NetworkPolicyMigration) -Force
            Assert-LineInputs @($source,$oldSource,$newSource);Write-LineRecord $record;$committed=$true;return Get-LineView
        }
        if($Operation -in @('NetworkPlan','NetworkMigrate')){
            if(-not $record){Stop-TCError '[TC:ProfileConfigurationMissing] 请先登记原线路配置。'}
            $state=Get-LineServerConnectionState;if(-not $state.Allowed){Stop-TCError ('[TC:'+$state.Code+'] '+$state.Message)}
            if(Test-AutoActive $source){Stop-TCError '[TC:ActiveIdentity] 该线路仍在使用，断开后再更新本机网络设置。'}
            $wanted=if($ProfileId){$ProfileId}else{[string](Get-TCProperty (Get-LineSavedPreference $record) ProfileId '')}
            $selected=@($record.Profiles|Where-Object Id -ceq $wanted)
            if($selected.Count -ne 1){Stop-TCError '[TC:SavedDefaultMissing] 请先选择原线路的连接方式。'}
            $p=$selected[0];$current=Read-LineProfileSource $p $node.id -Stored
            $pathModule=Import-Module (Join-Path (Split-Path (Split-Path $FallbackWg -Parent) -Parent) 'ProbePath.psm1') -PassThru -DisableNameChecking
            $networkIndex=[int](Get-TCProperty $TransportInfo InterfaceIndex 0)
            $oldBinding=Get-TCProperty $current.Manifest ProbeBinding;$oldPolicy=Get-TCProperty $current.Manifest NetworkPolicy
            $oldId=[string](Get-TCProperty $oldPolicy InterfaceId (Get-TCProperty $oldBinding InterfaceId ''))
            if($networkIndex -eq 0 -and $oldId){
                $snapshot=& $pathModule {Get-TCProbeNetworkContext}
                $same=@($snapshot.Interfaces|Where-Object {$_.Id -ceq $oldId -and $_.Status -eq 'Up'})
                if($same.Count -eq 1){$networkIndex=[int]$same[0].Index}else{$networkIndex=-1}
            }
            $dns=@($current.Config.dns.servers|Where-Object tag -ceq 'dns-direct')
            if($dns.Count -ne 1){Stop-TCError '[TC:ConfigurationIdentityUnverified] 原线路缺少唯一的直接 DNS。'}
            $plan=& $pathModule {param($c,$d,$i)Get-TCProbeBindingPlan -Candidate $c -DirectDnsIPv4 $d -InterfaceIndex ([Math]::Max(0,$i))} $current.Config $dns[0].server $networkIndex
            if($plan.Status -ne 'Ready' -or $networkIndex -lt 0){return [pscustomobject]@{LineId=$node.id;ProfileId=$wanted;CanUpdate=$false;Code='NetworkSelectionRequired';Interfaces=@($plan.Interfaces);Message='请选择这条线路使用的物理网络。原网卡不可用时不会自动改走其他网络。'}}
            # This private producer verifies product-owned old fields before it
            # is permitted to replace a DHCP pin or update an interface name.
            $null=& $pathModule {param($c,$m,$b)New-TCProbeDerivative $c $m $b} $current.Config $current.Manifest $plan.Binding
            $saved=Get-LineSavedPreference $record;$preserve=$false
            if($saved -and $saved.ProfileId -ceq $wanted){
                $selection=Import-Module (Join-Path (Split-Path (Split-Path $FallbackWg -Parent) -Parent) 'ProtocolSelection.psm1') -PassThru -DisableNameChecking
                $preserve=& $selection {param($s,$id,$p,$m)Test-TCSavedConnectionPreference -Preference $s -LineId $id -Profile $p -Manifest $m} $saved $node.id $p $current.Manifest
                if(-not $preserve){Stop-TCError '[TC:SavedDefaultInvalid] 原默认来源无法核验，不能自动迁移其绑定。'}
            }
            $expires=[DateTimeOffset]::UtcNow.AddMinutes(10).ToUnixTimeSeconds()
            $approval=[string](Get-TCProperty $TransportInfo PreviewToken '')
            if($Operation -eq 'NetworkMigrate'){
                if($approval -notmatch '^np1:(\d+):([A-Fa-f0-9]{64})$'){Stop-TCError '缺少网络更新预览。'}
                $expires=[long]$matches[1]
                if($expires -le [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() -or $expires -gt [DateTimeOffset]::UtcNow.AddMinutes(10).ToUnixTimeSeconds()){Stop-TCError '网络更新预览已过期。'}
            }
            $digest=Get-LineDigest ([ordered]@{LineId=$node.id;Record=$record;Profile=$p;Binding=$plan.Binding;ExpiresAt=$expires})
            $token='np1:'+$expires+':'+$digest
            if($Operation -eq 'NetworkPlan'){return [pscustomobject]@{LineId=$node.id;ProfileId=$wanted;CanUpdate=$true;PreviewToken=$token;InterfaceIndex=$plan.Binding.InterfaceIndex;InterfaceName=$plan.Binding.InterfaceName;Interfaces=@($plan.Interfaces);PreserveDefault=$preserve;Message='仅更新本机物理网卡设置，移除永久固定的本机 IPv4。保留服务器、设备和协议；保留原版本，可回退。确认后沿用此协议作为下次选择，连接后重新检查。'}}
            if($approval -cne $token){Stop-TCError '配置或网络已变化，请重新预览。'}
            $before=Copy-LineObject $record
            $envelope=if($p.Id -ceq 'Tcp'){Get-LineEnvelope $current (Find-AutoServer $source) $source}else{$null}
            $replacement=New-LineImmutableProfile $current $p.Id ([int]$p.Revision+1) $envelope $plan.Binding
            $next=Read-LineProfileSource $replacement $node.id -Stored
            $sameIdentity=& $pathModule {param($a,$b)Test-TCNetworkPolicyOnlyChange $a $b} $current.Config $next.Config
            if(-not $sameIdentity){Stop-TCError '网络更新包含未批准的配置差异，已保留原版本。'}
            $backupRoot=Join-Path $lineRoot 'network-policy-backups';New-LineDirectory $backupRoot
            $backupPath=Join-Path $backupRoot ([guid]::NewGuid().ToString('N')+'.json');Write-TCAtomicJson $backupPath $before -NewOnly
            $record.Profiles=@($record.Profiles|ForEach-Object {if($_.Id -ceq $wanted){$replacement}else{$_}})
            $record|Add-Member NoteProperty PreviousProfiles (@(Get-TCProperty $record PreviousProfiles @())+@($p)) -Force
            $record|Add-Member NoteProperty Recommendation $null -Force
            $record.Revision=[int]$record.Revision+1
            if($preserve){$record|Add-Member NoteProperty SavedConnectionPreference (New-LineSavedPreference $record $wanted $null -Manual) -Force;$record.PreferredProfileId=$wanted;$record.PreferenceSource='UserChoice'}
            $record|Add-Member NoteProperty NetworkPolicyMigration ([pscustomobject]@{SchemaVersion=1;AtUtc=[DateTimeOffset]::UtcNow.ToString('o');ProfileId=$wanted;PreviousManifestSHA256=$p.ManifestSHA256;NewManifestSHA256=$replacement.ManifestSHA256;PreviousPreferenceSource=(Get-TCProperty $saved Source);BackupPath=$backupPath;BackupSHA256=(Get-AutoHash $backupPath);Reason='UserApprovedNetworkPolicy';EvidenceTransferred=$false}) -Force
            Assert-LineInputs @($source,$current);Write-LineRecord $record;$committed=$true
            return Get-LineView
        }
        if($Operation -ceq 'Binding'){
            if(-not $record){Stop-TCError '请先登记线路连接方式。'}
            if(Test-AutoActive $source){return [pscustomobject]@{LineId=$node.id;State='Blocked';Prepared=$false;Code='ActiveIdentity';Results=@();NetworkChanged=$false}}
            $interfaceIndex=[int](Get-TCProperty $TransportInfo 'InterfaceIndex' 0)
            if($interfaceIndex -lt 0){Stop-TCError '检测网卡编号无效。'}
            $pathModule=Import-Module (Join-Path (Split-Path (Split-Path $FallbackWg -Parent) -Parent) 'ProbePath.psm1') -PassThru -DisableNameChecking
            $results=@();$changed=$false;$next=@();$previous=@(Get-TCProperty $record 'PreviousProfiles' @())
            foreach($p in @($record.Profiles)){
                $current=Read-LineProfileSource $p $node.id -Stored
                $bootstrap=@($current.Config.dns.servers|Where-Object tag -ceq 'dns-direct')
                $dnsAddress=if($bootstrap.Count -eq 1){[string](Get-TCProperty $bootstrap[0] 'server' '')}else{''}
                $plan=& $pathModule {param($Candidate,$Dns,$Index) Get-TCProbeBindingPlan -Candidate $Candidate -DirectDnsIPv4 $Dns -InterfaceIndex $Index} $current.Config $dnsAddress $interfaceIndex
                if($plan.Status -ne 'Ready' -or -not $plan.Binding){
                    $next+=,$p
                    $bindingState=if($plan.Reason -eq 'AmbiguousPhysicalInterface'){'NeedsNetworkSelection'}else{'Unsupported'}
                    $results+=,[pscustomobject]@{ProfileId=$p.Id;Status=$plan.Status;Reason=$plan.Reason;BindingState=$bindingState;ReasonCode=$plan.Reason;ProfileRevision=$p.Revision;CandidateSHA256=$p.CandidateSHA256;ManifestSHA256=$p.ManifestSHA256;BindingDigest=$null;NextAction=$(if($bindingState -eq 'NeedsNetworkSelection'){'ChooseNetwork'}else{'ViewDiagnostics'});Interfaces=@($plan.Interfaces)}
                    continue
                }
                # A check derives its own temporary config. The immutable profile
                # and saved choice are never replaced by a probe preparation.
                $next+=,$p
                $results+=,[pscustomobject]@{ProfileId=$p.Id;Status='Prepared';Reason='ProbeOnlyBinding';BindingState='Prepared';ReasonCode='ProbeOnlyBinding';ProfileRevision=$p.Revision;CandidateSHA256=$p.CandidateSHA256;ManifestSHA256=$p.ManifestSHA256;BindingDigest=(Get-LineDigest $plan.Binding);ProbeBinding=$plan.Binding;NextAction='None';Interfaces=@($plan.Interfaces)}
            }
            if($changed){
                $record.Profiles=@($next);$record|Add-Member NoteProperty PreviousProfiles @($previous) -Force
                $record.Revision=[int]$record.Revision+1
                # A new immutable network binding invalidates a prior automatic
                # decision, while the user's explicit choice remains their intent.
                if((Get-TCProperty $record 'PreferenceSource' '') -ne 'UserChoice'){
                    $record|Add-Member NoteProperty Recommendation ([pscustomobject]@{SchemaVersion=1;LineId=$node.id;Status='Inconclusive';RecommendedProfileId=$null;PreferredProfileId=$null;Source='None';Reason='已准备新的网卡绑定，正在重新检查。'}) -Force
                    $record.PreferredProfileId=$null;$record|Add-Member NoteProperty PreferenceSource 'None' -Force
                }
                Assert-LineInputs @($source);Write-LineRecord $record;$committed=$true
            }else{$committed=$true}
            $readyCount=@($results|Where-Object {$_.BindingState -in @('Prepared','Reused')}).Count
            $state=if($readyCount -eq $results.Count -and $readyCount){'Ready'}elseif(@($results|Where-Object BindingState -eq 'NeedsNetworkSelection').Count){'NeedsNetworkSelection'}elseif($readyCount){'Partial'}else{'Unsupported'}
            $code=switch($state){Ready {'BindingsPrepared'} Partial {'BindingsPartiallyPrepared'} NeedsNetworkSelection {'AmbiguousPhysicalInterface'} default {'ProbeBindingUnsupported'}}
            return [pscustomobject]@{LineId=$node.id;State=$state;Prepared=$changed;Code=$code;Results=@($results);ReadyProfiles=@($results|Where-Object {$_.BindingState -in @('Prepared','Reused')}|ForEach-Object {$_.ProfileId});ProfileRevision=$record.Revision;SelectedInterfaceIndex=$interfaceIndex;NetworkChanged=$false}
        }
        if($Operation -in @('Recommendation','Preference')){
            if(-not $record){Stop-TCError '请先登记线路连接方式。'}
            foreach($item in @(@{Name='Recommendation';Value=$null},@{Name='PreferenceSource';Value='ConfiguredDefault'},@{Name='PreferenceUpdatedAt';Value=$null})){
                if(-not $record.PSObject.Properties[$item.Name]){$record|Add-Member NoteProperty $item.Name $item.Value}
            }
            if($Operation -ceq 'Preference'){
                $expected=Get-TCProperty $TransportInfo ExpectedRevision -1
                if([long]$expected -ge 0 -and [long]$record.Revision -ne [long]$expected){Stop-TCError '[TC:PreferenceRevisionChanged] 线路资料已变化，请刷新后重试。'}
                $selected=@($record.Profiles|Where-Object {$_.Id -ceq $ProfileId})
                if($selected.Count -ne 1){Stop-TCError '选择的连接方式尚未准备。'}
                $null=Read-LineProfileSource $selected[0] $node.id -Stored
                $record|Add-Member NoteProperty SavedConnectionPreference (New-LineSavedPreference $record $ProfileId $null -Manual) -Force
                $record.PreferredProfileId=$ProfileId;$record.PreferenceSource='UserChoice'
            }else{
                $decision=Copy-LineObject $Validation
                if((Get-TCProperty $decision 'SchemaVersion' 0) -ne 1 -or (Get-TCProperty $decision 'LineId' '') -cne $node.id -or (Get-TCProperty $decision 'Status' '') -notin @('Recommended','Unavailable','Inconclusive','Blocked','UserChoice')){Stop-TCError '线路推荐结果的版本或身份无效。'}
                $selection=Import-Module (Join-Path (Split-Path (Split-Path $FallbackWg -Parent) -Parent) 'ProtocolSelection.psm1') -PassThru -DisableNameChecking
                if($decision.Status -eq 'Recommended'){
                    $valid=& $selection {param($Decision,$Profiles,$Context) Test-TCProtocolRecommendationCurrent -Recommendation $Decision -Profiles $Profiles -NetworkContext $Context} $decision @($record.Profiles) $TransportInfo
                    if(-not $valid){Stop-TCError '推荐证据已过期、环境改变或不属于当前配置。'}
                }
                elseif($decision.Status -eq 'UserChoice'){
                    $wanted=[string](Get-TCProperty $decision 'PreferredProfileId' '')
                    if(@($record.Profiles|Where-Object {$_.Id -ceq $wanted}).Count -ne 1){Stop-TCError '用户选择不属于此线路。'}
                }elseif(Get-TCProperty $decision 'RecommendedProfileId'){Stop-TCError '未通过资格核验的结果不能携带自动推荐方式。'}
                $saved=Get-LineSavedPreference $record
                # AutoSave records current evidence. Only the first qualified
                # recommendation establishes a default; later checks do not
                # silently switch a saved preference or fake a manual choice.
                if(-not $saved -and $decision.Status -eq 'Recommended'){$saved=New-LineSavedPreference $record $decision.RecommendedProfileId $decision}
                $record|Add-Member NoteProperty SavedConnectionPreference $saved -Force
                $record.Recommendation=$decision
                if($saved){$record.PreferredProfileId=$saved.ProfileId;$record.PreferenceSource=$saved.Source}
                else{$record.PreferredProfileId=$null;$record.PreferenceSource='None'}
            }
            $record.PreferenceUpdatedAt=[DateTimeOffset]::UtcNow.ToString('o');$record.Revision=[int]$record.Revision+1
            Assert-LineInputs @($source);Write-LineRecord $record;$committed=$true
            return Get-LineView
        }
        if($Operation -ceq 'Validation'){
            if(-not $record){Stop-TCError '请先登记线路 profile。'}
            $expected=Get-TCProperty $TransportInfo ExpectedRevision -1
            if([long]$expected -ge 0 -and [long]$record.Revision -ne [long]$expected){Stop-TCError '[TC:LineRevisionChanged] 检查期间线路资料已变化，结果未保存到新版本。'}
            $selected=@($record.Profiles|Where-Object {$_.Id -ceq $ProfileId})
            if($selected.Count -ne 1){Stop-TCError '指定 profile 不存在。'}
            $evidence=Copy-LineObject $Validation
            if($evidence -isnot [pscustomobject] -or (Get-TCProperty $evidence 'CandidateSHA256' '') -ine $selected[0].CandidateSHA256){Stop-TCError '验证证据必须绑定当前配置 CandidateSHA256。'}
            foreach($pair in @(@('LineId',$node.id),@('ProfileId',$ProfileId),@('ServerPublicKey',$source.Manifest.ServerPublicKey),@('ClientPublicKey',$source.Manifest.ClientPublicKey),@('Mode',$ProfileId))){
                $known=Get-TCProperty $evidence $pair[0]
                if($known -and $known -cne $pair[1]){Stop-TCError '验证证据的线路/设备/连接方式绑定冲突。'}
                $evidence|Add-Member NoteProperty $pair[0] $pair[1] -Force
            }
            $addr=Get-TCProperty $evidence 'ClientAddress'
            if($addr -and (ConvertTo-AutoAddress $addr) -cne (ConvertTo-AutoAddress $source.Manifest.ClientAddress)){Stop-TCError '验证证据的地址绑定冲突。'}
            $evidence|Add-Member NoteProperty ClientAddress (ConvertTo-AutoAddress $source.Manifest.ClientAddress) -Force
            if(-not (Get-TCProperty $evidence 'ValidatedAt')){$evidence|Add-Member NoteProperty ValidatedAt ([DateTimeOffset]::UtcNow.ToString('o')) -Force}
            $selected[0].Validation=$evidence;$record.Revision=[int]$record.Revision+1
            Assert-LineInputs @($source)
            Write-LineRecord $record;$committed=$true
            return $selected[0]
        }
        if(-not $record){$record=New-LineRecord}
        $changed=$false
        if(-not (Get-TCProperty $record 'SourceManifestPath')){$record|Add-Member NoteProperty SourceManifestPath $source.ManifestPath -Force;$changed=$true}
        if(-not $record.Profiles.Count){
            $mode=Get-LineMode $source
            $originalEnvelope=Get-LineEnvelope $source (Find-AutoServer $source) $source
            $record.Profiles=@(New-LineImmutableProfile $source $mode 1 $originalEnvelope);$changed=$true
            if($mode -ceq 'Tcp'){$record.Profiles+=,(New-LineImmutableProfile $source 'Udp' 1 $null)}
            elseif($aliases.Count){
                $s=$model.Groups[$node.id][0];$envelope=Get-LineEnvelope $s (Find-AutoServer $source) $source
                $record.Profiles+=,(New-LineImmutableProfile $s 'Tcp' 1 $envelope)
            }
        }
        $reused=$false
        if($Operation -ceq 'Prepare'){
            $info=Assert-AutoEnvelope $TransportInfo $source (Find-AutoServer $source)
            if($info.PSObject.Properties['MTU']){
                $udp=@($record.Profiles|Where-Object {$_.Id -ceq 'Udp'})
                $udpNeedsMtu=($udp.Count -ne 1)
                if(-not $udpNeedsMtu){$u=Read-LineProfileSource $udp[0] $node.id -Stored;$udpNeedsMtu=(@($u.Config.endpoints|Where-Object tag -ceq 'hk')[0].mtu -ne $info.MTU)}
                if($udpNeedsMtu){
                    $udpRevision=1;if($udp.Count){$udpRevision=[int]$udp[0].Revision+1}
                    $up=New-LineImmutableProfile $source 'Udp' $udpRevision $info
                    if($udp.Count){
                        $previous=@(Get-TCProperty $record 'PreviousProfiles' @())
                        if(-not @($previous|Where-Object {Test-TCSamePath $_.ManifestPath $udp[0].ManifestPath}).Count){$previous+=,$udp[0]}
                        $record|Add-Member NoteProperty PreviousProfiles @($previous) -Force
                    }
                    $record.Profiles=@($record.Profiles|Where-Object {$_.Id -cne 'Udp'})+@($up);$changed=$true
                }
            }
            $tcp=@($record.Profiles|Where-Object {$_.Id -ceq 'Tcp'})
            if($tcp.Count){
                $existing=Read-LineProfileSource $tcp[0] $node.id -Stored
                $existingInfo=Get-LineEnvelope $existing (Find-AutoServer $source) $source
                if($existingInfo -and (Get-AutoDigest $existingInfo) -ceq (Get-AutoDigest $info)){$reused=$true}
            }
            if(-not $reused){
                $revision=1;if($tcp.Count){$revision=[int]$tcp[0].Revision+1}
                $p=New-LineImmutableProfile $source 'Tcp' $revision $info
                if($tcp.Count){
                    $previous=@(Get-TCProperty $record 'PreviousProfiles' @())
                    if(-not @($previous|Where-Object {Test-TCSamePath $_.ManifestPath $tcp[0].ManifestPath}).Count){$previous+=,$tcp[0]}
                    $record|Add-Member NoteProperty PreviousProfiles @($previous) -Force
                }
                $record.Profiles=@($record.Profiles|Where-Object {$_.Id -cne 'Tcp'})+@($p);$changed=$true
            }
        }
        if($changed){
            $record|Add-Member NoteProperty Recommendation $null -Force
            $record.Revision=[int]$record.Revision+1;Assert-LineInputs (@($source)+@($model.Groups[$node.id]))
            Write-LineRecord $record
        }
        $committed=$true
        if($Operation -ceq 'Register'){return Get-LineView}
        $selected=@($record.Profiles|Where-Object {$_.Id -ceq 'Tcp'})[0]
        [pscustomobject]@{Kind='TradeChannel.AutomaticTransportCandidate';Status='ReadyInactive';Id=$node.id;NodeId=$node.id;LineId=$node.id;Name=$node.name;SourceNodeId=$node.id;ProfileId='Tcp';ManifestPath=$selected.ManifestPath;CandidateSHA256=$selected.CandidateSHA256;Revision=$selected.Revision;TransportMode='Tcp';Reused=$reused;Activated=$false;CurrentNetworkChanged=$false;ProbeRequiresInactiveIdentity=$true;SourceActive=$active}
    }catch{Stop-TCOperation $_ '线路资料准备或读取失败；原资料与当前连接保留，诊断内容已隐藏。'}
    finally{
        try{
            if(-not $committed){
                foreach($path in @($owned.ToArray())|Sort-Object Length -Descending){
                    $full=Get-TCFullPath $path
                    if(-not (Test-TCPathWithin $full $lineRoot) -or [IO.Path]::GetFileName($full) -cnotmatch '^(?:[0-9a-f]{32}|(?:Udp|Tcp)-r[0-9]+-[0-9a-f]{32})$'){Stop-TCError '拒绝清理非本次生成的 profile。'}
                    Assert-TCNoReparse $full;if([IO.Directory]::Exists($full)){Remove-Item -LiteralPath $full -Recurse -Force}
                }
            }
        }finally{
            if($lineLock){$lineLock.Dispose()};if($indexLock){$indexLock.Dispose()};if($sessionLock){$sessionLock.Dispose()}
            if(-not $committed){
                foreach($path in @($created.ToArray())|Sort-Object Length -Descending){
                    if([IO.Directory]::Exists($path)){
                        $lockPath=Join-Path $path '.line.lock'
                        if([IO.File]::Exists($lockPath)){[IO.File]::Delete($lockPath)}
                        if(@(Get-ChildItem -LiteralPath $path -Force).Count -eq 0){[IO.Directory]::Delete($path)}
                    }
                }
            }
            $source=$null;$TransportInfo=$null;$info=$null;$Validation=$null
        }
    }
}

function Get-TCLineCards {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root)
    & $script:TCLineNodes $script:TCLineImplementation $Root '' 'Cards' $null '' $null $script:TCLineWg
}
function Get-TCLine {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][string]$Id)
    & $script:TCLineNodes $script:TCLineImplementation $Root $Id 'Get' $null '' $null $script:TCLineWg
}
function Get-TCLineProfile {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][string]$Id,[Parameter(Mandatory=$true)][ValidateSet('Udp','Tcp')][string]$ProfileId)
    & $script:TCLineNodes $script:TCLineImplementation $Root $Id 'Profile' $null $ProfileId $null $script:TCLineWg
}
function Register-TCLineProfiles {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][string]$Id)
    & $script:TCLineNodes $script:TCLineImplementation $Root $Id 'Register' $null '' $null $script:TCLineWg
}
function Prepare-TCTcpLineProfile {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][string]$Id,[Parameter(Mandatory=$true)]$TransportInfo)
    & $script:TCLineNodes $script:TCLineImplementation $Root $Id 'Prepare' $TransportInfo '' $null $script:TCLineWg
}
function Set-TCLineProfileValidation {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][string]$Id,[Parameter(Mandatory=$true)][ValidateSet('Udp','Tcp')][string]$ProfileId,[Parameter(Mandatory=$true)]$Validation,[long]$ExpectedRevision=-1)
    & $script:TCLineNodes $script:TCLineImplementation $Root $Id 'Validation' ([pscustomobject]@{ExpectedRevision=$ExpectedRevision}) $ProfileId $Validation $script:TCLineWg
}
function Set-TCLineRecommendation {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][string]$Id,[Parameter(Mandatory=$true)]$Recommendation,$NetworkContext)
    & $script:TCLineNodes $script:TCLineImplementation $Root $Id 'Recommendation' $NetworkContext '' $Recommendation $script:TCLineWg
}
function Set-TCLinePreferredProfile {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][string]$Id,[Parameter(Mandatory=$true)][ValidateSet('Udp','Tcp')][string]$ProfileId,[long]$ExpectedRevision=-1)
    & $script:TCLineNodes $script:TCLineImplementation $Root $Id 'Preference' ([pscustomobject]@{ExpectedRevision=$ExpectedRevision}) $ProfileId $null $script:TCLineWg
}
function Repair-TCLineSavedPreference {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][string]$Id,[long]$ExpectedRevision=-1,[string]$ExpectedDigest)
    if($ExpectedRevision -lt 0){$line=Get-TCLine -Root $Root -Id $Id;$ExpectedRevision=$line.Revision;$ExpectedDigest=if($line.SavedConnectionPreference){[string]$line.SavedConnectionPreference.Digest}else{''}}
    & $script:TCLineNodes $script:TCLineImplementation $Root $Id 'RepairPreference' ([pscustomobject]@{ExpectedRevision=$ExpectedRevision;ExpectedDigest=$ExpectedDigest}) '' $null $script:TCLineWg
}
function Prepare-TCLineProbeBindings {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][string]$Id,[ValidateRange(0,2147483647)][int]$InterfaceIndex=0)
    & $script:TCLineNodes $script:TCLineImplementation $Root $Id 'Binding' ([pscustomobject]@{InterfaceIndex=$InterfaceIndex}) '' $null $script:TCLineWg
}
function Get-TCLineNetworkPolicyPreview {
    [CmdletBinding()]param([string]$Root,[string]$Id,[string]$ProfileId,[int]$InterfaceIndex=0)
    & $script:TCLineNodes $script:TCLineImplementation $Root $Id 'NetworkPlan' ([pscustomobject]@{InterfaceIndex=$InterfaceIndex}) $ProfileId $null $script:TCLineWg
}
function Update-TCLineNetworkPolicy {
    [CmdletBinding()]param([string]$Root,[string]$Id,[string]$ProfileId,[int]$InterfaceIndex,[string]$PreviewToken)
    & $script:TCLineNodes $script:TCLineImplementation $Root $Id 'NetworkMigrate' ([pscustomobject]@{InterfaceIndex=$InterfaceIndex;PreviewToken=$PreviewToken}) $ProfileId $null $script:TCLineWg
}
function Get-TCLineNetworkRollbackPreview {
    [CmdletBinding()]param([string]$Root,[string]$Id)
    & $script:TCLineNodes $script:TCLineImplementation $Root $Id 'NetworkRollbackPlan' $null '' $null $script:TCLineWg
}
function Restore-TCLineNetworkPolicy {
    [CmdletBinding()]param([string]$Root,[string]$Id,[string]$PreviewToken)
    & $script:TCLineNodes $script:TCLineImplementation $Root $Id 'NetworkRollback' ([pscustomobject]@{PreviewToken=$PreviewToken}) '' $null $script:TCLineWg
}
function Get-TCLineDefaultProfile {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][string]$Id,$NetworkContext,[ValidateSet('SavedDefault','CurrentRecommendation')][string]$SelectionMode='SavedDefault')
    $line=Get-TCLine -Root $Root -Id $Id
    Import-Module (Join-Path $PSScriptRoot 'ProtocolSelection.psm1') -DisableNameChecking
    Resolve-TCLineDefaultProfile -Line $line -NetworkContext $NetworkContext -SelectionMode $SelectionMode
}
function Resolve-TCLineDefaultProfile {
    param($Line,$NetworkContext,[string]$SelectionMode='SavedDefault')
    $registered=($Line.Revision -ge 1);$id=$null;$source='None';$code='SavedDefaultMissing';$reason='没有可核验的已保存默认，请明确选择已准备的连接方式。'
    $recommendation=$Line.Recommendation;$saved=$Line.SavedConnectionPreference;$current=$false;$recState='None';$recorded=$false
    if($recommendation){
        $recState=[string]$recommendation.Status
        if($recommendation.Status -eq 'Recommended'){
            $at=[DateTimeOffset]::MinValue;$until=[DateTimeOffset]::MinValue
            if([DateTimeOffset]::TryParse([string]$recommendation.CheckedAtUtc,[ref]$at)){$recorded=Test-TCProtocolRecommendationRecorded -Recommendation $recommendation -Profiles @($Line.Profiles) -RecordedAt $at}
            if(-not $recorded){$recState='Invalid'}
            elseif([DateTimeOffset]::TryParse([string]$recommendation.ExpiresAtUtc,[ref]$until) -and $until -le (LSPreferenceNow)){$recState='Expired'}
            else{
                if(-not $NetworkContext){$NetworkContext=Get-TCProtocolNetworkContext}
                $current=Test-TCProtocolRecommendationCurrent -Recommendation $recommendation -Profiles @($Line.Profiles) -NetworkContext $NetworkContext
                $recState=if($current){'Current'}else{'Old'}
            }
        }
    }
    if($SelectionMode -eq 'CurrentRecommendation'){
        $code='RecommendationCheckRequired';$reason='当前推荐不足、过期或环境已变化，请重新检查。'
        if($registered -and $current){$id=$recommendation.RecommendedProfileId;$source=$recommendation.Source;$code='CurrentRecommendation';$reason=$recommendation.Reason}
    }elseif($registered -and $saved){
        $profile=@($Line.Profiles|Where-Object Id -ceq $saved.ProfileId)
        $valid=$false
        if($profile.Count -eq 1){
            $raw=[IO.File]::ReadAllText($profile[0].ManifestPath)
            $manifest=if((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')){ConvertFrom-Json -InputObject $raw -DateKind String}else{ConvertFrom-Json -InputObject $raw}
            $valid=Test-TCSavedConnectionPreference -Preference $saved -LineId $Line.LineId -Profile $profile[0] -Manifest $manifest -Now (LSPreferenceNow)
        }
        $code='SavedDefaultInvalid';$reason='已保存默认的来源、配置或身份绑定无法核验，请重新准备或明确选择。'
        if($valid){
            $blocked=Get-TCSavedConnectionPreferenceBlock -Line $Line -Profile $profile[0]
            if($recState -eq 'Invalid'){$blocked='RecommendationIntegrityInvalid'}
            if($blocked){$code=$blocked;$reason='最近检查失败、受阻或结果待核对；不能按推荐过期继续连接。'}
            else{$id=$saved.ProfileId;$source=$saved.Source;$code='SavedDefault';$reason='明确使用已保存的 '+$id.ToUpperInvariant()+' 默认方式，连接后检查实际出口、DNS 和 HTTPS。'}
        }
    }
    if($Line.ServerConnectionBlock){$id=$null;$source='None';$code=$Line.ServerConnectionBlock;$reason=$Line.ServerConnectionMessage}
    [pscustomobject]@{LineId=$Line.LineId;ProfileId=$id;Source=$source;RequiresCheck=(-not $id);Reason=$reason;Recommendation=$recommendation;Registered=$registered;Line=$Line;SelectionMode=$SelectionMode;SavedConnectionPreference=$saved;RecommendationCurrent=$current;RecommendationState=$recState;Code=$code}
}
Export-ModuleMember -Function Get-TCLineCards,Get-TCLine,Get-TCLineProfile,Register-TCLineProfiles,Prepare-TCTcpLineProfile,Set-TCLineProfileValidation,Set-TCLineRecommendation,Set-TCLinePreferredProfile,Repair-TCLineSavedPreference,Get-TCLineDefaultProfile,Prepare-TCLineProbeBindings,Get-TCLineNetworkPolicyPreview,Update-TCLineNetworkPolicy,Get-TCLineNetworkRollbackPreview,Restore-TCLineNetworkPolicy
