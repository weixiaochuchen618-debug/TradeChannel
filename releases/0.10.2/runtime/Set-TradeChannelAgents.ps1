#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$ManifestPath,[string]$Root=(Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'TradeChannel'))
# Applies the saved AI assistant choice: rewrites the two rule-sets the engine
# watches, then moves only assistant connections whose path changed. Trading
# programs and trading sites match earlier rules and are never touched.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'TradeChannel.Agents.ps1')
$m=Get-Content -LiteralPath $ManifestPath -Encoding UTF8 -Raw|ConvertFrom-Json
$cfg=Get-Content -LiteralPath $m.CandidatePath -Encoding UTF8 -Raw|ConvertFrom-Json
$api=$cfg.experimental.clash_api
if($api.external_controller -notmatch '^127\.0\.0\.1:\d+$' -or -not $api.secret){throw 'An authenticated loopback controller is required.'}
$selection=Get-TCAgentSelection (Read-TCAgentPreferences $Root)
$paths=Get-TCAgentPaths $Root
$watched=@();if($cfg.route.PSObject.Properties['rule_set']){$watched=@($cfg.route.rule_set|Where-Object {$_.tag -eq 'tc-agents'})}
if(-not $watched.Count){
    $cfg=$null;$api=$null
    return [pscustomobject]@{Supported=$false;Lane=$selection.Lane;Applied=$false;Changed=$false;ConnectionsMoved=0;TradingConnectionsAffected=$false}
}
if(-not ([string]$watched[0].path).Equals($paths.Route,[StringComparison]::OrdinalIgnoreCase)){throw 'The running policy watches a different assistant list file.'}
$written=Write-TCAgentRuleSets -Root $Root -Selection $selection
$moved=0
if($written.Changed){
    # The engine reloads watched rule-sets on change; give it a moment before
    # re-routing existing connections.
    Start-Sleep -Milliseconds 1800
    Add-Type -AssemblyName System.Net.Http
    $handler=New-Object Net.Http.HttpClientHandler;$handler.UseProxy=$false
    $client=New-Object Net.Http.HttpClient($handler);$client.Timeout=[TimeSpan]::FromSeconds(5)
    $client.DefaultRequestHeaders.Authorization=New-Object Net.Http.Headers.AuthenticationHeaderValue('Bearer',[string]$api.secret)
    $base='http://'+$api.external_controller
    try{
        try{$null=$client.PostAsync($base+'/cache/dns/flush',(New-Object Net.Http.StringContent(''))).GetAwaiter().GetResult()}catch{}
        $mode=($client.GetStringAsync($base+'/configs').GetAwaiter().GetResult()|ConvertFrom-Json).mode
        $connections=@(($client.GetStringAsync($base+'/connections').GetAwaiter().GetResult()|ConvertFrom-Json).connections)
        foreach($id in @(Get-TCAgentMoves $connections $mode $written.Spec)){
            if($id -notmatch '^[A-Za-z0-9-]+$'){continue}
            try{$res=$client.DeleteAsync($base+'/connections/'+$id).GetAwaiter().GetResult();try{if($res.IsSuccessStatusCode){$moved++}}finally{$res.Dispose()}}catch{}
        }
    }finally{$client.Dispose();$handler.Dispose()}
    # Answers cached under the previous lane must not outlive the switch.
    try{Clear-DnsClientCache -ErrorAction Stop}catch{try{$null=& ipconfig.exe /flushdns}catch{}}
}
$cfg=$null;$api=$null
[pscustomobject]@{Supported=$true;Lane=$selection.Lane;Applied=$true;Changed=$written.Changed;Entries=(@($selection.Ids).Count+@($selection.Custom).Count);ConnectionsMoved=$moved;TradingConnectionsAffected=$false}
