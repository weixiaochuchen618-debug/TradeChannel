#requires -Version 5.1
<#
Local Windows/Linux transport only. Importing this module has no side effects.
Worker API: Invoke-TCLinuxRequest -Request <LinuxStart|LinuxPoll|LinuxComplete|LinuxRecent>
[-Root <TradeChannel base>] [-WgPath <existing wg.exe>]. The lower-level commands
take -Root as the dedicated linux-jobs directory instead. No node registration,
route changes, activation, downloads, password storage or automatic SSH retries.

LinuxStart: Operation, Connection {Host,Port=22,User=root,IdentityFile?},
Name, PublicEndpoint, TunnelSubnet. Apply: ParentJobId + optional PlanId only.
Recover may also inherit a Plan/Apply context via ParentJobId; its input is {}.
LinuxPoll/LinuxComplete: Id. Each Start is an explicit wizard click; only Start
opens a visible console. Pending is exposed to the Worker as Running.
The bundled, single-file Python backend is linux/tradechannel_linux.py.

The console and native transport are module-private test seams. Do not accept
adapters, executable paths, source text, scripts or arbitrary CLI options from
Worker JSON. A closed/expired console is terminal and never automatically retried;
the remote outcome can be unknown. Poll Status before deciding what to do next.
#>
Set-StrictMode -Version 2.0
$script:TCLinuxClientModule = $null
$script:TCLinuxMaxResult = 256KB
$script:TCLinuxLifetimeSeconds = 1800

function Stop-TCLinux {
    param([string]$Code, [string]$Message)
    throw [InvalidOperationException]::new(('[TC:{0}] {1}' -f $Code, $Message))
}

function Get-TCLinuxProperty {
    param($Object, [string]$Name, $Default = $null)
    if ($Object -is [Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
    } elseif ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}

function ConvertTo-TCLinuxUtcTime {
    # ConvertFrom-Json can return strings in PS5.1 and DateTime/DateTimeOffset
    # in PS7. Never stringify a typed time: that drops its Kind/offset and uses
    # the current culture. Unspecified DateTime values represent schema UTC.
    param($Value)
    if ($Value -is [DateTimeOffset]) { return $Value.ToUniversalTime() }
    if ($Value -is [DateTime]) {
        if ($Value.Kind -eq [DateTimeKind]::Unspecified) { $Value = [DateTime]::SpecifyKind($Value,[DateTimeKind]::Utc) }
        return ([DateTimeOffset]$Value.ToUniversalTime())
    }
    if ($Value -is [string] -and $Value -cmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,7})?(Z|[+-][0-9]{2}:[0-9]{2})$') {
        try { return [DateTimeOffset]::Parse($Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AdjustToUniversal) }
        catch { }
    }
    Stop-TCLinux InvalidTimestamp '时间字段必须是包含时区的 ISO 时间或有效的日期时间对象。'
}

function ConvertTo-TCLinuxUtcIso {
    param($Value)
    return (ConvertTo-TCLinuxUtcTime $Value).UtcDateTime.ToString('o',[Globalization.CultureInfo]::InvariantCulture)
}

function Assert-TCLinuxFields {
    param($Object, [string[]]$Allowed)
    if ($null -eq $Object -or ($Object -isnot [Collections.IDictionary] -and $Object -isnot [pscustomobject])) {
        Stop-TCLinux InvalidRequest '请求必须是结构化对象。'
    }
    $names = if ($Object -is [Collections.IDictionary]) { @($Object.Keys) } else { @($Object.PSObject.Properties.Name) }
    foreach ($name in $names) {
        if ($name -notin $Allowed) { Stop-TCLinux InvalidRequest '请求包含不支持的字段；密码和口令只能在认证控制台输入。' }
    }
}

function Assert-TCLinuxId {
    param([string]$Id)
    if ($Id -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') {
        Stop-TCLinux InvalidId '任务标识必须是规范 GUID。'
    }
}

function Get-TCLinuxPath {
    param([string]$Path)
    if ($Path -notmatch '^[A-Za-z]:[\\/]' -or $Path -match '[\x00-\x1f\x7f"*?]' -or $Path.Substring(2).Contains(':')) {
        Stop-TCLinux InvalidPath '必须使用本机绝对路径，不接受 UNC、通配符或控制字符。'
    }
    try { $full = [IO.Path]::GetFullPath($Path).TrimEnd('\') } catch { Stop-TCLinux InvalidPath '路径无效。' }
    $cursor = $full
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { Stop-TCLinux UnsafePath '任务路径不能经过链接或重解析点。' }
        }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ($cursor -eq $parent) { break }
        $cursor = $parent
    }
    return $full
}

function Resolve-TCLinuxRoot {
    param([string]$Root)
    $base = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'TradeChannel'
    if (-not $Root) { $Root = Join-Path $base 'linux-jobs' }
    $full = Get-TCLinuxPath $Root
    $reserved = @($base, [Environment]::GetFolderPath('CommonApplicationData'), [Environment]::GetFolderPath('UserProfile'),
        [Environment]::GetFolderPath('ProgramFiles'), [Environment]::GetFolderPath('Windows'), (Get-Location).Path)
    if ($full.Length -le 3 -or $full -in $reserved -or $full -match '(?i)\\TradeChannel\\(Product|Server)(\\|$)') {
        Stop-TCLinux InvalidRoot 'Linux 任务必须使用独立专用目录，不能使用 Product 或 Server 状态目录。'
    }
    return $full
}

function Get-TCLinuxSids {
    @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'S-1-5-18', 'S-1-5-32-544') | Select-Object -Unique
}

function Protect-TCLinuxPath {
    param([string]$Path, [switch]$Directory)
    $null = Get-TCLinuxPath $Path
    $acl = if ($Directory) { New-Object Security.AccessControl.DirectorySecurity } else { New-Object Security.AccessControl.FileSecurity }
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @(Get-TCLinuxSids)) {
        $identity = New-Object Security.Principal.SecurityIdentifier($sid)
        $rule = if ($Directory) {
            New-Object Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        } else { New-Object Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'Allow') }
        $null = $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
}

function Assert-TCLinuxPrivatePath {
    param([string]$Path)
    $null = Get-TCLinuxPath $Path
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    if (-not $acl.AreAccessRulesProtected) { Stop-TCLinux UnsafeAcl '任务状态必须禁用 ACL 继承。' }
    $allowed = @(Get-TCLinuxSids)
    foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference.Value -notin $allowed) {
            Stop-TCLinux UnsafeAcl '任务状态只允许当前用户、SYSTEM 和管理员访问。'
        }
    }
}

function New-TCLinuxDirectory {
    param([string]$Path)
    $Path = Get-TCLinuxPath $Path
    if (Test-Path -LiteralPath $Path) {
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) { Stop-TCLinux InvalidPath '任务路径必须是目录。' }
        Assert-TCLinuxPrivatePath $Path
        return
    }
    $null = [IO.Directory]::CreateDirectory($Path)
    Protect-TCLinuxPath $Path -Directory
}

function Write-TCLinuxJson {
    # Immutable, same-directory atomic publication. A terminal result is first-
    # writer-wins, including a poller racing a console close/timeout.
    param([string]$Path, $Value, [switch]$IfAbsent)
    $Path = Get-TCLinuxPath $Path
    $parent = [IO.Path]::GetDirectoryName($Path)
    Assert-TCLinuxPrivatePath $parent
    $temp = Join-Path $parent ('.write-' + [guid]::NewGuid().ToString('N'))
    try {
        $file = [IO.File]::Open($temp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $file.Dispose()
        Protect-TCLinuxPath $temp
        [IO.File]::WriteAllText($temp, ($Value | ConvertTo-Json -Depth 24 -Compress), (New-Object Text.UTF8Encoding($true)))
        try { [IO.File]::Move($temp, $Path) } catch {
            if (-not ($IfAbsent -and (Test-Path -LiteralPath $Path -PathType Leaf))) { throw }
            Assert-TCLinuxPrivatePath $Path
        }
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction Stop }
    }
}

function Read-TCLinuxJson {
    param([string]$Path, [int]$MaxBytes = 65536)
    Assert-TCLinuxPrivatePath $Path
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or (Get-Item -LiteralPath $Path -Force).Length -gt $MaxBytes) {
        Stop-TCLinux InvalidState '任务文件缺失或超出允许大小。'
    }
    try { return ([IO.File]::ReadAllText($Path) | ConvertFrom-Json -ErrorAction Stop) }
    catch { Stop-TCLinux InvalidState '任务文件无法解析。' }
}

