#requires -Version 5.1
Set-StrictMode -Version 2.0
$script:TCComparisonCandidate=Import-Module (Join-Path $PSScriptRoot 'CandidateProbe.psm1') -PassThru -DisableNameChecking
$script:TCComparisonPath=Import-Module (Join-Path $PSScriptRoot 'ProbePath.psm1') -PassThru -DisableNameChecking
function PCmpField {param($Value,[string]$Name,$Default=$null)
    if($Value -is [Collections.IDictionary]){if($Value.Contains($Name)){return $Value[$Name]}}
    elseif($null -ne $Value -and $Value.PSObject.Properties[$Name]){return $Value.$Name};$Default
}
function PCmpClone {param($Value)
    $json=ConvertTo-Json -InputObject $Value -Depth 60
    if((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')){ConvertFrom-Json -InputObject $json -DateKind String}else{ConvertFrom-Json -InputObject $json}
}
function Get-TCProtocolComparisonContext { & $script:TCComparisonPath {Get-TCProbeNetworkContext} }
function Get-TCProtocolComparisonProfile {param([string]$Root,[string]$NodeId,[string]$ProfileId)
    Import-Module (Join-Path $PSScriptRoot 'LineStore.psm1') -DisableNameChecking
    $line=Get-TCLine -Root $Root -Id $NodeId
    $profiles=@($line.Profiles|Where-Object {$_.Id -ceq $ProfileId})
    if($profiles.Count -gt 1){throw 'Duplicate stored profile'}
    if($profiles.Count){$profiles[0]}else{$null}
}
function Prepare-TCProtocolComparisonBinding {param([string]$Root,[string]$NodeId,[int]$InterfaceIndex)
    Import-Module (Join-Path $PSScriptRoot 'LineStore.psm1') -DisableNameChecking
    Prepare-TCLineProbeBindings -Root $Root -Id $NodeId -InterfaceIndex $InterfaceIndex
}
function Publish-TCProtocolComparisonProgress {param($Callback,$Value)
    if($Callback){$null=& $Callback $Value}
}
function Invoke-TCProtocolComparisonProbe {param([string]$Root,[string]$NodeId,[string]$ProfileId,[string]$ExpectedExitIPv4,[string]$ExpectedExitSource,[string]$CancellationPath,[int]$TimeoutSeconds)
    Test-TCCandidateProbe -Root $Root -NodeId $NodeId -ProfileId $ProfileId -ExpectedExitIPv4 $ExpectedExitIPv4 -ExpectedExitSource $ExpectedExitSource -CancellationPath $CancellationPath -TimeoutSeconds $TimeoutSeconds -FixedRequestBudget
}
function Get-TCProtocolComparisonStopCode {param($Result)
    $code=[string](PCmpField $Result Code '')
    if(-not (PCmpField $Result CleanupComplete $false) -or $code -eq 'ProbeCleanupFailed' -or (PCmpField (PCmpField $Result PathEvidence) Reason '') -in @('UdpEtwCleanupUnverified','ProbeCleanupFailed')){return 'ProbeCleanupFailed'}
    if((PCmpField $Result CancellationRequested $false) -or $code -eq 'ProbeCancelled'){return 'ProbeCancelled'}
    if($code -in @('ActiveIdentity','ProbeIdentityUnknown','IdentityBlocked')){return $code}
    if((PCmpField $Result ContextChanged $false) -or (PCmpField $Result NetworkChanged $false) -or $code -in @('NetworkChangedDuringComparison','NetworkContextChanged','NetworkChangedDuringObservation') -or (PCmpField (PCmpField $Result PathEvidence) Reason '') -in @('NetworkContextChanged','NetworkChangedDuringObservation','UnsupportedEnvironmentChanged')){return 'NetworkChangedDuringComparison'}
    if($code -in @('CancellationPathInvalid','ConfigurationChanged','EngineMismatch')){return $code}
    if((PCmpField $Result Status '') -eq 'Blocked'){return 'ProbeIdentityUnknown'}
    $null
}
function Test-TCProtocolComparisonBudget {param($Result,$Targets)
    $samples=@(PCmpField $Result Samples @())
    if($samples.Count -ne 7){return $false}
    foreach($target in $Targets){
        $required=[bool]$target.Trace;$count=if($required){3}else{1}
        $rows=@($samples|Where-Object {(PCmpField $_ Name '') -ceq $target.Name})
        if($rows.Count -ne $count){return $false}
        for($i=1;$i -le $count;$i++){
            $row=@($rows|Where-Object {(PCmpField $_ Round 0) -eq $i})
            if($row.Count -ne 1 -or (PCmpField $row[0] TargetUrl '') -cne $target.Url -or [bool](PCmpField $row[0] Required $false) -ne $required -or (PCmpField $row[0] RequestBudgetSeconds 0) -ne 6){return $false}
        }
    };$true
}
function New-TCProtocolComparisonEmptyResult {param([string]$NodeId,[string]$ProfileId,$Profile)
    [pscustomobject]@{SchemaVersion=2;Status='NotTested';Code='ProfileUnavailable';NodeId=$NodeId;ProfileId=$ProfileId;Checks=@();ForwardingPassed=$false;ExitServerVerifiedTrace=$false;ObservedExitIPv4=$null;ExpectedExitIPv4=$null;ExpectedExitSource=$null;Transport='Unknown';TransportPath='NotStarted';PathStatus='Inconclusive';PathEvidence=[pscustomobject]@{Kind='Unknown';Verified=$false;EligibleForRecommendation=$false;NetworkFingerprint=$null;Binding=$null;Reason='NotStarted'};NetworkFingerprint=$null;NetworkChanged=$false;ContextChanged=$false;ConfigHash=$null;CandidateHash=(PCmpField $Profile CandidateSHA256);ManifestHash=(PCmpField $Profile ManifestSHA256);EngineSHA256=$null;RunId=$null;CheckedAtUtc=[DateTimeOffset]::UtcNow.ToString('o');DurationMs=0;CleanupComplete=$true;Samples=@();Metrics=$null;EvidencePath=$null;CancellationRequested=$false;SnapshotFingerprint=$null;UnderlayFingerprint=$null;NetworkFingerprintScope=$null}
}
function Merge-TCProtocolComparisonResult {param([string]$NodeId,[string]$ProfileId,$Profile,$Runs,$Comparison)
    $runsArray=@($Runs);$samples=New-Object 'Collections.Generic.List[object]'
    $result=if($runsArray.Count){PCmpClone $runsArray[-1].Result}else{New-TCProtocolComparisonEmptyResult $NodeId $ProfileId $Profile}
    foreach($run in $runsArray){
        foreach($sample in @(PCmpField $run.Result Samples @())){
            $copy=PCmpClone $sample
            foreach($field in @(@('ComparisonId',$Comparison.ComparisonId),@('ComparisonRound',$run.PairRound),@('ProtocolOrderPosition',$run.OrderPosition),@('ProbeRunId',(PCmpField $run.Result RunId)))){$copy|Add-Member NoteProperty $field[0] $field[1] -Force}
            $samples.Add($copy)
        }
    }
    $result.Samples=$samples.ToArray()
    $result.Metrics=Get-TCCandidateProbeMetrics -Samples $result.Samples -ProbeCount ([Math]::Max(1,$runsArray.Count))
    $result|Add-Member NoteProperty ProbeRuns $runsArray -Force
    $result|Add-Member NoteProperty Comparison $Comparison -Force
    $result|Add-Member NoteProperty ProbeEvidencePaths @($runsArray|ForEach-Object {PCmpField $_.Result EvidencePath}|Where-Object {$_}) -Force
    $result.EvidencePath=$null;$result.RunId=$Comparison.ComparisonId
    if($runsArray.Count){
        # Never replace a failed early round with the last successful result.
        # The earliest timestamp also bounds the lifetime of the entire dataset.
        $result.CheckedAtUtc=[string](@($runsArray|ForEach-Object {$_.Result}|Sort-Object {$at=[DateTimeOffset]::MinValue;$null=[DateTimeOffset]::TryParse([string](PCmpField $_ CheckedAtUtc ''),[ref]$at);$at})[0].CheckedAtUtc)
        $result.DurationMs=[int](($runsArray|ForEach-Object {[int](PCmpField $_.Result DurationMs 0)}|Measure-Object -Sum).Sum)
        $result.CleanupComplete=@($runsArray|Where-Object {-not (PCmpField $_.Result CleanupComplete $false)}).Count -eq 0
        $result.ForwardingPassed=@($runsArray|Where-Object {-not (PCmpField $_.Result ForwardingPassed $false)}).Count -eq 0
        $result.ExitServerVerifiedTrace=@($runsArray|Where-Object {-not (PCmpField $_.Result ExitServerVerifiedTrace $false) -or (PCmpField $_.Result ExpectedExitSource '') -cne 'ServerVerifiedTlsTrace' -or -not (PCmpField $_.Result ObservedExitIPv4 '') -or (PCmpField $_.Result ObservedExitIPv4 '') -cne (PCmpField $_.Result ExpectedExitIPv4 '')}).Count -eq 0
        $ips=@($runsArray|ForEach-Object {PCmpField $_.Result ObservedExitIPv4 ''}|Sort-Object -Unique)
        $consistent=($ips.Count -eq 1 -and [bool]$ips[0])
        $pathOK=@($runsArray|Where-Object {-not (PCmpField (PCmpField $_.Result PathEvidence) Verified $false) -or -not (PCmpField (PCmpField $_.Result PathEvidence) EligibleForRecommendation $false)}).Count -eq 0
        $result.PathEvidence.Verified=[bool]($pathOK -and $Comparison.SameNetwork)
        $result.PathEvidence.EligibleForRecommendation=[bool]($result.PathEvidence.Verified -and $result.ForwardingPassed -and $result.ExitServerVerifiedTrace -and $consistent -and $result.CleanupComplete -and $Comparison.SameBudget)
        $checks=@(foreach($name in @('AddressHttps','DomainDnsHttps')){
            $rows=@($result.Samples|Where-Object {$_.Required -and $_.Name -ceq $name})
            $passed=@($rows|Where-Object {$_.Status -eq 'Passed'}).Count;$failed=@($rows|Where-Object {$_.Status -eq 'Failed'}).Count
            [pscustomobject]@{Name=$name;Status=$(if($rows.Count -eq 3*$runsArray.Count -and $passed -eq $rows.Count){'Passed'}elseif($failed){'Failed'}else{'Inconclusive'});Code='ComparisonTargetSummary';SampleCount=$rows.Count;PassedCount=$passed;FailedCount=$failed;TimeoutCount=@($rows|Where-Object {$_.Code -eq 'ProbeTimeout'}).Count;Source='AuthenticatedCandidateProxy'}
        })
        $checks+=@($result.Samples|Where-Object {-not $_.Required})
        if(-not $consistent){$checks+=,[pscustomobject]@{Name='ExitConsistency';Status='Inconclusive';Code='ExitPoolChanged'};$result.ForwardingPassed=$false;$result.PathEvidence.EligibleForRecommendation=$false}
        $result.Checks=$checks
        $failedRuns=@($runsArray|Where-Object {(PCmpField $_.Result Status '') -eq 'Failed'})
        if($failedRuns.Count){$result.Status='Failed';$result.Code=[string]$failedRuns[0].Result.Code;$result.PathEvidence.EligibleForRecommendation=$false}
        elseif($result.PathEvidence.EligibleForRecommendation){$result.Status='Passed';$result.Code='CandidateReachabilityVerified'}
        else{$result.Status='Inconclusive';$result.PathEvidence.EligibleForRecommendation=$false}
    }
    if($Comparison.StopCode){
        $result.Code=$Comparison.StopCode;$result.Status=if($Comparison.StopCode -in @('ProbeCleanupFailed','ConfigurationChanged','EngineMismatch','CancellationPathInvalid','ComparisonPreparationFailed','ComparisonContractInvalid')){'Failed'}else{'Inconclusive'}
        $result.ForwardingPassed=$false;$result.ExitServerVerifiedTrace=$false;$result.PathEvidence.Verified=$false;$result.PathEvidence.EligibleForRecommendation=$false;$result.PathEvidence.Reason=$Comparison.StopCode
        $result.CleanupComplete=$Comparison.CleanupComplete
        $result.CancellationRequested=$Comparison.CancellationRequested
        $result.ContextChanged=($Comparison.StopCode -eq 'NetworkChangedDuringComparison')
    }
    $result.PathStatus=if($result.PathEvidence.Verified){'Passed'}else{'Inconclusive'}
    $result.TransportPath=if($result.PathEvidence.Verified){$result.PathEvidence.Kind}elseif($runsArray.Count){'ExistingSystemRoute'}else{'NotStarted'}
    $result
}
function Invoke-TCProtocolComparison {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][string]$NodeId,[string]$ExpectedExitIPv4,[string]$ExpectedExitSource,[string]$CancellationPath,[ValidateRange(5,360)][int]$TimeoutSeconds=360,[ValidateRange(0,2147483647)][int]$InterfaceIndex=0,[scriptblock]$ProgressCallback)
    $ErrorActionPreference='Stop';$watch=[Diagnostics.Stopwatch]::StartNew();$id=[guid]::NewGuid().ToString('D')
    $nodeModule=$null;$lease=$null;$cancellation=$null;$full=$null;$normalized=$NodeId;$targets=@();$profiles=@{};$runs=New-Object 'Collections.Generic.List[object]';$probePending=$false;$bindingResult=$null;$readyProfiles=@()
    $comparison=[pscustomobject]@{SchemaVersion=1;ComparisonId=$id;NodeId=$NodeId;PlannedPairRounds=3;CompletedPairRounds=0;Completed=$false;ProtocolOrder=@([pscustomobject]@{Round=1;Order=@('Udp','Tcp')},[pscustomobject]@{Round=2;Order=@('Tcp','Udp')},[pscustomobject]@{Round=3;Order=@('Udp','Tcp')});MaxProbes=6;CompletedProbes=0;SampleBudgetPerProbe=6;ApplicationBudgetPerProbe=1;MaxRequests=42;RequestsAttempted=0;RequestBudgetSeconds=6;ProbeTimeoutSeconds=60;MaxDurationSeconds=$TimeoutSeconds;MaxResponseBytesPerRequest=65536;MaxResponseBytes=2752512;Concurrency=1;RequestRetries=0;FixedTargets=@();SnapshotFingerprint=$null;SameNetwork=$true;SameBudget=$true;CleanupComplete=$true;StopCode=$null;CancellationRequested=$false;PerformanceRanked=$false;Measurement='Bounded HTTPS response through a new authenticated HttpClient per request';PacketLossMeasured=$false;CheckedAtUtc=[DateTimeOffset]::UtcNow.ToString('o');DurationMs=0}
    try{
        $nodeModule=Import-Module (Join-Path $PSScriptRoot 'NodeStore.psm1') -PassThru -DisableNameChecking
        $full=& $nodeModule {param($r)$p=Get-TCFullPath $r;Assert-TCNoReparse $p;$p} $Root
        $normalized=& $nodeModule {param($n)ConvertTo-TCId $n} $NodeId;$comparison.NodeId=$normalized
        try{$cancellation=& $script:TCComparisonCandidate {param($r,$p,$n)Resolve-TCCandidateCancellation $r $p $n} $full $CancellationPath $nodeModule}catch{$comparison.StopCode='CancellationPathInvalid';throw}
        & $script:TCComparisonCandidate {param($c,$n)Assert-TCCandidateNotCancelled $c $n} $cancellation $nodeModule
        # This lease spans the alternating sequence. Each probe additionally
        # acquires the existing node session lock and proves previous cleanup.
        # No private/session lock bypass or concurrent engine is introduced.
        $probes=Join-Path $full 'probes';$null=& $nodeModule {param($p)New-TCPrivateDirectory $p} $probes
        $lockPath=Join-Path $probes '.comparison.lock';$null=& $nodeModule {param($p)Assert-TCNoReparse $p} $lockPath
        try{$lease=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}catch{$comparison.StopCode='ProbeIdentityUnknown';throw}
        Publish-TCProtocolComparisonProgress $ProgressCallback ([pscustomobject]@{Stage='PreparingProbePath';BindingResult=$null;ProfileId=$null;Round=0})
        # The preparation owns and releases its session/index/line locks before
        # each probe obtains the normal session lock. The comparison lease
        # fences this complete operation without bypassing active-identity checks.
        $bindingResult=Prepare-TCProtocolComparisonBinding $full $normalized $InterfaceIndex
        if(-not $bindingResult -or $bindingResult.LineId -cne $normalized){$comparison.StopCode='ComparisonPreparationFailed';throw 'Binding result does not identify this line'}
        if($bindingResult.State -eq 'Blocked'){$comparison.StopCode=[string]$bindingResult.Code;throw 'Candidate identity or preparation is blocked'}
        $bindingRows=@($bindingResult.Results)
        $seen=@{}
        foreach($row in $bindingRows){
            if($row.ProfileId -notin @('Udp','Tcp') -or $seen.ContainsKey([string]$row.ProfileId)){$comparison.StopCode='ComparisonContractInvalid';throw 'Invalid binding profile result'}
            $seen[[string]$row.ProfileId]=$true
            if($row.BindingState -in @('Prepared','Reused')){$readyProfiles+=,[string]$row.ProfileId}
        }
        Publish-TCProtocolComparisonProgress $ProgressCallback ([pscustomobject]@{Stage='CheckingProfiles';BindingResult=$bindingResult;ProfileId=$null;Round=0})
        & $script:TCComparisonCandidate {param($c,$n)Assert-TCCandidateNotCancelled $c $n} $cancellation $nodeModule
        # Preparation may publish new immutable revisions. Never cache a profile
        # before it, or compare the resulting receipt against an obsolete hash.
        foreach($profileId in @('Udp','Tcp')){
            $p=Get-TCProtocolComparisonProfile $full $normalized $profileId
            if($p){if((PCmpField $p Id '') -cne $profileId){throw 'Profile mismatch'};$profiles[$profileId]=$p}
        }
        foreach($profileId in $readyProfiles){
            $row=@($bindingRows|Where-Object ProfileId -ceq $profileId)[0]
            if(-not $profiles.ContainsKey($profileId) -or [string](PCmpField $row CandidateSHA256 '') -cne [string]$profiles[$profileId].CandidateSHA256 -or [string](PCmpField $row ManifestSHA256 '') -cne [string]$profiles[$profileId].ManifestSHA256){$comparison.StopCode='ConfigurationChanged';throw 'Binding and reloaded profile disagree'}
        }
        if(-not $readyProfiles.Count){$comparison.StopCode=[string]$bindingResult.Code;if(-not $comparison.StopCode){$comparison.StopCode='ProbeBindingUnsupported'};throw 'No supported candidate binding'}
        $targets=@(& $script:TCComparisonCandidate {Get-TCCandidateProbeTargets})
        if($targets.Count -ne 3 -or @($targets|Where-Object {$_.Trace -and $_.Name -in @('AddressHttps','DomainDnsHttps')}).Count -ne 2 -or @($targets|Where-Object {-not $_.Trace -and $_.Name -ceq 'ChatGPTWeb'}).Count -ne 1){$comparison.StopCode='ComparisonContractInvalid';throw 'Fixed target contract invalid'}
        $comparison.FixedTargets=$targets
        $context=Get-TCProtocolComparisonContext;$snapshot=[string](PCmpField $context SnapshotFingerprint (PCmpField $context Fingerprint ''))
        if((PCmpField $context Status '') -ne 'Available' -or $snapshot -notmatch '^[A-Fa-f0-9]{64}$'){$comparison.StopCode='NetworkContextUnavailable';$comparison.SameNetwork=$false;throw 'Network snapshot unavailable'}
        $comparison.SnapshotFingerprint=$snapshot
        $schedule=@(foreach($pair in $comparison.ProtocolOrder){for($order=0;$order -lt 2;$order++){[pscustomobject]@{PairRound=$pair.Round;OrderPosition=($order+1);ProfileId=$pair.Order[$order]}}})
        # A single prepared protocol retains reachability fallback, but cannot
        # become a completed/performance comparison.
        if($readyProfiles.Count -lt 2){$schedule=@($schedule|Where-Object {$_.PairRound -eq 1 -and $readyProfiles -contains $_.ProfileId})}
        foreach($slot in $schedule){
            & $script:TCComparisonCandidate {param($c,$n)Assert-TCCandidateNotCancelled $c $n} $cancellation $nodeModule
            $before=Get-TCProtocolComparisonContext
            if((PCmpField $before Status '') -ne 'Available' -or (PCmpField $before SnapshotFingerprint (PCmpField $before Fingerprint '')) -cne $snapshot){$comparison.StopCode='NetworkChangedDuringComparison';$comparison.SameNetwork=$false;break}
            $remaining=[int][Math]::Floor($TimeoutSeconds-$watch.Elapsed.TotalSeconds-6)
            if($remaining -lt 5){$comparison.StopCode='ComparisonTimeBudgetExhausted';break}
            Publish-TCProtocolComparisonProgress $ProgressCallback ([pscustomobject]@{Stage='CheckingProfiles';BindingResult=$bindingResult;ProfileId=$slot.ProfileId;Round=$slot.PairRound;OrderPosition=$slot.OrderPosition})
            $probePending=$true
            $result=Invoke-TCProtocolComparisonProbe -Root $full -NodeId $normalized -ProfileId $slot.ProfileId -ExpectedExitIPv4 $ExpectedExitIPv4 -ExpectedExitSource $ExpectedExitSource -CancellationPath $CancellationPath -TimeoutSeconds ([Math]::Min(60,$remaining))
            $probePending=$false
            if(-not $result){$comparison.StopCode='ProbeIdentityUnknown';$comparison.CleanupComplete=$false;break}
            $runs.Add([pscustomobject]@{PairRound=$slot.PairRound;OrderPosition=$slot.OrderPosition;Sequence=($runs.Count+1);ProfileId=$slot.ProfileId;Result=$result})
            $comparison.CleanupComplete=[bool]($comparison.CleanupComplete -and (PCmpField $result CleanupComplete $false))
            $comparison.SameBudget=[bool]($comparison.SameBudget -and (Test-TCProtocolComparisonBudget $result $targets))
            $stop=Get-TCProtocolComparisonStopCode $result
            if($stop){$comparison.StopCode=$stop;if($stop -eq 'NetworkChangedDuringComparison'){$comparison.SameNetwork=$false};break}
            $p=$profiles[$slot.ProfileId]
            if((PCmpField $result CandidateHash '') -ine (PCmpField $p CandidateSHA256 '') -or (PCmpField $result ManifestHash '') -ine (PCmpField $p ManifestSHA256 '')){$comparison.StopCode='ConfigurationChanged';break}
            $previous=@($runs|Where-Object {$_.ProfileId -ceq $slot.ProfileId})
            if(@($previous|Where-Object {(PCmpField $_.Result CandidateHash '') -cne (PCmpField $result CandidateHash '') -or (PCmpField $_.Result ManifestHash '') -cne (PCmpField $result ManifestHash '') -or (PCmpField $_.Result NetworkFingerprint '') -cne (PCmpField $result NetworkFingerprint '')}).Count){$comparison.StopCode='ConfigurationChanged';break}
            $engines=@($runs|ForEach-Object {[string](PCmpField $_.Result EngineSHA256 '')}|Sort-Object -Unique)
            if($engines.Count -gt 1){$comparison.StopCode='EngineMismatch';break}
            $rawSnapshot=[string](PCmpField $result SnapshotFingerprint '')
            if($rawSnapshot -and $rawSnapshot -cne $snapshot){$comparison.StopCode='NetworkChangedDuringComparison';$comparison.SameNetwork=$false;break}
            if(-not $rawSnapshot){$comparison.SameNetwork=$false}
            & $script:TCComparisonCandidate {param($c,$n)Assert-TCCandidateNotCancelled $c $n} $cancellation $nodeModule
            $after=Get-TCProtocolComparisonContext
            if((PCmpField $after Status '') -ne 'Available' -or (PCmpField $after SnapshotFingerprint (PCmpField $after Fingerprint '')) -cne $snapshot){$comparison.StopCode='NetworkChangedDuringComparison';$comparison.SameNetwork=$false;break}
        }
    }catch{
        if($_.Exception.Data['TCProbeCancellationRequested']){$comparison.StopCode='ProbeCancelled'}
        elseif($_.Exception.Data['TCProbeCancellationPathInvalid']){$comparison.StopCode='CancellationPathInvalid'}
        elseif(-not $comparison.StopCode){$comparison.StopCode='ComparisonPreparationFailed'}
        # Delegate exceptions cannot prove ownership cleanup. Never continue
        # the next profile based on an absent probe receipt.
        if($probePending){$comparison.StopCode='ProbeIdentityUnknown';$comparison.CleanupComplete=$false}
    }finally{
        if($lease){try{$lease.Dispose()}catch{$comparison.StopCode='ProbeCleanupFailed';$comparison.CleanupComplete=$false}}
    }
    if($cancellation -and $comparison.StopCode -notin @('ProbeCleanupFailed','CancellationPathInvalid')){
        try{if(& $script:TCComparisonCandidate {param($c,$n)Test-TCCandidateCancellation $c $n} $cancellation $nodeModule){$comparison.StopCode='ProbeCancelled'}}catch{$comparison.StopCode='CancellationPathInvalid'}
    }
    $comparison.CompletedProbes=$runs.Count
    $comparison.CompletedPairRounds=@(1..3|Where-Object {$round=$_;@($runs|Where-Object {$_.PairRound -eq $round}).Count -eq 2}).Count
    $comparison.Completed=[bool]($runs.Count -eq 6 -and $comparison.CompletedPairRounds -eq 3 -and -not $comparison.StopCode -and $comparison.CleanupComplete)
    $comparison.CancellationRequested=[bool]($comparison.StopCode -eq 'ProbeCancelled' -or @($runs|Where-Object {PCmpField $_.Result CancellationRequested $false}).Count -gt 0)
    $comparison.RequestsAttempted=@($runs|ForEach-Object {PCmpField $_.Result Samples @()}|Where-Object {PCmpField $_ Attempted $false}).Count
    $comparison.DurationMs=[int]$watch.ElapsedMilliseconds
    $results=@(foreach($profileId in @('Udp','Tcp')){
        $profile=if($profiles.ContainsKey($profileId)){$profiles[$profileId]}else{$null}
        $selectedRuns=@($runs|Where-Object {$_.ProfileId -ceq $profileId})
        $result=Merge-TCProtocolComparisonResult $normalized $profileId $profile $selectedRuns $comparison
        if(-not $selectedRuns.Count -and -not $comparison.StopCode -and $profile){
            $row=@($bindingResult.Results|Where-Object ProfileId -ceq $profileId)|Select-Object -First 1
            $result.Status='Inconclusive';$result.Code=[string](PCmpField $row ReasonCode 'ProbeBindingUnsupported');$result.PathEvidence.Reason=$result.Code
        }
        [pscustomobject]@{ProfileId=$profileId;Result=$result}
    })
    [pscustomobject]@{SchemaVersion=1;ComparisonId=$id;Status=$(if($comparison.Completed){'Completed'}elseif($comparison.CancellationRequested){'Cancelled'}elseif($comparison.StopCode){'Stopped'}else{'Incomplete'});Code=$(if($comparison.StopCode){$comparison.StopCode}elseif($comparison.Completed){'ProtocolComparisonCompleted'}else{'ProtocolComparisonIncomplete'});BindingResult=$bindingResult;Results=$results;Comparison=$comparison}
}
Export-ModuleMember -Function Invoke-TCProtocolComparison
