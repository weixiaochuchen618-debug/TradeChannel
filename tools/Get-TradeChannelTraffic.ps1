#requires -Version 5.1
[CmdletBinding()]
param([string]$ReportDirectory=(Join-Path (Split-Path $PSScriptRoot -Parent) 'reports'),[switch]$SaveReport)
$ErrorActionPreference='Stop'
$d=Get-Content -LiteralPath 'C:\ProgramData\TradeChannel\deployment.json' -Encoding UTF8 -Raw|ConvertFrom-Json
$m=Get-Content -LiteralPath $d.ManifestPath -Encoding UTF8 -Raw|ConvertFrom-Json
$cfg=Get-Content -LiteralPath $m.CandidatePath -Encoding UTF8 -Raw|ConvertFrom-Json
$webSuffixes=@($m.TradeDomainSuffixes)
$api=$cfg.experimental.clash_api
if($api.external_controller -notmatch '^127\.0\.0\.1:\d+$' -or -not $api.secret){throw 'Authenticated loopback controller required.'}
$all=@(Get-CimInstance Win32_Process|Select-Object ProcessId,ParentProcessId,Name,ExecutablePath)
$family=@($all|Where-Object {$_.Name -eq 'NinjaTrader.exe'})
$ids=@($family|ForEach-Object {[int]$_.ProcessId})
do{
    $children=@($all|Where-Object {[int]$_.ParentProcessId -in $ids -and [int]$_.ProcessId -notin $ids})
    $family+=$children
    $ids+=@($children|ForEach-Object {[int]$_.ProcessId})
}while($children.Count)
$paths=@($m.TradeProgramPaths)+@($family|Where-Object {$_.ExecutablePath}|Select-Object -ExpandProperty ExecutablePath)
$paths=@($paths|Sort-Object -Unique)
$familySockets=@()
if($ids.Count){$familySockets=@(Get-NetTCPConnection -ErrorAction SilentlyContinue|Where-Object {$_.OwningProcess -in $ids})}
Add-Type -AssemblyName System.Net.Http
$handler=New-Object Net.Http.HttpClientHandler
$handler.UseProxy=$false
$client=New-Object Net.Http.HttpClient($handler)
$client.Timeout=[TimeSpan]::FromSeconds(5)
$client.DefaultRequestHeaders.Authorization=New-Object Net.Http.Headers.AuthenticationHeaderValue('Bearer',[string]$api.secret)
try{
    $base='http://'+$api.external_controller
    $mode=$client.GetStringAsync($base+'/configs').GetAwaiter().GetResult()|ConvertFrom-Json
    $connections=$client.GetStringAsync($base+'/connections').GetAwaiter().GetResult()|ConvertFrom-Json
    $exitName='hk'
    if(@($cfg.outbounds|Where-Object {$_.tag -eq 'trade-exit'}).Count){$selection=$client.GetStringAsync($base+'/proxies/trade-exit').GetAwaiter().GetResult()|ConvertFrom-Json;$exitName=$selection.now}
}finally{$client.Dispose();$handler.Dispose();$cfg=$null;$api=$null}
$trade=@(foreach($c in $connections.connections){
    $match=$false
    foreach($path in $m.TradeProgramPaths){if([string]$c.metadata.processPath -eq $path -or ([string]$c.metadata.processPath).StartsWith($path+' (',[StringComparison]::OrdinalIgnoreCase)){$match=$true;break}}
    $webMatch=$false
    foreach($suffix in $webSuffixes){if($suffix -and ([string]$c.metadata.host -eq $suffix -or ([string]$c.metadata.host).EndsWith('.'+$suffix,[StringComparison]::OrdinalIgnoreCase))){$webMatch=$true;break}}
    $owner=@($familySockets|Where-Object {[string]$_.LocalPort -eq [string]$c.metadata.sourcePort -and [string]$_.RemoteAddress -eq [string]$c.metadata.destinationIP -and [string]$_.RemotePort -eq [string]$c.metadata.destinationPort})
    if($match -or $webMatch -or $owner.Count){[pscustomobject]@{Scope=$(if($match){'ProtectedProgram'}elseif($webMatch){'TradingWebsite'}else{'AttributedChildSocket'});ProcessId=@($owner|Select-Object -ExpandProperty OwningProcess -Unique);ProcessPath=$c.metadata.processPath;DestinationIP=$c.metadata.destinationIP;DestinationPort=$c.metadata.destinationPort;Hostname=$c.metadata.host;Network=$c.metadata.network;OutboundChain=@($c.chains);Rule=$c.rule;UploadBytes=$c.upload;DownloadBytes=$c.download;StartedAt=$c.start}}
})
$unprotected=@($family|Where-Object {$_.ExecutablePath -and $_.ExecutablePath -notin $m.TradeProgramPaths}|Select-Object Name,ExecutablePath -Unique)
$result=[ordered]@{
    CapturedAt=(Get-Date).ToString('o');Mode=$mode.mode;SelectedExit=$exitName;NinjaTraderProcesses=$family
    TradeConnections=$trade;UnexpectedProtectedDirectCount=@($trade|Where-Object {$_.Scope -eq 'ProtectedProgram' -and 'direct' -in $_.OutboundChain}).Count
    ChildDirectConnectionsNeedingReview=@($trade|Where-Object {$_.Scope -eq 'AttributedChildSocket' -and 'direct' -in $_.OutboundChain})
    UnexpectedTradingWebsiteDirectCount=@($trade|Where-Object {$_.Scope -eq 'TradingWebsite' -and 'direct' -in $_.OutboundChain}).Count
    AdditionalProgramPathsNeedingReview=$unprotected
    Note='Only currently open connections are shown. DNS/control sockets may be separate. This does not prove order delivery.'
}
if($SaveReport){$null=New-Item -ItemType Directory -Path $ReportDirectory -Force;$out=Join-Path $ReportDirectory ('trade-traffic-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.json');[IO.File]::WriteAllText($out,($result|ConvertTo-Json -Depth 10),(New-Object Text.UTF8Encoding($true)));$result.Report=$out}
[pscustomobject]$result
