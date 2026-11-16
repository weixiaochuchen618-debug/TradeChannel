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
 # RFC 7748 test-vector identity and documentation-only endpoint. These assets
 # must pass the real post-cleanup Nodes read; no tunnel or engine is started.
 $privateHex='77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a';$publicHex='8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a'
 $privateBytes=New-Object byte[] 32;$publicBytes=New-Object byte[] 32
 for($i=0;$i -lt 32;$i++){$privateBytes[$i]=[Convert]::ToByte($privateHex.Substring($i*2,2),16);$publicBytes[$i]=[Convert]::ToByte($publicHex.Substring($i*2,2),16)}
 $private=[Convert]::ToBase64String($privateBytes);$public=[Convert]::ToBase64String($publicBytes);$serverKey=[Convert]::ToBase64String([byte[]](@(83)*32))
 $server=Set-TCServerRecord -Root $script:Root -Connection @{Host=$HostAddress;Port=22;User='root';IdentityFile=''} -Name $Name -ServerInfo @{RemoteOwnerId=[guid]::NewGuid().ToString('D');Node=@{NodeId=[guid]::NewGuid().ToString('D');ServerPublicKey=$serverKey}}
 $id=[guid]::NewGuid().ToString('D');$mp=Join-Path $script:Root ('Product\nodes\'+$id+'\manifest.json')
 $key=Join-Path (Split-Path $mp) 'device.key';PutOwnership $key @{PrivateFixtureMaterial=$id}
 $configPath=Join-Path (Split-Path $mp) 'config.json'
 $config=[ordered]@{log=@{level='error'};inbounds=@(@{type='mixed';tag='probe';listen='127.0.0.1';listen_port=20341});endpoints=@(@{type='wireguard';tag='hk';system=$false;address=@('10.78.0.2/32');private_key=$private;peers=@(@{address=$HostAddress;port=51820;public_key=$serverKey;allowed_ips=@('0.0.0.0/0')})});outbounds=@(@{type='direct';tag='direct'});route=@{final='hk'}}
 PutOwnership $configPath $config;$configHash=OwnershipHash $configPath
 $manifest=@{SchemaVersion=1;node_id=$id;TCLineId=$id;TCManagedNodeId=$id;ServerPublicKey=$serverKey;ClientPublicKey=$public;ClientAddress='10.78.0.2/32';ServerEndpoint=($HostAddress+':51820');SyntaxValidated=$true;CandidatePath=$configPath;CandidateSHA256=$configHash;ProbePath=$configPath;ProbeSHA256=$configHash;EnginePath=(Join-Path $script:PackageRoot 'assets\sing-box.exe');WgPath=(Join-Path $script:PackageRoot 'assets\wg.exe')}
 PutOwnership $mp $manifest
 $lp=Join-Path $script:Root ('Product\lines\'+$id+'\line.json')
 $profileRoot=Join-Path (Split-Path $lp) 'profiles\Udp-fixture';$profileConfig=Join-Path $profileRoot 'config.json';$profileManifest=Join-Path $profileRoot 'manifest.json'
 PutOwnership $profileConfig $config;$profileHash=OwnershipHash $profileConfig;$profile=$manifest.Clone()
 $profile.TCProfileId='Udp';$profile.TCProfileRevision=1;$profile.CandidatePath=$profileConfig;$profile.CandidateSHA256=$profileHash;$profile.ProbePath=$profileConfig;$profile.ProbeSHA256=$profileHash;PutOwnership $profileManifest $profile
 $profileRecord=@{Id='Udp';Mode='Udp';ManifestPath=$profileManifest;ManifestSHA256=(OwnershipHash $profileManifest);CandidateSHA256=$profileHash;ProbeSHA256=$profileHash;Revision=1;PreparationState='SyntaxValidated';Validation=$null;SourceNodeId=$id}
 PutOwnership $lp @{SchemaVersion=2;LineId=$id;SourceNodeId=$id;Revision=1;Name=$Name;Endpoint=($HostAddress+':51820');AliasIds=@();Profiles=@($profileRecord);PreferredProfileId='Udp';PreferenceSource='ConfiguredDefault';PreferenceUpdatedAt=$null;SavedConnectionPreference=$null;SourceManifestPath=$mp;SourceManifestSHA256=(OwnershipHash $mp);SourceConfigSHA256=$configHash;SourceProbeSHA256=$configHash;ServerPublicKey=$serverKey;ClientPublicKey=$public;ClientAddress='10.78.0.2/32'}
 $node=[pscustomobject]@{id=$id;name=$Name;kind='wireguard';endpoint=($HostAddress+':51820');manifestPath=$mp;registeredAt=[DateTimeOffset]::UtcNow.ToString('o');status='CandidateOnly'}
 $indexPath=Join-Path $script:Root 'Product\index.json';$nodes=@();if(Test-Path -LiteralPath $indexPath){$nodes=@((Read-TCDJson $indexPath).nodes)}
 PutOwnership $indexPath @{schemaVersion=1;nodes=@($nodes)+@($node);tradeDomains=@('example.com')}
 $null=Set-TCServerLink -Root $script:Root -ServerId $server.LocalRecordId -NodeId $id
 $runId=[guid]::NewGuid().ToString('D');$state=[ordered]@{SchemaVersion=1;RunId=$runId;ServerRecordId=$server.LocalRecordId;Name=$Name;Revision=1;Intent='New';Status='Complete';Stage='ReadyInactive';CreatedAtUtc=[DateTimeOffset]::UtcNow.ToString('o');UpdatedAtUtc=[DateTimeOffset]::UtcNow.ToString('o');CandidateNodeId=$id;CandidateManifestPath=$mp}
 $sp=Join-Path $script:Root ('deployments\runs\'+$runId+'\state.json');PutOwnership $sp $state
 $client=Join-Path (Split-Path $sp) 'client';$sharedPath=Join-Path $client 'public.request.json';PutOwnership $sharedPath @{RequestId=[guid]::NewGuid().ToString('D');ClientPublicKey=('C'*43+'=')}
 $otherPath='';$otherId=''
 if($Shared){$otherId=[guid]::NewGuid().ToString('D');$otherPath=Join-Path $script:Root ('deployments\runs\'+$otherId+'\state.json');PutOwnership $otherPath @{SchemaVersion=1;RunId=$otherId;ServerRecordId=$server.LocalRecordId;Name='仍引用共享来源的准备';Revision=1;Intent='New';Status='WaitingUser';Stage='PrepareAccess';CreatedAtUtc=[DateTimeOffset]::UtcNow.ToString('o');UpdatedAtUtc=[DateTimeOffset]::UtcNow.ToString('o');RequestDirectory=$client;ReusedRequestSourceRunId=$runId;ClientRequest=@{ClientPublicKey=('C'*43+'=')}}}
 [pscustomobject]@{LineId=$id;Server=$server;Manifest=$mp;Key=$key;Line=$lp;Assets=@($mp,$key,$lp,$configPath,$profileConfig,$profileManifest);RunId=$runId;State=$sp;Shared=$sharedPath;OtherState=$otherPath;OtherId=$otherId;Node=$node}
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
  if($request.Action -notin @('RecordDeletePreview','RecordDeleteCommit','OperationHistory','Nodes','Overview')){throw ('Forbidden Worker action '+$request.Action)}
  $script:ActualRequests.Add($request)
  $args=@($ArgumentList)+@('-IsolatedTest','-TestRoot',('"'+$script:Root+'"'))
  $p=Microsoft.PowerShell.Management\Start-Process -FilePath $FilePath -ArgumentList $args -PassThru -WindowStyle Hidden
  $script:OwnedWorkers.Add([pscustomobject]@{Process=$p;Id=$p.Id;Action=$request.Action;Arguments=$args});return $p
 }
 function UpdateChrome {$script:Window.FindName('ChipText').Text='隔离清理验收 · 真实 Worker'}
 function Render {}
 function RefreshOverview {param([switch]$Silent) StartJob @{Action='Overview'} {} '读取隔离运行状态…' -Silent:$Silent}
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
  $resultProof=[pscustomobject]@{Action=$ExpectedAction;Result=$raw;UiReceipt=$null};$script:WorkerResults.Add($resultProof)
  CheckUI ($raw.Ok -and $raw.RequestId -ceq $job.RequestId -and $raw.PageGeneration -eq $job.OriginContext.Revision) ('Actual Worker result binds '+$ExpectedAction+' identity and navigation')
  PollBackgroundJob;StopIntakeTimer
  CheckUI (-not $job.CallbackFailed) ('Actual '+$ExpectedAction+' callback finishes without a hidden UI failure')
  $resultProof.UiReceipt=$script:LastJobReceipt
  if($ExpectedAction -ceq 'RecordDeleteCommit'){
   $script:LastCleanupCommitReceipt=$script:LastJobReceipt
   CheckUI ($script:LastCleanupCommitReceipt.RequestId -ceq $job.RequestId -and $script:LastCleanupCommitReceipt.Status -ceq 'Completed' -and $script:LastCleanupCommitReceipt.BusinessStatus -ceq 'Deleted') 'The exact commit receipt records a completed business deletion before follow-up reads'
  }
  return $raw.Data
 }
 function DrainOwnershipReads {
  for($i=0;$script:Job -and $i -lt 8;$i++){if($script:Job.Action -notin @('Nodes','OperationHistory','Overview')){throw ('Unexpected follow-up '+$script:Job.Action)};$null=WaitOwnershipWorker $script:Job.Action}
  CheckUI (-not $script:Job -and $script:JobQueue.Count -eq 0) 'Cleanup follow-up reads finish through the real queue'
  CheckUI ($script:DeployUI.CleanupRefresh.Phase -ceq 'Completed' -and @($script:Nodes|Where-Object {$_.LineId -cin $script:DeployUI.DeletedLineIds}).Count -eq 0) 'Authoritative Nodes refresh completes and cannot revive any deleted line'
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
 $hkProof=SnapshotOwnership (@($hk.Assets)+@((Join-Path $script:Root 'deployment.json'),(Join-Path $script:Root 'runtime.json')))
 $f=NewOwnershipLine '已发布输入线路（隔离夹具）' '192.0.2.10'
 $run=New-TCDeploymentRun -Root $script:Root -Intent Existing -ServerId $f.Server.LocalRecordId -ExistingNodeId $f.LineId -Name '为已有线路补齐 TCP 的任务'
 $statePath=Join-Path $script:Root ('deployments\runs\'+$run.RunId+'\state.json')
 $proof=SnapshotOwnership (@($f.Assets)+@((Join-Path $script:Root 'Product\index.json')))
 ShowOwnershipHistory '补齐 TCP';ClickUI ('DeleteHistoryDeploymentRun'+$run.RunId.Replace('-',''))
 $preview=WaitOwnershipWorker 'RecordDeletePreview'
 CheckUI ($preview.PlanVersion -eq 3 -and $preview.Scope -ceq 'DeploymentTask' -and $preview.LineCount -eq 0 -and $preview.RetainedLineIds -contains $f.LineId) 'Existing task preview keeps the input line outside the deletion scope'
 $details=CleanupDetailsText;$existingPending=$script:DeployUI.RecordDeletePending
 CheckUI ($script:DialogContext.CleanupDialog -ceq 'Confirm' -and $script:Window.FindName('DialogBody').Text -match '已保存线路和服务器上的服务会保留' -and $details -match '线路 0 条' -and $details -match '保留输入线路' -and $details.Contains($f.LineId)) 'Actual Existing confirmation shows the retained input line and zero line deletions in visible details'
 Shot '01-existing-task-preserves-line-preview'
 ConfirmOwnership;$done=WaitOwnershipWorker 'RecordDeleteCommit';DrainOwnershipReads
 CheckUI ($done.DataDeleted -and $done.LineCount -eq 0 -and $done.RetainedLineIds -contains $f.LineId -and -not [IO.File]::Exists($statePath)) 'Existing task is really deleted while its retained line is reported'
 AssertOwnershipBytes $proof 'Existing task deletion preserves manifest, private fixture material, default and index exact bytes'
 AssertOwnershipBytes $hkProof 'Existing deletion preserves the synthetic active Hong Kong configuration and runtime'
 CheckUI ($existingPending.Phase -ceq 'Deleted' -and $script:LastToast -ceq ('已删除'+$existingPending.Label+'。') -and $script:Window.FindName('Toast').Visibility -eq 'Visible' -and @($script:Nodes|Where-Object {$_.LineId -ceq $f.LineId}).Count -eq 1 -and @($script:Nodes|Where-Object {$_.LineId -ceq $hk.LineId}).Count -eq 1) 'Production completion displays deletion success and the authoritative list retains both existing lines'
 Shot '02-existing-task-completed'
 # Shared source: drive the real line-card menu, then run actual cleanup in
 # a second native isolated Worker and inspect its exact retained receipt.
 $script:ToastTimer.Stop();$script:Window.FindName('Toast').Visibility='Collapsed'
 $shared=NewOwnershipLine '待删除共享来源线路（隔离夹具）' '192.0.2.20' -Shared
 $sharedProof=SnapshotOwnership @($shared.Shared,$shared.OtherState)
 $null=Observe-TCRuntimeState -Root $script:Root -Overview $script:CleanupObservationOverview
 $script:Nodes=@([pscustomobject]@{id=$shared.LineId;LineId=$shared.LineId;Name='待删除共享来源线路（隔离夹具）';Endpoint='192.0.2.20:51820';Revision=1;DefaultVerified=$true;SavedConnectionPreference=@{ProfileId='Udp';Digest='fixture'};Profiles=@(@{Id='Udp';PreparationState='Ready';SyntaxValidated=$true},@{Id='Tcp';PreparationState='NotPrepared';SyntaxValidated=$false})})
 PageHead '线路' '隔离夹具：删除此线路后，另一条准备仍需要它的申请资料。' 'nodes';$script:LineCardControls=@{}
 AddLineCard $script:HostPanel (GetLineCardStateUI $script:Nodes[0])
 $key=$shared.LineId.Replace('-','');ClickUI ('MoreNode'+$key)
 $item=$script:Controls['DelNode'+$key];CheckUI $item.IsEnabled 'Actual line menu permits deletion of the unused shared-source line'
 $item.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.MenuItem]::ClickEvent)));$script:LineCardControls[$shared.LineId].Menu.IsOpen=$false
 $preview=WaitOwnershipWorker 'RecordDeletePreview'
 CheckUI ($preview.LineCount -eq 1 -and $preview.RetainedItems.Count -eq 1 -and $preview.RetainedItems[0].ReferenceIds -contains ('DeploymentRun:'+$shared.OtherId)) 'Shared preview binds the surviving task and immutable source hash'
 $details=CleanupDetailsText
 CheckUI ($script:DialogContext.CleanupDialog -ceq 'Confirm' -and $script:Window.FindName('DialogBody').Text -match '仅供它使用的资料.*服务器上的服务会保留' -and $details -match '其他线路或任务仍引用的不可变来源资料' -and $preview.RetainedItems[0].Hash -ceq (OwnershipHash $shared.Shared)) 'Actual shared-source confirmation visibly explains retained material and preview binds its exact bytes'
 Shot '03-shared-source-retention-preview'
 ConfirmOwnership
 # Navigate while cleanup runs, then finish its actual Nodes and overview reads.
 # The complete fixture assets must survive authoritative LineStore validation.
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
 # User journey P25: A -> B succeeded, B was disconnected, then delete A.
 # B uses this completed transaction's approved manifest. Keep it byte-exact
 # while the obsolete Original snapshot is removed through actual cleanup.
 $txid=[guid]::NewGuid().ToString('N');$txPath=Join-Path $script:Root ('connection-transactions\'+$txid+'.json');$approved=Join-Path $script:Root ('connection-transactions\'+$txid+'-approved.manifest')
 $bManifest=Read-TCDJson $f.Manifest;$bManifest|Add-Member NoteProperty TCTransactionId $txid;$bManifest|Add-Member NoteProperty TCProfileManifestPath $f.Manifest
 PutOwnership $approved $bManifest
 PutOwnership $txPath @{SchemaVersion=1;Id=$txid;Status='Completed';Phase='Completed';LineId=$f.LineId;Target=@{ManifestPath=$f.Manifest};ActiveManifestPath=$approved;Original=@{Observed=@{LineId=$hk.LineId;ManifestPath=$hk.Manifest};Manifest=@{Path=$hk.Manifest;Exists=$true;SHA256=(OwnershipHash $hk.Manifest);Bytes=[Convert]::ToBase64String([IO.File]::ReadAllBytes($hk.Manifest))}}}
 PutOwnership (Join-Path $script:Root 'deployment.json') @{LineId=$f.LineId;TransactionId=$txid;ManifestPath=$approved}
 PutOwnership (Join-Path $script:Root 'runtime.json') @{State='Disconnected';CleanupError=$false;OwnershipKnown=$true;ManifestPath=$approved;SessionId=[guid]::NewGuid().ToString('N')}
 $script:CleanupObservationOverview=[pscustomobject]@{Running=$false;StateKey='Disconnected';GuardState='Unprotected';Mode='rule';Exit='hk';ManifestPath=$approved;ConnectedSince=$null}
 $null=Observe-TCRuntimeState -Root $script:Root -Overview $script:CleanupObservationOverview
 $script:Overview=$script:CleanupObservationOverview
 $bProof=SnapshotOwnership (@($f.Assets)+@($approved,(Join-Path $script:Root 'deployment.json'),(Join-Path $script:Root 'runtime.json')))
 $script:Nodes=@([pscustomobject]@{id=$hk.LineId;LineId=$hk.LineId;Name='香港主线（旧回退夹具）';Endpoint='192.0.2.254:51820';Revision=1;DefaultVerified=$true;SavedConnectionPreference=@{ProfileId='Udp';Digest='fixture'};Profiles=@(@{Id='Udp';PreparationState='Ready';SyntaxValidated=$true},@{Id='Tcp';PreparationState='NotPrepared';SyntaxValidated=$false})})
 PageHead '线路' '已完成切换到另一条线路并断开；清理香港旧回退资料。' 'nodes';$script:LineCardControls=@{}
 AddLineCard $script:HostPanel (GetLineCardStateUI $script:Nodes[0]);$key=$hk.LineId.Replace('-','');ClickUI ('MoreNode'+$key)
 $item=$script:Controls['DelNode'+$key];CheckUI $item.IsEnabled 'Disconnected old Hong Kong line offers the actual delete menu'
 $item.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.MenuItem]::ClickEvent)));$script:LineCardControls[$hk.LineId].Menu.IsOpen=$false
 $preview=WaitOwnershipWorker 'RecordDeletePreview'
 CheckUI ($preview.PreviewToken -and $preview.Blocked.Count -eq 0 -and $preview.LineCount -eq 1) 'Actual WPF preview accepts completed rollback retirement'
 CheckUI ((CleanupDetailsText) -match '保留其他线路的已完成连接事务及当前配置.*旧回退快照') 'Actual confirmation visibly explains retained transaction and obsolete rollback cleanup'
 Shot '05-completed-switch-old-line-preview'
 $script:LastToast='';$completedPending=$script:DeployUI.RecordDeletePending;ConfirmOwnership;$completedSwitchRequest=$script:Job.RequestId;ShowUnifiedOperationHistory;$completionContext=CaptureNavigationContext;$done=WaitOwnershipWorker 'RecordDeleteCommit';DrainOwnershipReads
 CheckUI ($done.DataDeleted -and -not (Test-Path $hk.Manifest)) 'Actual WPF confirmation deletes old line after a completed switch'
 AssertOwnershipBytes $bProof 'The retained B line and disconnected runtime remain byte-identical'
 $saved=Read-TCDJson $txPath
 CheckUI ($saved.Status -ceq 'Completed' -and $null -eq $saved.Original -and $saved.OriginalRetention.State -ceq 'RemovedByLocalCleanup') 'Actual Worker retires Original without deleting B transaction'
 CheckUI ($script:LastToast -ceq ('已删除'+$completedPending.Label+'。') -and $script:LastCleanupCommitReceipt.RequestId -ceq $completedSwitchRequest -and $script:LastCleanupCommitReceipt.Status -ceq 'Completed' -and $script:LastCleanupCommitReceipt.BusinessStatus -ceq 'Deleted' -and (TestNavigationContext $completionContext) -and $script:Role -ceq 'operation-history' -and $script:Window.FindName('Toast').Visibility -eq 'Visible' -and @($script:Nodes|Where-Object {$_.LineId -ceq $f.LineId}).Count -eq 1 -and @($script:Nodes|Where-Object {$_.LineId -ceq $hk.LineId}).Count -eq 0) 'Navigated cleanup retains its exact success receipt and the current page after authoritative reads remove only the old line'
 Shot '06-completed-switch-old-line-deleted'
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
