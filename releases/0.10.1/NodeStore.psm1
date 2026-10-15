#requires -Version 5.1
Set-StrictMode -Version 2

# Store operations never activate a node or touch deployment/runtime/network state.
# The private native runner is the dependency-injection seam for isolated tests.
$script:TCDefaultRoot = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'TradeChannel\Product'
$script:TCDefaultDomains = @('tradingview.com','tradingview-widget.com','tradingviewusercontent.com','tvc-cdn.com','tradovate.com','tradovateapi.com','ninjatrader.com')
# Resolved via the trade exit only. NinjaTrader looks these up through the Windows
# DNS service, so a per-program DNS rule cannot see them; routing stays per program.
$script:TCAuxDnsDomains = @('launchdarkly.com','statsigapi.net')
$script:TCDailyProbeUser = 'tradechannel-daily'
$script:TCPolicyVersion = 4
$script:TCJsonLimit = 4194304
$script:TCConfLimit = 131072
$script:TCUtf8 = New-Object Text.UTF8Encoding($true, $true)

function Stop-TCError {
    param([string]$Message)
    throw (New-Object InvalidOperationException('TradeChannel: ' + $Message))
}

function Stop-TCOperation {
    param($Record, [string]$Message)
    if ($Record.Exception.Message.StartsWith('TradeChannel: ', [StringComparison]::Ordinal)) {
        # Do not preserve an inner native/parser exception that could contain keys.
        throw (New-Object InvalidOperationException($Record.Exception.Message))
    }
    Stop-TCError $Message
}

function Get-TCFullPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { Stop-TCError '请提供有效的本地文件或目录路径。' }
    try { $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path) }
    catch { Stop-TCError '无法解析本地路径。' }
    if ($full -notmatch '^[A-Za-z]:\\' -or $full.Substring(2) -match '[:*?"<>|\x00-\x1f]') {
        Stop-TCError '只支持本地磁盘路径，不支持网络共享、设备路径或通配符。'
    }
    $full = [IO.Path]::GetFullPath($full)
    if ($full.Length -gt 3) { $full = $full.TrimEnd('\') }
    return $full
}

function Assert-TCNoReparse {
    param([string]$Path)
    $cursor = $Path
    while ($cursor) {
        $item = Get-Item -LiteralPath $cursor -Force -ErrorAction SilentlyContinue
        if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            Stop-TCError '存储或输出路径不能经过符号链接、目录联接或其他重解析点。'
        }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
}

function Set-TCPrivateAcl {
    param([string]$Path, [switch]$Directory)
    if ($Directory) { $acl = New-Object Security.AccessControl.DirectorySecurity }
    else { $acl = New-Object Security.AccessControl.FileSecurity }
    $acl.SetAccessRuleProtection($true, $false)
    $admins = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $acl.SetOwner($admins)
    foreach ($sidText in @('S-1-5-18','S-1-5-32-544')) {
        $sid = New-Object Security.Principal.SecurityIdentifier($sidText)
        if ($Directory) {
            $rule = New-Object Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        } else { $rule = New-Object Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'Allow') }
        $null = $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
}

function New-TCPrivateDirectory {
    param([string]$Path)
    Assert-TCNoReparse $Path
    if ([IO.File]::Exists($Path)) { Stop-TCError '预期的存储目录已被同名文件占用。' }
    if (-not [IO.Directory]::Exists($Path)) {
        # Apply the protected ACL when creating the directory, before writing secrets.
        $acl = New-Object Security.AccessControl.DirectorySecurity
        $acl.SetAccessRuleProtection($true, $false)
        $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
        foreach ($sidText in @('S-1-5-18','S-1-5-32-544')) {
            $sid = New-Object Security.Principal.SecurityIdentifier($sidText)
            $null = $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
        }
        if ($PSVersionTable.PSVersion.Major -le 5) { $null = [IO.Directory]::CreateDirectory($Path, $acl) }
        else {
            $null = [IO.Directory]::CreateDirectory($Path)
            Set-TCPrivateAcl -Path $Path -Directory
        }
    } else { Set-TCPrivateAcl -Path $Path -Directory }
}

function Open-TCLock {
    param([string]$Root)
    $path = Join-Path $Root '.store.lock'
    Assert-TCNoReparse $path
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        try { return [IO.File]::Open($path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
        catch [IO.IOException] {
            if ($timer.ElapsedMilliseconds -ge 10000) { Stop-TCError '节点库正被其他操作占用，请稍后重试。' }
            Start-Sleep -Milliseconds 50
        }
    } while ($true)
}

function Write-TCAtomicJson {
    param([string]$Path, $Value, [switch]$NewOnly, [switch]$NoBom)
    Assert-TCNoReparse $Path
    $directory = [IO.Path]::GetDirectoryName($Path)
    if (-not [IO.Directory]::Exists($directory)) { Stop-TCError '输出目录不存在，请先创建目标目录。' }
    $text = ConvertTo-Json -InputObject $Value -Depth 40
    $bytes = $script:TCUtf8.GetBytes($text)
    if ($bytes.Length -gt $script:TCJsonLimit) { Stop-TCError 'JSON 超过允许的 4 MiB 大小。' }
    $temp = Join-Path $directory ('.tc-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $stream = [IO.File]::Open($temp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            if (-not $NoBom) {
                $preamble = $script:TCUtf8.GetPreamble()
                $stream.Write($preamble, 0, $preamble.Length)
            }
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        } finally { $stream.Dispose() }
        if ($NewOnly -or -not [IO.File]::Exists($Path)) { [IO.File]::Move($temp, $Path) }
        else { [IO.File]::Replace($temp, $Path, [NullString]::Value) }
    } finally {
        if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
        [Array]::Clear($bytes, 0, $bytes.Length)
    }
}

function Read-TCBoundedText {
    param([string]$Path, [int]$Limit = 4194304)
    if (-not [IO.File]::Exists($Path)) { Stop-TCError '指定的输入文件不存在。' }
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try {
        if ($stream.Length -gt $Limit) { Stop-TCError '输入文件过大，已拒绝读取。' }
        $memory = New-Object IO.MemoryStream
        try {
            $buffer = New-Object byte[] 4096
            while (($count = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                if ($memory.Length + $count -gt $Limit) { Stop-TCError '输入文件过大，已拒绝读取。' }
                $memory.Write($buffer, 0, $count)
            }
            $data = $memory.ToArray()
            try { return $script:TCUtf8.GetString($data).TrimStart([char]0xfeff) }
            finally { [Array]::Clear($data, 0, $data.Length); [Array]::Clear($buffer, 0, $buffer.Length) }
        } finally { $memory.Dispose() }
    } finally { $stream.Dispose() }
}

function Read-TCJson {
    param([string]$Path)
    $raw = Read-TCBoundedText $Path
    try { $value = ConvertFrom-Json -InputObject $raw -ErrorAction Stop }
    catch { Stop-TCError 'JSON 文件损坏或格式无效；内容未输出。' }
    finally { $raw = $null }
    if ($null -eq $value -or $value -isnot [pscustomobject]) { Stop-TCError 'JSON 顶层必须是对象。' }
    return $value
}

function Assert-TCFields {
    param($Value, [string[]]$Required, [string[]]$Optional = @())
    if ($null -eq $Value -or $Value -isnot [pscustomobject]) { Stop-TCError '数据记录必须是对象。' }
    $names = @($Value.PSObject.Properties | ForEach-Object { $_.Name })
    foreach ($field in $Required) {
        if ($names -cnotcontains $field) { Stop-TCError '数据记录缺少必需字段。' }
    }
    foreach ($field in $names) {
        if (($Required + $Optional) -cnotcontains $field) { Stop-TCError '数据记录包含不支持的字段；请使用设置迁移包，勿导入身份或运行状态。' }
    }
}

function ConvertTo-TCName {
    param($Value)
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value) -or $Value.Length -gt 120 -or $Value -match '[\x00-\x1f\x7f]') {
        Stop-TCError '节点名称须为 1–120 个字符，且不能包含控制字符。'
    }
    return $Value.Trim()
}

function ConvertTo-TCDomain {
    param($Value)
    if ($Value -isnot [string] -or $Value.Length -gt 253 -or $Value -notmatch '^[a-zA-Z0-9.-]+$') { Stop-TCError '域名格式无效；请使用 ASCII 或 punycode 域名。' }
    $domain = $Value.ToLowerInvariant().TrimEnd('.')
    if ($domain.Length -eq 0 -or $domain -notmatch '\.') { Stop-TCError '需要完整域名。' }
    foreach ($label in $domain.Split('.')) {
        if ($label.Length -gt 63 -or $label -notmatch '^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$') { Stop-TCError '域名格式无效。' }
    }
    $ip = $null
    if ([Net.IPAddress]::TryParse($domain, [ref]$ip) -or $domain -match '^[0-9.]+$') { Stop-TCError '此处需要域名，不能使用 IP 地址。' }
    return $domain
}

function ConvertTo-TCDomains {
    param($Value)
    if ($Value -isnot [array] -or $Value.Count -gt 256) { Stop-TCError '域名列表必须为数组，最多 256 项。' }
    $seen = @{}
    foreach ($item in $Value) {
        $domain = ConvertTo-TCDomain $item
        if (-not $seen.ContainsKey($domain)) { $seen[$domain] = $true; $domain }
    }
}

function ConvertTo-TCPort {
    param($Value)
    $number = 0
    if ([string]$Value -notmatch '^\d{1,5}$' -or -not [int]::TryParse([string]$Value, [ref]$number) -or $number -lt 1 -or $number -gt 65535) {
        Stop-TCError '端口必须是 1–65535 的整数。'
    }
    return $number
}

