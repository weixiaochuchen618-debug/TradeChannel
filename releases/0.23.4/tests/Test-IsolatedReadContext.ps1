#requires -Version 5.1
[CmdletBinding()]param()
$ErrorActionPreference='Stop';Set-StrictMode -Version 2
$package=Split-Path $PSScriptRoot -Parent;$module=Import-Module (Join-Path $package 'RuntimeBridge.psm1') -Force -PassThru -DisableNameChecking
$work=Join-Path ([IO.Path]::GetTempPath()) ('TradeChannel-worker-fixture-'+[guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($work);$script:Checks=0
function Check {param([bool]$Ok,[string]$Label)if(-not $Ok){throw ('Isolated read context regression: '+$Label)};$script:Checks++}
function Reject {param([scriptblock]$Body,[string]$Label)$caught=$false;try{$null=& $Body}catch{$caught=$true};Check $caught $Label}
try{
    Reject {Initialize-TCIsolatedReadContext -Root (Join-Path ([IO.Path]::GetTempPath()) 'wrong-marker')} 'untrusted marker cannot enable fixture context'
    $initialized=Initialize-TCIsolatedReadContext -Root $work;Check ($initialized.Initialized -and -not $initialized.ControllerAllowed -and (Get-TCProductPaths).Root -eq $work) 'initializer binds module to a verified temporary root'
    & $module {
        function script:Get-CimInstance {throw 'Fixture must not read OS process inventory.'}
        function script:Get-Process {throw 'Fixture must not read actual trading processes.'}
        function script:Get-NetAdapter {throw 'Fixture must not read actual adapters.'}
        function script:Find-TCProviderCandidates {throw 'Fixture must not scan actual provider profiles.'}
    }
    $overview=Get-TCOverview;Check ($overview.StateKey -eq 'Unconfigured' -and -not $overview.NinjaRunning -and -not $overview.SessionPresent -and $overview.GuardState -eq 'Unknown') 'actual overview pipeline uses synthetic process/guard evidence only'
    $inspection=Get-TCClientInspection;Check ($inspection.EvidenceSource -eq 'IsolatedFixture' -and $inspection.DirectDnsIPv4[0] -eq '192.0.2.53' -and $inspection.ProviderCandidates.Count -eq 0) 'client inspection uses explicit fixture facts without real profiles/adapters'
    Reject {& $module {Invoke-TCController ([pscustomobject]@{CandidatePath='not-read'}) '/configs'}} 'controller fails before candidate or endpoint is read'
    foreach($operation in @('Connect','Disconnect')){Reject {Invoke-TCSession -Action $operation} ('isolated session '+$operation+' refused')}
    Reject {Remove-TCClientProtection} 'isolated protection mutation refused'
    Reject {Update-TCActivePolicy} 'isolated maintenance mutation refused'
    Reject {Enable-TCNode -ManifestPath 'not-read'} 'isolated activation refused before file access'
    Reject {& $module {param($p)Assert-TCIsolatedReadPath $p} (Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'TradeChannel\runtime.json')} 'fixture cannot dereference a production data path'
    Check (-not [IO.File]::Exists((Join-Path $work '.session.lock'))) 'blocked operations create no session lock or runtime request'
    [pscustomobject]@{Passed=$true;Checks=$script:Checks;RealNetworkChanges=0;ProductionMetadataReads=0;ControllerRequests=0;SyntheticEvidenceOnly=$true}
}finally{
    $full=[IO.Path]::GetFullPath($work);$prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not ($full+'\').StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notmatch '^TradeChannel-worker-fixture-[a-f0-9]{32}$'){throw 'Cleanup rejected.'};Remove-Item -LiteralPath $full -Recurse -Force
}
