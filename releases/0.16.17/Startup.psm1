#requires -Version 5.1
<#
Opt-in UI startup only. Import and Get never write; call Set only from an explicit
user click. Get returns Enabled/Detail (unverified state is false with a reason).
Set returns Enabled/Detail on success and throws on refusal/failure.
New-TCStartupPlan is a pure, exported seam: it never reads identity, files or tasks.
Private context/task adapters are replaceable in isolated tests. No registry,
network, process launch, task Run(), or connection/preferences APIs are used.

Packages are immutable slots beneath CommonApplicationData\TradeChannel\
ui-startup\<SID>\<manifest SHA256>. A restricted receipt binds task ownership to
this installation; neither a familiar task name nor a matching executable alone
authorizes replacement/deletion. Hashes detect corruption, not publisher identity.
#>
Set-StrictMode -Version 2.0

function Get-TCStartupLayout {
    param([string]$UserSid, [string]$CommonAppData)
    if ($UserSid -notmatch '^S-1-(?:5-21|12-1)-\d+-\d+-\d+-\d+$') { throw '登录启动仅支持当前 Windows 用户，不能使用服务或组身份。' }
    if ($CommonAppData -notmatch '^[A-Za-z]:\\' -or $CommonAppData -match '[\x00-\x1f"<>|?*]' -or $CommonAppData.Substring(2).Contains(':')) { throw '启动目录必须位于本机 CommonApplicationData。' }
    $base = [IO.Path]::GetFullPath($CommonAppData).TrimEnd('\')
    $product = [IO.Path]::Combine($base, 'TradeChannel')
    $startup = [IO.Path]::Combine($product, 'ui-startup')
    $root = [IO.Path]::Combine($startup, $UserSid)
    $name = 'TradeChannel.UIStartup.v1-' + $UserSid
    [pscustomobject]@{ UserSid=$UserSid; CommonAppData=$base; ProductRoot=$product; StartupRoot=$startup; StageRoot=$root; ReceiptPath=([IO.Path]::Combine($root, '.owner.json')); TaskName=$name; TaskPath='\'; TaskFullName=('\'+$name) }
}

function New-TCStartupPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$UserSid,
        [Parameter(Mandatory=$true)][string]$CommonAppData,
        [Parameter(Mandatory=$true)][ValidatePattern('^[a-f0-9]{32}$')][string]$OwnerId,
        [Parameter(Mandatory=$true)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$PackageHash
    )
    $layout = Get-TCStartupLayout $UserSid $CommonAppData
    $hash = $PackageHash.ToUpperInvariant()
    $directory = [IO.Path]::Combine($layout.StageRoot, $hash)
    $execute = [IO.Path]::Combine($directory, 'TradeChannel.exe')
    $description = 'TradeChannel/UIStartup/v1;SID='+$UserSid+';Owner='+$OwnerId+';SHA256='+$hash
    $xml = @'
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Author/><Description/><URI/></RegistrationInfo>
  <Triggers><LogonTrigger><Enabled>true</Enabled><UserId/></LogonTrigger></Triggers>
  <Principals><Principal id="CurrentUser"><UserId/><LogonType>InteractiveToken</LogonType><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries><AllowHardTerminate>true</AllowHardTerminate><StartWhenAvailable>false</StartWhenAvailable><RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable><AllowStartOnDemand>false</AllowStartOnDemand><Enabled>true</Enabled><Hidden>false</Hidden><RunOnlyIfIdle>false</RunOnlyIfIdle><WakeToRun>false</WakeToRun><ExecutionTimeLimit>PT0S</ExecutionTimeLimit><Priority>7</Priority></Settings>
  <Actions Context="CurrentUser"><Exec><Command/><Arguments/><WorkingDirectory/></Exec></Actions>
</Task>
'@
    $doc = [xml]$xml
    $doc.Task.RegistrationInfo.Author = $UserSid
    $doc.Task.RegistrationInfo.Description = $description
    $doc.Task.RegistrationInfo.URI = $layout.TaskFullName
    $doc.Task.Triggers.LogonTrigger.UserId = $UserSid
    $doc.Task.Principals.Principal.UserId = $UserSid
    $doc.Task.Actions.Exec.Command = $execute
    $doc.Task.Actions.Exec.WorkingDirectory = $directory
    [pscustomobject]@{
        Enabled=$true; AutoConnect=$false; UserSid=$UserSid; OwnerId=$OwnerId; PackageHash=$hash
        TaskName=$layout.TaskName; TaskPath=$layout.TaskPath; TaskFullName=$layout.TaskFullName
        StageRoot=$layout.StageRoot; PackageDirectory=$directory; Description=$description
        Action=[pscustomobject]@{Execute=$execute; Arguments=''; WorkingDirectory=$directory}
        Xml=$doc.OuterXml; TaskSddl='O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)'
    }
}

function Get-TCStartupContext {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        [pscustomobject]@{ UserSid=$identity.User.Value; IsAdministrator=$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator); IsInteractive=(@($identity.Groups.Value) -contains 'S-1-5-4'); CommonAppData=[Environment]::GetFolderPath('CommonApplicationData') }
    } finally { $identity.Dispose() }
}

