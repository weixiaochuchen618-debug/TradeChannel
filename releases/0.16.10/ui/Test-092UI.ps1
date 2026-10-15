# Only invoked by SelfTest. Every worker action is captured by the UI fixture.
Fixture;$script:Role='linux';$script:Linux.Stage=0;$script:Linux.Host='203.0.113.70';$script:Linux.UseTcp=$true;$script:Linux.TcpPort='2443';$script:Linux.ServerName='www.example.com';$script:Linux.Busy=$false;ShowLinux
AssertUI ($script:Controls.ContainsKey('LinuxTcpPort') -and $script:Controls.ContainsKey('LinuxServerName')) 'TCP deployment fields are visible only when selected';Snapshot '33-linux-tcp-input'
$script:Actions.Clear();StartLinux 'Plan';$request=@(Requests)[0].Request
AssertUI ($request.Transport.Type -eq 'tcp-reality' -and $request.Transport.Port -eq 2443 -and $request.Transport.ServerName -eq 'www.example.com') 'TCP deployment choice reaches the reviewed plan request'
$script:Linux.Busy=$false;$script:Actions.Clear();$script:Linux.Stage=1
$script:Linux.Inspection=[pscustomobject]@{Supported=$false;AlreadyDeployed=$false;DeployedStatus='Applied';OwnedDeployment=$true;OS=@{Id='ubuntu';Version='24.04';Architecture='amd64'};Issues=@(@{Code='ConfigDrift';Message='fixture drift'});Warnings=@()}
ShowLinux;AssertUI (-not $script:Controls.LinuxPlan.IsEnabled -and -not $script:Controls.ContainsKey('LinuxAuthFromInspect')) 'blocked deployed server never shows ready authorization';Snapshot '34-linux-blocked'
$script:Linux.Stage=4;$script:Linux.JobId='status-only';$script:Linux.ApplyJobId=$null;$script:Linux.Data=[pscustomobject]@{Status='Applied';Summary='fixture status';Issues=@();Warnings=@()};ShowLinux
AssertUI (-not $script:Controls.ContainsKey('LinuxCompleteFromStatus') -and $script:Controls.ContainsKey('LinuxAuthFromStatus')) 'Status without original application requires independent authorization'
Fixture;ShowNodes;$script:Actions.Clear();LoadTransportForm $us
AssertUI (@(Requests)[0].Request.Action -eq 'TransportInfo') 'TCP form first loads this node instead of using fixed credentials'
CompleteUI ([pscustomobject]@{Id=$us;Name='美国备用';DefaultServer='198.51.100.20';Settings=$null;Transport=$null;Mode='Udp'})
AssertUI ($script:TransportForm.Server -eq '198.51.100.20' -and -not $script:TransportForm.Uuid -and -not $script:TransportForm.RealityPublicKey) 'new TCP form never copies another server identity';Snapshot '35-tcp-node-form'
$script:TransportForm.Uuid='aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';$script:TransportForm.RealityPublicKey='A'*43;$script:TransportForm.RealityShortId='1234567890abcdef';$script:TransportForm.ServerName='www.example.com'
$script:Actions.Clear();ClickUI 'SaveTransport';AssertUI ((DialogOpen) -and @(Requests).Count -eq 0) 'TCP save is explicitly confirmed before mutation'
ClickDialog 'DialogConfirm';$r=@(Requests)[0].Request
AssertUI ($r.Action -eq 'SetTransportMode' -and $r.Id -eq $us -and $r.TransportParams.Server -eq '198.51.100.20') 'TCP save binds parameters to the selected node only'
Fixture;ShowSettings;AssertUI ($script:Controls.ContainsKey('RepairState') -and $script:Controls.ContainsKey('ExportDiagnostics')) 'maintenance and diagnostic actions are product entries';Snapshot '36-maintenance'
$script:Actions.Clear();ClickUI 'RepairState';AssertUI ((DialogOpen) -and @(Requests).Count -eq 0) 'maintenance warns before disconnecting';ClickDialog 'DialogCancel'
$script:Linux.Stage=0;$script:Linux.Busy=$false;$script:Linux.UseTcp=$false;$script:Role='client';$script:Step=0
