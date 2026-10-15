#requires -Version 5.1
$ErrorActionPreference='Stop'
# The only execution seam is module-private. Tests install it temporarily with
# & $module { $script:TestAdapter=... }; no exported entry accepts callbacks.
$script:TestAdapter=$null

function CTField { param($Value,[string]$Name,$Default=$null)
    if($null -ne $Value -and $Value.PSObject.Properties[$Name]){return $Value.$Name};return $Default
}
function CTPath { param([string]$Path)
    $full=[IO.Path]::GetFullPath($Path);$cursor=$full
    while($cursor){if(Test-Path -LiteralPath $cursor){$item=Get-Item -LiteralPath $cursor -Force;if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw '事务路径不能经过重解析点。'}};$parent=[IO.Path]::GetDirectoryName($cursor);if($parent -eq $cursor){break};$cursor=$parent}
    return $full
}
function CTRead {param([string]$Path) if([IO.File]::Exists($Path)){[IO.File]::ReadAllText((CTPath $Path))|ConvertFrom-Json}}
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
function CTDefaultSelection {param([string]$Root,[string]$LineId)
    $pair=CTLine $Root $LineId $null;$line=$pair.Line
    if(-not $line){throw '[TC:RecommendationCheckRequired] 线路资料不可用，请先检查线路。'}
    $lineDigest=CTDigest $line
    $recommendation=CTField $line Recommendation
    $context=$null;$choice=$null
    if($recommendation){$context=CTNetworkContext $Root}
    if($script:TestAdapter){$choice=CTRuntime 'DefaultProfile' $Root ([pscustomobject]@{Id=$LineId;NetworkContext=$context})}
    else{
        $resolver=Get-Command Get-TCLineDefaultProfile -ErrorAction SilentlyContinue
        if($resolver){$choice=Get-TCLineDefaultProfile -Root $Root -Id $LineId -NetworkContext $context}
    }
    if(-not $choice){
        if($recommendation){throw '[TC:RecommendationCheckRequired] 默认方式需要重新检查，未自动选择 UDP。'}
        $choice=[pscustomobject]@{ProfileId=(CTField $line PreferredProfileId);Source='LegacyPreference';RequiresCheck=$false;Reason='兼容旧线路已保存方式';Recommendation=$null}
    }
    $choiceLine=CTField $choice Line
    if(($choiceLine -and (CTDigest $choiceLine) -cne $lineDigest) -or (CTDigest (CTField $choice Recommendation)) -cne (CTDigest $recommendation)){throw '[TC:RecommendationCheckRequired] 读取期间默认来源或线路 revision 已变化，请重新预览。'}
    $profileId=[string](CTField $choice ProfileId)
    if(-not $profileId -and (CTField $choice Source) -eq 'LegacyManifest' -and [int](CTField $line Revision 0) -eq 0){return [pscustomobject]@{LineId=$line.LineId;ProfileId=$null;Source='LegacyManifest';CandidateSHA256=$null;Recommendation=$null;NetworkFingerprint=$null}}
    if((CTField $choice RequiresCheck $false) -or $profileId -notin @('Udp','Tcp')){throw ('[TC:RecommendationCheckRequired] '+[string](CTField $choice Reason '没有有效默认方式，请先检查线路或明确选择连接方式。'))}
    $pair=CTLine $Root $line.LineId $profileId;$profile=$pair.Profile
    if(-not $profile -or $profile.Id -ne $profileId){throw '[TC:RecommendationCheckRequired] 推荐指向的配置不可用，请重新检查。'}
    if((CTDigest $pair.Line) -cne $lineDigest){throw '[TC:RecommendationCheckRequired] 读取期间配置 revision 已变化，请重新预览。'}
    $selected=@($line.Profiles|Where-Object Id -eq $profileId)
    if($selected.Count -ne 1 -or $selected[0].CandidateSHA256 -cne $profile.CandidateSHA256 -or -not [string]::Equals([string]$selected[0].ManifestPath,[string]$profile.ManifestPath,[StringComparison]::OrdinalIgnoreCase)){throw '[TC:RecommendationCheckRequired] 默认方式与实际 profile 配置不一致，请重新预览。'}
    $source=[string](CTField $choice Source 'None')
    if($source -in @('Reachability','PolicyDefault') -and -not $recommendation){throw '[TC:RecommendationCheckRequired] 自动选择缺少相同配置的推荐证据。'}
    if($recommendation -and $source -ne 'UserChoice'){
        if($context -and $context.Status -ne 'Available'){throw '[TC:RecommendationCheckRequired] 当前网络快照不可用，请重新检查。'}
        $checked=[DateTimeOffset]::MinValue;$expires=[DateTimeOffset]::MinValue;$now=[DateTimeOffset]::UtcNow
        $valid=[bool]($recommendation.SchemaVersion -eq 1 -and $recommendation.Status -eq 'Recommended' -and $source -in @('Reachability','PolicyDefault') -and $recommendation.Source -eq $source -and $recommendation.RecommendedProfileId -eq $profileId -and $recommendation.CandidateSHA256 -ceq $profile.CandidateSHA256 -and $recommendation.NetworkFingerprint -match '^[A-Fa-f0-9]{64}$')
        $valid=$valid -and [DateTimeOffset]::TryParse([string]$recommendation.CheckedAtUtc,[ref]$checked) -and [DateTimeOffset]::TryParse([string]$recommendation.ExpiresAtUtc,[ref]$expires)
        if(-not $valid -or $checked -gt $now -or $expires -le $now -or $expires -le $checked){throw '[TC:RecommendationCheckRequired] 推荐已过期，或网络环境、配置已变化，请重新检查线路。'}
        Import-Module (Join-Path $PSScriptRoot 'ProtocolSelection.psm1') -DisableNameChecking
        if(-not (Test-TCProtocolRecommendationCurrent -Recommendation $recommendation -Profiles @($line.Profiles) -NetworkContext $context -Now $now)){throw '[TC:RecommendationCheckRequired] 推荐证据不再有效，请重新检查线路。'}
    }
    if($recommendation -and $source -eq 'UserChoice' -and (CTField $line PreferenceSource) -ne 'UserChoice' -and $recommendation.Status -ne 'UserChoice'){throw '[TC:RecommendationCheckRequired] 缺少明确的用户选择。'}
    # ProtocolSelection revalidates each evidence binding. Its recommendation
    # fingerprint may aggregate multiple underlays and is not the global TUN
    # snapshot. Neither snapshot changes nor polling timestamps enter this token.
    [pscustomobject]@{LineId=$line.LineId;LineRevision=$line.Revision;ProfileId=$profileId;Source=$source;CandidateSHA256=$profile.CandidateSHA256;ProfileManifestPath=$profile.ManifestPath;ProfileManifestSHA256=(CTField $profile ManifestSHA256);Recommendation=$recommendation;NetworkFingerprint=$(if($recommendation -and $source -ne 'UserChoice'){$recommendation.NetworkFingerprint}else{$null})}
}
function CTOpenLock {param([string]$Path)
    try{[IO.File]::Open((CTPath $Path),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}catch{throw ('连接或资料操作正在进行，请稍后重新预览。锁：'+[IO.Path]::GetFileName($Path))}
}
function CTLocks {param([string]$Root,[bool]$SessionLockHeld=$false,[string]$LineId)
    $locks=New-Object 'Collections.Generic.List[object]'
    try{
        if(-not $SessionLockHeld){$locks.Add((CTOpenLock (Join-Path $Root '.session.lock')))}
        $store=Join-Path $Root 'Product'
        if([IO.Directory]::Exists($store)){$locks.Add((CTOpenLock (Join-Path $store '.store.lock')))}
        if($LineId){
            $lineRoot=Join-Path (Join-Path $store 'lines') $LineId
            if(-not [IO.Directory]::Exists($lineRoot)){throw '请先登记不可变线路 profile，再切换连接方式。'}
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
function CTTerminal {param($Transaction) $Transaction.Status -in @('Completed','RolledBack','ResolvedStopped')}
function CTPending {param([string]$Root)
    $dir=Join-Path $Root 'connection-transactions'
    if([IO.Directory]::Exists($dir)){foreach($file in @(Get-ChildItem -LiteralPath $dir -Filter '*.json')){$tx=CTRead $file.FullName;if(-not (CTTerminal $tx)){return $tx}}}
}
function CTBaseline {param([string]$Root,[string]$LineId,[string]$ProfileId,[string]$ManifestPath,$Intent,[bool]$DefaultSelection=$false)
    # Trading-app and isolation checks precede all candidate checks/mutations.
    $null=CTRuntime 'Preflight' $Root $null
    if(CTPending $Root){throw '[TC:NeedsRecovery] 存在尚未结束的连接事务，请先核对实际状态。'}
    $observed=CTRuntime 'Observe' $Root $null;CTAssertKnown $observed
    $default=$null
    if($DefaultSelection){
        $default=CTDefaultSelection $Root $LineId
        if($ProfileId -and $ProfileId -ne $default.ProfileId){throw '[TC:RecommendationCheckRequired] 默认连接方式已变化，请重新预览。'}
        $LineId=$default.LineId;$ProfileId=$default.ProfileId
    }
    $line=$null;$profile=$null
    if($ManifestPath){$target=CTManifest $Root $ManifestPath $null}
    else{
        $pair=CTLine $Root $LineId $ProfileId;$line=$pair.Line;$profile=$pair.Profile
        if(-not $line -or -not $profile -or $profile.Id -ne $ProfileId -or $profile.PreparationState -notin @('Ready','SyntaxValidated','Prepared')){throw '所选连接方式尚未准备完成。'}
        if([int]$line.Revision -lt 1 -or -not [IO.Directory]::Exists((Join-Path $Root ('Product\lines\'+$line.LineId)))){throw '请先登记不可变线路 profile，再预览切换。'}
        $LineId=[string]$line.LineId;$target=CTManifest $Root $profile.ManifestPath $profile.CandidateSHA256
        if($default -and ($default.LineRevision -ne $line.Revision -or $default.CandidateSHA256 -cne $target.CandidateSHA256 -or -not [string]::Equals([string]$default.ProfileManifestPath,[string]$target.ManifestPath,[StringComparison]::OrdinalIgnoreCase) -or ($default.ProfileManifestSHA256 -and $default.ProfileManifestSHA256 -cne $target.ManifestSHA256))){throw '[TC:RecommendationCheckRequired] 默认预览与目标 revision、manifest 或配置哈希不一致，请重新预览。'}
    }
    $prefs=CTRuntime 'Preferences' $Root $null
    $desired=$prefs|ConvertTo-Json -Depth 20|ConvertFrom-Json
    if($Intent){foreach($property in $Intent.PSObject.Properties){$desired|Add-Member NoteProperty $property.Name $property.Value -Force}}
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
    $baseline=[pscustomobject]@{Root=(CTPath $Root);LineId=$LineId;ProfileId=$ProfileId;LineRevision=(CTField $line Revision);SourceNodeId=(CTField $line SourceNodeId);AliasIds=@(CTField $line AliasIds @());Target=$target;Original=[pscustomobject]@{WasRunning=($observed.State -eq 'Running');Observed=$observed;Identity=(CTIdentity $observed);Manifest=$originalManifest;Deployment=$deployment;Index=$index;PreferenceFile=$preferenceFile;Preferences=$prefs;References=$refs};Intent=$desired}
    $baseline|Add-Member NoteProperty Digest (CTDigest ([ordered]@{Root=$baseline.Root;LineId=$LineId;ProfileId=$ProfileId;LineRevision=$baseline.LineRevision;SourceNodeId=$baseline.SourceNodeId;AliasIds=$baseline.AliasIds;TargetManifestHash=$target.ManifestSHA256;TargetHash=$target.CandidateSHA256;ExitEvidence=$target.ExitEvidence;OriginalIdentity=$baseline.Original.Identity;OriginalState=$observed.State;OriginalManifestHash=$(if($originalManifest){$originalManifest.SHA256}else{$null});DeploymentHash=$deployment.SHA256;IndexHash=$index.SHA256;PreferenceHash=$preferenceFile.SHA256;Preferences=$prefs;Intent=$desired;ActualMode=(CTField $observed Mode);ActualExit=(CTField $observed Exit);ActualDaily=(CTField $observed Daily);Guard=(CTField $observed Guard)}))
    $baseline|Add-Member NoteProperty DefaultSelection $default
    if($DefaultSelection){$baseline.Digest=CTDigest ([ordered]@{Baseline=$baseline.Digest;Default=$default})}
    return $baseline
}
function CTPreview {param([string]$Root,[string]$LineId,[string]$ProfileId,[string]$ManifestPath,$Intent,[bool]$DefaultSelection=$false)
    $baseline=CTBaseline $Root $LineId $ProfileId $ManifestPath $Intent $DefaultSelection
    $expiry=[DateTimeOffset]::UtcNow.AddMinutes(10).ToUnixTimeSeconds()
    [pscustomobject]@{LineId=$baseline.LineId;ProfileId=$baseline.ProfileId;PreviewToken=($(if($DefaultSelection){'ct2:'}else{'ct1:'})+ $expiry+':'+$baseline.Digest);CanSwitch=$true;Message=$(if($baseline.SourceNodeId){'将停止当前会话，目标交易出口使用该自建线路（HongKong/hk），再验证所选连接方式；日常和 AI 意图保留，失败时恢复原出口。请保持 NinjaTrader 退出。'}else{'将停止当前会话后切换并验证；失败时按原运行状态恢复。请保持 NinjaTrader 退出。'});TargetExit=$baseline.Intent.Exit;ExitEvidence=$baseline.Target.ExitEvidence;TargetHash=$baseline.Target.CandidateSHA256;Observed=$baseline.Original.Observed;Baseline=$baseline;Recommendation=(CTField $baseline.DefaultSelection Recommendation);DefaultSource=(CTField $baseline.DefaultSelection Source)}
}
function Get-TCDefaultConnectionSwitchPreview {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][string]$LineId)
    try{$preview=CTPreview (CTPath $Root) $LineId $null $null $null $true;$preview.PSObject.Properties.Remove('Baseline');return $preview}
    catch{[pscustomobject]@{LineId=$LineId;ProfileId=$null;PreviewToken=$null;CanSwitch=$false;Message=$_.Exception.Message;Status=$(if($_.Exception.Message -match 'NeedsRecovery'){'NeedsRecovery'}else{'Blocked'});Recommendation=$null;DefaultSource='None';Observed=$null}}
}
function Get-TCConnectionSwitchPreview {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][string]$LineId,[Parameter(Mandatory=$true)][ValidateSet('Udp','Tcp')][string]$ProfileId)
    try{$preview=CTPreview (CTPath $Root) $LineId $ProfileId $null $null;$preview.PSObject.Properties.Remove('Baseline');return $preview}
    catch{[pscustomobject]@{LineId=$LineId;ProfileId=$ProfileId;PreviewToken=$null;CanSwitch=$false;Message=$_.Exception.Message;Status=$(if($_.Exception.Message -match 'NeedsRecovery'){'NeedsRecovery'}else{'Blocked'});Observed=$null}}
}
function CTPhase {param($Transaction,[string]$Phase,[string]$Status='InProgress')
    $Transaction.Phase=$Phase;$Transaction.Status=$Status;$Transaction.UpdatedAt=[DateTimeOffset]::UtcNow.ToString('o')
    $Transaction.History=@($Transaction.History)+@([pscustomobject]@{Phase=$Phase;Status=$Status;At=$Transaction.UpdatedAt})
    CTWrite $Transaction.JournalPath $Transaction
}
function CTResult {param($Transaction,$Observed)
    $message=switch($Transaction.Status){
        'Completed'{'已切换连接方式，实际出口验证通过。'}
        'RolledBack'{if($Transaction.Original.WasRunning){'切换失败，已恢复原配置并重连原会话，实际出口复测通过。'}else{'切换失败，已恢复原配置，保持未连接。'}}
        'ResolvedStopped'{'已核对原配置和实际停止状态，故障任务已结束。当前保持未连接；可重新选择线路并点击连接。未自动重连，也未宣称原连接或交易业务已恢复。'}
        default{'[TC:NeedsRecovery] 连接事务需要恢复；请核对实际会话。配置还原不代表原连接已恢复，不会自动启动第二个引擎。'}
    }
    if($Transaction.Status -eq 'Completed' -and $Transaction.ProfileId -and -not (CTField $Transaction.TargetCheck ServerAttributionVerified $false)){$message='所选自建线路连接方式的 HTTPS/DNS 转发已通过；出口归属仅为 ConfiguredEndpoint 推定，未权威验证。'}
    [pscustomobject]@{TransactionId=$Transaction.Id;LineId=$Transaction.LineId;ProfileId=$Transaction.ProfileId;Status=$Transaction.Status;Phase=$Transaction.Phase;Message=$message;Observed=$Observed;Activated=($Transaction.Status -eq 'Completed');Check=$Transaction.TargetCheck;ConfigurationRestored=[bool]$Transaction.ConfigurationRestored;ConnectionRestored=[bool]$Transaction.ConnectionRestored;RecoveryCheck=$Transaction.RecoveryCheck;JournalPath=$Transaction.JournalPath;PreviousDeploymentBackup=$Transaction.JournalPath;Error=$Transaction.Error}
}
function CTStopOwned {param([string]$Root,$Owned,[string]$Operation)
    $actual=CTRuntime 'Observe' $Root $null;CTAssertKnown $actual
    if($actual.State -eq 'Stopped'){return $actual}
    if((CTDigest (CTIdentity $actual)) -cne (CTDigest (CTIdentity $Owned))){throw '[TC:NeedsRecovery] 会话身份已变化，未停止不属于本事务的进程。'}
    $null=CTRuntime $Operation $Root $Owned
    return CTAssertStopped $Root
}
function CTVerify {param([string]$Root,$Transaction,[bool]$Original=$false)
    $manifest=if($Original){CTRead $Transaction.Original.Manifest.Path}else{$Transaction.Target.Manifest}
    $intent=if($Original){$Transaction.Original.Preferences}else{$Transaction.Intent}
    $expected=if($Original){$Transaction.Original.Observed}else{$null}
    $profile=if(-not $Original -and $Transaction.SourceNodeId){$Transaction.ProfileId}else{$null}
    $result=CTRuntime 'Verify' $Root ([pscustomobject]@{Manifest=$manifest;Intent=$intent;Expected=$expected;Original=$Original;ProfileId=$profile;LineId=$Transaction.LineId})
    if($Original){$Transaction.RecoveryCheck=$result}else{$Transaction.TargetCheck=$result}
    if(-not $result.ExitHttp -or -not $result.ObservedIP -or -not $result.DnsHttps -or -not $result.ExitVerified){throw ('[TC:LineForwardingUnverified] 实际 TLS/HTTPS、DNS 或所选出口证据未通过核验。'+[string](CTField $result Code ''))}
    if($profile -and ($intent.Exit -ne 'HongKong' -or $result.ActualExit -ne 'hk' -or -not (CTField $result ProfileValidated $false))){throw '[TC:ProfileExitUnverified] 所选连接方式必须经已核验的自建 hk 出口验证，服务商证据不能代替。'}
    return $result
}
function CTExecute {param([string]$Root,[string]$LineId,[string]$ProfileId,[string]$PreviewToken,[string]$ManifestPath,$Intent,[bool]$SessionLockHeld=$false)
    $locks=$null;$tx=$null
    try{
        $Root=CTPath $Root
        # Guard before acquiring/creating lock or journal files.
        $null=CTRuntime 'Preflight' $Root $null
        # Resolve aliases read-only, then acquire the canonical line lock in
        # exactly the same order as LineStore's preparation writer.
        $canonical=$LineId
        if($LineId){$canonical=[string](CTLine $Root $LineId $ProfileId).Line.LineId}
        $locks=CTLocks $Root $SessionLockHeld $canonical
        $useDefault=[bool]($PreviewToken -clike 'ct2:*')
        $baseline=CTBaseline $Root $LineId $ProfileId $ManifestPath $Intent $useDefault
        $ProfileId=$baseline.ProfileId
        if(-not $PreviewToken -or $PreviewToken -cnotmatch '^ct[12]:(\d+):([A-F0-9]{64})$'){throw '缺少有效切换预览，请重新预览并确认。'}
        $expiry=[long]$matches[1];$digest=$matches[2]
        if($expiry -lt [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() -or $expiry -gt [DateTimeOffset]::UtcNow.AddMinutes(11).ToUnixTimeSeconds() -or $digest -cne $baseline.Digest){throw '切换目标、原会话或偏好已变化，预览已失效，请重新预览。'}
        $journalRoot=Join-Path $Root 'connection-transactions';$null=[IO.Directory]::CreateDirectory($journalRoot)
        foreach($file in @(Get-ChildItem -LiteralPath $journalRoot -Filter '*.json')){if((CTRead $file.FullName).Approval.PreviewToken -ceq $PreviewToken){throw '此预览已执行，请重新预览，不能重放事务。'}}
        $id=[guid]::NewGuid().ToString('N')
        $tx=[pscustomobject]@{SchemaVersion=1;Id=$id;Root=$Root;JournalPath=(Join-Path $journalRoot ($id+'.json'));LineId=$baseline.LineId;ProfileId=$ProfileId;SourceNodeId=$baseline.SourceNodeId;Original=$baseline.Original;Target=$baseline.Target;TargetHash=$baseline.Target.CandidateSHA256;ActiveManifestPath=(Join-Path $journalRoot ($id+'-approved.manifest'));ActiveManifestSHA256=$null;Intent=$baseline.Intent;Approval=[pscustomobject]@{PreviewToken=$PreviewToken;Digest=$digest;ExpiresAt=$expiry;Summary='明确批准一次停止、切换、验证及按原状态恢复';ApprovedAt=[DateTimeOffset]::UtcNow.ToString('o')};Status='InProgress';Phase='Prepared';UpdatedAt=$null;History=@();CandidateIdentity=$null;CandidateAttempted=$false;CandidateAttemptedAt=$null;OriginalStopped=$false;ConfigurationRestored=$false;ConnectionRestored=$false;TargetCheck=$null;RecoveryCheck=$null;Error=$null;RecoveryError=$null;Reconciliation=$null}
        $tx|Add-Member NoteProperty DefaultSelection $baseline.DefaultSelection
        CTPhase $tx 'Prepared'
        try{
            if($tx.Original.WasRunning){
                CTPhase $tx 'StopOriginal'
                $null=CTStopOwned $Root $tx.Original.Observed 'StopOriginal'
            }else{$null=CTAssertStopped $Root}
            $tx.OriginalStopped=$true;CTPhase $tx 'OriginalStopped'
            # Revalidate after stop and before pointer commit. Candidate files
            # are never transformed or checked by starting an identity probe.
            $check=CTManifest $Root $tx.Target.ManifestPath $tx.TargetHash
            if($check.ManifestSHA256 -cne $tx.Target.ManifestSHA256){throw '停止期间目标 manifest 已变化。'}
            if($useDefault -and (CTDigest (CTDefaultSelection $Root $baseline.LineId)) -cne (CTDigest $baseline.DefaultSelection)){throw '[TC:RecommendationCheckRequired] 停止期间推荐或网络环境已变化，恢复原连接。'}
            CTPhase $tx 'CommitTarget'
            if($tx.SourceNodeId){$idx=CTRead $tx.Original.Index.Path;$source=@($idx.nodes|Where-Object id -eq $tx.SourceNodeId);if($source.Count -ne 1){throw '来源节点在提交前已变化。'};$source[0].manifestPath=$tx.Target.ManifestPath;CTWrite $tx.Original.Index.Path $idx}
            # The supervisor requires DeploymentApproved. Give it an approved
            # runtime manifest; the registered profile remains immutable.
            $approved=$tx.Target.Manifest|ConvertTo-Json -Depth 40|ConvertFrom-Json
            $approved|Add-Member NoteProperty DeploymentApproved $true -Force
            $approved|Add-Member NoteProperty TCTransactionId $tx.Id -Force
            $approved|Add-Member NoteProperty TCProfileManifestPath $tx.Target.ManifestPath -Force
            CTWrite $tx.ActiveManifestPath $approved;$tx.ActiveManifestSHA256=CTHash $tx.ActiveManifestPath
            CTWrite $tx.Original.Deployment.Path ([ordered]@{ManifestPath=$tx.ActiveManifestPath;ProfileManifestPath=$tx.Target.ManifestPath;LineId=$tx.LineId;ProfileId=$tx.ProfileId;TransactionId=$tx.Id;CandidateSHA256=$tx.TargetHash;SelectedAt=[DateTimeOffset]::UtcNow.ToString('o');Stage='ConnectionTransaction';StartupMode=$tx.Intent.Mode;BootAutoStartEnabled=$false})
            CTWrite $tx.Original.PreferenceFile.Path $tx.Intent
            $null=CTAssertStopped $Root
            $tx.CandidateAttempted=$true;$tx.CandidateAttemptedAt=[DateTimeOffset]::UtcNow.ToString('o');CTPhase $tx 'StartTarget'
            $null=CTRuntime 'Start' $Root ([pscustomobject]@{ManifestPath=$tx.ActiveManifestPath;TransactionId=$tx.Id})
            $actual=CTRuntime 'Observe' $Root $null;CTAssertKnown $actual
            if($actual.State -ne 'Running' -or $actual.ManifestPath -ine $tx.ActiveManifestPath -or $actual.CandidateSHA256 -cne $tx.TargetHash){throw '候选实际会话与目标配置不一致。'}
            $tx.CandidateIdentity=$actual;CTPhase $tx 'ApplyOriginalIntent'
            $null=CTRuntime 'ApplyIntent' $Root ([pscustomobject]@{Manifest=$tx.Target.Manifest;Intent=$tx.Intent;Expected=$null;ProfileId=$tx.ProfileId;LineId=$tx.LineId})
            CTPhase $tx 'VerifyTarget';$tx.TargetCheck=CTVerify $Root $tx
            $actual=CTRuntime 'Observe' $Root $null;CTAssertKnown $actual
            if((CTDigest (CTIdentity $actual)) -cne (CTDigest (CTIdentity $tx.CandidateIdentity))){throw '验证期间实际会话身份已变化。'}
            CTPhase $tx 'Completed' 'Completed';return CTResult $tx $actual
        }catch{
            $tx.Error=$_.Exception.Message
            if(-not $tx.OriginalStopped){CTPhase $tx 'NeedsRecovery' 'NeedsRecovery';return CTResult $tx (CTRuntime 'Observe' $Root $null)}
            try{
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
                        $null=CTStopOwned $Root $tx.CandidateIdentity 'StopOwnedCandidate'
                    }else{$null=CTAssertStopped $Root}
                }else{$null=CTAssertStopped $Root}
                CTPhase $tx 'RestoreOriginalReferences'
                if($tx.Original.Manifest){CTRestoreFile $tx.Original.Manifest}
                CTRestoreFile $tx.Original.Index;CTRestoreFile $tx.Original.Deployment
                CTPhase $tx 'RestoreOriginalIntent';CTRestoreFile $tx.Original.PreferenceFile
                $tx.ConfigurationRestored=$true;CTPhase $tx 'OriginalConfigurationRestored'
                $null=CTAssertStopped $Root
                if($tx.Original.WasRunning){
                    # Original config hash is checked again before reusing it.
                    $restored=CTManifest $Root $tx.Original.Manifest.Path $tx.Original.Observed.CandidateSHA256
                    CTPhase $tx 'RestartOriginal'
                    $null=CTRuntime 'Start' $Root ([pscustomobject]@{ManifestPath=$restored.ManifestPath;TransactionId=$tx.Id;Restoring=$true})
                    CTPhase $tx 'ReapplyOriginalIntent'
                    $null=CTRuntime 'ApplyIntent' $Root ([pscustomobject]@{Manifest=$restored.Manifest;Intent=$tx.Original.Preferences;Expected=$tx.Original.Observed})
                    CTPhase $tx 'VerifyOriginal';$tx.RecoveryCheck=CTVerify $Root $tx $true
                    $actual=CTRuntime 'Observe' $Root $null;CTAssertKnown $actual
                    if($actual.State -ne 'Running' -or $actual.ManifestPath -ine $restored.ManifestPath -or $actual.CandidateSHA256 -cne $restored.CandidateSHA256){throw '重连后的原会话身份不符合原配置。'}
                    $tx.ConnectionRestored=$true
                }else{$actual=CTAssertStopped $Root;$tx.ConnectionRestored=$true}
                CTPhase $tx 'RolledBack' 'RolledBack';return CTResult $tx $actual
            }catch{
                $tx.RecoveryError=$_.Exception.Message;CTPhase $tx 'NeedsRecovery' 'NeedsRecovery'
                $actual=$null;try{$actual=CTRuntime 'Observe' $Root $null}catch{}
                return CTResult $tx $actual
            }
        }
    }finally{CTCloseLocks $locks}
}
function Invoke-TCConnectionSwitch {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][string]$LineId,[Parameter(Mandatory=$true)][ValidateSet('Udp','Tcp')][string]$ProfileId,[Parameter(Mandatory=$true)][string]$PreviewToken)
    CTExecute $Root $LineId $ProfileId $PreviewToken $null $null
}
function Invoke-CTSessionSwitch {param([string]$Root,[string]$LineId,[string]$ProfileId,[string]$ManifestPath,$Intent,[string]$PreviewToken,[bool]$SessionLockHeld,[bool]$DefaultSelection=$false)
    if(-not $PreviewToken){$preview=CTPreview $Root $LineId $ProfileId $ManifestPath $Intent $DefaultSelection;$PreviewToken=$preview.PreviewToken;$ProfileId=$preview.ProfileId}
    CTExecute $Root $LineId $ProfileId $PreviewToken $ManifestPath $Intent $SessionLockHeld
}
function Reconcile-TCConnectionTransactions {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,[switch]$ResolveStopped)
    # Reads actual evidence; never Stop/Start/Apply/Verify or replay a phase.
    $locks=$null
    try{
        $Root=CTPath $Root;$null=CTRuntime 'ReadBoundary' $Root $null;$locks=CTLocks $Root
        $dir=Join-Path $Root 'connection-transactions';if(-not [IO.Directory]::Exists($dir)){return}
        foreach($file in @(Get-ChildItem -LiteralPath $dir -Filter '*.json')){
            $tx=CTRead $file.FullName;if(CTTerminal $tx){continue}
            $actual=CTRuntime 'Observe' $Root $null
            $tx.Reconciliation=[pscustomobject]@{At=[DateTimeOffset]::UtcNow.ToString('o');Observed=$actual;Deployment=(CTRead (Join-Path $Root 'deployment.json'));IndexSHA256=(CTHash (Join-Path $Root 'Product\index.json'));PreferencesSHA256=(CTHash (Join-Path $Root 'ui-preferences.json'));PreviousPhase=$tx.Phase;Replayed=$false}
            if($ResolveStopped -and $tx.Status -eq 'NeedsRecovery' -and $tx.SchemaVersion -eq 1 -and $tx.Id -cmatch '^[a-f0-9]{32}$' -and (CTPath $tx.Root) -ieq $Root -and (CTPath $tx.JournalPath) -ieq $file.FullName -and $tx.OriginalStopped -and $tx.ConfigurationRestored -and $actual.State -eq 'Stopped' -and $actual.OwnershipKnown){
                $intact=$true
                foreach($snapshot in @($tx.Original.Manifest,$tx.Original.Deployment,$tx.Original.Index)){
                    if(-not $snapshot){$intact=$false;break}
                    $path=CTPath $snapshot.Path
                    if(-not $path.StartsWith($Root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){$intact=$false;break}
                    if($snapshot.Exists){if(-not $snapshot.SHA256 -or (CTHash $path) -cne $snapshot.SHA256){$intact=$false;break}}
                    elseif([IO.File]::Exists($path)){$intact=$false;break}
                }
                if($intact){
                    try{$null=CTManifest $Root $tx.Original.Manifest.Path $tx.Original.Observed.CandidateSHA256}catch{$intact=$false}
                }
                if($intact){
                    # Preserve user choices made while stopped. No reference,
                    # preference, protection or runtime operation is replayed.
                    $tx.ConnectionRestored=$false
                    CTPhase $tx 'ResolvedStopped' 'ResolvedStopped';CTResult $tx $actual;continue
                }
            }
            CTPhase $tx 'NeedsRecovery' 'NeedsRecovery';CTResult $tx $actual
        }
    }finally{CTCloseLocks $locks}
}
Export-ModuleMember -Function Get-TCConnectionSwitchPreview,Get-TCDefaultConnectionSwitchPreview,Invoke-TCConnectionSwitch,Reconcile-TCConnectionTransactions
