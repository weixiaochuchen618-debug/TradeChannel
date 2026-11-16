#requires -Version 5.1
#requires -PSEdition Desktop
[CmdletBinding()]param([Parameter(Mandatory=$true)][string]$ReportDirectory)
$ErrorActionPreference='Stop'
if([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw 'WPF visual verification requires -Sta'}
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$script:PackageRoot=Split-Path $PSScriptRoot -Parent
. (Join-Path $script:PackageRoot 'ui\ConnectionProfilePages.ps1')
. (Join-Path $script:PackageRoot 'ui\DeploymentPages.ps1')
$script:Controls=@{};$script:Ink='#0F1A38';$script:Text2='#475467';$script:Text3='#667085';$script:Smoke=$true
function AddC {param($Parent,$Child)$null=$Parent.Children.Add($Child)}
function T {param([string]$Text,[double]$Size=13,[string]$Color='#0F1A38',[string]$Weight='Normal')
 $t=New-Object Windows.Controls.TextBlock;$t.Text=$Text;$t.FontFamily='Microsoft YaHei UI';$t.FontSize=$Size;$t.FontWeight=$Weight;$t.TextWrapping='Wrap'
 $t.Foreground=([Windows.Media.BrushConverter]::new()).ConvertFromString($Color);return $t
}
function Margin {param($Element,[string]$Value)$Element.Margin=[Windows.Thickness]$Value;return $Element}
function ControlName {param($Element,[string]$Id)$script:Controls[$Id]=$Element;return $Element}
$checks=New-Object 'Collections.Generic.List[string]';$passed=$false;$failure=''
function Check {param([bool]$Ok,[string]$Label)if(-not $Ok){throw $Label};$checks.Add($Label)}
try{
 $directory=[IO.Path]::GetFullPath($ReportDirectory);$null=[IO.Directory]::CreateDirectory($directory)
 $root=New-Object Windows.Controls.Border;$root.Width=760;$root.Padding='24';$root.Background=([Windows.Media.BrushConverter]::new()).ConvertFromString('#F4F6FA')
 $stack=New-Object Windows.Controls.StackPanel;$root.Child=$stack
 AddC $stack (Margin (T '添加线路 · 四步进度' 23 '#0F1A38' 'SemiBold') '0,0,0,18')
 foreach($case in @(
  @{Stage='Inspect';Status='Running';Name='连接服务器'},
  @{Stage='TcpApply';Status='Running';Name='安装线路服务'},
  @{Stage='CheckingProfiles';Status='Failed';Name='需要处理'},
  @{Stage='ReadyInactive';Status='Complete';Name='准备完成'}
 )){
  $run=[pscustomobject]@{RunId=[guid]::NewGuid().ToString('D');Name='隔离示例';Stage=$case.Stage;Status=$case.Status;ProfileProbeState='Completed';AttentionRequired=$false}
  $script:DeployUI=@{Run=$run;PreparationConsentNotice=''}
  $card=New-Object Windows.Controls.Border;$card.Background=[Windows.Media.Brushes]::White;$card.CornerRadius='12';$card.Padding='20';$card.Margin='0,0,0,14'
  $body=New-Object Windows.Controls.StackPanel;$card.Child=$body
  AddC $body (Margin (T ([string]$case.Name) 17 '#0F1A38' 'SemiBold') '0,0,0,14')
  AddDeploymentProgressUI $body $run
  $row=$script:Controls.DeployFourSteps
  Check ($row.Children.Count -eq 4) ($case.Stage+': actual production component renders exactly four steps')
  $labels=@($row.Children|ForEach-Object Text)
  Check (($labels -join '|') -ceq '1 连接服务器|2 安装线路服务|3 设置这台电脑|4 测试线路') ($case.Stage+': rendered steps use short human labels')
  AddC $body (T (Get-TCDeploymentProgress $run).Summary 13 '#475467')
  AddC $stack $card
 }
 $root.Measure([Windows.Size]::new(760,[double]::PositiveInfinity));$height=[int][math]::Ceiling($root.DesiredSize.Height)
 $root.Arrange([Windows.Rect]::new(0,0,760,$height));$root.UpdateLayout()
 Check ($height -gt 400 -and $height -lt 900) 'Four states fit in one bounded review image'
 $bitmap=New-Object Windows.Media.Imaging.RenderTargetBitmap(760,$height,96,96,[Windows.Media.PixelFormats]::Pbgra32);$bitmap.Render($root)
 $encoder=New-Object Windows.Media.Imaging.PngBitmapEncoder;$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
 $file=Join-Path $directory 'deployment-four-steps.png';$stream=[IO.File]::Open($file,[IO.FileMode]::Create)
 try{$encoder.Save($stream)}finally{$stream.Dispose()}
 Check ((Get-Item -LiteralPath $file).Length -gt 5000) 'Actual WPF pixels were rendered without opening the product or creating a session'
 # Narrow layout must wrap complete labels instead of clipping them.
 $narrow=New-Object Windows.Controls.StackPanel;$narrow.Width=320
 AddDeploymentProgressUI $narrow $run
 $narrow.Measure([Windows.Size]::new(320,[double]::PositiveInfinity));$narrow.Arrange([Windows.Rect]::new(0,0,320,$narrow.DesiredSize.Height));$narrow.UpdateLayout()
 Check ($script:Controls.DeployFourSteps.ActualHeight -gt 25 -and $script:Controls.DeployFourSteps.ActualHeight -lt 120) 'Narrow form wraps the four complete step labels'
 $passed=$true
}catch{$failure=$_.Exception.Message;throw}
finally{
 $result=[pscustomobject]@{Passed=$passed;Count=$checks.Count;Checks=$checks.ToArray();Failure=$failure;Renderer='WPF RenderTargetBitmap';ProductWindowOpened=$false;NetworkChanges=0;RemoteOperations=0;PowerShell=$PSVersionTable.PSVersion.ToString()}
 [IO.File]::WriteAllText((Join-Path ([IO.Path]::GetFullPath($ReportDirectory)) 'progress-ui.json'),($result|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($true))
 $result|Select-Object Passed,Count,Failure|ConvertTo-Json
}
