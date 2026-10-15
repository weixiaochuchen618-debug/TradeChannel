#requires -Version 5.1
#requires -PSEdition Desktop
[CmdletBinding()]param(
 [string]$PackageRoot=(Split-Path $PSScriptRoot -Parent),[Parameter(Mandatory=$true)][string]$OldPackageRoot,
 [string]$ReportDirectory,[ValidateSet('Run','Produce','Consume')][string]$Mode='Run',[string]$FixtureRoot
)
$ErrorActionPreference='Stop';Set-StrictMode -Version 2.0;$env:PSModulePath=Join-Path $PSHOME 'Modules'
$checks=New-Object 'Collections.Generic.List[string]';$failure=$null
trap {Write-Output ('Readback fixture error after '+$checks.Count+' checks: '+$_.Exception.Message);Write-Output $_.ScriptStackTrace;exit 1}
function Check {param($Ok,[string]$Name)if(-not $Ok){throw $Name};$checks.Add($Name)}
function Hash {param([string]$Path)if([IO.File]::Exists($Path)){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash}else{'missing'}}
function SafeFixture {param([string]$Path)
 $full=[IO.Path]::GetFullPath($Path);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if(-not $full.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -cnotmatch '^tc-01614-readback-[a-f0-9]{32}$' -or [IO.File]::ReadAllText((Join-Path $full '.owned-readback')) -cne [IO.Path]::GetFileName($full)){throw 'Fixture ownership mismatch'}
 return $full
}
function Put {param([string]$Path,$Value)
 if(-not [IO.Path]::GetFullPath($Path).StartsWith($FixtureRoot+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Fixture write escaped owned root'}
 $null=[IO.Directory]::CreateDirectory((Split-Path $Path -Parent));[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 40),(New-Object Text.UTF8Encoding($true)))
}
function SecretMatches {param($Secure)
 $ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
 try{return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) -ceq '  SYNTHETIC_Readback_密码!  '}finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)}
}
if($Mode -ne 'Run'){$FixtureRoot=SafeFixture $FixtureRoot}
if($Mode -eq 'Produce'){
 Import-Module (Join-Path $PackageRoot 'DeploymentStore.psm1') -DisableNameChecking
 Import-Module (Join-Path $PackageRoot 'ServerRegistry.psm1') -DisableNameChecking
 $cleanup=Import-Module (Join-Path $PackageRoot 'OperationHistory.psm1') -PassThru -DisableNameChecking
 $flow=Import-Module (Join-Path $PackageRoot 'DeploymentFlow.psm1') -PassThru -DisableNameChecking
 Import-Module (Join-Path $PackageRoot 'DeploymentTransport.psm1') -DisableNameChecking
 $connection=Import-Module (Join-Path $PackageRoot 'ConnectionTransactions.psm1') -PassThru -DisableNameChecking
 $cleanupDefinitions=& $cleanup {[pscustomobject]@{Move=(Get-Item Function:LCMove).ScriptBlock.ToString();Rollback=(Get-Item Function:LCRollback).ScriptBlock.ToString();Finish=(Get-Item Function:LCFinish).ScriptBlock.ToString()}}
 $cleanupCases=@();$credentialCases=@();$connectionCases=@()
 foreach($phase in @('uncommitted','preparing','committed','completed')){
  $root=Join-Path $FixtureRoot ('cleanup-'+$phase);$server=Set-TCServerRecord -Root $root -Connection @{Host='192.0.2.51';Port=22;User='root';IdentityFile=''} -Name 'Readback shared source' -ServerInfo @{RemoteOwnerId=[guid]::NewGuid().ToString('D');Node=@{NodeId=[guid]::NewGuid().ToString('D');ServerPublicKey=('S'*43+'=')}}
  $line=[guid]::NewGuid().ToString('D');$a=[guid]::NewGuid().ToString('D');$b=[guid]::NewGuid().ToString('D');$manifest=Join-Path $root ('Product\nodes\'+$line+'\manifest.json')
  Put $manifest @{TCLineId=$line;TCManagedNodeId=$line;ServerPublicKey=('S'*43+'=');ClientPublicKey=('C'*43+'=')}
  Put (Join-Path $root ('Product\lines\'+$line+'\line.json')) @{SchemaVersion=2;LineId=$line;Profiles=@();SourceManifestPath=$manifest;ServerPublicKey=('S'*43+'=')}
  Put (Join-Path $root 'Product\index.json') @{schemaVersion=1;nodes=@(@{id=$line;name='readback';manifestPath=$manifest})}
  $null=Set-TCServerLink -Root $root -ServerId $server.LocalRecordId -NodeId $line
  $state=Join-Path $root ('deployments\runs\'+$a+'\state.json');$other=Join-Path $root ('deployments\runs\'+$b+'\state.json');$client=Join-Path (Split-Path $state) 'client';$shared=Join-Path $client 'public.request.json'
  Put $state @{SchemaVersion=1;RunId=$a;ServerRecordId=$server.LocalRecordId;Revision=1;Intent='New';Status='Complete';Stage='ReadyInactive';CandidateNodeId=$line;CandidateManifestPath=$manifest;CreatedAtUtc=[DateTimeOffset]::UtcNow.ToString('o');UpdatedAtUtc=[DateTimeOffset]::UtcNow.ToString('o')}
  Put $shared @{RequestId=[guid]::NewGuid().ToString('D');ClientPublicKey=('C'*43+'=')}
  Put $other @{SchemaVersion=1;RunId=$b;ServerRecordId=$server.LocalRecordId;Revision=1;Intent='New';Status='WaitingUser';Stage='PrepareAccess';RequestDirectory=$client;ReusedRequestSourceRunId=$a;ClientRequest=@{ClientPublicKey=('C'*43+'=')};CreatedAtUtc=[DateTimeOffset]::UtcNow.ToString('o');UpdatedAtUtc=[DateTimeOffset]::UtcNow.ToString('o')}
  $original=@($state,$manifest,$other,$shared,(Join-Path $root 'Product\index.json'),(Join-Path $root 'servers\registry.json')|ForEach-Object {[pscustomobject]@{Path=$_;SHA256=(Hash $_)}})
  $preview=New-TCLocalDeploymentCleanupPreview -Root $root -Ids @('Line:'+$line)
  Check ($preview.PlanVersion -eq 3 -and $preview.PreviewToken -and $preview.RetainedItems.Count -eq 1) ('Produce '+$phase+' exact PlanVersion 3 shared-source preview')
  if($phase -eq 'preparing'){
   & $cleanup {function script:LCMove {param($From,$To)[IO.File]::Move($From,$To);throw 'ReadbackInjectedCrashAfterMove'};function script:LCRollback {param($Root,$Journal)throw 'ReadbackInjectedLossBeforeRollback'}}
  }elseif($phase -eq 'committed'){& $cleanup {function script:LCFinish {param($Root,$Journal)throw 'ReadbackInjectedCrashAfterCommit'}}}
  $injected='';if($phase -ne 'uncommitted'){try{$null=Remove-TCLocalDeploymentData -Root $root -PreviewToken $preview.PreviewToken}catch{$injected=$_.Exception.Message}}
  & $cleanup {param($Definitions)Set-Item Function:script:LCMove ([scriptblock]::Create($Definitions.Move));Set-Item Function:script:LCRollback ([scriptblock]::Create($Definitions.Rollback));Set-Item Function:script:LCFinish ([scriptblock]::Create($Definitions.Finish))} $cleanupDefinitions
  $journal='';$status='NoJournal';$items=@()
  $journalFiles=@(Get-ChildItem -LiteralPath (Join-Path $root 'local-cleanup') -Filter journal.json -Recurse -ErrorAction SilentlyContinue)
  if($journalFiles.Count){$journal=$journalFiles[0].FullName;$j=Read-TCDJson $journal;$status=$j.Status;$items=@(Get-TCDField $j Items @())}
  Check ($status -ceq @{uncommitted='NoJournal';preparing='Preparing';committed='Committed';completed='Completed'}[$phase]) ('New cleanup produced actual '+$phase+' checkpoint')
  Check ((Hash $shared) -ceq @($original|Where-Object Path -eq $shared)[0].SHA256) ('New '+$phase+' cleanup keeps shared source bytes')
  $cleanupCases+=,[pscustomobject]@{Phase=$phase;Root=$root;RunId=$a;Shared=$shared;State=$state;Manifest=$manifest;OtherState=$other;PreviewToken=$preview.PreviewToken;Journal=$journal;JournalBeforeSHA256=$(if($journal){Hash $journal}else{'missing'});Items=$items;OriginalFiles=$original;InjectedError=$injected}
 }
 foreach($kind in @('healthy','busy-binding')){
  $root=Join-Path $FixtureRoot ('credential-'+$kind);$run=New-TCDeploymentRun -Root $root -Connection @{Host='192.0.2.52';Port=22;User='root';IdentityFile=''} -Name 'Synthetic downgrade credential'
  $null=Set-TCServerRecord -Root $root -Id $run.ServerRecordId -PinnedFingerprint ('SHA256:'+('P'*43))
  $revision=[guid]::NewGuid().ToString('D');$credential=@{Kind='Password';Password=(ConvertTo-SecureString '  SYNTHETIC_Readback_密码!  ' -AsPlainText -Force)}
  $saved=Save-TCDeployTaskCredential -Root $root -RunId $run.RunId -Credential $credential -CredentialRevision $revision
  $path=Join-Path $root ('deployments\credentials\'+$run.RunId+'.json');$state=Join-Path $root ('deployments\runs\'+$run.RunId+'\state.json')
  Check ($saved.Saved -and (Read-TCDJson $path).SchemaVersion -eq 1) ('New '+$kind+' credential uses actual unchanged SchemaVersion 1 DPAPI envelope')
  Check (SecretMatches (Get-TCDeployTaskCredential -Root $root -RunId $run.RunId).Credential.Password) ('New '+$kind+' credential can decrypt its own generated fixture')
  $credentialCases+=,[pscustomobject]@{Kind=$kind;Root=$root;RunId=$run.RunId;Path=$path;StatePath=$state;CredentialSHA256=(Hash $path);StateSHA256=(Hash $state);Revision=$revision}
 }
 foreach($desired in @('Aborted','ResolvedStopped')){
  $root=Join-Path $FixtureRoot ('connection-'+$desired);$line=[guid]::NewGuid().ToString('D');$null=[IO.Directory]::CreateDirectory((Join-Path $root ('Product\lines\'+$line)));$null=[IO.Directory]::CreateDirectory((Join-Path $root 'connection-transactions'))
  Put (Join-Path $root 'Product\index.json') @{schemaVersion=1;nodes=@()};Put (Join-Path $root 'ui-preferences.json') @{Mode='Rule';Extra='preserve-new-preference'}
  $details=& $connection {param($Root,$Line,$Desired)
   $script:ReadbackRoot=$Root;$script:ReadbackOps=New-Object 'Collections.Generic.List[string]'
   $script:TestAdapter={param($Operation,$DataRoot,$Payload)if($DataRoot -cne $script:ReadbackRoot){throw 'Readback root escape'};$script:ReadbackOps.Add($Operation);switch($Operation){'ReadBoundary'{return}'Observe'{return [pscustomobject]@{State='Stopped';OwnershipKnown=$true}}default{throw ('Readback actor forbidden '+$Operation)}}}
   $id=[guid]::NewGuid().ToString('N');$request=[guid]::NewGuid().ToString('N');$path=Join-Path $Root ('connection-transactions\'+$id+'.json')
   $tx=[pscustomobject]@{SchemaVersion=1;Id=$id;Root=$Root;JournalPath=$path;RequestId=$request;LineId=$Line;ProfileId='Udp';Status='NeedsRecovery';Phase=$(if($Desired -eq 'Aborted'){'Prepared'}else{'StopOriginal'});Original=[pscustomobject]@{WasRunning=$false;Deployment=(CTSnapshotFile (Join-Path $Root 'deployment.json'));Index=(CTSnapshotFile (Join-Path $Root 'Product\index.json'));PreferenceFile=(CTSnapshotFile (Join-Path $Root 'ui-preferences.json'));Manifest=$null;Observed=[pscustomobject]@{State='Stopped';OwnershipKnown=$true}};Executor=[pscustomobject]@{ProcessId=2147483646;ProcessStartedTicks=1};CandidateAttempted=$false;StopAttempted=($Desired -ne 'Aborted');OriginalStopped=$false;CandidateIdentity=$null;ConfigurationRestored=$false;ConnectionRestored=$false;TargetCheck=$null;RecoveryCheck=$null;Error=$null;Reconciliation=$null;History=@();UpdatedAt=$null}
   CTWrite $path $tx;$resolved=@(Reconcile-TCConnectionTransactions -Root $Root -ResolveStopped -RequestIds @($request));$written=CTRead $path
   [pscustomobject]@{Root=$Root;Path=$path;RequestId=$request;Status=$written.Status;Proof=$written.RecoveryProof;RuntimeOperations=@($script:ReadbackOps.ToArray());ResultCount=$resolved.Count;JournalSHA256=(CTHash $path);IndexSHA256=(CTHash (Join-Path $Root 'Product\index.json'));PreferenceSHA256=(CTHash (Join-Path $Root 'ui-preferences.json'))}
  } $root $line $desired
  Check ($details.Status -ceq $desired -and $details.ResultCount -eq 1 -and $details.Proof.Kind -ceq 'TradeChannel.ConnectionResolution' -and $details.Proof.OriginalConfigurationIntact) ('New read-only reconciliation actually persists '+$desired+' with RecoveryProof')
  Check (@($details.RuntimeOperations|Where-Object {$_ -notin @('ReadBoundary','Observe')}).Count -eq 0) ('Producing '+$desired+' executes no start, stop, verify or replay')
  $connectionCases+=,$details
 }
 Put (Join-Path $FixtureRoot 'inputs.json') @{Cleanup=$cleanupCases;Credentials=$credentialCases;Connections=$connectionCases;NewSource=$PackageRoot;Checks=@($checks.ToArray());CheckCount=$checks.Count}
 [pscustomobject]@{Mode='Produce';Passed=$true;Checks=$checks.Count;ActualSource=$PackageRoot;PowerShell=$PSVersionTable.PSVersion.ToString()}|ConvertTo-Json
 exit 0
}
if($Mode -eq 'Consume'){
 $inputs=[IO.File]::ReadAllText((Join-Path $FixtureRoot 'inputs.json'),[Text.Encoding]::UTF8)|ConvertFrom-Json
 Import-Module (Join-Path $OldPackageRoot 'DeploymentStore.psm1') -DisableNameChecking
 Import-Module (Join-Path $OldPackageRoot 'ServerRegistry.psm1') -DisableNameChecking
 $cleanup=Import-Module (Join-Path $OldPackageRoot 'OperationHistory.psm1') -PassThru -DisableNameChecking
 $transport=Import-Module (Join-Path $OldPackageRoot 'DeploymentTransport.psm1') -PassThru -DisableNameChecking
 $connection=Import-Module (Join-Path $OldPackageRoot 'ConnectionTransactions.psm1') -PassThru -DisableNameChecking
 foreach($module in @($cleanup,$transport,$connection)){Check ($module.Path.StartsWith([IO.Path]::GetFullPath($OldPackageRoot)+'\',[StringComparison]::OrdinalIgnoreCase)) ('Fresh old process loads actual '+$module.Name+' from baseline')}
 $limitations=New-Object 'Collections.Generic.List[object]'
 foreach($row in $inputs.Cleanup){
  if($row.Phase -eq 'uncommitted'){
   $rejected=$false;try{$null=Remove-TCLocalDeploymentData -Root $row.Root -PreviewToken $row.PreviewToken}catch{$rejected=$_.Exception.Message -match 'CleanupPreviewInvalid'}
   Check $rejected 'Old module rejects a not-yet-committed PlanVersion 3 token instead of recomputing its scope'
   Check (@($row.OriginalFiles|Where-Object {(Hash $_.Path) -cne $_.SHA256}).Count -eq 0) 'Rejected new preview leaves every source and reference byte unchanged'
   $limitations.Add([pscustomobject]@{Condition='NewUncommittedCleanupPreview';Disposition='BlockedByOldCode';Reason='PlanVersion 3 preview must be discarded; no silent conversion to old scope'})
   continue
  }
  if($row.Phase -in @('preparing','committed')){
   Check (@(Get-TCLocalCleanupPending -Root $row.Root).Count -eq 1) ('Old reader recognizes new '+$row.Phase+' journal as pending')
   $before=Read-TCDJson $row.Journal
   Check ($before.SchemaVersion -eq 1 -and (Get-TCDDigest @($before.Items)) -ceq (Get-TCDDigest @($row.Items))) ('Old '+$row.Phase+' recovery uses the actual original Items/stash list')
   $repaired=Repair-TCLocalDeploymentCleanup -Root $row.Root
   Check ($repaired.RecoveredCount -eq 1 -and @(Get-TCLocalCleanupPending -Root $row.Root).Count -eq 0) ('Old module safely settles new '+$row.Phase+' journal')
   Check ((Repair-TCLocalDeploymentCleanup -Root $row.Root).RecoveredCount -eq 0) ('Old new-'+$row.Phase+' recovery is idempotent')
  }
  if($row.Phase -eq 'preparing'){
   Check (@($row.OriginalFiles|Where-Object {(Hash $_.Path) -cne $_.SHA256}).Count -eq 0) 'Old rollback restores every new Preparing source/index byte while leaving retained shared files intact'
   Check ((Read-TCDJson $row.Journal).Status -ceq 'RolledBack') 'Old Preparing recovery retains an explicit RolledBack receipt'
  }else{
   $terminalHash=Hash $row.Journal;$repeat=Remove-TCLocalDeploymentData -Root $row.Root -PreviewToken $row.PreviewToken
   Check ($repeat.AlreadyApplied -and $repeat.DataDeleted -and $repeat.RetainedItems.Count -eq 1 -and -not [IO.File]::Exists($row.State) -and -not [IO.File]::Exists($row.Manifest)) ('Old '+$row.Phase+' confirmation only returns its original durable deletion result')
   Check ((Hash $row.Journal) -ceq $terminalHash -and (Hash $row.Shared) -ceq @($row.OriginalFiles|Where-Object Path -eq $row.Shared)[0].SHA256 -and (Hash $row.OtherState) -ceq @($row.OriginalFiles|Where-Object Path -eq $row.OtherState)[0].SHA256) ('Old '+$row.Phase+' readback preserves new receipt, shared bytes and surviving task')
   $history=@(Get-TCOperationHistory -Root $row.Root|Where-Object Id -ceq ('DeploymentRun:'+$row.RunId))
   Check ($history.Count -eq 1 -and $history[0].ProtectionReasons -contains 'SourceMetadataInvalid') ('Old '+$row.Phase+' UI projection limitation is visible rather than assumed compatible')
  }
 }
 $limitations.Add([pscustomobject]@{Condition='CompletedCleanupRetainedSourceDirectory';Disposition='DataSafeButOldProjectionLimited';Reason='Old history projects preserved source-only directory as missing metadata; new reader recognizes its exact completion receipt'})
 foreach($row in $inputs.Credentials){
  if($row.Kind -eq 'healthy'){
   $info=Get-TCDeployTaskCredential -Root $row.Root -RunId $row.RunId -InfoOnly;$value=Get-TCDeployTaskCredential -Root $row.Root -RunId $row.RunId
   Check ($info.Available -and -not $info.Credential -and $value.Available -and (SecretMatches $value.Credential.Password) -and $value.CredentialRevision -ceq $row.Revision) 'Actual old credential reader decrypts new SchemaVersion 1 envelope with exact revision, whitespace and Unicode'
   Check ((Hash $row.Path) -ceq $row.CredentialSHA256 -and (Hash $row.StatePath) -ceq $row.StateSHA256) 'Healthy old InfoOnly and credential reads never rewrite the new envelope or run'
  }else{
   $held=[IO.File]::Open($row.StatePath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
   try{$info=Get-TCDeployTaskCredential -Root $row.Root -RunId $row.RunId -InfoOnly}finally{$held.Dispose()}
   Check (-not $info -and -not [IO.File]::Exists($row.Path) -and (Hash $row.StatePath) -ceq $row.StateSHA256) 'Known old F08 is reproduced on a new envelope only in the disposable busy-binding fixture'
   $limitations.Add([pscustomobject]@{Condition='ActiveCredentialBindingReadFailure';Disposition='UnsafeBehaviorOnDowngrade';Reason='Old InfoOnly deletes a valid new envelope when run metadata is temporarily locked; close task writers and protect credential data before downgrade'})
  }
 }
 foreach($row in $inputs.Connections){
  $read=& $connection {param($Root,$RequestId)
   $script:ReadbackRoot=$Root;$script:ReadbackOps=New-Object 'Collections.Generic.List[string]';$script:TestAdapter={param($Operation,$DataRoot,$Payload)if($DataRoot -cne $script:ReadbackRoot){throw 'Old reader root escape'};$script:ReadbackOps.Add($Operation);if($Operation -eq 'ReadBoundary'){return};throw ('Old terminal reader must not reach actor '+$Operation)}
   $progress=Get-TCConnectionTransactionProgress -Root $Root -RequestId $RequestId;$out=@(Reconcile-TCConnectionTransactions -Root $Root -ResolveStopped -RequestIds @($RequestId));$withoutRequest=@(Reconcile-TCConnectionTransactions -Root $Root -ResolveStopped)
   [pscustomobject]@{Progress=$progress;Out=$out;WithoutRequestCount=$withoutRequest.Count;Operations=@($script:ReadbackOps.ToArray())}
  } $row.Root $row.RequestId
  Check ($read.Progress.Terminal -and $read.Progress.Status -ceq $row.Status -and $read.Out.Count -eq 1 -and $read.Out[0].Status -ceq $row.Status -and -not $read.Out[0].Activated -and -not $read.Out[0].ConnectionRestored) ('Old reader recognizes new '+$row.Status+' as the exact nonconnected terminal result')
  Check ($read.WithoutRequestCount -eq 0 -and @($read.Operations|Where-Object {$_ -ne 'ReadBoundary'}).Count -eq 0) ('Old '+$row.Status+' readback does not observe, replay, start or stop any connection')
  $raw=& $connection {param($Path)CTRead $Path} $row.Path
  Check ((Hash $row.Path) -ceq $row.JournalSHA256 -and (Get-TCDDigest $raw.RecoveryProof) -ceq (Get-TCDDigest $row.Proof) -and (Hash (Join-Path $row.Root 'Product\index.json')) -ceq $row.IndexSHA256 -and (Hash (Join-Path $row.Root 'ui-preferences.json')) -ceq $row.PreferenceSHA256) ('Old '+$row.Status+' readback preserves RecoveryProof, raw journal and current preferences byte for byte')
 }
 $result=[pscustomobject]@{Mode='Consume';Passed=$true;Checks=$checks.Count;Results=$checks.ToArray();ActualOldSource=$OldPackageRoot;PowerShell=$PSVersionTable.PSVersion.ToString();Limitations=$limitations.ToArray();ProductionTouched=$false;RemoteCalls=0;NetworkActors=0}
 Put (Join-Path $FixtureRoot 'readback-result.json') $result;$result|ConvertTo-Json -Depth 8;exit 0
}
if(-not $ReportDirectory){throw 'ReportDirectory is required in Run mode'}
$ReportDirectory=[IO.Path]::GetFullPath($ReportDirectory);$null=[IO.Directory]::CreateDirectory($ReportDirectory)
$FixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('tc-01614-readback-'+[guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($FixtureRoot);[IO.File]::WriteAllText((Join-Path $FixtureRoot '.owned-readback'),[IO.Path]::GetFileName($FixtureRoot))
$commands=@();$readback=$null;$inputs=$null
try{
 $exe=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
 foreach($stage in @('Produce','Consume')){
  $arguments=@('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',$PSCommandPath,'-Mode',$stage,'-PackageRoot',$PackageRoot,'-OldPackageRoot',$OldPackageRoot,'-FixtureRoot',$FixtureRoot)
  $started=[DateTimeOffset]::UtcNow.ToString('o');$log=Join-Path $ReportDirectory ($stage+'.log');$priorErrorPreference=$ErrorActionPreference
  try{$ErrorActionPreference='Continue';& $exe @arguments *> $log;$code=$LASTEXITCODE}finally{$ErrorActionPreference=$priorErrorPreference}
  $commands+=,[pscustomobject]@{Mode=$stage;Executable=$exe;Arguments=$arguments;StartedAtUtc=$started;FinishedAtUtc=[DateTimeOffset]::UtcNow.ToString('o');ExitCode=$code;Log=$log;LogSHA256=(Hash $log)}
  [IO.File]::WriteAllText((Join-Path $ReportDirectory 'commands.json'),($commands|ConvertTo-Json -Depth 6),(New-Object Text.UTF8Encoding($true)))
  if($code -ne 0){throw ('Isolated '+$stage+' failed; see '+$log)}
 }
 $inputs=[IO.File]::ReadAllText((Join-Path $FixtureRoot 'inputs.json'),[Text.Encoding]::UTF8)|ConvertFrom-Json;$readback=[IO.File]::ReadAllText((Join-Path $FixtureRoot 'readback-result.json'),[Text.Encoding]::UTF8)|ConvertFrom-Json
}catch{$failure=$_.Exception.Message}
$summary=[pscustomobject]@{Passed=(-not $failure);Checks=$(if($inputs -and $readback){$inputs.CheckCount+$readback.Checks}else{0});NewSource=$PackageRoot;OldSource=$OldPackageRoot;ProducerChecks=$(if($inputs){$inputs.CheckCount}else{0});Consumer=$readback;Failure=$failure;FixtureRoot=$FixtureRoot;ProductionTouched=$false;RemoteCalls=0;NetworkActors=0;PowerShell=$PSVersionTable.PSVersion.ToString();OldCodeModified=$false}
[IO.File]::WriteAllText((Join-Path $ReportDirectory 'result.json'),($summary|ConvertTo-Json -Depth 12),(New-Object Text.UTF8Encoding($true)))
$summary|Select-Object Passed,Checks,ProducerChecks,Failure,PowerShell|ConvertTo-Json
if(-not $failure){$safe=SafeFixture $FixtureRoot;$reparse=@(Get-ChildItem -LiteralPath $safe -Recurse -Force|Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint});if($reparse.Count){throw 'Fixture cleanup refused reparse point'};Remove-Item -LiteralPath $safe -Recurse -Force}else{exit 1}
