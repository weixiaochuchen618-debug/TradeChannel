Import-Module (Join-Path $script:PackageRoot 'UiState.psm1') -DisableNameChecking
if(-not ('TradeChannel.UI.BrandNative' -as [type])){Add-Type -Path (Join-Path $script:PackageRoot 'BrandNative.cs')}
# This affects only the management window's Windows identity.
[TradeChannel.UI.BrandNative]::InitializeProcess($script:Smoke)
$script:Window.FindName('BrandMark').Source=[Windows.Media.Imaging.BitmapFrame]::Create((New-Object Uri((Join-Path $script:PackageRoot 'assets\TradeChannel-small.png'))))
$script:BrandImages=@{};$script:BrandTrayIcons=@{};$script:BrandWindowIcons=@{};$script:BrandTaskbarOverlays=@{};$script:LastBrandWindowKey='';$script:LastIconReportKey='';$script:LastTrayIconKey=''
$script:Window.TaskbarItemInfo=New-Object Windows.Shell.TaskbarItemInfo
function BrandTaskbarOverlay {param([ValidateSet('connected','busy','idle','fault')][string]$State)
 if(-not $script:BrandTaskbarOverlays.ContainsKey($State)){
  $color=@{connected='#22C55E';busy='#F5A524';idle='#98A2B3';fault='#98A2B3'}[$State]
  $group=New-Object Windows.Media.DrawingGroup
  $circle=New-Object Windows.Media.GeometryDrawing
  $circle.Brush=B $color;$circle.Pen=New-Object Windows.Media.Pen((B '#FFFFFF'),1.2)
  $circle.Geometry=New-Object Windows.Media.EllipseGeometry((New-Object Windows.Point(8,8)),7.2,7.2)
  $group.Children.Add($circle)
  $mark=New-Object Windows.Media.GeometryDrawing
  $mark.Pen=New-Object Windows.Media.Pen((B '#FFFFFF'),1.8)
  $mark.Pen.StartLineCap='Round';$mark.Pen.EndLineCap='Round';$mark.Pen.LineJoin='Round'
  $path=switch($State){
   connected {'M4.5,8 L7,10.5 L11.5,5.5'}
   busy {'M8,4.5 L8,8 L10.5,9.5'}
   idle {'M4.5,8 L11.5,8'}
   fault {'M8,4 L8,8.5 M8,11.2 L8,11.4'}
  }
  $mark.Geometry=[Windows.Media.Geometry]::Parse($path);$group.Children.Add($mark)
  $drawing=New-Object Windows.Media.DrawingImage($group);$drawing.Freeze()
  $script:BrandTaskbarOverlays[$State]=$drawing
 }
 $script:BrandTaskbarOverlays[$State]
}
function BrandImage {param([string]$State='white',[double]$Size=36)
 $name=if($State -eq 'white'){'TradeChannel'}else{'TradeChannel-'+$State}
 if(-not $script:BrandImages.ContainsKey($name)){
  $path=Join-Path $script:PackageRoot ('assets\'+$name+'.png')
  $bitmap=New-Object Windows.Media.Imaging.BitmapImage
  $bitmap.BeginInit();$bitmap.CacheOption='OnLoad';$bitmap.UriSource=New-Object Uri($path);$bitmap.EndInit();$bitmap.Freeze()
  $script:BrandImages[$name]=$bitmap
 }
 $image=New-Object Windows.Controls.Image;$image.Source=$script:BrandImages[$name];$image.Width=$Size;$image.Height=$Size;$image.Stretch='Uniform';$image.IsHitTestVisible=$false
 [Windows.Automation.AutomationProperties]::SetName($image,('TradeChannel · '+$State))
 $image
}
function UpdateTrayPresentation {
 $state=Get-TCVisualState -State (StateKey) -Running ([bool]($script:Overview -and $script:Overview.Running)) -LineName $(if($script:Overview -and $script:Overview.Running){TradeLabel}else{''}) -ProfileId $(if($script:Overview){[string](ProfileUIField $script:Overview 'ActiveProfileId' '')}else{''})
 $script:TrayVisualState=$state
 $iconPath=Join-Path $script:PackageRoot ('assets\TradeChannel-'+$state.Icon+'.ico')
 if(-not $script:BrandWindowIcons.ContainsKey($state.Icon)){
  $decoder=New-Object Windows.Media.Imaging.IconBitmapDecoder((New-Object Uri($iconPath)),[Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,[Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
  $frame=@($decoder.Frames|Where-Object PixelWidth -eq 32)|Select-Object -First 1
  if(-not $frame){throw 'Missing native window icon frame'};$frame.Freeze();$script:BrandWindowIcons[$state.Icon]=$frame
 }
 $script:Window.Icon=$script:BrandWindowIcons[$state.Icon]
 # Shell grouping and pinned shortcuts may keep the launcher icon. WPF's
 # supported status overlay updates that group without changing its AppID,
 # user pins, shortcuts or the global icon cache. WPF restores it when the
 # taskbar button is recreated or the management window is shown again.
 $script:Window.TaskbarItemInfo.Overlay=BrandTaskbarOverlay $state.Icon
 $script:Window.TaskbarItemInfo.Description='TradeChannel · '+$state.Summary
 $helper=New-Object Windows.Interop.WindowInteropHelper($script:Window)
 if($helper.Handle -ne [IntPtr]::Zero){
  $windowKey=$helper.Handle.ToString()+':'+$state.Icon
  $script:LastBrandWindowKey=$windowKey
 }
 if(-not $script:Tray){return}
 $size=[Windows.Forms.SystemInformation]::SmallIconSize;$key=$state.Icon+':'+$size.Width+'x'+$size.Height
 if(-not $script:BrandTrayIcons.ContainsKey($key)){
  $script:BrandTrayIcons[$key]=New-Object Drawing.Icon((Join-Path $script:PackageRoot ('assets\TradeChannel-'+$state.Icon+'.ico')),$size)
 }
 if($script:LastTrayIconKey -cne $key){
  # Notification mirrors can retain the first icon after NIM_MODIFY. Re-register
  # only on an actual state/size change; never churn the icon on ordinary polls.
  $visible=$script:Tray.Visible
  if($visible){$script:Tray.Visible=$false}
  $script:Tray.Icon=$script:BrandTrayIcons[$key]
  if($visible){$script:Tray.Visible=$true}
  $script:LastTrayIconKey=$key
 }
 $tip='TradeChannel · '+$state.Summary;if($tip.Length -gt 63){$tip=$tip.Substring(0,63)};$script:Tray.Text=$tip
 if($script:TraySummary){$script:TraySummary.Text=$state.Summary}
 # Local presentation evidence only: no connection, route or credential data.
 $reportKey=$script:LastBrandWindowKey+':'+$key
 if($helper.Handle -ne [IntPtr]::Zero -and $script:LastIconReportKey -cne $reportKey){
  $script:IconPresentation=[pscustomobject]@{State=$state.Icon;WindowIconSource=$iconPath;TaskbarIconResource=[TradeChannel.UI.BrandNative]::ReadWindowIconResource($helper.Handle);TaskbarStatusMode='Overlay';TaskbarOverlayState=$state.Icon;TaskbarOverlayColor=@{connected='#22C55E';busy='#F5A524';idle='#98A2B3';fault='#98A2B3'}[$state.Icon];TrayIconSource=$iconPath;TrayIconWidth=$script:Tray.Icon.Width;TrayIconHeight=$script:Tray.Icon.Height;UiPid=$PID;UpdatedAtUtc=[DateTimeOffset]::UtcNow.ToString('o')}
  if(-not $script:Smoke){try{$dir=Join-Path $script:Root 'diagnostics';$null=[IO.Directory]::CreateDirectory($dir);[IO.File]::WriteAllText((Join-Path $dir 'icon-state.json'),($script:IconPresentation|ConvertTo-Json),(New-Object Text.UTF8Encoding($false)))}catch{}}
  $script:LastIconReportKey=$reportKey
 }
}
function ReleaseBrandResources {
 if($script:Tray){$script:Tray.Visible=$false;$script:Tray.Dispose()}
 foreach($icon in $script:BrandTrayIcons.Values){$icon.Dispose()};$script:BrandTrayIcons.Clear()
 if($script:AppTrayIcon){$script:AppTrayIcon.Dispose();$script:AppTrayIcon=$null}
}
$script:Window.Add_SourceInitialized({
 $helper=New-Object Windows.Interop.WindowInteropHelper($script:Window)
 [TradeChannel.UI.BrandNative]::SetWindow($helper.Handle,(Join-Path $script:PackageRoot 'TradeChannel.exe'),$script:Smoke)
 $script:LastBrandWindowKey='';UpdateTrayPresentation
})
