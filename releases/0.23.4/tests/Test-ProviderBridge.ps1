#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'ProviderBridge.psm1') -Force -PassThru -DisableNameChecking
$root=Join-Path $env:LOCALAPPDATA ('TC-ProviderBridge-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($root)
try{
    & $module {
        param($testRoot)
        $script:Checks=0;$script:ForwardCalls=0;$script:PrepareCalls=0
        function script:Assert-Bridge {param($Value,$Label)if(-not $Value){throw $Label};$script:Checks++}
        function script:Get-TCProviderHealth {param($Provider)[pscustomobject]@{Healthy=$true;Reason=$null}}
        function script:Get-TCProviderClientState {param($Profile)[pscustomobject]@{SnifferReady=$true;Details=@{password='fixture-secret-not-for-ui'}}}
        function script:Find-TCProviderCandidates {[pscustomobject]@{Kind='custom';Name='Candidate';DailyPort=10001;RuntimeFacts=@{uuid='fixture-secret-not-for-ui'}}}
        function script:Test-TCProviderForwarding {param($Port)$script:ForwardCalls++;[pscustomobject]@{Ok=$true;IP='198.51.100.10'}}
        function script:Test-TCProviderTradingPolicy {param($Provider)[pscustomobject]@{Allowed=$true;ReasonText='fixture remote'}}
        function script:Get-TCProviderRuntimeOverview {[pscustomobject]@{Running=$true;StateKey='Connected';Daily=$script:LiveDaily;Exit=$script:LiveTrade}}
        function script:Invoke-TCClashPreparation {param($Profile,$BackupRoot)$script:PrepareCalls++;throw 'Unmocked file changes prohibited'}
        $dir=Join-Path $testRoot 'Clients\Alpha';$null=[IO.Directory]::CreateDirectory($dir)
        $exe=Join-Path $dir 'client.exe';[IO.File]::WriteAllText($exe,'inert fixture')
        $request=[pscustomobject]@{Kind='custom';Name='Alpha';Directory=$dir;DailyPort=18091;TradePort=18092}
        $registered=Register-TCProviderProfile -Request $request -Root $testRoot
        Assert-Bridge ($registered.Registered -and -not $registered.NetworkChanged) 'registration mutated network'
        $stored=Read-TCProviderStore (Join-Path $testRoot 'Product')
        Assert-Bridge ($stored.Providers.Count -eq 1 -and $stored.Providers[0].id -eq $registered.Id) 'registry readback failed'
        $again=Register-TCProviderProfile -Request $request -Root $testRoot
        Assert-Bridge ($again.Id -eq $registered.Id) 'same directory created a duplicate identity'
        $overview=Get-TCProviderOverview $testRoot
        Assert-Bridge (($overview|ConvertTo-Json -Depth 12) -notmatch 'fixture-secret-not-for-ui|RuntimeFacts|Details') 'internal provider credentials escaped into UI payload'
        $check=Test-TCRegisteredProvider -Root $testRoot -Id $registered.Id
        Assert-Bridge (-not $check.Applied -and $null -eq $check.DailyForwarding -and $script:ForwardCalls -eq 0) 'unapplied provider was probed through live route'
        $id=$registered.Id
        $profile=$stored.Providers[0]
        $manifest=@{PolicyVersion=4;Providers=@(@{Id=$id;Slot=1;Tag='provider';TradeTag='provider-trade';Port=18091;TradePort=18092;Directory=$dir;Programs=@($exe);ExtraDirectories=@();BootstrapDomains=@();Name='Alpha';Kind='custom'})}
        $manifestPath=Join-Path $testRoot 'manifest.json'
        [IO.File]::WriteAllText($manifestPath,($manifest|ConvertTo-Json -Depth 8))
        [IO.File]::WriteAllText((Join-Path $testRoot 'deployment.json'),(@{ManifestPath=$manifestPath}|ConvertTo-Json))
        $check=Test-TCRegisteredProvider -Root $testRoot -Id $id -ForTrade
        Assert-Bridge ($check.Applied -and $check.DailyForwarding -and $check.TradeForwarding -and $check.TradeReadyBeforeSwitch) 'matching applied provider failed prerequisite check'
        Assert-Bridge (-not $check.TradingValidated -and $script:ForwardCalls -eq 2) 'connectivity was misreported as full trading acceptance'
        $profile|Add-Member -NotePropertyName bootstrapDomains -NotePropertyValue @('new-upstream.example') -Force
        $null=Write-TCProviderStore -StoreRoot (Join-Path $testRoot 'Product') -Providers @($profile)
        $calls=$script:ForwardCalls;$check=Test-TCRegisteredProvider -Root $testRoot -Id $id
        Assert-Bridge (-not $check.Applied -and $script:ForwardCalls -eq $calls) 'changed bootstrap domains bypassed pending-policy gate'
        $script:LiveDaily='direct';$script:LiveTrade='provider-trade';$caught=$false
        try{Assert-TCProviderMaintenanceSafe $profile $testRoot}catch{$caught=$true}
        Assert-Bridge $caught 'prepare permitted while provider carried trading'
        $script:LiveTrade='hk';$script:LiveDaily='provider';$caught=$false
        try{Assert-TCProviderMaintenanceSafe $profile $testRoot}catch{$caught=$true}
        Assert-Bridge $caught 'prepare permitted while provider carried daily traffic'
        $script:LiveDaily='direct';Assert-TCProviderMaintenanceSafe $profile $testRoot
        Assert-Bridge ($script:PrepareCalls -eq 0) 'maintenance gate performed mutation'
        [pscustomobject]@{Passed=$true;Checks=$script:Checks;Scope='Isolated registration, independent-route prerequisite, bootstrap drift, maintenance gate';RealNetworkChanges=0}
    } $root
}finally{
    Remove-Module ProviderBridge -ErrorAction SilentlyContinue
    $full=[IO.Path]::GetFullPath($root);$base=[IO.Path]::GetFullPath($env:LOCALAPPDATA).TrimEnd('\')+'\'
    if(-not $full.StartsWith($base,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notlike 'TC-ProviderBridge-*'){throw 'Cleanup rejected'}
    Remove-Item -LiteralPath $full -Recurse -Force
}
