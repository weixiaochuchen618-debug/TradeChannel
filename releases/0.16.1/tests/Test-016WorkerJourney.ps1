#requires -Version 5.1
[CmdletBinding()]param([Alias('SourceDirectory')][string]$PackageRoot='',[string]$ReportDirectory='')
$ErrorActionPreference='Stop';Set-StrictMode -Version 2.0
if(-not $PackageRoot){$PackageRoot=Split-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) -Parent};$PackageRoot=[IO.Path]::GetFullPath($PackageRoot)
$workspaceRoot=Split-Path (Split-Path $PackageRoot -Parent) -Parent;$allowedReport=[IO.Path]::GetFullPath((Join-Path $workspaceRoot 'reports\release-0.16.1'))
if(-not $ReportDirectory){$ReportDirectory=$allowedReport};if([IO.Path]::GetFullPath($ReportDirectory).TrimEnd('\') -ine $allowedReport.TrimEnd('\')){throw 'Journey evidence is restricted to release-0.16.1 reports.'}
$nonce=[guid]::NewGuid().ToString('N');$tempBase=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\');$fixture=Join-Path $tempBase ('TradeChannel-worker-fixture-'+$nonce);$jobs=Join-Path $fixture 'Product\jobs'
$checks=New-Object 'Collections.Generic.List[string]';$steps=New-Object 'Collections.Generic.List[object]';$workerCount=0
function Guard {param([string]$Path,[switch]$Root) $p=[IO.Path]::GetFullPath($Path).TrimEnd('\');foreach($blocked in @($env:ProgramData,[Environment]::GetFolderPath('CommonApplicationData'),'C:\ProgramData')){if($blocked){$b=[IO.Path]::GetFullPath($blocked).TrimEnd('\');if($p.Equals($b,[StringComparison]::OrdinalIgnoreCase) -or $p.StartsWith($b+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Production data is forbidden.'}}};if(-not $p.StartsWith($fixture+'\',[StringComparison]::OrdinalIgnoreCase) -and -not ($Root -and $p -ceq $fixture)){throw 'Outside owned worker fixture.'};return $p}
function Check {param([bool]$Value,[string]$Name) if(-not $Value){throw ('Worker journey assertion failed: '+$Name)};$checks.Add($Name)}
function Hash {param([string]$Path) (Get-FileHash -LiteralPath (Guard $Path) -Algorithm SHA256).Hash}
function JWrite {param([string]$Path,$Value) Write-TCDJson (Guard $Path) $Value}
function JRead {param([string]$Path) Read-TCDJson (Guard $Path)}
function InvokeWorker {
 param([hashtable]$Request,[switch]$AllowFailure)
 $id=[guid]::NewGuid().ToString('N');$requestPath=Guard (Join-Path $jobs ($id+'.request.json'));$resultPath=Guard (Join-Path $jobs ($id+'.result.json'));JWrite $requestPath $Request
 $arguments=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',('"'+(Join-Path $PackageRoot 'Worker.ps1')+'"'),'-RequestPath',('"'+$requestPath+'"'),'-ResultPath',('"'+$resultPath+'"'),'-IsolatedTest','-TestRoot',('"'+$fixture+'"'))
 $process=Start-Process -FilePath (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $arguments -WindowStyle Hidden -PassThru
 try{
  $script:workerCount++;if(-not $process.WaitForExit(45000)){$process.Kill();throw 'Owned isolated Worker exceeded timeout.'}
  if(-not [IO.File]::Exists($resultPath)){throw 'Isolated Worker produced no result.'};$result=[IO.File]::ReadAllText($resultPath,[Text.Encoding]::UTF8)|ConvertFrom-Json
  $steps.Add([pscustomobject]@{Action=$Request.Action;ProcessId=$process.Id;Ok=[bool]$result.Ok})
  if(-not $result.Ok -and -not $AllowFailure){throw ('Worker '+$Request.Action+' failed: '+$result.Message)}
  return $result
 }finally{$process.Dispose()}
}
$null=Guard $fixture -Root;if([IO.Directory]::Exists($fixture)){throw 'Fixture must not preexist.'}
Import-Module (Join-Path $PackageRoot 'DeploymentStore.psm1') -DisableNameChecking
$null=New-TCDDirectory $jobs;[IO.File]::WriteAllText((Join-Path $fixture '.tc-fixture-owned'),$nonce)
$channelBefore=@(Get-Process -Name 'sing-box','NinjaTrader','TradeChannelDeployHost' -ErrorAction SilentlyContinue|ForEach-Object {$_.Id}|Sort-Object)
try{
 $created=InvokeWorker @{Action='DeploymentCreate';Intent='New';Connection=@{Host='192.0.2.70';Port=22;User='root';IdentityFile=''};Name='完整隔离流程草稿';Transport='Auto';TcpPort=443;ServerName='www.bing.com'}
 $runId=[string]$created.Data.RunId;$serverId=[string]$created.Data.ServerRecordId;$recordId='DeploymentRun:'+$runId;$runPath=Join-Path $fixture ('deployments\runs\'+$runId+'\state.json');$registryPath=Join-Path $fixture 'servers\registry.json'
 Check ($created.Data.Stage -ceq 'PrepareAccess' -and -not $created.Data.NetworkChanged) 'A real Worker creates only a local input draft'

 # A separate saved line is present throughout the lifecycle. Its content and
 # index must remain byte-identical; no engine or network actor is started.
 $lineId=[guid]::NewGuid().ToString('D');$lineDirectory=Join-Path $fixture ('Product\nodes\'+$lineId);$configPath=Join-Path $lineDirectory 'candidate.json';$manifestPath=Join-Path $lineDirectory 'manifest.json';$indexPath=Join-Path $fixture 'Product\index.json'
 JWrite $configPath @{FixtureOnly=$true;Mode='Udp'}
 JWrite $manifestPath @{SchemaVersion=1;node_id=$lineId;TCManagedNodeId=$lineId;SyntaxValidated=$true;CandidatePath=$configPath;CandidateSHA256=(Hash $configPath);ServerPublicKey=('L'*43+'=');ClientPublicKey=('C'*43+'=')}
 JWrite $indexPath @{schemaVersion=1;nodes=@(@{id=$lineId;name='不应改动的既有线路';kind='wireguard';manifestPath=$manifestPath;status='CandidateOnly'});tradeDomains=@('example.invalid')}
 $before=@{Run=(Hash $runPath);Registry=(Hash $registryPath);Index=(Hash $indexPath);Config=(Hash $configPath);Manifest=(Hash $manifestPath)}

 $center=InvokeWorker @{Action='DeploymentCenter'};$drafts=@($center.Data.DraftItems)
 Check ($drafts.Count -eq 1 -and $drafts[0].Id -ceq $recordId -and $drafts[0].CanDiscardDraft) 'Center merges input task and provisional server into one actionable draft'
 Check (@($center.Data.AttentionItems).Count -eq 0 -and @($center.Data.ContinueItems).Count -eq 0) 'Pure input is not presented as recovery or deployed progress'
 $detail=InvokeWorker @{Action='OperationRecordDetail';Id=$recordId}
 Check ($detail.Data.Id -ceq $recordId -and $detail.Data.CanDiscardDraft -and -not $detail.Data.CanResume) 'Detail provides correct discard eligibility without pretending continuation'

 $preview=InvokeWorker @{Action='DraftDiscardPreview';Ids=@($recordId)}
 Check ($preview.Data.EligibleCount -eq 1 -and $serverId -in @($preview.Data.WillSuppressServerIds)) 'Worker preview binds the draft and its otherwise empty registration'
 Check ((Hash $runPath) -ceq $before.Run -and (Hash $registryPath) -ceq $before.Registry) 'Read-only preview changes no task or registry source'
 $committed=InvokeWorker @{Action='DraftDiscardCommit';PreviewToken=[string]$preview.Data.PreviewToken}
 Check ($recordId -in @($committed.Data.DiscardedIds) -and -not $committed.Data.DataDeleted -and -not $committed.Data.RemoteChanges) 'Worker commit only records local abandonment'

 $newCenter=InvokeWorker @{Action='DeploymentCenter'}
 Check (@($newCenter.Data.DraftItems).Count -eq 0 -and @($newCenter.Data.Cards|Where-Object ServerRecordId -ceq $serverId).Count -eq 0 -and @($newCenter.Data.DraftServers|Where-Object ServerRecordId -ceq $serverId).Count -eq 0) 'A fresh Worker cannot recreate the discarded task or ghost server card'
 $discovery=InvokeWorker @{Action='DeploymentDiscover'}
 Check (@($discovery.Data.Servers|Where-Object LocalRecordId -ceq $serverId).Count -eq 0 -and @($discovery.Data.ContinueRuns|Where-Object RunId -ceq $runId).Count -eq 0) 'Legacy discovery also honors the disposition barrier'
 $disposition=InvokeWorker @{Action='DraftDisposition'};$discarded=@($disposition.Data.Records|Where-Object Id -ceq $recordId)
 Check ($discarded.Count -eq 1 -and $discarded[0].Discarded -and $discarded[0].Name -ceq '完整隔离流程草稿') 'History gets a named abandoned input from a separate process'
 $history=InvokeWorker @{Action='OperationHistory';IncludeHidden=$true}
 Check (@($history.Data|Where-Object {$_.Id -ceq $recordId -and $_.Discarded}).Count -eq 1) 'Unified history retains the original record and its disposition'
 $import=InvokeWorker @{Action='ServerImportLegacy'}
 Check ($import.Data.Imported -eq 0) 'Legacy index refresh cannot recreate absent source lineage'
 $afterImport=InvokeWorker @{Action='DeploymentCenter'}
 Check (@($afterImport.Data.DraftItems).Count -eq 0) 'Import and refresh do not revive the abandoned addition'

 $restore=InvokeWorker @{Action='DraftRestore';Id=$recordId}
 Check ($restore.Data.Restored -and $restore.Data.RequiresReview -and -not $restore.Data.ApprovalsRestored) 'Worker restore requires review and restores no authorization'
 $restoredCenter=InvokeWorker @{Action='DeploymentCenter'};$visible=@($restoredCenter.Data.DraftItems|Where-Object Id -ceq $recordId)
 Check ($visible.Count -eq 1 -and $visible[0].CanDiscardDraft -and -not $visible[0].Discarded) 'A new process shows exactly one restored input draft'
 $replayed=InvokeWorker @{Action='DraftDiscardCommit';PreviewToken=[string]$preview.Data.PreviewToken}
 Check ($replayed.Data.AlreadyApplied -and $replayed.Data.DiscardedCount -eq 0) 'Replaying the original token after restore remains a no-op'
 $stillVisible=InvokeWorker @{Action='DeploymentCenter'}
 Check (@($stillVisible.Data.DraftItems|Where-Object Id -ceq $recordId).Count -eq 1) 'Token replay cannot silently reverse the user restore'
 Check ((Hash $runPath) -ceq $before.Run -and (Hash $registryPath) -ceq $before.Registry) 'Original run and server registry remain byte-identical end to end'
 Check ((Hash $indexPath) -ceq $before.Index -and (Hash $configPath) -ceq $before.Config -and (Hash $manifestPath) -ceq $before.Manifest) 'Unrelated line index configuration and manifest remain byte-identical'

 # A sequence of separate Worker processes exercises the record list API.
 $legacyIds=@([guid]::NewGuid().ToString('D'),[guid]::NewGuid().ToString('D'));$recordIds=@($recordId)
 foreach($id in $legacyIds){
  $recordIds+=,('LegacyLinuxJob:'+$id)
  JWrite (Join-Path $fixture ('linux-jobs\'+$id+'\job.json')) @{SchemaVersion=1;JobId=$id;Operation='Apply';Name='Linux record fixture';CreatedAtUtc=[DateTime]::UtcNow.ToString('o')}
  JWrite (Join-Path $fixture ('linux-jobs\'+$id+'\result.json')) @{SchemaVersion=1;JobId=$id;Operation='Apply';Status='Failed';Stage='Backend';FinishedAtUtc=[DateTime]::UtcNow.ToString('o')}
 }
 $list=InvokeWorker @{Action='OperationHistory';IncludeHidden=$false}
 Check (@($list.Data|Where-Object CanDeleteRecord).Count -eq 3) 'Real Worker exposes deletion eligibility for unfinished and unidentified records'
 $deletePreview=InvokeWorker @{Action='RecordDeletePreview';Ids=$recordIds}
 Check ($deletePreview.Data.EligibleCount -eq 3 -and $deletePreview.Data.ProtectedCount -eq 0) 'Worker batch preview accepts the exact selected records'
 $delete=InvokeWorker @{Action='RecordDeleteCommit';PreviewToken=[string]$deletePreview.Data.PreviewToken}
 Check ($delete.Data.DeletedCount -eq 3 -and -not $delete.Data.DataDeleted) 'A different Worker persists only display deletion'
 $normal=InvokeWorker @{Action='OperationHistory';IncludeHidden=$false}
 Check (@($normal.Data|Where-Object {$_}).Count -eq 0) 'Next Worker reads an empty normal history after all selected records are removed'
 $removed=InvokeWorker @{Action='OperationHistory';IncludeHidden=$true}
 Check (@($removed.Data|Where-Object Deleted).Count -eq 3) 'Next Worker reads every deleted record for recovery'
 $removedCenter=InvokeWorker @{Action='DeploymentCenter'}
 Check (@($removedCenter.Data.DraftItems).Count -eq 0 -and @($removedCenter.Data.AttentionItems).Count -eq 0) 'Center cannot recreate a linked server card after record deletion'
 $recordRestore=InvokeWorker @{Action='RecordRestore';Id=$recordId}
 Check ($recordRestore.Data.Restored) 'Independent Worker restores the exact original preparation record'
 $deleteReplay=InvokeWorker @{Action='RecordDeleteCommit';PreviewToken=[string]$deletePreview.Data.PreviewToken}
 Check ($deleteReplay.Data.AlreadyApplied -and $deleteReplay.Data.DeletedCount -eq 0) 'Cross-process token replay remains a no-op after restore'
 $afterRestore=InvokeWorker @{Action='DeploymentCenter'}
 Check (@($afterRestore.Data.DraftItems|Where-Object Id -ceq $recordId).Count -eq 1) 'Restored preparation stays visible after replay'
 Check ((Hash $runPath) -ceq $before.Run -and (Hash $registryPath) -ceq $before.Registry -and (Hash $indexPath) -ceq $before.Index -and (Hash $configPath) -ceq $before.Config -and (Hash $manifestPath) -ceq $before.Manifest) 'Record-management Worker journey preserves all deployment and connection source bytes'
 $detailDeleted=InvokeWorker @{Action='OperationRecordDetail';Id=$recordIds[1]}
 Check ($detailDeleted.Data.Deleted -and $detailDeleted.Data.EntryAction -eq 'ViewRecord') 'Deleted legacy detail is read-only through the real Worker'
 $blocked=InvokeWorker @{Action='Session';SessionAction='Disconnect'} -AllowFailure
 Check (-not $blocked.Ok -and $blocked.Message -match '禁止') 'Isolated worker denies production session actions'
 $channelAfter=@(Get-Process -Name 'sing-box','NinjaTrader','TradeChannelDeployHost' -ErrorAction SilentlyContinue|ForEach-Object {$_.Id}|Sort-Object)
 Check (($channelBefore -join ',') -ceq ($channelAfter -join ',')) 'No channel trading or deployment executor process is started or stopped'
 $report=[pscustomobject]@{Passed=$true;Checks=$checks.Count;Assertions=$checks.ToArray();WorkerProcesses=$workerCount;Steps=$steps.ToArray();PackageRoot=$PackageRoot;FixtureType='Owned isolated temporary data root';ProductionDataTouched=$false;NetworkUsed=$false;OriginalRunUnchanged=$true;OriginalServerRegistryUnchanged=$true;UnrelatedLineUnchanged=$true;VerifiedAtUtc=[DateTime]::UtcNow.ToString('o')}
 $null=New-Item -ItemType Directory -Path $ReportDirectory -Force;$json=ConvertTo-Json -InputObject $report -Depth 8;[IO.File]::WriteAllText((Join-Path $ReportDirectory 'Test-016WorkerJourney.json'),$json,(New-Object Text.UTF8Encoding($true)));$json
}finally{
 $clean=Guard $fixture -Root;$marker=Join-Path $clean '.tc-fixture-owned'
 if($clean -cne (Join-Path $tempBase ('TradeChannel-worker-fixture-'+$nonce)) -or -not [IO.File]::Exists($marker) -or [IO.File]::ReadAllText($marker) -cne $nonce){throw 'Fixture ownership check failed.'}
 Remove-Item -LiteralPath $clean -Recurse -Force -ErrorAction Stop
}
