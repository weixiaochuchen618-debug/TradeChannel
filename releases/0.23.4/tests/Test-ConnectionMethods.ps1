#requires -Version 5.1
[CmdletBinding()]param(
    [string]$PackageRoot,
    [string]$ReportPath)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$checks=New-Object 'Collections.Generic.List[object]'
$calls=New-Object 'Collections.Generic.List[object]'
$passed=$false;$failure=$null;$removed=$false;$originalExecutors=$null
$tempParent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$fixture=Join-Path $tempParent ('tc-x1x2-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($fixture)
$module=$null
function Check {param([bool]$Condition,[string]$Name) if(-not $Condition){throw ('Check failed: '+$Name)};$checks.Add([pscustomobject]@{Name=$Name;Passed=$true})}
function Throws {
    param([scriptblock]$Action,[string]$Code,[string]$Name)
    $caught=$false
    try{$null=& $Action}catch{if($_.Exception.Message -notlike ('*'+$Code+'*')){throw};$caught=$true}
    Check $caught $Name
}
function Clone {param($Value) ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $Value -Depth 60 -Compress)}
function Write-Utf8 {param([string]$Path,[string]$Value) [IO.File]::WriteAllText($Path,$Value,(New-Object Text.UTF8Encoding($false)))}

try {
    if(-not $PackageRoot){$PackageRoot=Split-Path -Parent $PSScriptRoot}
    $PackageRoot=[IO.Path]::GetFullPath($PackageRoot)
    $module=Import-Module (Join-Path $PackageRoot 'ConnectionMethods.psm1') -Force -PassThru -DisableNameChecking -ErrorAction Stop
    $methods=@(Get-TCConnectionMethods)
    Check (($methods.Id -join ',') -ceq 'Udp,Tcp') 'Legacy IDs remain ordered and available'
    Check (($methods.DisplayName -join ',') -ceq '标准连接,兼容连接') 'UI names come from the shared declaration'
    Check ((@(Get-TCConnectionMethodIds -IncludeAuto) -join ',') -ceq 'Auto,Udp,Tcp') 'Auto is explicitly an optional selection policy'
    Throws {Invoke-TCConnectionMethod -Id Auto -Operation DeploymentRequest -Parameters @{Phase='Inspect';Input=@{}}} 'UnknownConnectionMethod' 'Auto cannot dispatch a deployment'
    $methods[0].Handlers.ConfigureClient='evil'
    Check ((Get-TCConnectionMethod Udp).Handlers.ConfigureClient -ceq 'wireguard-direct-v1') 'Callers cannot mutate registered handlers'
    Check ((Resolve-TCConnectionMethod -Transport $null).Id -ceq 'Udp') 'Legacy null transport resolves to standard connection'
    Check ((Resolve-TCConnectionMethod -TransportType 'tcp-reality').Id -ceq 'Tcp') 'Existing tcp-reality resolves to compatibility connection'
    Throws {Resolve-TCConnectionMethod -TransportType 'unknown'} 'UnknownConnectionMethod' 'Unknown transport is rejected'

    $public=[Convert]::ToBase64String([byte[]](1..32)).TrimEnd('=').Replace('+','-').Replace('/','_')
    $transport=@{Type='tcp-reality';Server='192.0.2.20';Port=443;Uuid='11111111-2222-4333-8444-555555555555';ServerName='www.bing.com';RealityPublicKey=$public;RealityShortId='aabbccdd'}
    $normalized=Invoke-TCConnectionMethod -Id Tcp -Operation ValidateTransport -Parameters @{Value=$transport}
    Check ($normalized.Port -eq 443 -and $normalized.Type -ceq 'tcp-reality') 'Registered transport handler validates existing parameters'
    Check ($normalized -is [Collections.Specialized.OrderedDictionary] -and $normalized.Contains('Type') -and $normalized['Type'] -ceq 'tcp-reality') 'Transport retains the legacy ordered IDictionary return contract'
    $withoutShort=Clone $transport;$withoutShort.PSObject.Properties.Remove('RealityShortId')
    Check ((Invoke-TCConnectionMethod -Id Tcp -Operation ValidateTransport -Parameters @{Value=$withoutShort}).RealityShortId -ceq '') 'Legacy optional empty short ID is accepted'
    Throws {Invoke-TCConnectionMethod -Id Udp -Operation ValidateTransport -Parameters @{Value=$transport}} 'ConnectionMethodMismatch' 'Standard connection cannot receive compatibility parameters'
    Throws {Invoke-TCConnectionMethod -Id Tcp -Operation ValidateTransport -Parameters @{Value=@{Type='unknown'}}} 'InvalidConnectionParameters' 'Malformed compatibility parameters are rejected'

    $key=[Convert]::ToBase64String([byte[]](1..32))
    $config=[ordered]@{
        log=@{level='error'}
        dns=@{servers=@(@{type='udp';tag='dns-direct';server='1.1.1.1'})}
        endpoints=@(@{type='wireguard';tag='trade';system=$false;mtu=1380;address=@('10.78.0.2/32');private_key=$key;
            peers=@(@{address='192.0.2.20';port=51820;public_key=$key;allowed_ips=@('0.0.0.0/0');persistent_keepalive_interval=25})})
        outbounds=@(@{type='direct';tag='direct'})
        route=@{final='trade';default_domain_resolver='dns-direct';rules=@(@{ip_cidr=@('192.0.2.20/32');action='route';outbound='direct'})}
    }
    $before=ConvertTo-Json -InputObject $config -Depth 40 -Compress
    $tcpConfig=Invoke-TCConnectionMethod -Id Tcp -Operation ConfigureClient -Parameters @{Config=$config;Transport=$transport}
    Check ($tcpConfig.endpoints[0].detour -ceq 'tc-transport' -and $tcpConfig.outbounds[0].type -ceq 'vless' -and $tcpConfig.outbounds[0].tls.reality.public_key -ceq $public) 'Compatibility handler generates a real WireGuard over Reality configuration'
    Check ((ConvertTo-Json -InputObject $config -Depth 40 -Compress) -ceq $before) 'Configuration generation does not mutate caller state'
    Check ($tcpConfig -is [Collections.Specialized.OrderedDictionary] -and $tcpConfig['dns']['servers'] -is [array] -and $tcpConfig['outbounds'] -is [array]) 'Configuration preserves dictionary containers and JSON arrays in PowerShell 5.1'
    $udpConfig=Invoke-TCConnectionMethod -Id Udp -Operation ConfigureClient -Parameters @{Config=$tcpConfig}
    Check ($null -eq $udpConfig.endpoints[0].PSObject.Properties['detour'] -and @($udpConfig.outbounds|Where-Object tag -eq 'tc-transport').Count -eq 0) 'Standard handler removes the registered overlay and its detour'
    Check ($udpConfig.route.final -ceq 'trade' -and $udpConfig.route.rules[0].outbound -ceq 'direct') 'Existing traffic routing is preserved'
    $nodes=Import-Module (Join-Path $PackageRoot 'NodeStore.psm1') -PassThru -DisableNameChecking -ErrorAction Stop
    $nodeTransport=& $nodes {param($v) ConvertTo-TCTransport $v} $transport
    Check ($nodeTransport -is [Collections.Specialized.OrderedDictionary] -and $nodeTransport.Contains('RealityPublicKey') -and $nodeTransport['Port'] -eq 443) 'NodeOperations validate delegates to the registry without breaking Contains or indexed access'
    $nodeConfig=& $nodes {param($c,$t) Set-TCConfigurationTransport $c $t} (Clone $config) $nodeTransport
    Check ($nodeConfig -is [pscustomobject] -and $nodeConfig.endpoints[0].detour -ceq 'tc-transport') 'NodeOperations configure delegates and preserves a PSCustomObject input type'
    $dictionaryConfig=& $nodes {param($c,$t) Set-TCConfigurationTransport $c $t} $config $nodeTransport
    Check ($dictionaryConfig -is [Collections.Specialized.OrderedDictionary] -and $dictionaryConfig['outbounds'][0]['type'] -ceq 'vless') 'NodeOperations configure preserves an ordered dictionary input type'
    $foreign=Clone $config;$foreign.endpoints[0]|Add-Member NoteProperty detour 'foreign'
    Throws {Invoke-TCConnectionMethod -Id Tcp -Operation ConfigureClient -Parameters @{Config=$foreign;Transport=$transport}} 'InvalidConfiguration' 'Foreign detours are never overwritten'
    $dangling=Clone $tcpConfig;$dangling.route.final='tc-transport'
    Throws {Invoke-TCConnectionMethod -Id Udp -Operation ConfigureClient -Parameters @{Config=$dangling}} 'InvalidConfiguration' 'Removing an overlay cannot leave a dangling outbound reference'

    $engine=Join-Path $PackageRoot 'assets\sing-box.exe'
    foreach($entry in @(@{Id='Udp';Config=$udpConfig},@{Id='Tcp';Config=$tcpConfig})){
        $path=Join-Path $fixture ($entry.Id+'.json');Write-Utf8 $path (ConvertTo-Json -InputObject $entry.Config -Depth 40)
        $native=& $engine check -c $path 2>&1
        Check ($LASTEXITCODE -eq 0) ($entry.Id+' configuration passes bundled sing-box check without starting the engine')
    }

    $originalExecutors=& $module {$script:CMExecutors.Clone()}
    & $module {param($Calls)
        $script:CMCalls=$Calls
        $script:CMExecutors.Deploy={param($p) $script:CMCalls.Add([pscustomobject]@{Kind='Deploy';Parameters=$p});[pscustomobject]@{Status='FixtureDeployed';Operation=$p.Operation}}
        $script:CMExecutors.Probe={param($p) $script:CMCalls.Add([pscustomobject]@{Kind='Probe';Parameters=$p});[pscustomobject]@{Status='FixtureProbed';ProfileId=$p.ProfileId}}
    } $calls
    $planId='aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';$digest='A'*64;$session=[pscustomobject]@{Fixture='authenticated-session'}
    $request=Invoke-TCConnectionMethod -Id Tcp -Operation DeploymentRequest -Parameters @{Phase='AddApply';Input=@{PlanId=$planId;ApprovedChangeDigest=$digest}}
    Check ($request.Operation -ceq 'transport_apply' -and $request.Input.ApprovedChangeDigest -ceq $digest -and $calls.Count -eq 0) 'Preview contract preserves approval and does not execute'
    $result=Invoke-TCConnectionMethod -Id Tcp -Operation Deploy -Parameters @{Phase='AddApply';Input=@{PlanId=$planId;ApprovedChangeDigest=$digest};SessionRef=$session;OperationId=$planId}
    $arguments=$calls[0].Parameters
    Check ($result.Operation -ceq 'transport_apply' -and $arguments.OperationInput.PlanId -ceq $planId -and $arguments.OperationInput.ApprovedChangeDigest -ceq $digest -and $arguments.OperationId -ceq $planId -and $arguments.SessionRef -eq $session) 'Deploy dispatch invokes only the existing authenticated executor with unchanged bindings'
    foreach($id in @('Udp','Tcp')){
        $result=Invoke-TCConnectionMethod -Id $id -Operation Probe -Parameters @{Root=$fixture;NodeId=$planId;TimeoutSeconds=5;ExpectedExitIPv4='192.0.2.20';ExpectedExitSource='fixture';CancellationPath=(Join-Path $fixture 'cancel')}
        Check ($result.ProfileId -ceq $id) ($id+' probe dispatch uses its registered profile')
    }
    Check ($calls[1].Parameters.Root -ceq $fixture -and $calls[2].Parameters.TimeoutSeconds -eq 5) 'Probe dispatch preserves explicit root, budget and cancellation parameters'
    $comparison=Import-Module (Join-Path $PackageRoot 'ProtocolComparison.psm1') -PassThru -DisableNameChecking -ErrorAction Stop
    $probeBinding=[pscustomobject]@{Fixture='bound-path'}
    $comparisonProbe=& $comparison {param($r,$id,$binding) Invoke-TCProtocolComparisonProbe -Root $r -NodeId $id -ProfileId Tcp -ExpectedExitIPv4 '192.0.2.20' -ExpectedExitSource fixture -CancellationPath (Join-Path $r 'cancel') -TimeoutSeconds 17 -ProbeBinding $binding} $fixture $planId $probeBinding
    Check ($comparisonProbe.ProfileId -ceq 'Tcp' -and $calls[3].Parameters.FixedRequestBudget -eq $true -and $calls[3].Parameters.TimeoutSeconds -eq 17 -and $calls[3].Parameters.ProbeBinding -eq $probeBinding) 'ProtocolComparison uses the real registry dispatcher and preserves fixed budget and bound-path parameters'
    $count=$calls.Count
    Throws {Invoke-TCConnectionMethod -Id Udp -Operation Deploy -Parameters @{Phase='AddApply';Input=@{PlanId=$planId;ApprovedChangeDigest=$digest};SessionRef=$session}} 'UnsupportedConnectionOperation' 'A method cannot dispatch another method deployment phase'
    Throws {Invoke-TCConnectionMethod -Id Tcp -Operation DeploymentRequest -Parameters @{Phase='inspect';Input=@{}}} 'UnsupportedConnectionOperation' 'Phase names cannot bypass registered validation by changing case'
    Throws {Invoke-TCConnectionMethod -Id Tcp -Operation DeploymentRequest -Parameters @{Phase='Inspect';Input=@{Action='uninstall'}}} 'InvalidConnectionParameters' 'Action injection in deployment input is rejected'
    Throws {Invoke-TCConnectionMethod -Id Tcp -Operation Probe -Parameters @{Root=$fixture;NodeId=$planId;ProfileId='Udp'}} 'InvalidConnectionParameters' 'Probe callers cannot replace the bound profile'
    Throws {Invoke-TCConnectionMethod -Id Tcp -Operation Probe -Parameters @{NodeId=$planId}} 'InvalidConnectionParameters' 'Probe cannot silently fall back to the real product root'
    Throws {Invoke-TCConnectionMethod -Id Tcp -Operation Probe -Parameters @{Root=$fixture;NodeId=$planId;Handler='Invoke-Expression'}} 'InvalidConnectionParameters' 'Caller-provided handlers are not executable'
    Check ($calls.Count -eq $count) 'Rejected dispatch calls never reach an executor'
    $probeRequest=Invoke-TCConnectionMethod -Id Udp -Operation DeploymentRequest -Parameters @{Phase='Probe';Input=@{NetworkProbe=$true;ProbeRepeats=1;CaptureSeconds=10;ProbeRelayPort=443;ProbeSourceIPv4='198.51.100.4'}}
    Check ($probeRequest.Operation -ceq 'status' -and $probeRequest.Input.ProbeRepeats -eq 1 -and -not $probeRequest.Mutates) 'Server probe phase preserves the existing D integration contract'

    $registry=ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $PackageRoot 'ConnectionMethods.json')))
    $changed=Clone $registry;$changed.Methods[0].Handlers.Probe='Invoke-Expression'
    Throws {& $module {param($v) Assert-CMRegistry $v} $changed} 'ConnectionHandlerRejected' 'Unknown declaration handlers fail closed'
    $changed=Clone $registry;$changed.Methods[0].Deployment.Inspect.Action='uninstall'
    Throws {& $module {param($v) Assert-CMRegistry $v} $changed} 'ConnectionHandlerRejected' 'Deployment action remaps fail closed'
    $changed=Clone $registry;$changed.Architectures[1].ElfMachine=62
    Throws {& $module {param($v) Assert-CMRegistry $v} $changed} 'ConnectionRegistryInvalid' 'Declaration cannot relabel an x86 ELF as ARM'

    $python=(Get-Command python.exe -ErrorAction Stop).Source
    $bootstrap=Get-TCConnectionMethodBootstrap
    $bootstrapPath=Join-Path $fixture 'capability_bootstrap.py'
    $tail=@'
