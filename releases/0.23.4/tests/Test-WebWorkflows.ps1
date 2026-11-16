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
 if($job.Lifecycle.Finalized){& $job.Lifecycle.Finalized ([pscustomobject]@{UiRequestId=$job.Lifecycle.UiRequestId;Status='Completed';RequestId=[guid]::NewGuid().ToString('N')}) $job.CallbackContext}
 $script:HostPanel.IsEnabled=$true;SyncTCWebState -Force
}
function FailCapturedJob {param([string]$Action,[string]$Code,[string]$Message)
 $job=@($script:Actions|Where-Object {$_.Request.Action -ceq $Action -and -not $script:CompletedJobs.Contains($_)}|Select-Object -Last 1)
 if($job.Count -ne 1){throw ('No isolated failed action: '+$Action)}
 $job=$job[0];$null=$script:CompletedJobs.Add($job);$script:Pending=$null
 & $job.Failed $Message $job.CallbackContext ([pscustomobject]@{Ok=$false;Code=$Code;OutcomeUnknown=$false})
 if($job.Lifecycle.Finalized){& $job.Lifecycle.Finalized ([pscustomobject]@{UiRequestId=$job.Lifecycle.UiRequestId;RequestId=[guid]::NewGuid().ToString('N');Status='Failed'}) $job.CallbackContext}
 $script:HostPanel.IsEnabled=$true;SyncTCWebState -Force
}
function CheckWeb {param([string]$Name)
 Check ($script:WebShell.Visibility -eq 'Visible' -and $script:Window.FindName('Scroll').Parent.Visibility -eq 'Collapsed' -and $script:Window.FindName('NavHome').Parent.Visibility -eq 'Collapsed') ($Name+' stays in the web shell')
 Check ((Js "document.body.textContent.includes('此控件暂不支持') || document.body.textContent.includes('此内容暂不支持')") -ceq 'false') ($Name+' has no unsupported controls')
 Check ($script:Window.FindName('StatusChip').Visibility -eq 'Collapsed' -and $script:Window.FindName('FooterContext').Visibility -eq 'Collapsed' -and $script:Window.FindName('FooterMode').Text -ceq 'UI TEST') ($Name+' hides duplicate native connection and version while retaining self-test mode')
}
function Shot {param([string]$Name)
 [IO.File]::WriteAllText((Join-Path $script:ReportRoot ($Name+'.snapshot.json')),(@{Type='snapshot';State=(GetTCWebSnapshot);Page=$script:WebPage}|ConvertTo-Json -Depth 48),[Text.UTF8Encoding]::new($true))
 $stream=[IO.File]::Open((Join-Path $script:ReportRoot ($Name+'.png')),[IO.FileMode]::Create)
 try{$null=Await ($script:WebShell.CoreWebView2.CapturePreviewAsync([Microsoft.Web.WebView2.Core.CoreWebView2CapturePreviewImageFormat]::Png,$stream))}finally{$stream.Dispose()}
}
function MainPage {param([string]$Name)Click ('nav [data-page="'+$Name+'"]');WaitDom ('!document.querySelector(".workflow") && document.querySelector("nav .active").dataset.page === '+($Name|ConvertTo-Json -Compress))}
function ChooseFile {param($Title,$Filter,[switch]$Save,$Name)if($Filter -like '*.exe*'){Join-Path $script:Root 'terminal64.exe'}else{Join-Path $script:Root 'fixture-diagnostics.json'}}
$passed=$false;$failure=''
try{
 $script:Window.Show();[Threading.SynchronizationContext]::SetSynchronizationContext((New-Object Windows.Threading.DispatcherSynchronizationContext($script:Window.Dispatcher)))
 InitializeTCWebShell -DataFolder (Join-Path $script:Root 'browser') -Fixture
 $deadline=[DateTime]::UtcNow.AddSeconds(25)
 while(-not $script:WebReady -and -not $script:WebFailed -and [DateTime]::UtcNow -lt $deadline){Pump}
 Check ($script:WebReady -and -not $script:WebFailed) ('WebView2 initialized: '+$script:WebFailureMessage)
 WaitDom "document.querySelector('.signal-title')?.textContent.includes('已连接') === true"
 Check ((Js "document.body.textContent.includes('把注意力') || document.body.textContent.includes('我的连接') || document.body.textContent.includes('安心使用') || document.body.textContent.includes('连接由你掌握')") -ceq 'false') 'Homepage and navigation contain no promotional filler'
 CheckWeb 'Homepage'
 Check ((Js "document.querySelector('#mini-status').hidden && document.querySelectorAll('#version').length === 1") -ceq 'true') 'Homepage keeps one connection summary and one version'
 Shot '01-home'
 $before=$script:Actions.Count
 Click '[data-action="disconnect"]'
 Check ($script:Actions.Count -eq ($before+1) -and $script:Actions[-1].Request.SessionAction -eq 'Disconnect') 'One homepage click directly requests disconnection'
 Check ($script:Window.FindName('Overlay').Visibility -ne 'Visible') 'Disconnection has no confirmation dialog'
 $script:Pending=$null;$script:Overview.Running=$true;SyncTCWebState -Force

 MainPage 'settings';Shot '02-settings'
 Click '[data-action="diagnostics"]'
 $report=[pscustomobject]@{Current=[pscustomobject]@{State='Connected';Guard=[pscustomobject]@{State='Protected'};ObservedAtUtc=[DateTimeOffset]::UtcNow.ToString('o')};Events=@([pscustomobject]@{AtUtc=[DateTimeOffset]::UtcNow.ToString('o');Type='SessionReady';Source='RuntimeSupervisor'});SummaryText='Fixture technical evidence';JournalWarning=''}
 CompleteJob 'RuntimeReport' $report
 WaitDom "document.querySelector('h1')?.textContent === '运行诊断' && document.querySelector('[data-control-name=RuntimeReportRefresh]') !== null"
 CheckWeb 'Diagnostics';Shot '03-diagnostics'
 Click '[data-control-name="RuntimeReportExport"]'
 Check ($script:Actions[-1].Request.Action -eq 'ExportDiagnostics' -and $script:Actions[-1].Request.Path.StartsWith($script:Root)) 'Report export retains its real worker contract and system save-dialog boundary'
 CompleteJob 'ExportDiagnostics' ([pscustomobject]@{Friendly='诊断已保存'})
 Click '[data-action="confirmDialog"]'
 Click '[data-control-name="ProxyRecoveryOpen"]'
 CompleteJob 'ProxyRecoveryStatus' @()
 WaitDom "document.querySelector('h1')?.textContent === '系统代理恢复' && document.body.textContent.includes('没有需要恢复')"
 CheckWeb 'Proxy recovery';Shot '04-proxy-recovery'

 MainPage 'settings'
 $script:DeployUI.HistoryLoaded=$true;$script:DeployUI.HistoryError='';$script:DeployUI.HistoryRecords=@(
  [pscustomobject]@{Id='DeploymentRun:fixture-one';Name='主线路部署';SourceKind='DeploymentRun';Status='Complete';CanDeleteRecord=$true;Classification='History';AttentionRequired=$false;LastActivityAtUtc=[DateTimeOffset]::UtcNow.ToString('o')},
  [pscustomobject]@{Id='DeploymentRun:fixture-two';Name='备用线路部署';SourceKind='DeploymentRun';Status='Complete';CanDeleteRecord=$true;Classification='History';AttentionRequired=$false;LastActivityAtUtc=[DateTimeOffset]::UtcNow.ToString('o')})
 Click '[data-action="history"]'
 WaitDom "document.querySelector('h1')?.textContent === '操作记录' && document.querySelector('[data-control-name=HistorySearch]') !== null"
 CheckWeb 'History';Shot '05-history'
 FieldValue 'HistorySearch' '备用'
 Check ($script:Controls.HistorySearch.Text -ceq '备用') 'Typing reaches the original history search control'
 Click '[data-control-name="ApplyHistoryFilters"]'
 WaitDom "document.querySelector('.workflow').textContent.includes('备用线路部署') && !document.querySelector('.workflow').textContent.includes('主线路部署')"
 Check (@($script:DeployUI.HistoryVisibleRecords).Count -eq 1) 'History filtering executes its production callback'
 Click '[data-control-name="SelectAllHistory"]'
 WaitDom "document.querySelector('[data-control-name=DeleteSelectedRecords]').textContent.includes('1')"
 Check ($script:DeployUI.HistorySelectedIds.Count -eq 1) 'History selection updates without a page fallback'

 MainPage 'settings';Click '[data-action="maintenance"]'
 WaitDom "document.querySelector('h1')?.textContent === '维护与恢复'"
 CheckWeb 'Maintenance';Shot '06-maintenance'
 $before=$script:Actions.Count
 Click '[data-control-name="WebRepairState"]'
 WaitDom "document.querySelector('[role=alertdialog]') !== null"
 Check ($script:Actions.Count -eq $before) 'Recovery still requires its existing deliberate confirmation'
 Check ($script:Window.FindName('Overlay').Opacity -eq 0) 'Native dialog chrome is hidden behind the web confirmation'
 Click '[data-action="cancelDialog"]'
 Check ($script:Actions.Count -eq $before -and $script:Overview.Running) 'Cancelling recovery preserves the connection'

 MainPage 'apps';Click '[data-action="domains"]'
 $tradeList=[pscustomobject]@{Revision=1;SnapshotToken=('a'*64);Programs=@([pscustomobject]@{Name='NinjaTrader.exe';Path='C:\fixture\NinjaTrader.exe';Missing=$false;Applied=$true});AppliedPrograms=@('C:\fixture\NinjaTrader.exe');Domains=@('tradingview.com','ninjatrader.com');AppliedDomains=@('tradingview.com','ninjatrader.com');NeedsPolicyUpdate=$false;HasLine=$true;HasUndo=$false;Message='名单已生效'}
 CompleteJob 'TradeApplications' $tradeList
 WaitDom "document.querySelector('h1')?.textContent === '交易软件名单'"
 CheckWeb 'Trading programs and websites';Shot '07-websites'
 Click '[data-control-name="AddTradeProgram"]'
 Check ($script:Actions[-1].Request.Action -ceq 'TradeApplicationEdit' -and $script:Actions[-1].Request.Kind -ceq 'Program' -and $script:Actions[-1].Request.Value -ceq (Join-Path $script:Root 'terminal64.exe')) 'Program picker sends an exact executable path through the list contract'
 $tradeList.Programs+=,[pscustomobject]@{Name='terminal64.exe';Path=(Join-Path $script:Root 'terminal64.exe');Missing=$false;Applied=$false};$tradeList.Revision=2;$tradeList.NeedsPolicyUpdate=$true;$tradeList.HasUndo=$true
 CompleteJob 'TradeApplicationEdit' $tradeList
 WaitDom "document.querySelector('[data-control-name=ApplyTradeApplications]') !== null && document.body.textContent.includes('未生效')"
 $before=$script:Actions.Count;Click '[data-control-name="ApplyTradeApplications"]'
 Check ($script:Actions.Count -eq $before -and $script:Window.FindName('Overlay').Visibility -eq 'Visible') 'Saved application edits do not restart the connection before the user applies them'
 Click '[data-action="cancelDialog"]';Shot '15-application-pending'
 FieldValue 'TradeDomainInput' 'example.com'
 Click '[data-control-name="AddTradeDomain"]'
 Check ($script:Actions[-1].Request.Action -eq 'TradeApplicationEdit' -and $script:Actions[-1].Request.Kind -eq 'Domain' -and $script:Actions[-1].Request.Value -eq 'example.com') 'Website edit sends the exact domain through the unified list worker'

 MainPage 'apps';Click '[data-action="agentsList"]'
 WaitDom "document.querySelector('h1')?.textContent === 'AI 工具名单'"
 CheckWeb 'AI tool list';Shot '08-ai-tools'
 Check ((Js "document.querySelectorAll('.workflow input[type=checkbox]').length > 5") -ceq 'true') 'AI tool list exposes selectable applications'
 $before=$script:Actions.Count;Click '.workflow label.wf-check'
 Check ($script:Actions.Count -gt $before) 'AI selection invokes the original routing update'
 $agentResult=$script:Overview.PSObject.Copy();$agentResult.AgentIds=@($script:Actions[-1].Request.AgentIds)
 CompleteJob 'Session' $agentResult

 MainPage 'lines';Click '[data-action="providers"]'
 WaitDom "document.querySelector('h1')?.textContent === '代理软件'"
 CheckWeb 'Proxy clients';Shot '09-providers'
 $null=Js "[...document.querySelectorAll('.workflow button')].find(b => b.textContent.includes('手动'))?.click()";Pump;SyncTCWebState -Force
 CheckWeb 'Proxy registration'

 MainPage 'lines'
 Check ((Js "document.querySelectorAll('.line-card [data-action=setHomeLine]').length") -ceq '0') 'Cards offer no set-home action (R5)'
 Check ((Js "document.querySelectorAll('[data-testid=line-card] [data-testid=protocol-pick]').length === document.querySelectorAll('[data-testid=line-card]').length") -ceq 'true') 'Every line card carries a protocol pick slot (R1/R2)'
 Check ((Js "document.querySelectorAll('[data-testid=line-card] [data-testid=protocol-pick] [role=radio]').length % 2") -ceq '0') 'Protocol picks render as two-segment radios or static text'
 Click '[data-detail]'
 # 0.21.2 reverses R9: server/devices and the network binding had no other web entry.
 Check ((Js "document.querySelectorAll('#drawer .action-group[data-group=maintain] [data-action=lineSettings]').length") -ceq '1') 'Drawer maintain group restores the connection-method page entry (0.21.2)'
 Check ((Js "document.querySelectorAll('#drawer .action-group[data-group=maintain] [data-action=lineServer]').length") -ceq '1') 'Drawer maintain group carries the server and devices entry (0.21.2)'
 Check ((Js "document.querySelectorAll('#drawer .action-group').length") -ceq '3') 'Drawer actions split into three groups (R12)'
 Check ((Js "document.querySelectorAll('#drawer .action-group[data-group=danger] .danger').length") -ceq '1') 'Danger group holds the delete action alone (R12)'
 # The real drawer button now reaches the connection-method page (it used to be a test-channel post).
 $readsBefore=@($script:Actions|Where-Object {$_.Request.Action -ceq 'LineProfiles'}).Count
 Click '#drawer [data-action="lineSettings"]'
 $deadline=[DateTime]::UtcNow.AddSeconds(5);while(@($script:Actions|Where-Object {$_.Request.Action -ceq 'LineProfiles'}).Count -le $readsBefore -and [DateTime]::UtcNow -lt $deadline){Pump}
 $read=@($script:Actions|Where-Object {$_.Request.Action -ceq 'LineProfiles'})|Select-Object -Last 1
 Check ($read -and $read.Request.Id -ceq $hk) 'Drawer connection-method entry reads the exact line'
 $profileLine=$script:Nodes[0].PSObject.Copy();$tcpProfile=$profileLine.Profiles[0].PSObject.Copy();$tcpProfile.Id='Tcp';$tcpProfile.Mode='Tcp';$tcpProfile.ManifestPath='fixture-tcp'
 $profileLine.Profiles=@($profileLine.Profiles[0],$tcpProfile)
 CompleteJob 'LineProfiles' $profileLine
 WaitDom "document.querySelector('h1')?.textContent === '连接方式' && document.querySelector('[data-control-name=PreferProfileTcp]') !== null"
 CheckWeb 'Connection methods';Shot '13-connection-methods'
 $profileLine|Add-Member NoteProperty SavedConnectionPreference @{ProfileId='Udp';Source='UserChoice';Digest=('C'*64)} -Force
 $script:Nodes[0]|Add-Member NoteProperty SavedConnectionPreference $profileLine.SavedConnectionPreference -Force
 $script:Nodes[0].name='主线路';$script:Overview.NodeName='主线路';$profileLine.name='主线路'

 Check ((Js "document.querySelector('.workflow').textContent.includes('兼容连接')") -ceq 'true') 'Connection methods use understandable names'
 Click '[data-control-name="PreferProfileTcp"]'
 Check ($script:Actions[-1].Request.Action -ceq 'LinePreference' -and $script:Actions[-1].Request.ProfileId -ceq 'Tcp' -and $script:Actions[-1].Request.Id -ceq $hk) 'Default-method edit retains exact line and profile binding'
 FailCapturedJob 'LinePreference' PreferenceRevisionChanged '[TC:PreferenceRevisionChanged] 线路资料刚更新。'
 WaitDom "document.querySelector('.workflow').textContent.includes('重试保存')"
 Check ($script:Window.FindName('Overlay').Visibility -ne 'Visible') 'Save refusal appears next to the method form without a modal'
 Check ((Js "document.querySelector('.workflow').textContent.includes('当前仍连接')") -ceq 'true') 'Method form separates the failed save from the current live connection'
 # A revision refusal refreshes the projected form using the normal read action.
 $profileLine.Revision=3;CompleteJob 'LineProfiles' $profileLine
 $retry=@($script:Controls.Keys|Where-Object {$_ -like 'RetryLineAction*'})[0]
 Click ('[data-control-name="'+$retry+'"]')
 Check ($script:Actions[-1].Request.Action -ceq 'LinePreference' -and $script:Actions[-1].Request.ExpectedRevision -eq 3 -and $script:Actions[-1].Request.ProfileId -ceq 'Tcp') 'Form retry uses current line data and the original attempted method'
 $savedLine=$profileLine.PSObject.Copy();$savedLine.Revision=4;$savedLine.SavedConnectionPreference=@{ProfileId='Tcp';Source='UserChoice';Digest=('D'*64)}
 CompleteJob 'LinePreference' $savedLine
 WaitDom "document.querySelector('.workflow').textContent.includes('已固定为兼容连接')"
 Shot '17-method-save-success'
 MainPage 'lines';Click ('[data-detail="'+$hk+'"]')
 Click '#drawer [data-action="setProfile"][data-value="Udp"]'
 FailCapturedJob 'LinePreference' PreferenceWriteFailed '[TC:PreferenceWriteFailed] 未能保存，请重试。'
 WaitDom "document.querySelector('#drawer .line-feedback')?.textContent.includes('重试保存') === true"
 Check ((Js "!document.querySelector('#drawer').hidden && document.querySelector('#drawer [data-value=Tcp]').getAttribute('aria-pressed') === 'true'") -ceq 'true') 'Drawer save failure preserves the previous selected method and stays open'
 Check ((Js "document.querySelector('#drawer .line-feedback').textContent.includes('当前仍连接')") -ceq 'true') 'Drawer feedback states the actual connection'
 Shot '18-method-save-failed'
 Click '#drawer [data-action="retryLineAction"]'
 $savedLine.Revision=5;$savedLine.SavedConnectionPreference=@{ProfileId='Udp';Source='UserChoice';Digest=('E'*64)}
 CompleteJob 'LinePreference' $savedLine
 WaitDom "document.querySelector('#drawer [data-value=Udp]').getAttribute('aria-pressed') === 'true'"
 Check ((Js "!document.querySelector('#drawer').hidden && !document.querySelector('#drawer [data-action=retryLineAction]')") -ceq 'true') 'Successful drawer retry updates the method and removes the obsolete retry'
 Click '#drawer [data-action="testLine"]'
 $testProfile=$script:Actions[-1].Request.ProfileId
 CompleteJob 'LineProfileCheck' ([pscustomobject]@{LineId=$hk;ProfileId=$testProfile;Status='Failed';Code='ProbeTimeout';Check=@{Status='Failed';Code='ProbeTimeout';ForwardingPassed=$false}})
 WaitDom "document.querySelector('#drawer [data-action=retryLineAction]')?.textContent === '重新测试'"
 Check ($script:Window.FindName('Overlay').Visibility -ne 'Visible') 'Worker success with a timed-out network test stays inline and offers a real retry'
 Shot '19-line-test-failed'
 $before=$script:Actions.Count;Click '#drawer [data-action="retryLineAction"]'
 Check ($script:Actions[-1].Request.Action -ceq 'LineProfileCheck' -and $script:Actions[-1].Request.Id -ceq $hk -and $script:Actions[-1].Request.ProfileId -ceq $testProfile) 'Inline test retry reaches the exact original line and method'
 CompleteJob 'LineProfileCheck' ([pscustomobject]@{LineId=$hk;ProfileId=$testProfile;Status='Passed';Code='ForwardingPassed';Check=@{Status='Passed';ForwardingPassed=$true}})
 WaitDom "document.querySelector('#drawer').textContent.includes('线路测试通过') && !document.querySelector('#drawer [data-action=retryLineAction]')"
 Click '#drawer [data-close="drawer"]'


 MainPage 'lines';Click '[data-detail]';Click '[data-action="rename"]'
 WaitDom "document.querySelector('h1')?.textContent === '重命名线路'"
 FieldValue 'RenameLineName' '新的线路名称'
 Click '[data-control-name="RenameLineSave"]'
 Check ($script:Actions[-1].Request.Action -eq 'RenameNode' -and $script:Actions[-1].Request.Id -eq $hk -and $script:Actions[-1].Request.Name -ceq '新的线路名称') 'Rename is an in-app form bound to the original line'
 CheckWeb 'Rename'

 MainPage 'lines';Click '[data-action="add"]'
 WaitDom "document.querySelector('h1')?.textContent === '添加线路' && document.querySelector('[data-control-name=ProductDeployInspect]') !== null"
 CheckWeb 'Deployment';Shot '10-add-line'
 FieldValue 'DeployConnectionText' '203.0.113.50'
 FieldValue 'DeployPassword' 'fixture-only-not-a-real-password'
 Check ($script:Controls.DeployConnectionText.Text -ceq '203.0.113.50' -and $script:Controls.DeployPassword.SecurePassword.Length -gt 0) 'Server and password inputs reach the existing secure credential draft'
 $publicJson=GetTCWebSnapshot|ConvertTo-Json -Depth 48 -Compress
 Check (-not $publicJson.Contains('fixture-only-not-a-real-password')) 'Password is absent from outbound view snapshots'
 $focusBefore=Js 'document.activeElement.dataset.controlName';SyncTCWebState -Force;Pump
 Check ((Js 'document.activeElement.dataset.controlName') -ceq $focusBefore) 'Status refresh preserves the active input'
 Check ((Js "document.querySelector('[data-control-name=DeployPassword]').value.length > 0") -ceq 'true') 'Status refresh preserves the browser password field'
 Click '[data-password-toggle]'
 Check ((Js "document.querySelector('[data-control-name=DeployPassword]').type") -ceq '"text"') 'Password visibility is local to the new input'
 $null=Js "window.dispatchEvent(new Event('blur'))"
 Check ((Js "document.querySelector('[data-control-name=DeployPassword]').type") -ceq '"password"') 'Leaving the window hides the password'
 Click 'details[data-control-name="DeployAccessAdvanced"] > summary'
 WaitDom "document.querySelector('details[data-control-name=DeployAccessAdvanced]').open"
 FieldValue 'DeployName' '测试部署'
 $before=$script:Actions.Count
 Click '[data-control-name="ProductServers"]'
 WaitDom "!document.querySelector('.workflow') && document.querySelector('h1')?.textContent === '线路'"
 Check (@($script:Actions|Select-Object -Skip $before|Where-Object {$_.Request.Action -like 'Deployment*' -and $_.Request.Action -ne 'DeploymentDiscover'}).Count -eq 0) 'Leaving an unsubmitted form starts no deployment'

 Click '[data-action="add"]'
 WaitDom "document.querySelector('[data-control-name=ProductDeployInspect]') !== null"
 FieldValue 'DeployConnectionText' '203.0.113.60'
 FieldValue 'DeployPassword' 'fixture-submit-password'
 $before=$script:Actions.Count;Click '[data-control-name="ProductDeployInspect"]'
 Check ($script:Actions.Count -eq ($before+1) -and $script:Actions[-1].Request.Action -ceq 'DeploymentCreate' -and $script:Actions[-1].Request.Connection.Host -ceq '203.0.113.60') 'New form submit invokes real deployment creation with the entered server'
 Check ($script:DeployUI.Credential.Password -is [Security.SecureString]) 'Submitted credentials retain the secure in-memory handoff'
 Check (-not (($script:Actions[-1].Request|ConvertTo-Json -Depth 12).Contains('fixture-submit-password'))) 'Deployment job envelope excludes the password'

 MainPage 'settings'
 $null=Js "const theme=document.querySelector('#theme');theme.value='dark';theme.dispatchEvent(new Event('change',{bubbles:true}))"
 Click '[data-action="maintenance"]';WaitDom "document.documentElement.dataset.theme === 'dark' && document.querySelector('.workflow') !== null"
 CheckWeb 'Dark maintenance';Shot '11-maintenance-dark'
 $script:Window.Width=960;Pump;Shot '12-compact-maintenance'
 Check ((Js 'document.documentElement.scrollWidth <= document.documentElement.clientWidth') -ceq 'true') 'Compact workflow has no document-wide horizontal overflow'
 PageHead '长文本夹具' '' 'form-contract'
 $longInput=ControlName (New-Object Windows.Controls.TextBox) 'LongPublicMaterial';$longInput.MaxLength=131072;AddC $script:HostPanel $longInput;SyncTCWebState -Force
 WaitDom "document.querySelector('[data-control-name=LongPublicMaterial]') !== null"
 $null=Js "const input=document.querySelector('[data-control-name=LongPublicMaterial]');input.value='A'.repeat(65536);input.dispatchEvent(new Event('input',{bubbles:true}))"
 for($i=0;$i -lt 4;$i++){Pump}
 Check ($longInput.Text.Length -eq 65536) 'The outer web bridge preserves supported large connection material'
 MainPage 'home';$script:Pending=$null
 CommitLineConnectionPreview @{Action='ConnectionSwitchCommit';LineId=$hk;ProfileId='Udp';PreviewToken='fixture-only-approved-token'}
 CompleteJob 'ConnectionSwitchCommit' ([pscustomobject]@{Activated=$true;Status='Completed';DailyApply=[pscustomobject]@{Applied=$false;Effective='direct';ReasonText='日常代理正在检查，日常上网暂时直连。'}})
 WaitDom "document.body.textContent.includes('交易线路已连接；日常代理正在检查，日常上网暂时直连。')"
 Check ($script:Window.FindName('Overlay').Visibility -ne 'Visible') 'A verified connection with daily fallback displays its actual state without a failure dialog'
 CheckWeb 'Connected daily fallback';Shot '16-connected-daily-fallback'
 # 0.21.2: the drawer reaches the line's server and devices page, where the
 # invitation codes, devices and identity check live.
 MainPage 'lines';Click ('[data-detail="'+$hk+'"]')
 $readsBefore=@($script:Actions|Where-Object {$_.Request.Action -ceq 'LineProfiles'}).Count
 Click '#drawer [data-action="lineServer"]'
 $deadline=[DateTime]::UtcNow.AddSeconds(5);while(@($script:Actions|Where-Object {$_.Request.Action -ceq 'LineProfiles'}).Count -le $readsBefore -and [DateTime]::UtcNow -lt $deadline){Pump}
 $read=@($script:Actions|Where-Object {$_.Request.Action -ceq 'LineProfiles'})|Select-Object -Last 1
 Check ($read -and $read.Request.Id -ceq $hk) 'Drawer server entry reads the exact line binding'
 WaitDom "document.querySelector('h1')?.textContent === '线路的服务器与设备'"
 Check ($script:ServerNavigationUI.LineId -ceq $hk -and $script:ServerNavigationUI.ReturnKind -ceq 'Nodes') 'Server page is bound to the line and returns to the line list'
 CheckWeb 'Line server and devices';Shot '21-line-server'
 # Leave the smoke dispatcher for the actual launch-failure path. The fixture's
 # Start-Process still refuses every launch, so no process or network is started.
 $script:Smoke=$false;$script:UiJobRecoveryLoaded=$true;$script:UiReadWorkerEnabled=$false
 $script:Job=$null;$script:JobQueue.Clear();$script:QueuedJob=$null
 $null=[IO.Directory]::CreateDirectory($script:JobRoot)
 $before=$script:UiDispatchFailures.Count
 StartJob @{Action='Nodes'} {} -Silent
 SyncTCWebState -Force;Pump
 Check ($script:UiDispatchFailures.Count -eq ($before+1) -and $script:Window.FindName('Overlay').Visibility -ne 'Visible') 'Actual automatic-read launch refusal remains nonmodal in the real WebView2 UI'
 StartJob @{Action='Nodes'} {}
 SyncTCWebState -Force
 WaitDom "document.querySelector('#dialog-title')?.textContent === '读取线路列表未完成' && document.querySelector('[data-action=confirmDialog]')?.textContent === '重新读取'"
 Check ((Js "document.querySelector('[role=alertdialog]').textContent.includes('错误编号')") -ceq 'true') 'Actual dispatch failure renders its operation, diagnostic ID and retry button in WebView2'
 Shot '20-read-dispatch-failure'
 $before=$script:UiDispatchFailures.Count;$originalRequest=$script:LastUiDispatchFailure.RequestId
 Click '[data-action="confirmDialog"]'
 WaitDom "document.querySelector('#dialog-title')?.textContent === '读取线路列表未完成'"
 Check ($script:UiDispatchFailures.Count -eq ($before+1) -and $script:LastUiDispatchFailure.RequestId -cne $originalRequest) 'Clicking the real browser retry button reaches a fresh actual dispatcher request'
 CloseDialog;$script:Smoke=$true
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