function Assert-TCStartupContext {
    param($Context)
    if (-not $Context.IsAdministrator -or -not $Context.IsInteractive) { throw '请由当前交互式管理员用户设置登录启动；不支持 SYSTEM 或后台服务代设。' }
    Get-TCStartupLayout $Context.UserSid $Context.CommonAppData
}

function Assert-TCStartupPath {
    param([string]$Path)
    if ($Path -notmatch '^[A-Za-z]:\\' -or $Path -match '[\x00-\x1f"<>|?*]' -or $Path.Substring(2).Contains(':')) { throw '不支持的启动文件路径。' }
    $cursor = [IO.Path]::GetFullPath($Path)
    while ($cursor) {
        $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw ('启动路径不能经过 reparse point：'+$cursor) }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
}

function New-TCStartupAcl {
    param([switch]$Directory)
    $acl = if ($Directory) { New-Object Security.AccessControl.DirectorySecurity } else { New-Object Security.AccessControl.FileSecurity }
    $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($id in @('S-1-5-18','S-1-5-32-544')) {
        $sid = New-Object Security.Principal.SecurityIdentifier($id)
        $rule = if ($Directory) { New-Object Security.AccessControl.FileSystemAccessRule($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow') } else { New-Object Security.AccessControl.FileSystemAccessRule($sid,'FullControl','Allow') }
        $null = $acl.AddAccessRule($rule)
    }
    return $acl
}

function Assert-TCStartupAcl {
    param([string]$Path, [switch]$Parent)
    Assert-TCStartupPath $Path
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    $trusted = @('S-1-5-18','S-1-5-32-544')
    if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $trusted) { throw ('启动路径所有者不受信任：'+$Path) }
    # ProductRoot may already have read-only ACEs; never rewrite its existing ACL.
    if (-not $Parent -and -not $acl.AreAccessRulesProtected) { throw ('启动 staging 必须禁止 ACL 继承：'+$Path) }
    $writeMask = [Security.AccessControl.FileSystemRights]'Write,Delete,DeleteSubdirectoriesAndFiles,ChangePermissions,TakeOwnership'
    $full = @{}
    foreach ($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])) {
        $inheritOnly = [bool]($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly)
        $sid = $rule.IdentityReference.Value
        if ($rule.AccessControlType -ne 'Allow') { throw ('启动路径包含非预期的拒绝权限：'+$Path) }
        if ($sid -notin $trusted -and (-not $Parent -or (-not $inheritOnly -and ($rule.FileSystemRights -band $writeMask)))) { throw ('启动路径可由其他用户访问或修改：'+$Path) }
        if ($inheritOnly) { continue }
        if ($sid -in $trusted -and ($rule.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -eq [Security.AccessControl.FileSystemRights]::FullControl) { $full[$sid]=$true }
    }
    if ($full.Count -ne 2) { throw ('启动路径缺少管理员或 SYSTEM 权限：'+$Path) }
}

function Assert-TCStartupBase {
    param($Layout)
    Assert-TCStartupPath $Layout.CommonAppData
    # A writable parent DELETE_CHILD permission could bypass the child's DACL.
    $acl = Get-Acl -LiteralPath $Layout.CommonAppData -ErrorAction Stop
    if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin @('S-1-5-18','S-1-5-32-544')) { throw 'CommonApplicationData 父目录所有者不受信任。' }
    $mask = [Security.AccessControl.FileSystemRights]'DeleteSubdirectoriesAndFiles,Delete,ChangePermissions,TakeOwnership'
    foreach ($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -eq 'Allow' -and -not ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -and $rule.IdentityReference.Value -notin @('S-1-5-18','S-1-5-32-544') -and ($rule.FileSystemRights -band $mask)) { throw 'CommonApplicationData 父目录允许普通用户替换启动目录。' }
    }
}

