#requires -Version 5.1
<#
Disposable integration test. Run in a fresh Windows PowerShell 5.1 process.
Only this script and reports/release-0.14.2/probe-workflow-integration*.json/log
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

The same test with -PackageRoot ../0.14.1 must exit 1 at the preparation assertion.
Do not run the existing ProbePath test here: it intentionally starts live sockets.
#>
[CmdletBinding()]
param(
    [string]$PackageRoot = '',
    [ValidatePattern('^probe-workflow-integration(?:-[a-zA-Z0-9-]+)?$')]
    [string]$ReportName = 'probe-workflow-integration',
    [switch]$BarrierOnly,
    [switch]$CoreMatrixOnly
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version 2.0
$ownPackage = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$workspace = Split-Path (Split-Path $ownPackage -Parent) -Parent
if (-not $PackageRoot) { $PackageRoot = $ownPackage }
$PackageRoot = [IO.Path]::GetFullPath($PackageRoot)
$reportDirectory = Join-Path $workspace 'reports\release-0.14.2'
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
}

function Field { param($Value, [string]$Name, $Default = $null)
    if ($Value -is [Collections.IDictionary]) { if ($Value.Contains($Name)) { return $Value[$Name] } }
    elseif ($null -ne $Value -and $Value.PSObject.Properties[$Name]) { return $Value.$Name }
    $Default
}
function Note { param([string]$Text)
    $line = [DateTimeOffset]::UtcNow.ToString('o') + ' ' + $Text
    $log.Add($line); Write-Output $Text
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
        SchemaVersion=1; RunId=[guid]::NewGuid().ToString('D'); Revision=0; Intent='NewServer'
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
    foreach($name in @('NodeStore.psm1','LineStore.psm1','ProbePath.psm1','CandidateProbe.psm1','ProtocolComparison.psm1','ProtocolSelection.psm1','DeploymentStore.psm1','ServerRegistry.psm1','DeploymentFlow.psm1','Worker.ps1')) {
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

try {
    Check ($PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -eq 1 -and $PSVersionTable.PSEdition -eq 'Desktop') 'Windows PowerShell 5.1 Desktop executes this test'
    $env:PSModulePath=Join-Path $PSHOME 'Modules'
    if($BarrierOnly -and $CoreMatrixOnly){throw 'Select BarrierOnly or CoreMatrixOnly, not both'}
    $sourceBefore=ReadSourceHashes
    if($CoreMatrixOnly) {
        $archive=Join-Path $reportDirectory 'probe-workflow-integration-full-before-run-null.json'
        if([IO.File]::Exists($archive)) {
            $old=ReadJson $archive
            $historicalFull=[ordered]@{Path=$archive;SHA256=(Hash $archive);Passed=$old.Passed;PassedCount=$old.PassedCount;ExecutedAtUtc=$old.ExecutedAtUtc;TestSHA256=$old.TestSHA256;VersionScope='Historical full run loaded modules before the final Advance/Sync local run initialization fix; not full coverage of current SourceSHA256.'}
        }
    }
    foreach($entry in @(@('Nodes','NodeStore'),@('Lines','LineStore'),@('Path','ProbePath'),@('Candidate','CandidateProbe'),@('Comparison','ProtocolComparison'),@('Selection','ProtocolSelection'),@('Store','DeploymentStore'),@('Registry','ServerRegistry'),@('Flow','DeploymentFlow'))) {
        $modules[$entry[0]]=Import-Module (Join-Path $PackageRoot ($entry[1]+'.psm1')) -PassThru -DisableNameChecking
    }
    $state.FlowModule=$modules.Flow
    foreach($pair in @(@('Comparison','Invoke-TCProtocolComparison'),@('Comparison','Prepare-TCProtocolComparisonBinding'),
        @('Flow','Test-TCDeploymentProfiles'),@('Flow','Invoke-TCDeploymentProtocolComparison'),@('Flow','Update-TCDeploymentProbeProgress'),
        @('Flow','Set-TCDeploymentSession'),@('Flow','Invoke-TCDeploymentAdvance'),@('Flow','Sync-TCDeploymentRun'),@('Registry','Open-TCServerTaskLease'),
        @('Lines','Prepare-TCLineProbeBindings'),@('Path','Get-TCProbePathAssessment'),@('Selection','ConvertTo-TCProtocolEvidence'),@('Selection','Get-TCProtocolRecommendation'))) {
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
            function script:Start-TCDeploymentRemote {$script:Workflow.ForbiddenCalls++; throw 'Remote/SSH operation forbidden'}
            function script:Start-Process {$script:Workflow.ForbiddenCalls++; throw 'Process/Worker startup forbidden'}
            function script:Invoke-WebRequest {$script:Workflow.ForbiddenCalls++; throw 'Real HTTP forbidden'}
            function script:Invoke-RestMethod {$script:Workflow.ForbiddenCalls++; throw 'Real HTTP forbidden'}
        } $state
    }
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
            $duration=if($script:Workflow.CurrentProfile -ceq 'Udp'){140}else{45}
            if($Target.Name -ceq 'DomainDnsHttps'){$duration+=25}
            $status=if($Target.Trace){'Passed'}else{'UserVerificationRequired'}
            $code=if($Target.Trace){'HttpsReached'}else{'BrowserChallenge'}
            $tls=$true; $ip=if($Target.Trace){'192.0.2.40'}else{$null}; $http=if($Target.Trace){200}else{403}
            if($script:Workflow.Mode -eq 'HttpTimeout' -and $script:Workflow.HttpCount -eq 1){$status='Failed';$code='ProbeTimeout';$tls=$false;$ip=$null;$http=$null;$duration=6000}
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

    if($CoreMatrixOnly){InvokeDirectLeaseMatrix}
    if(-not $BarrierOnly) {
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

    if(-not $CoreMatrixOnly) {
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

    if(-not $CoreMatrixOnly) {
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
    foreach($key in @($originalCore.Keys | Sort-Object)) {
        $parts=$key.Split(':'); $definition=& $modules[$parts[0]] {param($n) (Get-Command $n).Definition} $parts[1]
        Check ((TextHash $definition) -ceq $originalCore[$key]) ($key+' production implementation was never replaced')
    }
    Check ($state.ForbiddenCalls -eq 0) 'no real Worker/engine run, SSH, HTTP or process-control boundary was invoked'
    Check ($state.NativeCalls.Count -gt 0 -and @($state.NativeCalls | Where-Object {$_.Command -notin @('check','pubkey')}).Count -eq 0 -and @($state.NativeCalls | Where-Object ExitCode -ne 0).Count -eq 0) 'all actual native calls are successful fixture-only sing-box check or wg pubkey'
    Check (@($state.NativeCalls | Where-Object {$_.Command -ceq 'check' -and $_.Config -match '\\.staging\\'}).Count -ge 8 -and @($state.NativeCalls | Where-Object {$_.Command -ceq 'check' -and $_.Config -match 'candidate\.private\.json$'}).Count -ge 6) 'real checks covered published immutable bindings and effective HTTP probe configs'
    Check (@($state.Writes | Where-Object {-not ([IO.Path]::GetFullPath($_).StartsWith($work.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase))}).Count -eq 0) 'all observed application writes stayed under the sole restricted fixture root'
    Check (@(Get-ChildItem -LiteralPath $work -Recurse -File -Filter 'candidate.private.json').Count -eq 0) 'real probe finalization removed all temporary authenticated private configs'
    $passed=$true
} catch {
    $failure=[pscustomobject]@{Case=$script:Case;Assertion=$script:LastAssertion;Message=$_.Exception.Message;ExceptionType=$_.Exception.GetType().FullName;SourceLine=$_.InvocationInfo.ScriptLineNumber;Stack=$_.ScriptStackTrace}
    Note ('FAIL ['+$script:Case+'] '+$_.Exception.Message)
} finally {
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
        PackageRoot=$PackageRoot; TestSHA256=(Hash $PSCommandPath); BarrierOnly=[bool]$BarrierOnly; CoreMatrixOnly=[bool]$CoreMatrixOnly; FixtureRoot=$work; FixtureRemoved=$removed
        Scope=$(if($CoreMatrixOnly){'Current-source minimum core matrix: real direct-API leases with caller-run contamination/lock failures/archive guards, full prepared comparison and same-run recheck; historical full run is linked separately.'}else{'Offline cross-module integration; engine/process lifecycle and public networking not exercised'})
        SourceSHA256=$sourceBefore; SourceSHA256After=$sourceAfter; SourcesStable=((Json $sourceBefore) -ceq (Json $sourceAfter)); HistoricalFullReport=$historicalFull
        RealModules=@('NodeStore','LineStore','ProbePath','CandidateProbe sampling/assessment/finalization','ProtocolComparison','ProtocolSelection','DeploymentFlow','DeploymentStore','ServerRegistry')
        ReplacedBoundaries=@('ProbePath.Read-TCProbeNetworkState','ProbePath owned socket/ETW observations and listener ownership','CandidateProbe HTTP responses; offline HTTP delegate omits engine startup')
        Safety=[ordered]@{RealWorkerCalls=0;RealNetworkRequests=0;ForbiddenBoundaryCalls=$state.ForbiddenCalls;ApplicationWriteCount=$state.Writes.Count;UniqueRestrictedRoot=$true;ProcessOwnershipSimulated=$true;NativeCheckCount=@($state.NativeCalls | Where-Object Command -ceq 'check').Count;NativePubkeyCount=@($state.NativeCalls | Where-Object Command -ceq 'pubkey').Count}
        CandidateSourceSHA256=$state.AdapterSourceSHA256; CandidateSourceRanges=$state.AdapterRanges
        CoreDefinitionSHA256=$originalCore; Assertions=@($checks.ToArray()); Cases=@($caseReports.ToArray()); NativeCalls=@($state.NativeCalls.ToArray()); Failure=$failure
        DirectLeaseMatrix=@($state.LeaseMatrix.ToArray())
    }
    $json=ConvertTo-Json -InputObject $report -Depth 90
    foreach($secret in $secrets){if($json.Contains($secret)){throw 'Report would expose a fixture private key'}}
    [IO.File]::WriteAllText($reportPath,$json,(New-Object Text.UTF8Encoding($false)))
    $log.Add(('RESULT Passed={0} Checks={1} FixtureRemoved={2} NativeChecks={3} Pubkeys={4} ForbiddenCalls={5}' -f $passed,$checks.Count,$removed,$report.Safety.NativeCheckCount,$report.Safety.NativePubkeyCount,$state.ForbiddenCalls))
    [IO.File]::WriteAllLines($logPath,$log,(New-Object Text.UTF8Encoding($false)))
}
Write-Output ('Probe workflow integration: Passed={0}; assertions={1}; fixture removed={2}; report={3}' -f $passed,$checks.Count,$removed,$reportPath)
if(-not $passed){exit 1}
