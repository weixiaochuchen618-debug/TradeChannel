# AI assistant list: which assistant programs and sites follow the trading line.
# The engine reads two local rule-sets and reloads them on change (sing-box 1.10+),
# so switching the lane or editing the list never restarts the engine. In the
# policy these rules come after the provider, trading and global-mode rules: the
# list can never capture BatVPN itself or move a trading connection.
$script:TCAgentRuleSetVersion=3
$script:TCAgentBrowserPattern='(?i)\\(chrome|msedge|firefox|brave|opera|vivaldi|chromium|arc)\.exe$'
$script:TCAgentCustomLimit=32

# App entries route by program and resolve their service domains on the trading
# line. Web entries route only browser traffic to the listed sites.
function Get-TCAgentCatalog {
    @(
        [pscustomobject]@{Id='mirasim';Name='Mirasim';Short='Mirasim';Kind='App';Programs=@('(?i)\\@mirasimdesktop\\');Domains=@('mirasim.ai');Detail='Mirasim 桌面程序。它的助手由 Claude Code 执行，请同时勾选 Claude Code。';Installed=@('%LOCALAPPDATA%\Programs\@mirasimdesktop\Mirasim.exe')}
        [pscustomobject]@{Id='claude-code';Name='Claude Code 与 Claude 桌面版';Short='Claude Code';Kind='App';Programs=@('(?i)\\claude\.exe$','(?i)\\WindowsApps\\Claude_[^\\]+\\');Domains=@('anthropic.com','claude.ai','claude.com');Detail='claude.exe：命令行、Mirasim 调用的助手和桌面版。';Installed=@('%APPDATA%\npm\node_modules\@anthropic-ai\claude-code\bin\claude.exe','%USERPROFILE%\.local\bin\claude.exe');Package='Claude'}
        [pscustomobject]@{Id='codex';Name='Codex 桌面版与命令行';Short='Codex';Kind='App';Programs=@('(?i)\\WindowsApps\\OpenAI\.Codex_[^\\]+\\','(?i)\\OpenAI\\Codex\\','(?i)\\codex\.exe$');Domains=@('openai.com','chatgpt.com','oaistatic.com','oaiusercontent.com');Detail='OpenAI Codex 应用（进程名 ChatGPT.exe）与 codex.exe。';Installed=@('%APPDATA%\npm\node_modules\@openai\codex');Package='OpenAI.Codex'}
        [pscustomobject]@{Id='antigravity';Name='Google Antigravity（反重力）';Short='Antigravity';Kind='App';Programs=@('(?i)\\Antigravity\\');Domains=@('googleapis.com','google.com','gstatic.com','googleusercontent.com','antigravity.google');Detail='安装在名为 Antigravity 的目录中即可识别，包括它的语言服务。';Installed=@('%LOCALAPPDATA%\Programs\Antigravity\Antigravity.exe')}
        # A local relay: when Codex or Claude Code points at it (base_url 127.0.0.1),
        # cc-switch.exe makes the outbound request, not the assistant. Its upstream
        # providers vary, so it carries no fixed domains.
        [pscustomobject]@{Id='cc-switch';Name='CC Switch（接口中转）';Short='CC Switch';Kind='App';Programs=@('(?i)\\cc-switch\.exe$');Domains=@();Detail='Codex 或 Claude Code 经它的本地代理联网时，实际出网的是 cc-switch.exe，需一并打开。';Installed=@('%LOCALAPPDATA%\Programs\CC Switch\cc-switch.exe')}
        [pscustomobject]@{Id='claude-web';Name='Claude 网页版';Short='Claude 网页版';Kind='Web';Programs=@();Domains=@('claude.ai','claude.com','anthropic.com','claudeusercontent.com');Detail='浏览器中的 Claude。';Installed=@()}
        [pscustomobject]@{Id='chatgpt-web';Name='ChatGPT 网页版';Short='ChatGPT 网页版';Kind='Web';Programs=@();Domains=@('chatgpt.com','openai.com','oaistatic.com','oaiusercontent.com');Detail='浏览器中的 ChatGPT。';Installed=@()}
        [pscustomobject]@{Id='gemini-web';Name='Gemini 网页版';Short='Gemini 网页版';Kind='Web';Programs=@();Domains=@('gemini.google.com');Detail='浏览器中的 Gemini。登录与图片等 Google 公共资源随日常上网。';Installed=@()}
    )
}

