#requires -Version 5.1
# Isolated stores only. Real wg pubkey / sing-box check; no engine run or session.
[CmdletBinding()]param([string]$ReportPath='')
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';Set-StrictMode -Version 2
$package=Split-Path $PSScriptRoot -Parent
if(-not $ReportPath){$ReportPath=Join-Path (Split-Path (Split-Path $package -Parent) -Parent) 'reports\release-0.10.2\auto-transport-tests.json'}
$nodes=Import-Module (Join-Path $package 'NodeStore.psm1') -Force -PassThru -DisableNameChecking
$auto=Import-Module (Join-Path $package 'AutoTransport.psm1') -Force -PassThru -DisableNameChecking
$work=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('TC-AutoTransport-'+[guid]::NewGuid().ToString('N'))
$engine=Join-Path $package 'assets\sing-box.exe';$wg=Join-Path $package 'assets\wg.exe'
$checks=New-Object 'Collections.Generic.List[string]';$passed=$false;$failure=$null
$nativeOriginal=& $nodes {$script:TCNativeRunner}
& $nodes {
    $script:AutoTestNative=${function:Invoke-TCProcess};$script:AutoTestCalls=New-Object 'Collections.Generic.List[object]';$script:AutoTestDiagnostic=$null
    function script:Get-CimInstance {param($ClassName,$Filter,$ErrorAction)@()}
    $script:AutoTestOriginalStop=${function:Stop-TCOperation}
    function script:Stop-TCOperation {
        param($Record,$Message)
        $script:AutoTestDiagnostic=[pscustomobject]@{ExceptionType=$Record.Exception.GetType().FullName;Line=$Record.InvocationInfo.ScriptLineNumber;Stack=$Record.ScriptStackTrace}
        & $script:AutoTestOriginalStop $Record $Message
    }
    $script:TCNativeRunner={param($FilePath,$ArgumentList,$InputText,$TimeoutMilliseconds)
        if($ArgumentList[0] -cnotin @('pubkey','check')){throw 'Auto test forbids all runtime commands.'}
        $r=& $script:AutoTestNative -FilePath $FilePath -ArgumentList $ArgumentList -InputText $InputText -TimeoutMilliseconds $TimeoutMilliseconds
        $script:AutoTestCalls.Add([pscustomobject]@{Command=$ArgumentList[0];Stage=($ArgumentList[0] -ceq 'check' -and $ArgumentList[-1].Contains('\.staging\'));ExitCode=$r.ExitCode})
        $r
    }
}
function Check {param([bool]$Ok,[string]$Label)if(-not $Ok){throw ('Auto transport assertion: '+$Label)};$checks.Add($Label)}
function Reject {param([scriptblock]$Body,[string]$Label)$caught=$false;try{$null=& $Body}catch{$caught=$true};Check $caught $Label}
function ReadJson {param($p)$raw=[IO.File]::ReadAllText($p);if((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')){ConvertFrom-Json -InputObject $raw -DateKind String}else{ConvertFrom-Json -InputObject $raw}}
function WriteJson {param($p,$v)[IO.File]::WriteAllText($p,(ConvertTo-Json -InputObject $v -Depth 40),(New-Object Text.UTF8Encoding($false)))}
function Hash {param($p)(Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash}
function Clone {param($v)ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $v -Depth 40)}
function Canonical {
    param($v)
    if($null -eq $v -or $v -is [string] -or $v -is [ValueType]){return $v}
    if($v -is [Collections.IDictionary]){$o=[ordered]@{};foreach($k in @($v.Keys|Sort-Object)){$o[$k]=Canonical $v[$k]};return $o}
    if($v -is [Collections.IEnumerable]){$o=@();foreach($item in $v){$o+=,(Canonical $item)};return ,$o}
    $o=[ordered]@{};foreach($k in @($v.PSObject.Properties.Name|Sort-Object)){$o[$k]=Canonical $v.$k};$o
}
function Json {param($v)ConvertTo-Json -InputObject (Canonical $v) -Depth 40 -Compress}
function Snapshot {param($dir)Json @(Get-ChildItem -LiteralPath $dir -File -Recurse -Force|Sort-Object FullName|ForEach-Object {[ordered]@{Path=$_.FullName;Hash=(Hash $_.FullName);Acl=(Get-Acl -LiteralPath $_.FullName).Sddl}})}
function NewKey {
    $b=New-Object byte[] 32;$rng=[Security.Cryptography.RandomNumberGenerator]::Create()
    try{$rng.GetBytes($b);$b[0]=$b[0] -band 248;$b[31]=($b[31] -band 127) -bor 64;[Convert]::ToBase64String($b)}finally{$rng.Dispose();[Array]::Clear($b,0,$b.Length)}
}
function NewFixture {
    param([string]$Slot,[string]$Name='Same display name',$Identity=$null)
    $dir=Join-Path $work $Slot;& $nodes {param($p)New-TCPrivateDirectory $p} $dir
    $private=if($Identity){$Identity.Private}else{NewKey};$serverPrivate=if($Identity){$Identity.ServerPrivate}else{NewKey}
    $public=& $nodes {param($e,$k)Invoke-TCNative -FilePath $e -ArgumentList @('pubkey') -InputText $k} $wg $serverPrivate
    $conf=Join-Path $dir 'client.conf';$program=Join-Path $dir 'NinjaTrader.exe';[IO.File]::WriteAllText($program,'inert')
    $providerDir=Join-Path $dir 'Provider';& $nodes {param($p)New-TCPrivateDirectory $p} $providerDir
    $providerProgram=Join-Path $providerDir 'fixture-client.exe';[IO.File]::WriteAllText($providerProgram,'inert')
    $provider=[pscustomobject]@{id=[guid]::NewGuid().ToString();slot=1;kind='custom';name='fixture provider';directory=$providerDir;extraDirectories=@();programPaths=@($providerProgram);dailyPort=18990;tradePort=18991;httpPort=$null;pacPort=$null;bootstrapDomains=@('provider.example.com');settingsDirectory=$null}
    [IO.File]::WriteAllText($conf,("[Interface]`nPrivateKey = $private`nAddress = 10.78.0.4/24`n[Peer]`nPublicKey = $($public.StandardOutput.Trim())`nEndpoint = 192.0.2.10:51820`nAllowedIPs = 0.0.0.0/0`nPersistentKeepalive = 25`n"),(New-Object Text.UTF8Encoding($false)))
    $store=Join-Path $dir 'Product';$n=Import-TCWireGuard -Root $store -Path $conf -Name $Name -EnginePath $engine -WgPath $wg -TradeProgramPaths @($program) -DirectDnsIPv4 '192.168.100.1' -Providers @($provider)
    $m=ReadJson $n.manifestPath
    [pscustomobject]@{Root=$dir;Store=$store;Node=$n;Manifest=$m;Private=$private;ServerPrivate=$serverPrivate}
}
function Envelope {param($f)[pscustomobject]@{Kind='TradeChannel.TransportInfo';Status='Available';NodeId=[guid]::NewGuid().ToString();RemoteOwnerId=[guid]::NewGuid().ToString();ServerPublicKey=$f.Manifest.ServerPublicKey;ClientPublicKey=$f.Manifest.ClientPublicKey;ClientAddress='10.78.0.4/32';Transport=[pscustomobject]@{Type='tcp-reality';Server='192.0.2.10';Port=443;Uuid='aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';RealityPublicKey='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';RealityShortId='1234567890abcdef';ServerName='www.bing.com'}}}
try{
    & $nodes {param($p)New-TCPrivateDirectory $p} $work
    foreach($p in @((Join-Path $package 'AutoTransport.psm1'),$PSCommandPath)){
        $tokens=$null;$errors=$null;$null=[Management.Automation.Language.Parser]::ParseFile($p,[ref]$tokens,[ref]$errors);Check ($errors.Count -eq 0) ('Parser '+[IO.Path]::GetFileName($p))
    }
    Check (@(Get-Command -Module AutoTransport).Count -eq 3) 'Three public functions'
    $f=NewFixture 'source';$info=Envelope $f
    # Actual production legacy shape: /32 manifest, single probe, no users.
    $f.Manifest.ClientAddress='10.78.0.4/32';$p=ReadJson $f.Manifest.ProbePath;$p.inbounds[0].PSObject.Properties.Remove('users');WriteJson $f.Manifest.ProbePath $p
    $f.Manifest.ProbeSHA256=Hash $f.Manifest.ProbePath;WriteJson $f.Node.manifestPath $f.Manifest
    WriteJson (Join-Path $f.Root 'deployment.json') @{ManifestPath=$f.Node.manifestPath;Stage='Active'}
    WriteJson (Join-Path $f.Root 'runtime.json') @{ManifestPath=$f.Node.manifestPath;State='Running';EnginePID=123456;CleanupError=$false}
    WriteJson (Join-Path $f.Root 'ui-preferences.json') @{NodeId=$f.Node.id;StartupMode='rule';Transport='Udp';AutoConnect=$false}
    $jobs=Join-Path $f.Root 'linux-jobs';& $nodes {param($p)New-TCPrivateDirectory $p;New-TCPrivateDirectory (Join-Path $p 'old')} $jobs
    WriteJson (Join-Path $jobs 'old\job.json') @{SchemaVersion=1;Connection=@{Host='192.0.2.10';Port=22;User='root';IdentityFile=''}}
    $baseline=Snapshot $f.Root;$sourceBefore=Snapshot (Split-Path $f.Node.manifestPath -Parent);$recordBefore=Json $f.Node
    $ctx=Get-TCTransportPreparation -Root $f.Root -Id $f.Node.id
    Check ($ctx.Active -and -not $ctx.HasSettings -and $ctx.NeedsAuthentication -and $ctx.ClientAddress -ceq '10.78.0.4') 'Legacy production context supports active /32 identity and probe without users'
    Check ($ctx.Connection.Unverified -and $ctx.Connection.Source -ceq 'LegacyJob' -and -not $ctx.ServerId -and -not $ctx.RemoteOwnerId -and -not $ctx.RemoteNodeId) 'Old matching host is only an unverified login suggestion'
    Check (-not (Json $ctx).Contains($info.Transport.Uuid) -and -not (Json $ctx).Contains($f.Private) -and -not $ctx.PSObject.Properties['Transport']) 'Preparation contains no UUID/private key/transport settings'
    Check ((Snapshot $f.Root) -ceq $baseline) 'Get preserves every file hash and ACL without creating locks'
    $missing=Join-Path $work 'missing';Reject {Get-TCTransportPreparation -Root $missing -Id $f.Node.id} 'Missing store rejected read-only';Check (-not [IO.Directory]::Exists($missing)) 'Get never initializes missing roots'
    foreach($case in @('server-key','client-key','address','host','uuid','status')){
        $bad=Clone $info
        switch($case){'server-key'{$bad.ServerPublicKey=$f.Manifest.ClientPublicKey};'client-key'{$bad.ClientPublicKey=$f.Manifest.ServerPublicKey};'address'{$bad.ClientAddress='10.78.0.99/32'};'host'{$bad.Transport.Server='192.0.2.99'};'uuid'{$bad.Transport.Uuid='not-a-uuid'};'status'{$bad.Status='Unavailable'}}
        Reject {New-TCAutomaticTransportCandidate -Root $f.Root -Id $f.Node.id -TransportInfo $bad} ('Reject wrong '+$case)
    }
    Check ((Snapshot $f.Root) -ceq $baseline) 'Rejected envelopes preserve source/deployment/preferences/index'
    $depHash=Hash (Join-Path $f.Root 'deployment.json');$prefHash=Hash (Join-Path $f.Root 'ui-preferences.json')
    $candidate=New-TCAutomaticTransportCandidate -Root $f.Root -Id $f.Node.id -TransportInfo $info
    $m=ReadJson $candidate.ManifestPath;$cfg=ReadJson $m.CandidatePath;$probe=ReadJson $m.ProbePath
    Check ($candidate.Id -cne $f.Node.id -and $candidate.Status -ceq 'ReadyInactive' -and $candidate.Name -ceq ($f.Node.name+' TCP备用')) 'Distinct independently indexed TCP sibling'
    Check (-not $candidate.CurrentNetworkChanged -and -not $candidate.Activated -and $candidate.ProbeRequiresInactiveIdentity -and $candidate.SourceActive) 'Active source prepares without activation or parallel identity probe'
    Check ((Snapshot (Split-Path $f.Node.manifestPath -Parent)) -ceq $sourceBefore -and (Hash (Join-Path $f.Root 'deployment.json')) -ceq $depHash -and (Hash (Join-Path $f.Root 'ui-preferences.json')) -ceq $prefHash) 'Source manifest/assets and current deployment/preferences preserved'
    $idx=ReadJson (Join-Path $f.Store 'index.json');$original=@($idx.nodes|Where-Object {$_.id -ceq $f.Node.id})[0];$sibling=@($idx.nodes|Where-Object {$_.id -ceq $candidate.Id})[0]
    Check ((Json $original) -ceq $recordBefore -and $sibling.kind -ceq 'wireguard' -and $sibling.status -ceq 'CandidateOnly' -and $sibling.endpoint -ceq $f.Node.endpoint) 'Original index record unchanged; sibling retains WireGuard endpoint'
    Check ($m.nodeGuid -ceq $candidate.Id -and $m.node_id -ceq $candidate.Id -and $m.AutoTransportSourceNodeId -ceq $f.Node.id -and $m.SourceConfigSHA256 -ceq $f.Manifest.CandidateSHA256 -and $m.TCPBindingDigest.Length -eq 64) 'New node identity and exact source/binding provenance'
    foreach($field in @('ClientPublicKey','ServerPublicKey','ClientAddress','EnginePath','WgPath','TradeProgramPaths','Providers')){Check ((Json $m.$field) -ceq (Json $f.Manifest.$field)) ('Preserved manifest '+$field)}
    $cfg.endpoints[0].PSObject.Properties.Remove('detour');$cfg.outbounds=@($cfg.outbounds|Where-Object {$_.tag -cne 'tc-transport'})
    Check ((Json $cfg) -ceq (Json (ReadJson $f.Manifest.CandidatePath))) 'All original candidate programs/rules/providers/DNS/identity preserved'
    $probe.endpoints[0].PSObject.Properties.Remove('detour');$probe.outbounds=@($probe.outbounds|Where-Object {$_.tag -cne 'tc-transport'});$probe.inbounds[0].PSObject.Properties.Remove('users')
    Check ((Json $probe) -ceq (Json (ReadJson $f.Manifest.ProbePath))) 'Legacy probe copied with only TCP binding and local authentication added'
    Check ($m.CandidateSHA256 -ceq (Hash $m.CandidatePath) -and $m.ProbeSHA256 -ceq (Hash $m.ProbePath)) 'New candidate/probe hashes match'
    foreach($path in @((Split-Path $candidate.ManifestPath -Parent),$candidate.ManifestPath,$m.CandidatePath,$m.ProbePath)){
        $acl=Get-Acl -LiteralPath $path;$sids=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])|ForEach-Object {$_.IdentityReference.Value}|Select-Object -Unique)
        Check ($acl.AreAccessRulesProtected -and $sids.Count -eq 2 -and $sids -contains 'S-1-5-18' -and $sids -contains 'S-1-5-32-544') ('Restricted ACL '+[IO.Path]::GetFileName($path))
    }
    $newBaseline=Snapshot $f.Root;$again=New-TCAutomaticTransportCandidate -Root $f.Root -Id $f.Node.id -TransportInfo $info
    Check ($again.Reused -and $again.Id -ceq $candidate.Id -and (Snapshot $f.Root) -ceq $newBaseline) 'Repeated click reuses exact checked sibling without rewriting store'
    $ctx=Get-TCTransportPreparation -Root $f.Root -Id $f.Node.id;$saved=Get-TCSavedTransportInfo -Root $f.Root -Id $f.Node.id
    Check ($ctx.HasSettings -and -not $ctx.NeedsAuthentication -and $ctx.SettingsSource -ceq 'AutoTransportSibling' -and $saved.Kind -ceq 'TradeChannel.TransportInfo') 'Trusted local envelope recovered for UI saved fast path'
    $savedAgain=New-TCAutomaticTransportCandidate -Root $f.Root -Id $f.Node.id -TransportInfo $saved;Check ($savedAgain.Reused -and $savedAgain.Id -ceq $candidate.Id) 'Saved envelope has canonical identical TCP binding digest'
    # Same name and same keys in another node do not borrow the source's sibling.
    $conf=Join-Path $f.Root 'client.conf';$second=Import-TCWireGuard -Root $f.Store -Path $conf -Name $f.Node.name -EnginePath $engine -WgPath $wg -TradeProgramPaths @() -DirectDnsIPv4 '192.168.100.1'
    $secondCtx=Get-TCTransportPreparation -Root $f.Root -Id $second.id;Check (-not $secondCtx.HasSettings) 'Same display name and same key do not collide with another source ID'
    $secondNew=New-TCAutomaticTransportCandidate -Root $f.Root -Id $second.id -TransportInfo $info;Check ($secondNew.Id -cne $candidate.Id -and -not $secondNew.Reused) 'Idempotency includes source node ID'
    # Real native rejection, not a success stub or mocked exit code.
    $fail=NewFixture 'failure';$failInfo=Envelope $fail;$broken=ReadJson $fail.Manifest.CandidatePath;$broken|Add-Member NoteProperty fixture_invalid_field $true
    WriteJson $fail.Manifest.CandidatePath $broken;$fail.Manifest.CandidateSHA256=Hash $fail.Manifest.CandidatePath;WriteJson $fail.Node.manifestPath $fail.Manifest
    $failBefore=Snapshot $fail.Root;Reject {New-TCAutomaticTransportCandidate -Root $fail.Root -Id $fail.Node.id -TransportInfo $failInfo} 'Actual sing-box check rejects invalid staged configuration'
    Check ((Snapshot $fail.Root) -ceq $failBefore -and @(Get-ChildItem -LiteralPath (Join-Path $fail.Store '.staging') -Force).Count -eq 0) 'Native check failure preserves source/index and removes staging'
    $registry=Join-Path $fail.Root 'servers';& $nodes {param($p)New-TCPrivateDirectory $p} $registry
    $server=[pscustomobject]@{LocalRecordId=[guid]::NewGuid().ToString();RemoteOwnerId=$failInfo.RemoteOwnerId;NodeId=$failInfo.NodeId;ServerPublicKey=$fail.Manifest.ServerPublicKey;LinkedNodeIds=@($fail.Node.id);Endpoints=@('192.0.2.10:51820');Connection=@{Host='192.0.2.10';Port=22;User='root';IdentityFile=''}}
    WriteJson (Join-Path $registry 'registry.json') @{SchemaVersion=1;Servers=@($server)}
    $bound=Get-TCTransportPreparation -Root $fail.Root -Id $fail.Node.id
    Check ($bound.ServerId -ceq $server.LocalRecordId -and $bound.RemoteOwnerId -ceq $server.RemoteOwnerId -and $bound.RemoteNodeId -ceq $server.NodeId -and -not $bound.Connection.Unverified) 'Registry exact binding exposes known remote identity in context'
    $bad=Clone $failInfo;$bad.RemoteOwnerId=[guid]::NewGuid().ToString();Reject {New-TCAutomaticTransportCandidate -Root $fail.Root -Id $fail.Node.id -TransportInfo $bad} 'Known remote owner mismatch rejected'
    $bad=Clone $failInfo;$bad.NodeId=[guid]::NewGuid().ToString();Reject {New-TCAutomaticTransportCandidate -Root $fail.Root -Id $fail.Node.id -TransportInfo $bad} 'Known remote node mismatch rejected'
    $server.ServerPublicKey=$fail.Manifest.ClientPublicKey;WriteJson (Join-Path $registry 'registry.json') @{SchemaVersion=1;Servers=@($server)}
    Reject {Get-TCTransportPreparation -Root $fail.Root -Id $fail.Node.id} 'Linked different server public key cannot supply credentials'
    $server.LinkedNodeIds=@();WriteJson (Join-Path $registry 'registry.json') @{SchemaVersion=1;Servers=@($server)}
    $unrelated=Get-TCTransportPreparation -Root $fail.Root -Id $fail.Node.id;Check (-not $unrelated.Connection -and -not $unrelated.ServerId) 'Same host unrelated server registry credentials ignored'
    [IO.File]::AppendAllText($fail.Manifest.ProbePath,' ');Reject {Get-TCTransportPreparation -Root $fail.Root -Id $fail.Node.id} 'Probe hash tampering rejected read-only'
    $calls=@(& $nodes {$script:AutoTestCalls.ToArray()})
    Check (@($calls|Where-Object {$_.Command -ceq 'check' -and $_.Stage -and $_.ExitCode -eq 0}).Count -ge 4 -and @($calls|Where-Object {$_.Command -ceq 'check' -and $_.Stage -and $_.ExitCode -ne 0}).Count -ge 1) 'Real staged candidate/probe checks and real rejection recorded'
    $passed=$true
}catch{
    $failure=[pscustomobject]@{ExceptionType=$_.Exception.GetType().FullName;Line=$_.InvocationInfo.ScriptLineNumber;Diagnostic=(& $nodes {$script:AutoTestDiagnostic})}
}finally{
    $calls=@(& $nodes {$script:AutoTestCalls.ToArray()})
    & $nodes {param($runner)$script:TCNativeRunner=$runner;${function:Stop-TCOperation}=$script:AutoTestOriginalStop;Remove-Item Function:\Get-CimInstance -ErrorAction SilentlyContinue} $nativeOriginal
    $full=[IO.Path]::GetFullPath($work);$parent=[IO.Path]::GetFullPath([Environment]::GetFolderPath('LocalApplicationData')).TrimEnd('\')+'\'
    if(-not $full.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -cnotmatch '^TC-AutoTransport-[0-9a-f]{32}$'){throw 'Auto test cleanup rejected.'}
    if([IO.Directory]::Exists($full)){Remove-Item -LiteralPath $full -Recurse -Force}
    $report=[pscustomobject]@{Passed=$passed;Checks=$checks.Count;CheckNames=$checks.ToArray();PowerShell=$PSVersionTable.PSVersion.ToString();RealNetworkChanges=0;RealEngineRuns=0;ProductionWrites=0;NativeScope='wg pubkey; sing-box check';NativePubkeys=@($calls|Where-Object {$_.Command -ceq 'pubkey'}).Count;NativeChecks=@($calls|Where-Object {$_.Command -ceq 'check'}).Count;Failure=$failure}
    $reportFull=[IO.Path]::GetFullPath($ReportPath);$null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($reportFull));WriteJson $reportFull $report
}
if(-not $passed){$report|ConvertTo-Json -Depth 8;throw 'Auto transport tests failed; safe location details are in the specified report.'}
$report|Select-Object Passed,Checks,PowerShell,NativeChecks,RealNetworkChanges,RealEngineRuns,ProductionWrites
