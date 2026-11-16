#requires -Version 5.1
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'runtime\TradeChannel.TradeApps.ps1')
function Get-TCTradeApplicationToken {
    param([string[]]$Programs,[string[]]$Domains,$Manifest)
    $text=(@($Programs|ForEach-Object {$_.ToLowerInvariant()}|Sort-Object)-join "`n")+'|'+(@($Domains|Sort-Object)-join "`n")+'|'+[string]$Manifest.CandidatePath+'|'+[string]$Manifest.CandidateSHA256
    $hash=[Security.Cryptography.SHA256]::Create()
    try{([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))).Replace('-','').ToLowerInvariant()}finally{$hash.Dispose()}
}
function Get-TCTradeApplicationManagement {
    param([Parameter(Mandatory=$true)][string]$Root)
    $record=Read-TCTradeAppRecord $Root;$programs=@(Get-TCConfiguredTradePrograms $Root);$manifest=Get-TCTradeAppManifest $Root
    Import-Module (Join-Path $PSScriptRoot 'ManagementStore.psm1') -DisableNameChecking
    $domains=Get-TCTradeDomainManagement $Root
    $applied=@($manifest.TradeProgramPaths|Where-Object {$_})
    $different=(@($programs|Sort-Object)-join '|') -ine (@($applied|Sort-Object)-join '|')
    [pscustomobject]@{Revision=$(if($record){$record.Revision}else{0});SnapshotToken=(Get-TCTradeApplicationToken $programs @($domains.Domains) $manifest);Programs=@(foreach($path in $programs){[pscustomobject]@{Path=$path;Name=[IO.Path]::GetFileName($path);Missing=(-not [IO.File]::Exists($path));Applied=($applied -icontains $path)}});AppliedPrograms=$applied;Domains=@($domains.Domains);AppliedDomains=@($domains.AppliedDomains);HasLine=[bool]$manifest;NeedsPolicyUpdate=([bool]$manifest -and ($different -or $domains.NeedsPolicyUpdate));HasUndo=[IO.File]::Exists((Join-Path $Root 'trade-programs.previous.json'));NetworkChanged=$false;Message=$(if($manifest -and ($different -or $domains.NeedsPolicyUpdate)){'名单已保存，应用到当前线路后生效。'}elseif(-not $manifest){'添加线路时会自动使用这份名单。'}else{'名单已在当前线路生效。'})}
}
function Set-TCTradeApplicationManagement {
    param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][ValidateSet('Add','Remove','Undo')][string]$Operation,[string]$Program,[Parameter(Mandatory=$true)][int]$Revision)
    $rootPath=Assert-TCTradeAppPath $Root
    $nodeModule=Import-Module (Join-Path $PSScriptRoot 'NodeStore.psm1') -PassThru -DisableNameChecking
    $null=& $nodeModule {param($p)New-TCPrivateDirectory $p} $rootPath
    $lockPath=Assert-TCTradeAppPath (Join-Path $rootPath '.trade-apps.lock')
    try{$lock=[IO.File]::Open($lockPath,'OpenOrCreate','ReadWrite','None')}catch{throw '名单正在保存，请稍后重试。'}
    try{
        $record=Read-TCTradeAppRecord $rootPath;$currentRevision=if($record){$record.Revision}else{0}
        if($Revision -ne $currentRevision){throw '名单已在其他页面更新，请刷新后重试。'}
        $current=@(Get-TCConfiguredTradePrograms $rootPath)
        if($Operation -eq 'Undo'){
            $previous=Read-TCTradeAppJson (Join-Path $rootPath 'trade-programs.previous.json')
            if(-not $previous -or $previous.Owner -cne 'TradeChannel.TradeApps' -or $previous.SchemaVersion -ne 1 -or $previous.Programs -isnot [array]){throw '没有可恢复的上一份名单。'}
            $next=@(ConvertTo-TCTradeAppPrograms @($previous.Programs))
        }else{
            $path=Assert-TCTradeAppPath $Program -Executable -MustExist:($Operation -eq 'Add')
            $next=if($Operation -eq 'Add'){@($current+$path|Select-Object -Unique)}else{@($current|Where-Object {$_ -ine $path})}
            $next=@(ConvertTo-TCTradeAppPrograms $next)
        }
        # A proxy client must retain its independent direct bootstrap path.
        # The stored archive is the only input ConvertTo-TCPolicyProviders accepts;
        # Read-TCStoredProviders returns an outbound view unless -Raw is requested.
        try{& $nodeModule {param($r,$p)$providers=Read-TCStoredProviders (Join-Path $r 'Product') -Raw;$null=ConvertTo-TCPolicyProviders -Providers $providers -TradePrograms $p -AllowMissingPrograms} $rootPath $next}
        catch{
            # This cross-check runs before either atomic save, so a refusal here
            # leaves the saved list untouched and must not read as an unknown outcome.
            $refusal=$_.Exception;while($refusal.InnerException){$refusal=$refusal.InnerException}
            if($refusal.Data -is [Collections.IDictionary]){$refusal.Data['TCCommitted']=$false}
            throw
        }
        $prior=[ordered]@{SchemaVersion=1;Owner='TradeChannel.TradeApps';Revision=[Math]::Max(1,$currentRevision);Programs=@($current);UpdatedAtUtc=[DateTimeOffset]::UtcNow.ToString('o')}
        $saved=[ordered]@{SchemaVersion=1;Owner='TradeChannel.TradeApps';Revision=($currentRevision+1);Programs=@($next);UpdatedAtUtc=[DateTimeOffset]::UtcNow.ToString('o')}
        & $nodeModule {param($r,$p,$v)Write-TCAtomicJson (Join-Path $r 'trade-programs.previous.json') $p;Write-TCAtomicJson (Join-Path $r 'trade-programs.json') $v} $rootPath $prior $saved
    }finally{$lock.Dispose()}
    Get-TCTradeApplicationManagement $rootPath
}
function Invoke-TCTradeApplicationApply {
    param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][string]$SnapshotToken)
    $view=Get-TCTradeApplicationManagement $Root
    if($SnapshotToken -cnotmatch '^[a-f0-9]{64}$' -or $view.SnapshotToken -cne $SnapshotToken){throw '名单或当前线路已变化，请重新检查后应用。'}
    if(-not $view.HasLine){throw '请先添加一条线路。'}
    if(-not $view.NeedsPolicyUpdate){return $view}
    Import-Module (Join-Path $PSScriptRoot 'RuntimeBridge.psm1') -DisableNameChecking
    $paths=Get-TCProductPaths
    if([IO.Path]::GetFullPath($paths.Root).TrimEnd('\') -ine [IO.Path]::GetFullPath($Root).TrimEnd('\')){throw '应用名单只接受当前产品数据目录。'}
    $null=Update-TCActivePolicy
    $result=Get-TCTradeApplicationManagement $Root
    if($result.NeedsPolicyUpdate){throw '配置已更新，但名单尚未完全一致，请查看当前线路状态。'}
    $result.NetworkChanged=$true;$result
}
Export-ModuleMember -Function Get-TCTradeApplicationManagement,Set-TCTradeApplicationManagement,Invoke-TCTradeApplicationApply,Get-TCConfiguredTradePrograms,Test-TCTradeApplicationsRunning
