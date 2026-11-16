#requires -Version 5.1
# Fixed SOCKS slots and watched bypass rule-sets. Dot-sourcing has no side effects.
# The C# listener host lives IN the supervisor; OS process death closes every
# socket. Disk state is never sufficient evidence that a mapping is live.
function Get-TCRelayValue {
    param($Object,[string]$Name,$Default=$null)
    if($null -eq $Object){return $Default}
    if($Object -is [Collections.IDictionary]){if($Object.Contains($Name)){return $Object[$Name]}}
    elseif($Object.PSObject.Properties[$Name]){return $Object.$Name}
    $Default
}
function Get-TCProviderRelayReservedPorts { @(17890,17891)+(17901..17908) }
function Get-TCProviderRelayContract {
    param([Parameter(Mandatory=$true)][string]$Root)
    $full=[IO.Path]::GetFullPath($Root).TrimEnd('\');$dir=Join-Path $full 'providers'
    [pscustomobject][ordered]@{
        Version=1;SlotCount=4;ListenAddress='127.0.0.1';Root=$full
        Slots=@(foreach($slot in 1..4){$tag=if($slot -eq 1){'provider'}else{'provider'+$slot};[pscustomobject]@{Slot=$slot;DailyTag=$tag;TradeTag=($tag+'-trade');DailyPort=(17899+2*$slot);TradePort=(17900+2*$slot)}})
        RouteRuleSetPath=(Join-Path $dir 'bypass-route.json');DnsRuleSetPath=(Join-Path $dir 'bypass-dns.json');StatePath=(Join-Path $dir 'relay-state.json')
    }
}
function Assert-TCRelayNoReparse {
    param([string]$Path)
    $cursor=[IO.Path]::GetFullPath($Path)
    while($cursor){if(Test-Path -LiteralPath $cursor){if((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw '[TC:ProviderRelayUnsafePath] 转发文件路径经过链接。'}};$cursor=[IO.Path]::GetDirectoryName($cursor)}
}
function Set-TCRelayPrivateAcl {
    param([string]$Path)
    Assert-TCRelayNoReparse $Path
    $isDirectory=[IO.Directory]::Exists($Path)
    $acl=if($isDirectory){New-Object Security.AccessControl.DirectorySecurity}else{New-Object Security.AccessControl.FileSecurity}
    $acl.SetAccessRuleProtection($true,$false)
    $inherit=if($isDirectory){[Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'}else{[Security.AccessControl.InheritanceFlags]::None}
    $user=[Security.Principal.WindowsIdentity]::GetCurrent().User
    foreach($sid in @('S-1-5-18','S-1-5-32-544',$user.Value)|Select-Object -Unique){
        $identity=New-Object Security.Principal.SecurityIdentifier($sid)
        $rule=New-Object Security.AccessControl.FileSystemAccessRule($identity,[Security.AccessControl.FileSystemRights]::FullControl,$inherit,[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow)
        $acl.AddAccessRule($rule)
    }
    $acl.SetOwner($user);Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
}
function Initialize-TCRelayDirectory {
    param([string]$Root)
    $directory=Join-Path ([IO.Path]::GetFullPath($Root)) 'providers';Assert-TCRelayNoReparse $directory
    $null=[IO.Directory]::CreateDirectory($directory);Set-TCRelayPrivateAcl $directory;$directory
}
function Write-TCRelayJson {
    param([string]$Path,$Value)
    Assert-TCRelayNoReparse $Path
    $text=ConvertTo-Json -InputObject $Value -Depth 30 -Compress
    if([IO.File]::Exists($Path) -and [IO.File]::ReadAllText($Path) -ceq $text){return}
    $temp=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp';$stream=$null
    try{
        $stream=New-Object IO.FileStream($temp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None,4096,[IO.FileOptions]::WriteThrough)
        Set-TCRelayPrivateAcl $temp
        $bytes=(New-Object Text.UTF8Encoding($false)).GetBytes($text);$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true);$stream.Dispose();$stream=$null
        for($attempt=0;;$attempt++){
            try{if([IO.File]::Exists($Path)){[IO.File]::Replace($temp,$Path,[NullString]::Value)}else{[IO.File]::Move($temp,$Path)};break}
            catch{
                $cause=$_.Exception;while($cause.InnerException){$cause=$cause.InnerException}
                if($cause -isnot [IO.IOException] -or ($cause.HResult -band 65535) -notin @(32,33) -or $attempt -ge 12){throw};Start-Sleep -Milliseconds 25
            }
        }
    }finally{if($stream){$stream.Dispose()};if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
}
function Read-TCRelayJson {
    param([string]$Path)
    Assert-TCRelayNoReparse $Path
    if(-not [IO.File]::Exists($Path)){return $null}
    if((Get-Item -LiteralPath $Path).Length -gt 1048576){throw '[TC:ProviderRelayInvalidState] 转发记录超过限制。'}
    # Let ReplaceFile complete while a reader holds a stable old/new snapshot.
    # File.ReadAllText uses FileShare.Read on .NET 4.8 and races the supervisor's
    # atomic ACK/state writer under a polling UI.
    $stream=$null
    for($attempt=0;;$attempt++){
        try{$stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete));break}
        catch{$cause=$_.Exception;while($cause.InnerException){$cause=$cause.InnerException};if($cause -isnot [IO.IOException] -or ($cause.HResult -band 65535) -notin @(32,33) -or $attempt -ge 12){throw};Start-Sleep -Milliseconds 25}
    }
    try{
        $reader=New-Object IO.StreamReader($stream,(New-Object Text.UTF8Encoding($false,$true)),$true)
        try{$text=$reader.ReadToEnd();if($text.Length -gt 1048576){throw '[TC:ProviderRelayInvalidState] 转发记录超过限制。'};ConvertFrom-Json -InputObject $text}finally{$reader.Dispose()}
    }finally{$stream.Dispose()}
}
function Assert-TCProviderRelayContract {
    param($Manifest,[string]$Root,[switch]$CheckConfiguration)
    $contract=Get-TCRelayValue $Manifest 'ProviderRelay'
    if(-not $contract){throw '[TC:ProviderRelayUpgradeRequired] 当前线路没有固定代理槽，请进行一次受控更新线路配置。'}
    $expected=Get-TCProviderRelayContract $Root
    foreach($field in @('Version','SlotCount','ListenAddress','Root','RouteRuleSetPath','DnsRuleSetPath','StatePath')){if((Get-TCRelayValue $contract $field) -cne $expected.$field){throw '[TC:ProviderRelayContractInvalid] 固定代理入口契约不匹配。'}}
    $slots=@(Get-TCRelayValue $contract 'Slots' @());if($slots.Count -ne 4){throw '[TC:ProviderRelayContractInvalid] 固定代理槽必须完整预留四个。'}
    for($i=0;$i -lt 4;$i++){foreach($field in @('Slot','DailyTag','TradeTag','DailyPort','TradePort')){if((Get-TCRelayValue $slots[$i] $field) -cne $expected.Slots[$i].$field){throw '[TC:ProviderRelayContractInvalid] 固定代理槽位定义无效。'}}}
    foreach($path in @($contract.RouteRuleSetPath,$contract.DnsRuleSetPath,$contract.StatePath)){Assert-TCRelayNoReparse $path}
    foreach($port in @((Get-TCRelayValue $Manifest 'ControlPort'),(Get-TCRelayValue $Manifest 'ProbePort'))){if($port -in (17901..17908)){throw '[TC:ProviderRelayPortConflict] 转发入口与线路接口冲突。'}}
    if($CheckConfiguration){
        $path=[string](Get-TCRelayValue $Manifest 'CandidatePath');Assert-TCRelayNoReparse $path
        if(-not [IO.File]::Exists($path) -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine (Get-TCRelayValue $Manifest 'CandidateSHA256')){throw '[TC:ProviderRelayConfigChanged] 线路配置完整性验证失败。'}
        $cfg=Read-TCRelayJson $path
        foreach($slot in $slots){foreach($lane in @('Daily','Trade')){
            $tag=$slot.($lane+'Tag');$port=$slot.($lane+'Port');$out=@($cfg.outbounds|Where-Object {$_.tag -ceq $tag})
            if($out.Count -ne 1 -or $out[0].type -ne 'socks' -or $out[0].server -cne '127.0.0.1' -or $out[0].server_port -ne $port -or [string]$out[0].version -ne '5'){throw '[TC:ProviderRelayContractInvalid] 线路未使用完整固定 SOCKS 入口。'}
        }}
        foreach($lane in @('daily','trade')){
            $selector=@($cfg.outbounds|Where-Object {$_.tag -ceq ($lane+'-exit')})
            $wanted=@($(if($lane -eq 'daily'){'direct'}else{'hk'}))+@($slots|ForEach-Object {if($lane -eq 'daily'){$_.DailyTag}else{$_.TradeTag}})
            if($selector.Count -ne 1 -or (@($selector[0].outbounds) -join '|') -cne ($wanted -join '|')){throw '[TC:ProviderRelayContractInvalid] 线路选择器没有完整预留固定入口。'}
        }
        foreach($spec in @(@('tc-providers',$contract.RouteRuleSetPath),@('tc-providers-dns',$contract.DnsRuleSetPath))){
            $set=@($cfg.route.rule_set|Where-Object {$_.tag -ceq $spec[0]})
            if($set.Count -ne 1 -or $set[0].type -cne 'local' -or $set[0].format -cne 'source' -or $set[0].path -cne $spec[1]){throw '[TC:ProviderRelayContractInvalid] 缺少代理进程或 DNS 动态绕过文件。'}
        }
        $route=@($cfg.route.rules)[0];$dns=@($cfg.dns.rules)[0]
        if(@($route.rule_set) -notcontains 'tc-providers' -or $route.outbound -cne 'direct' -or @($dns.rule_set) -notcontains 'tc-providers-dns' -or $dns.server -cne 'dns-direct'){throw '[TC:ProviderRelayContractInvalid] 动态直连规则必须先于交易和全局规则。'}
    }
    $contract
}
function Initialize-TCProviderRelayComponent {
    param([string]$PackageRoot=(Split-Path $PSScriptRoot -Parent))
    $relative='runtime\TradeChannelProviderRelay.dll';$path=[IO.Path]::GetFullPath((Join-Path $PackageRoot $relative));$receipt=Join-Path $PackageRoot 'package.sha256'
    foreach($item in @($PackageRoot,$path,$receipt)){Assert-TCRelayNoReparse $item}
    if(-not [IO.File]::Exists($path) -or -not [IO.File]::Exists($receipt)){throw '[TC:ProviderRelayComponentMissing] 缺少随包转发组件，请使用完整安装包。'}
    $allowed=@('S-1-5-18','S-1-5-32-544',[Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
    $mask=[Security.AccessControl.FileSystemRights]'Write,Delete,DeleteSubdirectoriesAndFiles,ChangePermissions,TakeOwnership'
    foreach($item in @($PackageRoot,(Split-Path $path -Parent),$path,$receipt)){
        $acl=Get-Acl -LiteralPath $item -ErrorAction Stop
        foreach($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){if($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference.Value -notin $allowed -and ($rule.FileSystemRights -band $mask)){throw '[TC:ProviderRelayUnsafeAcl] 转发组件可被其他账户写入。'}}
    }
    $rows=@([IO.File]::ReadAllLines($receipt)|Where-Object {$_ -match ('^[A-Fa-f0-9]{64}\|'+[regex]::Escape($relative)+'$')})
    if($rows.Count -ne 1 -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine ($rows[0] -split '\|')[0]){throw '[TC:ProviderRelayIntegrityInvalid] 转发组件校验未通过。'}
    $version=[string](Read-TCRelayJson (Join-Path $PackageRoot 'version.json')).Version;$assembly=[Reflection.AssemblyName]::GetAssemblyName($path)
    if($assembly.Name -cne 'TradeChannelProviderRelay' -or $assembly.Version.ToString() -cne ($version+'.0')){throw '[TC:ProviderRelayVersionConflict] 转发组件版本不匹配。'}
    $type='TradeChannelProviderRelay' -as [type]
    if($type){if(-not [string]::Equals($type.Assembly.Location,$path,[StringComparison]::OrdinalIgnoreCase)){throw '[TC:ProviderRelayVersionConflict] 已加载其他位置的转发组件。'}}else{Add-Type -Path $path -ErrorAction Stop}
}
function Get-TCProviderRelayRecordIdentity {
    param($Record)
    # Display names/timestamps do not define the network identity. Every routing,
    # DNS, directory and executable change does, including same-slot replacement.
    $value=[ordered]@{}
    foreach($field in @('id','slot','kind','directory','dailyPort','tradePort','httpPort','pacPort','settingsDirectory')){$value[$field]=Get-TCRelayValue $Record $field}
    $value.tradePort=if($value.tradePort){[int]$value.tradePort}else{[int]$value.dailyPort}
    foreach($field in @('extraDirectories','programPaths','bootstrapDomains')){$value[$field]=@(@(Get-TCRelayValue $Record $field @())|Sort-Object -Unique)}
    $bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $value -Depth 10 -Compress));$sha=[Security.Cryptography.SHA256]::Create()
    try{[BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','')}finally{$sha.Dispose()}
}
function ConvertTo-TCRelayManifestProviders {
    param([object[]]$Records,$Contract)
    @(foreach($r in @($Records)){$slot=$Contract.Slots[[int]$r.slot-1];[pscustomobject][ordered]@{
        Id=$r.id;Slot=[int]$r.slot;Tag=$slot.DailyTag;TradeTag=$slot.TradeTag;Kind=$r.kind;Name=$r.name
        Port=[int]$r.dailyPort;TradePort=$(if($r.tradePort){[int]$r.tradePort}else{[int]$r.dailyPort});HttpPort=$r.httpPort;PacPort=$r.pacPort
        Directory=$r.directory;ExtraDirectories=@($r.extraDirectories);Programs=@($r.programPaths);BootstrapDomains=@($r.bootstrapDomains);SettingsDirectory=$r.settingsDirectory
        RelayPort=$slot.DailyPort;RelayTradePort=$slot.TradePort;RelayIdentity=(Get-TCProviderRelayRecordIdentity $r)
    }})
}
function ConvertFrom-TCRelayManifestProviders {
    param([object[]]$Entries)
    @(foreach($p in @($Entries)){[pscustomobject]@{id=$p.Id;slot=[int]$p.Slot;kind=$p.Kind;name=$p.Name;directory=$p.Directory;extraDirectories=@(Get-TCRelayValue $p 'ExtraDirectories' @());programPaths=@($p.Programs);dailyPort=$p.Port;tradePort=$p.TradePort;httpPort=(Get-TCRelayValue $p 'HttpPort');pacPort=(Get-TCRelayValue $p 'PacPort');bootstrapDomains=@(Get-TCRelayValue $p 'BootstrapDomains' @());settingsDirectory=(Get-TCRelayValue $p 'SettingsDirectory');addedAt=''}})
}
function Get-TCProviderRelayLiveState {
    param($Manifest)
    try{
        $contract=Get-TCRelayValue $Manifest 'ProviderRelay';if(-not $contract){return $null}
        $null=Assert-TCProviderRelayContract $Manifest ([string]$contract.Root)
        $state=Read-TCRelayJson $contract.StatePath
        if(-not $state -or $state.Version -ne 1 -or -not $state.Active -or $state.CandidateSHA256 -cne $Manifest.CandidateSHA256 -or $state.CandidatePath -cne $Manifest.CandidatePath){return $null}
        $runtime=Read-TCRelayJson (Join-Path $contract.Root 'runtime.json')
        if(-not $runtime -or $runtime.State -cne 'Running' -or $runtime.SessionId -cne $state.SessionId -or $runtime.SupervisorPid -ne $state.SupervisorPid -or $runtime.SupervisorStartedAt -cne $state.SupervisorStartedAt -or $runtime.ConfigPath -cne $state.CandidatePath){return $null}
        $p=Get-Process -Id ([int]$state.SupervisorPid) -ErrorAction Stop
        if($p.StartTime.ToUniversalTime().Ticks -ne ([DateTimeOffset]$state.SupervisorStartedAt).UtcDateTime.Ticks -or $p.HasExited){return $null}
        $engine=Get-Process -Id ([int]$runtime.EnginePid) -ErrorAction Stop
        if($engine.HasExited -or $engine.StartTime.ToUniversalTime().Ticks -ne ([DateTimeOffset]$runtime.EngineStartedAt).UtcDateTime.Ticks){return $null}
        if(([DateTimeOffset]::UtcNow-([DateTimeOffset]$state.ObservedAt)).TotalSeconds -gt 60){return $null}
        $state
    }catch{$null}
}
function Get-TCProviderRelayTargetHealth {
    param($Provider,$Manifest,[switch]$ForTrade,[switch]$SkipTunnelCheck)
    $port=if($ForTrade){[int]$Provider.RelayTradePort}else{[int]$Provider.Port}
    $upstreamPort=if($ForTrade){[int]$Provider.UpstreamTradePort}else{[int]$Provider.UpstreamPort}
    $lane=if($port -eq $Provider.RelayTradePort){'trade'}else{'daily'}
    $result=[ordered]@{Configured=$true;Port=$port;UpstreamPort=$upstreamPort;Name=$Provider.Name;Tag=$Provider.Tag;Id=$Provider.Id;Listening=$false;OwnerPath=$null;OwnerPaths=@();OwnerIds=@();IdentityVerified=$false;LoopbackReachable=$false;ForeignTunnel=$null;Healthy=$false;TradingEgressVerified=$false;Reason='RelayUnavailable';RelayOwnerId=$null}
    $evidence=[pscustomobject]@{ProviderRelay=$Provider.RelayContract;CandidatePath=$Provider.RelayCandidatePath;CandidateSHA256=$Provider.RelayCandidateSHA256}
    $live=Get-TCProviderRelayLiveState $evidence
    if(-not $live -or $live.Faulted){return [pscustomobject]$result}
    $binding=@($live.Bindings|Where-Object {$_.ProviderId -ceq $Provider.Id -and $_.Slot -eq $Provider.Slot -and $_.Lane -ceq $lane -and $_.Port -eq $upstreamPort -and $_.Healthy})
    if($binding.Count -ne 1 -or ($Provider.RelaySessionId -and $Provider.RelaySessionId -cne $live.SessionId)){$result.Reason='RelayMappingMismatch';return [pscustomobject]$result}
    try{
        $owners=@(Get-TCListenerOwnerIds $port);$addresses=@(Get-TCProviderListenerAddresses $port)
        if($owners.Count -ne 1 -or $owners[0] -ne $live.SupervisorPid -or $addresses.Count -ne 1 -or $addresses[0] -cne '127.0.0.1'){$result.Reason='RelayNotListening';return [pscustomobject]$result}
        $upstream=[pscustomobject]@{Id=$Provider.Id;Name=$Provider.Name;Kind=$Provider.Kind;Tag=$Provider.Tag;Port=$upstreamPort;Directory=$Provider.Directory;Directories=$Provider.Directories;Programs=$Provider.Programs}
        $health=Get-TCProviderHealth -Manifest $Manifest -Provider $upstream -SkipTunnelCheck:$SkipTunnelCheck
        if(-not $health.Healthy){$result.Reason=$health.Reason;return [pscustomobject]$result}
        $owner=Get-Process -Id ([int]$binding[0].OwnerPid) -ErrorAction Stop
        if(@($health.OwnerIds).Count -ne 1 -or $health.OwnerIds[0] -ne $binding[0].OwnerPid -or $owner.StartTime.ToUniversalTime().Ticks -ne $binding[0].OwnerStartedTicks -or $health.OwnerPath -ine $binding[0].OwnerPath){$result.Reason='RelayMappingMismatch';return [pscustomobject]$result}
        foreach($key in @('Listening','OwnerPath','OwnerPaths','OwnerIds','IdentityVerified','LoopbackReachable','ForeignTunnel')){$result[$key]=$health.$key}
        $result.RelayOwnerId=$live.SupervisorPid;$result.Healthy=$true;$result.Reason=$null
    }catch{$result.Reason='InspectionFailed'}
    [pscustomobject]$result
}
function New-TCProviderBypassRuleSets {
    param([object[]]$Records,[string[]]$TradePrograms=@(),[string]$AgentRuleSetPath,[string[]]$AdditionalDomains=@())
    $module=Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'NodeStore.psm1') -PassThru -DisableNameChecking
    $providers=@(ConvertTo-TCPolicyProviders -Providers $Records -TradePrograms $TradePrograms -ReservedPorts (Get-TCProviderRelayReservedPorts) -AllowMissingPrograms)
    $programs=@(@(foreach($p in $providers){@($p.Programs)})|Sort-Object -Unique)
    if($AgentRuleSetPath -and [IO.File]::Exists($AgentRuleSetPath) -and $programs.Count){& $module {param($Path,$Programs);$rules=Read-TCJson $Path;Assert-TCProviderAgentSeparation $rules.rules $Programs} $AgentRuleSetPath $programs}
    $extras=@(& $module {param($Domains);ConvertTo-TCDomains $Domains} $AdditionalDomains)
    $domains=@(@(@(foreach($p in $providers){@($p.BootstrapDomains)})+$extras)|Sort-Object -Unique)
    $route=@();$dns=@()
    # Exact executable paths are mandatory for listener ownership as well. A
    # renamed/replaced core must be rediscovered, never widened to a shared folder.
    if($programs.Count){$route+=@{process_path=$programs};$dns+=@{process_path=$programs}}
    if($domains.Count){$dns+=@{domain=$domains}}
    [pscustomobject]@{Route=[ordered]@{version=3;rules=$route};Dns=[ordered]@{version=3;rules=$dns}}
}
function Get-TCProviderRelayBindings {
    param([object[]]$Records,$Manifest,[switch]$AllowUnavailable)
    $bindings=New-Object 'Collections.Generic.List[object]';$unavailable=New-Object 'Collections.Generic.List[object]'
    foreach($r in @($Records)){
        foreach($lane in @('daily','trade')){
            $port=if($lane -eq 'trade' -and $r.tradePort){[int]$r.tradePort}else{[int]$r.dailyPort}
            $target=[pscustomobject]@{Id=$r.id;Name=$r.name;Kind=$r.kind;Port=$port;Directory=$r.directory;Directories=@($r.directory)+@($r.extraDirectories);Programs=@($r.programPaths);Tag=(Get-TCProviderTag $r.slot)}
            $health=Get-TCProviderHealth -Manifest $Manifest -Provider $target
            $good=[bool]($health.Healthy -and @($health.OwnerIds).Count -eq 1)
            if($good){$good=[TradeChannelProviderRelay]::ProbeSocks($port,1200)}
            if(-not $good){
                $reason=if($health.Reason){$health.Reason}else{'SocksHandshakeFailed'}
                $unavailable.Add([pscustomobject]@{Id=$r.id;Lane=$lane;Reason=$reason})
                if(-not $AllowUnavailable){throw '[TC:ProviderRelayUpstreamUnhealthy] 代理监听、归属或 SOCKS 检查未通过。'};continue
            }
            $owner=Get-Process -Id ([int]$health.OwnerIds[0]) -ErrorAction Stop
            $binding=New-Object TCProviderRelayBinding
            $binding.Slot=[int]$r.slot;$binding.Lane=$lane;$binding.ProviderId=$r.id;$binding.Port=$port;$binding.OwnerPid=[int]$health.OwnerIds[0];$binding.OwnerStartedTicks=$owner.StartTime.ToUniversalTime().Ticks;$binding.OwnerPath=$health.OwnerPath;$binding.Identity=Get-TCProviderRelayRecordIdentity $r
            $bindings.Add($binding)
        }
    }
    [pscustomobject]@{Bindings=$bindings.ToArray();Unavailable=$unavailable.ToArray()}
}
function Write-TCProviderRelayState {
    param($Context,$RequestResult=$null)
    if($RequestResult){$Context.LastRequest=$RequestResult}
    $state=[ordered]@{Version=1;Active=[bool]($Context.Host -and $Context.Host.Running);SessionId=$Context.SessionId;SupervisorPid=$PID;SupervisorStartedAt=$Context.SupervisorStartedAt;CandidatePath=$Context.Manifest.CandidatePath;CandidateSHA256=$Context.Manifest.CandidateSHA256;Revision=$Context.Host.Revision;ObservedAt=[DateTimeOffset]::UtcNow.ToString('o');Providers=@(ConvertTo-TCRelayManifestProviders $Context.Records $Context.Contract);Bindings=@($Context.Host.Snapshot());Unavailable=@($Context.Unavailable);LastRequest=$Context.LastRequest;Faulted=[bool]$Context.Faulted}
    Write-TCRelayJson $Context.Contract.StatePath $state
}
function Repair-TCProviderRelayTransaction {
    param([string]$Root)
    $directory=Initialize-TCRelayDirectory $Root;$path=Join-Path $directory 'relay-transaction.json';$journal=Read-TCRelayJson $path
    if(-not $journal){return}
    if($journal.Version -ne 1){throw '[TC:ProviderRelayRecoveryRequired] 转发恢复记录无法识别。'}
    if($journal.Phase -ne 'Committed'){
        # No live mappings survive process death; restore the last committed
        # desired profiles before fresh owner/health validation on this start.
        $applied=Join-Path $directory 'relay-applied.json'
        if($journal.BeforeApplied){Write-TCRelayJson $applied $journal.BeforeApplied}elseif([IO.File]::Exists($applied)){[IO.File]::Delete($applied)}
    }
    [IO.File]::Delete($path)
}
function Start-TCProviderRelay {
    param([string]$Root,$Manifest,[string]$SessionId)
    $contract=Assert-TCProviderRelayContract $Manifest $Root -CheckConfiguration
    Initialize-TCProviderRelayComponent
    $directory=Initialize-TCRelayDirectory $Root;Repair-TCProviderRelayTransaction $Root
    $records=@(ConvertFrom-TCRelayManifestProviders @(Get-TCRelayValue $Manifest 'Providers' @()))
    $applied=Read-TCRelayJson (Join-Path $directory 'relay-applied.json')
    if($applied -and $applied.Version -eq 1 -and $applied.CandidateSHA256 -ceq $Manifest.CandidateSHA256 -and $applied.CandidatePath -ceq $Manifest.CandidatePath){$records=@($applied.Records)}
    if([IO.File]::Exists((Join-Path $Root 'Product\providers.json'))){$registered=@((Read-TCProviderStore (Join-Path $Root 'Product')).Providers);$records=@($records|Where-Object {$id=$_.id;@($registered|Where-Object {$_.id -eq $id}).Count -eq 1})}
    $records=@(foreach($r in $records){ConvertTo-TCProviderRecord $r})
    $sets=New-TCProviderBypassRuleSets $records @($Manifest.TradeProgramPaths) ([string](Get-TCRelayValue $Manifest 'AgentRuleSetPath')) @(Get-TCRelayValue $Manifest 'ProviderRelayBootstrapDomains' @())
    $hostObject=$null
    try{
        $ports=[int[]]@(foreach($s in $contract.Slots){$s.DailyPort;$s.TradePort})
        $hostObject=New-Object TCProviderRelayHost($SessionId,$ports,[int[]]@($Manifest.ControlPort,$Manifest.ProbePort))
        Write-TCRelayJson $contract.RouteRuleSetPath $sets.Route;Write-TCRelayJson $contract.DnsRuleSetPath $sets.Dns
        $proof=Get-TCProviderRelayBindings $records $Manifest -AllowUnavailable
        $hostObject.Replace([TCProviderRelayBinding[]]$proof.Bindings,'empty',[guid]::NewGuid().ToString('N'),[string[]]@())
        $context=[pscustomobject]@{Root=$Root;Directory=$directory;Manifest=$Manifest;Contract=$contract;Host=$hostObject;SessionId=$SessionId;SupervisorStartedAt=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o');Records=$records;Unavailable=$proof.Unavailable;LastRequest=$null;Faulted=$false;LastStateWrite=[DateTime]::UtcNow}
        Write-TCProviderRelayState $context
        $context
    }catch{if($hostObject){$hostObject.Dispose()};throw}
}
function Get-TCProviderRelayErrorCode {
    param($ErrorRecord)
    $message=[string]$ErrorRecord.Exception.Message
    foreach($code in @('SelectedProviderImmutable','RelayRevisionChanged','UpstreamOwnerMismatch','SocksHandshakeFailed','ProviderRelayUpstreamUnhealthy','ProviderRelayForwardingFailed','ProviderRelayTradeUnverified','ProviderRelayContractInvalid','ProviderRelayUpgradeRequired','ProviderRelayRequestStale','ProviderRelayRegistryChanged','ProviderRelayUnavailable','ProviderRelayApplyTimeout','ProviderRelayMappingMismatch','ProviderRelaySessionChanged','ProviderOperationBusy','ProviderInUse','ProviderRuntimeUncertain','ProviderClientMergeRequired')){if($message.Contains($code)){return $code}}
    'ProviderRelayApplyFailed'
}
function Invoke-TCProviderRelayCommit {
    param($Context,$Request,[string[]]$ProtectedTags=@())
    if($Context.Faulted -or -not $Context.Host.Running){throw '[TC:ProviderRelayUnavailable] 固定代理转发器不可用。'}
    if($Request.Version -ne 1 -or $Request.SessionId -cne $Context.SessionId -or $Request.CandidateSHA256 -cne $Context.Manifest.CandidateSHA256 -or $Request.ExpectedRevision -cne $Context.Host.Revision -or ([DateTimeOffset]::UtcNow-([DateTimeOffset]$Request.CreatedAt)).TotalSeconds -gt 20){throw '[TC:ProviderRelayRequestStale] 本次接入请求已经过期，请重新检查。'}
    $requestId=[guid]::Empty;if(-not [guid]::TryParseExact([string]$Request.RequestId,'N',[ref]$requestId)){throw '[TC:ProviderRelayRequestStale] 请求标识无效。'}
    $records=@(foreach($r in @($Request.Records)){ConvertTo-TCProviderRecord $r});Assert-TCProviderRecords $records
    $registered=@((Read-TCProviderStore (Join-Path $Context.Root 'Product')).Providers)
    foreach($r in $records){$match=@($registered|Where-Object {$_.id -ceq $r.id});if($match.Count -ne 1 -or (Get-TCProviderRelayRecordIdentity $match[0]) -cne (Get-TCProviderRelayRecordIdentity $r)){throw '[TC:ProviderRelayRegistryChanged] 接入期间代理档案已变化，请刷新。'}}
    # Protected identities are checked before writing a single bypass file, and
    # again atomically by the C# host at commit.
    foreach($tag in $ProtectedTags){
        $key=[TCProviderRelayHost]::TagKey($tag);if($key -lt 0){continue};$slot=[int][Math]::Floor($key/2)+1
        $before=@($Context.Records|Where-Object {$_.slot -eq $slot});$after=@($records|Where-Object {$_.slot -eq $slot})
        if($before.Count -ne 1 -or $after.Count -ne 1 -or (Get-TCProviderRelayRecordIdentity $before[0]) -cne (Get-TCProviderRelayRecordIdentity $after[0])){throw '[TC:SelectedProviderImmutable] 该代理正在承载流量，不能热改身份或端口。'}
    }
    $sets=New-TCProviderBypassRuleSets $records @($Context.Manifest.TradeProgramPaths) ([string](Get-TCRelayValue $Context.Manifest 'AgentRuleSetPath')) @(Get-TCRelayValue $Context.Manifest 'ProviderRelayBootstrapDomains' @())
    $proof=Get-TCProviderRelayBindings $records $Context.Manifest -AllowUnavailable
    foreach($id in @($Request.RequireIds)){if(@($proof.Unavailable|Where-Object {$_.Id -ceq $id -and ($_.Lane -eq 'daily' -or [bool]$Request.ForTrade)}).Count){throw '[TC:ProviderRelayUpstreamUnhealthy] 代理监听、归属或 SOCKS 检查未通过。'}}
    $oldBindings=[TCProviderRelayBinding[]]$Context.Host.Snapshot();$oldRevision=$Context.Host.Revision;$oldRecords=@($Context.Records);$oldUnavailable=@($Context.Unavailable)
    # Keep unchanged live bindings pinned to their original process birth. A
    # new process on the same port is a new identity, including on trade slots.
    foreach($tag in $ProtectedTags){$key=[TCProviderRelayHost]::TagKey($tag);if($key -ge 0){$old=@($oldBindings|Where-Object {$_.Slot -eq ([int][Math]::Floor($key/2)+1) -and $_.Lane -eq $(if($key%2){'trade'}else{'daily'})});$next=@($proof.Bindings|Where-Object {$_.Slot -eq ([int][Math]::Floor($key/2)+1) -and $_.Lane -eq $(if($key%2){'trade'}else{'daily'})});if($old.Count -ne 1 -or $next.Count -ne 1 -or $old[0].OwnerPid -ne $next[0].OwnerPid -or $old[0].OwnerStartedTicks -ne $next[0].OwnerStartedTicks){throw '[TC:SelectedProviderImmutable] 正在使用的代理进程身份已变化。'}}}
    $Context.Host.Validate([TCProviderRelayBinding[]]$proof.Bindings)
    $appliedPath=Join-Path $Context.Directory 'relay-applied.json';$journalPath=Join-Path $Context.Directory 'relay-transaction.json'
    $beforeApplied=Read-TCRelayJson $appliedPath;$oldRoute=Read-TCRelayJson $Context.Contract.RouteRuleSetPath;$oldDns=Read-TCRelayJson $Context.Contract.DnsRuleSetPath
    $journal=[ordered]@{Version=1;Phase='Prepared';RequestId=$Request.RequestId;SessionId=$Context.SessionId;BeforeApplied=$beforeApplied;BeforeRoute=$oldRoute;BeforeDns=$oldDns}
    Write-TCRelayJson $journalPath $journal
    $changed=$false
    try{
        # Add-before-remove: current connections keep their direct bypass while
        # the engine reloads new exact executable/DNS entries. No selector write.
        $unionRoute=@{version=3;rules=@($oldRoute.rules)+@($sets.Route.rules)};$unionDns=@{version=3;rules=@($oldDns.rules)+@($sets.Dns.rules)}
        Write-TCRelayJson $Context.Contract.RouteRuleSetPath $unionRoute;Write-TCRelayJson $Context.Contract.DnsRuleSetPath $unionDns
        # sing-box's source rule-set watcher is asynchronous. Allow reload before
        # opening new targets; a loopback integration test exercises that watcher.
        Start-Sleep -Milliseconds 1200
        $tradeReady=$false
        foreach($id in @($Request.RequireIds)){
            $r=@($records|Where-Object {$_.id -ceq $id})
            if($r.Count -ne 1){throw '[TC:ProviderRelayRegistryChanged] 接入对象不在本次档案中。'}
            $dailyProbe=Test-TCProviderForwarding -Port ([int]$r[0].dailyPort) -TimeoutSeconds 6
            if(-not $dailyProbe.Ok){throw '[TC:ProviderRelayForwardingFailed] 代理未通过实际转发检查。'}
            if($Request.ForTrade){
                $tradePort=if($r[0].tradePort){[int]$r[0].tradePort}else{[int]$r[0].dailyPort}
                $tradeTarget=[pscustomobject]@{Id=$r[0].id;Name=$r[0].name;Kind=$r[0].kind;Port=$tradePort;Directory=$r[0].directory;Directories=@($r[0].directory)+@($r[0].extraDirectories);Programs=@($r[0].programPaths);SettingsDirectory=$r[0].settingsDirectory;Tag=((Get-TCProviderTag $r[0].slot)+'-trade')}
                $policy=Test-TCProviderTradingPolicy -Provider $tradeTarget
                if(-not $policy.Allowed){throw '[TC:ProviderRelayTradeUnverified] 交易代理策略尚未得到可靠验证。'}
                $tradeProbe=Test-TCProviderForwarding -Port $tradePort -TimeoutSeconds 6
                if(-not $tradeProbe.Ok){throw '[TC:ProviderRelayForwardingFailed] 交易备用端口未通过转发检查。'}
                $tradeReady=$true
            }
        }
        if(([DateTimeOffset]::UtcNow-([DateTimeOffset]$Request.CreatedAt)).TotalSeconds -gt 28){throw '[TC:ProviderRelayRequestStale] 接入检查超时，未启用新映射。'}
        $Context.Host.Replace([TCProviderRelayBinding[]]$proof.Bindings,$oldRevision,[string]$Request.RequestId,$ProtectedTags);$changed=$true
        Write-TCRelayJson $Context.Contract.RouteRuleSetPath $sets.Route;Write-TCRelayJson $Context.Contract.DnsRuleSetPath $sets.Dns
        $next=[ordered]@{Version=1;CandidatePath=$Context.Manifest.CandidatePath;CandidateSHA256=$Context.Manifest.CandidateSHA256;Revision=$Request.RequestId;Records=$records;CommittedAt=[DateTimeOffset]::UtcNow.ToString('o')}
        Write-TCRelayJson $appliedPath $next
        $Context.Records=$records;$Context.Unavailable=$proof.Unavailable
        $journal.Phase='Committed';Write-TCRelayJson $journalPath $journal
        # A committed receipt is safe to retain for next-start cleanup. Failure
        # to delete it is not permission to undo an already committed mapping.
        try{[IO.File]::Delete($journalPath)}catch{}
        [pscustomobject]@{DailyForwarding=(@($Request.RequireIds).Count -gt 0);TradeReadyBeforeSwitch=$tradeReady}
    }catch{
        $failure=$_;$rollbackFailed=$false
        try{if($changed){$Context.Host.Replace($oldBindings,$Context.Host.Revision,$oldRevision,[string[]]@())};$Context.Records=$oldRecords;$Context.Unavailable=$oldUnavailable}catch{$rollbackFailed=$true}
        try{Write-TCRelayJson $Context.Contract.RouteRuleSetPath $oldRoute;Write-TCRelayJson $Context.Contract.DnsRuleSetPath $oldDns;if($beforeApplied){Write-TCRelayJson $appliedPath $beforeApplied}elseif([IO.File]::Exists($appliedPath)){[IO.File]::Delete($appliedPath)}}catch{$rollbackFailed=$true}
        if($rollbackFailed){$Context.Faulted=$true;$Context.Host.Dispose()}else{if([IO.File]::Exists($journalPath)){[IO.File]::Delete($journalPath)}}
        throw $failure
    }
}
function Sync-TCProviderRelay {
    param($Context,[scriptblock]$GetProtectedTags)
    if(-not $Context){return}
    $path=Join-Path $Context.Directory 'relay-request.json';$request=$null
    try{$request=Read-TCRelayJson $path}catch{}
    if($request -and (-not $Context.LastRequest -or $Context.LastRequest.RequestId -cne $request.RequestId)){
        $result=[ordered]@{RequestId=[string]$request.RequestId;Succeeded=$false;Code='ProviderRelayApplyFailed';CompletedAt=$null}
        try{
            if(-not $GetProtectedTags){throw 'Controller selection evidence unavailable'}
            $tags=@(& $GetProtectedTags)
            $proof=Invoke-TCProviderRelayCommit $Context $request $tags
            $result.Succeeded=$true;$result.Code='Applied'
            $result.DailyForwarding=[bool]$proof.DailyForwarding;$result.TradeReadyBeforeSwitch=[bool]$proof.TradeReadyBeforeSwitch
        }catch{$result.Code=Get-TCProviderRelayErrorCode $_}
        $result.CompletedAt=[DateTimeOffset]::UtcNow.ToString('o');Write-TCProviderRelayState $Context ([pscustomobject]$result);$Context.LastStateWrite=[DateTime]::UtcNow
        # Keep the acknowledgement and failed transaction for diagnosis; an old
        # request cannot be executed on a later session.
    }elseif(([DateTime]::UtcNow-$Context.LastStateWrite).TotalSeconds -ge 2){Write-TCProviderRelayState $Context;$Context.LastStateWrite=[DateTime]::UtcNow}
}
function Stop-TCProviderRelay {
    param($Context)
    if(-not $Context){return}
    $Context.Host.Dispose();$Context.Records=@();$Context.Unavailable=@()
    Write-TCProviderRelayState $Context
    # Never leave a stale direct bypass in a future session. Startup recreates
    # both sets from committed, revalidated profiles before starting the engine.
    Write-TCRelayJson $Context.Contract.RouteRuleSetPath @{version=3;rules=@()};Write-TCRelayJson $Context.Contract.DnsRuleSetPath @{version=3;rules=@()}
}
