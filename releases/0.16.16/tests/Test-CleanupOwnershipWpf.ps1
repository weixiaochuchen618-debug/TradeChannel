#requires -Version 5.1
#requires -PSEdition Desktop
[CmdletBinding()]param([string]$PackageRoot,[string]$ReportDirectory)
$ErrorActionPreference='Stop';$env:PSModulePath=Join-Path $PSHOME 'Modules'
if(-not $PackageRoot){$PackageRoot=Split-Path $PSScriptRoot -Parent}
if(-not $ReportDirectory){$ReportDirectory=Join-Path ([IO.Path]::GetTempPath()) ('tc-cleanup-ownership-wpf-'+[guid]::NewGuid().ToString('N'))}
$harness=[IO.File]::ReadAllText((Join-Path (Split-Path $PSScriptRoot -Parent) 'ui\Test-015UI.ps1'),[Text.Encoding]::UTF8)
$preambleEnd=$harness.IndexOf('$passed=$false;$failure=''''',$harness.IndexOf('function SelectHistoryFilter'))
$setupStart=$harness.IndexOf(" ImportNamedPresentation 'TradeChannel.ps1'")
$setupEnd=$harness.IndexOf(" ResetUI;ShowSetup;Shot '015-01-single-add-line'")
if($preambleEnd -lt 0 -or $setupStart -lt 0 -or $setupEnd -le $setupStart){throw 'WPF harness boundaries changed'}
# The native Worker isolated entry deliberately accepts only this exact temp
# name. Change the disposable harness root, never a production path.
$preamble=$harness.Substring(0,$preambleEnd).Replace("'tc-ui-015-data-'","'TradeChannel-worker-fixture-'")
. ([scriptblock]::Create($preamble)) -SourceDirectory $PackageRoot -TestOutputDirectory $ReportDirectory
$passed=$false;$failure='';$failureStack='';$script:OwnedWorkers=New-Object 'Collections.Generic.List[object]'
$script:ActualRequests=New-Object 'Collections.Generic.List[object]';$script:WorkerResults=New-Object 'Collections.Generic.List[object]';$script:FileProofs=New-Object 'Collections.Generic.List[object]';$script:CleanupHeartbeats=0
function PutOwnership {param([string]$Path,$Value) Write-TCDJson (FixturePath $Path) $Value}
function OwnershipHash {param([string]$Path) (Get-FileHash -LiteralPath (FixturePath $Path) -Algorithm SHA256).Hash}
function NewOwnershipLine {
 param([string]$Name,[string]$HostAddress,[switch]$Shared)
 $server=Set-TCServerRecord -Root $script:Root -Connection @{Host=$HostAddress;Port=22;User='root';IdentityFile=''} -Name $Name -ServerInfo @{RemoteOwnerId=[guid]::NewGuid().ToString('D');Node=@{NodeId=[guid]::NewGuid().ToString('D');ServerPublicKey=('S'*43+'=')}}
 $id=[guid]::NewGuid().ToString('D');$mp=Join-Path $script:Root ('Product\nodes\'+$id+'\manifest.json')
 $key=Join-Path (Split-Path $mp) 'device.key';PutOwnership $key @{PrivateFixtureMaterial=$id}
 PutOwnership $mp @{TCLineId=$id;TCManagedNodeId=$id;ServerPublicKey=('S'*43+'=');ClientPublicKey=('C'*43+'=');SyntaxValidated=$true}
 $lp=Join-Path $script:Root ('Product\lines\'+$id+'\line.json')
 PutOwnership $lp @{SchemaVersion=2;LineId=$id;Profiles=@();SourceManifestPath=$mp;ServerPublicKey=('S'*43+'=');SavedPreference=@{Mode='Udp';Revision=7}}
 $node=[pscustomobject]@{id=$id;name=$Name;kind='wireguard';endpoint=($HostAddress+':51820');manifestPath=$mp;registeredAt=[DateTimeOffset]::UtcNow.ToString('o');status='CandidateOnly'}
 $indexPath=Join-Path $script:Root 'Product\index.json';$nodes=@();if(Test-Path -LiteralPath $indexPath){$nodes=@((Read-TCDJson $indexPath).nodes)}
 PutOwnership $indexPath @{schemaVersion=1;nodes=@($nodes)+@($node);tradeDomains=@('example.com')}
 $null=Set-TCServerLink -Root $script:Root -ServerId $server.LocalRecordId -NodeId $id
 $runId=[guid]::NewGuid().ToString('D');$state=[ordered]@{SchemaVersion=1;RunId=$runId;ServerRecordId=$server.LocalRecordId;Name=$Name;Revision=1;Intent='New';Status='Complete';Stage='ReadyInactive';CreatedAtUtc=[DateTimeOffset]::UtcNow.ToString('o');UpdatedAtUtc=[DateTimeOffset]::UtcNow.ToString('o');CandidateNodeId=$id;CandidateManifestPath=$mp}
 $sp=Join-Path $script:Root ('deployments\runs\'+$runId+'\state.json');PutOwnership $sp $state
 $client=Join-Path (Split-Path $sp) 'client';$sharedPath=Join-Path $client 'public.request.json';PutOwnership $sharedPath @{RequestId=[guid]::NewGuid().ToString('D');ClientPublicKey=('C'*43+'=')}
 $otherPath='';$otherId=''
 if($Shared){$otherId=[guid]::NewGuid().ToString('D');$otherPath=Join-Path $script:Root ('deployments\runs\'+$otherId+'\state.json');PutOwnership $otherPath @{SchemaVersion=1;RunId=$otherId;ServerRecordId=$server.LocalRecordId;Name='仍引用共享来源的准备';Revision=1;Intent='New';Status='WaitingUser';Stage='PrepareAccess';CreatedAtUtc=[DateTimeOffset]::UtcNow.ToString('o');UpdatedAtUtc=[DateTimeOffset]::UtcNow.ToString('o');RequestDirectory=$client;ReusedRequestSourceRunId=$runId;ClientRequest=@{ClientPublicKey=('C'*43+'=')}}}
 [pscustomobject]@{LineId=$id;Server=$server;Manifest=$mp;Key=$key;Line=$lp;RunId=$runId;State=$sp;Shared=$sharedPath;OtherState=$otherPath;OtherId=$otherId;Node=$node}
}
function SnapshotOwnership {param([string[]]$Paths) @($Paths|ForEach-Object {[pscustomobject]@{Path=$_;SHA256=(OwnershipHash $_)}})}
function AssertOwnershipBytes {param($Before,[string]$Label)
 $after=@($Before|ForEach-Object {[pscustomobject]@{Path=$_.Path;Before=$_.SHA256;Exists=[IO.File]::Exists($_.Path);After=$(if([IO.File]::Exists($_.Path)){OwnershipHash $_.Path}else{''})}})
 CheckUI (@($after|Where-Object {-not $_.Exists -or $_.Before -cne $_.After}).Count -eq 0) $Label
 $script:FileProofs.Add([pscustomobject]@{Check=$Label;Files=$after})
}
try{
 . ([scriptblock]::Create($harness.Substring($setupStart,$setupEnd-$setupStart)))
 . (Join-Path $script:PackageRoot 'ui\NavigationContext.ps1')
 . (Join-Path $script:PackageRoot 'ui\BackgroundJobs.ps1')
 . (Join-Path $script:PackageRoot 'ui\LineCardState.ps1')
 . (Join-Path $script:PackageRoot 'ui\LineCardControls.ps1')
 ImportNamedPresentation 'TradeChannel.ps1' @('StateKey','IsRunning','IsBusy','NodeEntry','ActiveNodeId','TradeLaneValue','OpenDeleteNode','Toast')
 $script:ToastTimer=New-Object Windows.Threading.DispatcherTimer;$script:ToastTimer.Interval=[TimeSpan]::FromSeconds(20)
 $script:ToastTimer.Add_Tick({$script:ToastTimer.Stop();$script:Window.FindName('Toast').Visibility='Collapsed'})
 $script:Smoke=$false;$script:UiReadWorkerEnabled=$false;$script:UiJobRecoveryLoaded=$true;$script:UiMemoryJobs=$null
 $null=[IO.Directory]::CreateDirectory($script:JobRoot)
 # Match TradeChannel startup: Product owns the inherited private job ACL.
 $fixtureAcl=New-Object Security.AccessControl.DirectorySecurity;$fixtureAcl.SetAccessRuleProtection($true,$false)
 foreach($sidText in @('S-1-5-18','S-1-5-32-544')){$sid=New-Object Security.Principal.SecurityIdentifier($sidText);$null=$fixtureAcl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow')))}
 Set-Acl -LiteralPath (FixturePath (Join-Path $script:Root 'Product')) -AclObject $fixtureAcl
 $aclRoot=SafeLocalPath $script:Root
 if($aclRoot -cne (Join-Path ([IO.Path]::GetTempPath()) ('TradeChannel-worker-fixture-'+$testId)) -or -not [IO.File]::Exists((Join-Path $aclRoot '.owned-ui-015'))){throw 'Fixture ACL root ownership mismatch'}
 Set-Acl -LiteralPath $aclRoot -AclObject $fixtureAcl
 foreach($name in @('DeploymentStore.psm1','ServerRegistry.psm1','OperationHistory.psm1','DeploymentFlow.psm1','RuntimeObservability.psm1')){Import-Module (Join-Path $script:PackageRoot $name) -DisableNameChecking;$null=ReadSourceAst $name}
 $null=ReadSourceAst 'LocalDeploymentCleanup.ps1';$null=ReadSourceAst 'Worker.ps1';$null=ReadSourceAst 'ui\BackgroundJobs.ps1'
 # Production StartJob writes its real request envelope. At the external
 # process boundary add the native Worker isolation switches, then launch
 # the packaged Worker itself. No request, callback or cleanup API is faked.
 function Start-Process {
  param($FilePath,$ArgumentList,[switch]$PassThru,$WindowStyle)
  if($WindowStyle -cne 'Hidden' -or [IO.Path]::GetFileName($FilePath) -ine 'powershell.exe'){throw 'Unexpected process boundary'}
  $at=[array]::IndexOf($ArgumentList,'-RequestPath');$fileAt=[array]::IndexOf($ArgumentList,'-File')
  if($at -lt 0 -or $fileAt -lt 0 -or [string]$ArgumentList[$fileAt+1] -cne ('"'+(Join-Path $script:PackageRoot 'Worker.ps1')+'"')){throw 'Expected exact packaged Worker'}
  $path=FixturePath ([string]$ArgumentList[$at+1]).Trim('"');$request=[IO.File]::ReadAllText($path)|ConvertFrom-Json
  if($request.Action -notin @('RecordDeletePreview','RecordDeleteCommit','OperationHistory','Nodes')){throw ('Forbidden Worker action '+$request.Action)}
  $script:ActualRequests.Add($request)
  $args=@($ArgumentList)+@('-IsolatedTest','-TestRoot',('"'+$script:Root+'"'))
  $p=Microsoft.PowerShell.Management\Start-Process -FilePath $FilePath -ArgumentList $args -PassThru -WindowStyle Hidden
  $script:OwnedWorkers.Add([pscustomobject]@{Process=$p;Id=$p.Id;Action=$request.Action;Arguments=$args});return $p
 }
 function UpdateChrome {$script:Window.FindName('ChipText').Text='隔离清理验收 · 真实 Worker'}
 function Render {}
 function WaitOwnershipWorker {
  param([string]$ExpectedAction)
  $job=$script:Job;CheckUI ($job -and $job.Action -ceq $ExpectedAction) ('Production dispatcher starts '+$ExpectedAction)
  $deadline=[DateTimeOffset]::UtcNow.AddSeconds(45);$raw=$null
  while([DateTimeOffset]::UtcNow -lt $deadline){
   if([IO.File]::Exists($job.Result)){$raw=[IO.File]::ReadAllText((FixturePath $job.Result))|ConvertFrom-Json;break}
   if($job.Process.HasExited){throw ('Worker exited before result: '+$ExpectedAction)}
   Start-Sleep -Milliseconds 80;$null=$script:Window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Background)
  }
  if(-not $raw){throw ('Bounded Worker wait timed out: '+$ExpectedAction)}
  $script:WorkerResults.Add([pscustomobject]@{Action=$ExpectedAction;Result=$raw})
  CheckUI ($raw.Ok -and $raw.RequestId -ceq $job.RequestId -and $raw.PageGeneration -eq $job.OriginContext.Revision) ('Actual Worker result binds '+$ExpectedAction+' identity and navigation')
  PollBackgroundJob;StopIntakeTimer
  return $raw.Data
 }
 function DrainOwnershipReads {
  for($i=0;$script:Job -and $i -lt 8;$i++){if($script:Job.Action -notin @('Nodes','OperationHistory')){throw ('Unexpected follow-up '+$script:Job.Action)};$null=WaitOwnershipWorker $script:Job.Action}
  CheckUI (-not $script:Job -and $script:JobQueue.Count -eq 0) 'Cleanup follow-up reads finish through the real queue'
 }
 function ShowOwnershipHistory {param([string]$Search='')
  $script:DeployUI.HistoryRecords=@(Get-TCOperationHistory -Root $script:Root -IncludeHidden -IncludeServerRecords);$script:DeployUI.HistoryLoaded=$true;$script:DeployUI.HistorySearchText=$Search;ShowUnifiedOperationHistory
 }
 function ConfirmOwnership {
  CheckUI ($script:Window.FindName('Overlay').Visibility -eq 'Visible' -and $script:DialogCallback) 'A visible concrete cleanup confirmation is required'
  $path=Join-Path $script:Root 'runtime-observer.json';$before=OwnershipHash $path
  $beat=Observe-TCRuntimeState -Root $script:Root -Overview $script:CleanupObservationOverview
  CheckUI ($beat.Observed -and $beat.EventsAdded -eq 0 -and (OwnershipHash $path) -cne $before) 'Actual observer refreshes the unchanged active session after preview and before the UI confirmation'
  $script:CleanupHeartbeats++
  $script:Window.FindName('DialogConfirm').RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
 }
 $shot=(Get-Command Shot).Definition.Replace('隔离 WPF · 夹具状态 · 不证明服务器部署或网络结果','隔离 WPF · Smoke=false · 正式队列与真实 Worker · 本机夹具清理').Replace(' / SMOKE / FIXTURE',' / REAL WORKER / FIXTURE')
 Set-Item Function:script:Shot ([scriptblock]::Create($shot))
 # Active line is synthetic; preserve its configuration and runtime bytes.
 $hk=NewOwnershipLine '香港主线（隔离保留夹具）' '192.0.2.254'
 PutOwnership (Join-Path $script:Root 'deployment.json') @{LineId=$hk.LineId;ManifestPath=$hk.Manifest}
 $started=[DateTimeOffset]::UtcNow.ToString('o')
 PutOwnership (Join-Path $script:Root 'runtime.json') @{State='Running';OwnershipKnown=$true;LineId=$hk.LineId;ManifestPath=$hk.Manifest;SessionId=[guid]::NewGuid().ToString('N');EngineStartedAt=$started}
 $script:CleanupObservationOverview=[pscustomobject]@{Running=$true;StateKey='Connected';GuardState='Protected';Mode='rule';Exit='hk';ManifestPath=$hk.Manifest;ConnectedSince=$started}
 $observed=Observe-TCRuntimeState -Root $script:Root -Overview $script:CleanupObservationOverview
 CheckUI $observed.Observed 'Actual observer establishes a bound synthetic active session'
 $hkProof=SnapshotOwnership @($hk.Manifest,$hk.Key,$hk.Line,(Join-Path $script:Root 'deployment.json'),(Join-Path $script:Root 'runtime.json'))
 $f=NewOwnershipLine '已发布输入线路（隔离夹具）' '192.0.2.10'
 $run=New-TCDeploymentRun -Root $script:Root -Intent Existing -ServerId $f.Server.LocalRecordId -ExistingNodeId $f.LineId -Name '为已有线路补齐 TCP 的任务'
 $statePath=Join-Path $script:Root ('deployments\runs\'+$run.RunId+'\state.json')
 $proof=SnapshotOwnership @($f.Manifest,$f.Key,$f.Line,(Join-Path $script:Root 'Product\index.json'))
 ShowOwnershipHistory '补齐 TCP';ClickUI ('DeleteHistoryDeploymentRun'+$run.RunId.Replace('-',''))
 $preview=WaitOwnershipWorker 'RecordDeletePreview'
 CheckUI ($preview.PlanVersion -eq 3 -and $preview.Scope -ceq 'DeploymentTask' -and $preview.LineCount -eq 0 -and $preview.RetainedLineIds -contains $f.LineId) 'Existing task preview keeps the input line outside the deletion scope'
 CheckUI ($script:Window.FindName('DialogBody').Text -match '0 份本机线路配置' -and $script:Window.FindName('DialogBody').Text -match '保留输入线路' -and $script:Window.FindName('DialogBody').Text.Contains($f.LineId)) 'Actual Existing confirmation names the retained input line and zero line deletions'
 Shot '01-existing-task-preserves-line-preview'
 ConfirmOwnership;$done=WaitOwnershipWorker 'RecordDeleteCommit';DrainOwnershipReads
 CheckUI ($done.DataDeleted -and $done.LineCount -eq 0 -and $done.RetainedLineIds -contains $f.LineId -and -not [IO.File]::Exists($statePath)) 'Existing task is really deleted while its retained line is reported'
 AssertOwnershipBytes $proof 'Existing task deletion preserves manifest, private fixture material, default and index exact bytes'
 AssertOwnershipBytes $hkProof 'Existing deletion preserves the synthetic active Hong Kong configuration and runtime'
 CheckUI ($script:LastToast -like '*已清理对应的本机部署资料*' -and $script:Window.FindName('Toast').Visibility -eq 'Visible') 'Production completion displays a visible success result after the actual commit'
 Shot '02-existing-task-completed'
 # Shared source: drive the real line-card menu, then run actual cleanup in
 # a second native isolated Worker and inspect its exact retained receipt.
 $script:ToastTimer.Stop();$script:Window.FindName('Toast').Visibility='Collapsed'
 $shared=NewOwnershipLine '待删除共享来源线路（隔离夹具）' '192.0.2.20' -Shared
 $sharedProof=SnapshotOwnership @($shared.Shared,$shared.OtherState)
 $script:Nodes=@([pscustomobject]@{id=$shared.LineId;LineId=$shared.LineId;Name='待删除共享来源线路（隔离夹具）';Endpoint='192.0.2.20:51820';Revision=1;DefaultVerified=$true;SavedConnectionPreference=@{ProfileId='Udp';Digest='fixture'};Profiles=@(@{Id='Udp';PreparationState='Ready';SyntaxValidated=$true},@{Id='Tcp';PreparationState='NotPrepared';SyntaxValidated=$false})})
 PageHead '线路' '隔离夹具：删除此线路后，另一条准备仍需要它的申请资料。' 'nodes';$script:LineCardControls=@{}
 AddLineCard $script:HostPanel (GetLineCardStateUI $script:Nodes[0])
 $key=$shared.LineId.Replace('-','');ClickUI ('MoreNode'+$key)
 $item=$script:Controls['DelNode'+$key];CheckUI $item.IsEnabled 'Actual line menu permits deletion of the unused shared-source line'
 $item.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.MenuItem]::ClickEvent)));$script:LineCardControls[$shared.LineId].Menu.IsOpen=$false
 $preview=WaitOwnershipWorker 'RecordDeletePreview'
 CheckUI ($preview.LineCount -eq 1 -and $preview.RetainedItems.Count -eq 1 -and $preview.RetainedItems[0].ReferenceIds -contains ('DeploymentRun:'+$shared.OtherId)) 'Shared preview binds the surviving task and immutable source hash'
 CheckUI ($script:Window.FindName('DialogBody').Text -match '共享来源.*按引用保留' -and $script:Window.FindName('DialogBody').Text -match '其他线路或任务仍引用的不可变来源资料') 'Actual shared-source confirmation explains retained material'
 Shot '03-shared-source-retention-preview'
 ConfirmOwnership
 # Navigate to the actual history page while the bounded cleanup runs. The
 # deliberately minimal cleanup-only manifests are not a LineStore fixture.
 # This also verifies global cleanup completion survives a real page change.
 $commitId=$script:Job.RequestId;$script:DeployUI.HistoryLoaded=$true;ShowUnifiedOperationHistory
 CheckUI ($script:Job.RequestId -ceq $commitId) 'History navigation keeps the exact in-flight cleanup request'
 $done=WaitOwnershipWorker 'RecordDeleteCommit';DrainOwnershipReads
 CheckUI ($done.DataDeleted -and $done.RetainedItems.Count -eq 1 -and -not [IO.File]::Exists($shared.Manifest) -and -not [IO.File]::Exists($shared.State)) 'Real shared cleanup commits and removes the selected line and original task'
 AssertOwnershipBytes $sharedProof 'Shared request and surviving task remain byte-identical after the real commit'
 AssertOwnershipBytes $hkProof 'Shared cleanup preserves synthetic active Hong Kong identity and runtime'
 $history=@(Get-TCOperationHistory -Root $script:Root -IncludeServerRecords)
 CheckUI (@($history|Where-Object Id -ceq ('DeploymentRun:'+$shared.RunId)).Count -eq 0 -and @($history|Where-Object Id -ceq ('DeploymentRun:'+$shared.OtherId)).Count -eq 1) 'Actual history shows only the surviving shared-source task, not a broken deleted task'
 ShowOwnershipHistory '仍引用共享'
 CheckUI ((VisibleText) -like '*仍引用共享来源的准备*' -and $script:Window.FindName('Toast').Visibility -eq 'Visible') 'Success screenshot contains the production toast and actual retained shared-source task'
 Shot '04-shared-cleanup-success-retained-task'
 CheckUI (@($script:ActualRequests|Where-Object Action -ceq 'RecordDeletePreview').Count -eq 2 -and @($script:ActualRequests|Where-Object Action -ceq 'RecordDeleteCommit').Count -eq 2) 'Two concrete UI confirmations create exactly two previews and two commits'
 CheckUI ($script:CleanupHeartbeats -eq 2) 'Both real UI confirmations remain usable after a normal observer heartbeat'
 CheckUI ($script:DeniedActors.Count -eq 0 -and $script:Smoke -eq $false) 'All actions use the native isolated Worker with no forbidden production or network actor'
 $passed=$true
}catch{$failure=$_.Exception.Message;$failureStack=$_.ScriptStackTrace}
finally{
 StopIntakeTimer;if($script:ToastTimer){$script:ToastTimer.Stop()};if($script:Window){$script:Window.Close()}
 $workerFacts=@();foreach($w in $script:OwnedWorkers){$finished=$true;try{if(-not $w.Process.HasExited){$finished=$w.Process.WaitForExit(5000)};$workerFacts+=,[pscustomobject]@{ProcessId=$w.Id;Action=$w.Action;Exited=$finished;Arguments=$w.Arguments}}catch{$workerFacts+=,[pscustomobject]@{ProcessId=$w.Id;Action=$w.Action;Exited=$true;Arguments=$w.Arguments}}}
 $report=[pscustomobject]@{ExpectedMode='Fixed';ExpectedBehaviorSatisfied=$passed;UnexpectedActors=$script:DeniedActors.Count;Passed=$passed;Assertions=$script:Checks.Count;Checks=@($script:Checks.ToArray());Failure=$failure;Stack=$failureStack;Smoke=$script:Smoke;ActualControls=$true;ActualDispatcher=$true;ActualQueue=$true;ActualWorker=$true;ActualCleanupApi=$true;ExternalBoundary='Only append native Worker -IsolatedTest and -TestRoot at Start-Process';PackageRoot=$script:PackageRoot;ProductionWrites=0;VpsCalls=0;WorkerProcesses=$workerFacts;Requests=@($script:ActualRequests.ToArray());Results=@($script:WorkerResults.ToArray());FileProofs=@($script:FileProofs.ToArray());Screenshots=@($script:Shots.ToArray());Sources=@($script:LoadedSources.ToArray());FixtureRemoved=$false;PowerShellVersion=$PSVersionTable.PSVersion.ToString()}
 $owned=SafeLocalPath $script:Root;$marker=Join-Path $owned '.owned-ui-015'
 if($owned -cne (Join-Path ([IO.Path]::GetTempPath()) ('TradeChannel-worker-fixture-'+$testId)) -or -not [IO.File]::Exists($marker) -or [IO.File]::ReadAllText($marker) -cne $testId){throw 'Fixture cleanup ownership rejected'}
 if(@($workerFacts|Where-Object {-not $_.Exited}).Count -eq 0){$reparse=@(Get-ChildItem -LiteralPath $owned -Recurse -Force|Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint});if($reparse.Count){throw 'Fixture cleanup rejects reparse points'};Remove-Item -LiteralPath $owned -Recurse -Force;$report.FixtureRemoved=(-not (Test-Path -LiteralPath $owned))}
 $report|ConvertTo-Json -Depth 40|Set-Content -LiteralPath (Join-Path $qa 'cleanup-ownership-wpf.json') -Encoding UTF8
 $report|Select-Object Passed,Assertions,Failure,Stack,Smoke,ActualWorker,FixtureRemoved|ConvertTo-Json
}
if(-not $passed){throw $failure}
