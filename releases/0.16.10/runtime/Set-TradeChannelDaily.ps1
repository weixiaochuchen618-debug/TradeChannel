#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidateSet('Direct','Provider','Status')][string]$Daily,
    [Parameter(Mandatory=$true)][string]$ManifestPath,
    [AllowNull()][AllowEmptyString()][string]$ProviderId
)
# Switches only the daily-exit selector. Trading programs and trading sites are
# routed by earlier rules to trade-exit, so their connections are never touched.
# Moving between two registered providers is also just a selector move: the
# engine keeps running and the trading line is not rebuilt.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'TradeChannel.Provider.ps1')
$m=Get-Content -LiteralPath $ManifestPath -Encoding UTF8 -Raw|ConvertFrom-Json
$cfg=Get-Content -LiteralPath $m.CandidatePath -Encoding UTF8 -Raw|ConvertFrom-Json
$api=$cfg.experimental.clash_api
if($api.external_controller -notmatch '^127\.0\.0\.1:\d+$' -or -not $api.secret){throw 'An authenticated loopback controller is required.'}
if(-not @($cfg.outbounds|Where-Object {$_.tag -eq 'daily-exit'}).Count){
    $cfg=$null;$api=$null
    return [pscustomobject]@{Supported=$false;Requested=$Daily;Applied=$false;Effective='direct';Reason='Unsupported';TradingConnectionsAffected=$false}
}
$target=Resolve-TCProviderTarget $m $ProviderId
$want=$null;$reason=$null;$providerIP=$null;$name=$(if($target){[string]$target.Name}else{$null})
if($Daily -eq 'Provider'){
    if(-not $target){$reason='NotConfigured'}
    # The engine only knows the outbounds its own configuration defines.
    elseif(-not @($cfg.outbounds|Where-Object {$_.tag -eq $target.Tag}).Count){$reason='Unsupported'}
    else{
        $health=Get-TCProviderHealth -Provider $target
        if(-not $health.Healthy){$reason=[string]$health.Reason}
        else{
            $probe=Test-TCProviderForwarding -Port ([int]$target.Port) -TimeoutSeconds 8
            if($probe.Ok){$want=[string]$target.Tag;$providerIP=$probe.IP}else{$reason='ForwardingFailed'}
        }
    }
    # Not ready: keep daily traffic direct. The supervisor keeps the saved intent
    # and switches to the provider once it is verified and forwarding.
    if(-not $want){$want='direct'}
}elseif($Daily -eq 'Direct'){$want='direct'}
Add-Type -AssemblyName System.Net.Http
$handler=New-Object Net.Http.HttpClientHandler;$handler.UseProxy=$false
$client=New-Object Net.Http.HttpClient($handler);$client.Timeout=[TimeSpan]::FromSeconds(5)
$client.DefaultRequestHeaders.Authorization=New-Object Net.Http.Headers.AuthenticationHeaderValue('Bearer',[string]$api.secret)
$base='http://'+$api.external_controller
try{
    $previous=($client.GetStringAsync($base+'/proxies/daily-exit').GetAwaiter().GetResult()|ConvertFrom-Json).now
    if($want -and $previous -ne $want){
        $req=New-Object Net.Http.HttpRequestMessage((New-Object Net.Http.HttpMethod('PUT')),($base+'/proxies/daily-exit'))
        $req.Content=New-Object Net.Http.StringContent(('{"name":"'+$want+'"}'),[Text.Encoding]::UTF8,'application/json')
        try{$res=$client.SendAsync($req).GetAwaiter().GetResult();try{$null=$res.EnsureSuccessStatusCode()}finally{$res.Dispose()}}finally{$req.Dispose()}
    }
    $selected=($client.GetStringAsync($base+'/proxies/daily-exit').GetAwaiter().GetResult()|ConvertFrom-Json).now
    if($want -and $selected -ne $want){throw 'Daily exit read-back mismatch.'}
    $applied=($Daily -eq 'Status') -or ($Daily -eq 'Direct' -and $selected -eq 'direct') -or ($Daily -eq 'Provider' -and $target -and $selected -eq $target.Tag)
    [pscustomobject]@{Supported=$true;Requested=$Daily;Applied=$applied;Effective=$selected;Previous=$previous;Reason=$reason;ProviderName=$name;ProviderId=$(if($target){[string]$target.Id}else{$null});ProviderIPv4=$providerIP;TradingConnectionsAffected=$false}
}finally{$client.Dispose();$handler.Dispose();$cfg=$null;$api=$null}