function ConvertTo-TCEndpoint {
    param($Value)
    if ($Value -isnot [string] -or $Value.Length -gt 300) { Stop-TCError '节点端点格式无效。' }
    $endpointHost = $null
    $portText = $null
    $ip = $null
    if ($Value -match '^\[([0-9a-fA-F:]+)\]:(\d{1,5})$') {
        $endpointHost = $matches[1]; $portText = $matches[2]
        if (-not [Net.IPAddress]::TryParse($endpointHost, [ref]$ip) -or $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetworkV6) { Stop-TCError 'IPv6 端点无效。' }
        $endpointHost = $ip.ToString()
    } elseif ($Value -match '^([^:\s/\\@?#]+):(\d{1,5})$') {
        $endpointHost = $matches[1]; $portText = $matches[2]
        if ([Net.IPAddress]::TryParse($endpointHost, [ref]$ip)) {
            if ($ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or $endpointHost -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { Stop-TCError 'IPv4 端点必须使用完整点分十进制格式。' }
            $endpointHost = $ip.ToString()
        } else { $endpointHost = ConvertTo-TCDomain $endpointHost }
    } else { Stop-TCError '端点须为 IPv4:端口、域名:端口或 [IPv6]:端口。' }
    $port = ConvertTo-TCPort $portText
    $formatted = $endpointHost + ':' + $port
    if ($ip -and $ip.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetworkV6) { $formatted = '[' + $endpointHost + ']:' + $port }
    return [pscustomobject]@{ text = $formatted; address = $endpointHost; port = $port; ip = $ip }
}

function ConvertTo-TCId {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { Stop-TCError '节点 ID 必须是有效 GUID。' }
    if ($Value -like 'node:*') { $Value = $Value.Substring(5) }
    $parsed = [Guid]::Empty
    if (-not [Guid]::TryParseExact($Value, 'D', [ref]$parsed) -or $parsed -eq [Guid]::Empty) { Stop-TCError '节点 ID 必须是有效 GUID。' }
    return $parsed.ToString('D')
}

function ConvertTo-TCNode {
    param($Node)
    return [pscustomobject][ordered]@{
        id = [string]$Node.id; name = [string]$Node.name; kind = [string]$Node.kind
        endpoint = [string]$Node.endpoint; manifestPath = $Node.manifestPath
        registeredAt = [string]$Node.registeredAt; status = [string]$Node.status
    }
}

function Read-TCIndex {
    param([string]$Root)
    $path = Join-Path $Root 'index.json'
    Assert-TCNoReparse $path
    $index = Read-TCJson $path
    Assert-TCFields $index @('schemaVersion','nodes','tradeDomains') @('providerReferences')
    if ($index.schemaVersion -isnot [int] -or $index.schemaVersion -ne 1) { Stop-TCError '不支持此节点库版本。' }
    if ($index.nodes -isnot [array] -or $index.nodes.Count -gt 1000) { Stop-TCError '节点列表格式无效或超过 1000 个节点。' }
    $index.tradeDomains = @(ConvertTo-TCDomains $index.tradeDomains)
    if ($index.PSObject.Properties['providerReferences']) { $index.providerReferences = @(ConvertTo-TCProviderReferences $index.providerReferences) }
    $ids = @{}
    foreach ($node in $index.nodes) {
        Assert-TCFields $node @('id','name','kind','endpoint','manifestPath','registeredAt','status')
        $id = ConvertTo-TCId $node.id
        if ($ids.ContainsKey($id)) { Stop-TCError '节点库包含重复 ID。' }
        $ids[$id] = $true
        $node.name = ConvertTo-TCName $node.name
        $node.endpoint = (ConvertTo-TCEndpoint $node.endpoint).text
        if ($node.kind -cnotin @('wireguard','existing') -or $node.status -cnotin @('CandidateOnly','Registered','PendingAuthorization')) { Stop-TCError '节点类型或状态无效。' }
        $date = [DateTimeOffset]::MinValue
        if ($node.registeredAt -isnot [string] -or -not [DateTimeOffset]::TryParse($node.registeredAt, [ref]$date)) { Stop-TCError '节点登记时间无效。' }
        if ($node.status -eq 'PendingAuthorization') {
            if ($null -ne $node.manifestPath) { Stop-TCError '待授权节点不能携带可激活的 manifest。' }
        } elseif ($node.manifestPath -isnot [string] -or -not [IO.Path]::IsPathRooted($node.manifestPath)) { Stop-TCError '节点 manifest 路径无效。' }
    }
    return $index
}

function Initialize-TCStore {
    [CmdletBinding()]
    param([string]$Root = $script:TCDefaultRoot)
    $ErrorActionPreference = 'Stop'
    $lock = $null
    try {
        $full = Get-TCFullPath $Root
        Assert-TCNoReparse $full
        if ($full.Length -le 3) { Stop-TCError '节点库必须使用独立子目录。' }
        $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) -and [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ne 'S-1-5-18') { Stop-TCError '节点库需要管理员权限，以设置仅 SYSTEM 和 Administrators 可访问的 ACL。' }
        if ([IO.Directory]::Exists($full)) {
            foreach ($item in @(Get-ChildItem -LiteralPath $full -Force)) {
                if ($item.Name -notin @('index.json','providers.json','nodes','.staging','.store.lock','jobs') -and $item.Name -notmatch '^\.tc-[a-f0-9]{32}\.tmp$') { Stop-TCError '所选目录包含其他文件，请为节点库使用独立目录。' }
            }
            if ([IO.File]::Exists((Join-Path $full 'index.json'))) { $null = Read-TCIndex $full }
            $null = Read-TCStoredProviders $full
        }
        New-TCPrivateDirectory $full
        $lock = Open-TCLock $full
        $null = Read-TCStoredProviders $full
        foreach ($child in @('nodes','.staging')) { New-TCPrivateDirectory (Join-Path $full $child) }
        $indexPath = Join-Path $full 'index.json'
        if (-not [IO.File]::Exists($indexPath)) {
            Write-TCAtomicJson $indexPath ([ordered]@{schemaVersion = 1; nodes = @(); tradeDomains = @($script:TCDefaultDomains)}) -NewOnly
        }
        Set-TCPrivateAcl $indexPath
        $providerPath = Join-Path $full 'providers.json'
        if ([IO.File]::Exists($providerPath)) { Set-TCPrivateAcl $providerPath }
        $index = Read-TCIndex $full
        return [pscustomobject]@{ root = $full; indexPath = $indexPath; schemaVersion = 1; nodeCount = $index.nodes.Count }
    } catch { Stop-TCOperation $_ '无法初始化节点库，请检查管理员权限、磁盘空间和目录 ACL。' }
    finally { if ($lock) { $lock.Dispose() } }
}

function Get-TCNodes {
    [CmdletBinding()]
    param([string]$Root = $script:TCDefaultRoot)
    $ErrorActionPreference = 'Stop'
    try {
        $full = Get-TCFullPath $Root
        Assert-TCNoReparse $full
        if (-not [IO.File]::Exists((Join-Path $full 'index.json'))) { $null = Initialize-TCStore -Root $full }
        $index = Read-TCIndex $full
        foreach ($node in $index.nodes) { ConvertTo-TCNode $node }
    } catch { Stop-TCOperation $_ '无法读取节点库；现有索引未被重置。' }
}

function Register-TCExisting {
    [CmdletBinding()]
    param([string]$Root = $script:TCDefaultRoot, [Parameter(Mandatory=$true)][string]$ManifestPath, [Parameter(Mandatory=$true)][string]$Name)
    $ErrorActionPreference = 'Stop'
    $lock = $null
    try {
        $nodeName = ConvertTo-TCName $Name
        $manifestFull = Get-TCFullPath $ManifestPath
        $manifest = Read-TCJson $manifestFull
        foreach ($field in @('SchemaVersion','CandidatePath','EnginePath','ServerEndpoint')) {
            if (-not $manifest.PSObject.Properties[$field]) { Stop-TCError '现有 manifest 缺少配置、引擎或端点字段。' }
        }
        if ($manifest.SchemaVersion -ne 1) { Stop-TCError '不支持此 manifest 版本。' }
        $endpoint = (ConvertTo-TCEndpoint $manifest.ServerEndpoint).text
        foreach ($field in @('CandidatePath','EnginePath')) {
            if ($manifest.$field -isnot [string] -or -not [IO.Path]::IsPathRooted($manifest.$field) -or -not [IO.File]::Exists($manifest.$field)) { Stop-TCError '现有 manifest 指向的配置或引擎不存在；未接管。' }
        }
        $store = Initialize-TCStore -Root $Root
        $lock = Open-TCLock $store.root
        $index = Read-TCIndex $store.root
        $node = @($index.nodes | Where-Object { $_.manifestPath -and $_.manifestPath.Equals($manifestFull, [StringComparison]::OrdinalIgnoreCase) })
        if ($node.Count) {
            $node = $node[0]
            $node.name = $nodeName
        } else {
            if ($index.nodes.Count -ge 1000) { Stop-TCError '节点库最多支持 1000 个节点。' }
            $node = [pscustomobject][ordered]@{id = [Guid]::NewGuid().ToString('D'); name = $nodeName; kind = 'existing'; endpoint = $endpoint; manifestPath = $manifestFull; registeredAt = [DateTimeOffset]::UtcNow.ToString('o'); status = 'Registered'}
            $index.nodes = @($index.nodes) + @($node)
        }
        Write-TCAtomicJson $store.indexPath $index
        return ConvertTo-TCNode $node
    } catch { Stop-TCOperation $_ '接管现有 manifest 失败；源配置未被修改。' }
    finally { if ($lock) { $lock.Dispose() } }
}

function ConvertTo-TCNativeArgument {
    param([string]$Value)
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Invoke-TCProcess {
    param([string]$FilePath, [string[]]$ArgumentList, [AllowNull()][string]$InputText, [int]$TimeoutMilliseconds = 30000)
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $FilePath
    $info.Arguments = (@($ArgumentList | ForEach-Object { ConvertTo-TCNativeArgument $_ }) -join ' ')
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    $savedEncoding = [Console]::InputEncoding
    $inputBytes = $null
    try {
        [Console]::InputEncoding = [Text.Encoding]::ASCII
        $null = $process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if ($InputText) {
            $inputBytes = [Text.Encoding]::ASCII.GetBytes($InputText)
            $process.StandardInput.BaseStream.Write($inputBytes, 0, $inputBytes.Length)
        }
        $process.StandardInput.BaseStream.Close()
        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            $process.Kill(); $null = $process.WaitForExit(3000)
            Stop-TCError '本地校验程序超时，节点未入库。'
        }
        return [pscustomobject]@{ ExitCode = $process.ExitCode; StandardOutput = $stdout.Result; StandardError = $stderr.Result }
    } finally {
        if ($inputBytes) { [Array]::Clear($inputBytes, 0, $inputBytes.Length) }
        $process.Dispose(); [Console]::InputEncoding = $savedEncoding
    }
}
$script:TCNativeRunner = ${function:Invoke-TCProcess}

function Invoke-TCNative {
    param([string]$FilePath, [string[]]$ArgumentList, [AllowNull()][string]$InputText)
    $results = @(& $script:TCNativeRunner -FilePath $FilePath -ArgumentList $ArgumentList -InputText $InputText -TimeoutMilliseconds 30000 3>$null 4>$null 5>$null 6>$null)
    if ($results.Count -ne 1 -or -not $results[0].PSObject.Properties['ExitCode']) { Stop-TCError '本地校验程序返回了无效结果。' }
    return $results[0]
}

function Assert-TCKey {
    param([string]$Value)
    $bytes = $null
    try {
        if ($Value.Length -ne 44) { Stop-TCError 'WireGuard 密钥格式无效，内容未输出。' }
        try { $bytes = [Convert]::FromBase64String($Value) } catch { Stop-TCError 'WireGuard 密钥格式无效，内容未输出。' }
        if ($bytes.Length -ne 32 -or [Convert]::ToBase64String($bytes) -cne $Value -or @($bytes | Where-Object { $_ -ne 0 }).Count -eq 0) { Stop-TCError 'WireGuard 密钥必须编码 32 个有效字节，内容未输出。' }
    } finally { if ($bytes) { [Array]::Clear($bytes, 0, $bytes.Length) } }
}

