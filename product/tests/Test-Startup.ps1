#requires -Version 5.1
<#
Run in elevated Windows PowerShell 5.1. Standalone offline tests; no Pester.
Only disposable fixtures have real file/ACL changes. Task Scheduler is replaced
at its COM-folder boundary, including reads. Fixture executables are inert text.
The repository's package.sha256, live tasks, registry and network are never used.
#>
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Startup.psm1'
$workspace = Join-Path ([IO.Path]::GetTempPath()) ('ProductTests-Startup-'+[guid]::NewGuid().ToString('N'))
$module = $null
try {
    foreach ($path in @($modulePath,$PSCommandPath)) {
        $bytes = [IO.File]::ReadAllBytes($path)
        if ($bytes.Length -lt 3 -or $bytes[0] -ne 239 -or $bytes[1] -ne 187 -or $bytes[2] -ne 191) { throw ('UTF8 BOM required: '+$path) }
        $tokens=$null; $parseErrors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$parseErrors)
        if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
        if (@($ast.FindAll({param($node) $node -is [Management.Automation.Language.VariableExpressionAst] -and $node.VariablePath.UserPath -match '(^|:)(HOME|Host)$'},$true)).Count) { throw 'Reserved automatic variable used.' }
    }
    $module = Import-Module $modulePath -Force -PassThru
    $result = & $module {
        param($TestRoot)
        $script:Checks = 0
        function Assert-Startup {
            param([bool]$Condition,[string]$Label)
            if (-not $Condition) { throw ('Assertion failed: '+$Label) }
            $script:Checks++
        }
        function Assert-Rejected {
            param([scriptblock]$Action,[string]$Label,[string]$Message='')
            $failure=$null
            try { $null=& $Action } catch { $failure=$_ }
            Assert-Startup ($null -ne $failure) $Label
            if ($Message) { Assert-Startup ($failure.Exception.Message -match $Message) ($Label+': reason') }
        }
        $script:Calls = New-Object 'Collections.Generic.List[object]'
        $script:FakeTasks = @{}
        $script:ReadFailure = $false
        $script:RegisterFailure = $false
        $script:BadReadback = $false
        $script:IgnoreDelete = $false
        $script:ReadCount = 0
        $script:InjectOnRead = 0
        $script:Context = [pscustomobject]@{UserSid='S-1-5-21-101-102-103-1001'; IsAdministrator=$true; IsInteractive=$true; CommonAppData=(Join-Path $TestRoot 'common data')}
        # This is the only scheduler adapter replaced. Real Read/Register/Delete
        # code runs against these script methods, including exact native flags.
        $script:Folder = [pscustomobject]@{}
        $script:Folder | Add-Member ScriptMethod GetTask {
            param($Name)
            $script:ReadCount++
            if ($script:ReadFailure) { throw [UnauthorizedAccessException]::new('mock scheduler access denied') }
            if ($script:InjectOnRead -eq $script:ReadCount) {
                $script:FakeTasks[$Name].Xml = $script:FakeTasks[$Name].Xml.Replace('InteractiveToken','S4U')
            }
            if (-not $script:FakeTasks.ContainsKey($Name)) { throw [Runtime.InteropServices.COMException]::new('mock task not found',-2147024894) }
            return $script:FakeTasks[$Name]
        }
        $script:Folder | Add-Member ScriptMethod RegisterTask {
            param($Name,$Xml,$Flags,$UserId,$Password,$LogonType,$Sddl)
            $script:Calls.Add([pscustomobject]@{Operation='Register';Name=$Name;Xml=$Xml;Flags=$Flags;UserId=$UserId;Password=$Password;LogonType=$LogonType;Sddl=$Sddl})
            if ($script:RegisterFailure) { throw 'mock registration failure' }
            if ($Flags -eq 18 -and $script:FakeTasks.ContainsKey($Name)) { throw 'mock create refuses collision' }
            if ($Flags -eq 20 -and -not $script:FakeTasks.ContainsKey($Name)) { throw 'mock update refuses missing task' }
            if ($Flags -notin @(18,20)) { throw 'Unsafe registration flags.' }
            $doc=[xml]$Xml
            # Exercise ordinary scheduler normalization without touching real tasks.
            $null=$doc.Task.Actions.Exec.RemoveChild($doc.Task.Actions.Exec.SelectSingleNode('*[local-name()="Arguments"]'))
            if ($script:BadReadback) { $doc.Task.Actions.Exec.Command='C:\Users\Public\TradeChannel.exe' }
            $task=[pscustomobject]@{Name=$Name;Path=('\'+$Name);Enabled=$true;Xml=$doc.OuterXml;Sddl=$Sddl}
            $task | Add-Member ScriptMethod GetSecurityDescriptor { param($Flags) if ($Flags -ne 7) { throw 'Expected owner/group/DACL read.' }; return $this.Sddl }
            $task | Add-Member ScriptMethod Run { throw 'Task Run is forbidden.' }
            $script:FakeTasks[$Name]=$task
            return $task
        }
        $script:Folder | Add-Member ScriptMethod DeleteTask {
            param($Name,$Flags)
            $script:Calls.Add([pscustomobject]@{Operation='Delete';Name=$Name;Flags=$Flags})
            if ($Flags -ne 0) { throw 'Unexpected delete flags.' }
            if (-not $script:IgnoreDelete) { $script:FakeTasks.Remove($Name) }
        }
        function script:Get-TCStartupTaskFolder { return $script:Folder }
        function script:Get-TCStartupContext { return $script:Context }
        function script:Start-Process { throw 'Process launch forbidden.' }
        function script:Invoke-TCCommand { throw 'Connection action forbidden.' }
        function script:Register-ScheduledTask { throw 'Live task mutation forbidden.' }
        function script:Unregister-ScheduledTask { throw 'Live task mutation forbidden.' }
        function script:Invoke-WebRequest { throw 'Network forbidden.' }
        function script:New-ItemProperty { throw 'Registry mutation forbidden.' }

        $null=[IO.Directory]::CreateDirectory($TestRoot,(New-TCStartupAcl -Directory))
        New-TCStartupDirectory $script:Context.CommonAppData
        $source=Join-Path $TestRoot '桌面 source [fixture]'
        $null=[IO.Directory]::CreateDirectory($source)
        $utf8=New-Object Text.UTF8Encoding($true)
        $files=@('LinuxServerSetup.psm1','linux\tradechannel_linux.py','linux\Invoke-LinuxConsole.ps1','ui\LinuxPages.ps1','TradeChannel.exe','TradeChannel.ps1','Worker.ps1','RuntimeBridge.psm1','ProviderBridge.psm1','NodeStore.psm1','ServerSetup.psm1','Startup.psm1','ui\Shell.xaml','assets\sing-box.exe','assets\wg.exe',
            'runtime\Invoke-TradeChannel.ps1','runtime\Run-TradeChannel.ps1','runtime\Set-TradeChannelExit.ps1','runtime\Set-TradeChannelMode.ps1','runtime\Test-SelectedTradeExit.ps1','runtime\TradeChannel.Proxy.ps1','runtime\TradeChannel.Provider.ps1','runtime\TradeChannel.Providers.ps1','runtime\TradeChannel.ProviderSetup.ps1','runtime\Set-TradeChannelDaily.ps1','runtime\TradeChannel.Agents.ps1','runtime\Set-TradeChannelAgents.ps1','runtime\TradeChannel.State.ps1','runtime\TradeChannelGuard.cs','docs\说明.txt')
        foreach ($relative in $files) {
            $path=Join-Path $source $relative
            $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
            [IO.File]::WriteAllText($path,('inert fixture: '+$relative),$utf8)
        }
        function Write-FixtureManifest {
            param([string]$Directory)
            $rows=@(Get-ChildItem -LiteralPath $Directory -Recurse -File -Force | Where-Object {$_.Name -ne 'package.sha256'} | Sort-Object FullName | ForEach-Object {
                (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash+'|'+$_.FullName.Substring($Directory.Length+1)
            })
            [IO.File]::WriteAllLines((Join-Path $Directory 'package.sha256'),$rows,(New-Object Text.UTF8Encoding($true)))
        }
        Write-FixtureManifest $source
        $manifest=Join-Path $source 'package.sha256'
        $originalManifest=[IO.File]::ReadAllText($manifest)
        $packageHash=(Get-FileHash -LiteralPath $manifest).Hash
        $layout=Get-TCStartupLayout $script:Context.UserSid $script:Context.CommonAppData
        $plan=New-TCStartupPlan -UserSid $layout.UserSid -CommonAppData $layout.CommonAppData -OwnerId ('a'*32) -PackageHash $packageHash
        $other=New-TCStartupPlan -UserSid 'S-1-5-21-101-102-103-1002' -CommonAppData $layout.CommonAppData -OwnerId ('a'*32) -PackageHash $packageHash
        Assert-Startup ($plan.TaskName -ne $other.TaskName -and $plan.StageRoot -ne $other.StageRoot) 'per-user task and staging identity'
        Assert-Startup ($plan.Action.Execute -ceq (Join-Path (Join-Path $layout.StageRoot $packageHash) 'TradeChannel.exe') -and $plan.Action.Arguments -ceq '' -and -not $plan.AutoConnect) 'plan action opens only UI from staged executable'
        Assert-Startup ($plan.Action.WorkingDirectory -ceq $plan.PackageDirectory -and -not $plan.Xml.Contains($source)) 'plan never refers to source desktop'
        Assert-Startup ($plan.Xml -ceq (New-TCStartupPlan -UserSid $layout.UserSid -CommonAppData $layout.CommonAppData -OwnerId ('a'*32) -PackageHash $packageHash).Xml -and $script:Calls.Count -eq 0 -and -not (Test-Path -LiteralPath $layout.ProductRoot)) 'plan is deterministic and has no IO'
        foreach ($sid in @('S-1-5-18','S-1-5-19','S-1-5-20','S-1-5-32-544','..\bad')) {
            Assert-Rejected {New-TCStartupPlan -UserSid $sid -CommonAppData $layout.CommonAppData -OwnerId ('a'*32) -PackageHash $packageHash} ('reject service/group/invalid SID '+$sid)
        }
        Assert-Rejected {New-TCStartupPlan -UserSid $layout.UserSid -CommonAppData '\\server\share' -OwnerId ('a'*32) -PackageHash $packageHash} 'reject remote staging'
        $status=Get-TCStartup
        Assert-Startup (-not $status.Enabled -and $status.Detail -match '默认' -and $script:Calls.Count -eq 0 -and -not (Test-Path -LiteralPath $layout.ProductRoot)) 'default off; Get creates nothing'
        $status=Set-TCStartup -Enabled $false -SourceDirectory 'Z:\does-not-exist'
        Assert-Startup (-not $status.Enabled -and $script:Calls.Count -eq 0 -and -not (Test-Path -LiteralPath $layout.ProductRoot)) 'disable absent task is a no-op independent of source'
        $script:ReadFailure=$true
        Assert-Startup (-not (Get-TCStartup).Enabled -and (Get-TCStartup).Detail -match 'access denied') 'read failure is unverified, not silently absent'
        Assert-Rejected {Set-TCStartup -Enabled $true -SourceDirectory $source} 'scheduler read error blocks registration'
        $script:ReadFailure=$false
        foreach ($field in @('IsAdministrator','IsInteractive')) {
            $script:Context.$field=$false
            Assert-Rejected {Set-TCStartup -Enabled $true -SourceDirectory $source} ('identity gate '+$field)
            $script:Context.$field=$true
        }

        $payload=Join-Path $source 'Worker.ps1'; $originalPayload=[IO.File]::ReadAllBytes($payload)
        [IO.File]::WriteAllText($payload,'tampered')
        Assert-Rejected {Set-TCStartup -Enabled $true -SourceDirectory $source} 'source hash mismatch' '校验失败'
        [IO.File]::Delete($payload)
        Assert-Rejected {Set-TCStartup -Enabled $true -SourceDirectory $source} 'source file missing' '缺失'
        [IO.File]::WriteAllBytes($payload,$originalPayload)
        $extra=Join-Path $source 'extra.dll'; [IO.File]::WriteAllText($extra,'unlisted')
        Assert-Rejected {Set-TCStartup -Enabled $true -SourceDirectory $source} 'unlisted payload rejected' '未校验'
        [IO.File]::Delete($extra)
        $badRows=@(
            ('0'*64+'|..\outside.exe'), ('0'*64+'|C:\outside.exe'), ('0'*64+'|assets\wg.exe:ads'),
            ('0'*64+'|assets\\wg.exe'), ('0'*64+'|assets\..\wg.exe'), ('0'*64+'|assets\wg.exe.'),
            ('0'*64+'|assets\CON.txt'), ('0'*64+'|package.sha256'), ('0'*64+'|tradechannel.EXE'), 'invalid'
        )
        foreach ($row in $badRows) {
            [IO.File]::WriteAllText($manifest,$originalManifest+"`r`n"+$row,$utf8)
            Assert-Rejected {Set-TCStartup -Enabled $true -SourceDirectory $source} ('manifest path/format rejection: '+$row)
        }
        [IO.File]::WriteAllText($manifest,($originalManifest -replace '(?m)^\w{64}\|Worker\.ps1\r?\n?',''),$utf8)
        [IO.File]::Delete($payload)
        Assert-Rejected {Set-TCStartup -Enabled $true -SourceDirectory $source} 'required file cannot be removed together with manifest row' '必需'
        [IO.File]::WriteAllBytes($payload,$originalPayload)
        [IO.File]::WriteAllText($manifest,$originalManifest,$utf8)
        Assert-Startup ($script:Calls.Count -eq 0 -and -not (Test-Path -LiteralPath $layout.ProductRoot)) 'all invalid sources rejected before staging or tasks'

        # Real junctions exercise root, ancestor, nested and staging path handling.
        $outside=Join-Path $TestRoot 'junction-target'; $null=[IO.Directory]::CreateDirectory($outside)
        [IO.File]::WriteAllText((Join-Path $outside 'sentinel.txt'),'untouched')
        $link=Join-Path $TestRoot 'source-link'
        $null=New-Item -ItemType Junction -Path $link -Target ([Management.Automation.WildcardPattern]::Escape($source))
        try {
            Assert-Rejected {Set-TCStartup -Enabled $true -SourceDirectory $link} 'source root reparse rejected' 'reparse'
            Assert-Rejected {Assert-TCStartupPath (Join-Path $link 'Worker.ps1')} 'source ancestor reparse rejected' 'reparse'
        } finally { [IO.Directory]::Delete($link) }
        $link=Join-Path $source 'linked-directory'; $null=New-Item -ItemType Junction -Path $link -Target $outside
        try { Assert-Rejected {Set-TCStartup -Enabled $true -SourceDirectory $source} 'nested package reparse rejected' 'reparse' } finally { [IO.Directory]::Delete($link) }
        New-TCStartupDirectory $layout.ProductRoot -Parent
        New-TCStartupDirectory $layout.StartupRoot
        $null=New-Item -ItemType Junction -Path $layout.StageRoot -Target $outside
        try { Assert-Rejected {Set-TCStartup -Enabled $true -SourceDirectory $source} 'staging reparse rejected' 'reparse' } finally { [IO.Directory]::Delete($layout.StageRoot) }
        Assert-Startup ([IO.File]::ReadAllText((Join-Path $outside 'sentinel.txt')) -ceq 'untouched') 'reparse target untouched'

        $status=Set-TCStartup -Enabled $true -SourceDirectory $source
        Assert-Startup ($status.Enabled -and $status.Detail -match '不会自动连接' -and $script:Calls.Count -eq 1) 'enable registers once and opens no UI now'
        $registration=$script:Calls[0]
        Assert-Startup ($registration.Flags -eq 18 -and $registration.LogonType -eq 3 -and $registration.UserId -ceq $layout.UserSid -and $null -eq $registration.Password) 'interactive current SID; create-only; no principal ACE or password'
        $task=$script:FakeTasks[$layout.TaskName]; $savedXml=$task.Xml; $savedSddl=$task.Sddl
        $ownedPlan=Get-TCStartupOwnedPlan (Read-TCStartupTask $layout) $layout
        $stage=$ownedPlan.PackageDirectory
        $xml=[xml]$task.Xml
        Assert-Startup ($xml.Task.Principals.Principal.RunLevel -ceq 'HighestAvailable' -and $xml.Task.Principals.Principal.LogonType -ceq 'InteractiveToken' -and $xml.Task.Triggers.LogonTrigger.UserId -ceq $layout.UserSid -and $xml.Task.Actions.Exec.Command -ceq (Join-Path $stage 'TradeChannel.exe')) 'highest privilege only at this user logon, exact UI command'
        Assert-Startup ($xml.Task.Settings.StartWhenAvailable -ceq 'false' -and $xml.Task.Settings.AllowStartOnDemand -ceq 'false' -and $xml.Task.Settings.RunOnlyIfNetworkAvailable -ceq 'false') 'no immediate/missed/demand/network trigger'
        $staged=@(Get-TCStartupInventory $stage -Restricted)
        Assert-Startup ($staged.Count -eq ($files.Count+1)) 'all manifest files staged with restricted ACL'
        foreach ($relative in $files) { Assert-Startup ((Get-FileHash -LiteralPath (Join-Path $stage $relative)).Hash -ceq (Get-FileHash -LiteralPath (Join-Path $source $relative)).Hash) ('staged bytes: '+$relative) }
        Assert-Startup ((Get-TCStartup).Enabled -and $script:Calls.Count -eq 1) 'read verified enabled state without writes'
        $null=Set-TCStartup -Enabled $true -SourceDirectory $source
        Assert-Startup ($script:Calls.Count -eq 1) 'same package enable idempotent despite normalized XML'
        [IO.File]::WriteAllText($payload,'source later changed')
        Assert-Startup ((Get-TCStartup).Enabled) 'later desktop changes cannot alter staged startup'
        [IO.File]::WriteAllBytes($payload,$originalPayload)

        $mutations=@(
            @{Name='extra argument'; Apply={param($d) $e=$d.CreateElement('Arguments',$d.DocumentElement.NamespaceURI);$e.InnerText='-Connect';$null=$d.Task.Actions.Exec.AppendChild($e)}},
            @{Name='desktop action'; Apply={param($d) $d.Task.Actions.Exec.Command='C:\Users\Public\TradeChannel.exe'}},
            @{Name='command suffix'; Apply={param($d) $d.Task.Actions.Exec.Command+=' -Connect'}},
            @{Name='working directory'; Apply={param($d) $d.Task.Actions.Exec.WorkingDirectory='C:\Users\Public'}},
            @{Name='extra action'; Apply={param($d) $null=$d.Task.Actions.AppendChild($d.Task.Actions.Exec.CloneNode($true))}},
            @{Name='wrong owner marker'; Apply={param($d) $d.Task.RegistrationInfo.Description='not ours'}},
            @{Name='wrong author'; Apply={param($d) $d.Task.RegistrationInfo.Author='S-1-5-18'}},
            @{Name='SYSTEM principal'; Apply={param($d) $d.Task.Principals.Principal.UserId='S-1-5-18'}},
            @{Name='S4U logon'; Apply={param($d) $d.Task.Principals.Principal.LogonType='S4U'}},
            @{Name='limited token'; Apply={param($d) $d.Task.Principals.Principal.RunLevel='LeastPrivilege'}},
            @{Name='wrong logon user'; Apply={param($d) $d.Task.Triggers.LogonTrigger.UserId='S-1-5-21-101-102-103-1002'}},
            @{Name='extra trigger'; Apply={param($d) $null=$d.Task.Triggers.AppendChild($d.Task.Triggers.LogonTrigger.CloneNode($true))}},
            @{Name='missed start'; Apply={param($d) $d.Task.Settings.StartWhenAvailable='true'}}
        )
        foreach ($case in $mutations) {
            $changed=[xml]$savedXml; &$case.Apply $changed; $task.Xml=$changed.OuterXml
            Assert-Startup (-not (Get-TCStartup).Enabled) ($case.Name+': status rejected')
            Assert-Rejected {Set-TCStartup -Enabled $false} ($case.Name+': delete refused')
            Assert-Rejected {Set-TCStartup -Enabled $true -SourceDirectory $source} ($case.Name+': replacement refused')
            Assert-Startup ($script:Calls.Count -eq 1) ($case.Name+': no task mutation')
            $task.Xml=$savedXml
        }
        foreach ($field in @('Name','Path')) {
            $old=$task.$field; $task.$field+='-other'
            Assert-Rejected {Set-TCStartup -Enabled $false} ('task identity '+$field)
            $task.$field=$old
        }
        $task.Sddl='O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FA;;;BU)'
        Assert-Rejected {Set-TCStartup -Enabled $false} 'task writable by ordinary users rejected' '权限|身份'
        $task.Sddl=$savedSddl
        $ownerBytes=[IO.File]::ReadAllBytes($layout.ReceiptPath)
        [IO.File]::Delete($layout.ReceiptPath)
        Assert-Rejected {Set-TCStartup -Enabled $false} 'same name without receipt is not owned'
        [IO.File]::WriteAllBytes($layout.ReceiptPath,$ownerBytes); Set-Acl -LiteralPath $layout.ReceiptPath -AclObject (New-TCStartupAcl)
        $script:InjectOnRead=$script:ReadCount+2
        Assert-Rejected {Set-TCStartup -Enabled $false} 'recheck ownership immediately before delete'
        $script:InjectOnRead=0; $task.Xml=$savedXml
        Assert-Startup ($script:Calls.Count -eq 1) 'collision and race refusals leave task intact'

        $stagePayload=Join-Path $stage 'Worker.ps1'; $stageBytes=[IO.File]::ReadAllBytes($stagePayload)
        [IO.File]::WriteAllText($stagePayload,'tampered staged script')
        Assert-Startup (-not (Get-TCStartup).Enabled -and (Get-TCStartup).Detail -match '校验失败') 'staged tamper fails closed'
        Assert-Rejected {Set-TCStartup -Enabled $true -SourceDirectory $source} 'corrupt existing package is not silently overwritten'
        [IO.File]::WriteAllBytes($stagePayload,$stageBytes)
        $acl=New-TCStartupAcl
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')),'Write','Allow')))
        Set-Acl -LiteralPath $stagePayload -AclObject $acl
        Assert-Startup (-not (Get-TCStartup).Enabled) 'ordinary-user writable staged file rejected even with correct hash'
        Set-Acl -LiteralPath $stagePayload -AclObject (New-TCStartupAcl)
        $acl=New-TCStartupAcl -Directory
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')),'FullControl','ContainerInherit,ObjectInherit','InheritOnly','Allow')))
        Set-Acl -LiteralPath $layout.StageRoot -AclObject $acl
        Assert-Startup (-not (Get-TCStartup).Enabled) 'inheritable ordinary-user access cannot expose future copied files'
        Assert-Rejected {Set-TCStartup -Enabled $true -SourceDirectory $source} 'unsafe staging inheritance blocks writes'
        Set-Acl -LiteralPath $layout.StageRoot -AclObject (New-TCStartupAcl -Directory)
        $stageManifest=Join-Path $stage 'package.sha256'; $stageManifestBytes=[IO.File]::ReadAllBytes($stageManifest)
        [IO.File]::AppendAllText($stageManifest,"`r`n")
        Assert-Startup (-not (Get-TCStartup).Enabled) 'manifest digest pinned to task path and ownership marker'
        [IO.File]::WriteAllBytes($stageManifest,$stageManifestBytes)
        [IO.File]::Delete($stagePayload)
        Assert-Startup (-not (Get-TCStartup).Enabled) 'missing staged payload rejected'
        $disabled=Set-TCStartup -Enabled $false
        Assert-Startup (-not $disabled.Enabled -and $script:Calls.Count -eq 2 -and $script:Calls[1].Operation -eq 'Delete' -and (Test-Path -LiteralPath $stage) -and (Test-Path -LiteralPath $layout.ReceiptPath)) 'owned corrupt task can be disabled; staging and receipt retained'
        [IO.File]::WriteAllBytes($stagePayload,$stageBytes); Set-Acl -LiteralPath $stagePayload -AclObject (New-TCStartupAcl)
        $null=Set-TCStartup -Enabled $false
        Assert-Startup ($script:Calls.Count -eq 2) 'repeated disable is idempotent'
        $null=Set-TCStartup -Enabled $true -SourceDirectory $source
        Assert-Startup ((Get-TCStartup).Enabled -and $script:Calls[2].Flags -eq 18) 're-enable reuses verified staging and ownership'

        # Publish a new complete slot; old task/package survives failed registration.
        [IO.File]::WriteAllText($payload,'fixture v2',$utf8); Write-FixtureManifest $source
        $oldTaskXml=$script:FakeTasks[$layout.TaskName].Xml
        $script:RegisterFailure=$true
        Assert-Rejected {Set-TCStartup -Enabled $true -SourceDirectory $source} 'registration failure propagated'
        Assert-Startup ($script:FakeTasks[$layout.TaskName].Xml -ceq $oldTaskXml -and (Get-TCStartup).Enabled -and (Test-Path -LiteralPath $stage)) 'failed upgrade preserves previous verified package/task'
        $script:RegisterFailure=$false
        $null=Set-TCStartup -Enabled $true -SourceDirectory $source
        $newPlan=Get-TCStartupOwnedPlan (Read-TCStartupTask $layout) $layout
        Assert-Startup ($newPlan.PackageDirectory -cne $stage -and (Test-Path -LiteralPath $stage) -and $script:Calls[$script:Calls.Count-1].Flags -eq 20) 'new verified slot published by owned update only'
        $task=$script:FakeTasks[$layout.TaskName]; $doc=[xml]$task.Xml; $doc.Task.Settings.Enabled='false'; $task.Xml=$doc.OuterXml; $task.Enabled=$false
        Assert-Startup (-not (Get-TCStartup).Enabled -and (Get-TCStartup).Detail -match '已禁用') 'disabled owned task read accurately'
        $null=Set-TCStartup -Enabled $true -SourceDirectory $source
        Assert-Startup ((Get-TCStartup).Enabled) 'explicit enable restores disabled owned task'
        $script:IgnoreDelete=$true
        Assert-Rejected {Set-TCStartup -Enabled $false} 'delete readback detects task still present'
        $script:IgnoreDelete=$false; $null=Set-TCStartup -Enabled $false
        $script:BadReadback=$true
        Assert-Rejected {Set-TCStartup -Enabled $true -SourceDirectory $source} 'registration exact action readback mismatch rejected'
        Assert-Startup (-not (Get-TCStartup).Enabled) 'mismatched registration never reports success'
        $script:BadReadback=$false
        $script:FakeTasks.Clear()
        Assert-Startup (@($script:Calls | Where-Object {$_.Name -cne $layout.TaskName}).Count -eq 0) 'only current SID task touched'
        Assert-Startup (@($script:Calls | Where-Object {$_.Operation -notin @('Register','Delete')}).Count -eq 0) 'no task start or network/connection operation'
        [pscustomobject]@{Passed=$true;Checks=$script:Checks;PowerShell=$PSVersionTable.PSVersion.ToString();Scope='Isolated package fixtures + real restricted ACL/reparse checks + mocked Task Scheduler';RealTaskChanges=0;RealNetworkChanges=0}
    } $workspace
    $result
} finally {
    if ($module) { Remove-Module $module -ErrorAction SilentlyContinue }
    $resolved=[IO.Path]::GetFullPath($workspace).TrimEnd('\')
    $parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if (-not $resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^ProductTests-Startup-[a-f0-9]{32}$') { throw 'Cleanup guard rejected fixture path.' }
    if (Test-Path -LiteralPath $resolved) {
        # Remove junctions as links before traversing; never recursively follow one.
        function Remove-StartupFixtureTree {
            param([string]$Path)
            $full=[IO.Path]::GetFullPath($Path)
            if ($full -cne $resolved -and -not $full.StartsWith($resolved+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Cleanup escaped fixture.' }
            $item=Get-Item -LiteralPath $full -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                if ($item.PSIsContainer) { [IO.Directory]::Delete($full) } else { [IO.File]::Delete($full) }
            } elseif ($item.PSIsContainer) {
                foreach ($child in @(Get-ChildItem -LiteralPath $full -Force)) { Remove-StartupFixtureTree $child.FullName }
                [IO.Directory]::Delete($full)
            } else { [IO.File]::Delete($full) }
        }
        Remove-StartupFixtureTree $resolved
    }
}
