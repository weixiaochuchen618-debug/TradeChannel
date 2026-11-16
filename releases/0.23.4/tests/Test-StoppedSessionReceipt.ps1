#requires -Version 5.1
[CmdletBinding()]param([string]$PackageRoot,[string]$ReportPath,[switch]$ExpectLegacyDefect)
if(-not $PackageRoot){$PackageRoot=Split-Path $PSScriptRoot -Parent}
$ErrorActionPreference='Stop'
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('tc-session-receipt-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($fixture)
$m=Import-Module (Join-Path $PackageRoot 'ConnectionTransactions.psm1') -Force -PassThru -DisableNameChecking
try{
 $result=& $m {
  param($root,$legacy)
  $script:TestAdapter={param($op,$r,$p)
   if($op -eq 'ReadBoundary'){return}
   if($op -eq 'Observe'){return $script:FixtureObserved}
   throw ('Unexpected real action: '+$op)
  }
  function script:CTReceiptWorkerEnded {param($receipt) return $script:FixtureWorkerEnded}
  function script:Get-Process {throw 'Real process access forbidden'}
  function script:Get-CimInstance {throw 'Real inventory forbidden'}
  function script:Start-Process {throw 'Real process start forbidden'}
  function script:Stop-Process {throw 'Real process stop forbidden'}
  $rows=@();$checks=0
  foreach($case in @('Valid','WorkerAlive','Running','UnknownOwnership','CleanupError','MissingStop','UnrelatedStop','DifferentDiagnostic','MismatchedResult','MissingResult','OtherAction','RemoteReference','PendingTransaction','ProbeCleanup','ProxyCleanup','ConfigChanged','ContradictoryRequest','TransactionOwned')){
   $r=Join-Path $root $case
   foreach($dir in @('Product\jobs','diagnostics\failures','connection-transactions','proxy-recovery','probes')){$null=[IO.Directory]::CreateDirectory((Join-Path $r $dir))}
   $id='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';$diag='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';$session='cccccccccccccccccccccccccccccccc'
   $start=[DateTimeOffset]::UtcNow.AddSeconds(-20);$stop=$start.AddSeconds(1);$failed=$start.AddSeconds(2)
   $config=Join-Path $r 'config.json';[IO.File]::WriteAllText($config,'{"fixture":true}')
   $hash=CTHash $config;$manifest=Join-Path $r 'manifest.json';CTWrite $manifest @{SyntaxValidated=$true;CandidatePath=$config;CandidateSHA256=$hash}
   $receipt=[pscustomobject]@{SchemaVersion=1;RequestId=$id;Action='Session';Status='OutcomeUnknown';RunId='';LineId='';TransactionId=$null;ProcessId=12345;ProcessStartedTicks=123456789;StartedAtUtc=$start.ToString('o');UpdatedAtUtc=$failed.ToString('o')}
   $res=[pscustomobject]@{RequestId=$id;Action='Session';Ok=$false;OutcomeUnknown=$true;Code='WorkerStepFailed';Phase='Executing';DiagnosticId=$diag;ErrorId='original-error'}
   $diagnostic=[pscustomobject]@{RequestId=$id;Action='Session';AtUtc=$failed.ToString('o');ExceptionChain=@(@{Type='System.Management.Automation.MethodException'},@{Type='System.Management.Automation.PSInvalidCastException'},@{Type='System.OverflowException'})}
   $snapshot=[pscustomobject]@{State='Disconnected';SessionId=$session;CleanupError=$false}
   $script:FixtureWorkerEnded=$true;$script:FixtureObserved=[pscustomobject]@{State='Stopped';OwnershipKnown=$true;SessionId=$session;ManifestPath=$manifest;CandidateSHA256=$hash}
   switch($case){
    'WorkerAlive'{$script:FixtureWorkerEnded=$false}
    'Running'{$script:FixtureObserved.State='Running'}
    'UnknownOwnership'{$script:FixtureObserved.OwnershipKnown=$false}
    'CleanupError'{$snapshot.CleanupError=$true}
    'UnrelatedStop'{$stop=$start.AddSeconds(-10)}
    'DifferentDiagnostic'{$diagnostic.ExceptionChain[2].Type='System.InvalidOperationException'}
    'MismatchedResult'{$res.RequestId='dddddddddddddddddddddddddddddddd'}
    'OtherAction'{$receipt.Action='DeploymentProceed';$res.Action='DeploymentProceed'}
    'RemoteReference'{$receipt.RunId='remote-run'}
    'PendingTransaction'{CTWrite (Join-Path $r 'connection-transactions\pending.json') @{Status='NeedsRecovery'}}
    'TransactionOwned'{CTWrite (Join-Path $r 'connection-transactions\owner.json') @{Status='Completed';RequestId=$id}}
    'ProbeCleanup'{$probe=Join-Path $r ('probes\'+[guid]::NewGuid().ToString());$null=[IO.Directory]::CreateDirectory($probe);CTWrite (Join-Path $probe 'ownership.json') @{SchemaVersion=1;RunId=[IO.Path]::GetFileName($probe);State='Running'}}
    'ProxyCleanup'{CTWrite (Join-Path $r 'proxy-recovery\pending.json') @{SchemaVersion=1;Stage='Applied'}}
    'ConfigChanged'{[IO.File]::WriteAllText($config,'{"fixture":false}')}
    'ContradictoryRequest'{CTWrite (Join-Path $r ('Product\jobs\'+$id+'.request.json')) @{RequestId=$id;Action='Session';SessionAction='Connect'}}
   }
   CTWrite (Join-Path $r 'runtime.json') $snapshot
   if($case -ne 'MissingStop'){[IO.File]::WriteAllText((Join-Path $r 'stop.request'),$stop.ToString('o'))}
   $receiptPath=Join-Path $r ('Product\jobs\'+$id+'.receipt.json');CTWrite $receiptPath $receipt;$before=CTHash $receiptPath
   $resultPath=Join-Path $r ('Product\jobs\'+$id+'.result.json');if($case -ne 'MissingResult'){CTWrite $resultPath $res};$resultHash=CTHash $resultPath
   CTWrite (Join-Path $r ('diagnostics\failures\'+$diag+'.json')) $diagnostic
   if($legacy -or $case -eq 'Valid'){$out=@(Reconcile-TCConnectionTransactions -Root $r -ResolveStopped -RequestIds @($id))}
   else{
    # Public reconciliation also retains unrelated nonterminal transaction
    # handling; this private boundary isolates receipt refusal cases.
    $locks=CTLocks $r
    try{$out=@(CTReconcileStoppedSessionReceipts $r @($id))}finally{CTCloseLocks $locks}
   }
   $after=CTRead $receiptPath;$resolved=($after.Status -eq 'Reconciled')
   $expected=($case -eq 'Valid' -and -not $legacy)
   if($resolved -ne $expected){throw ('Wrong resolution: '+$case)};$checks++
   if(-not $expected -and (CTHash $receiptPath) -cne $before){throw ('Refused receipt changed: '+$case)};$checks++
   if((CTHash $resultPath) -cne $resultHash){throw ('Original failed result altered: '+$case)};$checks++
   if($expected){
    if($out.Count -ne 1 -or $out[0].Status -cne 'ResolvedStopped' -or $out[0].Resolution.NetworkOperationRequested -ne $false -or $out[0].Resolution.OriginalActionSucceeded -ne $false){throw 'Recovery overstated original success'};$checks++
    $hashBeforeRetry=CTHash $receiptPath;$null=Reconcile-TCConnectionTransactions -Root $r -ResolveStopped -RequestIds @($id)
    if((CTHash $receiptPath) -cne $hashBeforeRetry){throw 'Recovery not idempotent'};$checks++
   }
   $rows+=[pscustomobject]@{Case=$case;Resolved=$resolved;Expected=$expected;Passed=$true}
   if($legacy){break}
  }
  [pscustomobject]@{Passed=$true;Assertions=$checks;Cases=$rows;LegacyDefectConfirmed=[bool]$legacy;NetworkOperations=0;RealProcessesTouched=0}
 } $fixture ([bool]$ExpectLegacyDefect)
 if($ReportPath){[IO.File]::WriteAllText($ReportPath,($result|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($true))}
 $result|ConvertTo-Json -Depth 6
}finally{
 Remove-Module $m -Force
 $resolved=[IO.Path]::GetFullPath($fixture)
 if(-not $resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^tc-session-receipt-[a-f0-9]{32}$'){throw 'Unsafe fixture cleanup'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
}
