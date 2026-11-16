#requires -Version 5.1
# Shared high-frequency product language. Keys are stable; user-entered names
# are never translated or rewritten by this catalog.
$script:TCProductText=[ordered]@{
    Connected='已连接';Disconnected='未连接';Connecting='正在连接';Disconnecting='正在断开';Switching='正在切换';Unconfigured='还没有线路';Unstable='线路不稳定';ReadUnknown='无法读取';NeedsAttention='连接需要处理'
    Connect='连接';Disconnect='断开连接';AddLine='添加线路';SwitchLine='切换';Details='详情';Cancel='取消';Save='保存';Retry='重试'
    TradeApps='交易软件';Providers='代理软件';Agents='AI 工具';Daily='日常上网';Direct='本地直连';CurrentLine='当前线路'
    WaitingForApps='退出交易软件后将继续连接；等待时间有限，也可以取消。';GuardRetained='断开后仍阻止名单中的交易软件直连。';ApplyList='应用到当前线路';Check='检查连接';Diagnostics='运行诊断';History='操作记录';Maintenance='维护与恢复'
    GuardFix='修复保护';GuardCheck='检查保护';GuardAddPrograms='添加交易程序';GuardFixNote='重新连接会重新应用阻止规则'
    OutcomeCompleted='切换已完成，实际出口验证通过。';OutcomeRolledBack='连接检查未通过，已回到切换前的状态。';OutcomeAborted='切换没有开始：原连接、配置和选择都没有改动。';OutcomeResolvedStopped='通道已停止，故障记录已结束；当前未连接，也没有自动重连。';OutcomeNeedsRecovery='连接结果还需要确认：配置已经还原，但原连接没有恢复，系统也没有自动启动第二个引擎。'
    ExitVerified='出口已核验';ExitForwardedOnly='转发已通，归属未验证';ExitNotChecked='尚未核验';ExitFailed='本次核验未通过，请运行诊断';ExitInconclusive='本次核验未完成（会话或配置变化）';TestBudget='测速（最长 45 秒）'
    EngineRunning='引擎已运行';EngineRunningNever='—'
    PairStageVerified='邀请码已确认，可以加入这台电脑';PairStageCreating='正在确认邀请码';PairStageAuthorizing='正在为这台电脑开通线路';PairStagePreparing='正在设置并测试线路';PairStageComplete='线路已加入';PairStageNeedsCheck='线路已保存';PairStageFailed='这一步没有完成'
    PairErrorFallback='这一步没有完成';PairStillWorking='仍在处理，已用';PairNoResult='还没有结果；你可以取消后重新开始，或改用旧版表单';PairNoTakeover='它现在不会接管交易，确认能用之后再切换';PairJoinNote='线路已保存，还需要完成这台电脑的连接检查'
    QualityGood='很好';QualityFair='一般';QualityPoor='较差';QualityUnknown='尚未测量';QualityCurrent='当前连接响应';QualityStandby='服务器响应';QualityNote='当前连接包含加密耗时，备用线路仅测服务器响应，数值不能直接比较。'
}
function Get-TCText {param([Parameter(Mandatory=$true)][string]$Key)if(-not $script:TCProductText.Contains($Key)){throw ('Unknown product text key: '+$Key)};[string]$script:TCProductText[$Key]}
function Get-TCTextCatalog {$copy=[ordered]@{};foreach($key in $script:TCProductText.Keys){$copy[$key]=[string]$script:TCProductText[$key]};$copy}
Export-ModuleMember -Function Get-TCText,Get-TCTextCatalog
