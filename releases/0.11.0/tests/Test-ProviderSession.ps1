#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'RuntimeBridge.psm1') -Force -DisableNameChecking -PassThru
$root=Join-Path ([IO.Path]::GetTempPath()) ('TC-ProviderSession-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($root)
try{
    & $module {
        param($testRoot)
        $script:Root=$testRoot;$script:Checks=0
        $script:A='11111111-1111-1111-1111-111111111111';$script:B='22222222-2222-2222-2222-222222222222'
        $script:ManifestPath=Join-Path $testRoot 'manifest.json'
        $m=@{PolicyVersion=4;Providers=@(@{Id=$script:A;Slot=1;Tag='provider';TradeTag='provider-trade';Name='A';Kind='custom';Port=12081;TradePort=12082;Directory='C:\Clients\A';Programs=@()},@{Id=$script:B;Slot=2;Tag='provider2';TradeTag='provider2-trade';Name='B';Kind='custom';Port=12083;TradePort=12084;Directory='C:\Clients\B';Programs=@()})}
        Write-TCSessionJson $script:ManifestPath $m
        $script:Commands=New-Object 'System.Collections.Generic.List[string]'
        $script:Trade='provider-trade';$script:Day='provider';$script:Mode='rule';$script:FailTrade=$false
        function script:Assert-ProviderSession {param($Value,$Label)if(-not $Value){throw $Label};$script:Checks++}
        function script:Get-TCOverview {[pscustomobject]@{Running=$true;CanConnect=$false;StateKey='Connected';Mode=$script:Mode;Exit=$script:Trade;Daily=$script:Day;DailySupported=$true;AgentsSupported=$false;ManifestPath=$script:ManifestPath}}
        function script:Get-Process {param($Name,$ErrorAction)if($Name -eq 'NinjaTrader'){[pscustomobject]@{Name='NinjaTrader'}}}
        function script:Invoke-TCCommand {
            param($Action)
            $script:Commands.Add($Action)
            if($Action -in @('Connect','Disconnect','Emergency')){throw 'Unexpected engine mutation'}
            if($Action -eq 'Provider'){
                if($script:FailTrade){throw 'Provider unavailable'}
                $script:Trade=if((Get-TCPreferences).TradeProviderId -eq $script:B){'provider2-trade'}else{'provider-trade'}
            }
            if($Action -eq 'HongKong'){$script:Trade='hk'}
            if($Action -eq 'Global'){$script:Mode='global'}
            if($Action -eq 'Trading'){$script:Mode='rule'}
            if($Action -eq 'DailyProvider'){$script:Day=if((Get-TCPreferences).ProviderId -eq $script:B){'provider2'}else{'provider'};[pscustomobject]@{Applied=$true;Effective=$script:Day;Reason=$null}}
            if($Action -eq 'DailyDirect'){$script:Day='direct';[pscustomobject]@{Applied=$true;Effective='direct';Reason=$null}}
        }
        $null=Save-TCPreferences -Mode Trading -Exit Provider -Daily Provider -ProviderId $script:A -TradeProviderId $script:A
        $o=Invoke-TCSession Apply -ProviderId $script:B
        Assert-ProviderSession ($script:Trade -eq 'provider-trade' -and $script:Day -eq 'provider2') 'Changing daily provider changed trading exit'
        Assert-ProviderSession (($script:Commands.ToArray() -join ',') -eq 'DailyProvider') 'Daily selection invoked a trade command'
        Assert-ProviderSession ((Get-TCPreferences).TradeProviderId -eq $script:A) 'Daily selection overwrote backup identity'
        $script:Commands.Clear();$script:Trade='hk'
        $o=Invoke-TCSession Apply -Daily Direct
        Assert-ProviderSession ($script:Trade -eq 'hk' -and $script:Day -eq 'direct' -and $script:Commands.Count -eq 1) 'Stale preference switched live Hong Kong line'
        $before=[IO.File]::ReadAllText((Join-Path $testRoot 'ui-preferences.json'));$script:Commands.Clear();$caught=$false
        try{$null=Invoke-TCSession Apply -ProviderId '33333333-3333-3333-3333-333333333333'}catch{$caught=$true}
        Assert-ProviderSession ($caught -and $script:Commands.Count -eq 0) 'Unknown provider silently selected a different client'
        Assert-ProviderSession ([IO.File]::ReadAllText((Join-Path $testRoot 'ui-preferences.json')) -eq $before) 'Rejected provider mutated preferences'
        $o=Invoke-TCSession Apply -Exit Provider -TradeProviderId $script:B
        Assert-ProviderSession ($script:Trade -eq 'provider2-trade') 'Explicit trading backup did not use dedicated port tag'
        Assert-ProviderSession (($script:Commands.ToArray() -join ',') -eq 'Provider') 'Explicit backup restarted engine'
        $script:Commands.Clear();$o=Invoke-TCSession Apply -Exit HongKong
        Assert-ProviderSession ($script:Trade -eq 'hk') 'Manual return to Hong Kong failed'
        $script:Commands.Clear();$script:FailTrade=$true;$caught=$false
        try{$null=Invoke-TCSession Apply -Exit Provider -TradeProviderId $script:A}catch{$caught=$true}
        Assert-ProviderSession ($caught -and $script:Trade -eq 'hk') 'Failed backup replaced active Hong Kong exit'
        $script:Commands.Clear();$script:FailTrade=$false
        $o=Invoke-TCSession Apply -ProviderId $script:B -Daily Provider
        Assert-ProviderSession ($script:Trade -eq 'hk' -and $script:Day -eq 'provider2') 'Daily apply reused failed trade intent'
        Assert-ProviderSession (-not @($script:Commands|Where-Object {$_ -in @('Provider','Connect','Disconnect','Emergency')}).Count) 'Daily apply affected trade sessions'
        [pscustomobject]@{Passed=$true;Checks=$script:Checks;Scope='Isolated two-provider selection, dedicated backup, stale intent and rejection';RealNetworkChanges=0}
    } $root
}finally{
    Remove-Module RuntimeBridge -ErrorAction SilentlyContinue
    $full=[IO.Path]::GetFullPath($root);$base=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not $full.StartsWith($base,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notlike 'TC-ProviderSession-*'){throw 'Cleanup outside fixture rejected'}
    Remove-Item -LiteralPath $full -Recurse -Force
}
