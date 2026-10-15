# Isolated UI requests only; no SSH, configuration enablement or network switch.
Fixture;$script:AutoTCP=$null;$script:Role='client';ShowNodes;$script:Actions.Clear()
OpenToggleTransport $us 'Tcp'
AssertUI (@(Requests).Count -eq 1 -and @(Requests)[0].Request.Action -eq 'AutoTransportContext') 'beginner TCP entry reads bound node context instead of opening credentials form'
$ctx=[pscustomobject]@{Id=$us;Name='美国备用';DefaultServer='198.51.100.20';ClientPublicKey='A'*43+'=';ServerPublicKey='B'*43+'=';Active=$false;HasSettings=$false;NeedsAuthentication=$true;ServerId=$null;Connection=[pscustomobject]@{Host='198.51.100.20';User='root';Port=22}}
CompleteUI $ctx
AssertUI ($script:Controls.ContainsKey('AutomaticTcpLogin') -and $script:Controls.ServerPassword -is [Windows.Controls.PasswordBox]) 'automatic TCP requires only protected management authentication'
AssertUI (-not $script:Controls.ContainsKey('TransportUuid') -and -not $script:Controls.ContainsKey('TransportRealityPublicKey')) 'beginner automatic page has no UUID or Reality key fields'
Snapshot '46-automatic-tcp-login'
$script:Actions.Clear();$script:DeployUI.PendingManagement=$null;InitializeServerUI
$script:DeployUI.Management.ServerId='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';$script:DeployUI.Management.Authenticated=$true
$script:DeployUI.PendingManagement=@{Purpose='ServerInfo';Operation='server_info';OperationId='fixture';ServerId=$script:DeployUI.Management.ServerId}
CompleteServerOperation ([pscustomobject]@{Node=[pscustomobject]@{ServerPublicKey=$ctx.ServerPublicKey};OwnershipState='Applied'})
$request=@(Requests)[0].Request
AssertUI ($request.Action -eq 'ServerOperation' -and $request.Operation -eq 'transport_info' -and $request.Input.ClientPublicKey -ceq $ctx.ClientPublicKey) 'automatic retrieval binds parameters to original client and server public identities'
$script:Actions.Clear();CompleteServerOperation ([pscustomobject]@{Status='NotConfigured'})
$request=@(Requests)[0].Request
AssertUI ($request.Operation -eq 'transport_plan' -and $request.Input.Transport.Type -eq 'tcp-reality' -and -not $request.ContainsKey('SessionAction')) 'missing TCP service prepares a remote increment plan without local activation'
$script:Actions.Clear();CompleteServerOperation ([pscustomobject]@{PlanId='cccccccc-cccc-cccc-cccc-cccccccccccc';ChangeDigest='fixture-plan-digest';Transport=[pscustomobject]@{Port=443;ServerName='www.bing.com'}})
AssertUI ((DialogOpen) -and @(Requests).Count -eq 0) 'incremental TCP deployment waits for concrete change confirmation'
ClickDialog 'DialogConfirm';$request=@(Requests)[0].Request
AssertUI ($request.Operation -eq 'transport_apply' -and $request.Input.ApprovedChangeDigest -eq 'fixture-plan-digest') 'TCP apply is bound to the approved incremental plan'
$script:Actions.Clear();CompleteServerOperation ([pscustomobject]@{Status='Applied'})
AssertUI (@(Requests)[0].Request.Operation -eq 'transport_info') 'deployment completion automatically retrieves the original device parameters'
$envelope=[pscustomobject]@{Kind='TradeChannel.TransportInfo';Status='Available';ServerPublicKey=$ctx.ServerPublicKey;ClientPublicKey=$ctx.ClientPublicKey;ClientAddress='10.78.0.4/32';Transport=[pscustomobject]@{Type='tcp-reality';Server='198.51.100.20';Port=443}}
$script:Actions.Clear();CompleteServerOperation $envelope
$request=@(Requests)[0].Request
AssertUI ($request.Action -eq 'AutoTransportPrepare' -and $request.Id -eq $us -and -not $request.ContainsKey('SessionAction')) 'automatic parameters materialize a candidate without stopping the active connection'
CompleteUI ([pscustomobject]@{Id='eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee';ProbeRequiresInactiveIdentity=$true;Activated=$false;CurrentNetworkChanged=$false})
AssertUI ($script:Controls.ContainsKey('AutomaticTcpToNodes') -and -not $script:Controls.ContainsKey('DeployActivate')) 'automatic preparation ends ready and inactive with identity-probe boundary'
Snapshot '47-automatic-tcp-ready'
$script:AutoTCP=$null;$script:DeployUI.PendingManagement=$null;$script:DeployUI.Management=$null
Fixture;$script:Actions.Clear();OfferConnectionRecovery '[TC:LineForwardingUnverified] 外网出口未通过' $us
AssertUI ((DialogOpen) -and @(Requests).Count -eq 0) 'switch failure offers next-step diagnostics without silent fallback'
ClickDialog 'DialogConfirm'
AssertUI (@(Requests)[0].Request.Action -eq 'LineRecovery') 'switch failure proceeds to read-only layered diagnostics'
CompleteUI ([pscustomobject]@{Code='ActiveForwardingUnverified';Summary='测试转发未通过';Checks=@();CanPrepareTcp=$true})
AssertUI ($script:Controls.ContainsKey('RecoveryPrepareTcp')) 'failed forwarding offers automatic TCP preparation'
Snapshot '48-line-recovery'
$script:RecoveryResult=[pscustomobject]@{Code='ActiveForwardingPassed';Summary='当前线路已通过';Checks=@();CanPrepareTcp=$false}
ShowConnectionRecoveryPage
AssertUI (-not $script:Controls.ContainsKey('RecoveryPrepareTcp')) 'working UDP path is not presented as requiring TCP'
$script:Actions.Clear();Fixture;$script:AutoTCP=$null;$script:Role='client';ShowHome
