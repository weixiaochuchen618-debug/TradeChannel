#requires -Version 5.1
[CmdletBinding()]param([string]$ReportPath)
$ErrorActionPreference='Stop'
$package=Split-Path $PSScriptRoot -Parent
$workspace=Split-Path (Split-Path $package -Parent) -Parent
if(-not $ReportPath){$ReportPath=Join-Path $workspace 'reports\release-0.11.1\connection-transaction-tests.json'}
$reportRoot=Split-Path ([IO.Path]::GetFullPath($ReportPath)) -Parent
$null=[IO.Directory]::CreateDirectory($reportRoot)
$fixture=Join-Path $reportRoot ('.connection-fixture-'+[guid]::NewGuid().ToString('N'))
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
        function script:Start-Process {$script:ActualProcessTouches++;throw 'Real Start-Process forbidden'}
        function script:Stop-Process {$script:ActualProcessTouches++;throw 'Real Stop-Process forbidden'}
        function script:Invoke-TCCommand {$script:ActualProcessTouches++;throw 'Real channel command forbidden'}
        function script:Invoke-TCController {$script:ActualProcessTouches++;throw 'Real controller forbidden'}
        function script:Test-TCActiveConnection {$script:ActualProcessTouches++;throw 'Real network diagnostic forbidden'}
    }
    $result=& $module {
        param($FixtureRoot,$Bridge)
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
            $script:CaseNumber++;$script:Fixture=Join-Path $FixtureRoot ('case-'+$script:CaseNumber);$null=[IO.Directory]::CreateDirectory($script:Fixture)
            $script:LineId='11111111-1111-1111-1111-111111111111';$script:Alias='22222222-2222-2222-2222-222222222222'
            $script:Provider='33333333-3333-3333-3333-333333333333'
            $lineRoot=Join-Path $script:Fixture ('Product\lines\'+$script:LineId);$null=[IO.Directory]::CreateDirectory($lineRoot)
            $script:Old=Join-Path $script:Fixture 'old.manifest.json';$script:Udp=Join-Path $lineRoot 'udp.manifest.json';$script:Tcp=Join-Path $lineRoot 'tcp.manifest.json'
            foreach($entry in @(@($script:Old,'old'),@($script:Udp,'udp'),@($script:Tcp,'tcp'))){
                $config=Join-Path $script:Fixture ($entry[1]+'.config.json')
                $wg=@{type='wireguard';tag='hk';peers=@(@{public_key='fixture-server';address='192.0.2.20';port=51820})}
                $outbounds=@(@{tag='trade-exit';type='selector';outbounds=@('hk','provider-trade')},@{tag='daily-exit';type='selector';outbounds=@('direct','provider')})
                if($entry[1] -eq 'tcp'){$wg.detour='tc-transport';$outbounds+=@{tag='tc-transport';type='vless';server='192.0.2.20';tls=@{enabled=$true;reality=@{enabled=$true}}}}
                CTWrite $config @{inbounds=@(@{type='mixed';tag='egress-probe';listen='127.0.0.1';listen_port=17890;users=@(@{username='tradechannel-probe';password='fixture-only'},@{username='tradechannel-daily';password='fixture-only'})});route=@{fixture=$entry[1];rules=@(@{inbound=@('egress-probe');auth_user=@('tradechannel-daily');action='route';outbound='daily-exit'},@{inbound=@('egress-probe');action='route';outbound='trade-exit'},@{rule_set=@('tc-agents');action='route';outbound='trade-exit'})};endpoints=@($wg);outbounds=$outbounds}
                CTWrite $entry[0] @{SyntaxValidated=$true;DeploymentApproved=($entry[1] -eq 'old');CandidatePath=$config;CandidateSHA256=(CTHash $config);ServerPublicKey='fixture-server';ClientPublicKey='fixture-device';ServerEndpoint='192.0.2.20:51820';Providers=@(@{Id=$script:Provider;Tag='provider';TradeTag='provider-trade';Kind='custom';Name='fixture';Port=12080;TradePort=12081})}
            }
            CTWrite (Join-Path $script:Fixture 'Product\index.json') @{schemaVersion=1;nodes=@(@{id=$script:LineId;name='source';manifestPath=$script:Udp},@{id=$script:Alias;name='active alias';manifestPath=$script:Old});tradeDomains=@('example.invalid')}
            CTWrite (Join-Path $script:Fixture 'deployment.json') @{ManifestPath=$script:Old;Stage='Legacy';Extra='preserve exactly'}
            CTWrite (Join-Path $script:Fixture 'ui-preferences.json') @{Mode='Global';Exit='Provider';Daily='Provider';Agents='Trade';AgentIds=@('chatgpt','claude');AgentCustom=@(@{Kind='Site';Value='example.invalid'});NodeId=$script:Alias;ProviderId=$script:Provider;TradeProviderId=$script:Provider;ProfileId='Udp';Extra='keep all raw fields'}
            $script:Profiles=@([pscustomobject]@{Id='Udp';ManifestPath=$script:Udp;CandidateSHA256=(CTRead $script:Udp).CandidateSHA256;PreparationState='SyntaxValidated';Validation=$null},[pscustomobject]@{Id='Tcp';ManifestPath=$script:Tcp;CandidateSHA256=(CTRead $script:Tcp).CandidateSHA256;PreparationState='SyntaxValidated';Validation=$null})
            $script:Line=[pscustomobject]@{LineId=$script:LineId;Name='fixture';SourceNodeId=$script:LineId;AliasIds=@($script:Alias);Revision=2;Profiles=$script:Profiles;PreferredProfileId='Udp'}
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
                'Preflight'{if($script:Ninja){throw 'NinjaTrader must exit'};return}
                'Line'{[pscustomobject]@{Line=$script:Line;Profile=@($script:Profiles|Where-Object Id -eq $Payload.ProfileId)[0]};return}
                'Observe'{return ($script:Observed|ConvertTo-Json -Depth 12|ConvertFrom-Json)}
                'Preferences'{return CTRead (Join-Path $Root 'ui-preferences.json')}
                'ValidateIntent'{if($script:Fault -eq 'IntentInvalid'){throw 'Target lacks original intent'};return & $Bridge {param($DataRoot,$Data)$script:Root=$DataRoot;Assert-TCConnectionIntent $Data.Manifest $Data.Intent $Data.ProfileId $Data.LineId} $Root $Payload}
                {$_ -in @('StopOriginal','StopOwnedCandidate')}{
                    Check ((CTRead (Get-ChildItem (Join-Path $Root 'connection-transactions') -Filter '*.json'|Select-Object -First 1).FullName).Phase -eq $Operation) 'Stop intent was not journaled before operation'
                    if(($Operation -eq 'StopOriginal' -and $script:Fault -in @('StopOriginal','StopNoEffect')) -or ($Operation -eq 'StopOwnedCandidate' -and $script:Fault -eq 'StopCandidate')){if($script:Fault -eq 'StopNoEffect'){return};throw 'Injected stop failure'}
                    $script:Observed.State='Stopped';$script:Active=0;return
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
            CTWrite $registryPath $registry;$p=Preview;Check ($p.CanSwitch -and $p.ExitEvidence.Authoritative -and $p.ExitEvidence.Source -eq 'ServerVerifiedTlsTrace') 'Preview omitted bound registry evidence'
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
        [pscustomobject]@{Passed=$true;Checks=$script:Checks;CaseCount=$script:Cases.Count;Cases=$script:Cases.ToArray();ActualProcessTouches=$script:ActualProcessTouches;RealNetworkChanges=0;ActualChannelOperations=0;MockOperationCount=$script:AllOps.Count;Adapter='ModulePrivateTemporaryScriptBlock';FixtureScope='WorkspaceOnly';ProductionBridgeExecuted=$false;LockOrder='session -> NodeStore -> canonical line -> preferences'}
    } $fixture $bridge
}catch{$failure=$_.Exception.Message;$result=[pscustomobject]@{Passed=$false;Error=$failure;ActualProcessTouches=(& $bridge {$script:ActualProcessTouches});RealNetworkChanges=0;ProductionBridgeExecuted=$false}}
finally{
    & $module {$script:TestAdapter=$null}
    if($result){$result|Add-Member NoteProperty Timestamp ([DateTimeOffset]::UtcNow.ToString('o')) -Force;[IO.File]::WriteAllText($ReportPath,($result|ConvertTo-Json -Depth 20),(New-Object Text.UTF8Encoding($false)))}
    Remove-Module ConnectionTransactions,RuntimeBridge -ErrorAction SilentlyContinue
    $resolved=[IO.Path]::GetFullPath($fixture);$parent=[IO.Path]::GetFullPath($reportRoot).TrimEnd('\')+'\'
    if(-not $resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^\.connection-fixture-[a-f0-9]{32}$'){throw 'Cleanup rejected non-fixture directory'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
if($failure){throw $failure}
$result
