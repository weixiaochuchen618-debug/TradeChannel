#requires -Version 5.1
<#
Bounded pipeline verification, including 0.14.3 negative controls. Every child
runs the owned ProbeWorkflowIntegration harness in a fresh PS5.1 process. No
controller, installed Worker, service, live network or SSH executor is invoked.
#>
[CmdletBinding()]
param([string]$PackageRoot='', [switch]$SummarizeExisting, [switch]$ReuseNegativeControl)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$ownPackage=Split-Path $PSScriptRoot -Parent
if(-not $PackageRoot){$PackageRoot=$ownPackage}
$PackageRoot=[IO.Path]::GetFullPath($PackageRoot)
$workspace=Split-Path (Split-Path $ownPackage -Parent) -Parent
$reports=Join-Path $workspace 'reports/release-0.15.0'
$null=[IO.Directory]::CreateDirectory($reports)
$harness=Join-Path $ownPackage 'deployment/tests/Test-ProbeWorkflowIntegration.ps1'
$legacy=Join-Path (Split-Path $ownPackage -Parent) '0.14.3'
$powershell=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
$specs=@(
    @{Name='CurrentJourney';Root=$PackageRoot;Mode='JourneyOnly';Report='probe-workflow-integration-journey';ExpectedExit=0},
    @{Name='BaselineContractAbsence';Root=$legacy;Mode='NegativeControl';Report='probe-workflow-integration-0143-contract-negative';ExpectedExit=0},
    @{Name='BaselineRejectsNewJourney';Root=$legacy;Mode='JourneyOnly';Report='probe-workflow-integration-0143-journey-negative';ExpectedExit=1}
)
$rows=New-Object 'Collections.Generic.List[object]'
$passed=$true
$currentHarnessSHA256=(Get-FileHash -LiteralPath $harness -Algorithm SHA256).Hash
foreach($spec in $specs){
    $path=Join-Path $reports ($spec.Report+'.json');$exitCode=$null
    $reused=($SummarizeExisting -or ($ReuseNegativeControl -and $spec.Name -ne 'CurrentJourney'))
    if(-not $reused){
        $arguments=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$harness,'-PackageRoot',$spec.Root,'-ReportName',$spec.Report,('-'+$spec.Mode))
        & $powershell @arguments 2>&1 | Out-File -LiteralPath (Join-Path $reports ($spec.Report+'-runner.log')) -Encoding UTF8
        $exitCode=$LASTEXITCODE
    }
    if(-not [IO.File]::Exists($path)){throw ('Missing concrete child report: '+$spec.Name)}
    $r=[IO.File]::ReadAllText($path)|ConvertFrom-Json
    if($reused){$exitCode=if($r.Passed){0}else{1}}
    $historical=($ReuseNegativeControl -and $spec.Name -ne 'CurrentJourney')
    # Reused legacy evidence keeps its original harness hash. Its backend source
    # hashes still must match; only current Journey must use this exact harness.
    $stable=($r.TestStable -and ($historical -or $r.TestSHA256 -ceq $currentHarnessSHA256) -and $r.SourcesStable)
    foreach($p in $r.SourceSHA256.PSObject.Properties){
        $source=Join-Path $spec.Root $p.Name
        if(-not [IO.File]::Exists($source) -or (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -cne $p.Value){$stable=$false}
    }
    $valid=($exitCode -eq $spec.ExpectedExit -and $r.FixtureRemoved -and $r.Safety.ForbiddenBoundaryCalls -eq 0 -and $stable)
    if($spec.Name -ceq 'BaselineContractAbsence'){
        $valid=($valid -and $r.Passed -and -not $r.JourneyContracts.AccessState -and -not $r.JourneyContracts.AutomaticSave -and -not $r.JourneyContracts.SavedDefaultProducer -and -not $r.JourneyContracts.SavedDefaultFromRealComparison -and $r.JourneyContracts.ComparisonActuallyRan)
    }elseif($spec.Name -ceq 'BaselineRejectsNewJourney'){
        $valid=($valid -and -not $r.Passed -and $r.Failure.Case -ceq 'ApprovedCreateManageCompare' -and $r.Failure.Message -match 'Auto' -and $r.Failure.ExceptionType -match 'ParameterBindingValidationException')
    }else{$valid=($valid -and $r.Passed -and @($r.BlockingFindings).Count -eq 0)}
    if(-not $valid){$passed=$false}
    $rows.Add([pscustomobject]@{Name=$spec.Name;Verified=$valid;Reused=$reused;HistoricalEvidence=$historical;EvidenceTestSHA256=$r.TestSHA256;CurrentInputSHA256=$currentHarnessSHA256;ExpectedExit=$spec.ExpectedExit;ActualExit=$exitCode;PassedCount=$r.PassedCount;SourcesStable=$stable;FixtureRemoved=$r.FixtureRemoved;ReportPath=$path;ReportSHA256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash;BlockingFindings=@($r.BlockingFindings);Failure=$r.Failure})
}
$result=[ordered]@{Kind='TradeChannel.JourneyIntegration';Passed=$passed;ExecutedAtUtc=[DateTimeOffset]::UtcNow.ToString('o');PowerShell=$PSVersionTable.PSVersion.ToString();SummarizeExisting=[bool]$SummarizeExisting;ReuseNegativeControl=[bool]$ReuseNegativeControl;InputSHA256=$currentHarnessSHA256;Cases=@($rows.ToArray());Scope='Actual deployment/access/identity/profile/comparison/saved-default/UI DTO policies; only fixture executor/OS/HTTP observations and engine lifecycle replaced. No live changes, build or install.'}
$report=Join-Path $reports 'journey-integration.json'
[IO.File]::WriteAllText($report,($result|ConvertTo-Json -Depth 30),(New-Object Text.UTF8Encoding($false)))
$lines=@(foreach($row in $rows){'{0}: Verified={1}; Exit={2}; Assertions={3}; SourcesStable={4}' -f $row.Name,$row.Verified,$row.ActualExit,$row.PassedCount,$row.SourcesStable})+@('RESULT Passed='+$passed)
[IO.File]::WriteAllLines((Join-Path $reports 'journey-integration.log'),$lines,(New-Object Text.UTF8Encoding($false)))
Write-Output ('Journey integration: Passed={0}; report={1}' -f $passed,$report)
if(-not $passed){exit 1}