function Get-TCLinuxHash {
    param([string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function ConvertTo-TCLinuxIPv4 {
    param([string]$Address, [switch]$Public)
    if ($Address -cnotmatch '^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})$') {
        Stop-TCLinux InvalidHost '必须填写规范的 ASCII IPv4 地址。'
    }
    [uint64]$number = 0
    foreach ($part in $Address.Split('.')) {
        if ([int]$part -gt 255) { Stop-TCLinux InvalidHost 'IPv4 地址无效。' }
        $number = $number * 256 + [int]$part
    }
    if ($Public) {
        foreach ($range in @(@(0,16777215),@(167772160,184549375),@(1681915904,1686110207),@(2130706432,2147483647),
            @(2851995648,2852061183),@(2886729728,2887778303),@(3221225472,3221225727),@(3221225984,3221226239),
            @(3227017984,3227018239),@(3232235520,3232301055),@(3323068416,3323199487),@(3325256704,3325256959),
            @(3405803776,3405804031),@(3758096384,4294967295))) {
            if ($number -ge [uint64]$range[0] -and $number -le [uint64]$range[1]) { Stop-TCLinux InvalidHost 'SSH 主机和公开端点必须使用公网单播 IPv4。' }
        }
    }
    return $number
}

function Get-TCLinuxConnection {
    param($Connection)
    Assert-TCLinuxFields $Connection @('Host','Port','User','IdentityFile')
    $address = [string](Get-TCLinuxProperty $Connection Host '')
    $null = ConvertTo-TCLinuxIPv4 $address -Public
    $portText = [string](Get-TCLinuxProperty $Connection Port '22')
    if ($portText -cnotmatch '^[1-9][0-9]{0,4}$' -or [int]$portText -gt 65535) { Stop-TCLinux InvalidPort 'SSH 端口必须是 1 至 65535。' }
    $userName = [string](Get-TCLinuxProperty $Connection User 'root')
    if ($userName -cnotmatch '^[a-z_][a-z0-9_-]{0,31}$') { Stop-TCLinux InvalidUser 'SSH 用户名必须是安全的 Linux 账户名。' }
    $identity = [string](Get-TCLinuxProperty $Connection IdentityFile '')
    if ($identity) {
        $identity = Get-TCLinuxPath $identity
        if (-not (Test-Path -LiteralPath $identity -PathType Leaf) -or (Get-Item -LiteralPath $identity -Force).Length -gt 1MB) {
            Stop-TCLinux InvalidIdentity 'SSH 密钥必须是现有本机小文件。桥接不会读取或缓存其内容。'
        }
    }
    if ($userName -cne 'root' -and -not $identity) { Stop-TCLinux SudoRequiresKey '首版非 root 账户必须使用 SSH 密钥，并预先具备 sudo -n 权限；不代输 sudo 密码。' }
    [pscustomobject][ordered]@{ Host = $address; Port = [int]$portText; User = $userName; IdentityFile = $identity }
}

function Assert-TCLinuxPlanInput {
    param([string]$Name, [string]$PublicEndpoint, [string]$TunnelSubnet)
    if (-not $Name -or $Name.Length -gt 64 -or $Name.Trim() -cne $Name -or $Name -match '[\x00-\x1f\x7f]') { Stop-TCLinux InvalidName '节点名称必须是 1 至 64 个可显示字符。' }
    if ($PublicEndpoint -cnotmatch '^([^:]+):([1-9][0-9]{0,4})$') { Stop-TCLinux InvalidEndpoint '公开端点必须是 IPv4:UDP端口。' }
    $address = $Matches[1]; $port = [int]$Matches[2]
    $null = ConvertTo-TCLinuxIPv4 $address -Public
    if ($port -gt 65535) { Stop-TCLinux InvalidEndpoint 'UDP 端口必须是 1 至 65535。' }
    if ($TunnelSubnet -cnotmatch '^([^/]+)/(1[6-9]|2[0-9]|30)$') { Stop-TCLinux InvalidSubnet '隧道必须是 /16 至 /30 的 RFC1918 网络地址。' }
    $ip = ConvertTo-TCLinuxIPv4 $Matches[1]; $prefix = [int]$Matches[2]
    [uint64]$size = [math]::Pow(2,32-$prefix)
    $private = ($ip -ge 167772160 -and $ip + $size - 1 -le 184549375) -or
        ($ip -ge 2886729728 -and $ip + $size - 1 -le 2887778303) -or
        ($ip -ge 3232235520 -and $ip + $size - 1 -le 3232301055)
    if (($ip % $size) -ne 0 -or -not $private) { Stop-TCLinux InvalidSubnet '隧道必须是规范 RFC1918 网络地址。' }
}

function Get-TCLinuxClientModule {
    if ($null -eq $script:TCLinuxClientModule) {
        $script:TCLinuxClientModule = Import-Module (Join-Path $PSScriptRoot 'ServerSetup.psm1') -PassThru -DisableNameChecking -ErrorAction Stop
    }
    return $script:TCLinuxClientModule
}

function New-TCLinuxClientRequest {
    param([string]$Directory, [string]$WgPath)
    if (-not $WgPath) { $WgPath = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'WireGuard\wg.exe' }
    $module = Get-TCLinuxClientModule
    & $module { param($Directory,$WgPath) New-TCClientRequest -OutputDirectory $Directory -WgPath $WgPath } $Directory $WgPath
}

function Read-TCLinuxClientRequest {
    param([string]$Directory)
    Assert-TCLinuxPrivatePath $Directory
    $request = Read-TCLinuxJson (Join-Path $Directory 'public.request.json') 16384
    Assert-TCLinuxFields $request @('SchemaVersion','Kind','RequestId','DeviceId','CreatedAtUtc','ClientPublicKey','AddressFamilies')
    if ($request.SchemaVersion -ne 1 -or $request.Kind -cne 'TradeChannel.ClientRequest' -or (@($request.AddressFamilies) -join ',') -cne 'IPv4' -or
        $request.ClientPublicKey -cnotmatch '^[A-Za-z0-9+/]{43}=$') { Stop-TCLinux InvalidRequest '本机公开设备申请无效。' }
    Assert-TCLinuxId $request.RequestId; Assert-TCLinuxId $request.DeviceId
    $request.CreatedAtUtc = ConvertTo-TCLinuxUtcIso $request.CreatedAtUtc
    return $request
}

function Get-TCLinuxBackend {
    $path = Get-TCLinuxPath (Join-Path $PSScriptRoot 'linux\tradechannel_linux.py')
    if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Item -LiteralPath $path).Length -gt 2MB) {
        Stop-TCLinux BackendMissing '缺少随产品交付的 Linux Python 后端，或文件大小不受支持。'
    }
    $source = [IO.File]::ReadAllText($path)
    if (-not $source) { Stop-TCLinux BackendMissing 'Linux 后端文件为空。' }
    $supportPath=Join-Path $PSScriptRoot 'linux\transport_support.py'
    if(-not (Test-Path -LiteralPath $supportPath)){Stop-TCLinux BackendMissing '缺少 TCP 服务端组件，请重新解压完整包。'}
    $support=[IO.File]::ReadAllText($supportPath)
    if([Text.Encoding]::UTF8.GetByteCount($support) -gt 131072){Stop-TCLinux BackendMissing 'TCP 支持组件大小不受支持。'}
    $literal=ConvertTo-Json -InputObject $support -Compress
    $prefix='import sys,types; _tcp=types.ModuleType("transport_support"); _tcp.__file__="transport_support.py"; sys.modules["transport_support"]=_tcp; exec(compile('+$literal+',"transport_support.py","exec"),_tcp.__dict__)'+"`n"
    $source=$prefix+$source
    $managementPath=Join-Path $PSScriptRoot 'linux\management_support.py'
    if(-not (Test-Path -LiteralPath $managementPath -PathType Leaf)){Stop-TCLinux BackendMissing '缺少服务器管理组件，请重新解压完整包。'}
    $management=[IO.File]::ReadAllText($managementPath)
    if([Text.Encoding]::UTF8.GetByteCount($management) -gt 1MB){Stop-TCLinux BackendMissing '服务器管理组件大小不受支持。'}
    $managementLiteral=ConvertTo-Json -InputObject $management -Compress
    $managementPrefix='import sys,types; _mgmt=types.ModuleType("management_support"); _mgmt.__file__="management_support.py"; sys.modules["management_support"]=_mgmt; exec(compile('+$managementLiteral+',"management_support.py","exec"),_mgmt.__dict__)'+"`n"
    $source=$managementPrefix+$source
    [pscustomobject]@{ Source = $source; SourceSHA256 = (Get-TCLinuxHash $source) }
}

function Get-TCLinuxBootstrap {
    # Every byte is trusted constant text; no host, user, name, path, input or
    # backend source is interpolated into the remote shell command.
    $python = 'import sys,json,hashlib,io; p=json.loads(sys.stdin.buffer.read(4194305).decode("utf-8")); s=p["Source"]; (hashlib.sha256(s.encode("utf-8")).hexdigest()==p["SourceSHA256"]) or sys.exit(76); a=p["Action"]; (a in ("inspect","plan","apply","status","authorize","recover","finalize","capabilities","server_info","devices","device_rename","management_plan","management_apply","invite_create","invite_cancel","invite_status","authorize_external","request_status","revoke_preview","revoke","uninstall_preview","uninstall","transport_plan","transport_apply")) or sys.exit(77); sys.argv=["tradechannel_linux.py",a,"--input","-"]; sys.stdin=io.StringIO(json.dumps(p["Input"])); exec(compile(s,"tradechannel_linux.py","exec"),{"__name__":"__main__","__file__":"tradechannel_linux.py"})'
    return ('python3 -I -c ' + "'" + $python + "'")
}

function ConvertTo-TCLinuxArgument {
    param([string]$Value)
    if ($Value -match '[\x00\r\n]') { Stop-TCLinux InvalidArgument '进程参数包含控制字符。' }
    return ('"' + ([regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1')) + '"')
}

function Get-TCLinuxTransportPlan {
    param($Connection, [string]$KnownHostsPath)
    $connection = Get-TCLinuxConnection $Connection
    $knownHosts = Get-TCLinuxPath $KnownHostsPath
    $ssh = Join-Path ([Environment]::GetFolderPath('Windows')) 'System32\OpenSSH\ssh.exe'
    $command = Get-TCLinuxBootstrap
    if ($connection.User -cne 'root') { $command = 'sudo -n -- ' + $command }
    $arguments = @('-F','NUL','-T','-o','StrictHostKeyChecking=ask','-o',('UserKnownHostsFile="' + $knownHosts.Replace('\','/') + '"'),
        '-o','GlobalKnownHostsFile=none','-o','UpdateHostKeys=no','-o','VerifyHostKeyDNS=no','-o','BatchMode=no',
        '-o','ConnectTimeout=20','-o','ConnectionAttempts=1','-o','ServerAliveInterval=15','-o','ServerAliveCountMax=3',
        '-o','NumberOfPasswordPrompts=3','-o','ForwardAgent=no','-o','ClearAllForwardings=yes','-o','PermitLocalCommand=no',
        '-o','ControlMaster=no','-o','ControlPath=none','-o','ProxyCommand=none','-o','ProxyJump=none','-o','IdentityAgent=none',
        '-o','IdentitiesOnly=yes','-o','LogLevel=INFO')
    if ($connection.IdentityFile) { $arguments += @('-o','PreferredAuthentications=publickey','-i',$connection.IdentityFile) }
    else { $arguments += @('-o','PreferredAuthentications=keyboard-interactive,password') }
    $arguments += @('-p',[string]$connection.Port,'-l',$connection.User,'--',$connection.Host,$command)
    [pscustomobject]@{ FileName = $ssh; Arguments = $arguments; CommandLine = (($arguments | ForEach-Object { ConvertTo-TCLinuxArgument $_ }) -join ' '); RemoteCommand = $command }
}

function Start-TCLinuxConsole {
    param([string]$Id, [string]$Root)
    $powershell = Join-Path ([Environment]::GetFolderPath('Windows')) 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $console = Join-Path $PSScriptRoot 'linux\Invoke-LinuxConsole.ps1'
    $arguments = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$console,'-Id',$Id,'-Root',$Root)
    $process = Start-Process -FilePath $powershell -ArgumentList (($arguments | ForEach-Object { ConvertTo-TCLinuxArgument $_ }) -join ' ') -WindowStyle Normal -PassThru -ErrorAction Stop
    try { [pscustomobject]@{ ProcessId = $process.Id; StartTimeUtcTicks = [string]$process.StartTime.ToUniversalTime().Ticks } }
    finally { $process.Dispose() }
}

function Test-TCLinuxConsoleProcess {
    param($Receipt)
    try {
        $process = Get-Process -Id ([int]$Receipt.ProcessId) -ErrorAction Stop
        try { return (-not $process.HasExited -and [string]$process.StartTime.ToUniversalTime().Ticks -ceq [string]$Receipt.StartTimeUtcTicks) }
        finally { $process.Dispose() }
    } catch { return $false }
}

function Get-TCLinuxJobRecord {
    param([string]$Id, [string]$Root)
    Assert-TCLinuxId $Id
    $directory = Join-Path $Root $Id
    Assert-TCLinuxPrivatePath $Root; Assert-TCLinuxPrivatePath $directory
    $job = Read-TCLinuxJson (Join-Path $directory 'job.json')
    if ($job.SchemaVersion -ne 1 -or $job.JobId -cne $Id -or $job.Operation -cnotin @('Inspect','Plan','Apply','Status','Authorize','Recover','Finalize')) {
        Stop-TCLinux InvalidState '任务记录与所选操作不匹配。'
    }
    return $job
}

function Get-TCLinuxRequestDirectory {
    param($Job, [string]$Root)
    $requestJobId = [string]$Job.RequestJobId
    Assert-TCLinuxId $requestJobId
    if (-not (Test-Path -LiteralPath (Join-Path $Root $requestJobId))) {
        Stop-TCLinux RequestMissing '本机原始申请与私钥目录不存在（可能已被清理）。由于云端服务器已完成部署，请点击「为本机重新生成授权」完成自动并线。'
    }
    $owner = Get-TCLinuxJobRecord $requestJobId $Root
    if ($owner.Operation -notin @('Plan','Authorize') -or $owner.RequestJobId -cne $requestJobId -or $owner.RequestId -cne $Job.RequestId) {
        Stop-TCLinux RequestMismatch '任务未绑定原始本机设备申请。'
    }
    $directory = Join-Path (Join-Path $Root $requestJobId) 'client'
    $request = Read-TCLinuxClientRequest $directory
    if ($request.RequestId -cne $Job.RequestId -or (Get-TCLinuxHash ($request | ConvertTo-Json -Depth 8 -Compress)) -cne $Job.RequestHash) {
        Stop-TCLinux RequestMismatch '本机设备申请已改变；拒绝复用此计划。'
    }
    return $directory
}

function ConvertTo-TCLinuxMessage {
    param([string]$Message)
    if ($Message.Length -gt 600) { return '远端后端拒绝操作；返回的说明过长，请检查服务器状态。' }
    $safe = $Message -replace '[\x00-\x1f\x7f]', ' '
    $safe = $safe -replace '(?i)(private.?key|password|passphrase|preshared.?key|secret|token)\s*[=:]\s*("[^"]*"|\S+)', '$1=<隐藏>'
    $safe = $safe -replace '[A-Za-z0-9+/]{43}=', '<密钥已隐藏>'
    if (-not $safe.Trim()) { return '远端后端未提供操作说明。' }
    return $safe
}

function Assert-TCLinuxPublicData {
    param($Value, [int]$Depth = 0)
    if ($Depth -gt 16) { Stop-TCLinux InvalidEnvelope '后端返回内容嵌套过深。' }
    if ($null -eq $Value -or $Value -is [ValueType]) { return }
    if ($Value -is [string]) {
        if ($Value.Length -gt 32768 -or $Value -match '(?i)(-----BEGIN [^-]*PRIVATE KEY-----|\b(private.?key|password|passphrase|preshared.?key)\s*[=:])') {
            Stop-TCLinux UnsafeResponse '后端响应包含不允许的私密内容。'
        }
        return
    }
    if ($Value -is [array]) {
        if ($Value.Count -gt 512) { Stop-TCLinux InvalidEnvelope '后端返回列表过大。' }
        foreach ($entry in $Value) { Assert-TCLinuxPublicData $entry ($Depth + 1) }
        return
    }
    foreach ($property in $Value.PSObject.Properties) {
        if ($property.Name -match '(?i)(private.?key|password|passphrase|preshared.?key|secret|credential|stdout|stderr)') {
            Stop-TCLinux UnsafeResponse '后端响应含私密或原始输出字段，未保存或展示。'
        }
        Assert-TCLinuxPublicData $property.Value ($Depth + 1)
    }
}

function New-TCLinuxTerminalResult {
    param($Job, [string]$Status, [string]$Code, [string]$Message, $Data = $null, [bool]$OutcomeUnknown = $false,
        [string]$Stage = 'Console', [Nullable[int]]$ExitCode = $null)
    [pscustomobject][ordered]@{ SchemaVersion = 1; JobId = $Job.JobId; Status = $Status; Operation = $Job.Operation;
        Data = $Data; Message = $Message; ErrorCode = $Code; Stage = $Stage; ExitCode = $ExitCode;
        OutcomeUnknown = $OutcomeUnknown; FinishedAtUtc = [DateTime]::UtcNow.ToString('o') }
}

function Set-TCLinuxFailure {
    param($Job, [string]$Root, [string]$Code, [string]$Message, [bool]$OutcomeUnknown = $false, $Data = $null,
        [string]$Stage = 'Console', [Nullable[int]]$ExitCode = $null)
    $result = New-TCLinuxTerminalResult $Job Failed $Code $Message $Data $OutcomeUnknown $Stage $ExitCode
    Write-TCLinuxJson (Join-Path (Join-Path $Root $Job.JobId) 'result.json') $result -IfAbsent
}

function Add-TCLinuxJobContext {
    param($Result, $Job)
    foreach ($entry in @('Connection','Name','PublicEndpoint','TunnelSubnet','ParentJobId','PlanId')) {
        $Result | Add-Member -NotePropertyName $entry -NotePropertyValue $Job.$entry -Force
    }
    $Result | Add-Member -NotePropertyName CreatedAt -NotePropertyValue (ConvertTo-TCLinuxUtcIso $Job.CreatedAtUtc) -Force
    if ($Result.PSObject.Properties['FinishedAtUtc']) { $Result.FinishedAtUtc = ConvertTo-TCLinuxUtcIso $Result.FinishedAtUtc }
    if ($null -ne $Result.Data -and $Result.Data.PSObject.Properties['PlanExpiresAt']) {
        $Result.Data.PlanExpiresAt = ConvertTo-TCLinuxUtcIso $Result.Data.PlanExpiresAt
    }
    if (-not $Result.PSObject.Properties['Stage']) {
        $stage = if ($Result.Status -eq 'Completed') { 'Completed' } elseif ($Result.Status -eq 'Running') { 'Transport' } else { 'Console' }
        $Result | Add-Member -NotePropertyName Stage -NotePropertyValue $stage
    }
    if (-not $Result.PSObject.Properties['ExitCode']) { $Result | Add-Member -NotePropertyName ExitCode -NotePropertyValue $null }
    return $Result
}

function Get-TCLinuxJob {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Id, [string]$Root)
    $ErrorActionPreference = 'Stop'
    $rootPath = Resolve-TCLinuxRoot $Root
    $job = Get-TCLinuxJobRecord $Id $rootPath
    $directory = Join-Path $rootPath $Id
    $resultPath = Join-Path $directory 'result.json'
    if (-not (Test-Path -LiteralPath $resultPath)) {
        $unknown = $job.Operation -in @('Apply','Authorize','Recover','Finalize')
        $created = ConvertTo-TCLinuxUtcTime $job.CreatedAtUtc
        $deadline = ConvertTo-TCLinuxUtcTime $job.DeadlineUtc
        if ([DateTimeOffset]::UtcNow -gt $deadline) {
            Set-TCLinuxFailure $job $rootPath JobTimeout '认证或执行会话已超时。若执行过写入，请先查询 Status；不会自动重试。' $unknown
        } elseif (Test-Path -LiteralPath (Join-Path $directory 'process.json')) {
            $receipt = Read-TCLinuxJson (Join-Path $directory 'process.json')
            if (-not (Test-TCLinuxConsoleProcess $receipt)) {
                Set-TCLinuxFailure $job $rootPath ConsoleClosed '认证控制台已关闭。远端操作结果可能尚未确认；请先查询 Status，不要重复提交部署。' $unknown
            }
        } elseif (([DateTimeOffset]::UtcNow - $created).TotalSeconds -gt 60) {
            Set-TCLinuxFailure $job $rootPath ConsoleNotStarted '认证控制台未能启动，任务已结束。' $false
        }
    }
    if (Test-Path -LiteralPath $resultPath) {
        $result = Read-TCLinuxJson $resultPath (2 * $script:TCLinuxMaxResult)
        if ($result.JobId -cne $Id -or $result.Operation -cne $job.Operation -or $result.Status -cnotin @('Completed','Failed')) { Stop-TCLinux InvalidState '任务结果无效。' }
        Assert-TCLinuxPublicData $result.Data
        return (Add-TCLinuxJobContext $result $job)
    }
    $status = if (Test-Path -LiteralPath (Join-Path $directory 'running.json')) { 'Running' } else { 'Pending' }
    Add-TCLinuxJobContext ([pscustomobject]@{ JobId = $Id; Status = $status; Operation = $job.Operation; Data = $null; Message = '请在独立认证控制台完成主机指纹核对及 SSH 登录。'; ErrorCode = ''; OutcomeUnknown = $false }) $job
}

function Get-TCLinuxRecentJobs {
    param([string]$Root,[switch]$IncludeArchived,[ValidateRange(1,200)][int]$Limit=10)
    $rootPath = Resolve-TCLinuxRoot $Root
    if (-not (Test-Path -LiteralPath $rootPath)) { return [pscustomobject]@{ Items = @() } }
    Assert-TCLinuxPrivatePath $rootPath
    $items = New-Object 'Collections.Generic.List[object]'
    # No recursive scan, payload/key reads, console creation or remote access.
    $candidates = @(Get-ChildItem -LiteralPath $rootPath -Directory -Force -ErrorAction Stop |
        Where-Object { $_.Name -cmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' } |
        Sort-Object CreationTimeUtc -Descending | Select-Object -First 1000)
    foreach ($candidate in $candidates) {
        try {
            $archived=Test-TCLinuxJobArchived $rootPath $candidate.Name
            if($archived -and -not $IncludeArchived){continue}
            $job = Get-TCLinuxJob -Id $candidate.Name -Root $rootPath
            $status = if ($job.Status -eq 'Pending') { 'Running' } else { $job.Status }
            $items.Add([pscustomobject]@{ JobId = $job.JobId; Operation = $job.Operation; Status = $status; CreatedAt = $job.CreatedAt; Host = $job.Connection.Host; Name = $job.Name; OutcomeUnknown=[bool]$job.OutcomeUnknown;Archived=$archived })
        } catch { continue } # foreign ACLs, malformed or incomplete creations
        if ($items.Count -ge $Limit) { break }
    }
    [pscustomobject]@{ Items = @($items.ToArray()) }
}

function New-TCLinuxJob {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][ValidateSet('Inspect','Plan','Apply','Status','Authorize','Recover','Finalize')][string]$Action,
        $Connection, [string]$Name, [string]$PublicEndpoint, [string]$TunnelSubnet = '10.78.0.0/24',
        [Alias('ParentJobId')][string]$JobId, [string]$PlanId, [string]$ClientAddress, [string]$Root, [string]$WgPath,[switch]$NetworkProbe,[ValidateRange(0,60)][int]$CaptureSeconds=0,
        [ValidateSet(0,443)][int]$ProbeRelayPort=0,[string]$ProbeSourceIPv4,$Transport)
    $ErrorActionPreference = 'Stop'
    $Action = $Action.Substring(0,1).ToUpperInvariant() + $Action.Substring(1).ToLowerInvariant()
    if($PSBoundParameters.ContainsKey('Transport')){
        if($Action -ne 'Plan'){Stop-TCLinux PlanMismatch 'TCP 设置只能在生成 Plan 时提交；Apply 绑定原计划。'}
        Assert-TCLinuxFields $Transport @('Type','Port','ServerName')
        $tcpPort=0
        if($Transport.Type -cne 'tcp-reality' -or -not [int]::TryParse([string]$Transport.Port,[ref]$tcpPort) -or $tcpPort -lt 1 -or $tcpPort -gt 65535 -or [string]$Transport.ServerName -cnotmatch '^(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$'){Stop-TCLinux InvalidTransport '请填写有效的 TCP 端口及 Reality 伪装域名。'}
        $Transport=[ordered]@{Type='tcp-reality';Port=$tcpPort;ServerName=[string]$Transport.ServerName}
    }
    if($NetworkProbe -and $Action -ne 'Status'){Stop-TCLinux InvalidRequest '网络诊断只接受 Status，不随部署动作运行。'}
    if($PSBoundParameters.ContainsKey('CaptureSeconds') -and (-not $NetworkProbe -or $Action -ne 'Status')){Stop-TCLinux InvalidRequest '包头观察只用于 Status 网络诊断。'}
    if($ProbeRelayPort -or $ProbeSourceIPv4){
        if($Action -ne 'Status' -or -not $NetworkProbe -or $CaptureSeconds -lt 1 -or $ProbeRelayPort -ne 443 -or -not $ProbeSourceIPv4){Stop-TCLinux InvalidRequest '临时端口对照仅接受限时 Status 诊断、UDP 443 和指定来源公网 IPv4。'}
        $null=ConvertTo-TCLinuxIPv4 $ProbeSourceIPv4 -Public
    }
    $rootPath = Resolve-TCLinuxRoot $Root
    $parent = $null; $planData = $null; $request = $null; $requestJobId = ''; $requestHash = ''
    if ($Action -in @('Apply','Finalize')) {
        if (-not $JobId) { Stop-TCLinux PlanRequired 'Apply 必须引用已预览完成的 Plan 任务。' }
        if ($null -ne $Connection -or $PSBoundParameters.ContainsKey('Name') -or $PSBoundParameters.ContainsKey('PublicEndpoint') -or
            $PSBoundParameters.ContainsKey('TunnelSubnet') -or $ClientAddress) { Stop-TCLinux PlanMismatch 'Apply 只接受原 Plan 的 ParentJobId 和 PlanId，不能替换连接或计划内容。' }
        $parent = Get-TCLinuxJobRecord $JobId $rootPath
        $preview = Get-TCLinuxJob -Id $JobId -Root $rootPath
        if ($parent.Operation -cne 'Plan' -or $preview.Status -cne 'Completed' -or (Get-TCLinuxProperty $preview.Data Supported) -ne $true) {
            Stop-TCLinux PlanRequired '只能应用已成功完成且受支持的 Plan 预览。'
        }
        $planData = $preview.Data
        Assert-TCLinuxId ([string]$planData.PlanId)
        if ($PlanId -and $PlanId -cne $planData.PlanId) { Stop-TCLinux PlanMismatch 'PlanId 与原预览不一致。' }
        try { $expires = ConvertTo-TCLinuxUtcTime $planData.PlanExpiresAt } catch { Stop-TCLinux InvalidPlan 'Plan 缺少有效截止时间。' }
        if ($Action -eq 'Apply' -and $expires -le [DateTimeOffset]::UtcNow) { Stop-TCLinux PlanExpired 'Plan 已过期，请重新生成并预览。' }
        $PlanId = $planData.PlanId; $Name = $parent.Name; $PublicEndpoint = $parent.PublicEndpoint; $TunnelSubnet = $parent.TunnelSubnet
        $Connection = Get-TCLinuxConnection $parent.Connection
        $request = Read-TCLinuxClientRequest (Get-TCLinuxRequestDirectory $parent $rootPath)
        $requestJobId = $parent.RequestJobId; $requestHash = $parent.RequestHash
    } elseif ($Action -eq 'Recover' -and $JobId) {
        if ($null -ne $Connection -or $PSBoundParameters.ContainsKey('Name') -or $PSBoundParameters.ContainsKey('PublicEndpoint') -or
            $PSBoundParameters.ContainsKey('TunnelSubnet') -or $ClientAddress) { Stop-TCLinux PlanMismatch '绑定任务的 Recover 不接受替换连接或计划内容。' }
        $context = Get-TCLinuxJobRecord $JobId $rootPath
        $contextResult = Get-TCLinuxJob -Id $JobId -Root $rootPath
        if ($context.Operation -notin @('Plan','Apply') -or $contextResult.Status -notin @('Completed','Failed')) {
            Stop-TCLinux PlanRequired 'Recover 必须引用已结束的 Plan 或 Apply 任务，不能与部署并发。'
        }
        $storedPlanId = [string]$context.PlanId
        if ($context.Operation -eq 'Plan') {
            if ($contextResult.Status -cne 'Completed') { Stop-TCLinux PlanRequired 'Recover 引用的 Plan 尚未成功完成。' }
            $storedPlanId = [string](Get-TCLinuxProperty $contextResult.Data PlanId '')
        }
        Assert-TCLinuxId $storedPlanId
        if ($PlanId -and $PlanId -cne $storedPlanId) { Stop-TCLinux PlanMismatch 'Recover 的 PlanId 与原任务不一致。' }
        $PlanId = $storedPlanId; $Name = $context.Name; $PublicEndpoint = $context.PublicEndpoint; $TunnelSubnet = $context.TunnelSubnet
        $Connection = Get-TCLinuxConnection $context.Connection
        # Do not reuse $parent: only Apply claims the single-submission receipt.
    } else {
        if ($JobId -or $PlanId) { Stop-TCLinux InvalidRequest '只有 Apply 或 Recover 接受 ParentJobId/PlanId。' }
        $Connection = Get-TCLinuxConnection $Connection
        if ($Action -eq 'Plan') { Assert-TCLinuxPlanInput $Name $PublicEndpoint $TunnelSubnet }
        if ($Action -eq 'Authorize' -and $ClientAddress -and $ClientAddress -cnotmatch '^[0-9.]+(/32)?$') { Stop-TCLinux InvalidAddress '授权地址必须是 IPv4 或 IPv4/32。' }
    }
    $backend = Get-TCLinuxBackend
    New-TCLinuxDirectory $rootPath
    $lockPath = Join-Path $rootPath '.bridge.lock'
    try { $lock = [IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
    catch { Stop-TCLinux Busy '正在创建另一任务，请稍后重试。' }
    try {
        Protect-TCLinuxPath $lockPath
        if ($parent) {
            $claimPath = Join-Path (Join-Path $rootPath $parent.JobId) $(if($Action -eq 'Finalize'){'finalize-job.json'}else{'apply-job.json'})
            if (Test-Path -LiteralPath $claimPath) {
                $claim = Read-TCLinuxJson $claimPath
                return (Get-TCLinuxJob -Id $claim.JobId -Root $rootPath)
            }
        }
        $id = [guid]::NewGuid().ToString()
        $directory = Join-Path $rootPath $id
        New-TCLinuxDirectory $directory
        if ($Action -in @('Plan','Authorize')) {
            $clientDirectory = Join-Path $directory 'client'
            $null = New-TCLinuxClientRequest $clientDirectory $WgPath
            $request = Read-TCLinuxClientRequest $clientDirectory
            $requestJobId = $id; $requestHash = Get-TCLinuxHash ($request | ConvertTo-Json -Depth 8 -Compress)
        }
        $inputObject = switch ($Action) {
            Plan { $value=[ordered]@{Name=$Name;PublicEndpoint=$PublicEndpoint;TunnelSubnet=$TunnelSubnet;ClientRequest=$request};if($Transport){$value.Transport=$Transport};$value }
            Apply { [ordered]@{ PlanId = $PlanId } }
            Finalize { [ordered]@{ PlanId = $PlanId } }
            Status { if($NetworkProbe){$probeInput=[ordered]@{NetworkProbe=$true};if($CaptureSeconds -gt 0){$probeInput.CaptureSeconds=$CaptureSeconds};if($ProbeRelayPort){$probeInput.ProbeRelayPort=$ProbeRelayPort;$probeInput.ProbeSourceIPv4=$ProbeSourceIPv4};$probeInput}else{[ordered]@{}} }
            Authorize {
                $value = [ordered]@{ ClientRequest = $request }
                if ($ClientAddress) { $value.ClientAddress = $ClientAddress }
                $value
            }
            default { [ordered]@{} }
        }
        $job = [pscustomobject][ordered]@{ SchemaVersion = 1; JobId = $id; Operation = $Action; Connection = $Connection; Name = $Name;
            PublicEndpoint = $PublicEndpoint; TunnelSubnet = $TunnelSubnet; ParentJobId = $JobId; PlanId = $PlanId;
            RequestJobId = $requestJobId; RequestId = $(if ($request) { $request.RequestId } else { '' }); RequestHash = $requestHash;
            CreatedAtUtc = [DateTime]::UtcNow.ToString('o'); DeadlineUtc = [DateTime]::UtcNow.AddSeconds($script:TCLinuxLifetimeSeconds).ToString('o') }
        if($Transport){$job|Add-Member NoteProperty Transport $Transport}
        $payload = [ordered]@{ SchemaVersion = 1; Source = $backend.Source; SourceSHA256 = $backend.SourceSHA256; Action = $Action.ToLowerInvariant(); Input = $inputObject }
        Write-TCLinuxJson (Join-Path $directory 'payload.json') $payload
        Write-TCLinuxJson (Join-Path $directory 'job.json') $job
        if ($parent) { Write-TCLinuxJson $claimPath ([ordered]@{ JobId = $id; PlanId = $PlanId }) }
        $knownHosts = Join-Path $rootPath 'known_hosts'
        if (-not (Test-Path -LiteralPath $knownHosts)) {
            $file = [IO.File]::Open($knownHosts,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
            $file.Dispose(); Protect-TCLinuxPath $knownHosts
        }
        Assert-TCLinuxPrivatePath $knownHosts
        try {
            $process = Start-TCLinuxConsole $id $rootPath
            Write-TCLinuxJson (Join-Path $directory 'process.json') $process
        } catch {
            Set-TCLinuxFailure $job $rootPath ConsoleStartFailed '无法启动独立认证控制台；请重新打开向导检查任务状态。' ($Action -in @('Apply','Authorize','Recover','Finalize'))
        }
        return (Get-TCLinuxJob -Id $id -Root $rootPath)
    } finally { $lock.Dispose() }
}

function Invoke-TCLinuxNativeTransport {
    # Runs only inside the visible console, never inside the WPF Worker. stdin
    # carries UTF-8 payload; stdout is bounded and private; stderr/CON prompts
    # stay attached to that console. No shell, transcript, askpass or password cache.
    param($Plan, [string]$Payload, [DateTimeOffset]$Deadline)
    if (-not (Test-Path -LiteralPath $Plan.FileName -PathType Leaf)) { Stop-TCLinux SshMissing '未找到 Windows System32 OpenSSH 客户端。' }
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $Plan.FileName; $start.Arguments = $Plan.CommandLine
    $start.UseShellExecute = $false; $start.CreateNoWindow = $false
    $start.RedirectStandardInput = $true; $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $false
    $start.StandardOutputEncoding = New-Object Text.UTF8Encoding($false,$true)
    $start.EnvironmentVariables['SSH_ASKPASS_REQUIRE'] = 'never'
    $start.EnvironmentVariables.Remove('SSH_ASKPASS'); $start.EnvironmentVariables.Remove('DISPLAY')
    $process = New-Object Diagnostics.Process; $process.StartInfo = $start
    try {
        # .NET Framework's stdin writer otherwise emits Console.InputEncoding's
        # BOM even when its BaseStream is used. The console is single-job only.
        $oldEncoding = [Console]::InputEncoding
        try {
            [Console]::InputEncoding = New-Object Text.UTF8Encoding($false)
            if (-not $process.Start()) { Stop-TCLinux SshStartFailed '无法启动 SSH 客户端。' }
            $stdin = $process.StandardInput.BaseStream
        } finally { [Console]::InputEncoding = $oldEncoding }
        $bytes = [Text.Encoding]::UTF8.GetBytes($Payload)
        $write = $stdin.WriteAsync($bytes,0,$bytes.Length)
        $buffer = New-Object char[] 4096
        $read = $process.StandardOutput.ReadAsync($buffer,0,$buffer.Length)
        $output = New-Object Text.StringBuilder
        $inputClosed = $false; $ended = $false
        while (-not $ended -or -not $process.HasExited) {
            if ([DateTimeOffset]::UtcNow -ge $Deadline) { Stop-TCLinux JobTimeout '认证或执行会话已超时；远端结果需通过 Status 确认。' }
            if (-not $inputClosed -and $write.IsCompleted) {
                # Broken input can be a normal early remote rejection; classify
                # from the exit code/envelope below instead of leaking exceptions.
                $null = $write.Exception
                $stdin.Close(); $inputClosed = $true
            }
            if (-not $ended -and $read.IsCompleted) {
                if ($read.IsFaulted -or $read.IsCanceled) { Stop-TCLinux InvalidEnvelope 'SSH 返回内容不是有效 UTF-8。' }
                $count = $read.Result
                if ($count -eq 0) { $ended = $true } else {
                    if ($output.Length + $count -gt $script:TCLinuxMaxResult) { Stop-TCLinux OutputLimit 'SSH 返回内容超过允许大小，未保存原始输出。' }
                    $null = $output.Append($buffer,0,$count)
                    $read = $process.StandardOutput.ReadAsync($buffer,0,$buffer.Length)
                }
            }
            if (-not $ended -or -not $process.HasExited) { Start-Sleep -Milliseconds 40 }
        }
        [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $output.ToString() }
    } finally {
        try { if (-not $process.HasExited) { $process.Kill() } } catch { }
        $process.Dispose()
    }
}

function ConvertFrom-TCLinuxEnvelope {
    param([string]$Text, [string]$Operation)
    if (-not $Text -or [Text.Encoding]::UTF8.GetByteCount($Text) -gt $script:TCLinuxMaxResult) { Stop-TCLinux InvalidEnvelope 'SSH 未返回有效的有界 JSON 响应。' }
    try { $envelope = $Text | ConvertFrom-Json -ErrorAction Stop } catch { Stop-TCLinux InvalidEnvelope 'SSH 返回内容不符合后端 JSON 协议；原始输出未展示或保存。' }
    if ($envelope -isnot [pscustomobject] -or (Get-TCLinuxProperty $envelope Ok) -isnot [bool] -or
        [string](Get-TCLinuxProperty $envelope Action '') -cne $Operation.ToLowerInvariant()) { Stop-TCLinux InvalidEnvelope '后端响应的操作或结果标识不匹配。' }
    $data = Get-TCLinuxProperty $envelope Data
    Assert-TCLinuxPublicData $data
    if ($envelope.Ok -and $null -eq $data) { Stop-TCLinux InvalidEnvelope '后端成功响应缺少 Data。' }
    return $envelope
}

function Assert-TCLinuxPlanReply {
    param($Job, $Data)
    if ((Get-TCLinuxProperty $Data Supported) -isnot [bool]) { Stop-TCLinux InvalidPlan 'Plan 响应缺少 Supported 标识。' }
    if (-not $Data.Supported) { return }
    Assert-TCLinuxId ([string](Get-TCLinuxProperty $Data PlanId ''))
    if ([string](Get-TCLinuxProperty $Data Name '') -cne $Job.Name -or [string](Get-TCLinuxProperty $Data PublicEndpoint '') -cne $Job.PublicEndpoint) {
        Stop-TCLinux PlanMismatch '服务器返回的计划与所选名称或公网端点不一致。'
    }
    try { $expires = ConvertTo-TCLinuxUtcTime (Get-TCLinuxProperty $Data PlanExpiresAt '') } catch { Stop-TCLinux InvalidPlan 'Plan 缺少有效截止时间。' }
    if ($expires -le [DateTimeOffset]::UtcNow -or (Get-TCLinuxProperty $Data RequiresCloudFirewall) -ne $true) { Stop-TCLinux InvalidPlan 'Plan 已过期或未提供云防火墙提示。' }
    $Data.PlanExpiresAt = ConvertTo-TCLinuxUtcIso $expires
    foreach ($field in @('OS','Steps','ServerAddress','ClientAddress','Warnings')) {
        if ($null -eq $Data.PSObject.Properties[$field]) { Stop-TCLinux InvalidPlan 'Plan 预览字段不完整。' }
    }
}

function Save-TCLinuxClientResponse {
    param($Job, [string]$Root, $Response)
    $directory = Get-TCLinuxRequestDirectory $Job $Root
    $request = Read-TCLinuxClientRequest $directory
    if ($Response.SchemaVersion -ne 1 -or $Response.Kind -cne 'TradeChannel.ClientResponse' -or $Response.Status -cne 'Authorized' -or
        $Response.RequestId -cne $request.RequestId -or $Response.DeviceId -cne $request.DeviceId -or $Response.ClientPublicKey -cne $request.ClientPublicKey) {
        Stop-TCLinux ResponseMismatch '服务器公开响应与原本机设备申请不匹配。'
    }
    if ($Job.Operation -in @('Apply','Finalize')) {
        $parent = Get-TCLinuxJobRecord $Job.ParentJobId $Root
        $preview = Get-TCLinuxJob -Id $parent.JobId -Root $Root
        if ($preview.Status -cne 'Completed' -or $preview.Data.PlanId -cne $Job.PlanId -or
            $Response.PublicEndpoint -cne $parent.PublicEndpoint -or $Response.TunnelSubnet -cne $parent.TunnelSubnet -or $Response.NodeName -cne $parent.Name -or
            $Response.ServerAddress -cne $preview.Data.ServerAddress -or $Response.ClientAddress -cne $preview.Data.ClientAddress) {
            Stop-TCLinux ResponseMismatch '服务器公开响应与原预览计划不一致。'
        }
    }
    $transport=Get-TCLinuxProperty $Response 'Transport'
    if($transport){
        $nodeModule=Import-Module (Join-Path $PSScriptRoot 'NodeStore.psm1') -PassThru -DisableNameChecking
        $validated=& $nodeModule {param($Value) ConvertTo-TCTransport $Value} $transport
        if($validated.Server -cne ([string]$Response.PublicEndpoint).Split(':')[0]){Stop-TCLinux ResponseMismatch 'TCP 服务器与该节点公开端点不匹配。'}
        if($Job.Operation -in @('Apply','Finalize')){
            $expected=Get-TCLinuxProperty $preview.Data 'Transport'
            if(-not $expected -or $validated.Port -ne [int]$expected.Port -or $validated.ServerName -cne [string]$expected.ServerName){Stop-TCLinux ResponseMismatch 'TCP 参数与已预览计划不匹配。'}
        }
    }elseif($Job.Operation -in @('Apply','Finalize') -and (Get-TCLinuxProperty $preview.Data 'Transport')){Stop-TCLinux ResponseMismatch 'TCP 计划未返回对应传输参数。'}
    Write-TCLinuxJson (Join-Path (Join-Path $Root $Job.JobId) 'public.response.json') $Response -IfAbsent
}

function Invoke-TCLinuxConsoleJob {
    param([string]$Id, [string]$Root)
    $ErrorActionPreference = 'Stop'
    $rootPath = Resolve-TCLinuxRoot $Root
    $job = Get-TCLinuxJobRecord $Id $rootPath
    $directory = Join-Path $rootPath $Id
    $lockPath = Join-Path $directory '.execution.lock'
    try { $lock = [IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
    catch { Stop-TCLinux AlreadyRunning '该任务已在另一个认证控制台执行。' }
    $stage = 'Console'; $exitCode = $null
    try {
        Protect-TCLinuxPath $lockPath
        if (Test-Path -LiteralPath (Join-Path $directory 'result.json')) { return (Get-TCLinuxJob -Id $Id -Root $rootPath) }
        $connection = Get-TCLinuxConnection $job.Connection
        $knownHosts = Join-Path $rootPath 'known_hosts'
        Assert-TCLinuxPrivatePath $knownHosts
        $payload = Read-TCLinuxJson (Join-Path $directory 'payload.json') 16MB
        if ($payload.Action -cne $job.Operation.ToLowerInvariant() -or $payload.SourceSHA256 -cne (Get-TCLinuxHash $payload.Source)) {
            Stop-TCLinux PayloadMismatch '任务包校验失败。'
        }
        if ($job.RequestId) { $null = Get-TCLinuxRequestDirectory $job $rootPath }
        if ($job.Operation -in @('Apply','Finalize') -and $payload.Input.PlanId -cne $job.PlanId) { Stop-TCLinux PlanMismatch 'Apply 请求与原 Plan 不匹配。' }
        try {
            if ([Environment]::UserInteractive -and -not [Console]::IsOutputRedirected) {
                $Host.UI.RawUI.WindowTitle = ('TradeChannel Linux {0} - {1}@{2}:{3}' -f $job.Operation,$connection.User,$connection.Host,$connection.Port)
            }
        } catch { } # A host without a title bar still supports normal auth prompts.
        Write-Host ('TradeChannel Linux {0}  |  {1}@{2}:{3}' -f $job.Operation,$connection.User,$connection.Host,$connection.Port)
        if ($job.PublicEndpoint) { Write-Host ('公开 WireGuard 端点：' + $job.PublicEndpoint) }
        Write-Host '首次连接：请与云控制台提供的 SSH 主机指纹核对后再输入 yes。主机密钥改变会被拒绝。'
        Write-Host '无需先按回车。请等待下方 SSH 提示，再按提示输入：'
        Write-Host 'Are you sure you want to continue connecting：核对 SHA256 主机指纹；一致后输入 yes 并回车。'
        Write-Host 'password：输入服务器账户密码并回车。Enter passphrase for key：输入 SSH 私钥口令并回车。'
        Write-Host '输入密码或口令时不显示字符，这是正常现象。Permission denied 表示认证被拒绝；HOST IDENTIFICATION HAS CHANGED 表示主机指纹改变，请先通过云控制台核实。'
        Write-Host '密码或密钥口令仅在此窗口输入，不会进入任务 JSON。关闭本窗口会结束本地等待；部署结果需查询 Status。'
        Write-Host '看到 password: 后输入完整密码，再按一次回车。密码不显示字符或星号，光标不移动是正常现象。' -ForegroundColor Yellow
        if ($connection.User -cne 'root') { Write-Host '非 root 模式使用密钥登录及 sudo -n；若没有免交互 sudo 权限，请在云控制台配置权限或改用 root。' }
        Write-TCLinuxJson (Join-Path $directory 'running.json') ([ordered]@{ StartedAtUtc = [DateTime]::UtcNow.ToString('o') }) -IfAbsent
        $transport = Get-TCLinuxTransportPlan $connection $knownHosts
        $stage = 'Transport'
        $native = Invoke-TCLinuxNativeTransport $transport ($payload | ConvertTo-Json -Depth 24 -Compress) (ConvertTo-TCLinuxUtcTime $job.DeadlineUtc)
        $exitCode = [int]$native.ExitCode
        if ($native.ExitCode -eq 255) { Stop-TCLinux SshFailed 'SSH 认证、主机验证或连接失败；请查看本控制台的 SSH 提示。没有绕过主机密钥检查。' }
        $stage = 'Bootstrap'
        if ($native.ExitCode -eq 127) { Stop-TCLinux RemoteCommandMissing '远端启动命令不可用；请通过云控制台检查 python3，非 root 账户还需要 sudo 及 sudo -n 权限。' }
        if ($native.ExitCode -eq 76) { Stop-TCLinux SourceDigestMismatch '远端源码摘要校验失败，后端未执行。请检查产品包完整性。' }
        if ($native.ExitCode -eq 77) { Stop-TCLinux BootstrapActionRejected '远端启动器拒绝此操作，后端未执行。' }
        $envelope = ConvertFrom-TCLinuxEnvelope $native.Output $job.Operation
        $stage = 'Backend'
        if (-not $envelope.Ok) {
            Set-TCLinuxFailure $job $rootPath RemoteRejected ('服务器拒绝操作：' + (ConvertTo-TCLinuxMessage ([string](Get-TCLinuxProperty $envelope Message '')))) ($job.Operation -in @('Apply','Authorize','Recover','Finalize')) (Get-TCLinuxProperty $envelope Data) $stage $exitCode
        } else {
            if ($native.ExitCode -ne 0) { Stop-TCLinux BackendExitFailed '后端退出码与成功响应不一致；请先查询服务器状态。' }
            $stage = 'Response'
            if ($job.Operation -eq 'Plan') { Assert-TCLinuxPlanReply $job $envelope.Data }
            if ($job.Operation -in @('Apply','Authorize','Finalize')) {
                $response = Get-TCLinuxProperty $envelope.Data ClientResponse
                if ($null -eq $response) { Stop-TCLinux ResponseMissing '后端成功但未返回公开设备响应；请查询 Status 后补领响应。' }
                Save-TCLinuxClientResponse $job $rootPath $response
            }
            $result = New-TCLinuxTerminalResult $job Completed '' '远端操作完成；未导入或启用本机线路，公网和握手仍需单独验证。' $envelope.Data -Stage Completed -ExitCode $exitCode
            Write-TCLinuxJson (Join-Path $directory 'result.json') $result -IfAbsent
        }
    } catch {
        $code = 'ConsoleFailure'; $message = '认证会话未能完成；本地错误详情未回显，请检查任务文件及服务器状态。'
        if ($_.Exception.Message -match '^\[TC:([A-Za-z0-9]+)\] (.+)$') { $code = $Matches[1]; $message = $Matches[2] }
        Set-TCLinuxFailure $job $rootPath $code $message ($job.Operation -in @('Apply','Authorize','Recover','Finalize')) -Stage $stage -ExitCode $exitCode
    } finally { $lock.Dispose() }
    return (Get-TCLinuxJob -Id $Id -Root $rootPath)
}

function Complete-TCLinuxJob {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Id, [string]$Root)
    $ErrorActionPreference = 'Stop'
    $rootPath = Resolve-TCLinuxRoot $Root
    $job = Get-TCLinuxJobRecord $Id $rootPath
    $result = Get-TCLinuxJob -Id $Id -Root $rootPath
    if ($result.Status -cne 'Completed' -or $job.Operation -notin @('Apply','Authorize','Finalize')) { Stop-TCLinux NotCompletable '只有成功的 Apply 或 Authorize 任务可以生成本机客户端配置。' }
    $requestDirectory = Get-TCLinuxRequestDirectory $job $rootPath
    $responsePath = Join-Path (Join-Path $rootPath $Id) 'public.response.json'
    $response = Read-TCLinuxJson $responsePath 32768
    Assert-TCLinuxPublicData $response
    Save-TCLinuxClientResponse $job $rootPath $response
    # Existing helper validates the secret hash and full public response schema.
    # Bound all private-file reads before entering it; never enumerate key stores.
    foreach ($leaf in @('client.key','client.state.json')) {
        $path = Join-Path $requestDirectory $leaf
        Assert-TCLinuxPrivatePath $path
        $maxBytes = if ($leaf -eq 'client.key') { 256 } else { 16384 }
        if ((Get-Item -LiteralPath $path -Force).Length -gt $maxBytes) { Stop-TCLinux InvalidState '本机设备私有文件超出允许大小。' }
    }
    $destination = Join-Path (Join-Path $rootPath $Id) 'client.conf'
    $module = Get-TCLinuxClientModule
    try {
        $null = & $module { param($RequestDirectory,$ResponsePath,$Destination) Complete-TCClientConfig -RequestDirectory $RequestDirectory -ResponsePath $ResponsePath -Destination $Destination } $requestDirectory $responsePath $destination
    } catch {
        $code = 'ClientCompletionFailed'
        if ($_.Exception.Message -match '^\[TC:([A-Za-z0-9]+)\]') { $code = $Matches[1] }
        Stop-TCLinux $code '本机密钥与服务器公开响应未能安全合并；没有导入或启用任何线路。'
    }
    $transport=Get-TCLinuxProperty $response 'Transport'
    $completed=[pscustomobject]@{ConfigPath=$destination;RequestDirectory=$requestDirectory;ResponsePath=$responsePath;NodeName=$response.NodeName}
    if($transport){$completed|Add-Member NoteProperty Transport $transport}
    return $completed
}

function Invoke-TCLinuxRequest {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$Request, [string]$Root, [string]$WgPath)
    $ErrorActionPreference = 'Stop'
    if (-not $Root) { $Root = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'TradeChannel' }
    $jobsRoot = Resolve-TCLinuxRoot (Join-Path (Get-TCLinuxPath $Root) 'linux-jobs')
    $action = [string](Get-TCLinuxProperty $Request Action '')
    switch -CaseSensitive ($action) {
        LinuxStart {
            Assert-TCLinuxFields $Request @('Action','Operation','Connection','Name','PublicEndpoint','TunnelSubnet','ParentJobId','PlanId','ClientAddress','Transport','NetworkProbe','CaptureSeconds','ProbeRelayPort','ProbeSourceIPv4')
            $operation = [string](Get-TCLinuxProperty $Request Operation '')
            if ($operation -cnotin @('Inspect','Plan','Apply','Status','Authorize','Recover','Finalize')) { Stop-TCLinux InvalidOperation '不支持的 Linux 操作。' }
            $parameters = @{ Action = $operation; Root = $jobsRoot; WgPath = $WgPath }
            $networkProbe=Get-TCLinuxProperty $Request NetworkProbe
            if($null -ne $networkProbe){if($networkProbe -isnot [bool]){Stop-TCLinux InvalidRequest 'NetworkProbe 必须为布尔值。'};$parameters.NetworkProbe=$networkProbe}
            $captureSeconds=Get-TCLinuxProperty $Request CaptureSeconds
            if($null -ne $captureSeconds){
                if(($captureSeconds -isnot [int] -and $captureSeconds -isnot [long]) -or $captureSeconds -lt 0 -or $captureSeconds -gt 60){Stop-TCLinux InvalidRequest 'CaptureSeconds 必须是 0–60 的整数。'}
                $parameters.CaptureSeconds=[int]$captureSeconds
            }
            $relayPort=Get-TCLinuxProperty $Request ProbeRelayPort
            if($null -ne $relayPort){
                if(($relayPort -isnot [int] -and $relayPort -isnot [long]) -or $relayPort -notin @(0,443)){Stop-TCLinux InvalidRequest 'ProbeRelayPort 只允许 0 或 443。'}
                $parameters.ProbeRelayPort=[int]$relayPort
            }
            $probeSource=Get-TCLinuxProperty $Request ProbeSourceIPv4
            if($null -ne $probeSource){if($probeSource -isnot [string]){Stop-TCLinux InvalidRequest 'ProbeSourceIPv4 必须是公网 IPv4 字符串。'};$parameters.ProbeSourceIPv4=$probeSource}
            foreach ($field in @('Connection','Name','PublicEndpoint','TunnelSubnet','PlanId','ClientAddress','Transport')) {
                $value = Get-TCLinuxProperty $Request $field
                if ($null -ne $value) { $parameters[$field] = $value }
            }
            $parameters.JobId = [string](Get-TCLinuxProperty $Request ParentJobId '')
            $result = New-TCLinuxJob @parameters
            if ($result.Status -eq 'Pending') { $result.Status = 'Running' }
            return $result
        }
        LinuxPoll {
            Assert-TCLinuxFields $Request @('Action','Id')
            $result = Get-TCLinuxJob -Id ([string](Get-TCLinuxProperty $Request Id '')) -Root $jobsRoot
            if ($result.Status -eq 'Pending') { $result.Status = 'Running' }
            return $result
        }
        LinuxComplete {
            Assert-TCLinuxFields $Request @('Action','Id')
            return (Complete-TCLinuxJob -Id ([string](Get-TCLinuxProperty $Request Id '')) -Root $jobsRoot)
        }
        LinuxRecent {
            Assert-TCLinuxFields $Request @('Action')
            return (Get-TCLinuxRecentJobs -Root $jobsRoot)
        }
        LinuxTasks {
            Assert-TCLinuxFields $Request @('Action')
            return (Get-TCLinuxRecentJobs -Root $jobsRoot -IncludeArchived -Limit 200)
        }
        LinuxArchive {
            Assert-TCLinuxFields $Request @('Action','Id','Archived')
            return (Set-TCLinuxJobArchived -Root $jobsRoot -Id ([string]$Request.Id) -Archived:([bool]$Request.Archived))
        }
        LinuxResetHostKey {
            Assert-TCLinuxFields $Request @('Action','Host','Port')
            $port=Get-TCLinuxProperty $Request 'Port' 22
            return (Reset-TCLinuxHostKey -ServerHost ([string]$Request.Host) -Port ([int]$port) -Root $jobsRoot)
        }
        default { Stop-TCLinux InvalidOperation '不支持的 Linux Worker 请求。' }
    }
}


function Reset-TCLinuxHostKey {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$ServerHost,[int]$Port=22,[string]$Root)
    $rootPath=Resolve-TCLinuxRoot $Root
    $connection=Get-TCLinuxConnection @{Host=$ServerHost;Port=$Port;User='root';IdentityFile=$null}
    $knownHosts=Join-Path $rootPath 'known_hosts'
    if(-not (Test-Path -LiteralPath $knownHosts)){return [pscustomobject]@{Cleared=$true;Host=$ServerHost;Port=$Port;RemovedEntries=0}}
    Assert-TCLinuxPrivatePath $knownHosts
    $tool=Join-Path ([Environment]::GetFolderPath('Windows')) 'System32\OpenSSH\ssh-keygen.exe'
    if(-not (Test-Path -LiteralPath $tool)){Stop-TCLinux SshMissing '未找到系统 OpenSSH 指纹工具。'}
    $target=if($Port -eq 22){$connection.Host}else{'['+$connection.Host+']:'+$Port}
    $backup=Join-Path $rootPath ('known_hosts.backup-'+[guid]::NewGuid().ToString('N'))
    Copy-Item -LiteralPath $knownHosts -Destination $backup
    Protect-TCLinuxPath $backup
    $linesBefore=@(Get-Content -LiteralPath $knownHosts -Encoding UTF8).Count
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=$tool;$info.Arguments=(@('-R',$target,'-f',$knownHosts)|ForEach-Object {ConvertTo-TCLinuxArgument $_}) -join ' '
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $process=New-Object Diagnostics.Process;$process.StartInfo=$info
    try{
        $null=$process.Start();$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        if(-not $process.WaitForExit(10000)){$process.Kill();Stop-TCLinux HostKeyResetFailed '指纹工具未能按时完成，备份已保留。'}
        if($process.ExitCode -ne 0){Copy-Item -LiteralPath $backup -Destination $knownHosts -Force;Stop-TCLinux HostKeyResetFailed '指纹重置未完成，原记录已恢复。'}
        $null=$stdout.Result;$null=$stderr.Result
    }finally{$process.Dispose()}
    Protect-TCLinuxPath $knownHosts
    if(Test-Path -LiteralPath ($knownHosts+'.old')){Protect-TCLinuxPath ($knownHosts+'.old')}
    $removed=$linesBefore-@(Get-Content -LiteralPath $knownHosts -Encoding UTF8).Count
    [pscustomobject]@{Cleared=$true;Host=$ServerHost;Port=$Port;RemovedEntries=$removed;BackupPath=$backup;Message='该服务器端口的旧指纹已移除；重新登录时请核对新的 SHA256 指纹。'}
}

. (Join-Path $PSScriptRoot 'LinuxJobManagement.ps1')
Export-ModuleMember -Function New-TCLinuxJob, Get-TCLinuxJob, Complete-TCLinuxJob, Invoke-TCLinuxRequest, Reset-TCLinuxHostKey
