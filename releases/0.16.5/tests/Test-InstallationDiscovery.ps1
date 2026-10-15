#requires -Version 5.1
# Injected discovery sources and inert fixtures; no live shortcuts/registry mutation.
[CmdletBinding()]param()
$ErrorActionPreference='Stop';Set-StrictMode -Version 2
$package=Split-Path $PSScriptRoot -Parent;$module=Import-Module (Join-Path $package 'InstallationDiscovery.psm1') -Force -PassThru -DisableNameChecking
$work=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('TC-InstallationDiscovery-'+[guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($work);$script:Checks=0
function Check {param([bool]$Ok,[string]$Label)if(-not $Ok){throw ('Installation discovery regression: '+$Label)};$script:Checks++}
try{
    $current=Join-Path $work 'Current';$old=Join-Path $work 'Previous';foreach($dir in @($current,$old)){$null=[IO.Directory]::CreateDirectory($dir);[IO.File]::WriteAllText((Join-Path $dir 'TradeChannel.exe'),'inert')}
    [IO.File]::WriteAllText((Join-Path $current 'version.json'),'{"Version":"0.10.0"}');[IO.File]::WriteAllText((Join-Path $old 'version.json'),'{"Version":"0.9.3"}')
    & $module {
        param($New,$Old,$Fixture)
        $script:NewFixture=$New;$script:OldFixture=$Old;$script:FixtureRoot=$Fixture;$script:ShortcutReads=0
        function script:Get-TCInstallationSources {
            param($PackageRoot)
            [pscustomobject]@{Shortcuts=@('case-current','old-link','case-old','broken')+@(1..300|ForEach-Object {'noise-'+$_});Registered=@($script:OldFixture,$script:OldFixture.ToUpperInvariant());KnownPaths=@($script:NewFixture.ToUpperInvariant(),$script:OldFixture.ToUpperInvariant());ShortcutScanCount=304;RegistryScanCount=0}
        }
        function script:Read-TCInstallationShortcut {
            param($Path)
            $script:ShortcutReads++
            switch($Path){'case-current'{[pscustomobject]@{Path=$Path;Target=(Join-Path $script:NewFixture.ToUpperInvariant() 'TRADECHANNEL.EXE')}};'old-link'{[pscustomobject]@{Path=$Path;Target=(Join-Path $script:OldFixture 'TradeChannel.exe')}};'case-old'{[pscustomobject]@{Path=$Path;Target=(Join-Path $script:OldFixture.ToUpperInvariant() 'TRADECHANNEL.EXE')}};default{throw 'Unreadable fixture shortcut'}}
        }
    } $current $old $work
    $before=@(Get-ChildItem -LiteralPath $work -Recurse -File|ForEach-Object {(Get-FileHash -LiteralPath $_.FullName).Hash}) -join ','
    $info=Get-TCInstallationInfo -PackageRoot $current -Root (Join-Path $work 'Data')
    Check ($info.Current.Version -eq '0.10.0' -and $info.Current.PackageRoot -eq $current) 'current installation path and authoritative version visible'
    Check ($info.Copies.Count -eq 1 -and $info.Copies[0].Version -eq '0.9.3') 'case-only paths and repeated sources do not produce false copies'
    Check ($info.ShortcutMismatch.Count -eq 2 -and @($info.ShortcutMismatch|Where-Object {$_.Path -eq 'case-current'}).Count -eq 0) 'case-only shortcut targets match current installation'
    Check ($info.Scan.ShortcutsRead -eq 256 -and (& $module {$script:ShortcutReads}) -eq 256 -and -not $info.Scan.FullDiskScan) 'noisy discovery input is bounded at 256 reads'
    Check ($info.Scan.UnreadableShortcuts -gt 0 -and $info.Notices.Count -ge 1) 'unreadable shortcuts become notices without aborting discovery'
    $after=@(Get-ChildItem -LiteralPath $work -Recurse -File|ForEach-Object {(Get-FileHash -LiteralPath $_.FullName).Hash}) -join ',';Check ($before -ceq $after -and -not $info.FilesChanged -and -not $info.NetworkChanged) 'discovery leaves files and network unchanged'
    & $module {param($p)$script:OnlyCurrent=$p;function script:Get-TCInstallationSources {param($PackageRoot)[pscustomobject]@{Shortcuts=@();Registered=@($script:OnlyCurrent.ToUpperInvariant());KnownPaths=@($script:OnlyCurrent,$script:OnlyCurrent.ToUpperInvariant());ShortcutScanCount=0;RegistryScanCount=0}}} $current
    $caseOnly=Get-TCInstallationInfo -PackageRoot $current;Check ($caseOnly.Copies.Count -eq 0 -and $caseOnly.ShortcutMismatch.Count -eq 0) 'Casing alone never reports a second installation'
    $path=& $module {ConvertTo-TCInstallationPath '\\server\share\TradeChannel'};Check (-not $path) 'network locations excluded from local discovery'
    [pscustomobject]@{Passed=$true;Checks=$script:Checks;RealNetworkChanges=0;RegistryMutations=0;ShortcutMutations=0;CaseDeduplication=$true;BoundedReads=$true}
}finally{
    $full=[IO.Path]::GetFullPath($work);$parent=[IO.Path]::GetFullPath([Environment]::GetFolderPath('LocalApplicationData')).TrimEnd('\')+'\'
    if(-not $full.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notmatch '^TC-InstallationDiscovery-[0-9a-f]{32}$'){throw 'Cleanup rejected.'};Remove-Item -LiteralPath $full -Recurse -Force
}
