#requires -Version 5.1
[CmdletBinding()]
param([string]$ReportPath)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$source=Split-Path $PSScriptRoot -Parent
$work=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('TCProviderRelayTests-'+[guid]::NewGuid().ToString('N'))
$checks=New-Object 'Collections.Generic.List[string]';$processes=New-Object 'Collections.Generic.List[object]';$hostObject=$null;$runner=$null;$fixtureEngine=$null
function Assert-Test {param($Value,[string]$Label);if(-not $Value){throw ('Assertion: '+$Label)};$checks.Add($Label)}
function Expect-Failure {param([scriptblock]$Action,[string]$Label);$failed=$false;try{$null=& $Action}catch{$failed=$true};Assert-Test $failed $Label}
function Write-TestJson {param([string]$Path,$Value);[IO.File]::WriteAllText($Path,(ConvertTo-Json -InputObject $Value -Depth 40),(New-Object Text.UTF8Encoding($false)))}
function Read-TestJson {param([string]$Path);Read-TCRelayJson $Path}
function Wait-File {param([string]$Path,$Process);$deadline=[DateTime]::UtcNow.AddSeconds(12);while(-not [IO.File]::Exists($Path)){
    if($Process -and $Process.HasExited){$errorPath=Join-Path ([IO.Path]::GetDirectoryName($Path)) 'fixture-error.txt';if([IO.File]::Exists($errorPath)){throw [IO.File]::ReadAllText($errorPath)};throw 'Fixture exited before readiness'}
    if([DateTime]::UtcNow -ge $deadline){throw ('Fixture timeout: '+[IO.Path]::GetFileName($Path))};Start-Sleep -Milliseconds 50
}}
function Start-Backend {param([string]$Exe,[string]$Mark,[int]$Port=0)
    $ready=Join-Path $work ('ready-'+[guid]::NewGuid().ToString('N'))
    $args=@([string]$Port,('"'+$ready+'"'),$Mark,[string]$PID,[string](Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks)
    $p=Start-Process -FilePath $Exe -ArgumentList $args -WindowStyle Hidden -PassThru;$processes.Add($p);Wait-File $ready $p
    [pscustomobject]@{Process=$p;Port=[int][IO.File]::ReadAllText($ready);Exe=$Exe;Mark=$Mark}
}
function Read-Exact {param($Stream,[int]$Length);$bytes=New-Object byte[] $Length;$offset=0;while($offset -lt $Length){$count=$Stream.Read($bytes,$offset,$Length-$offset);if(-not $count){throw 'Unexpected EOF'};$offset+=$count};,$bytes}
function Open-FixtureSocks {param([int]$Port,[string]$Destination='fixture.invalid',[byte]$Command=1)
    $c=New-Object Net.Sockets.TcpClient;$c.ReceiveTimeout=2500;$c.SendTimeout=2500
    try{
        $c.Connect('127.0.0.1',$Port);$s=$c.GetStream();$s.Write([byte[]]@(5,1,0),0,3);$hello=Read-Exact $s 2;if($hello[0] -ne 5 -or $hello[1] -ne 0){throw 'SOCKS negotiation failed'}
        $domain=[Text.Encoding]::ASCII.GetBytes($Destination);$request=[byte[]]@(5,$Command,0,3,$domain.Length)+$domain+[byte[]]@(1,187);$s.Write($request,0,$request.Length)
        $reply=Read-Exact $s 10;if($reply[1] -ne 0){throw ('SOCKS reject '+$reply[1])}
        [pscustomobject]@{Client=$c;Stream=$s;Marker=[char]$s.ReadByte()}
    }catch{$c.Dispose();throw}
}
function Assert-Echo {param($Connection,[string]$Text,[string]$Label);$bytes=[Text.Encoding]::UTF8.GetBytes($Text);$Connection.Stream.Write($bytes,0,$bytes.Length);$read=Read-Exact $Connection.Stream $bytes.Length;Assert-Test ([Text.Encoding]::UTF8.GetString($read) -ceq $Text) $Label}
function New-Binding {param($Backend,[int]$Slot,[string]$Lane,[string]$Id,[string]$Identity='fixture')
    $b=New-Object TCProviderRelayBinding;$b.Slot=$Slot;$b.Lane=$Lane;$b.ProviderId=$Id;$b.Port=$Backend.Port;$b.OwnerPid=$Backend.Process.Id;$b.OwnerStartedTicks=$Backend.Process.StartTime.ToUniversalTime().Ticks;$b.OwnerPath=$Backend.Exe;$b.Identity=$Identity;$b
}
try{
    $null=[IO.Directory]::CreateDirectory($work)
    . (Join-Path $source 'runtime\TradeChannel.Provider.ps1')
    Set-TCRelayPrivateAcl $work
    $package=Join-Path $work 'package';$runtimePackage=Join-Path $package 'runtime';$null=[IO.Directory]::CreateDirectory($runtimePackage);Set-TCRelayPrivateAcl $package;Set-TCRelayPrivateAcl $runtimePackage
    $assemblyInfo=Join-Path $work 'AssemblyInfo.cs';[IO.File]::WriteAllText($assemblyInfo,'[assembly:System.Reflection.AssemblyVersion("0.18.0.0")]')
    $csc=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe';$dll=Join-Path $runtimePackage 'TradeChannelProviderRelay.dll'
    & $csc /nologo /target:library /platform:x64 /optimize+ ('/out:'+$dll) (Join-Path $source 'runtime\TradeChannelProviderRelay.cs') $assemblyInfo
    Assert-Test ($LASTEXITCODE -eq 0) 'C# 5 / .NET Framework x64 component compiles'
    Write-TestJson (Join-Path $package 'version.json') @{Version='0.18.0'}
    [IO.File]::WriteAllText((Join-Path $package 'package.sha256'),((Get-FileHash -LiteralPath $dll).Hash+'|runtime\TradeChannelProviderRelay.dll'))
    Initialize-TCProviderRelayComponent -PackageRoot $package
    Assert-Test ([bool]('TCProviderRelayHost' -as [type])) 'Production hash/version/ACL loader accepts protected packaged component'
    $receiptPath=Join-Path $package 'package.sha256';$goodReceipt=[IO.File]::ReadAllText($receiptPath)
    [IO.File]::WriteAllText($receiptPath,(('0'*64)+'|runtime\TradeChannelProviderRelay.dll'))
    Expect-Failure {Initialize-TCProviderRelayComponent -PackageRoot $package} 'Tampered component receipt rejected even when assembly is already loaded'
    [IO.File]::WriteAllText($receiptPath,$goodReceipt)
    Write-TestJson (Join-Path $package 'version.json') @{Version='0.18.1'}
    Expect-Failure {Initialize-TCProviderRelayComponent -PackageRoot $package} 'Component from another package version rejected'
    Write-TestJson (Join-Path $package 'version.json') @{Version='0.18.0'}
    $acl=Get-Acl -LiteralPath $package;$world=New-Object Security.Principal.SecurityIdentifier('S-1-1-0');$rule=New-Object Security.AccessControl.FileSystemAccessRule($world,[Security.AccessControl.FileSystemRights]::Write,[Security.AccessControl.AccessControlType]::Allow);$acl.AddAccessRule($rule);Set-Acl -LiteralPath $package -AclObject $acl
    Expect-Failure {Initialize-TCProviderRelayComponent -PackageRoot $package} 'Package writable by another identity is rejected'
    Set-TCRelayPrivateAcl $package
    $clientA=Join-Path $work 'clientA';$clientB=Join-Path $work 'clientB';$null=[IO.Directory]::CreateDirectory($clientA);$null=[IO.Directory]::CreateDirectory($clientB)
    $exeA=Join-Path $clientA 'FixtureA.exe';$exeB=Join-Path $clientB 'FixtureB.exe'
    & $csc /nologo /target:exe /platform:x64 ('/out:'+$exeA) (Join-Path $PSScriptRoot 'ProviderRelayFixture.cs');Assert-Test ($LASTEXITCODE -eq 0) 'Synthetic SOCKS backend compiles'
    [IO.File]::Copy($exeA,$exeB)
    $a=Start-Backend $exeA 'A';$b=Start-Backend $exeB 'B';$http=Start-Backend $exeB 'HTTP'
    $idA=[guid]::NewGuid().ToString('D');$idB=[guid]::NewGuid().ToString('D')
    $ports=[int[]](17901..17908)
    Assert-Test (@([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()|Where-Object {$_.Port -in $ports}).Count -eq 0) 'Fixed ports are free; no existing listener is stopped'
    $hostObject=New-Object TCProviderRelayHost([guid]::NewGuid().ToString('N'),$ports,[int[]]@(17890,17891))
    Assert-Test (@([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()|Where-Object {$_.Port -in $ports -and $_.Address.ToString() -ceq '127.0.0.1'}).Count -eq 8) 'All four daily/trade slots reserve IPv4 loopback only'
    Expect-Failure {Open-FixtureSocks 17901} 'Unassigned slot fails closed'
    $bindings=[TCProviderRelayBinding[]]@((New-Binding $a 1 daily $idA),(New-Binding $a 1 trade $idA))
    $hostObject.Replace($bindings,'empty','one',[string[]]@())
    $connection=Open-FixtureSocks 17902;Assert-Test ($connection.Marker -eq 'A') 'Trade slot forwards to its verified upstream';Assert-Echo $connection 'trade-before' 'Established trading connection works'
    $next=[TCProviderRelayBinding[]]@($bindings+(New-Binding $b 2 daily $idB)+(New-Binding $b 2 trade $idB))
    $hostObject.Replace($next,'one','two',[string[]]@('provider-trade'))
    Assert-Echo $connection 'trade-after-add' 'Adding another provider preserves established trading connection'
    $second=Open-FixtureSocks 17903;Assert-Test ($second.Marker -eq 'B') 'New daily slot hot-forwards to second provider';$second.Client.Dispose()
    $changed=New-Binding $b 1 trade $idA
    Expect-Failure {$hostObject.Replace([TCProviderRelayBinding[]]@($bindings[0],$changed),'two','bad',[string[]]@('provider-trade'))} 'Selected trade port/process change rejected atomically'
    Assert-Test ($hostObject.Revision -ceq 'two') 'Failed mapping leaves revision intact';Assert-Echo $connection 'still-A' 'Failed change preserves original live socket'
    $bad=New-Binding $a 3 daily ([guid]::NewGuid().ToString('D'));$bad.Port=17901
    Expect-Failure {$hostObject.Validate([TCProviderRelayBinding[]]@($bad))} 'Relay self-reference reserved port rejected'
    $bad=New-Binding $a 3 daily ([guid]::NewGuid().ToString('D'));$bad.OwnerPath=$exeB
    Expect-Failure {$hostObject.Validate([TCProviderRelayBinding[]]@($bad))} 'Wrong executable ownership rejected'
    $bad=New-Binding $http 3 daily ([guid]::NewGuid().ToString('D'))
    Expect-Failure {$hostObject.Validate([TCProviderRelayBinding[]]@($bad))} 'HTTP listener cannot masquerade as SOCKS'
    Expect-Failure {Open-FixtureSocks 17901 '127.0.0.1'} 'SOCKS CONNECT cannot recurse through loopback destinations'
    Expect-Failure {Open-FixtureSocks 17901 'fixture.invalid' 3} 'Unsupported SOCKS UDP ASSOCIATE fails explicitly'
    $connection.Client.Client.Shutdown([Net.Sockets.SocketShutdown]::Send);Assert-Test ($connection.Stream.ReadByte() -eq -1) 'Half-close drains response and closes correctly';$connection.Client.Dispose()
    $b.Process.Kill();$null=$b.Process.WaitForExit(3000);Start-Sleep -Milliseconds 1500
    Assert-Test (@($hostObject.Snapshot()|Where-Object {$_.Slot -eq 2 -and $_.Healthy}).Count -eq 0) 'Dead upstream mappings are invalidated without fallback'
    Expect-Failure {Open-FixtureSocks 17903} 'Dead upstream slot cannot accept new traffic'
    $hostObject.Dispose();$hostObject=$null
    $conflict=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,17905);$conflict.Start()
    try{Expect-Failure {New-Object TCProviderRelayHost([guid]::NewGuid().ToString('N'),$ports,[int[]]@())} 'One listen conflict fails the whole host';Assert-Test (@([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()|Where-Object {$_.Port -in @(17901,17902,17903,17904,17906,17907,17908)}).Count -eq 0) 'Partial listener reservation rolls back'}finally{$conflict.Stop()}

    # End-to-end bridge -> request journal -> supervisor host -> ACK, with a real
    # sing-box process configured ONLY with a loopback mixed listener, no TUN.
    $root=Join-Path $work 'state';$null=[IO.Directory]::CreateDirectory($root)
    $storeModule=Import-Module (Join-Path $source 'NodeStore.psm1') -Force -PassThru -DisableNameChecking
    $null=Initialize-TCStore -Root (Join-Path $root 'Product')
    $contract=Get-TCProviderRelayContract $root;$null=Initialize-TCRelayDirectory $root
    Write-TCRelayJson $contract.RouteRuleSetPath @{version=3;rules=@()};Write-TCRelayJson $contract.DnsRuleSetPath @{version=3;rules=@()}
    $controlProbe=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0);$controlProbe.Start();$controlPort=$controlProbe.LocalEndpoint.Port;$controlProbe.Stop()
    $socksProbe=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0);$socksProbe.Start();$probePort=$socksProbe.LocalEndpoint.Port;$socksProbe.Stop()
    $policy=& $storeModule {param($Relay);New-TCRoutingPolicy -TradePrograms @() -TradeDomains @() -AuxDnsDomains @() -Providers @() -BootstrapDomains @() -EndpointAddress '192.0.2.20' -EndpointIsIP $true -DirectDns '127.0.0.1' -ProviderRelay $Relay} $contract
    $config=@{log=@{level='warn'};dns=$policy.dns;inbounds=@(@{type='socks';tag='fixture';listen='127.0.0.1';listen_port=$probePort});outbounds=@(@{type='socks';tag='hk';server='127.0.0.1';server_port=$a.Port;version='5'})+@($policy.outbounds);route=$policy.route;experimental=@{clash_api=@{external_controller=('127.0.0.1:'+$controlPort);secret='fixture-only';default_mode='rule'}}}
    $cfgPath=Join-Path $root 'loopback-engine.json';Write-TestJson $cfgPath $config
    $manifest=@{ProviderRelay=$contract;Providers=@();CandidatePath=$cfgPath;CandidateSHA256=(Get-FileHash -LiteralPath $cfgPath).Hash;EnginePath=(Join-Path $source 'assets\sing-box.exe');ControlPort=$controlPort;ProbePort=$probePort;TradeProgramPaths=@();SyntaxValidated=$true;DeploymentApproved=$true}
    Write-TestJson (Join-Path $root 'manifest.json') $manifest;Write-TestJson (Join-Path $root 'deployment.json') @{ManifestPath=(Join-Path $root 'manifest.json')}
    $runner=Start-Process -FilePath (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',('"'+(Join-Path $PSScriptRoot 'ProviderRelayFixture.ps1')+'"'),'-Root',('"'+$root+'"'),'-PackageRoot',('"'+$package+'"'),'-SourceRoot',('"'+$source+'"')) -WindowStyle Hidden -PassThru
    $processes.Add($runner);Wait-File (Join-Path $root 'fixture-ready') $runner
    $runtime=Read-TestJson (Join-Path $root 'runtime.json');$fixtureEngine=Get-Process -Id $runtime.EnginePid;$processes.Add($fixtureEngine);$engineBirth=$fixtureEngine.StartTime.ToUniversalTime().Ticks
    $bridge=Import-Module (Join-Path $source 'ProviderBridge.psm1') -Force -PassThru -DisableNameChecking
    # This is the only environmental observation replaced in the caller. All
    # path/PID/listener, package, files, request/ACK and TCP operations are real.
    & $bridge {function script:Get-TCForeignTunnel {$null}}
    $request=[pscustomobject]@{Action='ProviderConnect';Kind='custom';Name='Fixture A';Directory=$clientA;ProgramPaths=@($exeA);DailyPort=$a.Port;TradePort=$a.Port;BootstrapDomains=@('upstream.fixture.invalid')}
    $connected=Invoke-TCProviderRequest -Root $root -Request $request
    Assert-Test ($connected.Applied -and $connected.HotApplied -and -not $connected.TradingExitChanged) ('Public one-key discovery/registration/check/apply ACK: '+$connected.Code)
    $health=& $bridge {param($Manifest,$Id);Get-TCProviderHealth -Manifest $Manifest -ProviderId $Id} ([pscustomobject]$manifest) $connected.Id
    Assert-Test ($health.Healthy -and $health.Port -eq 17901 -and $health.UpstreamPort -eq $a.Port -and $health.OwnerIds[0] -eq $a.Process.Id -and $health.RelayOwnerId -eq $runner.Id) 'Runtime health proves both supervisor listener and original upstream identity'
    $target=& $bridge {param($Manifest,$Id);Resolve-TCProviderTarget $Manifest $Id -ForTrade} ([pscustomobject]$manifest) $connected.Id
    Assert-Test ($target.Port -eq 17902 -and $target.UpstreamPort -eq $a.Port -and $target.Tag -ceq 'provider-trade') 'Existing runtime target API resolves dedicated fixed trade entry and retains policy upstream port'
    Assert-Test ($fixtureEngine.Id -eq $runtime.EnginePid -and -not $fixtureEngine.HasExited -and $fixtureEngine.StartTime.ToUniversalTime().Ticks -eq $engineBirth) 'One-key apply does not restart trading engine'
    $sets=Read-TestJson $contract.DnsRuleSetPath;Assert-Test (@($sets.rules|Where-Object {@($_.domain) -contains 'upstream.fixture.invalid'}).Count -eq 1) 'Bootstrap DNS has dynamic exact-domain direct rule'
    $sets=Read-TestJson $contract.RouteRuleSetPath;Assert-Test (@($sets.rules|Where-Object {@($_.process_path) -contains $exeA}).Count -eq 1) 'Real provider process path enters dynamic direct rule'
    $mapped=Open-FixtureSocks 17901;Assert-Test ($mapped.Marker -eq 'A') 'One-key mapping is actually usable';$mapped.Client.Dispose()
    $hashBefore=(Get-FileHash -LiteralPath $cfgPath).Hash
    $repeated=Invoke-TCProviderRequest -Root $root -Request ([pscustomobject]@{Action='ProviderConnect';Id=$connected.Id})
    Assert-Test ($repeated.Applied -and $repeated.Id -ceq $connected.Id) 'Retry resumes existing ID without duplicate registration'
    Assert-Test ((Read-TestJson (Join-Path $root 'Product\providers.json')).Providers.Count -eq 1 -and (Get-FileHash -LiteralPath $cfgPath).Hash -ceq $hashBefore) 'Hot apply leaves engine config and registry cardinality unchanged'
    $b=Start-Backend $exeB 'B'
    $registered=Invoke-TCProviderRequest -Root $root -Request ([pscustomobject]@{Action='ProviderRegister';Kind='custom';Name='Fixture B';Directory=$clientB;ProgramPaths=@($exeB);DailyPort=$b.Port;TradePort=$b.Port;BootstrapDomains=@('second.fixture.invalid')})
    [IO.File]::WriteAllText((Join-Path $root 'fixture-forwarding-fail'),'1')
    $before=Read-TestJson $contract.StatePath;$routeHash=(Get-FileHash -LiteralPath $contract.RouteRuleSetPath).Hash;$dnsHash=(Get-FileHash -LiteralPath $contract.DnsRuleSetPath).Hash
    $failed=Invoke-TCProviderRequest -Root $root -Request ([pscustomobject]@{Action='ProviderApply';Id=$registered.Id})
    Assert-Test (-not $failed.Applied -and $failed.Code -eq 'ProviderRelayForwardingFailed') 'Forwarding failure is never reported as applied'
    $after=Read-TestJson $contract.StatePath
    Assert-Test ($after.Revision -ceq $before.Revision -and (Get-FileHash -LiteralPath $contract.RouteRuleSetPath).Hash -ceq $routeHash -and (Get-FileHash -LiteralPath $contract.DnsRuleSetPath).Hash -ceq $dnsHash) 'Failure restores previous mappings and both bypass files atomically'
    [IO.File]::Delete((Join-Path $root 'fixture-forwarding-fail'))
    $secondResult=Invoke-TCProviderRequest -Root $root -Request ([pscustomobject]@{Action='ProviderApply';Id=$registered.Id})
    Assert-Test $secondResult.Applied 'Second provider retries and hot-applies successfully'
    Write-TestJson (Join-Path $root 'fixture-protected.json') @{Tags=@('provider-trade')}
    $stored=Read-TestJson (Join-Path $root 'Product\providers.json');$stored.Providers[0].bootstrapDomains=@('changed.fixture.invalid');Write-TestJson (Join-Path $root 'Product\providers.json') $stored
    $immutable=Invoke-TCProviderRequest -Root $root -Request ([pscustomobject]@{Action='ProviderApply';Id=$connected.Id})
    Assert-Test (-not $immutable.Applied -and $immutable.Code -eq 'SelectedProviderImmutable') ('Actual supervisor rejects selected provider DNS/identity mutation: '+($immutable|ConvertTo-Json -Compress))
    $stored.Providers[0].bootstrapDomains=@('upstream.fixture.invalid');Write-TestJson (Join-Path $root 'Product\providers.json') $stored
    Write-TestJson (Join-Path $root 'fixture-protected.json') @{Tags=@('hk','direct')}
    $removed=Invoke-TCProviderRequest -Root $root -Request ([pscustomobject]@{Action='ProviderRemove';Id=$registered.Id})
    Assert-Test $removed.Removed 'Removal withdraws the live mapping before freeing slot'
    Expect-Failure {Open-FixtureSocks 17903} 'Removed slot has no stale upstream mapping'
    $dns=Read-TestJson $contract.DnsRuleSetPath;Assert-Test ((ConvertTo-Json $dns -Depth 10) -notmatch 'second.fixture.invalid') 'Removed provider bootstrap bypass is retired'
    # Exercise the exact local source rule-set + atomic replacement mechanism
    # with a second real sing-box that has loopback sockets and synthetic SOCKS
    # outbounds only. No DNS request or external TCP connection can occur.
    $watchPortProbe=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0);$watchPortProbe.Start();$watchPort=$watchPortProbe.LocalEndpoint.Port;$watchPortProbe.Stop()
    $watchSet=Join-Path $root 'fixture-watch.json';Write-TCRelayJson $watchSet @{version=3;rules=@()}
    $watchConfig=@{log=@{level='warn'};inbounds=@(@{type='socks';tag='fixture';listen='127.0.0.1';listen_port=$watchPort});outbounds=@(@{type='socks';tag='a';server='127.0.0.1';server_port=$a.Port;version='5'},@{type='socks';tag='b';server='127.0.0.1';server_port=$b.Port;version='5'});route=@{rules=@(@{rule_set=@('watch');action='route';outbound='b'});rule_set=@(@{type='local';tag='watch';format='source';path=$watchSet});final='a'}}
    $watchConfigPath=Join-Path $root 'fixture-watch-config.json';Write-TestJson $watchConfigPath $watchConfig
    $watchEngine=Start-Process -FilePath $manifest.EnginePath -ArgumentList @('run','-c',('"'+$watchConfigPath+'"')) -WindowStyle Hidden -PassThru -RedirectStandardError (Join-Path $root 'fixture-watch.log') -RedirectStandardOutput (Join-Path $root 'fixture-watch.out');$processes.Add($watchEngine)
    $watchReady=[DateTime]::UtcNow.AddSeconds(5);$observed=$null
    do{try{$observed=Open-FixtureSocks $watchPort}catch{Start-Sleep -Milliseconds 100}}while(-not $observed -and [DateTime]::UtcNow -lt $watchReady)
    Assert-Test ($observed -and $observed.Marker -eq 'A') 'Real sing-box starts with empty watched source';$observed.Client.Dispose()
    $watchPid=$watchEngine.Id;$watchBirth=$watchEngine.StartTime.ToUniversalTime().Ticks
    $timer=[Diagnostics.Stopwatch]::StartNew();Write-TCRelayJson $watchSet @{version=3;rules=@(@{domain=@('fixture.invalid')})}
    do{$observed=Open-FixtureSocks $watchPort;$marker=$observed.Marker;$observed.Client.Dispose();if($marker -ne 'B'){Start-Sleep -Milliseconds 50}}while($marker -ne 'B' -and $timer.ElapsedMilliseconds -lt 5000)
    $reloadMilliseconds=$timer.ElapsedMilliseconds;$timer.Stop()
    Assert-Test ($marker -eq 'B') 'Atomic source replacement changes live engine routing without reload/restart'
    Write-TCRelayJson $watchSet @{version=3;rules=@()};$watchDeadline=[DateTime]::UtcNow.AddSeconds(5)
    do{$observed=Open-FixtureSocks $watchPort;$marker=$observed.Marker;$observed.Client.Dispose();if($marker -ne 'A'){Start-Sleep -Milliseconds 50}}while($marker -ne 'A' -and [DateTime]::UtcNow -lt $watchDeadline)
    Assert-Test ($marker -eq 'A' -and -not $watchEngine.HasExited -and $watchEngine.Id -eq $watchPid -and $watchEngine.StartTime.ToUniversalTime().Ticks -eq $watchBirth) 'Removing watched source rules restores prior routing with the same engine'
    $watchEngine.Kill();$null=$watchEngine.WaitForExit(5000)
    $stateBeforeCrash=Read-TestJson $contract.StatePath
    $runner.Kill();$null=$runner.WaitForExit(5000);Start-Sleep -Milliseconds 300
    Assert-Test (@([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()|Where-Object {$_.Port -in $ports}).Count -eq 0) 'Abrupt supervisor death closes every relay listener; no child survives'
    Assert-Test (-not (Get-TCProviderRelayLiveState ([pscustomobject]$manifest))) 'Stale Running mapping file cannot authorize a dead supervisor'
    $fixtureEngine.Kill();$null=$fixtureEngine.WaitForExit(5000)
    $appliedPath=Join-Path $root 'providers\relay-applied.json';$journalPath=Join-Path $root 'providers\relay-transaction.json';$committed=Read-TestJson $appliedPath
    Write-TestJson $journalPath @{Version=1;Phase='Prepared';BeforeApplied=$committed}
    Write-TestJson $appliedPath @{Version=1;CandidatePath=$manifest.CandidatePath;CandidateSHA256=$manifest.CandidateSHA256;Revision='interrupted';Records=@()}
    Repair-TCProviderRelayTransaction $root
    Assert-Test ((Read-TestJson $appliedPath).Revision -ceq $committed.Revision -and -not [IO.File]::Exists($journalPath)) 'Interrupted apply recovers last committed desired mapping before restart'
    [IO.File]::Delete((Join-Path $root 'fixture-ready'))
    $runner=Start-Process -FilePath (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',('"'+(Join-Path $PSScriptRoot 'ProviderRelayFixture.ps1')+'"'),'-Root',('"'+$root+'"'),'-PackageRoot',('"'+$package+'"'),'-SourceRoot',('"'+$source+'"')) -WindowStyle Hidden -PassThru
    $processes.Add($runner);Wait-File (Join-Path $root 'fixture-ready') $runner
    $runtime=Read-TestJson (Join-Path $root 'runtime.json');$fixtureEngine=Get-Process -Id $runtime.EnginePid;$processes.Add($fixtureEngine)
    $ackDeadline=[DateTime]::UtcNow.AddSeconds(5)
    do{$restarted=Read-TestJson $contract.StatePath;if(-not $restarted.LastRequest){Start-Sleep -Milliseconds 50}}while(-not $restarted.LastRequest -and [DateTime]::UtcNow -lt $ackDeadline)
    Assert-Test ($restarted.SessionId -cne $stateBeforeCrash.SessionId -and $restarted.LastRequest.Code -ceq 'ProviderRelayRequestStale' -and -not $restarted.LastRequest.Succeeded) 'Old-session request cannot replay on a new supervisor'
    $restored=Open-FixtureSocks 17901;Assert-Test ($restored.Marker -eq 'A') 'Restart validates ownership and restores only committed mapping';$restored.Client.Dispose()
    [IO.File]::WriteAllText((Join-Path $root 'fixture-stop'),'1');Assert-Test ($runner.WaitForExit(10000)) 'Graceful fixture supervisor exits within bounded cleanup'
    Assert-Test (@([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()|Where-Object {$_.Port -in $ports}).Count -eq 0 -and -not (Read-TestJson $contract.StatePath).Active -and (Read-TestJson $contract.DnsRuleSetPath).rules.Count -eq 0) 'Graceful shutdown retires live state, sockets and DNS bypass'
    $legacy=$manifest.Clone();$legacy.Remove('ProviderRelay');Write-TestJson (Join-Path $root 'manifest.json') $legacy
    $old=Invoke-TCProviderRequest -Root $root -Request ([pscustomobject]@{Action='ProviderConnect';Id=$connected.Id})
    $oldAgain=Invoke-TCProviderRequest -Root $root -Request ([pscustomobject]@{Action='ProviderConnect';Id=$connected.Id})
    Assert-Test ($old.NeedsUpgrade -and -not $old.Applied -and -not $old.HotApplied -and $old.MigrationNoticeFirstSeen -and -not $oldAgain.MigrationNoticeFirstSeen) 'Legacy manifest requests one controlled migration notice and never claims hot apply'
    $report=[pscustomobject]@{Passed=$true;Checks=$checks.Count;Cases=$checks.ToArray();PowerShell=$PSVersionTable.PSVersion.ToString();Runtime=[Environment]::Version.ToString();WatcherReloadMilliseconds=$reloadMilliseconds;Scope='Temporary roots, loopback sockets, synthetic SOCKS forwarding, no TUN/WFP/real proxy mutations';RealNetworkChanges=0}
    if($ReportPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($true)))}
    $report|Select-Object Passed,Checks,PowerShell,Scope
}catch{
    $testFailure=$_
    Write-Output ('FAILED after '+$checks.Count+' checks: '+$_.Exception.Message)
    Write-Output $_.ScriptStackTrace
    if($root -and [IO.Directory]::Exists($root)){
        foreach($file in @('fixture-error.txt','fixture-engine.log')){$p=Join-Path $root $file;if([IO.File]::Exists($p)){try{$stream=[IO.File]::Open($p,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete));try{$reader=New-Object IO.StreamReader($stream);try{Write-Output ($file+': '+$reader.ReadToEnd())}finally{$reader.Dispose()}}finally{$stream.Dispose()}}catch{Write-Output ($file+': diagnostic file unavailable')}}}
        if($runner){Write-Output ('Fixture supervisor exited: '+$runner.HasExited)}
        if($fixtureEngine){Write-Output ('Fixture engine exited: '+$fixtureEngine.HasExited)}
    }
    throw $testFailure
}finally{
    if($hostObject){$hostObject.Dispose()}
    foreach($p in $processes){try{if(-not $p.HasExited){$p.Kill();$null=$p.WaitForExit(5000)};$p.Dispose()}catch{}}
    $full=[IO.Path]::GetFullPath($work);$base=[IO.Path]::GetFullPath([Environment]::GetFolderPath('LocalApplicationData')).TrimEnd('\')+'\'
    if(-not $full.StartsWith($base,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notmatch '^TCProviderRelayTests-[a-f0-9]{32}$'){throw 'Fixture cleanup rejected'}
    # This process loaded the packaged DLL; Windows releases that file only on
    # process exit. A bounded helper removes only this verified disposable root.
    $cleanup='$ErrorActionPreference=''SilentlyContinue''; $p=Get-Process -Id '+$PID+'; if($p){$null=$p.WaitForExit(30000)}; $target='''+$full.Replace("'","''")+'''; $base='''+$base.Replace("'","''")+'''; if([IO.Path]::GetFullPath($target).StartsWith($base,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($target) -match ''^TCProviderRelayTests-[a-f0-9]{32}$''){Remove-Item -LiteralPath $target -Recurse -Force}'
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cleanup))
    $null=Start-Process -FilePath (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList @('-NoProfile','-NonInteractive','-EncodedCommand',$encoded) -WindowStyle Hidden
}
