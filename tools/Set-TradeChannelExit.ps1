#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][ValidateSet('HongKong','Provider','Status')][string]$Exit,[Parameter(Mandatory=$true)][string]$ManifestPath)
$ErrorActionPreference='Stop'
$m=Get-Content -LiteralPath $ManifestPath -Encoding UTF8 -Raw|ConvertFrom-Json
$cfg=Get-Content -LiteralPath $m.CandidatePath -Encoding UTF8 -Raw|ConvertFrom-Json
$api=$cfg.experimental.clash_api
if($api.external_controller -notmatch '^127\.0\.0\.1:\d+$' -or -not $api.secret){throw 'An authenticated loopback controller is required.'}
if($Exit -eq 'Provider'){
    # Query native table: Get-NetTCPConnection can take ~30 seconds while BatVPN initializes.
    $listeners=@(foreach($line in (& "$env:WINDIR\System32\netstat.exe" -ano -p tcp)){
        $columns=@($line.Trim() -split '\s+')
        if($columns.Count -eq 5 -and $columns[0] -eq 'TCP' -and $columns[1] -match (':'+$m.ProviderSocksPort+'$') -and $columns[3] -eq 'LISTENING'){
            [pscustomobject]@{OwningProcess=[int]$columns[4]}
        }
    })
    $verified=$false
    foreach($listener in $listeners){$p=Get-Process -Id $listener.OwningProcess -ErrorAction SilentlyContinue;if($p -and $p.Path -in $m.ProviderProgramPaths){$verified=$true}}
    if(-not $verified){throw 'Connect BatVPN first. Its configured local SOCKS port is not listening under the expected provider process.'}
    # Preflight uses the existing provider, with no credentials or node keys copied.
    $si=New-Object Diagnostics.ProcessStartInfo
    $si.FileName=(Get-Command curl.exe).Source
    $si.Arguments='--proxy socks5h://127.0.0.1:'+$m.ProviderSocksPort+' --noproxy .invalid --silent --show-error --connect-timeout 5 --max-time 12 https://1.1.1.1/cdn-cgi/trace'
    $si.UseShellExecute=$false;$si.CreateNoWindow=$true;$si.RedirectStandardOutput=$true;$si.RedirectStandardError=$true
    $p=New-Object Diagnostics.Process;$p.StartInfo=$si
    try{$null=$p.Start();$result=$p.StandardOutput.ReadToEnd();$errorText=$p.StandardError.ReadToEnd();$p.WaitForExit();if($p.ExitCode -ne 0 -or $result -notmatch '(?m)^ip=([^\r\n]+)'){throw 'The provider listener is present but HTTPS forwarding failed. Current selected exit was not changed.'};$providerIP=$matches[1].Trim()}finally{$p.Dispose()}
}
Add-Type -AssemblyName System.Net.Http
$handler=New-Object Net.Http.HttpClientHandler;$handler.UseProxy=$false
$client=New-Object Net.Http.HttpClient($handler);$client.Timeout=[TimeSpan]::FromSeconds(5)
$client.DefaultRequestHeaders.Authorization=New-Object Net.Http.Headers.AuthenticationHeaderValue('Bearer',[string]$api.secret)
$base='http://'+$api.external_controller
try{
    $previous=$client.GetStringAsync($base+'/proxies/trade-exit').GetAwaiter().GetResult()|ConvertFrom-Json
    if($Exit -ne 'Status'){
        $wanted=if($Exit -eq 'HongKong'){'hk'}else{'provider'}
        $req=New-Object Net.Http.HttpRequestMessage((New-Object Net.Http.HttpMethod('PUT')),($base+'/proxies/trade-exit'))
        $req.Content=New-Object Net.Http.StringContent(('{"name":"'+$wanted+'"}'),[Text.Encoding]::UTF8,'application/json')
        try{$res=$client.SendAsync($req).GetAwaiter().GetResult();try{$null=$res.EnsureSuccessStatusCode()}finally{$res.Dispose()}}finally{$req.Dispose()}
        $flush=New-Object Net.Http.HttpRequestMessage((New-Object Net.Http.HttpMethod('POST')),($base+'/cache/dns/flush'))
        try{$res=$client.SendAsync($flush).GetAwaiter().GetResult();try{$null=$res.EnsureSuccessStatusCode()}finally{$res.Dispose()}}finally{$flush.Dispose()}
        Clear-DnsClientCache
    }
    $selected=$client.GetStringAsync($base+'/proxies/trade-exit').GetAwaiter().GetResult()|ConvertFrom-Json
    if($Exit -ne 'Status' -and $selected.now -ne $wanted){throw 'Selected exit read-back mismatch.'}
    [pscustomobject]@{SelectedExit=$selected.now;PreviousExit=$previous.now;Changed=($previous.now -ne $selected.now);ProviderPreflightIPv4=$(if($Exit -eq 'Provider'){$providerIP}else{$null});TradingFirewallRetained=$true;AutomaticDirectFallback=$false;Meaning='Manual exit changes close selected-egress sessions. Reconnect NinjaTrader and reload TradingView.'}
}finally{$client.Dispose();$handler.Dispose();$cfg=$null;$api=$null}
