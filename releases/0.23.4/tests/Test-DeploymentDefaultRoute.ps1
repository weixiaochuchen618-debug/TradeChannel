#requires -Version 5.1
#requires -PSEdition Desktop
[CmdletBinding()]param([string]$ReportPath)
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'ProbePath.psm1') -Force -PassThru -DisableNameChecking
$checks=New-Object 'Collections.Generic.List[string]';$passed=$false;$failure=''
function Check {param([bool]$Ok,[string]$Label)if(-not $Ok){throw $Label};$checks.Add($Label)}
function ResetFixture {
 & $module {
  $script:DefaultFixture=[pscustomobject]@{Interfaces=@();Routes=@()}
  foreach($index in @(7,8)){
   $script:DefaultFixture.Interfaces+=,[pscustomobject]@{Index=$index;Id=('nic-'+$index);Name=('Physical '+$index);Status='Up';Type='Ethernet';Hardware=$true;Metric=$(if($index -eq 7){100}else{10});Addresses=@([pscustomobject]@{Address=('192.0.2.'+$index);Family='InterNetwork';PrefixLength=24;State='Preferred'});Gateways=@('192.0.2.1');DnsServers=@('192.0.2.53')}
   $script:DefaultFixture.Routes+=,[pscustomobject]@{InterfaceIndex=$index;DestinationPrefix='0.0.0.0/0';NextHop='192.0.2.1';RouteMetric=$(if($index -eq 7){5}else{20});AddressFamily='IPv4'}
  }
  function script:Read-TCProbeNetworkState {$script:DefaultFixture}
 }
}
$candidate=[pscustomobject]@{endpoints=@([pscustomobject]@{type='wireguard';tag='hk';peers=@([pscustomobject]@{address='198.51.100.10';port=51820})})}
try{
 ResetFixture
 $plan=Get-TCProbeBindingPlan -Candidate $candidate
 Check ($plan.Status -ceq 'Ready' -and $plan.SelectedInterfaceIndex -eq 8 -and $plan.SelectionMode -ceq 'AutomaticDefaultRoute') 'Two physical adapters automatically choose the unique lowest route plus interface metric'
 Check ($plan.Binding.DefaultRoute.EffectiveMetric -eq 30 -and $plan.Binding.DialFields.inet4_bind_address -ceq '192.0.2.8') 'Automatic choice binds the selected physical IPv4 source'
 $manual=Get-TCProbeBindingPlan -Candidate $candidate -InterfaceIndex 7
 Check ($manual.Status -ceq 'Ready' -and $manual.SelectedInterfaceIndex -eq 7 -and $manual.SelectionMode -ceq 'ExplicitInterface') 'Explicit supported adapter selection remains available'
 & $module {$script:DefaultFixture.Routes[0].RouteMetric=0;$script:DefaultFixture.Interfaces[0].Metric=30}
 Check ((Get-TCProbeBindingPlan -Candidate $candidate).Reason -ceq 'AmbiguousPhysicalInterface') 'Equal total metrics require a user choice'
 Check ((Get-TCProbeNetworkContext -Binding $plan.Binding).Reason -ceq 'DefaultRouteSelectionChanged') 'A new default route tie invalidates the old automatic choice'
 ResetFixture
 & $module {$script:DefaultFixture.Interfaces[0].Metric=0}
 Check ((Get-TCProbeNetworkContext -Binding $plan.Binding).Reason -ceq 'DefaultRouteSelectionChanged') 'Another adapter becoming best invalidates the previous choice'
 Check ((Get-TCProbeNetworkContext -Binding $manual.Binding).Status -ceq 'Available') 'An explicit still-valid binding is not silently switched by default route rank'
 ResetFixture
 & $module {$script:DefaultFixture.Routes[1].RouteMetric=21}
 Check ((Get-TCProbeNetworkContext -Binding $plan.Binding).Reason -ceq 'DefaultRouteSelectionChanged') 'Automatic default route metric drift requires a fresh selection'
 ResetFixture
 & $module {
  $script:DefaultFixture.Interfaces+=,[pscustomobject]@{Index=30;Id='tun-30';Name='TradeChannel';Status='Up';Type='Ethernet';Hardware=$false;Metric=0;Addresses=@([pscustomobject]@{Address='172.30.250.1';Family='InterNetwork';PrefixLength=30;State='Preferred'});Gateways=@('0.0.0.0');DnsServers=@('172.30.250.2')}
  foreach($prefix in @('0.0.0.0/1','128.0.0.0/1')){$script:DefaultFixture.Routes+=,[pscustomobject]@{InterfaceIndex=30;DestinationPrefix=$prefix;NextHop='0.0.0.0';RouteMetric=0;AddressFamily='IPv4'}}
 }
 $withTunnel=Get-TCProbeBindingPlan -Candidate $candidate
 Check ($withTunnel.Status -ceq 'Ready' -and $withTunnel.SelectedInterfaceIndex -eq 8) 'A TradeChannel full-tunnel pair of /1 routes leaves physical default route selection available'
 Check ((Get-TCProbeNetworkContext -Binding $plan.Binding).Status -ceq 'Available') 'Expected TradeChannel TUN layout preserves the original physical binding'
 & $module {$script:DefaultFixture.Routes+=,[pscustomobject]@{InterfaceIndex=30;DestinationPrefix='0.0.0.0/0';NextHop='0.0.0.0';RouteMetric=0;AddressFamily='IPv4'}}
 Check ((Get-TCProbeBindingPlan -Candidate $candidate).Reason -ceq 'UnsupportedDefaultInterface') 'A best virtual default route is rejected rather than bypassed automatically'
 ResetFixture
 & $module {$script:DefaultFixture.Routes=@();$script:DefaultFixture.Interfaces=@($script:DefaultFixture.Interfaces[0])}
 Check ((Get-TCProbeBindingPlan -Candidate $candidate).Status -ceq 'Unsupported') 'A lone adapter without a usable default route is not guessed'
 ResetFixture
 & $module {$script:DefaultFixture.Interfaces[1].Status='Down'}
 Check ((Get-TCProbeBindingPlan -Candidate $candidate).SelectedInterfaceIndex -eq 7) 'A down adapter is not an automatic default candidate'
 ResetFixture
 & $module {$script:DefaultFixture.Interfaces[1].Metric=-1}
 Check ((Get-TCProbeBindingPlan -Candidate $candidate).Reason -ceq 'DefaultRouteMetricUnavailable') 'Missing interface metric does not silently favor another route'
 ResetFixture
 & $module {$script:DefaultFixture.Routes[1].NextHop='0.0.0.0'}
 Check ((Get-TCProbeBindingPlan -Candidate $candidate).Reason -ceq 'InvalidDefaultGateway') 'Unsupported physical default gateway remains explicit'
 ResetFixture
 & $module {$script:DefaultFixture.Routes+=,$script:DefaultFixture.Routes[1]}
 Check ((Get-TCProbeBindingPlan -Candidate $candidate).SelectedInterfaceIndex -eq 8) 'An identical repeated route row does not invent ambiguity'
 ResetFixture
 & $module {$script:DefaultFixture.Routes+=,[pscustomobject]@{InterfaceIndex=7;DestinationPrefix='::/0';NextHop='fe80::1';RouteMetric=0;AddressFamily='IPv6'}}
 Check ((Get-TCProbeBindingPlan -Candidate $candidate).SelectedInterfaceIndex -eq 8) 'IPv6 default rows do not decide the IPv4 probe binding'
 ResetFixture
 & $module {$script:DefaultFixture.Interfaces[1].Addresses+=,[pscustomobject]@{Address='192.0.2.88';Family='InterNetwork';PrefixLength=24;State='Preferred'}}
 Check ((Get-TCProbeBindingPlan -Candidate $candidate).Reason -ceq 'NoSupportedPhysicalInterface') 'An ambiguous source address on the winning adapter is not silently bypassed'
 ResetFixture
 $selection=& $module {Get-TCProbeDefaultRouteSelection (Get-TCProbeNetworkContext)}
 Check ($selection.Status -ceq 'Ready' -and $selection.InterfaceIndex -eq 8 -and $selection.Route.InterfaceId -ceq 'nic-8' -and $selection.Fingerprint -cmatch '^[A-F0-9]{64}$') 'Quality measurement resolver can reuse the private read-only selection contract'
 $passed=$true
}catch{$failure=$_.Exception.Message;throw}
finally{
 $result=[pscustomobject]@{Passed=$passed;Count=$checks.Count;Checks=$checks.ToArray();Failure=$failure;NetworkChanges=0;NetworkPacketsSent=0;PowerShell=$PSVersionTable.PSVersion.ToString()}
 if($ReportPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($result|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($true))}
 $result|Select-Object Passed,Count,Failure|ConvertTo-Json
}
