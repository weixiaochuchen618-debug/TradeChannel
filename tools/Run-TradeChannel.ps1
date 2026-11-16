#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$ManifestPath)
# Supervisor: keeps a dynamic TUN permit alive while persistent per-program blocks remain.
# Must be launched via Invoke-TradeChannel after independent-guard validation.
$ErrorActionPreference='Stop'
$root='C:\ProgramData\TradeChannel'
$statePath=Join-Path $root 'runtime.json'
$stopPath=Join-Path $root 'stop.request'
. (Join-Path $PSScriptRoot 'TradeChannel.Proxy.ps1')
$m=Get-Content -LiteralPath $ManifestPath -Encoding UTF8 -Raw|ConvertFrom-Json
if(-not $m.IndependentGuardVerified){throw 'The independent guard has not passed the dedicated-program tests.'}
$mutex=New-Object Threading.Mutex($false,'Global\TradeChannelSupervisor')
if(-not $mutex.WaitOne(0)){$mutex.Dispose();throw 'A TradeChannel supervisor is already running.'}
$proc=$null;$permit=$null;$proxyChanged=$false;$oldProxy=$null;$script:providerProxyBackup=$null
$state=[ordered]@{SupervisorPid=$PID;EnginePid=$null;StartedAt=(Get-Date).ToString('o');ManifestPath=$ManifestPath;ConfigPath=$m.CandidatePath;State='Starting';Error=$null;TradingDirectAccessBlocked=$false;SystemProxyBefore=$null}
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
    $decision=Get-TradeProxyDecision -ProxyEnable ([int]$p.ProxyEnable) -ProxyServer ([string]$p.ProxyServer) -AutoConfigURL ([string]$p.AutoConfigURL)
    if(-not $decision.Allowed){throw $decision.Reason}
    if(-not $decision.NeedsNormalization){return}
    # BatVPN remains the transport; TUN controls which apps use it. Do not stack the system proxy.
    if($decision.ProxyEnabled -or $decision.PACEnabled){$script:providerProxyBackup=@{ProxyEnable=[int]$p.ProxyEnable;ProxyServer=[string]$p.ProxyServer;AutoConfigURL=$decision.RestorablePAC}}
    if($decision.ProxyEnabled){Set-ItemProperty -LiteralPath $regPath -Name ProxyEnable -Value 0}
    if($decision.PACEnabled -or $decision.PACDisabledMarker){Remove-ItemProperty -LiteralPath $regPath -Name AutoConfigURL -ErrorAction SilentlyContinue}
    Notify-ProxyChange
}
try{
    if(Get-Process -Name NinjaTrader -ErrorAction SilentlyContinue){throw 'Close NinjaTrader before starting or replacing the channel.'}
    $active=(& 'C:\Program Files\WireGuard\wg.exe' show interfaces|Out-String).Trim()
    if($LASTEXITCODE -ne 0 -or $active){throw 'Stop the old WireGuard tunnel before starting TradeChannel.'}
    if(Get-Process -Name 'sing-box' -ErrorAction SilentlyContinue){throw 'Another sing-box engine is running; resolve the conflict first.'}
    if(@([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()|Where-Object {$_.Port -eq $m.ControlPort}).Count){throw 'Control port already in use.'}
    $guardSource=Join-Path $PSScriptRoot 'TradeChannelGuard.cs'
    Add-Type -Path $guardSource
    $null=[TradeChannelGuard]::InstallPersistentBlocks([string[]]$m.TradeProgramPaths)
    $state.TradingDirectAccessBlocked=$true
    $reg='HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $oldProxy=Get-ItemProperty -LiteralPath $reg
    $state.SystemProxyBefore=[int]$oldProxy.ProxyEnable
    Normalize-ProviderProxy
    if(Test-Path -LiteralPath $stopPath){Remove-Item -LiteralPath $stopPath -Force}
    Save-State
    $stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
    $outLog=Join-Path $root ('logs\channel-'+$stamp+'.out.log')
    $errLog=Join-Path $root ('logs\channel-'+$stamp+'.err.log')
    $proc=Start-Process -FilePath $m.EnginePath -ArgumentList @('run','-c',('"'+$m.CandidatePath+'"')) -WindowStyle Hidden -PassThru -RedirectStandardOutput $outLog -RedirectStandardError $errLog
    $state.EnginePid=$proc.Id
    $deadline=(Get-Date).AddSeconds(15)
    do{
        if($proc.HasExited){throw 'Channel engine exited during startup; see the restricted logs.'}
        $adapters=@(Get-NetAdapter -Name 'TradeChannel' -ErrorAction SilentlyContinue|Where-Object {$_.Status -eq 'Up'})
        $listeners=@([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()|Where-Object {$_.Port -eq $m.ControlPort -and $_.Address.ToString() -eq '127.0.0.1'})
        if($adapters.Count -eq 1 -and $listeners.Count){break}
        Start-Sleep -Milliseconds 250
    }while((Get-Date) -lt $deadline)
    if($adapters.Count -ne 1 -or -not $listeners.Count){throw 'TUN or controller did not become ready.'}
    $permit=[TradeChannelGuard]::OpenTunPermit([string[]]$m.TradeProgramPaths,[uint32]$adapters[0].ifIndex)
    $tunGuid=$adapters[0].InterfaceGuid
    $state.State='Running'
    Save-State
    while(-not $proc.HasExited -and -not(Test-Path -LiteralPath $stopPath)){
        Start-Sleep -Milliseconds 750
        $nowAdapter=@(Get-NetAdapter -Name TradeChannel -ErrorAction SilentlyContinue)
        if($nowAdapter.Count -ne 1 -or $nowAdapter[0].InterfaceGuid -ne $tunGuid){throw 'TUN identity changed; trading remains blocked.'}
        Normalize-ProviderProxy
    }
    if($proc.HasExited){throw 'Channel engine stopped unexpectedly; persistent trading blocks remain active.'}
    $state.State='EmergencyStopped'
}catch{$state.State='StoppedWithError';$state.Error=$_.Exception.Message}
finally{
    # Revoke the dynamic exception before stopping the engine.
    if($permit){$permit.Dispose()}
    if($proc){if(-not $proc.HasExited){$proc.Kill();$proc.WaitForExit(8000)|Out-Null};$proc.Dispose()}
    if($script:providerProxyBackup){
        $current=Get-ItemProperty -LiteralPath $reg
        if($current.ProxyEnable -eq 0 -and [string]$current.ProxyServer -eq [string]$script:providerProxyBackup.ProxyServer -and [string]::IsNullOrEmpty([string]$current.AutoConfigURL)){
            Set-ItemProperty -LiteralPath $reg -Name ProxyEnable -Value ([int]$script:providerProxyBackup.ProxyEnable)
            if([string]::IsNullOrWhiteSpace([string]$script:providerProxyBackup.AutoConfigURL)){
                Remove-ItemProperty -LiteralPath $reg -Name AutoConfigURL -ErrorAction SilentlyContinue
            }else{Set-ItemProperty -LiteralPath $reg -Name AutoConfigURL -Value ([string]$script:providerProxyBackup.AutoConfigURL)}
            Notify-ProxyChange
        }
    }
    Save-State
    if(Test-Path -LiteralPath $stopPath){Remove-Item -LiteralPath $stopPath -Force}
    $mutex.ReleaseMutex();$mutex.Dispose()
}
