#requires -Version 5.1
#requires -PSEdition Desktop
[CmdletBinding()]param([string]$SourceDirectory=(Split-Path $PSScriptRoot -Parent),[Parameter(Mandatory=$true)][string]$ReportPath,[switch]$ExpectLegacyDefect)
$ErrorActionPreference='Stop';$env:PSModulePath=Join-Path $PSHOME 'Modules'
Import-Module (Join-Path $SourceDirectory 'DeploymentStore.psm1') -DisableNameChecking
Import-Module (Join-Path $SourceDirectory 'ServerRegistry.psm1') -DisableNameChecking
Import-Module (Join-Path $SourceDirectory 'RuntimeObservability.psm1') -DisableNameChecking
$history=Import-Module (Join-Path $SourceDirectory 'OperationHistory.psm1') -PassThru -DisableNameChecking
$checks=New-Object 'Collections.Generic.List[string]';$cases=New-Object 'Collections.Generic.List[object]';$fixtures=New-Object 'Collections.Generic.List[string]';$failure='';$stack=''
function Check {param($Value,[string]$Name) if(-not $Value){throw $Name};$checks.Add($Name)}
function Put {param([string]$Path,$Value)
 if(-not @($fixtures|Where-Object {[IO.Path]::GetFullPath($Path).StartsWith($_+'\',[StringComparison]::OrdinalIgnoreCase)}).Count){throw 'Test rejected external write'}
 Write-TCDJson $Path $Value
}
function Fixture {
 $root=Join-Path ([IO.Path]::GetTempPath()) ('TradeChannel-worker-fixture-'+[guid]::NewGuid().ToString('N'));$null=New-TCDDirectory $root;$fixtures.Add($root)
 $nodes=@();$lines=@();$runs=@()
 foreach($n in 1,2){
  $server=Set-TCServerRecord -Root $root -Connection @{Host=('192.0.2.'+$n);Port=22;User='root';IdentityFile=''} -Name ('fixture-'+$n) -ServerInfo @{RemoteOwnerId=[guid]::NewGuid().ToString();Node=@{NodeId=[guid]::NewGuid().ToString();ServerPublicKey=([string]$n*43+'=')}}
  $id=[guid]::NewGuid().ToString();$lines+=,$id;$mp=Join-Path $root ('Product\nodes\'+$id+'\manifest.json')
  Put $mp @{TCLineId=$id;TCManagedNodeId=$id;ServerPublicKey=([string]$n*43+'=');ClientPublicKey=('client-'+$id)}
  Put (Join-Path $root ('Product\nodes\'+$id+'\device.key')) @{FixtureOnly=$id}
  Put (Join-Path $root ('Product\lines\'+$id+'\line.json')) @{SchemaVersion=2;LineId=$id;Profiles=@();SourceManifestPath=$mp;ServerPublicKey=([string]$n*43+'=')}
  $nodes+=,@{id=$id;name=('fixture-'+$n);manifestPath=$mp};$run=[guid]::NewGuid().ToString();$runs+=,$run
  Put (Join-Path $root ('deployments\runs\'+$run+'\state.json')) @{SchemaVersion=1;RunId=$run;ServerRecordId=$server.LocalRecordId;Intent='New';Revision=1;Status='Complete';Stage='ReadyInactive';CandidateNodeId=$id;CandidateManifestPath=$mp;CreatedAtUtc=[DateTime]::UtcNow.ToString('o');UpdatedAtUtc=[DateTime]::UtcNow.ToString('o')}
  $null=Set-TCServerLink -Root $root -ServerId $server.LocalRecordId -NodeId $id
 }
 Put (Join-Path $root 'Product\index.json') @{schemaVersion=1;nodes=$nodes}
 Put (Join-Path $root 'deployment.json') @{LineId=$lines[0];ManifestPath=$nodes[0].manifestPath}
 $started=[DateTimeOffset]::UtcNow.ToString('o');$sid=[guid]::NewGuid().ToString('N')
 Put (Join-Path $root 'runtime.json') @{State='Running';OwnershipKnown=$true;LineId=$lines[0];ManifestPath=$nodes[0].manifestPath;SessionId=$sid;EngineStartedAt=$started}
 $overview=@{Running=$true;StateKey='Connected';GuardState='Protected';Mode='rule';Exit='hk';ManifestPath=$nodes[0].manifestPath;ConnectedSince=$started}
 # RuntimeObservability reads properties, so pass an actual PSCustomObject.
 $overview=[pscustomobject]$overview
 $observation=Observe-TCRuntimeState -Root $root -Overview $overview
 Check $observation.Observed 'Real observer establishes the synthetic active session'
 $null=[IO.Directory]::CreateDirectory((Join-Path $root 'Product\jobs'))
 [pscustomobject]@{Root=$root;Active=$lines[0];Target=$lines[1];Nodes=$nodes;Runs=$runs;Overview=$overview;Observer=(Join-Path $root 'runtime-observer.json');TargetManifest=$nodes[1].manifestPath}
}
function Worker {param($Fixture,[hashtable]$Request)
 $id=[guid]::NewGuid().ToString('N');$Request.RequestId=$id;$Request.UiRequestId=[guid]::NewGuid().ToString('N');$Request.PageGeneration=1
 $requestPath=Join-Path $Fixture.Root ('Product\jobs\'+$id+'.request.json');$resultPath=Join-Path $Fixture.Root ('Product\jobs\'+$id+'.result.json');Put $requestPath $Request
 $args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $SourceDirectory 'Worker.ps1'),'-RequestPath',$requestPath,'-ResultPath',$resultPath,'-IsolatedTest','-TestRoot',$Fixture.Root)
 $quoted=@($args|ForEach-Object {'"'+$_+'"'}) -join ' '
 $p=Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $quoted -WindowStyle Hidden -PassThru
 try{if(-not $p.WaitForExit(90000)){throw 'Owned isolated Worker exceeded 90 seconds'};Check ($p.ExitCode -eq 0 -and [IO.File]::Exists($resultPath)) ('Worker publishes '+$Request.Action)}finally{$p.Dispose()}
 $r=Read-TCDJson $resultPath;Check ($r.RequestId -ceq $id -and $r.UiRequestId -ceq $Request.UiRequestId) 'Real Worker returns the UI request identity'
 $r
}
function Preview {param($f)
 $r=Worker $f @{Action='RecordDeletePreview';Ids=@('Line:'+$f.Target);AbandonLocalTracking=$false}
 Check ($r.Ok -and $r.Data.PreviewToken -and $r.Data.LineCount -eq 1 -and $r.Data.Blocked.Count -eq 0) 'Unused target gets an exact one-line preview while another line is active'
 $r.Data
}
function ProtectedHashes {param($f)
 @('deployment.json','runtime.json',('Product\lines\'+$f.Active+'\line.json'),('Product\nodes\'+$f.Active+'\manifest.json'),('Product\nodes\'+$f.Active+'\device.key'))|ForEach-Object {[pscustomobject]@{Path=(Join-Path $f.Root $_);Hash=(Get-FileHash -LiteralPath (Join-Path $f.Root $_)).Hash}}
}
try{
 $f=Fixture;$before=@(ProtectedHashes $f);$preview=Preview $f;$rawBefore=(Get-FileHash -LiteralPath $f.Observer).Hash
 $refresh=Observe-TCRuntimeState -Root $f.Root -Overview $f.Overview
 Check ($refresh.Observed -and $refresh.EventsAdded -eq 0 -and (Get-FileHash -LiteralPath $f.Observer).Hash -cne $rawBefore) 'Ordinary same-session refresh changes bytes without a state event'
 $result=Worker $f @{Action='RecordDeleteCommit';PreviewToken=$preview.PreviewToken}
 if($ExpectLegacyDefect){Check (-not $result.Ok -and $result.Code -ceq 'CleanupPreviewStale' -and [IO.File]::Exists($f.TargetManifest)) 'Old Worker incorrectly rejects unchanged cleanup after a heartbeat'}
 else{
  Check ($result.Ok -and $result.Data.DataDeleted -and -not [IO.File]::Exists($f.TargetManifest)) 'Fixed Worker commits unchanged cleanup after a heartbeat'
  foreach($row in $before){Check ((Get-FileHash -LiteralPath $row.Path).Hash -ceq $row.Hash) 'Active line and runtime bytes survive the actual cleanup'}
  $again=Worker $f @{Action='RecordDeleteCommit';PreviewToken=$preview.PreviewToken};Check ($again.Ok -and $again.Data.AlreadyApplied) 'Repeated confirmation uses the completed journal without repeating deletion'
 }
 $cases.Add([pscustomobject]@{Name='Heartbeat';Ok=$result.Ok;Code=$result.Code;TargetExists=[IO.File]::Exists($f.TargetManifest);ActiveFiles=$before})
 if(-not $ExpectLegacyDefect){
  foreach($kind in @('Session','Snapshot','NewReference','UnknownField','TargetBytes','ActiveLine','PendingTransaction','InvalidObserver','FutureSchema','MissingObserver')){
   $f=Fixture
   if($kind -eq 'FutureSchema'){$d=Read-TCDJson $f.Observer;$d.SchemaVersion=2;Put $f.Observer $d}
   $preview=Preview $f
   $d=Read-TCDJson $f.Observer
   switch($kind){
    Session {$d.SessionId=[guid]::NewGuid().ToString('N');Put $f.Observer $d}
    Snapshot {$d.Snapshot.GuardState='Unprotected';Put $f.Observer $d}
    NewReference {$d|Add-Member NoteProperty ManifestPath $f.TargetManifest;Put $f.Observer $d}
    UnknownField {$d|Add-Member NoteProperty FutureSafetyFact 'changed';Put $f.Observer $d}
    TargetBytes {Put $f.TargetManifest @{TCLineId=$f.Target;TCManagedNodeId=$f.Target;ServerPublicKey=('2'*43+'=');ClientPublicKey='changed'}}
    ActiveLine {Put (Join-Path $f.Root 'deployment.json') @{LineId=$f.Target;ManifestPath=$f.TargetManifest}}
    PendingTransaction {Put (Join-Path $f.Root ('connection-transactions\'+[guid]::NewGuid().ToString('N')+'.json')) @{Status='NeedsRecovery';Target=@{LineId=$f.Target;ManifestPath=$f.TargetManifest}}}
    InvalidObserver {[IO.File]::WriteAllText($f.Observer,'{invalid', [Text.UTF8Encoding]::new($true))}
    FutureSchema {$d.Revision++;Put $f.Observer $d}
    MissingObserver {Remove-Item -LiteralPath $f.Observer -Force}
   }
   $targetHash=(Get-FileHash -LiteralPath $f.TargetManifest).Hash
   $result=Worker $f @{Action='RecordDeleteCommit';PreviewToken=$preview.PreviewToken}
   Check (-not $result.Ok -and (Get-FileHash -LiteralPath $f.TargetManifest).Hash -ceq $targetHash) ('Safety change still blocks cleanup: '+$kind)
   $cases.Add([pscustomobject]@{Name=$kind;Ok=$result.Ok;Code=$result.Code;TargetPreserved=$true})
  }
  # Force the exact read/verify interleaving, using real observer writes. No
  # timer luck: mutate once at the second observer stamp inside OHSnapshot.
  foreach($change in @('Heartbeat','Session')){
   $f=Fixture
   $probe=& $history {param($Root,$Overview,$Change)
    $original=(Get-Command OHFileStamp).ScriptBlock;$script:ObservationRaceCount=0;$script:ObservationRaceRoot=$Root;$script:ObservationRaceOverview=$Overview;$script:ObservationRaceChange=$Change;$script:ObservationOriginalStamp=$original
    function script:OHFileStamp {param($Context,[string]$Path,[switch]$PresenceOnly)
     if($Path -ieq (Join-Path $script:ObservationRaceRoot 'runtime-observer.json')){
      $script:ObservationRaceCount++
      if($script:ObservationRaceCount -eq 2){
       if($script:ObservationRaceChange -eq 'Heartbeat'){$null=Observe-TCRuntimeState -Root $script:ObservationRaceRoot -Overview $script:ObservationRaceOverview}
       else{$doc=Read-TCDJson $Path;$doc.SessionId=[guid]::NewGuid().ToString('N');Write-TCDJson $Path $doc}
      }
     }
     & $script:ObservationOriginalStamp $Context $Path -PresenceOnly:$PresenceOnly
    }
    try{$null=OHSnapshot $Root;[pscustomobject]@{Accepted=$true;Code='';Hits=$script:ObservationRaceCount}}catch{[pscustomobject]@{Accepted=$false;Code=$_.Exception.Message;Hits=$script:ObservationRaceCount}}finally{Set-Item Function:script:OHFileStamp $original}
   } $f.Root $f.Overview $change
   Check ($probe.Hits -ge 2 -and $probe.Accepted -eq ($change -eq 'Heartbeat')) ('Snapshot read race differentiates '+$change)
   $cases.Add([pscustomobject]@{Name=('ReadRace-'+$change);Accepted=$probe.Accepted;Hits=$probe.Hits;Code=$probe.Code})
  }
 }
}catch{$failure=$_.Exception.Message;$stack=$_.ScriptStackTrace}
$report=[pscustomobject]@{Passed=(-not $failure);ExpectLegacyDefect=[bool]$ExpectLegacyDefect;Checks=$checks.Count;Assertions=@($checks.ToArray());Cases=@($cases.ToArray());Error=$failure;Stack=$stack;SourceDirectory=$SourceDirectory;PowerShellVersion=$PSVersionTable.PSVersion.ToString();ActualWorker=$true;ActualObserver=$true;ProductionWrites=0;NetworkUsed=$false;Fixtures=@($fixtures.ToArray())}
[IO.File]::WriteAllText($ReportPath,($report|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($true))
$report|Select-Object Passed,ExpectLegacyDefect,Checks,Error,Stack|ConvertTo-Json
if(-not $failure){foreach($root in $fixtures){$full=[IO.Path]::GetFullPath($root);if(-not $full.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -cnotmatch '^TradeChannel-worker-fixture-[a-f0-9]{32}$' -or @(Get-ChildItem -LiteralPath $full -Recurse -Force|Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count){throw 'Unsafe fixture cleanup'};Remove-Item -LiteralPath $full -Recurse -Force}}
if($failure){exit 1}
