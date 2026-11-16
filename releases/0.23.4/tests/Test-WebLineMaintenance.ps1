#requires -Version 5.1
[CmdletBinding()]param([string]$PackageRoot='',[Parameter(Mandatory=$true)][string]$ReportDirectory)
$ErrorActionPreference='Stop'
if([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw 'Use Windows PowerShell -Sta.'}
if(-not $PackageRoot){$PackageRoot=Split-Path $PSScriptRoot -Parent}
$script:FixturePackageRoot=[IO.Path]::GetFullPath($PackageRoot)
$script:ReportRoot=[IO.Path]::GetFullPath($ReportDirectory)
if($script:ReportRoot.StartsWith('C:\ProgramData\',[StringComparison]::OrdinalIgnoreCase) -or $script:ReportRoot.StartsWith('C:\tradechannel',[StringComparison]::OrdinalIgnoreCase)){throw 'Use a workspace report directory.'}
$null=[IO.Directory]::CreateDirectory($script:ReportRoot)
function Start-Process {throw 'Line maintenance tests forbid external process launches.'}
function Stop-Process {throw 'Line maintenance tests forbid stopping real processes.'}
function Invoke-WebRequest {throw 'Line maintenance tests forbid network access.'}
function Invoke-RestMethod {throw 'Line maintenance tests forbid network access.'}

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
function ActionCount {param([string]$Action)@($script:Actions|Where-Object {$_.Request.Action -ceq $Action}).Count}
function NextAction {param([string]$Action,[int]$Before)
 $deadline=[DateTime]::UtcNow.AddSeconds(5);while((ActionCount $Action) -le $Before -and [DateTime]::UtcNow -lt $deadline){Pump}
 if((ActionCount $Action) -le $Before){return $null}
 @($script:Actions|Where-Object {$_.Request.Action -ceq $Action})|Select-Object -Last 1
}
function LineNode {param([string]$Id)@($script:Nodes|Where-Object {(UILineId $_) -ceq $Id})[0]}
function BackToLines {param([string]$Name)
 Check ((Js "document.querySelector('[data-control-name=MaintenanceBack]')?.textContent.includes('返回线路列表') === true") -ceq 'true') ($Name+' offers the line-list return')
 $before=ActionCount 'Nodes'
 Click '[data-control-name="MaintenanceBack"]'
 WaitDom "!document.querySelector('.workflow') && document.querySelector('nav .active')?.dataset.page === 'lines'"
 Check ((ActionCount 'Nodes') -gt $before) ($Name+' returns to the line list and refreshes it')
 CompleteJob 'Nodes' @($script:Nodes)
}
$passed=$false;$failure=''
try{
 $script:Window.Show();[Threading.SynchronizationContext]::SetSynchronizationContext((New-Object Windows.Threading.DispatcherSynchronizationContext($script:Window.Dispatcher)))
 InitializeTCWebShell -DataFolder (Join-Path $script:Root 'browser') -Fixture
 $deadline=[DateTime]::UtcNow.AddSeconds(25)
 while(-not $script:WebReady -and -not $script:WebFailed -and [DateTime]::UtcNow -lt $deadline){Pump}
 Check ($script:WebReady -and -not $script:WebFailed) ('WebView2 initialized: '+$script:WebFailureMessage)
 WaitDom "document.querySelector('.signal-title')?.textContent.includes('已连接') === true"
 # 0.21.2: the line drawer reaches the line's server and devices page, where the
 # invitation codes, devices and identity check live.
 MainPage 'lines'
 Click ('[data-detail="'+$hk+'"]')
 Check ((Js "document.querySelectorAll('#drawer .action-group[data-group=maintain] [data-action=lineServer]').length") -ceq '1') 'Drawer maintain group carries the server and devices entry'
 Check ((Js "document.querySelectorAll('#drawer .action-group[data-group=maintain] [data-action=lineSettings]').length") -ceq '1') 'Drawer maintain group carries the connection-method entry'
 $before=ActionCount 'LineProfiles'
 Click '#drawer [data-action="lineServer"]'
 $read=NextAction 'LineProfiles' $before
 Check ($read -and $read.Request.Id -ceq $hk) 'Drawer server entry reads the exact line binding'
 WaitDom "document.querySelector('h1')?.textContent === '线路的服务器与设备'"
 Check ($script:ServerNavigationUI.LineId -ceq $hk -and $script:ServerNavigationUI.ReturnKind -ceq 'Nodes') 'Drawer server page is bound to the line and returns to the line list'
 CompleteJob 'LineProfiles' (LineNode $hk)
 WaitDom "document.querySelector('.workflow')?.textContent.includes('这条线路没有关联的管理记录') === true"
 CheckWeb 'Line server and devices';Shot '01-line-server'
 BackToLines 'Drawer server page'

 # The connection-method page is reachable again and links to the same server page.
 Click ('[data-detail="'+$hk+'"]')
 $before=ActionCount 'LineProfiles'
 Click '#drawer [data-action="lineSettings"]'
 $read=NextAction 'LineProfiles' $before
 Check ($read -and $read.Request.Id -ceq $hk) 'Drawer connection-method entry reads the exact line'
 CompleteJob 'LineProfiles' (LineNode $hk)
 WaitDom "document.querySelector('h1')?.textContent === '连接方式' && !!document.querySelector('[data-control-name=LineMaintenance]') && !!document.querySelector('[data-control-name=LineNetworkPolicy]')"
 CheckWeb 'Connection methods';Shot '02-connection-methods'
 $before=ActionCount 'LineProfiles'
 Click '[data-control-name="LineMaintenance"]'
 $read=NextAction 'LineProfiles' $before
 WaitDom "document.querySelector('h1')?.textContent === '线路的服务器与设备'"
 Check ($read -and $read.Request.Id -ceq $hk -and $script:ServerNavigationUI.LineId -ceq $hk -and $script:ServerNavigationUI.ReturnKind -ceq 'LineProfiles') 'Connection-method page reaches the same server page and returns to the line'
 CompleteJob 'LineProfiles' (LineNode $hk)
 WaitDom "document.querySelector('[data-control-name=MaintenanceBack]')?.textContent.includes('返回原线路') === true"
 MainPage 'lines'

 # Invitation joins start on the native add-line page; the legacy form stays reachable.
 Click '[data-action="pairStart"]'
 WaitDom "document.querySelector('h1')?.textContent === '添加线路' && !!document.querySelector('[data-testid=pair-code]')"
 Check ($script:WebPage -ceq 'add-line') 'Header invitation entry opens the add-line page in the host'
 Check ((Js ("document.querySelector('[data-testid=pair-device]')?.value === "+([Environment]::MachineName|ConvertTo-Json -Compress))) -ceq 'true') 'The device name defaults to this computer, as the legacy form did'
 CheckWeb 'Invitation join';Shot '03-pair-start'
 Click '[data-testid="pair-legacy"]'
 WaitDom "document.querySelector('h1')?.textContent === '加入已有线路'"
 CheckWeb 'Legacy invitation form';Shot '04-pair-legacy'
 MainPage 'lines'

 # A line whose server identity changed shows why and leads to the identity check.
 $blockMessage='关联服务器公钥与此线路不一致，请先核对服务器身份。'
 $usNode=LineNode $us
 $usNode|Add-Member NoteProperty ServerConnectionBlock 'ServerBindingChanged' -Force
 $usNode|Add-Member NoteProperty ServerConnectionMessage $blockMessage -Force
 SyncTCWebState -Force
 $card='.line-card:has([data-detail="'+$us+'"])'
 WaitDom ("!!document.querySelector('"+$card+" [data-action=lineServer]')")
 Check ((Js ("document.querySelectorAll('"+$card+" [data-action=connect]').length")) -ceq '0') 'A blocked card offers no connect button'
 Check ((Js ("document.querySelector('"+$card+"').textContent.includes('"+$blockMessage+"')")) -ceq 'true') 'A blocked card shows the stored reason'
 $projected=@((GetTCWebSnapshot).Lines|Where-Object {$_.Id -ceq $us})[0]
 Check ($projected.Blocked -eq $true -and $projected.BlockedReason -ceq $blockMessage) 'The web projection carries the block and its reason'
 Click ('[data-detail="'+$us+'"]')
 Check ((Js "document.querySelectorAll('#drawer .action-group[data-group=primary] [data-action=lineServer]').length === 1 && document.querySelectorAll('#drawer [data-action=connect]').length === 0") -ceq 'true') 'A blocked line drawer leads with the identity check'
 Click '#drawer [data-close="drawer"]'
 Shot '05-blocked-card'
 $before=ActionCount 'LineProfiles'
 Click ($card+' [data-action="lineServer"]')
 $read=NextAction 'LineProfiles' $before
 Check ($read -and $read.Request.Id -ceq $us) 'Blocked card entry reads the blocked line binding'
 WaitDom "document.querySelector('h1')?.textContent === '线路的服务器与设备'"
 CompleteJob 'LineProfiles' $usNode
 WaitDom ("document.querySelector('.workflow')?.textContent.includes('"+$blockMessage+"') === true")
 CheckWeb 'Blocked line server page';Shot '06-blocked-line-server'
 BackToLines 'Blocked line server page'

 # Last step: a direct host message moves the acknowledged sequence past the page's
 # own counter, so no browser click may follow it. Older pages, guard repair and
 # recommendations may still post connect for a blocked line.
 $before=$script:Actions.Count;$script:LastToast=''
 InvokeTCWebMessage ([ordered]@{Type='connect';Id=$us;Sequence=[int]($script:WebAck+1)}|ConvertTo-Json -Compress) 'https://tradechannel.local/index.html'
 for($i=0;$i -lt 3;$i++){Pump}
 $new=@($script:Actions|Select-Object -Skip $before)
 Check ($new.Count -eq 1 -and $new[0].Request.Action -ceq 'LineProfiles' -and $new[0].Request.Id -ceq $us) 'A connect request for a blocked line opens its server check and starts nothing else'
 Check ($script:LastToast -ceq '这条线路的服务器身份需要先核对') 'The redirect says why the line did not connect'
 WaitDom "document.querySelector('h1')?.textContent === '线路的服务器与设备'"
 Check ($script:ServerNavigationUI.LineId -ceq $us -and $script:ServerNavigationUI.ReturnKind -ceq 'Nodes') 'The redirected server page is bound to the blocked line'
 Check (@($script:AllSelfTestRequests|Where-Object {$_.Request.ContainsKey('SessionAction') -or $_.Request.Action -like 'Connection*'}).Count -eq 0) 'No connection, switch or disconnect request was issued'
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
