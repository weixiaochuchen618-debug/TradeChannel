#requires -Version 5.1
<#
TradeChannel Windows Server backend, schema version 1.
Public commands return SchemaVersion, Status and Friendly. Rejections throw a
sanitized [TC:Code] error. No module-import side effects and no remote execution.
Root defaults to CommonApplicationData\TradeChannel\Server. One dedicated node
per Root; external tunnels/NAT/ICS/RRAS are never adopted. A plan writes only
product state; Invoke-TCServerPlan is the explicit deployment boundary.

Integration: New-TCServerPlan -> .Plan / .PlanPath; Invoke -> .ManifestPath /
.Node / .Validation; New-TCClientRequest -> .RequestPath / .KeyPath;
Add-TCServerDevice -> .ResponsePath; Complete-TCClientConfig -> .ConfigPath.
Status Applied means local configuration verified, NOT Internet/handshake/cloud
firewall/reboot verification. Failed transactions remain in transactions/ with
restricted backups and rollback.json. NeedsRecovery is deliberately fail-closed.
#>
Set-StrictMode -Version 2.0

function Stop-TC {
    param([string]$Code, [string]$Message)
    throw [InvalidOperationException]::new(('[TC:{0}] {1}' -f $Code, $Message))
}

function Get-TCProperty {
    param($Object, [string]$Name, $Default = $null)
    if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}

function Get-TCFullPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -match '[\r\n\x00"*?]' -or $Path.StartsWith('\\')) {
        Stop-TC InvalidPath '必须使用本机文件系统路径，不接受 UNC、通配符或控制字符。'
    }
    try { $full = [IO.Path]::GetFullPath($Path).TrimEnd('\') } catch { Stop-TC InvalidPath '路径无效。' }
    if ($full -notmatch '^[A-Za-z]:\\' -or $full.Substring(2).Contains(':')) { Stop-TC InvalidPath '必须使用本机绝对路径。' }
    $cursor = $full
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { Stop-TC ReparsePoint '产品状态路径不能经过链接或重解析点。' }
        }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
    return $full
}

function Resolve-TCRoot {
    param([string]$Root)
    if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'TradeChannel\Server' }
    $full = Get-TCFullPath $Root
    $reserved = @([Environment]::GetFolderPath('CommonApplicationData'), [Environment]::GetFolderPath('UserProfile'),
        [Environment]::GetFolderPath('ProgramFiles'), [Environment]::GetFolderPath('Windows'), (Get-Location).Path)
    if ($full.Length -le 3 -or $reserved -contains $full) { Stop-TC InvalidRoot 'Root 必须是产品专用子目录。' }
    return $full
}

function Get-TCAllowedSids {
    @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'S-1-5-18', 'S-1-5-32-544') | Select-Object -Unique
}

function Protect-TCPath {
    param([string]$Path, [switch]$Directory)
    $null = Get-TCFullPath $Path
    if ($Directory) { $acl = New-Object Security.AccessControl.DirectorySecurity }
    else { $acl = New-Object Security.AccessControl.FileSecurity }
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @(Get-TCAllowedSids)) {
        $identity = New-Object Security.Principal.SecurityIdentifier($sid)
        if ($Directory) {
            $rule = New-Object Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        } else { $rule = New-Object Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'Allow') }
        $null = $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
}

function Assert-TCPrivatePath {
    param([string]$Path)
    $null = Get-TCFullPath $Path
    if (-not (Test-Path -LiteralPath $Path)) { Stop-TC MissingState '缺少本产品受限状态文件。' }
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    $allowed = @(Get-TCAllowedSids)
    if (-not $acl.AreAccessRulesProtected) { Stop-TC UnsafeAcl '私有状态 ACL 必须禁用继承。' }
    foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference.Value -notin $allowed) {
            Stop-TC UnsafeAcl '私有状态授予了额外账户访问权限。'
        }
    }
}

function New-TCPrivateDirectory {
    param([string]$Path)
    $Path = Get-TCFullPath $Path
    if (-not (Test-Path -LiteralPath $Path)) { $null = [IO.Directory]::CreateDirectory($Path) }
    if (-not (Get-Item -LiteralPath $Path -Force).PSIsContainer) { Stop-TC InvalidPath '需要目录路径。' }
    Protect-TCPath $Path -Directory
}

function Write-TCText {
    param([string]$Path, [string]$Text, [switch]$NewOnly)
    $Path = Get-TCFullPath $Path
    $parent = [IO.Path]::GetDirectoryName($Path)
    Assert-TCPrivatePath $parent
    if ($NewOnly -and (Test-Path -LiteralPath $Path)) { Stop-TC AlreadyExists '目标文件已存在；不会覆盖。' }
    $temp = Join-Path $parent ('.tc-write-' + [guid]::NewGuid().ToString('N'))
    try {
        # PowerShell sources and JSON use UTF8 BOM. WireGuard's native config
        # parser does not accept a BOM before [Interface]. Keys/configs omit it.
        $withBom = [IO.Path]::GetExtension($Path) -notin @('.conf','.key')
        [IO.File]::WriteAllText($temp, $Text, (New-Object Text.UTF8Encoding($withBom)))
        Protect-TCPath $temp
        if (Test-Path -LiteralPath $Path) {
            Assert-TCPrivatePath $Path
            # PowerShell 5.1 coerces $null to an empty string for this overload.
            [IO.File]::Replace($temp, $Path, [System.Management.Automation.Language.NullString]::Value)
        } else { [IO.File]::Move($temp, $Path) }
        Protect-TCPath $Path
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction Stop }
    }
}

function Write-TCJson {
    param([string]$Path, $Object, [switch]$NewOnly)
    Write-TCText -Path $Path -Text ($Object | ConvertTo-Json -Depth 30) -NewOnly:$NewOnly
}

function Read-TCJson {
    param([string]$Path, [switch]$Private)
    $Path = Get-TCFullPath $Path
    if ($Private) { Assert-TCPrivatePath $Path }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Stop-TC MissingFile '找不到所需 JSON 文件。' }
    if ((Get-Item -LiteralPath $Path).Length -gt 2MB) { Stop-TC InvalidSchema 'JSON 文件过大。' }
    try { return ([IO.File]::ReadAllText($Path) | ConvertFrom-Json -ErrorAction Stop) }
    catch { Stop-TC InvalidSchema 'JSON 文件无法解析。' }
}

