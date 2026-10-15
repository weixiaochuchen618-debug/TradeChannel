# Loaded only by the full isolated WPF harness, all worker requests captured.
Fixture;$script:Step=0;$script:Role='client';ShowSetup
ClickUI 'DeployNew'
AssertUI ($script:Role -eq 'deployment' -and @(Requests)[0].Request.Action -eq 'DeploymentDiscover') 'product entry discovers state without SSH or local activation'
AssertUI ($script:Controls.DeployPassword -is [Windows.Controls.PasswordBox]) 'credentials use secure GUI input'
$script:Controls.DeployConnectionText.Text='203.0.113.70';$script:Controls.DeployName.Text='测试新服务器';$script:Controls.DeployPassword.Password='fixture-no-real-credential'
$script:Actions.Clear();StartProductDeployment
$r=@(Requests)[0].Request
AssertUI ($r.Action -eq 'DeploymentCreate' -and $r.Intent -eq 'New' -and -not $r.ContainsKey('Password') -and -not $r.ContainsKey('Credential')) 'new run request contains no GUI password'
$fake=[pscustomobject]@{RunId='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';ServerRecordId='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';Name='测试新服务器';Stage='PlanReady';Status='WaitingUser';SessionRef=$null;LastError=$null;Plan=[pscustomobject]@{PublicEndpoint='203.0.113.70:51820'};Transport='Udp';VpnPort=51820;TcpPort=443;Review=[pscustomobject]@{Title='部署并授权';Details='只处理服务器和候选';ChangeDigest='fixture-approved-digest'};Validation=$null}
$script:DeployUI.Run=$fake;$script:DeployUI.SessionAttached=$true;$script:DeployUI.ManagementMode=$false;$script:Actions.Clear();ShowProductDeployment;Snapshot '39-product-plan'
ClickUI 'DeployApprove'
AssertUI ((DialogOpen) -and @(Requests).Count -eq 0) 'remote change waits for specific plan confirmation'
ClickDialog 'DialogConfirm';$r=@(Requests)[0].Request
AssertUI ($r.Action -eq 'DeploymentProceed' -and $r.Command -eq 'Approve' -and $r.ApprovedChangeDigest -eq 'fixture-approved-digest') 'plan approval bound to exact run and digest'
AssertUI (-not $r.ContainsKey('SessionAction') -and -not $r.ContainsKey('Exit')) 'remote deployment never routes local traffic'
$fake.Stage='ReadyInactive';$fake.Status='WaitingUser';$fake.Validation=[pscustomobject]@{Status='Inconclusive';TransportPath='ExistingSystemRoute'}
$fake|Add-Member NoteProperty DeploymentCompleteness 'Complete'
$fake|Add-Member NoteProperty MissingProtocols @()
$fake|Add-Member NoteProperty ProtocolPreparation ([pscustomobject]@{Udp=[pscustomobject]@{ServerPreparation='Configured';LocalPreparation='SyntaxValidated'};Tcp=[pscustomobject]@{ServerPreparation='Configured';LocalPreparation='SyntaxValidated'}})
$script:Actions.Clear();ShowProductDeployment;Snapshot '40-product-ready-inactive'
AssertUI ($script:Controls.ContainsKey('DeployProbe') -and $script:Controls.ContainsKey('DeployLater') -and -not $script:Controls.ContainsKey('DeployConnectRecommended')) 'unverified candidate offers recheck or later without activation'
ClickUI 'DeployProbe';$r=@(Requests)[0].Request
AssertUI ($r.Action -eq 'DeploymentProceed' -and $r.Command -eq 'Probe') 'independent probe requested without Session activation'
Fixture;$script:LastObservedState=$null;$script:LastFaultNotice=$null;$script:TrayNotifications=@();$script:UserDisconnectIntent=$false
$good=[pscustomobject]@{StateKey='Connected';Running=$true;GuardState='Protected';Error=$null;RuntimeEvidence=[pscustomobject]@{State='Running'}}
$bad=[pscustomobject]@{StateKey='Fault';Running=$false;GuardState='Protected';Error='引擎退出';RuntimeEvidence=[pscustomobject]@{State='StoppedWithError'}}
ObserveTrayState $good;ObserveTrayState $bad;ObserveTrayState $bad
AssertUI ($script:TrayNotifications.Count -eq 1 -and $script:TrayNotifications[0].Text -match '保护仍生效') 'confirmed engine fault notifies once with verified protection'
ObserveTrayState $good;$script:UserDisconnectIntent=$true;$before=$script:TrayNotifications.Count
ObserveTrayState ([pscustomobject]@{StateKey='Disconnected';Running=$false;GuardState='Protected';Error=$null;RuntimeEvidence=[pscustomobject]@{State='Stopped'}})
AssertUI ($script:TrayNotifications.Count -eq $before) 'user requested disconnect does not generate fault notification'
$script:UserDisconnectIntent=$false;ObserveTrayState $good
ObserveTrayState ([pscustomobject]@{StateKey='Fault';Running=$false;GuardState='Unknown';Error='读取失败';RuntimeEvidence=[pscustomobject]@{State='Unknown'}})
AssertUI ($script:TrayNotifications[-1].Title -eq '连接状态需要处理' -and $script:TrayNotifications[-1].Text -notmatch '保护仍生效') 'unverified read failure never claims interruption or protection'
Fixture;$script:Actions.Clear();ShowConfigurationRollback $hk
AssertUI (@(Requests)[0].Request.Action -eq 'ConfigurationRollbackPreview') 'configuration rollback starts with readonly preview'
$script:RollbackUI=[pscustomobject]@{Message='在线需要维护';Available=$true;CanRestore=$false;RequiresMaintenance=$true;PreviewToken='fixture-hash-token'}
$script:RollbackNodeId=$hk;ShowConfigurationRollbackResult;Snapshot '41-rollback-maintenance'
AssertUI ($script:Controls.ContainsKey('RollbackPrepare') -and -not $script:Controls.ContainsKey('RollbackApply')) 'active rollback only prepares candidate and never restores live pointer'
$script:RollbackUI=[pscustomobject]@{Message='未连接可还原';Available=$true;CanRestore=$true;RequiresMaintenance=$false;PreviewToken='fixture-hash-token'}
$script:Actions.Clear();ShowConfigurationRollbackResult;ClickUI 'RollbackApply';AssertUI ((DialogOpen) -and @(Requests).Count -eq 0) 'inactive restore requires explicit confirmed preview'
ClickDialog 'DialogConfirm';$r=@(Requests)[0].Request
AssertUI ($r.Action -eq 'ConfigurationRollbackApply' -and $r.PreviewToken -eq 'fixture-hash-token' -and -not $r.ContainsKey('SessionAction')) 'restore request carries token and omits network action'
Fixture;ShowSettings
AssertUI ($script:Controls.ContainsKey('InstallationInfoCheck')) 'current version/path and bounded installation discovery have UI entry'
$script:DeployUI.Run=$null;$script:DeployUI.SessionRef=$null;$script:DeployUI.ManagementMode=$false;$script:Role='client';$script:Step=0
