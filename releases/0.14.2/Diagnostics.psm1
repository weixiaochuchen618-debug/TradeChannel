#requires -Version 5.1
Set-StrictMode -Version 2
function Test-TCDiagnosticTcp {
    param([string]$ServerHost,[int]$Port,[int]$TimeoutMs=2500)
    $socket=New-Object Net.Sockets.TcpClient;$timer=[Diagnostics.Stopwatch]::StartNew();$wait=$null
    try {
        $pending=$socket.BeginConnect($ServerHost,$Port,$null,$null);$wait=$pending.AsyncWaitHandle
        if(-not $wait.WaitOne($TimeoutMs)){return [pscustomobject]@{Port=$Port;Reachable=$false;LatencyMs=$null;Reason='Timeout'}}
        $socket.EndConnect($pending);$timer.Stop()
        [pscustomobject]@{Port=$Port;Reachable=$true;LatencyMs=[math]::Round($timer.Elapsed.TotalMilliseconds,1);Reason='Connected'}
    }catch{[pscustomobject]@{Port=$Port;Reachable=$false;LatencyMs=$null;Reason='Unavailable'}}
    finally{if($wait){$wait.Dispose()};$socket.Dispose()}
}
function Test-TCNodeDiagnostics {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][string]$Id)
    $ErrorActionPreference='Stop'
    $module=Import-Module (Join-Path $PSScriptRoot 'NodeStore.psm1') -PassThru -DisableNameChecking
    $info=Get-TCTransportInfo -Root $Root -Id $Id
    $facts=& $module {
        param($StoreRoot,$NodeId)
        $node=@(Get-TCNodes -Root $StoreRoot|Where-Object {$_.id -eq $NodeId})[0]
        $mf=Read-TCJson $node.manifestPath;$cfg=Read-TCJson $mf.CandidatePath
        $checks=New-Object 'Collections.Generic.List[object]'
        try{Test-TCCheckedConfiguration $mf.EnginePath $mf.CandidatePath;$checks.Add([pscustomobject]@{Label='引擎与配置依赖';Ok=$true;Message='配置语法及出站依赖通过'})}
        catch{$checks.Add([pscustomobject]@{Label='引擎与配置依赖';Ok=$false;Message=$_.Exception.Message})}
        if(Get-TCProperty $mf 'CandidateSHA256'){$valid=(Get-FileHash -LiteralPath $mf.CandidatePath).Hash -eq $mf.CandidateSHA256;$checks.Add([pscustomobject]@{Label='配置完整性';Ok=$valid;Message=$(if($valid){'文件与节点校验记录一致'}else{'配置文件已改变，请恢复原配置或重新导入'})})}
        $wg=[string](Get-TCProperty $mf 'WgPath' '')
        $endpoints=@(Get-TCProperty $cfg 'endpoints' @()|Where-Object {$_.type -eq 'wireguard'})
        if($wg -and [IO.File]::Exists($wg) -and $endpoints.Count -eq 1){
            $key=Invoke-TCNative -FilePath $wg -ArgumentList @('pubkey') -InputText $endpoints[0].private_key
            $record=[string](Get-TCProperty $mf 'ClientPublicKey' '')
            $ok=($key.ExitCode -eq 0 -and $record -and $key.StandardOutput.Trim() -ceq $record)
            $checks.Add([pscustomobject]@{Label='本机设备密钥';Ok=$ok;Message=$(if($ok){'私钥与本机公钥记录匹配；服务器授权需连接后确认'}else{'无法核实本机密钥记录，请重新完成设备授权'})})
            $key=$null
        }
        [pscustomobject]@{Checks=$checks.ToArray();ConfigValidated=(-not @($checks.ToArray()|Where-Object {-not $_.Ok}).Count)}
    } $Root $info.Id
    $ports=if($info.Transport){@([int]$info.Transport.Port,22)|Select-Object -Unique}else{@(22,443)}
    $serverHost=if($info.Transport){[string]$info.Transport.Server}else{[string]$info.DefaultServer}
    $probes=@(foreach($port in $ports){Test-TCDiagnosticTcp $serverHost $port})
    $reachable=@($probes|Where-Object {$_.Reachable})
    $checks=New-Object 'Collections.Generic.List[object]'
    foreach($check in @($facts.Checks)){$checks.Add($check)}
    foreach($probe in $probes){$checks.Add([pscustomobject]@{Label=('TCP '+$probe.Port);Ok=$probe.Reachable;Message=$(if($probe.Reachable){'可建立连接，耗时 '+$probe.LatencyMs+' ms'}else{'无可用 TCP 响应；可能未监听、端口受限或路径不可达'})})}
    $latency=if($reachable.Count){$reachable[0].LatencyMs}else{$null}
    $summary=if(-not $facts.ConfigValidated){'本机配置检查未通过，请先处理下方问题。'}elseif($info.Transport){
        $actual=@($probes|Where-Object {$_.Port -eq [int]$info.Transport.Port})[0]
        if($actual.Reachable){'TCP 传输端口可达；Reality 认证、WireGuard 握手及转发需连接后检查。'}else{'TCP 传输端口不可达，请检查对应服务与云安全组。'}
    }elseif($reachable.Count){'管理或 Web 端口可达；当前为 UDP WireGuard，尚未验证 UDP 与设备授权。'}else{'未探测到 TCP 22/443 响应。纯 UDP 服务器可能仍正常，不能据此判定离线。'}
    [pscustomobject]@{Id=$info.Id;Name=$info.Name;Endpoint=$info.Endpoint;TransportMode=$info.Mode;Reachable=($reachable.Count -gt 0);LatencyMs=$latency;Summary=$summary;Checks=$checks.ToArray();RemoteAuthorization='NotTested';Handshake='NotTested';NetworkChanged=$false}
}
Export-ModuleMember -Function Test-TCNodeDiagnostics
