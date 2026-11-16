#requires -Version 5.1
# Saved trade-domain intent is separate from the running engine. Existing nodes
# pick it up only through the explicit, guarded maintenance upgrade.
function Get-TCTradeDomainManagement {
    param([Parameter(Mandatory=$true)][string]$Root)
    $module=Import-Module (Join-Path $PSScriptRoot 'NodeStore.psm1') -PassThru -DisableNameChecking
    $domains=& $module {param($StoreRoot)$index=Join-Path $StoreRoot 'index.json';if([IO.File]::Exists($index)){@((Read-TCIndex $StoreRoot).tradeDomains)}else{@($script:TCDefaultDomains)}} (Join-Path $Root 'Product')
    $applied=@();$dep=Join-Path $Root 'deployment.json'
    if(Test-Path -LiteralPath $dep){$d=Get-Content -LiteralPath $dep -Raw -Encoding UTF8|ConvertFrom-Json;if($d.ManifestPath -and (Test-Path -LiteralPath $d.ManifestPath)){$mf=Get-Content -LiteralPath $d.ManifestPath -Raw -Encoding UTF8|ConvertFrom-Json;$applied=@($mf.TradeDomainSuffixes)}}
    $different=((@($domains|Sort-Object)-join '|') -cne (@($applied|Sort-Object)-join '|'))
    [pscustomobject]@{Domains=@($domains);AppliedDomains=$applied;NeedsPolicyUpdate=$different;NetworkChanged=$false;Message=$(if($different){'已保存名单用于新节点；现有线路需维护更新后应用。'}else{'已保存名单与当前节点配置一致。'})}
}
function Set-TCTradeDomainManagement {
    param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][ValidateSet('Add','Remove','Reset')][string]$Operation,[string]$Domain)
    $module=Import-Module (Join-Path $PSScriptRoot 'NodeStore.psm1') -PassThru -DisableNameChecking
    & $module {
        param($StoreRoot,$Action,$Value)
        $store=Initialize-TCStore -Root $StoreRoot;$lock=Open-TCLock $store.root
        try{
            $index=Read-TCIndex $store.root
            if($Action -eq 'Reset'){$next=@($script:TCDefaultDomains)}else{
                $text=([string]$Value).Trim().ToLowerInvariant() -replace '^https?://','';$text=($text -split '[/?#]',2)[0];$text=$text.TrimStart('*').TrimStart('.').TrimEnd('.')
                $normalized=ConvertTo-TCDomain $text
                $next=if($Action -eq 'Add'){@(@($index.tradeDomains)+$normalized|Select-Object -Unique)}else{@($index.tradeDomains|Where-Object {$_ -cne $normalized})}
            }
            $index.tradeDomains=@(ConvertTo-TCDomains $next);Write-TCAtomicJson $store.indexPath $index
        }finally{$lock.Dispose()}
    } (Join-Path $Root 'Product') $Operation $Domain
    Get-TCTradeDomainManagement -Root $Root
}
Export-ModuleMember -Function Get-TCTradeDomainManagement,Set-TCTradeDomainManagement
