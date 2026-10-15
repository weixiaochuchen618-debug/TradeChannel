#requires -Version 5.1
[CmdletBinding()]param([string]$ReportDirectory)
$ErrorActionPreference='Stop'
$package=Split-Path $PSScriptRoot -Parent
$workspace=Split-Path (Split-Path $package -Parent) -Parent
$parent=if($ReportDirectory){$ReportDirectory}else{[IO.Path]::GetTempPath()};$null=[IO.Directory]::CreateDirectory($parent)
$root=Join-Path $parent ('.runtime-bridge-fixture-'+[Guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($root)
$module=Import-Module (Join-Path $package 'RuntimeBridge.psm1') -Force -PassThru -DisableNameChecking
try{
 & $module {
  param($TestRoot)
  $script:Root=$TestRoot;$script:Checks=0;$script:ActualProcessTouches=0;$script:Transactions=0;$script:Fail=$false;$script:Running=$true;$script:ActiveLine=$null;$script:DefaultCalls=0;$script:DefaultMode=$null
  function script:Check {param($Ok,$Message)$script:Checks++;if(-not $Ok){throw $Message}}
  function script:Get-Process {param($Name,$Id,$ErrorAction)if($Name -eq 'NinjaTrader'){return};$script:ActualProcessTouches++;throw 'Actual process access forbidden'}
  function script:Get-CimInstance {$script:ActualProcessTouches++;throw 'Actual process inventory forbidden'}
  function script:Start-Process {$script:ActualProcessTouches++;throw 'Actual process start forbidden'}
  function script:Stop-Process {$script:ActualProcessTouches++;throw 'Actual process stop forbidden'}
  function script:Invoke-TCCommand {$script:ActualProcessTouches++;throw 'Actual channel operation forbidden'}
  function script:Test-TCActiveConnection {$script:ActualProcessTouches++;throw 'Actual network test forbidden'}
  function script:Test-TCNinjaRunning {return $false}
  $script:Id='11111111-1111-1111-1111-111111111111';$script:Manifest=Join-Path $TestRoot 'current.json';$script:NewManifest=Join-Path $TestRoot 'next.json'
  Write-TCSessionJson $script:Manifest @{Providers=@()};Write-TCSessionJson $script:NewManifest @{Providers=@()}
  function script:Get-TCRegisteredNodes {@([pscustomobject]@{id=$script:Id;manifestPath=$script:NewManifest})}
  function script:Get-TCOverview {[pscustomobject]@{Running=$script:Running;CanConnect=(-not $script:Running);ActiveLineId=$script:ActiveLine;StateKey='Connected';Mode='rule';ControllerModes=@('rule','global');Exit='hk';Daily='direct';DailySupported=$false;AgentsSupported=$false;ManifestPath=$script:Manifest;ConnectedSince='fixture'}}
  function script:AssertHeld {
   $opened=$null;$blocked=$false
   try{$opened=[IO.File]::Open((Join-Path $script:Root '.session.lock'),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}catch{$blocked=$true}finally{if($opened){$opened.Dispose()}}
   Check $blocked 'Session adapter did not inherit held lock'
  }
  function script:Invoke-TCManifestConnectionSwitch {
   param($ManifestPath,$Intent,[switch]$SessionLockHeld)
   $script:Transactions++;$script:LastManifest=$ManifestPath;$script:LastIntent=$Intent;$script:Held=[bool]$SessionLockHeld
   if($script:Fail){return [pscustomobject]@{Status='NeedsRecovery';Message='需要恢复，配置恢复不等于连接恢复';Error='simulated stop failure'}}
   if($SessionLockHeld){AssertHeld}
   [pscustomobject]@{Status='Completed';Activated=$true;Message='simulated';Check=@{ExitHttp=$true};Observed=@{State='Running'}}
  }
  function script:Invoke-TCProfileConnectionSwitch {
   param($LineId,$ProfileId,$Intent,$PreviewToken,[switch]$SessionLockHeld,[switch]$DefaultSelection)
   $script:LastDefault=[bool]$DefaultSelection
   $script:Transactions++;$script:LastLine=$LineId;$script:LastProfile=$ProfileId;$script:LastToken=$PreviewToken;$script:LastProfileIntent=$Intent;$script:Held=[bool]$SessionLockHeld;AssertHeld
   [pscustomobject]@{Status='Completed';Activated=$true;Message='simulated';Observed=@{State='Running'}}
  }
  function script:Get-TCSessionDefaultProfile {
   param($LineId)
   $script:DefaultCalls++
   if($script:DefaultMode -eq 'Blocked'){throw '[TC:RecommendationCheckRequired] 请检查线路'}
   if($script:DefaultMode){[pscustomobject]@{ProfileId=$script:DefaultMode;Source='Reachability'}}
  }
  $atomic=Join-Path $TestRoot 'atomic.json';[IO.File]::WriteAllText($atomic,'{"value":"old"}')
  $held=[IO.File]::Open($atomic,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
  $failed=$false;try{try{Write-TCSessionText $atomic '{"value":"new"}'}catch{$failed=$true}}finally{$held.Dispose()}
  Check ($failed -and [IO.File]::ReadAllText($atomic) -ceq '{"value":"old"}' -and @(Get-ChildItem $TestRoot -Filter '*.tmp').Count -eq 0) 'Atomic replacement corrupted old bytes'
  Write-TCSessionText $atomic '{"value":"new"}';Check ((Get-Content $atomic -Raw|ConvertFrom-Json).value -eq 'new') 'Atomic replacement failed'
  Check (-not (Get-TCPreferences).ProfileId) 'Old preferences require a ProfileId'
  $null=Save-TCPreferences -Mode Global -Exit HongKong -NodeId $script:Id -ProfileId Udp
  $null=Save-TCPreferences -Daily Direct;Check ((Get-TCPreferences).ProfileId -eq 'Udp') 'Unrelated preference save discarded profile'
  $null=Save-TCPreferences -ProfileId Tcp;Check ((Get-TCPreferences).ProfileId -eq 'Tcp') 'Profile preference roundtrip failed'
  $before=[IO.File]::ReadAllText((Join-Path $TestRoot 'ui-preferences.json'));$failed=$false
  try{$null=Save-TCPreferences -ProfileId 'Arbitrary'}catch{$failed=$true};Check ($failed -and [IO.File]::ReadAllText((Join-Path $TestRoot 'ui-preferences.json')) -ceq $before) 'Invalid profile was persisted'
  $null=Save-TCPreferences -ProfileId '';Check (-not (Get-TCPreferences).ProfileId) 'Optional profile could not be cleared'
  $r=Enable-TCNode -ManifestPath $script:NewManifest -Mode Global -Exit HongKong
  Check ($r.Activated -and $script:LastManifest -eq $script:NewManifest -and $script:LastIntent.Mode -eq 'Global' -and -not $script:Held) 'Legacy Enable did not use manifest transaction'
  $script:Fail=$true;$failed=$false;try{$null=Enable-TCNode -ManifestPath $script:NewManifest}catch{$failed=$true};Check ($failed -and $script:ActualProcessTouches -eq 0) 'Enable hid NeedsRecovery or escaped adapter';$script:Fail=$false
  $r=Invoke-TCSession Apply -NodeId $script:Id -ProfileId Tcp -PreviewToken 'fixture-preview'
  Check ($r.ConnectionTransaction.Status -eq 'Completed' -and $script:Held -and $script:LastLine -eq $script:Id -and $script:LastProfile -eq 'Tcp' -and $script:LastToken -eq 'fixture-preview') 'Session profile transaction dispatch failed'
  $count=$script:Transactions;$r=Invoke-TCSession Connect -ProfileId Tcp -Exit Provider
  Check ($r.ConnectionTransaction.Status -eq 'Completed' -and $script:Transactions -eq $count+1 -and $script:LastProfileIntent.Exit -eq 'HongKong') 'Profile-only Connect returned an untested provider session or kept provider target'
  $r=Invoke-TCSession Apply -NodeId $script:Id
  Check ($r.ConnectionTransaction.Status -eq 'Completed' -and $script:Held -and $script:LastManifest -eq $script:NewManifest) 'Legacy node change did not use same transaction'
  $second='22222222-2222-2222-2222-222222222222'
  $null=Save-TCPreferences -NodeId $script:Id -ProfileId Tcp
  $null=Save-TCPreferences -NodeId $second
  Check (-not (Get-TCPreferences).ProfileId) 'Switching preference node inherited old node profile'
  $null=Save-TCPreferences -NodeId $script:Id -ProfileId Udp
  $script:Running=$false;$script:DefaultMode='Tcp';$script:ActiveLine=$null
  $r=Invoke-TCSession Connect -NodeId $script:Id
  Check ($script:LastProfile -eq 'Tcp' -and $script:LastDefault -and $script:LastProfileIntent.Exit -eq 'HongKong') 'Connect ignored recommended TCP or bypassed default transaction'
  $script:Running=$true;$script:ActiveLine=$script:Id;$script:DefaultMode='Blocked'
  $beforeDefault=$script:DefaultCalls;$beforeTx=$script:Transactions
  $null=Invoke-TCSession Apply -Daily Direct
  $null=Invoke-TCSession Apply -NodeId $script:Id -Daily Direct
  $null=Invoke-TCSession Connect -NodeId $script:Id
  Check ($script:DefaultCalls -eq $beforeDefault -and $script:Transactions -eq $beforeTx) 'Daily Apply or idempotent Connect consumed changed recommendation'
  $canonical='33333333-3333-3333-3333-333333333333'
  $aliasRoot=Join-Path $TestRoot ('Product\lines\'+$canonical);$null=[IO.Directory]::CreateDirectory($aliasRoot)
  Write-TCSessionJson (Join-Path $aliasRoot 'line.json') @{LineId=$canonical;AliasIds=@($script:Id)}
  $script:ActiveLine=$canonical
  $null=Invoke-TCSession Apply -NodeId $script:Id -Daily Direct
  Check ($script:DefaultCalls -eq $beforeDefault -and $script:Transactions -eq $beforeTx) 'Same canonical line alias caused a transport switch during Apply'
  $script:ActiveLine=$script:Id
  $script:Running=$false;$beforePrefs=[IO.File]::ReadAllText((Join-Path $TestRoot 'ui-preferences.json'))
  $failed=$false;try{$null=Invoke-TCSession Connect -NodeId $script:Id}catch{$failed=$true}
  Check ($failed -and $script:Transactions -eq $beforeTx -and [IO.File]::ReadAllText((Join-Path $TestRoot 'ui-preferences.json')) -ceq $beforePrefs) 'Unavailable recommendation fell back to UDP or saved new intent'
  $script:Running=$true;$script:ActiveLine=$second;$script:DefaultMode='Tcp'
  $null=Invoke-TCSession Apply -NodeId $script:Id
  Check ($script:LastProfile -eq 'Tcp' -and $script:LastDefault) 'Explicit node switch inherited old saved Udp preference'
  $script:DefaultMode=$null;$script:ActiveLine=$null
  $null=Invoke-TCSession Apply -NodeId $script:Id
  Check (-not $script:LastIntent.ProfileId) 'Legacy manifest switch inherited stale profile intent'
  # Exercise the actual production proof logic. Only OS observations and TLS
  # probe I/O are supplied by the private fixture adapter; routes/registry/IP
  # matching and profile/legacy selection guards below are never mocked.
  $proofChecksBefore=$script:Checks
  function script:ResetProbeFixture {
   $script:ProbeCalls=0;$script:ProbeObservations=0;$script:ProbeDrift=$false;$script:DomainIP='192.0.2.40'
   $script:ProbeConfig=Join-Path $script:Root 'probe-main.json'
   $cfg=@{inbounds=@(@{type='mixed';tag='egress-probe';listen='127.0.0.1';listen_port=17890;users=@(@{username='tradechannel-probe';password='fixture'},@{username='tradechannel-daily';password='fixture'})});route=@{rules=@(@{inbound=@('egress-probe');auth_user=@('tradechannel-daily');action='route';outbound='daily-exit'},@{inbound=@('egress-probe');action='route';outbound='trade-exit'})};endpoints=@(@{type='wireguard';tag='hk';detour='tc-transport';peers=@(@{public_key='fixture-server-key';address='192.0.2.20';port=51820})});outbounds=@(@{type='selector';tag='trade-exit';outbounds=@('hk','provider-trade')},@{type='vless';tag='tc-transport';server='192.0.2.20';tls=@{enabled=$true;reality=@{enabled=$true}}})}
   Write-TCSessionJson $script:ProbeConfig $cfg
   $script:ProofManifest=[pscustomobject]@{CandidatePath=$script:ProbeConfig;CandidateSHA256=(Get-FileHash -LiteralPath $script:ProbeConfig -Algorithm SHA256).Hash;ServerPublicKey='fixture-server-key';ServerEndpoint='192.0.2.20:51820';TCLineId=$script:Id;Providers=@([pscustomobject]@{Id='fixture-provider';Tag='provider';TradeTag='provider-trade';Port=12080;TradePort=12081;Kind='custom';Name='fixture'})}
   $script:ProofIntent=[pscustomobject]@{Mode='Global';Exit='HongKong';Daily='Direct';Agents='Daily';AgentIds=@();AgentCustom=@();ProviderId='fixture-provider';TradeProviderId='fixture-provider'}
   $script:ProofPayload=[pscustomobject]@{Manifest=$script:ProofManifest;Intent=$script:ProofIntent;Expected=$null;ProfileId='Tcp';LineId=$script:Id}
   $script:ProbeState=[pscustomobject]@{State='Running';Mode='global';Exit='hk';CandidateSHA256=$script:ProofManifest.CandidateSHA256;SessionId='proof-session';EnginePid=202;EngineStartedAt='2026-01-01T00:00:01Z';SupervisorPid=201;SupervisorStartedAt='2026-01-01T00:00:00Z';ManifestPath=(Join-Path $script:Root 'proof.manifest')}
   $registry=Join-Path $script:Root 'servers\registry.json';if([IO.File]::Exists($registry)){[IO.File]::Delete($registry)}
  }
  function script:UpdateProbeConfig {
   param($Cfg)
   Write-TCSessionJson $script:ProbeConfig $Cfg
   $script:ProofManifest.CandidateSHA256=(Get-FileHash -LiteralPath $script:ProbeConfig -Algorithm SHA256).Hash;$script:ProbeState.CandidateSHA256=$script:ProofManifest.CandidateSHA256
  }
  function script:SetProbeRegistry {
   param([string]$IP,[string]$Key='fixture-server-key')
   $dir=Join-Path $script:Root 'servers';$null=[IO.Directory]::CreateDirectory($dir)
   Write-TCSessionJson (Join-Path $dir 'registry.json') @{SchemaVersion=1;Revision=1;Servers=@(@{LocalRecordId='fixture-server';LinkedNodeIds=@($script:Id);ServerPublicKey=$Key;ExpectedExitSource='ServerVerifiedTlsTrace';ExpectedExitIPv4=$IP;LastCheckedUtc='2026-01-01T00:00:00Z'})}
  }
  function script:Get-TCConnectionRuntimeObserved {
   $script:ProbeObservations++;$state=$script:ProbeState|ConvertTo-Json|ConvertFrom-Json
   if($script:ProbeDrift -and $script:ProbeObservations -gt 1){$state.SessionId='different-session'}
   $overview=[pscustomobject]@{StateKey='Connected';Running=$true;SessionId=$state.SessionId;ConfigHash=$state.CandidateSHA256;EnginePid=$state.EnginePid;ManifestPath=$state.ManifestPath;ActiveLineId=$script:ProofPayload.LineId;ActiveProfileId=$(if($script:ProofPayload.ProfileId){$script:ProofPayload.ProfileId}else{'Tcp'});Mode=$state.Mode;Exit=$state.Exit;Daily='direct';Agents='Daily';ProviderId='fixture-provider';TradeProviderId=$(if($state.Exit -eq 'hk'){''}else{'fixture-provider'});DesiredDaily='Direct';AgentsSupported=$false;DailySupported=$false;AgentIds=@();AgentCustom=@()}
   if($script:ContextDrift -and $script:ProbeObservations -gt 1){$overview.($script:ContextDrift)=$script:ContextDriftValue}
   $state|Add-Member NoteProperty Overview $overview -Force
   $state
  }
  function script:Invoke-TCConnectionTraceProbe {
   param($Url)
   $script:ProbeCalls++
   if($Url -eq 'https://www.tradingview.com/'){return [pscustomobject]@{CurlExit=0;HTTPStatus=403;ObservedIP=$null;Url=$Url}}
   [pscustomobject]@{CurlExit=0;HTTPStatus=200;ObservedIP=$(if($Url -eq 'https://www.cloudflare.com/cdn-cgi/trace'){$script:DomainIP}else{'192.0.2.40'});Url=$Url}
  }
  function script:RejectBeforeProbe {
   $failed=$false;try{$null=Test-TCConnectionExitEvidence $script:ProofPayload}catch{$failed=$true}
   Check ($failed -and $script:ProbeCalls -eq 0) 'Unsafe profile proof reached diagnostics'
  }
  ResetProbeFixture
  $proof=Test-TCConnectionExitEvidence $script:ProofPayload
  Check ($proof.ExitVerified -and $proof.ProfileValidated -and $proof.ActualExit -eq 'hk' -and $proof.ProbeRoute.AuthUser -eq 'tradechannel-probe' -and $proof.ProbeRoute.Outbound -eq 'trade-exit') 'Production logic did not prove authenticated self-hosted profile path'
  Check ($proof.ExitSource -eq 'ConfiguredEndpoint' -and -not $proof.ServerAttributionVerified -and $proof.ExitAttribution -eq 'InferredNotAuthoritative') 'Configured endpoint was promoted to authoritative attribution'
  Check ($proof.ApplicationValidation -eq 'UserVerificationRequired') 'Browser 403 incorrectly invalidated TLS/DNS forwarding'
  Check ($proof.ProofVersion -eq 2 -and -not $proof.ContextChanged -and (Test-TCLineCheckBinding $proof (Get-TCExitCheckContext $proof.Observed.Overview) $script:ProofPayload.LineId Tcp)) 'Actual transaction measurement records a complete reusable context'
  foreach($case in @(@('Daily','provider'),@('Agents','Trade'),@('TradeProviderId','other-provider'),@('ActiveLineId','other-line'),@('ActiveProfileId','Udp'),@('ConfigHash',('F'*64)))){
   ResetProbeFixture;$script:ContextDrift=$case[0];$script:ContextDriftValue=$case[1];$drift=Test-TCConnectionExitEvidence $script:ProofPayload
   Check ($drift.ContextChanged -and -not $drift.ExitVerified -and $drift.Code -eq 'SessionChangedDuringCheck') ('Routing/identity drift during actual measurement invalidates '+$case[0])
  }
  $script:ContextDrift=''
  ResetProbeFixture;SetProbeRegistry '192.0.2.40';$proof=Test-TCConnectionExitEvidence $script:ProofPayload
  Check ($proof.ProfileValidated -and $proof.ServerAttributionVerified -and $proof.ExitSource -eq 'ServerVerifiedTlsTrace' -and $proof.ServerRecordId -eq 'fixture-server') 'Known server TLS-trace match not bound to registry'
  ResetProbeFixture;SetProbeRegistry '192.0.2.41';$proof=Test-TCConnectionExitEvidence $script:ProofPayload
  Check (-not $proof.ExitVerified -and -not $proof.ProfileValidated -and $proof.Code -eq 'ServerExitMismatch') 'Mismatching authoritative server exit passed profile proof'
  ResetProbeFixture;SetProbeRegistry '192.0.2.40' 'foreign-server-key';RejectBeforeProbe
  ResetProbeFixture;$script:ProofIntent.Exit='Provider';$script:ProbeState.Exit='provider-trade';RejectBeforeProbe
  ResetProbeFixture;$script:ProbeState.Exit='provider-trade';RejectBeforeProbe
  foreach($mutation in @('MissingUser','DuplicateUser','ShadowProviderRoute','ConditionalRoute','NoProbeRoute','ProviderHk','WrongServerKey','TcpWithoutTransport')){
   ResetProbeFixture;$cfg=Get-Content -LiteralPath $script:ProbeConfig -Raw|ConvertFrom-Json
   switch($mutation){
    'MissingUser'{$cfg.inbounds[0].users=@([pscustomobject]@{username='unknown-user';password='fixture'})}
    'DuplicateUser'{$cfg.inbounds[0].users+=,[pscustomobject]@{username='tradechannel-probe';password='another'} }
    'ShadowProviderRoute'{$cfg.route.rules=@([pscustomobject]@{action='route';outbound='provider-trade'})+@($cfg.route.rules)}
    'ConditionalRoute'{$cfg.route.rules=@([pscustomobject]@{inbound=@('egress-probe');domain_suffix=@('cloudflare.com');action='route';outbound='provider-trade'})+@($cfg.route.rules)}
    'NoProbeRoute'{$cfg.route.rules=@($cfg.route.rules[0])}
    'ProviderHk'{$cfg.endpoints[0].type='socks'}
    'WrongServerKey'{$cfg.endpoints[0].peers[0].public_key='foreign-server-key'}
    'TcpWithoutTransport'{$cfg.endpoints[0].PSObject.Properties.Remove('detour')}
   }
   UpdateProbeConfig $cfg;RejectBeforeProbe
  }
  ResetProbeFixture;$script:ProofPayload.ProfileId='Udp';$cfg=Get-Content -LiteralPath $script:ProbeConfig -Raw|ConvertFrom-Json;$cfg.endpoints[0].PSObject.Properties.Remove('detour');UpdateProbeConfig $cfg;$proof=Test-TCConnectionExitEvidence $script:ProofPayload
  Check ($proof.ProfileValidated -and $proof.ProfileId -eq 'Udp' -and $proof.ActualExit -eq 'hk') 'Actual production proof rejected correct UDP self-hosted path'
  ResetProbeFixture;$script:DomainIP='192.0.2.41';$proof=Test-TCConnectionExitEvidence $script:ProofPayload
  Check (-not $proof.ExitVerified -and -not $proof.ProfileValidated) 'Different address/DNS trace IPs passed'
  ResetProbeFixture;$script:ProbeDrift=$true;$failed=$false;try{$null=Test-TCConnectionExitEvidence $script:ProofPayload}catch{$failed=$true};Check $failed 'Changed process identity passed proof'
  # Actual legacy layout: exact provider processes and a logical directory
  # bypass precede the authenticated probe route. curl cannot match either.
  ResetProbeFixture;$cfg=Get-Content -LiteralPath $script:ProbeConfig -Raw|ConvertFrom-Json
  $providerDirectory=Join-Path $TestRoot 'provider-only';$prefix='(?i)^'+[regex]::Escape($providerDirectory+'\')
  $bypass=[pscustomobject]@{process_path=@((Join-Path $providerDirectory 'vpn.exe'));action='route';outbound='direct'}
  $logical=[pscustomobject]@{type='logical';mode='and';rules=@([pscustomobject]@{process_path_regex=@($prefix)},[pscustomobject]@{rule_set=@('tc-agents');invert=$true});action='route';outbound='direct'}
  $cfg.route.rules=@($bypass,$logical)+@($cfg.route.rules);UpdateProbeConfig $cfg
  $proof=Test-TCConnectionExitEvidence $script:ProofPayload
  Check ($proof.ExitVerified -and $proof.ProfileValidated -and $script:ProbeCalls -eq 3) 'Real legacy provider-bypass layout was falsely rejected'
  Check ($proof.ProbeRoute.ProbeExecutablePath -ieq (Join-Path ([Environment]::GetFolderPath('System')) 'curl.exe')) 'Proof did not bind executor identity'
  $script:ProofPayload.ProfileId=$null;$null=Assert-TCConnectionIntent $script:ProofManifest $script:ProofIntent
  foreach($mutation in @('CurlProcess','InvertExcludedProcess','LogicalOrUnknown','BroadRegex','LogicalOrCurl')){
   ResetProbeFixture;$cfg=Get-Content -LiteralPath $script:ProbeConfig -Raw|ConvertFrom-Json
   $curl=Join-Path ([Environment]::GetFolderPath('System')) 'curl.exe'
   $rule=[pscustomobject]@{process_path=@((Join-Path $TestRoot 'provider.exe'));action='route';outbound='direct'}
   switch($mutation){
    'CurlProcess'{$rule.process_path=@($curl)}
    'InvertExcludedProcess'{$rule|Add-Member NoteProperty invert $true}
    'LogicalOrUnknown'{$rule=[pscustomobject]@{type='logical';mode='or';rules=@($rule,[pscustomobject]@{rule_set=@('unknown')});action='route';outbound='direct'}}
    'BroadRegex'{$rule=[pscustomobject]@{process_path_regex=@('(?i)^.*curl');action='route';outbound='direct'}}
    'LogicalOrCurl'{$rule=[pscustomobject]@{type='logical';mode='or';rules=@($rule,[pscustomobject]@{process_path=@($curl)});action='route';outbound='direct'}}
   }
   $cfg.route.rules=@($rule)+@($cfg.route.rules);UpdateProbeConfig $cfg;RejectBeforeProbe
   # The manifest-only/legacy preflight also rejects before any runtime actor.
   $failed=$false;try{$null=Assert-TCConnectionIntent $script:ProofManifest $script:ProofIntent}catch{$failed=$true}
   Check $failed 'Legacy preflight accepted an unsafe diagnostic path'
  }
  ResetProbeFixture;SetProbeRegistry '192.0.2.41';$script:ProofPayload.ProfileId=$null;$script:ProofIntent.Exit='Provider';$script:ProbeState.Exit='provider-trade';$proof=Test-TCConnectionExitEvidence $script:ProofPayload
  Check ($proof.ExitVerified -and -not $proof.ProfileValidated -and $proof.ActualExit -eq 'provider-trade' -and $proof.ExitSource -eq 'SelectedTradeExit') 'Manifest-only legacy Provider semantics changed'
  $proofChecks=$script:Checks-$proofChecksBefore
  $script:IsolatedReadContext=$true;$count=$script:Transactions
  foreach($body in @({Enable-TCNode -ManifestPath $script:NewManifest},{Invoke-TCSession Apply -NodeId $script:Id -ProfileId Tcp},{Invoke-TCConnectionRuntime -Operation Start -Root $TestRoot})){
   $failed=$false;try{& $body}catch{$failed=$true};Check $failed 'Isolation boundary permitted runtime mutation'
  }
  Check ($script:Transactions -eq $count -and $script:ActualProcessTouches -eq 0) 'Isolation guard ran an actor'
  [pscustomobject]@{Passed=$true;Checks=$script:Checks;ProductionEvidenceChecks=$proofChecks;ActualProcessTouches=$script:ActualProcessTouches;RealNetworkChanges=0;Scope='Atomic replacement, profile compatibility, unified dispatch, held lock, isolation rejection; real production proof logic with simulated I/O: exact auth route, hk WireGuard/TCP, authoritative registry match/mismatch, inferred attribution, provider rejection, legacy provider preservation'}
 } $root
}finally{
 Remove-Module RuntimeBridge -ErrorAction SilentlyContinue
 $resolved=[IO.Path]::GetFullPath($root);$prefix=[IO.Path]::GetFullPath($parent).TrimEnd('\')+'\'
 if(-not $resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^\.runtime-bridge-fixture-[a-f0-9]{32}$'){throw 'Cleanup guard rejected path'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
}
