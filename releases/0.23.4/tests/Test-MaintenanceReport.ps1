#requires -Version 5.1
# Mock OS/runtime observations, isolated export destinations only.
[CmdletBinding()]param()
$ErrorActionPreference='Stop';Set-StrictMode -Version 2
$package=Split-Path $PSScriptRoot -Parent
$module=Import-Module (Join-Path $package 'Maintenance.psm1') -Force -PassThru -DisableNameChecking
$work=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('TC-MaintenanceReport-'+[guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($work);$script:Checks=0
function Check {param([bool]$Ok,[string]$Label)if(-not $Ok){throw ('Maintenance report regression: '+$Label)};$script:Checks++}
function Reject {param([scriptblock]$Body,[string]$Label)$caught=$false;try{$null=& $Body}catch{$caught=$true};Check $caught $Label}
try{
    & $module {
        function script:Invoke-TCMaintenanceContext {
            param($Root,$Action,$Arguments)
            [pscustomobject]@{State='Connected';Running=$true;CanConnect=$false;ManifestPath='fixture-path';GuardState='Protected';Error=$null;Preferences=[pscustomobject]@{NodeId='fixture';Daily='Provider';ProviderId='fixture';TradeProviderId='fixture'};Overview=[pscustomobject]@{StateKey='Connected';Running=$true;Exit='hk';Daily='provider2';Connections=18;GuardState='Protected';GuardSummary='fixture verified protection'};NetworkChanged=$false}
        }
        function script:Get-NetAdapter {[pscustomobject]@{Name='fixture adapter';InterfaceDescription='inert';Status='Up'}}
        function script:Get-NetRoute {param($DestinationPrefix)[pscustomobject]@{InterfaceIndex=42;NextHop='192.0.2.1';RouteMetric=20}}
        function script:Invoke-TCSession {throw 'Runtime mutation forbidden.'}
    }
    $json=Join-Path $work 'diagnostic.json';$result=Export-TCClientDiagnostics -Root $work -Destination $json
    Check ($result.Exported -and -not $result.NetworkChanged -and [IO.File]::Exists($result.SummaryPath)) 'export emits structured diagnostics and readable summary'
    $report=[IO.File]::ReadAllText($json)|ConvertFrom-Json;Check ($report.Version -eq ([IO.File]::ReadAllText((Join-Path $package 'version.json'))|ConvertFrom-Json).Version -and $report.Runtime.Current.TradeExit.Source -eq 'ControllerSelector') 'report uses package version and explicit source labels'
    Check ([IO.File]::ReadAllText($result.SummaryPath).Contains('18') -and [IO.File]::ReadAllText($result.SummaryPath).Contains('未等同公网出口验证')) 'summary readable and avoids unsupported public-exit claim'
    $before=(Get-FileHash -LiteralPath $json).Hash;Reject {Export-TCClientDiagnostics -Root $work -Destination $json} 'existing diagnostics are not overwritten';Check ((Get-FileHash -LiteralPath $json).Hash -eq $before) 'existing report preserved'
    $textPath=Join-Path $work 'chosen.txt';$textResult=Export-TCClientDiagnostics -Root $work -Destination $textPath;Check ($textResult.Path -ne $textResult.SummaryPath -and ([IO.File]::ReadAllText($textPath)|ConvertFrom-Json).Version -eq ([IO.File]::ReadAllText((Join-Path $package 'version.json'))|ConvertFrom-Json).Version) 'text destination cannot overwrite its own JSON with summary'
    [pscustomobject]@{Passed=$true;Checks=$script:Checks;RealNetworkChanges=0;RuntimeMutations=0;VersionAuthority=$true}
}finally{
    $full=[IO.Path]::GetFullPath($work);$parent=[IO.Path]::GetFullPath([Environment]::GetFolderPath('LocalApplicationData')).TrimEnd('\')+'\'
    if(-not $full.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notmatch '^TC-MaintenanceReport-[0-9a-f]{32}$'){throw 'Cleanup rejected.'};Remove-Item -LiteralPath $full -Recurse -Force
}
