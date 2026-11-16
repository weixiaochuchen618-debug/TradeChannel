#requires -Version 5.1
#requires -PSEdition Desktop
# Production exports, real root/runtime/hash/ownership checks and cleanup journal.
# Inventory readers return isolated fixtures. Native TCP is guarded to loopback.
[CmdletBinding()]param()
$ErrorActionPreference='Stop';Set-StrictMode -Version 2
$package=Split-Path $PSScriptRoot -Parent
$qi=Import-Module (Join-Path $package 'QualityIntegration.psm1') -Force -PassThru -DisableNameChecking
$sq=Import-Module (Join-Path $package 'StandbyQuality.psm1') -PassThru -DisableNameChecking
$paths=& $qi {$script:QIPaths}
Import-Module (Join-Path $package 'DeploymentStore.psm1') -DisableNameChecking
Import-Module (Join-Path $package 'ServerRegistry.psm1') -DisableNameChecking
$cleanup=Import-Module (Join-Path $package 'OperationHistory.psm1') -PassThru -DisableNameChecking
$tempBase=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$work=Join-Path $tempBase ('TC-QualityIntegration-'+[guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($work)
$script:Checks=0;$active='11111111-1111-1111-1111-111111111111';$standby='22222222-2222-2222-2222-222222222222'
$data=@{Root='';Cards=@();Profiles=@{};Network=$null;NetworkReads=0;CardReads=0;ProfileReads=0;Measurements=0;Native=$false;Loopback=$false;LoopId='';LoopIndex=0;Action=$null;ThrowNetwork=$false;MutateDuringResolve=$false;ConfigPath='';CleanupResult=$null;CleanupError='';MeasuredResult=$null}
function Check {param([bool]$Ok,[string]$Label)if(-not $Ok){throw ('QualityIntegration check failed: '+$Label)};$script:Checks++}
function Put {param([string]$Path,$Value)
 $full=[IO.Path]::GetFullPath($Path);if(-not $full.StartsWith($work+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Fixture path escape.'}
 # Production readers reject world-readable data files, so fixtures use the same protected writer.
 $null=New-TCDDirectory (Split-Path $full -Parent);Write-TCDJson $full $Value
}
function Network {
 [pscustomobject]@{Interfaces=@(
  [pscustomobject]@{Index=7;Id='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';Name='Fixture Ethernet';Status='Up';Type='Ethernet';Hardware=$true;Metric=10;Addresses=@([pscustomobject]@{Address='192.0.2.20';Family='InterNetwork';PrefixLength=24;State='Preferred'});Gateways=@('192.0.2.1');DnsServers=@('1.1.1.1')},
  [pscustomobject]@{Index=17;Id='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';Name='TradeChannel';Status='Up';Type='Tunnel';Hardware=$false;Metric=1;Addresses=@([pscustomobject]@{Address='172.30.250.1';Family='InterNetwork';PrefixLength=30;State='Preferred'});Gateways=@();DnsServers=@()}
 );Routes=@(
  [pscustomobject]@{InterfaceIndex=7;DestinationPrefix='0.0.0.0/0';NextHop='192.0.2.1';RouteMetric=10;AddressFamily='IPv4'},
  [pscustomobject]@{InterfaceIndex=17;DestinationPrefix='0.0.0.0/1';NextHop='0.0.0.0';RouteMetric=1;AddressFamily='IPv4'},
  [pscustomobject]@{InterfaceIndex=17;DestinationPrefix='128.0.0.0/1';NextHop='0.0.0.0';RouteMetric=1;AddressFamily='IPv4'}
 )}
}
function Fixture {param([string]$Name,[string]$HostAddress='203.0.113.10',[int]$Port=443)
 $root=Join-Path $work $Name;$null=[IO.Directory]::CreateDirectory($root)
 $config=Join-Path $root ('Product\lines\'+$standby+'\profiles\r1\candidate.json');$manifest=Join-Path (Split-Path $config -Parent) 'manifest.json'
 $cfg=[pscustomobject]@{endpoints=@(@{type='wireguard';tag='hk';private_key='fixture-private-secret';detour='tc-transport';peers=@(@{address='203.0.113.10';port=51820;public_key='fixture-public'})});outbounds=@(@{type='vless';tag='tc-transport';server=$HostAddress;server_port=$Port;uuid='fixture-transport-secret';tls=@{enabled=$true;reality=@{public_key='fixture-reality-public'}}})}
 Put $config $cfg;$hash=(Get-FileHash -LiteralPath $config).Hash
 $mf=[pscustomobject]@{TCLineId=$standby;TCProfileId='Tcp';CandidatePath=$config;CandidateSHA256=$hash;PrivateNote='fixture-manifest-secret'};Put $manifest $mf
 $profile=[pscustomobject]@{Id='Tcp';Mode='Tcp';Revision=1;PreparationState='SyntaxValidated';SourceNodeId=$standby;ManifestPath=$manifest;ManifestSHA256=(Get-FileHash -LiteralPath $manifest).Hash;CandidateSHA256=$hash}
 $card=[pscustomobject]@{LineId=$standby;Profiles=@($profile);AliasIds=@();ServerConnectionBlock=''}
 $activeConfig=Join-Path $root 'active\candidate.json';$activeManifest=Join-Path $root 'active\manifest.json'
 Put $activeConfig @{experimental=@{clash_api=@{external_controller='127.0.0.1:1';secret='fixture-controller-secret'}}}
 $activeHash=(Get-FileHash -LiteralPath $activeConfig).Hash;Put $activeManifest @{CandidatePath=$activeConfig;CandidateSHA256=$activeHash}
 $process=Get-Process -Id $PID;try{$born=$process.StartTime.ToUniversalTime().ToString('o')}finally{$process.Dispose()}
 $runtime=[pscustomobject]@{State='Running';OwnershipKnown=$true;LineId=$active;SessionId='quality-integration';EnginePid=$PID;SupervisorPid=$PID;EngineStartedAt=$born;SupervisorStartedAt=$born;ManifestPath=$activeManifest;ConfigPath=$activeConfig}
 Put (Join-Path $root 'runtime.json') $runtime;Put (Join-Path $root 'deployment.json') @{LineId=$active;ProfileId='Udp';ManifestPath=$activeManifest}
 Put (Join-Path $root 'Product\index.json') @{schemaVersion=1;nodes=@(@{id=$active;name='active';manifestPath=$activeManifest},@{id=$standby;name='standby';manifestPath=$manifest})}
 $overview=[pscustomobject]@{Running=$true;StateKey='Connected';SessionId=$runtime.SessionId;ActiveLineId=$active;ActiveProfileId='Udp';ProfileBindingVerified=$true;Exit='hk';ConfigHash=$activeHash;EnginePid=$PID;ConnectedSince=$born;ManifestPath=$activeManifest;Mode='global';ObservedAt=[DateTimeOffset]::UtcNow.ToString('o')}
 $data.Root=$root;$data.Cards=@($card);$data.Profiles=@{};$data.Profiles[$standby]=$profile;$data.Network=Network;$data.NetworkReads=0;$data.CardReads=0;$data.ProfileReads=0;$data.Measurements=0;$data.Native=$false;$data.Loopback=$false;$data.Action=$null;$data.ThrowNetwork=$false;$data.MutateDuringResolve=$false;$data.ConfigPath=$config
 [pscustomobject]@{Root=$root;Overview=$overview;Profile=$profile;Card=$card;ConfigPath=$config;ManifestPath=$manifest;Config=$cfg;Manifest=$mf;Runtime=$runtime}
}
function Refresh {param($Fixture)$Fixture.Overview.ObservedAt=[DateTimeOffset]::UtcNow.ToString('o')}
function Targets {param($Fixture)Refresh $Fixture;return ,@(Get-TCStandbyTargets -Root $Fixture.Root -Overview $Fixture.Overview)}
try{
 foreach($file in @((Join-Path $package 'QualityIntegration.psm1'),(Join-Path $package 'LocalDeploymentCleanup.ps1'),$PSCommandPath)){
  $bytes=[IO.File]::ReadAllBytes($file);$tokens=$null;$errors=$null;$null=[Management.Automation.Language.Parser]::ParseFile($file,[ref]$tokens,[ref]$errors)
  Check ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191 -and @($errors).Count -eq 0) ('BOM and PS5.1 parser: '+[IO.Path]::GetFileName($file))
 }
 & $paths {param($d)$script:QIIntegrationData=$d;function script:Read-TCProbeNetworkState {$script:QIIntegrationData.NetworkReads++;if($script:QIIntegrationData.ThrowNetwork){throw 'fixture-inventory-secret'};$script:QIIntegrationData.Network}} $data
 & $qi {
  param($d)
  $script:QITestData=$d;$script:QIOriginalUnderlay=(Get-Command QICreateUnderlay).ScriptBlock
  function script:Get-TCQualityCards {param([string]$Root)
   if($Root -ine $script:QITestData.Root){throw 'Unexpected root.'};$script:QITestData.CardReads++
   $index=[IO.File]::ReadAllText((Join-Path $Root 'Product\index.json'))|ConvertFrom-Json
   @($script:QITestData.Cards|Where-Object {$_.LineId -in @($index.nodes|ForEach-Object id)})
  }
  function script:Get-TCQualityProfile {param([string]$Root,[string]$LineId)
   if($Root -ine $script:QITestData.Root){throw 'Unexpected root.'};$script:QITestData.ProfileReads++;$script:QITestData.Profiles[$LineId]
  }
  function script:QICreateUnderlay {param($Outer,$Network)
   if($script:QITestData.Loopback){
    if($Outer.Address -cne '127.0.0.1'){throw 'Loopback fixture refuses external endpoint.'}
    return [pscustomobject]@{InterfaceIndex=$script:QITestData.LoopIndex;LocalAddress='127.0.0.1';InterfaceId=$script:QITestData.LoopId;NetworkFingerprint=(QIDigest $Network.Network.SnapshotFingerprint)}
   }
   $result=& $script:QIOriginalUnderlay $Outer $Network
   if($script:QITestData.MutateDuringResolve){[IO.File]::AppendAllText($script:QITestData.ConfigPath,' ')}
   return $result
  }
 } $data
 & $sq {
  param($d)
  $script:QIIntegrationData=$d;$script:QIOriginalMeasure=(Get-Command SQRunMeasurement).ScriptBlock
  function script:SQRunMeasurement {param($Candidate,$Measure,$MeasureData,$BudgetMilliseconds)
   $script:QIIntegrationData.Measurements++
   if($script:QIIntegrationData.Action){& $script:QIIntegrationData.Action}
   if($script:QIIntegrationData.Native){
    if($Candidate.Binding.Host -cne '127.0.0.1'){throw 'Native test refuses all non-loopback endpoints.'}
    return (& $script:QIOriginalMeasure $Candidate $Measure $MeasureData $BudgetMilliseconds)
   }
   SQResult $Candidate 'Measured' 45
  }
 } $data
 $f=Fixture trusted;$targets=Targets $f
 Check ($targets.Count -eq 1 -and $targets[0].NodeId -eq $standby -and $targets[0].Host -eq '203.0.113.10' -and $targets[0].Underlay.InterfaceIndex -eq 7) 'production discovery selects prepared TCP on physical interface despite active TUN split routes'
 Check ($data.ProfileReads -eq 1 -and $data.CardReads -eq 1 -and $data.Measurements -eq 0) 'discovery re-reads selected profile with explicit root and performs no measurement'
 Check (-not (ConvertTo-Json -InputObject $targets -Depth 12).Contains('fixture-')) 'target output contains no private key, UUID, manifest note or controller secret'
 Refresh $f;$view=Invoke-TCStandbyObservation -Root $f.Root -Overview $f.Overview
 Check ($view.Sampled -and $null -ne $view.Recommendation -and $view.ManualOnly -and -not $view.NetworkChanged -and -not $view.AutoSwitched) 'production observation returns only manual recommendation after both verified reads'
 Check (-not (ConvertTo-Json -InputObject $view -Depth 20).Contains('fixture-')) 'production summary and cached target binding do not leak source secrets'
 $stored=[IO.File]::ReadAllText((Join-Path $f.Root 'Product\standby-quality.json'));Check (-not $stored.Contains('fixture-')) 'persisted standby evidence excludes source secrets'
 $bad=$false;try{$null=Get-TCStandbyTargets -Root '.' -Overview $f.Overview}catch{$bad=$_.Exception.Message -like '*[[]TC:QualityRoot]*'};Check $bad 'relative implicit root is rejected'
 $f=Fixture crossroot;$f.Overview.ManifestPath=Join-Path $work 'outside\manifest.json';$none=Targets $f
 Check ($none.Count -eq 0 -and $data.NetworkReads -eq 0) 'overview from another root cannot authorize discovery'
 $f=Fixture session;$f.Runtime.SessionId='another-session';Put (Join-Path $f.Root 'runtime.json') $f.Runtime;$none=Targets $f
 Check ($none.Count -eq 0 -and $data.NetworkReads -eq 0) 'runtime session mismatch prevents inventory and sampling'
 $f=Fixture stale;$f.Overview.ObservedAt=[DateTimeOffset]::UtcNow.AddSeconds(-16).ToString('o');$none=@(Get-TCStandbyTargets -Root $f.Root -Overview $f.Overview)
 Check ($none.Count -eq 0 -and $data.NetworkReads -eq 0) 'stale overview never authorizes candidate discovery'
 $f=Fixture owner;$f.Manifest.TCLineId=$active;Put $f.ManifestPath $f.Manifest;$f.Profile.ManifestSHA256=(Get-FileHash -LiteralPath $f.ManifestPath).Hash
 Check ((Targets $f).Count -eq 0) 'matching file hash cannot lend another line ownership to this TCP profile'
 $f=Fixture path;$outside=Join-Path $work 'outside\secret.json';Put $outside @{Secret='fixture-outside-secret'};$f.Profile.ManifestPath=$outside;$f.Profile.ManifestSHA256=(Get-FileHash -LiteralPath $outside).Hash
 Check ((Targets $f).Count -eq 0) 'profile cannot read outside explicit root even with matching digest'
 $f=Fixture sibling;$sibling=Join-Path $f.Root 'other-profile\candidate.json';Put $sibling $f.Config;$f.Manifest.CandidatePath=$sibling;$f.Manifest.CandidateSHA256=(Get-FileHash -LiteralPath $sibling).Hash;Put $f.ManifestPath $f.Manifest;$f.Profile.CandidateSHA256=$f.Manifest.CandidateSHA256;$f.Profile.ManifestSHA256=(Get-FileHash -LiteralPath $f.ManifestPath).Hash
 Check ((Targets $f).Count -eq 0) 'candidate file must remain in its immutable profile directory'
 $f=Fixture replaced;[IO.File]::AppendAllText($f.ConfigPath,' ')
 Check ((Targets $f).Count -eq 0) 'changed candidate bytes cannot borrow recorded hash'
 $f=Fixture readrace;$data.MutateDuringResolve=$true
 Check ((Targets $f).Count -eq 0) 'hash is rechecked after underlay construction to reject replacement during discovery'
 $f=Fixture domain 'standby.example.invalid'
 Check ((Targets $f).Count -eq 0 -and $data.Measurements -eq 0) 'domain-only endpoint is not independently recommended or resolved'
 $f=Fixture blocked;$f.Card.ServerConnectionBlock='IdentityChanged'
 Check ((Targets $f).Count -eq 0 -and $data.ProfileReads -eq 0) 'server identity block excludes standby candidate'
 $f=Fixture duplicate;$data.Cards=@($f.Card,$f.Card)
 Check ((Targets $f).Count -eq 0) 'duplicate line ownership is excluded'
 $f=Fixture alias;$f.Card.AliasIds=@($active)
 Check ((Targets $f).Count -eq 0) 'active line alias is not tested as an independent standby'
 $f=Fixture virtualdefault;$data.Network.Routes+=,[pscustomobject]@{InterfaceIndex=17;DestinationPrefix='0.0.0.0/0';NextHop='0.0.0.0';RouteMetric=0;AddressFamily='IPv4'}
 Check ((Targets $f).Count -eq 0) 'virtual default route cannot masquerade as the physical selection'
 $f=Fixture guard;$first=(Targets $f)[0].Underlay.NetworkFingerprint
 $data.Network.Interfaces+=,[pscustomobject]@{Index=27;Id='cccccccc-cccc-cccc-cccc-cccccccccccc';Name='Other VPN';Status='Up';Type='Tunnel';Hardware=$false;Metric=100;Addresses=@([pscustomobject]@{Address='10.9.0.1';Family='InterNetwork';PrefixLength=24;State='Preferred'});Gateways=@();DnsServers=@()}
 $second=(Targets $f)[0].Underlay.NetworkFingerprint
 Check ($first -cne $second) 'unknown virtual-network changes enter durable candidate fingerprint'
 $f=Fixture unavailable;$data.ThrowNetwork=$true;Refresh $f;$view=Invoke-TCStandbyObservation -Root $f.Root -Overview $f.Overview
 Check ($null -eq $view.Recommendation -and $data.Measurements -eq 0 -and -not (ConvertTo-Json -InputObject $view -Depth 16).Contains('fixture-')) 'inventory failure is sanitized and never falls back to an old successful target'

 $f=Fixture routechange;$d=$data
 $data.Action={ $d.Network.Routes[0].NextHop='192.0.2.2' }.GetNewClosure();Refresh $f;$view=Invoke-TCStandbyObservation -Root $f.Root -Overview $f.Overview
 Check ($data.Measurements -eq 1 -and $null -eq $view.Recommendation -and $view.Reason -eq 'BindingChanged') 'physical route change during measurement suppresses committed success'
 Check (@((Get-Content -LiteralPath (Join-Path $f.Root 'Product\standby-quality.json') -Raw|ConvertFrom-Json).Entries).Count -eq 0) 'post-read mismatch also removes persisted stale target evidence'
 $f=Fixture activeswitch;$runtimePath=Join-Path $f.Root 'runtime.json';$runtime=$f.Runtime
 $data.Action={ $runtime.SessionId='replaced-during-measurement';[IO.File]::WriteAllText($runtimePath,(ConvertTo-Json -InputObject $runtime -Depth 8),(New-Object Text.UTF8Encoding($true))) }.GetNewClosure()
 Refresh $f;$view=Invoke-TCStandbyObservation -Root $f.Root -Overview $f.Overview
 Check ($null -eq $view.Recommendation -and $view.Reason -eq 'BindingChanged') 'active session replacement is caught by the post-measurement root check'

 $listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0);$listener.Start()
 try{
  $f=Fixture loopback '127.0.0.1' ([Net.IPEndPoint]$listener.LocalEndpoint).Port
  $loop=@([Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()|Where-Object {$_.NetworkInterfaceType -eq [Net.NetworkInformation.NetworkInterfaceType]::Loopback})[0]
  $data.LoopId=([guid]$loop.Id).ToString();$data.LoopIndex=$loop.GetIPProperties().GetIPv4Properties().Index;$data.Loopback=$true;$data.Native=$true
  Refresh $f;$view=Invoke-TCStandbyObservation -Root $f.Root -Overview $f.Overview
  Check ($view.Sampled -and $null -ne $view.Recommendation -and $view.Recommendation.PathScope -eq 'LoopbackOnly' -and $listener.Pending()) 'production observation performs actual source/interface-bound loopback TCP'
  $accepted=$listener.AcceptTcpClient();try{Check ($accepted.Available -eq 0) 'integration TCP sends no authentication or application payload'}finally{$accepted.Close()}
 }finally{$listener.Stop()}

 $f=Fixture latecleanup;$root=$f.Root;$id=$standby;$operationModule=Join-Path $package 'OperationHistory.psm1';$d=$data
 # Real cleanup reads the same reservation cache and commits through its journal
 # while the sampler mutex is held and the shared store lock has been released.
 $data.Action={
  try{
   Import-Module $operationModule -DisableNameChecking
   $preview=New-TCLocalDeploymentCleanupPreview -Root $root -Ids @('Line:'+$id)
   if(-not $preview.PreviewToken){throw ('Fixture cleanup preview blocked: '+(($preview.Blocked|ForEach-Object Code)-join ','))}
   $d.CleanupResult=Remove-TCLocalDeploymentData -Root $root -PreviewToken $preview.PreviewToken
  }catch{$d.CleanupError=$_.Exception.Message+' / '+$_.ScriptStackTrace+' / id='+$id+' / nodes='+((([IO.File]::ReadAllText((Join-Path $root 'Product\index.json'))|ConvertFrom-Json).nodes|ForEach-Object id)-join ',');throw}
 }.GetNewClosure()
 Refresh $f;$view=Invoke-TCStandbyObservation -Root $f.Root -Overview $f.Overview
 $cache=Get-Content -LiteralPath (Join-Path $f.Root 'Product\standby-quality.json') -Raw|ConvertFrom-Json
 Check ($null -ne $data.CleanupResult) ('cleanup callback completes: '+$data.CleanupError+'; view='+$view.Reason+'; attempts='+$data.Measurements)
 Check ($data.CleanupResult.DataDeleted -and -not (Test-Path -LiteralPath (Split-Path $f.ManifestPath -Parent))) 'real journal removes the standby profile during an outstanding measurement'
 Check ($null -eq $view.Recommendation -and $view.Reason -eq 'BindingChanged' -and @($cache.Entries|Where-Object {$_.Binding.NodeId -eq $standby}).Count -eq 0) 'late sample cannot resurrect deleted target or recommendation after journal replacement'
 Check ((Get-Content -LiteralPath (Join-Path $f.Root 'runtime.json') -Raw|ConvertFrom-Json).SessionId -eq 'quality-integration') 'deleting standby leaves active fixture session intact'
 [pscustomobject]@{Passed=$true;Checks=$script:Checks;PowerShellVersion=$PSVersionTable.PSVersion.ToString();NativeLoopbackMeasurements=1;ProductionPhysicalMeasurements=0;ProductionRootAccesses=0;RemoteActors=0;NetworkChanges=0}
}catch{Write-Output $_.ScriptStackTrace;throw}finally{
 Remove-Module $qi,$sq,$cleanup -ErrorAction SilentlyContinue
 $full=[IO.Path]::GetFullPath($work).TrimEnd('\')
 if(-not $full.StartsWith($tempBase+'\',[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -cnotmatch '^TC-QualityIntegration-[a-f0-9]{32}$'){throw 'Unsafe fixture cleanup.'}
 if([IO.Directory]::Exists($full)){Remove-Item -LiteralPath $full -Recurse -Force}
}
