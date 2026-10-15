#requires -Version 5.1
# Explicit action-level dependencies and scheduling contract; no runtime source discovery.
$script:TCWorkerActions=@{}
function AddTCWorkerActions {param([string[]]$Names,[string[]]$Modules) foreach($name in $Names){$script:TCWorkerActions[$name]=@($Modules)}}
AddTCWorkerActions -Names @('Overview','RuntimeReport') -Modules @('RuntimeBridge.psm1','RuntimeObservability.psm1')
AddTCWorkerActions -Names @('DesktopShortcut','ProxyRecoveryCommit','ProxyRecoveryPreview','ProxyRecoveryStatus') -Modules @()
AddTCWorkerActions -Names @('InstallationInfo') -Modules @('InstallationDiscovery.psm1')
AddTCWorkerActions -Names @('ConfigurationRollbackApply','ConfigurationRollbackPrepare','ConfigurationRollbackPreview') -Modules @('ConfigurationRecovery.psm1')
AddTCWorkerActions -Names @('DeploymentCancelProbe','DeploymentDiscover','DeploymentGet','DeploymentPause','LineCompletion') -Modules @('DeploymentFlow.psm1')
AddTCWorkerActions -Names @('DeploymentClose','DeploymentSessionSnapshot') -Modules @('DeploymentTransport.psm1')
AddTCWorkerActions -Names @('DeploymentCenter','DraftDiscardCommit','DraftDiscardPreview','DraftDisposition','DraftRestore','OperationRecordDetail') -Modules @('DraftDisposition.psm1')
AddTCWorkerActions -Names @('HistoryClearCommit','HistoryClearPreview','HistoryRestore','OperationHistory','RecordCleanupRecover','RecordDeleteCommit','RecordDeletePreview','RecordRestore') -Modules @('OperationHistory.psm1')
AddTCWorkerActions -Names @('DeploymentCreate') -Modules @('RuntimeBridge.psm1','DeploymentFlow.psm1','DeploymentStore.psm1')
AddTCWorkerActions -Names @('DeploymentAttach','DeploymentPoll') -Modules @('DeploymentFlow.psm1','ServerRegistry.psm1')
AddTCWorkerActions -Names @('DeploymentAccessState') -Modules @('DeploymentFlow.psm1','DeploymentStore.psm1')
AddTCWorkerActions -Names @('DeploymentProceed') -Modules @('DeploymentFlow.psm1','DeploymentStore.psm1','ServerRegistry.psm1')
AddTCWorkerActions -Names @('ServerIdentityAssessment','ServerIdentityTransition','ServerIdentityTrustPreview','ServerImportLegacy','ServerList') -Modules @('ServerRegistry.psm1')
AddTCWorkerActions -Names @('PairGrantInspect','PairInviteInspect','PairRequestCreate','PairRequestInspect') -Modules @('DeploymentPairing.psm1')
AddTCWorkerActions -Names @('ServerReinstallConfirm','ServerReinstallPreview') -Modules @('ServerRegistry.psm1','DeploymentStore.psm1')
AddTCWorkerActions -Names @('PairComplete') -Modules @('RuntimeBridge.psm1','DeploymentFlow.psm1','DeploymentStore.psm1','ServerRegistry.psm1')
AddTCWorkerActions -Names @('CandidateProbe') -Modules @('CandidateProbe.psm1')
AddTCWorkerActions -Names @('Preferences') -Modules @('RuntimeBridge.psm1','Startup.psm1')
AddTCWorkerActions -Names @('Agents','CheckActive','Command','InspectClient','RemoveProtection','SavePreferences','Session','UpgradeActive') -Modules @('RuntimeBridge.psm1')
AddTCWorkerActions -Names @('ProviderCheck','ProviderPrepare','ProviderRegister','ProviderRemove','ProviderRestore','Providers','ProviderUpdate') -Modules @('ProviderBridge.psm1')
AddTCWorkerActions -Names @('TradeDomainEdit','TradeDomains') -Modules @('ManagementStore.psm1')
AddTCWorkerActions -Names @('SetStartup','StartupStatus') -Modules @('Startup.psm1')
AddTCWorkerActions -Names @('CompleteClient','DeviceRequest','InspectServer','ServerApply','ServerAuthorize','ServerPlan') -Modules @('ServerSetup.psm1')
AddTCWorkerActions -Names @('LinuxComplete','LinuxStart') -Modules @('LinuxServerSetup.psm1','ServerRegistry.psm1')
AddTCWorkerActions -Names @('LinuxArchive','LinuxPoll','LinuxRecent','LinuxTasks','ResetHostKey') -Modules @('LinuxServerSetup.psm1')
AddTCWorkerActions -Names @('LineNetworkPreview','LineNetworkRollback','LineNetworkRollbackPreview','LineNetworkUpdate','LinePreference','LineProfiles','LineRegister','Nodes') -Modules @('LineStore.psm1')
AddTCWorkerActions -Names @('ConnectionDefaultPreview','ConnectionSwitchCommit','ConnectionSwitchPreview','ConnectionTransactionReconcile') -Modules @('ConnectionTransactions.psm1')
AddTCWorkerActions -Names @('DeleteNode','ExportSettings','ImportSettings','RenameNode','SetTransportMode','TransportInfo') -Modules @('NodeStore.psm1')
AddTCWorkerActions -Names @('DiagnoseNode') -Modules @('Diagnostics.psm1')
AddTCWorkerActions -Names @('ExportDiagnostics','MaintenanceReport','RepairState') -Modules @('Maintenance.psm1')
AddTCWorkerActions -Names @('ActivateNode','Adopt') -Modules @('RuntimeBridge.psm1','NodeStore.psm1')
AddTCWorkerActions -Names @('ImportNode') -Modules @('ProviderBridge.psm1','NodeStore.psm1')
AddTCWorkerActions -Names @('AutoTransportBind','AutoTransportContext') -Modules @('AutoTransport.psm1','ServerRegistry.psm1')
AddTCWorkerActions -Names @('AutoTransportPrepare','AutoTransportSaved') -Modules @('AutoTransport.psm1')
AddTCWorkerActions -Names @('LineRecovery') -Modules @('LineRecovery.psm1')
AddTCWorkerActions -Names @('InstallWireGuard') -Modules @('InstallerSetup.psm1')
$script:TCReadLimits=@{Overview=15;Providers=45;Agents=20;Nodes=30;Preferences=15;LineProfiles=30;LineCompletion=30;LineRecovery=30;AutoTransportContext=30;OperationRecordDetail=30;DraftDisposition=30;DraftDiscardPreview=30;DeploymentDiscover=30;DeploymentGet=30;DeploymentSessionSnapshot=5;StartupStatus=20;InstallationInfo=20;RuntimeReport=30;OperationHistory=45;DeploymentCenter=45;ServerList=30;LineNetworkPreview=30;LineNetworkRollbackPreview=30;ConnectionDefaultPreview=45;ConnectionSwitchPreview=45;ConfigurationRollbackPreview=30;RecordDeletePreview=120;HistoryClearPreview=30;ProxyRecoveryStatus=20;ProxyRecoveryPreview=20}
function Get-TCWorkerActionContract {param([string]$Action)
 $known=$script:TCWorkerActions.ContainsKey($Action);$read=$script:TCReadLimits.ContainsKey($Action)
 $scope=if($Action -in @('DeploymentCreate','DeploymentAttach','DeploymentAccessState','DeploymentProceed','DeploymentPoll','DeploymentPause','DeploymentCancelProbe','DeploymentClose')){'DeploymentServer'}else{'Global'}
 [pscustomobject]@{Action=$Action;Known=$known;Modules=@($script:TCWorkerActions[$Action]);ReadOnly=$read;TimeoutSeconds=$(if($read){$script:TCReadLimits[$Action]}else{600});Global=($Action -in @('Overview','Providers','Agents','Nodes','Preferences','StartupStatus','DeploymentSessionSnapshot','DeploymentPoll','DeploymentProceed'));ReuseReadProcess=($Action -in @('Overview','Providers','Agents'));MutationScope=$scope}
}
function Get-TCWorkerRequestField {param($Value,[string]$Name,$Default=$null)
 if($Value -is [Collections.IDictionary]){if($Value.Contains($Name)){return $Value[$Name]}}
 elseif($null -ne $Value -and $Value.PSObject.Properties[$Name]){return $Value.$Name};return $Default
}
function Assert-TCWorkerRequestPreflight {param($Request)
 # Reject incomplete references before loading modules, acquiring a lease, or
 # crossing an execution boundary. These errors cannot be remote unknowns.
 $action=[string](Get-TCWorkerRequestField $Request Action '')
 if(-not (Get-TCWorkerActionContract $action).Known){throw '[TC:InvalidRequest] 不支持的操作。'}
 $guidPattern='^(?!00000000-0000-0000-0000-000000000000$)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
 $run=[string](Get-TCWorkerRequestField $Request RunId '')
 if($action -eq 'DeploymentPoll' -and (Get-TCWorkerRequestField $Request ReconciliationIntentId $null) -ne $null -and [string](Get-TCWorkerRequestField $Request ReconciliationIntentId '') -cnotmatch $guidPattern){throw '[TC:InvalidRequest] 原变更核对标识无效。'}
 if($action -in @('DeploymentGet','DeploymentAttach','DeploymentAccessState','DeploymentProceed','DeploymentPoll','DeploymentPause','DeploymentCancelProbe') -and $run -cnotmatch $guidPattern){throw '[TC:InvalidRequest] 部署请求缺少有效运行标识，请重新打开原记录。'}
 if($action -in @('DeploymentAttach','DeploymentAccessState','DeploymentSessionSnapshot','DeploymentClose')){
  $session=Get-TCWorkerRequestField $Request SessionRef
  $sessionRun=[string](Get-TCWorkerRequestField $session RunId '')
  if(-not $session -or $sessionRun -cnotmatch $guidPattern -or [string](Get-TCWorkerRequestField $session InstanceId '') -cnotmatch $guidPattern){throw '[TC:InvalidRequest] 部署请求缺少有效会话引用，请重新打开原记录。'}
  if($run -and $sessionRun -cne $run){throw '[TC:SessionBindingMismatch] 登录会话不属于这次准备。'}
 }
 if($action -eq 'DeploymentProceed'){
  $command=[string](Get-TCWorkerRequestField $Request Command 'Continue')
  if($command -notin @('Continue','Approve','Cancel','Recheck','Reconcile','RecoverProbe','Probe','UsePrepared','Save')){throw '[TC:InvalidRequest] 部署操作无效，请重新打开原记录。'}
  if($command -eq 'Approve' -and [string](Get-TCWorkerRequestField $Request ApprovedChangeDigest '') -cnotmatch '^[0-9a-fA-F]{64}$'){throw '[TC:InvalidRequest] 变更批准缺少当前计划摘要，请重新预览。'}
 }
 if($action -eq 'DeploymentCreate'){
  $server=[string](Get-TCWorkerRequestField $Request ServerId '')
  if($server -and $server -cnotmatch $guidPattern){throw '[TC:InvalidRequest] 服务器引用无效，请重新选择。'}
  if(-not $server){
   $connection=Get-TCWorkerRequestField $Request Connection;$address=$null;$port=0
   if(-not $connection -or -not [Net.IPAddress]::TryParse([string](Get-TCWorkerRequestField $connection Host ''),[ref]$address) -or $address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or -not [int]::TryParse([string](Get-TCWorkerRequestField $connection Port ''),[ref]$port) -or $port -lt 1 -or $port -gt 65535 -or [string](Get-TCWorkerRequestField $connection User '') -cnotmatch '^[a-z_][a-z0-9_-]{0,31}$'){throw '[TC:ConnectionInvalid] 请填写有效 IPv4、SSH 端口和用户名。'}
  }
 }
}
function Get-TCWorkerActionNames {@($script:TCWorkerActions.Keys|Sort-Object)}
Export-ModuleMember -Function Get-TCWorkerActionContract,Get-TCWorkerActionNames,Assert-TCWorkerRequestPreflight
