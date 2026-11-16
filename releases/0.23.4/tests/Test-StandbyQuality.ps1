#requires -Version 5.1
# All remote-looking measurements are injected. Actual sockets use 127.0.0.1 only.
[CmdletBinding()]param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$package=Split-Path $PSScriptRoot -Parent
$modulePath=Join-Path $package 'StandbyQuality.psm1'
$module=Import-Module $modulePath -Force -PassThru -DisableNameChecking
$fixtureBase=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$work=Join-Path $fixtureBase ('TC-StandbyQuality-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($work)
$script:Checks=0
$timer=@{Now=[DateTimeOffset]'2026-10-16T10:00:00Z'}; $clock={ $timer.Now }.GetNewClosure()
$data=@{Calls=0;Latency=45;SleepMs=0;Throw=$false;Source='TcpConnect';Status='Measured';Reason='Measured';WrongKey=$false;Action='';Root='';ModulePath=$modulePath;NodeId='';Overview=$null;Candidates=@();Now=$null;Nested=$null}
$measure={
    param($Candidate,$BudgetMilliseconds,$Data)
    $Data.Calls++
    if ($BudgetMilliseconds -lt 1 -or $BudgetMilliseconds -gt 2000) { throw 'Invalid budget.' }
    if ($Data.Throw) { throw 'fixture-secret must never escape' }
    if ($Data.SleepMs -gt 0) { Start-Sleep -Milliseconds $Data.SleepMs }
    if ($Data.Action -eq 'Clear') { Import-Module $Data.ModulePath -DisableNameChecking; $null=Clear-TCStandbyQuality -Root $Data.Root -NodeId $Data.NodeId }
    if ($Data.Action -in @('Overlap','Disconnect','EmptySet')) {
        Import-Module $Data.ModulePath -DisableNameChecking
        $fixtureClock={ $Data.Now }.GetNewClosure()
        $Data.Nested=Invoke-TCStandbyQualitySample -Root $Data.Root -Overview $Data.Overview -Candidates $Data.Candidates -Measure { throw 'Nested measure must never run.' } -Clock $fixtureClock
    }
    @{Status=$Data.Status;Reason=$Data.Reason;CandidateKey=$(if ($Data.WrongKey) {'wrong'} else {$Candidate.Key});Source=$Data.Source;LatencyMs=$Data.Latency}
}
function Check { param([bool]$Ok,[string]$Label) if (-not $Ok) { throw ('StandbyQuality check failed: '+$Label) }; $script:Checks++ }
function Overview {
    [pscustomobject]@{Running=$true;StateKey='Connected';SessionId='standby-session';ActiveLineId='11111111-1111-1111-1111-111111111111';ActiveProfileId='Udp';ProfileBindingVerified=$true;NodeId='99999999-9999-9999-9999-999999999999';Exit='hk';ConfigHash=('A'*64);EnginePid=1234;ConnectedSince='2026-10-15T00:00:00Z';ManifestPath=(Join-Path $work 'manifest.json');Mode='rule';ObservedAt=$timer.Now.ToString('o')}
}
function Candidate {
    param([int]$Number=2,[int]$Port=443)
    [pscustomobject]@{NodeId=('{0:d8}-2222-2222-2222-222222222222' -f $Number);ProfileId='Tcp';Exit='hk';Host='127.0.0.1';Port=$Port;ConfigHash=('B'*64);Enabled=$true}
}
function Tick {
    param([int]$Seconds=60)
    $timer.Now=$timer.Now.AddSeconds($Seconds); $overview.ObservedAt=$timer.Now.ToString('o')
    Invoke-TCStandbyQualitySample -Root $root -Overview $overview -Candidates $candidates -Clock $clock -Measure $measure -MeasureData $data
}
function View {
    $overview.ObservedAt=$timer.Now.ToString('o')
    Get-TCStandbyQualitySummary -Root $root -Overview $overview -Candidates $candidates -Clock $clock
}
try {
    foreach ($file in @($modulePath,$PSCommandPath)) {
        $bytes=[IO.File]::ReadAllBytes($file); Check ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) ('UTF8 BOM '+[IO.Path]::GetFileName($file))
        $tokens=$null; $errors=$null; $null=[Management.Automation.Language.Parser]::ParseFile($file,[ref]$tokens,[ref]$errors)
        Check (@($errors).Count -eq 0) ('PowerShell parser '+[IO.Path]::GetFileName($file))
    }
    $root=Join-Path $work 'lifecycle'; $overview=Overview; $candidates=@((Candidate 2),(Candidate 3))
    $first=Tick 0
    Check ($first.Sampled -and $first.AttemptedCount -eq 2 -and $first.Items.Count -eq 2 -and $first.Recommendation.ManualOnly -and $first.Recommendation.LatencyMs -eq 45) ('fresh TCP results allow a manual suggestion: '+$first.Reason)
    Check (-not $first.AutoSwitched -and -not $first.NetworkChanged -and -not $first.TunnelStarted -and -not $first.TunnelVerified -and -not $first.PacketLossMeasured -and $null -eq $first.PacketLossPercent) 'no tunnel, switching, authentication or fabricated loss'
    Check ($first.Metric -eq 'StandbyTcpConnect' -and $first.MeasurementLabel.Contains('TCP') -and $first.Limitation.Contains('HTTPS')) 'TCP evidence remains visibly distinct from active HTTPS RTT'
    $path=Join-Path $root 'Product\standby-quality.json'; $bytes=[IO.File]::ReadAllBytes($path)
    Check ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191 -and $bytes.Length -lt 131072) 'small persistent cache uses UTF8 BOM'
    $before=[IO.File]::ReadAllText($path); $calls=$data.Calls; $cached=Tick 29
    Check (-not $cached.Sampled -and $data.Calls -eq $calls -and [IO.File]::ReadAllText($path) -ceq $before) '29-second batch interval does not probe or rewrite'
    $cached=Tick 30
    Check (-not $cached.Sampled -and $data.Calls -eq $calls) '59-second target interval still returns cache'
    $again=Tick 1; Check ($again.Sampled -and $data.Calls -eq ($calls+2)) '60-second target boundary may measure again'
    $timer.Now=$timer.Now.AddSeconds(180); $boundary=View
    Check ($null -ne $boundary.Recommendation) '180-second freshness boundary is inclusive'
    $timer.Now=$timer.Now.AddSeconds(1); $expired=View
    Check ($null -eq $expired.Recommendation -and @($expired.Items|Where-Object Fresh).Count -eq 0 -and $expired.Items[0].Reason -eq 'SampleExpired') 'expired successes never produce recommendations'
    $data.Status='Unavailable'; $data.Reason='TcpUnavailable'; $data.Latency=$null; $failed=Tick
    Check ($null -eq $failed.Recommendation -and $null -eq $failed.Items[0].LatencyMs -and $failed.Items[0].Reason -eq 'TcpUnavailable') 'latest failure replaces previous good result'
    $data.Status='Measured'; $data.Reason='Measured'; $data.Latency=55; $null=Tick
    foreach ($field in @('Host','Port','ConfigHash','NodeId')) {
        $old=$candidates[0].$field
        $candidates[0].$field=switch ($field) { Host {'127.0.0.2'}; Port {444}; ConfigHash {('C'*64)}; NodeId {'77777777-7777-7777-7777-777777777777'} }
        $changed=View; Check (-not $changed.Items[0].Recommendable -and $null -eq $changed.Items[0].LatencyMs) ('changed candidate '+$field+' cannot inherit evidence')
        $candidates[0].$field=$old
    }
    foreach ($change in @(@('SessionId','new-session'),@('ActiveProfileId','Tcp'),@('Exit','provider2-trade'),@('ConfigHash',('C'*64)))) {
        $old=$overview.($change[0]); $overview.($change[0])=$change[1]; $changed=View
        Check ($null -eq $changed.Recommendation -and $changed.Reason -eq 'BindingChanged') ('active '+$change[0]+' invalidates a stale suggestion')
        $overview.($change[0])=$old
    }
    $candidates[0].Enabled=$false; $enabled=View
    Check ($enabled.Items.Count -eq 1 -and $enabled.Items[0].Binding.NodeId -eq $candidates[1].NodeId) 'disabled candidate is absent from suggestions'
    $candidates[0].Enabled=$true; $candidates[0].NodeId=$overview.ActiveLineId; $active=View
    Check ($active.Items.Count -eq 1) 'current actual line is never offered as standby'
    $candidates[0]=Candidate 2
    $calls=$data.Calls; $disabled=Invoke-TCStandbyQualitySample -Root $root -Overview $overview -Candidates $candidates -Enabled $false -Clock $clock -Measure $measure -MeasureData $data
    Check ($disabled.Reason -eq 'Disabled' -and $null -eq $disabled.Recommendation -and $data.Calls -eq $calls -and (View).Recommendation -eq $null) 'disabled sampling invalidates saved recommendations without probing'
    $null=Tick; $overview.ObservedAt=$timer.Now.AddSeconds(-16).ToString('o'); $calls=$data.Calls
    $stale=Invoke-TCStandbyQualitySample -Root $root -Overview $overview -Candidates $candidates -Clock $clock -Measure $measure -MeasureData $data
    Check ($stale.Reason -eq 'ObservationStale' -and $null -eq $stale.Recommendation -and $data.Calls -eq $calls) 'stale overview never authorizes a probe'

    $root=Join-Path $work 'validation'; $overview=Overview; $candidates=@(Candidate 2)
    foreach ($value in @($null,0,-1,2001,[double]::NaN,[double]::PositiveInfinity,'42',$true)) {
        $data.Latency=$value; $bad=Tick
        Check ($null -eq $bad.Recommendation -and $null -eq $bad.Items[0].LatencyMs) 'invalid injected numeric results are never recommended'
    }
    $data.Latency=45; $data.Source='ControllerDelay'; $bad=Tick
    Check ($null -eq $bad.Recommendation -and $bad.Items[0].Reason -eq 'InvalidMeasurement') 'HTTPS evidence cannot be substituted for standby TCP'
    $data.Source='TcpConnect'; $data.WrongKey=$true; $bad=Tick
    Check ($null -eq $bad.Recommendation) 'wrong endpoint result rejected'; $data.WrongKey=$false
    $data.Throw=$true; $bad=Tick; $data.Throw=$false
    Check ($null -eq $bad.Recommendation -and -not (ConvertTo-Json -InputObject $bad -Depth 10).Contains('fixture-secret')) 'measurement exception is sanitized'
    foreach ($edit in @(@('Host','https://127.0.0.1'),@('Host','bad host'),@('Host','0.0.0.0'),@('Port',0),@('Port',65536),@('ProfileId','Udp'),@('Exit','provider'),@('ConfigHash','bad'),@('Enabled','true'))) {
        $old=$candidates[0].($edit[0]); $candidates[0].($edit[0])=$edit[1]; $calls=$data.Calls; $bad=Tick
        Check ($bad.Reason -eq 'CandidatesInvalid' -and $data.Calls -eq $calls) ('invalid candidate '+$edit[0]+' does not probe')
        $candidates[0].($edit[0])=$old
    }
    $candidates=@((Candidate 2),(Candidate 2)); $calls=$data.Calls; $bad=Tick
    Check ($bad.Reason -eq 'CandidatesInvalid' -and $data.Calls -eq $calls) 'duplicate endpoint ownership is rejected'
    $candidates=@(for ($i=2;$i -le 18;$i++) { Candidate $i }); $bad=Tick
    Check ($bad.Reason -eq 'CandidatesInvalid') 'more than sixteen candidates is rejected'
    $candidates=@(); $empty=Tick
    Check ($empty.Items.Count -eq 0 -and $null -eq $empty.Recommendation -and -not $empty.Sampled -and $empty.Reason -eq 'Available') 'empty set removes old candidates without network work'

    $root=Join-Path $work 'underlay'; $overview=Overview; $candidates=@(Candidate 2); $candidates[0].Host='203.0.113.10'; $calls=$data.Calls
    $unbound=Tick
    Check (-not $unbound.Sampled -and $unbound.Items[0].Reason -eq 'UnderlayUnavailable' -and $null -eq $unbound.Recommendation -and $data.Calls -eq $calls) 'non-loopback target without underlay cannot probe via current TUN or recommend'
    $underlay=[pscustomobject]@{InterfaceIndex=7;LocalAddress='192.0.2.20';InterfaceId='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';NetworkFingerprint=('D'*64)}
    $candidates[0]|Add-Member NoteProperty Underlay $underlay
    $candidates[0].Host='standby.example.invalid'; $dns=Tick
    Check (-not $dns.Sampled -and $dns.Items[0].Reason -eq 'DnsPathUnverified' -and $null -eq $dns.Recommendation -and $data.Calls -eq $calls) 'DNS targets remain unknown without pretending resolver traffic is independent'
    $candidates[0].Host='2001:db8::10'; $ipv6=Tick
    Check (-not $ipv6.Sampled -and $ipv6.Items[0].Reason -eq 'AddressFamilyUnsupported' -and $data.Calls -eq $calls) 'unsupported IPv6 is not sent through an unbound socket'
    $candidates[0].Host='203.0.113.10'; $bound=Tick
    Check ($bound.Sampled -and $bound.Items[0].Recommendable -and $bound.Items[0].PathScope -eq 'BoundPhysicalIPv4') 'injected physical-underlay success retains its explicit path scope'
    foreach ($edit in @(@('InterfaceIndex',8),@('LocalAddress','192.0.2.21'),@('InterfaceId','bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'),@('NetworkFingerprint',('E'*64)))) {
        $old=$underlay.($edit[0]); $underlay.($edit[0])=$edit[1]; $changed=View
        Check ($null -eq $changed.Recommendation -and $changed.Items[0].CandidateKey -cne $bound.Items[0].CandidateKey) ('underlay '+$edit[0]+' change invalidates old evidence')
        $underlay.($edit[0])=$old
    }
    $underlay.LocalAddress='127.0.0.1'; $bad=Tick
    Check ($bad.Reason -eq 'CandidatesInvalid') 'loopback source cannot masquerade as physical underlay for an external target'

    $root=Join-Path $work 'schedule'; $overview=Overview; $candidates=@(for ($i=2;$i -lt 18;$i++) { Candidate $i })
    for ($i=0;$i -lt 4;$i++) { $round=Tick 30; Check ($round.AttemptedCount -eq 4) 'batch obeys four-target cap' }
    $disk=[IO.File]::ReadAllText((Join-Path $root 'Product\standby-quality.json'))|ConvertFrom-Json
    Check ($disk.Entries.Count -eq 16 -and @($round.Items | Where-Object Recommendable).Count -eq 16) 'least-recent scheduling visits all candidates without starvation'
    $old=$timer.Now; $timer.Now=$timer.Now.AddSeconds(-300); $rollback=Tick 0
    Check ($rollback.Sampled -and @($rollback.Items|Where-Object Recommendable).Count -eq 4) 'clock rollback discards future successes before fresh measurements'
    $timer.Now=$old

    $root=Join-Path $work 'cleanup'; $overview=Overview; $candidates=@((Candidate 2),(Candidate 3)); $null=Tick 0
    $lock=[IO.File]::Open((Join-Path $root 'Product\.store.lock'),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {
        $calls=$data.Calls; $watch=[Diagnostics.Stopwatch]::StartNew(); $busy=Tick
        Check ($busy.Reason -eq 'StoreBusy' -and $data.Calls -eq $calls -and $watch.ElapsedMilliseconds -lt 1000) 'contention skips without waiting'
        $clear=Clear-TCStandbyQuality -Root $root -NodeId $candidates[0].NodeId -StoreLock $lock; $remaining=View
        Check ($clear.Cleared -and $clear.RemovedEntries -eq 1 -and $lock.CanWrite -and -not $remaining.Items[0].Recommendable -and $remaining.Items[1].Recommendable) 'lock-held cleanup removes one owner and preserves the other'
        $wrong=Clear-TCStandbyQuality -Root (Join-Path $work 'wrong-lock-root') -StoreLock $lock
        Check (-not $wrong.Cleared -and -not (Test-Path -LiteralPath (Join-Path $work 'wrong-lock-root'))) 'wrong-root lock cannot clear another store'
    } finally { $lock.Dispose() }
    $null=Tick; $clear=Clear-TCStandbyQuality -Root $root -NodeId $overview.ActiveLineId
    Check ($clear.Cleared -and $null -eq (View).Recommendation) 'deleting the active observation owner invalidates all its standby suggestions'
    $root=Join-Path $work 'inflight'; $overview=Overview; $candidates=@(Candidate 2); $data.Root=$root; $data.NodeId=$candidates[0].NodeId; $data.Action='Clear'
    $late=Tick 0; $data.Action=''
    Check ($late.Reason -eq 'BindingChanged' -and $null -eq (View).Recommendation) 'deleted pending entry cannot be resurrected by late TCP success'
    $data.Action='Overlap'; $data.Overview=$overview; $data.Candidates=$candidates; $data.Now=$timer.Now.AddSeconds(60)
    $overlap=Tick
    Check ($overlap.Sampled -and $data.Nested.SkipReason -eq 'SamplingBusy') 'root mutex excludes a concurrent probe'
    $data.Action='Disconnect'; $data.Overview=Overview; $data.Overview.Running=$false; $data.Overview.StateKey='Disconnected'; $data.Now=$timer.Now.AddSeconds(60)
    $late=Tick; $data.Action=''
    Check ($late.Reason -eq 'BindingChanged' -and $data.Nested.Reason -eq 'Disconnected' -and $null -eq (View).Recommendation) 'disconnect invalidates reservations without waiting for sampler mutex'

    $root=Join-Path $work 'timeout'; $overview=Overview; $candidates=@((Candidate 2),(Candidate 3)); $data.SleepMs=10000
    $watch=[Diagnostics.Stopwatch]::StartNew()
    $timeout=Invoke-TCStandbyQualitySample -Root $root -Overview $overview -Candidates $candidates -Clock $clock -Measure $measure -MeasureData $data -BudgetMilliseconds 250 -PerTargetBudgetMilliseconds 200
    $timeoutMs=$watch.ElapsedMilliseconds; $data.SleepMs=0
    Check ($null -eq $timeout.Recommendation -and $timeoutMs -lt 1500 -and @($timeout.Items|Where-Object {$_.Reason -in @('MeasurementTimeout','BudgetExhausted')}).Count -eq 2) 'total budget stops hanging probes and never recommends unmeasured targets'
    $recovered=Tick; Check ($null -ne $recovered.Recommendation) 'sampling recovers after cancelled worker'
    $root=Join-Path $work 'noncooperative'; $overview=Overview; $candidates=@(Candidate 2); $sticky=@{Calls=0}
    $stickyMeasure={param($Candidate,$BudgetMilliseconds,$Data) $Data.Calls++; [Threading.Thread]::Sleep(1200); @{Status='Measured';Reason='Measured';CandidateKey=$Candidate.Key;Source='TcpConnect';LatencyMs=10}}
    $watch=[Diagnostics.Stopwatch]::StartNew()
    $stuck=Invoke-TCStandbyQualitySample -Root $root -Overview $overview -Candidates $candidates -Clock $clock -Measure $stickyMeasure -MeasureData $sticky -BudgetMilliseconds 150 -PerTargetBudgetMilliseconds 150
    $stickyMs=$watch.ElapsedMilliseconds
    Check ($stuck.Items[0].Reason -eq 'MeasurementTimeout' -and $stickyMs -lt 1000 -and $sticky.Calls -eq 1) 'non-cooperative .NET call cannot hold caller beyond deadline'
    $timer.Now=$timer.Now.AddSeconds(60); $overview.ObservedAt=$timer.Now.ToString('o')
    $heldWorker=Invoke-TCStandbyQualitySample -Root $root -Overview $overview -Candidates $candidates -Clock $clock -Measure $stickyMeasure -MeasureData $sticky -BudgetMilliseconds 150 -PerTargetBudgetMilliseconds 150
    Check ($heldWorker.Items[0].Reason -eq 'MeasurementTimeout' -and $sticky.Calls -eq 1) 'unfinished retired worker prevents accumulating additional runspaces'
    $null=& $module { if ($script:SQRetiredWorker) { $script:SQRetiredWorker.Stop.AsyncWaitHandle.WaitOne(2000) } }
    $released=Tick; Check ($released.Items[0].Fresh -and $null -ne $released.Recommendation) 'completed retired worker is reaped before sampling resumes'
    $path=Join-Path $root 'Product\standby-quality.json'; $before=[IO.File]::ReadAllText($path)
    [IO.File]::WriteAllText($path,'{"Owner":"someone-else","secret":"fixture-secret"}')
    $foreign=[IO.File]::ReadAllText($path); $calls=$data.Calls; $bad=Tick
    Check ($bad.Reason -eq 'StoreUnavailable' -and $null -eq $bad.Recommendation -and $data.Calls -eq $calls -and [IO.File]::ReadAllText($path) -ceq $foreign) 'foreign cache is preserved without measuring'
    [IO.File]::WriteAllText($path,$before,(New-Object Text.UTF8Encoding($true)))

    $root=Join-Path $work 'loopback'; $overview=Overview; $listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0)
    $listener.Start()
    try {
        $port=([Net.IPEndPoint]$listener.LocalEndpoint).Port; $candidates=@(Candidate 2 $port)
        $overview.ObservedAt=$timer.Now.ToString('o'); $network=Invoke-TCStandbyQualitySample -Root $root -Overview $overview -Candidates $candidates -Clock $clock
        Check ($network.Sampled -and $network.Items[0].Fresh -and $network.Items[0].LatencyMs -ge 1 -and $null -ne $network.Recommendation) ('actual TCP adapter reaches loopback listener: '+$network.Reason)
        Check ($listener.Pending()) 'loopback server observes TCP handshake without application payload'
        $accepted=$listener.AcceptTcpClient(); try { Check ($accepted.Available -eq 0) 'measurement sends no credentials or protocol payload' } finally { $accepted.Close() }
        $loopInterface=@([Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() | Where-Object { $_.NetworkInterfaceType -eq [Net.NetworkInformation.NetworkInterfaceType]::Loopback })[0]
        $loopId=[guid]$loopInterface.Id; $loopIndex=$loopInterface.GetIPProperties().GetIPv4Properties().Index
        $candidates[0]|Add-Member NoteProperty Underlay ([pscustomobject]@{InterfaceIndex=$loopIndex;LocalAddress='127.0.0.1';InterfaceId=$loopId.ToString();NetworkFingerprint=('F'*64)})
        $pinned=Invoke-TCStandbyQualitySample -Root (Join-Path $work 'loopback-pinned') -Overview $overview -Candidates $candidates -Clock $clock
        Check ($pinned.Items[0].Fresh -and $listener.Pending()) 'Windows accepts explicit source bind plus IP_UNICAST_IF for loopback socket'
        $accepted=$listener.AcceptTcpClient(); try { Check ($accepted.Client.RemoteEndPoint.Address.ToString() -eq '127.0.0.1') 'pinned loopback connection has the selected source address' } finally { $accepted.Close() }
    } finally { $listener.Stop() }
    $timer.Now=$timer.Now.AddSeconds(60); $overview.ObservedAt=$timer.Now.ToString('o')
    $refused=Invoke-TCStandbyQualitySample -Root $root -Overview $overview -Candidates $candidates -Clock $clock -PerTargetBudgetMilliseconds 1500
    Check ($null -eq $refused.Recommendation -and $null -eq $refused.Items[0].LatencyMs -and $refused.Items[0].Reason -in @('TcpUnavailable','MeasurementTimeout')) 'closed loopback port replaces prior success with unavailable'
    Check (@(Get-ChildItem -LiteralPath (Join-Path $root 'Product') -Filter '.tc-*.tmp').Count -eq 0) 'atomic cache writes leave no temporary files'
    # Verify external-interface calls with a socket object double only. No
    # packet is sent to these documentation addresses or a physical interface.
    $trace=@{Calls=(New-Object 'Collections.Generic.List[string]');Begins=0;Closed=0;FailBind=$false;FailOption=$false;Source='';Option=0;OptionValue=0}
    & $module {
        param($Trace)
        $script:SQSocketTrace=$Trace
        function script:SQNewTcpClient {
            param($AddressFamily)
            $t=$script:SQSocketTrace
            $client=[pscustomobject]@{Trace=$t;LocalEndPoint=[pscustomobject]@{Address=[Net.IPAddress]::Parse('192.0.2.20')}}
            $client|Add-Member ScriptMethod Bind {param($Endpoint) $this.Trace.Calls.Add('Bind');$this.Trace.Source=$Endpoint.Address.ToString();if($this.Trace.FailBind){throw 'Fixture bind failure.'}}
            $client|Add-Member ScriptMethod SetSocketOption {param($Level,$Name,$Value) $this.Trace.Calls.Add('SetSocketOption');$this.Trace.Option=[int]$Name;$this.Trace.OptionValue=[int]$Value;if($this.Trace.FailOption){throw 'Fixture option failure.'}}
            $socket=[pscustomobject]@{Trace=$t;Client=$client;Connected=$true}
            $socket|Add-Member ScriptMethod BeginConnect {param($Address,$Port,$Callback,$State) $this.Trace.Calls.Add('BeginConnect');$this.Trace.Begins++;[pscustomobject]@{AsyncWaitHandle=(New-Object Threading.ManualResetEvent($true))}}
            $socket|Add-Member ScriptMethod EndConnect {param($Pending) $this.Trace.Calls.Add('EndConnect')}
            $socket|Add-Member ScriptMethod Close { $this.Trace.Closed++ }
            $socket
        }
    } $trace
    $fakeTarget=& $module { SQCandidate @{NodeId='22222222-2222-2222-2222-222222222222';ProfileId='Tcp';Exit='hk';Host='203.0.113.10';Port=443;ConfigHash=('B'*64);Underlay=@{InterfaceIndex=7;LocalAddress='192.0.2.20';InterfaceId='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';NetworkFingerprint=('D'*64)}} }
    $proof=& $module {param($c) SQTcpMeasure $c 1000} $fakeTarget
    Check ($proof.Status -eq 'Measured' -and ($trace.Calls -join ',') -ceq 'Bind,SetSocketOption,BeginConnect,EndConnect' -and $trace.Source -eq '192.0.2.20' -and $trace.Option -eq 31 -and $trace.OptionValue -eq [Net.IPAddress]::HostToNetworkOrder(7)) 'physical socket selects exact source and network-order IP_UNICAST_IF before connect'
    $trace.FailBind=$true; $proof=& $module {param($c) SQTcpMeasure $c 1000} $fakeTarget
    Check ($proof.Reason -eq 'UnderlayBindFailed' -and $trace.Begins -eq 1 -and $trace.Closed -eq 2) 'source bind failure closes socket without a system-route fallback'
    $trace.FailBind=$false; $trace.FailOption=$true; $proof=& $module {param($c) SQTcpMeasure $c 1000} $fakeTarget
    Check ($proof.Reason -eq 'UnderlayBindFailed' -and $trace.Begins -eq 1 -and $trace.Closed -eq 3) 'IP_UNICAST_IF failure cannot start an unpinned connection'
    [pscustomobject]@{Passed=$true;Checks=$script:Checks;PowerShellVersion=$PSVersionTable.PSVersion.ToString();MeasurementBudgetMs=250;TimeoutObservedMs=$timeoutMs;NonCooperativeDeadlineMs=$stickyMs;LoopbackMeasurements=3;ProductionNetworkProbes=0;ProductionRootAccesses=0;NetworkChanges=0;AutoSwitches=0}
} finally {
    Remove-Module $module -ErrorAction SilentlyContinue
    $resolved=[IO.Path]::GetFullPath($work).TrimEnd('\')
    if (-not $resolved.StartsWith(($fixtureBase+'\'),[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -cnotmatch '^TC-StandbyQuality-[a-f0-9]{32}$') { throw 'Unsafe fixture cleanup.' }
    if ([IO.Directory]::Exists($resolved)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
