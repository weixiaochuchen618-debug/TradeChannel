#requires -Version 5.1
Set-StrictMode -Version 2
$script:LQPackage = $PSScriptRoot
$script:LQRetiredWorker = $null
$script:LQMaxSamples = 2880
$script:LQMaxSeries = 64
$script:LQMaxStoreBytes = 1048576

<#
Integration (run in a silent worker, never on the UI/engine/supervisor thread):
  Invoke-TCLineQualitySample -Root $paths.Root -Overview (Get-TCOverview)
  Get-TCLineQualitySummary -Root $paths.Root -Overview $overview # no network
  Clear-TCLineQuality -Root $paths.Root -PreserveHistory # disconnect/switch
  Get-TCLineQualityHistory -Root $paths.Root -NodeId $lineId -Window Day
Settings are caller-owned: Enabled / NotifyEnabled. No setting is written here.
UI must compare BindingKey with (Get-TCLineQualityContext $latestOverview).Key.
Notify is an at-most-once delivery hint; summary reads never replay a toast.
Degraded/NotificationMessage represent a latched incident only while its binding
matches and its latest sample is fresh. LastNotification is history, not a banner.

Store ownership: Root/Product/line-quality.json, Owner=TradeChannel.LineQuality.
Schema 2 keeps separate session/line/profile/exit series for a rolling 24 hours:
at most 2880 samples TOTAL, 64 series TOTAL and 1 MiB on disk. History remains
the current series' last 30 minutes for existing callers. ThirtyMinutes / Day
contain bounded aggregates. Get-TCLineQualityHistory reads archived series,
including while disconnected; it never presents historical data as live.
Schema 1 is validated and migrated in memory, then persisted on the next write.
NodeId is the verified ActiveLineId, never the desired NodeId. The store allows
this exact filename (regular file, no reparse point). Writes take .store.lock
without waiting, use its existing .tc-<guid>.tmp convention, then atomically
replace. No file lock is held during network measurement. A named Local mutex
excludes concurrent samplers; a persisted Revision invalidates late results.
Cleanup must include ALL archived and current Binding.NodeId values, not just
the active binding. Clear-TCLineQuality -NodeId <family IDs> removes only those
series and advances Revision. Under an existing exclusive .store.lock, pass
its open FileStream as -StoreLock (never a boolean bypass). Do not restore this
cache on undo/import. Without NodeId, Clear removes everything unless the
caller explicitly requests PreserveHistory, which only invalidates live data.
For a journal preview, use Remove-TCLineQualityOwnedState -State $alreadyRead
-NodeId $familyIds. It performs no I/O and returns {Changed,Value,Empty}.
Value/Revision/SeriesId are deterministic for normalized IDs; Empty permits a
whole-file delete only when Changed=true and no other ownership remains.

Measure is a trusted TEST seam executed in an isolated runspace (no closures):
  param($Context, $BudgetMilliseconds, $Data)
  return @{Status='Measured'; ContextKey=$Context.Key; Outbound=$Context.Binding.Exit;
           Source='ControllerDelay'; LatencyMs=100; Reason='Measured'}
Use MeasureData for fixtures, Clock for state timestamps. Neither is accepted
from a worker's JSON request. The production adapter uses the SAME controller
delay API and HTTPS target as RuntimeBridge.Get-TCExitLatency. It additionally
pins the concrete selected outbound and checks both sides of the measurement.
This is HTTPS round-trip latency (including TLS), not ICMP, loss, trading order
latency, or proof of a server's public IP. No engine/config/route writes exist.
#>

