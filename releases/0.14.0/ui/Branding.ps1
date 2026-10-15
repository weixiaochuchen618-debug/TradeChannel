Import-Module (Join-Path $script:PackageRoot 'UiState.psm1') -DisableNameChecking
if(-not ('TradeChannel.UI.BrandNative' -as [type])){Add-Type -Path (Join-Path $script:PackageRoot 'BrandNative.cs')}
# This affects only the management window's Windows identity.
[TradeChannel.UI.BrandNative]::InitializeProcess()
$script:Window.FindName('BrandMark').Source=[Windows.Media.Imaging.BitmapFrame]::Create((New-Object Uri((Join-Path $script:PackageRoot 'assets\TradeChannel-small.png'))))
$script:BrandImages=@{};$script:BrandTrayIcons=@{}
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
 if(-not $script:Tray){return}
 $size=[Windows.Forms.SystemInformation]::SmallIconSize;$key=$state.Icon+':'+$size.Width+'x'+$size.Height
 if(-not $script:BrandTrayIcons.ContainsKey($key)){
  $script:BrandTrayIcons[$key]=New-Object Drawing.Icon((Join-Path $script:PackageRoot ('assets\TradeChannel-'+$state.Icon+'.ico')),$size)
 }
 $script:Tray.Icon=$script:BrandTrayIcons[$key]
 $tip='TradeChannel · '+$state.Summary;if($tip.Length -gt 63){$tip=$tip.Substring(0,63)};$script:Tray.Text=$tip
 if($script:TraySummary){$script:TraySummary.Text=$state.Summary}
}
function ReleaseBrandResources {
 if($script:Tray){$script:Tray.Visible=$false;$script:Tray.Dispose()}
 foreach($icon in $script:BrandTrayIcons.Values){$icon.Dispose()};$script:BrandTrayIcons.Clear()
 if($script:AppTrayIcon){$script:AppTrayIcon.Dispose();$script:AppTrayIcon=$null}
}
$decoder=New-Object Windows.Media.Imaging.IconBitmapDecoder((New-Object Uri((Join-Path $script:PackageRoot 'assets\TradeChannel.ico'))),[Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,[Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
$frame=@($decoder.Frames|Where-Object PixelWidth -eq 32)|Select-Object -First 1
if($frame){$frame.Freeze();$script:Window.Icon=$frame}
$script:Window.Add_SourceInitialized({
 $helper=New-Object Windows.Interop.WindowInteropHelper($script:Window)
 [TradeChannel.UI.BrandNative]::SetWindow($helper.Handle,(Join-Path $script:PackageRoot 'TradeChannel.exe'))
})
