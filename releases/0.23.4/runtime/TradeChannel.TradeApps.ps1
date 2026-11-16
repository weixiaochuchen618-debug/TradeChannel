#requires -Version 5.1
# Shared by the UI worker, connection preflight and supervisor. Reads never
# modify application, network or protection state.
function Assert-TCTradeAppPath {
    param([string]$Path,[switch]$Executable,[switch]$MustExist)
    if(-not $Path -or $Path -notmatch '^[A-Za-z]:[\\/]' -or $Path.Substring(2).Contains(':') -or $Path -match '[\x00-\x1f*?]'){throw '请选择本机的完整程序路径。'}
    $full=[IO.Path]::GetFullPath($Path);$cursor=$full
    while($cursor){
        if(Test-Path -LiteralPath $cursor){if((Get-Item -LiteralPath $cursor -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint){throw '程序或名单路径不能经过链接。'}}
        $cursor=[IO.Path]::GetDirectoryName($cursor)
    }
    if($Executable -and [IO.Path]::GetExtension($full) -ine '.exe'){throw '请选择 .exe 程序文件。'}
    if($MustExist -and -not [IO.File]::Exists($full)){throw '找不到这个程序，请重新选择。'}
    $full
}
function Read-TCTradeAppJson {
    param([string]$Path,[int]$Limit=65536)
    $full=Assert-TCTradeAppPath $Path
    if(-not [IO.File]::Exists($full)){return $null}
    if((Get-Item -LiteralPath $full -Force -ErrorAction Stop).Length -gt $Limit){throw '交易软件名单大小异常，请从备份恢复。'}
    [IO.File]::ReadAllText($full,(New-Object Text.UTF8Encoding($false,$true))).TrimStart([char]0xfeff)|ConvertFrom-Json -ErrorAction Stop
}
function ConvertTo-TCTradeAppPrograms {
    param([AllowEmptyCollection()][object[]]$Programs,[switch]$MustExist)
    if(@($Programs).Count -gt 64){throw '最多添加 64 个交易程序。'}
    $seen=@{}
    foreach($item in @($Programs)){
        if($item -isnot [string] -or -not $item){throw '程序路径不能为空。'}
        $full=Assert-TCTradeAppPath $item -Executable -MustExist:$MustExist
        if(-not $seen.ContainsKey($full)){$seen[$full]=$true;$full}
    }
}
function Read-TCTradeAppRecord {
    param([string]$Root)
    $value=Read-TCTradeAppJson (Join-Path $Root 'trade-programs.json')
    if(-not $value){return $null}
    if($value.SchemaVersion -ne 1 -or $value.Owner -cne 'TradeChannel.TradeApps' -or $value.Revision -isnot [int] -or $value.Revision -lt 1 -or $value.Programs -isnot [array] -or @($value.PSObject.Properties.Name|Where-Object {$_ -cnotin @('SchemaVersion','Owner','Revision','Programs','UpdatedAtUtc')}).Count){throw '交易软件名单格式无效，未使用默认名单覆盖。'}
    $date=[DateTimeOffset]::MinValue
    if(-not [DateTimeOffset]::TryParse([string]$value.UpdatedAtUtc,[ref]$date)){throw '交易软件名单时间无效。'}
    $value.Programs=@(ConvertTo-TCTradeAppPrograms @($value.Programs));$value
}
function Get-TCTradeAppManifest {
    param([string]$Root)
    $deployment=Read-TCTradeAppJson (Join-Path $Root 'deployment.json')
    if(-not $deployment){return $null}
    if(-not $deployment.ManifestPath){throw '当前线路缺少配置路径，暂不能核实交易软件名单。'}
    $manifest=Read-TCTradeAppJson ([string]$deployment.ManifestPath) -Limit 4194304
    if(-not $manifest){throw '当前线路配置丢失，暂不能核实交易软件名单。'}
    $manifest
}
function Get-TCDetectedTradePrograms {
    foreach($base in @($env:ProgramFiles,${env:ProgramFiles(x86)})){
        if($base){$path=Join-Path $base 'NinjaTrader 8\bin\NinjaTrader.exe';if([IO.File]::Exists($path)){Assert-TCTradeAppPath $path -Executable}}
    }
}
function Get-TCConfiguredTradePrograms {
    param([string]$Root)
    $record=Read-TCTradeAppRecord $Root
    if($record){return @($record.Programs)}
    $manifest=Get-TCTradeAppManifest $Root
    if($manifest -and $manifest.PSObject.Properties['TradeProgramPaths']){return @(ConvertTo-TCTradeAppPrograms @($manifest.TradeProgramPaths))}
    @(Get-TCDetectedTradePrograms|Select-Object -Unique)
}
function Get-TCTradeAppProcesses {
    param([string[]]$Names)
    if(@($Names).Count){@(Get-Process -Name $Names -ErrorAction SilentlyContinue)}
}
function Test-TCTradeApplicationsRunning {
    param([Parameter(Mandatory=$true)][string]$Root,[AllowEmptyCollection()][string[]]$AdditionalPrograms=@(),[switch]$WithoutDeployment)
    # -WithoutDeployment is for status reads only: it leaves out the current
    # deployment's own program list when that manifest can no longer be read.
    # Connection gates never pass it, so they still refuse in that case.
    $manifest=if($WithoutDeployment){$null}else{Get-TCTradeAppManifest $Root}
    $configured=if($WithoutDeployment){$record=Read-TCTradeAppRecord $Root;if($record){@($record.Programs)}else{@(Get-TCDetectedTradePrograms|Select-Object -Unique)}}else{@(Get-TCConfiguredTradePrograms $Root)}
    $programs=@(@($configured)+@($AdditionalPrograms)+@($manifest.TradeProgramPaths)|Where-Object {$_}|Select-Object -Unique)
    if(-not $programs.Count){return $false}
    $names=@($programs|ForEach-Object {[IO.Path]::GetFileNameWithoutExtension($_)}|Select-Object -Unique)
    foreach($process in @(Get-TCTradeAppProcesses $names)){
        # If Windows cannot reveal a matching process path, keep the connection
        # change waiting instead of treating missing evidence as an exited app.
        $path=$null;try{$path=[string]$process.Path}catch{}
        if(-not $path -or $programs -icontains $path){return $true}
    }
    $false
}
