#requires -Version 5.1
Set-StrictMode -Version 2

function Get-TCPathField {param($Object,[string]$Name,$Default=$null)
    if($Object -is [Collections.IDictionary]){if($Object.Contains($Name)){return $Object[$Name]};return $Default}
    if($null -ne $Object -and $Object.PSObject.Properties[$Name]){$Object.$Name}else{$Default}
}
function Get-TCPathDigest {param($Value)
    $sha=[Security.Cryptography.SHA256]::Create()
    try{([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($Value|ConvertTo-Json -Depth 20 -Compress))))).Replace('-','')}
    finally{$sha.Dispose()}
}
function Get-TCPathFailureReason {param([string]$Message)
    if($Message -in @('UnsupportedEndpoint','UnsupportedPeerCount','UnsupportedDetour','UnsupportedTransport','UnsupportedOuterDetourOrTransport','InnerPeerDnsNotSupported','InvalidBootstrapDns','InvalidOuterEndpoint','IPv6NotSupported','BoundInterfaceUnavailable','IPv4SourceUnavailable','SourceAddressInterfaceAmbiguous','NonPhysicalInterface','BoundInterfaceRouteMissing','AmbiguousBoundRoute','InvalidBoundGateway')){return $Message}
    'UnsupportedOrIncompleteConfiguration'
}
function Read-TCProbeNetworkState {
    # The only network-context reader; tests replace this private function in
    # module scope. No callback or caller-provided context is a public API.
    if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){throw 'WindowsRequired'}
    $adapters=@(Get-CimInstance -Namespace root/StandardCimv2 -ClassName MSFT_NetAdapter -ErrorAction Stop)
    $ipInterfaces=@(Get-NetIPInterface -ErrorAction Stop)
    $routes=@(Get-NetRoute -PolicyStore ActiveStore -ErrorAction Stop)
    $interfaces=@(foreach($nic in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()){
        $props=$nic.GetIPProperties();$index=0
        if($nic.Supports([Net.NetworkInformation.NetworkInterfaceComponent]::IPv4)){$index=$props.GetIPv4Properties().Index}
        if(-not $index){continue}
        $adapter=@($adapters|Where-Object {$_.InterfaceIndex -eq $index})
        $ipif=@($ipInterfaces|Where-Object {$_.InterfaceIndex -eq $index -and [int]$_.AddressFamily -eq 2})
        [pscustomobject]@{
            Index=$index;Id=$nic.Id;Name=$nic.Name;Status=[string]$nic.OperationalStatus;Type=[string]$nic.NetworkInterfaceType
            Hardware=($adapter.Count -eq 1 -and [bool]$adapter[0].HardwareInterface -and -not [bool]$adapter[0].Virtual)
            Metric=$(if($ipif.Count -eq 1){[int]$ipif[0].InterfaceMetric}else{-1})
            Addresses=@($props.UnicastAddresses|ForEach-Object {[pscustomobject]@{Address=$_.Address.ToString();Family=[string]$_.Address.AddressFamily;PrefixLength=$_.PrefixLength;State=[string]$_.DuplicateAddressDetectionState}})
            Gateways=@($props.GatewayAddresses|ForEach-Object {$_.Address.ToString()})
            DnsServers=@($props.DnsAddresses|ForEach-Object {$_.ToString()})
        }
    })
    [pscustomobject]@{Interfaces=$interfaces;Routes=@($routes|ForEach-Object {[pscustomobject]@{InterfaceIndex=[int]$_.InterfaceIndex;DestinationPrefix=[string]$_.DestinationPrefix;NextHop=[string]$_.NextHop;RouteMetric=[int]$_.RouteMetric;AddressFamily=[string]$_.AddressFamily}})}
}
function Get-TCProbeNetworkSnapshot {
    $at=[DateTimeOffset]::UtcNow.ToString('o')
    try{
        $raw=Read-TCProbeNetworkState
        # Explicit allow-list: no DHCP lease clocks, counters, MAC, SSID, DNS
        # suffix, credentials or caller metadata can enter the fingerprint.
        $interfaces=@(foreach($i in @($raw.Interfaces|Sort-Object Index,Id)){
            [pscustomobject][ordered]@{Index=[int]$i.Index;Id=[string]$i.Id;Name=[string]$i.Name;Status=[string]$i.Status;Type=[string]$i.Type;Hardware=[bool]$i.Hardware;Metric=[int]$i.Metric
                Addresses=@($i.Addresses|Sort-Object Address,PrefixLength|ForEach-Object {[pscustomobject][ordered]@{Address=[string]$_.Address;Family=[string]$_.Family;PrefixLength=[int]$_.PrefixLength;State=[string]$_.State}})
                Gateways=@($i.Gateways|Sort-Object -Unique);DnsServers=@($i.DnsServers|Sort-Object -Unique)}
        })
        $routes=@($raw.Routes|Sort-Object InterfaceIndex,DestinationPrefix,NextHop,RouteMetric|ForEach-Object {[pscustomobject][ordered]@{InterfaceIndex=[int]$_.InterfaceIndex;DestinationPrefix=[string]$_.DestinationPrefix;NextHop=[string]$_.NextHop;RouteMetric=[int]$_.RouteMetric;AddressFamily=[string]$_.AddressFamily}})
        if(-not $interfaces.Count){throw 'NoInterface'}
        $fingerprint=Get-TCPathDigest ([ordered]@{Scope='FullNetworkSnapshot.v1';Interfaces=$interfaces;Routes=$routes})
        [pscustomobject]@{SchemaVersion=2;Scope='FullNetworkSnapshot.v1';Fingerprint=$fingerprint;SnapshotFingerprint=$fingerprint;UnderlayFingerprint=$null;EnvironmentGuardFingerprint=$null;Status='Available';Interfaces=$interfaces;Routes=$routes;ObservedAt=$at;Reason='ReadOnlySnapshot';ScopeDetails=$null}
    }catch{[pscustomobject]@{SchemaVersion=2;Scope='FullNetworkSnapshot.v1';Fingerprint=$null;SnapshotFingerprint=$null;UnderlayFingerprint=$null;EnvironmentGuardFingerprint=$null;Status='Unavailable';Interfaces=@();Routes=@();ObservedAt=$at;Reason='NetworkContextReadFailed';ScopeDetails=$null}}
}
function Test-TCExpectedTunnelLayout {param($Interface)
    # A narrow layout exception, NOT process ownership or absence-of-WFP proof.
    # Matches NodeStore's fixed trade-tun contract, never an alias-only match.
    if($Interface.Hardware -or $Interface.Name -cne 'TradeChannel' -or $Interface.Type -notin @('Ethernet','Tunnel')){return $false}
    $v4=@($Interface.Addresses|Where-Object {$_.Family -eq 'InterNetwork'})
    if($v4.Count -ne 1 -or $v4[0].Address -cne '172.30.250.1' -or $v4[0].PrefixLength -ne 30){return $false}
    foreach($a in @($Interface.Addresses|Where-Object {$_.Family -ne 'InterNetwork'})){
        $ip=$null;if(-not [Net.IPAddress]::TryParse($a.Address,[ref]$ip)){return $false}
        if($ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetworkV6 -or (-not $ip.IsIPv6LinkLocal -and -not ($ip.ToString() -eq 'fd42:7472:6164::1' -and $a.PrefixLength -eq 126))){return $false}
    };$true
}
function Get-TCProbeEnvironmentGuard {param($Snapshot)
    # Changes in third-party/unknown virtual networks are not silently excluded.
    # Unchanged third-party networks are still NOT a physical-directness claim.
    $other=@($Snapshot.Interfaces|Where-Object {-not $_.Hardware -and $_.Type -ne 'Loopback' -and -not (Test-TCExpectedTunnelLayout $_)})
    $indices=@($other|ForEach-Object {$_.Index})
    $routes=@($Snapshot.Routes|Where-Object {$_.InterfaceIndex -in $indices})
    Get-TCPathDigest ([ordered]@{Scope='OtherVirtualEnvironment.v1';Interfaces=$other;Routes=$routes})
}
function Get-TCProbeRouteSelection {param($Snapshot,[int]$Index,[string]$Address)
    $ip=$null;if(-not [Net.IPAddress]::TryParse($Address,[ref]$ip) -or $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork){throw 'IPv4RouteRequired'}
    $bytes=$ip.GetAddressBytes();$matched=@()
    foreach($r in @($Snapshot.Routes|Where-Object {$_.InterfaceIndex -eq $Index})){
        $parts=$r.DestinationPrefix.Split('/');$prefix=$null
        if($parts.Count -ne 2 -or -not [Net.IPAddress]::TryParse($parts[0],[ref]$prefix) -or $prefix.AddressFamily -ne $ip.AddressFamily){continue}
        $bits=[int]$parts[1];if($bits -lt 0 -or $bits -gt 32){continue};$p=$prefix.GetAddressBytes();$matches=$true
        for($n=0;$n -lt 4;$n++){$take=[Math]::Max(0,[Math]::Min(8,$bits-8*$n));$mask=if($take){(255 -shl (8-$take)) -band 255}else{0};if(($bytes[$n] -band $mask) -ne ($p[$n] -band $mask)){$matches=$false;break}}
        if($matches){$matched+=,[pscustomobject]@{PrefixLength=$bits;DestinationPrefix=$r.DestinationPrefix;NextHop=$r.NextHop;RouteMetric=[int]$r.RouteMetric}}
    }
    if(-not $matched.Count){throw 'BoundInterfaceRouteMissing'}
    $ordered=@($matched|Sort-Object @{Expression='PrefixLength';Descending=$true},RouteMetric,NextHop)
    $best=@($ordered|Where-Object {$_.PrefixLength -eq $ordered[0].PrefixLength -and $_.RouteMetric -eq $ordered[0].RouteMetric})
    if(@($best|Select-Object -ExpandProperty NextHop -Unique).Count -ne 1){throw 'AmbiguousBoundRoute'}
    $hop=$null;if(-not [Net.IPAddress]::TryParse($best[0].NextHop,[ref]$hop) -or $hop.AddressFamily -ne $ip.AddressFamily){throw 'InvalidBoundGateway'}
    [pscustomobject]@{Destination=$ip.ToString();NextHop=$hop.ToString();MatchedPrefix=$best[0].DestinationPrefix;RouteMetric=$best[0].RouteMetric}
}
function Get-TCProbeUnderlayData {param($Snapshot,$Binding)
    if([int](Get-TCPathField $Binding 'SchemaVersion' 0) -ne 2 -or (Get-TCPathField $Binding 'Scope' '') -notin @('BoundPhysicalIPv4.v1','BoundLoopbackIPv4.v1')){throw 'LegacyOrUnsupportedBindingScope'}
    if($Binding.AddressFamily -cne 'IPv4'){throw 'IPv6NotSupported'}
    $interfaces=@($Snapshot.Interfaces|Where-Object {$_.Index -eq $Binding.InterfaceIndex -and $_.Id -ceq $Binding.InterfaceId -and $_.Name -ceq $Binding.InterfaceName -and $_.Status -eq 'Up'})
    if($interfaces.Count -ne 1){throw 'BoundInterfaceUnavailable'};$i=$interfaces[0]
    $local=$null;if(-not [Net.IPAddress]::TryParse($Binding.LocalAddress,[ref]$local) -or $local.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork){throw 'IPv4SourceUnavailable'}
    $owners=@($Snapshot.Interfaces|Where-Object {@($_.Addresses|Where-Object {$_.Address -ceq $Binding.LocalAddress -and $_.Family -eq 'InterNetwork' -and $_.State -eq 'Preferred'}).Count})
    if($owners.Count -ne 1 -or $owners[0].Index -ne $i.Index){throw 'SourceAddressInterfaceAmbiguous'}
    if($Binding.Scope -eq 'BoundPhysicalIPv4.v1' -and (-not $i.Hardware -or [Net.IPAddress]::IsLoopback($local))){throw 'NonPhysicalInterface'}
    if($Binding.Scope -eq 'BoundLoopbackIPv4.v1' -and ($i.Type -ne 'Loopback' -or -not [Net.IPAddress]::IsLoopback($local))){throw 'InvalidLoopbackScope'}
    $address=@($i.Addresses|Where-Object {$_.Address -ceq $Binding.LocalAddress -and $_.Family -eq 'InterNetwork'})
    if($address.Count -ne 1){throw 'IPv4SourceUnavailable'}
    $gateways=@(foreach($g in $i.Gateways){$ip=$null;if([Net.IPAddress]::TryParse($g,[ref]$ip) -and $ip.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork){$ip.ToString()}})
    $remote=$null;$literal=[Net.IPAddress]::TryParse($Binding.RemoteAddress,[ref]$remote);$routes=@()
    if($literal){
        if($remote.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork){throw 'IPv6NotSupported'}
        if($Binding.Scope -eq 'BoundLoopbackIPv4.v1' -and -not [Net.IPAddress]::IsLoopback($remote)){throw 'InvalidLoopbackScope'}
        $selected=Get-TCProbeRouteSelection $Snapshot $i.Index $remote.ToString();$routes+=,$selected
        $outerPath=[ordered]@{Address=$remote.ToString();NextHop=$selected.NextHop}
        # Literal outer and literal inner peer need no bootstrap lookup. Neither
        # unused OS DNS servers nor unused configured DNS enter this fingerprint.
        $bootstrap=[ordered]@{Usage='NotUsedForLiteralOuter'}
    }else{
        $dns=$Binding.BootstrapDns;$dnsIp=$null
        if($dns.Type -cne 'udp' -or [int]$dns.ServerPort -ne 53 -or -not [Net.IPAddress]::TryParse($dns.Server,[ref]$dnsIp) -or $dnsIp.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork){throw 'InvalidBootstrapDns'}
        $selected=Get-TCProbeRouteSelection $Snapshot $i.Index $dnsIp.ToString();$routes+=,$selected
        $outerPath=[ordered]@{Hostname=[string]$Binding.RemoteAddress;Route='Unresolved'}
        $bootstrap=[ordered]@{Usage='RequiredForOuterHostname';Type='udp';Server=$dnsIp.ToString();Port=53;NextHop=$selected.NextHop}
    }
    # Route prefix/metric remain diagnostic. Adding an equivalent host bypass
    # route with the same effective gateway does not change the underlay path.
    $data=[ordered]@{Scope=[string]$Binding.Scope;Interface=[ordered]@{Index=[int]$i.Index;Id=[string]$i.Id;Name=[string]$i.Name;Hardware=[bool]$i.Hardware;Type=[string]$i.Type;Status=[string]$i.Status};Source=[ordered]@{Address=$local.ToString();PrefixLength=[int]$address[0].PrefixLength;State=[string]$address[0].State};Gateways=@($gateways|Sort-Object -Unique);OuterPath=$outerPath;BootstrapDns=$bootstrap}
    [pscustomobject]@{Fingerprint=(Get-TCPathDigest $data);Data=[pscustomobject]$data;Routes=$routes}
}
function ConvertTo-TCProbeBoundContext {param($Snapshot,$Binding)
    $result=[pscustomobject]@{SchemaVersion=2;Scope=[string](Get-TCPathField $Binding 'Scope' 'UnsupportedBinding');Fingerprint=$null;UnderlayFingerprint=$null;SnapshotFingerprint=$Snapshot.SnapshotFingerprint;EnvironmentGuardFingerprint=$null;Status='Unavailable';Interfaces=$Snapshot.Interfaces;Routes=$Snapshot.Routes;ObservedAt=$Snapshot.ObservedAt;Reason='NetworkContextReadFailed';ScopeDetails=$null}
    if($Snapshot.Status -ne 'Available'){return $result}
    try{
        $data=Get-TCProbeUnderlayData $Snapshot $Binding
        $result.UnderlayFingerprint=$data.Fingerprint;$result.ScopeDetails=$data.Data
        $guard=Get-TCProbeEnvironmentGuard $Snapshot;$result.EnvironmentGuardFingerprint=$guard
        if([string](Get-TCPathField $Binding 'EnvironmentGuardFingerprint' '') -cne $guard){throw 'UnsupportedEnvironmentChanged'}
        $result.Fingerprint=$data.Fingerprint;$result.Status='Available';$result.Reason='ReadOnlyBoundUnderlay'
    }catch{
        $reason=$_.Exception.Message
        $result.Status='Unsupported';$result.Reason=if($reason -in @('LegacyOrUnsupportedBindingScope','BoundInterfaceUnavailable','IPv4SourceUnavailable','SourceAddressInterfaceAmbiguous','NonPhysicalInterface','InvalidLoopbackScope','IPv4RouteRequired','BoundInterfaceRouteMissing','AmbiguousBoundRoute','InvalidBoundGateway','IPv6NotSupported','InvalidBootstrapDns','UnsupportedEnvironmentChanged')){$reason}else{'UnsupportedUnderlayContext'}
    };$result
}
function Get-TCProbeNetworkContext {
    [CmdletBinding()]param($Binding)
    $snapshot=Get-TCProbeNetworkSnapshot
    if($null -eq $Binding){return $snapshot}
    ConvertTo-TCProbeBoundContext $snapshot $Binding
}
function Get-TCProbeOuter {param($Candidate)
    $endpoints=@((Get-TCPathField $Candidate 'endpoints' @())|Where-Object {(Get-TCPathField $_ 'tag' '') -ceq 'hk' -and (Get-TCPathField $_ 'type' '') -ceq 'wireguard'})
    if($endpoints.Count -ne 1){throw 'UnsupportedEndpoint'}
    $endpoint=$endpoints[0];$peers=@(Get-TCPathField $endpoint 'peers' @())
    if($peers.Count -ne 1){throw 'UnsupportedPeerCount'}
    $detour=[string](Get-TCPathField $endpoint 'detour' '')
    if($detour){
        if($detour -cne 'tc-transport'){throw 'UnsupportedDetour'}
        $outbounds=@((Get-TCPathField $Candidate 'outbounds' @())|Where-Object {(Get-TCPathField $_ 'tag' '') -ceq 'tc-transport'})
        if($outbounds.Count -ne 1 -or (Get-TCPathField $outbounds[0] 'type' '') -cne 'vless'){throw 'UnsupportedTransport'}
        $outer=$outbounds[0]
        if((Get-TCPathField $outer 'detour' '') -or (Get-TCPathField $outer 'transport')){throw 'UnsupportedOuterDetourOrTransport'}
        $innerIp=$null
        if(-not [Net.IPAddress]::TryParse([string](Get-TCPathField $peers[0] 'address' ''),[ref]$innerIp)){throw 'InnerPeerDnsNotSupported'}
        [pscustomobject]@{Layer='outbounds';Tag='tc-transport';Protocol='Tcp';Address=[string](Get-TCPathField $outer 'server' '');Port=[int](Get-TCPathField $outer 'server_port' 0);Object=$outer;Endpoint=$endpoint}
    }else{[pscustomobject]@{Layer='endpoints';Tag='hk';Protocol='Udp';Address=[string](Get-TCPathField $peers[0] 'address' '');Port=[int](Get-TCPathField $peers[0] 'port' 0);Object=$endpoint;Endpoint=$endpoint}}
}
function Test-TCProbeRoute {param($Context,[int]$Index,[string]$Address)
    $ip=$null;if(-not [Net.IPAddress]::TryParse($Address,[ref]$ip) -or $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork){return $false}
    $bytes=$ip.GetAddressBytes()
    foreach($r in @($Context.Routes|Where-Object {$_.InterfaceIndex -eq $Index})){
        $parts=$r.DestinationPrefix.Split('/');$prefix=$null
        if($parts.Count -ne 2 -or -not [Net.IPAddress]::TryParse($parts[0],[ref]$prefix) -or $prefix.AddressFamily -ne $ip.AddressFamily){continue}
        $bits=[int]$parts[1];if($bits -lt 0 -or $bits -gt 32){continue};$p=$prefix.GetAddressBytes();$matches=$true
        for($n=0;$n -lt 4;$n++){$take=[Math]::Max(0,[Math]::Min(8,$bits-8*$n));$mask=if($take){(255 -shl (8-$take)) -band 255}else{0};if(($bytes[$n] -band $mask) -ne ($p[$n] -band $mask)){$matches=$false;break}}
        if($matches){return $true}
    };$false
}
function New-TCProbeBinding {param($Outer,$Interface,$Context,[string]$LocalAddress,[string]$Dns)
    $binding=[pscustomobject][ordered]@{SchemaVersion=2;Scope=$(if($Interface.Type -eq 'Loopback'){'BoundLoopbackIPv4.v1'}else{'BoundPhysicalIPv4.v1'});NetworkFingerprint=$null;UnderlayFingerprint=$null;EnvironmentGuardFingerprint=(Get-TCProbeEnvironmentGuard $Context);InterfaceIndex=$Interface.Index;InterfaceName=$Interface.Name;InterfaceId=$Interface.Id;LocalAddress=$LocalAddress;AddressFamily='IPv4';OuterLayer=$Outer.Layer;OuterTag=$Outer.Tag;Protocol=$Outer.Protocol;RemoteAddress=$Outer.Address;RemotePort=$Outer.Port
        DialFields=[pscustomobject]@{bind_interface=$Interface.Name;inet4_bind_address=$LocalAddress}
        BootstrapDns=[pscustomobject]@{Tag='dns-direct';Type='udp';Server=$Dns;ServerPort=53;DialFields=[pscustomobject]@{bind_interface=$Interface.Name;inet4_bind_address=$LocalAddress}}}
    $data=Get-TCProbeUnderlayData $Context $binding
    $binding.NetworkFingerprint=$data.Fingerprint;$binding.UnderlayFingerprint=$data.Fingerprint;$binding
}
function Get-TCProbeBindingPlan {
    [CmdletBinding()]param([Parameter(Mandatory=$true)]$Candidate,[string]$DirectDnsIPv4='1.1.1.1',[ValidateRange(0,2147483647)][int]$InterfaceIndex=0)
    $context=Get-TCProbeNetworkContext;$binding=$null;$reason='NetworkContextUnavailable';$status='Unavailable';$interfaces=@()
    if($context.Status -eq 'Available'){
        try{
            $outer=Get-TCProbeOuter $Candidate;$dns=$null
            if(-not [Net.IPAddress]::TryParse($DirectDnsIPv4,[ref]$dns) -or $dns.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork){throw 'InvalidBootstrapDns'}
            if(-not $outer.Address -or $outer.Port -lt 1 -or $outer.Port -gt 65535){throw 'InvalidOuterEndpoint'}
            $remote=$null;$literal=[Net.IPAddress]::TryParse($outer.Address,[ref]$remote)
            if($literal -and $remote.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork){throw 'IPv6NotSupported'}
            $eligible=@($context.Interfaces|Where-Object {$_.Status -eq 'Up' -and $_.Hardware -and ($InterfaceIndex -eq 0 -or $_.Index -eq $InterfaceIndex) -and @( $_.Addresses|Where-Object {$_.Family -eq 'InterNetwork' -and $_.State -eq 'Preferred'}).Count -eq 1})
            $eligible=@($eligible|Where-Object {if($literal){Test-TCProbeRoute $context $_.Index $outer.Address}else{Test-TCProbeRoute $context $_.Index $DirectDnsIPv4}})
            $interfaces=@($eligible|ForEach-Object {[pscustomobject]@{Index=$_.Index;Name=$_.Name;Type=$_.Type;LocalAddress=@($_.Addresses|Where-Object {$_.Family -eq 'InterNetwork' -and $_.State -eq 'Preferred'})[0].Address}})
            if($eligible.Count -ne 1){$reason=if($eligible.Count){'AmbiguousPhysicalInterface'}else{'NoSupportedPhysicalInterface'};$status='Unsupported'}
            else{$i=$eligible[0];$local=@($i.Addresses|Where-Object {$_.Family -eq 'InterNetwork' -and $_.State -eq 'Preferred'})[0].Address;$binding=New-TCProbeBinding $outer $i $context $local $dns.ToString();$status='Ready';$reason='BindingPlanOnly'}
        }catch{$reason=Get-TCPathFailureReason $_.Exception.Message;$status='Unsupported'}
    }
    [pscustomobject]@{Status=$status;Reason=$reason;Binding=$binding;Interfaces=$interfaces;SelectedInterfaceIndex=$InterfaceIndex;ObservedAt=$context.ObservedAt;Scope=$(if($binding){$binding.Scope}else{$null});NetworkFingerprint=$(if($binding){$binding.NetworkFingerprint}else{$null});UnderlayFingerprint=$(if($binding){$binding.UnderlayFingerprint}else{$null});SnapshotFingerprint=$context.SnapshotFingerprint;RecommendationCapability=$(if(-not $binding){'Unavailable'}elseif(-not $literal){'BindingOnlyBootstrapDnsRemoteUnobservable'}elseif($binding.Protocol -eq 'Udp'){'WindowsOwnedUdpIpv4Etw'}else{'WindowsOwnedTcpIpv4Literal'})}
}
function Initialize-TCProbePathNative {
    if(-not ('TCProbePathV1.Native' -as [type])){Add-Type -Path (Join-Path $PSScriptRoot 'ProbePath.Native.cs') -ErrorAction Stop}
}
function Initialize-TCProbeEtwNative {
    if(-not ('TCProbePathV1.UdpEtwWatch' -as [type])){Add-Type -Path (Join-Path $PSScriptRoot 'ProbePath.Etw.cs') -ErrorAction Stop}
}
function Stop-TCProbeOwnedTrace {param([string]$Identity)
    Initialize-TCProbeEtwNative
    $guid=[guid]::Parse($Identity);if($guid -eq [guid]::Empty){throw 'Missing owned trace identity'}
    if([TCProbePathV1.UdpEtwWatch]::StopOwn($guid.ToString('D')) -ne 0 -or [TCProbePathV1.UdpEtwWatch]::QueryOwn($guid.ToString('D')) -ne 4201){throw 'Owned trace needs recovery'}
}
function Start-TCProbeTraceGuard {param([string]$Identity,[string]$RunDirectory)
    $node=Import-Module (Join-Path $PSScriptRoot 'NodeStore.psm1') -PassThru -DisableNameChecking
    & $node {param($p)Assert-TCNoReparse $p} $RunDirectory
    if(-not [IO.Directory]::Exists($RunDirectory)){throw 'Trace guard requires owned run directory'}
    $guid=[guid]::Parse($Identity);$base=Join-Path $RunDirectory ('udp-etw-'+$guid.ToString('N'))
    $ready=$base+'.ready';$stop=$base+'.stop';$source=Join-Path $PSScriptRoot 'ProbePath.Etw.cs'
    $owner=[Diagnostics.Process]::GetCurrentProcess();try{$birth=$owner.StartTime.ToUniversalTime().Ticks}finally{$owner.Dispose()}
    $program='$ErrorActionPreference="Stop";if($PSVersionTable.PSEdition -ne "Core"){$env:PSModulePath=Join-Path $PSHOME "Modules"};Add-Type -Path '''+$source.Replace("'","''")+''';exit [TCProbePathV1.UdpEtwWatch]::GuardOwnSession('+[string]$PID+','+[string]$birth+','''+$guid.ToString('D')+''','''+$ready.Replace("'","''")+''','''+$stop.Replace("'","''")+''',75)'
    $binary=if($PSVersionTable.PSEdition -eq 'Core'){Join-Path $PSHOME 'pwsh.exe'}else{Join-Path $PSHOME 'powershell.exe'}
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($program))
    $process=Start-Process -FilePath $binary -ArgumentList @('-NoProfile','-NonInteractive','-EncodedCommand',$encoded) -WindowStyle Hidden -PassThru
    [pscustomobject]@{Process=$process;ReadyPath=$ready;StopPath=$stop;Identity=$guid.ToString('D')}
}
function Start-TCProbeSocketObservation {param([int]$ProcessId,$Binding,[string]$TraceIdentity,[string]$RunDirectory)
    Initialize-TCProbePathNative
    $tcp=New-Object TCProbePathV1.SocketWatch($ProcessId)
    if(-not $TraceIdentity){return $tcp}
    $handle=[pscustomobject]@{Kind='OwnedUdpObservation';Tcp=$tcp;Udp=$null;Guard=$null;Identity=$TraceIdentity;CanOwnTrace=$false;Started=$false;StartReason='UdpEtwUnavailable';Result=$null}
    try{
        Initialize-TCProbeEtwNative
        if($Binding.Protocol -ne 'Udp' -or [TCProbePathV1.UdpEtwWatch]::QueryOwn($TraceIdentity) -ne 4201){throw 'Invalid or occupied trace identity'}
        $handle.CanOwnTrace=$true
        $handle.Guard=Start-TCProbeTraceGuard $TraceIdentity $RunDirectory
        $deadline=[DateTime]::UtcNow.AddSeconds(5)
        while(-not [IO.File]::Exists($handle.Guard.ReadyPath) -and -not $handle.Guard.Process.HasExited -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 50}
        if($handle.Guard.Process.HasExited -or -not [IO.File]::Exists($handle.Guard.ReadyPath) -or [IO.File]::ReadAllText($handle.Guard.ReadyPath) -cne ([guid]$TraceIdentity).ToString('D')){throw 'Trace guard not ready'}
        $handle.Udp=New-Object TCProbePathV1.UdpEtwWatch($ProcessId,$tcp.ProcessStartTicks,[string]$Binding.RemoteAddress,[int]$Binding.RemotePort,$TraceIdentity)
        $handle.Udp.Start();$handle.Started=$true;$handle.StartReason='UdpEtwStarted'
    }catch{$handle.StartReason='UdpEtwUnavailable'}
    # Return even a partial handle so caller finally owns every started resource.
    $handle
}
function Stop-TCProbeSocketObservation {param($Observer)
    if((Get-TCPathField $Observer 'Kind' '') -eq 'OwnedUdpObservation'){
        if($Observer.Result){return $Observer.Result}
        $failed=$false;$guardComplete=$false
        try{if($Observer.Udp){$Observer.Udp.Dispose()}}catch{$failed=$true}
        if($Observer.CanOwnTrace){try{Stop-TCProbeOwnedTrace $Observer.Identity}catch{$failed=$true}}
        try{
            if($Observer.Guard){
                [IO.File]::WriteAllText($Observer.Guard.StopPath,$Observer.Identity)
                $guard=$Observer.Guard.Process
                if(-not $guard.WaitForExit(3000)){throw 'Trace guard stop timeout'}
                $guardComplete=($guard.ExitCode -eq 0);if(-not $guardComplete){$failed=$true}
            }
        }catch{$failed=$true}
        try{$Observer.Tcp.Dispose()}catch{$failed=$true}
        if($failed){throw 'Owned UDP observation cleanup failed'}
        $udp=$Observer.Udp;$tcp=$Observer.Tcp
        $trace=[pscustomobject]@{SessionGuid=$Observer.Identity;SessionName=('TCProbe-UDP-'+([guid]$Observer.Identity).ToString('N'));Started=$Observer.Started;CleanupComplete=$true;SessionAbsent=$Observer.CanOwnTrace;GuardCompleted=$guardComplete;GuardMode='OwnerExitOr75SecondLease';EventsLost=$(if($udp){$udp.EventsLost}else{0});BuffersLost=$(if($udp){$udp.BuffersLost}else{0});MatchedEvents=$(if($udp){$udp.MatchedEvents}else{0});StartReason=$Observer.StartReason;StartCode=$(if($udp){$udp.StartCode}else{$null});EnableCode=$(if($udp){$udp.EnableCode}else{$null});ProcessTraceCode=$(if($udp){$udp.ProcessTraceCode}else{$null});StopCode=$(if($udp){$udp.StopCode}else{$null})}
        $Observer.Result=[pscustomobject]@{Status=$(if($Observer.Started -and $guardComplete){'Available'}else{'Unavailable'});Protocol='Udp';ProcessId=$tcp.ProcessId;ProcessStartTicks=$tcp.ProcessStartTicks;Reads=$tcp.Reads;Errors=($tcp.Errors+$(if($udp){$udp.Errors}else{0}));Overflow=($tcp.Overflow -or ($udp -and $udp.Overflow));NetworkChanges=$tcp.NetworkChanges;Rows=$(if($udp){@($udp.Snapshot())}else{@()});Source='WindowsKernelNetworkUdpEtw';TraceEvidence=$trace}
        if($Observer.Guard){$Observer.Guard.Process.Dispose()}
        return $Observer.Result
    }
    $Observer.Dispose()
    [pscustomobject]@{Status='Available';ProcessId=$Observer.ProcessId;ProcessStartTicks=$Observer.ProcessStartTicks;Reads=$Observer.Reads;Errors=$Observer.Errors;Overflow=$Observer.Overflow;NetworkChanges=$Observer.NetworkChanges;Rows=@($Observer.Snapshot());Source='WindowsOwnedTcpTable'}
}
function Test-TCProbeDialBinding {param($Object,$Binding)
    if([string](Get-TCPathField $Object 'detour' '') -or [string](Get-TCPathField $Object 'bind_interface' '') -cne $Binding.InterfaceName -or [string](Get-TCPathField $Object 'inet4_bind_address' '') -cne $Binding.LocalAddress){return $false}
    foreach($f in @('inet6_bind_address','network_strategy','network_type','fallback_network_type','tcp_multi_path','routing_mark','netns')){if(Get-TCPathField $Object $f){return $false}}
    $true
}
function Get-TCProbePathAssessment {
    # Private evaluator; CandidateProbe invokes it inside this module. It is
    # never exported as an API accepting caller-fabricated network evidence.
    param($Candidate,$Manifest,$Profile,$Contexts,$Observation,[bool]$ProcessOwned)
    $contextsArray=@($Contexts);$first=if($contextsArray.Count){$contextsArray[0]}else{$null};$binding=$null
    $result=[pscustomobject]@{Kind='Unknown';Verified=$false;EligibleForRecommendation=$false;NetworkFingerprint=$null;UnderlayFingerprint=$null;SnapshotFingerprint=(Get-TCPathField $first 'SnapshotFingerprint');Binding=$null;Reason='NetworkContextUnavailable';Scope=(Get-TCPathField $first 'Scope' 'Unknown');EvidenceScope='Observed owned IPv4 TCP sockets or UDP send metadata on a saved interface binding; not proof against WFP redirection or of end-to-end physical directness';SocketEvidence=@();TraceEvidence=$null;BootstrapDnsEvidence='Unverified';ContextObservationCount=$contextsArray.Count}
    if($contextsArray.Count -lt 2){return $result}
    $bad=@($contextsArray|Where-Object {$_.Status -ne 'Available' -or -not $_.Fingerprint -or -not (Get-TCPathField $_ 'SnapshotFingerprint')})
    if($bad.Count){$result.Reason=Get-TCPathField $bad[0] 'Reason' 'NetworkContextUnavailable';return $result}
    # Full snapshot changes DURING a probe remain conservative. Between probe
    # and activation the public Binding context compares the narrower underlay.
    if(@($contextsArray|Where-Object {$_.SnapshotFingerprint -cne $first.SnapshotFingerprint -or $_.Fingerprint -cne $first.Fingerprint -or $_.Scope -cne $first.Scope}).Count){$result.Reason='NetworkContextChanged';return $result}
    if(-not $Profile){$result.Reason='StoredProfileRequired';return $result}
    $saved=Get-TCPathField $Manifest 'ProbeBinding'
    if(-not $saved){$result.Reason='StoredBindingMissing';return $result}
    try{
        $result.Reason='StoredBindingInvalid'
        $bound=ConvertTo-TCProbeBoundContext $first $saved
        if($bound.Status -ne 'Available'){$result.Reason=$bound.Reason;return $result}
        $result.NetworkFingerprint=$bound.Fingerprint;$result.UnderlayFingerprint=$bound.UnderlayFingerprint;$result.Scope=$bound.Scope
        $outer=Get-TCProbeOuter $Candidate;$dnsRows=@((Get-TCPathField (Get-TCPathField $Candidate 'dns') 'servers' @())|Where-Object {(Get-TCPathField $_ 'tag' '') -ceq 'dns-direct'})
        if($dnsRows.Count -ne 1){$result.Reason='StoredBootstrapDnsMissingOrAmbiguous';return $result};$dns=$dnsRows[0]
        $i=@($first.Interfaces|Where-Object {$_.Index -eq $saved.InterfaceIndex -and $_.Id -ceq $saved.InterfaceId -and $_.Name -ceq $saved.InterfaceName -and $_.Status -eq 'Up'})
        if($i.Count -ne 1){$result.Reason='BoundInterfaceUnavailable';return $result}
        $binding=New-TCProbeBinding $outer $i[0] $first ([string]$saved.LocalAddress) ([string]$dns.server);$result.Binding=$binding
        # Whitelist and compare every binding field. Unknown manifest fields
        # cannot leak into evidence, and config itself remains the authority.
        foreach($f in @('SchemaVersion','Scope','NetworkFingerprint','UnderlayFingerprint','EnvironmentGuardFingerprint','InterfaceIndex','InterfaceName','InterfaceId','LocalAddress','AddressFamily','OuterLayer','OuterTag','Protocol','RemoteAddress','RemotePort')){
            if([string](Get-TCPathField $saved $f '') -cne [string]$binding.$f){$result.Reason='StoredBindingContextMismatch';return $result}
        }
        foreach($f in @('bind_interface','inet4_bind_address')){
            if([string](Get-TCPathField (Get-TCPathField $saved 'DialFields') $f '') -cne [string]$binding.DialFields.$f -or [string](Get-TCPathField (Get-TCPathField (Get-TCPathField $saved 'BootstrapDns') 'DialFields') $f '') -cne [string]$binding.DialFields.$f){$result.Reason='StoredBindingContextMismatch';return $result}
        }
        foreach($f in @('Tag','Type','Server','ServerPort')){
            if([string](Get-TCPathField (Get-TCPathField $saved 'BootstrapDns') $f '') -cne [string]$binding.BootstrapDns.$f){$result.Reason='StoredBindingContextMismatch';return $result}
        }
        if(-not (Test-TCProbeDialBinding $outer.Object $binding)){$result.Reason='OuterBindingMissingOrIgnored';return $result}
        $dnsIp=$null
        if($dns.type -cne 'udp' -or -not [Net.IPAddress]::TryParse([string]$dns.server,[ref]$dnsIp) -or $dnsIp.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or [int](Get-TCPathField $dns 'server_port' 53) -ne 53 -or -not (Test-TCProbeDialBinding $dns $binding)){$result.Reason='BootstrapDnsBindingMissingOrIgnored';return $result}
        $resolver=Get-TCPathField $outer.Object 'domain_resolver'
        if((Get-TCPathField $resolver 'server' '') -cne 'dns-direct' -or (Get-TCPathField $resolver 'strategy' '') -cne 'ipv4_only'){$result.Reason='OuterResolverNotBound';return $result}
        $owners=@($first.Interfaces|Where-Object {@($_.Addresses|Where-Object {$_.Address -ceq $binding.LocalAddress -and $_.Family -eq 'InterNetwork' -and $_.State -eq 'Preferred'}).Count})
        if($owners.Count -ne 1 -or $owners[0].Index -ne $i[0].Index){$result.Reason='SourceAddressInterfaceAmbiguous';return $result}
        $ip=$null;if(-not [Net.IPAddress]::TryParse($outer.Address,[ref]$ip)){$result.Reason='BootstrapDnsRemoteUnobservable';return $result}
        if($ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork){$result.Reason='IPv6NotSupported';return $result}
        $result.BootstrapDnsEvidence='BoundButUnusedLiteralOuter'
        if(-not (Test-TCProbeRoute $first $i[0].Index $outer.Address)){$result.Reason='BoundInterfaceRouteMissing';return $result}
        if($outer.Protocol -eq 'Udp'){
            $trace=Get-TCPathField $Observation 'TraceEvidence'
            $result.TraceEvidence=$trace
            if((Get-TCPathField $Observation 'Protocol' '') -ne 'Udp' -or -not $trace -or -not $trace.Started){$result.Reason='UdpEtwObservationUnavailable';return $result}
            if(-not $trace.CleanupComplete -or -not $trace.SessionAbsent -or -not $trace.GuardCompleted){$result.Reason='UdpEtwCleanupUnverified';return $result}
            if($trace.EventsLost -ne 0 -or $trace.BuffersLost -ne 0){$result.Reason='UdpEtwEventsLost';return $result}
            if($trace.MatchedEvents -lt 1){$result.Reason='OuterSocketNotObserved';return $result}
        }
        if(-not $ProcessOwned -or -not $Observation -or $Observation.Status -ne 'Available' -or $Observation.Errors -ne 0 -or $Observation.Reads -lt 1 -or $Observation.Overflow){$result.Reason='OwnedSocketObservationUnavailable';return $result}
        if($Observation.NetworkChanges -ne 0){$result.Reason='NetworkChangedDuringObservation';return $result}
        $matching=@();$conflicting=@()
        foreach($row in @($Observation.Rows)){
            $remote=$null;if(-not [Net.IPAddress]::TryParse($row.RemoteAddress,[ref]$remote)){continue}
            if([Net.IPAddress]::IsLoopback($remote) -and -not [Net.IPAddress]::IsLoopback($ip)){continue}
            $sourceMatches=if($outer.Protocol -eq 'Udp'){$row.State -eq 0 -and $row.Source -eq 'WindowsKernelNetworkUdpSendV0'}else{$row.State -eq 5 -and $row.Source -eq 'GetExtendedTcpTable'}
            if($row.ProcessId -eq $Observation.ProcessId -and $sourceMatches -and $row.AddressFamily -eq 'IPv4' -and $row.LocalAddress -ceq $binding.LocalAddress -and $row.RemoteAddress -ceq $ip.ToString() -and $row.RemotePort -eq $outer.Port){$matching+=,$row}else{$conflicting+=,$row}
        }
        if($conflicting.Count){$result.Reason='UnexpectedOwnedSocket';return $result}
        if(-not $matching.Count){$result.Reason='OuterSocketNotObserved';return $result}
        $result.SocketEvidence=@($matching|Select-Object ProcessId,LocalAddress,LocalPort,RemoteAddress,RemotePort,AddressFamily,Source)
        if(-not $i[0].Hardware -and -not [Net.IPAddress]::IsLoopback($ip)){$result.Reason='NonPhysicalInterface';return $result}
        $result.Kind='BoundInterfaceObserved';$result.Verified=$true;$result.Reason=if($outer.Protocol -eq 'Udp'){'OwnedUdpEtwAndSavedBindingVerified'}else{'OwnedTcpSocketAndSavedBindingVerified'}
        if([Net.IPAddress]::IsLoopback($ip)){$result.Kind='LoopbackOwnedSocket';$result.Reason='LoopbackOnlyNotRecommendationEligible'}
        # Eligibility is finalized by CandidateProbe after forwarding and cleanup.
    }catch{$result.Reason=Get-TCPathFailureReason $_.Exception.Message}
    $result
}
Export-ModuleMember -Function Get-TCProbeNetworkContext,Get-TCProbeBindingPlan