function Get-TCHash {
    param([string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-TCFileHash {
    param([string]$Path)
    Get-TCHash ([IO.File]::ReadAllText((Get-TCFullPath $Path)))
}

function Assert-TCGuid {
    param([string]$Value)
    if ($Value -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') { Stop-TC InvalidSchema '标识必须是规范 GUID。' }
}

function Assert-TCKey {
    param([string]$Key)
    if ($Key -cnotmatch '^[A-Za-z0-9+/]{43}=$') { Stop-TC InvalidKey 'WireGuard 密钥格式无效。' }
    try { $bytes = [Convert]::FromBase64String($Key) } catch { Stop-TC InvalidKey 'WireGuard 密钥格式无效。' }
    if ($bytes.Length -ne 32 -or [Convert]::ToBase64String($bytes) -cne $Key -or -not @($bytes | Where-Object { $_ -ne 0 }).Count) {
        Stop-TC InvalidKey 'WireGuard 密钥无效。'
    }
}

function ConvertTo-TCIPv4Number {
    param([string]$Address)
    if ($Address -notmatch '^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})$') { Stop-TC InvalidAddress 'IPv4 地址格式无效。' }
    [uint64]$value = 0
    foreach ($octet in $Address.Split('.')) {
        if ([int]$octet -gt 255) { Stop-TC InvalidAddress 'IPv4 地址格式无效。' }
        $value = $value * 256 + [int]$octet
    }
    return $value
}

function ConvertFrom-TCIPv4Number {
    param([uint64]$Number)
    return ('{0}.{1}.{2}.{3}' -f (($Number -shr 24) -band 255), (($Number -shr 16) -band 255), (($Number -shr 8) -band 255), ($Number -band 255))
}

function Get-TCCidr {
    param([string]$Cidr, [switch]$Dedicated)
    if ($Cidr -notmatch '^([^/]+)/(0|[1-9][0-9]?)$') { Stop-TC InvalidSubnet '必须使用 IPv4 CIDR。' }
    [uint64]$ip = ConvertTo-TCIPv4Number $Matches[1]
    $length = [int]$Matches[2]
    if ($length -gt 32) { Stop-TC InvalidSubnet 'IPv4 前缀长度无效。' }
    [uint64]$size = [math]::Pow(2, (32 - $length))
    [uint64]$start = [uint64]([math]::Floor($ip / [double]$size) * $size)
    [uint64]$end = $start + $size - 1
    if ($Dedicated) {
        $private = ($start -ge 167772160 -and $end -le 184549375) -or ($start -ge 2886729728 -and $end -le 2887778303) -or ($start -ge 3232235520 -and $end -le 3232301055)
        if ($ip -ne $start -or $length -lt 16 -or $length -gt 30 -or -not $private) {
            Stop-TC InvalidSubnet '专用隧道网段必须是规范 RFC1918 网络地址，前缀 /16 至 /30。'
        }
    }
    [pscustomobject]@{ Start = $start; End = $end; PrefixLength = $length; Canonical = ((ConvertFrom-TCIPv4Number $start) + '/' + $length) }
}

function Test-TCOverlap {
    param($First, $Second)
    return ($First.Start -le $Second.End -and $Second.Start -le $First.End)
}

function Get-TCEndpoint {
    param([string]$Endpoint)
    if ($Endpoint -notmatch '^([^:]+):([1-9][0-9]{0,4})$') { Stop-TC InvalidEndpoint 'PublicEndpoint 必须是 IPv4:port。' }
    $address = $Matches[1]; $port = [int]$Matches[2]
    $value = ConvertTo-TCIPv4Number $address
    if ($port -gt 65535 -or $value -lt 16777216 -or $value -ge 3758096384 -or ($value -ge 2130706432 -and $value -le 2147483647) -or ($value -ge 2851995648 -and $value -le 2852061183)) {
        Stop-TC InvalidEndpoint '端点必须是有效单播 IPv4 地址及 1-65535 端口。'
    }
    [pscustomobject]@{ Address = $address; Port = $port; Value = ($address + ':' + $port) }
}

function Resolve-TCWgPath {
    param([string]$WgPath)
    if ([string]::IsNullOrWhiteSpace($WgPath)) { $WgPath = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'WireGuard\wg.exe' }
    $full = Get-TCFullPath $WgPath
    if ([IO.Path]::GetFileName($full) -ine 'wg.exe' -or -not (Test-Path -LiteralPath $full -PathType Leaf)) { Stop-TC WireGuardMissing '找不到本机 wg.exe；本模块不会下载或安装工具。' }
    return $full
}

function Invoke-TCNative {
    param([string]$Path, [string[]]$Arguments, [string]$InputText)
    $Path = Get-TCFullPath $Path
    if ($InputText) {
        if ($Arguments.Count -ne 1 -or $Arguments[0] -cne 'pubkey') { Stop-TC InvalidArgument '只有公钥推导操作接受标准输入。' }
        Assert-TCKey $InputText
    }
    $encoded = foreach ($argument in $Arguments) {
        if ($argument -match '[\r\n\x00]') { Stop-TC InvalidArgument '工具参数包含控制字符。' }
        '"' + ([regex]::Replace([regex]::Replace($argument, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1')) + '"'
    }
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $Path; $start.Arguments = $encoded -join ' '
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true; $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    try {
        # .NET Framework creates its stdin writer with Console.InputEncoding and
        # immediately emits that encoding's BOM. PS5.1 lacks the per-process
        # StandardInputEncoding property. Temporarily select UTF8 without a BOM
        # while creating the writer; restore it before any input or wait.
        if ($InputText -and -not $start.PSObject.Properties['StandardInputEncoding']) {
            [Threading.Monitor]::Enter([Console])
            $originalEncoding = [Console]::InputEncoding
            try {
                [Console]::InputEncoding = New-Object Text.UTF8Encoding($false)
                $started = $process.Start()
            } finally {
                try { [Console]::InputEncoding = $originalEncoding }
                finally { [Threading.Monitor]::Exit([Console]) }
            }
        } else {
            if ($InputText) { $start.StandardInputEncoding = New-Object Text.UTF8Encoding($false) }
            $started = $process.Start()
        }
        if (-not $started) { Stop-TC ToolFailure '无法启动 WireGuard 工具。' }
        $output = $process.StandardOutput.ReadToEndAsync()
        $errorOutput = $process.StandardError.ReadToEndAsync()
        if ($InputText) { $process.StandardInput.Write($InputText) }
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(30000)) { $process.Kill(); Stop-TC ToolTimeout 'WireGuard 工具运行超时。' }
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { Stop-TC ToolFailure ('WireGuard 操作失败，退出码 {0}；工具输出不回显以保护密钥。' -f $process.ExitCode) }
        return $output.Result.Trim()
    } finally { $process.Dispose() }
}

function New-TCKeyPair {
    param([string]$WgPath)
    $private = Invoke-TCNative $WgPath @('genkey')
    Assert-TCKey $private
    $public = Invoke-TCNative $WgPath @('pubkey') $private
    Assert-TCKey $public
    [pscustomobject]@{ Private = $private; Public = $public }
}

function Get-TCEnvironment {
    # This function and Invoke-TCNative are isolated test seams. Every operation
    # below is read-only. Errors remain explicit, never silently treated as empty.
    $errors = New-Object 'Collections.Generic.List[string]'
    $os = $null; $machineId = ''; $adapters = @(); $ip4 = @(); $ipInterfaces = @(); $persistent = @()
    $routes = @(); $nat = @(); $services = @(); $udp = @(); $profiles = @(); $fw = @(); $wgInterfaces = @(); $configs = @()
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    try { $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop } catch { $errors.Add('OperatingSystem') }
    try { $machineId = [string](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid -ErrorAction Stop).MachineGuid } catch { $errors.Add('MachineIdentity') }
    try { $adapters = @(Get-NetAdapter -IncludeHidden -ErrorAction Stop | Select-Object Name, InterfaceIndex, InterfaceGuid, MacAddress, Status, InterfaceDescription) } catch { $errors.Add('Adapters') }
    try { $ip4 = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Select-Object InterfaceIndex, InterfaceAlias, IPAddress, PrefixLength, AddressState) } catch { $errors.Add('IPv4Addresses') }
    try { $ipInterfaces = @(Get-NetIPInterface -AddressFamily IPv4 -PolicyStore ActiveStore -ErrorAction Stop | Select-Object InterfaceIndex, InterfaceAlias, Forwarding, ConnectionState) } catch { $errors.Add('ForwardingActive') }
    try { $persistent = @(Get-NetIPInterface -AddressFamily IPv4 -PolicyStore PersistentStore -ErrorAction Stop | Select-Object InterfaceIndex, InterfaceAlias, Forwarding) } catch { $errors.Add('ForwardingPersistent') }
    try { $routes = @(Get-NetRoute -PolicyStore ActiveStore -ErrorAction Stop | Select-Object DestinationPrefix, NextHop, InterfaceIndex, RouteMetric) } catch { $errors.Add('Routes') }
    try { $nat = @(Get-NetNat -ErrorAction Stop | Select-Object Name, InternalIPInterfaceAddressPrefix, ExternalIPInterfaceAddressPrefix, Active) } catch { $errors.Add('WinNAT') }
    try { $services = @(Get-CimInstance -ClassName Win32_Service -ErrorAction Stop | Where-Object { $_.Name -like 'WireGuard*' -or $_.Name -in @('SharedAccess', 'RemoteAccess', 'MpsSvc', 'TermService') } | Select-Object Name, State, StartMode, PathName, StartName) } catch { $errors.Add('Services') }
    try { $udp = @(Get-NetUDPEndpoint -ErrorAction Stop | Select-Object LocalAddress, LocalPort, OwningProcess) } catch { $errors.Add('UdpListeners') }
    try { $profiles = @(Get-NetFirewallProfile -PolicyStore ActiveStore -ErrorAction Stop | Select-Object Name, Enabled, AllowLocalFirewallRules) } catch { $errors.Add('FirewallProfiles') }
    try { $fw = @(Get-NetFirewallRule -PolicyStore ActiveStore -ErrorAction Stop | Where-Object { $_.Name -like 'tc-*' } | Select-Object Name) } catch { $errors.Add('FirewallRules') }
    $wg = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'WireGuard\wg.exe'
    $serviceExe = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'WireGuard\wireguard.exe'
    $installed = (Test-Path -LiteralPath $wg -PathType Leaf) -and (Test-Path -LiteralPath $serviceExe -PathType Leaf)
    if (Test-Path -LiteralPath $wg -PathType Leaf) {
        try { $text = Invoke-TCNative $wg @('show', 'interfaces'); $wgInterfaces = @($text -split '\s+' | Where-Object { $_ }) } catch { $errors.Add('WireGuardInterfaces') }
    }
    $configStore = Join-Path ([IO.Path]::GetDirectoryName($wg)) 'Data\Configurations'
    try {
        if (Test-Path -LiteralPath $configStore -ErrorAction Stop) {
            $configs = @(Get-ChildItem -LiteralPath $configStore -File -Force -ErrorAction Stop | Where-Object { $_.Name -match '\.conf(\.dpapi)?$' } | Select-Object -ExpandProperty Name)
        }
    } catch { $errors.Add('WireGuardConfigurationStore') }
    $sharing = @(); $sharingManager = $null
    try {
        $sharingManager = New-Object -ComObject HNetCfg.HNetShare -ErrorAction Stop
        foreach ($connection in @($sharingManager.EnumEveryConnection())) {
            $config = $null; $properties = $null
            try {
                $config = $sharingManager.INetSharingConfigurationForINetConnection($connection)
                if ($config.SharingEnabled) {
                    $properties = $sharingManager.NetConnectionProps($connection)
                    $sharing += [string]$properties.Name
                }
            } finally {
                foreach ($com in @($properties, $config, $connection)) { if ($null -ne $com -and [Runtime.InteropServices.Marshal]::IsComObject($com)) { $null = [Runtime.InteropServices.Marshal]::ReleaseComObject($com) } }
            }
        }
    } catch { $errors.Add('ICSConfiguration') }
    finally { if ($sharingManager -and [Runtime.InteropServices.Marshal]::IsComObject($sharingManager)) { $null = [Runtime.InteropServices.Marshal]::ReleaseComObject($sharingManager) } }
    $supported = $null -ne $os -and [int]$os.ProductType -in @(2,3) -and [string]$os.BuildNumber -eq '20348' -and [string]$os.Caption -match 'Server 2022'
    [pscustomobject]@{
        CapturedAtUtc = [DateTime]::UtcNow.ToString('o'); MachineId = $machineId; IsAdministrator = $admin
        OS = [pscustomobject]@{ Caption = [string](Get-TCProperty $os Caption 'Unknown'); Version = [string](Get-TCProperty $os Version ''); BuildNumber = [string](Get-TCProperty $os BuildNumber ''); ProductType = [int](Get-TCProperty $os ProductType 0); Supported = [bool]$supported }
        WireGuard = [pscustomobject]@{ Installed = [bool]$installed; WgPath = $wg; ServiceExecutable = $serviceExe; Interfaces = @($wgInterfaces); ConfigurationFiles = @($configs) }
        Adapters = @($adapters); IPv4Addresses = @($ip4); IPInterfaces = @($ipInterfaces); PersistentIPInterfaces = @($persistent)
        Routes = @($routes); Nat = @($nat); Services = @($services); UdpListeners = @($udp); FirewallProfiles = @($profiles); ProductFirewallNames = @($fw | ForEach-Object { $_.Name })
        ICSConnections = @($sharing); Errors = @($errors.ToArray())
    }
}

function Get-TCDefaultRoutes {
    param($Environment)
    @($Environment.Routes | Where-Object { $_.DestinationPrefix -in @('0.0.0.0/0', '::/0') } | Sort-Object DestinationPrefix, InterfaceIndex, NextHop, RouteMetric | Select-Object DestinationPrefix, NextHop, InterfaceIndex, RouteMetric)
}

function ConvertTo-TCStableJson {
    param($Value)
    ConvertTo-Json -InputObject @($Value) -Depth 20 -Compress
}

function Get-TCEnvironmentFingerprint {
    param($Environment, [string]$TunnelName)
    $excluded = @($Environment.Adapters | Where-Object { $_.Name -ceq $TunnelName } | ForEach-Object { $_.InterfaceIndex })
    $baseline = [ordered]@{
        MachineId = $Environment.MachineId; OS = $Environment.OS
        Adapters = @($Environment.Adapters | Where-Object { $_.Name -cne $TunnelName } | Sort-Object InterfaceIndex | Select-Object Name, InterfaceIndex, InterfaceGuid, MacAddress, Status)
        Addresses = @($Environment.IPv4Addresses | Where-Object { $_.InterfaceIndex -notin $excluded } | Sort-Object InterfaceIndex, IPAddress | Select-Object InterfaceIndex, IPAddress, PrefixLength, AddressState)
        Routes = @($Environment.Routes | Where-Object { $_.InterfaceIndex -notin $excluded } | Sort-Object DestinationPrefix, InterfaceIndex, NextHop, RouteMetric)
        DefaultRoutes = @(Get-TCDefaultRoutes $Environment)
    }
    Get-TCHash ($baseline | ConvertTo-Json -Depth 20 -Compress)
}

function Get-TCServerInspection {
    [CmdletBinding()]
    param([string]$Root)
    $rootPath = Resolve-TCRoot $Root
    $envState = Get-TCEnvironment
    $tunnels = @($envState.Services | Where-Object { $_.Name -like 'WireGuardTunnel$*' })
    $existing = $tunnels.Count -gt 0 -or @($envState.WireGuard.Interfaces).Count -gt 0 -or @($envState.WireGuard.ConfigurationFiles).Count -gt 0
    $ics = @($envState.Services | Where-Object { $_.Name -eq 'SharedAccess' })
    $rras = @($envState.Services | Where-Object { $_.Name -eq 'RemoteAccess' })
    $friendly = New-Object 'Collections.Generic.List[string]'
    if ($envState.OS.Supported) { $friendly.Add('系统：支持 Windows Server 2022。') } else { $friendly.Add('系统：仅支持 Windows Server 2022；当前系统不能部署。') }
    if ($envState.IsAdministrator) { $friendly.Add('权限：管理员。') } else { $friendly.Add('权限：非管理员；只能查看可读信息。') }
    if ($envState.WireGuard.Installed) { $friendly.Add('WireGuard：wg.exe 与服务程序已安装。') } else { $friendly.Add('WireGuard：缺少工具或服务程序。') }
    if ($existing) { $friendly.Add('发现已有 WireGuard 节点：优先检查，本模块不会接管或补改其 Peer。') }
    $friendly.Add(('IPv4 地址 {0} 个；WinNAT {1} 个；ICS/RRAS 状态见详情。' -f @($envState.IPv4Addresses).Count, @($envState.Nat).Count))
    $friendly.Add('保留 RDP：不修改管理默认路由、网关、DNS、RDP 规则或 ICS/RRAS。')
    if (@($envState.Errors).Count) { $friendly.Add(('检查不完整：' + ($envState.Errors -join ', '))) }
    $status = 'Inspected'
    if (-not $envState.OS.Supported) { $status = 'UnsupportedOS' }
    elseif (@($envState.Errors).Count) { $status = 'InspectionIncomplete' }
    elseif ($existing) { $status = 'ExistingNodeReadOnly' }
    [pscustomobject]@{
        SchemaVersion = 1; Status = $status; Friendly = ($friendly -join [Environment]::NewLine); Root = $rootPath
        CapturedAtUtc = $envState.CapturedAtUtc; OS = $envState.OS; IsAdministrator = $envState.IsAdministrator
        WireGuard = $envState.WireGuard; TunnelServices = $tunnels; ExistingNodeDetected = [bool]$existing
        Adapters = @($envState.Adapters); IPv4Addresses = @($envState.IPv4Addresses); Forwarding = @($envState.IPInterfaces); PersistentForwarding = @($envState.PersistentIPInterfaces)
        Nat = @($envState.Nat); ICS = [pscustomobject]@{ Services = $ics; EnabledConnections = @($envState.ICSConnections) }; RRAS = $rras
        ManagementDefaultRoutes = @(Get-TCDefaultRoutes $envState); RdpWarning = '必须保留现有 RDP 管理通路；云安全组与远端连通性未验证。'
        Errors = @($envState.Errors); ExternalConnectivity = 'NotTested'
    }
}

function Assert-TCBaseEnvironment {
    param($Environment)
    if (-not $Environment.OS.Supported -or [int]$Environment.OS.ProductType -notin @(2,3) -or [string]$Environment.OS.BuildNumber -ne '20348') { Stop-TC UnsupportedOS '仅支持 Windows Server 2022；当前主机拒绝部署。' }
    if (-not $Environment.IsAdministrator) { Stop-TC AdministratorRequired '服务器计划与部署需要管理员权限。' }
    if (-not $Environment.WireGuard.Installed) { Stop-TC WireGuardMissing '必须预先安装 WireGuard 的 wg.exe 和 wireguard.exe。' }
    if (@($Environment.Errors).Count -or [string]::IsNullOrWhiteSpace($Environment.MachineId)) { Stop-TC InspectionIncomplete ('环境检查不完整：' + ($Environment.Errors -join ', ')) }
    if (@($Environment.Services | Where-Object { $_.Name -in @('SharedAccess', 'RemoteAccess') -and $_.State -ne 'Stopped' }).Count -or @($Environment.ICSConnections).Count) { Stop-TC SharingConflict '检测到 ICS/RRAS；不改变已有共享或路由服务。' }
    $firewallService = @($Environment.Services | Where-Object { $_.Name -eq 'MpsSvc' -and $_.State -eq 'Running' })
    if ($firewallService.Count -ne 1 -or @($Environment.FirewallProfiles).Count -ne 3 -or @($Environment.FirewallProfiles | Where-Object { [string]$_.Enabled -notin @('True','1') -or [string]$_.AllowLocalFirewallRules -in @('False','0') }).Count) { Stop-TC FirewallUnavailable 'Windows 防火墙或本地规则策略不满足部署条件。' }
}

function Get-TCUplink {
    param($Environment, [string]$InterfaceAlias)
    if ([string]::IsNullOrWhiteSpace($InterfaceAlias) -or $InterfaceAlias -match '[\r\n\x00*?\[\]]') { Stop-TC InvalidInterface '请选择明确的单一出口网卡。' }
    $found = @($Environment.Adapters | Where-Object { $_.Name -ceq $InterfaceAlias })
    if ($found.Count -ne 1 -or [string]$found[0].Status -ne 'Up') { Stop-TC InvalidInterface '出口网卡不存在、不唯一或尚未启动。' }
    $adapter = $found[0]
    $addresses = @($Environment.IPv4Addresses | Where-Object { $_.InterfaceIndex -eq $adapter.InterfaceIndex -and [string]$_.AddressState -eq 'Preferred' })
    $routes = @($Environment.Routes | Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' })
    if (-not $addresses.Count -or -not $routes.Count -or @($routes | Where-Object { $_.InterfaceIndex -ne $adapter.InterfaceIndex }).Count) { Stop-TC ManagementRoute '首版要求单一 IPv4 默认出口且与所选网卡一致；不会修改默认路由。' }
    foreach ($store in @('IPInterfaces', 'PersistentIPInterfaces')) {
        $items = @($Environment.$store | Where-Object { $_.InterfaceIndex -eq $adapter.InterfaceIndex })
        if ($items.Count -ne 1 -or [string]$items[0].Forwarding -notin @('Enabled','Disabled')) { Stop-TC InspectionIncomplete '无法确定出口网卡的当前及持久转发状态。' }
    }
    [pscustomobject]@{ InterfaceAlias = [string]$adapter.Name; InterfaceIndex = [int]$adapter.InterfaceIndex; InterfaceGuid = [string]$adapter.InterfaceGuid; MacAddress = [string]$adapter.MacAddress }
}

function Assert-TCConflicts {
    param($Environment, $Plan, [switch]$Owned)
    $ownName = ''
    if ($Owned) { $ownName = $Plan.TunnelName }
    $otherServices = @($Environment.Services | Where-Object { $_.Name -like 'WireGuardTunnel$*' -and $_.Name -cne ('WireGuardTunnel$' + $ownName) })
    if ($otherServices.Count -or @($Environment.WireGuard.Interfaces | Where-Object { $_ -cne $ownName }).Count -or @($Environment.WireGuard.ConfigurationFiles).Count) { Stop-TC ExistingNodeReadOnly '已有 WireGuard 节点；请使用 inspection，不接管已有服务或 Peer。' }
    $otherNat = @($Environment.Nat | Where-Object { -not $Owned -or $_.Name -cne $Plan.NatName })
    if ($otherNat.Count) { Stop-TC NatConflict '检测到其他 WinNAT；首版只允许本产品独占一个专用网段。' }
    if (-not $Owned -and (@($Environment.Adapters | Where-Object { $_.Name -ieq $Plan.TunnelName }).Count -or $Plan.FirewallRuleName -in @($Environment.ProductFirewallNames))) { Stop-TC ObjectCollision '目标对象名称已存在且没有本产品授权记录。' }
    $subnet = Get-TCCidr $Plan.TunnelSubnet -Dedicated
    $excluded = @($Environment.Adapters | Where-Object { $Owned -and $_.Name -ceq $ownName } | ForEach-Object { $_.InterfaceIndex })
    foreach ($address in @($Environment.IPv4Addresses | Where-Object { $_.InterfaceIndex -notin $excluded })) {
        if (Test-TCOverlap $subnet (Get-TCCidr ($address.IPAddress + '/' + $address.PrefixLength))) { Stop-TC SubnetConflict '隧道网段与已有 IPv4 地址网段重叠。' }
    }
    foreach ($route in @($Environment.Routes | Where-Object { $_.DestinationPrefix -ne '0.0.0.0/0' -and $_.DestinationPrefix -notmatch ':' -and $_.InterfaceIndex -notin $excluded })) {
        if (Test-TCOverlap $subnet (Get-TCCidr $route.DestinationPrefix)) { Stop-TC SubnetConflict '隧道网段与已有路由重叠。' }
    }
    if (-not $Owned -and @($Environment.UdpListeners | Where-Object { $_.LocalPort -eq $Plan.ListenPort }).Count) { Stop-TC PortConflict 'UDP 端口已被占用。' }
}

function Get-TCRootOwner {
    param([string]$Root, $Environment, [switch]$Initialize)
    $ownerPath = Join-Path $Root 'owner.json'
    if (-not (Test-Path -LiteralPath $ownerPath)) {
        if (-not $Initialize) { Stop-TC OwnershipRequired '缺少本产品 Root 授权标记。' }
        if ((Test-Path -LiteralPath $Root) -and @(Get-ChildItem -LiteralPath $Root -Force -ErrorAction Stop).Count) { Stop-TC ForeignRoot 'Root 已有其他内容，拒绝接管或更改其 ACL。' }
        New-TCPrivateDirectory $Root
        $owner = [pscustomobject]@{ SchemaVersion = 1; Kind = 'TradeChannel.ServerRoot'; RootId = [guid]::NewGuid().ToString(); RootPath = $Root; MachineId = $Environment.MachineId }
        Write-TCJson $ownerPath $owner -NewOnly
    }
    Assert-TCPrivatePath $Root
    $owner = Read-TCJson $ownerPath -Private
    if ($owner.SchemaVersion -ne 1 -or $owner.Kind -cne 'TradeChannel.ServerRoot' -or $owner.RootPath -ine $Root -or $owner.MachineId -cne $Environment.MachineId) { Stop-TC OwnershipMismatch '状态目录不属于当前机器或当前产品 Root。' }
    Assert-TCGuid $owner.RootId
    return $owner
}

function New-TCServerPlan {
    [CmdletBinding()]
    param([string]$Root, [Parameter(Mandatory=$true)][string]$PublicEndpoint, [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][string]$InterfaceAlias, [Parameter(Mandatory=$true)][string]$TunnelSubnet)
    $ErrorActionPreference = 'Stop'
    $rootPath = Resolve-TCRoot $Root
    $endpoint = Get-TCEndpoint $PublicEndpoint
    $cidr = Get-TCCidr $TunnelSubnet -Dedicated
    $endpointAddress = ConvertTo-TCIPv4Number $endpoint.Address
    if ($endpointAddress -ge $cidr.Start -and $endpointAddress -le $cidr.End) { Stop-TC EndpointConflict '公网端点不能位于新建专用隧道网段内。' }
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name.Length -gt 80 -or $Name -match '[\x00-\x1f]') { Stop-TC InvalidName '名称必须是 1-80 个可显示字符。' }
    $envState = Get-TCEnvironment
    Assert-TCBaseEnvironment $envState
    $uplink = Get-TCUplink $envState $InterfaceAlias
    if (Test-Path -LiteralPath (Join-Path $rootPath 'manifest.json')) { Stop-TC ExistingNodeReadOnly '此 Root 已有部署记录；先检查既有节点，不创建替代节点。' }
    $nodeId = [guid]::NewGuid().ToString()
    $tunnel = 'tc-' + $nodeId.Replace('-', '').Substring(0,12)
    $plan = [pscustomobject][ordered]@{
        SchemaVersion = 1; Kind = 'TradeChannel.ServerPlan'; PlanId = [guid]::NewGuid().ToString(); NodeId = $nodeId; RootId = ''; MachineId = $envState.MachineId
        CreatedAtUtc = [DateTime]::UtcNow.ToString('o'); ExpiresAtUtc = [DateTime]::UtcNow.AddHours(24).ToString('o')
        Name = $Name; PublicEndpoint = $endpoint.Value; ListenPort = $endpoint.Port; TunnelSubnet = $cidr.Canonical
        ServerAddress = ((ConvertFrom-TCIPv4Number ($cidr.Start + 1)) + '/' + $cidr.PrefixLength)
        TunnelName = $tunnel; ServiceName = ('WireGuardTunnel$' + $tunnel); NatName = $tunnel; FirewallRuleName = ($tunnel + '-udp'); Uplink = $uplink
        EnvironmentFingerprint = (Get-TCEnvironmentFingerprint $envState $tunnel); ManagementDefaultRoutes = @(Get-TCDefaultRoutes $envState)
        ForwardingBefore = [pscustomobject]@{ ActiveStore = [string](@($envState.IPInterfaces | Where-Object { $_.InterfaceIndex -eq $uplink.InterfaceIndex })[0].Forwarding); PersistentStore = [string](@($envState.PersistentIPInterfaces | Where-Object { $_.InterfaceIndex -eq $uplink.InterfaceIndex })[0].Forwarding) }
        CloudFirewall = 'NotVerified'; RequiredCloudRule = ('UDP ' + $endpoint.Port); ExternalConnectivity = 'NotTested'
    }
    Assert-TCConflicts $envState $plan
    $owner = Get-TCRootOwner $rootPath $envState -Initialize
    $plan.RootId = $owner.RootId
    $plansDir = Join-Path $rootPath 'plans'
    New-TCPrivateDirectory $plansDir
    $planPath = Join-Path $plansDir ($plan.PlanId + '.json')
    Write-TCJson $planPath $plan -NewOnly
    [pscustomobject]@{ SchemaVersion = 1; Status = 'Planned'; Friendly = '仅生成计划，未修改网络。应用前将重新校验环境；计划 24 小时有效。'; Plan = $plan; PlanPath = $planPath }
}

function Read-TCServerPlan {
    param([string]$Root, [string]$PlanPath, $Owner)
    $path = Get-TCFullPath $PlanPath
    $plan = Read-TCJson $path -Private
    foreach ($property in @('SchemaVersion','Kind','PlanId','NodeId','RootId','MachineId','CreatedAtUtc','ExpiresAtUtc','Name','PublicEndpoint','ListenPort','TunnelSubnet','ServerAddress','TunnelName','ServiceName','NatName','FirewallRuleName','Uplink','EnvironmentFingerprint','ManagementDefaultRoutes','ForwardingBefore')) {
        if ($null -eq $plan.PSObject.Properties[$property]) { Stop-TC InvalidPlan '计划缺少必需字段。' }
    }
    Assert-TCGuid $plan.PlanId; Assert-TCGuid $plan.NodeId
    $expectedName = 'tc-' + $plan.NodeId.Replace('-', '').Substring(0,12)
    $cidr = Get-TCCidr $plan.TunnelSubnet -Dedicated
    $endpoint = Get-TCEndpoint $plan.PublicEndpoint
    $endpointAddress = ConvertTo-TCIPv4Number $endpoint.Address
    if ($endpointAddress -ge $cidr.Start -and $endpointAddress -le $cidr.End) { Stop-TC InvalidPlan '公网端点不能位于专用隧道网段内。' }
    $expectedPath = Join-Path (Join-Path $Root 'plans') ($plan.PlanId + '.json')
    if ($plan.SchemaVersion -ne 1 -or $plan.Kind -cne 'TradeChannel.ServerPlan' -or $path -ine $expectedPath -or $plan.RootId -cne $Owner.RootId -or $plan.MachineId -cne $Owner.MachineId -or $plan.TunnelName -cne $expectedName -or $plan.ServiceName -cne ('WireGuardTunnel$' + $expectedName) -or $plan.NatName -cne $expectedName -or $plan.FirewallRuleName -cne ($expectedName + '-udp') -or $plan.ListenPort -ne $endpoint.Port -or $plan.ServerAddress -cne ((ConvertFrom-TCIPv4Number ($cidr.Start + 1)) + '/' + $cidr.PrefixLength)) {
        Stop-TC InvalidPlan '计划路径、产品身份或派生对象名称不匹配。'
    }
    if ($plan.Name -match '[\x00-\x1f]' -or [string]::IsNullOrWhiteSpace($plan.Name) -or $plan.Name.Length -gt 80 -or $plan.EnvironmentFingerprint -cnotmatch '^[0-9a-f]{64}$') { Stop-TC InvalidPlan '计划内容无效。' }
    foreach ($store in @('ActiveStore','PersistentStore')) { if ($plan.ForwardingBefore.$store -notin @('Enabled','Disabled')) { Stop-TC InvalidPlan '计划转发状态无效。' } }
    return $plan
}

function Assert-TCFreshEnvironment {
    param($Environment, $Plan, [switch]$Owned)
    Assert-TCBaseEnvironment $Environment
    $uplink = Get-TCUplink $Environment $Plan.Uplink.InterfaceAlias
    if ((ConvertTo-TCStableJson $uplink) -cne (ConvertTo-TCStableJson $Plan.Uplink)) { Stop-TC StalePlan '出口网卡身份已变化；拒绝使用旧索引。' }
    Assert-TCConflicts $Environment $Plan -Owned:$Owned
    if ((Get-TCEnvironmentFingerprint $Environment $Plan.TunnelName) -cne $Plan.EnvironmentFingerprint -or (ConvertTo-TCStableJson (Get-TCDefaultRoutes $Environment)) -cne (ConvertTo-TCStableJson $Plan.ManagementDefaultRoutes)) { Stop-TC StalePlan '环境或管理默认路由已变化，必须重新检查。' }
    if (-not $Owned) {
        try { $expires = [DateTime]::Parse($Plan.ExpiresAtUtc).ToUniversalTime() } catch { Stop-TC InvalidPlan '计划有效期格式无效。' }
        if ($expires -le [DateTime]::UtcNow) { Stop-TC PlanExpired '计划已过期，请重新生成。' }
        $active = @($Environment.IPInterfaces | Where-Object { $_.InterfaceIndex -eq $Plan.Uplink.InterfaceIndex })[0]
        $persistent = @($Environment.PersistentIPInterfaces | Where-Object { $_.InterfaceIndex -eq $Plan.Uplink.InterfaceIndex })[0]
        if ([string]$active.Forwarding -cne $Plan.ForwardingBefore.ActiveStore -or [string]$persistent.Forwarding -cne $Plan.ForwardingBefore.PersistentStore) { Stop-TC StalePlan '出口转发状态已变化，请重新生成计划。' }
    }
}

function Get-TCConfigPath {
    param([string]$Root, $Plan)
    Join-Path (Join-Path (Join-Path $Root 'nodes') $Plan.NodeId) ($Plan.TunnelName + '.conf')
}

function Get-TCServerConfigText {
    param($Plan, [string]$PrivateKey, [object[]]$Peers, [switch]$SyncOnly)
    Assert-TCKey $PrivateKey
    $lines = @('[Interface]', ('PrivateKey = ' + $PrivateKey), ('ListenPort = ' + $Plan.ListenPort))
    if (-not $SyncOnly) { $lines += @(('Address = ' + $Plan.ServerAddress), 'Table = off') }
    foreach ($peer in @($Peers | Sort-Object DeviceId)) {
        Assert-TCKey $peer.ClientPublicKey
        $null = Get-TCClientAddress $Plan $peer.ClientAddress
        $lines += @('', '[Peer]', ('PublicKey = ' + $peer.ClientPublicKey), ('AllowedIPs = ' + $peer.ClientAddress))
    }
    return (($lines -join "`r`n") + "`r`n")
}

function Get-TCClientAddress {
    param($Plan, [string]$Address)
    if ($Address -match '/') {
        if ($Address -notmatch '^([^/]+)/32$') { Stop-TC InvalidClientAddress '设备必须使用单个 IPv4 /32 地址。' }
        $Address = $Matches[1]
    }
    $number = ConvertTo-TCIPv4Number $Address
    $cidr = Get-TCCidr $Plan.TunnelSubnet -Dedicated
    if ($number -le ($cidr.Start + 1) -or $number -ge $cidr.End) { Stop-TC InvalidClientAddress '设备地址必须在专用网段内且不能占用网络、服务器或广播地址。' }
    return ($Address + '/32')
}

function Get-TCService {
    param([string]$Name)
    if ($Name -notmatch '^WireGuardTunnel\$tc-[a-f0-9]{12}$') { Stop-TC OwnershipMismatch '拒绝查询非产品服务作为授权目标。' }
    @(Get-CimInstance -ClassName Win32_Service -Filter ("Name='" + $Name + "'") -ErrorAction Stop)
}

function Assert-TCOwnedService {
    param($Service, $Plan, [string]$ConfigPath, [string]$ServiceExecutable, [switch]$RequireRunning)
    $items = @($Service)
    if ($items.Count -ne 1) { Stop-TC ServiceDrift '本产品服务不存在或不唯一。' }
    $pattern = '^\s*"?' + [regex]::Escape($ServiceExecutable) + '"?\s+/tunnelservice\s+"?' + [regex]::Escape($ConfigPath) + '"?\s*$'
    if ($items[0].Name -cne $Plan.ServiceName -or $items[0].PathName -notmatch $pattern -or $items[0].StartName -notin @('LocalSystem','NT AUTHORITY\SYSTEM') -or $items[0].StartMode -ne 'Auto') { Stop-TC OwnershipMismatch '服务程序、配置路径或运行身份不匹配，拒绝修改。' }
    if ($RequireRunning -and $items[0].State -ne 'Running') { Stop-TC ServiceDrift '本产品服务未运行。' }
}

function Wait-TCTunnel {
    param($Plan, [string]$ConfigPath, [string]$ServiceExecutable)
    $until = [DateTime]::UtcNow.AddSeconds(30)
    do {
        $service = @(Get-TCService $Plan.ServiceName)
        if ($service.Count -gt 0) {
            Assert-TCOwnedService $service $Plan $ConfigPath $ServiceExecutable
            $adapter = @(Get-NetAdapter -IncludeHidden -ErrorAction Stop | Where-Object { $_.Name -ceq $Plan.TunnelName })
            $ip = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.InterfaceAlias -ceq $Plan.TunnelName -and ($_.IPAddress + '/' + $_.PrefixLength) -ceq $Plan.ServerAddress -and [string]$_.AddressState -eq 'Preferred' })
            if ($service[0].State -eq 'Running' -and $adapter.Count -eq 1 -and $ip.Count -eq 1) { return $adapter[0] }
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $until)
    Stop-TC TunnelTimeout 'WireGuard 服务或隧道地址未在 30 秒内就绪。'
}

function Get-TCForwarding {
    param([int]$InterfaceIndex, [string]$Store)
    $items = @(Get-NetIPInterface -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -PolicyStore $Store -ErrorAction Stop)
    if ($items.Count -ne 1 -or [string]$items[0].Forwarding -notin @('Enabled','Disabled')) { Stop-TC ForwardingUnknown '无法确定指定网卡的转发状态。' }
    return [string]$items[0].Forwarding
}

function Set-TCForwarding {
    param([int]$InterfaceIndex, [string]$Store, [string]$Value)
    $null = Set-NetIPInterface -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -PolicyStore $Store -Forwarding $Value -ErrorAction Stop
    if ((Get-TCForwarding $InterfaceIndex $Store) -cne $Value) { Stop-TC ForwardingVerification '网卡转发设置验证失败。' }
}

function Get-TCFirewallDescription {
    param($Plan)
    'TradeChannel.Server/v1 RootId=' + $Plan.RootId + ' NodeId=' + $Plan.NodeId
}

function Assert-TCNat {
    param($Nat, $Plan)
    $items = @($Nat)
    if ($items.Count -ne 1 -or $items[0].Name -cne $Plan.NatName -or [string]$items[0].InternalIPInterfaceAddressPrefix -cne $Plan.TunnelSubnet -or -not [string]::IsNullOrWhiteSpace([string]$items[0].ExternalIPInterfaceAddressPrefix) -or -not [bool]$items[0].Active) { Stop-TC NatDrift '本产品 WinNAT 对象缺失或与授权网段不一致。' }
}

function Get-TCFirewallState {
    param($Plan, [string]$Store)
    $rules = @(Get-NetFirewallRule -PolicyStore $Store -ErrorAction Stop | Where-Object { $_.Name -ceq $Plan.FirewallRuleName })
    foreach ($rule in $rules) {
        $port = @($rule | Get-NetFirewallPortFilter -ErrorAction Stop)
        $iface = @($rule | Get-NetFirewallInterfaceFilter -ErrorAction Stop)
        $address = @($rule | Get-NetFirewallAddressFilter -ErrorAction Stop)
        [pscustomobject]@{ Name = $rule.Name; Group = $rule.Group; Description = $rule.Description; Enabled = [string]$rule.Enabled; Direction = [string]$rule.Direction; Action = [string]$rule.Action; Profile = [string]$rule.Profile
            Protocol = [string]($port.Protocol); LocalPort = @($port.LocalPort); RemotePort = @($port.RemotePort); InterfaceAlias = @($iface.InterfaceAlias); LocalAddress = @($address.LocalAddress); RemoteAddress = @($address.RemoteAddress) }
    }
}

function Assert-TCFirewall {
    param($Rules, $Plan)
    $items = @($Rules)
    if ($items.Count -ne 1) { Stop-TC FirewallDrift '本产品防火墙规则缺失或不唯一。' }
    $rule = $items[0]
    if ($rule.Name -cne $Plan.FirewallRuleName -or $rule.Group -cne 'TradeChannel.Server' -or $rule.Description -cne (Get-TCFirewallDescription $Plan) -or $rule.Enabled -notin @('True','1') -or $rule.Direction -ne 'Inbound' -or $rule.Action -ne 'Allow' -or $rule.Profile -notin @('Any','0') -or $rule.Protocol -notin @('UDP','17') -or (@($rule.LocalPort) -join ',') -cne [string]$Plan.ListenPort -or (@($rule.RemotePort) -join ',') -cne 'Any' -or (@($rule.InterfaceAlias) -join ',') -cne $Plan.Uplink.InterfaceAlias -or (@($rule.LocalAddress) -join ',') -cne 'Any' -or (@($rule.RemoteAddress) -join ',') -cne 'Any') { Stop-TC FirewallDrift '防火墙规则与本产品授权对象不匹配。' }
}

function Get-TCWgRuntime {
    param([string]$WgPath, $Plan)
    $public = Invoke-TCNative $WgPath @('show', $Plan.TunnelName, 'public-key')
    $port = Invoke-TCNative $WgPath @('show', $Plan.TunnelName, 'listen-port')
    $allowed = Invoke-TCNative $WgPath @('show', $Plan.TunnelName, 'allowed-ips')
    $peers = @()
    foreach ($line in @($allowed -split '[\r\n]+' | Where-Object { $_ })) {
        if ($line -notmatch '^(\S+)\s+(\S+)\s*$') { Stop-TC PeerDrift '当前 Peer AllowedIPs 格式不符合本产品单地址授权。' }
        $peers += [pscustomobject]@{ ClientPublicKey = $Matches[1]; ClientAddress = $Matches[2] }
    }
    # Detect out-of-band PSK/keepalive changes before syncconf could reset them.
    # Never put the PSK values into a result, journal, error, or manifest.
    $defaultOptions = $true
    $peerKeys = @($peers | ForEach-Object { $_.ClientPublicKey } | Sort-Object)
    foreach ($field in @('preshared-keys','persistent-keepalive')) {
        $values = Invoke-TCNative $WgPath @('show', $Plan.TunnelName, $field)
        $seen = @()
        foreach ($line in @($values -split '[\r\n]+' | Where-Object { $_ })) {
            if ($line -notmatch '^(\S+)\s+(\S+)\s*$') { $defaultOptions = $false; continue }
            $seen += $Matches[1]
            if ($field -eq 'preshared-keys' -and $Matches[2] -cnotin @('(none)','AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=')) { $defaultOptions = $false }
            if ($field -eq 'persistent-keepalive' -and $Matches[2] -cnotin @('off','0')) { $defaultOptions = $false }
        }
        if ((ConvertTo-TCStableJson @($seen | Sort-Object)) -cne (ConvertTo-TCStableJson $peerKeys)) { $defaultOptions = $false }
        $values = $null
    }
    $mark = Invoke-TCNative $WgPath @('show', $Plan.TunnelName, 'fwmark')
    if ($mark -cnotin @('off','0','0x0')) { $defaultOptions = $false }
    [pscustomobject]@{ ServerPublicKey = $public; ListenPort = $port; Peers = @($peers); DefaultPeerOptions = $defaultOptions }
}

function Assert-TCPeerRuntime {
    param($Runtime, $Manifest, $Plan)
    $expected = @($Manifest.Peers | Sort-Object ClientPublicKey | Select-Object ClientPublicKey, ClientAddress)
    $actual = @($Runtime.Peers | Sort-Object ClientPublicKey | Select-Object ClientPublicKey, ClientAddress)
    if (-not $Runtime.DefaultPeerOptions -or $Runtime.ServerPublicKey -cne $Manifest.ServerPublicKey -or [string]$Runtime.ListenPort -cne [string]$Plan.ListenPort -or (ConvertTo-TCStableJson $actual) -cne (ConvertTo-TCStableJson $expected)) { Stop-TC PeerDrift '运行中的 WireGuard 身份、端口或 Peer 与产品记录不一致；不会修补已有 Peer。' }
}

function Read-TCManifest {
    param([string]$Root, $Owner, $Plan)
    $manifest = Read-TCJson (Join-Path $Root 'manifest.json') -Private
    $planPath = Join-Path (Join-Path $Root 'plans') ($Plan.PlanId + '.json')
    if ($manifest.SchemaVersion -ne 1 -or $manifest.Kind -cne 'TradeChannel.ServerManifest' -or $manifest.RootId -cne $Owner.RootId -or $manifest.NodeId -cne $Plan.NodeId -or $manifest.PlanId -cne $Plan.PlanId -or $manifest.PlanHash -cne (Get-TCFileHash $planPath) -or $manifest.ConfigPath -ine (Get-TCConfigPath $Root $Plan)) { Stop-TC OwnershipMismatch '部署 manifest 与受限计划、Root 或配置路径不匹配。' }
    if ($manifest.Status -cne 'Applied') { Stop-TC NeedsRecovery ('部署状态为 ' + $manifest.Status + '；先检查受限事务与回滚记录。') }
    Assert-TCKey $manifest.ServerPublicKey
    Assert-TCPrivatePath $manifest.ConfigPath
    if ((Get-TCFileHash $manifest.ConfigPath) -cne $manifest.ConfigHash) { Stop-TC ConfigDrift '服务器配置已改变；不会覆盖或补改。' }
    $ids = @(); $keys = @(); $addresses = @(); $requests = @()
    foreach ($peer in @($manifest.Peers)) {
        Assert-TCGuid $peer.DeviceId; Assert-TCGuid $peer.RequestId; Assert-TCKey $peer.ClientPublicKey
        if ((Get-TCClientAddress $Plan $peer.ClientAddress) -cne $peer.ClientAddress -or $peer.DeviceId -in $ids -or $peer.RequestId -in $requests -or $peer.ClientPublicKey -cin $keys -or $peer.ClientAddress -in $addresses) { Stop-TC InvalidManifest '设备授权记录重复或无效。' }
        $ids += $peer.DeviceId; $requests += $peer.RequestId; $keys += $peer.ClientPublicKey; $addresses += $peer.ClientAddress
    }
    return $manifest
}

function Test-TCAppliedState {
    param([string]$Root, $Plan, $Manifest, [string]$WgPath)
    $envState = Get-TCEnvironment
    Assert-TCFreshEnvironment $envState $Plan -Owned
    Assert-TCOwnedService @(Get-TCService $Plan.ServiceName) $Plan (Get-TCConfigPath $Root $Plan) $envState.WireGuard.ServiceExecutable -RequireRunning
    $adapters = @($envState.Adapters | Where-Object { $_.Name -ceq $Plan.TunnelName })
    $ip = @($envState.IPv4Addresses | Where-Object { $_.InterfaceAlias -ceq $Plan.TunnelName })
    if ($adapters.Count -ne 1 -or [string]$adapters[0].Status -ne 'Up' -or $ip.Count -ne 1 -or ($ip[0].IPAddress + '/' + $ip[0].PrefixLength) -cne $Plan.ServerAddress -or [string]$ip[0].AddressState -ne 'Preferred') { Stop-TC TunnelDrift '本产品隧道网卡或地址发生漂移。' }
    foreach ($index in @([int]$Plan.Uplink.InterfaceIndex, [int]$adapters[0].InterfaceIndex)) {
        foreach ($store in @('ActiveStore','PersistentStore')) { if ((Get-TCForwarding $index $store) -cne 'Enabled') { Stop-TC ForwardingDrift '本产品所需转发状态发生漂移。' } }
    }
    Assert-TCNat @($envState.Nat) $Plan
    foreach ($store in @('ActiveStore','PersistentStore')) { Assert-TCFirewall @(Get-TCFirewallState $Plan $store) $Plan }
    Assert-TCPeerRuntime (Get-TCWgRuntime $WgPath $Plan) $Manifest $Plan
    Assert-TCPrivatePath $Manifest.ConfigPath
    if ((Get-TCFileHash $Manifest.ConfigPath) -cne $Manifest.ConfigHash) { Stop-TC ConfigDrift '服务器配置校验不匹配。' }
    [pscustomobject]@{ LocalConfiguration = 'Verified'; VerifiedAtUtc = [DateTime]::UtcNow.ToString('o'); ManagementDefaultRoutesPreserved = $true; CloudFirewall = 'NotVerified'; ExternalConnectivity = 'NotTested'; Handshake = 'NotTested'; RebootPersistence = 'NotTested' }
}

function Enter-TCServerLock {
    param([string]$Root)
    $path = Join-Path $Root 'operation.lock'
    $null = Get-TCFullPath $path
    try { $stream = [IO.File]::Open($path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
    catch { Stop-TC Busy '另一个产品操作正在运行。' }
    return $stream
}

function New-TCTransaction {
    param([string]$Root, [string]$Kind, $Plan)
    $id = [guid]::NewGuid().ToString()
    $parent = Join-Path $Root 'transactions'
    New-TCPrivateDirectory $parent
    $dir = Join-Path $parent $id
    New-TCPrivateDirectory $dir
    $manifestPath = Join-Path $Root 'manifest.json'
    if (Test-Path -LiteralPath $manifestPath) { Write-TCText (Join-Path $dir 'manifest.before.json') ([IO.File]::ReadAllText($manifestPath)) -NewOnly }
    else { Write-TCJson (Join-Path $dir 'manifest.before.json') ([pscustomobject]@{ SchemaVersion = 1; Status = 'Absent' }) -NewOnly }
    $journal = [pscustomobject]@{ SchemaVersion = 1; Kind = $Kind; TransactionId = $id; NodeId = $Plan.NodeId; RootId = $Plan.RootId; Status = 'Applying'; StartedAtUtc = [DateTime]::UtcNow.ToString('o'); FinishedAtUtc = $null; Steps = @(); ErrorCode = $null; ManagementDefaultRoutes = @($Plan.ManagementDefaultRoutes) }
    $transaction = [pscustomobject]@{ Directory = $dir; Path = (Join-Path $dir 'rollback.json'); Journal = $journal }
    Save-TCTransaction $transaction
    return $transaction
}

function Save-TCTransaction {
    param($Transaction)
    Write-TCJson $Transaction.Path $Transaction.Journal
}

function Add-TCTransactionStep {
    param($Transaction, [string]$Kind, $Target, $Before)
    $step = [pscustomobject]@{ Kind = $Kind; Target = $Target; Before = $Before; Status = 'Pending'; Rollback = 'NotRequired'; ErrorCode = $null }
    $Transaction.Journal.Steps += $step
    Save-TCTransaction $Transaction
    return $step
}

function Complete-TCTransactionStep {
    param($Transaction, $Step)
    $Step.Status = 'Applied'
    Save-TCTransaction $Transaction
}

function Get-TCErrorCode {
    param($Record)
    if ($Record.Exception.Message -match '\[TC:([A-Za-z0-9]+)\]') { return $Matches[1] }
    return 'OperationFailed'
}

function Undo-TCDeployment {
    param($Transaction, [string]$Root, $Plan, [string]$ServiceExecutable)
    $ok = $true
    $steps = @($Transaction.Journal.Steps)
    [array]::Reverse($steps)
    foreach ($step in $steps) {
        try {
            switch ($step.Kind) {
                'Firewall' {
                    $rules = @(Get-TCFirewallState $Plan 'PersistentStore')
                    if ($rules.Count) { Assert-TCFirewall $rules $Plan; $null = Remove-NetFirewallRule -PolicyStore PersistentStore -Name $Plan.FirewallRuleName -ErrorAction Stop }
                    if (@(Get-TCFirewallState $Plan 'PersistentStore').Count) { Stop-TC RollbackVerification '防火墙回滚未完成。' }
                }
                'Nat' {
                    $items = @(Get-NetNat -ErrorAction Stop | Where-Object { $_.Name -ceq $Plan.NatName })
                    if ($items.Count) { Assert-TCNat $items $Plan; $null = Remove-NetNat -Name $Plan.NatName -Confirm:$false -ErrorAction Stop }
                    if (@(Get-NetNat -ErrorAction Stop | Where-Object { $_.Name -ceq $Plan.NatName }).Count) { Stop-TC RollbackVerification 'NAT 回滚未完成。' }
                }
                'Forwarding' {
                    $target = $step.Target
                    $adapter = @(Get-NetAdapter -IncludeHidden -ErrorAction Stop | Where-Object { $_.InterfaceIndex -eq $target.InterfaceIndex -and [string]$_.InterfaceGuid -ceq $target.InterfaceGuid -and $_.Name -ceq $target.InterfaceAlias })
                    if ($adapter.Count -ne 1) { Stop-TC RollbackOwnership '网卡身份变化；未回滚其转发状态。' }
                    foreach ($store in @('PersistentStore','ActiveStore')) {
                        $value = Get-TCForwarding $target.InterfaceIndex $store
                        if ($value -cne $step.Before.$store -and $value -cne 'Enabled') { Stop-TC RollbackOwnership '转发状态已由外部改变。' }
                    }
                    # PersistentStore can also update ActiveStore. Restore the
                    # persistent setting first, then restore the active value.
                    Set-TCForwarding $target.InterfaceIndex 'PersistentStore' $step.Before.PersistentStore
                    Set-TCForwarding $target.InterfaceIndex 'ActiveStore' $step.Before.ActiveStore
                }
                'Service' {
                    $service = @(Get-TCService $Plan.ServiceName)
                    if ($service.Count) {
                        Assert-TCOwnedService $service $Plan (Get-TCConfigPath $Root $Plan) $ServiceExecutable
                        $null = Invoke-TCNative $ServiceExecutable @('/uninstalltunnelservice', $Plan.TunnelName)
                    }
                    if (@(Get-TCService $Plan.ServiceName).Count) { Stop-TC RollbackVerification '服务回滚未完成。' }
                }
            }
            $step.Rollback = 'Reverted'
        } catch { $step.Rollback = 'Failed'; $step.ErrorCode = Get-TCErrorCode $_; $ok = $false }
        Save-TCTransaction $Transaction
    }
    try {
        $envState = Get-TCEnvironment
        if ((ConvertTo-TCStableJson (Get-TCDefaultRoutes $envState)) -cne (ConvertTo-TCStableJson $Plan.ManagementDefaultRoutes)) { $ok = $false }
    } catch { $ok = $false }
    return $ok
}

function Get-TCNode {
    param($Plan, $Manifest)
    [pscustomobject]@{ SchemaVersion = 1; NodeId = $Plan.NodeId; Name = $Plan.Name; Type = 'WireGuard'; PublicEndpoint = $Plan.PublicEndpoint; ServerPublicKey = $Manifest.ServerPublicKey; TunnelSubnet = $Plan.TunnelSubnet; ServerAddress = $Plan.ServerAddress; AddressFamilies = @('IPv4'); ConfigRevision = $Manifest.ConfigRevision }
}

function Invoke-TCServerPlan {
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')]
    param([string]$Root, [Parameter(Mandatory=$true)][string]$PlanPath, [string]$WgPath)
    $ErrorActionPreference = 'Stop'
    $rootPath = Resolve-TCRoot $Root
    $envState = Get-TCEnvironment
    Assert-TCBaseEnvironment $envState
    $owner = Get-TCRootOwner $rootPath $envState
    $plan = Read-TCServerPlan $rootPath $PlanPath $owner
    $wg = Resolve-TCWgPath $WgPath
    # An alternate wg.exe is permitted for key/protocol operations. The service
    # executable is always the already installed program observed at inspection.
    $serviceExe = Get-TCFullPath $envState.WireGuard.ServiceExecutable
    $manifestPath = Join-Path $rootPath 'manifest.json'
    if ($WhatIfPreference) {
        $owned = Test-Path -LiteralPath $manifestPath
        Assert-TCFreshEnvironment $envState $plan -Owned:$owned
        if ($owned) { $manifest = Read-TCManifest $rootPath $owner $plan; $null = Test-TCAppliedState $rootPath $plan $manifest $wg }
        return [pscustomobject]@{ SchemaVersion = 1; Status = 'WhatIf'; Friendly = '只读预检完成，未执行部署。'; PlanPath = (Get-TCFullPath $PlanPath); Plan = $plan }
    }
    if (-not $PSCmdlet.ShouldProcess($plan.TunnelName, '应用本产品专用 WireGuard、WinNAT、转发及 UDP 防火墙配置')) { return }
    $lock = Enter-TCServerLock $rootPath
    $transaction = $null; $manifest = $null
    try {
        $envState = Get-TCEnvironment
        if (Test-Path -LiteralPath $manifestPath) {
            $manifest = Read-TCManifest $rootPath $owner $plan
            $validation = Test-TCAppliedState $rootPath $plan $manifest $wg
            return [pscustomobject]@{ SchemaVersion = 1; Status = 'AlreadyApplied'; Friendly = '本产品本机配置一致；未重复修改。公网、安全组及握手未验证。'; ManifestPath = $manifestPath; Node = (Get-TCNode $plan $manifest); Validation = $validation }
        }
        Assert-TCFreshEnvironment $envState $plan
        $transaction = New-TCTransaction $rootPath 'TradeChannel.DeploymentTransaction' $plan
        Write-TCJson (Join-Path $transaction.Directory 'environment.before.json') $envState -NewOnly
        $nodesDir = Join-Path $rootPath 'nodes'
        New-TCPrivateDirectory $nodesDir
        $nodeDir = Join-Path $nodesDir $plan.NodeId
        if (Test-Path -LiteralPath $nodeDir) { Stop-TC ObjectCollision '节点目录已存在，拒绝覆盖。' }
        New-TCPrivateDirectory $nodeDir
        $configPath = Get-TCConfigPath $rootPath $plan
        $pair = New-TCKeyPair $wg
        Write-TCText $configPath (Get-TCServerConfigText $plan $pair.Private @()) -NewOnly
        $manifest = [pscustomobject][ordered]@{
            SchemaVersion = 1; Kind = 'TradeChannel.ServerManifest'; RootId = $owner.RootId; NodeId = $plan.NodeId; PlanId = $plan.PlanId
            PlanHash = (Get-TCFileHash $PlanPath); Status = 'Applying'; ServerPublicKey = $pair.Public; ConfigPath = $configPath; ConfigHash = (Get-TCFileHash $configPath)
            ConfigRevision = 1; Peers = @(); TransactionId = $transaction.Journal.TransactionId; Validation = $null
        }
        $pair = $null
        Write-TCJson $manifestPath $manifest -NewOnly
        # Last read immediately before the first external mutation.
        Assert-TCFreshEnvironment (Get-TCEnvironment) $plan
        $step = Add-TCTransactionStep $transaction 'Service' $plan.ServiceName 'Absent'
        $null = Invoke-TCNative $serviceExe @('/installtunnelservice', $configPath)
        $tunnelAdapter = Wait-TCTunnel $plan $configPath $serviceExe
        Complete-TCTransactionStep $transaction $step
        foreach ($adapter in @($plan.Uplink, [pscustomobject]@{ InterfaceAlias = $plan.TunnelName; InterfaceIndex = $tunnelAdapter.InterfaceIndex; InterfaceGuid = [string]$tunnelAdapter.InterfaceGuid })) {
            $before = [pscustomobject]@{ ActiveStore = (Get-TCForwarding $adapter.InterfaceIndex 'ActiveStore'); PersistentStore = (Get-TCForwarding $adapter.InterfaceIndex 'PersistentStore') }
            if ($before.ActiveStore -cne 'Enabled' -or $before.PersistentStore -cne 'Enabled') {
                $target = [pscustomobject]@{ InterfaceIndex = [int]$adapter.InterfaceIndex; InterfaceGuid = [string]$adapter.InterfaceGuid; InterfaceAlias = $adapter.InterfaceAlias }
                $step = Add-TCTransactionStep $transaction 'Forwarding' $target $before
                foreach ($store in @('PersistentStore','ActiveStore')) {
                    if ((Get-TCForwarding $adapter.InterfaceIndex $store) -cne 'Enabled') { Set-TCForwarding $adapter.InterfaceIndex $store 'Enabled' }
                }
                Complete-TCTransactionStep $transaction $step
            }
        }
        if (@(Get-NetNat -ErrorAction Stop).Count) { Stop-TC NatConflict '应用期间出现新的 NAT，停止部署。' }
        $step = Add-TCTransactionStep $transaction 'Nat' $plan.NatName 'Absent'
        $null = New-NetNat -Name $plan.NatName -InternalIPInterfaceAddressPrefix $plan.TunnelSubnet -ErrorAction Stop
        Complete-TCTransactionStep $transaction $step
        if (@(Get-TCFirewallState $plan 'PersistentStore').Count -or @(Get-TCFirewallState $plan 'ActiveStore').Count) { Stop-TC ObjectCollision '应用期间出现同名防火墙规则。' }
        $step = Add-TCTransactionStep $transaction 'Firewall' $plan.FirewallRuleName 'Absent'
        $null = New-NetFirewallRule -PolicyStore PersistentStore -Name $plan.FirewallRuleName -DisplayName ('TradeChannel ' + $plan.TunnelName + ' UDP') -Group 'TradeChannel.Server' -Description (Get-TCFirewallDescription $plan) -Direction Inbound -Action Allow -Enabled True -Protocol UDP -LocalPort $plan.ListenPort -RemotePort Any -Profile Any -InterfaceAlias $plan.Uplink.InterfaceAlias -LocalAddress Any -RemoteAddress Any -ErrorAction Stop
        Complete-TCTransactionStep $transaction $step
        $manifest.Validation = Test-TCAppliedState $rootPath $plan $manifest $wg
        $manifest.Status = 'Applied'
        Write-TCJson $manifestPath $manifest
        $transaction.Journal.Status = 'Committed'; $transaction.Journal.FinishedAtUtc = [DateTime]::UtcNow.ToString('o'); Save-TCTransaction $transaction
        [pscustomobject]@{ SchemaVersion = 1; Status = 'Applied'; Friendly = '本机服务、专用 NAT、接口转发及 UDP 规则已验证；公网、安全组和握手未验证。'; ManifestPath = $manifestPath; Node = (Get-TCNode $plan $manifest); Validation = $manifest.Validation; RollbackPath = $transaction.Path }
    } catch {
        $code = Get-TCErrorCode $_
        if ($transaction) {
            $rolledBack = Undo-TCDeployment $transaction $rootPath $plan $serviceExe
            $status = 'NeedsRecovery'; if ($rolledBack) { $status = 'FailedRolledBack' }
            $transaction.Journal.Status = $status; $transaction.Journal.ErrorCode = $code; $transaction.Journal.FinishedAtUtc = [DateTime]::UtcNow.ToString('o'); Save-TCTransaction $transaction
            if ($manifest) { $manifest.Status = $status; Write-TCJson $manifestPath $manifest }
            Stop-TC $status ('部署未完成；原因 ' + $code + '。回滚记录：' + $transaction.Path)
        }
        throw
    } finally { $lock.Dispose() }
}

function New-TCClientRequest {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$OutputDirectory, [Parameter(Mandatory=$true)][string]$WgPath)
    $ErrorActionPreference = 'Stop'
    $directory = Get-TCFullPath $OutputDirectory
    $wg = Resolve-TCWgPath $WgPath
    if ((Test-Path -LiteralPath $directory) -and @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop).Count) { Stop-TC RequestExists '申请目录已有内容，拒绝覆盖或复用设备私钥。' }
    New-TCPrivateDirectory $directory
    $pair = New-TCKeyPair $wg
    $request = [pscustomobject]@{ SchemaVersion = 1; Kind = 'TradeChannel.ClientRequest'; RequestId = [guid]::NewGuid().ToString(); DeviceId = [guid]::NewGuid().ToString(); CreatedAtUtc = [DateTime]::UtcNow.ToString('o'); ClientPublicKey = $pair.Public; AddressFamilies = @('IPv4') }
    $keyPath = Join-Path $directory 'client.key'; $requestPath = Join-Path $directory 'public.request.json'
    Write-TCText $keyPath ($pair.Private + "`r`n") -NewOnly
    $localState = [pscustomobject]@{ SchemaVersion = 1; Kind = 'TradeChannel.ClientPrivateState'; RequestId = $request.RequestId; DeviceId = $request.DeviceId; ClientPublicKey = $pair.Public; PrivateKeyHash = (Get-TCHash $pair.Private) }
    Write-TCJson (Join-Path $directory 'client.state.json') $localState -NewOnly
    Write-TCJson $requestPath $request -NewOnly
    $pair = $null
    [pscustomobject]@{ SchemaVersion = 1; Status = 'RequestCreated'; Friendly = '已在本机生成独立设备密钥。仅把 public.request.json 交给服务器，保留 client.key 和 client.state.json。'; RequestId = $request.RequestId; DeviceId = $request.DeviceId; ClientPublicKey = $request.ClientPublicKey; RequestPath = $requestPath; KeyPath = $keyPath; RequestDirectory = $directory }
}

function Read-TCClientRequest {
    param([string]$Path)
    $request = Read-TCJson $Path
    if ($request.SchemaVersion -ne 1 -or $request.Kind -cne 'TradeChannel.ClientRequest' -or (@($request.AddressFamilies) -join ',') -cne 'IPv4') { Stop-TC InvalidRequest '设备申请 schema 或地址族不受支持。' }
    Assert-TCGuid $request.RequestId; Assert-TCGuid $request.DeviceId; Assert-TCKey $request.ClientPublicKey
    return $request
}

function Write-TCClientResponse {
    param([string]$Root, $Plan, $Manifest, $Peer)
    $dir = Join-Path (Join-Path (Join-Path $Root 'nodes') $Plan.NodeId) 'devices'
    New-TCPrivateDirectory $dir
    $deviceDir = Join-Path $dir $Peer.DeviceId
    New-TCPrivateDirectory $deviceDir
    $path = Join-Path $deviceDir 'client-response.json'
    $response = [pscustomobject][ordered]@{
        SchemaVersion = 1; Kind = 'TradeChannel.ClientResponse'; Status = 'Authorized'; RequestId = $Peer.RequestId; DeviceId = $Peer.DeviceId; NodeId = $Plan.NodeId; NodeName = $Plan.Name
        ClientPublicKey = $Peer.ClientPublicKey; ClientAddress = $Peer.ClientAddress; ServerPublicKey = $Manifest.ServerPublicKey; PublicEndpoint = $Plan.PublicEndpoint
        TunnelSubnet = $Plan.TunnelSubnet; ServerAddress = $Plan.ServerAddress; AllowedIPs = @('0.0.0.0/0'); PersistentKeepalive = 25; AddressFamilies = @('IPv4'); ConfigRevision = $Manifest.ConfigRevision
        Validation = [pscustomobject]@{ LocalAuthorization = 'Verified'; CloudFirewall = 'NotVerified'; ExternalConnectivity = 'NotTested'; Handshake = 'NotTested' }
    }
    Write-TCJson $path $response
    return $path
}

function Get-TCPrivateFromServerConfig {
    param([string]$Path, [string]$WgPath, $Manifest, $Plan)
    Assert-TCPrivatePath $Path
    $text = [IO.File]::ReadAllText($Path)
    $matches = [regex]::Matches($text, '(?m)^PrivateKey = ([A-Za-z0-9+/]{43}=)\r?$')
    if ($matches.Count -ne 1) { Stop-TC ConfigDrift '受管配置的身份字段不符合预期。' }
    $private = $matches[0].Groups[1].Value
    if ((Invoke-TCNative $WgPath @('pubkey') $private) -cne $Manifest.ServerPublicKey -or $text -cne (Get-TCServerConfigText $Plan $private @($Manifest.Peers))) { Stop-TC ConfigDrift '受管配置内容与授权记录不一致。' }
    return $private
}

function Add-TCServerDevice {
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')]
    param([string]$Root, [Parameter(Mandatory=$true)][string]$RequestPath, [Parameter(Mandatory=$true)][string]$ClientAddress)
    $ErrorActionPreference = 'Stop'
    $rootPath = Resolve-TCRoot $Root
    $envState = Get-TCEnvironment
    Assert-TCBaseEnvironment $envState
    $owner = Get-TCRootOwner $rootPath $envState
    $header = Read-TCJson (Join-Path $rootPath 'manifest.json') -Private
    Assert-TCGuid $header.PlanId
    $plan = Read-TCServerPlan $rootPath (Join-Path (Join-Path $rootPath 'plans') ($header.PlanId + '.json')) $owner
    $request = Read-TCClientRequest $RequestPath
    $address = Get-TCClientAddress $plan $ClientAddress
    $wg = Resolve-TCWgPath $envState.WireGuard.WgPath
    if ($WhatIfPreference) {
        $manifest = Read-TCManifest $rootPath $owner $plan
        $null = Test-TCAppliedState $rootPath $plan $manifest $wg
        return [pscustomobject]@{ SchemaVersion = 1; Status = 'WhatIf'; Friendly = '本产品节点只读检查完成；未授权设备。'; NodeId = $plan.NodeId; DeviceId = $request.DeviceId; ClientAddress = $address }
    }
    if (-not $PSCmdlet.ShouldProcess($plan.TunnelName, ('授权设备 ' + $request.DeviceId + ' ' + $address))) { return }
    $lock = Enter-TCServerLock $rootPath
    $transaction = $null; $before = $null; $candidate = $null; $private = $null; $committed = $false
    $manifestPath = Join-Path $rootPath 'manifest.json'
    try {
        $before = Read-TCManifest $rootPath $owner $plan
        $null = Test-TCAppliedState $rootPath $plan $before $wg
        if ($request.ClientPublicKey -ceq $before.ServerPublicKey) { Stop-TC InvalidRequest '设备公钥不能与服务器身份相同。' }
        $existing = @($before.Peers | Where-Object { $_.RequestId -ceq $request.RequestId -or $_.DeviceId -ceq $request.DeviceId -or $_.ClientPublicKey -ceq $request.ClientPublicKey -or $_.ClientAddress -ceq $address })
        if ($existing.Count) {
            if ($existing.Count -ne 1 -or $existing[0].RequestId -cne $request.RequestId -or $existing[0].DeviceId -cne $request.DeviceId -or $existing[0].ClientPublicKey -cne $request.ClientPublicKey -or $existing[0].ClientAddress -cne $address) { Stop-TC DeviceConflict '设备、申请、公钥或地址已授权给其他对象；不会补改既有 Peer。' }
            $responsePath = Write-TCClientResponse $rootPath $plan $before $existing[0]
            return [pscustomobject]@{ SchemaVersion = 1; Status = 'AlreadyAuthorized'; Friendly = '设备授权一致，未改动 Peer；公网握手尚未验证。'; NodeId = $plan.NodeId; DeviceId = $request.DeviceId; ClientAddress = $address; ResponsePath = $responsePath }
        }
        $private = Get-TCPrivateFromServerConfig $before.ConfigPath $wg $before $plan
        $transaction = New-TCTransaction $rootPath 'TradeChannel.DeviceTransaction' $plan
        Write-TCText (Join-Path $transaction.Directory 'server.before.conf') ([IO.File]::ReadAllText($before.ConfigPath)) -NewOnly
        $candidate = $before | ConvertTo-Json -Depth 30 | ConvertFrom-Json
        $peer = [pscustomobject]@{ RequestId = $request.RequestId; DeviceId = $request.DeviceId; ClientPublicKey = $request.ClientPublicKey; ClientAddress = $address; AuthorizedAtUtc = [DateTime]::UtcNow.ToString('o') }
        $candidate.Peers = @($candidate.Peers) + @($peer); $candidate.ConfigRevision = [int]$before.ConfigRevision + 1
        $candidate.TransactionId = $transaction.Journal.TransactionId
        $text = Get-TCServerConfigText $plan $private @($candidate.Peers)
        $candidate.ConfigHash = Get-TCHash $text
        $syncPath = Join-Path $transaction.Directory 'sync.conf'
        Write-TCText $syncPath (Get-TCServerConfigText $plan $private @($candidate.Peers) -SyncOnly) -NewOnly
        $null = Test-TCAppliedState $rootPath $plan $before $wg
        $pending = $before | ConvertTo-Json -Depth 30 | ConvertFrom-Json
        $pending.Status = 'AddingDevice'; $pending.TransactionId = $transaction.Journal.TransactionId
        Write-TCJson $manifestPath $pending
        $step = Add-TCTransactionStep $transaction 'Configuration' $before.ConfigPath $before.ConfigHash
        Write-TCText $before.ConfigPath $text
        Complete-TCTransactionStep $transaction $step
        $step = Add-TCTransactionStep $transaction 'PeerSync' $request.ClientPublicKey 'Absent'
        $null = Invoke-TCNative $wg @('syncconf', $plan.TunnelName, $syncPath)
        Complete-TCTransactionStep $transaction $step
        $candidate.Validation = Test-TCAppliedState $rootPath $plan $candidate $wg
        Write-TCJson $manifestPath $candidate
        $transaction.Journal.Status = 'Committed'; $transaction.Journal.FinishedAtUtc = [DateTime]::UtcNow.ToString('o'); Save-TCTransaction $transaction
        $committed = $true
        $responsePath = Write-TCClientResponse $rootPath $plan $candidate $peer
        [pscustomobject]@{ SchemaVersion = 1; Status = 'DeviceAuthorized'; Friendly = '设备已授权并同步到本产品节点；公网和实际握手未验证。'; NodeId = $plan.NodeId; DeviceId = $request.DeviceId; ClientAddress = $address; ResponsePath = $responsePath; ManifestPath = $manifestPath; Validation = $candidate.Validation; RollbackPath = $transaction.Path }
    } catch {
        $code = Get-TCErrorCode $_
        if ($committed) { Stop-TC ResponseExportFailed '设备已授权，但响应文件导出失败；用同一申请与地址重试即可补导出，不会重复授权。' }
        if ($transaction) {
            $reverted = $true
            try {
                Assert-TCOwnedService @(Get-TCService $plan.ServiceName) $plan $before.ConfigPath $envState.WireGuard.ServiceExecutable -RequireRunning
                $runtime = Get-TCWgRuntime $wg $plan
                $isOld = $false
                try { Assert-TCPeerRuntime $runtime $before $plan; $isOld = $true } catch { Assert-TCPeerRuntime $runtime $candidate $plan }
                if (-not $isOld) {
                    $restorePath = Join-Path $transaction.Directory 'restore.conf'
                    Write-TCText $restorePath (Get-TCServerConfigText $plan $private @($before.Peers) -SyncOnly)
                    $null = Invoke-TCNative $wg @('syncconf', $plan.TunnelName, $restorePath)
                }
                $currentHash = Get-TCFileHash $before.ConfigPath
                if ($currentHash -cne $before.ConfigHash) {
                    if ($currentHash -cne $candidate.ConfigHash) { Stop-TC RollbackOwnership '配置已被外部修改，不覆盖。' }
                    Write-TCText $before.ConfigPath ([IO.File]::ReadAllText((Join-Path $transaction.Directory 'server.before.conf')))
                }
                $null = Test-TCAppliedState $rootPath $plan $before $wg
                Write-TCJson $manifestPath $before
            } catch { $reverted = $false }
            $status = 'NeedsRecovery'; if ($reverted) { $status = 'FailedRolledBack' }
            foreach ($step in @($transaction.Journal.Steps)) { $step.Rollback = $(if ($reverted) { 'Reverted' } else { 'NeedsReview' }) }
            $transaction.Journal.Status = $status; $transaction.Journal.ErrorCode = $code; $transaction.Journal.FinishedAtUtc = [DateTime]::UtcNow.ToString('o'); Save-TCTransaction $transaction
            if (-not $reverted) { $before.Status = 'NeedsRecovery'; $before.TransactionId = $transaction.Journal.TransactionId; Write-TCJson $manifestPath $before }
            Stop-TC $status ('设备授权未完成；原因 ' + $code + '。回滚记录：' + $transaction.Path)
        }
        throw
    } finally {
        $private = $null
        if ($transaction) {
            foreach ($leaf in @('sync.conf','restore.conf')) {
                $temp = Join-Path $transaction.Directory $leaf
                if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
            }
        }
        $lock.Dispose()
    }
}

function Complete-TCClientConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$RequestDirectory, [Parameter(Mandatory=$true)][string]$ResponsePath, [Parameter(Mandatory=$true)][string]$Destination)
    $ErrorActionPreference = 'Stop'
    $directory = Get-TCFullPath $RequestDirectory
    Assert-TCPrivatePath $directory
    $request = Read-TCClientRequest (Join-Path $directory 'public.request.json')
    $state = Read-TCJson (Join-Path $directory 'client.state.json') -Private
    $keyPath = Join-Path $directory 'client.key'
    Assert-TCPrivatePath $keyPath
    $private = [IO.File]::ReadAllText($keyPath).Trim()
    Assert-TCKey $private
    if ($state.SchemaVersion -ne 1 -or $state.Kind -cne 'TradeChannel.ClientPrivateState' -or $state.RequestId -cne $request.RequestId -or $state.DeviceId -cne $request.DeviceId -or $state.ClientPublicKey -cne $request.ClientPublicKey -or $state.PrivateKeyHash -cne (Get-TCHash $private)) { Stop-TC RequestMismatch '本机申请、公钥和私钥状态不匹配。' }
    $response = Read-TCJson $ResponsePath
    if ($response.SchemaVersion -ne 1 -or $response.Kind -cne 'TradeChannel.ClientResponse' -or $response.Status -cne 'Authorized' -or $response.RequestId -cne $request.RequestId -or $response.DeviceId -cne $request.DeviceId -or $response.ClientPublicKey -cne $request.ClientPublicKey -or (@($response.AddressFamilies) -join ',') -cne 'IPv4') { Stop-TC ResponseMismatch '服务器响应与本机设备申请不匹配。' }
    Assert-TCGuid $response.NodeId
    Assert-TCKey $response.ServerPublicKey
    $endpoint = Get-TCEndpoint $response.PublicEndpoint
    $cidr = Get-TCCidr $response.TunnelSubnet -Dedicated
    $address = Get-TCClientAddress $response $response.ClientAddress
    if ($response.ServerPublicKey -ceq $request.ClientPublicKey -or $response.ServerAddress -cne ((ConvertFrom-TCIPv4Number ($cidr.Start + 1)) + '/' + $cidr.PrefixLength) -or (@($response.AllowedIPs) -join ',') -cne '0.0.0.0/0' -or $response.PersistentKeepalive -ne 25) { Stop-TC InvalidResponse '响应中的服务器身份、地址或客户端路由不符合 schema。' }
    $path = Get-TCFullPath $Destination
    if ([IO.Path]::GetExtension($path) -ine '.conf') { Stop-TC InvalidDestination 'Destination 必须是 .conf 文件路径。' }
    $text = (@('[Interface]', ('PrivateKey = ' + $private), ('Address = ' + $address), '', '[Peer]', ('PublicKey = ' + $response.ServerPublicKey), ('AllowedIPs = ' + (@($response.AllowedIPs) -join ', ')), ('Endpoint = ' + $endpoint.Value), 'PersistentKeepalive = 25', '') -join "`r`n")
    if (Test-Path -LiteralPath $path) {
        Assert-TCPrivatePath $path
        if ([IO.File]::ReadAllText($path) -cne $text) { Stop-TC DestinationExists '目标配置已存在且内容不同，不覆盖其他配置。' }
        return [pscustomobject]@{ SchemaVersion = 1; Status = 'AlreadyCompleted'; Friendly = '本机配置已存在且一致；尚未连接或验证握手。'; ConfigPath = $path; NodeId = $response.NodeId; DeviceId = $request.DeviceId; ExternalConnectivity = 'NotTested' }
    }
    # Never tighten ACL on a user-selected existing parent directory. Create an
    # empty protected file before putting any private key bytes in that file.
    $parent = [IO.Path]::GetDirectoryName($path)
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-TCPrivateDirectory $parent }
    $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $stream.Dispose()
    try { Protect-TCPath $path; [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($false))); Assert-TCPrivatePath $path }
    catch { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue; throw }
    finally { $private = $null; $text = $null }
    [pscustomobject]@{ SchemaVersion = 1; Status = 'ConfigCompleted'; Friendly = '已生成受限 WireGuard IPv4 客户端配置，可交给 nodes 导入；未启用通道，尚未验证公网或握手。'; ConfigPath = $path; NodeId = $response.NodeId; DeviceId = $request.DeviceId; ExternalConnectivity = 'NotTested' }
}

Export-ModuleMember -Function Get-TCServerInspection, New-TCServerPlan, Invoke-TCServerPlan, New-TCClientRequest, Add-TCServerDevice, Complete-TCClientConfig
