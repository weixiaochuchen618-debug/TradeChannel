#requires -Version 5.1
$ErrorActionPreference='Stop'
# The only execution seam is module-private. Tests install it temporarily with
# & $module { $script:TestAdapter=... }; no exported entry accepts callbacks.
$script:TestAdapter=$null
$script:PreferenceClock=$null
$script:MonotonicClock=$null
function CTNow {if($script:PreferenceClock){return & $script:PreferenceClock};[DateTimeOffset]::UtcNow}
function CTTicks {
    if($script:MonotonicClock){return [int64](& $script:MonotonicClock)}
    return [Diagnostics.Stopwatch]::GetTimestamp()
}
function CTSecondsBetween {param([int64]$StartTicks,[int64]$EndTicks)
    if($EndTicks -lt $StartTicks){return 0.0}
    return ([double]($EndTicks-$StartTicks))/[double][Diagnostics.Stopwatch]::Frequency
}
function CTNewBudget {param([ValidateRange(1,3600)][int]$Seconds)
    $start=CTTicks
    [pscustomobject]@{BudgetSeconds=$Seconds;StartedAtUtc=(CTNow).ToString('o');StartTicks=$start;DeadlineTicks=$start+([int64]($Seconds*[Diagnostics.Stopwatch]::Frequency))}
}
function CTBudgetRemaining {param($Budget)
    if(-not $Budget){return [double]::PositiveInfinity}
    $elapsed=CTSecondsBetween $Budget.StartTicks (CTTicks)
    return [Math]::Max(0.0,$Budget.BudgetSeconds-$elapsed)
}
function CTEnsureBudget {param($Budget,[string]$Phase,[string]$TimeoutCode='ConnectionTimeout')
    if(-not $Budget){return}
    $remaining=CTBudgetRemaining $Budget
    if($remaining -le 0){$e=New-Object TimeoutException(('[TC:'+ $TimeoutCode +'] '+$Phase+' 超过 '+$Budget.BudgetSeconds+' 秒预算。'));$e.Data['TCConnectionTimeout']=$true;$e.Data['TCConnectionTimeoutPhase']=$Phase;throw $e}
}
function CTBudgetPayload {param($Payload,$Budget)
    $value=if($null -eq $Payload){[pscustomobject]@{}}else{$Payload|ConvertTo-Json -Depth 40|ConvertFrom-Json}
    if($Budget){$remaining=[int][Math]::Max(1,[Math]::Floor((CTBudgetRemaining $Budget)));$value|Add-Member NoteProperty TimeoutSeconds $remaining -Force;$value|Add-Member NoteProperty DeadlineUtc ((CTNow).AddSeconds($remaining).ToString('o')) -Force;$value|Add-Member NoteProperty BudgetSeconds $Budget.BudgetSeconds -Force}
    return $value
}

