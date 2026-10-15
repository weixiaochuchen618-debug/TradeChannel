#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidateSet('HongKong','Provider','Status')][string]$Exit,
    [Parameter(Mandatory=$true)][string]$ManifestPath,
    [AllowNull()][AllowEmptyString()][string]$ProviderId
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'TradeChannel.Provider.ps1')
$m=Get-Content -LiteralPath $ManifestPath -Encoding UTF8 -Raw|ConvertFrom-Json
$cfg=Get-Content -LiteralPath $m.CandidatePath -Encoding UTF8 -Raw|ConvertFrom-Json
$api=$cfg.experimental.clash_api
if($api.external_controller -notmatch '^127\.0\.0\.1:\d+$' -or -not $api.secret){throw 'An authenticated loopback controller is required.'}
$target=$null;$providerIP=$null
$wanted=$null
if($Exit -eq 'HongKong'){$wanted='hk'}
elseif($Exit -eq 'Provider'){
    $target=Resolve-TCProviderTarget $m $ProviderId -ForTrade
    if(-not $target){throw '当前线路配置中没有服务商，请先在「线路」页登记并应用。'}
    if(-not @($cfg.outbounds|Where-Object {$_.tag -eq $target.Tag}).Count){throw '所选服务商尚未写入线路配置，请先在「线路」页应用。'}
    $wanted=[string]$target.Tag
    # The listener must be the provider itself before any trading flow is moved.
    $health=Get-TCProviderHealth -Provider $target
    if(-not $health.Healthy){throw ('暂时无法把交易切到 '+[string]$target.Name+'：'+(Get-TCProviderReasonText ([string]$health.Reason) ([string]$target.Name))+'。当前交易线路未改变。')}
    $policy=Test-TCProviderTradingPolicy -Provider $target
    if(-not $policy.Allowed){throw ('交易备用尚不能确认经代理节点转发：'+[string]$policy.ReasonText+'。当前交易线路未改变。')}
    # Preflight uses the existing provider, with no credentials or node keys copied.
    $probe=Test-TCProviderForwarding -Port ([int]$target.Port) -TimeoutSeconds 12
    if(-not $probe.Ok){throw ([string]$target.Name+' 正在监听，但 HTTPS 转发失败。当前交易线路未改变。')}
    $providerIP=$probe.IP
}
Add-Type -AssemblyName System.Net.Http
$handler=New-Object Net.Http.HttpClientHandler;$handler.UseProxy=$false
$client=New-Object Net.Http.HttpClient($handler);$client.Timeout=[TimeSpan]::FromSeconds(5)
$client.DefaultRequestHeaders.Authorization=New-Object Net.Http.Headers.AuthenticationHeaderValue('Bearer',[string]$api.secret)
$base='http://'+$api.external_controller
try{
    $previous=$client.GetStringAsync($base+'/proxies/trade-exit').GetAwaiter().GetResult()|ConvertFrom-Json
    if($Exit -ne 'Status' -and $previous.now -ne $wanted){
        $req=New-Object Net.Http.HttpRequestMessage((New-Object Net.Http.HttpMethod('PUT')),($base+'/proxies/trade-exit'))
        $req.Content=New-Object Net.Http.StringContent(('{"name":"'+$wanted+'"}'),[Text.Encoding]::UTF8,'application/json')
        try{$res=$client.SendAsync($req).GetAwaiter().GetResult();try{$null=$res.EnsureSuccessStatusCode()}finally{$res.Dispose()}}finally{$req.Dispose()}
        $flush=New-Object Net.Http.HttpRequestMessage((New-Object Net.Http.HttpMethod('POST')),($base+'/cache/dns/flush'))
        try{$res=$client.SendAsync($flush).GetAwaiter().GetResult();try{$null=$res.EnsureSuccessStatusCode()}finally{$res.Dispose()}}finally{$flush.Dispose()}
        Clear-DnsClientCache
    }
    $selected=$client.GetStringAsync($base+'/proxies/trade-exit').GetAwaiter().GetResult()|ConvertFrom-Json
    if($Exit -ne 'Status' -and $selected.now -ne $wanted){throw 'Selected exit read-back mismatch.'}
    [pscustomobject]@{SelectedExit=$selected.now;PreviousExit=$previous.now;Changed=($previous.now -ne $selected.now);ProviderName=$(if($target){[string]$target.Name}else{$null});ProviderPreflightIPv4=$providerIP;TradingFirewallRetained=$true;AutomaticDirectFallback=$false;Meaning='Manual exit changes close selected-egress sessions. Reconnect NinjaTrader and reload TradingView.'}
}finally{$client.Dispose();$handler.Dispose();$cfg=$null;$api=$null}