function Read-TCWireGuardText {
    param([string]$Path)
    $extension = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($extension -eq '.conf') { return Read-TCBoundedText -Path $Path -Limit $script:TCConfLimit }
    if ($extension -ne '.zip') { Stop-TCError '请选择 WireGuard .conf 或 .zip 文件。' }
    if (-not [IO.File]::Exists($Path) -or (Get-Item -LiteralPath $Path).Length -gt 8388608) { Stop-TCError 'ZIP 不存在或超过 8 MiB。' }
    Add-Type -AssemblyName System.IO.Compression,System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        if ($archive.Entries.Count -eq 0 -or $archive.Entries.Count -gt 32) { Stop-TCError 'ZIP 必须包含配置，且不能超过 32 个条目。' }
        $names = @{}; $configs = @(); $total = [long]0
        foreach ($entry in $archive.Entries) {
            $entryName = $entry.FullName.Replace('\','/')
            if ($entryName.StartsWith('/') -or $entryName -match '[:\x00-\x1f<>"|?*]' -or $entryName.Length -gt 240) { Stop-TCError 'ZIP 包含不安全的路径，已拒绝导入。' }
            $parts = $entryName.TrimEnd('/').Split('/')
            foreach ($part in $parts) {
                if ($part -in @('','..','.') -or $part -match '[. ]$' -or $part -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') { Stop-TCError 'ZIP 包含路径穿越或无效文件名，已拒绝导入。' }
            }
            if ($names.ContainsKey($entryName)) { Stop-TCError 'ZIP 包含重复文件名。' }
            $names[$entryName] = $true
            $unixType = (($entry.ExternalAttributes -shr 16) -band 0xf000)
            if ($unixType -eq 0xa000 -or ($entry.ExternalAttributes -band 0x400)) { Stop-TCError 'ZIP 不允许包含链接。' }
            $total += $entry.Length
            if ($entry.Length -gt $script:TCConfLimit -or $total -gt 1048576) { Stop-TCError 'ZIP 解压大小超限，已拒绝导入。' }
            if ([IO.Path]::GetExtension($entryName) -ieq '.conf') { $configs += $entry }
        }
        if ($configs.Count -ne 1) { Stop-TCError 'ZIP 必须恰好包含一个 .conf；多节点请分别导入。' }
        # Read only; no archive entry is ever extracted to the filesystem.
        $stream = $configs[0].Open()
        $memory = New-Object IO.MemoryStream
        $data = $null
        try {
            $buffer = New-Object byte[] 4096
            while (($count = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                if ($memory.Length + $count -gt $script:TCConfLimit) { Stop-TCError 'ZIP 配置实际大小超限。' }
                $memory.Write($buffer, 0, $count)
            }
            $data = $memory.ToArray()
            return $script:TCUtf8.GetString($data).TrimStart([char]0xfeff)
        } finally {
            if ($data) { [Array]::Clear($data, 0, $data.Length) }
            if ($buffer) { [Array]::Clear($buffer, 0, $buffer.Length) }
            $memory.Dispose(); $stream.Dispose()
        }
    } finally { $archive.Dispose() }
}

function ConvertFrom-TCWireGuard {
    param([string]$Text)
    $interface = @{}; $peer = @{}; $section = ''; $interfaces = 0; $peers = 0
    foreach ($originalLine in ($Text -split '\r?\n')) {
        $line = ($originalLine -split '#', 2)[0].Trim()
        if (-not $line) { continue }
        if ($line -ieq '[Interface]') { $section = 'Interface'; $interfaces++; continue }
        if ($line -ieq '[Peer]') { $section = 'Peer'; $peers++; if ($peers -gt 1) { Stop-TCError '仅支持单 Peer 客户端配置；请为每个节点单独导出。' }; continue }
        if ($line.StartsWith('[') -or $line -notmatch '^([^=]+)=(.*)$') { Stop-TCError 'WireGuard 语法不受支持；原文未输出。' }
        $field = $matches[1].Trim(); $value = $matches[2].Trim()
        if ($field -in @('PreUp','PostUp','PreDown','PostDown','Table','SaveConfig','FwMark')) { Stop-TCError '不支持钩子、自定义路由表或持久化脚本；请提供纯客户端配置。' }
        if ($section -eq 'Interface') { $table = $interface; $allowed = @('PrivateKey','Address','DNS','MTU','ListenPort') }
        elseif ($section -eq 'Peer') { $table = $peer; $allowed = @('PublicKey','PresharedKey','Endpoint','AllowedIPs','PersistentKeepalive') }
        else { Stop-TCError 'WireGuard 设置必须位于 Interface 或 Peer 段内。' }
        if ($field -notin $allowed -or -not $value) { Stop-TCError 'WireGuard 包含未知字段或空值；内容未输出。' }
        if ($table.ContainsKey($field)) {
            if ($field -in @('Address','AllowedIPs','DNS')) { $table[$field] += ',' + $value }
            else { Stop-TCError 'WireGuard 包含重复设置；内容未输出。' }
        } else { $table[$field] = $value }
    }
    if ($interfaces -ne 1 -or $peers -ne 1) { Stop-TCError '需要且仅支持一个 Interface 和一个 Peer。' }
    foreach ($field in @('PrivateKey','Address')) { if (-not $interface.ContainsKey($field)) { Stop-TCError 'Interface 缺少 PrivateKey 或 Address。' } }
    foreach ($field in @('PublicKey','Endpoint','AllowedIPs')) { if (-not $peer.ContainsKey($field)) { Stop-TCError 'Peer 缺少 PublicKey、Endpoint 或 AllowedIPs。' } }
    Assert-TCKey $interface.PrivateKey
    Assert-TCKey $peer.PublicKey
    if ($peer.ContainsKey('PresharedKey')) { Assert-TCKey $peer.PresharedKey }
    $endpoint = ConvertTo-TCEndpoint $peer.Endpoint
    $clientAddress = $null
    if ($interface.Address -notmatch '^(\d{1,3}(?:\.\d{1,3}){3})/(\d{1,2})$') { Stop-TCError '目前仅支持单个 IPv4 隧道地址。' }
    $clientIPv4 = $matches[1]; $prefix = [int]$matches[2]
    if (-not [Net.IPAddress]::TryParse($clientIPv4, [ref]$clientAddress) -or $clientAddress.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or $prefix -gt 32) { Stop-TCError '客户端 IPv4 地址或前缀无效。' }
    $allowedIPs = @($peer.AllowedIPs -split ',' | ForEach-Object { $_.Trim() })
    foreach ($cidr in $allowedIPs) {
        if ($cidr -notmatch '^(.+)/(\d{1,3})$') { Stop-TCError 'AllowedIPs 必须使用有效 CIDR。' }
        $addressText = $matches[1]; $bits = [int]$matches[2]; $ip = $null
        if (-not [Net.IPAddress]::TryParse($addressText, [ref]$ip)) { Stop-TCError 'AllowedIPs 包含无效地址。' }
        $maxBits = if ($ip.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork) { 32 } else { 128 }
        if ($bits -gt $maxBits) { Stop-TCError 'AllowedIPs 前缀无效。' }
    }
    if ($allowedIPs -notcontains '0.0.0.0/0') { Stop-TCError '需要包含 0.0.0.0/0 的客户端授权；不会擅自扩大受限 Peer 的范围。' }
    if ($interface.ContainsKey('DNS')) {
        foreach ($dns in ($interface.DNS -split ',')) {
            $ip = $null
            if (-not [Net.IPAddress]::TryParse($dns.Trim(), [ref]$ip)) { $null = ConvertTo-TCDomain $dns.Trim() }
        }
    }
    $mtu = 1408; $keepAlive = 25; $listenPort = 0
    if ($interface.ContainsKey('MTU')) {
        if (-not [int]::TryParse($interface.MTU, [ref]$mtu)) { Stop-TCError 'MTU 必须为整数。' }
    }
    if ($mtu -lt 1280 -or $mtu -gt 1420) { Stop-TCError '当前双栈本地 TUN 要求 MTU 在 1280–1420 之间。' }
    if ($peer.ContainsKey('PersistentKeepalive')) {
        if (-not [int]::TryParse($peer.PersistentKeepalive, [ref]$keepAlive)) { Stop-TCError 'PersistentKeepalive 必须为整数。' }
    }
    if ($keepAlive -lt 0 -or $keepAlive -gt 65535) { Stop-TCError 'PersistentKeepalive 必须在 0–65535 之间。' }
    if ($interface.ContainsKey('ListenPort')) {
        if ($interface.ListenPort -eq '0') { $listenPort = 0 } else { $listenPort = ConvertTo-TCPort $interface.ListenPort }
    }
    return [pscustomobject]@{ interface = $interface; peer = $peer; endpoint = $endpoint; clientIPv4 = $clientAddress.ToString(); mtu = $mtu; keepAlive = $keepAlive; listenPort = $listenPort }
}

function Resolve-TCPrograms {
    param([string[]]$Paths)
    if ($null -eq $Paths) { return }
    if ($Paths.Count -gt 64) { Stop-TCError '应用程序列表不能超过 64 项。' }
    $seen = @{}
    foreach ($path in $Paths) {
        if (-not [IO.Path]::IsPathRooted($path)) { Stop-TCError '应用程序必须使用绝对路径。' }
        $full = Get-TCFullPath $path
        if ([IO.Path]::GetExtension($full) -ine '.exe' -or -not [IO.File]::Exists($full)) { Stop-TCError '应用程序必须是已存在的 .exe 文件。' }
        if (-not $seen.ContainsKey($full)) { $seen[$full] = $true; $full }
    }
}

function ConvertTo-TCRe2Literal {
    param([string]$Text)
    # sing-box uses Go RE2: escape only its metacharacters (not spaces or CJK).
    $builder = New-Object Text.StringBuilder
    foreach ($ch in $Text.ToCharArray()) {
        if ('\.+*?()|[]{}^$'.IndexOf($ch) -ge 0) { $null = $builder.Append('\') }
        $null = $builder.Append($ch)
    }
    return $builder.ToString()
}

function Get-TCProviderRoot {
    param([string[]]$ProviderPrograms, [string[]]$TradePrograms)
    # The provider's own install folder: it must be the folder of one provider
    # program (never a shared parent such as ...\Programs) and hold no trade program.
    $programs = @($ProviderPrograms | Where-Object { $_ })
    if ($programs.Count -eq 0) { return $null }
    $dirs = @(foreach ($program in $programs) { [IO.Path]::GetDirectoryName($program) })
    $common = $dirs[0]
    foreach ($dir in $dirs) {
        while ($common -and -not ($dir.Equals($common, [StringComparison]::OrdinalIgnoreCase) -or $dir.StartsWith($common + '\', [StringComparison]::OrdinalIgnoreCase))) { $common = [IO.Path]::GetDirectoryName($common) }
    }
    if (-not $common -or @($common.TrimEnd('\').Split('\')).Count -lt 3) { return $null }
    if (-not @($dirs | Where-Object { $_.Equals($common, [StringComparison]::OrdinalIgnoreCase) }).Count) { return $null }
    foreach ($trade in @($TradePrograms | Where-Object { $_ })) {
        if ($trade.StartsWith($common + '\', [StringComparison]::OrdinalIgnoreCase)) { return $null }
    }
    return $common.TrimEnd('\')
}

function Get-TCProperty {
    param($Value, [string]$Name, $Default = $null)
    if ($Value -is [Collections.IDictionary]) {
        if ($Value.Contains($Name)) { return $Value[$Name] }
    } elseif ($null -ne $Value -and $Value.PSObject.Properties[$Name]) { return $Value.$Name }
    return $Default
}

function Test-TCPathWithin {
    param([string]$Path, [string]$Directory)
    return $Path.StartsWith($Directory.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Test-TCSamePath {
    param($Left,$Right)
    if(-not $Left -or -not $Right){return $false}
    try{return [IO.Path]::GetFullPath([string]$Left).Equals([IO.Path]::GetFullPath([string]$Right),[StringComparison]::OrdinalIgnoreCase)}catch{return $false}
}

function Resolve-TCProviderDirectory {
    param($Path, [switch]$AllowMissing)
    if ($Path -isnot [string] -or $Path -notmatch '^[A-Za-z]:[\\/]' -or $Path -match '(?:[ .]|~\d+)[\\/]|[ .]$') { Stop-TCError '服务商必须使用明确的本地绝对安装目录。' }
    $full = Get-TCFullPath $Path
    Assert-TCNoReparse $full
    if (@($full.Split('\')).Count -lt 3 -or $full -match '(?i)(^|\\)(temp|tmp)(\\|$)') { Stop-TCError '服务商不能使用磁盘根目录、共享上级目录或临时目录。' }
    $shared = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:CommonProgramFiles, ${env:CommonProgramFiles(x86)}, $env:ProgramData, $env:USERPROFILE, $env:PUBLIC, $env:APPDATA, $env:LOCALAPPDATA)
    foreach ($special in @('Desktop','MyDocuments','CommonDocuments','UserProfile','CommonApplicationData','LocalApplicationData','ApplicationData')) { $shared += [Environment]::GetFolderPath($special) }
    if ($env:USERPROFILE) { $shared += @(Join-Path $env:USERPROFILE 'Downloads'); $shared += @(Join-Path $env:USERPROFILE 'AppData') }
    if ($env:LOCALAPPDATA) { $shared += @(Join-Path $env:LOCALAPPDATA 'Programs') }
    if ($env:ProgramFiles) { $shared += @(Join-Path $env:ProgramFiles 'WindowsApps') }
    if ($env:APPDATA) { $shared += @((Join-Path $env:APPDATA 'npm'), (Join-Path $env:APPDATA 'npm\node_modules')) }
    foreach ($root in @($shared | Where-Object { $_ })) {
        $root = (Get-TCFullPath $root).TrimEnd('\')
        if ($full.Equals($root, [StringComparison]::OrdinalIgnoreCase) -or (Test-TCPathWithin $root $full)) { Stop-TCError '请选择服务商自己的目录，不能使用共用的上级目录。' }
    }
    foreach ($root in @($env:WINDIR, $env:TEMP, $env:TMP, [IO.Path]::GetTempPath()) | Where-Object { $_ }) {
        $root = (Get-TCFullPath $root).TrimEnd('\')
        if ($full.Equals($root, [StringComparison]::OrdinalIgnoreCase) -or (Test-TCPathWithin $full $root)) { Stop-TCError '服务商不能使用系统或临时目录。' }
    }
    if ([IO.File]::Exists($full) -or (-not $AllowMissing -and -not [IO.Directory]::Exists($full))) { Stop-TCError '服务商安装目录不存在。' }
    return $full
}

# Both the registry and the compiler validate the same shape. Stored records may
# outlive an uninstalled client, but cannot acquire arbitrary fields or bypasses.
function ConvertTo-TCPolicyProviders {
    param(
        [AllowNull()][AllowEmptyCollection()][object[]]$Providers,
        [AllowNull()][AllowEmptyCollection()][string[]]$TradePrograms,
        [int[]]$ReservedPorts = @(17890,17891), [switch]$AllowMissingPrograms
    )
    if ($null -eq $Providers) { $Providers = @() }
    if ($Providers.Count -gt 4) { Stop-TCError '最多支持四个服务商。' }
    $trade = @(foreach ($program in @($TradePrograms | Where-Object { $_ })) { Get-TCFullPath $program })
    $slots = @{}; $ids = @{}; $usedPorts = @{}; $shaped = @()
    foreach ($port in @(@(17890,17891) + $ReservedPorts | Select-Object -Unique)) { $usedPorts[[int]$port] = 0 }
    foreach ($entry in $Providers) {
        if ($entry -is [Collections.IDictionary]) { $entry = [pscustomobject]$entry }
        Assert-TCFields $entry @('id','slot','kind','name','directory','extraDirectories','programPaths','dailyPort','httpPort','pacPort','bootstrapDomains') @('tradePort','addedAt','settingsDirectory')
        $slot = 0
        if (-not [int]::TryParse([string]$entry.slot, [ref]$slot) -or $slot -lt 1 -or $slot -gt 4) { Stop-TCError '服务商编号无效。' }
        if ($slots.ContainsKey($slot)) { Stop-TCError '两个服务商使用了相同编号。' }
        $slots[$slot] = $true
        $id = ConvertTo-TCId $entry.id
        if ($ids.ContainsKey($id)) { Stop-TCError '两个服务商使用了相同 ID。' }
        $ids[$id] = $true
        if ($entry.kind -isnot [string] -or $entry.kind.ToLowerInvariant() -notin @('batvpn','clash-verge','clashverge','clash','custom')) { Stop-TCError '服务商类型无效。' }
        $kind = $entry.kind.ToLowerInvariant()
        if ($kind -eq 'clash-verge') { $kind = 'clashverge' }
        $name = ConvertTo-TCName $entry.name
        if ($entry.PSObject.Properties['addedAt'] -and $null -ne $entry.addedAt -and $entry.addedAt -cne '') {
            $date = [DateTimeOffset]::MinValue
            if ($entry.addedAt -isnot [string] -or -not [DateTimeOffset]::TryParse($entry.addedAt, [ref]$date)) { Stop-TCError '服务商登记时间无效。' }
        }
        $port = ConvertTo-TCPort $entry.dailyPort
        $tradePort = Get-TCProperty $entry 'tradePort'
        $tradePort = if ($null -eq $tradePort) { $port } else { ConvertTo-TCPort $tradePort }
        $httpPort = if ($null -eq $entry.httpPort) { $null } else { ConvertTo-TCPort $entry.httpPort }
        $pacPort = if ($null -eq $entry.pacPort) { $null } else { ConvertTo-TCPort $entry.pacPort }
        foreach ($localPort in @(@($port,$tradePort,$httpPort,$pacPort) | Where-Object { $null -ne $_ } | Select-Object -Unique)) {
            if ($usedPorts.ContainsKey([int]$localPort)) { Stop-TCError '服务商端口与其他服务商、诊断入口或路由控制端口冲突。' }
            $usedPorts[[int]$localPort] = $slot
        }
        if ($entry.programPaths -isnot [array] -or $entry.programPaths.Count -gt 64 -or $entry.extraDirectories -isnot [array] -or $entry.extraDirectories.Count -gt 16) { Stop-TCError '服务商程序和附加目录必须是有界数组。' }
        $programs = @(@(foreach ($program in $entry.programPaths) {
            if ($program -isnot [string] -or $program -notmatch '^[A-Za-z]:[\\/]' -or $program -match '(?:[ .]|~\d+)[\\/]|[ .]$') { Stop-TCError '服务商程序路径无效。' }
            $full = Get-TCFullPath $program
            Assert-TCNoReparse $full
            if ([IO.Path]::GetExtension($full) -ine '.exe' -or (-not $AllowMissingPrograms -and -not [IO.File]::Exists($full))) { Stop-TCError '服务商程序必须是存在的 .exe 文件。' }
            if ([IO.Path]::GetFileName($full) -match '^(NinjaTrader|TradingView|codex|claude|ChatGPT|Antigravity|Mirasim|cc-switch|chrome|msedge|firefox|brave|opera|vivaldi|chromium|arc)\.exe$') { Stop-TCError '交易、AI 或浏览器程序不能登记为服务商核心。' }
            $full
        }) | Select-Object -Unique)
        if (-not $programs.Count) { Stop-TCError '服务商缺少可执行程序。' }
        $directories = @()
        foreach ($directory in @($entry.directory) + @($entry.extraDirectories)) {
            $full = Resolve-TCProviderDirectory $directory -AllowMissing:$AllowMissingPrograms
            foreach ($program in $trade) { if (Test-TCPathWithin $program $full) { Stop-TCError '交易程序不能位于服务商目录内。' } }
            foreach ($other in $shaped) {
                foreach ($otherDir in $other.Directories) {
                    if ($full -ieq $otherDir -or (Test-TCPathWithin $full $otherDir) -or (Test-TCPathWithin $otherDir $full)) { Stop-TCError '不同服务商的目录不能重叠。' }
                }
            }
            if ($directories -notcontains $full) { $directories += $full }
        }
        foreach ($program in $programs) {
            if (-not @($directories | Where-Object { Test-TCPathWithin $program $_ }).Count) { Stop-TCError '服务商程序必须位于登记的安装目录或附加目录内。' }
        }
        $settingsDirectory = Get-TCProperty $entry 'settingsDirectory'
        if ($null -ne $settingsDirectory) { $settingsDirectory = Resolve-TCProviderDirectory $settingsDirectory -AllowMissing:$AllowMissingPrograms }
        $tag = if ($slot -eq 1) { 'provider' } else { 'provider' + $slot }
        $shaped += [pscustomobject][ordered]@{
            Slot = $slot; Tag = $tag; TradeTag = $(if ($tradePort -eq $port) { $tag } else { $tag + '-trade' })
            Id = $id; Kind = $kind; Name = $name
            Port = $port; TradePort = $tradePort; Directory = $directories[0]; Directories = @($directories); Programs = @($programs)
            HttpPort = $httpPort; PacPort = $pacPort; SettingsDirectory = $settingsDirectory
            BootstrapDomains = @(ConvertTo-TCDomains $entry.bootstrapDomains)
        }
    }
    @($shaped | Sort-Object Slot)
}

# What the manifest records about each provider outbound, so the runtime can map
# a selector value back to a real client without consulting the registry.
function ConvertTo-TCManifestProviders {
    param([AllowNull()][AllowEmptyCollection()][object[]]$Providers)
    @(foreach ($provider in @($Providers | Where-Object { $_ })) {
        [ordered]@{
            Tag = [string]$provider.Tag; Slot = [int]$provider.Slot; Id = [string]$provider.Id; Kind = [string]$provider.Kind; Name = [string]$provider.Name
            TradeTag = [string]$provider.TradeTag; Port = [int]$provider.Port; TradePort = [int]$provider.TradePort; HttpPort = $provider.HttpPort; PacPort = $provider.PacPort
            Directory = [string]$provider.Directory; ExtraDirectories = @(@($provider.Directories) | Where-Object { $_ -and $_ -ne $provider.Directory })
            Programs = @($provider.Programs); BootstrapDomains = @($provider.BootstrapDomains); SettingsDirectory = $provider.SettingsDirectory
        }
    })
}

# The registry records a stored manifest describes, so an upgrade that is not
# given a new list keeps exactly the providers the running line already has.
function ConvertFrom-TCManifestProviders {
    param($Manifest)
    if (-not $Manifest) { return @() }
    if ($Manifest.PSObject.Properties['Providers']) {
        if ($Manifest.Providers -isnot [array]) { Stop-TCError 'manifest 服务商列表必须是数组。' }
        return @(foreach ($entry in @($Manifest.Providers)) {
            if ($null -eq $entry) { Stop-TCError 'manifest 包含空服务商记录。' }
            $expectedTag = if ($entry.Slot -eq 1) { 'provider' } else { 'provider' + [string]$entry.Slot }
            $tradePort = Get-TCProperty $entry 'TradePort'
            $expectedTradeTag = if ($null -eq $tradePort -or $tradePort -eq $entry.Port) { $expectedTag } else { $expectedTag + '-trade' }
            if ($entry.Tag -cne $expectedTag -or (Get-TCProperty $entry 'TradeTag' $expectedTradeTag) -cne $expectedTradeTag) { Stop-TCError 'manifest 服务商标签与编号或端口不一致。' }
            [pscustomobject][ordered]@{
                id = $(if ($entry.Id) { [string]$entry.Id } elseif ($entry.Slot -eq 1 -and $entry.Kind -eq 'batvpn') { '00000000-0000-0000-0000-000000000001' } else { '' }); slot = [int]$entry.Slot; kind = [string]$entry.Kind; name = [string]$entry.Name
                directory = [string]$entry.Directory; extraDirectories = @($entry.ExtraDirectories); programPaths = @($entry.Programs)
                dailyPort = [int]$entry.Port; tradePort = $tradePort; httpPort = $entry.HttpPort; pacPort = $entry.PacPort
                bootstrapDomains = @(Get-TCProperty $entry 'BootstrapDomains' @())
                settingsDirectory = (Get-TCProperty $entry 'SettingsDirectory')
            }
        })
    }
    $programs = @(Get-TCProperty $Manifest 'ProviderProgramPaths' @())
    $port = Get-TCProperty $Manifest 'ProviderSocksPort'
    if (-not $programs.Count -or -not $port) { return @() }
    $directory = [string](Get-TCProperty $Manifest 'ProviderDirectory')
    if (-not $directory) { $directory = Get-TCProviderRoot $programs @() }
    if (-not $directory) { Stop-TCError '无法确定旧 BatVPN 的独立安装目录，请重新识别服务商。' }
    @([pscustomobject][ordered]@{
        id = '00000000-0000-0000-0000-000000000001'; slot = 1; kind = 'batvpn'; name = 'BatVPN'; directory = $directory; extraDirectories = @(); programPaths = $programs
        dailyPort = $port; tradePort = (Get-TCProperty $Manifest 'ProviderTradePort'); httpPort = (Get-TCProperty $Manifest 'ProviderHttpPort'); pacPort = (Get-TCProperty $Manifest 'ProviderPacPort')
        bootstrapDomains = @(Get-TCProperty $Manifest 'ProviderBootstrapDomains' @())
    })
}

function ConvertFrom-TCLegacyProvider {
    param($Provider)
    if ($null -eq $Provider -or ($Provider -is [Collections.IDictionary] -and $Provider.Count -eq 0)) { return @() }
    $programs = @(Get-TCProperty $Provider 'ProgramPaths' @())
    $directory = Get-TCProperty $Provider 'Directory'
    if (-not $directory) { $directory = Get-TCProviderRoot $programs @() }
    @([pscustomobject][ordered]@{
        id = '00000000-0000-0000-0000-000000000001'; slot = 1; kind = 'batvpn'; name = 'BatVPN'
        directory = $directory; extraDirectories = @(Get-TCProperty $Provider 'BypassDirectories' @()); programPaths = $programs
        dailyPort = (Get-TCProperty $Provider 'SocksPort'); tradePort = (Get-TCProperty $Provider 'TradePort')
        httpPort = (Get-TCProperty $Provider 'HttpPort'); pacPort = (Get-TCProperty $Provider 'PacPort'); bootstrapDomains = @(Get-TCProperty $Provider 'BootstrapDomains' @())
    })
}

function Read-TCStoredProviders {
    param([string]$Root)
    $path = Join-Path $Root 'providers.json'
    Assert-TCNoReparse $path
    if ([IO.Directory]::Exists($path)) { Stop-TCError 'providers.json 必须是服务商档案文件。' }
    if (-not [IO.File]::Exists($path)) { return @() }
    $registry = Read-TCJson $path
    # Registry JSON has historically used both object and hashtable casing.
    if (@($registry.PSObject.Properties.Name) -ccontains 'Version') { Assert-TCFields $registry @('Version','Providers') }
    else { Assert-TCFields $registry @('version','providers') }
    if ($registry.version -isnot [int] -or $registry.version -ne 1 -or $registry.providers -isnot [array]) { Stop-TCError '服务商档案版本或列表格式无效；原文件未重置。' }
    return @(ConvertTo-TCPolicyProviders -Providers $registry.providers -AllowMissingPrograms)
}

function ConvertTo-TCProviderReferences {
    param($References)
    if ($References -isnot [array] -or $References.Count -gt 4) { Stop-TCError '迁移服务商参考必须是数组，最多四项。' }
    $seen = @{}
    foreach ($item in $References) {
        Assert-TCFields $item @('slot','kind','name','status')
        if ($item.slot -isnot [int] -or $item.slot -lt 1 -or $item.slot -gt 4 -or $seen.ContainsKey($item.slot)) { Stop-TCError '迁移服务商编号无效或重复。' }
        if ($item.kind -cnotin @('batvpn','clash-verge','clashverge','clash','custom') -or $item.status -cne 'PendingDetection') { Stop-TCError '迁移服务商只能是待重新识别的参考记录。' }
        $seen[$item.slot] = $true
        [pscustomobject][ordered]@{slot = [int]$item.slot; kind = [string]$item.kind; name = (ConvertTo-TCName $item.name); status = 'PendingDetection'}
    }
}

# AI assistant rule-sets live beside the store. The runtime fills them from the
# saved choice before every start; a missing file would stop the engine, so the
# policy step creates empty ones (an empty list routes nothing).
function Initialize-TCAgentRuleSetFiles {
    param([string]$StoreRoot)
    $directory = Join-Path ([IO.Path]::GetDirectoryName($StoreRoot)) 'agents'
    if (-not [IO.Directory]::Exists($directory)) { New-TCPrivateDirectory $directory }
    $paths = [pscustomobject]@{ Route = (Join-Path $directory 'agents-route.json'); Dns = (Join-Path $directory 'agents-dns.json') }
    foreach ($file in @($paths.Route, $paths.Dns)) {
        if (-not [IO.File]::Exists($file)) { Write-TCAtomicJson $file ([ordered]@{ version = 3; rules = @() }) -NewOnly -NoBom }
    }
    return $paths
}

function Assert-TCProviderAgentSeparation {
    param($Rules, [string[]]$Programs)
    foreach ($rule in @($Rules)) {
        foreach ($program in $Programs) {
            if (@(Get-TCProperty $rule 'process_path' @()) -contains $program) { Stop-TCError '服务商核心与 AI 程序重叠，请重新识别服务商。' }
            foreach ($pattern in @(Get-TCProperty $rule 'process_path_regex' @())) {
                try { $matchesAgent = [regex]::IsMatch($program, $pattern, [Text.RegularExpressions.RegexOptions]::None, [TimeSpan]::FromSeconds(1)) }
                catch { Stop-TCError '无法安全校验 AI 程序规则，未生成服务商绕行规则。' }
                if ($matchesAgent) { Stop-TCError '服务商核心与 AI 程序规则重叠，请重新识别服务商。' }
            }
        }
        if ($rule.PSObject.Properties['rules']) { Assert-TCProviderAgentSeparation $rule.rules $Programs }
    }
}

# Single source of the routing policy for imported and upgraded nodes.
# Order matters: provider core -> probes -> DNS -> trading programs -> tunnel
# endpoint -> LAN -> trading sites -> global mode -> AI assistants -> daily
# traffic -> unidentified. The assistant list can never take a trading flow.
function New-TCRoutingPolicy {
    param(
        [AllowNull()][AllowEmptyCollection()][string[]]$TradePrograms,
        [AllowNull()][AllowEmptyCollection()][string[]]$TradeDomains,
        [AllowNull()][AllowEmptyCollection()][string[]]$AuxDnsDomains,
        [AllowNull()][AllowEmptyCollection()][object[]]$Providers,
        [AllowNull()][AllowEmptyCollection()][string[]]$BootstrapDomains,
        [Parameter(Mandatory = $true)][string]$EndpointAddress,
        [bool]$EndpointIsIP,
        [int]$EndpointBits = 32,
        [Parameter(Mandatory = $true)][string]$DirectDns,
        [AllowNull()][AllowEmptyString()][string]$AgentRouteRuleSet,
        [AllowNull()][AllowEmptyString()][string]$AgentDnsRuleSet
    )
    $TradePrograms = @($TradePrograms | Where-Object { $_ }); $TradeDomains = @($TradeDomains | Where-Object { $_ })
    $AuxDnsDomains = @($AuxDnsDomains | Where-Object { $_ }); $Providers = @($Providers | Where-Object { $_ })
    $BootstrapDomains = @($BootstrapDomains | Where-Object { $_ })
    $providerPrograms = @(@(foreach ($provider in $Providers) { @($provider.Programs) }) | Where-Object { $_ } | Select-Object -Unique)
    $providerDirectories = @(@(foreach ($provider in $Providers) { @($provider.Directories) }) | Where-Object { $_ } | Select-Object -Unique)
    $hasAgents = [bool]($AgentRouteRuleSet -and $AgentDnsRuleSet)
    if ($hasAgents -and $providerPrograms.Count) {
        $agentRules = Read-TCJson $AgentRouteRuleSet
        Assert-TCProviderAgentSeparation $agentRules.rules $providerPrograms
    }
    $dnsRules = @(); $routeRules = @()
    if ($providerPrograms.Count) {
        $dnsRules += [ordered]@{process_path = $providerPrograms; action = 'route'; server = 'dns-direct'; strategy = 'ipv4_only'}
        $routeRules += [ordered]@{process_path = $providerPrograms; action = 'route'; outbound = 'direct'}
    }
    if ($providerDirectories.Count) {
        # Renamed provider cores must bypass the tunnel. A watched AI rule-set
        # exclusion keeps other applications in that folder on their own lane,
        # including assistant selections made after this candidate was created.
        $patterns = @(foreach ($directory in $providerDirectories) { '(?i)^' + (ConvertTo-TCRe2Literal $directory) + '\\' })
        if ($hasAgents) {
            $conditions = @([ordered]@{process_path_regex = $patterns}, [ordered]@{rule_set = @('tc-agents'); invert = $true})
            $dnsRules += [ordered]@{type = 'logical'; mode = 'and'; rules = $conditions; action = 'route'; server = 'dns-direct'; strategy = 'ipv4_only'}
            $routeRules += [ordered]@{type = 'logical'; mode = 'and'; rules = $conditions; action = 'route'; outbound = 'direct'}
        } else {
            $dnsRules += [ordered]@{process_path_regex = $patterns; action = 'route'; server = 'dns-direct'; strategy = 'ipv4_only'}
            $routeRules += [ordered]@{process_path_regex = $patterns; action = 'route'; outbound = 'direct'}
        }
    }
    $directDomains = @(@($BootstrapDomains) + @(foreach ($provider in $Providers) { @($provider.BootstrapDomains) }) | Where-Object { $_ } | Select-Object -Unique)
    if (-not $EndpointIsIP) { $directDomains += $EndpointAddress }
    if ($directDomains.Count) {
        # Only names actually observed in a client profile bypass tunnel DNS.
        # Guessing a suffix (especially co.uk) could take unrelated trading/AI
        # names away from dns-trade. Changed upstream names require a new policy.
        $dnsRules += [ordered]@{domain = @($directDomains | Select-Object -Unique); action = 'route'; server = 'dns-direct'; strategy = 'prefer_ipv4'}
    }
    $dnsRules += [ordered]@{clash_mode = 'global'; action = 'route'; server = 'dns-trade'; strategy = 'ipv4_only'}
    if ($TradePrograms.Count) { $dnsRules += [ordered]@{process_path = $TradePrograms; action = 'route'; server = 'dns-trade'; strategy = 'ipv4_only'} }
    $tradeDns = @(@($TradeDomains) + @($AuxDnsDomains) | Select-Object -Unique)
    if ($tradeDns.Count) { $dnsRules += [ordered]@{domain_suffix = $tradeDns; action = 'route'; server = 'dns-trade'; strategy = 'ipv4_only'} }
    # Listed assistant sites resolve on the trading line only while the list follows
    # it; the runtime leaves the DNS rule-set empty otherwise.
    if ($hasAgents) { $dnsRules += [ordered]@{rule_set = @('tc-agents-dns'); action = 'route'; server = 'dns-trade'; strategy = 'ipv4_only'} }
    # Declare BOTH supported modes regardless of the startup default. sing-box
    # builds its mode-list from referenced modes plus default_mode; a global
    # startup otherwise drops 'rule' and PATCH /configs silently ignores it.
    # This is the same fallback as dns.final, after trade and assistant rules.
    $dnsRules += [ordered]@{clash_mode = 'rule'; action = 'route'; server = 'dns-direct'}
    $routeRules += [ordered]@{inbound = @('egress-probe'); auth_user = @($script:TCDailyProbeUser); action = 'route'; outbound = 'daily-exit'}
    $routeRules += [ordered]@{inbound = @('egress-probe'); action = 'route'; outbound = 'trade-exit'}
    $routeRules += [ordered]@{port = 53; action = 'hijack-dns'}
    if ($TradePrograms.Count) {
        $routeRules += @([ordered]@{process_path = $TradePrograms; ip_version = 6; action = 'reject'}, [ordered]@{process_path = $TradePrograms; action = 'route'; outbound = 'trade-exit'})
    }
    if ($EndpointIsIP) { $routeRules += [ordered]@{ip_cidr = @($EndpointAddress + '/' + $EndpointBits); action = 'route'; outbound = 'direct'} }
    else { $routeRules += [ordered]@{domain = @($EndpointAddress); action = 'route'; outbound = 'direct'} }
    $routeRules += @([ordered]@{ip_is_private = $true; action = 'route'; outbound = 'direct'}, [ordered]@{port = @(80,443); action = 'sniff'; sniffer = @('http','tls','quic'); timeout = '300ms'})
    if ($TradeDomains.Count) {
        $routeRules += @([ordered]@{domain_suffix = $TradeDomains; ip_version = 6; action = 'reject'}, [ordered]@{domain_suffix = $TradeDomains; action = 'route'; outbound = 'trade-exit'})
    }
    $routeRules += @([ordered]@{clash_mode = 'global'; ip_version = 6; action = 'reject'}, [ordered]@{clash_mode = 'global'; action = 'route'; outbound = 'trade-exit'})
    if ($hasAgents) { $routeRules += @([ordered]@{rule_set = @('tc-agents'); ip_version = 6; action = 'reject'}, [ordered]@{rule_set = @('tc-agents'); action = 'route'; outbound = 'trade-exit'}) }
    $routeRules += @([ordered]@{process_path_regex = @('.+'); action = 'route'; outbound = 'daily-exit'}, [ordered]@{action = 'reject'})
    $outbounds = @([ordered]@{type = 'direct'; tag = 'direct'}); $exits = @('hk'); $daily = @('direct')
    # A dedicated trade listener must never appear in the daily selector, and a
    # provider's daily listener cannot stand in for its dedicated trade listener.
    foreach ($provider in $Providers) {
        $outbounds += [ordered]@{type = 'socks'; tag = [string]$provider.Tag; server = '127.0.0.1'; server_port = [int]$provider.Port; version = '5'}
        if ($provider.TradeTag -cne $provider.Tag) { $outbounds += [ordered]@{type = 'socks'; tag = [string]$provider.TradeTag; server = '127.0.0.1'; server_port = [int]$provider.TradePort; version = '5'} }
        $exits += [string]$provider.TradeTag; $daily += [string]$provider.Tag
    }
    $outbounds += [ordered]@{type = 'selector'; tag = 'trade-exit'; outbounds = $exits; default = 'hk'; interrupt_exist_connections = $true}
    $outbounds += [ordered]@{type = 'selector'; tag = 'daily-exit'; outbounds = $daily; default = 'direct'; interrupt_exist_connections = $true}
    $route = [ordered]@{rules = $routeRules; final = 'direct'; auto_detect_interface = $true; default_domain_resolver = [ordered]@{server = 'dns-direct'; strategy = 'prefer_ipv4'}}
    # Local rule-sets are reloaded by the engine when the files change.
    if ($hasAgents) { $route.rule_set = @([ordered]@{type = 'local'; tag = 'tc-agents'; format = 'source'; path = $AgentRouteRuleSet}, [ordered]@{type = 'local'; tag = 'tc-agents-dns'; format = 'source'; path = $AgentDnsRuleSet}) }
    return [ordered]@{
        dns = [ordered]@{servers = @([ordered]@{type = 'udp'; tag = 'dns-direct'; server = $DirectDns}, [ordered]@{type = 'https'; tag = 'dns-trade'; server = '1.1.1.1'; server_port = 443; path = '/dns-query'; detour = 'trade-exit'}); rules = $dnsRules; final = 'dns-direct'; reverse_mapping = $true}
        route = $route
        outbounds = $outbounds
    }
}

function Remove-TCOwnedDirectory {
    param([string]$Root, [string]$Path, [string]$Id)
    $guid = ConvertTo-TCId $Id
    $full = Get-TCFullPath $Path
    $allowed = @((Join-Path (Join-Path $Root '.staging') $guid), (Join-Path (Join-Path $Root 'nodes') $guid))
    if ($full -notin $allowed) { Stop-TCError '拒绝清理节点库范围之外的目录。' }
    Assert-TCNoReparse $full
    if ([IO.Directory]::Exists($full)) { [IO.Directory]::Delete($full, $true) }
}

function Import-TCWireGuard {
    [CmdletBinding()]
    param(
        [string]$Root = $script:TCDefaultRoot,
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][string]$EnginePath,
        [Parameter(Mandatory=$true)][string]$WgPath,
        [AllowEmptyCollection()][string[]]$TradeProgramPaths = @(),
        [Parameter(Mandatory=$true)][string]$DirectDnsIPv4,
        [AllowNull()][AllowEmptyCollection()][object[]]$Providers,
        [AllowNull()]$Provider
    )
    $ErrorActionPreference = 'Stop'
    $lock = $null; $stage = $null; $final = $null; $committed = $false; $store = $null; $wg = $null
    try {
        $nodeName = ConvertTo-TCName $Name
        $source = Get-TCFullPath $Path
        $engine = Get-TCFullPath $EnginePath; $wgExe = Get-TCFullPath $WgPath
        foreach ($exe in @($engine,$wgExe)) {
            if ([IO.Path]::GetExtension($exe) -ine '.exe' -or -not [IO.File]::Exists($exe)) { Stop-TCError '请提供可用的 sing-box.exe 和 wg.exe；不要求安装 WireGuard GUI。' }
        }
        $tradePrograms = @(Resolve-TCPrograms $TradeProgramPaths)
        $directDns = $null
        if ($DirectDnsIPv4 -notmatch '^\d{1,3}(\.\d{1,3}){3}$' -or -not [Net.IPAddress]::TryParse($DirectDnsIPv4, [ref]$directDns) -or $directDns.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { Stop-TCError 'DirectDnsIPv4 必须是有效 IPv4 DNS 地址。' }
        if ($PSBoundParameters.ContainsKey('Provider') -and $PSBoundParameters.ContainsKey('Providers')) { Stop-TCError '不能同时指定旧 Provider 和 Providers 列表。' }
        $sourceProviders = if ($PSBoundParameters.ContainsKey('Provider')) { @(ConvertFrom-TCLegacyProvider $Provider) } else { $Providers }
        $raw = Read-TCWireGuardText $source
        try { $wg = ConvertFrom-TCWireGuard $raw } finally { $raw = $null }
        $policyProviders = @(ConvertTo-TCPolicyProviders -Providers $sourceProviders -TradePrograms $tradePrograms -ReservedPorts @(17890,17891,$wg.listenPort))
        $hasProvider = ($policyProviders.Count -gt 0)
        $primary = $(if ($hasProvider) { $policyProviders[0] } else { $null })
        $bootstrap = @(@(foreach ($provider in $policyProviders) { @($provider.BootstrapDomains) }) | Where-Object { $_ } | Select-Object -Unique)
        $derived = Invoke-TCNative -FilePath $wgExe -ArgumentList @('pubkey') -InputText $wg.interface.PrivateKey
        if ($derived.ExitCode -ne 0) { Stop-TCError 'wg.exe 无法校验客户端密钥；诊断内容已隐藏。' }
        $clientPublic = $derived.StandardOutput.Trim()
        Assert-TCKey $clientPublic
        if ($clientPublic -ceq $wg.peer.PublicKey) { Stop-TCError 'Peer 公钥与客户端公钥相同；请使用服务器公钥。' }
        $derived = $null
        $store = Initialize-TCStore -Root $Root
        $lock = Open-TCLock $store.root
        $index = Read-TCIndex $store.root
        if ($index.nodes.Count -ge 1000) { Stop-TCError '节点库最多支持 1000 个节点。' }
        $id = [Guid]::NewGuid().ToString('D')
        $stage = Join-Path (Join-Path $store.root '.staging') $id
        $final = Join-Path (Join-Path $store.root 'nodes') $id
        New-TCPrivateDirectory $stage
        $tokenBytes = New-Object byte[] 32
        $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
        try { $rng.GetBytes($tokenBytes); $secret = [Convert]::ToBase64String($tokenBytes) }
        finally { $rng.Dispose(); [Array]::Clear($tokenBytes, 0, $tokenBytes.Length) }
        $wgPeer = [ordered]@{address = $wg.endpoint.address; port = $wg.endpoint.port; public_key = $wg.peer.PublicKey; allowed_ips = @('0.0.0.0/0'); persistent_keepalive_interval = $wg.keepAlive}
        if ($wg.peer.ContainsKey('PresharedKey')) { $wgPeer.pre_shared_key = $wg.peer.PresharedKey }
        $endpoint = [ordered]@{type = 'wireguard'; tag = 'hk'; system = $false; mtu = $wg.mtu; address = @($wg.clientIPv4 + '/32'); private_key = $wg.interface.PrivateKey; peers = @($wgPeer)}
        if ($wg.listenPort -gt 0) { $endpoint.listen_port = $wg.listenPort }
        $bits = 32
        if ($wg.endpoint.ip -and $wg.endpoint.ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { $bits = 128 }
        $agentFiles = Initialize-TCAgentRuleSetFiles $store.root
        $policy = New-TCRoutingPolicy -TradePrograms $tradePrograms -TradeDomains @($index.tradeDomains) -AuxDnsDomains $script:TCAuxDnsDomains -Providers $policyProviders -BootstrapDomains $bootstrap -EndpointAddress $wg.endpoint.address -EndpointIsIP ([bool]$wg.endpoint.ip) -EndpointBits $bits -DirectDns $directDns.ToString() -AgentRouteRuleSet $agentFiles.Route -AgentDnsRuleSet $agentFiles.Dns
        $config = [ordered]@{
            log = @{level = 'warn'; timestamp = $true}
            dns = $policy.dns
            inbounds = @(@{type = 'tun'; tag = 'trade-tun'; interface_name = 'TradeChannel'; address = @('172.30.250.1/30','fd42:7472:6164::1/126'); mtu = $wg.mtu; auto_route = $true; strict_route = $true; stack = 'gvisor'}, @{type = 'mixed'; tag = 'egress-probe'; listen = '127.0.0.1'; listen_port = 17890; users = @(@{username = 'tradechannel-probe'; password = $secret}, @{username = $script:TCDailyProbeUser; password = $secret})})
            endpoints = @($endpoint); outbounds = $policy.outbounds
            route = $policy.route
            experimental = @{clash_api = @{external_controller = '127.0.0.1:17891'; secret = $secret; default_mode = 'rule'; access_control_allow_origin = @(); access_control_allow_private_network = $false}}
        }
        $probe = [ordered]@{
            log = @{level = 'warn'; timestamp = $true}
            dns = @{servers = @(@{type = 'udp'; tag = 'dns-direct'; server = $directDns.ToString()}, @{type = 'udp'; tag = 'dns-hk'; server = '1.1.1.1'; detour = 'hk'}); final = 'dns-hk'; strategy = 'ipv4_only'}
            inbounds = @(@{type = 'mixed'; tag = 'probe'; listen = '127.0.0.1'; listen_port = 17890; users = @(@{username='tradechannel-probe';password=$secret})})
            endpoints = @($endpoint); outbounds = @()
            route = @{final = 'hk'; auto_detect_interface = $true; default_domain_resolver = @{server = 'dns-direct'; strategy = 'prefer_ipv4'}}
        }
        $probe=Set-TCAuthenticatedProbe ([pscustomobject]($probe|ConvertTo-Json -Depth 30|ConvertFrom-Json)) $secret
        $candidateStage = Join-Path $stage 'dual-mode.json'; $probeStage = Join-Path $stage 'probe.json'
        # sing-box's JSON decoder expects UTF-8 without a BOM. PS sources retain BOM.
        Write-TCAtomicJson $candidateStage $config -NewOnly -NoBom
        Write-TCAtomicJson $probeStage $probe -NewOnly -NoBom
        foreach ($checkPath in @($candidateStage,$probeStage)) {
            $check = Invoke-TCNative -FilePath $engine -ArgumentList @('check','-c',$checkPath)
            if ($check.ExitCode -ne 0) { Stop-TCError 'sing-box check 未通过，节点未入库；诊断内容已隐藏以保护密钥。' }
            $check = $null
        }
        $manifestPath = Join-Path $final 'manifest.json'
        $createdAt = [DateTimeOffset]::UtcNow.ToString('o')
        $manifest = [ordered]@{
            SchemaVersion = 1; node_id = $id; CreatedAt = $createdAt; Status = 'CandidateOnly'
            EnginePath = $engine; WgPath = $wgExe; CandidatePath = (Join-Path $final 'dual-mode.json'); ProbePath = (Join-Path $final 'probe.json')
            ExportSHA256 = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
            CandidateSHA256 = (Get-FileHash -LiteralPath $candidateStage -Algorithm SHA256).Hash; ProbeSHA256 = (Get-FileHash -LiteralPath $probeStage -Algorithm SHA256).Hash
            ClientPublicKey = $clientPublic; ServerPublicKey = $wg.peer.PublicKey; ServerEndpoint = $wg.endpoint.text
            ClientAddress = $wg.clientIPv4; DirectDns = $directDns.ToString(); TradeProgramPaths = $tradePrograms
            ControlPort = 17891; ProbePort = 17890; HasPSK = $wg.peer.ContainsKey('PresharedKey'); TradeDomainSuffixes = @($index.tradeDomains)
            ProviderEnabled = $hasProvider; Providers = @(ConvertTo-TCManifestProviders $policyProviders)
            # Slot-1 fields stay for readers written before provider profiles.
            ProviderProgramPaths = @(if ($primary) { $primary.Programs } else { @() }); ProviderSocksPort = $(if ($primary) { $primary.Port } else { $null })
            ProviderTradePort = $(if ($primary) { $primary.TradePort } else { $null })
            ProviderHttpPort = $(if ($primary) { $primary.HttpPort } else { $null }); ProviderPacPort = $(if ($primary) { $primary.PacPort } else { $null })
            ProviderBootstrapDomains = $bootstrap; ProviderSwitchVerified = $false
            PolicyVersion = $script:TCPolicyVersion; ProviderDirectory = $(if ($primary) { $primary.Directory } else { $null }); TradeDnsOnlySuffixes = @($script:TCAuxDnsDomains); DailyProbeUser = $script:TCDailyProbeUser
            AgentRuleSetPath = $agentFiles.Route; AgentDnsRuleSetPath = $agentFiles.Dns
            SyntaxValidated = $true; ServerForwardingVerified = $false; ProcessRoutingVerified = $false; IndependentGuardVerified = $false
            IPv6Policy = 'Reject public IPv6 for trading programs, listed AI assistants on the trading line and in global mode until server IPv6 is provisioned.'
            UnidentifiedPublicProcessPolicy = 'Reject; never silently fall back to direct.'
            ModeSwitchPolicy = 'Rule/global affects new connections. Existing connections retain their original paths.'
            ExitSwitchPolicy = 'Manual selection interrupts selected-egress connections. No automatic direct fallback.'
            StartupMode = 'rule'; DeploymentApproved = $false
        }
        Write-TCAtomicJson (Join-Path $stage 'manifest.json') $manifest -NewOnly
        Assert-TCNoReparse $final
        [IO.Directory]::Move($stage, $final)
        $node = [pscustomobject][ordered]@{id = $id; name = $nodeName; kind = 'wireguard'; endpoint = $wg.endpoint.text; manifestPath = $manifestPath; registeredAt = $createdAt; status = 'CandidateOnly'}
        $index.nodes = @($index.nodes) + @($node)
        Write-TCAtomicJson $store.indexPath $index
        $committed = $true
        return ConvertTo-TCNode $node
    } catch { Stop-TCOperation $_ '导入 WireGuard 失败，请检查输入格式、程序路径和节点库权限；密钥内容未输出。' }
    finally {
        try {
            if (-not $committed -and $store) {
                if ($stage) { Remove-TCOwnedDirectory -Root $store.root -Path $stage -Id $id }
                if ($final) { Remove-TCOwnedDirectory -Root $store.root -Path $final -Id $id }
            }
        } catch { Stop-TCOperation $_ '导入未完成，且本次暂存产物清理失败；请检查节点库权限后重试。' }
        finally {
            if ($lock) { $lock.Dispose() }
            $wg = $null; $config = $null; $probe = $null; $endpoint = $null; $wgPeer = $null; $secret = $null
        }
    }
}

# Rebuilds a node's routing policy at the current version. The tunnel identity,
# controller secret and TUN settings are carried over unchanged; the result is a
# new, separately checked candidate. The running configuration is never edited.
function Update-TCNodePolicy {
    [CmdletBinding()]
    param(
        [string]$Root = $script:TCDefaultRoot, [Parameter(Mandatory=$true)][string]$ManifestPath,
        [AllowNull()][AllowEmptyCollection()][string[]]$BootstrapDomains,
        # Omitted: keep the providers the current line already has.
        [AllowNull()][AllowEmptyCollection()][object[]]$Providers, [switch]$ReplaceProviders
    )
    $ErrorActionPreference = 'Stop'
    $stage = $null; $committed = $false; $config = $null; $secret = $null; $newConfig = $null
    try {
        $manifestFull = Get-TCFullPath $ManifestPath
        $manifest = Read-TCJson $manifestFull
        foreach ($field in @('CandidatePath','EnginePath','ServerEndpoint')) {
            if (-not $manifest.PSObject.Properties[$field] -or -not $manifest.$field) { Stop-TCError '节点记录缺少配置、引擎或端点字段，无法升级。' }
        }
        $engine = Get-TCFullPath $manifest.EnginePath; $candidate = Get-TCFullPath $manifest.CandidatePath
        foreach ($file in @($engine, $candidate)) { if (-not [IO.File]::Exists($file)) { Stop-TCError '节点配置或连接引擎文件不存在，无法升级。' } }
        $config = Read-TCJson $candidate
        foreach ($field in @('endpoints','inbounds','experimental','log')) { if (-not $config.PSObject.Properties[$field]) { Stop-TCError '现有配置结构不完整，未升级。' } }
        $endpoint = @($config.endpoints | Where-Object { $_.tag -eq 'hk' })
        $probe = @($config.inbounds | Where-Object { $_.tag -eq 'egress-probe' })
        if ($endpoint.Count -ne 1 -or @($endpoint[0].peers).Count -lt 1 -or $probe.Count -ne 1 -or @($probe[0].users).Count -lt 1) { Stop-TCError '现有配置缺少隧道或诊断入口，未升级。' }
        $address = [string]@($endpoint[0].peers)[0].address
        $ip = $null; $isIP = [Net.IPAddress]::TryParse($address, [ref]$ip)
        $bits = 32
        if ($isIP -and $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { $bits = 128 }
        $directDns = $null
        if ($config.PSObject.Properties['dns']) { $server = @($config.dns.servers | Where-Object { $_.tag -eq 'dns-direct' }); if ($server.Count) { $directDns = [string]$server[0].server } }
        if (-not $directDns -and $manifest.PSObject.Properties['DirectDns']) { $directDns = [string]$manifest.DirectDns }
        $dnsIp = $null
        if (-not $directDns -or -not [Net.IPAddress]::TryParse($directDns, [ref]$dnsIp)) { Stop-TCError '现有配置缺少本地 DNS 地址，未升级。' }
        $field = { param($Name) if ($manifest.PSObject.Properties[$Name]) { @($manifest.$Name | Where-Object { $_ }) } else { @() } }
        $tradePrograms = @(& $field 'TradeProgramPaths')
        if ($PSBoundParameters.ContainsKey('Providers') -and -not $ReplaceProviders) { Stop-TCError '替换服务商列表需要同时指定 ReplaceProviders。' }
        $sourceProviders = if ($ReplaceProviders) { $Providers } else { @(ConvertFrom-TCManifestProviders $manifest) }
        $reservedPorts = @(17890,17891)
        foreach ($inbound in @($config.inbounds) + @($config.endpoints)) {
            if ($inbound.PSObject.Properties['listen_port'] -and $inbound.listen_port) { $reservedPorts += ConvertTo-TCPort $inbound.listen_port }
        }
        $controller = [string](Get-TCProperty (Get-TCProperty $config.experimental 'clash_api') 'external_controller')
        if ($controller -match ':(\d+)$') { $reservedPorts += ConvertTo-TCPort $matches[1] }
        $policyProviders = @(ConvertTo-TCPolicyProviders -Providers $sourceProviders -TradePrograms $tradePrograms -ReservedPorts $reservedPorts)
        $primary = $(if ($policyProviders.Count) { $policyProviders[0] } else { $null })
        $previousBootstrap = @(if (-not $ReplaceProviders) { & $field 'ProviderBootstrapDomains' })
        $bootstrap = @($previousBootstrap + @($BootstrapDomains | Where-Object { $_ }) + @(foreach ($provider in $policyProviders) { @($provider.BootstrapDomains) }) | Where-Object { $_ } | ForEach-Object { ConvertTo-TCDomain ([string]$_) } | Select-Object -Unique)
        $tradeDomains = @(& $field 'TradeDomainSuffixes')
        $storeFull = Get-TCFullPath $Root
        if ([IO.File]::Exists((Join-Path $storeFull 'index.json'))) { $tradeDomains = @((Read-TCIndex $storeFull).tradeDomains) }
        $agentFiles = Initialize-TCAgentRuleSetFiles $storeFull
        $policy = New-TCRoutingPolicy -TradePrograms $tradePrograms -TradeDomains $tradeDomains -AuxDnsDomains $script:TCAuxDnsDomains -Providers $policyProviders -BootstrapDomains $bootstrap -EndpointAddress $address -EndpointIsIP $isIP -EndpointBits $bits -DirectDns $directDns -AgentRouteRuleSet $agentFiles.Route -AgentDnsRuleSet $agentFiles.Dns
        $secret = [string]@($probe[0].users)[0].password
        if (-not $secret) { Stop-TCError '现有诊断入口缺少认证，未升级。' }
        $users = @([ordered]@{username = 'tradechannel-probe'; password = $secret}, [ordered]@{username = $script:TCDailyProbeUser; password = $secret})
        $inbounds = @(foreach ($inbound in @($config.inbounds)) {
            if ($inbound.tag -eq 'egress-probe') { [ordered]@{type = 'mixed'; tag = 'egress-probe'; listen = $inbound.listen; listen_port = $inbound.listen_port; users = $users} } else { $inbound }
        })
        $existingTransport = Get-TCTransportFromConfiguration $manifest $config
        $newConfig = [ordered]@{log = @{level='warn';timestamp=$true}; dns = $policy.dns; inbounds = $inbounds; endpoints = @($config.endpoints); outbounds = $policy.outbounds; route = $policy.route; experimental = $config.experimental}
        $newConfig = Set-TCConfigurationTransport ([pscustomobject]$newConfig) $existingTransport
        $configsRoot = Join-Path ([IO.Path]::GetDirectoryName($storeFull)) 'configs'
        if (-not [IO.Directory]::Exists($configsRoot)) { New-TCPrivateDirectory $configsRoot }
        $name = 'policy' + $script:TCPolicyVersion + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [Guid]::NewGuid().ToString('N')
        $stage = Join-Path $configsRoot ('.staging-' + $name); $final = Join-Path $configsRoot $name
        New-TCPrivateDirectory $stage
        $stagedConfig = Join-Path $stage 'dual-mode.json'
        Write-TCAtomicJson $stagedConfig $newConfig -NewOnly -NoBom
        Test-TCCheckedConfiguration $engine $stagedConfig
        $probeSource = $null
        if ($manifest.PSObject.Properties['ProbePath'] -and $manifest.ProbePath -and [IO.File]::Exists([string]$manifest.ProbePath)) { $probeSource = [string]$manifest.ProbePath; $probeConfig=Read-TCJson $probeSource; $probeConfig=Set-TCAuthenticatedProbe $probeConfig $secret; $probeConfig=Set-TCConfigurationTransport $probeConfig $existingTransport; Write-TCAtomicJson (Join-Path $stage 'probe.json') $probeConfig -NewOnly -NoBom; Test-TCCheckedConfiguration $engine (Join-Path $stage 'probe.json') }
        $next = [ordered]@{}
        foreach ($property in $manifest.PSObject.Properties) { $next[$property.Name] = $property.Value }
        $next.CandidatePath = Join-Path $final 'dual-mode.json'
        if ($probeSource) { $next.ProbePath = Join-Path $final 'probe.json'; $next.ProbeSHA256=(Get-FileHash -LiteralPath (Join-Path $stage 'probe.json')).Hash }
        $next.CandidateSHA256 = (Get-FileHash -LiteralPath $stagedConfig -Algorithm SHA256).Hash
        $next.TradeDomainSuffixes = $tradeDomains; $next.ProviderBootstrapDomains = $bootstrap
        $next.ProviderEnabled = ($policyProviders.Count -gt 0); $next.Providers = @(ConvertTo-TCManifestProviders $policyProviders)
        $next.ProviderProgramPaths = @(if ($primary) { $primary.Programs } else { @() }); $next.ProviderSocksPort = $(if ($primary) { $primary.Port } else { $null })
        $next.ProviderTradePort = $(if ($primary) { $primary.TradePort } else { $null })
        $next.ProviderHttpPort = $(if ($primary) { $primary.HttpPort } else { $null }); $next.ProviderPacPort = $(if ($primary) { $primary.PacPort } else { $null })
        $next.PolicyVersion = $script:TCPolicyVersion; $next.ProviderDirectory = $(if ($primary) { $primary.Directory } else { $null }); $next.TradeDnsOnlySuffixes = @($script:TCAuxDnsDomains); $next.DailyProbeUser = $script:TCDailyProbeUser
        $next.AgentRuleSetPath = $agentFiles.Route; $next.AgentDnsRuleSetPath = $agentFiles.Dns
        $next.UpgradedFrom = $manifestFull; $next.PreviousManifestPath=$manifestFull; $next.ConfigurationChangeKind='PolicyUpdate'; $next.ConfigurationChangedAt=[DateTimeOffset]::UtcNow.ToString('o'); $next.PolicyUpgradedAt = [DateTimeOffset]::Now.ToString('o'); if ($existingTransport) { $next.Transport = $existingTransport }
        # Activation (and its runtime checks) belongs to Enable-TCNode, not to this step.
        $next.DeploymentApproved = $false
        $next.SyntaxValidated = $true; $next.ProviderSwitchVerified = $false
        Write-TCAtomicJson (Join-Path $stage 'manifest.json') $next -NewOnly
        Assert-TCNoReparse $final
        [IO.Directory]::Move($stage, $final)
        $committed = $true
        return [pscustomobject]@{ManifestPath = (Join-Path $final 'manifest.json'); CandidatePath = (Join-Path $final 'dual-mode.json'); PreviousManifestPath = $manifestFull; PolicyVersion = $script:TCPolicyVersion; ProviderDirectory = $(if ($primary) { $primary.Directory } else { $null }); ProviderNames = @($policyProviders | ForEach-Object { [string]$_.Name })}
    } catch { Stop-TCOperation $_ '线路配置升级失败；当前配置与连接均未改变。' }
    finally {
        try { if (-not $committed -and $stage -and [IO.Directory]::Exists($stage)) { [IO.Directory]::Delete($stage, $true) } } catch { }
        $config = $null; $newConfig = $null; $secret = $null; $users = $null; $inbounds = $null
    }
}

# Points a registered node at a replacement manifest (after a successful upgrade).
function Set-TCNodeManifest {
    [CmdletBinding()]
    param([string]$Root = $script:TCDefaultRoot, [Parameter(Mandatory=$true)][string]$PreviousManifestPath, [Parameter(Mandatory=$true)][string]$ManifestPath,[string]$ExpectedNodeId,[string]$ExpectedCurrentHash)
    $ErrorActionPreference = 'Stop'; $lock = $null
    try {
        $previous = Get-TCFullPath $PreviousManifestPath; $next = Get-TCFullPath $ManifestPath
        if (-not [IO.File]::Exists($next)) { Stop-TCError '新的节点记录不存在。' }
        $store = Initialize-TCStore -Root $Root
        $lock = Open-TCLock $store.root
        $index = Read-TCIndex $store.root
        $found = @($index.nodes | Where-Object { $_.manifestPath -and ([string]$_.manifestPath).Equals($previous, [StringComparison]::OrdinalIgnoreCase) })
        if($ExpectedNodeId){$expectedId=ConvertTo-TCId $ExpectedNodeId;if($found.Count -ne 1 -or $found[0].id -cne $expectedId){Stop-TCError '线路指针已变化，请重新预览。'}}
        if($ExpectedCurrentHash -and (Get-FileHash -LiteralPath $previous -Algorithm SHA256).Hash -cne $ExpectedCurrentHash){Stop-TCError '当前配置记录已变化，请重新预览。'}
        if($ExpectedNodeId){$target=Read-TCJson $next;Assert-TCNoReparse $target.CandidatePath;if((Get-FileHash -LiteralPath $target.CandidatePath -Algorithm SHA256).Hash -cne (Get-TCProperty $target 'CandidateSHA256' '')){Stop-TCError '目标配置完整性已变化，请重新预览。'}}
        foreach ($node in $found) { $node.manifestPath = $next }
        if ($found.Count) { Write-TCAtomicJson $store.indexPath $index }
        return @($found | ForEach-Object { ConvertTo-TCNode $_ })
    } catch { Stop-TCOperation $_ '更新节点记录失败；请检查节点库权限。' }
    finally { if ($lock) { $lock.Dispose() } }
}

function Rename-TCNode {
    [CmdletBinding()]
    param([string]$Root = $script:TCDefaultRoot, [Parameter(Mandatory=$true)][string]$Id, [Parameter(Mandatory=$true)][string]$Name)
    $ErrorActionPreference = 'Stop'; $lock = $null
    try {
        $nodeId = ConvertTo-TCId $Id; $nodeName = ConvertTo-TCName $Name
        $store = Initialize-TCStore -Root $Root
        $lock = Open-TCLock $store.root
        $index = Read-TCIndex $store.root
        $found = @($index.nodes | Where-Object { $_.id -eq $nodeId })
        if ($found.Count -ne 1) { Stop-TCError '找不到指定节点。' }
        $found[0].name = $nodeName
        Write-TCAtomicJson $store.indexPath $index
        return ConvertTo-TCNode $found[0]
    } catch { Stop-TCOperation $_ '重命名节点失败；请检查节点 ID 和写入权限。' }
    finally { if ($lock) { $lock.Dispose() } }
}

function Export-TCSettings {
    [CmdletBinding()]
    param([string]$Root = $script:TCDefaultRoot, [Parameter(Mandatory=$true)][string]$Destination)
    $ErrorActionPreference = 'Stop'
    try {
        $full = Get-TCFullPath $Root; $destinationFull = Get-TCFullPath $Destination
        Assert-TCNoReparse $full; Assert-TCNoReparse $destinationFull
        if ($destinationFull.Equals($full, [StringComparison]::OrdinalIgnoreCase) -or $destinationFull.StartsWith($full + '\', [StringComparison]::OrdinalIgnoreCase)) { Stop-TCError '请将迁移包保存到节点库之外的独立文件。' }
        if ([IO.File]::Exists($destinationFull) -or [IO.Directory]::Exists($destinationFull)) { Stop-TCError '目标已存在；请选择新文件名，避免覆盖原文件。' }
        if (-not [IO.File]::Exists((Join-Path $full 'index.json'))) { $null = Initialize-TCStore -Root $full }
        $index = Read-TCIndex $full
        $metadata = @(foreach ($node in $index.nodes) { [pscustomobject][ordered]@{name = $node.name; kind = $node.kind; endpoint = $node.endpoint} })
        $package = [ordered]@{schemaVersion = 1; nodes = $metadata; tradeDomains = @($index.tradeDomains)}
        $references = @{}
        foreach ($reference in @(Get-TCProperty $index 'providerReferences' @())) { $references[[int]$reference.slot] = $reference }
        $providers = @(Read-TCStoredProviders $full)
        if (-not [IO.File]::Exists((Join-Path $full 'providers.json'))) {
            # Older stores have only manifests. Read their metadata, never their
            # client config, subscription, proxy credentials or WireGuard keys.
            $providers = @(foreach ($node in $index.nodes) {
                if ($node.manifestPath -and [IO.File]::Exists($node.manifestPath)) {
                    $sourceManifest = Read-TCJson $node.manifestPath
                    foreach ($entry in @(ConvertFrom-TCManifestProviders $sourceManifest)) {
                        [pscustomobject]@{Slot = $entry.slot; Kind = $entry.kind; Name = $entry.name}
                    }
                }
            })
        }
        foreach ($provider in $providers) {
            $references[[int]$provider.Slot] = [pscustomobject][ordered]@{slot = [int]$provider.Slot; kind = [string]$provider.Kind; name = [string]$provider.Name; status = 'PendingDetection'}
        }
        $providerReferences = @(ConvertTo-TCProviderReferences @($references.Values | Sort-Object slot))
        if ($providerReferences.Count) { $package.providerReferences = $providerReferences }
        Write-TCAtomicJson $destinationFull $package -NewOnly
        return [pscustomobject]@{path = $destinationFull; schemaVersion = 1; nodeCount = $metadata.Count; providerCount = $providerReferences.Count}
    } catch { Stop-TCOperation $_ '无法导出设置，请检查目标目录是否存在且可写。' }
}

function Import-TCSettings {
    [CmdletBinding()]
    param([string]$Root = $script:TCDefaultRoot, [Parameter(Mandatory=$true)][string]$Path)
    $ErrorActionPreference = 'Stop'; $lock = $null
    try {
        $package = Read-TCJson (Get-TCFullPath $Path)
        Assert-TCFields $package @('schemaVersion','nodes','tradeDomains') @('providerReferences')
        if ($package.schemaVersion -isnot [int] -or $package.schemaVersion -ne 1) { Stop-TCError '不支持此设置迁移版本。' }
        if ($package.nodes -isnot [array] -or $package.nodes.Count -gt 1000) { Stop-TCError '迁移节点必须是数组且不能超过 1000 项。' }
        $domains = @(ConvertTo-TCDomains $package.tradeDomains)
        $providerReferences = @(if ($package.PSObject.Properties['providerReferences']) { ConvertTo-TCProviderReferences $package.providerReferences })
        $imported = @(foreach ($item in $package.nodes) {
            Assert-TCFields $item @('name','kind','endpoint')
            $nodeName = ConvertTo-TCName $item.name
            $endpoint = (ConvertTo-TCEndpoint $item.endpoint).text
            if ($item.kind -cnotin @('wireguard','existing')) { Stop-TCError '迁移包包含不支持的节点类型。' }
            [pscustomobject][ordered]@{id = [Guid]::NewGuid().ToString('D'); name = $nodeName; kind = $item.kind; endpoint = $endpoint; manifestPath = $null; registeredAt = [DateTimeOffset]::UtcNow.ToString('o'); status = 'PendingAuthorization'}
        })
        $store = Initialize-TCStore -Root $Root
        $lock = Open-TCLock $store.root
        $index = Read-TCIndex $store.root
        if ($index.nodes.Count + $imported.Count -gt 1000) { Stop-TCError '导入后节点数将超过 1000，已取消。' }
        $index.nodes = @($index.nodes) + $imported
        $index.tradeDomains = $domains
        # References stay in the node index. They are intentionally not a local
        # provider registry and cannot produce an outbound before rediscovery.
        if ($providerReferences.Count) {
            $combined = @{}
            foreach ($reference in @(Get-TCProperty $index 'providerReferences' @()) + $providerReferences) { $combined[[int]$reference.slot] = $reference }
            $index | Add-Member -MemberType NoteProperty -Name providerReferences -Value @($combined.Values | Sort-Object slot) -Force
        }
        Write-TCAtomicJson $store.indexPath $index
        return [pscustomobject]@{schemaVersion = 1; importedCount = $imported.Count; nodes = @($imported | ForEach-Object { ConvertTo-TCNode $_ }); providerCount = $providerReferences.Count; providerReferences = @($providerReferences)}
    } catch { Stop-TCOperation $_ '设置导入失败；仅支持不携带密钥和运行状态的设置迁移包。' }
    finally { if ($lock) { $lock.Dispose() } }
}


. (Join-Path $PSScriptRoot 'NodeOperations.ps1')

Export-ModuleMember -Function Initialize-TCStore,Get-TCNodes,Register-TCExisting,Import-TCWireGuard,Update-TCNodePolicy,Set-TCNodeManifest,Export-TCSettings,Import-TCSettings,Rename-TCNode,Remove-TCNode,Set-TCTransportMode,Get-TCTransportInfo,ConvertFrom-TCManifestProviders,ConvertTo-TCPolicyProviders
