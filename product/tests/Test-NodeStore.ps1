#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$EnginePath,
    [string]$WgPath
)

# Offline only: new disposable keys, sing-box check, no run/show/service/network calls.
# Run from an elevated Windows PowerShell 5.1. No Pester or installed GUI is required.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'NodeStore.psm1'
if (-not $EnginePath) { $EnginePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'assets\sing-box.exe' }
if (-not $WgPath) { $WgPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'assets\wg.exe' }
Import-Module $modulePath -Force -DisableNameChecking
$module = Get-Module NodeStore
$checks = New-Object 'Collections.Generic.List[string]'
# Disposable fixtures live outside Temp: real provider clients in a temporary
# extraction directory must be rejected by the same validation used in tests.
$fixtureParent = [Environment]::GetFolderPath('LocalApplicationData')
$work = Join-Path $fixtureParent ('NodeStoreTests-' + [Guid]::NewGuid().ToString('N'))
$originalRunner = & $module { $script:TCNativeRunner }
& $module {
    $script:TCTestNativeAudit = New-Object 'Collections.Generic.List[string]'
    $script:TCTestOriginalProcess = ${function:Invoke-TCProcess}
    function script:Invoke-TCProcess {
        param($FilePath,$ArgumentList,$InputText,$TimeoutMilliseconds = 30000)
        if ($ArgumentList[0] -notin @('pubkey','check')) { throw 'Test isolation: only pubkey and check are allowed.' }
        $script:TCTestNativeAudit.Add([string]$ArgumentList[0])
        & $script:TCTestOriginalProcess -FilePath $FilePath -ArgumentList $ArgumentList -InputText $InputText -TimeoutMilliseconds $TimeoutMilliseconds
    }
    $script:TCNativeRunner = ${function:Invoke-TCProcess}
    $script:TCTestOriginalError = ${function:Stop-TCOperation}
    function script:Stop-TCOperation {
        param($Record,$Message)
        $script:TCTestInternal = ($Record.Exception.Message -replace '[A-Za-z0-9+/]{43}=', '[REDACTED]') + ' | ' + $Record.ScriptStackTrace
        & $script:TCTestOriginalError $Record $Message
    }
}
$testRunner = & $module { $script:TCNativeRunner }
$utf8 = New-Object Text.UTF8Encoding($true)
$privateKeys = @()
$failure = $null

function Assert-Test {
    param([bool]$Condition, [string]$Label)
    if (-not $Condition) { throw ('Assertion failed: ' + $Label) }
    $checks.Add($Label)
}

function Expect-Failure {
    param([scriptblock]$Action, [string]$Label)
    & $module { $script:TCTestInternal = $null; $script:TCTestDiagnostic = $null }
    $failed = $false; $leaked = $false
    try { $noise = @(& $Action *>&1) }
    catch {
        $failed = $true
        $text = ($_ | Out-String)
        foreach ($key in $privateKeys) { if ($text.Contains($key)) { $leaked = $true } }
    }
    Assert-Test $failed $Label
    Assert-Test (-not $leaked) ($Label + ': no secret in error')
    & $module { $script:TCTestInternal = $null; $script:TCTestDiagnostic = $null }
}

function Write-Fixture {
    param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText($Path, $Text, $utf8)
}

function Read-Json {
    param([string]$Path)
    return (ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Path)))
}

function Get-Hash {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function New-TestKey {
    $bytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($bytes)
        $bytes[0] = $bytes[0] -band 248
        $bytes[31] = ($bytes[31] -band 127) -bor 64
        return [Convert]::ToBase64String($bytes)
    } finally { $rng.Dispose(); [Array]::Clear($bytes, 0, $bytes.Length) }
}

function Get-TestPublicKey {
    param([string]$PrivateKey)
    $result = & $module { param($Exe,$Key) Invoke-TCProcess -FilePath $Exe -ArgumentList @('pubkey') -InputText $Key } $WgPath $PrivateKey
    if ($result.ExitCode -ne 0) { throw 'Offline key generation failed; native output suppressed.' }
    return $result.StandardOutput.Trim()
}

function New-TestConf {
    param([string]$PrivateKey, [string]$PublicKey, [string]$Endpoint = '192.0.2.10:51820', [string]$Psk = '')
    # Explicit format avoids PowerShell comma/string-concatenation ambiguity.
    $text = "[Interface]`nPrivateKey = {0}`nAddress = 10.77.0.2/24`nDNS = 1.1.1.1`nMTU = 1408`n[Peer]`nPublicKey = {1}`nEndpoint = {2}`nAllowedIPs = 0.0.0.0/0, ::/0`nPersistentKeepalive = 25`n" -f $PrivateKey,$PublicKey,$Endpoint
    if ($Psk) { $text += 'PresharedKey = ' + $Psk + "`n" }
    return $text
}

function New-TestZip {
    param([string]$Path, [hashtable]$Entries)
    Add-Type -AssemblyName System.IO.Compression,System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::Open($Path, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($entryName in $Entries.Keys) {
            $entry = $archive.CreateEntry($entryName)
            $stream = $entry.Open()
            try {
                $bytes = [Text.Encoding]::UTF8.GetBytes([string]$Entries[$entryName])
                $stream.Write($bytes, 0, $bytes.Length)
            } finally { $stream.Dispose(); [Array]::Clear($bytes, 0, $bytes.Length) }
        }
    } finally { $archive.Dispose() }
}

function Assert-PrivateAcl {
    param([string]$Path, [string]$Label, [switch]$Protected)
    $acl = Get-Acl -LiteralPath $Path
    $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
    $sids = @($rules | ForEach-Object { $_.IdentityReference.Value } | Select-Object -Unique)
    Assert-Test ($sids.Count -eq 2 -and $sids -contains 'S-1-5-18' -and $sids -contains 'S-1-5-32-544' -and @($rules | Where-Object { $_.AccessControlType -ne 'Allow' -or $_.FileSystemRights -ne 'FullControl' }).Count -eq 0) ($Label + ': SYSTEM + Administrators only')
    if ($Protected) { Assert-Test $acl.AreAccessRulesProtected ($Label + ': inheritance disabled') }
}

function Restore-Runner {
    & $module { param($Runner) $script:TCNativeRunner = $Runner } $testRunner
}

function Copy-TestObject {
    param($Value)
    return (ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $Value -Depth 40))
}

function New-TestProvider {
    param([int]$Slot, [int]$Port, $TradePort = $null, [string]$Kind = 'custom')
    $directory = Join-Path $work ('Provider ' + $Slot + ' [安装]')
    $null = [IO.Directory]::CreateDirectory($directory)
    $program = Join-Path $directory 'client.exe'
    [IO.File]::WriteAllBytes($program, [byte[]]@(0))
    return [pscustomobject][ordered]@{
        id = [Guid]::NewGuid().ToString('D'); slot = $Slot; kind = $Kind; name = ('服务商 ' + $Slot)
        directory = $directory; extraDirectories = @(); programPaths = @($program)
        dailyPort = $Port; tradePort = $TradePort; httpPort = $null; pacPort = $null
        bootstrapDomains = @('node' + $Slot + '.provider.example'); settingsDirectory = $null; addedAt = [DateTimeOffset]::UtcNow.ToString('o')
    }
}

function Assert-ProviderFailure {
    param([object[]]$Records, [string]$Label)
    Expect-Failure { ConvertTo-TCPolicyProviders -Providers $Records -TradePrograms @($tradeProgram) -AllowMissingPrograms } $Label
}

