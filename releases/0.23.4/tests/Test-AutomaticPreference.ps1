#requires -Version 5.1
[CmdletBinding()]param([string]$ReportPath,[string]$PackageRoot)
$ErrorActionPreference='Stop';Set-StrictMode -Version 2;$env:PSModulePath=Join-Path $PSHOME 'Modules'
if($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1){throw 'Run this fixture with Windows PowerShell 5.1.'}
$package=if($PackageRoot){[IO.Path]::GetFullPath($PackageRoot)}else{Split-Path $PSScriptRoot -Parent}
$work=Join-Path ([IO.Path]::GetTempPath()) ('TradeChannel-worker-fixture-'+[guid]::NewGuid().ToString('N'))
$testPackage=Join-Path $work 'package';$fixtureRoot=$work
$jobs=Join-Path $fixtureRoot 'Product\jobs';$null=[IO.Directory]::CreateDirectory((Join-Path $testPackage 'assets'));$null=[IO.Directory]::CreateDirectory($jobs)
foreach($name in @('NodeStore.psm1','NodeOperations.ps1','LineStore.psm1','ProtocolSelection.psm1','ConnectionTransactions.psm1','ProtocolComparison.psm1','CandidateProbe.psm1','ProbePath.psm1','RuntimeObservability.psm1','DeploymentDecision.psm1','DeploymentStore.psm1','ConnectionMethods.psm1','ConnectionMethods.json','ProductText.psm1','Worker.ps1','WorkerContracts.psm1','WorkerErrors.psm1')){Copy-Item -LiteralPath (Join-Path $package $name) -Destination (Join-Path $testPackage $name)}
$null=[IO.Directory]::CreateDirectory((Join-Path $testPackage 'runtime'));Copy-Item -LiteralPath (Join-Path $package 'runtime\TradeChannel.ProviderRelay.ps1') -Destination (Join-Path $testPackage 'runtime\TradeChannel.ProviderRelay.ps1')
$engine=Join-Path $testPackage 'assets\sing-box.exe';$wg=Join-Path $testPackage 'assets\wg.exe';[IO.File]::WriteAllText($engine,'inert fixture engine');[IO.File]::WriteAllText($wg,'inert fixture helper')
$state=@{Base=$work;Root=$null;Now=[DateTimeOffset]::UtcNow;Network=[pscustomobject]@{Status='Available';Fingerprint=('A'*64)};EngineHash='';LineId='';Node=$null;Observed=$null;NativeCalls=0;ActualTouches=0;Starts=0;Active=1;MaximumActive=1;Ops=(New-Object 'Collections.Generic.List[string]')}
$workerRows=New-Object 'Collections.Generic.List[object]'
$checks=New-Object 'Collections.Generic.List[string]';$failure=$null;$result=$null
function Check {param([bool]$Ok,[string]$Label)if(-not $Ok){throw $Label};$script:checks.Add($Label);Write-Host ('PASS '+$Label)}
function JsonRead {param([string]$Path)$raw=[IO.File]::ReadAllText($Path);if((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')){ConvertFrom-Json -InputObject $raw -DateKind String}else{ConvertFrom-Json -InputObject $raw}}
function JsonWrite {param([string]$Path,$Value)$full=[IO.Path]::GetFullPath($Path);if(-not $full.StartsWith($work.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Fixture rejected external write'};[IO.File]::WriteAllText($full,(ConvertTo-Json -InputObject $Value -Depth 60),(New-Object Text.UTF8Encoding($true)))}
function Hash {param([string]$Path)(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash}
function CopyValue {param($Value)$raw=ConvertTo-Json -InputObject $Value -Depth 60;if((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')){ConvertFrom-Json -InputObject $raw -DateKind String}else{ConvertFrom-Json -InputObject $raw}}
function RecordPath {Join-Path $state.Root ('Product\lines\'+$state.LineId+'\line.json')}
function Line {Get-TCLine -Root $state.Root -Id $state.LineId}
$nodes=Import-Module (Join-Path $testPackage 'NodeStore.psm1') -PassThru -DisableNameChecking
$lines=Import-Module (Join-Path $testPackage 'LineStore.psm1') -PassThru -DisableNameChecking
$protocol=Import-Module (Join-Path $testPackage 'ProtocolSelection.psm1') -PassThru -DisableNameChecking
$transactions=Import-Module (Join-Path $testPackage 'ConnectionTransactions.psm1') -PassThru -DisableNameChecking
try{
 & $nodes {
  param($State,$Engine,$Wg)
  $script:Fixture=$State;$script:FixtureEngine=$Engine;$script:FixtureWg=$Wg
  function script:Invoke-TCProcess {throw 'Real native process forbidden'}
  function script:Get-CimInstance {param($ClassName,$Filter,$ErrorAction)@()}
  function script:Get-Process {throw 'Real process read forbidden'}
  function script:Start-Process {throw 'Real process start forbidden'}
  function script:Stop-Process {throw 'Real process stop forbidden'}
  $script:TCNativeRunner={param($FilePath,$ArgumentList,$InputText,$TimeoutMilliseconds)
   if($ArgumentList[0] -eq 'pubkey' -and $FilePath -ceq $script:FixtureWg){$output=[Convert]::ToBase64String([byte[]](1..32))}
   elseif($ArgumentList[0] -eq 'check' -and $FilePath -ceq $script:FixtureEngine -and (Test-TCPathWithin $ArgumentList[-1] $script:Fixture.Base)){$null=Read-TCJson $ArgumentList[-1];$output='fixture syntax checked'}
   else{throw 'Native adapter refuses non-fixture command'}
   $script:Fixture.NativeCalls++;[pscustomobject]@{ExitCode=0;StandardOutput=$output;StandardError=''}
  }
 } $state $engine $wg
 & $lines {param($State)$script:Fixture=$State;$script:PreferenceClock={$script:Fixture.Now}} $state
 & $protocol {param($State)$script:Fixture=$State;$script:PreferenceClock={$script:Fixture.Now};$script:NetworkContextReader={param($Binding)$script:Fixture.Network}} $state
 # Exercise the public next-connection transaction with the existing private
 # runtime seam. All selection, immutable binding, approval and journal logic
 # stays real; only the runtime actor operates on disposable fixture state.
 & $transactions {
  param($State,$LineApi)
  $script:Fixture=$State;$script:FixtureLines=$LineApi;$script:PreferenceClock={$script:Fixture.Now}
  function script:Get-Process {$script:Fixture.ActualTouches++;throw 'Real process access forbidden'}
  function script:Get-CimInstance {$script:Fixture.ActualTouches++;throw 'Real process inventory forbidden'}
  function script:Start-Process {$script:Fixture.ActualTouches++;throw 'Real runtime start forbidden'}
  function script:Stop-Process {$script:Fixture.ActualTouches++;throw 'Real runtime stop forbidden'}
  function script:Invoke-WebRequest {$script:Fixture.ActualTouches++;throw 'Real network forbidden'}
  function script:Invoke-RestMethod {$script:Fixture.ActualTouches++;throw 'Real network forbidden'}
  function script:Invoke-TCController {$script:Fixture.ActualTouches++;throw 'Production controller forbidden'}
  $script:TestAdapter={param($Operation,$Root,$Payload)
   $s=$script:Fixture
   if($Root -cne $s.Root -or -not $Root.StartsWith($s.Base.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Runtime adapter rejects external root'}
   $s.Ops.Add($Operation)
   switch($Operation){
    'Preflight'{return}
    'ReadBoundary'{return}
    'Line'{$line=& $script:FixtureLines {param($r,$i)Get-TCLine -Root $r -Id $i} $Root $Payload.Id;$profile=@($line.Profiles|Where-Object Id -ceq $Payload.ProfileId)|Select-Object -First 1;return [pscustomobject]@{Line=$line;Profile=$profile}}
    'DefaultProfile'{return & $script:FixtureLines {param($r,$i,$n,$m)Get-TCLineDefaultProfile -Root $r -Id $i -NetworkContext $n -SelectionMode $m} $Root $Payload.Id $Payload.NetworkContext $Payload.SelectionMode}
    'NetworkContext'{return $s.Network}
    'Preferences'{return CTRead (Join-Path $Root 'ui-preferences.json')}
    'Observe'{return CTRead (Join-Path $Root 'fixture-observed.json')}
    'ValidateIntent'{if(-not $Payload.Manifest.SyntaxValidated){throw 'Unprepared fixture intent'};return [pscustomobject]@{ExitEvidence=[pscustomobject]@{Source='ConfiguredEndpoint';Authoritative=$false}}}
    {$_ -in @('StopOriginal','StopOwnedCandidate')}{$s.Active=0;$s.Observed.State='Stopped';CTWrite (Join-Path $Root 'fixture-observed.json') $s.Observed;return}
    'Start'{
     if($s.Active -ne 0){throw 'Second fixture engine forbidden'}
     $s.Active=1;$s.Starts++;$s.MaximumActive=[Math]::Max($s.MaximumActive,$s.Active)
     $s.Observed.State='Running';$s.Observed.ManifestPath=$Payload.ManifestPath;$s.Observed.CandidateSHA256=(CTRead $Payload.ManifestPath).CandidateSHA256
     $s.Observed.SessionId='fixture-'+$s.Starts;$s.Observed.SupervisorPid=500+$s.Starts;$s.Observed.EnginePid=600+$s.Starts
     $s.Observed.SupervisorStartedAt=(CTNow).ToString('o');$s.Observed.EngineStartedAt=(CTNow).ToString('o')
     CTWrite (Join-Path $Root 'fixture-observed.json') $s.Observed;return
    }
    'ApplyIntent'{return}
    'Verify'{return [pscustomobject]@{ExitHttp=$true;ObservedIP='192.0.2.40';DnsHttps=$true;ExitVerified=$true;ActualExit='hk';ProfileValidated=[bool]$Payload.ProfileId;ServerAttributionVerified=$false}}
    default{throw ('Unexpected fixture runtime operation '+$Operation)}
   }
  }
 } $state $lines
 # Launch the unmodified Worker copy in its own Windows PowerShell process.
 # Only module-private fixture adapters replace native work and network reads;
 # no request field can supply these adapters or bypass evidence validation.
 $workerHarness=Join-Path $testPackage 'Invoke-AutomaticFixture.ps1'
 [IO.File]::WriteAllText($workerHarness,@'
param([string]$FixtureRoot,[string]$RequestPath,[string]$ResultPath,[switch]$ReadSession)
$ErrorActionPreference='Stop';$env:PSModulePath=Join-Path $PSHOME 'Modules'
if($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.ToString() -notlike '5.1.*'){throw 'Windows PowerShell 5.1 required'}
$fixture=Get-Content -LiteralPath (Join-Path $FixtureRoot 'fixture-context.json') -Raw -Encoding UTF8|ConvertFrom-Json
$nodes=Import-Module (Join-Path $PSScriptRoot 'NodeStore.psm1') -PassThru -DisableNameChecking
& $nodes {
 param($State,$Root,$Package)
 $script:Fixture=$State;$script:FixtureRoot=$Root;$script:FixturePackage=$Package;$script:ActualTouches=0;$script:ReadbackFault=$false
 function script:Invoke-TCProcess {$script:ActualTouches++;throw 'Fixture forbids real native work'}
 function script:Get-CimInstance {$script:ActualTouches++;throw 'Fixture forbids real process inventory'}
 function script:Get-Process {$script:ActualTouches++;throw 'Fixture forbids real process access'}
 function script:Start-Process {$script:ActualTouches++;throw 'Fixture forbids runtime start'}
 function script:Stop-Process {$script:ActualTouches++;throw 'Fixture forbids runtime stop'}
 function script:Invoke-WebRequest {$script:ActualTouches++;throw 'Fixture forbids network'}
 function script:Invoke-RestMethod {$script:ActualTouches++;throw 'Fixture forbids network'}
 $script:TCNativeRunner={param($FilePath,$ArgumentList,$InputText,$TimeoutMilliseconds)
  if($FilePath -cne (Join-Path $script:FixturePackage 'assets\wg.exe') -or $ArgumentList.Count -ne 1 -or $ArgumentList[0] -cne 'pubkey'){throw 'Fixture rejects native command'}
  [pscustomobject]@{ExitCode=0;StandardOutput=[Convert]::ToBase64String([byte[]](1..32));StandardError=''}
 }
 $script:OriginalWrite=(Get-Command Write-TCAtomicJson -CommandType Function).ScriptBlock
 $script:OriginalRead=(Get-Command Read-TCBoundedText -CommandType Function).ScriptBlock
 function script:Write-TCAtomicJson {
  param([string]$Path,$Value,[switch]$NewOnly,[switch]$NoBom)
  if(-not $Path.StartsWith($script:FixtureRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Fixture forbids external write'}
  $metadata=[IO.Path]::GetFileName($Path) -like '.metadata-*.json'
  if($metadata -and $script:Fixture.Fault -eq 'BeforeWrite'){throw 'Injected metadata write failure'}
  & $script:OriginalWrite -Path $Path -Value $Value -NewOnly:$NewOnly -NoBom:$NoBom
  if($metadata -and $script:Fixture.Fault -eq 'AfterCommitRead'){$script:ReadbackFault=$true}
 }
 function script:Read-TCBoundedText {
  param([string]$Path,[int]$Limit=4194304)
  if(-not $Path.StartsWith($script:FixtureRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -and -not $Path.StartsWith($script:FixturePackage.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Fixture forbids external read'}
  if($script:ReadbackFault -and [IO.Path]::GetFileName($Path) -ceq 'line.json'){$script:ReadbackFault=$false;throw 'Injected committed readback failure'}
  & $script:OriginalRead -Path $Path -Limit $Limit
 }
} $fixture $FixtureRoot $PSScriptRoot
$protocol=Import-Module (Join-Path $PSScriptRoot 'ProtocolSelection.psm1') -PassThru -DisableNameChecking
& $protocol {param($State)$script:Fixture=$State;$script:PreferenceClock={[DateTimeOffset]$script:Fixture.Now};$script:NetworkContextReader={param($Binding)$script:Fixture.Network}} $fixture
& (Join-Path $PSScriptRoot 'Worker.ps1') -RequestPath $RequestPath -ResultPath $ResultPath -IsolatedTest -TestRoot $FixtureRoot -ReadSession:$ReadSession
$touches=& $nodes {$script:ActualTouches}
[IO.File]::WriteAllText(($ResultPath+'.guard.json'),(@{ActualTouches=$touches;RuntimeBridgeLoaded=[bool](Get-Module RuntimeBridge);PowerShellVersion=$PSVersionTable.PSVersion.ToString()}|ConvertTo-Json))
'@,(New-Object Text.UTF8Encoding($true)))
 function NewFixture {param([switch]$WithTcp)
  $script:fixtureRoot=Join-Path $work ('TradeChannel-worker-fixture-'+[guid]::NewGuid().ToString('N'))
  $script:jobs=Join-Path $fixtureRoot 'Product\jobs';$null=[IO.Directory]::CreateDirectory($jobs)
  $state.Root=$fixtureRoot;$state.Now=[DateTimeOffset]::UtcNow;$state.Network.Status='Available';$state.Network.Fingerprint=('A'*64);$state.Starts=0;$state.Active=1;$state.MaximumActive=1;$state.Ops.Clear()
  [IO.File]::WriteAllText($engine,'inert fixture engine');$state.EngineHash=Hash $engine
  $private=[Convert]::ToBase64String([byte[]](33..64));$serverKey=[Convert]::ToBase64String([byte[]](65..96));$conf=Join-Path $state.Root 'client.conf'
  [IO.File]::WriteAllText($conf,("[Interface]`nPrivateKey = $private`nAddress = 10.78.0.4/24`n[Peer]`nPublicKey = $serverKey`nEndpoint = 192.0.2.20:51820`nAllowedIPs = 0.0.0.0/0`nPersistentKeepalive = 25`n"))
  $node=Import-TCWireGuard -Root (Join-Path $state.Root 'Product') -Path $conf -Name 'safe fixture' -EnginePath $engine -WgPath $wg -DirectDnsIPv4 '192.0.2.53' -Providers @()
  $state.LineId=$node.id;$state.Node=$node;$manifest=JsonRead $node.manifestPath
  $manifest|Add-Member NoteProperty NetworkPolicy ([pscustomobject]@{SchemaVersion=1;Kind='PhysicalInterface';InterfaceId='fixture-only';InterfaceName='Fixture';AddressPolicy='CurrentIPv4'});JsonWrite $node.manifestPath $manifest
  $null=Register-TCLineProfiles -Root $state.Root -Id $node.id
  if($WithTcp){AddTcp}
  $state.Observed=[pscustomobject]@{State='Running';OwnershipKnown=$true;ManifestPath=$node.manifestPath;CandidateSHA256=$manifest.CandidateSHA256;SessionId='fixture-session';SupervisorPid=501;EnginePid=601;SupervisorStartedAt='2026-01-01T00:00:00Z';EngineStartedAt='2026-01-01T00:00:01Z'}
  JsonWrite (Join-Path $state.Root 'runtime.json') $state.Observed
  JsonWrite (Join-Path $state.Root 'fixture-observed.json') $state.Observed
  JsonWrite (Join-Path $state.Root 'ui-preferences.json') @{NodeId=$node.id;ProfileId='Udp';Mode='Rule';Exit='HongKong';Daily='Direct'}
  JsonWrite (Join-Path $state.Root 'deployment.json') @{ManifestPath=$node.manifestPath;Stage='Configured';NodeId=$node.id}
 }
 function AddTcp {
   $node=$state.Node;$manifest=JsonRead $node.manifestPath
   $transport=[pscustomobject]@{Type='tcp-reality';Server='192.0.2.20';Port=443;Uuid='cccccccc-dddd-4eee-8fff-aaaaaaaaaaaa';RealityPublicKey='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';RealityShortId='1234567890abcdef';ServerName='www.bing.com'}
   $envelope=[pscustomobject]@{Kind='TradeChannel.TransportInfo';Status='Available';NodeId='aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';RemoteOwnerId='bbbbbbbb-cccc-4ddd-8eee-ffffffffffff';ServerPublicKey=$manifest.ServerPublicKey;ClientPublicKey=$manifest.ClientPublicKey;ClientAddress=$manifest.ClientAddress;Transport=$transport}
   $null=Prepare-TCTcpLineProfile -Root $state.Root -Id $node.id -TransportInfo $envelope
 }
 function ProtectedSnapshot {
  $line=Line;$paths=@($state.Node.manifestPath,(Join-Path $state.Root 'Product\index.json'),(Join-Path $state.Root 'runtime.json'),(Join-Path $state.Root 'ui-preferences.json'),(Join-Path $state.Root 'deployment.json'),$engine,$wg)
  foreach($profile in @($line.Profiles)){$paths+=,$profile.ManifestPath;$m=JsonRead $profile.ManifestPath;$paths+=@($m.CandidatePath,$m.ProbePath)}
  @($paths|Sort-Object -Unique|ForEach-Object {[pscustomobject]@{Path=$_;SHA256=(Hash $_)}})
 }
 function CheckProtected {param($Before,[string]$Label)
  Check (@($Before|Where-Object {(-not [IO.File]::Exists($_.Path)) -or (Hash $_.Path) -cne $_.SHA256}).Count -eq 0) $Label
 }
 function AddCurrentRecommendation {param([string]$ProfileId='Udp')
  $line=Line;$profile=@($line.Profiles|Where-Object Id -ceq $ProfileId)[0]
  $runId=[guid]::NewGuid().ToString('D')
  $raw=[pscustomobject]@{Status='Passed';Code='CandidateReachabilityVerified';CandidateHash=$profile.CandidateSHA256;ManifestHash=$profile.ManifestSHA256;EngineSHA256=$state.EngineHash;ForwardingPassed=$true;ExpectedExitSource='ServerVerifiedTlsTrace';ExpectedExitIPv4='192.0.2.40';ObservedExitIPv4='192.0.2.40';CheckedAtUtc=$state.Now.ToString('o');CleanupComplete=$true;Checks=@([pscustomobject]@{Name='AddressHttps';Status='Passed'},[pscustomobject]@{Name='DomainDnsHttps';Status='Passed'});PathEvidence=[pscustomobject]@{Verified=$true;EligibleForRecommendation=$true;Kind='BoundInterfaceObserved';NetworkFingerprint=$state.Network.Fingerprint;Binding=[pscustomobject]@{InterfaceId='fixture-only';NetworkFingerprint=$state.Network.Fingerprint}};NetworkFingerprint=$state.Network.Fingerprint;RunId=$runId;ConfigHash=$profile.ProbeSHA256;ProbeDerivativeRequired=$true;ProbeDerivative=[pscustomobject]@{SchemaVersion=1;BaseCandidateSHA256=$profile.CandidateSHA256;BaseManifestSHA256=$profile.ManifestSHA256;ProbeSHA256=$profile.ProbeSHA256;Binding=[pscustomobject]@{InterfaceId='fixture-only';NetworkFingerprint=$state.Network.Fingerprint};EvidenceId=$runId}}
  $evidence=ConvertTo-TCProtocolEvidence -Result $raw -Profile $profile -NetworkContext $state.Network -Now $state.Now
  $null=Set-TCLineProfileValidation -Root $state.Root -Id $state.LineId -ProfileId $ProfileId -Validation $evidence
  $line=Line;$recommendation=Get-TCProtocolRecommendation -LineId $line.LineId -Profiles @($line.Profiles) -NetworkContext $state.Network -Now $state.Now
  Check ($recommendation.Status -ceq 'Recommended' -and $recommendation.RecommendedProfileId -ceq $ProfileId) ('fixture produces a current bound '+$ProfileId+' recommendation')
  $null=Set-TCLineRecommendation -Root $state.Root -Id $state.LineId -Recommendation $recommendation -NetworkContext $state.Network
 }
 function SaveManual {param([string]$Id='Tcp')
  $line=Line;$profile=@($line.Profiles|Where-Object Id -ceq $Id)[0]
  Set-TCLinePreferredProfile -Root $state.Root -Id $state.LineId -ProfileId $Id -ExpectedRevision $line.Revision -ExpectedProfileRevision $profile.Revision -ExpectedCandidateSHA256 $profile.CandidateSHA256
 }
 function InvokeResetWorker {param($Request,[string]$Fault='',[switch]$ReadSession)
  $id=[guid]::NewGuid().ToString('N');$requestPath=Join-Path $jobs ($id+'.request.json');$resultPath=Join-Path $jobs ($id+'.result.json')
  $Request=$Request.Clone();$Request.RequestId=$id;$Request.PageGeneration=3;$Request.UiRequestId=[guid]::NewGuid().ToString('N')
  [IO.File]::WriteAllText($requestPath,($Request|ConvertTo-Json -Depth 12 -Compress),(New-Object Text.UTF8Encoding($true)))
  $receiptPath=Join-Path $jobs ($id+'.receipt.json');JsonWrite $receiptPath @{SchemaVersion=1;RequestId=$id;OperationId=$id;Action='LinePreferenceReset';LineId=$state.LineId;Status='Running';UpdatedAtUtc=[DateTimeOffset]::UtcNow.ToString('o')}
  JsonWrite (Join-Path $fixtureRoot 'fixture-context.json') @{Now=$state.Now.ToString('o');Network=$state.Network;Fault=$Fault}
  $arguments=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',('"'+$workerHarness+'"'),'-RequestPath',('"'+$requestPath+'"'),'-ResultPath',('"'+$resultPath+'"'),'-FixtureRoot',('"'+$fixtureRoot+'"'))
  if($ReadSession){$arguments+='-ReadSession'}
  $exe=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe';$process=Start-Process -FilePath $exe -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput ($resultPath+'.out.log') -RedirectStandardError ($resultPath+'.err.log')
  try{
   if(-not $process.WaitForExit(60000)){try{$process.Kill()}catch{};throw 'Fixture Worker timed out.'}
   if(-not(Test-Path -LiteralPath $resultPath)){throw ('Fixture Worker did not publish a result: '+[IO.File]::ReadAllText(($resultPath+'.err.log')))}
   $r=JsonRead $resultPath;$receipt=JsonRead $receiptPath;$guard=JsonRead ($resultPath+'.guard.json')
   Check ($guard.ActualTouches -eq 0 -and -not $guard.RuntimeBridgeLoaded -and $guard.PowerShellVersion -like '5.1.*') 'Worker uses Windows PowerShell 5.1 with no native process, controller or network access'
   Check ($r.RequestId -ceq $id -and $r.UiRequestId -ceq $Request.UiRequestId -and $r.PageGeneration -eq 3) 'Worker preserves request and UI envelope identity'
   $terminal=if($r.OutcomeUnknown){'OutcomeUnknown'}elseif($r.Ok){'Completed'}else{'Failed'}
   Check ($receipt.Status -ceq $terminal -and $receipt.RequestId -ceq $id -and [IO.File]::GetLastWriteTimeUtc($receiptPath) -le [IO.File]::GetLastWriteTimeUtc($resultPath)) 'Worker publishes a matching terminal receipt before the result'
   $workerRows.Add([pscustomobject]@{RequestId=$id;Ok=$r.Ok;Code=$(if($r.PSObject.Properties['Code']){$r.Code}else{''});ReceiptStatus=$receipt.Status;OutcomeUnknown=$r.OutcomeUnknown;Guard=$guard})
   return $r
  }finally{$process.Dispose()}
 }

 NewFixture -WithTcp;AddCurrentRecommendation;$line=SaveManual Tcp;$beforeRecommendation=Hash (RecordPath);$oldSavedDigest=$line.SavedConnectionPreference.Digest
 $protected=ProtectedSnapshot
 $checksums=@($line.Profiles|ForEach-Object {Hash $_.ManifestPath});$deploymentBefore=if(Test-Path (Join-Path $state.Root 'deployment.json')){Hash (Join-Path $state.Root 'deployment.json')}else{''};$prefsBefore=Hash (Join-Path $state.Root 'ui-preferences.json')
 $worker=InvokeResetWorker @{Action='LinePreferenceReset';Id=$state.LineId;ExpectedRevision=$line.Revision;ExpectedDigest=$oldSavedDigest}
 Check ($worker.Ok -and $worker.Data.PreferenceMode -ceq 'Auto' -and $worker.Data.PreferenceOutcome -ceq 'AutomaticRecommendation' -and $worker.Data.PreferredProfileId -ceq 'Udp' -and $worker.Data.PreferenceSource -ceq 'Reachability') 'real Worker restores a currently recommended automatic default'
 $after=Line;Check ($after.Revision -eq ($line.Revision+1) -and $after.SavedConnectionPreference.Source -ceq 'Reachability' -and $after.Recommendation.EvidenceDigest -ceq $line.Recommendation.EvidenceDigest) 'automatic choice advances CAS revision and preserves the recommendation digest'
 $record=JsonRead (RecordPath);Check ($record.AutomaticPreferenceTransition.FromDigest -ceq $oldSavedDigest -and $record.AutomaticPreferenceTransition.FromRevision -eq $line.Revision -and $record.AutomaticPreferenceTransition.ToRevision -eq $after.Revision) 'transition audit summary retains the cleared digest and both revisions'
 Check ((Hash (RecordPath)) -cne $beforeRecommendation -and $after.DefaultVerified) 'automatic preference is persisted with a verified saved binding'
 Check ($worker.Data.PreferenceChanged -and $after.PreferenceMode -ceq 'Auto' -and $after.AutomaticPreferenceTransition.RequestId -ceq $worker.RequestId -and $after.AutomaticPreferenceTransition.ToDigest -ceq $after.SavedConnectionPreference.Digest -and $after.AutomaticPreferenceTransition.RecommendationDigest -ceq $after.Recommendation.EvidenceDigest) 'durable audit binds the operation identity, automatic snapshot and recommendation'
 $audit=CopyValue $after.AutomaticPreferenceTransition;$auditDigest=$audit.Digest;$audit.PSObject.Properties.Remove('Digest')
 $sha=[Security.Cryptography.SHA256]::Create();try{$rebuiltDigest=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($audit|ConvertTo-Json -Depth 40 -Compress))))).Replace('-','')}finally{$sha.Dispose()}
 Check ($rebuiltDigest -ceq $auditDigest -and (Line).AutomaticPreferenceTransition.Digest -ceq $auditDigest) 'line reads expose a reproducible persisted transition digest for receipt recovery'
 CheckProtected $protected 'reset preserves runtime, deployment, connection intent, node index and every immutable profile byte'
 $beforeNoop=Hash (RecordPath);$again=InvokeResetWorker @{Action='LinePreferenceReset';Id=$state.LineId;ExpectedRevision=$after.Revision;ExpectedDigest=$after.SavedConnectionPreference.Digest}
 Check ($again.Ok -and $again.Data.PreferenceOutcome -ceq 'AlreadyAutomatic' -and -not $again.Data.PreferenceChanged -and $again.Data.PreferenceNextAction -ceq 'PreviewConnection' -and (Hash (RecordPath)) -ceq $beforeNoop) 'repeating automatic mode with a fresh CAS is idempotent and byte-identical'
 $acl=Get-Acl -LiteralPath (RecordPath);$rules=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
 Check ($acl.AreAccessRulesProtected -and $rules.Count -eq 2 -and @($rules|Where-Object {$_.IdentityReference.Value -notin @('S-1-5-18','S-1-5-32-544') -or $_.AccessControlType -ne 'Allow' -or $_.FileSystemRights -ne [Security.AccessControl.FileSystemRights]::FullControl}).Count -eq 0) 'atomic replacement retains private SYSTEM and Administrators-only ACL'
 Check (($checksums -join ',') -ceq (@($after.Profiles|ForEach-Object {Hash $_.ManifestPath}) -join ',') -and (Hash (Join-Path $state.Root 'ui-preferences.json')) -ceq $prefsBefore -and $state.Observed.State -ceq 'Running') 'reset leaves immutable profiles, active runtime and connection intent untouched'
 if($deploymentBefore){Check ((Hash (Join-Path $state.Root 'deployment.json')) -ceq $deploymentBefore) 'deployment intent is byte-identical'}else{Check (-not (Test-Path (Join-Path $state.Root 'deployment.json'))) 'reset does not create deployment state'}
 $null=Import-Module (Join-Path $testPackage 'WorkerContracts.psm1') -Force -PassThru -DisableNameChecking
 $contract=Get-TCWorkerActionContract LinePreferenceReset;Check ($contract.Known -and -not $contract.ReadOnly -and $contract.TimeoutSeconds -eq 60 -and $contract.Modules -contains 'LineStore.psm1') 'worker contract registers the local atomic mutation with a bounded timeout'
 $bad=$false;try{Assert-TCWorkerRequestPreflight @{Action='LinePreferenceReset';Id=$state.LineId;ExpectedRevision=$after.Revision;ExpectedDigest=$after.SavedConnectionPreference.Digest;Extra=$true}}catch{$bad=$true};Check $bad 'worker preflight rejects unrecognized fields before dispatch'

 NewFixture -WithTcp;AddCurrentRecommendation Tcp;$manualUdp=SaveManual Udp;$protected=ProtectedSnapshot
 $r=InvokeResetWorker @{Action='LinePreferenceReset';Id=$state.LineId;ExpectedRevision=$manualUdp.Revision;ExpectedDigest=$manualUdp.SavedConnectionPreference.Digest}
 Check ($r.Ok -and $r.Data.PreferenceOutcome -ceq 'AutomaticRecommendation' -and $r.Data.PreferredProfileId -ceq 'Tcp' -and $r.Data.SavedConnectionPreference.Source -ceq 'Reachability' -and $r.Data.AutomaticPreferenceTransition.FromDigest -ceq $manualUdp.SavedConnectionPreference.Digest) 'a manual UDP choice can return to the currently recommended TCP method'
 CheckProtected $protected 'clearing a manual UDP preference also leaves the active runtime and all configuration bytes untouched'

 NewFixture;$single=SaveManual Udp;$singlePrior=$single.SavedConnectionPreference.Digest
 $singleWorker=InvokeResetWorker @{Action='LinePreferenceReset';Id=$state.LineId;ExpectedRevision=$single.Revision;ExpectedDigest=$singlePrior};$singleAfter=$singleWorker.Data
 Check ($singleWorker.Ok -and $singleAfter.PreferenceMode -ceq 'Auto' -and $singleAfter.PreferenceOutcome -ceq 'SinglePreparedProfile' -and $singleAfter.SavedConnectionPreference.Source -ceq 'SingleProfile' -and $singleAfter.PreferredProfileId -ceq 'Udp') 'real Worker makes a single prepared method usable without labeling it as a verified recommendation'
 $resolved=Get-TCLineDefaultProfile -Root $state.Root -Id $state.LineId
 Check ($resolved.ProfileId -ceq 'Udp' -and -not $resolved.RequiresCheck -and $resolved.Source -ceq 'SingleProfile') 'the normal saved-default resolver consumes the single-profile automatic binding'
 Check (-not $singleAfter.Recommendation -and -not $singleAfter.Profiles[0].Validation -and $singleAfter.SavedConnectionPreference.Provenance.Kind -ceq 'SinglePreparedProfile') 'single-profile automatic mode creates no reachability, path or recommendation evidence'
 $tampered=CopyValue $singleAfter.SavedConnectionPreference;$tampered.ProfileId='Tcp';$profile=$singleAfter.Profiles[0];$manifest=JsonRead $profile.ManifestPath
 Check (-not (Test-TCSavedConnectionPreference $tampered $state.LineId $profile $manifest)) 'single-profile saved digest and binding reject tampering'
 $preview=Get-TCDefaultConnectionSwitchPreview -Root $state.Root -LineId $state.LineId
 Check ($preview.CanSwitch -and $preview.ProfileId -ceq 'Udp' -and $preview.DefaultSource -ceq 'SingleProfile' -and $preview.PreviewToken -clike 'ct2:*' -and $state.Starts -eq 0 -and $state.Ops -notcontains 'StopOriginal') 'single-profile automatic default passes the real connection preview without invoking a runtime actor'
 $connected=Invoke-TCDefaultConnectionSwitch -Root $state.Root -LineId $state.LineId -PreviewToken $preview.PreviewToken
 Check ($connected.Status -ceq 'Completed' -and $connected.Check.ProfileValidated -and $state.Starts -eq 1 -and $state.MaximumActive -eq 1 -and $state.Ops -contains 'Verify' -and $state.ActualTouches -eq 0) 'single-profile automatic default completes the real transaction through a simulated actor and post-start verification'
 Check ((Line).SavedConnectionPreference.Digest -ceq $singleAfter.SavedConnectionPreference.Digest -and -not (Line).Recommendation -and -not (Line).Profiles[0].Validation) 'a later simulated connection preserves the automatic preference and creates no recommendation or probe pass'
 AddTcp;$expanded=Get-TCLineDefaultProfile -Root $state.Root -Id $state.LineId
 Check ($expanded.RequiresCheck -and -not $expanded.ProfileId -and -not $expanded.SavedConnectionPreference) 'preparing a second method invalidates the unique-profile shortcut without defaulting to either method'

 NewFixture -WithTcp;$multi=SaveManual Tcp;$multiPrior=$multi.SavedConnectionPreference.Digest
 $noRecommendation=[pscustomobject]@{SchemaVersion=1;LineId=$state.LineId;Status='Inconclusive';RecommendedProfileId=$null;PreferredProfileId=$null;RequestedProfileId=$null;Source='None';Reason='fixture'}
 $null=Set-TCLineRecommendation -Root $state.Root -Id $state.LineId -Recommendation $noRecommendation -NetworkContext $state.Network
 $multi=Line;$multiPrior=$multi.SavedConnectionPreference.Digest
 $blocked=Reset-TCLineManualPreference -Root $state.Root -Id $state.LineId -ExpectedRevision $multi.Revision -ExpectedDigest $multiPrior
 Check ($blocked.PreferenceOutcome -ceq 'NeedsCheck' -and $blocked.PreferenceNextAction -ceq 'CheckLineProfiles' -and -not $blocked.PreferredProfileId -and -not $blocked.SavedConnectionPreference) 'multiple prepared methods without an effective recommendation require a line check and select neither'
 $choice=Get-TCLineDefaultProfile -Root $state.Root -Id $state.LineId
 Check (-not $choice.ProfileId -and $choice.RequiresCheck -and $choice.Code -eq 'AutomaticPreferenceNeedsCheck') 'automatic connection resolution cannot start a random method without a recommendation'
 $protected=ProtectedSnapshot;$preview=Get-TCDefaultConnectionSwitchPreview -Root $state.Root -LineId $state.LineId
 Check (-not $preview.CanSwitch -and -not $preview.PreviewToken -and $preview.Code -ceq 'AutomaticPreferenceNeedsCheck' -and $state.Starts -eq 0 -and $state.Ops -notcontains 'StopOriginal' -and $state.Ops -notcontains 'Verify') 'real default connection preview refuses unresolved automatic mode before any runtime actor'
 CheckProtected $protected 'unresolved automatic preview preserves active runtime and configuration bytes'
 $beforeNoop=Hash (RecordPath);$again=Reset-TCLineManualPreference -Root $state.Root -Id $state.LineId -ExpectedRevision $blocked.Revision -ExpectedDigest ''
 Check ($again.PreferenceOutcome -ceq 'AlreadyAutomatic' -and $again.PreferenceNextAction -ceq 'CheckLineProfiles' -and (Hash (RecordPath)) -ceq $beforeNoop) 'already-automatic unresolved mode remains byte-identical and still directs the user to check'

 NewFixture -WithTcp;$stale=SaveManual Tcp;$digest=$stale.SavedConnectionPreference.Digest;$before=Hash (RecordPath)
 $refused=$false;try{$null=Reset-TCLineManualPreference -Root $state.Root -Id $state.LineId -ExpectedRevision ($stale.Revision-1) -ExpectedDigest $digest}catch{$refused=$_.Exception.Message -like '*[[]TC:PreferenceRevisionChanged]*'}
 Check ($refused -and (Hash (RecordPath)) -ceq $before -and (Line).PreferenceSource -ceq 'UserChoice') 'stale line revision refuses the reset without writing'
 $protected=ProtectedSnapshot
 foreach($badCas in @(@{ExpectedRevision=($stale.Revision-1);ExpectedDigest=$digest},@{ExpectedRevision=$stale.Revision;ExpectedDigest=('0'*64)},@{ExpectedRevision=$stale.Revision;ExpectedDigest=''})){
  $r=InvokeResetWorker @{Action='LinePreferenceReset';Id=$state.LineId;ExpectedRevision=$badCas.ExpectedRevision;ExpectedDigest=$badCas.ExpectedDigest}
  Check (-not $r.Ok -and $r.Code -ceq 'PreferenceRevisionChanged' -and $r.NextAction -ceq 'Refresh' -and -not $r.OutcomeUnknown -and $r.Phase -ceq 'Executing' -and (Hash (RecordPath)) -ceq $before) 'Worker classifies stale revision or changed digest as a known refusal and retains every line byte'
 }
 CheckProtected $protected 'all rejected CAS requests preserve configuration and active connection intent bytes'
 $baseRequest=@{Action='LinePreferenceReset';Id=$state.LineId;ExpectedRevision=$stale.Revision;ExpectedDigest=$digest}
 $extra=$baseRequest.Clone();$extra.Extra=$true
 $missing=$baseRequest.Clone();$missing.Remove('ExpectedDigest')
 $stringRevision=$baseRequest.Clone();$stringRevision.ExpectedRevision=[string]$stale.Revision
 $negative=$baseRequest.Clone();$negative.ExpectedRevision=-1
 $badId=$baseRequest.Clone();$badId.Id='00000000-0000-0000-0000-000000000000'
 $badDigest=$baseRequest.Clone();$badDigest.ExpectedDigest='not-a-digest'
 foreach($badRequest in @($extra,$missing,$stringRevision,$negative,$badId,$badDigest)){
  $r=InvokeResetWorker $badRequest
  Check (-not $r.Ok -and $r.Code -ceq 'InvalidRequest' -and $r.Phase -ceq 'BeforeDispatch' -and -not $r.OutcomeUnknown -and (Hash (RecordPath)) -ceq $before) 'Worker rejects malformed reset fields before dispatch without any line write'
 }
 $r=InvokeResetWorker $baseRequest -ReadSession
 Check (-not $r.Ok -and $r.Code -ceq 'ReadActionNotAllowed' -and $r.Phase -ceq 'BeforeDispatch' -and -not $r.OutcomeUnknown -and (Hash (RecordPath)) -ceq $before) 'read-session Worker cannot reset a preference'
 $r=InvokeResetWorker $baseRequest -Fault BeforeWrite
 Check (-not $r.Ok -and $r.Code -ceq 'LocalOperationNotApplied' -and $r.NextAction -ceq 'RetryOperation' -and -not $r.OutcomeUnknown -and (Hash (RecordPath)) -ceq $before -and -not (Line).AutomaticPreferenceTransition) 'metadata write failure is known not applied and retains the original manual preference'
 Check (@(Get-ChildItem -LiteralPath (Split-Path (RecordPath) -Parent) -Filter '.metadata-*.json' -Force).Count -eq 0) 'failed metadata publication leaves no orphan temporary metadata'
 $r=InvokeResetWorker $baseRequest -Fault AfterCommitRead
 $committed=Line;$transition=$committed.AutomaticPreferenceTransition
 Check (-not $r.Ok -and $r.Code -ceq 'LocalResultReadFailed' -and $r.NextAction -ceq 'Refresh' -and -not $r.OutcomeUnknown -and $committed.PreferenceMode -ceq 'Auto' -and $committed.Revision -eq ($stale.Revision+1)) 'failure after atomic commit is classified as saved with a failed readback'
 Check ($transition.RequestId -ceq $r.RequestId -and $transition.FromRevision -eq $stale.Revision -and $transition.FromDigest -ceq $digest -and $transition.ToRevision -eq $committed.Revision -and $transition.Outcome -ceq 'NeedsCheck') 'persisted request-bound transition proves the committed reset when the result could not be read'
 CheckProtected $protected 'write failure and committed read failure leave runtime, deployment and immutable profile bytes untouched'

 foreach($invalidContext in @('ChangedNetwork','UnavailableNetwork','Expired','DamagedRecommendation','UnboundProbePath')){
  NewFixture -WithTcp;AddCurrentRecommendation;$manual=SaveManual Tcp
  switch($invalidContext){
   ChangedNetwork {$state.Network.Fingerprint=('B'*64)}
   UnavailableNetwork {$state.Network.Status='Unavailable';$state.Network.Fingerprint=$null}
   Expired {$state.Now=$state.Now.AddHours(1)}
   DamagedRecommendation {$record=JsonRead (RecordPath);$record.Recommendation.EvidenceDigest=('0'*64);JsonWrite (RecordPath) $record}
   UnboundProbePath {
    $record=JsonRead (RecordPath);$p=@($record.Profiles|Where-Object Id -ceq 'Udp')[0];$raw=CopyValue $p.Validation.Result
    $raw.ProbeDerivative.Binding.NetworkFingerprint=('B'*64)
    $evidence=ConvertTo-TCProtocolEvidence -Result $raw -Profile $p -NetworkContext $state.Network -Now $state.Now
    Check (-not $evidence.EligibleForAutomaticSelection) 'mismatched probe derivative and path binding cannot become automatic evidence'
    $null=Set-TCLineProfileValidation -Root $state.Root -Id $state.LineId -ProfileId Udp -Validation $evidence
   }
  }
  $manual=Line;$protected=ProtectedSnapshot;$recommendationBefore=($manual.Recommendation|ConvertTo-Json -Depth 40 -Compress)
  $r=InvokeResetWorker @{Action='LinePreferenceReset';Id=$state.LineId;ExpectedRevision=$manual.Revision;ExpectedDigest=$manual.SavedConnectionPreference.Digest}
  Check ($r.Ok -and $r.Data.PreferenceMode -ceq 'Auto' -and $r.Data.PreferenceOutcome -ceq 'NeedsCheck' -and $r.Data.PreferenceNextAction -ceq 'CheckLineProfiles' -and -not $r.Data.SavedConnectionPreference -and -not $r.Data.PreferredProfileId -and -not $r.Data.DefaultVerified) ($invalidContext+' recommendation never supplies an arbitrary or falsely verified automatic method')
  Check (((Line).Recommendation|ConvertTo-Json -Depth 40 -Compress) -ceq $recommendationBefore) 'reset preserves original recommendation and path evidence rather than repairing it into a pass'
  CheckProtected $protected ($invalidContext+' reset preserves configuration and active connection intent bytes')
 }
 $errors=Import-Module (Join-Path $testPackage 'WorkerErrors.psm1') -PassThru -DisableNameChecking
 $safe=Get-TCWorkerFailure -Failure '[TC:AutomaticPreferenceNeedsCheck] fixture' -Action ConnectionDefaultPreview -Phase Executing -MayHaveChanged $false
 Check ($safe.Code -ceq 'AutomaticPreferenceNeedsCheck' -and $safe.NextAction -ceq 'CheckLineProfiles' -and -not $safe.OutcomeUnknown) 'automatic pending default has a known check-line classification rather than an uncertain mutation'
 Check ($state.NativeCalls -gt 0 -and $state.ActualTouches -eq 0 -and -not (Get-Module RuntimeBridge)) 'fixtures use only bounded syntax/key adapters and never load the production controller'
 $result=[pscustomobject]@{Passed=$true;Checks=$checks.Count;Assertions=$checks.ToArray();WorkerAction='LinePreferenceReset';WorkerResults=$workerRows.ToArray();FixtureScope='Disposable Windows PowerShell 5.1 fixture';PowerShellVersion=$PSVersionTable.PSVersion.ToString();ProductionWrites=0;RealNetworkChanges=0;RemoteCalls=0;RuntimeStateTouched=$false;Timestamp=[DateTimeOffset]::UtcNow.ToString('o')}
}catch{$failure=$_.Exception.Message;$result=[pscustomobject]@{Passed=$false;Error=$failure;FailureLine=$_.InvocationInfo.ScriptLineNumber;Stack=$_.ScriptStackTrace;Checks=$checks.Count;Assertions=$checks.ToArray();WorkerResults=$workerRows.ToArray();FixtureScope='Disposable Windows PowerShell 5.1 fixture';ProductionWrites=0;RealNetworkChanges=0;RemoteCalls=0}}
finally{
 foreach($module in @($lines,$protocol,$transactions)){if($module){& $module {$script:PreferenceClock=$null;$script:NetworkContextReader=$null;$script:TestAdapter=$null}}}
 if($ReportPath){$fullReport=[IO.Path]::GetFullPath($ReportPath);$null=[IO.Directory]::CreateDirectory((Split-Path $fullReport -Parent));[IO.File]::WriteAllText($fullReport,($result|ConvertTo-Json -Depth 30),(New-Object Text.UTF8Encoding($true)))}
 Get-Module|Where-Object {$_.Path -and $_.Path.StartsWith($testPackage.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)}|Remove-Module -Force
 $full=[IO.Path]::GetFullPath($work);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if(-not $full.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notmatch '^TradeChannel-worker-fixture-[a-f0-9]{32}$'){throw 'Fixture cleanup rejected a non-temporary directory'}
 Remove-Item -LiteralPath $full -Recurse -Force
}
if($failure){throw $failure};$result
