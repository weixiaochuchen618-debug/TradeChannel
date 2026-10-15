#requires -Version 5.1
[CmdletBinding()]param()
$ErrorActionPreference='Stop';Set-StrictMode -Version 2
$module=Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'ProbePath.psm1') -Force -PassThru
$script:Checks=0
function Check {param([bool]$Ok,[string]$Label)if(-not $Ok){throw ('ProbePath regression: '+$Label)};$script:Checks++}
function Copy-Fixture {param($Value)$Value|ConvertTo-Json -Depth 30|ConvertFrom-Json}

# An actual TCP owner-table observation, on loopback only, of a child we own.
$listener=$null;$client=$null;$child=$null;$watch=$null
try{
    $live=Get-TCProbeNetworkContext
    Check ($live.Status -eq 'Available' -and $live.Fingerprint -match '^[A-F0-9]{64}$') 'native read-only Windows network context'
    & $module {Initialize-TCProbePathNative}
    $listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0);$listener.Start();$port=$listener.LocalEndpoint.Port
    $childScript='$ErrorActionPreference="Stop";$c=New-Object Net.Sockets.TcpClient;$c.Connect("127.0.0.1",'+$port+');$s=$c.GetStream();$s.ReadTimeout=10000;try{$null=$s.ReadByte()}finally{$c.Dispose()}'
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childScript))
    $binary=if($PSVersionTable.PSEdition -eq 'Core'){Join-Path $PSHOME 'pwsh.exe'}else{Join-Path $PSHOME 'powershell.exe'}
    $child=Start-Process -FilePath $binary -ArgumentList @('-NoProfile','-NonInteractive','-EncodedCommand',$encoded) -WindowStyle Hidden -PassThru
    $accept=$listener.AcceptTcpClientAsync();if(-not $accept.Wait(6000)){throw 'Loopback child not ready'};$client=$accept.Result
    $watch=& $module {param($id)Start-TCProbeSocketObservation $id} $child.Id
    Start-Sleep -Milliseconds 200
    $observation=& $module {param($w)Stop-TCProbeSocketObservation $w} $watch;$watch=$null
    $socket=@($observation.Rows|Where-Object {$_.RemoteAddress -eq '127.0.0.1' -and $_.RemotePort -eq $port -and $_.ProcessId -eq $child.Id})
    Check ($observation.Errors -eq 0 -and $observation.Reads -gt 0 -and $socket.Count -eq 1 -and $socket[0].LocalAddress -eq '127.0.0.1') 'real owned TCP local/remote tuple without public traffic'
    Check ($observation.ProcessStartTicks -eq $child.StartTime.ToUniversalTime().Ticks) 'socket evidence carries owned process creation identity'
    $loop=@($live.Interfaces|Where-Object {@($_.Addresses|Where-Object {$_.Address -eq '127.0.0.1'}).Count})[0]
    $loopConfig=[pscustomobject]@{endpoints=@([pscustomobject]@{type='wireguard';tag='hk';system=$false;detour='tc-transport';peers=@([pscustomobject]@{address='127.0.0.1';port=51820})});outbounds=@([pscustomobject]@{type='vless';tag='tc-transport';server='127.0.0.1';server_port=$port;bind_interface=$loop.Name;inet4_bind_address='127.0.0.1';domain_resolver=[pscustomobject]@{server='dns-direct';strategy='ipv4_only'}});dns=[pscustomobject]@{servers=@([pscustomobject]@{type='udp';tag='dns-direct';server='127.0.0.1';bind_interface=$loop.Name;inet4_bind_address='127.0.0.1'})}}
    $loopBinding=& $module {param($c,$i,$ctx)$o=Get-TCProbeOuter $c;New-TCProbeBinding $o $i $ctx '127.0.0.1' '127.0.0.1'} $loopConfig $loop $live
    $loopEvidence=& $module {param($c,$b,$ctx,$o)Get-TCProbePathAssessment $c ([pscustomobject]@{ProbeBinding=$b}) ([pscustomobject]@{Id='Tcp'}) @($ctx,$ctx) $o $true} $loopConfig $loopBinding $live $observation
    Check ($loopEvidence.Verified -and $loopEvidence.Kind -eq 'LoopbackOwnedSocket' -and -not $loopEvidence.EligibleForRecommendation) 'actual loopback path can verify locally without recommendation'
}finally{
    if($watch){$watch.Dispose()};if($client){$client.Dispose()};if($listener){$listener.Stop()}
    if($child){if(-not $child.HasExited -and -not $child.WaitForExit(2000)){$child.Kill();$null=$child.WaitForExit(3000)};$child.Dispose()}
}

