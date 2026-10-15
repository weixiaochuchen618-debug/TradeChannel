#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidateSet('Trading','Global','Status')][string]$Mode,
    [Parameter(Mandatory=$true)][string]$ConfigPath
)

# Talks only to the authenticated loopback controller of an already running engine.
# This does not launch an engine, close sockets, or claim to migrate existing TCP flows.
$ErrorActionPreference='Stop'
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
try {
    $dnsFlushed=$false
    $actual=$client.GetStringAsync($base+'/configs').GetAwaiter().GetResult() | ConvertFrom-Json
    if ($Mode -ne 'Status') {
        $wanted=if($Mode -eq 'Trading'){'rule'}else{'global'}
        if(@($actual.'mode-list') -notcontains $wanted){throw '[TC:ModeUnavailable] 当前引擎配置缺少所需分流模式，请更新配置并重新连接；当前连接保持。'}
        $request=New-Object Net.Http.HttpRequestMessage((New-Object Net.Http.HttpMethod('PATCH')),($base+'/configs'))
        $request.Content=New-Object Net.Http.StringContent(('{"mode":"'+$wanted+'"}'),[Text.Encoding]::UTF8,'application/json')
        try {
            $response=$client.SendAsync($request).GetAwaiter().GetResult()
            try { $null=$response.EnsureSuccessStatusCode() } finally { $response.Dispose() }
        } finally { $request.Dispose() }
        $actual=$client.GetStringAsync($base+'/configs').GetAwaiter().GetResult() | ConvertFrom-Json
        if($actual.mode -ne $wanted){throw '[TC:ModeMismatch] 控制器未接受模式切换，请刷新实际状态。'}
        # Cached direct-path DNS answers can remain unusable after selecting Hong Kong.
        # Clear engine + Windows resolver caches; existing TCP sessions stay open.
        $flushRequest=New-Object Net.Http.HttpRequestMessage((New-Object Net.Http.HttpMethod('POST')),($base+'/cache/dns/flush'))
        try{
            $flushResponse=$client.SendAsync($flushRequest).GetAwaiter().GetResult()
            try{$null=$flushResponse.EnsureSuccessStatusCode()}finally{$flushResponse.Dispose()}
        }finally{$flushRequest.Dispose()}
        Clear-DnsClientCache -ErrorAction Stop
        $dnsFlushed=$true
    }
    $connections=$client.GetStringAsync($base+'/connections').GetAwaiter().GetResult() | ConvertFrom-Json
    $exitName='hk'
    if(@($cfg.outbounds|Where-Object {$_.tag -eq 'trade-exit'}).Count){$selection=$client.GetStringAsync($base+'/proxies/trade-exit').GetAwaiter().GetResult()|ConvertFrom-Json;$exitName=$selection.now}
    [pscustomobject]@{
        ControllerMode=$actual.mode
        SelectedExit=$exitName
        ActiveConnections=@($connections.connections).Count
        EngineRestarted=$false
        ExistingConnectionsClosed=$false
        EngineAndWindowsDNSCachesCleared=$dnsFlushed
        Meaning='Mode changes apply to NEW connections. Existing application sessions require a controlled reconnect before global-mode acceptance.'
        DisconnectProtection='This command does not establish or verify an independent firewall guard.'
    }
} finally { $client.Dispose(); $handler.Dispose(); $cfg=$null; $api=$null }
