#requires -Version 5.1
param([string]$ReportPath)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$source=Split-Path $PSScriptRoot -Parent
$work=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('TCProviderPolicyTests-'+[guid]::NewGuid().ToString('N'))
$checks=New-Object 'Collections.Generic.List[string]'
function Assert-Test {param($Value,[string]$Label);if(-not $Value){throw ('Assertion: '+$Label)};$checks.Add($Label)}
function Expect-Failure {param([scriptblock]$Action,[string]$Label);$failed=$false;try{$null=& $Action}catch{$failed=$true};Assert-Test $failed $Label}
function Read-TestJson {param([string]$Path);ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Path))}
function Write-TestJson {param([string]$Path,$Value);[IO.File]::WriteAllText($Path,(ConvertTo-Json -InputObject $Value -Depth 40),(New-Object Text.UTF8Encoding($true)))}
try{
    $module=Import-Module (Join-Path $source 'NodeStore.psm1') -Force -PassThru -DisableNameChecking
    & $module {
        $script:FixtureOriginalRunner=$script:TCNativeRunner
        $script:TCNativeRunner={param($FilePath,$ArgumentList,$InputText,$TimeoutMilliseconds=30000)
            $result=& $script:FixtureOriginalRunner -FilePath $FilePath -ArgumentList $ArgumentList -InputText $InputText -TimeoutMilliseconds $TimeoutMilliseconds
            if($result.ExitCode -ne 0){$script:FixtureNativeFailure=([string]$result.StandardError -replace '[A-Za-z0-9+/]{43}=', '[fixture-key]');if($ArgumentList[0] -eq 'check'){$script:FixtureDnsFailure=(Read-TCJson $ArgumentList[2]).dns.rules|ConvertTo-Json -Depth 15}}
            $result
        }
    }
    & $module {param($Path);New-TCPrivateDirectory $Path} $work
    $root=Join-Path $work 'Product';$null=Initialize-TCStore -Root $root
    $trade=Join-Path $work 'Trade.exe';$trade2=Join-Path $work 'Trade2.exe';[IO.File]::WriteAllText($trade,'inert');[IO.File]::WriteAllText($trade2,'inert')
    $client=Join-Path $work 'ProxyClient';$null=[IO.Directory]::CreateDirectory($client);$clientExe=Join-Path $client 'Proxy.exe';[IO.File]::WriteAllText($clientExe,'inert')
    $record=[pscustomobject]@{id=[guid]::NewGuid().ToString('D');slot=1;kind='custom';name='Fixture';directory=$client;extraDirectories=@();programPaths=@($clientExe);dailyPort=23101;tradePort=$null;httpPort=$null;pacPort=$null;bootstrapDomains=@('node.fixture.invalid');settingsDirectory=$null}
    $rng=[Security.Cryptography.RandomNumberGenerator]::Create();$a=New-Object byte[] 32;$b=New-Object byte[] 32;$rng.GetBytes($a);$rng.GetBytes($b);$rng.Dispose()
    $key=[Convert]::ToBase64String($a);$server=[Convert]::ToBase64String($b)
    $conf=Join-Path $work 'fixture.conf'
    [IO.File]::WriteAllText($conf,("[Interface]`nPrivateKey = {0}`nAddress = 10.77.0.2/24`nDNS = 1.1.1.1`nMTU = 1408`n[Peer]`nPublicKey = {1}`nEndpoint = 192.0.2.10:51820`nAllowedIPs = 0.0.0.0/0, ::/0`nPersistentKeepalive = 25`n" -f $key,$server))
    $engine=Join-Path $source 'assets\sing-box.exe';$wg=Join-Path $source 'assets\wg.exe'
    $node=Import-TCWireGuard -Root $root -Path $conf -Name 'Relay fixture' -EnginePath $engine -WgPath $wg -TradeProgramPaths @($trade) -DirectDnsIPv4 '127.0.0.1' -Providers @($record)
    $manifest=Read-TestJson $node.manifestPath;$config=Read-TestJson $manifest.CandidatePath
    Assert-Test ($manifest.ProviderRelay.Version -eq 1 -and $manifest.ProviderRelay.SlotCount -eq 4) 'New import reserves four provider slots'
    Assert-Test ($manifest.TradeProgramsSynchronized -eq $true) 'Explicit new import supports exact persistent-block synchronization'
    $daily=@($config.outbounds|Where-Object tag -eq 'daily-exit')[0];$tradeSelector=@($config.outbounds|Where-Object tag -eq 'trade-exit')[0]
    Assert-Test (($daily.outbounds -join ',') -ceq 'direct,provider,provider2,provider3,provider4') 'Daily selector reserves every daily lane'
    Assert-Test (($tradeSelector.outbounds -join ',') -ceq 'hk,provider-trade,provider2-trade,provider3-trade,provider4-trade') 'Trade selector reserves dedicated trade tags even for shared upstream'
    Assert-Test (@($config.outbounds|Where-Object type -eq 'socks').Count -eq 8) 'Eight fixed SOCKS outbounds exist'
    foreach($slot in $manifest.ProviderRelay.Slots){foreach($lane in @('Daily','Trade')){$o=@($config.outbounds|Where-Object {$_.tag -ceq $slot.($lane+'Tag')})[0];Assert-Test ($o.server -ceq '127.0.0.1' -and $o.server_port -eq $slot.($lane+'Port') -and $o.network -ceq 'tcp') ('Slot '+$slot.Slot+' '+$lane+' is loopback TCP')}}
    Assert-Test ($config.route.rules[0].rule_set[0] -ceq 'tc-providers' -and $config.route.rules[0].outbound -ceq 'direct') 'Provider process bypass precedes probes/trading/global/AI routes'
    Assert-Test ($config.dns.rules[0].rule_set[0] -ceq 'tc-providers-dns' -and $config.dns.rules[0].server -ceq 'dns-direct') 'Provider bootstrap/process DNS bypass precedes global/trade DNS'
    Assert-Test (@($config.route.rule_set|Where-Object {$_.tag -eq 'tc-providers' -and $_.path -ceq $manifest.ProviderRelay.RouteRuleSetPath}).Count -eq 1 -and @($config.route.rule_set|Where-Object {$_.tag -eq 'tc-providers-dns' -and $_.path -ceq $manifest.ProviderRelay.DnsRuleSetPath}).Count -eq 1) 'Actual NodeStore route/DNS both reference watched source files'
    $round=@(ConvertFrom-TCManifestProviders $manifest);Assert-Test ($round.Count -eq 1 -and $round[0].dailyPort -eq 23101 -and $round[0].tradePort -eq 23101 -and $round[0].id -ceq $record.id) 'Manifest roundtrip retains upstream identity and raw port, not relay port'
    foreach($field in @('dailyPort','tradePort','httpPort','pacPort')){$bad=ConvertFrom-Json -InputObject ($record|ConvertTo-Json -Depth 10);$bad.$field=17903;Expect-Failure {ConvertTo-TCPolicyProviders -Providers @($bad)} ($field+' rejects relay self-reference')}
    $originalHash=(Get-FileHash -LiteralPath $manifest.CandidatePath).Hash
    $routePath=$manifest.ProviderRelay.RouteRuleSetPath;$dnsPath=$manifest.ProviderRelay.DnsRuleSetPath
    [IO.File]::WriteAllText($routePath,'{"version":3,"rules":[{"process_path":["C:\\Fixture\\existing.exe"]}]}')
    [IO.File]::WriteAllText($dnsPath,'{"version":3,"rules":[{"domain":["existing.fixture.invalid"]}]}')
    $routeHash=(Get-FileHash -LiteralPath $routePath).Hash;$dnsHash=(Get-FileHash -LiteralPath $dnsPath).Hash
    $update=Update-TCNodePolicy -Root $root -ManifestPath $node.manifestPath -TradeProgramPaths @($trade2) -ReplaceTradePrograms
    $updated=Read-TestJson $update.ManifestPath;$updatedConfig=Read-TestJson $updated.CandidatePath
    Assert-Test ($updated.TradeProgramPaths.Count -eq 1 -and $updated.TradeProgramPaths[0] -ceq $trade2 -and $updated.TradeProgramsSynchronized) 'Explicit program replacement updates manifest and synchronization flag'
    Assert-Test ((ConvertTo-Json -InputObject $updatedConfig.route.rules -Depth 20) -match [regex]::Escape(($trade2 -replace '\\','\\')) -or @($updatedConfig.route.rules|Where-Object {@($_.process_path) -contains $trade2}).Count -gt 0) 'Program replacement reaches actual routing rules'
    Assert-Test ((Get-FileHash -LiteralPath $manifest.CandidatePath).Hash -ceq $originalHash -and $updated.PreviousManifestPath -ceq $node.manifestPath -and -not $updated.DeploymentApproved) 'Migration creates a separate, inactive and reversible candidate'
    Assert-Test ((Get-FileHash -LiteralPath $routePath).Hash -ceq $routeHash -and (Get-FileHash -LiteralPath $dnsPath).Hash -ceq $dnsHash) 'Preparing a candidate never edits live watched bypass files'
    $empty=Update-TCNodePolicy -Root $root -ManifestPath $node.manifestPath -TradeProgramPaths @() -ReplaceTradePrograms -ReplaceProviders -Providers @()
    $emptied=Read-TestJson $empty.ManifestPath;$emptyConfig=Read-TestJson $emptied.CandidatePath
    Assert-Test ($emptied.TradeProgramPaths.Count -eq 0 -and $emptied.TradeProgramsSynchronized) 'Explicit empty program list remains an exact synchronization request'
    Assert-Test ($emptied.Providers.Count -eq 0 -and @($emptyConfig.outbounds|Where-Object type -eq 'socks').Count -eq 8) 'Removing all providers retains fixed unused reservations'
    Expect-Failure {Update-TCNodePolicy -Root $root -ManifestPath $node.manifestPath -TradeProgramPaths @($trade2)} 'Program input without explicit replacement switch rejected'
    Expect-Failure {Update-TCNodePolicy -Root $root -ManifestPath $node.manifestPath -TradeProgramPaths @((Join-Path $work 'missing.exe')) -ReplaceTradePrograms} 'Missing executable cannot be marked synchronized'
    # A legacy manifest with no synchronization marker stays legacy unless the
    # caller explicitly replaces the list. The source is retained for rollback.
    $legacy=Read-TestJson $node.manifestPath;$legacy.PSObject.Properties.Remove('ProviderRelay');$legacy.PSObject.Properties.Remove('TradeProgramsSynchronized');$legacy.Providers[0].TradeTag='provider'
    $legacyPath=Join-Path $work 'legacy-manifest.json';Write-TestJson $legacyPath $legacy
    $upgrade=Update-TCNodePolicy -Root $root -ManifestPath $legacyPath
    $migrated=Read-TestJson $upgrade.ManifestPath
    Assert-Test ($migrated.ProviderRelay.Version -eq 1 -and -not $migrated.PSObject.Properties['TradeProgramsSynchronized']) 'Legacy provider migration does not invent trade-list authorization'
    Assert-Test ($migrated.PreviousManifestPath -ceq $legacyPath -and [IO.File]::Exists($legacyPath)) 'Legacy migration exposes original manifest for controlled rollback'
    [IO.File]::WriteAllText((Join-Path $root 'standby-quality.json'),'{}');$null=Initialize-TCStore $root
    Assert-Test $true 'OwnedStoreLayout permits exact regular standby-quality.json'
    [IO.File]::Delete((Join-Path $root 'standby-quality.json'));$null=[IO.Directory]::CreateDirectory((Join-Path $root 'standby-quality.json'))
    Expect-Failure {Initialize-TCStore $root} 'OwnedStoreLayout rejects directory masquerading as standby-quality.json'
    $report=[pscustomobject]@{Passed=$true;Checks=$checks.Count;Cases=$checks.ToArray();PowerShell=$PSVersionTable.PSVersion.ToString();NativeCommands=@('wg pubkey','sing-box check');NetworkChanges=0}
    if($ReportPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($true)))}
    $report|Select-Object Passed,Checks,PowerShell,NetworkChanges
}catch{Write-Output $_.ScriptStackTrace;if($module){& $module {$script:FixtureNativeFailure;$script:FixtureDnsFailure}};throw}
finally{
    $key=$null;$server=$null
    $full=[IO.Path]::GetFullPath($work);$base=[IO.Path]::GetFullPath([Environment]::GetFolderPath('LocalApplicationData')).TrimEnd('\')+'\'
    if(-not $full.StartsWith($base,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notmatch '^TCProviderPolicyTests-[a-f0-9]{32}$'){throw 'Fixture cleanup rejected'}
    if([IO.Directory]::Exists($full)){Remove-Item -LiteralPath $full -Recurse -Force}
}