function ConvertTo-TCAgentSite {
    param([string]$Text)
    $value=([string]$Text).Trim().ToLowerInvariant()
    $value=$value -replace '^[a-z][a-z0-9+.-]*://',''
    $value=($value -split '[/?#]',2)[0]
    if($value -match '^\[|:\d+$'){$value=$value -replace ':\d+$',''}
    $value=$value.TrimStart('*').TrimStart('.').TrimEnd('.')
    $ip=$null
    if([Net.IPAddress]::TryParse($value,[ref]$ip)){throw '请填写网址（域名），不支持 IP 地址。'}
    if($value.Length -gt 253 -or $value -notmatch '^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$'){throw ('网址格式无效：'+$Text)}
    return $value
}

function ConvertTo-TCAgentProgram {
    param([string]$Path)
    $value=([string]$Path).Trim().Trim('"')
    if(-not $value -or -not [IO.Path]::IsPathRooted($value)){throw '请选择程序文件（完整路径）。'}
    try{$full=[IO.Path]::GetFullPath($value)}catch{throw ('程序路径无效：'+$Path)}
    if([IO.Path]::GetExtension($full) -ine '.exe'){throw '只能添加 .exe 程序。'}
    return $full
}

# Normalizes saved preferences. Missing AgentIds means "all built-in entries".
function Get-TCAgentSelection {
    param($Preferences)
    $catalog=@(Get-TCAgentCatalog)
    $lane='Daily'
    if($Preferences -and $Preferences.PSObject.Properties['Agents'] -and [string]$Preferences.Agents -eq 'Trade'){$lane='Trade'}
    $ids=@($catalog|ForEach-Object {$_.Id})
    if($Preferences -and $Preferences.PSObject.Properties['AgentIds'] -and $null -ne $Preferences.AgentIds){
        $wanted=@($Preferences.AgentIds|ForEach-Object {[string]$_})
        $ids=@($catalog|Where-Object {$wanted -contains $_.Id}|ForEach-Object {$_.Id})
    }
    $custom=@()
    if($Preferences -and $Preferences.PSObject.Properties['AgentCustom'] -and $null -ne $Preferences.AgentCustom){
        $seen=@{}
        foreach($item in @($Preferences.AgentCustom)){
            if(-not $item -or $custom.Count -ge $script:TCAgentCustomLimit){continue}
            try{
                $kind=[string]$item.Kind
                $value=if($kind -eq 'Site'){ConvertTo-TCAgentSite ([string]$item.Value)}elseif($kind -eq 'Program'){ConvertTo-TCAgentProgram ([string]$item.Value)}else{$null}
                if($value -and -not $seen.ContainsKey($kind+'|'+$value.ToLowerInvariant())){$seen[$kind+'|'+$value.ToLowerInvariant()]=$true;$custom+=[pscustomobject]@{Kind=$kind;Value=$value}}
            }catch{}
        }
    }
    [pscustomobject]@{Lane=$lane;Ids=$ids;Custom=$custom}
}

