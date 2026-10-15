#requires -Version 5.1
[CmdletBinding()]param([string]$ReportPath)
$ErrorActionPreference='Stop';$env:PSModulePath=Join-Path $PSHOME 'Modules'
$package=Split-Path $PSScriptRoot -Parent
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('TC-ConnectionDiagnostics-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($fixture)
$checks=New-Object 'Collections.Generic.List[string]'
function Check {param([bool]$Ok,[string]$Name)if(-not $Ok){throw $Name};$checks.Add($Name)}
function Reject {param([scriptblock]$Action,[string]$Code,[string]$Name)
 $caught=$false;try{& $Action|Out-Null}catch{$caught=$_.Exception.Message -like ('[[]TC:'+$Code+']*');Check (-not $_.Exception.Message.Contains('SECRET_MUST_NOT_LEAK')) ($Name+' redacts configuration')}
 Check $caught $Name
}
. (Join-Path $package 'runtime/TradeChannel.Diagnostics.ps1')
$bridge=Import-Module (Join-Path $package 'RuntimeBridge.psm1') -PassThru -Force -DisableNameChecking
$transactions=Import-Module (Join-Path $package 'ConnectionTransactions.psm1') -PassThru -Force -DisableNameChecking
try{
 function Get-NetAdapter {param([switch]$IncludeHidden,$ErrorAction) [pscustomobject]@{Name='以太网'}}
 & $bridge {
  param($Root)
  $script:Root=$Root
  function script:Get-NetAdapter {param([switch]$IncludeHidden,$ErrorAction) [pscustomobject]@{Name='以太网'}}
  function script:Invoke-TCCommand {throw 'Live runtime mutation forbidden'}
  function script:Invoke-TCController {throw 'Live controller access forbidden'}
 } $fixture
 foreach($protocol in @('Udp','Tcp')){foreach($bom in @($false,$true)){
  $config=[pscustomobject]@{
   inbounds=@(@{type='mixed';tag='egress-probe';listen='127.0.0.1';listen_port=12000;users=@(@{username='tradechannel-probe';password='SECRET_MUST_NOT_LEAK'},@{username='tradechannel-daily';password='DAILY_TEST_ONLY'})})
   outbounds=@(@{type='selector';tag='trade-exit';outbounds=@('hk')})
   endpoints=@(@{type='wireguard';tag='hk';peers=@(@{public_key='public-fixture-only'});bind_interface='以太网'})
   route=@{rules=@(@{inbound=@('egress-probe');auth_user=@('tradechannel-probe');outbound='trade-exit'})}
   dns=@{servers=@(@{tag='dns-direct';bind_interface='以太网'})}
  }
  if($protocol -eq 'Tcp'){$config.endpoints[0].Remove('bind_interface');$config.endpoints[0].detour='tc-transport';$config.outbounds+=@{type='vless';tag='tc-transport';bind_interface='以太网';tls=@{enabled=$true;reality=@{enabled=$true}}}}
  $path=Join-Path $fixture ($protocol+'-'+$bom+'.json');[IO.File]::WriteAllText($path,($config|ConvertTo-Json -Depth 12),(New-Object Text.UTF8Encoding($bom)))
  $manifest=[pscustomobject]@{CandidatePath=$path;CandidateSHA256=(Get-FileHash -LiteralPath $path).Hash;ServerPublicKey='public-fixture-only';ServerEndpoint='192.0.2.10:51820'}
  $manifestPath=Join-Path $fixture 'manifest.json';[IO.File]::WriteAllText($manifestPath,($manifest|ConvertTo-Json),(New-Object Text.UTF8Encoding($bom)))
  $deploymentPath=Join-Path $fixture 'deployment.json';[IO.File]::WriteAllText($deploymentPath,(@{ManifestPath=$manifestPath}|ConvertTo-Json),(New-Object Text.UTF8Encoding($bom)))
  $d=Read-TCExitDiagnosticJson $deploymentPath;$m=Read-TCExitDiagnosticJson $d.ManifestPath
  $inputContext=Get-TCExitDiagnosticInput -Manifest $m -CheckInterfaces
  Check ($inputContext.Config.dns.servers[0].bind_interface -ceq '以太网' -and $inputContext.User.username -ceq 'tradechannel-probe') ($protocol+' BOM='+$bom+' preserves Chinese interface and exact trade identity')
  $daily=Get-TCExitDiagnosticInput -Manifest $m -Lane Daily
  Check ($daily.User.username -ceq 'tradechannel-daily') ($protocol+' BOM='+$bom+' preserves independent daily identity')
  $route=& $bridge {param($M,$Id) Assert-TCConnectionProbeRoute -Manifest $M -ProfileId $Id} $m $protocol
  Check ($route.RouteVerified -and $route.SelfHostedEndpointVerified) ($protocol+' BOM='+$bom+' passes real preflight route validation')
  Check ((Get-FileHash -LiteralPath $path).Hash -ceq $m.CandidateSHA256) ($protocol+' BOM='+$bom+' preflight is read only')
 }}
 $bad=Join-Path $fixture 'invalid.json';[IO.File]::WriteAllText($bad,'{"password":"SECRET_MUST_NOT_LEAK", invalid',(New-Object Text.UTF8Encoding($false)))
 Reject {Read-TCExitDiagnosticJson $bad} 'DiagnosticConfigReadFailed' 'Malformed JSON reports a fixed safe code'
 $m.CandidatePath=$bad
 $intent=[pscustomobject]@{Mode='Trading';Exit='HongKong';Daily='Direct';Agents='Daily';AgentIds=@();AgentCustom=@()}
 Reject {& $bridge {param($M,$Intent) Assert-TCConnectionIntent $M $Intent Tcp fixture} $m $intent} 'DiagnosticConfigReadFailed' 'Actual transaction preflight rejects malformed config before any actor'
 $missing=Read-TCExitDiagnosticJson $path;$missing.dns.servers[0].bind_interface='已移除网卡'
 [IO.File]::WriteAllText($bad,($missing|ConvertTo-Json -Depth 12),[Text.Encoding]::UTF8)
 Reject {Get-TCExitDiagnosticInput -Manifest $m -CheckInterfaces} 'DiagnosticInterfaceMissing' 'Removed interface is caught before connecting'
 function Get-NetIPAddress {param($AddressFamily,$ErrorAction) [pscustomobject]@{InterfaceAlias='以太网';IPAddress='192.0.2.55'}}
 $missing.dns.servers[0].bind_interface='以太网';$missing.dns.servers[0]|Add-Member NoteProperty inet4_bind_address '192.0.2.55' -Force
 [IO.File]::WriteAllText($bad,($missing|ConvertTo-Json -Depth 12),[Text.Encoding]::UTF8)
 $pinnedOk=Get-TCExitDiagnosticInput -Manifest $m -CheckInterfaces
 Check ($pinnedOk.Config.dns.servers[0].inet4_bind_address -ceq '192.0.2.55') 'Pinned local IPv4 that is still assigned passes preflight'
 $missing.dns.servers[0].inet4_bind_address='192.0.2.77'
 [IO.File]::WriteAllText($bad,($missing|ConvertTo-Json -Depth 12),[Text.Encoding]::UTF8)
 Reject {Get-TCExitDiagnosticInput -Manifest $m -CheckInterfaces} 'DiagnosticAddressChanged' 'Moved DHCP address is caught before connecting'
 $mapped=& $transactions {CTFailure ([InvalidOperationException]::new('[TC:DiagnosticAddressChanged] fixture')) BeforeStop}
 Check ($mapped.Code -ceq 'DiagnosticAddressChanged' -and $mapped.Message -like '*IPv4*') 'Address change maps to an actionable transaction message'
 $missing.dns.servers[0].PSObject.Properties.Remove('inet4_bind_address')
 $missing.dns.servers[0].bind_interface='以太网';$missing.inbounds[0].users=@(@{username='wrong-user';password='SECRET_MUST_NOT_LEAK'})
 [IO.File]::WriteAllText($bad,($missing|ConvertTo-Json -Depth 12),[Text.Encoding]::UTF8)
 Reject {Get-TCExitDiagnosticInput -Manifest $m} 'ProbeRouteUnverified' 'Probe cannot fall back to a different authenticated user'
 foreach($errorText in @('JSON parse SECRET_MUST_NOT_LEAK', '[TC:DiagnosticConfigReadFailed] SECRET_MUST_NOT_LEAK')){
  $failure=& $transactions {param($Text) CTFailure ([InvalidOperationException]::new($Text)) VerifyTarget} $errorText
  Check (-not ($failure|ConvertTo-Json).Contains('SECRET_MUST_NOT_LEAK') -and $failure.Phase -ceq 'VerifyTarget') 'Transaction diagnostics whitelist error metadata'
 }
 $result=[pscustomobject]@{Passed=$true;PowerShellVersion=$PSVersionTable.PSVersion.ToString();Checks=$checks.Count;Assertions=$checks.ToArray();RealRuntimeMutations=0;RealNetworkRequests=0}
 if($ReportPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($result|ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($true)))}
 $result|ConvertTo-Json -Depth 5
}finally{
 Remove-Module RuntimeBridge,ConnectionTransactions -ErrorAction SilentlyContinue
 $full=[IO.Path]::GetFullPath($fixture);$parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if(-not $full.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -cnotmatch '^TC-ConnectionDiagnostics-[a-f0-9]{32}$'){throw 'Fixture cleanup rejected'}
 Remove-Item -LiteralPath $full -Recurse -Force
}
