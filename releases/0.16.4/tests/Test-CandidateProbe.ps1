#requires -Version 5.1
# Disposable keys/configs; fake engine and HTTP replies; real syntax check only.
[CmdletBinding()]param()
$ErrorActionPreference='Stop';Set-StrictMode -Version 2
if($PSVersionTable.PSEdition -ne 'Core'){$env:PSModulePath=Join-Path $PSHOME 'Modules'}
$package=Split-Path $PSScriptRoot -Parent;$nodes=Import-Module (Join-Path $package 'NodeStore.psm1') -Force -PassThru -DisableNameChecking
$probe=Import-Module (Join-Path $package 'CandidateProbe.psm1') -Force -PassThru -DisableNameChecking
$work=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('TC-CandidateProbe-'+[guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($work);$script:Checks=0
function Check {param([bool]$Ok,[string]$Label)if(-not $Ok){throw ('Candidate probe regression: '+$Label)};$script:Checks++}
function ReadJson {param($p)[IO.File]::ReadAllText($p)|ConvertFrom-Json}
function WriteJson {param($p,$v)[IO.File]::WriteAllText($p,($v|ConvertTo-Json -Depth 40),(New-Object Text.UTF8Encoding($false)))}
try{
    if($PSVersionTable.PSEdition -eq 'Core'){
        # NodeStore's unrelated v1 reader requires Int32; PS7 JSON emits Int64.
        # Normalize only disposable test JSON inside its private reader.
        & $nodes {function script:Read-TCJson {param([string]$Path)$v=ConvertFrom-Json -InputObject (Read-TCBoundedText $Path) -DateKind String;if($v.PSObject.Properties['schemaVersion'] -and $v.schemaVersion -is [long]){$v.schemaVersion=[int]$v.schemaVersion};$v}}
    }
    & $nodes {$script:ProbeNative=${function:Invoke-TCProcess};$script:TCNativeRunner={param($FilePath,$ArgumentList,$InputText,$TimeoutMilliseconds)if($ArgumentList[0] -notin @('check','pubkey')){throw 'Actual engine launch forbidden.'};& $script:ProbeNative -FilePath $FilePath -ArgumentList $ArgumentList -InputText $InputText -TimeoutMilliseconds $TimeoutMilliseconds}}
    & $probe {
        $script:Starts=0;$script:PortRetry=$false;$script:HttpFailure=$false;$script:ReplyIP='192.0.2.20';$script:Configs=@();$script:Kills=0;$script:HttpCalls=0;$script:FailAt=0;$script:FlipExitAt=0;$script:KillFails=$false;$script:Slow=$false;$script:Drift=$false;$script:DriftConfig=$null;$script:Profile=$null;$script:ComparisonProfiles=$null;$script:Cancel=$false
        $script:ProcessStart=[DateTime]::UtcNow
        $script:ObservedProtocol='Tcp';$script:EtwUnavailable=$false;$script:TraceStopFails=$false;$script:TraceReceiptSeen=$false
        $script:CancelMarkerAt=0;$script:CancelMarkerPath='';$script:CancelMarkerAttempt='';$script:CancelMarkerOnKill=$false;$script:SocketStops=0;$script:TraceStops=0
        $script:Context=[pscustomobject]@{Status='Available';Fingerprint=('A'*64);Interfaces=@([pscustomobject]@{Index=7;Id='fixture-7';Name='Ethernet Fixture';Status='Up';Type='Ethernet';Hardware=$true;Metric=10;Addresses=@([pscustomobject]@{Address='192.0.2.2';Family='InterNetwork';PrefixLength=24;State='Preferred'});Gateways=@('192.0.2.1');DnsServers=@('192.168.100.1')});Routes=@([pscustomobject]@{InterfaceIndex=7;DestinationPrefix='0.0.0.0/0';NextHop='192.0.2.1';RouteMetric=10;AddressFamily='IPv4'});ObservedAt=[DateTimeOffset]::UtcNow.ToString('o')}
        function script:Get-TCCandidateNetworkContext {param($Binding)
            $copy=$script:Context|ConvertTo-Json -Depth 20|ConvertFrom-Json
            if($script:Drift -and $script:HttpCalls -gt 0){$copy.Routes[0].NextHop='192.0.2.254';$copy.Interfaces[0].Gateways=@('192.0.2.254')}
            & $script:TCProbePathModule {param($raw,$b)$script:CandidateNetworkFixture=$raw;function script:Read-TCProbeNetworkState {$script:CandidateNetworkFixture};Get-TCProbeNetworkContext -Binding $b} $copy $Binding
        }
        function script:Get-TCCandidateProbeProfile {param($Root,$NodeId,$ProfileId)if($script:ComparisonProfiles){@($script:ComparisonProfiles|Where-Object {$_.Id -ceq $ProfileId})[0]}else{$script:Profile}}
        function script:Start-TCCandidateSocketWatch {param($ProcessId,$Binding,$TraceIdentity,$RunDirectory)
            $script:ObservedProtocol=if($Binding -and $Binding.Protocol -eq 'Udp'){'Udp'}else{'Tcp'}
            if($TraceIdentity){$r=Read-TCCandidateProbeJson (Join-Path $RunDirectory 'ownership.json');$script:TraceReceiptSeen=($r.TraceGuid -ceq $TraceIdentity -and $r.TraceState -eq 'Starting' -and $r.ConfigHash -match '^[A-F0-9]{64}$')}
            [pscustomobject]@{Id=$ProcessId;Identity=$TraceIdentity}
        }
        function script:Stop-TCCandidateOwnedTrace {param($Identity)$script:TraceStops++;if($script:TraceStopFails){throw 'Fixture trace cleanup failed'}}
        function script:Stop-TCCandidateSocketWatch {param($Observer)
            $script:SocketStops++
            if($script:ObservedProtocol -eq 'Udp'){
                if($script:TraceStopFails){throw 'Fixture trace cleanup failed'}
                return [pscustomobject]@{Status=$(if($script:EtwUnavailable){'Unavailable'}else{'Available'});Protocol='Udp';ProcessId=9876;ProcessStartTicks=$script:ProcessStart.ToUniversalTime().Ticks;Reads=3;Errors=0;Overflow=$false;NetworkChanges=0;TraceEvidence=[pscustomobject]@{Started=(-not $script:EtwUnavailable);CleanupComplete=$true;SessionAbsent=$true;GuardCompleted=$true;MatchedEvents=12;EventsLost=0;BuffersLost=0;SessionGuid=$Observer.Identity};Rows=@([pscustomobject]@{ProcessId=9876;LocalAddress='192.0.2.2';LocalPort=55000;RemoteAddress='192.0.2.10';RemotePort=51820;AddressFamily='IPv4';State=0;Source='WindowsKernelNetworkUdpSendV0'})}
            }
            [pscustomobject]@{Status='Available';ProcessId=9876;ProcessStartTicks=$script:ProcessStart.ToUniversalTime().Ticks;Reads=3;Errors=0;Overflow=$false;NetworkChanges=0;Rows=@([pscustomobject]@{ProcessId=9876;LocalAddress='192.0.2.2';LocalPort=55000;RemoteAddress='192.0.2.10';RemotePort=443;AddressFamily='IPv4';State=5;Source='GetExtendedTcpTable'})}
        }
        function script:Get-CimInstance {param($ClassName,$Filter,$ErrorAction)@()}
        function script:Get-TCCandidateProbePort {41001+$script:Starts}
        function script:Start-TCBoundedEngineProcess {
            param($Root,$Executable,$Arguments,$SessionId,$MaxBytes)
            $script:Starts++;$path=($Arguments -replace '^run -c "','' -replace '"$','');$script:Configs+=,(Read-TCCandidateProbeJson $path)
            $p=[pscustomobject]@{Id=9876;HasExited=($script:PortRetry -and $script:Starts -eq 1);LogPath='fixture';StartTime=$script:ProcessStart}
            $p|Add-Member ScriptMethod Kill {if($script:KillFails){throw 'Fake stop failure'};$script:Kills++;if($script:CancelMarkerOnKill){[IO.File]::WriteAllText($script:CancelMarkerPath,(@{AttemptId=$script:CancelMarkerAttempt}|ConvertTo-Json -Compress),(New-Object Text.UTF8Encoding($false)))};$this.HasExited=$true};$p|Add-Member ScriptMethod WaitForExit {param($ms)$this.HasExited};$p|Add-Member ScriptMethod Dispose {};return $p
        }
        function script:Test-TCCandidateProbeListener {param($Port,$ProcessId)$true}
        function script:Invoke-TCCandidateProbeHttp {
            param($Port,$User,$Secret,$Target,$TimeoutSeconds)
            if($script:Cancel){throw (New-Object OperationCanceledException)}
            $script:HttpCalls++;$fail=($script:HttpFailure -or $script:HttpCalls -eq $script:FailAt)
            if($script:CancelMarkerAt -gt 0 -and $script:HttpCalls -eq $script:CancelMarkerAt){[IO.File]::WriteAllText($script:CancelMarkerPath,(@{AttemptId=$script:CancelMarkerAttempt}|ConvertTo-Json -Compress),(New-Object Text.UTF8Encoding($false)))}
            if($script:Slow){Start-Sleep -Seconds $TimeoutSeconds;$fail=$true}
            if($script:DriftConfig){[IO.File]::AppendAllText($script:DriftConfig,' ');$script:DriftConfig=$null}
            [pscustomobject]@{Name=$Target.Name;Status=$(if($fail){'Failed'}elseif($Target.Name -eq 'ChatGPTWeb'){'UserVerificationRequired'}else{'Passed'});Code=$(if($script:Slow){'ProbeTimeout'}elseif($Target.Name -eq 'ChatGPTWeb'){'BrowserChallenge'}else{'HttpsReached'});HttpStatus=$(if($Target.Name -eq 'ChatGPTWeb'){403}else{200});TlsVerified=(-not $fail);ObservedExitIPv4=$(if($Target.Trace){if($script:HttpCalls -eq $script:FlipExitAt){'192.0.2.21'}else{$script:ReplyIP}}else{$null});DurationMs=$(if($script:Slow){$TimeoutSeconds*1000}else{1});TargetHost=([Uri]$Target.Url).Host;Source='AuthenticatedCandidateProxy'}
        }
    }
    $wg=Join-Path $package 'assets\wg.exe';$engine=Join-Path $package 'assets\sing-box.exe';$private=(& $wg genkey).Trim();$serverPrivate=(& $wg genkey).Trim();$pub=& $nodes {param($e,$k)Invoke-TCNative -FilePath $e -ArgumentList @('pubkey') -InputText $k} $wg $serverPrivate
    $conf=Join-Path $work 'client.conf';[IO.File]::WriteAllText($conf,("[Interface]`nPrivateKey = $private`nAddress = 10.99.0.2/24`n[Peer]`nPublicKey = $($pub.StandardOutput.Trim())`nEndpoint = 192.0.2.10:51820`nAllowedIPs = 0.0.0.0/0`n"),(New-Object Text.UTF8Encoding($false)))
    $node=Import-TCWireGuard -Root (Join-Path $work 'Product') -Path $conf -Name 'Candidate fixture' -EnginePath $engine -WgPath $wg -TradeProgramPaths @() -DirectDnsIPv4 '192.168.100.1';$manifest=ReadJson $node.manifestPath;$hash=(Get-FileHash -LiteralPath $manifest.CandidatePath).Hash
    $expectedEngineHash=(Get-FileHash -LiteralPath $engine -Algorithm SHA256).Hash
    $engineMismatchManifest=ReadJson $node.manifestPath;$badEngine=Join-Path $work 'mismatched-engine.exe';[IO.File]::WriteAllText($badEngine,'not an engine; never execute')
    $engineMismatchManifest.EnginePath=$badEngine;WriteJson $node.manifestPath $engineMismatchManifest
    $engineMismatch=Test-TCCandidateProbe -Root $work -NodeId $node.id
    Check ($engineMismatch.Code -eq 'EngineMismatch' -and $engineMismatch.Status -eq 'Failed' -and (& $probe {$script:Starts}) -eq 0 -and $engineMismatch.Samples.Count -eq 0) 'different manifest engine binary rejected before any probe launch or request'
    $engineMismatchManifest.EnginePath=$engine;$engineMismatchManifest|Add-Member NoteProperty EngineSHA256 ('F'*64) -Force;WriteJson $node.manifestPath $engineMismatchManifest
    $badRecordedEngine=Test-TCCandidateProbe -Root $work -NodeId $node.id
    Check ($badRecordedEngine.Code -eq 'EngineMismatch' -and (& $probe {$script:Starts}) -eq 0) 'recorded engine digest mismatch cannot pass with the right path'
    $engineMismatchManifest.EngineSHA256='';WriteJson $node.manifestPath $engineMismatchManifest
    Check ((Test-TCCandidateProbe -Root $work -NodeId $node.id).Code -eq 'EngineMismatch') 'present but empty engine digest is not legacy absence'
    WriteJson $node.manifestPath $manifest
    WriteJson (Join-Path $work 'runtime.json') @{State='Running';ManifestPath=$node.manifestPath;CleanupError=$false}
    $active=Test-TCCandidateProbe -Root $work -NodeId $node.id -ExpectedExitIPv4 '192.0.2.20' -ExpectedExitSource 'ServerVerifiedTlsTrace'
    Check ($active.Code -eq 'ActiveIdentity' -and $active.Status -eq 'Inconclusive' -and (& $probe {$script:Starts}) -eq 0) 'active identity is rejected before any probe process or request'
    $activeCopy=ReadJson $node.manifestPath;$activeConfig=ReadJson $manifest.CandidatePath;$activeConfig.endpoints[0].private_key=" `n"+$activeConfig.endpoints[0].private_key+" `n";$activeCopy.ClientPublicKey=$pub.StandardOutput.Trim();$activeCopy.CandidatePath=Join-Path $work 'active-copy.private.json';WriteJson $activeCopy.CandidatePath $activeConfig;$activeCopyPath=Join-Path $work 'active-copy.manifest.json';WriteJson $activeCopyPath $activeCopy
    WriteJson (Join-Path $work 'runtime.json') @{State='Running';ManifestPath=$activeCopyPath;CleanupError=$false}
    $equivalent=Test-TCCandidateProbe -Root $work -NodeId $node.id;Check ($equivalent.Code -eq 'ActiveIdentity' -and (& $probe {$script:Starts}) -eq 0) 'decoded private identity comparison rejects formatting variants even when public metadata differs'
    [IO.File]::Delete((Join-Path $work 'runtime.json'))
    & $probe {$script:PortRetry=$true}
    $result=Test-TCCandidateProbe -Root $work -NodeId $node.id -ExpectedExitIPv4 '192.0.2.20' -ExpectedExitSource 'ServerVerifiedTlsTrace'
    Check ($result.Status -eq 'Inconclusive' -and $result.Code -eq 'ForwardingPassedPhysicalPathUnverified' -and $result.TransportPath -eq 'ExistingSystemRoute') 'verified candidate forwarding never proves physical-direct routing'
    Check (-not $manifest.PSObject.Properties['EngineSHA256'] -and $result.EngineSHA256 -ceq $expectedEngineHash) 'legacy manifest without recorded digest uses real binary hash and emits engine binding evidence'
    Check ($result.ForwardingPassed -and $result.ExitServerVerifiedTrace -and -not $result.PathEvidence.Verified -and -not $result.PathEvidence.EligibleForRecommendation -and $result.Samples.Count -eq 7 -and $result.Metrics.SampleBudget -eq 6 -and -not $result.Metrics.PerformanceRanked) 'layered evidence and fixed repeated sample budget'
    Check ($result.Metrics.MaxRequests -eq 7 -and $result.Metrics.TargetMetrics.Count -eq 3 -and @($result.Samples|Where-Object {-not $_.TargetUrl}).Count -eq 0 -and -not $result.Metrics.OverallDurationsRankable) 'single-probe boundary stays 6+1; complete URLs and per-target populations are retained'
    Check ((& $probe {$script:Starts}) -eq 2 -and $result.CleanupComplete) 'bind/startup race retries and kills only owned fixture processes'
    Check (@($result.Checks|Where-Object {$_.Name -eq 'ChatGPTWeb' -and $_.Code -eq 'BrowserChallenge'}).Count -eq 1) 'browser challenge is separate from network forwarding failure'
    $configs=& $probe {$script:Configs};$cfg=$configs[-1]
    Check ($cfg.inbounds.Count -eq 1 -and $cfg.inbounds[0].type -eq 'mixed' -and $cfg.inbounds[0].listen -eq '127.0.0.1' -and -not $cfg.PSObject.Properties['experimental']) 'candidate has no TUN/controller or system proxy configuration'
    Check ($cfg.inbounds[0].users[0].password.Length -ge 32 -and $cfg.inbounds[0].users[0].password -cne (ReadJson $manifest.CandidatePath).experimental.clash_api.secret) 'ephemeral loopback credentials are new random values'
    Check ($cfg.dns.final -eq 'dns-hk' -and @($cfg.dns.servers|Where-Object {$_.tag -eq 'dns-hk' -and $_.detour -eq 'hk'}).Count -eq 1) 'target DNS explicitly traverses candidate WireGuard'
    Check (-not [IO.File]::Exists((Join-Path (Split-Path $result.EvidencePath -Parent) 'candidate.private.json')) -and [IO.File]::Exists($result.EvidencePath)) 'ephemeral plaintext deleted and only public evidence kept'
    Check (-not [IO.File]::ReadAllText($result.EvidencePath).Contains($private) -and -not [IO.File]::ReadAllText($result.EvidencePath).Contains($cfg.inbounds[0].users[0].password)) 'evidence contains no tunnel or loopback secret'
    & $probe {$script:ReplyIP='192.0.2.21'}
    $mismatch=Test-TCCandidateProbe -Root $work -NodeId $node.id -ExpectedExitIPv4 '192.0.2.20' -ExpectedExitSource 'ServerVerifiedTlsTrace';Check ($mismatch.Status -eq 'Failed' -and $mismatch.Code -eq 'ExitMismatch') 'wrong exit cannot pass using current production exit'
    & $probe {$script:ReplyIP='192.0.2.20'}
    $unknown=Test-TCCandidateProbe -Root $work -NodeId $node.id -ExpectedExitIPv4 '192.0.2.20' -ExpectedExitSource 'ConfiguredAddress';Check ($unknown.Code -eq 'ExpectedExitUnverified' -and $unknown.Status -eq 'Inconclusive') 'configured expected address is not observed server evidence'
    $copyEngine=Join-Path $work 'identical-engine.exe';[IO.File]::Copy($engine,$copyEngine)
    $sameEngineManifest=ReadJson $node.manifestPath;$sameEngineManifest.EnginePath=$copyEngine;$sameEngineManifest|Add-Member NoteProperty EngineSHA256 $expectedEngineHash -Force;WriteJson $node.manifestPath $sameEngineManifest
    $sameEngine=Test-TCCandidateProbe -Root $work -NodeId $node.id -ExpectedExitIPv4 '192.0.2.20' -ExpectedExitSource 'ServerVerifiedTlsTrace'
    Check ($sameEngine.ForwardingPassed -and $sameEngine.EngineSHA256 -ceq $expectedEngineHash) 'identical binary at an older path is accepted by actual hash'
    & $probe {param($p)$script:DriftConfig=$p} $copyEngine
    $engineChanged=Test-TCCandidateProbe -Root $work -NodeId $node.id -ExpectedExitIPv4 '192.0.2.20' -ExpectedExitSource 'ServerVerifiedTlsTrace'
    Check ($engineChanged.Code -eq 'EngineMismatch' -and -not $engineChanged.PathEvidence.EligibleForRecommendation) 'engine bytes changed while sampling invalidate engine binding'
    WriteJson $node.manifestPath $manifest
    & $probe {$script:HttpFailure=$true};$fail=Test-TCCandidateProbe -Root $work -NodeId $node.id;Check ($fail.Code -eq 'CandidateForwardingFailed' -and $fail.Status -eq 'Failed') 'DNS/TCP/TLS failure is explicit failed forwarding'
    Check ($fail.Metrics.Failed -eq 6 -and $fail.Metrics.Attempted -eq 6 -and -not $fail.ForwardingPassed) 'failed samples remain in denominator and duration population'
    & $probe {$script:HttpFailure=$false;$script:HttpCalls=0;$script:FailAt=6}
    $lateFail=Test-TCCandidateProbe -Root $work -NodeId $node.id -ExpectedExitIPv4 '192.0.2.20' -ExpectedExitSource 'ServerVerifiedTlsTrace'
    Check (-not $lateFail.ForwardingPassed -and $lateFail.Metrics.Passed -eq 5 -and $lateFail.Metrics.Failed -eq 1 -and $lateFail.Samples.Count -eq 7) 'late repeated failure prevents qualification despite five passes'
    & $probe {$script:FailAt=0;$script:HttpCalls=0;$script:FlipExitAt=6}
    $exitPool=Test-TCCandidateProbe -Root $work -NodeId $node.id -ExpectedExitIPv4 '192.0.2.20' -ExpectedExitSource 'ServerVerifiedTlsTrace'
    Check ($exitPool.Code -eq 'ExitPoolChanged' -and -not $exitPool.ForwardingPassed -and -not $exitPool.PathEvidence.EligibleForRecommendation) 'exit consistency covers every repeated sample'
    & $probe {$script:FlipExitAt=0;$script:HttpCalls=0;$script:Slow=$true}
    $budget=Test-TCCandidateProbe -Root $work -NodeId $node.id -TimeoutSeconds 5
    Check ($budget.Samples.Count -eq 7 -and $budget.Metrics.NotTested -gt 0 -and @($budget.Samples|Where-Object {$_.Code -eq 'ProbeTimeout'}).Count -gt 0) 'timeouts and unattempted samples retain fixed budget slots'
    Check ($budget.Metrics.TimedOut -gt 0 -and @($budget.Metrics.TargetMetrics|Where-Object {$_.TimedOut -gt 0 -and $_.FailedResponses.Count -gt 0}).Count -gt 0) 'timeout duration is retained in failure statistics for its own target'
    & $probe {$script:Slow=$false;$script:HttpCalls=0}
    $fixedBudget=Test-TCCandidateProbe -Root $work -NodeId $node.id -TimeoutSeconds 5 -FixedRequestBudget
    Check ($fixedBudget.Samples.Count -eq 7 -and $fixedBudget.Metrics.NotTested -eq 6 -and (& $probe {$script:HttpCalls}) -eq 0 -and @($fixedBudget.Samples|Where-Object {$_.RequestBudgetSeconds -ne 6}).Count -eq 0 -and $fixedBudget.CleanupComplete) 'comparison fixed budget never silently shortens a request to fit remaining time'
    $metricFixture=@(
        [pscustomobject]@{Name='AddressHttps';TargetUrl='https://fixture.invalid/address';Required=$true;Attempted=$true;Status='Passed';Code='HttpsReached';DurationMs=10},
        [pscustomobject]@{Name='AddressHttps';TargetUrl='https://fixture.invalid/address';Required=$true;Attempted=$true;Status='Failed';Code='ProbeTimeout';DurationMs=6000},
        [pscustomobject]@{Name='DomainDnsHttps';TargetUrl='https://fixture.invalid/domain';Required=$true;Attempted=$true;Status='Passed';Code='HttpsReached';DurationMs=1000})
    $targetMetrics=(Get-TCCandidateProbeMetrics $metricFixture).TargetMetrics
    $addressMetric=@($targetMetrics|Where-Object {$_.Name -eq 'AddressHttps'})[0];$domainMetric=@($targetMetrics|Where-Object {$_.Name -eq 'DomainDnsHttps'})[0]
    Check ($addressMetric.Passed -eq 1 -and $addressMetric.Failed -eq 1 -and $addressMetric.TimedOut -eq 1 -and $addressMetric.Successful.MedianResponseMs -eq 10 -and $addressMetric.FailedResponses.MedianResponseMs -eq 6000 -and $domainMetric.Successful.MedianResponseMs -eq 1000) 'successful and failed durations stay separate and targets are never pooled for ranking'

    # Persist a disposable bound profile. Only process/socket/HTTP observations
    # are private fixtures; production config generation and native check run.
    $cfg=ReadJson $manifest.CandidatePath
    $transport=[pscustomobject]@{Type='tcp-reality';Server='192.0.2.10';Port=443;Uuid='aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';RealityPublicKey='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';RealityShortId='1234567890abcdef';ServerName='www.bing.com'}
    $cfg=& $nodes {param($c,$t)Set-TCConfigurationTransport $c (ConvertTo-TCTransport $t)} $cfg $transport
    $cfg=$cfg|ConvertTo-Json -Depth 40|ConvertFrom-Json
    # Legacy local E2E callers pass only endpoints/outbounds. Missing DNS must
    # remain a supported constructor shape under StrictMode 2 for both modes.
    foreach($mode in @('Udp','Tcp')){
        $sourceConfig=if($mode -eq 'Tcp'){$cfg}else{ReadJson $manifest.CandidatePath}
        foreach($shape in @('Absent','Null','NoServers','EmptyServers')){
            $minimal=[pscustomobject]@{endpoints=$sourceConfig.endpoints;outbounds=$sourceConfig.outbounds}
            switch($shape){
                'Null' {$minimal|Add-Member NoteProperty dns $null}
                'NoServers' {$minimal|Add-Member NoteProperty dns ([pscustomobject]@{})}
                'EmptyServers' {$minimal|Add-Member NoteProperty dns ([pscustomobject]@{servers=@()})}
            }
            $before=$minimal|ConvertTo-Json -Depth 40 -Compress
            $generated=& $probe {param($m,$c)New-TCCandidateProbeConfig $m $c $null 41311 'fixture-user' 'fixture-only-secret-0123456789abcdef'} $manifest $minimal
            $bootstrap=@($generated.dns.servers|Where-Object {$_.tag -eq 'dns-direct'})
            $generatedPath=Join-Path $work ('ctor-'+$mode+'-'+$shape+'.json');WriteJson $generatedPath $generated
            $null=& $nodes {param($e,$p)Test-TCCheckedConfiguration $e $p} $engine $generatedPath
            Check ($bootstrap.Count -eq 1 -and $bootstrap[0].server -eq $manifest.DirectDns -and $bootstrap[0].type -eq 'udp' -and -not $bootstrap[0].PSObject.Properties['bind_interface'] -and ($minimal|ConvertTo-Json -Depth 40 -Compress) -ceq $before) ($mode+' '+$shape+' DNS uses manifest fallback, passes native check, and leaves source untouched')
            [IO.File]::Delete($generatedPath)
        }
    }
    $pathModule=& $probe {$script:TCProbePathModule}
    $ctx=& $probe {Get-TCCandidateNetworkContext}
    $binding=& $pathModule {param($c,$ctx)$outer=Get-TCProbeOuter $c;New-TCProbeBinding $outer $ctx.Interfaces[0] $ctx '192.0.2.2' '192.168.100.1'} $cfg $ctx
    $outer=@($cfg.outbounds|Where-Object {$_.tag -eq 'tc-transport'})[0];$dns=@($cfg.dns.servers|Where-Object {$_.tag -eq 'dns-direct'})[0]
    foreach($obj in @($outer,$dns)){foreach($p in $binding.DialFields.PSObject.Properties){$obj|Add-Member NoteProperty $p.Name $p.Value -Force}}
    $outer|Add-Member NoteProperty domain_resolver ([pscustomobject]@{server='dns-direct';strategy='ipv4_only'}) -Force
    $manifest|Add-Member NoteProperty ProbeBinding $binding -Force
    WriteJson $manifest.CandidatePath $cfg;$manifest.CandidateSHA256=(Get-FileHash -LiteralPath $manifest.CandidatePath).Hash;WriteJson $node.manifestPath $manifest
    $profile=[pscustomobject]@{Id='Tcp';ManifestPath=$node.manifestPath;ManifestSHA256=(Get-FileHash -LiteralPath $node.manifestPath).Hash;CandidateSHA256=$manifest.CandidateSHA256}
    & $probe {param($p)$script:Profile=$p} $profile
    $ctx=& $probe {param($b)Get-TCCandidateNetworkContext $b} $binding
    $missingSavedDns=$cfg|ConvertTo-Json -Depth 40|ConvertFrom-Json;$missingSavedDns.PSObject.Properties.Remove('dns')
    $missingDnsProof=& $probe {param($c,$m,$p,$ctx)Get-TCCandidatePathAssessment $c $m $p @($ctx,$ctx) $null $true} $missingSavedDns $manifest $profile $ctx
    Check (-not $missingDnsProof.Verified -and -not $missingDnsProof.EligibleForRecommendation -and $missingDnsProof.Reason -eq 'StoredBootstrapDnsMissingOrAmbiguous') 'declared TCP ProbeBinding cannot upgrade generated fallback DNS into saved path proof'
    $qualified=Test-TCCandidateProbe -Root $work -NodeId $node.id -ProfileId Tcp -ExpectedExitIPv4 '192.0.2.20' -ExpectedExitSource 'ServerVerifiedTlsTrace'
    Check ($qualified.Status -eq 'Passed' -and $qualified.ForwardingPassed -and $qualified.PathEvidence.Kind -eq 'BoundInterfaceObserved' -and $qualified.PathEvidence.Verified -and $qualified.PathEvidence.EligibleForRecommendation -and $qualified.CleanupComplete) 'saved binding plus owned socket and exit evidence qualify TCP in isolated fixture'
    $emitted=(& $probe {$script:Configs})[-1];$emittedOuter=@($emitted.outbounds|Where-Object {$_.tag -eq 'tc-transport'})[0]
    Check ($emittedOuter.bind_interface -eq 'Ethernet Fixture' -and $emittedOuter.inet4_bind_address -eq '192.0.2.2' -and -not $emitted.endpoints[0].PSObject.Properties['bind_interface'] -and -not $emitted.route.auto_detect_interface) 'probe retains saved real TCP outer binding and removes ignored WG inner fields'
    Check ($emitted.dns.servers[0].bind_interface -eq 'Ethernet Fixture' -and $emitted.dns.servers[0].inet4_bind_address -eq '192.0.2.2') 'bootstrap DNS carries actual saved interface and source bind'
    Import-Module (Join-Path $package 'ProtocolSelection.psm1') -Force
    $normalized=ConvertTo-TCProtocolEvidence -Result $qualified -Profile $profile -NetworkContext $ctx
    Check ($normalized.EligibleForAutomaticSelection -and $normalized.Status -eq 'Passed') 'actual ProtocolSelection normalizer consumes qualified candidate contract'
    Check ($qualified.NetworkFingerprint -ceq $qualified.UnderlayFingerprint -and $qualified.NetworkFingerprint -ceq $qualified.PathEvidence.NetworkFingerprint -and $qualified.NetworkFingerprintScope -eq 'BoundPhysicalIPv4.v1' -and $qualified.SnapshotFingerprint -cne $qualified.NetworkFingerprint) 'raw and path evidence share explicit binding-specific underlay scope'
    & $probe {
        $script:Context.Interfaces+=,[pscustomobject]@{Index=30;Id='tc-fixture-30';Name='TradeChannel';Status='Up';Type='Ethernet';Hardware=$false;Metric=0;Addresses=@([pscustomobject]@{Address='172.30.250.1';Family='InterNetwork';PrefixLength=30;State='Preferred'});Gateways=@();DnsServers=@('172.30.250.2')}
        $script:Context.Routes+=,[pscustomobject]@{InterfaceIndex=30;DestinationPrefix='0.0.0.0/1';NextHop='0.0.0.0';RouteMetric=0;AddressFamily='IPv4'}
    }
    $afterTun=& $probe {param($b)Get-TCCandidateNetworkContext $b} $binding
    $afterEvidence=ConvertTo-TCProtocolEvidence -Result $qualified -Profile $profile -NetworkContext $afterTun
    Check ($afterEvidence.EligibleForAutomaticSelection -and (Test-TCProtocolEvidenceCurrent -Evidence $normalized -Profile $profile -NetworkContext $afterTun) -and $afterTun.SnapshotFingerprint -cne $ctx.SnapshotFingerprint) 'core current/normalize survive expected TUN addition when passed saved Binding context'
    & $probe {$script:Context.Interfaces[1].Name='ThirdPartyVPN'}
    $foreignContext=& $probe {param($b)Get-TCCandidateNetworkContext $b} $binding
    Check (-not (ConvertTo-TCProtocolEvidence -Result $qualified -Profile $profile -NetworkContext $foreignContext).EligibleForAutomaticSelection -and $foreignContext.Reason -eq 'UnsupportedEnvironmentChanged') 'core rejects unsupported third-party environment change through null Fingerprint'
    & $probe {$script:Context.Interfaces=@($script:Context.Interfaces[0]);$script:Context.Routes=@($script:Context.Routes[0])}
    $afterRemoval=& $probe {param($b)Get-TCCandidateNetworkContext $b} $binding
    Check ((Test-TCProtocolEvidenceCurrent -Evidence $normalized -Profile $profile -NetworkContext $afterRemoval)) 'core current check survives expected TUN removal'
    & $probe {$script:Drift=$true;$script:HttpCalls=0}
    $contextDrift=Test-TCCandidateProbe -Root $work -NodeId $node.id -ProfileId Tcp -ExpectedExitIPv4 '192.0.2.20' -ExpectedExitSource 'ServerVerifiedTlsTrace'
    Check (-not $contextDrift.PathEvidence.Verified -and $contextDrift.PathEvidence.Reason -eq 'NetworkContextChanged' -and $contextDrift.ContextChanged) 'network drift prevents bound candidate eligibility'
    Check ($contextDrift.Code -eq 'NetworkChangedDuringComparison' -and $contextDrift.Samples.Count -eq 1 -and (& $probe {$script:HttpCalls}) -eq 1 -and $contextDrift.CleanupComplete) 'network drift stops the next request immediately and still completes owned cleanup'
    & $probe {$script:Drift=$false;$script:HttpCalls=0}
    $udpDir=Join-Path $work 'udp-bound';$null=[IO.Directory]::CreateDirectory($udpDir)
    $udpCfg=& $nodes {param($c)Set-TCConfigurationTransport $c $null} (ReadJson $manifest.CandidatePath)
    $udpCfg=$udpCfg|ConvertTo-Json -Depth 40|ConvertFrom-Json
    $udpBinding=& $pathModule {param($c,$ctx)New-TCProbeBinding (Get-TCProbeOuter $c) $ctx.Interfaces[0] $ctx '192.0.2.2' '192.168.100.1'} $udpCfg $ctx
    foreach($obj in @($udpCfg.endpoints[0],@($udpCfg.dns.servers|Where-Object {$_.tag -eq 'dns-direct'})[0])){foreach($p in $udpBinding.DialFields.PSObject.Properties){$obj|Add-Member NoteProperty $p.Name $p.Value -Force}}
    $udpCfg.endpoints[0]|Add-Member NoteProperty domain_resolver ([pscustomobject]@{server='dns-direct';strategy='ipv4_only'}) -Force
    $udpManifest=$manifest|ConvertTo-Json -Depth 40|ConvertFrom-Json;$udpManifest.CandidatePath=Join-Path $udpDir 'candidate.json';$udpManifest.ProbeBinding=$udpBinding
    WriteJson $udpManifest.CandidatePath $udpCfg;$udpManifest.CandidateSHA256=(Get-FileHash $udpManifest.CandidatePath).Hash
    $udpManifestPath=Join-Path $udpDir 'manifest.json';WriteJson $udpManifestPath $udpManifest
    $udpProfile=[pscustomobject]@{Id='Udp';ManifestPath=$udpManifestPath;ManifestSHA256=(Get-FileHash $udpManifestPath).Hash;CandidateSHA256=$udpManifest.CandidateSHA256}
    & $probe {param($p)$script:Profile=$p} $udpProfile
    $udpPassed=Test-TCCandidateProbe -Root $work -NodeId $node.id -ProfileId Udp -ExpectedExitIPv4 '192.0.2.20' -ExpectedExitSource 'ServerVerifiedTlsTrace'
    Check ($udpPassed.Status -eq 'Passed' -and $udpPassed.ForwardingPassed -and $udpPassed.PathEvidence.Verified -and $udpPassed.PathEvidence.EligibleForRecommendation -and $udpPassed.PathEvidence.Reason -eq 'OwnedUdpEtwAndSavedBindingVerified' -and (& $probe {$script:TraceReceiptSeen})) 'UDP saved binding and owned ETW qualify only after durable trace ownership intent'
    $comparisonModule=Import-Module (Join-Path $package 'ProtocolComparison.psm1') -PassThru -DisableNameChecking
    & $probe {param($p)$script:ComparisonProfiles=$p;$script:HttpCalls=0} @($udpProfile,$profile)
    & $comparisonModule {
        param($p)$script:FixtureCandidate=$p
        function script:Get-TCProtocolComparisonContext {& $script:FixtureCandidate {Get-TCCandidateNetworkContext $null}}
        function script:Get-TCProtocolComparisonProfile {param($Root,$NodeId,$ProfileId)& $script:FixtureCandidate {param($r,$n,$id)Get-TCCandidateProbeProfile $r $n $id} $Root $NodeId $ProfileId}
        # This suite tests the real comparison -> candidate execution boundary.
        # Fixtures were bound above; full LineStore preparation is covered by
        # Test-ProbeWorkflowIntegration, so do not use physical NICs here.
        function script:Prepare-TCProtocolComparisonBinding {
            param($Root,$NodeId,$InterfaceIndex)
            $rows=@(foreach($id in @('Udp','Tcp')){
                $p=Get-TCProtocolComparisonProfile $Root $NodeId $id
                if((Get-FileHash -LiteralPath $p.ManifestPath).Hash -cne $p.ManifestSHA256){throw 'Fixture manifest changed before comparison'}
                [pscustomobject]@{ProfileId=$id;BindingState='Reused';CandidateSHA256=$p.CandidateSHA256;ManifestSHA256=$p.ManifestSHA256}
            })
            [pscustomobject]@{LineId=$NodeId;State='Ready';Code='FixtureExistingBindings';Results=$rows}
        }
    } $probe
    $killsBefore=& $probe {$script:Kills}
    $integrated=Invoke-TCProtocolComparison -Root $work -NodeId $node.id -ExpectedExitIPv4 '192.0.2.20' -ExpectedExitSource ServerVerifiedTlsTrace
    $comparisonOk=($integrated.Comparison.Completed -and $integrated.Comparison.SameBudget -and $integrated.Comparison.SameNetwork -and $integrated.Comparison.RequestsAttempted -eq 42 -and (& $probe {$script:HttpCalls}) -eq 42 -and (& $probe {$script:Kills}) -eq ($killsBefore+6))
    if(-not $comparisonOk){[pscustomobject]@{Completed=$integrated.Comparison.Completed;SameBudget=$integrated.Comparison.SameBudget;SameNetwork=$integrated.Comparison.SameNetwork;RequestsAttempted=$integrated.Comparison.RequestsAttempted;HttpCalls=(& $probe {$script:HttpCalls});Kills=(& $probe {$script:Kills});KillsBefore=$killsBefore;Results=@($integrated.Results|ForEach-Object {[pscustomobject]@{Id=$_.ProfileId;Status=$_.Result.Status;Code=$_.Result.Code}});ComparisonCode=$integrated.Code}|ConvertTo-Json -Depth 5}
    Check $comparisonOk 'comparison default delegate consumes the real candidate API and cleans six isolated fixture engines serially'
    foreach($entry in $integrated.Results){Check ($entry.Result.Status -eq 'Passed' -and $entry.Result.Samples.Count -eq 21 -and $entry.Result.ProbeRuns.Count -eq 3 -and @($entry.Result.ProbeRuns|Where-Object {-not $_.Result.CleanupComplete}).Count -eq 0) 'integration preserves every path/exit/hash/cleanup receipt in aggregate Result'}
    $integrationProfiles=@($udpProfile|ConvertTo-Json -Depth 40|ConvertFrom-Json)+@($profile|ConvertTo-Json -Depth 40|ConvertFrom-Json)
    foreach($p in $integrationProfiles){$r=@($integrated.Results|Where-Object {$_.ProfileId -ceq $p.Id})[0].Result;$bindingContext=& $probe {param($b)Get-TCCandidateNetworkContext $b} $r.PathEvidence.Binding;$p|Add-Member NoteProperty Validation (ConvertTo-TCProtocolEvidence -Result $r -Profile $p -NetworkContext $bindingContext) -Force}
    $integrationRecommendation=Get-TCProtocolRecommendation -Profiles $integrationProfiles -NetworkContext $ctx -LineId $node.id
    Check ($integrationRecommendation.RecommendedProfileId -eq 'Udp' -and $integrationRecommendation.Source -eq 'PolicyDefault' -and -not $integrationRecommendation.PerformanceRanked -and $integrationRecommendation.PairedSampleCount -eq 18) 'real normalized probe shapes feed paired comparison without pooled timing claims'
    & $probe {$script:ComparisonProfiles=$null;$script:HttpCalls=0}
    $udpContext=& $probe {param($b)Get-TCCandidateNetworkContext $b} $udpBinding
    $missingUdpDns=$udpCfg|ConvertTo-Json -Depth 40|ConvertFrom-Json;$missingUdpDns.PSObject.Properties.Remove('dns')
    $missingUdpProof=& $probe {param($c,$m,$p,$ctx)Get-TCCandidatePathAssessment $c $m $p @($ctx,$ctx) $null $true} $missingUdpDns $udpManifest $udpProfile $udpContext
    Check (-not $missingUdpProof.Verified -and -not $missingUdpProof.EligibleForRecommendation -and $missingUdpProof.Reason -eq 'StoredBootstrapDnsMissingOrAmbiguous') 'declared UDP ProbeBinding without saved DNS remains unqualified'
    $udpEvidence=ConvertTo-TCProtocolEvidence -Result $udpPassed -Profile $udpProfile -NetworkContext $udpContext
    $udpProfile|Add-Member NoteProperty Validation $udpEvidence
    $udpRecommendation=Get-TCProtocolRecommendation -Profiles @($udpProfile) -NetworkContext $udpContext -LineId $node.id
    Check ($udpEvidence.EligibleForAutomaticSelection -and $udpRecommendation.RecommendedProfileId -eq 'Udp' -and -not $udpRecommendation.PerformanceRanked) 'UDP-only deployment can auto-select qualified reachability without TCP'
    $failedTcp=[pscustomobject]@{Id='Tcp';CandidateSHA256=$profile.CandidateSHA256;Validation=[pscustomobject]@{Status='Failed';EligibleForAutomaticSelection=$false;Code='DependencyUnavailable'}}
    Check ((Get-TCProtocolRecommendation -Profiles @($udpProfile,$failedTcp) -NetworkContext $udpContext -LineId $node.id).RecommendedProfileId -eq 'Udp') 'failed TCP preparation does not prevent a genuinely qualified UDP default'
    & $probe {$script:EtwUnavailable=$true}
    $udpUnknown=Test-TCCandidateProbe -Root $work -NodeId $node.id -ProfileId Udp -ExpectedExitIPv4 '192.0.2.20' -ExpectedExitSource 'ServerVerifiedTlsTrace'
    Check ($udpUnknown.ForwardingPassed -and $udpUnknown.Status -eq 'Inconclusive' -and $udpUnknown.PathEvidence.Reason -eq 'UdpEtwObservationUnavailable' -and -not $udpUnknown.PathEvidence.EligibleForRecommendation) 'unavailable UDP observation does not become forwarding failure'
    & $probe {$script:EtwUnavailable=$false;$script:TraceStopFails=$true}
    $udpUnclean=Test-TCCandidateProbe -Root $work -NodeId $node.id -ProfileId Udp -ExpectedExitIPv4 '192.0.2.20' -ExpectedExitSource 'ServerVerifiedTlsTrace'
    Check ($udpUnclean.Code -eq 'ProbeCleanupFailed' -and -not $udpUnclean.CleanupComplete -and -not $udpUnclean.PathEvidence.EligibleForRecommendation) 'ETW cleanup failure overrides UDP forwarding success'
    $beforeStarts=& $probe {$script:Starts}
    $udpBlocked=Test-TCCandidateProbe -Root $work -NodeId $node.id -ProfileId Udp
    Check ($udpBlocked.Code -eq 'ProbeCleanupFailed' -and (& $probe {$script:Starts}) -eq $beforeStarts) 'residual own ETW blocks another engine while trace cleanup is unavailable'
    & $probe {$script:TraceStopFails=$false}
    $udpRecoveredTrace=Test-TCCandidateProbe -Root $work -NodeId $node.id -ProfileId Udp
    Check ($udpRecoveredTrace.Code -eq 'ProbeCleanupFailed' -and (& $probe {$script:Starts}) -eq $beforeStarts) 'trace recovery alone never grants permission to reuse unresolved probe identity'
    $udpMarker=Join-Path (Split-Path $udpUnclean.EvidencePath -Parent) 'ownership.json';$udpOwner=ReadJson $udpMarker
    Check ($udpOwner.TraceState -eq 'Stopped' -and $udpOwner.State -eq 'NeedsRecovery') 'recovery stops only receipt trace and retains engine identity fence'
    $udpOwner.State='Stopped';WriteJson $udpMarker $udpOwner
    & $probe {param($p)$script:Profile=$p} $profile

    # File-based UI cancellation: real marker I/O under the required run path.
    # The fake HTTP delegate writes while the probe owns its session lock.
    $cancelRun=[guid]::NewGuid().ToString('D');$cancelAttempt=[guid]::NewGuid().ToString('N')
    $cancelDir=Join-Path (Join-Path $work 'deployments\runs') $cancelRun;$null=[IO.Directory]::CreateDirectory($cancelDir)
    $cancelPath=Join-Path $cancelDir ('probe-cancel-'+$cancelAttempt+'.json')
    Check ((Get-Command Test-TCCandidateProbe).Parameters.ContainsKey('CancellationPath')) 'optional CancellationPath is available to Flow/UI'
    WriteJson $cancelPath @{AttemptId=$cancelAttempt}
    $beforeStarts=& $probe {$script:Starts};$beforeCalls=& $probe {$script:HttpCalls}
    $held=& $nodes {param($r)Open-TCNodeSessionLock (Join-Path $r 'Product')} $work
    try{$preCancelled=Test-TCCandidateProbe -Root $work -NodeId $node.id -ProfileId Tcp -CancellationPath $cancelPath}finally{$held.Dispose()}
    Check ($preCancelled.Code -eq 'ProbeCancelled' -and $preCancelled.Status -eq 'Inconclusive' -and $preCancelled.CancellationRequested -and -not $preCancelled.ForwardingPassed -and $preCancelled.CleanupComplete -and (& $probe {$script:Starts}) -eq $beforeStarts -and (& $probe {$script:HttpCalls}) -eq $beforeCalls) 'preexisting matching marker cancels before acquiring identity lock or starting anything'
    Check ([IO.File]::Exists($cancelPath) -and $preCancelled.CancellationAttemptId -ceq $cancelAttempt) 'marker is preserved for next profile and attempt identity is explicit'
    WriteJson $cancelPath @{AttemptId=[guid]::NewGuid().ToString('N')}
    & $probe {$script:HttpCalls=0}
    $staleMarker=Test-TCCandidateProbe -Root $work -NodeId $node.id -ProfileId Tcp -CancellationPath $cancelPath -ExpectedExitIPv4 '192.0.2.20' -ExpectedExitSource 'ServerVerifiedTlsTrace'
    Check ($staleMarker.Status -eq 'Passed' -and -not $staleMarker.CancellationRequested -and (& $probe {$script:HttpCalls}) -eq 7) 'different AttemptId cannot cancel current probe'
    $cancelSpec=& $probe {param($r,$p,$n)Resolve-TCCandidateCancellation $r $p $n} $work $cancelPath $nodes
    [IO.File]::WriteAllText($cancelPath,'{"AttemptId":')
    Check (-not (& $probe {param($c,$n)Test-TCCandidateCancellation $c $n} $cancelSpec $nodes)) 'partial marker write is ignored until valid JSON is published'
    WriteJson $cancelPath @{AttemptId=([guid]$cancelAttempt).ToString('D').ToUpperInvariant()}
    Check (& $probe {param($c,$n)Test-TCCandidateCancellation $c $n} $cancelSpec $nodes) 'marker GUID format/case normalizes to leaf attempt'
    [IO.File]::Delete($cancelPath)
    foreach($badPath in @((Join-Path $work ('probe-cancel-'+$cancelAttempt+'.json')),($work+'-other\deployments\runs\'+$cancelRun+'\probe-cancel-'+$cancelAttempt+'.json'),(Join-Path $cancelDir 'probe-cancel-wrong.json'),('deployments\runs\'+$cancelRun+'\probe-cancel-'+$cancelAttempt+'.json'))){
        $beforeStarts=& $probe {$script:Starts}
        $badCancel=Test-TCCandidateProbe -Root $work -NodeId $node.id -CancellationPath $badPath
        Check ($badCancel.Code -eq 'CancellationPathInvalid' -and -not $badCancel.ForwardingPassed -and (& $probe {$script:Starts}) -eq $beforeStarts) 'invalid cancellation path rejected without probe startup'
    }
    $junction=Join-Path (Join-Path $work 'deployments\runs') ([guid]::NewGuid().ToString('D'))
    $junctionTarget=Join-Path $work 'cancellation-link-target';$null=[IO.Directory]::CreateDirectory($junctionTarget)
    $null=New-Item -ItemType Junction -Path $junction -Value $junctionTarget
    try{
        $linked=Join-Path $junction ('probe-cancel-'+$cancelAttempt+'.json')
        $beforeStarts=& $probe {$script:Starts};$unsafe=Test-TCCandidateProbe -Root $work -NodeId $node.id -CancellationPath $linked
        Check ($unsafe.Code -eq 'CancellationPathInvalid' -and (& $probe {$script:Starts}) -eq $beforeStarts) 'a junction ancestor is rejected even before marker creation'
    }finally{[IO.Directory]::Delete($junction)}
    foreach($mode in @('Tcp','Udp')){
        $selected=if($mode -eq 'Udp'){$udpProfile}else{$profile}
        & $probe {param($p,$path,$attempt)$script:Profile=$p;$script:HttpCalls=0;$script:CancelMarkerAt=1;$script:CancelMarkerPath=$path;$script:CancelMarkerAttempt=$attempt} $selected $cancelPath $cancelAttempt
        $beforeStops=& $probe {$script:SocketStops};$beforeKills=& $probe {$script:Kills}
        $stopped=Test-TCCandidateProbe -Root $work -NodeId $node.id -ProfileId $mode -CancellationPath $cancelPath -ExpectedExitIPv4 '192.0.2.20' -ExpectedExitSource 'ServerVerifiedTlsTrace'
        Check ($stopped.Code -eq 'ProbeCancelled' -and $stopped.Status -eq 'Inconclusive' -and $stopped.CancellationRequested -and -not $stopped.ForwardingPassed -and -not $stopped.PathEvidence.Verified -and -not $stopped.PathEvidence.EligibleForRecommendation -and $stopped.Samples.Count -eq 1 -and (& $probe {$script:HttpCalls}) -eq 1) ($mode+' file marker after first real fixture response prevents the next request')
        $owner=ReadJson (Join-Path (Split-Path $stopped.EvidencePath -Parent) 'ownership.json')
        Check ($stopped.CleanupComplete -and $owner.State -eq 'Stopped' -and (& $probe {$script:SocketStops}) -gt $beforeStops -and (& $probe {$script:Kills}) -eq ($beforeKills+1) -and ($mode -ne 'Udp' -or $owner.TraceState -eq 'Stopped') -and -not [IO.File]::Exists((Join-Path (Split-Path $stopped.EvidencePath -Parent) 'candidate.private.json'))) ($mode+' cancellation cleans only owned engine/observation and persisted private state')
        [IO.File]::Delete($cancelPath)
    }
    & $probe {param($p)$script:Profile=$p;$script:HttpCalls=0;$script:CancelMarkerAt=7} $profile
    $lastRequestCancel=Test-TCCandidateProbe -Root $work -NodeId $node.id -ProfileId Tcp -CancellationPath $cancelPath -ExpectedExitIPv4 '192.0.2.20' -ExpectedExitSource 'ServerVerifiedTlsTrace'
    Check ($lastRequestCancel.Code -eq 'ProbeCancelled' -and $lastRequestCancel.Samples.Count -eq 7 -and -not $lastRequestCancel.ForwardingPassed) 'marker arriving in final request still cancels result qualification'
    [IO.File]::Delete($cancelPath)
    & $probe {$script:CancelMarkerAt=0;$script:CancelMarkerOnKill=$true;$script:HttpCalls=0}
    $duringCleanup=Test-TCCandidateProbe -Root $work -NodeId $node.id -ProfileId Tcp -CancellationPath $cancelPath -ExpectedExitIPv4 '192.0.2.20' -ExpectedExitSource 'ServerVerifiedTlsTrace'
    Check ($duringCleanup.Code -eq 'ProbeCancelled' -and $duringCleanup.CleanupComplete -and -not $duringCleanup.ForwardingPassed -and -not $duringCleanup.PathEvidence.EligibleForRecommendation) 'marker arriving during cleanup cannot leave a passed recommendation'
    [IO.File]::Delete($cancelPath)
    & $probe {$script:CancelMarkerOnKill=$false;$script:CancelMarkerAt=1;$script:HttpCalls=0;$script:KillFails=$true}
    $cancelUnclean=Test-TCCandidateProbe -Root $work -NodeId $node.id -ProfileId Tcp -CancellationPath $cancelPath
    Check ($cancelUnclean.CancellationRequested -and $cancelUnclean.Code -eq 'ProbeCleanupFailed' -and $cancelUnclean.Status -eq 'Failed' -and -not $cancelUnclean.CleanupComplete -and -not $cancelUnclean.ForwardingPassed) 'cleanup failure takes precedence over a valid cancellation marker'
    $cancelOwnerPath=Join-Path (Split-Path $cancelUnclean.EvidencePath -Parent) 'ownership.json';$cancelOwner=ReadJson $cancelOwnerPath;$cancelOwner.State='Stopped';WriteJson $cancelOwnerPath $cancelOwner
    [IO.File]::Delete($cancelPath)
    & $probe {$script:KillFails=$false;$script:CancelMarkerAt=0;$script:CancelMarkerPath='';$script:CancelMarkerAttempt=''}
    $lock=& $nodes {param($r)Open-TCNodeSessionLock (Join-Path $r 'Product')} $work
    try{$beforeStarts=& $probe {$script:Starts};$locked=Test-TCCandidateProbe -Root $work -NodeId $node.id -ProfileId Tcp;Check (($locked.Status -eq 'Failed') -and (& $probe {$script:Starts}) -eq $beforeStarts) 'session lock prevents concurrent identity acquisition'}finally{$lock.Dispose()}
    & $probe {$script:Cancel=$true};$killsBefore=& $probe {$script:Kills}
    $cancelled=Test-TCCandidateProbe -Root $work -NodeId $node.id -ProfileId Tcp
    Check ($cancelled.CleanupComplete -and -not $cancelled.CancellationRequested -and -not $cancelled.PathEvidence.EligibleForRecommendation -and (& $probe {$script:Kills}) -eq ($killsBefore+1)) 'generic HTTP exception unwinds owned process without impersonating marker cancellation'
    & $probe {$script:Cancel=$false}

    # Real BoundedEngine parent/child lifetime, using sleeping local PowerShell
    # processes only. No WG identity, listener or network request is involved.
    $orphanRun=Join-Path (Join-Path $work 'probes') ([guid]::NewGuid().ToString('D'));$worker=$null;$orphan=$null;$orphanOwned=$false
    $binary=if($PSVersionTable.PSEdition -eq 'Core'){Join-Path $PSHOME 'pwsh.exe'}else{Join-Path $PSHOME 'powershell.exe'}
    $childEncoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('Start-Sleep -Seconds 40'))
    $workerCode=@'
$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition -ne 'Core'){$env:PSModulePath=Join-Path $PSHOME 'Modules'}
$candidate=Import-Module '__PACKAGE__/CandidateProbe.psm1' -PassThru -DisableNameChecking
$nodes=Import-Module '__PACKAGE__/NodeStore.psm1' -PassThru -DisableNameChecking
Import-Module '__PACKAGE__/RuntimeObservability.psm1' -DisableNameChecking
$dir='__RUN__';$null=& $nodes {param($p)New-TCPrivateDirectory $p} $dir
$metadata=[pscustomobject]@{RunId=[IO.Path]::GetFileName($dir);NodeId='__NODE__';CandidateHash='__HASH__';ConfigHash=('C'*64);EnginePath='__BINARY__';ProcessId=$null;ProcessStartedAt=$null}
& $candidate {param($n,$d,$m)Set-TCCandidateOwnership $n $d 'Starting' $null $m} $nodes $dir $metadata
$p=Start-TCBoundedEngineProcess -Root $dir -Executable '__BINARY__' -Arguments '-NoProfile -NonInteractive -EncodedCommand __CHILD__' -SessionId 'candidate-0' -MaxBytes 262144
& $candidate {param($n,$d,$p,$m)Set-TCCandidateOwnership $n $d 'Running' $p $m} $nodes $dir $p $metadata
Start-Sleep -Seconds 40
'@
    $workerCode=$workerCode.Replace('__PACKAGE__',$package.Replace("'","''")).Replace('__RUN__',$orphanRun.Replace("'","''")).Replace('__NODE__',$node.id).Replace('__HASH__',$profile.CandidateSHA256).Replace('__BINARY__',$binary.Replace("'","''")).Replace('__CHILD__',$childEncoded)
    try{
        $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($workerCode))
        $worker=Start-Process -FilePath $binary -ArgumentList @('-NoProfile','-NonInteractive','-EncodedCommand',$encoded) -WindowStyle Hidden -PassThru
        $until=[DateTime]::UtcNow.AddSeconds(12);$orphanMarker=Join-Path $orphanRun 'ownership.json';$record=$null
        do{if([IO.File]::Exists($orphanMarker)){try{$record=ReadJson $orphanMarker}catch{}};if($record -and $record.State -eq 'Running'){break};Start-Sleep -Milliseconds 100}while([DateTime]::UtcNow -lt $until -and -not $worker.HasExited)
        if(-not $record -or $record.State -ne 'Running'){throw 'Owned parent fixture failed to start'}
        $orphan=[Diagnostics.Process]::GetProcessById([int]$record.ProcessId)
        Check ($orphan.StartTime.ToUniversalTime().Ticks -eq ([DateTimeOffset]$record.ProcessStartedAt).UtcDateTime.Ticks -and $orphan.Path -ieq $binary -and $record.CandidateHash -ceq $profile.CandidateSHA256 -and $record.ConfigHash -match '^[C]{64}$') 'ownership marker records native PID birth and config identity'
        $orphanOwned=$true
        $worker.Kill();$null=$worker.WaitForExit(3000);$beforeStarts=& $probe {$script:Starts}
        $resume=Test-TCCandidateProbe -Root $work -NodeId $node.id -ProfileId Tcp
        Check ($resume.Code -eq 'ProbeCleanupFailed' -and -not $resume.CleanupComplete -and (& $probe {$script:Starts}) -eq $beforeStarts) 'parent worker death cannot start second probe while orphan ownership is unresolved'
    }finally{
        if($worker){if(-not $worker.HasExited){$worker.Kill();$null=$worker.WaitForExit(3000)};$worker.Dispose()}
        if($orphan){if($orphanOwned -and -not $orphan.HasExited){$orphan.Kill();$null=$orphan.WaitForExit(3000)};$orphan.Dispose()}
        if($record){$record.State='Stopped';WriteJson $orphanMarker $record}
    }
    & $probe {$script:KillFails=$true}
    $unclean=Test-TCCandidateProbe -Root $work -NodeId $node.id -ProfileId Tcp -ExpectedExitIPv4 '192.0.2.20' -ExpectedExitSource 'ServerVerifiedTlsTrace'
    Check (-not $unclean.CleanupComplete -and $unclean.Code -eq 'ProbeCleanupFailed' -and -not $unclean.PathEvidence.EligibleForRecommendation) 'cleanup failure overrides positive forwarding and path proof'
    & $probe {$script:KillFails=$false};$beforeStarts=& $probe {$script:Starts}
    $blocked=Test-TCCandidateProbe -Root $work -NodeId $node.id -ProfileId Tcp
    Check ($blocked.Code -eq 'ProbeCleanupFailed' -and -not $blocked.CleanupComplete -and (& $probe {$script:Starts}) -eq $beforeStarts) 'persisted cleanup failure blocks next isolated engine'
    # The failed process was a PSObject fixture; explicitly recover its marker
    # only in this disposable test root, never by killing an external process.
    $marker=Join-Path (Split-Path $unclean.EvidencePath -Parent) 'ownership.json';$ownership=ReadJson $marker;$ownership.State='Stopped';WriteJson $marker $ownership
    & $probe {param($p)$script:DriftConfig=$p} $manifest.CandidatePath
    $during=Test-TCCandidateProbe -Root $work -NodeId $node.id -ProfileId Tcp -ExpectedExitIPv4 '192.0.2.20' -ExpectedExitSource 'ServerVerifiedTlsTrace'
    Check ($during.Code -eq 'ConfigurationChanged' -and -not $during.PathEvidence.Verified) 'saved config changed while probing invalidates evidence'
    [IO.File]::AppendAllText($manifest.CandidatePath,' ');$drift=Test-TCCandidateProbe -Root $work -NodeId $node.id;Check ($drift.Code -eq 'ProbePreparationFailed' -and $drift.Status -eq 'Failed') 'candidate hash drift rejected before launch'
    [pscustomobject]@{Passed=$true;Checks=$script:Checks;RealNetworkChanges=0;RealEngineRun=0;PublicCandidateProbes=0;ActiveIdentityProtected=$true;SourceAwareExit=$true;SecretCleanup=$true;FixedSampleBudget=6;ProtocolSelectionContract=$true;ProtocolComparisonContract=$true;SerialComparisonRequests=42;TargetMetricPopulations=$true;UdpOnlyQualifiedSelection=$true;UdpEtwUnavailableIsUnknown=$true;EtwResidualBlocksNewEngine=$true;EngineBinaryBindingVerified=$true;FileMarkerCancellation=$true;CancellationPathBoundedNoReparse=$true;WorkerDeathContinuationBlocked=$true;NativeScope='pubkey/check and owned sleeping PowerShell only';PowerShell=$PSVersionTable.PSVersion.ToString()}
}finally{
    $full=[IO.Path]::GetFullPath($work);$parent=[IO.Path]::GetFullPath([Environment]::GetFolderPath('LocalApplicationData')).TrimEnd('\')+'\'
    if(-not $full.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notmatch '^TC-CandidateProbe-[0-9a-f]{32}$'){throw 'Cleanup rejected.'};Remove-Item -LiteralPath $full -Recurse -Force
}
