#requires -Version 5.1
#requires -PSEdition Desktop
[CmdletBinding()]param([string]$PackageRoot='',[Parameter(Mandatory=$true)][string]$ReportDirectory)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
if($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1 -or [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw 'Use Windows PowerShell 5.1 -Sta.'}
$env:PSModulePath=Join-Path $PSHOME 'Modules'
if(-not $PackageRoot){$PackageRoot=Split-Path $PSScriptRoot -Parent}
$SourceDirectory=[IO.Path]::GetFullPath($PackageRoot);$script:FixturePackageRoot=$SourceDirectory
$script:ReportRoot=[IO.Path]::GetFullPath($ReportDirectory).TrimEnd('\')
$workspace=Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
$allowedReport=[IO.Path]::GetFullPath((Join-Path $workspace 'reports')).TrimEnd('\')+'\'
if(-not $script:ReportRoot.StartsWith($allowedReport,[StringComparison]::OrdinalIgnoreCase)){throw 'Use a dedicated directory under workspace reports.'}
$cursor=$script:ReportRoot;while($cursor){if([IO.Directory]::Exists($cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Report paths cannot traverse reparse points.'};$cursor=[IO.Path]::GetDirectoryName($cursor)}
$null=[IO.Directory]::CreateDirectory($script:ReportRoot)
$script:WindowsPowerShell='C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
function Start-Process {throw 'Only the exact isolated Worker launcher below may start a process.'}
function Stop-Process {throw 'Tests forbid stopping other processes.'}
function Invoke-WebRequest {throw 'Tests forbid network access.'}
function Invoke-RestMethod {throw 'Tests forbid network access.'}

# Import helper definitions only, never the existing test's outer execution.
# Nested helper extraction must resolve $PSScriptRoot to the explicit tests path.
$base=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Test-CleanupStoppedRollback.ps1'),[Text.Encoding]::UTF8)
$start=$base.IndexOf('$base=[IO.File]');$end=$base.IndexOf("try{`n "+'$f=FailedFixture;')
if($end -lt 0){$end=$base.IndexOf("try{`r`n "+'$f=FailedFixture;')}
if($start -lt 0 -or $end -le $start){throw 'Stopped-rollback fixture boundary changed.'}
$helperPrefix=$base.Substring($start,$end-$start).Replace("'`$PSScriptRoot'","'__WEB_TESTS_ROOT_LITERAL__'")
$helperPrefix=$helperPrefix.Replace('$PSScriptRoot',("'"+$PSScriptRoot.Replace("'","''")+"'")).Replace("'__WEB_TESTS_ROOT_LITERAL__'","'`$PSScriptRoot'")
. ([scriptblock]::Create($helperPrefix))

# Complete only synthetic assets before CTExecute creates its real failure and
# rollback proof. No transaction snapshots are patched after the failure.
$script:OriginalWebFixture=${function:Fixture}
function WebFixtureServerKey {param($Fixture,$Node)
 $octet=if($Node.id -ceq $Fixture.Active){11}else{22}
 return [Convert]::ToBase64String([byte[]](@($octet)*32))
}
function WebFixtureConfig {param($Fixture,$Node)
 $privateHex='77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a'
 $bytes=New-Object byte[] 32;for($i=0;$i -lt 32;$i++){$bytes[$i]=[Convert]::ToByte($privateHex.Substring($i*2,2),16)}
 $private=[Convert]::ToBase64String($bytes);[Array]::Clear($bytes,0,$bytes.Length)
 $server=WebFixtureServerKey $Fixture $Node
 $address=([string]$Node.endpoint).Split(':')[0]
 [ordered]@{log=[ordered]@{level='error'};inbounds=@([ordered]@{type='mixed';tag='probe';listen='127.0.0.1';listen_port=20341});endpoints=@([ordered]@{type='wireguard';tag='hk';system=$false;address=@('10.78.0.4/32');private_key=$private;peers=@([ordered]@{address=$address;port=51820;public_key=$server;allowed_ips=@('0.0.0.0/0')})});outbounds=@([ordered]@{type='direct';tag='direct'});route=[ordered]@{final='hk'}}
}
function Fixture {
 $f=& $script:OriginalWebFixture
 $publicHex='8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a'
 $bytes=New-Object byte[] 32;for($i=0;$i -lt 32;$i++){$bytes[$i]=[Convert]::ToByte($publicHex.Substring($i*2,2),16)};$public=[Convert]::ToBase64String($bytes)
 $ordinal=0
 foreach($node in $f.Nodes){
  $ordinal++;$node.kind='wireguard';$node.endpoint='192.0.2.'+$ordinal+':51820';$node.registeredAt=[DateTimeOffset]::UtcNow.ToString('o');$node.status='CandidateOnly';$node.name=if($node.id -ceq $f.Active){'保留主线（隔离）'}else{'失败测试线（隔离）'}
  $config=Join-Path (Split-Path $node.manifestPath) 'config.json';Put $config (WebFixtureConfig $f $node)
  $m=Read-TCDJson $node.manifestPath
  foreach($entry in @{SchemaVersion=1;node_id=$node.id;ServerPublicKey=(WebFixtureServerKey $f $node);ClientPublicKey=$public;ClientAddress='10.78.0.4/32';ServerEndpoint=$node.endpoint;ProbePath=$config;ProbeSHA256=(Hash $config);EnginePath=(Join-Path $SourceDirectory 'assets\sing-box.exe');WgPath=(Join-Path $SourceDirectory 'assets\wg.exe');EngineSHA256=(Hash (Join-Path $SourceDirectory 'assets\sing-box.exe'))}.GetEnumerator()){$m|Add-Member NoteProperty $entry.Key $entry.Value -Force}
  Put $node.manifestPath $m
 }
 $registryPath=Join-Path $f.Root 'servers\registry.json';$registry=Read-TCDJson $registryPath
 foreach($server in $registry.Servers){$linked=@($f.Nodes|Where-Object {$_.id -in $server.LinkedNodeIds});if($linked.Count -ne 1){throw 'Synthetic server requires one exact line binding.'};$server.ServerPublicKey=WebFixtureServerKey $f $linked[0]}
 Put $registryPath $registry
 Put (Join-Path $f.Root 'Product\index.json') @{schemaVersion=1;nodes=@($f.Nodes);tradeDomains=@('example.com')}
 return $f
}
function CompleteWebFixtureLines {param($f)
 foreach($node in $f.Nodes){
  $source=Read-TCDJson $node.manifestPath;$dir=Join-Path $f.Root ('Product\lines\'+$node.id+'\profiles\Udp-fixture');$config=Join-Path $dir 'config.json';$manifest=Join-Path $dir 'manifest.json'
  Put $config (WebFixtureConfig $f $node);$profile=$source|ConvertTo-Json -Depth 30|ConvertFrom-Json
  foreach($entry in @{TCProfileId='Udp';TCProfileRevision=1;CandidatePath=$config;CandidateSHA256=(Hash $config);ProbePath=$config;ProbeSHA256=(Hash $config)}.GetEnumerator()){$profile|Add-Member NoteProperty $entry.Key $entry.Value -Force};Put $manifest $profile
  $p=[ordered]@{Id='Udp';Mode='Udp';ManifestPath=$manifest;CandidateSHA256=(Hash $config);ProbeSHA256=(Hash $config);ManifestSHA256=(Hash $manifest);Revision=1;PreparationState='SyntaxValidated';Validation=$null;SourceNodeId=$node.id}
  Put (Join-Path $f.Root ('Product\lines\'+$node.id+'\line.json')) ([ordered]@{SchemaVersion=2;LineId=$node.id;SourceNodeId=$node.id;Revision=1;Name=$node.name;Endpoint=$node.endpoint;AliasIds=@();Profiles=@($p);PreferredProfileId='Udp';PreferenceSource='ConfiguredDefault';PreferenceUpdatedAt=$null;SavedConnectionPreference=$null;SourceManifestPath=$node.manifestPath;SourceManifestSHA256=(Hash $node.manifestPath);SourceConfigSHA256=$source.CandidateSHA256;SourceProbeSHA256=$source.ProbeSHA256;ServerPublicKey=$source.ServerPublicKey;ClientPublicKey=$source.ClientPublicKey;ClientAddress=$source.ClientAddress})
 }
}
$switchBody=${function:SwitchFixture}.ToString()
$placeholder='Put $config @{SyntheticOnly=$true;LineId=$node.id}'
if(-not $switchBody.Contains($placeholder)){throw 'Synthetic switch config boundary changed.'}
$switchBody=$switchBody.Replace($placeholder,'Put $config (WebFixtureConfig $f $node)').Replace('return $f','CompleteWebFixtureLines $f;return $f')
Set-Item Function:script:SwitchFixture ([scriptblock]::Create($switchBody))

$script:WebChecks=New-Object 'Collections.Generic.List[string]'
$script:ActualWorkers=New-Object 'Collections.Generic.List[object]'
$script:OwnedWorkerProcesses=New-Object 'Collections.Generic.List[object]'
$script:WebCases=New-Object 'Collections.Generic.List[object]'
$script:WaitTimings=New-Object 'Collections.Generic.List[object]'
$script:CompletedCaptures=New-Object 'Collections.Generic.HashSet[object]'
$script:Step='Fixture';$passed=$false;$failure='';$failureStack='';$uiRoot='';$f=$null
function WebCheck {param($Value,[string]$Name)if(-not $Value){throw ('Web delete Worker assertion: '+$Name)};$script:WebChecks.Add($Name)}
function EventProof {param([string]$Stage)
 $script:Step=$Stage;Write-Output ('STAGE '+$Stage)
 [IO.File]::AppendAllText((Join-Path $script:ReportRoot 'stages.log'),([DateTimeOffset]::UtcNow.ToString('o')+' '+$Stage+[Environment]::NewLine),[Text.UTF8Encoding]::new($true))
}
function AssertWebFixture {param([string]$Path,[switch]$RootOnly)
 $root=[IO.Path]::GetFullPath($f.Root).TrimEnd('\');$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if(-not $root.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($root) -cnotmatch '^TradeChannel-worker-fixture-[a-f0-9]{32}$' -or $root -cnotin @($fixtures)){throw 'Unowned Worker fixture root.'}
 $full=[IO.Path]::GetFullPath($Path).TrimEnd('\')
 if($RootOnly){if($full -ine $root){throw 'Wrong fixture root.'}}elseif(-not $full.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'External fixture path.'}
 if(@(Get-ChildItem -LiteralPath $root -Recurse -Force|Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count){throw 'Fixture contains a reparse point.'}
 return $full
}
function Pump {[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 15}
function Await {param($Task)$deadline=[DateTime]::UtcNow.AddSeconds(20);while(-not $Task.IsCompleted){Pump;if([DateTime]::UtcNow -gt $deadline){throw 'WebView deadline exceeded.'}};$Task.GetAwaiter().GetResult()}
function Js {param([string]$Code)Await ($script:WebShell.CoreWebView2.ExecuteScriptAsync($Code))}
function WaitDom {param([string]$Expression)$deadline=[DateTime]::UtcNow.AddSeconds(15);do{Pump;if((Js $Expression) -ceq 'true'){return}}while([DateTime]::UtcNow -lt $deadline);throw ('DOM condition: '+$Expression)}
function Click {param([string]$Selector)
 $literal=$Selector|ConvertTo-Json -Compress;WaitDom ("!!document.querySelector("+$literal+") && !document.querySelector("+$literal+").disabled")
 $null=Js ("document.querySelector("+$literal+").click()")
 for($i=0;$i -lt 3;$i++){Pump}
}
function Shot {param([string]$Name)
 $snapshot=@{Type='snapshot';State=(GetTCWebSnapshot);Page=$script:WebPage}
 [IO.File]::WriteAllText((Join-Path $script:ReportRoot ($Name+'.snapshot.json')),($snapshot|ConvertTo-Json -Depth 45),[Text.UTF8Encoding]::new($true))
 $stream=[IO.File]::Open((Join-Path $script:ReportRoot ($Name+'.png')),[IO.FileMode]::Create)
 try{$null=Await ($script:WebShell.CoreWebView2.CapturePreviewAsync([Microsoft.Web.WebView2.Core.CoreWebView2CapturePreviewImageFormat]::Png,$stream))}finally{$stream.Dispose()}
}
function PendingCapture {param([string]$Action)
 $rows=@($script:Actions|Where-Object {$_.Request.Action -ceq $Action -and -not $script:CompletedCaptures.Contains($_)})
 if($rows.Count -ne 1){throw ('Expected exactly one captured '+$Action+', found '+$rows.Count)};return $rows[0]
}
function CommitCount {@($script:Actions|Where-Object {$_.Request.Action -ceq 'RecordDeleteCommit'}).Count}
function BeginActualWorker {param([hashtable]$Request,$Capture=$null)
 $action=[string]$Request.Action
 if($action -cnotin @('Nodes','RecordDeletePreview','RecordDeleteCommit')){throw ('Forbidden Worker action '+$action)}
 $null=AssertWebFixture $f.Root -RootOnly
 if($action -eq 'Nodes'){
  if(@($Request.Keys|Where-Object {$_ -cne 'Action'}).Count){throw 'Nodes accepts no business arguments.'}
 }elseif($action -eq 'RecordDeletePreview'){
  if(@($Request.Ids).Count -ne 1 -or $Request.Ids[0] -cne ('Line:'+$f.Target) -or $Request.AbandonLocalTracking){throw 'Preview target is not the exact synthetic line.'}
 }elseif(-not $Capture -or $Capture.CallbackContext.Pending.Ids.Count -ne 1 -or $Capture.CallbackContext.Pending.Ids[0] -cne ('Line:'+$f.Target) -or $Request.PreviewToken -cne $Capture.CallbackContext.PreviewToken){throw 'Commit is not bound to the captured synthetic confirmation.'}
 if($Capture -and (($Capture.Request|ConvertTo-Json -Depth 15 -Compress) -cne ($Request|ConvertTo-Json -Depth 15 -Compress))){throw 'Captured business request changed.'}
 $id=[guid]::NewGuid().ToString('N');$uiId=if($Capture){[string]$Capture.Lifecycle.UiRequestId}else{[guid]::NewGuid().ToString('N')}
 $origin=if($Capture -and $Capture.CallbackContext.Type -ceq 'LocalCleanup'){$Capture.CallbackContext.Pending.Context}else{CaptureNavigationContext}
 $envelope=$Request.Clone();$envelope.RequestId=$id;$envelope.UiRequestId=$uiId;$envelope.PageGeneration=[int]$origin.Revision
 $req=AssertWebFixture (Join-Path $script:JobRoot ($id+'.request.json'));$out=AssertWebFixture (Join-Path $script:JobRoot ($id+'.result.json'));Put $req $envelope
 $args=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $script:FixturePackageRoot 'Worker.ps1'),'-RequestPath',$req,'-ResultPath',$out,'-IsolatedTest','-TestRoot',$f.Root)
 if([IO.Path]::GetFullPath($args[5]) -cne (Join-Path $script:FixturePackageRoot 'Worker.ps1')){throw 'Unexpected Worker executable boundary.'}
 $quoted=@($args|ForEach-Object {'"'+$_+'"'}) -join ' '
 $p=Microsoft.PowerShell.Management\Start-Process -FilePath $script:WindowsPowerShell -ArgumentList $quoted -WindowStyle Hidden -PassThru
 $script:OwnedWorkerProcesses.Add($p)
 $work=@{Process=$p;Action=$action;Request=$req;Result=$out;RequestId=$id;UiRequestId=$uiId;PageGeneration=[int]$origin.Revision;Capture=$Capture;Started=[DateTimeOffset]::UtcNow;Job=$null}
 if($Capture){
  $null=$script:CompletedCaptures.Add($Capture);$Capture.Lifecycle.RequestId=$id
  if($action -eq 'RecordDeleteCommit'){$Capture.CallbackContext.Pending.CommitRequestId=$id}
  $work.Job=@{Process=$p;WorkerProcessId=$p.Id;ProcessStartedTicks=$p.StartTime.ToUniversalTime().Ticks;Request=$req;Result=$out;RequestData=$envelope;RequestId=$id;UiRequestId=$uiId;Lifecycle=$Capture.Lifecycle;Complete=$Capture.Complete;Failed=$Capture.Failed;CallbackContext=$Capture.CallbackContext;Policy=(GetUiJobPolicy $action);OriginContext=$origin;Started=(Get-Date);Action=$action;RunId='';LineId=$f.Target;Message=('Isolated '+$action);Silent=($action -ne 'RecordDeleteCommit');OutcomeUnknown=$false;CleanupEpoch=[long](ProfileUIField $script:DeployUI CleanupEpoch 0);PreserveFiles=$true;CompletionDelivered=$false;ResourceScope=$null}
  $script:Job=$work.Job;SyncTCWebState -Force
 }
 $proof=[pscustomobject]@{Action=$action;RequestId=$id;UiRequestId=$uiId;PageGeneration=$work.PageGeneration;ProcessId=$p.Id;Root=$f.Root;RequestSHA256=(Hash $req);StartedAtUtc=$work.Started.ToString('o');EndedAtUtc='';ExitCode=$null;ResultSHA256='';Ok=$false;Code='';SelectedIds=@();DeletedLineIds=@();DataDeleted=$false;EligibleCount=0;BlockedCodes=@();NodeIds=@();ReferenceReleaseCount=0;CallbackDelivered=$false;CallbackFailed=$false}
 $work.Proof=$proof;$script:ActualWorkers.Add($proof);Write-Host ('WORKER '+$action+' '+$id)
 return $work
}
function FinishActualWorker {param($Work)
 $deadline=[DateTime]::UtcNow.AddSeconds(120)
 while(-not $Work.Process.HasExited){Pump;if([DateTime]::UtcNow -gt $deadline){throw ('Owned isolated Worker deadline: '+$Work.Action)}}
 $Work.Process.WaitForExit();$proof=$Work.Proof;$proof.ExitCode=$Work.Process.ExitCode;$proof.EndedAtUtc=[DateTimeOffset]::UtcNow.ToString('o')
 WebCheck ($proof.ExitCode -eq 0 -and [IO.File]::Exists($Work.Result)) ('Actual Worker publishes '+$Work.Action)
 $proof.ResultSHA256=Hash $Work.Result;$result=Read-TCDJson $Work.Result
 WebCheck ($result.RequestId -ceq $Work.RequestId -and $result.UiRequestId -ceq $Work.UiRequestId -and [int]$result.PageGeneration -eq $Work.PageGeneration -and $result.Action -ceq $Work.Action) ('Actual '+$Work.Action+' result matches all envelope identities')
 $proof.Ok=[bool]$result.Ok;$proof.Code=[string]$result.Code
 if($Work.Action -eq 'Nodes'){$proof.NodeIds=@($result.Data|ForEach-Object {$_.LineId})}
 else{$proof.SelectedIds=@($result.Data.SelectedIds);$proof.DeletedLineIds=@($result.Data.DeletedLineIds);$proof.DataDeleted=[bool]$result.Data.DataDeleted;$proof.EligibleCount=[int]$result.Data.EligibleCount;$proof.BlockedCodes=@($result.Data.Blocked|ForEach-Object {$_.Code});$proof.ReferenceReleaseCount=[int]$result.Data.ReferenceReleaseCount}
 [IO.File]::WriteAllText((Join-Path $script:ReportRoot ($Work.RequestId+'.worker.json')),($proof|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($true))
 if($Work.Capture){
  CompleteUiJob $Work.Job $result
  $proof.CallbackDelivered=[bool]$Work.Job.CompletionDelivered;$proof.CallbackFailed=[bool]$Work.Job.CallbackFailed
  WebCheck ($proof.CallbackDelivered -and -not $proof.CallbackFailed) ('Production CompleteUiJob consumes real '+$Work.Action+' result')
  $script:Pending=$null;$script:HostPanel.IsEnabled=$true;SyncTCWebState -Force
 }else{$Work.Process.Dispose()}
 return $result
}
function OpenDeleteDetail {param([string]$CaseName)
 $selector='.name-button[data-detail="'+$f.Target+'"]';Click $selector;WaitDom "!document.querySelector('#drawer').hidden"
 WaitDom "!!document.querySelector('#drawer [data-action=delete]') && !document.querySelector('#drawer [data-action=delete]').disabled"
 # Same browser clock brackets the real DOM click and progress DOM visibility.
 # This measures WebView2 -> host presentation -> WebView2 DOM, before the
 # captured Smoke request is dispatched to its actual isolated Worker below.
 $null=Js @'
(() => {
 const button = document.querySelector('#drawer [data-action=delete]');
 const sample = window.__deleteWorkerWait = {StartMs:performance.now(),DomVisibleMs:null,ElapsedMs:null,CanCancel:false};
 const observe = () => {
  const dialog=document.querySelector('[role=alertdialog][aria-busy=true]');
  const cancel=dialog?.querySelector('[data-action=confirmDialog]');
  if(!dialog || dialog.getBoundingClientRect().width===0 || getComputedStyle(dialog).visibility==='hidden' || cancel?.textContent!=='取消检查') return;
  sample.DomVisibleMs=performance.now();sample.ElapsedMs=sample.DomVisibleMs-sample.StartMs;sample.CanCancel=!cancel.disabled;
  sample.Title=dialog.querySelector('h2')?.textContent;observer.disconnect();
 };
 const observer=new MutationObserver(observe);observer.observe(document.body,{subtree:true,childList:true,attributes:true});
 sample.StartMs=performance.now();button.click();observe();
})()
'@
 WaitDom "document.querySelector('[role=alertdialog][aria-busy=true]') !== null"
 WaitDom "window.__deleteWorkerWait?.ElapsedMs !== null"
 $sample=(Js 'window.__deleteWorkerWait')|ConvertFrom-Json
 WebCheck ($null -ne $sample.ElapsedMs -and $sample.ElapsedMs -ge 0 -and $sample.CanCancel) 'Actual WebView2 click exposes a measurable cancellable progress DOM'
 $script:WaitTimings.Add([pscustomobject]@{Case=$CaseName;ElapsedMs=$sample.ElapsedMs;Start='performance.now immediately before real WebView2 HTMLElement.click';End='MutationObserver first sees nonzero-size busy dialog with enabled cancel';Clock='WebView2 performance.now';HostPumpMilliseconds=15;Smoke=$script:Smoke;DispatchBoundary='Real isolated Worker starts after this progress sample';Offscreen=$true;PhysicalInputOrDisplayPaintMeasured=$false;Production200msCriterionClaimed=$false})
 WebCheck ($script:DeployUI.RecordDeletePending.Phase -ceq 'Previewing' -and $script:DeployUI.RecordDeletePending.Ids[0] -ceq ('Line:'+$f.Target)) 'Real detail delete immediately enters the exact target check'
}
function MainPage {param([string]$Name)Click ('nav [data-page="'+$Name+'"]');WaitDom ('!document.querySelector(".workflow") && document.querySelector("nav .active").dataset.page === '+($Name|ConvertTo-Json -Compress))}
try{
 EventProof 'Create real failed rollback with synthetic runtime adapter'
 $f=FailedFixture
 $fixtureAssertions=@($checks.ToArray());WebCheck ($fixtureAssertions.Count -ge 3) 'Imported real rollback helper completes its original assertions'
 WebCheck ((Read-TCDJson (Join-Path $f.Root 'runtime.json')).ManifestPath -and (Read-TCDJson $f.FailedTransactionPath).Status -ceq 'RolledBack') 'Legacy stopped runtime still references the real failed transaction before UI starts'
 $sourceFiles=@('TradeChannel.ps1','Worker.ps1','LineStore.psm1','LocalDeploymentCleanup.ps1','ConnectionTransactions.psm1','ui\WebShell.ps1','ui\BackgroundJobs.ps1','ui\OperationHistoryPages.ps1','ui\NavigationContext.ps1','web\app.js','web\app.css')
 $sourceBefore=@($sourceFiles|ForEach-Object {[pscustomobject]@{Path=$_;SHA256=(Hash (Join-Path $script:FixturePackageRoot $_))}})
 $SelfTest=$true;$ReadOnlyLaunch=$false;$StartupLaunch=$false;$TestOutputDirectory=''
 $source=[IO.File]::ReadAllText((Join-Path $script:FixturePackageRoot 'TradeChannel.ps1'));$begin=$source.IndexOf('$ErrorActionPreference=');$end=$source.IndexOf("foreach(`$name in @('Home','Nodes','Setup','Settings'))")
 if($begin -lt 0 -or $end -le $begin){throw 'Production presentation bootstrap changed.'}
 Invoke-Expression ($source.Substring($begin,$end-$begin).Replace('$PSScriptRoot','$script:FixturePackageRoot'))
 $uiRoot=$script:Root;$script:Root=$f.Root;$script:Store=Join-Path $f.Root 'Product';$script:JobRoot=Join-Path $script:Store 'jobs';$script:WebFormsFixture=$true
 $script:Prefs=@{NodeId=$f.Active;Mode='Rule';Exit='HongKong';Daily='Direct';Agents='Trade';OpenAtLogin=$false}
 $script:Overview=[pscustomobject]@{StateKey='Disconnected';Running=$false;ReadState='Known';GuardState='Protected';NinjaRunning=$false;SessionId='isolated-stopped';ActiveLineId=$f.Active;ActiveProfileId='Udp';NodeName='保留主线（隔离）';Mode='rule';Exit='hk';DesiredDaily='direct';TradePrograms=@('synthetic-guarded-program')}
 $script:UserSettings=@{AutoTrustFirstConnection=$true;AutoConnectOnLogin=$false};$script:Providers=[pscustomobject]@{Items=@()};$script:WebTasksAt=[DateTime]::UtcNow
 $script:Tray=New-Object Windows.Forms.NotifyIcon;$script:Window.ShowInTaskbar=$false;$script:Window.ShowActivated=$false;$script:Window.Left=-16000;$script:Window.Top=-16000;$script:Window.Width=1280;$script:Window.Height=900
 EventProof 'Read starting lines through actual isolated Nodes Worker'
 $initialWork=BeginActualWorker @{Action='Nodes'};$initial=FinishActualWorker $initialWork
 WebCheck ($initial.Ok -and @($initial.Data).Count -eq 2 -and @($initial.Data|Where-Object {$_.LineId -ceq $f.Target}).Count -eq 1 -and @($initial.Data|Where-Object {$_.Profiles.Count -ne 1}).Count -eq 0) 'Actual LineStore Nodes accepts both complete synthetic lines without a fake list'
 $script:Nodes=@($initial.Data)
 $script:Window.Show();[Threading.SynchronizationContext]::SetSynchronizationContext((New-Object Windows.Threading.DispatcherSynchronizationContext($script:Window.Dispatcher)))
 InitializeTCWebShell -DataFolder (Join-Path $f.Root 'browser') -Fixture
 $deadline=[DateTime]::UtcNow.AddSeconds(30);while(-not $script:WebReady -and -not $script:WebFailed -and [DateTime]::UtcNow -lt $deadline){Pump}
 WebCheck ($script:Smoke -and $script:WebReady -and -not $script:WebFailed) ('Real offscreen WebView2 initialized: '+$script:WebFailureMessage)
 WaitDom "document.querySelectorAll('.line-table tbody tr').length === 2 && document.querySelector('.signal-title').textContent.includes('未连接')"
 $browserVersion=$script:WebShell.CoreWebView2.Environment.BrowserVersionString;Shot '01-before-delete'

 EventProof 'Cancel wait while actual preview Worker is running'
 $indexBefore=Hash (Join-Path $f.Root 'Product\index.json');$runtimeBefore=Hash (Join-Path $f.Root 'runtime.json')
 OpenDeleteDetail 'CancelWaiting';$cancelCapture=PendingCapture 'RecordDeletePreview';$cancelWork=BeginActualWorker $cancelCapture.Request $cancelCapture
 WebCheck ((Js "document.querySelector('[data-action=confirmDialog]').textContent === '取消检查'") -ceq 'true') 'Immediate progress dialog exposes cancellation before the Worker finishes'
 Shot '02-cancellable-wait';Click '[data-action="confirmDialog"]'
 WebCheck ($script:DeployUI.RecordDeletePending.Phase -ceq 'Cancelled' -and (CommitCount) -eq 0) 'Cancel waiting does not capture or submit a deletion'
 $cancelResult=FinishActualWorker $cancelWork
 WaitDom "!document.querySelector('[role=alertdialog]')"
 WebCheck ($cancelResult.Ok -and (Hash (Join-Path $f.Root 'Product\index.json')) -ceq $indexBefore -and (Hash (Join-Path $f.Root 'runtime.json')) -ceq $runtimeBefore -and (CommitCount) -eq 0) 'Late real preview result cannot reopen confirmation or change the cancelled target'
 $script:WebCases.Add([pscustomobject]@{Case='CancelWaiting';Passed=$true;ActualPreview=$true;CommitRequests=0});Shot '03-cancelled'

 EventProof 'Show real blocked preview and its target-bound handling entry'
 $savedRuntime=[IO.File]::ReadAllBytes((Join-Path $f.Root 'runtime.json'));$r=Read-TCDJson (Join-Path $f.Root 'runtime.json');$r.CleanupError=$true;Put (Join-Path $f.Root 'runtime.json') $r
 OpenDeleteDetail 'BlockedPreview';$blockedCapture=PendingCapture 'RecordDeletePreview';$blockedWork=BeginActualWorker $blockedCapture.Request $blockedCapture;$blocked=FinishActualWorker $blockedWork
 WaitDom "document.querySelector('[data-action=confirmDialog]')?.textContent === '检查并处理'"
 WebCheck ($blocked.Ok -and -not $blocked.Data.PreviewToken -and @($blocked.Data.Blocked).Count -gt 0 -and $script:DeployUI.RecordDeletePending.Phase -ceq 'Blocked') 'Actual cleanup uncertainty blocks deletion rather than reporting success'
 WebCheck ($script:DialogContext.Pending.Ids[0] -ceq ('Line:'+$f.Target) -and (Js "document.querySelector('[role=alertdialog]').textContent.includes('尚未删除')") -ceq 'true') 'Blocked handling entry retains the original line and states that nothing was deleted'
 WebCheck ((Js "!!document.querySelector('.dialog-details') && !document.querySelector('.dialog-details').open") -ceq 'true') 'Blocked technical evidence starts folded'
 Shot '04-blocked';Click '[data-action="cancelDialog"]'
 [IO.File]::WriteAllBytes((Join-Path $f.Root 'runtime.json'),$savedRuntime)
 $script:WebCases.Add([pscustomobject]@{Case='BlockedPreview';Passed=$true;ActualPreview=$true;HandlingEntryVerified=$true;RecoveryExecuted=$false;Codes=@($blocked.Data.Blocked|ForEach-Object {$_.Code})})

 EventProof 'A stale confirmation returns a known refusal with an immediate retry entry'
 OpenDeleteDetail 'StaleConfirmation';$staleCapture=PendingCapture 'RecordDeletePreview';$staleWork=BeginActualWorker $staleCapture.Request $staleCapture;$stalePreview=FinishActualWorker $staleWork
 WaitDom "document.querySelector('[data-action=confirmDialog]')?.textContent === '删除线路'"
 $staleRecord=Join-Path $f.Root ('Product\lines\'+$f.Target+'\line.json');$staleDoc=Read-TCDJson $staleRecord;$staleDoc.Revision++;Put $staleRecord $staleDoc
 Click '[data-action="confirmDialog"]';$staleCommit=PendingCapture 'RecordDeleteCommit';$staleCommitWork=BeginActualWorker $staleCommit.Request $staleCommit;$staleResult=FinishActualWorker $staleCommitWork
 WebCheck (-not $staleResult.Ok -and -not $staleResult.OutcomeUnknown -and $staleResult.Code -ceq 'CleanupPreviewStale') 'The real Worker classifies a stale preview as a known refusal before mutation'
 WaitDom "document.querySelector('[data-action=confirmDialog]')?.textContent === '重新检查并删除'"
 WebCheck ($script:DeployUI.RecordDeletePending.Phase -ceq 'NotApplied' -and -not $script:DeployUI.RecordDeletePending.Submitted -and [IO.File]::Exists($f.TargetManifest)) 'The actual failure callback keeps the target and exposes a new-check entry'
 Shot '04-stale-confirmation-retry';Click '[data-action="cancelDialog"]'
 # Start the independent success scenario with its original commit counters.
 $script:Actions.Clear();$script:CompletedCaptures.Clear()

 EventProof 'Real failed-rollback deletion: one confirmation and actual commit'
 $preserve=@('deployment.json','ui-preferences.json',('Product\nodes\'+$f.Active+'\manifest.json'),('Product\nodes\'+$f.Active+'\config.json'),('Product\nodes\'+$f.Active+'\device.key'),('Product\lines\'+$f.Active+'\line.json'),('Product\lines\'+$f.Active+'\profiles\Udp-fixture\manifest.json'),('Product\lines\'+$f.Active+'\profiles\Udp-fixture\config.json'))
 $retainedBefore=@($preserve|ForEach-Object {[pscustomobject]@{Path=$_;SHA256=(Hash (Join-Path $f.Root $_))}})
 OpenDeleteDetail 'DeleteFailedRollback';$previewCapture=PendingCapture 'RecordDeletePreview';$previewWork=BeginActualWorker $previewCapture.Request $previewCapture;$preview=FinishActualWorker $previewWork
 WaitDom "document.querySelector('[data-action=confirmDialog]')?.textContent === '删除线路'"
 WebCheck ($preview.Ok -and $preview.Data.EligibleCount -eq 1 -and $preview.Data.ReferenceReleaseCount -eq 1 -and $preview.Data.PreviewToken -and $script:DeployUI.RecordDeletePending.Phase -ceq 'Ready') 'Real failed rollback preview safely authorizes exactly one historical reference release'
 WebCheck ((Js "document.querySelectorAll('[role=alertdialog]').length === 1 && document.querySelectorAll('[role=alertdialog] [data-action=confirmDialog]').length === 1 && document.querySelector('[role=alertdialog]').textContent.includes('服务器上的服务会保留')") -ceq 'true') 'Only one explicit local-line deletion confirmation is shown'
 WebCheck ((CommitCount) -eq 0 -and [IO.File]::Exists($f.TargetManifest)) 'Preview and confirmation have not yet deleted or committed anything'
 Shot '05-single-confirmation'
 $repeat=(Js "(() => {const b=document.querySelector('[data-action=confirmDialog]');b.click();const disabled=b.disabled;b.click();return {DisabledAfterFirstClick:disabled,SecondClickAttempted:true};})()")|ConvertFrom-Json
 for($i=0;$i -lt 3;$i++){Pump}
 WebCheck ($repeat.DisabledAfterFirstClick -and $repeat.SecondClickAttempted) 'Actual WebView2 immediately disables confirmation before a second DOM click attempt'
 WebCheck ((CommitCount) -eq 1 -and $script:DeployUI.RecordDeletePending.Submitted) 'One confirmation captures exactly one original commit request'
 $commitCapture=PendingCapture 'RecordDeleteCommit';$commitWork=BeginActualWorker $commitCapture.Request $commitCapture
 MainPage 'settings';WebCheck ($script:WebPage -ceq 'settings') 'Real web navigation changes page while the commit is outstanding'
 $committed=FinishActualWorker $commitWork
 WebCheck ($committed.Ok -and $committed.Data.DataDeleted -and $committed.Data.DeletedLineIds -contains $f.Target -and $committed.Data.DeletedLineIds -notcontains $f.Active) 'Actual commit returns deletion evidence for only the selected synthetic line'
 WaitDom "document.querySelector('nav .active').dataset.page === 'settings' && !document.querySelector('[role=alertdialog]')"
 WebCheck ($script:WebPage -ceq 'settings' -and (CommitCount) -eq 1 -and $script:DeployUI.RecordDeletePending.Phase -ceq 'Deleted') 'Cross-page real commit keeps the current page and does not reopen old confirmation'
 WebCheck (@($script:Nodes).Count -eq 1 -and $script:Nodes[0].LineId -ceq $f.Active) 'Commit callback removes only its confirmed target from the existing cache'
 $refreshCapture=PendingCapture 'Nodes';WebCheck ($refreshCapture.CallbackContext.Type -ceq 'LocalCleanupRefresh') 'Production deletion callback captures an authoritative Nodes refresh'
 $refreshWork=BeginActualWorker $refreshCapture.Request $refreshCapture;$refreshed=FinishActualWorker $refreshWork
 WebCheck ($refreshed.Ok -and @($refreshed.Data).Count -eq 1 -and $refreshed.Data[0].LineId -ceq $f.Active -and $script:DeployUI.CleanupRefresh.Phase -ceq 'Completed') 'Real authority reread completes the original refresh callback with the remaining line'
 MainPage 'home';WaitDom "document.querySelectorAll('.line-table tbody tr').length === 1 && document.querySelector('.line-name').textContent === '保留主线（隔离）'"
 WebCheck ((Js "!document.querySelector('.empty') && !document.body.textContent.includes('失败测试线（隔离）？') && !document.querySelector('[role=alertdialog]')") -ceq 'true') 'Returning home shows the other line without a false empty list or stale confirmation'
 $index=Read-TCDJson (Join-Path $f.Root 'Product\index.json');$runtime=Read-TCDJson (Join-Path $f.Root 'runtime.json')
 WebCheck ($index.nodes.Count -eq 1 -and $index.nodes[0].id -ceq $f.Active -and -not [IO.File]::Exists($f.TargetManifest)) 'Persisted authoritative index and target files agree with the web result'
 WebCheck ($runtime.State -ceq 'Disconnected' -and -not $runtime.ManifestPath -and -not $runtime.ConfigPath -and $runtime.TradingDirectAccessBlocked -eq $true) 'Cleanup clears only the proved stopped reference and retains the synthetic guard flag'
 foreach($file in $retainedBefore){WebCheck ((Hash (Join-Path $f.Root $file.Path)) -ceq $file.SHA256) ('Retained bytes unchanged: '+$file.Path)}
 $script:WebCases.Add([pscustomobject]@{Case='DeleteFailedRollback';Passed=$true;RealPreview=$true;RealCommit=$true;RealNodesRefresh=$true;CommitRequests=(CommitCount);RemainingLineId=$f.Active;DeletedLineId=$f.Target;CrossPageCommit=$true})
 Shot '06-after-authoritative-refresh'
 $sourceAfter=@($sourceBefore|ForEach-Object {[pscustomobject]@{Path=$_.Path;Before=$_.SHA256;After=(Hash (Join-Path $script:FixturePackageRoot $_.Path))}})
 WebCheck (@($sourceAfter|Where-Object {$_.Before -cne $_.After}).Count -eq 0) 'Product sources stayed unchanged throughout this integration run'
 WebCheck ($script:Smoke -and @($script:ActualWorkers|Where-Object {$_.Action -cnotin @('Nodes','RecordDeletePreview','RecordDeleteCommit')}).Count -eq 0) 'All actual Workers obey the exact fixture action whitelist and UI remains Smoke'
 $passed=$true;EventProof 'Passed'
}catch{
 $failure=$_.Exception.Message;$failureStack=$_.ScriptStackTrace
 try{if($script:WebReady){Shot 'failure';[IO.File]::WriteAllText((Join-Path $script:ReportRoot 'failure-dom.txt'),(Js 'document.body.innerText'),[Text.UTF8Encoding]::new($true))}}catch{}
 Write-Output ('FAILED '+$failure)
}finally{
 $result=[ordered]@{Passed=$passed;Checks=$script:WebChecks.Count;Assertions=$script:WebChecks.ToArray();Failure=$failure;Stack=$failureStack;Stage=$script:Step;PowerShellVersion=$PSVersionTable.PSVersion.ToString();ApartmentState=[string][Threading.Thread]::CurrentThread.ApartmentState;BrowserRuntime='WebView2';BrowserVersion=$browserVersion;Smoke=$script:Smoke;ActualWorkerCount=$script:ActualWorkers.Count;ActualWorkers=$script:ActualWorkers.ToArray();Cases=$script:WebCases.ToArray();WaitTimings=$script:WaitTimings.ToArray();FixtureAssertions=$fixtureAssertions;FixtureRoot=$(if($f){$f.Root}else{''});ProductionDataAccessed=$false;ProductionWrites=0;RealConnectionExecuted=$false;WfpOperations=0;RuntimeAdapter='Synthetic CT Observe/Start/Stop/Verify, actual CTExecute rollback and persisted journals';CallbackDelivery='Production CompleteUiJob with real Worker result; Smoke dispatch envelopes adapted only at the isolated process boundary';SourceFiles=$sourceAfter;NotCovered=@('Installed application entry or deployment','Actual network and WFP protection','Executing the blocked recovery action','Cross-page preview completion before confirmation','Refresh-failure retry and process interruption','Physical user input, first display paint or production 200ms timing acceptance')}
 [IO.File]::WriteAllText((Join-Path $script:ReportRoot 'result.json'),($result|ConvertTo-Json -Depth 18),[Text.UTF8Encoding]::new($true))
 foreach($proof in $script:ActualWorkers){[IO.File]::WriteAllText((Join-Path $script:ReportRoot ($proof.RequestId+'.worker.json')),($proof|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($true))}
 $browserProcess=$null
 try{if($script:WebShell.CoreWebView2){$browserProcess=[Diagnostics.Process]::GetProcessById([int]$script:WebShell.CoreWebView2.BrowserProcessId)}}catch{}
 try{if($script:WebShell){$script:WebShell.Dispose()};if($script:Window){$script:Window.Close()};if($script:Tray){$script:Tray.Dispose()};if($script:ToastTimer){$script:ToastTimer.Stop()}}catch{}
 if($browserProcess){try{if(-not $browserProcess.WaitForExit(10000)){throw 'Owned WebView2 process has not exited; fixture retained.'}}finally{$browserProcess.Dispose()}}
 foreach($p in $script:OwnedWorkerProcesses){try{if($p.HasExited){$p.Dispose()}}catch{}}
 # Only disposable, verified roots are recursively removed. Keep a failed
 # Worker fixture for reproduction; never remove a process's live workspace.
 if($passed -and $f){$root=AssertWebFixture $f.Root -RootOnly;Remove-Item -LiteralPath $root -Recurse -Force}
 if($uiRoot){$full=[IO.Path]::GetFullPath($uiRoot).TrimEnd('\');$boundary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\';if($full.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($full) -cmatch '^TradeChannel-ui-fixture-[a-f0-9]{32}$' -and [IO.Directory]::Exists($full) -and -not @(Get-ChildItem -LiteralPath $full -Recurse -Force|Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count){Remove-Item -LiteralPath $full -Recurse -Force}}
}
[pscustomobject]@{Passed=$passed;Checks=$script:WebChecks.Count;ActualWorkers=$script:ActualWorkers.Count;Failure=$failure;Report=(Join-Path $script:ReportRoot 'result.json')}|ConvertTo-Json
if(-not $passed){exit 1}
