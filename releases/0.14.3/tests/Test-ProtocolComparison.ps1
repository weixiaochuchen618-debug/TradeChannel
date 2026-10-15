#requires -Version 5.1
[CmdletBinding()]param()
$ErrorActionPreference='Stop';Set-StrictMode -Version 2.0
if($PSVersionTable.PSEdition -ne 'Core'){$env:PSModulePath=Join-Path $PSHOME 'Modules'}
$package=Split-Path $PSScriptRoot -Parent
$cmp=Import-Module (Join-Path $package 'ProtocolComparison.psm1') -Force -PassThru -DisableNameChecking
$selection=Import-Module (Join-Path $package 'ProtocolSelection.psm1') -Force -PassThru -DisableNameChecking
$work=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('TC-ProtocolComparison-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($work);$nodeId=[guid]::NewGuid().ToString('D');$script:Checks=0
$profiles=@([pscustomobject]@{Id='Udp';CandidateSHA256=('A'*64);ManifestSHA256=('D'*64);Validation=$null},[pscustomobject]@{Id='Tcp';CandidateSHA256=('B'*64);ManifestSHA256=('E'*64);Validation=$null})
$context=[pscustomobject]@{Status='Available';Fingerprint=('C'*64);SnapshotFingerprint=('C'*64)}
function Check {param([bool]$Condition,[string]$Label)if(-not $Condition){throw ('Protocol comparison: '+$Label)};$script:Checks++}
function Clone {param($Value)
    $json=$Value|ConvertTo-Json -Depth 60
    if((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')){ConvertFrom-Json $json -DateKind String}else{ConvertFrom-Json $json}
}
function Reset-Fixture {param([string]$Mode='FastTcp')
    & $cmp {param($m,$p)$script:Mode=$m;$script:Profiles=$p;$script:Calls=0;$script:Busy=$false;$script:MaxConcurrent=0;$script:PreviousClean=$true;$script:Order=@();$script:CancelPath='';$script:CancelAttempt='';$script:Now=[DateTimeOffset]::UtcNow} $Mode $profiles
}
function Invoke-FixtureComparison {param([string]$CancellationPath,[int]$TimeoutSeconds=360)
    Invoke-TCProtocolComparison -Root $work -NodeId $nodeId -ExpectedExitIPv4 '192.0.2.40' -ExpectedExitSource ServerVerifiedTlsTrace -CancellationPath $CancellationPath -TimeoutSeconds $TimeoutSeconds
}
function Normalize {param($Run)
    $p=Clone $profiles
    foreach($profile in $p){$r=@($Run.Results|Where-Object {$_.ProfileId -ceq $profile.Id})[0];$profile.Validation=ConvertTo-TCProtocolEvidence -Result $r.Result -Profile $profile -NetworkContext $context}
    $p
}
function Recommend {param($Run,[string]$Mode='Auto')
    $p=@(Normalize $Run);Get-TCProtocolRecommendation -Profiles $p -RequestedMode $Mode -NetworkContext $context -LineId $nodeId
}
try{
    & $cmp {
        # Comparison budget/merge unit tests isolate only this preparation seam.
        # The separate workflow integration runs the real LineStore publication.
        function script:Prepare-TCProtocolComparisonBinding {param($Root,$NodeId,$InterfaceIndex)
            $rows=@($script:Profiles|Where-Object {$script:Mode -ne 'NoTcp' -or $_.Id -ne 'Tcp'}|ForEach-Object {[pscustomobject]@{ProfileId=$_.Id;BindingState='Reused';ReasonCode='StoredBindingUnchanged';CandidateSHA256=$_.CandidateSHA256;ManifestSHA256=$_.ManifestSHA256}})
            [pscustomobject]@{LineId=$NodeId;State='Ready';Code='BindingsPrepared';Prepared=$false;Results=$rows}
        }
        function script:Get-TCProtocolComparisonContext {
            $fp=if($script:Mode -eq 'BetweenNetwork' -and $script:Calls -gt 0){'F'*64}else{'C'*64}
            [pscustomobject]@{Status='Available';Fingerprint=$fp;SnapshotFingerprint=$fp}
        }
        function script:Get-TCProtocolComparisonProfile {param($Root,$NodeId,$ProfileId)
            if($script:Mode -eq 'NoTcp' -and $ProfileId -eq 'Tcp'){return $null};@($script:Profiles|Where-Object {$_.Id -ceq $ProfileId})[0]
        }
        function script:Invoke-TCProtocolComparisonProbe {
            param($Root,$NodeId,$ProfileId,$ExpectedExitIPv4,$ExpectedExitSource,$CancellationPath,$TimeoutSeconds)
            if($script:Busy -or -not $script:PreviousClean){throw 'Concurrent or unclean identity reuse'}
            $script:Busy=$true;$script:Calls++;$script:MaxConcurrent=[Math]::Max($script:MaxConcurrent,1);$script:Order+=,$ProfileId
            try{
                if($script:Mode -eq 'Throw'){throw 'Simulated delegate lost its receipt'}
                $seq=$script:Calls;$pairRound=[int][Math]::Floor(($seq-1)/2)+1;$p=@($script:Profiles|Where-Object {$_.Id -eq $ProfileId})[0];$samples=@()
                foreach($round in 1..3){foreach($target in @([pscustomobject]@{Name='AddressHttps';Url='https://1.1.1.1/cdn-cgi/trace'},[pscustomobject]@{Name='DomainDnsHttps';Url='https://www.cloudflare.com/cdn-cgi/trace'})){
                    $duration=if($ProfileId -eq 'Udp'){120}else{50}
                    if($script:Mode -eq 'FastUdp'){$duration=if($ProfileId -eq 'Udp'){50}else{120}}
                    if($script:Mode -eq 'Tie'){$duration=100}
                    if($script:Mode -eq 'SmallAbsolute'){$duration=if($ProfileId -eq 'Udp'){15}else{5}}
                    if($script:Mode -eq 'SmallRelative'){$duration=if($ProfileId -eq 'Udp'){1010}else{990}}
                    if($target.Name -eq 'DomainDnsHttps'){$duration+=40}
                    if($script:Mode -eq 'TargetConflict' -and $target.Name -eq 'DomainDnsHttps'){$duration=if($ProfileId -eq 'Udp'){50}else{200}}
                    if($script:Mode -eq 'OrderSensitive' -and $pairRound -eq 2){$duration=if($ProfileId -eq 'Udp'){50}else{140}}
                    $duration+=($pairRound*2+$round)
                    $samples+=,[pscustomobject]@{Name=$target.Name;TargetUrl=$target.Url;TargetHost=([uri]$target.Url).Host;Round=$round;SampleIndex=($samples.Count+1);Required=$true;Attempted=$true;RequestBudgetSeconds=6;Status='Passed';Code='HttpsReached';HttpStatus=200;TlsVerified=$true;ObservedExitIPv4=$ExpectedExitIPv4;DurationMs=$duration;Source='AuthenticatedCandidateProxy';Phase='RepeatedNewHttpClient'}
                }}
                $samples+=,[pscustomobject]@{Name='ChatGPTWeb';TargetUrl='https://chatgpt.com/';TargetHost='chatgpt.com';Round=1;SampleIndex=7;Required=$false;Attempted=$true;RequestBudgetSeconds=6;Status='UserVerificationRequired';Code='BrowserChallenge';HttpStatus=403;TlsVerified=$true;ObservedExitIPv4=$null;DurationMs=20;Source='AuthenticatedCandidateProxy';Phase='FirstTargetRequest'}
                $path=[pscustomobject]@{Kind='BoundInterfaceObserved';Verified=$true;EligibleForRecommendation=$true;NetworkFingerprint=('C'*64);Reason='FixtureOwnedPath'}
                $raw=[pscustomobject]@{SchemaVersion=2;Status='Passed';Code='CandidateReachabilityVerified';NodeId=$NodeId;ProfileId=$ProfileId;Checks=@([pscustomobject]@{Name='AddressHttps';Status='Passed'},[pscustomobject]@{Name='DomainDnsHttps';Status='Passed'});ForwardingPassed=$true;ExitServerVerifiedTrace=$true;ObservedExitIPv4=$ExpectedExitIPv4;ExpectedExitIPv4=$ExpectedExitIPv4;ExpectedExitSource=$ExpectedExitSource;Transport=$(if($ProfileId -eq 'Udp'){'WireGuardUdp'}else{'WireGuardOverVlessReality'});TransportPath='BoundInterfaceObserved';PathStatus='Passed';PathEvidence=$path;NetworkFingerprint=('C'*64);SnapshotFingerprint=('C'*64);UnderlayFingerprint=('C'*64);NetworkChanged=$false;ContextChanged=$false;CandidateHash=$p.CandidateSHA256;ManifestHash=$p.ManifestSHA256;ConfigHash=('8'*64);EngineSHA256=('9'*64);RunId=[guid]::NewGuid().ToString('D');CheckedAtUtc=$script:Now.AddMilliseconds($seq).ToString('o');DurationMs=10;CleanupComplete=$true;CancellationRequested=$false;Samples=$samples;Metrics=$null;EvidencePath=$null}
                if($script:Mode -eq 'Timeout' -and $seq -eq 1){$samples[1].Status='Failed';$samples[1].Code='ProbeTimeout';$samples[1].DurationMs=6000;$samples[1].TlsVerified=$false;$samples[1].ObservedExitIPv4=$null;$raw.Status='Failed';$raw.Code='CandidateForwardingFailed';$raw.ForwardingPassed=$false;$raw.ExitServerVerifiedTrace=$false;$path.EligibleForRecommendation=$false}
                if($script:Mode -eq 'BadBudget'){$samples[0].RequestBudgetSeconds=2}
                if($script:Mode -eq 'DifferentUrl'){$samples[0].TargetUrl+='?changed=1'}
                if($script:Mode -eq 'DuplicateRound'){$samples[2].Round=1}
                if($script:Mode -eq 'MissingUrl'){$samples[0].PSObject.Properties.Remove('TargetUrl')}
                if($script:Mode -in @('Cancel','CancelCleanup')){[IO.File]::WriteAllText($script:CancelPath,(@{AttemptId=$script:CancelAttempt}|ConvertTo-Json -Compress),(New-Object Text.UTF8Encoding($false)))}
                if($script:Mode -in @('Cleanup','CancelCleanup')){$raw.Code='ProbeCleanupFailed';$raw.CleanupComplete=$false;$script:PreviousClean=$false}
                if($script:Mode -eq 'CancelCleanup'){$raw.CancellationRequested=$true}
                if($script:Mode -in @('Identity','IdentityUnknown')){$raw.Code=if($script:Mode -eq 'Identity'){'ActiveIdentity'}else{'ProbeIdentityUnknown'};$raw.Status='Inconclusive';$raw.ForwardingPassed=$false;$path.EligibleForRecommendation=$false;$raw.Samples=@()}
                if($script:Mode -eq 'Network'){$raw.ContextChanged=$true;$raw.Code='NetworkChangedDuringComparison';$path.Reason='NetworkContextChanged'}
                if($script:Mode -eq 'SnapshotDrift'){$raw.SnapshotFingerprint='F'*64}
                if($script:Mode -eq 'EngineDrift' -and $seq -eq 2){$raw.EngineSHA256='F'*64}
                if($script:Mode -eq 'HashDrift' -and $seq -eq 4){$raw.CandidateHash='F'*64}
                if($script:Mode -eq 'ExpiredRound' -and $seq -eq 1){$raw.CheckedAtUtc=$script:Now.AddMinutes(-31).ToString('o')}
                $raw
            }finally{$script:Busy=$false}
        }
    }
    Reset-Fixture
    $run=Invoke-FixtureComparison;$p=@(Normalize $run);$decision=Get-TCProtocolRecommendation -Profiles $p -NetworkContext $context -LineId $nodeId
    Check ($run.Status -eq 'Completed' -and $run.Results.Count -eq 2 -and $run.Results[0].ProfileId -ceq 'Udp' -and $run.Results[1].ProfileId -ceq 'Tcp') 'Results wrapper is stable and directly consumable'
    Check ((& $cmp {$script:Order -join ','}) -ceq 'Udp,Tcp,Tcp,Udp,Udp,Tcp' -and (& $cmp {$script:MaxConcurrent}) -eq 1 -and (& $cmp {$script:Calls}) -eq 6) 'three pair rounds alternate, never overlap, and require previous cleanup'
    Check ($run.Comparison.MaxRequests -eq 42 -and $run.Comparison.RequestsAttempted -eq 42 -and $run.Comparison.MaxResponseBytes -eq 2752512 -and $run.Comparison.CompletedPairRounds -eq 3 -and $run.Comparison.SameNetwork -and $run.Comparison.SameBudget) 'comparison has a fixed bounded total and equal request budgets'
    foreach($result in $run.Results){
        Check ($result.Result.Samples.Count -eq 21 -and $result.Result.ProbeRuns.Count -eq 3 -and $result.Result.Metrics.SampleBudget -eq 18 -and $result.Result.Metrics.ApplicationBudget -eq 3 -and $result.Result.Metrics.PerProbeSampleBudget -eq 6 -and $result.Result.Metrics.MaxRequests -eq 21) 'aggregation adds rounds without increasing a single probe boundary'
        Check (@($result.Result.Samples|Where-Object {$_.ComparisonRound -in @(1,2,3) -and $_.ProbeRunId -and $_.TargetUrl}).Count -eq 21 -and $result.Result.Metrics.TargetMetrics.Count -eq 3) 'raw samples retain pairing identity and separate target metrics'
    }
    Check ($decision.RecommendedProfileId -eq 'Tcp' -and $decision.Source -eq 'Performance' -and $decision.PerformanceRanked -and $decision.PairedSampleCount -eq 18 -and $decision.PairedRoundCount -eq 3 -and $decision.TargetComparisons.Count -eq 2) 'large consistent same-target response advantage can recommend TCP'
    Check ($decision.PerformanceThresholds.MinimumAbsoluteAdvantageMs -eq 20 -and $decision.PerformanceThresholds.MinimumRelativeAdvantage -eq 0.20 -and $decision.PerformanceThresholds.PolicyKind -eq 'EngineeringScreen' -and $decision.PolicyVersion -ceq 'PairedHttpsEngineering.v1' -and $decision.Reason -notmatch '统计显著|交易延迟最佳') 'engineering thresholds and version are explicit without statistical or trading claims'
    Check (Test-TCProtocolRecommendationCurrent $decision $p $context) 'fresh performance selection is reproducible'
    $manual=Get-TCProtocolRecommendation -Profiles $p -RequestedMode Udp -NetworkContext $context -LineId $nodeId
    Check ($manual.Status -eq 'UserChoice' -and $manual.PreferredProfileId -eq 'Udp' -and -not $manual.PerformanceRanked -and -not $manual.RecommendedProfileId) 'manual choice overrides a measured performance winner'
    foreach($change in @('Metrics','EvidenceMetrics','PairDuration','AggregateSample','Budget','Network','ComparisonQuality','PairOrder','AggregatePath','AggregateHash','AggregateExit','AggregateTimestamp','PolicyVersion','RecommendationMetrics','RecommendationThresholds')){
        $changed=Clone $p;$old=Clone $decision
        switch($change){
            'Metrics'{$changed[0].Validation.Result.Metrics.TargetMetrics[0].Successful.MedianResponseMs=999}
            'EvidenceMetrics'{$changed[0].Validation.Metrics.TargetMetrics[0].Successful.MedianResponseMs=999}
            'PairDuration'{$changed[0].Validation.Result.ProbeRuns[0].Result.Samples[0].DurationMs=999}
            'AggregateSample'{$changed[0].Validation.Result.Samples[0].DurationMs=999}
            'Budget'{$changed[0].Validation.Result.ProbeRuns[0].Result.Samples[0].RequestBudgetSeconds=1}
            'Network'{$changed[0].Validation.Result.Comparison.SnapshotFingerprint='F'*64}
            'ComparisonQuality'{$changed[0].Validation.Result.Comparison.CompletedPairRounds=2}
            'PairOrder'{$changed[0].Validation.Result.ProbeRuns[0].OrderPosition=2}
            'AggregatePath'{$changed[0].Validation.Result.PathEvidence.Verified=$false}
            'AggregateHash'{$changed[0].Validation.Result.CandidateHash='F'*64}
            'AggregateExit'{$changed[0].Validation.Result.ExpectedExitSource='ConfiguredAddress'}
            'AggregateTimestamp'{$changed[0].Validation.Result.CheckedAtUtc=[DateTimeOffset]::UtcNow.AddMinutes(-31).ToString('o')}
            'PolicyVersion'{$old.PolicyVersion='PairedHttpsEngineering.v0'}
            'RecommendationMetrics'{$old.TargetComparisons[0].TcpMedianResponseMs=999}
            'RecommendationThresholds'{$old.PerformanceThresholds.MinimumAbsoluteAdvantageMs=1}
        }
        Check (-not (Test-TCProtocolRecommendationCurrent $old $changed $context)) ('selection digest rejects changed '+$change)
    }
    foreach($mode in @('Tie','SmallAbsolute','SmallRelative','TargetConflict','OrderSensitive')){
        Reset-Fixture $mode;$case=Invoke-FixtureComparison;$rec=Recommend $case
        Check ($case.Comparison.Completed -and $rec.RecommendedProfileId -eq 'Udp' -and $rec.Source -eq 'PolicyDefault' -and -not $rec.PerformanceRanked) ($mode+' never creates unsupported performance ranking')
    }
    foreach($mode in @('BadBudget','DifferentUrl','DuplicateRound','MissingUrl')){
        Reset-Fixture $mode;$case=Invoke-FixtureComparison;$rec=Recommend $case
        Check ($case.Comparison.Completed -and -not $case.Comparison.SameBudget -and -not $rec.RecommendedProfileId -and -not $rec.PerformanceRanked -and -not (Test-TCProtocolRecommendationCurrent $rec @(Normalize $case) $context)) ($mode+' invalid target/budget pairing cannot become a current automatic recommendation')
    }
    Reset-Fixture FastUdp;$fastUdp=Recommend (Invoke-FixtureComparison)
    Check ($fastUdp.RecommendedProfileId -eq 'Udp' -and $fastUdp.Source -eq 'Performance' -and $fastUdp.PerformanceRanked) 'either protocol can win supported response ranking'
    Reset-Fixture Timeout;$failed=Invoke-FixtureComparison;$stable=Recommend $failed
    $udpResult=$failed.Results[0].Result;$domain=@($udpResult.Metrics.TargetMetrics|Where-Object {$_.Name -ceq 'DomainDnsHttps'})[0]
    Check ($failed.Comparison.Completed -and (& $cmp {$script:Calls}) -eq 6 -and $udpResult.Status -eq 'Failed' -and $udpResult.Metrics.Failed -eq 1 -and $udpResult.Metrics.TimedOut -eq 1 -and $domain.FailedResponses.MedianResponseMs -eq 6000 -and $domain.Successful.Count -eq 8) 'ordinary timeout remains in target denominator and cannot be hidden by later passes'
    Check ($stable.RecommendedProfileId -eq 'Tcp' -and $stable.Source -eq 'Stability' -and -not $stable.PerformanceRanked) 'successful response speed cannot override required-sample stability'
    Reset-Fixture ExpiredRound;$expired=Invoke-FixtureComparison;$expiredP=@(Normalize $expired)
    Check ($expiredP[0].Validation.Status -eq 'Stale' -and -not $expiredP[0].Validation.EligibleForAutomaticSelection -and -not (Recommend $expired).PerformanceRanked) 'aggregation preserves earliest evidence expiry'
    foreach($case in @(@{Mode='Identity';Code='ActiveIdentity';Calls=1},@{Mode='IdentityUnknown';Code='ProbeIdentityUnknown';Calls=1},@{Mode='Cleanup';Code='ProbeCleanupFailed';Calls=1},@{Mode='Network';Code='NetworkChangedDuringComparison';Calls=1},@{Mode='BetweenNetwork';Code='NetworkChangedDuringComparison';Calls=1},@{Mode='SnapshotDrift';Code='NetworkChangedDuringComparison';Calls=1},@{Mode='EngineDrift';Code='EngineMismatch';Calls=2},@{Mode='HashDrift';Code='ConfigurationChanged';Calls=4},@{Mode='Throw';Code='ProbeIdentityUnknown';Calls=1})){
        Reset-Fixture $case.Mode;$stopped=Invoke-FixtureComparison;$rec=Recommend $stopped
        Check ($stopped.Code -ceq $case.Code -and (& $cmp {$script:Calls}) -eq $case.Calls -and -not $stopped.Comparison.Completed -and -not $rec.RecommendedProfileId -and -not $rec.PerformanceRanked -and @($stopped.Results|Where-Object {$_.Result.PathStatus -eq 'Passed' -or $_.Result.PathEvidence.EligibleForRecommendation}).Count -eq 0) ($case.Mode+' immediately fences both protocols and the next probe')
    }
    Reset-Fixture NoTcp;$single=Invoke-FixtureComparison;$singleRec=Recommend $single
    Check ((& $cmp {$script:Calls}) -eq 1 -and $single.Status -eq 'Incomplete' -and $single.Results[1].Result.Code -eq 'ProfileUnavailable' -and $singleRec.RecommendedProfileId -eq 'Udp' -and $singleRec.Source -eq 'Reachability' -and -not $singleRec.PerformanceRanked) 'one prepared protocol keeps reachability fallback without fabricating pairs'
    $runDir=Join-Path (Join-Path $work 'deployments\runs') ([guid]::NewGuid().ToString('D'));$null=[IO.Directory]::CreateDirectory($runDir)
    $attempt=[guid]::NewGuid().ToString('N');$cancelPath=Join-Path $runDir ('probe-cancel-'+$attempt+'.json')
    [IO.File]::WriteAllText($cancelPath,(@{AttemptId=$attempt}|ConvertTo-Json -Compress))
    Reset-Fixture;$pre=Invoke-FixtureComparison $cancelPath
    Check ($pre.Code -eq 'ProbeCancelled' -and (& $cmp {$script:Calls}) -eq 0 -and $pre.Results.Count -eq 2 -and -not (Recommend $pre).RecommendedProfileId) 'preexisting marker cancels the entire comparison before startup'
    [IO.File]::Delete($cancelPath)
    foreach($mode in @('Cancel','CancelCleanup')){
        Reset-Fixture $mode;& $cmp {param($p,$a)$script:CancelPath=$p;$script:CancelAttempt=$a} $cancelPath $attempt
        $cancelled=Invoke-FixtureComparison $cancelPath;$rec=Recommend $cancelled
        $expected=if($mode -eq 'Cancel'){'ProbeCancelled'}else{'ProbeCleanupFailed'}
        Check ($cancelled.Code -eq $expected -and (& $cmp {$script:Calls}) -eq 1 -and $cancelled.Comparison.CancellationRequested -and -not $rec.RecommendedProfileId -and $cancelled.Results[0].Result.CancellationRequested) ($mode+' stops at a boundary and preserves cleanup-error precedence')
        [IO.File]::Delete($cancelPath)
    }
    Reset-Fixture;$unsafe=Invoke-FixtureComparison (Join-Path $work ('probe-cancel-'+$attempt+'.json'))
    Check ($unsafe.Code -eq 'CancellationPathInvalid' -and (& $cmp {$script:Calls}) -eq 0) 'comparison reuses the original bounded no-reparse cancellation contract'
    $lockPath=Join-Path (Join-Path $work 'probes') '.comparison.lock';$held=[IO.File]::Open($lockPath,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try{Reset-Fixture;$busy=Invoke-FixtureComparison;Check ($busy.Code -eq 'ProbeIdentityUnknown' -and (& $cmp {$script:Calls}) -eq 0) 'another comparison cannot interleave an alternating sequence'}finally{$held.Dispose()}
    Reset-Fixture;$limited=Invoke-FixtureComparison -TimeoutSeconds 5
    Check ($limited.Code -eq 'ComparisonTimeBudgetExhausted' -and (& $cmp {$script:Calls}) -eq 0 -and $limited.Comparison.RequestsAttempted -eq 0) 'total time admission budget is bounded independently of request count'
    [pscustomobject]@{Passed=$true;Checks=$script:Checks;NetworkRequests=0;RealEngineRuns=0;SystemNetworkChanges=0;PairedRounds=3;RequiredPairsPerTarget=9;ComparisonMaxRequests=42;SingleProbeMaxRequests=7;Concurrency=1;PolicyVersion='PairedHttpsEngineering.v1';DigestTamperCases=15;PowerShell=$PSVersionTable.PSVersion.ToString()}|ConvertTo-Json
}finally{
    $full=[IO.Path]::GetFullPath($work);$parent=[IO.Path]::GetFullPath([Environment]::GetFolderPath('LocalApplicationData')).TrimEnd('\')+'\'
    if(-not $full.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notmatch '^TC-ProtocolComparison-[0-9a-f]{32}$'){throw 'Fixture cleanup rejected'}
    Remove-Item -LiteralPath $full -Recurse -Force
}
