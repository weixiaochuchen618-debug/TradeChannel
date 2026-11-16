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
 foreach($name in @('unused-preview','preparing','committed','stale-preview')){
  $root=Join-Path $owned $name
  $server=Set-TCServerRecord -Root $root -Connection @{Host='192.0.2.123';Port=22;User='root';IdentityFile=''} -Name ('legacy '+$name)
  $registry=Join-Path $root 'servers\registry.json';$before=(Get-FileHash -LiteralPath $registry).Hash
  $preview=New-TCLocalDeploymentCleanupPreview -Root $root -Ids @('ServerRecord:'+$server.LocalRecordId)
  $files=@($preview.Files|ForEach-Object {[pscustomobject]@{Path=$_.Path;SHA256=(Get-FileHash -LiteralPath (Join-Path $root $_.Path)).Hash}})
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
  }elseif($name -eq 'stale-preview'){$null=Set-TCServerRecord -Root $root -Id $server.LocalRecordId -Name 'Changed after original preview'}
  $version=if($preview.PSObject.Properties['PlanVersion']){[int]$preview.PlanVersion}else{0}
  $scope=if($preview.PSObject.Properties['Scope']){[string]$preview.Scope}else{''}
  $rows+=,[pscustomobject]@{Name=$name;Root=$root;RegistryPath=$registry;OriginalSHA256=$before;ConfirmationSHA256=$(if($name -eq 'stale-preview'){(Get-FileHash -LiteralPath $registry).Hash}else{$before});PreviewToken=$preview.PreviewToken;PlanVersion=$version;Scope=$scope;Files=$files;InjectedError=$errorCode;ServerId=$server.LocalRecordId}
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
 $unused=$rows[0];$previewError='';$previewDisposition=''
 $fresh=New-TCLocalDeploymentCleanupPreview -Root $unused.Root -Ids @('ServerRecord:'+$unused.ServerId)
 Check ($fresh.PlanVersion -eq 3 -and $fresh.Scope -ceq 'Server' -and $fresh.PreviewToken -and (Get-FileHash -LiteralPath $unused.RegistryPath).Hash -ceq $unused.OriginalSHA256) 'Reading the old record produces a fresh scoped preview without changing registry bytes'
 $matchingPlan=& $current {param($Root,$OldToken,$FreshToken)$a=LCToken -Root $Root -Token $OldToken;$b=LCToken -Root $Root -Token $FreshToken;return ($a.Digest -ceq $b.Digest)} $unused.Root $unused.PreviewToken $fresh.PreviewToken
 # A v3 token from 0.16.17 remains valid when its exact scope and digest match.
 # Its age/version alone is not a reason to change the approved deletion set.
 if($unused.PlanVersion -eq 3 -and $unused.Scope -ceq 'Server' -and $matchingPlan){
  $finish=& $current {(Get-Item Function:LCFinish).ScriptBlock}
  & $current {param($Finish)$script:LegacyTestFinish=$Finish;$script:LegacyTestItems=@();function script:LCFinish {param($Root,$Journal)$script:LegacyTestItems=@($Journal.Items);& $script:LegacyTestFinish $Root $Journal}} $finish
  try{$applied=Remove-TCLocalDeploymentData -Root $unused.Root -PreviewToken $unused.PreviewToken}finally{& $current {param($Finish)Set-Item Function:script:LCFinish $Finish} $finish}
  $appliedItems=@(& $current {$script:LegacyTestItems});$previewDisposition='AppliedExactPlan'
  Check ($applied.DataDeleted -and -not $applied.AlreadyApplied -and $applied.ServerCount -eq 1 -and $applied.OperationCount -eq 0 -and $applied.LineCount -eq 0 -and ($applied.SelectedIds -join ',') -ceq ('ServerRecord:'+$unused.ServerId)) 'Matching baseline v3 token applies only its exact original server scope'
  $journals=@(Get-ChildItem -LiteralPath (Join-Path $unused.Root 'local-cleanup') -Filter journal.json -Recurse)
  Check ($journals.Count -eq 1) 'Compatible old confirmation creates one durable cleanup journal'
  $journal=[IO.File]::ReadAllText($journals[0].FullName)|ConvertFrom-Json
  $expectedPaths=@($unused.Files.Path|Sort-Object);$actualPaths=@($appliedItems|ForEach-Object {$_.Path.Substring($unused.Root.Length+1)}|Sort-Object)
  $hashesMatch=@($appliedItems|Where-Object {$item=$_;$relative=$item.Path.Substring($unused.Root.Length+1);@($unused.Files|Where-Object {$_.Path -ceq $relative -and $_.SHA256 -ceq $item.Hash}).Count -ne 1}).Count -eq 0
  $registry=[IO.File]::ReadAllText($unused.RegistryPath)|ConvertFrom-Json
  Check ($journal.Status -ceq 'Completed' -and ($actualPaths -join '|') -ceq ($expectedPaths -join '|') -and $hashesMatch -and @($registry.Servers).Count -eq 0) 'Compatible token deletes only the originally hashed files and records completion without expanding scope'
  $journalHash=(Get-FileHash -LiteralPath $journals[0].FullName).Hash;$repeat=Remove-TCLocalDeploymentData -Root $unused.Root -PreviewToken $unused.PreviewToken
  Check ($repeat.AlreadyApplied -and $repeat.DataDeleted -and (Get-FileHash -LiteralPath $journals[0].FullName).Hash -ceq $journalHash) 'Repeating a compatible old confirmation returns its byte-identical receipt'
 }else{
  $expectedPreviewError=if($unused.PlanVersion -eq 3 -and $unused.Scope -ceq 'Server'){'CleanupPreviewStale'}else{'CleanupPreviewInvalid'}
  try{$null=Remove-TCLocalDeploymentData -Root $unused.Root -PreviewToken $unused.PreviewToken}catch{if($_.Exception.Message -match '^\[TC:(Cleanup[A-Za-z]+)\]'){$previewError=$matches[1]}}
  Check ($previewError -ceq $expectedPreviewError) ('Incompatible baseline token is rejected with exact '+$expectedPreviewError)
  Check ((Get-FileHash -LiteralPath $unused.RegistryPath).Hash -ceq $unused.OriginalSHA256 -and @(Get-ChildItem -LiteralPath (Join-Path $unused.Root 'local-cleanup') -Filter journal.json -Recurse -ErrorAction SilentlyContinue).Count -eq 0) 'Rejected baseline preview preserves registry bytes and creates no cleanup journal'
  $previewDisposition='RejectedIncompatiblePlan'
 }
 $stale=$rows[3];$staleCode=''
 try{$null=Remove-TCLocalDeploymentData -Root $stale.Root -PreviewToken $stale.PreviewToken}catch{if($_.Exception.Message -match '^\[TC:(Cleanup[A-Za-z]+)\]'){$staleCode=$matches[1]}}
 $expectedStaleCode=if($stale.PlanVersion -eq 3 -and $stale.Scope -ceq 'Server'){'CleanupPreviewStale'}else{'CleanupPreviewInvalid'}
 Check ($staleCode -ceq $expectedStaleCode -and (Get-FileHash -LiteralPath $stale.RegistryPath).Hash -ceq $stale.ConfirmationSHA256 -and @(Get-ChildItem -LiteralPath (Join-Path $stale.Root 'local-cleanup') -Filter journal.json -Recurse -ErrorAction SilentlyContinue).Count -eq 0) 'Baseline token cannot delete changed data or create a journal after its approved digest becomes stale'
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
$result=[pscustomobject]@{Passed=(-not $failure);CheckCount=$checks.Count;Checks=$checks.ToArray();Failure=$failure;PackageRoot=$PackageRoot;OldPackageRoot=$OldPackageRoot;FixtureRoot=$owned;BaselinePreviewPlanVersion=$unused.PlanVersion;BaselinePreviewScope=$unused.Scope;BaselinePreviewDisposition=$previewDisposition;PreviewRejectionCode=$previewError;StalePreviewRejectionCode=$staleCode;LegacyPlannerSHA256=(Get-FileHash -LiteralPath (Join-Path $OldPackageRoot 'LocalDeploymentCleanup.ps1')).Hash;NewPlannerSHA256=(Get-FileHash -LiteralPath (Join-Path $PackageRoot 'LocalDeploymentCleanup.ps1')).Hash;Scope='Actual old module creates tokens/journals in bounded synthetic roots; new package recovers them; no remote actors'}
if($ReportPath){[IO.File]::WriteAllText($ReportPath,($result|ConvertTo-Json -Depth 7),(New-Object Text.UTF8Encoding($true)))}
if(-not $failure -and [IO.Path]::GetFullPath($owned).StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($owned) -cmatch '^tc-legacy-cleanup-[a-f0-9]{32}$'){Remove-Item -LiteralPath $owned -Recurse -Force}
$result|ConvertTo-Json -Depth 7
if($failure){exit 1}
