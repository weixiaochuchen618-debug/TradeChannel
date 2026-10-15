#requires -Version 5.1
Set-StrictMode -Version 2
$script:RecoveryTestAdapter=$null
function RecoveryField {param($Value,[string]$Name,$Default=$null)
 if($Value -is [Collections.IDictionary]){if($Value.Contains($Name)){return $Value[$Name]}}
 elseif($null -ne $Value -and $Value.PSObject.Properties[$Name]){return $Value.$Name};$Default
}
function Get-TCRecoveryDecision {
 [CmdletBinding()]param([bool]$ActiveTarget,$ActiveCheck,$CandidateCheck)
 $raw=$CandidateCheck;if(RecoveryField $raw Result){$raw=RecoveryField $raw Result}
 $code=[string](RecoveryField $raw Code '')
 $layers=[ordered]@{Identity='Unknown';Forwarding='Unknown';Dns='Unknown';ExitBinding='Unknown';PhysicalPath='Unknown';Application='NotTested';Cleanup='NotApplicable'}
 $next='CheckLine';$canTcp=$true;$outCode='ForwardingNotVerified'
 $summary='候选转发尚未证实；单次超时不能证明 UDP 被阻断。请核对服务、授权和云入站规则，再决定是否准备 TCP 备用。'
 $ip=$null
 if($ActiveTarget){
  $layers.Identity='VerifiedActiveSession'
  $forward=[bool]((RecoveryField $ActiveCheck ExitHttp $false) -and [Net.IPAddress]::TryParse([string](RecoveryField $ActiveCheck ObservedIP ''),[ref]$ip))
  $layers.Forwarding=if($forward){'Passed'}else{'Unverified'}
  $layers.Dns=if(RecoveryField $ActiveCheck DnsHttps $false){'Passed'}else{'Unknown'}
  $layers.ExitBinding=if(RecoveryField $ActiveCheck ServerAttributionVerified $false){'Passed'}else{'Unknown'}
  $layers.Application=if(RecoveryField $ActiveCheck TradingViewHttp $false){'HttpsReached'}else{'UserVerificationRequired'}
  if($forward){$outCode='ActiveForwardingPassed';$summary='当前线路的实际 HTTPS 出口转发已通过；交易网站、历史数据和订单需分别核对。';$canTcp=$false;$next='None'}
  else{$outCode='ActiveForwardingUnverified';$summary='当前会话身份已核实，但外网转发尚未通过。请先检查当前连接、服务器授权和入站规则。';$next='CheckCurrentConnection'}
 }else{
  $layers.Cleanup=if(RecoveryField $raw CleanupComplete $false){'Passed'}else{'Unknown'}
  $required=@(RecoveryField $raw Checks @()|Where-Object {(RecoveryField $_ Name '') -in @('AddressHttps','DomainDnsHttps')})
  $names=@($required|ForEach-Object {RecoveryField $_ Name ''}|Select-Object -Unique)
  $forward=[bool]($required.Count -eq 2 -and $names.Count -eq 2 -and @($required|Where-Object {(RecoveryField $_ Status '') -ne 'Passed'}).Count -eq 0 -and [Net.IPAddress]::TryParse([string](RecoveryField $raw ObservedExitIPv4 ''),[ref]$ip))
  $blocked=$code -in @('ActiveIdentity','ProbeCleanupFailed','ProbeIdentityUnknown') -or (RecoveryField $raw Status '') -eq 'Blocked' -or ($null -ne (RecoveryField $raw CleanupComplete) -and -not (RecoveryField $raw CleanupComplete))
  if($blocked){
   $outCode=if($code -eq 'ActiveIdentity'){'IdentityInUse'}else{'NeedsRecovery'}
   $summary='设备身份正在使用，或探针归属与清理未核实；请先核对现有会话，不再启动候选。';$canTcp=$false;$next='ResolveSession';$layers.Identity='Blocked'
  }elseif($forward){
   $outCode='CandidateForwardingPassed';$summary='候选 DNS 与 HTTPS 转发通过；服务器出口归属和启用后的物理路径仍未核验。';$canTcp=$false;$next='ReviewCandidate'
   $layers.Forwarding='Passed';$layers.Dns='Passed'
   if((RecoveryField $raw ExpectedExitSource '') -eq 'ServerVerifiedTlsTrace'){
    if((RecoveryField $raw ExpectedExitIPv4 '') -eq $ip.ToString()){$layers.ExitBinding='Passed'}
    else{$layers.ExitBinding='Failed';$outCode='CandidateExitMismatch';$summary='候选转发有响应，但出口与已核验服务器不一致，请核对服务器身份和出口。';$next='CheckServerIdentity'}
   }
   $path=RecoveryField $raw PathEvidence
   if((RecoveryField $path Verified $false) -and (RecoveryField $path EligibleForRecommendation $false) -and (RecoveryField $path Kind '') -in @('BoundInterfaceObserved','InterfaceBoundObserved')){$layers.PhysicalPath='BoundInterfaceObserved'}
  }
 }
 [pscustomobject]@{Status=$(if($outCode -in @('ActiveForwardingPassed','CandidateForwardingPassed')){'Passed'}elseif($outCode -in @('IdentityInUse','NeedsRecovery')){'Blocked'}else{'Inconclusive'});Code=$outCode;Summary=$summary;CanPrepareTcp=$canTcp;NetworkChanged=$false;NextAction=$next;Layers=[pscustomobject]$layers}
}
function Invoke-TCRecoveryRead {
 param([string]$Operation,[string]$Root,$Payload)
 if($script:RecoveryTestAdapter){return & $script:RecoveryTestAdapter $Operation $Root $Payload}
 switch($Operation){
  'Line' {
   Import-Module (Join-Path $PSScriptRoot 'LineStore.psm1') -DisableNameChecking
   Get-TCLine -Root $Root -Id $Payload;return
  }
  'Observe' {
   $module=Import-Module (Join-Path $PSScriptRoot 'RuntimeBridge.psm1') -PassThru -DisableNameChecking
   & $module {
    param($DataRoot)
    $prior=$script:Root
    try{
     $script:Root=$DataRoot;$e=Get-TCSessionEvidence
     [pscustomobject]@{Overview=(Get-TCSessionPresentation -Evidence $e -Preferences (Get-TCPreferences));Identity=[pscustomobject]@{SessionId=$e.Snapshot.SessionId;EnginePid=$e.Snapshot.EnginePid;EngineStartedAt=$e.Snapshot.EngineStartedAt;SupervisorPid=$e.Snapshot.SupervisorPid;SupervisorStartedAt=$e.Snapshot.SupervisorStartedAt;ManifestPath=$e.Deployment.ManifestPath;CandidateSHA256=$e.ProfileBinding.CandidateSHA256};ServerPublicKey=$e.Manifest.ServerPublicKey;ClientPublicKey=$e.Manifest.ClientPublicKey;ClientAddress=$e.Manifest.ClientAddress}
    }finally{$script:Root=$prior}
   } $Root;return
  }
  'TargetIdentity' {
   $path=[string]$Payload.Profiles[0].ManifestPath
   $module=Get-Module RuntimeBridge|Select-Object -First 1
   & $module {param($DataRoot,$Path)$prior=$script:Root;try{$script:Root=$DataRoot;$m=(Read-TCProfileBindingFile $Path -Json).Value;[pscustomobject]@{ServerPublicKey=$m.ServerPublicKey;ClientPublicKey=$m.ClientPublicKey;ClientAddress=$m.ClientAddress}}finally{$script:Root=$prior}} $Root $path;return
  }
  'ActiveCheck' {
   $module=Get-Module RuntimeBridge|Select-Object -First 1
   & $module {param($DataRoot)$prior=$script:Root;$lock=$null;try{$script:Root=$DataRoot;$lock=Open-TCSessionLock;Test-TCActiveConnection}finally{if($lock){$lock.Dispose()};$script:Root=$prior}} $Root;return
  }
  'Preparation' {Import-Module (Join-Path $PSScriptRoot 'AutoTransport.psm1') -DisableNameChecking;Get-TCTransportPreparation -Root $Root -Id $Payload;return}
  'Candidate' {
   Import-Module (Join-Path $PSScriptRoot 'CandidateProbe.psm1') -DisableNameChecking
   Test-TCCandidateProbe -Root $Root -NodeId $Payload.Id -ExpectedExitIPv4 ([string]$Payload.DefaultServer) -ExpectedExitSource ConfiguredAddress -TimeoutSeconds 45;return
  }
  default {throw '未知诊断读取操作。'}
 }
}
function Get-TCConnectionRecovery {
 [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][string]$Id)
 $ErrorActionPreference='Stop'
 $line=Invoke-TCRecoveryRead Line $Root $Id
 if(-not $line){throw '待检查的线路不存在。'}
 $before=Invoke-TCRecoveryRead Observe $Root $null;$overview=$before.Overview
 $active=[bool]((RecoveryField $overview Running $false) -and (RecoveryField $overview ProfileBindingVerified $false) -and (RecoveryField $overview ActiveLineId '') -eq $line.LineId)
 $conflict=$false;$unknown=[bool]((RecoveryField $overview SessionPresent $false) -and -not (RecoveryField $overview Running $false))
 if(-not (RecoveryField $overview Running $false) -and (RecoveryField $overview StateKey '') -in @('Fault','Connecting','Disconnecting')){$unknown=$true}
 if((RecoveryField $overview Running $false) -and -not $active){
  $target=Invoke-TCRecoveryRead TargetIdentity $Root $line
  # Shared identity forbids parallel probing; it never proves attribution.
  $conflict=[bool]((RecoveryField $before ServerPublicKey '') -and (RecoveryField $before ClientPublicKey '') -and $before.ServerPublicKey -ceq $target.ServerPublicKey -and $before.ClientPublicKey -ceq $target.ClientPublicKey)
  $unknown=$unknown -or -not (RecoveryField $before ClientPublicKey '') -or -not (RecoveryField $target ClientPublicKey '') -or -not (RecoveryField $overview ProfileBindingVerified $false)
 }
 $checks=New-Object 'Collections.Generic.List[object]';$result=$null
 if($active -or $conflict){
  try{$activeCheck=Invoke-TCRecoveryRead ActiveCheck $Root $null}catch{$activeCheck=[pscustomobject]@{ExitHttp=$false;Code='ActiveDiagnosticUnavailable'}}
  $after=Invoke-TCRecoveryRead Observe $Root $null
  $same=[bool]((RecoveryField $after.Overview Running $false) -and $before.Identity.SessionId -and (($before.Identity|ConvertTo-Json -Compress) -ceq ($after.Identity|ConvertTo-Json -Compress)) -and (RecoveryField $before.Overview Exit '') -ceq (RecoveryField $after.Overview Exit ''))
  if(-not $same){$result=Get-TCRecoveryDecision -CandidateCheck ([pscustomobject]@{Code='ProbeIdentityUnknown'})}
  elseif($conflict){$result=Get-TCRecoveryDecision -CandidateCheck ([pscustomobject]@{Code='ActiveIdentity'});$result.NextAction='ReviewCurrentConnection'}
  elseif((RecoveryField $overview Exit '') -ne 'hk'){
   $result=Get-TCRecoveryDecision -CandidateCheck ([pscustomobject]@{Code='ActiveIdentity'});$result.Code='CurrentExitNotTarget';$result.Summary='当前交易出口使用其他服务商；现有出口检查不能验证该线路的 UDP/TCP。';$result.NextAction='ReviewCurrentConnection'
  }else{$result=Get-TCRecoveryDecision -ActiveTarget $true -ActiveCheck $activeCheck}
  $checks.Add([pscustomobject]@{Label='当前会话 HTTPS 出口';Message=$(if(RecoveryField $activeCheck ExitHttp $false){'转发通过；结果仅属于检查时的当前会话'}else{'尚未通过'})})
 }elseif($unknown){$result=Get-TCRecoveryDecision -CandidateCheck ([pscustomobject]@{Code='ProbeIdentityUnknown'})}
 else{
  $context=Invoke-TCRecoveryRead Preparation $Root $line.SourceNodeId
  $candidate=Invoke-TCRecoveryRead Candidate $Root ([pscustomobject]@{Id=$line.SourceNodeId;DefaultServer=$context.DefaultServer})
  $result=Get-TCRecoveryDecision -CandidateCheck $candidate
  foreach($check in @(RecoveryField $candidate Checks @())){$checks.Add([pscustomobject]@{Label=[string](RecoveryField $check Name '');Message=([string](RecoveryField $check Status '')+' / '+[string](RecoveryField $check Code ''))})}
 }
 $result|Add-Member NoteProperty Id $Id
 $result|Add-Member NoteProperty LineId $line.LineId
 $result|Add-Member NoteProperty Name $line.Name
 $result|Add-Member NoteProperty ActiveTarget $active
 $result|Add-Member NoteProperty Checks $checks.ToArray()
 $result
}
Export-ModuleMember -Function Get-TCRecoveryDecision,Get-TCConnectionRecovery
