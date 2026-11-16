#requires -Version 5.1
# 0.21.4 field case: a second PC kept deployment.json from an earlier setup whose
# manifest no longer exists. Every status read threw in the trading-program check
# and the whole UI showed 无法读取. Reads must now return; connection gates must
# still refuse. Temporary data root only; reads the local process list, nothing else.
[CmdletBinding()]param([string]$PackageRoot='')
$ErrorActionPreference='Stop'
if(-not $PackageRoot){$PackageRoot=Split-Path $PSScriptRoot -Parent}
$PackageRoot=[IO.Path]::GetFullPath($PackageRoot)
$checks=New-Object 'Collections.Generic.List[string]'
function Check {param([bool]$Condition,[string]$Name)if(-not $Condition){throw ('FAILED: '+$Name)};$checks.Add($Name)}
$root=Join-Path ([IO.Path]::GetTempPath()) ('tc-stale-deployment-'+[guid]::NewGuid().ToString('N'))
$utf8=New-Object Text.UTF8Encoding($true)
try{
    $null=New-Item -ItemType Directory -Force -Path (Join-Path $root 'Product')
    $gone=Join-Path $root 'Product\nodes\removed-line\manifest.json'
    [IO.File]::WriteAllText((Join-Path $root 'deployment.json'),(@{ManifestPath=$gone;Stage='Applied'}|ConvertTo-Json),$utf8)
    [IO.File]::WriteAllText((Join-Path $root 'Product\index.json'),(@{nodes=@(@{id='a';name='Old line A';manifestPath=$gone},@{id='b';name='Old line B';manifestPath=(Join-Path $root 'Product\nodes\other\manifest.json')})}|ConvertTo-Json -Depth 4),$utf8)

    . (Join-Path $PackageRoot 'runtime\TradeChannel.TradeApps.ps1')
    $gate='allowed';try{$null=Test-TCTradeApplicationsRunning -Root $root}catch{$gate=$_.Exception.Message}
    Check ($gate -like '*当前线路配置丢失*') 'The connection gate still refuses when the current deployment manifest is gone'

    $record=Join-Path $root 'trade-programs.json'
    $write={param($programs)[IO.File]::WriteAllText($record,([ordered]@{SchemaVersion=1;Owner='TradeChannel.TradeApps';Revision=1;Programs=@($programs);UpdatedAtUtc=[DateTimeOffset]::UtcNow.ToString('o')}|ConvertTo-Json),$utf8)}
    & $write @('C:\TradeChannelFixture\NotRunning\trader-fixture.exe')
    Check ((Test-TCTradeApplicationsRunning -Root $root -WithoutDeployment) -eq $false) 'A status read checks the saved program list without the missing manifest'
    $self=[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    & $write @($self)
    Check ((Test-TCTradeApplicationsRunning -Root $root -WithoutDeployment) -eq $true) 'A listed program that is running is still reported as running'
    Remove-Item -LiteralPath $record -Force

    Import-Module (Join-Path $PackageRoot 'RuntimeBridge.psm1') -Force -DisableNameChecking
    $bridge=Get-Module RuntimeBridge
    & $bridge {param($r)$script:Root=$r} $root
    $threw=$false;try{$null=& $bridge {Test-TCNinjaRunning}}catch{$threw=$true}
    Check $threw 'The gate form inside the runtime bridge still throws'
    $read=& $bridge {Test-TCNinjaRunningForRead}
    Check ($read -is [bool]) 'The read form answers with a boolean'
    $overview=Get-TCOverview
    Check ($overview.StateKey -ceq 'Fault' -and [string]$overview.Error -like '*无法核实部署*' -and $overview.NinjaRunning -is [bool]) 'The status read of this data returns a readable fault (连接需要处理) instead of failing'
    [pscustomobject]@{Passed=$true;Checks=$checks.Count;Assertions=$checks.ToArray();StateKey=$overview.StateKey;NetworkChanged=$false}|ConvertTo-Json
}finally{
    $full=[IO.Path]::GetFullPath($root);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if($full.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($full) -like 'tc-stale-deployment-*' -and (Test-Path -LiteralPath $full)){Remove-Item -LiteralPath $full -Recurse -Force}
}
