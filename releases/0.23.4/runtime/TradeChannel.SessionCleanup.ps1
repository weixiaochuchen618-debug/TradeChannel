# Cleanup resolution for a session that ended without finishing its teardown.
# Split out of RuntimeBridge so the connection gate can call the same, idempotent
# routine the UI uses instead of bypassing the cleanup flag.
function Resolve-TCSessionCleanup {
    [CmdletBinding()]
    param([string]$Root=$script:Root,[switch]$NormalizeOnly)
    $package=Split-Path $PSScriptRoot -Parent
    if($script:IsolatedReadContext){return [pscustomobject]@{Resolved=$false;Reason='IsolatedReadContext';Message='隔离只读上下文不接受清理归位。'}}
    Import-Module (Join-Path $package 'DeploymentStore.psm1') -DisableNameChecking
    . (Join-Path $PSScriptRoot 'TradeChannel.ProxyJournal.ps1')
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    # 1. Ownership: a live or unidentifiable session must never be normalized.
    $evidence=Get-TCSessionEvidence -SkipController
    if(-not $evidence -or -not $evidence.Identity){return [pscustomobject]@{Resolved=$false;Reason='EvidenceUnavailable';Message='无法核实会话归属，未改动任何状态。'}}
    if($evidence.Fault){return [pscustomobject]@{Resolved=$false;Reason='EvidenceFault';Message='部署或进程状态无法核实，未改动任何状态。'}}
    if($evidence.Identity.Untracked){return [pscustomobject]@{Resolved=$false;Reason='UntrackedEngine';Message='存在身份不明的通道进程，未改动任何状态。'}}
    if($evidence.Identity.SessionPresent){return [pscustomobject]@{Resolved=$false;Reason='SessionActive';Message='通道仍在运行，未改动任何状态。'}}
    # 2. Journal ownership: every pending record must belong to an ended owner.
    $pending=@();try{$pending=@(Get-TCProxyRecoveryEntries $Root|Where-Object {$_.Entry.UserSid -ceq $sid})}catch{return [pscustomobject]@{Resolved=$false;Reason='ProxyJournalUnreadable';Message='代理恢复记录无法核验，未改动任何状态。'}}
    $live=@($pending|Where-Object {-not (Test-TCProxyJournalOwnerEnded $_.Entry)})
    if($live.Count){return [pscustomobject]@{Resolved=$false;Reason='ProxyOwnerAlive';Message='原会话仍持有代理设置，未改动任何状态。'}}
    $sessionIds=@($pending|ForEach-Object {[string]$_.Entry.SessionId}|Select-Object -Unique)
    # 3. Replay the journal. Idempotent: AlreadyRestored entries only advance Stage.
    $restored=0;$conflicts=0
    if(-not $NormalizeOnly){
        try{$result=Restore-TCProxyJournal -Root $Root;$restored=[int]$result.Restored;$conflicts=[int]$result.Conflicts}
        catch{return [pscustomobject]@{Resolved=$false;Reason='ProxyRestoreFailed';Message='代理恢复未完成，未改动运行状态。';SessionIds=$sessionIds}}
    }
    # 4. A conflicting record is a user decision, not something to paper over.
    if($conflicts -gt 0 -or @($pending|Where-Object {$_.Entry.Stage -eq 'Conflict'}).Count){
        return [pscustomobject]@{Resolved=$false;Reason='ProxyConflict';NeedsChoice=$true;SessionIds=$sessionIds;Message='代理设置与记录不一致，请选择保留当前设置或恢复原设置。'}
    }
    # 5. Only now normalize the ledger the gates read.
    $path=Join-Path $Root 'runtime.json';$state=$null
    if([IO.File]::Exists($path)){try{$state=[IO.File]::ReadAllText($path)|ConvertFrom-Json}catch{return [pscustomobject]@{Resolved=$false;Reason='RuntimeUnreadable';Message='运行状态文件无法读取，未改动任何状态。'}}}
    $previous=[string]$state.State;$previousSession=[string]$state.SessionId;$changed=$false
    if($state){
        if($previous -notin @('Disconnected','Stopped','StoppedWithError')){return [pscustomobject]@{Resolved=$false;Reason='UnexpectedState';Message=('运行状态为 '+$previous+'，不属于已停止范围，未改动任何状态。')}}
        if([bool]$state.CleanupError -or $previous -ne 'Disconnected' -or $null -ne $state.Error){
            $state.State='Disconnected';$state.Error=$null
            $state|Add-Member -NotePropertyName CleanupError -NotePropertyValue $false -Force
            $state|Add-Member -NotePropertyName CleanupResolvedAt -NotePropertyValue ([DateTimeOffset]::UtcNow.ToString('o')) -Force
            $state|Add-Member -NotePropertyName CleanupResolution -NotePropertyValue $(if($NormalizeOnly){'UserVerifiedStopped'}else{'VerifiedStoppedAfterReplay'}) -Force
            Write-TCSessionJson $path $state;$changed=$true
        }
    }
    # 6. Audit trail. Never carries proxy values.
    try{
        Import-Module (Join-Path $package 'RuntimeObservability.psm1') -DisableNameChecking
        $auditSession=if($previousSession -match '^[A-Za-z0-9_-]{1,80}$'){$previousSession}else{'cleanup-'+[guid]::NewGuid().ToString('N')}
        $null=Add-TCRuntimeEvent -Root $Root -SessionId $auditSession -Type CleanupResolved -Data @{} -DedupKey ('cleanup-'+[guid]::NewGuid().ToString('N'))
    }catch{}
    [pscustomobject]@{Resolved=$true;Changed=$changed;PreviousState=$previous;Restored=$restored;StageAdvanced=@($pending).Count;SessionIds=$sessionIds;Message=$(if($changed){'上次连接的清理已归位，可以重新连接。'}else{'上次连接没有未完成的清理。'})}
}
