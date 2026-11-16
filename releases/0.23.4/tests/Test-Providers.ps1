#requires -Version 5.1
[CmdletBinding()]
param([string]$MihomoPath='C:\Program Files\Clash Verge\verge-mihomo.exe',[switch]$SkipNative)
# All fixtures/writes are under a fresh TEMP directory. No clients, TUN, routes,
# network connections, controller mutations or real settings are changed.
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
Set-StrictMode -Version 2
$runtime=Join-Path (Split-Path $PSScriptRoot -Parent) 'runtime'
. (Join-Path $runtime 'TradeChannel.Provider.ps1')
. (Join-Path $runtime 'TradeChannel.ProviderSetup.ps1')
$work=Join-Path ([IO.Path]::GetTempPath()) ('TCProvidersTests-'+[Guid]::NewGuid().ToString('N'))
$checks=New-Object 'Collections.Generic.List[string]';$native=0
function Assert-Test {param([bool]$Condition,[string]$Label);if(-not $Condition){throw ('Assertion failed: '+$Label)};$checks.Add($Label)}
function Expect-Failure {param([scriptblock]$Action,[string]$Label);$failed=$false;try{$null=& $Action}catch{$failed=$true};Assert-Test $failed $Label}
function Write-Fixture {param([string]$Path,[string]$Text);$null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path));[IO.File]::WriteAllText($Path,$Text,(New-Object Text.UTF8Encoding($true)))}
function New-Profile {
    param([int]$Index)
    $dir=Join-Path $work ('client-'+$Index);$exe=Join-Path $dir 'client.exe';Write-Fixture $exe ''
    [pscustomobject]@{Name=('client '+$Index);Kind='custom';Directory=$dir;ExtraDirectories=@();ProgramPaths=@($exe);DailyPort=(20000+$Index);TradePort=(21000+$Index);HttpPort=(20000+$Index);PacPort=$null;BootstrapDomains=@('HK1.example.test');SettingsDirectory=(Join-Path $work ('settings-'+$Index))}
}
# No actual port/socket/process interaction in tests: these are metadata mocks.
$script:TestOwners=@(501);$script:TestOwnerPaths=@{};$script:TestAddresses=@('127.0.0.1');$script:TestTunnel=$null
function Get-TCListenerOwnerIds {param([int]$Port);@($script:TestOwners)}
function Get-TCProcessImagePath {param([int]$Id);$script:TestOwnerPaths[$Id]}
function Get-TCProviderListenerAddresses {param([int]$Port);@($script:TestAddresses)}
function Get-TCForeignTunnel {$script:TestTunnel}
function Get-TCSetupBusyPorts {@(7897,17890,17891)}
function Test-TCOwnedListener {param([int]$Port,[string]$Directory);$false}
function Start-Process {throw 'Tests must not start clients'}
function Stop-Process {throw 'Tests must not stop clients'}
function Invoke-WebRequest {throw 'Tests must not connect to remote hosts'}
function Invoke-RestMethod {throw 'Tests must not call controllers'}
try {
    $null=[IO.Directory]::CreateDirectory($work)
    foreach($file in @('TradeChannel.Providers.ps1','TradeChannel.Provider.ps1','TradeChannel.ProviderSetup.ps1')){
        $path=Join-Path $runtime $file;$bytes=[IO.File]::ReadAllBytes($path);$tokens=$null;$errors=$null
        $null=[Management.Automation.Language.Parser]::ParseInput([IO.File]::ReadAllText($path),[ref]$tokens,[ref]$errors)
        Assert-Test (@($errors).Count -eq 0) ($file+' parses')
        Assert-Test ([BitConverter]::ToString($bytes,0,3) -eq 'EF-BB-BF') ($file+' UTF8 BOM')
    }
    $storeRoot=Join-Path $work 'store';$p1=New-Profile 1;$p2=New-Profile 2
    Assert-Test (@((Read-TCProviderStore $storeRoot).Providers).Count -eq 0) 'missing store empty'
    $r1=Add-TCProvider $storeRoot $p1;$r2=Add-TCProvider $storeRoot $p2
    $store=Read-TCProviderStore $storeRoot
    Assert-Test ($store.Providers.Count -eq 2 -and $r1.slot -eq 1 -and $r2.slot -eq 2) 'add slots'
    Assert-Test ($store.Providers[0].tradePort -eq 21001 -and $store.Providers[0].settingsDirectory -eq $p1.SettingsDirectory) 'settingsDirectory and tradePort roundtrip'
    $updated=Update-TCProvider $storeRoot $r1.id @{name='renamed';tradePort=$null}
    Assert-Test ($updated.id -eq $r1.id -and $updated.slot -eq 1 -and $updated.addedAt -eq $r1.addedAt -and $null -eq $updated.tradePort) 'partial update stable identity and nullable trade port'
    $null=Remove-TCProvider $storeRoot $r1.id;$p3=New-Profile 3;$r3=Add-TCProvider $storeRoot $p3
    Assert-Test ($r3.slot -eq 1 -and $r3.id -ne $r1.id -and (Read-TCProviderStore $storeRoot).Providers[1].id -eq $r2.id) 'delete does not renumber; vacancy reusable'
    $null=Add-TCProvider $storeRoot (New-Profile 4);$null=Add-TCProvider $storeRoot (New-Profile 5)
    Expect-Failure {Add-TCProvider $storeRoot (New-Profile 6)} 'fifth provider rejected'
    Expect-Failure {Update-TCProvider $storeRoot 'missing' @{name='x'}} 'unknown update rejected'
    Expect-Failure {Remove-TCProvider $storeRoot 'missing'} 'unknown delete rejected'
    $before=Get-FileHash -LiteralPath (Get-TCProviderStorePath $storeRoot)
    Expect-Failure {Update-TCProvider $storeRoot $r2.id @{dailyPort=$r3.dailyPort}} 'cross provider port conflict'
    Assert-Test ((Get-FileHash -LiteralPath (Get-TCProviderStorePath $storeRoot)).Hash -eq $before.Hash) 'failed update preserves bytes'
    foreach($field in @('dailyPort','tradePort','httpPort','pacPort')){Expect-Failure {Update-TCProvider $storeRoot $r2.id @{$field=17891}} ('reserved '+$field)}
    Expect-Failure {Update-TCProvider $storeRoot $r2.id @{tradePort=65536}} 'port overflow'
    Expect-Failure {Update-TCProvider $storeRoot $r2.id @{bootstrapDomains=@('*.example.test')}} 'wildcard bootstrap rejected'
    Expect-Failure {Update-TCProvider $storeRoot $r2.id @{directory=$env:TEMP}} 'shared root rejected'
    Expect-Failure {Update-TCProvider $storeRoot $r2.id @{extraDirectories=@($env:ProgramFiles)}} 'shared extra root rejected'
    $changed=(Read-TCProviderStore $storeRoot);$changed.Providers[0].slot=4
    Expect-Failure {Write-TCProviderStore $storeRoot $changed} 'raw duplicate/stable slot rejected'
    $corrupt=Join-Path $work 'corrupt';Write-Fixture (Join-Path $corrupt 'providers.json') '{bad'
    Expect-Failure {Write-TCProviderStore -StoreRoot $corrupt -Providers @()} 'damaged registry not overwritten'
    Write-Fixture (Join-Path $corrupt 'providers.json') '{"Version":1,"Providers":[{"id":"bad"}]}'
    Expect-Failure {Read-TCProviderStore $corrupt} 'invalid record not silently dropped'
    foreach($r in (Read-TCProviderStore $storeRoot).Providers){$null=Remove-TCProvider $storeRoot $r.id}
    Assert-Test (@((Read-TCProviderStore $storeRoot).Providers).Count -eq 0) 'last removal reloads empty registry'
    $null=Write-TCProviderStore -StoreRoot $storeRoot -Providers @($r1,$r2)
    Assert-Test ((Read-TCProviderStore $storeRoot).Providers.Count -eq 2) 'bridge Providers parameter'

    $manifest=[pscustomobject]@{Providers=@([pscustomobject]@{Tag='provider';TradeTag='provider-trade';Port=20001;TradePort=21001;Id=$r1.id;Slot=1;Kind='custom';Name='first';Directory=$p1.Directory;ExtraDirectories=@();Programs=$p1.ProgramPaths},[pscustomobject]@{Tag='provider2';Port=20002;Id=$r2.id;Slot=2;Kind='custom';Name='second';Directory=$p2.Directory;Programs=$p2.ProgramPaths});EnginePath=(Join-Path $work 'engine\sing-box.exe');ControlPort=17891;ProbePort=17890}
    Assert-Test ((Resolve-TCProviderTarget $manifest $r1.id).Tag -eq 'provider' -and (Resolve-TCProviderTarget $manifest $r1.id -ForTrade).Tag -eq 'provider-trade') 'daily and trade target tags'
    Assert-Test ((Resolve-TCProviderTarget $manifest $r1.id -ForTrade).Port -eq 21001 -and (Resolve-TCProviderTarget $manifest $r2.id -ForTrade).Port -eq 20002) 'dedicated and same trade ports'
    Assert-Test ((Get-TCProviderByTag $manifest 'provider-trade').Port -eq 21001) 'lookup by trade tag'
    Expect-Failure {Resolve-TCProviderTarget $manifest 'stale'} 'unknown manifest id refuses fallback'
    Expect-Failure {Resolve-TCProviderTarget $null 'stale'} 'unknown id refuses empty manifest'
    Expect-Failure {Resolve-TCProviderTarget $manifest ' '} 'nonempty whitespace id refuses fallback'
    $legacy=[pscustomobject]@{ProviderSocksPort=1080;ProviderDirectory=$p1.Directory;ProviderProgramPaths=$p1.ProgramPaths}
    Assert-Test ((Resolve-TCProviderTarget $legacy '00000000-0000-0000-0000-000000000001').Port -eq 1080) 'legacy stable identity'
    Assert-Test (21001 -in @(Get-TCProviderProxyPorts $manifest (Read-TCProviderStore $storeRoot))) 'trade port included in known ports'
    $script:TestOwnerPaths=@{501=$p1.ProgramPaths[0]}
    $health=Get-TCProviderHealth -Manifest $manifest -ProviderId $r1.id
    Assert-Test ($health.Healthy -and -not $health.TradingEgressVerified) 'healthy local owner not egress validation'
    $health=Get-TCProviderHealth -Manifest $manifest -ProviderId $r1.id -ForTrade
    Assert-Test ($health.Healthy -and $health.Port -eq 21001) 'trade health uses trade port'
    $script:TestOwners=@(501,502);$script:TestOwnerPaths[502]=$p2.ProgramPaths[0]
    Assert-Test ((Get-TCProviderHealth $manifest -ProviderId $r1.id).Reason -eq 'UnknownOwner') 'mixed listener owners rejected'
    $script:TestOwnerPaths[502]=$null
    Assert-Test ((Get-TCProviderHealth $manifest -ProviderId $r1.id).Reason -eq 'UnknownOwner') 'inaccessible owner rejected'
    $script:TestOwners=@(501);$script:TestOwnerPaths[501]=$manifest.EnginePath
    Assert-Test ((Get-TCProviderHealth $manifest -ProviderId $r1.id).Reason -eq 'LoopbackRisk') 'own engine rejected'
    $script:TestOwnerPaths[501]=$p1.ProgramPaths[0];$script:TestAddresses=@('192.0.2.1')
    Assert-Test ((Get-TCProviderHealth $manifest -ProviderId $r1.id).Reason -eq 'LoopbackUnavailable') 'nonloopback listener rejected'
    $script:TestAddresses=@('127.0.0.1');$script:TestTunnel='OtherTun'
    Assert-Test ((Get-TCProviderHealth $manifest -ProviderId $r1.id).Reason -eq 'ForeignTunnel') 'foreign TUN metadata rejected'
    $script:TestTunnel=$null;$script:TestOwners=@()
    Assert-Test ((Get-TCProviderHealth $manifest -ProviderId $r1.id).Reason -eq 'NotListening') 'stopped client unhealthy'
    $script:TestOwners=@(501)

    $clashDir=Join-Path $work 'Clash';$settings=Join-Path $work 'VergeSettings';Write-Fixture (Join-Path $clashDir 'clash-verge.exe') '';Write-Fixture (Join-Path $clashDir 'verge-mihomo.exe') ''
    $profile=[pscustomobject]@{kind='clashverge';name='Clash';directory=$clashDir;programPaths=@((Join-Path $clashDir 'clash-verge.exe'),(Join-Path $clashDir 'verge-mihomo.exe'));extraDirectories=@();dailyPort=7897;tradePort=$null;httpPort=7897;pacPort=$null;bootstrapDomains=@();settingsDirectory=$settings}
    $base=@('mixed-port: 7897','mode: rule','allow-lan: false','tun: {enable: false}','dns: {enable: false}','proxies:','  - name: "HK node"','    type: socks5','    server: 192.0.2.10','    port: 1080','proxy-groups:','  - name: "Backup"','    type: select','    proxies: ["HK node", DIRECT]','rules:','  - MATCH,Backup') -join "`n"
    Write-Fixture (Join-Path $settings 'clash-verge.yaml') $base
    Write-Fixture (Join-Path $settings 'config.yaml') 'mixed-port: 9999'
    Write-Fixture (Join-Path $settings 'verge.yaml') "verge_mixed_port: 9998`nenable_system_proxy: false`nenable_tun_mode: false`nenable_proxy_guard: false"
    Write-Fixture (Join-Path $settings 'profiles.yaml') "current: abc`nitems:`n  - uid: Merge`n    type: merge`n    file: custom-global.yaml"
    $mergePath=Join-Path $settings 'profiles\custom-global.yaml';$backup=Join-Path $work 'backups'
    $state=Get-TCClashVergeState -InstallDirectory $clashDir -ConfigDirectory $settings -SkipRuntime
    Assert-Test ($state.DailyPort -eq 7897 -and -not $state.Ready -and $state.MergePath -eq $mergePath) 'effective filename and global merge metadata'
    $plan=Get-TCProviderSetupPlan -Profile $profile -BusyPorts @(7897,7895)
    Assert-Test ($plan.TradePort -eq 7894 -and $plan.TradeProxy -eq 'Backup' -and -not $plan.TradingEgressVerified) 'free port and group remain unverified'
    Expect-Failure {Get-TCProviderSetupPlan $profile -TradeProxy DIRECT -BusyPorts @()} 'DIRECT target rejected'
    Expect-Failure {Get-TCProviderSetupPlan $profile -TradeProxy 'unknown' -BusyPorts @()} 'unknown proxy rejected'
    Expect-Failure {Get-TCProviderSetupPlan $profile -TradePort 7897 -BusyPorts @()} 'daily port collision rejected'
    Expect-Failure {New-TCClashManagedBlock 7895 "bad`nname"} 'proxy name newline rejected'
    Assert-Test ((Select-TCClashTradePort -Busy @(7895) -Keep 7895) -eq 7894) 'busy Keep is not reused'
    # Explicit no-state-change proof: snapshot every fixture before preparation.
    # Only the merge file and its backup receipt may be created/modified.
    Write-Fixture (Join-Path $work 'session\deployment.json') '{"Exit":"hk","Daily":"direct","Agent":"hk"}'
    Write-Fixture (Join-Path $work 'session\selectors.json') '{"trading":"hk","agent":"hk","running":true}'
    $beforeApply=@{};foreach($file in Get-ChildItem -LiteralPath $work -File -Recurse){$beforeApply[$file.FullName]=(Get-FileHash -LiteralPath $file.FullName).Hash}
    $applied=Invoke-TCClashPreparation -Profile $profile -BackupRoot $backup
    $outsideChanges=@(foreach($file in Get-ChildItem -LiteralPath $work -File -Recurse){
        if($file.FullName -eq $mergePath -or (Test-TCProviderPathWithin $file.FullName $backup)){continue}
        if(-not $beforeApply.ContainsKey($file.FullName) -or $beforeApply[$file.FullName] -ne (Get-FileHash -LiteralPath $file.FullName).Hash){$file.FullName}
    })
    $deletedOutside=@($beforeApply.Keys|Where-Object {$_ -ne $mergePath -and -not [IO.File]::Exists($_)})
    Assert-Test ($outsideChanges.Count -eq 0 -and $deletedOutside.Count -eq 0) 'prepare writes only merge and backups; HK/session/settings bytes unchanged'
    $tokens=$null;$errors=$null;$setupAst=[Management.Automation.Language.Parser]::ParseInput([IO.File]::ReadAllText((Join-Path $runtime 'TradeChannel.ProviderSetup.ps1')),[ref]$tokens,[ref]$errors)
    $forbidden=@($setupAst.FindAll({param($n)
        if($n -is [Management.Automation.Language.CommandAst]){return $n.GetCommandName() -match '^(Start-Process|Stop-Process|Restart-Service|Start-Service|Stop-Service|Set-Net.*|New-Net.*|Remove-Net.*|Set-ItemProperty|Invoke-RestMethod|Invoke-WebRequest|Start-TCClashVerge|Stop-TCClashVerge|Set-TradeChannel.*)$'}
        if($n -is [Management.Automation.Language.InvokeMemberExpressionAst]){return $n.Member.Value -in @('Start','Kill','Connect','GetAsync','SendAsync')};return $false
    },$true))
    Assert-Test ($forbidden.Count -eq 0) 'setup contains no client launch/stop/controller request/route mutation calls'

    Assert-Test ($applied.Applied -and $applied.Changed -and -not $applied.Effective -and -not $applied.TradingEgressVerified -and $applied.RestartRequired) 'apply prepares file only'
    Assert-Test ([IO.File]::Exists($applied.BackupPath)) 'new file also receives recovery receipt'
    $state=Get-TCClashVergeState -InstallDirectory $clashDir -ConfigDirectory $settings -SkipRuntime
    Assert-Test ($state.TradePort -eq $applied.TradePort -and $state.RestartRequired -and -not $state.SnifferReady) 'unloaded managed port available for registration'
    $again=Invoke-TCClashPreparation -Profile $profile -BackupRoot $backup
    Assert-Test (-not $again.Changed -and $null -eq $again.BackupPath) 'apply is idempotent'
    $restored=Restore-TCClashPreparation -Profile $profile -BackupRoot $backup
    Assert-Test ($restored.Restored -and -not [IO.File]::Exists($mergePath)) 'restore absent original removes only new merge file'
    Assert-Test (-not (Restore-TCClashPreparation -Profile $profile -BackupRoot $backup).Changed) 'restore is idempotent'
    Write-Fixture $mergePath "# original bytes`r`nlog-level: warning`r`n"
    $before=[Convert]::ToBase64String([IO.File]::ReadAllBytes($mergePath));$applied=Invoke-TCClashPreparation $profile $backup
    $null=Restore-TCProviderSetup $profile $applied.BackupPath $backup
    Assert-Test ([Convert]::ToBase64String([IO.File]::ReadAllBytes($mergePath)) -ceq $before) 'restore preserves exact BOM and CRLF bytes'
    $applied=Invoke-TCClashPreparation $profile $backup
    [IO.File]::AppendAllText($mergePath,"# user changed`n")
    Expect-Failure {Restore-TCProviderSetup $profile $applied.BackupPath $backup} 'restore refuses subsequent user edits'
    Write-Fixture $mergePath "'sniffer':`n  enable: false"
    Expect-Failure {Invoke-TCClashPreparation $profile $backup} 'quoted custom sniffer conflict'
    Write-Fixture $mergePath ($script:TCClashBegin+"`npartial: true")
    Expect-Failure {Read-TCClashMerge $mergePath} 'partial marker rejected'
    Write-Fixture $mergePath ''
    $block=New-TCClashManagedBlock 7895 'Backup';$facts=Get-TCClashRuntimeFacts $block
    Assert-Test ($facts.SnifferReady -and $facts.Listener.NoAuth -and $facts.Listener.Listen -eq '127.0.0.1') 'generated sniffer and loopback noauth listener'
    $bad=@($block -replace 'parse-pure-ip: true','parse-pure-ip: false')
    Assert-Test (-not (Get-TCClashRuntimeFacts $bad).SnifferReady) 'pure IP sniff required'
    $bad=@($block -replace 'ports: \[443, 8443\]','ports: [8443]')
    Assert-Test (-not (Get-TCClashRuntimeFacts $bad).SnifferReady) 'protocol ports checked'
    Expect-Failure {Get-TCClashRuntimeFacts @('sniffer: {enable: true}','sniffer: {enable: false}')} 'duplicate YAML key rejected'
    Expect-Failure {Get-TCClashRuntimeFacts @('sniffer: &defaults {enable: true}')} 'YAML alias not guessed'
    $jsonlike=@('mixed-port: 7897','proxies: [{name: "x # y", type: socks5, server: example.test, port: 1080}]','proxy-groups: [{name: "a,b", type: select, proxies: ["x # y", DIRECT]}]')
    $facts=Get-TCClashRuntimeFacts $jsonlike
    Assert-Test ($facts.Groups[0] -ceq 'a,b' -and $facts.NodeServers[0] -ceq 'example.test') 'flow YAML and quoted delimiters'
    $effective=$base+"`n"+($block -join "`n");Write-Fixture (Join-Path $settings 'clash-verge.yaml') $effective
    $null=Invoke-TCClashPreparation $profile $backup
    $state=Get-TCClashVergeState -InstallDirectory $clashDir -ConfigDirectory $settings -SkipRuntime
    Assert-Test ($state.SnifferReady -and -not $state.RestartRequired -and -not $state.Effective -and -not $state.TradingEgressVerified) 'generated config checks never prove active egress'
    Expect-Failure {Start-TCClashVerge $clashDir} 'start entry cannot start engine'
    Expect-Failure {Stop-TCClashVerge $clashDir} 'stop entry cannot stop engine'
    Assert-Test (-not (Test-TCProviderPorts 7897 7895).TradingEgressVerified) 'legacy probes cannot certify trade'

    $batDir=Join-Path $work 'Bat';Write-Fixture (Join-Path $batDir 'BatVPN.exe') '';$batConfig=Join-Path $work 'BatSettings\config.json'
    Write-Fixture $batConfig '{"inbounds":[{"protocol":"socks","listen":"127.0.0.1","port":1080,"settings":{"auth":"noauth"},"sniffing":{"enabled":true}}],"outbounds":[{"settings":{"vnext":[{"address":"node.example.test"}]}}]}'
    $bat=Get-TCBatVPNState -InstallDirectory $batDir -ConfigPath $batConfig -SkipRuntime
    Assert-Test ($bat.DailyPort -eq 1080 -and $bat.BootstrapDomains[0] -eq 'node.example.test' -and -not $bat.TradingEgressVerified) 'BatVPN sparse configuration detection'
    $custom=Get-TCCustomProviderState -Profile $p1 -SkipRuntime
    Assert-Test ($custom.DailyPort -eq 20001 -and -not $custom.Ready) 'custom profile offline detection'

    # Complete bootstrap reporting: never return a silently truncated list.
    $many=@('mixed-port: 7897','proxies:')
    foreach($index in 1..257){$many+=@(('  - name: n'+$index),'    type: socks5',('    server: n'+$index+'.example.test'),'    port: 1080')}
    Expect-Failure {Get-TCClashRuntimeFacts $many} 'oversized bootstrap set rejected'
    Expect-Failure {Get-TCClashRuntimeFacts @('proxy-providers: {pool: {type: http, url: "https://example.test/sub"}}')} 'dynamic subscription cannot hide bootstrap domains'
    Write-Fixture (Join-Path $settings 'clash-verge.yaml') ($many -join "`n")
    $incomplete=Get-TCClashVergeState -InstallDirectory $clashDir -ConfigDirectory $settings -SkipRuntime
    Assert-Test (-not $incomplete.BootstrapComplete) 'detection flags incomplete bootstrap'
    Expect-Failure {New-TCProviderRecord $incomplete 1} 'incomplete detected profile cannot register'
    $manifest.Providers[0]|Add-Member NoteProperty BootstrapDomains @('changed.example.test')
    $legacy|Add-Member NoteProperty ProviderBootstrapDomains @('legacy.example.test')
    Assert-Test ((Get-TCManifestProviders $manifest)[0].BootstrapDomains[0] -eq 'changed.example.test' -and (Get-TCManifestProviders $legacy)[0].BootstrapDomains[0] -eq 'legacy.example.test') 'manifest bootstrap for modern and legacy targets'

    # Trading policy: only local facts and mocked authenticated GET snapshots.
    $script:TestOwnerPaths=@{501=(Join-Path $clashDir 'verge-mihomo.exe')};$script:TestOwners=@(501)
    $script:TestProcessConfig=$true;$script:TestApiCalls=0
    function Test-TCProviderProcessConfig {param([int]$OwnerId,[string]$ConfigPath);$script:TestProcessConfig}
    $script:TestApi=@{
        '/configs'=@{'mixed-port'=7897;mode='rule';tun=@{enable=$false}}
        '/proxies'=@{proxies=@{Backup=@{type='Selector';now='HK node';all=@('HK node','DIRECT')};'HK node'=@{type='Socks5';alive=$true};DIRECT=@{type='Direct'}}}
        '/connections'=@{connections=@()}
    }
    function Invoke-TCProviderControllerRead {
        param([string]$Endpoint,[string]$Secret,[string]$Path)
        if($Endpoint -ne '127.0.0.1:9090' -or $Secret -ne 'test-secret'){throw 'Wrong controller/secret'}
        $script:TestApiCalls++;$script:TestApi[$Path]
    }
    $tradingConfig=$effective+"`nexternal-controller: 127.0.0.1:9090`nsecret: test-secret"
    $tradingConfig=$tradingConfig.Replace('    port: 1080',"    port: 1080`n    password: fixture-do-not-leak-secret")
    Write-Fixture (Join-Path $settings 'clash-verge.yaml') $tradingConfig
    $target=[pscustomobject]@{Kind='clashverge';Port=7895;Name='Clash';Tag='provider-trade';Directory=$clashDir;Directories=@($clashDir);Programs=$profile.programPaths;SettingsDirectory=$settings}
    $safeState=Get-TCProviderClientState $profile
    $safeCandidate=Get-TCClashVergeState -InstallDirectory $clashDir -ConfigDirectory $settings -SkipRuntime
    $safeResult=Invoke-TCClashPreparation $profile $backup
    $serialized=@($safeState,$safeCandidate,$safeResult)|ConvertTo-Json -Depth 20
    Assert-Test (-not $serialized.Contains('fixture-do-not-leak-secret') -and -not $serialized.Contains('test-secret') -and -not $safeState.PSObject.Properties['Details'] -and -not $safeCandidate.PSObject.Properties['RuntimeFacts']) 'public client state/candidate/setup do not serialize secrets'
    $policy=Test-TCProviderTradingPolicy $target
    Assert-Test ($policy.Allowed -and $policy.TradingEgressVerified -and $policy.Chain -contains 'HK node') 'authenticated selected remote chain permits policy'
    $script:TestApi['/proxies'].proxies.Backup.now='DIRECT'
    Assert-Test (-not (Test-TCProviderTradingPolicy $target).Allowed) 'selected DIRECT blocks trade'
    $script:TestApi['/proxies'].proxies.Backup=@{type='Fallback';now='HK node';all=@('HK node','DIRECT')}
    Assert-Test (-not (Test-TCProviderTradingPolicy $target).Allowed) 'automatic fallback to DIRECT blocks trade'
    $script:TestApi['/proxies'].proxies.Backup=@{type='Selector';now='Backup';all=@('Backup')}
    Assert-Test (-not (Test-TCProviderTradingPolicy $target).Allowed) 'cyclic controller chain blocks trade'
    $script:TestApi['/proxies'].proxies.Backup=@{type='Selector';now='HK node';all=@('HK node','DIRECT')}
    $script:TestApi['/proxies'].proxies['HK node'].type='Reject'
    Assert-Test (-not (Test-TCProviderTradingPolicy $target).Allowed) 'renamed reject leaf blocks trade'
    $script:TestApi['/proxies'].proxies['HK node'].type='Socks5'
    $script:TestApi['/configs'].mode='direct'
    Assert-Test (-not (Test-TCProviderTradingPolicy $target).Allowed) 'live direct mode blocks trade'
    $script:TestApi['/configs'].mode='rule';$script:TestProcessConfig=$false
    Assert-Test ((Test-TCProviderTradingPolicy $target).Reason -eq 'RuntimeConfigUnproven') 'stale generated config cannot prove active listener'
    $script:TestApi['/connections'].connections=@(@{metadata=@{inboundName='tradechannel-trade';inboundPort='7895';inboundIP='127.0.0.1';specialProxy='Backup'};chains=@('HK node','Backup')})
    Assert-Test ((Test-TCProviderTradingPolicy $target).Allowed) 'active inbound metadata corroborates loaded listener'
    $script:TestApi['/connections'].connections[0].chains=@('DIRECT','Backup')
    Assert-Test (-not (Test-TCProviderTradingPolicy $target).Allowed) 'active direct connection not corroboration'
    $script:TestProcessConfig=$true
    Write-Fixture (Join-Path $settings 'clash-verge.yaml') $effective
    $apiCalls=$script:TestApiCalls
    Assert-Test ((Test-TCProviderTradingPolicy $target).Reason -eq 'AuthenticatedControllerRequired') 'missing controller authentication rejected'
    Assert-Test ($script:TestApiCalls -eq $apiCalls) 'unauthenticated check makes no API call'
    Write-Fixture (Join-Path $settings 'clash-verge.yaml') ($tradingConfig.Replace('127.0.0.1:9090','192.0.2.10:9090'))
    Assert-Test ((Test-TCProviderTradingPolicy $target).Reason -eq 'AuthenticatedControllerRequired') 'nonloopback controller refused'
    Write-Fixture (Join-Path $settings 'clash-verge.yaml') $tradingConfig
    $target.Port=7897
    Assert-Test ((Test-TCProviderTradingPolicy $target).Reason -eq 'DedicatedListenerRequired') 'daily listener cannot satisfy trade gate'
    $target.Port=7895
    # Named pipe transport is tested against in-memory duplex streams only.
    # No real pipe/controller is opened, and secrets are checked after PID identity.
    # The OS identity leaf below is a fixture. The precompiled helper is tested
    # against a real local pipe by Test-NativeReadHelpers, from a protected package.
    Add-Type -TypeDefinition @"
using System; using System.IO; using System.Threading; using System.Threading.Tasks;
public class TCProviderTestDuplex : Stream {
  private readonly MemoryStream input; public readonly MemoryStream Written = new MemoryStream();
  public TCProviderTestDuplex(byte[] data) { input = new MemoryStream(data); }
  public override bool CanRead { get { return true; } } public override bool CanSeek { get { return false; } } public override bool CanWrite { get { return true; } }
  public override long Length { get { return input.Length; } } public override long Position { get { return input.Position; } set { throw new NotSupportedException(); } }
  public override int Read(byte[] b,int o,int c) { return input.Read(b,o,c); }
  public override Task<int> ReadAsync(byte[] b,int o,int c,CancellationToken t) { return Task.FromResult(input.Read(b,o,c)); }
  public override void Write(byte[] b,int o,int c) { Written.Write(b,o,c); }
  public override Task WriteAsync(byte[] b,int o,int c,CancellationToken t) { Written.Write(b,o,c); return Task.FromResult(0); }
  public override void Flush() {} public override long Seek(long o,SeekOrigin s) { throw new NotSupportedException(); } public override void SetLength(long v) { throw new NotSupportedException(); }
}
"@
    $script:PipeOwner=501;$script:PipeBodies=New-Object 'Collections.Generic.Queue[string]';$script:LastTestPipe=$null
    function Open-TCProviderControlPipe {
        param([string]$Name,[int]$TimeoutMilliseconds=2000)
        if($Name -ne 'tc-test'){throw 'Unexpected pipe name'}
        $bytes=[Text.Encoding]::UTF8.GetBytes($script:PipeBodies.Dequeue())
        $script:LastTestPipe=New-Object TCProviderTestDuplex(,$bytes);$script:LastTestPipe
    }
    function Get-TCProviderPipeServerId {param($Pipe);$script:PipeOwner}
    function Queue-PipeJson {
        param($Value)
        $body=ConvertTo-Json -InputObject $Value -Depth 16 -Compress
        $length=[Text.Encoding]::UTF8.GetByteCount($body)
        $script:PipeBodies.Enqueue("HTTP/1.0 200 OK`r`nContent-Length: $length`r`nContent-Type: application/json`r`n`r`n"+$body)
    }
    Queue-PipeJson @{ok=$true}
    $pipeResult=Invoke-TCProviderPipeRead -PipePath '\\.\pipe\tc-test' -Secret 'test-secret' -OwnerId 501 -Path '/proxies'
    Assert-Test ([bool]$pipeResult.ok) 'named pipe bounded HTTP JSON parsed'
    $requestText=[Text.Encoding]::UTF8.GetString($script:LastTestPipe.Written.ToArray())
    Assert-Test ($requestText.StartsWith('GET /proxies HTTP/1.0') -and $requestText.Contains('Authorization: Bearer test-secret') -and $requestText.Contains('Connection: close')) 'pipe request GET auth and connection close'
    $script:PipeOwner=502;Queue-PipeJson @{ok=$true}
    Expect-Failure {Invoke-TCProviderPipeRead -PipePath '\\.\pipe\tc-test' -Secret 'test-secret' -OwnerId 501 -Path '/proxies'} 'wrong pipe PID rejected'
    Assert-Test ($script:LastTestPipe.Written.Length -eq 0) 'wrong pipe PID receives no secret'
    $script:PipeOwner=501
    Expect-Failure {Invoke-TCProviderPipeRead -PipePath '\\otherhost\pipe\tc-test' -Secret 'test-secret' -OwnerId 501 -Path '/configs'} 'remote named pipe prohibited'
    Expect-Failure {Invoke-TCProviderPipeRead -PipePath '\\.\pipe\tc-test' -Secret 'test-secret' -OwnerId 501 -Path '/restart'} 'mutating pipe endpoint prohibited'
    $script:PipeBodies.Enqueue("HTTP/1.0 401 Unauthorized`r`nContent-Length: 2`r`n`r`n{}")
    Expect-Failure {Invoke-TCProviderPipeRead -PipePath '\\.\pipe\tc-test' -Secret 'test-secret' -OwnerId 501 -Path '/configs'} 'pipe authentication failure rejected'
    $script:PipeBodies.Enqueue("HTTP/1.0 200 OK`r`nContent-Length: 99`r`n`r`n{}")
    Expect-Failure {Invoke-TCProviderPipeRead -PipePath '\\.\pipe\tc-test' -Secret 'test-secret' -OwnerId 501 -Path '/configs'} 'truncated pipe JSON rejected'
    $small=New-Object TCProviderTestDuplex(,[Text.Encoding]::ASCII.GetBytes("HTTP/1.0 200 OK`r`n`r`n"+('x'*100)))
    Expect-Failure {Read-TCProviderControlResponse $small -MaxBytes 20} 'pipe response size bounded'
    $pipeConfig=$effective+"`nexternal-controller-pipe: '\\.\pipe\tc-test'`nsecret: test-secret"
    Write-Fixture (Join-Path $settings 'clash-verge.yaml') $pipeConfig
    Queue-PipeJson $script:TestApi['/configs'];Queue-PipeJson $script:TestApi['/proxies']
    $apiCalls=$script:TestApiCalls;$policy=Test-TCProviderTradingPolicy $target
    Assert-Test ($policy.Allowed -and $policy.TradingEgressVerified -and $script:TestApiCalls -eq $apiCalls) 'pipe-only authenticated policy works without TCP'
    Write-Fixture (Join-Path $settings 'clash-verge.yaml') ($pipeConfig+"`nexternal-controller: 127.0.0.1:9090")
    Queue-PipeJson $script:TestApi['/configs'];Queue-PipeJson $script:TestApi['/proxies']
    Assert-Test ((Test-TCProviderTradingPolicy $target).Allowed -and $script:TestApiCalls -eq $apiCalls) 'named pipe preferred over TCP'

    $manual=[pscustomobject]@{Kind='custom';Port=20001}
    Assert-Test (-not (Test-TCProviderTradingPolicy $manual).Allowed) 'manual clients explicitly unverified'
    $batTarget=[pscustomobject]@{Kind='batvpn';Port=1080;Name='Bat';Directory=$batDir;Directories=@($batDir);Programs=@((Join-Path $batDir 'BatVPN.exe'));SettingsDirectory=(Split-Path $batConfig -Parent)}
    $batDoc=@{inbounds=@(@{protocol='socks';port=1080});outbounds=@(@{tag='remote';protocol='vmess';settings=@{vnext=@(@{address='node.example.test'})}},@{tag='direct';protocol='freedom'});routing=@{rules=@(@{type='field';port='0-65535';outboundTag='direct'})}}
    Write-Fixture $batConfig ($batDoc|ConvertTo-Json -Depth 10)
    Assert-Test ((Test-TCProviderTradingPolicy $batTarget).Reason -eq 'DirectOrRejectRoute') 'Bat final direct rule blocks trade'
    $batDoc.routing.rules=@();Write-Fixture $batConfig ($batDoc|ConvertTo-Json -Depth 10);$script:TestOwnerPaths=@{501=(Join-Path $batDir 'BatVPN.exe')}
    Assert-Test ((Test-TCProviderTradingPolicy $batTarget).Allowed) 'Bat loaded remote-only routing permits policy'
    $batDoc.routing.rules=@(@{type='field';ip=@('geoip:private','10.0.0.0/8','127.0.0.1','fc00::/7','::1');outboundTag='direct'})
    Write-Fixture $batConfig ($batDoc|ConvertTo-Json -Depth 10)
    Assert-Test ((Test-TCProviderTradingPolicy $batTarget).Allowed) 'Bat remote default with only private exceptions allowed'
    foreach($public in @('0.0.0.0/0','10.0.0.0/7','192.0.0.0/8','geoip:cn','geoip:!private','::/0','8.8.8.8')){
        $batDoc.routing.rules[0].ip=@('geoip:private',$public);Write-Fixture $batConfig ($batDoc|ConvertTo-Json -Depth 10)
        Assert-Test (-not (Test-TCProviderTradingPolicy $batTarget).Allowed) ('Bat public exception rejected: '+$public)
    }
    $batDoc.routing.rules=@(@{type='field';domain=@('domain:example.test');outboundTag='direct'});Write-Fixture $batConfig ($batDoc|ConvertTo-Json -Depth 10)
    Assert-Test (-not (Test-TCProviderTradingPolicy $batTarget).Allowed) 'Bat public domain direct refused'
    $batDoc.routing.rules=@();Write-Fixture $batConfig ($batDoc|ConvertTo-Json -Depth 10)
    $script:TestProcessConfig=$false
    Assert-Test (-not (Test-TCProviderTradingPolicy $batTarget).Allowed) 'Bat unloaded file cannot authorize trade'

    if(-not $SkipNative){
        if(-not [IO.File]::Exists($MihomoPath)){throw 'Mihomo check binary unavailable. Supply -MihomoPath or explicitly use -SkipNative.'}
        # -t parses then exits before hub startup. No GEO rules/providers/DNS/TUN,
        # subscriptions or URLs: the test cannot fetch a geodata/provider database.
        $nativeDir=Join-Path $work 'native';$config=Join-Path $nativeDir 'config.yaml';Write-Fixture $config $effective
        foreach($case in @('valid','invalid-port')){
            if($case -eq 'invalid-port'){Write-Fixture $config ($effective.Replace('port: 7895','port: invalid-port'))}
            $si=New-Object Diagnostics.ProcessStartInfo;$si.FileName=$MihomoPath;$si.Arguments='-t -d "'+$nativeDir+'" -f "'+$config+'"';$si.WorkingDirectory=$nativeDir;$si.UseShellExecute=$false;$si.CreateNoWindow=$true;$si.RedirectStandardOutput=$true;$si.RedirectStandardError=$true
            foreach($key in @($si.EnvironmentVariables.Keys)){if([string]$key -match '^(CLASH_|MIHOMO_|SAFE_PATHS$)'){$si.EnvironmentVariables.Remove($key)}}
            $process=New-Object Diagnostics.Process;$process.StartInfo=$si
            try{$null=$process.Start();$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync();if(-not $process.WaitForExit(15000)){$process.Kill();throw 'mihomo -t timed out'};$output=$stdout.GetAwaiter().GetResult();$errorOutput=$stderr.GetAwaiter().GetResult();if($case -eq 'valid'){Assert-Test ($process.ExitCode -eq 0) 'real mihomo validates generated listener/sniffer'}else{Assert-Test ($process.ExitCode -ne 0) 'real mihomo rejects invalid listener port'};$native++}finally{$process.Dispose()}
        }
    }
    [pscustomobject]@{Passed=$checks.Count;NativeChecks=$native;PowerShell=$PSVersionTable.PSVersion.ToString();NetworkChanges=0;Checks=$checks.ToArray()}
} catch { Write-Output $_.ScriptStackTrace;throw } finally {
    # Exact generated TEMP directory only, verified before recursive deletion.
    $full=[IO.Path]::GetFullPath($work);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if($full.StartsWith($temp+'\',[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($full) -match '^TCProvidersTests-[0-9a-f]{32}$' -and [IO.Directory]::Exists($full)){Remove-Item -LiteralPath $full -Recurse -Force}
}
