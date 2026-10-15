#requires -Version 5.1
<#
Isolated bridge/transport contract tests. No actual SSH, visible consoles,
ProgramData reads/writes, network changes, external dependencies or downloads.
Existing ServerSetup request/config helpers run against fixture keys; native
WireGuard calls are replaced with in-memory fixtures. If Python is installed,
the constant bootstrap is also exercised locally with inert source via stdin.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$product = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $product 'LinuxServerSetup.psm1'
$consolePath = Join-Path $product 'linux\Invoke-LinuxConsole.ps1'
$testBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$testRoot = Join-Path $testBase ('tc-linuxbridge-test-' + [guid]::NewGuid().ToString('N'))
$jobsRoot = Join-Path $testRoot 'linux-jobs'
$null = [IO.Directory]::CreateDirectory($testRoot)
$module = $null
$script:passed = 0; $script:failed = 0

function Assert-True {
    param($Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Assert-Throws {
    param([scriptblock]$Body, [string]$Code)
    $caught = $false
    try { $null = & $Body } catch {
        $caught = $true
        if ($_.Exception.Message -notmatch ('\[TC:' + [regex]::Escape($Code) + '\]')) { throw ('Expected ' + $Code + '; received: ' + $_.Exception.Message) }
    }
    if (-not $caught) { throw ('Expected rejection: ' + $Code) }
}
function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    try { & $Body; $script:passed++; Write-Output ('PASS ' + $Name) }
    catch { $script:failed++; Write-Output ('FAIL ' + $Name + ': ' + $_.Exception.Message + ' (line ' + $_.InvocationInfo.ScriptLineNumber + ')') }
}
function Read-FixtureJson {
    param([string]$Path)
    [IO.File]::ReadAllText($Path) | ConvertFrom-Json
}
function Set-FixtureJson {
    param([string]$Path, $Value)
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($testRoot + '\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Fixture write escaped test root.' }
    [IO.File]::WriteAllText($full,($Value | ConvertTo-Json -Depth 24 -Compress),(New-Object Text.UTF8Encoding($true)))
}
function Start-FixtureJob {
    param([string]$Operation = 'Inspect')
    $request = @{ Action = 'LinuxStart'; Operation = $Operation; Connection = @{ Host = '8.8.8.8'; Port = 22; User = 'root' } }
    if ($Operation -eq 'Plan') { $request.Name = '隔离 Linux 节点'; $request.PublicEndpoint = '8.8.4.4:51878'; $request.TunnelSubnet = '10.78.0.0/24' }
    Invoke-TCLinuxRequest -Request $request -Root $testRoot
}
function Run-FixtureJob {
    param([string]$Id)
    & $module { param($Id,$Root) Invoke-TCLinuxConsoleJob -Id $Id -Root $Root } $Id $jobsRoot
}
function New-FixturePlan {
    $job = Start-FixtureJob Plan
    Run-FixtureJob $job.JobId
}
function Reset-FixtureTransport {
    & $module { $script:OutputOverride = $null; $script:ExitOverride = 0; $script:ConsoleAlive = $true; $script:StartFails = $false; $script:RaceFailure = $false }
}

try {
    foreach ($path in @($modulePath,$consolePath,$PSCommandPath)) {
        $bytes = [IO.File]::ReadAllBytes($path)
        Assert-True ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) 'All three owned PowerShell files must use UTF-8 BOM.'
        $tokens = $null; $errors = $null
        $null = [Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
        Assert-True ($errors.Count -eq 0) ('PowerShell parse failure: ' + [IO.Path]::GetFileName($path))
    }
    $module = Import-Module $modulePath -Force -PassThru -DisableNameChecking
    Assert-True (-not (Test-Path -LiteralPath $jobsRoot)) 'Import created task state.'
    & $module {
        param($FixtureRoot)
        $script:FixtureRoot = $FixtureRoot
        $script:ConsoleStarts = 0; $script:NativeCalls = 0; $script:ConsoleAlive = $true
        $script:StartFails = $false; $script:OutputOverride = $null; $script:ExitOverride = 0; $script:RaceFailure = $false
        $script:FixturePlans = @{}; $script:LastPayload = ''; $script:LastTransport = $null
        $script:OriginalResolve = ${function:Resolve-TCLinuxRoot}
        $script:OriginalProcessCheck = ${function:Test-TCLinuxConsoleProcess}
        function script:Resolve-TCLinuxRoot {
            param([string]$Root)
            $resolved = & $script:OriginalResolve $Root
            if (-not $resolved.StartsWith($script:FixtureRoot + '\',[StringComparison]::OrdinalIgnoreCase)) { throw 'TEST GUARD: live state access prohibited.' }
            return $resolved
        }
        function script:Start-TCLinuxConsole {
            param($Id,$Root)
            if ($script:StartFails) { throw 'LOCAL-SECRET-CANARY must not reach UI' }
            $script:ConsoleStarts++
            [pscustomobject]@{ ProcessId = 12345; StartTimeUtcTicks = '123456789' }
        }
        function script:Test-TCLinuxConsoleProcess { param($Receipt) return $script:ConsoleAlive }
        function script:Get-TCLinuxBackend {
            $source = "# inert transport fixture`n" + ('# padding for a backend over 32 KiB' + "`n") * 1800
            [pscustomobject]@{ Source = $source; SourceSHA256 = (Get-TCLinuxHash $source) }
        }
        function script:New-FixtureResponse {
            param($Request, $InputData)
            [pscustomobject]@{ SchemaVersion = 1; Kind = 'TradeChannel.ClientResponse'; Status = 'Authorized'; RequestId = $Request.RequestId;
                DeviceId = $Request.DeviceId; NodeId = '11111111-2222-4333-8444-555555555555'; NodeName = $InputData.Name;
                ClientPublicKey = $Request.ClientPublicKey; ClientAddress = '10.78.0.2/32'; ServerPublicKey = [Convert]::ToBase64String([byte[]](101..132));
                PublicEndpoint = $InputData.PublicEndpoint; TunnelSubnet = $InputData.TunnelSubnet; ServerAddress = '10.78.0.1/24';
                AllowedIPs = @('0.0.0.0/0'); PersistentKeepalive = 25; AddressFamilies = @('IPv4'); ConfigRevision = 1;
                Validation = @{ LocalAuthorization = 'Verified'; CloudFirewall = 'NotVerified'; Handshake = 'NotTested'; ExternalConnectivity = 'NotTested' } }
        }
        function script:Invoke-TCLinuxNativeTransport {
            param($Plan,$Payload,$Deadline)
            $script:NativeCalls++; $script:LastPayload = $Payload; $script:LastTransport = $Plan
            $p = $Payload | ConvertFrom-Json
            if ($null -ne $script:OutputOverride) { return [pscustomobject]@{ ExitCode = $script:ExitOverride; Output = $script:OutputOverride } }
            $data = switch ($p.Action) {
                plan {
                    $planId = [guid]::NewGuid().ToString(); $script:FixturePlans[$planId] = $p.Input
                    [pscustomobject]@{ PlanId = $planId; Supported = $true; OS = @{ ID = 'ubuntu'; VERSION_ID = '24.04' }; Steps = @('fixture preview');
                        Name = $p.Input.Name; PublicEndpoint = $p.Input.PublicEndpoint; ServerAddress = '10.78.0.1/24'; ClientAddress = '10.78.0.2/32';
                        Warnings = @('Cloud firewall remains unverified'); RequiresCloudFirewall = $true; PlanExpiresAt = [DateTime]::UtcNow.AddMinutes(30).ToString('o') }
                }
                apply {
                    $original = $script:FixturePlans[$p.Input.PlanId]
                    [pscustomobject]@{ Status = 'Applied'; ClientResponse = (New-FixtureResponse $original.ClientRequest $original) }
                }
                finalize {
                    $original = $script:FixturePlans[$p.Input.PlanId]
                    [pscustomobject]@{ Status = 'Applied'; ClientResponse = (New-FixtureResponse $original.ClientRequest $original) }
                }
                authorize {
                    [pscustomobject]@{ Status = 'Authorized'; ClientResponse = (New-FixtureResponse $p.Input.ClientRequest ([pscustomobject]@{ Name = 'Existing Linux'; PublicEndpoint = '8.8.4.4:51878'; TunnelSubnet = '10.78.0.0/24' })) }
                }
                default { [pscustomobject]@{ Supported = $true; Status = 'Inspected'; OS = @{ ID = 'ubuntu'; VERSION_ID = '24.04' } } }
            }
            if ($script:RaceFailure) {
                $directories = @(Get-ChildItem -LiteralPath (Join-Path $script:FixtureRoot 'linux-jobs') -Directory | Sort-Object CreationTimeUtc -Descending)
                $root = Join-Path $script:FixtureRoot 'linux-jobs'
                $job = Get-TCLinuxJobRecord $directories[0].Name $root
                Set-TCLinuxFailure $job $root ConsoleClosed 'fixture first terminal result' $true
            }
            [pscustomobject]@{ ExitCode = $script:ExitOverride; Output = ([ordered]@{ Ok = $true; Action = $p.Action; Data = $data; Message = 'fixture success' } | ConvertTo-Json -Depth 18 -Compress) }
        }
        # Fail closed if a future edit accidentally adds a non-transport native
        # or network operation to the bridge instead of the owned remote backend.
        function script:Start-Process { throw 'TEST GUARD: real process launch prohibited.' }
        function script:Invoke-Expression { throw 'TEST GUARD: shell evaluation prohibited.' }
        function script:Invoke-Command { throw 'TEST GUARD: remote execution prohibited.' }
        function script:Write-Host { param($Object) }
        $clientModule = Get-TCLinuxClientModule
        & $clientModule {
            param($FixtureRoot)
            $script:FixtureRoot = $FixtureRoot; $script:FixtureKeyCalls = 0
            function script:Resolve-TCWgPath { param($WgPath) return (Join-Path $script:FixtureRoot 'inert-wg.exe') }
            function script:Invoke-TCNative {
                param($Path,$Arguments,$InputText)
                if ($Path -ne (Join-Path $script:FixtureRoot 'inert-wg.exe') -or $Arguments.Count -ne 1) { throw 'TEST GUARD: unexpected native call.' }
                $script:FixtureKeyCalls++
                if ($Arguments[0] -eq 'genkey') {
                    $bytes = New-Object byte[] 32; $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
                    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
                    return [Convert]::ToBase64String($bytes)
                }
                if ($Arguments[0] -eq 'pubkey') {
                    $sha = [Security.Cryptography.SHA256]::Create()
                    try { return [Convert]::ToBase64String($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($InputText))) } finally { $sha.Dispose() }
                }
                throw 'TEST GUARD: only fixture key generation is permitted.'
            }
        } $FixtureRoot
    } $testRoot

    Test-Case 'PS5.1 syntax, BOM, exports and import without state' {
        $exports = @($module.ExportedFunctions.Keys | Sort-Object)
        Assert-True (($exports -join ',') -eq 'Complete-TCLinuxJob,Get-TCLinuxJob,Invoke-TCLinuxRequest,New-TCLinuxJob,Reset-TCLinuxHostKey') 'Unexpected export surface.'
        $recent = Invoke-TCLinuxRequest -Request @{ Action = 'LinuxRecent' } -Root $testRoot
        Assert-True ($recent.Items.Count -eq 0 -and -not (Test-Path -LiteralPath $jobsRoot)) 'Recent created state.'
    }
    Test-Case 'strict ASCII public host, argv and credential rejection' {
        foreach ($address in @('127.0.0.1','10.0.0.1','192.168.1.1','100.64.0.1','169.254.1.2','203.0.113.1','224.0.0.1','0.0.0.0','8.8.8.8;id','-oProxyCommand=evil','8.8.8.8`nwhoami','８.8.8.8','8.8.8.01','256.8.8.8','example.com')) {
            Assert-Throws { New-TCLinuxJob -Action Inspect -Connection @{ Host = $address; User = 'root' } -Root $jobsRoot } InvalidHost
        }
        foreach ($userName in @('root;id','-root','root@evil',"root`nwhoami")) {
            Assert-Throws { New-TCLinuxJob -Action Inspect -Connection @{ Host = '8.8.8.8'; User = $userName } -Root $jobsRoot } InvalidUser
        }
        foreach ($port in @('0','65536','22 -o anything')) {
            Assert-Throws { New-TCLinuxJob -Action Inspect -Connection @{ Host = '8.8.8.8'; Port = $port } -Root $jobsRoot } InvalidPort
        }
        Assert-Throws { New-TCLinuxJob -Action Inspect -Connection @{ Host = '8.8.8.8'; Password = 'not-stored' } -Root $jobsRoot } InvalidRequest
        Assert-Throws { Invoke-TCLinuxRequest -Request @{ Action = 'LinuxStart'; Operation = 'Inspect'; Password = 'not-stored' } -Root $testRoot } InvalidRequest
        Assert-Throws { New-TCLinuxJob -Action Inspect -Connection @{ Host = '8.8.8.8'; User = 'ubuntu' } -Root $jobsRoot } SudoRequiresKey
        Assert-True ((& $module { $script:ConsoleStarts }) -eq 0) 'Validation launched a console.'
    }
    Test-Case 'start returns promptly; poll and context never launch SSH' {
        $script:inspect = Start-FixtureJob
        Assert-True ($inspect.Status -eq 'Running' -and $inspect.Operation -eq 'Inspect') 'Worker start contract changed.'
        $poll = Invoke-TCLinuxRequest -Request @{ Action = 'LinuxPoll'; Id = $inspect.JobId } -Root $testRoot
        Assert-True ($poll.Connection.Host -eq '8.8.8.8' -and $poll.Connection.User -eq 'root' -and $poll.CreatedAt) 'Resume context missing.'
        Assert-True ((& $module { $script:NativeCalls }) -eq 0) 'Start/poll invoked SSH.'
        $finished = Run-FixtureJob $inspect.JobId
        Assert-True ($finished.Status -eq 'Completed' -and $finished.Data.OS.VERSION_ID -eq '24.04') 'Data was wrapped or lost.'
        $calls = & $module { $script:NativeCalls }
        $null = Run-FixtureJob $inspect.JobId
        Assert-True ((& $module { $script:NativeCalls }) -eq $calls) 'Completed console replay invoked SSH.'
    }
    Test-Case 'UTC parser preserves string, DateTime and DateTimeOffset instants across cultures' {
        $utc = [DateTime]::SpecifyKind([DateTime]::new(2026,10,4,12,54,58),[DateTimeKind]::Utc)
        $offset = [DateTimeOffset]::new(2026,10,4,20,54,58,[TimeSpan]::FromHours(8))
        $values = @('2026-10-04T12:54:58Z','2026-10-04T20:54:58+08:00',$utc,$utc.ToLocalTime(),$offset,
            [DateTime]::SpecifyKind($utc,[DateTimeKind]::Unspecified))
        $oldCulture = [Threading.Thread]::CurrentThread.CurrentCulture
        try {
            foreach ($cultureName in @('en-US','zh-CN','fr-FR')) {
                [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo($cultureName)
                foreach ($value in $values) {
                    $actual = & $module { param($Value) ConvertTo-TCLinuxUtcTime $Value } $value
                    $iso = & $module { param($Value) ConvertTo-TCLinuxUtcIso $Value } $value
                    Assert-True ($actual -is [DateTimeOffset] -and $actual.UtcDateTime.Ticks -eq $utc.Ticks -and $actual.Offset -eq [TimeSpan]::Zero) 'Parser changed the instant or offset.'
                    Assert-True ($iso -is [string] -and $iso -ceq '2026-10-04T12:54:58.0000000Z') 'DTO UTC ISO output changed by culture.'
                }
            }
        } finally { [Threading.Thread]::CurrentThread.CurrentCulture = $oldCulture }
        Assert-Throws { & $module { ConvertTo-TCLinuxUtcTime '2026-10-04T12:54:58' } } InvalidTimestamp
        Assert-Throws { & $module { ConvertTo-TCLinuxUtcTime '2026-99-04T12:54:58Z' } } InvalidTimestamp
    }
    Test-Case 'fresh JSON job polling retains UTC deadline and never writes a false timeout' {
        $j = Start-FixtureJob
        $directory = Join-Path $jobsRoot $j.JobId
        $record = Read-FixtureJson (Join-Path $directory 'job.json')
        # PS7 supplies DateTime here; PS5.1 supplies string. Exercise each real
        # engine's JSON behavior against the same persisted UTC wire contract.
        $deadline = & $module { param($Value) ConvertTo-TCLinuxUtcTime $Value } $record.DeadlineUtc
        Assert-True (($deadline - [DateTimeOffset]::UtcNow).TotalMinutes -gt 28) 'Fresh job deadline shifted with local timezone.'
        $before = & $module { $script:NativeCalls }
        $poll = Invoke-TCLinuxRequest -Request @{ Action = 'LinuxPoll'; Id = $j.JobId } -Root $testRoot
        Assert-True ($poll.Status -eq 'Running' -and -not (Test-Path -LiteralPath (Join-Path $directory 'result.json'))) 'Fresh job was prematurely made terminal.'
        Assert-True ($poll.CreatedAt -is [string] -and $poll.CreatedAt -cmatch '^\d{4}-\d{2}-\d{2}T.+Z$') 'Poll CreatedAt is not UTC ISO text.'
        $result = Run-FixtureJob $j.JobId
        Assert-True ($result.Status -eq 'Completed' -and $result.FinishedAtUtc -is [string] -and $result.FinishedAtUtc.EndsWith('Z')) 'FinishedAt DTO lost UTC ISO form.'
        Assert-True ((& $module { $script:NativeCalls }) -eq ($before + 1)) 'Polling performed a remote call.'
    }
    Test-Case 'SSH argument plan pins system SSH and first-host checks' {
        $plan = & $module { param($Path) Get-TCLinuxTransportPlan @{ Host = '8.8.8.8'; User = 'root'; Port = 2222 } $Path } (Join-Path $jobsRoot 'known_hosts')
        Assert-True ($plan.FileName -match '\\System32\\OpenSSH\\ssh.exe$') 'SSH path was not pinned.'
        foreach ($option in @('StrictHostKeyChecking=ask','GlobalKnownHostsFile=none','UpdateHostKeys=no','IdentityAgent=none','ClearAllForwardings=yes','ProxyCommand=none','LogLevel=INFO')) {
            Assert-True ($plan.Arguments -contains $option) ('Missing SSH protection ' + $option)
        }
        Assert-True ($plan.Arguments -contains '2222' -and $plan.Arguments -contains '-T' -and $plan.Arguments -contains 'NUL') 'SSH configuration or tty isolation missing.'
        Assert-True ($plan.RemoteCommand.Length -lt 2048 -and $plan.CommandLine -notmatch 'padding for a backend') 'Source was inlined into argv.'
        Assert-True ($plan.RemoteCommand -match 'sys.stdin.buffer.read\(\).decode' -and $plan.RemoteCommand -match 'sys.stdin=io.StringIO' -and $plan.RemoteCommand -match 'sha256') 'Dual-stdin UTF-8 bootstrap contract missing.'
        & $module { param($Path) Assert-TCLinuxPrivatePath $Path } (Join-Path $jobsRoot 'known_hosts')
    }
    Test-Case 'identity path is passed as one argument; non-root uses sudo -n' {
        $identity = Join-Path $testRoot 'identity with spaces & quote.key'
        [IO.File]::WriteAllText($identity,'INERT-IDENTITY-NOT-FOR-PAYLOAD')
        $plan = & $module { param($Identity,$Known) Get-TCLinuxTransportPlan @{ Host = '8.8.8.8'; User = 'ubuntu'; IdentityFile = $Identity } $Known } $identity (Join-Path $jobsRoot 'known_hosts')
        Assert-True ($plan.Arguments -contains $identity -and $plan.RemoteCommand.StartsWith('sudo -n -- python3')) 'Identity/sudo command was altered.'
        Assert-True ($plan.Arguments -contains 'PreferredAuthentications=publickey') 'Non-root silently falls back to password.'
        Assert-True ($plan.CommandLine -notmatch 'INERT-IDENTITY') 'Private identity contents were read into argv.'
    }
    Test-Case 'plan creates a unique local request and sends only public fields' {
        $script:preview = New-FixturePlan
        Assert-True ($preview.Status -eq 'Completed' -and $preview.Data.Supported -and $preview.Data.RequiresCloudFirewall) 'Plan failed.'
        Assert-True ($preview.Data.PlanExpiresAt -is [string] -and $preview.Data.PlanExpiresAt.EndsWith('Z')) 'Plan expiry DTO must remain UTC ISO text.'
        $record = Read-FixtureJson (Join-Path (Join-Path $jobsRoot $preview.JobId) 'job.json')
        $payload = Read-FixtureJson (Join-Path (Join-Path $jobsRoot $preview.JobId) 'payload.json')
        $requestDirectory = Join-Path (Join-Path $jobsRoot $preview.JobId) 'client'
        $private = [IO.File]::ReadAllText((Join-Path $requestDirectory 'client.key')).Trim()
        Assert-True ($payload.Source.Length -gt 32768 -and $payload.Input.ClientRequest.RequestId -eq $record.RequestId) 'Large source or request identity lost.'
        Assert-True (-not (($payload | ConvertTo-Json -Depth 20).Contains($private))) 'Private key escaped in payload.'
        Assert-True (-not (($record | ConvertTo-Json -Depth 10).Contains($private))) 'Private key escaped in job JSON.'
        $second = New-FixturePlan
        Assert-True ($second.JobId -ne $preview.JobId) 'Plan job reused.'
        $secondRecord = Read-FixtureJson (Join-Path (Join-Path $jobsRoot $second.JobId) 'job.json')
        Assert-True ($record.RequestId -ne $secondRecord.RequestId) 'Plan requests are not independent.'
    }
    Test-Case 'apply rejects arbitrary plan, host, parent and caller content changes' {
        $before = & $module { $script:ConsoleStarts }
        Assert-Throws { New-TCLinuxJob -Action Apply -PlanId ([guid]::NewGuid().ToString()) -Root $jobsRoot } PlanRequired
        Assert-Throws { New-TCLinuxJob -Action Apply -JobId $inspect.JobId -Root $jobsRoot } PlanRequired
        Assert-Throws { New-TCLinuxJob -Action Apply -JobId $preview.JobId -PlanId ([guid]::NewGuid().ToString()) -Root $jobsRoot } PlanMismatch
        Assert-Throws { New-TCLinuxJob -Action Apply -JobId $preview.JobId -Connection @{ Host = '1.1.1.1' } -Root $jobsRoot } PlanMismatch
        Assert-Throws { Invoke-TCLinuxRequest -Request @{ Action = 'LinuxStart'; Operation = 'Apply'; ParentJobId = $preview.JobId; Name = 'Changed' } -Root $testRoot } PlanMismatch
        Assert-True ((& $module { $script:ConsoleStarts }) -eq $before) 'Rejected Apply launched a console.'
    }
    Test-Case 'apply reuses stored host/request and is single submission per plan' {
        $script:apply = Invoke-TCLinuxRequest -Request @{ Action = 'LinuxStart'; Operation = 'Apply'; ParentJobId = $preview.JobId; PlanId = $preview.Data.PlanId } -Root $testRoot
        Assert-True ($apply.Status -eq 'Running' -and $apply.Connection.Host -eq '8.8.8.8' -and $apply.PublicEndpoint -eq '8.8.4.4:51878') 'Apply resume context incorrect.'
        $script:applied = Run-FixtureJob $apply.JobId
        Assert-True ($applied.Status -eq 'Completed') ('Apply failed: ' + $applied.Message)
        $payload = Read-FixtureJson (Join-Path (Join-Path $jobsRoot $apply.JobId) 'payload.json')
        Assert-True (@($payload.Input.PSObject.Properties).Count -eq 1 -and $payload.Input.PlanId -eq $preview.Data.PlanId) 'Apply sent mutable request data.'
        $before = & $module { $script:ConsoleStarts }
        $again = New-TCLinuxJob -Action Apply -JobId $preview.JobId -Root $jobsRoot
        Assert-True ($again.JobId -eq $apply.JobId -and (& $module { $script:ConsoleStarts }) -eq $before) 'Repeated Apply retried remote mutation.'
    }
    Test-Case 'complete merges locally and remains idempotent, without import or activation' {
        $before = & $module { $script:NativeCalls }
        $script:completed = Invoke-TCLinuxRequest -Request @{ Action = 'LinuxComplete'; Id = $apply.JobId } -Root $testRoot
        Assert-True (@($completed.PSObject.Properties).Count -eq 4 -and $completed.NodeName -eq '隔离 Linux 节点') 'Completion contract changed.'
        $config = [IO.File]::ReadAllText($completed.ConfigPath)
        $private = [IO.File]::ReadAllText((Join-Path $completed.RequestDirectory 'client.key')).Trim()
        Assert-True ($config.Contains('PrivateKey = ' + $private) -and $config.Contains('Endpoint = 8.8.4.4:51878')) 'Local merge contents incorrect.'
        Assert-True (-not (($completed | ConvertTo-Json).Contains($private))) 'Completion metadata leaks secret.'
        Assert-True ([IO.File]::ReadAllBytes($completed.ConfigPath)[0] -eq 91) 'WireGuard config incorrectly includes BOM.'
        $again = Complete-TCLinuxJob -Id $apply.JobId -Root $jobsRoot
        Assert-True ($again.ConfigPath -eq $completed.ConfigPath -and (& $module { $script:NativeCalls }) -eq $before) 'Complete was not local/idempotent.'
        & $module { param($Path) Assert-TCLinuxPrivatePath $Path } $completed.ConfigPath
        Assert-Throws { Complete-TCLinuxJob -Id $preview.JobId -Root $jobsRoot } NotCompletable
    }
    Test-Case 'explicit finalize binds the original plan and identity without replaying Apply' {
        Assert-Throws { New-TCLinuxJob -Action Finalize -JobId $inspect.JobId -Root $jobsRoot } PlanRequired
        Assert-Throws { New-TCLinuxJob -Action Finalize -JobId $preview.JobId -Connection @{Host='1.1.1.1'} -Root $jobsRoot } PlanMismatch
        $finish=Invoke-TCLinuxRequest -Request @{Action='LinuxStart';Operation='Finalize';ParentJobId=$preview.JobId;PlanId=$preview.Data.PlanId} -Root $testRoot
        Assert-True ($finish.JobId -ne $apply.JobId -and $finish.Connection.Host -eq $preview.Connection.Host) 'Finalize reused Apply result or replaced the reviewed host.'
        $finished=Run-FixtureJob $finish.JobId
        Assert-True ($finished.Status -eq 'Completed') ('Finalize failed: '+$finished.Message)
        $data=Invoke-TCLinuxRequest -Request @{Action='LinuxComplete';Id=$finish.JobId} -Root $testRoot
        Assert-True ($data.RequestDirectory -eq $completed.RequestDirectory) 'Finalize generated a new client identity.'
        $again=New-TCLinuxJob -Action Finalize -JobId $preview.JobId -Root $jobsRoot
        Assert-True ($again.JobId -eq $finish.JobId) 'Finalize duplicate click replayed a remote operation.'
    }
    Test-Case 'client key reads are bounded and private state mismatches fail closed' {
        $keyPath = Join-Path $completed.RequestDirectory 'client.key'
        $old = [IO.File]::ReadAllText($keyPath)
        try {
            [IO.File]::WriteAllText($keyPath,('X' * 257))
            Assert-Throws { Complete-TCLinuxJob -Id $apply.JobId -Root $jobsRoot } InvalidState
            [IO.File]::WriteAllText($keyPath,([Convert]::ToBase64String([byte[]](41..72))))
            Assert-Throws { Complete-TCLinuxJob -Id $apply.JobId -Root $jobsRoot } RequestMismatch
        } finally { [IO.File]::WriteAllText($keyPath,$old,(New-Object Text.UTF8Encoding($false))) }
    }
    Test-Case 'original request and public reply are bound to preview identity' {
        $requestPath = Join-Path $completed.RequestDirectory 'public.request.json'
        $request = Read-FixtureJson $requestPath; $oldId = $request.RequestId
        try {
            $request.RequestId = [guid]::NewGuid().ToString(); Set-FixtureJson $requestPath $request
            Assert-Throws { Complete-TCLinuxJob -Id $apply.JobId -Root $jobsRoot } RequestMismatch
        } finally { $request.RequestId = $oldId; Set-FixtureJson $requestPath $request }
        $response = Read-FixtureJson $completed.ResponsePath; $endpoint = $response.PublicEndpoint
        try {
            $response.PublicEndpoint = '1.1.1.1:51878'; Set-FixtureJson $completed.ResponsePath $response
            Assert-Throws { Complete-TCLinuxJob -Id $apply.JobId -Root $jobsRoot } ResponseMismatch
        } finally { $response.PublicEndpoint = $endpoint; Set-FixtureJson $completed.ResponsePath $response }
    }
    Test-Case 'expired plan cannot create an Apply console' {
        $p = New-FixturePlan
        $path = Join-Path (Join-Path $jobsRoot $p.JobId) 'result.json'
        $result = Read-FixtureJson $path; $result.Data.PlanExpiresAt = [DateTime]::UtcNow.AddMinutes(-1).ToString('o'); Set-FixtureJson $path $result
        Assert-Throws { New-TCLinuxJob -Action Apply -JobId $p.JobId -Root $jobsRoot } PlanExpired
    }
    Test-Case 'expired plan can still request verification-only Finalize' {
        $p = New-FixturePlan
        $path = Join-Path (Join-Path $jobsRoot $p.JobId) 'result.json'
        $result = Read-FixtureJson $path; $result.Data.PlanExpiresAt = [DateTime]::UtcNow.AddMinutes(-1).ToString('o'); Set-FixtureJson $path $result
        $finish=New-TCLinuxJob -Action Finalize -JobId $p.JobId -Root $jobsRoot
        $payload=Read-FixtureJson (Join-Path (Join-Path $jobsRoot $finish.JobId) 'payload.json')
        Assert-True ($payload.Action -ceq 'finalize' -and $payload.Input.PlanId -eq $p.Data.PlanId) 'Expired plan did not retain explicit verification-only action.'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path (Join-Path $jobsRoot $p.JobId) 'apply-job.json'))) 'Finalize re-applied an expired plan.'
    }
    Test-Case 'console close, PID reuse and deadline lead to terminal states' {
        $j = Start-FixtureJob
        & $module { $script:ConsoleAlive = $false }
        $result = Get-TCLinuxJob -Id $j.JobId -Root $jobsRoot
        Assert-True ($result.Status -eq 'Failed' -and $result.ErrorCode -eq 'ConsoleClosed' -and -not $result.OutcomeUnknown) 'Closed inspection stayed pending.'
        Reset-FixtureTransport
        $p = New-FixturePlan; $a = New-TCLinuxJob -Action Apply -JobId $p.JobId -Root $jobsRoot
        & $module { $script:ConsoleAlive = $false }
        $result = Get-TCLinuxJob -Id $a.JobId -Root $jobsRoot
        Assert-True ($result.Status -eq 'Failed' -and $result.OutcomeUnknown) 'Interrupted mutation was reported as absent.'
        Reset-FixtureTransport
        $j = Start-FixtureJob
        $path = Join-Path (Join-Path $jobsRoot $j.JobId) 'job.json'; $record = Read-FixtureJson $path
        $record.DeadlineUtc = [DateTime]::UtcNow.AddSeconds(-1).ToString('o'); Set-FixtureJson $path $record
        $result = Get-TCLinuxJob -Id $j.JobId -Root $jobsRoot
        Assert-True ($result.ErrorCode -eq 'JobTimeout') 'Deadline did not terminate job.'
        $pidReused = & $module { param($ProcessId) & $script:OriginalProcessCheck ([pscustomobject]@{ ProcessId = $ProcessId; StartTimeUtcTicks = '1' }) } $PID
        Assert-True (-not $pidReused) 'PID was checked without creation time.'
    }
    Test-Case 'failed console launch records a sanitized terminal result' {
        & $module { $script:StartFails = $true }
        try {
            $result = Start-FixtureJob
            Assert-True ($result.Status -eq 'Failed' -and $result.ErrorCode -eq 'ConsoleStartFailed' -and $result.Message -notmatch 'SECRET-CANARY') 'Launch error leaked or stayed pending.'
        } finally { Reset-FixtureTransport }
    }
    Test-Case 'creation and execution locks reject concurrent submissions' {
        $lock = [IO.File]::Open((Join-Path $jobsRoot '.bridge.lock'),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        try { Assert-Throws { Start-FixtureJob } Busy } finally { $lock.Dispose() }
        $j = Start-FixtureJob
        $lock = [IO.File]::Open((Join-Path (Join-Path $jobsRoot $j.JobId) '.execution.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        try { Assert-Throws { Run-FixtureJob $j.JobId } AlreadyRunning } finally { $lock.Dispose() }
    }
    Test-Case 'SSH transport errors and structured backend refusals remain distinct' {
        & $module { $script:OutputOverride = 'RAW-PRIVATE-ERROR-CANARY'; $script:ExitOverride = 255 }
        try {
            $j = Start-FixtureJob; $result = Run-FixtureJob $j.JobId
            Assert-True ($result.ErrorCode -eq 'SshFailed' -and ($result | ConvertTo-Json -Depth 10) -notmatch 'RAW-PRIVATE') 'SSH failure exposed raw output.'
            Assert-True ($result.Stage -eq 'Transport' -and $result.ExitCode -eq 255) 'SSH failure phase/exit code missing.'
            & $module { $script:ExitOverride = 1; $script:OutputOverride = '{"Ok":false,"Action":"inspect","Data":{"Code":"UnsupportedOS"},"Message":"Only Ubuntu 24.04 is supported. password=CANARY"}' }
            $j = Start-FixtureJob; $result = Run-FixtureJob $j.JobId
            Assert-True ($result.ErrorCode -eq 'RemoteRejected' -and $result.Data.Code -eq 'UnsupportedOS' -and $result.Message -notmatch 'CANARY') 'Remote error code/secret handling incorrect.'
            Assert-True ($result.Stage -eq 'Backend' -and $result.ExitCode -eq 1) 'Backend refusal phase/exit code missing.'
        } finally { Reset-FixtureTransport }
    }
    Test-Case 'bootstrap failures expose safe phase and exit code without raw output' {
        foreach ($exit in @(76,77,127)) {
            & $module { param($Exit) $script:OutputOverride = 'RAW-BOOTSTRAP-CANARY'; $script:ExitOverride = $Exit } $exit
            try {
                $j = Start-FixtureJob; $result = Run-FixtureJob $j.JobId
                Assert-True ($result.Status -eq 'Failed' -and $result.Stage -eq 'Bootstrap' -and $result.ExitCode -eq $exit) 'Bootstrap phase/exit code missing.'
                Assert-True (($result | ConvertTo-Json -Depth 10) -notmatch 'RAW-BOOTSTRAP-CANARY') 'Bootstrap output leaked into result.'
            } finally { Reset-FixtureTransport }
        }
    }
    foreach ($fixture in @(
        @{ Name = 'invalid JSON'; Output = 'RAW-ERROR-CANARY'; Code = 'InvalidEnvelope' },
        @{ Name = 'action mismatch'; Output = '{"Ok":true,"Action":"apply","Data":{}}'; Code = 'InvalidEnvelope' },
        @{ Name = 'boolean type'; Output = '{"Ok":"true","Action":"inspect","Data":{}}'; Code = 'InvalidEnvelope' },
        @{ Name = 'secret property'; Output = '{"Ok":true,"Action":"inspect","Data":{"PrivateKey":"RAW-SECRET-CANARY"}}'; Code = 'UnsafeResponse' },
        @{ Name = 'secret text'; Output = '{"Ok":true,"Action":"inspect","Data":{"Notes":"PrivateKey=RAW-SECRET-CANARY"}}'; Code = 'UnsafeResponse' },
        @{ Name = 'bounded output'; Output = ('X' * (256KB + 1)); Code = 'InvalidEnvelope' }
    )) {
        Test-Case ('envelope rejection: ' + $fixture.Name) {
            & $module { param($Output) $script:OutputOverride = $Output } $fixture.Output
            try {
                $j = Start-FixtureJob; $result = Run-FixtureJob $j.JobId
                Assert-True ($result.Status -eq 'Failed' -and $result.ErrorCode -eq $fixture.Code) ('Wrong rejection for ' + $fixture.Name)
                Assert-True (($result | ConvertTo-Json -Depth 10) -notmatch 'RAW-(ERROR|SECRET)-CANARY') 'Unsafe output persisted in result.'
            } finally { Reset-FixtureTransport }
        }
    }
    Test-Case 'source digest tampering is rejected before transport' {
        $j = Start-FixtureJob
        $path = Join-Path (Join-Path $jobsRoot $j.JobId) 'payload.json'; $p = Read-FixtureJson $path
        $p.Source += '# modified'; Set-FixtureJson $path $p
        $before = & $module { $script:NativeCalls }
        $result = Run-FixtureJob $j.JobId
        Assert-True ($result.ErrorCode -eq 'PayloadMismatch' -and (& $module { $script:NativeCalls }) -eq $before) 'Tampered source reached SSH.'
    }
    Test-Case 'terminal publication is atomic and first result wins' {
        $j = Start-FixtureJob
        & $module { $script:RaceFailure = $true }
        try {
            $result = Run-FixtureJob $j.JobId
            Assert-True ($result.Status -eq 'Failed' -and $result.ErrorCode -eq 'ConsoleClosed') 'Late completion overwrote terminal close.'
            Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $jobsRoot $j.JobId) -Filter '.write-*' -Force).Count -eq 0) 'Atomic write leaked temporary files.'
        } finally { Reset-FixtureTransport }
    }
    Test-Case 'authorize creates its own local request and complete remains local' {
        $j = Start-FixtureJob Authorize; $result = Run-FixtureJob $j.JobId
        Assert-True ($result.Status -eq 'Completed') 'Authorize response rejected.'
        $done = Complete-TCLinuxJob -Id $j.JobId -Root $jobsRoot
        Assert-True ($done.NodeName -eq 'Existing Linux' -and $done.RequestDirectory -ne $completed.RequestDirectory) 'Authorize reused another client identity.'
    }
    Test-Case 'recover inherits Plan or Apply target with an empty backend input' {
        foreach ($parentId in @($preview.JobId,$apply.JobId)) {
            $j = Invoke-TCLinuxRequest -Request @{ Action = 'LinuxStart'; Operation = 'Recover'; ParentJobId = $parentId; PlanId = $preview.Data.PlanId } -Root $testRoot
            Assert-True ($j.Connection.Host -eq '8.8.8.8' -and $j.ParentJobId -eq $parentId) 'Recover lost reviewed host context.'
            $payload = Read-FixtureJson (Join-Path (Join-Path $jobsRoot $j.JobId) 'payload.json')
            Assert-True (($payload.Input | ConvertTo-Json -Compress) -eq '{}') 'Recover backend input was not empty.'
            $result = Run-FixtureJob $j.JobId
            Assert-True ($result.Status -eq 'Completed') 'Linked recovery failed.'
        }
        Assert-Throws { New-TCLinuxJob -Action Recover -JobId $preview.JobId -Connection @{ Host = '1.1.1.1' } -Root $jobsRoot } PlanMismatch
        Assert-Throws { New-TCLinuxJob -Action Recover -JobId $preview.JobId -PlanId ([guid]::NewGuid().ToString()) -Root $jobsRoot } PlanMismatch
    }
    Test-Case 'recent jobs are capped at ten; context survives fresh module state' {
        foreach ($index in 1..12) { $null = Start-FixtureJob Status }
        $before = & $module { $script:ConsoleStarts }
        $recent = Invoke-TCLinuxRequest -Request @{ Action = 'LinuxRecent' } -Root $testRoot
        Assert-True ($recent.Items.Count -eq 10) 'Recent result was not bounded.'
        foreach ($entry in $recent.Items) {
            Assert-True ($entry.Host -eq '8.8.8.8' -and $entry.CreatedAt -and $entry.Status -in @('Running','Completed','Failed')) 'Recent public context incomplete.'
        }
        $poll = Invoke-TCLinuxRequest -Request @{ Action = 'LinuxPoll'; Id = $preview.JobId } -Root $testRoot
        Assert-True ($poll.Name -eq '隔离 Linux 节点' -and $poll.TunnelSubnet -eq '10.78.0.0/24' -and $poll.Data.PlanId) 'Saved Plan cannot be resumed.'
        Assert-True ((& $module { $script:ConsoleStarts }) -eq $before) 'Recent or resume launched another console.'
    }
    Test-Case 'path traversal and unsafe existing ACLs are rejected' {
        Assert-Throws { Get-TCLinuxJob -Id '..\other' -Root $jobsRoot } InvalidId
        Assert-Throws { New-TCLinuxJob -Action Inspect -Connection @{ Host = '8.8.8.8' } -Root '\\remote\share' } InvalidPath
        $unsafe = Join-Path $testRoot 'unsafe-root'; $null = [IO.Directory]::CreateDirectory($unsafe)
        Assert-Throws { New-TCLinuxJob -Action Inspect -Connection @{ Host = '8.8.8.8' } -Root $unsafe } UnsafeAcl
    }
    Test-Case 'network diagnostics are explicit Status-only public input' {
        Assert-Throws { Invoke-TCLinuxRequest -Request @{Action='LinuxStart';Operation='Inspect';Connection=@{Host='8.8.8.8';User='root'};NetworkProbe=$true} -Root $testRoot } InvalidRequest
        Assert-Throws { Invoke-TCLinuxRequest -Request @{Action='LinuxStart';Operation='Status';Connection=@{Host='8.8.8.8';User='root'};NetworkProbe='false'} -Root $testRoot } InvalidRequest
        $job=Invoke-TCLinuxRequest -Request @{Action='LinuxStart';Operation='Status';Connection=@{Host='8.8.8.8';User='root'};NetworkProbe=$true} -Root $testRoot
        $payload=Read-FixtureJson (Join-Path (Join-Path $jobsRoot $job.JobId) 'payload.json')
        Assert-True ($payload.Input.NetworkProbe -eq $true -and @($payload.Input.PSObject.Properties).Count -eq 1) 'Diagnostic Status lost its explicit bounded flag.'
    }
    Test-Case 'header diagnostics require explicit network Status and bounded integer duration' {
        foreach($value in @(-1,61,1.5,'30',$true)){
            Assert-Throws { Invoke-TCLinuxRequest -Request @{Action='LinuxStart';Operation='Status';Connection=@{Host='8.8.8.8';User='root'};NetworkProbe=$true;CaptureSeconds=$value} -Root $testRoot } InvalidRequest
        }
        foreach($operation in @('Inspect','Status','Plan','Apply','Finalize')){
            Assert-Throws { Invoke-TCLinuxRequest -Request @{Action='LinuxStart';Operation=$operation;Connection=@{Host='8.8.8.8';User='root'};CaptureSeconds=0} -Root $testRoot } InvalidRequest
        }
        $job=Invoke-TCLinuxRequest -Request @{Action='LinuxStart';Operation='Status';Connection=@{Host='8.8.8.8';User='root'};NetworkProbe=$true;CaptureSeconds=45} -Root $testRoot
        $payload=Read-FixtureJson (Join-Path (Join-Path $jobsRoot $job.JobId) 'payload.json')
        Assert-True ($payload.Input.NetworkProbe -eq $true -and $payload.Input.CaptureSeconds -eq 45 -and @($payload.Input.PSObject.Properties).Count -eq 2) 'Header diagnostic request lost its explicit scope.'
    }
    Test-Case 'temporary UDP port comparison pins scope, source and duration' {
        $request=@{Action='LinuxStart';Operation='Status';Connection=@{Host='8.8.8.8';User='root'};NetworkProbe=$true;CaptureSeconds=45;ProbeRelayPort=443;ProbeSourceIPv4='8.8.4.4'}
        foreach($change in @(@{Operation='Inspect'},@{NetworkProbe=$false},@{CaptureSeconds=0},@{ProbeRelayPort=51820},@{ProbeRelayPort='443'},@{ProbeSourceIPv4=''})){
            $bad=$request.Clone();foreach($k in $change.Keys){$bad[$k]=$change[$k]}
            Assert-Throws { Invoke-TCLinuxRequest -Request $bad -Root $testRoot } InvalidRequest
        }
        $bad=$request.Clone();$bad.ProbeSourceIPv4='127.0.0.1'
        Assert-Throws { Invoke-TCLinuxRequest -Request $bad -Root $testRoot } InvalidHost
        $job=Invoke-TCLinuxRequest -Request $request -Root $testRoot
        $payload=Read-FixtureJson (Join-Path (Join-Path $jobsRoot $job.JobId) 'payload.json')
        Assert-True ($payload.Action -ceq 'status' -and $payload.Input.NetworkProbe -eq $true -and $payload.Input.CaptureSeconds -eq 45 -and $payload.Input.ProbeRelayPort -eq 443 -and $payload.Input.ProbeSourceIPv4 -eq '8.8.4.4' -and @($payload.Input.PSObject.Properties).Count -eq 4) 'Temporary diagnostic transport changed scope.'
    }
    Test-Case 'source has no local network mutations, activation or arbitrary remote commands' {
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($modulePath,[ref]$tokens,[ref]$errors)
        $forbidden = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -match '^(New|Set|Remove)-(NetRoute|NetIPAddress|DnsClientServerAddress|NetFirewallRule|NetNat|NetIPInterface)$|^(Enable-TCNode|Import-TCWireGuard|Invoke-Expression|Invoke-Command|Invoke-WebRequest)$' },$true))
        Assert-True ($forbidden.Count -eq 0) 'Local network/deployment side effect found.'
        $text = [IO.File]::ReadAllText($modulePath)
        Assert-True ($text -match '-WindowStyle Normal' -and $text -notmatch 'StrictHostKeyChecking=no|StrictHostKeyChecking=accept-new|RedirectStandardError = \$true') 'Auth console visibility/trust contract changed.'
    }
    Test-Case 'failure acknowledgement waits only in an interactive terminal' {
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($consolePath,[ref]$tokens,[ref]$errors)
        $function = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Wait-TCLinuxFailureClose' },$true)
        Assert-True ($null -ne $function) 'Console failure acknowledgement missing.'
        $counts = & $module {
            param($Definition)
            . ([scriptblock]::Create($Definition))
            $script:FixtureInteractive = $false; $script:FixtureClosePrompts = 0
            function Test-TCLinuxInteractiveTerminal { return $script:FixtureInteractive }
            function Read-Host { param($Prompt) $script:FixtureClosePrompts++; return 'ignored fixture acknowledgement' }
            Wait-TCLinuxFailureClose
            $noninteractive = $script:FixtureClosePrompts
            $script:FixtureInteractive = $true
            Wait-TCLinuxFailureClose
            [pscustomobject]@{ Noninteractive = $noninteractive; Interactive = $script:FixtureClosePrompts }
        } $function.Extent.Text
        Assert-True ($counts.Noninteractive -eq 0 -and $counts.Interactive -eq 1) 'Failure close prompt blocks redirected callers or skips interactive callers.'
        $consoleText = [IO.File]::ReadAllText($consolePath)
        Assert-True ($consoleText -match 'IsInputRedirected' -and $consoleText -match 'IsOutputRedirected' -and $consoleText -match 'UserInteractive') 'Real interactive terminal gate missing.'
    }

    $python = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($python) {
        Test-Case 'local inert Python proves large UTF-8 payload, CLI argv and replacement stdin' {
            $source = "import json,sys`nvalue=json.load(sys.stdin)`nprint(json.dumps(dict(Ok=True,Action=sys.argv[1],Data=dict(Name=value['Name'],Args=sys.argv[2:]),Message='ok'),ensure_ascii=True))`n" + ('# inert padding' + "`n") * 4000
            $payload = & $module { param($Source) [ordered]@{ SchemaVersion = 1; Source = $Source; SourceSHA256 = (Get-TCLinuxHash $Source); Action = 'plan'; Input = @{ Name = '中文大包' } } } $source
            $bootstrap = & $module { Get-TCLinuxBootstrap }
            Assert-True ($bootstrap -match "^python3 -I -c '(.*)'$") 'Cannot extract fixed bootstrap.'
            $code = $Matches[1]
            foreach ($tamper in @($false,$true)) {
                if ($tamper) { $payload.SourceSHA256 = '0' * 64 }
                $start = New-Object Diagnostics.ProcessStartInfo
                $start.FileName = $python.Source
                $start.Arguments = & $module { param($Code) (@('-I','-c',$Code) | ForEach-Object { ConvertTo-TCLinuxArgument $_ }) -join ' ' } $code
                $start.UseShellExecute = $false; $start.CreateNoWindow = $true
                $start.RedirectStandardInput = $true; $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
                $process = New-Object Diagnostics.Process; $process.StartInfo = $start
                try {
                    $oldEncoding = [Console]::InputEncoding
                    try {
                        [Console]::InputEncoding = New-Object Text.UTF8Encoding($false)
                        $null = $process.Start(); $stdin = $process.StandardInput.BaseStream
                    } finally { [Console]::InputEncoding = $oldEncoding }
                    $out = $process.StandardOutput.ReadToEndAsync(); $err = $process.StandardError.ReadToEndAsync()
                    $bytes = [Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Depth 8 -Compress))
                    $stdin.Write($bytes,0,$bytes.Length); $stdin.Close()
                    if (-not $process.WaitForExit(10000)) { $process.Kill(); throw 'Local bootstrap fixture timed out.' }
                    if ($tamper) { Assert-True ($process.ExitCode -eq 76 -and -not $out.Result) 'Bad source digest executed.' }
                    else {
                        Assert-True ($process.ExitCode -eq 0) ('Bootstrap did not run: ' + $err.Result)
                        $reply = $out.Result | ConvertFrom-Json
                        Assert-True ($reply.Action -eq 'plan' -and $reply.Data.Name -eq '中文大包' -and ($reply.Data.Args -join ',') -eq '--input,-') ('Bootstrap fixture response mismatch: ' + $out.Result)
                    }
                } finally { $process.Dispose() }
            }
        }
    } else { Write-Output 'SKIP optional local Python bootstrap check: Python is not installed; no download attempted.' }
} finally {
    if ($module) { Remove-Module $module -Force -ErrorAction SilentlyContinue }
    $resolved = [IO.Path]::GetFullPath($testRoot).TrimEnd('\')
    if ([IO.Path]::GetDirectoryName($resolved) -ine $testBase -or [IO.Path]::GetFileName($resolved) -cnotmatch '^tc-linuxbridge-test-[0-9a-f]{32}$') { throw 'Unsafe test cleanup target refused.' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop }
}
Write-Output ('LinuxBridge: {0} passed; {1} failed. Real SSH/consoles/network changes/ProgramData access: 0. Live deployment: NOT TESTED.' -f $script:passed,$script:failed)
if ($script:failed) { throw ('LinuxBridge tests failed: ' + $script:failed) }
