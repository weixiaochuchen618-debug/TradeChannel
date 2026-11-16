#requires -Version 5.1
#requires -PSEdition Desktop
[CmdletBinding()]
param([string]$PackageRoot='',[string]$ReportDirectory='',[switch]$CheckWebShellIntegration)
$ErrorActionPreference='Stop'
$env:PSModulePath=Join-Path $PSHOME 'Modules'
if(-not $PackageRoot){$PackageRoot=Split-Path $PSScriptRoot -Parent}
if($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1){throw 'Run this fixture with Windows PowerShell 5.1.'}
if([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw 'Run this fixture with powershell.exe -Sta.'}
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$script:PackageRoot=[IO.Path]::GetFullPath($PackageRoot)
$script:DensityChecks=New-Object 'Collections.Generic.List[string]'
$script:DensitySources=New-Object 'Collections.Generic.List[object]'
$script:DensitySnapshots=New-Object 'Collections.Generic.List[string]'
$script:DensityReportDirectory=''
if($ReportDirectory){$script:DensityReportDirectory=[IO.Path]::GetFullPath($ReportDirectory);$null=[IO.Directory]::CreateDirectory($script:DensityReportDirectory)}
$script:Window=$null;$passed=$false;$failure=''
function Check {param([bool]$Condition,[string]$Message)
 if(-not $Condition){throw ('ChromeDensity: '+$Message)}
 $script:DensityChecks.Add($Message)
}
function ImportPresentationFunctions {param([string]$File,[string[]]$Names)
 $path=Join-Path $script:PackageRoot $File;$tokens=$null;$errors=$null
 $ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
 Check ($errors.Count -eq 0) ($File+' 可由 PS5.1 解析')
 $script:DensitySources.Add([pscustomobject]@{File=$File;SHA256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash;Functions=$Names})
 foreach($name in $Names){
  $definitions=@($ast.FindAll({param($a)$a -is [Management.Automation.Language.FunctionDefinitionAst]},$false)|Where-Object Name -CEQ $name)
  if($definitions.Count -ne 1){throw ('Expected one presentation function: '+$name)}
  $body=$definitions[0].Body.Extent.Text
  Set-Item -Path ('Function:script:'+$name) -Value ([scriptblock]::Create($body.Substring(1,$body.Length-2)))
 }
}
# Extract presentation functions only: no startup code, store, worker, tray or browser.
function Hero {if($script:DensityState -eq 'Connected'){@{Tone='ok';Title='已连接'}}else{@{Tone='idle';Title='未连接'}}}
function StateKey {$script:DensityState}
function TradeLabel {'隔离测试线路'}
function UpdateTrayPresentation {$script:DensityTrayUpdates++}
function SyncTCWebState {param([switch]$Force) $script:DensitySyncs++}
function SetNavigationContext {param([string]$Section,[string]$View) $script:DensityNavigation=@{Section=$Section;View=$View}}
function StartJob {throw 'This fixture must not dispatch any worker.'}
function Start-Process {throw 'This fixture must not start any process.'}
function Layout {
 $script:Window.UpdateLayout()
 $null=$script:Window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Render)
}
function SaveWindowSnapshot {param([string]$Name)
 if(-not $script:DensityReportDirectory){return}
 Layout;$width=[int][Math]::Ceiling($script:Window.ActualWidth);$height=[int][Math]::Ceiling($script:Window.ActualHeight)
 $bitmap=New-Object Windows.Media.Imaging.RenderTargetBitmap($width,$height,96,96,[Windows.Media.PixelFormats]::Pbgra32);$bitmap.Render($script:Window)
 $encoder=New-Object Windows.Media.Imaging.PngBitmapEncoder;$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
 $path=Join-Path $script:DensityReportDirectory ($Name+'.png');$stream=[IO.File]::Create($path);try{$encoder.Save($stream)}finally{$stream.Dispose()};$script:DensitySnapshots.Add($path)
}
function CheckWebChrome {param([string]$Modes='',[string]$Label='Web')
 Layout
 foreach($name in @('StatusChip','FooterStatus','FooterContext')){
  $control=$script:Window.FindName($name)
  Check ($control.Visibility -eq 'Collapsed' -and -not $control.IsVisible) ($Label+' 隐藏 '+$name)
 }
 $mode=$script:Window.FindName('FooterMode');$footer=$script:Window.FindName('ShellFooter');$row=$script:Window.FindName('ShellFooterRow')
 if($Modes){
  Check ($mode.IsVisible -and $mode.Text -ceq $Modes -and $mode.Text -notlike ('*'+$script:Version+'*')) ($Label+' 仅显示运行模式，不显示版本')
  Check ($footer.IsVisible -and $row.Height.Value -eq 30 -and $row.ActualHeight -eq 30) ($Label+' 为运行模式保留底栏')
 }else{
  Check ($mode.Visibility -eq 'Collapsed' -and -not $footer.IsVisible -and $row.Height.Value -eq 0 -and $row.ActualHeight -eq 0) ($Label+' 底栏完全收起，无空白占位')
 }
}
function CheckFallbackChrome {param([string]$Modes='',[string]$Label='WPF')
 Layout
 foreach($name in @('StatusChip','FooterStatus','FooterContext')){
  Check ($script:Window.FindName($name).IsVisible) ($Label+' 恢复 '+$name)
 }
 $expected='TradeChannel '+$script:Version
 if($Modes){$expected+=' / '+$Modes}
 Check ($script:Window.FindName('FooterContext').Text -ceq $expected) ($Label+' 显示当前版本及运行模式')
 Check ($script:Window.FindName('FooterMode').Visibility -eq 'Collapsed' -and $script:Window.FindName('ShellFooter').IsVisible -and $script:Window.FindName('ShellFooterRow').ActualHeight -eq 30) ($Label+' 底栏恢复且模式不重复')
}
try{
 ImportPresentationFunctions 'TradeChannel.ps1' @('SetTCChromeDensity','SetTCChromeTheme','UpdateChrome','B')
 foreach($path in @((Join-Path $script:PackageRoot 'TradeChannel.ps1'),$PSCommandPath)){
  $bytes=[IO.File]::ReadAllBytes($path)
  Check ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) ((Split-Path $path -Leaf)+' 保留 UTF8 BOM')
 }
 $tokens=$null;$errors=$null;$null=[Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$errors)
 Check ($errors.Count -eq 0) '测试脚本可由 PS5.1 解析'
 $script:Version=[string](([IO.File]::ReadAllText((Join-Path $script:PackageRoot 'version.json'),[Text.Encoding]::UTF8)|ConvertFrom-Json).Version)
 Check ($script:Version -match '^\d+\.\d+\.\d+$') '使用发布目录的实际版本元数据'
 $xamlPath=Join-Path $script:PackageRoot 'ui\Shell.xaml'
 [xml]$xaml=[IO.File]::ReadAllText($xamlPath,[Text.Encoding]::UTF8)
 $reader=New-Object Xml.XmlNodeReader($xaml)
 try{$script:Window=[Windows.Markup.XamlReader]::Load($reader)}finally{$reader.Close()}
 $script:DensitySources.Add([pscustomobject]@{File='ui\Shell.xaml';SHA256=(Get-FileHash -LiteralPath $xamlPath -Algorithm SHA256).Hash;Functions=@()})
 $script:Window.WindowStartupLocation='Manual';$script:Window.Left=-15000;$script:Window.Top=-15000
 $script:Window.Width=1000;$script:Window.Height=680;$script:Window.ShowInTaskbar=$false;$script:Window.ShowActivated=$false
 $script:Window.Show();Layout
 $chrome=[Windows.Shell.WindowChrome]::GetWindowChrome($script:Window)
 Check ([Math]::Abs($chrome.CaptionHeight-44) -lt 0.1) 'WPF 拖拽标题区收至 44px'
 Check ($script:Window.FindName('ShellHeader').ActualHeight -eq 44) '标题栏行高为 44px'
 foreach($name in @('HeaderHelp','WindowMinimize','WindowMaximize','WindowClose')){Check ($script:Window.FindName($name).ActualHeight -eq 44) ($name+' 匹配紧凑标题栏高度')}
 Check ($script:Window.FindName('WindowClose').Width -eq 42) '窗口控制按钮采用紧凑宽度'
 SetTCChromeTheme -Theme 'light';Layout
 SaveWindowSnapshot 'titlebar-light'
 Check ($script:Window.FindName('ShellHeader').Background.Color.ToString() -ceq '#FFFFFFFF') '浅色主题标题栏背景为白色'
 SetTCChromeTheme -Theme 'dark';Layout
 SaveWindowSnapshot 'titlebar-dark'
 Check ($script:Window.FindName('ShellHeader').Background.Color.ToString() -ceq '#FF141E30') '深色主题标题栏背景同步变暗'
 Check ($script:Window.FindName('BrandMark').Parent.Children[1].Foreground.Color.ToString() -ceq '#FFE5EBF7') '深色主题标题文字保持清晰'
 Check ($script:Window.FindName('WindowMinimize').Content.Stroke.Color.ToString() -ceq '#FF9BAAC2') '深色主题窗口图标保持清晰'
 SetTCChromeTheme -Theme 'light';Layout
 Check ($script:Window.FindName('StatusChip').IsVisible -and $script:Window.FindName('FooterContext').IsVisible -and $script:Window.FindName('ShellFooterRow').ActualHeight -eq 30) 'XAML 默认保持兼容界面的状态和版本区域'
 $script:ReadOnly=$false;$script:Smoke=$false
 $script:DensityState='Connected';$script:DensityTrayUpdates=0;$script:DensitySyncs=0
 $script:Tone=@{ok=@{Fg='#15803D';Bg='#ECF8F0';Dot='#22A55B'};idle=@{Fg='#4B5360';Bg='#F2F3F5';Dot='#A9AFB8'}};$script:Text2='#4B5360'
 SetTCChromeDensity -WebActive $false
 CheckFallbackChrome
 foreach($densityPageId in @('home','lines','apps','settings','add-line')){
  $script:Page='web';$script:WebPage=$densityPageId
  SetTCChromeDensity -WebActive $true
  CheckWebChrome -Label $densityPageId
 }
 SetTCChromeDensity -WebActive $true
 UpdateChrome
 Check ($script:Window.FindName('ChipText').Text -ceq '已连接 · 隔离测试线路' -and $script:DensityTrayUpdates -eq 1) 'Web 模式仍更新兼容状态和托盘展示入口'
 CheckWebChrome -Label '重复启用及刷新'
 $script:DensityState='Disconnected';$script:Footer=$script:Window.FindName('FooterStatus');$script:Footer.Text='隔离状态已更新'
 UpdateChrome
 SetTCChromeDensity -WebActive $false
 CheckFallbackChrome -Label '恢复'
 Check ($script:Window.FindName('ChipText').Text -ceq '未连接' -and $script:Footer.Text -ceq '隔离状态已更新') '恢复兼容界面时显示最新状态，不回退到旧状态'
 foreach($case in @(@{ReadOnly=$true;Smoke=$false;Modes='READ ONLY';Label='只读'},@{ReadOnly=$false;Smoke=$true;Modes='UI TEST';Label='自检'},@{ReadOnly=$true;Smoke=$true;Modes='READ ONLY / UI TEST';Label='只读自检'})){
  $script:ReadOnly=$case.ReadOnly;$script:Smoke=$case.Smoke
  SetTCChromeDensity -WebActive $true
  CheckWebChrome -Modes $case.Modes -Label $case.Label
  # Legacy snapshot writers may still write a version into FooterContext.
  $script:Window.FindName('FooterContext').Text=$script:Version+' / '+$case.Modes
  Check (-not $script:Window.FindName('FooterContext').IsVisible -and $script:Window.FindName('FooterMode').Text -ceq $case.Modes) ($case.Label+' 旧截图文字写入不会泄漏版本或抹去模式')
  UpdateChrome
  CheckWebChrome -Modes $case.Modes -Label ($case.Label+'刷新')
  SetTCChromeDensity -WebActive $false
  CheckFallbackChrome -Modes $case.Modes -Label ($case.Label+'恢复')
 }
 $script:ReadOnly=$false;$script:Smoke=$false
 SetTCChromeDensity -WebActive $true
 CheckWebChrome -Label '清除模式'
 SetTCChromeDensity -WebActive $false
 CheckFallbackChrome -Label '最终兼容界面'
 foreach($name in @('HeaderHelp','WindowMinimize','WindowMaximize','WindowClose')){
  Check ($script:Window.FindName($name).IsVisible) ($name+' 保持可见')
 }
 if($CheckWebShellIntegration){
  # A plain WPF Border stands in for the web surface; no WebView2 is loaded.
  ImportPresentationFunctions 'ui\WebShell.ps1' @('ShowTCWebShell','SuspendTCWebShell','ShowTCWebFormSurface')
  $script:WebShell=New-Object Windows.Controls.Border;$script:WebShell.Visibility='Collapsed'
  [Windows.Controls.Grid]::SetRow($script:WebShell,1)
  $null=$script:Window.FindName('Frame').Child.Children.Add($script:WebShell)
  $script:WebReady=$true;$script:WebFailed=$false;$script:WebFormsFixture=$false
  foreach($densityPageId in @('home','lines','apps','settings','add-line')){
   Check (ShowTCWebShell $densityPageId) ($densityPageId+' 使用真实 WebShell 展示入口')
   CheckWebChrome -Label ($densityPageId+'接线')
  }
  SetTCChromeTheme -Theme 'dark'
  SuspendTCWebShell
  CheckFallbackChrome -Label 'Suspend接线'
  Check ($script:Window.FindName('ShellHeader').Background.Color.ToString() -ceq '#FFFFFFFF') '退出新版界面后标题栏随兼容界面恢复浅色'
  Check ($script:Window.FindName('Scroll').Parent.IsVisible -and $script:Window.FindName('NavHome').Parent.IsVisible -and $script:WebShell.Visibility -eq 'Collapsed') 'Suspend 同步恢复 WPF 内容及导航'
  ShowTCWebFormSurface
  CheckWebChrome -Label '表单接线'
  SuspendTCWebShell
  $script:WebReady=$false
  Check (-not (ShowTCWebShell 'home')) '尚未就绪的 WebShell 不切换外壳'
  CheckFallbackChrome -Label '未就绪'
  $script:WebReady=$true;$script:WebFailed=$true
  Check (-not (ShowTCWebShell 'home')) '失败的 WebShell 不切换外壳'
  CheckFallbackChrome -Label '初始化失败'
  $script:WebFailed=$false;$script:ReadOnly=$true
  Check (ShowTCWebShell 'settings') '只读 WebShell 可展示设置'
  CheckWebChrome -Modes 'READ ONLY' -Label '只读接线'
  SuspendTCWebShell
  CheckFallbackChrome -Modes 'READ ONLY' -Label '只读Suspend'
  $script:ReadOnly=$false;$script:Smoke=$true
  SetTCChromeDensity -WebActive $false
  Check (-not (ShowTCWebShell 'home')) '普通自检保持原有 WebShell 禁用规则'
  CheckFallbackChrome -Modes 'UI TEST' -Label '普通自检'
  $script:WebFormsFixture=$true
  Check (ShowTCWebShell 'home') '显式 Web 表单夹具可启用 WebShell'
  CheckWebChrome -Modes 'UI TEST' -Label '自检接线'
  SuspendTCWebShell
  CheckFallbackChrome -Modes 'UI TEST' -Label '自检Suspend'
 }
 $passed=$true
}catch{$failure=$_.Exception.Message;throw}
finally{
 if($script:Window){$script:Window.Close()}
 [ordered]@{Passed=$passed;Count=$script:DensityChecks.Count;PowerShellVersion=[string]$PSVersionTable.PSVersion;ProductVersion=$script:Version;WebShellIntegrationRequested=[bool]$CheckWebShellIntegration;WebView2Initialized=$false;WorkerLaunched=$false;RealDataAccessed=$false;Snapshots=@($script:DensitySnapshots.ToArray());Sources=@($script:DensitySources.ToArray());Checks=@($script:DensityChecks.ToArray());Failure=$failure}|ConvertTo-Json -Depth 6
}