import json
print(json.dumps(sys.modules["connection_methods"].methods(), ensure_ascii=True))
'@
    $guard=@'
import builtins
def reject_remote_file_read(*args, **kwargs):
    raise AssertionError("Capability bootstrap must not read remote package files")
builtins.open = reject_remote_file_read

'@
    Write-Utf8 $bootstrapPath ($guard+"`n"+$bootstrap+$tail)
    $rows=& $python -I -B $bootstrapPath
    Check ($LASTEXITCODE -eq 0) 'Capability bootstrap executes in isolated Python without a remote JSON file'
    $pythonMethods=ConvertFrom-Json -InputObject ($rows -join "`n")
    Check ((ConvertTo-Json -InputObject @($pythonMethods) -Depth 30 -Compress) -ceq (ConvertTo-Json -InputObject @(Get-TCConnectionMethods) -Depth 30 -Compress)) 'PowerShell and embedded Python expose identical capability contracts'
    $embeddedPath=Join-Path $fixture 'embedded_connection_methods.py'
    Write-Utf8 $embeddedPath ((Get-TCConnectionMethodPythonSource)+"`nprint(normalize_architecture('aarch64'))`n")
    $architecture=& $python -I -B $embeddedPath
    Check ($LASTEXITCODE -eq 0 -and ($architecture -join '') -ceq 'arm64') 'Standalone embedded helper supports the E source bundle without directory assumptions'

    $linux=Import-Module (Join-Path $PackageRoot 'LinuxServerSetup.psm1') -PassThru -DisableNameChecking -ErrorAction Stop
    $backend=& $linux {Get-TCLinuxBackend}
    $payloadPath=Join-Path $fixture 'tradechannel_payload.py';$emptyPath=Join-Path $fixture 'input.json'
    Check ($backend.Source.StartsWith('import sys,types; _cm=types.ModuleType("connection_methods")')) 'Production LinuxServerSetup prefixes capabilities before transport imports'
    Write-Utf8 $payloadPath $backend.Source;Write-Utf8 $emptyPath '{}'
    $payloadResult=& $python -I -B $payloadPath inspect --input $emptyPath
    $exit=$LASTEXITCODE
    $envelope=ConvertFrom-Json -InputObject ($payloadResult -join "`n")
    Check ($exit -eq 1 -and -not $envelope.Ok -and $envelope.Data.Code -ceq 'UnsupportedHost') 'Production in-memory bootstrap loads all modules and refuses Windows before host commands'
    $bom=[IO.File]::ReadAllBytes((Join-Path $PackageRoot 'ConnectionMethods.psm1'))
    Check ($bom.Length -gt 3 -and $bom[0] -eq 239 -and $bom[1] -eq 187 -and $bom[2] -eq 191) 'Chinese PowerShell source retains UTF-8 BOM'
    $passed=$true
} catch {
    $failure=[ordered]@{Message=$_.Exception.Message;Line=$_.InvocationInfo.ScriptLineNumber}
} finally {
    if($null -ne $module -and $null -ne $originalExecutors){& $module {param($v) $script:CMExecutors=$v} $originalExecutors}
    $full=[IO.Path]::GetFullPath($fixture)
    if($full.StartsWith($tempParent+'\',[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($full) -cmatch '^tc-x1x2-[0-9a-f]{32}$'){
        if(Test-Path -LiteralPath $full){Remove-Item -LiteralPath $full -Recurse -Force}
        $removed=-not (Test-Path -LiteralPath $full)
    }
    $report=[ordered]@{Kind='TradeChannel.ConnectionMethodsOfflineTests';Passed=($passed -and $removed);Runtime=$PSVersionTable.PSVersion.ToString();CLR=[Environment]::Version.ToString();Assertions=$checks.Count;Checks=$checks.ToArray();DispatchCalls=$calls.Count;FixtureRemoved=$removed;Failure=$failure;Scope='Explicit disposable root; mocked deployment/probe executors; bundled sing-box check only; no VPS, active connection, installed product or real ProgramData access'}
    if($ReportPath){Write-Utf8 ([IO.Path]::GetFullPath($ReportPath)) (ConvertTo-Json -InputObject $report -Depth 30)}
    $report|ConvertTo-Json -Depth 30 -Compress
}
if(-not $passed -or -not $removed){exit 1}
