#requires -Version 5.1
Set-StrictMode -Version 2
function RecoveryField {param($Value,[string]$Name,$Default=$null)if($null -ne $Value -and $Value.PSObject.Properties[$Name]){$Value.$Name}else{$Default}}
function Get-TCRecoveryDecision {
 [CmdletBinding()]param([bool]$ActiveTarget,$ActiveCheck,$CandidateCheck)
 if($ActiveTarget){
  if([bool](RecoveryField $ActiveCheck ExitHttp $false) -and (RecoveryField $ActiveCheck ObservedIP '')){
   return [pscustomobject]@{Code='ActiveForwardingPassed';Summary='当前线路的实际外网出口已通过检查；此前失败可能是连接尚未就绪或短暂超时。';CanPrepareTcp=$false;NetworkChanged=$false}
  }
  return [pscustomobject]@{Code='ActiveForwardingUnverified';Summary='线路进程正在运行，但外网转发尚未通过。可检查服务器授权和入站规则，或自动准备 TCP 备用。';CanPrepareTcp=$true;NetworkChanged=$false}
 }
 $code=[string](RecoveryField $CandidateCheck Code '')
 if($code -eq 'ForwardingPassedPhysicalPathUnverified'){
  return [pscustomobject]@{Code='CandidateForwardingPassed';Summary='候选转发已通过；当前系统路径下可用，切换后的物理直连仍需在启用后核对。';CanPrepareTcp=$true;NetworkChanged=$false}
 }
 $required=@(RecoveryField $CandidateCheck Checks @()|Where-Object {$_.Name -in @('AddressHttps','DomainDnsHttps')})
 if($code -eq 'ExpectedExitUnverified' -and $required.Count -eq 2 -and @($required|Where-Object Status -ne Passed).Count -eq 0 -and (RecoveryField $CandidateCheck ObservedExitIPv4 '')){
  return [pscustomobject]@{Code='CandidateForwardingPassed';Summary='候选 DNS 与 HTTPS 转发通过，但服务器出口归属和切换后的物理直连仍未核验。';CanPrepareTcp=$true;NetworkChanged=$false}
 }
 if($code -eq 'ActiveIdentity'){
  return [pscustomobject]@{Code='IdentityInUse';Summary='候选与当前连接共用设备身份，暂不并行探测，以免影响现有连接。可先准备 TCP 备用。';CanPrepareTcp=$true;NetworkChanged=$false}
 }
 [pscustomobject]@{Code='ForwardingNotVerified';Summary='候选转发尚未证实；单次超时不能证明 UDP 被阻断。请核对服务、授权和云入站规则，也可自动准备 TCP 备用。';CanPrepareTcp=$true;NetworkChanged=$false}
}
function Get-TCConnectionRecovery {
 [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][string]$Id)
 $ErrorActionPreference='Stop'
 Import-Module (Join-Path $PSScriptRoot 'AutoTransport.psm1') -DisableNameChecking
 Import-Module (Join-Path $PSScriptRoot 'NodeStore.psm1') -DisableNameChecking
 $found=@(Get-TCNodes -Root (Join-Path $Root 'Product')|Where-Object id -eq $Id)
 if($found.Count -ne 1){throw '待检查的线路不存在。'};$node=$found[0]
 $module=Import-Module (Join-Path $PSScriptRoot 'RuntimeBridge.psm1') -PassThru -DisableNameChecking
 $overview=& $module {param($DataRoot)$script:Root=$DataRoot;Get-TCOverview} $Root
 $active=($overview.Running -and [string]$overview.ManifestPath -ieq [string]$node.manifestPath)
 $checks=New-Object 'Collections.Generic.List[object]'
 $activeCheck=$null;$candidateCheck=$null
 $context=[pscustomobject]@{Name=$node.name}
 if($active){
  $activeCheck=& $module {Test-TCActiveConnection}
  $checks.Add([pscustomobject]@{Label='实际外网出口';Message=$(if($activeCheck.ExitHttp){[string]$activeCheck.ObservedIP}else{'尚未取得有效 HTTPS 出口证据'})})
  $checks.Add([pscustomobject]@{Label='交易网站';Message=$(if($activeCheck.TradingViewHttp){'HTTPS 可达；登录和行情未测试'}else{'尚未通过；可展开运行报告核对'})})
 }else{
  $context=Get-TCTransportPreparation -Root $Root -Id $Id
  Import-Module (Join-Path $PSScriptRoot 'CandidateProbe.psm1') -DisableNameChecking
  $candidateCheck=Test-TCCandidateProbe -Root $Root -NodeId $Id -ExpectedExitIPv4 ([string]$context.DefaultServer) -ExpectedExitSource ConfiguredAddress -TimeoutSeconds 45
  foreach($check in @($candidateCheck.Checks)){$checks.Add([pscustomobject]@{Label=[string]$check.Name;Message=([string]$check.Status+' / '+[string]$check.Code)})}
 }
 $result=Get-TCRecoveryDecision -ActiveTarget $active -ActiveCheck $activeCheck -CandidateCheck $candidateCheck
 $result|Add-Member NoteProperty Id $Id
 $result|Add-Member NoteProperty Name $context.Name
 $result|Add-Member NoteProperty Checks $checks.ToArray()
 $result
}
Export-ModuleMember -Function Get-TCRecoveryDecision,Get-TCConnectionRecovery
