#requires -Version 5.1
$ErrorActionPreference='Stop'
$script:Root=Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'TradeChannel'
$script:Package=$PSScriptRoot
$script:IsolatedReadContext=$false
$script:IsolatedBootAt=$null
Import-Module (Join-Path $PSScriptRoot 'Version.psm1') -DisableNameChecking
$script:WizardVersion=Get-TCProductVersion -PackageRoot $PSScriptRoot
# Read-only provider checks (netstat based in short-lived workers; no compile cost).
. (Join-Path $PSScriptRoot 'runtime\TradeChannel.Provider.ps1')
# AI assistant list: catalog, saved choice and the rule-set files the engine watches.
. (Join-Path $PSScriptRoot 'runtime\TradeChannel.Agents.ps1')

# Explicit CLI-only fixture boundary. Normal callers retain real OS evidence.
# This adapter accepts no scriptblocks or JSON-provided execution callbacks.
function Initialize-TCIsolatedReadContext {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root)
    $full=[IO.Path]::GetFullPath($Root).TrimEnd('\')
    $prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not ($full+'\').StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -cnotmatch '^TradeChannel-worker-fixture-[a-f0-9]{32}$' -or -not [IO.Directory]::Exists($full)){throw '隔离只读上下文仅接受已存在的可信临时验证目录。'}
    $cursor=$full
    while($cursor){$item=Get-Item -LiteralPath $cursor -Force -ErrorAction Stop;if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw '隔离只读目录不能经过重解析点。'};$parent=[IO.Path]::GetDirectoryName($cursor);if($parent -eq $cursor){break};$cursor=$parent}
    $script:Root=$full;$script:IsolatedReadContext=$true;$script:IsolatedBootAt=[DateTime]::UtcNow.AddHours(-1)
    [pscustomobject]@{Initialized=$true;Root=$full;EvidenceSource='IsolatedFixture';ControllerAllowed=$false;NetworkChanged=$false}
}
function Test-TCNinjaRunning {
    if($script:IsolatedReadContext){return $false}
    [bool](Get-Process -Name NinjaTrader -ErrorAction SilentlyContinue)
}
function Assert-TCIsolatedReadPath {
    param([string]$Path)
    if(-not $script:IsolatedReadContext){return}
    $full=[IO.Path]::GetFullPath($Path);$prefix=$script:Root.TrimEnd('\')+'\'
    if(-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw '隔离只读上下文禁止读取临时数据根之外的部署资料。'}
    $cursor=$full;while($cursor){if(Test-Path -LiteralPath $cursor){$item=Get-Item -LiteralPath $cursor -Force;if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw '隔离只读资料不能经过重解析点。'}};$parent=[IO.Path]::GetDirectoryName($cursor);if($parent -eq $cursor){break};$cursor=$parent}
}
function Assert-TCRealRuntimeContext {
    if($script:IsolatedReadContext){throw '隔离只读上下文禁止修改保护或运行会话。'}
}

