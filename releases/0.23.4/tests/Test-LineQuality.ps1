#requires -Version 5.1
# All measurements are injected; controller transport and runtime reads are
# replaced in memory for adapter checks. No production root or network probes.
[CmdletBinding()]param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$package=Split-Path $PSScriptRoot -Parent
$modulePath=Join-Path $package 'LineQuality.psm1'
$module=Import-Module $modulePath -Force -PassThru -DisableNameChecking
$fixtureBase=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$work=Join-Path $fixtureBase ('TC-LineQuality-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($work)
$script:Checks=0
$timer=@{Now=[DateTimeOffset]'2026-10-15T06:00:00Z'}
$clock={ $timer.Now }.GetNewClosure()
$data=@{Calls=0; Latency=80; Throw=$false; SleepMs=0; Source='ControllerDelay'; Status='Measured'; WrongKey=$false; Action=''; Root=''; ModulePath=$modulePath; Overview=$null; Now=$null; Nested=$null}
$measure={
    param($Context,$BudgetMilliseconds,$Data)
    $Data.Calls++
    if ($BudgetMilliseconds -le 0 -or $BudgetMilliseconds -gt 7000) { throw 'Invalid budget.' }
    if ($Data.Throw) { throw 'fixture-secret must never appear in evidence' }
    if ($Data.SleepMs -gt 0) { Start-Sleep -Milliseconds $Data.SleepMs }
    if ($Data.Action -eq 'Clear') {
        Import-Module $Data.ModulePath -DisableNameChecking
        $null=Clear-TCLineQuality -Root $Data.Root
    }
    if ($Data.Action -in @('Overlap','Disconnect')) {
        Import-Module $Data.ModulePath -DisableNameChecking
        $fixtureClock={ $Data.Now }.GetNewClosure()
        $Data.Nested=Invoke-TCLineQualitySample -Root $Data.Root -Overview $Data.Overview -Measure { throw 'Nested sampling must not execute.' } -Clock $fixtureClock
    }
    [pscustomobject]@{
        Status=$Data.Status; Reason=$(if ($Data.Status -eq 'Measured') {'Measured'} else {'DelayUnavailable'})
        ContextKey=$(if ($Data.WrongKey) {'wrong-key'} else {$Context.Key})
        Source=$Data.Source; Outbound=$Context.Binding.Exit; LatencyMs=$Data.Latency
    }
}
function Check {
    param([bool]$Ok,[string]$Label)
    if (-not $Ok) { throw ('LineQuality check failed: '+$Label) }
    $script:Checks++
}
function New-Overview {
    [pscustomobject]@{
        Running=$true; StateKey='Connected'; SessionId='fixture-session-1'; ActiveLineId='11111111-1111-1111-1111-111111111111'
        ActiveProfileId='Udp'; ProfileBindingVerified=$true; NodeId='22222222-2222-2222-2222-222222222222'
        Exit='hk'; ConfigHash=('A'*64); EnginePid=12345; ConnectedSince='2026-10-14T00:00:00Z'
        ManifestPath=(Join-Path $work 'fixture-manifest.json'); Mode='rule'; ObservedAt=$timer.Now.ToString('o')
    }
}
function Tick {
    param($Ms=80,[int]$Seconds=30,[bool]$NotifyEnabled=$true)
    $timer.Now=$timer.Now.AddSeconds($Seconds); $overview.ObservedAt=$timer.Now.ToString('o'); $data.Latency=$Ms
    Invoke-TCLineQualitySample -Root $root -Overview $overview -Measure $measure -MeasureData $data -Clock $clock -NotifyEnabled $NotifyEnabled
}
function View {
    $overview.ObservedAt=$timer.Now.ToString('o')
    Get-TCLineQualitySummary -Root $root -Overview $overview -Clock $clock
}
try {
    foreach ($file in @($modulePath,$PSCommandPath)) {
        $bytes=[IO.File]::ReadAllBytes($file)
        Check ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) ('UTF8 BOM '+[IO.Path]::GetFileName($file))
        $tokens=$null; $parseErrors=$null
        $null=[Management.Automation.Language.Parser]::ParseFile($file,[ref]$tokens,[ref]$parseErrors)
        Check (@($parseErrors).Count -eq 0) ('PowerShell parser '+[IO.Path]::GetFileName($file))
    }
    $root=Join-Path $work 'lifecycle'; $overview=New-Overview
    $good=Tick 85 0
    Check ($good.Sampled -and $good.Quality -eq 'Good' -and $good.LatencyMs -eq 85 -and -not $good.Notify) ('first good sample: '+$good.Reason)
    Check (-not $good.Degraded -and $good.NotificationMessage -eq '') 'good sample has no persistent warning'
    Check ($good.Binding.NodeId -eq $overview.ActiveLineId -and $good.Binding.NodeId -ne $overview.NodeId) 'identity uses actual verified line, not desired node'
    Check ($good.PacketLossPercent -eq $null -and -not $good.PacketLossMeasured -and -not $good.NetworkChanged -and -not $good.AutoSwitched) 'no fabricated loss or network change'
    $calls=$data.Calls; $cached=Tick 999 29
    Check (-not $cached.Sampled -and $data.Calls -eq $calls -and $cached.LatencyMs -eq 85) '29 seconds returns cache without measuring'
    $bad1=Tick 650 1; $bad2=Tick 700; $bad3=Tick 800
    Check (-not $bad1.Notify -and -not $bad2.Notify -and $bad3.Notify -and $bad3.Notification.Reason -eq 'ConsecutiveHighLatency') 'three consecutive poor samples emit one alert'
    Check (-not $bad1.Degraded -and -not $bad2.Degraded -and $bad1.NotificationMessage -eq '' -and $bad3.Degraded -and $bad3.NotificationMessage -eq $bad3.Notification.Message) 'only the latched incident creates a persistent warning'
    $firstId=$bad3.Notification.Id
    Check (-not (View).Notify -and (View).Notification -eq $null) 'summary reads never replay an alert'
    Check ((View).Degraded -and (View).NotificationMessage -eq $bad3.Notification.Message) 'fresh matching summary retains the warning without another toast'
    $timer.Now=$timer.Now.AddSeconds(76); $staleWarning=View
    Check (-not $staleWarning.Degraded -and $staleWarning.NotificationMessage -eq '' -and $staleWarning.LastNotification.Id -eq $firstId) 'expired samples hide persistent warnings even when historical alert exists'
    $timer.Now=$timer.Now.AddSeconds(-76)
    # Re-import simulates the next short-lived worker. Debounce must be durable.
    $module=Import-Module $modulePath -Force -PassThru -DisableNameChecking
    for ($i=0; $i -lt 10; $i++) { $bad=Tick 850; Check (-not $bad.Notify) 'same incident stays latched even after cooldown expires' }
    $recover1=Tick 100; $recover2=Tick 110
    Check ($recover1.Quality -eq 'Good' -and $recover2.Quality -eq 'Good' -and -not $recover2.Notify) 'two recovery samples re-arm silently'
    Check ($recover1.Degraded -and -not $recover2.Degraded -and $recover2.NotificationMessage -eq '' -and $recover2.LastNotification.Id -eq $firstId) 'two-sample recovery clears banner without erasing historical alert'
    $null=Tick 600; $null=Tick 650; $again=Tick 700
    Check ($again.Notify -and $again.Notification.Id -ne $firstId) 'recovered then degraded incident alerts again'
    $secondAt=[DateTimeOffset]$again.Notification.AtUtc
    $null=Tick 100; $null=Tick 100
    $null=Tick 600; $null=Tick 600; $cool=Tick 600
    Check (-not $cool.Notify) 'new incident inside five-minute cooldown is suppressed'
    Check (-not $cool.Degraded -and $cool.NotificationMessage -eq '') 'suppressed new incident does not borrow the previous alert banner'
    while (($timer.Now-$secondAt).TotalSeconds -lt 270) { $cool=Tick 700; Check (-not $cool.Notify) 'cooldown remains in force' }
    $afterCooldown=Tick 700
    Check ($afterCooldown.Notify) 'sustained new incident alerts when cooldown expires'

    $root=Join-Path $work 'freshness'; $overview=New-Overview
    $null=Tick 90 0; $timer.Now=$timer.Now.AddSeconds(76); $expired=View
    Check ($expired.Quality -eq 'Unknown' -and $expired.LatencyMs -eq $null -and $expired.Reason -eq 'SampleExpired' -and $expired.History.Count -eq 1) 'stale sample never appears as live latency'
    $timer.Now=$timer.Now.AddMinutes(31); $empty=View
    Check ($empty.History.Count -eq 0 -and $empty.LatencyMs -eq $null) 'history excludes samples older than thirty minutes'
    $calls=$data.Calls; $overview.ObservedAt=$timer.Now.AddSeconds(-16).ToString('o')
    $stale=Invoke-TCLineQualitySample -Root $root -Overview $overview -Measure $measure -MeasureData $data -Clock $clock
    Check ($stale.Reason -eq 'ObservationStale' -and $data.Calls -eq $calls) 'old overview cannot authorize probing'

    $root=Join-Path $work 'binding'; $overview=New-Overview; $null=Tick 88 0
    $bindingKey=(View).BindingKey
    $overview.NodeId='33333333-3333-3333-3333-333333333333'
    Check ((View).BindingKey -eq $bindingKey -and (View).LatencyMs -eq 88) 'unapplied desired node does not relabel actual exit'
    foreach ($change in @(
        @('ActiveLineId','44444444-4444-4444-4444-444444444444'),@('ActiveProfileId','Tcp'),@('Exit','provider2-trade'),
        @('SessionId','new-session'),@('ConfigHash',('B'*64)),@('EnginePid',54321),@('ConnectedSince','2026-10-14T01:00:00Z'),@('Mode','global')
    )) {
        $old=$overview.($change[0]); $overview.($change[0])=$change[1]; $different=View
        Check ($different.Quality -eq 'Unknown' -and $different.LatencyMs -eq $null -and $different.History.Count -eq 0 -and $different.BindingKey -ne $bindingKey) ('no cross-binding reuse: '+$change[0])
        Check (-not $different.Degraded -and $different.NotificationMessage -eq '') ('no cross-binding persistent warning: '+$change[0])
        $overview.($change[0])=$old
    }
    $calls=$data.Calls; $overview.Running=$false; $overview.StateKey='Disconnected'
    $disconnected=Invoke-TCLineQualitySample -Root $root -Overview $overview -Measure $measure -MeasureData $data -Clock $clock
    Check ($disconnected.Reason -eq 'Disconnected' -and $disconnected.History.Count -eq 0 -and $data.Calls -eq $calls) 'disconnected never measures and drops cached series'
    $overview.Running=$true; $overview.StateKey='Connected'
    Check ((View).LatencyMs -eq $null) 'reconnect cannot resurrect the cleared latency even with a reused fixture session'
    $null=Tick 95 0; $oldLine=$overview.ActiveLineId
    $overview.ActiveLineId='55555555-5555-5555-5555-555555555555'; $switched=Tick 620 0
    Check ($switched.Sampled -and $switched.History.Count -eq 1 -and $switched.Binding.NodeId -eq $overview.ActiveLineId -and -not $switched.Notify) 'switch begins a fresh series and debounce'
    $notOwned=Clear-TCLineQuality -Root $root -NodeId $oldLine -Clock $clock
    Check ($notOwned.Cleared -and (View).LatencyMs -eq 620) 'cleanup removes old-line archives and preserves the current other line'
    $owned=Clear-TCLineQuality -Root $root -NodeId $overview.ActiveLineId -Clock $clock
    Check ($owned.Cleared -and (View).LatencyMs -eq $null) 'cleanup clears only the bound line'

    $root=Join-Path $work 'failure'; $overview=New-Overview; $null=Tick 77 0
    $null=[IO.Directory]::CreateDirectory($root)
    $sentinel=Join-Path $root 'runtime.json'; [IO.File]::WriteAllText($sentinel,'fixture runtime must not change')
    $beforeHash=(Get-FileHash -LiteralPath $sentinel).Hash
    $data.Throw=$true; $fail1=Tick 70; $fail2=Tick 70; $fail3=Tick 70
    Check ($fail1.Quality -eq 'Unknown' -and $fail1.LatencyMs -eq $null -and $fail1.Reason -eq 'MeasurementFailed') 'measurement failure replaces good current value with unknown'
    Check (-not $fail1.Notify -and -not $fail2.Notify -and $fail3.Notify -and $fail3.Notification.Reason -eq 'ConsecutiveMeasurementFailures') 'consecutive unavailability alerts without claiming packet loss'
    Check ($fail3.Degraded -and $fail3.NotificationMessage.Contains('质量未知')) 'latched measurement failure remains explicitly unknown'
    Check (-not (ConvertTo-Json -InputObject $fail3 -Depth 10).Contains('fixture-secret') -and (Get-FileHash -LiteralPath $sentinel).Hash -ceq $beforeHash) 'failure is sanitized and cannot change network/runtime state'
    $data.Throw=$false
    foreach ($value in @($null,0,-1,[double]::NaN,[double]::PositiveInfinity,'90',$true)) {
        $invalid=Tick $value
        Check ($invalid.Quality -eq 'Unknown' -and $null -eq $invalid.LatencyMs) 'invalid or missing delay is unknown'
    }
    $data.Source='IcmpPing'; $ping=Tick 25
    Check ($ping.Quality -eq 'Unknown' -and $ping.LatencyMs -eq $null) 'ICMP cannot be passed off as selected-exit measurement'
    $data.Source='ControllerDelay'; $data.WrongKey=$true; $wrong=Tick 30
    Check ($wrong.Quality -eq 'Unknown' -and $wrong.LatencyMs -eq $null) 'callback results from another context are rejected'
    $data.WrongKey=$false
    $null=Tick 75; $data.Status='ContextChanged'; $changed=Tick 75
    Check ($changed.Reason -eq 'BindingChanged' -and $changed.History.Count -eq 0 -and $changed.LatencyMs -eq $null) 'during-measurement binding change discards the whole old series'
    $data.Status='Measured'; $data.Action='Clear'; $data.Root=$root; $clearedDuringProbe=Tick 90
    Check ($clearedDuringProbe.Reason -eq 'BindingChanged' -and (View).LatencyMs -eq $null) 'disconnect/cleanup revision rejects an in-flight late result'
    $data.Action=''

    $root=Join-Path $work 'overlap'; $overview=New-Overview
    $data.Action='Overlap'; $data.Root=$root; $data.Overview=$overview; $data.Now=$timer.Now
    $overlap=Tick 80 0
    Check ($overlap.Sampled -and $overlap.Quality -eq 'Good' -and $data.Nested.SkipReason -eq 'SamplingBusy') 'a concurrent sampler returns cache without starting another measurement'
    $data.Action='Disconnect'; $data.Overview=New-Overview; $data.Overview.Running=$false; $data.Overview.StateKey='Disconnected'
    $data.Now=$timer.Now.AddSeconds(30); $duringDisconnect=Tick 85
    Check ($duringDisconnect.Reason -eq 'BindingChanged' -and $data.Nested.Reason -eq 'Disconnected' -and (View).History.Count -eq 0) 'disconnect observation invalidates even while sampler mutex is held'
    $data.Action=''

    $root=Join-Path $work 'debounce'; $overview=New-Overview
    $null=Tick 700 0; $null=Tick 800; $gap=Tick 900 76
    Check (-not $gap.Notify) 'gap resets consecutive bad count'
    $null=Tick 400; $null=Tick 700; $null=Tick 700; $boundary=Tick 499
    Check (-not $boundary.Notify -and $boundary.Quality -eq 'Fair') 'below bad threshold breaks the bad streak'
    $null=Tick 500; $null=Tick 500; $boundary=Tick 500
    Check ($boundary.Notify -and $boundary.Quality -eq 'Poor') '500ms is an inclusive bad threshold'
    $null=Tick 350; $null=Tick 400; $null=Tick 350; $notRecovered=Tick 800
    Check (-not $notRecovered.Notify) 'middle band breaks recovery streak and preserves latch'
    $root=Join-Path $work 'settings'; $overview=New-Overview
    $null=Tick 650 0 $false; $null=Tick 650 30 $false; $muted=Tick 650 30 $false
    Check ($muted.Quality -eq 'Poor' -and -not $muted.Notify -and $muted.History.Count -eq 3) 'notifications may be disabled without disabling measurement'
    $calls=$data.Calls
    $disabled=Invoke-TCLineQualitySample -Root $root -Overview $overview -Enabled $false -Measure $measure -MeasureData $data -Clock $clock
    Check ($disabled.Reason -eq 'Disabled' -and $disabled.History.Count -eq 0 -and $data.Calls -eq $calls) 'disabled setting never probes or leaves a good current value'
    Check (-not $disabled.Degraded -and $disabled.NotificationMessage -eq '') 'disabled setting has no persistent warning'

    $root=Join-Path $work 'retention'; $overview=New-Overview
    for ($i=0; $i -lt 65; $i++) { $retained=Tick (80+$i) 30 }
    $cache=Join-Path $root 'Product\line-quality.json'; $stored=[IO.File]::ReadAllText($cache)|ConvertFrom-Json
    Check ($retained.History.Count -eq 60 -and $stored.Samples.Count -eq 65 -and $stored.Samples[0].LatencyMs -eq 80 -and $retained.Day.Statistics.SampleCount -eq 65 -and (Get-Item -LiteralPath $cache).Length -lt 1048576) 'thirty-minute view retains sixty samples while the day store preserves older history'
    Check (@(Get-ChildItem -LiteralPath (Split-Path $cache -Parent) -Filter '.tc-*.tmp').Count -eq 0) 'atomic write temporaries are cleaned'
    $cacheBytes=[IO.File]::ReadAllBytes($cache)
    Check ($cacheBytes[0] -eq 239 -and $cacheBytes[1] -eq 187 -and $cacheBytes[2] -eq 191) 'store uses UTF8 BOM'
    $timer.Now=$timer.Now.AddSeconds(-60); $clockBack=Tick 90 0
    Check ($clockBack.Sampled -and $clockBack.History.Count -eq 1) 'clock rollback drops future samples and debounce state'
    $held=[IO.File]::Open((Join-Path $root 'Product\.store.lock'),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {
        $calls=$data.Calls; $budget=[Diagnostics.Stopwatch]::StartNew(); $busy=Tick 90
        Check ($busy.Reason -eq 'StoreBusy' -and $data.Calls -eq $calls -and $budget.ElapsedMilliseconds -lt 1000) 'store contention skips immediately without blocking engine operations'
    } finally { $held.Dispose() }
    $before=[IO.File]::ReadAllText($cache); [IO.File]::WriteAllText($cache,'{"Owner":"someone-else","secret":"fixture-secret"}')
    $corruptBytes=[IO.File]::ReadAllText($cache); $calls=$data.Calls; $corrupt=Tick 90
    Check ($corrupt.Quality -eq 'Unknown' -and $corrupt.Reason -eq 'StoreUnavailable' -and $data.Calls -eq $calls -and [IO.File]::ReadAllText($cache) -ceq $corruptBytes) 'foreign/corrupt store is preserved, not silently overwritten'
    [IO.File]::WriteAllText($cache,$before,(New-Object Text.UTF8Encoding($true)))
    $forged=$before|ConvertFrom-Json; $forged.Samples[-1].Quality='Poor'
    [IO.File]::WriteAllText($cache,($forged|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($true)))
    $inconsistent=View
    Check ($inconsistent.Quality -eq 'Unknown' -and $inconsistent.Reason -eq 'StoreUnavailable' -and -not $inconsistent.Degraded) 'cache quality cannot contradict the measured numeric value'
    [IO.File]::WriteAllText($cache,$before,(New-Object Text.UTF8Encoding($true)))

    $root=Join-Path $work 'timeout'; $overview=New-Overview; $data.SleepMs=10000
    $watch=[Diagnostics.Stopwatch]::StartNew()
    $timed=Invoke-TCLineQualitySample -Root $root -Overview $overview -Measure $measure -MeasureData $data -Clock $clock -BudgetMilliseconds 250
    Check ($timed.Quality -eq 'Unknown' -and $timed.Reason -eq 'MeasurementTimeout' -and $timed.LatencyMs -eq $null -and $watch.ElapsedMilliseconds -lt 2000) 'hanging measurement is cancelled within its bounded budget'
    $timeoutElapsed=$watch.ElapsedMilliseconds; $data.SleepMs=0; $afterTimeout=Tick 95
    Check ($afterTimeout.Sampled -and $afterTimeout.Quality -eq 'Good') 'sampling can recover after a cancelled callback'

    # Exercise actual on-disk runtime/config binding with THIS test process as
    # both fixture identities. No engine is started and no controller is called.
    $runtimeRoot=Join-Path $work 'runtime-binding'; $null=[IO.Directory]::CreateDirectory($runtimeRoot)
    $configPath=Join-Path $runtimeRoot 'candidate.json'; $manifestPath=Join-Path $runtimeRoot 'manifest.json'
    [IO.File]::WriteAllText($configPath,'{"fixture":"owned"}')
    $hash=(Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash
    $process=Get-Process -Id $PID
    try { $born=$process.StartTime.ToUniversalTime().ToString('o') } finally { $process.Dispose() }
    $runtime=@{State='Running';SessionId='fixture-runtime';EnginePid=$PID;SupervisorPid=$PID;EngineStartedAt=$born;SupervisorStartedAt=$born;ManifestPath=$manifestPath;ConfigPath=$configPath}
    $deployment=@{ManifestPath=$manifestPath;LineId='11111111-1111-1111-1111-111111111111';ProfileId='Udp'}
    [IO.File]::WriteAllText($manifestPath,(@{CandidatePath=$configPath;CandidateSHA256=$hash}|ConvertTo-Json))
    [IO.File]::WriteAllText((Join-Path $runtimeRoot 'runtime.json'),($runtime|ConvertTo-Json))
    [IO.File]::WriteAllText((Join-Path $runtimeRoot 'deployment.json'),($deployment|ConvertTo-Json))
    $runtimeOverview=New-Overview
    $runtimeOverview.EnginePid=$PID; $runtimeOverview.ConnectedSince=$born; $runtimeOverview.SessionId='fixture-runtime'
    $runtimeOverview.ConfigHash=$hash; $runtimeOverview.ManifestPath=$manifestPath; $runtimeOverview.ObservedAt=[DateTimeOffset]::UtcNow.ToString('o')
    $runtimeContext=Get-TCLineQualityContext $runtimeOverview
    $boundConfig=& $module {param($r,$c) LQRuntimeConfig $r $c} $runtimeRoot $runtimeContext
    Check ($runtimeContext.Eligible -and $boundConfig.fixture -eq 'owned') 'runtime adapter binds explicit root, exact process births and configuration hash'
    foreach ($field in @('SessionId','EngineStartedAt','SupervisorStartedAt','ConfigPath')) {
        $prior=$runtime[$field]
        $runtime[$field]=switch ($field) { 'SessionId' {'other-session'}; 'ConfigPath' {Join-Path $runtimeRoot 'other.json'}; default {'2000-01-01T00:00:00Z'} }
        [IO.File]::WriteAllText((Join-Path $runtimeRoot 'runtime.json'),($runtime|ConvertTo-Json))
        $rejected=$false
        try { $null=& $module {param($r,$c) LQRuntimeConfig $r $c} $runtimeRoot $runtimeContext } catch { $rejected=$true }
        Check $rejected ('runtime adapter rejects changed '+$field)
        $runtime[$field]=$prior
    }
    [IO.File]::WriteAllText((Join-Path $runtimeRoot 'runtime.json'),($runtime|ConvertTo-Json))
    [IO.File]::WriteAllText($configPath,'{"fixture":"replaced"}')
    $rejected=$false
    try { $null=& $module {param($r,$c) LQRuntimeConfig $r $c} $runtimeRoot $runtimeContext } catch { $rejected=$true }
    Check $rejected 'runtime adapter rejects configuration contents replaced under the same path'

    # Test the actual adapter logic with in-memory fake transport/runtime. No
    # local TCP listener, real controller, DNS, ping, curl or tunnel is used.
    $adapter=@{
        Paths=(New-Object 'Collections.Generic.List[string]'); ReadCount=0; Exit='hk'; AfterExit='hk'; Delay=123; ChangeRuntime=$false
        Config=[pscustomobject]@{
            experimental=@{clash_api=@{external_controller='127.0.0.1:17891'; secret='fixture-secret'}}
            outbounds=@(@{tag='trade-exit';type='selector';outbounds=@('hk','provider2-trade')},@{tag='provider2-trade';type='socks'})
            endpoints=@(@{tag='hk';type='wireguard'})
        }
    }
    & $module {
        param($Fixture)
        $script:LQTestAdapter=$Fixture
        function script:LQRuntimeConfig {
            param($Root,$Context)
            $script:LQTestAdapter.ReadCount++
            if ($script:LQTestAdapter.ChangeRuntime -and $script:LQTestAdapter.ReadCount -gt 1) { throw 'fixture runtime replaced' }
            $script:LQTestAdapter.Config
        }
        function script:LQHttpGet {
            param($Client,$BaseUrl,$Path,$Watch,$BudgetMilliseconds,$RequestMilliseconds)
            $script:LQTestAdapter.Paths.Add($Path)
            if ($BaseUrl -cne 'http://127.0.0.1:17891' -or $Client.DefaultRequestHeaders.Authorization.Scheme -cne 'Bearer') { throw 'Wrong local controller.' }
            if ($Path -eq '/proxies/trade-exit') {
                if ($script:LQTestAdapter.Paths.Count -gt 1) { return @{now=$script:LQTestAdapter.AfterExit} }
                return @{now=$script:LQTestAdapter.Exit}
            }
            @{delay=$script:LQTestAdapter.Delay}
        }
    } $adapter
    $overview=New-Overview; $context=Get-TCLineQualityContext $overview $timer.Now
    $result=& $module {param($r,$c) LQControllerMeasure $r $c ([Diagnostics.Stopwatch]::StartNew()) 7000} $work $context
    Check ($result.Status -eq 'Measured' -and $result.LatencyMs -eq 123 -and $adapter.Paths.Count -eq 3 -and $adapter.Paths[1].StartsWith('/proxies/hk/delay?') -and $adapter.Paths[1].Contains([Uri]::EscapeDataString('https://1.1.1.1/cdn-cgi/trace'))) 'adapter pins selected hk outbound and uses existing HTTPS delay target'
    $adapter.Paths.Clear(); $adapter.ReadCount=0; $adapter.Exit='provider2-trade'; $adapter.AfterExit='provider2-trade'
    $overview.Exit='provider2-trade'; $context=Get-TCLineQualityContext $overview $timer.Now
    $result=& $module {param($r,$c) LQControllerMeasure $r $c ([Diagnostics.Stopwatch]::StartNew()) 7000} $work $context
    Check ($result.Status -eq 'Measured' -and $adapter.Paths[1].StartsWith('/proxies/provider2-trade/delay?')) 'adapter measures selected provider exit instead of hk or daily selector'
    $adapter.Paths.Clear(); $adapter.ReadCount=0; $adapter.Exit='hk'
    $result=& $module {param($r,$c) LQControllerMeasure $r $c ([Diagnostics.Stopwatch]::StartNew()) 7000} $work $context
    Check ($result.Status -eq 'ContextChanged' -and $adapter.Paths.Count -eq 1) 'selector mismatch prevents any delay request'
    $adapter.Paths.Clear(); $adapter.ReadCount=0; $adapter.Exit='provider2-trade'; $adapter.AfterExit='hk'
    $result=& $module {param($r,$c) LQControllerMeasure $r $c ([Diagnostics.Stopwatch]::StartNew()) 7000} $work $context
    Check ($result.Status -eq 'ContextChanged' -and $null -eq $result.LatencyMs) 'selector change after delay discards result'
    $adapter.Paths.Clear(); $adapter.ReadCount=0; $adapter.AfterExit='provider2-trade'; $adapter.ChangeRuntime=$true
    $result=& $module {param($r,$c) LQControllerMeasure $r $c ([Diagnostics.Stopwatch]::StartNew()) 7000} $work $context
    Check ($result.Status -eq 'ContextChanged' -and $null -eq $result.LatencyMs) 'session/config replacement after delay discards result'
    $adapter.Paths.Clear(); $adapter.ReadCount=0; $adapter.ChangeRuntime=$false; $adapter.Delay=0
    $result=& $module {param($r,$c) LQControllerMeasure $r $c ([Diagnostics.Stopwatch]::StartNew()) 7000} $work $context
    Check ($result.Status -eq 'Unavailable' -and $null -eq $result.LatencyMs) 'controller delay zero is unknown, never excellent'
    Check (-not (ConvertTo-Json -InputObject $result -Depth 8).Contains('fixture-secret')) 'controller credentials never escape evidence'

    [pscustomobject]@{
        Passed=$true; Checks=$script:Checks; PowerShellVersion=$PSVersionTable.PSVersion.ToString()
        ProductionNetworkProbes=0; ProductionRootAccesses=0; NetworkChanges=0
        MeasurementBudgetMs=250; TimeoutObservedMs=$timeoutElapsed; RetentionSamples=2880; RetentionSeconds=86400
    }
} finally {
    Remove-Module $module -ErrorAction SilentlyContinue
    # Only the exact freshly created fixture directory is eligible for deletion.
    $resolved=[IO.Path]::GetFullPath($work).TrimEnd('\')
    if (-not $resolved.StartsWith(($fixtureBase+'\'),[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -cnotmatch '^TC-LineQuality-[a-f0-9]{32}$') { throw 'Refusing fixture cleanup outside the owned temporary directory.' }
    if ([IO.Directory]::Exists($resolved)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
