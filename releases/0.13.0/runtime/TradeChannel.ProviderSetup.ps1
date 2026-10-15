#requires -Version 5.1
# Single setup implementation. File operations never activate/restart/stop clients.
# Applied = written, Effective = runtime verification (false until independently proven).
# https://wiki.metacubex.one/en/config/inbound/listeners/
# https://wiki.metacubex.one/en/config/sniff/ (HTTP/TLS/QUIC only)
$script:TCClashListener='tradechannel-trade'
$script:TCClashBegin='# >>> TradeChannel managed block (do not edit by hand) >>>'
$script:TCClashEnd='# <<< TradeChannel managed block <<<'
$script:TCClashPortCandidates=@(7895,7894,7893,7892,17895,17896,17897)
$script:TCReservedPorts=@(17890,17891)

# Conservative reader: block/flow maps and lists, quotes, comments and literals.
# Aliases, tags, duplicate keys and unsupported syntax fail closed, never ready.
function Split-TCYamlTokens {
    param([string]$Text,[char]$Separator=',')
    $parts=New-Object 'Collections.Generic.List[string]';$start=0;$quote=[char]0;$depth=0
    for($i=0;$i -lt $Text.Length;$i++){
        $c=$Text[$i]
        if($quote -ne [char]0){
            if($quote -eq '"' -and $c -eq '\'){$i++;continue}
            if($c -eq $quote){if($quote -eq "'" -and $i+1 -lt $Text.Length -and $Text[$i+1] -eq "'"){$i++;continue};$quote=[char]0};continue
        }
        if($c -in @('"',"'")){$quote=$c;continue}
        if($c -eq '#' -and ($i -eq 0 -or [char]::IsWhiteSpace($Text[$i-1]))){$Text=$Text.Substring(0,$i);break}
        if($c -in @('[','{')){$depth++}elseif($c -in @(']','}')){$depth--;if($depth -lt 0){throw 'YAML 括号不匹配。'}}
        if($depth -eq 0 -and $c -eq $Separator){$parts.Add($Text.Substring($start,$i-$start).Trim());$start=$i+1}
    }
    if($quote -ne [char]0 -or $depth -ne 0){throw '不支持未闭合或跨行的 YAML 流式值。'}
    $parts.Add($Text.Substring($start).Trim());,$parts.ToArray()
}
function ConvertFrom-TCYamlScalar {
    param([string]$Text)
    $v=(Split-TCYamlTokens $Text ([char]0))[0].Trim()
    if($v -match '^[&*!?]' -or $v -match '^<<\s*:'){throw '无法可靠分析 YAML 别名、标签或复杂键。'}
    if($v.StartsWith('[')){
        if(-not $v.EndsWith(']')){throw 'YAML 数组未闭合。'};$inner=$v.Substring(1,$v.Length-2)
        if(-not $inner.Trim()){return ,@()}
        return ,@(foreach($part in (Split-TCYamlTokens $inner)){ConvertFrom-TCYamlScalar $part})
    }
    if($v.StartsWith('{')){
        if(-not $v.EndsWith('}')){throw 'YAML 对象未闭合。'};$map=@{};$inner=$v.Substring(1,$v.Length-2)
        if($inner.Trim()){foreach($part in (Split-TCYamlTokens $inner)){
            $pair=Split-TCYamlTokens $part ':';if($pair.Count -lt 2){throw 'YAML 对象缺少冒号。'}
            $key=[string](ConvertFrom-TCYamlScalar $pair[0]);if($map.ContainsKey($key)){throw 'YAML 键重复。'}
            $map[$key]=ConvertFrom-TCYamlScalar (($pair|Select-Object -Skip 1) -join ':')
        }};return $map
    }
    if($v.StartsWith('"')){try{return ConvertFrom-Json -InputObject $v}catch{throw '不支持该 YAML 双引号转义。'}}
    if($v.StartsWith("'")){if(-not $v.EndsWith("'")){throw 'YAML 引号未闭合。'};return $v.Substring(1,$v.Length-2).Replace("''","'")}
    if($v -ceq 'true'){return $true};if($v -ceq 'false'){return $false};if($v -in @('','null','~')){return $null};$v
}
function Read-TCYamlNode {
    param($State,[int]$Indent,[int]$Depth=0)
    if($Depth -gt 40){throw 'YAML 嵌套过深。'}
    $sequence=$State.Lines[$State.Index].Text -match '^-(?:\s|$)';$list=New-Object 'Collections.Generic.List[object]';$map=@{}
    while($State.Index -lt $State.Lines.Count){
        $line=$State.Lines[$State.Index];if($line.Indent -lt $Indent){break};if($line.Indent -gt $Indent){throw 'YAML 缩进不一致。'}
        $isItem=$line.Text -match '^-(?:\s|$)';if($isItem -ne $sequence){break}
        if($sequence){
            $value=$line.Text.Substring(1).Trim();$State.Index++
            if($value){$node=ConvertFrom-TCYamlScalar $value}
            elseif($State.Index -lt $State.Lines.Count -and $State.Lines[$State.Index].Indent -gt $Indent){$node=Read-TCYamlNode $State $State.Lines[$State.Index].Indent ($Depth+1)}else{$node=$null}
            $list.Add($node)
        }else{
            if($line.Text -notmatch '^([A-Za-z0-9_.-]+|"[^"\r\n]+"|''(?:[^'']|'''')+'')\s*:\s*(.*)$'){throw '不支持该 YAML 映射格式。'}
            $key=[string](ConvertFrom-TCYamlScalar $matches[1]);$value=$matches[2]
            if($key -eq '<<' -or $map.ContainsKey($key)){throw 'YAML 键重复或使用合并别名。'};$State.Index++
            if($value){$map[$key]=ConvertFrom-TCYamlScalar $value}
            elseif($State.Index -lt $State.Lines.Count -and ($State.Lines[$State.Index].Indent -gt $Indent -or ($State.Lines[$State.Index].Indent -eq $Indent -and $State.Lines[$State.Index].Text -match '^-(?:\s|$)'))){$map[$key]=Read-TCYamlNode $State $State.Lines[$State.Index].Indent ($Depth+1)}else{$map[$key]=$null}
        }
    }
    if($sequence){return ,$list.ToArray()};$map
}
function ConvertFrom-TCProviderYaml {
    param([string[]]$Lines)
    $clean=New-Object 'Collections.Generic.List[object]'
    for($i=0;$i -lt @($Lines).Count;$i++){
        $raw=([string]$Lines[$i]).TrimStart([char]0xfeff).TrimEnd("`r")
        if($raw -match '^\s*(#.*)?$'){continue};if($raw -match '^\s*---\s*$' -and $clean.Count -eq 0){continue}
        if($raw -match '^\s*(---|\.\.\.|%)' -or $raw -match '^ *\t'){throw '不支持多个 YAML 文档、指令或制表符缩进。'}
        $indent=$raw.Length-$raw.TrimStart(' ').Length;$text=$raw.TrimStart(' ')
        if($text -match '^(.+:\s*)[|>][-+]?\s*(?:#.*)?$'){
            $prefix=$matches[1];$literal=New-Object 'Collections.Generic.List[string]'
            while($i+1 -lt $Lines.Count -and (([string]$Lines[$i+1]) -match '^\s*$' -or (([string]$Lines[$i+1]).Length-([string]$Lines[$i+1]).TrimStart(' ').Length) -gt $indent)){$i++;$literal.Add([string]$Lines[$i])}
            $text=$prefix+(ConvertTo-Json -InputObject ($literal.ToArray() -join "`n") -Compress)
        }else{$text=(Split-TCYamlTokens $text ([char]0))[0]}
        if($text -match '^-\s+([A-Za-z0-9_.-]+|"[^"\r\n]+"|''[^'']+'')\s*:\s*'){
            $clean.Add([pscustomobject]@{Indent=$indent;Text='-'});$clean.Add([pscustomobject]@{Indent=$indent+2;Text=$text.Substring(1).TrimStart()})
        }else{$clean.Add([pscustomobject]@{Indent=$indent;Text=$text})}
    }
    if(-not $clean.Count){return @{}}
    $state=@{Lines=$clean.ToArray();Index=0};if($state.Lines[0].Indent -ne 0){throw 'YAML 顶层必须从第 1 列开始。'}
    $node=Read-TCYamlNode $state 0
    if($state.Index -ne $state.Lines.Count -or $node -isnot [Collections.IDictionary]){throw 'YAML 顶层结构无效。'};$node
}
function Read-TCYamlTop {param([string[]]$Lines);ConvertFrom-TCProviderYaml $Lines}
function Get-TCYamlBlock {
    param([string[]]$Lines,[string]$Key)
    $out=New-Object 'Collections.Generic.List[string]';$inside=$false
    foreach($line in @($Lines)){if($line -match '^([A-Za-z0-9_.-]+)\s*:'){if($inside){break};if($matches[1] -eq $Key){$inside=$true};continue};if($inside){$out.Add($line)}};,$out.ToArray()
}
function Get-TCYamlItems {param([string[]]$Lines);$doc=ConvertFrom-TCProviderYaml (@('items:')+@($Lines));,@(Get-TCProviderValue $doc 'items' @())}
function Test-TCSniffPort {
    param($Ports,[int]$Port)
    foreach($part in @($Ports)){if([string]$part -eq [string]$Port){return $true};if([string]$part -match '^(\d+)-(\d+)$' -and $Port -ge [int]$matches[1] -and $Port -le [int]$matches[2]){return $true}};$false
}
function Get-TCClashRuntimeFacts {
    param([string[]]$Lines)
    $doc=ConvertFrom-TCProviderYaml $Lines;$sniffer=Get-TCProviderValue $doc 'sniffer' @{};$sniff=Get-TCProviderValue $sniffer 'sniff' @{}
    $enabled=(Get-TCProviderValue $sniffer 'enable') -eq $true;$pure=(Get-TCProviderValue $sniffer 'parse-pure-ip') -eq $true
    $override=(Get-TCProviderValue $sniffer 'override-destination' $true) -eq $true;$protocols=$true
    foreach($protocol in @('HTTP','TLS','QUIC')){
        $settings=Get-TCProviderValue $sniff $protocol @{};$port=if($protocol -eq 'HTTP'){80}else{443}
        if(-not (Test-TCSniffPort (Get-TCProviderValue $settings 'ports' @()) $port) -or (Get-TCProviderValue $settings 'override-destination' $override) -ne $true){$protocols=$false}
    }
    $listener=$null;$listeners=@(Get-TCProviderValue $doc 'listeners' @());$names=@{}
    foreach($entry in $listeners){
        $name=[string](Get-TCProviderValue $entry 'name');if(-not $name -or $names.ContainsKey($name)){throw 'Listener 名称缺失或重复。'};$names[$name]=$true
        if($name -eq $script:TCClashListener){$listener=[pscustomobject]@{
            Port=(ConvertTo-TCProviderPort (Get-TCProviderValue $entry 'port') -Required);Proxy=[string](Get-TCProviderValue $entry 'proxy');Listen=[string](Get-TCProviderValue $entry 'listen');Type=[string](Get-TCProviderValue $entry 'type')
            NoAuth=($entry.Contains('users') -and @(Get-TCProviderValue $entry 'users' @()).Count -eq 0);Udp=(Get-TCProviderValue $entry 'udp' $true) -eq $true
        }}
    }
    $groups=@(Get-TCProviderValue $doc 'proxy-groups' @());$proxies=@(Get-TCProviderValue $doc 'proxies' @());$proxyNames=@($groups+$proxies|ForEach-Object {Get-TCProviderValue $_ 'name'})
    $matchTarget=$null;foreach($rule in @(Get-TCProviderValue $doc 'rules' @())){if([string]$rule -match '^MATCH\s*,\s*([^,]+)'){$matchTarget=$matches[1].Trim();break}}
    $servers=@(foreach($p in $proxies){$server=[string](Get-TCProviderValue $p 'server');$ip=$null;if($server -and -not [Net.IPAddress]::TryParse($server,[ref]$ip)){ConvertTo-TCProviderDomains @($server)}})
    $servers=@(ConvertTo-TCProviderDomains $servers)
    if((Get-TCProviderValue $doc 'proxy-providers' @{}).Count -gt 0){throw '动态 proxy-providers 的上游域名无法完整静态确认，本版不自动登记。'}
    $mixed=Get-TCProviderValue $doc 'mixed-port';$socks=Get-TCProviderValue $doc 'socks-port';$http=Get-TCProviderValue $doc 'port'
    $mixed=if($mixed -and $mixed -ne '0'){ConvertTo-TCProviderPort $mixed}else{$null};$socks=if($socks -and $socks -ne '0'){ConvertTo-TCProviderPort $socks}else{$null};$http=if($http -and $http -ne '0'){ConvertTo-TCProviderPort $http}else{$null}
    $excluded=@(Get-TCProviderValue $sniffer 'skip-src-address' @()).Count -gt 0 -or @(Get-TCProviderValue $sniffer 'skip-dst-address' @()).Count -gt 0 -or @(@(Get-TCProviderValue $sniffer 'skip-domain' @())|Where-Object {$_ -in @('*','+.*')}).Count -gt 0
    [pscustomobject]@{
        MixedPort=$mixed;SocksPort=$socks;HttpPort=$http;Mode=[string](Get-TCProviderValue $doc 'mode' 'rule')
        SnifferEnabled=$enabled;ParsePureIp=$pure;OverrideDestination=$override;SnifferReady=($enabled -and $pure -and $override -and $protocols -and -not $excluded)
        Listener=$listener;Listeners=$listeners;Groups=@($groups|ForEach-Object {Get-TCProviderValue $_ 'name'});Proxies=$proxies;ProxyNames=$proxyNames;GroupDefinitions=$groups;MatchTarget=$matchTarget;NodeServers=$servers
        TunEnabled=((Get-TCProviderValue (Get-TCProviderValue $doc 'tun' @{}) 'enable') -eq $true);TradingEgressVerified=$false;Document=$doc
    }
}
function New-TCClashManagedBlock {
    param([Parameter(Mandatory=$true)][int]$Port,[Parameter(Mandatory=$true)][string]$Group)
    $null=ConvertTo-TCProviderPort $Port -Required;if($Port -lt 1024){throw '备用端口应在 1024–65535 之间。'}
    if([string]::IsNullOrWhiteSpace($Group) -or $Group -match '[\x00-\x1f]' -or $Group -in @('DIRECT','REJECT','REJECT-DROP','PASS','COMPATIBLE','GLOBAL')){throw '备用目标必须是明确的节点或代理组。'}
    $quoted=ConvertTo-Json -InputObject $Group -Compress
    @($script:TCClashBegin
      '# A group may select DIRECT; this configuration does not verify trading egress.'
      'sniffer:';'  enable: true';'  force-dns-mapping: true';'  parse-pure-ip: true';'  override-destination: true'
      '  sniff:';'    HTTP:';'      ports: [80, 8080-8880]';'      override-destination: true'
      '    TLS:';'      ports: [443, 8443]';'    QUIC:';'      ports: [443, 8443]'
      '  skip-domain:';'    - "Mijia Cloud"';'    - "+.push.apple.com"'
      'listeners:';('  - name: '+$script:TCClashListener);'    type: socks';('    port: '+$Port);'    listen: 127.0.0.1';'    users: []';'    udp: true';('    proxy: '+$quoted)
      $script:TCClashEnd)
}
function Split-TCClashMerge {
    param([string[]]$Lines)
    $own=New-Object 'Collections.Generic.List[string]';$managed=New-Object 'Collections.Generic.List[string]';$inside=$false;$found=$false
    foreach($raw in @($Lines)){
        $line=([string]$raw).TrimEnd("`r")
        $begin=$line.Trim() -eq $script:TCClashBegin -or $line -match '^# >>> TradeChannel(?::| begin)'
        $end=$line.Trim() -eq $script:TCClashEnd -or $line.Trim() -in @('# <<< TradeChannel <<<','# <<< TradeChannel end')
        if($begin){if($inside -or $found){throw '托管标记重复，未修改。'};$inside=$true;$found=$true;continue}
        if($end){if(-not $inside){throw '托管标记不完整，未修改。'};$inside=$false;continue}
        if($inside){$managed.Add($line)}else{$own.Add($line)}
    }
    if($inside){throw '托管标记不完整，未修改。'}
    [pscustomobject]@{Own=$own.ToArray();Managed=$managed.ToArray();Found=$found}
}
function Read-TCClashMerge {
    param([string]$Path)
    $exists=[bool]($Path -and [IO.File]::Exists($Path));$text=''
    if($exists){$text=Read-TCProviderTextFile $Path;if($null -eq $text){throw '无法读取 Clash 扩展配置。'}}
    $split=Split-TCClashMerge @($text -split '\r?\n');$own=ConvertFrom-TCProviderYaml $split.Own
    $conflicts=@(foreach($key in @('sniffer','listeners')){if($own.ContainsKey($key)){$key}})
    $facts=Get-TCClashRuntimeFacts $split.Managed;$port=$null;$group=$null;if($facts.Listener){$port=$facts.Listener.Port;$group=$facts.Listener.Proxy}
    [pscustomobject]@{Path=$Path;Exists=$exists;Managed=$split.Found;Port=$port;Group=$group;Conflicts=$conflicts;Own=$split.Own;CurrentText=$text}
}
function Get-TCProviderBytesHash {
    param([byte[]]$Bytes)
    $sha=[Security.Cryptography.SHA256]::Create();try{[BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-','')}finally{$sha.Dispose()}
}
function Set-TCProviderFileTransaction {
    param([string]$Path,[string]$NextText,[string]$BackupDirectory,[AllowNull()][string]$ExpectedText)
    $full=[IO.Path]::GetFullPath($Path);Assert-TCProviderNoReparse $full;Assert-TCProviderNoReparse $BackupDirectory
    $exists=[IO.File]::Exists($full);[byte[]]$original=if($exists){[IO.File]::ReadAllBytes($full)}else{[byte[]]@()}
    if($null -eq $original){$original=[byte[]]@()}
    $current=if($exists){Read-TCProviderTextFile $full}else{''}
    if($null -eq $current -or $current -cne [string]$ExpectedText){throw '配置在计划后已变化，请刷新后重试。'}
    if($current -ceq $NextText){return [pscustomobject]@{Path=$full;MergePath=$full;Changed=$false;Backup=$null;BackupPath=$null}}
    $bytes=(New-Object Text.UTF8Encoding($false)).GetBytes($NextText)
    $null=[IO.Directory]::CreateDirectory($BackupDirectory);$backup=Join-Path $BackupDirectory ('clash-merge-'+[Guid]::NewGuid().ToString('N')+'.json')
    $receipt=[ordered]@{Version=1;Path=$full;Existed=$exists;OriginalBase64=[Convert]::ToBase64String($original);OriginalHash=(Get-TCProviderBytesHash $original);AppliedHash=(Get-TCProviderBytesHash $bytes)}
    Write-TCProviderAtomicBytes $backup ([Text.Encoding]::UTF8.GetBytes(($receipt|ConvertTo-Json)))
    if([IO.File]::Exists($full) -ne $exists -or ($exists -and (Get-TCProviderBytesHash ([IO.File]::ReadAllBytes($full))) -ne $receipt.OriginalHash)){throw '配置被其他程序更新，未覆盖。'}
    Write-TCProviderAtomicBytes $full $bytes
    [pscustomobject]@{Path=$full;MergePath=$full;Changed=$true;Backup=$backup;BackupPath=$backup}
}
function Set-TCClashManagedBlock {
    param([Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)][string[]]$Block,[Parameter(Mandatory=$true)][string]$BackupDirectory)
    $state=Read-TCClashMerge $Path;if($state.Conflicts.Count){throw '已有自定义 sniffer/listeners，未覆盖；请手动合并。'}
    $parts=Split-TCClashMerge $Block;if(-not $parts.Found -or @($parts.Own|Where-Object {$_.Trim()}).Count){throw '无效托管块。'}
    $facts=Get-TCClashRuntimeFacts $parts.Managed
    if(-not $facts.SnifferReady){throw '托管嗅探配置不完整。'}
    if($facts.Listener -and ($facts.Listener.Type -ne 'socks' -or $facts.Listener.Listen -ne '127.0.0.1' -or -not $facts.Listener.NoAuth -or -not $facts.Listener.Proxy)){throw '备用监听器无效。'}
    $own=($state.Own -join "`n").TrimEnd("`r","`n");$next=if($own){$own+"`n`n"}else{''};$next+=($Block -join "`n")+"`n"
    Set-TCProviderFileTransaction $Path $next $BackupDirectory $state.CurrentText
}
function Remove-TCClashManagedBlock {
    param([Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)][string]$BackupDirectory)
    $state=Read-TCClashMerge $Path
    if(-not $state.Managed){return [pscustomobject]@{Path=$Path;Backup=$null;BackupPath=$null;Removed=$false;Changed=$false}}
    $result=Set-TCProviderFileTransaction $Path (($state.Own -join "`n").TrimEnd("`r","`n")+"`n") $BackupDirectory $state.CurrentText
    $result|Add-Member NoteProperty Removed $true -PassThru
}
function Restore-TCProviderFileTransaction {
    param([string]$Path,[string]$BackupPath,[string]$BackupRoot)
    $full=[IO.Path]::GetFullPath($BackupPath);$target=[IO.Path]::GetFullPath($Path)
    if(-not (Test-TCProviderPathWithin $full $BackupRoot)){throw '只能从指定备份目录恢复。'};Assert-TCProviderNoReparse $full;Assert-TCProviderNoReparse $target
    $text=Read-TCProviderTextFile $full;if($null -eq $text){throw '找不到可读取的恢复凭据。'}
    try{$receipt=ConvertFrom-Json -InputObject $text}catch{throw '恢复凭据格式无效。'}
    if((Get-TCProviderValue $receipt 'Version') -ne 1 -or (Get-TCProviderValue $receipt 'Path') -ne $target){throw '恢复凭据不属于此配置文件。'}
    $original=[Convert]::FromBase64String([string](Get-TCProviderValue $receipt 'OriginalBase64'))
    if((Get-TCProviderBytesHash $original) -ne $receipt.OriginalHash){throw '备份内容校验失败。'}
    $exists=[IO.File]::Exists($target);$hash=if($exists){Get-TCProviderBytesHash ([IO.File]::ReadAllBytes($target))}else{$null}
    $restored=($receipt.Existed -and $exists -and $hash -eq $receipt.OriginalHash) -or (-not $receipt.Existed -and -not $exists)
    if(-not $restored){
        if(-not $exists -or $hash -ne $receipt.AppliedHash){throw '配置已被后续修改，拒绝覆盖；备份仍保留。'}
        if($receipt.Existed){Write-TCProviderAtomicBytes $target $original}else{[IO.File]::Delete($target)}
    }
    [pscustomobject]@{Restored=$true;Changed=(-not $restored);MergePath=$target;BackupPath=$full;Effective=$false;RestartRequired=(-not $restored);TradingEgressVerified=$false}
}
function Select-TCClashTradePort {
    param([int[]]$Busy=@(),[AllowNull()]$Keep)
    if($null -ne $Keep){$port=ConvertTo-TCProviderPort $Keep -Required;if($port -lt 1024){throw '备用端口应大于 1023。'};if($port -notin $Busy){return $port}}
    foreach($port in $script:TCClashPortCandidates){if($port -notin $Busy){return $port}};throw '没有可用的专用备用端口。'
}
function Read-TCProviderYamlFile {
    param([string]$Path)
    $text=Read-TCProviderTextFile $Path;if($null -eq $text){throw '无法读取配置文件。'};ConvertFrom-TCProviderYaml @($text -split '\r?\n')
}
function Get-TCClashVergeInstallDirectory {
    $dirs=New-Object 'Collections.Generic.List[string]'
    foreach($key in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*','HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*')){
        foreach($item in @(Get-ItemProperty -Path $key -ErrorAction SilentlyContinue)){
            if([string](Get-TCProviderValue $item 'DisplayName') -match '^Clash Verge' -and (Get-TCProviderValue $item 'InstallLocation')){$dirs.Add(([string]$item.InstallLocation).Trim().Trim('"'))}
        }
    }
    foreach($base in @($env:ProgramFiles,${env:ProgramFiles(x86)},$(if($env:LOCALAPPDATA){Join-Path $env:LOCALAPPDATA 'Programs'}))){if($base){$dirs.Add((Join-Path $base 'Clash Verge'))}}
    foreach($dir in $dirs){if([IO.File]::Exists((Join-Path $dir 'clash-verge.exe'))){return ([IO.Path]::GetFullPath($dir)).TrimEnd('\')}};$null
}
function Get-TCClashMergePath {
    param([string]$ConfigDirectory)
    $profiles=Join-Path $ConfigDirectory 'profiles.yaml';$file='Merge.yaml'
    if([IO.File]::Exists($profiles)){
        $doc=Read-TCProviderYamlFile $profiles;$items=@(Get-TCProviderValue $doc 'items' @())
        $global=@($items|Where-Object {(Get-TCProviderValue $_ 'uid') -ceq 'Merge'})
        if($global.Count -gt 1){throw '全局 Merge 档案重复。'}
        if($global.Count -eq 1){
            if((Get-TCProviderValue $global[0] 'type') -ne 'merge'){throw '全局 Merge 档案类型无效。'}
            $file=[string](Get-TCProviderValue $global[0] 'file');if(-not $file -or $file -match '[\\/:]' -or $file -in @('.','..') -or [IO.Path]::GetExtension($file) -notin @('.yaml','.yml')){throw 'Merge 文件路径无效。'}
        }
    }
    Join-Path (Join-Path $ConfigDirectory 'profiles') $file
}
function Test-TCOwnedListener {
    param([int]$Port,[string]$Directory)
    if(-not $Port -or -not $Directory){return $false}
    if(-not (Get-Command Get-TCListenerOwnerIds -ErrorAction SilentlyContinue)){. (Join-Path $PSScriptRoot 'TradeChannel.Provider.ps1')}
    $owners=@(Get-TCListenerOwnerIds $Port);if(-not $owners.Count){return $false}
    foreach($owner in $owners){$path=Get-TCProcessImagePath ([int]$owner);if(-not (Test-TCProviderPathWithin $path $Directory)){return $false}};$true
}
function Get-TCRunningUnder {
    param([string]$Directory)
    if(-not $Directory){return @()}
    @(Get-Process -ErrorAction SilentlyContinue|Where-Object {try{$_.Path -and (Test-TCProviderPathWithin $_.Path $Directory)}catch{$false}})
}
function Get-TCClashVergeState {
    param([string]$InstallDirectory=(Get-TCClashVergeInstallDirectory),[string]$ConfigDirectory=$(if($env:APPDATA){Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev'}),[switch]$SkipRuntime)
    if(-not $InstallDirectory -or -not [IO.File]::Exists((Join-Path $InstallDirectory 'clash-verge.exe'))){return $null}
    $programs=@(foreach($name in @('clash-verge.exe','verge-mihomo.exe','verge-mihomo-alpha.exe','clash-verge-service.exe')){$path=Join-Path $InstallDirectory $name;if([IO.File]::Exists($path)){$path}})
    $extra=@(foreach($base in @($env:ProgramFiles,${env:ProgramFiles(x86)})){if($base){$path=Join-Path $base 'Clash Verge Service';if([IO.Directory]::Exists($path)){$path}}})
    $issues=New-Object 'Collections.Generic.List[object]'
    $s=[ordered]@{Kind='clashverge';Name='Clash Verge';Installed=$true;Detected=$true;Directory=$InstallDirectory;InstallDirectory=$InstallDirectory;ConfigDirectory=$ConfigDirectory;SettingsDirectory=$ConfigDirectory;ProgramPaths=$programs;ExtraDirectories=$extra
        Version=$null;MixedPort=$null;DailyPort=$null;HttpPort=$null;PacPort=$null;SystemProxy=$null;Tun=$null;ProxyGuard=$null;AutoLaunch=$null;ConfigFound=$false;ConfigPath=$null
        SnifferReady=$false;RuntimeListener=$null;RuntimeFacts=$null;Groups=@();MatchTarget=$null;DefaultGroup=$null;NodeServers=@();BootstrapDomains=@();BootstrapComplete=$false;Mode=$null
        MergePath=$null;Managed=$false;ManagedPort=$null;ManagedGroup=$null;MergeConflicts=@();RestartNeeded=$false;RestartRequired=$false
        Running=$false;CoreRunning=$false;DailyListening=$false;TradeListening=$false;TradePort=$null;Ready=$false;Effective=$false;TradingEgressVerified=$false;Issues=@();ModeHint='保持规则模式，关闭其他 TUN/系统代理守卫。'}
    if($ConfigDirectory -and [IO.Directory]::Exists($ConfigDirectory)){
        try{
            $vergePath=Join-Path $ConfigDirectory 'verge.yaml'
            if([IO.File]::Exists($vergePath)){
                $v=Read-TCProviderYamlFile $vergePath
                foreach($mapping in @(@('SystemProxy','enable_system_proxy'),@('Tun','enable_tun_mode'),@('ProxyGuard','enable_proxy_guard'),@('AutoLaunch','enable_auto_launch'))){$value=Get-TCProviderValue $v $mapping[1];if($null -ne $value){$s[$mapping[0]]=($value -eq $true)}}
            }
            # config.yaml is NOT Verge's effective generated configuration.
            $runtime=Join-Path $ConfigDirectory 'clash-verge.yaml';$s.ConfigPath=$runtime
            if([IO.File]::Exists($runtime)){
                $f=Get-TCClashRuntimeFacts @((Read-TCProviderTextFile $runtime) -split '\r?\n');$s.RuntimeFacts=$f;$s.ConfigFound=$true
                $s.MixedPort=$f.MixedPort;$s.DailyPort=if($f.MixedPort){$f.MixedPort}else{$f.SocksPort};$s.HttpPort=if($f.MixedPort){$f.MixedPort}else{$f.HttpPort}
                $s.SnifferReady=$f.SnifferReady;$s.RuntimeListener=$f.Listener;$s.Groups=$f.Groups;$s.MatchTarget=$f.MatchTarget;$s.NodeServers=$f.NodeServers;$s.BootstrapDomains=$f.NodeServers;$s.BootstrapComplete=$true;$s.Mode=$f.Mode
                if($f.TunEnabled){$s.Tun=$true}
                if($f.MatchTarget -and $f.MatchTarget -in $f.ProxyNames){$s.DefaultGroup=$f.MatchTarget}
                elseif($f.Groups.Count){$s.DefaultGroup=$f.Groups[0]}
                else{$remote=@($f.Proxies|Where-Object {(Get-TCProviderValue $_ 'type') -notin @('direct','reject','pass')});if($remote.Count){$s.DefaultGroup=[string](Get-TCProviderValue $remote[0] 'name')}}
            }
            $s.MergePath=Get-TCClashMergePath $ConfigDirectory;$merge=Read-TCClashMerge $s.MergePath
            $s.Managed=$merge.Managed;$s.ManagedPort=$merge.Port;$s.ManagedGroup=$merge.Group;$s.MergeConflicts=$merge.Conflicts
            # Persist the prepared port even before Verge reloads; do not claim loaded.
            $s.TradePort=if($merge.Port){$merge.Port}elseif($s.RuntimeListener){$s.RuntimeListener.Port}else{$null}
            $s.RestartNeeded=[bool]($s.Managed -and -not ($s.SnifferReady -and $s.RuntimeListener -and $s.RuntimeListener.Port -eq $s.ManagedPort -and $s.RuntimeListener.Proxy -eq $s.ManagedGroup -and $s.RuntimeListener.NoAuth -and $s.RuntimeListener.Listen -eq '127.0.0.1' -and $s.RuntimeListener.Type -eq 'socks'))
            $s.RestartRequired=$s.RestartNeeded
        }catch{$issues.Add([pscustomobject]@{Code='UnsupportedConfig';Text='配置或上游域名无法完整分析（最多 256 个；动态订阅池需手动核对），不允许登记或准备。'})}
    }
    if(-not $s.ConfigFound -or -not $s.DailyPort){$issues.Add([pscustomobject]@{Code='NoConfig';Text='未找到有效 clash-verge.yaml 和本机 SOCKS/混合端口。'})}
    if($s.Tun -or $s.ProxyGuard -or $s.SystemProxy){$issues.Add([pscustomobject]@{Code='ClientCapture';Text='请在客户端关闭 TUN、系统代理和代理守卫；当前设置未修改。'})}
    if($s.MergeConflicts.Count){$issues.Add([pscustomobject]@{Code='MergeConflict';Text='已有自定义嗅探或监听配置，请手动合并。'})}
    if(-not $SkipRuntime){
        $running=@(Get-TCRunningUnder $InstallDirectory);$s.Running=[bool]@($running|Where-Object {$_.ProcessName -eq 'clash-verge'}).Count;$s.CoreRunning=[bool]@($running|Where-Object {$_.ProcessName -like 'verge-mihomo*'}).Count
        if($s.DailyPort){$s.DailyListening=Test-TCOwnedListener $s.DailyPort $InstallDirectory};if($s.TradePort){$s.TradeListening=Test-TCOwnedListener $s.TradePort $InstallDirectory}
    }
    $s.Issues=$issues.ToArray()
    $s.Ready=[bool](-not $SkipRuntime -and $s.ConfigFound -and $s.SnifferReady -and $s.Managed -and -not $s.RestartNeeded -and $s.DailyListening -and $s.TradeListening -and -not $issues.Count)
    $s.Remove('RuntimeFacts')
    [pscustomobject]$s
}
function Get-TCBatVPNState {
    param([string]$InstallDirectory=$(if($env:LOCALAPPDATA){Join-Path $env:LOCALAPPDATA 'Programs\BatVPN'}),[string]$ConfigPath=$(if($env:APPDATA){Join-Path $env:APPDATA 'BatVPN\config.json'}),[switch]$SkipRuntime)
    if(-not $InstallDirectory -or -not [IO.File]::Exists((Join-Path $InstallDirectory 'BatVPN.exe'))){return $null}
    $programs=@(foreach($name in @('BatVPN.exe','resources\extra\v2ray-core\Windows\v2ray.exe')){$path=Join-Path $InstallDirectory $name;if([IO.File]::Exists($path)){$path}})
    $s=[ordered]@{Kind='batvpn';Name='BatVPN';Installed=$true;Detected=$true;Directory=$InstallDirectory;InstallDirectory=$InstallDirectory;ConfigPath=$ConfigPath;SettingsDirectory=[IO.Path]::GetDirectoryName($ConfigPath);ProgramPaths=$programs;ExtraDirectories=@();SocksPort=$null;DailyPort=$null;TradePort=$null;HttpPort=$null;PacPort=$null;BootstrapDomains=@();BootstrapComplete=$false;SnifferReady=$false;Running=$false;CoreRunning=$false;DailyListening=$false;Ready=$false;TradingEgressVerified=$false;Issues=@();ModeHint='日常可用白名单模式；备用交易出口必须单独验证。'}
    try{
        $text=Read-TCProviderTextFile $ConfigPath;if(-not $text){throw 'Missing config'};$doc=ConvertFrom-Json -InputObject $text
        $socks=@(@(Get-TCProviderValue $doc 'inbounds' @())|Where-Object {(Get-TCProviderValue $_ 'protocol') -eq 'socks' -and (Get-TCProviderValue (Get-TCProviderValue $_ 'settings') 'auth' 'noauth') -eq 'noauth' -and (Get-TCProviderValue $_ 'listen' '0.0.0.0') -in @('127.0.0.1','0.0.0.0','::','::1','localhost')})
        if($socks.Count -ne 1){throw 'Ambiguous socks listener'}
        $s.SocksPort=ConvertTo-TCProviderPort (Get-TCProviderValue $socks[0] 'port') -Required;$s.DailyPort=$s.SocksPort
        $sniff=Get-TCProviderValue $socks[0] 'sniffing' @{};$s.SnifferReady=(Get-TCProviderValue $sniff 'enabled') -eq $true
        foreach($inbound in @(Get-TCProviderValue $doc 'inbounds' @())){if((Get-TCProviderValue $inbound 'protocol') -eq 'http'){$s.HttpPort=ConvertTo-TCProviderPort (Get-TCProviderValue $inbound 'port')}}
        $domains=@(foreach($out in @(Get-TCProviderValue $doc 'outbounds' @())){$settings=Get-TCProviderValue $out 'settings';foreach($remote in @((Get-TCProviderValue $settings 'vnext' @()))+@((Get-TCProviderValue $settings 'servers' @()))){$address=Get-TCProviderValue $remote 'address';$ip=$null;if($address -and -not [Net.IPAddress]::TryParse([string]$address,[ref]$ip)){ConvertTo-TCProviderDomains @($address)}}})
        $s.BootstrapDomains=@(ConvertTo-TCProviderDomains $domains);$s.BootstrapComplete=$true
    }catch{$s.Issues=@([pscustomobject]@{Code='NoConfig';Text='SOCKS 配置或上游域名无法完整读取（最多 256 个），不允许登记。'})}
    if(-not $SkipRuntime -and $s.DailyPort){$s.DailyListening=Test-TCOwnedListener $s.DailyPort $InstallDirectory;$s.Running=$s.DailyListening;$s.CoreRunning=$s.DailyListening}
    $s.Ready=[bool](-not $SkipRuntime -and $s.DailyPort -and $s.DailyListening);[pscustomobject]$s
}
function Get-TCCustomProviderState {
    param([Parameter(Mandatory=$true)]$Profile,[switch]$SkipRuntime)
    $record=New-TCProviderRecord $Profile 1;$health=$null
    if(-not $SkipRuntime){$target=[pscustomobject]@{Port=$record.dailyPort;Directories=@($record.directory)+$record.extraDirectories;Programs=$record.programPaths;Name=$record.name;Id=$record.id;Tag='provider'};$health=Get-TCProviderHealth -Provider $target}
    [pscustomobject]@{Kind='custom';Name=$record.name;Directory=$record.directory;InstallDirectory=$record.directory;ProgramPaths=$record.programPaths;ExtraDirectories=$record.extraDirectories;DailyPort=$record.dailyPort;TradePort=$record.tradePort;HttpPort=$record.httpPort;PacPort=$record.pacPort;SettingsDirectory=$record.settingsDirectory;BootstrapDomains=$record.bootstrapDomains;Detected=$true;Ready=[bool]($health -and $health.Healthy);Health=$health;TradingEgressVerified=$false;Issues=@()}
}
function Get-TCProviderCandidates {
    param([switch]$SkipRuntime)
    foreach($kind in @('batvpn','clashverge')){try{if($kind -eq 'batvpn'){$s=Get-TCBatVPNState -SkipRuntime:$SkipRuntime}else{$s=Get-TCClashVergeState -SkipRuntime:$SkipRuntime};if($s){$s}}catch{}}
}
function Find-TCProviderCandidates {param([switch]$SkipRuntime);Get-TCProviderCandidates -SkipRuntime:$SkipRuntime}
function Find-TCBatVPNProfile {Get-TCBatVPNState -SkipRuntime}
function Find-TCClashVergeProfile {Get-TCClashVergeState -SkipRuntime}
function Get-TCVergeSetting {param([string]$Text,[string]$Key);Get-TCProviderValue (ConvertFrom-TCProviderYaml @($Text -split '\r?\n')) $Key}
function ConvertTo-TCProviderProfile {
    param([Parameter(Mandatory=$true)]$State,[object[]]$Others=@())
    $directory=Get-TCProviderValue $State 'Directory' (Get-TCProviderValue $State 'InstallDirectory');$daily=Get-TCProviderValue $State 'DailyPort' (Get-TCProviderValue $State 'MixedPort' (Get-TCProviderValue $State 'SocksPort'))
    if(-not $daily){throw '服务商本机代理端口未知。'}
    @{Kind=$State.Kind;Name=$State.Name;Directory=$directory;DailyPort=$daily;SocksPort=$daily;TradePort=(Get-TCProviderValue $State 'TradePort');TradeDedicated=[bool](Get-TCProviderValue $State 'TradePort');ProgramPaths=@(Get-TCProviderValue $State 'ProgramPaths' @());ExtraDirectories=@(Get-TCProviderValue $State 'ExtraDirectories' @());HttpPort=(Get-TCProviderValue $State 'HttpPort');PacPort=(Get-TCProviderValue $State 'PacPort');SettingsDirectory=(Get-TCProviderValue $State 'SettingsDirectory');BootstrapDomains=@(Get-TCProviderValue $State 'BootstrapDomains' @());BypassDirectories=@($Others|ForEach-Object {Get-TCProviderValue $_ 'InstallDirectory'});TradingEgressVerified=$false}
}
function Get-TCProviderClientState {
    param($Profile)
    $state=$null;$kind=[string](Get-TCProviderValue $Profile 'Kind')
    if($kind -in @('clashverge','clash-verge')){$state=Get-TCClashVergeState -InstallDirectory (Get-TCProviderValue $Profile 'Directory') -ConfigDirectory (Get-TCProviderValue $Profile 'SettingsDirectory') -SkipRuntime}
    elseif($kind -eq 'batvpn'){$settings=Get-TCProviderValue $Profile 'SettingsDirectory';$path=if($settings){Join-Path $settings 'config.json'}else{Join-Path $env:APPDATA 'BatVPN\config.json'};$state=Get-TCBatVPNState -InstallDirectory $Profile.Directory -ConfigPath $path -SkipRuntime}
    [pscustomobject]@{SystemProxy=(Get-TCProviderValue $state 'SystemProxy');TunMode=(Get-TCProviderValue $state 'Tun');ProxyGuard=(Get-TCProviderValue $state 'ProxyGuard');SnifferReady=(Get-TCProviderValue $state 'SnifferReady' $false);MergePath=(Get-TCProviderValue $state 'MergePath');Notes=@(Get-TCProviderValue $state 'Issues' @());Effective=$false;TradingEgressVerified=$false}
}
function Get-TCSetupBusyPorts { @([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()|ForEach-Object {$_.Port}|Select-Object -Unique) }
function Get-TCProviderSetupPlan {
    param([Parameter(Mandatory=$true)]$Profile,[Alias('Group')][string]$TradeProxy,[AllowNull()]$TradePort,[int[]]$BusyPorts)
    if([string](Get-TCProviderValue $Profile 'Kind') -notin @('clashverge','clash-verge')){throw '该自动设置仅支持 Clash Verge。'}
    $directory=Get-TCProviderSafeDirectory ([string](Get-TCProviderValue $Profile 'Directory')) -MustExist
    $settings=Get-TCProviderSafeDirectory ([string](Get-TCProviderValue $Profile 'SettingsDirectory')) -MustExist
    $state=Get-TCClashVergeState -InstallDirectory $directory -ConfigDirectory $settings -SkipRuntime
    if(-not $state -or -not $state.ConfigFound -or -not $state.DailyPort -or @($state.Issues|Where-Object {$_.Code -eq 'UnsupportedConfig'}).Count){throw '未找到可可靠分析的 clash-verge.yaml，无法自动准备。'}
    $facts=Get-TCClashRuntimeFacts @((Read-TCProviderTextFile (Join-Path $settings 'clash-verge.yaml')) -split '\r?\n')
    $merge=Read-TCClashMerge $state.MergePath;if($merge.Conflicts.Count){throw '已有自定义 sniffer/listeners，未修改；请手动合并。'}
    if(@($facts.Listeners|Where-Object {(Get-TCProviderValue $_ 'name') -ne $script:TCClashListener}).Count){throw '有效配置已有其他监听器，自动覆盖列表会丢失它们；请手动合并。'}
    if(-not $TradeProxy){$TradeProxy=if($merge.Group){$merge.Group}else{$state.DefaultGroup}}
    if(-not $TradeProxy -or $TradeProxy -cnotin $facts.ProxyNames){throw '无法确定有效的备用节点或代理组。'}
    $direct=@($facts.Proxies|Where-Object {(Get-TCProviderValue $_ 'name') -ceq $TradeProxy -and (Get-TCProviderValue $_ 'type') -in @('direct','reject','pass')});if($direct.Count){throw '备用目标不能是直连或拒绝节点。'}
    $busy=if($PSBoundParameters.ContainsKey('BusyPorts')){@($BusyPorts)}else{@(Get-TCSetupBusyPorts)}
    $busy+=@($state.DailyPort,$state.HttpPort,17890,17891)|Where-Object {$_}
    if($merge.Port -and $state.RuntimeListener -and $state.RuntimeListener.Port -eq $merge.Port -and (Test-TCOwnedListener $merge.Port $directory)){$busy=@($busy|Where-Object {$_ -ne $merge.Port})}
    $keep=if($null -ne $TradePort){$TradePort}elseif($merge.Port){$merge.Port}else{Get-TCProviderValue $Profile 'TradePort'}
    if($keep -and $keep -eq $state.DailyPort){$keep=$null}
    if($null -ne $TradePort -and [int]$TradePort -in $busy){throw '指定备用端口已占用或与日常/控制端口冲突。'}
    $port=Select-TCClashTradePort -Busy $busy -Keep $keep;$block=New-TCClashManagedBlock $port $TradeProxy
    $warnings=@('专用端口不证明远端出口；需独立验证当前代理链及实际交易可用性。','域名识别限 HTTP/TLS/QUIC 的可识别流量，无法保证所有应用恢复域名。')
    if($TradeProxy -cin $facts.Groups){$warnings+='固定代理组仍可能选择 DIRECT、REJECT 或自动回退；TradingEgressVerified 保持 false。'}
    if($state.Tun -or $state.SystemProxy -or $state.ProxyGuard){$warnings+='请在维护窗口关闭 Clash TUN/系统代理/代理守卫；此操作不修改这些开关。'}
    $own=($merge.Own -join "`n").TrimEnd("`r","`n");$next=if($own){$own+"`n`n"}else{''};$next+=($block -join "`n")+"`n"
    [pscustomobject]@{MergePath=$state.MergePath;Exists=$merge.Exists;Conflict=$false;AlreadyApplied=($next -ceq $merge.CurrentText);CurrentText=$merge.CurrentText;NextText=$next;Block=$block;TradePort=$port;TradeProxy=$TradeProxy;DailyPort=$state.DailyPort;Warnings=$warnings;TradingEgressVerified=$false;Effective=$false;RuntimeFacts=$facts}
}
function Invoke-TCProviderSetup {
    param([Parameter(Mandatory=$true)]$Profile,[Parameter(Mandatory=$true)][string]$BackupRoot,[Alias('Group')][string]$TradeProxy,[AllowNull()]$TradePort)
    $plan=Get-TCProviderSetupPlan -Profile $Profile -TradeProxy $TradeProxy -TradePort $TradePort
    $result=Set-TCProviderFileTransaction $plan.MergePath $plan.NextText $BackupRoot $plan.CurrentText
    [pscustomobject]@{Changed=$result.Changed;Applied=$true;Effective=$false;RestartRequired=$true;MergePath=$plan.MergePath;BackupPath=$result.BackupPath;TradePort=$plan.TradePort;TradeProxy=$plan.TradeProxy;TradingEgressVerified=$false;Warnings=$plan.Warnings;Friendly='配置已准备并备份；未加载、未重启，当前线路未切换。';NextStep='维护窗口由客户端加载后重新检查；交易出口仍需独立验收。'}
}
function Restore-TCProviderSetup {
    param([Parameter(Mandatory=$true)]$Profile,[Parameter(Mandatory=$true)][string]$BackupPath,[Parameter(Mandatory=$true)][string]$BackupRoot)
    $settings=Get-TCProviderSafeDirectory ([string](Get-TCProviderValue $Profile 'SettingsDirectory')) -MustExist
    Restore-TCProviderFileTransaction (Get-TCClashMergePath $settings) $BackupPath $BackupRoot
}
function Invoke-TCClashPreparation {
    param([Parameter(Mandatory=$true)]$Profile,[Parameter(Mandatory=$true)][string]$BackupRoot,[string]$TradeProxy,[AllowNull()]$TradePort)
    Invoke-TCProviderSetup -Profile $Profile -BackupRoot $BackupRoot -TradeProxy $TradeProxy -TradePort $TradePort
}
function Restore-TCClashPreparation {
    param([Parameter(Mandatory=$true)]$Profile,[Parameter(Mandatory=$true)][string]$BackupRoot,[string]$BackupPath)
    if(-not $BackupPath){
        $path=Get-TCClashMergePath ([string](Get-TCProviderValue $Profile 'SettingsDirectory'))
        $candidates=@(if([IO.Directory]::Exists($BackupRoot)){Get-ChildItem -LiteralPath $BackupRoot -Filter 'clash-merge-*.json' -File|Sort-Object LastWriteTimeUtc -Descending})
        foreach($file in $candidates){try{$receipt=ConvertFrom-Json -InputObject (Read-TCProviderTextFile $file.FullName);if((Get-TCProviderValue $receipt 'Path') -eq $path){$BackupPath=$file.FullName;break}}catch{}}
        if(-not $BackupPath){throw '此客户端没有可恢复的备份。'}
    }
    Restore-TCProviderSetup -Profile $Profile -BackupRoot $BackupRoot -BackupPath $BackupPath
}
# Backward compatible entry points now delegate to the single implementation.
function Get-TCVergeMergePlan {param([Parameter(Mandatory=$true)]$Profile);Get-TCProviderSetupPlan $Profile}
function Set-TCVergeSniffer {param([Parameter(Mandatory=$true)]$Profile,[Parameter(Mandatory=$true)][string]$BackupRoot);Invoke-TCClashPreparation $Profile $BackupRoot}
function Restore-TCVergeMerge {param([Parameter(Mandatory=$true)]$Profile,[Parameter(Mandatory=$true)][string]$BackupPath,[Parameter(Mandatory=$true)][string]$BackupRoot);Restore-TCProviderSetup $Profile $BackupPath $BackupRoot}
function Remove-TCVergeManagedBlock {param([string]$Text);(Split-TCClashMerge @($Text -split '\r?\n')).Own -join "`n"}
function Get-TCVergeSnifferBlock { $lines=New-TCClashManagedBlock 7895 'placeholder';$start=[array]::IndexOf($lines,'sniffer:');$end=[array]::IndexOf($lines,'listeners:');(@($script:TCClashBegin)+@($lines[$start..($end-1)])+@($script:TCClashEnd)) -join "`n" }
function Start-TCClashVerge {param([Parameter(Mandatory=$true)][string]$InstallDirectory);throw '配置模块不启动客户端，请在维护窗口使用客户端自己的界面。'}
function Stop-TCClashVerge {param([Parameter(Mandatory=$true)][string]$InstallDirectory);throw '配置模块不停止客户端，请在维护窗口使用客户端自己的界面。'}
function Wait-TCOwnedListener {param([int[]]$Ports,[string]$Directory,[int]$Seconds=30);foreach($port in $Ports){if(-not (Test-TCOwnedListener $port $Directory)){return $false}};$true}
function Invoke-TCCurlProbe {param([string[]]$Arguments,[int]$TimeoutSeconds=10);[pscustomobject]@{Ok=$false;Body='';Exit=-1;Reason='ExplicitDiagnosticRequired';TradingEgressVerified=$false}}
function Get-TCProbeIP {param([string]$Body);$parsed=$null;if($Body -match '(?m)^ip=([^\r\n]+)' -and [Net.IPAddress]::TryParse($matches[1].Trim(),[ref]$parsed)){$parsed.ToString()}else{$null}}
function Test-TCProviderPorts {
    param([Parameter(Mandatory=$true)][int]$DailyPort,[AllowNull()]$TradePort)
    $null=ConvertTo-TCProviderPort $DailyPort -Required;$null=ConvertTo-TCProviderPort $TradePort
    [pscustomobject]@{DailyPort=$DailyPort;TradePort=$TradePort;DailyIP=$null;SniffOk=$false;DomesticIP=$null;TradeIP=$null;TradeDomesticIP=$null;TradeIsolated=$null;TradingEgressVerified=$false;Reason='ExplicitDiagnosticRequired'}
}
if(-not (Get-Command Get-TCProviderValue -ErrorAction SilentlyContinue)){. (Join-Path $PSScriptRoot 'TradeChannel.Providers.ps1')}
