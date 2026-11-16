#requires -Version 5.1
Set-StrictMode -Version 2
$script:SQPackage=$PSScriptRoot
$script:SQRetiredWorker=$null
Import-Module (Join-Path $PSScriptRoot 'LineQuality.psm1') -DisableNameChecking

<#
Worker-only TCP reachability sampling. No tunnel, controller, engine, routing,
remote authentication or switching code is present. No default data root.

Caller supplies up to 16 verified candidate descriptors, never browser/worker
JSON targets: NodeId (canonical line ID), ProfileId (Tcp), Exit (hk), Host,
Port (actual prepared TCP transport port), ConfigHash (candidate SHA256), and
Underlay={InterfaceIndex,LocalAddress,InterfaceId,NetworkFingerprint} from the
trusted physical-interface resolver. All four fields participate in the key.
Non-loopback production targets require a literal IPv4 and this binding; DNS
names/IPv6/missing underlay remain unknown and are not probed or recommended.
TCP binds its source address and IP_UNICAST_IF (31, network-order index); a
binding failure never falls back to the active TUN/system route. Loopback-only
tests may omit Underlay. Re-resolve the underlay when reading/publishing a
recommendation so changed network fingerprints cannot borrow old evidence.
Optional Enabled=false excludes a descriptor. Do not substitute UDP, SSH or
generic HTTPS ports. Resolve a prepared Tcp profile's immutable configuration
in the trusted worker; this module does not import NodeStore or prepare profiles.
Changed config/address/port changes CandidateKey. The current line is excluded.

Invoke-TCStandbyQualitySample -Root ... -Overview ... -Candidates $targets
Get-TCStandbyQualitySummary  -Root ... -Overview ... -Candidates $targets
Clear-TCStandbyQuality -Root ... -NodeId $removedFamilyIds [-StoreLock $stream]
Remove-TCStandbyQualityOwnedState -State $alreadyRead -NodeId $removedFamilyIds
is a deterministic, no-I/O journal transform returning {Changed,Value,Empty}.
Deleting an active observation owner unbinds live evidence but retains other
candidate entries. Empty permits file removal only together with Changed=true.

Store: Product/standby-quality.json, Owner=TradeChannel.StandbyQuality, Schema 1.
At most 16 entries / 128 KiB; same exclusive .store.lock and .tc-<guid>.tmp
atomic writes as NodeStore. No file lock during network I/O. A root-scoped
mutex excludes samplers and Revision invalidates late commits after cleanup.
NodeStore/cleanup/packaging must allow this exact regular file/module.
Clear with no NodeId invalidates all; cleanup must not restore on undo/import.

Default: 4 attempts/batch, 4000 ms whole measurement budget, 1000 ms/target,
60 seconds between attempts per target, 30 seconds between batches, freshness
180 seconds. Failures/timeouts replace previous successes. One retired worker
at most; no retry storm. All TCP attempts share the supplied budget; DNS names
are not resolved or measured in this version.
TCP success proves only port reachability, not tunnel authentication, HTTPS
exit quality or packet loss. Ranking compares only fresh TCP measurements.
Recommendations are manual suggestions, never an automatic action or a claim
that a TCP result is faster than the active exit's HTTPS round trip.

Measure/MeasureData/Clock are trusted test seams only (no closures in Measure):
  param($Candidate,$BudgetMilliseconds,$Data)
  @{Status='Measured';Reason='Measured';CandidateKey=$Candidate.Key;
    Source='TcpConnect';LatencyMs=50}
Tests inject measurements or use loopback TCP only.
#>

