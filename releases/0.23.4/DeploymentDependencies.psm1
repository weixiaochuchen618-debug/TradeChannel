#requires -Version 5.1
Set-StrictMode -Version 2.0
function Test-TCDeploymentDependencies {
    [CmdletBinding()]param([string]$PackageRoot=$PSScriptRoot)
    $path=Join-Path $PackageRoot 'deployment\dependencies.lock.json'
    if(-not [IO.File]::Exists($path) -or (Get-Item -LiteralPath $path).Length -gt 128KB){throw '[TC:DependencyLockMissing] 缺少部署依赖锁，请重新解压完整包。'}
    $lock=[IO.File]::ReadAllText($path)|ConvertFrom-Json
    $required=@('Renci.SshNet.dll','jose-jwt.dll','BouncyCastle.Cryptography.dll','Microsoft.Bcl.AsyncInterfaces.dll','Microsoft.Extensions.Logging.Abstractions.dll','Microsoft.Extensions.DependencyInjection.Abstractions.dll','System.Formats.Asn1.dll','System.Buffers.dll','System.Memory.dll','System.Numerics.Vectors.dll','System.Runtime.CompilerServices.Unsafe.dll','System.Threading.Tasks.Extensions.dll','System.ValueTuple.dll')
    if($lock.SchemaVersion -ne 1 -or @($lock.Dependencies).Count -ne $required.Count){throw '[TC:DependencyLockInvalid] 部署依赖锁不完整。'}
    $found=@()
    foreach($dependency in $lock.Dependencies){
        if($dependency.File -cnotmatch '^assets/lib/([A-Za-z0-9.-]+\.dll)$' -or $dependency.SHA256 -cnotmatch '^[A-F0-9]{64}$'){throw '[TC:DependencyLockInvalid] 部署依赖路径或摘要无效。'}
        $name=[IO.Path]::GetFileName($dependency.File);if($name -notin $required -or $name -in $found){throw '[TC:DependencyLockInvalid] 部署依赖列表有未知或重复条目。'};$found+=$name
        $file=Join-Path $PackageRoot $dependency.File
        if(-not [IO.File]::Exists($file) -or (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -cne $dependency.SHA256){throw '[TC:DependencyIntegrityFailed] 部署组件摘要不匹配，已拒绝加载。请重新解压完整包。'}
    }
    [pscustomobject]@{Ok=$true;Count=$found.Count;Framework='net48';Locked=$true}
}
function Invoke-TCDeploymentUdpIngressSend {
    [CmdletBinding()]param([Parameter(Mandatory=$true)]$Binding,[ValidateRange(250,6000)][int]$DurationMilliseconds=5000)
    Import-Module (Join-Path $PSScriptRoot 'ProbePath.psm1') -DisableNameChecking
    $result=[pscustomobject]@{Status='NotSent';Code='IngressBindingUnavailable';SentCount=0;PayloadLength=96;LocalAddress='';LocalPort=0;RemoteAddress='';RemotePort=0;InterfaceIndex=0;StartedAtUtc=$null;CompletedAtUtc=$null;NetworkStable=$false;NetworkFingerprint=$null;NetworkChanged=$false}
    $socket=$null;$payload=$null
    try{
        $local=[Net.IPAddress]::Parse([string]$Binding.LocalAddress);$remote=[Net.IPAddress]::Parse([string]$Binding.RemoteAddress)
        if($Binding.Protocol -cne 'Udp' -or $local.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or $remote.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or [int]$Binding.RemotePort -lt 1 -or [int]$Binding.RemotePort -gt 65535 -or [int]$Binding.InterfaceIndex -lt 1){return $result}
        if([Net.IPAddress]::IsLoopback($remote) -ne [Net.IPAddress]::IsLoopback($local)){return $result}
        $before=Get-TCProbeNetworkContext -Binding $Binding
        if($before.Status -cne 'Available' -or [string]$before.Fingerprint -cne [string]$Binding.NetworkFingerprint){return $result}
        $socket=New-Object Net.Sockets.Socket([Net.Sockets.AddressFamily]::InterNetwork,[Net.Sockets.SocketType]::Dgram,[Net.Sockets.ProtocolType]::Udp)
        $socket.SendTimeout=1000
        # IP_UNICAST_IF selects the interface for this socket only. No system
        # route, adapter, firewall, tunnel or current connection is modified.
        $socket.SetSocketOption([Net.Sockets.SocketOptionLevel]::IP,[Net.Sockets.SocketOptionName]31,[Net.IPAddress]::HostToNetworkOrder([int]$Binding.InterfaceIndex))
        $socket.Bind((New-Object Net.IPEndPoint($local,0)))
        $target=New-Object Net.IPEndPoint($remote,[int]$Binding.RemotePort)
        $payload=New-Object byte[] 96;$rng=[Security.Cryptography.RandomNumberGenerator]::Create()
        try{$rng.GetBytes($payload)}finally{$rng.Dispose()}
        # Deliberately not a WireGuard message: this diagnoses ingress without
        # using any device key or attempting to activate a second identity.
        $payload[0]=84;$payload[1]=67;$payload[2]=73;$payload[3]=80
        $result.LocalAddress=$local.ToString();$result.LocalPort=$socket.LocalEndPoint.Port;$result.RemoteAddress=$remote.ToString();$result.RemotePort=[int]$Binding.RemotePort;$result.InterfaceIndex=[int]$Binding.InterfaceIndex
        $result.NetworkFingerprint=[string]$before.Fingerprint;$result.StartedAtUtc=[DateTimeOffset]::UtcNow.ToString('o')
        $watch=[Diagnostics.Stopwatch]::StartNew()
        do{
            if($socket.SendTo($payload,$target) -eq $payload.Length){$result.SentCount++}
            $remaining=$DurationMilliseconds-$watch.ElapsedMilliseconds
            if($remaining -gt 0){Start-Sleep -Milliseconds ([int][math]::Min(250,$remaining))}
        }while($watch.ElapsedMilliseconds -lt $DurationMilliseconds -and $result.SentCount -lt 24)
        $result.CompletedAtUtc=[DateTimeOffset]::UtcNow.ToString('o')
        $after=Get-TCProbeNetworkContext -Binding $Binding
        $result.NetworkStable=($after.Status -ceq 'Available' -and [string]$after.Fingerprint -ceq [string]$before.Fingerprint -and [string]$after.SnapshotFingerprint -ceq [string]$before.SnapshotFingerprint)
        $result.Status=if($result.NetworkStable -and $result.SentCount -gt 0){'Sent'}else{'Inconclusive'}
        $result.Code=if($result.Status -eq 'Sent'){'BoundUdpDatagramsSent'}else{'IngressNetworkChanged'}
    }catch{$result.Status='Inconclusive';$result.Code='IngressSendUnavailable'}
    finally{if($socket){$socket.Dispose()};if($payload){[Array]::Clear($payload,0,$payload.Length)};if(-not $result.CompletedAtUtc){$result.CompletedAtUtc=[DateTimeOffset]::UtcNow.ToString('o')}}
    return $result
}
Export-ModuleMember -Function Test-TCDeploymentDependencies,Invoke-TCDeploymentUdpIngressSend