# Real UDP observations. Every sender, listener and trace belongs to this test.
$udpRoot=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('TC-ProbePath-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($udpRoot)
$udpListener=$null;$commandListener=$null;$command=$null;$udpChild=$null;$udpWatch=$null;$otherWatch=$null;$protectedWatch=$null;$deathWorker=$null;$deathGuard=$null
try{
    & $module {Initialize-TCProbeEtwNative}
    $udpListener=New-Object Net.Sockets.UdpClient([Net.IPEndPoint]::new([Net.IPAddress]::Loopback,0));$udpListener.Client.ReceiveTimeout=5000;$udpPort=$udpListener.Client.LocalEndPoint.Port
    $commandListener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0);$commandListener.Start();$commandPort=$commandListener.LocalEndpoint.Port
    $udpCode='$ErrorActionPreference="Stop";$c=New-Object Net.Sockets.TcpClient;$c.Connect("127.0.0.1",'+$commandPort+');$s=$c.GetStream();$s.ReadTimeout=30000;$u=New-Object Net.Sockets.UdpClient([Net.IPEndPoint]::new([Net.IPAddress]::Loopback,0));try{while(($cmd=$s.ReadByte()) -gt 0){for($i=0;$i -lt 8;$i++){$null=$u.Send([byte[]]@(1),1,"127.0.0.1",'+$udpPort+');Start-Sleep -Milliseconds 30}}}finally{$u.Dispose();$c.Dispose()}'
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($udpCode))
    $udpChild=Start-Process -FilePath $binary -ArgumentList @('-NoProfile','-NonInteractive','-EncodedCommand',$encoded) -WindowStyle Hidden -PassThru
    $accept=$commandListener.AcceptTcpClientAsync();if(-not $accept.Wait(6000)){throw 'UDP control child unavailable'};$command=$accept.Result
    $udpContext=Get-TCProbeNetworkContext;$loop=@($udpContext.Interfaces|Where-Object {@($_.Addresses|Where-Object {$_.Address -eq '127.0.0.1'}).Count})[0]
    $udpConfig=[pscustomobject]@{endpoints=@([pscustomobject]@{type='wireguard';tag='hk';system=$false;peers=@([pscustomobject]@{address='127.0.0.1';port=$udpPort});bind_interface=$loop.Name;inet4_bind_address='127.0.0.1';domain_resolver=[pscustomobject]@{server='dns-direct';strategy='ipv4_only'}});outbounds=@();dns=[pscustomobject]@{servers=@([pscustomobject]@{type='udp';tag='dns-direct';server='127.0.0.1';bind_interface=$loop.Name;inet4_bind_address='127.0.0.1'})}}
    $udpBinding=& $module {param($c,$i,$ctx)New-TCProbeBinding (Get-TCProbeOuter $c) $i $ctx '127.0.0.1' '127.0.0.1'} $udpConfig $loop $udpContext
    $positiveUdp=$null
    foreach($case in @('Match','WrongPid','WrongDestination','Unavailable','Cancel','EarlyStop')){
        $identity=[guid]::NewGuid().ToString('D');$filter=Copy-Fixture $udpBinding
        $observedPid=if($case -eq 'WrongPid'){$PID}else{$udpChild.Id}
        if($case -eq 'WrongDestination'){$filter.RemotePort=if($udpPort -eq 65535){65534}else{$udpPort+1}}
        if($case -eq 'Unavailable'){& $module {$script:EtwInitializer=${function:Initialize-TCProbeEtwNative};function script:Initialize-TCProbeEtwNative {throw 'Isolated ETW unavailable'}}}
        try{$udpWatch=& $module {param($id,$b,$trace,$dir)Start-TCProbeSocketObservation $id $b $trace $dir} $observedPid $filter $identity $udpRoot}
        finally{if($case -eq 'Unavailable'){& $module {Set-Item Function:script:Initialize-TCProbeEtwNative $script:EtwInitializer}}}
        $cancelled=$false
        try{
            $command.GetStream().WriteByte(1)
            for($packet=0;$packet -lt 8;$packet++){$remoteEndpoint=[Net.IPEndPoint]::new([Net.IPAddress]::Any,0);$data=$udpListener.Receive([ref]$remoteEndpoint);[Array]::Clear($data,0,$data.Length)}
            if($case -eq 'EarlyStop'){$null=[TCProbePathV1.UdpEtwWatch]::StopOwn($identity);Start-Sleep -Milliseconds 100}
            if($case -eq 'Cancel'){throw 'fixture-cancel'}
        }catch{if($_.Exception.Message -eq 'fixture-cancel'){$cancelled=$true}else{throw}}
        finally{$udpObservation=& $module {param($w)Stop-TCProbeSocketObservation $w} $udpWatch;$udpWatch=$null}
        Check ([TCProbePathV1.UdpEtwWatch]::QueryOwn($identity) -eq 4201) ('owned '+$case+' ETW session absent after cleanup')
        if($case -eq 'Match'){
            Check ($udpObservation.Status -eq 'Available' -and @($udpObservation.Rows).Count -eq 1 -and $udpObservation.Rows[0].LocalPort -eq $remoteEndpoint.Port -and $udpObservation.TraceEvidence.MatchedEvents -ge 8 -and $udpObservation.TraceEvidence.EventsLost -eq 0 -and $udpObservation.TraceEvidence.GuardCompleted) 'real UDP ETW owner/source/remote agrees with received loopback datagrams'
            $positiveUdp=$udpObservation
            $udpProof=& $module {param($c,$b,$ctx,$o)Get-TCProbePathAssessment $c ([pscustomobject]@{ProbeBinding=$b}) ([pscustomobject]@{Id='Udp'}) @($ctx,$ctx) $o $true} $udpConfig $udpBinding $udpContext $udpObservation
            Check ($udpProof.Verified -and $udpProof.Kind -eq 'LoopbackOwnedSocket' -and -not $udpProof.EligibleForRecommendation) 'real loopback UDP path proves bounded metadata without physical recommendation'
        }elseif($case -in @('WrongPid','WrongDestination')){
            Check (@($udpObservation.Rows).Count -eq 0 -and $udpObservation.TraceEvidence.MatchedEvents -eq 0) ($case+' never retains other PID/target metadata')
        }elseif($case -eq 'Unavailable'){
            Check ($udpObservation.Status -eq 'Unavailable' -and @($udpObservation.Rows).Count -eq 0) 'unavailable ETW remains unknown, not UDP network failure'
        }elseif($case -eq 'EarlyStop'){Check ($udpObservation.Errors -gt 0) 'premature trace termination cannot appear as complete observation'}
        else{Check ($cancelled -and $udpObservation.TraceEvidence.CleanupComplete) 'exception unwinds actual owned ETW and guard'}
    }
    $otherId=[guid]::NewGuid().ToString('D')
    $otherWatch=New-Object TCProbePathV1.UdpEtwWatch($udpChild.Id,$udpChild.StartTime.ToUniversalTime().Ticks,'127.0.0.1',$udpPort,$otherId);$otherWatch.Start()
    $collision=& $module {param($id,$b,$trace,$dir)Start-TCProbeSocketObservation $id $b $trace $dir} $udpChild.Id $udpBinding $otherId $udpRoot
    $collisionResult=& $module {param($w)Stop-TCProbeSocketObservation $w} $collision
    Check ($collisionResult.Status -eq 'Unavailable' -and [TCProbePathV1.UdpEtwWatch]::QueryOwn($otherId) -eq 0) 'failed duplicate startup never stops an already existing trace'
    $protectedId=[guid]::NewGuid().ToString('D')
    $protectedWatch=New-Object TCProbePathV1.UdpEtwWatch($udpChild.Id,$udpChild.StartTime.ToUniversalTime().Ticks,'127.0.0.1',$udpPort,$protectedId);$protectedWatch.Start()
    $receiptRun=[guid]::NewGuid().ToString('D');$receiptDir=Join-Path (Join-Path $udpRoot 'probes') $receiptRun;$null=[IO.Directory]::CreateDirectory($receiptDir)
    $receiptPath=Join-Path $receiptDir 'ownership.json'
    [IO.File]::WriteAllText($receiptPath,([pscustomobject]@{State='NeedsRecovery';RunId=$receiptRun;TraceGuid=$otherId;TraceName=('TCProbe-UDP-'+([guid]$otherId).ToString('N'));TraceState='Starting'}|ConvertTo-Json))
    $candidateModule=Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'CandidateProbe.psm1') -PassThru -DisableNameChecking
    $nodeModule=Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'NodeStore.psm1') -PassThru -DisableNameChecking
    $blocked=$false;try{& $candidateModule {param($r,$n)Assert-TCCandidatePreviousCleanup $r $n} $udpRoot $nodeModule}catch{$blocked=$true}
    $receipt=[IO.File]::ReadAllText($receiptPath)|ConvertFrom-Json
    Check ($blocked -and $receipt.TraceState -eq 'Stopped' -and $receipt.State -eq 'NeedsRecovery' -and [TCProbePathV1.UdpEtwWatch]::QueryOwn($otherId) -eq 4201) 'real residual trace is stopped by exact private receipt while probe identity remains blocked'
    Check ([TCProbePathV1.UdpEtwWatch]::QueryOwn($protectedId) -eq 0) 'residual recovery leaves a different simultaneous trace untouched'
    $protectedWatch.Dispose();$protectedWatch=$null
    $otherWatch.Dispose();$otherWatch=$null
    $badTrace=Copy-Fixture $positiveUdp;$badTrace.TraceEvidence.CleanupComplete=$false
    $unverified=& $module {param($c,$b,$ctx,$o)Get-TCProbePathAssessment $c ([pscustomobject]@{ProbeBinding=$b}) ([pscustomobject]@{Id='Udp'}) @($ctx,$ctx) $o $true} $udpConfig $udpBinding $udpContext $badTrace
    Check (-not $unverified.Verified -and $unverified.Reason -eq 'UdpEtwCleanupUnverified') 'residual trace cleanup cannot authorize UDP recommendation'
    $badTrace=Copy-Fixture $positiveUdp;$badTrace.TraceEvidence.EventsLost=1
    $unverified=& $module {param($c,$b,$ctx,$o)Get-TCProbePathAssessment $c ([pscustomobject]@{ProbeBinding=$b}) ([pscustomobject]@{Id='Udp'}) @($ctx,$ctx) $o $true} $udpConfig $udpBinding $udpContext $badTrace
    Check (-not $unverified.Verified -and $unverified.Reason -eq 'UdpEtwEventsLost') 'ETW event loss explicitly disqualifies path proof'
    $deathId=[guid]::NewGuid().ToString('D');$deathFile=Join-Path $udpRoot 'worker-trace.json'
    $source=Join-Path (Split-Path $PSScriptRoot -Parent) 'ProbePath.psm1'
    $deathCode=@'
