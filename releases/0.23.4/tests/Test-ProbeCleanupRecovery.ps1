#requires -Version 5.1
$ErrorActionPreference='Stop';$env:PSModulePath=Join-Path $PSHOME 'Modules'
$package=Split-Path $PSScriptRoot -Parent
$nodes=Import-Module (Join-Path $package 'NodeStore.psm1') -PassThru -DisableNameChecking
$probe=Import-Module (Join-Path $package 'CandidateProbe.psm1') -PassThru -DisableNameChecking
$work=Join-Path ([IO.Path]::GetTempPath()) ('TC-ProbeRecovery-'+[guid]::NewGuid().ToString('N'))
$line=[guid]::NewGuid().ToString('D');$other=[guid]::NewGuid().ToString('D');$count=0
function Check {param([bool]$Pass,[string]$Message)if(-not $Pass){throw $Message};$script:count++}
& $nodes {param($p)New-TCPrivateDirectory $p;New-TCPrivateDirectory (Join-Path $p 'Product');New-TCPrivateDirectory (Join-Path $p 'probes')} $work
& $probe {
 $script:RecoveryFixtureAlive=$false;$script:RecoveryCimCalls=0
 function script:Get-CimInstance {param($ClassName,$Filter,$ErrorAction)$script:RecoveryCimCalls++;if($script:RecoveryFixtureAlive){[pscustomobject]@{ProcessId=123456;Name='inert-fixture'}}}
 function script:Stop-Process {throw 'Recovery test refuses every process stop'}
 function script:Stop-TCCandidateOwnedTrace {throw 'This fixture has no ETW session'}
}
function Receipt {param([string]$Node=$line,[string]$State='NeedsRecovery',[int]$ProcessId=123456)
 $id=[guid]::NewGuid().ToString('D');$dir=Join-Path (Join-Path $work 'probes') $id
 & $nodes {param($p)New-TCPrivateDirectory $p} $dir
 $config=Join-Path $dir 'candidate.private.json'
 [IO.File]::WriteAllText($config,'{"inbounds":[{"type":"mixed","listen":"127.0.0.1","listen_port":12345}]}',(New-Object Text.UTF8Encoding($false)))
 $owner=[pscustomobject]@{SchemaVersion=1;RunId=$id;NodeId=$Node;State=$State;ProcessId=$ProcessId;ProcessStartedAt=$(if($ProcessId){'2026-01-01T00:00:00Z'}else{$null});ConfigHash=(Get-FileHash -LiteralPath $config).Hash;TraceGuid=$null;TraceState='NotStarted'}
 & $nodes {param($p,$v)Write-TCAtomicJson $p $v} (Join-Path $dir 'ownership.json') $owner
 [pscustomobject]@{Directory=$dir;Marker=(Join-Path $dir 'ownership.json');Config=$config;Owner=$owner}
}
try{
 $r=Receipt;$result=Repair-TCCandidateProbeCleanup -Root $work -NodeId $line
 if(-not $result.CleanupComplete){& $probe {$script:LastProbeRecoveryDiagnostic}|ConvertTo-Json}
 Check $result.CleanupComplete 'Recorded instance absence permits owned file reconciliation'
 Check (-not (Test-Path -LiteralPath $r.Config)) 'Only the ended probe private config is removed'
 Check ((Get-Content -LiteralPath $r.Marker -Raw|ConvertFrom-Json).State -eq 'Stopped') 'Owned receipt is marked stopped after verification'
 $repeat=Repair-TCCandidateProbeCleanup -Root $work -NodeId $line
 Check ($repeat.CleanupComplete -and $repeat.Results.Count -eq 0) 'Repeated cleanup is a no-op'
 $live=Receipt;& $probe {$script:RecoveryFixtureAlive=$true}
 $before=(Get-FileHash -LiteralPath $live.Marker).Hash;$blocked=Repair-TCCandidateProbeCleanup -Root $work -NodeId $line
 Check (-not $blocked.CleanupComplete -and (Test-Path -LiteralPath $live.Config) -and (Get-FileHash -LiteralPath $live.Marker).Hash -eq $before) 'Existing or reused PID is never stopped or marked absent'
 & $probe {$script:RecoveryFixtureAlive=$false};$null=Repair-TCCandidateProbeCleanup -Root $work -NodeId $line
 $pending=Receipt -State 'Starting' -ProcessId 0
 $blocked=Repair-TCCandidateProbeCleanup -Root $work -NodeId $line
 Check (-not $blocked.CleanupComplete -and (Test-Path -LiteralPath $pending.Config)) 'Interrupted launch without recorded identity remains blocked'
 $pending.Owner.State='Stopped';& $nodes {param($p,$v)Write-TCAtomicJson $p $v} $pending.Marker $pending.Owner
 $foreign=Receipt -Node $other;$foreignBefore=(Get-FileHash -LiteralPath $foreign.Marker).Hash
 $blocked=Repair-TCCandidateProbeCleanup -Root $work -NodeId $line
 Check (-not $blocked.CleanupComplete -and (Get-FileHash -LiteralPath $foreign.Marker).Hash -eq $foreignBefore -and (Test-Path -LiteralPath $foreign.Config)) 'Other-line unresolved receipt stays untouched and fences new probes'
 [pscustomobject]@{Passed=$true;Checks=$count;RealProcessStops=0;RealNetworkChanges=0}|ConvertTo-Json
}finally{
 $full=[IO.Path]::GetFullPath($work);$parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
 if([IO.Path]::GetDirectoryName($full) -ine $parent -or [IO.Path]::GetFileName($full) -notmatch '^TC-ProbeRecovery-[a-f0-9]{32}$'){throw 'Cleanup path rejected'}
 Remove-Item -LiteralPath $full -Recurse -Force
}
