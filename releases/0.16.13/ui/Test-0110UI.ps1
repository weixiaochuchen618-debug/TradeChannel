# Shared profile-management regression, executed only inside WPF SelfTest.
Fixture0120 'Disconnected'
$line=NewUI0120Line 'Failed' 'Passed'
$script:Nodes=@($line);ShowNodes
AssertUI ($script:Controls.ContainsKey('Profiles'+$hk.Replace('-','')) -and -not $script:Controls.ContainsKey('Proto'+$hk.Replace('-',''))) 'one logical line with two prepared profiles has no backup-preparation shortcut'
$script:Actions.Clear();ClickUI ('Profiles'+$hk.Replace('-',''))
AssertUI (@(Requests)[0].Request.Action -eq 'LineProfiles' -and -not @(Requests)[0].Request.ContainsKey('SessionAction')) 'profile navigation only reads metadata'
CompleteUI $line
AssertUI ($script:Controls.ContainsKey('PreferProfileUdp') -and $script:Controls.ContainsKey('PreferProfileTcp') -and -not $script:Controls.ContainsKey('SwitchProfileTcp')) 'profile page exposes next-connection preferences without immediate switches'
$script:Actions.Clear();ClickUI 'PreferProfileUdp'
$r=@(Requests)[0].Request
AssertUI ($r.Action -eq 'LinePreference' -and $r.Id -eq $hk -and $r.ProfileId -eq 'Udp' -and $r.ExpectedRevision -eq $line.Revision -and $r.Count -eq 4) 'manual preference sends exact identity and expected revision'
SaveUI0120Default $line Udp -Manual
CompleteUI $line
AssertUI ($script:Controls.LineDefaultLabel.Text -like '*UDP*' -and $line.Recommendation.RecommendedProfileId -eq 'Tcp') 'manual LineStore preference overrides the still-preserved automatic recommendation on screen'
AssertUI (-not (@(Requests)|Where-Object {$_.Request.Action -eq 'ConnectionSwitchCommit' -or $_.Request.ContainsKey('SessionAction')})) 'saving a default never commits or changes the current network'
AssertUI ($script:LastToast -like '*下次默认*当前连接保持*') 'manual selection explains next connection only'
Snapshot '12-manual-default'
Fixture0120 'Connected'
$script:Actions.Clear();PreviewDefaultLineConnection $hk
CompleteUI ([pscustomobject]@{LineId=$hk;ProfileId='Tcp';CanSwitch=$false;Message='网络环境已变化，请重新检查。'})
AssertUI ((DialogOpen) -and $script:Window.FindName('DialogBody').Text -like '*网络环境已变化*' -and @(Requests).Count -eq 1) 'blocked preview reports its reason without a commit'
CloseDialog;$script:Actions.Clear();$script:Overview.NinjaRunning=$true;PreviewDefaultLineConnection $hk
AssertUI ((DialogOpen) -and @(Requests).Count -eq 0) 'running NinjaTrader blocks previews before dispatch'
CloseDialog;$script:Overview.NinjaRunning=$false
Fixture0120 'Connected'
$ctx=[pscustomobject]@{Id=$us;Name='旧线路';DefaultServer='198.51.100.20';ClientPublicKey='A'*43+'=';ServerPublicKey='B'*43+'=';HasSettings=$false;NeedsAuthentication=$true;ServerId='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';CredentialAvailable=$true;Connection=[pscustomobject]@{User='root';Port=22}}
OpenAutomaticTransport $us;CompleteUI $ctx
AssertUI ($script:Controls.ContainsKey('ServerUseSaved') -and $script:Controls.ServerUseSaved.IsChecked) 'optional legacy configuration reuses saved management access'
Fixture0120 'Disconnected';$script:Role='client';$script:Step=0;ShowSetup;ClickUI 'DeployAddLine'
AssertUI ($script:Controls.DeployTransport.SelectedItem.Tag -eq 'Auto' -and -not $script:Controls.DeploymentAdvanced.IsExpanded) 'standard preparation and automatic checks remain default with advanced fields collapsed'
Snapshot '13-standard-deployment'
Fixture0120 'Disconnected';ShowHome
$script:Actions.Clear();ErrorDialog '[TC:NeedsRecovery] 连接事务需要核对。'
AssertUI ((DialogOpen) -and $script:Window.FindName('DialogConfirm').Content -eq '核对当前状态') 'unfinished connection transaction exposes its own recovery action'
ClickDialog 'DialogConfirm'
AssertUI (@(Requests).Count -eq 1 -and @(Requests)[0].Request.Action -eq 'ConnectionTransactionReconcile') 'recovery reconciliation never connects'
CompleteUI ([pscustomobject]@{Resolved=$true})
AssertUI ($script:Window.FindName('DialogNote').Text -like '*没有自动重连*') 'recovery completion does not claim an automatic reconnection'
CloseDialog
