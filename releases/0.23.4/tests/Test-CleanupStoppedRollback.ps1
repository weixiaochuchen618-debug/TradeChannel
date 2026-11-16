#requires -Version 5.1
#requires -PSEdition Desktop
[CmdletBinding()]param([string]$SourceDirectory=(Split-Path $PSScriptRoot -Parent),[Parameter(Mandatory=$true)][string]$ReportPath)
$ErrorActionPreference='Stop';$env:PSModulePath=Join-Path $PSHOME 'Modules'
$base=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Test-CleanupCompletedSwitch.ps1'),[Text.Encoding]::UTF8)
$start=$base.IndexOf('$base=[IO.File]');$end=$base.IndexOf("try{`n "+'$f=SwitchFixture;')
if($end -lt 0){$end=$base.IndexOf("try{`r`n "+'$f=SwitchFixture;')}
if($start -lt 0 -or $end -le $start){throw 'Completed-switch fixture boundary changed'}
$fixturePrefix=$base.Substring($start,$end-$start).Replace('$PSScriptRoot',("'"+$PSScriptRoot.Replace("'","''")+"'"))
. ([scriptblock]::Create($fixturePrefix))
# Worker uses -IsolatedTest; in-process cleanup also needs a private inventory.
# Keep the real PID/birth check so LiveRecordedProcess still proves protection.
$fixtureRuntimeModule=Import-Module (Join-Path $SourceDirectory 'RuntimeBridge.psm1') -PassThru -DisableNameChecking
$originalProcessInventory=& $fixtureRuntimeModule {(Get-Item Function:Get-TCProcessInventory).ScriptBlock}
& $fixtureRuntimeModule {function script:Get-TCProcessInventory {param($Manifest) @()}}
function FailedFixture {
 $f=SwitchFixture
 $result=& $ct {param($root,$target)
  $script:SimulatedConnectionState='Stopped';$script:SimulatedIdentity=$null
  $script:TestAdapter={param($op,$r,$data)
   switch($op){
    {$_ -in @('ReadBoundary','Preflight','ValidateIntent')}{return $true}
    'Preferences'{return CTRead (Join-Path $r 'ui-preferences.json')}
    'Observe'{
     $d=CTRead (Join-Path $r 'deployment.json');$m=CTRead $d.ManifestPath
     if($script:SimulatedIdentity){$o=$script:SimulatedIdentity|ConvertTo-Json -Depth 10|ConvertFrom-Json;$o.State=$script:SimulatedConnectionState;$o.ManifestPath=$d.ManifestPath;$o.CandidateSHA256=$m.CandidateSHA256;return $o}
     return [pscustomobject]@{State='Stopped';OwnershipKnown=$true;ManifestPath=$d.ManifestPath;CandidateSHA256=$m.CandidateSHA256;SessionId='initial-stopped';Mode='rule';Exit='hk';Daily='direct';Guard='Protected'}
    }
    'Start'{
     $d=CTRead (Join-Path $r 'deployment.json');$m=CTRead $d.ManifestPath;$birth=[DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o')
     $script:SimulatedIdentity=[pscustomobject]@{State='Running';OwnershipKnown=$true;ManifestPath=$d.ManifestPath;CandidateSHA256=$m.CandidateSHA256;SessionId=[guid]::NewGuid().ToString('N');EnginePid=2147480000;EngineStartedAt=$birth;SupervisorPid=2147480001;SupervisorStartedAt=$birth;Mode='rule';Exit='hk';Daily='direct';Guard='Protected'}
     $script:SimulatedConnectionState='Running'
     CTWrite (Join-Path $r 'runtime.json') ([pscustomobject]@{SchemaVersion=2;State='Running';CleanupError=$false;OwnershipKnown=$true;SessionId=$script:SimulatedIdentity.SessionId;ManifestPath=$d.ManifestPath;ConfigPath=$m.CandidatePath;EnginePid=2147480000;EngineStartedAt=$birth;SupervisorPid=2147480001;SupervisorStartedAt=$birth;StartedAt=$birth;TradingDirectAccessBlocked=$true;FinishedAt=$null})
     return $true
    }
    'ApplyIntent'{return $true}
    'Verify'{return [pscustomobject]@{ExitHttp=$false;DnsHttps=$false;ExitVerified=$false;ObservedIP=$null;Code='TraceFailedOrInconsistent'}}
    {$_ -in @('StopOriginal','StopOwnedCandidate')}{
     $script:SimulatedConnectionState='Stopped';$s=CTRead (Join-Path $r 'runtime.json');$s.State='Disconnected';$s.FinishedAt=[DateTimeOffset]::UtcNow.ToString('o');CTWrite (Join-Path $r 'runtime.json') $s;return $true
    }
    default{throw ('Forbidden test runtime operation '+$op)}
   }
  }
  try{Invoke-CTSessionSwitch -Root $root -ManifestPath $target -Intent $null -SessionLockHeld $false -RequestId ([guid]::NewGuid().ToString('N'))}finally{$script:TestAdapter=$null}
 } $f.Root $f.TargetManifest
 Check ($result.Status -ceq 'RolledBack' -and -not $result.Activated -and $result.ConfigurationRestored -and $result.ConnectionRestored) 'Real connection executor fails verification and restores the original disconnected state'
 $path=Join-Path $f.Root ('connection-transactions\'+$result.TransactionId+'.json');$tx=Read-TCDJson $path
 Check ($tx.StoppedReferenceRelease.State -ceq 'Completed' -and -not (Read-TCDJson (Join-Path $f.Root 'runtime.json')).ManifestPath) 'New failed rollback releases its own stopped dependency and preserves its historical identity'
 # Recreate only the legacy stale snapshot from the real executor's journal,
 # so the cleanup migration is tested against the exact previous failure.
 & $ct {param($snapshot)CTRestoreFile $snapshot} $tx.StoppedReferenceRelease.Original
 $f|Add-Member NoteProperty FailedTransactionPath $path;$f|Add-Member NoteProperty FailedTransactionId $result.TransactionId
 return $f
}
function OriginalFiles {param($f)
 foreach($relative in @('runtime.json','deployment.json','ui-preferences.json','Product\index.json',('Product\nodes\'+$f.Target+'\manifest.json'),('Product\nodes\'+$f.Active+'\manifest.json'),('Product\nodes\'+$f.Active+'\device.key'))){$path=Join-Path $f.Root $relative;[pscustomobject]@{Path=$path;Hash=(Hash $path)}}
}
try{
 $f=FailedFixture;$before=@(OriginalFiles $f);$preview=NewPreview $f
 Check ($preview.PreviewToken -and $preview.EligibleCount -eq 1 -and $preview.ReferenceReleaseCount -eq 1) 'Actual Worker approves one legacy failed line and one precisely bound historical reference release'
 foreach($row in $before){Check ((Hash $row.Path) -ceq $row.Hash) 'Preview is read-only'}
 $result=Worker $f @{Action='RecordDeleteCommit';PreviewToken=$preview.PreviewToken}
 Check ($result.Ok -and $result.Data.DataDeleted -and $result.Data.DeletedLineIds -contains $f.Target -and $result.Data.DeletedLineIds -notcontains $f.Active) 'Actual Worker reports the exact deleted line'
 $index=Read-TCDJson (Join-Path $f.Root 'Product\index.json');$s=Read-TCDJson (Join-Path $f.Root 'runtime.json')
 Check ($index.nodes.Count -eq 1 -and $index.nodes[0].id -ceq $f.Active -and -not (Test-Path $f.TargetManifest)) 'Deleting failed B leaves A in the authoritative index'
 Check (-not $s.ManifestPath -and -not $s.ConfigPath -and $s.State -ceq 'Disconnected' -and -not $s.CleanupError -and $s.TradingDirectAccessBlocked) 'Stopped runtime retains protection and no dangling candidate reference'
 foreach($row in @($before|Where-Object {$_.Path -notlike '*\runtime.json' -and $_.Path -notlike '*\index.json' -and $_.Path -notlike ('*\'+$f.Target+'\*')})){Check ((Hash $row.Path) -ceq $row.Hash) 'Remaining line, saved selection and keys retain their exact bytes'}
 AssertRemainingConnectable $f
 $again=Worker $f @{Action='RecordDeleteCommit';PreviewToken=$preview.PreviewToken};Check ($again.Ok -and $again.Data.AlreadyApplied) 'Repeated submission reads the original committed outcome'
 foreach($case in @('CleanupError','CleanupFlagWrongType','OwnershipFlagWrongType','Starting','MissingBirth','MismatchedIdentity','RollbackUnproved','RollbackFlagWrongType','ChangedRestoredConfiguration','ChangedRestoredManifest','UnresolvedTransaction','ProxyRecovery','LiveRecordedProcess','UnknownProcess','AfterPreviewConnect','AfterReleaseFailure','ForgedRuntimeWrite','SelectedStopped')){
  $f=FailedFixture;$s=Read-TCDJson (Join-Path $f.Root 'runtime.json');$tx=Read-TCDJson $f.FailedTransactionPath;$runtimeModule=$null;$inventoryFunction=$null
  switch($case){
   CleanupError {$s.CleanupError=$true;Put (Join-Path $f.Root 'runtime.json') $s}
   CleanupFlagWrongType {$s.CleanupError='false';Put (Join-Path $f.Root 'runtime.json') $s}
   OwnershipFlagWrongType {$s.OwnershipKnown='true';Put (Join-Path $f.Root 'runtime.json') $s}
   Starting {$s.State='Starting';Put (Join-Path $f.Root 'runtime.json') $s}
   MissingBirth {$s.EngineStartedAt='';Put (Join-Path $f.Root 'runtime.json') $s}
   MismatchedIdentity {$s.SessionId=[guid]::NewGuid().ToString('N');Put (Join-Path $f.Root 'runtime.json') $s}
   RollbackUnproved {$tx.ConfigurationRestored=$false;Put $f.FailedTransactionPath $tx}
   RollbackFlagWrongType {$tx.ConfigurationRestored='true';$tx.ConnectionRestored='true';Put $f.FailedTransactionPath $tx}
   ChangedRestoredConfiguration {$d=Read-TCDJson (Join-Path $f.Root 'deployment.json');$d|Add-Member NoteProperty ChangedAfterRollback $true;Put (Join-Path $f.Root 'deployment.json') $d}
   ChangedRestoredManifest {$m=Read-TCDJson $tx.Original.Manifest.Path;$m|Add-Member NoteProperty ChangedAfterRollback $true;Put $tx.Original.Manifest.Path $m}
   UnresolvedTransaction {$tx.Status='NeedsRecovery';$tx.Phase='NeedsRecovery';Put $f.FailedTransactionPath $tx}
   ProxyRecovery {Put (Join-Path $f.Root ('proxy-recovery\'+[guid]::NewGuid().ToString('N')+'.json')) @{SchemaVersion=1;Stage='Conflict'}}
   LiveRecordedProcess {$p=[Diagnostics.Process]::GetCurrentProcess();$s.EnginePid=$PID;$s.EngineStartedAt=$p.StartTime.ToUniversalTime().ToString('o');$p.Dispose();$tx.CandidateIdentity.EnginePid=$s.EnginePid;$tx.CandidateIdentity.EngineStartedAt=$s.EngineStartedAt;Put (Join-Path $f.Root 'runtime.json') $s;Put $f.FailedTransactionPath $tx}
   UnknownProcess {
    $runtimeModule=Import-Module (Join-Path $SourceDirectory 'RuntimeBridge.psm1') -PassThru -DisableNameChecking
    $inventoryFunction=& $runtimeModule {(Get-Item Function:Get-TCProcessInventory).ScriptBlock}
    & $runtimeModule {function script:Get-TCProcessInventory {param($Manifest) [pscustomobject]@{Name='sing-box.exe';ProcessId=2147480002;ParentProcessId=0;ExecutablePath='';CommandLine='';CreationDate=[DateTime]::UtcNow}}}
   }
   SelectedStopped {
    $tx.Status='Completed';$tx.Phase='Completed';Put $f.FailedTransactionPath $tx
    Put (Join-Path $f.Root 'deployment.json') @{ManifestPath=$tx.ActiveManifestPath;LineId=$f.Target;TransactionId=$tx.Id;ProfileId='Udp'}
   }
  }
  try{$preview=New-TCLocalDeploymentCleanupPreview $f.Root @('Line:'+$f.Target)}finally{if($inventoryFunction){& $runtimeModule {param($s)Set-Item Function:script:Get-TCProcessInventory $s} $inventoryFunction}}
  if($case -eq 'AfterPreviewConnect'){
   Check ([bool]$preview.PreviewToken) 'Stale-state fixture starts with an eligible preview';$s.State='Running';$s.SessionId=[guid]::NewGuid().ToString('N');Put (Join-Path $f.Root 'runtime.json') $s
   $rejected=$false;try{$null=Remove-TCLocalDeploymentData $f.Root $preview.PreviewToken}catch{$rejected=$_.Exception.Message -match 'CleanupPreviewStale'}
   Check ($rejected -and (Test-Path $f.TargetManifest)) 'Reconnection after preview invalidates the original confirmation'
  }elseif($case -eq 'AfterReleaseFailure'){
   Check ([bool]$preview.PreviewToken) 'Rollback fixture starts eligible';$hashes=@(OriginalFiles $f);$assert=& $history {(Get-Item Function:LCAssertRetained).ScriptBlock}
   & $history {function script:LCAssertRetained {param($Plan)throw 'Injected failure after reference release'}}
   $rejected=$false
   try{$null=Remove-TCLocalDeploymentData $f.Root $preview.PreviewToken}catch{$rejected=$_.Exception.Message -match 'CleanupRolledBack'}finally{& $history {param($s)Set-Item Function:script:LCAssertRetained $s} $assert}
   Check $rejected 'Failure after releasing references rolls the cleanup back'
   foreach($row in $hashes){Check ((Hash $row.Path) -ceq $row.Hash) 'Rollback restores original runtime, selection, index and line bytes'}
  }elseif($case -eq 'ForgedRuntimeWrite'){
   $rejected=& $history {param($r,$id)
    $p=LCPlan $r @('Line:'+$id);$path=Join-Path $r 'runtime.json';$value=$p.Replacements[$path];$value.TradingDirectAccessBlocked=$false
    $item=[pscustomobject]@{Path=$path;Hash=(Get-FileHash -LiteralPath $path).Hash;Stash='000000.stash';Replace=$true;Value=$value;ReferenceRelease=$p.ReferenceReleases[$path]}
    $journal=[pscustomobject]@{SchemaVersion=1;RootDigest=(Get-TCDDigest $r.ToLowerInvariant());UserSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;Id=[guid]::NewGuid().ToString('D');Status='Preparing';Items=@($item)}
    try{LCValidateJournal $r $journal;return $false}catch{return $_.Exception.Message -match 'CleanupJournalInvalid'}
   } $f.Root $f.Target
   Check ($rejected -and (Test-Path $f.TargetManifest)) 'Journal cannot use reference release to modify protection or unrelated runtime fields'
  }elseif($case -eq 'SelectedStopped'){
   Check ($preview.PreviewToken -and $preview.ReferenceReleaseCount -eq 2) 'A verified stopped selected line releases both exact dependency records'
   $null=Remove-TCLocalDeploymentData $f.Root $preview.PreviewToken
   $d=Read-TCDJson (Join-Path $f.Root 'deployment.json');Check (-not $d.ManifestPath -and $d.Stage -ceq 'Unconfigured') 'Deleting the selected stopped line preserves an explicit unconfigured record'
  }else{Check (-not $preview.PreviewToken -and $preview.Blocked.Count -gt 0 -and (Test-Path $f.TargetManifest)) ('Uncertain or active ownership stays protected: '+$case)}
  $cases.Add([pscustomobject]@{Case=$case;Blocked=@($preview.Blocked|ForEach-Object Code)})
 }
}catch{$failure=$_.Exception.Message;$stack=$_.ScriptStackTrace}finally{& $fixtureRuntimeModule {param($s)Set-Item Function:script:Get-TCProcessInventory $s} $originalProcessInventory}
$report=[pscustomobject]@{Passed=(-not $failure);Checks=$checks.Count;Assertions=$checks.ToArray();Cases=$cases.ToArray();Error=$failure;Stack=$stack;SourceDirectory=$SourceDirectory;PowerShell=$PSVersionTable.PSVersion.ToString();ActualCleanupWorker=$true;ActualConnectionExecutor=$true;RuntimeNetworkBoundary='Private synthetic adapter';NetworkUsed=$false;ProductionWrites=0;Fixtures=$fixtures.ToArray()}
[IO.File]::WriteAllText($ReportPath,($report|ConvertTo-Json -Depth 10),(New-Object Text.UTF8Encoding($true)))
$report|Select-Object Passed,Checks,Error,Stack|ConvertTo-Json
if(-not $failure){foreach($root in $fixtures){$full=[IO.Path]::GetFullPath($root);if(-not $full.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -cnotmatch '^TradeChannel-worker-fixture-[a-f0-9]{32}$' -or @(Get-ChildItem -LiteralPath $full -Recurse -Force|Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count){throw 'Unsafe fixture cleanup'};Remove-Item -LiteralPath $full -Recurse -Force}}
if($failure){exit 1}