function CTField { param($Value,[string]$Name,$Default=$null)
    if($null -ne $Value -and $Value.PSObject.Properties[$Name]){return $Value.$Name};return $Default
}
function CTPath { param([string]$Path)
    $full=[IO.Path]::GetFullPath($Path);$cursor=$full
    while($cursor){if(Test-Path -LiteralPath $cursor){$item=Get-Item -LiteralPath $cursor -Force;if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw '事务路径不能经过重解析点。'}};$parent=[IO.Path]::GetDirectoryName($cursor);if($parent -eq $cursor){break};$cursor=$parent}
    return $full
}
function CTRead {param([string]$Path)
    if([IO.File]::Exists($Path)){
        try{$json=[IO.File]::ReadAllText((CTPath $Path),[Text.Encoding]::UTF8);if((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')){ConvertFrom-Json -InputObject $json -DateKind String}else{ConvertFrom-Json -InputObject $json}}
        catch{throw '[TC:ConnectionMetadataInvalid] 无法读取本机连接资料，请重新核对原记录。'}
    }
}
function CTFailure {param($Failure,[string]$Phase)
    $message=if($Failure -is [Management.Automation.ErrorRecord]){[string]$Failure.Exception.Message}elseif($Failure -is [Exception]){[string]$Failure.Message}else{[string]$Failure}
    $code='ConnectionStepFailed'
    if($message -match '^\[TC:([A-Za-z][A-Za-z0-9_]{0,63})\]'){$code=$matches[1]}
    $safe=switch($code){
        'DiagnosticConfigReadFailed'{'出口检查无法读取本机配置。'}
        'DiagnosticInterfaceMissing'{'连接配置绑定的网卡已不存在。'}
        'DiagnosticInterfaceUnknown'{'无法核对连接配置绑定的网卡。'}
        'DiagnosticInterfaceRenamed'{'原物理网卡已改名，请更新本机网络设置。'}
        'NetworkPolicyUpdateRequired'{'请确认这条线路使用的物理网卡，并更新本机网络设置。'}
        'DiagnosticAddressChanged'{'连接配置绑定的本机 IPv4 地址已变化。'}
        'ConnectionMetadataInvalid'{'本机连接资料无法读取。'}
        'ProbeRouteUnverified'{'出口检查入口或路由未通过核验。'}
        'ProfileExitUnverified'{'实际出口与所选连接方式不一致。'}
        'LineForwardingUnverified'{'实际 HTTPS、DNS 或出口验证未通过。'}
        'TradingAppRunning'{'NinjaTrader 正在运行，连接步骤已停止；请先完整退出 NinjaTrader。'}
        'EngineChanged'{'连接引擎与登记版本不一致，请核对安装文件。'}
        'EngineBindingRequired'{'所选配置缺少可信引擎绑定，请更新这条线路的本机配置。'}
        'ServerBindingChanged'{'关联服务器身份已变化，请核对原服务器。'}
        'ServerArchived'{'原服务器身份已归档，请使用当前身份准备的线路。'}
        'SavedDefaultMissing'{'请选择这条线路的默认连接方式。'}
        'SavedDefaultInvalid'{'已保存选择的配置绑定需要核对，请打开原线路连接方式。'}
        'ProfileConfigurationMissing'{'所选方式缺少完整本机配置，请继续原线路的准备步骤。'}
        'ConnectionCheckTimeout'{'本次线路出口、DNS 与 HTTPS 检查超过 45 秒，结果未确认；请查看原操作记录后再处理。'}
        'ConnectionTimeout'{'连接操作超过 120 秒，当前结果需要核对；不会把未确认状态当作成功。'}
        'RecoveryTimeout'{'恢复原连接超过 90 秒，当前结果需要核对；不会宣称原线路已恢复。'}
        'NeedsRecovery'{'上次连接或检查的状态尚未核实，请先恢复连接状态。'}
        default{switch($Phase){'BeforeStop'{'切换开始前的核对未通过。'}'StopOriginal'{'原连接未能完全停止。'}'StartTarget'{'目标线路未能启动。'}'ApplyOriginalIntent'{'目标线路未能应用已保存的流量设置。'}'VerifyTarget'{'目标线路的出口检查未完成。'}'VerifyOriginal'{'原线路的恢复检查未通过。'}default{'连接操作未完成，请按本步骤的提示处理。'}}}
    }
    [pscustomobject]@{Code=$code;Phase=$Phase;Message=$safe;AtUtc=(CTNow).ToString('o')}
}
function CTHash {param([string]$Path) if([IO.File]::Exists($Path)){(Get-FileHash -LiteralPath (CTPath $Path) -Algorithm SHA256).Hash}else{$null}}
function CTDigest {param($Value)
    $sha=[Security.Cryptography.SHA256]::Create()
    $json=if($null -eq $Value){'null'}else{ConvertTo-Json -InputObject $Value -Depth 40 -Compress}
    try{([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($json)))).Replace('-','')}finally{$sha.Dispose()}
}
function CTWrite {param([string]$Path,$Value)
    $full=CTPath $Path;$temp=$full+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try{[IO.File]::WriteAllText($temp,($Value|ConvertTo-Json -Depth 40),(New-Object Text.UTF8Encoding($true)));if([IO.File]::Exists($full)){[IO.File]::Replace($temp,$full,[NullString]::Value)}else{[IO.File]::Move($temp,$full)}}finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
}
function CTSnapshotFile {param([string]$Path)
    $full=CTPath $Path;[pscustomobject]@{Path=$full;Exists=[IO.File]::Exists($full);SHA256=(CTHash $full);Bytes=$(if([IO.File]::Exists($full)){[Convert]::ToBase64String([IO.File]::ReadAllBytes($full))}else{$null})}
}
function CTRestoreFile {param($Snapshot)
    $full=CTPath $Snapshot.Path
    if($Snapshot.Exists){
        $temp=$full+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
        try{[IO.File]::WriteAllBytes($temp,[Convert]::FromBase64String($Snapshot.Bytes));if([IO.File]::Exists($full)){[IO.File]::Replace($temp,$full,[NullString]::Value)}else{[IO.File]::Move($temp,$full)}}finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
        if((CTHash $full) -cne $Snapshot.SHA256){throw '原始资料恢复哈希不一致。'}
    }elseif([IO.File]::Exists($full)){[IO.File]::Delete($full)}
}
function CTRuntime {param([string]$Operation,[string]$Root,$Payload)
    if($script:TestAdapter){return & $script:TestAdapter $Operation $Root $Payload}
    $bridge=Get-Module RuntimeBridge | Select-Object -First 1
    if(-not $bridge){$bridge=Import-Module (Join-Path $PSScriptRoot 'RuntimeBridge.psm1') -PassThru -DisableNameChecking}
    & $bridge {param($Op,$DataRoot,$Data) Invoke-TCConnectionRuntime -Operation $Op -Root $DataRoot -Payload $Data} $Operation $Root $Payload
}
function CTLine {param([string]$Root,[string]$Id,[string]$ProfileId)
    if($script:TestAdapter){return CTRuntime 'Line' $Root ([pscustomobject]@{Id=$Id;ProfileId=$ProfileId})}
    Import-Module (Join-Path $PSScriptRoot 'LineStore.psm1') -DisableNameChecking
    $line=Get-TCLine -Root $Root -Id $Id
    $profile=if($ProfileId){Get-TCLineProfile -Root $Root -Id $Id -ProfileId $ProfileId}else{$null}
    [pscustomobject]@{Line=$line;Profile=$profile}
}
function CTNetworkContext {param([string]$Root)
    if($script:TestAdapter){return CTRuntime 'NetworkContext' $Root $null}
    $path=Join-Path $PSScriptRoot 'ProtocolSelection.psm1'
    if(-not [IO.File]::Exists($path)){return [pscustomobject]@{Fingerprint=$null;Status='Unavailable'}}
    Import-Module $path -DisableNameChecking
    Get-TCProtocolNetworkContext
}
function CTDefaultSelection {param([string]$Root,[string]$LineId,[string]$SelectionMode='SavedDefault')
    $pair=CTLine $Root $LineId $null;$line=$pair.Line
    if(-not $line){throw '[TC:RecommendationCheckRequired] 线路资料不可用，请先检查线路。'}
    $lineDigest=CTDigest $line;$recommendation=CTField $line Recommendation
    Import-Module (Join-Path $PSScriptRoot 'ProtocolSelection.psm1') -DisableNameChecking
    $context=$null
    if($recommendation){$context=CTNetworkContext $Root}
    if($script:TestAdapter){$choice=CTRuntime 'DefaultProfile' $Root ([pscustomobject]@{Id=$LineId;NetworkContext=$context;SelectionMode=$SelectionMode})}
    else{Import-Module (Join-Path $PSScriptRoot 'LineStore.psm1') -DisableNameChecking;$choice=Get-TCLineDefaultProfile -Root $Root -Id $LineId -NetworkContext $context -SelectionMode $SelectionMode}
    if(-not $choice){throw '[TC:RecommendationCheckRequired] 没有可核验的已保存默认，请明确选择连接方式。'}
    $choiceLine=CTField $choice Line
    if(($choiceLine -and (CTDigest $choiceLine) -cne $lineDigest) -or (CTDigest (CTField $choice Recommendation)) -cne (CTDigest $recommendation)){throw '[TC:RecommendationCheckRequired] 读取期间默认来源或线路 revision 已变化，请重新预览。'}
    $profileId=[string](CTField $choice ProfileId)
    if((CTField $choice RequiresCheck $false) -or $profileId -notin @('Udp','Tcp')){
        $code=[string](CTField $choice Code '')
        $tag=if($code -match '^[A-Za-z][A-Za-z0-9_]{0,63}$'){'[TC:'+$code+']'}else{'[TC:RecommendationCheckRequired]'}
        throw ($tag+' '+[string](CTField $choice Reason '没有有效默认方式，请先检查线路或明确选择连接方式。'))
    }
    $pair=CTLine $Root $line.LineId $profileId;$profile=$pair.Profile
    if(-not $profile -or $profile.Id -cne $profileId -or (CTDigest $pair.Line) -cne $lineDigest){throw '[TC:RecommendationCheckRequired] 读取期间配置 revision 已变化，请重新预览。'}
    $selected=@($line.Profiles|Where-Object Id -ceq $profileId)
    if($selected.Count -ne 1 -or $selected[0].CandidateSHA256 -cne $profile.CandidateSHA256 -or -not [string]::Equals([string]$selected[0].ManifestPath,[string]$profile.ManifestPath,[StringComparison]::OrdinalIgnoreCase)){throw '[TC:RecommendationCheckRequired] 默认方式与实际 profile 配置不一致，请重新预览。'}
    $source=[string](CTField $choice Source 'None');$saved=CTField $line SavedConnectionPreference
    $blocked=Get-TCSavedConnectionPreferenceBlock -Line $line -Profile $profile
    if($blocked){throw ('[TC:'+$blocked+'] 最近检查的保护状态需要处理。')}
    if($SelectionMode -eq 'SavedDefault'){
        if(-not (Test-TCSavedConnectionPreference -Preference $saved -LineId $line.LineId -Profile $profile -Manifest (CTRead $profile.ManifestPath) -Now (CTNow)) -or $saved.ProfileId -cne $profileId -or $saved.Source -cne $source){throw '[TC:SavedDefaultInvalid] 已保存默认的真实来源、配置或设备身份无法核验。'}
        if($recommendation -and $recommendation.Status -eq 'Recommended'){
            $at=[DateTimeOffset]::MinValue
            if(-not [DateTimeOffset]::TryParse([string]$recommendation.CheckedAtUtc,[ref]$at) -or -not (Test-TCProtocolRecommendationRecorded -Recommendation $recommendation -Profiles @($line.Profiles) -RecordedAt $at)){throw '[TC:RecommendationCheckRequired] 当前记录的推荐证据已损坏或配置发生变化，不能当作仅过期。'}
        }
    }elseif($SelectionMode -eq 'CurrentRecommendation'){
        if(-not $context -or $context.Status -ne 'Available' -or $source -notin @('Reachability','PolicyDefault','Performance','Stability') -or -not $recommendation -or $recommendation.Source -cne $source -or $recommendation.RecommendedProfileId -cne $profileId -or -not (Test-TCProtocolRecommendationCurrent -Recommendation $recommendation -Profiles @($line.Profiles) -NetworkContext $context)){throw '[TC:RecommendationCheckRequired] 当前推荐已过期、网络改变或绑定无效。'}
    }else{throw '[TC:RecommendationCheckRequired] 未识别的连接选择模式。'}
    [pscustomobject]@{LineId=$line.LineId;LineRevision=$line.Revision;ProfileId=$profileId;Source=$source;SelectionMode=$SelectionMode;SavedConnectionPreference=$saved;CandidateSHA256=$profile.CandidateSHA256;ProfileManifestPath=$profile.ManifestPath;ProfileManifestSHA256=(CTField $profile ManifestSHA256);Recommendation=$recommendation;RecommendationCurrent=[bool](CTField $choice RecommendationCurrent $false);RecommendationState=(CTField $choice RecommendationState);NetworkFingerprint=$(if($SelectionMode -eq 'CurrentRecommendation'){$recommendation.NetworkFingerprint}else{$null})}
}
function CTDefaultApproval {param($Selection)
    # Freshness is display metadata. Passing the expiry boundary alone must not
    # invalidate an approved saved-default attempt; new evidence still does.
    [ordered]@{LineId=$Selection.LineId;LineRevision=$Selection.LineRevision;ProfileId=$Selection.ProfileId;Source=$Selection.Source;SelectionMode=$Selection.SelectionMode;SavedConnectionPreference=$Selection.SavedConnectionPreference;CandidateSHA256=$Selection.CandidateSHA256;ProfileManifestPath=$Selection.ProfileManifestPath;ProfileManifestSHA256=$Selection.ProfileManifestSHA256;Recommendation=$Selection.Recommendation;NetworkFingerprint=$Selection.NetworkFingerprint}
}
function CTOpenLock {param([string]$Path)
    try{[IO.File]::Open((CTPath $Path),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}catch{throw ('连接或资料操作正在进行，请稍后重新预览。锁：'+[IO.Path]::GetFileName($Path))}
}
function CTLocks {param([string]$Root,[bool]$SessionLockHeld=$false,[string]$LineId,[switch]$ReconcileLines)
    $locks=New-Object 'Collections.Generic.List[object]'
    try{
        if(-not $SessionLockHeld){$locks.Add((CTOpenLock (Join-Path $Root '.session.lock')))}
        $store=Join-Path $Root 'Product'
        if([IO.Directory]::Exists($store)){$locks.Add((CTOpenLock (Join-Path $store '.store.lock')))}
        $lineIds=@($LineId|Where-Object {$_})
        if($ReconcileLines){
            # Session and store locks are already held. Acquire canonical line
            # locks before preferences, in the same order as normal commits.
            $dir=Join-Path $Root 'connection-transactions'
            if([IO.Directory]::Exists($dir)){
                $lineIds=@(Get-ChildItem -LiteralPath $dir -Filter '*.json'|ForEach-Object {CTField (CTRead $_.FullName) LineId ''}|Where-Object {$_ -cmatch '^[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}$'}|Sort-Object -Unique)
            }
        }
        foreach($id in $lineIds){
            $lineRoot=Join-Path (Join-Path $store 'lines') $id
            if(-not [IO.Directory]::Exists($lineRoot)){if($ReconcileLines){continue};throw '请先登记不可变线路 profile，再切换连接方式。'}
            $locks.Add((CTOpenLock (Join-Path $lineRoot '.line.lock')))
        }
        $locks.Add((CTOpenLock (Join-Path $Root '.preferences.lock')))
        return ,$locks
    }catch{foreach($lock in $locks){$lock.Dispose()};throw}
}
function CTCloseLocks {param($Locks) if($Locks){for($i=$Locks.Count-1;$i -ge 0;$i--){$Locks[$i].Dispose()}}}
function CTIdentity {param($Observed)
    [ordered]@{SessionId=(CTField $Observed SessionId);SupervisorPid=(CTField $Observed SupervisorPid);SupervisorStartedAt=(CTField $Observed SupervisorStartedAt);EnginePid=(CTField $Observed EnginePid);EngineStartedAt=(CTField $Observed EngineStartedAt);ManifestPath=(CTField $Observed ManifestPath);CandidateSHA256=(CTField $Observed CandidateSHA256)}
}
function CTAssertKnown {param($Observed)
    if(-not $Observed -or $Observed.State -notin @('Running','Stopped') -or -not $Observed.OwnershipKnown){throw '[TC:NeedsRecovery] 会话归属或停止状态无法核实，禁止启动第二个引擎。'}
    if($Observed.State -eq 'Running' -and (-not $Observed.SessionId -or -not $Observed.EnginePid -or -not $Observed.EngineStartedAt -or -not $Observed.SupervisorPid -or -not $Observed.SupervisorStartedAt)){throw '[TC:NeedsRecovery] 缺少实际进程身份或出生时间，禁止切换。'}
}
function CTAssertStopped {param([string]$Root)
    $actual=CTRuntime 'Observe' $Root $null;CTAssertKnown $actual
    if($actual.State -ne 'Stopped'){throw '[TC:NeedsRecovery] 尚未确认原会话完全停止，禁止启动第二个引擎。'}
    return $actual
}
function CTManifest {param([string]$Root,[string]$Path,[string]$ExpectedHash)
    $full=CTPath $Path;$prefix=(CTPath $Root).TrimEnd('\')+'\'
    if(-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw '连接配置必须位于指定数据根内。'}
    $manifest=CTRead $full
    if(-not $manifest -or -not $manifest.SyntaxValidated -or -not $manifest.CandidatePath){throw '连接配置尚未通过语法校验。'}
    $engineHash=[string](CTField $manifest EngineSHA256 '')
    if($engineHash -and ((CTHash ([string](CTField $manifest EnginePath ''))) -cne $engineHash)){throw '[TC:EngineChanged] 连接引擎已变化，请重新准备并检查此连接方式；当前连接未改变。'}
    $config=CTPath $manifest.CandidatePath
    if(-not $config.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw '候选配置不能位于数据根之外。'}
    $hash=CTHash $config
    if(-not $hash -or -not $manifest.CandidateSHA256 -or $hash -cne [string]$manifest.CandidateSHA256 -or ($ExpectedHash -and $hash -cne $ExpectedHash)){throw '连接配置完整性已变化，请重新准备或预览。'}
    [pscustomobject]@{ManifestPath=$full;ManifestSHA256=(CTHash $full);CandidatePath=$config;CandidateSHA256=$hash;Manifest=$manifest}
}
function CTServerBinding {param([string]$Root,$Line,$Manifest)
    Import-Module (Join-Path $PSScriptRoot 'ProtocolSelection.psm1') -DisableNameChecking
    $state=Get-TCLineServerBindingState -LineId $Line.LineId -AliasIds (@(CTField $Line AliasIds @())+@((CTField $Line SourceNodeId))) -ServerPublicKey ([string](CTField $Manifest ServerPublicKey '')) -Registry (CTRead (Join-Path $Root 'servers\registry.json'))
    if(-not $state.Allowed){throw ('[TC:'+$state.Code+'] '+$state.Message)}
    return $state.Bindings
}
function CTTerminal {param($Transaction) $Transaction.Status -in @('Completed','RolledBack','ResolvedStopped','Aborted')}
function CTPending {param([string]$Root)
    $dir=Join-Path $Root 'connection-transactions'
    if([IO.Directory]::Exists($dir)){foreach($file in @(Get-ChildItem -LiteralPath $dir -Filter '*.json')){$tx=CTRead $file.FullName;if(-not (CTTerminal $tx)){return $tx}}}
}
function CTAssertProbeCleanup {param([string]$Root)
    # Inspect persisted receipts only. Recovery belongs to the probe workflow;
    # expiry never authorizes killing a probe, ending a trace or deleting files.
    $dir=CTPath (Join-Path $Root 'probes')
    if(-not [IO.Directory]::Exists($dir)){return}
    foreach($run in @(Get-ChildItem -LiteralPath $dir -Directory)){
        if($run.Name -cnotmatch '^[a-fA-F0-9]{8}-(?:[a-fA-F0-9]{4}-){3}[a-fA-F0-9]{12}$'){continue}
        $null=CTPath $run.FullName;$owner=CTRead (Join-Path $run.FullName 'ownership.json');$result=CTRead (Join-Path $run.FullName 'result.json')
        if($owner -and ((CTField $owner SchemaVersion 0) -ne 1 -or (CTField $owner RunId '') -cne $run.Name -or (CTField $owner State '') -cne 'Stopped' -or ((CTField $owner TraceGuid) -and (CTField $owner TraceState '') -cne 'Stopped'))){throw '[TC:NeedsRecovery] 探针进程或跟踪的归属、停止及清理尚未确认，请先核对恢复。'}
        if([IO.File]::Exists((Join-Path $run.FullName 'candidate.private.json')) -or ($result -and -not (CTField $result CleanupComplete $false))){throw '[TC:NeedsRecovery] 上次独立检查尚未完成清理，不能连接或启动第二个引擎。'}
    }
}
function CTBaseline {param([string]$Root,[string]$LineId,[string]$ProfileId,[string]$ManifestPath,$Intent,[bool]$DefaultSelection=$false,[string]$SelectionMode='SavedDefault')
    # Trading-app and isolation checks precede all candidate checks/mutations.
    $null=CTRuntime 'Preflight' $Root $null
    if(CTPending $Root){throw '[TC:NeedsRecovery] 存在尚未结束的连接事务，请先核对实际状态。'}
    CTAssertProbeCleanup $Root
    $observed=CTRuntime 'Observe' $Root $null;CTAssertKnown $observed
    $default=$null
    if($DefaultSelection){
        $default=CTDefaultSelection $Root $LineId $SelectionMode
        if($ProfileId -and $ProfileId -ne $default.ProfileId){throw '[TC:RecommendationCheckRequired] 默认连接方式已变化，请重新预览。'}
        $LineId=$default.LineId;$ProfileId=$default.ProfileId
    }
    $line=$null;$profile=$null
    if($ManifestPath){$target=CTManifest $Root $ManifestPath $null}
    else{
        $pair=CTLine $Root $LineId $ProfileId;$line=$pair.Line;$profile=$pair.Profile
        if(-not $line -or -not $profile -or $profile.Id -ne $ProfileId -or $profile.PreparationState -notin @('Ready','SyntaxValidated','Prepared')){throw '[TC:ProfileConfigurationMissing] 所选连接方式尚未准备完成。'}
        Import-Module (Join-Path $PSScriptRoot 'ProtocolSelection.psm1') -DisableNameChecking
        $eligibility=Get-TCConnectionEligibility -Line $line -Profile $profile
        if(-not $eligibility.CanConnect){throw ('[TC:'+$eligibility.Code+'] '+$eligibility.Message)}
        if([int]$line.Revision -lt 1 -or -not [IO.Directory]::Exists((Join-Path $Root ('Product\lines\'+$line.LineId)))){throw '请先登记不可变线路 profile，再预览切换。'}
        $LineId=[string]$line.LineId;$target=CTManifest $Root $profile.ManifestPath $profile.CandidateSHA256
        if([string](CTField $target.Manifest EngineSHA256 '') -cnotmatch '^[A-F0-9]{64}$'){throw '[TC:EngineBindingRequired] 已登记连接方式缺少可信引擎版本，请重新准备。'}
        if($default -and ($default.LineRevision -ne $line.Revision -or $default.CandidateSHA256 -cne $target.CandidateSHA256 -or -not [string]::Equals([string]$default.ProfileManifestPath,[string]$target.ManifestPath,[StringComparison]::OrdinalIgnoreCase) -or ($default.ProfileManifestSHA256 -and $default.ProfileManifestSHA256 -cne $target.ManifestSHA256))){throw '[TC:RecommendationCheckRequired] 默认预览与目标 revision、manifest 或配置哈希不一致，请重新预览。'}
    }
    $serverBinding=@(if($line){CTServerBinding $Root $line $target.Manifest})
    if($line -and -not (CTField $target.Manifest NetworkPolicy)){
        throw '[TC:NetworkPolicyUpdateRequired] 正式连接需要明确的物理网卡策略，请先确认本机网络。'
    }
    $prefs=CTRuntime 'Preferences' $Root $null
    $desired=$prefs|ConvertTo-Json -Depth 20|ConvertFrom-Json
    if($Intent){foreach($property in $Intent.PSObject.Properties){
        # Preserve the preference field order used by the approved preview.
        # Add-Member -Force removes and re-appends existing fields, changing
        # the digest even when a Session caller supplies identical intent.
        $existing=$desired.PSObject.Properties[$property.Name]
        if($existing){$existing.Value=$property.Value}
        else{$desired|Add-Member NoteProperty $property.Name $property.Value}
    }}
    if($ManifestPath){$desired|Add-Member NoteProperty ProfileId $null -Force}
    if($line){
        $desired.NodeId=$LineId;$desired|Add-Member NoteProperty ProfileId $ProfileId -Force
        # A profile switch validates this WireGuard transport, never a saved
        # provider selector. Keep that provider in Original for failure recovery.
        $desired.Exit='HongKong'
    }
    $validation=CTRuntime 'ValidateIntent' $Root ([pscustomobject]@{Manifest=$target.Manifest;Intent=$desired;ProfileId=$(if($line){$ProfileId}else{$null});LineId=$LineId})
    $target|Add-Member NoteProperty ExitEvidence (CTField $validation ExitEvidence) -Force
    $deployment=CTSnapshotFile (Join-Path $Root 'deployment.json')
    $index=CTSnapshotFile (Join-Path $Root 'Product\index.json')
    $preferenceFile=CTSnapshotFile (Join-Path $Root 'ui-preferences.json')
    $originalManifest=$null
    if($deployment.Exists){$d=CTRead $deployment.Path;if(-not $d.ManifestPath){throw '原 deployment 缺少 manifest 引用。'};$originalManifest=CTSnapshotFile $d.ManifestPath;if(-not $originalManifest.Exists){throw '原配置资料丢失，不能保证恢复。'}
        if($observed.State -eq 'Running' -and -not [string]::Equals([string]$observed.ManifestPath,[string]$d.ManifestPath,[StringComparison]::OrdinalIgnoreCase)){throw '[TC:NeedsRecovery] 实际会话与 deployment 引用不一致。'}
    }elseif($observed.State -eq 'Running'){throw '[TC:NeedsRecovery] 运行会话缺少原 deployment。'}
    if($observed.State -eq 'Running'){
        # The rollback configuration must also pass the real route validator
        # before we stop its session. Keep original preferences independent.
        $null=CTRuntime 'ValidateIntent' $Root ([pscustomobject]@{Manifest=(CTRead $originalManifest.Path);Intent=$prefs;ProfileId=$null;LineId=$null})
    }
    if($line){
        if(-not $index.Exists){throw '线路缺少节点库，不能提交活动引用。'}
        $idx=CTRead $index.Path;$source=@($idx.nodes|Where-Object id -eq $line.SourceNodeId)
        if($source.Count -ne 1){throw '线路来源节点不唯一或已变化。'}
        $aliases=@($line.AliasIds)+@($line.SourceNodeId)
        $refs=@($idx.nodes|Where-Object {$aliases -contains $_.id}|ForEach-Object {[pscustomobject]@{Id=$_.id;ManifestPath=$_.manifestPath}})
    }else{$refs=@()}
    $baseline=[pscustomobject]@{Root=(CTPath $Root);LineId=$LineId;ProfileId=$ProfileId;LineRevision=(CTField $line Revision);SourceNodeId=(CTField $line SourceNodeId);ServerBinding=$serverBinding;AliasIds=@(CTField $line AliasIds @());Target=$target;Original=[pscustomobject]@{WasRunning=($observed.State -eq 'Running');Observed=$observed;Identity=(CTIdentity $observed);Manifest=$originalManifest;Deployment=$deployment;Index=$index;PreferenceFile=$preferenceFile;Preferences=$prefs;References=$refs};Intent=$desired}
    $baseline|Add-Member NoteProperty Digest (CTDigest ([ordered]@{Root=$baseline.Root;LineId=$LineId;ProfileId=$ProfileId;LineRevision=$baseline.LineRevision;SourceNodeId=$baseline.SourceNodeId;ServerBinding=$serverBinding;AliasIds=$baseline.AliasIds;TargetManifestHash=$target.ManifestSHA256;TargetHash=$target.CandidateSHA256;ExitEvidence=$target.ExitEvidence;OriginalIdentity=$baseline.Original.Identity;OriginalState=$observed.State;OriginalManifestHash=$(if($originalManifest){$originalManifest.SHA256}else{$null});DeploymentHash=$deployment.SHA256;IndexHash=$index.SHA256;PreferenceHash=$preferenceFile.SHA256;Preferences=$prefs;Intent=$desired;ActualMode=(CTField $observed Mode);ActualExit=(CTField $observed Exit);ActualDaily=(CTField $observed Daily);Guard=(CTField $observed Guard)}))
    $baseline|Add-Member NoteProperty DefaultSelection $default
    if($DefaultSelection){$baseline.Digest=CTDigest ([ordered]@{Baseline=$baseline.Digest;Default=(CTDefaultApproval $default)})}
    return $baseline
}
function CTPreview {param([string]$Root,[string]$LineId,[string]$ProfileId,[string]$ManifestPath,$Intent,[bool]$DefaultSelection=$false,[string]$SelectionMode='SavedDefault')
    $baseline=CTBaseline $Root $LineId $ProfileId $ManifestPath $Intent $DefaultSelection $SelectionMode
    $expiry=(CTNow).AddMinutes(10).ToUnixTimeSeconds()
    $approvalDigest=CTDigest ([ordered]@{Baseline=$baseline.Digest;ExpiresAt=$expiry})
    [pscustomobject]@{LineId=$baseline.LineId;ProfileId=$baseline.ProfileId;PreviewToken=($(if($DefaultSelection -and $SelectionMode -eq 'CurrentRecommendation'){'ct3:'}elseif($DefaultSelection){'ct2:'}else{'ct1:'})+ $expiry+':'+$approvalDigest);CanSwitch=$true;Message=$(if($baseline.SourceNodeId){'将停止当前会话，目标交易出口使用该自建线路（HongKong/hk），再验证所选连接方式；日常和 AI 意图保留，失败时恢复原出口。请保持 NinjaTrader 退出。'}else{'将停止当前会话后切换并验证；失败时按原运行状态恢复。请保持 NinjaTrader 退出。'});TargetExit=$baseline.Intent.Exit;ExitEvidence=$baseline.Target.ExitEvidence;TargetHash=$baseline.Target.CandidateSHA256;Observed=$baseline.Original.Observed;Baseline=$baseline;Recommendation=(CTField $baseline.DefaultSelection Recommendation);DefaultSource=(CTField $baseline.DefaultSelection Source);SelectionMode=(CTField $baseline.DefaultSelection SelectionMode 'ExplicitProfile');SavedConnectionPreference=(CTField $baseline.DefaultSelection SavedConnectionPreference);RecommendationCurrent=[bool](CTField $baseline.DefaultSelection RecommendationCurrent $false);RecommendationState=(CTField $baseline.DefaultSelection RecommendationState)}
}
function Get-TCDefaultConnectionSwitchPreview {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][string]$LineId,[ValidateSet('SavedDefault','CurrentRecommendation')][string]$SelectionMode='SavedDefault')
    try{$preview=CTPreview (CTPath $Root) $LineId $null $null $null $true $SelectionMode;$preview.PSObject.Properties.Remove('Baseline');return $preview}
    catch{
        $failure=$_;$profileId=$null
        try{$line=(CTLine (CTPath $Root) $LineId $null).Line;$profileId=[string](CTField (CTField $line SavedConnectionPreference) ProfileId (CTField $line DefaultProfileId))}catch{}
        if($profileId -notin @('Udp','Tcp')){$profileId=$null}
        CTPreviewFailure $failure $LineId $profileId
    }
}
function Get-TCConnectionSwitchPreview {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][string]$LineId,[Parameter(Mandatory=$true)][ValidateSet('Udp','Tcp')][string]$ProfileId)
    try{$preview=CTPreview (CTPath $Root) $LineId $ProfileId $null $null;$preview.PSObject.Properties.Remove('Baseline');return $preview}
    catch{CTPreviewFailure $_ $LineId $ProfileId}
}
function CTPreviewFailure {param($ErrorRecord,[string]$LineId,[string]$ProfileId)
    $failure=CTFailure $ErrorRecord 'BeforeStop'
    $action=switch -Regex ($failure.Code){'^SavedDefault(Missing|Invalid)$'{'ChooseProfile';break}'ProfileConfigurationMissing|EngineBindingRequired'{'CompleteProfile';break}'DiagnosticAddressChanged|NetworkPolicyUpdateRequired'{'UpdateNetworkBinding';break}'DiagnosticInterface'{'ChooseNetwork';break}'Server|Identity|ExitMismatch'{'CheckServerIdentity';break}'NeedsRecovery'{'ResolveSession';break}default{'ViewDiagnostics'}}
    [pscustomobject]@{LineId=$LineId;ProfileId=$ProfileId;PreviewToken=$null;CanSwitch=$false;Code=$failure.Code;Message=('[TC:'+$failure.Code+'] '+$failure.Message);Status=$(if($action -in @('ChooseProfile','CompleteProfile','UpdateNetworkBinding','ChooseNetwork')){'NeedsCompletion'}else{'NeedsRecovery'});NextAction=$action;Recommendation=$null;DefaultSource='None';Observed=$null}
}
function CTPhase {param($Transaction,[string]$Phase,[string]$Status='InProgress')
    $Transaction.Phase=$Phase;$Transaction.Status=$Status;$Transaction.UpdatedAt=(CTNow).ToString('o')
    $budget=CTField $Transaction Budget
    if($budget -and (CTField $budget StartTicks 0)){
        $recovering=[bool](CTField $budget RecoveryStartTicks 0)
        $start=if($recovering){$budget.RecoveryStartTicks}else{$budget.StartTicks};$limit=if($recovering){$budget.RecoverySeconds}else{$budget.TransactionSeconds}
        $elapsed=CTSecondsBetween $start (CTTicks)
        $Transaction|Add-Member NoteProperty Progress ([pscustomobject]@{Phase=$Phase;Status=$Status;Recovery=$recovering;BudgetSeconds=$limit;ElapsedSeconds=[Math]::Round($elapsed,3);RemainingSeconds=[Math]::Max(0,[Math]::Floor($limit-$elapsed));AtUtc=$Transaction.UpdatedAt}) -Force
    }
    $Transaction.History=@($Transaction.History)+@([pscustomobject]@{Phase=$Phase;Status=$Status;At=$Transaction.UpdatedAt})
    CTWrite $Transaction.JournalPath $Transaction
}
function CTResult {param($Transaction,$Observed)
    $message=switch($Transaction.Status){
        'Completed'{'已切换连接方式，实际出口验证通过。'}
        'RolledBack'{if($Transaction.Original.WasRunning){'切换失败，已恢复原配置并重连原会话，实际出口复测通过。'}else{'切换失败，已恢复原配置，保持未连接。'}}
        'ResolvedStopped'{'已核对原配置和实际停止状态，故障任务已结束。当前保持未连接；可重新选择线路并点击连接。未自动重连，也未宣称原连接或交易业务已恢复。'}
        'Aborted'{'切换没有开始：原连接、配置和偏好均未改动。'}
        default{'[TC:NeedsRecovery] 连接事务需要恢复；请核对实际会话。配置还原不代表原连接已恢复，不会自动启动第二个引擎。'}
    }
    $proof=CTField $Transaction RecoveryProof
    if($Transaction.Status -eq 'NeedsRecovery' -and $proof){
        $reason=switch($proof.ReasonCode){
            'OriginalWorkerStillActive'{'原执行器尚未退出，请等待原操作结束后核对。'}
            'OriginalWorkerUnresolved'{'原请求的执行器归属尚未核实，请查看原操作记录。'}
            'LegacyWorkerEvidenceMissing'{'旧请求缺少执行器证明，保留原记录，不能重放连接。'}
            'SessionNotStopped'{'实际会话仍在运行，请先通过正常断开操作停止，再核对结果。'}
            'OriginalConfigurationChanged'{'原配置或引用与恢复快照不一致，请使用原事务恢复资料。'}
            'OriginalManifestMissing'{'原线路配置缺失，请先找回原配置资料。'}
            'OriginalLineMissing'{'原线路资料缺失，请核对资料恢复记录。'}
            'ProxyRecoveryPending'{'代理设置尚未完成恢复，请先核对代理恢复记录。'}
            default{'停止状态、配置完整性或清理证据尚不完整，请查看原事务详情。'}
        }
        $message=$reason+[Environment]::NewLine+'当前连接状态尚未确认，本次核对已结束。'
    }
    if($Transaction.Status -eq 'Completed' -and $Transaction.ProfileId -and -not (CTField $Transaction.TargetCheck ServerAttributionVerified $false)){$message='所选自建线路连接方式的 HTTPS/DNS 转发已通过；出口归属仅为 ConfiguredEndpoint 推定，未权威验证。'}
    $failure=CTField $Transaction Failure
    if(-not $failure -and $Transaction.Error){$failure=CTFailure $Transaction.Error 'VerifyTarget'}
    if($failure -and $Transaction.Status -ne 'Completed'){$message=$failure.Message+[Environment]::NewLine+$message+[Environment]::NewLine+'请按本步骤提示处理后可重新连接。'}
    [pscustomobject]@{TransactionId=$Transaction.Id;RequestId=(CTField $Transaction RequestId '');LineId=$Transaction.LineId;ProfileId=$Transaction.ProfileId;Status=$Transaction.Status;Phase=$Transaction.Phase;Message=$message;Observed=$Observed;Activated=($Transaction.Status -eq 'Completed');Check=$Transaction.TargetCheck;ConfigurationRestored=[bool]$Transaction.ConfigurationRestored;ConnectionRestored=[bool]$Transaction.ConnectionRestored;RecoveryCheck=$Transaction.RecoveryCheck;JournalPath=$Transaction.JournalPath;PreviousDeploymentBackup=$Transaction.JournalPath;Error=$(if($failure){$failure.Message}else{$null});Failure=$failure;RecoveryFailure=(CTField $Transaction RecoveryFailure);Budget=(CTField $Transaction Budget);LastCheckBudget=(CTField $Transaction LastCheckBudget);RecoveryProof=(CTField $Transaction RecoveryProof)}
}
function CTStopOwned {param([string]$Root,$Owned,[string]$Operation,$Transaction=$null,$Budget)
    CTEnsureBudget $Budget $Operation 'ConnectionTimeout'
    $actual=CTRuntime 'Observe' $Root $null;CTAssertKnown $actual
    if($actual.State -eq 'Stopped'){return $actual}
    if((CTDigest (CTIdentity $actual)) -cne (CTDigest (CTIdentity $Owned))){throw '[TC:NeedsRecovery] 会话身份已变化，未停止不属于本事务的进程。'}
    try{$null=CTRuntime 'Preflight' $Root $null}catch{throw '[TC:TradingAppRunning] NinjaTrader 正在运行，未停止任何连接。'}
    CTEnsureBudget $Budget $Operation 'ConnectionTimeout'
    # Everything above only reads. From here the stop may be partial, so a
    # failure can no longer be closed as a switch that never started.
    if($Transaction){$Transaction|Add-Member NoteProperty StopAttempted $true -Force}
    $null=CTRuntime $Operation $Root (CTBudgetPayload ([pscustomobject]@{Identity=$Owned}) $Budget)
    CTEnsureBudget $Budget $Operation 'ConnectionTimeout'
    return CTAssertStopped $Root
}
function CTVerify {param([string]$Root,$Transaction,[bool]$Original=$false,$Budget)
    $checkSeconds=45
    if($Budget){$checkSeconds=[int][Math]::Max(1,[Math]::Min(45,[Math]::Floor((CTBudgetRemaining $Budget))))}
    $checkBudget=CTNewBudget $checkSeconds
    CTEnsureBudget $Budget $(if($Original){'VerifyOriginal'}else{'VerifyTarget'}) 'ConnectionTimeout'
    $manifest=if($Original){CTRead $Transaction.Original.Manifest.Path}else{$Transaction.Target.Manifest}
    $intent=if($Original){$Transaction.Original.Preferences}else{$Transaction.Intent}
    $expected=if($Original){$Transaction.Original.Observed}else{$null}
    $profile=if(-not $Original -and $Transaction.SourceNodeId){$Transaction.ProfileId}else{$null}
    $payload=CTBudgetPayload ([pscustomobject]@{Manifest=$manifest;Intent=$intent;Expected=$expected;Original=$Original;ProfileId=$profile;LineId=$Transaction.LineId}) $checkBudget
    $result=CTRuntime 'Verify' $Root $payload
    CTEnsureBudget $checkBudget $(if($Original){'VerifyOriginal'}else{'VerifyTarget'}) 'ConnectionCheckTimeout'
    if($Budget){CTEnsureBudget $Budget $(if($Original){'VerifyOriginal'}else{'VerifyTarget'}) 'ConnectionTimeout'}
    $Transaction|Add-Member NoteProperty LastCheckBudget ([pscustomobject]@{BudgetSeconds=$checkSeconds;StartedAtUtc=$checkBudget.StartedAtUtc;ElapsedSeconds=[Math]::Round((CTSecondsBetween $checkBudget.StartTicks (CTTicks)),3);Original=$Original}) -Force
    if($Original){$Transaction.RecoveryCheck=$result}else{$Transaction.TargetCheck=$result}
    if(-not $result.ExitHttp -or -not $result.ObservedIP -or -not $result.DnsHttps -or -not $result.ExitVerified){throw ('[TC:LineForwardingUnverified] 实际 TLS/HTTPS、DNS 或所选出口证据未通过核验。'+[string](CTField $result Code ''))}
    if($profile -and ($intent.Exit -ne 'HongKong' -or $result.ActualExit -ne 'hk' -or -not (CTField $result ProfileValidated $false))){throw '[TC:ProfileExitUnverified] 所选连接方式必须经已核验的自建 hk 出口验证，服务商证据不能代替。'}
    return $result
}
function CTExecute {param([string]$Root,[string]$LineId,[string]$ProfileId,[string]$PreviewToken,[string]$ManifestPath,$Intent,[bool]$SessionLockHeld=$false,[string]$RequestId='')
    $locks=$null;$tx=$null;$operationBudget=CTNewBudget 120;$recoveryBudget=$null
    try{
        $Root=CTPath $Root
        if($RequestId -and $RequestId -cnotmatch '^[a-f0-9]{32}$'){throw '[TC:InvalidRequest] 请求编号无效。'}
        # Guard before acquiring/creating lock or journal files.
        CTEnsureBudget $operationBudget 'Preflight' 'ConnectionTimeout'
        $null=CTRuntime 'Preflight' $Root $null
        # Resolve aliases read-only, then acquire the canonical line lock in
        # exactly the same order as LineStore's preparation writer.
        $canonical=$LineId
        if($LineId){$canonical=[string](CTLine $Root $LineId $ProfileId).Line.LineId}
        $locks=CTLocks $Root $SessionLockHeld $canonical
        $useDefault=[bool]($PreviewToken -cmatch '^ct[23]:');$selectionMode=if($PreviewToken -clike 'ct3:*'){'CurrentRecommendation'}else{'SavedDefault'}
        CTEnsureBudget $operationBudget 'Prepare' 'ConnectionTimeout'
        $baseline=CTBaseline $Root $LineId $ProfileId $ManifestPath $Intent $useDefault $selectionMode
        $ProfileId=$baseline.ProfileId
        if(-not $PreviewToken -or $PreviewToken -cnotmatch '^ct[123]:(\d+):([A-F0-9]{64})$'){throw '缺少有效切换预览，请重新预览并确认。'}
        $expiry=[long]$matches[1];$digest=$matches[2]
        if($expiry -lt (CTNow).ToUnixTimeSeconds() -or $expiry -gt (CTNow).AddMinutes(11).ToUnixTimeSeconds() -or $digest -cne (CTDigest ([ordered]@{Baseline=$baseline.Digest;ExpiresAt=$expiry}))){throw '切换目标、原会话或偏好已变化，预览已失效，请重新预览。'}
        $journalRoot=Join-Path $Root 'connection-transactions';$null=[IO.Directory]::CreateDirectory($journalRoot)
        foreach($file in @(Get-ChildItem -LiteralPath $journalRoot -Filter '*.json')){if((CTRead $file.FullName).Approval.PreviewToken -ceq $PreviewToken){throw '此预览已执行，请重新预览，不能重放事务。'}}
        $id=[guid]::NewGuid().ToString('N')
        $tx=[pscustomobject]@{SchemaVersion=1;Id=$id;Root=$Root;JournalPath=(Join-Path $journalRoot ($id+'.json'));LineId=$baseline.LineId;ProfileId=$ProfileId;SourceNodeId=$baseline.SourceNodeId;Original=$baseline.Original;Target=$baseline.Target;TargetHash=$baseline.Target.CandidateSHA256;ActiveManifestPath=(Join-Path $journalRoot ($id+'-approved.manifest'));ActiveManifestSHA256=$null;Intent=$baseline.Intent;Approval=[pscustomobject]@{PreviewToken=$PreviewToken;Digest=$digest;ExpiresAt=$expiry;Summary='明确批准一次停止、切换、验证及按原状态恢复';ApprovedAt=(CTNow).ToString('o')};Budget=[pscustomobject]@{TransactionSeconds=120;CheckSeconds=45;RecoverySeconds=90;GraceSeconds=15;StartedAtUtc=$operationBudget.StartedAtUtc};Status='InProgress';Phase='Prepared';UpdatedAt=$null;History=@();CandidateIdentity=$null;CandidateAttempted=$false;CandidateAttemptedAt=$null;OriginalStopped=$false;ConfigurationRestored=$false;ConnectionRestored=$false;TargetCheck=$null;RecoveryCheck=$null;Error=$null;RecoveryError=$null;Reconciliation=$null}
        $tx.Budget|Add-Member NoteProperty StartTicks $operationBudget.StartTicks -Force
        $tx|Add-Member NoteProperty DefaultSelection $baseline.DefaultSelection
        $tx|Add-Member NoteProperty RequestId $RequestId
        if($RequestId){$executor=[Diagnostics.Process]::GetCurrentProcess();try{$tx|Add-Member NoteProperty Executor ([pscustomobject]@{ProcessId=$executor.Id;ProcessStartedTicks=[string]$executor.StartTime.ToUniversalTime().Ticks})}finally{$executor.Dispose()}}
        CTPhase $tx 'Prepared'
        try{
            CTEnsureBudget $operationBudget 'BeforeStop' 'ConnectionTimeout'
            if($tx.Original.WasRunning){
                CTPhase $tx 'StopOriginal'
                $null=CTStopOwned $Root $tx.Original.Observed 'StopOriginal' $tx $operationBudget
            }else{$null=CTAssertStopped $Root}
            CTEnsureBudget $operationBudget 'OriginalStopped' 'ConnectionTimeout'
            $tx.OriginalStopped=$true;CTPhase $tx 'OriginalStopped'
            # Revalidate after stop and before pointer commit. Candidate files
            # are never transformed or checked by starting an identity probe.
            CTEnsureBudget $operationBudget 'RevalidateTarget' 'ConnectionTimeout'
            $check=CTManifest $Root $tx.Target.ManifestPath $tx.TargetHash
            if($check.ManifestSHA256 -cne $tx.Target.ManifestSHA256){throw '停止期间目标 manifest 已变化。'}
            if($useDefault -and (CTDigest (CTDefaultApproval (CTDefaultSelection $Root $baseline.LineId $selectionMode))) -cne (CTDigest (CTDefaultApproval $baseline.DefaultSelection))){throw '[TC:RecommendationCheckRequired] 停止期间默认来源、配置或检查状态已变化，恢复原连接。'}
            if($tx.SourceNodeId){$current=CTLine $Root $baseline.LineId $ProfileId;if($current.Line.Revision -ne $baseline.LineRevision -or (CTDigest @(CTServerBinding $Root $current.Line $check.Manifest)) -cne (CTDigest $baseline.ServerBinding)){throw '[TC:ServerBindingChanged] 停止期间线路或服务器身份绑定已变化。'}}
            CTEnsureBudget $operationBudget 'CommitTarget' 'ConnectionTimeout'
            CTPhase $tx 'CommitTarget'
            if($tx.SourceNodeId){$idx=CTRead $tx.Original.Index.Path;$source=@($idx.nodes|Where-Object id -eq $tx.SourceNodeId);if($source.Count -ne 1){throw '来源节点在提交前已变化。'};$source[0].manifestPath=$tx.Target.ManifestPath;CTWrite $tx.Original.Index.Path $idx}
            # The supervisor requires DeploymentApproved. Give it an approved
            # runtime manifest; the registered profile remains immutable.
            $approved=$tx.Target.Manifest|ConvertTo-Json -Depth 40|ConvertFrom-Json
            $approved|Add-Member NoteProperty DeploymentApproved $true -Force
            $approved|Add-Member NoteProperty TCTransactionId $tx.Id -Force
            $approved|Add-Member NoteProperty TCProfileManifestPath $tx.Target.ManifestPath -Force
            CTWrite $tx.ActiveManifestPath $approved;$tx.ActiveManifestSHA256=CTHash $tx.ActiveManifestPath
            CTWrite $tx.Original.Deployment.Path ([ordered]@{ManifestPath=$tx.ActiveManifestPath;ProfileManifestPath=$tx.Target.ManifestPath;LineId=$tx.LineId;ProfileId=$tx.ProfileId;TransactionId=$tx.Id;CandidateSHA256=$tx.TargetHash;SelectedAt=(CTNow).ToString('o');Stage='ConnectionTransaction';StartupMode=$tx.Intent.Mode;BootAutoStartEnabled=$false})
            CTWrite $tx.Original.PreferenceFile.Path $tx.Intent
            $null=CTAssertStopped $Root
            $null=CTRuntime 'Preflight' $Root $null
            CTAssertProbeCleanup $Root
            if($tx.SourceNodeId){$null=CTServerBinding $Root $current.Line $tx.Target.Manifest}
            CTEnsureBudget $operationBudget 'StartTarget' 'ConnectionTimeout'
            $tx.CandidateAttempted=$true;$tx.CandidateAttemptedAt=(CTNow).ToString('o');CTPhase $tx 'StartTarget'
            $null=CTRuntime 'Start' $Root (CTBudgetPayload ([pscustomobject]@{ManifestPath=$tx.ActiveManifestPath;TransactionId=$tx.Id}) $operationBudget)
            CTEnsureBudget $operationBudget 'StartTarget' 'ConnectionTimeout'
            $actual=CTRuntime 'Observe' $Root $null;CTAssertKnown $actual
            if($actual.State -ne 'Running' -or $actual.ManifestPath -ine $tx.ActiveManifestPath -or $actual.CandidateSHA256 -cne $tx.TargetHash){throw '候选实际会话与目标配置不一致。'}
            $tx.CandidateIdentity=$actual;CTPhase $tx 'ApplyOriginalIntent'
            $null=CTRuntime 'ApplyIntent' $Root (CTBudgetPayload ([pscustomobject]@{Manifest=$tx.Target.Manifest;Intent=$tx.Intent;Expected=$null;ProfileId=$tx.ProfileId;LineId=$tx.LineId}) $operationBudget)
            CTEnsureBudget $operationBudget 'ApplyOriginalIntent' 'ConnectionTimeout'
            CTPhase $tx 'VerifyTarget';$tx.TargetCheck=CTVerify $Root $tx $false $operationBudget
            $actual=CTRuntime 'Observe' $Root $null;CTAssertKnown $actual
            if((CTDigest (CTIdentity $actual)) -cne (CTDigest (CTIdentity $tx.CandidateIdentity))){throw '验证期间实际会话身份已变化。'}
            CTEnsureBudget $operationBudget 'Completed' 'ConnectionTimeout'
            CTPhase $tx 'Completed' 'Completed';return CTResult $tx $actual
        }catch{
            $aborted=(-not $tx.OriginalStopped -and -not (CTField $tx StopAttempted $false))
            $failure=CTFailure $_ $(if($aborted){'BeforeStop'}else{$tx.Phase});$tx|Add-Member NoteProperty Failure $failure -Force;$tx.Error='[TC:'+$failure.Code+'] '+$failure.Message
            # Nothing was stopped or rewritten yet. Close the journal instead of
            # leaving a recovery record that blocks every later connection.
            if($aborted){CTPhase $tx 'Aborted' 'Aborted';return CTResult $tx (CTRuntime 'Observe' $Root $null)}
            $recoveryBudget=CTNewBudget 90
            $tx.Budget|Add-Member NoteProperty RecoveryStartedAtUtc $recoveryBudget.StartedAtUtc -Force
            $tx.Budget|Add-Member NoteProperty RecoveryStartTicks $recoveryBudget.StartTicks -Force
            if(-not $tx.OriginalStopped){
                try{CTEnsureBudget $recoveryBudget 'ObserveAfterStopAttempt' 'RecoveryTimeout';$null=CTAssertStopped $Root;$tx.OriginalStopped=$true}catch{}
                if(-not $tx.OriginalStopped){CTPhase $tx 'NeedsRecovery' 'NeedsRecovery';return CTResult $tx (CTRuntime 'Observe' $Root $null)}
            }
            try{
                CTEnsureBudget $recoveryBudget 'RecoveryStart' 'RecoveryTimeout'
                if($tx.CandidateAttempted){
                    CTPhase $tx 'StopOwnedCandidate'
                    $actual=CTRuntime 'Observe' $Root $null;CTAssertKnown $actual
                    if($actual.State -eq 'Running'){
                        if(-not $tx.CandidateIdentity){
                            # Start may throw after launching. Recover ownership
                            # from actual births/hash; never assume a PID is ours.
                            if($actual.ManifestPath -ine $tx.ActiveManifestPath -or $actual.CandidateSHA256 -cne $tx.TargetHash -or ([DateTimeOffset]$actual.SupervisorStartedAt) -lt ([DateTimeOffset]$tx.CandidateAttemptedAt)){throw '候选启动结果未知且无法证明归属。'}
                            $tx.CandidateIdentity=$actual;CTPhase $tx 'StopOwnedCandidate'
                        }
                        $null=CTStopOwned $Root $tx.CandidateIdentity 'StopOwnedCandidate' $null $recoveryBudget
                    }else{$null=CTAssertStopped $Root}
                }else{$null=CTAssertStopped $Root}
                CTEnsureBudget $recoveryBudget 'RestoreOriginalReferences' 'RecoveryTimeout'
                CTPhase $tx 'RestoreOriginalReferences'
                if($tx.Original.Manifest){CTRestoreFile $tx.Original.Manifest}
                CTRestoreFile $tx.Original.Index;CTRestoreFile $tx.Original.Deployment
                CTPhase $tx 'RestoreOriginalIntent';CTRestoreFile $tx.Original.PreferenceFile
                $tx.ConfigurationRestored=$true;CTPhase $tx 'OriginalConfigurationRestored'
                $null=CTAssertStopped $Root
                if($tx.Original.WasRunning){
                    # Original config hash is checked again before reusing it.
                    $restored=CTManifest $Root $tx.Original.Manifest.Path $tx.Original.Observed.CandidateSHA256
                    $originalId=[string](CTField $restored.Manifest TCLineId (CTField $restored.Manifest node_id))
                    if($originalId){$null=CTServerBinding $Root ([pscustomobject]@{LineId=$originalId;AliasIds=@();SourceNodeId=$originalId}) $restored.Manifest}
                    CTEnsureBudget $recoveryBudget 'RestartOriginal' 'RecoveryTimeout'
                    CTPhase $tx 'RestartOriginal'
                    $null=CTRuntime 'Start' $Root (CTBudgetPayload ([pscustomobject]@{ManifestPath=$restored.ManifestPath;TransactionId=$tx.Id;Restoring=$true}) $recoveryBudget)
                    CTEnsureBudget $recoveryBudget 'RestartOriginal' 'RecoveryTimeout'
                    CTPhase $tx 'ReapplyOriginalIntent'
                    $null=CTRuntime 'ApplyIntent' $Root (CTBudgetPayload ([pscustomobject]@{Manifest=$restored.Manifest;Intent=$tx.Original.Preferences;Expected=$tx.Original.Observed}) $recoveryBudget)
                    CTEnsureBudget $recoveryBudget 'ReapplyOriginalIntent' 'RecoveryTimeout'
                    CTPhase $tx 'VerifyOriginal';$tx.RecoveryCheck=CTVerify $Root $tx $true $recoveryBudget
                    $actual=CTRuntime 'Observe' $Root $null;CTAssertKnown $actual
                    if($actual.State -ne 'Running' -or $actual.ManifestPath -ine $restored.ManifestPath -or $actual.CandidateSHA256 -cne $restored.CandidateSHA256){throw '重连后的原会话身份不符合原配置。'}
                    $tx.ConnectionRestored=$true
                }else{CTEnsureBudget $recoveryBudget 'ConfirmStopped' 'RecoveryTimeout';$actual=CTAssertStopped $Root;$tx.ConnectionRestored=$true}
                CTEnsureBudget $recoveryBudget 'RolledBack' 'RecoveryTimeout'
                CTPhase $tx 'RolledBack' 'RolledBack';return CTResult $tx $actual
            }catch{
                $failure=CTFailure $_ $tx.Phase;$tx|Add-Member NoteProperty RecoveryFailure $failure -Force;$tx.RecoveryError='[TC:'+$failure.Code+'] '+$failure.Message;CTPhase $tx 'NeedsRecovery' 'NeedsRecovery'
                $actual=$null;try{$actual=CTRuntime 'Observe' $Root $null}catch{}
                return CTResult $tx $actual
            }
        }
    }finally{CTCloseLocks $locks}
}
function Invoke-TCConnectionSwitch {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][string]$LineId,[Parameter(Mandatory=$true)][ValidateSet('Udp','Tcp')][string]$ProfileId,[Parameter(Mandatory=$true)][string]$PreviewToken,[string]$RequestId='')
    CTExecute $Root $LineId $ProfileId $PreviewToken $null $null -RequestId $RequestId
}
function Invoke-TCDefaultConnectionSwitch {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][string]$LineId,[Parameter(Mandatory=$true)][string]$PreviewToken)
    if($PreviewToken -cnotmatch '^ct2:'){throw '已保存默认连接需要相同选择模式的明确预览。'}
    CTExecute $Root $LineId $null $PreviewToken $null $null
}
function Invoke-CTSessionSwitch {param([string]$Root,[string]$LineId,[string]$ProfileId,[string]$ManifestPath,$Intent,[string]$PreviewToken,[bool]$SessionLockHeld,[bool]$DefaultSelection=$false,[string]$RequestId='')
    if(-not $PreviewToken){$preview=CTPreview $Root $LineId $ProfileId $ManifestPath $Intent $DefaultSelection;$PreviewToken=$preview.PreviewToken;$ProfileId=$preview.ProfileId}
    CTExecute $Root $LineId $ProfileId $PreviewToken $ManifestPath $Intent $SessionLockHeld -RequestId $RequestId
}
function CTReceiptWorkerEnded {param($Receipt)
    if([int](CTField $Receipt ProcessId 0) -le 0 -or [long](CTField $Receipt ProcessStartedTicks 0) -le 0){return $false}
    $process=$null
    try{
        $process=Get-Process -Id ([int]$Receipt.ProcessId) -ErrorAction Stop
        return ($process.HasExited -or $process.StartTime.ToUniversalTime().Ticks -ne [long]$Receipt.ProcessStartedTicks)
    }catch [Microsoft.PowerShell.Commands.ProcessCommandException]{return $true}
    catch{return $false}finally{if($process){$process.Dispose()}}
}
function CTReconcileStoppedSessionReceipts {param([string]$Root,[string[]]$RequestIds)
    # Compatibility for the 0.16.12 standalone timeout overflow. A timeout or
    # dead worker alone is never proof. Only the matching failed local Session,
    # its diagnostic and correlated stop marker can enter this recovery path.
    $runtimeLock=CTOpenLock (Join-Path $Root '.runtime-command.lock')
    try{
        foreach($id in @($RequestIds|Select-Object -Unique)){
            if($id -cnotmatch '^[a-f0-9]{32}$'){continue}
            $path=Join-Path $Root ('Product\jobs\'+$id+'.receipt.json')
            $receipt=CTRead $path
            if(-not $receipt -or $receipt.SchemaVersion -ne 1 -or $receipt.RequestId -cne $id -or $receipt.Action -cne 'Session' -or $receipt.Status -notin @('Dispatched','OutcomeUnknown')){continue}
            $blocked=[pscustomobject]@{RequestId=$id;Action='Session';Status='NeedsRecovery';ReconciliationKind='LocalSession';Message='原会话操作的停止或清理证据仍不完整，保留原记录。'}
            try{
                foreach($key in @('RunId','LineId','TransactionId','DeploymentMutation','DeploymentProbe')){if(CTField $receipt $key){throw 'Receipt has another recovery owner'}}
                if(-not (CTReceiptWorkerEnded $receipt)){throw 'Worker still alive or unknown'}
                $resultPath=Join-Path $Root ('Product\jobs\'+$id+'.result.json');$result=CTRead $resultPath
                if(-not $result -or $result.RequestId -cne $id -or $result.Action -cne 'Session' -or $result.Ok -ne $false -or -not $result.OutcomeUnknown -or $result.Code -cne 'WorkerStepFailed' -or $result.Phase -cne 'Executing' -or (CTField $result Data)){throw 'No matching failed Session result'}
                $diagnosticId=[string](CTField $result DiagnosticId '')
                if($diagnosticId -cnotmatch '^[a-f0-9]{32}$'){throw 'Missing failure diagnostic'}
                $diagnostic=CTRead (Join-Path $Root ('diagnostics\failures\'+$diagnosticId+'.json'))
                $chain=@($diagnostic.ExceptionChain|ForEach-Object {$_.Type}) -join '|'
                if($diagnostic.RequestId -cne $id -or $diagnostic.Action -cne 'Session' -or $chain -cne 'System.Management.Automation.MethodException|System.Management.Automation.PSInvalidCastException|System.OverflowException'){throw 'Different failure, keep unresolved'}
                $request=CTRead (Join-Path $Root ('Product\jobs\'+$id+'.request.json'))
                if($request -and ($request.RequestId -cne $id -or $request.Action -cne 'Session' -or $request.SessionAction -cne 'Disconnect')){throw 'Conflicting original request'}
                $stopPath=CTPath (Join-Path $Root 'stop.request')
                if(-not [IO.File]::Exists($stopPath)){throw 'No correlated stop request'}
                $stopAt=[DateTimeOffset]::Parse([IO.File]::ReadAllText($stopPath))
                $started=[DateTimeOffset]::Parse($receipt.StartedAtUtc);$failed=[DateTimeOffset]::Parse($diagnostic.AtUtc)
                if($stopAt -lt $started -or $stopAt -gt $failed -or $failed -lt $started -or ($failed-$started).TotalSeconds -gt 240){throw 'Stop request belongs to another operation'}
                if(CTPending $Root){throw 'Pending connection transaction'}
                foreach($file in @(Get-ChildItem -LiteralPath (Join-Path $Root 'connection-transactions') -Filter '*.json' -ErrorAction SilentlyContinue)){
                    if((CTField (CTRead $file.FullName) RequestId '') -ceq $id){throw 'Transaction owns this request'}
                }
                CTAssertProbeCleanup $Root
                foreach($file in @(Get-ChildItem -LiteralPath (Join-Path $Root 'proxy-recovery') -Filter '*.json' -ErrorAction SilentlyContinue)){
                    $entry=CTRead $file.FullName
                    if($entry.SchemaVersion -ne 1 -or $entry.Stage -notin @('Restored','Unchanged','UserRestored','UserKeptCurrent')){throw 'Proxy cleanup remains unresolved'}
                }
                $actual=CTAssertStopped $Root;$snapshot=CTRead (Join-Path $Root 'runtime.json')
                if(-not $snapshot -or $snapshot.State -notin @('Disconnected','Stopped') -or $snapshot.CleanupError -or $snapshot.SessionId -cne $actual.SessionId){throw 'No clean stopped snapshot'}
                $null=CTManifest $Root $actual.ManifestPath $actual.CandidateSHA256
                # Compare again before the atomic receipt write. Keep the failed
                # result and diagnostic intact; reconciliation is not success.
                $receiptHash=CTHash $path;$current=CTRead $path
                if($current.RequestId -cne $id -or $current.Status -notin @('Dispatched','OutcomeUnknown') -or -not (CTReceiptWorkerEnded $current)){throw 'Receipt or worker changed'}
                $again=CTAssertStopped $Root
                if($again.SessionId -cne $actual.SessionId -or $again.CandidateSHA256 -cne $actual.CandidateSHA256 -or (CTHash $path) -cne $receiptHash){throw 'Recovery evidence changed'}
                $proof=[pscustomobject]@{Kind='StandaloneStopOverflowReconciled';RequestId=$id;OriginalStatus=$current.Status;OriginalErrorId=(CTField $result ErrorId);DiagnosticId=$diagnosticId;ResultSHA256=(CTHash $resultPath);StoppedSessionId=$actual.SessionId;CandidateSHA256=$actual.CandidateSHA256;VerifiedAtUtc=(CTNow).ToString('o');NetworkOperationRequested=$false;OriginalActionSucceeded=$false}
                $current.Status='Reconciled';$current.UpdatedAtUtc=(CTNow).ToString('o');$current|Add-Member NoteProperty Resolution $proof -Force;CTWrite $path $current
                [pscustomobject]@{RequestId=$id;Action='Session';Status='ResolvedStopped';ReconciliationKind='LocalSession';Resolution=$proof;Message='已核对原操作失败后的停止与清理状态。当前未连接，可重新选择线路连接。'}
            }catch{$blocked}
        }
    }finally{$runtimeLock.Dispose()}
}
function CTValidRecoveryJournal {param([string]$Root,[string]$Path,$Transaction)
    try{
        $id=[string](CTField $Transaction Id '')
        return ($Transaction.SchemaVersion -eq 1 -and $id -cmatch '^[a-f0-9]{32}$' -and (CTPath $Transaction.Root) -ieq $Root -and (CTPath $Transaction.JournalPath) -ieq (CTPath $Path) -and (CTPath $Path) -ieq (Join-Path $Root ('connection-transactions\'+$id+'.json')) -and ((CTField $Transaction RequestId '') -eq '' -or (CTField $Transaction RequestId '') -cmatch '^[a-f0-9]{32}$'))
    }catch{return $false}
}
function Get-TCConnectionResolutionProof {param([string]$Root,$Transaction,$Actual)
    $proof=[pscustomobject]@{SchemaVersion=1;Kind='TradeChannel.ConnectionResolution';TransactionId=$Transaction.Id;RequestId=(CTField $Transaction RequestId '');Decision='Blocked';ReasonCode='RecoveryEvidenceIncomplete';ObservedAtUtc=(CTNow).ToString('o');NetworkOperationRequested=$false;OriginalConfigurationIntact=$false;ExecutorEnded=$false;CurrentState=(CTField $Actual State 'Unknown');PreferenceDisposition='PreservedCurrent';OriginalPhase=$Transaction.Phase}
    try{
        $executor=CTField $Transaction Executor
        if($executor -and -not (CTReceiptWorkerEnded $executor)){$proof.ReasonCode='OriginalWorkerStillActive';return $proof}
        $requestId=[string](CTField $Transaction RequestId '')
        if($requestId){
            $receipt=CTRead (Join-Path $Root ('Product\jobs\'+$requestId+'.receipt.json'))
            if($receipt){
                if($receipt.RequestId -cne $requestId -or $receipt.Action -notin @('Session','ConnectionSwitchCommit') -or -not (CTReceiptWorkerEnded $receipt)){$proof.ReasonCode='OriginalWorkerUnresolved';return $proof}
            }elseif(-not $executor){$proof.ReasonCode='LegacyWorkerEvidenceMissing';return $proof}
        }
        $proof.ExecutorEnded=$true
        CTAssertKnown $Actual
        if($Actual.State -ne 'Stopped'){$proof.ReasonCode='SessionNotStopped';return $proof}
        CTAssertProbeCleanup $Root
        foreach($file in @(Get-ChildItem -LiteralPath (Join-Path $Root 'proxy-recovery') -Filter '*.json' -ErrorAction SilentlyContinue)){
            $entry=CTRead $file.FullName
            if($entry.SchemaVersion -ne 1 -or $entry.Stage -notin @('Restored','Unchanged','UserRestored','UserKeptCurrent')){$proof.ReasonCode='ProxyRecoveryPending';return $proof}
        }
        $original=$Transaction.Original
        $expected=@{Deployment=(Join-Path $Root 'deployment.json');Index=(Join-Path $Root 'Product\index.json');PreferenceFile=(Join-Path $Root 'ui-preferences.json')}
        foreach($key in @('Deployment','Index','PreferenceFile')){
            $snapshot=CTField $original $key
            if(-not $snapshot -or (CTPath $snapshot.Path) -ine $expected[$key]){$proof.ReasonCode='SnapshotPathMismatch';return $proof}
        }
        foreach($snapshot in @($original.Deployment,$original.Index,$original.Manifest)){
            if(-not $snapshot){if($original.Deployment.Exists){$proof.ReasonCode='OriginalManifestMissing';return $proof};continue}
            $path=CTPath $snapshot.Path
            if(-not $path.StartsWith($Root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){$proof.ReasonCode='SnapshotOutsideRoot';return $proof}
            if($snapshot.Exists){if(-not $snapshot.SHA256 -or (CTHash $path) -cne $snapshot.SHA256){$proof.ReasonCode='OriginalConfigurationChanged';return $proof}}
            elseif([IO.File]::Exists($path)){$proof.ReasonCode='OriginalConfigurationChanged';return $proof}
        }
        if($original.Deployment.Exists){
            $deployment=CTRead $original.Deployment.Path
            if(-not $original.Manifest -or (CTPath $deployment.ManifestPath) -ine (CTPath $original.Manifest.Path)){$proof.ReasonCode='OriginalManifestMismatch';return $proof}
            $verified=CTManifest $Root $original.Manifest.Path $original.Observed.CandidateSHA256
            $originalId=[string](CTField $verified.Manifest TCLineId (CTField $verified.Manifest node_id))
            if($originalId){$null=CTServerBinding $Root ([pscustomobject]@{LineId=$originalId;AliasIds=@();SourceNodeId=$originalId}) $verified.Manifest}
        }
        if($Transaction.LineId -and (-not [IO.Directory]::Exists((Join-Path $Root ('Product\lines\'+$Transaction.LineId))) -or [string]$Transaction.LineId -cnotmatch '^[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}$')){$proof.ReasonCode='OriginalLineMissing';return $proof}
        # Read current preferences for validity, but never overwrite a later
        # legitimate user change with this transaction's old preference bytes.
        $null=CTRead $original.PreferenceFile.Path
        $proof.OriginalConfigurationIntact=$true
        $prepared=($Transaction.Phase -eq 'Prepared' -or ($Transaction.Phase -eq 'NeedsRecovery' -and (CTField (CTField $Transaction Reconciliation) PreviousPhase '') -eq 'Prepared'))
        if($prepared -and -not $Transaction.CandidateAttempted -and -not (CTField $Transaction StopAttempted $false) -and -not $Transaction.OriginalStopped -and -not $Transaction.CandidateIdentity -and -not [IO.File]::Exists((Join-Path $Root ('connection-transactions\'+$Transaction.Id+'-approved.manifest')))){
            $proof.Decision='AbortUnstarted';$proof.ReasonCode='NoSideEffectsVerified'
        }else{$proof.Decision='ResolveStopped';$proof.ReasonCode='StoppedAndOriginalConfigurationVerified'}
    }catch{
        $code='RecoveryEvidenceIncomplete';if($_.Exception.Message -match '^\[TC:([A-Za-z][A-Za-z0-9_]+)\]'){$code=$matches[1]};$proof.ReasonCode=$code
    }
    return $proof
}
function Reconcile-TCConnectionTransactions {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,[switch]$ResolveStopped,[string[]]$RequestIds=@())
    # Reads actual evidence; never Stop/Start/Apply/Verify or replay a phase.
    $locks=$null;$runtimeLock=$null
    try{
        $Root=CTPath $Root;$null=CTRuntime 'ReadBoundary' $Root $null;$locks=CTLocks $Root -ReconcileLines
        $dir=Join-Path $Root 'connection-transactions';if(-not [IO.Directory]::Exists($dir)){if($ResolveStopped){CTReconcileStoppedSessionReceipts $Root $RequestIds};return}
        foreach($file in @(Get-ChildItem -LiteralPath $dir -Filter '*.json')){
            $tx=CTRead $file.FullName
            if(-not (CTValidRecoveryJournal $Root $file.FullName $tx)){
                [pscustomobject]@{RequestId='';Status='NeedsRecovery';Phase='NeedsRecovery';Code='RecoveryJournalInvalid';Message='原事务归属或路径无法核实，保留原记录。';Activated=$false;ConnectionRestored=$false};continue
            }
            if($RequestIds.Count -gt 0 -and (CTField $tx RequestId '') -cnotin $RequestIds){continue}
            if(CTTerminal $tx){
                if((CTField $tx RequestId '') -cmatch '^[a-f0-9]{32}$' -and (CTField $tx RequestId '') -cin $RequestIds){CTResult $tx $null}
                continue
            }
            try{
                $runtimeLock=CTOpenLock (Join-Path $Root '.runtime-command.lock')
                $actual=CTRuntime 'Observe' $Root $null
                $proof=Get-TCConnectionResolutionProof $Root $tx $actual
                $priorPhase=$tx.Phase
                if($priorPhase -eq 'NeedsRecovery' -and $tx.Reconciliation){$priorPhase=[string](CTField $tx.Reconciliation PreviousPhase $priorPhase)}
                $tx.Reconciliation=[pscustomobject]@{At=(CTNow).ToString('o');Observed=$actual;Deployment=(CTRead (Join-Path $Root 'deployment.json'));IndexSHA256=(CTHash (Join-Path $Root 'Product\index.json'));PreferencesSHA256=(CTHash (Join-Path $Root 'ui-preferences.json'));PreviousPhase=$priorPhase;Replayed=$false}
                $tx|Add-Member NoteProperty RecoveryProof $proof -Force
                if($ResolveStopped -and $proof.Decision -in @('AbortUnstarted','ResolveStopped')){
                    $tx.ConnectionRestored=$false
                    $status=if($proof.Decision -eq 'AbortUnstarted'){'Aborted'}else{'ResolvedStopped'}
                    CTPhase $tx $status $status;CTResult $tx $actual;continue
                }
                CTPhase $tx 'NeedsRecovery' 'NeedsRecovery';CTResult $tx $actual
            }finally{if($runtimeLock){$runtimeLock.Dispose();$runtimeLock=$null}}
        }
        if($ResolveStopped){CTReconcileStoppedSessionReceipts $Root $RequestIds}
    }finally{if($runtimeLock){$runtimeLock.Dispose()};CTCloseLocks $locks}
}
function Get-TCConnectionTransactionProgress {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][string]$RequestId)
    if($RequestId -cnotmatch '^[a-f0-9]{32}$'){return}
    $dir=CTPath (Join-Path $Root 'connection-transactions');if(-not [IO.Directory]::Exists($dir)){return}
    $labels=@{Prepared='核对已选线路资料';StopOriginal='停止原连接';OriginalStopped='核对目标配置';CommitTarget='应用目标配置';StartTarget='启动目标协议';ApplyOriginalIntent='应用流量设置';VerifyTarget='核对出口、DNS 与 HTTPS';Completed='连接检查通过';StopOwnedCandidate='停止本次目标连接';RestoreOriginalReferences='还原原线路资料';RestoreOriginalIntent='还原流量设置';OriginalConfigurationRestored='原配置已还原';RestartOriginal='重新连接原线路';ReapplyOriginalIntent='恢复原流量设置';VerifyOriginal='核对原线路恢复结果';RolledBack='已恢复原连接状态';Aborted='连接未开始';NeedsRecovery='连接结果需要核对';ResolvedStopped='已核对停止状态'}
    foreach($file in @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File|Sort-Object LastWriteTimeUtc -Descending)){
        if($file.BaseName -cnotmatch '^[a-f0-9]{32}$' -or $file.Length -gt 4194304){continue}
        try{$tx=CTRead $file.FullName;if((CTField $tx RequestId '') -cne $RequestId -or $tx.Id -cne $file.BaseName -or (CTPath $tx.Root) -ine (CTPath $Root) -or (CTPath $tx.JournalPath) -ine $file.FullName){continue}
            return [pscustomobject]@{RequestId=$RequestId;TransactionId=$tx.Id;LineId=$tx.LineId;ProfileId=$tx.ProfileId;Phase=$tx.Phase;Status=$tx.Status;Label=$(if($labels.ContainsKey($tx.Phase)){$labels[$tx.Phase]}else{'核对连接状态'});Progress=(CTField $tx Progress);Terminal=(CTTerminal $tx)}
        }catch{}
    }
}
Export-ModuleMember -Function Get-TCConnectionSwitchPreview,Get-TCDefaultConnectionSwitchPreview,Invoke-TCConnectionSwitch,Invoke-TCDefaultConnectionSwitch,Reconcile-TCConnectionTransactions,Get-TCConnectionTransactionProgress
