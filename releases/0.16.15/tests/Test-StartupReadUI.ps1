#requires -Version 5.1
param([string]$PackageRoot=(Split-Path $PSScriptRoot -Parent),[string]$ReportDirectory)
$ErrorActionPreference='Stop';$env:PSModulePath=Join-Path $PSHOME 'Modules'
$startupChecks=New-Object 'Collections.Generic.List[string]'
function Check {param($Ok,$Text)if(-not $Ok){throw $Text};$startupChecks.Add($Text)}
$source=[IO.File]::ReadAllText((Join-Path $PackageRoot 'TradeChannel.ps1'),[Text.Encoding]::UTF8)
$end=$source.LastIndexOf('if($SelfTest){');if($end -lt 0){throw 'Main startup boundary missing'}
# Load the actual full shell and functions in SelfTest mode. Only the terminal
# harness/dispatcher loop is excluded; no rendering/completion function is replaced.
$boot=$source.Substring(0,$end).Replace("`$ErrorActionPreference='Stop'",("`$PSScriptRoot='"+$PackageRoot.Replace("'","''")+"'`r`n`$ErrorActionPreference='Stop'"))
$passed=$false;$failure='';$ownedRoot=$null
$null=[IO.Directory]::CreateDirectory($ReportDirectory)
try{
 . ([scriptblock]::Create($boot)) -SelfTest
 $ownedRoot=$script:Root
 $script:Window.Show();$script:Window.UpdateLayout()
 function Shot {param($Name)
  $script:Window.UpdateLayout();$null=$script:Window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Render)
  $v=$script:Window.Content;$b=New-Object Windows.Media.Imaging.RenderTargetBitmap([int]$v.ActualWidth,[int]$v.ActualHeight,96,96,[Windows.Media.PixelFormats]::Pbgra32);$b.Render($v)
  $e=New-Object Windows.Media.Imaging.PngBitmapEncoder;$e.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($b));$s=[IO.File]::Create((Join-Path $ReportDirectory ($Name+'.png')));try{$e.Save($s)}finally{$s.Dispose()}
 }
 function Deliver {param($Result,$Complete={})
  $id=[guid]::NewGuid().ToString('N');$ui=[guid]::NewGuid().ToString('N')
  $job=@{Action='Overview';Policy=(GetUiJobPolicy 'Overview');RequestId=$id;UiRequestId=$ui;OriginContext=(CaptureNavigationContext);RequestData=@{Action='Overview'};Complete=$Complete;Silent=$true;PreserveFiles=$true;Lifecycle=@{UiRequestId=$ui;RequestId=$id;FinalizedDelivered=$false}}
  CompleteUiJob $job $Result
  Check (-not $job.CallbackFailed -and $job.Lifecycle.FinalizedDelivered) 'Real completion callback finishes without an exception'
 }
 $script:Overview=$null
 Deliver @{Ok=$false;Message='Fixture read failed';Code='ReadTimeout'}
 Check ((StateKey) -eq 'ReadUnknown' -and $script:Controls.StatusTitle.Text -eq '状态暂不可核验' -and $script:Controls.Primary.Content -eq '重试读取') 'Initial failure renders terminal unknown status and a real retry button'
 Check ($script:Window.FindName('Overlay').Visibility -eq 'Collapsed') 'Read failure does not open a callback error dialog'
 Shot 'startup-read-failed'
 foreach($i in 1..3){Deliver @{Ok=$false;Message='Fixture read failed';Code='ReadTimeout'}}
 Check ($script:Window.FindName('Overlay').Visibility -eq 'Collapsed') 'Repeated failure remains inline with no repeated modal'
 $script:Actions.Clear();$script:Controls.Primary.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
 Check ($script:Actions.Count -eq 1 -and $script:Actions[0].Request.Action -eq 'Overview') 'Retry button requests observation only, never reconnects'
 $complete=$script:Actions[0].Complete
 $snapshot=[pscustomobject]@{StateKey='Unconfigured';Running=$false;NodeId=$null;GuardState='Unknown';SessionId='';ConfigHash='';EnginePid=0;Mode='rule';Exit='hk';DesiredDaily='Direct';AgentIds=@();AgentCustom=@()}
 $script:ProvidersAt=Get-Date
 Deliver @{Ok=$true;Data=$snapshot} $complete
 Check ((StateKey) -eq 'Unconfigured' -and $script:Controls.StatusTitle.Text -eq '还没有交易线路') 'Successful actual refresh callback replaces failed read view'
 Shot 'startup-read-recovered'
 $snapshot.StateKey='Connected';$snapshot.Running=$true;$snapshot|Add-Member NoteProperty NodeName 'Fixture previous line';$snapshot|Add-Member NoteProperty SessionId 'fixture' -Force
 $script:Overview=$snapshot
 Deliver @{Ok=$false;Message='Fixture read unavailable';Code='ReadTimeout'}
 Check ([object]::ReferenceEquals($snapshot,$script:Overview) -and $script:Overview.Running -and $script:Overview.SessionId -eq 'fixture' -and (StateKey) -eq 'ReadUnknown') 'Later failure preserves exact previous session while marking freshness unknown'
 Check ($script:Controls.StatusDetail.Text -match '上次显示通道运行中') 'Retained snapshot is explicitly historical in the real UI'
 $passed=$true
}catch{$failure=$_.Exception.Message;throw}
finally{
 $proof=@{Passed=$passed;Count=$startupChecks.Count;Checks=@($startupChecks.ToArray());Failure=$failure;RealWorkerUsed=$false;RealCompletionAndRenderingUsed=$true;RealNetworkChanges=0}
 [IO.File]::WriteAllText((Join-Path $ReportDirectory 'result.json'),($proof|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($true))
 if($script:Window){$script:Closing=$true;$script:Window.Close()};if($script:Timer){$script:Timer.Stop()};if($script:Tray){$script:Tray.Dispose()}
 if($ownedRoot -and [IO.Directory]::Exists($ownedRoot)){$full=[IO.Path]::GetFullPath($ownedRoot);$prefix=[IO.Path]::GetTempPath().TrimEnd('\')+'\';if(-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -cnotmatch '^TradeChannel-ui-fixture-[a-f0-9]{32}$'){throw 'Unsafe WPF fixture cleanup'};Remove-Item -LiteralPath $full -Recurse -Force}
}
