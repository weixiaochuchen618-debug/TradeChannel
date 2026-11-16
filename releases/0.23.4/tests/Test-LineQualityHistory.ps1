#requires -Version 5.1
# Isolated schema migration, retention, ownership and aggregate checks. No network.
[CmdletBinding()]param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$package=Split-Path $PSScriptRoot -Parent
$modulePath=Join-Path $package 'LineQuality.psm1'
$module=Import-Module $modulePath -Force -PassThru -DisableNameChecking
$fixtureBase=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$work=Join-Path $fixtureBase ('TC-QualityHistory-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($work)
$script:Checks=0
$timer=@{Now=[DateTimeOffset]'2026-10-16T12:00:00Z'}
$clock={ $timer.Now }.GetNewClosure()
$data=@{Calls=0; Root=''; ModulePath=$modulePath; RemoveId=''; Latency=90}
$measure={
    param($Context,$BudgetMilliseconds,$Data)
    $Data.Calls++
    if ($Data.RemoveId) { Import-Module $Data.ModulePath -DisableNameChecking; $null=Clear-TCLineQuality -Root $Data.Root -NodeId $Data.RemoveId }
    @{Status='Measured'; Reason='Measured'; ContextKey=$Context.Key; Outbound=$Context.Binding.Exit; Source='ControllerDelay'; LatencyMs=$Data.Latency}
}
function Check { param([bool]$Ok,[string]$Label) if (-not $Ok) { throw ('QualityHistory check failed: '+$Label) }; $script:Checks++ }
function Overview {
    [pscustomobject]@{Running=$true;StateKey='Connected';SessionId='history-session';ActiveLineId='11111111-1111-1111-1111-111111111111';ActiveProfileId='Udp';ProfileBindingVerified=$true;NodeId='99999999-9999-9999-9999-999999999999';Exit='hk';ConfigHash=('A'*64);EnginePid=1234;ConnectedSince='2026-10-10T00:00:00Z';ManifestPath=(Join-Path $work 'manifest.json');Mode='rule';ObservedAt=$timer.Now.ToString('o')}
}
function Sample {
    param($At,[int]$Ms=80,[string]$Reason='Measured')
    [pscustomobject]@{AtUtc=([DateTimeOffset]$At).ToString('o');LatencyMs=$(if ($Reason -eq 'Measured') {$Ms} else {$null});Quality=$(if ($Reason -ne 'Measured') {'Unknown'} elseif ($Ms -ge 500) {'Poor'} elseif ($Ms -gt 200) {'Fair'} else {'Good'});Reason=$Reason;Source='ControllerDelay'}
}
function Seed {
    param([string]$Root,$State)
    $product=Join-Path $Root 'Product'; $null=[IO.Directory]::CreateDirectory($product)
    [IO.File]::WriteAllText((Join-Path $product 'line-quality.json'),(ConvertTo-Json -InputObject $State -Depth 10 -Compress),(New-Object Text.UTF8Encoding($true)))
}
function New-State {
    param($Overview)
    $state=& $module { LQNewState }; $context=Get-TCLineQualityContext $Overview $timer.Now
    $state.BindingKey=$context.Key; $state.Binding=$context.Binding; $state
}
function Tick {
    param([int]$Seconds=30)
    $timer.Now=$timer.Now.AddSeconds($Seconds); $overview.ObservedAt=$timer.Now.ToString('o')
    Invoke-TCLineQualitySample -Root $root -Overview $overview -Clock $clock -Measure $measure -MeasureData $data
}
try {
    foreach ($file in @($modulePath,$PSCommandPath)) {
        $bytes=[IO.File]::ReadAllBytes($file)
        Check ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) ('UTF8 BOM '+[IO.Path]::GetFileName($file))
        $tokens=$null; $errors=$null; $null=[Management.Automation.Language.Parser]::ParseFile($file,[ref]$tokens,[ref]$errors)
        Check (@($errors).Count -eq 0) ('PowerShell parser '+[IO.Path]::GetFileName($file))
    }
    $overview=Overview; $root=Join-Path $work 'migration'; $state=New-State $overview
    $state.SchemaVersion=1; $state.PSObject.Properties.Remove('SeriesId'); $state.PSObject.Properties.Remove('ArchivedSeries')
    $state.Samples=@((Sample $timer.Now.AddSeconds(-60) 70),(Sample $timer.Now.AddSeconds(-30) 90),(Sample $timer.Now 110))
    $state.LastAttemptAtUtc=$timer.Now.ToString('o'); $state.BadCount=2
    $state.LastAlert=[pscustomobject]@{Id=('a'*32);AtUtc=$timer.Now.AddMinutes(-1).ToString('o');Reason='ConsecutiveHighLatency';Message='untrusted fixture message'}
    $state.AlertLatched=$true
    Seed $root $state; $path=Join-Path $root 'Product\line-quality.json'; $before=[IO.File]::ReadAllText($path); $revision=$state.Revision
    $view=Get-TCLineQualitySummary -Root $root -Overview $overview -Clock $clock
    Check ($view.SchemaVersion -eq 2 -and $view.History.Count -eq 3 -and $view.LatencyMs -eq 110 -and $view.Degraded) 'Schema 1 preserves matching history and incident state in memory'
    Check ([IO.File]::ReadAllText($path) -ceq $before -and -not (ConvertTo-Json -InputObject $view -Depth 12).Contains('untrusted fixture')) 'summary migration is read-only and sanitizes alert text'
    $migrated=Tick 0; $disk=[IO.File]::ReadAllText($path)|ConvertFrom-Json
    Check (-not $migrated.Sampled -and $data.Calls -eq 0 -and $disk.SchemaVersion -eq 2 -and $disk.Samples.Count -eq 3 -and $disk.Revision -ceq $revision) 'first write upgrades legacy cache without measuring early or losing reservation identity'
    Check ($disk.BadCount -eq 2 -and $disk.AlertLatched -and $disk.SeriesId -eq $revision) 'legacy debounce and series origin survive migration'

    $root=Join-Path $work 'day'; $overview=Overview; $state=New-State $overview
    $state.Samples=@(for ($i=1; $i -le 2880; $i++) { Sample $timer.Now.AddSeconds(-86400+30*$i) (60+($i%100)) })
    $state.LastAttemptAtUtc=$timer.Now.ToString('o'); Seed $root $state
    $readWatch=[Diagnostics.Stopwatch]::StartNew(); $view=Get-TCLineQualitySummary -Root $root -Overview $overview -Clock $clock; $fullDayReadMs=$readWatch.ElapsedMilliseconds
    Check ($view.History.Count -eq 60 -and $view.Day.Statistics.SampleCount -eq 2880 -and $view.ThirtyMinutes.Statistics.SampleCount -eq 60) '24 hours retain 2880 samples and thirty minutes select sixty'
    Check ($view.Day.Buckets.Count -eq 96 -and $view.ThirtyMinutes.Buckets.Count -eq 60 -and ($view.Day.Buckets|Measure-Object SampleCount -Sum).Sum -eq 2880) 'bounded aggregates conserve samples across all buckets'
    Check (@($view.Day.Buckets|Where-Object {$_.SampleCount -ne 30}).Count -eq 0 -and @($view.ThirtyMinutes.Buckets|Where-Object {$_.SampleCount -ne 1}).Count -eq 0) 'exact interval boundaries use left-open right-closed buckets without empty first or doubled last slot'
    $sampleWatch=[Diagnostics.Stopwatch]::StartNew(); $view=Tick 30; $fullDaySampleMs=$sampleWatch.ElapsedMilliseconds; $path=Join-Path $root 'Product\line-quality.json'; $disk=[IO.File]::ReadAllText($path)|ConvertFrom-Json
    Check ($view.Sampled -and $disk.Samples.Count -eq 2880 -and ([DateTimeOffset]$disk.Samples[0].AtUtc) -gt $timer.Now.AddHours(-24) -and ([DateTimeOffset]$disk.Samples[-1].AtUtc) -eq $timer.Now) 'append prunes the exact 24-hour boundary and preserves newest sample'
    Check ((Get-Item -LiteralPath $path).Length -le 1048576 -and @(Get-ChildItem -LiteralPath (Split-Path $path -Parent) -Filter '.tc-*.tmp').Count -eq 0) 'day cache fits one MiB with no atomic write debris'
    $dayBytes=(Get-Item -LiteralPath $path).Length
    $timer.Now=$timer.Now.AddHours(24); $overview.ObservedAt=$timer.Now.ToString('o')
    $empty=Get-TCLineQualitySummary -Root $root -Overview $overview -Clock $clock
    Check ($empty.Day.Statistics.SampleCount -eq 0 -and $null -eq $empty.LatencyMs -and $empty.History.Count -eq 0) '24-hour exact boundary is excluded even without a writer'

    $root=Join-Path $work 'aggregates'; $overview=Overview; $state=New-State $overview
    $state.Samples=@((Sample $timer.Now.AddSeconds(-1800) 999),(Sample $timer.Now.AddSeconds(-120) 100),(Sample $timer.Now.AddSeconds(-90) 300),(Sample $timer.Now.AddSeconds(-60) 0 'MeasurementTimeout'),(Sample $timer.Now.AddSeconds(-30) 0 'ControllerUnavailable'),(Sample $timer.Now 500))
    $state.LastAttemptAtUtc=$timer.Now.ToString('o'); Seed $root $state
    $aggregate=(Get-TCLineQualitySummary -Root $root -Overview $overview -Clock $clock).ThirtyMinutes
    Check ($aggregate.Statistics.SampleCount -eq 5 -and $aggregate.Statistics.MeasuredCount -eq 3 -and $aggregate.Statistics.UnavailableCount -eq 2 -and $aggregate.Statistics.TimeoutCount -eq 1) 'timeouts/unavailable are counted without inventing packet loss'
    Check ($aggregate.Statistics.AverageLatencyMs -eq 300 -and $aggregate.Statistics.MinLatencyMs -eq 100 -and $aggregate.Statistics.MaxLatencyMs -eq 500 -and $aggregate.Statistics.P95LatencyMs -eq 500) 'latency aggregates include measured values only'
    Check (@($aggregate.Buckets | Where-Object { $_.SampleCount -eq 0 -and $null -ne $_.AverageLatencyMs }).Count -eq 0) 'empty buckets remain null rather than zero latency'

    $root=Join-Path $work 'ownership'; $overview=Overview; $first=Tick 0; $nodeA=$overview.ActiveLineId
    $overview.ActiveProfileId='Tcp'; $tcp=Tick
    $overview.Exit='provider2-trade'; $provider=Tick
    $overview.SessionId='new-session'; $session=Tick
    $overview.ActiveLineId='22222222-2222-2222-2222-222222222222'; $nodeB=$overview.ActiveLineId; $other=Tick
    $history=Get-TCLineQualityHistory -Root $root -Window Day -Clock $clock
    Check ($history.Series.Count -eq 5 -and @($history.Series.BindingKey|Sort-Object -Unique).Count -eq 5 -and $history.HistoricalOnly) 'session/profile/exit/node transitions retain separate provenance'
    Check (@((Get-TCLineQualityHistory -Root $root -NodeId $nodeA -ProfileId Tcp -Exit provider2-trade -Clock $clock).Series).Count -eq 2) 'history filters retain both sessions without merging their samples'
    Check ($other.History.Count -eq 1 -and $other.Day.Statistics.SampleCount -eq 1 -and $other.Binding.NodeId -eq $nodeB) 'current view cannot borrow archived line samples'
    $clear=Clear-TCLineQuality -Root $root -NodeId $nodeA -Clock $clock
    $history=Get-TCLineQualityHistory -Root $root -Clock $clock
    Check ($clear.Cleared -and $clear.RemovedSeries -eq 4 -and $history.Series.Count -eq 1 -and $history.Series[0].Binding.NodeId -eq $nodeB) 'delete removes all profiles/exits/sessions owned by a line and preserves another line'
    $overview.Running=$false; $overview.StateKey='Disconnected'; $disconnected=Tick
    Check ($disconnected.History.Count -eq 0 -and $null -eq $disconnected.LatencyMs -and (Get-TCLineQualityHistory -Root $root -Clock $clock).Series.Count -eq 1) 'disconnect invalidates live latency while preserving historical evidence'
    $overview.Running=$true; $overview.StateKey='Connected'; $overview.ObservedAt=$timer.Now.ToString('o')
    Check ($null -eq (Get-TCLineQualitySummary -Root $root -Overview $overview -Clock $clock).LatencyMs) 'same-key fixture reconnect cannot revive archived live latency'
    $null=Tick; $clear=Clear-TCLineQuality -Root $root -PreserveHistory -Clock $clock
    Check ($clear.Cleared -and (Get-TCLineQualityHistory -Root $root -Clock $clock).Series.Count -eq 2) 'explicit invalidation archives rather than silently truncating history'
    $lock=[IO.File]::Open((Join-Path $root 'Product\.store.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {
        $clear=Clear-TCLineQuality -Root $root -NodeId $nodeB -StoreLock $lock -Clock $clock
        Check ($clear.Cleared -and $lock.CanWrite -and (Get-TCLineQualityHistory -Root $root -Clock $clock).Series.Count -eq 0) 'cleanup uses caller exclusive lock without releasing it'
        $wrong=Clear-TCLineQuality -Root (Join-Path $work 'wrong-root') -NodeId $nodeB -StoreLock $lock -Clock $clock
        Check (-not $wrong.Cleared -and -not (Test-Path -LiteralPath (Join-Path $work 'wrong-root'))) 'wrong-root lock cannot authorize writes'
    } finally { $lock.Dispose() }
    $root=Join-Path $work 'inflight-delete'; $overview=Overview; $data.Root=$root; $data.RemoveId=$overview.ActiveLineId
    $late=Tick 0; $data.RemoveId=''
    Check ($late.Reason -eq 'BindingChanged' -and (Get-TCLineQualityHistory -Root $root -Clock $clock).Series.Count -eq 0) 'targeted deletion rejects an in-flight reservation even before its first sample'

    $root=Join-Path $work 'rapid-switches'; $overview=Overview; $state=New-State $overview
    $state.Samples=@(Sample $timer.Now 90); $state.LastAttemptAtUtc=$timer.Now.ToString('o')
    $archives=@(for ($i=0; $i -lt 63; $i++) {
        $old=New-State $overview; $old.SeriesId=([guid]::NewGuid().ToString('N'))
        $samples=@(for ($j=0; $j -lt 45; $j++) { Sample $timer.Now.AddSeconds(-3000+30*$j+$i) 80 })
        [pscustomobject]@{SeriesId=$old.SeriesId;BindingKey=$old.BindingKey;Binding=$old.Binding;Samples=$samples}
    })
    $state.ArchivedSeries=$archives; Seed $root $state
    $overview.SessionId='capacity-switch'; $capacity=Tick
    $disk=[IO.File]::ReadAllText((Join-Path $root 'Product\line-quality.json'))|ConvertFrom-Json
    $count=$disk.Samples.Count; foreach ($series in $disk.ArchivedSeries) { $count+=$series.Samples.Count }
    Check ($capacity.Sampled -and $disk.ArchivedSeries.Count -le 63 -and $count -le 2880) 'rapid switches obey global series and sample bounds'
    $root=Join-Path $work 'global-cap'; $overview=Overview; $state=New-State $overview
    $state.Samples=@(for ($i=0; $i -lt 1440; $i++) { Sample $timer.Now.AddSeconds(-43170+30*$i) 80 }); $state.LastAttemptAtUtc=$timer.Now.ToString('o')
    $old=New-State $overview
    $state.ArchivedSeries=@([pscustomobject]@{SeriesId=$old.SeriesId;BindingKey=$old.BindingKey;Binding=$old.Binding;Samples=@(for ($i=0; $i -lt 1440; $i++) { Sample $timer.Now.AddSeconds(-43200+30*$i) 90 })})
    Seed $root $state; $null=Tick
    $disk=[IO.File]::ReadAllText((Join-Path $root 'Product\line-quality.json'))|ConvertFrom-Json
    Check (($disk.Samples.Count+$disk.ArchivedSeries[0].Samples.Count) -eq 2880 -and ([DateTimeOffset]$disk.ArchivedSeries[0].Samples[0].AtUtc) -gt $timer.Now.AddSeconds(-43230)) 'sample cap drops globally oldest evidence across series'
    $badPath=Join-Path $root 'Product\line-quality.json'; $disk.ArchivedSeries[0].Binding.ProfileId='UdpCorrupt'; Seed $root $disk; $badBytes=[IO.File]::ReadAllText($badPath)
    $bad=Get-TCLineQualityHistory -Root $root -Clock $clock
    Check ($bad.Reason -eq 'StoreUnavailable' -and $bad.Series.Count -eq 0 -and [IO.File]::ReadAllText($badPath) -ceq $badBytes) 'corrupted archived ownership is rejected without mutation'
    [pscustomobject]@{Passed=$true;Checks=$script:Checks;PowerShellVersion=$PSVersionTable.PSVersion.ToString();DaySamples=2880;DayStoreBytes=$dayBytes;FullDayReadMs=$fullDayReadMs;FullDaySampleMs=$fullDaySampleMs;ProductionNetworkProbes=0;ProductionRootAccesses=0;NetworkChanges=0}
} finally {
    Remove-Module $module -ErrorAction SilentlyContinue
    $resolved=[IO.Path]::GetFullPath($work).TrimEnd('\')
    if (-not $resolved.StartsWith(($fixtureBase+'\'),[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -cnotmatch '^TC-QualityHistory-[a-f0-9]{32}$') { throw 'Unsafe fixture cleanup.' }
    if ([IO.Directory]::Exists($resolved)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
