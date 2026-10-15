#requires -Version 5.1
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'runtime\TradeChannel.Provider.ps1')
. (Join-Path $PSScriptRoot 'runtime\TradeChannel.ProviderSetup.ps1')

function Get-TCProviderContext {
    param([string]$Root)
    $deploymentPath=Join-Path $Root 'deployment.json';$manifest=$null
    if(Test-Path -LiteralPath $deploymentPath){$d=Get-Content -LiteralPath $deploymentPath -Encoding UTF8 -Raw|ConvertFrom-Json;$manifest=Get-Content -LiteralPath $d.ManifestPath -Encoding UTF8 -Raw|ConvertFrom-Json}
    $prefPath=Join-Path $Root 'ui-preferences.json';$prefs=$null
    if(Test-Path -LiteralPath $prefPath){$prefs=Get-Content -LiteralPath $prefPath -Encoding UTF8 -Raw|ConvertFrom-Json}
    [pscustomobject]@{Manifest=$manifest;Preferences=$prefs;StoreRoot=(Join-Path $Root 'Product');BackupRoot=(Join-Path $Root 'backup\providers')}
}
function Get-TCProviderOverview {
    param([string]$Root)
    $ctx=Get-TCProviderContext $Root;$store=Read-TCProviderStore $ctx.StoreRoot
    $applied=@(Get-TCManifestProviders $ctx.Manifest)
    $items=@(foreach($record in @($store.Providers)){
        $live=@($applied|Where-Object {Test-TCProviderAppliedRecord $_ $record})
        $health=$null;$state=$null
        try{
            $target=[pscustomobject]@{Id=$record.id;Name=$record.name;Kind=$record.kind;Tag=(Get-TCProviderTag $record.slot);Port=$record.dailyPort;Directory=$record.directory;Directories=@($record.directory)+@($record.extraDirectories);Programs=@($record.programPaths)}
            $health=Get-TCProviderHealth -Provider $target
            $state=Get-TCProviderClientState $record|Select-Object SystemProxy,TunMode,ProxyGuard,SnifferReady,MergePath,Notes,Effective,TradingEgressVerified
        }catch{$health=[pscustomobject]@{Healthy=$false;Reason='InspectionFailed'}}
        [pscustomobject]@{Id=$record.id;Name=$record.name;Kind=$record.kind;DailyPort=$record.dailyPort;TradePort=$record.tradePort;Directory=$record.directory;Registered=$true;Applied=($live.Count -eq 1);Health=$health;ClientState=$state}
    })
    # The internal detector also inspects raw proxy definitions. Never serialize
    # them (or controller secrets/subscription URLs) into UI worker results.
    $candidates=@(Find-TCProviderCandidates|Select-Object Kind,Name,Directory,DailyPort,TradePort,Detected,Ready,Issues)
    $selected=[string]$ctx.Preferences.ProviderId
    $active=@($applied|Where-Object {$_.Id -eq $selected})
    if(-not $selected -and $applied.Count){$active=@($applied[0])}
    [pscustomobject]@{Items=$items;Candidates=$candidates;SelectedProviderId=$selected;ActiveProviderName=$(if($active.Count){$active[0].Name}else{$null});RequiresUpgrade=[bool](@($items|Where-Object {-not $_.Applied}).Count);SelectionChangesTrading=$false}
}
function Register-TCProviderProfile {
    param($Request,[string]$Root)
    Import-Module (Join-Path $PSScriptRoot 'NodeStore.psm1') -DisableNameChecking
    $ctx=Get-TCProviderContext $Root
    $null=Initialize-TCStore -Root $ctx.StoreRoot
    # Registry updates are serialized, and never write deployment/engine state.
    $lock=[IO.File]::Open((Join-Path $ctx.StoreRoot '.store.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try{
        $store=Read-TCProviderStore $ctx.StoreRoot;$records=@($store.Providers)
        if(-not $records.Count -and $ctx.Manifest){
            foreach($old in @(ConvertFrom-TCManifestProviders $ctx.Manifest)){
                $profile=[pscustomobject]@{Kind=$old.kind;Name=$old.name;Directory=$old.directory;ExtraDirectories=@($old.extraDirectories);ProgramPaths=@($old.programPaths);DailyPort=$old.dailyPort;TradePort=$old.tradePort;HttpPort=$old.httpPort;PacPort=$old.pacPort;BootstrapDomains=@($old.bootstrapDomains)}
                $records+=New-TCProviderRecord -Profile $profile -Slot $old.slot -Id $old.id
            }
        }
        $kind=if($Request.CandidateKind){[string]$Request.CandidateKind}else{[string]$Request.Kind}
        if($kind -in @('batvpn','clashverge')){
            $matches=@(Find-TCProviderCandidates|Where-Object {$_.Kind -eq $kind})
            if($matches.Count -ne 1){throw '尚未找到该客户端，请先安装并完成一次订阅导入，再点击自动发现。'}
            $profile=$matches[0]
            if(-not $profile.BootstrapComplete){throw '尚未完整识别客户端的上游节点域名。请先导入并加载订阅后重新检测；不登记可能依赖香港 DNS 的备用线路。'}
        }elseif($kind -in @('custom','manual')){
            $dir=[string]$Request.Directory
            if(-not $dir -or -not [IO.Directory]::Exists($dir)){throw '请选择代理客户端自己的安装目录。'}
            $programs=@(Get-ChildItem -LiteralPath $dir -Filter '*.exe' -File|Select-Object -ExpandProperty FullName)
            $profile=[pscustomobject]@{Kind='custom';Name=[string]$Request.Name;Directory=$dir;ProgramPaths=$programs;ExtraDirectories=@();DailyPort=$Request.DailyPort;TradePort=$Request.TradePort;HttpPort=$null;PacPort=$null;BootstrapDomains=@()}
        }else{throw '请选择已检测到的客户端，或选择其他 SOCKS5 客户端。'}
        if($Request.Name){$profile.Name=[string]$Request.Name}
        # Auto detection remains authoritative for known clients; no guessed core or port.
        $existing=@($records|Where-Object {$_.directory -eq $profile.Directory})
        $slot=if($existing.Count){[int]$existing[0].slot}else{Get-TCProviderFreeSlot ([pscustomobject]@{Providers=$records})}
        $id=if($existing.Count){[string]$existing[0].id}else{$null}
        $record=New-TCProviderRecord -Profile $profile -Slot $slot -Id $id
        $next=@($records|Where-Object {$_.id -ne $record.id})+@($record)
        $null=ConvertTo-TCPolicyProviders -Providers $next -TradePrograms @($ctx.Manifest.TradeProgramPaths)
        $null=Write-TCProviderStore -StoreRoot $ctx.StoreRoot -Providers $next
        [pscustomobject]@{Registered=$true;Id=$record.id;Name=$record.name;NetworkChanged=$false;Friendly='服务商资料已保存，当前交易线路未改变。新增端口需在维护窗口更新线路配置后使用。'}
    }finally{$lock.Dispose()}
}
function Get-TCStoredProvider {
    param([string]$Root,[string]$Id)
    $ctx=Get-TCProviderContext $Root
    $match=@((Read-TCProviderStore $ctx.StoreRoot).Providers|Where-Object {$_.id -eq $Id})
    if($match.Count -ne 1){throw '未找到该服务商，请刷新列表。'}
    $match[0]
}
function Test-TCProviderAppliedRecord {
    param($Applied,$Record)
    $tradePort=if($Record.tradePort){[int]$Record.tradePort}else{[int]$Record.dailyPort}
    if($Applied.Id -ne $Record.id -or $Applied.Port -ne $Record.dailyPort -or $Applied.TradePort -ne $tradePort -or $Applied.Directory -ne $Record.directory){return $false}
    $wanted=@(@($Record.directory)+@($Record.extraDirectories)|Where-Object {$_}|ForEach-Object {$_.ToLowerInvariant()}|Sort-Object -Unique) -join '|'
    $actual=@($Applied.Directories|Where-Object {$_}|ForEach-Object {$_.ToLowerInvariant()}|Sort-Object -Unique) -join '|'
    if($actual -cne $wanted){return $false}
    $wanted=@($Record.programPaths|Where-Object {$_}|ForEach-Object {$_.ToLowerInvariant()}|Sort-Object -Unique) -join '|'
    $actual=@($Applied.Programs|Where-Object {$_}|ForEach-Object {$_.ToLowerInvariant()}|Sort-Object -Unique) -join '|'
    if($actual -cne $wanted){return $false}
    $expectedDomains=@($Record.bootstrapDomains|Where-Object {$_}|Sort-Object -Unique) -join '|'
    $actualDomains=@($Applied.BootstrapDomains|Where-Object {$_}|Sort-Object -Unique) -join '|'
    $actualDomains -eq $expectedDomains
}
function Get-TCProviderRuntimeOverview {
    Import-Module (Join-Path $PSScriptRoot 'RuntimeBridge.psm1') -DisableNameChecking
    Get-TCOverview
}
function Assert-TCProviderMaintenanceSafe {
    param($Profile,[string]$Root)
    # Config writes/reload must never be attempted while this provider owns any
    # selected lane. No selector or engine is stopped as a side effect.
    $o=Get-TCProviderRuntimeOverview
    $tag=Get-TCProviderTag $Profile.slot
    if($o.Running -and ($o.Daily -eq $tag -or $o.Exit -in @($tag,($tag+'-trade')))){throw '该服务商正在承载流量。请先将交易切回自建线路、日常上网改为直连，再准备或恢复客户端；当前连接未改变。'}
    if($o.StateKey -eq 'Fault'){throw '无法核实当前线路状态，暂不修改代理客户端配置。'}
}
function Test-TCRegisteredProvider {
    param([string]$Root,[string]$Id,[switch]$ForTrade)
    $ctx=Get-TCProviderContext $Root;$record=Get-TCStoredProvider $Root $Id
    $target=[pscustomobject]@{Id=$record.id;Name=$record.name;Kind=$record.kind;Tag=(Get-TCProviderTag $record.slot);Port=$record.dailyPort;Directory=$record.directory;Directories=@($record.directory)+@($record.extraDirectories);Programs=@($record.programPaths)}
    $health=Get-TCProviderHealth -Provider $target
    $state=Get-TCProviderClientState $record|Select-Object SystemProxy,TunMode,ProxyGuard,SnifferReady,MergePath,Notes,Effective,TradingEgressVerified
    # A newly discovered provider is not bypassed by the current engine yet.
    # Probing it in global mode could travel through Hong Kong and falsely
    # certify it as an independent backup. Require applied bypass first.
    $live=@(Get-TCManifestProviders $ctx.Manifest|Where-Object {Test-TCProviderAppliedRecord $_ $record})
    $probe=$null;$tradeProbe=$null;$tradeHealth=$null;$tradePolicy=$null
    if($live.Count -eq 1 -and $health.Healthy){$probe=Test-TCProviderForwarding -Port $record.dailyPort}
    if($ForTrade -and $live.Count -eq 1){
        $tradeTarget=Resolve-TCProviderTarget $ctx.Manifest $Id -ForTrade
        $tradeHealth=Get-TCProviderHealth -Provider $tradeTarget
        if($tradeHealth.Healthy){
            $tradePolicy=Test-TCProviderTradingPolicy -Provider $tradeTarget
            if($tradePolicy.Allowed){$tradeProbe=Test-TCProviderForwarding -Port $tradeTarget.Port}
        }
    }
    $tradeReady=[bool]($tradeHealth -and $tradeHealth.Healthy -and $tradePolicy -and $tradePolicy.Allowed -and $tradeProbe -and $tradeProbe.Ok)
    [pscustomobject]@{Id=$Id;Name=$record.name;Health=$health;ClientState=$state;Applied=($live.Count -eq 1);DailyForwarding=$(if($probe){[bool]$probe.Ok}else{$null});ObservedIP=$(if($probe){$probe.IP}else{$null});ForTrade=[bool]$ForTrade;TradeHealth=$tradeHealth;TradePolicy=$tradePolicy;TradeForwarding=$(if($tradeProbe){[bool]$tradeProbe.Ok}else{$null});TradeReadyBeforeSwitch=$tradeReady;TradeIP=$(if($tradeProbe){$tradeProbe.IP}else{$null});TradingValidated=$false;Friendly=$(if(-not $live.Count){'档案已登记；需更新线路配置后才能验证独立出口。当前交易连接未改变。'}elseif($ForTrade -and -not $tradeReady){if($tradePolicy -and $tradePolicy.ReasonText){$tradePolicy.ReasonText}else{'交易备用端口未通过检查，保留当前交易出口。'}}elseif($probe -and $probe.Ok){'日常端口转发通过。交易备用的出口、历史数据和订单仍需分别验收。'}else{'服务商暂未通过转发检查，当前交易线路未改变。'})}
}
function Invoke-TCProviderRequest {
    param([Parameter(Mandatory=$true)]$Request,[Parameter(Mandatory=$true)][string]$Root)
    switch([string]$Request.Action){
        'Providers' {Get-TCProviderOverview $Root}
        'ProviderRegister' {Register-TCProviderProfile $Request $Root}
        'ProviderCheck' {Test-TCRegisteredProvider -Root $Root -Id $Request.Id -ForTrade:([bool]$Request.ForTrade)}
        'ProviderPrepare' {
            $profile=Get-TCStoredProvider $Root $Request.Id
            Assert-TCProviderMaintenanceSafe $profile $Root
            $ctx=Get-TCProviderContext $Root
            $prepared=Invoke-TCClashPreparation -Profile $profile -BackupRoot $ctx.BackupRoot
            $null=Register-TCProviderProfile -Request ([pscustomobject]@{Kind='clashverge';Name=$profile.name}) -Root $Root
            $prepared
        }
        'ProviderRestore' {
            $profile=Get-TCStoredProvider $Root $Request.Id
            Assert-TCProviderMaintenanceSafe $profile $Root
            $ctx=Get-TCProviderContext $Root
            Restore-TCClashPreparation -Profile $profile -BackupRoot $ctx.BackupRoot
        }
        default {throw '不支持的服务商操作。'}
    }
}
Export-ModuleMember -Function Invoke-TCProviderRequest,Get-TCProviderOverview,Register-TCProviderProfile,Test-TCRegisteredProvider