function ConvertTo-TCAgentRe2Literal {
    param([string]$Text)
    $builder=New-Object Text.StringBuilder
    foreach($ch in $Text.ToCharArray()){if('\.+*?()|[]{}^$'.IndexOf($ch) -ge 0){$null=$builder.Append('\')};$null=$builder.Append($ch)}
    $builder.ToString()
}

# What the list covers, independent of the lane.
function New-TCAgentSpec {
    param([Parameter(Mandatory=$true)]$Selection)
    $catalog=@(Get-TCAgentCatalog|Where-Object {$Selection.Ids -contains $_.Id})
    $apps=@($catalog|Where-Object {$_.Kind -eq 'App'});$webs=@($catalog|Where-Object {$_.Kind -eq 'Web'})
    $programs=@($Selection.Custom|Where-Object {$_.Kind -eq 'Program'}|ForEach-Object {'(?i)^'+(ConvertTo-TCAgentRe2Literal $_.Value)+'$'})
    $sites=@($Selection.Custom|Where-Object {$_.Kind -eq 'Site'}|ForEach-Object {$_.Value})
    $appPatterns=@(@($apps|ForEach-Object {$_.Programs})+$programs|Where-Object {$_}|Select-Object -Unique)
    $webDomains=@($webs|ForEach-Object {$_.Domains}|Where-Object {$_}|Select-Object -Unique)
    $dns=@(@($apps|ForEach-Object {$_.Domains})+$webDomains+$sites|Where-Object {$_}|Select-Object -Unique)
    [pscustomobject]@{Lane=$Selection.Lane;AppPatterns=$appPatterns;BrowserPattern=$script:TCAgentBrowserPattern;WebDomains=$webDomains;Sites=@($sites|Select-Object -Unique);DnsDomains=$dns}
}

# Rule-set sources. The lane decides whether they are populated: following daily
# traffic leaves both empty, so routing and DNS are exactly the daily behaviour.
function New-TCAgentRuleSets {
    param([Parameter(Mandatory=$true)]$Spec)
    $route=@();$dns=@()
    if($Spec.Lane -eq 'Trade'){
        if($Spec.AppPatterns.Count){$route+=[ordered]@{process_path_regex=@($Spec.AppPatterns)}}
        if($Spec.WebDomains.Count){$route+=[ordered]@{process_path_regex=@($Spec.BrowserPattern);domain_suffix=@($Spec.WebDomains)}}
        if($Spec.Sites.Count){$route+=[ordered]@{domain_suffix=@($Spec.Sites)}}
        if($Spec.DnsDomains.Count){$dns+=[ordered]@{domain_suffix=@($Spec.DnsDomains)}}
    }
    [pscustomobject]@{Route=[ordered]@{version=$script:TCAgentRuleSetVersion;rules=$route};Dns=[ordered]@{version=$script:TCAgentRuleSetVersion;rules=$dns}}
}

function Get-TCAgentPaths {
    param([Parameter(Mandatory=$true)][string]$Root)
    $dir=Join-Path $Root 'agents'
    [pscustomobject]@{Directory=$dir;Route=(Join-Path $dir 'agents-route.json');Dns=(Join-Path $dir 'agents-dns.json');State=(Join-Path $dir 'agents-state.json')}
}

function Write-TCAgentFile {
    param([string]$Path,[string]$Text)
    # The engine reloads on change: write only real changes, and replace atomically.
    if([IO.File]::Exists($Path) -and [IO.File]::ReadAllText($Path) -ceq $Text){return $false}
    $temp=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try{
        [IO.File]::WriteAllText($temp,$Text,(New-Object Text.UTF8Encoding($false)))
        if([IO.File]::Exists($Path)){[IO.File]::Replace($temp,$Path,[NullString]::Value)}else{[IO.File]::Move($temp,$Path)}
    }finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
    return $true
}

function Write-TCAgentRuleSets {
    param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)]$Selection)
    $paths=Get-TCAgentPaths $Root
    $null=[IO.Directory]::CreateDirectory($paths.Directory)
    $spec=New-TCAgentSpec $Selection;$sets=New-TCAgentRuleSets $spec
    # sing-box decodes UTF-8 without a BOM.
    $changed=Write-TCAgentFile $paths.Route ($sets.Route|ConvertTo-Json -Depth 6)
    $changed=(Write-TCAgentFile $paths.Dns ($sets.Dns|ConvertTo-Json -Depth 6)) -or $changed
    # The state records the applied choice even when the rule-sets stay identical
    # (for example, editing the list while it follows daily traffic).
    if($changed -or -not (Test-TCAgentApplied (Read-TCAgentState $Root) $Selection)){
        $state=[ordered]@{Lane=$Selection.Lane;Ids=@($Selection.Ids);Custom=@($Selection.Custom);WrittenAt=(Get-Date).ToString('o')}
        $null=Write-TCAgentFile $paths.State ($state|ConvertTo-Json -Depth 6)
    }
    [pscustomobject]@{Changed=$changed;Spec=$spec;Paths=$paths}
}

