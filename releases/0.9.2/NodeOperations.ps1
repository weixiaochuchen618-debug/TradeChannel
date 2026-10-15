# Node operations share the runtime session lock. Configuration changes create
# separately validated files; an old or external manifest is never overwritten.
function Open-TCNodeSessionLock {
    param([string]$StoreRoot)
    $path = Join-Path (Split-Path (Get-TCFullPath $StoreRoot) -Parent) '.session.lock'
    Assert-TCNoReparse $path
    try { [IO.File]::Open($path,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
    catch { Stop-TCError '连接操作正在进行，请等待完成后再修改线路。' }
}

function Assert-TCNodeStopped {
    param([string]$StoreRoot,[string]$ManifestPath,$Manifest)
    $parent = Split-Path (Get-TCFullPath $StoreRoot) -Parent
    $deploymentPath = Join-Path $parent 'deployment.json'
    $selected = $false
    if ([IO.File]::Exists($deploymentPath)) {
        $dep = Read-TCJson $deploymentPath
        $selected = Test-TCSamePath (Get-TCProperty $dep 'ManifestPath') $ManifestPath
    }
    $runtimePath = Join-Path $parent 'runtime.json'
    if ($selected -and [IO.File]::Exists($runtimePath)) {
        $rt = Read-TCJson $runtimePath
        $state = [string](Get-TCProperty $rt 'State' '')
        if ($state -notin @('Disconnected','Stopped','StoppedWithError') -or (Get-TCProperty $rt 'CleanupError' $false)) {
            Stop-TCError '该线路仍在运行或清理尚未完成。请先在概览页断开并确认停止，再修改线路。'
        }
    }
    $engine = [string](Get-TCProperty $Manifest 'EnginePath' '')
    $candidate = [string](Get-TCProperty $Manifest 'CandidatePath' '')
    if ($engine -and $candidate) {
        $leaf = [IO.Path]::GetFileName($engine).Replace("'","''")
        foreach ($process in @(Get-CimInstance Win32_Process -Filter ("Name='"+$leaf+"'") -ErrorAction Stop)) {
            if ($process.ExecutablePath -and (Test-TCSamePath $process.ExecutablePath $engine)) {
                if (-not $process.CommandLine -or ([string]$process.CommandLine).IndexOf($candidate,[StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    Stop-TCError '检测到该线路的引擎仍在运行，配置未修改。请先确认通道已停止。'
                }
            }
        }
    }
    return $selected
}

function Assert-TCConfigurationDependencies {
    param($Config)
    $tags = @{}
    foreach ($entry in @(Get-TCProperty $Config 'endpoints' @()) + @(Get-TCProperty $Config 'outbounds' @())) {
        $tag = [string](Get-TCProperty $entry 'tag' '')
        if (-not $tag -or $tags.ContainsKey($tag)) { Stop-TCError '配置包含空标签或重复的出站标签，未保存。' }
        $tags[$tag] = $true
    }
    $references = New-Object 'Collections.Generic.List[string]'
    foreach ($entry in @(Get-TCProperty $Config 'endpoints' @()) + @(Get-TCProperty $Config 'outbounds' @())) {
        $detour = [string](Get-TCProperty $entry 'detour' '')
        if ($detour) { $references.Add($detour) }
        foreach ($member in @(Get-TCProperty $entry 'outbounds' @())) { if ($member -is [string]) { $references.Add($member) } }
        $default = [string](Get-TCProperty $entry 'default' '')
        if ($default) { $references.Add($default) }
    }
    $route = Get-TCProperty $Config 'route'
    $final = [string](Get-TCProperty $route 'final' '')
    if ($final) { $references.Add($final) }
    $visitRule = {
        param($Rule)
        $out = [string](Get-TCProperty $Rule 'outbound' '')
        if ($out) { $references.Add($out) }
        foreach ($child in @(Get-TCProperty $Rule 'rules' @())) { & $visitRule $child }
    }
    foreach ($rule in @(Get-TCProperty $route 'rules' @())) { & $visitRule $rule }
    $dns = Get-TCProperty $Config 'dns'
    foreach ($server in @(Get-TCProperty $dns 'servers' @())) {
        $detour = [string](Get-TCProperty $server 'detour' '')
        if ($detour) { $references.Add($detour) }
    }
    foreach ($reference in $references) {
        if (-not $tags.ContainsKey($reference)) { Stop-TCError ('配置引用了不存在的出站「'+$reference+'」，原线路保留。') }
    }
}

function ConvertTo-TCTransport {
    param($Value)
    if (-not $Value) { return $null }
    $type = [string](Get-TCProperty $Value 'Type' 'tcp-reality')
    if ($type -ne 'tcp-reality') { Stop-TCError '不支持此传输类型。' }
    $server = [string](Get-TCProperty $Value 'Server' '')
    $port = ConvertTo-TCPort (Get-TCProperty $Value 'Port' '')
    $ip = $null
    if ([Net.IPAddress]::TryParse($server,[ref]$ip)) { $server=$ip.ToString() }
    else { $server=ConvertTo-TCDomain $server }
    $id = [Guid]::Empty
    if (-not [Guid]::TryParseExact([string](Get-TCProperty $Value 'Uuid' ''),'D',[ref]$id) -or $id -eq [Guid]::Empty) { Stop-TCError '请填写服务器提供的有效 TCP 用户 UUID。' }
    $publicKey = [string](Get-TCProperty $Value 'RealityPublicKey' '')
    if ($publicKey -cnotmatch '^[A-Za-z0-9_-]{43}$') { Stop-TCError 'Reality 公钥须为服务器提供的 43 位 base64url 公钥。' }
    $keyBytes=$null
    try { $keyBytes=[Convert]::FromBase64String($publicKey.Replace('-','+').Replace('_','/')+'='); if($keyBytes.Length -ne 32){throw 'Invalid key length'} }
    catch { Stop-TCError 'Reality 公钥格式无效，未修改线路。' }
    finally { if($keyBytes){[Array]::Clear($keyBytes,0,$keyBytes.Length)} }
    $shortId = [string](Get-TCProperty $Value 'RealityShortId' '')
    if ($shortId -cnotmatch '^(?:[0-9a-fA-F]{2}){0,8}$') { Stop-TCError 'Reality ShortId 须为偶数长度十六进制，最多 16 位。' }
    $serverName = [string](Get-TCProperty $Value 'ServerName' '')
    if($serverName -ne 'localhost'){$serverName=ConvertTo-TCDomain $serverName}
    return [ordered]@{Type='tcp-reality';Server=$server;Port=$port;Uuid=$id.ToString('D');ServerName=$serverName;RealityPublicKey=$publicKey;RealityShortId=$shortId.ToLowerInvariant()}
}

function Get-TCTransportFromConfiguration {
    param($Manifest,$Config)
    $stored = Get-TCProperty $Manifest 'Transport'
    if ($stored) { return ConvertTo-TCTransport $stored }
    $detours = @(Get-TCProperty $Config 'endpoints' @() | Where-Object {[string](Get-TCProperty $_ 'detour' '') -eq 'tc-transport'})
    if (-not $detours.Count) { return $null }
    $transit = @(Get-TCProperty $Config 'outbounds' @() | Where-Object {[string](Get-TCProperty $_ 'tag' '') -eq 'tc-transport'})
    if ($transit.Count -ne 1 -or $transit[0].type -ne 'vless') { Stop-TCError '旧 TCP 配置缺少唯一的传输出站，请恢复原配置或重新填写 TCP 参数。' }
    $tls = Get-TCProperty $transit[0] 'tls'
    $reality = Get-TCProperty $tls 'reality'
    if (-not (Get-TCProperty $tls 'enabled' $false) -or -not (Get-TCProperty $reality 'enabled' $false)) { Stop-TCError '旧 TCP 配置不属于支持的 VLESS/Reality 结构，原线路保留。' }
    return ConvertTo-TCTransport @{Type='tcp-reality';Server=$transit[0].server;Port=$transit[0].server_port;Uuid=$transit[0].uuid;ServerName=(Get-TCProperty $tls 'server_name' '');RealityPublicKey=(Get-TCProperty $reality 'public_key' '');RealityShortId=(Get-TCProperty $reality 'short_id' '')}
}

function Set-TCConfigurationTransport {
    param($Config,$Transport)
    $endpoints = @(Get-TCProperty $Config 'endpoints' @())
    if (-not $endpoints.Count) { Stop-TCError '配置缺少 WireGuard endpoint，未保存。' }
    foreach ($endpoint in $endpoints) {
        if ($endpoint.type -ne 'wireguard') { continue }
        $existing = [string](Get-TCProperty $endpoint 'detour' '')
        if ($existing -and $existing -ne 'tc-transport') { Stop-TCError '线路含有其他传输依赖，不能自动覆盖。' }
        if ($Transport) { $endpoint | Add-Member NoteProperty detour 'tc-transport' -Force }
        elseif ($existing -eq 'tc-transport') { $endpoint.PSObject.Properties.Remove('detour') }
    }
    $outbounds = @(Get-TCProperty $Config 'outbounds' @() | Where-Object {[string](Get-TCProperty $_ 'tag' '') -ne 'tc-transport'})
    if ($Transport) {
        $transit=[ordered]@{type='vless';tag='tc-transport';server=$Transport.Server;server_port=$Transport.Port;uuid=$Transport.Uuid;
            tls=[ordered]@{enabled=$true;server_name=$Transport.ServerName;utls=@{enabled=$true;fingerprint='chrome'};reality=@{enabled=$true;public_key=$Transport.RealityPublicKey;short_id=$Transport.RealityShortId}}}
        $outbounds=@($transit)+$outbounds
    }
    $Config | Add-Member NoteProperty outbounds $outbounds -Force
    Assert-TCConfigurationDependencies $Config
    return $Config
}

function Test-TCCheckedConfiguration {
    param([string]$Engine,[string]$Path)
    if (-not [IO.File]::Exists($Engine)) { Stop-TCError '连接引擎不存在，请重新解压完整安装包。' }
    Assert-TCNoReparse $Engine
    $config = Read-TCJson $Path
    Assert-TCConfigurationDependencies $config
    $result = Invoke-TCNative -FilePath $Engine -ArgumentList @('check','-c',$Path)
    if ($result.ExitCode -ne 0) { Stop-TCError '新配置未通过引擎校验，原线路保留；原始诊断已隐藏以保护密钥。' }
}

function Set-TCTransportMode {
    [CmdletBinding()]
    param([string]$Root=$script:TCDefaultRoot,[Parameter(Mandatory=$true)][string]$Id,
        [Parameter(Mandatory=$true)][ValidateSet('Udp','Tcp')][string]$Mode,[hashtable]$TransportParams=@{})
    $ErrorActionPreference='Stop';$lock=$null;$sessionLock=$null;$stage=$null;$final=$null;$committed=$false;$nodeRootCreated=$false
    try {
        $nodeId=ConvertTo-TCId $Id;$store=Initialize-TCStore -Root $Root
        $sessionLock=Open-TCNodeSessionLock $store.root;$lock=Open-TCLock $store.root
        $index=Read-TCIndex $store.root;$oldIndex=ConvertTo-Json $index -Depth 40
        $found=@($index.nodes|Where-Object {$_.id -eq $nodeId})
        if($found.Count -ne 1){Stop-TCError '找不到指定线路。'};$node=$found[0]
        $manifestPath=Get-TCFullPath $node.manifestPath;Assert-TCNoReparse $manifestPath;$manifest=Read-TCJson $manifestPath
        $selected=Assert-TCNodeStopped $store.root $manifestPath $manifest
        $engine=Get-TCFullPath $manifest.EnginePath
        if(-not [IO.File]::Exists($engine)){Stop-TCError '连接引擎不存在，请使用完整安装包；原线路保留。'}
        $config=Read-TCJson (Get-TCFullPath $manifest.CandidatePath)
        $existing=Get-TCTransportFromConfiguration $manifest $config
        $transport=$null
        if($Mode -eq 'Tcp') {
            if($TransportParams.Count){$transport=ConvertTo-TCTransport $TransportParams}
            elseif($existing){$transport=$existing}
            elseif(Get-TCProperty $manifest 'TransportSettings'){$transport=ConvertTo-TCTransport $manifest.TransportSettings}
            else {Stop-TCError '这条线路尚无 TCP 服务参数。请填写该服务器提供的 UUID、Reality 公钥、ShortId 与伪装域名；不会套用其他服务器凭据。'}
        }
        $probePath=[string](Get-TCProperty $manifest 'ProbePath' '');$probe=$null
        if($probePath){$probe=Read-TCJson (Get-TCFullPath $probePath)}
        $nodeRoot=Join-Path (Join-Path $store.root 'nodes') $nodeId
        $nodeRootCreated=(-not [IO.Directory]::Exists($nodeRoot));New-TCPrivateDirectory $nodeRoot
        $suffix=[Guid]::NewGuid().ToString('N');$stage=Join-Path $nodeRoot ('.transport-'+$suffix);$final=Join-Path $nodeRoot ('transport-'+$suffix)
        New-TCPrivateDirectory $stage
        $config=Set-TCConfigurationTransport $config $transport
        Write-TCAtomicJson (Join-Path $stage 'dual-mode.json') $config -NewOnly -NoBom
        Test-TCCheckedConfiguration $engine (Join-Path $stage 'dual-mode.json')
        if($probe){$probe=Set-TCConfigurationTransport $probe $transport;Write-TCAtomicJson (Join-Path $stage 'probe.json') $probe -NewOnly -NoBom;Test-TCCheckedConfiguration $engine (Join-Path $stage 'probe.json')}
        $manifest | Add-Member NoteProperty CandidatePath (Join-Path $final 'dual-mode.json') -Force
        $manifest | Add-Member NoteProperty CandidateSHA256 ((Get-FileHash (Join-Path $stage 'dual-mode.json')).Hash) -Force
        if($probe){$manifest|Add-Member NoteProperty ProbePath (Join-Path $final 'probe.json') -Force;$manifest|Add-Member NoteProperty ProbeSHA256 ((Get-FileHash (Join-Path $stage 'probe.json')).Hash) -Force}
        $manifest|Add-Member NoteProperty Transport $transport -Force
        $settings=if($transport){$transport}elseif($existing){$existing}else{Get-TCProperty $manifest 'TransportSettings'}
        if($settings){$manifest|Add-Member NoteProperty TransportSettings $settings -Force}
        $manifest|Add-Member NoteProperty TCManagedNodeId $nodeId -Force
        $manifest|Add-Member NoteProperty TransportChangedAt ([DateTimeOffset]::UtcNow.ToString('o')) -Force
        $manifest|Add-Member NoteProperty PreviousManifestPath $manifestPath -Force
        $manifest|Add-Member NoteProperty SyntaxValidated $true -Force
        foreach($field in @('ServerForwardingVerified','ProcessRoutingVerified','IndependentGuardVerified')){$manifest|Add-Member NoteProperty $field $false -Force}
        Write-TCAtomicJson (Join-Path $stage 'manifest.json') $manifest -NewOnly
        [IO.Directory]::Move($stage,$final);$stage=$null
        $newManifest=Join-Path $final 'manifest.json';$node.manifestPath=$newManifest
        $deploymentPath=Join-Path (Split-Path $store.root -Parent) 'deployment.json';$oldDeployment=$null
        if($selected){$oldDeployment=Read-TCJson $deploymentPath}
        try {
            Write-TCAtomicJson $store.indexPath $index
            if($selected){$nextDeployment=ConvertFrom-Json (ConvertTo-Json $oldDeployment -Depth 40);$nextDeployment.ManifestPath=$newManifest;Write-TCAtomicJson $deploymentPath $nextDeployment}
        } catch {
            Write-TCAtomicJson $store.indexPath (ConvertFrom-Json $oldIndex)
            if($oldDeployment){Write-TCAtomicJson $deploymentPath $oldDeployment}
            throw
        }
        $committed=$true
        $port=if($transport){[string]$transport.Port}else{[string](ConvertTo-TCEndpoint $manifest.ServerEndpoint).port}
        [pscustomobject]@{NodeId=$nodeId;Name=$node.name;ManifestPath=$newManifest;PreviousManifestPath=$manifestPath;TransportMode=$(if($transport){'tcp-reality'}else{'udp-direct'});Message=('线路「'+$node.name+'」已保存为 '+$(if($transport){'TCP '+$port}else{'UDP '+$port})+'。原配置保留，重新连接后生效。')}
    } catch {Stop-TCOperation $_ '传输配置未保存，请检查引擎、配置或节点库权限；原线路保留。'}
    finally {
        if(-not $committed){foreach($path in @($stage,$final)|Where-Object {$_}){Assert-TCNoReparse $path;if([IO.Directory]::Exists($path)){[IO.Directory]::Delete($path,$true)}}}
        if($lock){$lock.Dispose()};if($sessionLock){$sessionLock.Dispose()}
    }
}

function Remove-TCNode {
    [CmdletBinding()]
    param([string]$Root=$script:TCDefaultRoot,[Parameter(Mandatory=$true)][string]$Id)
    $ErrorActionPreference='Stop';$lock=$null;$sessionLock=$null;$prefLock=$null;$quarantine=$null;$moved=$false;$indexCommitted=$false
    try {
        $nodeId=ConvertTo-TCId $Id;$store=Initialize-TCStore -Root $Root
        $sessionLock=Open-TCNodeSessionLock $store.root;$lock=Open-TCLock $store.root
        $index=Read-TCIndex $store.root;$oldIndex=ConvertTo-Json $index -Depth 40
        $found=@($index.nodes|Where-Object {$_.id -eq $nodeId});if($found.Count -ne 1){Stop-TCError '找不到指定线路。'};$node=$found[0]
        $manifest=$null;$selected=$false
        if($node.manifestPath){Assert-TCNoReparse $node.manifestPath;$manifest=Read-TCJson $node.manifestPath;$selected=Assert-TCNodeStopped $store.root $node.manifestPath $manifest}
        $nodeDir=Get-TCFullPath (Join-Path (Join-Path $store.root 'nodes') $nodeId)
        $owned=[bool]($manifest -and (Test-TCPathWithin (Get-TCFullPath $node.manifestPath) $nodeDir) -and (($node.kind -eq 'wireguard' -and (Get-TCProperty $manifest 'node_id') -eq $nodeId) -or (Get-TCProperty $manifest 'TCManagedNodeId') -eq $nodeId))
        if($owned -and [IO.Directory]::Exists($nodeDir)){
            Assert-TCNoReparse $nodeDir
            foreach($item in Get-ChildItem -LiteralPath $nodeDir -Recurse -Force){Assert-TCNoReparse $item.FullName}
            # Check locks before any file or index disappears.
            foreach($file in Get-ChildItem -LiteralPath $nodeDir -Recurse -File -Force){$held=[IO.File]::Open($file.FullName,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);$held.Dispose()}
            $quarantine=Join-Path (Join-Path $store.root '.staging') ('delete-'+$nodeId+'-'+[Guid]::NewGuid().ToString('N'))
            [IO.Directory]::Move($nodeDir,$quarantine);$moved=$true
        }
        try {
            $index.nodes=@($index.nodes|Where-Object {$_.id -ne $nodeId});Write-TCAtomicJson $store.indexPath $index;$indexCommitted=$true
            if($moved){[IO.Directory]::Delete($quarantine,$true);$moved=$false}
        } catch {
            if($moved -and [IO.Directory]::Exists($quarantine)){[IO.Directory]::Move($quarantine,$nodeDir);$moved=$false}
            if($indexCommitted){Write-TCAtomicJson $store.indexPath (ConvertFrom-Json $oldIndex)}
            throw
        }
        $parent=Split-Path $store.root -Parent;$warnings=New-Object 'Collections.Generic.List[string]'
        if($selected){try{[IO.File]::Delete((Join-Path $parent 'deployment.json'))}catch{$warnings.Add('线路已移除，但已选中记录尚未清除；请重新选择可用线路。')}}
        $prefPath=Join-Path $parent 'ui-preferences.json'
        if([IO.File]::Exists($prefPath)){
            try{$prefLock=[IO.File]::Open((Join-Path $parent '.preferences.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);$prefs=Read-TCJson $prefPath;if((Get-TCProperty $prefs 'NodeId') -eq $nodeId){$prefs.NodeId=$null;Write-TCAtomicJson $prefPath $prefs}}
            catch{$warnings.Add('线路已移除，连接偏好尚未刷新，请在概览页重新选择线路。')}
        }
        [pscustomobject]@{Removed=$true;Id=$nodeId;Name=$node.name;RemainingCount=$index.nodes.Count;PhysicalDirectoryRemoved=$owned;ExternalFilesPreserved=(-not $owned);Warnings=$warnings.ToArray();Message=('已移除线路「'+$node.name+'」。'+$(if(-not $owned){'接管的原始配置目录保留。'}else{''}))}
    } catch {Stop-TCOperation $_ '删除未完成，节点记录保留；请关闭占用配置的程序后重试。'}
    finally {if($prefLock){$prefLock.Dispose()};if($lock){$lock.Dispose()};if($sessionLock){$sessionLock.Dispose()}}
}

function Get-TCTransportInfo {
    [CmdletBinding()]param([string]$Root=$script:TCDefaultRoot,[Parameter(Mandatory=$true)][string]$Id)
    $nodeId=ConvertTo-TCId $Id;$nodes=@(Get-TCNodes -Root $Root|Where-Object {$_.id -eq $nodeId})
    if($nodes.Count -ne 1 -or -not $nodes[0].manifestPath){Stop-TCError '该线路尚未导入配置。'}
    $manifest=Read-TCJson $nodes[0].manifestPath;$config=Read-TCJson $manifest.CandidatePath
    $transport=Get-TCTransportFromConfiguration $manifest $config
    $settings=if($transport){$transport}else{Get-TCProperty $manifest 'TransportSettings'}
    [pscustomobject]@{Id=$nodeId;Name=$nodes[0].name;Endpoint=$nodes[0].endpoint;Transport=$transport;Settings=$settings;DefaultServer=(ConvertTo-TCEndpoint $nodes[0].endpoint).address;Mode=$(if($transport){'Tcp'}else{'Udp'})}
}
