#requires -Version 5.1
<#
Self-contained tests; Pester and admin are not required. Run in Windows
PowerShell 5.1. All network/service/firewall calls are module-scoped mocks.
The ONLY real WireGuard commands permitted are genkey and pubkey. Real writes
are limited to an isolated temporary directory and ACLs on those test files.
No downloaded tools, no server connection, no deployment against the host.
#>
[CmdletBinding()]
param([string]$WgPath = 'C:\Program Files\WireGuard\wg.exe')
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'ServerSetup.psm1'
$tokens = $null; $parseErrors = $null
$null = [Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Module failed PowerShell parsing.' }
foreach ($file in @($modulePath, $PSCommandPath)) {
    $bytes = [IO.File]::ReadAllBytes($file)
    if ($bytes.Length -lt 3 -or $bytes[0] -ne 239 -or $bytes[1] -ne 187 -or $bytes[2] -ne 191) { throw 'Both source files must use UTF8 BOM.' }
}
if (-not (Test-Path -LiteralPath $WgPath -PathType Leaf)) { throw 'Tests need an existing wg.exe; no tool will be downloaded.' }
$module = Import-Module $modulePath -Force -PassThru
$testBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$testRoot = Join-Path $testBase ('tc-serversetup-test-' + [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($testRoot)
$script:passed = 0; $script:failed = 0; $script:caseId = 0

# Replace environment and every direct mutation seam before calling any public
# server function. Extra native calls are fail-closed, not passed through.
& $module {
    param($KeyTool)
    $script:TestKeyTool = $KeyTool
    $script:OriginalNative = ${function:Invoke-TCNative}
    $script:Trace = New-Object 'Collections.Generic.List[string]'
    $script:Fake = $null; $script:Runtime = $null; $script:Firewall = @(); $script:Fault = ''
    function script:Get-TCEnvironment { $script:Fake }
    function script:Get-TCService {
        param($Name)
        @($script:Fake.Services | Where-Object { $_.Name -ceq $Name })
    }
    function script:Get-NetAdapter {
        param([switch]$IncludeHidden, $ErrorAction)
        @($script:Fake.Adapters)
    }
    function script:Get-NetIPAddress {
        param($AddressFamily, $ErrorAction)
        @($script:Fake.IPv4Addresses)
    }
    function script:Get-NetIPInterface {
        param($InterfaceIndex, $AddressFamily, $PolicyStore, $ErrorAction)
        $items = $script:Fake.IPInterfaces
        if ($PolicyStore -eq 'PersistentStore') { $items = $script:Fake.PersistentIPInterfaces }
        @($items | Where-Object { $_.InterfaceIndex -eq $InterfaceIndex })
    }
    function script:Set-NetIPInterface {
        param($InterfaceIndex, $AddressFamily, $PolicyStore, $Forwarding, $ErrorAction)
        $script:Trace.Add(('Forward:' + $InterfaceIndex + ':' + $PolicyStore + ':' + $Forwarding))
        if ($AddressFamily -ne 'IPv4' -or $InterfaceIndex -notin @(7,42) -or $PolicyStore -notin @('ActiveStore','PersistentStore')) { throw 'Unexpected forwarding target.' }
        $items = $script:Fake.IPInterfaces
        if ($PolicyStore -eq 'PersistentStore') {
            $items = $script:Fake.PersistentIPInterfaces
            # Windows persistent writes can immediately affect ActiveStore too.
            foreach ($item in @($script:Fake.IPInterfaces | Where-Object { $_.InterfaceIndex -eq $InterfaceIndex })) { $item.Forwarding = $Forwarding }
        }
        foreach ($item in @($items | Where-Object { $_.InterfaceIndex -eq $InterfaceIndex })) { $item.Forwarding = $Forwarding }
    }
    function script:Get-NetNat { param($ErrorAction) @($script:Fake.Nat) }
    function script:New-NetNat {
        param($Name, $InternalIPInterfaceAddressPrefix, $ErrorAction)
        $script:Trace.Add('NewNat:' + $Name)
        if ($Name -notmatch '^tc-[0-9a-f]{12}$') { throw 'Unexpected NAT target.' }
        if ($script:Fault -eq 'NatBefore') { $script:Fault = ''; throw 'Injected pre-mutation NAT failure.' }
        $script:Fake.Nat = @([pscustomobject]@{ Name = $Name; InternalIPInterfaceAddressPrefix = $InternalIPInterfaceAddressPrefix; ExternalIPInterfaceAddressPrefix = ''; Active = $true })
        if ($script:Fault -eq 'NatAfter') { $script:Fault = ''; throw 'Injected post-mutation NAT failure.' }
    }
    function script:Remove-NetNat {
        param($Name, $Confirm, $ErrorAction)
        $script:Trace.Add('RemoveNat:' + $Name)
        if ($Name -notmatch '^tc-[0-9a-f]{12}$') { throw 'Unexpected NAT rollback target.' }
        if ($script:Fault -eq 'RollbackNat') { throw 'Injected NAT rollback failure.' }
        $script:Fake.Nat = @($script:Fake.Nat | Where-Object { $_.Name -cne $Name })
    }
    function script:Get-TCFirewallState { param($Plan, $Store) @($script:Firewall | Where-Object { $_.Name -ceq $Plan.FirewallRuleName }) }
    function script:New-NetFirewallRule {
        param($PolicyStore,$Name,$DisplayName,$Group,$Description,$Direction,$Action,$Enabled,$Protocol,$LocalPort,$RemotePort,$Profile,$InterfaceAlias,$LocalAddress,$RemoteAddress,$ErrorAction)
        $script:Trace.Add('NewFirewall:' + $Name)
        if ($PolicyStore -ne 'PersistentStore' -or $Name -notmatch '^tc-[0-9a-f]{12}-udp$' -or $InterfaceAlias -cne 'Ethernet') { throw 'Unexpected firewall target.' }
        $script:Firewall = @([pscustomobject]@{ Name=$Name; Group=$Group; Description=$Description; Enabled=[string]$Enabled; Direction=$Direction; Action=$Action; Profile=[string]$Profile; Protocol=[string]$Protocol; LocalPort=@([string]$LocalPort); RemotePort=@($RemotePort); InterfaceAlias=@($InterfaceAlias); LocalAddress=@($LocalAddress); RemoteAddress=@($RemoteAddress) })
        $script:Fake.ProductFirewallNames = @($Name)
        if ($script:Fault -in @('FirewallAfter','RollbackNat')) {
            if ($script:Fault -eq 'FirewallAfter') { $script:Fault = '' }
            throw 'Injected firewall failure.'
        }
        if ($script:Fault -eq 'RouteChange') { $script:Fault = ''; $script:Fake.Routes[0].NextHop = '192.0.2.254' }
    }
    function script:Remove-NetFirewallRule {
        param($PolicyStore,$Name,$ErrorAction)
        $script:Trace.Add('RemoveFirewall:' + $Name)
        if ($Name -notmatch '^tc-[0-9a-f]{12}-udp$') { throw 'Unexpected firewall rollback target.' }
        $script:Firewall = @($script:Firewall | Where-Object { $_.Name -cne $Name })
        $script:Fake.ProductFirewallNames = @($script:Fake.ProductFirewallNames | Where-Object { $_ -cne $Name })
    }
    function script:Read-TCMockConfig {
        param($Path)
        $rawBytes = [IO.File]::ReadAllBytes($Path)
        if ($rawBytes.Length -ge 3 -and $rawBytes[0] -eq 239 -and $rawBytes[1] -eq 187 -and $rawBytes[2] -eq 191) { throw 'Native WireGuard config cannot start with UTF8 BOM.' }
        $text = [IO.File]::ReadAllText($Path)
        $key = [regex]::Match($text, '(?m)^PrivateKey = (\S+)\r?$').Groups[1].Value
        $public = & $script:OriginalNative $script:TestKeyTool @('pubkey') $key
        $peers = @()
        foreach ($section in @($text -split '\[Peer\]' | Select-Object -Skip 1)) {
            $peers += [pscustomobject]@{ ClientPublicKey = [regex]::Match($section, '(?m)^PublicKey = (\S+)\r?$').Groups[1].Value; ClientAddress = [regex]::Match($section, '(?m)^AllowedIPs = (\S+)\r?$').Groups[1].Value }
        }
        [pscustomobject]@{ ServerPublicKey = $public; ListenPort = [regex]::Match($text, '(?m)^ListenPort = (\d+)\r?$').Groups[1].Value; Peers = @($peers); DefaultPeerOptions = $true }
    }
    function script:Invoke-TCNative {
        param([string]$Path,[string[]]$Arguments,[string]$InputText)
        if ($Arguments.Count -eq 1 -and $Arguments[0] -in @('genkey','pubkey')) {
            if ($Path -ine $script:TestKeyTool) { throw 'Unexpected key tool.' }
            return (& $script:OriginalNative $Path $Arguments $InputText)
        }
        if ($Arguments[0] -eq '/installtunnelservice') {
            $configPath = $Arguments[1]; $name = [IO.Path]::GetFileNameWithoutExtension($configPath)
            if ($name -notmatch '^tc-[0-9a-f]{12}$') { throw 'Unexpected service target.' }
            $script:Trace.Add('Install:' + $name)
            $script:Runtime = Read-TCMockConfig $configPath
            $text = [IO.File]::ReadAllText($configPath)
            if ($text -notmatch '(?m)^Table = off\r?$' -or $text -match '(?i)PostUp|PreUp|PostDown|PreDown|DNS|Endpoint') { throw 'Unsafe server configuration.' }
            $address = [regex]::Match($text, '(?m)^Address = (\S+)\r?$').Groups[1].Value
            $parts = $address.Split('/')
            $script:Fake.Services += [pscustomobject]@{ Name = ('WireGuardTunnel$' + $name); State = 'Running'; StartMode = 'Auto'; StartName = 'LocalSystem'; PathName = ('"' + $Path + '" /tunnelservice "' + $configPath + '"') }
            $script:Fake.Adapters += [pscustomobject]@{ Name = $name; InterfaceIndex = 42; InterfaceGuid = '{cccccccc-cccc-cccc-cccc-cccccccccccc}'; MacAddress = ''; Status = 'Up'; InterfaceDescription = 'WireGuard Tunnel' }
            $script:Fake.IPv4Addresses += [pscustomobject]@{ InterfaceIndex = 42; InterfaceAlias = $name; IPAddress = $parts[0]; PrefixLength = [int]$parts[1]; AddressState = 'Preferred' }
            $script:Fake.IPInterfaces += [pscustomobject]@{ InterfaceIndex = 42; InterfaceAlias = $name; Forwarding = 'Disabled'; ConnectionState = 'Connected' }
            $script:Fake.PersistentIPInterfaces += [pscustomobject]@{ InterfaceIndex = 42; InterfaceAlias = $name; Forwarding = 'Disabled' }
            $script:Fake.Routes += [pscustomobject]@{ DestinationPrefix = (Get-TCCidr $address).Canonical; NextHop = '0.0.0.0'; InterfaceIndex = 42; RouteMetric = 256 }
            $script:Fake.WireGuard.Interfaces = @($name)
            $script:Fake.UdpListeners += [pscustomobject]@{ LocalAddress = '0.0.0.0'; LocalPort = [int]$script:Runtime.ListenPort; OwningProcess = 12345 }
            return ''
        }
        if ($Arguments[0] -eq '/uninstalltunnelservice') {
            $name = $Arguments[1]
            if ($name -notmatch '^tc-[0-9a-f]{12}$') { throw 'Unexpected uninstall target.' }
            $script:Trace.Add('Uninstall:' + $name)
            $script:Fake.Services = @($script:Fake.Services | Where-Object { $_.Name -cne ('WireGuardTunnel$' + $name) })
            $script:Fake.Adapters = @($script:Fake.Adapters | Where-Object { $_.Name -cne $name })
            $script:Fake.IPv4Addresses = @($script:Fake.IPv4Addresses | Where-Object { $_.InterfaceIndex -ne 42 })
            $script:Fake.IPInterfaces = @($script:Fake.IPInterfaces | Where-Object { $_.InterfaceIndex -ne 42 })
            $script:Fake.PersistentIPInterfaces = @($script:Fake.PersistentIPInterfaces | Where-Object { $_.InterfaceIndex -ne 42 })
            $script:Fake.Routes = @($script:Fake.Routes | Where-Object { $_.InterfaceIndex -ne 42 })
            $script:Fake.WireGuard.Interfaces = @(); $script:Fake.UdpListeners = @(); $script:Runtime = $null
            return ''
        }
        if ($Arguments[0] -eq 'show') {
            if ($Arguments[1] -cne $script:Fake.WireGuard.Interfaces[0]) { throw 'Attempted to read external tunnel as owned.' }
            switch ($Arguments[2]) {
                'public-key' { return $script:Runtime.ServerPublicKey }
                'listen-port' { return [string]$script:Runtime.ListenPort }
                'allowed-ips' { return (@($script:Runtime.Peers | ForEach-Object { $_.ClientPublicKey + "`t" + $_.ClientAddress }) -join "`n") }
                'preshared-keys' { return (@($script:Runtime.Peers | ForEach-Object { $_.ClientPublicKey + "`t(none)" }) -join "`n") }
                'persistent-keepalive' { return (@($script:Runtime.Peers | ForEach-Object { $_.ClientPublicKey + "`t" + $(if ($script:Runtime.DefaultPeerOptions) {'off'} else {'25'}) }) -join "`n") }
                'fwmark' { return 'off' }
                default { throw 'Unmocked wg read operation.' }
            }
        }
        if ($Arguments[0] -eq 'syncconf') {
            if ($Arguments[1] -cne $script:Fake.WireGuard.Interfaces[0]) { throw 'Attempted to sync external tunnel.' }
            $script:Trace.Add('Sync:' + $Arguments[1])
            $script:Runtime = Read-TCMockConfig $Arguments[2]
            if ($script:Fault -eq 'SyncAfter') { $script:Fault = ''; throw 'Injected post-sync failure.' }
            return ''
        }
        throw 'Blocked an unmocked native command. No real deployment is permitted.'
    }
} $WgPath

function Assert-True { param([bool]$Condition,[string]$Message) if (-not $Condition) { throw $Message } }
function Assert-Throws {
    param([scriptblock]$Action,[string]$Code)
    $caught = $false
    try { $null = & $Action } catch { $caught = $true; if ($_.Exception.Message -notlike ('*[TC:' + $Code + ']*').Replace('[','`[').Replace(']','`]')) { throw ('Expected TC:' + $Code + '; got ' + $_.Exception.Message) } }
    if (-not $caught) { throw ('Expected rejection TC:' + $Code) }
}
function Test-Case {
    param([string]$Name,[scriptblock]$Action)
    try { & $Action; $script:passed++; Write-Output ('PASS ' + $Name) }
    catch { $script:failed++; Write-Output ('FAIL ' + $Name + ': ' + $_.Exception.Message); Write-Output $_.ScriptStackTrace }
}
function Write-TestJson { param([string]$Path,$Object) [IO.File]::WriteAllText($Path,($Object | ConvertTo-Json -Depth 30),(New-Object Text.UTF8Encoding($true))) }
function Read-TestJson { param([string]$Path) [IO.File]::ReadAllText($Path) | ConvertFrom-Json }
function Get-TraceCount { & $module { $script:Trace.Count } }
function Reset-Fake {
    $fake = [pscustomobject]@{
        CapturedAtUtc = [DateTime]::UtcNow.ToString('o'); MachineId = 'unit-test-machine'; IsAdministrator = $true
        OS = [pscustomobject]@{ Caption = 'Microsoft Windows Server 2022 Datacenter'; Version = '10.0.20348'; BuildNumber = '20348'; ProductType = 3; Supported = $true }
        WireGuard = [pscustomobject]@{ Installed = $true; WgPath = $WgPath; ServiceExecutable = (Join-Path (Split-Path -Parent $WgPath) 'wireguard.exe'); Interfaces = @(); ConfigurationFiles = @() }
        Adapters = @([pscustomobject]@{ Name = 'Ethernet'; InterfaceIndex = 7; InterfaceGuid = '{aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa}'; MacAddress = '00-11-22-33-44-55'; Status = 'Up'; InterfaceDescription = 'Mock uplink' })
        IPv4Addresses = @([pscustomobject]@{ InterfaceIndex = 7; InterfaceAlias = 'Ethernet'; IPAddress = '192.0.2.10'; PrefixLength = 24; AddressState = 'Preferred' })
        IPInterfaces = @([pscustomobject]@{ InterfaceIndex = 7; InterfaceAlias = 'Ethernet'; Forwarding = 'Disabled'; ConnectionState = 'Connected' })
        PersistentIPInterfaces = @([pscustomobject]@{ InterfaceIndex = 7; InterfaceAlias = 'Ethernet'; Forwarding = 'Disabled' })
        Routes = @([pscustomobject]@{ DestinationPrefix = '0.0.0.0/0'; NextHop = '192.0.2.1'; InterfaceIndex = 7; RouteMetric = 10 }, [pscustomobject]@{ DestinationPrefix = '192.0.2.0/24'; NextHop = '0.0.0.0'; InterfaceIndex = 7; RouteMetric = 256 })
        Nat = @(); Services = @([pscustomobject]@{ Name='MpsSvc'; State='Running'; StartMode='Auto'; PathName=''; StartName='LocalSystem' },[pscustomobject]@{ Name='SharedAccess'; State='Stopped'; StartMode='Manual'; PathName=''; StartName='LocalSystem' },[pscustomobject]@{ Name='RemoteAccess'; State='Stopped'; StartMode='Disabled'; PathName=''; StartName='LocalSystem' })
        UdpListeners = @(); FirewallProfiles = @('Domain','Private','Public' | ForEach-Object { [pscustomobject]@{ Name=$_; Enabled='True'; AllowLocalFirewallRules='NotConfigured' } })
        ProductFirewallNames = @(); ICSConnections = @(); Errors = @()
    }
    & $module { param($Value) $script:Fake=$Value; $script:Trace.Clear(); $script:Runtime=$null; $script:Firewall=@(); $script:Fault='' } $fake
}
function New-TestRoot {
    $script:caseId++
    Join-Path $testRoot ('case-' + $script:caseId)
}
function New-TestPlan {
    param([string]$Root = (New-TestRoot))
    New-TCServerPlan -Root $Root -PublicEndpoint '203.0.113.10:51878' -Name '测试服务器' -InterfaceAlias 'Ethernet' -TunnelSubnet '10.78.0.0/24'
}
function New-AppliedContext {
    Reset-Fake
    $root = New-TestRoot
    $planned = New-TestPlan $root
    $applied = Invoke-TCServerPlan -Root $root -PlanPath $planned.PlanPath -WgPath $WgPath -Confirm:$false
    [pscustomobject]@{ Root=$root; Planned=$planned; Applied=$applied }
}

try {
    Test-Case 'six exported functions / schema contract' {
        $commands = @(Get-Command -Module ServerSetup)
        Assert-True ($commands.Count -eq 6) 'Unexpected public exports.'
        Reset-Fake
        $inspection = Get-TCServerInspection -Root (New-TestRoot)
        Assert-True ($inspection.SchemaVersion -eq 1 -and $inspection.Status -eq 'Inspected' -and $inspection.Friendly -match 'RDP') 'Inspection contract missing.'
        Assert-True ((Get-TraceCount) -eq 0) 'Inspection mutated network.'
    }
    Test-Case 'real local genkey/pubkey; no private output; ACL; no overwrite' {
        Reset-Fake
        $script:request1 = New-TCClientRequest -OutputDirectory (Join-Path $testRoot 'request-one') -WgPath $WgPath
        $script:request2 = New-TCClientRequest -OutputDirectory (Join-Path $testRoot 'request-two') -WgPath $WgPath
        Assert-True ($request1.ClientPublicKey -cne $request2.ClientPublicKey) 'Device keys must be independent.'
        $key = [IO.File]::ReadAllText($request1.KeyPath).Trim()
        $public = & $module { param($Tool,$Key) Invoke-TCNative $Tool @('pubkey') $Key } $WgPath $key
        Assert-True ($public -ceq $request1.ClientPublicKey) 'Client public key did not derive from local private key.'
        Assert-True (-not (($request1 | ConvertTo-Json -Depth 10).Contains($key))) 'Result leaked client private key.'
        Assert-True (-not ([IO.File]::ReadAllText($request1.RequestPath).Contains($key))) 'Public request leaked private key.'
        & $module { param($Dir,$Key) Assert-TCPrivatePath $Dir; Assert-TCPrivatePath $Key } $request1.RequestDirectory $request1.KeyPath
        Assert-Throws { New-TCClientRequest -OutputDirectory $request1.RequestDirectory -WgPath $WgPath } 'RequestExists'
        Assert-True ((Get-TraceCount) -eq 0) 'Pure key request mutated network.'
    }
    foreach ($case in @(
        @{Name='Windows11';Code='UnsupportedOS';Change={ $script:Fake.OS.Supported=$false; $script:Fake.OS.ProductType=1; $script:Fake.OS.BuildNumber='26200'; $script:Fake.OS.Caption='Windows 11' }},
        @{Name='no administrator';Code='AdministratorRequired';Change={ $script:Fake.IsAdministrator=$false }},
        @{Name='missing WireGuard';Code='WireGuardMissing';Change={ $script:Fake.WireGuard.Installed=$false }},
        @{Name='unknown inspection';Code='InspectionIncomplete';Change={ $script:Fake.Errors=@('WinNAT') }},
        @{Name='nonoverlapping existing NAT';Code='NatConflict';Change={ $script:Fake.Nat=@([pscustomobject]@{Name='DockerNAT';InternalIPInterfaceAddressPrefix='172.25.0.0/16';ExternalIPInterfaceAddressPrefix='';Active=$true}) }},
        @{Name='overlapping interface';Code='SubnetConflict';Change={ $script:Fake.IPv4Addresses += [pscustomobject]@{InterfaceIndex=8;InterfaceAlias='Other';IPAddress='10.78.0.50';PrefixLength=24;AddressState='Preferred'} }},
        @{Name='overlapping route';Code='SubnetConflict';Change={ $script:Fake.Routes += [pscustomobject]@{DestinationPrefix='10.0.0.0/8';NextHop='192.0.2.2';InterfaceIndex=7;RouteMetric=30} }},
        @{Name='existing endpoint tunnel service';Code='ExistingNodeReadOnly';Change={ $script:Fake.Services += [pscustomobject]@{Name='WireGuardTunnel$endpoint';State='Running';StartMode='Auto';PathName='external';StartName='LocalSystem'} }},
        @{Name='existing stopped wg0 service';Code='ExistingNodeReadOnly';Change={ $script:Fake.Services += [pscustomobject]@{Name='WireGuardTunnel$wg0';State='Stopped';StartMode='Auto';PathName='external';StartName='LocalSystem'} }},
        @{Name='unmanaged active tunnel';Code='ExistingNodeReadOnly';Change={ $script:Fake.WireGuard.Interfaces=@('wg0') }},
        @{Name='dormant WireGuard config';Code='ExistingNodeReadOnly';Change={ $script:Fake.WireGuard.ConfigurationFiles=@('endpoint.conf.dpapi') }},
        @{Name='UDP occupied';Code='PortConflict';Change={ $script:Fake.UdpListeners=@([pscustomobject]@{LocalAddress='0.0.0.0';LocalPort=51878;OwningProcess=4}) }},
        @{Name='ICS configured';Code='SharingConflict';Change={ $script:Fake.ICSConnections=@('Ethernet') }},
        @{Name='RRAS running';Code='SharingConflict';Change={ @($script:Fake.Services | Where-Object {$_.Name -eq 'RemoteAccess'})[0].State='Running' }},
        @{Name='firewall policy disabled';Code='FirewallUnavailable';Change={ $script:Fake.FirewallProfiles[0].Enabled='False' }},
        @{Name='second management exit';Code='ManagementRoute';Change={ $script:Fake.Routes += [pscustomobject]@{DestinationPrefix='0.0.0.0/0';NextHop='198.51.100.1';InterfaceIndex=8;RouteMetric=5} }}
    )) {
        Test-Case ('plan rejects ' + $case.Name) {
            Reset-Fake
            & $module $case.Change
            $root = New-TestRoot
            Assert-Throws { New-TestPlan $root } $case.Code
            Assert-True ((Get-TraceCount) -eq 0 -and -not (Test-Path -LiteralPath $root)) 'Rejected plan changed state.'
        }
    }
    Test-Case 'existing node inspection is read-only and friendly' {
        Reset-Fake
        & $module { $script:Fake.WireGuard.Interfaces=@('endpoint') }
        $inspection = Get-TCServerInspection -Root (New-TestRoot)
        Assert-True ($inspection.Status -eq 'ExistingNodeReadOnly' -and $inspection.ExistingNodeDetected) 'Existing node status missing.'
        Assert-True ((Get-TraceCount) -eq 0) 'Existing node inspection modified state.'
    }
    Test-Case 'plan-only / canonical subnet / independent service names' {
        Reset-Fake
        $root = New-TestRoot; $p = New-TestPlan $root
        Assert-True ($p.Status -eq 'Planned' -and $p.PlanPath -like '*\plans\*.json' -and $p.Plan.ServiceName -match '^WireGuardTunnel\$tc-' -and $p.Plan.ServerAddress -ceq '10.78.0.1/24') 'Plan fields incorrect.'
        Assert-True ((Get-TraceCount) -eq 0) 'Planning mutated network.'
        Assert-Throws { New-TCServerPlan -Root (New-TestRoot) -PublicEndpoint '203.0.113.10:51878' -Name 'bad' -InterfaceAlias 'Ethernet' -TunnelSubnet '10.78.0.9/24' } 'InvalidSubnet'
        Assert-Throws { New-TCServerPlan -Root (New-TestRoot) -PublicEndpoint '203.0.113.10:0' -Name 'bad' -InterfaceAlias 'Ethernet' -TunnelSubnet '10.78.0.0/24' } 'InvalidEndpoint'
        Assert-Throws { New-TCServerPlan -Root (New-TestRoot) -PublicEndpoint '10.78.0.2:51878' -Name 'bad' -InterfaceAlias 'Ethernet' -TunnelSubnet '10.78.0.0/24' } 'EndpointConflict'
    }
    Test-Case 'apply WhatIf is completely read-only' {
        Reset-Fake
        $root = New-TestRoot; $p = New-TestPlan $root
        $beforeFiles = @(Get-ChildItem -LiteralPath $root -File -Recurse).Count
        $result = Invoke-TCServerPlan -Root $root -PlanPath $p.PlanPath -WgPath $WgPath -WhatIf
        Assert-True ($result.Status -eq 'WhatIf' -and (Get-TraceCount) -eq 0 -and @(Get-ChildItem -LiteralPath $root -File -Recurse).Count -eq $beforeFiles) 'WhatIf changed state.'
    }
    foreach ($case in @(
        @{Name='Windows11';Code='UnsupportedOS';Change={ $script:Fake.OS.Supported=$false; $script:Fake.OS.ProductType=1 }},
        @{Name='lost administrator';Code='AdministratorRequired';Change={ $script:Fake.IsAdministrator=$false }},
        @{Name='changed default route';Code='StalePlan';Change={ $script:Fake.Routes[0].NextHop='192.0.2.254' }},
        @{Name='replaced uplink';Code='StalePlan';Change={ $script:Fake.Adapters[0].InterfaceGuid='{bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb}' }},
        @{Name='new external endpoint';Code='ExistingNodeReadOnly';Change={ $script:Fake.WireGuard.Interfaces=@('endpoint') }},
        @{Name='new NAT';Code='NatConflict';Change={ $script:Fake.Nat=@([pscustomobject]@{Name='Other';InternalIPInterfaceAddressPrefix='172.25.0.0/16';ExternalIPInterfaceAddressPrefix='';Active=$true}) }}
    )) {
        Test-Case ('fresh apply rejects ' + $case.Name) {
            Reset-Fake
            $root = New-TestRoot; $p = New-TestPlan $root
            & $module $case.Change
            Assert-Throws { Invoke-TCServerPlan -Root $root -PlanPath $p.PlanPath -WgPath $WgPath -Confirm:$false } $case.Code
            Assert-True ((Get-TraceCount) -eq 0) 'Fresh preflight rejection mutated network.'
        }
    }
    Test-Case 'reject plan targeting endpoint / expired plan / foreign root' {
        Reset-Fake
        $root = New-TestRoot; $p = New-TestPlan $root
        $changed = Read-TestJson $p.PlanPath; $changed.ServiceName='WireGuardTunnel$endpoint'; Write-TestJson $p.PlanPath $changed
        Assert-Throws { Invoke-TCServerPlan -Root $root -PlanPath $p.PlanPath -WgPath $WgPath -Confirm:$false } 'InvalidPlan'
        $changed.ServiceName=$p.Plan.ServiceName; $changed.ExpiresAtUtc=[DateTime]::UtcNow.AddMinutes(-1).ToString('o'); Write-TestJson $p.PlanPath $changed
        Assert-Throws { Invoke-TCServerPlan -Root $root -PlanPath $p.PlanPath -WgPath $WgPath -Confirm:$false } 'PlanExpired'
        $owner = Read-TestJson (Join-Path $root 'owner.json'); $owner.MachineId='another-machine'; Write-TestJson (Join-Path $root 'owner.json') $owner
        Assert-Throws { Invoke-TCServerPlan -Root $root -PlanPath $p.PlanPath -WgPath $WgPath -Confirm:$false } 'OwnershipMismatch'
        Assert-True ((Get-TraceCount) -eq 0) 'Invalid plan mutated network.'
    }
    Test-Case 'mock deploy with zero peers / idempotency / private backup / management preserved' {
        $script:context = New-AppliedContext
        $result = $context.Applied; $manifest = Read-TestJson $result.ManifestPath
        Assert-True ($result.Status -eq 'Applied' -and @($manifest.Peers).Count -eq 0) 'Empty server not applied.'
        Assert-True ($result.Validation.LocalConfiguration -eq 'Verified' -and $result.Validation.Handshake -eq 'NotTested' -and $result.Validation.CloudFirewall -eq 'NotVerified') 'Validation overclaims connectivity.'
        $trace = Get-TraceCount
        $again = Invoke-TCServerPlan -Root $context.Root -PlanPath $context.Planned.PlanPath -WgPath $WgPath -Confirm:$false
        Assert-True ($again.Status -eq 'AlreadyApplied' -and (Get-TraceCount) -eq $trace) 'Repeated apply mutated state.'
        Assert-True ((Read-TestJson $result.RollbackPath).Status -eq 'Committed') 'Missing transaction journal.'
        $defaults = & $module { Get-TCDefaultRoutes $script:Fake }
        Assert-True ($defaults.NextHop -eq '192.0.2.1') 'Management route modified.'
        & $module { param($Path) Assert-TCPrivatePath $Path } $manifest.ConfigPath
        Assert-Throws { New-TestPlan $context.Root } 'ExistingNodeReadOnly'
    }
    Test-Case 'authorize device / repeat / preserve existing peer / response has no secrets' {
        $script:context = New-AppliedContext
        $script:authorized = Add-TCServerDevice -Root $context.Root -RequestPath $request1.RequestPath -ClientAddress '10.78.0.2' -Confirm:$false
        Assert-True ($authorized.Status -eq 'DeviceAuthorized' -and $authorized.ResponsePath -like '*\devices\*\client-response.json') 'ResponsePath contract missing.'
        $manifest = Read-TestJson $context.Applied.ManifestPath
        $firstPeer = @($manifest.Peers)[0] | ConvertTo-Json -Compress
        $trace = Get-TraceCount
        $again = Add-TCServerDevice -Root $context.Root -RequestPath $request1.RequestPath -ClientAddress '10.78.0.2/32' -Confirm:$false
        Assert-True ($again.Status -eq 'AlreadyAuthorized' -and (Get-TraceCount) -eq $trace) 'Repeated authorization changed peer.'
        $null = Add-TCServerDevice -Root $context.Root -RequestPath $request2.RequestPath -ClientAddress '10.78.0.3' -Confirm:$false
        $manifest = Read-TestJson $context.Applied.ManifestPath
        Assert-True (@($manifest.Peers).Count -eq 2 -and ((@($manifest.Peers)[0] | ConvertTo-Json -Compress) -ceq $firstPeer)) 'Existing peer changed.'
        $response = [IO.File]::ReadAllText($authorized.ResponsePath)
        $serverPrivate = [regex]::Match([IO.File]::ReadAllText($manifest.ConfigPath),'(?m)^PrivateKey = (\S+)\r?$').Groups[1].Value
        Assert-True (-not $response.Contains($serverPrivate) -and $response -notmatch '(?i)PrivateKey|PresharedKey') 'Response leaked private server material.'
        $backup = Join-Path (Split-Path -Parent $authorized.RollbackPath) 'server.before.conf'
        & $module { param($Path) Assert-TCPrivatePath $Path } $backup
    }
    Test-Case 'client config completion / ACL / request binding / no overwrite' {
        $config = Join-Path $testRoot 'client-one.conf'
        $trace = Get-TraceCount
        $done = Complete-TCClientConfig -RequestDirectory $request1.RequestDirectory -ResponsePath $authorized.ResponsePath -Destination $config
        Assert-True ($done.Status -eq 'ConfigCompleted' -and $done.ConfigPath -eq $config) 'Client config result incorrect.'
        $content = [IO.File]::ReadAllText($config)
        $rawBytes = [IO.File]::ReadAllBytes($config)
        Assert-True ($rawBytes[0] -eq 91) 'Client WireGuard config must start with [, not a BOM.'
        $key = [IO.File]::ReadAllText($request1.KeyPath).Trim()
        Assert-True ($content.Contains('PrivateKey = ' + $key) -and $content.Contains('Endpoint = 203.0.113.10:51878') -and $content.Contains('Address = 10.78.0.2/32')) 'Client config contents incorrect.'
        Assert-True (-not (($done | ConvertTo-Json).Contains($key))) 'Completion result leaked private key.'
        & $module { param($Path) Assert-TCPrivatePath $Path } $config
        $again = Complete-TCClientConfig -RequestDirectory $request1.RequestDirectory -ResponsePath $authorized.ResponsePath -Destination $config
        Assert-True ($again.Status -eq 'AlreadyCompleted') 'Client completion not idempotent.'
        Assert-Throws { Complete-TCClientConfig -RequestDirectory $request2.RequestDirectory -ResponsePath $authorized.ResponsePath -Destination (Join-Path $testRoot 'wrong.conf') } 'ResponseMismatch'
        [IO.File]::WriteAllText($config,'user-owned changed content',(New-Object Text.UTF8Encoding($true)))
        Assert-Throws { Complete-TCClientConfig -RequestDirectory $request1.RequestDirectory -ResponsePath $authorized.ResponsePath -Destination $config } 'DestinationExists'
        Assert-True ((Get-TraceCount) -eq $trace) 'Client config completion touched network.'
    }
    Test-Case 'device conflicts / invalid addresses / no existing-peer repair' {
        $trace = Get-TraceCount
        Assert-Throws { Add-TCServerDevice -Root $context.Root -RequestPath $request1.RequestPath -ClientAddress '10.78.0.4' -Confirm:$false } 'DeviceConflict'
        Assert-Throws { Add-TCServerDevice -Root $context.Root -RequestPath $request2.RequestPath -ClientAddress '10.78.0.2' -Confirm:$false } 'DeviceConflict'
        foreach ($address in @('10.78.0.0','10.78.0.1','10.78.0.255','10.79.0.2','10.78.0.9/24')) {
            Assert-Throws { Add-TCServerDevice -Root $context.Root -RequestPath $request1.RequestPath -ClientAddress $address -Confirm:$false } 'InvalidClientAddress'
        }
        & $module { $script:Runtime.Peers[0].ClientAddress='10.78.0.99/32' }
        Assert-Throws { Add-TCServerDevice -Root $context.Root -RequestPath $request1.RequestPath -ClientAddress '10.78.0.2' -Confirm:$false } 'PeerDrift'
        Assert-True ((Get-TraceCount) -eq $trace) 'Conflict or drift modified peers.'
    }
    Test-Case 'service ownership mismatch refuses peer authorization' {
        $ctx = New-AppliedContext
        & $module { @($script:Fake.Services | Where-Object { $_.Name -like 'WireGuardTunnel$*' })[0].PathName='"C:\Program Files\WireGuard\wireguard.exe" /tunnelservice "C:\foreign\wg0.conf"' }
        $trace = Get-TraceCount
        Assert-Throws { Add-TCServerDevice -Root $ctx.Root -RequestPath $request1.RequestPath -ClientAddress '10.78.0.2' -Confirm:$false } 'OwnershipMismatch'
        Assert-True ((Get-TraceCount) -eq $trace) 'Foreign service was touched.'
    }
    Test-Case 'out-of-band existing peer options are never reset' {
        $ctx = New-AppliedContext
        $null = Add-TCServerDevice -Root $ctx.Root -RequestPath $request1.RequestPath -ClientAddress '10.78.0.2' -Confirm:$false
        & $module { $script:Runtime.DefaultPeerOptions=$false }
        $trace = Get-TraceCount
        Assert-Throws { Add-TCServerDevice -Root $ctx.Root -RequestPath $request2.RequestPath -ClientAddress '10.78.0.3' -Confirm:$false } 'PeerDrift'
        Assert-True ((Get-TraceCount) -eq $trace) 'Out-of-band peer options were overwritten.'
    }
    Test-Case 'client private state tampering refused' {
        $local = New-TCClientRequest -OutputDirectory (Join-Path $testRoot 'request-tamper') -WgPath $WgPath
        [IO.File]::WriteAllText($local.KeyPath,[IO.File]::ReadAllText($request1.KeyPath),(New-Object Text.UTF8Encoding($true)))
        Assert-Throws { Complete-TCClientConfig -RequestDirectory $local.RequestDirectory -ResponsePath $authorized.ResponsePath -Destination (Join-Path $testRoot 'tamper.conf') } 'RequestMismatch'
    }
    foreach ($fault in @('NatBefore','NatAfter','FirewallAfter')) {
        Test-Case ('deployment rollback ' + $fault) {
            Reset-Fake
            # Capture distinct active/persistent states to exercise cascade-safe rollback.
            & $module { $script:Fake.IPInterfaces[0].Forwarding='Enabled' }
            $root=New-TestRoot; $p=New-TestPlan $root
            & $module { param($Fault) $script:Fault=$Fault } $fault
            Assert-Throws { Invoke-TCServerPlan -Root $root -PlanPath $p.PlanPath -WgPath $WgPath -Confirm:$false } 'FailedRolledBack'
            $state = & $module { [pscustomobject]@{ NatCount=@($script:Fake.Nat).Count; ServiceCount=@($script:Fake.Services | Where-Object {$_.Name -like 'WireGuardTunnel$*'}).Count; FirewallCount=@($script:Firewall).Count; Active=$script:Fake.IPInterfaces[0].Forwarding; Persistent=$script:Fake.PersistentIPInterfaces[0].Forwarding; DefaultRoute=$script:Fake.Routes[0].NextHop } }
            Assert-True ($state.NatCount -eq 0 -and $state.ServiceCount -eq 0 -and $state.FirewallCount -eq 0 -and $state.Active -eq 'Enabled' -and $state.Persistent -eq 'Disabled' -and $state.DefaultRoute -eq '192.0.2.1') 'Rollback did not restore exact state.'
            $manifest = Read-TestJson (Join-Path $root 'manifest.json')
            Assert-True ($manifest.Status -eq 'FailedRolledBack') 'Failed deployment status missing.'
        }
    }
    Test-Case 'rollback failure is explicit NeedsRecovery' {
        Reset-Fake
        $root=New-TestRoot; $p=New-TestPlan $root
        & $module { $script:Fault='RollbackNat' }
        Assert-Throws { Invoke-TCServerPlan -Root $root -PlanPath $p.PlanPath -WgPath $WgPath -Confirm:$false } 'NeedsRecovery'
        $manifest=Read-TestJson (Join-Path $root 'manifest.json')
        Assert-True ($manifest.Status -eq 'NeedsRecovery') 'Rollback failure hidden.'
        $trace=Get-TraceCount
        Assert-Throws { Invoke-TCServerPlan -Root $root -PlanPath $p.PlanPath -WgPath $WgPath -Confirm:$false } 'NeedsRecovery'
        Assert-True ((Get-TraceCount) -eq $trace) 'NeedsRecovery replay modified network.'
    }
    Test-Case 'external default-route change is never repaired by this module' {
        Reset-Fake
        $root=New-TestRoot; $p=New-TestPlan $root
        & $module { $script:Fault='RouteChange' }
        Assert-Throws { Invoke-TCServerPlan -Root $root -PlanPath $p.PlanPath -WgPath $WgPath -Confirm:$false } 'NeedsRecovery'
        Assert-True ((& $module { $script:Fake.Routes[0].NextHop }) -eq '192.0.2.254') 'External route was overwritten.'
    }
    Test-Case 'post-sync device failure restores prior config and existing peers' {
        $ctx=New-AppliedContext
        $null=Add-TCServerDevice -Root $ctx.Root -RequestPath $request1.RequestPath -ClientAddress '10.78.0.2' -Confirm:$false
        $before=Read-TestJson $ctx.Applied.ManifestPath
        $hash=Get-FileHash -LiteralPath $before.ConfigPath -Algorithm SHA256
        & $module { $script:Fault='SyncAfter' }
        Assert-Throws { Add-TCServerDevice -Root $ctx.Root -RequestPath $request2.RequestPath -ClientAddress '10.78.0.3' -Confirm:$false } 'FailedRolledBack'
        $after=Read-TestJson $ctx.Applied.ManifestPath
        Assert-True ($after.Status -eq 'Applied' -and @($after.Peers).Count -eq 1 -and $after.ConfigRevision -eq $before.ConfigRevision -and (Get-FileHash -LiteralPath $before.ConfigPath -Algorithm SHA256).Hash -eq $hash.Hash) 'Device rollback changed existing config.'
        $runtimeCount=& $module { @($script:Runtime.Peers).Count }
        Assert-True ($runtimeCount -eq 1) 'Runtime peers were not rolled back.'
    }
    Test-Case 'source contains no route/gateway/DNS mutations or arbitrary hooks' {
        $ast = [Management.Automation.Language.Parser]::ParseFile($modulePath,[ref]$tokens,[ref]$parseErrors)
        $forbidden = @($ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -match '^(New|Set|Remove)-(NetRoute|NetIPAddress|DnsClientServerAddress)$|^Invoke-Expression$|^Invoke-Command$|^Start-Process$' },$true))
        Assert-True ($forbidden.Count -eq 0) 'Forbidden network management command found.'
    }
} finally {
    Remove-Module $module -Force -ErrorAction SilentlyContinue
    # Only this suite's exact generated directory may be recursively deleted.
    $resolved = [IO.Path]::GetFullPath($testRoot).TrimEnd('\')
    if ([IO.Path]::GetDirectoryName($resolved) -ine $testBase -or [IO.Path]::GetFileName($resolved) -notmatch '^tc-serversetup-test-[0-9a-f]{32}$') { throw 'Unsafe test cleanup target refused.' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop }
}
Write-Output ('ServerSetup: {0} passed; {1} failed. Real network/service/firewall mutations: 0. Live Server 2022 deployment: NOT TESTED.' -f $script:passed,$script:failed)
if ($script:failed) { throw ('ServerSetup tests failed: ' + $script:failed) }
