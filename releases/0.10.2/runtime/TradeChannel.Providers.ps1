#requires -Version 5.1
# Provider API: configuration only. No routing, engine or controller mutations.
# Read/Write-TCProviderStore; Add/Update/Remove-TCProvider preserve identity/slots.
# Get-TCManifestProviders exposes daily Tag/Port plus TradeTag/TradePort.
# Resolve-TCProviderTarget -ForTrade substitutes the dedicated target, if present.
$script:TCProviderSlotLimit = 4
$script:TCProviderStoreVersion = 1
$script:TCProviderBootstrapLimit = 256
$script:TCProviderConfLimit = 4194304

function Get-TCProviderValue {
    param($Value,[string]$Key,$Default=$null)
    if($null -eq $Value){return $Default}
    if($Value -is [Collections.IDictionary]){if($Value.Contains($Key)){return $Value[$Key]}}
    elseif($Value.PSObject.Properties[$Key]){return $Value.$Key}
    return $Default
}
function Get-TCProviderTag {
    param([int]$Slot)
    if($Slot -lt 1 -or $Slot -gt 4){throw '服务商 slot 必须在 1–4 之间。'}
    if($Slot -eq 1){'provider'}else{'provider'+$Slot}
}
function Test-TCProviderPathWithin {
    param([string]$Path,[string]$Directory)
    if(-not $Path -or -not $Directory){return $false}
    try{
        $full=[IO.Path]::GetFullPath($Path);$root=[IO.Path]::GetFullPath($Directory).TrimEnd('\','/')
        return $full.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)
    }catch{return $false}
}
function Assert-TCProviderNoReparse {
    param([string]$Path)
    $full=[IO.Path]::GetFullPath($Path)
    while($full){
        if(Test-Path -LiteralPath $full){if((Get-Item -LiteralPath $full -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw '路径经过链接或重解析点，无法可靠验证归属。'}}
        $full=[IO.Path]::GetDirectoryName($full)
    }
}
function Get-TCProviderSafeDirectory {
    param([string]$Path,[switch]$MustExist)
    if(-not $Path -or $Path -notmatch '^[A-Za-z]:[\\/]'){throw '请提供客户端的本机绝对目录。'}
    $full=[IO.Path]::GetFullPath($Path).TrimEnd('\','/')
    if($full -match '[\x00-\x1f*?]' -or @($full.Split('\')).Count -lt 3){throw '请选择客户端自己的文件夹。'}
    foreach($reserved in @($env:WINDIR,$env:ProgramFiles,${env:ProgramFiles(x86)},$env:USERPROFILE,$env:APPDATA,$env:LOCALAPPDATA,$env:ProgramData,$env:TEMP,$env:TMP,$(if($env:LOCALAPPDATA){Join-Path $env:LOCALAPPDATA 'Programs'}))){
        if($reserved -and $full -eq ([IO.Path]::GetFullPath($reserved)).TrimEnd('\')){throw '不能把共用上级目录作为服务商目录。'}
    }
    Assert-TCProviderNoReparse $full
    if($MustExist -and -not [IO.Directory]::Exists($full)){throw '找不到服务商目录。'}
    $full
}
function Read-TCProviderTextFile {
    param([string]$Path)
    if(-not $Path -or -not [IO.File]::Exists($Path)){return $null}
    try{
        if((New-Object IO.FileInfo($Path)).Length -gt $script:TCProviderConfLimit){return $null}
        $stream=[IO.File]::Open($Path,'Open','Read','ReadWrite')
        try{$reader=New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8,$true);try{$reader.ReadToEnd()}finally{$reader.Dispose()}}finally{$stream.Dispose()}
    }catch{$null}
}
function ConvertTo-TCProviderPort {
    param($Value,[switch]$Required,[switch]$AllowReserved)
    if($null -eq $Value -or [string]$Value -eq ''){if($Required){throw '请填写服务商端口。'};return $null}
    $port=0
    if([string]$Value -notmatch '^\d+$' -or -not [int]::TryParse([string]$Value,[ref]$port) -or $port -lt 1 -or $port -gt 65535){throw '端口必须是 1–65535 的整数。'}
    if(-not $AllowReserved -and $port -in @(17890,17891)){throw '端口与 TradeChannel 自身接口冲突。'}
    $port
}
function ConvertTo-TCProviderDomains {
    param([object[]]$Values)
    $domains=New-Object 'Collections.Generic.List[string]'
    foreach($item in @($Values)){
        if(-not $item){continue};$name=([string]$item).Trim().TrimEnd('.').ToLowerInvariant();$ip=$null
        if($name.Length -gt 253 -or $name -notmatch '^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?$' -or [Net.IPAddress]::TryParse($name,[ref]$ip)){throw '启动域名必须是完整域名，不能包含 URL、通配符或 IP。'}
        if(-not $domains.Contains($name)){$domains.Add($name)}
    }
    if($domains.Count -gt $script:TCProviderBootstrapLimit){throw '启动域名最多 256 个。'}
    @($domains.ToArray())
}
function Get-TCProviderDomainsFromText {
    param([string]$Text,[string[]]$Keys=@('server','address'))
    $found=@();$pattern='(?im)^\s*(?:-\s*)?(?:'+(($Keys|ForEach-Object {[regex]::Escape($_)}) -join '|')+')\s*[:=]\s*["'']?([A-Za-z0-9][A-Za-z0-9.\-]*\.[A-Za-z]{2,})["'']?\s*(?:#.*)?$'
    foreach($m in [regex]::Matches([string]$Text,$pattern)){try{$found+=@(ConvertTo-TCProviderDomains @($m.Groups[1].Value))}catch{}}
    ConvertTo-TCProviderDomains @($found|Select-Object -Unique)
}
function Get-TCProviderKindLabel {
    param([string]$Kind)
    switch($Kind){'batvpn'{'BatVPN'} 'clashverge'{'Clash Verge'} 'clash'{'Clash / mihomo'} default{'其他客户端'}}
}
function ConvertTo-TCProviderRecord {
    param($Value)
    if($null -eq $Value){throw '服务商档案为空。'}
    $slot=0;$id=[string](Get-TCProviderValue $Value 'id');$guid=[Guid]::Empty
    if(-not [int]::TryParse([string](Get-TCProviderValue $Value 'slot'),[ref]$slot) -or $slot -lt 1 -or $slot -gt 4){throw '服务商 slot 必须在 1–4 之间。'}
    if(-not [Guid]::TryParseExact($id,'D',[ref]$guid) -or $guid -eq [Guid]::Empty){throw '服务商 ID 无效。'}
    $kind=([string](Get-TCProviderValue $Value 'kind' 'custom')).ToLowerInvariant()
    if($kind -eq 'clash-verge'){$kind='clashverge'}
    if($kind -notin @('batvpn','clashverge','clash','custom')){throw '不支持的服务商类型。'}
    $name=([string](Get-TCProviderValue $Value 'name')).Trim();if(-not $name){$name=Get-TCProviderKindLabel $kind}
    if($name.Length -gt 48 -or $name -match '[\x00-\x1f]'){throw '服务商名称应为 1–48 个可显示字符。'}
    $directory=Get-TCProviderSafeDirectory ([string](Get-TCProviderValue $Value 'directory'))
    $extra=@(@(Get-TCProviderValue $Value 'extraDirectories' @())|Where-Object {$_}|ForEach-Object {Get-TCProviderSafeDirectory ([string]$_)}|Select-Object -Unique)
    $programs=@(@(foreach($item in @(Get-TCProviderValue $Value 'programPaths' @())){
        if(-not $item){continue};$program=[IO.Path]::GetFullPath([string]$item)
        if([string]$item -notmatch '^[A-Za-z]:[\\/]' -or [IO.Path]::GetExtension($program) -ne '.exe' -or -not @(@($directory)+$extra|Where-Object {Test-TCProviderPathWithin $program $_}).Count){throw '程序必须位于该服务商安装目录或额外目录中。'}
        Assert-TCProviderNoReparse $program;$program
    })|Select-Object -Unique)
    if(-not $programs.Count){throw '请提供服务商的可执行程序。'}
    $settings=[string](Get-TCProviderValue $Value 'settingsDirectory');if($settings){$settings=Get-TCProviderSafeDirectory $settings}
    [pscustomobject][ordered]@{
        id=$guid.ToString('D');slot=$slot;name=$name;kind=$kind;directory=$directory;extraDirectories=$extra;programPaths=$programs
        dailyPort=(ConvertTo-TCProviderPort (Get-TCProviderValue $Value 'dailyPort') -Required)
        tradePort=(ConvertTo-TCProviderPort (Get-TCProviderValue $Value 'tradePort'))
        httpPort=(ConvertTo-TCProviderPort (Get-TCProviderValue $Value 'httpPort'));pacPort=(ConvertTo-TCProviderPort (Get-TCProviderValue $Value 'pacPort'))
        bootstrapDomains=@(ConvertTo-TCProviderDomains @(Get-TCProviderValue $Value 'bootstrapDomains' @()))
        settingsDirectory=$(if($settings){$settings}else{$null});addedAt=[string](Get-TCProviderValue $Value 'addedAt')
    }
}
function New-TCProviderRecord {
    param([Parameter(Mandatory=$true)]$Profile,[Parameter(Mandatory=$true)][int]$Slot,[string]$Id)
    if((Get-TCProviderValue $Profile 'BootstrapComplete' $true) -ne $true){throw '上游域名未能完整读取或超过 256 个，不能登记不完整的备用 DNS 规则。'}
    $values=@{};foreach($key in @('kind','name','directory','extraDirectories','programPaths','dailyPort','tradePort','httpPort','pacPort','bootstrapDomains','settingsDirectory','addedAt')){$values[$key]=Get-TCProviderValue $Profile $key}
    if(-not $values.dailyPort){$values.dailyPort=Get-TCProviderValue $Profile 'SocksPort'}
    if(-not $values.kind){$values.kind='custom'}
    $values.id=if($Id){$Id}else{[Guid]::NewGuid().ToString('D')};$values.slot=$Slot
    if(-not $values.addedAt){$values.addedAt=[DateTimeOffset]::Now.ToString('o')}
    $record=ConvertTo-TCProviderRecord $values
    $null=Get-TCProviderSafeDirectory $record.directory -MustExist
    foreach($program in $record.programPaths){if(-not [IO.File]::Exists($program)){throw '找不到服务商可执行程序。'}}
    $record
}
function Assert-TCProviderRecords {
    param([object[]]$Records)
    if(@($Records).Count -gt 4){throw '最多只能登记 4 个服务商。'}
    $ids=@{};$slots=@{};$ports=@{};$directories=@{}
    foreach($r in @($Records)){
        if($ids.ContainsKey($r.id) -or $slots.ContainsKey([string]$r.slot)){throw '服务商 ID 或 slot 重复。'}
        $ids[$r.id]=$true;$slots[[string]$r.slot]=$true
        if($directories.ContainsKey($r.directory)){throw '该安装目录已经登记。'};$directories[$r.directory]=$true
        foreach($port in @($r.dailyPort,$r.tradePort,$r.httpPort,$r.pacPort)|Where-Object {$_}|Select-Object -Unique){
            if($ports.ContainsKey([string]$port)){throw '不同服务商不能共用代理端口。'};$ports[[string]$port]=$true
        }
    }
}
function Get-TCProviderStorePath {param([string]$StoreRoot);Join-Path $StoreRoot 'providers.json'}
function Read-TCProviderStore {
    param([Parameter(Mandatory=$true)][string]$StoreRoot)
    $path=Get-TCProviderStorePath $StoreRoot;$records=@()
    if([IO.File]::Exists($path)){
        $text=Read-TCProviderTextFile $path;if($null -eq $text){throw '服务商列表不可读取，未修改。'}
        try{$parsed=ConvertFrom-Json -InputObject $text}catch{throw '服务商列表 JSON 已损坏，未修改。'}
        if((Get-TCProviderValue $parsed 'version') -ne 1 -or -not $parsed.PSObject.Properties['providers'] -or $null -eq $parsed.providers){throw '服务商列表版本或结构无效，未修改。'}
        $records=@(foreach($item in @(Get-TCProviderValue $parsed 'providers')){ConvertTo-TCProviderRecord $item})
        Assert-TCProviderRecords $records
    }
    [pscustomobject]@{Version=1;Providers=@($records|Sort-Object slot)}
}
function Write-TCProviderAtomicBytes {
    param([string]$Path,[byte[]]$Bytes)
    $full=[IO.Path]::GetFullPath($Path);Assert-TCProviderNoReparse $full
    $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($full))
    $temp=$full+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
    try{
        [IO.File]::WriteAllBytes($temp,$Bytes)
        if([IO.File]::Exists($full)){[IO.File]::Replace($temp,$full,[NullString]::Value)}else{[IO.File]::Move($temp,$full)}
    }finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
}
function Write-TCProviderStore {
    param([Parameter(Mandatory=$true)][string]$StoreRoot,$Store,[object[]]$Providers)
    $entries=if($PSBoundParameters.ContainsKey('Providers')){@($Providers)}else{@(Get-TCProviderValue $Store 'Providers' @())}
    if($null -eq $Store -and -not $PSBoundParameters.ContainsKey('Providers')){throw '必须提供 Store 或 Providers。'}
    $records=@(foreach($entry in $entries){ConvertTo-TCProviderRecord $entry});Assert-TCProviderRecords $records
    # Do not silently overwrite an unreadable registry, even through this low-level API.
    $previous=Read-TCProviderStore $StoreRoot
    foreach($record in $records){$old=@($previous.Providers|Where-Object {$_.id -eq $record.id});if($old.Count -and $old[0].slot -ne $record.slot){throw '已有服务商的 slot 不能改变。'}}
    $next=[pscustomobject]@{Version=1;Providers=@($records|Sort-Object slot)}
    $enc=New-Object Text.UTF8Encoding($true);$bytes=$enc.GetPreamble()+$enc.GetBytes(($next|ConvertTo-Json -Depth 12))
    Write-TCProviderAtomicBytes (Get-TCProviderStorePath $StoreRoot) $bytes
    $next
}
function Get-TCProviderFreeSlot {
    param($Store)
    $used=@(@(Get-TCProviderValue $Store 'Providers' @())|ForEach-Object {[int]$_.slot})
    for($slot=1;$slot -le 4;$slot++){if($slot -notin $used){return $slot}};0
}
function Invoke-TCProviderStoreEdit {
    param([string]$StoreRoot,[scriptblock]$Action)
    # Same lock as ProviderBridge/NodeStore; Write-TCProviderStore itself does not
    # take it because those callers already own it.
    $root=[IO.Path]::GetFullPath($StoreRoot);Assert-TCProviderNoReparse $root
    $null=[IO.Directory]::CreateDirectory($root);$lock=$null;$deadline=[DateTime]::UtcNow.AddSeconds(5)
    try{
        while(-not $lock){
            try{$lock=[IO.File]::Open((Join-Path $root '.store.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}
            catch [IO.IOException]{if([DateTime]::UtcNow -ge $deadline){throw '服务商列表正被另一操作更新。'};Start-Sleep -Milliseconds 50}
        }
        & $Action
    }finally{if($lock){$lock.Dispose()}}
}
function Add-TCProvider {
    param([Parameter(Mandatory=$true)][string]$StoreRoot,[Parameter(Mandatory=$true)]$Profile)
    Invoke-TCProviderStoreEdit $StoreRoot {
        $store=Read-TCProviderStore $StoreRoot;$slot=Get-TCProviderFreeSlot $store;if(-not $slot){throw '最多只能登记 4 个服务商。'}
        $record=New-TCProviderRecord $Profile $slot;$store.Providers=@($store.Providers)+@($record);$null=Write-TCProviderStore $StoreRoot $store;$record
    }
}
function Update-TCProvider {
    param([Parameter(Mandatory=$true)][string]$StoreRoot,[Parameter(Mandatory=$true)][string]$Id,[Parameter(Mandatory=$true)]$Profile)
    Invoke-TCProviderStoreEdit $StoreRoot {
        $store=Read-TCProviderStore $StoreRoot;$old=@($store.Providers|Where-Object {$_.id -eq $Id});if($old.Count -ne 1){throw '找不到该服务商 ID。'}
        $merged=@{};foreach($property in $old[0].PSObject.Properties){$merged[$property.Name]=$property.Value}
        if($Profile -is [Collections.IDictionary]){foreach($key in $Profile.Keys){$merged[$key]=$Profile[$key]}}else{foreach($property in $Profile.PSObject.Properties){$merged[$property.Name]=$property.Value}}
        $merged.addedAt=$old[0].addedAt;$record=New-TCProviderRecord $merged $old[0].slot $old[0].id
        $store.Providers=@(foreach($r in $store.Providers){if($r.id -eq $Id){$record}else{$r}});$null=Write-TCProviderStore $StoreRoot $store;$record
    }
}
function Remove-TCProvider {
    param([Parameter(Mandatory=$true)][string]$StoreRoot,[Parameter(Mandatory=$true)][string]$Id)
    Invoke-TCProviderStoreEdit $StoreRoot {
        $store=Read-TCProviderStore $StoreRoot;if(-not @($store.Providers|Where-Object {$_.id -eq $Id}).Count){throw '找不到该服务商 ID。'}
        $store.Providers=@($store.Providers|Where-Object {$_.id -ne $Id});$null=Write-TCProviderStore $StoreRoot $store
        [pscustomobject]@{Removed=$true;Id=$Id;Providers=$store.Providers}
    }
}
function Get-TCManifestProviders {
    param($Manifest)
    if(-not $Manifest){return @()}
    $entries=@(Get-TCProviderValue $Manifest 'Providers' @())
    if(-not $entries.Count){
        $programs=@(Get-TCProviderValue $Manifest 'ProviderProgramPaths' @());$port=Get-TCProviderValue $Manifest 'ProviderSocksPort'
        if(-not $programs.Count -or -not $port){return @()}
        $entries=@(@{Tag='provider';Id='00000000-0000-0000-0000-000000000001';Slot=1;Kind='batvpn';Name='BatVPN';Port=$port;Directory=(Get-TCProviderValue $Manifest 'ProviderDirectory');Programs=$programs;BootstrapDomains=@(Get-TCProviderValue $Manifest 'ProviderBootstrapDomains' @())})
    }
    $seen=@{}
    @(foreach($entry in $entries){
        $tag=[string](Get-TCProviderValue $entry 'Tag');if(-not $tag){throw 'Manifest 服务商缺少 Tag。'}
        $port=ConvertTo-TCProviderPort (Get-TCProviderValue $entry 'Port') -Required
        $tradePort=ConvertTo-TCProviderPort (Get-TCProviderValue $entry 'TradePort');if(-not $tradePort){$tradePort=$port}
        $tradeTag=[string](Get-TCProviderValue $entry 'TradeTag')
        if(-not $tradeTag){if($tradePort -ne $port){throw 'Manifest 专用端口缺少 TradeTag。'};$tradeTag=$tag}
        if(($tradePort -ne $port) -eq ($tradeTag -eq $tag)){throw 'Manifest 的日常和备用 tag/port 不一致。'}
        foreach($t in @($tag,$tradeTag)|Select-Object -Unique){if($seen.ContainsKey($t)){throw 'Manifest 服务商 Tag 重复。'};$seen[$t]=$true}
        $directory=[string](Get-TCProviderValue $entry 'Directory');$kind=[string](Get-TCProviderValue $entry 'Kind');$name=[string](Get-TCProviderValue $entry 'Name');if(-not $name){$name=Get-TCProviderKindLabel $kind}
        [pscustomobject][ordered]@{
            Tag=$tag;TradeTag=$tradeTag;Port=$port;TradePort=$tradePort;DailyTag=$tag;DailyPort=$port
            Id=[string](Get-TCProviderValue $entry 'Id');Slot=[int](Get-TCProviderValue $entry 'Slot' 1);Kind=$kind;Name=$name;Directory=$directory
            Directories=@(@($directory)+@(Get-TCProviderValue $entry 'Directories' @())+@(Get-TCProviderValue $entry 'ExtraDirectories' @())|Where-Object {$_}|Select-Object -Unique)
            Programs=@(Get-TCProviderValue $entry 'Programs' (Get-TCProviderValue $entry 'ProgramPaths' @()))
            SettingsDirectory=[string](Get-TCProviderValue $entry 'SettingsDirectory')
            BootstrapDomains=@(Get-TCProviderValue $entry 'BootstrapDomains' @())
        }
    })
}
function Resolve-TCProviderTarget {
    param($Manifest,[AllowNull()][AllowEmptyString()][string]$ProviderId,[switch]$ForTrade,[switch]$AllowMissing)
    $providers=@(Get-TCManifestProviders $Manifest);$target=$null
    if(-not [string]::IsNullOrEmpty($ProviderId)){
        $matches=@($providers|Where-Object {$_.Id -and $_.Id -eq $ProviderId})
        if($matches.Count -eq 1){$target=$matches[0]}elseif($matches.Count -eq 0 -and $AllowMissing){return $null}else{throw '服务商 ID 不在当前 manifest 中或不唯一，请检查线路配置。'}
    }elseif($providers.Count){$target=$providers[0]}
    if($target -and $ForTrade){$target.Tag=$target.TradeTag;$target.Port=$target.TradePort}
    $target
}
function Get-TCProviderByTag {
    param($Manifest,[string]$Tag)
    foreach($p in @(Get-TCManifestProviders $Manifest)){if($Tag -eq $p.Tag){return $p};if($Tag -eq $p.TradeTag){$p.Tag=$p.TradeTag;$p.Port=$p.TradePort;return $p}}
    $null
}
function Get-TCProviderProxyPorts {
    param($Manifest,$Store)
    $ports=@(foreach($p in @(Get-TCManifestProviders $Manifest)){$p.Port;$p.TradePort};foreach($r in @(Get-TCProviderValue $Store 'Providers' @())){foreach($key in @('dailyPort','tradePort','httpPort','pacPort')){Get-TCProviderValue $r $key}})
    @($ports|Where-Object {$_}|Select-Object -Unique)
}
# Setup has the only detection/merge implementation. Legacy names are wrappers there.
if(-not (Get-Command Get-TCProviderSetupPlan -ErrorAction SilentlyContinue)){. (Join-Path $PSScriptRoot 'TradeChannel.ProviderSetup.ps1')}
