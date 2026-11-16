#requires -Version 5.1
#requires -PSEdition Desktop
# 0.18.4 P0-8: a probe that claims to be running but has no living owner is finished safely.
[CmdletBinding()]param([string]$ReportPath)
$ErrorActionPreference='Stop'
$package=Split-Path $PSScriptRoot -Parent
$root=Join-Path ([IO.Path]::GetTempPath()) ('tc-orphan-'+[guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($root)
Import-Module (Join-Path $package 'DeploymentStore.psm1') -DisableNameChecking
$flow=Import-Module (Join-Path $package 'DeploymentFlow.psm1') -Force -PassThru -DisableNameChecking
$checks=0;function Check {param($ok,$name)if(-not $ok){throw $name};$script:checks++}
function New-Run {param([string]$Owner='none',[int]$AgeSeconds=300,[string]$Candidate='')
 $id=[guid]::NewGuid().ToString('D');$dir=Join-Path $root ('deployments\runs\'+$id);$null=New-TCDDirectory $dir
 $at=[DateTimeOffset]::UtcNow.AddSeconds(-$AgeSeconds).ToString('o')
 $run=[ordered]@{SchemaVersion=1;RunId=$id;Revision=3;Name='fixture';Stage='CheckingProfiles';Status='Running';ProfileProbeState='Running';ProbeAttemptId=('a'*32);ProbeStartedAt=$at;UpdatedAtUtc=$at;CandidateNodeId=$Candidate;RecoveryRequired=$false;ProbeRecoveryRequired=$false;UnresolvedTcpMutation=$null;ExperienceVersion=1;DeploymentCompleteness='Complete';ProtocolPreparation=[ordered]@{Udp=[ordered]@{ServerPreparation='Configured';LocalPreparation='SyntaxValidated'};Tcp=[ordered]@{ServerPreparation='Configured';LocalPreparation='SyntaxValidated'}};UserActions=@('重新检查');MissingProtocols=@();PartialUseAccepted=$false;PartialUseOrigin='';Recommendation=$null;RecommendedProfileId=$null;LastError=$null;ProbeError=$null;PendingPurpose=$null;PendingOperationId=$null;ProbeProgress=[ordered]@{Stage='CheckingProfiles';ProfileId='Tcp';Round=3;UpdatedAtUtc=$at}}
 if($Owner -eq 'live'){$p=[Diagnostics.Process]::GetCurrentProcess();$run.ProbeOwner=[ordered]@{ProcessId=$PID;ProcessStartedTicks=[string]$p.StartTime.ToUniversalTime().Ticks;Kind='Worker';HeartbeatAtUtc=[DateTimeOffset]::UtcNow.ToString('o')};$p.Dispose()}
 if($Owner -eq 'dead'){$run.ProbeOwner=[ordered]@{ProcessId=999999;ProcessStartedTicks='1';Kind='UiRunspace';HeartbeatAtUtc=[DateTimeOffset]::UtcNow.ToString('o')}}
 if($Owner -eq 'stale'){$p=[Diagnostics.Process]::GetCurrentProcess();$run.ProbeOwner=[ordered]@{ProcessId=$PID;ProcessStartedTicks=[string]$p.StartTime.ToUniversalTime().Ticks;Kind='UiRunspace';HeartbeatAtUtc=$at};$p.Dispose()}
 Write-TCDJson (Join-Path $dir 'state.json') ([pscustomobject]$run) -Compact
 $id
}
function Read-Run {param($Id)[IO.File]::ReadAllText((Join-Path $root ('deployments\runs\'+$Id+'\state.json')))|ConvertFrom-Json}
try{
 # the shape of the real record: no owner field, last update minutes ago
 $legacy=New-Run -Owner none;$r=Read-Run $legacy
 Check (Test-TCDeploymentProbeOrphaned $r) 'an old record without an owner and without recent updates is orphaned'
 $progress=Get-TCDeploymentProgress $r
 Check ($progress.State -ceq 'NeedsAttention' -and $progress.Summary -match '中断') 'progress shows an interrupted test instead of an endless spinner'
 Check (-not (Test-TCDeploymentProbeOrphaned (Read-Run (New-Run -Owner none -AgeSeconds 20)))) 'a recently updated record without an owner is left alone'
 Check (-not (Test-TCDeploymentProbeOrphaned (Read-Run (New-Run -Owner live -AgeSeconds 300)))) 'a living owner with a fresh heartbeat is not orphaned'
 Check (Test-TCDeploymentProbeOrphaned (Read-Run (New-Run -Owner dead -AgeSeconds 5))) 'an owner whose process is gone is orphaned at once'
 Check (Test-TCDeploymentProbeOrphaned (Read-Run (New-Run -Owner stale -AgeSeconds 300))) 'a living process with a stale heartbeat is orphaned'
 # repair under the run lock
 $live=New-Run -Owner live;$held=[IO.File]::Open((Join-Path $root ('deployments\runs\'+$live+'\.run.lock')),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
 try{$none=Repair-TCOrphanedDeploymentProbes -Root $root}finally{$held.Dispose()}
 Check (@($none.Repaired|Where-Object RunId -ceq $live).Count -eq 0 -and (Read-Run $live).ProfileProbeState -ceq 'Running') 'a run whose probe still holds its lock is not touched'
 Check (@($none.Repaired).Count -ge 3 -and @($none.Repaired|Where-Object RunId -ceq $legacy).Count -eq 1) 'the other orphans (no owner, dead owner, stale heartbeat) are closed in the same pass'
 $result=Repair-TCOrphanedDeploymentProbes -Root $root
 $fixed=Read-Run $legacy
 Check (@($result.Repaired|Where-Object RunId -ceq $live).Count -eq 1 -and $fixed.Stage -ceq 'ReadyInactive' -and $fixed.ProfileProbeState -ceq 'Interrupted' -and $fixed.Status -ne 'Running' -and -not $fixed.ProbeOwner -and $fixed.ProbeError.Code -ceq 'ProfileCheckInterrupted' -and $fixed.ProbeError.Message -match '不需要重新部署') 'an orphaned probe is closed as interrupted with a plain message'
 Check (-not $result.RemoteChanged -and -not $result.NetworkChanged) 'the repair never touches a server or the network'
 $again=Repair-TCOrphanedDeploymentProbes -Root $root
 Check (@($again.Repaired|Where-Object RunId -ceq $legacy).Count -eq 0) 'repair is idempotent'
 Check (@($result.Repaired).Count -ge 1) 'dead and stale owners are also closed'
 # cleanup that cannot be proven takes the existing recovery path
 $dirty=New-Run -Owner dead -Candidate ([guid]::NewGuid().ToString('D'))
 & $flow {$script:TCProbeCleanupHook={param($r,$n)[pscustomobject]@{CleanupComplete=$false;Code='ProbeCleanupFailed';Message='fixture leftover'}}}
 try{$null=Repair-TCOrphanedDeploymentProbes -Root $root}finally{& $flow {$script:TCProbeCleanupHook=$null}}
 $d=Read-Run $dirty
 Check ($d.ProbeRecoveryRequired -and $d.RecoveryRequired -and $d.ProfileProbeState -ceq 'Interrupted' -and $d.Stage -ceq 'NeedsRecovery') 'an unproven cleanup is not closed: the record keeps its recovery requirement'
 $clean=New-Run -Owner dead -Candidate ([guid]::NewGuid().ToString('D'))
 & $flow {$script:TCProbeCleanupHook={param($r,$n)[pscustomobject]@{CleanupComplete=$true;Code='Clean';Message=''}}}
 try{$null=Repair-TCOrphanedDeploymentProbes -Root $root}finally{& $flow {$script:TCProbeCleanupHook=$null}}
 Check ((Read-Run $clean).Stage -ceq 'ReadyInactive' -and -not (Read-Run $clean).RecoveryRequired) 'a confirmed clean candidate is closed normally'
 $out=[pscustomobject]@{Passed=$true;Checks=$checks;NetworkChanged=$false;RemoteChanged=$false}
 if($ReportPath){$out|ConvertTo-Json|Set-Content -LiteralPath $ReportPath -Encoding UTF8};$out|ConvertTo-Json -Compress
}finally{
 $full=[IO.Path]::GetFullPath($root);if($full.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($full) -match '^tc-orphan-[a-f0-9]{32}$'){Remove-Item -LiteralPath $full -Recurse -Force}
}