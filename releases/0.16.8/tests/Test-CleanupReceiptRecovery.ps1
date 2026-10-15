#requires -Version 5.1
#requires -PSEdition Desktop
param([string]$SourceDirectory=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';Set-StrictMode -Version 2.0
$workspace=Join-Path ([IO.Path]::GetTempPath()) ('tc-cleanup-receipt-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($workspace);$checks=New-Object 'Collections.Generic.List[string]'
$script:PackageRoot=$SourceDirectory;$script:ReadOnly=$false;$script:Footer=[pscustomobject]@{Text=''};$script:Job=$null
Import-Module (Join-Path $SourceDirectory 'DeploymentStore.psm1') -DisableNameChecking
Import-Module (Join-Path $SourceDirectory 'ServerRegistry.psm1') -DisableNameChecking
$module=Import-Module (Join-Path $SourceDirectory 'OperationHistory.psm1') -PassThru -DisableNameChecking
. (Join-Path $SourceDirectory 'ui\BackgroundJobs.ps1')
function Check {param($Value,[string]$Label)if(-not $Value){throw ('FAIL: '+$Label)};$checks.Add($Label)}
function Fixture {param([string]$Name)
 $script:Root=New-TCDDirectory (Join-Path $workspace $Name);$script:JobRoot=New-TCDDirectory (Join-Path $script:Root 'Product\jobs')
 $script:UncertainUiJobs.Clear();$script:UiJobRecoveryLoaded=$false
 $server=Set-TCServerRecord -Root $script:Root -Connection @{Host='192.0.2.88';Port=22;User='root';IdentityFile=''} -Name '本机恢复夹具'
 $preview=New-TCLocalDeploymentCleanupPreview -Root $script:Root -Ids @('ServerRecord:'+$server.LocalRecordId)
 [pscustomobject]@{Root=$script:Root;Server=$server;Preview=$preview}
}
function Receipt {param([string]$Action,[string]$Token='')
 $id=[guid]::NewGuid().ToString('N')
 $request=@{Action=$Action;RequestId=$id};if($Token){$request.PreviewToken=$Token}
 $r=@{SchemaVersion=1;Action=$Action;RequestId=$id;RunId='';LineId='';TransactionId='';ResourceScope=@{Kind='Global'};Status='OutcomeUnknown';StartedAtUtc=[DateTime]::UtcNow.ToString('o');ProcessId=0;ProcessStartedTicks=0}
 Write-TCDJson (Join-Path $script:JobRoot ($id+'.request.json')) $request;Write-TCDJson (Join-Path $script:JobRoot ($id+'.receipt.json')) $r
 return $id
}
function ReadReceipt {param([string]$Id) Read-TCDJson (Join-Path $script:JobRoot ($Id+'.receipt.json'))}
function Blocked {TestUiMutationBlocked @{Action='DeploymentCreate';Connection=@{Host='192.0.2.88';Port=22;User='root'}} @{Kind='DeploymentServer';Host='192.0.2.88';Port=22;User='root';ServerRecordId='';RunId=''}}
try{
 $f=Fixture completed;$null=Remove-TCLocalDeploymentData -Root $f.Root -PreviewToken $f.Preview.PreviewToken
 $id=Receipt RecordDeleteCommit $f.Preview.PreviewToken
 RestoreUiJobReceipts
 Check (-not (Blocked) -and $script:UncertainUiJobs.Count -eq 0) 'Completed cleanup with lost worker result cannot keep the global deployment gate blocked'
 Check ((ReadReceipt $id).Status -eq 'Reconciled' -and (ReadReceipt $id).Resolution.Outcome -eq 'Completed') 'Completed journal is bound to the original request token and recorded as reconciled'
 $f=Fixture committed;$null=Remove-TCLocalDeploymentData -Root $f.Root -PreviewToken $f.Preview.PreviewToken
 & $module {param($Root,$Preview)
  $token=LCToken -Root $Root -Token $Preview.PreviewToken;$path=LCJournalPath $Root $token.Id;$journal=LCRead $Root $path;$journal.Status='Committed';$journal|Add-Member NoteProperty Items @() -Force
  $stash=New-TCDDirectory (Join-Path (Split-Path $path -Parent) 'stash');[IO.File]::WriteAllText((Join-Path $stash '000000.stash'),'fixture retired copy');Write-TCDJson $path $journal
 } $f.Root $f.Preview
 $id=Receipt RecordDeleteCommit $f.Preview.PreviewToken;RestoreUiJobReceipts;Check ((Blocked)) 'Committed cleanup still requires its durable purge to finish'
 $recovered=Repair-TCLocalDeploymentCleanup -Root $f.Root;RefreshUiJobReceipts
 Check (@($recovered.CompletedResults).Count -eq 1 -and -not (Blocked) -and (ReadReceipt $id).Resolution.Outcome -eq 'Completed') 'Committed recovery publishes deleted identities and resolves its original receipt'
 $f=Fixture beforejournal;$original=(Get-FileHash (Join-Path $f.Root 'servers\registry.json')).Hash;$id=Receipt RecordDeleteCommit $f.Preview.PreviewToken
 RestoreUiJobReceipts
 Check (-not (Blocked) -and (ReadReceipt $id).Resolution.Outcome -eq 'NotApplied' -and (Get-FileHash (Join-Path $f.Root 'servers\registry.json')).Hash -ceq $original) 'Crash before journal creation requires an unchanged original snapshot and is not reported as deletion'
 $f=Fixture preparing;$original=(Get-FileHash (Join-Path $f.Root 'servers\registry.json')).Hash
 & $module {param($Root,$Preview,$ServerId)
  $token=LCToken -Root $Root -Token $Preview.PreviewToken;$path=Join-Path $Root 'servers\registry.json';$doc=LCRead $Root $path;$hash=(Get-FileHash $path).Hash
  $changed=$doc|ConvertTo-Json -Depth 20|ConvertFrom-Json;$changed.Servers=@();$base=Split-Path (LCJournalPath $Root $token.Id) -Parent;$stash=New-TCDDirectory (Join-Path $base 'stash')
  $journal=@{SchemaVersion=1;Id=$token.Id;RootDigest=$token.RootDigest;UserSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;Status='Preparing';TokenDigest=(Get-TCDDigest $Preview.PreviewToken);Items=@(@{Path=$path;Hash=$hash;Stash='000000.stash';Replace=$true;Value=$changed});Result=@{SelectedIds=@('ServerRecord:'+$ServerId);DeletedIds=@('ServerRecord:'+$ServerId);DeletedLineIds=@();DataDeleted=$true}}
  Write-TCDJson (LCJournalPath $Root $token.Id) $journal;[IO.File]::Move($path,(Join-Path $stash '000000.stash'));Write-TCDJson $path $changed
 } $f.Root $f.Preview $f.Server.LocalRecordId
 $id=Receipt RecordDeleteCommit $f.Preview.PreviewToken;RestoreUiJobReceipts
 Check ((Blocked) -and (ReadReceipt $id).Status -eq 'OutcomeUnknown') 'Pending local cleanup remains blocked until its journal is recovered'
 $recovered=Repair-TCLocalDeploymentCleanup -Root $f.Root;RefreshUiJobReceipts
 Check ($recovered.RecoveredCount -eq 1 -and -not (Blocked) -and (ReadReceipt $id).Resolution.Outcome -eq 'RolledBack' -and (Get-FileHash (Join-Path $f.Root 'servers\registry.json')).Hash -ceq $original) 'Repair restores files and clears the same in-memory gate without restarting the UI'
 $recoveryId=Receipt RecordCleanupRecover;RefreshUiJobReceipts
 Check ((ReadReceipt $recoveryId).Resolution.Outcome -eq 'NoPendingCleanup' -and -not (Blocked)) 'Lost recovery acknowledgement is reconciled only after no cleanup remains pending'
 $remote=Receipt DeploymentProceed;RefreshUiJobReceipts;RefreshUiJobReceipts
 Check ((Blocked) -and $script:UncertainUiJobs.Count -eq 1 -and (ReadReceipt $remote).Status -eq 'OutcomeUnknown') 'Repeated receipt refresh preserves one unresolved remote mutation without duplicates'
 $f=Fixture changed;$id=Receipt RecordDeleteCommit $f.Preview.PreviewToken;$null=Set-TCServerRecord -Root $f.Root -Id $f.Server.LocalRecordId -Name '已被其他操作改动';RestoreUiJobReceipts
 Check ((Blocked) -and (ReadReceipt $id).Status -eq 'OutcomeUnknown') 'Missing journal plus changed source cannot be called not-applied'
 $f=Fixture live;$null=Remove-TCLocalDeploymentData -Root $f.Root -PreviewToken $f.Preview.PreviewToken;$id=Receipt RecordDeleteCommit $f.Preview.PreviewToken;$r=ReadReceipt $id;$process=[Diagnostics.Process]::GetCurrentProcess()
 try{$r.ProcessId=$process.Id;$r.ProcessStartedTicks=$process.StartTime.ToUniversalTime().Ticks;Write-TCDJson (Join-Path $script:JobRoot ($id+'.receipt.json')) $r;RestoreUiJobReceipts;Check ((Blocked) -and (ReadReceipt $id).Status -eq 'OutcomeUnknown') 'An active executor cannot be resolved from a journal'}finally{$process.Dispose()}
 foreach($pending in @($script:UncertainUiJobs.ToArray())){if($pending.Process){$pending.Process.Dispose()}}
 $f=Fixture wrongrequest;$null=Remove-TCLocalDeploymentData -Root $f.Root -PreviewToken $f.Preview.PreviewToken;$id=Receipt RecordDeleteCommit $f.Preview.PreviewToken;$requestPath=Join-Path $script:JobRoot ($id+'.request.json');$request=Read-TCDJson $requestPath;$request.RequestId=[guid]::NewGuid().ToString('N');Write-TCDJson $requestPath $request;RestoreUiJobReceipts
 Check ((Blocked)) 'Mismatched original request cannot borrow another cleanup journal'
 [pscustomobject]@{Passed=$true;Checks=$checks.Count;Assertions=$checks.ToArray();NetworkUsed=$false;ProductionDataTouched=$false}|ConvertTo-Json -Depth 4
}finally{
 $full=[IO.Path]::GetFullPath($workspace)
 if(-not $full.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -cnotmatch '^tc-cleanup-receipt-[a-f0-9]{32}$'){throw 'Unsafe fixture cleanup'}
 Remove-Item -LiteralPath $full -Recurse -Force
}
