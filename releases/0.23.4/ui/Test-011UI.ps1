# Loaded only by the isolated WPF self-test; no production worker or network.
function FlushLayout011 {
 $script:Window.UpdateLayout()
 $null=$script:Window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ContextIdle)
 $script:Window.UpdateLayout()
}
Fixture;$script:Role='client';$script:Step=0
$script:Window.Width=1000;$script:Window.Height=680
ShowHome;FlushLayout011
$scroll=$script:Window.FindName('Scroll');$scroll.ScrollToEnd();FlushLayout011
$beforeOffset=$scroll.VerticalOffset
AssertUI ($beforeOffset -gt 30) 'compact overview reproduces a scrollable bottom'
$primaryBefore=$script:Controls.Primary
$updated=$script:Overview|ConvertTo-Json -Depth 14|ConvertFrom-Json
$updated.Connections=999
RefreshOverview -Silent;CompleteUI $updated;FlushLayout011
AssertUI ($scroll.VerticalOffset -ge $beforeOffset-2) 'periodic connection-count refresh keeps the reading position'
AssertUI ([Object]::ReferenceEquals($primaryBefore,$script:Controls.Primary) -and $script:Controls.StatusMeta.Text -like '*999*') 'live metrics update without replacing page controls'
$updated=$script:Overview|ConvertTo-Json -Depth 14|ConvertFrom-Json
$updated.GuardState='Unknown'
$scroll.ScrollToEnd();FlushLayout011;$beforeOffset=$scroll.VerticalOffset
RefreshOverview -Silent;CompleteUI $updated;FlushLayout011
AssertUI ($scroll.VerticalOffset -ge [Math]::Min($beforeOffset,$scroll.ScrollableHeight)-2) 'structural same-page refresh preserves bottom anchor'
$compactWidth=$script:HostPanel.ActualWidth
foreach($layout in $script:ResponsiveLayouts){if($layout.Kind -eq 'Lane'){AssertUI ([Windows.Controls.Grid]::GetRow($layout.Grid.Children[2]) -eq 1) 'compact lane choices move below their description'}}
$script:Window.Width=1500;$script:Window.Height=900;FlushLayout011
AssertUI ($script:HostPanel.ActualWidth -gt $compactWidth+350) 'content expands with a wider window'
foreach($layout in $script:ResponsiveLayouts){if($layout.Kind -eq 'Lane'){AssertUI ([Windows.Controls.Grid]::GetRow($layout.Grid.Children[2]) -eq 0) 'wide lane choices return to their inline column'}}
Snapshot '43-responsive-wide'
$script:Window.Width=1000;$script:Window.Height=680;FlushLayout011
Snapshot '44-responsive-compact'
ShowSettings;FlushLayout011
AssertUI ($scroll.VerticalOffset -lt 2) 'navigation to another page starts at top'
ShowHome;FlushLayout011;$scroll.ScrollToEnd();FlushLayout011
ShowHome;ShowSettings;FlushLayout011
AssertUI ($scroll.VerticalOffset -lt 2) 'stale scroll-restore callbacks cannot move a newly opened page'

# Real window preference writes are confined to the existing disposable fixture.
$script:Actions.Clear();$null=[IO.Directory]::CreateDirectory($script:Root);$script:WindowPrefs=Set-TCWindowPreferences -Root $script:Root -CloseBehavior Tray
[IO.File]::WriteAllText((Join-Path $script:Root 'ui-preferences.json'),'{"Mode":"fixture-network-intent"}',[Text.Encoding]::UTF8)
$intentHash=(Get-FileHash -LiteralPath (Join-Path $script:Root 'ui-preferences.json')).Hash
ShowSettings;FlushLayout011
$box=$script:Controls.CloseBehaviorChoice
$null=$box.Focus();$box.IsDropDownOpen=$true;FlushLayout011
AssertUI ($box.IsKeyboardFocusWithin -and $box.IsDropDownOpen -and $box.Style -eq $script:ProviderChoiceStyle) 'window close selector uses the shared keyboard-accessible theme'
$box.IsDropDownOpen=$false
$box.SelectedItem=@($box.Items|Where-Object Tag -eq 'ExitInterface')[0];FlushLayout011
AssertUI ((Get-TCWindowPreferences -Root $script:Root).CloseBehavior -eq 'ExitInterface') 'close behavior persists independently from connection intent'
AssertUI ((Get-FileHash -LiteralPath (Join-Path $script:Root 'ui-preferences.json')).Hash -ceq $intentHash) 'window preference writes do not change network preferences'
AssertUI ($script:Window.FindName('WindowClose').ToolTip -like '*退出界面*') 'close button describes its configured action'
Snapshot '45-window-settings'
$box.SelectedItem=@($box.Items|Where-Object Tag -eq 'Tray')[0];FlushLayout011
$cachedPanel=$script:HostPanel.Children[0];$cachedView=$script:Page;$cachedGeneration=$script:ScrollRestoreState.Generation
$script:Window.WindowState='Maximized';FlushLayout011
$event=New-Object ComponentModel.CancelEventArgs
HandleWindowClosing $event
AssertUI ($event.Cancel -and -not $script:Window.IsVisible) 'configured close-to-tray hides the same window'
ShowExistingConsole;FlushLayout011
AssertUI ($script:Window.IsVisible -and $script:Window.WindowState -eq 'Maximized') 'tray restore retains the maximized window state'
AssertUI ([Object]::ReferenceEquals($cachedPanel,$script:HostPanel.Children[0]) -and $script:Page -eq $cachedView -and $script:ScrollRestoreState.Generation -eq $cachedGeneration) 'waking the console reuses its controls and page'
AssertUI (@(Requests).Count -eq 0) 'hide and wake never enqueue connection or reload requests'
$script:Window.WindowState='Normal';$script:Window.Width=1180;$script:Window.Height=800;FlushLayout011
$script:WindowPrefs.CloseBehavior='ExitInterface';$script:Job=[pscustomobject]@{Silent=$false}
$event=New-Object ComponentModel.CancelEventArgs;HandleWindowClosing $event
AssertUI ($event.Cancel -and -not $script:Closing -and $script:LastCloseMessage -like '*任务*') 'active task keeps the console alive in tray when exit is configured'
$script:Job=$null;ShowExistingConsole;FlushLayout011
$event=New-Object ComponentModel.CancelEventArgs;HandleWindowClosing $event
AssertUI (-not $event.Cancel -and $script:Closing -and @(Requests).Count -eq 0) 'idle interface exit accepts close without disconnecting'
$script:Closing=$false;$script:WindowPrefs=Set-TCWindowPreferences -Root $script:Root -CloseBehavior Tray
Fixture;$script:Window.Width=1180;$script:Window.Height=800;ShowHome;FlushLayout011
