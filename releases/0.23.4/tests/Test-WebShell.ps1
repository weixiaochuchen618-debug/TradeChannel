#requires -Version 5.1
[CmdletBinding()]param([string]$PackageRoot='',[Parameter(Mandatory=$true)][string]$ReportDirectory)
$ErrorActionPreference='Stop';$env:PSModulePath=Join-Path $PSHOME 'Modules'
if(-not $PackageRoot){$PackageRoot=Split-Path $PSScriptRoot -Parent}
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Windows.Forms
$script:PackageRoot=[IO.Path]::GetFullPath($PackageRoot);$out=[IO.Path]::GetFullPath($ReportDirectory)
$null=[IO.Directory]::CreateDirectory($out)
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('TC-WebShell-'+[guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($fixture)
$script:Root=$fixture;$script:Smoke=$false;$script:ReadOnly=$false;$script:Page='home';$script:Version='0.18.0'
$script:Requests=New-Object 'Collections.Generic.List[object]';$script:Checks=New-Object 'Collections.Generic.List[string]'
$script:Prefs=@{NodeId='11111111-1111-1111-1111-111111111111';Daily='Direct';Agents='Daily'};$script:UserSettings=@{AutoTrustFirstConnection=$true;AutoConnectOnLogin=$false}
$script:Nodes=@([pscustomobject]@{LineId='11111111-1111-1111-1111-111111111111';Name='我的主线路';Profiles=@(@{Id='Udp';PreparationState='SyntaxValidated'});SavedConnectionPreference=@{ProfileId='Udp'}},[pscustomobject]@{LineId='22222222-2222-2222-2222-222222222222';Name='备用线路';Profiles=@(@{Id='Tcp';PreparationState='SyntaxValidated'});SavedConnectionPreference=@{ProfileId='Tcp'}})
$script:Overview=[pscustomobject]@{StateKey='Connected';Running=$true;ActiveLineId='11111111-1111-1111-1111-111111111111';ActiveProfileId='Udp';NodeName='我的主线路';GuardState='Protected';NinjaRunning=$false}
$script:Providers=@{Items=@()};$script:Job=$null;$script:LastToast=''
function StateKey {$script:Overview.StateKey}
function IsBusy {$false}
function DailyLaneValue {$script:Prefs.Daily}
function UILineId($n){$n.LineId}
function SetNavigationContext {param($Section,$View) $script:Navigation=@{Section=$Section;View=$View}}
function StartJob {param($Request,$Callback,$Message) $script:Requests.Add($Request)}
function StartLineConnectionPreview {param($Id,$Profile) $script:Requests.Add(@{Action='ConnectionDefaultPreview';LineId=$Id})}
function OpenDisconnect {$script:Requests.Add(@{Action='DisconnectPreview'})}
function OnDaily($Value){$script:Requests.Add(@{Action='Daily';Value=$Value})}
function OnAgents($Value){$script:Requests.Add(@{Action='Agents';Value=$Value})}
function Toast($Value){$script:LastToast=[string]$Value}
function ErrorDialog($Message){throw $Message}
function CloseDialog {$script:Window.FindName('Overlay').Visibility='Collapsed';$script:DialogCallback=$null;$script:DialogContext=$null}
function Check($Condition,$Message){if(-not $Condition){throw $Message};$script:Checks.Add($Message)}
function Pump { [Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 20 }
function Await($Task){$deadline=[DateTime]::UtcNow.AddSeconds(25);while(-not $Task.IsCompleted){Pump;if([DateTime]::UtcNow -gt $deadline){throw 'WebView operation exceeded deadline'}};$Task.GetAwaiter().GetResult()}
function Js([string]$Code){Await ($script:WebShell.CoreWebView2.ExecuteScriptAsync($Code))}
function WaitDom([string]$Expression){$deadline=[DateTime]::UtcNow.AddSeconds(10);do{Pump;if((Js $Expression) -ceq 'true'){return}}while([DateTime]::UtcNow -lt $deadline);throw ('DOM condition failed: '+$Expression)}
function Shot([string]$Name){$s=[IO.File]::Open((Join-Path $out ($Name+'.png')),[IO.FileMode]::Create);try{$null=Await ($script:WebShell.CoreWebView2.CapturePreviewAsync([Microsoft.Web.WebView2.Core.CoreWebView2CapturePreviewImageFormat]::Png,$s))}finally{$s.Dispose()}}
[xml]$xaml=[IO.File]::ReadAllText((Join-Path $script:PackageRoot 'ui\Shell.xaml'));$script:Window=[Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader($xaml)))
$script:Window.Left=-15000;$script:Window.Top=-15000;$script:Window.Width=1280;$script:Window.Height=850
$script:HostPanel=$script:Window.FindName('ContentHost');$script:Footer=$script:Window.FindName('FooterStatus')
$tcTokens=$null;$tcErrors=$null
$tcAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $script:PackageRoot 'TradeChannel.ps1'),[ref]$tcTokens,[ref]$tcErrors)
$tcFn=@($tcAst.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)|Where-Object Name -ceq 'SetTCChromeDensity')[0]
Set-Item Function:script:SetTCChromeDensity ([scriptblock]::Create($tcFn.Body.Extent.Text.Substring(1,$tcFn.Body.Extent.Text.Length-2)))
$themeFn=@($tcAst.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)|Where-Object Name -ceq 'SetTCChromeTheme')[0]
Set-Item Function:script:SetTCChromeTheme ([scriptblock]::Create($themeFn.Body.Extent.Text.Substring(1,$themeFn.Body.Extent.Text.Length-2)))
function WaitChromeTheme([string]$Color){$deadline=[DateTime]::UtcNow.AddSeconds(5);do{Pump;if($script:Window.FindName('ShellHeader').Background.Color.ToString() -ceq $Color){return}}while([DateTime]::UtcNow -lt $deadline);throw ('Title-bar theme did not reach '+$Color)}
. (Join-Path $script:PackageRoot 'ui\WebShell.ps1')
$null=SetTCChromeTheme -Theme 'light'
$passed=$false;$failure=''
try{
 $script:Window.Show();[Threading.SynchronizationContext]::SetSynchronizationContext((New-Object Windows.Threading.DispatcherSynchronizationContext($script:Window.Dispatcher)));InitializeTCWebShell -DataFolder (Join-Path $fixture 'browser') -Fixture
 $deadline=[DateTime]::UtcNow.AddSeconds(25)
 while(-not $script:WebReady -and -not $script:WebFailed -and [DateTime]::UtcNow -lt $deadline){Pump}
 Check ($script:WebReady -and -not $script:WebFailed) ('WebView2 initialized: '+$script:WebFailureMessage)
 WaitDom "document.querySelector('.signal-title')?.textContent.includes('已连接') === true"
 $startupTheme=([string](Js 'document.documentElement.dataset.theme')).Trim('"')
 if($startupTheme -eq 'dark'){WaitChromeTheme '#FF141E30'}else{WaitChromeTheme '#FFFFFFFF'}
 Check ($startupTheme -cin @('light','dark')) 'Saved or system theme initializes the native title bar on first load'
 Check (@($script:Requests|Where-Object {$_.Action -cne 'DeploymentDiscover'}).Count -eq 0) 'Opening the WebView creates no connection or configuration request (the read-only progress discovery is allowed)'
 Shot '01-home-light'
 $null=Js "document.querySelector('[data-page=lines]').click()";WaitDom "document.querySelector('h1')?.textContent === '线路'"
 Shot '02-lines'
 $null=Js "document.querySelector('[data-detail]').click()";WaitDom "!document.getElementById('drawer').hidden"
 Shot '03-line-details'
 $null=Js "document.querySelector('[data-close=drawer]').click();document.querySelector('[data-page=apps]').click()";WaitDom "document.querySelector('h1')?.textContent === '应用'"
 $null=Js "const d=document.getElementById('daily');d.value='Trade';d.dispatchEvent(new Event('change',{bubbles:true}));"
 Pump;Check (@($script:Requests|Where-Object Action -eq 'Daily').Count -eq 1) 'Application selection reaches only its explicit UI intent'
 Shot '04-apps'
 $null=Js "document.querySelector('[data-page=settings]').click()";WaitDom "document.querySelector('h1')?.textContent === '设置'"
 Check ((Js "document.querySelector('[data-setting=AutoConnectOnLogin]').getAttribute('aria-checked')") -eq '"false"') 'Auto-connect switch defaults off'
 Shot '05-settings'
 $null=Js "const t=document.getElementById('theme');t.value='dark';t.dispatchEvent(new Event('change',{bubbles:true}));document.querySelector('[data-page=home]').click();"
 WaitDom "document.documentElement.dataset.theme === 'dark' && document.querySelector('h1')?.textContent === '首页'"
 WaitChromeTheme '#FF141E30'
 Check ($script:Window.FindName('BrandMark').Parent.Children[1].Foreground.Color.ToString() -ceq '#FFE5EBF7' -and $script:Window.FindName('WindowMinimize').Content.Stroke.Color.ToString() -ceq '#FF9BAAC2') 'Dark selection updates title, controls and surface together'
 Shot '06-home-dark'
 $null=Js "document.querySelector('[data-page=settings]').click()"
 WaitDom "document.querySelector('h1')?.textContent === '设置'"
 $null=Js "(()=>{const t=document.getElementById('theme');t.value='light';t.dispatchEvent(new Event('change',{bubbles:true}));})()"
 WaitDom "document.documentElement.dataset.theme === 'light'"
 WaitChromeTheme '#FFFFFFFF'
 Check ($script:Window.FindName('WindowMinimize').Content.Stroke.Color.ToString() -ceq '#FF4B5360') 'Light selection restores title-bar control contrast'
 $null=Js "document.querySelector('[data-page=home]').click()"
 WaitDom "document.querySelector('h1')?.textContent === '首页'"
 $null=Js "document.querySelector('[data-page=settings]').click()"
 WaitDom "document.querySelector('h1')?.textContent === '设置'"
 $null=Js "(()=>{const t=document.getElementById('theme');t.value='system';t.dispatchEvent(new Event('change',{bubbles:true}));})()"
 $darkMedia='{"features":[{"name":"prefers-color-scheme","value":"dark"}]}'
 $null=Await ($script:WebShell.CoreWebView2.CallDevToolsProtocolMethodAsync('Emulation.setEmulatedMedia',$darkMedia))
 WaitDom "document.documentElement.dataset.theme === 'dark'"
 WaitChromeTheme '#FF141E30'
 Check ($script:Window.FindName('ShellHeader').Background.Color.ToString() -ceq '#FF141E30') 'System dark-mode changes propagate through the WebView media-query listener'
 $lightMedia='{"features":[{"name":"prefers-color-scheme","value":"light"}]}'
 $null=Await ($script:WebShell.CoreWebView2.CallDevToolsProtocolMethodAsync('Emulation.setEmulatedMedia',$lightMedia))
 WaitDom "document.documentElement.dataset.theme === 'light'"
 WaitChromeTheme '#FFFFFFFF'
 $null=Js "document.querySelector('[data-page=home]').click()"
 WaitDom "document.querySelector('h1')?.textContent === '首页'"
 $before=$script:Requests.Count
 InvokeTCWebMessage '{"Type":"connect","Id":"22222222-2222-2222-2222-222222222222"}' 'https://other.invalid/index.html'
 InvokeTCWebMessage '{"Type":"connect","Id":"unknown-line"}' 'https://tradechannel.local/index.html'
 InvokeTCWebMessage '{"Type":"connect","Id":"22222222-2222-2222-2222-222222222222","Command":"anything"}' 'https://tradechannel.local/index.html'
 Check ($script:Requests.Count -eq $before) 'Foreign origins, unknown lines and extra fields cannot invoke a connection'
 $script:ReadOnly=$true;InvokeTCWebMessage '{"Type":"connect","Id":"22222222-2222-2222-2222-222222222222"}' 'https://tradechannel.local/index.html'
 Check ($script:Requests.Count -eq $before) 'Read-only launch refuses web mutations'
 $script:ReadOnly=$false;InvokeTCWebMessage '{"Type":"connect","Id":"22222222-2222-2222-2222-222222222222"}' 'https://tradechannel.local/index.html'
 Check ($script:Requests[$script:Requests.Count-1].Action -eq 'ConnectionDefaultPreview') 'Connection click uses the existing preview flow'
  $before=$script:Requests.Count;$script:Overview.NinjaRunning=$true
  InvokeTCWebMessage '{"Type":"connect","Id":"22222222-2222-2222-2222-222222222222"}' 'https://tradechannel.local/index.html'
  Check ($script:Requests.Count -eq $before -and $script:WebPendingConnection.Id -eq '22222222-2222-2222-2222-222222222222') 'Running trading software defers the explicitly requested connection'
  ContinueTCWebConnection;Check ($script:Requests.Count -eq $before) 'Waiting cannot connect while trading software runs'
  $script:Overview.NinjaRunning=$false;ContinueTCWebConnection
  Check ($script:Requests.Count -eq ($before+1) -and -not $script:WebPendingConnection) 'Closing trading software continues the requested connection once'
  ContinueTCWebConnection;Check ($script:Requests.Count -eq ($before+1)) 'Pending connection is consumed exactly once'
  $script:Overview.NinjaRunning=$true;InvokeTCWebMessage '{"Type":"connect","Id":"22222222-2222-2222-2222-222222222222"}' 'https://tradechannel.local/index.html'
  InvokeTCWebMessage '{"Type":"cancelWaiting"}' 'https://tradechannel.local/index.html';$script:Overview.NinjaRunning=$false;ContinueTCWebConnection
  Check ($script:Requests.Count -eq ($before+1) -and -not $script:WebPendingConnection) 'Cancel prevents a delayed connection'
  $script:DialogCallback={$script:Requests.Add(@{Action='ApprovedFixture'})};$script:DialogContext=@{LineId='22222222-2222-2222-2222-222222222222'}
  $script:Window.FindName('DialogTitle').Text='切换到备用线路？';$script:Window.FindName('DialogBody').Text='当前连接会短暂中断。';$script:Window.FindName('DialogNote').Text='失败时会核对原连接的恢复结果。';$script:Window.FindName('DialogConfirm').Content='切换线路';$script:Window.FindName('DialogCancel').Content='取消';$script:Window.FindName('DialogCancel').Visibility='Visible';$script:Window.FindName('Overlay').Visibility='Visible'
  SyncTCWebState -Force;WaitDom "document.querySelector('[role=alertdialog]')!==null"
  Check ((Js "document.activeElement.dataset.action") -ceq '"cancelDialog"') 'Connection confirmation starts with cancel focused'
  $before=$script:Requests.Count;InvokeTCWebMessage '{"Type":"confirmDialog","Id":"stale"}' 'https://tradechannel.local/index.html'
  Check ($script:Requests.Count -eq $before) 'A stale web confirmation cannot approve a new request'
  Shot '07-switch-confirmation'
  $null=Js "document.querySelector('[data-action=confirmDialog]').click()";Pump
  Check ($script:Requests.Count -eq ($before+1) -and $script:Requests[$before].Action -eq 'ApprovedFixture') 'Web confirmation delivers the existing immutable callback once'
 foreach($entry in @(@('ProfileBindingVerified',$true),@('SessionId','fixture-web-session'),@('ConfigHash',('A'*64)),@('EnginePid',123),@('ConnectedSince',[DateTimeOffset]::UtcNow.AddHours(-1).ToString('o')),@('ObservedAt',[DateTimeOffset]::UtcNow.ToString('o')),@('ManifestPath',(Join-Path $fixture 'fixture.manifest')),@('Mode','rule'),@('Exit','hk'))){$script:Overview|Add-Member NoteProperty $entry[0] $entry[1] -Force}
 $script:WebQuality=[pscustomobject]@{BindingKey=(Get-TCLineQualityContext $script:Overview).Key;SampleAtUtc=[DateTimeOffset]::UtcNow.ToString('o');LatencyMs=72;Quality='Good';Degraded=$false;NotificationMessage='';History=@(0..29|ForEach-Object {[pscustomobject]@{AtUtc=[DateTimeOffset]::UtcNow.AddSeconds(-30*(29-$_)).ToString('o');LatencyMs=(70+($_%6)*4);Quality='Good'}})}
 SyncTCWebState -Force;WaitDom "document.querySelector('.response-value')?.textContent.includes('72')===true"
 Check ((Js "document.querySelectorAll('.response-chart svg polyline').length") -ceq '1') 'Only current bound samples render the response trend'
 Shot '08-home-sampled'
 $script:WebQuality.Degraded=$true;$script:WebQuality.Quality='Unknown';$script:WebQuality.LatencyMs=$null;$script:WebQuality.NotificationMessage='当前交易出口连续 3 次无法取得响应，质量未知；当前线路保持。'
 SyncTCWebState -Force;WaitDom "document.querySelector('.signal-title')?.textContent.includes('线路质量待检查')===true"
 Check ((Js "document.querySelector('.response-value')?.textContent.includes('—')") -ceq 'true') 'Measurement failure shows unknown rather than a fabricated latency'
 Shot '09-quality-unknown'
 $script:WebStandby=[pscustomobject]@{BindingKey=(Get-TCLineQualityContext $script:Overview).Key;Items=@([pscustomobject]@{Binding=@{NodeId='22222222-2222-2222-2222-222222222222'};LatencyMs=54;Fresh=$true;Reason='Measured';SampleAtUtc=[DateTimeOffset]::UtcNow.ToString('o')})}
 SyncTCWebState -Force;WaitDom "document.querySelector('.recommendation')?.textContent.includes('54 ms')===true"
 Check ((Js "document.querySelector('.recommendation button')?.textContent") -ceq '"检查并切换"') 'A fresh reachable backup produces a manual action, never an automatic switch'
 Shot '10-backup-suggestion'
 $script:WebStandby.Items[0].SampleAtUtc=[DateTimeOffset]::UtcNow.AddMinutes(-4).ToString('o');SyncTCWebState -Force
 WaitDom "document.querySelector('.recommendation') === null"
 Check ((Js "document.querySelector('.recommendation')===null") -ceq 'true') 'Expired backup data cannot remain recommended'
 $null=Js "document.querySelector('[data-detail]').click()";Pump
 Check ($script:Requests[-1].Action -ceq 'LineQualityHistory' -and $script:Requests[-1].Window -ceq 'Day') 'Line details request bounded history for that exact line'
 $end=[DateTimeOffset]::UtcNow;$start=$end.AddHours(-24)
 $script:WebQualityHistory=@{NodeId='11111111-1111-1111-1111-111111111111';Window='Day';Reason='Available';Series=@(@{Binding=@{Exit='hk';ProfileId='Udp'};Aggregate=@{StartAtUtc=$start.ToString('o');EndAtUtc=$end.ToString('o');Statistics=@{MeasuredCount=3;UnavailableCount=1;AverageLatencyMs=80};Buckets=@(@{MeasuredCount=1;AverageLatencyMs=60},@{MeasuredCount=1;AverageLatencyMs=80},@{MeasuredCount=0;AverageLatencyMs=$null},@{MeasuredCount=1;AverageLatencyMs=100})}})}
 SyncTCWebState -Force;WaitDom "document.querySelector('.quality-history svg') !== null"
 Check ((Js "document.querySelectorAll('.quality-history polyline').length === 1 && document.querySelectorAll('.quality-history circle').length === 1") -ceq 'true') 'Historical chart preserves a measurement gap rather than joining across it'
 Shot '11-quality-history'
 $null=Js "document.querySelector('[data-history=ThirtyMinutes]').click()";Pump
 Check ($script:Requests[-1].Action -ceq 'LineQualityHistory' -and $script:Requests[-1].Window -ceq 'ThirtyMinutes') 'History range switch requests the selected time window'
 $null=Js "document.querySelector('[data-close=drawer]').click()";Pump
 Check (-not $script:WebQualityHistory) 'Closing history releases the large snapshot and prevents stale repaint'
 $script:Overview.ActiveProfileId='Tcp';SyncTCWebState -Force
 WaitDom "document.querySelector('.response-value')?.textContent.includes('—')===true && !document.querySelector('.notice.warn')"
 Check ((Js "document.querySelectorAll('.response-chart svg polyline').length") -ceq '0') 'A profile change hides the previous session trend and alert'
 $script:Nodes[1].Name='<img src=x onerror="alert(1)">';SyncTCWebState -Force
 WaitDom "document.body.textContent.includes('<img src=x onerror=')"
 Check ((Js 'document.querySelectorAll("main img").length') -ceq '0') 'Server names render as text and cannot inject markup'
 $script:WebShell.CoreWebView2.Navigate('https://example.invalid/')
 for($i=0;$i -lt 10;$i++){Pump}
 Check ($script:WebShell.CoreWebView2.Source -ceq 'https://tradechannel.local/index.html') 'Navigation remains on the packaged local UI'
 $passed=$true
}catch{$failure=$_.Exception.Message;throw}finally{
 $result=@{Passed=$passed;Checks=$script:Checks.Count;Assertions=$script:Checks.ToArray();Failure=$failure;NetworkChanged=$false;WorkersStarted=0;BrowserRuntime='WebView2'}
 [IO.File]::WriteAllText((Join-Path $out 'result.json'),($result|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($true)))
 if($script:WebShell){$script:WebShell.Dispose()};$script:Window.Close()
 # WebView processes release their temporary cache asynchronously. Keep this
 # explicitly named fixture for diagnosis if Windows still holds the files.
 $full=[IO.Path]::GetFullPath($fixture);$prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if($full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($full) -cmatch '^TC-WebShell-[0-9a-f]{32}$'){try{Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop}catch{}}
}
$result|ConvertTo-Json -Depth 8
