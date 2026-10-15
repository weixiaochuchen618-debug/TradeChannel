#requires -Version 5.1
param([Parameter(Mandatory=$true)][string]$OutputPath,[int]$DailyA,[int]$DailyB,[int]$TradeB,[string]$AgentRoot)
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'NodeStore.psm1') -Force -DisableNameChecking -PassThru
$agentFiles=$null
if($AgentRoot){
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'runtime\TradeChannel.Agents.ps1')
    $selection=[pscustomobject]@{Lane='Trade';Ids=@();Custom=@([pscustomobject]@{Kind='Site';Value='assistant.example'})}
    $agentFiles=(Write-TCAgentRuleSets -Root $AgentRoot -Selection $selection).Paths
}
$policy=& $module {
    param($a,$b,$tb,$agent)
    $providers=@(
        [pscustomobject]@{Tag='provider';TradeTag='provider';Port=$a;TradePort=$a;Programs=@('C:\TradeChannelFixture\A\client.exe');Directories=@('C:\TradeChannelFixture\A');BootstrapDomains=@()},
        [pscustomobject]@{Tag='provider2';TradeTag='provider2-trade';Port=$b;TradePort=$tb;Programs=@('C:\TradeChannelFixture\B\client.exe');Directories=@('C:\TradeChannelFixture\B');BootstrapDomains=@()}
    )
    $routePath='';$dnsPath='';if($agent){$routePath=$agent.Route;$dnsPath=$agent.Dns}
    New-TCRoutingPolicy -TradePrograms @('C:\TradeChannelFixture\Trade\NinjaTrader.exe') -TradeDomains @('trading.example') -Providers $providers -EndpointAddress '192.0.2.1' -EndpointIsIP $true -DirectDns '127.0.0.1' -AgentRouteRuleSet $routePath -AgentDnsRuleSet $dnsPath
} $DailyA $DailyB $TradeB $agentFiles
[IO.File]::WriteAllText($OutputPath,($policy|ConvertTo-Json -Depth 30),(New-Object Text.UTF8Encoding($false)))
