#requires -Version 5.1
#requires -PSEdition Desktop
param([string]$SourceDirectory=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';Set-StrictMode -Version 2.0
$script:PackageRoot=$SourceDirectory;$script:Root=Join-Path ([IO.Path]::GetTempPath()) ('tc-receipt-'+[guid]::NewGuid().ToString('N'))
$script:JobRoot=Join-Path $script:Root 'Product\jobs';$null=[IO.Directory]::CreateDirectory($script:JobRoot)
$script:ReadOnly=$false;$script:Footer=[pscustomobject]@{Text=''};$script:Job=$null;$checks=0
. (Join-Path $SourceDirectory 'ui\BackgroundJobs.ps1')
function Check {param($Condition,[string]$Text) if(-not $Condition){throw $Text};$script:checks++}
function MakeReceipt {param([string]$Action,[string]$Run='', $Binding=$null)
 $id=[guid]::NewGuid().ToString('N');$r=@{SchemaVersion=1;RequestId=$id;Action=$Action;RunId=$Run;LineId='';TransactionId='';ResourceScope=$Binding;Status='OutcomeUnknown';StartedAtUtc=[DateTime]::UtcNow.ToString('o');ProcessId=0;ProcessStartedTicks=0}
 $result=@{RequestId=$id;Action=$Action;Ok=$false;Code='WorkerStepFailed';Phase='Executing';OutcomeUnknown=$true}
 foreach($item in @(@('receipt',$r),@('result',$result))){[IO.File]::WriteAllText((Join-Path $script:JobRoot ($id+'.'+$item[0]+'.json')),($item[1]|ConvertTo-Json),[Text.UTF8Encoding]::new($true))};$id
}
try{
 $id=MakeReceipt DeploymentAccessState
 RestoreUiJobReceipts
 $r=[IO.File]::ReadAllText((Join-Path $script:JobRoot ($id+'.receipt.json')))|ConvertFrom-Json
 Check ($script:UncertainUiJobs.Count -eq 0 -and $r.Status -eq 'Failed' -and $r.Resolution.Kind -eq 'FailedLocalBookkeeping') 'Old unbound bookkeeping failure is resolved as failed, never as successful deployment'
 Check ([IO.File]::Exists((Join-Path $script:JobRoot ($id+'.result.json')))) 'Original failed result remains as evidence'
 $script:UiJobRecoveryLoaded=$false;$script:UncertainUiJobs.Clear();RestoreUiJobReceipts
 Check ($script:UncertainUiJobs.Count -eq 0) 'Resolution survives UI restart'
 $remote=MakeReceipt DeploymentProceed;$script:UiJobRecoveryLoaded=$false;RestoreUiJobReceipts
 Check ($script:UncertainUiJobs.Count -eq 1 -and (TestUiMutationBlocked @{Action='DeploymentCreate'} @{Kind='DeploymentServer';Host='192.0.2.50';ServerRecordId='';RunId=''})) 'Unbound remote mutation still blocks new work'
 $script:UiJobRecoveryLoaded=$false;$script:UncertainUiJobs.Clear();$bound=MakeReceipt DeploymentAccessState ([guid]::NewGuid().ToString('D'))
 RestoreUiJobReceipts;Check ($script:UncertainUiJobs.Count -eq 2) 'Valid run binding cannot use legacy empty-run resolution'
 $fake=[pscustomobject]@{SchemaVersion=1;RequestId=('f'*32);Action='DeploymentAccessState';Status='OutcomeUnknown';RunId=''}
 $result=[pscustomobject]@{RequestId=('e'*32);Action='DeploymentAccessState';Ok=$false;Code='WorkerStepFailed';Phase='Executing'}
 Check (-not (GetUiLegacyReceiptResolution $fake $result $null)) 'Mismatched result cannot resolve receipt'
 $result.RequestId=$fake.RequestId;$live=[Diagnostics.Process]::GetCurrentProcess()
 try{Check (-not (GetUiLegacyReceiptResolution $fake $result $live)) 'Live executor cannot be reconciled'}finally{$live.Dispose()}
 [pscustomobject]@{Passed=$checks;RemoteCalls=0}|ConvertTo-Json
}finally{
 $full=[IO.Path]::GetFullPath($script:Root);if(-not $full.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -cnotmatch '^tc-receipt-[a-f0-9]{32}$'){throw 'Invalid fixture cleanup'}
 Remove-Item -LiteralPath $full -Recurse -Force
}
