#requires -Version 5.1
# New pages use a small display-only snapshot and explicit UI intents. Existing
# workers still own every connection/configuration transaction.
$script:WebShell=$null;$script:WebReady=$false;$script:WebFailed=$false;$script:WebLastJson='';$script:WebPage='home'
$script:WebTasks=@();$script:WebTasksAt=[DateTime]::MinValue;$script:WebDialogId='';$script:WebLastDialog=''
$script:WebQuality=$null;$script:WebQualityAt=[DateTime]::MinValue
$script:WebStandby=$null;$script:WebStandbyAt=[DateTime]::MinValue;$script:WebQualityHistory=$null;$script:WebHistoryRequest=''
$script:WebPendingConnection=$null
# Snapshot fields that never change during a session (text catalog and connection
# method list) are projected once and reused. Anything that can change at runtime
# MUST clear this cache, otherwise the page keeps rendering the old values.
$script:WebStaticProjection=$null
# 冷启动打点：只在设置了 TRADECHANNEL_PERF_TRACE 环境变量时写文件，正常启动是空操作。
# 用来把"首屏可见/可操作"变成可测的时刻，而不是靠外部代理值猜。
$script:PerfTraces=@{}
function Write-TCPerfTrace {param([string]$Mark)
 if(-not $env:TRADECHANNEL_PERF_TRACE){return}
 if($script:PerfTraces.ContainsKey($Mark)){return}
 $script:PerfTraces[$Mark]=$true
 try{[IO.File]::AppendAllText($env:TRADECHANNEL_PERF_TRACE,(([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()).ToString()+' '+$Mark+' pid='+$PID+"`r`n"))}catch{}
}
# Single source of truth for the "wait until the trading app exits" budget. The
# snapshot deadline and the timeout check both read this value, so changing it in
# one place keeps the browser countdown and the host timeout identical.
$script:WebPendingBudgetSeconds=300
function GetTCWebPendingBudgetSeconds {return [int]$script:WebPendingBudgetSeconds}
$script:WebConnectionAttempts=@{};$script:WebOrphanRepairRequested=$false;$script:WebStartupTasksDone=$false
$script:WebFormActive=$false;$script:WebParentPage='home';$script:WebAck=0;$script:WebNodeView=''
# 0.20 pairing session. The invitation code itself is never stored here: it is
# handed to the in-memory worker and then only the DPAPI enrollment record keeps
# it. PairEpoch is a generation counter, not a clock (see 0.20 plan §4.4).
$script:PairSession=$null;$script:PairEpoch=0
# 0.20 read-only projection of the 30-minute quality store. Keyed by
# "<line id>|<profile>" and refreshed at most once every 30 seconds, because the
# snapshot is built up to four times per second.
$script:WebQuality30m=@{};$script:WebQuality30mAt=@{}
. (Join-Path $script:PackageRoot 'ui\WebForms.ps1')
. (Join-Path $script:PackageRoot 'ui\WebTools.ps1')
Import-Module (Join-Path $script:PackageRoot 'LineQuality.psm1') -DisableNameChecking
Import-Module (Join-Path $script:PackageRoot 'ProductText.psm1') -DisableNameChecking
Import-Module (Join-Path $script:PackageRoot 'ConnectionMethods.psm1') -DisableNameChecking
Import-Module (Join-Path $script:PackageRoot 'DeploymentStore.psm1') -DisableNameChecking
Import-Module (Join-Path $script:PackageRoot 'UserSettings.psm1') -DisableNameChecking
function WebField {param($Value,[string]$Name,$Default=$null)
 if($Value -is [Collections.IDictionary]){if($Value.Contains($Name)){return $Value[$Name]}}
 elseif($null -ne $Value -and $Value.PSObject.Properties[$Name]){return $Value.$Name};$Default
}
function GetTCWebConnectionAttemptBinding {param($Request)
 if([string](WebField $Request Action '') -cnotin @('ConnectionSwitchCommit','AutoConnectCommit','Session') -or ([string](WebField $Request Action '') -ceq 'Session' -and [string](WebField $Request SessionAction '') -cne 'Connect')){return $null}
 $id=[string](WebField $Request LineId (WebField $Request Id (WebField $script:Prefs NodeId '')))
 $lines=@($script:Nodes|Where-Object {[string](WebField $_ LineId (WebField $_ id '')) -ceq $id})
 if($lines.Count -ne 1){return $null};$line=$lines[0]
 $profileId=[string](WebField $Request ProfileId (WebField (WebField $line SavedConnectionPreference) ProfileId (WebField $line PreferredProfileId '')))
 $profiles=@(WebField $line Profiles @()|Where-Object {[string](WebField $_ Id '') -ceq $profileId})
 if($profiles.Count -ne 1){return $null};$profile=$profiles[0]
 return @{LineId=$id;ProfileId=$profileId;CandidateSHA256=[string](WebField $profile CandidateSHA256 '');ManifestSHA256=[string](WebField $profile ManifestSHA256 '');ProfileRevision=[long](WebField $profile Revision -1);LineRevision=[long](WebField $line Revision -1)}
}
function ConvertTCWebConnectionAttempt {param($Transaction)
 $target=WebField $Transaction Target;$manifest=WebField $target Manifest
 $at=[DateTimeOffset]::MinValue
 if(-not [DateTimeOffset]::TryParse([string](WebField $Transaction UpdatedAt ''),[ref]$at)){return $null}
 # The projection never retains Original snapshots, credentials, paths or the
 # complete transaction in the browser. A failure notice is valid for 1 hour.
 return @{LineId=[string](WebField $Transaction LineId '');TransactionId=[string](WebField $Transaction Id '');RequestId=[string](WebField $Transaction RequestId '');ProfileId=[string](WebField $Transaction ProfileId '');Status=[string](WebField $Transaction Status '');HasFailure=($null -ne (WebField $Transaction Failure));HasFailureKnown=($null -ne $Transaction.PSObject.Properties['Failure']);CandidateSHA256=[string](WebField $target CandidateSHA256 '');ManifestSHA256=[string](WebField $target ManifestSHA256 '');ProfileRevision=[long](WebField $manifest TCProfileRevision -1);LineRevision=(WebField $Transaction LineRevision);AtUtc=$at.ToUniversalTime().ToString('o');ExpiresAtUtc=$at.ToUniversalTime().AddHours(1).ToString('o')}
}
function ReadTCWebConnectionAttempt {param([string]$TransactionId,[string]$LineId='')
 if($TransactionId -cnotmatch '^[a-f0-9]{32}$'){return $null}
 try{
  $root=(Assert-TCDPath $script:Root).TrimEnd('\');$directory=Join-Path $root 'connection-transactions';$path=Join-Path $directory ($TransactionId+'.json')
  # Read only the exact journal under the existing product root. Reparse points
  # and mismatched root/journal identities fail closed instead of exporting data.
  $transaction=Read-TCDJson -Path $path -MaxBytes 4194304
  if((WebField $transaction SchemaVersion 0) -ne 1 -or [string](WebField $transaction Id '') -cne $TransactionId -or [IO.Path]::GetFullPath([string](WebField $transaction Root '')) -ine $root -or [IO.Path]::GetFullPath([string](WebField $transaction JournalPath '')) -ine $path -or ($LineId -and [string](WebField $transaction LineId '') -cne $LineId)){return $null}
  return ConvertTCWebConnectionAttempt $transaction
 }catch{return $null}
}
function UpdateTCWebPersistedConnectionAttemptsUI {
 # Called on authoritative Nodes/connection results, never on every snapshot.
 # If the directory cannot be read completely, omit notices rather than retain
 # a possibly superseded failure. This is display evidence, not deletion proof.
 try{
  $directory=Join-Path $script:Root 'connection-transactions';$attempts=@{}
  if([IO.Directory]::Exists($directory)){
   $files=@(Get-ChildItem -LiteralPath $directory -File -Filter '*.json' -ErrorAction Stop)
   if($files.Count -gt 256){$script:WebConnectionAttempts=@{};return}
   foreach($file in $files){
    if($file.BaseName -cnotmatch '^[a-f0-9]{32}$'){continue}
    $attempt=ReadTCWebConnectionAttempt $file.BaseName
    if(-not $attempt){$script:WebConnectionAttempts=@{};return}
    if(-not $attempt.LineId){continue}
    $previous=$attempts[$attempt.LineId]
    if(-not $previous -or [DateTimeOffset]$attempt.AtUtc -gt [DateTimeOffset]$previous.AtUtc){$attempts[$attempt.LineId]=$attempt}
   }
  }
  $script:WebConnectionAttempts=$attempts
 }catch{$script:WebConnectionAttempts=@{}}
}
function ObserveTCWebConnectionAttempt {param($Job,$Result)
 if([string](WebField $Job Action '') -ceq 'Nodes'){
  if($Result.Ok -and -not $script:Smoke){UpdateTCWebPersistedConnectionAttemptsUI};return
 }
 $binding=WebField $Job ConnectionAttemptBinding
 if(-not $binding){return}
 if(-not $script:Smoke){UpdateTCWebPersistedConnectionAttemptsUI}
 $data=WebField $Result Data;$transaction=WebField $data ConnectionTransaction $data
 $status=[string](WebField $transaction Status '');$id=[string](WebField $transaction TransactionId '')
 if($id -cnotmatch '^[a-f0-9]{32}$' -or $status -cnotin @('Completed','RolledBack','Aborted','NeedsRecovery','ResolvedStopped')){return}
 $lineId=[string](WebField $transaction LineId '');$profileId=[string](WebField $transaction ProfileId '')
 if($lineId -cne $binding.LineId -or $profileId -cne $binding.ProfileId){return}
 $existing=$script:WebConnectionAttempts[$lineId]
 if($existing -and $existing.TransactionId -ceq $id){return} # The journal has the original time/config binding.
 $attempt=$binding.Clone();$attempt.TransactionId=$id;$attempt.RequestId=[string](WebField $Job RequestId '');$attempt.Status=$status;$attempt.HasFailure=($null -ne (WebField $transaction Failure));$attempt.HasFailureKnown=($null -ne $transaction.PSObject.Properties['Failure']);$attempt.AtUtc=[DateTimeOffset]::UtcNow.ToString('o');$attempt.ExpiresAtUtc=[DateTimeOffset]::UtcNow.AddHours(1).ToString('o')
 $script:WebConnectionAttempts[$lineId]=$attempt
}
function GetTCWebRecentConnectionFailure {param($Line,[string]$ProfileId,[DateTimeOffset]$Now=[DateTimeOffset]::UtcNow)
 $id=[string](WebField $Line LineId (WebField $Line id ''));$attempt=$script:WebConnectionAttempts[$id]
 if(-not $attempt -or $attempt.LineId -cne $id -or $attempt.ProfileId -cne $ProfileId -or $attempt.Status -cnotin @('RolledBack','Aborted','NeedsRecovery','ResolvedStopped') -or -not $attempt.HasFailure){return $null}
 $profile=@(WebField $Line Profiles @()|Where-Object {[string](WebField $_ Id '') -ceq $ProfileId})
 if($profile.Count -ne 1 -or $ProfileId -cnotin @('Udp','Tcp')){return $null}
 $candidate=[string](WebField $profile[0] CandidateSHA256 '');$manifest=[string](WebField $profile[0] ManifestSHA256 '')
 if($candidate -cnotmatch '^[A-Fa-f0-9]{64}$' -or $manifest -cnotmatch '^[A-Fa-f0-9]{64}$' -or $attempt.CandidateSHA256 -cne $candidate -or $attempt.ManifestSHA256 -cne $manifest -or [long](WebField $attempt ProfileRevision -1) -lt 0 -or [long]$attempt.ProfileRevision -ne [long](WebField $profile[0] Revision -2)){return $null}
 $revision=WebField $attempt LineRevision
 if($null -ne $revision -and [long]$revision -ne [long](WebField $Line Revision -1)){return $null}
 $at=[DateTimeOffset]::MinValue;$until=[DateTimeOffset]::MinValue
 if(-not [DateTimeOffset]::TryParse([string]$attempt.AtUtc,[ref]$at) -or -not [DateTimeOffset]::TryParse([string]$attempt.ExpiresAtUtc,[ref]$until) -or $at -gt $Now -or $until -le $Now -or $until -gt $at.AddHours(1)){return $null}
 return @{ProfileId=$ProfileId;ExpiresAtUtc=$until.ToUniversalTime().ToString('o')}
}
function GetTCWebLineDeleteAvailability {param($Line,$Overview)
 $id=[string](WebField $Line LineId (WebField $Line id ''));$aliases=@($id)+@(WebField $Line AliasIds @())
 $active=[string](WebField $Overview ActiveLineId (WebField $Overview NodeId ''))
 if((WebField $Overview Running $false) -and $active -cin $aliases){return @{CanDelete=$false;State='InUse';Message='断开后可删除'}}
 if((WebField $Overview ReadState '') -ceq 'Unknown'){return @{CanDelete=$true;State='NeedsCheck';Message='删除前检查使用情况'}}
 return @{CanDelete=$true;State='NeedsCheck';Message='删除前检查使用情况'}
}
function GetTCWebDeleteState {
 $pending=WebField $script:DeployUI RecordDeletePending
 if(-not $pending){return $null}
 $elapsed=if($pending.Phase -eq 'Previewing' -and (WebField $pending WaitClock)){[int]$pending.WaitClock.Elapsed.TotalSeconds}else{0}
 $message=if($elapsed -gt 20){'仍在检查'+$pending.Label+'，已等待 '+$elapsed+' 秒，可以取消等待。'}else{$pending.Message}
 return @{Id=$pending.OperationId;Scope=$pending.Scope;Name=$pending.Name;Phase=$pending.Phase;Message=$message;ElapsedSeconds=$elapsed;CanCancel=($pending.Phase -eq 'Previewing' -and -not $pending.Submitted);CanCheck=($pending.Phase -in @('Blocked','Ready','OutcomeUnknown') -and -not (WebField $pending ResultCheckActive $false));CanRetry=($pending.Phase -eq 'NotApplied' -and -not $pending.Submitted);TransactionIds=@($pending.TransactionIds);Details=[string]$pending.Details}
}
function GetTCWebLastSuccessRecord {
 # 0.22.0 C-R3：快照每秒构建 4 次，成功记录 30 秒读一次就够（方案第 4 条）。
 $now=[DateTimeOffset]::UtcNow
 $cache=if(Get-Variable WebLastSuccessCache -Scope Script -ErrorAction SilentlyContinue){$script:WebLastSuccessCache}else{$null}
 if($cache -and ($now-$cache.At).TotalSeconds -lt 30){return $cache.Record}
 $record=$null
 if(Get-Command Get-TCLastSuccessfulConnection -ErrorAction SilentlyContinue){try{$record=Get-TCLastSuccessfulConnection -Root $script:Root}catch{$record=$null}}
 $script:WebLastSuccessCache=@{At=$now;Record=$record}
 return $record
}
function GetTCWebLastConnectedEvidence {param($Line,$Profile)
 # 0.22.0 C-R3：运行期的成功证据。节点（含别名）、方式、候选哈希、清单哈希四项全等才算数，
 # 这样配置一改就自动回到「未测试」（C3-03）。
 $id=[string](WebField $Line LineId (WebField $Line id ''));$aliases=@($id)+@(WebField $Line AliasIds @())
 $profileId=[string](WebField $Profile Id '')
 if($profileId -cnotin @('Udp','Tcp')){return $null}
 $candidate=[string](WebField $Profile CandidateSHA256 '');$manifest=[string](WebField $Profile ManifestSHA256 '')
 if($candidate -cnotmatch '^[A-Fa-f0-9]{64}$' -or $manifest -cnotmatch '^[A-Fa-f0-9]{64}$'){return $null}
 $at=''
 $record=GetTCWebLastSuccessRecord
 if($record -and [string](WebField $record NodeId '') -cin $aliases -and [string](WebField $record ProfileId '') -ceq $profileId){
  $binding=WebField $record Binding
  if([string](WebField $binding CandidateSHA256 '') -ceq $candidate -and [string](WebField $binding ManifestSHA256 '') -ceq $manifest){$at=[string](WebField $record SucceededAtUtc '')}
 }
 if(-not $at){
  # 方案第 1(b) 条：同一次运行里刚完成、但宿主还没写成功记录的事务。
  $attempts=if(Get-Variable WebConnectionAttempts -Scope Script -ErrorAction SilentlyContinue){$script:WebConnectionAttempts}else{$null}
  $attempt=if($attempts){$attempts[$id]}else{$null}
  if($attempt -and [string]$attempt.LineId -ceq $id -and [string]$attempt.ProfileId -ceq $profileId -and [string]$attempt.Status -ceq 'Completed' -and [string]$attempt.CandidateSHA256 -ceq $candidate -and [string]$attempt.ManifestSHA256 -ceq $manifest){$at=[string]$attempt.AtUtc}
 }
 $stamp=ConvertTCWebUtcStamp $at
 if(-not $stamp){return $null}
 return $stamp
}
function TestTCWebLineInUse {param([string]$Id)
 # 0.22.0 C-R7：只有「运行中 + 交易出口是自建线路 + 就是这条线」才算在用。
 $o=$script:Overview
 if(-not $o -or -not (WebField $o Running $false) -or [string](WebField $o Exit 'hk') -cne 'hk'){return $false}
 $line=@($script:Nodes|Where-Object {(UILineId $_) -ceq $Id})[0]
 if(-not $line){return $false}
 $active=[string](WebField $o ActiveLineId (WebField $o NodeId ''))
 $aliases=@($Id)+@(WebField $line AliasIds @())
 return ($active -cin $aliases)
}
function TestTCWebProviderBackupReturn {param([string]$Id)
 # 0.22.0 C-R8：交易出口被代理软件接管时，原线路仍是 ActiveLineId 但不在用。
 # 这条路径只切换 selector，不重启通道，因此不需要退出 NinjaTrader。
 $o=$script:Overview
 if(-not $o -or -not (WebField $o Running $false) -or [string](WebField $o Exit 'hk') -ceq 'hk'){return $false}
 if(-not (Get-Command CanReturnHongKong -ErrorAction SilentlyContinue) -or -not (CanReturnHongKong)){return $false}
 # 注意：这里不能复用 TestTCWebLineInUse——它按定义排除了代理软件接管的情况。
 $line=@($script:Nodes|Where-Object {(UILineId $_) -ceq $Id})[0]
 if(-not $line){return $false}
 $active=[string](WebField $o ActiveLineId (WebField $o NodeId ''))
 $aliases=@($Id)+@(WebField $line AliasIds @())
 return ($active -cin $aliases)
}
function GetTCWebLineReadiness {param($Line,$Overview,[string]$ProfileId)
 # 0.18.4: the host decides the line label; the browser only renders it. Sources: connection eligibility and the latest test evidence.
 $id=[string](WebField $Line LineId (WebField $Line id ''));$aliases=@($id)+@(WebField $Line AliasIds @())
 $active=[string](WebField $Overview ActiveLineId (WebField $Overview NodeId ''))
 if((WebField $Overview Running $false) -and $active -cin $aliases){
  # 0.22.0 C-R8：交易走代理软件时这条线路仍是 ActiveLineId，但它不在用。
  # 说「使用中」会把「切回此线路」藏起来，用户只能看到灰色的「切换」。
  if([string](WebField $Overview Exit 'hk') -cne 'hk'){return @{State='ProviderBackup';Label='交易暂走代理软件';Reason='切回这条线路不需要重启通道'}}
  return @{State='InUse';Label='使用中';Reason=''}
 }
 $profiles=@(WebField $Line Profiles @());$selected=$null
 foreach($p in $profiles){if($ProfileId -and [string](WebField $p Id '') -ceq $ProfileId){$selected=$p}}
 if(-not $selected){$selected=@($profiles|Where-Object {(WebField $_ PreparationState '') -in @('Ready','Prepared','SyntaxValidated')})|Select-Object -First 1}
 if(-not $selected){return @{State='NeedsAction';Label='需要处理';Reason='还没有可用的连接方式'}}
 $eligibility=$null
 if(Get-Command Get-TCConnectionEligibility -ErrorAction SilentlyContinue){try{$eligibility=Get-TCConnectionEligibility -Line $Line -Profile $selected}catch{$eligibility=$null}}
 if($eligibility -and -not $eligibility.CanConnect){return @{State='NeedsAction';Label='需要处理';Reason=[string]$eligibility.Message}}
 $validation=WebField $selected Validation;$status=[string](WebField $validation Status '')
 if($status -in @('Failed')){return @{State='TestFailed';Label='上次测试未通过';Reason='连接时会自动重试，不通会自动恢复原状态'}}
 if($status -in @('Passed','Recommended') -or [string](WebField (WebField $Line Recommendation) Status '') -ceq 'Recommended'){return @{State='Verified';Label='可用';Reason=''}}
 # 0.22.0 C-R3：每天在用的主线路断开后不该显示「未测试」——运行期的成功记录同样是证据。
 # 失败优先：上面的 Validation=Failed 已经提前返回（C3-04）。
 $connectedAt=GetTCWebLastConnectedEvidence $Line $selected
 if($connectedAt){
  $when=''
  try{$when=([DateTimeOffset]::Parse($connectedAt,[Globalization.CultureInfo]::InvariantCulture)).ToLocalTime().ToString('MM-dd HH:mm')}catch{$when=''}
  return @{State='LastConnected';Label='上次连接正常';Reason=$(if($when){'上次连接于 '+$when}else{'上次连接正常'})}
 }
 $reason=if($status -in @('Inconclusive','Unknown','UserVerificationRequired')){'上次测试没有完成'}else{'还没有测试过'}
 return @{State='Untested';Label='未测试';Reason=$reason}
}
function GetTCWebTestProfileId {param($Line)
 # "Test line" always tests something: the saved method, otherwise the standard method, otherwise compatible.
 $saved=[string](WebField (WebField $Line SavedConnectionPreference) ProfileId '')
 $ready=@(@(WebField $Line Profiles @())|Where-Object {(WebField $_ PreparationState '') -in @('Ready','Prepared','SyntaxValidated')}|ForEach-Object {[string](WebField $_ Id '')})
 if($saved -cin $ready){return $saved}
 if('Udp' -cin $ready){return 'Udp'}
 if('Tcp' -cin $ready){return 'Tcp'}
 return ''
}
function GetTCWebLinePending {param([string]$Id)
 if((Get-Variable LinePreferenceRequests -Scope Script -ErrorAction SilentlyContinue) -and $script:LinePreferenceRequests.ContainsKey($Id)){return 'Saving'}
 if((Get-Variable LineCheckRequests -Scope Script -ErrorAction SilentlyContinue) -and $script:LineCheckRequests.ContainsKey($Id)){return 'Testing'}
 return ''
}
function GetTCWebHomeLineId {
 if(-not (Get-Variable WebHomeLineId -Scope Script -ErrorAction SilentlyContinue)){$script:WebHomeLineId=$null}
 if($null -eq $script:WebHomeLineId){$script:WebHomeLineId='';try{$script:WebHomeLineId=[string](Get-TCHomeLineId -Root $script:Root)}catch{}}
 return $script:WebHomeLineId
}
function SetTCWebHomeLine {param([string]$Id)
 try{$null=Set-TCHomeLineId -Root $script:Root -Id $Id;$script:WebHomeLineId=$Id;Toast '首页会连接这条线路'}catch{Toast '这次没能保存，请重试'}
}
function ConvertTCWebUtcStamp {param($Value)
 # Normalise any host timestamp to ISO8601 UTC. Unparseable values become $null so
 # the browser renders "unknown" instead of a misleading time.
 if($null -eq $Value){return $null}
 if($Value -is [DateTime]){return $Value.ToUniversalTime().ToString('o')}
 if($Value -is [DateTimeOffset]){return ([DateTimeOffset]$Value).ToUniversalTime().ToString('o')}
 $text=[string]$Value
 if(-not $text){return $null}
 $parsed=[DateTimeOffset]::MinValue
 if([DateTimeOffset]::TryParse($text,[ref]$parsed)){return $parsed.ToUniversalTime().ToString('o')}
 return $null
}
function GetTCWebOutcomeCopy {param([string]$Status)
 # Host-side wording for the five connection transaction outcomes. Only
 # RolledBack may claim a restore; the other three must never say 已恢复.
 switch($Status){
  'Completed'{return @{Label='切换已完成';Message='切换已完成，实际出口验证通过。';NextAction='Details'}}
  'RolledBack'{return @{Label='已回到切换前';Message='连接检查未通过，已回到切换前的状态。';NextAction='Details'}}
  'Aborted'{return @{Label='切换没有开始';Message='切换没有开始：原连接、配置和选择都没有改动。';NextAction='Connect'}}
  'ResolvedStopped'{return @{Label='通道已停止';Message='通道已停止，故障记录已结束；当前未连接，也没有自动重连。';NextAction='ChooseLine'}}
  'NeedsRecovery'{return @{Label='结果需要确认';Message='连接结果还需要确认：配置已经还原，但原连接没有恢复，系统也没有自动启动第二个引擎。';NextAction='ReviewOperation'}}
 }
 return @{Label='';Message='';NextAction='Details'}
}
function GetTCWebLastOutcome {param($Line,[string]$ProfileId,[DateTimeOffset]$Now=[DateTimeOffset]::UtcNow)
 # Same preconditions as GetTCWebRecentConnectionFailure (line/method/config
 # binding and the one hour window). This second exit also exposes Status so the
 # browser can render the exact outcome sentence; the old exit is untouched.
 $id=[string](WebField $Line LineId (WebField $Line id ''));$attempt=$script:WebConnectionAttempts[$id]
 if(-not $attempt -or $attempt.LineId -cne $id -or $attempt.ProfileId -cne $ProfileId -or $attempt.Status -cnotin @('Completed','RolledBack','Aborted','NeedsRecovery','ResolvedStopped')){return $null}
 # Only gate the two statuses whose failure invariant is unambiguous. Crashed
 # transactions reconciled to ResolvedStopped/NeedsRecovery (and AbortUnstarted
 # to Aborted) never pass through the in-process catch, so they legitimately
 # have no Failure; an unknown property must not hide the outcome.
 $failureExpected=switch([string]$attempt.Status){'Completed'{$false};'RolledBack'{$true};default{$null}}
 if($null -ne $failureExpected -and [bool](WebField $attempt HasFailureKnown $false) -and [bool](WebField $attempt HasFailure $false) -ne $failureExpected){return $null}
 $profile=@(WebField $Line Profiles @()|Where-Object {[string](WebField $_ Id '') -ceq $ProfileId})
 if($profile.Count -ne 1 -or $ProfileId -cnotin @('Udp','Tcp')){return $null}
 $candidate=[string](WebField $profile[0] CandidateSHA256 '');$manifest=[string](WebField $profile[0] ManifestSHA256 '')
 if($candidate -cnotmatch '^[A-Fa-f0-9]{64}$' -or $manifest -cnotmatch '^[A-Fa-f0-9]{64}$' -or $attempt.CandidateSHA256 -cne $candidate -or $attempt.ManifestSHA256 -cne $manifest -or [long](WebField $attempt ProfileRevision -1) -lt 0 -or [long]$attempt.ProfileRevision -ne [long](WebField $profile[0] Revision -2)){return $null}
 $revision=WebField $attempt LineRevision
 if($null -ne $revision -and [long]$revision -ne [long](WebField $Line Revision -1)){return $null}
 $at=[DateTimeOffset]::MinValue;$until=[DateTimeOffset]::MinValue
 if(-not [DateTimeOffset]::TryParse([string]$attempt.AtUtc,[ref]$at) -or -not [DateTimeOffset]::TryParse([string]$attempt.ExpiresAtUtc,[ref]$until) -or $at -gt $Now -or $until -le $Now -or $until -gt $at.AddHours(1)){return $null}
 $copy=GetTCWebOutcomeCopy ([string]$attempt.Status)
 if($copy.NextAction -ceq 'ReviewOperation'){
  # NeedsRecovery only offers "review the original operation" while such an
  # entry exists; otherwise the honest next step is the diagnostics page.
  $pending=$false
  try{if(Get-Command GetUiPendingOperationViews -ErrorAction SilentlyContinue){$pending=(@(GetUiPendingOperationViews|Where-Object {[string](WebField $_ Kind '') -ceq 'Connection'}).Count -gt 0)}}catch{$pending=$false}
  if(-not $pending){$copy.NextAction='Diagnostics'}
 }
 return @{Status=[string]$attempt.Status;Label=[string]$copy.Label;Message=[string]$copy.Message;NextAction=[string]$copy.NextAction;ExpiresAtUtc=$until.ToUniversalTime().ToString('o')}
}
function GetTCWebOperationKind {param($Entry)
 # Deterministic mapping; anything else (Nodes/Overview/LineQuality reads) never
 # becomes an in-flight operation in the browser.
 if(-not $Entry){return ''}
 $request=WebField $Entry RequestData (WebField $Entry Request $null)
 $action=[string](WebField $Entry Action (WebField $request Action ''))
 $session=[string](WebField $request SessionAction (WebField $Entry SessionAction ''))
 switch($action){
  'Session'{if($session -ceq 'Connect'){return 'Connect'};if($session -ceq 'Disconnect'){return 'Disconnect'};return ''}
  'ConnectionSwitchCommit'{return 'Switch'}
  'AutoConnectCommit'{return 'Switch'}
  'LineProfileCheck'{return 'Test'}
 }
 return ''
}
function NewTCWebOperation {param([string]$Kind,[string]$LineId,[string]$Message,$Started)
 $name=''
 try{
  if($LineId){
   $targets=@($script:Nodes|Where-Object {[string](WebField $_ LineId (WebField $_ id '')) -ceq $LineId})
   if($targets.Count -eq 1){$name=[string](WebField $targets[0] Name '')}
  }
 }catch{$name=''}
 return @{Kind=$Kind;LineId=$LineId;Name=$name;Message=$Message;StartedAtUtc=(ConvertTCWebUtcStamp $Started)}
}
function GetTCWebOperation {
 # Running job first, then the first visible queued job, then a single line test.
 # A queued entry has no start time, so the browser shows "queued" without seconds.
 $job=$null
 if(Get-Variable Job -Scope Script -ErrorAction SilentlyContinue){$job=$script:Job}
 if($job -and -not [bool](WebField $job Silent $false)){
  $kind=GetTCWebOperationKind $job
  if($kind){return (NewTCWebOperation $kind ([string](WebField $job LineId '')) ([string](WebField $job Message '')) (WebField $job Started $null))}
  return $null
 }
 if($job){return $null}
 $queue=$null
 if(Get-Variable JobQueue -Scope Script -ErrorAction SilentlyContinue){$queue=$script:JobQueue}
 $first=@(@($queue)|Where-Object {$_ -and -not [bool](WebField $_ Silent $false)})|Select-Object -First 1
 if($first){
  $kind=GetTCWebOperationKind $first
  if($kind){return (NewTCWebOperation $kind ([string](WebField $first LineId '')) ([string](WebField $first Message '')) $null)}
  return $null
 }
 $checks=$null
 if(Get-Variable LineCheckRequests -Scope Script -ErrorAction SilentlyContinue){$checks=$script:LineCheckRequests}
 if($checks -and @($checks.Keys).Count -eq 1){return (NewTCWebOperation 'Test' ([string]@($checks.Keys)[0]) '' $null)}
 return $null
}
function GetTCWebPendingView {
 # Deadline and remaining seconds are derived from the same budget constant that
 # ContinueTCWebConnection uses, so the browser can never show a different limit.
 $waiting=$script:WebPendingConnection
 if(-not $waiting){return $null}
 $deadline=$null;$remaining=0
 $created=WebField $waiting CreatedAt $null
 if($created -is [DateTime]){
  $due=$created.AddSeconds($script:WebPendingBudgetSeconds)
  $deadline=$due.ToUniversalTime().ToString('o')
  $remaining=[Math]::Max(0,[int][Math]::Floor(($due.ToUniversalTime()-[DateTime]::UtcNow).TotalSeconds))
 }
 return @{Name=[string](WebField $waiting Name '');SessionId=[string](WebField $waiting SessionId '');DeadlineUtc=$deadline;SecondsRemaining=$remaining}
}
function GetTCWebExitEvidence {param($Overview)
 # Always an object: the browser renders four levels without null checks. The
 # degraded validation objects from RuntimeBridge only carry CheckedAt.
 $degraded=@{Verified=$false;Attribution='Unknown';Status='Unknown';Code='';CheckedAtUtc=$null;ObservedIP=$null}
 $validation=WebField $Overview RuntimeValidation $null
 if(-not $validation){return $degraded}
 $verified=$false
 try{$verified=[bool](WebField $validation ServerAttributionVerified $false)}catch{$verified=$false}
 $attribution='Unknown'
 try{$attribution=[string](WebField $validation ExitAttribution 'Unknown')}catch{$attribution='Unknown'}
 $status='Unknown'
 try{$status=[string](WebField $validation Status 'Unknown')}catch{$status='Unknown'}
 $code=''
 try{$code=[string](WebField $validation Code '')}catch{$code=''}
 $stamp=WebField $validation ValidatedAt $null
 if(-not $stamp){$stamp=WebField $validation CheckedAt $null}
 # 0.20: the observed exit address was already produced by the runtime but never
 # projected. It is display-only evidence and stays $null when unreadable.
 $observed=''
 try{$observed=[string](WebField $validation ObservedIP '')}catch{$observed=''}
 return @{Verified=$verified;Attribution=$(if($attribution){$attribution}else{'Unknown'});Status=$(if($status){$status}else{'Unknown'});Code=$code;CheckedAtUtc=(ConvertTCWebUtcStamp $stamp);ObservedIP=$(if($observed){$observed}else{$null})}
}
# ---- 0.20 three-step "add line" pairing --------------------------------------
# The wording table is the single source of truth for both surfaces: the native
# three-step page reads it through GetTCWebPairView, and the legacy WPF mirror
# (ui/OnlinePairingPages.ps1) delegates to GetTCWebPairErrorCopy.
$script:TCPairErrorCopy=[ordered]@{
 'InvalidOnlineInput'=@{Message='这张邀请码不是本产品生成的，请让给你的人重新生成。';Action='重新输入';NextAction='Reenter'}
 'InvalidOnlineCode'=@{Message='邀请码不完整或已损坏，请复制完整的一次性邀请码。';Action='重新输入';NextAction='Reenter'}
 'InvalidOnlineJson'=@{Message='邀请码内容无法识别，请重新复制完整的一次性邀请码。';Action='重新输入';NextAction='Reenter'}
 'InvalidOnlineHost'=@{Message='邀请码里的服务器地址无效，请让管理员重新生成。';Action='重新输入';NextAction='Reenter'}
 'OnlineInviteExpired'=@{Message='邀请码已过期，请让管理电脑重新生成（可以设更长的有效期）。';Action='重新输入';NextAction='Reenter'}
 'InviteConsumed'=@{Message='这张邀请码已经被用过了，请在原申请电脑上重试或索取新码。';Action='重新输入';NextAction='Reenter'}
 'OnlineInviteIdentityMismatch'=@{Message='邀请码与本机原申请不匹配，请使用同一张邀请码重试。';Action='继续加入';NextAction='ContinueJoin'}
 'PairingBusy'=@{Message='本机正在完成这个申请，请稍后再试。';Action='重试';NextAction='Retry'}
 'InvalidDeviceName'=@{Message='这台电脑的名称必须是 1–64 个字符，首尾不能有空格。';Action='修改电脑名称';NextAction='FixName'}
 'OnlineEnrollmentConflict'=@{Message='这台电脑上同一张邀请码已有多份申请，请先恢复原申请再试。';Action='用旧版表单';NextAction='UseLegacyForm'}
 'InvalidOnlineResponse'=@{Message='服务器返回的登记结果无法核对，本次没有登记成功。';Action='重试';NextAction='Retry'}
 'OnlineAuthorizationMismatch'=@{Message='服务器给的授权不属于这台电脑的申请，没有采用。';Action='重试';NextAction='Retry'}
 'InvalidOnlineEnrollment'=@{Message='本机的在线申请记录损坏，需要重新开始一次申请。';Action='用旧版表单';NextAction='UseLegacyForm'}
 'OnlineSourceMissing'=@{Message='这台电脑缺少在线登记所需的组件，请修复安装后重试。';Action='运行诊断';NextAction='Diagnostics'}
 'OnlineSourceTooLarge'=@{Message='在线登记组件超出大小限制，请修复安装后重试。';Action='运行诊断';NextAction='Diagnostics'}
 'InvalidOnlineSshReply'=@{Message='服务器返回的结果无法对应本次邀请码操作，没有采用。';Action='重试';NextAction='Retry'}
 'OnlineOperationFailed'=@{Message='服务器没有完成这次邀请码操作；重试会沿用原申请。';Action='重试';NextAction='Retry'}
 'EnrollmentMismatch'=@{Message='本机保存的申请、密钥或签名身份与服务器返回不一致，没有采用。';Action='重试';NextAction='Retry'}
 'AuthorizationUnavailable'=@{Message='本机没有可恢复的已验签授权，请重新取得一次服务器返回。';Action='重试';NextAction='Retry'}
 'OnlineInvitationUnavailable'=@{Message='这一步没有完成。';Action='重试';NextAction='Retry'}
 'OnlineEnrollmentIncomplete'=@{Message='这台电脑的线路还没有设置完。';Action='继续加入';NextAction='ContinueJoin'}
 'PairJoinUnfinished'=@{Message='这台电脑还没有加入成功，原申请仍保留。请在邀请码有效期内重新粘贴同一张邀请码继续；已过期就请管理电脑重新生成。';Action='重新输入';NextAction='Reenter'}
 # Transport failures arrive as WorkerStepFailed; the sentence is the only
 # honest one when the host never reached the server.
 'WorkerStepFailed'=@{Message='需要联网才能校验邀请码；请检查网络后重试。';Action='重试';NextAction='Retry'}
}
function GetTCWebPairErrorCopy {param([string]$Code,[string]$Detail='')
 $copy=$script:TCPairErrorCopy[$Code]
 if(-not $copy){
  # Unregistered codes keep the raw code in the details expander and never claim
  # the failure was a network problem. A host sentence wins over the fallback.
  $message=if($Detail -and $Detail.Trim()){$Detail.Trim()}else{'这一步没有完成'}
  return @{Message=$message;Action='重试';NextAction='Retry'}
 }
 return $copy
}
function GetTCWebPairStageLabel {param([string]$Phase)
 switch($Phase){
  'Creating'{return '正在确认邀请码'}
  'Authorizing'{return '正在为这台电脑开通线路'}
  'Preparing'{return '正在设置并测试线路'}
  'Complete'{return '线路已加入'}
  'NeedsCheck'{return '线路已保存'}
  'Failed'{return '这一步没有完成'}
 }
 return ''
}
function SetTCWebPairPhase {param([string]$Phase,[string]$Label='')
 $session=$script:PairSession;if(-not $session){return}
 $stamp=[DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ',[Globalization.CultureInfo]::InvariantCulture)
 $session.Phase=$Phase
 $session.StageLabel=if($Label){$Label}else{GetTCWebPairStageLabel $Phase}
 $session.StageChangedAtUtc=$stamp;$session.AtUtc=$stamp
}
function NewTCWebPairSession {param([string]$DeviceName)
 $stamp=[DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ',[Globalization.CultureInfo]::InvariantCulture)
 $script:PairSession=[ordered]@{
  PairId=[guid]::NewGuid().ToString('N');Phase='Idle';StageLabel='';DeploymentCompleteness='Unknown'
  Host='';Port=0;ExpiresAtUtc=$null;DeviceName=[string]$DeviceName;LocalName=''
  ErrorCode='';ErrorMessage='';NextAction='None';AtUtc=$stamp;StageChangedAtUtc=$null
  EnrollmentId='';NodeName=''
 }
 return $script:PairSession
}
function TestTCWebPairContext {param($Context)
 if(-not $Context -or -not $script:PairSession){return $false}
 return ([object]::ReferenceEquals($script:PairSession,(WebField $Context Model $null)) -and [string](WebField $Context Id '') -ceq [string]$script:PairSession.PairId)
}
function ConvertTCWebPairCodePeek {param([string]$Code)
 # Display-only peek at the invitation envelope (host, port, expiry). It is never
 # used to accept or reject a code: the worker in PairingOnline.psm1 owns that.
 # Nothing is persisted and the decoded text is dropped with the local scope.
 if(-not $Code -or $Code.Length -le 5 -or $Code -cnotmatch '^TCI1\.'){return $null}
 try{
  $body=$Code.Substring(5).Replace('-','+').Replace('_','/')
  switch($body.Length % 4){2{$body+='=='}3{$body+='='}}
  $value=([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($body)))|ConvertFrom-Json -ErrorAction Stop
  if($null -eq $value.h -or $null -eq $value.p -or $null -eq $value.e){return $null}
  return @{Host=[string]$value.h;Port=[int]$value.p;ExpiresAtUtc=([DateTimeOffset]::FromUnixTimeSeconds([long]$value.e)).UtcDateTime.ToString('o')}
 }catch{return $null}
}
function GetTCWebPairView {
 # Exactly fifteen keys. The invitation code, the token and the TLS pin never
 # appear here, so a snapshot can be logged without redaction.
 $session=$script:PairSession
 if(-not $session){return $null}
 return [ordered]@{
  PairId=[string](WebField $session PairId '');Epoch=[int]$script:PairEpoch;Phase=[string](WebField $session Phase 'Idle')
  StageLabel=[string](WebField $session StageLabel '');DeploymentCompleteness=[string](WebField $session DeploymentCompleteness 'Unknown')
  Host=[string](WebField $session Host '');Port=[int](WebField $session Port 0);ExpiresAtUtc=(WebField $session ExpiresAtUtc $null)
  DeviceName=[string](WebField $session DeviceName '');LocalName=[string](WebField $session LocalName '')
  ErrorCode=[string](WebField $session ErrorCode '');ErrorMessage=[string](WebField $session ErrorMessage '')
  NextAction=[string](WebField $session NextAction 'None');AtUtc=(WebField $session AtUtc $null);StageChangedAtUtc=(WebField $session StageChangedAtUtc $null)
 }
}
function DenyTCWebPair {param([string]$Message='这一步没有生效，请重试',$Sequence=$null)
 # Every rejected pair message must answer. Without this the browser keeps
 # pendingIntent set, every button on the page stays disabled, and nothing on
 # screen explains why (0.20 plan §5.5).
 if($null -ne $Sequence){
  $value=0
  if(($Sequence -is [int] -or $Sequence -is [long]) -and [long]$Sequence -ge 1 -and [long]$Sequence -le 2147483647){$value=[long]$Sequence}
  if($value -gt $script:WebAck){$script:WebAck=$value;Write-TCPerfTrace 'first-ack'}
 }
 Toast $Message;SyncTCWebState -Force
}
function GetTCWebQuality30m {param($Line,[string]$ProfileId)
 # ControllerUnavailableCount 只统计 ControllerUnavailable 这一种原因——本机引擎
 # 自己没跑起来。DelayUnavailable（出口返回 200 但 /delay 字段不可用）仍然留在
 # UnavailableCount 里，不计入本字段：那是出口侧给不出数，不是本机故障。
 # web/app.js 的「未响应比例」按这个边界剔除本机故障（分子分母都减），改这里必须
 # 同步改前端，否则比例会把引擎故障摊薄成线路失败。
 # Read-only projection of the quality store, independent of "is the engine
 # running": a user who just disconnected must still see the last 30 minutes.
 # Synchronous read with a 30 second TTL (the snapshot is built 4x/second).
 $id=[string](WebField $Line LineId (WebField $Line id ''))
 if(-not $id){return $null}
 $key=$id+'|'+[string]$ProfileId;$now=[DateTime]::UtcNow
 if($script:WebQuality30m.ContainsKey($key)){
  $at=$script:WebQuality30mAt[$key]
  if($at -and ($now-$at).TotalSeconds -lt 30){return $script:WebQuality30m[$key]}
 }
 $view=$null
 try{
  $history=Get-TCLineQualityHistory -Root $script:Root -NodeId @($id) -Window 'ThirtyMinutes'
  $series=@(WebField $history Series @());$picked=$null
  foreach($entry in $series){
   $binding=WebField $entry Binding
   if([string](WebField $binding ProfileId '') -ceq [string]$ProfileId -and [string](WebField $binding Exit '') -ceq 'hk'){$picked=$entry;break}
  }
  if(-not $picked -and $series.Count){$picked=$series[0]}
  if($picked){
   $aggregate=WebField $picked Aggregate;$stats=WebField $aggregate Statistics
   $samples=@(foreach($bucket in @(WebField $aggregate Buckets @())){
    if([int](WebField $bucket MeasuredCount 0) -gt 0){[int](WebField $bucket AverageLatencyMs 0)}else{$null}
   })
   # P50 / P95 逐桶序列：图表用它们画两条线，替代原来那条逐桶平均线。
   # 平均线在少数超时上会被拉高，看不出"平时多快"和"最差多差"的区别。
   # 桶内没有读数时保持 $null，图表按同样的断线规则处理。
   $medians=@(foreach($bucket in @(WebField $aggregate Buckets @())){
    $m=WebField $bucket MedianLatencyMs $null
    if([int](WebField $bucket MeasuredCount 0) -gt 0 -and $null -ne $m){[double]$m}else{$null}
   })
   $p95s=@(foreach($bucket in @(WebField $aggregate Buckets @())){
    $p=WebField $bucket P95LatencyMs $null
    if([int](WebField $bucket MeasuredCount 0) -gt 0 -and $null -ne $p){[double]$p}else{$null}
   })
   $view=@{SampleCount=[int](WebField $stats SampleCount 0);MeasuredCount=[int](WebField $stats MeasuredCount 0);UnavailableCount=[int](WebField $stats UnavailableCount 0);TimeoutCount=[int](WebField $stats TimeoutCount 0);ControllerUnavailableCount=[int](WebField $stats ControllerUnavailableCount 0);Samples=$samples;MedianSamples=$medians;P95Samples=$p95s;MedianLatencyMs=(WebField $stats MedianLatencyMs $null);P95LatencyMs=(WebField $stats P95LatencyMs $null);AtUtc=$now.ToString('yyyy-MM-ddTHH:mm:ssZ',[Globalization.CultureInfo]::InvariantCulture)}
  }
 }catch{$view=$null}
 $script:WebQuality30m[$key]=$view;$script:WebQuality30mAt[$key]=$now
 return $view
}
function StartTCWebPairVerify {param([string]$Code,[string]$DeviceName,[string]$PairId,$Peek=$null)
 $session=$script:PairSession
 if(-not $session){$session=NewTCWebPairSession $DeviceName}else{$session.DeviceName=$DeviceName}
 $session.ErrorCode='';$session.ErrorMessage='';$session.NextAction='None';$session.DeploymentCompleteness='Unknown'
 $session.EnrollmentId='';$session.NodeName='';$session.Host='';$session.Port=0;$session.ExpiresAtUtc=$null
 if($Peek){$session.Host=[string]$Peek.Host;$session.Port=[int]$Peek.Port;$session.ExpiresAtUtc=$Peek.ExpiresAtUtc}
 SetTCWebPairPhase 'Creating'
 $context=@{Model=$session;Id=$session.PairId}
 StartUiCommand -Module 'PairingOnline.psm1' -Command 'New-TCPairOnlineEnrollment' -Arguments @{InvitationCode=$Code;Root=$script:Root;DeviceName=$DeviceName;WgPath=(Join-Path $script:PackageRoot 'assets\wg.exe')} -Context $context -Complete {
  param($data,$inner)
  if(-not (TestTCWebPairContext $inner)){return}
  $inner.Model.EnrollmentId=[string](WebField $data EnrollmentId '')
  $expires=ConvertTCWebUtcStamp (WebField $data ExpiresAtUtc $null)
  if($expires){$inner.Model.ExpiresAtUtc=$expires}
  # The code is confirmed. Waiting for the local line name is the only reason
  # this phase is not called Authorizing progress yet.
  SetTCWebPairPhase 'Authorizing' '邀请码已确认，可以加入这台电脑'
  SyncTCWebState -Force
 } -Failed {
  param($message,$inner,$failure)
  if(-not (TestTCWebPairContext $inner)){return}
  $code=[string](WebField $failure Code 'OnlineInvitationUnavailable')
  $copy=GetTCWebPairErrorCopy $code ([string](WebField $failure Message ''))
  $inner.Model.ErrorCode=$code;$inner.Model.ErrorMessage=[string]$copy.Message;$inner.Model.NextAction=[string]$copy.NextAction
  SetTCWebPairPhase 'Failed'
  SyncTCWebState -Force
 } -Message '正在确认邀请码…'
 $Code=$null
}
function StartTCWebPairJoin {
 $session=$script:PairSession;if(-not $session -or -not $session.EnrollmentId){return}
 SetTCWebPairPhase 'Authorizing'
 $context=@{Type='Pair';Model=$session;Id=$session.PairId}
 StartJob @{Action='PairOnlineFinish';EnrollmentId=$session.EnrollmentId} {
  param($data,$inner)
  if(-not (TestTCWebPairContext $inner) -or [string](WebField $data EnrollmentId '') -cne [string]$inner.Model.EnrollmentId){return}
  $inner.Model.NodeName=[string](WebField $data NodeName '')
  if(-not $inner.Model.LocalName){$inner.Model.LocalName=if($inner.Model.NodeName){$inner.Model.NodeName}else{'加入的线路'}}
  SetTCWebPairPhase 'Preparing'
  SyncTCWebState -Force
  StartJob @{Action='PairComplete';EnrollmentId=$inner.Model.EnrollmentId;Name=$inner.Model.LocalName} {
   param($result,$deep)
   if(-not (TestTCWebPairContext $deep) -or [string](WebField $result EnrollmentId '') -cne [string]$deep.Model.EnrollmentId){return}
   $deep.Model.NodeName=[string](WebField $result NodeName (WebField $deep.Model NodeName ''))
   $complete=[string](WebField $result DeploymentCompleteness '') -ceq 'Complete'
   $deep.Model.DeploymentCompleteness=if($complete){'Complete'}else{'NeedsCheck'}
   $deep.Model.NextAction=if($complete){'None'}else{'ContinueCheck'}
   SetTCWebPairPhase $(if($complete){'Complete'}else{'NeedsCheck'})
   SyncTCWebState -Force
   try{FetchNodes}catch{}
   Toast $(if($complete){'线路已加入'}else{'线路已保存，请完成连接检查'})
  } '正在设置并检查这台电脑的线路…' -CallbackContext $inner -Failed {param($message,$deep,$failure)FailTCWebPair $message $deep $failure 'OnlineEnrollmentIncomplete'} -Finalized {param($notice,$deep)EndTCWebPairTask $notice $deep 'Preparing' 'OnlineEnrollmentIncomplete'}
 } '正在为这台电脑开通线路…' -CallbackContext $context -Failed {param($message,$deep,$failure)FailTCWebPair $message $deep $failure 'OnlineEnrollmentIncomplete'} -Finalized {param($notice,$deep)EndTCWebPairTask $notice $deep 'Authorizing' 'PairJoinUnfinished'}
}
function EndTCWebPairTask {param($Notice,$Context,[string]$Phase,[string]$Code)
 # Runs however a join task's request ends. A result delivered to this page has
 # already moved the phase on; refused before it ran, timed out, or finished
 # while another page was open must not leave the spinner running on nothing.
 if(-not (TestTCWebPairContext $Context) -or [string]$Context.Model.Phase -cne $Phase){return}
 $status=[string](WebField $Notice Status '')
 if($status -ceq 'Completed' -and $Phase -ceq 'Preparing'){$Context.Model.DeploymentCompleteness='NeedsCheck';$Context.Model.NextAction='ContinueCheck';SetTCWebPairPhase 'NeedsCheck';SyncTCWebState -Force;return}
 if($status -cin @('Rejected','Cancelled')){$Code='PairJoinUnfinished'}
 FailTCWebPair '' $Context ([pscustomobject]@{Code=$Code}) $Code
}
function FailTCWebPair {param([string]$Message,$Context,$Failure,[string]$DefaultCode='OnlineInvitationUnavailable')
 if(-not (TestTCWebPairContext $Context)){return}
 $code=[string](WebField $Failure Code $DefaultCode);if(-not $code){$code=$DefaultCode}
 $copy=GetTCWebPairErrorCopy $code ([string](WebField $Failure Message ''))
 $Context.Model.ErrorCode=$code;$Context.Model.ErrorMessage=[string]$copy.Message;$Context.Model.NextAction=[string]$copy.NextAction
 SetTCWebPairPhase 'Failed';SyncTCWebState -Force
}
function ClearTCWebPairSession {param([string]$Toast='已取消这次加入',[switch]$Silent)
 # The session object goes away, the epoch moves, and every in-flight callback
 # becomes inert because TestTCWebPairContext no longer matches. Running jobs are
 # not killed: their completion is simply ignored.
 # -Silent is for the two cases where nothing was cancelled: starting a new join
 # page (0.21.8 A0) and leaving the page after a finished join. A toast there would
 # read as "your line was cancelled" when the line was already added.
 $script:PairSession=$null
 $script:PairEpoch=[int]$script:PairEpoch+1
 if(-not $Silent){Toast $Toast}
 SyncTCWebState -Force
}
function InvokeTCWebPairOnline {param($Message)
 $phase=[string](WebField $Message Phase '');$id=[string](WebField $Message Id '');$sequence=WebField $Message Sequence $null
 switch($phase){
  {$_ -in @('BeginChoose','BeginCode')}{
   # 0.21.8 A0. The two entry buttons of the web page ("＋ 添加线路" and
   # "用邀请码加入") land here instead of navigating directly. A finished session
   # used to live on in $script:PairSession, so every snapshot re-delivered its Pair
   # and the add-line page reopened on the previous result. Starting the page clears
   # it silently. A running join is kept: its callbacks are still live and its
   # progress must stay visible - dropping it would strand the invitation in flight.
   if($script:WebFormActive -and (IsBusy)){DenyTCWebPair '上一步还没有结束，请稍等' $sequence;return}
   $session=$script:PairSession
   if($session -and $session.Phase -in @('Creating','Authorizing','Preparing')){
    Toast '上一条线路还在加入中，完成后可以继续添加'
   }else{
    ClearTCWebPairSession -Silent
   }
   NavigateTCWebPage 'add-line'
   SyncTCWebState -Force;return
  }
  'Verify'{
   if($script:ReadOnly -or (IsBusy)){DenyTCWebPair '这一步没有生效，请重试' $sequence;return}
   $code=[string](WebField $Message Code '');$name=[string](WebField $Message Name '')
   if(-not $name){$name=[Environment]::MachineName}
   $session=$script:PairSession
   if($session -and $session.Phase -in @('Creating','Authorizing','Preparing')){DenyTCWebPair '上一步还没有结束，请稍等' $sequence;return}
   if($session -and $id -and $id -cne [string]$session.PairId){DenyTCWebPair '这一步没有生效，请重试' $sequence;return}
   if($code.Length -gt 2048 -or $code.Trim() -cnotmatch '^TCI1\.[A-Za-z0-9_-]+$'){
    if(-not $session){$session=NewTCWebPairSession $name}
    $copy=GetTCWebPairErrorCopy 'InvalidOnlineCode' ''
    $session.ErrorCode='InvalidOnlineCode';$session.ErrorMessage=[string]$copy.Message;$session.NextAction='Reenter'
    SetTCWebPairPhase 'Failed';Toast '请粘贴完整的一次性邀请码';SyncTCWebState -Force;return
   }
   if($name.Length -gt 64 -or $name.Trim() -cne $name -or $name -match '[\p{C}\p{Zl}\p{Zp}]'){
    if(-not $session){$session=NewTCWebPairSession $name}
    $copy=GetTCWebPairErrorCopy 'InvalidDeviceName' ''
    $session.ErrorCode='InvalidDeviceName';$session.ErrorMessage=[string]$copy.Message;$session.NextAction='FixName'
    SetTCWebPairPhase 'Failed';SyncTCWebState -Force;return
   }
   if($session -and $session.Phase -in @('Complete','NeedsCheck','Failed')){$script:PairEpoch=[int]$script:PairEpoch+1;$session=$null}
   StartTCWebPairVerify $code.Trim() $name $id (ConvertTCWebPairCodePeek $code.Trim())
   SyncTCWebState -Force;return
  }
  'Join'{
   $session=$script:PairSession
   if(-not $session){DenyTCWebPair '这一步没有生效，请重试' $sequence;return}
   if(-not $id -or $id -cne [string]$session.PairId){DenyTCWebPair '这一步没有生效，请重试' $sequence;return}
   if($script:ReadOnly -or (IsBusy)){DenyTCWebPair '这一步没有生效，请重试' $sequence;return}
   if($session.Phase -cne 'Authorizing' -or -not $session.EnrollmentId){DenyTCWebPair '这一步没有生效，请重试' $sequence;return}
   $name=[string](WebField $Message Name '');if(-not $name){$name='加入的线路'}
   if($name.Length -gt 64){$name=$name.Substring(0,64)}
   $session.LocalName=$name;$session.ErrorCode='';$session.ErrorMessage='';$session.NextAction='None'
   StartTCWebPairJoin
   SyncTCWebState -Force;return
  }
  'Cancel'{
   $session=$script:PairSession
   if(-not $session){return} # idempotent: nothing to cancel is a success
   if($id -and $id -cne [string]$session.PairId){DenyTCWebPair '这一步没有生效，请重试' $sequence;return}
   ClearTCWebPairSession '已取消这次加入';return
  }
  'Reset'{
   ClearTCWebPairSession '已清空这次加入';return
  }
 }
 DenyTCWebPair '这一步没有生效，请重试' $sequence
}
function GetTCWebSnapshot {
 $o=$script:Overview
 # 首页「线路响应」必须看交易出口实际在用的线路与连接方式。SavedConnectionPreference
 # 可能是 Auto，而质量库只记解析后的 Udp/Tcp（LineQuality.psm1 用 ActiveProfileId），
 # 'Auto' -ceq 'Udp' 恒假会让下面的匹配落到 $series[0]，把另一套传输的曲线当成这条线路的。
 $active=[string](WebField $o ActiveLineId (WebField $o NodeId ''))
 $activeProfile=[string](WebField $o ActiveProfileId '')
 # $tradeExit 只在这里读一次，投影与下发给前端的 TradeExit 共用它。0.20.5 及以前这里
 # 默认 ''、发布字段默认 'hk'，同一个缺失字段两种解释：前端按自建出口取 ActiveLineId，
 # 宿主却按保存偏好取曲线，两边可能说的不是同一条线/同一套传输。
 $tradeExit=[string](WebField $o Exit 'hk')
 $lines=@(foreach($n in $script:Nodes){
  $id=[string](WebField $n LineId (WebField $n id ''));if(-not $id){continue}
  $profiles=@(WebField $n Profiles @());$saved=WebField $n SavedConnectionPreference
  $profileId=[string](WebField $saved ProfileId (WebField $n PreferredProfileId ''))
  # 0.22.0 A2 line projection: invitation needs exactly one manageable server
  # linked to this line, and the page needs that record's opaque id to preselect
  # it. Computed by a side query on the server registry (cached inside
  # ui/WebInvite.ps1); a snapshot never blocks on disk.
  $inviteBinding=@{CanInvite=$false;ServerRecordId='';ServerName=''}
  if(Get-Command GetTCWebLineInviteBindingUI -ErrorAction SilentlyContinue){try{$inviteBinding=GetTCWebLineInviteBindingUI $id}catch{$inviteBinding=@{CanInvite=$false;ServerRecordId='';ServerName=''}}}
  [pscustomobject]@{Id=$id;Name=[string](WebField $n Name '我的线路');Profile=$profileId;Prepared=(@($profiles|Where-Object {(WebField $_ PreparationState '') -in @('Ready','Prepared','SyntaxValidated')}).Count -gt 0);Readiness=(GetTCWebLineReadiness $n $o $profileId);ProfileSource=[string](WebField $saved Source (WebField $n PreferenceSource ''));AutomaticNeedsCheck=([string](WebField $n PreferenceOutcome '') -ceq 'NeedsCheck' -or (-not $saved -and @($profiles|Where-Object {(WebField $_ PreparationState '') -in @('Ready','Prepared','SyntaxValidated')}).Count -gt 1));PreparedProfiles=@($profiles|Where-Object {(WebField $_ PreparationState '') -in @('Ready','Prepared','SyntaxValidated') -and [string](WebField $_ Id '') -cin @('Udp','Tcp')}|ForEach-Object {[string](WebField $_ Id '')});Pending=(GetTCWebLinePending $id);Feedback=@(if(Get-Command GetLineActionFeedbackViewsUI -ErrorAction SilentlyContinue){GetLineActionFeedbackViewsUI $id});Blocked=[bool](WebField $n ServerConnectionBlock $false);BlockedReason=$(if(WebField $n ServerConnectionBlock $false){[string](WebField $n ServerConnectionMessage '')}else{''});LastOutcome=$(try{GetTCWebLastOutcome $n $profileId}catch{$null});RecentConnectionFailure=(GetTCWebRecentConnectionFailure $n $profileId);DeleteAvailability=(GetTCWebLineDeleteAvailability $n $o);Quality30m=$(try{GetTCWebQuality30m $n $(if($id -ceq $active -and $tradeExit -ceq 'hk' -and $activeProfile){$activeProfile}else{$profileId})}catch{$null});CanInvite=[bool]$inviteBinding.CanInvite;ServerRecordId=[string]$inviteBinding.ServerRecordId;ServerName=[string]$inviteBinding.ServerName}
 })
 $providers=@(foreach($p in @(WebField $script:Providers Items @())){[pscustomobject]@{Id=[string](WebField $p Id '');Name=[string](WebField $p Name '代理软件');Kind=$(switch([string](WebField $p Kind '')){'clashverge'{'Clash Verge'}'batvpn'{'BatVPN'}default{'本机代理'}});Applied=[bool](WebField $p Applied $false);NeedsUpgrade=[bool](WebField $p NeedsUpgrade $false)}})
 $dialog=$null
 if($script:Window.FindName('Overlay').Visibility -eq 'Visible'){
  $key=@($script:Window.FindName('DialogTitle').Text,$script:Window.FindName('DialogBody').Text,$script:Window.FindName('DialogConfirm').Content) -join '|'
  if($key -cne $script:WebLastDialog){$script:WebLastDialog=$key;$script:WebDialogId=[guid]::NewGuid().ToString('N')}
  $dialog=@{Id=$script:WebDialogId;Title=$script:Window.FindName('DialogTitle').Text;Body=$script:Window.FindName('DialogBody').Text;Note=$script:Window.FindName('DialogNote').Text;Confirm=[string]$script:Window.FindName('DialogConfirm').Content;Cancel=$(if($script:Window.FindName('DialogCancel').Visibility -eq 'Visible'){[string]$script:Window.FindName('DialogCancel').Content}else{''});Danger=($script:Window.FindName('DialogConfirm').Style -eq $script:Window.FindResource('Danger'))}
  $dialog.Details=[string](WebField $script:DialogContext Details '');$dialog.Progress=([string](WebField $script:DialogContext CleanupDialog '') -ceq 'PreviewWait')
 }else{$script:WebLastDialog='';$script:WebDialogId=''}
 $quality=$script:WebQuality
 $qualityContext=Get-TCLineQualityContext $o
 $qualityFresh=$false;try{$qualityFresh=($quality -and $quality.SampleAtUtc -and ([DateTimeOffset]::UtcNow-[DateTimeOffset]$quality.SampleAtUtc).TotalSeconds -le 75)}catch{}
 if(-not $qualityContext.Eligible -or -not $qualityFresh -or -not (WebField $o Running $false) -or (WebField $o ReadState '') -ceq 'Unknown' -or ($quality -and [string](WebField $quality BindingKey '') -cne $qualityContext.Key)){$quality=$null}
 if($quality){$quality=@{LatencyMs=$quality.LatencyMs;Quality=$quality.Quality;History=@($quality.History);ThirtyMinutes=(WebField $quality ThirtyMinutes);Day=(WebField $quality Day);Degraded=[bool]$quality.Degraded;NotificationMessage=[string]$quality.NotificationMessage}}
 $standby=$null
 if($script:WebStandby -and $qualityContext.Eligible -and (WebField $script:WebStandby BindingKey '') -ceq $qualityContext.Key){
  $items=@(foreach($entry in @(WebField $script:WebStandby Items @())){
   $binding=WebField $entry Binding;$lineId=[string](WebField $binding NodeId '')
   if(-not @($lines|Where-Object {$_.Id -ceq $lineId -and -not $_.Blocked}).Count){continue}
   $fresh=$false;try{$fresh=([bool](WebField $entry Fresh $false) -and ([DateTimeOffset]::UtcNow-[DateTimeOffset]$entry.SampleAtUtc).TotalSeconds -le 180)}catch{}
   [pscustomobject]@{NodeId=$lineId;LatencyMs=$(if($fresh){$entry.LatencyMs}else{$null});Fresh=$fresh;Reason=[string](WebField $entry Reason '');Source='TcpConnect'}
  })
  $best=@($items|Where-Object Fresh|Sort-Object LatencyMs,NodeId|Select-Object -First 1)
  $standby=@{Items=$items;Recommendation=$(if($best.Count){$best[0]}else{$null})}
 }
 $settings=if(Get-Variable UserSettings -Scope Script -ErrorAction SilentlyContinue){$script:UserSettings}else{@{AutoTrustFirstConnection=$true;AutoConnectOnLogin=$false;QualityWarning=$true}}
 $login=if(Get-Variable LoginAutoConnect -Scope Script -ErrorAction SilentlyContinue){$script:LoginAutoConnect}else{$null}
 $form=$null
 if($script:WebFormActive){$form=GetTCWebFormSnapshot;$form|Add-Member NoteProperty ParentPage $script:WebParentPage -Force;$form|Add-Member NoteProperty ViewKey ([string](WebField $script:ScrollRestoreState ViewKey $script:Page)) -Force}
 $windowPrefs=if(Get-Variable WindowPrefs -Scope Script -ErrorAction SilentlyContinue){$script:WindowPrefs}else{@{CloseBehavior='Tray'}}
 $background=@();if(Get-Command GetDeploymentBackgroundSummaryUI -ErrorAction SilentlyContinue){$background=@(GetDeploymentBackgroundSummaryUI)}
 $canBackground=$false;if(Get-Command TestDeploymentBackgroundAvailableUI -ErrorAction SilentlyContinue){$canBackground=[bool](TestDeploymentBackgroundAvailableUI)}
 $deleteState=GetTCWebDeleteState;$refresh=WebField $script:DeployUI CleanupRefresh
 $deleteRefresh=if($refresh){@{Id=$refresh.OperationId;Phase=$refresh.Phase;Message=$refresh.Message;CanRetry=($refresh.Phase -eq 'Failed')}}else{$null}
 # Every new projection block below swallows its own failure: a single throwing
 # block would fail the whole snapshot and leave the page on the global fallback.
 $snapshotAt=''
 try{$snapshotAt=[DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ',[Globalization.CultureInfo]::InvariantCulture)}catch{$snapshotAt=''}
 $connectedSince=$null
 try{$connectedSince=ConvertTCWebUtcStamp (WebField $o ConnectedSince $null)}catch{$connectedSince=$null}
 $guardSummary=''
 try{$guardSummary=[string](WebField $o GuardSummary '')}catch{$guardSummary=''}
 $pending=$null
 try{$pending=GetTCWebPendingView}catch{$pending=$null}
 $exitEvidence=@{Verified=$false;Attribution='Unknown';Status='Unknown';Code='';CheckedAtUtc=$null;ObservedIP=$null}
 try{$exitEvidence=GetTCWebExitEvidence $o}catch{$exitEvidence=@{Verified=$false;Attribution='Unknown';Status='Unknown';Code='';CheckedAtUtc=$null;ObservedIP=$null}}
 $operation=$null
 try{$operation=GetTCWebOperation}catch{$operation=$null}
 $pair=$null
 try{$pair=GetTCWebPairView}catch{$pair=$null}
 # 0.22.0 A2: the invitation view. It carries no code (see ui/WebInvite.ps1), so a
 # snapshot can be logged without redaction.
 $inviteView=$null
 try{if(Get-Command GetTCWebInviteView -ErrorAction SilentlyContinue){$inviteView=GetTCWebInviteView}}catch{$inviteView=$null}
 # Text catalog and connection methods are session constants; build them once per
 # process instead of copying the whole dictionary on every 250 ms snapshot.
 # If either becomes runtime-mutable (hot reload, live text edit), reset
 # $script:WebStaticProjection or the page will keep the stale values.
 if(-not $script:WebStaticProjection){
  $script:WebStaticProjection=@{
   Text=(Get-TCTextCatalog)
   ConnectionMethods=@(Get-TCConnectionMethods|Select-Object Id,DisplayName,TechnicalName)
  }
 }
 [ordered]@{Text=$script:WebStaticProjection.Text;ConnectionMethods=$script:WebStaticProjection.ConnectionMethods;Version=$script:Version;Ack=$script:WebAck;Form=$form;State=(StateKey);Running=[bool](WebField $o Running $false);Busy=[bool]((IsBusy) -or @($script:JobQueue|Where-Object {$_ -and -not $_.Silent}).Count -or ($deleteState -and $deleteState.Phase -in @('Previewing','Checking','Submitted')));BusyMessage=$(if($deleteState -and $deleteState.Phase -in @('Previewing','Checking','Submitted')){$deleteState.Message}else{[string](WebField $script:Job Message '')});DeleteOperation=$deleteState;DeleteRefresh=$deleteRefresh;PendingOperations=@(if(Get-Command GetUiPendingOperationViews -ErrorAction SilentlyContinue){GetUiPendingOperationViews});ReadOnly=[bool]$script:ReadOnly;NinjaRunning=[bool](WebField $o NinjaRunning $false);PendingConnectionName=[string](WebField $script:WebPendingConnection Name '');NodeName=[string](WebField $o NodeName '');TradeName=$(if(Get-Command TradeLabel -ErrorAction SilentlyContinue){[string](TradeLabel)}else{[string](WebField $o NodeName '')});TradeExit=$tradeExit;ActiveLineId=$active;ActiveProfile=[string](WebField $o ActiveProfileId '');PreferredLineId=[string]$script:Prefs.NodeId;HomeLineId=(GetTCWebHomeLineId);Guard=[string](WebField $o GuardState 'Unknown');TradeProgramCount=$(if($o -and $o.PSObject.Properties['TradePrograms']){@($o.TradePrograms).Count}else{-1});Daily=[string](DailyLaneValue);Agents=$(if(Get-Command AgentLaneValue -ErrorAction SilentlyContinue){[string](AgentLaneValue)}else{[string](WebField $script:Prefs Agents 'Daily')});Lines=$lines;Providers=$providers;Tasks=@($script:WebTasks);Deployments=$background;CanBackground=$canBackground;Quality=$quality;Standby=$standby;QualityHistory=$script:WebQualityHistory;Settings=@{AutoTrustFirstConnection=[bool]$settings.AutoTrustFirstConnection;AutoConnectOnLogin=[bool]$settings.AutoConnectOnLogin;QualityWarning=[bool]$settings.QualityWarning;OpenAtLogin=[bool]$script:Prefs.OpenAtLogin;CloseBehavior=[string](WebField $windowPrefs CloseBehavior 'Tray');Warning=[string](WebField $settings Warning '')};ReadWarning=[string](WebField $o ReadWarning '');AutoConnectNotice=$(if($login -and $login.Status -in @('Skipped','Done') -and $settings.AutoConnectOnLogin -and $login.Reason){'本次未自动连接：'+$login.Reason}else{''});Dialog=$dialog;Toast=$(if(Get-Variable LastToast -Scope Script -ErrorAction SilentlyContinue){[string]$script:LastToast}else{''});SnapshotAtUtc=$snapshotAt;ConnectedSince=$connectedSince;GuardSummary=$guardSummary;Pending=$pending;ExitEvidence=$exitEvidence;Operation=$operation;Pair=$pair
Invite=$inviteView;PairDeviceDefault=[Environment]::MachineName}
}
function SyncTCWebState {param([switch]$Force)
 if(-not $script:WebReady -or ($script:Page -ne 'web' -and -not $script:WebFormActive)){return}
 try{
  $snapshot=GetTCWebSnapshot;$json=@{Type='snapshot';State=$snapshot;Page=$script:WebPage}|ConvertTo-Json -Depth 48 -Compress
  if($Force -or $json -cne $script:WebLastJson){$script:WebShell.CoreWebView2.PostWebMessageAsJson($json);$script:WebLastJson=$json}
 }catch{$script:Footer.Text='新版界面状态暂未刷新，请稍后重试。'}
}
function SuspendTCWebShell {
 SetTCChromeDensity -WebActive $false
 SetTCChromeTheme -Theme 'light'
 $script:WebFormActive=$false
 if($script:WebShell){$script:WebShell.Visibility='Collapsed'}
 $script:Window.FindName('Overlay').Opacity=1;$script:Window.FindName('Overlay').IsHitTestVisible=$true
 $script:Window.FindName('Scroll').Parent.Visibility='Visible';$script:Window.FindName('NavHome').Parent.Visibility='Visible'
}
function ShowTCWebShell {param([ValidateSet('home','lines','apps','settings','add-line','invite')][string]$Page='home')
 if(-not $script:WebReady -or ($script:Smoke -and -not $script:WebFormsFixture) -or $script:WebFailed){return $false}
 $script:WebFormActive=$false;$script:WebParentPage=$Page;$script:WebNodeView=''
 $script:WebPage=$Page;$script:Page='web';$script:Role='client'
 SetNavigationContext 'web' $Page
 $script:Window.FindName('Scroll').Parent.Visibility='Collapsed';$script:Window.FindName('NavHome').Parent.Visibility='Collapsed'
 $script:WebShell.Visibility='Visible';SyncTCWebState -Force
 SetTCChromeDensity -WebActive $true
 $script:Window.FindName('Overlay').Opacity=0;$script:Window.FindName('Overlay').IsHitTestVisible=$false
 return $true
}
function ShowTCWebFormSurface {
 SetTCChromeDensity -WebActive $true
 $script:WebFormActive=$true
 $script:Window.FindName('Scroll').Parent.Visibility='Collapsed';$script:Window.FindName('NavHome').Parent.Visibility='Collapsed'
 $script:Window.FindName('Overlay').Opacity=0;$script:Window.FindName('Overlay').IsHitTestVisible=$false
 $script:WebShell.Visibility='Visible'
}
function UpdateTCWebTasks {
 if(IsBusy){return}
 $script:WebTasksAt=[DateTime]::UtcNow
 StartJob @{Action='DeploymentDiscover'} {param($data)
  # A probe that claims to run but has no living owner (for example after the console was closed mid-test) is finished here.
  $orphans=@(WebField $data ContinueRuns @()|Where-Object {[string](WebField $_ ProfileProbeState '') -ceq 'Running' -and [string](WebField $_ Stage '') -in @('PreparingProbePath','CheckingProfiles') -and -not ((Get-Command TestDeploymentBackgroundPendingUI -ErrorAction SilentlyContinue) -and (TestDeploymentBackgroundPendingUI ([string]$_.RunId)))})
  if($orphans.Count -and -not $script:WebOrphanRepairRequested){$script:WebOrphanRepairRequested=$true;StartJob @{Action='DeploymentRepairOrphans'} {param($repair)$script:WebOrphanRepairRequested=$false;if(@($repair.Repaired).Count){UpdateTCWebTasks}} '正在整理上次中断的测试…' '' -Silent -Failed {param($message)$script:WebOrphanRepairRequested=$false}}
  $script:WebTasks=@(foreach($r in @(WebField $data ContinueRuns @())){[pscustomobject]@{Id=[string]$r.RunId;Name=[string]$r.Name;Label=$(if($r.Status -in @('Running','Dispatching')){'正在准备'}elseif($r.Status -in @('NeedsRecovery','OutcomeUnknown')){'上次操作需要处理'}else{'进度已保存'})}})
  SyncTCWebState
 } '正在读取添加进度…' '' -Silent
}
function UpdateTCLineQuality {
 if($script:Smoke -or $script:ReadOnly -or $script:Job -or $script:JobQueue.Count -or (IsBusy)){return}
 if(-not (WebField $script:Overview Running $false)){$script:WebQuality=$null;$script:WebStandby=$null;return}
 # 隐藏态放宽到 60s（断线判定下限），可见态维持 30s。不能更宽：隐藏态采样是
 # 托盘线路劣化提醒（下方 ShowBalloonTip）的唯一来源。
 $qualityInterval=if($script:Window.IsVisible){30}else{60}
 if(([DateTime]::UtcNow-$script:WebQualityAt).TotalSeconds -lt $qualityInterval){
  # 备用线路只影响推荐的新鲜度，不参与断线判定，隐藏态可以更宽。
  $standbyInterval=if($script:Window.IsVisible){60}else{120}
  if(([DateTime]::UtcNow-$script:WebStandbyAt).TotalSeconds -ge $standbyInterval){
   $script:WebStandbyAt=[DateTime]::UtcNow
   StartJob @{Action='StandbyQuality'} {param($data)
    $context=Get-TCLineQualityContext $script:Overview
    $script:WebStandby=if($context.Key -and $context.Key -ceq (WebField $data BindingKey '')){$data}else{$null}
    SyncTCWebState -Force
   } '正在检查备用服务器响应…' '' -Silent -Failed {param($message)$script:WebStandby=$null}
  }
  return
 }
 $script:WebQualityAt=[DateTime]::UtcNow
 StartJob @{Action='LineQuality'} {param($data)
  $context=Get-TCLineQualityContext $script:Overview
  if(-not $context.Key -or $context.Key -cne [string](WebField $data BindingKey '')){$script:WebQuality=$null;return}
  $script:WebQuality=$data
  if((WebField $data Notify $false) -and (WebField $data Notification)){
   $message=[string]$data.Notification.Message;Toast $message
   if($script:Tray -and -not $script:Window.IsVisible){$script:DeploymentTrayNotificationRunId='';$script:Tray.ShowBalloonTip(6000,'线路状态提醒',$message,[Windows.Forms.ToolTipIcon]::Warning)}
  }
  SyncTCWebState -Force
 } '正在记录线路响应…' '' -Silent -Failed {param($message)$script:WebQuality=$null}
}
function LoadTCWebQualityHistory {param([string]$Id,[string]$Window='Day')
 if($Window -ceq 'Close'){$script:WebQualityHistory=$null;$script:WebHistoryRequest='';return}
 if($Window -cnotin @('ThirtyMinutes','Day') -or -not @($script:Nodes|Where-Object {(UILineId $_) -ceq $Id}).Count){return}
 $script:WebHistoryRequest=$Id+'|'+$Window;$script:WebQualityHistory=@{NodeId=$Id;Window=$Window;Loading=$true;Series=@()}
 StartJob @{Action='LineQualityHistory';NodeId=$Id;Window=$Window} {param($data,$context)
  if($script:WebHistoryRequest -ceq $context.Key -and $context.Key -ceq ([string]$data.NodeId+'|'+[string]$data.Window)){
   $series=@(foreach($entry in @($data.Series)){
    [pscustomobject]@{Binding=@{ProfileId=$entry.Binding.ProfileId;Exit=$entry.Binding.Exit};Aggregate=@{Statistics=$entry.Aggregate.Statistics;StartAtUtc=$entry.Aggregate.StartAtUtc;EndAtUtc=$entry.Aggregate.EndAtUtc;Buckets=@($entry.Aggregate.Buckets|Select-Object AverageLatencyMs,MedianLatencyMs,P95LatencyMs,MeasuredCount,SampleCount)}}
   })
   $script:WebQualityHistory=@{Reason=$data.Reason;NodeId=$data.NodeId;Window=$data.Window;Series=$series};SyncTCWebState -Force
  }
 } '正在读取线路历史…' '' -Silent -CallbackContext @{Type='QualityHistory';Key=$script:WebHistoryRequest} -Failed {param($message,$context)if($script:WebHistoryRequest -ceq $context.Key){$script:WebQualityHistory=@{Reason='StoreUnavailable';NodeId=($context.Key -split '\|')[0];Series=@()};SyncTCWebState -Force}}
}
function ContinueTCWebConnection {
 $waiting=$script:WebPendingConnection
 if(-not $waiting){return}
 if($script:ReadOnly -or ([DateTime]::UtcNow-$waiting.CreatedAt).TotalSeconds -gt $script:WebPendingBudgetSeconds -or [string](WebField $script:Overview SessionId '') -cne $waiting.SessionId){$script:WebPendingConnection=$null;Toast '等待已结束，请重新选择线路';return}
 if((IsBusy) -or (WebField $script:Overview NinjaRunning $true) -or (WebField $script:Overview ReadState '') -eq 'Unknown' -or $script:Window.FindName('Overlay').Visibility -eq 'Visible'){return}
 $id=$waiting.Id;$script:WebPendingConnection=$null
 if(@($script:Nodes|Where-Object {(UILineId $_) -ceq $id}).Count){StartLineConnectionPreview $id ''}
}
function RequestTCLineConnection {param([string]$Id)
 if($script:ReadOnly -or (IsBusy) -or (WebField $script:Overview ReadState '') -eq 'Unknown'){return}
 $targets=@($script:Nodes|Where-Object {(UILineId $_) -ceq $Id})
 if($targets.Count -ne 1 -or (WebField $targets[0] ServerConnectionBlock $false)){return}
 if(Get-Command StopLoginAutoConnectUI -ErrorAction SilentlyContinue){StopLoginAutoConnectUI}
 $script:WebPendingConnection=$null
 if((WebField $script:Overview Running $false) -and [string](WebField $script:Overview ActiveLineId '') -ceq $Id -and [string](WebField $script:Overview Exit '') -match '^provider'){OnTrade ('node:'+$Id);return}
 if(WebField $script:Overview NinjaRunning $false){
  $script:WebPendingConnection=@{Id=$Id;Name=[string](WebField $targets[0] Name '所选线路');CreatedAt=[DateTime]::UtcNow;SessionId=[string](WebField $script:Overview SessionId '')}
  Toast (Get-TCText WaitingForApps);SyncTCWebState -Force
 }else{StartLineConnectionPreview $Id ''}
}
function UpdateTCTrayLines {
 if(-not $script:TrayLineMenu){return}
 $script:TrayLineMenu.DropDownItems.Clear()
 $active=[string](WebField $script:Overview ActiveLineId (WebField $script:Overview NodeId ''))
 $running=[bool](WebField $script:Overview Running $false)
 foreach($entry in @($script:Nodes)){
  $id=UILineId $entry;if(-not $id){continue}
  $item=New-Object Windows.Forms.ToolStripMenuItem([string](WebField $entry Name '我的线路'))
  $item.Tag=$id;$item.Checked=($running -and $active -ceq $id -and (WebField $script:Overview Exit '') -ceq 'hk')
  $item.Enabled=(-not $script:ReadOnly -and -not (IsBusy) -and -not (WebField $entry ServerConnectionBlock $false) -and -not $item.Checked)
  $item.Add_Click({ShowExistingConsole;RequestTCLineConnection ([string]$this.Tag)})
  $null=$script:TrayLineMenu.DropDownItems.Add($item)
 }
 if(-not $script:TrayLineMenu.DropDownItems.Count){$empty=$script:TrayLineMenu.DropDownItems.Add('还没有线路');$empty.Enabled=$false}
 if($script:TrayConnectItem){$script:TrayConnectItem.Text=$(if($running){'断开连接'}else{'连接'});$script:TrayConnectItem.Enabled=(-not $script:ReadOnly -and -not (IsBusy))}
}
function SetTCUserSettingUI {param([string]$Name,[bool]$Value)
 if($script:ReadOnly -or (IsBusy)){return}
 StartJob @{Action='SetUserSetting';Name=$Name;Value=$Value} {param($settings)
  $script:UserSettings=$settings
  if($settings.AutoConnectOnLogin){$script:Prefs.OpenAtLogin=$true}
  if($script:Page -eq 'settings'){ShowSettings}else{SyncTCWebState -Force}
  Toast '设置已保存'
 } '正在保存设置…' -Failed {param($message)ErrorDialog $message;SyncTCWebState -Force}
}
function NavigateTCWebPage {param([string]$Page)
 # Shared by the navigate message and by the pair page entries (0.21.8 A0). Both
 # must capture a pending deployment draft and reset password visibility before the
 # surface changes, otherwise a half-typed wizard is lost on the way in or out.
 if(Get-Command CaptureDeploymentDraftUI -ErrorAction SilentlyContinue){CaptureDeploymentDraftUI}
 if(Get-Command SetDeploymentPasswordVisibilityUI -ErrorAction SilentlyContinue){SetDeploymentPasswordVisibilityUI $false}
 $null=ShowTCWebShell $Page
}
function InvokeTCWebMessage {param([string]$Json,[string]$Origin)
 if($Origin -cne 'https://tradechannel.local/index.html' -or $Json.Length -gt 1048576){return}
 try{$m=$Json|ConvertFrom-Json -ErrorAction Stop}catch{return}
 $type=[string](WebField $m Type '');$allowed=@('theme','setProfile','testLine','setHomeLine','retryLineAction','reviewLineAction','ready','navigate','refresh','add','joinLine','connect','disconnect','lineSettings','lineServer','rename','delete','resume','providers','domains','agentsList','diagnostics','history','maintenance','daily','agents','setting','startup','closeBehavior','desktopShortcut','confirmDialog','cancelDialog','cancelWaiting','cancelDeletePreview','checkDelete','retryDelete','retryDeleteRefresh','reviewOperation','form','qualityHistory','backgroundDeployment','resumeDeployment','pairOnline','pairCancel','pairReset','invite')
 $fields=if($type -eq 'form'){@('Type','Id','Generation','Event','Value','Sequence')}elseif($type -eq 'theme'){@('Type','Value','Sequence')}elseif($type -ceq 'pairOnline'){@('Type','Id','Phase','Code','Name','Sequence')}elseif($type -ceq 'invite'){@('Type','Id','Phase','Value','Sequence')}else{@('Type','Id','Page','Name','Value','Sequence')}
 if($type -ne 'form' -and $Json.Length -gt 4096){return}
 if($type -cnotin $allowed -or @($m.PSObject.Properties.Name|Where-Object {$_ -cnotin $fields}).Count){
  # A dropped pair message would leave the page permanently busy, so this one
  # class of rejection answers (toast + advanced Ack + snapshot) instead of
  # returning silently. The type and field gates themselves are unchanged.
  if($type -cin @('pairOnline','pairCancel','pairReset')){DenyTCWebPair '这一步没有生效，请重试' (WebField $m Sequence $null)}
  # 0.22.0 A2: an `invite` message dropped here would leave the page's buttons
  # disabled with no explanation, so it answers the same way.
  if($type -ceq 'invite' -and (Get-Command DenyTCWebInvite -ErrorAction SilentlyContinue)){DenyTCWebInvite '这一步没有生效，请重试' (WebField $m Sequence $null)}
  return
 }
 if($m.PSObject.Properties['Sequence']){if($m.Sequence -isnot [int] -and $m.Sequence -isnot [long]){return};if($m.Sequence -lt 1 -or $m.Sequence -gt 2147483647 -or $m.Sequence -le $script:WebAck){return};$script:WebAck=[long]$m.Sequence}
 if($type -eq 'theme'){if([string](WebField $m Value '') -cin @('light','dark')){SetTCChromeTheme -Theme ([string]$m.Value)};return}
 if($type -eq 'ready'){if(-not $script:WebStartupTasksDone){$script:WebStartupTasksDone=$true;UpdateTCWebTasks};SyncTCWebState -Force;return}
 if($type -in @('confirmDialog','cancelDialog')){
  if($script:Window.FindName('Overlay').Visibility -ne 'Visible' -or [string](WebField $m Id '') -cne $script:WebDialogId){return}
  $action=$script:DialogCallback;$context=$script:DialogContext
  if($type -eq 'cancelDialog' -and [string](WebField $context CleanupDialog '') -cin @('PreviewWait','Confirm')){CancelLocalCleanupPreviewUI ([string]$context.Pending.OperationId) -KeepDialog}
  CloseDialog
  if($type -eq 'confirmDialog' -and $action -and -not $script:ReadOnly){& $action $context};SyncTCWebState -Force;return
 }
 if($type -eq 'reviewOperation'){
  if((Get-Variable UncertainUiJobs -Scope Script -ErrorAction SilentlyContinue) -and (Get-Command OpenUiReceiptDialog -ErrorAction SilentlyContinue)){
   $entry=@($script:UncertainUiJobs.ToArray()|Where-Object {[string](WebField $_ RequestId '') -ceq [string](WebField $m Id '')})|Select-Object -First 1
   if($entry){OpenUiReceiptDialog $entry}
  }
  SyncTCWebState -Force;return
 }
 if($type -in @('cancelDeletePreview','checkDelete','retryDelete','retryDeleteRefresh')){
  $id=[string](WebField $m Id '');$pending=WebField $script:DeployUI RecordDeletePending;$refresh=WebField $script:DeployUI CleanupRefresh
  if($type -eq 'retryDeleteRefresh'){
   if($refresh -and $refresh.OperationId -ceq $id -and $refresh.Phase -eq 'Failed'){RequestLocalCleanupRefreshUI $refresh.Pending}
  }elseif($pending -and $pending.OperationId -ceq $id){
   if($type -eq 'cancelDeletePreview'){CancelLocalCleanupPreviewUI $id}
   elseif($type -eq 'retryDelete'){RetryLocalCleanupUI $pending}
   elseif(-not $script:ReadOnly -and -not (IsBusy) -and $pending.Phase -in @('Blocked','Ready','OutcomeUnknown')){
    if($pending.Phase -eq 'OutcomeUnknown'){CheckOriginalLocalCleanupResultUI $pending}else{InspectLocalCleanupTargetUI $pending}
   }
  }
  SyncTCWebState -Force;return
 }
 if($script:Window.FindName('Overlay').Visibility -eq 'Visible'){SyncTCWebState -Force;return}
 # 0.20: cancel paths sit above the ReadOnly/IsBusy gate. A running pairing job
 # must stay cancellable, and the legacy cancelWaiting had the same defect: its
 # whole effect is the assignment above, which the busy gate made unreachable.
 if($type -in @('pairOnline','pairCancel','pairReset')){
  if($type -cne 'pairOnline'){$m|Add-Member NoteProperty Phase $(if($type -ceq 'pairCancel'){'Cancel'}else{'Reset'}) -Force}
  InvokeTCWebPairOnline $m;return
 }
 # 0.22.0 A2: the invitation page owns its own phases. It sits here, above the
 # ReadOnly/IsBusy gate, because 「取消邀请码」 and closing the page must stay
 # reachable while a status poll is in flight.
 if($type -ceq 'invite'){
  if(Get-Command InvokeTCWebInviteMessage -ErrorAction SilentlyContinue){InvokeTCWebInviteMessage $m}
  elseif(Get-Command DenyTCWebInvite -ErrorAction SilentlyContinue){DenyTCWebInvite '这一步没有生效，请重试' (WebField $m Sequence $null)}
  else{SyncTCWebState -Force}
  return
 }
 if($type -ceq 'cancelWaiting'){$script:WebPendingConnection=$null;SyncTCWebState -Force;return}
 if($type -eq 'backgroundDeployment'){
  if(-not $script:ReadOnly -and (Get-Command SendDeploymentToBackgroundUI -ErrorAction SilentlyContinue)){$null=SendDeploymentToBackgroundUI}
  SyncTCWebState -Force;return
 }
 if($type -eq 'resumeDeployment'){
  $id=[string](WebField $m Id '')
  $foregroundMemory=@($script:UiMemoryJobs|Where-Object {(WebField (WebField $_ Context) Type '') -cne 'DeploymentBackground'})
  if(-not $script:ReadOnly -and -not $foregroundMemory.Count -and (-not $script:Job -or $script:Job.Silent) -and @(GetDeploymentBackgroundSummaryUI|Where-Object RunId -CEQ $id).Count){OpenDeploymentBackgroundRunUI $id}
  SyncTCWebState -Force;return
 }
 if($type -eq 'navigate'){
  $page=[string](WebField $m Page '');if($page -cnotin @('home','lines','apps','settings','add-line','invite')){return}
  if($script:WebFormActive -and (IsBusy)){SyncTCWebState -Force;return}
  # 0.21.8 A0: a finished join session must not follow the user to another page -
  # every snapshot would re-deliver its Pair, so coming back to add-line reopened on
  # the old result. A running join stays: its callbacks are still live.
  if($script:WebPage -ceq 'add-line' -and $page -cne 'add-line' -and $script:PairSession -and $script:PairSession.Phase -notin @('Creating','Authorizing','Preparing')){
   ClearTCWebPairSession -Silent
  }
  # 0.22.0 A2: leaving the invitation page stops its status poll, drops the code
  # and releases the management driver, so a late result renders the server page
  # instead of silently updating a page nobody is looking at.
  if($script:WebPage -ceq 'invite' -and $page -cne 'invite' -and (Get-Command ClearTCWebInvite -ErrorAction SilentlyContinue)){ClearTCWebInvite}
  # 有未保存的名单改动时先拦一次：两条轨道拦在同一个入口，前端不另做「未保存」概念。
  if((Get-Command AgentDraftDirty -ErrorAction SilentlyContinue) -and (AgentDraftDirty)){
   $script:AgentLeaveTarget=$page
   OpenDialog '名单还有改动没保存' '这些改动还没有生效，离开后需要重新勾选。' '要放弃改动，先点「放弃修改」。' '保存并离开' {SaveAgentDraftAndGo $script:AgentLeaveTarget} '留在此页' -SafeDefault
   SyncTCWebState -Force;return
  }
  NavigateTCWebPage $page
  if($page -eq 'lines' -and ([DateTime]::UtcNow-$script:WebTasksAt).TotalSeconds -gt 60){UpdateTCWebTasks};SyncTCWebState -Force;return
 }
 if($type -eq 'form'){
  if($script:WebFormActive){
   $result=InvokeTCWebFormAction -Generation (WebField $m Generation '') -Id (WebField $m Id '') -Event (WebField $m Event '') -Value (WebField $m Value)
   if(-not $result.Ok){switch($result.Code){
    'ActionFailed'{ErrorDialog '这次操作未完成，请重试。'}
    'StaleGeneration'{Toast '页面已更新，请重新操作'}
    # 句柄失效（例如吸底操作条刚被重建）过去是静默丢弃，用户只会看到「点了没反应」。
    'UnknownId'{Toast '页面已更新，请重新操作'}
    'ValueTooLarge'{Toast '输入内容过长，请缩短后重试'}
    'InvalidValue'{Toast '输入内容无效，请检查后重试'}
   }}
  }
  SyncTCWebState -Force;return
 }
 if($type -eq 'refresh'){if(-not (IsBusy)){RefreshOverview -Silent;FetchNodes};return}
 if($type -eq 'qualityHistory'){if((WebField $m Value '') -ceq 'Close' -or -not (IsBusy)){LoadTCWebQualityHistory ([string](WebField $m Id '')) ([string](WebField $m Value 'Day'))};SyncTCWebState -Force;return}
 if($script:ReadOnly -or (IsBusy)){
  # A disabled button must never be a silent drop: say what is running, or that
  # the previous step has not finished yet. No new message type is introduced.
  if($type -cin @('connect','disconnect','testLine','delete','rename','setProfile','setHomeLine')){
   $running=$null
   try{if(Get-Command GetTCWebOperation -ErrorAction SilentlyContinue){$running=GetTCWebOperation}}catch{$running=$null}
   $label=''
   if($running){switch([string](WebField $running Kind '')){'Connect'{$label='连接'}'Switch'{$label='切换'}'Disconnect'{$label='断开'}'Test'{$label='测速'}}}
   if($label){Toast ('正在'+$label+'，请稍等')}else{Toast '上一步还没有结束，请稍等'}
  }
  SyncTCWebState -Force;return
 }
 $script:WebPendingConnection=$null
 if(Get-Command StopLoginAutoConnectUI -ErrorAction SilentlyContinue){StopLoginAutoConnectUI}
 $id=[string](WebField $m Id '')
 if($type -in @('connect','lineSettings','lineServer','rename','delete','setProfile','testLine','setHomeLine','retryLineAction','reviewLineAction') -and -not @($script:Nodes|Where-Object {(UILineId $_) -ceq $id}).Count){SyncTCWebState -Force;return}
 switch($type){
  'add'{BeginProductDeployment 'Auto'}
  'joinLine'{OpenOnlinePairingUI}
  'connect'{
   # 0.21.2: a line whose server identity must be checked cannot connect, and
   # RequestTCLineConnection drops it silently. Every web path that still asks to
   # connect it (guard repair, recommendation, an older page) gets the repair page.
   $target=@($script:Nodes|Where-Object {(UILineId $_) -ceq $id})[0]
   if(WebField $target ServerConnectionBlock $false){Toast '这条线路的服务器身份需要先核对';OpenLineServerManagement $id -ReturnKind Nodes}
   elseif(TestTCWebProviderBackupReturn $id){
    # 0.22.0 C-R8：只切 selector，不重启通道（Pages.ps1 的 QuickHongKong）。
    if(Get-Command QuickHongKong -ErrorAction SilentlyContinue){QuickHongKong}else{Toast '请到首页点「回到…」切回这条线路'}
   }
   else{RequestTCLineConnection $id}
  }
  'disconnect'{OpenDisconnect}
  'lineSettings'{LoadLineConnections $id}
  # Server and devices of this line: invitation codes, devices, identity check.
  'lineServer'{OpenLineServerManagement $id -ReturnKind Nodes}
  'setProfile'{if([string](WebField $m Value '') -ceq 'Auto'){ResetLineDefaultProfileForLineUI $id -Origin 'Card'}elseif([string](WebField $m Value '') -cin @('Udp','Tcp')){SaveLineDefaultProfileForLineUI $id ([string]$m.Value) -Origin 'Card'}}
  'retryLineAction'{RetryLineActionUI $id ([string](WebField $m Value ''))}
  'reviewLineAction'{ReviewLineActionUI $id ([string](WebField $m Value ''))}
  'testLine'{
   # 0.22.0 C-R7：在用线路的测速永远会被 ActiveIdentityInUse 拒绝（LineConnectionCheck.psm1:19），
   # 与其让用户点一个必然失败的按钮，不如直接说清楚去哪儿看响应。
   if(TestTCWebLineInUse $id){Toast '使用中的线路请看首页「线路响应」。'}
   else{$target=@($script:Nodes|Where-Object {(UILineId $_) -ceq $id})[0];$testProfile=GetTCWebTestProfileId $target;CheckLineCardProtocolUI $id -ProfileId $testProfile}
  }
  'setHomeLine'{SetTCWebHomeLine $id}
  'rename'{OpenRenameNode $id}
  'delete'{
   $target=@($script:Nodes|Where-Object {(UILineId $_) -ceq $id})[0];$availability=GetTCWebLineDeleteAvailability $target $script:Overview
   if(-not $availability.CanDelete){Toast $availability.Message}else{OpenDeleteNode $id}
  }
  'resume'{if(@($script:WebTasks|Where-Object Id -CEQ $id).Count){ResumeProductDeployment $id}}
  'providers'{$script:WebNodeView='providers';ShowTCWebNodeView;FetchProviders -Silent}
  'domains'{$script:WebNodeView='domains';LoadTradeDomainManager}
  'agentsList'{$script:WebNodeView='agents';ShowTCWebNodeView}
  'diagnostics'{ShowRuntimeReport}
  'history'{ShowUnifiedOperationHistory}
  'maintenance'{ShowTCWebMaintenance}
  'startup'{if((WebField $m Value) -is [bool]){SetTCWebStartup ([bool]$m.Value)}}
  'closeBehavior'{if([string](WebField $m Value '') -cin @('Tray','ExitInterface')){SetWindowCloseBehavior ([string]$m.Value)}}
  'desktopShortcut'{StartJob @{Action='DesktopShortcut'} {param($d)Toast '桌面快捷方式已创建'} '正在创建桌面快捷方式…'}
  'daily'{if([string](WebField $m Value '') -cin @('Direct','Provider','Trade')){OnDaily ([string]$m.Value)}}
  'agents'{if([string](WebField $m Value '') -cin @('Daily','Trade')){OnAgents ([string]$m.Value)}}
  'setting'{if([string](WebField $m Name '') -cin @('AutoTrustFirstConnection','AutoConnectOnLogin','QualityWarning') -and (WebField $m Value) -is [bool]){SetTCUserSettingUI ([string]$m.Name) ([bool]$m.Value)}}
 }
 SyncTCWebState -Force
}
function GetTCWebFileDropControl {param([string]$Id)
 # 只有交易程序输入框接受拖入的文件；其余控件一律忽略。
 # 判定按"宿主控件"而不是按页面：网页可能把同一个输入框渲染在任何页面上。
 if($Id -cnotmatch '^wf-[0-9a-f]{32}$' -or -not $script:TCWebFormView){return $null}
 if(-not $script:TCWebFormView.Handles.ContainsKey($Id)){return $null}
 $control=$script:TCWebFormView.Handles[$Id].Control
 if($control -isnot [Windows.Controls.TextBox] -or $control.Name -cne 'TradeProgramInput'){return $null}
 $control
}
function ResolveTCWebShortcut {param([string]$Path)
 # 桌面和开始菜单上的程序绝大多数是快捷方式（.lnk），而 Windows 默认隐藏已知扩展名，
 # 用户看到的只是「NinjaTrader」这样的名字，分辨不出 .lnk 和 .exe。拖进来的是快捷方式
 # 时必须按它的目标解析，否则用户永远加不上桌面上的程序。
 # 只跟 3 层并记录已访问路径，避免快捷方式互相指向形成环。
 if(-not $Path -or [IO.Path]::GetExtension($Path) -ine '.lnk'){return $Path}
 $current=$Path;$seen=@{}
 for($depth=0;$depth -lt 3;$depth++){
  if([IO.Path]::GetExtension($current) -ine '.lnk'){return $current}
  $key=$current.ToLowerInvariant()
  if($seen.ContainsKey($key)){return ''}
  $seen[$key]=$true
  $shell=$null;$target=''
  try{
   $shell=New-Object -ComObject WScript.Shell
   $target=[string]$shell.CreateShortcut($current).TargetPath
  }catch{return ''}
  finally{if($shell){try{[void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)}catch{}}}
  if(-not $target){return ''}
  $current=$target
 }
 if([IO.Path]::GetExtension($current) -ine '.lnk'){return $current}
 ''
}
function TestTCWebDroppedProgram {param([string]$Path)
 # 上限和页面上的 MaxLength 保持一致：超长路径会被输入框截断，显示的和提交的就不是同一个值。
 if(-not $Path){return '请拖入 .exe 程序文件。'}
 if($Path.Length -gt 1024){return '程序路径过长，请把程序放到更短的目录下。'}
 if([IO.Directory]::Exists($Path)){return '请拖入 .exe 程序文件，而不是文件夹。'}
 $extension=[IO.Path]::GetExtension($Path)
 if($extension -ine '.exe'){
  # 说清楚拖进来的到底是什么，否则用户只会重复拖同一个文件。
  if($extension){return ('只能添加 .exe 程序文件，你拖入的是 '+$extension+' 文件。')}
  return '只能添加 .exe 程序文件。'
 }
 ''
}
function ReceiveTCWebFileDrop {param($Message)
 # 页面读不到被拖文件的完整路径，只能把 File 交给宿主；这里取回真实路径。
 # 来源校验必须最先做，和 InvokeTCWebMessage 的入口校验保持同一把锁。
 if(-not $Message){return $false}
 $origin=''
 try{$origin=[string]$Message.Source}catch{$origin=''}
 if($origin -cne 'https://tradechannel.local/index.html'){return $false}
 $payload=$null
 try{$payload=([string]$Message.WebMessageAsJson)|ConvertFrom-Json}catch{return $false}
 if([string](WebField $payload Type '') -cne 'fileDrop'){return $false}
 $control=GetTCWebFileDropControl ([string](WebField $payload Target ''))
 if(-not $control){return $false}
 $objects=$null
 try{$objects=$Message.AdditionalObjects}catch{return $false}
 # 没有附加对象 = 这不是一次文件拖放（页面只发了一条普通消息），静默交回原逻辑；
 # 只有真的带了多个文件才提示。
 if(-not $objects){return $false}
 if($objects.Count -ne 1){ErrorDialog '一次只能拖入一个程序文件。';return $true}
 $file=$objects[0]
 $path=''
 try{if($file){$path=[string]$file.Path}}catch{$path=''}
 # 拖进来的常常是桌面快捷方式：先解析到真正的目标程序，再按 .exe 校验。
 $shortcut=$path
 if($path -and [IO.Path]::GetExtension($path) -ieq '.lnk'){
  $path=ResolveTCWebShortcut $path
  if(-not $path -or -not [IO.File]::Exists($path)){
   ErrorDialog ('这个快捷方式找不到可用的目标程序：'+[IO.Path]::GetFileName($shortcut)+'。请右键点它，选「打开文件所在位置」，再把里面的 .exe 拖进来。')
   return $true
  }
  # 有些快捷方式是用系统脚本宿主启动的（例如 .vbs 包一层），解析出来的是 wscript.exe。
  # 填进去会把「所有脚本宿主流量」当成这个程序，既不准确也放大了保护范围，宁可说清楚。
  if([IO.Path]::GetFileName($path) -imatch '^(wscript|cscript|cmd|powershell|pwsh)\.exe$'){
   ErrorDialog ('这个快捷方式是用 '+[IO.Path]::GetFileName($path)+' 启动的脚本，不是程序本身。名单只接受 .exe，请右键点它选「打开文件所在位置」，找到真正运行的 .exe 再拖进来。')
   return $true
  }
 }
 # 注意：不要用 $error 当局部变量名，那是 PowerShell 的自动变量。
 $problem=TestTCWebDroppedProgram $path
 if($problem){ErrorDialog $problem;return $true}
 $control.Text=$path
 if($shortcut -ne $path){Toast ('已按快捷方式填入目标程序：'+[IO.Path]::GetFileName($path))}
 SyncTCWebState -Force
 return $true
}
function ResolveTCWebPopoverCapability {
 # Native popover shipped in Chromium 114. Failure to inspect the installed
 # runtime only disables that presentation feature; it never blocks the web UI.
 try{
  $text=[Microsoft.Web.WebView2.Core.CoreWebView2Environment]::GetAvailableBrowserVersionString()
  $parsed=[version]$null
  return ([version]::TryParse([string]$text,[ref]$parsed) -and $parsed -ge [version]'114.0.0.0')
 }catch{return $false}
}
function InitializeTCWebShell {param([string]$DataFolder='',[switch]$Fixture)
 if($script:WebShell -or ($script:Smoke -and -not $Fixture)){return}
 try{
  $lib=Join-Path $script:PackageRoot 'assets\webview2'
  $null=[Reflection.Assembly]::LoadFrom((Join-Path $lib 'Microsoft.Web.WebView2.Core.dll'))
  $null=[Reflection.Assembly]::LoadFrom((Join-Path $lib 'Microsoft.Web.WebView2.Wpf.dll'))
  if(-not $DataFolder){$DataFolder=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'TradeChannel\WebView2'}
  $script:WebShell=New-Object Microsoft.Web.WebView2.Wpf.WebView2
  $creation=New-Object Microsoft.Web.WebView2.Wpf.CoreWebView2CreationProperties;$creation.UserDataFolder=$DataFolder;$script:WebShell.CreationProperties=$creation
  # 拖放走 WebView2 自己的通道：Chromium 的子窗口自己就是 OLE 放置目标，
  # 关掉 AllowExternalDrop 并不会把拖放交给父级 WPF 元素（实测 WPF 的 Drop 不触发）。
  # 所以保持 AllowExternalDrop 默认的 true，由页面把 File 交给宿主换取真实路径。
  [Windows.Controls.Grid]::SetRow($script:WebShell,1);$script:WebShell.Visibility='Collapsed'
  $null=$script:Window.FindName('Frame').Child.Children.Add($script:WebShell)
  $script:WebShell.Add_CoreWebView2InitializationCompleted({param($sender,$event)
   if(-not $event.IsSuccess){$script:WebFailed=$true;$script:WebFailureMessage=[string]$event.InitializationException;SuspendTCWebShell;$script:Footer.Text='新版界面未能启动，已打开兼容界面。';return}
   try{
    $core=$sender.CoreWebView2;$core.Settings.AreDevToolsEnabled=$false;$core.Settings.AreDefaultContextMenusEnabled=$false;$core.Settings.IsStatusBarEnabled=$false;$core.Settings.AreHostObjectsAllowed=$false;$core.Settings.IsPasswordAutosaveEnabled=$false;$core.Settings.IsGeneralAutofillEnabled=$false
    $script:WebPopoverVersionAllowed=ResolveTCWebPopoverCapability
    $popoverLiteral=if($script:WebPopoverVersionAllowed){'true'}else{'false'}
    $null=$core.AddScriptToExecuteOnDocumentCreatedAsync('window.__tcNativePopoverAllowed = '+$popoverLiteral+';')
    $core.SetVirtualHostNameToFolderMapping('tradechannel.local',(Join-Path $script:PackageRoot 'web'),[Microsoft.Web.WebView2.Core.CoreWebView2HostResourceAccessKind]::DenyCors)
    $core.Add_NavigationStarting({param($s,$e)if($e.Uri -cne 'https://tradechannel.local/index.html'){$e.Cancel=$true}else{$script:WebAck=0;$script:WebLastJson=''}})
    $core.Add_NewWindowRequested({param($s,$e)$e.Handled=$true})
    $core.Add_DownloadStarting({param($s,$e)$e.Cancel=$true})
    $core.Add_PermissionRequested({param($s,$e)$e.State=[Microsoft.Web.WebView2.Core.CoreWebView2PermissionState]::Deny})
    $core.Add_WebMessageReceived({param($s,$e)try{if(ReceiveTCWebFileDrop $e){return};InvokeTCWebMessage $e.WebMessageAsJson $e.Source}catch{ErrorDialog '这次操作未完成，请刷新后重试。'}})
    $script:WebReady=$true;$null=ShowTCWebShell 'home';$core.Navigate('https://tradechannel.local/index.html');Write-TCPerfTrace 'webview-ready'
   }catch{$script:WebFailed=$true;$script:WebReady=$false;$script:WebFailureMessage=$_.Exception.Message;SuspendTCWebShell;$script:Footer.Text='新版界面初始化失败，已打开兼容界面。'}
  })
  $null=$script:WebShell.EnsureCoreWebView2Async($null)
 }catch{$script:WebFailed=$true;$script:WebFailureMessage=$_.Exception.Message;SuspendTCWebShell;$script:Footer.Text='未找到可用的 WebView2，已打开兼容界面。'}
}