function Read-TCAgentState {
    param([Parameter(Mandatory=$true)][string]$Root)
    $path=(Get-TCAgentPaths $Root).State
    if(-not [IO.File]::Exists($path)){return $null}
    try{[IO.File]::ReadAllText($path)|ConvertFrom-Json}catch{$null}
}

# True when the written rule-sets already reflect this selection.
function Test-TCAgentApplied {
    param($State,[Parameter(Mandatory=$true)]$Selection)
    if(-not $State){return $false}
    $key={param($s)(@([string]$s.Lane)+@(@($s.Ids|ForEach-Object {[string]$_})|Sort-Object)+@(@($s.Custom|Where-Object {$_}|ForEach-Object {[string]$_.Kind+'|'+[string]$_.Value})|Sort-Object)) -join "`n"}
    return ((& $key $State) -ceq (& $key $Selection))
}

function Read-TCAgentPreferences {
    param([Parameter(Mandatory=$true)][string]$Root)
    $path=Join-Path $Root 'ui-preferences.json'
    if(-not [IO.File]::Exists($path)){return $null}
    try{[IO.File]::ReadAllText($path,[Text.Encoding]::UTF8)|ConvertFrom-Json}catch{$null}
}

# Called before every engine start: the rule-set files must exist and reflect the
# saved choice. Never blocks a start; an unreadable choice means "follow daily".
function Sync-TCAgentRuleSets {
    param([Parameter(Mandatory=$true)][string]$Root)
    try{Write-TCAgentRuleSets -Root $Root -Selection (Get-TCAgentSelection (Read-TCAgentPreferences $Root))}
    catch{Write-TCAgentRuleSets -Root $Root -Selection ([pscustomobject]@{Lane='Daily';Ids=@();Custom=@()})}
}

function Test-TCAgentHost {
    param([string]$HostName,[string[]]$Suffixes)
    if(-not $HostName){return $false}
    $h=$HostName.ToLowerInvariant().TrimEnd('.')
    foreach($s in @($Suffixes)){if($s -and ($h -eq $s -or $h.EndsWith('.'+$s))){return $true}}
    return $false
}

# Mirrors the rule-set semantics: (app program) or (browser and listed site) or (custom site).
function Test-TCAgentMatch {
    param([Parameter(Mandatory=$true)]$Spec,[string]$ProcessPath,[string]$HostName)
    if($ProcessPath){foreach($pattern in @($Spec.AppPatterns)){if($ProcessPath -match $pattern){return $true}}}
    if($ProcessPath -and $ProcessPath -match $Spec.BrowserPattern -and (Test-TCAgentHost $HostName $Spec.WebDomains)){return $true}
    return (Test-TCAgentHost $HostName $Spec.Sites)
}

# Connections whose path changes with the new list: on the agent rule but no longer
# listed, or on the daily rule but now listed. Every other rule (trading programs,
# trading sites, probes, provider, LAN, global mode) is left alone.
function Get-TCAgentMoves {
    param([object[]]$Connections,[string]$Mode,[Parameter(Mandatory=$true)]$Spec)
    if($Mode -ne 'rule'){return @()}
    @(foreach($c in @($Connections)){
        if(-not $c){continue}
        $rule=[string]$c.rule
        $onAgent=$rule.StartsWith('rule_set=tc-agents ')
        $onDaily=$rule.StartsWith('process_path_regex=.+ ')
        if(-not ($onAgent -or $onDaily)){continue}
        $want=($Spec.Lane -eq 'Trade' -and (Test-TCAgentMatch $Spec ([string]$c.metadata.processPath) ([string]$c.metadata.host)))
        if(($onAgent -and -not $want) -or ($onDaily -and $want)){[string]$c.id}
    })
}

