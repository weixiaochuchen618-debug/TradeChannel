#requires -Version 5.1
[CmdletBinding()]param([string]$ReportPath,[string]$CasePattern='.',[string]$PackageRoot)
$ErrorActionPreference='Stop'
$env:PSModulePath=Join-Path $PSHOME 'Modules'
$package=if($PackageRoot){[IO.Path]::GetFullPath($PackageRoot)}else{Split-Path $PSScriptRoot -Parent}
$workspace=Split-Path (Split-Path $package -Parent) -Parent
if(-not $ReportPath){$ReportPath=Join-Path ([IO.Path]::GetTempPath()) ('TC-connection-tests-'+[guid]::NewGuid().ToString('N')+'.json')}
$reportRoot=Split-Path ([IO.Path]::GetFullPath($ReportPath)) -Parent
$null=[IO.Directory]::CreateDirectory($reportRoot)
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('.connection-fixture-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($fixture)
$module=Import-Module (Join-Path $package 'ConnectionTransactions.psm1') -Force -PassThru -DisableNameChecking
$bridge=Import-Module (Join-Path $package 'RuntimeBridge.psm1') -Force -PassThru -DisableNameChecking
$result=$null;$failure=$null
try{
    # Refuse accidental production fall-through. Every runtime function executes
    # under one temporary, private simulated adapter; never a Worker callback.
    & $bridge {
        $script:ActualProcessTouches=0
        function script:Get-Process {$script:ActualProcessTouches++;throw 'Real Get-Process forbidden'}
        function script:Get-CimInstance {$script:ActualProcessTouches++;throw 'Real process inventory forbidden'}
        function script:Get-NetAdapter {[pscustomobject]@{InterfaceGuid='fixture-only';Name='Fixture';Status='Up'}}
        function script:Start-Process {$script:ActualProcessTouches++;throw 'Real Start-Process forbidden'}
        function script:Stop-Process {$script:ActualProcessTouches++;throw 'Real Stop-Process forbidden'}
        function script:Invoke-TCCommand {$script:ActualProcessTouches++;throw 'Real channel command forbidden'}
        function script:Invoke-TCController {$script:ActualProcessTouches++;throw 'Real controller forbidden'}
        function script:Test-TCActiveConnection {$script:ActualProcessTouches++;throw 'Real network diagnostic forbidden'}
    }
    $result=& $module {
        param($FixtureRoot,$Bridge,$CasePattern,$TestPackageRoot)
        $script:CasePattern=$CasePattern
        $script:TestPackageRoot=$TestPackageRoot
        $script:Cases=New-Object 'Collections.Generic.List[object]';$script:Checks=0;$script:ActualProcessTouches=0
        $script:CaseNumber=0;$script:AllOps=New-Object 'Collections.Generic.List[string]'
        function script:Get-Process {$script:ActualProcessTouches++;throw 'Actual process access forbidden'}
        function script:Get-CimInstance {$script:ActualProcessTouches++;throw 'Actual process inventory forbidden'}
        function script:Start-Process {$script:ActualProcessTouches++;throw 'Actual process start forbidden'}
        function script:Stop-Process {$script:ActualProcessTouches++;throw 'Actual process stop forbidden'}
        function script:Invoke-WebRequest {$script:ActualProcessTouches++;throw 'Actual network forbidden'}
        function script:Invoke-RestMethod {$script:ActualProcessTouches++;throw 'Actual network forbidden'}
        function script:Check {param([bool]$Condition,[string]$Message) $script:Checks++;if(-not $Condition){throw $Message}}
        function script:NewFixture {param([bool]$Running=$true)
            $script:MonotonicClock=$null;$script:PreferenceClock=$null;$script:FixtureTicks=[int64][Diagnostics.Stopwatch]::Frequency
            $script:SnapshotOverride=$null;$script:CaseNumber++;$script:Fixture=Join-Path $FixtureRoot ('case-'+$script:CaseNumber);$null=[IO.Directory]::CreateDirectory($script:Fixture)
            $script:LineId='11111111-1111-1111-1111-111111111111';$script:Alias='22222222-2222-2222-2222-222222222222'
            $script:Provider='33333333-3333-3333-3333-333333333333'
            $lineRoot=Join-Path $script:Fixture ('Product\lines\'+$script:LineId);$null=[IO.Directory]::CreateDirectory($lineRoot)
            $script:Engine=Join-Path $script:Fixture 'sing-box.exe';[IO.File]::WriteAllText($script:Engine,'inert fixture engine, never executable')
            $script:Old=Join-Path $script:Fixture 'old.manifest.json';$script:Udp=Join-Path $lineRoot 'udp.manifest.json';$script:Tcp=Join-Path $lineRoot 'tcp.manifest.json'
            foreach($entry in @(@($script:Old,'old'),@($script:Udp,'udp'),@($script:Tcp,'tcp'))){
                $config=Join-Path $script:Fixture ($entry[1]+'.config.json')
                $wg=@{type='wireguard';tag='hk';peers=@(@{public_key='fixture-server';address='192.0.2.20';port=51820})}
                $outbounds=@(@{tag='trade-exit';type='selector';outbounds=@('hk','provider-trade')},@{tag='daily-exit';type='selector';outbounds=@('direct','provider')})
                if($entry[1] -eq 'tcp'){$wg.detour='tc-transport';$outbounds+=@{tag='tc-transport';type='vless';server='192.0.2.20';tls=@{enabled=$true;reality=@{enabled=$true}}}}
                CTWrite $config @{inbounds=@(@{type='mixed';tag='egress-probe';listen='127.0.0.1';listen_port=17890;users=@(@{username='tradechannel-probe';password='fixture-only'},@{username='tradechannel-daily';password='fixture-only'})});route=@{fixture=$entry[1];rules=@(@{inbound=@('egress-probe');auth_user=@('tradechannel-daily');action='route';outbound='daily-exit'},@{inbound=@('egress-probe');action='route';outbound='trade-exit'},@{rule_set=@('tc-agents');action='route';outbound='trade-exit'})};endpoints=@($wg);outbounds=$outbounds}
                CTWrite $entry[0] @{SyntaxValidated=$true;DeploymentApproved=($entry[1] -eq 'old');CandidatePath=$config;CandidateSHA256=(CTHash $config);ServerPublicKey='fixture-server';ClientPublicKey='fixture-device';ClientAddress='10.78.0.4';EnginePath=$script:Engine;EngineSHA256=(CTHash $script:Engine);ProbeSHA256=(CTHash $config);NetworkPolicy=@{SchemaVersion=1;Kind='PhysicalInterface';InterfaceId='fixture-only';InterfaceName='Fixture';AddressPolicy='CurrentIPv4'};ServerEndpoint='192.0.2.20:51820';Providers=@(@{Id=$script:Provider;Tag='provider';TradeTag='provider-trade';Kind='custom';Name='fixture';Port=12080;TradePort=12081})}
            }
            CTWrite (Join-Path $script:Fixture 'Product\index.json') @{schemaVersion=1;nodes=@(@{id=$script:LineId;name='source';manifestPath=$script:Udp},@{id=$script:Alias;name='active alias';manifestPath=$script:Old});tradeDomains=@('example.invalid')}
            CTWrite (Join-Path $script:Fixture 'deployment.json') @{ManifestPath=$script:Old;Stage='Legacy';Extra='preserve exactly'}
            CTWrite (Join-Path $script:Fixture 'ui-preferences.json') @{Mode='Global';Exit='Provider';Daily='Provider';Agents='Trade';AgentIds=@('chatgpt','claude');AgentCustom=@(@{Kind='Site';Value='example.invalid'});NodeId=$script:Alias;ProviderId=$script:Provider;TradeProviderId=$script:Provider;ProfileId='Udp';Extra='keep all raw fields'}
            $script:Profiles=@([pscustomobject]@{Id='Udp';ManifestPath=$script:Udp;CandidateSHA256=(CTRead $script:Udp).CandidateSHA256;ManifestSHA256=(CTHash $script:Udp);ProbeSHA256=(CTRead $script:Udp).ProbeSHA256;Revision=1;PreparationState='SyntaxValidated';Validation=$null},[pscustomobject]@{Id='Tcp';ManifestPath=$script:Tcp;CandidateSHA256=(CTRead $script:Tcp).CandidateSHA256;ManifestSHA256=(CTHash $script:Tcp);ProbeSHA256=(CTRead $script:Tcp).ProbeSHA256;Revision=1;PreparationState='SyntaxValidated';Validation=$null})
            $script:Line=[pscustomobject]@{LineId=$script:LineId;Name='fixture';SourceNodeId=$script:LineId;AliasIds=@($script:Alias);Revision=2;Profiles=$script:Profiles;PreferredProfileId='Udp';SavedConnectionPreference=$null}
            $script:Observed=[pscustomobject]@{State=$(if($Running){'Running'}else{'Stopped'});OwnershipKnown=$true;ManifestPath=$script:Old;CandidateSHA256=(CTRead $script:Old).CandidateSHA256;SessionId='original-session';SupervisorPid=901;SupervisorStartedAt='2026-01-01T00:00:00Z';EnginePid=902;EngineStartedAt='2026-01-01T00:00:01Z';Mode='global';Exit='provider-trade';Daily='provider';Agents='Trade';DailySupported=$true;AgentsSupported=$true;Guard=@{GuardState='Protected'}}
            $script:Ops=New-Object 'Collections.Generic.List[string]';$script:Fault='';$script:Ninja=$false;$script:Unknown=$false;$script:Active=0;$script:MaximumActive=if($Running){1}else{0};$script:Starts=0
            if($Running){$script:Active=1}
            $script:Prior=@{Deployment=[IO.File]::ReadAllBytes((Join-Path $script:Fixture 'deployment.json'));Index=[IO.File]::ReadAllBytes((Join-Path $script:Fixture 'Product\index.json'));Prefs=[IO.File]::ReadAllBytes((Join-Path $script:Fixture 'ui-preferences.json'));OldHash=(CTHash $script:Old);TcpHash=(CTHash $script:Tcp)}
            return $script:Fixture
        }
        function script:AssertRestored {
            foreach($pair in @(@('Deployment','deployment.json'),@('Index','Product\index.json'),@('Prefs','ui-preferences.json'))){Check ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $script:Fixture $pair[1]))) -ceq [Convert]::ToBase64String($script:Prior[$pair[0]])) ('Exact byte restore failed: '+$pair[0])}
            Check ((CTHash $script:Old) -ceq $script:Prior.OldHash) 'Original manifest changed'
            Check ((CTHash $script:Tcp) -ceq $script:Prior.TcpHash) 'Immutable target profile changed'
        }
        $script:TestAdapter={param($Operation,$Root,$Payload)
            if($Root -cne $script:Fixture){throw 'Adapter rejected root outside current disposable fixture'}
            $script:Ops.Add($Operation);$script:AllOps.Add($Operation)
            switch($Operation){
                'ReadBoundary'{return}
                'Preflight'{if($script:Ninja){throw 'NinjaTrader must exit'};if($script:Fault -in @('NinjaBeforeStop','BudgetBeforeStop')){$journal=@(Get-ChildItem (Join-Path $Root 'connection-transactions') -Filter '*.json' -ErrorAction SilentlyContinue);if($journal.Count -and (CTRead $journal[0].FullName).Phase -eq 'StopOriginal'){if($script:Fault -eq 'BudgetBeforeStop'){$script:FixtureTicks+=121*[Diagnostics.Stopwatch]::Frequency}else{throw 'NinjaTrader opened during switch'}}};return}
                'Line'{[pscustomobject]@{Line=$script:Line;Profile=@($script:Profiles|Where-Object Id -eq $Payload.ProfileId)[0]};return}
                'NetworkContext'{if($script:SnapshotOverride){return $script:SnapshotOverride};return $script:Network}
                'DefaultProfile'{
                    $r=CTField $script:Line Recommendation;$saved=CTField $script:Line SavedConnectionPreference
                    if($Payload.SelectionMode -eq 'SavedDefault'){
                        return [pscustomobject]@{ProfileId=(CTField $saved ProfileId);Source=(CTField $saved Source 'None');RequiresCheck=(-not $saved);Recommendation=$r;Registered=$true;SelectionMode='SavedDefault'}
                    }
                    return [pscustomobject]@{ProfileId=(CTField $r RecommendedProfileId);Source=(CTField $r Source 'None');RequiresCheck=($null -eq $r -or $r.Status -ne 'Recommended');Reason='请重新检查线路';Recommendation=$r;Registered=$true;RecommendationCurrent=$true;SelectionMode='CurrentRecommendation'}
                }
                'Observe'{return ($script:Observed|ConvertTo-Json -Depth 12|ConvertFrom-Json)}
                'Preferences'{return CTRead (Join-Path $Root 'ui-preferences.json')}
                'ValidateIntent'{if($script:Fault -eq 'IntentInvalid'){throw 'Target lacks original intent'};return & $Bridge {param($DataRoot,$Data)$script:Root=$DataRoot;Assert-TCConnectionIntent $Data.Manifest $Data.Intent $Data.ProfileId $Data.LineId} $Root $Payload}
                {$_ -in @('StopOriginal','StopOwnedCandidate')}{
                    Check ((CTRead (Get-ChildItem (Join-Path $Root 'connection-transactions') -Filter '*.json'|Select-Object -First 1).FullName).Phase -eq $Operation) 'Stop intent was not journaled before operation'
                    if(($Operation -eq 'StopOriginal' -and $script:Fault -in @('StopOriginal','StopNoEffect')) -or ($Operation -eq 'StopOwnedCandidate' -and $script:Fault -eq 'StopCandidate')){if($script:Fault -eq 'StopNoEffect'){return};throw 'Injected stop failure'}
                    $script:Observed.State='Stopped';$script:Active=0
                    if($Operation -eq 'StopOriginal' -and $script:Fault -eq 'BudgetAfterStop'){$script:FixtureTicks+=121*[Diagnostics.Stopwatch]::Frequency}
                    if($Operation -eq 'StopOriginal' -and $script:Fault -eq 'NetworkAfterStop'){$script:Network.Fingerprint=('B'*64)}
                    return
                }
                'Start'{
                    Check ($script:Active -eq 0) 'A second engine was started'
                    $tx=CTRead (Get-ChildItem (Join-Path $Root 'connection-transactions') -Filter '*.json'|Select-Object -First 1).FullName
                    Check ($tx.Phase -in @('StartTarget','RestartOriginal')) 'Start intent was not journaled before operation'
                    if($Payload.Restoring -and $script:Fault -eq 'RestartOriginal'){throw 'Injected original restart failure'}
                    $script:Starts++;$script:Active=1;$script:MaximumActive=[math]::Max($script:MaximumActive,$script:Active)
                    $script:Observed.State='Running';$script:Observed.ManifestPath=$Payload.ManifestPath;$script:Observed.CandidateSHA256=(CTRead $Payload.ManifestPath).CandidateSHA256
                    $script:Observed.SessionId='simulated-'+$script:Starts;$script:Observed.SupervisorPid=1000+$script:Starts;$script:Observed.EnginePid=2000+$script:Starts
                    $script:Observed.SupervisorStartedAt=[DateTimeOffset]::UtcNow.ToString('o');$script:Observed.EngineStartedAt=[DateTimeOffset]::UtcNow.ToString('o')
                    if($Payload.Restoring -and $script:Fault -eq 'BudgetRecovery'){$script:FixtureTicks+=91*[Diagnostics.Stopwatch]::Frequency}
                    if($script:Fault -eq 'StartThrowsAfterLaunch' -and -not $Payload.Restoring){throw 'Launch returned failure after creating owned process'}
                    if($script:Fault -eq 'StartUnknown' -and -not $Payload.Restoring){$script:Observed.OwnershipKnown=$false;throw 'Unknown launched process'}
                    return
                }
                'ApplyIntent'{
                    $prefs=$Payload.Intent;Check ($prefs.AgentIds.Count -eq 2 -and $prefs.AgentCustom.Count -eq 1 -and $prefs.Agents -eq 'Trade' -and $prefs.Daily -eq 'Provider') 'Incomplete AI/daily intent'
                    if($script:Fault -eq 'ApplyIntent' -and -not $Payload.Expected){throw 'Injected selector failure'}
                    $script:Observed.Mode='global';$script:Observed.Exit=if($Payload.Expected){$Payload.Expected.Exit}elseif($prefs.Exit -eq 'HongKong'){'hk'}else{'provider-trade'};$script:Observed.Daily='provider';return
                }
                'Verify'{
                    Check ($Payload.TimeoutSeconds -gt 0 -and $Payload.TimeoutSeconds -le 45) 'Verify did not receive the remaining bounded check budget'
                    if(-not $Payload.Original -and $script:Fault -in @('BudgetVerify','BudgetRecovery')){$script:FixtureTicks+=46*[Diagnostics.Stopwatch]::Frequency}
                    if(-not $Payload.Original -and $script:Fault -eq 'SecretFailure'){throw '[TC:DiagnosticConfigReadFailed] {"password":"SECRET_LEAKED_FROM_EXCEPTION"}'}
                    $wanted=if($Payload.Original){'provider-trade'}elseif($Payload.ProfileId){'hk'}else{'provider-trade'}
                    Check ($script:Observed.Mode -eq 'global' -and $script:Observed.Exit -eq $wanted) 'Wrong actual exit: profile must use hk; rollback must use original provider'
                    if(-not $Payload.Original -and $script:Fault -in @('TargetVerify','StopCandidate','RestartOriginal','OriginalVerify','TargetUnknown','VerifyIdentityChanged')){
                        if($script:Fault -eq 'TargetUnknown'){$script:Observed.OwnershipKnown=$false}
                        if($script:Fault -eq 'VerifyIdentityChanged'){$script:Observed.SessionId='foreign-session'}
                        throw 'Injected target exit failure'
                    }
                    if($Payload.Original -and $script:Fault -eq 'OriginalVerify'){throw 'Injected original exit failure'}
                    if($script:Fault -eq 'ProviderTrace' -and -not $Payload.Original){$script:Observed.Exit='provider-trade';return [pscustomobject]@{ExitHttp=$true;ObservedIP='192.0.2.40';DnsHttps=$true;ExitVerified=$true;ActualExit='provider-trade';ProfileValidated=$false}}
                    if($script:Fault -eq 'DnsFail' -and -not $Payload.Original){return [pscustomobject]@{ExitHttp=$true;ObservedIP='192.0.2.40';DnsHttps=$false;ExitVerified=$false}}
                    [pscustomobject]@{ExitHttp=$true;ObservedIP='192.0.2.40';DnsHttps=$true;ExitVerified=$true;ActualExit=$script:Observed.Exit;ProfileValidated=[bool]($Payload.ProfileId -and $script:Observed.Exit -eq 'hk');ExitSource='ConfiguredEndpoint';ServerAttributionVerified=$false};return
                }
                default{throw ('Unexpected adapter operation '+$Operation)}
            }
        }
        function script:Case {param([string]$Name,[scriptblock]$Body)
            if($Name -notmatch $script:CasePattern){return}
            $before=$script:Checks
            try{& $Body;$script:Cases.Add([pscustomobject]@{Name=$Name;Passed=$true;Checks=($script:Checks-$before)})}
            catch{$script:Cases.Add([pscustomobject]@{Name=$Name;Passed=$false;Error=$_.Exception.Message});throw}
        }
        function script:Preview {Get-TCConnectionSwitchPreview -Root $script:Fixture -LineId $script:Alias -ProfileId Tcp}
        function script:Commit {param($Preview) Invoke-TCConnectionSwitch -Root $script:Fixture -LineId $script:Alias -ProfileId Tcp -PreviewToken $Preview.PreviewToken}
        Case 'Preview is read-only, canonical and Worker-compatible' {
            $null=NewFixture;$p=Preview;Check ($p.CanSwitch -and $p.LineId -eq $script:LineId -and $p.ProfileId -eq 'Tcp' -and $p.PreviewToken -and $p.Message) 'Preview contract missing'
            Check ($p.TargetExit -eq 'HongKong' -and $p.ExitEvidence.Source -eq 'ConfiguredEndpoint' -and $p.Message -match 'HongKong/hk') 'Profile preview did not declare self-hosted exit and evidence source'
            AssertRestored;Check (-not [IO.Directory]::Exists((Join-Path $script:Fixture 'connection-transactions'))) 'Preview persisted runtime work'
            Check (@($script:Ops|Where-Object {$_ -in @('Start','StopOriginal','StopOwnedCandidate','ApplyIntent','Verify')}).Count -eq 0) 'Preview touched actor'
        }
        Case 'Independent Ninja gate on Preview and Commit' {
            $null=NewFixture;$p=Preview;$script:Ninja=$true;$blocked=Preview;Check (-not $blocked.CanSwitch -and -not $blocked.PreviewToken) 'Preview failed to block trading app'
            $caught=$false;try{$null=Commit $p}catch{$caught=$true};Check $caught 'Commit failed to independently block trading app';AssertRestored
        }
        Case 'Successful switch preserves profiles and active alias' {
            $null=NewFixture;$r=Commit (Preview);Check ($r.Status -eq 'Completed' -and $r.Activated -and $r.Observed.State -eq 'Running') 'Switch did not complete'
            $index=CTRead (Join-Path $script:Fixture 'Product\index.json');Check ($index.nodes[0].manifestPath -eq $script:Tcp -and $index.nodes[1].manifestPath -eq $script:Old) 'Source/alias contract violated'
            $prefs=CTRead (Join-Path $script:Fixture 'ui-preferences.json');Check ($prefs.ProfileId -eq 'Tcp' -and $prefs.NodeId -eq $script:LineId -and $prefs.AgentIds.Count -eq 2 -and $prefs.ProviderId -eq $script:Provider) 'Complete preferences lost'
            Check ($prefs.Exit -eq 'HongKong' -and $r.Check.ActualExit -eq 'hk' -and $r.Check.ProfileValidated -and $r.Message -match 'ConfiguredEndpoint') 'TCP switch validated provider trace or claimed authoritative attribution'
            Check ((CTHash $script:Tcp) -ceq $script:Prior.TcpHash) 'Profile manifest mutated'
            $tx=CTRead $r.JournalPath;Check ($tx.Original.References.Count -eq 2 -and $tx.Original.WasRunning -and $tx.Original.Manifest.Bytes -and $tx.Original.Manifest.SHA256 -and $tx.TargetHash -and $tx.Approval.Summary) 'Durable snapshot incomplete'
            Check ($tx.Original.Preferences.Exit -eq 'Provider' -and $tx.Original.Observed.Exit -eq 'provider-trade' -and $tx.Intent.Exit -eq 'HongKong') 'Original provider snapshot overwritten by target profile intent'
            Check ($script:MaximumActive -eq 1) 'Concurrent engines detected'
        }
        Case 'Stopped original can switch without StopOriginal' {
            $null=NewFixture $false;$r=Commit (Preview);Check ($r.Status -eq 'Completed' -and $script:Ops -notcontains 'StopOriginal' -and $script:Starts -eq 1) 'Inactive activation incorrect'
        }
        Case 'Explicit Provider intent cannot override Udp profile self-hosted target' {
            $null=NewFixture;$r=Invoke-CTSessionSwitch -Root $script:Fixture -LineId $script:Alias -ProfileId Udp -Intent ([pscustomobject]@{Exit='Provider'})
            $tx=CTRead $r.JournalPath;Check ($r.Status -eq 'Completed' -and $tx.Intent.Exit -eq 'HongKong' -and $tx.Original.Preferences.Exit -eq 'Provider' -and $r.Check.ActualExit -eq 'hk') 'UDP profile accepted provider target'
        }
        Case 'Manifest-only transaction retains legacy Provider target' {
            $null=NewFixture;$r=Invoke-CTSessionSwitch -Root $script:Fixture -ManifestPath $script:Tcp -Intent ([pscustomobject]@{Exit='Provider'})
            Check ($r.Status -eq 'Completed' -and (CTRead $r.JournalPath).Intent.Exit -eq 'Provider' -and $r.Check.ActualExit -eq 'provider-trade' -and -not $r.Check.ProfileValidated) 'Legacy manifest-only Provider semantics changed'
        }
        Case 'Changed registry exit evidence invalidates confirmed preview' {
            $null=NewFixture;$dir=Join-Path $script:Fixture 'servers';$null=[IO.Directory]::CreateDirectory($dir);$registryPath=Join-Path $dir 'registry.json'
            $registry=@{SchemaVersion=1;Revision=1;Servers=@(@{LocalRecordId='fixture-server';LinkedNodeIds=@($script:LineId);ServerPublicKey='fixture-server';ExpectedExitSource='ServerVerifiedTlsTrace';ExpectedExitIPv4='192.0.2.40'})}
            CTWrite $registryPath $registry;$p=Preview;Check ($p.CanSwitch -and $p.ExitEvidence.Authoritative -and $p.ExitEvidence.Source -eq 'ServerVerifiedTlsTrace') ('Preview omitted bound registry evidence: '+($p|ConvertTo-Json -Depth 12 -Compress))
            $registry.Servers[0].ExpectedExitIPv4='192.0.2.41';CTWrite $registryPath $registry
            $caught=$false;try{$null=Commit $p}catch{$caught=$true};Check ($caught -and $script:Starts -eq 0 -and $script:Ops -notcontains 'StopOriginal') 'Commit reused changed authoritative exit evidence'
        }
        foreach($mutation in @('TargetHash','PreferenceHash','LineRevision','OriginalIdentity','OriginalManifest')){
            Case ('Stale preview rejected: '+$mutation) {
                $null=NewFixture;$p=Preview
                switch($mutation){'TargetHash'{CTWrite (CTRead $script:Tcp).CandidatePath @{changed=$true}}'PreferenceHash'{CTWrite (Join-Path $script:Fixture 'ui-preferences.json') @{Mode='Trading'}}'LineRevision'{$script:Line.Revision++}'OriginalIdentity'{$script:Observed.SessionId='reused-session'}'OriginalManifest'{CTWrite $script:Old @{drift=$true}}}
                $caught=$false;try{$null=Commit $p}catch{$caught=$true};Check $caught 'Stale preview accepted'
                Check ($script:Ops -notcontains 'Start' -and $script:Ops -notcontains 'StopOriginal') 'Stale preview mutated runtime'
            }
        }
        foreach($fault in @('StopOriginal','StopNoEffect')){
            Case ('Original stop failure prohibits another engine: '+$fault) {
                $null=NewFixture;$script:Fault=$fault;$r=Commit (Preview)
                Check ($r.Status -eq 'NeedsRecovery' -and -not $r.ConnectionRestored -and $script:Starts -eq 0) 'Stop failure started recovery';AssertRestored
            }
        }
        Case 'Trading app opened before stop aborts without blocking later connections' {
            $null=NewFixture;$script:Fault='NinjaBeforeStop';$r=Commit (Preview)
            Check ($r.Status -eq 'Aborted' -and -not $r.Activated -and $r.Failure.Code -eq 'TradingAppRunning' -and $r.Message -notmatch '未能完全停止') 'Pre-stop trading-app check was not closed as an unstarted switch'
            Check ($script:Ops -notcontains 'StopOriginal' -and $script:Starts -eq 0 -and $script:Observed.State -eq 'Running' -and (CTRead $r.JournalPath).Status -eq 'Aborted') 'Aborted switch touched the original session';AssertRestored
            $script:Fault='';$p=Preview;Check ($p.CanSwitch -and $p.PreviewToken) 'Aborted switch still blocked the next connection'
        }
        foreach($fault in @('TargetVerify','ApplyIntent','DnsFail','StartThrowsAfterLaunch','ProviderTrace')){
            Case ('Full running rollback: '+$fault) {
                $null=NewFixture;$script:Fault=$fault;$r=Commit (Preview)
                Check ($r.Status -eq 'RolledBack' -and $r.ConfigurationRestored -and $r.ConnectionRestored -and $r.RecoveryCheck.ExitVerified) 'Complete original connection recovery missing'
                Check ($r.RecoveryCheck.ActualExit -eq 'provider-trade' -and $r.Observed.Exit -eq 'provider-trade') 'Rollback did not restore and retest original Provider exit'
                Check ($script:Ops -contains 'StopOwnedCandidate' -and $script:Starts -eq 2 -and $script:MaximumActive -eq 1) 'Wrong rollback ordering';AssertRestored
            }
        }
        Case 'Inactive rollback remains disconnected' {
            $null=NewFixture $false;$script:Fault='TargetVerify';$r=Commit (Preview)
            Check ($r.Status -eq 'RolledBack' -and $r.Observed.State -eq 'Stopped' -and $script:Starts -eq 1 -and -not $r.RecoveryCheck) 'Inactive recovery reconnected';AssertRestored
        }
        Case 'Configuration parser failure is blocked before stopping the old line' {
            $null=NewFixture;$manifest=CTRead $script:Tcp
            [IO.File]::WriteAllText($manifest.CandidatePath,'{"password":"SECRET_LEAKED_FROM_EXCEPTION", invalid',(New-Object Text.UTF8Encoding($false)))
            $manifest.CandidateSHA256=CTHash $manifest.CandidatePath;CTWrite $script:Tcp $manifest
            $script:Profiles[1].CandidateSHA256=$manifest.CandidateSHA256
            $p=Preview
            Check (-not $p.CanSwitch -and $p.Message -match 'DiagnosticConfigReadFailed' -and $p.Message -notmatch 'SECRET_LEAKED_FROM_EXCEPTION') 'Malformed JSON was not rejected with a redacted preflight error'
            Check ($script:Ops -notcontains 'StopOriginal' -and $script:Starts -eq 0 -and -not [IO.Directory]::Exists((Join-Path $script:Fixture 'connection-transactions'))) 'Invalid config reached an actor or transaction journal'
        }
        Case 'Failed exit diagnostics retain cause and rollback state without secret JSON' {
            $null=NewFixture;$script:Fault='SecretFailure';$r=Commit (Preview);$tx=CTRead $r.JournalPath
            Check ($r.Status -ceq 'RolledBack' -and $r.ConnectionRestored -and $r.Failure.Code -ceq 'DiagnosticConfigReadFailed' -and $r.Failure.Phase -ceq 'VerifyTarget') 'Diagnostic cause or rollback result lost'
            Check ($r.Message -match '出口检查无法读取' -and $r.Message -match '已恢复原配置' -and (ConvertTo-Json $r -Depth 30) -notmatch 'SECRET_LEAKED_FROM_EXCEPTION' -and (ConvertTo-Json $tx -Depth 40) -notmatch 'SECRET_LEAKED_FROM_EXCEPTION') 'Runtime response or journal persisted raw config exception'
        }
        foreach($fault in @('StopCandidate','TargetUnknown','StartUnknown','VerifyIdentityChanged')){
            Case ('Candidate cleanup or ownership failure: '+$fault) {
                $null=NewFixture;$script:Fault=$fault;$r=Commit (Preview)
                Check ($r.Status -eq 'NeedsRecovery' -and $script:Starts -eq 1 -and -not $r.ConfigurationRestored -and -not $r.ConnectionRestored) 'Unknown candidate caused unsafe restore/restart'
                Check ((CTRead (Join-Path $script:Fixture 'deployment.json')).TransactionId -eq $r.TransactionId) 'Live candidate identity discarded'
                Check ($r.Message -notmatch '已恢复原') 'NeedsRecovery falsely claimed recovery'
            }
        }
        foreach($fault in @('RestartOriginal','OriginalVerify')){
            Case ('Configuration restored does not imply connectivity: '+$fault) {
                $null=NewFixture;$script:Fault=$fault;$r=Commit (Preview)
                Check ($r.Status -eq 'NeedsRecovery' -and $r.ConfigurationRestored -and -not $r.ConnectionRestored) 'Configuration restoration claimed connection success';AssertRestored
            }
        }
        Case 'Unowned original blocks Preview' {
            $null=NewFixture;$script:Observed.OwnershipKnown=$false;$p=Preview;Check (-not $p.CanSwitch -and $p.Status -eq 'NeedsRecovery') 'Unknown original allowed switch'
        }
        foreach($lockName in @('.session.lock','Product\.store.lock',('Product\lines\'+$script:LineId+'\.line.lock'),'.preferences.lock')){
            Case ('Lock contention blocks all actors: '+$lockName) {
                $null=NewFixture;$p=Preview;$held=[IO.File]::Open((Join-Path $script:Fixture $lockName),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
                try{$caught=$false;try{$null=Commit $p}catch{$caught=$true};Check ($caught -and $script:Starts -eq 0 -and $script:Ops -notcontains 'StopOriginal') 'Lock contention reached actor'}finally{$held.Dispose()}
            }
        }
        Case 'SessionLockHeld never recursively opens session lock' {
            $null=NewFixture;$held=[IO.File]::Open((Join-Path $script:Fixture '.session.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
            try{$r=Invoke-CTSessionSwitch -Root $script:Fixture -LineId $script:Alias -ProfileId Tcp -SessionLockHeld $true;Check ($r.Status -eq 'Completed') 'Session lock recursively acquired'}finally{$held.Dispose()}
        }
        Case 'Interrupt reconciliation observes actual state without replay' {
            $null=NewFixture;$r=Commit (Preview);$tx=CTRead $r.JournalPath;$tx.Status='InProgress';$tx.Phase='StartTarget';CTWrite $r.JournalPath $tx
            $script:Ops.Clear();$before=CTHash (Join-Path $script:Fixture 'deployment.json');$out=@(Reconcile-TCConnectionTransactions -Root $script:Fixture)
            Check ($out.Count -eq 1 -and $out[0].Status -eq 'NeedsRecovery' -and $out[0].Observed.State -eq 'Running') 'Interrupted state not observed'
            Check ($script:Ops -notcontains 'Start' -and $script:Ops -notcontains 'StopOwnedCandidate' -and $script:Ops -notcontains 'ApplyIntent' -and $script:Ops -notcontains 'Verify') 'Reconcile replayed actor'
            Check ((CTHash (Join-Path $script:Fixture 'deployment.json')) -ceq $before) 'Reconcile rewrote active deployment'
            $p=Preview;Check (-not $p.CanSwitch -and $p.Status -eq 'NeedsRecovery') 'Pending transaction allowed another engine'
        }
        Case 'Recorded engine drift blocks before stopping the current session' {
            $null=NewFixture
            $engine=Join-Path $script:Fixture 'engine.fixture';[IO.File]::WriteAllText($engine,'fixture-engine')
            $m=CTRead $script:Tcp;$m|Add-Member NoteProperty EnginePath $engine -Force;$m|Add-Member NoteProperty EngineSHA256 (CTHash $engine) -Force;CTWrite $script:Tcp $m
            $p=Preview;Check $p.CanSwitch 'Matching engine hash should allow a preview'
            [IO.File]::AppendAllText($engine,'-changed');$script:Ops.Clear()
            $caught=$false;try{$null=Commit $p}catch{$caught=$true}
            Check ($caught -and $script:Ops -notcontains 'StopOriginal' -and $script:Ops -notcontains 'Start') 'Changed runtime engine was accepted after recommendation'
        }
        Case 'Public API accepts no executable adapter or lock bypass' {
            $null=NewFixture;$script:Fault='OriginalVerify';$r=Commit (Preview)
            $script:Observed.State='Stopped';$script:Active=0
            $prefs=CTRead (Join-Path $script:Fixture 'ui-preferences.json');$prefs.Mode='Trading';CTWrite (Join-Path $script:Fixture 'ui-preferences.json') $prefs
            $currentPreferenceHash=CTHash (Join-Path $script:Fixture 'ui-preferences.json');$script:Ops.Clear()
            $out=@(Reconcile-TCConnectionTransactions -Root $script:Fixture -ResolveStopped)
            Check ($out.Count -eq 1 -and $out[0].Status -eq 'ResolvedStopped' -and -not $out[0].Activated -and -not $out[0].ConnectionRestored) 'Stopped resolution claimed connectivity'
            Check ($script:Ops -notcontains 'Start' -and $script:Ops -notcontains 'StopOriginal' -and $script:Ops -notcontains 'StopOwnedCandidate' -and $script:Ops -notcontains 'ApplyIntent' -and $script:Ops -notcontains 'Verify') 'Stopped resolution operated channel'
            Check ((CTHash (Join-Path $script:Fixture 'ui-preferences.json')) -ceq $currentPreferenceHash) 'Stopped user choices overwritten'
            $script:Fault='';Check (Preview).CanSwitch 'Resolved stopped transaction permanently blocked next preview'
            foreach($name in @('Get-TCConnectionSwitchPreview','Invoke-TCConnectionSwitch','Reconcile-TCConnectionTransactions')){
                $command=Get-Command $name;Check (-not $command.Parameters.ContainsKey('Adapter') -and -not $command.Parameters.ContainsKey('Callback') -and -not $command.Parameters.ContainsKey('SessionLockHeld')) 'Public executable injection or lock bypass'
            }
            Check ($script:ActualProcessTouches -eq 0) 'Actual processes were touched'
            $touches=& $Bridge {$script:ActualProcessTouches};Check ($touches -eq 0) 'RuntimeBridge escaped adapter'
        }
        Case 'Recovery refuses a running session and keeps the journal' {
            $null=NewFixture;$script:Fault='OriginalVerify';$r=Commit (Preview);$script:Ops.Clear()
            $out=@(Reconcile-TCConnectionTransactions -Root $script:Fixture -ResolveStopped)
            Check ($out[0].Status -eq 'NeedsRecovery' -and $out[0].Observed.State -eq 'Running') 'Recovery closed a live unverified session'
            Check ($script:Ops -notcontains 'Start' -and $script:Ops -notcontains 'StopOriginal' -and $script:Ops -notcontains 'StopOwnedCandidate' -and $script:Ops -notcontains 'Verify') 'Recovery touched a running session'
        }
        Case 'Recovery refuses restored-reference drift' {
            $null=NewFixture;$script:Fault='OriginalVerify';$r=Commit (Preview);$script:Observed.State='Stopped';$script:Active=0
            CTWrite (Join-Path $script:Fixture 'deployment.json') @{ManifestPath=$script:Tcp};$script:Ops.Clear()
            $out=@(Reconcile-TCConnectionTransactions -Root $script:Fixture -ResolveStopped)
            Check ($out[0].Status -eq 'NeedsRecovery') 'Reference drift was hidden by stopped resolution'
        }
        Case 'Invalid original diagnostic route blocks before disconnection' {
            $null=NewFixture;$manifest=CTRead $script:Old;$cfg=CTRead $manifest.CandidatePath
            $cfg.route.rules=@([pscustomobject]@{inbound=@('egress-probe');action='route';outbound='direct'})+@($cfg.route.rules)
            CTWrite $manifest.CandidatePath $cfg;$manifest.CandidateSHA256=CTHash $manifest.CandidatePath;CTWrite $script:Old $manifest
            $script:Observed.CandidateSHA256=$manifest.CandidateSHA256;$script:Ops.Clear();$p=Preview
            Check (-not $p.CanSwitch -and $script:Ops -notcontains 'StopOriginal' -and $script:Ops -notcontains 'Start') 'Invalid rollback route was found after stopping'
        }
        function script:RecommendTcp {
            Import-Module (Join-Path $script:TestPackageRoot 'ProtocolSelection.psm1') -DisableNameChecking
            $script:Network=[pscustomobject]@{Status='Available';Fingerprint=('A'*64);ObservedAt=[DateTimeOffset]::UtcNow.ToString('o')}
            $protocol=Get-Module ProtocolSelection|Select-Object -First 1
            & $protocol {
                param($Context)
                $script:FixtureBoundContext=$Context
                $script:NetworkContextReader={param($Binding)
                    if($Binding -and $Binding.PSObject.Properties['FixtureFingerprint']){
                        $copy=$script:FixtureBoundContext|ConvertTo-Json|ConvertFrom-Json;$copy.Fingerprint=$Binding.FixtureFingerprint;return $copy
                    }
                    $script:FixtureBoundContext
                }
            } $script:Network
            $raw=[pscustomobject]@{Status='Passed';Code='CandidateReachabilityVerified';CheckedAtUtc=[DateTimeOffset]::UtcNow.ToString('o');CleanupComplete=$true;CandidateHash=$script:Profiles[1].CandidateSHA256;ObservedExitIPv4='192.0.2.40';ExpectedExitIPv4='192.0.2.40';ExpectedExitSource='ServerVerifiedTlsTrace';Checks=@([pscustomobject]@{Name='AddressHttps';Status='Passed'},[pscustomobject]@{Name='DomainDnsHttps';Status='Passed'});PathEvidence=[pscustomobject]@{Verified=$true;EligibleForRecommendation=$true;Kind='BoundInterfaceObserved';NetworkFingerprint=$script:Network.Fingerprint;Binding=[pscustomobject]@{SchemaVersion=2;Scope='BoundPhysicalIPv4.v1';InterfaceId='fixture-only'}}}
            $script:Profiles[1].Validation=ConvertTo-TCProtocolEvidence -Profile $script:Profiles[1] -Result $raw -NetworkContext $script:Network
            $recommendation=Get-TCProtocolRecommendation -Profiles $script:Profiles -NetworkContext $script:Network -LineId $script:LineId
            Check ($recommendation.Status -eq 'Recommended' -and $recommendation.RecommendedProfileId -eq 'Tcp') 'Synthetic protocol evidence did not qualify'
            $script:Line|Add-Member NoteProperty Recommendation $recommendation -Force
            $script:Line|Add-Member NoteProperty PreferenceSource 'Reachability' -Force
            $script:Line.PreferredProfileId='Tcp'
        }
        function script:RecommendComparison {param([string]$Kind,[string]$Winner)
            RecommendTcp
            foreach($profile in $script:Profiles){$profile|Add-Member NoteProperty ManifestSHA256 (CTHash $profile.ManifestPath) -Force}
            $comparison=Import-Module (Join-Path $script:TestPackageRoot 'ProtocolComparison.psm1') -Force -PassThru -DisableNameChecking
            & $comparison {
                param($Profiles,$Network,$Kind,$Winner)
                $script:CTProfiles=$Profiles;$script:CTNetwork=$Network;$script:CTKind=$Kind;$script:CTWinner=$Winner
                function script:Prepare-TCProtocolComparisonBinding {param($Root,$NodeId,$InterfaceIndex)
                    [pscustomobject]@{LineId=$NodeId;State='Ready';Code='BindingsPrepared';Prepared=$false;Results=@($script:CTProfiles|ForEach-Object {[pscustomobject]@{ProfileId=$_.Id;BindingState='Reused';ReasonCode='StoredBindingUnchanged';CandidateSHA256=$_.CandidateSHA256;ManifestSHA256=$_.ManifestSHA256}})}
                }
                function script:Get-TCProtocolComparisonContext {$script:CTNetwork}
                function script:Get-TCProtocolComparisonProfile {param($Root,$NodeId,$ProfileId) @($script:CTProfiles|Where-Object Id -eq $ProfileId)[0]}
                function script:Invoke-TCProtocolComparisonProbe {
                    param($Root,$NodeId,$ProfileId,$ExpectedExitIPv4,$ExpectedExitSource,$CancellationPath,$TimeoutSeconds)
                    $profile=@($script:CTProfiles|Where-Object Id -eq $ProfileId)[0];$samples=@()
                    $failed=($script:CTKind -eq 'Stability' -and $ProfileId -ne $script:CTWinner)
                    $duration=if($script:CTKind -eq 'PolicyDefault'){100}elseif($ProfileId -eq $script:CTWinner){60}else{200}
                    foreach($round in 1..3){foreach($target in @([pscustomobject]@{Name='AddressHttps';Url='https://1.1.1.1/cdn-cgi/trace'},[pscustomobject]@{Name='DomainDnsHttps';Url='https://www.cloudflare.com/cdn-cgi/trace'})){
                        $samples+=,[pscustomobject]@{Name=$target.Name;TargetUrl=$target.Url;Round=$round;Required=$true;Attempted=$true;RequestBudgetSeconds=6;Status=$(if($failed){'Failed'}else{'Passed'});Code=$(if($failed){'ProbeTimeout'}else{'HttpsReached'});HttpStatus=200;TlsVerified=(-not $failed);ObservedExitIPv4=$(if(-not $failed){$ExpectedExitIPv4}else{$null});DurationMs=$duration}
                    }}
                    $samples+=,[pscustomobject]@{Name='ChatGPTWeb';TargetUrl='https://chatgpt.com/';Round=1;Required=$false;Attempted=$true;RequestBudgetSeconds=6;Status='UserVerificationRequired';Code='BrowserChallenge';HttpStatus=403;TlsVerified=$true;DurationMs=20}
                    $path=[pscustomobject]@{Verified=$true;EligibleForRecommendation=(-not $failed);Kind='BoundInterfaceObserved';NetworkFingerprint=$script:CTNetwork.Fingerprint;Binding=[pscustomobject]@{SchemaVersion=2;Scope='BoundPhysicalIPv4.v1';InterfaceId='fixture-only'}}
                    [pscustomobject]@{SchemaVersion=2;Checks=@();RunId=[guid]::NewGuid().ToString('D');DurationMs=10;TransportPath='BoundInterfaceObserved';PathStatus='Passed';UnderlayFingerprint=$script:CTNetwork.Fingerprint;NetworkChanged=$false;ContextChanged=$false;NodeId=$NodeId;ProfileId=$ProfileId;CandidateHash=$profile.CandidateSHA256;ManifestHash=$profile.ManifestSHA256;EngineSHA256=('E'*64);Status=$(if($failed){'Failed'}else{'Passed'});Code=$(if($failed){'CandidateForwardingFailed'}else{'CandidateReachabilityVerified'});ForwardingPassed=(-not $failed);ObservedExitIPv4=$ExpectedExitIPv4;ExpectedExitIPv4=$ExpectedExitIPv4;ExpectedExitSource=$ExpectedExitSource;ExitServerVerifiedTrace=(-not $failed);NetworkFingerprint=$script:CTNetwork.Fingerprint;SnapshotFingerprint=$script:CTNetwork.Fingerprint;PathEvidence=$path;ProbeId=[guid]::NewGuid().ToString('D');CheckedAtUtc=[DateTimeOffset]::UtcNow.ToString('o');CleanupComplete=$true;CancellationRequested=$false;Samples=$samples;Metrics=$null;EvidencePath=$null}
                }
            } $script:Profiles $script:Network $Kind $Winner
            $batch=Invoke-TCProtocolComparison -Root $script:Fixture -NodeId $script:LineId -ExpectedExitIPv4 '192.0.2.40' -ExpectedExitSource ServerVerifiedTlsTrace
            Check ($batch.Status -eq 'Completed' -and $batch.Results.Count -eq 2) 'Real comparison did not finish both protocols'
            foreach($profile in $script:Profiles){$row=@($batch.Results|Where-Object ProfileId -eq $profile.Id)[0];$profile.Validation=ConvertTo-TCProtocolEvidence -Result $row.Result -Profile $profile -NetworkContext $script:Network}
            $rec=Get-TCProtocolRecommendation -Profiles $script:Profiles -NetworkContext $script:Network -LineId $script:LineId
            Check ($rec.Status -eq 'Recommended' -and $rec.Source -eq $Kind -and $rec.RecommendedProfileId -eq $Winner) ('Real producer did not generate expected '+$Kind+' '+$Winner+': '+$rec.Source)
            Check (Test-TCProtocolRecommendationCurrent -Recommendation $rec -Profiles $script:Profiles -NetworkContext $script:Network) 'Producer recommendation is not current'
            $script:Line.Recommendation=$rec;$script:Line.PreferenceSource=$rec.Source;$script:Line.PreferredProfileId=$rec.RecommendedProfileId
        }
        foreach($kind in @('Performance','Stability','PolicyDefault')){foreach($winner in @('Udp','Tcp')){
            if($kind -eq 'PolicyDefault' -and $winner -eq 'Tcp'){continue}
            Case ('Comparison '+$kind+' '+$winner+' default connects through transaction') {
                $null=NewFixture;RecommendComparison $kind $winner
                $p=Get-TCDefaultConnectionSwitchPreview -Root $script:Fixture -LineId $script:Alias -SelectionMode CurrentRecommendation
                Check ($p.CanSwitch -and $p.ProfileId -eq $winner -and $p.DefaultSource -eq $kind -and $p.TargetHash -ceq @($script:Profiles|Where-Object Id -eq $winner)[0].CandidateSHA256) ('Current comparison default was blocked: '+$p.Message)
                Check ($script:Ops -notcontains 'StopOriginal' -and $script:Starts -eq 0) 'Preview changed the original connection'
                $r=Invoke-TCConnectionSwitch -Root $script:Fixture -LineId $script:Alias -ProfileId $winner -PreviewToken $p.PreviewToken
                Check ($r.Status -eq 'Completed' -and $script:MaximumActive -eq 1 -and $r.Check.ProfileValidated) 'Comparison default failed simulated controlled activation'
            }
        }}
        foreach($kind in @('Performance','Stability')){
            foreach($mutation in @('Expired','Network','Config','Cleanup','Source','UnknownSource','MissingRecommendation')){
                Case ('Comparison '+$kind+' rejects '+$mutation+' before stopping') {
                    $null=NewFixture;RecommendComparison $kind 'Udp'
                    $p=Get-TCDefaultConnectionSwitchPreview -Root $script:Fixture -LineId $script:Alias -SelectionMode CurrentRecommendation
                    Check $p.CanSwitch $p.Message
                    switch($mutation){
                        'Expired'{$script:Line.Recommendation.ExpiresAtUtc=[DateTimeOffset]::UtcNow.AddSeconds(-1).ToString('o')}
                        'Network'{$script:Network.Fingerprint=('B'*64)}
                        'Config'{$script:Line.Recommendation.CandidateSHA256=('0'*64)}
                        'Cleanup'{$script:Profiles[0].Validation.CleanupComplete=$false}
                        'Source'{$script:Line.Recommendation.Source='PolicyDefault'}
                        'UnknownSource'{$script:Line.Recommendation.Source='UnsupportedSource'}
                        'MissingRecommendation'{$script:Line.Recommendation=$null}
                    }
                    $recheck=Get-TCDefaultConnectionSwitchPreview -Root $script:Fixture -LineId $script:Alias -SelectionMode CurrentRecommendation
                    $expectedCode=if($mutation -eq 'Cleanup'){'NeedsRecovery'}else{'RecommendationCheckRequired'}
                    Check (-not $recheck.CanSwitch -and -not $recheck.PreviewToken -and $recheck.Code -eq $expectedCode) ('Invalid comparison default obtained a preview token or wrong cause: '+$mutation+' / '+$recheck.Code)
                    $failed=$false;try{$null=Invoke-TCConnectionSwitch -Root $script:Fixture -LineId $script:Alias -ProfileId Udp -PreviewToken $p.PreviewToken}catch{$failed=$true}
                    Check ($failed -and $script:Ops -notcontains 'StopOriginal' -and $script:Starts -eq 0) 'Invalid comparison default stopped the original connection'
                    AssertRestored
                }
            }
            Case ('Comparison '+$kind+' restores original when target validation fails') {
                $null=NewFixture;RecommendComparison $kind 'Tcp'
                $p=Get-TCDefaultConnectionSwitchPreview -Root $script:Fixture -LineId $script:Alias -SelectionMode CurrentRecommendation
                Check $p.CanSwitch $p.Message
                $script:Fault='TargetVerify';$r=Invoke-TCConnectionSwitch -Root $script:Fixture -LineId $script:Alias -ProfileId Tcp -PreviewToken $p.PreviewToken
                Check ($r.Status -eq 'RolledBack' -and $r.ConnectionRestored -and $script:MaximumActive -eq 1) 'Comparison target failure did not restore the original'
                AssertRestored
            }
            Case ('Comparison '+$kind+' restores original on network change after stop') {
                $null=NewFixture;RecommendComparison $kind 'Tcp'
                $p=Get-TCDefaultConnectionSwitchPreview -Root $script:Fixture -LineId $script:Alias -SelectionMode CurrentRecommendation
                Check $p.CanSwitch $p.Message
                $script:Fault='NetworkAfterStop';$r=Invoke-TCConnectionSwitch -Root $script:Fixture -LineId $script:Alias -ProfileId Tcp -PreviewToken $p.PreviewToken
                Check ($r.Status -eq 'RolledBack' -and $r.ConnectionRestored -and $script:Starts -eq 1) 'Comparison network drift launched a target or failed recovery'
                AssertRestored
            }
        }
        Case 'Default TCP preview commits through same transaction with current evidence' {
            $null=NewFixture;RecommendTcp
            $p=Get-TCDefaultConnectionSwitchPreview -Root $script:Fixture -LineId $script:Alias -SelectionMode CurrentRecommendation
            Check ($p.CanSwitch -and $p.ProfileId -eq 'Tcp' -and $p.DefaultSource -eq 'Reachability' -and $p.PreviewToken -clike 'ct3:*' -and $p.TargetHash -ceq $script:Profiles[1].CandidateSHA256) ('Default preview not bound: '+$p.Message)
            $script:Network.ObservedAt=[DateTimeOffset]::UtcNow.ToString('o')
            $r=Commit $p
            Check ($r.Status -eq 'Completed' -and $script:MaximumActive -eq 1) 'Stable context with changed observation time failed'
        }
        Case 'Global TUN snapshot change preserves bound recommendation token' {
            $null=NewFixture;RecommendTcp;$p=Get-TCDefaultConnectionSwitchPreview -Root $script:Fixture -LineId $script:Alias -SelectionMode CurrentRecommendation
            $script:SnapshotOverride=[pscustomobject]@{Status='Available';Fingerprint=('D'*64);Scope='FullNetworkSnapshot.v1'}
            $again=Get-TCDefaultConnectionSwitchPreview -Root $script:Fixture -LineId $script:Alias -SelectionMode CurrentRecommendation
            Check ($again.CanSwitch -and $again.Recommendation.NetworkFingerprint -cne $script:SnapshotOverride.Fingerprint) 'Global snapshot leaked into default digest'
            $r=Commit $p;Check ($r.Status -eq 'Completed') 'Unchanged bound underlay invalidated by global snapshot'
        }
        Case 'Multiple bound fingerprints use recommendation aggregate' {
            $null=NewFixture;RecommendTcp
            $udp=$script:Profiles[1].Validation|ConvertTo-Json -Depth 30|ConvertFrom-Json
            $udp.ProfileId='Udp';$udp.CandidateSHA256=$script:Profiles[0].CandidateSHA256;$udp.NetworkFingerprint=('C'*64);$udp.EvidenceId='fixture-udp-distinct'
            $udp.PathEvidence.Binding|Add-Member NoteProperty FixtureFingerprint ('C'*64)
            $script:Profiles[0].Validation=$udp
            $script:Line.Recommendation=Get-TCProtocolRecommendation -Profiles $script:Profiles -NetworkContext $script:Network -LineId $script:LineId
            $script:Line.PreferredProfileId='Udp';$script:Line.PreferenceSource='PolicyDefault'
            $p=Get-TCDefaultConnectionSwitchPreview -Root $script:Fixture -LineId $script:Alias -SelectionMode CurrentRecommendation
            Check ($p.CanSwitch -and $p.ProfileId -eq 'Udp' -and $p.DefaultSource -eq 'PolicyDefault' -and $p.Recommendation.NetworkFingerprint -cne $script:Network.Fingerprint) 'Multiple underlays could not bind aggregate recommendation'
            $r=Invoke-TCConnectionSwitch -Root $script:Fixture -LineId $script:Alias -ProfileId Udp -PreviewToken $p.PreviewToken
            Check ($r.Status -eq 'Completed') 'Aggregate fingerprint failed controlled commit'
        }
        foreach($mutation in @('Network','UnavailableNetwork','Source','Expired','Evidence','Config','Profile','Status','Future')){
            Case ('Default preview rejects changed '+$mutation+' before stopping') {
                $null=NewFixture;RecommendTcp;$p=Get-TCDefaultConnectionSwitchPreview -Root $script:Fixture -LineId $script:Alias -SelectionMode CurrentRecommendation
                Check $p.CanSwitch $p.Message
                switch($mutation){
                    'Network'{$script:Network.Fingerprint=('B'*64)}
                    'UnavailableNetwork'{$script:Network.Status='Unavailable'}
                    'Source'{$script:Line.Recommendation.Source='PolicyDefault'}
                    'Expired'{$script:Line.Recommendation.ExpiresAtUtc=[DateTimeOffset]::UtcNow.AddSeconds(-1).ToString('o')}
                    'Future'{$script:Line.Recommendation.CheckedAtUtc=[DateTimeOffset]::UtcNow.AddMinutes(5).ToString('o')}
                    'Evidence'{$script:Profiles[1].Validation.CleanupComplete=$false}
                    'Config'{$script:Line.Recommendation.CandidateSHA256=('0'*64)}
                    'Profile'{$script:Line.Recommendation.RecommendedProfileId='Udp'}
                    'Status'{$script:Line.Recommendation.Status='Inconclusive'}
                }
                $failed=$false;try{$null=Commit $p}catch{$failed=$true}
                Check ($failed -and $script:Ops -notcontains 'StopOriginal' -and $script:Starts -eq 0) ('Changed recommendation reached an actor: '+$mutation)
                AssertRestored
            }
        }
        foreach($state in @('Unavailable','Inconclusive','Blocked')){
            Case ('Explicit no recommendation never falls back to UDP: '+$state) {
                $null=NewFixture;RecommendTcp;$script:Line.Recommendation.Status=$state;$script:Line.Recommendation.RecommendedProfileId=$null
                $p=Get-TCDefaultConnectionSwitchPreview -Root $script:Fixture -LineId $script:Alias -SelectionMode CurrentRecommendation
                Check (-not $p.CanSwitch -and -not $p.ProfileId -and -not $p.PreviewToken -and $p.Code -in @('RecommendationCheckRequired','SavedDefaultBlocked')) 'No recommendation silently defaulted to UDP'
            }
        }
        Case 'Recommendation changes after original stop restore original session' {
            $null=NewFixture;RecommendTcp;$p=Get-TCDefaultConnectionSwitchPreview -Root $script:Fixture -LineId $script:Alias -SelectionMode CurrentRecommendation
            $script:Fault='NetworkAfterStop';$r=Commit $p
            Check ($r.Status -eq 'RolledBack' -and $r.ConnectionRestored -and $script:Starts -eq 1 -and $script:MaximumActive -eq 1) 'Mid-commit network change started a target or skipped rollback'
            AssertRestored
        }
        Case 'Manual preference uses PreferredProfileId with null automatic recommendation' {
            $null=NewFixture;RecommendTcp
            $script:Line.Recommendation=Get-TCProtocolRecommendation -Profiles $script:Profiles -RequestedMode Tcp -NetworkContext $script:Network -LineId $script:LineId
            $script:Line.PreferenceSource='UserChoice'
            Check (-not $script:Line.Recommendation.RecommendedProfileId) 'UserChoice fixture incorrectly has automatic profile'
            $script:Line.SavedConnectionPreference=New-TCSavedConnectionPreference -LineId $script:LineId -Profile $script:Profiles[1] -Manifest (CTRead $script:Tcp) -ManualChoice
            $p=Get-TCDefaultConnectionSwitchPreview -Root $script:Fixture -LineId $script:Alias
            Check ($p.CanSwitch -and $p.DefaultSource -eq 'UserChoice' -and $p.ProfileId -eq 'Tcp') 'Explicit preference not consumed'
            $script:Network.Fingerprint=('C'*64);$r=Commit $p;Check ($r.Status -eq 'Completed') 'User choice unexpectedly relied on automatic network recommendation'
        }
        Case 'Archived canonical and alias registry bindings block explicit profile paths' {
            $null=NewFixture
            foreach($linkedId in @($script:LineId,$script:Alias)){
                $null=NewFixture;$dir=Join-Path $script:Fixture 'servers';$null=[IO.Directory]::CreateDirectory($dir)
                CTWrite (Join-Path $dir 'registry.json') @{SchemaVersion=1;Servers=@(@{LocalRecordId='fixture-generation';RecordState='Archived';ServerPublicKey='fixture-server';LinkedNodeIds=@($linkedId);Connection=@{Host='192.0.2.20'}})}
                $p=Preview;Check (-not $p.CanSwitch -and $p.Message -match 'ServerArchived') 'Archived registry binding allowed explicit profile'
                Check ($script:Starts -eq 0 -and $script:Ops -notcontains 'StopOriginal') 'Archived binding reached actor'
            }
        }
        Case 'Old registered line without trustworthy recorded origin fails closed' {
            $null=NewFixture;$p=Get-TCDefaultConnectionSwitchPreview -Root $script:Fixture -LineId $script:Alias
            Check (-not $p.CanSwitch -and -not $p.PreviewToken -and -not $p.ProfileId) 'Unbound configured preference silently became a default'
        }
        Case 'Network completion preserves the saved TCP target before stopping' {
            $null=NewFixture;RecommendTcp
            $m=CTRead $script:Tcp;$m.PSObject.Properties.Remove('NetworkPolicy');CTWrite $script:Tcp $m
            $script:Profiles[1].ManifestSHA256=CTHash $script:Tcp
            $script:Line.SavedConnectionPreference=New-TCSavedConnectionPreference -LineId $script:LineId -Profile $script:Profiles[1] -Manifest $m -ManualChoice
            $p=Get-TCDefaultConnectionSwitchPreview -Root $script:Fixture -LineId $script:Alias
            Check (-not $p.CanSwitch -and $p.Code -eq 'NetworkPolicyUpdateRequired' -and $p.NextAction -eq 'UpdateNetworkBinding' -and $p.ProfileId -eq 'Tcp') 'Network completion lost the original saved TCP target'
            Check ($script:Starts -eq 0 -and $script:Ops -notcontains 'StopOriginal') 'Missing network policy interrupted the original connection'
        }
        Case 'Saved default preview accepts unchanged session intent with optional fields' {
            $null=NewFixture $false
            Import-Module (Join-Path $script:TestPackageRoot 'ProtocolSelection.psm1') -DisableNameChecking
            $prefs=CTRead (Join-Path $script:Fixture 'ui-preferences.json')
            $prefs.NodeId=$script:LineId;$prefs.Exit='HongKong';$prefs.ProfileId=$null
            $prefs|Add-Member NoteProperty OpenAtLogin $false
            $prefs|Add-Member NoteProperty ManualConnect $true
            CTWrite (Join-Path $script:Fixture 'ui-preferences.json') $prefs
            $script:Line.SavedConnectionPreference=New-TCSavedConnectionPreference -LineId $script:LineId -Profile $script:Profiles[0] -Manifest (CTRead $script:Udp) -ManualChoice
            $p=Get-TCDefaultConnectionSwitchPreview -Root $script:Fixture -LineId $script:LineId
            Check ($p.CanSwitch -and $p.ProfileId -eq 'Udp') 'Saved UDP default preview failed'
            $intent=[pscustomobject][ordered]@{Mode=$prefs.Mode;Exit='HongKong';Daily=$prefs.Daily;NodeId=$script:LineId;ProfileId='Udp';ProviderId=$prefs.ProviderId;TradeProviderId=$prefs.TradeProviderId;Agents=$prefs.Agents;AgentIds=@($prefs.AgentIds);AgentCustom=@($prefs.AgentCustom)}
            $r=Invoke-CTSessionSwitch -Root $script:Fixture -LineId $script:LineId -ProfileId Udp -Intent $intent -PreviewToken $p.PreviewToken -DefaultSelection $true
            Check ($r.Status -eq 'Completed' -and $script:Starts -eq 1) 'Equivalent session intent invalidated its confirmed default preview'
            $saved=(CTRead $r.JournalPath).Intent
            Check ($saved.Extra -ceq $prefs.Extra -and $saved.ManualConnect -and -not $saved.OpenAtLogin -and $saved.ProfileId -eq 'Udp') 'Optional preference fields were lost while preserving the approved intent'
        }
        Case 'Saved default preview rejects changed session intent before dispatch' {
            $null=NewFixture $false
            Import-Module (Join-Path $script:TestPackageRoot 'ProtocolSelection.psm1') -DisableNameChecking
            $prefs=CTRead (Join-Path $script:Fixture 'ui-preferences.json');$prefs.NodeId=$script:LineId;$prefs.Exit='HongKong'
            CTWrite (Join-Path $script:Fixture 'ui-preferences.json') $prefs
            $script:Line.SavedConnectionPreference=New-TCSavedConnectionPreference -LineId $script:LineId -Profile $script:Profiles[0] -Manifest (CTRead $script:Udp) -ManualChoice
            $p=Get-TCDefaultConnectionSwitchPreview -Root $script:Fixture -LineId $script:LineId
            Check $p.CanSwitch 'Saved default preview failed'
            $blocked=$false
            try{$null=Invoke-CTSessionSwitch -Root $script:Fixture -LineId $script:LineId -ProfileId Udp -Intent ([pscustomobject]@{Daily='Direct'}) -PreviewToken $p.PreviewToken -DefaultSelection $true}catch{$blocked=$true}
            Check ($blocked -and $script:Starts -eq 0 -and $script:Ops -notcontains 'StopOriginal' -and -not (Test-Path -LiteralPath (Join-Path $script:Fixture 'connection-transactions'))) 'Changed intent bypassed preview approval'
        }
        Case 'Lost result is recovered by durable original request identity without replay' {
            $null=NewFixture;$p=Preview;$requestId=[guid]::NewGuid().ToString('N')
            $r=Invoke-TCConnectionSwitch -Root $script:Fixture -LineId $script:LineId -ProfileId Tcp -PreviewToken $p.PreviewToken -RequestId $requestId
            Check ($r.Status -eq 'Completed' -and $r.RequestId -ceq $requestId -and (CTRead $r.JournalPath).RequestId -ceq $requestId) 'Request identity was not persisted before transaction effects'
            $starts=$script:Starts;$operations=@($script:Ops|Where-Object {$_ -in @('Start','StopOriginal','StopOwnedCandidate','ApplyIntent','Verify')}).Count
            $wrong=@(Reconcile-TCConnectionTransactions -Root $script:Fixture -ResolveStopped -RequestIds @([guid]::NewGuid().ToString('N')))
            Check ($wrong.Count -eq 0) 'An unrelated request reclaimed terminal history'
            $resolved=@(Reconcile-TCConnectionTransactions -Root $script:Fixture -ResolveStopped -RequestIds @($requestId))
            Check ($resolved.Count -eq 1 -and $resolved[0].TransactionId -ceq $r.TransactionId -and $resolved[0].Status -eq 'Completed') 'Original request did not recover its durable completion'
            Check ($script:Starts -eq $starts -and @($script:Ops|Where-Object {$_ -in @('Start','StopOriginal','StopOwnedCandidate','ApplyIntent','Verify')}).Count -eq $operations) 'Result recovery replayed a network operation'
        }
        Case 'Budget before stop aborts with no effects' {
            $null=NewFixture;$p=Preview;$script:MonotonicClock={$script:FixtureTicks};$script:Fault='BudgetBeforeStop';$r=Commit $p
            Check ($r.Status -eq 'Aborted' -and $r.Failure.Code -eq 'ConnectionTimeout' -and $script:Ops -notcontains 'StopOriginal' -and $script:Starts -eq 0) 'Expired pre-stop budget dispatched a mutation'
            AssertRestored
        }
        Case 'Budget after identified stop gets a fresh recovery window' {
            $null=NewFixture;$p=Preview;$script:MonotonicClock={$script:FixtureTicks};$script:Fault='BudgetAfterStop';$r=Commit $p
            Check ($r.Status -eq 'RolledBack' -and $r.ConnectionRestored -and $r.Budget.RecoverySeconds -eq 90 -and $script:Starts -eq 1) 'Main deadline prevented owned original recovery'
            AssertRestored
        }
        Case 'Budget single verification expires and recovers once without deployment comparison' {
            $null=NewFixture;$p=Preview;$script:MonotonicClock={$script:FixtureTicks};$script:Fault='BudgetVerify';$r=Commit $p
            Check ($r.Status -eq 'RolledBack' -and $r.Failure.Code -eq 'ConnectionCheckTimeout' -and $r.ConnectionRestored -and @($script:Ops|Where-Object {$_ -eq 'Verify'}).Count -eq 2 -and $script:MaximumActive -eq 1) 'Check expiry reran comparison, escaped budget or failed recovery'
            AssertRestored
        }
        Case 'Budget recovery exhaustion is unknown and never claims restored connectivity' {
            $null=NewFixture;$p=Preview;$script:MonotonicClock={$script:FixtureTicks};$script:Fault='BudgetRecovery';$r=Commit $p
            Check ($r.Status -eq 'NeedsRecovery' -and -not $r.ConnectionRestored -and $r.ConfigurationRestored -and $r.RecoveryFailure.Code -eq 'RecoveryTimeout') 'Recovery overrun was reported as restored'
        }
        Case 'Budget monotonic elapsed survives UTC jumps and progress stays request bound' {
            $null=NewFixture;$p=Preview;$script:MonotonicClock={$script:FixtureTicks};$b=CTNewBudget 120
            $script:PreferenceClock={[DateTimeOffset]::UtcNow.AddDays(3)};$script:FixtureTicks+=9*[Diagnostics.Stopwatch]::Frequency
            Check ((CTBudgetRemaining $b) -eq 111) 'UTC clock changed the monotonic budget';$script:PreferenceClock=$null
            $requestId=[guid]::NewGuid().ToString('N');$r=Invoke-TCConnectionSwitch -Root $script:Fixture -LineId $script:Alias -ProfileId Tcp -PreviewToken $p.PreviewToken -RequestId $requestId
            $progress=Get-TCConnectionTransactionProgress -Root $script:Fixture -RequestId $requestId
            Check ($progress.TransactionId -ceq $r.TransactionId -and $progress.Phase -eq 'Completed' -and $progress.Terminal -and $progress.Progress.BudgetSeconds -eq 120) 'Phase projection did not match actual journal'
            Check (-not (Get-TCConnectionTransactionProgress -Root $script:Fixture -RequestId ([guid]::NewGuid().ToString('N')))) 'Progress leaked another request'
            Import-Module (Join-Path $script:TestPackageRoot 'WorkerContracts.psm1') -DisableNameChecking
            $contract=Get-TCWorkerActionContract ConnectionSwitchCommit
            Check (-not $contract.ReadOnly -and $contract.TimeoutSeconds -ge 120+90+15) 'Supervisor expires before recovery grace'
        }
        Case 'F04 failed stop reconciles only after actual safe stop' {
            $null=NewFixture
            $script:Fault='StopOriginal'
            $result=Commit (Preview)
            Check ($result.Status -eq 'NeedsRecovery') 'Stop fault did not create expected durable transaction'
            $journal=CTRead $result.JournalPath
            $script:Observed.State='Stopped';$script:Active=0;$script:Fault=''
            AssertRestored
            $script:Ops.Clear()
            $first=@(Reconcile-TCConnectionTransactions -Root $script:Fixture -ResolveStopped)
            $second=@(Reconcile-TCConnectionTransactions -Root $script:Fixture -ResolveStopped)
            $next=Preview
            Check ($first[0].Status -eq 'ResolvedStopped' -and $second.Count -eq 0 -and $next.CanSwitch -and $first[0].RecoveryProof.OriginalConfigurationIntact) 'Safe stopped original must settle without historical booleans'
            Check (-not $journal.OriginalStopped -and -not $journal.ConfigurationRestored) 'Unexpected journal flags'
            Check (@($script:Ops|Where-Object {$_ -in @('Start','StopOriginal','StopOwnedCandidate','ApplyIntent','Verify')}).Count -eq 0) 'Reconciliation operated network'
        }
        Case 'F04 legacy Prepared crash aborts after unchanged stopped baseline proof' {
            $null=NewFixture $false
            $script:ProductionPhase=(Get-Command CTPhase).ScriptBlock
            $script:PreparedSnapshot=$null
            function script:CTPhase {param($Transaction,[string]$Phase,[string]$Status='InProgress')
                & $script:ProductionPhase $Transaction $Phase $Status
                if($Phase -ceq 'Prepared'){$script:PreparedSnapshot=CTRead $Transaction.JournalPath}
            }
            try{$result=Commit (Preview)}finally{Set-Item Function:script:CTPhase $script:ProductionPhase}
            Check ($result.Status -eq 'Completed' -and $script:PreparedSnapshot.Phase -eq 'Prepared') 'Could not capture actual durable Prepared boundary'
            $journal=$script:PreparedSnapshot
            foreach($snapshot in @($journal.Original.Manifest,$journal.Original.Deployment,$journal.Original.Index,$journal.Original.PreferenceFile)){CTRestoreFile $snapshot}
            if([IO.File]::Exists($journal.ActiveManifestPath)){[IO.File]::Delete($journal.ActiveManifestPath)}
            CTWrite $journal.JournalPath $journal
            $script:Observed=$journal.Original.Observed;$script:Active=0
            AssertRestored;$script:Ops.Clear()
            $first=@(Reconcile-TCConnectionTransactions -Root $script:Fixture -ResolveStopped)
            $second=@(Reconcile-TCConnectionTransactions -Root $script:Fixture -ResolveStopped)
            $next=Preview
            Check ($first[0].Status -eq 'Aborted' -and $second.Count -eq 0 -and $next.CanSwitch -and $first[0].RecoveryProof.Decision -eq 'AbortUnstarted') 'An actual unchanged Prepared checkpoint must abort safely'
        }
        foreach($fault in @('ConfigChanged','UnknownEngine','ManifestMissing','WrongRoot','WrongJournal','ProbePending')){
            Case ('F04 evidence guard '+$fault) {
                $null=NewFixture;$script:Fault='StopOriginal';$r=Commit (Preview)
                $script:Observed.State='Stopped';$script:Active=0;$script:Fault=''
                $tx=CTRead $r.JournalPath
                switch($fault){
                    'ConfigChanged'{[IO.File]::AppendAllText((CTRead $script:Old).CandidatePath,' ')}
                    'UnknownEngine'{$script:Observed.OwnershipKnown=$false}
                    'ManifestMissing'{[IO.File]::Delete($script:Old)}
                    'WrongRoot'{$tx.Root=Join-Path $script:Fixture 'wrong';CTWrite $r.JournalPath $tx}
                    'WrongJournal'{$tx.JournalPath=Join-Path $script:Fixture 'outside.json';CTWrite $r.JournalPath $tx}
                    'ProbePending'{$dir=Join-Path $script:Fixture ('probes\'+[guid]::NewGuid().ToString());$null=[IO.Directory]::CreateDirectory($dir);[IO.File]::WriteAllText((Join-Path $dir 'candidate.private.json'),'inert fixture')}
                }
                $script:Ops.Clear();$journalHash=CTHash $r.JournalPath
                $observed=@(Reconcile-TCConnectionTransactions -Root $script:Fixture -ResolveStopped)
                Check ($observed.Count -eq 1 -and $observed[0].Status -eq 'NeedsRecovery') ('Unsafe evidence accepted: '+$fault)
                if($fault -in @('WrongRoot','WrongJournal')){Check ((CTHash $r.JournalPath) -ceq $journalHash -and -not [IO.File]::Exists((Join-Path $script:Fixture 'outside.json'))) 'Invalid journal paths must not redirect writes'}
                Check (@($script:Ops|Where-Object {$_ -in @('Start','StopOriginal','StopOwnedCandidate','ApplyIntent','Verify')}).Count -eq 0) 'Recovery evidence read performed network actions'
            }
        }
        Case 'F04 precise request binding and live worker guard' {
            $null=NewFixture;$script:Fault='StopOriginal';$r=Commit (Preview)
            $script:Observed.State='Stopped';$script:Active=0;$script:Fault=''
            $tx=CTRead $r.JournalPath;$id=[guid]::NewGuid().ToString('N');$tx.RequestId=$id
            $tx|Add-Member NoteProperty Executor ([pscustomobject]@{ProcessId=987654;ProcessStartedTicks='123'})
            CTWrite $r.JournalPath $tx
            $oldGet=(Get-Command Get-Process).ScriptBlock
            try{
                function script:Get-Process {param($Id)$p=[pscustomobject]@{HasExited=$false;StartTime=([datetime]::new(123,[DateTimeKind]::Utc))};$p|Add-Member ScriptMethod Dispose {};return $p}
                $none=@(Reconcile-TCConnectionTransactions -Root $script:Fixture -ResolveStopped -RequestIds @([guid]::NewGuid().ToString('N')))
                Check ($none.Count -eq 0) 'Unrelated request must not reconcile this transaction'
                $blocked=@(Reconcile-TCConnectionTransactions -Root $script:Fixture -ResolveStopped -RequestIds @($id))
                Check ($blocked[0].Status -eq 'NeedsRecovery' -and $blocked[0].RecoveryProof.ReasonCode -eq 'OriginalWorkerStillActive') 'A live exact worker must remain protected despite stopped engine'
                function script:Get-Process {param($Id)$p=[pscustomobject]@{HasExited=$false;StartTime=([datetime]::new(456,[DateTimeKind]::Utc))};$p|Add-Member ScriptMethod Dispose {};return $p}
                $resolved=@(Reconcile-TCConnectionTransactions -Root $script:Fixture -ResolveStopped -RequestIds @($id))
                Check ($resolved[0].Status -eq 'ResolvedStopped' -and $resolved[0].RecoveryProof.OriginalConfigurationIntact) 'Reused PID is not the original worker; exact files and stopped ownership still required'
                $again=@(Reconcile-TCConnectionTransactions -Root $script:Fixture -ResolveStopped -RequestIds @($id))
                Check ($again[0].Status -eq 'ResolvedStopped' -and $again[0].TransactionId -eq $r.TransactionId) 'Same resolved request must read original terminal result'
            }finally{Set-Item Function:script:Get-Process $oldGet}
        }
        [pscustomobject]@{ExpectedMode='Fixed';ExpectedBehaviorSatisfied=$true;UnexpectedActors=0;Passed=$true;Checks=$script:Checks;CaseCount=$script:Cases.Count;Cases=$script:Cases.ToArray();ActualProcessTouches=$script:ActualProcessTouches;RealNetworkChanges=0;ActualChannelOperations=0;MockOperationCount=$script:AllOps.Count;Adapter='ModulePrivateTemporaryScriptBlock';FixtureScope='DisposableTempOnly';ProductionBridgeExecuted=$false;LockOrder='session -> NodeStore -> canonical line -> preferences'}
    } $fixture $bridge $CasePattern $package
}catch{$failure=$_.Exception.Message;$result=[pscustomobject]@{Passed=$false;Error=$failure;ActualProcessTouches=(& $bridge {$script:ActualProcessTouches});RealNetworkChanges=0;ProductionBridgeExecuted=$false}}
finally{
    & $module {$script:TestAdapter=$null}
    if($result){$result|Add-Member NoteProperty Timestamp ([DateTimeOffset]::UtcNow.ToString('o')) -Force;[IO.File]::WriteAllText($ReportPath,($result|ConvertTo-Json -Depth 20),(New-Object Text.UTF8Encoding($false)))}
    Remove-Module ConnectionTransactions,RuntimeBridge -ErrorAction SilentlyContinue
    $resolved=[IO.Path]::GetFullPath($fixture);$parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not $resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^\.connection-fixture-[a-f0-9]{32}$'){throw 'Cleanup rejected non-fixture directory'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
if($failure){throw $failure}
$result
