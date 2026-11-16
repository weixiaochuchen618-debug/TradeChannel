# Provider metadata management never edits client settings or changes selectors.
function Get-TCProviderAvailability {
    param($Record)
    $missing=@($Record.programPaths|Where-Object {-not [IO.File]::Exists([string]$_)})
    $directory=[IO.Directory]::Exists([string]$Record.directory)
    $available=($directory -and @($Record.programPaths).Count -gt 0 -and $missing.Count -eq 0)
    [pscustomobject]@{Available=$available;DirectoryExists=$directory;MissingPrograms=$missing;Reason=$(if($available){''}else{'安装目录或程序已不存在，请更新路径或删除此档案。'})}
}
function Select-TCImportProviders {
    param([string]$Root,[string[]]$Programs=@(),[switch]$SkipUnavailable)
    $ctx=Get-TCProviderContext $Root;$records=@((Read-TCProviderStore $ctx.StoreRoot).Providers)
    $valid=New-Object 'Collections.Generic.List[object]';$warnings=New-Object 'Collections.Generic.List[string]'
    foreach($record in $records){
        $status=Get-TCProviderAvailability $record
        if(-not $status.Available){
            if(-not $SkipUnavailable){throw ('服务商「'+$record.name+'」的安装目录或程序不存在。请在线路页更新/删除档案，或不将服务商纳入本次导入。')}
            $warnings.Add('新线路未纳入失效服务商「'+$record.name+'」，请在线路页更新路径或删除档案。');continue
        }
        $valid.Add($record)
    }
    if($valid.Count){Import-Module (Join-Path $PSScriptRoot 'NodeStore.psm1') -DisableNameChecking;$null=ConvertTo-TCPolicyProviders -Providers $valid.ToArray() -TradePrograms $Programs}
    [pscustomobject]@{Providers=$valid.ToArray();Warnings=$warnings.ToArray();UnchangedOriginalProfiles=$true}
}
function Update-TCProviderProfile {
    param($Request,[string]$Root)
    $current=Get-TCStoredProvider $Root ([string]$Request.Id)
    Assert-TCProviderMaintenanceSafe $current $Root
    $values=@{};foreach($key in @('kind','name','directory','extraDirectories','programPaths','dailyPort','tradePort','httpPort','pacPort','bootstrapDomains','settingsDirectory','addedAt')){$values[$key]=Get-TCProviderValue $current $key}
    if($Request.Name){$values.name=[string]$Request.Name}
    if($Request.Directory){$values.directory=[string]$Request.Directory}
    if($Request.PSObject.Properties['DailyPort']){$values.dailyPort=$Request.DailyPort}
    if($Request.PSObject.Properties['TradePort']){$values.tradePort=$Request.TradePort}
    if($Request.RefreshPaths){
        $found=@(Find-TCProviderCandidates|Where-Object {$_.Kind -eq $current.kind})
        if($found.Count -ne 1){throw '未找到唯一的客户端安装，请在编辑页填写正确目录。'}
        foreach($key in @('Directory','ProgramPaths','ExtraDirectories','DailyPort','TradePort','BootstrapDomains','SettingsDirectory')){$values[$key]=Get-TCProviderValue $found[0] $key}
        $values.name=$current.name
    }else{
        $paths=@(Get-ChildItem -LiteralPath $values.directory -Filter '*.exe' -File -ErrorAction Stop|Select-Object -ExpandProperty FullName)
        foreach($old in @($current.programPaths)){
            if(Test-TCProviderPathWithin $old $current.directory){$candidate=Join-Path $values.directory $old.Substring($current.directory.Length).TrimStart('\');if([IO.File]::Exists($candidate)){$paths+=$candidate}}
        }
        $values.programPaths=@($paths|Select-Object -Unique)
    }
    $record=New-TCProviderRecord -Profile ([pscustomobject]$values) -Slot $current.slot -Id $current.id
    $ctx=Get-TCProviderContext $Root
    $session=Open-TCProviderSessionLock $Root;$lock=$null
    try{
        Assert-TCProviderMaintenanceSafe $current $Root
        $lock=[IO.File]::Open((Join-Path $ctx.StoreRoot '.store.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $store=Read-TCProviderStore $ctx.StoreRoot;$prior=@($store.Providers|Where-Object {$_.id -eq $current.id})
        if($prior.Count -ne 1){throw '服务商档案在编辑期间发生变化，请刷新后重试。'}
        if((ConvertTo-Json -InputObject $prior[0] -Depth 12 -Compress) -cne (ConvertTo-Json -InputObject $current -Depth 12 -Compress)){throw '服务商档案在编辑期间发生变化，请刷新后重试。'}
        $next=@($store.Providers|Where-Object {$_.id -ne $record.id})+@($record)
        Import-Module (Join-Path $PSScriptRoot 'NodeStore.psm1') -DisableNameChecking
        $null=ConvertTo-TCPolicyProviders -Providers $next -TradePrograms @($ctx.Manifest.TradeProgramPaths) -AllowMissingPrograms
        $null=Write-TCProviderStore -StoreRoot $ctx.StoreRoot -Providers $next
        [pscustomobject]@{Updated=$true;Id=$record.id;Name=$record.name;NetworkChanged=$false;Friendly='服务商档案已更新。新线路使用新资料；已有线路需在维护窗口更新配置，当前出口保持。'}
    }finally{if($lock){$lock.Dispose()};$session.Dispose()}
}
function Remove-TCProviderProfile {
    param([string]$Root,[string]$Id)
    $record=Get-TCStoredProvider $Root $Id;Assert-TCProviderMaintenanceSafe $record $Root
    $ctx=Get-TCProviderContext $Root;$session=$null;$storeLock=$null;$prefLock=$null
    try{
        $session=[IO.File]::Open((Join-Path $Root '.session.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        Assert-TCProviderMaintenanceSafe $record $Root
        # Withdraw the live slot before freeing its registry identity. Reusing a
        # removed slot can never inherit the previous provider's live mapping.
        if(Get-TCProviderValue $ctx.Manifest 'ProviderRelay'){
            $live=Get-TCProviderRelayLiveState $ctx.Manifest
            if($live -and @($live.Providers|Where-Object {$_.Id -eq $Id}).Count){
                $remaining=@(ConvertFrom-TCRelayManifestProviders @($live.Providers|Where-Object {$_.Id -ne $Id}))
                $withdraw=Submit-TCProviderRelayRequest -Root $Root -Manifest $ctx.Manifest -Records $remaining -RequireIds @()
                if(-not $withdraw.Succeeded){throw '代理槽撤回未完成，保留原档案供重试。'}
            }
        }
        $storeLock=[IO.File]::Open((Join-Path $ctx.StoreRoot '.store.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $prefLock=[IO.File]::Open((Join-Path $Root '.preferences.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $store=Read-TCProviderStore $ctx.StoreRoot;$old=@($store.Providers);$next=@($old|Where-Object {$_.id -ne $Id})
        if($next.Count -eq $old.Count){throw '服务商档案已变更，请刷新。'}
        $prefPath=Join-Path $Root 'ui-preferences.json';$prefBytes=$null;$prefs=$null
        if([IO.File]::Exists($prefPath)){$prefBytes=[IO.File]::ReadAllBytes($prefPath);$prefs=[IO.File]::ReadAllText($prefPath)|ConvertFrom-Json}
        $null=Write-TCProviderStore -StoreRoot $ctx.StoreRoot -Providers $next
        try{
            if($prefs){
                if([string]$prefs.ProviderId -eq $Id){$prefs.ProviderId='';$prefs.Daily='Direct'}
                if([string]$prefs.TradeProviderId -eq $Id){$prefs.TradeProviderId='';$prefs.Exit='HongKong'}
                $bytes=[Text.Encoding]::UTF8.GetBytes(($prefs|ConvertTo-Json -Depth 14));Write-TCProviderAtomicBytes $prefPath $bytes
            }
        }catch{$null=Write-TCProviderStore -StoreRoot $ctx.StoreRoot -Providers $old;if($prefBytes){Write-TCProviderAtomicBytes $prefPath $prefBytes};throw}
        [pscustomobject]@{Removed=$true;Id=$Id;Name=$record.name;NetworkChanged=$false;ClientFilesDeleted=$false;Friendly=('服务商「'+$record.name+'」档案已删除，客户端及其订阅文件保留。当前线路配置中的旧记录在维护更新后移除。')}
    }finally{if($prefLock){$prefLock.Dispose()};if($storeLock){$storeLock.Dispose()};if($session){$session.Dispose()}}
}

function Open-TCProviderSessionLock {
    param([string]$Root)
    $path=Join-Path $Root '.session.lock';Assert-TCRelayNoReparse $path
    $deadline=[DateTime]::UtcNow.AddSeconds(5)
    do{try{return [IO.File]::Open($path,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}catch [IO.IOException]{if([DateTime]::UtcNow -ge $deadline){throw '[TC:ProviderOperationBusy] 另一连接操作正在进行，请稍后重试。'};Start-Sleep -Milliseconds 50}}while($true)
}
function Get-TCProviderLocalRuntimeOverview {
    param([string]$Root)
    $ctx=Get-TCProviderContext $Root;$runtime=Read-TCRelayJson (Join-Path $Root 'runtime.json')
    if(-not $runtime -or $runtime.State -in @('Disconnected','StoppedWithError')){
        if($ctx.Manifest -and (Get-TCProviderValue $ctx.Manifest 'ControlPort')){
            try{if(@(Get-TCListenerOwnerIds ([int]$ctx.Manifest.ControlPort)).Count){return [pscustomobject]@{Running=$false;StateKey='Fault';Daily=$null;Exit=$null}}}catch{return [pscustomobject]@{Running=$false;StateKey='Fault';Daily=$null;Exit=$null}}
        }
        return [pscustomobject]@{Running=$false;StateKey='Disconnected';Daily='direct';Exit='hk'}
    }
    if($runtime.State -ne 'Running'){return [pscustomobject]@{Running=$false;StateKey='Fault';Daily=$null;Exit=$null}}
    try{
        foreach($role in @('Supervisor','Engine')){
            $process=Get-Process -Id ([int]$runtime.($role+'Pid')) -ErrorAction Stop
            if($process.HasExited -or $process.StartTime.ToUniversalTime().Ticks -ne ([DateTimeOffset]$runtime.($role+'StartedAt')).UtcDateTime.Ticks){throw 'Runtime identity mismatch'}
        }
        $ports=@(Get-TCListenerOwnerIds ([int]$ctx.Manifest.ControlPort));if($ports.Count -ne 1 -or $ports[0] -ne $runtime.EnginePid){throw 'Controller owner mismatch'}
        $configuration=Read-TCRelayJson $ctx.Manifest.CandidatePath
        if((Get-FileHash -LiteralPath $ctx.Manifest.CandidatePath -Algorithm SHA256).Hash -cne $ctx.Manifest.CandidateSHA256){throw 'Configuration changed'}
        $api=$configuration.experimental.clash_api
        if($api.external_controller -cne ('127.0.0.1:'+([int]$ctx.Manifest.ControlPort)) -or -not $api.secret){throw 'Controller unavailable'}
        Add-Type -AssemblyName System.Net.Http
        $handler=New-Object Net.Http.HttpClientHandler;$handler.UseProxy=$false;$handler.AllowAutoRedirect=$false
        $client=New-Object Net.Http.HttpClient($handler);$client.Timeout=[TimeSpan]::FromSeconds(3);$client.MaxResponseContentBufferSize=1048576
        try{
            $client.DefaultRequestHeaders.Authorization=New-Object Net.Http.Headers.AuthenticationHeaderValue('Bearer',[string]$api.secret)
            $selected=@{}
            foreach($lane in @('daily','trade')){
                $response=$client.GetAsync(('http://'+$api.external_controller+'/proxies/'+$lane+'-exit')).GetAwaiter().GetResult()
                try{if(-not $response.IsSuccessStatusCode){throw 'Controller refused'};$value=ConvertFrom-Json -InputObject ($response.Content.ReadAsStringAsync().GetAwaiter().GetResult());$selected[$lane]=[string]$value.now}finally{$response.Dispose()}
            }
            if(-not $selected.daily -or -not $selected.trade){throw 'Selection unavailable'}
            [pscustomobject]@{Running=$true;StateKey='Connected';Daily=$selected.daily;Exit=$selected.trade}
        }finally{$client.Dispose();$handler.Dispose()}
    }catch{[pscustomobject]@{Running=$false;StateKey='Fault';Daily=$null;Exit=$null}}
}
function New-TCProviderConnectResult {
    param([string]$Id,[string]$Name)
    [pscustomobject][ordered]@{Id=$Id;Name=$Name;Registered=$false;Applied=$false;HotApplied=$false;NeedsUpgrade=$false;NeedsClientAction=$false;Friendly='代理接入尚未完成，当前交易出口保持。';NextStep=$null;Stage='Discover';Code='Pending';TradingExitChanged=$false;TradeReadyBeforeSwitch=$false;DailyForwarding=$false;BackupPath=$null;NeedsConnection=$false;ResumeAction='ProviderConnect';MigrationNoticeFirstSeen=$false}
}
function Get-TCProviderUpgradeResult {
    param([string]$Root,$Result)
    $directory=Initialize-TCRelayDirectory $Root;$notice=Join-Path $directory 'relay-upgrade-notice.json'
    $Result.NeedsUpgrade=$true;$Result.Stage='Migration';$Result.Code='ProviderRelayUpgradeRequired'
    $Result.Friendly='代理档案已保存；当前线路需先进行一次受控更新，尚未热应用。'
    $Result.NextStep='在可中断交易的维护窗口更新线路配置；更新前的配置会保留供回退，完成后重新点击接入。'
    $Result.MigrationNoticeFirstSeen=(-not [IO.File]::Exists($notice))
    if($Result.MigrationNoticeFirstSeen){Write-TCRelayJson $notice @{Version=1;Key='ProviderRelayV1';FirstSeenAt=[DateTimeOffset]::UtcNow.ToString('o')}}
    $Result
}
function Submit-TCProviderRelayRequest {
    param([string]$Root,$Manifest,[object[]]$Records,[string[]]$RequireIds=@(),[switch]$ForTrade)
    $null=Assert-TCProviderRelayContract $Manifest $Root -CheckConfiguration
    $directory=Initialize-TCRelayDirectory $Root;$lock=$null
    try{
        $lock=[IO.File]::Open((Join-Path $directory '.relay-request.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $live=Get-TCProviderRelayLiveState $Manifest;if(-not $live -or $live.Faulted){throw '[TC:ProviderRelayUnavailable] 当前线路没有健康的固定代理转发器。'}
        $request=[ordered]@{Version=1;RequestId=[guid]::NewGuid().ToString('N');SessionId=$live.SessionId;CandidateSHA256=$Manifest.CandidateSHA256;ExpectedRevision=$live.Revision;CreatedAt=[DateTimeOffset]::UtcNow.ToString('o');Records=@($Records);RequireIds=@($RequireIds);ForTrade=[bool]$ForTrade}
        Write-TCRelayJson (Join-Path $directory 'relay-request.json') $request
        $deadline=[DateTime]::UtcNow.AddSeconds(35)
        do{
            $state=Get-TCProviderRelayLiveState $Manifest
            if(-not $state -or $state.SessionId -cne $live.SessionId){throw '[TC:ProviderRelaySessionChanged] 接入期间线路会话已变化，请刷新状态。'}
            if($state.LastRequest -and $state.LastRequest.RequestId -ceq $request.RequestId){return $state.LastRequest}
            Start-Sleep -Milliseconds 100
        }while([DateTime]::UtcNow -lt $deadline)
        throw '[TC:ProviderRelayApplyTimeout] 接入确认超时，请刷新检查；不会自动重复提交。'
    }finally{if($lock){$lock.Dispose()}}
}
function Apply-TCRegisteredProvider {
    param([string]$Root,[string]$Id,[switch]$ForTrade)
    $record=Get-TCStoredProvider $Root $Id;$result=New-TCProviderConnectResult $Id $record.name;$result.Registered=$true;$result.Stage='Check'
    $ctx=Get-TCProviderContext $Root
    if(-not $ctx.Manifest){$result.NeedsConnection=$true;$result.Code='NoActiveLine';$result.Friendly='代理档案已保存，请先连接一条已更新的线路，再完成接入。';$result.NextStep='连接线路后，以此代理档案重新接入。';return $result}
    if(-not (Get-TCProviderValue $ctx.Manifest 'ProviderRelay')){return Get-TCProviderUpgradeResult $Root $result}
    $session=$null
    try{
        $session=Open-TCProviderSessionLock $Root
        $ctx=Get-TCProviderContext $Root;$live=Get-TCProviderRelayLiveState $ctx.Manifest
        if(-not $live){$result.NeedsConnection=$true;$result.Code='ProviderRelayUnavailable';$result.Friendly='代理档案已保存，固定代理入口尚未运行。';$result.NextStep='连接已更新的线路后重新接入。';return $result}
        $records=@(ConvertFrom-TCRelayManifestProviders @($live.Providers|Where-Object {$_.Id -ne $Id -and $_.Slot -ne $record.slot}))+@($record)
        $result.Stage='Apply';$applied=Submit-TCProviderRelayRequest -Root $Root -Manifest $ctx.Manifest -Records $records -RequireIds @($Id) -ForTrade:$ForTrade
        if(-not $applied.Succeeded){
            $result.Code=[string]$applied.Code
            $result.NeedsClientAction=$applied.Code -in @('ProviderRelayUpstreamUnhealthy','SocksHandshakeFailed','ProviderRelayForwardingFailed','ProviderRelayTradeUnverified')
            $result.Friendly=if($applied.Code -eq 'SelectedProviderImmutable'){'正在使用的代理身份或端口不能热改，原出口保持。'}else{'代理未通过接入检查，旧映射与当前出口保留。'}
            $result.NextStep=if($result.NeedsClientAction){'在代理客户端确认已连接、SOCKS 监听已加载且关闭 TUN／系统代理／代理守卫，再重新接入。'}else{'刷新运行状态；涉及正在使用的代理变更，请在维护窗口处理。'}
            return $result
        }
        $fresh=Get-TCProviderRelayLiveState $ctx.Manifest
        $matched=@($fresh.Providers|Where-Object {$_.Id -ceq $Id -and $_.RelayIdentity -ceq (Get-TCProviderRelayRecordIdentity $record)})
        $binding=@($fresh.Bindings|Where-Object {$_.ProviderId -ceq $Id -and $_.Lane -ceq 'daily' -and $_.Healthy})
        if($matched.Count -ne 1 -or $binding.Count -ne 1){throw '[TC:ProviderRelayMappingMismatch] 接入确认与实际映射不一致。'}
        $result.Applied=$true;$result.HotApplied=$true;$result.Stage='Complete';$result.Code='Applied';$result.DailyForwarding=$true;$result.TradeReadyBeforeSwitch=[bool]$applied.TradeReadyBeforeSwitch
        $result.Friendly='代理已接入固定入口，交易引擎未重启；当前交易出口保持。'
        $result.NextStep=if($ForTrade){'交易备用检查已通过；实际交易软件仍需验收，切换出口请另行明确选择。'}else{'需要使用时，另行选择日常或交易出口。'}
        $result
    }catch{
        $result.Code=Get-TCProviderRelayErrorCode $_;$result.Friendly='代理接入未完成，当前交易出口保持。';$result.NextStep='刷新代理与线路状态后重试；失败记录已保留。';$result
    }finally{if($session){$session.Dispose()}}
}
function Connect-TCProvider {
    param($Request,[string]$Root)
    $result=New-TCProviderConnectResult ([string](Get-TCProviderValue $Request 'Id')) ''
    try{
        if($result.Id){$record=Get-TCStoredProvider $Root $result.Id;$result.Name=$record.name;$result.Registered=$true}
        else{
            $hasDomains=if($Request -is [Collections.IDictionary]){$Request.Contains('BootstrapDomains')}else{[bool]$Request.PSObject.Properties['BootstrapDomains']}
            if((Get-TCProviderValue $Request 'Kind') -in @('custom','manual') -and -not $hasDomains){$result.NeedsClientAction=$true;$result.Code='BootstrapDomainsRequired';$result.NextStep='填写代理实际使用的上游域名；确认全部使用 IP 时可提交空域名列表。';return $result}
            $kind=[string](Get-TCProviderValue $Request 'CandidateKind' (Get-TCProviderValue $Request 'Kind'))
            if($kind -in @('batvpn','clashverge')){
                $found=@(Find-TCProviderCandidates|Where-Object {$_.Kind -eq $kind})
                if($found.Count -ne 1 -or -not $found[0].BootstrapComplete){$result.NeedsClientAction=$true;$result.Code='ClientNotDiscovered';$result.Friendly='尚未找到配置完整的代理客户端。';$result.NextStep='安装并打开所选客户端，导入并加载订阅后重新点击接入。';return $result}
            }
            $registered=Register-TCProviderProfile -Request $Request -Root $Root;$result.Id=$registered.Id;$result.Name=$registered.Name;$result.Registered=$true;$record=Get-TCStoredProvider $Root $result.Id
        }
        $result.Stage='Prepare';$ctx=Get-TCProviderContext $Root
        if($record.kind -in @('clashverge','clash-verge')){
            $state=Get-TCClashVergeState -InstallDirectory $record.directory -ConfigDirectory $record.settingsDirectory -SkipRuntime
            if(-not $state){$result.NeedsClientAction=$true;$result.Code='ClientMissing';$result.NextStep='安装并打开已登记的 Clash Verge，加载订阅后重新接入。';return $result}
            $plan=Get-TCProviderSetupPlan -Profile $record
            if(-not $plan.AlreadyApplied){
                $session=Open-TCProviderSessionLock $Root
                try{
                    Assert-TCProviderMaintenanceSafe $record $Root
                    $prepared=Invoke-TCClashPreparation -Profile $record -BackupRoot $ctx.BackupRoot
                    $result.BackupPath=$prepared.BackupPath
                }finally{$session.Dispose()}
                $null=Register-TCProviderProfile -Request ([pscustomobject]@{Kind='clashverge';Name=$record.name}) -Root $Root
                $record=Get-TCStoredProvider $Root $result.Id
                $state=Get-TCClashVergeState -InstallDirectory $record.directory -ConfigDirectory $record.settingsDirectory -SkipRuntime
            }
            if($state.RestartNeeded -or -not $state.SnifferReady -or $state.Tun -or $state.SystemProxy -or $state.ProxyGuard){
                $result.NeedsClientAction=$true;$result.Code='ClientReloadRequired';$result.Friendly='代理启动配置已准备并保留备份，等待客户端加载。';$result.NextStep='在 Clash Verge 关闭 TUN、系统代理与代理守卫，加载配置后重新点击接入。';return $result
            }
        }else{
            $state=Get-TCProviderClientState $record
            if($state.TunMode -or $state.SystemProxy -or $state.ProxyGuard){$result.NeedsClientAction=$true;$result.Code='ClientCaptureEnabled';$result.NextStep='在代理客户端关闭 TUN、系统代理与代理守卫，确认已连接后重新接入。';return $result}
        }
        $applied=Apply-TCRegisteredProvider -Root $Root -Id $result.Id -ForTrade:([bool](Get-TCProviderValue $Request 'ForTrade' $false))
        $applied.BackupPath=$result.BackupPath;$applied
    }catch{
        $result.Code=Get-TCProviderRelayErrorCode $_;$result.Friendly='代理接入未完成，当前交易出口保持。';$result.NextStep='检查已发现客户端、配置与端口；已有准备备份仍可恢复。'
        if($result.Code -eq 'ProviderClientMergeRequired'){$result.NeedsClientAction=$true;$result.NextStep='保留已有自定义嗅探或监听器，在客户端完成合并后重新接入。'}
        elseif($result.Code -eq 'ProviderInUse'){$result.Friendly='该代理正在承载流量，启动配置保持原样。';$result.NextStep='在维护窗口手动调整所用出口后，再准备或恢复这个代理客户端。'}
        $result
    }finally{if(Get-Variable TCClashFactsCache -Scope Script -ErrorAction SilentlyContinue){$script:TCClashFactsCache.Clear()}}
}
function New-TCProviderMigrationCandidate {
    param([string]$Root)
    $ctx=Get-TCProviderContext $Root
    if(-not $ctx.ManifestPath){throw '请先选择需要更新的线路。'}
    Import-Module (Join-Path $PSScriptRoot 'NodeStore.psm1') -DisableNameChecking
    $records=@((Read-TCProviderStore $ctx.StoreRoot).Providers)
    if(-not [IO.File]::Exists((Join-Path $ctx.StoreRoot 'providers.json'))){$records=@(ConvertFrom-TCManifestProviders $ctx.Manifest)}
    $directory=Initialize-TCRelayDirectory $Root;$receiptPath=Join-Path $directory 'relay-migration.json'
    Assert-TCRelayNoReparse $ctx.ManifestPath
    $sourceHash=(Get-FileHash -LiteralPath $ctx.ManifestPath -Algorithm SHA256).Hash
    $identities=@($records|Sort-Object slot|ForEach-Object {Get-TCProviderRelayRecordIdentity $_}) -join '|'
    $receipt=Read-TCRelayJson $receiptPath;$next=$null
    if($receipt -and $receipt.Version -eq 1 -and $receipt.SourceManifestPath -ceq $ctx.ManifestPath -and $receipt.SourceSHA256 -ceq $sourceHash -and $receipt.ProviderIdentities -ceq $identities){
        try{
            foreach($file in @($receipt.ManifestPath,$receipt.CandidatePath)){Assert-TCRelayNoReparse $file;if(-not [IO.File]::Exists($file)){throw 'Prepared candidate missing'}}
            if((Get-FileHash -LiteralPath $receipt.ManifestPath -Algorithm SHA256).Hash -cne $receipt.ManifestSHA256 -or (Get-FileHash -LiteralPath $receipt.CandidatePath -Algorithm SHA256).Hash -cne $receipt.CandidateSHA256){throw 'Prepared candidate changed'}
            $next=[pscustomobject]@{ManifestPath=$receipt.ManifestPath;CandidatePath=$receipt.CandidatePath;PreviousManifestPath=$ctx.ManifestPath}
        }catch{$next=$null}
    }
    if(-not $next){
    $next=Update-TCNodePolicy -Root $ctx.StoreRoot -ManifestPath $ctx.ManifestPath -ReplaceProviders -Providers $records
        Write-TCRelayJson $receiptPath @{Version=1;SourceManifestPath=$ctx.ManifestPath;SourceSHA256=$sourceHash;ProviderIdentities=$identities;ManifestPath=$next.ManifestPath;ManifestSHA256=(Get-FileHash -LiteralPath $next.ManifestPath -Algorithm SHA256).Hash;CandidatePath=$next.CandidatePath;CandidateSHA256=(Get-FileHash -LiteralPath $next.CandidatePath -Algorithm SHA256).Hash}
    }
    [pscustomobject]@{Prepared=$true;Applied=$false;HotApplied=$false;NeedsUpgrade=$true;NeedsControlledActivation=$true;ManifestPath=$next.ManifestPath;PreviousManifestPath=$next.PreviousManifestPath;TradingExitChanged=$false;Friendly='固定代理入口候选已生成，原线路配置保留；尚未启用。';NextStep='在维护窗口通过现有受控更新流程启用；需要回退时选择保留的原配置。'}
}