$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition -ne 'Core'){$env:PSModulePath=Join-Path $PSHOME 'Modules'}
$m=Import-Module '__MODULE__' -PassThru
$binding=[pscustomobject]@{Protocol='Udp';RemoteAddress='127.0.0.1';RemotePort=__PORT__}
$w=& $m {param($id,$b,$trace,$dir)Start-TCProbeSocketObservation $id $b $trace $dir} $PID $binding '__TRACE__' '__ROOT__'
if(-not $w.Started){throw 'Trace fixture unavailable'}
[IO.File]::WriteAllText('__FILE__',([pscustomobject]@{Trace='__TRACE__';GuardPid=$w.Guard.Process.Id;GuardBirth=$w.Guard.Process.StartTime.ToUniversalTime().Ticks}|ConvertTo-Json))
$u=New-Object Net.Sockets.UdpClient([Net.IPEndPoint]::new([Net.IPAddress]::Loopback,0));$null=$u.Send([byte[]]@(1),1,'127.0.0.1',__PORT__);$u.Dispose()
Start-Sleep -Seconds 30
'@
    $deathCode=$deathCode.Replace('__MODULE__',$source.Replace("'","''")).Replace('__PORT__',[string]$udpPort).Replace('__TRACE__',$deathId).Replace('__ROOT__',$udpRoot.Replace("'","''")).Replace('__FILE__',$deathFile.Replace("'","''"))
    $deathWorker=Start-Process -FilePath $binary -ArgumentList @('-NoProfile','-NonInteractive','-EncodedCommand',([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($deathCode)))) -WindowStyle Hidden -PassThru
    $deadline=[DateTime]::UtcNow.AddSeconds(10);while(-not [IO.File]::Exists($deathFile) -and -not $deathWorker.HasExited -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 100}
    if(-not [IO.File]::Exists($deathFile)){throw 'Death fixture unavailable'}
    $deathRecord=[IO.File]::ReadAllText($deathFile)|ConvertFrom-Json
    $deathGuard=[Diagnostics.Process]::GetProcessById($deathRecord.GuardPid)
    if($deathGuard.StartTime.ToUniversalTime().Ticks -ne $deathRecord.GuardBirth){$deathGuard.Dispose();$deathGuard=$null;throw 'Guard birth mismatch'}
    $guardHandle=$deathGuard.Handle
    $deathWorker.Kill();$null=$deathWorker.WaitForExit(3000)
    $deadline=[DateTime]::UtcNow.AddSeconds(5);while([TCProbePathV1.UdpEtwWatch]::QueryOwn($deathId) -ne 4201 -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 100}
    $deathQuery=[TCProbePathV1.UdpEtwWatch]::QueryOwn($deathId);$guardExited=$deathGuard.WaitForExit(2000);$guardExit=if($guardExited){$deathGuard.ExitCode}else{-1}
    Check ($deathQuery -eq 4201 -and $guardExited -and $guardExit -eq 0) ('independent guard stops its exact memory trace after worker death; query='+$deathQuery+', exited='+$guardExited+', exit='+$guardExit)
}finally{
    if($udpWatch){$null=& $module {param($w)Stop-TCProbeSocketObservation $w} $udpWatch}
    if($otherWatch){$otherWatch.Dispose()}
    if($protectedWatch){$protectedWatch.Dispose()}
    if($deathWorker){if(-not $deathWorker.HasExited){$deathWorker.Kill();$null=$deathWorker.WaitForExit(3000)};$deathWorker.Dispose()}
    if(Get-Variable deathId -ErrorAction SilentlyContinue){$null=[TCProbePathV1.UdpEtwWatch]::StopOwn($deathId)}
    if($deathGuard){if(-not $deathGuard.HasExited -and -not $deathGuard.WaitForExit(2000)){$deathGuard.Kill();$null=$deathGuard.WaitForExit(2000)};$deathGuard.Dispose()}
    if($command){try{$command.GetStream().WriteByte(0)}catch{};$command.Dispose()};if($commandListener){$commandListener.Stop()};if($udpListener){$udpListener.Dispose()}
    if($udpChild){if(-not $udpChild.HasExited -and -not $udpChild.WaitForExit(2000)){$udpChild.Kill();$null=$udpChild.WaitForExit(3000)};$udpChild.Dispose()}
    $full=[IO.Path]::GetFullPath($udpRoot);$parent=[IO.Path]::GetFullPath([Environment]::GetFolderPath('LocalApplicationData')).TrimEnd('\')+'\'
    if(-not $full.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notmatch '^TC-ProbePath-[0-9a-f]{32}$'){throw 'Cleanup rejected'}
    Remove-Item -LiteralPath $full -Recurse -Force
}

& $module {
    $script:Fixture=[pscustomobject]@{Interfaces=@([pscustomobject]@{Index=7;Id='fixture-interface-7';Name='Ethernet Fixture';Status='Up';Type='Ethernet';Hardware=$true;Metric=10;Addresses=@([pscustomobject]@{Address='192.0.2.2';Family='InterNetwork';PrefixLength=24;State='Preferred'});Gateways=@('192.0.2.1');DnsServers=@('192.0.2.53')});Routes=@([pscustomobject]@{InterfaceIndex=7;DestinationPrefix='0.0.0.0/0';NextHop='192.0.2.1';RouteMetric=10;AddressFamily='IPv4'})}
    function script:Read-TCProbeNetworkState {if($script:ReadFails){throw 'secret must not escape'};$script:Fixture}
    $script:ReadFails=$false
}
$context=Get-TCProbeNetworkContext
& $module {$script:Fixture|Add-Member NoteProperty Secret 'do-not-fingerprint';$script:Fixture.Interfaces[0]|Add-Member NoteProperty BytesReceived 1234;$script:Fixture.Interfaces[0]|Add-Member NoteProperty ObservedAt 'yesterday'}
$again=Get-TCProbeNetworkContext
Check ($context.Fingerprint -ceq $again.Fingerprint -and ($again|ConvertTo-Json -Depth 20) -notmatch 'do-not-fingerprint|BytesReceived|yesterday') 'fingerprint and summary exclude secrets counters and timestamps'
& $module {$script:Fixture.Routes[0].RouteMetric=11};$changed=Get-TCProbeNetworkContext
Check ($context.Fingerprint -cne $changed.Fingerprint) 'route changes invalidate network fingerprint'
& $module {$script:Fixture.Routes[0].RouteMetric=10}
$candidate=[pscustomobject]@{endpoints=@([pscustomobject]@{type='wireguard';tag='hk';system=$false;peers=@([pscustomobject]@{address='198.51.100.10';port=51820})});outbounds=@();dns=[pscustomobject]@{servers=@([pscustomobject]@{type='udp';tag='dns-direct';server='192.0.2.53'})}}
$udp=Get-TCProbeBindingPlan -Candidate $candidate -DirectDnsIPv4 '192.0.2.53'
Check ($udp.Status -eq 'Ready' -and $udp.Binding.OuterLayer -eq 'endpoints' -and $udp.Binding.Protocol -eq 'Udp' -and $udp.Binding.DialFields.inet4_bind_address -eq '192.0.2.2') 'UDP plan binds real endpoint and source'
$candidate.endpoints[0]|Add-Member NoteProperty detour 'tc-transport'
$candidate.outbounds=@([pscustomobject]@{type='vless';tag='tc-transport';server='198.51.100.10';server_port=443})
$tcp=Get-TCProbeBindingPlan -Candidate $candidate -DirectDnsIPv4 '192.0.2.53'
Check ($tcp.Status -eq 'Ready' -and $tcp.Binding.OuterLayer -eq 'outbounds' -and $tcp.Binding.OuterTag -eq 'tc-transport' -and $tcp.Binding.BootstrapDns.DialFields.bind_interface -eq 'Ethernet Fixture') 'TCP plan binds transport and bootstrap DNS'
Check ($udp.Binding.Protocol -ne $tcp.Binding.Protocol -and $udp.Binding.RemotePort -ne $tcp.Binding.RemotePort -and $udp.Binding.NetworkFingerprint -ceq $tcp.Binding.NetworkFingerprint -and (Get-TCProbeNetworkContext -Binding $udp.Binding).Fingerprint -ceq (Get-TCProbeNetworkContext -Binding $tcp.Binding).Fingerprint) 'UDP/TCP protocol and port differences do not split the same physical underlay fingerprint'
Check (-not $candidate.outbounds[0].PSObject.Properties['bind_interface']) 'binding plan does not modify candidate'
$candidate.outbounds[0]|Add-Member NoteProperty detour 'other'
Check ((Get-TCProbeBindingPlan -Candidate $candidate).Status -eq 'Unsupported') 'outer detour cannot hide ignored binding'
$candidate.outbounds[0].PSObject.Properties.Remove('detour')
& $module {$second=$script:Fixture.Interfaces[0]|ConvertTo-Json -Depth 10|ConvertFrom-Json;$second.Index=8;$second.Id='fixture-interface-8';$second.Name='Second';$second.Addresses[0].Address='192.0.2.3';$script:Fixture.Interfaces+=,$second;$route=$script:Fixture.Routes[0]|ConvertTo-Json|ConvertFrom-Json;$route.InterfaceIndex=8;$script:Fixture.Routes+=,$route}
Check ((Get-TCProbeBindingPlan -Candidate $candidate).Reason -eq 'AmbiguousPhysicalInterface') 'dual physical interfaces need explicit selection'
Check ((Get-TCProbeBindingPlan -Candidate $candidate -InterfaceIndex 7).Status -eq 'Ready') 'explicit interface selection is available without mutating network'
& $module {$script:Fixture.Interfaces=@($script:Fixture.Interfaces[0]);$script:Fixture.Routes=@($script:Fixture.Routes[0])}

$binding=$tcp.Binding
foreach($obj in @($candidate.outbounds[0],$candidate.dns.servers[0])){foreach($prop in $binding.DialFields.PSObject.Properties){$obj|Add-Member NoteProperty $prop.Name $prop.Value -Force}}
$candidate.outbounds[0]|Add-Member NoteProperty domain_resolver ([pscustomobject]@{server='dns-direct';strategy='ipv4_only'})
$manifest=[pscustomobject]@{ProbeBinding=$binding};$profile=[pscustomobject]@{Id='Tcp'}
$socket=[pscustomobject]@{ProcessId=42;LocalAddress='192.0.2.2';LocalPort=50000;RemoteAddress='198.51.100.10';RemotePort=443;AddressFamily='IPv4';State=5;Source='GetExtendedTcpTable'}
$obs=[pscustomobject]@{Status='Available';ProcessId=42;ProcessStartTicks=123;Reads=2;Errors=0;Overflow=$false;NetworkChanges=0;Rows=@($socket)}
function Assess {param($Cfg=$candidate,$Man=$manifest,$Ctx=@($context,$context),$Obs=$obs,[bool]$Owned=$true,$Profile=$profile)
    & $module {param($c,$m,$p,$ctx,$o,$own)Get-TCProbePathAssessment $c $m $p $ctx $o $own} $Cfg $Man $Profile $Ctx $Obs $Owned
}
$good=Assess
Check ($good.Verified -and $good.Kind -eq 'BoundInterfaceObserved' -and -not $good.EligibleForRecommendation) 'private TCP path proof positive; forwarding finalizes eligibility separately'
$c=Copy-Fixture $candidate;$c.outbounds[0].PSObject.Properties.Remove('bind_interface');$c.endpoints[0]|Add-Member NoteProperty bind_interface 'Ethernet Fixture'
Check ((Assess -Cfg $c).Reason -eq 'OuterBindingMissingOrIgnored') 'inner WG binding alone cannot prove TCP outer path'
$c=Copy-Fixture $candidate;$c.dns.servers[0]|Add-Member NoteProperty detour 'tc-transport'
Check ((Assess -Cfg $c).Reason -eq 'BootstrapDnsBindingMissingOrIgnored') 'DNS detour ignores binding and disqualifies proof'
Check ((Assess -Ctx @($context,$changed)).Reason -eq 'NetworkContextChanged') 'mid-probe network context drift invalidates proof'
$o=Copy-Fixture $obs;$o.NetworkChanges=1
Check ((Assess -Obs $o).Reason -eq 'NetworkChangedDuringObservation') 'OS change event catches change followed by matching snapshot'
$o=Copy-Fixture $obs;$o.Rows[0].LocalAddress='192.0.2.3'
Check ((Assess -Obs $o).Reason -eq 'UnexpectedOwnedSocket') 'wrong socket source is not binding proof'
$o=Copy-Fixture $obs;$o.Rows[0].RemoteAddress='198.51.100.11'
Check ((Assess -Obs $o).Reason -eq 'UnexpectedOwnedSocket') 'wrong socket destination is not binding proof'
$o=Copy-Fixture $obs;$o.Rows[0].ProcessId=43
Check (-not (Assess -Obs $o).Verified) 'other PID cannot supply path evidence'
Check (-not (Assess -Owned $false).Verified) 'lost process ownership disqualifies proof'
$o=Copy-Fixture $obs;$o.Rows=@()
Check ((Assess -Obs $o).Reason -eq 'OuterSocketNotObserved') 'config and fingerprint alone never verify a path'
Check ((Assess -Profile $null).Reason -eq 'StoredProfileRequired') 'stored profile is mandatory'
$c=Copy-Fixture $candidate;$c.outbounds[0].server='example.invalid';$m=Copy-Fixture $manifest;$m.ProbeBinding=(Get-TCProbeBindingPlan -Candidate $c -DirectDnsIPv4 '192.0.2.53').Binding
Check ((Assess -Cfg $c -Man $m).Reason -eq 'BootstrapDnsRemoteUnobservable') 'hostname path does not pretend DNS route is observed'
$c=Copy-Fixture $candidate;$c.endpoints[0].PSObject.Properties.Remove('detour');$c.outbounds=@();foreach($p in $binding.DialFields.PSObject.Properties){$c.endpoints[0]|Add-Member NoteProperty $p.Name $p.Value};$c.endpoints[0]|Add-Member NoteProperty domain_resolver ([pscustomobject]@{server='dns-direct';strategy='ipv4_only'});$m=Copy-Fixture $manifest;$m.ProbeBinding=$udp.Binding
Check ((Assess -Cfg $c -Man $m).Reason -eq 'UdpEtwObservationUnavailable') 'UDP cannot qualify from a TCP table or configuration-only observation'

# Qualification uses a binding-specific physical IPv4 scope. The complete
# snapshot is retained for in-probe detection, not post-activation invalidation.
$baseline=Get-TCProbeNetworkContext -Binding $binding
Check ($binding.SchemaVersion -eq 2 -and $binding.Scope -eq 'BoundPhysicalIPv4.v1' -and $baseline.Fingerprint -ceq $binding.NetworkFingerprint -and $baseline.Fingerprint -ceq $baseline.UnderlayFingerprint -and $baseline.Fingerprint -cne $baseline.SnapshotFingerprint) 'binding context explicitly separates underlay and full snapshot'
$baseRaw=& $module {$script:Fixture|ConvertTo-Json -Depth 20}
function Reset-NetworkFixture {& $module {param($raw)$script:Fixture=$raw|ConvertFrom-Json} $baseRaw}
function Add-TunnelFixture {param([string]$Name='TradeChannel',[string]$Address='172.30.250.1')
    & $module {param($name,$address)
        $script:Fixture.Interfaces+=,[pscustomobject]@{Index=30;Id='virtual-30';Name=$name;Status='Up';Type='Ethernet';Hardware=$false;Metric=0;Addresses=@([pscustomobject]@{Address=$address;Family='InterNetwork';PrefixLength=30;State='Preferred'});Gateways=@('0.0.0.0');DnsServers=@('172.30.250.2')}
        foreach($prefix in @('0.0.0.0/1','128.0.0.0/1')){$script:Fixture.Routes+=,[pscustomobject]@{InterfaceIndex=30;DestinationPrefix=$prefix;NextHop='0.0.0.0';RouteMetric=0;AddressFamily='IPv4'}}
    } $Name $Address
}
Add-TunnelFixture
$withTC=Get-TCProbeNetworkContext -Binding $binding
Check ($withTC.Status -eq 'Available' -and $withTC.Fingerprint -ceq $baseline.Fingerprint -and $withTC.SnapshotFingerprint -cne $baseline.SnapshotFingerprint) 'adding only expected TC TUN does not invalidate bound underlay'
$planWithTC=Get-TCProbeBindingPlan -Candidate $candidate -DirectDnsIPv4 '192.0.2.53'
Check ($planWithTC.Binding.NetworkFingerprint -ceq $binding.NetworkFingerprint -and $planWithTC.Binding.EnvironmentGuardFingerprint -ceq $binding.EnvironmentGuardFingerprint) 'binding plans generated with old TC TUN survive its later removal'
Check ((Assess -Ctx @($withTC,$withTC)).Verified) 'unchanged complete probe under TC layout retains limited bound-interface proof'
Check ((Assess -Ctx @($baseline,$withTC)).Reason -eq 'NetworkContextChanged') 'TUN change during sampling remains a snapshot race without being an underlay change'
Reset-NetworkFixture
Check ((Get-TCProbeNetworkContext -Binding $planWithTC.Binding).Fingerprint -ceq $baseline.Fingerprint) 'removing expected TC TUN does not invalidate existing binding'
& $module {$script:Fixture.Routes+=,[pscustomobject]@{InterfaceIndex=7;DestinationPrefix='198.51.100.10/32';NextHop='192.0.2.1';RouteMetric=1;AddressFamily='IPv4'}}
Check ((Get-TCProbeNetworkContext -Binding $binding).Fingerprint -ceq $baseline.Fingerprint) 'equivalent physical host bypass route preserves same effective gateway scope'
& $module {$script:Fixture.Routes[1].NextHop='192.0.2.254'}
Check ((Get-TCProbeNetworkContext -Binding $binding).Fingerprint -cne $baseline.Fingerprint) 'more-specific route to different gateway invalidates underlay'
Reset-NetworkFixture
& $module {$script:Fixture.Interfaces[0].Addresses[0].Address='192.0.2.3'}
Check (-not (Get-TCProbeNetworkContext -Binding $binding).Fingerprint) 'bound IPv4 address replacement invalidates current qualification'
Reset-NetworkFixture
& $module {$script:Fixture.Interfaces[0].Gateways=@('192.0.2.254');$script:Fixture.Routes[0].NextHop='192.0.2.254'}
Check ((Get-TCProbeNetworkContext -Binding $binding).Fingerprint -cne $baseline.Fingerprint) 'physical gateway change invalidates qualification'
Reset-NetworkFixture
& $module {$script:Fixture.Interfaces[0].Id='replacement-interface'}
Check (-not (Get-TCProbeNetworkContext -Binding $binding).Fingerprint) 'same interface index with different physical GUID invalidates qualification'
Reset-NetworkFixture
& $module {$script:Fixture.Interfaces[0].Status='Down'}
Check (-not (Get-TCProbeNetworkContext -Binding $binding).Fingerprint) 'bound interface down has no usable qualification fingerprint'
Reset-NetworkFixture
& $module {$script:Fixture.Interfaces[0].DnsServers=@('203.0.113.53');$script:Fixture.Routes+=,[pscustomobject]@{InterfaceIndex=7;DestinationPrefix='192.0.2.53/32';NextHop='192.0.2.254';RouteMetric=1;AddressFamily='IPv4'}}
Check ((Get-TCProbeNetworkContext -Binding $binding).Fingerprint -ceq $baseline.Fingerprint) 'unused OS DNS and unused literal-outer bootstrap route do not pollute scope'
$hostBinding=(Get-TCProbeBindingPlan -Candidate ([pscustomobject]@{endpoints=$candidate.endpoints;outbounds=@([pscustomobject]@{tag='tc-transport';type='vless';server='example.invalid';server_port=443})}) -DirectDnsIPv4 '192.0.2.53').Binding
$hostContext=Get-TCProbeNetworkContext -Binding $hostBinding
& $module {$script:Fixture.Routes[1].NextHop='192.0.2.253'}
Check ((Get-TCProbeNetworkContext -Binding $hostBinding).Fingerprint -cne $hostContext.Fingerprint -and $hostContext.ScopeDetails.BootstrapDns.Usage -eq 'RequiredForOuterHostname') 'used bootstrap DNS effective gateway participates in hostname underlay scope'
Reset-NetworkFixture
Add-TunnelFixture -Name 'ThirdPartyVPN'
$foreign=Get-TCProbeNetworkContext -Binding $binding
Check ($foreign.Status -eq 'Unsupported' -and -not $foreign.Fingerprint -and $foreign.UnderlayFingerprint -ceq $baseline.UnderlayFingerprint -and $foreign.Reason -eq 'UnsupportedEnvironmentChanged') 'third-party virtual environment change degrades instead of silently reusing evidence'
Reset-NetworkFixture
Add-TunnelFixture -Address '10.77.0.1'
Check ((Get-TCProbeNetworkContext -Binding $binding).Reason -eq 'UnsupportedEnvironmentChanged') 'TradeChannel name alone never exempts an unknown interface layout'
Reset-NetworkFixture
& $module {$script:Fixture.Routes+=,[pscustomobject]@{InterfaceIndex=7;DestinationPrefix='0.0.0.0/0';NextHop='192.0.2.254';RouteMetric=10;AddressFamily='IPv4'}}
Check ((Get-TCProbeNetworkContext -Binding $binding).Reason -eq 'AmbiguousBoundRoute') 'ambiguous equal-cost physical gateways degrade honestly'
Reset-NetworkFixture
$old=Copy-Fixture $binding;$old.SchemaVersion=1
Check ((Get-TCProbeNetworkContext -Binding $old).Reason -eq 'LegacyOrUnsupportedBindingScope' -and -not (Get-TCProbeNetworkContext -Binding $old).Fingerprint) 'old full-snapshot binding is not silently upgraded to underlay evidence'
Check ((Get-TCProbeNetworkContext).Scope -eq 'FullNetworkSnapshot.v1') 'unbound context stays explicitly full snapshot for legacy diagnostics'
& $module {$script:ReadFails=$true};$unavailable=Get-TCProbeNetworkContext
Check ($unavailable.Status -eq 'Unavailable' -and -not $unavailable.Fingerprint -and ($unavailable|ConvertTo-Json) -notmatch 'secret must') 'failed context read has no usable fingerprint or exception secrets'
Check (-not (Get-Command Get-TCProbeNetworkContext).Parameters.ContainsKey('NetworkContextReader') -and @(Get-Command -Module ProbePath).Count -eq 2) 'only read-only context and binding plan are public APIs'
[pscustomobject]@{Passed=$true;Checks=$script:Checks;RealNetworkChanges=0;PublicCandidateProbes=0;OwnedLoopbackTcpObserved=$true;OwnedLoopbackUdpEtwObserved=$true;EtwWrongPidAndTargetRejected=$true;EtwCancelAndWorkerDeathCleaned=$true;EtwResidualAndLossRejected=$true;PhysicalPublicPathAccepted=$false;PowerShell=$PSVersionTable.PSVersion.ToString()}
