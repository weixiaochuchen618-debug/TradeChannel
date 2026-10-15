#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Connect','Disconnect','Trading','Global','Status','Emergency','HongKong','Provider','DailyDirect','DailyProvider','Agents')][string]$Action,
    [switch]$LoadFunctionsOnly
)
# LoadFunctionsOnly is an isolated-test seam. The bridge dot-sources these
# functions so every entry point uses the same identity and presentation rules.
function Assert-TCRuntimeElevation {
    $principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw '请以管理员身份执行连接操作。'}
}
function Start-TCSupervisor {
    param([string]$ManifestPath)
    foreach($folder in @('logs','backup')){$null=[IO.Directory]::CreateDirectory((Join-Path $script:Root $folder))}
    $runner=Join-Path $script:Package 'runtime\Run-TradeChannel.ps1'
    $exe=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',('"'+$runner+'"'),'-ManifestPath',('"'+$ManifestPath+'"'))
    Start-Process -FilePath $exe -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $script:Root 'logs\supervisor.out.log') -RedirectStandardError (Join-Path $script:Root 'logs\supervisor.err.log')
}
function Stop-TCIdentifiedEngine {
    param($Identity,[ValidateRange(1,8000)][int]$WaitMilliseconds=8000)
    $process=Get-Process -Id ([int]$Identity.ProcessId) -ErrorAction Stop
    try{
        $null=$process.Handle
        if(-not (Test-TCSamePath $process.Path $Identity.ExecutablePath) -or [math]::Abs(((ConvertTo-TCUtc $process.StartTime)-(ConvertTo-TCUtc $Identity.CreationDate)).TotalMilliseconds) -ge 1){throw '进程身份已变化，未执行停止。'}
        if(-not $process.HasExited){$process.Kill();if(-not $process.WaitForExit($WaitMilliseconds)){throw '进程尚未退出。'}}
    }finally{$process.Dispose()}
}
function Set-TCRunningSelection {
    param([string]$Action,$Deployment,$Manifest,[int]$TimeoutSeconds=0)
    if($Action -in @('HongKong','Provider')){
        $prefs=Get-TCPreferences;$id=if($prefs.TradeProviderId){$prefs.TradeProviderId}else{$prefs.ProviderId}
        & (Join-Path $script:Package 'runtime\Set-TradeChannelExit.ps1') -Exit $Action -ManifestPath $Deployment.ManifestPath -ProviderId $id -TimeoutSeconds $TimeoutSeconds
    }
    elseif($Action -in @('Trading','Global')){& (Join-Path $script:Package 'runtime\Set-TradeChannelMode.ps1') -Mode $Action -ConfigPath $Manifest.CandidatePath -TimeoutSeconds $TimeoutSeconds}
    elseif($Action -in @('DailyDirect','DailyProvider')){& (Join-Path $script:Package 'runtime\Set-TradeChannelDaily.ps1') -Daily $Action.Substring(5) -ManifestPath $Deployment.ManifestPath -ProviderId (Get-TCPreferences).ProviderId -TimeoutSeconds $TimeoutSeconds}
    elseif($Action -eq 'Agents'){& (Join-Path $script:Package 'runtime\Set-TradeChannelAgents.ps1') -ManifestPath $Deployment.ManifestPath -Root $script:Root -TimeoutSeconds $TimeoutSeconds}
}
function Invoke-TCRuntimeAction {
    param([Parameter(Mandatory=$true)][string]$Action,[ValidateRange(0,3600)][int]$TimeoutSeconds=0)
    $actionClock=[Diagnostics.Stopwatch]::StartNew()
    $remainingAction={
        if($TimeoutSeconds -gt 0){[Math]::Max(0.0,$TimeoutSeconds-$actionClock.Elapsed.TotalSeconds)}else{[double]::PositiveInfinity}
    }
    $checkAction={if((& $remainingAction) -le 0){throw '[TC:ConnectionTimeout] 当前连接阶段超过执行预算，请核对原事务状态。'}}
    if($Action -eq 'Status'){return Get-TCOverview}
    Assert-TCRuntimeElevation
    $lock=Open-TCSessionLock -Name 'runtime-command'
    try{
        & $checkAction
        $stopping=$Action -in @('Emergency','Disconnect')
        $e=Get-TCSessionEvidence -SkipController:$stopping
        $i=$e.Identity;$s=$e.Snapshot;$d=$e.Deployment;$m=$e.Manifest
        $stopPath=Join-Path $script:Root 'stop.request'
        if(-not $i -or $i.Untracked -or ($e.Fault -and -not ($i.SupervisorAlive -or $i.EngineAlive))){throw '无法安全核实会话身份；请检查诊断信息，未启动或停止任何未知进程。'}
        if($stopping){
            # Old supervisors understand the existence of this same marker.
            # Keep it after shutdown: only an explicit Connect may clear it.
            [IO.File]::WriteAllText($stopPath,(Get-Date).ToString('o'))
            if($i.SupervisorAlive){
                $stopClock=[Diagnostics.Stopwatch]::StartNew();$stopBudget=[Math]::Min([double]18,[double](& $remainingAction))
                do{
                    & $checkAction
                    Start-Sleep -Milliseconds 200
                    $e=Get-TCSessionEvidence -SkipController;$i=$e.Identity;$s=$e.Snapshot
                    if(-not $i -or $i.Untracked){throw '停机期间身份核验失败，请检查实际状态；交易保护未解除。'}
                    if(-not $i.SupervisorAlive){break}
                }while($stopClock.Elapsed.TotalSeconds -lt $stopBudget)
                if($i.SupervisorAlive){throw '通道尚未停止，请稍后检查；交易保护仍保留，不会自动重启。'}
            }
            if($i.EngineAlive){
                & $checkAction
                $waitMs=[int][Math]::Max(1.0,[Math]::Min([double]8000,[double]((& $remainingAction)*1000)))
                Stop-TCIdentifiedEngine $i.Engine $waitMs
                # An orphan cannot attest that its owner's proxy cleanup ran.
                $s|Add-Member -NotePropertyName State -NotePropertyValue 'StoppedWithError' -Force
                $s|Add-Member -NotePropertyName CleanupError -NotePropertyValue $true -Force
                $s|Add-Member -NotePropertyName Error -NotePropertyValue '已停止身份核实的孤立引擎；请检查代理恢复状态，交易保护未解除。' -Force
                Write-TCSessionJson (Join-Path $script:Root 'runtime.json') $s
            }
            # Terminal labels alone never prove shutdown. Check processes again.
            $e=Get-TCSessionEvidence -SkipController
            if(-not $e.Identity -or $e.Identity.SessionPresent){throw '仍有通道进程，断开尚未完成；不会自动重启。'}
            # Pre-0.3 supervisors remove the marker in their finally block.
            [IO.File]::WriteAllText($stopPath,(Get-Date).ToString('o'))
            if($e.Identity.Current -and $e.Snapshot.State -eq 'StoppedWithError' -and $e.Snapshot.CleanupError){throw '通道已停止，但清理未完成，请检查代理与保护状态。'}
            if($e.Identity.Current -and $e.Snapshot -and $e.Snapshot.State -ne 'StoppedWithError'){
                $e.Snapshot|Add-Member -NotePropertyName State -NotePropertyValue 'Disconnected' -Force
                $e.Snapshot|Add-Member -NotePropertyName Error -NotePropertyValue $null -Force
                Write-TCSessionJson (Join-Path $script:Root 'runtime.json') $e.Snapshot
            }
            return (Get-TCSessionPresentation $e (Get-TCPreferences))
        }
        if($i.SessionPresent){
            if(-not ($i.Current -and $i.SupervisorAlive -and $i.EngineAlive -and $s.State -eq 'Running' -and $e.ControlAvailable)){
                throw '通道进程存在，但会话未就绪或控制接口不可用；请断开后重试，不会启动新实例。'
            }
        }else{
            if($Action -in @('HongKong','Provider','DailyDirect','DailyProvider','Agents')){throw '尚未连接，请先连接再应用出口选择。'}
            if(-not $m -or -not $m.SyntaxValidated -or -not $m.DeploymentApproved){throw '请先在部署页导入并启用通过检查的节点。'}
            if($e.Fault){throw '状态读取失败，未启动新实例。'}
            if(Get-Process -Name NinjaTrader -ErrorAction SilentlyContinue){throw '请先退出 NinjaTrader 整个控制中心，再启动通道。'}
            if(Test-Path -LiteralPath $stopPath){Remove-Item -LiteralPath $stopPath -Force}
            $launcher=Start-TCSupervisor $d.ManifestPath
            $startClock=[Diagnostics.Stopwatch]::StartNew();$startBudget=[Math]::Min([double]25,[double](& $remainingAction))
            do{
                & $checkAction
                $e=Get-TCSessionEvidence
                if($e.Snapshot.SupervisorPid -eq $launcher.Id){
                    if($e.Snapshot.State -eq 'StoppedWithError'){throw '通道启动失败，请查看诊断信息；不会自动重启。'}
                    if($e.Identity.SupervisorAlive -and $e.Identity.EngineAlive -and $e.Snapshot.State -eq 'Running' -and $e.ControlAvailable){break}
                }
                if($launcher.HasExited){throw '通道启动进程已经退出，请检查诊断信息；不会自动重试。'}
                Start-Sleep -Milliseconds 200
            }while($startClock.Elapsed.TotalSeconds -lt $startBudget)
            if(-not ($e.Snapshot.SupervisorPid -eq $launcher.Id -and $e.Identity.SupervisorAlive -and $e.Identity.EngineAlive -and $e.Snapshot.State -eq 'Running' -and $e.ControlAvailable)){throw '连接尚未通过状态核验，请检查或断开；不会重复启动。'}
        }
        & $checkAction
        $selectionTimeout=if($TimeoutSeconds -gt 0){[int][Math]::Max(1,[Math]::Floor((& $remainingAction)))}else{0}
        $applied=Set-TCRunningSelection $Action $d $m $selectionTimeout
        & $checkAction
        # Daily and assistant results carry details that the overview cannot infer.
        if($Action -in @('DailyDirect','DailyProvider','Agents')){return $applied}
        Get-TCOverview
    }finally{$lock.Dispose()}
}
if(-not $LoadFunctionsOnly){
    if(-not $Action){throw '请指定连接操作。'}
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'RuntimeBridge.psm1') -DisableNameChecking
    Invoke-TCCommand -Action $Action
}
