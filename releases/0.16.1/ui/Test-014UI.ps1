# Isolated WPF/Windows shell checks only. The inherited harness blocks Workers.
if(-not $script:Smoke -or -not $SelfTest){throw 'Only isolated SelfTest is permitted.'}
$script:UI014Enabled=$true
function UI014Check {param([bool]$TradePassed=$true,[bool]$DailyPassed=$true)
 [pscustomobject]@{Time=[DateTimeOffset]::UtcNow.ToString('o');ExitHttp=$TradePassed;ObservedIP=$(if($TradePassed){'203.0.113.10'}else{''});DailyHttp=$DailyPassed;DailyIP=$(if($DailyPassed){'198.51.100.20'}else{''});DailyLane='provider2';AgentLane='daily';TradingViewHttp=$TradePassed;TradeLatencyMs=158;CheckContext=(Get-TCExitCheckContext $script:Overview);ContextChanged=$false}
}
function Fixture014 {
 Fixture0120 'Connected'
 foreach($pair in @(@('SessionId','fixture-session'),@('ConfigHash',('A'*64)),@('EnginePid',123),@('ActiveLineId',$hk),@('ActiveProfileId','Udp'))){$script:Overview|Add-Member NoteProperty $pair[0] $pair[1] -Force}
 $script:Overview.Daily='provider2';$script:Overview.DesiredDaily='Provider';$script:Prefs.ProviderId='pv-clash';$script:Prefs.Daily='Provider'
 $script:StatusDetailsOpen=$false;$script:Window.Width=1280;$script:Window.Height=800
}
function AssertSyncedIcons0141 {param([string]$Expected)
 UpdateChrome;$script:Window.UpdateLayout();$null=$script:Window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Render)
 $hwnd=(New-Object Windows.Interop.WindowInteropHelper($script:Window)).Handle
 $resource=[TradeChannel.UI.BrandNative]::ReadWindowIconResource($hwnd)
 AssertUI ($script:TrayVisualState.Icon -eq $Expected -and $resource.EndsWith('TradeChannel.exe,0') -and $script:IconPresentation.WindowIconSource -eq $script:IconPresentation.TrayIconSource -and $script:IconPresentation.TaskbarOverlayState -eq $Expected) ('0141 '+$Expected+' uses one state for the window, taskbar status overlay and tray')
 AssertUI ($script:Window.TaskbarItemInfo.Overlay -eq (BrandTaskbarOverlay $Expected) -and $script:Window.TaskbarItemInfo.Description -eq ('TradeChannel · '+$script:TrayVisualState.Summary)) ('0141 '+$Expected+' taskbar has a cached status image and matching accessible summary')
 $overlay=New-Object Windows.Media.Imaging.RenderTargetBitmap(16,16,96,96,[Windows.Media.PixelFormats]::Pbgra32)
 $visual=New-Object Windows.Media.DrawingVisual;$dc=$visual.RenderOpen()
 try{$dc.DrawImage($script:Window.TaskbarItemInfo.Overlay,(New-Object Windows.Rect(0,0,16,16)))}finally{$dc.Close()}
 $overlay.Render($visual);$bytes=New-Object byte[](16*16*4);$overlay.CopyPixels($bytes,64,0)
 $color=[Windows.Media.ColorConverter]::ConvertFromString($script:IconPresentation.TaskbarOverlayColor);$pixels=0
 for($i=0;$i -lt $bytes.Length;$i+=4){if($bytes[$i+3] -gt 240 -and [Math]::Abs($bytes[$i]-$color.B) -lt 8 -and [Math]::Abs($bytes[$i+1]-$color.G) -lt 8 -and [Math]::Abs($bytes[$i+2]-$color.R) -lt 8){$pixels++}}
 AssertUI ($pixels -gt 35) ('0141 taskbar overlay pixels actually have '+$Expected+' color')
 function RenderNative0141 {param([IntPtr]$Handle,[int]$Size)
  $bitmap=New-Object Drawing.Bitmap($Size,$Size);$graphics=[Drawing.Graphics]::FromImage($bitmap);$graphics.Clear([Drawing.Color]::White);$dc=$graphics.GetHdc()
  try{[TradeChannel.UI.BrandNative]::DrawNativeIcon($dc,$Handle,$Size,$Size)}finally{$graphics.ReleaseHdc($dc);$graphics.Dispose()}
  $bitmap
 }
 $nativeBitmap=RenderNative0141 ([TradeChannel.UI.BrandNative]::ReadWindowIcon($hwnd)) 32;$trayBitmap=RenderNative0141 $script:Tray.Icon.Handle $script:Tray.Icon.Width
 try{
  foreach($entry in @(@('window',$nativeBitmap),@('tray',$trayBitmap))){
   $pixels=0;$bitmap=$entry[1]
   for($x=0;$x -lt $bitmap.Width;$x++){for($y=0;$y -lt $bitmap.Height;$y++){
    $c=$bitmap.GetPixel($x,$y);$match=if($Expected -eq 'connected'){$c.G -gt 120 -and $c.G -gt $c.R*1.5 -and $c.G -gt $c.B*1.3}elseif($Expected -eq 'busy'){$c.R -gt 180 -and $c.G -gt 70 -and $c.G -lt 210 -and $c.B -lt 90}else{$c.R -gt 100 -and $c.R -lt 220 -and $c.G -gt 100 -and $c.B -gt 100 -and [Math]::Abs($c.R-$c.B) -lt 65}
    if($c.A -gt 128 -and $match){$pixels++}
   }}
   if($pixels -le 3){$bitmap.Save((Join-Path $qa ('icon-mismatch-'+$entry[0]+'-'+$Expected+'.png')),[Drawing.Imaging.ImageFormat]::Png)}
   AssertUI ($pixels -gt 3) ('0141 '+$entry[0]+' native pixels actually have '+$Expected+' color')
  }
 }finally{$nativeBitmap.Dispose();$trayBitmap.Dispose()}
}
function InvokeUI014Tests {
 $start=$script:Assertions.Count
 Fixture014;$script:Checks=@{Data=(UI014Check)};ShowHome;UpdateChrome;Snapshot '014-01-split-traffic'
 AssertUI ($script:Controls.StatusTitle.Text -eq '通道运行中' -and $script:TrayVisualState.Icon -eq 'connected') '014 green describes the running channel, never overall business health'
 AssertUI ($script:Tray.Icon.Size -eq [Windows.Forms.SystemInformation]::SmallIconSize) '014 the native tray uses the actual small icon frame instead of a default large frame'
 AssertSyncedIcons0141 'connected'
 AssertUI ($script:Controls.TradeLaneEvidence.Text -like '*203.0.113.10*检查通过*' -and $script:Controls.DailyLaneEvidence.Text -like '*198.51.100.20*') '014 each traffic row carries its own bound exit evidence'
 AssertUI ($script:Controls.TradeLaneStatus.Text -notmatch '未完成|未通过') '014 a measured success cannot contradict an incomplete profile summary in the same row'
 AssertUI ($script:Controls.AgentLaneEvidence.Text -like '*按分流规则*198.51.100.20*未单独验证*') '014 AI inheritance is labelled as an inference, not a platform acceptance test'
 AssertUI (-not $script:Controls.StatusDetails.IsExpanded) '014 healthy details are collapsed by default'
 Fixture014;$script:Overview.GuardState='Unprotected';ShowHome
 AssertUI ($script:Controls.StatusMeta.Text -like '*保护不完整*' -and $script:Controls.StatusMeta.Foreground.ToString() -eq '#FFB42318' -and $script:Controls.StatusDetails.IsExpanded) '014 an incomplete trading guard is visible in the first-screen hero and expands diagnostic details'
 Snapshot '014-06-protection-warning';Fixture014;ShowHome
 $handle=(New-Object Windows.Interop.WindowInteropHelper($script:Window)).Handle
 AssertUI ([TradeChannel.UI.BrandNative]::ReadWindowAppId($handle) -eq [TradeChannel.UI.BrandNative]::SelfTestAppId) '014 isolated WPF checks have a stable identity separate from the production taskbar group'
 AssertUI ([TradeChannel.UI.BrandNative]::ReadWindowIcon($handle) -ne [IntPtr]::Zero) '014 the actual Windows window exposes its own native icon'
 $linkPath=Join-Path $script:Root 'TradeChannel-fixture.lnk';$shell=New-Object -ComObject WScript.Shell
 try{$link=$shell.CreateShortcut($linkPath);$link.TargetPath=Join-Path $script:PackageRoot 'TradeChannel.exe';$link.IconLocation=(Join-Path $script:PackageRoot 'assets\TradeChannel.ico')+',0';$link.Save();[TradeChannel.UI.BrandNative]::SetShortcut($linkPath,$true);AssertUI ([TradeChannel.UI.BrandNative]::ReadShortcutAppId($linkPath) -eq [TradeChannel.UI.BrandNative]::SelfTestAppId) '014 actual temporary Windows shortcut shares the isolated management window identity'}finally{$null=[Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)}
 AssertUI ($script:Window.Icon.PixelWidth -eq 32 -and $script:Window.FindName('BrandMark').Source.PixelWidth -eq 24) '014 window and header use independently rendered icon size frames'
 foreach($pending in @('Connecting','Applying','Disconnecting')){
  $script:Pending=$pending;UpdateChrome
  AssertUI ($script:TrayVisualState.Icon -eq 'busy') ('014 '+$pending+' immediately updates the tray before runtime polling')
  AssertSyncedIcons0141 'busy'
 }
 foreach($pending in @('ApplyingDaily','ApplyingAgents','CheckingProvider')){
  $script:Pending=$pending;UpdateChrome
  AssertUI ($script:TrayVisualState.Icon -eq 'connected') ('014 '+$pending+' does not pretend the trade channel disconnected')
  AssertSyncedIcons0141 'connected'
 }
 $script:Pending=$null
 foreach($key in @('ActiveLineId','ActiveProfileId','SessionId','ConfigHash','Exit','Daily','Agents','Mode','ProviderId')){
  Fixture014;$script:Checks=@{Data=(UI014Check)};$script:Overview.$key=if($key -eq 'ConfigHash'){'B'*64}else{'changed'};ShowHome
  AssertUI ($script:Controls.TradeLaneEvidence.Text -notlike '*203.0.113.10*' -and (CurrentExitCheck).Status -eq 'Stale') ('014 changing '+$key+' removes the stale IP from traffic rows')
 }
 Fixture014;$script:Checks=@{Data=(UI014Check $false)};ShowHome;Snapshot '014-02-check-failed'
 AssertUI ($script:Controls.TradeLaneEvidence.Text -like '*未通过*' -and $script:Controls.StatusDetails.IsExpanded) '014 failure stays explicit and opens the diagnostic details'
 Fixture014;$script:Overview|Add-Member NoteProperty RuntimeValidation ([pscustomobject]@{Status='Passed';ForwardingPassed=$true;LineId=$hk;ProfileId='Udp';SessionId='fixture-session';ConfigHash=('A'*64);CheckedAtUtc=[DateTimeOffset]::UtcNow.AddMinutes(-5).ToString('o')}) -Force;ShowHome
 AssertUI ($script:Controls.TradeLaneEvidence.Text -like '*连接时网络检查通过*' -and $script:Controls.TradeLaneEvidence.Text -notlike '*实测出口*') '014 connection-time evidence is distinguished from a fresh exit IP measurement'
 Fixture014;$script:Checks=@{Data=(UI014Check)};$script:Checks.Data.Time=[DateTimeOffset]::UtcNow.AddMinutes(-11).ToString('o');ShowHome
 AssertUI ($script:Controls.TradeLaneEvidence.Text -like '*过期*' -and $script:Controls.TradeLaneEvidence.Text -notlike '*203.0.113.10*') '014 expired evidence cannot look like a fresh green success'
 Fixture014;$script:Overview.Mode='global';$script:Checks=@{Data=(UI014Check)};ShowHome;UpdateChrome;Snapshot '014-03-global-locked'
 $selected=$script:Controls[(SegId 'Agents' 'Trade')];$selected.ApplyTemplate()|Out-Null
 AssertUI (-not $selected.IsEnabled -and $selected.Template.FindName('SelectionMark',$selected)) '014 the locked selected route retains its check mark'
 Fixture014;$script:Overview.StateKey='Fault';$script:Overview.Running=$false;$script:Overview.Error='模拟控制接口读取失败，进程状态尚待核对。';ShowHome;UpdateChrome;Snapshot '014-04-fault'
 AssertUI ($script:TrayVisualState.Icon -eq 'fault' -and $script:Controls.StatusTitle.Text -like '*需要处理*' -and $script:Controls.StatusDetails.IsExpanded) '014 uncertain fault remains visibly distinct from intentional disconnect'
 AssertSyncedIcons0141 'fault'
 AssertUI ($script:Controls.TradeLaneStatus.Text -like '*当前走向待核对*' -and $script:Controls.AgentLaneEvidence.Text -notmatch '连接后|实测出口') '014 unknown runtime state cannot masquerade as a known disconnected route'
 $script:LastObservedState='Connected';$script:LastFaultNotice=$null;$script:UserDisconnectIntent=$false;$script:TrayNotifications=@();ObserveTrayState $script:Overview
 AssertUI ($script:TrayNotifications.Count -eq 1) '014 unexpected fault retains the existing notification'
 ObserveTrayState $script:Overview;AssertUI ($script:TrayNotifications.Count -eq 1) '014 repeated polling does not repeat the same interruption notice'
 $script:LastObservedState='Connected';$script:UserDisconnectIntent=$true;ObserveTrayState $script:Overview
 AssertUI ($script:TrayNotifications.Count -eq 1) '014 intentional stop does not raise an unexpected-interruption notice'
 foreach($state in @('Disconnected','Loading','Unconfigured')){Fixture014;$script:Overview.StateKey=$state;$script:Overview.Running=$false;UpdateChrome;AssertSyncedIcons0141 'idle'}
 Fixture014;ShowHome;UpdateChrome
 foreach($id in @('Primary',(SegId 'Daily' 'Provider'),(SegId 'Agents' 'Daily'),'FlowCheckConnection')){
  $control=$script:Controls[$id];$pt=$control.TranslatePoint((New-Object Windows.Point(0,0)),$script:Window.Content)
  AssertUI ($pt.Y -ge 0 -and $pt.Y+$control.ActualHeight -lt $script:Window.Content.ActualHeight-29) ('014 '+$id+' is visible on the wide 800px first screen')
 }
 $script:Window.Width=1000;$script:Window.Height=680;ShowHome;ScrollToUI 'FlowCheckConnection';Snapshot '014-05-minimum'
 foreach($id in @('ProviderChoice',(SegId 'Agents' 'Daily'),'FlowCheckConnection')){
  ScrollToUI $id;$control=$script:Controls[$id];$pt=$control.TranslatePoint((New-Object Windows.Point(0,0)),$script:Window.Content)
  AssertUI ($pt.X -ge 0 -and $pt.X+$control.ActualWidth -le $script:Window.Content.ActualWidth) ('014 minimum width keeps '+$id+' reachable')
 }
 . (Join-Path $PSScriptRoot 'Test-011UI.ps1')
 AssertSyncedIcons0141 'connected'
 AssertUI (-not (Test-Path -LiteralPath $script:JobRoot) -and -not $script:Timer.IsEnabled) '014 presentation and window checks never launch the production dispatcher'
 $summary=[ordered]@{Passed=$true;Assertions=($script:Assertions.Count-$start);Checks=@($script:Assertions.ToArray()|Select-Object -Skip $start);NetworkChanged=$false;WpfRendered=$true;WindowAppIdVerified=$true}
 [IO.File]::WriteAllText((Join-Path $qa 'ui-014-result.json'),($summary|ConvertTo-Json -Depth 6),(New-Object Text.UTF8Encoding($true)))
}
. (Join-Path $PSScriptRoot 'Test-013UI.ps1')
