#requires -Version 5.1
[CmdletBinding()]
param()

# Offline regression: all data, links and subprocess fixtures stay in one private
# disposable directory. The only persistent output is the specified JSON report.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version 2
$package = Split-Path $PSScriptRoot -Parent
$workspace = Split-Path (Split-Path $package -Parent) -Parent
$modulePath = Join-Path $package 'WindowPreferences.psm1'
$reportPath = Join-Path $workspace 'reports\release-0.12.0\window-preferences-result.json'
$utf8 = New-Object Text.UTF8Encoding($true, $true)
$checks = New-Object 'Collections.Generic.List[string]'
$links = New-Object 'Collections.Generic.List[string]'
$processes = New-Object 'Collections.Generic.List[Diagnostics.Process]'
$work = Join-Path ([IO.Path]::GetTempPath()) ('TC-WindowPreferences-' + [guid]::NewGuid().ToString('N'))
$module = $null; $failure = $null; $cleanupVerified = $false
$childCount = 0; $concurrentReads = 0; $corruptCases = 0
$readContentionEvidence = [ordered]@{}
$started = [DateTime]::UtcNow
$timer = [Diagnostics.Stopwatch]::StartNew()

function Check {
    param([bool]$Condition, [string]$Label)
    if (-not $Condition) { throw ('Window preferences assertion failed: ' + $Label) }
    $checks.Add($Label)
}

function Reject {
    param([scriptblock]$Body, [string]$Label, [string]$Pattern = '')
    $caught = $null
    try { $null = & $Body } catch { $caught = $_ }
    Check ($null -ne $caught) $Label
    if ($Pattern) { Check ($null -ne $caught -and $caught.Exception.Message -match $Pattern) ($Label + ': readable error') }
}

function Write-Fixture {
    param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText($Path, $Text, $utf8)
}

function Hash {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function AclText {
    param([string]$Path)
    return (Get-Acl -LiteralPath $Path).Sddl
}

function AclPermissions {
    param([string]$Path)
    $acl = Get-Acl -LiteralPath $Path
    $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | ForEach-Object {
        '{0}|{1}|{2}|{3}|{4}|{5}' -f $_.IdentityReference.Value, $_.AccessControlType, [int]$_.FileSystemRights, $_.InheritanceFlags, $_.PropagationFlags, $_.IsInherited
    } | Sort-Object)
    # Windows can normalize the AutoInherited control bit when creating a copy.
    # Compare effective DACL entries, protection, owner and group, not that bit.
    return ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value + ';' + $acl.GetGroup([Security.Principal.SecurityIdentifier]).Value + ';' + $acl.AreAccessRulesProtected + ';' + ($rules -join ';'))
}

function PrivateDirectory {
    param([string]$Path)
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $sids = @('S-1-5-18', 'S-1-5-32-544', [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) | Select-Object -Unique
    foreach ($text in $sids) {
        $sid = New-Object Security.Principal.SecurityIdentifier($text)
        $null = $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
    }
    $null = [IO.Directory]::CreateDirectory($Path, $acl)
}

function Start-TestProcess {
    param([string]$Source)
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Source))
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = Join-Path $PSHOME 'powershell.exe'
    $info.Arguments = '-NoProfile -NonInteractive -OutputFormat Text -EncodedCommand ' + $encoded
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.WorkingDirectory = $work
    $info.EnvironmentVariables['PSModulePath'] = $env:ProgramFiles + '\WindowsPowerShell\Modules;' + $env:SystemRoot + '\System32\WindowsPowerShell\v1.0\Modules'
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    $null = $process.Start()
    $processes.Add($process)
    $script:childCount++
    return $process
}

function Finish-TestProcess {
    param([Diagnostics.Process]$Process, [string]$Label)
    if (-not $Process.WaitForExit(30000)) { $Process.Kill(); throw ($Label + ': process timed out') }
    $stdout = $Process.StandardOutput.ReadToEnd()
    $stderr = $Process.StandardError.ReadToEnd()
    Check ($Process.ExitCode -eq 0) ($Label + ': WinPS child exited successfully; ' + $stderr.Trim())
    return $stdout
}

function Assert-NoTemps {
    param([string]$Root, [string]$Label)
    Check (@([IO.Directory]::GetFiles($Root, '.ui-window-settings-*.tmp')).Count -eq 0) $Label
}

