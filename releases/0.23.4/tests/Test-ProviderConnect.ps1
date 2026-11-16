#requires -Version 5.1
param([string]$ReportPath)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$source=Split-Path $PSScriptRoot -Parent;$work=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('TCProviderConnectTests-'+[guid]::NewGuid().ToString('N'))
$module=Import-Module (Join-Path $source 'ProviderBridge.psm1') -Force -PassThru -DisableNameChecking
try{
    $result=& $module {
        param($Work)
        $script:FixtureInstall=Join-Path $Work 'Client';$script:FixtureSettings=Join-Path $Work 'Settings';$root=Join-Path $Work 'Runtime';$checks=New-Object 'Collections.Generic.List[string]'
        function Check {param($Value,$Name);if(-not $Value){throw $Name};$checks.Add($Name)}
        function Write-Fixture {param($Path,$Text);$null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path));[IO.File]::WriteAllText($Path,$Text,(New-Object Text.UTF8Encoding($true)))}
        Write-Fixture (Join-Path $script:FixtureInstall 'clash-verge.exe') 'inert';Write-Fixture (Join-Path $script:FixtureInstall 'verge-mihomo.exe') 'inert'
        $base=@('mixed-port: 7897','mode: rule','allow-lan: false','tun: {enable: false}','dns: {enable: false}','proxies:','  - name: "remote"','    type: socks5','    server: node.fixture.invalid','    port: 1080','rules:','  - MATCH,remote') -join "`n"
        Write-Fixture (Join-Path $script:FixtureSettings 'clash-verge.yaml') $base
        Write-Fixture (Join-Path $script:FixtureSettings 'verge.yaml') "enable_system_proxy: false`nenable_tun_mode: false`nenable_proxy_guard: false"
        Write-Fixture (Join-Path $script:FixtureSettings 'profiles.yaml') "current: fixture`nitems:`n  - uid: Merge`n    type: merge`n    file: global.yaml"
        $settingsHash=(Get-FileHash -LiteralPath (Join-Path $script:FixtureSettings 'verge.yaml')).Hash
        $script:FixtureRunning=$false;$script:FixtureApplyCalls=0
        $script:FixtureErrorCode=${function:Get-TCProviderRelayErrorCode}
        function script:Get-TCProviderRelayErrorCode {param($ErrorRecord);$script:FixtureError=$ErrorRecord.Exception.Message+"`n"+$ErrorRecord.ScriptStackTrace;& $script:FixtureErrorCode $ErrorRecord}
        function script:Find-TCProviderCandidates { $found=Get-TCClashVergeState -InstallDirectory $script:FixtureInstall -ConfigDirectory $script:FixtureSettings -SkipRuntime;$found.ExtraDirectories=@();$found }
        function script:Get-TCProviderRuntimeOverview {param($Root);[pscustomobject]@{Running=$script:FixtureRunning;StateKey='Connected';Daily='direct';Exit=$(if($script:FixtureRunning){'provider-trade'}else{'hk'})}}
        function script:Get-TCSetupBusyPorts {@(7897)}
        function script:Test-TCOwnedListener {param($Port,$Directory);$false}
        function script:Apply-TCRegisteredProvider {param($Root,$Id,[switch]$ForTrade);$script:FixtureApplyCalls++;$r=New-TCProviderConnectResult $Id 'Fixture';$r.Registered=$true;$r.Applied=$true;$r.HotApplied=$true;$r.Stage='Complete';$r.Code='Applied';$r}
        $first=Invoke-TCProviderRequest -Root $root -Request ([pscustomobject]@{Action='ProviderConnect';CandidateKind='clashverge';Name='My proxy'})
        Check ($first.Registered -and $first.NeedsClientAction -and -not $first.Applied -and $first.Code -ceq 'ClientReloadRequired') ('One-key stops truthfully for client reload: '+$first.Code+' '+$script:FixtureError)
        Check ($first.BackupPath -and [IO.File]::Exists($first.BackupPath) -and $script:FixtureApplyCalls -eq 0) 'Preparation creates recoverable backup before any hot application'
        $record=Get-TCStoredProvider $root $first.Id;$merge=Join-Path $script:FixtureSettings 'profiles\global.yaml';$hash=(Get-FileHash -LiteralPath $merge).Hash;$created=$record.addedAt
        $count=@(Get-ChildItem -LiteralPath (Join-Path $root 'backup\providers') -Filter '*.json').Count
        $retry=Invoke-TCProviderRequest -Root $root -Request ([pscustomobject]@{Action='ProviderConnect';Id=$first.Id})
        Check ($retry.Id -ceq $first.Id -and $retry.NeedsClientAction -and $retry.NextStep -ceq $first.NextStep) 'One concise client action is repeated only as result; retry keeps ID'
        Check ((Get-FileHash -LiteralPath $merge).Hash -ceq $hash -and @((Read-TCProviderStore (Join-Path $root 'Product')).Providers).Count -eq 1 -and @(Get-ChildItem -LiteralPath (Join-Path $root 'backup\providers') -Filter '*.json').Count -eq $count) 'Unloaded retry is idempotent and preserves existing backup'
        $again=Register-TCProviderProfile -Root $root -Request ([pscustomobject]@{Kind='clashverge'})
        $saved=Get-TCStoredProvider $root $again.Id
        Check ($saved.name -ceq 'My proxy' -and $saved.addedAt -ceq $created) 'Rediscovery preserves user name and original registration time'
        $mergeText=[IO.File]::ReadAllText($merge)
        $mergeBytes=[IO.File]::ReadAllBytes($merge)
        [IO.File]::Delete($merge);$script:FixtureRunning=$true
        $busy=Invoke-TCProviderRequest -Root $root -Request ([pscustomobject]@{Action='ProviderConnect';Id=$first.Id})
        Check (-not $busy.Applied -and $busy.Code -ceq 'ProviderInUse' -and -not [IO.File]::Exists($merge)) 'Client preparation refuses selected trading provider before writing'
        $script:FixtureRunning=$false;[IO.File]::WriteAllBytes($merge,$mergeBytes)
        # Only the synthetic generated config is changed to model user loading.
        Write-Fixture (Join-Path $script:FixtureSettings 'clash-verge.yaml') ($base+"`n"+$mergeText)
        $done=Invoke-TCProviderRequest -Root $root -Request ([pscustomobject]@{Action='ProviderConnect';Id=$first.Id})
        Check ($done.Applied -and $done.HotApplied -and $script:FixtureApplyCalls -eq 1 -and -not $done.TradingExitChanged) 'Loaded config resumes into the same apply API without selecting an exit'
        Check ((Get-FileHash -LiteralPath (Join-Path $script:FixtureSettings 'verge.yaml')).Hash -ceq $settingsHash) 'No TUN/system-proxy/guard/client settings are changed'
        $restored=Invoke-TCProviderRequest -Root $root -Request ([pscustomobject]@{Action='ProviderRestore';Id=$first.Id;BackupPath=$first.BackupPath})
        Check ($restored.Restored -and -not [IO.File]::Exists($merge) -and -not $restored.Effective) 'Explicit restore uses original receipt and does not claim client reload'
        Write-Fixture $merge "sniffer:`n  enable: false"
        $manual=Invoke-TCProviderRequest -Root $root -Request ([pscustomobject]@{Action='ProviderConnect';Id=$first.Id})
        Check ($manual.NeedsClientAction -and $manual.Code -ceq 'ProviderClientMergeRequired' -and -not $manual.Applied) 'Custom merge conflict produces one client-action result instead of overwrite'
        [pscustomobject]@{Passed=$true;Checks=$checks.Count;Cases=$checks.ToArray();PowerShell=$PSVersionTable.PSVersion.ToString();RealNetworkChanges=0;Scope='Temporary Clash startup config; discovery/runtime/apply simulated, file preparation and rollback real'}
    } $work
    if($ReportPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($result|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($true)))}
    $result|Select-Object Passed,Checks,PowerShell,Scope
}finally{
    $full=[IO.Path]::GetFullPath($work);$base=[IO.Path]::GetFullPath([Environment]::GetFolderPath('LocalApplicationData')).TrimEnd('\')+'\'
    if(-not $full.StartsWith($base,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notmatch '^TCProviderConnectTests-[a-f0-9]{32}$'){throw 'Cleanup rejected'}
    if([IO.Directory]::Exists($full)){Remove-Item -LiteralPath $full -Recurse -Force}
}
