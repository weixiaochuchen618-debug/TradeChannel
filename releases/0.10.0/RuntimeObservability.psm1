#requires -Version 5.1
Set-StrictMode -Version 2
$script:TCEventLimit=200
function Get-TCObservationValue { param($Object,[string]$Name,$Default=$null) if($null -ne $Object -and $Object.PSObject.Properties[$Name]){$Object.$Name}else{$Default} }
function Assert-TCObservationPath {
    param([string]$Path)
    $full=[IO.Path]::GetFullPath($Path);if($full -notmatch '^[A-Za-z]:\\' -or $full.Substring(2) -match '[:*?"<>|\x00-\x1f]'){throw '运行报告只支持本机磁盘路径。'};$cursor=$full
    while($cursor){if(Test-Path -LiteralPath $cursor){if((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw '运行报告路径不能经过重解析点。'}};$parent=[IO.Path]::GetDirectoryName($cursor);if($parent -eq $cursor){break};$cursor=$parent};$full
}
function Read-TCEventJournal {
    param([string]$Root)
    $path=Assert-TCObservationPath (Join-Path $Root 'runtime-events.json')
    if(-not [IO.File]::Exists($path)){return [pscustomobject]@{SchemaVersion=1;Events=@()}}
    if((Get-Item -LiteralPath $path).Length -gt 524288){throw '运行事件记录超过安全上限。'}
    $j=[IO.File]::ReadAllText($path)|ConvertFrom-Json
    if($j.SchemaVersion -ne 1 -or @($j.Events).Count -gt $script:TCEventLimit){throw '运行事件记录格式不受支持。'}
    $typed=@(foreach($e in @($j.Events)){
        $date=[DateTimeOffset]::MinValue
        if($e.Id -cnotmatch '^[0-9a-f]{32}$' -or $e.SessionId -cnotmatch '^[A-Za-z0-9_-]{1,80}$' -or -not [DateTimeOffset]::TryParse([string]$e.AtUtc,[ref]$date) -or $e.Type -notin @('SessionStarting','SessionReady','SessionStopped','SessionFault','DailyExitChanged','ForeignTunnelChanged','ProxyNormalized','TransientReadError','ConfigurationRestored','TradeExitChanged','ModeChanged','GuardChanged','StateObserved')){throw '运行事件记录包含无效字段。'}
        $data=@{};foreach($p in $e.Data.PSObject.Properties){$data[$p.Name]=$p.Value};$clean=ConvertTo-TCRuntimeEventData $data
        $dedup=[string](Get-TCObservationValue $e 'DedupKey' '');if($dedup -and $dedup -cnotmatch '^[A-Za-z0-9:_-]{1,120}$'){throw '运行事件标识无效。'}
        $source=[string](Get-TCObservationValue $e 'Source' 'RuntimeSupervisor');if($source -notin @('RuntimeSupervisor','RuntimeObserver')){throw '运行事件来源无效。'}
        [pscustomobject]@{Id=$e.Id;AtUtc=$date.ToUniversalTime().ToString('o');SessionId=$e.SessionId;Type=$e.Type;Data=$clean;DedupKey=$dedup;Source=$source}
    });[pscustomobject]@{SchemaVersion=1;Events=$typed}
}
function ConvertTo-TCRuntimeEventData {
    param([hashtable]$Data=@{})
    $clean=[ordered]@{}
    $enums=@{State=@('Starting','Running','Stopping','Disconnected','Stopped','StoppedWithError','Fault','Connected','Connecting','Disconnecting','Unconfigured','Unknown');Code=@('TunnelCheck','DailySync','ProxyCheck','AdapterRead','JournalWrite','ObserverState','EngineExit','ChannelFailure','CleanupFailure');Kind=@('Provider','Unknown','PAC','Manual','Disabled');Reason=@('NotConfigured','ForeignTunnel','ForwardingFailed','Checking','Healthy','Unavailable');GuardState=@('Protected','Unprotected','Unverified','Blocked','Active','Ready','Missing','Unknown','Fault');Mode=@('rule','global','unknown');Previous=@();Target=@()}
    foreach($key in $Data.Keys){
        if($key -in @('Count','Connections')){$value=0L;if(-not [long]::TryParse([string]$Data[$key],[ref]$value) -or $value -lt 0 -or $value -gt 2147483647){throw '运行事件数字无效。'};$clean[$key]=$value}
        elseif($key -eq 'Present'){if($Data[$key] -isnot [bool]){throw '运行事件标志无效。'};$clean[$key]=[bool]$Data[$key]}
        elseif($enums.ContainsKey($key)){$value=[string]$Data[$key];if($key -in @('Previous','Target')){if($value -cnotmatch '^(?:direct|hk|provider(?:[0-9]{1,3})?(?:-trade)?|none|unknown)$'){throw '运行事件出口标签无效。'}}elseif($value -and $value -notin $enums[$key]){throw '运行事件枚举无效。'};$clean[$key]=$value}
        else{throw '运行事件不接受任意字段或秘密资料。'}
    };[pscustomobject]$clean
}
function Add-TCRuntimeEvent {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][string]$SessionId,
        [Parameter(Mandatory=$true)][ValidateSet('SessionStarting','SessionReady','SessionStopped','SessionFault','DailyExitChanged','ForeignTunnelChanged','ProxyNormalized','TransientReadError','ConfigurationRestored','TradeExitChanged','ModeChanged','GuardChanged','StateObserved')][string]$Type,
        [hashtable]$Data=@{},[string]$DedupKey='',[ValidateSet('RuntimeSupervisor','RuntimeObserver')][string]$Source='RuntimeSupervisor')
    $ErrorActionPreference='Stop';$lock=$null
    if($SessionId -cnotmatch '^[A-Za-z0-9_-]{1,80}$' -or ($DedupKey -and $DedupKey -cnotmatch '^[A-Za-z0-9:_-]{1,120}$')){throw '运行事件身份格式无效。'}
    $clean=ConvertTo-TCRuntimeEventData $Data;$full=Assert-TCObservationPath $Root;$null=[IO.Directory]::CreateDirectory($full)
    try{
        $lockPath=Assert-TCObservationPath (Join-Path $full '.runtime-events.lock');$deadline=[DateTime]::UtcNow.AddSeconds(2)
        do{try{$lock=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}catch{if([DateTime]::UtcNow -ge $deadline){throw '运行事件正由另一操作写入。'};Start-Sleep -Milliseconds 25}}while(-not $lock)
        $journal=Read-TCEventJournal $full
        if($DedupKey -and @($journal.Events|Where-Object {$_.SessionId -ceq $SessionId -and $_.Type -ceq $Type -and (Get-TCObservationValue $_ 'DedupKey' '') -ceq $DedupKey}).Count){return $false}
        $event=[pscustomobject][ordered]@{Id=[guid]::NewGuid().ToString('N');AtUtc=[DateTimeOffset]::UtcNow.ToString('o');SessionId=$SessionId;Type=$Type;Data=$clean;DedupKey=$DedupKey;Source=$Source}
        $events=@(@($journal.Events)+@($event)|Select-Object -Last $script:TCEventLimit)
        $path=Assert-TCObservationPath (Join-Path $full 'runtime-events.json');$temp=Assert-TCObservationPath (Join-Path $full 'runtime-events.next.json')
        [IO.File]::WriteAllText($temp,([ordered]@{SchemaVersion=1;Events=$events}|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($false)))
        if([IO.File]::Exists($path)){[IO.File]::Replace($temp,$path,[NullString]::Value)}else{[IO.File]::Move($temp,$path)};$true
    }finally{if($lock){$lock.Dispose()}}
}
function Get-TCRuntimeEvents {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,[string]$SessionId,[ValidateRange(1,200)][int]$Limit=200)
    $journal=Read-TCEventJournal $Root;@($journal.Events|Where-Object {-not $SessionId -or $_.SessionId -ceq $SessionId}|Select-Object -Last $Limit)
}
function Observe-TCRuntimeState {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)]$Overview)
    $ErrorActionPreference='Stop';$lock=$null;$runtimePath=Assert-TCObservationPath (Join-Path $Root 'runtime.json')
    if(-not [IO.File]::Exists($runtimePath) -or (Get-Item -LiteralPath $runtimePath).Length -gt 1048576){return [pscustomobject]@{Observed=$false;Reason='NoSession';NetworkChanged=$false}}
    try{$runtime=[IO.File]::ReadAllText($runtimePath)|ConvertFrom-Json}catch{return [pscustomobject]@{Observed=$false;Reason='InvalidRuntime';NetworkChanged=$false}}
    $sid=[string](Get-TCObservationValue $runtime 'SessionId' '')
    if($sid -cnotmatch '^[A-Za-z0-9_-]{1,80}$'){return [pscustomobject]@{Observed=$false;Reason='LegacySessionWithoutIdentity';NetworkChanged=$false}}
    $running=[bool](Get-TCObservationValue $Overview 'Running' $false)
    if($running){
        $observedStart=[DateTimeOffset]::MinValue;$actualStart=[DateTimeOffset]::MinValue
        $sameStart=([DateTimeOffset]::TryParse([string](Get-TCObservationValue $Overview 'ConnectedSince' ''),[ref]$observedStart) -and [DateTimeOffset]::TryParse([string](Get-TCObservationValue $runtime 'EngineStartedAt' ''),[ref]$actualStart) -and $observedStart -eq $actualStart)
        $manifest=[string](Get-TCObservationValue $Overview 'ManifestPath' '');$runtimeManifest=[string](Get-TCObservationValue $runtime 'ManifestPath' '')
        if(-not $sameStart -or -not $manifest -or -not $manifest.Equals($runtimeManifest,[StringComparison]::OrdinalIgnoreCase) -or (Get-TCObservationValue $runtime 'State' '') -ne 'Running'){return [pscustomobject]@{Observed=$false;Reason='StaleOrUnboundObservation';NetworkChanged=$false}}
    }
    $snapshot=[ordered]@{State=[string](Get-TCObservationValue $Overview 'StateKey' 'Unknown');GuardState=[string](Get-TCObservationValue $Overview 'GuardState' 'Unknown');Mode=$(if($running){[string](Get-TCObservationValue $Overview 'Mode' 'unknown')}else{'unknown'});TradeExit=$(if($running){[string](Get-TCObservationValue $Overview 'Exit' 'unknown')}else{'unknown'})}
    $null=ConvertTo-TCRuntimeEventData @{State=$snapshot.State;GuardState=$snapshot.GuardState;Mode=$snapshot.Mode;Target=$snapshot.TradeExit}
    try{
        $lockPath=Assert-TCObservationPath (Join-Path $Root '.runtime-observer.lock')
        try{$lock=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}catch{return [pscustomobject]@{Observed=$false;Reason='ObserverBusy';NetworkChanged=$false}}
        $path=Assert-TCObservationPath (Join-Path $Root 'runtime-observer.json');$previous=$null
        if([IO.File]::Exists($path)){if((Get-Item -LiteralPath $path).Length -gt 16384){throw '运行观测快照超过上限。'};try{$previous=[IO.File]::ReadAllText($path)|ConvertFrom-Json}catch{throw '运行观测快照损坏，保留原记录。'}}
        if($previous -and ($previous.SchemaVersion -ne 1 -or [int]$previous.Revision -lt 1)){throw '运行观测快照版本无效。'}
        $sameSession=[bool]($previous -and $previous.SessionId -ceq $sid);$revision=$(if($sameSession){[int]$previous.Revision+1}else{1});$added=0
        foreach($field in @('State','GuardState','Mode','TradeExit')){
            if($sameSession -and [string](Get-TCObservationValue $previous.Snapshot $field '') -ceq [string]$snapshot[$field]){continue}
            $type=switch($field){'State'{'StateObserved'};'GuardState'{'GuardChanged'};'Mode'{'ModeChanged'};'TradeExit'{'TradeExitChanged'}}
            $data=@{}
            if($field -eq 'TradeExit'){$data.Target=$snapshot[$field];$data.Previous=$(if($sameSession){[string](Get-TCObservationValue $previous.Snapshot $field 'unknown')}else{'none'})}
            elseif($field -eq 'GuardState'){$data.GuardState=$snapshot[$field]}
            elseif($field -eq 'Mode'){$data.Mode=$snapshot[$field]}
            else{$data.State=$snapshot[$field]}
            $didAdd=Add-TCRuntimeEvent -Root $Root -SessionId $sid -Type $type -Data $data -DedupKey ('observer-'+$type+'-'+$revision) -Source RuntimeObserver;if($didAdd){$added++}
        }
        $temp=Assert-TCObservationPath (Join-Path $Root 'runtime-observer.next.json')
        [IO.File]::WriteAllText($temp,([ordered]@{SchemaVersion=1;SessionId=$sid;Revision=$revision;ObservedAtUtc=[DateTimeOffset]::UtcNow.ToString('o');Snapshot=$snapshot}|ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($false)))
        if([IO.File]::Exists($path)){[IO.File]::Replace($temp,$path,[NullString]::Value)}else{[IO.File]::Move($temp,$path)}
        [pscustomobject]@{Observed=$true;SessionId=$sid;EventsAdded=$added;NetworkChanged=$false}
    }finally{if($lock){$lock.Dispose()}}
}
function Get-TCRuntimeReport {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,$Overview)
    $ErrorActionPreference='Stop';$runtime=$null;$journalError=$null
    $path=Assert-TCObservationPath (Join-Path $Root 'runtime.json')
    if([IO.File]::Exists($path)){if((Get-Item -LiteralPath $path).Length -le 1048576){try{$runtime=[IO.File]::ReadAllText($path)|ConvertFrom-Json}catch{}}}
    if([bool](Get-TCObservationValue $runtime 'EventJournalWarning' $false)){$journalError='监督进程曾遇到运行事件写入失败；时间轴可能不完整。'}
    $sid=[string](Get-TCObservationValue $runtime 'SessionId' '')
    if(-not $sid -and $runtime){$started=[string](Get-TCObservationValue $runtime 'StartedAt' 'unknown');$sha=[Security.Cryptography.SHA256]::Create();try{$sid='legacy-'+([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($started))).Replace('-','').Substring(0,24))}finally{$sha.Dispose()}}
    # Observe terminal state even if an older supervisor has no journal producer.
    if($runtime -and $sid -and (Get-TCObservationValue $runtime 'State' '') -eq 'StoppedWithError'){
        try{$null=Add-TCRuntimeEvent -Root $Root -SessionId $sid -Type SessionFault -Data @{State='StoppedWithError';Code='ChannelFailure'} -DedupKey 'terminal' -Source RuntimeObserver}catch{$journalError='运行事件暂不可写；当前状态仍可查看。'}
    }
    try{$events=@(Get-TCRuntimeEvents -Root $Root)}catch{$events=@();$journalError='运行事件无法读取；未更改原记录。'}
    $duration=$null;$start=[DateTimeOffset]::MinValue;$finish=[DateTimeOffset]::UtcNow
    if([DateTimeOffset]::TryParse([string](Get-TCObservationValue $runtime 'EngineStartedAt' ''),[ref]$start)){
        $finished=[DateTimeOffset]::MinValue;if([DateTimeOffset]::TryParse([string](Get-TCObservationValue $runtime 'FinishedAt' ''),[ref]$finished)){$finish=$finished};$duration=[Math]::Max(0,[Math]::Floor(($finish-$start).TotalSeconds))
    }
    $observed=[bool]$Overview;$running=[bool](Get-TCObservationValue $Overview 'Running' $false)
    $current=[pscustomobject][ordered]@{State=(Get-TCObservationValue $Overview 'StateKey' 'Unknown');RuntimeState=(Get-TCObservationValue $runtime 'State' 'Unknown');SessionId=$sid;DurationSeconds=$duration;ObservedAtUtc=[DateTimeOffset]::UtcNow.ToString('o');
        TradeExit=[pscustomobject]@{Value=(Get-TCObservationValue $Overview 'Exit');Source=$(if($observed -and $running){'ControllerSelector'}else{'Unavailable'});Verified=$false;Note='控制器选择项不能证明实际公网出口；需独立出口测试。'};
        DailyExit=[pscustomobject]@{Value=(Get-TCObservationValue $Overview 'DailyEffective' (Get-TCObservationValue $Overview 'Daily'));Configured=(Get-TCObservationValue $Overview 'DesiredDaily');Reason=(Get-TCObservationValue $Overview 'DailyReason');Source=$(if($observed -and $running){'ControllerAndSupervisor'}else{'Unavailable'});Verified=$false};
        Connections=[pscustomobject]@{Value=(Get-TCObservationValue $Overview 'Connections');Source=$(if($observed -and $running){'Controller'}else{'Unavailable'})};
        Guard=[pscustomobject]@{State=(Get-TCObservationValue $Overview 'GuardState' 'Unknown');Summary=(Get-TCObservationValue $Overview 'GuardSummary' '尚未取得实际保护证据。');Source=$(if($observed){'RuntimeGuardEvidence'}else{'Unavailable'})};
        ForeignTunnel=[pscustomobject]@{Value=(Get-TCObservationValue $Overview 'ForeignTunnel');Source=$(if($observed){'AdapterObservation'}else{'Unavailable'})};
        ProxyEvents=(Get-TCObservationValue $runtime 'ProxyEvents' 0);TransientErrors=(Get-TCObservationValue $runtime 'TransientErrors' 0);Error=$(if((Get-TCObservationValue $runtime 'State' '') -eq 'StoppedWithError'){'通道故障，需查看实际连接和保护状态。'}else{$null})}
    $sessions=@($events|Group-Object SessionId|ForEach-Object {[pscustomobject]@{SessionId=$_.Name;FirstRetainedEventAt=$_.Group[0].AtUtc;LastEventAt=$_.Group[-1].AtUtc;RetainedEventCount=$_.Count;LastType=$_.Group[-1].Type}})
    $labels=@{SessionStarting='开始连接';SessionReady='通道引擎和控制器已就绪';SessionStopped='通道停止';SessionFault='通道故障，保护状态以实际检查为准';DailyExitChanged='日常出口选择变化';ForeignTunnelChanged='外部隧道观测变化';ProxyNormalized='外部系统代理变更已处理';TransientReadError='运行状态读取暂时失败';ConfigurationRestored='线路配置已恢复，尚未自动连接';TradeExitChanged='交易出口选择变化（控制器选择项）';ModeChanged='分流模式变化';GuardChanged='实际保护观测变化';StateObserved='连接状态观测变化'}
    $lines=New-Object 'Collections.Generic.List[string]';$lines.Add('TradeChannel 运行状况');$lines.Add(('当前状态：'+$current.State+'；监督记录：'+$current.RuntimeState));$lines.Add(('保护：'+$current.Guard.Summary));$lines.Add(('交易出口选择：'+[string]$current.TradeExit.Value+'（来源 '+$current.TradeExit.Source+'，未等同公网出口验证）'));$lines.Add(('活动连接：'+[string]$current.Connections.Value+'（来源 '+$current.Connections.Source+'）'));$lines.Add('最近运行事件：')
    foreach($e in @($events|Select-Object -Last 30)){$lines.Add(([string]$e.AtUtc+'  '+[string]$labels[$e.Type]))}
    [pscustomobject][ordered]@{SchemaVersion=1;Current=$current;Sessions=$sessions;Events=$events;SummaryText=($lines.ToArray() -join [Environment]::NewLine);JournalWarning=$journalError;NetworkChanged=$false;Retention=[pscustomobject]@{MaxEvents=200;CurrentLogMaxBytes=4194304;LogFilesPerSession=3;RetainedLogSessions=4};SourceLabels=[pscustomobject]@{ControllerSelector='控制器选择项';Controller='控制器实测计数';RuntimeGuardEvidence='实际运行保护核验';AdapterObservation='网卡观测';Unavailable='未取得证据'}}
}
function Initialize-TCBoundedLogType {
    if('TCBoundedEngineProcess' -as [type]){return}
    Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
public sealed class TCBoundedEngineProcess : IDisposable {
    readonly Process process; readonly object gate = new object(); readonly string path; readonly long maxBytes; readonly int files;
    FileStream log; Thread output; Thread error;
    public int Id { get { return process.Id; } }
    public DateTime StartTime { get { return process.StartTime; } }
    public bool HasExited { get { return process.HasExited; } }
    public string LogPath { get { return path; } }
    public string CollectionError { get; private set; }
    public TCBoundedEngineProcess(string executable, string arguments, string logfile, long limit, int count) {
        path = logfile; maxBytes = limit; files = count;
        log = new FileStream(path,FileMode.CreateNew,FileAccess.Write,FileShare.Read);
        process = new Process(); process.StartInfo = new ProcessStartInfo(executable,arguments);
        process.StartInfo.UseShellExecute = false; process.StartInfo.CreateNoWindow = true;
        process.StartInfo.RedirectStandardOutput = true; process.StartInfo.RedirectStandardError = true;
        try { process.Start(); } catch { log.Dispose(); throw; }
        output = Pump(process.StandardOutput.BaseStream); error = Pump(process.StandardError.BaseStream);
    }
    Thread Pump(Stream source) {
        Thread thread = new Thread(delegate() {
            byte[] buffer = new byte[8192]; int read;
            try { while((read=source.Read(buffer,0,buffer.Length))>0) { if(CollectionError==null) { try { Write(buffer,read); } catch { CollectionError="日志收集失败，继续排空进程输出；原始错误未输出。"; } } } }
            catch { CollectionError="日志收集失败；原始错误未输出。"; }
        }); thread.IsBackground=true; thread.Start(); return thread;
    }
    void Rotate() {
        log.Dispose();
        string oldest=path+"."+(files-1); if(File.Exists(oldest)) File.Delete(oldest);
        for(int i=files-2;i>=1;i--) if(File.Exists(path+"."+i)) File.Move(path+"."+i,path+"."+(i+1));
        File.Move(path,path+".1"); log=new FileStream(path,FileMode.CreateNew,FileAccess.Write,FileShare.Read);
    }
    void Write(byte[] buffer,int length) {
        lock(gate) {
            int offset=0;
            while(offset<length) { if(log.Length>=maxBytes) Rotate(); int size=(int)Math.Min(length-offset,maxBytes-log.Length); log.Write(buffer,offset,size); offset+=size; }
            log.Flush();
        }
    }
    public void Kill() { process.Kill(); }
    public bool WaitForExit(int milliseconds) { bool done=process.WaitForExit(milliseconds); if(done){output.Join(2000);error.Join(2000);} return done; }
    public void Dispose() { if(!process.HasExited) throw new InvalidOperationException("Process must stop before log collector disposal."); output.Join(2000);error.Join(2000); lock(gate){log.Dispose();} process.Dispose(); }
}
'@
}
function Start-TCBoundedEngineProcess {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][string]$Executable,[Parameter(Mandatory=$true)][string]$Arguments,[Parameter(Mandatory=$true)][string]$SessionId,[ValidateRange(16384,4194304)][int]$MaxBytes=4194304)
    if($SessionId -cnotmatch '^[A-Za-z0-9_-]{1,80}$'){throw '日志会话身份无效。'}
    $dir=Assert-TCObservationPath (Join-Path $Root 'logs');$null=[IO.Directory]::CreateDirectory($dir)
    # Only logs written by this collector are retained/pruned. Legacy logs are untouched.
    $prior=@(Get-ChildItem -LiteralPath $dir -File -Filter 'bounded-channel-*.log'|Sort-Object LastWriteTimeUtc -Descending)
    foreach($old in @($prior|Select-Object -Skip 3)){foreach($suffix in @('','.1','.2')){$p=Assert-TCObservationPath ($old.FullName+$suffix);if([IO.File]::Exists($p)){[IO.File]::Delete($p)}}}
    $path=Assert-TCObservationPath (Join-Path $dir ('bounded-channel-'+$SessionId+'.log'));Initialize-TCBoundedLogType
    New-Object TCBoundedEngineProcess($Executable,$Arguments,$path,[long]$MaxBytes,3)
}
Export-ModuleMember -Function Add-TCRuntimeEvent,Get-TCRuntimeEvents,Get-TCRuntimeReport,Observe-TCRuntimeState,Start-TCBoundedEngineProcess
