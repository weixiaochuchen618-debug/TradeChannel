#requires -Version 5.1
#requires -PSEdition Desktop
[CmdletBinding()]param([string]$SourceDirectory=(Split-Path $PSScriptRoot -Parent),[Parameter(Mandatory=$true)][string]$ReportPath,[switch]$ExpectLegacyDefect,[switch]$ContinuousOnly)
$ErrorActionPreference='Stop';Set-StrictMode -Version 2
$env:PSModulePath=Join-Path $PSHOME 'Modules'
Import-Module (Join-Path $SourceDirectory 'DeploymentStore.psm1') -DisableNameChecking
Import-Module (Join-Path $SourceDirectory 'ServerRegistry.psm1') -DisableNameChecking
Import-Module (Join-Path $SourceDirectory 'RuntimeObservability.psm1') -DisableNameChecking
$history=Import-Module (Join-Path $SourceDirectory 'OperationHistory.psm1') -PassThru -DisableNameChecking
Import-Module (Join-Path $SourceDirectory 'LineQuality.psm1') -DisableNameChecking
Import-Module (Join-Path $SourceDirectory 'StandbyQuality.psm1') -DisableNameChecking
$work=New-TCDDirectory (Join-Path ([IO.Path]::GetTempPath()) ('tc-cleanup-telemetry-'+[guid]::NewGuid().ToString('N')))
$checks=New-Object 'Collections.Generic.List[string]';$cases=New-Object 'Collections.Generic.List[object]';$failure='';$stack=''
function Check {param($Value,[string]$Name)if(-not $Value){throw $Name};$checks.Add($Name)}
function Put {param([string]$Path,$Value)if(-not [IO.Path]::GetFullPath($Path).StartsWith($work+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Fixture path escape'};Write-TCDJson $Path $Value}
function Hash {param([string]$Path)(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash}
$lineMeasure={param($Context,$BudgetMilliseconds,$Data)@{Status='Measured';Reason='Measured';ContextKey=$Context.Key;Source='ControllerDelay';Outbound=$Context.Binding.Exit;LatencyMs=80}}
$standbyMeasure={param($Candidate,$BudgetMilliseconds,$Data)@{Status='Measured';Reason='Measured';CandidateKey=$Candidate.Key;Source='TcpConnect';LatencyMs=45}}
function Sample {param($f,[string]$Kind)
 $f.Now=$f.Now.AddSeconds(60);$f.Overview.ObservedAt=$f.Now.ToString('o');$at=$f.Now;$clock={$at}.GetNewClosure()
 switch($Kind){
  Quality {$r=Invoke-TCLineQualitySample -Root $f.Root -Overview $f.Overview -Clock $clock -Measure $lineMeasure;Check $r.Sampled ('Real quality sampler writes '+$f.Name)}
  Standby {$r=Invoke-TCStandbyQualitySample -Root $f.Root -Overview $f.Overview -Candidates $f.Candidates -Clock $clock -Measure $standbyMeasure;Check $r.Sampled ('Real standby sampler writes '+$f.Name+': '+$r.Reason)}
  Heartbeat {$r=Observe-TCRuntimeState -Root $f.Root -Overview $f.Overview;Check ($r.Observed -and $r.EventsAdded -eq 0) ('Real heartbeat writes without a state transition '+$f.Name)}
 }
}
function Fixture {param([string]$Name)
 $root=New-TCDDirectory (Join-Path $work $Name);$nodes=@();$lines=@();$runs=@();$servers=@()
 foreach($n in 1,2){
  $server=Set-TCServerRecord -Root $root -Connection @{Host=('192.0.2.'+$n);Port=22;User='root';IdentityFile=''} -Name ('fixture-'+$n) -ServerInfo @{RemoteOwnerId=[guid]::NewGuid().ToString();Node=@{NodeId=[guid]::NewGuid().ToString();ServerPublicKey=([string]$n*43+'=')}};$servers+=,$server
  $line=[guid]::NewGuid().ToString();$lines+=,$line;$manifest=Join-Path $root ('Product\nodes\'+$line+'\manifest.json')
  Put $manifest @{TCLineId=$line;TCManagedNodeId=$line;ServerPublicKey=([string]$n*43+'=');ClientPublicKey=('client-'+$line)}
  Put (Join-Path (Split-Path $manifest) 'device.key') @{FixtureOnly=$line}
  Put (Join-Path $root ('Product\lines\'+$line+'\line.json')) @{SchemaVersion=2;LineId=$line;Profiles=@();SourceManifestPath=$manifest;ServerPublicKey=([string]$n*43+'=')}
  $nodes+=,@{id=$line;name=('fixture-'+$n);manifestPath=$manifest};$run=[guid]::NewGuid().ToString();$runs+=,$run
  Put (Join-Path $root ('deployments\runs\'+$run+'\state.json')) @{SchemaVersion=1;RunId=$run;ServerRecordId=$server.LocalRecordId;Intent='New';Revision=1;Status='Complete';Stage='ReadyInactive';CandidateNodeId=$line;CandidateManifestPath=$manifest;CreatedAtUtc=[DateTime]::UtcNow.ToString('o');UpdatedAtUtc=[DateTime]::UtcNow.ToString('o')}
  $null=Set-TCServerLink -Root $root -ServerId $server.LocalRecordId -NodeId $line
 }
 Put (Join-Path $root 'Product\index.json') @{schemaVersion=1;nodes=$nodes}
 $started=[DateTimeOffset]::UtcNow.AddHours(-1).ToString('o');$session=[guid]::NewGuid().ToString('N')
 Put (Join-Path $root 'deployment.json') @{LineId=$lines[0];ManifestPath=$nodes[0].manifestPath}
 Put (Join-Path $root 'runtime.json') @{State='Running';OwnershipKnown=$true;LineId=$lines[0];ManifestPath=$nodes[0].manifestPath;SessionId=$session;EngineStartedAt=$started}
 $now=[DateTimeOffset]::UtcNow.AddMinutes(-5)
 $view=[pscustomobject]@{Running=$true;StateKey='Connected';GuardState='Protected';SessionId=$session;ActiveLineId=$lines[0];ActiveProfileId='Udp';ProfileBindingVerified=$true;Exit='hk';ConfigHash=('A'*64);EnginePid=1234;ConnectedSince=$started;ManifestPath=$nodes[0].manifestPath;Mode='rule';ObservedAt=$now.ToString('o')}
 $candidates=@(foreach($line in @($lines[1],[guid]::NewGuid().ToString())){[pscustomobject]@{NodeId=$line;ProfileId='Tcp';Exit='hk';Host='127.0.0.1';Port=443;ConfigHash=('B'*64)}})
 $f=[pscustomobject]@{Name=$Name;Root=$root;Active=$lines[0];Target=$lines[1];TargetManifest=$nodes[1].manifestPath;Nodes=$nodes;Runs=$runs;Servers=$servers;Overview=$view;Candidates=$candidates;Now=$now;QualityPath=(Join-Path $root 'Product\line-quality.json');StandbyPath=(Join-Path $root 'Product\standby-quality.json')}
 # Real samplers create a target's archived series and then the active A series.
 $other=$view|ConvertTo-Json -Depth 8|ConvertFrom-Json;$other.ActiveLineId=$f.Target;$other.ManifestPath=$f.TargetManifest;$at=$now;$clock={$at}.GetNewClosure()
 $r=Invoke-TCLineQualitySample -Root $root -Overview $other -Clock $clock -Measure $lineMeasure;Check $r.Sampled 'Real sampler seeds target B history'
 Sample $f Quality;Sample $f Standby
 $null=Observe-TCRuntimeState -Root $root -Overview $view
 $shared=[guid]::NewGuid().ToString();foreach($s in $servers){$null=Set-TCServerRecord -Root $root -Id $s.LocalRecordId -SavedLoginRef $shared}
 Put (Join-Path $root ('credentials\'+$shared+'.json')) @{Protected='shared-fixture-only'}
 $f|Add-Member NoteProperty ProtectedPaths @((Join-Path $root 'deployment.json'),(Join-Path $root 'runtime.json'),$nodes[0].manifestPath,(Join-Path (Split-Path $nodes[0].manifestPath) 'device.key'),(Join-Path $root ('Product\lines\'+$f.Active+'\line.json')),(Join-Path $root ('credentials\'+$shared+'.json')))
 return $f
}
function Plan {param($f)& $history {param($r,$id)LCPlan $r @('Line:'+$id)} $f.Root $f.Target}
function Commit {param($f,$preview)
 try{$r=Remove-TCLocalDeploymentData -Root $f.Root -PreviewToken $preview.PreviewToken;[pscustomobject]@{Ok=$true;Code='';Result=$r}}
 catch{[pscustomobject]@{Ok=$false;Code=$_.Exception.Message;Result=$null}}
}
function PreservedQuality {param($f,$q=$null,$sq=$null)
 if(-not $q){$q=Read-TCDJson $f.QualityPath};if(-not $sq){$sq=Read-TCDJson $f.StandbyPath}
 # Revisions and CandidateSetKey are intentionally invalidated by cleanup.
 Get-TCDDigest @{Binding=$q.Binding;BindingKey=$q.BindingKey;SeriesId=$q.SeriesId;Samples=$q.Samples;LastAttemptAtUtc=$q.LastAttemptAtUtc;BadCount=$q.BadCount;RecoveryCount=$q.RecoveryCount;AlertLatched=$q.AlertLatched;LastAlert=$q.LastAlert;ArchivedSeries=@($q.ArchivedSeries|Where-Object {$_.Binding.NodeId -cne $f.Target});StandbyBinding=$sq.Binding;StandbyBindingKey=$sq.BindingKey;StandbyAttempt=$sq.LastAttemptAtUtc;Entries=@($sq.Entries|Where-Object {$_.Binding.NodeId -cne $f.Target})}
}
try{
 foreach($kind in $(if($ContinuousOnly){@()}else{@('Heartbeat','Quality','Standby')})){
  $f=Fixture $kind;$protected=@($f.ProtectedPaths|ForEach-Object {Hash $_})
  $rounds=if($ExpectLegacyDefect -and $kind -ne 'Heartbeat'){3}else{1}
  for($i=0;$i -lt $rounds;$i++){
   $before=Plan $f;$preview=New-TCLocalDeploymentCleanupPreview -Root $f.Root -Ids @('Line:'+$f.Target)
   Check ($preview.PreviewToken -and $preview.LineCount -eq 1 -and $preview.Blocked.Count -eq 0) 'Only idle B is previewed while A stays connected'
   $cacheHashes=@((Hash $f.QualityPath),(Hash $f.StandbyPath));Sample $f $kind;$after=Plan $f
   $preserved=PreservedQuality $f;$result=Commit $f $preview
   $changed=@(foreach($path in $before.Context.Files.Keys){if($before.Context.Files[$path].Stamp -cne $after.Context.Files[$path].Stamp){$path.Substring($f.Root.Length+1)}})
   $cases.Add([pscustomobject]@{Name=$kind;Round=$i+1;BeforeDigest=$before.Digest;AfterDigest=$after.Digest;OwnershipBefore=$before.Context.Digest;OwnershipAfter=$after.Context.Digest;ChangedOwnershipFiles=$changed;CacheHashesBefore=$cacheHashes;CacheHashesAfter=@((Hash $f.QualityPath),(Hash $f.StandbyPath));ReplacementBefore=(Get-TCDDigest $before.Replacements);ReplacementAfter=(Get-TCDDigest $after.Replacements);Ok=$result.Ok;Code=$result.Code})
   if($ExpectLegacyDefect -and $kind -ne 'Heartbeat'){
    Check (-not $result.Ok -and $result.Code.Contains('CleanupPreviewStale') -and [IO.File]::Exists($f.TargetManifest)) ('Original rejects ordinary '+$kind+' round '+($i+1))
    Check ($before.Context.Digest -ceq $after.Context.Digest -and $before.Digest -cne $after.Digest) 'Only cache fingerprints and replacement payloads changed, ownership stayed identical'
   }else{
    Check ($result.Ok -and $result.Result.DataDeleted -and -not [IO.File]::Exists($f.TargetManifest)) ('Cleanup succeeds after ordinary '+$kind)
    Check ((PreservedQuality $f) -ceq $preserved) 'Latest active A samples, alert state and other-line standby entries survive'
    $q=Read-TCDJson $f.QualityPath;$sq=Read-TCDJson $f.StandbyPath
    Check (-not @($q.ArchivedSeries|Where-Object {$_.Binding.NodeId -ceq $f.Target}).Count -and -not @($sq.Entries|Where-Object {$_.Binding.NodeId -ceq $f.Target}).Count) 'Only B quality ownership is removed'
    $again=Commit $f $preview;Check ($again.Ok -and $again.Result.AlreadyApplied) 'Completed cleanup confirmation is idempotent'
   }
   Check ((Get-TCDDigest @($f.ProtectedPaths|ForEach-Object {Hash $_})) -ceq (Get-TCDDigest $protected)) 'Current runtime, active line, key and shared credential bytes are unchanged'
  }
 }
 if(-not $ExpectLegacyDefect -and -not $ContinuousOnly){
  # Force writes between the unlocked plan and lock acquisition, then attempt
  # real writes during the locked replan. No timer-dependent races or sockets.
  $f=Fixture 'lock-boundaries';$preview=New-TCLocalDeploymentCleanupPreview $f.Root @('Line:'+$f.Target)
  $protected=@($f.ProtectedPaths|ForEach-Object {Hash $_});$race=@{Quality=$null;Standby=$null;StoreBusy=$false;Heartbeats=0;BeforeLockWrites=0}
  $beforeLock={
   $f.Now=$f.Now.AddSeconds(60);$f.Overview.ObservedAt=$f.Now.ToString('o');$at=$f.Now;$clock={$at}.GetNewClosure()
   $a=Invoke-TCLineQualitySample -Root $f.Root -Overview $f.Overview -Clock $clock -Measure $lineMeasure
   $b=Invoke-TCStandbyQualitySample -Root $f.Root -Overview $f.Overview -Candidates $f.Candidates -Clock $clock -Measure $standbyMeasure
   $race.BeforeLockWrites=[int]$a.Sampled+[int]$b.Sampled
   $race.Quality=Read-TCDJson $f.QualityPath;$race.Standby=Read-TCDJson $f.StandbyPath
  }.GetNewClosure()
  $insideLock={
   $f.Now=$f.Now.AddSeconds(60);$f.Overview.ObservedAt=$f.Now.ToString('o');$at=$f.Now;$clock={$at}.GetNewClosure()
   $a=Invoke-TCLineQualitySample -Root $f.Root -Overview $f.Overview -Clock $clock -Measure {throw 'Locked sampler must not measure'}
   $b=Invoke-TCStandbyQualitySample -Root $f.Root -Overview $f.Overview -Candidates $f.Candidates -Clock $clock -Measure {throw 'Locked sampler must not measure'}
   $race.StoreBusy=($a.Reason -ceq 'StoreBusy' -and $b.Reason -ceq 'StoreBusy' -and -not $a.Sampled -and -not $b.Sampled)
   foreach($i in 1..3){$o=Observe-TCRuntimeState -Root $f.Root -Overview $f.Overview;if($o.Observed -and $o.EventsAdded -eq 0){$race.Heartbeats++}}
  }.GetNewClosure()
  $originalOpen=& $history {(Get-Command LCOpenLocks).ScriptBlock};$originalQuality=& $history {(Get-Command LCQualityCaches).ScriptBlock}
  & $history {param($Open,$Quality,$Before,$Inside)
   $script:TelemetryOriginalOpen=$Open;$script:TelemetryOriginalQuality=$Quality;$script:TelemetryBefore=$Before;$script:TelemetryInside=$Inside;$script:TelemetryInsideDone=$false
   function script:LCOpenLocks {param($Plan)& $script:TelemetryBefore;& $script:TelemetryOriginalOpen $Plan}
   function script:LCQualityCaches {param($Plan)
    if(-not $script:TelemetryInsideDone -and (Join-Path $Plan.Root 'Product\.store.lock') -in $Plan.Context.OwnedLocks){$script:TelemetryInsideDone=$true;& $script:TelemetryInside}
    & $script:TelemetryOriginalQuality $Plan
   }
  } $originalOpen $originalQuality $beforeLock $insideLock
  try{$result=Commit $f $preview}finally{& $history {param($Open,$Quality)Set-Item Function:script:LCOpenLocks $Open;Set-Item Function:script:LCQualityCaches $Quality} $originalOpen $originalQuality}
  Check ($result.Ok -and $race.BeforeLockWrites -eq 2 -and $race.StoreBusy -and $race.Heartbeats -eq 3) 'Cleanup rebases real pre-lock samples while both samplers honor the actual exclusive store lock and heartbeat continues'
  Check ((PreservedQuality $f) -ceq (PreservedQuality $f $race.Quality $race.Standby)) 'Locked replacement preserves the samples written after the preliminary plan'
  Check ((Get-TCDDigest @($f.ProtectedPaths|ForEach-Object {Hash $_})) -ceq (Get-TCDDigest $protected)) 'Concurrent cleanup retains every protected file byte for byte'
  $cases.Add([pscustomobject]@{Name='LockBoundaries';Ok=$result.Ok;Code=$result.Code;PreLockWrites=$race.BeforeLockWrites;SamplersStoreBusy=$race.StoreBusy;ConcurrentHeartbeats=$race.Heartbeats})
  foreach($kind in @('Quality','Standby')){
   $f=Fixture ('late-'+$kind);$preview=New-TCLocalDeploymentCleanupPreview $f.Root @('Line:'+$f.Target)
   $f.Now=$f.Now.AddSeconds(60);$f.Overview.ObservedAt=$f.Now.ToString('o');$at=$f.Now;$clock={$at}.GetNewClosure()
   $data=@{Root=$f.Root;Token=$preview.PreviewToken;Module=(Join-Path $SourceDirectory 'OperationHistory.psm1');Deleted=$false;Error=''}
   $measure={param($Context,$BudgetMilliseconds,$Data)
    if(-not $Data.Deleted){try{Import-Module $Data.Module -DisableNameChecking;$r=Remove-TCLocalDeploymentData -Root $Data.Root -PreviewToken $Data.Token;$Data.Deleted=$r.DataDeleted}catch{$Data.Error=$_.Exception.Message;throw}}
    if($Context.PSObject.Properties['Binding'] -and $Context.Binding.PSObject.Properties['SessionId']){@{Status='Measured';ContextKey=$Context.Key;Source='ControllerDelay';Outbound=$Context.Binding.Exit;LatencyMs=80}}
    else{@{Status='Measured';CandidateKey=$Context.Key;Source='TcpConnect';LatencyMs=45}}
   }
   if($kind -ceq 'Quality'){$late=Invoke-TCLineQualitySample -Root $f.Root -Overview $f.Overview -Clock $clock -Measure $measure -MeasureData $data}
   else{
    # Inject only transport to force the pending-ticket/cleanup/publish order.
    # The normal 2s per-target network deadline must not time out the cleanup
    # operation itself when other regression processes are running in parallel.
    $standby=Get-Module StandbyQuality;$transport=& $standby {(Get-Command SQRunMeasurement).ScriptBlock}
    & $standby {function script:SQRunMeasurement {param($Candidate,[scriptblock]$Measure,$MeasureData,[int]$BudgetMilliseconds)& $Measure $Candidate $BudgetMilliseconds $MeasureData}}
    try{$late=Invoke-TCStandbyQualitySample -Root $f.Root -Overview $f.Overview -Candidates $f.Candidates -Clock $clock -Measure $measure -MeasureData $data}finally{& $standby {param($Original)Set-Item Function:script:SQRunMeasurement $Original} $transport}
   }
   $cases.Add([pscustomobject]@{Name=('Late-'+$kind);Deleted=$data.Deleted;Reason=$late.Reason;Sampled=$late.Sampled;Error=$data.Error})
   Check ($data.Deleted -and $late.Reason -ceq 'BindingChanged' -and -not $late.Sampled -and -not [IO.File]::Exists($f.TargetManifest)) ('Late '+$kind+' result cannot overwrite cleanup or resurrect B')
   $q=Read-TCDJson $f.QualityPath;$sq=Read-TCDJson $f.StandbyPath
   Check (-not @($q.ArchivedSeries|Where-Object {$_.Binding.NodeId -ceq $f.Target}).Count -and -not @($sq.Entries|Where-Object {$_.Binding.NodeId -ceq $f.Target}).Count) ('Revision invalidation retains target deletion for '+$kind)
  }
  $qualityModule=Get-Module LineQuality;$standbyModule=Get-Module StandbyQuality
  foreach($change in @('TargetBinding','StandbyBinding','ActiveBinding','UnknownField','UnknownSeriesField','UnknownEntryField','UnknownUnderlayField','UnknownBeforePreview','InvalidSample','FutureSchema','MissingCache','UnsafeCacheAcl','TargetAcl','IdentityMismatch','NewTransaction')){
   $f=Fixture ('reject-'+$change)
   if($change -ceq 'UnknownBeforePreview'){$d=Read-TCDJson $f.QualityPath;$d|Add-Member NoteProperty FutureFact 'unchanged';Put $f.QualityPath $d}
   $preview=New-TCLocalDeploymentCleanupPreview $f.Root @('Line:'+$f.Target);Check ([bool]$preview.PreviewToken) ('Safety fixture is initially deletable: '+$change)
   $targetHash=Hash $f.TargetManifest;$q=Read-TCDJson $f.QualityPath;$sq=Read-TCDJson $f.StandbyPath
   switch($change){
    TargetBinding {$s=@($q.ArchivedSeries|Where-Object {$_.Binding.NodeId -ceq $f.Target})[0];$s.Binding.ConfigHash=('C'*64);$s.BindingKey=& $qualityModule {param($b)LQHash (ConvertTo-Json -InputObject $b -Depth 4 -Compress)} $s.Binding;Put $f.QualityPath $q}
    StandbyBinding {$e=@($sq.Entries|Where-Object {$_.Binding.NodeId -ceq $f.Target})[0];$e.Binding.Port=444;$e.CandidateKey=(& $standbyModule {param($b)SQCandidate $b} $e.Binding).Key;Put $f.StandbyPath $sq}
    ActiveBinding {$q.Binding.ConfigHash=('C'*64);$q.BindingKey=& $qualityModule {param($b)LQHash (ConvertTo-Json -InputObject $b -Depth 4 -Compress)} $q.Binding;Put $f.QualityPath $q}
    UnknownField {$q|Add-Member NoteProperty ManifestPath $f.TargetManifest;Put $f.QualityPath $q}
    UnknownSeriesField {$q.ArchivedSeries[0]|Add-Member NoteProperty FutureFact $f.TargetManifest;Put $f.QualityPath $q}
    UnknownEntryField {$sq.Entries[0]|Add-Member NoteProperty FutureFact $f.TargetManifest;Put $f.StandbyPath $sq}
    UnknownUnderlayField {$e=$sq.Entries[0];$e.Binding.Underlay=[pscustomobject]@{InterfaceIndex=1;LocalAddress='192.0.2.20';InterfaceId=[guid]::NewGuid().ToString();NetworkFingerprint=('D'*64);FutureFact=$f.TargetManifest};$e.CandidateKey=(& $standbyModule {param($b)SQCandidate $b} $e.Binding).Key;Put $f.StandbyPath $sq}
    UnknownBeforePreview {$q.Revision=[guid]::NewGuid().ToString('N');Put $f.QualityPath $q}
    InvalidSample {$q.Samples[0].Quality='Poor';Put $f.QualityPath $q}
    FutureSchema {$q.SchemaVersion=3;Put $f.QualityPath $q}
    MissingCache {[IO.File]::Delete($f.QualityPath)}
    UnsafeCacheAcl {$acl=[IO.File]::GetAccessControl($f.QualityPath);$acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier('S-1-1-0')),'Read','Allow')));[IO.File]::SetAccessControl($f.QualityPath,$acl)}
    TargetAcl {$acl=[IO.File]::GetAccessControl($f.TargetManifest);$acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier('S-1-1-0')),'Read','Allow')));[IO.File]::SetAccessControl($f.TargetManifest,$acl)}
    IdentityMismatch {$registry=Read-TCDJson (Join-Path $f.Root 'servers\registry.json');$s=@($registry.Servers|Where-Object LocalRecordId -ceq $f.Servers[1].LocalRecordId)[0];$s.ServerPublicKey=('X'*43+'=');Put (Join-Path $f.Root 'servers\registry.json') $registry}
    NewTransaction {Put (Join-Path $f.Root ('connection-transactions\'+[guid]::NewGuid().ToString('N')+'.json')) @{Status='NeedsRecovery';Target=@{LineId=$f.Target;ManifestPath=$f.TargetManifest}}}
   }
   $result=Commit $f $preview
   Check (-not $result.Ok -and [IO.File]::Exists($f.TargetManifest) -and (Hash $f.TargetManifest) -ceq $targetHash) ('Changed safety evidence blocks cleanup before deletion: '+$change)
   Check (@(Get-TCLocalCleanupPending $f.Root).Count -eq 0) ('Rejection creates no destructive journal: '+$change)
   $cases.Add([pscustomobject]@{Name=$change;Ok=$result.Ok;Code=$result.Code;TargetPreserved=$true})
  }
 }
 if(-not $ExpectLegacyDefect){
  $f=Fixture 'continuous';$protected=@($f.ProtectedPaths|ForEach-Object {Hash $_})
  $status=[hashtable]::Synchronized(@{Stop=$false;Quality=0;Standby=0;Heartbeats=0;StoreBusy=0;Error='';WrittenQuality=$null;WrittenStandby=$null})
  $pump=[PowerShell]::Create();$job=$null
  $body={param($Source,$Fixture,$Status)
   $ErrorActionPreference='Stop';$env:PSModulePath=Join-Path $PSHOME 'Modules'
   Import-Module (Join-Path $Source 'DeploymentStore.psm1') -DisableNameChecking
   Import-Module (Join-Path $Source 'LineQuality.psm1') -DisableNameChecking
   Import-Module (Join-Path $Source 'StandbyQuality.psm1') -DisableNameChecking
   Import-Module (Join-Path $Source 'RuntimeObservability.psm1') -DisableNameChecking
   $view=$Fixture.Overview|ConvertTo-Json -Depth 10|ConvertFrom-Json;$at=$Fixture.Now
   try{
    while(-not $Status.Stop){
     $at=$at.AddSeconds(60);$view.ObservedAt=$at.ToString('o');$clock={$at}.GetNewClosure()
     $q=Invoke-TCLineQualitySample -Root $Fixture.Root -Overview $view -Clock $clock -Measure {param($Context,$BudgetMilliseconds,$Data)@{Status='Measured';ContextKey=$Context.Key;Source='ControllerDelay';Outbound=$Context.Binding.Exit;LatencyMs=80}}
     if($q.Sampled){$Status.Quality++;$Status.WrittenQuality=Read-TCDJson $Fixture.QualityPath};if($q.Reason -ceq 'StoreBusy'){$Status.StoreBusy++}
     $sq=Invoke-TCStandbyQualitySample -Root $Fixture.Root -Overview $view -Candidates $Fixture.Candidates -Clock $clock -Measure {param($Candidate,$BudgetMilliseconds,$Data)@{Status='Measured';CandidateKey=$Candidate.Key;Source='TcpConnect';LatencyMs=45}}
     if($sq.Sampled){$Status.Standby++;$Status.WrittenStandby=Read-TCDJson $Fixture.StandbyPath};if($sq.Reason -ceq 'StoreBusy'){$Status.StoreBusy++}
     $o=Observe-TCRuntimeState -Root $Fixture.Root -Overview $view;if($o.Observed -and $o.EventsAdded -eq 0){$Status.Heartbeats++}
     Start-Sleep -Milliseconds 200
    }
   }catch{$Status.Error=$_.Exception.Message}
  }
  $null=$pump.AddScript($body.ToString()).AddArgument($SourceDirectory).AddArgument($f).AddArgument($status)
  $retries=New-Object 'Collections.Generic.List[string]';$attempts=0;$result=$null;$watch=[Diagnostics.Stopwatch]::StartNew()
  try{
   $job=$pump.BeginInvoke()
   while($status.Quality -lt 2 -or $status.Standby -lt 2 -or $status.Heartbeats -lt 2){if($status.Error -or $watch.Elapsed.TotalSeconds -gt 30){throw ('Synthetic writer did not start: '+$status.Error)};Start-Sleep -Milliseconds 50}
   $writesAtPreview=@($status.Quality,$status.Standby,$status.Heartbeats)
   $preview=New-TCLocalDeploymentCleanupPreview -Root $f.Root -Ids @('Line:'+$f.Target)
   Check ([bool]$preview.PreviewToken) 'Continuous real sampling and heartbeat permit an exact idle-line preview'
   # Reuse the same token for transient busy responses; no re-preview loop.
   do{
    $attempts++;$result=Commit $f $preview
    if(-not $result.Ok){$retries.Add($result.Code);if($result.Code -notmatch '\[TC:HistoryBusy\]' -or $watch.Elapsed.TotalSeconds -gt 40){throw ('Continuous cleanup refused: '+$result.Code)};Start-Sleep -Milliseconds 50}
   }while(-not $result.Ok)
   $status.Stop=$true
   if(-not $job.AsyncWaitHandle.WaitOne(10000)){throw 'Owned telemetry runspace did not stop'};$null=$pump.EndInvoke($job)
   Check (-not $status.Error -and $result.Result.DataDeleted -and -not [IO.File]::Exists($f.TargetManifest)) 'One sealed preview completes while a real background runspace continuously samples and observes'
   Check ($status.Quality -gt $writesAtPreview[0] -and $status.Standby -gt $writesAtPreview[1] -and $status.Heartbeats -gt $writesAtPreview[2]) 'Both samplers and heartbeat publish again after preview begins'
   Check ((Get-TCDDigest @($f.ProtectedPaths|ForEach-Object {Hash $_})) -ceq (Get-TCDDigest $protected)) 'Sustained background writes preserve current runtime, active line, key and shared credential bytes'
   $actual=Read-TCDJson $f.QualityPath;$latest=$status.WrittenQuality
   Check ($actual.Binding.NodeId -ceq $f.Active -and (Get-TCDDigest $actual.Samples) -ceq (Get-TCDDigest $latest.Samples)) 'Latest completed active sampler samples survive continuous cleanup'
   $cases.Add([pscustomobject]@{Name='Continuous';Ok=$result.Ok;Attempts=$attempts;Retries=@($retries.ToArray());QualityWrites=$status.Quality;StandbyWrites=$status.Standby;Heartbeats=$status.Heartbeats;StoreBusy=$status.StoreBusy;ElapsedMs=$watch.ElapsedMilliseconds;WriterError=$status.Error})
  }finally{$status.Stop=$true;if($job -and -not $job.IsCompleted){$pump.Stop()};$pump.Dispose()}
 }
}catch{$failure=$_.Exception.Message;$stack=$_.ScriptStackTrace}
$report=[pscustomobject]@{Passed=(-not $failure);ExpectLegacyDefect=[bool]$ExpectLegacyDefect;ContinuousOnly=[bool]$ContinuousOnly;Checks=$checks.Count;Assertions=@($checks.ToArray());Cases=@($cases.ToArray());Error=$failure;Stack=$stack;SourceDirectory=$SourceDirectory;PowerShellVersion=$PSVersionTable.PSVersion.ToString();SourceHashes=@(Get-FileHash -LiteralPath (Join-Path $SourceDirectory 'LocalDeploymentCleanup.ps1'),(Join-Path $SourceDirectory 'OperationHistory.psm1')|Select-Object Path,Hash);ActualSamplers=$true;InjectedMeasurements=$true;ActualObserver=$true;ProductionWrites=0;NetworkUsed=$false;FixtureRoot=$work}
[IO.File]::WriteAllText($ReportPath,($report|ConvertTo-Json -Depth 16),[Text.UTF8Encoding]::new($true))
$report|Select-Object Passed,ExpectLegacyDefect,Checks,Error,Stack|ConvertTo-Json
if(-not $failure){$full=[IO.Path]::GetFullPath($work);if(-not $full.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -cnotmatch '^tc-cleanup-telemetry-[a-f0-9]{32}$' -or @(Get-ChildItem -LiteralPath $full -Recurse -Force|Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count){throw 'Unsafe fixture cleanup'};Remove-Item -LiteralPath $full -Recurse -Force}
if($failure){exit 1}