function SQField {
    param($Value,[string]$Name,$Default=$null)
    if ($Value -is [Collections.IDictionary]) { if ($Value.Contains($Name)) { return $Value[$Name] } }
    elseif ($null -ne $Value -and $Value.PSObject.Properties[$Name]) { return $Value.$Name }
    return $Default
}
function SQNow { param([scriptblock]$Clock) if ($Clock) { return ([DateTimeOffset](& $Clock)).ToUniversalTime() }; [DateTimeOffset]::UtcNow }
function SQDate { param($Value) $date=[DateTimeOffset]::MinValue; if ([DateTimeOffset]::TryParse([string]$Value,[ref]$date)) { return $date.ToUniversalTime() }; return $null }
function SQHash {
    param([string]$Text)
    $sha=[Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
}
function SQPath {
    param([string]$Path)
    if ($Path -notmatch '^[A-Za-z]:[\\/]') { throw 'Local absolute path required.' }
    $full=[IO.Path]::GetFullPath($Path)
    if ($full.Substring(2) -match '[:*?"<>|\x00-\x1f]') { throw 'Invalid path.' }
    $cursor=$full
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) { if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse points are not supported.' } }
        $parent=[IO.Path]::GetDirectoryName($cursor); if ($parent -eq $cursor) { break }; $cursor=$parent
    }
    $full
}
function SQCandidate {
    param($Value)
    $id=[guid]::Empty; $port=0; $address=$null
    if (-not [guid]::TryParse([string](SQField $Value NodeId ''),[ref]$id) -or $id -eq [guid]::Empty -or
        (SQField $Value ProfileId '') -cne 'Tcp' -or (SQField $Value Exit '') -cne 'hk' -or
        [string](SQField $Value ConfigHash '') -notmatch '^[a-fA-F0-9]{64}$' -or
        -not [int]::TryParse([string](SQField $Value Port ''),[ref]$port) -or $port -lt 1 -or $port -gt 65535) { throw 'Invalid TCP candidate.' }
    $hostName=[string](SQField $Value Host '')
    if (-not $hostName -or $hostName.Length -gt 253 -or $hostName -match '[\s/\\@?#%]') { throw 'Invalid TCP host.' }
    $literal=[Net.IPAddress]::TryParse($hostName,[ref]$address)
    if ($literal) {
        if ($address.Equals([Net.IPAddress]::Any) -or $address.Equals([Net.IPAddress]::IPv6Any) -or $address.Equals([Net.IPAddress]::Broadcast) -or $address.IsIPv6Multicast) { throw 'Invalid TCP address.' }
        $hostName=$address.ToString().ToLowerInvariant()
    } else {
        $hostName=(New-Object Globalization.IdnMapping).GetAscii($hostName.TrimEnd('.')).ToLowerInvariant()
        if ($hostName.Length -gt 253 -or $hostName -cnotmatch '^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*$') { throw 'Invalid DNS host.' }
    }
    $underlay=$null; $rawUnderlay=SQField $Value Underlay
    if ($null -ne $rawUnderlay) {
        $index=0; $interfaceId=[guid]::Empty; $sourceAddress=$null
        if (-not [int]::TryParse([string](SQField $rawUnderlay InterfaceIndex ''),[ref]$index) -or $index -le 0 -or
            -not [guid]::TryParse([string](SQField $rawUnderlay InterfaceId ''),[ref]$interfaceId) -or $interfaceId -eq [guid]::Empty -or
            [string](SQField $rawUnderlay NetworkFingerprint '') -notmatch '^[a-fA-F0-9]{64}$' -or
            -not [Net.IPAddress]::TryParse([string](SQField $rawUnderlay LocalAddress ''),[ref]$sourceAddress) -or $sourceAddress.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
            $sourceAddress.GetAddressBytes()[0] -eq 0 -or $sourceAddress.GetAddressBytes()[0] -ge 224 -or
            ([Net.IPAddress]::IsLoopback($sourceAddress) -and (-not $literal -or -not [Net.IPAddress]::IsLoopback($address)))) { throw 'Invalid underlay binding.' }
        $underlay=[pscustomobject][ordered]@{InterfaceIndex=$index;LocalAddress=$sourceAddress.ToString();InterfaceId=$interfaceId.ToString();NetworkFingerprint=([string](SQField $rawUnderlay NetworkFingerprint)).ToUpperInvariant()}
    }
    $probeEligible=$false; $probeReason='UnderlayUnavailable'; $pathScope='Unavailable'
    if (-not $literal) { $probeReason='DnsPathUnverified' }
    elseif ([Net.IPAddress]::IsLoopback($address)) { $probeEligible=$true; $probeReason='Ready'; $pathScope='LoopbackOnly' }
    elseif ($address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { $probeReason='AddressFamilyUnsupported' }
    elseif ($address.GetAddressBytes()[0] -eq 0 -or $address.GetAddressBytes()[0] -ge 224) { throw 'Invalid TCP address.' }
    elseif ($underlay) { $probeEligible=$true; $probeReason='Ready'; $pathScope='BoundPhysicalIPv4' }
    $binding=[pscustomobject][ordered]@{NodeId=$id.ToString(); ProfileId='Tcp'; Exit='hk'; Host=$hostName; Port=$port; ConfigHash=([string](SQField $Value ConfigHash)).ToUpperInvariant(); Underlay=$underlay}
    [pscustomobject]@{Key=(SQHash (ConvertTo-Json -InputObject $binding -Depth 4 -Compress)); Binding=$binding; ProbeEligible=$probeEligible; ProbeReason=$probeReason; PathScope=$pathScope}
}
function SQCandidates {
    param($Candidates,$Context)
    if (@($Candidates).Count -gt 16) { throw 'Too many candidates.' }
    $keys=@{}; $nodes=@{}
    foreach ($candidate in @($Candidates)) {
        if ($null -eq $candidate) { continue }
        $enabled=SQField $candidate Enabled $true
        if ($enabled -isnot [bool]) { throw 'Invalid candidate enablement.' }
        if (-not $enabled) { continue }
        $value=SQCandidate $candidate
        if ($Context.Binding -and $value.Binding.NodeId -ieq $Context.Binding.NodeId) { continue }
        if ($keys.ContainsKey($value.Key) -or $nodes.ContainsKey($value.Binding.NodeId)) { throw 'Duplicate or ambiguous candidate.' }
        $keys[$value.Key]=$true; $nodes[$value.Binding.NodeId]=$true; $value
    }
}
function SQNewState {
    [pscustomobject][ordered]@{SchemaVersion=1; Owner='TradeChannel.StandbyQuality'; Revision=[guid]::NewGuid().ToString('N'); BindingKey=''; Binding=$null; CandidateSetKey=''; LastAttemptAtUtc=$null; Entries=@()}
}
function SQOpenStore {
    param([string]$Root)
    $dir=SQPath (Join-Path $Root 'Product'); $null=[IO.Directory]::CreateDirectory($dir)
    $path=SQPath (Join-Path $dir '.store.lock')
    try { return [IO.File]::Open($path,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) } catch [IO.IOException] { return $null }
}
function SQNormalizeState {
    param($State)
    try {
        if ($state.SchemaVersion -ne 1 -or $state.Owner -cne 'TradeChannel.StandbyQuality' -or $state.Revision -cnotmatch '^[a-f0-9]{32}$' -or @($state.Entries).Count -gt 16 -or
            ($state.BindingKey -and $state.BindingKey -cnotmatch '^[a-f0-9]{64}$') -or ($state.CandidateSetKey -and $state.CandidateSetKey -cnotmatch '^[a-f0-9]{64}$') -or
            ($state.LastAttemptAtUtc -and -not (SQDate $state.LastAttemptAtUtc))) { throw 'Invalid store.' }
        if ($state.BindingKey) { if ($state.BindingKey -cne (SQHash (ConvertTo-Json -InputObject $state.Binding -Depth 4 -Compress))) { throw 'Invalid active binding.' } }
        elseif ($state.Binding) { throw 'Unbound active binding.' }
        $keys=@{}
        foreach ($entry in @($state.Entries)) {
            $candidate=SQCandidate $entry.Binding
            if ($entry.CandidateKey -cne $candidate.Key -or $keys.ContainsKey($entry.CandidateKey) -or $entry.Source -cne 'TcpConnect' -or
                -not (SQDate $entry.LastAttemptAtUtc) -or ($entry.AtUtc -and -not (SQDate $entry.AtUtc)) -or
                $entry.Reason -cnotin @('Pending','Measured','TcpUnavailable','MeasurementTimeout','MeasurementFailed','InvalidMeasurement','BudgetExhausted','UnderlayBindFailed')) { throw 'Invalid entry.' }
            if (($entry.Reason -ceq 'Pending' -and $null -ne $entry.AtUtc) -or ($entry.Reason -cne 'Pending' -and (SQDate $entry.AtUtc) -ne (SQDate $entry.LastAttemptAtUtc))) { throw 'Inconsistent attempt timestamp.' }
            $entry.Binding=$candidate.Binding; $keys[$entry.CandidateKey]=$true
            if ($entry.Reason -ceq 'Measured') {
                if (-not $candidate.ProbeEligible -or -not $entry.AtUtc -or $entry.LatencyMs -isnot [ValueType] -or $entry.LatencyMs -is [bool] -or [double]::IsNaN([double]$entry.LatencyMs) -or [double]::IsInfinity([double]$entry.LatencyMs) -or $entry.LatencyMs -lt 1 -or $entry.LatencyMs -gt 2000) { throw 'Invalid latency.' }
            } elseif ($null -ne $entry.LatencyMs) { throw 'Unavailable latency must be null.' }
        }
        return $state
    } catch { throw '[TC:StandbyQualityStore] 备用线路质量缓存不可读；原文件已保留。' }
}
function SQReadState {
    param([string]$Root)
    $path=SQPath (Join-Path $Root 'Product\standby-quality.json')
    if (-not [IO.File]::Exists($path)) { return (SQNewState) }
    $stream=$null; $reader=$null
    try {
        $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        if ($stream.Length -gt 131072) { throw 'Store size exceeded.' }
        $reader=New-Object IO.StreamReader($stream,(New-Object Text.UTF8Encoding($false,$true)),$true)
        $text=$reader.ReadToEnd(); if ([Text.Encoding]::UTF8.GetByteCount($text) -gt 131072) { throw 'Store size exceeded.' }
        SQNormalizeState (ConvertFrom-Json -InputObject $text -ErrorAction Stop)
    } catch { throw '[TC:StandbyQualityStore] 备用线路质量缓存不可读；原文件已保留。' }
    finally { if ($reader) { $reader.Dispose() } elseif ($stream) { $stream.Dispose() } }
}
function SQWriteState {
    param([string]$Root,$State)
    $path=SQPath (Join-Path $Root 'Product\standby-quality.json')
    $temp=SQPath (Join-Path (Split-Path $path -Parent) ('.tc-'+[guid]::NewGuid().ToString('N')+'.tmp'))
    $text=ConvertTo-Json -InputObject $State -Depth 8 -Compress
    if ([Text.Encoding]::UTF8.GetByteCount($text)+3 -gt 131072) { throw 'Store size exceeded.' }
    try {
        [IO.File]::WriteAllText($temp,$text,(New-Object Text.UTF8Encoding($true)))
        if ([IO.File]::Exists($path)) { [IO.File]::Replace($temp,$path,[NullString]::Value) } else { [IO.File]::Move($temp,$path) }
    } finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}
function SQSummary {
    param($State,$Context,$Candidates,[DateTimeOffset]$Now,[bool]$Enabled,[string]$OverrideReason='')
    $reason='Available'; $eligible=$Enabled -and $Context.Eligible
    if (-not $Enabled) { $reason='Disabled' } elseif (-not $Context.Eligible) { $reason=$Context.Reason }
    elseif (-not $State -or $State.BindingKey -cne $Context.Key) { $reason='BindingChanged'; $eligible=$false }
    if ($OverrideReason) { $reason=$OverrideReason; $eligible=$false }
    $items=@(foreach ($candidate in @($Candidates)) {
        $entry=$null; $ms=$null; $stamp=$null; $fresh=$false; $entryReason='NoSamples'; $next=$null
        if ($eligible -and $candidate.ProbeEligible) { $matches=@($State.Entries | Where-Object { $_.CandidateKey -ceq $candidate.Key }); if ($matches.Count -eq 1) { $entry=$matches[0] } }
        if (-not $candidate.ProbeEligible) { $entryReason=$candidate.ProbeReason }
        if ($entry) {
            $stamp=$entry.AtUtc; $attempt=SQDate $entry.LastAttemptAtUtc; $sample=SQDate $entry.AtUtc
            if ($attempt) { $next=$attempt.AddSeconds(60).ToString('o') }
            $entryReason=$entry.Reason
            if (-not $sample -or $sample -gt $Now -or ($Now-$sample).TotalSeconds -gt 180 -or $attempt -gt $Now) { $entryReason=if ($entry.Reason -eq 'Pending') { 'Pending' } else { 'SampleExpired' } }
            elseif ($entry.Reason -ceq 'Measured') { $fresh=$true; $ms=$entry.LatencyMs }
        }
        [pscustomobject][ordered]@{CandidateKey=$candidate.Key; Binding=$candidate.Binding; LatencyMs=$ms; Reason=$entryReason; SampleAtUtc=$stamp; NextSampleAtUtc=$next; Fresh=$fresh; Recommendable=$fresh; Source='TcpConnect'; PathScope=$candidate.PathScope; TunnelVerified=$false}
    })
    $ranked=@($items | Where-Object { $_.Recommendable } | Sort-Object LatencyMs,CandidateKey)
    $recommendation=$null
    if ($ranked.Count) {
        $best=$ranked[0]
        $recommendation=[pscustomobject][ordered]@{
            NodeId=$best.Binding.NodeId; ProfileId=$best.Binding.ProfileId; Exit=$best.Binding.Exit; CandidateKey=$best.CandidateKey
            LatencyMs=$best.LatencyMs; SampleAtUtc=$best.SampleAtUtc; ValidUntilUtc=(SQDate $best.SampleAtUtc).AddSeconds(180).ToString('o')
            ManualOnly=$true; Action='PreviewConnection'; Reason='FreshTcpReachability'; PathScope=$best.PathScope; TunnelVerified=$false
            Message='此备用线路的 TCP 端口可达，可手动测试并切换；连接能力仍需验证。'
        }
    }
    [pscustomobject][ordered]@{
        SchemaVersion=1; Reason=$reason; BindingKey=$Context.Key; Binding=$Context.Binding; Items=@($items); Recommendation=$recommendation
        Sampled=$false; AttemptedCount=0; Source='TcpConnect'; Metric='StandbyTcpConnect'; MeasurementLabel='备用线路 TCP 建连（指定本机网卡）'
        Limitation='仅验证绑定网卡后的 IPv4 TCP 端口可达，未建立隧道；与当前交易出口 HTTPS 延迟不能直接比较。域名未测量。'
        IntervalSeconds=60; BatchIntervalSeconds=30; FreshnessSeconds=180; MaxCandidates=16; MaxAttempts=4; MeasurementBudgetMs=4000; PerTargetBudgetMs=1000
        ManualOnly=$true; TunnelStarted=$false; TunnelVerified=$false; PacketLossPercent=$null; PacketLossMeasured=$false; NetworkChanged=$false; AutoSwitched=$false
    }
}
function Get-TCStandbyQualitySummary {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Root,$Overview,[object[]]$Candidates=@(),[bool]$Enabled=$true,[scriptblock]$Clock)
    $now=SQNow $Clock; $context=Get-TCLineQualityContext $Overview $now; $targets=@()
    try { $targets=@(SQCandidates $Candidates $context) } catch { return (SQSummary $null $context @() $now $Enabled 'CandidatesInvalid') }
    try { $state=SQReadState $Root; SQSummary $state $context $targets $now $Enabled }
    catch { SQSummary $null $context $targets $now $Enabled 'StoreUnavailable' }
}
function Remove-TCStandbyQualityOwnedState {
    <# Deterministic journal transformation: no I/O, lock, clock, randomness or
       input mutation. Empty means no current or candidate ownership remains. #>
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$State,[string[]]$NodeId=@())
    $ErrorActionPreference='Stop'
    $ids=@(@(foreach ($id in $NodeId) { $guid=[guid]::Empty; if (-not [guid]::TryParse($id,[ref]$guid) -or $guid -eq [guid]::Empty) { throw 'Invalid node ID.' }; $guid.ToString() }) | Sort-Object -Unique)
    $text=ConvertTo-Json -InputObject $State -Depth 10 -Compress -WarningAction Stop
    if ([Text.Encoding]::UTF8.GetByteCount($text)+3 -gt 131072) { throw 'Standby quality store exceeds its bound.' }
    $copy=SQNormalizeState (ConvertFrom-Json -InputObject $text -ErrorAction Stop)
    $activeRemoved=[string](SQField $copy.Binding NodeId '') -in $ids
    $matched=@($copy.Entries | Where-Object { $_.Binding.NodeId -in $ids })
    if (-not $activeRemoved -and -not $matched.Count) { return [pscustomobject]@{Changed=$false;Value=$State;Empty=$false} }
    $seed='TradeChannel.StandbyQuality.cleanup.v1|'+$copy.Revision+'|'+($ids -join ',')
    $copy.Entries=@($copy.Entries | Where-Object { $_.Binding.NodeId -notin $ids }); $copy.CandidateSetKey=''; $copy.Revision=(SQHash $seed).Substring(0,32)
    if ($activeRemoved) { $copy.BindingKey=''; $copy.Binding=$null; $copy.LastAttemptAtUtc=$null }
    [pscustomobject]@{Changed=$true;Value=$copy;Empty=(-not $copy.BindingKey -and -not @($copy.Entries).Count)}
}
function Clear-TCStandbyQuality {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Root,[string[]]$NodeId=@(),[IO.FileStream]$StoreLock)
    $ErrorActionPreference='Stop'; $lock=$null; $owned=$false
    try {
        $ids=@(foreach ($id in $NodeId) { $guid=[guid]::Empty; if (-not [guid]::TryParse($id,[ref]$guid) -or $guid -eq [guid]::Empty) { throw 'Invalid node ID.' }; $guid.ToString() })
        if ($StoreLock) {
            if (-not $StoreLock.CanRead -or -not $StoreLock.CanWrite -or $StoreLock.SafeFileHandle.IsClosed -or [IO.Path]::GetFullPath($StoreLock.Name) -ine (SQPath (Join-Path $Root 'Product\.store.lock'))) { throw 'Invalid store lock.' }
            $lock=$StoreLock
        } else { $lock=SQOpenStore $Root; $owned=$true }
        if (-not $lock) { return [pscustomobject]@{Cleared=$false; Reason='StoreBusy'; NetworkChanged=$false} }
        $state=SQReadState $Root; $before=@($state.Entries).Count
        if ($ids.Count) {
            $change=Remove-TCStandbyQualityOwnedState -State $state -NodeId $ids
            if (-not $change.Changed) { return [pscustomobject]@{Cleared=$false; Reason='OtherLine'; NetworkChanged=$false} }
            $state=$change.Value
        } else { $state=SQNewState }
        SQWriteState $Root $state
        [pscustomobject]@{Cleared=$true; Reason='Cleared'; RemovedEntries=($before-@($state.Entries).Count); NetworkChanged=$false}
    } catch { [pscustomobject]@{Cleared=$false; Reason='StoreUnavailable'; NetworkChanged=$false} }
    finally { if ($lock -and $owned) { $lock.Dispose() } }
}
function SQResult {
    param($Candidate,[string]$Reason='MeasurementFailed',$LatencyMs=$null)
    [pscustomobject]@{Status=$(if ($Reason -ceq 'Measured') {'Measured'} else {'Unavailable'}); Reason=$Reason; CandidateKey=$Candidate.Key; Source='TcpConnect'; LatencyMs=$LatencyMs}
}
function SQNewTcpClient { param([Net.Sockets.AddressFamily]$AddressFamily) New-Object Net.Sockets.TcpClient($AddressFamily) }
function SQTcpMeasure {
    param($Candidate,[int]$BudgetMilliseconds)
    $socket=$null; $wait=$null; $watch=[Diagnostics.Stopwatch]::StartNew(); $failureReason='TcpUnavailable'
    try {
        if (-not $Candidate.ProbeEligible) { return (SQResult $Candidate 'UnderlayBindFailed') }
        $address=$null
        if ([Net.IPAddress]::TryParse([string]$Candidate.Binding.Host,[ref]$address)) {
            $socket=SQNewTcpClient $address.AddressFamily
            if ($Candidate.Binding.Underlay) {
                $failureReason='UnderlayBindFailed'; $binding=$Candidate.Binding.Underlay
                $socket.Client.Bind((New-Object Net.IPEndPoint([Net.IPAddress]::Parse($binding.LocalAddress),0)))
                $socket.Client.SetSocketOption([Net.Sockets.SocketOptionLevel]::IP,[Net.Sockets.SocketOptionName]31,[Net.IPAddress]::HostToNetworkOrder([int]$binding.InterfaceIndex))
                $failureReason='TcpUnavailable'
            }
            $pending=$socket.BeginConnect($address,[int]$Candidate.Binding.Port,$null,$null)
        } else {
            return (SQResult $Candidate 'UnderlayBindFailed')
        }
        $wait=$pending.AsyncWaitHandle
        $remaining=[int][Math]::Max(0,$BudgetMilliseconds-$watch.ElapsedMilliseconds)
        if (-not $wait.WaitOne($remaining)) { return (SQResult $Candidate 'MeasurementTimeout') }
        $socket.EndConnect($pending)
        if ($Candidate.Binding.Underlay -and $socket.Client.LocalEndPoint.Address.ToString() -cne $Candidate.Binding.Underlay.LocalAddress) { return (SQResult $Candidate 'UnderlayBindFailed') }
        if (-not $socket.Connected -or $watch.ElapsedMilliseconds -ge $BudgetMilliseconds) { return (SQResult $Candidate 'MeasurementTimeout') }
        SQResult $Candidate 'Measured' ([int][Math]::Max(1,[Math]::Ceiling($watch.Elapsed.TotalMilliseconds)))
    } catch { SQResult $Candidate $failureReason }
    finally { if ($socket) { $socket.Close() }; if ($wait) { $wait.Dispose() } }
}
function SQReapWorker {
    if (-not $script:SQRetiredWorker) { return $true }
    $worker=$script:SQRetiredWorker; if (-not $worker.Stop.IsCompleted) { return $false }
    try { $worker.PowerShell.EndStop($worker.Stop) } catch {}
    $worker.PowerShell.Dispose(); $script:SQRetiredWorker=$null; return $true
}
function SQRunMeasurement {
    param($Candidate,[scriptblock]$Measure,$MeasureData,[int]$BudgetMilliseconds)
    if (-not (SQReapWorker)) { return (SQResult $Candidate 'MeasurementTimeout') }
    $watch=[Diagnostics.Stopwatch]::StartNew(); $worker=[PowerShell]::Create(); $retained=$false
    $body=@'
param($ModulePath,$Candidate,$MeasureText,$Data,$Watch,$Budget)
$ErrorActionPreference='Stop'
if($MeasureText){
    & ([scriptblock]::Create($MeasureText)) $Candidate ([int][Math]::Max(1,$Budget-$Watch.ElapsedMilliseconds)) $Data
}else{
    $module=Import-Module $ModulePath -PassThru -DisableNameChecking
    & $module {param($c,$w,$b) $remaining=[int]($b-$w.ElapsedMilliseconds); if($remaining -le 0){SQResult $c 'MeasurementTimeout'}else{SQTcpMeasure $c $remaining}} $Candidate $Watch $Budget
}
'@
    try {
        $null=$worker.AddScript($body).AddArgument((Join-Path $script:SQPackage 'StandbyQuality.psm1')).AddArgument($Candidate).AddArgument([string]$Measure).AddArgument($MeasureData).AddArgument($watch).AddArgument($BudgetMilliseconds)
        $pending=$worker.BeginInvoke(); $remaining=[int][Math]::Max(0,$BudgetMilliseconds-$watch.ElapsedMilliseconds)
        if (-not $pending.AsyncWaitHandle.WaitOne($remaining)) {
            $stop=$worker.BeginStop($null,$null)
            if ($stop.AsyncWaitHandle.WaitOne(100)) { try { $worker.EndStop($stop) } catch {} }
            else { $script:SQRetiredWorker=[pscustomobject]@{PowerShell=$worker; Stop=$stop}; $retained=$true }
            return (SQResult $Candidate 'MeasurementTimeout')
        }
        $values=@($worker.EndInvoke($pending))
        if ($watch.ElapsedMilliseconds -gt $BudgetMilliseconds) { return (SQResult $Candidate 'MeasurementTimeout') }
        if ($worker.HadErrors -or $values.Count -ne 1) { return (SQResult $Candidate 'InvalidMeasurement') }
        return $values[0]
    } catch { return (SQResult $Candidate 'MeasurementFailed') }
    finally { if (-not $retained) { $worker.Dispose() } }
}
function Invoke-TCStandbyQualitySample {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Root,$Overview,[object[]]$Candidates=@(),[bool]$Enabled=$true,
        [scriptblock]$Measure,$MeasureData=$null,[scriptblock]$Clock,
        [ValidateRange(100,6000)][int]$BudgetMilliseconds=4000,
        [ValidateRange(100,2000)][int]$PerTargetBudgetMilliseconds=1000,
        [ValidateRange(1,4)][int]$MaxAttempts=4
    )
    $ErrorActionPreference='Stop'; $now=SQNow $Clock; $context=Get-TCLineQualityContext $Overview $now
    $targets=@(); $lock=$null; $mutex=$null; $owned=$false
    try { $targets=@(SQCandidates $Candidates $context) } catch { return (SQSummary $null $context @() $now $Enabled 'CandidatesInvalid') }
    try {
        $rootPath=(SQPath $Root).TrimEnd('\')
        if (-not $Enabled -or -not $context.Eligible) {
            $lock=SQOpenStore $rootPath
            if (-not $lock) { return (SQSummary $null $context $targets $now $Enabled 'StoreBusy') }
            $state=SQReadState $rootPath
            if ($state.BindingKey -or @($state.Entries).Count) { SQWriteState $rootPath (SQNewState) }
            return (SQSummary $null $context $targets $now $Enabled)
        }
        $mutex=New-Object Threading.Mutex($false,('Local\TradeChannel-StandbyQuality-'+(SQHash $rootPath.ToLowerInvariant())))
        try { $owned=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned=$true }
        if (-not $owned) {
            $view=Get-TCStandbyQualitySummary -Root $Root -Overview $Overview -Candidates $Candidates -Enabled $Enabled -Clock $Clock
            $view | Add-Member NoteProperty SkipReason 'SamplingBusy'; return $view
        }
        $lock=SQOpenStore $rootPath
        if (-not $lock) { return (SQSummary $null $context $targets $now $Enabled 'StoreBusy') }
        $state=SQReadState $rootPath; $lastAttempt=SQDate $state.LastAttemptAtUtc
        if ($state.BindingKey -cne $context.Key -or ($lastAttempt -and $lastAttempt -gt $now)) { $state=SQNewState; $state.BindingKey=$context.Key; $state.Binding=$context.Binding; $lastAttempt=$null }
        $targetKeys=@($targets | ForEach-Object { $_.Key }); $setKey=SQHash ((@($targetKeys | Sort-Object)) -join '|')
        if ($state.CandidateSetKey -cne $setKey) {
            $state.Entries=@($state.Entries | Where-Object { $_.CandidateKey -cin $targetKeys }); $state.CandidateSetKey=$setKey
            $state.Revision=[guid]::NewGuid().ToString('N'); SQWriteState $rootPath $state
        }
        if ($lastAttempt -and ($now-$lastAttempt).TotalSeconds -lt 30) { return (SQSummary $state $context $targets $now $Enabled) }
        $due=@(@(foreach ($target in $targets) {
            if (-not $target.ProbeEligible) { continue }
            $entries=@($state.Entries | Where-Object { $_.CandidateKey -ceq $target.Key })
            $attempt=$null; if ($entries.Count) { $attempt=SQDate $entries[0].LastAttemptAtUtc }
            if (-not $attempt -or $attempt -gt $now -or ($now-$attempt).TotalSeconds -ge 60) { [pscustomobject]@{Target=$target; Attempt=$(if ($attempt) { $attempt } else { [DateTimeOffset]::MinValue })} }
        }) | Sort-Object Attempt,@{Expression={$_.Target.Key}} | Select-Object -First $MaxAttempts)
        if (-not $due.Count) { return (SQSummary $state $context $targets $now $Enabled) }
        $state.LastAttemptAtUtc=$now.ToString('o'); $state.Revision=[guid]::NewGuid().ToString('N'); $ticket=$state.Revision
        foreach ($item in $due) {
            $state.Entries=@($state.Entries | Where-Object { $_.CandidateKey -cne $item.Target.Key })
            $state.Entries+=,[pscustomobject]@{CandidateKey=$item.Target.Key; Binding=$item.Target.Binding; LastAttemptAtUtc=$now.ToString('o'); AtUtc=$null; LatencyMs=$null; Source='TcpConnect'; Reason='Pending'}
        }
        SQWriteState $rootPath $state; $lock.Dispose(); $lock=$null
        $watch=[Diagnostics.Stopwatch]::StartNew(); $results=@{}; $attempted=0
        foreach ($item in $due) {
            $remaining=[int][Math]::Max(0,$BudgetMilliseconds-$watch.ElapsedMilliseconds)
            if ($remaining -lt 100) { $results[$item.Target.Key]=SQResult $item.Target 'BudgetExhausted'; continue }
            $slice=[int][Math]::Min($PerTargetBudgetMilliseconds,$remaining); $attempted++
            $result=SQRunMeasurement $item.Target $Measure $MeasureData $slice
            $ms=$null; $reason='InvalidMeasurement'; $value=SQField $result LatencyMs
            if ((SQField $result CandidateKey '') -ceq $item.Target.Key -and (SQField $result Source '') -ceq 'TcpConnect') {
                if ((SQField $result Status '') -ceq 'Measured' -and $value -is [ValueType] -and $value -isnot [bool] -and
                    -not [double]::IsNaN([double]$value) -and -not [double]::IsInfinity([double]$value) -and $value -ge 1 -and $value -le $slice) { $ms=[int][Math]::Ceiling([double]$value); $reason='Measured' }
                elseif ((SQField $result Status '') -ceq 'Unavailable' -and (SQField $result Reason '') -cin @('TcpUnavailable','MeasurementTimeout','MeasurementFailed','InvalidMeasurement','UnderlayBindFailed')) { $reason=[string]$result.Reason }
            }
            $results[$item.Target.Key]=SQResult $item.Target $reason $ms
        }
        $finished=SQNow $Clock; $lock=SQOpenStore $rootPath
        if (-not $lock) { return (SQSummary $null $context $targets $finished $Enabled 'StoreBusy') }
        $state=SQReadState $rootPath
        if ($state.Revision -cne $ticket -or $state.BindingKey -cne $context.Key -or $state.CandidateSetKey -cne $setKey) { return (SQSummary $null $context $targets $finished $Enabled 'BindingChanged') }
        if ($finished -lt $now -or ($finished-$now).TotalSeconds -gt 180) { SQWriteState $rootPath (SQNewState); return (SQSummary $null $context $targets $finished $Enabled 'BindingChanged') }
        foreach ($entry in $state.Entries) { if ($results.ContainsKey($entry.CandidateKey)) { $result=$results[$entry.CandidateKey]; $entry.LatencyMs=$result.LatencyMs; $entry.Reason=$result.Reason; $entry.AtUtc=$now.ToString('o') } }
        $state.Revision=[guid]::NewGuid().ToString('N'); SQWriteState $rootPath $state
        $view=SQSummary $state $context $targets $finished $Enabled; $view.Sampled=$true; $view.AttemptedCount=$attempted; $view.MeasurementBudgetMs=$BudgetMilliseconds; $view.PerTargetBudgetMs=$PerTargetBudgetMilliseconds; $view.MaxAttempts=$MaxAttempts
        return $view
    } catch { return (SQSummary $null $context $targets $now $Enabled 'StoreUnavailable') }
    finally { if ($lock) { $lock.Dispose() }; if ($owned -and $mutex) { $mutex.ReleaseMutex() }; if ($mutex) { $mutex.Dispose() } }
}

Export-ModuleMember -Function Invoke-TCStandbyQualitySample,Get-TCStandbyQualitySummary,Clear-TCStandbyQuality,Remove-TCStandbyQualityOwnedState
