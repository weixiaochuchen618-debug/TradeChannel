#requires -Version 5.1
# AI assistant list: catalog, input checks, matching, rule-set content, connection
# moves, file writes and start-time sync. Only a disposable temp directory is
# written; the bundled engine checks the generated rule-sets offline (no TUN).
$ErrorActionPreference='Stop'
$package=Split-Path $PSScriptRoot -Parent
. (Join-Path $package 'runtime\TradeChannel.Agents.ps1')
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('TC-Agents-'+[guid]::NewGuid().ToString('N'))
$script:Checks=0
function Assert-Agent {param([bool]$Value,[string]$Label)if(-not $Value){throw ('Assistant list regression: '+$Label)};$script:Checks++}
function Reject-Agent {param([scriptblock]$Action,[string]$Label)$failed=$false;try{& $Action|Out-Null}catch{$failed=$true};Assert-Agent $failed $Label}
function Spec {param([string]$Lane,[string[]]$Ids,[object[]]$Custom=@())New-TCAgentSpec ([pscustomobject]@{Lane=$Lane;Ids=@($Ids);Custom=@($Custom)})}
try{
 $null=[IO.Directory]::CreateDirectory($testRoot)
 $catalog=@(Get-TCAgentCatalog);$all=@($catalog|ForEach-Object {$_.Id})
 Assert-Agent ($catalog.Count -eq 22 -and @($all|Select-Object -Unique).Count -eq 22) 'catalog has twenty-two unique entries'
 foreach($id in 'mirasim','claude-code','codex','antigravity','cc-switch','claude-web','chatgpt-web','gemini-web'){Assert-Agent ($all -contains $id) ('catalog entry '+$id)}
 Assert-Agent (@($catalog|Where-Object {$_.Kind -eq 'Web' -and @($_.Programs).Count}).Count -eq 0) 'web entries carry no programs'
 foreach($entry in $catalog){Assert-Agent ($entry.Name -and $entry.Short -and $entry.Detail) ('entry is labelled: '+$entry.Id);foreach($domain in $entry.Domains){Assert-Agent ((ConvertTo-TCAgentSite $domain) -eq $domain) ('catalog domain is canonical: '+$domain)}}

 # Programs: real install shapes on this kind of machine, and things that must never match.
 $spec=Spec 'Trade' $all
 $programs=[ordered]@{
  'C:\Users\u\AppData\Local\Programs\@mirasimdesktop\Mirasim.exe'=$true
  'C:\Users\u\AppData\Roaming\npm\node_modules\@anthropic-ai\claude-code\bin\claude.exe'=$true
  'C:\Users\u\.local\bin\claude.exe'=$true
  'C:\Program Files\WindowsApps\Claude_1.5354.0.0_x64__pzs8sxrjxfjjc\app\claude.exe'=$true
  'C:\Program Files\WindowsApps\Claude_1.5354.0.0_x64__pzs8sxrjxfjjc\app\resources\cowork-svc.exe'=$true
  'C:\Program Files\WindowsApps\OpenAI.Codex_26.928.4866.0_x64__2p2nqsd0c76g0\app\ChatGPT.exe'=$true
  'C:\Users\u\AppData\Local\OpenAI\Codex\runtimes\cua_node\x\bin\codex-computer-use-swift.exe'=$true
  'C:\Users\u\AppData\Roaming\npm\node_modules\@openai\codex\node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\bin\codex.exe'=$true
  'C:\Users\u\AppData\Local\Programs\Antigravity\Antigravity.exe'=$true
  'C:\Users\u\AppData\Local\Programs\Antigravity\resources\app\extensions\antigravity\bin\language_server_windows_x64.exe'=$true
  'C:\Users\u\AppData\Local\Programs\CC Switch\cc-switch.exe'=$true
  'C:\Tools\not-cc-switch.exe'=$false
  'C:\Program Files\NinjaTrader 8\bin\NinjaTrader.exe'=$false
  'C:\Users\u\AppData\Local\Programs\BatVPN\BatVPN.exe'=$false
  'C:\Users\u\AppData\Local\Programs\BatVPN\resources\extra\v2ray-core\Windows\v2ray.exe'=$false
  'C:\Program Files\Google\Chrome\Application\chrome.exe'=$false
  'C:\Users\u\.codex\.sandbox-bin\codex-command-runner-0.133.0.exe'=$false
  'C:\Users\u\.antigravity\extensions\x\node.exe'=$false
  'C:\Program Files\Tencent\Weixin\Weixin.exe'=$false
 }
 foreach($path in $programs.Keys){Assert-Agent ((Test-TCAgentMatch $spec $path '') -eq $programs[$path]) ('program '+[IO.Path]::GetFileName($path)+' listed='+$programs[$path])}

 # Web entries: a browser AND a listed site.
 $chrome='C:\Program Files\Google\Chrome\Application\chrome.exe';$edge='C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
 Assert-Agent (Test-TCAgentMatch $spec $chrome 'chatgpt.com') 'Chrome to chatgpt.com is listed'
 Assert-Agent (Test-TCAgentMatch $spec $edge 'gemini.google.com') 'Edge to Gemini is listed'
 Assert-Agent (Test-TCAgentMatch $spec $chrome 'api.claude.ai') 'subdomains follow the suffix'
 Assert-Agent (-not (Test-TCAgentMatch $spec $chrome 'www.google.com')) 'Gemini entry does not take other Google sites'
 Assert-Agent (-not (Test-TCAgentMatch $spec $chrome 'notchatgpt.com')) 'suffix respects the label boundary'
 Assert-Agent (-not (Test-TCAgentMatch $spec 'C:\Tools\curl.exe' 'chatgpt.com')) 'web entries do not take other programs'
 Assert-Agent (-not (Test-TCAgentMatch $spec $chrome 'www.tradingview.com')) 'trading sites are not on the list'
 $only=Spec 'Trade' @('chatgpt-web')
 Assert-Agent (-not (Test-TCAgentMatch $only 'C:\x\@anthropic-ai\claude-code\bin\claude.exe' 'api.anthropic.com')) 'an unchecked app is not matched'
 Assert-Agent ($only.DnsDomains -contains 'chatgpt.com' -and $only.DnsDomains -contains 'openai.com' -and $only.DnsDomains -contains 'challenges.cloudflare.com' -and $only.DnsDomains -contains 'cdn.workos.com' -and $only.DnsDomains -notcontains 'claude.ai' -and $only.DnsDomains -notcontains 'perplexity.ai') 'trading-line DNS covers checked entries only'

 # User input.
 Assert-Agent ((ConvertTo-TCAgentSite ' https://www.Perplexity.ai/search?q=1 ') -eq 'www.perplexity.ai') 'site input normalized'
 Assert-Agent ((ConvertTo-TCAgentSite '*.example.com') -eq 'example.com') 'wildcard input normalized'
 Assert-Agent ((ConvertTo-TCAgentSite 'example.com:8443') -eq 'example.com') 'port removed'
 Reject-Agent {ConvertTo-TCAgentSite '1.1.1.1'} 'IP address rejected'
 Reject-Agent {ConvertTo-TCAgentSite 'localhost'} 'single label rejected'
 Reject-Agent {ConvertTo-TCAgentSite 'bad_domain.com'} 'invalid characters rejected'
 Reject-Agent {ConvertTo-TCAgentSite ''} 'empty site rejected'
 Assert-Agent ((ConvertTo-TCAgentProgram '"C:\Tools\Agent (x86)\run.exe"') -eq 'C:\Tools\Agent (x86)\run.exe') 'program path kept'
 Reject-Agent {ConvertTo-TCAgentProgram 'run.exe'} 'relative program rejected'
 Reject-Agent {ConvertTo-TCAgentProgram 'C:\Tools\script.ps1'} 'non-exe rejected'
 $custom=Spec 'Trade' @() @([pscustomobject]@{Kind='Program';Value='C:\Tools\Agent (x86)\run.exe'},[pscustomobject]@{Kind='Site';Value='perplexity.ai'})
 Assert-Agent (Test-TCAgentMatch $custom 'c:\tools\agent (x86)\RUN.exe' '') 'custom program matches case-insensitively'
 Assert-Agent (-not (Test-TCAgentMatch $custom 'C:\Tools\Agent (x86)\run.exe.bak' '')) 'custom program matches the exact file'
 Assert-Agent (-not (Test-TCAgentMatch $custom 'C:\Tools\AgentXx86Xrun.exe' '')) 'custom program path is a literal, not a pattern'
 Assert-Agent (Test-TCAgentMatch $custom 'C:\Tools\curl.exe' 'www.perplexity.ai') 'custom site applies to any program'

 # Saved preferences.
 $sel=Get-TCAgentSelection $null
 Assert-Agent ($sel.Lane -eq 'Daily' -and $sel.Ids.Count -eq 22 -and $sel.Custom.Count -eq 0) 'no preference: follow daily traffic, every entry checked'
 $sel=Get-TCAgentSelection ([pscustomobject]@{Agents='Trade';AgentIds=@('codex','unknown','mirasim');AgentCustom=@([pscustomobject]@{Kind='Site';Value='Example.com'},[pscustomobject]@{Kind='Site';Value='example.com'},[pscustomobject]@{Kind='Other';Value='x'},[pscustomobject]@{Kind='Site';Value='1.2.3.4'})})
 Assert-Agent ($sel.Lane -eq 'Trade' -and ($sel.Ids -join ',') -eq 'mirasim,codex' -and $sel.Custom.Count -eq 1 -and $sel.Custom[0].Value -eq 'example.com') 'unknown ids, duplicates and invalid items dropped; catalog order kept'
 Assert-Agent ((Get-TCAgentSelection ([pscustomobject]@{Agents='Trade';AgentIds=@()})).Ids.Count -eq 0) 'an explicitly empty list stays empty'
 Assert-Agent ((Get-TCAgentSelection ([pscustomobject]@{Agents='Sideways'})).Lane -eq 'Daily') 'an unknown lane follows daily traffic'

 # Rule-set content.
 $trade=New-TCAgentRuleSets $spec
 Assert-Agent ($trade.Route.version -eq 3 -and @($trade.Route.rules).Count -eq 3 -and @($trade.Dns.rules).Count -eq 1) 'trading lane: program, browser and service rules plus DNS'
 $web=@($trade.Route.rules|Where-Object {$_.Contains('domain_suffix') -and $_.Contains('process_path_regex')})
 Assert-Agent ($web.Count -eq 1 -and $web[0].Contains('process_path_regex') -and (@($web[0].process_path_regex) -join '') -eq $script:TCAgentBrowserPattern) 'listed sites are limited to browsers'
 $daily=New-TCAgentRuleSets (Spec 'Daily' $all)
 Assert-Agent (@($daily.Route.rules).Count -eq 0 -and @($daily.Dns.rules).Count -eq 0) 'following daily traffic leaves both rule-sets empty'

 # Connection moves after a change.
 $conns=@(
  [pscustomobject]@{id='a1';rule='process_path_regex=.+ => route(daily-exit)';metadata=[pscustomobject]@{processPath='C:\x\npm\node_modules\@anthropic-ai\claude-code\bin\claude.exe';host='api.anthropic.com'}}
  [pscustomobject]@{id='a2';rule='rule_set=tc-agents => route(trade-exit)';metadata=[pscustomobject]@{processPath='C:\Users\u\AppData\Local\Programs\@mirasimdesktop\Mirasim.exe';host='mirasim.ai'}}
  [pscustomobject]@{id='t1';rule='process_path=C:\Program Files\NinjaTrader 8\bin\NinjaTrader.exe => route(trade-exit)';metadata=[pscustomobject]@{processPath='C:\Program Files\NinjaTrader 8\bin\NinjaTrader.exe';host='tradovateapi.com'}}
  [pscustomobject]@{id='t2';rule='domain_suffix=[tradingview.com] => route(trade-exit)';metadata=[pscustomobject]@{processPath=$chrome;host='tradingview.com'}}
  [pscustomobject]@{id='d1';rule='process_path_regex=.+ => route(daily-exit)';metadata=[pscustomobject]@{processPath=$chrome;host='www.bing.com'}}
  [pscustomobject]@{id='g1';rule='clash_mode=global => route(trade-exit)';metadata=[pscustomobject]@{processPath=$chrome;host='chatgpt.com'}}
 )
 Assert-Agent ((@(Get-TCAgentMoves $conns 'rule' (Spec 'Trade' @('claude-code','mirasim'))) -join ',') -eq 'a1') 'to the trading line: only listed daily connections move'
 Assert-Agent ((@(Get-TCAgentMoves $conns 'rule' (Spec 'Daily' @('claude-code','mirasim'))) -join ',') -eq 'a2') 'back to daily: only assistant-rule connections move'
 Assert-Agent ((@(Get-TCAgentMoves $conns 'rule' (Spec 'Trade' @('claude-code'))) -join ',') -eq 'a1,a2') 'checking and unchecking entries move exactly those connections'
 Assert-Agent (@(Get-TCAgentMoves $conns 'global' (Spec 'Daily' @())).Count -eq 0) 'global mode moves nothing'
 foreach($case in @((Spec 'Trade' $all),(Spec 'Daily' $all),(Spec 'Trade' @()))){$moved=@(Get-TCAgentMoves $conns 'rule' $case);Assert-Agent (-not ($moved -contains 't1' -or $moved -contains 't2' -or $moved -contains 'g1')) 'trading and global-mode connections never move'}

 # Mode switches: leaving global mode, listed assistants stay connected on the trading line.
 $claude='C:\x\npm\node_modules\@anthropic-ai\claude-code\bin\claude.exe'
 $mc=@(
  [pscustomobject]@{id='m1';rule='clash_mode=global => route(trade-exit)';metadata=[pscustomobject]@{processPath=$claude;host='api.anthropic.com';destinationIP='160.79.104.10'}}
  [pscustomobject]@{id='m2';rule='clash_mode=global => route(trade-exit)';metadata=[pscustomobject]@{processPath=$chrome;host='www.bing.com';destinationIP='13.107.21.200'}}
  [pscustomobject]@{id='m3';rule='clash_mode=global => route(trade-exit)';metadata=[pscustomobject]@{processPath=$claude;host='api.anthropic.com';destinationIP='2607:6bc0::10'}}
  [pscustomobject]@{id='m4';rule='process_path=C:\Program Files\NinjaTrader 8\bin\NinjaTrader.exe => route(trade-exit)';metadata=[pscustomobject]@{processPath='C:\Program Files\NinjaTrader 8\bin\NinjaTrader.exe';host='tradovateapi.com';destinationIP='192.0.2.10'}}
  [pscustomobject]@{id='m5';rule='clash_mode=global => route(trade-exit)';metadata=[pscustomobject]@{processPath=$chrome;host='chatgpt.com';destinationIP='192.0.2.20'}}
  [pscustomobject]@{id='m6';rule='process_path_regex=.+ => route(daily-exit)';metadata=[pscustomobject]@{processPath=$chrome;host='www.bing.com';destinationIP='13.107.21.200'}}
  [pscustomobject]@{id='m7';rule='rule_set=tc-agents => route(trade-exit)';metadata=[pscustomobject]@{processPath=$claude;host='api.anthropic.com';destinationIP='160.79.104.10'}}
 )
 $plan=Get-TCModeSwitchCloses $mc 'rule' (Spec 'Trade' $all)
 Assert-Agent ((@($plan.Close) -join ',') -eq 'm2,m3' -and $plan.Kept -eq 2) 'leaving global mode keeps listed assistant connections; daily and IPv6 ones reconnect'
 Assert-Agent ((@((Get-TCModeSwitchCloses $mc 'rule' (Spec 'Daily' $all)).Close) -join ',') -eq 'm1,m2,m3,m5') 'a list that follows daily traffic keeps nothing'
 Assert-Agent ((@((Get-TCModeSwitchCloses $mc 'rule' $null).Close) -join ',') -eq 'm1,m2,m3,m5') 'without an applied list every global-mode connection reconnects'
 $plan=Get-TCModeSwitchCloses $mc 'global' (Spec 'Trade' $all)
 Assert-Agent ((@($plan.Close) -join ',') -eq 'm6' -and $plan.Kept -eq 0) 'entering global mode moves only daily-lane connections'

 # Files the engine watches.
 $root=Join-Path $testRoot 'state';$paths=Get-TCAgentPaths $root
 $w=Write-TCAgentRuleSets -Root $root -Selection ([pscustomobject]@{Lane='Trade';Ids=@('codex');Custom=@()})
 Assert-Agent ($w.Changed -and [IO.File]::Exists($paths.Route) -and [IO.File]::Exists($paths.Dns) -and [IO.File]::Exists($paths.State)) 'first write creates both rule-sets and the state'
 $bytes=[IO.File]::ReadAllBytes($paths.Route);Assert-Agent (-not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB)) 'rule-sets are written without a BOM'
 $stamp=[IO.File]::GetLastWriteTimeUtc($paths.Route);Start-Sleep -Milliseconds 30
 $w=Write-TCAgentRuleSets -Root $root -Selection ([pscustomobject]@{Lane='Trade';Ids=@('codex');Custom=@()})
 Assert-Agent (-not $w.Changed -and [IO.File]::GetLastWriteTimeUtc($paths.Route) -eq $stamp) 'an unchanged choice never touches the watched files'
 $w=Write-TCAgentRuleSets -Root $root -Selection ([pscustomobject]@{Lane='Daily';Ids=@('codex','mirasim');Custom=@()})
 $state=Read-TCAgentState $root
 Assert-Agent ($w.Changed -and $state.Lane -eq 'Daily' -and (@($state.Ids) -join ',') -eq 'codex,mirasim') 'the state records the applied choice'
 $w=Write-TCAgentRuleSets -Root $root -Selection ([pscustomobject]@{Lane='Daily';Ids=@('codex');Custom=@()})
 Assert-Agent (-not $w.Changed -and (@((Read-TCAgentState $root).Ids) -join ',') -eq 'codex') 'list edits while following daily traffic update the state without a reload'
 Assert-Agent (Test-TCAgentApplied (Read-TCAgentState $root) ([pscustomobject]@{Lane='Daily';Ids=@('codex');Custom=@()})) 'applied state compares equal'
 Assert-Agent (-not (Test-TCAgentApplied (Read-TCAgentState $root) ([pscustomobject]@{Lane='Trade';Ids=@('codex');Custom=@()}))) 'a lane change is detected'
 Assert-Agent (-not (Test-TCAgentApplied $null ([pscustomobject]@{Lane='Daily';Ids=@();Custom=@()}))) 'a missing state is never treated as applied'
 Assert-Agent (@(Get-ChildItem -LiteralPath (Split-Path $paths.Route -Parent) -Filter '*.tmp').Count -eq 0) 'no temporary files remain'

 # A mode switch reads the applied list from the state beside the files its config watches.
 $cfgFor={param($path)[pscustomobject]@{route=[pscustomobject]@{rule_set=@([pscustomobject]@{tag='tc-agents';path=$path})}}}
 $null=Write-TCAgentRuleSets -Root $root -Selection ([pscustomobject]@{Lane='Trade';Ids=@('claude-code');Custom=@()})
 $applied=Get-TCAppliedAgentSpec (& $cfgFor $paths.Route)
 Assert-Agent ($applied -and $applied.Lane -eq 'Trade' -and (Test-TCAgentMatch $applied $claude '') -and -not (Test-TCAgentMatch $applied $chrome 'chatgpt.com')) 'the applied list is read from the state the config watches'
 Assert-Agent ($null -eq (Get-TCAppliedAgentSpec (& $cfgFor (Join-Path $testRoot 'elsewhere\agents\other.json')))) 'a config watching other files gets no list'
 Assert-Agent ($null -eq (Get-TCAppliedAgentSpec ([pscustomobject]@{route=[pscustomobject]@{rules=@()}}))) 'a config without a list gets none'
 $null=Write-TCAgentRuleSets -Root $root -Selection ([pscustomobject]@{Lane='Daily';Ids=@('claude-code');Custom=@()})
 Assert-Agent ($null -eq (Get-TCAppliedAgentSpec (& $cfgFor $paths.Route))) 'a list that follows daily traffic keeps no connection'

 # Before an engine start the saved choice is written; unreadable input means "follow daily".
 [IO.File]::WriteAllText((Join-Path $root 'ui-preferences.json'),'{"Mode":"Trading","Agents":"Trade","AgentIds":["gemini-web"],"AgentCustom":[{"Kind":"Site","Value":"perplexity.ai"}]}',(New-Object Text.UTF8Encoding($true)))
 $null=Sync-TCAgentRuleSets -Root $root
 $route=[IO.File]::ReadAllText($paths.Route)|ConvertFrom-Json
 Assert-Agent (@($route.rules).Count -eq 2 -and @($route.rules[0].domain_suffix) -contains 'gemini.google.com' -and @($route.rules[0].domain_suffix) -contains 'accounts.google.com' -and (@($route.rules[1].domain_suffix) -join ',') -eq 'perplexity.ai') 'start-time sync writes the saved choice'
 [IO.File]::WriteAllText((Join-Path $root 'ui-preferences.json'),'{ not json',(New-Object Text.UTF8Encoding($true)))
 $null=Sync-TCAgentRuleSets -Root $root
 Assert-Agent (@(([IO.File]::ReadAllText($paths.Route)|ConvertFrom-Json).rules).Count -eq 0) 'unreadable preferences fall back to following daily traffic'

 # The bundled engine accepts the full list (offline check: no TUN, no listener, no network).
 $null=Write-TCAgentRuleSets -Root $root -Selection ([pscustomobject]@{Lane='Trade';Ids=$all;Custom=@([pscustomobject]@{Kind='Program';Value='C:\Tools\Agent (x86)\run.exe'},[pscustomobject]@{Kind='Site';Value='perplexity.ai'})})
 $config=[ordered]@{
  log=@{level='warn'}
  dns=[ordered]@{servers=@(@{type='local';tag='dns-local'},@{type='local';tag='dns-trade'});rules=@(@{rule_set=@('tc-agents-dns');action='route';server='dns-trade'});final='dns-local'}
  inbounds=@(@{type='mixed';tag='in';listen='127.0.0.1';listen_port=17999})
  outbounds=@(@{type='direct';tag='direct'},@{type='direct';tag='trade-exit'})
  route=[ordered]@{rule_set=@(@{type='local';tag='tc-agents';format='source';path=$paths.Route},@{type='local';tag='tc-agents-dns';format='source';path=$paths.Dns});rules=@(@{rule_set=@('tc-agents');ip_version=6;action='reject'},@{rule_set=@('tc-agents');action='route';outbound='trade-exit'});final='direct';auto_detect_interface=$false;default_domain_resolver=@{server='dns-local'}}
 }
 $checkPath=Join-Path $testRoot 'check.json';[IO.File]::WriteAllText($checkPath,($config|ConvertTo-Json -Depth 10),(New-Object Text.UTF8Encoding($false)))
 $previous=$ErrorActionPreference;$ErrorActionPreference='Continue'
 try{$out=& (Join-Path $package 'assets\sing-box.exe') check -c $checkPath 2>&1;$code=$LASTEXITCODE}finally{$ErrorActionPreference=$previous}
 Assert-Agent ($code -eq 0) ('bundled engine accepts the full list '+(($out|Out-String).Trim()))
 [pscustomobject]@{Passed=$true;Checks=$script:Checks;Scope='Catalog, input checks, matching, rule-sets, connection moves, mode switches, watched files, start-time sync, offline engine check';RealNetworkChanges=0}
}finally{
 $full=[IO.Path]::GetFullPath($testRoot);$temporary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if(-not $full.StartsWith($temporary,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notlike 'TC-Agents-*'){throw 'Fixture cleanup path rejected'}
 if(Test-Path -LiteralPath $full){Remove-Item -LiteralPath $full -Recurse -Force}
}
