#requires -Version 5.1
# Real producers and LineStore persistence, with inert assets and a private,
# fail-closed runtime adapter. No production controller, process or network use.
[CmdletBinding()]param([string]$ReportPath,[string]$CasePattern='.',[string]$PackageRoot)
$ErrorActionPreference='Stop';Set-StrictMode -Version 2
$package=if($PackageRoot){$PackageRoot}else{Split-Path $PSScriptRoot -Parent}
$work=Join-Path ([IO.Path]::GetTempPath()) ('TC-saved-preference-'+[guid]::NewGuid().ToString('N'))
$testPackage=Join-Path $work 'package';$null=[IO.Directory]::CreateDirectory((Join-Path $testPackage 'assets'))
foreach($name in @('NodeStore.psm1','NodeOperations.ps1','LineStore.psm1','ProtocolSelection.psm1','ConnectionTransactions.psm1','ProtocolComparison.psm1','CandidateProbe.psm1','ProbePath.psm1','RuntimeObservability.psm1','DeploymentDecision.psm1')){Copy-Item -LiteralPath (Join-Path $package $name) -Destination (Join-Path $testPackage $name)}
$engine=Join-Path $testPackage 'assets\sing-box.exe';$wg=Join-Path $testPackage 'assets\wg.exe'
[IO.File]::WriteAllText($engine,'inert fixture engine');[IO.File]::WriteAllText($wg,'inert fixture helper')
$state=@{Base=$work;Root=$null;Now=[DateTimeOffset]::UtcNow;Network=[pscustomobject]@{Status='Available';Fingerprint=('A'*64)};Ninja=$false;Fault='';Observed=$null;Starts=0;Active=0;MaximumActive=0;ActualTouches=0;NativeCalls=0;Ops=(New-Object 'Collections.Generic.List[string]')}
$checks=0;$cases=New-Object 'Collections.Generic.List[object]';$failure=$null;$result=$null;$caseNumber=0
function Check {param([bool]$Ok,[string]$Label)$script:checks++;if(-not $Ok){throw $Label}}
function JsonRead {param([string]$Path)$raw=[IO.File]::ReadAllText($Path);if((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')){ConvertFrom-Json -InputObject $raw -DateKind String}else{ConvertFrom-Json -InputObject $raw}}
function JsonWrite {param([string]$Path,$Value)
 $full=[IO.Path]::GetFullPath($Path)
 if(-not $full.StartsWith($work.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Fixture rejected external write'}
 [IO.File]::WriteAllText($full,(ConvertTo-Json -InputObject $Value -Depth 60),(New-Object Text.UTF8Encoding($true)))
}
function Hash {param([string]$Path)(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash}
function CopyValue {param($Value)$raw=ConvertTo-Json -InputObject $Value -Depth 60;if((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')){ConvertFrom-Json -InputObject $raw -DateKind String}else{ConvertFrom-Json -InputObject $raw}}
function RecordPath {Join-Path $state.Root ('Product\lines\'+$state.LineId+'\line.json')}
function Line {Get-TCLine -Root $state.Root -Id $state.LineId}
function Case {param([string]$Name,[scriptblock]$Body)
 if($Name -notmatch $CasePattern){return};$before=$checks;$caseWatch=[Diagnostics.Stopwatch]::StartNew();Write-Host ('CASE START '+$Name)
 try{& $Body;$cases.Add([pscustomobject]@{Name=$Name;Passed=$true;Checks=($checks-$before);DurationSeconds=$caseWatch.Elapsed.TotalSeconds});Write-Host ('CASE PASS '+$Name+' '+[math]::Round($caseWatch.Elapsed.TotalSeconds,2)+'s')}
 catch{$cases.Add([pscustomobject]@{Name=$Name;Passed=$false;Error=$_.Exception.Message});throw}
}
function Reject {param([scriptblock]$Body,[string]$Label)$caught=$false;try{$null=& $Body}catch{$caught=$true};Check $caught $Label}
$nodes=Import-Module (Join-Path $testPackage 'NodeStore.psm1') -PassThru -DisableNameChecking
$lines=Import-Module (Join-Path $testPackage 'LineStore.psm1') -PassThru -DisableNameChecking
$protocol=Import-Module (Join-Path $testPackage 'ProtocolSelection.psm1') -PassThru -DisableNameChecking
$transactions=Import-Module (Join-Path $testPackage 'ConnectionTransactions.psm1') -PassThru -DisableNameChecking
$comparison=Import-Module (Join-Path $testPackage 'ProtocolComparison.psm1') -PassThru -DisableNameChecking
try{
 & $nodes {
  param($State,$Engine,$Wg)
  $script:Fixture=$State;$script:FixtureEngine=$Engine;$script:FixtureWg=$Wg
  function script:Invoke-TCProcess {$script:Fixture.ActualTouches++;throw 'Real native process forbidden'}
  function script:Get-CimInstance {param($ClassName,$Filter,$ErrorAction)@()}
  function script:Get-Process {$script:Fixture.ActualTouches++;throw 'Real process read forbidden'}
  function script:Start-Process {$script:Fixture.ActualTouches++;throw 'Real process start forbidden'}
  function script:Stop-Process {$script:Fixture.ActualTouches++;throw 'Real process stop forbidden'}
  $script:TCNativeRunner={param($FilePath,$ArgumentList,$InputText,$TimeoutMilliseconds)
   if($ArgumentList[0] -eq 'pubkey' -and $FilePath -ceq $script:FixtureWg){$output=[Convert]::ToBase64String([byte[]](1..32))}
   elseif($ArgumentList[0] -eq 'check' -and $FilePath -ceq $script:FixtureEngine -and (Test-TCPathWithin $ArgumentList[-1] $script:Fixture.Base)){$null=Read-TCJson $ArgumentList[-1];$output='fixture syntax checked'}
   else{throw 'Native adapter refuses non-fixture command'}
   $script:Fixture.NativeCalls++;[pscustomobject]@{ExitCode=0;StandardOutput=$output;StandardError=''}
  }
 } $state $engine $wg
 foreach($module in @($lines,$protocol,$transactions)){
  & $module {param($State)$script:Fixture=$State;$script:PreferenceClock={$script:Fixture.Now}} $state
 }
 & $protocol {$script:NetworkContextReader={param($Binding)$script:Fixture.Network}}
 & $transactions {
  param($LineApi)
  $script:FixtureLines=$LineApi
  function script:Get-Process {$script:Fixture.ActualTouches++;throw 'Real process read forbidden'}
  function script:Get-CimInstance {$script:Fixture.ActualTouches++;throw 'Real process inventory forbidden'}
  function script:Start-Process {$script:Fixture.ActualTouches++;throw 'Real process start forbidden'}
  function script:Stop-Process {$script:Fixture.ActualTouches++;throw 'Real process stop forbidden'}
  function script:Invoke-WebRequest {$script:Fixture.ActualTouches++;throw 'Real network forbidden'}
  function script:Invoke-RestMethod {$script:Fixture.ActualTouches++;throw 'Real network forbidden'}
  function script:Invoke-TCController {$script:Fixture.ActualTouches++;throw 'Production controller forbidden'}
  $script:TestAdapter={param($Operation,$Root,$Payload)
   $s=$script:Fixture
   if($Root -cne $s.Root -or -not $Root.StartsWith($s.Base.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Runtime adapter refuses external root'}
   $s.Ops.Add($Operation)
   switch($Operation){
    'Preflight'{if($s.Ninja){throw 'NinjaTrader must exit'};return}
    'ReadBoundary'{return}
    'Line'{$line=& $script:FixtureLines {param($r,$i)Get-TCLine -Root $r -Id $i} $Root $Payload.Id;$profile=@($line.Profiles|Where-Object Id -eq $Payload.ProfileId)|Select-Object -First 1;return [pscustomobject]@{Line=$line;Profile=$profile}}
    'DefaultProfile'{return & $script:FixtureLines {param($r,$i,$n,$m)Get-TCLineDefaultProfile -Root $r -Id $i -NetworkContext $n -SelectionMode $m} $Root $Payload.Id $Payload.NetworkContext $Payload.SelectionMode}
    'NetworkContext'{return $s.Network}
    'Preferences'{return CTRead (Join-Path $Root 'ui-preferences.json')}
    'Observe'{return CTRead (Join-Path $Root 'fixture-observed.json')}
    'ValidateIntent'{if(-not $Payload.Manifest.SyntaxValidated){throw 'Unprepared intent'};return [pscustomobject]@{ExitEvidence=[pscustomobject]@{Source='ConfiguredEndpoint';Authoritative=$false}}}
    {$_ -in @('StopOriginal','StopOwnedCandidate')}{
     $s.Active=0;$s.Observed.State='Stopped'
     if($Operation -eq 'StopOriginal' -and $s.Fault -eq 'FailureAfterStop'){
      $record=CTRead (Join-Path $Root ('Product\lines\'+$s.LineId+'\line.json'));$record.Recommendation.Status='Blocked';CTWrite (Join-Path $Root ('Product\lines\'+$s.LineId+'\line.json')) $record
     }
     CTWrite (Join-Path $Root 'fixture-observed.json') $s.Observed;return
    }
    'Start'{
     if($s.Active -ne 0){throw 'Second fixture engine forbidden'}
     $s.Active=1;$s.Starts++;$s.MaximumActive=[Math]::Max($s.MaximumActive,$s.Active)
     $s.Observed.State='Running';$s.Observed.ManifestPath=$Payload.ManifestPath;$s.Observed.CandidateSHA256=(CTRead $Payload.ManifestPath).CandidateSHA256
     $s.Observed.SessionId='fixture-'+$s.Starts;$s.Observed.SupervisorPid=500+$s.Starts;$s.Observed.EnginePid=600+$s.Starts
     $s.Observed.SupervisorStartedAt=(CTNow).ToString('o');$s.Observed.EngineStartedAt=(CTNow).ToString('o')
     CTWrite (Join-Path $Root 'fixture-observed.json') $s.Observed;return
    }
    'ApplyIntent'{$s.Observed.Mode='rule';$s.Observed.Exit='hk';$s.Observed.Daily='direct';CTWrite (Join-Path $Root 'fixture-observed.json') $s.Observed;return}
    'Verify'{
     if(-not $Payload.Original -and $s.Fault -eq 'Verify'){throw 'Simulated target HTTPS/DNS failure'}
     return [pscustomobject]@{ExitHttp=$true;ObservedIP='192.0.2.40';DnsHttps=$true;ExitVerified=$true;ActualExit='hk';ProfileValidated=[bool]$Payload.ProfileId;ServerAttributionVerified=$false}
    }
    default{throw ('Unexpected runtime operation '+$Operation)}
   }
  }
 } $lines
 & $comparison {
  param($State)
  $script:Fixture=$State
  function script:Prepare-TCProtocolComparisonBinding {param($Root,$NodeId,$InterfaceIndex)
   if($Root -cne $script:Fixture.Root){throw 'Comparison rejects external root'}
   [pscustomobject]@{LineId=$NodeId;State='Ready';Code='BindingsPrepared';Results=@($script:Fixture.Profiles|ForEach-Object {[pscustomobject]@{ProfileId=$_.Id;BindingState='Reused';CandidateSHA256=$_.CandidateSHA256;ManifestSHA256=$_.ManifestSHA256}})}
  }
  function script:Get-TCProtocolComparisonContext {$script:Fixture.Network}
  function script:Get-TCProtocolComparisonProfile {param($Root,$NodeId,$ProfileId)if($Root -cne $script:Fixture.Root){throw 'Comparison rejects external root'};@($script:Fixture.Profiles|Where-Object Id -eq $ProfileId)[0]}
  function script:Invoke-TCProtocolComparisonProbe {
   param($Root,$NodeId,$ProfileId,$ExpectedExitIPv4,$ExpectedExitSource,$CancellationPath,$TimeoutSeconds)
   if($Root -cne $script:Fixture.Root){throw 'Probe adapter rejects external root'}
   $s=$script:Fixture;$p=@($s.Profiles|Where-Object Id -eq $ProfileId)[0];$failed=($s.Kind -eq 'Stability' -and $ProfileId -ne $s.Winner)
   $duration=if($s.Kind -eq 'PolicyDefault'){100}elseif($ProfileId -eq $s.Winner){60}else{200};$samples=@()
   foreach($round in 1..3){foreach($t in @(@('AddressHttps','https://1.1.1.1/cdn-cgi/trace'),@('DomainDnsHttps','https://www.cloudflare.com/cdn-cgi/trace'))){$samples+=,[pscustomobject]@{Name=$t[0];TargetUrl=$t[1];Round=$round;Required=$true;Attempted=$true;RequestBudgetSeconds=6;Status=$(if($failed){'Failed'}else{'Passed'});Code=$(if($failed){'ProbeTimeout'}else{'HttpsReached'});TlsVerified=(-not $failed);ObservedExitIPv4=$(if(-not $failed){$ExpectedExitIPv4}else{$null});DurationMs=$duration}}}
   $samples+=,[pscustomobject]@{Name='ChatGPTWeb';TargetUrl='https://chatgpt.com/';Round=1;Required=$false;Attempted=$true;RequestBudgetSeconds=6;Status='UserVerificationRequired';Code='BrowserChallenge';TlsVerified=$true;DurationMs=20}
   $path=[pscustomobject]@{Verified=$true;EligibleForRecommendation=(-not $failed);Kind='BoundInterfaceObserved';NetworkFingerprint=$s.Network.Fingerprint;Binding=[pscustomobject]@{SchemaVersion=2;Scope='FixtureOnly';InterfaceId='fixture-only'}}
   [pscustomobject]@{SchemaVersion=2;NodeId=$NodeId;ProfileId=$ProfileId;CandidateHash=$p.CandidateSHA256;ManifestHash=$p.ManifestSHA256;EngineSHA256=$s.EngineHash;Status=$(if($failed){'Failed'}else{'Passed'});Code=$(if($failed){'CandidateForwardingFailed'}else{'CandidateReachabilityVerified'});ForwardingPassed=(-not $failed);ExitServerVerifiedTrace=(-not $failed);ObservedExitIPv4=$ExpectedExitIPv4;ExpectedExitIPv4=$ExpectedExitIPv4;ExpectedExitSource=$ExpectedExitSource;NetworkFingerprint=$s.Network.Fingerprint;SnapshotFingerprint=$s.Network.Fingerprint;PathEvidence=$path;CheckedAtUtc=$s.Now.ToString('o');CleanupComplete=$true;CancellationRequested=$false;NetworkChanged=$false;ContextChanged=$false;Samples=$samples;Checks=@();Metrics=$null;EvidencePath=$null;RunId=[guid]::NewGuid().ToString('D');ProbeId=[guid]::NewGuid().ToString('D');DurationMs=10;TransportPath='BoundInterfaceObserved';PathStatus='Passed'}
  }
 } $state
 function NewFixture {param([bool]$Running=$true)
  $script:caseNumber++;$state.Root=Join-Path $work ('case-'+$caseNumber);$null=[IO.Directory]::CreateDirectory($state.Root)
  [IO.File]::WriteAllText($engine,'inert fixture engine');$state.EngineHash=Hash $engine;$state.Now=[DateTimeOffset]::UtcNow
  $state.Network.Status='Available';$state.Network.Fingerprint=('A'*64);$state.Ninja=$false;$state.Fault='';$state.Starts=0;$state.Active=[int]$Running;$state.MaximumActive=[int]$Running;$state.Ops.Clear()
  $private=[Convert]::ToBase64String([byte[]](33..64));$serverKey=[Convert]::ToBase64String([byte[]](65..96));$conf=Join-Path $state.Root 'client.conf'
  [IO.File]::WriteAllText($conf,("[Interface]`nPrivateKey = $private`nAddress = 10.78.0.4/24`n[Peer]`nPublicKey = $serverKey`nEndpoint = 192.0.2.20:51820`nAllowedIPs = 0.0.0.0/0`nPersistentKeepalive = 25`n"))
  $n=Import-TCWireGuard -Root (Join-Path $state.Root 'Product') -Path $conf -Name 'safe fixture' -EnginePath $engine -WgPath $wg -DirectDnsIPv4 '192.0.2.53' -Providers @()
  $state.LineId=$n.id;$state.Source=$n.manifestPath;$state.Original=Join-Path $state.Root 'original.manifest.json'
  $m=JsonRead $n.manifestPath
  # This suite uses an inert runtime adapter, but its prepared profiles must
  # still carry the same explicit physical-network policy as current imports.
  $m|Add-Member NoteProperty NetworkPolicy ([pscustomobject]@{SchemaVersion=1;Kind='PhysicalInterface';InterfaceId='fixture-only';InterfaceName='Fixture';AddressPolicy='CurrentIPv4'})
  JsonWrite $n.manifestPath $m
  $original=CopyValue $m;$original.DeploymentApproved=$true;JsonWrite $state.Original $original
  $null=Register-TCLineProfiles -Root $state.Root -Id $n.id
  $envelope=[pscustomobject]@{Kind='TradeChannel.TransportInfo';Status='Available';NodeId='aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';RemoteOwnerId='bbbbbbbb-cccc-4ddd-8eee-ffffffffffff';ServerPublicKey=$m.ServerPublicKey;ClientPublicKey=$m.ClientPublicKey;ClientAddress=$m.ClientAddress;Transport=[pscustomobject]@{Type='tcp-reality';Server='192.0.2.20';Port=443;Uuid='cccccccc-dddd-4eee-8fff-aaaaaaaaaaaa';RealityPublicKey='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';RealityShortId='1234567890abcdef';ServerName='www.bing.com'}}
  $null=Prepare-TCTcpLineProfile -Root $state.Root -Id $n.id -TransportInfo $envelope
  JsonWrite (Join-Path $state.Root 'deployment.json') @{ManifestPath=$state.Original;Stage='FixtureOriginal'}
  JsonWrite (Join-Path $state.Root 'ui-preferences.json') @{NodeId=$n.id;ProfileId='Udp';Mode='Rule';Exit='HongKong';Daily='Direct';Agents='Direct';AgentIds=@();AgentCustom=@()}
  $state.Observed=[pscustomobject]@{State=$(if($Running){'Running'}else{'Stopped'});OwnershipKnown=$true;ManifestPath=$state.Original;CandidateSHA256=$m.CandidateSHA256;SessionId='fixture-original';SupervisorPid=101;EnginePid=102;SupervisorStartedAt='2026-01-01T00:00:00Z';EngineStartedAt='2026-01-01T00:00:01Z';Mode='rule';Exit='hk';Daily='direct';Guard=[pscustomobject]@{GuardState='Protected'}}
  JsonWrite (Join-Path $state.Root 'fixture-observed.json') $state.Observed
  $state.Before=@{Deployment=Hash (Join-Path $state.Root 'deployment.json');Index=Hash (Join-Path $state.Root 'Product\index.json');Preferences=Hash (Join-Path $state.Root 'ui-preferences.json');Original=Hash $state.Original}
 }
 function Seed {param([string]$Kind='Reachability',[string]$Winner='Tcp',[switch]$NoSave,[int]$EvidenceAgeMinutes=0)
  $state.Kind=$Kind;$state.Winner=$Winner;$state.Profiles=@((Line).Profiles)
  if($Kind -ne 'Reachability'){
   $batch=Invoke-TCProtocolComparison -Root $state.Root -NodeId $state.LineId -ExpectedExitIPv4 '192.0.2.40' -ExpectedExitSource 'ServerVerifiedTlsTrace'
   Check ($batch.Status -eq 'Completed') 'Fixture real comparison did not finish'
   foreach($p in $state.Profiles){$row=@($batch.Results|Where-Object ProfileId -eq $p.Id)[0];$e=ConvertTo-TCProtocolEvidence -Result $row.Result -Profile $p -NetworkContext $state.Network -Now $state.Now;$null=Set-TCLineProfileValidation -Root $state.Root -Id $state.LineId -ProfileId $p.Id -Validation $e}
  }else{
   $p=@($state.Profiles|Where-Object Id -eq $Winner)[0]
   $raw=[pscustomobject]@{Status='Passed';Code='CandidateReachabilityVerified';CandidateHash=$p.CandidateSHA256;ManifestHash=$p.ManifestSHA256;EngineSHA256=$state.EngineHash;ForwardingPassed=$true;ExpectedExitSource='ServerVerifiedTlsTrace';ExpectedExitIPv4='192.0.2.40';ObservedExitIPv4='192.0.2.40';CheckedAtUtc=$state.Now.AddMinutes(-$EvidenceAgeMinutes).ToString('o');CleanupComplete=$true;Checks=@([pscustomobject]@{Name='AddressHttps';Status='Passed'},[pscustomobject]@{Name='DomainDnsHttps';Status='Passed'});PathEvidence=[pscustomobject]@{Verified=$true;EligibleForRecommendation=$true;Kind='BoundInterfaceObserved';NetworkFingerprint=$state.Network.Fingerprint;Binding=[pscustomobject]@{InterfaceId='fixture-only'}}}
   $runId=[guid]::NewGuid().ToString('D');$probeBinding=$raw.PathEvidence.Binding
   $probeBinding|Add-Member NoteProperty NetworkFingerprint $state.Network.Fingerprint
   $raw|Add-Member NoteProperty NetworkFingerprint $state.Network.Fingerprint
   $raw|Add-Member NoteProperty RunId $runId
   $raw|Add-Member NoteProperty ConfigHash $p.ProbeSHA256
   $raw|Add-Member NoteProperty ProbeDerivativeRequired $true
   $raw|Add-Member NoteProperty ProbeDerivative ([pscustomobject]@{SchemaVersion=1;BaseCandidateSHA256=$p.CandidateSHA256;BaseManifestSHA256=$p.ManifestSHA256;ProbeSHA256=$p.ProbeSHA256;Binding=$probeBinding;EvidenceId=$runId})
   $e=ConvertTo-TCProtocolEvidence -Result $raw -Profile $p -NetworkContext $state.Network -Now $state.Now;$null=Set-TCLineProfileValidation -Root $state.Root -Id $state.LineId -ProfileId $p.Id -Validation $e
  }
  $l=Line;$r=Get-TCProtocolRecommendation -LineId $l.LineId -Profiles @($l.Profiles) -NetworkContext $state.Network -Now $state.Now
  Check ($r.Status -eq 'Recommended' -and $r.Source -eq $Kind -and $r.RecommendedProfileId -eq $Winner) ('Real producer returned wrong recommendation: '+$r.Source)
  if(-not $NoSave){$null=Set-TCLineRecommendation -Root $state.Root -Id $state.LineId -Recommendation $r -NetworkContext $state.Network}
  return $r
 }
 Case 'Old automatic provenance repair is read-only until explicit migration, CAS guarded and idempotent' {
  NewFixture;$null=Seed Reachability Tcp;$r=JsonRead (RecordPath);$old=CopyValue $r.SavedConnectionPreference
  foreach($p in @($old.Provenance.Profiles)){$p.PSObject.Properties.Remove('ManifestSHA256')}
  & $protocol {param($v)$v.Digest=PSelSavedDigest $v} $old
  $r.SavedConnectionPreference=$old;JsonWrite (RecordPath) $r;$before=Hash (RecordPath)
  $null=Line;Check ((Hash (RecordPath)) -ceq $before) 'list read must not persist repair'
  $repair=Repair-TCLineSavedPreference -Root $state.Root -Id $state.LineId -ExpectedRevision $r.Revision -ExpectedDigest $old.Digest
  Check ($repair.Repaired -and (Line).SavedConnectionPreference.Source -eq 'Reachability' -and (Line).SavedConnectionPreference.SavedAtUtc -ceq $old.SavedAtUtc) ('original provenance repaired under line locks: '+$repair.Code+'/'+$repair.DiagnosticCode)
  $after=Hash (RecordPath);$again=Repair-TCLineSavedPreference -Root $state.Root -Id $state.LineId
  Check ($again.Code -eq 'AlreadyCurrent' -and (Hash (RecordPath)) -ceq $after) 'repeat migration must not write'
  Reject {Repair-TCLineSavedPreference -Root $state.Root -Id $state.LineId -ExpectedRevision $r.Revision -ExpectedDigest $old.Digest} 'stale migration must reject changed revision'
  $null=Set-TCLinePreferredProfile -Root $state.Root -Id $state.LineId -ProfileId Udp
  $manualHash=Hash (RecordPath);$manual=Repair-TCLineSavedPreference -Root $state.Root -Id $state.LineId
  Check ($manual.Code -eq 'AlreadyCurrent' -and (Hash (RecordPath)) -ceq $manualHash -and (Line).SavedConnectionPreference.Source -eq 'UserChoice') 'later manual choice preserved'
  Reject {Set-TCLinePreferredProfile -Root $state.Root -Id $state.LineId -ProfileId Tcp -ExpectedRevision $r.Revision} 'card save must reject stale revision'
 }
 function Preview {Get-TCDefaultConnectionSwitchPreview -Root $state.Root -LineId $state.LineId}
 function Commit {param($Preview)Invoke-TCDefaultConnectionSwitch -Root $state.Root -LineId $state.LineId -PreviewToken $Preview.PreviewToken}
 function NoActor {Check ($state.Starts -eq 0 -and $state.Ops -notcontains 'StopOriginal' -and $state.Ops -notcontains 'ApplyIntent' -and $state.Ops -notcontains 'Verify') 'Invalid input reached a simulated actor'}
 function Restored {foreach($pair in @(@('Deployment','deployment.json'),@('Index','Product\index.json'),@('Preferences','ui-preferences.json'),@('Original','original.manifest.json'))){Check ((Hash (Join-Path $state.Root $pair[1])) -ceq $state.Before[$pair[0]]) ('Original bytes not restored: '+$pair[0])}}
 foreach($kind in @('Reachability','Performance','Stability','PolicyDefault')){foreach($winner in @('Udp','Tcp')){
  if($kind -eq 'PolicyDefault' -and $winner -eq 'Tcp'){continue}
  Case ($kind+' '+$winner+' producer -> persisted default -> expired preview -> simulated commit') {
   NewFixture;$null=Seed $kind $winner;$l=Line;$saved=$l.SavedConnectionPreference
   Check ($saved.Source -eq $kind -and $saved.Provenance.Kind -eq 'Recommendation' -and $l.PreferenceSource -eq $kind) 'Recommendation falsely recorded as manual choice'
   $hashes=@($l.Profiles|ForEach-Object {Hash $_.ManifestPath});$state.Now=$state.Now.AddDays(2)
   $choice=Get-TCLineDefaultProfile -Root $state.Root -Id $state.LineId -NetworkContext $state.Network
   Check ($choice.ProfileId -eq $winner -and -not $choice.RequiresCheck -and -not $choice.RecommendationCurrent -and $choice.RecommendationState -eq 'Expired') 'Expiry erased saved default or called old evidence current'
   $p=Preview;Check ($p.CanSwitch -and $p.ProfileId -eq $winner -and $p.SelectionMode -eq 'SavedDefault' -and $p.DefaultSource -eq $kind -and $p.PreviewToken -clike 'ct2:*' -and -not $p.RecommendationCurrent) ('Saved preview failed: '+$p.Message)
   NoActor;$r=Commit $p;Check ($r.Status -eq 'Completed' -and $r.Check.ProfileValidated -and $state.Ops -contains 'Verify' -and $state.MaximumActive -eq 1) 'Default skipped controlled post-activation verification'
   Check ((Line).SavedConnectionPreference.Digest -ceq $saved.Digest) 'Commit silently rewrote next default'
   $after=@((Line).Profiles|ForEach-Object {Hash $_.ManifestPath});Check (($hashes -join ',') -ceq ($after -join ',')) 'Immutable profiles rewritten'
  }
 }}
 Case 'Expiry alone after preview preserves approval; expired evidence cannot be current recommendation' {
  NewFixture;$null=Seed Reachability Tcp -EvidenceAgeMinutes 25;$p=Preview;$state.Now=$state.Now.AddMinutes(6)
  $again=Preview;Check ($again.CanSwitch -and $again.PreviewToken.Split(':')[-1] -cne $p.PreviewToken.Split(':')[-1]) 'New preview did not bind its expiry'
  $current=Get-TCDefaultConnectionSwitchPreview -Root $state.Root -LineId $state.LineId -SelectionMode CurrentRecommendation
  Check (-not $current.CanSwitch -and -not $current.PreviewToken) 'Expired evidence presented as current recommendation'
  Check ((Commit $p).Status -eq 'Completed') 'Expiry alone invalidated approved saved-default attempt'
 }
  Case 'Unset choice stays unset; verified legacy configured default remains compatible' {
  NewFixture;$p=Preview;Check (-not $p.CanSwitch -and -not $p.ProfileId -and -not $p.PreviewToken) 'Unset default became UDP';NoActor
  $record=JsonRead (RecordPath);$record.PSObject.Properties.Remove('SavedConnectionPreference');JsonWrite (RecordPath) $record
   $p=Preview;Check ($p.CanSwitch -and $p.ProfileId -eq 'Udp' -and $p.DefaultSource -eq 'ConfiguredDefault') 'Verified legacy configured choice was lost';NoActor
 }
 Case 'Genuine manual choice is durable; producer UserChoice alone does not fabricate a saved choice' {
  NewFixture;$l=Line;$r=Get-TCProtocolRecommendation -Profiles @($l.Profiles) -LineId $l.LineId -RequestedMode Tcp -NetworkContext $state.Network
  $null=Set-TCLineRecommendation -Root $state.Root -Id $state.LineId -Recommendation $r -NetworkContext $state.Network
  Check (-not (Line).SavedConnectionPreference) 'Recommendation setter invented genuine manual choice'
  $l=Set-TCLinePreferredProfile -Root $state.Root -Id $state.LineId -ProfileId Tcp
  Check ($l.SavedConnectionPreference.Source -eq 'UserChoice' -and $l.SavedConnectionPreference.Provenance.Kind -eq 'ManualChoice' -and -not $l.SavedConnectionPreference.Provenance.Recommendation) 'Manual provenance missing'
  $state.Now=$state.Now.AddDays(2);$p=Preview;Check $p.CanSwitch $p.Message;Check ((Commit $p).Status -eq 'Completed') 'Manual default failed checked activation'
 }
 Case 'AutoSave does not overwrite manual or previously saved recommendation defaults' {
  NewFixture;$null=Seed Reachability Tcp;$saved=(Line).SavedConnectionPreference;$null=Seed PolicyDefault Udp
  $l=Line;Check ($l.SavedConnectionPreference.Digest -ceq $saved.Digest -and $l.PreferredProfileId -eq 'Tcp' -and $l.Recommendation.RecommendedProfileId -eq 'Udp' -and $l.PreferenceSource -eq 'Reachability') 'AutoSave silently changed recommended default';NoActor
  $l=Set-TCLinePreferredProfile -Root $state.Root -Id $state.LineId -ProfileId Tcp;$saved=$l.SavedConnectionPreference;$null=Seed PolicyDefault Udp
  Check ((Line).SavedConnectionPreference.Digest -ceq $saved.Digest -and (Line).PreferenceSource -eq 'UserChoice') 'AutoSave overwrote manual default';NoActor
 }
 Case 'Saving an expired recommendation is rejected and does not establish default' {
  NewFixture;$r=Seed Reachability Tcp -NoSave;$state.Now=$state.Now.AddDays(2);$before=Hash (RecordPath)
  Reject {Set-TCLineRecommendation -Root $state.Root -Id $state.LineId -Recommendation $r -NetworkContext $state.Network} 'Expired recommendation saved'
  Check ((Hash (RecordPath)) -ceq $before -and -not (Preview).CanSwitch) 'Expired save altered default';NoActor
 }
 foreach($mutation in @('SavedSource','SavedProfile','SavedBinding','Origin','CurrentSource','CurrentEvidence','Cleanup','SelectedFailed','Unknown','Blocked','Future')){
  Case ('Expired saved default rejects '+$mutation) {
   NewFixture;$null=Seed;$state.Now=$state.Now.AddDays(2);$record=JsonRead (RecordPath)
   switch($mutation){
    'SavedSource'{$record.SavedConnectionPreference.Source='UserChoice'}
    'SavedProfile'{$record.SavedConnectionPreference.ProfileId='Udp'}
    'SavedBinding'{$record.SavedConnectionPreference.Binding.CandidateSHA256=('0'*64)}
    'Origin'{$record.SavedConnectionPreference.Provenance.Recommendation.Source='PolicyDefault'}
    'CurrentSource'{$record.Recommendation.Source='UserChoice'}
    'CurrentEvidence'{$record.Profiles[1].Validation.EvidenceId=('0'*64)}
    'Cleanup'{$record.Profiles[1].Validation.CleanupComplete=$false}
    'AllFailed'{foreach($p in $record.Profiles){$p.Validation=[pscustomobject]@{CandidateSHA256=$p.CandidateSHA256;Status='Failed';Code='CandidateForwardingFailed';CleanupComplete=$true}};$record.Recommendation.Status='Unavailable'}
    'SelectedFailed'{$record.Profiles[1].Validation.Status='Failed'}
    'Unknown'{$record.Profiles[1].Validation.Status='OutcomeUnknown'}
    'Inconclusive'{$record.Recommendation.Status='Inconclusive'}
    'Blocked'{$record.Recommendation.Status='Blocked'}
    'Future'{$record.Recommendation.CheckedAtUtc=$state.Now.AddMinutes(5).ToString('o')}
   };JsonWrite (RecordPath) $record
   # A refused preview retains ProfileId for the repair/navigation UI. Only
   # CanSwitch plus a valid token can authorize the subsequent transaction.
   $p=Preview;Check (-not $p.CanSwitch -and -not $p.PreviewToken -and $p.Code) ('Expiry bypassed '+$mutation);NoActor
  }
 }
 foreach($mutation in @('Config','Manifest','Identity','Engine','Revision','PendingTransaction','UnknownOwnership')){
  Case ('Default protects '+$mutation+' before stopping') {
   NewFixture;$null=Seed;$p=Preview;Check $p.CanSwitch $p.Message;$l=Line;$target=@($l.Profiles|Where-Object Id -eq 'Tcp')[0]
   switch($mutation){
    'Config'{$m=JsonRead $target.ManifestPath;[IO.File]::AppendAllText($m.CandidatePath,' ')}
    'Manifest'{[IO.File]::AppendAllText($target.ManifestPath,' ')}
    'Identity'{$m=JsonRead $target.ManifestPath;$m.ClientPublicKey=[Convert]::ToBase64String([byte[]](97..128));JsonWrite $target.ManifestPath $m}
    'Engine'{[IO.File]::AppendAllText($engine,' changed')}
    'Revision'{$record=JsonRead (RecordPath);$record.Profiles[1].Revision++;JsonWrite (RecordPath) $record}
    'PendingTransaction'{$dir=Join-Path $state.Root 'connection-transactions';$null=[IO.Directory]::CreateDirectory($dir);JsonWrite (Join-Path $dir 'pending.json') @{Status='OutcomeUnknown';Phase='StartTarget'}}
    'UnknownOwnership'{$state.Observed.OwnershipKnown=$false;JsonWrite (Join-Path $state.Root 'fixture-observed.json') $state.Observed}
   }
   Check (-not (Preview).CanSwitch) ('Default preview ignored '+$mutation);Reject {Commit $p} ('Stale commit ignored '+$mutation);NoActor
  }
 }
 foreach($mutation in @('Default','Intent','Session','TokenExpired')){
  Case ('Worker-style default commit rejects stale '+$mutation+' preview') {
   NewFixture;$null=Seed;$p=Preview;Check $p.CanSwitch $p.Message
   switch($mutation){
    'Default'{$null=Set-TCLinePreferredProfile -Root $state.Root -Id $state.LineId -ProfileId Udp}
    'Intent'{$v=JsonRead (Join-Path $state.Root 'ui-preferences.json');$v.Mode='Global';JsonWrite (Join-Path $state.Root 'ui-preferences.json') $v}
    'Session'{$state.Observed.SessionId='foreign-session';JsonWrite (Join-Path $state.Root 'fixture-observed.json') $state.Observed}
    'TokenExpired'{$state.Now=$state.Now.AddMinutes(11)}
   };Reject {Commit $p} ('Stale preview committed: '+$mutation);NoActor
  }
 }
 foreach($running in @($true,$false)){
  Case ('Failed post-activation verification rolls back running='+$running) {
   NewFixture $running;$null=Seed;$p=Preview;$state.Fault='Verify';$r=Commit $p
   Check ($r.Status -eq 'RolledBack' -and $r.ConfigurationRestored -and $r.ConnectionRestored -and $state.MaximumActive -le 1) 'Failed activation did not restore original state';Restored
   Check ($state.Observed.State -eq $(if($running){'Running'}else{'Stopped'})) 'Rollback did not preserve original running state'
  }
 }
 Case 'A newly blocked result after stopping restores the original session' {
  NewFixture;$null=Seed;$p=Preview;$state.Fault='FailureAfterStop';$r=Commit $p
  Check ($r.Status -eq 'RolledBack' -and $state.Starts -eq 1 -and $r.ConnectionRestored) 'Blocked state after stop launched target or skipped recovery';Restored
 }
 Case 'NinjaTrader protects preview and commit independently' {
  NewFixture;$null=Seed;$state.Ninja=$true;Check (-not (Preview).CanSwitch) 'Ninja preview allowed';NoActor
  $state.Ninja=$false;$p=Preview;$state.Ninja=$true;Reject {Commit $p} 'Ninja commit allowed';NoActor;Restored
  Check (-not [IO.Directory]::Exists((Join-Path $state.Root 'connection-transactions'))) 'Ninja gate wrote a transaction journal'
 }
 Case 'Active identity stays protected from independent probing; saved preview does not probe or rewrite it' {
  NewFixture;$null=Seed;$state.Now=$state.Now.AddDays(2);$l=Line;$hashes=@($l.Profiles|ForEach-Object {Hash $_.ManifestPath})
  JsonWrite (Join-Path $state.Root 'runtime.json') @{State='Running';ManifestPath=$state.Source;ClientPublicKey=$l.ClientPublicKey}
  $binding=Prepare-TCLineProbeBindings -Root $state.Root -Id $state.LineId
  Check ($binding.State -eq 'Blocked' -and $binding.Code -eq 'ActiveIdentity' -and -not $binding.Prepared) 'Active identity independently probed'
  $p=Preview;Check $p.CanSwitch $p.Message;NoActor;Restored
  Check (($hashes -join ',') -ceq (@((Line).Profiles|ForEach-Object {Hash $_.ManifestPath}) -join ',')) 'Active profile rewritten'
 }
 Case 'Trustworthy expired historical recommendation migrates read-only; mismatched origin fails closed' {
  NewFixture;$null=Seed;$record=JsonRead (RecordPath);$record.PSObject.Properties.Remove('SavedConnectionPreference');JsonWrite (RecordPath) $record;$before=Hash (RecordPath);$state.Now=$state.Now.AddDays(2)
  $l=Line;Check ($l.SavedConnectionPreference.Migrated -and $l.SavedConnectionPreference.Source -eq 'Reachability' -and (Preview).CanSwitch) 'Fully bound historical origin did not migrate'
  Check ((Hash (RecordPath)) -ceq $before) 'Migration read rewrote metadata';NoActor
  $record.PreferenceUpdatedAt=$null;JsonWrite (RecordPath) $record;Check (-not (Preview).CanSwitch) 'Unrecorded origin migrated';NoActor
 }
 Case 'Historical manual origin requires recorded request and exact configuration binding' {
  NewFixture;$l=Set-TCLinePreferredProfile -Root $state.Root -Id $state.LineId -ProfileId Tcp
  $origin=Get-TCProtocolRecommendation -Profiles @($l.Profiles) -LineId $l.LineId -RequestedMode Tcp -NetworkContext $state.Network
  $record=JsonRead (RecordPath);$record.PSObject.Properties.Remove('SavedConnectionPreference');$record.Recommendation=$origin;JsonWrite (RecordPath) $record
  $l=Line;Check ($l.SavedConnectionPreference.Migrated -and $l.SavedConnectionPreference.Source -eq 'UserChoice' -and (Preview).CanSwitch) 'Bound historical manual choice did not migrate';NoActor
  $record.Recommendation.RequestedProfileId='Udp';JsonWrite (RecordPath) $record
  Check (-not (Preview).CanSwitch) 'Ambiguous manual origin migrated';NoActor
 }
 Case 'Archived generation blocks saved and explicit paths; only IP matching does not bind' {
  NewFixture;$null=Seed;$l=Line;$dir=Join-Path $state.Root 'servers';$null=[IO.Directory]::CreateDirectory($dir)
  $registry=[pscustomobject]@{SchemaVersion=1;Servers=@([pscustomobject]@{LocalRecordId='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';RecordState='Archived';ServerPublicKey=$l.ServerPublicKey;LinkedNodeIds=@($l.LineId);Connection=[pscustomobject]@{Host='192.0.2.20'}})}
  JsonWrite (Join-Path $dir 'registry.json') $registry
  Check ((Line).ServerConnectionBlock -eq 'ServerArchived' -and (Line).ServerConnectionMessage -match '归档') 'Line view omitted archived explanation'
  $p=Preview;$explicit=Get-TCConnectionSwitchPreview -Root $state.Root -LineId $state.LineId -ProfileId Tcp
  Check (-not $p.CanSwitch -and $p.Message -match 'ServerArchived' -and -not $explicit.CanSwitch -and $explicit.Message -match 'ServerArchived') 'Archived generation reached connection preview';NoActor
  $registry.Servers[0].LinkedNodeIds=@('eeeeeeee-ffff-4aaa-8bbb-cccccccccccc');$registry.Servers[0].ServerPublicKey=[Convert]::ToBase64String([byte[]](97..128));JsonWrite (Join-Path $dir 'registry.json') $registry
  Check ((Preview).CanSwitch -and (Get-TCConnectionSwitchPreview -Root $state.Root -LineId $state.LineId -ProfileId Tcp).CanSwitch) 'Unrelated same IP blocked legacy compatibility';NoActor
  $registry.Servers[0].ServerPublicKey=$l.ServerPublicKey;JsonWrite (Join-Path $dir 'registry.json') $registry
  Check (-not (Preview).CanSwitch -and -not (Get-TCConnectionSwitchPreview -Root $state.Root -LineId $state.LineId -ProfileId Tcp).CanSwitch) 'Known archived public identity allowed old keys';NoActor
  $registry.Servers[0].LinkedNodeIds=@($state.LineId);$registry.Servers[0].RecordState='Active';$registry.Servers[0].ServerPublicKey=[Convert]::ToBase64String([byte[]](97..128));JsonWrite (Join-Path $dir 'registry.json') $registry
  Check (-not (Preview).CanSwitch -and -not (Get-TCConnectionSwitchPreview -Root $state.Root -LineId $state.LineId -ProfileId Tcp).CanSwitch) 'Linked key mismatch accepted by IP';NoActor
 }
 Case 'Archiving after preview invalidates both worker-style commit paths before stopping' {
  NewFixture;$null=Seed;$l=Line;$dir=Join-Path $state.Root 'servers';$null=[IO.Directory]::CreateDirectory($dir)
  $registry=[pscustomobject]@{SchemaVersion=1;Servers=@([pscustomobject]@{LocalRecordId='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';RecordState='Active';ServerPublicKey=$l.ServerPublicKey;LinkedNodeIds=@($l.LineId)})};JsonWrite (Join-Path $dir 'registry.json') $registry
  $p=Preview;$explicit=Get-TCConnectionSwitchPreview -Root $state.Root -LineId $state.LineId -ProfileId Tcp
  Check ($p.CanSwitch -and $explicit.CanSwitch) 'Active registry preview failed'
  $registry.Servers[0].RecordState='Archived';JsonWrite (Join-Path $dir 'registry.json') $registry
  Reject {Commit $p} 'Archived saved default committed'
  Reject {Invoke-TCConnectionSwitch -Root $state.Root -LineId $state.LineId -ProfileId Tcp -PreviewToken $explicit.PreviewToken} 'Archived explicit profile committed';NoActor;Restored
 }
 Case 'UI separates current connection, saved default and expired recommendation, and explains archived generation' {
  NewFixture;$null=Seed
  $script:PackageRoot=$testPackage;$script:DeployUI=$null
  . (Join-Path $package 'ui\ConnectionProfilePages.ps1')
  function UIExpired {param($Value)if(-not $Value){return $false};try{[DateTimeOffset]::Parse([string]$Value) -le $state.Now}catch{$true}}
  $view=LineRecommendationView (Line);Check ($view.CanConnect -and $view.RecommendationCurrent) 'UI did not qualify fresh producer evidence'
  $state.Network.Fingerprint=('B'*64);$view=LineRecommendationView (Line)
  Check ($view.CanConnect -and -not $view.RecommendationCurrent -and $view.OldRecommendationLabel) 'UI called evidence current after underlay drift'
  $state.Network.Fingerprint=('A'*64);$state.Now=$state.Now.AddDays(2)
  $view=LineRecommendationView (Line)
  Check ($view.CanConnect -and $view.ProfileId -eq 'Tcp' -and $view.SelectionMode -eq 'SavedDefault' -and $view.Button -eq '连接 TCP 并检查' -and $view.OldRecommendationLabel -match '已过期' -and -not $view.RecommendationCurrent) ('UI default view failed: '+($view|Select-Object CanConnect,ProfileId,SelectionMode,Button,OldRecommendationLabel,RecommendationCurrent,Reason|ConvertTo-Json -Compress))
  $l=Line;$dir=Join-Path $state.Root 'servers';$null=[IO.Directory]::CreateDirectory($dir)
  JsonWrite (Join-Path $dir 'registry.json') @{SchemaVersion=1;Servers=@(@{LocalRecordId='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';RecordState='Archived';ServerPublicKey=$l.ServerPublicKey;LinkedNodeIds=@($l.LineId)})}
  $view=LineRecommendationView (Line);Check (-not $view.CanConnect -and $view.Reason -match '归档') 'UI allowed or concealed archived generation'
 }
 Case 'Preview expiry cannot be extended by changing its timestamp' {
  NewFixture;$null=Seed;$p=Preview;$parts=$p.PreviewToken.Split(':');$p.PreviewToken=$parts[0]+':'+([long]$parts[1]+30)+':'+$parts[2]
  Reject {Commit $p} 'Tampered approval expiry committed';NoActor
 }
 foreach($receipt in @('Starting','TraceUnknown','CleanupIncomplete')){
  Case ('Expired default cannot bypass persisted probe '+$receipt) {
   NewFixture;$null=Seed;$p=Preview;$state.Now=$state.Now.AddDays(2);$run=[guid]::NewGuid().ToString('D');$dir=Join-Path $state.Root ('probes\'+$run);$null=[IO.Directory]::CreateDirectory($dir)
   $owner=[pscustomobject]@{SchemaVersion=1;RunId=$run;NodeId=$state.LineId;State='Stopped';TraceGuid=$null;TraceState='NotStarted'}
   switch($receipt){'Starting'{$owner.State='Starting'}'TraceUnknown'{$owner.TraceGuid=[guid]::NewGuid().ToString('D');$owner.TraceState='Unknown'}'CleanupIncomplete'{JsonWrite (Join-Path $dir 'result.json') @{CleanupComplete=$false;Code='ProbeCleanupFailed'}}}
   JsonWrite (Join-Path $dir 'ownership.json') $owner
   $p=Preview;Check (-not $p.CanSwitch -and $p.Message -match 'NeedsRecovery') 'Probe receipt was treated as evidence expiry';NoActor
   Check ((JsonRead (Join-Path $dir 'ownership.json')).State -ceq $owner.State) 'Default preview performed probe recovery'
  }
 }
 Check ($cases.Count -gt 0) 'CasePattern did not select any meaningful tests'
 Check ($state.ActualTouches -eq 0) 'Production process/network/controller was touched'
 Check (-not (Get-Module RuntimeBridge)) 'Production controller module was loaded'
 $result=[pscustomobject]@{Passed=$true;CaseCount=$cases.Count;Checks=$checks;Cases=$cases.ToArray();FixtureScope='DisposableTempOnly';ActualProcessTouches=$state.ActualTouches;ActualNativeProcesses=0;RealNetworkChanges=0;ProductionWrites=0;ProductionControllerLoaded=$false;SimulatedNativeChecks=$state.NativeCalls;Adapter='ModulePrivateTemporaryScriptBlock';Timestamp=[DateTimeOffset]::UtcNow.ToString('o')}
}catch{$failure=$_.Exception.Message;$result=[pscustomobject]@{Passed=$false;Error=$failure;Cases=$cases.ToArray();ActualProcessTouches=$state.ActualTouches;ActualNativeProcesses=0;RealNetworkChanges=0;ProductionWrites=0;ProductionControllerLoaded=[bool](Get-Module RuntimeBridge)}}
finally{
 foreach($module in @($transactions,$lines,$protocol)){if($module){& $module {$script:PreferenceClock=$null;$script:TestAdapter=$null}}}
 if($ReportPath){$fullReport=[IO.Path]::GetFullPath($ReportPath);$null=[IO.Directory]::CreateDirectory((Split-Path $fullReport -Parent));[IO.File]::WriteAllText($fullReport,($result|ConvertTo-Json -Depth 30),(New-Object Text.UTF8Encoding($true)))}
 Get-Module | Where-Object {$_.Path -and $_.Path.StartsWith($testPackage.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)} | Remove-Module -Force
 $full=[IO.Path]::GetFullPath($work);$tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if(-not $full.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -cnotmatch '^TC-saved-preference-[a-f0-9]{32}$'){throw 'Cleanup rejects non-fixture directory'}
 Remove-Item -LiteralPath $full -Recurse -Force
}
if($failure){throw $failure}
$result
