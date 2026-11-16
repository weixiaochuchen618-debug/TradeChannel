#requires -Version 5.1
#requires -PSEdition Desktop
[CmdletBinding()]param([string]$ReportPath)
$ErrorActionPreference='Stop'
$package=Split-Path $PSScriptRoot -Parent
$pathModule=Import-Module (Join-Path $package 'ProbePath.psm1') -PassThru -DisableNameChecking
$flow=Import-Module (Join-Path $package 'DeploymentFlow.psm1') -PassThru -DisableNameChecking
Import-Module (Join-Path $package 'DeploymentDependencies.psm1') -DisableNameChecking
$checks=New-Object 'Collections.Generic.List[string]';$passed=$false;$failure='';$listener=$null;$received=0
function Check {param([bool]$Ok,[string]$Label)if(-not $Ok){throw $Label};$checks.Add($Label)}
function CopyValue {param($Value)$Value|ConvertTo-Json -Depth 30|ConvertFrom-Json}
try{
 $listener=New-Object Net.Sockets.UdpClient([Net.IPEndPoint]::new([Net.IPAddress]::Loopback,0));$listener.Client.ReceiveTimeout=1000;$port=$listener.Client.LocalEndPoint.Port
 $context=Get-TCProbeNetworkContext
 # Read the real layout once, then isolate this loopback sender from unrelated
 # adapter/DHCP changes while collaborators run their own read-only tests.
 # Socket binding and packet transmission remain real Windows operations.
 & $pathModule {param($snapshot)$script:IngressNetworkSnapshot=$snapshot;function script:Read-TCProbeNetworkState {$script:IngressNetworkSnapshot}} $context
 $loop=@($context.Interfaces|Where-Object {$_.Type -eq 'Loopback' -and @($_.Addresses|Where-Object {$_.Address -ceq '127.0.0.1'}).Count})[0]
 $candidate=[pscustomobject]@{endpoints=@([pscustomobject]@{tag='hk';type='wireguard';peers=@([pscustomobject]@{address='127.0.0.1';port=$port})})}
 $binding=& $pathModule {param($c,$i,$snapshot)New-TCProbeBinding (Get-TCProbeOuter $c) $i $snapshot '127.0.0.1' '127.0.0.1'} $candidate $loop $context
 & $flow {
  param($Binding)
  $script:IngressFixtureBinding=$Binding;$script:IngressDispatches=New-Object 'Collections.Generic.List[object]'
  function script:Get-TCDeploymentPreparationConsent {param($Root,$RunId)[pscustomobject]@{State='Active'}}
  function script:Get-TCServer {param($Root,$Id)[pscustomobject]@{Connection=@{Host='127.0.0.1'}}}
  function script:Get-TCDeploymentIngressBinding {param($Candidate,$InterfaceIndex)[pscustomobject]@{Status='Ready';Binding=$script:IngressFixtureBinding}}
  function script:Start-TCDeploymentRemote {param($Root,$Run,$Operation,$Purpose,$InputData)
   if($Operation -cne 'status' -or $Purpose -cne 'ServerExit'){throw 'Only a read-only status capture may be dispatched'}
   $script:IngressDispatches.Add([pscustomobject]@{Operation=$Operation;Purpose=$Purpose;Input=$InputData})
   $Run.PendingOperationId=[guid]::NewGuid().ToString('D');$Run.PendingPurpose=$Purpose;$Run.Status='Running'
  }
 } $binding
 $run=[pscustomobject]@{RunId=[guid]::NewGuid().ToString('D');ServerRecordId=[guid]::NewGuid().ToString('D');SessionRef=[pscustomobject]@{RunId='';InstanceId=[guid]::NewGuid().ToString('D')};VpnPort=$port;ProbeInterfaceIndex=0;ClientResponse=@{PublicEndpoint=('127.0.0.1:'+$port)};IngressProbe=$null;Status='Idle';PendingOperationId=$null;PendingPurpose=$null;NetworkChanged=$false}
 $run.SessionRef.RunId=$run.RunId
 & $flow {param($r)Start-TCDeploymentServerExit 'C:\FixtureOnly-NoFiles' $r} $run
 $dispatches=@(& $flow {$script:IngressDispatches.ToArray()})
 Check ($dispatches.Count -eq 1 -and $dispatches[0].Input.NetworkProbe -and $dispatches[0].Input.CaptureSeconds -eq 8 -and -not $dispatches[0].Input.ContainsKey('ProbeRelayPort')) 'Main server-exit step requests the existing bounded Linux header capture without relay or firewall changes'
 $sender=$run.IngressProbe.Sender
 Check ($sender.Status -ceq 'Sent' -and $sender.NetworkStable -and $sender.SentCount -ge 1 -and $sender.SentCount -le 24) ('Actual Windows bound UDP sender finishes within its packet budget: '+$sender.Status+'/'+$sender.Code+', sent='+$sender.SentCount+', stable='+$sender.NetworkStable)
 $samples=@()
 for($i=0;$i -lt $sender.SentCount;$i++){
  $peer=[Net.IPEndPoint]::new([Net.IPAddress]::Any,0);$bytes=$listener.Receive([ref]$peer);$received++
  Check ($peer.Address.ToString() -ceq '127.0.0.1' -and $peer.Port -eq $sender.LocalPort -and $bytes.Length -eq $sender.PayloadLength -and $bytes[0] -eq 84) ('Owned loopback datagram '+$i+' matches source port and non-WireGuard framing')
  $samples+=,[pscustomobject]@{Protocol='UDP';Direction='Incoming';SourceAddress='127.0.0.1';SourcePort=$peer.Port;DestinationAddress='127.0.0.1';DestinationPort=$port;PayloadLength=$bytes.Length}
  [Array]::Clear($bytes,0,$bytes.Length)
 }
 $data=[pscustomobject]@{Status='Applied';NetworkProbe=@{Capture=[pscustomobject]@{Status='Completed';StartedAtUtc=[DateTimeOffset]::Parse($sender.StartedAtUtc).AddMilliseconds(-100).ToString('o');ElapsedMilliseconds=8000;OmittedPackets=0;Samples=$samples}}}
 $poll=[pscustomobject]@{OperationId=$run.PendingOperationId;RunId=$run.RunId;InstanceId=$run.SessionRef.InstanceId;Operation='status';Status='Completed'}
 $base=CopyValue $run
 & $flow {param($r,$d,$p)Complete-TCDeploymentIngressProbe $r $d $p} $run $data $poll
 Check ($run.IngressProbe.Status -ceq 'Observed' -and $run.IngressProbe.ObservedPackets -eq $received -and -not $run.IngressProbe.CloudFirewallInspected -and $run.IngressProbe.ClientAttribution -ceq 'HeaderPatternOnly') 'Observed ingress is a bounded header observation, not a firewall verdict or authenticated connection claim'
 $empty=CopyValue $data;$empty.NetworkProbe.Capture.Samples=@();$copy=CopyValue $base
 & $flow {param($r,$d,$p)Complete-TCDeploymentIngressProbe $r $d $p} $copy $empty $poll
 Check ($copy.IngressProbe.Status -ceq 'NotReceived' -and $copy.IngressProbe.Code -ceq 'ServerUdpNotReceived' -and -not $copy.IngressProbe.CloudFirewallInspected) 'No matching packet reports only NotReceived with no cloud firewall conclusion'
 $mutations=@{
  WrongOperation={param($r,$d,$p)$p.OperationId=[guid]::NewGuid().ToString('D')}
  WrongOperationKind={param($r,$d,$p)$p.Operation='server_info'}
  OtherPollRun={param($r,$d,$p)$p.RunId=[guid]::NewGuid().ToString('D')}
  OtherPollSession={param($r,$d,$p)$p.InstanceId=[guid]::NewGuid().ToString('D')}
  WrongSession={param($r,$d,$p)$r.SessionRef.InstanceId=[guid]::NewGuid().ToString('D')}
  WrongRun={param($r,$d,$p)$r.RunId=[guid]::NewGuid().ToString('D')}
  CaptureFailed={param($r,$d,$p)$d.NetworkProbe.Capture.Status='Failed'}
  CaptureLostPackets={param($r,$d,$p)$d.NetworkProbe.Capture.OmittedPackets=1}
  CaptureNotOverlapping={param($r,$d,$p)$d.NetworkProbe.Capture.StartedAtUtc=[DateTimeOffset]::UtcNow.AddHours(1).ToString('o')}
  SenderFailed={param($r,$d,$p)$r.IngressProbe.Sender.Status='Inconclusive'}
  NetworkChanged={param($r,$d,$p)$r.IngressProbe.Sender.NetworkStable=$false}
 }
 foreach($name in @($mutations.Keys|Sort-Object)){
  $r=CopyValue $base;$d=CopyValue $data;$p=CopyValue $poll;& $mutations[$name] $r $d $p
  & $flow {param($v,$report,$observation)Complete-TCDeploymentIngressProbe $v $report $observation} $r $d $p
  Check ($r.IngressProbe.Status -ceq 'Inconclusive') ($name+' cannot become a conclusive ingress result')
 }
 $wrongPacket=CopyValue $data;$wrongPacket.NetworkProbe.Capture.Samples[0].DestinationPort=$port+1;$wrongPacket.NetworkProbe.Capture.Samples=@($wrongPacket.NetworkProbe.Capture.Samples[0]);$copy=CopyValue $base
 & $flow {param($r,$d,$p)Complete-TCDeploymentIngressProbe $r $d $p} $copy $wrongPacket $poll
 Check ($copy.IngressProbe.Status -ceq 'NotReceived') 'Another destination port cannot supply ingress evidence'
 $invalid=CopyValue $binding;$invalid.RemoteAddress='192.0.2.1'
 $result=Invoke-TCDeploymentUdpIngressSend -Binding $invalid -DurationMilliseconds 250
 Check ($result.Status -ceq 'NotSent' -and $result.SentCount -eq 0) 'Loopback binding cannot be reused to send packets to a public target'
 Check (-not $run.NetworkChanged -and $run.PSObject.Properties.Name -notcontains 'RecommendedProfileId') 'Ingress diagnostics do not activate or recommend a line'
 $passed=$true
}catch{$failure=$_.Exception.Message;throw}
finally{
 if($listener){$listener.Dispose()}
 $result=[pscustomobject]@{Passed=$passed;Count=$checks.Count;Checks=$checks.ToArray();Failure=$failure;SenderStatus=$sender;LoopbackDatagramsReceived=$received;RealVpsOperations=0;NetworkChanges=0;CaptureFixtureOnly=$true;SenderContext='Frozen native read-only snapshot';ActualWindowsUdpSender=$true;PowerShell=$PSVersionTable.PSVersion.ToString()}
 if($ReportPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($result|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($true))}
 $result|Select-Object Passed,Count,Failure,LoopbackDatagramsReceived|ConvertTo-Json
}
