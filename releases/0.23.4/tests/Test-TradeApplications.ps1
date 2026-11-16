#requires -Version 5.1
[CmdletBinding()]param([string]$ReportDirectory='')
$ErrorActionPreference='Stop'
$package=Split-Path $PSScriptRoot -Parent
$work=Join-Path ([IO.Path]::GetTempPath()) ('TradeChannel-apps-fixture-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($work);$checks=New-Object 'Collections.Generic.List[string]'
function Check {param($Condition,[string]$Name)if(-not $Condition){throw $Name};$checks.Add($Name)}
function Reject {param([scriptblock]$Action,[string]$Name)$failed=$false;try{$null=& $Action}catch{$failed=$true};Check $failed $Name}
try{
    $module=Import-Module (Join-Path $package 'TradeApplications.psm1') -Force -PassThru -DisableNameChecking
    & $module {function script:Get-TCDetectedTradePrograms {@()};$script:FixtureProcesses=@();function script:Get-TCTradeAppProcesses {param($Names)@($script:FixtureProcesses)}}
    $node=Import-Module (Join-Path $package 'NodeStore.psm1') -PassThru -DisableNameChecking
    $first=Join-Path $work 'terminal64.exe';$second=Join-Path $work 'tws.exe';[IO.File]::WriteAllText($first,'inert');[IO.File]::WriteAllText($second,'inert')
    $view=Get-TCTradeApplicationManagement $work
    Check ($view.Revision -eq 0 -and $view.Programs.Count -eq 0 -and -not $view.HasLine) 'Fresh installation reads without changing defaults or runtime'
    $view=Set-TCTradeApplicationManagement -Root $work -Operation Add -Program $first -Revision 0
    Check ($view.Revision -eq 1 -and $view.Programs[0].Path -eq $first -and -not $view.NetworkChanged) 'Custom trading program persists without a network change'
    Check (@(Get-TCConfiguredTradePrograms $work)[0] -eq $first) 'Deployment inspection reads the saved custom program'
    Reject {Set-TCTradeApplicationManagement -Root $work -Operation Add -Program $second -Revision 0} 'Stale editor cannot overwrite a newer list'
    Reject {Set-TCTradeApplicationManagement -Root $work -Operation Add -Program 'C:\missing\terminal.exe' -Revision 1} 'Missing program cannot be added'
    Reject {Set-TCTradeApplicationManagement -Root $work -Operation Add -Program $first.Replace('.exe','.txt') -Revision 1} 'Non-executable path is rejected'
    Reject {Set-TCTradeApplicationManagement -Root $work -Operation Add -Program ($first+':stream') -Revision 1} 'Alternate data streams are rejected'
    $view=Set-TCTradeApplicationManagement -Root $work -Operation Add -Program $second -Revision 1
    Check ($view.Programs.Count -eq 2 -and $view.HasUndo) 'A second program is saved with an undo point'
    $view=Set-TCTradeApplicationManagement -Root $work -Operation Undo -Revision 2
    Check ($view.Programs.Count -eq 1 -and $view.Programs[0].Path -eq $first -and $view.Revision -eq 3) 'Undo restores the preceding list with a new revision'
    $manifest=Join-Path $work 'manifest.json'
    & $node {param($r,$m,$p)Write-TCAtomicJson $m @{TradeProgramPaths=@($p);TradeDomainSuffixes=@($script:TCDefaultDomains);CandidatePath=(Join-Path $r 'config.json');CandidateSHA256=('a'*64)};Write-TCAtomicJson (Join-Path $r 'deployment.json') @{ManifestPath=$m}} $work $manifest $first
    $view=Get-TCTradeApplicationManagement $work
    Check (-not $view.NeedsPolicyUpdate -and $view.Programs[0].Applied) 'Applied list is distinguished from saved intent'
    & $module {param($p)$script:FixtureProcesses=@([pscustomobject]@{Path=$p})} $first
    Check (Test-TCTradeApplicationsRunning -Root $work) 'Preflight waits for a custom trading program'
    & $module {$script:FixtureProcesses=@([pscustomobject]@{Path='C:\another\terminal64.exe'})}
    Check (-not (Test-TCTradeApplicationsRunning -Root $work)) 'Same process name at another known path does not block'
    & $module {$script:FixtureProcesses=@([pscustomobject]@{Path=$null})}
    Check (Test-TCTradeApplicationsRunning -Root $work) 'Uninspectable matching process is never assumed stopped'
    $oldToken=$view.SnapshotToken
    $view=Set-TCTradeApplicationManagement -Root $work -Operation Remove -Program $first -Revision 3
    Check ($view.NeedsPolicyUpdate -and $view.Programs.Count -eq 0 -and $view.AppliedPrograms.Count -eq 1) 'Removing a program leaves current protection explicitly pending'
    Check (Test-TCTradeApplicationsRunning -Root $work) 'Removed but still-applied program continues to block restart'
    Reject {Invoke-TCTradeApplicationApply -Root $work -SnapshotToken $oldToken} 'Changed intent invalidates the confirmation snapshot'
    [IO.File]::Delete($first)
    $view=Set-TCTradeApplicationManagement -Root $work -Operation Undo -Revision 4
    Check ($view.Programs[0].Missing) 'Missing old paths remain visible and removable'
    $savedPath=Join-Path $work 'trade-programs.json';$saved=[IO.File]::ReadAllText($savedPath)
    [IO.File]::WriteAllText($savedPath,'{"SchemaVersion":2}')
    Reject {Get-TCTradeApplicationManagement $work} 'Corrupt list fails visibly instead of silently dropping protection'
    [IO.File]::WriteAllText($savedPath,$saved,(New-Object Text.UTF8Encoding($true)))
    # A registered proxy client must not block editing the list. Regression: the
    # stored archive was re-fed as if it were ConvertTo-TCPolicyProviders output,
    # so every program and domain edit was refused before it could be saved.
    # The temp fixture cannot pass the real "no temp/shared directory" policy, which
    # is unrelated to the archive shape this case verifies; keep it inside the module.
    & $node {function script:Resolve-TCProviderDirectory {param($Path,[switch]$AllowMissing)$full=[IO.Path]::GetFullPath([string]$Path);if(-not $AllowMissing -and -not [IO.Directory]::Exists($full)){Stop-TCError '服务商目录不存在。'};$full}}
    $providerRoot=Join-Path $work 'provider-case';$providerDir=Join-Path $providerRoot 'client'
    $null=[IO.Directory]::CreateDirectory($providerDir);$null=[IO.Directory]::CreateDirectory((Join-Path $providerRoot 'Product'))
    $providerExe=Join-Path $providerDir 'client.exe';[IO.File]::WriteAllText($providerExe,'inert')
    $providerProgram=Join-Path $providerRoot 'terminal64.exe';[IO.File]::WriteAllText($providerProgram,'inert')
    & $node {param($r,$d,$p)Write-TCAtomicJson (Join-Path $r 'Product\providers.json') ([ordered]@{Version=1;Providers=@([ordered]@{id=[guid]::NewGuid().ToString('D');slot=2;kind='custom';name='Fixture Provider';directory=$d;extraDirectories=@();programPaths=@($p);dailyPort=17892;httpPort=17893;pacPort=17894;bootstrapDomains=@('example.com')})})} $providerRoot $providerDir $providerExe
    $providerView=Set-TCTradeApplicationManagement -Root $providerRoot -Operation Add -Program $providerProgram -Revision 0
    Check ($providerView.Programs.Count -eq 1 -and $providerView.Programs[0].Path -eq $providerProgram) 'A registered proxy provider does not block saving a trading program'
    $providerView=Set-TCTradeApplicationManagement -Root $providerRoot -Operation Remove -Program $providerProgram -Revision 1
    Check ($providerView.Programs.Count -eq 0) 'A registered proxy provider does not block removing a trading program'
    $compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    & $compiler /nologo /target:library ('/out:'+(Join-Path $work 'Guard.dll')) (Join-Path $package 'runtime\TradeChannelGuard.cs')
    Check ($LASTEXITCODE -eq 0) 'Protection helper compiles against .NET Framework without touching WFP'
    Import-Module (Join-Path $package 'WorkerContracts.psm1') -Force -DisableNameChecking
    Assert-TCWorkerRequestPreflight @{Action='TradeApplicationEdit';Kind='Program';Operation='Add';Value=$second;Revision=1}
    Check ((Get-TCWorkerActionContract 'TradeApplications').ReadOnly) 'List reads have a bounded read-only worker contract'
    Reject {Assert-TCWorkerRequestPreflight @{Action='TradeApplicationEdit';Kind='Program';Operation='Reset';Value='';Revision=1}} 'Unsupported program operations are rejected before dispatch'
    Reject {Assert-TCWorkerRequestPreflight @{Action='TradeApplicationApply';SnapshotToken=('a'*64);Path='C:\unexpected'}} 'Apply cannot carry arbitrary extra instructions'
    $result=[pscustomobject]@{Passed=$true;Checks=$checks.Count;Details=@($checks);RealNetworkChanges=0;WfpMutations=0}
    if($ReportDirectory){$null=[IO.Directory]::CreateDirectory($ReportDirectory);[IO.File]::WriteAllText((Join-Path $ReportDirectory 'trade-applications.json'),($result|ConvertTo-Json -Depth 6),(New-Object Text.UTF8Encoding($true)))}
    $result|Select-Object Passed,Checks,RealNetworkChanges,WfpMutations
}finally{
    Remove-Module TradeApplications -ErrorAction SilentlyContinue
    $full=[IO.Path]::GetFullPath($work);$prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -cnotmatch '^TradeChannel-apps-fixture-[a-f0-9]{32}$'){throw 'Unsafe cleanup path'}
    Remove-Item -LiteralPath $full -Recurse -Force
}