try {
    Check ($PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -eq 1 -and $PSVersionTable.PSEdition -eq 'Desktop') 'Runs on local Windows PowerShell 5.1 Desktop'
    Check ([Environment]::Version.Major -eq 4) 'Runs on .NET Framework CLR 4'
    foreach ($source in @($modulePath, $PSCommandPath)) {
        $bytes = [IO.File]::ReadAllBytes($source)
        Check ($bytes.Length -gt 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) ('UTF8 BOM: ' + [IO.Path]::GetFileName($source))
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
        Check ($errors.Count -eq 0) ('WinPS 5.1 parser: ' + [IO.Path]::GetFileName($source))
        if ($source -eq $modulePath) { $moduleAst = $ast }
    }
    # Allow only storage helpers and standard, non-network utility commands.
    $functions = @($moduleAst.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]}, $true))
    $allowed = @($functions | ForEach-Object { $_.Name }) + @('Set-StrictMode', 'New-Object', 'Join-Path', 'Select-Object', 'Start-Sleep', 'ConvertTo-Json', 'Write-Warning', 'Export-ModuleMember')
    $commands = @($moduleAst.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst]}, $true))
    Check (@($commands | Where-Object { -not $_.GetCommandName() -or $_.GetCommandName() -notin $allowed }).Count -eq 0) 'Module command audit: no imports, runtime, Connect, Disconnect, or network commands'
    $types = @($moduleAst.FindAll({param($n) $n -is [Management.Automation.Language.TypeExpressionAst]}, $true))
    Check (@($types | Where-Object { $_.TypeName.FullName -match '(?i)(Net\.|Management\.|Process|Registry|Service|Marshal|Activator|Assembly)' }).Count -eq 0) 'Module .NET audit: no network, process, registry, service or dynamic invocation APIs'
    $planAst = @($functions | Where-Object { $_.Name -eq 'Get-TCWindowClosePlan' })[0]
    $planCommands = @($planAst.Body.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst]}, $true))
    Check ($planCommands.Count -eq 1 -and $planCommands[0].GetCommandName() -eq 'ConvertTo-TCWindowBehavior') 'Close plan depends only on value normalization'
    Check (@($planAst.Body.FindAll({param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst]}, $true)).Count -eq 0) 'Close plan has no .NET calls or filesystem side effects'

    PrivateDirectory $work
    $beforeImport = @([IO.Directory]::GetFileSystemEntries($work)).Count
    $module = Import-Module $modulePath -Force -PassThru -DisableNameChecking
    Check (@([IO.Directory]::GetFileSystemEntries($work)).Count -eq $beforeImport) 'Import creates no fixture data'
    Check (@(Compare-Object @('Get-TCWindowPreferences', 'Set-TCWindowPreferences', 'Get-TCWindowClosePlan') @($module.ExportedFunctions.Keys)).Count -eq 0) 'Exactly the three requested functions are exported'
    $topCommands = @($moduleAst.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.PipelineAst] } | ForEach-Object { $_.PipelineElements } | Where-Object { $_ -is [Management.Automation.Language.CommandAst] } | ForEach-Object { $_.GetCommandName() })
    Check (@($topCommands | Where-Object { $_ -notin @('Set-StrictMode', 'Export-ModuleMember') }).Count -eq 0) 'Import statements cannot initialize production data or import another store'

    $root = Join-Path $work '窗口偏好 [可信]'
    PrivateDirectory $root
    $rootAcl = AclText $root
    $parentAcl = AclText $work
    $settings = Join-Path $root 'ui-window-settings.json'
    $connection = Join-Path $root 'ui-preferences.json'
    Write-Fixture $connection '{"Mode":"Trading","Exit":"HongKong","Daily":"Provider","NodeId":"fixture-node","ProviderId":"fixture-provider","Agents":true}'
    $connectionHash = Hash $connection
    $connectionAcl = AclText $connection
    $warnings = @()
    $result = @(Get-TCWindowPreferences -Root $root -WarningVariable warnings -WarningAction SilentlyContinue)
    Check ($result.Count -eq 1 -and $result[0].CloseBehavior -ceq 'Tray' -and $result[0].Defaulted) 'Empty existing root returns one default Tray object'
    Check (@($warnings).Count -eq 0 -and -not [IO.File]::Exists($settings)) 'Default read has no warning and writes no settings'
    $missing = Join-Path $work 'not-created\nested'
    Check ((Get-TCWindowPreferences -Root $missing).CloseBehavior -eq 'Tray' -and -not [IO.Directory]::Exists((Split-Path $missing -Parent))) 'Missing root reads default without creating any directory'
    Reject {Set-TCWindowPreferences -Root $missing -CloseBehavior Tray} 'Saving requires an existing trusted root' '\[TC:WindowPath\]'
    Check (-not [IO.Directory]::Exists((Split-Path $missing -Parent))) 'Rejected save creates no root'

    $saved = @(Set-TCWindowPreferences -Root $root -CloseBehavior ExitInterface)
    Check ($saved.Count -eq 1 -and $saved[0].CloseBehavior -ceq 'ExitInterface' -and $saved[0].Source -eq 'Saved') 'Initial atomic save returns the requested CloseBehavior'
    Check ((Get-TCWindowPreferences -Root $root).CloseBehavior -ceq 'ExitInterface') 'Initial save reads back'
    $bytes = [IO.File]::ReadAllBytes($settings)
    Check ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) 'Persisted record uses UTF8 BOM'
    $json = [IO.File]::ReadAllText($settings) | ConvertFrom-Json
    Check (@($json.PSObject.Properties).Count -eq 1 -and $json.CloseBehavior -eq 'ExitInterface') 'Window record contains only CloseBehavior'
    $security = Get-Acl -LiteralPath $settings
    $allowedSids = @('S-1-5-18', 'S-1-5-32-544', [Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
    Check ($security.AreAccessRulesProtected -and @($security.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | Where-Object { $_.AccessControlType -eq 'Allow' -and $_.IdentityReference.Value -notin $allowedSids }).Count -eq 0) 'New settings file grants no unrelated account access'

    $quotedModule = "'" + $modulePath.Replace("'", "''") + "'"
    $quotedRoot = "'" + $root.Replace("'", "''") + "'"
    $childSource = '$ErrorActionPreference="Stop";$ProgressPreference="SilentlyContinue";Import-Module ' + $quotedModule + ';$p=Get-TCWindowPreferences -Root ' + $quotedRoot + ';if($p.CloseBehavior -cne "ExitInterface"){throw "Restart preference mismatch"};$p | ConvertTo-Json -Compress'
    $child = Start-TestProcess $childSource
    $childResult = (Finish-TestProcess $child 'Fresh process restart read') | ConvertFrom-Json
    Check ($childResult.CloseBehavior -ceq 'ExitInterface') 'Preference survives a real WinPS process restart'
    Remove-Module $module.Name
    $module = Import-Module $modulePath -Force -PassThru -DisableNameChecking
    Check ((Get-TCWindowPreferences -Root $root).CloseBehavior -eq 'ExitInterface') 'Preference survives module reimport'
    $before = Hash $settings
    Check ((Set-TCWindowPreferences -Root $root -CloseBehavior Tray).CloseBehavior -ceq 'Tray') 'Overwrite save returns Tray'
    Check ((Hash $settings) -ne $before -and (Get-TCWindowPreferences -Root $root).CloseBehavior -eq 'Tray') 'Overwrite replaces the persisted value'
    Check ((Set-TCWindowPreferences -Root ($root + '\') -CloseBehavior exitinterface).CloseBehavior -ceq 'ExitInterface') 'Input casing normalizes and a trailing separator is supported'
    Check ((Get-TCWindowPreferences -Root $root.Replace('\', '/')).CloseBehavior -eq 'ExitInterface') 'Local absolute paths also support forward separators'
    Check ((Hash $connection) -ceq $connectionHash -and (AclText $connection) -ceq $connectionAcl) 'Connection preferences remain byte-for-byte and ACL identical after saves'
    Check ((AclText $root) -ceq $rootAcl -and (AclText $work) -ceq $parentAcl) 'Saves do not widen root or parent ACLs'
    Assert-NoTemps $root 'Successful saves leave no temporary files'

    # A held old reader sees its complete old record; a new reader sees the new one.
    $null = Set-TCWindowPreferences -Root $root -CloseBehavior Tray
    $oldReader = [IO.File]::Open($settings, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::Read -bor [IO.FileShare]::Delete))
    try {
        $null = Set-TCWindowPreferences -Root $root -CloseBehavior ExitInterface
        $reader = New-Object IO.StreamReader($oldReader, $utf8)
        try { $oldJson = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
        Check ($oldJson.CloseBehavior -eq 'Tray' -and (Get-TCWindowPreferences -Root $root).CloseBehavior -eq 'ExitInterface') 'Atomic replacement keeps old readers intact and publishes a complete new record'
    } finally { $oldReader.Dispose() }

    # A real sharing violation forces File.Replace to fail after staging the data.
    $priorHash = Hash $settings
    $held = [IO.File]::Open($settings, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try { Reject {Set-TCWindowPreferences -Root $root -CloseBehavior Tray} 'Destination without delete sharing rejects atomic replacement' }
    finally { $held.Dispose() }
    Check ((Hash $settings) -ceq $priorHash) 'Failed replacement preserves the original bytes'
    Assert-NoTemps $root 'Failed replacement removes its staged temporary file'
    Check ((Set-TCWindowPreferences -Root $root -CloseBehavior Tray).CloseBehavior -eq 'Tray') 'Failed replacement releases the writer lock'
    $lockPath = Join-Path $root '.ui-window-settings.lock'
    $lock = [IO.File]::Open($lockPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $priorHash = Hash $settings
    try { Reject {Set-TCWindowPreferences -Root $root -CloseBehavior ExitInterface} 'Writer lock contention times out cleanly' '\[TC:WindowBusy\]' }
    finally { $lock.Dispose() }
    Check ((Hash $settings) -ceq $priorHash) 'Contended save preserves settings'
    Check ((Set-TCWindowPreferences -Root $root -CloseBehavior ExitInterface).CloseBehavior -eq 'ExitInterface') 'Writer lock timeout leaves later saves usable'
    $priorHash = Hash $settings
    $held = [IO.File]::Open($settings, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $readWatch = [Diagnostics.Stopwatch]::StartNew()
    $readError = $null
    try { try { $null = Get-TCWindowPreferences -Root $root } catch { $readError = $_ } }
    finally { $held.Dispose() }
    $persistentReadMilliseconds = $readWatch.ElapsedMilliseconds
    Check ($null -ne $readError -and $readError.Exception.Message -match '\[TC:WindowRead\]') 'Unreadable occupied file is an IO error rather than silent corruption'
    $cause = $readError.Exception
    while ($cause.InnerException) { $cause = $cause.InnerException }
    Check ($cause -is [IO.IOException] -and $cause.HResult -eq -2147024864) 'Persistent sharing error retains original IOException 0x80070020'
    Check ($persistentReadMilliseconds -ge 500 -and $persistentReadMilliseconds -lt 3000) 'Persistent sharing contention has a bounded retry budget'
    $readContentionEvidence.PersistentHResult = ('0x{0:X8}' -f $cause.HResult)
    $readContentionEvidence.PersistentReadMilliseconds = $persistentReadMilliseconds

    # A real child holds an incompatible handle until the reader requests release.
    # The delay exposes a genuine sharing violation before returning saved data.
    $readyPath = Join-Path $work 'reader-holder-ready'
    $releasePath = Join-Path $work 'reader-holder-release'
    $holderSource = '$ErrorActionPreference="Stop";$held=[IO.File]::Open(''' + $settings.Replace("'", "''") + ''',[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);try{[IO.File]::WriteAllText(''' + $readyPath.Replace("'", "''") + ''',"ready");$watch=[Diagnostics.Stopwatch]::StartNew();while(-not [IO.File]::Exists(''' + $releasePath.Replace("'", "''") + ''')){if($watch.ElapsedMilliseconds -gt 10000){throw "Release handshake timed out"};[Threading.Thread]::Sleep(5)};[Threading.Thread]::Sleep(150)}finally{$held.Dispose()};"holder-complete"'
    $holder = Start-TestProcess $holderSource
    $readyWatch = [Diagnostics.Stopwatch]::StartNew()
    while (-not [IO.File]::Exists($readyPath) -and -not $holder.HasExited -and $readyWatch.ElapsedMilliseconds -lt 10000) { Start-Sleep -Milliseconds 10 }
    Check ([IO.File]::Exists($readyPath) -and -not $holder.HasExited) 'Transient sharing fixture acquired its incompatible handle'
    $probeError = $null
    try {
        $probe = [IO.File]::Open($settings, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::Read -bor [IO.FileShare]::Delete))
        $probe.Dispose()
    } catch { $probeError = $_ }
    Check ($null -ne $probeError) 'Transient sharing fixture actually blocks a reader before release'
    $cause = $probeError.Exception
    while ($cause.InnerException) { $cause = $cause.InnerException }
    Check ($cause -is [IO.IOException] -and $cause.HResult -eq -2147024864) 'Transient sharing fixture reproduces native ERROR_SHARING_VIOLATION'
    [IO.File]::WriteAllText($releasePath, 'release')
    $readWatch = [Diagnostics.Stopwatch]::StartNew()
    $afterSharing = Get-TCWindowPreferences -Root $root -WarningAction Stop
    $readContentionEvidence.TransientReadMilliseconds = $readWatch.ElapsedMilliseconds
    $readContentionEvidence.TransientSource = $afterSharing.Source
    Check ($afterSharing.Source -eq 'Saved' -and $afterSharing.CloseBehavior -ceq 'ExitInterface' -and -not $afterSharing.Defaulted) 'Transient sharing contention returns the actual saved preference'
    Check ((Finish-TestProcess $holder 'Transient sharing holder').Trim() -eq 'holder-complete') 'Transient sharing holder releases its handle normally'

    # Access denied must still surface as WindowRead with the original Win32 code.
    $deniedSecurity = [IO.File]::GetAccessControl($settings)
    $denyRead = New-Object Security.AccessControl.FileSystemAccessRule([Security.Principal.WindowsIdentity]::GetCurrent().User, 'ReadData', 'Deny')
    $null = $deniedSecurity.AddAccessRule($denyRead)
    $readError = $null
    try {
        [IO.File]::SetAccessControl($settings, $deniedSecurity)
        try { $null = Get-TCWindowPreferences -Root $root -WarningAction Stop } catch { $readError = $_ }
    } finally {
        $deniedSecurity.RemoveAccessRuleSpecific($denyRead)
        [IO.File]::SetAccessControl($settings, $deniedSecurity)
    }
    Check ($null -ne $readError -and $readError.Exception.Message -match '\[TC:WindowRead\]') 'Access denied is not returned as a default or corrupt preference'
    $cause = $readError.Exception
    while ($cause.InnerException) { $cause = $cause.InnerException }
    Check ($cause -is [UnauthorizedAccessException] -and $cause.HResult -eq -2147024891) 'Access denied retains original HRESULT 0x80070005'
    $readContentionEvidence.AccessDeniedHResult = ('0x{0:X8}' -f $cause.HResult)
    Check ((Hash $settings) -ceq $priorHash) 'Failed and retried reads preserve the saved bytes'

    # Preserve a custom tighter DACL through replacement, not merely a default ACL.
    $tight = New-Object Security.AccessControl.FileSecurity
    $tight.SetAccessRuleProtection($true, $false)
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $null = $tight.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'Allow')))
    [IO.File]::SetAccessControl($settings, $tight)
    $tightSddl = AclText $settings
    $null = Set-TCWindowPreferences -Root $root -CloseBehavior Tray
    Check ((AclText $settings) -ceq $tightSddl) 'Overwrite preserves a custom tighter file ACL'
    Check ((AclText $root) -ceq $rootAcl) 'Custom file ACL handling does not change directory ACL'

    $badRecords = @(
        '', '{', 'null', '42', '[]', '[{"CloseBehavior":"Tray"}]', '{}',
        '{"CloseBehavior":"Disconnect"}', '{"CloseBehavior":"tray"}',
        '{"CloseBehavior":true}', '{"CloseBehavior":null}', '{"CloseBehavior":1}',
        '{"CloseBehavior":"Tray","Mode":"Trading"}',
        '{"CloseBehavior":"Tray","CloseBehavior":"ExitInterface"}',
        '{"CloseBehavior":"Tray"} trailing', '{"closeBehavior":"Tray"}',
        '{"CloseBehavior":"Tray",}', '{/* comment */"CloseBehavior":"Tray"}'
    )
    foreach ($text in $badRecords) {
        Write-Fixture $settings $text
        $hash = Hash $settings; $acl = AclText $settings; $warnings = @()
        $read = @(Get-TCWindowPreferences -Root $root -WarningVariable warnings -WarningAction SilentlyContinue)
        $corruptCases++
        Check ($read.Count -eq 1 -and $read[0].CloseBehavior -eq 'Tray' -and $read[0].Source -eq 'Corrupt') ('Malformed/schema case ' + $corruptCases + ': one default Tray result')
        Check (@($warnings).Count -eq 1 -and [string]$warnings[0] -match '损坏.*Tray.*保留' -and $read[0].Warning) ('Malformed/schema case ' + $corruptCases + ': readable warning')
        Check ((Hash $settings) -ceq $hash -and (AclText $settings) -ceq $acl) ('Malformed/schema case ' + $corruptCases + ': original bytes and ACL retained')
    }
    foreach ($bytes in @([byte[]]@(239,187,191,255,254,192), [Text.Encoding]::Unicode.GetBytes('{"CloseBehavior":"ExitInterface"}'), (New-Object byte[] 16385))) {
        [IO.File]::WriteAllBytes($settings, $bytes)
        $hash = Hash $settings; $warnings = @()
        $read = Get-TCWindowPreferences -Root $root -WarningVariable warnings -WarningAction SilentlyContinue
        $corruptCases++
        Check ($read.CloseBehavior -eq 'Tray' -and $read.Source -eq 'Corrupt' -and @($warnings).Count -eq 1) ('Encoding/size case ' + $corruptCases + ': warning and default')
        Check ((Hash $settings) -ceq $hash) ('Encoding/size case ' + $corruptCases + ': exact original retained')
    }
    $valid = '{"CloseBehavior":"ExitInterface"}'
    Write-Fixture $settings ($valid + (' ' * (16384 - 3 - $valid.Length)))
    Check ((Get-TCWindowPreferences -Root $root).CloseBehavior -eq 'ExitInterface' -and (Get-Item -LiteralPath $settings).Length -eq 16384) 'Exactly 16 KiB remains readable'
    Write-Fixture $settings '{broken recovery record'
    $badHash = Hash $settings; $badPermissions = AclPermissions $settings; $warnings = @()
    $recovered = Set-TCWindowPreferences -Root $root -CloseBehavior ExitInterface -WarningVariable warnings -WarningAction SilentlyContinue
    Check ($recovered.CloseBehavior -eq 'ExitInterface' -and $recovered.Source -eq 'Saved' -and $recovered.CorruptBackupPath) 'Explicit save recovers corruption and returns its backup path'
    Check ((Hash $recovered.CorruptBackupPath) -ceq $badHash) 'Recovery backup retains original bytes'
    Check ((AclPermissions $recovered.CorruptBackupPath) -ceq $badPermissions) 'Recovery backup retains DACL permissions, protection, owner and group'
    Check (@($warnings).Count -eq 1 -and [string]$warnings[0] -match '损坏.*备份') 'Recovery save emits a readable backup warning'
    Check ((Get-TCWindowPreferences -Root $root).CloseBehavior -eq 'ExitInterface') 'Recovered value persists'
    $firstBackup = $recovered.CorruptBackupPath
    Write-Fixture $settings 'second broken record'
    $secondHash = Hash $settings
    $recovered = Set-TCWindowPreferences -Root $root -CloseBehavior Tray -WarningAction SilentlyContinue
    Check ($recovered.CorruptBackupPath -cne $firstBackup -and (Hash $firstBackup) -ceq $badHash -and (Hash $recovered.CorruptBackupPath) -ceq $secondHash) 'Repeated recovery uses unique backups and retains earlier corruption evidence'
    Assert-NoTemps $root 'Corruption recovery leaves no staging residue'

    $priorHash = Hash $settings
    $entries = @([IO.Directory]::GetFileSystemEntries($root)).Count
    foreach ($value in @('', ' ', 'Exit', 'Hide', 'Disconnect', 'Tray ', "Tray`n", '0', 1, $true, $null)) {
        $label = if ($null -eq $value) { '<null>' } else { '[' + [string]$value + ']' }
        Reject {Set-TCWindowPreferences -Root $root -CloseBehavior $value} ('Invalid saved CloseBehavior ' + $label)
        Reject {Get-TCWindowClosePlan -CloseBehavior $value} ('Invalid planned CloseBehavior ' + $label)
    }
    Check ((Hash $settings) -ceq $priorHash -and @([IO.Directory]::GetFileSystemEntries($root)).Count -eq $entries) 'Invalid values do not write settings, locks, backups or temporary files'
    $invalidPaths = @('', ' ', '.', 'relative\root', 'C:relative', '\rooted-without-drive', '\\localhost\share', '\\?\C:\device', 'FileSystem::C:\provider', 'HKCU:\Software', 'C:\',
        ($work + '\bad:stream'), ($work + '\wild*card'), ($work + '\wild?card'), ($work + '\bad|path'), ($work + '\bad"path'), ($work + '\..\escape'),
        ($work + '\.\escape'), ($work + '\trailing.'), ($work + '\trailing '), ($work + '\NUL'), ($work + '\CON.txt'), ($work + '\COM1'), ($work + "\control`nname"))
    foreach ($path in $invalidPaths) {
        Reject {Get-TCWindowPreferences -Root $path} ('Invalid read path: ' + $path)
        Reject {Set-TCWindowPreferences -Root $path -CloseBehavior Tray} ('Invalid save path: ' + $path)
    }
    Reject {Get-TCWindowPreferences -Root $null} 'Null root rejected'
    Reject {Set-TCWindowPreferences -Root $null -CloseBehavior Tray} 'Null save root rejected'
    $fileRoot = Join-Path $work 'root-is-file'
    Write-Fixture $fileRoot 'fixture'
    Reject {Get-TCWindowPreferences -Root $fileRoot} 'File cannot be read as root' '\[TC:WindowPath\]'
    Reject {Set-TCWindowPreferences -Root $fileRoot -CloseBehavior Tray} 'File cannot be written as root' '\[TC:WindowPath\]'
    Reject {Get-TCWindowPreferences -Root (Join-Path $fileRoot 'nested')} 'File ancestor cannot be mistaken for missing root' '\[TC:WindowPath\]'
    Reject {Set-TCWindowPreferences -Root (Join-Path $fileRoot 'nested') -CloseBehavior Tray} 'File ancestor cannot be used for save' '\[TC:WindowPath\]'
    $occupied = Join-Path $work 'occupied-file'
    PrivateDirectory $occupied
    PrivateDirectory (Join-Path $occupied 'ui-window-settings.json')
    Reject {Get-TCWindowPreferences -Root $occupied} 'Directory cannot be read as settings file' '\[TC:WindowPath\]'
    Reject {Set-TCWindowPreferences -Root $occupied -CloseBehavior Tray} 'Directory cannot be overwritten as settings file' '\[TC:WindowPath\]'
    $occupiedLock = Join-Path $work 'occupied-lock'
    PrivateDirectory $occupiedLock
    PrivateDirectory (Join-Path $occupiedLock '.ui-window-settings.lock')
    Reject {Set-TCWindowPreferences -Root $occupiedLock -CloseBehavior Tray} 'Directory cannot be used as writer lock' '\[TC:WindowPath\]'

    $target = Join-Path $work 'link-target'
    PrivateDirectory $target
    PrivateDirectory (Join-Path $target 'nested')
    $targetFile = Join-Path $target 'ui-window-settings.json'
    Write-Fixture $targetFile '{"CloseBehavior":"ExitInterface"}'
    $targetHash = Hash $targetFile
    $junction = Join-Path $work 'root-junction'
    $null = New-Item -ItemType Junction -Path $junction -Value $target
    $links.Add($junction)
    Check (([IO.File]::GetAttributes($junction) -band [IO.FileAttributes]::ReparsePoint) -ne 0) 'Fixture uses a real directory junction'
    foreach ($path in @($junction, (Join-Path $junction 'nested'), (Join-Path $junction 'missing'))) {
        Reject {Get-TCWindowPreferences -Root $path} ('Reparse root/ancestor rejected for read: ' + $path) '\[TC:WindowPath\]'
        Reject {Set-TCWindowPreferences -Root $path -CloseBehavior Tray} ('Reparse root/ancestor rejected for save: ' + $path) '\[TC:WindowPath\]'
    }
    $linkedRoot = Join-Path $work 'linked-settings'
    PrivateDirectory $linkedRoot
    $linkedSettings = Join-Path $linkedRoot 'ui-window-settings.json'
    $null = New-Item -ItemType SymbolicLink -Path $linkedSettings -Value $targetFile
    $links.Add($linkedSettings)
    Reject {Get-TCWindowPreferences -Root $linkedRoot} 'Settings file symbolic link rejected for read' '\[TC:WindowPath\]'
    Reject {Set-TCWindowPreferences -Root $linkedRoot -CloseBehavior Tray} 'Settings file symbolic link rejected for save' '\[TC:WindowPath\]'
    $brokenRoot = Join-Path $work 'broken-link'
    PrivateDirectory $brokenRoot
    $brokenSettings = Join-Path $brokenRoot 'ui-window-settings.json'
    $brokenTarget = Join-Path $target 'absent.json'
    Write-Fixture $brokenTarget '{}'
    $null = New-Item -ItemType SymbolicLink -Path $brokenSettings -Value $brokenTarget
    $links.Add($brokenSettings)
    [IO.File]::Delete($brokenTarget)
    Reject {Get-TCWindowPreferences -Root $brokenRoot} 'Dangling settings symbolic link rejected for read' '\[TC:WindowPath\]'
    Reject {Set-TCWindowPreferences -Root $brokenRoot -CloseBehavior Tray} 'Dangling settings symbolic link rejected for save' '\[TC:WindowPath\]'
    $lockRoot = Join-Path $work 'linked-lock'
    PrivateDirectory $lockRoot
    $linkedLock = Join-Path $lockRoot '.ui-window-settings.lock'
    $null = New-Item -ItemType SymbolicLink -Path $linkedLock -Value $targetFile
    $links.Add($linkedLock)
    Reject {Set-TCWindowPreferences -Root $lockRoot -CloseBehavior Tray} 'Writer lock symbolic link rejected' '\[TC:WindowPath\]'
    Check ((Hash $targetFile) -ceq $targetHash -and -not [IO.File]::Exists((Join-Path $lockRoot 'ui-window-settings.json'))) 'Rejected links do not change their target or create settings'

    # Atomic replacement must also leave a connection file hard-link intact.
    $hardRoot = Join-Path $work 'hard-link'
    PrivateDirectory $hardRoot
    $hardSettings = Join-Path $hardRoot 'ui-window-settings.json'
    $hardConnection = Join-Path $hardRoot 'ui-preferences.json'
    [IO.File]::Copy($connection, $hardConnection)
    $null = New-Item -ItemType HardLink -Path $hardSettings -Value $hardConnection
    $hardResult = Set-TCWindowPreferences -Root $hardRoot -CloseBehavior ExitInterface -WarningAction SilentlyContinue
    Check ($hardResult.CloseBehavior -eq 'ExitInterface' -and (Hash $hardConnection) -ceq $connectionHash -and (Hash $connection) -ceq $connectionHash) 'Atomic recovery of hard-linked settings leaves connection preferences untouched'
    Check ((Hash $hardResult.CorruptBackupPath) -ceq $connectionHash -and (Get-TCWindowPreferences -Root $hardRoot).CloseBehavior -eq 'ExitInterface') 'Hard-link recovery retains the old record and publishes independent window preferences'

    $plansBefore = Hash $settings
    $entryCount = @([IO.Directory]::GetFileSystemEntries($root)).Count
    foreach ($behavior in @('Tray', 'ExitInterface')) {
        foreach ($busy in @($false, $true)) {
            $plan = @(Get-TCWindowClosePlan -CloseBehavior $behavior -TaskInProgress $busy)
            $expected = if ($behavior -eq 'ExitInterface' -and -not $busy) { 'Exit' } else { 'Hide' }
            $blocked = ($behavior -eq 'ExitInterface' -and $busy)
            Check ($plan.Count -eq 1 -and $plan[0].Action -ceq $expected -and $plan[0].TaskBlocked -is [bool] -and $plan[0].TaskBlocked -eq $blocked) ('Close plan contract: ' + $behavior + ', busy=' + $busy)
            Check ($plan[0].KeepConnection -eq $true -and $plan[0].TaskInProgress -eq $busy -and $plan[0].Message -match '后台连接保持') ('Close plan retains background connection: ' + $behavior + ', busy=' + $busy)
            if ($blocked) { Check ($plan[0].Message -match '任务.*不能退出.*隐藏.*任务继续执行') 'Busy exit clearly explains task protection and hide fallback' }
        }
    }
    $defaultPlan = Get-TCWindowClosePlan
    Check ($defaultPlan.CloseBehavior -ceq 'Tray' -and $defaultPlan.Action -ceq 'Hide' -and $defaultPlan.TaskBlocked -eq $false) 'Default close plan is idle Tray/Hide'
    Check ((Hash $settings) -ceq $plansBefore -and @([IO.Directory]::GetFileSystemEntries($root)).Count -eq $entryCount) 'All close plans leave persisted preferences and files unchanged'

    $writerSource = '$ErrorActionPreference="Stop";$ProgressPreference="SilentlyContinue";Import-Module ' + $quotedModule + ';for($i=0;$i -lt 40;$i++){$b=if($i%2){"ExitInterface"}else{"Tray"};$null=Set-TCWindowPreferences -Root ' + $quotedRoot + ' -CloseBehavior $b;Start-Sleep -Milliseconds 5};"writer-complete"'
    $writer = Start-TestProcess $writerSource
    $readerTimer = [Diagnostics.Stopwatch]::StartNew()
    $allWhole = $true
    $concurrentSources = @{}
    while (-not $writer.HasExited -and $readerTimer.ElapsedMilliseconds -lt 30000) {
        $read = Get-TCWindowPreferences -Root $root -WarningAction Stop
        if(-not $concurrentSources.ContainsKey($read.Source)){$concurrentSources[$read.Source]=0}
        $concurrentSources[$read.Source]++
        if ($read.Source -ne 'Saved' -or $read.CloseBehavior -cnotin @('Tray', 'ExitInterface')) { $allWhole = $false }
        $concurrentReads++
        Start-Sleep -Milliseconds 2
    }
    $writerOutput = Finish-TestProcess $writer 'Concurrent atomic writer'
    Check ($allWhole -and $concurrentReads -gt 0 -and $writerOutput.Trim() -eq 'writer-complete') ('Concurrent readers observe only complete old or new records; sources='+($concurrentSources|ConvertTo-Json -Compress)+'; writer='+$writerOutput.Trim())
    Check ((Get-TCWindowPreferences -Root $root).CloseBehavior -ceq 'ExitInterface') 'Concurrent writes publish the final intended value'
    Assert-NoTemps $root 'Concurrent saves leave no staging files'
    Check ((Hash $connection) -ceq $connectionHash -and (AclText $connection) -ceq $connectionAcl) 'Connection preferences bytes and ACL remain unchanged across every boundary'
    Check ((AclText $root) -ceq $rootAcl -and (AclText $work) -ceq $parentAcl -and (AclText $settings) -ceq $tightSddl) 'All operations retain original directory ACLs and the tighter settings ACL'
} catch { $failure = $_ }
finally {
    try {
        foreach ($process in $processes) {
            if (-not $process.HasExited) { $process.Kill(); $null = $process.WaitForExit(5000) }
            $process.Dispose()
        }
        if ($module) { Remove-Module $module.Name -ErrorAction SilentlyContinue }
        $full = [IO.Path]::GetFullPath($work).TrimEnd('\')
        $prefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        if (-not ($full + '\').StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notmatch '^TC-WindowPreferences-[a-f0-9]{32}$') { throw 'Cleanup rejected: untrusted fixture root.' }
        if ([IO.Directory]::Exists($full)) {
            if ([IO.File]::GetAttributes($full) -band [IO.FileAttributes]::ReparsePoint) { throw 'Cleanup rejected: fixture root became a reparse point.' }
            # Delete our links nonrecursively before any recursive cleanup in WinPS.
            foreach ($link in $links) {
                $linkFull = [IO.Path]::GetFullPath($link)
                if (-not $linkFull.StartsWith($full + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Cleanup rejected: link outside fixture root.' }
                $attributes = [IO.File]::GetAttributes($linkFull)
                if (-not ($attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Cleanup rejected: expected test link changed type.' }
                if ($attributes -band [IO.FileAttributes]::Directory) { [IO.Directory]::Delete($linkFull) }
                else { [IO.File]::Delete($linkFull) }
            }
            if (@(Get-ChildItem -LiteralPath $full -Force -Recurse | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) { throw 'Cleanup rejected: untracked reparse point.' }
            Remove-Item -LiteralPath $full -Recurse -Force
        }
        $cleanupVerified = -not [IO.Directory]::Exists($full)
        Check $cleanupVerified 'Trusted temporary fixtures and all subprocesses cleaned up'
    } catch { if (-not $failure) { $failure = $_ } }
    $timer.Stop()
    $errorText = if ($failure) { $failure.Exception.Message + ' | ' + $failure.ScriptStackTrace } else { '' }
    $report = [pscustomobject][ordered]@{
        Passed = ($null -eq $failure)
        AssertionCount = $checks.Count
        Checks = $checks.Count
        RegressionFileCount = 1
        CheckedFileCount = 2
        CheckedFiles = @($modulePath, $PSCommandPath)
        SourceSHA256 = [ordered]@{ Module = (Hash $modulePath); Test = (Hash $PSCommandPath) }
        PowerShellVersion = $PSVersionTable.PSVersion.ToString()
        PSEdition = $PSVersionTable.PSEdition
        CLRVersion = [Environment]::Version.ToString()
        PowerShellExecutable = Join-Path $PSHOME 'powershell.exe'
        StartedAtUtc = $started.ToString('o')
        DurationSeconds = [Math]::Round($timer.Elapsed.TotalSeconds, 3)
        ChildProcessCount = $childCount
        ConcurrentReadCount = $concurrentReads
        CorruptRecordCaseCount = $corruptCases
        ReadContentionEvidence = $readContentionEvidence
        TemporaryDataOnly = $true
        FixtureCleanupVerified = $cleanupVerified
        RealNetworkChanges = 0
        ConnectionPreferencesUnchanged = ($null -eq $failure)
        RootAclUnchanged = ($null -eq $failure)
        Assertions = @($checks.ToArray())
        Error = $errorText
    }
    # This is the sole permitted persistent output; reject reparse report parents.
    $reportParent = [IO.Path]::GetDirectoryName($reportPath)
    if (-not [IO.Directory]::Exists($reportParent)) { throw 'Expected report directory does not exist.' }
    $cursor = $reportPath
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Report path is a reparse point.' }
        }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
    [IO.File]::WriteAllText($reportPath, ($report | ConvertTo-Json -Depth 8), $utf8)
}
$report | Select-Object Passed, AssertionCount, RegressionFileCount, CheckedFileCount, PowerShellVersion, CLRVersion, ChildProcessCount, ConcurrentReadCount, CorruptRecordCaseCount, FixtureCleanupVerified, RealNetworkChanges, DurationSeconds, Error | ConvertTo-Json -Depth 4
if ($failure) { throw $failure }
