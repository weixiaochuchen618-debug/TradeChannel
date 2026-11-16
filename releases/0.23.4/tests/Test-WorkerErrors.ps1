#requires -Version 5.1
param([string]$ReportPath)
$ErrorActionPreference='Stop';$checks=0
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'WorkerErrors.psm1') -DisableNameChecking
function Check {param($ok,$name)if(-not $ok){throw $name};$script:checks++}
$id=[guid]::NewGuid().ToString('N')
foreach($code in @('EngineChanged','ServerBindingChanged','DiagnosticAddressChanged','SavedDefaultMissing','ComponentIntegrityInvalid')){
 $safe=Get-TCWorkerFailure -Failure ('[TC:'+$code+'] SECRET_RAW_PARSER_CONTENT {"password":"also-secret"}') -Action Session -RequestId $id -Phase Executing -MayHaveChanged $true
 Check ($safe.Code -ceq $code -and $safe.RequestId -ceq $id -and $safe.NextAction -ne 'ReviewOperation' -and ($safe|ConvertTo-Json) -notmatch 'SECRET_RAW|also-secret') ('known reason preserved without raw text: '+$code)
}
$unsafe=Get-TCWorkerFailure -Failure 'ConvertFrom-Json failed near {"secret":"AUTHORIZATION_SAMPLE"}' -Action Session -RequestId $id -Phase Executing -MayHaveChanged $true
Check ($unsafe.Code -eq 'WorkerStepFailed' -and $unsafe.OutcomeUnknown -and $unsafe.NextAction -eq 'ReconcileOperation' -and ($unsafe|ConvertTo-Json) -notmatch 'AUTHORIZATION_SAMPLE') 'ambiguous mutation never exposes source JSON or promises it failed before effects'
$before=Get-TCWorkerFailure -Failure 'parser private contents' -Action Session -RequestId $id
Check (-not $before.OutcomeUnknown -and $before.Phase -eq 'BeforeDispatch') 'failure before dispatch is not treated as remote execution'
$unknown=Get-TCWorkerFailure -Failure '[TC:SECRET_UNKNOWN_REASON] credential=raw' -Action Overview -RequestId $id
Check ($unknown.Code -eq 'WorkerStepFailed' -and ($unknown|ConvertTo-Json) -notmatch 'SECRET_UNKNOWN_REASON|credential=raw') 'unrecognized reason is not a path for leaking arbitrary content'
$known=Get-TCWorkerFailure -Failure '[TC:DispatchOutcomeUnknown] secret server output' -Action DeploymentProceed -RequestId $id -Phase Executing
Check ($known.OutcomeUnknown -and $known.ErrorId -cmatch '^[a-f0-9]{32}$') 'unknown remote outcome retains correlation and recovery state'
foreach($code in @('OperationBindingMismatch','OperationResolutionInvalid','OperationEvidenceAmbiguous','OperationHistoryReadLimit','LegacyMutationEvidenceMissing','PlanNotFound')){
 $safe=Get-TCWorkerFailure -Failure ('[TC:'+$code+'] SECRET_RAW_RECOVERY') -Action DeploymentRefresh -RequestId $id -Phase Executing -MayHaveChanged $true
 Check ($safe.Code -ceq $code -and $safe.OutcomeUnknown -and $safe.NextAction -eq 'ReconcileOperation' -and ($safe|ConvertTo-Json) -notmatch 'SECRET_RAW') ('F03 missing proof preserves original recovery barrier: '+$code)
}
foreach($pair in @(@('CredentialTemporarilyUnavailable','RetryLocalRead'),@('UnsupportedTcpPort','EditDeploymentSettings'))){
 $safe=Get-TCWorkerFailure -Failure ('[TC:'+$pair[0]+'] SECRET_RAW_CREDENTIAL') -Action DeploymentCreate -RequestId $id
 Check ($safe.Code -ceq $pair[0] -and $safe.NextAction -eq $pair[1] -and -not $safe.OutcomeUnknown -and ($safe|ConvertTo-Json) -notmatch 'SECRET_RAW') ('F08/F09 actionable local error: '+$pair[0])
}
$result=[pscustomobject]@{Passed=$true;Checks=$checks;RawExceptionPublished=$false;NetworkChanges=0}
foreach($code in @('StartupUnverified','StartupSettingFailed','StartupRollbackFailed')){
 $failure=Get-TCWorkerFailure -Failure ('[TC:'+$code+'] SECRET_STARTUP_DETAILS') -Action SetUserSetting -RequestId $id -Phase Executing -MayHaveChanged $true
 Check ($failure.Code -ceq $code -and $failure.NextAction -ceq 'ReviewSettings' -and ($failure|ConvertTo-Json) -notmatch 'SECRET_STARTUP_DETAILS') ('Settings failure retains a safe actionable reason: '+$code)
 Check ($failure.OutcomeUnknown -eq ($code -ne 'StartupUnverified')) ('Only the pre-write startup refusal has a proven unchanged outcome: '+$code)
}
# --- 0.18.4: a tagged refusal is a refusal, with or without the TradeChannel: prefix ---------------
# Stop-TCError adds "TradeChannel: " in front of the message. The classifier used to require the tag
# at position zero, so every such refusal of a mutating action became an unresolved operation and
# blocked every other action. Real NodeStore wrappers produce the exceptions below.
$node=Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'NodeStore.psm1') -PassThru -DisableNameChecking
function New-WrappedFailure {param([string]$Inner,[switch]$Wrap,$Committed=$null)
 $record=$null
 try{& $node {param($inner,$wrap,$committed)
   if($wrap){try{Stop-TCError $inner}catch{if($null -eq $committed){Stop-TCOperation $_ '线路资料准备或读取失败；原资料与当前连接保留，诊断内容已隐藏。'}else{Stop-TCOperation $_ '线路资料准备或读取失败；原资料与当前连接保留，诊断内容已隐藏。' -Committed:([bool]$committed)}}}
   else{Stop-TCError $inner}
  } $Inner ([bool]$Wrap) $Committed}catch{$record=$_}
 $record
}
function Get-Classified {param($Record,[string]$Action='LinePreference',[bool]$MayHaveChanged=$true,[string]$Phase='Executing')
 Get-TCWorkerFailure -Failure $Record -Action $Action -RequestId $id -Phase $Phase -MayHaveChanged $MayHaveChanged
}
# the real LinePreference refusal that blocked the product on 2026-10-17
$revision=New-WrappedFailure '[TC:PreferenceRevisionChanged] 线路资料已变化，请刷新后重试。' -Wrap -Committed $false
Check ($revision.Exception.Message.StartsWith('TradeChannel: [TC:PreferenceRevisionChanged]')) 'fixture really carries the product prefix'
$f=Get-Classified $revision
Check ($f.Code -ceq 'PreferenceRevisionChanged' -and -not $f.OutcomeUnknown -and $f.NextAction -ceq 'Refresh' -and $f.Message -match '已自动刷新') 'prefixed revision refusal is a known refusal, not an unresolved operation'
# registered code behind the prefix, with and without the wrapper
foreach($wrap in @($false,$true)){
 $f=Get-Classified (New-WrappedFailure '[TC:SavedDefaultMissing] 请先选择原线路的连接方式。' -Wrap:$wrap)
 Check ($f.Code -ceq 'SavedDefaultMissing' -and -not $f.OutcomeUnknown -and $f.NextAction -ceq 'ChooseProfile') ('prefixed registered code keeps its meaning (wrapped='+$wrap+')')
}
# an unregistered tag whose sentence is product text is a refusal and shows that sentence
$f=Get-Classified (New-WrappedFailure '[TC:ZzNewProductRefusal] 这条线路暂时不能这样设置，请稍后再试。')
Check ($f.Code -ceq 'ZzNewProductRefusal' -and -not $f.OutcomeUnknown -and $f.Message -match '这条线路暂时不能这样设置') 'unregistered tag with product text is a known refusal that uses its own sentence'
# unusable text never becomes a recognised refusal and never leaks
foreach($bad in @('[TC:ZzOddRefusal] credential=raw password: hunter2','[TC:ZzOddRefusal] 失败 C:\Users\ExampleUser\secret\client.key','[TC:ZzOddRefusal] 失败 AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA')){
 $f=Get-Classified (New-WrappedFailure $bad)
 Check ($f.Code -ceq 'WorkerStepFailed' -and $f.OutcomeUnknown -and ($f|ConvertTo-Json) -notmatch 'hunter2|client\.key|AAAAAAAA|ZzOddRefusal') 'unusable product text stays generic, conservative for a mutation, and leaks nothing'
}
# codes listed as possibly-changed stay unresolved, with and without the prefix
foreach($code in @('ServerTransactionPending','TcpMutationNotResolved','OriginalRequestNotResolved','ProviderRuntimeUncertain','ProviderRelayRecoveryRequired','LinePolicyRecoveryRequired','ConnectionTimeout','MutationIdentityChanged','DispatchOutcomeUnknown','OutcomeUnknown')){
 foreach($wrap in @($false,$true)){
  $f=Get-Classified (New-WrappedFailure ('[TC:'+$code+'] 原操作尚缺可核实的证明，保留原申请及恢复屏障。') -Wrap:$wrap) -Action DeploymentProceed
  Check ($f.Code -ceq $code -and $f.OutcomeUnknown -and $f.NextAction -in @('ReconcileOperation','ReviewIdentity')) ('unresolved code stays unresolved: '+$code+' wrapped='+$wrap)
 }
}
# commit evidence
$notApplied=New-WrappedFailure '线路资料没有准备好。' -Wrap -Committed $false
$f=Get-Classified $notApplied
Check ($f.Code -ceq 'LocalOperationNotApplied' -and -not $f.OutcomeUnknown -and $f.Message -match '原资料保留，可以重试' -and $f.NextAction -ceq 'RetryOperation') 'untagged wrapped failure with nothing written is a known failure that kept the original data'
$readBack=New-WrappedFailure '读取结果失败。' -Wrap -Committed $true
$f=Get-Classified $readBack
Check ($f.Code -ceq 'LocalResultReadFailed' -and -not $f.OutcomeUnknown -and $f.NextAction -ceq 'Refresh' -and $f.Message -match '已保存') 'committed write with a failed read-back is saved, not unresolved, and asks for a refresh'
$silent=New-WrappedFailure '线路资料没有准备好。' -Wrap
$f=Get-Classified $silent
Check ($f.Code -ceq 'WorkerStepFailed' -and $f.OutcomeUnknown) 'a wrapper that states nothing keeps the conservative default for a mutating action'
$f=Get-Classified $silent -MayHaveChanged $false
Check (-not $f.OutcomeUnknown) 'the same failure of a read-only action is never unresolved'
$tagWins=New-WrappedFailure '[TC:ServerTransactionPending] 服务器尚有未完成事务。' -Wrap -Committed $false
$f=Get-Classified $tagWins -Action DeploymentProceed
Check ($f.OutcomeUnknown -and $f.Code -ceq 'ServerTransactionPending') 'a possibly-changed tag is not downgraded by a not-committed note'
# the prefix must not hide an exact public sentence either
$exact=New-WrappedFailure '请先退出 NinjaTrader 整个控制中心，再启动通道。'
$f=Get-Classified $exact -Action Session
Check ($f.Code -ceq 'OperationRejected' -and -not $f.OutcomeUnknown) 'prefixed exact public sentence is recognised'
# every registered refusal added in 0.18.4 keeps a non-empty plain-Chinese message and is not unresolved
foreach($code in @('PreferenceRevisionChanged','PreferenceProfileChanged','LineRevisionChanged','PreferenceReadbackInvalid','LinePolicyPending','AutoConnectMissing','ProviderInUse','PreparationIdentityChanged')){
 $f=Get-Classified (New-WrappedFailure ('[TC:'+$code+'] x') -Wrap) -Action LinePreference
 Check ($f.Code -ceq $code -and -not $f.OutcomeUnknown -and $f.Message -match '[\u4e00-\u9fff]') ('registered refusal is plain Chinese and settled: '+$code)
}
$result.Checks=$checks
if($ReportPath){$result|ConvertTo-Json|Set-Content -LiteralPath $ReportPath -Encoding UTF8};$result|ConvertTo-Json