function Get-TCProductPaths {
    [pscustomobject]@{Root=$script:Root;StoreRoot=(Join-Path $script:Root 'Product');Runtime=(Join-Path $script:Package 'runtime');Engine=(Join-Path $script:Package 'assets\sing-box.exe');Wg=(Join-Path $script:Package 'assets\wg.exe')}
}
function Get-TCRuntimeSnapshot {
    $path=Join-Path $script:Root 'runtime.json'
    Assert-TCIsolatedReadPath $path
    if(-not(Test-Path -LiteralPath $path)){return $null}
    . (Join-Path $script:Package 'runtime\TradeChannel.State.ps1')
    $snapshot=Read-TradeChannelState -Path $path
    # Legacy records have no engine birth timestamp. File time bounds that
    # engine's creation: a later process reusing the PID cannot own this record.
    $snapshot|Add-Member -NotePropertyName RecordWrittenAt -NotePropertyValue ([IO.File]::GetLastWriteTimeUtc($path).ToString('o')) -Force
    $snapshot
}
function Get-TCInstalledDeployment {
    $path=Join-Path $script:Root 'deployment.json'
    Assert-TCIsolatedReadPath $path
    if(-not(Test-Path -LiteralPath $path)){return $null}
    $d=Get-Content -LiteralPath $path -Encoding UTF8 -Raw|ConvertFrom-Json
    if($script:IsolatedReadContext){Assert-TCIsolatedReadPath $d.ManifestPath}
    if(-not (Test-Path -LiteralPath $d.ManifestPath)){throw '当前部署记录存在，但配置文件丢失。请使用备份恢复或重新导入节点。'}
    $d
}
function Get-TCClientInspection {
    if($script:IsolatedReadContext){return [pscustomobject]@{OS='Windows isolated fixture';IsServer=$false;Elevated=$true;NinjaTraderPaths=@();NinjaTraderRunning=$false;DirectDnsIPv4=@('192.0.2.53');LocalIPv4Addresses=@();LocalRoutes=@();Provider=$null;ProviderCandidates=@();RegisteredProviders=@();EngineStaged=[IO.File]::Exists((Join-Path $script:Package 'assets\sing-box.exe'));WgHelperStaged=[IO.File]::Exists((Join-Path $script:Package 'assets\wg.exe'));ExistingDeployment=[bool](Get-TCInstalledDeployment);WGServices=@();ControlPortBusy=$false;WizardVersion=$script:WizardVersion;EvidenceSource='IsolatedFixture'}}
    $os=Get-CimInstance Win32_OperatingSystem
    $principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $applications=@()
    foreach($base in @($env:ProgramFiles,${env:ProgramFiles(x86)})){
        if($base){$p=Join-Path $base 'NinjaTrader 8\bin\NinjaTrader.exe';if(Test-Path -LiteralPath $p){$applications+=$p}}
    }
    $physical=@(Get-NetAdapter|Where-Object {$_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'WireGuard|Wintun|sing-tun|VMware|Hyper-V|Bluetooth'})
    $dns=@();foreach($adapter in $physical){$dns+=@(Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4|Select-Object -ExpandProperty ServerAddresses)}
    $candidates=@(Find-TCProviderCandidates|Select-Object Kind,Name,Directory,ProgramPaths,DailyPort,TradePort,Detected,Ready,Issues)
    $provider=$null
    $prefs=Get-TCPreferences
    $records=@((Read-TCProviderStore (Join-Path $script:Root 'Product')).Providers)
    $chosen=@($records|Where-Object {$_.id -eq $prefs.ProviderId})
    if(-not $chosen.Count -and $records.Count){$chosen=@($records[0])}
    if($chosen.Count){
        $r=$chosen[0]
        $provider=[pscustomobject]@{Id=$r.id;Kind=$r.kind;Name=$r.name;SocksPort=$r.dailyPort;TradePort=$r.tradePort;HttpPort=$r.httpPort;PacPort=$r.pacPort;Directory=$r.directory;ProgramPaths=@($r.programPaths);BootstrapDomains=@($r.bootstrapDomains)}
    }
    $ports=@([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()|Select-Object -ExpandProperty Port|Sort-Object -Unique)
    $paths=Get-TCProductPaths
    [pscustomobject]@{OS=$os.Caption;IsServer=($os.ProductType -ne 1);Elevated=$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator);NinjaTraderPaths=@($applications|Sort-Object -Unique);NinjaTraderRunning=[bool](Get-Process -Name NinjaTrader -ErrorAction SilentlyContinue);DirectDnsIPv4=@($dns|Where-Object {$_ -notmatch '^(127\.|172\.30\.250\.)'}|Select-Object -Unique -First 1);Provider=$provider;ProviderCandidates=$candidates;RegisteredProviders=$records;EngineStaged=(Test-Path -LiteralPath $paths.Engine);WgHelperStaged=(Test-Path -LiteralPath $paths.Wg);ExistingDeployment=[bool](Get-TCInstalledDeployment);WGServices=@(Get-Service -Name 'WireGuardTunnel*' -ErrorAction SilentlyContinue|Select-Object Name,@{n='Status';e={$_.Status.ToString()}});ControlPortBusy=($ports -contains 17891);WizardVersion=$script:WizardVersion}
}
function Invoke-TCController {
    param($Manifest,[string]$Path,[string]$Method='GET',$Body=$null)
    if($script:IsolatedReadContext){throw '隔离只读上下文禁止访问实际控制器。'}
    $cfg=Get-Content -LiteralPath $Manifest.CandidatePath -Encoding UTF8 -Raw|ConvertFrom-Json
    $api=$cfg.experimental.clash_api
    if($api.external_controller -notmatch '^127\.0\.0\.1:\d+$' -or -not $api.secret){throw '控制接口必须仅监听本机并启用认证。'}
    Add-Type -AssemblyName System.Net.Http
    $handler=New-Object Net.Http.HttpClientHandler;$handler.UseProxy=$false
    $client=New-Object Net.Http.HttpClient($handler);$client.Timeout=[TimeSpan]::FromSeconds(6)
    $client.DefaultRequestHeaders.Authorization=New-Object Net.Http.Headers.AuthenticationHeaderValue('Bearer',[string]$api.secret)
    $request=New-Object Net.Http.HttpRequestMessage((New-Object Net.Http.HttpMethod($Method)),('http://'+$api.external_controller+$Path))
    if($null -ne $Body){$request.Content=New-Object Net.Http.StringContent(($Body|ConvertTo-Json -Depth 8 -Compress),[Text.Encoding]::UTF8,'application/json')}
    try{$response=$client.SendAsync($request).GetAwaiter().GetResult();try{$null=$response.EnsureSuccessStatusCode();$text=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult();if($text){$text|ConvertFrom-Json}}finally{$response.Dispose()}}finally{$request.Dispose();$client.Dispose();$handler.Dispose();$cfg=$null;$api=$null}
}
# Preferences are deliberately outside the restricted NodeStore. They are intent,
# never a request to start/reconfigure a session. Startup.psm1 owns login tasks.
function Get-TCPreferences {
    $value=$null;$path=Join-Path $script:Root 'ui-preferences.json'
    Assert-TCIsolatedReadPath $path
    if(Test-Path -LiteralPath $path){
        try{$value=Get-Content -LiteralPath $path -Encoding UTF8 -Raw|ConvertFrom-Json}catch{throw '连接偏好文件无法读取；未重置保存的选择。'}
    }
    $agents=Get-TCAgentSelection $value
    [pscustomobject]@{Mode=$(if($value.Mode -in @('Trading','Global')){$value.Mode}else{'Trading'});Exit=$(if($value.Exit -in @('HongKong','Provider')){$value.Exit}else{'HongKong'});Daily=$(if($value.Daily -in @('Direct','Provider')){$value.Daily}else{'Direct'});NodeId=$(if($value.NodeId){[string]$value.NodeId}else{$null});ProfileId=$(if($value.ProfileId -in @('Udp','Tcp')){[string]$value.ProfileId}else{$null});ProviderId=[string]$value.ProviderId;TradeProviderId=[string]$value.TradeProviderId;Agents=$agents.Lane;AgentIds=@($agents.Ids);AgentCustom=@($agents.Custom);OpenAtLogin=$false;ManualConnect=$true}
}
function Write-TCSessionText {
    param([string]$Path,[string]$Text)
    $temp=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try{
        [IO.File]::WriteAllText($temp,$Text,(New-Object Text.UTF8Encoding($true)))
        if([IO.File]::Exists($Path)){[IO.File]::Replace($temp,$Path,[NullString]::Value)}else{[IO.File]::Move($temp,$Path)}
    }finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
}
function Write-TCSessionJson {
    param([string]$Path,$Value)
    Write-TCSessionText $Path ($Value|ConvertTo-Json -Depth 14)
}
function Open-TCSessionLock {
    param([string]$Name='session')
    $null=[IO.Directory]::CreateDirectory($script:Root)
    try{[IO.File]::Open((Join-Path $script:Root ('.'+$Name+'.lock')),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}
    catch{throw '连接操作正在进行，请等待完成后再操作。'}
}
function Save-TCPreferences {
    [CmdletBinding()]
    param([ValidateSet('Trading','Global')][string]$Mode,[ValidateSet('HongKong','Provider')][string]$Exit,[ValidateSet('Direct','Provider')][string]$Daily,[AllowNull()][AllowEmptyString()][string]$NodeId,[ValidateSet('Daily','Trade')][string]$Agents,[AllowNull()][AllowEmptyCollection()][string[]]$AgentIds,[AllowNull()][AllowEmptyCollection()][object[]]$AgentCustom,[AllowNull()][AllowEmptyString()][string]$ProviderId,[AllowNull()][AllowEmptyString()][string]$TradeProviderId,[AllowNull()][AllowEmptyString()][ValidateScript({-not $_ -or $_ -in @('Udp','Tcp')})][string]$ProfileId)
    if($NodeId){$guid=[guid]::Empty;if(-not [guid]::TryParse($NodeId,[ref]$guid)){throw '节点 ID 无效。'}}
    foreach($id in @($ProviderId,$TradeProviderId)){if($id){$guid=[guid]::Empty;if(-not [guid]::TryParse($id,[ref]$guid)){throw '服务商 ID 无效。'}}}
    $custom=$null
    if($PSBoundParameters.ContainsKey('AgentCustom')){
        # User-entered items are validated here; the saved file only holds clean values.
        $items=@($AgentCustom|Where-Object {$_})
        if($items.Count -gt $script:TCAgentCustomLimit){throw ('自定义项最多 '+$script:TCAgentCustomLimit+' 个。')}
        $custom=@(foreach($item in $items){
            switch([string]$item.Kind){'Site'{[pscustomobject]@{Kind='Site';Value=(ConvertTo-TCAgentSite ([string]$item.Value))}}'Program'{[pscustomobject]@{Kind='Program';Value=(ConvertTo-TCAgentProgram ([string]$item.Value))}}default{throw '不支持的自定义项。'}}
        })
    }
    $lock=Open-TCSessionLock -Name 'preferences'
    try{
        $p=Get-TCPreferences
        foreach($key in @('Mode','Exit','Daily','NodeId','Agents','ProviderId','TradeProviderId','ProfileId')){if($PSBoundParameters.ContainsKey($key)){$p.$key=$PSBoundParameters[$key]}}
        if(-not $p.NodeId){$p.NodeId=$null}
        if($PSBoundParameters.ContainsKey('AgentIds')){$p.AgentIds=@((Get-TCAgentSelection ([pscustomobject]@{AgentIds=@($AgentIds|Where-Object {$_})})).Ids)}
        if($null -ne $custom){$p.AgentCustom=@((Get-TCAgentSelection ([pscustomobject]@{AgentIds=@();AgentCustom=$custom})).Custom)}
        # The supervisor reads Daily as the user's intent for daily traffic, and the
        # assistant fields when it writes the rule-sets before an engine start.
        Write-TCSessionJson (Join-Path $script:Root 'ui-preferences.json') ([ordered]@{Mode=$p.Mode;Exit=$p.Exit;Daily=$p.Daily;NodeId=$p.NodeId;ProfileId=$p.ProfileId;ProviderId=$p.ProviderId;TradeProviderId=$p.TradeProviderId;Agents=$p.Agents;AgentIds=@($p.AgentIds);AgentCustom=@($p.AgentCustom)})
        $p
    }finally{$lock.Dispose()}
}
function Get-TCRegisteredNodes {
    $path=Join-Path $script:Root 'Product\index.json'
    Assert-TCIsolatedReadPath $path
    if(Test-Path -LiteralPath $path){
        try{@((Get-Content -LiteralPath $path -Encoding UTF8 -Raw|ConvertFrom-Json).nodes)}catch{throw '节点列表无法读取。'}
    }
}
function Test-TCSamePath {
    param($Left,$Right)
    if(-not $Left -or -not $Right){return $false}
    try{return [IO.Path]::GetFullPath([string]$Left).Equals([IO.Path]::GetFullPath([string]$Right),[StringComparison]::OrdinalIgnoreCase)}catch{return $false}
}
function Get-TCCommandArgument {
    param([string]$CommandLine,[string]$Name)
    $match=[regex]::Match($CommandLine,('(?i)(?:^|\s)(?:'+$Name+')\s+(?:"([^"]+)"|(\S+))'))
    if($match.Success){if($match.Groups[1].Success){$match.Groups[1].Value}else{$match.Groups[2].Value}}
}
function Get-TCPowerShellFileArgument {
    param([string]$CommandLine)
    # Read host arguments only. A -Command payload (quoted or unquoted) may
    # contain arbitrary -File text, including strings that are invalid paths.
    $arguments=[regex]::Matches($CommandLine,'(?:"[^"]*"|[^\s"]+)+')
    for($index=1;$index -lt $arguments.Count;$index++){
        $argument=$arguments[$index].Value.Trim('"')
        if($argument -eq '-File'){
            if($index+1 -lt $arguments.Count){return $arguments[$index+1].Value.Trim('"')}
            return
        }
        if($argument.StartsWith('-')){
            $option=$argument.Substring(1)
            if($option -and ('Command'.StartsWith($option,[StringComparison]::OrdinalIgnoreCase) -or 'CommandWithArgs'.StartsWith($option,[StringComparison]::OrdinalIgnoreCase) -or 'EncodedCommand'.StartsWith($option,[StringComparison]::OrdinalIgnoreCase) -or $option -eq 'ec')){return}
        }
    }
}
function ConvertTo-TCUtc {
    param($Value)
    if($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)){return $null}
    try{([DateTimeOffset]$Value).UtcDateTime}catch{return $null}
}
function Get-TCBootTime { if($script:IsolatedReadContext){return $script:IsolatedBootAt};(Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime }
function Get-TCProcessInventory {
    param($Manifest)
    if($script:IsolatedReadContext){return @()}
    # Include old tools/Run-TradeChannel.ps1 supervisors and engines whose state
    # record was lost. A failed read is never converted to an empty inventory.
    @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
        $_.Name -in @('powershell.exe','pwsh.exe','sing-box.exe') -or ($Manifest -and (Test-TCSamePath $_.ExecutablePath $Manifest.EnginePath))
    })
}
function Get-TCRuntimeIdentity {
    param($Deployment,$Manifest,$Snapshot,[object[]]$Processes,$BootTime)
    $boot=ConvertTo-TCUtc $BootTime;$started=ConvertTo-TCUtc $Snapshot.StartedAt
    $savedBoot=ConvertTo-TCUtc $Snapshot.BootStartedAt
    $reboot=[bool]($Snapshot -and $boot -and (($started -and $started -lt $boot.AddSeconds(-2)) -or ($savedBoot -and [math]::Abs(($savedBoot-$boot).TotalSeconds) -gt 2)))
    $pathsCurrent=[bool]($Snapshot -and $Manifest -and $started -and $boot -and (Test-TCSamePath $Snapshot.ManifestPath $Deployment.ManifestPath) -and (Test-TCSamePath $Snapshot.ConfigPath $Manifest.CandidatePath))
    $current=$pathsCurrent -and -not $reboot
    $owner=$null;$engine=$null;$candidates=@();$ownerExact=$false;$engineExact=$false
    foreach($p in $Processes){
        $supervisor=$false
        if($p.Name -in @('powershell.exe','pwsh.exe')){
            $file=Get-TCPowerShellFileArgument $p.CommandLine
            # Invalid paths in unrelated processes must not abort the inventory.
            try{$supervisor=[bool]($file -and $file.IndexOfAny([IO.Path]::GetInvalidPathChars()) -lt 0 -and [IO.Path]::GetFileName($file) -eq 'Run-TradeChannel.ps1')}catch{$supervisor=$false}
        }
        $engineCandidate=[bool]($Manifest -and (Test-TCSamePath $p.ExecutablePath $Manifest.EnginePath) -and (Test-TCSamePath (Get-TCCommandArgument $p.CommandLine '-c|--config') $Manifest.CandidatePath))
        # An unreadable command line, or an extra sing-box, is not proof that
        # no session exists. It must block starts without authorizing a kill.
        $unknownEngine=$p.Name -eq 'sing-box.exe'
        if($supervisor -or $engineCandidate -or $unknownEngine){$candidates+=,$p}
        if(-not $pathsCurrent){continue}
        $created=ConvertTo-TCUtc $p.CreationDate
        if(-not $created -or $created -lt $boot){continue}
        if($supervisor -and $p.ProcessId -eq $Snapshot.SupervisorPid -and (Test-TCSamePath (Get-TCCommandArgument $p.CommandLine '-ManifestPath') $Deployment.ManifestPath)){
            $recorded=ConvertTo-TCUtc $Snapshot.SupervisorStartedAt
            $timeMatches=if($recorded){[math]::Abs(($created-$recorded).TotalMilliseconds) -lt 1}else{($started-$created).TotalSeconds -ge 0 -and ($started-$created).TotalSeconds -lt 120}
            if($timeMatches){$owner=$p;$ownerExact=[bool]$recorded}
        }
        if($engineCandidate -and $p.ProcessId -eq $Snapshot.EnginePid){
            $recorded=ConvertTo-TCUtc $Snapshot.EngineStartedAt
            $written=ConvertTo-TCUtc $Snapshot.RecordWrittenAt
            $timeMatches=if($recorded){[math]::Abs(($created-$recorded).TotalMilliseconds) -lt 1}else{$written -and $created -le $written -and ($created-$started).TotalSeconds -ge -1 -and ($created-$started).TotalSeconds -lt 120}
            if($timeMatches -and $p.ParentProcessId -eq $Snapshot.SupervisorPid){$engine=$p;$engineExact=[bool]$recorded}
        }
    }
    # WMI LastBootUpTime can drift after clock synchronization. It must not
    # invalidate two exact live process births, paths and the parent relationship.
    # Legacy approximate timestamps and reused PIDs never get this exception.
    if($reboot -and $ownerExact -and $engineExact){$reboot=$false;$current=$true}
    elseif($reboot){$owner=$null;$engine=$null}
    [pscustomobject]@{Current=$current;BootRestartDetected=$reboot;SupervisorAlive=[bool]$owner;EngineAlive=[bool]$engine;Supervisor=$owner;Engine=$engine;SessionPresent=($candidates.Count -gt 0);Untracked=(@($candidates|Where-Object {(!$owner -or $_.ProcessId -ne $owner.ProcessId) -and (!$engine -or $_.ProcessId -ne $engine.ProcessId)}).Count -gt 0)}
}
function Get-TCGuardApplicationId {
    param([string]$Path)
    # WFP stores a device path, not C:\...; compare exact program identities.
    if(-not ('TCDevicePath' -as [type])){
        Add-Type -TypeDefinition 'using System; using System.Text; using System.Runtime.InteropServices; public static class TCDevicePath { [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] public static extern uint QueryDosDevice(string name, StringBuilder target, int size); }'
    }
    $full=[IO.Path]::GetFullPath($Path);$buffer=New-Object Text.StringBuilder(4096)
    if(-not [TCDevicePath]::QueryDosDevice($full.Substring(0,2),$buffer,$buffer.Capacity)){throw '无法核对交易程序身份。'}
    ($buffer.ToString().Split([char]0)[0]+$full.Substring(2)).ToLowerInvariant()
}
function Get-TCGuardSnapshot {
    if($script:IsolatedReadContext){return $null}
    if(-not ('TradeChannelGuard' -as [type])){Add-Type -Path (Join-Path $script:Package 'runtime\TradeChannelGuard.cs')}
    [TradeChannelGuard]::GetStatus()
}
function Get-TCGuardPresentation {
    param($Guard,[string[]]$ApplicationIds)
    $state='Unknown';$summary='交易保护状态暂时无法核实，请检查保护规则。'
    if($Guard){
        if(-not $Guard.ProviderPresent -or -not @($ApplicationIds).Count){$state='Unprotected'}
        elseif($Guard.InfrastructureVerified){
            $state='Protected'
            foreach($app in $ApplicationIds){foreach($family in @('IPv4','IPv6')){
                if(-not @($Guard.Filters|Where-Object {$_.Recognized -and $_.IsBlock -and $_.IsPersistent -and -not $_.IsDisabled -and $_.ApplicationId -eq $app -and $_.Family -eq $family}).Count){$state='Unprotected'}
            }}
        }
    }
    if($state -eq 'Protected'){$summary='交易程序 IPv4/IPv6 直连保护已启用；断开通道后仍保留。'}
    elseif($state -eq 'Unprotected'){$summary='交易程序直连保护未完整启用，请检查保护规则。'}
    [pscustomobject]@{GuardState=$state;GuardSummary=$summary}
}
function Read-TCProfileBindingFile {
    param([string]$Path,[switch]$Json)
    $full=[IO.Path]::GetFullPath($Path);$prefix=[IO.Path]::GetFullPath($script:Root).TrimEnd('\')+'\'
    if(-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Profile binding outside data root'}
    Assert-TCIsolatedReadPath $full
    $bytes=[IO.File]::ReadAllBytes($full);$sha=[Security.Cryptography.SHA256]::Create()
    try{$hash=([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','')}finally{$sha.Dispose()}
    $value=$null;if($Json){$value=[Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xfeff)|ConvertFrom-Json}
    [pscustomobject]@{Path=$full;SHA256=$hash;Value=$value}
}
function Get-TCActiveProfileBindingEvidence {
    param($Deployment,$Manifest,$Snapshot,$Identity,[bool]$ControlAvailable,$Fault)
    $unverified=[pscustomobject]@{Verified=$false;Reason='NoVerifiedRunningProfile'}
    if($Fault -or -not $ControlAvailable -or -not $Identity.Current -or $Identity.Untracked -or -not $Identity.SupervisorAlive -or -not $Identity.EngineAlive -or $Snapshot.State -ne 'Running' -or -not $Snapshot.SessionId){return $unverified}
    if(-not $Deployment.ProfileManifestPath -or -not $Deployment.LineId -or $Deployment.ProfileId -notin @('Udp','Tcp') -or $Deployment.TransactionId -cnotmatch '^[a-f0-9]{32}$'){return $unverified}
    try{
        $lineGuid=[guid]::Empty;if(-not [guid]::TryParse([string]$Deployment.LineId,[ref]$lineGuid)){throw 'Invalid line identity'}
        if(-not (Test-TCSamePath $Snapshot.ManifestPath $Deployment.ManifestPath) -or -not (Test-TCSamePath $Snapshot.ConfigPath $Manifest.CandidatePath)){throw 'Snapshot deployment mismatch'}
        $journal=Read-TCProfileBindingFile (Join-Path $script:Root ('connection-transactions\'+$Deployment.TransactionId+'.json')) -Json
        $tx=$journal.Value
        if($tx.SchemaVersion -ne 1 -or $tx.Id -cne $Deployment.TransactionId -or $tx.LineId -ne $Deployment.LineId -or $tx.SourceNodeId -ne $Deployment.LineId -or $tx.ProfileId -ne $Deployment.ProfileId -or -not (Test-TCSamePath $tx.ActiveManifestPath $Deployment.ManifestPath) -or -not (Test-TCSamePath $tx.Target.ManifestPath $Deployment.ProfileManifestPath)){throw 'Transaction profile mismatch'}
        $approved=Read-TCProfileBindingFile $Deployment.ManifestPath -Json
        $profile=Read-TCProfileBindingFile $Deployment.ProfileManifestPath -Json
        $config=Read-TCProfileBindingFile $Manifest.CandidatePath
        $a=$approved.Value;$p=$profile.Value;$hash=$config.SHA256
        if($approved.SHA256 -cne $tx.ActiveManifestSHA256 -or $profile.SHA256 -cne $tx.Target.ManifestSHA256 -or -not $a.DeploymentApproved -or $a.TCTransactionId -cne $tx.Id -or -not (Test-TCSamePath $a.TCProfileManifestPath $profile.Path)){throw 'Approved/profile manifest hash mismatch'}
        if(-not $hash -or $hash -cne $tx.TargetHash -or $hash -cne $tx.Target.CandidateSHA256 -or $hash -cne $Deployment.CandidateSHA256 -or $hash -cne $Manifest.CandidateSHA256 -or $hash -cne $a.CandidateSHA256 -or $hash -cne $p.CandidateSHA256){throw 'Candidate hash mismatch'}
        foreach($path in @($a.CandidatePath,$p.CandidatePath,$tx.Target.CandidatePath)){if(-not (Test-TCSamePath $path $Snapshot.ConfigPath)){throw 'Candidate path mismatch'}}
        foreach($m in @($a,$p)){
            if(($m.TCLineId -and $m.TCLineId -ne $Deployment.LineId) -or ($m.TCProfileId -and $m.TCProfileId -ne $Deployment.ProfileId)){throw 'Manifest line/profile identity mismatch'}
        }
        [pscustomobject]@{Verified=$true;Reason='VerifiedRunningProfile';LineId=[string]$Deployment.LineId;ProfileId=[string]$Deployment.ProfileId;ProfileManifestPath=$profile.Path;ManifestPath=$approved.Path;ApprovedManifestSHA256=$approved.SHA256;ProfileManifestSHA256=$profile.SHA256;CandidateSHA256=$hash;ConfigPath=$config.Path;SessionId=$Snapshot.SessionId;SupervisorPid=$Snapshot.SupervisorPid;SupervisorStartedAt=$Snapshot.SupervisorStartedAt;EnginePid=$Snapshot.EnginePid;EngineStartedAt=$Snapshot.EngineStartedAt}
    }catch{$unverified.Reason='ProfileBindingMismatch';return $unverified}
}
function Get-TCSessionEvidence {
    param([switch]$SkipController)
    $d=$null;$s=$null;$m=$null;$identity=$null;$fault=$null;$control=$null;$controllerModes=@();$selection=$null;$dailySelection=$null;$dailySupported=$false;$agentsSupported=$false;$sessions=$null;$healthy=$false
    try{
        $d=Get-TCInstalledDeployment;$s=Get-TCRuntimeSnapshot
        if($d){
            $m=Get-Content -LiteralPath $d.ManifestPath -Encoding UTF8 -Raw|ConvertFrom-Json;if(-not $m.CandidatePath -or -not $m.EnginePath -or -not (Test-Path -LiteralPath $m.CandidatePath)){throw 'Invalid deployment'}
            if($script:IsolatedReadContext){Assert-TCIsolatedReadPath $m.CandidatePath}
            # Tag checks only; the secret-bearing configuration is not kept in memory.
            $configText=[IO.File]::ReadAllText($m.CandidatePath)
            $dailySupported=[bool]($configText -match '"tag"\s*:\s*"daily-exit"');$agentsSupported=[bool]($configText -match '"tag"\s*:\s*"tc-agents"');$configText=$null
        }
        $boot=Get-TCBootTime
        if(-not (ConvertTo-TCUtc $boot)){throw 'Boot time unavailable'}
        $identity=Get-TCRuntimeIdentity $d $m $s @(Get-TCProcessInventory $m) $boot
    }catch{$fault='无法核实部署或进程状态，请检查诊断信息后重试；不会自动启动新实例。'}
    if(-not $SkipController -and $identity -and $identity.Current -and $identity.EngineAlive -and $identity.SupervisorAlive -and $s.State -eq 'Running'){
        try{
            $control=Invoke-TCController $m '/configs'
            $controllerModes=@($control.'mode-list'|Where-Object {$_ -is [string] -and $_}|ForEach-Object {$_.ToLowerInvariant()}|Select-Object -Unique)
            $cfg=Get-Content -LiteralPath $m.CandidatePath -Encoding UTF8 -Raw|ConvertFrom-Json
            if(@($cfg.outbounds|Where-Object {$_.tag -eq 'trade-exit'}).Count){$selection=Invoke-TCController $m '/proxies/trade-exit'}else{$selection=[pscustomobject]@{now='hk'}}
            if($dailySupported){$dailySelection=Invoke-TCController $m '/proxies/daily-exit'}
            $cfg=$null
            $sessions=Invoke-TCController $m '/connections'
            $allowedExits=@('hk','provider')+@(Get-TCManifestProviders $m|ForEach-Object {$_.Tag;if($_.TradeTag){$_.TradeTag}})
            if($control.mode -notin @('rule','global') -or $selection.now -notin $allowedExits -or -not $sessions.PSObject.Properties['connections']){throw 'Unexpected controller response'}
            $healthy=$true
        }catch{$fault='通道进程仍在运行，但控制接口不可用。请断开后重试连接。'}
        # Close the read race: a successful API response is not proof the owner
        # survived, or that deployment/state was not replaced during the request.
        try{
            $latest=Get-TCRuntimeSnapshot;$latestDeployment=Get-TCInstalledDeployment
            if(-not (Test-TCSamePath $latestDeployment.ManifestPath $d.ManifestPath)) {throw 'Deployment changed'}
            foreach($field in @('ProfileManifestPath','LineId','ProfileId','TransactionId','CandidateSHA256')){if([string]$latestDeployment.$field -cne [string]$d.$field){throw 'Deployment binding changed'}}
            $identity=Get-TCRuntimeIdentity $d $m $latest @(Get-TCProcessInventory $m) (Get-TCBootTime)
            $s=$latest
            if(-not $identity.SessionPresent){$healthy=$false;$fault=$null}
        }catch{$healthy=$false;$fault='读取期间会话发生变化，请刷新状态；不会自动启动新实例。'}
    }
    $profileBinding=Get-TCActiveProfileBindingEvidence $d $m $s $identity $healthy $fault
    $guard=Get-TCGuardPresentation $null @()
    try{$ids=@(foreach($program in @($m.TradeProgramPaths)){if($program){Get-TCGuardApplicationId $program}});$guard=Get-TCGuardPresentation (Get-TCGuardSnapshot) $ids}catch{}
    $nodeName=$null
    if($d){try{$node=@(Get-TCRegisteredNodes|Where-Object {(Test-TCSamePath $_.manifestPath $d.ManifestPath) -or ($profileBinding.Verified -and $_.id -eq $profileBinding.LineId -and (Test-TCSamePath $_.manifestPath $profileBinding.ProfileManifestPath))});if($node.Count){$nodeName=$node[0].name}}catch{}}
    if(-not $nodeName -and $m){$nodeName=if($m.Name){[string]$m.Name}else{'当前节点'}}
    $stopPath=Join-Path $script:Root 'stop.request';$stopRequested=Test-Path -LiteralPath $stopPath
    $provider=$null;try{$provider=Get-TCProviderStatus $m}catch{}
    $policyVersion=if($m -and $m.PolicyVersion){[int]$m.PolicyVersion}elseif($m){1}else{$null}
    $agentState=$null;if($agentsSupported){try{$agentState=Read-TCAgentState $script:Root}catch{}}
    [pscustomobject]@{Deployment=$d;Manifest=$m;Snapshot=$s;Identity=$identity;ProfileBinding=$profileBinding;Fault=$fault;ControlAvailable=$healthy;Mode=$control.mode;ControllerModes=$controllerModes;ModeSwitchSupported=[bool]($healthy -and $controllerModes -contains 'rule' -and $controllerModes -contains 'global');Exit=$selection.now;Daily=$dailySelection.now;DailySupported=$dailySupported;AgentsSupported=$agentsSupported;AgentState=$agentState;Provider=$provider;PolicyVersion=$policyVersion;Connections=@($sessions.connections|Where-Object {$null -ne $_}).Count;Guard=$guard;NodeName=$nodeName;NinjaRunning=(Test-TCNinjaRunning);StopRequested=$stopRequested;StopRequestedAt=$(if($stopRequested){[IO.File]::GetLastWriteTimeUtc($stopPath).ToString('o')}else{$null});ObservedAt=(Get-Date).ToString('o')}
}
function Get-TCProviderStatus {
    param($Manifest)
    if($script:IsolatedReadContext){return $null}
    if(-not $Manifest -or -not @(Get-TCManifestProviders $Manifest).Count){return $null}
    $preferences=Get-TCPreferences
    $health=Get-TCProviderHealth -Manifest $Manifest -ProviderId $preferences.ProviderId
    $health|Add-Member -NotePropertyName ReasonText -NotePropertyValue (Get-TCProviderReasonText ([string]$health.Reason)) -Force
    $health
}
function Get-TCSessionPresentation {
    # Pure function: all filesystem/process/API/WFP inputs are supplied by caller.
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$Evidence,$Preferences)
    $e=$Evidence;$i=$e.Identity;$s=$e.Snapshot
    if(-not $Preferences){$Preferences=[pscustomobject]@{Mode='Trading';Exit='HongKong';NodeId=$null}}
    $key='Disconnected';$title='未连接';$detail='选择线路后点击连接；不会自动连接。';$action='Connect';$enabled=$true;$errorText=$null
    $canStart=[bool]($e.Deployment -and $i -and -not $i.SessionPresent -and -not $e.Fault)
    if(-not $e.Deployment){$key='Unconfigured';$title='尚未配置';$detail='请在部署页导入或接管节点，然后连接。';$action='Setup'}
    if($i.BootRestartDetected){$detail='检测到系统已重启，上次连接已结束。点击连接以建立新会话。'}
    if($i.Current -and $i.SupervisorAlive -and -not $i.Untracked -and $e.StopRequested){
        $key='Disconnecting';$title='正在断开';$detail='已请求停止通道，正在等待清理完成；交易保护仍保留。';$action='None';$enabled=$false
    }
    elseif($e.Fault){$key='Fault';$errorText=$e.Fault}
    elseif($i.Untracked){$key='Fault';$errorText='发现无法核实身份的通道进程，请检查诊断信息；不会重复启动或停止未知进程。';$enabled=$false}
    elseif($i.Current -and $i.SupervisorAlive -and $s.State -in @('Starting','Stopping','Disconnecting')){
        if($s.State -eq 'Starting'){
            $key='Connecting';$title='正在连接';$detail='正在启动并核对通道，请稍候。'
            $now=ConvertTo-TCUtc $e.ObservedAt;$start=ConvertTo-TCUtc $s.StartedAt
            if($now -and $start -and ($now-$start).TotalSeconds -gt 60){$key='Fault';$errorText='启动未在预期时间内完成，请断开后重试。'}
        }else{$key='Disconnecting';$title='正在断开';$detail='正在停止通道并保留交易保护，请稍候。'}
        $action='None';$enabled=$false
    }
    elseif($i.Current -and $i.SupervisorAlive -and $i.EngineAlive -and $s.State -eq 'Running' -and $e.ControlAvailable){
        $key='Connected';$title='已连接';$detail='通道进程与本机控制接口正常；行情、历史数据和订单需分别检查。';$action='Disconnect'
    }
    elseif($i.SessionPresent){$key='Fault';$errorText='会话未完整运行，请断开后重新连接。'}
    elseif($i.Current -and $s.State -eq 'StoppedWithError'){$key='Fault';$errorText='上次通道异常停止，请检查诊断信息后重试连接。'}
    if($key -eq 'Disconnecting'){
        $now=ConvertTo-TCUtc $e.ObservedAt
        $since=if($e.StopRequestedAt){ConvertTo-TCUtc $e.StopRequestedAt}else{ConvertTo-TCUtc $s.RecordWrittenAt}
        if($now -and $since -and ($now-$since).TotalSeconds -gt 30){$key='Fault';$errorText='断开未在预期时间内完成，请重试断开并检查诊断信息；不会自动重启。'}
    }
    if($key -eq 'Fault'){
        $title='连接需要处理';$detail=$errorText
        if($i.SupervisorAlive -or $i.EngineAlive){$action='Disconnect';$enabled=$true}
        else{$action='Retry';$enabled=$canStart}
    }
    $running=$key -eq 'Connected'
    $m=$e.Manifest
    $profile=$null;$b=$e.ProfileBinding
    if($running -and $b.Verified -and $b.SessionId -and $b.SessionId -ceq $s.SessionId -and $b.LineId -eq $e.Deployment.LineId -and $b.ProfileId -eq $e.Deployment.ProfileId -and (Test-TCSamePath $b.ManifestPath $e.Deployment.ManifestPath) -and (Test-TCSamePath $b.ProfileManifestPath $e.Deployment.ProfileManifestPath) -and (Test-TCSamePath $b.ConfigPath $s.ConfigPath) -and $b.CandidateSHA256 -ceq $m.CandidateSHA256 -and $b.CandidateSHA256 -ceq $e.Deployment.CandidateSHA256 -and $b.SupervisorPid -eq $s.SupervisorPid -and $b.SupervisorStartedAt -ceq $s.SupervisorStartedAt -and $b.EnginePid -eq $s.EnginePid -and $b.EngineStartedAt -ceq $s.EngineStartedAt){$profile=$b}
    $agentPrefs=Get-TCAgentSelection $Preferences
    $agentNames=@(@(Get-TCAgentCatalog|Where-Object {$agentPrefs.Ids -contains $_.Id}|ForEach-Object {$_.Short})+@($agentPrefs.Custom|ForEach-Object {if($_.Kind -eq 'Program'){[IO.Path]::GetFileName([string]$_.Value)}else{[string]$_.Value}}))
    [pscustomobject][ordered]@{
        Running=$running;State=$title;StateKey=$key;Title=$title;Detail=$detail;PrimaryAction=$action;PrimaryEnabled=[bool]$enabled
        Mode=$(if($running){$e.Mode}else{$null});Exit=$(if($running){$e.Exit}else{$null});Connections=$(if($running){$e.Connections}else{0})
        ControllerModes=@(if($running){$e.ControllerModes});ModeSwitchSupported=[bool]($running -and $e.ModeSwitchSupported)
        Daily=$(if($running -and $e.DailySupported){$e.Daily}else{$null});DailySupported=[bool]$e.DailySupported;DesiredDaily=$(if($Preferences.Daily){$Preferences.Daily}else{'Direct'})
        DailyReason=$(if($running){$s.DailyReason}else{$null});ForeignTunnel=$(if($running -and $s.ForeignTunnel){$s.ForeignTunnel}elseif($e.Provider){$e.Provider.ForeignTunnel}else{$null})
        AgentsSupported=[bool]$e.AgentsSupported;Agents=$(if($running -and $e.AgentsSupported -and $e.AgentState){[string]$e.AgentState.Lane}else{$null});DesiredAgents=$agentPrefs.Lane;AgentIds=@($agentPrefs.Ids);AgentCustom=@($agentPrefs.Custom);AgentNames=$agentNames
        Provider=$e.Provider;Providers=@(Get-TCManifestProviders $m);ProviderId=$Preferences.ProviderId;TradeProviderId=$Preferences.TradeProviderId;PolicyVersion=$e.PolicyVersion;UpgradeAvailable=[bool]($e.Deployment -and (($e.PolicyVersion -and $e.PolicyVersion -lt 4) -or ($running -and @($e.ControllerModes).Count -gt 0 -and -not $e.ModeSwitchSupported)))
        ConnectedSince=$(if($running){$s.EngineStartedAt}else{$null})
        ProxyEvents=$(if($running -and $s.ProxyEvents){[int]$s.ProxyEvents}else{0});LastProxyKind=$(if($running){$s.LastProxyKind}else{$null});LastProxyAt=$(if($running){$s.LastProxyAt}else{$null});LastProxySummary=$(if($running){$s.LastProxySummary}else{$null})
        TradePrograms=@(foreach($program in @($m.TradeProgramPaths)){if($program){[IO.Path]::GetFileName([string]$program)}});TradeDomains=@($m.TradeDomainSuffixes|Where-Object {$_});AuxDomains=@($m.TradeDnsOnlySuffixes|Where-Object {$_})
        DesiredMode=$Preferences.Mode;DesiredExit=$Preferences.Exit;NodeId=$Preferences.NodeId;NodeName=$e.NodeName
        GuardState=$e.Guard.GuardState;GuardSummary=$e.Guard.GuardSummary;BootRestartDetected=[bool]$i.BootRestartDetected
        ManifestPath=$e.Deployment.ManifestPath;ProfileManifestPath=$profile.ProfileManifestPath;LineId=$profile.LineId;ProfileId=$profile.ProfileId;ProfileBindingVerified=[bool]$profile;DesiredProfileId=$Preferences.ProfileId;NodeEndpoint=$e.Manifest.ServerEndpoint;NinjaRunning=[bool]$e.NinjaRunning
        ProviderConfigured=[bool](@(Get-TCManifestProviders $e.Manifest).Count);Error=$errorText;ObservedAt=$e.ObservedAt
        ProtectionNote='浏览器连通不代表全部交易服务正常；保护状态仅说明交易程序的直连规则。'
        SessionPresent=[bool]$i.SessionPresent;CanConnect=$canStart
    }
}
function Get-TCOverview {
    $preferences=Get-TCPreferences
    Get-TCSessionPresentation -Evidence (Get-TCSessionEvidence) -Preferences $preferences
}
function Invoke-TCCommand {
    param([ValidateSet('Connect','Disconnect','Trading','Global','HongKong','Provider','DailyDirect','DailyProvider','Agents','Emergency','Status')][string]$Action)
    Assert-TCRealRuntimeContext
    . (Join-Path $script:Package 'runtime\Invoke-TradeChannel.ps1') -Action $Action -LoadFunctionsOnly
    Invoke-TCRuntimeAction -Action $Action
}
function Invoke-TCSession {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][ValidateSet('Connect','Disconnect','Apply')][string]$Action,[ValidateSet('Trading','Global')][string]$Mode,[ValidateSet('HongKong','Provider')][string]$Exit,[ValidateSet('Direct','Provider')][string]$Daily,[AllowNull()][AllowEmptyString()][string]$NodeId,[ValidateSet('Daily','Trade')][string]$Agents,[AllowNull()][AllowEmptyCollection()][string[]]$AgentIds,[AllowNull()][AllowEmptyCollection()][object[]]$AgentCustom,[AllowNull()][AllowEmptyString()][string]$ProviderId,[AllowNull()][AllowEmptyString()][string]$TradeProviderId,[AllowNull()][AllowEmptyString()][ValidateScript({-not $_ -or $_ -in @('Udp','Tcp')})][string]$ProfileId,[string]$PreviewToken)
    Assert-TCRealRuntimeContext
    $lock=Open-TCSessionLock
    try{
        if($Action -eq 'Disconnect'){$null=Invoke-TCCommand Disconnect;return Get-TCOverview}
        $p=Get-TCPreferences
        if(-not $PSBoundParameters.ContainsKey('Mode')){$Mode=$p.Mode}
        if(-not $PSBoundParameters.ContainsKey('Exit')){$Exit=$p.Exit}
        if(-not $PSBoundParameters.ContainsKey('Daily')){$Daily=$p.Daily}
        if(-not $PSBoundParameters.ContainsKey('NodeId')){$NodeId=$p.NodeId}
        if(-not $PSBoundParameters.ContainsKey('ProviderId')){$ProviderId=$p.ProviderId}
        if(-not $PSBoundParameters.ContainsKey('TradeProviderId')){$TradeProviderId=$p.TradeProviderId}
        if(-not $PSBoundParameters.ContainsKey('ProfileId')){$ProfileId=$p.ProfileId}
        $o=Get-TCOverview
        # Applying daily/assistant settings must preserve the observed trading
        # session, even when a previous failed operation left stale preferences.
        if($Action -eq 'Apply' -and $o.Running){
            if(-not $PSBoundParameters.ContainsKey('Mode')){$Mode=if($o.Mode -eq 'global'){'Global'}else{'Trading'}}
            if(-not $PSBoundParameters.ContainsKey('Exit')){$Exit=if($o.Exit -eq 'hk'){'HongKong'}else{'Provider'}}
            if(-not $PSBoundParameters.ContainsKey('NodeId') -and -not $PSBoundParameters.ContainsKey('ProfileId')){$NodeId=$null}
        }
        # Legacy Connect remains idempotent. An explicit profile request must
        # enter the controlled switch and prove that profile's own hk exit.
        if($Action -eq 'Connect' -and $o.Running -and -not ($PSBoundParameters.ContainsKey('ProfileId') -and $ProfileId)){return $o}
        if($Action -eq 'Apply' -and -not $o.Running){throw '当前未连接；选择仅可保存，连接成功后才能应用更改。'}
        if($Action -eq 'Connect' -and -not $o.Running -and -not $o.CanConnect -and $o.StateKey -ne 'Unconfigured'){throw '当前会话未能安全核实或操作仍在进行，请先检查状态或断开；不会重复启动。'}
        if($ProfileId -and $PSBoundParameters.ContainsKey('ProfileId') -and -not $NodeId){throw '连接方式切换缺少已选择的线路；未验证或改变任何出口。'}
        if($ProfileId -and $NodeId -and ($Action -eq 'Connect' -or $PSBoundParameters.ContainsKey('NodeId') -or $PSBoundParameters.ContainsKey('ProfileId'))){
            $intent=[ordered]@{Mode=$Mode;Exit='HongKong';Daily=$Daily;NodeId=$NodeId;ProfileId=$ProfileId;ProviderId=$ProviderId;TradeProviderId=$TradeProviderId;Agents=$p.Agents;AgentIds=@($p.AgentIds);AgentCustom=@($p.AgentCustom)}
            foreach($key in @('Agents','AgentIds','AgentCustom')){if($PSBoundParameters.ContainsKey($key)){$intent[$key]=$PSBoundParameters[$key]}}
            $transaction=Invoke-TCProfileConnectionSwitch -LineId $NodeId -ProfileId $ProfileId -Intent ([pscustomobject]$intent) -PreviewToken $PreviewToken -SessionLockHeld
            if($transaction.Status -ne 'Completed'){throw ($transaction.Message+' '+$transaction.Error)}
            $result=Get-TCOverview;$result|Add-Member NoteProperty ConnectionTransaction $transaction -Force;return $result
        }
        $selected=$null
        if($NodeId){
            $selected=@(Get-TCRegisteredNodes|Where-Object {$_.id -eq $NodeId})
            if($selected.Count -ne 1 -or -not $selected[0].manifestPath){throw '所选节点尚无可用配置，请先在部署页完成导入。'}
            $selected=$selected[0]
        }
        $logicalManifest=if($o.ProfileManifestPath){$o.ProfileManifestPath}else{$o.ManifestPath}
        $changeNode=[bool]($selected -and -not (Test-TCSamePath $selected.manifestPath $logicalManifest))
        $wantedMode=if($Mode -eq 'Trading'){'rule'}else{'global'}
        # Observed capabilities belong to this running node only. Reject before
        # saving any intent or changing even an unrelated selector/rule-set.
        if($Action -eq 'Apply' -and -not $changeNode -and $o.Mode -ne $wantedMode -and $o.ControllerModes -notcontains $wantedMode){
            throw ('[TC:ModeUnavailable] 当前引擎配置缺少请求的模式（'+$wantedMode+'），请更新线路配置并重新连接后再切换；当前连接未改变。')
        }
        if($changeNode -and (Get-Process -Name NinjaTrader -ErrorAction SilentlyContinue)){throw '请先退出 NinjaTrader 整个控制中心，再应用节点更改；当前连接未改变。'}
        if(-not $selected -and -not $o.ManifestPath){throw '请先在部署页选择可用节点。'}
        $currentManifest=if($changeNode){Get-Content -LiteralPath $selected.manifestPath -Encoding UTF8 -Raw|ConvertFrom-Json}elseif($o.ManifestPath){Get-Content -LiteralPath $o.ManifestPath -Encoding UTF8 -Raw|ConvertFrom-Json}else{$null}
        $fallbacks=New-Object 'Collections.Generic.List[string]'
        $allowDailyMissing=$changeNode -or ($Action -eq 'Connect' -and -not $PSBoundParameters.ContainsKey('ProviderId'))
        $dailyTarget=Resolve-TCProviderTarget $currentManifest $ProviderId -AllowMissing:$allowDailyMissing
        if($ProviderId -and -not $dailyTarget){
            $Daily='Direct';$ProviderId=$null
            $fallbacks.Add('目标线路不包含此前的日常服务商，日常上网暂时使用本地直连。')
        }
        if($changeNode -and $TradeProviderId -and -not (Resolve-TCProviderTarget $currentManifest $TradeProviderId -ForTrade -AllowMissing)){
            $TradeProviderId=$null
            if($Exit -eq 'Provider'){$Exit='HongKong'}
            $fallbacks.Add('目标线路没有此前的交易备用，交易使用该自建线路。')
        }
        if($Action -eq 'Apply' -and $o.Running -and -not $PSBoundParameters.ContainsKey('Exit') -and -not $PSBoundParameters.ContainsKey('TradeProviderId')){
            $wantedExit=[string]$o.Exit
            $actualProvider=Get-TCProviderByTag $currentManifest $o.Exit
            if($actualProvider){$TradeProviderId=[string]$actualProvider.Id}
        }elseif($Exit -eq 'HongKong'){$wantedExit='hk'}else{
            if(-not $TradeProviderId){$TradeProviderId=$ProviderId}
            if(-not $TradeProviderId -and -not $changeNode -and $currentManifest.PSObject.Properties['ProviderSocksPort'] -and -not $currentManifest.PSObject.Properties['Providers']){
                $legacyDefault=Resolve-TCProviderTarget $currentManifest $null -ForTrade
                if($legacyDefault){$TradeProviderId=[string]$legacyDefault.Id}
            }
            $tradeTarget=if($TradeProviderId){Resolve-TCProviderTarget $currentManifest $TradeProviderId -ForTrade -AllowMissing:$changeNode}else{$null}
            if(-not $tradeTarget){
                if($changeNode){$Exit='HongKong';$wantedExit='hk';$TradeProviderId=$null}
                else{throw '交易备用尚未写入线路配置，当前出口未改变。'}
            }else{
                $wantedExit=[string]$tradeTarget.Tag
            }
        }
        $save=@{Mode=$Mode;Exit=$Exit;Daily=$Daily;ProviderId=$ProviderId;TradeProviderId=$TradeProviderId}
        if($PSBoundParameters.ContainsKey('NodeId') -or $Action -eq 'Connect'){$save.NodeId=$NodeId}
        foreach($key in @('Agents','AgentIds','AgentCustom')){if($PSBoundParameters.ContainsKey($key)){$save[$key]=$PSBoundParameters[$key]}}
        if($changeNode){
            # Snapshot preferences before writing requested intent. The unified
            # transaction owns stop, pointers, selectors, verification and rollback.
            $transaction=Invoke-TCManifestConnectionSwitch -ManifestPath $selected.manifestPath -Intent ([pscustomobject]$save) -SessionLockHeld
            if($transaction.Status -ne 'Completed'){throw ($transaction.Message+' '+$transaction.Error)}
            $result=Get-TCOverview;$result|Add-Member NoteProperty ConnectionTransaction $transaction -Force
            if($fallbacks.Count){$result|Add-Member NoteProperty PreferenceFallback ($fallbacks.ToArray() -join ' ') -Force}
            return $result
        }
        $saved=$null;$preferencesSaved=$false
        try{
            $saved=Save-TCPreferences @save
            $preferencesSaved=$true
        if($Action -eq 'Connect'){$null=Invoke-TCCommand Connect}
        $active=Get-TCOverview
        if(-not $active.Running){throw '连接尚未通过状态核验，未应用线路选择；请检查状态。'}
        $activeManifest=if($active.ProfileManifestPath){$active.ProfileManifestPath}else{$active.ManifestPath}
        if($selected -and -not (Test-TCSamePath $activeManifest $selected.manifestPath)){throw '实际连接节点与所选节点不符，请检查当前状态。'}
        if($active.Exit -ne $wantedExit){$null=Invoke-TCCommand $Exit}
        if($active.Mode -ne $wantedMode){$null=Invoke-TCCommand $Mode}
        # Daily traffic never shares a selector with trading flows. A provider that is
        # not ready keeps daily traffic direct; the saved intent is applied later.
        $dailyApply=$null
        $wantedDaily=if($Daily -eq 'Provider' -and $dailyTarget){[string]$dailyTarget.Tag}else{'direct'}
        if($active.DailySupported -and $active.Daily -ne $wantedDaily){$dailyApply=Invoke-TCCommand ('Daily'+$Daily)}
        # The assistant list is applied by rewriting watched rule-sets; trading flows stay put.
        $agentApply=$null
        if($active.AgentsSupported -and -not (Test-TCAgentApplied (Read-TCAgentState $script:Root) (Get-TCAgentSelection $saved))){$agentApply=Invoke-TCCommand Agents}
        $result=Get-TCOverview
        if(-not $result.Running -or $result.Exit -ne $wantedExit -or $result.Mode -ne $wantedMode){throw '连接选择未通过回读，请检查当前状态；不会自动重启。'}
        $resultManifest=if($result.ProfileManifestPath){$result.ProfileManifestPath}else{$result.ManifestPath}
        if($selected -and -not (Test-TCSamePath $resultManifest $selected.manifestPath)){throw '读取期间连接节点发生变化，请检查当前状态。'}
        if($dailyApply){$result|Add-Member -NotePropertyName DailyApply -NotePropertyValue ([pscustomobject]@{Applied=[bool]$dailyApply.Applied;Effective=$dailyApply.Effective;Reason=$dailyApply.Reason;ReasonText=(Get-TCProviderReasonText ([string]$dailyApply.Reason));ProviderIPv4=$dailyApply.ProviderIPv4}) -Force}
        if($agentApply){
            if($agentApply.Supported -and $result.Agents -ne $saved.Agents){throw 'AI 助手设置未通过回读，请检查当前状态。'}
            $result|Add-Member -NotePropertyName AgentApply -NotePropertyValue ([pscustomobject]@{Supported=[bool]$agentApply.Supported;Lane=$agentApply.Lane;Changed=[bool]$agentApply.Changed;Moved=[int]$agentApply.ConnectionsMoved}) -Force
        }
            if($fallbacks.Count){$result|Add-Member NoteProperty PreferenceFallback ($fallbacks.ToArray() -join ' ') -Force}
            $result
        }catch{
            # Commands may have partially succeeded. Reconcile only trading
            # preferences proven by the same live engine, never the old snapshot
            # or compensating network commands. Daily/agent intent stays saved.
            if($preferencesSaved){
                try{
                    if($changeNode){
                        $observed=Get-TCOverview
                        # Restore the full previous intent only when the candidate
                        # was not retained as the actual selected/live deployment.
                        if([string]$observed.ManifestPath -eq [string]$o.ManifestPath){
                            $prior=@{}
                            foreach($key in @('Mode','Exit','Daily','NodeId','ProviderId','TradeProviderId','Agents','AgentIds','AgentCustom','ProfileId')){$prior[$key]=$p.$key}
                            $null=Save-TCPreferences @prior
                        }
                    }elseif($Action -eq 'Apply'){
                        $observed=Get-TCOverview
                        if($observed.Running -and $observed.ConnectedSince -and $observed.ConnectedSince -eq $o.ConnectedSince -and (Test-TCSamePath $observed.ManifestPath $o.ManifestPath)){
                            $actual=@{Mode=$(if($observed.Mode -eq 'global'){'Global'}else{'Trading'});Exit=$(if($observed.Exit -eq 'hk'){'HongKong'}else{'Provider'})}
                            $actualProvider=Get-TCProviderByTag $currentManifest $observed.Exit
                            if($actualProvider){$actual.TradeProviderId=[string]$actualProvider.Id}
                            $current=Get-TCPreferences;$reconcile=@{}
                            foreach($key in $actual.Keys){if($current.$key -ne $actual[$key]){$reconcile[$key]=$actual[$key]}}
                            if($reconcile.Count){$null=Save-TCPreferences @reconcile}
                        }
                    }
                }catch{}
            }
            throw
        }
    }finally{$lock.Dispose()}
}
function Remove-TCClientProtection {
    Assert-TCRealRuntimeContext
    if(Get-Process -Name NinjaTrader -ErrorAction SilentlyContinue){throw '请先退出 NinjaTrader 整个控制中心；解除后该程序将可以使用普通网络。'}
    $null=Invoke-TCCommand Emergency
    Add-Type -Path (Join-Path $script:Package 'runtime\TradeChannelGuard.cs')
    $count=[TradeChannelGuard]::RemovePersistentBlocks()
    if([TradeChannelGuard]::GetStatus().ProviderPresent){throw '保护解除没有通过回读，请检查诊断信息。'}
    [pscustomobject]@{RemovedProjectFilters=$count;Friendly='本项目交易保护已解除，NinjaTrader 可使用普通网络。其他 VPN 和原始配置未删除。'}
}
function Get-TCExitLatency {
    param($Manifest,[string]$Outbound='trade-exit')
    # Engine-side HTTPS round trip through the selected exit (includes the TLS handshake).
    # An IP literal keeps local DNS answers out of the measurement.
    try{$r=Invoke-TCController $Manifest ('/proxies/'+$Outbound+'/delay?timeout=5000&url='+[Uri]::EscapeDataString('https://1.1.1.1/cdn-cgi/trace'));if($r.delay){[int]$r.delay}}catch{$null}
}
function Test-TCActiveConnection {
    $overview=Get-TCOverview
    if(-not $overview.Running){throw '通道未运行。请先启动，或在部署向导导入并启用节点。'}
    $runner=Join-Path $script:Package 'runtime\Test-SelectedTradeExit.ps1'
    $out=& $runner
    $exitChecks=@($out)
    if($out.CurlExit -ne 0 -or $out.HTTPStatus -ne 200 -or -not $out.ObservedIP){
        $retry=& $runner -Url 'https://www.cloudflare.com/cdn-cgi/trace'
        $exitChecks+=@($retry)
        if($retry.CurlExit -eq 0 -and $retry.HTTPStatus -eq 200 -and $retry.ObservedIP){$out=$retry}
    }
    $site=& $runner -Url 'https://www.tradingview.com/'
    $daily=$null
    if($overview.DailySupported -and $overview.Mode -eq 'rule'){try{$daily=& $runner -Lane Daily}catch{$daily=$null}}
    $m=$null;try{$m=Get-Content -LiteralPath (Get-TCInstalledDeployment).ManifestPath -Encoding UTF8 -Raw|ConvertFrom-Json}catch{}
    $latency=if($m){Get-TCExitLatency $m 'trade-exit'}else{$null}
    $lane=if($overview.Mode -eq 'global'){'trade'}elseif($overview.DailySupported -and $overview.Daily){[string]$overview.Daily}else{'direct'}
    $agentLane=if($overview.Mode -eq 'global' -or ($overview.AgentsSupported -and $overview.Agents -eq 'Trade')){'trade'}else{'daily'}
    [pscustomobject]@{
        Control='通过';ExitHttp=($out.CurlExit -eq 0 -and $out.HTTPStatus -eq 200 -and [bool]$out.ObservedIP);ObservedIP=$out.ObservedIP;TradingViewHttp=($site.CurlExit -eq 0 -and $site.HTTPStatus -eq 200);ExitChecks=$exitChecks
        TradeLatencyMs=$latency;DailyLane=$lane;AgentLane=$agentLane;DailyHttp=$(if($daily){$daily.CurlExit -eq 0 -and $daily.HTTPStatus -eq 200}else{$null});DailyIP=$(if($daily){$daily.ObservedIP}elseif($lane -eq 'trade'){$out.ObservedIP}else{$null})
        History='未在此检查中验证';Orders='未测试，不会自动下单';Time=(Get-Date).ToString('o')
    }
}
# The list page: built-in entries with what is installed or running, plus the saved choice.
function Get-TCAgentOverview {
    $p=Get-TCPreferences;$presence=@();try{$presence=@(Get-TCAgentPresence)}catch{}
    $entries=@(foreach($entry in @(Get-TCAgentCatalog)){
        $found=@($presence|Where-Object {$_.Id -eq $entry.Id})
        [pscustomobject]@{Id=$entry.Id;Name=$entry.Name;Kind=$entry.Kind;Detail=$entry.Detail;Domains=@($entry.Domains);Presence=$(if($found.Count){[string]$found[0].State}else{$null});Enabled=[bool](@($p.AgentIds) -contains $entry.Id)}
    })
    [pscustomobject]@{Lane=$p.Agents;Entries=$entries;Custom=@($p.AgentCustom);Browsers='Chrome、Edge、Firefox、Brave、Opera、Vivaldi'}
}
# Rebuilds the active line at the current policy version, then switches to it with
# the same checks as any node activation. NinjaTrader must be closed (restart).
function Update-TCActivePolicy {
    Assert-TCRealRuntimeContext
    if(Get-Process -Name NinjaTrader -ErrorAction SilentlyContinue){throw '请先退出 NinjaTrader 整个控制中心，再升级线路配置；当前连接未改变。'}
    $d=Get-TCInstalledDeployment;if(-not $d){throw '尚未配置线路，无需升级。'}
    if(-not (Get-Command Update-TCNodePolicy -ErrorAction SilentlyContinue)){Import-Module (Join-Path $script:Package 'NodeStore.psm1') -DisableNameChecking}
    $prefs=Get-TCPreferences;$store=Join-Path $script:Root 'Product'
    $registered=Read-TCProviderStore $store
    $args=@{Root=$store;ManifestPath=$d.ManifestPath}
    if(@($registered.Providers).Count){$args.Providers=@($registered.Providers);$args.ReplaceProviders=$true}
    $up=Update-TCNodePolicy @args
    $activation=Enable-TCNode -ManifestPath $up.ManifestPath -Mode $prefs.Mode -Exit $prefs.Exit
    $null=Set-TCNodeManifest -Root $store -PreviousManifestPath $up.PreviousManifestPath -ManifestPath $up.ManifestPath
    $daily=$null;if($prefs.Daily -eq 'Provider'){try{$daily=Invoke-TCCommand DailyProvider}catch{}}
    [pscustomobject]@{Upgraded=$true;PolicyVersion=$up.PolicyVersion;ManifestPath=$up.ManifestPath;PreviousManifestPath=$up.PreviousManifestPath;Check=$activation.Check;DailyApplied=$(if($daily){[bool]$daily.Applied}else{$null});Friendly='线路配置已升级并重新连接。现在可以打开 NinjaTrader。'}
}
function Enable-TCNode {
    param([string]$ManifestPath,[ValidateSet('Trading','Global')][string]$Mode='Trading',[ValidateSet('HongKong','Provider')][string]$Exit='HongKong')
    Assert-TCRealRuntimeContext
    $transaction=Invoke-TCManifestConnectionSwitch -ManifestPath $ManifestPath -Intent ([pscustomobject]@{Mode=$Mode;Exit=$Exit})
    if($transaction.Status -ne 'Completed'){throw ($transaction.Message+' '+$transaction.Error)}
    $transaction|Add-Member NoteProperty Next '现在可以启动交易软件检查行情；订单与历史数据仍需分别验收。' -Force
    $transaction
}

# Static bridge dispatch lives in this module's scope, so tests can replace its
# dependencies without accepting Worker-supplied executable callbacks.
function Get-TCConnectionTransactionModule {
    $module=Get-Module ConnectionTransactions|Select-Object -First 1
    if(-not $module){$module=Import-Module (Join-Path $script:Package 'ConnectionTransactions.psm1') -PassThru -DisableNameChecking}
    $module
}
function Invoke-TCProfileConnectionSwitch {
    param([string]$LineId,[string]$ProfileId,$Intent,[string]$PreviewToken,[switch]$SessionLockHeld)
    $module=Get-TCConnectionTransactionModule
    & $module {param($DataRoot,$Id,$Profile,$Desired,$Token,$Held) Invoke-CTSessionSwitch -Root $DataRoot -LineId $Id -ProfileId $Profile -Intent $Desired -PreviewToken $Token -SessionLockHeld $Held} $script:Root $LineId $ProfileId $Intent $PreviewToken ([bool]$SessionLockHeld)
}
function Invoke-TCManifestConnectionSwitch {
    param([string]$ManifestPath,$Intent,[switch]$SessionLockHeld)
    $module=Get-TCConnectionTransactionModule
    & $module {param($DataRoot,$Path,$Desired,$Held) Invoke-CTSessionSwitch -Root $DataRoot -ManifestPath $Path -Intent $Desired -SessionLockHeld $Held} $script:Root $ManifestPath $Intent ([bool]$SessionLockHeld)
}
function Get-TCConnectionRuntimeObserved {
    $e=Get-TCSessionEvidence;$i=$e.Identity;$s=$e.Snapshot
    $o=Get-TCSessionPresentation -Evidence $e -Preferences (Get-TCPreferences)
    $known=[bool]($i -and -not $i.Untracked -and -not $e.Fault)
    $state=if($known -and -not $i.SessionPresent -and -not $s.CleanupError){'Stopped'}elseif($known -and $o.Running){'Running'}else{'Unknown'}
    [pscustomobject]@{State=$state;OwnershipKnown=($known -and $state -ne 'Unknown');SessionId=$s.SessionId;SupervisorPid=$s.SupervisorPid;SupervisorStartedAt=$s.SupervisorStartedAt;EnginePid=$s.EnginePid;EngineStartedAt=$s.EngineStartedAt;ManifestPath=$e.Deployment.ManifestPath;CandidateSHA256=$(if($e.Manifest -and [IO.File]::Exists($e.Manifest.CandidatePath)){(Get-FileHash -LiteralPath $e.Manifest.CandidatePath -Algorithm SHA256).Hash}else{$null});Mode=$o.Mode;Exit=$o.Exit;Daily=$o.Daily;DailySupported=$o.DailySupported;Agents=$o.Agents;AgentsSupported=$o.AgentsSupported;AgentState=$e.AgentState;Guard=$e.Guard;Overview=$o}
}
function Assert-TCConnectionIntent {
    param($Manifest,$Intent,[string]$ProfileId,[string]$LineId)
    if($Intent.Mode -notin @('Trading','Global') -or $Intent.Exit -notin @('HongKong','Provider') -or $Intent.Daily -notin @('Direct','Provider') -or $Intent.Agents -notin @('Daily','Trade')){throw '连接意图包含无效模式或出口。'}
    $null=Get-TCAgentSelection $Intent
    $cfg=Get-Content -LiteralPath $Manifest.CandidatePath -Raw -Encoding UTF8|ConvertFrom-Json
    $mode=if($Intent.Mode -eq 'Global'){'global'}else{'rule'}
    if(-not @($cfg.outbounds|Where-Object {$_.type -eq 'selector' -and $_.tag -eq 'trade-exit'}).Count -and $Intent.Exit -eq 'Provider'){throw '候选配置不支持所选交易备用。'}
    if($Intent.Exit -eq 'Provider'){
        $id=if($Intent.TradeProviderId){$Intent.TradeProviderId}else{$Intent.ProviderId}
        if(-not $id -or -not (Resolve-TCProviderTarget $Manifest $id -ForTrade)){throw '候选配置缺少所选交易备用身份。'}
    }
    if($Intent.Daily -eq 'Provider'){
        if(-not $Intent.ProviderId -or -not (Resolve-TCProviderTarget $Manifest $Intent.ProviderId)){throw '候选配置缺少所选日常服务商身份。'}
        if(-not @($cfg.outbounds|Where-Object tag -eq 'daily-exit').Count){throw '候选配置不支持日常出口。'}
    }
    if(($Intent.Agents -eq 'Trade' -or @($Intent.AgentCustom).Count -or @($Intent.AgentIds).Count) -and -not @($cfg.route.rules|Where-Object {$_.'rule_set' -contains 'tc-agents'}).Count){
        # Legacy configs have no assistant selector; empty legacy intent is OK.
        if($Intent.Agents -eq 'Trade' -or @($Intent.AgentCustom).Count){throw '候选配置不支持当前 AI 分流意图。'}
    }
    # Validate the diagnostic path before stopping even a legacy manifest-only
    # session. A schema failure must never be discovered after disconnection.
    $null=Assert-TCConnectionProbeRoute -Manifest $Manifest -ProfileId $ProfileId
    if($ProfileId){
        if($Intent.Exit -ne 'HongKong'){throw '[TC:ProfileExitUnverified] 连接方式切换的目标交易出口必须为 HongKong/hk。'}
        return [pscustomobject]@{ExitEvidence=(Get-TCConnectionServerExitEvidence -Manifest $Manifest -LineId $LineId)}
    }
}
function Get-TCConnectionExpectedSelection {
    param($Manifest,$Intent,$Expected)
    $mode=if($Intent.Mode -eq 'Global'){'global'}else{'rule'};$exit='hk';$daily='direct'
    if($Intent.Exit -eq 'Provider'){$id=if($Intent.TradeProviderId){$Intent.TradeProviderId}else{$Intent.ProviderId};$exit=(Resolve-TCProviderTarget $Manifest $id -ForTrade).Tag}
    if($Intent.Daily -eq 'Provider'){$daily=(Resolve-TCProviderTarget $Manifest $Intent.ProviderId).Tag}
    if($Expected){if($Expected.Mode){$mode=$Expected.Mode};if($Expected.Exit){$exit=$Expected.Exit};if($Expected.Daily){$daily=$Expected.Daily}}
    [pscustomobject]@{Mode=$mode;Exit=$exit;Daily=$daily}
}
function Set-TCConnectionIntent {
    param($Payload)
    $wanted=Get-TCConnectionExpectedSelection $Payload.Manifest $Payload.Intent $Payload.Expected
    if($Payload.ProfileId -and ($Payload.Intent.Exit -ne 'HongKong' -or $wanted.Exit -ne 'hk')){throw '[TC:ProfileExitUnverified] 连接方式切换不能将目标交易出口应用为服务商。'}
    $o=Get-TCOverview;if(-not $o.Running){throw '会话尚未就绪，不能应用原意图。'}
    if($o.Exit -ne $wanted.Exit){$null=Invoke-TCController $Payload.Manifest '/proxies/trade-exit' 'PUT' @{name=$wanted.Exit}}
    if($o.Mode -ne $wanted.Mode){$null=Invoke-TCCommand $(if($wanted.Mode -eq 'global'){'Global'}else{'Trading'})}
    if($o.DailySupported -and $o.Daily -ne $wanted.Daily){
        if($Payload.Expected){$null=Invoke-TCController $Payload.Manifest '/proxies/daily-exit' 'PUT' @{name=$wanted.Daily}}
        else{$null=Invoke-TCCommand ('Daily'+$Payload.Intent.Daily)}
    }
    if($o.AgentsSupported){$null=Invoke-TCCommand Agents}
    $o=Get-TCOverview
    if(-not $o.Running -or $o.Mode -ne $wanted.Mode -or $o.Exit -ne $wanted.Exit -or ($o.DailySupported -and $o.Daily -ne $wanted.Daily)){throw '模式或交易/日常出口实际回读不符合原意图。'}
    if($o.AgentsSupported -and -not (Test-TCAgentApplied (Read-TCAgentState $script:Root) (Get-TCAgentSelection $Payload.Intent))){throw 'AI 分流实际回读不符合原意图。'}
    $o
}
function Get-TCProbePrefixMatch {
    param([string]$Pattern,[string]$ProbePath)
    # Only the shared Go/.NET literal directory-prefix subset is evaluated.
    # Arbitrary regex syntax, including lookarounds, stays unknown.
    if(-not $Pattern.StartsWith('(?i)^',[StringComparison]::Ordinal) -or $Pattern.Length -gt 4096){return -1}
    $body=$Pattern.Substring(5);$literal=New-Object Text.StringBuilder
    for($n=0;$n -lt $body.Length;$n++){
        $c=[string]$body[$n]
        if($c -eq '\'){
            $n++;if($n -ge $body.Length){return -1}
            $c=[string]$body[$n]
            if('\.+*?[](){}|^$ #'.IndexOf($c) -lt 0){return -1}
        }elseif('.+*?[](){}|^$'.IndexOf($c) -ge 0){return -1}
        $null=$literal.Append($c)
    }
    $prefix=$literal.ToString()
    if($prefix -notmatch '^[A-Za-z]:\\' -or -not $prefix.EndsWith('\')){return -1}
    if($ProbePath.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){return 1};return 0
}
function Get-TCProbeRuleMatch {
    param($Rule,[string]$ProbePath,[int]$Depth=0)
    if(-not $Rule -or $Depth -gt 16){return -1}
    $match=-1
    if($Rule.type -eq 'logical'){
        $children=@($Rule.rules)
        if($children.Count -lt 1 -or $children.Count -gt 128 -or $Rule.mode -notin @('and','or')){return -1}
        $values=@(foreach($child in $children){Get-TCProbeRuleMatch $child $ProbePath ($Depth+1)})
        if($Rule.mode -eq 'and'){if($values -contains 0){$match=0}elseif($values -notcontains -1){$match=1}}
        else{if($values -contains 1){$match=1}elseif($values -notcontains -1){$match=0}}
        if(@($Rule.PSObject.Properties.Name|Where-Object {$_ -notin @('type','mode','rules','invert','action','outbound')}).Count){return -1}
    }elseif(-not $Rule.type -or $Rule.type -eq 'default'){
        $values=New-Object 'Collections.Generic.List[int]'
        if($Rule.inbound){$values.Add([int](@($Rule.inbound) -ccontains 'egress-probe'))}
        if($Rule.auth_user){$values.Add([int](@($Rule.auth_user) -ccontains 'tradechannel-probe'))}
        if($Rule.process_path){$values.Add([int](@($Rule.process_path|Where-Object {[string]::Equals([string]$_,$ProbePath,[StringComparison]::OrdinalIgnoreCase)}).Count -gt 0))}
        if($Rule.process_name){$values.Add([int](@($Rule.process_name|Where-Object {[string]::Equals([string]$_,[IO.Path]::GetFileName($ProbePath),[StringComparison]::OrdinalIgnoreCase)}).Count -gt 0))}
        if($Rule.process_path_regex){
            $regexValues=@(foreach($pattern in @($Rule.process_path_regex)){Get-TCProbePrefixMatch ([string]$pattern) $ProbePath})
            $values.Add($(if($regexValues -contains 1){1}elseif($regexValues -contains -1){-1}else{0}))
        }
        if(@($Rule.PSObject.Properties.Name|Where-Object {$_ -notin @('type','invert','action','outbound','inbound','auth_user','process_path','process_name','process_path_regex')}).Count){$values.Add(-1)}
        if($values -contains 0){$match=0}elseif($values -notcontains -1){$match=1}
    }
    if($Rule.invert -and $match -ne -1){$match=1-$match}
    return $match
}
function Assert-TCConnectionProbeRoute {
    param($Manifest,[string]$ProfileId)
    $hash=(Get-FileHash -LiteralPath $Manifest.CandidatePath -Algorithm SHA256).Hash
    if($hash -cne $Manifest.CandidateSHA256){throw '[TC:ProbeRouteUnverified] 诊断配置哈希已变化。'}
    $cfg=Get-Content -LiteralPath $Manifest.CandidatePath -Raw -Encoding UTF8|ConvertFrom-Json
    $inbound=@($cfg.inbounds|Where-Object tag -eq 'egress-probe')
    if($inbound.Count -ne 1 -or $inbound[0].type -ne 'mixed' -or $inbound[0].listen -ne '127.0.0.1' -or -not $inbound[0].users[0].password){throw '[TC:ProbeRouteUnverified] 主诊断入口不是已认证的 IPv4 回环入口。'}
    $users=@($inbound[0].users|Where-Object username -ceq 'tradechannel-probe')
    if($users.Count -ne 1 -or -not $users[0].password){throw '[TC:ProbeRouteUnverified] 缺少唯一 tradechannel-probe 用户；不使用其他认证用户替代。'}
    # The executor uses this exact Windows curl binary, not PATH resolution.
    $probePath=Join-Path ([Environment]::GetFolderPath('System')) 'curl.exe'
    if(-not [IO.File]::Exists($probePath)){throw '[TC:ProbeRouteUnverified] 缺少用于绑定诊断身份的 Windows curl。'}
    $routeVerified=$false
    foreach($rule in @($cfg.route.rules)){
        # Ignore only rules provably excluding this inbound or this exact user.
        # Unknown/logical/conditional rules before the terminal probe route are
        # not proof of a safe route, even if trade-exit appears farther below.
        if((Get-TCProbeRuleMatch $rule $probePath) -eq 0){continue}
        $unknown=@($rule.PSObject.Properties.Name|Where-Object {$_ -notin @('inbound','auth_user','action','outbound','invert','type')})
        if($unknown.Count -or $rule.invert -or ($rule.type -and $rule.type -ne 'default') -or ($rule.action -and $rule.action -ne 'route') -or $rule.outbound -cne 'trade-exit'){throw '[TC:ProbeRouteUnverified] 无法证明 tradechannel-probe 的首个实际路由为 trade-exit。'}
        $routeVerified=$true;break
    }
    if(-not $routeVerified){throw '[TC:ProbeRouteUnverified] 主诊断入口缺少明确的 trade-exit 路由。'}
    $selector=@($cfg.outbounds|Where-Object tag -eq 'trade-exit')
    if($selector.Count -ne 1 -or $selector[0].type -ne 'selector' -or $selector[0].outbounds -cnotcontains 'hk'){throw '[TC:ProbeRouteUnverified] trade-exit 不是包含 hk 的唯一选择器。'}
    if($ProfileId){
        $hk=@(@($cfg.endpoints)+@($cfg.outbounds)|Where-Object tag -eq 'hk')
        if($hk.Count -ne 1 -or $hk[0].type -ne 'wireguard' -or @($hk[0].peers).Count -ne 1 -or -not $Manifest.ServerPublicKey -or $hk[0].peers[0].public_key -cne $Manifest.ServerPublicKey){throw '[TC:ProfileExitUnverified] hk 不是绑定已知服务器公钥的唯一 WireGuard endpoint。'}
        if($ProfileId -eq 'Udp' -and $hk[0].detour){throw '[TC:ProfileExitUnverified] UDP profile 含有其他传输 detour。'}
        if($ProfileId -eq 'Tcp'){
            $transport=@($cfg.outbounds|Where-Object tag -eq 'tc-transport')
            if($hk[0].detour -cne 'tc-transport' -or $transport.Count -ne 1 -or $transport[0].type -ne 'vless' -or $transport[0].detour -or -not $transport[0].tls.enabled -or -not $transport[0].tls.reality.enabled){throw '[TC:ProfileExitUnverified] TCP profile 未通过自建 WireGuard → VLESS/Reality 路径核验。'}
        }
    }
    [pscustomobject]@{Inbound='egress-probe';AuthUser='tradechannel-probe';Outbound='trade-exit';RouteVerified=$true;SelfHostedEndpointVerified=[bool]$ProfileId;CandidateSHA256=$hash;ProbeExecutablePath=$probePath}
}
function Get-TCConnectionServerExitEvidence {
    param($Manifest,[string]$LineId)
    $path=Join-Path $script:Root 'servers\registry.json';$hash=$null;$found=@()
    if([IO.File]::Exists($path)){
        $hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        $registry=Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json
        if($registry.SchemaVersion -ne 1 -or $registry.Servers -isnot [array]){throw '[TC:ExitBindingUnverified] 服务器台账格式无法核实。'}
        $ids=@($LineId,$Manifest.TCLineId,$Manifest.TCManagedNodeId,$Manifest.nodeGuid)|Where-Object {$_}
        foreach($server in @($registry.Servers)){
            $linked=@($server.LinkedNodeIds|Where-Object {$ids -contains $_}).Count -gt 0
            if($linked -and (-not $server.ServerPublicKey -or $server.ServerPublicKey -cne $Manifest.ServerPublicKey)){throw '[TC:ExitBindingUnverified] 关联台账的服务器公钥与 profile 冲突。'}
            if($Manifest.ServerPublicKey -and $server.ServerPublicKey -ceq $Manifest.ServerPublicKey){$found+=,$server}
        }
        if($found.Count -gt 1){throw '[TC:ExitBindingUnverified] 服务器出口台账存在身份歧义。'}
    }
    if($found.Count -eq 1 -and $found[0].ExpectedExitSource -ceq 'ServerVerifiedTlsTrace'){
        $ip=$null
        if(-not [Net.IPAddress]::TryParse([string]$found[0].ExpectedExitIPv4,[ref]$ip) -or $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork){throw '[TC:ExitBindingUnverified] 权威服务器出口观测不是有效 IPv4。'}
        return [pscustomobject]@{Source='ServerVerifiedTlsTrace';Authoritative=$true;ExpectedExitIPv4=$ip.ToString();ServerPublicKey=$Manifest.ServerPublicKey;ServerRecordId=$found[0].LocalRecordId;RegistrySHA256=$hash;ObservedAt=$found[0].LastCheckedUtc;Message='出口需匹配已绑定服务器的 TLS trace 观测。'}
    }
    $hostAddress=$null;$ip=$null
    try{$hostAddress=([Uri]('udp://'+$Manifest.ServerEndpoint)).DnsSafeHost}catch{}
    $expected=$null;if($hostAddress -and [Net.IPAddress]::TryParse($hostAddress,[ref]$ip) -and $ip.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork){$expected=$ip.ToString()}
    [pscustomobject]@{Source='ConfiguredEndpoint';Authoritative=$false;ExpectedExitIPv4=$expected;Endpoint=$Manifest.ServerEndpoint;ServerPublicKey=$Manifest.ServerPublicKey;RegistrySHA256=$hash;Message='仅按配置服务器端点推定；未取得权威服务器出口观测，公网归属不保证。'}
}
function Invoke-TCConnectionTraceProbe {
    param([string]$Url)
    & (Join-Path $script:Package 'runtime\Test-SelectedTradeExit.ps1') -Lane Trade -Url $Url
}
function Test-TCConnectionExitEvidence {
    param($Payload)
    Assert-TCRealRuntimeContext
    $wanted=Get-TCConnectionExpectedSelection $Payload.Manifest $Payload.Intent $Payload.Expected
    if($Payload.ProfileId -and ($Payload.Intent.Exit -ne 'HongKong' -or $wanted.Exit -ne 'hk')){throw '[TC:ProfileExitUnverified] 服务商出口不能作为所选连接方式的验证证据。'}
    $probe=Assert-TCConnectionProbeRoute -Manifest $Payload.Manifest -ProfileId $Payload.ProfileId
    $binding=if($Payload.ProfileId){Get-TCConnectionServerExitEvidence -Manifest $Payload.Manifest -LineId $Payload.LineId}else{[pscustomobject]@{Source='SelectedTradeExit';Authoritative=$false;ExpectedExitIPv4=$null}}
    $before=Get-TCConnectionRuntimeObserved
    if($before.State -ne 'Running' -or $before.Mode -ne $wanted.Mode -or $before.Exit -ne $wanted.Exit -or $before.CandidateSHA256 -cne $probe.CandidateSHA256){throw '实际出口选择或正在运行的配置哈希与预期不符。'}
    $address=Invoke-TCConnectionTraceProbe 'https://1.1.1.1/cdn-cgi/trace'
    $dns=Invoke-TCConnectionTraceProbe 'https://www.cloudflare.com/cdn-cgi/trace'
    $site=$null;try{$site=Invoke-TCConnectionTraceProbe 'https://www.tradingview.com/'}catch{}
    $after=Get-TCConnectionRuntimeObserved
    if($after.State -ne 'Running' -or $after.SessionId -ne $before.SessionId -or $after.EnginePid -ne $before.EnginePid -or $after.EngineStartedAt -ne $before.EngineStartedAt -or $after.SupervisorPid -ne $before.SupervisorPid -or $after.SupervisorStartedAt -ne $before.SupervisorStartedAt -or $after.ManifestPath -ne $before.ManifestPath -or $after.Mode -ne $wanted.Mode -or $after.Exit -ne $wanted.Exit -or $after.CandidateSHA256 -cne $probe.CandidateSHA256 -or (Get-FileHash -LiteralPath $Payload.Manifest.CandidatePath -Algorithm SHA256).Hash -cne $probe.CandidateSHA256){throw '外网验证期间会话身份、配置哈希或出口发生变化。'}
    $ip=$null;$dnsIP=$null
    $addressPassed=[bool]($address.CurlExit -eq 0 -and $address.HTTPStatus -eq 200 -and [Net.IPAddress]::TryParse([string]$address.ObservedIP,[ref]$ip))
    $dnsPassed=[bool]($dns.CurlExit -eq 0 -and $dns.HTTPStatus -eq 200 -and [Net.IPAddress]::TryParse([string]$dns.ObservedIP,[ref]$dnsIP))
    $consistent=[bool]($addressPassed -and $dnsPassed -and $ip.ToString() -eq $dnsIP.ToString())
    $match=[bool]($consistent -and $ip.ToString() -eq $binding.ExpectedExitIPv4)
    $verified=[bool]($consistent -and (-not $binding.Authoritative -or $match))
    [pscustomobject]@{ExitHttp=$addressPassed;ObservedIP=$address.ObservedIP;DnsHttps=$dnsPassed;ExitVerified=$verified;ProfileValidated=[bool]($Payload.ProfileId -and $verified -and $after.Exit -eq 'hk' -and $probe.SelfHostedEndpointVerified);ProfileId=$Payload.ProfileId;ActualExit=$after.Exit;Mode=$after.Mode;ExitSource=$binding.Source;ExitAttribution=$(if($binding.Authoritative){'ServerVerifiedTlsTrace'}elseif($Payload.ProfileId){'InferredNotAuthoritative'}else{'SelectedTradeExit'});ServerAttributionVerified=[bool]($binding.Authoritative -and $match);ExpectedExitIPv4=$binding.ExpectedExitIPv4;ConfiguredEndpointMatch=$match;ServerPublicKey=$Payload.Manifest.ServerPublicKey;ServerRecordId=$binding.ServerRecordId;Code=$(if(-not $consistent){'TraceFailedOrInconsistent'}elseif($binding.Authoritative -and -not $match){'ServerExitMismatch'}elseif($Payload.ProfileId -and -not $binding.Authoritative){'ConfiguredEndpointInference'}else{'ForwardingPassed'});Message=$binding.Message;ProbeRoute=$probe;TradingViewHttp=[bool]($site -and $site.CurlExit -eq 0 -and $site.HTTPStatus -eq 200);ApplicationValidation=$(if($site -and $site.CurlExit -eq 0 -and $site.HTTPStatus -eq 200){'Reached'}elseif($site -and $site.HTTPStatus -in @(403,401,302)){'UserVerificationRequired'}else{'Inconclusive'});ExitChecks=@($address,$dns);DnsCheck=$dns;Observed=$after}
}
function Invoke-TCConnectionRuntime {
    param([ValidateSet('Preflight','ReadBoundary','Observe','Preferences','ValidateIntent','StopOriginal','StopOwnedCandidate','Start','ApplyIntent','Verify')][string]$Operation,[string]$Root,$Payload)
    Assert-TCRealRuntimeContext
    $savedRoot=$script:Root
    try{
        # Legacy runtime diagnostic scripts still use the installed root. Refuse
        # a different real root rather than inspecting or operating another one.
        if(-not (Test-TCSamePath $Root $savedRoot)){throw '实际运行桥接只接受当前产品数据根；隔离测试必须使用模块私有适配器。'}
        switch($Operation){
            'ReadBoundary'{return}
            'Preflight'{if(Test-TCNinjaRunning){throw '请先退出 NinjaTrader 整个控制中心，再确认切换；当前连接未改变。'};return}
            'Observe'{return Get-TCConnectionRuntimeObserved}
            'Preferences'{return Get-TCPreferences}
            'ValidateIntent'{return Assert-TCConnectionIntent $Payload.Manifest $Payload.Intent $Payload.ProfileId $Payload.LineId}
            {$_ -in @('StopOriginal','StopOwnedCandidate')}{return Invoke-TCCommand Disconnect}
            'Start'{return Invoke-TCCommand Connect}
            'ApplyIntent'{return Set-TCConnectionIntent $Payload}
            'Verify'{return Test-TCConnectionExitEvidence $Payload}
        }
    }finally{$script:Root=$savedRoot}
}
Export-ModuleMember -Function Get-TCProductPaths,Get-TCClientInspection,Get-TCOverview,Get-TCInstalledDeployment,Get-TCPreferences,Save-TCPreferences,Get-TCSessionPresentation,Invoke-TCSession,Invoke-TCCommand,Test-TCActiveConnection,Enable-TCNode,Remove-TCClientProtection,Update-TCActivePolicy,Get-TCAgentOverview,Initialize-TCIsolatedReadContext