# The list the running engine applies: the state written beside the rule-sets that
# this config watches. Null when the config has no list or it follows daily traffic.
function Get-TCAppliedAgentSpec {
    param([Parameter(Mandatory=$true)]$Config)
    $set=@();if($Config.route -and $Config.route.PSObject.Properties['rule_set']){$set=@($Config.route.rule_set|Where-Object {$_.tag -eq 'tc-agents'})}
    if(-not $set.Count -or -not $set[0].path){return $null}
    $root=Split-Path (Split-Path ([string]$set[0].path) -Parent) -Parent
    if(-not (Get-TCAgentPaths $root).Route.Equals([string]$set[0].path,[StringComparison]::OrdinalIgnoreCase)){return $null}
    $state=Read-TCAgentState $root
    if(-not $state -or [string]$state.Lane -ne 'Trade'){return $null}
    New-TCAgentSpec ([pscustomobject]@{Lane='Trade';Ids=@($state.Ids);Custom=@($state.Custom|Where-Object {$_})})
}

# Connections to reset when the mode changes, so they reconnect on the new path.
# Leaving global mode, an assistant the list keeps on the trading line stays
# connected (an IPv6 one would now be rejected, so it is reset). Entering global
# mode, only daily-lane connections move. Trading connections are never matched.
function Get-TCModeSwitchCloses {
    param([object[]]$Connections,[Parameter(Mandatory=$true)][ValidateSet('rule','global')][string]$Wanted,$Spec)
    $pattern=if($Wanted -eq 'rule'){'^clash_mode=global\b'}else{'^process_path_regex=\.\+ =>'}
    $close=New-Object 'System.Collections.Generic.List[string]';$kept=0
    foreach($c in @($Connections)){
        if(-not $c -or [string]$c.rule -notmatch $pattern){continue}
        if($Wanted -eq 'rule' -and $Spec -and $Spec.Lane -eq 'Trade' -and ([string]$c.metadata.destinationIP) -notmatch ':' -and (Test-TCAgentMatch $Spec ([string]$c.metadata.processPath) ([string]$c.metadata.host))){$kept++;continue}
        $close.Add([string]$c.id)
    }
    [pscustomobject]@{Close=@($close);Kept=$kept}
}

# Read-only presence for the list page: running programs first, then known installs.
function Get-TCAgentPresence {
    $paths=@(Get-Process -ErrorAction SilentlyContinue|ForEach-Object {try{$_.Path}catch{$null}}|Where-Object {$_}|Select-Object -Unique)
    $packages=@()
    try{$packages=@(Get-AppxPackage -ErrorAction Stop|ForEach-Object {$_.Name})}catch{}
    @(foreach($entry in @(Get-TCAgentCatalog|Where-Object {$_.Kind -eq 'App'})){
        $running=$false
        foreach($p in $paths){foreach($pattern in $entry.Programs){if($p -match $pattern){$running=$true;break}};if($running){break}}
        $installed=$running
        if(-not $installed){foreach($candidate in @($entry.Installed)){if($candidate -and (Test-Path -LiteralPath ([Environment]::ExpandEnvironmentVariables($candidate)))){$installed=$true;break}}}
        if(-not $installed -and $entry.PSObject.Properties['Package'] -and $packages -contains $entry.Package){$installed=$true}
        [pscustomobject]@{Id=$entry.Id;State=$(if($running){'Running'}elseif($installed){'Installed'}else{'NotFound'})}
    })
}
