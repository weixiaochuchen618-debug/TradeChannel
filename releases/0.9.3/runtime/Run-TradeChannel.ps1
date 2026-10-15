#requires -Version 5.1
[CmdletBinding()]
param([string]$ManifestPath,[switch]$LoadFunctionsOnly)
# Supervisor: keeps a dynamic TUN permit alive while persistent per-program blocks remain.
# Must be launched via Invoke-TradeChannel after independent-guard validation.
# Only three things end a running session: the engine exits, the user disconnects,
# or the TUN adapter is replaced/unavailable. Proxy changes, provider state and
# transient read failures are recorded and handled without touching trading flows.
function Open-TCSupervisorMutex { New-Object Threading.Mutex($false,'Global\TradeChannelSupervisor') }
function Get-TCSupervisorListeners { @([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()) }
function Test-TCSupervisorController {
    param($Manifest)
    $bridge=Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'RuntimeBridge.psm1') -PassThru -DisableNameChecking
    & $bridge {
        param($m)
        $control=Invoke-TCController $m '/configs'
        $sessions=Invoke-TCController $m '/connections'
        if($control.mode -notin @('rule','global') -or -not $sessions.PSObject.Properties['connections']){throw '控制接口未就绪。'}
    } $Manifest
}
# Event-driven proxy enforcement: a registry change wakes the loop immediately,
# so a proxy written by another program is suspended within milliseconds.
function New-TCProxyWatch {
    if(-not ('TCRegistryWatch' -as [type])){
        Add-Type -TypeDefinition @'
using System;
using System.Threading;
using System.Runtime.InteropServices;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;
public sealed class TCRegistryWatch : IDisposable {
    [DllImport("advapi32.dll")]
    private static extern int RegNotifyChangeKeyValue(SafeRegistryHandle key, bool subtree, uint filter, SafeWaitHandle signal, bool asynchronous);
    private readonly RegistryKey key;
    private readonly AutoResetEvent changed = new AutoResetEvent(false);
    public TCRegistryWatch(string subKey) {
        key = Registry.CurrentUser.OpenSubKey(subKey, false);
        if (key == null) throw new InvalidOperationException("Internet Settings key is missing.");
    }
    public bool Arm() { return RegNotifyChangeKeyValue(key.Handle, false, 0x4, changed.SafeWaitHandle, true) == 0; }
    public bool Wait(int milliseconds) { return changed.WaitOne(milliseconds); }
    public void Dispose() { key.Dispose(); changed.Dispose(); }
}
'@
    }
    $watch=New-Object TCRegistryWatch('Software\Microsoft\Windows\CurrentVersion\Internet Settings')
    if(-not $watch.Arm()){$watch.Dispose();return $null}
    $watch
}
function Wait-TCSupervisorTick {
    param($Watch,[int]$Milliseconds=750)
    if($Watch){if($Watch.Wait($Milliseconds)){$null=$Watch.Arm()}}
    else{Start-Sleep -Milliseconds $Milliseconds}
}
function Invoke-TCSupervisorApi {
    param([string]$Path,[string]$Method='GET',[string]$Body)
    if(-not $script:ApiClient){throw 'Controller client unavailable.'}
    $request=New-Object Net.Http.HttpRequestMessage((New-Object Net.Http.HttpMethod($Method)),($script:ApiBase+$Path))
    if($Body){$request.Content=New-Object Net.Http.StringContent($Body,[Text.Encoding]::UTF8,'application/json')}
    try{
        $response=$script:ApiClient.SendAsync($request).GetAwaiter().GetResult()
        try{$null=$response.EnsureSuccessStatusCode();$text=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult();if($text){$text|ConvertFrom-Json}}finally{$response.Dispose()}
    }finally{$request.Dispose()}
}
function Get-TCDailyIntent {
    param([string]$Root)
    $path=Join-Path $Root 'ui-preferences.json'
    try{
        if(Test-Path -LiteralPath $path){
            $p=Get-Content -LiteralPath $path -Encoding UTF8 -Raw|ConvertFrom-Json
            return [pscustomobject]@{Daily=$(if($p.Daily -eq 'Provider'){'Provider'}else{'Direct'});ProviderId=[string]$p.ProviderId}
        }
    }catch{}
    [pscustomobject]@{Daily='Direct';ProviderId=$null}
}
# Daily traffic follows the user's intent only while the chosen provider is
# verified: a listener owned by that provider's own folders, no competing tunnel
# and real forwarding. Otherwise it stays direct, so it can never loop back into
# itself. Only the daily-exit selector is touched; trading flows use trade-exit.
function Sync-TCDailyExit {
    param($State,$Manifest,[string]$Root)
    if(-not $script:DailySupported){return}
    $intent=Get-TCDailyIntent $Root
    $target=$null
    try{$target=Resolve-TCProviderTarget $Manifest $intent.ProviderId}catch{}
    $current=[string](Invoke-TCSupervisorApi '/proxies/daily-exit').now
    $want='direct';$reason=$null;$name=$null
    if($intent.Daily -eq 'Provider'){
        if(-not $target){$reason='NotConfigured'}
        else{
            $name=[string]$target.Name;$tag=[string]$target.Tag
            # The loop refreshes ForeignTunnel on its own slower cadence.
            $health=Get-TCProviderHealth -Provider $target -SkipTunnelCheck
            if($health.Healthy -and $State.ForeignTunnel){$health=[pscustomobject]@{Healthy=$false;Reason='ForeignTunnel'}}
            if(-not $health.Healthy){$reason=[string]$health.Reason}
            elseif($current -eq $tag){$want=$tag}
            else{
                # Restore only after real forwarding is proven; the probe runs detached so
                # proxy enforcement in this loop is never delayed by a slow provider.
                if($script:Preflight){
                    if($script:Preflight.HasExited){
                        $probe=Read-TCProviderPreflight $script:Preflight $script:PreflightFile;$wasFor=$script:PreflightTag;$script:Preflight=$null;$script:PreflightTag=$null
                        # A result for a provider the user has since switched away from proves nothing.
                        if($probe.Ok -and $wasFor -eq $tag){$want=$tag}else{$reason='ForwardingFailed';$script:NextPreflight=(Get-Date).AddSeconds(30)}
                    }else{$reason='Checking'}
                }elseif((Get-Date) -ge $script:NextPreflight){
                    $script:Preflight=Start-TCProviderPreflight -Port ([int]$target.Port) -OutFile $script:PreflightFile -TimeoutSeconds 6
                    $script:PreflightTag=$(if($script:Preflight){$tag}else{$null})
                    $reason=if($script:Preflight){'Checking'}else{'ForwardingFailed'}
                }else{$reason='ForwardingFailed'}
            }
        }
    }
    if($current -ne $want){$null=Invoke-TCSupervisorApi '/proxies/daily-exit' 'PUT' ('{"name":"'+$want+'"}');$current=$want}
    $State.DailyIntent=$intent.Daily;$State.DailyEffective=$current;$State.DailyReason=$reason
    $State.DailyProvider=$name;$State.DailyProviderId=$intent.ProviderId
}
function Invoke-TCSupervisor {
param([string]$ManifestPath,[string]$Root=(Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'TradeChannel'))
$ErrorActionPreference='Stop'
$root=$Root
$statePath=Join-Path $root 'runtime.json'
$stopPath=Join-Path $root 'stop.request'
. (Join-Path $PSScriptRoot 'TradeChannel.Proxy.ps1')
. (Join-Path $PSScriptRoot 'TradeChannel.Provider.ps1')
. (Join-Path $PSScriptRoot 'TradeChannel.Agents.ps1')
try{Initialize-TCNetTable}catch{}
$m=Get-Content -LiteralPath $ManifestPath -Encoding UTF8 -Raw|ConvertFrom-Json
if(-not $m.SyntaxValidated -or -not $m.DeploymentApproved){throw '候选配置必须先通过检查，并由部署向导启用。'}
$mutex=Open-TCSupervisorMutex
try{$ownsMutex=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$ownsMutex=$true}
if(-not $ownsMutex){$mutex.Dispose();throw 'A TradeChannel supervisor is already running.'}
$proc=$null;$permit=$null;$oldProxy=$null;$watch=$null;$script:providerProxyBackup=$null
$script:ApiClient=$null;$script:ApiHandler=$null;$script:ApiBase=$null;$script:DailySupported=$false
$script:Preflight=$null;$script:PreflightTag=$null;$script:NextPreflight=[DateTime]::MinValue;$script:PreflightFile=Join-Path $root 'logs\provider-preflight.txt'
# Ports any registered provider may drive the system proxy to, so a provider the
# user adds later is recognised instead of reported as an unknown proxy. A
# damaged registry only costs that recognition; it never stops the channel.
$script:ProviderProxyPorts=@()
try{$script:ProviderProxyPorts=@(Get-TCProviderProxyPorts $m (Read-TCProviderStore (Join-Path $root 'Product')))}catch{try{$script:ProviderProxyPorts=@(Get-TCProviderProxyPorts $m $null)}catch{}}
$state=[ordered]@{SchemaVersion=2;SupervisorPid=$PID;SupervisorStartedAt=$null;EnginePid=$null;EngineStartedAt=$null;BootStartedAt=$null;StartedAt=(Get-Date).ToString('o');ManifestPath=$ManifestPath;ConfigPath=$m.CandidatePath;State='Starting';Error=$null;CleanupError=$false;TradingDirectAccessBlocked=$false;SystemProxyBefore=$null;FinishedAt=$null
    DailySupported=$false;DailyIntent=$null;DailyEffective=$null;DailyReason=$null;DailyProvider=$null;DailyProviderId=$null;ForeignTunnel=$null;ProxyEvents=0;LastProxyAt=$null;LastProxyKind=$null;LastProxySummary=$null;TransientErrors=0;LastTransientError=$null}
$terminalState='Disconnected';$exitCode=0
function Save-State {
    $tmp=Join-Path $root 'runtime.next.json'
    [IO.File]::WriteAllText($tmp,($state|ConvertTo-Json -Depth 6),(New-Object Text.UTF8Encoding($true)))
    if(Test-Path -LiteralPath $statePath){[IO.File]::Replace($tmp,$statePath,(Join-Path $root 'runtime.previous.json'))}else{[IO.File]::Move($tmp,$statePath)}
}
function Notify-ProxyChange {
    if(-not ('TradeChannelProxyNotify' -as [type])){
        Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class TradeChannelProxyNotify { [DllImport("wininet.dll", SetLastError=true)] public static extern bool InternetSetOption(IntPtr handle, int option, IntPtr buffer, int length); }'
    }
    $null=[TradeChannelProxyNotify]::InternetSetOption([IntPtr]::Zero,39,[IntPtr]::Zero,0)
    $null=[TradeChannelProxyNotify]::InternetSetOption([IntPtr]::Zero,37,[IntPtr]::Zero,0)
}
function Normalize-ProviderProxy {
    $regPath='HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $p=Get-ItemProperty -LiteralPath $regPath
    $httpPort=if($m.ProviderHttpPort){[int]$m.ProviderHttpPort}else{8001}
    $socksPort=if($m.ProviderSocksPort){[int]$m.ProviderSocksPort}else{10823}
    $pacPort=if($m.ProviderPacPort){[int]$m.ProviderPacPort}else{7777}
    $decision=Get-TradeProxyDecision -ProxyEnable ([int]$p.ProxyEnable) -ProxyServer ([string]$p.ProxyServer) -AutoConfigURL ([string]$p.AutoConfigURL) -HttpPort $httpPort -SocksPort $socksPort -PacPort $pacPort -KnownPorts $script:ProviderProxyPorts
    if(-not $decision.NeedsNormalization){return $null}
    # TradeChannel owns the system proxy while it runs: browsers must reach the TUN
    # so trading sites keep their exit; the program guard blocks loopback proxies.
    if($decision.ProxyEnabled -or $decision.PACEnabled){$script:providerProxyBackup=@{ProxyEnable=[int]$p.ProxyEnable;ProxyServer=[string]$p.ProxyServer;AutoConfigURL=$decision.RestorablePAC}}
    if($decision.ProxyEnabled){Set-ItemProperty -LiteralPath $regPath -Name ProxyEnable -Value 0}
    if($decision.PACEnabled -or $decision.PACDisabledMarker){Remove-ItemProperty -LiteralPath $regPath -Name AutoConfigURL -ErrorAction SilentlyContinue}
    Notify-ProxyChange
    $decision
}
function Register-TCProxyEvent {
    param($Decision)
    if(-not $Decision -or -not ($Decision.ProxyEnabled -or $Decision.PACEnabled)){return $false}
    $state.ProxyEvents=[int]$state.ProxyEvents+1;$state.LastProxyAt=(Get-Date).ToString('o');$state.LastProxyKind=[string]$Decision.Kind;$state.LastProxySummary=[string]$Decision.Summary
    $true
}
function Register-TCTransient {
    param([string]$Code)
    $state.TransientErrors=[int]$state.TransientErrors+1;$state.LastTransientError=$Code
}
try{
    # Publish Starting before any check can fail, replacing stale Running data.
    $state.SupervisorStartedAt=(Get-Process -Id $PID -ErrorAction Stop).StartTime.ToUniversalTime().ToString('o')
    $state.BootStartedAt=(Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime.ToUniversalTime().ToString('o')
    Save-State
    if(Test-Path -LiteralPath $stopPath){throw (New-Object OperationCanceledException('连接已取消。'))}
    if(Get-Process -Name NinjaTrader -ErrorAction SilentlyContinue){throw 'Close NinjaTrader before starting or replacing the channel.'}
    $oldTunnels=@(Get-Service -Name 'WireGuardTunnel*' -ErrorAction SilentlyContinue|Where-Object {$_.Status -eq 'Running'})
    if($oldTunnels.Count){throw '请在 WireGuard 中停用旧隧道，再启动本通道。不要卸载它。'}
    if(Get-Process -Name 'sing-box' -ErrorAction SilentlyContinue){throw 'Another sing-box engine is running; resolve the conflict first.'}
    if(@(Get-TCSupervisorListeners|Where-Object {$_.Port -eq $m.ControlPort}).Count){throw 'Control port already in use.'}
    $guardSource=Join-Path $PSScriptRoot 'TradeChannelGuard.cs'
    if(-not ('TradeChannelGuard' -as [type])){Add-Type -Path $guardSource}
    if(@($m.TradeProgramPaths).Count){
        $null=[TradeChannelGuard]::InstallPersistentBlocks([string[]]$m.TradeProgramPaths)
        $state.TradingDirectAccessBlocked=$true
    }
    $reg='HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $oldProxy=Get-ItemProperty -LiteralPath $reg
    $state.SystemProxyBefore=[int]$oldProxy.ProxyEnable
    $null=Register-TCProxyEvent (Normalize-ProviderProxy)
    Save-State
    if(Test-Path -LiteralPath $stopPath){throw (New-Object OperationCanceledException('连接已取消。'))}
    # The engine reads the AI assistant rule-sets at start; they must exist and
    # match the saved choice. A failure here falls back to an empty list.
    try{$null=Sync-TCAgentRuleSets -Root $root}catch{}
    $stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
    $outLog=Join-Path $root ('logs\channel-'+$stamp+'.out.log')
    $errLog=Join-Path $root ('logs\channel-'+$stamp+'.err.log')
    $proc=Start-Process -FilePath $m.EnginePath -ArgumentList @('run','-c',('"'+$m.CandidatePath+'"')) -WindowStyle Hidden -PassThru -RedirectStandardOutput $outLog -RedirectStandardError $errLog
    $state.EnginePid=$proc.Id
    $state.EngineStartedAt=$proc.StartTime.ToUniversalTime().ToString('o')
    Save-State
    $deadline=(Get-Date).AddSeconds(15)
    do{
        if(Test-Path -LiteralPath $stopPath){throw (New-Object OperationCanceledException('连接已取消。'))}
        if($proc.HasExited){throw 'Channel engine exited during startup; see the restricted logs.'}
        $adapters=@(Get-NetAdapter -Name 'TradeChannel' -ErrorAction SilentlyContinue|Where-Object {$_.Status -eq 'Up'})
        $listeners=@(Get-TCSupervisorListeners|Where-Object {$_.Port -eq $m.ControlPort -and $_.Address.ToString() -eq '127.0.0.1'})
        if($adapters.Count -eq 1 -and $listeners.Count){break}
        Start-Sleep -Milliseconds 250
    }while((Get-Date) -lt $deadline)
    if($adapters.Count -ne 1 -or -not $listeners.Count){throw 'TUN or controller did not become ready.'}
    Test-TCSupervisorController $m
    if(Test-Path -LiteralPath $stopPath){throw (New-Object OperationCanceledException('连接已取消。'))}
    if(@($m.TradeProgramPaths).Count){$permit=[TradeChannelGuard]::OpenTunPermit([string[]]$m.TradeProgramPaths,[uint32]$adapters[0].ifIndex)}
    $tunGuid=$adapters[0].InterfaceGuid
    # Controller client for daily-exit reconciliation; secret stays in memory.
    try{
        $cfg=Get-Content -LiteralPath $m.CandidatePath -Encoding UTF8 -Raw|ConvertFrom-Json
        $api=$cfg.experimental.clash_api
        if(@($cfg.outbounds|Where-Object {$_.tag -eq 'daily-exit'}).Count -and $api.external_controller -match '^127\.0\.0\.1:\d+$' -and $api.secret){
            Add-Type -AssemblyName System.Net.Http
            $script:ApiHandler=New-Object Net.Http.HttpClientHandler;$script:ApiHandler.UseProxy=$false
            $script:ApiClient=New-Object Net.Http.HttpClient($script:ApiHandler);$script:ApiClient.Timeout=[TimeSpan]::FromSeconds(3)
            $script:ApiClient.DefaultRequestHeaders.Authorization=New-Object Net.Http.Headers.AuthenticationHeaderValue('Bearer',[string]$api.secret)
            $script:ApiBase='http://'+$api.external_controller
            $script:DailySupported=$true
        }
    }catch{$script:DailySupported=$false}finally{$cfg=$null;$api=$null}
    $state.DailySupported=$script:DailySupported
    try{$state.ForeignTunnel=Get-TCForeignTunnel}catch{Register-TCTransient 'TunnelCheck'}
    try{Sync-TCDailyExit -State $state -Manifest $m -Root $root}catch{Register-TCTransient 'DailySync'}
    $state.State='Running'
    Save-State
    try{$watch=New-TCProxyWatch}catch{$watch=$null}
    $adapterMisses=0;$tick=0
    while(-not $proc.HasExited -and -not(Test-Path -LiteralPath $stopPath)){
        Wait-TCSupervisorTick $watch 750
        $tick++
        $before=($state|ConvertTo-Json -Compress -Depth 3)
        # Proxy first: it is the only check another program can race against.
        try{$null=Register-TCProxyEvent (Normalize-ProviderProxy)}catch{Register-TCTransient 'ProxyCheck'}
        # Definitive TUN replacement ends the session; a missing reading does not.
        $nowAdapter=$null
        try{$nowAdapter=@(Get-NetAdapter -Name TradeChannel -ErrorAction SilentlyContinue)}catch{Register-TCTransient 'AdapterRead'}
        if($null -ne $nowAdapter){
            if($nowAdapter.Count -eq 1 -and $nowAdapter[0].InterfaceGuid -ne $tunGuid){throw 'TUN identity changed; trading remains blocked.'}
            if($nowAdapter.Count -eq 1 -and $nowAdapter[0].Status -eq 'Up'){$adapterMisses=0}else{$adapterMisses++}
        }else{$adapterMisses++}
        if($adapterMisses -ge 8){throw 'TUN adapter unavailable; trading remains blocked.'}
        if($tick % 9 -eq 0){try{$state.ForeignTunnel=Get-TCForeignTunnel}catch{Register-TCTransient 'TunnelCheck'}}
        if($tick % 3 -eq 0){try{Sync-TCDailyExit -State $state -Manifest $m -Root $root}catch{Register-TCTransient 'DailySync'}}
        if(($state|ConvertTo-Json -Compress -Depth 3) -ne $before){try{Save-State}catch{}}
    }
    if($proc.HasExited -and -not (Test-Path -LiteralPath $stopPath)){throw 'Channel engine stopped unexpectedly; persistent trading blocks remain active.'}
}catch [OperationCanceledException]{
    $terminalState='Disconnected';$state.Error=$null
}catch{
    $terminalState='StoppedWithError';$exitCode=1
    # Do not persist native/parser exceptions which can include config secrets.
    $state.Error='通道启动或运行失败，请检查受限诊断日志；不会自动重启。'
}
finally{
    $cleanupErrors=New-Object 'System.Collections.Generic.List[string]'
    $state.State='Stopping'
    try{Save-State}catch{$cleanupErrors.Add('停机状态写入失败。')}
    try{if($watch){$watch.Dispose()}}catch{}
    try{if($script:Preflight){if(-not $script:Preflight.HasExited){$script:Preflight.Kill()};$script:Preflight.Dispose()}}catch{}
    try{if($script:ApiClient){$script:ApiClient.Dispose()};if($script:ApiHandler){$script:ApiHandler.Dispose()}}catch{}
    # Revoke the dynamic exception before stopping the engine.
    try{if($permit){$permit.Dispose()}}catch{$cleanupErrors.Add('撤销临时放行失败，需检查保护状态。')}
    try{if($proc){if(-not $proc.HasExited){$proc.Kill();if(-not $proc.WaitForExit(8000)){throw 'Engine stop timed out'}};if(-not $proc.HasExited){throw 'Engine remains alive'};$proc.Dispose()}}catch{$cleanupErrors.Add('通道进程清理失败，请检查实际运行状态。')}
    try{if($script:providerProxyBackup){
        $current=Get-ItemProperty -LiteralPath $reg
        if($current.ProxyEnable -eq 0 -and [string]$current.ProxyServer -eq [string]$script:providerProxyBackup.ProxyServer -and [string]::IsNullOrEmpty([string]$current.AutoConfigURL)){
            Set-ItemProperty -LiteralPath $reg -Name ProxyEnable -Value ([int]$script:providerProxyBackup.ProxyEnable)
            if([string]::IsNullOrWhiteSpace([string]$script:providerProxyBackup.AutoConfigURL)){
                Remove-ItemProperty -LiteralPath $reg -Name AutoConfigURL -ErrorAction SilentlyContinue
            }else{Set-ItemProperty -LiteralPath $reg -Name AutoConfigURL -Value ([string]$script:providerProxyBackup.AutoConfigURL)}
            Notify-ProxyChange
        }
    }}catch{$cleanupErrors.Add('恢复代理设置未完成，请检查普通网络。')}
    $state.State=$terminalState;$state.FinishedAt=(Get-Date).ToString('o');$state.DailyEffective=$null
    if($cleanupErrors.Count){$state.State='StoppedWithError';$state.CleanupError=$true;$exitCode=1;$state.Error=([string]$state.Error+' '+($cleanupErrors.ToArray() -join ' ')).Trim()}
    try{Save-State}catch{$exitCode=1;[Console]::Error.WriteLine('无法写入最终状态，请使用检查连接查看实际情况。')}
    # Preserve stop.request; opening the console never clears manual disconnect.
    try{$mutex.ReleaseMutex()}finally{$mutex.Dispose()}
}
return $exitCode
}
if(-not $LoadFunctionsOnly){
    if(-not $ManifestPath){throw '请指定已验证的节点配置。'}
    exit (Invoke-TCSupervisor -ManifestPath $ManifestPath)
}
