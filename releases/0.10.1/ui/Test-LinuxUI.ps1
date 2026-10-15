# Loaded inside the existing isolated WPF harness; all Worker calls captured.
Fixture;$script:Step=0;$script:Role='client';ShowSetup
AssertUI ($script:Controls.ContainsKey('DeployNew') -and $script:Controls.ContainsKey('SetupWinServer')) 'Linux wizard added without removing Windows server entry'
ClickUI 'AdvancedLinux';AssertUI ((LinuxOnPage) -and @(Requests).Count -eq 1 -and @(Requests)[0].Request.Action -eq 'LinuxRecent') 'opening advanced Linux wizard does not connect, deploy or change local network'
$script:Linux.Host='203.0.113.70';$script:Linux.Port='22';$script:Linux.User='root';$script:Linux.IdentityFile='';ShowLinux;Snapshot '29-linux-connection'
AssertUI ($script:Controls.ContainsKey('LinuxInspect') -and -not $script:Controls.ContainsKey('LinuxPassword')) 'Linux credentials entered in SSH console, no password field in worker UI'
$script:Linux.Host='203.0.113.70;command';$script:Actions.Clear();StartLinux 'Inspect'
AssertUI ((DialogOpen) -and @(Requests).Count -eq 0) 'invalid remote target rejected before dispatch';CloseDialog
$script:Linux.Host='203.0.113.70';StartLinux 'Inspect';$r=@(Requests)[0].Request
AssertUI ($r.Action -eq 'LinuxStart' -and $r.Operation -eq 'Inspect' -and $r.Connection.Host -eq '203.0.113.70' -and -not $r.ContainsKey('Password')) 'inspect submits public connection only'
CompleteUI ([pscustomobject]@{JobId='fixture-inspect';Status='Running';Operation='Inspect'})
AssertUI ($script:Linux.Busy -and $script:Linux.JobId -eq 'fixture-inspect') 'independent SSH job is polled, not mistaken for complete'
CompleteLinuxPoll ([pscustomobject]@{JobId='fixture-inspect';Status='Completed';Operation='Inspect';Data=[pscustomobject]@{Supported=$true;Summary='Ubuntu 24.04 · 环境就绪';Issues=@();Warnings=@()}})
AssertUI ($script:Linux.Stage -eq 1 -and -not $script:Linux.Busy -and $script:Controls.LinuxPlan.IsEnabled) 'inspection allows plan preparation only';Snapshot '30-linux-inspected'
$script:Actions.Clear();ClickUI 'LinuxPlan';$r=@(Requests)[0].Request
AssertUI ($r.Operation -eq 'Plan' -and $r.PublicEndpoint -eq '203.0.113.70:51820' -and $r.TunnelSubnet -eq '10.78.0.0/24') 'plan request includes reviewed endpoint and subnet, no local activation'
CompleteUI ([pscustomobject]@{JobId='fixture-plan';Status='Running';Operation='Plan'})
$plan=[pscustomobject]@{PlanId='safe-plan';Name='香港 Linux';PublicEndpoint='203.0.113.70:51820';ServerAddress='10.78.0.1/24';ClientAddress='10.78.0.2/32';Steps=@('安装发行版 WireGuard 组件','添加本机设备授权','启用限定网段的转发与 NAT','配置服务开机加载');Warnings=@('云安全组仍需放行 UDP 51820')}
CompleteLinuxPoll ([pscustomobject]@{JobId='fixture-plan';Status='Completed';Operation='Plan';Data=$plan})
AssertUI ($script:Linux.Stage -eq 2 -and -not $script:Controls.LinuxApply.IsEnabled) 'server plan shown, cloud firewall acknowledgement still required';Snapshot '31-linux-plan'
$script:Linux.CloudConfirmed=$true;ShowLinux;$script:Actions.Clear();ClickUI 'LinuxApply'
AssertUI ((DialogOpen) -and @(Requests).Count -eq 0 -and $script:Window.FindName('DialogBody').Text -like '*203.0.113.70:51820*') 'apply confirmation names reviewed target before sending mutation'
ClickDialog 'DialogCancel';AssertUI (@(Requests).Count -eq 0) 'cancel server deployment is inert'
ClickUI 'LinuxApply';ClickDialog 'DialogConfirm';$r=@(Requests)[0].Request
AssertUI ($r.Operation -eq 'Apply' -and $r.ParentJobId -eq 'fixture-plan' -and -not $r.ContainsKey('Connection')) 'apply binds to prior plan and cannot switch its target'
CompleteUI ([pscustomobject]@{JobId='fixture-apply';Status='Running';Operation='Apply'})
CompleteLinuxPoll ([pscustomobject]@{JobId='fixture-apply';Status='Completed';Operation='Apply';Data=[pscustomobject]@{Status='Applied';ClientResponse=@{}}})
AssertUI ($script:Linux.Stage -eq 3 -and $script:Controls.ContainsKey('LinuxComplete')) 'applied server still requires local completion, not a live channel switch';Snapshot '32-linux-applied'
$script:Actions.Clear();ClickUI 'LinuxComplete';AssertUI (@(Requests)[0].Request.Action -eq 'LinuxComplete') 'completion only assembles client identity'
CompleteUI ([pscustomobject]@{ConfigPath='C:\Fixture\linux-client.conf';NodeName='香港 Linux'})
AssertUI (@(Requests)[-1].Request.Action -eq 'InspectClient') 'completion requests inspection before import'
CompleteUI ([pscustomobject]@{NinjaTraderPaths=@('C:\Fixture\NinjaTrader.exe');DirectDnsIPv4=@('192.168.100.1');RegisteredProviders=@()})
$autoImport=@(Requests)[-1].Request
AssertUI ($autoImport.Action -eq 'ImportNode' -and $autoImport.Path -eq 'C:\Fixture\linux-client.conf' -and $autoImport.Name -eq '香港 Linux') 'asynchronous import retains config path and name'
CompleteUI ([pscustomobject]@{Id=$us;Name='香港 Linux'})
AssertUI ((DialogOpen) -and $script:CompletedLinuxNodeId -eq $us -and $script:Window.FindName('DialogBody').Text -like '*行情*') 'completed import retains switch identity and accurate validation boundary'
ClickDialog 'DialogCancel'
foreach($request in @(Requests)){AssertUI ($request.Request.Action -notin @('Session','ActivateNode','UpgradeActive')) 'Linux completion never replaces active HK'}
$script:Linux.JobId=$null;$script:Linux.Busy=$false;$script:Linux.Stage=0;$script:Linux.Error='';$script:Role='client';$script:Step=0