function New-TCStartupDirectory {
    param([string]$Path, [switch]$Parent)
    Assert-TCStartupPath ([IO.Path]::GetDirectoryName($Path))
    if (-not (Test-Path -LiteralPath $Path -ErrorAction Stop)) {
        # .NET Framework creates the directory with its restricted DACL atomically.
        $null = [IO.Directory]::CreateDirectory($Path, (New-TCStartupAcl -Directory))
    }
    if (-not (Get-Item -LiteralPath $Path -Force -ErrorAction Stop).PSIsContainer) { throw '启动 staging 必须为目录。' }
    Assert-TCStartupAcl $Path -Parent:$Parent
}

function Assert-TCStartupParents {
    param($Layout)
    Assert-TCStartupBase $Layout
    Assert-TCStartupAcl $Layout.ProductRoot -Parent
    Assert-TCStartupAcl $Layout.StartupRoot
    Assert-TCStartupAcl $Layout.StageRoot
}

function Get-TCStartupInventory {
    param([string]$Directory, [switch]$Restricted)
    Assert-TCStartupPath $Directory
    $pending = New-Object 'Collections.Generic.Stack[string]'
    $pending.Push($Directory)
    while ($pending.Count) {
        $current = $pending.Pop()
        if ($Restricted) { Assert-TCStartupAcl $current }
        foreach ($item in @(Get-ChildItem -LiteralPath $current -Force -ErrorAction Stop)) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw ('产品包包含 reparse point：'+$item.FullName) }
            if ($item.PSIsContainer) { $pending.Push($item.FullName) }
            else { if ($Restricted) { Assert-TCStartupAcl $item.FullName }; $item }
        }
    }
}