function LQField {
    param($Value, [string]$Name, $Default=$null)
    if ($Value -is [Collections.IDictionary]) { if ($Value.Contains($Name)) { return $Value[$Name] } }
    elseif ($null -ne $Value -and $Value.PSObject.Properties[$Name]) { return $Value.$Name }
    return $Default
}
function LQNow {
    param([scriptblock]$Clock)
    if ($Clock) { return ([DateTimeOffset](& $Clock)).ToUniversalTime() }
    [DateTimeOffset]::UtcNow
}
function LQDate {
    param($Value)
    $date=[DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse([string]$Value,[ref]$date)) { return $date.ToUniversalTime() }
    return $null
}
function LQHash {
    param([string]$Text)
    $sha=[Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}
function LQPath {
    param([string]$Path)
    if ($Path -notmatch '^[A-Za-z]:[\\/]') { throw '[TC:LineQualityPath] A local absolute path is required.' }
    $full=[IO.Path]::GetFullPath($Path)
    if ($full.Substring(2) -match '[:*?"<>|\x00-\x1f]') { throw '[TC:LineQualityPath] Invalid local path.' }
    $cursor=$full
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw '[TC:LineQualityPath] Reparse points are not supported.' }
        }
        $parent=[IO.Path]::GetDirectoryName($cursor)
        if ($parent -eq $cursor) { break }; $cursor=$parent
    }
    $full
}
function LQReadJson {
    param([string]$Path, [int]$MaxBytes=262144)
    $full=LQPath $Path
    $stream=[IO.File]::Open($full,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    $reader=$null
    try {
        if ($stream.Length -gt $MaxBytes) { throw 'Bounded JSON size exceeded.' }
        $reader=New-Object IO.StreamReader($stream,(New-Object Text.UTF8Encoding($false,$true)),$true)
        $text=$reader.ReadToEnd()
        if ([Text.Encoding]::UTF8.GetByteCount($text) -gt $MaxBytes) { throw 'Bounded JSON size exceeded.' }
        ConvertFrom-Json -InputObject $text -ErrorAction Stop
    } finally { if ($reader) { $reader.Dispose() } else { $stream.Dispose() } }
}
function LQNewState {
    param([string]$Revision=([guid]::NewGuid().ToString('N')), [string]$SeriesId=([guid]::NewGuid().ToString('N')))
    [pscustomobject][ordered]@{
        SchemaVersion=2; Owner='TradeChannel.LineQuality'; Revision=$Revision
        SeriesId=$SeriesId; ArchivedSeries=@()
        BindingKey=''; Binding=$null; Samples=@(); LastAttemptAtUtc=$null
        BadCount=0; RecoveryCount=0; AlertLatched=$false; LastAlert=$null
    }
}
function LQAssertBinding {
    param($Binding, [string]$Key)
    $node=[guid]::Empty; $pidValue=0L
    if ($Key -cnotmatch '^[a-f0-9]{64}$' -or $Key -cne (LQHash (ConvertTo-Json -InputObject $Binding -Depth 4 -Compress)) -or
        -not [guid]::TryParse([string]$Binding.NodeId,[ref]$node) -or $node -eq [guid]::Empty -or
        [string]$Binding.SessionId -cnotmatch '^[A-Za-z0-9_-]{1,80}$' -or $Binding.ProfileId -cnotin @('Udp','Tcp') -or
        [string]$Binding.Exit -cnotmatch '^(?:hk|provider(?:[0-9]{1,3})?(?:-trade)?)$' -or
        [string]$Binding.ConfigHash -cnotmatch '^[A-F0-9]{64}$' -or
        -not [long]::TryParse([string]$Binding.EnginePid,[ref]$pidValue) -or $pidValue -le 0 -or
        -not (LQDate $Binding.EngineStartedAtUtc) -or $Binding.Mode -cnotin @('rule','global') -or
        [string]$Binding.ManifestPath -notmatch '^[A-Za-z]:[\\/]' -or ([string]$Binding.ManifestPath).Length -gt 1024 -or
        @($Binding.PSObject.Properties).Count -ne 9) { throw 'Invalid binding.' }
}
function LQAssertSamples {
    param($Samples)
    $previous=$null
    foreach ($sample in @($Samples)) {
        $stamp=[DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParse([string]$sample.AtUtc,[ref]$stamp) -or ($previous -and ($stamp-$previous).TotalSeconds -lt 30) -or $sample.Quality -cnotin @('Good','Fair','Poor','Unknown') -or $sample.Source -cne 'ControllerDelay') { throw 'Invalid sample.' }
        if ($sample.Quality -eq 'Unknown') { if ($null -ne $sample.LatencyMs) { throw 'Unknown latency must be null.' } }
        elseif ($sample.LatencyMs -isnot [ValueType] -or $sample.LatencyMs -is [bool] -or [double]::IsNaN([double]$sample.LatencyMs) -or [double]::IsInfinity([double]$sample.LatencyMs) -or $sample.LatencyMs -le 0 -or $sample.LatencyMs -gt 60000) { throw 'Invalid latency.' }
        if ($sample.Reason -cnotin @('Measured','ControllerUnavailable','MeasurementTimeout','MeasurementFailed','InvalidMeasurement','DelayUnavailable')) { throw 'Invalid sample reason.' }
        $expected=if ($null -eq $sample.LatencyMs) { 'Unknown' } elseif ($sample.LatencyMs -ge 500) { 'Poor' } elseif ($sample.LatencyMs -gt 200) { 'Fair' } else { 'Good' }
        if ($sample.Quality -cne $expected -or ($sample.Reason -eq 'Measured') -ne ($null -ne $sample.LatencyMs) -or @($sample.PSObject.Properties).Count -ne 5) { throw 'Inconsistent quality.' }
        $previous=$stamp
    }
}
function LQNormalizeState {
    param($State, [ref]$Migrated)
    if ($Migrated) { $Migrated.Value=$false }
    try {
        if ($state.SchemaVersion -notin @(1,2) -or $state.Owner -cne 'TradeChannel.LineQuality' -or $state.Revision -cnotmatch '^[a-f0-9]{32}$' -or @($state.Samples).Count -gt $script:LQMaxSamples) { throw 'Invalid store.' }
        if ($state.SchemaVersion -eq 1 -and @($state.Samples).Count -gt 60) { throw 'Invalid legacy store.' }
        if ($state.BindingKey) {
            LQAssertBinding $state.Binding $state.BindingKey
        } elseif ($null -ne $state.Binding -or @($state.Samples).Count) { throw 'Unbound samples.' }
        if ($state.BadCount -lt 0 -or $state.BadCount -gt 60 -or $state.RecoveryCount -lt 0 -or $state.RecoveryCount -gt 60 -or $state.AlertLatched -isnot [bool]) { throw 'Invalid debounce.' }
        if ($state.LastAttemptAtUtc -and -not (LQDate $state.LastAttemptAtUtc)) { throw 'Invalid attempt timestamp.' }
        if ($state.AlertLatched -and -not $state.LastAlert) { throw 'Missing latched alert.' }
        if ($state.LastAlert) {
            if ($state.LastAlert.Id -cnotmatch '^[a-f0-9]{32}$' -or -not (LQDate $state.LastAlert.AtUtc) -or $state.LastAlert.Reason -notin @('ConsecutiveHighLatency','ConsecutiveMeasurementFailures','ConsecutiveDegradedSamples')) { throw 'Invalid alert.' }
            # Reconstruct display text from the enum; never reflect arbitrary
            # text/extra fields from a corrupted cache into a notification.
            $state.LastAlert=[pscustomobject]@{Id=$state.LastAlert.Id; Reason=$state.LastAlert.Reason; Message=(LQAlertMessage $state.LastAlert.Reason); AtUtc=(LQDate $state.LastAlert.AtUtc).ToString('o')}
        }
        LQAssertSamples $state.Samples
        if ($state.SchemaVersion -eq 1) {
            $state.SchemaVersion=2
            $state | Add-Member NoteProperty SeriesId $state.Revision
            $state | Add-Member NoteProperty ArchivedSeries @()
            if ($Migrated) { $Migrated.Value=$true }
        }
        if ($state.SeriesId -cnotmatch '^[a-f0-9]{32}$' -or @($state.ArchivedSeries).Count -ge $script:LQMaxSeries) { throw 'Invalid series bound.' }
        $ids=@{}; $ids[$state.SeriesId]=$true; $total=@($state.Samples).Count
        foreach ($series in @($state.ArchivedSeries)) {
            if ($series.SeriesId -cnotmatch '^[a-f0-9]{32}$' -or $ids.ContainsKey($series.SeriesId) -or -not @($series.Samples).Count) { throw 'Invalid archived series.' }
            $ids[$series.SeriesId]=$true; $total+=@($series.Samples).Count
            if ($total -gt $script:LQMaxSamples) { throw 'Invalid sample bound.' }
            LQAssertBinding $series.Binding $series.BindingKey
            LQAssertSamples $series.Samples
        }
        return $state
    } catch { throw '[TC:LineQualityStore] 线路质量缓存不可读；原文件已保留。' }
}
function LQReadState {
    param([string]$Root, [ref]$Migrated)
    if ($Migrated) { $Migrated.Value=$false }
    $path=LQPath (Join-Path $Root 'Product\line-quality.json')
    if (-not [IO.File]::Exists($path)) { return (LQNewState) }
    try {
        $state=LQReadJson $path $script:LQMaxStoreBytes
        if ($state.SchemaVersion -eq 1 -and (Get-Item -LiteralPath $path).Length -gt 262144) { throw 'Invalid legacy store size.' }
        LQNormalizeState $state $Migrated
    } catch { throw '[TC:LineQualityStore] 线路质量缓存不可读；原文件已保留。' }
}
function LQOpenStore {
    param([string]$Root)
    $dir=LQPath (Join-Path $Root 'Product')
    $null=[IO.Directory]::CreateDirectory($dir)
    $path=LQPath (Join-Path $dir '.store.lock')
    # Share the NodeStore/cleanup serialization boundary, but never wait for it.
    try { return [IO.File]::Open($path,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
    catch [IO.IOException] { return $null }
}
function LQWriteState {
    param([string]$Root, $State)
    $path=LQPath (Join-Path $Root 'Product\line-quality.json')
    $temp=LQPath (Join-Path (Split-Path $path -Parent) ('.tc-'+[guid]::NewGuid().ToString('N')+'.tmp'))
    $text=ConvertTo-Json -InputObject $State -Depth 8 -Compress
    if ([Text.Encoding]::UTF8.GetByteCount($text)+3 -gt $script:LQMaxStoreBytes) { throw 'Line quality store exceeds its bound.' }
    try {
        [IO.File]::WriteAllText($temp,$text,(New-Object Text.UTF8Encoding($true)))
        if ([IO.File]::Exists($path)) { [IO.File]::Replace($temp,$path,[NullString]::Value) }
        else { [IO.File]::Move($temp,$path) }
    } finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}

function Get-TCLineQualityContext {
    [CmdletBinding()]
    param($Overview, [DateTimeOffset]$Now=[DateTimeOffset]::UtcNow)
    $result=[pscustomobject]@{Eligible=$false; Key=''; Binding=$null; Reason='Disconnected'}
    if ((LQField $Overview Running $false) -isnot [bool] -or (LQField $Overview Running $false) -ne $true -or (LQField $Overview StateKey '') -cne 'Connected') { return $result }
    $result.Reason='BindingUnavailable'
    $node=[guid]::Empty; $line=[string](LQField $Overview ActiveLineId '')
    $connected=LQDate (LQField $Overview ConnectedSince); $observed=LQDate (LQField $Overview ObservedAt)
    $pidValue=0L
    if ((LQField $Overview ProfileBindingVerified $false) -isnot [bool] -or (LQField $Overview ProfileBindingVerified $false) -ne $true -or -not [guid]::TryParse($line,[ref]$node) -or
        $node -eq [guid]::Empty -or (LQField $Overview ActiveProfileId '') -notin @('Udp','Tcp') -or
        [string](LQField $Overview SessionId '') -cnotmatch '^[A-Za-z0-9_-]{1,80}$' -or
        [string](LQField $Overview ConfigHash '') -notmatch '^[a-fA-F0-9]{64}$' -or
        -not [long]::TryParse([string](LQField $Overview EnginePid ''),[ref]$pidValue) -or $pidValue -le 0 -or
        -not $connected -or $connected -gt $Now -or
        [string](LQField $Overview ManifestPath '') -notmatch '^[A-Za-z]:[\\/]' -or ([string](LQField $Overview ManifestPath '')).Length -gt 1024 -or
        (LQField $Overview Mode '') -notin @('rule','global') -or
        [string](LQField $Overview Exit '') -cnotmatch '^(?:hk|provider(?:[0-9]{1,3})?(?:-trade)?)$') { return $result }
    $binding=[pscustomobject][ordered]@{
        SessionId=[string](LQField $Overview SessionId); NodeId=$node.ToString(); ProfileId=[string](LQField $Overview ActiveProfileId)
        Exit=[string](LQField $Overview Exit); ConfigHash=([string](LQField $Overview ConfigHash)).ToUpperInvariant()
        EnginePid=$pidValue; EngineStartedAtUtc=$connected.ToString('o')
        ManifestPath=([IO.Path]::GetFullPath([string](LQField $Overview ManifestPath))).ToLowerInvariant()
        Mode=[string](LQField $Overview Mode)
    }
    $result.Binding=$binding; $result.Key=LQHash (ConvertTo-Json -InputObject $binding -Compress)
    if (-not $observed -or $observed -gt $Now.AddSeconds(2) -or ($Now-$observed).TotalSeconds -gt 15) { $result.Reason='ObservationStale'; return $result }
    $result.Eligible=$true; $result.Reason='Bound'; $result
}
function LQPrune {
    param($State, [DateTimeOffset]$Now)
    $cutoff=$Now.AddHours(-24)
    foreach ($series in @($State)+@($State.ArchivedSeries)) {
        $samples=New-Object 'Collections.Generic.List[object]'
        foreach ($sample in $series.Samples) { $stamp=[DateTimeOffset]$sample.AtUtc; if ($stamp -le $Now -and $stamp -gt $cutoff) { $samples.Add($sample) } }
        $series.Samples=$samples.ToArray()
    }
    $State.ArchivedSeries=@($State.ArchivedSeries | Where-Object { @($_.Samples).Count } | Sort-Object { LQDate $_.Samples[-1].AtUtc } | Select-Object -Last ($script:LQMaxSeries-1))
    $total=@($State.Samples).Count
    foreach ($series in $State.ArchivedSeries) { $total+=@($series.Samples).Count }
    if ($total -gt $script:LQMaxSamples) {
        $all=@(foreach ($series in @($State)+@($State.ArchivedSeries)) { foreach ($sample in $series.Samples) { [pscustomobject]@{Id=$series.SeriesId; AtUtc=$sample.AtUtc; Stamp=(LQDate $sample.AtUtc)} } })
        $keep=@{}
        foreach ($item in @($all | Sort-Object Stamp,Id | Select-Object -Last $script:LQMaxSamples)) { $keep[$item.Id+'|'+$item.AtUtc]=$true }
        foreach ($series in @($State)+@($State.ArchivedSeries)) { $series.Samples=@($series.Samples | Where-Object { $keep.ContainsKey($series.SeriesId+'|'+$_.AtUtc) }) }
        $State.ArchivedSeries=@($State.ArchivedSeries | Where-Object { @($_.Samples).Count })
    }
}
function LQInvalidateLive {
    param($State, [bool]$PreserveHistory=$true)
    $next=LQNewState
    if ($PreserveHistory) {
        $next.ArchivedSeries=@($State.ArchivedSeries)
        if ($State.BindingKey -and @($State.Samples).Count) {
            $next.ArchivedSeries+=,[pscustomobject][ordered]@{SeriesId=$State.SeriesId; BindingKey=$State.BindingKey; Binding=$State.Binding; Samples=@($State.Samples)}
        }
    }
    return $next
}
function LQStatistics {
    param($Samples)
    $values=New-Object 'Collections.Generic.List[int]'; $timeouts=0; $controller=0; $count=0; $sum=0L
    foreach ($sample in $Samples) {
        $count++
        # Engine/controller faults are not network misses. They stay inside
        # UnavailableCount (unchanged meaning) but are counted separately so the
        # console can stop reporting an engine fault as "did not measure".
        if ($sample.Reason -ceq 'MeasurementTimeout') { $timeouts++ }
        elseif ($sample.Reason -ceq 'ControllerUnavailable') { $controller++ }
        if ($null -ne $sample.LatencyMs) { $value=[int]$sample.LatencyMs; $values.Add($value); $sum+=$value }
    }
    $values.Sort()
    $average=$null; $minimum=$null; $maximum=$null; $p95=$null; $p50=$null
    if ($values.Count) {
        $average=[Math]::Round($sum/[double]$values.Count,1); $minimum=$values[0]; $maximum=$values[-1]; $p95=$values[[int][Math]::Ceiling($values.Count*0.95)-1]
        # P50 与 P95 一起给图表用：中位数代表"平时多快"，P95 代表"最差的时候"。
        # 只有平均值时，少数超时会把线拉高，看不出到底是普遍变慢还是偶发尖峰。
        $p50=if ($values.Count % 2) { [double]$values[[int](($values.Count-1)/2)] } else { [Math]::Round(([double]$values[$values.Count/2-1]+[double]$values[$values.Count/2])/2,1) }
    }
    [pscustomobject][ordered]@{
        SampleCount=$count; MeasuredCount=$values.Count; UnavailableCount=($count-$values.Count)
        TimeoutCount=$timeouts
        ControllerUnavailableCount=$controller
        AverageLatencyMs=$average; MedianLatencyMs=$p50; MinLatencyMs=$minimum; MaxLatencyMs=$maximum; P95LatencyMs=$p95
    }
}
function LQAggregate {
    param($Samples, [DateTimeOffset]$Now, [int]$WindowSeconds, [int]$BucketSeconds)
    $start=$Now.AddSeconds(-$WindowSeconds)
    $selected=New-Object 'Collections.Generic.List[object]'
    $groups=@{}; $bucketCount=[int]($WindowSeconds/$BucketSeconds)
    foreach ($sample in $Samples) {
        $date=[DateTimeOffset]$sample.AtUtc
        if ($date -le $start -or $date -gt $Now) { continue }
        $selected.Add($sample)
        # Both the rolling window and every bucket are (start, end]. This
        # gives each regular 30-second sample its own slot at exact boundaries.
        $index=[int][Math]::Min($bucketCount-1,[Math]::Ceiling(($date-$start).TotalSeconds/$BucketSeconds)-1)
        if (-not $groups.ContainsKey($index)) { $groups[$index]=New-Object 'Collections.Generic.List[object]' }
        $groups[$index].Add($sample)
    }
    $buckets=@(for ($i=0; $i -lt $bucketCount; $i++) {
        $items=@(); if ($groups.ContainsKey($i)) { $items=$groups[$i].ToArray() }
        $stats=LQStatistics $items
        [pscustomobject][ordered]@{
            StartAtUtc=$start.AddSeconds($i*$BucketSeconds).ToString('o'); EndAtUtc=$start.AddSeconds(($i+1)*$BucketSeconds).ToString('o')
            SampleCount=$stats.SampleCount; MeasuredCount=$stats.MeasuredCount; UnavailableCount=$stats.UnavailableCount; TimeoutCount=$stats.TimeoutCount; ControllerUnavailableCount=$stats.ControllerUnavailableCount
            AverageLatencyMs=$stats.AverageLatencyMs; MedianLatencyMs=$stats.MedianLatencyMs; MinLatencyMs=$stats.MinLatencyMs; MaxLatencyMs=$stats.MaxLatencyMs; P95LatencyMs=$stats.P95LatencyMs
        }
    })
    [pscustomobject][ordered]@{StartAtUtc=$start.ToString('o'); EndAtUtc=$Now.ToString('o'); WindowSeconds=$WindowSeconds; BucketSeconds=$BucketSeconds; Statistics=(LQStatistics $selected); Buckets=@($buckets)}
}
function LQSummary {
    param($State, $Context, [DateTimeOffset]$Now, [bool]$Enabled=$true, [string]$OverrideReason='')
    $quality='Unknown'; $ms=$null; $history=@(); $daySamples=@(); $reason='NoSamples'; $stamp=$null; $next=$null; $lastAlert=$null
    $degraded=$false; $notificationMessage=''
    if (-not $Enabled) { $reason='Disabled' }
    elseif (-not $Context.Eligible) { $reason=$Context.Reason }
    elseif (-not $State -or $State.BindingKey -cne $Context.Key) { $reason='BindingChanged' }
    else {
        LQPrune $State $Now
        $daySamples=@($State.Samples)
        $history=@($daySamples | Where-Object { ([DateTimeOffset]$_.AtUtc) -gt $Now.AddMinutes(-30) } | Select-Object AtUtc,LatencyMs,Quality,Reason,Source)
        $lastAlert=$State.LastAlert
        $attempt=LQDate $State.LastAttemptAtUtc
        if ($attempt) { $next=$attempt.AddSeconds(30).ToString('o') }
        if ($daySamples.Count) {
            $last=$daySamples[-1]; $stamp=$last.AtUtc
            if (($Now-(LQDate $stamp)).TotalSeconds -le 75) {
                $quality=$last.Quality; $ms=$last.LatencyMs; $reason=$last.Reason
                $degraded=[bool]$State.AlertLatched
                if ($degraded -and $lastAlert) { $notificationMessage=LQAlertMessage $lastAlert.Reason }
            }
            else { $reason='SampleExpired' }
        }
    }
    if ($OverrideReason) { $reason=$OverrideReason; $quality='Unknown'; $ms=$null; $degraded=$false; $notificationMessage='' }
    $labels=@{Good='良好';Fair='一般';Poor='较差';Unknown='未知'}
    [pscustomobject][ordered]@{
        SchemaVersion=2; Quality=$quality; QualityLabel=$labels[$quality]; LatencyMs=$ms
        LatencyText=$(if ($null -ne $ms) { [string]$ms+' ms' } else { '未知' }); Reason=$reason
        History=@($history); SampleAtUtc=$stamp; NextSampleAtUtc=$next
        ThirtyMinutes=(LQAggregate $daySamples $Now 1800 30); Day=(LQAggregate $daySamples $Now 86400 900)
        BindingKey=$Context.Key; Binding=$Context.Binding; Sampled=$false; Notify=$false; Notification=$null; LastNotification=$lastAlert
        Degraded=$degraded; NotificationMessage=$notificationMessage
        Source='ControllerDelay'; Metric='SelectedTradeExitHttpsRoundTrip'; MeasurementLabel='当前交易出口 HTTPS 往返（含 TLS）'
        PacketLossPercent=$null; PacketLossMeasured=$false; NetworkChanged=$false; AutoSwitched=$false
        RetentionSeconds=86400; HistoryWindowSeconds=1800; MaxSamples=$script:LQMaxSamples; MaxSeries=$script:LQMaxSeries; MaxStoreBytes=$script:LQMaxStoreBytes
        IntervalSeconds=30; FreshnessSeconds=75; MeasurementBudgetMs=7000
        BadThresholdMs=500; RecoveryThresholdMs=350; RequiredBadSamples=3; RequiredRecoverySamples=2; CooldownSeconds=300
    }
}
function Get-TCLineQualitySummary {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Root, $Overview, [bool]$Enabled=$true, [scriptblock]$Clock)
    $now=LQNow $Clock; $context=Get-TCLineQualityContext $Overview $now
    try { $state=LQReadState $Root; LQSummary $state $context $now $Enabled }
    catch { LQSummary $null $context $now $Enabled 'StoreUnavailable' }
}
function Get-TCLineQualityHistory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Root, [string[]]$NodeId=@(),
        [ValidateSet('','Udp','Tcp')][string]$ProfileId='', [string]$Exit='', [string]$SessionId='',
        [ValidateSet('ThirtyMinutes','Day')][string]$Window='Day', [scriptblock]$Clock
    )
    $now=LQNow $Clock; $seconds=86400; $bucket=900
    if ($Window -eq 'ThirtyMinutes') { $seconds=1800; $bucket=30 }
    $reason='Available'; $seriesViews=@()
    try {
        $state=LQReadState $Root; LQPrune $state $now
        $seriesViews=@(foreach ($series in @($state)+@($state.ArchivedSeries)) {
            if (-not $series.Binding -or -not @($series.Samples).Count -or
                ($NodeId.Count -and $series.Binding.NodeId -notin $NodeId) -or ($ProfileId -and $series.Binding.ProfileId -cne $ProfileId) -or
                ($Exit -and $series.Binding.Exit -cne $Exit) -or ($SessionId -and $series.Binding.SessionId -cne $SessionId)) { continue }
            $aggregate=LQAggregate $series.Samples $now $seconds $bucket
            if (-not $aggregate.Statistics.SampleCount) { continue }
            [pscustomobject][ordered]@{SeriesId=$series.SeriesId; BindingKey=$series.BindingKey; Binding=$series.Binding; Aggregate=$aggregate}
        })
    } catch { $reason='StoreUnavailable'; $seriesViews=@() }
    [pscustomobject][ordered]@{
        SchemaVersion=2; Reason=$reason; Window=$Window; RetentionSeconds=86400; Series=@($seriesViews)
        Metric='SelectedTradeExitHttpsRoundTrip'; MeasurementLabel='交易出口 HTTPS 往返历史（含 TLS）'
        HistoricalOnly=$true; PacketLossMeasured=$false; NetworkChanged=$false; AutoSwitched=$false
    }
}
function LQUseStoreLock {
    param([string]$Root, [IO.FileStream]$StoreLock)
    $expected=LQPath (Join-Path $Root 'Product\.store.lock')
    if (-not $StoreLock.CanRead -or -not $StoreLock.CanWrite -or $StoreLock.SafeFileHandle.IsClosed -or
        [IO.Path]::GetFullPath($StoreLock.Name) -ine $expected) { throw 'Invalid existing store lock.' }
}
function Remove-TCLineQualityOwnedState {
    <# Deterministic journal transformation. No file I/O, lock, clock, randomness or input mutation.
       Changed=false returns the original Value; callers must not write it.
       Empty=true means there is no remaining ownership and a journal may delete
       the file. Changed=true upgrades Schema 1 and derives Revision from the old
       revision and sorted, normalized ownership IDs, so preview/commit agree. #>
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$State, [string[]]$NodeId=@())
    $ErrorActionPreference='Stop'
    $ids=@(@(foreach ($id in $NodeId) { $guid=[guid]::Empty; if (-not [guid]::TryParse($id,[ref]$guid) -or $guid -eq [guid]::Empty) { throw 'Invalid node ID.' }; $guid.ToString() }) | Sort-Object -Unique)
    $text=ConvertTo-Json -InputObject $State -Depth 10 -Compress -WarningAction Stop
    if ([Text.Encoding]::UTF8.GetByteCount($text)+3 -gt $script:LQMaxStoreBytes) { throw 'Line quality store exceeds its bound.' }
    $copy=ConvertFrom-Json -InputObject $text -ErrorAction Stop
    if ($copy.Owner -cne 'TradeChannel.LineQuality' -or $copy.Revision -cnotmatch '^[a-f0-9]{32}$') { throw 'Invalid line quality owner or revision.' }
    $seed='TradeChannel.LineQuality.cleanup.v1|'+$copy.Revision+'|'+($ids -join ',')
    $revision=(LQHash $seed).Substring(0,32); $seriesId=(LQHash ($seed+'|series')).Substring(0,32)
    # Schema 1 exclusively owns its single Binding. Old cleanup fixtures and
    # damaged legacy single-line caches may omit live/alert fields; an exact
    # owner match can still remove the entire file without trusting those fields.
    if ($copy.SchemaVersion -eq 1) {
        if (@(LQField $copy ArchivedSeries @()).Count) { throw 'Invalid legacy ownership.' }
        if ($null -eq (LQField $copy Binding) -and -not @(LQField $copy Samples @()).Count) {
            $null=LQNormalizeState $copy
            return [pscustomobject]@{Changed=$false;Value=$State;Empty=$true}
        }
        $owner=[guid]::Empty
        if (-not [guid]::TryParse([string](LQField (LQField $copy Binding) NodeId ''),[ref]$owner) -or $owner -eq [guid]::Empty) { throw 'Invalid legacy ownership.' }
        if ($owner.ToString() -notin $ids) { return [pscustomobject]@{Changed=$false; Value=$State; Empty=$false} }
        return [pscustomobject]@{Changed=$true; Value=(LQNewState -Revision $revision -SeriesId $seriesId); Empty=$true}
    }
    $copy=LQNormalizeState $copy
    $matches=@(@($copy)+@($copy.ArchivedSeries) | Where-Object { [string](LQField $_.Binding NodeId '') -in $ids })
    if (-not $matches.Count) { return [pscustomobject]@{Changed=$false; Value=$State; Empty=$false} }
    if ([string](LQField $copy.Binding NodeId '') -in $ids) {
        $copy.BindingKey=''; $copy.Binding=$null; $copy.Samples=@(); $copy.LastAttemptAtUtc=$null
        $copy.BadCount=0; $copy.RecoveryCount=0; $copy.AlertLatched=$false; $copy.LastAlert=$null; $copy.SeriesId=$seriesId
    }
    $copy.ArchivedSeries=@($copy.ArchivedSeries | Where-Object { $_.Binding.NodeId -notin $ids })
    $copy.Revision=$revision
    [pscustomobject]@{Changed=$true; Value=$copy; Empty=(-not $copy.BindingKey -and -not @($copy.ArchivedSeries).Count)}
}
function Clear-TCLineQuality {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Root, [string[]]$NodeId=@(), [switch]$PreserveHistory, [IO.FileStream]$StoreLock, [scriptblock]$Clock)
    $ErrorActionPreference='Stop'; $lock=$null; $ownsLock=$false
    try {
        if ($NodeId.Count -and $PreserveHistory) { throw 'Cannot preserve deleted ownership.' }
        $ids=@(foreach ($id in $NodeId) { $guid=[guid]::Empty; if (-not [guid]::TryParse($id,[ref]$guid) -or $guid -eq [guid]::Empty) { throw 'Invalid node ID.' }; $guid.ToString() })
        if ($StoreLock) { LQUseStoreLock $Root $StoreLock; $lock=$StoreLock }
        else { $lock=LQOpenStore $Root; $ownsLock=$true }
        if (-not $lock) { return [pscustomobject]@{Cleared=$false; Reason='StoreBusy'; NetworkChanged=$false} }
        $state=LQReadState $Root
        $removed=0; $removedSeries=0
        if ($ids.Count) {
            foreach ($series in @($state)+@($state.ArchivedSeries)) {
                if ([string](LQField $series.Binding NodeId '') -in $ids) { $removed+=@($series.Samples).Count; $removedSeries++ }
            }
            if (-not $removedSeries) { return [pscustomobject]@{Cleared=$false; Reason='OtherLine'; NetworkChanged=$false} }
            $state=(Remove-TCLineQualityOwnedState -State $state -NodeId $ids).Value
        } else {
            if (-not $PreserveHistory) { foreach ($series in @($state)+@($state.ArchivedSeries)) { $removed+=@($series.Samples).Count; if ($series.Binding) { $removedSeries++ } } }
            $state=LQInvalidateLive $state ([bool]$PreserveHistory)
        }
        LQPrune $state (LQNow $Clock)
        LQWriteState $Root $state
        [pscustomobject]@{Cleared=$true; Reason='Cleared'; RemovedSamples=$removed; RemovedSeries=$removedSeries; NetworkChanged=$false}
    } catch { [pscustomobject]@{Cleared=$false; Reason='StoreUnavailable'; NetworkChanged=$false} }
    finally { if ($lock -and $ownsLock) { $lock.Dispose() } }
}

