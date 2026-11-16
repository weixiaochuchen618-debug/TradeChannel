#requires -Version 5.1
[CmdletBinding()]param([string]$PackageRoot='',[Parameter(Mandatory=$true)][string]$ReportDirectory)
$ErrorActionPreference='Stop'
if([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw 'Use Windows PowerShell -Sta.'}
if(-not $PackageRoot){$PackageRoot=Split-Path $PSScriptRoot -Parent}
$script:FixturePackageRoot=[IO.Path]::GetFullPath($PackageRoot)
$script:ReportRoot=[IO.Path]::GetFullPath($ReportDirectory)
if($script:ReportRoot.StartsWith('C:\ProgramData\',[StringComparison]::OrdinalIgnoreCase) -or $script:ReportRoot.StartsWith('C:\tradechannel',[StringComparison]::OrdinalIgnoreCase)){throw 'Use a workspace report directory.'}
$null=[IO.Directory]::CreateDirectory($script:ReportRoot)
function Start-Process {throw 'Workflow tests forbid external process launches.'}
function Stop-Process {throw 'Workflow tests forbid stopping real processes.'}
function Invoke-WebRequest {throw 'Workflow tests forbid network access.'}
function Invoke-RestMethod {throw 'Workflow tests forbid network access.'}

# Initialize exactly the production presentation and business callbacks. Stop
# before startup, timers or worker dispatch; SelfTest owns a new temporary store.
$SelfTest=$true;$ReadOnlyLaunch=$false;$StartupLaunch=$false;$TestOutputDirectory=''
$source=[IO.File]::ReadAllText((Join-Path $script:FixturePackageRoot 'TradeChannel.ps1'))
$begin=$source.IndexOf('$ErrorActionPreference=')
$end=$source.IndexOf("foreach(`$name in @('Home','Nodes','Setup','Settings'))")
if($begin -lt 0 -or $end -le $begin){throw 'Presentation bootstrap boundary changed.'}
$bootstrap=$source.Substring($begin,$end-$begin).Replace('$PSScriptRoot','$script:FixturePackageRoot')
Invoke-Expression $bootstrap
$script:WebFormsFixture=$true
$script:Tray=New-Object Windows.Forms.NotifyIcon
$script:Window.ShowInTaskbar=$false;$script:Window.ShowActivated=$false
$script:Window.Left=-16000;$script:Window.Top=-16000;$script:Window.Width=1280;$script:Window.Height=900
$script:TestChecks=New-Object 'Collections.Generic.List[string]'
$script:CompletedJobs=New-Object 'Collections.Generic.HashSet[object]'
$hk='11111111-1111-1111-1111-111111111111';$us='22222222-2222-2222-2222-222222222222'
$tokens=$null;$parseErrors=$null
$fixtureAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $script:PackageRoot 'ui\SelfTest.ps1'),[ref]$tokens,[ref]$parseErrors)
$fixtureFunction=@($fixtureAst.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst]},$false)|Where-Object Name -eq 'Fixture')[0]
Set-Item Function:script:Fixture ([scriptblock]::Create($fixtureFunction.Body.Extent.Text.Substring(1,$fixtureFunction.Body.Extent.Text.Length-2)))
Fixture
foreach($node in $script:Nodes){$node|Add-Member NoteProperty LineId $node.id -Force}
$script:Overview|Add-Member NoteProperty ActiveLineId $hk -Force
$script:Overview|Add-Member NoteProperty ActiveProfileId 'Udp' -Force
$script:Overview|Add-Member NoteProperty ReadState 'Known' -Force
$script:Overview|Add-Member NoteProperty SessionId 'workflow-fixture' -Force
$script:UserSettings=@{AutoTrustFirstConnection=$true;AutoConnectOnLogin=$false}
$script:WebTasksAt=[DateTime]::UtcNow
function Check {param([bool]$Condition,[string]$Name)if(-not $Condition){throw ('Workflow assertion: '+$Name)};$script:TestChecks.Add($Name)}
function Pump {[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 15}
function Await {param($Task)$deadline=[DateTime]::UtcNow.AddSeconds(20);while(-not $Task.IsCompleted){Pump;if([DateTime]::UtcNow -gt $deadline){throw 'WebView operation exceeded deadline'}};$Task.GetAwaiter().GetResult()}
function Js {param([string]$Code)Await ($script:WebShell.CoreWebView2.ExecuteScriptAsync($Code))}
function WaitDom {param([string]$Expression)$deadline=[DateTime]::UtcNow.AddSeconds(12);do{Pump;if((Js $Expression) -ceq 'true'){return}}while([DateTime]::UtcNow -lt $deadline);throw ('DOM condition: '+$Expression)}
function Click {param([string]$Selector)
 $literal=$Selector|ConvertTo-Json -Compress
 WaitDom ("!!document.querySelector("+$literal+") && !document.querySelector("+$literal+").disabled")
 $null=Js ("document.querySelector("+$literal+").click()")
 for($i=0;$i -lt 3;$i++){Pump}
}
function FieldValue {param([string]$Name,[string]$Value)
 $selector=('[data-control-name="'+$Name+'"]')|ConvertTo-Json -Compress;$literal=$Value|ConvertTo-Json -Compress
 $null=Js ("(() => {const input=document.querySelector("+$selector+"); input.focus(); input.value="+$literal+"; input.dispatchEvent(new Event('input',{bubbles:true}));})()")
 for($i=0;$i -lt 3;$i++){Pump}
}
function CompleteJob {param([string]$Action,$Data)
 $job=@($script:Actions|Where-Object {$_.Request.Action -ceq $Action -and -not $script:CompletedJobs.Contains($_)}|Select-Object -Last 1)
 if($job.Count -ne 1){throw ('No pending isolated action: '+$Action)}
 $job=$job[0];$null=$script:CompletedJobs.Add($job);$script:Pending=$null
 if($job.Complete){& $job.Complete $Data $job.CallbackContext}
 if($job.Lifecycle.Finalized){& $job.Lifecycle.Finalized ([pscustomobject]@{UiRequestId=$job.Lifecycle.UiRequestId;Status='Completed'}) $job.CallbackContext}
 $script:HostPanel.IsEnabled=$true;SyncTCWebState -Force
}
function CheckWeb {param([string]$Name)
 Check ($script:WebShell.Visibility -eq 'Visible' -and $script:Window.FindName('Scroll').Parent.Visibility -eq 'Collapsed' -and $script:Window.FindName('NavHome').Parent.Visibility -eq 'Collapsed') ($Name+' stays in the web shell')
 Check ((Js "document.body.textContent.includes('此控件暂不支持') || document.body.textContent.includes('此内容暂不支持')") -ceq 'false') ($Name+' has no unsupported controls')
}
function Shot {param([string]$Name)
 [IO.File]::WriteAllText((Join-Path $script:ReportRoot ($Name+'.snapshot.json')),(@{Type='snapshot';State=(GetTCWebSnapshot);Page=$script:WebPage}|ConvertTo-Json -Depth 48),[Text.UTF8Encoding]::new($true))
 $stream=[IO.File]::Open((Join-Path $script:ReportRoot ($Name+'.png')),[IO.FileMode]::Create)
 try{$null=Await ($script:WebShell.CoreWebView2.CapturePreviewAsync([Microsoft.Web.WebView2.Core.CoreWebView2CapturePreviewImageFormat]::Png,$stream))}finally{$stream.Dispose()}
}
function MainPage {param([string]$Name)Click ('nav [data-page="'+$Name+'"]');WaitDom ('!document.querySelector(".workflow") && document.querySelector("nav .active").dataset.page === '+($Name|ConvertTo-Json -Compress))}
function ChooseFile {param($Title,$Filter,[switch]$Save,$Name)if($Filter -like '*.exe*'){Join-Path $script:Root 'terminal64.exe'}else{Join-Path $script:Root 'fixture-diagnostics.json'}}
$passed=$false;$failure=''
$script:UiCommands=New-Object 'Collections.Generic.List[object]'
function RequestKeys {param($Value)if($Value -is [Collections.IDictionary]){@($Value.Keys)}else{@($Value.PSObject.Properties.Name)}}
function RequestsText {$t=@($script:AllSelfTestRequests|ForEach-Object {$_.Request}|ForEach-Object {$_|ConvertTo-Json -Depth 12 -Compress});return (($t -join "`n")+'')}
# In-memory command channel is replaced by a recorder: no module is loaded, no network is touched.
function StartUiCommand {param([string]$Module,[string]$Command,[hashtable]$Arguments,[scriptblock]$Complete,[scriptblock]$Failed,$Context,[string]$Message='')
 $script:UiCommands.Add([pscustomobject]@{Module=$Module;Command=$Command;Arguments=$Arguments;Complete=$Complete;Failed=$Failed;Context=$Context})
}
try{
 $script:Window.Show();[Threading.SynchronizationContext]::SetSynchronizationContext((New-Object Windows.Threading.DispatcherSynchronizationContext($script:Window.Dispatcher)))
 InitializeTCWebShell -DataFolder (Join-Path $script:Root 'browser') -Fixture
 $deadline=[DateTime]::UtcNow.AddSeconds(25)
 while(-not $script:WebReady -and -not $script:WebFailed -and [DateTime]::UtcNow -lt $deadline){Pump}
 Check ($script:WebReady -and -not $script:WebFailed) ('WebView2 initialized: '+$script:WebFailureMessage)
 WaitDom "document.querySelector('.signal-title')?.textContent.includes('已连接') === true"

 # ---- New computer: join with a one-time invitation code ----
 # 0.21.2: every page entry opens the add-line flow; this form is its legacy exit.
 MainPage 'lines'
 Check ((Js "!!document.querySelector('[data-action=pairStart]') && !document.querySelector('#main [data-action=joinLine]')") -ceq 'true') 'The Lines page offers joining with an invitation code through the add-line flow'
 Click '[data-action="pairStart"]'
 WaitDom "document.querySelector('h1')?.textContent === '添加线路' && document.querySelector('[data-testid=pair-legacy]') !== null"
 Click '[data-testid="pair-legacy"]'
 WaitDom "document.querySelector('h1')?.textContent === '加入已有线路' && document.querySelector('[data-control-name=OnlineInvitationCode]') !== null"
 CheckWeb 'Join by invitation';Shot '16-join-invitation'
 Check ((Js "document.querySelector('[data-control-name=OnlineInvitationCode]').type") -ceq '"password"') 'The invitation code field is masked'
 FieldValue 'OnlineInvitationCode' 'not-a-code'
 Click '[data-control-name="OnlinePairJoin"]'
 Check ($script:UiCommands.Count -eq 0) 'An invalid invitation code starts no command'
 $secretCode='TCI1.'+('A'*96)
 FieldValue 'OnlineInvitationCode' $secretCode
 Click '[data-control-name="OnlinePairJoin"]'
 Check ($script:UiCommands.Count -eq 1 -and $script:UiCommands[0].Module -ceq 'PairingOnline.psm1' -and $script:UiCommands[0].Command -ceq 'New-TCPairOnlineEnrollment' -and $script:UiCommands[0].Arguments.InvitationCode -ceq $secretCode -and $script:UiCommands[0].Arguments.Root -ceq $script:Root) 'Enrollment runs through the in-memory command channel with the local data root'
 Check (-not ((RequestsText).Contains($secretCode))) 'The invitation code never enters a worker request'
 Check (-not ((GetTCWebSnapshot|ConvertTo-Json -Depth 48 -Compress).Contains($secretCode))) 'The invitation code is absent from the outbound view snapshot'
 $enrollmentId='33333333-3333-3333-3333-333333333333'
 $before=$script:Actions.Count
 & $script:UiCommands[0].Complete ([pscustomobject]@{EnrollmentId=$enrollmentId}) $script:UiCommands[0].Context
 Check ($script:Actions.Count -eq ($before+1) -and $script:Actions[-1].Request.Action -ceq 'PairOnlineFinish' -and $script:Actions[-1].Request.EnrollmentId -ceq $enrollmentId -and @(RequestKeys $script:Actions[-1].Request|Where-Object {$_ -cnotin @('Action','EnrollmentId')}).Count -eq 0) 'Authorization is requested through the worker with only the local enrollment id'
 Import-Module (Join-Path $script:PackageRoot 'WorkerContracts.psm1') -Force -DisableNameChecking
 $contract=Get-TCWorkerActionContract 'PairOnlineFinish'
 Check ($contract.Known -and $contract.Modules -contains 'PairingOnline.psm1' -and -not $contract.ReadOnly) 'PairOnlineFinish is a declared mutating worker action'
 $rejected=$false;try{Assert-TCWorkerRequestPreflight ([pscustomobject]@{Action='PairOnlineFinish';EnrollmentId='not-a-guid'})}catch{$rejected=$true}
 Check $rejected 'PairOnlineFinish rejects a malformed enrollment id'
 $rejected=$false;try{Assert-TCWorkerRequestPreflight ([pscustomobject]@{Action='PairOnlineFinish';EnrollmentId=$enrollmentId;InvitationCode=$secretCode})}catch{$rejected=$true}
 Check $rejected 'PairOnlineFinish rejects any extra field such as the invitation code'
 CompleteJob 'PairOnlineFinish' ([pscustomobject]@{EnrollmentId=$enrollmentId;NodeName='共享线路'})
 Check ($script:Actions[-1].Request.Action -ceq 'PairComplete' -and $script:Actions[-1].Request.EnrollmentId -ceq $enrollmentId -and @(RequestKeys $script:Actions[-1].Request) -cnotcontains 'EncryptedAuthorization') 'The saved authorization is completed locally without re-sending secrets'
 CompleteJob 'PairComplete' ([pscustomobject]@{EnrollmentId=$enrollmentId;NodeId=$hk;RunId='';DeploymentCompleteness='Complete'})
 WaitDom "document.querySelector('[data-control-name=OnlinePairConnect]') !== null && document.body.textContent.includes('线路已加入')"
 CheckWeb 'Join complete';Shot '17-join-complete'

 # ---- Management computer: generate a one-time invitation code ----
 # A real RSA public key is needed because the fingerprint is computed by the production pairing crypto.
 $rsa=New-Object Security.Cryptography.RSACng 3072;$rsaParameters=$rsa.ExportParameters($false);$rsa.Dispose()
 $jwk=[pscustomobject]@{kty='RSA';n=([Convert]::ToBase64String($rsaParameters.Modulus).TrimEnd('=').Replace('+','-').Replace('/','_'));e=([Convert]::ToBase64String($rsaParameters.Exponent).TrimEnd('=').Replace('+','-').Replace('/','_'))}
 InitializeServerUI;$m=$script:DeployUI.Management
 $m.Authenticated=$true;$m.SessionRef=@{RunId='44444444-4444-4444-4444-444444444444';InstanceId='55555555-5555-5555-5555-555555555555'};$m.ServerId='66666666-6666-6666-6666-666666666666'
 $m.Info=[pscustomobject]@{RemoteOwnerId='77777777-7777-7777-7777-777777777777';ManagementSigningPublicKey=$jwk;Node=[pscustomobject]@{NodeId='88888888-8888-8888-8888-888888888888';ServerPublicKey=('S'*43+'=');PublicEndpoint='203.0.113.10:51820'}}
 $m.Input.DeviceName='办公室电脑'
 $script:Role='servers'
 PageHead '服务器管理夹具' '' 'servers'
 $card=Card;$p=Stack;$card.Child=$p;AddOnlineInviteCardUI $p;AddC $script:HostPanel $card;SyncTCWebState -Force
 WaitDom "document.querySelector('[data-control-name=OnlineInviteCreate]') !== null"
 CheckWeb 'Invitation generation card';Shot '18-invite-card'
 $before=$script:Actions.Count
 Click '[data-control-name="OnlineInviteCreate"]'
 Check ($script:Actions.Count -eq ($before+1) -and $script:Actions[-1].Request.Action -ceq 'ServerOperation' -and $script:Actions[-1].Request.Operation -ceq 'pair_online_create') 'Generating a code dispatches the online create operation once'
 $request=$script:Actions[-1].Request.Input
 Check ($request.PublicHost -ceq '203.0.113.10' -and $request.Port -eq 18443 -and $request.ExpiresInSeconds -eq 600 -and $request.DeviceName -ceq '办公室电脑' -and $request.ExpectedServerBinding.NodeId -ceq '88888888-8888-8888-8888-888888888888' -and $request.ExpectedManagementFingerprint.Length -ge 20) 'The create request is bound to the verified server identity and public address'
 Check ($request.InviteId -match '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$') 'The invitation id is generated once and kept for safe retry'
 $issued=[pscustomobject]@{InviteId=$request.InviteId;State='Open';DeviceName='办公室电脑';ExpiresAtUtc=[DateTimeOffset]::UtcNow.AddMinutes(10).ToString('o');InvitationCode=('TCI1.'+('B'*96));PublicHost='203.0.113.10';Port=18443}
 CompleteJob 'ServerOperation' $issued
 PageHead '服务器管理夹具' '' 'servers'
 $card=Card;$p=Stack;$card.Child=$p;AddOnlineInviteCardUI $p;AddC $script:HostPanel $card;SyncTCWebState -Force
 WaitDom "document.querySelector('[data-control-name=OnlineInviteCopy]') !== null && document.querySelector('[data-control-name=OnlineInviteCode]') !== null"
 CheckWeb 'Invitation issued';Shot '19-invite-issued'
 Check ((Js "document.body.textContent.includes('TCP 18443')") -ceq 'true') 'The listener port requirement is stated next to the code'
 Check (-not ((RequestsText).Contains('TCI1.BBBB'))) 'The issued code is never written into worker requests'
 # 0.21.3: copy buttons use the non-throwing helper; a busy clipboard is a toast, not a failure dialog.
 Click '[data-control-name="OnlineInviteCopy"]'
 Check ($script:LastCopiedText -ceq ('TCI1.'+('B'*96)) -and $script:LastToast -ceq '已复制邀请码' -and $script:Window.FindName('Overlay').Visibility -ne 'Visible') 'Copying the invitation code goes through the copy helper without a failure dialog'
 $before=$script:Actions.Count
 $script:DeployUI.PendingManagement=$null
 Click '[data-control-name="OnlineInviteCancel"]'
 Check ($script:Actions.Count -eq ($before+1) -and $script:Actions[-1].Request.Operation -ceq 'pair_online_cancel' -and $script:Actions[-1].Request.Input.InviteId -ceq $request.InviteId) 'Cancelling targets exactly the issued invitation'
 # 0.21.3: the logged-in server page leads with the 10-minute code; the 24-hour
 # offline handoff and its approval step stay folded until used.
 $script:DeployUI.PendingManagement=$null;$m.OnlineInvite=$null;$script:DeployUI.Invite=$null;InitializeServerNavigationUI
 $srv=[pscustomobject]@{LocalRecordId=$m.ServerId;RecordState='Active';Host='203.0.113.10';ServerPublicKey=('S'*43+'=');PinnedHostKey='SHA256:fixture';OwnershipState='Applied';ManagementAccessState='Managed';Connection=[pscustomobject]@{Host='203.0.113.10';Port=22}}
 $script:DeployUI.Discovery=[pscustomobject]@{Servers=@($srv)};$m.Server=$srv
 $script:ServerNavigationUI.View='server-detail';$script:ServerNavigationUI.DetailKind='Managed';$script:ServerNavigationUI.SelectedServerId=$m.ServerId
 ShowServerManagement;SyncTCWebState -Force
 WaitDom "document.querySelector('[data-control-name=OnlineInviteCreate]') !== null && document.querySelector('[data-control-name=ServerDevices]') !== null"
 Check ((Js "(document.querySelector('[data-control-name=OnlineInviteCreate]').compareDocumentPosition(document.querySelector('[data-control-name=ServerDevices]')) & Node.DOCUMENT_POSITION_FOLLOWING) !== 0") -ceq 'true') 'The invitation card comes before the device list'
 Check ((Js "document.querySelector('.workflow').innerText.includes('离线邀请（24 小时）') && !document.querySelector('.workflow').innerText.includes('生成一次性邀请（24 小时）') && !document.querySelector('.workflow').innerText.includes('批准新电脑申请')") -ceq 'true') 'The 24-hour offline invitation is folded by default'
 CheckWeb 'Server page with invitations';Shot '20-server-invitations'
 # 0.21.4: a code past its deadline is shown as expired with a fresh generate button,
 # even before anyone asks the server for its status.
 $m.OnlineInvite=[pscustomobject]@{InviteId='34343434-3434-4343-8343-343434343434';State='Open';InvitationCode=('TCI1.'+('C'*96));ExpiresAtUtc=[DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o');PublicHost='203.0.113.10';Port=18443}
 ShowServerManagement;SyncTCWebState -Force
 WaitDom "document.querySelector('[data-control-name=OnlineInviteCreate]') !== null && document.querySelector('[data-control-name=OnlineInviteCode]') === null"
 Check ((Js "document.querySelector('.workflow').innerText.includes('已过期') && !document.querySelector('.workflow').innerText.includes('TCI1.CCCC')") -ceq 'true') 'An expired code is labelled expired, hidden, and replaced by the generate button'
 $passed=$true
}catch{
 $failure=$_.Exception.Message
 try{Shot 'failure';[IO.File]::WriteAllText((Join-Path $script:ReportRoot 'failure-dom.txt'),(Js 'document.body.innerText'),[Text.UTF8Encoding]::new($true))}catch{}
 throw
}finally{
 $result=[ordered]@{Passed=$passed;Checks=$script:TestChecks.Count;Assertions=$script:TestChecks.ToArray();Failure=$failure;NetworkChanged=$false;WorkersStarted=0;BrowserRuntime='WebView2';CapturedWorkerActions=@($script:AllSelfTestRequests|ForEach-Object {$_.Request.Action})}
 [IO.File]::WriteAllText((Join-Path $script:ReportRoot 'result.json'),($result|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($true))
 if($script:WebShell){$script:WebShell.Dispose()};$script:Window.Close();$script:Tray.Dispose();$script:ToastTimer.Stop()
 if(Get-Command ClearDeploymentCredentialUI -ErrorAction SilentlyContinue){ClearDeploymentCredentialUI}
 $full=[IO.Path]::GetFullPath($script:Root);$boundary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if($full.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($full) -cmatch '^TradeChannel-ui-fixture-[0-9a-f]{32}$'){try{Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop}catch{}}
}
$result|ConvertTo-Json -Depth 10
