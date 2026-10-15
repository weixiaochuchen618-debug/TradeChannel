#requires -Version 5.1
[CmdletBinding()]param([string]$PackageRoot,[Parameter(Mandatory=$true)][string]$OldPackageRoot,[string]$ReportPath,[ValidateSet('Run','MakeLegacy')][string]$Mode='Run',[string]$FixtureRoot)
$ErrorActionPreference='Stop';$env:PSModulePath=Join-Path $PSHOME 'Modules'
if(-not $PackageRoot){$PackageRoot=Split-Path $PSScriptRoot -Parent}
if($Mode -eq 'MakeLegacy'){
 $owned=[IO.Path]::GetFullPath($FixtureRoot);$marker=Join-Path $owned '.owned-legacy-cleanup'
 if(-not $owned.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($owned) -cnotmatch '^tc-legacy-cleanup-[a-f0-9]{32}$' -or -not [IO.File]::Exists($marker) -or [IO.File]::ReadAllText($marker) -cne [IO.Path]::GetFileName($owned)){throw 'Old-code fixture ownership mismatch'}
 Import-Module (Join-Path $OldPackageRoot 'ServerRegistry.psm1') -DisableNameChecking
 $old=Import-Module (Join-Path $OldPackageRoot 'OperationHistory.psm1') -PassThru -DisableNameChecking
 $rollbackDefinition=& $old {(Get-Item Function:LCRollback).ScriptBlock.ToString()}
 $rows=@()
 foreach($name in @('unused-preview','preparing','committed')){
  $root=Join-Path $owned $name
  $server=Set-TCServerRecord -Root $root -Connection @{Host='192.0.2.123';Port=22;User='root';IdentityFile=''} -Name ('legacy '+$name)
  $registry=Join-Path $root 'servers\registry.json';$before=(Get-FileHash -LiteralPath $registry).Hash
  $preview=New-TCLocalDeploymentCleanupPreview -Root $root -Ids @('ServerRecord:'+$server.LocalRecordId)
  $errorCode=''
  if($name -eq 'preparing'){
   & $old {
    function script:LCMove {param($From,$To)[IO.File]::Move($From,$To);throw 'InjectedLegacyCrashAfterMove'}
    function script:LCRollback {param($Root,$Journal)throw 'InjectedLegacyProcessExitBeforeRollback'}
   }
   try{$null=Remove-TCLocalDeploymentData -Root $root -PreviewToken $preview.PreviewToken}catch{$errorCode=$_.Exception.Message}
   & $old {param($definition)function script:LCMove {param($From,$To)[IO.File]::Move($From,$To)};Set-Item Function:script:LCRollback ([scriptblock]::Create($definition))} $rollbackDefinition
  }elseif($name -eq 'committed'){
   & $old {function script:LCFinish {param($Root,$Journal)throw 'InjectedLegacyCrashAfterCommit'}}
   try{$null=Remove-TCLocalDeploymentData -Root $root -PreviewToken $preview.PreviewToken}catch{$errorCode=$_.Exception.Message}
  }
  $rows+=,[pscustomobject]@{Name=$name;Root=$root;RegistryPath=$registry;OriginalSHA256=$before;PreviewToken=$preview.PreviewToken;InjectedError=$errorCode;ServerId=$server.LocalRecordId}
 }
 [IO.File]::WriteAllText((Join-Path $owned 'legacy-inputs.json'),($rows|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($true)))
 exit 0
}
$owned=Join-Path ([IO.Path]::GetTempPath()) ('tc-legacy-cleanup-'+[guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($owned)
[IO.File]::WriteAllText((Join-Path $owned '.owned-legacy-cleanup'),[IO.Path]::GetFileName($owned))
$checks=New-Object 'Collections.Generic.List[string]';$failure=''
function Check {param([bool]$Ok,[string]$Message)if(-not $Ok){throw $Message};$checks.Add($Message)}
try{
 $ps51=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
 & $ps51 -NoProfile -STA -ExecutionPolicy Bypass -File $PSCommandPath -Mode MakeLegacy -OldPackageRoot $OldPackageRoot -FixtureRoot $owned
 if($LASTEXITCODE -ne 0){throw 'Actual old-code fixture construction failed'}
 $rows=[IO.File]::ReadAllText((Join-Path $owned 'legacy-inputs.json'))|ConvertFrom-Json
 Import-Module (Join-Path $PackageRoot 'ServerRegistry.psm1') -DisableNameChecking
 $current=Import-Module (Join-Path $PackageRoot 'OperationHistory.psm1') -PassThru -DisableNameChecking
 $unused=$rows[0];$rejected=$false
 try{$null=Remove-TCLocalDeploymentData -Root $unused.Root -PreviewToken $unused.PreviewToken}catch{$rejected=$_.Exception.Message -match 'CleanupPreviewInvalid'}
 Check ($rejected -and (Get-FileHash -LiteralPath $unused.RegistryPath).Hash -ceq $unused.OriginalSHA256) 'Uncommitted baseline preview is rejected before any files change; it needs a new scoped preview'
 $fresh=New-TCLocalDeploymentCleanupPreview -Root $unused.Root -Ids @('ServerRecord:'+$unused.ServerId)
 Check ($fresh.PlanVersion -eq 3 -and $fresh.Scope -ceq 'Server' -and $fresh.PreviewToken) 'Same retained old record obtains a fresh PlanVersion 3 scope-bound preview'
 $preparing=$rows[1];$pending=@(Get-TCLocalCleanupPending $preparing.Root)
 Check ($preparing.InjectedError -match 'CleanupRecoveryRequired' -and $pending.Count -eq 1) 'Actual baseline partially moved journal remains explicitly pending'
 $repaired=Repair-TCLocalDeploymentCleanup $preparing.Root
 Check ($repaired.RecoveredCount -eq 1 -and (Get-FileHash -LiteralPath $preparing.RegistryPath).Hash -ceq $preparing.OriginalSHA256 -and @(Get-TCLocalCleanupPending $preparing.Root).Count -eq 0) 'New package rolls back the actual old Preparing journal to byte-identical registry'
 Check ((Repair-TCLocalDeploymentCleanup $preparing.Root).RecoveredCount -eq 0) 'Old Preparing journal recovery is idempotent'
 $committed=$rows[2]
 Check (@(Get-TCLocalCleanupPending $committed.Root).Count -eq 1) 'Actual old committed-but-unpurged journal remains recoverable'
 $repaired=Repair-TCLocalDeploymentCleanup $committed.Root
 Check ($repaired.RecoveredCount -eq 1 -and $repaired.CompletedResults.Count -eq 1 -and $repaired.CompletedResults[0].DataDeleted -and @(Get-TCLocalCleanupPending $committed.Root).Count -eq 0) 'New package finishes actual old Committed journal without reviving its deleted record'
 $repeat=Remove-TCLocalDeploymentData -Root $committed.Root -PreviewToken $committed.PreviewToken
 Check ($repeat.AlreadyApplied -and $repeat.DataDeleted) 'Already committed old confirmation reconciles its own durable journal instead of re-expanding deletion'
}catch{$failure=$_.Exception.Message}
$result=[pscustomobject]@{Passed=(-not $failure);CheckCount=$checks.Count;Checks=$checks.ToArray();Failure=$failure;PackageRoot=$PackageRoot;OldPackageRoot=$OldPackageRoot;FixtureRoot=$owned;LegacyPlannerSHA256=(Get-FileHash -LiteralPath (Join-Path $OldPackageRoot 'LocalDeploymentCleanup.ps1')).Hash;NewPlannerSHA256=(Get-FileHash -LiteralPath (Join-Path $PackageRoot 'LocalDeploymentCleanup.ps1')).Hash;Scope='Actual old module creates tokens/journals in bounded synthetic roots; new package recovers them; no remote actors'}
if($ReportPath){[IO.File]::WriteAllText($ReportPath,($result|ConvertTo-Json -Depth 7),(New-Object Text.UTF8Encoding($true)))}
if(-not $failure -and [IO.Path]::GetFullPath($owned).StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($owned) -cmatch '^tc-legacy-cleanup-[a-f0-9]{32}$'){Remove-Item -LiteralPath $owned -Recurse -Force}
$result|ConvertTo-Json -Depth 7
if($failure){exit 1}
