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
 # --- 0.18.4: local one-file operations are verified from their file once the executor has ended ---
 $dead=Start-Process -FilePath (Join-Path $env:WINDIR 'System32\cmd.exe') -ArgumentList '/c exit 0' -PassThru -WindowStyle Hidden
 $deadId=$dead.Id;$deadTicks=$dead.StartTime.ToUniversalTime().Ticks;$null=$dead.WaitForExit(5000);$dead.Dispose()
 $lineId='343a3e8e-5960-47b9-b4ae-4c40a80ec244'
 $lineDir=Join-Path $script:Root ('Product\lines\'+$lineId);$null=[IO.Directory]::CreateDirectory($lineDir)
 $linePath=Join-Path $lineDir 'line.json'
 $startedAt=[DateTime]::UtcNow.AddMinutes(-10)
 function MakeLocal {param([string]$Action='LinePreference',[datetime]$Written,$Scope=@{Kind='Global';Host='';ServerRecordId='';RunId=''},[int]$ProcessId=$deadId,[long]$Ticks=$deadTicks,[string]$Run='',[string]$Status='OutcomeUnknown')
  $lineJson=if($Action -ceq 'LinePreferenceReset'){ConvertTo-Json -InputObject ([ordered]@{SchemaVersion=2;LineId=$lineId;Revision=7;PreferenceSource='UserChoice';PreferenceUpdatedAt=$startedAt.ToString('o');PreferredProfileId='Udp';SavedConnectionPreference=@{ProfileId='Udp';Source='UserChoice';Digest=('A'*64)}}) -Depth 8 -Compress}else{'{"PreferenceSource":"None"}'}
  [IO.File]::WriteAllText($linePath,$lineJson,[Text.UTF8Encoding]::new($true));[IO.File]::SetLastWriteTimeUtc($linePath,$Written)
  $id=[guid]::NewGuid().ToString('N')
  $r=@{SchemaVersion=1;RequestId=$id;OperationId=$id;Action=$Action;RunId=$Run;LineId=$lineId;TransactionId=$null;DeploymentMutation=$null;DeploymentProbe=$null;ResourceScope=$Scope;Status=$Status;StartedAtUtc=$startedAt.ToString('o');ProcessId=$ProcessId;ProcessStartedTicks=$Ticks}
  $result=@{RequestId=$id;Action=$Action;Ok=$false;Code='WorkerStepFailed';Phase='Executing';OutcomeUnknown=$true}
  foreach($item in @(@('receipt',$r),@('result',$result))){[IO.File]::WriteAllText((Join-Path $script:JobRoot ($id+'.'+$item[0]+'.json')),($item[1]|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($true))}
  if($Action -ceq 'LinePreferenceReset'){$request=@{RequestId=$id;Action=$Action;Id=$lineId;ExpectedRevision=7;ExpectedDigest=('A'*64)};[IO.File]::WriteAllText((Join-Path $script:JobRoot ($id+'.request.json')),($request|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($true))}
  $id
 }
 function Reload {$script:UiJobRecoveryLoaded=$false;$script:UncertainUiJobs.Clear();RestoreUiJobReceipts}
 function ReadReceipt2 {param($Id)[IO.File]::ReadAllText((Join-Path $script:JobRoot ($Id+'.receipt.json')))|ConvertFrom-Json}
 $notApplied=MakeLocal -Written $startedAt.AddMinutes(-1)
 $resultPath=Join-Path $script:JobRoot ($notApplied+'.result.json');$resultHash=(Get-FileHash -LiteralPath $resultPath).Hash
 Reload;$r=ReadReceipt2 $notApplied
 Check ($r.Status -ceq 'Failed' -and $r.Resolution.Kind -ceq 'LocalAtomicNotApplied' -and -not $r.Resolution.OperationReplayed -and -not $r.Resolution.RemoteMutation -and @($script:UncertainUiJobs|Where-Object RequestId -ceq $notApplied).Count -eq 0) 'a saved default whose record was not written since the start is released as not applied'
 Check ((Get-FileHash -LiteralPath $resultPath).Hash -ceq $resultHash) 'the original failed result is kept byte for byte'
 $hashAfter=(Get-FileHash -LiteralPath (Join-Path $script:JobRoot ($notApplied+'.receipt.json'))).Hash
 Reload;Check ((Get-FileHash -LiteralPath (Join-Path $script:JobRoot ($notApplied+'.receipt.json'))).Hash -ceq $hashAfter) 'resolution is idempotent across restarts'
 Check (@($script:UncertainUiJobs|Where-Object {$_.Action -ceq 'LinePreference'}).Count -eq 0) 'after resolution no saved-default record blocks anything'
 $reset=MakeLocal -Action LinePreferenceReset -Written $startedAt.AddMinutes(-1)
 Reload;$resetReceipt=ReadReceipt2 $reset
 Check ($resetReceipt.Status -ceq 'Failed' -and $resetReceipt.Resolution.Kind -ceq 'LocalAtomicNotApplied' -and @($script:UncertainUiJobs|Where-Object RequestId -ceq $reset).Count -eq 0) 'an exited automatic-preference reset is reconciled locally without replaying a connection'
 $resetApplied=MakeLocal -Action LinePreferenceReset -Written $startedAt.AddMinutes(1)
 $at=[DateTimeOffset]::UtcNow.ToString('o');$newDigest=('B'*64)
 $transition=[ordered]@{SchemaVersion=1;Kind='ManualPreferenceCleared';RequestId=$resetApplied;LineId=$lineId;FromRevision=7;ToRevision=8;FromDigest=('A'*64);AtUtc=$at;Outcome='SinglePreparedProfile';SelectedProfileId='Udp';ToDigest=$newDigest;PreferenceMode='Auto';NextAction='PreviewConnection';RecommendationDigest=''}
 $bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $transition -Depth 40 -Compress));$sha=[Security.Cryptography.SHA256]::Create();try{$transition.Digest=([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','')}finally{$sha.Dispose();[Array]::Clear($bytes,0,$bytes.Length)}
 $appliedLine=[ordered]@{SchemaVersion=2;LineId=$lineId;Revision=8;PreferenceSource='SingleProfile';PreferenceUpdatedAt=$at;PreferredProfileId='Udp';SavedConnectionPreference=@{ProfileId='Udp';Source='SingleProfile';Digest=$newDigest};AutomaticPreferenceTransition=[pscustomobject]$transition}
 [IO.File]::WriteAllText($linePath,(ConvertTo-Json -InputObject $appliedLine -Depth 12 -Compress),[Text.UTF8Encoding]::new($true));[IO.File]::SetLastWriteTimeUtc($linePath,$startedAt.AddMinutes(1))
 Reload;$resetAppliedReceipt=ReadReceipt2 $resetApplied
 Check ($resetAppliedReceipt.Status -ceq 'Completed' -and $resetAppliedReceipt.Resolution.Reason -ceq 'MatchingAutomaticPreferenceTransition' -and @($script:UncertainUiJobs|Where-Object RequestId -ceq $resetApplied).Count -eq 0) 'only the exact durable automatic-preference transition proves that reset completed'
 $resetMissing=MakeLocal -Action LinePreferenceReset -Written $startedAt.AddMinutes(-1);[IO.File]::Delete($linePath)
 Reload;Check ((ReadReceipt2 $resetMissing).Status -ceq 'OutcomeUnknown' -and @($script:UncertainUiJobs|Where-Object RequestId -ceq $resetMissing).Count -eq 1) 'a missing line record cannot be mistaken for a completed automatic reset'
 Check ((GetUiOperationLabel 'LinePreferenceReset') -ceq '恢复自动选择') 'automatic-preference recovery exposes the actual task name'
 $written=MakeLocal -Written $startedAt.AddMinutes(1)
 Reload;$r=ReadReceipt2 $written
 Check ($r.Status -ceq 'Completed' -and $r.Resolution.Kind -ceq 'LocalAtomicObserved' -and $r.Resolution.Reason -ceq 'TargetWrittenAfterStart') 'a record written after the start is shown as it is now, not replayed'
 $liveProcess=[Diagnostics.Process]::GetCurrentProcess()
 $alive=MakeLocal -Written $startedAt.AddMinutes(-1) -ProcessId $liveProcess.Id -Ticks $liveProcess.StartTime.ToUniversalTime().Ticks;$liveProcess.Dispose()
 Reload;Check ((ReadReceipt2 $alive).Status -ceq 'OutcomeUnknown' -and @($script:UncertainUiJobs|Where-Object RequestId -ceq $alive).Count -eq 1) 'an executor that is still running is never released'
 foreach($p in @($script:UncertainUiJobs.ToArray())){if($p.Process){$p.Process.Dispose()}}
 $unknownExec=MakeLocal -Written $startedAt.AddMinutes(-1) -ProcessId 0 -Ticks 0
 Reload;Check ((ReadReceipt2 $unknownExec).Status -ceq 'OutcomeUnknown') 'an unverifiable executor identity is never released'
 $conn=MakeLocal -Action Session -Written $startedAt.AddMinutes(-1);$dep=MakeLocal -Action DeploymentProceed -Written $startedAt.AddMinutes(-1);$bound=MakeLocal -Written $startedAt.AddMinutes(-1) -Run ([guid]::NewGuid().ToString('D'))
 $serverScope=MakeLocal -Written $startedAt.AddMinutes(-1) -Scope @{Kind='DeploymentServer';Host='192.0.2.9';ServerRecordId='';RunId=''}
 Reload
 Check ((ReadReceipt2 $conn).Status -ceq 'OutcomeUnknown' -and (ReadReceipt2 $dep).Status -ceq 'OutcomeUnknown' -and (ReadReceipt2 $bound).Status -ceq 'OutcomeUnknown' -and (ReadReceipt2 $serverScope).Status -ceq 'OutcomeUnknown') 'connection, deployment, run-bound and server-scoped records keep their own recovery path'
 $lineScoped=MakeLocal -Written $startedAt.AddMinutes(-1) -ProcessId $liveProcess.Id
 $labels=@('LinePreference','LineProfileCheck','DeploymentProceed','RecordDeleteCommit','ProviderApply','TradeApplicationApply'|ForEach-Object {GetUiOperationLabel $_})
 Check (($labels -join '|') -ceq '保存默认连接方式|测试线路|部署新线路|删除线路|接入代理软件|更新交易软件名单' -and (GetUiOperationLabel 'Nope') -ceq '一项后台操作') 'operation labels are plain and unknown names never leak'
 [pscustomobject]@{Passed=$checks;RemoteCalls=0}|ConvertTo-Json
}finally{
 $full=[IO.Path]::GetFullPath($script:Root);if(-not $full.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -cnotmatch '^tc-receipt-[a-f0-9]{32}$'){throw 'Invalid fixture cleanup'}
 Remove-Item -LiteralPath $full -Recurse -Force
}
