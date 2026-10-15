#requires -Version 5.1
# Disposable fixtures only. No TUN/run, real identity, SSH or network mutation.
[CmdletBinding()]param([string]$ReportPath='',[switch]$BindingOnly)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';Set-StrictMode -Version 2
$env:PSModulePath=Join-Path $PSHOME 'Modules'
$package=Split-Path $PSScriptRoot -Parent
if(-not $ReportPath){$ReportPath=Join-Path (Split-Path (Split-Path $package -Parent) -Parent) 'reports\release0.15.0\regression\LineStore.json'}
$nodes=Import-Module (Join-Path $package 'NodeStore.psm1') -Force -PassThru -DisableNameChecking
$lines=Import-Module (Join-Path $package 'LineStore.psm1') -Force -PassThru -DisableNameChecking
$auto=Import-Module (Join-Path $package 'AutoTransport.psm1') -Force -PassThru -DisableNameChecking
# Provider validation disallows the OS Temp folder: use a unique disposable
# LocalAppData directory, restrict its ACL, and remove it after the test.
$work=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('TC-LineStore-'+[guid]::NewGuid().ToString('N'))
$engine=Join-Path $package 'assets\sing-box.exe';$wg=Join-Path $package 'assets\wg.exe'
$checks=New-Object 'Collections.Generic.List[string]';$passed=$false;$failure=$null
$nativeOriginal=& $nodes {$script:TCNativeRunner}
$lineClockOriginal=& $lines {$script:PreferenceClock};$protocol=$null;$protocolClockOriginal=$null
& $nodes {
    param($Work,$Engine,$Wg)
    $script:LineTestWork=$Work;$script:LineTestEngine=$Engine;$script:LineTestWg=$Wg
    $script:LineTestNative=${function:Invoke-TCProcess};$script:LineTestCalls=New-Object 'Collections.Generic.List[object]'
    $script:LineTestDiagnostic=$null;$script:LineTestBreakTcp=$false;$script:LineTestBreakMetadata=$false
    $script:LineTestLocks=New-Object 'Collections.Generic.List[string]'
    $script:LineTestOriginalStop=${function:Stop-TCOperation}
    $script:LineTestOriginalCim=Get-Item Function:\Get-CimInstance -ErrorAction SilentlyContinue
    $script:LineTestSession=${function:Open-TCNodeSessionLock};$script:LineTestStore=${function:Open-TCLock}
    $script:LineTestAtomic=${function:Write-TCAtomicJson}
    function script:Get-CimInstance {param($ClassName,$Filter,$ErrorAction)@()}
    function script:Stop-TCOperation {
        param($Record,$Message)
        $script:LineTestDiagnostic=[pscustomobject]@{ExceptionType=$Record.Exception.GetType().FullName;Line=$Record.InvocationInfo.ScriptLineNumber;Stack=$Record.ScriptStackTrace}
        & $script:LineTestOriginalStop $Record $Message
    }
    function script:Open-TCNodeSessionLock {
        param($StoreRoot)
        if(-not (Test-TCPathWithin $StoreRoot $script:LineTestWork)){throw 'Test refuses external session lock.'}
        $script:LineTestLocks.Add('session');& $script:LineTestSession $StoreRoot
    }
    function script:Open-TCLock {
        param($Root)
        if(-not (Test-TCPathWithin $Root $script:LineTestWork)){throw 'Test refuses external index lock.'}
        $script:LineTestLocks.Add('index');& $script:LineTestStore $Root
    }
    function script:Write-TCAtomicJson {
        param($Path,$Value,[switch]$NewOnly,[switch]$NoBom)
        if(-not (Test-TCPathWithin $Path $script:LineTestWork)){throw 'Test refuses non-fixture write.'}
        if($script:LineTestBreakMetadata -and [IO.Path]::GetFileName($Path) -like '.metadata-*'){throw 'Injected metadata publication failure.'}
        & $script:LineTestAtomic -Path $Path -Value $Value -NewOnly:$NewOnly -NoBom:$NoBom
    }
    $script:TCNativeRunner={param($FilePath,$ArgumentList,$InputText,$TimeoutMilliseconds)
        if($ArgumentList[0] -ceq 'pubkey'){
            if(-not (Test-TCSamePath $FilePath $script:LineTestWg)){throw 'Only bundled wg pubkey allowed.'}
        }elseif($ArgumentList[0] -ceq 'check'){
            if(-not (Test-TCSamePath $FilePath $script:LineTestEngine) -or -not (Test-TCPathWithin $ArgumentList[-1] $script:LineTestWork)){throw 'Only fixture sing-box check allowed.'}
            if($script:LineTestBreakTcp -and $ArgumentList[-1].Contains('\.staging\')){
                $cfg=Read-TCJson $ArgumentList[-1]
                if(@($cfg.outbounds|Where-Object {$_.tag -ceq 'tc-transport'}).Count){
                    $cfg|Add-Member NoteProperty fixture_invalid_field $true
                    & $script:LineTestAtomic $ArgumentList[-1] $cfg -NoBom
                }
            }
        }else{throw 'Tests forbid all runtime/network/native commands.'}
        $r=& $script:LineTestNative -FilePath $FilePath -ArgumentList $ArgumentList -InputText $InputText -TimeoutMilliseconds $TimeoutMilliseconds
        $script:LineTestCalls.Add([pscustomobject]@{Command=$ArgumentList[0];Stage=($ArgumentList[0] -ceq 'check' -and $ArgumentList[-1].Contains('\.staging\'));ExitCode=$r.ExitCode})
        $r
    }
} $work $engine $wg
function Check {param([bool]$Ok,[string]$Label)if(-not $Ok){throw ('Line store assertion: '+$Label)};$checks.Add($Label)}
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

function PreservedSnapshot {
    param($f)
    $paths=@((Join-Path $f.Store 'index.json'),$f.Node.manifestPath,$f.Manifest.CandidatePath,$f.Manifest.ProbePath)
    foreach($name in @('deployment.json','runtime.json','ui-preferences.json')){$path=Join-Path $f.Root $name;if([IO.File]::Exists($path)){$paths+=,$path}}
    Json @($paths|ForEach-Object {[ordered]@{Path=$_;Hash=(Hash $_);Acl=(Get-Acl -LiteralPath $_).Sddl}})
}
function LegacySibling {
    param($f,$Info,[string]$Name='Legacy backup')
    # Construct the exact 0.10.2 sibling shape without calling any old mutation API.
    $id=[guid]::NewGuid().ToString();$dir=Join-Path (Join-Path $f.Store 'nodes') $id
    & $nodes {param($p)New-TCPrivateDirectory $p} $dir
    $cfg=& $nodes {param($c,$t)Set-TCConfigurationTransport $c (ConvertTo-TCTransport $t)} (Clone (ReadJson $f.Manifest.CandidatePath)) $Info.Transport
    $probe=& $nodes {param($c,$t)Set-TCConfigurationTransport $c (ConvertTo-TCTransport $t)} (Clone (ReadJson $f.Manifest.ProbePath)) $Info.Transport
    $cp=Join-Path $dir 'dual-mode.json';$pp=Join-Path $dir 'probe.json';WriteJson $cp $cfg;WriteJson $pp $probe
    $m=Clone $f.Manifest
    # Assert-AutoEnvelope's canonical ordered transport / normalized IPv4 digest.
    $t=& $nodes {param($t)ConvertTo-TCTransport $t} $Info.Transport
    $canonical=[pscustomobject][ordered]@{Kind=$Info.Kind;Status=$Info.Status;NodeId=$Info.NodeId;RemoteOwnerId=$Info.RemoteOwnerId;ServerPublicKey=$Info.ServerPublicKey;ClientPublicKey=$Info.ClientPublicKey;ClientAddress='10.78.0.4';Transport=$t}
    $bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $canonical -Depth 40 -Compress));$sha=[Security.Cryptography.SHA256]::Create()
    try{$digest=([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','')}finally{$sha.Dispose();[Array]::Clear($bytes,0,$bytes.Length)}
    $fields=[ordered]@{node_id=$id;nodeGuid=$id;TCManagedNodeId=$id;CandidatePath=$cp;CandidateSHA256=(Hash $cp);ProbePath=$pp;ProbeSHA256=(Hash $pp);Transport=$t;TransportSettings=$t;AutoTransportSourceNodeId=$f.Node.id;AutoTransportSourceManifestPath=$f.Node.manifestPath;SourceConfigSHA256=$f.Manifest.CandidateSHA256;TCPBindingDigest=$digest;AutoTransportRemoteOwnerId=$Info.RemoteOwnerId;AutoTransportRemoteNodeId=$Info.NodeId}
    foreach($key in $fields.Keys){$m|Add-Member NoteProperty $key $fields[$key] -Force}
    $mp=Join-Path $dir 'manifest.json';WriteJson $mp $m
    $n=[pscustomobject]@{id=$id;name=$Name;kind='wireguard';endpoint=$f.Node.endpoint;manifestPath=$mp;registeredAt=[DateTimeOffset]::UtcNow.ToString('o');status='CandidateOnly'}
    $index=ReadJson (Join-Path $f.Store 'index.json');$index.nodes=@($index.nodes)+@($n);WriteJson (Join-Path $f.Store 'index.json') $index
    $n
}
function CheckCommittedProfilePointer {
    param($f,$Info,[string]$AliasId='')
    $originalView=Get-TCLine -Root $f.Root -Id $f.Node.id
    $recordPath=Join-Path (Join-Path (Join-Path $f.Store 'lines') $f.Node.id) 'line.json'
    $recordBefore=Hash $recordPath;$anchorBefore=Snapshot (Split-Path $f.Node.manifestPath -Parent)
    $indexPath=Join-Path $f.Store 'index.json';$index=ReadJson $indexPath
    $requests=@($f.Node.id);if($AliasId){$requests+=,$AliasId}
    foreach($mode in @('Udp','Tcp')){
        $target=@($originalView.Profiles|Where-Object {$_.Id -ceq $mode})[0]
        # Fixture-only equivalent of CT's reference commit; no runtime execution.
        @($index.nodes|Where-Object {$_.id -ceq $f.Node.id})[0].manifestPath=$target.ManifestPath
        WriteJson $indexPath $index
        WriteJson (Join-Path $f.Root 'deployment.json') @{ManifestPath=$target.ManifestPath;Stage='Active'}
        WriteJson (Join-Path $f.Root 'ui-preferences.json') @{NodeId=$f.Node.id;Transport=$mode}
        WriteJson (Join-Path $f.Root 'runtime.json') @{State='Running';ManifestPath=$target.ManifestPath;FixtureOnly=$true}
        $before=Snapshot $f.Root
        $cards=@(Get-TCLineCards -Root $f.Root)
        Check ($cards.Count -eq 1 -and $cards[0].LineId -ceq $f.Node.id -and $cards[0].manifestPath -ceq $target.ManifestPath -and $cards[0].CurrentProfileId -ceq $mode -and (Json $cards[0].AliasIds) -ceq (Json $originalView.AliasIds)) ('Committed '+$mode+' card keeps source LineId/aliases/current profile')
        foreach($id in $requests){
            $view=Get-TCLine -Root $f.Root -Id $id
            $profile=Get-TCLineProfile -Root $f.Root -Id $id -ProfileId $mode
            Check ((Json $view) -ceq (Json $originalView) -and $profile.ManifestPath -ceq $target.ManifestPath) ('Committed '+$mode+' Get/GetProfile stable '+$(if($id -ceq $f.Node.id){'source'}else{'alias'}))
            $registered=Register-TCLineProfiles -Root $f.Root -Id $id
            $again=Prepare-TCTcpLineProfile -Root $f.Root -Id $id -TransportInfo $Info
            $tcp=@($originalView.Profiles|Where-Object {$_.Id -ceq 'Tcp'})[0]
            Check ((Json $registered) -ceq (Json $originalView) -and $again.Reused -and $again.Id -ceq $f.Node.id -and $again.Revision -eq $tcp.Revision -and $again.ManifestPath -ceq $tcp.ManifestPath) ('Committed '+$mode+' Register/Prepare reuse anchored revision '+$(if($id -ceq $f.Node.id){'source'}else{'alias'}))
        }
        Check ((Snapshot $f.Root) -ceq $before -and (Hash $recordPath) -ceq $recordBefore -and (Snapshot (Split-Path $f.Node.manifestPath -Parent)) -ceq $anchorBefore) ('Committed '+$mode+' APIs preserve original anchor/record and CT references')
    }
}
function CheckApprovedCloneCurrent {
    param($f)
    $view=Get-TCLine -Root $f.Root -Id $f.Node.id
    $transactionRoot=Join-Path $f.Root 'connection-transactions'
    & $nodes {param($p)New-TCPrivateDirectory $p} $transactionRoot
    $immutableBefore=Snapshot (Join-Path (Join-Path (Join-Path $f.Store 'lines') $f.Node.id) 'profiles')
    foreach($mode in @('Udp','Tcp')){
        $profile=@($view.Profiles|Where-Object {$_.Id -ceq $mode})[0]
        $original=ReadJson $profile.ManifestPath;$tx=[guid]::NewGuid().ToString('N')
        $clone=Clone $original;$clone.DeploymentApproved=$true
        $clone|Add-Member NoteProperty TCTransactionId $tx -Force
        $clone|Add-Member NoteProperty TCProfileManifestPath $profile.ManifestPath -Force
        $clonePath=Join-Path $transactionRoot ($tx+'-approved.manifest');WriteJson $clonePath $clone
        $indexPath=Join-Path $f.Store 'index.json';$index=ReadJson $indexPath
        @($index.nodes|Where-Object {$_.id -ceq $f.Node.id})[0].manifestPath=$profile.ManifestPath;WriteJson $indexPath $index
        $dep=[pscustomobject]@{ManifestPath=$clonePath;ProfileManifestPath=$profile.ManifestPath;LineId=$view.LineId;ProfileId=$mode;CandidateSHA256=$profile.CandidateSHA256;TransactionId=$tx}
        $rt=[pscustomobject]@{State='Running';ManifestPath=$clonePath;ConfigPath=$original.CandidatePath;CandidateSHA256=$profile.CandidateSHA256;CleanupError=$false}
        $depPath=Join-Path $f.Root 'deployment.json';$rtPath=Join-Path $f.Root 'runtime.json'
        WriteJson $depPath $dep;WriteJson $rtPath $rt
        WriteJson (Join-Path $f.Root 'ui-preferences.json') @{NodeId=$view.LineId;ProfileId=$(if($mode -ceq 'Udp'){'Tcp'}else{'Udp'})}
        $before=Snapshot $f.Root;$cards=@(Get-TCLineCards -Root $f.Root)
        Check ($cards.Count -eq 1 -and $cards[0].CurrentProfileId -ceq $mode -and $cards[0].LineId -ceq $view.LineId -and (Json $cards[0].AliasIds) -ceq (Json $view.AliasIds) -and (Snapshot $f.Root) -ceq $before) ('Approved '+$mode+' runtime clone identified readonly despite opposite preference')
        # Real legacy runtime records may have ConfigPath but no explicit hash.
        $legacyRuntime=Clone $rt;$legacyRuntime.PSObject.Properties.Remove('CandidateSHA256');WriteJson $rtPath $legacyRuntime
        $cards=@(Get-TCLineCards -Root $f.Root);Check ($cards[0].CurrentProfileId -ceq $mode) ('Approved '+$mode+' runtime without redundant hash binds checked profile asset')
        WriteJson $rtPath $rt
        foreach($case in @('LineId','ProfileId','reference','candidate-hash','candidate-path','server-key','device-key','address','approval','transaction')){
            $bad=Clone $clone
            switch($case){
                'LineId'{$bad.TCLineId=[guid]::NewGuid().ToString()}
                'ProfileId'{$bad.TCProfileId=$(if($mode -ceq 'Udp'){'Tcp'}else{'Udp'})}
                'reference'{$bad.TCProfileManifestPath=$f.Node.manifestPath}
                'candidate-hash'{$bad.CandidateSHA256='0'*64}
                'candidate-path'{$bad.CandidatePath=$f.Manifest.CandidatePath}
                'server-key'{$bad.ServerPublicKey=$f.Manifest.ClientPublicKey}
                'device-key'{$bad.ClientPublicKey=$f.Manifest.ServerPublicKey}
                'address'{$bad.ClientAddress='10.78.0.99/32'}
                'approval'{$bad.DeploymentApproved=$false}
                'transaction'{$bad.TCTransactionId=[guid]::NewGuid().ToString('N')}
            }
            WriteJson $clonePath $bad;$before=Snapshot $f.Root;$cards=@(Get-TCLineCards -Root $f.Root)
            Check ($null -eq $cards[0].CurrentProfileId -and (Snapshot $f.Root) -ceq $before) ('Approved '+$mode+' clone rejects '+$case+' readonly')
        }
        WriteJson $clonePath $clone
        foreach($case in @('state','hash','config','cleanup')){
            $bad=Clone $rt
            switch($case){'state'{$bad.State='Stopped'};'hash'{$bad.CandidateSHA256='0'*64};'config'{$bad.ConfigPath=$f.Manifest.CandidatePath};'cleanup'{$bad.CleanupError=$true}}
            WriteJson $rtPath $bad;$cards=@(Get-TCLineCards -Root $f.Root)
            Check ($null -eq $cards[0].CurrentProfileId) ('Approved '+$mode+' runtime rejects '+$case+' instead of using deployment/preference')
        }
        WriteJson $rtPath $rt
        $bad=Clone $dep;$bad.ProfileId=$(if($mode -ceq 'Udp'){'Tcp'}else{'Udp'});WriteJson $depPath $bad
        $cards=@(Get-TCLineCards -Root $f.Root);Check ($null -eq $cards[0].CurrentProfileId) ('Approved '+$mode+' inconsistent deployment binding stays unknown')
        WriteJson $depPath $dep
        $outside=Join-Path $f.Root ($tx+'-approved.manifest');WriteJson $outside $clone
        $bad=Clone $rt;$bad.ManifestPath=$outside;WriteJson $rtPath $bad
        $cards=@(Get-TCLineCards -Root $f.Root);Check ($null -eq $cards[0].CurrentProfileId) ('Approved '+$mode+' identical clone outside transaction root stays unknown')
        [IO.File]::Delete($rtPath);$before=Snapshot $f.Root;$cards=@(Get-TCLineCards -Root $f.Root)
        Check ($null -eq $cards[0].CurrentProfileId -and (Snapshot $f.Root) -ceq $before) ('Approved '+$mode+' deployment/preferences alone never mark running')
        WriteJson $rtPath $rt
    }
    Check ((Snapshot (Join-Path (Join-Path (Join-Path $f.Store 'lines') $f.Node.id) 'profiles')) -ceq $immutableBefore) 'Approved clone recognition never changes immutable profiles'
}
try{
    & $nodes {param($p)New-TCPrivateDirectory $p} $work
    if($BindingOnly){
        $bf=NewFixture 'binding'
        # Shipped Hong Kong probes have only dns-hk; their main configuration
        # has dns-direct. The binding upgrade must handle both immutable inputs.
        $legacyProbe=ReadJson $bf.Manifest.ProbePath
        $legacyProbe.dns=[pscustomobject]@{servers=@([pscustomobject]@{tag='dns-hk';type='udp';server='1.1.1.1';detour='hk'});final='dns-hk'}
        $legacyProbe.route|Add-Member NoteProperty default_domain_resolver ([pscustomobject]@{server='dns-hk';strategy='ipv4_only'}) -Force
        WriteJson $bf.Manifest.ProbePath $legacyProbe;$bf.Manifest.ProbeSHA256=Hash $bf.Manifest.ProbePath;WriteJson $bf.Node.manifestPath $bf.Manifest
        $null=Register-TCLineProfiles -Root $bf.Root -Id $bf.Node.id
        $null=Prepare-TCTcpLineProfile -Root $bf.Root -Id $bf.Node.id -TransportInfo (Envelope $bf)
        $before=PreservedSnapshot $bf
        $pathModule=Import-Module (Join-Path $package 'ProbePath.psm1') -PassThru -DisableNameChecking
        $inventory=Get-TCProbeNetworkContext
        $physical=@($inventory.Interfaces|Where-Object {$_.Hardware -and $_.Status -eq 'Up' -and @($_.Addresses|Where-Object {$_.Family -eq 'InterNetwork' -and $_.State -eq 'Preferred'}).Count -eq 1})[0]
        $local=@($physical.Addresses|Where-Object {$_.Family -eq 'InterNetwork' -and $_.State -eq 'Preferred'})[0].Address
        & $pathModule {
            param($Interface)
            $i=$Interface|ConvertTo-Json -Depth 10|ConvertFrom-Json
            $gateway=@($i.Gateways|Where-Object {$_ -match '^\d+\.'})[0]
            $script:LineBindingFixture=[pscustomobject]@{Interfaces=@($i);Routes=@([pscustomobject]@{InterfaceIndex=$i.Index;DestinationPrefix='0.0.0.0/0';NextHop=$gateway;RouteMetric=10;AddressFamily='IPv4'})}
            function script:Read-TCProbeNetworkState {$script:LineBindingFixture}
        } $physical
        $old=Get-TCLine -Root $bf.Root -Id $bf.Node.id
        $bound=Prepare-TCLineProbeBindings -Root $bf.Root -Id $bf.Node.id
        Check ($bound.Prepared -and @($bound.Results|Where-Object Status -eq 'Prepared').Count -eq 2) ('Both profiles publish checked immutable interface bindings: '+($bound|ConvertTo-Json -Depth 4 -Compress))
        $new=Get-TCLine -Root $bf.Root -Id $bf.Node.id
        foreach($p in @($new.Profiles)){
            $m=ReadJson $p.ManifestPath;$c=ReadJson $m.CandidatePath;$pr=ReadJson $m.ProbePath
            if($p.Id -ceq 'Udp'){Check ($pr.dns.final -ceq 'dns-hk' -and @($pr.dns.servers|Where-Object {$_.tag -ceq 'dns-hk' -and $_.detour -ceq 'hk'}).Count -eq 1) 'Legacy probe keeps its DNS requests inside the tested tunnel'}
            Check ($m.ProbeBinding.Protocol -ceq $p.Id -and $m.ProbeBinding.InterfaceName -ceq $physical.Name) ('Binding identity matches '+$p.Id)
            foreach($value in @($c,$pr)){
                $outer=if($p.Id -ceq 'Tcp'){@($value.outbounds|Where-Object tag -ceq 'tc-transport')[0]}else{@($value.endpoints|Where-Object tag -ceq 'hk')[0]}
                Check ($null -ne $outer -and $outer.PSObject.Properties['bind_interface'] -and $outer.PSObject.Properties['inet4_bind_address'] -and $outer.PSObject.Properties['domain_resolver']) ('Bound outer fields exist for '+$p.Id+': '+$(if($outer){$outer.PSObject.Properties.Name -join ','}else{'missing outbound'}))
                Check ($outer.bind_interface -ceq $physical.Name -and $outer.inet4_bind_address -ceq $local -and $outer.domain_resolver.strategy -ceq 'ipv4_only') ('Saved '+$p.Id+' uses actual bound outer layer')
                $dns=@($value.dns.servers|Where-Object tag -ceq 'dns-direct')[0]
                Check ($dns.bind_interface -ceq $physical.Name -and $dns.inet4_bind_address -ceq $local -and $dns.server -ceq $m.ProbeBinding.BootstrapDns.Server) 'Bootstrap DNS uses same saved binding'
            }
        }
        Check ((PreservedSnapshot $bf) -ceq $before) 'Binding preserves source index config deployment and preferences'
        $stable=Snapshot $bf.Root;$repeat=Prepare-TCLineProbeBindings -Root $bf.Root -Id $bf.Node.id
        Check (-not $repeat.Prepared -and (Snapshot $bf.Root) -ceq $stable) 'Repeated identical binding is read-only reuse'
        $recordPath=Join-Path (Join-Path (Join-Path $bf.Store 'lines') $bf.Node.id) 'line.json'
        $record=ReadJson $recordPath;$udp=@($record.Profiles|Where-Object Id -ceq 'Udp')[0];$manifest=ReadJson $udp.ManifestPath
        $originalFiles=@(foreach($path in @($recordPath,$udp.ManifestPath,$manifest.ProbePath)){[pscustomobject]@{Path=$path;Bytes=[IO.File]::ReadAllBytes($path)}})
        try{
            $tampered=ReadJson $manifest.ProbePath;@($tampered.dns.servers|Where-Object tag -ceq 'dns-direct')[0].server='203.0.113.99'
            WriteJson $manifest.ProbePath $tampered;$manifest.ProbeSHA256=Hash $manifest.ProbePath;WriteJson $udp.ManifestPath $manifest
            $udp.ProbeSHA256=$manifest.ProbeSHA256;$udp.ManifestSHA256=Hash $udp.ManifestPath;WriteJson $recordPath $record
            Reject {Get-TCLine -Root $bf.Root -Id $bf.Node.id} 'Legacy DNS compatibility still rejects a different bootstrap server with rewritten file hashes'
            Check ((& $nodes {$script:LineTestDiagnostic.Stack}) -match 'Get-LinePolicyDigest') 'Different legacy bootstrap is rejected by policy provenance validation'
        }finally{foreach($entry in $originalFiles){[IO.File]::WriteAllBytes($entry.Path,$entry.Bytes)}}
        Check ((Snapshot $bf.Root) -ceq $stable) 'Bootstrap rejection fixture restores the original immutable files'
        # A stopped legacy index may still reference a previous immutable copy.
        $index=ReadJson (Join-Path $bf.Store 'index.json');$index.nodes[0].manifestPath=$old.Profiles[0].ManifestPath;WriteJson (Join-Path $bf.Store 'index.json') $index
        Check ((Get-TCLine -Root $bf.Root -Id $bf.Node.id).Profiles.Count -eq 2) 'Retained immutable reference still resolves original source anchor'
        & $pathModule {$script:LineBindingFixture.Routes[0].NextHop='192.0.2.254';$script:LineBindingFixture.Interfaces[0].Gateways=@('192.0.2.254')}
        $rebound=Prepare-TCLineProbeBindings -Root $bf.Root -Id $bf.Node.id
        Check ($rebound.Prepared -and @((Get-TCLine -Root $bf.Root -Id $bf.Node.id).Profiles).Count -eq 2) 'Changed underlay creates new copies without replacing old index reference'
        $passed=$true;return
    }
    foreach($p in @((Join-Path $package 'LineStore.psm1'),(Join-Path $package 'AutoTransport.psm1'),$PSCommandPath)){
        $b=[IO.File]::ReadAllBytes($p);Check ($b[0] -eq 239 -and $b[1] -eq 187 -and $b[2] -eq 191) ('UTF8 BOM '+[IO.Path]::GetFileName($p))
        $t=$null;$e=$null;$null=[Management.Automation.Language.Parser]::ParseFile($p,[ref]$t,[ref]$e);Check ($e.Count -eq 0) ('WinPS parser '+[IO.Path]::GetFileName($p))
    }
    Check (@(Get-Command -Module LineStore).Count -eq 10 -and @(Get-Command -Module AutoTransport).Count -eq 3) 'Public API exports'
    $f=NewFixture 'active';$info=Envelope $f
    $f.Manifest.ClientAddress='10.78.0.4/32';$probe=ReadJson $f.Manifest.ProbePath;$probe.inbounds[0].PSObject.Properties.Remove('users');WriteJson $f.Manifest.ProbePath $probe
    $f.Manifest.ProbeSHA256=Hash $f.Manifest.ProbePath;WriteJson $f.Node.manifestPath $f.Manifest
    WriteJson (Join-Path $f.Root 'deployment.json') @{ManifestPath=$f.Node.manifestPath;Stage='Active'}
    WriteJson (Join-Path $f.Root 'runtime.json') @{ManifestPath=$f.Node.manifestPath;State='Running';EnginePID=123456;CleanupError=$false}
    WriteJson (Join-Path $f.Root 'ui-preferences.json') @{NodeId=$f.Node.id;Transport='Udp';AutoConnect=$false}
    $before=Snapshot $f.Root;$preserved=PreservedSnapshot $f
    $cards=@(Get-TCLineCards -Root $f.Root);$view=Get-TCLine -Root $f.Root -Id $f.Node.id
    $ctx=Get-TCTransportPreparation -Root $f.Root -Id $f.Node.id
    Check ($cards.Count -eq 1 -and $cards[0].id -ceq $f.Node.id -and $cards[0].Profiles -is [array] -and $cards[0].CurrentProfileId -ceq 'Udp' -and $cards[0].MissingBackup) 'Readonly active UDP card / array contract'
    Check ($view.LineId -ceq $f.Node.id -and $view.SourceNodeId -ceq $f.Node.id -and $view.AliasIds -is [array] -and $ctx.Active -and -not $ctx.HasSettings) 'Stable source identity and Auto compatibility'
    Check ((Snapshot $f.Root) -ceq $before -and -not [IO.Directory]::Exists((Join-Path $f.Store 'lines'))) 'Get creates no directory/lock and changes no hash/ACL'
    $missing=Join-Path $work 'missing';Reject {Get-TCLineCards -Root $missing} 'Missing root rejected read-only';Check (-not [IO.Directory]::Exists($missing)) 'No missing root initialization'
    foreach($case in @('server-key','client-key','address','host','uuid','status','kind','port','reality-key','short-id','sni')){
        $bad=Clone $info
        switch($case){'server-key'{$bad.ServerPublicKey=$f.Manifest.ClientPublicKey};'client-key'{$bad.ClientPublicKey=$f.Manifest.ServerPublicKey};'address'{$bad.ClientAddress='10.78.0.99/32'};'host'{$bad.Transport.Server='192.0.2.99'};'uuid'{$bad.Transport.Uuid='bad'};'status'{$bad.Status='Unavailable'};'kind'{$bad.Kind='Untrusted'};'port'{$bad.Transport.Port=0};'reality-key'{$bad.Transport.RealityPublicKey='bad'};'short-id'{$bad.Transport.RealityShortId='x'};'sni'{$bad.Transport.ServerName='https://invalid'}}
        Reject {Prepare-TCTcpLineProfile -Root $f.Root -Id $f.Node.id -TransportInfo $bad} ('Reject envelope '+$case)
    }
    Check ((Snapshot $f.Root) -ceq $before) 'Invalid envelopes have no filesystem side effects'
    & $nodes {$script:LineTestLocks.Clear()}
    $registered=Register-TCLineProfiles -Root $f.Root -Id $f.Node.id
    Check ((Json $registered) -ceq (Json (Get-TCLine -Root $f.Root -Id $f.Node.id)) -and $registered.Revision -eq 1) 'Register returns Get-TCLine shape'
    Check ((Json @(& $nodes {$script:LineTestLocks.ToArray()})) -ceq (Json @('session','index'))) 'Session before index lock order'
    $baseline=Snapshot $f.Root;$again=Register-TCLineProfiles -Root $f.Root -Id $f.Node.id
    Check ((Snapshot $f.Root) -ceq $baseline -and $again.Revision -eq $registered.Revision) 'Register idempotent metadata/profile reuse'
    $candidate=New-TCAutomaticTransportCandidate -Root $f.Root -Id $f.Node.id -TransportInfo $info
    $view=Get-TCLine -Root $f.Root -Id $f.Node.id;$tcp=Get-TCLineProfile -Root $f.Root -Id $f.Node.id -ProfileId Tcp
    Check ($candidate.Id -ceq $f.Node.id -and $candidate.NodeId -ceq $f.Node.id -and $candidate.LineId -ceq $f.Node.id -and $candidate.ProfileId -ceq 'Tcp' -and -not $candidate.Reused) 'Auto adapter creates Tcp under stable line ID'
    Check ($candidate.SourceActive -and -not $candidate.Activated -and -not $candidate.CurrentNetworkChanged -and $candidate.ProbeRequiresInactiveIdentity) 'Active source preparation has no activation/parallel probe'
    Check ($view.Profiles -is [array] -and $view.Profiles.Count -eq 2 -and @($view.Profiles|Where-Object {$_.Id -cin @('Udp','Tcp')}).Count -eq 2) 'Single line contains complete Udp/Tcp profile array'
    Check ((PreservedSnapshot $f) -ceq $preserved -and (ReadJson (Join-Path $f.Store 'index.json')).schemaVersion -eq 1 -and (ReadJson (Join-Path $f.Store 'index.json')).nodes.Count -eq 1) 'Original assets/index/deployment/runtime/preferences unchanged'
    $recordPath=Join-Path (Join-Path (Join-Path $f.Store 'lines') $f.Node.id) 'line.json';$record=ReadJson $recordPath
    Check ($record.SchemaVersion -eq 2 -and $record.LineId -ceq $f.Node.id -and $record.PreferredProfileId -ceq 'Udp') 'Schema 2 record preserves preferred source profile'
    foreach($p in $view.Profiles){
        $m=ReadJson $p.ManifestPath;$cfg=ReadJson $m.CandidatePath;$pr=ReadJson $m.ProbePath
        Check ($p.CandidateSHA256 -ceq (Hash $m.CandidatePath) -and $m.ProbeSHA256 -ceq (Hash $m.ProbePath) -and $m.TCLineId -ceq $f.Node.id -and $m.TCProfileId -ceq $p.Id) ('Immutable '+$p.Id+' hash / line binding')
        $cfg=& $nodes {param($c)Set-TCConfigurationTransport $c $null} $cfg
        Check ((Json $cfg) -ceq (Json (ReadJson $f.Manifest.CandidatePath))) ('Preserve '+$p.Id+' keys/address/rules/providers')
        Check (@($pr.inbounds[0].users).Count -eq 1 -and $pr.inbounds[0].users[0].password.Length -ge 32) ('Legacy '+$p.Id+' probe authentication added only to copy')
        foreach($path in @((Split-Path $p.ManifestPath -Parent),$p.ManifestPath,$m.CandidatePath,$m.ProbePath)){
            $acl=Get-Acl -LiteralPath $path;$sids=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])|ForEach-Object {$_.IdentityReference.Value}|Select-Object -Unique)
            Check ($acl.AreAccessRulesProtected -and $sids.Count -eq 2 -and $sids -contains 'S-1-5-18' -and $sids -contains 'S-1-5-32-544') ('Restricted ACL '+$p.Id+' '+[IO.Path]::GetFileName($path))
        }
    }
    $baseline=Snapshot $f.Root;$again=Prepare-TCTcpLineProfile -Root $f.Root -Id $f.Node.id -TransportInfo $info
    $saved=Get-TCSavedTransportInfo -Root $f.Root -Id $f.Node.id;$ctx=Get-TCTransportPreparation -Root $f.Root -Id $f.Node.id
    Check ($again.Reused -and $again.Revision -eq $candidate.Revision -and $again.ManifestPath -ceq $candidate.ManifestPath -and (Snapshot $f.Root) -ceq $baseline) 'Repeated prepare reuses exact immutable revision without writes'
    Check ($saved.Kind -ceq 'TradeChannel.TransportInfo' -and $saved.Transport.Uuid -ceq $info.Transport.Uuid -and $ctx.HasSettings -and -not $ctx.NeedsAuthentication -and $ctx.SettingsSource -ceq 'LineProfile') 'Secret saved envelope and sanitized preparation compatibility'
    Check (-not (Json $ctx).Contains($info.Transport.Uuid) -and -not (Json $ctx).Contains($f.Private) -and -not $ctx.PSObject.Properties['Transport']) 'Preparation contains no UUID/key/secret envelope'
    $again=New-TCAutomaticTransportCandidate -Root $f.Root -Id $f.Node.id -TransportInfo $saved;Check $again.Reused 'Saved envelope canonical digest reuses profile'
    $badEvidence=@{CandidateSHA256=('0'*64);Status='Passed'};Reject {Set-TCLineProfileValidation -Root $f.Root -Id $f.Node.id -ProfileId Tcp -Validation $badEvidence} 'Validation hash mismatch rejected'
    Check ((Snapshot $f.Root) -ceq $baseline) 'Rejected evidence changes no profile or metadata'
    $evidence=@{CandidateSHA256=$tcp.CandidateSHA256;PathValidation='NotTested';ApplicationValidation='NotTested';Source='OfflineFixture';NetworkEnvironmentFingerprint='fixture-only'}
    $assetsBefore=Snapshot (Split-Path $tcp.ManifestPath -Parent)
    $validated=Set-TCLineProfileValidation -Root $f.Root -Id $f.Node.id -ProfileId Tcp -Validation $evidence
    Check ($validated.Validation.LineId -ceq $f.Node.id -and $validated.Validation.ProfileId -ceq 'Tcp' -and $validated.Validation.ServerPublicKey -ceq $f.Manifest.ServerPublicKey -and $validated.Validation.ClientPublicKey -ceq $f.Manifest.ClientPublicKey -and $validated.Validation.ClientAddress -ceq '10.78.0.4') 'Validation binds hash/server/device/address/profile without network'
    Check ((Snapshot (Split-Path $tcp.ManifestPath -Parent)) -ceq $assetsBefore -and (PreservedSnapshot $f) -ceq $preserved) 'Validation updates metadata only, immutable assets preserved'
    # Readers still work with all three mutation locks held; no reader lock side effects.
    $session=[IO.File]::Open((Join-Path $f.Root '.session.lock'),'Open','ReadWrite','None')
    $storeLock=[IO.File]::Open((Join-Path $f.Store '.store.lock'),'Open','ReadWrite','None')
    $lineLock=[IO.File]::Open((Join-Path (Split-Path $recordPath -Parent) '.line.lock'),'Open','ReadWrite','None')
    try{
        $v=Get-TCLine -Root $f.Root -Id $f.Node.id;Check ($v.Profiles.Count -eq 2) 'Get ignores held session/index/line mutation locks'
        & $nodes {$script:LineTestLocks.Clear()};Reject {Register-TCLineProfiles -Root $f.Root -Id $f.Node.id} 'Held session lock blocks register'
        Check ((Json @(& $nodes {$script:LineTestLocks.ToArray()})) -ceq (Json @('session'))) 'Busy session prevents index/line lock acquisition'
    }finally{$lineLock.Dispose();$storeLock.Dispose();$session.Dispose()}
    # Selection changes only metadata while the source is live. Real producer
    # evidence must bind the immutable manifest and its actual checked engine;
    # hand-filled Passed/eligible flags cannot establish an automatic default.
    $protocol=Import-Module (Join-Path $package 'ProtocolSelection.psm1') -PassThru -DisableNameChecking
    $protocolClockOriginal=& $protocol {$script:PreferenceClock}
    $selectionRecord=ReadJson $recordPath;$selectionProtected=PreservedSnapshot $f
    $network=[pscustomobject]@{Status='Available';Fingerprint=('C'*64)}
    foreach($profile in @((Get-TCLine -Root $f.Root -Id $f.Node.id).Profiles)){
        $manifest=ReadJson $profile.ManifestPath
        Check ((Hash $profile.ManifestPath) -ceq $profile.ManifestSHA256 -and (Hash $manifest.EnginePath) -ceq $manifest.EngineSHA256) ('Selection fixture binds actual '+$profile.Id+' manifest and engine')
        $raw=[pscustomobject]@{SchemaVersion=2;FixtureOnly=$true;Status='Passed';Code='CandidateReachabilityVerified';NodeId=$f.Node.id;ProfileId=$profile.Id;CheckedAtUtc=[DateTimeOffset]::UtcNow.ToString('o');CandidateHash=$profile.CandidateSHA256;ManifestHash=$profile.ManifestSHA256;EngineSHA256=$manifest.EngineSHA256;ForwardingPassed=$true;CleanupComplete=$true;ObservedExitIPv4='192.0.2.40';ExpectedExitIPv4='192.0.2.40';ExpectedExitSource='ServerVerifiedTlsTrace';NetworkFingerprint=$network.Fingerprint;PathEvidence=[pscustomobject]@{Kind='BoundInterfaceObserved';Verified=$true;EligibleForRecommendation=$true;NetworkFingerprint=$network.Fingerprint};Checks=@([pscustomobject]@{Name='AddressHttps';Status='Passed';Code='FixtureHttpsTraceVerified'},[pscustomobject]@{Name='DomainDnsHttps';Status='Passed';Code='FixtureDnsHttpsTraceVerified'});Samples=@();Metrics=$null;NetworkChanged=$false;ContextChanged=$false;CancellationRequested=$false}
        $ev=ConvertTo-TCProtocolEvidence -Result $raw -Profile $profile -NetworkContext $network
        Check ($ev.Origin -ceq 'Candidate' -and $ev.Status -ceq 'Passed' -and $ev.EligibleForAutomaticSelection -and $ev.Result.ManifestHash -ceq $profile.ManifestSHA256 -and $ev.EngineSHA256 -ceq $manifest.EngineSHA256) ('Real producer qualifies bound '+$profile.Id+' fixture evidence')
        $null=Set-TCLineProfileValidation -Root $f.Root -Id $f.Node.id -ProfileId $profile.Id -Validation $ev
    }
    $selectionLine=Get-TCLine -Root $f.Root -Id $f.Node.id
    $decision=Get-TCProtocolRecommendation -Profiles $selectionLine.Profiles -LineId $f.Node.id -NetworkContext $network
    Check (Test-TCProtocolRecommendationCurrent -Recommendation $decision -Profiles $selectionLine.Profiles -NetworkContext $network) 'Original producer recommendation qualifies against the stored evidence'
    $selectionLineForRestore=ReadJson $recordPath;$beforePublish=Snapshot $f.Root
    $forged=Clone $decision;$forged.Source='UserChoice'
    Reject {Set-TCLineRecommendation -Root $f.Root -Id $f.Node.id -Recommendation $forged -NetworkContext $network} 'Changing recommendation source cannot fabricate manual provenance'
    Check ((Snapshot $f.Root) -ceq $beforePublish) 'Rejected forged recommendation preserves all metadata and assets'
    # Even an otherwise current recommendation must fail closed when the raw
    # sensor has no manifest/engine binding, as in the obsolete fixture.
    $incomplete=Clone (ReadJson $recordPath)
    foreach($profile in $incomplete.Profiles){
        $badRaw=Clone $profile.Validation.Result;$badRaw.PSObject.Properties.Remove('ManifestHash');$badRaw.PSObject.Properties.Remove('EngineSHA256')
        $profile.Validation=ConvertTo-TCProtocolEvidence -Result $badRaw -Profile $profile -NetworkContext $network
    }
    $badDecision=Get-TCProtocolRecommendation -Profiles $incomplete.Profiles -LineId $f.Node.id -NetworkContext $network
    WriteJson $recordPath $incomplete;$incompleteBefore=Snapshot $f.Root
    Reject {Set-TCLineRecommendation -Root $f.Root -Id $f.Node.id -Recommendation $badDecision -NetworkContext $network} 'Incomplete original manifest/engine evidence cannot save a default'
    Check ((Snapshot $f.Root) -ceq $incompleteBefore) 'Incomplete-evidence rejection changes no files'
    WriteJson $recordPath $selectionLineForRestore
    $savedLine=Set-TCLineRecommendation -Root $f.Root -Id $f.Node.id -Recommendation $decision -NetworkContext $network
    Check ($savedLine.Recommendation.Status -ceq 'Recommended' -and $savedLine.PreferredProfileId -ceq 'Udp' -and $savedLine.PreferenceSource -ceq 'PolicyDefault') 'Verified recommendation persists correct default and reason'
    $saved=$savedLine.SavedConnectionPreference;$udp=@($savedLine.Profiles|Where-Object Id -ceq 'Udp')[0]
    Check ($saved.Source -ceq 'PolicyDefault' -and $saved.Provenance.Kind -ceq 'Recommendation' -and $saved.Provenance.Recommendation.EvidenceDigest -ceq $decision.EvidenceDigest -and (Test-TCSavedConnectionPreference -Preference $saved -LineId $f.Node.id -Profile $udp -Manifest (ReadJson $udp.ManifestPath))) 'Saved automatic default retains full original producer provenance and config binding'
    $default=Get-TCLineDefaultProfile -Root $f.Root -Id $f.Node.id -NetworkContext $network
    Check ($default.ProfileId -ceq 'Udp' -and -not $default.RequiresCheck -and $default.Registered -and $default.SelectionMode -ceq 'SavedDefault' -and $default.RecommendationCurrent) 'Default consumer distinguishes saved preference from current recommendation'
    $changed=[pscustomobject]@{Status='Available';Fingerprint=('D'*64)}
    $old=Get-TCLineDefaultProfile -Root $f.Root -Id $f.Node.id -NetworkContext $changed -SelectionMode CurrentRecommendation
    $stillSaved=Get-TCLineDefaultProfile -Root $f.Root -Id $f.Node.id -NetworkContext $changed
    Check (-not $old.ProfileId -and $old.RequiresCheck -and -not $old.RecommendationCurrent -and $stillSaved.ProfileId -ceq 'Udp' -and -not $stillSaved.RequiresCheck -and -not $stillSaved.RecommendationCurrent -and $stillSaved.RecommendationState -ceq 'Old') 'Changed network invalidates current recommendation but preserves explicit saved default'
    # Advance private test clocks, leaving the original evidence bytes intact.
    $beforeExpiry=Snapshot $f.Root;$future=[DateTimeOffset]::UtcNow.AddDays(2)
    & $lines {param($At)$script:LineTestNow=$At;$script:PreferenceClock={$script:LineTestNow}} $future
    & $protocol {param($At)$script:LineTestNow=$At;$script:PreferenceClock={$script:LineTestNow}} $future
    try{
        $expired=Get-TCLineDefaultProfile -Root $f.Root -Id $f.Node.id -NetworkContext $network
        $notCurrent=Get-TCLineDefaultProfile -Root $f.Root -Id $f.Node.id -NetworkContext $network -SelectionMode CurrentRecommendation
        Check ($expired.ProfileId -ceq 'Udp' -and -not $expired.RequiresCheck -and -not $expired.RecommendationCurrent -and $expired.RecommendationState -ceq 'Expired' -and -not $notCurrent.ProfileId -and $notCurrent.RequiresCheck) 'Expired original evidence permits saved default but never a current recommendation'
        Check ((Snapshot $f.Root) -ceq $beforeExpiry) 'Expiry resolution is readonly and does not rewrite the saved origin'
    }finally{
        & $lines {param($Clock)$script:PreferenceClock=$Clock} $lineClockOriginal
        & $protocol {param($Clock)$script:PreferenceClock=$Clock} $protocolClockOriginal
    }
    $manual=Set-TCLinePreferredProfile -Root $f.Root -Id $f.Node.id -ProfileId Tcp
    Check ($manual.SavedConnectionPreference.Source -ceq 'UserChoice' -and $manual.SavedConnectionPreference.Provenance.Kind -ceq 'ManualChoice' -and -not $manual.SavedConnectionPreference.Provenance.Recommendation) 'Genuine explicit choice records manual provenance without relabeling automatic evidence'
    $manualDigest=$manual.SavedConnectionPreference.Digest
    $savedLine=Set-TCLineRecommendation -Root $f.Root -Id $f.Node.id -Recommendation $decision -NetworkContext $network
    $chosen=Get-TCLineDefaultProfile -Root $f.Root -Id $f.Node.id -NetworkContext $network
    Check ($chosen.ProfileId -ceq 'Tcp' -and $chosen.Source -ceq 'UserChoice' -and $savedLine.PreferenceSource -ceq 'UserChoice' -and $savedLine.SavedConnectionPreference.Digest -ceq $manualDigest -and $savedLine.Recommendation.Source -ceq 'PolicyDefault') 'New automatic recommendation preserves the genuine manual default and its original digest'
    Check ((PreservedSnapshot $f) -ceq $selectionProtected) 'Recommendation or preference changed active configuration/index/runtime/preferences'
    WriteJson $recordPath $selectionRecord
    $unknownLine=Get-TCLine -Root $f.Root -Id $f.Node.id
    $noDecision=Get-TCProtocolRecommendation -Profiles $unknownLine.Profiles -LineId $f.Node.id -NetworkContext $network
    $savedLine=Set-TCLineRecommendation -Root $f.Root -Id $f.Node.id -Recommendation $noDecision -NetworkContext $network
    $none=Get-TCLineDefaultProfile -Root $f.Root -Id $f.Node.id -NetworkContext $network
    Check (-not $savedLine.PreferredProfileId -and -not $none.ProfileId -and $none.RequiresCheck) 'Explicit no-recommendation never falls back to configured UDP'
    Check (@(Get-TCLineCards -Root $f.Root)[0].Recommendation.Status -ceq 'Inconclusive') 'No-recommendation remains readable on one line card'
    WriteJson $recordPath $selectionRecord
    # Old configured defaults had no SavedConnectionPreference field. Preserve
    # their real origin while treating an explicit new null as authoritative.
    $legacyDefault=Clone $selectionRecord;$legacyDefault.PSObject.Properties.Remove('SavedConnectionPreference')
    $legacyDefault.PreferenceSource='ConfiguredDefault';$legacyDefault.PreferredProfileId='Udp';$legacyDefault.Recommendation=$null
    WriteJson $recordPath $legacyDefault;$beforeLegacyDefault=Snapshot $f.Root
    $restoredDefault=Get-TCLineDefaultProfile -Root $f.Root -Id $f.Node.id
    Check ($restoredDefault.ProfileId -ceq 'Udp' -and -not $restoredDefault.RequiresCheck -and $restoredDefault.Source -ceq 'ConfiguredDefault' -and $restoredDefault.SavedConnectionPreference.Provenance.Kind -ceq 'LegacyConfiguredDefault') 'Old configured UDP default resolves with its own provenance'
    $againDefault=Get-TCLineDefaultProfile -Root $f.Root -Id $f.Node.id
    Check ($againDefault.SavedConnectionPreference.Digest -ceq $restoredDefault.SavedConnectionPreference.Digest -and (Snapshot $f.Root) -ceq $beforeLegacyDefault) 'Legacy default compatibility is deterministic and read only'
    $legacyDefault|Add-Member NoteProperty SavedConnectionPreference $null -Force;WriteJson $recordPath $legacyDefault
    $nullDefault=Get-TCLineDefaultProfile -Root $f.Root -Id $f.Node.id
    Check ($nullDefault.RequiresCheck -and $nullDefault.Code -ceq 'SavedDefaultMissing') 'Explicit missing new default cannot resurrect configured UDP'
    WriteJson $recordPath $selectionRecord
    # Explicit legacy alias is consolidated; active alias references remain old.
    $legacy=NewFixture 'legacy';$li=Envelope $legacy;$sibling=LegacySibling $legacy $li
    WriteJson (Join-Path $legacy.Root 'runtime.json') @{State='Running';ManifestPath=$sibling.manifestPath}
    WriteJson (Join-Path $legacy.Root 'deployment.json') @{ManifestPath=$sibling.manifestPath;Stage='Active'}
    WriteJson (Join-Path $legacy.Root 'ui-preferences.json') @{NodeId=$sibling.id;Transport='Tcp'}
    $legacyBefore=Snapshot $legacy.Root;$aliasPreserved=PreservedSnapshot $legacy;$siblingBefore=Snapshot (Split-Path $sibling.manifestPath -Parent)
    $cards=@(Get-TCLineCards -Root $legacy.Root);$alias=Get-TCLine -Root $legacy.Root -Id $sibling.id
    Check ($cards.Count -eq 1 -and $cards[0].LineId -ceq $legacy.Node.id -and $cards[0].AliasIds -contains $sibling.id -and $cards[0].CurrentProfileId -ceq 'Tcp' -and $cards[0].HasTcp -and -not $cards[0].MissingBackup) 'Verified active alias hidden behind one Tcp/Udp card'
    Check ($alias.LineId -ceq $legacy.Node.id -and $alias.SourceNodeId -ceq $legacy.Node.id -and $alias.Profiles.Count -eq 2 -and (Snapshot $legacy.Root) -ceq $legacyBefore) 'Alias resolves readonly to stable source line'
    $migrated=Register-TCLineProfiles -Root $legacy.Root -Id $sibling.id
    Check ($migrated.LineId -ceq $legacy.Node.id -and $migrated.Profiles.Count -eq 2 -and (PreservedSnapshot $legacy) -ceq $aliasPreserved -and (Snapshot (Split-Path $sibling.manifestPath -Parent)) -ceq $siblingBefore) 'Register alias materializes profiles without rewriting active legacy references'
    $again=New-TCAutomaticTransportCandidate -Root $legacy.Root -Id $sibling.id -TransportInfo $li;Check ($again.Reused -and $again.Id -ceq $legacy.Node.id) 'Alias prepare reuses migrated Tcp revision'
    # CT moves only the source node pointer. Stable provenance must survive both modes.
    CheckCommittedProfilePointer $f $info
    CheckCommittedProfilePointer $legacy $li $sibling.id
    CheckApprovedCloneCurrent $f
    CheckApprovedCloneCurrent $legacy
    # Existing v2 records without a stored source path can recover an explicit
    # hash-matched original path; recovery remains readonly until registration.
    $compat=NewFixture 'pointer-v2-compat';$ci=Envelope $compat
    $null=Prepare-TCTcpLineProfile -Root $compat.Root -Id $compat.Node.id -TransportInfo $ci
    $cv=Get-TCLine -Root $compat.Root -Id $compat.Node.id
    $crp=Join-Path (Join-Path (Join-Path $compat.Store 'lines') $compat.Node.id) 'line.json'
    $cr=ReadJson $crp;$cr.PSObject.Properties.Remove('SourceManifestPath');WriteJson $crp $cr
    $cidx=ReadJson (Join-Path $compat.Store 'index.json');$cidx.nodes[0].manifestPath=@($cv.Profiles|Where-Object {$_.Id -ceq 'Tcp'})[0].ManifestPath;WriteJson (Join-Path $compat.Store 'index.json') $cidx
    $before=Snapshot $compat.Root;$v=Get-TCLine -Root $compat.Root -Id $compat.Node.id
    Check ((Json $v) -ceq (Json $cv) -and (Snapshot $compat.Root) -ceq $before) 'Old v2 anchor recovery accepts exact registered pointer readonly'
    $recovered=Register-TCLineProfiles -Root $compat.Root -Id $compat.Node.id
    Check ((ReadJson $crp).SourceManifestPath -ceq $compat.Node.manifestPath -and $recovered.Profiles.Count -eq 2) 'Old v2 register adds explicit original anchor without replacing profiles'
    # Same key and even identical profile bytes at another path confer no ownership.
    $ptrIndex=ReadJson (Join-Path $f.Store 'index.json');$validPointer=$ptrIndex.nodes[0].manifestPath
    $unregistered=Join-Path $f.Root 'unregistered-manifest.json';[IO.File]::Copy($validPointer,$unregistered)
    $ptrIndex.nodes[0].manifestPath=$unregistered;WriteJson (Join-Path $f.Store 'index.json') $ptrIndex
    $before=Snapshot $f.Root
    Reject {Get-TCLineCards -Root $f.Root} 'Unregistered identical same-key manifest pointer rejected by cards'
    Reject {Get-TCLine -Root $f.Root -Id $f.Node.id} 'Unregistered identical same-key manifest pointer rejected by Get'
    Reject {Get-TCLineProfile -Root $f.Root -Id $f.Node.id -ProfileId Tcp} 'Unregistered identical same-key manifest pointer rejected by GetProfile'
    Reject {Prepare-TCTcpLineProfile -Root $f.Root -Id $f.Node.id -TransportInfo $info} 'Unregistered identical same-key manifest pointer rejected by Prepare'
    Check ((Snapshot $f.Root) -ceq $before) 'Unknown pointer rejection preserves all files'
    $ptrIndex.nodes[0].manifestPath=$validPointer;WriteJson (Join-Path $f.Store 'index.json') $ptrIndex
    # A different line with the same keys has no authority over this source pointer.
    $foreign=NewFixture 'foreign-pointer' 'Foreign' $f
    $null=Prepare-TCTcpLineProfile -Root $foreign.Root -Id $foreign.Node.id -TransportInfo (Envelope $foreign)
    $foreignProfile=Get-TCLineProfile -Root $foreign.Root -Id $foreign.Node.id -ProfileId Tcp
    $ptrIndex.nodes[0].manifestPath=$foreignProfile.ManifestPath;WriteJson (Join-Path $f.Store 'index.json') $ptrIndex
    Reject {Get-TCLine -Root $f.Root -Id $f.Node.id} 'Same-key profile registered under foreign LineId rejected'
    $ptrIndex.nodes[0].manifestPath=$validPointer;WriteJson (Join-Path $f.Store 'index.json') $ptrIndex
    # Exact registered pointer still requires all recorded hashes and original anchor.
    $registeredProfile=Get-TCLineProfile -Root $f.Root -Id $f.Node.id -ProfileId Tcp
    $bytes=[IO.File]::ReadAllBytes($registeredProfile.ManifestPath);[IO.File]::AppendAllText($registeredProfile.ManifestPath,' ')
    try{Reject {Get-TCLine -Root $f.Root -Id $f.Node.id} 'Committed registered profile manifest hash tamper rejected'}finally{[IO.File]::WriteAllBytes($registeredProfile.ManifestPath,$bytes)}
    foreach($asset in @($f.Node.manifestPath,$f.Manifest.CandidatePath,$f.Manifest.ProbePath)){
        $bytes=[IO.File]::ReadAllBytes($asset);[IO.File]::AppendAllText($asset,' ');$before=Snapshot $f.Root
        try{
            Reject {Get-TCLineCards -Root $f.Root} ('Committed profile rejects original anchor drift '+[IO.Path]::GetFileName($asset))
            Reject {Prepare-TCTcpLineProfile -Root $f.Root -Id $f.Node.id -TransportInfo $info} ('Prepare rejects original anchor drift '+[IO.Path]::GetFileName($asset))
            Check ((Snapshot $f.Root) -ceq $before) ('Anchor drift rejection readonly '+[IO.Path]::GetFileName($asset))
        }finally{[IO.File]::WriteAllBytes($asset,$bytes)}
    }
    # Same name/key without provenance remains a separate line.
    $sameFixture=NewFixture 'same-keys'
    $same=Import-TCWireGuard -Root $sameFixture.Store -Path (Join-Path $sameFixture.Root 'client.conf') -Name $sameFixture.Node.name -EnginePath $engine -WgPath $wg -TradeProgramPaths @() -DirectDnsIPv4 '192.168.100.1'
    $cards=@(Get-TCLineCards -Root $sameFixture.Root);Check ($cards.Count -eq 2 -and @($cards|Where-Object {$_.id -ceq $same.id}).Count -eq 1) 'Same name/server/device key does not merge independent line'
    foreach($case in @('source-hash','server-key','device-key','address','policy','binding-digest','source-path')){
        $a=NewFixture ('unproven-'+$case);$ai=Envelope $a;$sn=LegacySibling $a $ai;$m=ReadJson $sn.manifestPath
        switch($case){'source-hash'{$m.SourceConfigSHA256='0'*64};'server-key'{$m.ServerPublicKey=$m.ClientPublicKey};'device-key'{$m.ClientPublicKey=$m.ServerPublicKey};'address'{$m.ClientAddress='10.78.0.99'};'policy'{$m.StartupMode='global'};'binding-digest'{$m.TCPBindingDigest='0'*64};'source-path'{$m.AutoTransportSourceManifestPath=$sn.manifestPath}}
        WriteJson $sn.manifestPath $m;$snap=Snapshot $a.Root;$cards=@(Get-TCLineCards -Root $a.Root)
        Check ($cards.Count -eq 2 -and @($cards|Where-Object {$_.AliasIds.Count}).Count -eq 0 -and (Snapshot $a.Root) -ceq $snap) ('Unproven '+$case+' retained as independent readonly record')
    }
    $amb=NewFixture 'ambiguous';$ambInfo=Envelope $amb;$null=LegacySibling $amb $ambInfo;$otherInfo=Clone $ambInfo;$otherInfo.Transport.Port=8443;$null=LegacySibling $amb $otherInfo
    $cards=@(Get-TCLineCards -Root $amb.Root);Check ($cards.Count -eq 3 -and @($cards|Where-Object {$_.AliasIds.Count}).Count -eq 0) 'Conflicting explicit siblings have no arbitrary merge winner'
    # Source TCP must yield a separate UDP revision without changing source detour.
    $tc=NewFixture 'tcp-source';$ti=Envelope $tc;$tn=LegacySibling $tc $ti;$tm=ReadJson $tn.manifestPath
    foreach($key in @('AutoTransportSourceNodeId','AutoTransportSourceManifestPath','SourceConfigSHA256','TCPBindingDigest')){$tm.PSObject.Properties.Remove($key)}
    WriteJson $tn.manifestPath $tm;$index=ReadJson (Join-Path $tc.Store 'index.json');$index.nodes=@($tn);WriteJson (Join-Path $tc.Store 'index.json') $index
    $tcpOriginal=Snapshot (Split-Path $tn.manifestPath -Parent);$tcpOnly=Get-TCLine -Root $tc.Root -Id $tn.id
    Check ($tcpOnly.Profiles.Count -eq 1 -and $tcpOnly.Profiles[0].Id -ceq 'Tcp') 'TCP legacy source accurately reports existing profile'
    $dual=Register-TCLineProfiles -Root $tc.Root -Id $tn.id;$udp=@($dual.Profiles|Where-Object {$_.Id -ceq 'Udp'})[0];$um=ReadJson $udp.ManifestPath;$uc=ReadJson $um.CandidatePath
    Check ($dual.PreferredProfileId -ceq 'Tcp' -and $dual.Profiles.Count -eq 2 -and -not $uc.endpoints[0].PSObject.Properties['detour'] -and @($uc.outbounds|Where-Object {$_.tag -ceq 'tc-transport'}).Count -eq 0 -and (Snapshot (Split-Path $tn.manifestPath -Parent)) -ceq $tcpOriginal) 'TCP source clones UDP by removing transport, source remains unchanged'
    # Production legacy existing shape: no WgPath/ProbeSHA256; /24 vs /32.
    $old=NewFixture 'existing';$old.Node.kind='existing';$old.Node.status='Registered';$index=ReadJson (Join-Path $old.Store 'index.json');$index.nodes=@($old.Node);WriteJson (Join-Path $old.Store 'index.json') $index
    $old.Manifest.ClientAddress='10.78.0.4/24';$old.Manifest.PSObject.Properties.Remove('WgPath');$old.Manifest.PSObject.Properties.Remove('ProbeSHA256');WriteJson $old.Node.manifestPath $old.Manifest
    $oldBefore=Snapshot $old.Root;$cards=@(Get-TCLineCards -Root $old.Root);$v=Get-TCLine -Root $old.Root -Id $old.Node.id
    Check ($cards.Count -eq 1 -and $cards[0].status -ceq 'Registered' -and $v.Profiles.Count -eq 1 -and (Snapshot $old.Root) -ceq $oldBefore) 'Legacy existing missing wg/probe hash and /24 readable without writes'
    $r=Register-TCLineProfiles -Root $old.Root -Id $old.Node.id;$om=ReadJson $r.Profiles[0].ManifestPath
    Check ($om.WgPath -ceq $wg -and $om.ProbeSHA256 -ceq (Hash $om.ProbePath) -and -not (ReadJson $old.Node.manifestPath).PSObject.Properties['WgPath'] -and -not (ReadJson $old.Node.manifestPath).PSObject.Properties['ProbeSHA256']) 'Legacy fallback/hash written to new profile only'
    # Native failure after first profile succeeds must remove both stage and unpublished final.
    $fail=NewFixture 'failure';$fi=Envelope $fail;$failPreserved=PreservedSnapshot $fail
    & $nodes {$script:LineTestBreakTcp=$true}
    try{Reject {Prepare-TCTcpLineProfile -Root $fail.Root -Id $fail.Node.id -TransportInfo $fi} 'Actual sing-box check rejects corrupted Tcp stage'}finally{& $nodes {$script:LineTestBreakTcp=$false}}
    Check ((PreservedSnapshot $fail) -ceq $failPreserved -and -not [IO.Directory]::Exists((Join-Path $fail.Store 'lines'))) 'Native failure cleans unpublished UDP/TCP/staging/metadata and preserves source'
    $candidate=Prepare-TCTcpLineProfile -Root $fail.Root -Id $fail.Node.id -TransportInfo $fi;$failureBaseline=Snapshot $fail.Root
    $fi2=Clone $fi;$fi2.Transport.Port=8443
    & $nodes {$script:LineTestBreakMetadata=$true}
    try{Reject {Prepare-TCTcpLineProfile -Root $fail.Root -Id $fail.Node.id -TransportInfo $fi2} 'Metadata publication failure after checked new revision'}finally{& $nodes {$script:LineTestBreakMetadata=$false}}
    Check ((Snapshot $fail.Root) -ceq $failureBaseline) 'Metadata failure preserves published revision and removes unpublished final'
    # Known registry owner/node binds transport_info, with no SSH calls.
    $bound=NewFixture 'bound';$bi=Envelope $bound;$registry=Join-Path $bound.Root 'servers';& $nodes {param($p)New-TCPrivateDirectory $p} $registry
    $server=[pscustomobject]@{LocalRecordId=[guid]::NewGuid().ToString();RemoteOwnerId=$bi.RemoteOwnerId;NodeId=$bi.NodeId;ServerPublicKey=$bound.Manifest.ServerPublicKey;LinkedNodeIds=@($bound.Node.id);Endpoints=@($bound.Node.endpoint);Connection=@{Host='192.0.2.10';Port=22;User='root';IdentityFile=''}}
    WriteJson (Join-Path $registry 'registry.json') @{SchemaVersion=1;Servers=@($server)}
    foreach($field in @('NodeId','RemoteOwnerId')){$bad=Clone $bi;$bad.$field=[guid]::NewGuid().ToString();Reject {Prepare-TCTcpLineProfile -Root $bound.Root -Id $bound.Node.id -TransportInfo $bad} ('Known registry '+$field+' mismatch rejected')}
    $ctx=Get-TCTransportPreparation -Root $bound.Root -Id $bound.Node.id;Check ($ctx.ServerId -ceq $server.LocalRecordId -and $ctx.RemoteOwnerId -ceq $bi.RemoteOwnerId -and $ctx.RemoteNodeId -ceq $bi.NodeId -and -not $ctx.Connection.Unverified) 'Bound management context retained in Auto contract'
    [IO.File]::AppendAllText((ReadJson $candidate.ManifestPath).ProbePath,' ')
    Reject {Get-TCLine -Root $fail.Root -Id $fail.Node.id} 'Readonly profile hash tamper rejected'
    $calls=@(& $nodes {$script:LineTestCalls.ToArray()})
    Check (@($calls|Where-Object {$_.Command -ceq 'check' -and $_.Stage -and $_.ExitCode -eq 0}).Count -ge 8 -and @($calls|Where-Object {$_.Command -ceq 'check' -and $_.Stage -and $_.ExitCode -ne 0}).Count -ge 1) 'Real native profile candidate/probe success and rejection evidence'
    # Authenticated maintenance repairs old MTU defaults using immutable profiles.
    $mtuf=NewFixture 'mtu-maintenance';$mi=Envelope $mtuf;$mi|Add-Member NoteProperty MTU 1380
    $null=Register-TCLineProfiles -Root $mtuf.Root -Id $mtuf.Node.id
    $legacyRecordPath=Join-Path (Join-Path (Join-Path $mtuf.Store 'lines') $mtuf.Node.id) 'line.json'
    $legacyRecord=ReadJson $legacyRecordPath;$legacyRecord.PSObject.Properties.Remove('Recommendation')
    WriteJson $legacyRecordPath $legacyRecord
    $oldUdp=@($legacyRecord.Profiles|Where-Object Id -ceq 'Udp')[0]
    $legacyIndex=ReadJson (Join-Path $mtuf.Store 'index.json')
    @($legacyIndex.nodes|Where-Object id -ceq $mtuf.Node.id)[0].manifestPath=$oldUdp.ManifestPath
    WriteJson (Join-Path $mtuf.Store 'index.json') $legacyIndex
    Check (-not (ReadJson $legacyRecordPath).PSObject.Properties['Recommendation']) 'Legacy schema 2 fixture omits optional Recommendation as the shipped old record does'
    $sourceBefore=PreservedSnapshot $mtuf
    $mc=Prepare-TCTcpLineProfile -Root $mtuf.Root -Id $mtuf.Node.id -TransportInfo $mi
    $ml=Get-TCLine -Root $mtuf.Root -Id $mtuf.Node.id
    Check ($ml.PSObject.Properties['Recommendation'] -and $null -eq $ml.Recommendation) 'MTU maintenance adds the missing recommendation slot without requiring another import'
    Check ($ml.Profiles.Count -eq 2) 'MTU maintenance creates both profiles in the original line'
    $storedMtu=ReadJson $legacyRecordPath
    Check (@($storedMtu.PreviousProfiles|Where-Object ManifestPath -ceq $oldUdp.ManifestPath).Count -eq 1) 'UDP MTU replacement preserves the exact registered old pointer in history'
    $mtuContext=Get-TCTransportPreparation -Root $mtuf.Root -Id $mtuf.Node.id
    Check ($mtuContext.HasSettings) 'Legacy node pointer remains readable after both new profiles are published'
    foreach($mode in @('Udp','Tcp')){
        $mp=Get-TCLineProfile -Root $mtuf.Root -Id $mtuf.Node.id -ProfileId $mode
        $mm=ReadJson $mp.ManifestPath;$cfg=ReadJson $mm.CandidatePath;$pr=ReadJson $mm.ProbePath
        Check (@($cfg.endpoints|Where-Object tag -ceq 'hk')[0].mtu -eq 1380 -and @($pr.endpoints|Where-Object tag -ceq 'hk')[0].mtu -eq 1380) ('Authenticated MTU reaches '+$mode+' configuration and probe')
        Check (@($cfg.inbounds|Where-Object type -ceq 'tun')[0].mtu -eq 1380) ('Authenticated MTU reaches '+$mode+' TUN')
    }
    Check ((PreservedSnapshot $mtuf) -ceq $sourceBefore) 'MTU maintenance leaves original config, identity and user settings unchanged'
    $mtuSnapshot=Snapshot $mtuf.Root;$repeatMtu=Prepare-TCTcpLineProfile -Root $mtuf.Root -Id $mtuf.Node.id -TransportInfo $mi
    Check ($repeatMtu.Reused -and (Snapshot $mtuf.Root) -ceq $mtuSnapshot) 'Repeated MTU maintenance reuses both immutable profiles'
    foreach($invalid in @($null,$true,'1380',1279,1421)){
        $badMtu=Clone $mi;$badMtu.MTU=$invalid
        Reject {Prepare-TCTcpLineProfile -Root $mtuf.Root -Id $mtuf.Node.id -TransportInfo $badMtu} ('MTU maintenance rejects invalid authenticated value '+[string]$invalid)
    }
    Check ((Snapshot $mtuf.Root) -ceq $mtuSnapshot) 'Invalid MTU never publishes partial profiles'
    $passed=$true
}catch{
    $failure=[pscustomobject]@{ExceptionType=$_.Exception.GetType().FullName;Line=$_.InvocationInfo.ScriptLineNumber;Diagnostic=(& $nodes {$script:LineTestDiagnostic});TestMessage=$(if($_.Exception.Message -like 'Line store assertion:*'){$_.Exception.Message}else{$null})}
}finally{
    & $lines {param($Clock)$script:PreferenceClock=$Clock} $lineClockOriginal
    if($protocol){& $protocol {param($Clock)$script:PreferenceClock=$Clock} $protocolClockOriginal}
    $calls=@(& $nodes {$script:LineTestCalls.ToArray()})
    & $nodes {
        param($Runner)
        $script:TCNativeRunner=$Runner;${function:Stop-TCOperation}=$script:LineTestOriginalStop
        ${function:Open-TCNodeSessionLock}=$script:LineTestSession;${function:Open-TCLock}=$script:LineTestStore;${function:Write-TCAtomicJson}=$script:LineTestAtomic
        if($script:LineTestOriginalCim){Set-Item Function:\Get-CimInstance $script:LineTestOriginalCim.ScriptBlock}else{Remove-Item Function:\Get-CimInstance -ErrorAction SilentlyContinue}
    } $nativeOriginal
    $full=[IO.Path]::GetFullPath($work);$parent=[IO.Path]::GetFullPath([Environment]::GetFolderPath('LocalApplicationData')).TrimEnd('\')+'\'
    if(-not $full.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -cnotmatch '^TC-LineStore-[0-9a-f]{32}$'){throw 'Line test cleanup rejected.'}
    if([IO.Directory]::Exists($full)){Remove-Item -LiteralPath $full -Recurse -Force}
    $report=[pscustomobject]@{Passed=$passed;Checks=$checks.Count;CheckNames=$checks.ToArray();PowerShell=$PSVersionTable.PSVersion.ToString();RealNetworkChanges=0;RealEngineRuns=0;ProductionWrites=0;RealSshCalls=0;NativeScope='wg pubkey; sing-box check';NativePubkeys=@($calls|Where-Object {$_.Command -ceq 'pubkey'}).Count;NativeChecks=@($calls|Where-Object {$_.Command -ceq 'check'}).Count;StagedCheckPasses=@($calls|Where-Object {$_.Command -ceq 'check' -and $_.Stage -and $_.ExitCode -eq 0}).Count;StagedCheckFailures=@($calls|Where-Object {$_.Command -ceq 'check' -and $_.Stage -and $_.ExitCode -ne 0}).Count;TemporaryFixtureRemoved=(-not [IO.Directory]::Exists($full));Failure=$failure}
    $reportFull=[IO.Path]::GetFullPath($ReportPath);$null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($reportFull));WriteJson $reportFull $report
}
if(-not $passed){$report|ConvertTo-Json -Depth 8;throw 'Line store tests failed; safe diagnostics are in the specified report.'}
$report|Select-Object Passed,Checks,PowerShell,NativeChecks,StagedCheckFailures,RealNetworkChanges,RealEngineRuns,ProductionWrites
