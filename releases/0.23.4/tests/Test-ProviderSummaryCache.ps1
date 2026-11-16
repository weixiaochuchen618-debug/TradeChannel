#requires -Version 5.1
$ErrorActionPreference='Stop'
$package=Split-Path $PSScriptRoot -Parent
. (Join-Path $package 'runtime\TradeChannel.Provider.ps1')
. (Join-Path $package 'runtime\TradeChannel.ProviderSetup.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('tc-summary-test-'+[guid]::NewGuid().ToString('N'));$script:TCProviderSummaryCacheRoot=$root;$checks=0
function Check {param($ok,$message)if(-not $ok){throw $message};$script:checks++}
try{
 $lines=@('mixed-port: 7897','secret: never-persist-this-secret','proxies: [{name: Remote, type: socks5, server: fixture.invalid, port: 10001, username: user, password: never-persist-password}]','rules: ["MATCH,Remote"]')
 $first=Get-TCClashRuntimeFacts $lines -DisplayOnly
 Check ($first.MixedPort -eq 7897) 'summary reads actual source configuration'
 $bytes=@(Get-ChildItem -LiteralPath $root -File|ForEach-Object {[IO.File]::ReadAllText($_.FullName)}) -join ''
 Check ($bytes -notmatch 'never-persist|username|password|Document|GroupDefinitions|Proxies') 'persistent cache omits raw config and authentication'
 $script:TCClashFactsCache=@{};$uncached=${function:Get-TCClashRuntimeFactsUncached}
 function Get-TCClashRuntimeFactsUncached {throw 'unchanged configuration was reparsed'}
 $second=Get-TCClashRuntimeFacts $lines -DisplayOnly
 Check ($second.MixedPort -eq 7897) 'a fresh request reuses only the safe fingerprinted summary'
 ${function:Get-TCClashRuntimeFactsUncached}=$uncached
 $changed=@($lines);$changed[0]='mixed-port: 7898';$third=Get-TCClashRuntimeFacts $changed -DisplayOnly
 Check ($third.MixedPort -eq 7898) 'port change invalidates cached display on the next request'
 $raw=Get-TCClashRuntimeFacts $changed
 Check ($raw.Document -is [Collections.IDictionary] -and (Get-TCProviderValue $raw.Document secret) -ceq 'never-persist-this-secret') 'actual operations reread full typed data instead of trusting a display cache'
 [pscustomobject]@{Passed=$true;Checks=$checks;ProductionWrites=0;NetworkChanges=0}|ConvertTo-Json -Compress
}finally{
 $full=[IO.Path]::GetFullPath($root);if($full.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($full) -match '^tc-summary-test-[a-f0-9]{32}$'){Remove-Item -LiteralPath $full -Recurse -Force}
}
