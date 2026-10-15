#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidateSet('Trading','Global','Status')][string]$Mode,
    [Parameter(Mandatory=$true)][string]$ConfigPath,
    [ValidateRange(0,3600)][int]$TimeoutSeconds=0
)

# Talks only to the authenticated loopback controller of an already running engine.
# Switching mode never restarts the engine. Only daily connections that were routed
# by the previous mode are closed, so they reconnect on the new path; connections
# matched by the trading-program and trading-site rules are left untouched, and so
# are assistant connections the list keeps on the trading line.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'TradeChannel.OperationBudget.ps1')
$operationBudget=New-TCOperationBudget $TimeoutSeconds
. (Join-Path $PSScriptRoot 'TradeChannel.Agents.ps1')
$cfg=Get-Content -LiteralPath $ConfigPath -Encoding UTF8 -Raw | ConvertFrom-Json
$api=$cfg.experimental.clash_api
if ($api.external_controller -notmatch '^127\.0\.0\.1:(\d+)$' -or [string]::IsNullOrWhiteSpace($api.secret)) { throw 'An authenticated IPv4 loopback-only controller is required.' }
$port=[int]$matches[1]
if ($port -lt 1024 -or $port -gt 65535) { throw 'Unexpected controller port.' }
Add-Type -AssemblyName System.Net.Http
$handler=New-Object Net.Http.HttpClientHandler
$handler.UseProxy=$false
$client=New-Object Net.Http.HttpClient($handler)
$client.Timeout=[TimeSpan]::FromSeconds(5)
$client.DefaultRequestHeaders.Authorization=New-Object Net.Http.Headers.AuthenticationHeaderValue('Bearer',[string]$api.secret)
$base='http://127.0.0.1:'+$port
function Send-TCController {
    param([string]$Method,[string]$Path,[string]$Body)
    $null=Send-TCBudgetController $client $Method ($base+$Path) $Body $operationBudget
}
try {
    $dnsFlushed=$false;$closed=0;$kept=0;$cacheWarning=$null
    $actual=(Send-TCBudgetController $client GET ($base+'/configs') $null $operationBudget) | ConvertFrom-Json
    $previous=[string]$actual.mode
    if ($Mode -ne 'Status') {
        $wanted=if($Mode -eq 'Trading'){'rule'}else{'global'}
        # HTTP 204 is also returned when sing-box rejects an undeclared mode.
        # Verify capability BEFORE PATCH, DNS flush or any connection deletion.
        if(@($actual.'mode-list') -notcontains $wanted){throw '[TC:ModeUnavailable] 当前引擎配置缺少所需分流模式，请更新配置并重新连接；本次未切换、未关闭任何连接。'}
        if ($previous -ne $wanted) {
            $spec=$null
            if($wanted -eq 'rule'){
                try{$spec=Get-TCAppliedAgentSpec $cfg}catch{throw 'AI 助手名单无法读取，未切换模式，现有连接保持。'}
            }
            $connections=(Send-TCBudgetController $client GET ($base+'/connections') $null $operationBudget) | ConvertFrom-Json
            $plan=Get-TCModeSwitchCloses @($connections.connections) $wanted $spec
            Send-TCController 'PATCH' '/configs' ('{"mode":"'+$wanted+'"}')
            $actual=(Send-TCBudgetController $client GET ($base+'/configs') $null $operationBudget) | ConvertFrom-Json
            if($actual.mode -ne $wanted){throw '[TC:ModeMismatch] 控制器未接受模式切换，尚未清缓存或关闭连接，请刷新实际状态。'}
            # Mode has really changed. A cache flush failure must not roll back
            # preferences as if the switch never happened.
            try{
                Send-TCController 'POST' '/cache/dns/flush'
                Clear-DnsClientCache -ErrorAction Stop
                $dnsFlushed=$true
            }catch{$cacheWarning='模式已切换，DNS 缓存刷新未完成；部分应用可能需要重新连接。'}
            $kept=$plan.Kept
            foreach ($id in @($plan.Close)) {
                Assert-TCOperationBudget $operationBudget
                if ($id -notmatch '^[A-Za-z0-9-]+$') { continue }
                try { Send-TCController 'DELETE' ('/connections/'+$id); $closed++ } catch {}
            }
        }
    }
    $connections=(Send-TCBudgetController $client GET ($base+'/connections') $null $operationBudget) | ConvertFrom-Json
    $exitName='hk'
    if(@($cfg.outbounds|Where-Object {$_.tag -eq 'trade-exit'}).Count){$selection=(Send-TCBudgetController $client GET ($base+'/proxies/trade-exit') $null $operationBudget)|ConvertFrom-Json;$exitName=$selection.now}
    [pscustomobject]@{
        ControllerMode=$actual.mode
        PreviousMode=$previous
        SelectedExit=$exitName
        ActiveConnections=@($connections.connections).Count
        EngineRestarted=$false
        DailyConnectionsClosed=$closed
        AssistantConnectionsKept=$kept
        TradingConnectionsClosed=0
        EngineAndWindowsDNSCachesCleared=$dnsFlushed
        CacheWarning=$cacheWarning
        AvailableModes=@($actual.'mode-list')
        Meaning='New connections follow the new mode at once. Daily connections from the previous mode were closed and reconnect on the new path; trading connections and listed assistant connections were kept.'
        DisconnectProtection='This command does not establish or verify an independent firewall guard.'
    }
} finally { $client.Dispose(); $handler.Dispose(); $cfg=$null; $api=$null }