function Get-TCStartupPackage {
    param([string]$Directory, [switch]$Restricted, [string]$ExpectedHash)
    Assert-TCStartupPath $Directory
    $manifest = [IO.Path]::Combine($Directory,'package.sha256')
    Assert-TCStartupPath $manifest
    $hash = (Get-FileHash -LiteralPath $manifest -Algorithm SHA256 -ErrorAction Stop).Hash
    if ($ExpectedHash -and $hash -cne $ExpectedHash) { throw 'staging 校验清单被修改。' }
    $entries = @{}
    foreach ($line in [IO.File]::ReadAllLines($manifest, (New-Object Text.UTF8Encoding($false,$true)))) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -notmatch '^([A-Fa-f0-9]{64})\|(.+)$') { throw 'package.sha256 格式错误。' }
        $digest = $Matches[1].ToUpperInvariant(); $relative = $Matches[2].Replace('/','\')
        if ($relative -match '[\x00-\x1f:<>"|?*]' -or [IO.Path]::IsPathRooted($relative)) { throw '校验清单包含不安全路径。' }
        foreach ($part in $relative.Split('\')) {
            if (-not $part -or $part -in @('.','..') -or $part -match '[. ]$|^(?i:CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(?:\.|$)') { throw '校验清单包含不安全路径段。' }
        }
        if ($relative -ieq 'package.sha256' -or $entries.ContainsKey($relative)) { throw '校验清单包含重复或自引用项。' }
        $entries[$relative] = $digest
    }
    $required = @('TradeChannel.exe','TradeChannel.ps1','Worker.ps1','RuntimeBridge.psm1','ProviderBridge.psm1','NodeStore.psm1','ServerSetup.psm1','Startup.psm1','ui\Shell.xaml','assets\sing-box.exe','assets\wg.exe',
        'runtime\Invoke-TradeChannel.ps1','runtime\Run-TradeChannel.ps1','runtime\Set-TradeChannelExit.ps1','runtime\Set-TradeChannelMode.ps1','runtime\Test-SelectedTradeExit.ps1','runtime\TradeChannel.Proxy.ps1','runtime\TradeChannel.Provider.ps1','runtime\TradeChannel.Providers.ps1','runtime\TradeChannel.ProviderSetup.ps1','runtime\Set-TradeChannelDaily.ps1','runtime\TradeChannel.Agents.ps1','runtime\Set-TradeChannelAgents.ps1','runtime\TradeChannel.State.ps1','runtime\TradeChannelGuard.cs')
    $required+=@('LinuxServerSetup.psm1','linux\tradechannel_linux.py','linux\Invoke-LinuxConsole.ps1','ui\LinuxPages.ps1')
    $required+=@('runtime\TradeChannelGuard.dll','runtime\TCDevicePath.dll','runtime\TradeChannel.Components.ps1','runtime\TradeChannel.Diagnostics.ps1','runtime\Read-TradeChannel.ps1','ui\BackgroundJobs.ps1')
    $required+=@('WorkerContracts.psm1','WorkerErrors.psm1')
    $required+=@('ui\MemoryJobs.ps1')
    $required+=@('runtime\TradeChannel.ProxyJournal.ps1')
    foreach ($relative in $required) { if (-not $entries.ContainsKey($relative)) { throw ('产品包缺少必需校验项：'+$relative) } }
    $seen = @{}
    foreach ($file in @(Get-TCStartupInventory $Directory -Restricted:$Restricted)) {
        $relative = $file.FullName.Substring($Directory.TrimEnd('\').Length+1)
        if ($relative -ieq 'package.sha256') { continue }
        if (-not $entries.ContainsKey($relative)) { throw ('产品包存在未校验文件：'+$relative) }
        if ((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256 -ErrorAction Stop).Hash -cne $entries[$relative]) { throw ('产品文件校验失败：'+$relative) }
        $seen[$relative] = $true
    }
    if ($seen.Count -ne $entries.Count) { throw '产品包文件缺失。' }
    if ((Get-FileHash -LiteralPath $manifest -Algorithm SHA256 -ErrorAction Stop).Hash -cne $hash) { throw '校验期间清单发生变化。' }
    [pscustomobject]@{ Directory=$Directory; Hash=$hash; Entries=$entries }
}

function Copy-TCStartupPackage {
    param($Package, $Plan)
    if (Test-Path -LiteralPath $Plan.PackageDirectory -ErrorAction Stop) {
        $null = Get-TCStartupPackage $Plan.PackageDirectory -Restricted -ExpectedHash $Package.Hash
        return
    }
    New-TCStartupDirectory $Plan.PackageDirectory
    foreach ($relative in @('package.sha256') + @($Package.Entries.Keys | Sort-Object)) {
        $source = [IO.Path]::Combine($Package.Directory,$relative)
        Assert-TCStartupPath $source
        $target = [IO.Path]::Combine($Plan.PackageDirectory,$relative)
        $parent = [IO.Path]::GetDirectoryName($relative)
        $directory = $Plan.PackageDirectory
        if ($parent) { foreach ($part in $parent.Split('\')) { $directory = [IO.Path]::Combine($directory,$part); New-TCStartupDirectory $directory } }
        $inputStream = [IO.File]::OpenRead($source)
        try {
            $outputStream = [IO.File]::Open($target,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            try { $inputStream.CopyTo($outputStream) } finally { $outputStream.Dispose() }
            Set-Acl -LiteralPath $target -AclObject (New-TCStartupAcl) -ErrorAction Stop
        } finally { $inputStream.Dispose() }
    }
    $null = Get-TCStartupPackage $Plan.PackageDirectory -Restricted -ExpectedHash $Package.Hash
}

function Read-TCStartupOwner {
    param($Layout)
    Assert-TCStartupParents $Layout
    Assert-TCStartupAcl $Layout.ReceiptPath
    $receipt = [IO.File]::ReadAllText($Layout.ReceiptPath, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
    if ($receipt.SchemaVersion -ne 1 -or $receipt.UserSid -cne $Layout.UserSid -or $receipt.OwnerId -cnotmatch '^[a-f0-9]{32}$') { throw '登录启动所有权凭据无效；不会接管或删除任务。' }
    return [string]$receipt.OwnerId
}

function Open-TCStartupLock {
    param($Layout)
    $path = [IO.Path]::Combine($Layout.StageRoot,'.lock')
    if (-not (Test-Path -LiteralPath $path -ErrorAction Stop)) {
        $stream = [IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        try { Set-Acl -LiteralPath $path -AclObject (New-TCStartupAcl) -ErrorAction Stop } finally { $stream.Dispose() }
    }
    Assert-TCStartupAcl $path
    return [IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
}

# The only Task Scheduler boundary. Tests replace this adapter with an in-memory
# folder; they never connect to the live scheduler, including for status reads.
function Get-TCStartupTaskFolder {
    $service = New-Object -ComObject 'Schedule.Service'
    $service.Connect()
    return $service.GetFolder('\')
}

function Read-TCStartupTask {
    param($Layout)
    $folder = Get-TCStartupTaskFolder
    try { $task = $folder.GetTask($Layout.TaskName) }
    catch {
        $fault = $_.Exception
        while ($fault) { if ($fault.HResult -eq -2147024894) { return $null }; $fault=$fault.InnerException }
        throw
    }
    if ($null -eq $task) { throw '任务计划程序返回了无效结果。' }
    [pscustomobject]@{ Name=[string]$task.Name; Path=[string]$task.Path; Enabled=[bool]$task.Enabled; Xml=[string]$task.Xml; Sddl=[string]$task.GetSecurityDescriptor(7) }
}

function Register-TCStartupTask {
    param($Plan, [bool]$Update)
    $folder = Get-TCStartupTaskFolder
    # TASK_CREATE / TASK_UPDATE + TASK_DONT_ADD_PRINCIPAL_ACE: keep the filtered
    # user token from gaining write access via an automatically added user ACE.
    $flags = if ($Update) { 20 } else { 18 }
    $null = $folder.RegisterTask($Plan.TaskName,$Plan.Xml,$flags,$Plan.UserSid,$null,3,$Plan.TaskSddl)
}

function Remove-TCStartupTask {
    param($Layout)
    $folder = Get-TCStartupTaskFolder
    $null = $folder.DeleteTask($Layout.TaskName,0)
}

function ConvertFrom-TCStartupTaskXml {
    param([string]$Text)
    $settings = New-Object Xml.XmlReaderSettings
    $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $settings.MaxCharactersInDocument = 1048576
    $reader = [Xml.XmlReader]::Create((New-Object IO.StringReader($Text)),$settings)
    try { $doc = New-Object Xml.XmlDocument; $doc.XmlResolver=$null; $doc.Load($reader); return ,$doc } finally { $reader.Dispose() }
}

function Assert-TCStartupTask {
    param($Task, $Plan)
    if ($null -eq $Task -or $Task.Name -cne $Plan.TaskName -or $Task.Path -cne $Plan.TaskFullName) { throw '登录启动任务身份不匹配。' }
    $security = New-Object Security.AccessControl.RawSecurityDescriptor($Task.Sddl)
    if ($security.Owner.Value -notin @('S-1-5-18','S-1-5-32-544') -or -not ($security.ControlFlags -band [Security.AccessControl.ControlFlags]::DiscretionaryAclProtected) -or $null -eq $security.DiscretionaryAcl -or $security.DiscretionaryAcl.Count -ne 2) { throw '登录启动任务权限不受信任。' }
    $sids = @{}
    foreach ($ace in $security.DiscretionaryAcl) {
        if ($ace.AceType -ne 'AccessAllowed' -or $ace.SecurityIdentifier.Value -notin @('S-1-5-18','S-1-5-32-544') -or $ace.AccessMask -ne 2032127 -or $ace.AceFlags -ne 'None') { throw '登录启动任务允许其他身份修改。' }
        $sids[$ace.SecurityIdentifier.Value]=$true
    }
    if ($sids.Count -ne 2) { throw '登录启动任务权限不完整。' }
    $doc = ConvertFrom-TCStartupTaskXml $Task.Xml
    $ns = New-Object Xml.XmlNamespaceManager($doc.NameTable)
    $ns.AddNamespace('t','http://schemas.microsoft.com/windows/2004/02/mit/task')
    $expected = ConvertFrom-TCStartupTaskXml $Plan.Xml
    foreach ($section in @('RegistrationInfo','Triggers','Principals','Settings','Actions')) {
        if ($doc.SelectNodes('/t:Task/t:'+$section,$ns).Count -ne 1) { throw '登录启动任务结构不匹配。' }
    }
    foreach ($xpath in @('/t:Task/t:RegistrationInfo/t:Author','/t:Task/t:RegistrationInfo/t:Description','/t:Task/t:RegistrationInfo/t:URI','/t:Task/t:Principals/t:Principal/t:UserId','/t:Task/t:Principals/t:Principal/t:LogonType','/t:Task/t:Principals/t:Principal/t:RunLevel','/t:Task/t:Triggers/t:LogonTrigger/t:UserId','/t:Task/t:Triggers/t:LogonTrigger/t:Enabled','/t:Task/t:Actions/t:Exec/t:Command','/t:Task/t:Actions/t:Exec/t:WorkingDirectory')) {
        $nodes = $doc.SelectNodes($xpath,$ns)
        if ($nodes.Count -ne 1 -or $nodes[0].InnerText -cne $expected.SelectSingleNode($xpath,$ns).InnerText) { throw '登录启动任务所有权、身份或 action 不匹配。' }
    }
    $principal=$doc.SelectSingleNode('/t:Task/t:Principals',$ns); $triggers=$doc.SelectSingleNode('/t:Task/t:Triggers',$ns); $actions=$doc.SelectSingleNode('/t:Task/t:Actions',$ns)
    if ($principal.ChildNodes.Count -ne 1 -or $principal.FirstChild.GetAttribute('id') -cne 'CurrentUser' -or $principal.FirstChild.ChildNodes.Count -ne 3 -or $triggers.ChildNodes.Count -ne 1 -or $triggers.FirstChild.ChildNodes.Count -ne 2 -or $actions.GetAttribute('Context') -cne 'CurrentUser' -or $actions.ChildNodes.Count -ne 1 -or $actions.FirstChild.LocalName -cne 'Exec') { throw '登录启动任务包含额外身份、触发器或 action。' }
    $arguments = $doc.SelectNodes('/t:Task/t:Actions/t:Exec/t:Arguments',$ns)
    if ($arguments.Count -gt 1 -or ($arguments.Count -eq 1 -and $arguments[0].InnerText -cne '') -or $actions.FirstChild.ChildNodes.Count -ne (2+$arguments.Count)) { throw '登录启动 action 必须只打开 UI，且不得携带参数。' }
    foreach ($node in $expected.SelectNodes('/t:Task/t:Settings/*',$ns)) {
        $actual = $doc.SelectNodes('/t:Task/t:Settings/t:'+$node.LocalName,$ns)
        if ($node.LocalName -eq 'Enabled') {
            if ($actual.Count -ne 1 -or $actual[0].InnerText -cnotin @('true','false') -or $Task.Enabled -ne ($actual[0].InnerText -ceq 'true')) { throw '登录启动任务启用状态不一致。' }
        } elseif ($actual.Count -ne 1 -or $actual[0].InnerText -cne $node.InnerText) { throw '登录启动任务设置不匹配。' }
    }
    # Scheduler may materialize default IdleSettings/Compatibility/Unified engine
    # values. A RestartOnFailure policy is never part of our login-only contract.
    if ($doc.SelectNodes('/t:Task/t:Settings/t:RestartOnFailure',$ns).Count) { throw '登录启动任务不允许失败后自动重启。' }
}

function Get-TCStartupOwnedPlan {
    param($Task, $Layout)
    $owner = Read-TCStartupOwner $Layout
    $doc = ConvertFrom-TCStartupTaskXml $Task.Xml
    $description = [string]$doc.Task.RegistrationInfo.Description
    $prefix = 'TradeChannel/UIStartup/v1;SID='+$Layout.UserSid+';Owner='+$owner+';SHA256='
    if (-not $description.StartsWith($prefix,[StringComparison]::Ordinal) -or $description.Substring($prefix.Length) -cnotmatch '^[A-F0-9]{64}$') { throw '同名任务不属于当前安装；不会接管或删除。' }
    $plan = New-TCStartupPlan -UserSid $Layout.UserSid -CommonAppData $Layout.CommonAppData -OwnerId $owner -PackageHash $description.Substring($prefix.Length)
    Assert-TCStartupTask $Task $plan
    return $plan
}

function Get-TCStartup {
    [CmdletBinding()]
    param()
    try {
        $layout = Assert-TCStartupContext (Get-TCStartupContext)
        $task = Read-TCStartupTask $layout
        if ($null -eq $task) { return [pscustomobject]@{Enabled=$false; Detail='登录后打开控制台：关闭（默认）；连接始终需要手动点击。'} }
        $plan = Get-TCStartupOwnedPlan $task $layout
        $null = Get-TCStartupPackage $plan.PackageDirectory -Restricted -ExpectedHash $plan.PackageHash
        if (-not $task.Enabled) { return [pscustomobject]@{Enabled=$false; Detail='登录后打开控制台：关闭；任务已禁用。'} }
        [pscustomobject]@{Enabled=$true; Detail='登录 Windows 后仅打开控制台；不会自动连接。'}
    } catch { [pscustomobject]@{Enabled=$false; Detail=('无法确认登录启动设置：'+$_.Exception.Message)} }
}

function Set-TCStartup {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][bool]$Enabled, [string]$SourceDirectory=$PSScriptRoot)
    $layout = Assert-TCStartupContext (Get-TCStartupContext)
    $task = Read-TCStartupTask $layout
    if ($null -ne $task) { $null = Get-TCStartupOwnedPlan $task $layout }
    if (-not $Enabled -and $null -eq $task) { return [pscustomobject]@{Enabled=$false; Detail='登录后打开控制台：关闭；没有本用户的启动任务。'} }
    if ($Enabled) {
        $source = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($SourceDirectory).TrimEnd('\')
        $package = Get-TCStartupPackage $source
        Assert-TCStartupBase $layout
        New-TCStartupDirectory $layout.ProductRoot -Parent
        New-TCStartupDirectory $layout.StartupRoot
        New-TCStartupDirectory $layout.StageRoot
    }
    Assert-TCStartupParents $layout
    $lock = Open-TCStartupLock $layout
    try {
        $task = Read-TCStartupTask $layout
        if ($null -ne $task) { $null = Get-TCStartupOwnedPlan $task $layout }
        if (-not $Enabled) {
            # Deletion verifies ownership + the exact task contract, not payload
            # health, so an owned task with missing/corrupt files can be disabled.
            if ($null -ne $task) { Remove-TCStartupTask $layout }
            if ($null -ne (Read-TCStartupTask $layout)) { throw '启动任务删除后仍然存在。' }
            return [pscustomobject]@{Enabled=$false; Detail='登录后打开控制台：关闭；已保留 staging，不影响当前连接。'}
        }
        if (-not (Test-Path -LiteralPath $layout.ReceiptPath -ErrorAction Stop)) {
            $receipt = @{SchemaVersion=1; UserSid=$layout.UserSid; OwnerId=[guid]::NewGuid().ToString('N')} | ConvertTo-Json -Compress
            $stream = [IO.File]::Open($layout.ReceiptPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            try { $bytes=[Text.Encoding]::UTF8.GetBytes($receipt); $stream.Write($bytes,0,$bytes.Length) } finally { $stream.Dispose() }
            Set-Acl -LiteralPath $layout.ReceiptPath -AclObject (New-TCStartupAcl) -ErrorAction Stop
        }
        $owner = Read-TCStartupOwner $layout
        $plan = New-TCStartupPlan -UserSid $layout.UserSid -CommonAppData $layout.CommonAppData -OwnerId $owner -PackageHash $package.Hash
        Copy-TCStartupPackage $package $plan
        # Recheck after copying; never overwrite a task that appeared meanwhile.
        $latest = Read-TCStartupTask $layout
        $latestPlan = $null
        if ($null -ne $latest) { $latestPlan=Get-TCStartupOwnedPlan $latest $layout }
        if (($null -eq $task) -ne ($null -eq $latest) -or ($null -ne $task -and $task.Xml -cne $latest.Xml)) { throw '读取期间启动任务发生变化，请重试。' }
        if ($null -eq $latest -or -not $latest.Enabled -or $latestPlan.PackageHash -cne $plan.PackageHash) { Register-TCStartupTask $plan ($null -ne $latest) }
        $verified = Read-TCStartupTask $layout
        Assert-TCStartupTask $verified $plan
        if (-not $verified.Enabled) { throw '启动任务注册后未启用。' }
        $null = Get-TCStartupPackage $plan.PackageDirectory -Restricted -ExpectedHash $plan.PackageHash
        [pscustomobject]@{Enabled=$true; Detail='登录 Windows 后仅打开控制台；不会自动连接。'}
    } finally { $lock.Dispose() }
}

Export-ModuleMember -Function Get-TCStartup,Set-TCStartup,New-TCStartupPlan
