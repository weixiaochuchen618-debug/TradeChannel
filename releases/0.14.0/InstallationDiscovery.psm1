#requires -Version 5.1
Set-StrictMode -Version 2
function ConvertTo-TCInstallationPath {
    param([string]$Path)
    if([string]::IsNullOrWhiteSpace($Path)){return $null}
    $expanded=[Environment]::ExpandEnvironmentVariables($Path.Trim().Trim('"'))
    if($expanded -notmatch '^[A-Za-z]:\\' -or $expanded.Substring(2) -match '[:*?"<>|\x00-\x1f]'){return $null}
    try{$full=[IO.Path]::GetFullPath($expanded);if($full.Length -gt 3){$full=$full.TrimEnd('\')};$full}catch{$null}
}
function Get-TCInstallationSources {
    param([string]$PackageRoot)
    $shortcuts=New-Object 'Collections.Generic.List[string]';$seen=@{};$remaining=256;$directories=New-Object 'Collections.Generic.Queue[string]';$visited=@{};$directoryReads=0
    foreach($folder in @([Environment]::GetFolderPath('Desktop'),[Environment]::GetFolderPath('CommonDesktopDirectory'),[Environment]::GetFolderPath('Programs'),[Environment]::GetFolderPath('CommonPrograms'))){
        if($folder -and [IO.Directory]::Exists($folder)){$directories.Enqueue($folder)}
    }
    while($remaining -gt 0 -and $directories.Count -gt 0 -and $directoryReads -lt 128){
        $folder=$directories.Dequeue();$key=$folder.ToLowerInvariant();if($visited.ContainsKey($key)){continue};$visited[$key]=$true
        try{
            if((Get-Item -LiteralPath $folder -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint){continue};$directoryReads++
            # Only known shell shortcut locations; no whole-drive enumeration.
            foreach($item in @(Get-ChildItem -LiteralPath $folder -Filter '*.lnk' -File -ErrorAction SilentlyContinue|Select-Object -First $remaining)){
                if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $seen.ContainsKey($item.FullName.ToLowerInvariant())){continue};$seen[$item.FullName.ToLowerInvariant()]=$true;$shortcuts.Add($item.FullName);$remaining--
            }
            $capacity=128-$directoryReads-$directories.Count
            if($capacity -gt 0){foreach($sub in @(Get-ChildItem -LiteralPath $folder -Directory -ErrorAction SilentlyContinue|Select-Object -First $capacity)){if(-not ($sub.Attributes -band [IO.FileAttributes]::ReparsePoint)){$directories.Enqueue($sub.FullName)}}}
        }catch{}
    }
    $registered=New-Object 'Collections.Generic.List[string]';$registryRead=0
    foreach($key in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall','HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall','HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')){
        if($registryRead -ge 512){break}
        try{
            foreach($item in @(Get-ChildItem -LiteralPath $key -ErrorAction SilentlyContinue|Select-Object -First (512-$registryRead))){
                $registryRead++
                try{$p=Get-ItemProperty -LiteralPath $item.PSPath -ErrorAction Stop;if($p.PSObject.Properties['DisplayName'] -and [string]$p.DisplayName -match '^TradeChannel(?:\s|$)'){
                    if($p.PSObject.Properties['InstallLocation'] -and $p.InstallLocation){$registered.Add([string]$p.InstallLocation)}
                    if($p.PSObject.Properties['DisplayIcon'] -and $p.DisplayIcon){$icon=[string]$p.DisplayIcon;$icon=$icon -replace ',\s*-?\d+$','';$registered.Add($icon)}
                }}catch{}
            }
        }catch{}
    }
    $known=@('C:\TradeChannel','C:\tradechannel')
    foreach($base in @($env:ProgramFiles,${env:ProgramFiles(x86)},[Environment]::GetFolderPath('LocalApplicationData'))){if($base){$known+=Join-Path $base 'TradeChannel'}}
    $local=[Environment]::GetFolderPath('LocalApplicationData');if($local){$known+=Join-Path $local 'Programs\TradeChannel'}
    [pscustomobject]@{Shortcuts=$shortcuts.ToArray();Registered=$registered.ToArray();KnownPaths=$known;ShortcutScanCount=$shortcuts.Count;RegistryScanCount=$registryRead}
}
function Read-TCInstallationShortcut {
    param([string]$Path)
    $shell=$null;$shortcut=$null
    try{
        if(-not [IO.File]::Exists($Path) -or (Get-Item -LiteralPath $Path -Force).Length -gt 1048576){return $null}
        $shell=New-Object -ComObject WScript.Shell;$shortcut=$shell.CreateShortcut($Path)
        # CreateShortcut loads metadata; never call Save or change any property.
        [pscustomobject]@{Path=$Path;Target=[string]$shortcut.TargetPath;Arguments=[string]$shortcut.Arguments}
    }catch{$null}finally{if($shortcut -and [Runtime.InteropServices.Marshal]::IsComObject($shortcut)){$null=[Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut)};if($shell -and [Runtime.InteropServices.Marshal]::IsComObject($shell)){$null=[Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)}}
}
function Read-TCInstallationVersion {
    param([string]$Directory)
    $meta=Join-Path $Directory 'version.json'
    if([IO.File]::Exists($meta)){
        try{if((Get-Item -LiteralPath $meta -Force).Length -le 16384){$v=[IO.File]::ReadAllText($meta)|ConvertFrom-Json;if($v.PSObject.Properties['Version'] -and [string]$v.Version -match '^\d+\.\d+\.\d+(?:-[A-Za-z0-9.]+)?$'){return [pscustomobject]@{Value=[string]$v.Version;Source='PackageMetadata'}}}}catch{}
    }
    $exe=Join-Path $Directory 'TradeChannel.exe'
    if([IO.File]::Exists($exe)){try{$v=[Diagnostics.FileVersionInfo]::GetVersionInfo($exe);if($v.ProductVersion -match '^\d+\.\d+\.\d+(?:\.\d+)?$'){return [pscustomobject]@{Value=$v.ProductVersion;Source='ExecutableMetadata'}}}catch{}}
    [pscustomobject]@{Value='Unknown';Source='Unavailable'}
}
function Get-TCInstallationInfo {
    [CmdletBinding()]param([string]$PackageRoot=$PSScriptRoot,[string]$Root=(Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'TradeChannel'))
    $ErrorActionPreference='Stop';$currentPath=ConvertTo-TCInstallationPath $PackageRoot
    if(-not $currentPath){throw '当前程序目录必须是有效的本机磁盘路径。'}
    $version=Read-TCInstallationVersion $currentPath
    $current=[pscustomobject]@{PackageRoot=$currentPath;ExecutablePath=(Join-Path $currentPath 'TradeChannel.exe');Version=$version.Value;VersionSource=$version.Source;DataRoot=(ConvertTo-TCInstallationPath $Root)}
    $candidates=New-Object 'Collections.Generic.List[object]';$mismatches=New-Object 'Collections.Generic.List[object]';$notices=New-Object 'Collections.Generic.List[string]'
    $sources=Get-TCInstallationSources $currentPath;$seen=@{};$seen[$currentPath.ToLowerInvariant()]=$true;$readCount=0;$failed=0
    foreach($link in @($sources.Shortcuts|Select-Object -First 256)){
        $readCount++;$s=$null;try{$s=Read-TCInstallationShortcut $link}catch{$s=$null};if(-not $s){$failed++;continue}
        $target=ConvertTo-TCInstallationPath $s.Target
        if(-not $target -or [IO.Path]::GetFileName($target) -notin @('TradeChannel.exe','TradeChannel.ps1')){continue}
        $dir=[IO.Path]::GetDirectoryName($target)
        if(-not $dir.Equals($currentPath,[StringComparison]::OrdinalIgnoreCase)){$mismatches.Add([pscustomobject]@{Path=[string]$s.Path;Target=$target;TargetExists=[IO.File]::Exists($target);Reason='DifferentPackageDirectory'})}
        if(-not $seen.ContainsKey($dir.ToLowerInvariant())){$seen[$dir.ToLowerInvariant()]=$true;$candidates.Add([pscustomobject]@{Directory=$dir;Source='Shortcut'})}
    }
    foreach($candidate in @($sources.Registered|Select-Object -First 128)+@($sources.KnownPaths|Select-Object -First 16)){
        $path=ConvertTo-TCInstallationPath ([string]$candidate);if(-not $path){continue};$dir=$(if([IO.Path]::GetExtension($path) -eq '.exe'){[IO.Path]::GetDirectoryName($path)}else{$path})
        if(-not $seen.ContainsKey($dir.ToLowerInvariant())){$seen[$dir.ToLowerInvariant()]=$true;$candidates.Add([pscustomobject]@{Directory=$dir;Source='KnownLocation'})}
    }
    $copies=@(foreach($candidate in $candidates){$exe=Join-Path $candidate.Directory 'TradeChannel.exe';$scriptFile=Join-Path $candidate.Directory 'TradeChannel.ps1';if([IO.File]::Exists($exe) -or [IO.File]::Exists($scriptFile)){$v=Read-TCInstallationVersion $candidate.Directory;[pscustomobject]@{PackageRoot=$candidate.Directory;ExecutablePath=$exe;Version=$v.Value;VersionSource=$v.Source;DiscoveredBy=$candidate.Source;SharesDataRoot=$null;DataRootEvidence='NotInspected'}}})
    if($copies.Count){$notices.Add('发现其他 TradeChannel 程序目录。请核对当前路径和快捷方式；本工具不会删除或替换其他目录。')}
    if($mismatches.Count){$notices.Add('部分快捷方式指向其他程序目录，可在设置页重新创建当前版本的桌面快捷方式。')}
    if($failed){$notices.Add('部分快捷方式无法读取；检测仅覆盖已知位置，不能证明电脑上只有一份程序。')}
    [pscustomobject]@{Current=$current;Copies=$copies;ShortcutMismatch=$mismatches.ToArray();Notices=$notices.ToArray();Scan=[pscustomobject]@{ShortcutLimit=256;ShortcutDirectoryLimit=128;ShortcutsRead=$readCount;RegistryLimit=512;FullDiskScan=$false;Coverage='KnownLocationsOnly';UnreadableShortcuts=$failed};NetworkChanged=$false;FilesChanged=$false}
}
Export-ModuleMember -Function Get-TCInstallationInfo