function LQMeasurementResult {
    param($Context, [string]$Status='Unavailable', [string]$Reason='MeasurementFailed', $LatencyMs=$null)
    [pscustomobject]@{Status=$Status; Reason=$Reason; LatencyMs=$LatencyMs; ContextKey=$Context.Key; Outbound=$Context.Binding.Exit; Source='ControllerDelay'}
}
function LQRuntimeConfig {
    param([string]$Root, $Context)
    # Only inspect the explicit caller root; importing this module never reads
    # ProgramData, installed runtime state, adapters or controllers.
    $binding=$Context.Binding
    if ([IO.File]::Exists((Join-Path $Root 'stop.request'))) { throw '[LQ:ContextChanged]' }
    $runtime=LQReadJson (Join-Path $Root 'runtime.json') 1048576
    $deployment=LQReadJson (Join-Path $Root 'deployment.json')
    $manifestPath=LQPath ([string](LQField $deployment ManifestPath ''))
    if ($runtime.State -cne 'Running' -or $runtime.SessionId -cne $binding.SessionId -or
        [long]$runtime.EnginePid -ne $binding.EnginePid -or
        (LQDate $runtime.EngineStartedAt) -ne (LQDate $binding.EngineStartedAtUtc) -or
        $manifestPath -ine $binding.ManifestPath -or (LQPath $runtime.ManifestPath) -ine $manifestPath) { throw '[LQ:ContextChanged]' }
    foreach ($pair in @(@('LineId','NodeId'),@('ProfileId','ProfileId'))) {
        $value=[string](LQField $deployment $pair[0] '')
        if ($value -and $value -ine [string](LQField $binding $pair[1] '')) { throw '[LQ:ContextChanged]' }
    }
    foreach ($prefix in @('Engine','Supervisor')) {
        $process=$null
        try {
            $process=Get-Process -Id ([int](LQField $runtime ($prefix+'Pid') 0)) -ErrorAction Stop
            $born=LQDate (LQField $runtime ($prefix+'StartedAt'))
            if (-not $born -or [Math]::Abs(($process.StartTime.ToUniversalTime()-$born.UtcDateTime).TotalMilliseconds) -ge 1) { throw '[LQ:ContextChanged]' }
        } finally { if ($process) { $process.Dispose() } }
    }
    $manifest=LQReadJson $manifestPath 1048576
    $configPath=LQPath ([string]$manifest.CandidatePath)
    if ($configPath -ine (LQPath ([string]$runtime.ConfigPath)) -or $manifest.CandidateSHA256 -ine $binding.ConfigHash -or
        (Get-Item -LiteralPath $configPath).Length -gt 4194304 -or
        (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash -ine $binding.ConfigHash) { throw '[LQ:ContextChanged]' }
    $config=LQReadJson $configPath 4194304
    # Check again after reading the JSON so a replacement cannot lend its hash
    # to a different controller configuration.
    if ((Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash -ine $binding.ConfigHash) { throw '[LQ:ContextChanged]' }
    $config
}
function LQHttpGet {
    param($Client, [string]$BaseUrl, [string]$Path, [Diagnostics.Stopwatch]$Watch, [int]$BudgetMilliseconds, [int]$RequestMilliseconds)
    $remaining=[int][Math]::Floor($BudgetMilliseconds-$Watch.Elapsed.TotalMilliseconds)
    if ($remaining -le 0) { throw '[LQ:Timeout]' }
    $cancel=New-Object Threading.CancellationTokenSource
    $response=$null
    try {
        $cancel.CancelAfter([Math]::Min($remaining,$RequestMilliseconds))
        $response=$Client.GetAsync(($BaseUrl+$Path),$cancel.Token).GetAwaiter().GetResult()
        $null=$response.EnsureSuccessStatusCode()
        $text=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if ($Watch.ElapsedMilliseconds -ge $BudgetMilliseconds) { throw '[LQ:Timeout]' }
        ConvertFrom-Json -InputObject $text -ErrorAction Stop
    } finally { if ($response) { $response.Dispose() }; $cancel.Dispose() }
}
function LQControllerMeasure {
    param([string]$Root, $Context, [Diagnostics.Stopwatch]$Watch, [int]$BudgetMilliseconds)
    $ErrorActionPreference='Stop'
    $handler=$null; $client=$null; $config=$null; $api=$null
    try {
        try { $config=LQRuntimeConfig $Root $Context }
        catch { return (LQMeasurementResult $Context 'ContextChanged' 'BindingChanged') }
        $api=LQField (LQField $config experimental) clash_api
        $address=[string](LQField $api external_controller '')
        if ($address -cnotmatch '^127\.0\.0\.1:([0-9]{1,5})$' -or [int]$Matches[1] -lt 1 -or [int]$Matches[1] -gt 65535 -or -not (LQField $api secret '')) { return (LQMeasurementResult $Context 'Unavailable' 'ControllerUnavailable') }
        $outbounds=@(LQField $config outbounds @())
        $selector=@($outbounds | Where-Object { (LQField $_ tag '') -ceq 'trade-exit' })
        $concrete=@(@($outbounds)+@(LQField $config endpoints @()) | Where-Object { (LQField $_ tag '') -ceq $Context.Binding.Exit })
        if ($selector.Count -ne 1 -or (LQField $selector[0] type '') -cne 'selector' -or
            @((LQField $selector[0] outbounds @()) | Where-Object { $_ -ceq $Context.Binding.Exit }).Count -ne 1 -or
            $concrete.Count -ne 1 -or (LQField $concrete[0] type '') -notin @('wireguard','socks','http','shadowsocks','trojan','vmess','vless','hysteria','hysteria2','tuic')) {
            return (LQMeasurementResult $Context 'ContextChanged' 'BindingChanged')
        }
        Add-Type -AssemblyName System.Net.Http
        $handler=New-Object Net.Http.HttpClientHandler
        $handler.UseProxy=$false; $handler.AllowAutoRedirect=$false
        $client=New-Object Net.Http.HttpClient($handler)
        $client.Timeout=[Threading.Timeout]::InfiniteTimeSpan; $client.MaxResponseContentBufferSize=65536
        $client.DefaultRequestHeaders.Authorization=New-Object Net.Http.Headers.AuthenticationHeaderValue('Bearer',[string]$api.secret)
        $baseUrl='http://'+$address
        $before=LQHttpGet $client $baseUrl '/proxies/trade-exit' $Watch $BudgetMilliseconds 1000
        if ((LQField $before now '') -cne $Context.Binding.Exit) { return (LQMeasurementResult $Context 'ContextChanged' 'BindingChanged') }
        $timeout=[int][Math]::Min(5000,[Math]::Floor($BudgetMilliseconds-$Watch.Elapsed.TotalMilliseconds-500))
        if ($timeout -lt 100) { return (LQMeasurementResult $Context 'Unavailable' 'MeasurementTimeout') }
        # Pin the concrete outbound. A temporary A->B->A selector change cannot
        # turn a B measurement into an A latency. There is no fallback to direct,
        # ping, a candidate tunnel, or another controller/outbound.
        $path='/proxies/'+[Uri]::EscapeDataString($Context.Binding.Exit)+'/delay?timeout='+$timeout+'&url='+[Uri]::EscapeDataString('https://1.1.1.1/cdn-cgi/trace')
        $delay=LQHttpGet $client $baseUrl $path $Watch $BudgetMilliseconds ($timeout+100)
        $after=LQHttpGet $client $baseUrl '/proxies/trade-exit' $Watch $BudgetMilliseconds 500
        if ((LQField $after now '') -cne $Context.Binding.Exit) { return (LQMeasurementResult $Context 'ContextChanged' 'BindingChanged') }
        try { $null=LQRuntimeConfig $Root $Context }
        catch { return (LQMeasurementResult $Context 'ContextChanged' 'BindingChanged') }
        if ($Watch.ElapsedMilliseconds -ge $BudgetMilliseconds) { return (LQMeasurementResult $Context 'Unavailable' 'MeasurementTimeout') }
        $value=LQField $delay delay
        if ($null -eq $value -or $value -is [bool] -or $value -isnot [ValueType] -or [double]::IsNaN([double]$value) -or [double]::IsInfinity([double]$value) -or $value -le 0 -or $value -gt $timeout) {
            return (LQMeasurementResult $Context 'Unavailable' 'DelayUnavailable')
        }
        LQMeasurementResult $Context 'Measured' 'Measured' ([int][Math]::Ceiling([double]$value))
    } catch {
        $reason=if ($Watch.ElapsedMilliseconds -ge $BudgetMilliseconds -or $_.Exception.Message -like '*[[]LQ:Timeout]*') { 'MeasurementTimeout' } else { 'ControllerUnavailable' }
        LQMeasurementResult $Context 'Unavailable' $reason
    } finally {
        if ($client) { $client.Dispose() }; if ($handler) { $handler.Dispose() }
        $config=$null; $api=$null
    }
}
function LQReapWorker {
    if (-not $script:LQRetiredWorker) { return $true }
    $worker=$script:LQRetiredWorker
    if (-not $worker.Stop.IsCompleted) { return $false }
    try { $worker.PowerShell.EndStop($worker.Stop) } catch {}
    $worker.PowerShell.Dispose(); $script:LQRetiredWorker=$null; return $true
}
function LQRunMeasurement {
    param([string]$Root, $Context, [scriptblock]$Measure, $MeasureData, [int]$BudgetMilliseconds)
    # A non-cooperative test callback is not allowed to create unbounded workers.
    # Production HTTP has its own cancellation deadline even when PS stopping
    # waits for a .NET call. Reap a late stop before allowing another measurement.
    if (-not (LQReapWorker)) { return (LQMeasurementResult $Context 'Unavailable' 'MeasurementTimeout') }
    $watch=[Diagnostics.Stopwatch]::StartNew(); $worker=[PowerShell]::Create(); $retained=$false
    $body=@'
param($ModulePath,$DataRoot,$Context,$MeasureText,$Data,$Watch,$Budget)
$ErrorActionPreference='Stop'
if($MeasureText){
    & ([scriptblock]::Create($MeasureText)) $Context ([int][Math]::Max(1,$Budget-$Watch.ElapsedMilliseconds)) $Data
}else{
    $module=Import-Module $ModulePath -PassThru -DisableNameChecking
    & $module {param($r,$c,$w,$b) LQControllerMeasure $r $c $w $b} $DataRoot $Context $Watch $Budget
}
'@
    try {
        $null=$worker.AddScript($body).AddArgument((Join-Path $script:LQPackage 'LineQuality.psm1')).AddArgument($Root).AddArgument($Context).AddArgument([string]$Measure).AddArgument($MeasureData).AddArgument($watch).AddArgument($BudgetMilliseconds)
        $pending=$worker.BeginInvoke()
        $remaining=[int][Math]::Max(0,$BudgetMilliseconds-$watch.ElapsedMilliseconds)
        if (-not $pending.AsyncWaitHandle.WaitOne($remaining)) {
            $stop=$worker.BeginStop($null,$null)
            if ($stop.AsyncWaitHandle.WaitOne(100)) { try { $worker.EndStop($stop) } catch {} }
            else { $script:LQRetiredWorker=[pscustomobject]@{PowerShell=$worker; Stop=$stop}; $retained=$true }
            return (LQMeasurementResult $Context 'Unavailable' 'MeasurementTimeout')
        }
        $values=@($worker.EndInvoke($pending))
        if ($watch.ElapsedMilliseconds -gt $BudgetMilliseconds) { return (LQMeasurementResult $Context 'Unavailable' 'MeasurementTimeout') }
        if ($values.Count -ne 1 -or $worker.HadErrors) { return (LQMeasurementResult $Context 'Unavailable' 'InvalidMeasurement') }
        return $values[0]
    } catch { return (LQMeasurementResult $Context 'Unavailable' 'MeasurementFailed') }
    finally { if (-not $retained) { $worker.Dispose() } }
}
function LQQuality {
    param($LatencyMs)
    if ($null -eq $LatencyMs) { return 'Unknown' }
    if ($LatencyMs -ge 500) { return 'Poor' }
    if ($LatencyMs -gt 200) { return 'Fair' }
    return 'Good'
}
function LQAlertMessage {
    param([string]$Reason)
    switch ($Reason) {
        'ConsecutiveHighLatency' { '当前交易出口连续 3 次延迟较高，请检查线路；当前线路保持。' }
        'ConsecutiveMeasurementFailures' { '当前交易出口连续 3 次无法取得延迟，质量未知；当前线路保持。' }
        default { '当前交易出口连续多次高延迟或测量不可用，请检查线路；当前线路保持。' }
    }
}
function Invoke-TCLineQualitySample {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Root, $Overview,
        [bool]$Enabled=$true, [bool]$NotifyEnabled=$true,
        [scriptblock]$Measure, $MeasureData=$null, [scriptblock]$Clock,
        [ValidateRange(100,7000)][int]$BudgetMilliseconds=7000
    )
    $ErrorActionPreference='Stop'
    $now=LQNow $Clock; $context=Get-TCLineQualityContext $Overview $now
    $lock=$null; $mutex=$null; $owned=$false; $state=$null
    try {
        $rootPath=(LQPath $Root).TrimEnd('\')
        # Invalidation must not wait for the sampler mutex: a disconnect/setting
        # change can arrive while the previous worker is inside its HTTP call.
        if (-not $Enabled -or -not $context.Eligible) {
            $lock=LQOpenStore $rootPath
            if (-not $lock) { return (LQSummary $null $context $now $Enabled 'StoreBusy') }
            $state=LQReadState $rootPath
            if ($state.BindingKey -or $state.LastAttemptAtUtc) { $state=LQInvalidateLive $state; LQPrune $state $now; LQWriteState $rootPath $state }
            return (LQSummary $state $context $now $Enabled)
        }
        $mutex=New-Object Threading.Mutex($false,('Local\TradeChannel-LineQuality-'+(LQHash $rootPath.ToLowerInvariant())))
        try { $owned=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned=$true }
        if (-not $owned) {
            $view=Get-TCLineQualitySummary -Root $Root -Overview $Overview -Enabled $Enabled -Clock $Clock
            $view | Add-Member NoteProperty SkipReason 'SamplingBusy'; return $view
        }
        $lock=LQOpenStore $rootPath
        if (-not $lock) { return (LQSummary $null $context $now $Enabled 'StoreBusy') }
        $migrated=$false; $state=LQReadState $rootPath ([ref]$migrated)
        $lastAttempt=LQDate $state.LastAttemptAtUtc
        $alertAt=if ($state.LastAlert) { LQDate $state.LastAlert.AtUtc } else { $null }
        if ($state.BindingKey -cne $context.Key -or ($lastAttempt -and $lastAttempt -gt $now) -or ($alertAt -and $alertAt -gt $now)) {
            $state=LQInvalidateLive $state; $state.BindingKey=$context.Key; $state.Binding=$context.Binding; $lastAttempt=$null
        }
        LQPrune $state $now
        if ($lastAttempt -and ($now-$lastAttempt).TotalSeconds -lt 30) { if ($migrated) { LQWriteState $rootPath $state }; return (LQSummary $state $context $now $Enabled) }
        if (-not $state.Samples.Count -or ($now-(LQDate $state.Samples[-1].AtUtc)).TotalSeconds -gt 75) { $state.BadCount=0; $state.RecoveryCount=0 }
        $state.Revision=[guid]::NewGuid().ToString('N'); $ticket=$state.Revision
        $state.LastAttemptAtUtc=$now.ToString('o')
        LQWriteState $rootPath $state
        $lock.Dispose(); $lock=$null

        $measurement=LQRunMeasurement $rootPath $context $Measure $MeasureData $BudgetMilliseconds
        $finished=LQNow $Clock
        $lock=LQOpenStore $rootPath
        if (-not $lock) { return (LQSummary $null $context $finished $Enabled 'StoreBusy') }
        $state=LQReadState $rootPath
        if ($state.Revision -cne $ticket -or $state.BindingKey -cne $context.Key) { return (LQSummary $null $context $finished $Enabled 'BindingChanged') }
        if ($finished -lt $now -or ($finished-$now).TotalSeconds -gt 75 -or (LQField $measurement Status '') -ceq 'ContextChanged') {
            $state=LQInvalidateLive $state; LQPrune $state $finished; LQWriteState $rootPath $state
            return (LQSummary $null $context $finished $Enabled 'BindingChanged')
        }
        $ms=$null; $reason='InvalidMeasurement'
        if ((LQField $measurement ContextKey '') -ceq $context.Key -and (LQField $measurement Outbound '') -ceq $context.Binding.Exit -and (LQField $measurement Source '') -ceq 'ControllerDelay') {
            $candidate=LQField $measurement LatencyMs
            if ((LQField $measurement Status '') -ceq 'Measured' -and $candidate -is [ValueType] -and $candidate -isnot [bool] -and
                -not [double]::IsNaN([double]$candidate) -and -not [double]::IsInfinity([double]$candidate) -and $candidate -gt 0 -and $candidate -le 60000) {
                $ms=[int][Math]::Ceiling([double]$candidate); $reason='Measured'
            } elseif ((LQField $measurement Status '') -ceq 'Unavailable' -and (LQField $measurement Reason '') -in @('ControllerUnavailable','MeasurementTimeout','MeasurementFailed','InvalidMeasurement','DelayUnavailable')) { $reason=[string]$measurement.Reason }
        }
        $quality=LQQuality $ms
        $sample=[pscustomobject]@{AtUtc=$now.ToString('o'); LatencyMs=$ms; Quality=$quality; Reason=$reason; Source='ControllerDelay'}
        $state.Samples=@($state.Samples)+@($sample); LQPrune $state $finished
        $notification=$null
        if ($reason -ceq 'ControllerUnavailable') {
            # 本机引擎自己没跑起来，不是线路问题：既不算坏样本，也不清零已有计数。
            # 不清零是因为一次引擎抖动不该解除一个真实的线路告警；不累加是因为
            # 连续 3 次引擎故障会打出「交易出口连续 3 次无法取得延迟」，把本机故障
            # 说成出口问题——与前端把 ControllerUnavailableCount 从分子分母剔除
            # 是同一条口径。
        } elseif ($quality -in @('Poor','Unknown')) {
            $state.BadCount=[Math]::Min(60,$state.BadCount+1); $state.RecoveryCount=0
            $lastAlertAt=if ($state.LastAlert) { LQDate $state.LastAlert.AtUtc } else { $null }
            if ($NotifyEnabled -and $state.BadCount -ge 3 -and -not $state.AlertLatched -and (-not $lastAlertAt -or ($finished-$lastAlertAt).TotalSeconds -ge 300)) {
                $tail=@($state.Samples | Select-Object -Last 3)
                $alertReason=if (@($tail | Where-Object Quality -eq 'Poor').Count -eq 3) { 'ConsecutiveHighLatency' } elseif (@($tail | Where-Object Quality -eq 'Unknown').Count -eq 3) { 'ConsecutiveMeasurementFailures' } else { 'ConsecutiveDegradedSamples' }
                $notification=[pscustomobject]@{Id=[guid]::NewGuid().ToString('N'); Reason=$alertReason; Message=(LQAlertMessage $alertReason); AtUtc=$finished.ToString('o')}
                $state.LastAlert=$notification; $state.AlertLatched=$true
            }
        } elseif ($ms -le 350) {
            $state.BadCount=0; $state.RecoveryCount=[Math]::Min(60,$state.RecoveryCount+1)
            if ($state.RecoveryCount -ge 2) { $state.AlertLatched=$false }
        } else { $state.BadCount=0; $state.RecoveryCount=0 }
        $state.Revision=[guid]::NewGuid().ToString('N')
        LQWriteState $rootPath $state
        $view=LQSummary $state $context $finished $Enabled
        $view.Sampled=$true; $view.Notify=($null -ne $notification); $view.Notification=$notification; $view.MeasurementBudgetMs=$BudgetMilliseconds
        return $view
    } catch { return (LQSummary $null $context $now $Enabled 'StoreUnavailable') }
    finally {
        if ($lock) { $lock.Dispose() }
        if ($owned -and $mutex) { $mutex.ReleaseMutex() }
        if ($mutex) { $mutex.Dispose() }
    }
}

Export-ModuleMember -Function Get-TCLineQualityContext,Get-TCLineQualitySummary,Get-TCLineQualityHistory,Invoke-TCLineQualitySample,Clear-TCLineQuality,Remove-TCLineQualityOwnedState
