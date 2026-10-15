#requires -Version 5.1
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'DeploymentStore.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'DraftDisposition.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'ServerRegistry.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'DeploymentTransport.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'ProtocolSelection.psm1') -DisableNameChecking
function Initialize-TCDeploymentProtocolState {param($Run)
 foreach($field in @(
  @{Name='RecoveryAttempt';Value=$null},@{Name='RecoveryVerification';Value=$null},
  @{Name='ProtocolPreparation';Value=[pscustomobject]@{Udp=[pscustomobject]@{ServerPreparation='Pending';LocalPreparation='Missing';Error=$null};Tcp=[pscustomobject]@{ServerPreparation='NotConfigured';LocalPreparation='Missing';Error=$null}}},
  @{Name='ValidationProfiles';Value=[pscustomobject]@{Udp=[pscustomobject]@{PathValidation='NotTested'};Tcp=[pscustomobject]@{PathValidation='NotTested'}}},
  @{Name='CloudRuleList';Value=@()},@{Name='RecommendedProfileId';Value=$null},@{Name='TcpPlan';Value=$null},@{Name='TcpInfo';Value=$null},
  @{Name='TcpFailure';Value=$null},@{Name='RecoveryRequired';Value=$false},@{Name='UdpRecheck';Value=$null},@{Name='StopTransaction';Value=$null},
  @{Name='ExistingDevice';Value=$false},@{Name='ConnectionBundle';Value=$null},@{Name='UnresolvedTcpMutation';Value=$null},
  @{Name='ApprovedTransportChoices';Value=$null},@{Name='TransportOptions';Value=$null},
  @{Name='DualPreparationRequired';Value=([string](Get-TCDField $Run Intent '') -ne 'Pairing')},
  @{Name='DeploymentCompleteness';Value='Partial'},@{Name='MissingProtocols';Value=@('Udp','Tcp')},@{Name='PartialUseAccepted';Value=$false},
  @{Name='Recommendation';Value=$null},@{Name='ProfileProbeState';Value='NotStarted'},@{Name='ProbeAttemptId';Value=$null},
  @{Name='ProbeStartedAt';Value=$null},@{Name='ProbeCompletedAt';Value=$null},@{Name='NetworkContext';Value=$null},@{Name='ProbeError';Value=$null},@{Name='ProbeBindingResult';Value=$null},@{Name='ProbeCancellationPath';Value=$null},@{Name='CheckingProfileId';Value=$null},
  @{Name='ProbePreparation';Value=$null},@{Name='ProbeInterfaceIndex';Value=0},@{Name='ProbeProgress';Value=$null},@{Name='ProbeHistory';Value=@()},@{Name='SavedForLaterAtUtc';Value=$null},@{Name='ProbeRecoveryRequired';Value=$false}
 )){if(-not $Run.PSObject.Properties[$field.Name]){$Run|Add-Member NoteProperty $field.Name $field.Value}}
 Update-TCDeploymentCompleteness $Run
}
function Update-TCDeploymentCompleteness {param($Run)
 # Configuration readiness is independent of reachability, performance and
 # the user's initial transport preference. Legacy records are conservative.
 $missing=@(foreach($id in @('Udp','Tcp')){
  $preparation=Get-TCDField $Run.ProtocolPreparation $id
  if((Get-TCDField $preparation ServerPreparation '') -cne 'Configured' -or (Get-TCDField $preparation LocalPreparation '') -cne 'SyntaxValidated'){$id}
 })
 $previous=@($Run.MissingProtocols) -join ','
 $Run.MissingProtocols=@($missing)
 $Run.DeploymentCompleteness=if($Run.RecoveryRequired -or $Run.UnresolvedTcpMutation -or $Run.Status -in @('OutcomeUnknown','NeedsRecovery') -or $Run.Stage -eq 'NeedsRecovery'){'NeedsRecovery'}elseif($missing.Count){'Partial'}else{'Complete'}
 if($Run.DeploymentCompleteness -ne 'Partial' -or $previous -cne ($missing -join ',')){$Run.PartialUseAccepted=$false}
 if($Run.Stage -eq 'ReadyInactive'){
  if($Run.DeploymentCompleteness -eq 'NeedsRecovery'){$Run.Stage='NeedsRecovery';$Run.Status='NeedsRecovery';$Run.RecommendedProfileId=$null}
  elseif($Run.DeploymentCompleteness -eq 'Partial'){$Run.Status='PartialDeployment'}
  elseif($Run.Status -in @('PartialDeployment','CompletedWithWarnings')){$Run.Status='WaitingUser'}
 }
}
function Set-TCDeploymentReadyState {param($Run,[bool]$Cancelled=$false)
 $Run.Stage='ReadyInactive';$Run.Status=if($Cancelled){'Cancelled'}else{'WaitingUser'}
 Update-TCDeploymentCompleteness $Run
 if($Run.DeploymentCompleteness -eq 'NeedsRecovery'){$Run.UserActions=@('核对事务与清理结果');return}
 if($Run.DeploymentCompleteness -eq 'Partial'){
  $Run.UserActions=if($Run.PartialUseAccepted){@('使用已准备方式','补齐缺失协议','稍后使用')}else{@('先使用已准备方式','补齐缺失协议','稍后使用')}
 }elseif($Run.ProfileProbeState -eq 'Pending'){$Run.UserActions=@('正在自动比较已准备的连接方式','稍后使用')}
 elseif((Get-TCDField $Run.Recommendation Status '') -eq 'Recommended'){$Run.UserActions=@('连接推荐方式','稍后使用')}
 elseif((Get-TCDField $Run.Recommendation Status '') -eq 'UserChoice'){$Run.UserActions=@('连接所选方式','稍后使用')}
 else{$Run.UserActions=@('重新检查','稍后使用')}
}
function Import-TCDeploymentProfiles {
 Import-Module (Join-Path $PSScriptRoot 'LineStore.psm1') -DisableNameChecking -ErrorAction Stop
 foreach($name in @('Register-TCLineProfiles','Prepare-TCTcpLineProfile','Get-TCLineProfile')){if(-not (Get-Command $name -ErrorAction SilentlyContinue)){throw '[TC:ProfileApiUnavailable] 线路 profile API 尚不可用，原候选配置已保留。'}}
}
function Update-TCDeploymentCloudRules {param([string]$Root,$Run)
 $server=Get-TCServer $Root $Run.ServerRecordId;$rules=@()
 if($server.Connection){$rules+=[pscustomobject]@{Purpose='SSH';Protocol='tcp';Port=[int]$server.Connection.Port;Evidence='NotInspected'}}
 $endpoint=[string](Get-TCDField $Run.ClientResponse PublicEndpoint '')
 $port=if($endpoint){[int]($endpoint.Split(':')[-1])}else{[int]$Run.VpnPort}
 $rules+=[pscustomobject]@{Purpose='UDP';Protocol='udp';Port=$port;Evidence='NotInspected'}
 $tcp=Get-TCDField $Run.TcpInfo Transport (Get-TCDField $Run.ClientResponse Transport)
 if(-not $tcp -and $Run.TcpPlan){$tcp=Get-TCDField $Run.TcpPlan Transport}
 if($tcp -or $Run.DualPreparationRequired){$rules+=[pscustomobject]@{Purpose='TCP';Protocol='tcp';Port=$(if($tcp){[int]$tcp.Port}else{[int]$Run.TcpPort});Evidence='NotInspected';ServerName=$(if($tcp){[string]$tcp.ServerName}else{[string]$Run.ServerName})}}
 $Run.CloudRuleList=@($rules)
}
function Assert-TCDeploymentTransportBinding {param($Run,$Info)
 $binding=Get-TCDField $Run.ServerInfo Node
 if($Info.Kind -cne 'TradeChannel.TransportInfo' -or $Info.Status -cnotin @('Available','NotConfigured')){throw '[TC:TransportInfoInvalid] TCP 参数返回不符合契约。'}
 foreach($field in @('ServerPublicKey','ClientPublicKey','ClientAddress','NodeId')){if([string](Get-TCDField $Info $field '') -cne [string](Get-TCDField $Run.ClientResponse $field '')){throw '[TC:TransportBindingMismatch] TCP 参数不属于原设备授权。'}}
 if(-not $binding -or $binding.NodeId -cne $Info.NodeId -or $Run.ServerInfo.RemoteOwnerId -cne $Info.RemoteOwnerId){throw '[TC:TransportBindingMismatch] TCP 参数服务器归属不匹配。'}
}
function Complete-TCDeploymentProfiles {param([string]$Root,$Run,$TransportInfo)
 Import-TCDeploymentProfiles
 $null=Register-TCLineProfiles -Root $Root -Id $Run.CandidateNodeId
 if($TransportInfo){Assert-TCDeploymentTransportBinding $Run $TransportInfo;$null=Prepare-TCTcpLineProfile -Root $Root -Id $Run.CandidateNodeId -TransportInfo $TransportInfo}
 $udp=Get-TCLineProfile -Root $Root -Id $Run.CandidateNodeId -ProfileId Udp
 if(-not $udp -or $udp.PreparationState -cne 'SyntaxValidated'){throw '[TC:UdpProfileMissing] 原 UDP profile 尚未通过语法检查。'}
 $Run.ProtocolPreparation.Udp.LocalPreparation='SyntaxValidated'
 if($TransportInfo){$tcp=Get-TCLineProfile -Root $Root -Id $Run.CandidateNodeId -ProfileId Tcp;if(-not $tcp -or $tcp.PreparationState -cne 'SyntaxValidated'){throw '[TC:TcpProfileMissing] TCP profile 尚未通过语法检查。'};$Run.ProtocolPreparation.Tcp.LocalPreparation='SyntaxValidated';$Run.ProtocolPreparation.Tcp.ServerPreparation='Configured';$Run.ProtocolPreparation.Tcp.Error=$null;$Run.TcpFailure=$null}
 $Run.RecommendedProfileId=$null;$Run.Recommendation=$null;$Run.ProfileProbeState='Pending'
 Update-TCDeploymentCloudRules $Root $Run
 Set-TCDeploymentReadyState $Run;$Run.NetworkChanged=$false
}
function Start-TCDeploymentTcpInspection {param([string]$Root,$Run)
 if($Run.Intent -eq 'Pairing'){throw '[TC:ConnectorOnly] 邀请接入只有连接使用权，请取得含 TCP 的授权资料。'}
 $Run.ProtocolPreparation.Tcp.ServerPreparation='Inspecting'
 Start-TCDeploymentRemote $Root $Run transport_info InspectTcp @{ClientPublicKey=$Run.ClientResponse.ClientPublicKey;ServerPublicKey=$Run.ClientResponse.ServerPublicKey}
}
function Get-TCDeploymentApprovedTransportChoices {param($Run)
 if($Run.ApprovedTransportChoices){return $Run.ApprovedTransportChoices}
 # Historical approvals did not include fallback targets. Preserve their one
 # requested domain; never expand an old digest to authorize another domain.
 return [pscustomobject]@{CandidatePorts=@(443,8443,2443);ServerName=$Run.ServerName;CandidateServerNames=@($Run.ServerName)}
}
function Start-TCDeploymentUdpRecheck {param([string]$Root,$Run,$ErrorInfo,[bool]$RecoveryRequired=$false)
 $Run.TcpFailure=$ErrorInfo;$Run.ProtocolPreparation.Tcp.Error=$ErrorInfo;$Run.RecoveryRequired=$RecoveryRequired
 $Run.ProtocolPreparation.Tcp.ServerPreparation=if($RecoveryRequired){'OutcomeUnknown'}else{'Failed'}
 if($RecoveryRequired -and $Run.LastRemoteMutation -and $Run.LastRemoteMutation.Operation -ceq 'transport_apply'){$Run.UnresolvedTcpMutation=$Run.LastRemoteMutation}
 Start-TCDeploymentRemote $Root $Run deployment_state RecheckUdp @{ClientPublicKey=$Run.ClientResponse.ClientPublicKey;ServerPublicKey=$Run.ClientResponse.ServerPublicKey}
}
function Assert-TCDeploymentMutationIntent {param($Run)
 $mutation=$Run.LastRemoteMutation;$operation=[string](Get-TCDField $mutation Operation '')
 if(-not $mutation -or -not (Get-TCDField $mutation Mutating $false) -or $mutation.State -notin @('Prepared','Dispatched','Completed')){throw '[TC:MutationIntentMissing] 缺少原始变更意图，无法安全核对。'}
 $null=Assert-TCDId ([string]$mutation.IntentId)
 switch($operation){
  'management_apply'{$plan=$Run.ManagementPlan;$inputData=@{PlanId=(Get-TCDField $plan PlanId);ApprovedChangeDigest=(Get-TCDField $plan ChangeDigest)}}
  'transport_apply'{$plan=$Run.TcpPlan;$inputData=@{PlanId=(Get-TCDField $plan PlanId);ApprovedChangeDigest=(Get-TCDField $plan ChangeDigest)}}
  'apply'{$plan=$Run.Plan;$inputData=@{PlanId=(Get-TCDField $plan PlanId)}}
  'authorize'{$inputData=@{ClientRequest=$Run.ClientRequest}}
  default{throw '[TC:UnsupportedMutation] 此变更不能按设备授权核对，请使用对应的服务器维护流程。'}
 }
 if($operation -ne 'authorize'){$null=Assert-TCDId ([string](Get-TCDField $plan PlanId ''))}
 if((Get-TCDDigest $inputData) -cne [string](Get-TCDField $mutation InputDigest '')){throw '[TC:MutationIntentChanged] 原变更参数或计划已变化，未解除恢复。'}
 if($Run.UnresolvedTcpMutation -and ($operation -cne 'transport_apply' -or $Run.UnresolvedTcpMutation.IntentId -cne $mutation.IntentId)){throw '[TC:OtherMutationPending] 另有未核对的 TCP 变更，必须保留恢复状态。'}
}
function Assert-TCDeploymentRecoveryServer {param($Run,$Info)
 if((Get-TCDField $Info OwnershipState '') -cne 'Applied' -or $null -ne (Get-TCDField $Info PendingOperation '__Missing__')){throw '[TC:ServerTransactionPending] 服务器尚有未完成事务，不能认定变更完成。'}
 if((Get-TCDField (Get-TCDField $Info Health) LocalConfiguration '') -cne 'Verified'){throw '[TC:ServerHealthUnverified] 服务器配置未通过实际验证。'}
 $node=Get-TCDField $Info Node
 foreach($field in @('NodeId','ServerPublicKey')){if(-not (Get-TCDField $node $field '')){throw '[TC:MutationIdentityMissing] 服务器身份信息不完整。'}}
 if(-not (Get-TCDField $Info RemoteOwnerId '')){throw '[TC:MutationIdentityMissing] 服务器归属信息不完整。'}
 $binding=if($Run.LastRemoteMutation.Operation -ceq 'management_apply'){Get-TCDField $Run.ManagementPlan ServerBinding}elseif($Run.LastRemoteMutation.Operation -ceq 'transport_apply'){$Run.TcpPlan}else{$null}
 if($Run.LastRemoteMutation.Operation -in @('management_apply','transport_apply') -and -not $binding){throw '[TC:MutationBindingMissing] 原计划缺少目标身份，无法核对。'}
 if($binding){
  if(-not (Get-TCDField $binding NodeId '') -or -not (Get-TCDField $binding RemoteOwnerId '') -or -not (Get-TCDField $binding ServerPublicKey '') -or $binding.NodeId -cne $node.NodeId -or $binding.RemoteOwnerId -cne $Info.RemoteOwnerId -or $binding.ServerPublicKey -cne $node.ServerPublicKey){throw '[TC:MutationIdentityChanged] 实际服务器与原变更目标不一致。'}
 }
 $reply=$Run.ClientResponse
 if($reply -and ($reply.NodeId -cne $node.NodeId -or $reply.ServerPublicKey -cne $node.ServerPublicKey)){throw '[TC:MutationIdentityChanged] 实际服务器与原设备授权不一致。'}
 if($Run.LastRemoteMutation.Operation -ceq 'apply' -and (Get-TCDField $Info ActivePlanId '') -cne $Run.Plan.PlanId){throw '[TC:MutationPlanChanged] 实际部署不是原始安装计划。'}
}
function Test-TCDeploymentMutationSettled {param($Run,$ServerInfo)
 try{
  Assert-TCDeploymentMutationIntent $Run
  if($Run.LastRemoteMutation.Operation -cne 'management_apply'){throw '[TC:UnsupportedMutation] 此入口只核对管理初始化。'}
  Assert-TCDeploymentRecoveryServer $Run $ServerInfo
  $signing=Get-TCDField $ServerInfo ManagementSigningPublicKey
  if(-not $signing){throw '[TC:ManagementIdentityMissing] 尚未取得完整管理签名身份。'}
  Assert-TCManagementSigningPublicKey $signing
  if([int](Get-TCDField $ServerInfo ManagementApiVersion 0) -ne 2 -or [int](Get-TCDField $ServerInfo ManagementRevision 0) -lt 1){throw '[TC:ManagementRevisionBehind] 管理接口版本或修订号尚未达到要求。'}
  if([int](Get-TCDField $Run.ManagementPlan ConfigRevision 0) -lt 1 -or [int](Get-TCDField $ServerInfo ConfigRevision 0) -ne [int]$Run.ManagementPlan.ConfigRevision){throw '[TC:MutationRevisionChanged] 隧道配置已偏离原管理计划，请核对后续变更。'}
  return [pscustomobject]@{Settled=$true;Code='ManagementIdentityVerified';Message='已核对管理身份、原计划与服务器健康状态。';ManagementRevision=$ServerInfo.ManagementRevision}
 }catch{
  $code='MutationProofInvalid';$message='原变更的核对证据不完整。'
  if($_.Exception.Message -match '^\[TC:([A-Za-z0-9_]+)\] (.+)$'){$code=$Matches[1];$message=$Matches[2]}
  return [pscustomobject]@{Settled=$false;Code=$code;Message=$message}
 }
}
function Set-TCDeploymentRecoveryBlocked {param($Run,[string]$Code,[string]$Message)
 $Run.Stage='NeedsRecovery';$Run.Status='NeedsRecovery';$Run.RecoveryRequired=$true;$Run.RecommendedProfileId=$null
 $Run.PendingOperationId=$null;$Run.PendingPurpose=$null
 $Run.LastError=[pscustomobject]@{Code=$Code;Message=$Message};$Run.UserActions=@('重新核对服务器状态','稍后继续')
 if($Run.RecoveryVerification){$Run.RecoveryVerification.Status='Blocked'}
}
function Start-TCDeploymentReconciliation {param([string]$Root,$Run,[bool]$Explicit=$false)
 $id=[string](Get-TCDField $Run.LastRemoteMutation IntentId '')
 if(-not $Explicit -and $Run.RecoveryAttempt -and $Run.RecoveryAttempt.MutationIntentId -ceq $id){Set-TCDeploymentRecoveryBlocked $Run 'ReconciliationRequiresAction' '本次自动核对已结束，请处理提示后选择重新核对。';return}
 try{Assert-TCDeploymentMutationIntent $Run}catch{Set-TCDeploymentRecoveryBlocked $Run 'MutationProofUnavailable' $_.Exception.Message;return}
 $attempt=[pscustomobject]@{AttemptId=[guid]::NewGuid().ToString();MutationIntentId=$id;Operation=$Run.LastRemoteMutation.Operation;InputDigest=$Run.LastRemoteMutation.InputDigest;ServerRecordId=$Run.ServerRecordId;SessionDigest=(Get-TCDDigest $Run.SessionRef);ObservationBinding=$null;Reads=0;DeadlineUtc=[DateTimeOffset]::UtcNow.AddMinutes(3).ToString('o')}
 $Run.RecoveryAttempt=$attempt
 $Run.RecoveryVerification=[pscustomobject]@{Status='Checking';MutationIntentId=$id;Operation=$attempt.Operation;ServerRecordId=$Run.ServerRecordId;RunId=$Run.RunId;CompletedAtUtc=$null;ResumeStage='ServerInfo'}
 $Run.RecoveryRequired=$true
 if($attempt.Operation -in @('apply','authorize')){Start-TCDeploymentRemote $Root $Run status RecoveryStatus @{}}
 else{Start-TCDeploymentRemote $Root $Run server_info RecoveryServerInfo @{}}
}
function Assert-TCDeploymentRecoveryObservation {param([string]$Root,$Run)
 $attempt=$Run.RecoveryAttempt
 if(-not $attempt -or $attempt.MutationIntentId -cne $Run.LastRemoteMutation.IntentId -or $attempt.Operation -cne $Run.LastRemoteMutation.Operation -or $attempt.InputDigest -cne $Run.LastRemoteMutation.InputDigest -or $attempt.ServerRecordId -cne $Run.ServerRecordId -or $attempt.SessionDigest -cne (Get-TCDDigest $Run.SessionRef)){throw '[TC:RecoveryBindingChanged] 核对期间任务、会话或原始意图已变化。'}
 Assert-TCDeploymentMutationIntent $Run
 $observation=Get-TCDeployVerifiedOperation -SessionRef $Run.SessionRef -Operation $Run.DispatchIntent.Operation -OperationId $Run.PendingOperationId
 $server=Get-TCServer $Root $Run.ServerRecordId
 if($server.Connection.Host -cne $observation.Connection.Host -or [int]$server.Connection.Port -ne [int]$observation.Connection.Port -or $server.Connection.User -cne $observation.Connection.User -or -not $server.PinnedHostKey -or ([string]$server.PinnedHostKey).TrimEnd('=') -cne $observation.ObservedFingerprint){throw '[TC:RecoveryHostChanged] 核对会话未证明原服务器地址与已固定主机密钥。'}
 $binding=Get-TCDDigest @{Connection=$observation.Connection;Fingerprint=$observation.ObservedFingerprint;Algorithm=$observation.ObservedHostKeyAlgorithm;Generation=$observation.AuthenticationGeneration}
 if($attempt.ObservationBinding -and $attempt.ObservationBinding -cne $binding){throw '[TC:RecoverySessionChanged] 核对期间认证会话发生变化，请重新核对。'}
 $attempt.ObservationBinding=$binding;$attempt.Reads++
 if($attempt.Reads -gt 5){throw '[TC:RecoveryReadLimit] 本次核对达到读取上限，请处理提示后重新核对。'}
 return $observation
}
function Complete-TCDeploymentRecovery {param($Run,[string]$ResumeStage='ServerInfo',[ValidateSet('Applied','NotApplied')][string]$Outcome='Applied')
 $mutation=$Run.LastRemoteMutation
 $mutation.State=if($Outcome -eq 'NotApplied'){'NotApplied'}else{'Completed'}
 if($Run.UnresolvedTcpMutation -and $Run.UnresolvedTcpMutation.IntentId -ceq $mutation.IntentId){$Run.UnresolvedTcpMutation=$null}
 # Resolve only a stop marker for this exact remote operation. Local probe
 # cleanup and unrelated stop/transaction markers remain independent barriers.
 if($Run.StopTransaction -and (Get-TCDField (Get-TCDField $Run.StopTransaction DispatchIntent) IntentId '') -ceq $mutation.IntentId){$Run.StopTransaction.State='Reconciled'}
 $otherStop=$Run.StopTransaction -and $Run.StopTransaction.State -ne 'Reconciled'
 $Run.RecoveryRequired=[bool]($Run.ProbeRecoveryRequired -or $Run.UnresolvedTcpMutation -or $otherStop)
 $proof=$Run.RecoveryVerification;$proof.Status='Verified';$proof.CompletedAtUtc=[DateTimeOffset]::UtcNow.ToString('o');$proof.ResumeStage=$ResumeStage
 $proof|Add-Member NoteProperty Outcome $Outcome -Force
 if($Outcome -eq 'NotApplied'){
  # Preserve the resolved original intent and proposal before any subsequent
  # operation can replace LastRemoteMutation or ManagementPlan.
  $entry=[pscustomobject]@{Mutation=$mutation;ManagementPlan=$Run.ManagementPlan;Verification=$proof;Evidence=$Run.RecoveryAttempt.NotAppliedEvidence}
  $entry=ConvertFrom-Json (ConvertTo-Json -InputObject $entry -Depth 32 -Compress)
  $Run|Add-Member NoteProperty ResolvedMutationHistory (@(Get-TCDField $Run ResolvedMutationHistory @())+@($entry)) -Force
  $Run.AllowManagementInitialize=$false;$Run.ApprovedChangeDigest=$null
 }
 $Run.LastError=$null;$Run.PendingOperationId=$null;$Run.PendingPurpose=$null
 if($Run.RecoveryRequired){$Run.Stage='NeedsRecovery';$Run.Status='NeedsRecovery';$Run.UserActions=@('处理其余事务与本机清理结果')}
 else{$Run.Stage='RecoveryVerified';$Run.Status='WaitingUser';$Run.UserActions=@('继续原部署','稍后继续')}
}
function Sync-TCDeploymentRecovery {param([string]$Root,$Run,[string]$Purpose,$Data)
 switch($Purpose){
  'RecoveryStatus'{
   if((Get-TCDField $Data Status '') -cne 'Applied'){throw '[TC:ServerTransactionPending] 原部署尚未处于健康的已应用状态。'}
   Start-TCDeploymentRemote $Root $Run request_status RecoveryRequest @{RequestId=$Run.ClientRequest.RequestId}
  }
  'RecoveryRequest'{
   $reply=Get-TCDField $Data ClientResponse
   if(-not $reply -or (Get-TCDField $Data Status '') -cne 'Authorized' -or (Get-TCDField $Data RequestId '') -cne $Run.ClientRequest.RequestId -or $reply.RequestId -cne $Run.ClientRequest.RequestId -or $reply.DeviceId -cne $Run.ClientRequest.DeviceId -or $reply.ClientPublicKey -cne $Run.ClientRequest.ClientPublicKey){throw '[TC:OriginalRequestNotResolved] 尚未读到属于原申请与原设备的授权结果，未重复授权。'}
   $Run.ClientResponse=$reply
   Start-TCDeploymentRemote $Root $Run server_info RecoveryServerInfo @{}
  }
  {$_ -in @('RecoveryServerInfo','RecoveryFinalInfo')}{
   $operation=$Run.LastRemoteMutation.Operation
   Assert-TCDeploymentRecoveryServer $Run $Data
   if($operation -ceq 'management_apply'){
    $notApplied=Get-TCDField $Run.RecoveryAttempt NotAppliedEvidence
    $proof=Test-TCDeploymentMutationSettled $Run $Data
    if(-not $proof.Settled){
     if($proof.Code -cne 'ManagementIdentityMissing' -or [int](Get-TCDField $Data ManagementApiVersion 0) -ne 1 -or $null -ne (Get-TCDField $Data ManagementRevision '__Missing__') -or [int](Get-TCDField $Run.ManagementPlan ConfigRevision 0) -lt 1 -or [int](Get-TCDField $Data ConfigRevision 0) -ne [int]$Run.ManagementPlan.ConfigRevision){throw ('[TC:'+$proof.Code+'] '+$proof.Message)}
     $registered=Get-TCServer $Root $Run.ServerRecordId
     if(Get-TCDField $registered ManagementSigningPublicKey){throw '[TC:ManagementIdentityMissing] 已登记的管理身份缺失，不能将其认定为尚未初始化。'}
     if($Purpose -eq 'RecoveryServerInfo'){
      Start-TCDeploymentRemote $Root $Run management_recovery_state RecoveryManagementState @{PlanId=$Run.ManagementPlan.PlanId;ApprovedChangeDigest=$Run.ManagementPlan.ChangeDigest}
      break
     }
     if(-not $notApplied){throw '[TC:ManagementAbsenceUnverified] 缺少原过期计划未生效的核对证据。'}
    }elseif($notApplied){throw '[TC:ManagementStateChanged] 管理身份在核对期间发生变化，请重新读取原操作结果。'}
   }
   elseif($operation -ceq 'transport_apply'){
    if((Get-TCDField $Data ActivePlanId '') -cne $Run.TcpPlan.PlanId -or [int](Get-TCDField $Run.TcpPlan BaseConfigRevision -1) -lt 1 -or [int](Get-TCDField $Data ConfigRevision 0) -ne ([int]$Run.TcpPlan.BaseConfigRevision+1) -or $Run.ClientResponse.DeviceId -cnotin @(Get-TCDField $Run.TcpPlan AffectedDeviceIds @())){throw '[TC:TcpMutationNotResolved] 当前 TCP 计划、修订号或设备范围与原变更不一致。'}
   }
   # Always update the authenticated registry before completing the run. A
   # pre-existing run.ServerInfo is only a snapshot, never a registry substitute.
   $null=Set-TCServerRecord -Root $Root -Id $Run.ServerRecordId -ServerInfo $Data -SessionRef $Run.SessionRef
   $Run.ServerInfo=$Data
   if($operation -ceq 'management_apply' -or $Purpose -ceq 'RecoveryFinalInfo'){
    $outcome=if($operation -ceq 'management_apply' -and (Get-TCDField $Run.RecoveryAttempt NotAppliedEvidence)){'NotApplied'}else{'Applied'}
    Complete-TCDeploymentRecovery $Run $(if($operation -ceq 'transport_apply'){'MaterializeTcp'}else{'ServerInfo'}) -Outcome $outcome;break
   }
   Start-TCDeploymentRemote $Root $Run deployment_state RecoveryUdp @{ClientPublicKey=$Run.ClientResponse.ClientPublicKey;ServerPublicKey=$Run.ClientResponse.ServerPublicKey}
  }
  'RecoveryManagementState'{
   $binding=Get-TCDField $Data ServerBinding;$absent=Get-TCDField $Data FilesAbsent
   if($Run.LastRemoteMutation.Operation -cne 'management_apply' -or (Get-TCDField $Data Kind '') -cne 'TradeChannel.ManagementRecoveryState' -or (Get-TCDField $Data SchemaVersion 0) -ne 1 -or (Get-TCDField $Data Outcome '') -cne 'NotApplied' -or (Get-TCDField $Data ReadOnly) -isnot [bool] -or -not $Data.ReadOnly -or (Get-TCDField $Data PlanExpired) -isnot [bool] -or -not $Data.PlanExpired -or $Data.PlanId -cne $Run.ManagementPlan.PlanId -or $Data.ApprovedChangeDigest -cne $Run.ManagementPlan.ChangeDigest -or (Get-TCDDigest $binding) -cne (Get-TCDDigest $Run.ManagementPlan.ServerBinding) -or [int](Get-TCDField $Data ConfigRevision 0) -ne [int]$Run.ManagementPlan.ConfigRevision -or $null -ne (Get-TCDField $Data PendingOperation '__Missing__') -or (Get-TCDField (Get-TCDField $Data Health) LocalConfiguration '') -cne 'Verified'){throw '[TC:ManagementAbsenceUnverified] 尚未证明原过期管理计划未生效。'}
   foreach($field in @('State','PrivateKey','PublicKey')){if((Get-TCDField $absent $field) -isnot [bool] -or -not $absent.$field){throw '[TC:ManagementInitializationPresent] 存在管理资料或缺少文件检查证据，保留恢复状态。'}}
   if((Get-TCDField $Data ManagementHistoryAbsent) -isnot [bool] -or -not $Data.ManagementHistoryAbsent){throw '[TC:ManagementHistoryUnverified] 尚未排除既有管理初始化记录，不能生成新身份。'}
   if(-not (Get-TCDField $Run.ManagementPlan ExpiresAtUtc '') -or [DateTimeOffset]$Data.PlanExpiresAtUtc -ne [DateTimeOffset]$Run.ManagementPlan.ExpiresAtUtc -or [DateTimeOffset]$Data.ObservedAtUtc -lt [DateTimeOffset]$Data.PlanExpiresAtUtc){throw '[TC:ManagementPlanStillValid] 原计划的失效时间尚未得到服务器核实。'}
   $Run.RecoveryAttempt|Add-Member NoteProperty NotAppliedEvidence $Data -Force
   Start-TCDeploymentRemote $Root $Run deployment_state RecoveryManagementUdp @{ClientPublicKey=$Run.ClientResponse.ClientPublicKey;ServerPublicKey=$Run.ClientResponse.ServerPublicKey}
  }
  {$_ -in @('RecoveryUdp','RecoveryManagementUdp')}{
   $Run.UdpRecheck=$Data;$reply=Get-TCDField (Get-TCDField $Data Udp) ClientResponse
   if($Data.Kind -cne 'TradeChannel.DeploymentState' -or $Data.Status -cne 'Settled' -or $null -ne (Get-TCDField $Data Transaction '__Missing__') -or $Data.NodeId -cne $Run.ClientResponse.NodeId -or $Data.RemoteOwnerId -cne $Run.ServerInfo.RemoteOwnerId -or $Data.ServerPublicKey -cne $Run.ClientResponse.ServerPublicKey -or $Data.ClientPublicKey -cne $Run.ClientResponse.ClientPublicKey -or $Data.Udp.Status -cne 'Healthy' -or $Data.Udp.ClientAddress -cne $Run.ClientResponse.ClientAddress -or -not $reply -or $reply.RequestId -cne $Run.ClientRequest.RequestId -or $reply.DeviceId -cne $Run.ClientRequest.DeviceId -or $reply.ClientPublicKey -cne $Run.ClientRequest.ClientPublicKey -or $reply.ServerPublicKey -cne $Run.ClientResponse.ServerPublicKey -or $reply.NodeId -cne $Run.ClientResponse.NodeId){throw '[TC:UdpRecoveryNotVerified] 原设备、UDP 健康状态或未决事务证据不一致。'}
   $Run.ProtocolPreparation.Udp.ServerPreparation='Configured'
   if($Run.LastRemoteMutation.Operation -ceq 'transport_apply'){
    if(-not (Get-TCDField $Data TcpConfigured $false)){throw '[TC:TcpMutationNotResolved] 原 TCP 变更尚未反映在实际配置中。'}
    Start-TCDeploymentRemote $Root $Run transport_info RecoveryTcp @{ClientPublicKey=$Run.ClientResponse.ClientPublicKey;ServerPublicKey=$Run.ClientResponse.ServerPublicKey}
   }else{Start-TCDeploymentRemote $Root $Run server_info RecoveryFinalInfo @{}}
  }
  'RecoveryTcp'{
   Assert-TCDeploymentTransportBinding $Run $Data
   $transport=Get-TCDField $Data Transport;$expected=$Run.TcpPlan.Transport
   if($Data.Status -cne 'Available' -or -not $transport -or $transport.Type -cne $expected.Type -or [int]$transport.Port -ne [int]$expected.Port -or $transport.ServerName -cne $expected.ServerName -or $transport.Server -cne $Run.ClientResponse.PublicEndpoint.Split(':')[0] -or [string](Get-TCDField $transport Uuid '') -cnotmatch '^[0-9a-f-]{36}$' -or [string](Get-TCDField $transport RealityPublicKey '') -cnotmatch '^[A-Za-z0-9_-]{43}$' -or [string](Get-TCDField $transport RealityShortId '') -cnotmatch '^[a-f0-9]{16}$'){throw '[TC:TcpRecoveryNotVerified] TCP 参数未完整匹配原计划与原设备。'}
   $Run.TcpInfo=$Data;$Run.ProtocolPreparation.Tcp.ServerPreparation='Configured';$Run.ProtocolPreparation.Tcp.Error=$null;$Run.TcpFailure=$null
   Start-TCDeploymentRemote $Root $Run server_info RecoveryFinalInfo @{}
  }
  default{throw '[TC:RecoveryStageInvalid] 未识别只读核对阶段。'}
 }
}
function Stop-TCDeploymentRun {param([string]$Root,$Run)
 $Run.StopTransaction=[pscustomobject]@{State='Prepared';OperationId=$Run.PendingOperationId;DispatchIntent=$Run.DispatchIntent;RequestedAtUtc=[DateTime]::UtcNow.ToString('o');Error=$null}
 $null=Save-TCDeploymentRun $Root $Run
 try{if($Run.SessionRef){$null=Stop-TCDeploySession -SessionRef $Run.SessionRef -Cancel};$Run.StopTransaction.State='StopRequested'}catch{$Run.StopTransaction.State='OutcomeUnknown';$Run.StopTransaction.Error=[pscustomobject]@{Code='StopOutcomeUnknown';Message='停止执行器结果未知，需要读取服务器实际状态。'}}
 if(($Run.DispatchIntent -and $Run.DispatchIntent.Mutating -and $Run.DispatchIntent.State -in @('Prepared','Dispatched')) -or $Run.StopTransaction.State -eq 'OutcomeUnknown'){
  $Run.Status='OutcomeUnknown';$Run.Stage='Reconcile'
  if($Run.LastRemoteMutation -and $Run.LastRemoteMutation.Operation -ceq 'transport_apply'){$Run.UnresolvedTcpMutation=$Run.LastRemoteMutation}
 }else{$Run.Status='Cancelled'}
 $Run.UserActions=@('检查服务器实际结果');return Save-TCDeploymentRun $Root $Run
}
function Import-TCDeploymentProtocolComparison {
 Import-Module (Join-Path $PSScriptRoot 'ProtocolComparison.psm1') -DisableNameChecking -ErrorAction Stop
}
function Invoke-TCDeploymentProtocolComparison {param([string]$Root,$Run)
 Import-TCDeploymentProtocolComparison
 $progressCommand=Get-Command Update-TCDeploymentProbeProgress
 $progress={param($event)& $progressCommand $Root $Run $event}.GetNewClosure()
 Invoke-TCProtocolComparison -Root $Root -NodeId $Run.CandidateNodeId -ExpectedExitIPv4 $Run.ExpectedExitIPv4 -ExpectedExitSource $Run.ExpectedExitSource -CancellationPath $Run.ProbeCancellationPath -InterfaceIndex $Run.ProbeInterfaceIndex -ProgressCallback $progress
}
function Update-TCDeploymentProbeProgress {param([string]$Root,$Run,$Event)
 if($Event.Stage -notin @('PreparingProbePath','CheckingProfiles')){throw '[TC:ProbeProgressInvalid] 检测阶段无效。'}
 $Run.Stage=$Event.Stage;$Run.CheckingProfileId=Get-TCDField $Event ProfileId
 $Run.ProbeProgress=[pscustomobject]@{Stage=$Event.Stage;ProfileId=$Run.CheckingProfileId;Round=(Get-TCDField $Event Round 0);UpdatedAtUtc=[DateTimeOffset]::UtcNow.ToString('o')}
 if(Get-TCDField $Event BindingResult){$Run.ProbeBindingResult=$Event.BindingResult;$Run.ProbePreparation=$Event.BindingResult;$Run.ProbePreparation|Add-Member NoteProperty CompletedAtUtc ([DateTimeOffset]::UtcNow.ToString('o')) -Force}
 $null=Save-TCDeploymentRun $Root $Run
}
function Save-TCDeploymentProbeHistory {param([string]$Root,$Run)
 if(-not $Run.ProbeAttemptId -or $Run.ProfileProbeState -in @('NotStarted','Pending')){return}
 $dir=Join-Path (Get-TCDeploymentRunPath $Root $Run.RunId) 'check-history';$null=New-TCDDirectory $dir
 $file=Join-Path $dir ('check-'+[guid]::NewGuid().ToString('N')+'.json')
 $history=[ordered]@{Kind='TradeChannel.ProbeHistory';RunId=$Run.RunId;LineId=$Run.CandidateNodeId;AttemptId=$Run.ProbeAttemptId;RecordedAtUtc=[DateTimeOffset]::UtcNow.ToString('o');ProbePreparation=$Run.ProbePreparation;Recommendation=$Run.Recommendation;ValidationProfiles=$Run.ValidationProfiles;ProbeError=$Run.ProbeError}
 Write-TCDJson $file $history -Compact
 $Run.ProbeHistory=@(@($Run.ProbeHistory)+@([pscustomobject]@{AttemptId=$Run.ProbeAttemptId;Path=$file;RecordedAtUtc=$history.RecordedAtUtc}))
}
function Request-TCDeploymentProbeStop {
 [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][string]$RunId)
 $run=Get-TCDeploymentRun -Root $Root -RunId $RunId
 if($run.Stage -notin @('PreparingProbePath','CheckingProfiles') -or $run.ProfileProbeState -ne 'Running' -or $run.ProbeAttemptId -cnotmatch '^[a-f0-9]{32}$'){return [pscustomobject]@{Accepted=$false;Code='NoActiveLocalCheck';NetworkChanged=$false}}
 $path=Join-Path (Get-TCDeploymentRunPath $Root $RunId) ('probe-cancel-'+$run.ProbeAttemptId+'.json')
 if(-not [IO.File]::Exists($path)){Write-TCDJson $path ([pscustomobject]@{RunId=$RunId;AttemptId=$run.ProbeAttemptId;RequestedAtUtc=[DateTimeOffset]::UtcNow.ToString('o')})}
 [pscustomobject]@{Accepted=$true;Code='LocalCheckStopRequested';RunId=$RunId;AttemptId=$run.ProbeAttemptId;NetworkChanged=$false}
}
function Test-TCDeploymentProbeStopRequested {param([string]$Root,$Run)
 if(-not $Run.ProbeCancellationPath -or -not [IO.File]::Exists($Run.ProbeCancellationPath)){return $false}
 $marker=Read-TCDJson $Run.ProbeCancellationPath
 [bool]($marker.AttemptId -ceq $Run.ProbeAttemptId -and $marker.RunId -ceq $Run.RunId)
}
function Test-TCDeploymentProfiles {param([string]$Root,$Run)
 Import-TCDeploymentProfiles
 Initialize-TCDeploymentProtocolState $Run
 if($Run.DeploymentCompleteness -eq 'NeedsRecovery'){throw '[TC:NeedsRecovery] 请先核对未完成事务，未启动新的连接检查。'}
 Save-TCDeploymentProbeHistory $Root $Run
 $Run.Stage='PreparingProbePath';$Run.Status='Running';$Run.ProfileProbeState='Running';$Run.ProbeAttemptId=[guid]::NewGuid().ToString('N');$Run.ProbeStartedAt=[DateTimeOffset]::UtcNow.ToString('o');$Run.ProbeError=$null
 $Run.ProbePreparation=[pscustomobject]@{State='Preparing';Code='PreparingProbePath';Results=@();StartedAtUtc=$Run.ProbeStartedAt;CompletedAtUtc=$null}
 $Run.ProbeCancellationPath=Join-Path (Get-TCDeploymentRunPath $Root $Run.RunId) ('probe-cancel-'+$Run.ProbeAttemptId+'.json')
 $Run.RecommendedProfileId=$null;$Run.Recommendation=$null
 $context=Get-TCProtocolNetworkContext;$Run.NetworkContext=$context
 $null=Save-TCDeploymentRun $Root $Run
 $blocked=$null;$cancelled=$false;$profiles=@();$processed=@{}
 try{
 $line=Get-TCLine -Root $Root -Id $Run.CandidateNodeId
 $profiles=@($line.Profiles);$comparison=Invoke-TCDeploymentProtocolComparison $Root $Run
 $Run.ProbeBindingResult=Get-TCDField $comparison BindingResult
 if($Run.ProbeBindingResult){$Run.ProbePreparation=$Run.ProbeBindingResult}
 # Preparation publishes immutable revisions; normalize receipts against the
 # reloaded references and never against the old unbound hash.
 $line=Get-TCLine -Root $Root -Id $Run.CandidateNodeId;$profiles=@($line.Profiles)
 $results=@{};$details=Get-TCDField $comparison Comparison
 foreach($entry in @(Get-TCDField $comparison Results @())){
  $id=[string](Get-TCDField $entry ProfileId '');$result=Get-TCDField $entry Result
  if($id -cnotin @('Udp','Tcp') -or $results.ContainsKey($id) -or -not $result){throw '[TC:ComparisonResultInvalid] 协议对比返回缺失标识、重复方式或空结果。'}
  $results[$id]=$result
  if(-not (Get-TCDField $result CleanupComplete $false)){$blocked='ProbeCleanupFailed';$Run.RecoveryRequired=$true}
  if((Get-TCDField $result Code '') -eq 'ProbeCancelled' -or (Get-TCDField $result CancellationRequested $false)){$cancelled=$true}
 }
 if($details -and -not (Get-TCDField $details CleanupComplete $false)){$blocked='ProbeCleanupFailed';$Run.RecoveryRequired=$true}
 if($blocked -eq 'ProbeCleanupFailed'){$Run.ProbeRecoveryRequired=$true}
 $cancelled=[bool]($cancelled -or (Get-TCDField $comparison Code '') -eq 'ProbeCancelled' -or (Test-TCDeploymentProbeStopRequested $Root $Run))
 foreach($profile in $profiles){
  $profileId=[string]$profile.Id;$Run.CheckingProfileId=$profileId
  $result=if($results.ContainsKey($profileId)){$results[$profileId]}else{[pscustomobject]@{Status='Inconclusive';Code='ComparisonResultMissing';CleanupComplete=$true;CheckedAtUtc=[DateTimeOffset]::UtcNow.ToString('o');CandidateHash=$profile.CandidateSHA256;Comparison=$details}}
  $binding=Get-TCDField (Get-TCDField $result PathEvidence) Binding
  $after=if($binding){Get-TCProtocolNetworkContext -Binding $binding}else{Get-TCProtocolNetworkContext}
  $evidence=ConvertTo-TCProtocolEvidence -Result $result -Profile $profile -NetworkContext $after
  $evidence|Add-Member NoteProperty LineId $Run.CandidateNodeId -Force
  $paired=Get-TCDField $result Comparison $details
  $evidence|Add-Member NoteProperty ComparisonId (Get-TCDField $result ComparisonId (Get-TCDField $paired ComparisonId (Get-TCDField $comparison ComparisonId))) -Force
  $evidence|Add-Member NoteProperty RoundCount (Get-TCDField $result RoundCount (Get-TCDField $paired CompletedPairRounds 0)) -Force
  if($blocked -eq 'ProbeCleanupFailed'){$evidence.Status='Blocked';$evidence.Code=$blocked;$evidence.EligibleForAutomaticSelection=$false}
  elseif($cancelled){$evidence.Status='Inconclusive';$evidence.Code='ProbeCancelled';$evidence.EligibleForAutomaticSelection=$false}
  if(-not $binding -and [string](Get-TCDField $after Fingerprint '') -cne [string](Get-TCDField $context Fingerprint '')){$evidence.Status='Inconclusive';$evidence.Code='NetworkChangedDuringComparison';$evidence.EligibleForAutomaticSelection=$false;$blocked='NetworkChangedDuringComparison'}
  $path=if($evidence.Status -eq 'Passed'){'CurrentEnvironmentPassed'}elseif($evidence.Status -eq 'Failed'){'Failed'}else{'Inconclusive'}
  $evidence|Add-Member NoteProperty PathValidation $path -Force
  $Run.ValidationProfiles.$profileId=$evidence
  $null=Set-TCLineProfileValidation -Root $Root -Id $Run.CandidateNodeId -ProfileId $profileId -Validation $evidence
  $processed[$profileId]=$true
  $null=Save-TCDeploymentRun $Root $Run
 }
 $line=Get-TCLine -Root $Root -Id $Run.CandidateNodeId
 $mode=$Run.Transport
 if($mode -eq 'Auto' -and $line.PreferenceSource -eq 'UserChoice' -and $line.PreferredProfileId){$mode=$line.PreferredProfileId}
 $Run.Recommendation=Get-TCProtocolRecommendation -Profiles @($line.Profiles) -RequestedMode $mode -NetworkContext (Get-TCProtocolNetworkContext) -LineId $Run.CandidateNodeId
 $Run.RecommendedProfileId=$Run.Recommendation.RecommendedProfileId
 $selected=[string]$Run.Recommendation.PreferredProfileId
 if($selected){$Run.Validation=$Run.ValidationProfiles.$selected}
 else{$Run.Validation=[pscustomobject]@{Status=$(if($Run.Recommendation.Status -eq 'Unavailable'){'Failed'}else{'Inconclusive'});Code='NoAutomaticRecommendation';TransportPath='Unknown';Message=$Run.Recommendation.Reason;Profiles=$Run.ValidationProfiles}}
 if(-not $Run.RecoveryRequired){
  $savedLine=Set-TCLineRecommendation -Root $Root -Id $Run.CandidateNodeId -Recommendation $Run.Recommendation -NetworkContext (Get-TCProtocolNetworkContext)
  if(-not $savedLine -or -not (Get-TCDField $savedLine Profiles)){$savedLine=Get-TCLine -Root $Root -Id $Run.CandidateNodeId}
  $Run|Add-Member NoteProperty Profiles @($savedLine.Profiles) -Force
  $Run|Add-Member NoteProperty SavedConnectionPreference (Get-TCDField $savedLine SavedConnectionPreference) -Force
  $Run|Add-Member NoteProperty PreferredProfileId (Get-TCDField $savedLine PreferredProfileId) -Force
  $Run|Add-Member NoteProperty PreferenceSource (Get-TCDField $savedLine PreferenceSource) -Force
 }
 $Run.ProfileProbeState=if($cancelled){'Cancelled'}elseif($Run.Recommendation.Status -eq 'Blocked'){'Blocked'}else{'Completed'};$Run.CheckingProfileId=$null;$Run.ProbeCompletedAt=[DateTimeOffset]::UtcNow.ToString('o')
 Set-TCDeploymentReadyState $Run $cancelled
 }catch{
  $Run.ProfileProbeState='Interrupted';$Run.ProbeError=[pscustomobject]@{Code='ProfileCheckInterrupted';Message='本机检查未完成，服务器和已准备的连接资料保留。请重新检查，无需重复部署。';ExceptionType=$_.Exception.GetType().FullName;SourceLine=$_.InvocationInfo.ScriptLineNumber}
  $Run.RecommendedProfileId=$null;$Run.Recommendation=$null
  # Do not leave a previous successful comparison as the default after an
  # interrupted or malformed reply. Raw receipts already saved stay intact.
  foreach($profile in $profiles){
   if($processed.ContainsKey([string]$profile.Id)){$evidence=$Run.ValidationProfiles.($profile.Id)}
   else{
    $result=[pscustomobject]@{Status='Inconclusive';Code='ProfileCheckInterrupted';CleanupComplete=$true;CheckedAtUtc=[DateTimeOffset]::UtcNow.ToString('o');CandidateHash=$profile.CandidateSHA256}
    $evidence=ConvertTo-TCProtocolEvidence -Result $result -Profile $profile -NetworkContext $context
   }
   $evidence.Status=if($Run.RecoveryRequired){'Blocked'}else{'Inconclusive'};$evidence.Code=if($Run.RecoveryRequired){'ProbeCleanupFailed'}else{'ProfileCheckInterrupted'};$evidence.EligibleForAutomaticSelection=$false
   $evidence|Add-Member NoteProperty PathValidation 'Inconclusive' -Force;$Run.ValidationProfiles.($profile.Id)=$evidence
   $null=Set-TCLineProfileValidation -Root $Root -Id $Run.CandidateNodeId -ProfileId $profile.Id -Validation $evidence
  }
  Set-TCDeploymentReadyState $Run
  $Run.LastError=$Run.ProbeError
 }finally{$null=Save-TCDeploymentRun $Root $Run}
}
function Get-TCDeploymentRunPath {param([string]$Root,[string]$RunId) return Join-Path (Join-Path (Get-TCDPath $Root deployments) 'runs') (Assert-TCDId $RunId)}
function Complete-TCDeploymentAutomaticChecks {param([string]$Root,$Run)
 if($Run.Stage -eq 'ReadyInactive' -and $Run.ProfileProbeState -eq 'Pending' -and -not $Run.RecoveryRequired -and -not (Get-TCDField $Run PendingPurpose)){
  if($Run.ExistingDevice -and $Run.CandidateNodeId){
   Import-TCDeploymentProfiles
   $cards=@(Get-TCLineCards -Root $Root|Where-Object LineId -eq $Run.CandidateNodeId)
   if($cards.Count -eq 1 -and (Get-TCDField $cards[0] CurrentProfileId)){
    $line=Get-TCLine -Root $Root -Id $Run.CandidateNodeId
    $Run|Add-Member NoteProperty Profiles @($line.Profiles) -Force;$Run|Add-Member NoteProperty SavedConnectionPreference (Get-TCDField $line SavedConnectionPreference) -Force
    $Run.Recommendation=Get-TCDField $line Recommendation;$Run.ProfileProbeState='NotCheckedActive'
    $Run.Validation=[pscustomobject]@{Status='NotTested';Code='ActiveIdentityPreserved';Message='当前身份正在使用，未并行检测；已准备配置保留，明确切换时验收。'}
    return
   }
  }
  Test-TCDeploymentProfiles $Root $Run
 }
}
function Get-TCDeploymentRun {param([string]$Root,[string]$RunId)
 $run=Read-TCDJson (Join-Path (Get-TCDeploymentRunPath $Root $RunId) 'state.json')
 if($run.SchemaVersion -ne 1 -or $run.RunId -cne (Assert-TCDId $RunId)){throw '[TC:RunMismatch] 部署运行记录不匹配。'}
 foreach($item in @(@{Name='DispatchIntent';Value=$null},@{Name='LastRemoteMutation';Value=$null},@{Name='CandidateTransaction';Value=$null},@{Name='ProviderWarnings';Value=@()},@{Name='RequiredProviderIds';Value=@()},@{Name='AddressSelectionEvidence';Value=$null})){
  if(-not $run.PSObject.Properties[$item.Name]){$run|Add-Member NoteProperty $item.Name $item.Value}
 }
 Initialize-TCDeploymentProtocolState $run
 return $run
}
function Save-TCDeploymentRun {param([string]$Root,$Run)
 Initialize-TCDeploymentProtocolState $Run
 foreach($field in @(@{Name='ExperienceVersion';Value=0},@{Name='AccessIssue';Value=$null},@{Name='AttemptSessionRef';Value=$null},@{Name='AutoSavedAtUtc';Value=$null},@{Name='AttentionRequired';Value=$false})){
  if(-not $Run.PSObject.Properties[$field.Name]){$Run|Add-Member NoteProperty $field.Name $field.Value}
 }
 # Persisting preparation is independent of activating a line. Do not mark
 # partial, live, or unresolved work complete just because files exist.
 if($Run.ExperienceVersion -ge 1 -and $Run.Stage -eq 'ReadyInactive' -and $Run.DeploymentCompleteness -eq 'Complete' -and -not $Run.PendingPurpose -and -not $Run.RecoveryRequired -and -not $Run.ProbeRecoveryRequired -and $Run.ProfileProbeState -notin @('Pending','Running')){
  $Run.AutoSavedAtUtc=[DateTimeOffset]::UtcNow.ToString('o');$Run.Status='Complete'
  $Run.AttentionRequired=([string](Get-TCDField $Run.Recommendation Status '') -notin @('Recommended','UserChoice'))
 }elseif($Run.Stage -eq 'ReadyInactive'){$Run.AttentionRequired=($Run.DeploymentCompleteness -ne 'Complete' -or $Run.RecoveryRequired)}
 $Run.Revision=[int]$Run.Revision+1;$Run.UpdatedAtUtc=[DateTime]::UtcNow.ToString('o')
 Write-TCDJson (Join-Path (Get-TCDeploymentRunPath $Root $Run.RunId) 'state.json') $Run -Compact
 return $Run
}
function Get-TCDeploymentRuns {param([string]$Root)
 $base=Join-Path (Get-TCDPath $Root deployments) 'runs';if(-not [IO.Directory]::Exists($base)){return @()}
 return @(Get-ChildItem -LiteralPath $base -Directory|Sort-Object LastWriteTimeUtc -Descending|Select-Object -First 2000|ForEach-Object {try{Get-TCDeploymentRun $Root $_.Name}catch{}}|Sort-Object UpdatedAtUtc -Descending|Select-Object -First 200)
}
function Get-TCDeploymentDiscovery {param([string]$Root)
 $runs=@(Get-TCDeploymentRuns $Root);$servers=@(Get-TCServers $Root);$legacy=Join-Path (Assert-TCDPath $Root) 'linux-jobs'
 $runs=@($runs|Where-Object {-not (Test-TCDraftDiscarded -Root $Root -Id ('DeploymentRun:'+$_.RunId))})
 $servers=@($servers|Where-Object {-not (Test-TCDraftDiscarded -Root $Root -Id ('ServerRecord:'+$_.LocalRecordId))})
 $archived=@($servers|Where-Object {(Get-TCDField $_ RecordState 'Active') -ceq 'Archived'}|ForEach-Object {$_.LocalRecordId})
 [pscustomobject]@{Servers=$servers;Runs=$runs;ContinueRuns=@($runs|Where-Object {$_.Status -notin @('Complete','Cancelled') -and $_.ServerRecordId -notin $archived});HasLegacyRecords=[IO.Directory]::Exists($legacy);NetworkChanged=$false}
}
function ConvertTo-TCDeploymentConnection {param([string]$Text,[string]$User='root',[int]$Port=22,[string]$IdentityFile='')
 $value=$Text.Trim()
 if($value -match '[;&|<>$]' -or $value.Contains([char]96) -or $value -match '[\r\n]'){throw '[TC:ConnectionInvalid] 只粘贴接入地址，不接受执行命令。'}
 if($value -match '^ssh\s+(?<user>[a-z_][a-z0-9_-]{0,31})@(?<host>(?:\d{1,3}\.){3}\d{1,3})(?:\s+-p\s+(?<port>\d{1,5}))?$'){$User=$Matches.user;$value=$Matches.host;if($Matches.port){$Port=[int]$Matches.port}}
 elseif($value -match '^(?<user>[a-z_][a-z0-9_-]{0,31})@(?<host>(?:\d{1,3}\.){3}\d{1,3})$'){$User=$Matches.user;$value=$Matches.host}
 $ip=$null;if($value -cnotmatch '^(?:0|[1-9][0-9]{0,2})(?:\.(?:0|[1-9][0-9]{0,2})){3}$' -or -not [Net.IPAddress]::TryParse($value,[ref]$ip) -or $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or $Port -lt 1 -or $Port -gt 65535 -or $User -cnotmatch '^[a-z_][a-z0-9_-]{0,31}$'){throw '[TC:ConnectionInvalid] 请填写完整公网 IPv4、SSH 用户名和端口。'}
 return [pscustomobject]@{Host=$ip.ToString();Port=$Port;User=$User;IdentityFile=$IdentityFile}
}
function New-TCDeploymentRun {
 [CmdletBinding()]param([string]$Root,[ValidateSet('Auto','New','Add','Existing')][string]$Intent='New',[string]$ServerId,$Connection,[string]$Name='新的服务器线路',[string]$TemplateNodeId,[string]$Transport='Auto',[int]$TcpPort=443,[string]$ServerName='www.bing.com',[int]$VpnPort=51820,$ClientInspection,[string]$ExistingNodeId,[string]$ReuseSourceRunId,$IdentitySessionRef,[string]$IdentityTargetToken)
 foreach($component in @('EngineStaged','WgHelperStaged')){if((Get-TCDField $ClientInspection $component $true) -eq $false){throw '[TC:LocalComponentsMissing] 本机运行组件缺失，请完整解压安装包后重新检查；没有开始服务器部署。'}}
 $automatic=($Intent -eq 'Auto')
 if($automatic){$Intent=if(Get-TCDField $ClientInspection ExistingDeployment $false){'Add'}else{'New'}}
 if($Transport -notin @('Auto','Udp','Tcp') -or $VpnPort -lt 1 -or $VpnPort -gt 65535 -or $TcpPort -lt 1 -or $TcpPort -gt 65535){throw '[TC:SettingsInvalid] 连接参数无效。'}
 if($ServerName -cnotmatch '^(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$'){throw '[TC:SettingsInvalid] TLS 域名无效。'}
 if($ServerId){$server=Get-TCServer $Root $ServerId}else{$server=Set-TCServerRecord -Root $Root -Connection $Connection -Name $Name}
 if(-not $server.Connection){throw '[TC:AccessRequired] 此记录只有连接使用权；请使用邀请接入，或提供管理资料。'}
 $creationLease=Open-TCServerTaskLease -Root $Root -ServerId $server.LocalRecordId
 try{
 if($automatic -and $server.ServerPublicKey -and @($server.LinkedNodeIds).Count){
  Import-Module (Join-Path $PSScriptRoot 'NodeStore.psm1') -DisableNameChecking
  $usable=@(foreach($n in @(Get-TCNodes -Root (Join-Path $Root 'Product'))){
   if($n.id -notin @($server.LinkedNodeIds) -or -not $n.manifestPath){continue}
   try{$m=Read-TCDJson $n.manifestPath;if($m.ServerPublicKey -ceq $server.ServerPublicKey -and $m.ClientPublicKey -and $m.SyntaxValidated -and [IO.File]::Exists($m.CandidatePath) -and (Get-FileHash -LiteralPath $m.CandidatePath -Algorithm SHA256).Hash -ceq $m.CandidateSHA256){$n}}catch{}
  })
  $preferences=Read-TCDJson (Join-Path $Root 'ui-preferences.json') -AllowMissing
  $chosen=@($usable|Where-Object id -eq (Get-TCDField $preferences NodeId ''))
  if(-not $chosen.Count -and $usable.Count -eq 1){$chosen=@($usable[0])}
  if($chosen.Count -eq 1){$Intent='Existing';$ExistingNodeId=$chosen[0].id}
  elseif($usable.Count -gt 1){throw '[TC:ExistingSelectionRequired] 这台电脑已有多份该服务器的授权，请从线路页选择已有线路；未生成额外设备。'}
 }
 $id=[guid]::NewGuid().ToString('D');$dir=Get-TCDeploymentRunPath $Root $id;$null=New-TCDDirectory $dir
 $programs=@(Get-TCDField $ClientInspection NinjaTraderPaths @());$dns=@(Get-TCDField $ClientInspection DirectDnsIPv4 @())|Select-Object -First 1
 $run=[pscustomobject][ordered]@{SchemaVersion=1;RunId=$id;Revision=0;Intent=$Intent;ServerRecordId=$server.LocalRecordId;Name=$Name;TemplateNodeId=$TemplateNodeId;Transport=$Transport;TcpPort=$TcpPort;ServerName=$ServerName;VpnPort=$VpnPort;TunnelSubnet=$null;Programs=$programs;DirectDns=$dns;Stage='PrepareAccess';Status='WaitingUser';SessionRef=$null;PendingOperationId=$null;PendingPurpose=$null;ClientRequest=$null;RequestDirectory=$null;Plan=$null;ManagementPlan=$null;Review=$null;ApprovedChangeDigest=$null;AllowManagementInitialize=$false;AllowDeviceAuthorize=$false;ClientResponse=$null;ServerInfo=$null;CandidateNodeId=$null;CandidateManifestPath=$null;ExpectedExitIPv4=$null;ExpectedExitSource=$null;Validation=$null;LastError=$null;UserActions=@('连接并检查');CreatedAtUtc=[DateTime]::UtcNow.ToString('o');UpdatedAtUtc=[DateTime]::UtcNow.ToString('o');NetworkChanged=$false}
 foreach($item in @(@{Name='DispatchIntent';Value=$null},@{Name='LastRemoteMutation';Value=$null},@{Name='CandidateTransaction';Value=$null},@{Name='ProviderWarnings';Value=@()},@{Name='RequiredProviderIds';Value=@()},@{Name='AddressSelectionEvidence';Value=$null})){$run|Add-Member NoteProperty $item.Name $item.Value}
 Initialize-TCDeploymentProtocolState $run
 $run|Add-Member NoteProperty ExperienceVersion 1 -Force
 $run|Add-Member NoteProperty AccessIssue $null -Force
 $run|Add-Member NoteProperty AttemptSessionRef $null -Force
 if($ReuseSourceRunId -and $Intent -ne 'Existing'){
  $reuse=Get-TCServerSameApplicationRequest -Root $Root -ServerId $server.LocalRecordId -SourceRunId $ReuseSourceRunId -SessionRef $IdentitySessionRef -TargetToken $IdentityTargetToken
  if($reuse.CanReuse){
   $run.ClientRequest=$reuse.ClientRequest;$run.RequestDirectory=$reuse.RequestDirectory
   $run|Add-Member NoteProperty ReusedRequestSourceRunId $ReuseSourceRunId -Force
  }
 }
 if($Intent -eq 'Existing'){
  if(-not $ExistingNodeId){$ExistingNodeId=$TemplateNodeId};if(-not $ExistingNodeId){throw '[TC:ExistingIdentityRequired] 补齐需指定原线路，不生成新设备。'}
  Import-Module (Join-Path $PSScriptRoot 'NodeStore.psm1') -DisableNameChecking
  $existing=@(Get-TCNodes -Root (Join-Path $Root 'Product')|Where-Object {$_.id -ceq $ExistingNodeId})
  if($existing.Count -ne 1 -or $ExistingNodeId -notin @($server.LinkedNodeIds)){throw '[TC:ExistingIdentityMismatch] 原线路与服务器记录未绑定。'}
  $manifest=Read-TCDJson $existing[0].manifestPath
  if($manifest.ServerPublicKey -cne $server.ServerPublicKey){throw '[TC:ExistingIdentityMismatch] 原线路的服务器公钥不匹配。'}
  $run.ExistingDevice=$true;$run.CandidateNodeId=$ExistingNodeId;$run.CandidateManifestPath=$existing[0].manifestPath
  $run.ClientRequest=[pscustomobject]@{ClientPublicKey=$manifest.ClientPublicKey}
 }
 Update-TCDeploymentCloudRules $Root $run
 return Save-TCDeploymentRun $Root $run
 }finally{$creationLease.Dispose()}
}
function Set-TCDeploymentSession {param([string]$Root,[string]$RunId,$SessionRef)
 $server=Assert-TCServerTaskActive -Root $Root -RunId $RunId
 $lease=Open-TCServerTaskLease -Root $Root -ServerId $server.LocalRecordId
 try{
 Assert-TCDraftActive -Root $Root -Id ('DeploymentRun:'+$RunId)
 if([string](Get-TCDField $SessionRef RunId '') -cne $RunId){throw '[TC:SessionMismatch] 会话属于另一项部署。'}
 $run=Get-TCDeploymentRun $Root $RunId;$run.SessionRef=$SessionRef;$run.LastError=$null
 $run|Add-Member NoteProperty AccessIssue $null -Force;$run|Add-Member NoteProperty AttemptSessionRef $SessionRef -Force
 if($run.Status -in @('OutcomeUnknown','NeedsRecovery') -or $run.RecoveryRequired -or ($run.DispatchIntent -and $run.DispatchIntent.Mutating -and $run.DispatchIntent.State -in @('Prepared','Dispatched'))){$run.Stage='Reconcile';$run.RecoveryRequired=$true}
 elseif($run.TcpInfo -and $run.ProtocolPreparation.Tcp.LocalPreparation -ne 'SyntaxValidated'){$run.Stage='MaterializeTcp'}
 elseif($run.CandidateNodeId -and $run.ProtocolPreparation.Tcp.ServerPreparation -eq 'Inspecting'){$run.Stage='InspectTcp'}
 elseif($run.Stage -eq 'ReadyInactive'){return Save-TCDeploymentRun $Root $run}
 elseif($run.CandidateTransaction -and $run.CandidateTransaction.State -ne 'Completed'){$run.Stage='MaterializeCandidate'}
 elseif($run.ClientResponse){$run.Stage='ServerInfo'}
 elseif($run.Stage -ne 'PlanReady'){$run.Stage='Inspect'}
 if($run.Stage -ne 'Reconcile'){$run.PendingOperationId=$null;$run.PendingPurpose=$null}
 $run.Status='Idle';return Save-TCDeploymentRun $Root $run
 }finally{$lease.Dispose()}
}
function Set-TCDeploymentAccessState {
 [CmdletBinding()]param([string]$Root,[string]$RunId,[Parameter(Mandatory=$true)]$SessionRef,[switch]$AttemptOnly)
 $server=Assert-TCServerTaskActive -Root $Root -RunId $RunId
 $lease=Open-TCServerTaskLease -Root $Root -ServerId $server.LocalRecordId;$lock=$null
 try{
  Assert-TCDraftActive -Root $Root -Id ('DeploymentRun:'+$RunId)
  $run=Get-TCDeploymentRun $Root $RunId;$lock=Open-TCDLock (Join-Path (Get-TCDeploymentRunPath $Root $RunId) '.run.lock')
  $run=Get-TCDeploymentRun $Root $RunId
  if([string](Get-TCDField $SessionRef RunId '') -cne $RunId){throw '[TC:SessionBindingMismatch] 登录会话不属于这次准备。'}
  $poll=Get-TCDeploySession -SessionRef $SessionRef
  if($AttemptOnly){$run|Add-Member NoteProperty AttemptSessionRef $SessionRef -Force;$run|Add-Member NoteProperty AccessIssue $null -Force;return Save-TCDeploymentRun $Root $run}
  $attempt=Get-TCDField $run AttemptSessionRef $run.SessionRef
  if(-not $attempt -or (Get-TCDDigest $attempt) -cne (Get-TCDDigest $SessionRef)){throw '[TC:SessionBindingMismatch] 原登录会话已变化，未写入过期结果。'}
  $diagnostic=Get-TCDeployAccessDiagnostic -Code ([string](Get-TCDField $poll Code 'AccessStateUnknown'))
  $code=$diagnostic.Code
  if($poll.HasSession){$run|Add-Member NoteProperty AccessIssue $null -Force;return Save-TCDeploymentRun $Root $run}
  $kind=$diagnostic.Kind
  $issue=[pscustomobject]@{SchemaVersion=1;Kind=$kind;Code=$code;ResumeStage=$run.Stage;ServerRecordId=$run.ServerRecordId;SessionDigest=(Get-TCDDigest $SessionRef);ObservedFingerprint=[string](Get-TCDField $poll ObservedFingerprint '');HostKeyAlgorithm=[string](Get-TCDField $poll HostKeyAlgorithm '');RecordedAtUtc=[DateTimeOffset]::UtcNow.ToString('o')}
  $run|Add-Member NoteProperty AccessIssue $issue -Force
  if($poll.Status -eq 'OutcomeUnknown'){$run.Status='OutcomeUnknown';$run.RecoveryRequired=$true;$run.Stage='Reconcile'}
  elseif($run.Status -notin @('OutcomeUnknown','NeedsRecovery','Running','Dispatching')){$run.Status='WaitingUser'}
  $run.LastError=[pscustomobject]@{Code=$code;Message='服务器接入需要处理，准备进度和当前线路保持。'};$run.UserActions=@('在当前步骤处理接入','稍后继续')
  return Save-TCDeploymentRun $Root $run
 }finally{if($lock){$lock.Dispose()};$lease.Dispose()}
}
function Initialize-TCDeploymentRequest {param([string]$Root,$Run)
 if($Run.ExistingDevice){return}
 if($Run.ClientRequest){
  $state=Read-TCDJson (Join-Path $Run.RequestDirectory 'public.request.json')
  if((Get-TCDDigest $state) -cne (Get-TCDDigest $Run.ClientRequest) -or -not [IO.File]::Exists((Join-Path $Run.RequestDirectory 'client.key'))){throw '[TC:PrivateKeyMissing] 原申请或私钥缺失，请通过新身份申请处理，未重复授权。'}
  return
 }
 $client=Join-Path (Get-TCDeploymentRunPath $Root $Run.RunId) 'client'
 Import-Module (Join-Path $PSScriptRoot 'ServerSetup.psm1') -DisableNameChecking
 if([IO.Directory]::Exists($client) -and @(Get-ChildItem -LiteralPath $client -Force).Count){
  foreach($leaf in @('public.request.json','client.state.json','client.key')){if(-not [IO.File]::Exists((Join-Path $client $leaf))){throw '[TC:LocalRequestIncomplete] 本机申请创建曾中断，唯一私钥仍保留；请处理原申请资料，未生成新设备。'}}
  $savedRequest=Read-TCDJson (Join-Path $client 'public.request.json');$savedState=Read-TCDJson (Join-Path $client 'client.state.json');$keyPath=Assert-TCDPath (Join-Path $client 'client.key')
  if((Get-Item -LiteralPath $keyPath).Length -gt 256){throw '[TC:PrivateKeyMissing] 原申请私钥资料超限。'}
  $keyText=[IO.File]::ReadAllText($keyPath).Trim();$serverModule=Get-Module ServerSetup;$keyHash=& $serverModule {param($Key) Assert-TCKey $Key;Get-TCHash $Key} $keyText;$keyText=$null
  if($savedRequest.Kind -cne 'TradeChannel.ClientRequest' -or $savedState.Kind -cne 'TradeChannel.ClientPrivateState' -or $savedRequest.RequestId -cne $savedState.RequestId -or $savedRequest.DeviceId -cne $savedState.DeviceId -or $savedRequest.ClientPublicKey -cne $savedState.ClientPublicKey -or $keyHash -cne $savedState.PrivateKeyHash){throw '[TC:PrivateKeyMissing] 原申请与私钥记录不匹配，请处理原身份。'}
 }else{$null=New-TCClientRequest -OutputDirectory $client -WgPath (Join-Path $PSScriptRoot 'assets\wg.exe')}
 $Run.ClientRequest=Read-TCDJson (Join-Path $client 'public.request.json');$Run.RequestDirectory=$client
}
function Start-TCDeploymentRemote {param([string]$Root,$Run,[string]$Operation,[string]$Purpose,$InputData=@{})
 if((Get-TCDField $Run.RecoveryVerification Status '') -ceq 'Checking' -and ($Operation -notin @('status','server_info','request_status','deployment_state','transport_info','management_recovery_state') -or ($Operation -eq 'status' -and (Get-TCDField $InputData NetworkProbe $false)) -or ($Operation -eq 'request_status' -and (Get-TCDField $InputData RefreshAuthorization $false)))){throw '[TC:RecoveryReadOnly] 核对期间不能发起新变更或网络探针。'}
 if(-not $Run.SessionRef){throw '[TC:AuthenticationRequired] 请在程序内登录服务器。'}
 $pausePath=Join-Path (Get-TCDeploymentRunPath $Root $Run.RunId) 'pause-at-checkpoint.json'
 $pause=Read-TCDJson $pausePath -AllowMissing
 if($pause -and $pause.RunId -ceq $Run.RunId -and $pause.InstanceId -ceq $Run.SessionRef.InstanceId -and (Get-TCDField $Run.RecoveryVerification Status '') -cne 'Checking'){
  $server=Get-TCServer $Root $Run.ServerRecordId
  $binding=Get-TCDDigest @{ServerId=$server.LocalRecordId;Connection=$server.Connection;Key=$server.ServerPublicKey;HostKey=$server.PinnedHostKey}
  $Run|Add-Member NoteProperty PausedContinuation ([pscustomobject]@{Operation=$Operation;Purpose=$Purpose;InputData=$InputData;ServerBinding=$binding}) -Force
  $Run.Status='WaitingUser';$Run.Stage=$Purpose;$Run.PendingOperationId=$null;$Run.PendingPurpose=$null;$Run.UserActions=@('继续原步骤','稍后继续')
  $null=Save-TCDeploymentRun $Root $Run;return
 }
 $mutating=$Operation -in @('apply','authorize','recover','finalize','management_apply','device_rename','invite_create','invite_cancel','authorize_external','revoke','uninstall','transport_apply') -or ($Operation -eq 'request_status' -and (Get-TCDField $InputData RefreshAuthorization $false))
 $intent=[pscustomobject]@{IntentId=[guid]::NewGuid().ToString();Operation=$Operation;Purpose=$Purpose;InputDigest=(Get-TCDDigest $InputData);State='Prepared';Mutating=$mutating;CreatedAtUtc=[DateTime]::UtcNow.ToString('o')}
 $Run.DispatchIntent=$intent;$Run.PendingOperationId=$intent.IntentId;$Run.PendingPurpose=$Purpose;$Run.Status='Dispatching';$Run.Stage=$Purpose;$Run.LastError=$null;$Run.UserActions=@()
 if($mutating){$Run.LastRemoteMutation=$intent;$Run.RecoveryVerification=$null;$Run.RecoveryAttempt=$null}
 # Publish durable intent before anything can execute remotely. The same operation ID is sent over the pipe.
 $null=Save-TCDeploymentRun $Root $Run
 try{$response=Invoke-TCDeployOperation -SessionRef $Run.SessionRef -Operation $Operation -Input $InputData -OperationId $intent.IntentId}catch{
  $Run.Status=if($mutating){'OutcomeUnknown'}else{'Failed'};$Run.LastError=[pscustomobject]@{Code='DispatchOutcomeUnknown';Message='执行器未返回接收结果，请查询原操作，不自动重新提交。'};$Run.UserActions=@('重新登录并检查原操作');$null=Save-TCDeploymentRun $Root $Run;throw '[TC:DispatchOutcomeUnknown] 请查询原操作结果后继续。'
 }
 if(-not (Get-TCDField $response Ok $false)){$intent.State='Rejected';$Run.Status='Failed';$Run.LastError=[pscustomobject]@{Code=[string](Get-TCDField $response Code 'RemoteRejected');Message='执行器未接受此操作，请保留原申请并处理提示。'};$null=Save-TCDeploymentRun $Root $Run;throw '[TC:RemoteRejected] 远程操作未接受。'}
 if([string](Get-TCDField $response OperationId '') -cne $intent.IntentId){$Run.Status=if($mutating){'OutcomeUnknown'}else{'Failed'};$null=Save-TCDeploymentRun $Root $Run;throw '[TC:OperationMismatch] 执行器未返回原操作标识。'}
 $intent.State='Dispatched';$Run.Status='Running'
}
function Set-TCDeploymentReview {param([string]$Root,$Run,[string]$Kind,$Plan,[string]$Title,[string]$Details)
 $server=Get-TCServer $Root $Run.ServerRecordId;$access=$null;if($server.Connection){$access=@{Host=$server.Connection.Host;Port=$server.Connection.Port;User=$server.Connection.User}}
 $identity=@{RemoteOwnerId=$server.RemoteOwnerId;NodeId=$server.NodeId;ServerPublicKey=$server.ServerPublicKey;PinnedHostKey=$server.PinnedHostKey;Connection=$access}
 $review=[ordered]@{Kind=$Kind;ServerRecordId=$Run.ServerRecordId;TargetIdentity=$identity;ServerBinding=$Run.ServerInfo;Plan=$Plan;ClientPublicKey=(Get-TCDField $Run.ClientRequest ClientPublicKey);Title=$Title;Details=$Details;IncludesManagementInitialize=$true;IncludesLocalDeviceAuthorize=$true;ChangesLocalNetwork=$false}
 $review.IncludesLocalDeviceAuthorize=(-not $Run.ExistingDevice)
 $names=if($Run.ServerName -ceq 'www.bing.com'){@('www.bing.com','www.microsoft.com')}else{@($Run.ServerName)}
 # Keep the existing review field for stored digests/UI compatibility. All
 # standard modes prepare both protocols; Transport only selects preference.
 $review.InitialTransportPreference=$Run.Transport;$review.DualPreparationRequired=$Run.DualPreparationRequired
 $review.OptionalTcpPreparation=@{CandidatePorts=@(443,8443,2443);ServerName=$Run.ServerName;CandidateServerNames=@($names);HandshakeBudgetSeconds=8;HandshakeValidationLayer='TlsEndpointReachable';PreserveExistingTransport=$true;FailurePolicy='RecheckUdpBeforePartialDeployment'}
 $review.ChangeDigest=Get-TCDDigest $review;$Run.Review=[pscustomobject]$review;$Run.Stage='PlanReady';$Run.Status='WaitingUser';$Run.UserActions=@('核对变更并开始','稍后继续')
}
function ConvertTo-TCDeploymentRange {param([string]$Cidr)
 if($Cidr -cnotmatch '^([0-9]{1,3}(?:\.[0-9]{1,3}){3})/(\d{1,2})$'){return $null};$ip=$null;$prefix=[int]$Matches[2]
 if($prefix -lt 1 -or $prefix -gt 32 -or -not [Net.IPAddress]::TryParse($Matches[1],[ref]$ip) -or $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork){return $null}
 $parts=$ip.GetAddressBytes();if($parts[0] -eq 127 -or ($parts[0] -eq 169 -and $parts[1] -eq 254) -or $parts[0] -ge 224){return $null}
 [uint64]$number=0;foreach($part in $parts){$number=$number*256+$part};[uint64]$size=[math]::Pow(2,32-$prefix);[uint64]$start=$number-($number%$size)
 [pscustomobject]@{Start=$start;End=$start+$size-1;Cidr=$Cidr}
}
function Get-TCDeploymentLocalNetworks {
 # Read-only. A failed query cannot be treated as proof that no local network exists.
 $ranges=@();try{
  foreach($route in @(Get-NetRoute -AddressFamily IPv4 -ErrorAction Stop)){$cidr=[string]$route.DestinationPrefix;if($cidr -ne '0.0.0.0/0'){$ranges+=$cidr}}
  foreach($address in @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop)){$ranges+=([string]$address.IPAddress+'/'+[string]$address.PrefixLength)}
 }catch{throw '[TC:LocalNetworkUnknown] 无法读取本机现有网段，请先处理系统查询权限；未猜测可用网段。'}
 return @($ranges|Select-Object -Unique)
}
function Select-TCDeploymentSubnet {param([string]$Root,$Run,$Inspection)
 $excluded=@(Get-TCDeploymentLocalNetworks)+@(Get-TCDField $Inspection ConflictNetworks @())
 Import-Module (Join-Path $PSScriptRoot 'NodeStore.psm1') -DisableNameChecking
 foreach($node in @(Get-TCNodes -Root (Join-Path $Root 'Product'))){if($node.manifestPath){
  $m=Read-TCDJson $node.manifestPath
  foreach($field in @('TunnelSubnet','ServerAddress')){$sub=[string](Get-TCDField $m $field '');if($sub){$excluded+=$sub}}
  $client=[string](Get-TCDField $m ClientAddress '');if($client){$excluded+=($client+$(if($client.Contains('/')){''}else{'/32'}))}
 }}
 $ranges=@($excluded|Select-Object -Unique|ForEach-Object {ConvertTo-TCDeploymentRange ([string]$_)}|Where-Object {$null -ne $_})
 $candidates=@(foreach($index in 78..240){'10.'+$index+'.0.0/24'})+@(foreach($index in 20..29){foreach($part in 0..15){'172.'+$index+'.'+$part+'.0/24'}})
 foreach($candidate in $candidates){$range=ConvertTo-TCDeploymentRange $candidate;$overlap=@($ranges|Where-Object {$range.Start -le $_.End -and $_.Start -le $range.End});if(-not $overlap.Count){
  $Run.AddressSelectionEvidence=[pscustomobject]@{Selected=$candidate;CheckedAtUtc=[DateTime]::UtcNow.ToString('o');ExcludedNetworks=@($ranges|ForEach-Object {$_.Cidr});DefaultRouteExcluded=$true;NetworkChanged=$false};return $candidate
 }}
 throw '[TC:AddressConflict] 没有已知无冲突网段，请在高级设置检查现有地址。'
}
function Complete-TCDeploymentCandidate {param([string]$Root,$Run,[switch]$UseExistingConfig,[string]$SourceConfigPath)
 if(-not $Run.ClientResponse){throw '[TC:AuthorizationMissing] 尚未取得本机授权。'}
 if(-not $UseExistingConfig){Initialize-TCDeploymentRequest $Root $Run}
 $dir=Get-TCDeploymentRunPath $Root $Run.RunId;$responsePath=Join-Path $dir 'client-response.json';Write-TCDJson $responsePath $Run.ClientResponse
 $destination=if($UseExistingConfig){Assert-TCDPath $SourceConfigPath}else{Join-Path $dir 'client.conf'}
 if($UseExistingConfig -and -not [IO.File]::Exists($destination)){throw '[TC:ConfigMissing] 接收端授权合成资料缺失，未重新申请。'}
 Import-Module (Join-Path $PSScriptRoot 'ServerSetup.psm1') -DisableNameChecking
 if(-not $UseExistingConfig -and -not [IO.File]::Exists($destination)){$null=Complete-TCClientConfig -RequestDirectory $Run.RequestDirectory -ResponsePath $responsePath -Destination $destination}
 Import-Module (Join-Path $PSScriptRoot 'NodeStore.psm1') -DisableNameChecking
 $programs=@($Run.Programs|Where-Object {[IO.File]::Exists([string]$_)});$providers=@();$warnings=@();$sourceProviders=$null
 foreach($path in @($Run.Programs)){if(-not [IO.File]::Exists([string]$path)){$warnings+='程序路径暂不可用，已跳过：'+[string]$path}}
 if([string]::IsNullOrWhiteSpace([string]$Run.DirectDns)){$Run.DirectDns='1.1.1.1'}
 if($Run.TemplateNodeId){
  $source=@(Get-TCNodes -Root (Join-Path $Root 'Product')|Where-Object {$_.id -eq $Run.TemplateNodeId})|Select-Object -First 1
  if($source -and $source.manifestPath){
   $manifest=Read-TCDJson $source.manifestPath
   $originalPrograms=@(Get-TCDField $manifest TradeProgramPaths $programs);$programs=@($originalPrograms|Where-Object {[IO.File]::Exists([string]$_)})
   foreach($path in $originalPrograms){if(-not [IO.File]::Exists([string]$path)){$warnings+='模板程序已不存在，已跳过：'+[string]$path}}
   if(Get-TCDField $manifest DirectDns){$Run.DirectDns=[string]$manifest.DirectDns}
   $sourceProviders=@(Get-TCDField $manifest Providers @()|ForEach-Object {[string](Get-TCDField $_ Id '')}|Where-Object {$_})
  }else{throw '[TC:TemplateMissing] 选择的来源线路已不存在，未改用其他线路设置。'}
 }
 Import-Module (Join-Path $PSScriptRoot 'ProviderBridge.psm1') -DisableNameChecking
 # A malformed provider store is a real error; only explicitly unavailable profiles may be skipped.
 $selection=Select-TCImportProviders -Root $Root -Programs $programs -SkipUnavailable
 $providers=@($selection.Providers);$warnings+=@($selection.Warnings)
 if($null -ne $sourceProviders){$providers=@($providers|Where-Object {[string](Get-TCDField $_ Id '') -in $sourceProviders});foreach($providerId in $sourceProviders){if($providerId -notin @($providers|ForEach-Object {[string](Get-TCDField $_ Id '')})){$warnings+='模板服务商未纳入候选，请刷新对应档案：'+$providerId}}}
 foreach($required in @($Run.RequiredProviderIds)){if($required -notin @($providers|ForEach-Object {[string](Get-TCDField $_ Id '')})){$Run.ProviderWarnings=@($warnings);$null=Save-TCDeploymentRun $Root $Run;throw '[TC:RequiredProviderUnavailable] 目标连接依赖的服务商不可用，请先修复对应档案。'}}
 $Run.ProviderWarnings=@($warnings|Select-Object -Unique)
 $nodes=@(Get-TCNodes -Root (Join-Path $Root 'Product'));$configHash=(Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
 if(-not $Run.CandidateTransaction){
  $Run.CandidateTransaction=[pscustomobject]@{State='Prepared';RequestId=$Run.ClientRequest.RequestId;ConfigHash=$configHash;BeforeNodeIds=@($nodes|ForEach-Object {$_.id});NodeId=$null;CreatedAtUtc=[DateTime]::UtcNow.ToString('o')}
  $Run.Stage='MaterializeCandidate';$null=Save-TCDeploymentRun $Root $Run
 }elseif($Run.CandidateTransaction.RequestId -cne $Run.ClientRequest.RequestId -or $Run.CandidateTransaction.ConfigHash -cne $configHash){throw '[TC:CandidateTransactionMismatch] 原候选准备资料发生变化，请保留记录并核对。'}
 if(-not $Run.CandidateNodeId){
  # Reconcile a crash after node import and before publishing its ID to the run.
  $matches=@(foreach($node in $nodes){if($node.id -in @($Run.CandidateTransaction.BeforeNodeIds)){continue};$manifest=Read-TCDJson $node.manifestPath;if([string](Get-TCDField $manifest ExportSHA256 '') -ceq $configHash -and $manifest.ClientPublicKey -ceq $Run.ClientRequest.ClientPublicKey -and $manifest.ServerPublicKey -ceq $Run.ClientResponse.ServerPublicKey){$node}})
  if($matches.Count -gt 1){throw '[TC:CandidateAmbiguous] 发现多个相同申请候选，请核对记录；未新增线路。'}
  if($matches.Count -eq 1){$Run.CandidateNodeId=$matches[0].id;$Run.CandidateManifestPath=$matches[0].manifestPath}
  else{$imported=Import-TCWireGuard -Root (Join-Path $Root 'Product') -Path $destination -Name $Run.Name -EnginePath (Join-Path $PSScriptRoot 'assets\sing-box.exe') -WgPath (Join-Path $PSScriptRoot 'assets\wg.exe') -TradeProgramPaths $programs -DirectDnsIPv4 ([string]$Run.DirectDns) -Providers $providers;$Run.CandidateNodeId=$imported.Id;$Run.CandidateManifestPath=$imported.ManifestPath}
  $Run.CandidateTransaction.NodeId=$Run.CandidateNodeId;$Run.CandidateTransaction.State='Imported';$null=Save-TCDeploymentRun $Root $Run
 }
 $existing=@(Get-TCNodes -Root (Join-Path $Root 'Product')|Where-Object {$_.id -eq $Run.CandidateNodeId});if($existing.Count -ne 1){throw '[TC:CandidateMissing] 原候选记录缺失，未重复生成线路。'}
 $Run.CandidateManifestPath=$existing[0].manifestPath;$candidate=Read-TCDJson $Run.CandidateManifestPath
 $null=Set-TCServerLink -Root $Root -ServerId $Run.ServerRecordId -NodeId $Run.CandidateNodeId -ObservedExitIPv4 $Run.ExpectedExitIPv4 -EvidenceSource $Run.ExpectedExitSource
 $Run.CandidateTransaction.State='ProfilesPending';$Run.Stage='MaterializeCandidate';$Run.NetworkChanged=$false;$null=Save-TCDeploymentRun $Root $Run
 $Run.ProtocolPreparation.Udp.ServerPreparation='Configured'
 Complete-TCDeploymentProfiles $Root $Run $null
 if(Get-TCDField $Run.ClientResponse Transport){
  $Run.TcpInfo=[pscustomobject]@{Kind='TradeChannel.TransportInfo';Status='Available';NodeId=$Run.ClientResponse.NodeId;RemoteOwnerId=$Run.ServerInfo.RemoteOwnerId;ServerPublicKey=$Run.ClientResponse.ServerPublicKey;ClientPublicKey=$Run.ClientResponse.ClientPublicKey;ClientAddress=$Run.ClientResponse.ClientAddress;Transport=$Run.ClientResponse.Transport}
  if($Run.ClientResponse.PSObject.Properties['MTU'] -or ($Run.ClientResponse -is [Collections.IDictionary] -and $Run.ClientResponse.Contains('MTU'))){$Run.TcpInfo|Add-Member NoteProperty MTU (Get-TCDField $Run.ClientResponse MTU)}
  Complete-TCDeploymentProfiles $Root $Run $Run.TcpInfo
 }
 $Run.CandidateTransaction.State='Completed'
}
function Complete-TCPairCandidate {
 [CmdletBinding()]param([string]$Root,[Parameter(Mandatory=$true)][string]$EnrollmentId,[string]$EncryptedAuthorization,[string]$Name='邀请接入的服务器',$ClientInspection)
 Import-Module (Join-Path $PSScriptRoot 'DeploymentPairing.psm1') -DisableNameChecking
 $run=$null;$runId=Assert-TCDId $EnrollmentId;$dir=Get-TCDeploymentRunPath $Root $runId;$null=New-TCDDirectory $dir;$lock=Open-TCDLock (Join-Path $dir '.run.lock')
 try{
  $completed=if($EncryptedAuthorization){Complete-TCPairAuthorization -Root $Root -EnrollmentId $EnrollmentId -EncryptedAuthorization $EncryptedAuthorization}else{Resume-TCPairAuthorization -Root $Root -EnrollmentId $EnrollmentId}
  $enrollment=Get-TCPairEnrollment -Root $Root -EnrollmentId $EnrollmentId;$response=Read-TCDJson $completed.ResponsePath
  $info=@{RemoteOwnerId=$enrollment.ServerBinding.RemoteOwnerId;Node=@{NodeId=$response.NodeId;ServerPublicKey=$response.ServerPublicKey;PublicEndpoint=$response.PublicEndpoint};ManagementSigningPublicKey=$enrollment.ManagementSigningPublicKey;ManagementApiVersion=2;OwnershipState='InvitationPinned'}
  $server=Set-TCServerRecord -Root $Root -ServerInfo $info -Name $Name -ConnectorOnly
  $statePath=Join-Path $dir 'state.json'
  if([IO.File]::Exists($statePath)){
   $run=Get-TCDeploymentRun $Root $runId
   if($run.Intent -cne 'Pairing' -or $run.ServerRecordId -cne $server.LocalRecordId -or $run.ClientRequest.RequestId -cne $enrollment.ClientRequest.RequestId){throw '[TC:EnrollmentRunMismatch] 此接入申请已经绑定到另一项运行记录。'}
   $run.ClientResponse=$response
  }else{
   $run=[pscustomobject][ordered]@{SchemaVersion=1;RunId=$runId;Revision=0;Intent='Pairing';ServerRecordId=$server.LocalRecordId;Name=$Name;TemplateNodeId=$null;Transport='Auto';Programs=@();DirectDns='1.1.1.1';Stage='MaterializeCandidate';Status='Idle';SessionRef=$null;PendingOperationId=$null;PendingPurpose=$null;ClientRequest=$enrollment.ClientRequest;RequestDirectory=$completed.RequestDirectory;ClientResponse=$response;CandidateNodeId=$null;CandidateManifestPath=$null;ExpectedExitIPv4=$null;ExpectedExitSource=$null;Validation=$null;LastError=$null;UserActions=@();DispatchIntent=$null;LastRemoteMutation=$null;CandidateTransaction=$null;ProviderWarnings=@();RequiredProviderIds=@();AddressSelectionEvidence=$null;CreatedAtUtc=[DateTime]::UtcNow.ToString('o');UpdatedAtUtc=[DateTime]::UtcNow.ToString('o');NetworkChanged=$false}
   foreach($field in @(@{Name='TcpPort';Value=443},@{Name='ServerName';Value='www.bing.com'},@{Name='VpnPort';Value=51820},@{Name='TunnelSubnet';Value=$response.TunnelSubnet},@{Name='Plan';Value=$null},@{Name='ManagementPlan';Value=$null},@{Name='Review';Value=$null},@{Name='ApprovedChangeDigest';Value=$null},@{Name='AllowManagementInitialize';Value=$false},@{Name='AllowDeviceAuthorize';Value=$false},@{Name='ServerInfo';Value=$info})){$run|Add-Member NoteProperty $field.Name $field.Value}
   $null=Save-TCDeploymentRun $Root $run
  }
  if($ClientInspection){$run.Programs=@(Get-TCDField $ClientInspection NinjaTraderPaths @());$dns=@(Get-TCDField $ClientInspection DirectDnsIPv4 @());if($dns.Count){$run.DirectDns=[string]$dns[0]}}
  Complete-TCDeploymentCandidate -Root $Root -Run $run -UseExistingConfig -SourceConfigPath $completed.ConfigPath
  # Consume the verified private bundle, not the public completion summary.
  # V2 evidence has already been checked against the signed original request.
  $verifiedBundle=Get-TCPairConnectionBundle -Root $Root -EnrollmentId $EnrollmentId
  $run.ConnectionBundle=Get-TCDField $completed ConnectionBundle
  $run|Add-Member NoteProperty ExperienceVersion 1 -Force
  $exit=Get-TCDField $verifiedBundle ExitEvidence
  if((Get-TCDField $verifiedBundle ContractVersion 0) -eq 2 -and $exit -and (Get-TCDField $exit Source '') -ceq 'ServerVerifiedTlsTrace'){
   $run.ExpectedExitIPv4=[string](Get-TCDField $exit ObservedExitIPv4 '');$run.ExpectedExitSource='ServerVerifiedTlsTrace'
  }
  if($run.Stage -eq 'ReadyInactive' -and $run.ProfileProbeState -eq 'Pending' -and $run.ExpectedExitSource -eq 'ServerVerifiedTlsTrace'){Complete-TCDeploymentAutomaticChecks $Root $run}
  $null=Save-TCDeploymentRun $Root $run
  [pscustomobject]@{Status=$(if($run.DeploymentCompleteness -eq 'Complete'){'ReadyInactive'}else{$run.Status});DeploymentCompleteness=$run.DeploymentCompleteness;MissingProtocols=@($run.MissingProtocols);DualPreparationRequired=$run.DualPreparationRequired;PartialUseAccepted=$run.PartialUseAccepted;Id=$run.CandidateNodeId;NodeId=$run.CandidateNodeId;ManifestPath=$run.CandidateManifestPath;ServerRecordId=$server.LocalRecordId;EnrollmentId=$EnrollmentId;RunId=$run.RunId;ConfigPath=$completed.ConfigPath;ProviderWarnings=$run.ProviderWarnings;NetworkChanged=$false}
 }catch{
  if($run){$run.Status='Failed';$run.Stage='MaterializeCandidate';$run.LastError=[pscustomobject]@{Code='PairCandidateFailed';Message='候选尚未完成，原授权和事务已保留；重新提交相同返回可继续。'};$null=Save-TCDeploymentRun $Root $run};throw
 }finally{$lock.Dispose()}
}
function Invoke-TCDeploymentAdvance {
 [CmdletBinding()]param([string]$Root,[string]$RunId,[ValidateSet('Continue','Approve','Cancel','Recheck','Reconcile','RecoverProbe','Probe','UsePrepared','Save')][string]$Command='Continue',[string]$ApprovedChangeDigest,[ValidateRange(0,2147483647)][int]$InterfaceIndex=0)
 $server=Assert-TCServerTaskActive -Root $Root -RunId $RunId
 $lease=Open-TCServerTaskLease -Root $Root -ServerId $server.LocalRecordId;$lock=$null;$run=$null
 try{
  Assert-TCDraftActive -Root $Root -Id ('DeploymentRun:'+$RunId)
  $dir=Get-TCDeploymentRunPath $Root $RunId;$lock=Open-TCDLock (Join-Path $dir '.run.lock')
  $run=Get-TCDeploymentRun $Root $RunId
  if($Command -eq 'Continue' -and -not $run.RecoveryRequired -and (Get-TCDField $run PausedContinuation)){
   $next=$run.PausedContinuation;$server=Get-TCServer $Root $run.ServerRecordId
   $binding=Get-TCDDigest @{ServerId=$server.LocalRecordId;Connection=$server.Connection;Key=$server.ServerPublicKey;HostKey=$server.PinnedHostKey}
   if($binding -cne $next.ServerBinding){throw '[TC:ApprovalTargetChanged] 暂停后服务器身份已变化，请先核对原步骤。'}
   $pausePath=Join-Path $dir 'pause-at-checkpoint.json';if([IO.File]::Exists($pausePath)){[IO.File]::Delete((Assert-TCDPath $pausePath))}
   $run.PausedContinuation=$null;Start-TCDeploymentRemote $Root $run $next.Operation $next.Purpose $next.InputData
   return Save-TCDeploymentRun $Root $run
  }
  if($Command -in @('Continue','RecoverProbe') -and $run.ProbeRecoveryRequired -and -not $run.UnresolvedTcpMutation -and -not $run.PendingPurpose -and (Get-TCDField $run.LastRemoteMutation State '') -notin @('Prepared','Dispatched') -and (-not $run.StopTransaction -or $run.StopTransaction.State -eq 'Reconciled')){
   Import-Module (Join-Path $PSScriptRoot 'CandidateProbe.psm1') -DisableNameChecking
   $check=Repair-TCCandidateProbeCleanup -Root $Root -NodeId $run.CandidateNodeId
   $check|Add-Member NoteProperty RunId $run.RunId -Force;$check|Add-Member NoteProperty CandidateNodeId $run.CandidateNodeId -Force;$check|Add-Member NoteProperty ProbeAttemptId $run.ProbeAttemptId -Force;$check|Add-Member NoteProperty CompletedAtUtc ([DateTimeOffset]::UtcNow.ToString('o')) -Force
   $run|Add-Member NoteProperty ProbeRecovery $check -Force
   if($check.CleanupComplete){$run.ProbeRecoveryRequired=$false;$run.RecoveryRequired=$false;$run.LastError=$null;$run.ProfileProbeState='Interrupted';$run.Recommendation=$null;$run.RecommendedProfileId=$null;Set-TCDeploymentReadyState $run}
   else{$run.LastError=[pscustomobject]@{Code=$check.Code;Message=$check.Message}}
   return Save-TCDeploymentRun $Root $run
  }
  if($Command -eq 'RecoverProbe'){throw '[TC:ProbeRecoveryNotReady] 请先核对远端变更及其他事务，再清理原本机探针。'}
  if($Command -eq 'Save'){
   if($run.Stage -ne 'ReadyInactive' -or $run.PendingPurpose -or $run.ProfileProbeState -eq 'Running' -or $run.RecoveryRequired){throw '[TC:DeploymentNotReady] 请先核对正在进行或需要恢复的任务。'}
   $run.SavedForLaterAtUtc=[DateTimeOffset]::UtcNow.ToString('o');if($run.DeploymentCompleteness -eq 'Complete'){$run.Status='Complete'};$run.UserActions=@('查看已准备方式','重新检查');$run.NetworkChanged=$false;return Save-TCDeploymentRun $Root $run
  }
  # Worker Action=DeploymentProceed already forwards Command. Acceptance only
  # records the user's choice; activation remains a separate explicit action.
  if($Command -eq 'UsePrepared'){
   if($run.DeploymentCompleteness -eq 'NeedsRecovery'){throw '[TC:NeedsRecovery] 请先核对事务与清理结果，不能接受部分部署。'}
   if($run.Stage -ne 'ReadyInactive' -or $run.DeploymentCompleteness -ne 'Partial' -or $run.PendingPurpose){throw '[TC:PartialDeploymentRequired] 只有已准备且没有待处理事务的部分部署可以先使用。'}
   Import-TCDeploymentProfiles;$line=Get-TCLine -Root $Root -Id $run.CandidateNodeId
   $prepared=@($line.Profiles|Where-Object {$_.Id -notin @($run.MissingProtocols) -and $_.PreparationState -ceq 'SyntaxValidated'})
   if(-not $prepared.Count){throw '[TC:PreparedProfileMissing] 尚无已备齐的服务和本机连接资料。'}
   $run.PartialUseAccepted=$true;Set-TCDeploymentReadyState $run;$run.NetworkChanged=$false;return Save-TCDeploymentRun $Root $run
  }
  if($Command -eq 'Cancel'){return Stop-TCDeploymentRun $Root $run}
  if($run.Status -in @('Running','Dispatching')){return $run}
  if($Command -eq 'Probe'){
   if(-not $run.CandidateNodeId){throw '[TC:CandidateMissing] 请先准备候选线路。'}
   if($run.RecoveryRequired -or $run.Status -in @('OutcomeUnknown','NeedsRecovery')){throw '[TC:NeedsRecovery] 请先核对事务与原 UDP，未启动探针。'}
   if($PSBoundParameters.ContainsKey('InterfaceIndex')){$run.ProbeInterfaceIndex=$InterfaceIndex}
   Test-TCDeploymentProfiles $Root $run;return Save-TCDeploymentRun $Root $run
  }
  if($Command -eq 'Approve' -and $run.RecoveryRequired){throw '[TC:NeedsRecovery] 请先核对原变更，未提交新变更。'}
  if($Command -eq 'Approve'){
   if($run.Stage -ne 'PlanReady' -or -not $run.Review -or $ApprovedChangeDigest -cne $run.Review.ChangeDigest){throw '[TC:ApprovalMismatch] 变更确认与当前预览不匹配，请重新核对。'}
   $server=Get-TCServer $Root $run.ServerRecordId;$access=$null;if($server.Connection){$access=@{Host=$server.Connection.Host;Port=$server.Connection.Port;User=$server.Connection.User}}
   $identity=@{RemoteOwnerId=$server.RemoteOwnerId;NodeId=$server.NodeId;ServerPublicKey=$server.ServerPublicKey;PinnedHostKey=$server.PinnedHostKey;Connection=$access}
   if(-not (Get-TCDField $run.Review TargetIdentity) -or (Get-TCDDigest $identity) -cne (Get-TCDDigest $run.Review.TargetIdentity)){throw '[TC:ApprovalTargetChanged] 目标身份或接入资料在预览后发生变化，请重新检查并核对计划。'}
   $run.ApprovedChangeDigest=$ApprovedChangeDigest;$run.AllowManagementInitialize=$true;$run.AllowDeviceAuthorize=$true
   $run.ApprovedTransportChoices=Get-TCDField $run.Review OptionalTcpPreparation
   switch($run.Review.Kind){
    'Deploy'{
     if([DateTimeOffset]$run.Plan.PlanExpiresAt -le [DateTimeOffset]::UtcNow){$run.AllowManagementInitialize=$false;$run.AllowDeviceAuthorize=$false;$run.Stage='Inspect';$run.Status='Idle';Start-TCDeploymentRemote $Root $run inspect Inspect @{}}
     else{Start-TCDeploymentRemote $Root $run apply Apply @{PlanId=$run.Plan.PlanId}}
    }
    'Management'{Start-TCDeploymentRemote $Root $run management_apply ManagementApply @{PlanId=$run.ManagementPlan.PlanId;ApprovedChangeDigest=$run.ManagementPlan.ChangeDigest}}
    'Authorize'{Start-TCDeploymentRemote $Root $run authorize Authorize @{ClientRequest=$run.ClientRequest}}
    'PrepareTcp'{$run.AllowDeviceAuthorize=$false;Start-TCDeploymentTcpInspection $Root $run}
    default{throw '[TC:ApprovalMismatch] 不支持此变更类型。'}
   }
   return Save-TCDeploymentRun $Root $run
  }
  if($Command -eq 'Reconcile' -or $run.RecoveryRequired -or $run.Status -in @('OutcomeUnknown','NeedsRecovery') -or $run.Stage -eq 'Reconcile'){
   Start-TCDeploymentReconciliation $Root $run ($Command -in @('Reconcile','Recheck'))
   return Save-TCDeploymentRun $Root $run
  }
  if($run.Stage -eq 'RecoveryVerified'){
   $run.Stage=$run.RecoveryVerification.ResumeStage
  }
  if($run.Stage -eq 'ReadyInactive'){
   if($Command -eq 'Recheck' -and 'Tcp' -in @($run.MissingProtocols)){
    if($run.Intent -eq 'Pairing'){Test-TCDeploymentProfiles $Root $run;return Save-TCDeploymentRun $Root $run}
    $run.TcpFailure=$null;$run.LastError=$null;$run.TcpPlan=$null;Start-TCDeploymentTcpInspection $Root $run;return Save-TCDeploymentRun $Root $run
   }
   Complete-TCDeploymentAutomaticChecks $Root $run;return Save-TCDeploymentRun $Root $run
  }
  if($run.Stage -eq 'InspectTcp'){Start-TCDeploymentTcpInspection $Root $run;return Save-TCDeploymentRun $Root $run}
  if($run.Stage -eq 'MaterializeTcp'){Complete-TCDeploymentProfiles $Root $run $run.TcpInfo;Complete-TCDeploymentAutomaticChecks $Root $run;return Save-TCDeploymentRun $Root $run}
  if($run.Intent -eq 'Pairing' -and ($run.Stage -eq 'MaterializeCandidate' -or ($run.CandidateTransaction -and $run.CandidateTransaction.State -ne 'Completed'))){
   Import-Module (Join-Path $PSScriptRoot 'DeploymentPairing.psm1') -DisableNameChecking
   $completed=Resume-TCPairAuthorization -Root $Root -EnrollmentId $run.RunId;$run.ClientResponse=Read-TCDJson $completed.ResponsePath
   Complete-TCDeploymentCandidate -Root $Root -Run $run -UseExistingConfig -SourceConfigPath $completed.ConfigPath;return Save-TCDeploymentRun $Root $run
  }
  if($run.CandidateTransaction -and $run.CandidateTransaction.State -ne 'Completed'){$run.Stage='MaterializeCandidate';Complete-TCDeploymentCandidate $Root $run;Start-TCDeploymentTcpInspection $Root $run;return Save-TCDeploymentRun $Root $run}
  if($run.ClientResponse -or $run.Stage -eq 'ServerInfo'){Start-TCDeploymentRemote $Root $run server_info ServerInfo @{};return Save-TCDeploymentRun $Root $run}
  if($run.Stage -in @('PrepareAccess','Inspect') -or $Command -eq 'Recheck'){Start-TCDeploymentRemote $Root $run inspect Inspect @{};return Save-TCDeploymentRun $Root $run}
  throw '[TC:StageMismatch] 请先完成当前阶段显示的操作。'
 }finally{if($lock){$lock.Dispose()};$lease.Dispose()}
}
function Sync-TCDeploymentRun {
 [CmdletBinding()]param([string]$Root,[string]$RunId,[string]$ReconciliationIntentId)
 $server=Assert-TCServerTaskActive -Root $Root -RunId $RunId
 $lease=Open-TCServerTaskLease -Root $Root -ServerId $server.LocalRecordId;$lock=$null;$run=$null
 try{
  Assert-TCDraftActive -Root $Root -Id ('DeploymentRun:'+$RunId)
  $dir=Get-TCDeploymentRunPath $Root $RunId;$lock=Open-TCDLock (Join-Path $dir '.run.lock')
  $run=Get-TCDeploymentRun $Root $RunId
  if($ReconciliationIntentId){
   if(-not $run.RecoveryVerification -or $run.RecoveryVerification.MutationIntentId -cne $ReconciliationIntentId){throw '[TC:RecoveryBindingChanged] 核对轮询不属于当前原始变更。'}
   if($run.RecoveryVerification.Status -in @('Verified','Blocked')){return $run}
   if($run.RecoveryVerification.Status -cne 'Checking' -or $run.PendingPurpose -notlike 'Recovery*'){throw '[TC:RecoveryBindingChanged] 当前阶段不是指定事务的只读核对。'}
  }
  if($run.Stage -in @('PreparingProbePath','CheckingProfiles')){
   # Acquiring the run lock proves the old checking worker has released it.
   # A retry still goes through the probe's actual identity/owned-process guard.
   $run.ProfileProbeState='Interrupted';$run.RecommendedProfileId=$null;$run.Recommendation=$null;Set-TCDeploymentReadyState $run
   $run.ProbeError=[pscustomobject]@{Code='ProfileCheckInterrupted';Message='上次本机检查已中断。请重新检查，已准备的服务器和连接资料保留。'};$run.LastError=$run.ProbeError
   return Save-TCDeploymentRun $Root $run
  }
  if($run.Status -notin @('Running','Dispatching') -or -not $run.SessionRef){return $run}
  if($run.PendingPurpose -like 'Recovery*' -and $run.RecoveryAttempt -and [DateTimeOffset]::UtcNow -gt [DateTimeOffset]$run.RecoveryAttempt.DeadlineUtc){Set-TCDeploymentRecoveryBlocked $run 'RecoveryReadTimeout' '只读核对已超时，请检查接入后重新核对。';return Save-TCDeploymentRun $Root $run}
  $poll=Get-TCDeploySession -SessionRef $run.SessionRef
  if($poll.Status -in @('Running','Connecting','AwaitingCredential','HostTrustRequired')){return $run}
  if($poll.OperationId -and $poll.OperationId -cne $run.PendingOperationId){
   if($run.Status -eq 'Dispatching'){$run.Status=if($run.DispatchIntent.Mutating){'OutcomeUnknown'}else{'Failed'};$run.Stage='Reconcile';return Save-TCDeploymentRun $Root $run}
   throw '[TC:OperationMismatch] 执行器结果不是当前操作。'
  }
  if($poll.Status -ne 'Completed'){
   $purpose=$run.PendingPurpose
   if($purpose -like 'Recovery*'){Set-TCDeploymentRecoveryBlocked $run ([string](Get-TCDField $poll Code 'RecoveryReadFailed')) '核对读取未完成，原变更仍需恢复。';return Save-TCDeploymentRun $Root $run}
   if($purpose -in @('RecheckUdp','ExistingUdp')){
    $run.Status='NeedsRecovery';$run.Stage='NeedsRecovery';$run.RecoveryRequired=$true;$run.RecommendedProfileId=$null
    $run.UdpRecheck=[pscustomobject]@{Status='Unknown';ErrorCode=(Get-TCDField $poll Code 'UdpStateUnavailable')}
    $run.ProtocolPreparation.Udp.Error=[pscustomobject]@{Code='UdpStateUnavailable';Message='未能读取原 UDP 实际状态，不能交付成功。'}
    return Save-TCDeploymentRun $Root $run
   }
   if($purpose -in @('InspectTcp','TcpCandidates','TcpPlan','TcpApply','TcpParameters')){
    $errorData=Get-TCDField $poll Data;$code=[string](Get-TCDField $errorData Code (Get-TCDField $poll Code 'TcpPreparationFailed'))
    $unknown=$poll.Status -eq 'OutcomeUnknown' -or ($run.DispatchIntent.Mutating -and -not $errorData) -or $code -in @('NeedsRecovery','OwnershipMismatch','ConfigDrift','ServiceDrift','IdentityDrift','TunnelDrift','TransportBindingMismatch','ServerBindingMismatch')
    if($run.DispatchIntent -and -not $unknown){$run.DispatchIntent.State='Failed';if($run.DispatchIntent.Mutating){$run.LastRemoteMutation=$run.DispatchIntent}}
    Start-TCDeploymentUdpRecheck $Root $run ([pscustomobject]@{Code=$code;Message='TCP 备用准备失败，正在核对原 UDP 服务和授权。'}) $unknown
    return Save-TCDeploymentRun $Root $run
   }
   $run.Status=if($poll.Status -eq 'OutcomeUnknown' -or ($run.DispatchIntent -and $run.DispatchIntent.Mutating -and $run.DispatchIntent.State -in @('Prepared','Dispatched'))){'OutcomeUnknown'}else{'Failed'}
   $run.LastError=[pscustomobject]@{Code=(Get-TCDField $poll Code 'RemoteFailed');Message=(Get-TCDField $poll Message '远程操作未完成，请核对实际结果。')};$run.UserActions=@('重新登录并检查结果');return Save-TCDeploymentRun $Root $run
  }
  if($run.PendingPurpose -like 'Recovery*'){$poll=Assert-TCDeploymentRecoveryObservation $Root $run}
  $data=$poll.Data
  if($data -and (Get-TCDField $data Ok $null) -is [bool]){if(-not $data.Ok){throw '[TC:RemoteFailed] 服务器拒绝了操作。'};$data=$data.Data}
  $purpose=$run.PendingPurpose;if($run.DispatchIntent){$run.DispatchIntent.State='Completed';if($run.DispatchIntent.Mutating){$run.LastRemoteMutation=$run.DispatchIntent}};$run.PendingOperationId=$null;$run.PendingPurpose=$null;$run.Status='Idle'
  if($purpose -like 'Recovery*'){Sync-TCDeploymentRecovery $Root $run $purpose $data;return Save-TCDeploymentRun $Root $run}
  switch($purpose){
   'Inspect'{
    if(-not $data.Supported){
     $run.Status='Failed';$run.LastError=[pscustomobject]@{Code='PreflightRejected';Message=$data.Summary;Issues=$data.Issues};$run.UserActions=@('按检查结果处理','导入已有连接');break
    }
    $knownServer=Get-TCServer $Root $run.ServerRecordId
    if($knownServer.ServerPublicKey -and -not ($data.AlreadyDeployed -or $data.OwnedDeployment)){
     $run|Add-Member NoteProperty AccessIssue ([pscustomobject]@{Kind='ApplicationReset';Code='ApplicationEnvironmentReset';ResumeStage='Inspect';ServerRecordId=$run.ServerRecordId;RecordedAtUtc=[DateTimeOffset]::UtcNow.ToString('o')}) -Force
     $run.Status='WaitingUser';$run.LastError=[pscustomobject]@{Code='ApplicationEnvironmentReset';Message='原隧道环境已不存在，需要在本向导核对新环境后继续。'};break
    }
    Initialize-TCDeploymentRequest $Root $run
    if($run.ExistingDevice -and -not ($data.AlreadyDeployed -or $data.OwnedDeployment)){throw '[TC:ExistingServerMissing] 原服务器部署已不存在，未重新安装或新增设备。'}
    if($data.AlreadyDeployed -or $data.OwnedDeployment){Start-TCDeploymentRemote $Root $run server_info ServerInfo @{}}
    else{
     if(-not $run.TunnelSubnet){$run.TunnelSubnet=Select-TCDeploymentSubnet $Root $run $data}
     $server=Get-TCServer $Root $run.ServerRecordId
     $inputData=@{Name=$run.Name;PublicEndpoint=($server.Connection.Host+':'+$run.VpnPort);TunnelSubnet=$run.TunnelSubnet;ClientRequest=$run.ClientRequest}
     Start-TCDeploymentRemote $Root $run plan Plan $inputData
    }
   }
   'Plan'{$run.Plan=$data;Set-TCDeploymentReview $Root $run Deploy $data '备齐 UDP、TCP 服务并授权本机' '安装 UDP 服务、授权首台设备、初始化管理记录与邀请身份，再在同一会话增量准备 TCP 和两套本机连接资料。连接方式选项仅为初始偏好；TCP 未完成时标为部分部署。云端端口按下方清单处理，本机网络不会切换。'}
   'Apply'{$run.ClientResponse=$data.ClientResponse;Start-TCDeploymentRemote $Root $run server_info ServerInfo @{}}
   'ServerInfo'{
    $knownServer=Get-TCServer $Root $run.ServerRecordId
    if($knownServer.ServerPublicKey -and ([string](Get-TCDField (Get-TCDField $data Node) ServerPublicKey '') -cne [string]$knownServer.ServerPublicKey -or [string](Get-TCDField $data RemoteOwnerId '') -cne [string]$knownServer.RemoteOwnerId)){
     $run|Add-Member NoteProperty AccessIssue ([pscustomobject]@{Kind='ApplicationMismatch';Code='ApplicationIdentityMismatch';ResumeStage='ServerInfo';ServerRecordId=$run.ServerRecordId;RecordedAtUtc=[DateTimeOffset]::UtcNow.ToString('o')}) -Force
     $run.Status='WaitingUser';$run.LastError=[pscustomobject]@{Code='ApplicationIdentityMismatch';Message='实际隧道身份与原记录不一致，请先核对真实服务器环境。'};break
    }
    $run.ServerInfo=$data;$null=Set-TCServerRecord -Root $Root -Id $run.ServerRecordId -ServerInfo $data -SessionRef $run.SessionRef
    if(-not (Get-TCDField $data ManagementSigningPublicKey)){
     Start-TCDeploymentRemote $Root $run management_plan ManagementPlan @{}
    }elseif($run.ExistingDevice -and -not $run.ClientResponse){
     Start-TCDeploymentRemote $Root $run deployment_state ExistingUdp @{ClientPublicKey=$run.ClientRequest.ClientPublicKey;ServerPublicKey=$data.Node.ServerPublicKey}
    }elseif($run.ClientResponse){Start-TCDeploymentRemote $Root $run status ServerExit @{NetworkProbe=$true}}
    elseif($run.AllowDeviceAuthorize){Start-TCDeploymentRemote $Root $run authorize Authorize @{ClientRequest=$run.ClientRequest}}
    else{Set-TCDeploymentReview $Root $run Authorize @{ClientPublicKey=$run.ClientRequest.ClientPublicKey;Node=$data.Node} '授权本机并备齐 UDP、TCP 连接方式' '保留服务器和其他设备；为本机生成独立授权，再在同一会话准备 UDP、TCP 服务和本机连接资料。连接方式选项仅为初始偏好，尚不切换网络。'}
   }
   'ManagementPlan'{
    $run.ManagementPlan=$data
    if($run.AllowManagementInitialize){Start-TCDeploymentRemote $Root $run management_apply ManagementApply @{PlanId=$data.PlanId;ApprovedChangeDigest=$data.ChangeDigest}}
    else{Set-TCDeploymentReview $Root $run Management $data '补齐管理能力并授权本机' '只新增管理记录与签名身份，保留隧道和现有设备；随后为这台电脑生成独立授权。'}
   }
   'ManagementApply'{Start-TCDeploymentRemote $Root $run server_info ServerInfo @{}}
   'Authorize'{$run.ClientResponse=$data.ClientResponse;Start-TCDeploymentRemote $Root $run status ServerExit @{NetworkProbe=$true}}
   'ServerExit'{
    if((Get-TCDField $data Status '') -cne 'Applied'){throw '[TC:UdpNotHealthy] UDP 服务尚未核验，不能交付。'}
    $probe=Get-TCDField $data NetworkProbe;$rows=@(Get-TCDField $probe ServerHttps @())
    $verified=@($rows|Where-Object {(Get-TCDField $_ ExitEvidence '') -eq 'VerifiedTlsTrace' -and (Get-TCDField $_ ObservedExitIPv4)})|Select-Object -First 1
    if($verified){$run.ExpectedExitIPv4=$verified.ObservedExitIPv4;$run.ExpectedExitSource='ServerVerifiedTlsTrace'}
    Complete-TCDeploymentCandidate $Root $run
    Start-TCDeploymentTcpInspection $Root $run
   }
   'ReconcileManagement'{Start-TCDeploymentReconciliation $Root $run $true}
   'ExistingUdp'{
    if($data.Kind -cne 'TradeChannel.DeploymentState' -or $data.NodeId -cne $run.ServerInfo.Node.NodeId -or $data.RemoteOwnerId -cne $run.ServerInfo.RemoteOwnerId -or $data.ServerPublicKey -cne $run.ServerInfo.Node.ServerPublicKey -or $data.ClientPublicKey -cne $run.ClientRequest.ClientPublicKey -or $data.Status -cne 'Settled' -or $data.Udp.Status -cne 'Healthy'){$run.Status='NeedsRecovery';$run.Stage='NeedsRecovery';$run.RecoveryRequired=$true;$run.UdpRecheck=$data;$run.RecommendedProfileId=$null;break}
    $run.ClientResponse=$data.Udp.ClientResponse;$run.ClientRequest=[pscustomobject]@{RequestId=$run.ClientResponse.RequestId;DeviceId=$run.ClientResponse.DeviceId;ClientPublicKey=$run.ClientResponse.ClientPublicKey}
    $run.ProtocolPreparation.Udp.ServerPreparation='Configured';Complete-TCDeploymentProfiles $Root $run $null
    if($run.ApprovedChangeDigest){Start-TCDeploymentTcpInspection $Root $run}else{Set-TCDeploymentReview $Root $run PrepareTcp @{ClientPublicKey=$run.ClientRequest.ClientPublicKey} '为原线路补齐 TCP 备用连接方式' '复用原设备和 UDP profile；已有 TCP 直接取参数，未配置时按候选端口增量准备。'}
   }
   'InspectTcp'{
    Assert-TCDeploymentTransportBinding $run $data
    if($data.Status -eq 'Available'){
     $run.TcpInfo=$data;$run.Stage='MaterializeTcp';$null=Save-TCDeploymentRun $Root $run;Complete-TCDeploymentProfiles $Root $run $data
    }elseif($run.ApprovedChangeDigest){$choices=Get-TCDeploymentApprovedTransportChoices $run;Start-TCDeploymentRemote $Root $run transport_options TcpCandidates @{ServerPublicKey=$run.ClientResponse.ServerPublicKey;ServerName=$choices.ServerName;CandidatePorts=@($choices.CandidatePorts);CandidateServerNames=@($choices.CandidateServerNames)}}
    else{Set-TCDeploymentReview $Root $run PrepareTcp @{ClientPublicKey=$run.ClientRequest.ClientPublicKey} '补齐 TCP 备用连接方式' '保留 UDP 和原授权，增量准备 TCP。'}
   }
   'TcpCandidates'{
    $run.TransportOptions=$data
    if($data.Status -eq 'Available'){Start-TCDeploymentTcpInspection $Root $run}
    elseif($data.Status -eq 'Selected'){
     $choices=Get-TCDeploymentApprovedTransportChoices $run
     if((Get-TCDField $data HandshakeValidation '') -cne 'TlsEndpointReachable' -or [string](Get-TCDField $data SelectedServerName '') -cnotin @($choices.CandidateServerNames) -or [int]$data.Port -notin @($choices.CandidatePorts)){throw '[TC:TransportOptionsMismatch] TCP 目标未通过 TLS 预检或超出原审批 choices，未提交计划。'}
     $run.TcpPort=[int]$data.Port;$run.ServerName=[string]$data.SelectedServerName
     Start-TCDeploymentRemote $Root $run transport_plan TcpPlan @{Transport=@{Type='tcp-reality';Port=$run.TcpPort;ServerName=$run.ServerName}}
    }
    else{
     $code=[string](Get-TCDField $data Code 'TransportPortsUnavailable');if($code -cnotmatch '^[A-Za-z][A-Za-z0-9_]{0,63}$'){$code='TransportOptionsFailed'}
     $errorInfo=[pscustomobject]@{Code=$code;Message='TCP 候选端口或握手目标预检失败；保留 UDP，未提交 TCP 安装。';HandshakeChecks=@(Get-TCDField $data HandshakeChecks @())}
     Start-TCDeploymentUdpRecheck $Root $run $errorInfo
    }
   }
   'TcpPlan'{
    if($data.Transport.Port -ne $run.TcpPort -or $data.Transport.ServerName -cne $run.ServerName -or $data.NodeId -cne $run.ClientResponse.NodeId -or $data.RemoteOwnerId -cne $run.ServerInfo.RemoteOwnerId -or $data.ServerPublicKey -cne $run.ClientResponse.ServerPublicKey){throw '[TC:TransportBindingMismatch] TCP 增量计划改变了目标或参数。'}
    $run.TcpPlan=$data;$run.ProtocolPreparation.Tcp.ServerPreparation='Pending';Update-TCDeploymentCloudRules $Root $run
    Start-TCDeploymentRemote $Root $run transport_apply TcpApply @{PlanId=$data.PlanId;ApprovedChangeDigest=$data.ChangeDigest}
   }
   'TcpApply'{Start-TCDeploymentRemote $Root $run transport_info TcpParameters @{ClientPublicKey=$run.ClientResponse.ClientPublicKey;ServerPublicKey=$run.ClientResponse.ServerPublicKey}}
   'TcpParameters'{
    Assert-TCDeploymentTransportBinding $run $data;if($data.Status -ne 'Available'){throw '[TC:TransportInfoInvalid] TCP 提交后尚未取得原设备参数。'}
    $run.TcpInfo=$data;$run.Stage='MaterializeTcp';$null=Save-TCDeploymentRun $Root $run;Complete-TCDeploymentProfiles $Root $run $data
   }
   'RecheckUdp'{
    $run.UdpRecheck=$data
    $bound=$data.Kind -ceq 'TradeChannel.DeploymentState' -and $data.NodeId -ceq $run.ClientResponse.NodeId -and $data.RemoteOwnerId -ceq $run.ServerInfo.RemoteOwnerId -and $data.ServerPublicKey -ceq $run.ClientResponse.ServerPublicKey -and $data.ClientPublicKey -ceq $run.ClientResponse.ClientPublicKey -and $data.Udp.Status -ceq 'Healthy' -and $data.Udp.ClientAddress -ceq $run.ClientResponse.ClientAddress
    if(-not $bound -or $data.Status -ne 'Settled' -or $run.RecoveryRequired){$run.Stage='NeedsRecovery';$run.Status=if($run.UnresolvedTcpMutation -and $data.Status -eq 'Settled'){'OutcomeUnknown'}else{'NeedsRecovery'};$run.RecoveryRequired=$true;$run.RecommendedProfileId=$null;$run.UserActions=@('核对服务器事务与 UDP 状态');break}
    Complete-TCDeploymentProfiles $Root $run $null;$run.LastError=$run.TcpFailure
   }
   'Reconcile'{Start-TCDeploymentReconciliation $Root $run $false}
   'RequestStatus'{Start-TCDeploymentReconciliation $Root $run $false}
   default{throw '[TC:StageMismatch] 未识别执行结果阶段。'}
  }
  Complete-TCDeploymentAutomaticChecks $Root $run
  return Save-TCDeploymentRun $Root $run
 }catch{
  if($ReconciliationIntentId -and $_.Exception.Message.StartsWith('[TC:RecoveryBindingChanged]')){throw}
  if($run){
   if((Get-TCDField $run.RecoveryVerification Status '') -ceq 'Checking'){
    $code='RecoveryProofFailed';$message='核对证据不足，请处理提示后重新核对。';if($_.Exception.Message -match '^\[TC:([A-Za-z0-9_]+)\] (.+)$'){$code=$Matches[1];$message=$Matches[2]}
    Set-TCDeploymentRecoveryBlocked $run $code $message;return Save-TCDeploymentRun $Root $run
   }
   if($run.CandidateNodeId -and $run.ClientResponse -and ($run.Stage -in @('InspectTcp','TcpCandidates','TcpPlan','TcpApply','TcpParameters','MaterializeTcp'))){
    $code='TcpPreparationFailed';if($_.Exception.Message -match '^\[TC:([A-Za-z0-9_]+)\]'){$code=$Matches[1]}
    $unknown=$run.Status -eq 'OutcomeUnknown' -or $code -in @('NeedsRecovery','TransportBindingMismatch','ServerBindingMismatch')
    try{Start-TCDeploymentUdpRecheck $Root $run ([pscustomobject]@{Code=$code;Message='TCP 备用准备未完成，正在核对原 UDP。'}) $unknown;return Save-TCDeploymentRun $Root $run}catch{$run.RecoveryRequired=$true;$run.Status='NeedsRecovery';$run.Stage='NeedsRecovery'}
   }
   if($run.Status -notin @('OutcomeUnknown','NeedsRecovery')){$run.Status=if($run.DispatchIntent -and $run.DispatchIntent.Mutating -and $run.DispatchIntent.State -in @('Prepared','Dispatched')){'OutcomeUnknown'}else{'Failed'}}
   $message='流程未完成，原申请和操作记录已保留。';$errorCode='FlowFailed';if($_.Exception.Message -match '^\[TC:([A-Za-z0-9_]+)\] (.{1,500})$'){$errorCode=$Matches[1];$message=$Matches[2]}
   $run.LastError=[pscustomobject]@{Code=$errorCode;Message=$message};$run.UserActions=@('检查原操作结果','保留记录并重试');return Save-TCDeploymentRun $Root $run};throw
 }finally{if($lock){$lock.Dispose()};$lease.Dispose()}
}
function Request-TCDeploymentPause {param([string]$Root,[string]$RunId)
 $run=Get-TCDeploymentRun $Root $RunId
 if(-not $run.SessionRef -or $run.Status -in @('OutcomeUnknown','NeedsRecovery')){throw '[TC:NeedsRecovery] 请先核对原操作结果，不能将结果未知记为已暂停。'}
 $path=Join-Path (Get-TCDeploymentRunPath $Root $RunId) 'pause-at-checkpoint.json'
 Write-TCDJson $path ([pscustomobject]@{RunId=$run.RunId;InstanceId=$run.SessionRef.InstanceId;AtUtc=[DateTimeOffset]::UtcNow.ToString('o')})
 [pscustomobject]@{RunId=$run.RunId;PauseRequested=$true;Paused=$false}
}
Export-ModuleMember -Function Test-TCDeploymentMutationSettled,Get-TCDeploymentDiscovery,Get-TCDeploymentRuns,Get-TCDeploymentRun,New-TCDeploymentRun,Set-TCDeploymentSession,Set-TCDeploymentAccessState,Invoke-TCDeploymentAdvance,Sync-TCDeploymentRun,ConvertTo-TCDeploymentConnection,Complete-TCPairCandidate,Request-TCDeploymentProbeStop,Request-TCDeploymentPause
