#requires -Version 5.1
Set-StrictMode -Version 2

# No default data root, store imports, directory creation, or runtime operations.
# Reads are side-effect free; saves require an explicitly supplied existing root.
$script:TCWindowUtf8 = New-Object Text.UTF8Encoding($true, $true)
$script:TCWindowMaxBytes = 16384

function Assert-TCWindowPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -notmatch '^[A-Za-z]:[\\/]' -or
        $Path -match '[\x00-\x1f\x7f"*?<>|]' -or $Path.Substring(2).Contains(':')) {
        throw '[TC:WindowPath] 窗口偏好必须使用本机绝对磁盘路径，不能使用共享、设备、通配符或数据流路径。'
    }
    foreach ($part in @($Path.Substring(3) -split '[\\/]')) {
        if ($part -and ($part -match '[. ]$' -or $part -match '^(?i:CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³])(?:\.|$)')) {
            throw '[TC:WindowPath] 窗口偏好路径不能包含相对段、尾随点或空格、保留设备名称。'
        }
    }
    try { $full = [IO.Path]::GetFullPath($Path).TrimEnd('\') }
    catch { throw '[TC:WindowPath] 无法解析窗口偏好路径。' }
    if ($full.Length -eq 2) { throw '[TC:WindowPath] 不能将磁盘根目录用作窗口偏好目录。' }
    $cursor = $full
    while ($cursor) {
        try { $attributes = [IO.File]::GetAttributes($cursor) }
        catch [IO.FileNotFoundException] { $attributes = $null }
        catch [IO.DirectoryNotFoundException] { $attributes = $null }
        catch { throw '[TC:WindowPath] 无法安全检查窗口偏好路径，请检查目录访问权限。' }
        if ($null -ne $attributes -and ($attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw '[TC:WindowPath] 窗口偏好路径不能经过符号链接、目录联接或其他重解析点。'
        }
        if ($cursor -ne $full -and $null -ne $attributes -and -not ($attributes -band [IO.FileAttributes]::Directory)) {
            throw '[TC:WindowPath] 窗口偏好路径的上级目录被文件占用。'
        }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
    return $full
}

function Resolve-TCWindowRoot {
    param([string]$Root, [switch]$RequireExisting)
    $full = Assert-TCWindowPath $Root
    if ([IO.File]::Exists($full)) { throw '[TC:WindowPath] 窗口偏好目录被同名文件占用。' }
    if ($RequireExisting -and -not [IO.Directory]::Exists($full)) {
        throw '[TC:WindowPath] 请先提供已存在的可信窗口偏好目录；本模块不会创建数据目录。'
    }
    return $full
}

function Get-TCWindowSettingsPath {
    param([string]$Root)
    $path = Assert-TCWindowPath (Join-Path $Root 'ui-window-settings.json')
    if ([IO.Directory]::Exists($path)) { throw '[TC:WindowPath] 窗口偏好文件被同名目录占用。' }
    return $path
}

function ConvertTo-TCWindowBehavior {
    param([string]$Value)
    if ($Value -ieq 'Tray') { return 'Tray' }
    if ($Value -ieq 'ExitInterface') { return 'ExitInterface' }
    throw '[TC:WindowValue] CloseBehavior 只能是 Tray 或 ExitInterface。'
}

function New-TCWindowResult {
    param([string]$Behavior, [string]$Path, [string]$Source, [string]$Warning = '', [string]$BackupPath = '')
    return [pscustomobject][ordered]@{
        CloseBehavior = $Behavior
        Path = $Path
        Source = $Source
        Defaulted = ($Source -ne 'Saved')
        Warning = $Warning
        CorruptBackupPath = $BackupPath
    }
}

function Read-TCWindowSettings {
    param([string]$Path)
    $null = Assert-TCWindowPath $Path
    if ([IO.Directory]::Exists($Path)) { throw '[TC:WindowPath] 窗口偏好文件被同名目录占用。' }
    if (-not [IO.File]::Exists($Path)) { return (New-TCWindowResult 'Tray' $Path 'Default') }
    $stream = $null
    $invalid = $false
    $raw = $null
    try {
        # Delete sharing lets readers finish on the old file during atomic replacement.
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
            ([IO.FileShare]::Read -bor [IO.FileShare]::Delete))
        if ($stream.Length -gt $script:TCWindowMaxBytes) { $invalid = $true }
        else {
            $bytes = New-Object byte[] ([int]$stream.Length)
            $offset = 0
            while ($offset -lt $bytes.Length) {
                $count = $stream.Read($bytes, $offset, $bytes.Length - $offset)
                if ($count -eq 0) { $invalid = $true; break }
                $offset += $count
            }
            try { $raw = $script:TCWindowUtf8.GetString($bytes).TrimStart([char]0xfeff) }
            catch [Text.DecoderFallbackException] { $invalid = $true }
        }
    } catch { throw '[TC:WindowRead] 无法读取窗口偏好，请检查文件权限或占用情况；原文件未修改。' }
    finally { if ($stream) { $stream.Dispose() } }

    # This small single-field format deliberately rejects duplicates, extra fields,
    # type coercion and noncanonical values, independently of PS 5.1 JSON leniency.
    if (-not $invalid -and $raw -cmatch '\A\s*\{\s*"CloseBehavior"\s*:\s*"(Tray|ExitInterface)"\s*\}\s*\z') {
        return (New-TCWindowResult $Matches[1] $Path 'Saved')
    }
    $warning = '窗口关闭偏好记录损坏、过大或格式无效，已回退为默认 Tray（隐藏到托盘）；原文件已保留。保存新偏好时会先备份损坏记录。'
    return (New-TCWindowResult 'Tray' $Path 'Corrupt' $warning)
}

function New-TCWindowFileSecurity {
    param([string]$ExistingPath = '')
    if ($ExistingPath -and [IO.File]::Exists($ExistingPath)) {
        # Preserve the original file DACL. Never modify the root or its inheritance.
        return [IO.File]::GetAccessControl($ExistingPath)
    }
    $security = New-Object Security.AccessControl.FileSecurity
    $security.SetAccessRuleProtection($true, $false)
    $sids = @('S-1-5-18', 'S-1-5-32-544', [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) | Select-Object -Unique
    foreach ($sidText in $sids) {
        $sid = New-Object Security.Principal.SecurityIdentifier($sidText)
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'Allow')
        $null = $security.AddAccessRule($rule)
    }
    return $security
}

function New-TCWindowFile {
    param([string]$Path, [Security.AccessControl.FileSecurity]$Security)
    $null = Assert-TCWindowPath $Path
    # Apply the DACL at creation, before writing any bytes; CreateNew rejects races.
    return [IO.FileStream]::new($Path, [IO.FileMode]::CreateNew,
        [Security.AccessControl.FileSystemRights]::Write, [IO.FileShare]::None,
        4096, [IO.FileOptions]::None, $Security)
}

function Open-TCWindowLock {
    param([string]$Root)
    $path = Join-Path $Root '.ui-window-settings.lock'
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        $null = Assert-TCWindowPath $path
        if ([IO.Directory]::Exists($path)) { throw '[TC:WindowPath] 窗口偏好锁被同名目录占用。' }
        try {
            if ([IO.File]::Exists($path)) {
                return [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::None)
            }
            return (New-TCWindowFile $path (New-TCWindowFileSecurity))
        } catch [IO.IOException] {
            if ($watch.ElapsedMilliseconds -ge 2000) { throw '[TC:WindowBusy] 另一个操作正在保存窗口偏好，请稍后重试。' }
            Start-Sleep -Milliseconds 40
        }
    }
}

function Backup-TCWindowCorruptRecord {
    param([string]$Path)
    $null = Assert-TCWindowPath $Path
    $parent = [IO.Path]::GetDirectoryName($Path)
    $backup = Join-Path $parent ('ui-window-settings.corrupt-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ') + '-' + [guid]::NewGuid().ToString('N') + '.json')
    $source = $null; $target = $null; $complete = $false
    try {
        $source = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $target = New-TCWindowFile $backup (New-TCWindowFileSecurity $Path)
        $source.CopyTo($target)
        $target.Flush($true)
        $complete = $true
    } finally {
        if ($target) { $target.Dispose() }
        if ($source) { $source.Dispose() }
        if (-not $complete -and $target -and [IO.File]::Exists($backup)) { [IO.File]::Delete($backup) }
    }
    return $backup
}

