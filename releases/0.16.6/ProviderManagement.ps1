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
    $lock=[IO.File]::Open((Join-Path $ctx.StoreRoot '.store.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try{
        $store=Read-TCProviderStore $ctx.StoreRoot;$prior=@($store.Providers|Where-Object {$_.id -eq $current.id})
        if($prior.Count -ne 1){throw '服务商档案在编辑期间发生变化，请刷新后重试。'}
        $next=@($store.Providers|Where-Object {$_.id -ne $record.id})+@($record)
        Import-Module (Join-Path $PSScriptRoot 'NodeStore.psm1') -DisableNameChecking
        $null=ConvertTo-TCPolicyProviders -Providers $next -TradePrograms @($ctx.Manifest.TradeProgramPaths) -AllowMissingPrograms
        $null=Write-TCProviderStore -StoreRoot $ctx.StoreRoot -Providers $next
        [pscustomobject]@{Updated=$true;Id=$record.id;Name=$record.name;NetworkChanged=$false;Friendly='服务商档案已更新。新线路使用新资料；已有线路需在维护窗口更新配置，当前出口保持。'}
    }finally{$lock.Dispose()}
}
function Remove-TCProviderProfile {
    param([string]$Root,[string]$Id)
    $record=Get-TCStoredProvider $Root $Id;Assert-TCProviderMaintenanceSafe $record $Root
    $ctx=Get-TCProviderContext $Root;$session=$null;$storeLock=$null;$prefLock=$null
    try{
        $session=[IO.File]::Open((Join-Path $Root '.session.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        Assert-TCProviderMaintenanceSafe $record $Root
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
