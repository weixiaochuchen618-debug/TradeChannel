#requires -Version 5.1
Set-StrictMode -Version 2.0
# Pure presentation decisions: supplied records only, no store/network/process reads.
function DDField {param($Object,[string]$Name,$Default=$null)
 if($Object -is [Collections.IDictionary]){if($Object.Contains($Name)){return $Object[$Name]}}
 elseif($null -ne $Object -and $Object.PSObject.Properties[$Name]){return $Object.$Name};$Default
}
function DDLayers {param($Value)
 for($i=0;$Value -and $i -lt 6;$i++){$Value;$Value=DDField $Value 'Result'}
}
function DDValue {param($Layers,[string]$Name,$Default=$null)
 foreach($layer in $Layers){$value=DDField $layer $Name;if($null -ne $value -and [string]$value -ne ''){return $value}};$Default
}
function DDExpired {param($Value)
 if(-not $Value){return $false};try{[DateTimeOffset]::Parse([string]$Value) -le [DateTimeOffset]::UtcNow}catch{$true}
}
function DDPrepared {param($Profile)
 $null -ne $Profile -and [string](DDField $Profile 'PreparationState' 'Missing') -in @('Ready','Prepared','SyntaxValidated') -and (DDField $Profile 'SyntaxValidated' $true) -ne $false
}
function DDResult {param([string]$Code,[string]$Title,[string]$Message,[string]$Action,[string]$Label,[object[]]$Secondary=@(),[bool]$CanManualTry=$false,[bool]$Blocked=$false,$ProfileId=$null)
 [pscustomobject][ordered]@{Code=$Code;Title=$Title;Message=$Message;PrimaryAction=$Action;PrimaryLabel=$Label;SecondaryActions=@($Secondary);CanManualTry=$CanManualTry;Blocked=$Blocked;ProfileId=$ProfileId}
}
function DDAction {param([string]$Action,[string]$Label) [pscustomobject]@{Action=$Action;Label=$Label}}
function DDSelectionCurrent {param($Recommendation,$Profiles,[string]$SelectedProfileId)
 # The recommendation's top-level digest must never stand in for a profile hash.
 # Legacy records without SelectionData still use the selected evidence binding.
 $declared=if($Recommendation -is [Collections.IDictionary]){$Recommendation.Contains('SelectionData')}else{$null -ne $Recommendation -and $null -ne $Recommendation.PSObject.Properties['SelectionData']}
 if(-not $declared){return $true};$data=DDField $Recommendation 'SelectionData'
 $rows=@($data|Where-Object {$_});$seen=@{}
 if(-not $rows.Count){return $false}
 foreach($row in $rows){
  $id=[string](DDField $row 'ProfileId' '')
  if($id -notin @('Udp','Tcp') -or $seen.ContainsKey($id)){return $false};$seen[$id]=$true
  $currentProfiles=@($Profiles|Where-Object {[string](DDField $_ 'Id' '') -eq $id})
  if($currentProfiles.Count -ne 1){return $false};$profile=$currentProfiles[0]
  $hash=[string](DDField $row 'CandidateSHA256' '')
  if($hash -notmatch '^[a-fA-F0-9]{64}$' -or $hash -ne [string](DDField $profile 'CandidateSHA256' '')){return $false}
  foreach($key in @('ManifestSHA256','ProfileRevision','EngineSHA256')){
   $saved=DDField $row $key;$current=DDField $profile $key
   if(-not $current -and $key -eq 'ProfileRevision'){$current=DDField $profile 'Revision'}
   if($saved -and $current -and [string]$saved -ne [string]$current){return $false}
  }
  $layers=@(DDLayers (DDField $profile 'Validation'))
  foreach($key in @('EvidenceId','Status','Code')){
   $saved=DDField $row $key;$current=DDValue $layers $key
   if($saved -and [string]$saved -ne [string]$current){return $false}
  }
 }
 if(-not $seen.ContainsKey($SelectedProfileId)){return $false}
 foreach($profile in $Profiles){
  if([string](DDField $profile 'CandidateSHA256' '') -match '^[a-fA-F0-9]{64}$' -and -not $seen.ContainsKey([string](DDField $profile 'Id' ''))){return $false}
 }
 return $true
}
function Get-TCDeploymentDecision {
 [CmdletBinding()]param($Run,$Line)
 $profiles=@(DDField $Line 'Profiles' @()|Where-Object {$_})
 if(-not $profiles.Count){$profiles=@(DDField $Run 'Profiles' @()|Where-Object {$_})}
 if(-not $profiles.Count){
  foreach($id in @('Udp','Tcp')){
   $prep=DDField (DDField $Run 'ProtocolPreparation') $id;$validation=DDField (DDField $Run 'ValidationProfiles') $id
   if($prep -or $validation){$local=[string](DDField $prep 'LocalPreparation' 'Missing');$profiles+=,[pscustomobject]@{Id=$id;PreparationState=$local;CandidateSHA256=(DDValue @(DDLayers $validation) 'CandidateSHA256');Validation=$validation}}
  }
 }
 $prepared=@($profiles|Where-Object {DDPrepared $_})
 $stage=[string](DDField $Run 'Stage' '');$status=[string](DDField $Run 'Status' '')
 $access=DDField $Run 'AccessIssue';$accessKind=[string](DDField $access 'Kind' '')
 $preparation=DDField $Run 'ProbePreparation';if(-not $preparation){$preparation=DDField $Line 'ProbePreparation'}
 $bindingResults=@(DDField $preparation 'Results' @()|Where-Object {$_})
 $prepState=[string](DDField $preparation 'State' '');$codes=@();$evidence=@()
 foreach($value in @($Run,$Line,(DDField $Run 'LastError'),(DDField $Run 'ProbeError'),$preparation)+$bindingResults){
  foreach($key in @('Code','ReasonCode')){$code=[string](DDField $value $key '');if($code){$codes+=,$code}}
 }
 foreach($profile in $profiles){
  $validation=DDField $profile 'Validation';if(-not $validation){$validation=DDField (DDField $Run 'ValidationProfiles') ([string](DDField $profile 'Id' ''))}
  $layers=@(DDLayers $validation);$evidence+=$layers
  foreach($layer in $layers){foreach($value in @($layer,(DDField $layer 'PathEvidence'),(DDField $layer 'Comparison'))){
   foreach($key in @('Code','Reason','ReasonCode')){$code=[string](DDField $value $key '');if($code){$codes+=,$code}}
  }}
 }
 $save=DDAction 'Save' '保存配置，稍后使用';$details=DDAction 'Diagnostics' '查看检测详情'
 $retry=DDAction 'Probe' '重新检查';$title='配置已备齐，网络检查需要处理'
 $recovery=([bool](DDField $Run 'RecoveryRequired' $false) -or [bool](DDField $Run 'ProbeRecoveryRequired' $false) -or [bool](DDField $Line 'RecoveryRequired' $false) -or [bool](DDField $Line 'ProbeRecoveryRequired' $false) -or $status -in @('NeedsRecovery','OutcomeUnknown') -or $stage -eq 'NeedsRecovery' -or [string](DDField $Run 'DeploymentCompleteness' '') -eq 'NeedsRecovery' -or [string](DDField $Line 'DeploymentCompleteness' '') -eq 'NeedsRecovery')
 foreach($layer in @($Run,$Line,$preparation)+$bindingResults+$evidence){
  if((DDField $layer 'CleanupComplete' $true) -eq $false -or (DDField $layer 'OwnershipKnown' $true) -eq $false -or [string](DDField $layer 'Status' '') -in @('NeedsRecovery','OutcomeUnknown')){$recovery=$true}
  $comparison=DDField $layer 'Comparison';if((DDField $comparison 'CleanupComplete' $true) -eq $false){$recovery=$true}
 }
 foreach($profile in $profiles){if([string](DDField $profile 'PreparationState' '') -in @('OutcomeUnknown','NeedsRecovery')){$recovery=$true}}
 if($accessKind){
  $resume=if($recovery){'登录后先自动核对原操作结果，不重复部署或授权。'}else{'原资料和进度保留，处理后从本步骤继续。'}
  switch($accessKind){
   'ApplicationReset'{return DDResult 'ApplicationEnvironmentReset' '服务器隧道环境已重置' '登录身份已核验，但原连接环境已经不存在。软件在当前向导核对实际状态后，为新环境准备独立授权。' 'VerifyIdentity' '核对新环境并继续准备' @((DDAction 'Leave' '稍后继续')) $false $true}
   'ApplicationMismatch'{return DDResult 'ApplicationIdentityMismatch' '实际隧道身份需要核对' '原记录与实际服务器环境不一致。先核对归属和身份，不能自动覆盖现有部署。' 'VerifyIdentity' '核对这台服务器的环境' @((DDAction 'Leave' '稍后继续')) $false $true}
   'IdentityChanged'{return DDResult 'ServerIdentityChanged' '服务器登录身份已变化' '请在当前步骤核对新 SSH 身份。软件随后检查实际隧道环境，不凭指纹变化直接重装。当前线路保持。' 'VerifyIdentity' '核对这台服务器的新身份' @((DDAction 'Leave' '稍后继续')) $false $true}
   'FirstTrust'{return DDResult 'FirstServerTrust' '需要核对首次服务器身份' '与云控制台等可信来源核对本次目标和指纹，再继续登录。' 'VerifyIdentity' '核对服务器身份' @((DDAction 'Leave' '稍后继续')) $false $true}
   'Connection'{return DDResult 'ServerConnectionRequired' '服务器管理连接未建立' ('请核对接入地址、SSH 入口与服务器启动情况。'+$resume) 'RetryLogin' '检查接入资料并继续' @((DDAction 'Leave' '稍后继续')) $false $true}
   'PrivateKey'{return DDResult 'ServerPrivateKeyRequired' 'SSH 私钥无法用于这次登录' ('请核对私钥文件和解密口令。'+$resume) 'RetryLogin' '修正登录资料并继续' @((DDAction 'Leave' '稍后继续')) $false $true}
   'ExecutorBusy'{return DDResult 'AccessExecutorBusy' '正在核对管理登录状态' '执行器仍在运行，尚未确认登录结果。保留原操作，不能重复提交安装。' 'Diagnostics' '查看状态详情' @((DDAction 'Leave' '稍后继续')) $false $true}
   default{return DDResult 'ServerAuthenticationRequired' '需要更新服务器登录' ('请提供这次目标的有效凭据。'+$resume) 'RetryLogin' '原地登录并继续' @((DDAction 'Leave' '稍后继续')) $false $true}
  }
 }
 if($recovery -or @($codes|Where-Object {$_ -match 'CleanupFailed|CleanupIncomplete|ProbeIdentityUnknown|OwnershipUnknown|TransactionUnknown|OutcomeUnknown|NeedsRecovery'}).Count){
  return DDResult 'NeedsRecovery' '本次操作需要核对恢复' '尚不能确认上次检查或连接任务已结束。先核对任务与恢复结果，保留当前连接和已准备配置。' 'Recover' '核对并恢复本次检查' @($details,$save) $false $true
 }
 if($Run -and $stage -eq 'PrepareAccess'){
  return DDResult 'WaitingForServerAccess' '正在准备服务器登录' '本机当前连接保持。首次身份核对或登录结果会在本页显示，不会开始未确认的安装。' 'RetryLogin' '修改登录资料' @((DDAction 'Leave' '稍后继续')) $false $true
 }
 if($Run -and $stage -eq 'PlanReady' -and (DDField $Run 'Review')){
  return DDResult 'PreparationReview' '确认准备这条线路' '一次核对目标准备范围：服务器双连接、本机独立授权及配置；当前电脑继续使用现有连接。' 'ApprovePreparation' '开始准备这条线路' @((DDAction 'Leave' '稍后继续')) $false $true
 }
 if($Run -and $stage -notin @('PreparingProbePath','CheckingProfiles','ReadyInactive') -and $status -in @('Failed','Cancelled')){
  return DDResult 'ServerPreparationIncomplete' '服务器准备需要处理' ([string](DDField (DDField $Run 'LastError') 'Message' '已保留原资料。先核对失败阶段，再继续原操作。')) 'RetryServer' '核对本步骤并继续' @((DDAction 'Leave' '稍后继续')) $false $true
 }
 if(@($codes|Where-Object {$_ -match '^(ActiveIdentity|ActiveIdentityInUse|IdentityInUse|ActiveIdentityConflict|ActiveDeviceIdentityInUse)$'}).Count){
  return DDResult 'ActiveIdentity' $title '这台设备的身份正在使用，不能并行检查候选方式。请检查当前连接，或保存后稍后检查。' 'CheckActive' '检查当前连接' @($details,$save) $false $true
 }
 if($prepState -eq 'Blocked' -or @($bindingResults|Where-Object {[string](DDField $_ 'BindingState' '') -eq 'Blocked'}).Count -or [string](DDField $Run 'ProfileProbeState' '') -eq 'Blocked' -or @($evidence|Where-Object {[string](DDField $_ 'Status' '') -eq 'Blocked'}).Count){
  return DDResult 'ProbeBlocked' $title '本次检查被保护条件阻止。查看原因并核对后再继续；当前连接保持。' 'Diagnostics' '查看检查受阻原因' @($save) $false $true
 }
 if($prepState -eq 'Preparing' -or $stage -eq 'PreparingProbePath'){
  return DDResult 'PreparingProbePath' '正在准备检测路径' '正在检查已准备配置并准备本次检测使用的网络，随后分别检查 UDP 和 TCP；当前连接保持。' 'Diagnostics' '查看检查进度' @($save) $false $true
 }
 if($stage -eq 'CheckingProfiles' -or [string](DDField $Run 'ProfileProbeState' '') -in @('Pending','Running')){
  return DDResult 'CheckingProfiles' '正在检查连接方式' '分别检查 UDP 和 TCP，完成后汇总默认建议。检查有时间上限，可停止并保留配置。' 'Diagnostics' '查看检查进度' @($save) $false $true
 }
 $missing=@(DDField $Run 'MissingProtocols' (DDField $Line 'MissingProtocols' @())|Where-Object {$_ -in @('Udp','Tcp')})
 $prepared=@($prepared|Where-Object {(DDField $_ 'Id') -notin $missing})
 $complete=[string](DDField $Run 'DeploymentCompleteness' (DDField $Line 'DeploymentCompleteness' ''))
 $partial=($complete -eq 'Partial' -or $missing.Count -gt 0 -or ($null -ne $Run -and @('Udp','Tcp'|Where-Object {$_ -notin @($prepared|ForEach-Object {DDField $_ 'Id'})}).Count -gt 0))
 $accepted=(DDField $Run 'PartialUseAccepted' $false) -eq $true
 $canManual=($prepared.Count -gt 0 -and (-not $partial -or $accepted))
 $lineId=[string](DDField $Line 'LineId' (DDField $Line 'id' (DDField $Run 'CandidateNodeId' '')))
 if(-not $lineId){$canManual=$false}
 if(DDField $Line 'ServerConnectionBlock'){
  return DDResult 'ServerIdentityUnavailable' '此线路的服务器身份需要核对' ([string](DDField $Line 'ServerConnectionMessage' '此配置属于旧服务器身份，请从部署中心使用当前身份继续准备。')) 'Diagnostics' '查看身份原因' @($save) $false $true
 }
 $savedDefault=DDField $Line 'SavedConnectionPreference' (DDField $Run 'SavedConnectionPreference')
 if($savedDefault -and $canManual -and -not $partial){
  $savedId=[string](DDField $savedDefault 'ProfileId' '');$savedProfiles=@($prepared|Where-Object {[string](DDField $_ 'Id') -eq $savedId})
  $selectedLayers=if($savedProfiles.Count -eq 1){@(DDLayers (DDField $savedProfiles[0] 'Validation'))}else{@()}
  $knownFailure=@($selectedLayers|Where-Object {[string](DDField $_ 'Status' '') -in @('Failed','Blocked') -and [string](DDField $_ 'Code' '') -notmatch 'EvidenceExpired|ActiveIdentity'}).Count -gt 0
  if($savedProfiles.Count -eq 1 -and $savedId -in @('Udp','Tcp') -and -not $knownFailure){
   # Presentation checks the saved profile hash; the transaction revalidates
   # its full origin, identity, manifest and current recovery protections.
   $savedHash=[string](DDField (DDField $savedDefault 'Binding') 'CandidateSHA256' (DDField $savedDefault 'CandidateSHA256' ''))
   if($savedHash -match '^[a-fA-F0-9]{64}$' -and $savedHash -ceq [string](DDField $savedProfiles[0] 'CandidateSHA256' '')){
    return DDResult 'SavedDefaultReady' '服务器与本机连接已准备' '配置和下次默认方式已保存。连接按钮明确使用保存的方式，启用后核对实际出口；旧推荐不作为当前优选。' 'ConnectRecommended' ('连接 '+$savedId.ToUpperInvariant()+' 并检查…') @((DDAction 'Leave' '稍后使用'),$details) $true $false $savedId
   }
  }
 }
 $recommendation=DDField $Line 'Recommendation' (DDField $Run 'Recommendation')
 $recStatus=[string](DDField $recommendation 'Status' '');$source=[string](DDField $recommendation 'Source' '')
 $userChoice=([string](DDField $Line 'PreferenceSource' (DDField $Run 'PreferenceSource' $source)) -eq 'UserChoice' -or $recStatus -eq 'UserChoice')
 $profileId=[string](DDField $recommendation 'RecommendedProfileId' '')
 if($userChoice){$profileId=[string](DDField $Line 'PreferredProfileId' (DDField $Run 'PreferredProfileId' (DDField $recommendation 'PreferredProfileId' (DDField $recommendation 'RequestedProfileId' ''))))}
 $selected=@($prepared|Where-Object {[string](DDField $_ 'Id') -eq $profileId})
 $eligible=$false
 if($profileId -in @('Udp','Tcp') -and $selected.Count -eq 1 -and $lineId){
  $profile=$selected[0];$layers=@(DDLayers (DDField $profile 'Validation' (DDField (DDField $Run 'ValidationProfiles') $profileId)))
  $vStatus=[string](DDValue $layers 'Status' (DDValue $layers 'PathValidation' 'NotTested'))
  $eligible=$userChoice
  if(-not $userChoice){
   $eligible=($recStatus -eq 'Recommended' -and $source -in @('Reachability','PolicyDefault','Performance','Stability') -and $vStatus -eq 'Passed' -and (DDValue $layers 'EligibleForAutomaticSelection' $false) -eq $true -and (DDValue $layers 'ForwardingPassed' $false) -eq $true -and [string](DDValue $layers 'Origin' 'Candidate') -ne 'Runtime' -and [string](DDValue $layers 'ProfileId' '') -eq $profileId -and [string](DDValue $layers 'CandidateSHA256' '') -match '^[a-fA-F0-9]{64}$' -and (DDValue $layers 'ExpiresAt'))
  }
  if(-not $userChoice -and ($vStatus -in @('Failed','Blocked','Stale','NotTested','Inconclusive') -or (DDExpired (DDValue $layers 'ExpiresAt')) -or (DDExpired (DDField $recommendation 'ExpiresAtUtc')))){$eligible=$false}
  foreach($key in @('CandidateSHA256','ManifestSHA256','ProfileRevision')){
   $current=DDField $profile $key;if(-not $current -and $key -eq 'ProfileRevision'){$current=DDField $profile 'Revision'}
   $checked=DDValue $layers $key;$recommended=if($key -eq 'CandidateSHA256'){$null}else{DDField $recommendation $key}
   if(-not $userChoice -and $current -and (($checked -and [string]$current -ne [string]$checked) -or ($recommended -and [string]$current -ne [string]$recommended))){$eligible=$false}
  }
  if(-not $userChoice -and -not (DDSelectionCurrent $recommendation $profiles $profileId)){$eligible=$false}
  $recLine=[string](DDField $recommendation 'LineId' '');if(-not $userChoice -and $recLine -and $recLine -ne $lineId){$eligible=$false}
  if(-not $userChoice -and $preparation){
   $binding=@($bindingResults|Where-Object {[string](DDField $_ 'ProfileId' '') -eq $profileId})
   if($binding.Count -ne 1 -or [string](DDField $binding[0] 'BindingState' '') -notin @('Prepared','Reused')){$eligible=$false}
   elseif($binding.Count -eq 1){foreach($key in @('CandidateSHA256','ManifestSHA256','ProfileRevision')){
    $current=DDField $profile $key;if(-not $current -and $key -eq 'ProfileRevision'){$current=DDField $profile 'Revision'}
    $bound=DDField $binding[0] $key;if($current -and $bound -and [string]$current -ne [string]$bound){$eligible=$false}
   }}
  }
 }
 if($partial){
  $secondary=@($details,$save)
  if($accepted -and $eligible){$secondary=@((DDAction 'ConnectRecommended' '连接已准备方式…'))+$secondary}
  return DDResult 'PartialDeployment' '配置部分准备完成' '只有部分连接方式已准备。继续完成另一种配置，或明确确认先保存已准备方式；网络检查不代表配置已经备齐。' 'CompleteRemaining' '继续完成另一种配置' $secondary $canManual $false $(if($eligible){$profileId}else{$null})
 }
 if($eligible){
  if($userChoice){return DDResult 'UserChoice' ('配置已备齐，你选择 '+$profileId.ToUpperInvariant()) '已保留你选择的默认方式。网络检查结果另列；实际启用前仍需核对连接预览并明确确认。' 'Save' '完成，保留当前连接' @((DDAction 'ConnectRecommended' ('连接指定 '+$profileId.ToUpperInvariant()+'…')),$details) $canManual $false $profileId}
  $message=switch($source){
   'PolicyDefault'{'两种方式均满足本轮连接条件，按默认策略选择；未证明哪种最快。'}
   'Performance'{if((DDField $recommendation 'PerformanceRanked' $false) -eq $true){'建议依据为本轮同目标 HTTPS 响应比较，不代表交易延迟或长期稳定性。'}else{'性能数据不足，沿用策略默认；未证明速度优胜。'}}
   default{($profileId.ToUpperInvariant()+' 满足本轮连接条件。另一种方式的结果另列；本次建议只适用于当前证据。')}
  }
  if([int](DDField $Run 'ExperienceVersion' 0) -ge 1 -and (DDField $Run 'AutoSavedAtUtc')){return DDResult 'RecommendationReady' '服务器与本机连接已准备' ($message+' 配置和结果已自动保存，当前连接保持。') 'ConnectRecommended' ('连接 '+$profileId.ToUpperInvariant()+' 并检查…') @((DDAction 'Leave' '稍后使用'),$details) $canManual $false $profileId}
  return DDResult 'RecommendationReady' ('部署完成，推荐 '+$profileId.ToUpperInvariant()) $message 'Save' '完成，保留当前连接' @((DDAction 'ConnectRecommended' ('连接 '+$profileId.ToUpperInvariant()+'…')),$details) $canManual $false $profileId
 }
 if($prepState -eq 'NeedsNetworkSelection' -or @($bindingResults|Where-Object {[string](DDField $_ 'BindingState' '') -eq 'NeedsNetworkSelection'}).Count -or @($codes|Where-Object {$_ -in @('AmbiguousPhysicalInterface','NeedsNetworkSelection')}).Count){
  return DDResult 'NeedsNetworkSelection' $title '发现多个可用于本次检测的网络。请选择网络名称、连接类型和当前地址；选择只影响候选检查，当前连接保持。' 'ChooseNetwork' '选择检测网络' @($details,$save) $canManual
 }
 if(@($codes|Where-Object {$_ -match 'StoredBindingMissing|BindingMissing|MissingBinding|BindingExpired|BindingStale|LegacyOrUnsupportedBindingScope|BindingsRequired|NetworkChanged|NetworkContextChanged|ConfigurationChanged|EngineChanged|EngineMismatch|EvidenceExpired|BoundInterfaceUnavailable|Ipv4SourceUnavailable'}).Count){
  return DDResult 'ProbePathNeedsPreparation' $title '已有连接配置保留。本次检测路径或旧检查结果需要更新；自动准备后重新检查，无需重新登录或安装服务器。' 'Probe' '自动准备检测路径并重新检查' @($details,$save) $canManual
 }
 if($prepState -in @('Unsupported','Partial') -or @($bindingResults|Where-Object {[string](DDField $_ 'BindingState' '') -eq 'Unsupported'}).Count -or @($codes|Where-Object {$_ -match 'Unsupported|NoSupportedPhysicalInterface|IPv6NotSupported|PhysicalPathUnverified|PathUnverified|Unobservable|EtwUnavailable|Observation|TrustedExitNotVerified|ExpectedExitUnverified'}).Count){
  $limitation=if('IPv6NotSupported' -in $codes){'当前网络仅 IPv6 或目标使用 IPv6，本次检测暂不支持。'}elseif('NoSupportedPhysicalInterface' -in $codes){'未找到可用于本次检查的受支持网络。'}elseif('ForwardingPassedPhysicalPathUnverified' -in $codes){'转发通过，但检测路径未能核验。'}elseif(@($codes|Where-Object {$_ -match 'Unobservable|EtwUnavailable|Observation'}).Count){'当前环境未能完成检测路径的观测。'}elseif(@($codes|Where-Object {$_ -match 'TrustedExitNotVerified|ExpectedExitUnverified'}).Count){'本轮尚未核验预期出口。'}else{'本轮未能完整核验检测路径或出口。'}
  return DDResult 'DetectionLimited' $title ($limitation+'暂不自动推荐，配置保留，当前连接保持。可以查看限制与已准备方式；手动试用前会核对配置、身份及原连接，并要求明确确认。') 'Diagnostics' '查看检测限制' @($retry,$save) $canManual
 }
 if(@($codes|Where-Object {$_ -match 'Ingress|Inbound|CloudRule|EntryCheck|Entrance'}).Count){
  return DDResult 'EntryCheckUnverified' $title '入口检查未通过，需要核对本次入站规则。现有证据不能确定云规则是否有误；核对后重新检查。' 'Diagnostics' '查看本次入站规则' @($retry,$save) $canManual
 }
 $failed=@($evidence|Where-Object {[string](DDField $_ 'Status' '') -eq 'Failed'}).Count -gt 0
 if($failed -or @($codes|Where-Object {$_ -match 'ForwardingFailed|DnsFailed|TlsFailed|ProbeTimeout|^Timeout$|RequiredSampleFailed|ProbeFailed'}).Count){
  return DDResult 'NetworkCheckFailed' $title '本轮请求有超时或连接检查未通过。查看失败目标与次数，处理后可重新检查；这不表示协议永久不可用。' 'Diagnostics' '检查连接问题' @($retry,$save) $canManual
 }
 if($prepState -eq 'Failed'){
  return DDResult 'ProbePreparationFailed' $title '本次本机检测准备未完成，已准备连接资料保留。查看原因后重新准备和检查。' 'Probe' '重新准备并检查' @($details,$save) $canManual
 }
 return DDResult 'CheckRequired' $title '尚无可用的本轮自动推荐。可重新检查，或保存已准备配置后从连接方式页明确选择；实际连接需要另行确认。' 'Probe' '重新检查' @($details,$save) $canManual
}
Export-ModuleMember -Function Get-TCDeploymentDecision