function Write-TCWindowAtomicSettings {
    param([string]$Path, [string]$Behavior)
    $null = Assert-TCWindowPath $Path
    $parent = [IO.Path]::GetDirectoryName($Path)
    $temp = Join-Path $parent ('.ui-window-settings-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $stream = $null
    try {
        $security = New-TCWindowFileSecurity $Path
        $stream = New-TCWindowFile $temp $security
        $text = ConvertTo-Json -InputObject ([ordered]@{ CloseBehavior = $Behavior }) -Compress
        $bytes = $script:TCWindowUtf8.GetPreamble() + $script:TCWindowUtf8.GetBytes($text)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
        $stream.Dispose(); $stream = $null
        $null = Assert-TCWindowPath $Path
        if ([IO.Directory]::Exists($Path)) { throw '[TC:WindowPath] 窗口偏好文件被同名目录占用。' }
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temp, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temp, $Path) }
    } finally {
        if ($stream) { $stream.Dispose() }
        if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
    }
}

function Get-TCWindowPreferences {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Root)
    $full = Resolve-TCWindowRoot $Root
    $result = Read-TCWindowSettings (Get-TCWindowSettingsPath $full)
    if ($result.Warning) { Write-Warning $result.Warning }
    return $result
}

function Set-TCWindowPreferences {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Root,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][ValidateSet('Tray', 'ExitInterface')][string]$CloseBehavior
    )
    $behavior = ConvertTo-TCWindowBehavior $CloseBehavior
    $full = Resolve-TCWindowRoot $Root -RequireExisting
    $path = Get-TCWindowSettingsPath $full
    $lock = $null
    try {
        $lock = Open-TCWindowLock $full
        $null = Resolve-TCWindowRoot $full -RequireExisting
        $prior = Read-TCWindowSettings $path
        $backup = ''
        if ($prior.Source -eq 'Corrupt') {
            $backup = Backup-TCWindowCorruptRecord $path
            Write-Warning ('窗口关闭偏好记录损坏，已保留备份：' + $backup)
        }
        Write-TCWindowAtomicSettings $path $behavior
        return (New-TCWindowResult $behavior $path 'Saved' '' $backup)
    } finally { if ($lock) { $lock.Dispose() } }
}

