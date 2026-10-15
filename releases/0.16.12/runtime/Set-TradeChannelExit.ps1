#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidateSet('HongKong','Provider','Status')][string]$Exit,
    [Parameter(Mandatory=$true)][string]$ManifestPath,
    [AllowNull()][AllowEmptyString()][string]$ProviderId,
    [ValidateRange(0,3600)][int]$TimeoutSeconds=0
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'TradeChannel.OperationBudget.ps1')
$operationBudget=New-TCOperationBudget $TimeoutSeconds
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
    $left=[int][Math]::Floor([Math]::Min(12,((Get-TCOperationRemaining $operationBudget)-3)));if($left -lt 1){throw '[TC:ConnectionTimeout] Provider probe has no remaining budget.'}
    $probe=Test-TCProviderForwarding -Port ([int]$target.Port) -TimeoutSeconds $left
    Assert-TCOperationBudget $operationBudget
    if(-not $probe.Ok){throw ([string]$target.Name+' 正在监听，但 HTTPS 转发失败。当前交易线路未改变。')}
    $providerIP=$probe.IP
}
Add-Type -AssemblyName System.Net.Http
$handler=New-Object Net.Http.HttpClientHandler;$handler.UseProxy=$false
$client=New-Object Net.Http.HttpClient($handler);$client.Timeout=[TimeSpan]::FromSeconds(5)
$client.DefaultRequestHeaders.Authorization=New-Object Net.Http.Headers.AuthenticationHeaderValue('Bearer',[string]$api.secret)
$base='http://'+$api.external_controller
try{
    $previous=(Send-TCBudgetController $client GET ($base+'/proxies/trade-exit') $null $operationBudget)|ConvertFrom-Json
    if($Exit -ne 'Status' -and $previous.now -ne $wanted){
        $null=Send-TCBudgetController $client PUT ($base+'/proxies/trade-exit') ('{"name":"'+$wanted+'"}') $operationBudget
        $null=Send-TCBudgetController $client POST ($base+'/cache/dns/flush') $null $operationBudget
        Clear-DnsClientCache
    }
    $selected=(Send-TCBudgetController $client GET ($base+'/proxies/trade-exit') $null $operationBudget)|ConvertFrom-Json
    if($Exit -ne 'Status' -and $selected.now -ne $wanted){throw 'Selected exit read-back mismatch.'}
    [pscustomobject]@{SelectedExit=$selected.now;PreviousExit=$previous.now;Changed=($previous.now -ne $selected.now);ProviderName=$(if($target){[string]$target.Name}else{$null});ProviderPreflightIPv4=$providerIP;TradingFirewallRetained=$true;AutomaticDirectFallback=$false;Meaning='Manual exit changes close selected-egress sessions. Reconnect NinjaTrader and reload TradingView.'}
}finally{$client.Dispose();$handler.Dispose();$cfg=$null;$api=$null}