try {
    if (-not (Test-Path -LiteralPath $EnginePath -PathType Leaf) -or -not (Test-Path -LiteralPath $WgPath -PathType Leaf)) { throw 'Supply existing -EnginePath and -WgPath. The test never downloads or installs tools.' }
    & $module { param($Directory) New-TCPrivateDirectory $Directory } $work
    $root = Join-Path $work 'store A'
    $otherRoot = Join-Path $work 'store B'
    $migrationRoot = Join-Path $work 'migration'
    foreach ($sourcePath in @($modulePath,$PSCommandPath)) {
        $bytes = [IO.File]::ReadAllBytes($sourcePath)
        Assert-Test ($bytes.Length -gt 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) ('UTF8 BOM: ' + [IO.Path]::GetFileName($sourcePath))
        $tokens = $null; $errors = $null
        $null = [Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$errors)
        Assert-Test ($errors.Count -eq 0) ('Parser: ' + [IO.Path]::GetFileName($sourcePath))
    }
    $publicFunctions = @('Initialize-TCStore','Get-TCNodes','Register-TCExisting','Import-TCWireGuard','Update-TCNodePolicy','Set-TCNodeManifest','Export-TCSettings','Import-TCSettings','Rename-TCNode','ConvertFrom-TCManifestProviders','ConvertTo-TCPolicyProviders')
    Assert-Test (@(Compare-Object $publicFunctions @((Get-Command -Module NodeStore).Name)).Count -eq 0) 'Public store and provider conversion API'
    $defaultRoot = & $module { $script:TCDefaultRoot }
    Assert-Test ($defaultRoot -eq (Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'TradeChannel\Product')) 'Default CommonApplicationData root (not initialized)'
    $jobsPath = Join-Path $root 'jobs'
    $null = [IO.Directory]::CreateDirectory($jobsPath)
    $jobPath = Join-Path $jobsPath 'own-test-job.json'
    Write-Fixture $jobPath '{}'
    $initialized = @(Initialize-TCStore -Root $root *>&1)
    Assert-Test ($initialized.Count -eq 1 -and $initialized[0].nodeCount -eq 0) 'Initialize returns one business object'
    Assert-Test ([IO.File]::ReadAllText($jobPath) -eq '{}') 'GUI jobs directory coexists with store initialization'
    Assert-Test (@(Get-TCNodes -Root $root).Count -eq 0) 'Empty store yields no phantom node'
    $indexPath = Join-Path $root 'index.json'
    $initialHash = Get-Hash $indexPath
    $null = Initialize-TCStore -Root $root
    Assert-Test ((Get-Hash $indexPath) -eq $initialHash) 'Initialize is idempotent'
    Assert-PrivateAcl -Path $root -Label 'Store ACL' -Protected
    Assert-PrivateAcl -Path $indexPath -Label 'Index ACL' -Protected

    $clientKey = New-TestKey; $secondClient = New-TestKey; $serverKey = New-TestKey; $psk = New-TestKey
    $privateKeys = @($clientKey,$secondClient,$serverKey,$psk)
    $serverPublic = Get-TestPublicKey $serverKey
    $clientPublic = Get-TestPublicKey $clientKey
    $confText = New-TestConf -PrivateKey $clientKey -PublicKey $serverPublic -Psk $psk
    $confPath = Join-Path $work 'client fixture.conf'
    Write-Fixture $confPath $confText
    $sourceHash = Get-Hash $confPath
    $providerDir = Join-Path $work 'BatVPN [test] 中文'
    $null = [IO.Directory]::CreateDirectory($providerDir)
    $tradeProgram = Join-Path $work 'trade app.exe'; $providerProgram = Join-Path $providerDir 'provider app.exe'
    [IO.File]::WriteAllBytes($tradeProgram, [byte[]]@(0)); [IO.File]::WriteAllBytes($providerProgram, [byte[]]@(0))
    $common = @{Root = $root; EnginePath = $EnginePath; WgPath = $WgPath; DirectDnsIPv4 = '1.1.1.1'}

    # Spy delegates every positive check to the actual binaries, never to a success stub.
    & $module {
        $script:TCTestCalls = New-Object 'Collections.Generic.List[string]'
        $script:TCNativeRunner = {
            param($FilePath,$ArgumentList,$InputText,$TimeoutMilliseconds)
            if ($ArgumentList[0] -notin @('pubkey','check')) { throw 'Unexpected native command.' }
            $script:TCTestCalls.Add([string]$ArgumentList[0])
            $result = Invoke-TCProcess -FilePath $FilePath -ArgumentList $ArgumentList -InputText $InputText -TimeoutMilliseconds $TimeoutMilliseconds
            if ($result.ExitCode -ne 0) { $script:TCTestDiagnostic = $result.StandardError -replace '[A-Za-z0-9+/]{43}=', '[REDACTED]' }
            return $result
        }
    }
    $result = @(Import-TCWireGuard @common -Path $confPath -Name '纽约自建 / Node 1' -TradeProgramPaths @($tradeProgram) -Provider $null *>&1)
    Assert-Test ($result.Count -eq 1 -and $result[0].PSObject.Properties['manifestPath']) 'WireGuard import returns one node and no native noise'
    $first = $result[0]
    $manifest = Read-Json $first.manifestPath
    $config = Read-Json $manifest.CandidatePath
    $probe = Read-Json $manifest.ProbePath
    Assert-Test ($first.status -eq 'CandidateOnly' -and $manifest.node_id -eq $first.id -and $manifest.SyntaxValidated) 'GUID candidate is syntax validated'
    Assert-Test (-not $manifest.DeploymentApproved -and -not $manifest.IndependentGuardVerified -and -not $manifest.ServerForwardingVerified -and -not $manifest.ProcessRoutingVerified -and -not $manifest.ProviderSwitchVerified) 'No fabricated deployment or historical verification'
    Assert-Test (-not $manifest.ProviderEnabled -and @($config.outbounds | Where-Object { $_.tag -eq 'provider' }).Count -eq 0) 'Provider is optional; no BatVPN configuration dependency'
    Assert-Test (($config.outbounds | Where-Object { $_.tag -eq 'trade-exit' }).outbounds.Count -eq 1) 'Standalone selector contains hk only'
    Assert-Test ($config.endpoints[0].private_key -ceq $clientKey -and $config.endpoints[0].peers[0].pre_shared_key -ceq $psk) 'Client key and PSK preserved only in restricted config'
    Assert-Test ((Get-Hash $confPath) -eq $sourceHash) 'Source WireGuard file unchanged'
    Assert-Test ($probe.inbounds.Count -eq 1 -and $probe.inbounds[0].listen -eq '127.0.0.1' -and $probe.inbounds[0].type -eq 'mixed') 'Probe has no TUN inbound'
    Assert-Test ($config.inbounds[1].users[0].password -ceq $config.experimental.clash_api.secret -and $config.experimental.clash_api.secret.Length -ge 32) 'Loopback control and egress probe authenticated'
    Assert-PrivateAcl -Path $manifest.CandidatePath -Label 'Secret config ACL'
    Assert-PrivateAcl -Path (Split-Path $first.manifestPath -Parent) -Label 'Node directory ACL' -Protected
    $firstHash = Get-Hash $manifest.CandidatePath

    $zipPath = Join-Path $work 'different location.zip'
    $secondText = (New-TestConf -PrivateKey $secondClient -PublicKey $serverPublic -Endpoint 'gateway.example.net:443').Replace('MTU = 1408', "MTU = 1408`nListenPort = 51999")
    New-TestZip $zipPath @{'nested/client.conf' = $secondText; 'README.txt' = 'Offline fixture'}
    $provider = @{SocksPort = 10823; ProgramPaths = @($providerProgram); BootstrapDomains = @('bootstrap.example.net'); HttpPort = 8001; PacPort = 7777}
    $second = Import-TCWireGuard @common -Path $zipPath -Name '法兰克福' -TradeProgramPaths @() -Provider $provider
    $secondManifest = Read-Json $second.manifestPath
    $secondConfig = Read-Json $secondManifest.CandidatePath
    Assert-Test ($second.id -ne $first.id -and $second.manifestPath -ne $first.manifestPath) 'Nodes have independent GUIDs and artifact directories'
    Assert-Test ($secondManifest.TradeProgramPaths.Count -eq 0 -and $secondManifest.ProviderEnabled) 'TradingView-only supports an optional explicit provider'
    Assert-Test (@($secondConfig.outbounds | Where-Object { $_.tag -eq 'provider' }).Count -eq 1 -and $secondManifest.ProviderPacPort -eq 7777) 'Provider fields compiled without reading APPDATA'
    Assert-Test ($secondConfig.endpoints[0].peers[0].address -eq 'gateway.example.net' -and $secondConfig.endpoints[0].listen_port -eq 51999) 'Hostname endpoint and explicit listen port pass real check'
    Assert-Test ($secondConfig.endpoints[0].private_key -cne $config.endpoints[0].private_key -and $secondConfig.experimental.clash_api.secret -cne $config.experimental.clash_api.secret) 'Independent test identities and controller credentials'
    Assert-Test ((Get-Hash $manifest.CandidatePath) -eq $firstHash) 'Import second node leaves first config unchanged'
    # Policy v2: daily selector, provider-folder rule, auxiliary trading DNS, daily probe.
    $daily = @($secondConfig.outbounds | Where-Object { $_.tag -eq 'daily-exit' })
    Assert-Test ($daily.Count -eq 1 -and (@($daily[0].outbounds) -join ',') -eq 'direct,provider' -and $daily[0].default -eq 'direct') 'Daily selector defaults to direct and offers the provider'
    Assert-Test ((@(($config.outbounds | Where-Object { $_.tag -eq 'daily-exit' }).outbounds) -join ',') -eq 'direct') 'Without a provider the daily selector is direct only'
    $providerRule = @($secondConfig.route.rules | Where-Object { $_.PSObject.Properties['type'] -and $_.type -eq 'logical' -and $_.outbound -eq 'direct' })
    Assert-Test ($providerRule.Count -eq 1 -and $secondManifest.ProviderDirectory -eq $providerDir -and $secondManifest.PolicyVersion -eq 4) 'Provider install folder bypass has a watched AI exclusion'
    $rules = @($secondConfig.route.rules)
    $tail = $rules[$rules.Count - 2]
    Assert-Test ($tail.outbound -eq 'daily-exit' -and (@($tail.process_path_regex) -join '') -eq '.+' -and -not $rules[$rules.Count - 1].PSObject.Properties['outbound']) 'Identified daily traffic uses daily-exit; unidentified traffic is rejected'
    $firstProviderRules = @($config.route.rules | Where-Object { $_.PSObject.Properties['process_path_regex'] -and $_.outbound -eq 'direct' })
    Assert-Test ($firstProviderRules.Count -eq 0) 'No provider folder rule without a provider'
    $tradeDns = @($secondConfig.dns.rules | Where-Object { $_.PSObject.Properties['domain_suffix'] -and $_.server -eq 'dns-trade' })
    Assert-Test ($tradeDns.Count -eq 1 -and @($tradeDns[0].domain_suffix) -contains 'launchdarkly.com' -and @($tradeDns[0].domain_suffix) -contains 'statsigapi.net') 'NinjaTrader auxiliary names resolve on the trade exit'
    Assert-Test ((@($secondConfig.inbounds[1].users | ForEach-Object { $_.username }) -join ',') -eq 'tradechannel-probe,tradechannel-daily') 'Daily probe user shares the probe credential'
    $bootstrapRule = @($secondConfig.dns.rules | Where-Object { $_.PSObject.Properties['domain'] -and $_.server -eq 'dns-direct' })
    Assert-Test ($bootstrapRule.Count -eq 1 -and @($bootstrapRule[0].domain) -contains 'bootstrap.example.net' -and @($bootstrapRule[0].domain) -contains 'gateway.example.net' -and -not $bootstrapRule[0].PSObject.Properties['domain_suffix']) 'Provider and tunnel bootstrap use exact names without widening the DNS bypass'
    # Policy v3: the AI assistant list is two watched rule-sets, after trading and global rules.
    $agentDir = Join-Path (Split-Path $root -Parent) 'agents'
    $agentSets = @($secondConfig.route.rule_set)
    Assert-Test ($agentSets.Count -eq 2 -and $agentSets[0].tag -eq 'tc-agents' -and $agentSets[0].type -eq 'local' -and $agentSets[0].path -eq (Join-Path $agentDir 'agents-route.json') -and $agentSets[1].tag -eq 'tc-agents-dns' -and $agentSets[1].path -eq (Join-Path $agentDir 'agents-dns.json')) 'Assistant list is two watched local rule-sets beside the store'
    $emptySet = Read-Json (Join-Path $agentDir 'agents-route.json')
    Assert-Test ($emptySet.version -eq 3 -and @($emptySet.rules).Count -eq 0 -and $secondManifest.AgentRuleSetPath -eq $agentSets[0].path -and $secondManifest.AgentDnsRuleSetPath -eq $agentSets[1].path) 'Policy step creates an empty list that routes nothing'
    Assert-PrivateAcl -Path $agentDir -Label 'Assistant list directory ACL' -Protected
    $at = { param($Predicate) for ($i = 0; $i -lt $rules.Count; $i++) { if (& $Predicate $rules[$i]) { return $i } }; return -1 }
    $providerAt = & $at { param($r) $r.PSObject.Properties['type'] -and $r.type -eq 'logical' -and $r.PSObject.Properties['outbound'] -and $r.outbound -eq 'direct' }
    $tradeAt = & $at { param($r) $r.PSObject.Properties['domain_suffix'] -and $r.PSObject.Properties['outbound'] -and $r.outbound -eq 'trade-exit' }
    $globalAt = & $at { param($r) $r.PSObject.Properties['clash_mode'] -and $r.PSObject.Properties['outbound'] -and $r.outbound -eq 'trade-exit' }
    $agentRejectAt = & $at { param($r) $r.PSObject.Properties['rule_set'] -and $r.PSObject.Properties['ip_version'] -and $r.action -eq 'reject' }
    $agentAt = & $at { param($r) $r.PSObject.Properties['rule_set'] -and $r.PSObject.Properties['outbound'] -and $r.outbound -eq 'trade-exit' }
    $dailyAt = & $at { param($r) $r.PSObject.Properties['process_path_regex'] -and $r.PSObject.Properties['outbound'] -and $r.outbound -eq 'daily-exit' }
    Assert-Test ($providerAt -ge 0 -and $tradeAt -gt $providerAt -and $globalAt -gt $tradeAt -and $agentRejectAt -eq $globalAt + 1 -and $agentAt -eq $agentRejectAt + 1 -and $dailyAt -eq $agentAt + 1) 'Assistant rules sit after provider, trading and global rules, before daily traffic'
    $dnsRules = @($secondConfig.dns.rules); $agentDns = @($dnsRules | Where-Object { $_.PSObject.Properties['rule_set'] })
    $declaredModes = @($dnsRules | Where-Object { $_.PSObject.Properties['clash_mode'] } | ForEach-Object { $_.clash_mode })
    Assert-Test ($declaredModes -contains 'rule' -and $declaredModes -contains 'global' -and $dnsRules[-1].server -eq $secondConfig.dns.final) 'Both modes remain available after maintenance chooses a global startup; rule DNS fallback keeps its original target'
    Assert-Test ($agentDns.Count -eq 1 -and (@($agentDns[0].rule_set) -join ',') -eq 'tc-agents-dns' -and $agentDns[0].server -eq 'dns-trade' -and $agentDns[0].strategy -eq 'ipv4_only') 'Listed assistant sites resolve on the trading line'
    Assert-Test ([array]::IndexOf($dnsRules, $agentDns[0]) -gt [array]::IndexOf($dnsRules, $bootstrapRule[0])) 'Provider names keep local DNS ahead of the assistant list'
    $guarded = & $module { param($Provider, $Trade) Get-TCProviderRoot @($Provider) @($Trade) } $providerProgram (Join-Path $providerDir 'trade app.exe')
    Assert-Test ($null -eq $guarded) 'Provider folder holding a trading program is never trusted'
    $ipv6Path = Join-Path $work 'ipv6 endpoint.conf'
    Write-Fixture $ipv6Path (New-TestConf -PrivateKey $secondClient -PublicKey $serverPublic -Endpoint '[2001:db8::10]:51820')
    $third = Import-TCWireGuard @common -Path $ipv6Path -Name 'IPv6 transport' -TradeProgramPaths $null -Provider @{}
    Assert-Test ($third.endpoint -eq '[2001:db8::10]:51820') 'Browser-only standalone node accepts IPv6 transport endpoint'
    $thirdManifest = Read-Json $third.manifestPath
    Assert-Test (-not $thirdManifest.ProviderEnabled -and $thirdManifest.TradeProgramPaths.Count -eq 0) 'Null programs and empty provider dictionary are supported'
    $calls = @(& $module { $script:TCTestCalls.ToArray() })
    Assert-Test (@($calls | Where-Object { $_ -eq 'check' }).Count -eq 6 -and @($calls | Where-Object { $_ -eq 'pubkey' }).Count -eq 3) 'Both artifacts for all three nodes passed actual sing-box check'
    Restore-Runner

    $nodes = @(Get-TCNodes -Root $root)
    $fields = @('id','name','kind','endpoint','manifestPath','registeredAt','status')
    Assert-Test ($nodes.Count -eq 3 -and @(Compare-Object $fields @($nodes[0].PSObject.Properties.Name)).Count -eq 0) 'Get-TCNodes exposes exactly seven public fields'
    $nodeJson = ConvertTo-Json -InputObject $nodes -Depth 10
    foreach ($key in $privateKeys) { Assert-Test (-not $nodeJson.Contains($key)) 'No private key in returned node objects' }
    $manifestHash = Get-Hash $first.manifestPath
    $renamed = Rename-TCNode -Root $root -Id $first.id -Name '芝加哥任意名称'
    Assert-Test ($renamed.name -eq '芝加哥任意名称' -and $renamed.id -eq $first.id -and $renamed.registeredAt -eq $first.registeredAt) 'Rename changes metadata while retaining identity'
    Assert-Test ((Get-Hash $first.manifestPath) -eq $manifestHash -and (Get-Hash $manifest.CandidatePath) -eq $firstHash) 'Rename does not rewrite checked artifacts'
    $sourceAcl = (Get-Acl -LiteralPath $first.manifestPath).Sddl
    $registered = Register-TCExisting -Root $otherRoot -ManifestPath $first.manifestPath -Name '只读接管'
    $registeredAgain = Register-TCExisting -Root $otherRoot -ManifestPath $first.manifestPath -Name '接管改名'
    Assert-Test ($registered.status -eq 'Registered' -and $registeredAgain.id -eq $registered.id -and @(Get-TCNodes -Root $otherRoot).Count -eq 1) 'Register is idempotent and does not assume validation'
    Assert-Test ((Get-Hash $first.manifestPath) -eq $manifestHash -and (Get-Acl -LiteralPath $first.manifestPath).Sddl -eq $sourceAcl -and (Get-Hash $manifest.CandidatePath) -eq $firstHash) 'Register leaves source contents and ACL untouched'

    $exportPath = Join-Path $work 'settings.json'
    $exported = @(Export-TCSettings -Root $root -Destination $exportPath *>&1)
    Assert-Test ($exported.Count -eq 1 -and $exported[0].nodeCount -eq 3) 'Export returns one business object'
    $package = Read-Json $exportPath
    $exportText = [IO.File]::ReadAllText($exportPath)
    Assert-Test (@(Compare-Object @('schemaVersion','nodes','tradeDomains','providerReferences') @($package.PSObject.Properties.Name)).Count -eq 0) 'Migration top-level field allowlist'
    Assert-Test ($package.providerReferences.Count -eq 1 -and $package.providerReferences[0].kind -eq 'batvpn' -and $package.providerReferences[0].status -eq 'PendingDetection') 'Legacy provider exports a rediscovery reference only'
    foreach ($node in $package.nodes) { Assert-Test (@(Compare-Object @('name','kind','endpoint') @($node.PSObject.Properties.Name)).Count -eq 0) 'Migration contains metadata only' }
    Assert-Test ($exportText -notmatch '(?i)manifest|private.?key|preshared|validated|verified|approved|registeredAt|[A-Z]:\\\\') 'No credentials, paths, IDs, dates or passed state in migration'
    foreach ($key in $privateKeys) { Assert-Test (-not $exportText.Contains($key)) 'No private material in export' }
    $imported = Import-TCSettings -Root $migrationRoot -Path $exportPath
    Assert-Test ($imported.importedCount -eq 3 -and $imported.nodes.Count -eq 3) 'Settings import returns nodes and count'
    foreach ($node in $imported.nodes) {
        Assert-Test ($node.status -eq 'PendingAuthorization' -and $null -eq $node.manifestPath -and $nodes.id -notcontains $node.id) 'Migrated node has new GUID and no activatable manifest'
    }
    Assert-Test (@(Get-ChildItem -LiteralPath (Join-Path $migrationRoot 'nodes') -Force).Count -eq 0) 'Settings migration creates no identity artifacts'
    $emptyRoot = Join-Path $work 'empty'; $emptyExport = Join-Path $work 'empty.json'
    $null = Export-TCSettings -Root $emptyRoot -Destination $emptyExport
    $emptyImported = Import-TCSettings -Root $migrationRoot -Path $emptyExport
    Assert-Test ($emptyImported.importedCount -eq 0 -and $emptyImported.nodes -is [array]) 'Empty arrays survive round-trip'

    $stableIndex = Get-Hash $indexPath
    $badConf = Join-Path $work 'invalid.conf'
    $invalidConfigs = [ordered]@{
        'Multiple peers' = ($confText + "`n[Peer]`nPublicKey = " + $serverPublic)
        'Hooks' = $confText.Replace('[Interface]', "[Interface]`nPostUp = do-not-run")
        'Restricted peer' = $confText.Replace('0.0.0.0/0, ::/0','10.0.0.0/8')
        'Invalid client key' = $confText.Replace($clientKey,'NOT-A-KEY')
        'Client used as server key' = $confText.Replace($serverPublic,$clientPublic)
        'Invalid endpoint' = $confText.Replace('192.0.2.10:51820','999.999.999.999:70000')
        'Unknown field' = ($confText + "`nUnknown = rejected")
        'Duplicate key' = $confText.Replace('[Interface]', "[Interface]`nPrivateKey = " + $clientKey)
        'Invalid MTU' = $confText.Replace('MTU = 1408','MTU = 9000')
        'Invalid address' = $confText.Replace('10.77.0.2/24','10.77.0.2/99')
        'Invalid keepalive' = $confText.Replace('PersistentKeepalive = 25','PersistentKeepalive = -1')
    }
    foreach ($label in $invalidConfigs.Keys) {
        Write-Fixture $badConf $invalidConfigs[$label]
        Expect-Failure { Import-TCWireGuard @common -Path $badConf -Name 'invalid' } $label
    }
    Write-Fixture $badConf ('#' * 131073)
    Expect-Failure { Import-TCWireGuard @common -Path $badConf -Name 'oversized' } 'Oversized conf'
    $badZip = Join-Path $work 'traversal.zip'
    New-TestZip $badZip @{'../../escaped.conf' = $confText}
    Expect-Failure { Import-TCWireGuard @common -Path $badZip -Name 'bad ZIP' } 'ZIP slip traversal'
    $driveZip = Join-Path $work 'drive.zip'
    New-TestZip $driveZip @{'C:\outside.conf' = $confText}
    Expect-Failure { Import-TCWireGuard @common -Path $driveZip -Name 'bad ZIP' } 'ZIP rooted Windows path'
    $bigZip = Join-Path $work 'oversized.zip'
    New-TestZip $bigZip @{'client.conf' = $confText; 'large.txt' = ('0' * 131073)}
    Expect-Failure { Import-TCWireGuard @common -Path $bigZip -Name 'bad ZIP' } 'ZIP expansion limit for all entries'
    $multiZip = Join-Path $work 'multiple.zip'
    New-TestZip $multiZip @{'one.conf' = $confText; 'two.conf' = $confText}
    Expect-Failure { Import-TCWireGuard @common -Path $multiZip -Name 'bad ZIP' } 'ZIP multiple configs'
    $corruptZip = Join-Path $work 'corrupt.zip'; Write-Fixture $corruptZip 'not a zip'
    Expect-Failure { Import-TCWireGuard @common -Path $corruptZip -Name 'bad ZIP' } 'Corrupt ZIP'
    Expect-Failure { Import-TCWireGuard @common -Path $confPath -Name 'bad provider' -Provider @{SocksPort = 17891; ProgramPaths = @($providerProgram)} } 'Provider controller port collision'
    Expect-Failure { Import-TCWireGuard @common -Path $confPath -Name 'bad overlap' -TradeProgramPaths @($tradeProgram) -Provider @{SocksPort = 10823; ProgramPaths = @($tradeProgram)} } 'Provider/trading process overlap'
    Expect-Failure { Import-TCWireGuard @common -Path $confPath -Name 'bad path' -TradeProgramPaths @('relative.exe') } 'Relative application path'
    Expect-Failure { Rename-TCNode -Root $root -Id 'not-guid' -Name 'invalid' } 'Invalid GUID'
    Expect-Failure { Rename-TCNode -Root $root -Id ([Guid]::NewGuid().ToString('D')) -Name 'missing' } 'Unknown node ID'
    Expect-Failure { Rename-TCNode -Root $root -Id $first.id -Name "bad`nname" } 'Control character in name'
    Expect-Failure { Export-TCSettings -Root $root -Destination $indexPath } 'Export cannot overwrite store'
    Expect-Failure { Export-TCSettings -Root $root -Destination $exportPath } 'Export cannot overwrite existing destination'
    Assert-Test ((Get-Hash $indexPath) -eq $stableIndex) 'Invalid imports leave index byte-for-byte unchanged'

    $badSettings = Join-Path $work 'bad-settings.json'
    $migrationIndex = Join-Path $migrationRoot 'index.json'; $migrationHash = Get-Hash $migrationIndex
    foreach ($fixture in @(
        '{broken',
        '{"schemaVersion":2,"nodes":[],"tradeDomains":[]}',
        '{"schemaVersion":1,"nodes":{},"tradeDomains":[]}',
        '{"schemaVersion":1,"nodes":[],"tradeDomains":["https://bad.example"]}',
        '{"schemaVersion":1,"nodes":[{"name":"n","kind":"wireguard","endpoint":"192.0.2.2:123","manifestPath":"C:\\untrusted.json"}],"tradeDomains":[]}',
        '{"schemaVersion":1,"nodes":[],"tradeDomains":[],"PrivateKey":"DO-NOT-IMPORT"}',
        '{"schemaVersion":1,"nodes":[{"name":"n","kind":"wireguard","endpoint":"invalid"}],"tradeDomains":[]}'
    )) {
        Write-Fixture $badSettings $fixture
        Expect-Failure { Import-TCSettings -Root $migrationRoot -Path $badSettings } 'Invalid/malicious migration input'
    }
    Assert-Test ((Get-Hash $migrationIndex) -eq $migrationHash) 'Invalid settings cause no partial import'
    $corruptRoot = Join-Path $work 'corrupt-store'; $null = Initialize-TCStore -Root $corruptRoot
    $corruptIndex = Join-Path $corruptRoot 'index.json'; Write-Fixture $corruptIndex '{broken'
    $corruptHash = Get-Hash $corruptIndex
    Expect-Failure { Initialize-TCStore -Root $corruptRoot } 'Corrupt index is not reset'
    Assert-Test ((Get-Hash $corruptIndex) -eq $corruptHash) 'Corrupt index retained for recovery'

    # Failure injection covers key validation, either check, and atomic index commit.
    foreach ($failAt in @('pubkey','first-check','second-check','index-commit')) {
        & $module {
            param($FailureMode,$IndexPath,$Secret)
            $script:TCTestFailure = $FailureMode; $script:TCTestIndexPath = $IndexPath
            $script:TCTestSecret = $Secret; $script:TCTestCheckCount = 0; $script:TCTestIndexHandle = $null
            $script:TCNativeRunner = {
                param($FilePath,$ArgumentList,$InputText,$TimeoutMilliseconds)
                if ($ArgumentList[0] -eq 'check') { $script:TCTestCheckCount++ }
                if (($script:TCTestFailure -eq 'pubkey' -and $ArgumentList[0] -eq 'pubkey') -or ($script:TCTestFailure -eq 'first-check' -and $script:TCTestCheckCount -eq 1) -or ($script:TCTestFailure -eq 'second-check' -and $script:TCTestCheckCount -eq 2)) {
                    return [pscustomobject]@{ExitCode = 7; StandardOutput = $script:TCTestSecret; StandardError = $script:TCTestSecret}
                }
                $native = Invoke-TCProcess -FilePath $FilePath -ArgumentList $ArgumentList -InputText $InputText -TimeoutMilliseconds $TimeoutMilliseconds
                if ($script:TCTestFailure -eq 'index-commit' -and $script:TCTestCheckCount -eq 2) {
                    $script:TCTestIndexHandle = [IO.File]::Open($script:TCTestIndexPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
                }
                return $native
            }
        } $failAt $indexPath $clientKey
        try { Expect-Failure { Import-TCWireGuard @common -Path $confPath -Name 'injected failure' } ('Injected ' + $failAt) }
        finally {
            & $module { if ($script:TCTestIndexHandle) { $script:TCTestIndexHandle.Dispose(); $script:TCTestIndexHandle = $null }; $script:TCTestSecret = $null }
            Restore-Runner
        }
        Assert-Test ((Get-Hash $indexPath) -eq $stableIndex) ($failAt + ': atomic index unchanged')
        Assert-Test (@(Get-ChildItem -LiteralPath (Join-Path $root '.staging') -Force).Count -eq 0 -and @(Get-ChildItem -LiteralPath (Join-Path $root 'nodes') -Directory).Count -eq 3) ($failAt + ': no orphan secret artifacts')
    }
    # Upgrade rebuilds the policy into a new checked candidate; the source is untouched.
    $before = Get-Hash $secondManifest.CandidatePath
    # A saved list must survive an upgrade, and the real engine check must accept it.
    $savedList = '{"version":3,"rules":[{"process_path_regex":["(?i)\\\\claude\\.exe$"]},{"process_path_regex":["(?i)\\\\(chrome|msedge)\\.exe$"],"domain_suffix":["chatgpt.com"]}]}'
    [IO.File]::WriteAllText((Join-Path $agentDir 'agents-route.json'), $savedList, (New-Object Text.UTF8Encoding($false)))
    $upgraded = Update-TCNodePolicy -Root $root -ManifestPath $second.manifestPath -BootstrapDomains @('node2.example.net')
    $upManifest = Read-Json $upgraded.ManifestPath
    $upConfig = Read-Json $upgraded.CandidatePath
    Assert-Test ((Get-Hash $secondManifest.CandidatePath) -eq $before -and $upgraded.PreviousManifestPath -eq $second.manifestPath) 'Upgrade never edits the source configuration'
    Assert-Test ($upgraded.CandidatePath.StartsWith((Join-Path (Split-Path $root -Parent) 'configs\policy4-'), [StringComparison]::OrdinalIgnoreCase) -and -not $upManifest.DeploymentApproved -and $upManifest.PolicyVersion -eq 4) 'Upgraded candidate is separate and awaits activation'
    Assert-Test (@($upConfig.route.rule_set).Count -eq 2 -and $upManifest.AgentRuleSetPath -eq (Join-Path $agentDir 'agents-route.json') -and [IO.File]::ReadAllText((Join-Path $agentDir 'agents-route.json')) -ceq $savedList) 'Upgrade keeps the saved assistant list and passes the real check with it'
    Assert-Test ($upConfig.endpoints[0].private_key -ceq $secondConfig.endpoints[0].private_key -and $upConfig.experimental.clash_api.secret -ceq $secondConfig.experimental.clash_api.secret) 'Tunnel identity and controller secret carried over'
    Assert-Test (@($upManifest.ProviderBootstrapDomains) -contains 'node2.example.net' -and @($upManifest.ProviderBootstrapDomains) -contains 'bootstrap.example.net') 'Current provider node name added to local bootstrap'
    Assert-PrivateAcl -Path $upgraded.CandidatePath -Label 'Upgraded secret config ACL'
    $moved = @(Set-TCNodeManifest -Root $root -PreviousManifestPath $second.manifestPath -ManifestPath $upgraded.ManifestPath)
    Assert-Test ($moved.Count -eq 1 -and $moved[0].id -eq $second.id -and $moved[0].manifestPath -eq $upgraded.ManifestPath) 'Node record follows the activated upgrade'
    $null = Set-TCNodeManifest -Root $root -PreviousManifestPath $upgraded.ManifestPath -ManifestPath $second.manifestPath
    Assert-Test (@(Get-ChildItem -LiteralPath $root -Filter '.tc-*.tmp' -Recurse -Force).Count -eq 0) 'No temporary JSON remains'
    Assert-Test ((Get-Hash $manifest.CandidatePath) -eq $firstHash -and (Get-Hash $first.manifestPath) -eq $manifestHash) 'All failure paths preserve existing node artifacts'

    # Four providers: stable slots, shared mixed ports and dedicated trade ports.
    $records = @((New-TestProvider 1 10823 $null 'batvpn'), (New-TestProvider 2 7890 7895 'clashverge'), (New-TestProvider 3 10900 10900), (New-TestProvider 4 10910 10911 'clash'))
    $records[1].httpPort = 7890
    $records[1].bootstrapDomains = @('edge.provider.co.uk')
    $records[0].pacPort = 7777
    $extraDir = Join-Path $work 'Provider 2 extra core'
    $null = [IO.Directory]::CreateDirectory($extraDir)
    $extraProgram = Join-Path $extraDir 'core.exe'
    [IO.File]::WriteAllBytes($extraProgram, [byte[]]@(0))
    $records[1].extraDirectories = @($extraDir); $records[1].programPaths += $extraProgram
    $records[1].settingsDirectory = $extraDir
    $shaped = @(ConvertTo-TCPolicyProviders -Providers @($records[3],$records[1],$records[0],$records[2]) -TradePrograms @($tradeProgram))
    Assert-Test (($shaped.Tag -join ',') -eq 'provider,provider2,provider3,provider4' -and ($shaped.TradeTag -join ',') -eq 'provider,provider2-trade,provider3,provider4-trade') 'Stable slots determine daily and trade tags regardless of input order'
    Assert-Test (($shaped.TradePort -join ',') -eq '10823,7895,10900,10911' -and $shaped[1].HttpPort -eq $shaped[1].Port) 'Null and equal trade ports reuse daily; mixed HTTP aliases are supported'
    $multiRoot = Join-Path $work 'multi store'
    $multiArgs = @{Root = $multiRoot; EnginePath = $EnginePath; WgPath = $WgPath; DirectDnsIPv4 = '1.1.1.1'; Path = $confPath; TradeProgramPaths = @($tradeProgram)}
    $multiNode = Import-TCWireGuard @multiArgs -Name '四服务商' -Providers @($records[3],$records[1],$records[0],$records[2])
    $multiManifest = Read-Json $multiNode.manifestPath; $multiConfig = Read-Json $multiManifest.CandidatePath
    $tradeSelector = @($multiConfig.outbounds | Where-Object { $_.tag -eq 'trade-exit' })[0]
    $dailySelector = @($multiConfig.outbounds | Where-Object { $_.tag -eq 'daily-exit' })[0]
    Assert-Test (($tradeSelector.outbounds -join ',') -eq 'hk,provider,provider2-trade,provider3,provider4-trade' -and $tradeSelector.default -eq 'hk') 'Trading selector offers exactly hk and actual trade tags'
    Assert-Test (($dailySelector.outbounds -join ',') -eq 'direct,provider,provider2,provider3,provider4' -and $dailySelector.default -eq 'direct') 'Daily selector excludes every dedicated trade outbound'
    Assert-Test ($multiConfig.outbounds.Count -eq 9 -and @($multiConfig.outbounds.tag | Select-Object -Unique).Count -eq 9) 'All generated outbounds have unique tags'
    foreach ($p in $multiManifest.Providers) {
        $dailyOut = @($multiConfig.outbounds | Where-Object { $_.tag -eq $p.Tag })[0]
        $tradeOut = @($multiConfig.outbounds | Where-Object { $_.tag -eq $p.TradeTag })[0]
        Assert-Test ($dailyOut.server_port -eq $p.Port -and $tradeOut.server_port -eq $p.TradePort -and $dailyOut.server -eq '127.0.0.1' -and $tradeOut.server -eq '127.0.0.1') ('Manifest ports map to actual loopback listeners: ' + $p.Tag)
    }
    $roundTrip = @(ConvertTo-TCPolicyProviders -Providers @(ConvertFrom-TCManifestProviders $multiManifest) -TradePrograms @($tradeProgram))
    Assert-Test ((ConvertTo-Json -InputObject $roundTrip -Depth 30 -Compress) -ceq (ConvertTo-Json -InputObject $shaped -Depth 30 -Compress)) 'Manifest provider metadata round-trips without losing trade ports, extra roots or bootstrap domains'
    $policyTail = @($multiConfig.route.rules | Select-Object -Skip 2)
    Assert-Test ((ConvertTo-Json -InputObject $policyTail -Depth 30 -Compress) -ceq (ConvertTo-Json -InputObject $config.route.rules -Depth 30 -Compress)) 'Trading, IPv6, probes, global, AI and unidentified routing rules remain identical'
    Assert-Test ((ConvertTo-Json -InputObject $multiConfig.inbounds[0] -Depth 15 -Compress) -ceq (ConvertTo-Json -InputObject $config.inbounds[0] -Depth 15 -Compress)) 'TUN settings remain identical'
    $folderBypass = $multiConfig.route.rules[1]
    $patterns = @($folderBypass.rules[0].process_path_regex)
    $renamedCore = Join-Path $extraDir 'next-version.exe'
    $assistantInFolder = Join-Path $records[1].directory 'claude.exe'
    Assert-Test ($folderBypass.mode -eq 'and' -and $folderBypass.rules[1].invert -and ($folderBypass.rules[1].rule_set -join ',') -eq 'tc-agents') 'Folder bypass excludes watched AI rules instead of swallowing assistant traffic'
    Assert-Test (@($patterns | Where-Object { $renamedCore -match $_ }).Count -eq 1 -and @($patterns | Where-Object { $assistantInFolder -match $_ }).Count -eq 1 -and $assistantInFolder -match '(?i)\\claude\.exe$') 'Renamed provider cores match while collocated selected assistants have the AI exclusion'
    Assert-Test (@($patterns | Where-Object { ($records[1].directory + '-other\core.exe') -match $_ }).Count -eq 0 -and @($patterns | Where-Object { $tradeProgram -match $_ }).Count -eq 0) 'Bypass boundaries do not include sibling folders or trading programs'
    Assert-Test ($multiConfig.dns.rules[1].mode -eq 'and' -and $multiConfig.dns.rules[1].rules[1].invert) 'Provider directory DNS bypass also excludes assistant programs'
    $exactDns = @($multiConfig.dns.rules | Where-Object { $_.PSObject.Properties['domain'] -and $_.server -eq 'dns-direct' })[0]
    Assert-Test (@($exactDns.domain) -contains 'edge.provider.co.uk' -and @($exactDns.domain) -notcontains 'co.uk' -and @($multiConfig.dns.rules | Where-Object { $_.PSObject.Properties['domain_suffix'] -and $_.server -eq 'dns-direct' }).Count -eq 0) 'Multi-label public suffixes never become a direct DNS bypass'
    $sparse = @(ConvertTo-TCPolicyProviders -Providers @($records[3]))
    Assert-Test ($sparse.Count -eq 1 -and $sparse[0].Tag -eq 'provider4' -and $sparse[0].TradeTag -eq 'provider4-trade') 'A deleted slot is never renumbered or reused implicitly'

    $multiHash = Get-Hash $multiManifest.CandidatePath
    $keep = Update-TCNodePolicy -Root $multiRoot -ManifestPath $multiNode.manifestPath
    $keepManifest = Read-Json $keep.ManifestPath
    Assert-Test ((ConvertTo-Json -InputObject $keepManifest.Providers -Depth 30 -Compress) -ceq (ConvertTo-Json -InputObject $multiManifest.Providers -Depth 30 -Compress) -and -not $keepManifest.ProviderSwitchVerified) 'Upgrade preserves provider identity and clears provider verification'
    $changedProviders = @(foreach ($record in $records) { Copy-TestObject $record })
    $changedProviders[1].bootstrapDomains = @('new-upstream.other.co.uk')
    $refreshed = Update-TCNodePolicy -Root $multiRoot -ManifestPath $multiNode.manifestPath -ReplaceProviders -Providers $changedProviders
    $refreshedManifest = Read-Json $refreshed.ManifestPath; $refreshedConfig = Read-Json $refreshed.CandidatePath
    $refreshedDns = @($refreshedConfig.dns.rules | Where-Object { $_.PSObject.Properties['domain'] -and $_.server -eq 'dns-direct' })[0]
    Assert-Test (($refreshedManifest.Providers[1].BootstrapDomains -join ',') -eq 'new-upstream.other.co.uk' -and $refreshedManifest.Providers[1].Port -eq $multiManifest.Providers[1].Port -and $refreshedManifest.Providers[1].Id -eq $multiManifest.Providers[1].Id) 'Manifest exposes upstream changes even when provider ID and port stay the same'
    Assert-Test (@($refreshedDns.domain) -contains 'new-upstream.other.co.uk' -and @($refreshedDns.domain) -notcontains 'edge.provider.co.uk' -and @($refreshedManifest.ProviderBootstrapDomains) -notcontains 'edge.provider.co.uk') 'Explicit provider refresh replaces obsolete bootstrap names without suffix expansion'
    $removed = Update-TCNodePolicy -Root $multiRoot -ManifestPath $multiNode.manifestPath -ReplaceProviders -Providers @()
    $removedManifest = Read-Json $removed.ManifestPath; $removedConfig = Read-Json $removed.CandidatePath
    Assert-Test (-not $removedManifest.ProviderEnabled -and $removedManifest.Providers.Count -eq 0 -and $removedManifest.ProviderBootstrapDomains.Count -eq 0 -and ($removedConfig.outbounds | Where-Object { $_.tag -eq 'trade-exit' }).outbounds.Count -eq 1) 'Explicit empty replacement removes provider outbounds and stale bootstrap references'
    Assert-Test (@(ConvertFrom-TCManifestProviders $removedManifest).Count -eq 0 -and (Get-Hash $multiManifest.CandidatePath) -eq $multiHash) 'Empty Providers is authoritative and source candidates remain untouched'
    Expect-Failure { Update-TCNodePolicy -Root $multiRoot -ManifestPath $multiNode.manifestPath -Providers @($records[0]) } 'Replacement cannot be silently ignored without ReplaceProviders'
    Expect-Failure { Import-TCWireGuard @multiArgs -Name 'ambiguous' -Provider $provider -Providers $records } 'Old and new provider arguments cannot be mixed'
    $legacyManifest = Copy-TestObject $secondManifest
    foreach ($field in @('Providers','ProviderDirectory','ProviderTradePort')) { $legacyManifest.PSObject.Properties.Remove($field) }
    $legacyManifest.PolicyVersion = 3
    $legacyPath = Join-Path $work 'legacy-manifest.json'; Write-Fixture $legacyPath (ConvertTo-Json $legacyManifest -Depth 30)
    $legacyUpgrade = Update-TCNodePolicy -Root $root -ManifestPath $legacyPath
    $legacyUp = Read-Json $legacyUpgrade.ManifestPath
    Assert-Test ($legacyUp.Providers.Count -eq 1 -and $legacyUp.Providers[0].Tag -eq 'provider' -and $legacyUp.Providers[0].TradeTag -eq 'provider' -and $legacyUp.Providers[0].TradePort -eq 10823) 'Pre-profile BatVPN manifest upgrades with the historical selector tag'

    # Validation covers every endpoint role, stale records and widening bypasses.
    foreach ($portField in @('dailyPort','tradePort','httpPort','pacPort')) {
        foreach ($badPort in @(0,65536,-1,'abc','',17890,17891)) {
            $bad = Copy-TestObject $records[0]; $bad.$portField = $badPort
            Assert-ProviderFailure @($bad) ('Invalid or reserved ' + $portField)
        }
        $bad = Copy-TestObject $records[1]; $bad.$portField = $records[0].dailyPort
        Assert-ProviderFailure @($records[0],$bad) ('Cross-provider collision on ' + $portField)
    }
    $mutations = [ordered]@{
        'Duplicate slot' = { param($r) $r.slot = 1 }
        'Duplicate identity' = { param($r) $r.id = $records[0].id }
        'Empty GUID' = { param($r) $r.id = [Guid]::Empty.ToString() }
        'Out-of-range slot' = { param($r) $r.slot = 5 }
        'Fractional slot' = { param($r) $r.slot = 1.5 }
        'Unknown kind' = { param($r) $r.kind = 'invalid' }
        'Invalid name' = { param($r) $r.name = "bad`nname" }
        'Invalid date' = { param($r) $r.addedAt = 'not a date' }
        'Program array required' = { param($r) $r.programPaths = $r.programPaths[0] }
        'Directory array required' = { param($r) $r.extraDirectories = $extraDir }
        'Domain array required' = { param($r) $r.bootstrapDomains = 'node.example.net' }
        'Invalid bootstrap domain' = { param($r) $r.bootstrapDomains = @('https://node.example.net/path') }
        'Programs must be contained' = { param($r) $r.programPaths = @($providerProgram) }
        'Trading directory overlap' = { param($r) $r.extraDirectories += $work }
        'Provider directory overlap' = { param($r) $r.extraDirectories += $records[0].directory }
        'Credential field forbidden' = { param($r) $r | Add-Member -NotePropertyName password -NotePropertyValue 'DO-NOT-EXPORT' }
        'AI core forbidden' = { param($r) $r.programPaths = @((Join-Path $r.directory 'codex.exe')) }
        'Browser core forbidden' = { param($r) $r.programPaths = @((Join-Path $r.directory 'chrome.exe')) }
        'Relative directory forbidden' = { param($r) $r.directory = 'relative\client' }
        'Missing directory forbidden' = { param($r) $r.directory = $null }
    }
    foreach ($label in $mutations.Keys) {
        $bad = Copy-TestObject $records[1]; & $mutations[$label] $bad
        Assert-ProviderFailure @($records[0],$bad) $label
    }
    foreach ($badDirectory in @($env:LOCALAPPDATA, (Join-Path $env:LOCALAPPDATA 'Programs'), $env:ProgramFiles, $env:APPDATA, $env:USERPROFILE, (Join-Path $env:TEMP '7z-test\Client'))) {
        $bad = Copy-TestObject $records[1]; $bad.extraDirectories = @($badDirectory)
        Assert-ProviderFailure @($bad) 'Shared and temporary provider roots are forbidden'
    }
    Assert-ProviderFailure @($records + @($records[0])) 'At most four provider slots'
    Assert-ProviderFailure @($null) 'Null provider records are rejected instead of dropped'
    $bad = Copy-TestObject $records[0]; $bad.tradePort = 51999
    Expect-Failure { Import-TCWireGuard -Root $multiRoot -EnginePath $EnginePath -WgPath $WgPath -DirectDnsIPv4 '1.1.1.1' -Path $zipPath -Name 'listen collision' -Providers @($bad) } 'WireGuard listen port cannot be a provider port'
    $missing = Copy-TestObject $records[0]; $missing.programPaths = @((Join-Path $missing.directory 'uninstalled.exe'))
    Expect-Failure { ConvertTo-TCPolicyProviders -Providers @($missing) } 'Missing provider executable prevents compilation'
    $customAssistant = [ordered]@{version = 3; rules = @([ordered]@{process_path = @($records[1].programPaths[0])})}
    [IO.File]::WriteAllText((Join-Path $agentDir 'agents-route.json'), (ConvertTo-Json $customAssistant -Depth 10), (New-Object Text.UTF8Encoding($false)))
    try { Expect-Failure { Update-TCNodePolicy -Root $multiRoot -ManifestPath $multiNode.manifestPath } 'Saved custom AI executable cannot also be a provider core' }
    finally { [IO.File]::WriteAllText((Join-Path $agentDir 'agents-route.json'), $savedList, (New-Object Text.UTF8Encoding($false))) }
    Assert-Test ((Get-Hash $multiManifest.CandidatePath) -eq $multiHash) 'Provider validation failures preserve checked source candidates'

    # providers.json is an exact registry schema, not an arbitrary allowlisted file.
    $registryPath = Join-Path $multiRoot 'providers.json'
    $registry = [ordered]@{Version = 1; Providers = $records}
    Write-Fixture $registryPath (ConvertTo-Json $registry -Depth 20)
    $registryHash = Get-Hash $registryPath
    $null = Initialize-TCStore -Root $multiRoot
    Assert-Test ((Get-Hash $registryPath) -eq $registryHash -and @(Get-TCNodes -Root $multiRoot).Count -eq 1) 'Valid ProviderRegistry archive coexists with NodeStore without rewriting it'
    Assert-PrivateAcl -Path $registryPath -Label 'Provider registry ACL' -Protected
    $invalidRegistry = @(
        '{broken', '{"version":2,"providers":[]}', '{"version":1,"providers":{}}', '{"version":1,"providers":null}',
        '{"version":1,"providers":[null]}', '{"version":1,"providers":[],"subscription":"https://example.invalid/token"}',
        (ConvertTo-Json ([ordered]@{version = 1; providers = @($records[0],$records[0])}) -Depth 20)
    )
    foreach ($fixture in $invalidRegistry) {
        Write-Fixture $registryPath $fixture; $badHash = Get-Hash $registryPath
        Expect-Failure { Initialize-TCStore -Root $multiRoot } 'Invalid providers.json is not admitted or reset'
        Assert-Test ((Get-Hash $registryPath) -eq $badHash) 'Corrupt provider archive retained for recovery'
    }
    Write-Fixture $registryPath (ConvertTo-Json ([ordered]@{version = 1; providers = @($missing)}) -Depth 20)
    $null = Initialize-TCStore -Root $multiRoot
    Assert-Test ((Read-Json $registryPath).providers[0].programPaths[0] -eq $missing.programPaths[0]) 'An uninstalled client record stays readable without becoming activatable'
    Write-Fixture $registryPath (ConvertTo-Json $registry -Depth 20)
    $registryHash = Get-Hash $registryPath

    $multiExportPath = Join-Path $work 'multi-settings.json'
    $multiExport = Export-TCSettings -Root $multiRoot -Destination $multiExportPath
    $multiPackage = Read-Json $multiExportPath; $multiText = [IO.File]::ReadAllText($multiExportPath)
    Assert-Test ($multiExport.providerCount -eq 4 -and $multiPackage.providerReferences.Count -eq 4) 'Export includes four provider references from providers.json'
    foreach ($reference in $multiPackage.providerReferences) {
        Assert-Test (@(Compare-Object @('slot','kind','name','status') @($reference.PSObject.Properties.Name)).Count -eq 0 -and $reference.status -ceq 'PendingDetection') 'Provider reference has no local identity, path, port or activation state'
    }
    foreach ($sensitive in @($privateKeys) + @($multiConfig.experimental.clash_api.secret,$records[1].id,$records[1].directory,$records[1].bootstrapDomains[0])) { Assert-Test (-not $multiText.Contains($sensitive)) 'Provider migration excludes client identity, credentials and client configuration'
    }
    Assert-Test ($multiText -notmatch '(?i)subscription|password|private.?key|preshared|settingsDirectory|dailyPort|tradePort|manifest|deployment|[A-Z]:\\\\') 'Migration is an explicit metadata allowlist'
    $rediscoverRoot = Join-Path $work 'new-machine'
    $rediscover = Import-TCSettings -Root $rediscoverRoot -Path $multiExportPath
    Assert-Test ($rediscover.providerCount -eq 4 -and @($rediscover.providerReferences | Where-Object { $_.status -ne 'PendingDetection' }).Count -eq 0 -and $rediscover.nodes[0].status -eq 'PendingAuthorization') 'New machine requires node authorization and provider rediscovery'
    Assert-Test (-not [IO.File]::Exists((Join-Path $rediscoverRoot 'providers.json')) -and @(Get-ChildItem -LiteralPath (Join-Path $rediscoverRoot 'nodes') -Force).Count -eq 0) 'Migration writes neither a usable provider registry nor identity artifacts'
    $rediscoverIndex = Read-Json (Join-Path $rediscoverRoot 'index.json')
    Assert-Test ($rediscoverIndex.providerReferences.Count -eq 4) 'Rediscovery references persist across NodeStore reads'
    $repeatPath = Join-Path $work 'references-again.json'
    $null = Export-TCSettings -Root $rediscoverRoot -Destination $repeatPath
    Assert-Test ((ConvertTo-Json -InputObject (Read-Json $repeatPath).providerReferences -Compress) -ceq (ConvertTo-Json -InputObject $multiPackage.providerReferences -Compress)) 'References survive export-import-export without local provider files'
    $null = Import-TCSettings -Root $multiRoot -Path $multiExportPath
    Assert-Test ((Get-Hash $registryPath) -eq $registryHash) 'Settings import never overwrites existing local provider registration'
    $rediscoverIndexPath = Join-Path $rediscoverRoot 'index.json'; $rediscoverHash = Get-Hash $rediscoverIndexPath
    foreach ($field in @('password','subscription','directory','dailyPort','id','bootstrapDomains')) {
        $badPackage = Copy-TestObject $multiPackage
        $badPackage.providerReferences[0] | Add-Member -NotePropertyName $field -NotePropertyValue 'DO-NOT-IMPORT'
        Write-Fixture $badSettings (ConvertTo-Json $badPackage -Depth 20)
        Expect-Failure { Import-TCSettings -Root $rediscoverRoot -Path $badSettings } 'Provider references reject client data and credentials'
    }
    $badPackage = Copy-TestObject $multiPackage; $badPackage.providerReferences[0].status = 'Ready'
    Write-Fixture $badSettings (ConvertTo-Json $badPackage -Depth 20)
    Expect-Failure { Import-TCSettings -Root $rediscoverRoot -Path $badSettings } 'Migrated provider cannot claim readiness'
    Assert-Test ((Get-Hash $rediscoverIndexPath) -eq $rediscoverHash) 'Malformed provider migration is atomic'
    $nativeAudit = @(& $module { $script:TCTestNativeAudit.ToArray() })
    $realChecks = @($nativeAudit | Where-Object { $_ -eq 'check' }).Count
    Assert-Test ($realChecks -ge 14 -and @($nativeAudit | Where-Object { $_ -notin @('check','pubkey') }).Count -eq 0) ('Native execution stayed offline: ' + $realChecks + ' real checks, ' + $nativeAudit.Count + ' calls, check and pubkey only')
} catch {
    # Test labels and sanitized module messages only; never emit an input fixture.
    $message = $_.Exception.Message
    $diagnostic = & $module { if (Get-Variable -Name TCTestDiagnostic -Scope Script -ErrorAction SilentlyContinue) { $script:TCTestDiagnostic } }
    if ($diagnostic) { $message += ' | Offline native diagnostic: ' + $diagnostic }
    $internal = & $module { if (Get-Variable -Name TCTestInternal -Scope Script -ErrorAction SilentlyContinue) { $script:TCTestInternal } }
    if ($internal) { $message += ' | ' + $internal }
    foreach ($key in $privateKeys) { $message = $message.Replace($key,'[REDACTED]') }
    $failure = $message + ' (test line ' + $_.InvocationInfo.ScriptLineNumber + ')'
} finally {
    & $module { param($Runner) $script:TCNativeRunner = $Runner } $originalRunner
    & $module {
        Set-Item -Path Function:script:Stop-TCOperation -Value $script:TCTestOriginalError
        Set-Item -Path Function:script:Invoke-TCProcess -Value $script:TCTestOriginalProcess
    }
    $privateKeys = @(); $clientKey = $null; $secondClient = $null; $serverKey = $null; $psk = $null
    if ([IO.Directory]::Exists($work)) {
        $resolved = [IO.Path]::GetFullPath($work)
        $parent = [IO.Path]::GetFullPath($fixtureParent).TrimEnd('\') + '\'
        if (-not $resolved.StartsWith($parent, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^NodeStoreTests-[a-f0-9]{32}$') { throw 'Refusing cleanup outside the owned test directory.' }
        & $module { param($Directory) Assert-TCNoReparse $Directory } $resolved
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
if ($failure) { throw ('NodeStore tests failed after ' + $checks.Count + ' checks: ' + $failure) }
[pscustomobject]@{passed = $true; checks = $checks.Count; powerShell = $PSVersionTable.PSVersion.ToString(); realEngineChecks = $true; realEngineCheckCount = $realChecks; offlineOnly = $true; cleaned = (-not [IO.Directory]::Exists($work))}
