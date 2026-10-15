#requires -Version 5.1
<#
Disposable integration test. Run in a fresh Windows PowerShell 5.1 process.
Only owned tests and reports/release-0.15.0/probe-workflow-integration*.json/log
are deliverables. All application writes use one unique, restricted fixture root.

The real DeploymentFlow -> ProtocolComparison -> LineStore preparation, profile
reload, evidence normalization, recommendation and history code is executed.
The HTTP boundary adapter executes AST statements FROM CandidateProbe.psm1:
its identity/cleanup checks, request schedule, summaries, path assessment and
receipt finalization. It omits engine startup and process termination. This is
not a test of the engine lifecycle. The only observations supplied by fixtures
are adapter snapshots, owned socket/ETW metadata and HTTP responses. No policy
or preparation result is supplied as a canned Passed object. In particular,
PathEvidence.Verified is set only by the production path evaluator.

JourneyOnly executes Create -> Inspect -> one approval -> Apply/Manage/Auth ->
real profiles/comparison -> real saved default -> production UI DTO. NegativeControl
uses 0.14.3 runtime to demonstrate missing access/autosave/saved-default contracts.
Do not run the existing ProbePath test here: it intentionally starts live sockets.
#>
[CmdletBinding()]
param(
    [string]$PackageRoot = '',
    [ValidatePattern('^probe-workflow-integration(?:-[a-zA-Z0-9-]+)?$')]
    [string]$ReportName = 'probe-workflow-integration',
    [switch]$BarrierOnly,
    [switch]$CoreMatrixOnly,
    [switch]$JourneyOnly,
    [switch]$NegativeControl,
    [ValidateSet('All','ApplyRecovery','AuthorizeRecovery','RetainedReply')][string]$JourneyCase='All'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version 2.0
$ownPackage = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$workspace = Split-Path (Split-Path $ownPackage -Parent) -Parent
if (-not $PackageRoot) { $PackageRoot = $ownPackage }
$PackageRoot = [IO.Path]::GetFullPath($PackageRoot)
$reportDirectory = Join-Path $workspace 'reports\release-0.15.0'
$reportPath = Join-Path $reportDirectory ($ReportName + '.json')
$logPath = Join-Path $reportDirectory ($ReportName + '.log')
$parentRoot = [Environment]::GetFolderPath('LocalApplicationData')
$work = Join-Path $parentRoot ('TC-ProbeWorkflowIntegration-' + [guid]::NewGuid().ToString('N'))
$engine = Join-Path $PackageRoot 'assets\sing-box.exe'
$wg = Join-Path $PackageRoot 'assets\wg.exe'
$checks = New-Object 'Collections.Generic.List[object]'
$caseReports = New-Object 'Collections.Generic.List[object]'
$log = New-Object 'Collections.Generic.List[string]'
$secrets = New-Object 'Collections.Generic.List[string]'
$passed = $false
$removed = $false
$failure = $null
$script:Case = 'Setup'
$script:LastAssertion = ''
$modules = @{}
$nativeOriginal = $null
$originalCore = @{}
$sourceBefore = [ordered]@{}
$sourceAfter = [ordered]@{}
$testSHA256 = ''
$historicalFull = $null
$state = [pscustomobject]@{
    Root = $work; PackageRoot = $PackageRoot; Engine = $engine; Wg = $wg; Mode = 'FastTcp'
    ActiveRoot = ''; ActiveRunId = ''; CurrentProfile = ''; FlowModule = $null
    ProbeCount = 0; HttpCount = 0; SnapshotReads = 0; ObservationStarts = 0
    ObservationStops = 0; AssessmentCount = 0; ForbiddenCalls = 0
    Events = (New-Object 'Collections.Generic.List[object]')
    Receipts = (New-Object 'Collections.Generic.List[object]')
    NativeCalls = (New-Object 'Collections.Generic.List[object]')
    Writes = (New-Object 'Collections.Generic.List[string]')
    LeaseMatrix = (New-Object 'Collections.Generic.List[object]')
    Snapshot = $null; AdapterRanges = @(); AdapterSourceSHA256 = ''
    TransportModule=$null; ExecutorPoll=$null; ExecutorSession=$null; EvidenceReads=0; LostOperation=''
    Dispatches=(New-Object 'Collections.Generic.List[object]')
    Journeys=(New-Object 'Collections.Generic.List[object]')
    Findings=(New-Object 'Collections.Generic.List[object]')
    Contracts=[ordered]@{}; UiModule=$null; LatestRun=$null; LatestError=$null; ManagementJwk=$null
    ReportSecrets=$secrets
    RecoveryNegatives=(New-Object 'Collections.Generic.List[object]')
    CachedContinuations=(New-Object 'Collections.Generic.List[object]')
}

function Field { param($Value, [string]$Name, $Default = $null)
    if ($Value -is [Collections.IDictionary]) { if ($Value.Contains($Name)) { return $Value[$Name] } }
    elseif ($null -ne $Value -and $Value.PSObject.Properties[$Name]) { return $Value.$Name }
    $Default
}
function Note { param([string]$Text)
    foreach($secret in $secrets){if($secret){$Text=$Text.Replace($secret,'[redacted-fixture-secret]')}}
    $line = [DateTimeOffset]::UtcNow.ToString('o') + ' ' + $Text
    $log.Add($line); Write-Host $Text
}
function Check { param([bool]$Condition, [string]$Label)
    $script:LastAssertion = $Label
    if (-not $Condition) { throw ('Integration assertion: ' + $Label) }
    $checks.Add([pscustomobject]@{Case=$script:Case; Label=$Label})
    Note ('PASS [' + $script:Case + '] ' + $Label)
}
function Clone { param($Value) ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $Value -Depth 80) }
function Json { param($Value) ConvertTo-Json -InputObject $Value -Depth 80 -Compress }
function ReadJson { param([string]$Path) ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Path)) }
function Hash { param([string]$Path) (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
function TextHash { param([string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-','') }
    finally { $sha.Dispose() }
}
function AssertFixturePath { param([string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    if (-not ($full.Equals($work,[StringComparison]::OrdinalIgnoreCase) -or
        $full.StartsWith($work.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase))) {
        throw 'Fixture write/lock outside the unique root refused'
    }
    & $modules.Nodes { param($p) Assert-TCNoReparse $p } $full
    $full
}
function WriteFixture { param([string]$Path, $Value)
    $full = AssertFixturePath $Path
    & $modules.Nodes { param($p,$v) Write-TCAtomicJson -Path $p -Value $v -NoBom } $full $Value
}
function PrivateDirectory { param([string]$Path)
    $full = AssertFixturePath $Path
    $null = & $modules.Nodes { param($p) New-TCPrivateDirectory $p } $full
}
function SnapshotFiles { param([string[]]$Paths)
    Json @(foreach ($path in @($Paths | Sort-Object -Unique)) {
        [pscustomobject]@{Path=$path; Hash=(Hash $path); Acl=(Get-Acl -LiteralPath $path).Sddl}
    })
}
function SnapshotTree { param([string]$Root)
    SnapshotFiles @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force | Select-Object -ExpandProperty FullName)
}
function NewKey {
    $bytes = New-Object byte[] 32; $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($bytes); $bytes[0]=$bytes[0] -band 248; $bytes[31]=($bytes[31] -band 127) -bor 64
        [Convert]::ToBase64String($bytes)
    } finally { $rng.Dispose(); [Array]::Clear($bytes,0,$bytes.Length) }
}
function SetSnapshot { param([switch]$Multiple, [switch]$VirtualOnly)
    $interfaces = @([pscustomobject]@{
        Index=7; Id='fixture-interface-7'; Name='Ethernet Fixture'; Status='Up'; Type='Ethernet'
        Hardware=(-not $VirtualOnly); Metric=10
        Addresses=@([pscustomobject]@{Address='192.0.2.2'; Family='InterNetwork'; PrefixLength=24; State='Preferred'})
        Gateways=@('192.0.2.1'); DnsServers=@('192.0.2.53')
    })
    $routes = @([pscustomobject]@{InterfaceIndex=7; DestinationPrefix='0.0.0.0/0'; NextHop='192.0.2.1'; RouteMetric=10; AddressFamily='IPv4'})
    if ($Multiple) {
        $interfaces += [pscustomobject]@{
            Index=8; Id='fixture-interface-8'; Name='Wi-Fi Fixture'; Status='Up'; Type='Wireless80211'
            Hardware=$true; Metric=20
            Addresses=@([pscustomobject]@{Address='198.51.100.2'; Family='InterNetwork'; PrefixLength=24; State='Preferred'})
            Gateways=@('198.51.100.1'); DnsServers=@('198.51.100.53')
        }
        $routes += [pscustomobject]@{InterfaceIndex=8; DestinationPrefix='0.0.0.0/0'; NextHop='198.51.100.1'; RouteMetric=20; AddressFamily='IPv4'}
    }
    $state.Snapshot = [pscustomobject]@{Interfaces=$interfaces; Routes=$routes}
}
function NewFixture { param([string]$Slot, [string]$TcpServer='192.0.2.10', [switch]$UserChoice)
    $root = Join-Path $work $Slot; PrivateDirectory $root
    $private=NewKey; $serverPrivate=NewKey; $secrets.Add($private); $secrets.Add($serverPrivate)
    $public = & $modules.Nodes { param($e,$k) Invoke-TCNative -FilePath $e -ArgumentList @('pubkey') -InputText $k } $wg $serverPrivate
    $conf=Join-Path $root 'client.conf'; $program=Join-Path $root 'NinjaTrader.exe'
    $null=AssertFixturePath $program; [IO.File]::WriteAllText($program,'inert fixture, never executable')
    $endpoint=if($TcpServer.Contains(':')){'['+$TcpServer+']:51820'}else{$TcpServer+':51820'}
    $text="[Interface]`nPrivateKey = $private`nAddress = 10.78.0.4/24`n[Peer]`nPublicKey = $($public.StandardOutput.Trim())`nEndpoint = $endpoint`nAllowedIPs = 0.0.0.0/0`nPersistentKeepalive = 25`n"
    $null=AssertFixturePath $conf; [IO.File]::WriteAllText($conf,$text,(New-Object Text.UTF8Encoding($false)))
    & $modules.Nodes { param($p) Set-TCPrivateAcl $p } $conf
    $node=Import-TCWireGuard -Root (Join-Path $root 'Product') -Path $conf -Name 'Offline integration fixture' -EnginePath $engine -WgPath $wg -TradeProgramPaths @($program) -DirectDnsIPv4 '192.0.2.53' -Providers @()
    $manifest=ReadJson $node.manifestPath
    $info=[pscustomobject]@{
        Kind='TradeChannel.TransportInfo'; Status='Available'; NodeId=[guid]::NewGuid().ToString('D')
        RemoteOwnerId=[guid]::NewGuid().ToString('D'); ServerPublicKey=$manifest.ServerPublicKey
        ClientPublicKey=$manifest.ClientPublicKey; ClientAddress='10.78.0.4/32'
        Transport=[pscustomobject]@{Type='tcp-reality'; Server=$TcpServer; Port=443
            Uuid='aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'; RealityPublicKey='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
            RealityShortId='1234567890abcdef'; ServerName='www.bing.com'}
    }
    $null=Register-TCLineProfiles -Root $root -Id $node.id
    $null=Prepare-TCTcpLineProfile -Root $root -Id $node.id -TransportInfo $info
    if ($UserChoice) { $null=Set-TCLinePreferredProfile -Root $root -Id $node.id -ProfileId Udp }
    $serverInfo=[pscustomobject]@{RemoteOwnerId=$info.RemoteOwnerId;ManagementApiVersion=1;OwnershipState='Managed';Node=[pscustomobject]@{NodeId=$info.NodeId;ServerPublicKey=$manifest.ServerPublicKey;PublicEndpoint=$node.endpoint}}
    $server=Set-TCServerRecord -Root $root -Name 'Offline integration server' -ServerInfo $serverInfo
    $server=Set-TCServerLink -Root $root -ServerId $server.LocalRecordId -NodeId $node.id
    WriteFixture (Join-Path $root 'deployment.json') @{ManifestPath=$node.manifestPath; Stage='ReadyInactive'; FixtureOnly=$true}
    WriteFixture (Join-Path $root 'runtime.json') @{State='Stopped'; ManifestPath=$node.manifestPath; CleanupError=$false; FixtureOnly=$true}
    WriteFixture (Join-Path $root 'ui-preferences.json') @{NodeId=$node.id; Transport='Tcp'; DailyMode='rule'; FixtureOnly=$true}
    $protected=@($conf,$program,(Join-Path $root 'Product\index.json'),$node.manifestPath,$manifest.CandidatePath,$manifest.ProbePath,
        (Join-Path $root 'deployment.json'),(Join-Path $root 'runtime.json'),(Join-Path $root 'ui-preferences.json'),(Join-Path $root 'servers\registry.json'))
    $line=Get-TCLine -Root $root -Id $node.id
    [pscustomobject]@{Root=$root; Node=$node; Server=$server; Manifest=$manifest; OldLine=$line; Info=$info; Protected=$protected; Before=(SnapshotFiles $protected)}
}
function NewFixtureRun { param($Fixture)
    $run=[pscustomobject][ordered]@{
        SchemaVersion=1; ExperienceVersion=1; RunId=[guid]::NewGuid().ToString('D'); Revision=0; Intent='NewServer'
        ServerRecordId=$Fixture.Server.LocalRecordId; Name='Offline integration'; Transport='Auto'
        Stage='ReadyInactive'; Status='WaitingUser'; SessionRef=$null; PendingOperationId=$null; PendingPurpose=$null
        CandidateNodeId=$Fixture.Node.id; CandidateManifestPath=$Fixture.Node.manifestPath
        ExpectedExitIPv4='192.0.2.40'; ExpectedExitSource='ServerVerifiedTlsTrace'; Validation=$null
        LastError=$null; NetworkChanged=$false; UserActions=@(); CreatedAtUtc=[DateTimeOffset]::UtcNow.ToString('o')
        UpdatedAtUtc=[DateTimeOffset]::UtcNow.ToString('o')
        ProtocolPreparation=[pscustomobject]@{
            Udp=[pscustomobject]@{ServerPreparation='Configured'; LocalPreparation='SyntaxValidated'; Error=$null}
            Tcp=[pscustomobject]@{ServerPreparation='Configured'; LocalPreparation='SyntaxValidated'; Error=$null}
        }
    }
    $null=& $modules.Flow { param($r,$run) Save-TCDeploymentRun $r $run } $Fixture.Root $run
    $run
}
function BeginCase { param([string]$Name, [string]$Mode='FastTcp')
    $script:Case=$Name; $state.Mode=$Mode; $state.ProbeCount=0; $state.HttpCount=0
    $state.ObservationStarts=0; $state.ObservationStops=0; $state.AssessmentCount=0
    $state.Events.Clear(); $state.Receipts.Clear()
}
function ProbeRun { param($Fixture,$Run,[int]$InterfaceIndex=0)
    $state.ActiveRoot=$Fixture.Root; $state.ActiveRunId=$Run.RunId
    $arguments=@{Root=$Fixture.Root;RunId=$Run.RunId;Command='Probe'}
    if((Get-Command Invoke-TCDeploymentAdvance).Parameters.ContainsKey('InterfaceIndex')){$arguments.InterfaceIndex=$InterfaceIndex}
    elseif($InterfaceIndex -ne 0){throw 'Selected interface is unsupported by this package'}
    Invoke-TCDeploymentAdvance @arguments
}
function RecordCase { param($Run,$Fixture)
    $caseReports.Add([pscustomobject]@{
        Name=$script:Case; ProbeCount=$state.ProbeCount; HttpCount=$state.HttpCount
        ObservationStarts=$state.ObservationStarts; ObservationStops=$state.ObservationStops
        AssessmentCount=$state.AssessmentCount; LineId=$Fixture.Node.id; RunId=$Run.RunId
        Stage=$Run.Stage; ProfileProbeState=$Run.ProfileProbeState; RecoveryRequired=$Run.RecoveryRequired
        BindingResult=(Field $Run ProbeBindingResult); Recommendation=(Field $Run Recommendation)
        Profiles=@(foreach($id in @('Udp','Tcp')) {
            $e=Field $Run.ValidationProfiles $id; $raw=Field $e Result
            [pscustomobject]@{Id=$id; Status=(Field $e Status); Code=(Field $e Code)
                CandidateSHA256=(Field $e CandidateSHA256); ManifestSHA256=(Field $raw ManifestHash)
                Eligible=(Field $e EligibleForAutomaticSelection $false); PathEvidence=(Field $e PathEvidence)
                Comparison=(Field $raw Comparison); Samples=(Field $raw Samples @())}
        })
        Progress=@($state.Events.ToArray()); Receipts=@($state.Receipts.ToArray())
    })
}
function CheckFenced { param($Run,[string]$Code,[int]$ProbeCount,[int]$HttpCount)
    Check ($state.ProbeCount -eq $ProbeCount -and $state.HttpCount -eq $HttpCount) ($Code+' fences the next protocol and HTTP request')
    Check (-not $Run.RecommendedProfileId -and -not (Field $Run.Recommendation PerformanceRanked $false)) ($Code+' produces no automatic/performance recommendation')
    foreach($id in @('Udp','Tcp')) {
        $e=Field $Run.ValidationProfiles $id
        Check (-not (Field $e EligibleForAutomaticSelection $false) -and (Field $e Code '') -eq $Code) ($Code+' invalidates '+$id+' evidence')
    }
}
function ReadSourceHashes {
    $result=[ordered]@{}
    foreach($name in @('NodeStore.psm1','LineStore.psm1','ProbePath.psm1','CandidateProbe.psm1','ProtocolComparison.psm1','ProtocolSelection.psm1','DeploymentStore.psm1','ServerRegistry.psm1','DeploymentTransport.psm1','DeploymentDecision.psm1','DeploymentFlow.psm1','ui/ConnectionProfilePages.ps1','ui/DeploymentPages.ps1')) {
        $result[$name]=Hash (Join-Path $PackageRoot $name)
    }
    $result
}
function InvokeLeaseMatrixAction {param([string]$Root,[string]$RunId,$Sentinel,[string]$Action,$Session)
    # Deliberately provide a valid run in the Flow CALLER scope. Old Sync catch
    # could see this object before acquiring .run.lock and save it on failure.
    & $modules.Flow {param($Root,$RunId,$Sentinel,$Action,$Session)
        $run=$Sentinel
        switch($Action) {
            Attach {Set-TCDeploymentSession -Root $Root -RunId $RunId -SessionRef $Session}
            Advance {Invoke-TCDeploymentAdvance -Root $Root -RunId $RunId -Command Save}
            Sync {Sync-TCDeploymentRun -Root $Root -RunId $RunId}
        }
    } $Root $RunId $Sentinel $Action $Session
}
function InvokeDirectLeaseMatrix {
    BeginCase 'DirectLeaseMatrix'
    $root=Join-Path $work 'direct-lease-matrix'; PrivateDirectory $root
    $server=Set-TCServerRecord -Root $root -Name 'Offline lease fixture' -Connection @{Host='192.0.2.50';Port=22;User='root';IdentityFile=''}
    $created=New-TCDeploymentRun -Root $root -ServerId $server.LocalRecordId -Name 'Offline lease fixture' -ClientInspection @{NinjaTraderPaths=@();DirectDnsIPv4=@('1.1.1.1')}
    $session=[pscustomobject]@{RunId=$created.RunId;InstanceId=[guid]::NewGuid().ToString('D')}
    $runPath=Join-Path (Join-Path $root ('deployments\runs\'+$created.RunId)) 'state.json'
    $lockPath=Join-Path (Split-Path $runPath -Parent) '.run.lock'
    $state.ActiveRoot=$root; $state.ActiveRunId=$created.RunId
    foreach($boundary in @('HeldServer','HeldRun','Archived')) {
        $lease=$null; $heldRun=$null
        if($boundary -ceq 'HeldServer'){$lease=Open-TCServerTaskLease -Root $root -ServerId $server.LocalRecordId}
        elseif($boundary -ceq 'HeldRun'){$heldRun=Open-TCDLock -Path $lockPath}
        else {
            $registryPath=Join-Path $root 'servers\registry.json'; $registry=Read-TCDJson $registryPath
            $registry.Servers[0] | Add-Member NoteProperty RecordState 'Archived' -Force
            Write-TCDJson -Path $registryPath -Value $registry
        }
        try {
            $actions=if($boundary -ceq 'HeldRun'){@('Advance','Sync')}else{@('Attach','Advance','Sync')}
            foreach($action in $actions) {
                $script:Case='DirectLeaseMatrix-'+$boundary+'-'+$action
                $sentinel=Clone $created; $sentinel | Add-Member NoteProperty CallerScopeSentinel 'MustRemainUntouched'
                $objectBefore=Json $sentinel; $fileBefore=Hash $runPath; $writesBefore=$state.Writes.Count; $caught=$null
                try{$null=InvokeLeaseMatrixAction $root $created.RunId $sentinel $action $session}catch{$caught=$_}
                $fileAfter=Hash $runPath; $objectAfter=Json $sentinel; $writeDelta=$state.Writes.Count-$writesBefore
                $expected=if($boundary -ceq 'Archived'){'ServerArchived'}else{'Busy'}
                $errorCode=if($caught -and $caught.Exception.Message -match '\[TC:([A-Za-z0-9_]+)\]'){$Matches[1]}else{$null}
                $state.LeaseMatrix.Add([pscustomobject]@{Boundary=$boundary;Action=$action;Threw=[bool]$caught;Code=$errorCode;RunSHA256Before=$fileBefore;RunSHA256After=$fileAfter;CallerObjectUnchanged=($objectBefore -ceq $objectAfter);StateWriteDelta=$writeDelta})
                Check ($null -ne $caught -and $errorCode -ceq $expected) ($boundary+' '+$action+' propagates the actual '+$expected+' failure')
                Check ($fileAfter -ceq $fileBefore -and $writeDelta -eq 0) ($boundary+' '+$action+' performs no save before acquiring the required locks')
                Check ($objectAfter -ceq $objectBefore) ($boundary+' '+$action+' leaves the caller-scope run sentinel unchanged')
                if($boundary -ceq 'HeldRun') {
                    # Reacquire WHILE the run lock is still held: finally must
                    # release the earlier server lease before returning error.
                    $released=Open-TCServerTaskLease -Root $root -ServerId $server.LocalRecordId
                    try{Check ([bool]$released) ($action+' run-lock failure releases the real server lease immediately')}finally{$released.Dispose()}
                }
            }
        } finally {if($heldRun){$heldRun.Dispose()};if($lease){$lease.Dispose()}}
        if($boundary -ceq 'HeldRun') {
            $script:Case='DirectLeaseMatrix-Success'
            $synced=InvokeLeaseMatrixAction $root $created.RunId (Clone $created) Sync $session
            Check ($synced.RunId -ceq $created.RunId -and $synced.Stage -ceq 'PrepareAccess') 'direct idle Sync succeeds after the real held-lock failures'
            $attached=InvokeLeaseMatrixAction $root $created.RunId (Clone $created) Attach $session
            Check ($attached.RunId -ceq $created.RunId -and $attached.Stage -ceq 'Inspect') 'direct SetSession acquires/releases its own real lease without dispatch'
            # Ready fixture state only; no server, engine or network action.
            $attached.Stage='ReadyInactive';$attached.Status='WaitingUser'
            $null=& $modules.Flow {param($r,$v) Save-TCDeploymentRun $r $v} $root $attached
            $saved=InvokeLeaseMatrixAction $root $created.RunId (Clone $created) Advance $session
            Check ($saved.RunId -ceq $created.RunId -and $saved.SavedForLaterAtUtc) 'direct Advance Save succeeds without a reentrant server lease'
            $released=Open-TCServerTaskLease -Root $root -ServerId $server.LocalRecordId
            try{Check ([bool]$released) 'successful direct APIs release the real server lease'}finally{$released.Dispose()}
        }
    }
    Check ($state.ProbeCount -eq 0 -and $state.HttpCount -eq 0 -and $state.ForbiddenCalls -eq 0) 'held-lock and archive matrix has zero server/Worker/network operations'
}

function NewJourneySession {param($Run,[string]$Root)
    [pscustomobject]@{RunId=$Run.RunId;InstanceId=[guid]::NewGuid().ToString('D');PipeName=('TCDeploy-'+[guid]::NewGuid().ToString('N'));ProcessId=240001;StartTimeUtcTicks='638000000000000000';Root=$Root}
}
function SetJourneyPoll {param($Run,$Session,[string]$Status='Completed',$Data=$null,[string]$Code='Completed')
    $server=Get-TCServer -Root $state.ActiveRoot -Id $Run.ServerRecordId;$c=$server.Connection
    $state.ExecutorSession=$Session
    $state.ExecutorPoll=[pscustomobject]@{
        Ok=($Status -in @('Ready','Completed'));RunId=$Run.RunId;InstanceId=$Session.InstanceId
        Status=$Status;Code=$Code;HasSession=($Status -notin @('Failed','OutcomeUnknown'))
        Operation=(Field $Run.DispatchIntent Operation '');OperationId=$Run.PendingOperationId;Data=$Data
        HasMutatingOperations=[bool](@($state.Dispatches | Where-Object {$_.RunId -ceq $Run.RunId -and $_.InstanceId -ceq $Session.InstanceId -and $_.Mutating}).Count)
        AuthenticationGeneration=1;Connection=[pscustomobject]@{Host=$c.Host;Port=$c.Port;User=$c.User}
        ObservedFingerprint=('SHA256:'+('A'*43));AcceptedFingerprint=('SHA256:'+('A'*43));ObservedHostKeyAlgorithm='ssh-ed25519';HostKeyAlgorithm='ssh-ed25519'
    }
}
function FinishJourney {param($Run,$Data,[string]$Purpose='')
    $state.LatestRun=$Run
    if($Purpose -and $Run.PendingPurpose -cne $Purpose){throw ('Expected '+$Purpose+', actual '+$Run.PendingPurpose+' / '+$Run.Stage+' / '+(Field $Run.LastError Code '')+' / '+(Field $Run.LastError Message ''))}
    SetJourneyPoll $Run $Run.SessionRef Completed $Data
    $state.LatestRun=Sync-TCDeploymentRun -Root $state.ActiveRoot -RunId $Run.RunId
    if($state.LatestRun.Status -ceq 'Failed' -and $Error.Count){$err=$Error[0];$message=$err.Exception.Message;foreach($secret in $secrets){$message=$message.Replace($secret,'[redacted-key]')};$state.LatestError=[pscustomobject]@{Message=$message;Type=$err.Exception.GetType().FullName;ErrorId=$err.FullyQualifiedErrorId;SourceLine=$err.InvocationInfo.ScriptLineNumber;Stack=$err.ScriptStackTrace}}
    $state.LatestRun
}
function InstallJourneyBoundary {
    $state.TransportModule=$modules.Transport
    # Ephemeral RSA-3072 public identity, in the format produced by real management.
    $rsa=New-Object Security.Cryptography.RSACng
    try{$rsa.KeySize=3072;$parameters=$rsa.ExportParameters($false);$state.ManagementJwk=[pscustomobject]@{kty='RSA';n=([Convert]::ToBase64String($parameters.Modulus).TrimEnd('=').Replace('+','-').Replace('/','_'));e=[Convert]::ToBase64String($parameters.Exponent).TrimEnd('=')}}finally{$rsa.Dispose()}
    & $modules.Transport {param($s)
        $script:Workflow=$s
        function script:Assert-WorkflowExecutor {param($SessionRef)
            if(-not $script:Workflow.ExecutorSession -or (ConvertTo-Json $SessionRef -Compress) -cne (ConvertTo-Json $script:Workflow.ExecutorSession -Compress)){throw 'Executor fixture session binding changed'}
            if(-not ([IO.Path]::GetFullPath($SessionRef.Root).StartsWith($script:Workflow.Root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase))){throw 'External executor root forbidden'}
        }
        function script:Read-TCDeployObservation {param($SessionRef)
            Assert-WorkflowExecutor $SessionRef;$script:Workflow.EvidenceReads++;$script:Workflow.ExecutorPoll
        }
        function script:Invoke-TCDeployPipe {param($SessionRef,$Body)
            Assert-WorkflowExecutor $SessionRef
            if($Body.Command -ceq 'Poll'){return $script:Workflow.ExecutorPoll}
            if($Body.Command -ceq 'Cancel'){
                $r=& $script:Workflow.FlowModule {param($root,$id)Get-TCDeploymentRun $root $id} $script:Workflow.ActiveRoot $SessionRef.RunId
                if($r.StopTransaction.State -cne 'Prepared' -or $r.StopTransaction.DispatchIntent.IntentId -cne $r.LastRemoteMutation.IntentId){throw 'Executor cancellation did not preserve the original durable mutation'}
                return [pscustomobject]@{Ok=$true;Status='OutcomeUnknown';Code='StopRequested'}
            }
            if($Body.Command -cne 'Execute'){$script:Workflow.ForbiddenCalls++;throw 'Only fixture Poll/Execute envelopes are allowed'}
            $r=& $script:Workflow.FlowModule {param($root,$id)Get-TCDeploymentRun $root $id} $script:Workflow.ActiveRoot $SessionRef.RunId
            if($r.Status -cne 'Dispatching' -or $r.DispatchIntent.State -cne 'Prepared' -or $r.DispatchIntent.IntentId -cne $Body.OperationId -or $r.DispatchIntent.Operation -cne $Body.Operation){throw 'Executor received an operation without the real durable dispatch intent'}
            $script:Workflow.Dispatches.Add([pscustomobject]@{RunId=$SessionRef.RunId;InstanceId=$SessionRef.InstanceId;Operation=$Body.Operation;OperationId=$Body.OperationId;Mutating=[bool]$r.DispatchIntent.Mutating;Input=$Body.Input})
            $p=$script:Workflow.ExecutorPoll;$p.Status='Running';$p.Code='Running';$p.Operation=$Body.Operation;$p.OperationId=$Body.OperationId;$p.Data=$null;$p.HasMutatingOperations=[bool]($p.HasMutatingOperations -or $r.DispatchIntent.Mutating)
            if($script:Workflow.LostOperation -ceq $Body.Operation){
                $script:Workflow.LostOperation='';$p.Status='OutcomeUnknown';$p.Code='AuthenticationRequired';$p.HasSession=$false
                throw 'Fixture accepted mutation then lost pipe reply'
            }
            [pscustomobject]@{Ok=$true;Status='Running';Operation=$Body.Operation;OperationId=$Body.OperationId}
        }
        function script:Start-TCDeploySession {$script:Workflow.ForbiddenCalls++;throw 'Live SSH executor creation forbidden'}
        function script:Start-Process {$script:Workflow.ForbiddenCalls++;throw 'Live executor process forbidden'}
    } $state
    & $modules.Flow {param($t)
        $script:WorkflowTransport=$t
        function script:Invoke-TCDeployOperation {param($SessionRef,$Operation,[Alias('Input')]$OperationInput=@{},[string]$OperationId)
            & $script:WorkflowTransport {param($s,$op,$data,$id)Invoke-TCDeployOperation -SessionRef $s -Operation $op -OperationInput $data -OperationId $id} $SessionRef $Operation $OperationInput $OperationId
        }
        function script:Get-TCDeploymentLocalNetworks {@('0.0.0.0/0','192.0.2.0/24')}
    } $modules.Transport
    & $modules.Setup {param($s,$secretValues)
        $script:Workflow=$s;$script:WorkflowSecrets=$secretValues
        $script:WorkflowNative=${function:Invoke-TCNative};$script:WorkflowText=${function:Write-TCText};$script:WorkflowJson=${function:Write-TCJson};$script:WorkflowDirectory=${function:New-TCPrivateDirectory}
        function script:Assert-WorkflowSetupPath {param($Path)
            $full=Get-TCFullPath $Path
            if(-not $full.StartsWith($script:Workflow.Root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'External request/key write refused'}
            $full
        }
        function script:Invoke-TCNative {param($Path,$Arguments,$InputText)
            if((Get-TCFullPath $Path) -ine $script:Workflow.Wg -or $Arguments.Count -ne 1 -or $Arguments[0] -cnotin @('genkey','pubkey')){$script:Workflow.ForbiddenCalls++;throw 'Only fixture wg key generation/derivation allowed'}
            $value=& $script:WorkflowNative $Path $Arguments $InputText
            if($Arguments[0] -ceq 'genkey'){$script:WorkflowSecrets.Add($value.Trim())}
            $value
        }
        function script:Write-TCText {param($Path,$Text,[switch]$NewOnly)
            $full=Assert-WorkflowSetupPath $Path;$script:Workflow.Writes.Add($full);& $script:WorkflowText $full $Text -NewOnly:$NewOnly
        }
        function script:Write-TCJson {param($Path,$Value,[switch]$NewOnly)
            $full=Assert-WorkflowSetupPath $Path;$script:Workflow.Writes.Add($full);& $script:WorkflowJson $full $Value -NewOnly:$NewOnly
        }
        function script:New-TCPrivateDirectory {param($Path)$full=Assert-WorkflowSetupPath $Path;& $script:WorkflowDirectory $full}
    } $state $secrets
    $state.UiModule=New-Module -Name JourneyProductionUI -ArgumentList $PackageRoot -ScriptBlock {
        param($Package)
        $script:PackageRoot=$Package
        . (Join-Path $Package 'ui/ConnectionProfilePages.ps1')
        . (Join-Path $Package 'ui/DeploymentPages.ps1')
    }
}
function JourneyDto {param($Run)
    & $state.UiModule {param($r)
        $script:DeployUI.Run=$r;$line=DeploymentLineView $r;$view=LineRecommendationView $line;$decision=ProfileDeploymentDecision $line $r
        [pscustomobject]@{LineId=$line.LineId;CanConnect=$view.CanConnect;ProfileId=$view.ProfileId;Source=$view.Source;SelectionMode=$view.SelectionMode;RecommendationCurrent=$view.RecommendationCurrent;SavedDigest=(ProfileUIField $view.SavedConnectionPreference Digest);DecisionCode=$decision.Code;PrimaryAction=$decision.PrimaryAction;Blocked=$decision.Blocked;ManifestPaths=@($line.Profiles|ForEach-Object ManifestPath)}
    } $Run
}
function JourneyResponse {param($Run,[string]$HostAddress='192.0.2.80',$ServerInfo=$null)
    if($ServerInfo){$public=$ServerInfo.Node.ServerPublicKey;$node=$ServerInfo.Node.NodeId}
    else{$private=NewKey;$secrets.Add($private);$publicResult=& $modules.Nodes {param($e,$k)Invoke-TCNative -FilePath $e -ArgumentList @('pubkey') -InputText $k} $wg $private;$public=$publicResult.StandardOutput.Trim();$node=[guid]::NewGuid().ToString('D')}
    $subnet=if($Run.TunnelSubnet){$Run.TunnelSubnet}else{'10.78.0.0/24'};$prefix=$subnet -replace '\.0/24$',''
    [pscustomobject]@{SchemaVersion=1;Kind='TradeChannel.ClientResponse';Status='Authorized';RequestId=$Run.ClientRequest.RequestId;DeviceId=$Run.ClientRequest.DeviceId;NodeId=$node;NodeName='Offline journey';ClientPublicKey=$Run.ClientRequest.ClientPublicKey;ClientAddress=($prefix+'.2/32');ServerPublicKey=$public;PublicEndpoint=($HostAddress+':51820');TunnelSubnet=$subnet;ServerAddress=($prefix+'.1/24');AllowedIPs=@('0.0.0.0/0');PersistentKeepalive=25;AddressFamilies=@('IPv4');ConfigRevision=1}
}
function JourneyServerInfo {param($Response,[string]$Owner,[switch]$Management)
    [pscustomobject]@{RemoteOwnerId=$Owner;Node=(JourneyNode $Response);ManagementSigningPublicKey=$(if($Management){$state.ManagementJwk}else{$null});OwnershipState='Applied';ManagementApiVersion=2}
}
function JourneyNode {param($Response)
    [pscustomobject]@{NodeId=$Response.NodeId;Name='Offline journey';NodeName='Offline journey';Platform='Linux';PublicEndpoint=$Response.PublicEndpoint;TunnelSubnet=(Field $Response TunnelSubnet '10.78.0.0/24');ServerAddress=(Field $Response ServerAddress '10.78.0.1/24');ServerPublicKey=$Response.ServerPublicKey;ConfigRevision=(Field $Response ConfigRevision 1);DeviceCount=1}
}
function JourneyRequestStatus {param($Run,$Response)
    # The backend uses this LF-separated v1 tuple, not a generic JSON digest.
    $tuple=@(foreach($name in @('SchemaVersion','Kind','RequestId','DeviceId','CreatedAtUtc','ClientPublicKey')){[string](Field $Run.ClientRequest $name)})
    $digest=(TextHash (($tuple -join "`n")+"`nIPv4")).ToLowerInvariant()
    [pscustomobject]@{Status='Authorized';RequestId=$Response.RequestId;DeviceId=$Response.DeviceId;ClientPublicKey=$Response.ClientPublicKey;RequestDigest=$digest;Node=(JourneyNode $Response);ClientResponse=$Response}
}
function JourneyRecoveryGuard {param($Run,$Status)
    $proof=Field $Run OriginalRequestRecovery;$mutation=Field $Run LastRemoteMutation;$node=Field $Run.ServerInfo Node;$statusNode=Field $Status Node
    $sessionDigest=& $modules.Store {param($value)Get-TCDDigest $value} $Run.SessionRef
    $responseDigest=& $modules.Store {param($value)Get-TCDDigest $value} $Run.ClientResponse
    $bits=[ordered]@{
        RecoveryRequired=[bool]$Run.RecoveryRequired;ProofPresent=[bool]$proof;ProofState=(Field $proof State '')
        LastMutationOperation=(Field $mutation Operation '');ProofOperation=(Field $proof Operation '')
        LastMutationIntentId=(Field $mutation IntentId '');ProofIntentId=(Field $proof IntentId '')
        AllowedOriginalMutation=((Field $mutation Operation '') -in @('apply','authorize'))
        IntentEqual=((Field $mutation IntentId '') -ceq (Field $proof IntentId ''))
        OperationEqual=((Field $mutation Operation '') -ceq (Field $proof Operation ''))
        ServerRecordEqual=($Run.ServerRecordId -ceq (Field $proof ServerRecordId ''))
        SessionDigestEqual=($sessionDigest -ceq (Field $proof SessionDigest ''))
        RequestIdEqual=($Run.ClientRequest.RequestId -ceq (Field $proof RequestId ''))
        DeviceIdEqual=($Run.ClientRequest.DeviceId -ceq (Field $proof DeviceId ''))
        PublicKeyEqual=($Run.ClientRequest.ClientPublicKey -ceq (Field $proof ClientPublicKey ''))
        ResponseDigestEqual=($responseDigest -ceq (Field $proof ClientResponseDigest ''))
        OwnerPresent=[bool](Field $Run.ServerInfo RemoteOwnerId)
        ResponseNodeEqual=((Field $Run.ClientResponse NodeId '') -ceq (Field $node NodeId ''))
        ResponsePublicKeyEqual=((Field $Run.ClientResponse ServerPublicKey '') -ceq (Field $node ServerPublicKey ''))
        Status=(Field $Status Status '');StatusNodePresent=[bool]$statusNode
        StatusNodeEqual=((Field $statusNode NodeId '') -ceq (Field $node NodeId ''))
        StatusPublicKeyEqual=((Field $statusNode ServerPublicKey '') -ceq (Field $node ServerPublicKey ''))
        NoUnresolvedTcp=(-not [bool]$Run.UnresolvedTcpMutation);NoProbeRecovery=(-not [bool]$Run.ProbeRecoveryRequired)
    }
    [pscustomobject]$bits
}
function JourneyTransportInfo {param($Run)
    [pscustomobject]@{Kind='TradeChannel.TransportInfo';Status='Available';NodeId=$Run.ClientResponse.NodeId;RemoteOwnerId=$Run.ServerInfo.RemoteOwnerId;ServerPublicKey=$Run.ClientResponse.ServerPublicKey;ClientPublicKey=$Run.ClientResponse.ClientPublicKey;ClientAddress=$Run.ClientResponse.ClientAddress;Transport=[pscustomobject]@{Type='tcp-reality';Server=$Run.ClientResponse.PublicEndpoint.Split(':')[0];Port=8443;ServerName='www.bing.com';Uuid='aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';RealityPublicKey=('A'*43);RealityShortId='1234567890abcdef'}}
}
function JourneyUdpState {param($Run)
    [pscustomobject]@{Kind='TradeChannel.DeploymentState';Status='Settled';NodeId=$Run.ClientResponse.NodeId;RemoteOwnerId=$Run.ServerInfo.RemoteOwnerId;ServerPublicKey=$Run.ClientResponse.ServerPublicKey;ClientPublicKey=$Run.ClientResponse.ClientPublicKey;Transaction=$null;Udp=[pscustomobject]@{Status='Healthy';ClientAddress=$Run.ClientResponse.ClientAddress;ClientResponse=$Run.ClientResponse}}
}
function InvokeOneJourney {param([string]$Slot,[ValidateSet('','apply','authorize')][string]$Lost='',
    [ValidateSet('','RetainedReply','CancelGeneric','RequestIdMismatch','DeviceIdMismatch','PublicKeyMismatch','MissingReply','OtherMutation','ChangedSession','ProbeRecovery','TcpRecovery','StatusNodeMismatch','StatusPublicKeyMismatch')][string]$Fault='')
    BeginCase $Slot;SetSnapshot
    $root=Join-Path $work $Slot;PrivateDirectory $root;$state.ActiveRoot=$root
    $program=Join-Path $root 'NinjaTrader.exe';$null=AssertFixturePath $program;[IO.File]::WriteAllText($program,'inert fixture, never executable')
    $preservedCandidate=Join-Path $root 'preserved-candidate.json';WriteFixture $preservedCandidate @{endpoints=@();FixtureOnly=$true}
    $preservedManifest=Join-Path $root 'preserved-manifest.json';WriteFixture $preservedManifest @{Providers=@();EnginePath=$engine;CandidatePath=$preservedCandidate;FixtureOnly=$true}
    foreach($leaf in @('runtime.json','deployment.json','ui-preferences.json')){WriteFixture (Join-Path $root $leaf) @{State='Stopped';FixtureOnly=$true;NodeId=$null;ManifestPath=$preservedManifest}}
    $protected=@($program,$preservedManifest,$preservedCandidate,(Join-Path $root 'runtime.json'),(Join-Path $root 'deployment.json'),(Join-Path $root 'ui-preferences.json'));$before=SnapshotFiles $protected
    $inspection=@{EngineStaged=$true;WgHelperStaged=$true;ExistingDeployment=$false;NinjaTraderPaths=@($program);DirectDnsIPv4=@('192.0.2.53')}
    $connection=@{Host='192.0.2.80';Port=22;User='root';IdentityFile=''};$owner=[guid]::NewGuid().ToString('D');$originalInfo=$null
    if($Lost -eq 'authorize'){
        $private=NewKey;$secrets.Add($private);$pk=& $modules.Nodes {param($e,$k)Invoke-TCNative -FilePath $e -ArgumentList @('pubkey') -InputText $k} $wg $private
        $seed=@{NodeId=[guid]::NewGuid().ToString('D');ServerPublicKey=$pk.StandardOutput.Trim();PublicEndpoint='192.0.2.80:51820'}
        $originalInfo=JourneyServerInfo $seed $owner -Management
        $server=Set-TCServerRecord -Root $root -Connection $connection -ServerInfo $originalInfo -Name 'Existing fixture server'
        $inspection.ExistingDeployment=$true
        $run=New-TCDeploymentRun -Root $root -Intent Auto -ServerId $server.LocalRecordId -Name $Slot -ClientInspection $inspection
    }else{$run=New-TCDeploymentRun -Root $root -Intent Auto -Connection $connection -Name $Slot -ClientInspection $inspection}
    $state.ActiveRunId=$run.RunId;$dispatchStart=$state.Dispatches.Count;$session=NewJourneySession $run $root
    SetJourneyPoll $run $session Failed $null AuthenticationFailed
    $run=Set-TCDeploymentAccessState -Root $root -RunId $run.RunId -SessionRef $session -AttemptOnly
    $run=Set-TCDeploymentAccessState -Root $root -RunId $run.RunId -SessionRef $session
    Check ($run.AccessIssue.Kind -ceq 'Credentials' -and (Get-TCDeploymentRun $root $run.RunId).AccessIssue.Code -ceq 'AuthenticationFailed' -and -not $run.RequestDirectory) 'real intake/access state preserves the preparation identity before any enrollment'
    SetJourneyPoll $run $session Ready $null Authenticated
    $run=Set-TCDeploymentSession -Root $root -RunId $run.RunId -SessionRef $session
    $run=Invoke-TCDeploymentAdvance -Root $root -RunId $run.RunId
    $run=FinishJourney $run @{Supported=$true;AlreadyDeployed=($Lost -eq 'authorize');OwnedDeployment=($Lost -eq 'authorize');ConflictNetworks=@()} Inspect
    if($Lost -eq 'authorize'){$run=FinishJourney $run $originalInfo ServerInfo}
    else{$run=FinishJourney $run @{PlanId=[guid]::NewGuid().ToString('D');PlanExpiresAt=[DateTimeOffset]::UtcNow.AddHours(1).ToString('o')} Plan}
    Check ($run.Stage -ceq 'PlanReady' -and $run.Review.DualPreparationRequired -and $run.Review.OptionalTcpPreparation) 'real plan review binds the target and both protocols before one approval'
    $requestId=$run.ClientRequest.RequestId;$deviceId=$run.ClientRequest.DeviceId;$keyPath=Join-Path $run.RequestDirectory 'client.key';$keyHash=Hash $keyPath
    $secrets.Add([IO.File]::ReadAllText($keyPath).Trim());$response=JourneyResponse $run $connection.Host $originalInfo
    $info=JourneyServerInfo $response $owner -Management
    $state.LostOperation=$Lost;$approvalCount=1;$approvalDigest=$run.Review.ChangeDigest;$lostRejected=$false
    try{$run=Invoke-TCDeploymentAdvance -Root $root -RunId $run.RunId -Command Approve -ApprovedChangeDigest $approvalDigest}catch{
        if(-not $Lost -or -not $_.Exception.Message.StartsWith('[TC:DispatchOutcomeUnknown]')){throw};$lostRejected=$true;$run=Get-TCDeploymentRun $root $run.RunId
    }
    if($Lost){
        $mutationId=$run.PendingOperationId
        Check ($lostRejected -and $run.Status -ceq 'OutcomeUnknown' -and $run.DispatchIntent.Operation -ceq $Lost -and $run.DispatchIntent.IntentId -ceq $mutationId) 'accepted lost reply retains the actual original mutation ID and never invents rollback'
        if($Fault -eq 'CancelGeneric'){
            $run=Invoke-TCDeploymentAdvance -Root $root -RunId $run.RunId -Command Cancel
            Check ($run.Status -ceq 'OutcomeUnknown' -and $run.Stage -ceq 'Reconcile' -and -not $run.UnresolvedTcpMutation -and $run.StopTransaction.State -ceq 'StopRequested' -and $run.StopTransaction.DispatchIntent.Operation -ceq $Lost -and $run.StopTransaction.DispatchIntent.IntentId -ceq $mutationId) 'generic cancellation preserves the original unknown mutation without inventing a TCP recovery obligation'
            Check ((Hash $keyPath) -ceq $keyHash -and -not $run.NetworkChanged) 'generic cancellation preserves the original private key and current fixture network'
        }
        if($Fault -eq 'RetainedReply'){$run.ClientResponse=Clone $response;$run=& $modules.Flow {param($root,$r)Save-TCDeploymentRun $root $r} $root $run}
        $session=NewJourneySession $run $root;SetJourneyPoll $run $session Ready $null Authenticated
        $run=Set-TCDeploymentSession -Root $root -RunId $run.RunId -SessionRef $session
        Check ($run.Stage -ceq 'Reconcile' -and $run.RecoveryRequired) 'real reauthentication resumes reconciliation of the lost mutation'
        $continuation=$null
        if($Fault -eq 'RetainedReply'){
            $continuation=[pscustomobject]@{Name=$Slot;Root=$root;RunId=$run.RunId;BeforeStage=$run.Stage;BeforeStatus=$run.Status;BeforeLastMutationOperation=$run.LastRemoteMutation.Operation;BeforeLastMutationIntentId=$run.LastRemoteMutation.IntentId;BeforeLastMutationState=$run.LastRemoteMutation.State;BeforeDispatchOperation=$run.DispatchIntent.Operation;BeforeDispatchIntentId=$run.DispatchIntent.IntentId;BeforeDispatchState=$run.DispatchIntent.State;SameOperation=($run.LastRemoteMutation.Operation -ceq $run.DispatchIntent.Operation);SameIntent=($run.LastRemoteMutation.IntentId -ceq $run.DispatchIntent.IntentId);CachedRequestMatches=($run.ClientResponse.RequestId -ceq $run.ClientRequest.RequestId);CandidateNodeId=$run.CandidateNodeId;TcpLocalPreparation=$run.ProtocolPreparation.Tcp.LocalPreparation;AfterStage=$null;AfterPurpose=$null;AfterLastMutation=$null;AfterUnresolvedTcpOperation=$null}
            $state.CachedContinuations.Add($continuation)
        }
        $run=Invoke-TCDeploymentAdvance -Root $root -RunId $run.RunId
        if($continuation){$continuation.AfterStage=$run.Stage;$continuation.AfterPurpose=$run.PendingPurpose;$continuation.AfterLastMutation=$run.LastRemoteMutation.Operation;$continuation.AfterUnresolvedTcpOperation=(Field $run.UnresolvedTcpMutation Operation '')}
        $run=FinishJourney $run @{Status='Applied';Node=(JourneyNode $response)} Reconcile
        Check ($run.PendingPurpose -ceq 'RequestStatus' -and $state.Dispatches[-1].Input.RequestId -ceq $requestId) 'real reconciliation queries only the original public request ID'
        $reply=JourneyRequestStatus $run (Clone $response)
        switch($Fault){
            RequestIdMismatch {$reply.ClientResponse.RequestId=[guid]::NewGuid().ToString('D')}
            DeviceIdMismatch {$reply.ClientResponse.DeviceId=[guid]::NewGuid().ToString('D')}
            PublicKeyMismatch {$reply.ClientResponse.ClientPublicKey=$response.ServerPublicKey}
            MissingReply {$reply=[pscustomobject]@{Status='NotFound';RequestId=$requestId}}
        }
        $run=FinishJourney $run $reply RequestStatus
        if($Fault -in @('RequestIdMismatch','DeviceIdMismatch','PublicKeyMismatch','MissingReply')){
            $code=if($Fault -eq 'MissingReply'){'OriginalRequestNotResolved'}else{'RequestReconciliationMismatch'}
            Check ($run.RecoveryRequired -and $run.LastError.Code -ceq $code -and $run.Status -notin @('Complete','Running','Dispatching') -and -not $run.CandidateNodeId -and -not $run.AutoSavedAtUtc -and -not (Field $run OriginalRequestRecovery)) ($Fault+' cannot resolve the original authorization or enter candidate preparation')
            Check ((Hash $keyPath) -ceq $keyHash -and $run.ClientRequest.RequestId -ceq $requestId -and @($state.Dispatches | Where-Object {$_.RunId -ceq $run.RunId -and $_.Operation -in @('apply','authorize')}).Count -eq 1 -and (SnapshotFiles $protected) -ceq $before) ($Fault+' preserves original private identity and never blindly reauthorizes')
            $state.RecoveryNegatives.Add([pscustomobject]@{Name=$Fault;Passed=$true;Stage=$run.Stage;Status=$run.Status;RecoveryRequired=$run.RecoveryRequired;Code=$run.LastError.Code;OriginalMutationCount=1;Guard=$null})
            return
        }
        if($Fault -eq 'OtherMutation'){
            # A later accepted management operation creates a different REAL durable
            # dispatch intent. The old authorized-reply proof cannot resolve it.
            $run=& $modules.Flow {param($root,$r)Start-TCDeploymentRemote $root $r management_apply ManagementApply @{PlanId=[guid]::NewGuid().ToString('D');ApprovedChangeDigest=('D'*64)};Save-TCDeploymentRun $root $r} $root $run
            $run=FinishJourney $run @{Status='Applied'} ManagementApply
        }elseif($Fault -eq 'ChangedSession'){
            $newSession=NewJourneySession $run $root;SetJourneyPoll $run $newSession Ready $null Authenticated
            $run=Set-TCDeploymentSession -Root $root -RunId $run.RunId -SessionRef $newSession
            # Re-read authenticated application identity without reissuing the
            # original request query. This deliberately leaves the OLD proof stale.
            $run=& $modules.Flow {param($root,$r)Start-TCDeploymentRemote $root $r server_info ServerInfo @{};Save-TCDeploymentRun $root $r} $root $run
        }elseif($Fault -in @('ProbeRecovery','TcpRecovery')){
            if($Fault -eq 'ProbeRecovery'){$run.ProbeRecoveryRequired=$true}
            else{$run.UnresolvedTcpMutation=[pscustomobject]@{IntentId=[guid]::NewGuid().ToString('D');Operation='transport_apply';State='Prepared';Mutating=$true}}
            $run=& $modules.Flow {param($root,$r)Save-TCDeploymentRun $root $r} $root $run
        }
        $run=FinishJourney $run $info ServerInfo
    }elseif($Lost -ne 'authorize'){
        $run=FinishJourney $run @{ClientResponse=$response} Apply
        $withoutManagement=JourneyServerInfo $response $owner
        $run=FinishJourney $run $withoutManagement ServerInfo
        $run=FinishJourney $run @{PlanId=[guid]::NewGuid().ToString('D');ChangeDigest=('D'*64)} ManagementPlan
        $run=FinishJourney $run @{Status='Applied'} ManagementApply
        $run=FinishJourney $run $info ServerInfo
        Check ($run.PendingPurpose -ceq 'ServerExit' -and $run.AllowManagementInitialize -and $run.AllowDeviceAuthorize) 'one approved scope automatically initializes management then verifies the original authorization'
    }
    $server=Get-TCServer $root $run.ServerRecordId
    Check ($server.ManagementAccessState -ceq 'Authenticated' -and $server.HostTrustState -ceq 'Verified' -and $server.NodeId -ceq $response.NodeId -and $state.EvidenceReads -gt 0) 'bound authenticated executor server_info passes real transport/registry identity policy'
    $statusReply=[pscustomobject]@{Status='Applied';Node=(JourneyNode $response);NetworkProbe=@{ServerHttps=@(@{ExitEvidence='VerifiedTlsTrace';ObservedExitIPv4='192.0.2.40'})}}
    if($Fault -eq 'StatusNodeMismatch'){$statusReply.Node.NodeId=[guid]::NewGuid().ToString('D')}
    if($Fault -eq 'StatusPublicKeyMismatch'){$statusReply.Node.ServerPublicKey=$response.ClientPublicKey}
    $guard=JourneyRecoveryGuard $run $statusReply
    $run=FinishJourney $run $statusReply ServerExit
    if($Fault -in @('OtherMutation','ChangedSession','ProbeRecovery','TcpRecovery','StatusNodeMismatch','StatusPublicKeyMismatch')){
        $reason=switch($Fault){OtherMutation {-not $guard.IntentEqual -and -not $guard.OperationEqual}ChangedSession {-not $guard.SessionDigestEqual}ProbeRecovery {-not $guard.NoProbeRecovery}TcpRecovery {-not $guard.NoUnresolvedTcp}StatusNodeMismatch {-not $guard.StatusNodeEqual}StatusPublicKeyMismatch {-not $guard.StatusPublicKeyEqual}}
        Check ($reason -and $run.RecoveryRequired -and (Field (Field $run OriginalRequestRecovery) State '') -ceq 'AuthorizedReplyRead' -and $run.Status -ne 'Complete' -and -not $run.AutoSavedAtUtc) ($Fault+' leaves generic recovery unresolved despite a real bound server_info and healthy status Node')
        $healthyNode=($guard.StatusNodePresent -and ($guard.StatusNodeEqual -or $Fault -eq 'StatusNodeMismatch') -and ($guard.StatusPublicKeyEqual -or $Fault -eq 'StatusPublicKeyMismatch'))
        Check ($healthyNode -and (Hash $keyPath) -ceq $keyHash -and @($state.Dispatches | Where-Object {$_.RunId -ceq $run.RunId -and $_.Operation -in @('apply','authorize')}).Count -eq 1 -and (SnapshotFiles $protected) -ceq $before -and -not $run.NetworkChanged) ($Fault+' rejection comes from the required binding and preserves the original enrollment/network')
        $state.RecoveryNegatives.Add([pscustomobject]@{Name=$Fault;Passed=$true;Stage=$run.Stage;Status=$run.Status;RecoveryRequired=$run.RecoveryRequired;Code=(Field $run.LastError Code);OriginalMutationCount=1;Guard=$guard})
        return
    }
    $notConfigured=JourneyTransportInfo $run;$notConfigured.Status='NotConfigured';$notConfigured.Transport=$null
    $run=FinishJourney $run $notConfigured InspectTcp
    $run=FinishJourney $run @{Status='Selected';Port=8443;SelectedServerName='www.bing.com';HandshakeValidation='TlsEndpointReachable';HandshakeChecks=@(@{ServerName='www.bing.com';Status='TlsEndpointReachable';ErrorCode=$null});Candidates=@(@{Port=443;Busy=$true},@{Port=8443;Busy=$false})} TcpCandidates
    $run=FinishJourney $run @{NodeId=$response.NodeId;RemoteOwnerId=$owner;ServerPublicKey=$response.ServerPublicKey;PlanId=[guid]::NewGuid().ToString('D');ChangeDigest=('D'*64);Transport=@{Type='tcp-reality';Port=8443;ServerName='www.bing.com'}} TcpPlan
    $run=FinishJourney $run @{Status='Applied'} TcpApply
    $run=FinishJourney $run (JourneyTransportInfo $run) TcpParameters
    $line=Get-TCLine -Root $root -Id $run.CandidateNodeId;$dispatches=@($state.Dispatches | Select-Object -Skip $dispatchStart)
    Check ($run.ClientRequest.RequestId -ceq $requestId -and $run.ClientRequest.DeviceId -ceq $deviceId -and (Hash $keyPath) -ceq $keyHash -and @(Get-TCNodes (Join-Path $root 'Product')).Count -eq 1 -and @($dispatches | Where-Object Operation -ceq $(if($Lost -eq 'authorize'){'authorize'}else{'apply'})).Count -eq 1) 'full pipeline retains one original enrollment/key and accepts each original mutation exactly once'
    Check ($line.Profiles.Count -eq 2 -and @($line.Profiles | Where-Object PreparationState -cne 'SyntaxValidated').Count -eq 0 -and (SnapshotFiles $protected) -ceq $before -and -not $run.NetworkChanged) 'actual UDP/TCP generation preserves unrelated fixture channel/preferences and makes no activation'
    RecordCase $run ([pscustomobject]@{Node=[pscustomobject]@{id=$line.LineId}})
    $dto=JourneyDto $run
    $row=[pscustomobject]@{Name=$Slot;Root=$root;RunId=$run.RunId;LostOperation=$Lost;ApprovalCount=$approvalCount;DispatchCount=$dispatches.Count;Stage=$run.Stage;Status=$run.Status;RecoveryRequired=$run.RecoveryRequired;ProfileProbeState=$run.ProfileProbeState;AttentionRequired=$run.AttentionRequired;RecommendationStatus=(Field $run.Recommendation Status);CandidateNodeId=$run.CandidateNodeId;RequestId=$requestId;DeviceId=$deviceId;RecoveryGuardBeforeServerExit=$guard;RecoveryProofAfter=(Field (Field $run OriginalRequestRecovery) State '');UiDto=$dto;Passed=$false}
    $state.Journeys.Add($row)
    Check ($run.Stage -ceq 'ReadyInactive' -and $run.Status -ceq 'Complete' -and $run.AutoSavedAtUtc -and -not $run.RecoveryRequired -and -not $run.AttentionRequired -and $run.ProfileProbeState -ceq 'Completed') ('original '+$(if($Lost){$Lost+' lost result'}else{'approved request'})+' reaches normal automatically saved readiness after authenticated identity and health checks')
    $saved=$line.SavedConnectionPreference;$p=Get-TCLineProfile -Root $root -Id $line.LineId -ProfileId $saved.ProfileId;$manifest=ReadJson $p.ManifestPath
    Check ($saved.ProfileId -ceq 'Tcp' -and $saved.Source -ceq 'Performance' -and $saved.Provenance.Kind -ceq 'Recommendation' -and $saved.Binding.CandidateSHA256 -ceq $p.CandidateSHA256 -and $saved.Binding.ManifestSHA256 -ceq (Hash $p.ManifestPath) -and (Test-TCSavedConnectionPreference -Preference $saved -LineId $line.LineId -Profile $p -Manifest $manifest)) 'actual LineStore saved-default producer validates config hashes and original comparison provenance'
    $default=Get-TCLineDefaultProfile -Root $root -Id $line.LineId
    Check ($dto.CanConnect -and $dto.ProfileId -ceq $default.ProfileId -and $dto.Source -ceq $default.Source -and $dto.SelectionMode -ceq 'SavedDefault' -and $dto.SavedDigest -ceq $saved.Digest -and @($dto.ManifestPaths | Where-Object {-not [IO.File]::Exists($_)}).Count -eq 0) 'production completed-run projection and UI consumer use the same saved default and real manifests'
    $row.Passed=$true
    Check ($approvalCount -eq 1 -and @($dispatches | Where-Object Operation -ceq 'transport_apply').Count -eq 1 -and $run.ApprovedChangeDigest -ceq $approvalDigest -and @($dispatches | Where-Object {$_.InstanceId -cne $run.SessionRef.InstanceId -and -not $Lost}).Count -eq 0) 'real incremental TCP options/plan/apply remain inside the single original approval and authenticated session'
    [pscustomobject]@{Root=$root;Run=$run;Line=$line;Protected=$protected;Before=$before;RequestId=$requestId;KeyHash=$keyHash;KeyPath=$keyPath;SavedDigest=$saved.Digest}
}
function InvokeJourneyMatrix {
    $state.Contracts=[ordered]@{AutoIntake=$true;AccessState=[bool](Get-Command Set-TCDeploymentAccessState -ErrorAction SilentlyContinue);SavedDefaultProducer=[bool](Get-Command New-TCSavedConnectionPreference -ErrorAction SilentlyContinue)}
    if($JourneyCase -ne 'All'){
        if($JourneyCase -eq 'RetainedReply'){$null=InvokeOneJourney 'LostResult-retained-reply' apply RetainedReply}
        else{$lost=if($JourneyCase -eq 'ApplyRecovery'){'apply'}else{'authorize'};$null=InvokeOneJourney ('LostResult-'+$lost) $lost}
        return
    }
    $main=InvokeOneJourney 'ApprovedCreateManageCompare'
    BeginCase 'SavedDefaultAfterRecheck' 'FastUdp';SetSnapshot;$state.ActiveRoot=$main.Root;$state.ActiveRunId=$main.Run.RunId
    $again=Invoke-TCDeploymentAdvance -Root $main.Root -RunId $main.Run.RunId -Command Probe;$line=Get-TCLine -Root $main.Root -Id $again.CandidateNodeId;$dto=JourneyDto $again
    Check ($again.RecommendedProfileId -ceq 'Udp' -and $line.SavedConnectionPreference.Digest -ceq $main.SavedDigest -and $line.SavedConnectionPreference.ProfileId -ceq 'Tcp' -and $dto.ProfileId -ceq 'Tcp' -and $dto.CanConnect) 'new UDP comparison updates only the short term recommendation; real saved TCP default and UI agree'
    BeginCase 'AutoExistingUniqueLine';$state.ActiveRoot=$main.Root
    $beforeEnrollment=@(Get-ChildItem -LiteralPath $main.Root -Recurse -File -Filter 'client.key').Count;$beforeNodes=@(Get-TCNodes (Join-Path $main.Root 'Product')).Count;$beforeDispatch=$state.Dispatches.Count
    WriteFixture (Join-Path $main.Root 'ui-preferences.json') @{NodeId=$main.Line.LineId;FixtureOnly=$true}
    $reused=New-TCDeploymentRun -Root $main.Root -Intent Auto -ServerId $main.Run.ServerRecordId -ClientInspection @{EngineStaged=$true;WgHelperStaged=$true;ExistingDeployment=$true;NinjaTraderPaths=@();DirectDnsIPv4=@('192.0.2.53')}
    Check ($reused.Intent -ceq 'Existing' -and $reused.CandidateNodeId -ceq $main.Line.LineId -and -not $reused.RequestDirectory -and $reused.ClientRequest.ClientPublicKey -ceq $main.Run.ClientRequest.ClientPublicKey) 'real Auto intake selects the unique linked original line using actual manifest key/hash and UI preference'
    $state.ActiveRunId=$reused.RunId;$session=NewJourneySession $reused $main.Root;SetJourneyPoll $reused $session Ready $null Authenticated;$reused=Set-TCDeploymentSession -Root $main.Root -RunId $reused.RunId -SessionRef $session
    $reused=Invoke-TCDeploymentAdvance -Root $main.Root -RunId $reused.RunId
    $reused=FinishJourney $reused @{Supported=$true;AlreadyDeployed=$true;OwnedDeployment=$true;ConflictNetworks=@()} Inspect
    $reused=FinishJourney $reused $main.Run.ServerInfo ServerInfo
    $reused=FinishJourney $reused (JourneyUdpState $main.Run) ExistingUdp
    $reused=Invoke-TCDeploymentAdvance -Root $main.Root -RunId $reused.RunId -Command Approve -ApprovedChangeDigest $reused.Review.ChangeDigest
    $reused=FinishJourney $reused (JourneyTransportInfo $reused) InspectTcp
    Check ($reused.Status -ceq 'Complete' -and $reused.CandidateNodeId -ceq $main.Line.LineId -and $reused.ClientRequest.DeviceId -ceq $main.Run.ClientRequest.DeviceId -and @(Get-ChildItem -LiteralPath $main.Root -Recurse -File -Filter 'client.key').Count -eq $beforeEnrollment -and @(Get-TCNodes (Join-Path $main.Root 'Product')).Count -eq $beforeNodes -and @($state.Dispatches | Select-Object -Skip $beforeDispatch | Where-Object {$_.Operation -in @('apply','authorize','transport_apply')}).Count -eq 0) 'full Auto maintenance pipeline performs no duplicate enrollment or server mutation'
    BeginCase 'FailedRecheckAttention' 'AllHttpFailed';SetSnapshot;$state.ActiveRunId=$main.Run.RunId
    $failed=Invoke-TCDeploymentAdvance -Root $main.Root -RunId $main.Run.RunId -Command Probe;$line=Get-TCLine -Root $main.Root -Id $failed.CandidateNodeId;$dto=JourneyDto $failed;$default=Get-TCLineDefaultProfile -Root $main.Root -Id $line.LineId
    Check ($failed.Status -ceq 'Complete' -and $failed.DeploymentCompleteness -ceq 'Complete' -and $failed.AutoSavedAtUtc -and $failed.AttentionRequired -and -not $failed.RecommendedProfileId -and $line.SavedConnectionPreference.Digest -ceq $main.SavedDigest -and -not $dto.CanConnect -and -not $default.ProfileId -and $default.RequiresCheck) 'failed real samples autosave prepared configs with attention and block consumption without replacing saved provenance'
    foreach($lost in @('apply','authorize')){
        try{$null=InvokeOneJourney ('LostResult-'+$lost) $lost}catch{
            $row=@($state.Journeys | Where-Object Name -ceq ('LostResult-'+$lost))|Select-Object -Last 1
            $state.Findings.Add([pscustomobject]@{Case=('LostResult-'+$lost);Assertion=$script:LastAssertion;Error=([regex]::Replace($_.Exception.Message,'[A-Za-z0-9+/]{43}=','[redacted-key]'));Stage=(Field $row Stage);Status=(Field $row Status);RecoveryRequired=(Field $row RecoveryRequired);ProductionFile='DeploymentFlow.psm1';Area='Reconcile -> RequestStatus -> ServerInfo -> ServerExit';RequiredFix='Resolve only the original apply/authorize dispatch after request_status returns the same original RequestId/DeviceId/ClientPublicKey, bound authenticated server_info matches owner/node/key, and status verifies UDP health. Then clear that generic recovery obligation before profile preparation; retain UnresolvedTcpMutation and ProbeRecoveryRequired barriers.'})
            Note ('FAIL ['+$script:Case+'] '+$_.Exception.Message)
        }
    }
    foreach($fault in @('RetainedReply','CancelGeneric','RequestIdMismatch','DeviceIdMismatch','PublicKeyMismatch','MissingReply','OtherMutation','ChangedSession','ProbeRecovery','TcpRecovery','StatusNodeMismatch','StatusPublicKeyMismatch')){
        try{$null=InvokeOneJourney ('Recovery-'+$fault) apply $fault}catch{
            $state.Findings.Add([pscustomobject]@{Case=('Recovery-'+$fault);Assertion=$script:LastAssertion;Error=$_.Exception.Message;Stage=(Field $state.LatestRun Stage);Status=(Field $state.LatestRun Status);RecoveryRequired=(Field $state.LatestRun RecoveryRequired);PendingPurpose=(Field $state.LatestRun PendingPurpose);ProductionFile='DeploymentFlow.psm1';Area='Invoke-TCDeploymentAdvance reconciliation entry / RequestStatus / ServerExit';RequiredFix='Keep the original request and all session/node/operation/cleanup bindings; determine which real continuation branch or binding rejected the case.'})
            Note ('FAIL ['+$script:Case+'] '+$_.Exception.Message)
        }
    }
}
function InvokeNegativeJourneyContracts {
    BeginCase 'NegativeControl0143';SetSnapshot
    $f=NewFixture 'negative-contracts';$run=NewFixtureRun $f
    $before=$state.ForbiddenCalls;$access=Get-Command Set-TCDeploymentAccessState -ErrorAction SilentlyContinue
    $run.ProfileProbeState='Completed';$run=& $modules.Flow {param($root,$r)Save-TCDeploymentRun $root $r} $f.Root $run
    $autosave=($run.Status -ceq 'Complete' -and [bool](Field $run AutoSavedAtUtc))
    $result=ProbeRun $f $run;$line=Get-TCLine -Root $f.Root -Id $f.Node.id
    $saved=(Field $line SavedConnectionPreference);$producer=Get-Command New-TCSavedConnectionPreference -ErrorAction SilentlyContinue
    $state.Contracts=[ordered]@{AccessState=[bool]$access;AutomaticSave=[bool]$autosave;SavedDefaultProducer=[bool]$producer;SavedDefaultFromRealComparison=[bool]$saved;ComparisonActuallyRan=($state.HttpCount -eq 42 -and $result.RecommendedProfileId -ceq 'Tcp')}
    Check (-not $state.Contracts.AccessState -and -not $state.Contracts.AutomaticSave -and -not $state.Contracts.SavedDefaultProducer -and -not $state.Contracts.SavedDefaultFromRealComparison -and $state.Contracts.ComparisonActuallyRan -and $state.ForbiddenCalls -eq $before) '0.14.3 actual runtime lacks access/autosave/saved-default contracts despite a complete real comparison'
    RecordCase $result $f
}

try {
    $testSHA256=Hash $PSCommandPath
    Check ($PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -eq 1 -and $PSVersionTable.PSEdition -eq 'Desktop') 'Windows PowerShell 5.1 Desktop executes this test'
    $env:PSModulePath=Join-Path $PSHOME 'Modules'
    if(@($BarrierOnly,$CoreMatrixOnly,$JourneyOnly,$NegativeControl | Where-Object {$_}).Count -gt 1){throw 'Select one integration mode'}
    $sourceBefore=ReadSourceHashes
    if($CoreMatrixOnly) {
        $archive=Join-Path $reportDirectory 'probe-workflow-integration-full-before-run-null.json'
        if([IO.File]::Exists($archive)) {
            $old=ReadJson $archive
            $historicalFull=[ordered]@{Path=$archive;SHA256=(Hash $archive);Passed=$old.Passed;PassedCount=$old.PassedCount;ExecutedAtUtc=$old.ExecutedAtUtc;TestSHA256=$old.TestSHA256;VersionScope='Historical full run loaded modules before the final Advance/Sync local run initialization fix; not full coverage of current SourceSHA256.'}
        }
    }
    foreach($entry in @(@('Nodes','NodeStore'),@('Lines','LineStore'),@('Path','ProbePath'),@('Candidate','CandidateProbe'),@('Comparison','ProtocolComparison'),@('Selection','ProtocolSelection'),@('Store','DeploymentStore'),@('Registry','ServerRegistry'),@('Transport','DeploymentTransport'),@('Decision','DeploymentDecision'),@('Flow','DeploymentFlow'),@('Setup','ServerSetup'))) {
        $modules[$entry[0]]=Import-Module (Join-Path $PackageRoot ($entry[1]+'.psm1')) -PassThru -DisableNameChecking
    }
    $state.FlowModule=$modules.Flow
    foreach($pair in @(@('Comparison','Invoke-TCProtocolComparison'),@('Comparison','Prepare-TCProtocolComparisonBinding'),
        @('Flow','Test-TCDeploymentProfiles'),@('Flow','Invoke-TCDeploymentProtocolComparison'),@('Flow','Update-TCDeploymentProbeProgress'),
        @('Flow','Set-TCDeploymentSession'),@('Flow','Invoke-TCDeploymentAdvance'),@('Flow','Sync-TCDeploymentRun'),@('Registry','Open-TCServerTaskLease'),
        @('Lines','Prepare-TCLineProbeBindings'),@('Lines','Set-TCLineRecommendation'),@('Lines','Get-TCLineDefaultProfile'),@('Flow','Save-TCDeploymentRun'),@('Flow','Start-TCDeploymentRemote'),
        @('Registry','Set-TCServerRecord'),@('Transport','Get-TCDeployVerifiedServerInfo'),@('Transport','Assert-TCDeployLiveIdentity'),@('Transport','Assert-TCDeploySessionRef'),
        @('Path','Get-TCProbePathAssessment'),@('Selection','New-TCSavedConnectionPreference'),@('Selection','Test-TCSavedConnectionPreference'),@('Selection','ConvertTo-TCProtocolEvidence'),@('Selection','Get-TCProtocolRecommendation'))) {
        $definition=& $modules[$pair[0]] {param($n) $c=Get-Command $n -ErrorAction SilentlyContinue; if($c){$c.Definition}} $pair[1]
        if($definition){$originalCore[$pair[0]+':'+$pair[1]]=TextHash $definition}
    }
    # Transparent guards: valid calls still run the real implementation.
    & $modules.Nodes {
        param($s)
        $script:Workflow=$s
        $script:WorkflowNative=$script:TCNativeRunner
        $script:WorkflowWrite=${function:Write-TCAtomicJson}; $script:WorkflowDirectory=${function:New-TCPrivateDirectory}
        $script:WorkflowSession=${function:Open-TCNodeSessionLock}; $script:WorkflowLock=${function:Open-TCLock}
        function script:Assert-WorkflowPath {param($p)
            $full=Get-TCFullPath $p
            if(-not (Test-TCPathWithin $full $script:Workflow.Root) -and -not (Test-TCSamePath $full $script:Workflow.Root)){throw 'External fixture write or lock refused'}
            Assert-TCNoReparse $full
        }
        function script:Write-TCAtomicJson {param($Path,$Value,[switch]$NewOnly,[switch]$NoBom)
            Assert-WorkflowPath $Path; $script:Workflow.Writes.Add($Path)
            & $script:WorkflowWrite -Path $Path -Value $Value -NewOnly:$NewOnly -NoBom:$NoBom
        }
        function script:New-TCPrivateDirectory {param($Path) Assert-WorkflowPath $Path; & $script:WorkflowDirectory $Path}
        function script:Open-TCNodeSessionLock {param($StoreRoot) Assert-WorkflowPath $StoreRoot; & $script:WorkflowSession $StoreRoot}
        function script:Open-TCLock {param($Root) Assert-WorkflowPath $Root; & $script:WorkflowLock $Root}
        $script:TCNativeRunner={param($FilePath,$ArgumentList,$InputText,$TimeoutMilliseconds)
            $allowed=$false; $relative=$null
            if($ArgumentList.Count -eq 1 -and $ArgumentList[0] -ceq 'pubkey' -and (Test-TCSamePath $FilePath $script:Workflow.Wg)){$allowed=$true}
            elseif($ArgumentList.Count -eq 3 -and $ArgumentList[0] -ceq 'check' -and $ArgumentList[1] -ceq '-c' -and (Test-TCSamePath $FilePath $script:Workflow.Engine)){
                Assert-WorkflowPath $ArgumentList[2]; $allowed=$true
                $relative=[IO.Path]::GetFullPath($ArgumentList[2]).Substring($script:Workflow.Root.Length+1)
            }
            if(-not $allowed){$script:Workflow.ForbiddenCalls++; throw 'Only real fixture sing-box check and wg pubkey are allowed'}
            $r=& $script:WorkflowNative -FilePath $FilePath -ArgumentList $ArgumentList -InputText $InputText -TimeoutMilliseconds $TimeoutMilliseconds
            $script:Workflow.NativeCalls.Add([pscustomobject]@{Command=$ArgumentList[0];Config=$relative;ExitCode=$r.ExitCode})
            $r
        }
    } $state
    $nativeOriginal=& $modules.Nodes {$script:WorkflowNative}
    PrivateDirectory $work
    $acl=Get-Acl -LiteralPath $work
    $allowed=@('S-1-5-18','S-1-5-32-544',[Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
    $other=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]) | Where-Object {$_.AccessControlType -eq 'Allow' -and $_.IdentityReference.Value -notin $allowed})
    Check ($acl.AreAccessRulesProtected -and $other.Count -eq 0) 'single disposable root has a restricted, non-inherited ACL'
    foreach($storeCaller in @($modules.Store,$modules.Flow,$modules.Registry)) { & $storeCaller {
        param($s)
        $script:Workflow=$s; $script:WorkflowWrite=(Get-Command Write-TCDJson).ScriptBlock; $script:WorkflowLock=(Get-Command Open-TCDLock).ScriptBlock
        function script:Assert-WorkflowStorePath {param($p)
            $full=Assert-TCDPath $p
            if(-not $full.StartsWith($script:Workflow.Root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'External deployment write or lock refused'}
        }
        function script:Write-TCDJson {param($Path,$Value,[switch]$NewOnly)
            Assert-WorkflowStorePath $Path; $script:Workflow.Writes.Add($Path)
            if([IO.Path]::GetFileName($Path) -ceq 'state.json' -and $script:Workflow.ActiveRunId -and $Value.RunId -ceq $script:Workflow.ActiveRunId){
                $script:Workflow.Events.Add([pscustomobject]@{Type='DeploymentProgress';Stage=$Value.Stage;ProfileId=(Get-TCDField $Value CheckingProfileId);BindingState=(Get-TCDField (Get-TCDField $Value ProbePreparation) State);AttemptId=(Get-TCDField $Value ProbeAttemptId)})
            }
            & $script:WorkflowWrite -Path $Path -Value $Value -NewOnly:$NewOnly
        }
        function script:Open-TCDLock {param($Path,[int]$TimeoutMs=5000) Assert-WorkflowStorePath $Path; & $script:WorkflowLock -Path $Path -TimeoutMs $TimeoutMs}
    } $state }
    # Hard fences installed in the caller scopes: a future accidental startup
    # or network call fails rather than using the machine's live facilities.
    foreach($module in @($modules.Flow,$modules.Candidate,$modules.Comparison,$modules.Path)) {
        & $module {param($s)
            $script:Workflow=$s
            function script:Start-TCBoundedEngineProcess {$script:Workflow.ForbiddenCalls++; throw 'Real engine/Worker startup forbidden'}
            function script:Invoke-TCDeployOperation {$script:Workflow.ForbiddenCalls++; throw 'Remote/SSH operation forbidden'}
            function script:Start-Process {$script:Workflow.ForbiddenCalls++; throw 'Process/Worker startup forbidden'}
            function script:Invoke-WebRequest {$script:Workflow.ForbiddenCalls++; throw 'Real HTTP forbidden'}
            function script:Invoke-RestMethod {$script:Workflow.ForbiddenCalls++; throw 'Real HTTP forbidden'}
        } $state
    }
    # Process tables are external OS observations too; no live process is inspected.
    foreach($module in @($modules.Candidate,$modules.Lines)) { & $module {param($s)
        $script:Workflow=$s
        function script:Get-CimInstance {param($ClassName,$Filter)
            if($ClassName -cne 'Win32_Process'){$script:Workflow.ForbiddenCalls++;throw 'Unsupported external OS observation'}
            @()
        }
    } $state }
    & $modules.Path {
        param($s)
        $script:Workflow=$s
        function script:Read-TCProbeNetworkState {$script:Workflow.SnapshotReads++; $script:Workflow.Snapshot}
        function script:Start-TCProbeSocketObservation {param([int]$ProcessId,$Binding,[string]$TraceIdentity,[string]$RunDirectory)
            $script:Workflow.ObservationStarts++
            if(-not $TraceIdentity){$TraceIdentity=[guid]::NewGuid().ToString('D')}
            [pscustomobject]@{ProcessId=$ProcessId;ProcessStartTicks=638000000000000000;Binding=$Binding;Identity=$TraceIdentity}
        }
        function script:Stop-TCProbeSocketObservation {param($Observer)
            $script:Workflow.ObservationStops++
            if($script:Workflow.Mode -in @('CancelCleanup','CancelDuringCleanup')){
                $receipt=& $script:Workflow.FlowModule {param($r,$id) Request-TCDeploymentProbeStop -Root $r -RunId $id} $script:Workflow.ActiveRoot $script:Workflow.ActiveRunId
                if(-not $receipt.Accepted){throw 'Real deployment cancellation marker rejected'}
            }
            if($script:Workflow.Mode -in @('CleanupFailure','CancelCleanup')){throw 'Fixture owned observation cleanup failed'}
            $b=$Observer.Binding; $protocol=if($b){$b.Protocol}else{'Udp'}
            $row=@()
            if($b){$row=@([pscustomobject]@{ProcessId=$Observer.ProcessId;LocalAddress=$b.LocalAddress;LocalPort=49001;RemoteAddress=$b.RemoteAddress;RemotePort=$b.RemotePort;AddressFamily='IPv4';State=$(if($protocol -eq 'Udp'){0}else{5});Source=$(if($protocol -eq 'Udp'){'WindowsKernelNetworkUdpSendV0'}else{'GetExtendedTcpTable'})})}
            $trace=$null
            if($protocol -eq 'Udp'){
                $trace=[pscustomobject]@{SessionGuid=$Observer.Identity;SessionName=('TCProbe-UDP-'+([guid]$Observer.Identity).ToString('N'));Started=$true;CleanupComplete=$true;SessionAbsent=$true;GuardCompleted=$true;EventsLost=0;BuffersLost=0;MatchedEvents=3;Source='FixtureEtwBoundary'}
                if($script:Workflow.Mode -eq 'UdpEtwUnavailable'){$trace.Started=$false;$trace.MatchedEvents=0;$row=@()}
            }
            [pscustomobject]@{Status='Available';Protocol=$protocol;ProcessId=$Observer.ProcessId;ProcessStartTicks=$Observer.ProcessStartTicks;Reads=3;Errors=0;Overflow=$false;NetworkChanges=0;Rows=$row;Source='FixtureObservationBoundary';TraceEvidence=$trace}
        }
        function script:Stop-TCProbeOwnedTrace {param([string]$Identity)
            if($Identity -notmatch '^[a-fA-F0-9-]{36}$'){throw 'Invalid fixture trace identity'}
            # No native ETW provider/session was started by this test.
        }
    } $state
    & $modules.Candidate {
        param($s)
        $script:Workflow=$s
        function script:Invoke-TCCandidateProbeHttp {param([int]$Port,[string]$User,[string]$Secret,$Target,[int]$TimeoutSeconds)
            if($Port -ne 19341 -or $User -notlike 'candidate-*' -or -not $Secret -or $TimeoutSeconds -ne 6){throw 'Real bounded HTTP contract changed'}
            $script:Workflow.HttpCount++
            if($script:Workflow.Mode -eq 'CancelDuringHttp' -and $script:Workflow.HttpCount -eq 1){
                $receipt=& $script:Workflow.FlowModule {param($r,$id) Request-TCDeploymentProbeStop -Root $r -RunId $id} $script:Workflow.ActiveRoot $script:Workflow.ActiveRunId
                if(-not $receipt.Accepted){throw 'Real deployment cancellation marker rejected'}
            }
            $duration=if(($script:Workflow.CurrentProfile -ceq 'Udp') -xor ($script:Workflow.Mode -eq 'FastUdp')){140}else{45}
            if($Target.Name -ceq 'DomainDnsHttps'){$duration+=25}
            $status=if($Target.Trace){'Passed'}else{'UserVerificationRequired'}
            $code=if($Target.Trace){'HttpsReached'}else{'BrowserChallenge'}
            $tls=$true; $ip=if($Target.Trace){'192.0.2.40'}else{$null}; $http=if($Target.Trace){200}else{403}
            if($script:Workflow.Mode -eq 'HttpTimeout' -and $script:Workflow.HttpCount -eq 1){$status='Failed';$code='ProbeTimeout';$tls=$false;$ip=$null;$http=$null;$duration=6000}
            if($script:Workflow.Mode -eq 'AllHttpFailed'){$status='Failed';$code='HttpsUnreachable';$tls=$false;$ip=$null;$http=$null}
            [pscustomobject]@{Name=$Target.Name;Status=$status;Code=$code;HttpStatus=$http;TlsVerified=$tls;ObservedExitIPv4=$ip;DurationMs=$duration;TargetHost=([uri]$Target.Url).Host;Source='AuthenticatedCandidateProxy'}
        }
    } $state

    # Select complete AST statements, never regex-copy a second implementation.
    # The actual sampler is coupled to engine startup; its offline HTTP adapter
    # therefore uses the original statements around that forbidden phase.
    $tokens=$null; $parseErrors=$null
    $candidateSource=Join-Path $PackageRoot 'CandidateProbe.psm1'
    $ast=[Management.Automation.Language.Parser]::ParseFile($candidateSource,[ref]$tokens,[ref]$parseErrors)
    Check ($parseErrors.Count -eq 0) 'CandidateProbe source parses in Windows PowerShell 5.1'
    $fn=$ast.Find({param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -ceq 'Test-TCCandidateProbe'},$true)
    $top=@($fn.Body.EndBlock.Statements); $tryNode=@($top | Where-Object {$_ -is [Management.Automation.Language.TryStatementAst]})[0]
    $tryStatements=@($tryNode.Body.Statements)
    $launch=@($tryStatements | Where-Object {$_ -is [Management.Automation.Language.ForStatementAst] -and $_.Extent.Text -match '^for\(\$attempt='})[0]
    $setup=@($tryStatements | Where-Object {$_.Extent.StartOffset -lt $launch.Extent.StartOffset})
    $sampleStart=@($tryStatements | Where-Object {$_.Extent.Text -match '^\$targets=@\(Get-TCCandidateProbeTargets\)'})[0]
    $sampling=@($tryStatements | Where-Object {$_.Extent.StartOffset -ge $sampleStart.Extent.StartOffset})
    $finallyStatements=@($tryNode.Finally.Statements | Where-Object {$_.Extent.Text -notmatch '^if\(\$process\)'})
    $after=@($top | Where-Object {$_.Extent.StartOffset -gt $tryNode.Extent.EndOffset})
    $before=@($top | Where-Object {$_.Extent.StartOffset -lt $tryNode.Extent.StartOffset})
    $configStatements=@($launch.Body.Statements | Where-Object {$_.Extent.Text -match '^\$configHash=' -or $_.Extent.Text -match '^\$transport=' -or $_.Extent.Text -match '^if\(\(\$ProfileId'})
    $inject=@'
        $script:Workflow.ProbeCount++; $script:Workflow.CurrentProfile=$ProfileId
        $script:Workflow.Events.Add([pscustomobject]@{Type='ProbeEntered';ProfileId=$ProfileId;CandidateSHA256=$null})
'@
    $offline=@'
        $script:Workflow.ReportSecrets.Add($secret)
        $port=19341
        $config=New-TCCandidateProbeConfig $manifest $candidate $stored $port $user $secret
        $null=& $nodeModule {param($p,$c,$e) Write-TCAtomicJson $p $c -NoBom; Test-TCCheckedConfiguration $e $p} $configPath $config $engine
        $process=[pscustomobject]@{Id=240001;HasExited=$false;StartTime=[DateTime]::new(638000000000000000,[DateTimeKind]::Utc)}
        $binding=Get-TCProbeField $manifest 'ProbeBinding'
        if($binding -and $binding.Protocol -eq 'Udp'){$ownershipMetadata.TraceGuid=[guid]::NewGuid().ToString('D');$ownershipMetadata.TraceState='Starting'}
        $observer=Start-TCCandidateSocketWatch $process.Id $binding $ownershipMetadata.TraceGuid $runDirectory
        $script:Workflow.Events[$script:Workflow.Events.Count-1].CandidateSHA256=$candidateHash
'@
    $receipt=@'
    $script:Workflow.AssessmentCount+=$([int]($pathEvidence.Reason -ne 'NotStarted'))
    $script:Workflow.Receipts.Add([pscustomobject]@{ProfileId=$ProfileId;CandidateHash=$result.CandidateHash;ManifestHash=$result.ManifestHash;ConfigHash=$result.ConfigHash;Status=$result.Status;Code=$result.Code;CleanupComplete=$result.CleanupComplete;CancellationRequested=$result.CancellationRequested;Samples=$result.Samples.Count;PathEvidence=$result.PathEvidence})
'@
    $diagnostic=@'
        $script:Workflow.Events.Add([pscustomobject]@{Type='HttpAdapterException';ExceptionType=$_.Exception.GetType().FullName;ErrorId=$_.FullyQualifiedErrorId;SourceLine=$_.InvocationInfo.ScriptLineNumber})
'@
    $catchParts=@(foreach($clause in $tryNode.CatchClauses){'catch {'; $diagnostic; $clause.Body.Statements | ForEach-Object {$_.Extent.Text}; '}'})
    $parts=@($fn.Body.ParamBlock.Extent.Text)+@($before | ForEach-Object {$_.Extent.Text})+@($inject,'try {')+
        @($setup | ForEach-Object {$_.Extent.Text})+@($offline)+@($configStatements | ForEach-Object {$_.Extent.Text})+
        @($sampling | ForEach-Object {$_.Extent.Text})+@('}')+$catchParts+
        @('finally {')+@($finallyStatements | ForEach-Object {$_.Extent.Text})+@('}')+
        @($after | Where-Object {$_.Extent.Text -cne '$result'} | ForEach-Object {$_.Extent.Text})+@($receipt,'$result')
    # A dynamically compiled fragment has no source-file PSScriptRoot. Preserve
    # its original module imports with an explicit, already selected package root.
    $adapterText=($parts -join "`r`n").Replace('$PSScriptRoot','$script:Workflow.PackageRoot')
    $adapter=[scriptblock]::Create($adapterText)
    $state.AdapterSourceSHA256=Hash $candidateSource
    $state.AdapterRanges=@(foreach($group in @(@{Name='Setup';Items=$setup},@{Name='SamplingAndAssessment';Items=$sampling},@{Name='Finalize';Items=$after})) {
        [pscustomobject]@{Name=$group.Name;FirstLine=$group.Items[0].Extent.StartLineNumber;LastLine=$group.Items[-1].Extent.EndLineNumber}
    })
    Check ($adapterText -notmatch 'Start-TCBoundedEngineProcess|Get-TCCandidateProbePort|\.Kill\(|\.WaitForExit\(') 'HTTP adapter cannot launch an engine, Worker, socket listener or terminate any process'
    Check ($adapterText -notmatch 'Verified\s*=\s*\$true' -and $adapterText -match 'Get-TCCandidatePathAssessment \$candidate' -and $adapterText -match 'Get-TCCandidatePathAssessment \$config') 'saved/effective PathEvidence.Verified comes only from real ProbePath assessment'
    & $modules.Candidate {param($body) Set-Item Function:script:Invoke-WorkflowHttpProbe $body; function script:Test-TCCandidateProbeListener {param($Port,$ProcessId) ($Port -eq 19341 -and $ProcessId -eq 240001)}} $adapter
    & $modules.Comparison {param($candidate)
        $script:WorkflowCandidate=$candidate
        function script:Invoke-TCProtocolComparisonProbe {param($Root,$NodeId,$ProfileId,$ExpectedExitIPv4,$ExpectedExitSource,$CancellationPath,$TimeoutSeconds)
            try { & $script:WorkflowCandidate {param($r,$n,$p,$ip,$source,$cancel,$budget)
                Invoke-WorkflowHttpProbe -Root $r -NodeId $n -ProfileId $p -ExpectedExitIPv4 $ip -ExpectedExitSource $source -CancellationPath $cancel -TimeoutSeconds $budget -FixedRequestBudget
            } $Root $NodeId $ProfileId $ExpectedExitIPv4 $ExpectedExitSource $CancellationPath $TimeoutSeconds }
            catch {
                $script:Workflow.Events.Add([pscustomobject]@{Type='HttpDelegateException';ExceptionType=$_.Exception.GetType().FullName;ErrorId=$_.FullyQualifiedErrorId;SourceLine=$_.InvocationInfo.ScriptLineNumber;Message=([regex]::Replace($_.Exception.Message,'[A-Za-z0-9+/]{43}=','[redacted-base64-key]'));Stack=$_.ScriptStackTrace})
                throw
            }
        }
    } $modules.Candidate

    if($JourneyOnly){InstallJourneyBoundary;InvokeJourneyMatrix}
    elseif($NegativeControl){InvokeNegativeJourneyContracts}
    if($CoreMatrixOnly){InvokeDirectLeaseMatrix}
    if(-not $BarrierOnly -and -not $JourneyOnly -and -not $NegativeControl) {
    BeginCase 'PrepareReloadNormalizeRecommend'; SetSnapshot
    $f=NewFixture 'main'; $run=NewFixtureRun $f
    Check ($f.OldLine.Profiles.Count -eq 2 -and @($f.OldLine.Profiles | Where-Object {(Field (ReadJson $_.ManifestPath) ProbeBinding)}).Count -eq 0) 'real Import/Register/PrepareTCP starts with two unbound profiles'
    $oldAssets=SnapshotFiles @($f.OldLine.Profiles | ForEach-Object {$m=ReadJson $_.ManifestPath; $_.ManifestPath; $m.CandidatePath; $m.ProbePath})
    $result=ProbeRun $f $run
    RecordCase $result $f
    $binding=Field $result ProbeBindingResult
    Check ($binding -and $binding.State -ceq 'Ready' -and $binding.Prepared -and @($binding.Results | Where-Object BindingState -ceq 'Prepared').Count -eq 2) 'Comparison must prepare both unbound profiles before sampling (0.14.1 regression)'
    $line=Get-TCLine -Root $f.Root -Id $f.Node.id
    foreach($id in @('Udp','Tcp')) {
        $old=@($f.OldLine.Profiles | Where-Object Id -ceq $id)[0]; $p=@($line.Profiles | Where-Object Id -ceq $id)[0]
        $row=@($binding.Results | Where-Object ProfileId -ceq $id)[0]; $e=$result.ValidationProfiles.$id; $raw=$e.Result
        Check ($p.Revision -eq $old.Revision+1 -and $p.CandidateSHA256 -cne $old.CandidateSHA256 -and $p.ManifestSHA256 -cne $old.ManifestSHA256) ($id+' unbound config publishes new immutable hashes')
        Check ($row.CandidateSHA256 -ceq $p.CandidateSHA256 -and $row.ManifestSHA256 -ceq $p.ManifestSHA256 -and $raw.CandidateHash -ceq $p.CandidateSHA256 -and $e.CandidateSHA256 -ceq $p.CandidateSHA256 -and $e.Status -ceq 'Passed') ($id+' binding, reloaded profile, sample receipt and normalized evidence agree')
        Check ($raw.ProbeRuns.Count -eq 3 -and $raw.Samples.Count -eq 21 -and @($raw.ProbeRuns | Where-Object {$_.Result.CandidateHash -cne $p.CandidateSHA256}).Count -eq 0) ($id+' every actual comparison round uses the new hash')
        $m=ReadJson $p.ManifestPath; $cfg=ReadJson $m.CandidatePath; $pr=ReadJson $m.ProbePath
        $outer=& $modules.Path {param($c) Get-TCProbeOuter $c} $cfg
        foreach($c in @($cfg,$pr)) {
            $o=& $modules.Path {param($v) Get-TCProbeOuter $v} $c
            $dns=@($c.dns.servers | Where-Object tag -ceq 'dns-direct')[0]
            Check ($o.Object.bind_interface -ceq 'Ethernet Fixture' -and $o.Object.inet4_bind_address -ceq '192.0.2.2' -and $o.Object.domain_resolver.server -ceq 'dns-direct' -and $o.Object.domain_resolver.strategy -ceq 'ipv4_only' -and $dns.bind_interface -ceq $o.Object.bind_interface -and $dns.inet4_bind_address -ceq $o.Object.inet4_bind_address -and $dns.server -ceq '192.0.2.53' -and -not (Field $dns detour)) ($id+' real candidate/probe outer and bootstrap DNS share saved dial fields')
            if($id -ceq 'Tcp') { Check (-not (Field $o.Endpoint bind_interface) -and -not (Field $o.Endpoint inet4_bind_address) -and $o.Layer -ceq 'outbounds') 'TCP binding belongs to outer transport and is absent from detoured WireGuard endpoint' }
        }
        $context=Get-TCProbeNetworkContext -Binding $m.ProbeBinding
        $path=$raw.PathEvidence
        Check ($context.Status -ceq 'Available' -and $context.Scope -ceq 'BoundPhysicalIPv4.v1' -and $path.NetworkFingerprint -ceq $context.Fingerprint -and $path.UnderlayFingerprint -ceq $context.UnderlayFingerprint -and $raw.SnapshotFingerprint -ceq $context.SnapshotFingerprint -and $path.Verified -and $path.SocketEvidence.Count -eq 1) ($id+' production bound context and real tuple assessment fingerprints agree')
        Check ($path.Reason -ceq $(if($id -ceq 'Udp'){'OwnedUdpEtwAndSavedBindingVerified'}else{'OwnedTcpSocketAndSavedBindingVerified'})) ($id+' path is verified by the production owned-observation evaluator')
        if($id -ceq 'Udp') { Check ($path.TraceEvidence.CleanupComplete -and $path.TraceEvidence.SessionAbsent -and $path.TraceEvidence.GuardCompleted -and $path.TraceEvidence.MatchedEvents -gt 0) 'UDP eligibility includes ETW owner, trace completion and cleanup fields' }
        # A real evaluator must reject a wrong tuple; passing HTTP is insufficient.
        $observation=& $modules.Path {param($b) $h=Start-TCProbeSocketObservation 240001 $b ([guid]::NewGuid().ToString('D')) ''; Stop-TCProbeSocketObservation $h} $m.ProbeBinding
        $observation.Rows[0].RemotePort++
        $bad=& $modules.Path {param($c,$m,$p,$ctx,$o) Get-TCProbePathAssessment $c $m $p @($ctx,$ctx) $o $true} $cfg $m $p $context $observation
        Check (-not $bad.Verified -and $bad.Reason -ceq 'UnexpectedOwnedSocket') ($id+' wrong remote tuple cannot inherit top-level Verified')
    }
    $order=($state.Receipts | ForEach-Object ProfileId) -join ','
    Check ($state.ProbeCount -eq 6 -and $state.HttpCount -eq 42 -and $order -ceq 'Udp,Tcp,Tcp,Udp,Udp,Tcp') 'real Comparison alternates six probes with 42 bounded HTTP samples'
    Check ($result.Recommendation.Status -ceq 'Recommended' -and $result.RecommendedProfileId -ceq 'Tcp' -and $result.Recommendation.Source -ceq 'Performance' -and $result.Recommendation.PerformanceRanked -and $result.Recommendation.PairedSampleCount -eq 18) 'real normalization/recommendation consumes paired samples and selects supported faster TCP'
    $saved=$line.SavedConnectionPreference;$profile=Get-TCLineProfile -Root $f.Root -Id $f.Node.id -ProfileId Tcp;$manifest=ReadJson $profile.ManifestPath
    Check ($result.Status -ceq 'Complete' -and $result.AutoSavedAtUtc -and -not $result.AttentionRequired -and (Json $result.SavedConnectionPreference) -ceq (Json $saved)) 'latest real Flow autosaves the fully prepared comparison and exact LineStore default snapshot'
    Check ($saved.ProfileId -ceq 'Tcp' -and $saved.Source -ceq 'Performance' -and $saved.Provenance.Kind -ceq 'Recommendation' -and $saved.Binding.CandidateSHA256 -ceq $profile.CandidateSHA256 -and $saved.Binding.ManifestSHA256 -ceq (Hash $profile.ManifestPath) -and (Test-TCSavedConnectionPreference -Preference $saved -LineId $line.LineId -Profile $profile -Manifest $manifest)) 'real saved-default producer binds immutable config/manifest and authenticated original comparison provenance'
    $default=Get-TCLineDefaultProfile -Root $f.Root -Id $f.Node.id
    Check ($default.ProfileId -ceq 'Tcp' -and $default.Code -ceq 'SavedDefault' -and $default.SelectionMode -ceq 'SavedDefault') 'production default consumer validates the actual saved-default binding'
    Check (Test-TCProtocolRecommendationCurrent -Recommendation $result.Recommendation -Profiles $line.Profiles -NetworkContext (Get-TCProtocolNetworkContext)) 'stored recommendation is reproducibly current against real bound contexts'
    Check ((SnapshotFiles $f.Protected) -ceq $f.Before -and (SnapshotFiles @($f.OldLine.Profiles | ForEach-Object {$m=ReadJson $_.ManifestPath; $_.ManifestPath; $m.CandidatePath; $m.ProbePath})) -ceq $oldAssets) 'original import, immutable old assets, index, deployment, runtime and UI preferences stay byte/ACL-identical'
    $events=@($state.Events.ToArray()); $firstProbe=@($events | Where-Object Type -ceq 'ProbeEntered')[0]
    Check (@($events | Where-Object {$_.Type -ceq 'DeploymentProgress' -and $_.Stage -ceq 'PreparingProbePath'}).Count -gt 0 -and @($events | Where-Object {$_.Type -ceq 'DeploymentProgress' -and $_.Stage -ceq 'CheckingProfiles' -and $_.BindingState -ceq 'Ready'}).Count -gt 0 -and $firstProbe.CandidateSHA256 -ceq $line.Profiles[0].CandidateSHA256) 'DeploymentFlow persists preparation/checking progress before the first new-profile sample'
    $stable=SnapshotTree $f.Root
    $reuse=Prepare-TCLineProbeBindings -Root $f.Root -Id $f.Node.id
    Check (-not $reuse.Prepared -and @($reuse.Results | Where-Object BindingState -ceq 'Reused').Count -eq 2 -and (SnapshotTree $f.Root) -ceq $stable) 'identical real binding preparation reuses profiles without filesystem writes'
    BeginCase 'ReusedBindingAndHistory'
    $again=ProbeRun $f $result; RecordCase $again $f
    Check (@($again.ProbeBindingResult.Results | Where-Object BindingState -ceq 'Reused').Count -eq 2 -and $state.HttpCount -eq 42) 'Comparison reports Reused binding on another complete check'
    Check ($again.ProbeHistory.Count -ge 1 -and [IO.File]::Exists($again.ProbeHistory[-1].Path)) 'DeploymentFlow saves prior check history before another attempt'
    $history=ReadJson $again.ProbeHistory[-1].Path
    Check ($history.AttemptId -ceq $result.ProbeAttemptId -and $history.ProbePreparation.State -ceq 'Ready' -and $history.Recommendation.RecommendedProfileId -ceq 'Tcp' -and $history.ValidationProfiles.Udp.CandidateSHA256 -ceq $line.Profiles[0].CandidateSHA256) 'history retains original attempt, real preparation, new hashes and recommendation'
    Check ((SnapshotFiles $f.Protected) -ceq $f.Before) 'recheck/history does not modify current channel or preferences'

    if(-not $CoreMatrixOnly -and -not $JourneyOnly -and -not $NegativeControl) {
    BeginCase 'ExplicitPreference'; SetSnapshot
    $f=NewFixture 'preference' -UserChoice; $run=NewFixtureRun $f; $result=ProbeRun $f $run; RecordCase $result $f
    $line=Get-TCLine -Root $f.Root -Id $f.Node.id
    Check ($result.ProbeBindingResult.Prepared -and $line.PreferredProfileId -ceq 'Udp' -and $line.PreferenceSource -ceq 'UserChoice' -and $result.Recommendation.Status -ceq 'UserChoice' -and -not $result.RecommendedProfileId) 'new binding and real comparison preserve explicit UDP choice despite faster TCP samples'
    Check ((SnapshotFiles $f.Protected) -ceq $f.Before) 'explicit preference case preserves original import and persisted UI preferences'

    BeginCase 'MultipleInterfaces'; SetSnapshot -Multiple
    $f=NewFixture 'multiple'; $run=NewFixtureRun $f; $old=SnapshotFiles @($f.OldLine.Profiles.ManifestPath)
    $result=ProbeRun $f $run; RecordCase $result $f
    Check ($result.ProbeBindingResult.State -ceq 'NeedsNetworkSelection' -and @($result.ProbeBindingResult.Results | Where-Object {$_.BindingState -ceq 'NeedsNetworkSelection' -and $_.ReasonCode -ceq 'AmbiguousPhysicalInterface' -and $_.Interfaces.Count -eq 2}).Count -eq 2) 'multiple eligible NICs produce explicit ChooseNetwork rows for both profiles'
    Check ($state.ProbeCount -eq 0 -and $state.HttpCount -eq 0 -and -not $result.RecommendedProfileId -and (SnapshotFiles @($f.OldLine.Profiles.ManifestPath)) -ceq $old) 'ambiguous NIC selection starts no sampler and keeps unbound assets'
    BeginCase 'ExplicitInterfaceSelection'
    $result=ProbeRun $f $result -InterfaceIndex 8; RecordCase $result $f
    Check ($result.ProbeBindingResult.State -ceq 'Ready' -and $result.ProbeBindingResult.SelectedInterfaceIndex -eq 8 -and $state.ProbeCount -eq 6 -and $state.HttpCount -eq 42 -and $result.RecommendedProfileId -ceq 'Tcp') 'DeploymentFlow forwards InterfaceIndex and resumes the same run using the selected NIC'
    Check ($result.ValidationProfiles.Udp.PathEvidence.Binding.InterfaceIndex -eq 8 -and $result.ValidationProfiles.Tcp.PathEvidence.Binding.LocalAddress -ceq '198.51.100.2' -and (SnapshotFiles $f.Protected) -ceq $f.Before) 'explicit selected interface/source survives path normalization without current-channel changes'

    BeginCase 'UnsupportedIpv6'; SetSnapshot
    $f=NewFixture 'ipv6' -TcpServer '2001:db8::10'; $run=NewFixtureRun $f; $result=ProbeRun $f $run; RecordCase $result $f
    Check ($result.ProbeBindingResult.State -ceq 'Unsupported' -and @($result.ProbeBindingResult.Results | Where-Object {$_.BindingState -ceq 'Unsupported' -and $_.ReasonCode -ceq 'IPv6NotSupported'}).Count -eq 2) 'real preparation explicitly leaves unsupported IPv6 outer paths unverified'
    Check ($state.ProbeCount -eq 0 -and $state.HttpCount -eq 0 -and -not $result.RecommendedProfileId -and -not $result.Recommendation.PerformanceRanked) 'unsupported IPv6 bindings start no sampler or automatic recommendation'
    Check (-not $result.ValidationProfiles.Tcp.EligibleForAutomaticSelection -and (SnapshotFiles $f.Protected) -ceq $f.Before) 'unsupported IPv6 cannot become an automatic candidate or modify source assets'

    BeginCase 'PartialHostnamePreparation'; SetSnapshot
    $f=NewFixture 'hostname' -TcpServer 'transport.example.com'; $run=NewFixtureRun $f; $result=ProbeRun $f $run; RecordCase $result $f
    Check ($result.ProbeBindingResult.State -ceq 'Partial' -and @($result.ProbeBindingResult.Results | Where-Object {$_.ProfileId -ceq 'Tcp' -and $_.BindingState -ceq 'Unsupported' -and $_.ReasonCode -ceq 'InnerPeerDnsNotSupported'}).Count -eq 1) 'production plan supports UDP hostname binding but explicitly rejects detoured inner-peer DNS'
    Check ($state.ProbeCount -eq 1 -and $state.HttpCount -eq 7 -and $state.Receipts[0].ProfileId -ceq 'Udp' -and -not $result.RecommendedProfileId -and -not $result.Recommendation.PerformanceRanked) 'only ready UDP is sampled and unobservable hostname path never creates an automatic/performance recommendation'
    Check ($result.ValidationProfiles.Udp.PathEvidence.Reason -ceq 'BootstrapDnsRemoteUnobservable' -and $result.ValidationProfiles.Tcp.Code -ceq 'InnerPeerDnsNotSupported' -and (SnapshotFiles $f.Protected) -ceq $f.Before) 'partial preparation and real path assessment retain their separate unverified reasons'

    BeginCase 'UdpEtwUnavailable' 'UdpEtwUnavailable'; SetSnapshot
    $f=NewFixture 'etw-unavailable'; $run=NewFixtureRun $f; $result=ProbeRun $f $run; RecordCase $result $f
    Check ($state.HttpCount -eq 42 -and -not $result.ValidationProfiles.Udp.PathEvidence.Verified -and -not $result.ValidationProfiles.Udp.EligibleForAutomaticSelection -and $result.ValidationProfiles.Udp.PathEvidence.Reason -ceq 'UdpEtwObservationUnavailable') 'successful HTTP never verifies UDP when production ETW assessment reports unavailable'
    Check ($result.RecommendedProfileId -ceq 'Tcp' -and -not $result.Recommendation.PerformanceRanked) 'unverified UDP path cannot participate in performance ranking'
    }
    }

    if(-not $CoreMatrixOnly -and -not $JourneyOnly -and -not $NegativeControl) {
    BeginCase 'ActiveIdentity'; SetSnapshot
    $f=NewFixture 'active'; WriteFixture (Join-Path $f.Root 'runtime.json') @{State='Running';ManifestPath=$f.Node.manifestPath;CleanupError=$false;FixtureOnly=$true}
    $f.Before=SnapshotFiles $f.Protected; $run=NewFixtureRun $f; $old=SnapshotFiles @($f.OldLine.Profiles.ManifestPath)
    $result=ProbeRun $f $run; RecordCase $result $f
    Check ($result.ProbeBindingResult.State -ceq 'Blocked' -and $result.ProbeBindingResult.Code -ceq 'ActiveIdentity') 'real source identity check blocks binding for an active fixture identity'
    CheckFenced $result 'ActiveIdentity' 0 0
    Check ((SnapshotFiles @($f.OldLine.Profiles.ManifestPath)) -ceq $old -and (SnapshotFiles $f.Protected) -ceq $f.Before) 'active identity barrier preserves profile assets and current-channel records'

    BeginCase 'PreviousCleanup'; SetSnapshot
    $f=NewFixture 'previous-cleanup'; $run=NewFixtureRun $f
    $owned=Join-Path (Join-Path $f.Root 'probes') ([guid]::NewGuid().ToString('D')); PrivateDirectory $owned
    WriteFixture (Join-Path $owned 'ownership.json') @{State='NeedsRecovery';RunId=[IO.Path]::GetFileName($owned);TraceGuid=$null;TraceState='NotStarted'}
    $result=ProbeRun $f $run; RecordCase $result $f
    CheckFenced $result 'ProbeCleanupFailed' 1 0
    Check ($result.RecoveryRequired -and $state.ObservationStarts -eq 0 -and (SnapshotFiles $f.Protected) -ceq $f.Before) 'real previous-cleanup receipt blocks all observation/HTTP and requires recovery'

    BeginCase 'PreexistingCancellation'; SetSnapshot
    $f=NewFixture 'pre-cancel'; $run=NewFixtureRun $f
    $attempt=[guid]::NewGuid().ToString('N'); $cancel=Join-Path (Join-Path $f.Root ('deployments\runs\'+$run.RunId)) ('probe-cancel-'+$attempt+'.json')
    WriteFixture $cancel @{RunId=$run.RunId;AttemptId=$attempt}
    $before=SnapshotTree $f.Root
    $comparison=Invoke-TCProtocolComparison -Root $f.Root -NodeId $f.Node.id -ExpectedExitIPv4 '192.0.2.40' -ExpectedExitSource ServerVerifiedTlsTrace -CancellationPath $cancel
    Check ($comparison.Code -ceq 'ProbeCancelled' -and -not $comparison.BindingResult -and $state.ProbeCount -eq 0 -and $state.HttpCount -eq 0 -and (SnapshotTree $f.Root) -ceq $before) 'preexisting bounded marker cancels real Comparison before preparation, locks and sampling'

    foreach($mode in @('CancelDuringHttp','CancelDuringCleanup','CleanupFailure','CancelCleanup')) {
        BeginCase $mode $mode; SetSnapshot
        $f=NewFixture $mode; $run=NewFixtureRun $f; $result=ProbeRun $f $run; RecordCase $result $f
        $cleanupFailure=$mode -in @('CleanupFailure','CancelCleanup'); $code=if($cleanupFailure){'ProbeCleanupFailed'}else{'ProbeCancelled'}
        $expectedHttp=if($mode -ceq 'CancelDuringHttp'){1}else{7}
        CheckFenced $result $code 1 $expectedHttp
        if($cleanupFailure) { Check ($result.RecoveryRequired -and $result.Stage -ceq 'NeedsRecovery') ($mode+' actual failed cleanup requires recovery and takes precedence over cancellation') }
        else { Check ($result.ProfileProbeState -ceq 'Cancelled' -and -not $result.RecoveryRequired -and $result.Stage -ceq 'ReadyInactive') ($mode+' unwinds local check without destroying prepared deployment') }
        if($mode -ne 'CleanupFailure') { Check ([IO.File]::Exists($result.ProbeCancellationPath) -and (ReadJson $result.ProbeCancellationPath).AttemptId -ceq $result.ProbeAttemptId) ($mode+' uses real per-attempt deployment cancellation marker') }
        Check ((SnapshotFiles $f.Protected) -ceq $f.Before) ($mode+' preserves original assets, preferences and channel')
    }

    BeginCase 'HttpTimeoutDenominator' 'HttpTimeout'; SetSnapshot
    $f=NewFixture 'timeout'; $run=NewFixtureRun $f; $result=ProbeRun $f $run; RecordCase $result $f
    $raw=$result.ValidationProfiles.Udp.Result
    Check ($state.HttpCount -eq 42 -and $raw.Metrics.Failed -eq 1 -and $raw.Metrics.TimedOut -eq 1 -and @($raw.Samples | Where-Object Code -ceq 'ProbeTimeout').Count -eq 1 -and $result.RecommendedProfileId -ceq 'Tcp' -and $result.Recommendation.Source -ceq 'Stability' -and -not $result.Recommendation.PerformanceRanked) 'real sampler/aggregation keeps timeout in denominator and stability overrides response speed'
    }

    $script:Case='SafetyAndCloseout'
    $sourceAfter=ReadSourceHashes
    Check ((Json $sourceBefore) -ceq (Json $sourceAfter)) 'all recorded SourceSHA256 values stayed stable from import through validation'
    Check ((Hash $PSCommandPath) -ceq $testSHA256) 'test source stayed identical to the loaded script throughout validation'
    foreach($key in @($originalCore.Keys | Sort-Object)) {
        $parts=$key.Split(':'); $definition=& $modules[$parts[0]] {param($n) (Get-Command $n).Definition} $parts[1]
        Check ((TextHash $definition) -ceq $originalCore[$key]) ($key+' production implementation was never replaced')
    }
    Check ($state.ForbiddenCalls -eq 0) 'no real Worker/engine run, SSH, HTTP or process-control boundary was invoked'
    Check ($state.NativeCalls.Count -gt 0 -and @($state.NativeCalls | Where-Object {$_.Command -notin @('check','pubkey')}).Count -eq 0 -and @($state.NativeCalls | Where-Object ExitCode -ne 0).Count -eq 0) 'all actual native calls are successful fixture-only sing-box check or wg pubkey'
    if(-not $JourneyOnly -and -not $NegativeControl){Check (@($state.NativeCalls | Where-Object {$_.Command -ceq 'check' -and $_.Config -match '\\.staging\\'}).Count -ge 8 -and @($state.NativeCalls | Where-Object {$_.Command -ceq 'check' -and $_.Config -match 'candidate\.private\.json$'}).Count -ge 6) 'real checks covered published immutable bindings and effective HTTP probe configs'}
    Check (@($state.Writes | Where-Object {-not ([IO.Path]::GetFullPath($_).StartsWith($work.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase))}).Count -eq 0) 'all observed application writes stayed under the sole restricted fixture root'
    Check (@(Get-ChildItem -LiteralPath $work -Recurse -File -Filter 'candidate.private.json').Count -eq 0) 'real probe finalization removed all temporary authenticated private configs'
    if($state.Findings.Count){throw ('Journey contract failures: '+(($state.Findings | ForEach-Object Case) -join ', '))}
    $passed=$true
} catch {
    $failure=[pscustomobject]@{Case=$script:Case;Assertion=$script:LastAssertion;Message=([regex]::Replace($_.Exception.Message,'[A-Za-z0-9+/]{43}=','[redacted-key]'));ExceptionType=$_.Exception.GetType().FullName;SourceLine=$_.InvocationInfo.ScriptLineNumber;Stack=$_.ScriptStackTrace}
    Note ('FAIL ['+$script:Case+'] '+$_.Exception.Message)
} finally {
    if($sourceBefore.Count){$sourceAfter=ReadSourceHashes}
    if($nativeOriginal -and $modules.ContainsKey('Nodes')) { & $modules.Nodes {param($runner) $script:TCNativeRunner=$runner} $nativeOriginal }
    if([IO.Directory]::Exists($work)) {
        try {
            $full=[IO.Path]::GetFullPath($work); $parent=[IO.Path]::GetFullPath($parentRoot).TrimEnd('\')+'\'
            if(-not $full.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -cnotmatch '^TC-ProbeWorkflowIntegration-[a-f0-9]{32}$'){throw 'Fixture cleanup target validation failed'}
            if($modules.ContainsKey('Nodes')) { & $modules.Nodes {param($p) Assert-TCNoReparse $p} $full }
            Remove-Item -LiteralPath $full -Recurse -Force
            $removed=-not [IO.Directory]::Exists($full)
        } catch { $passed=$false; $log.Add('Fixture cleanup failed: '+$_.Exception.GetType().FullName) }
    } else { $removed=$true }
    if(-not [IO.Directory]::Exists($reportDirectory)){ $null=[IO.Directory]::CreateDirectory($reportDirectory) }
    $report=[ordered]@{
        SchemaVersion=1; Kind='TradeChannel.ProbeWorkflowIntegration'; Passed=$passed; PassedCount=$checks.Count
        ExecutedAtUtc=[DateTimeOffset]::UtcNow.ToString('o'); PowerShell=$PSVersionTable.PSVersion.ToString(); PSEdition=$PSVersionTable.PSEdition
        PackageRoot=$PackageRoot; TestSHA256=$testSHA256; TestSHA256After=(Hash $PSCommandPath); TestStable=((Hash $PSCommandPath) -ceq $testSHA256); BarrierOnly=[bool]$BarrierOnly; CoreMatrixOnly=[bool]$CoreMatrixOnly; JourneyOnly=[bool]$JourneyOnly; JourneyCase=$JourneyCase; NegativeControl=[bool]$NegativeControl; FixtureRoot=$work; FixtureRemoved=$removed
        Scope=$(if($JourneyOnly){'Actual Flow intake/access/dispatch/management/enrollment/reconciliation/profile/comparison/saved-default and production UI DTO pipeline.'}elseif($NegativeControl){'0.14.3 runtime contract absence with a real prepared protocol comparison.'}elseif($CoreMatrixOnly){'Real direct-API leases with caller-run contamination/lock failures/archive guards, full prepared comparison and same-run recheck.'}else{'Offline cross-module integration; engine/process lifecycle and public networking not exercised'})
        SourceSHA256=$sourceBefore; SourceSHA256After=$sourceAfter; SourcesStable=((Json $sourceBefore) -ceq (Json $sourceAfter)); HistoricalFullReport=$historicalFull
        RealModules=@('NodeStore','LineStore','ProbePath','CandidateProbe sampling/assessment/finalization','ProtocolComparison','ProtocolSelection','DeploymentFlow','DeploymentStore','ServerRegistry')
        JourneyModules=$(if($JourneyOnly){@('ServerSetup request/config/key operations','DeploymentTransport public dispatch/session/verified observation policy','DeploymentDecision','ui/DeploymentPages.DeploymentLineView','ui/ConnectionProfilePages.LineRecommendationView')}else{@()})
        ReplacedBoundaries=@('ProbePath.Read-TCProbeNetworkState','ProbePath owned socket/ETW observations and listener ownership','CandidateProbe/LineStore external OS process inventory','CandidateProbe HTTP responses; offline HTTP delegate omits engine startup')+$(if($JourneyOnly){@('DeploymentTransport private observation/pipe envelope; real public authentication/identity validation','DeploymentFlow local network inventory; real remote dispatch and reconciliation policies')}else{@()})
        Safety=[ordered]@{RealWorkerCalls=0;RealNetworkRequests=0;ForbiddenBoundaryCalls=$state.ForbiddenCalls;ApplicationWriteCount=$state.Writes.Count;UniqueRestrictedRoot=$true;ProcessOwnershipSimulated=$true;NativeCheckCount=@($state.NativeCalls | Where-Object Command -ceq 'check').Count;NativePubkeyCount=@($state.NativeCalls | Where-Object Command -ceq 'pubkey').Count}
        CandidateSourceSHA256=$state.AdapterSourceSHA256; CandidateSourceRanges=$state.AdapterRanges
        CoreDefinitionSHA256=$originalCore; Assertions=@($checks.ToArray()); Cases=@($caseReports.ToArray()); NativeCalls=@($state.NativeCalls.ToArray()); Failure=$failure
        DirectLeaseMatrix=@($state.LeaseMatrix.ToArray())
        JourneyContracts=$state.Contracts; Journeys=@($state.Journeys.ToArray()); BlockingFindings=@($state.Findings.ToArray()); AuthenticatedObservationReads=$state.EvidenceReads
        RecoveryNegativeCases=@($state.RecoveryNegatives.ToArray())
        CachedReplyContinuations=@($state.CachedContinuations.ToArray())
        LatestJourneyRun=$(if($state.LatestRun){[pscustomobject]@{RunId=$state.LatestRun.RunId;Stage=$state.LatestRun.Stage;Status=$state.LatestRun.Status;PendingPurpose=$state.LatestRun.PendingPurpose;LastError=$state.LatestRun.LastError;RecoveryRequired=$state.LatestRun.RecoveryRequired}}else{$null})
        LatestJourneyError=$state.LatestError
        Dispatches=@(foreach($d in $state.Dispatches){[pscustomobject]@{RunId=$d.RunId;InstanceId=$d.InstanceId;Operation=$d.Operation;OperationId=$d.OperationId;Mutating=$d.Mutating;RequestId=(Field (Field $d.Input ClientRequest) RequestId (Field $d.Input RequestId))}})
    }
    $json=ConvertTo-Json -InputObject $report -Depth 90
    foreach($secret in $secrets){if($json.Contains($secret)){throw 'Report would expose a fixture private key'}}
    [IO.File]::WriteAllText($reportPath,$json,(New-Object Text.UTF8Encoding($false)))
    $log.Add(('RESULT Passed={0} Checks={1} FixtureRemoved={2} NativeChecks={3} Pubkeys={4} ForbiddenCalls={5}' -f $passed,$checks.Count,$removed,$report.Safety.NativeCheckCount,$report.Safety.NativePubkeyCount,$state.ForbiddenCalls))
    [IO.File]::WriteAllLines($logPath,$log,(New-Object Text.UTF8Encoding($false)))
}
Write-Output ('Probe workflow integration: Passed={0}; assertions={1}; fixture removed={2}; report={3}' -f $passed,$checks.Count,$removed,$reportPath)
if(-not $passed){exit 1}
