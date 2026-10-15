# Full WPF fixture; requests captured, never dispatched to a real runtime.
Fixture;$script:AutoTCP=$null;$script:Role='client'
$base=$script:Nodes[0].manifestPath
$profiles=@([pscustomobject]@{Id='Udp';Mode='Udp';ManifestPath=$base;PreparationState='Ready';Validation=$null},[pscustomobject]@{Id='Tcp';Mode='Tcp';ManifestPath='C:\Fixture\tcp-profile\manifest.json';PreparationState='Ready';Validation=$null})
$script:Nodes[0]|Add-Member NoteProperty Profiles $profiles -Force
$script:Nodes[0]|Add-Member NoteProperty LineId $hk -Force
$script:Nodes[0]|Add-Member NoteProperty HasTcp $true -Force
ShowNodes
AssertUI ($script:Controls.ContainsKey('Profiles'+$hk.Replace('-','')) -and -not $script:Controls.ContainsKey('Proto'+$hk.Replace('-',''))) 'one line with TCP profile offers profile management instead of another server or TCP deployment'
AssertUI ((LineConnectionsSummary $script:Nodes[0]) -like '*UDP*连通性待验证*TCP*连通性待验证*') 'prepared profiles are not labeled as network verified'
Snapshot '49-one-line-two-profiles'
$script:Actions.Clear();ClickUI ('Profiles'+$hk.Replace('-',''))
AssertUI (@(Requests)[0].Request.Action -eq 'LineRegister' -and -not @(Requests)[0].Request.ContainsKey('SessionAction')) 'profile metadata preparation never requests runtime activation'
$line=[pscustomobject]@{LineId=$hk;Name='香港主线';Endpoint='203.0.113.10:51820';SourceNodeId=$hk;Revision=1;Profiles=$profiles;PreferredProfileId='Udp'}
CompleteUI $line
AssertUI ($script:Controls.ContainsKey('SwitchProfileUdp') -and $script:Controls.ContainsKey('SwitchProfileTcp')) 'same line exposes two prepared connection choices'
Snapshot '50-line-profile-selection'
$script:Actions.Clear();ClickUI 'SwitchProfileTcp'
AssertUI (@(Requests)[0].Request.Action -eq 'ConnectionSwitchPreview' -and @(Requests)[0].Request.ProfileId -eq 'Tcp') 'switch first reads a bounded preview'
CompleteUI ([pscustomobject]@{LineId=$hk;ProfileId='Tcp';PreviewToken='fixture-bound-token';CanSwitch=$true})
AssertUI ((DialogOpen) -and @(Requests).Count -eq 1) 'profile switch does not commit until the concrete confirmation'
ClickDialog 'DialogConfirm'
$r=@(Requests)[-1].Request
AssertUI ($r.Action -eq 'ConnectionSwitchCommit' -and $r.PreviewToken -eq 'fixture-bound-token' -and $r.LineId -eq $hk -and $r.ProfileId -eq 'Tcp') 'profile activation is bound to the approved line and preview'
$script:Pending=$null;$script:Actions.Clear();$script:Overview.NinjaRunning=$true
PreviewLineConnectionSwitch 'Udp'
AssertUI ((DialogOpen) -and @(Requests).Count -eq 0) 'trading software blocks profile switching before any worker request'
CloseDialog;$script:Overview.NinjaRunning=$false
Fixture;$script:AutoTCP=$null;$script:Actions.Clear()
$ctx=[pscustomobject]@{Id=$us;Name='美国备用';DefaultServer='198.51.100.20';ClientPublicKey='A'*43+'=';ServerPublicKey='B'*43+'=';HasSettings=$false;NeedsAuthentication=$true;ServerId='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';CredentialAvailable=$true;Connection=[pscustomobject]@{User='root';Port=22}}
OpenAutomaticTransport $us;CompleteUI $ctx
AssertUI ($script:Controls.ContainsKey('ServerUseSaved') -and $script:Controls.ServerUseSaved.IsChecked) 'TCP preparation defaults to previously authorized encrypted management access'
Snapshot '51-reuse-management-access'
$script:AutoTCP=$null;Fixture;$script:Role='client';$script:Step=0;ShowSetup;ClickUI 'DeployNew'
AssertUI ($script:Controls.DeployTransport.SelectedItem.Tag -eq 'Auto' -and -not $script:Controls.DeploymentAdvanced.IsExpanded) 'new deployment defaults to real standard preparation with technical choices collapsed'
Snapshot '52-standard-deployment'
$script:DeployUI.Run=[pscustomobject]@{RunId='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';Name='标准新服务器';Stage='ReadyInactive';Status='WaitingUser';LastError=$null;Validation=$null;ProtocolPreparation=[pscustomobject]@{Udp=[pscustomobject]@{ServerPreparation='Configured';LocalPreparation='SyntaxValidated';Error=$null};Tcp=[pscustomobject]@{ServerPreparation='Failed';LocalPreparation='Missing';Error=[pscustomobject]@{Message='备用依赖暂不可达'}}};TcpFailure=[pscustomobject]@{Message='备用依赖暂不可达'};CloudRuleList=@([pscustomobject]@{Purpose='SSH';Protocol='tcp';Port=22},[pscustomobject]@{Purpose='UDP';Protocol='udp';Port=51820},[pscustomobject]@{Purpose='TCP';Protocol='tcp';Port=8443})}
$script:DeployUI.SessionAttached=$true;ShowDeploymentRun
AssertUI ($script:Controls.ContainsKey('CopyDeploymentCloudRules') -and $script:Controls.CopyDeploymentCloudRules.Tag -like '*UDP: UDP 51820*TCP: TCP 8443*') 'UDP and final alternate TCP ports are presented as one cloud checklist'
AssertUI ($script:Controls.ContainsKey('DeployProbe') -and $script:Controls.ContainsKey('DeployToNodes')) 'optional TCP failure retains prepared UDP delivery and later verification'
Snapshot '53-udp-delivered-tcp-warning'
$script:AutoTCP=$null;$script:LineProfileUI=$null;$script:DeployUI.Management=$null;$script:DeployUI.PendingManagement=$null;$script:DeployUI.Run=$null;Fixture;$script:Role='client';ShowHome