function Get-TCWindowClosePlan {
    [CmdletBinding()]
    param(
        [ValidateNotNullOrEmpty()][ValidateSet('Tray', 'ExitInterface')][string]$CloseBehavior = 'Tray',
        [bool]$TaskInProgress = $false
    )
    $behavior = ConvertTo-TCWindowBehavior $CloseBehavior
    $blocked = ($behavior -eq 'ExitInterface' -and $TaskInProgress)
    $action = if ($behavior -eq 'ExitInterface' -and -not $TaskInProgress) { 'Exit' } else { 'Hide' }
    $message = if ($blocked) {
        '任务正在执行，暂时不能退出界面；窗口将隐藏到托盘，任务继续执行，后台连接保持。任务完成后可再次退出界面。'
    } elseif ($action -eq 'Exit') {
        '退出界面，后台连接保持。'
    } else {
        '窗口隐藏到托盘，后台连接保持。'
    }
    return [pscustomobject][ordered]@{
        CloseBehavior = $behavior
        Action = $action
        TaskBlocked = [bool]$blocked
        TaskInProgress = $TaskInProgress
        KeepConnection = $true
        Message = $message
    }
}

Export-ModuleMember -Function Get-TCWindowPreferences, Set-TCWindowPreferences, Get-TCWindowClosePlan
