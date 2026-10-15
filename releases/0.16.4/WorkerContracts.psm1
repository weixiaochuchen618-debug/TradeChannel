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
AddTCWorkerActions -Names @('HistoryClearCommit','HistoryClearPreview','HistoryRestore','OperationHistory','RecordDeleteCommit','RecordDeletePreview','RecordRestore') -Modules @('OperationHistory.psm1')
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
$script:TCReadLimits=@{Overview=15;Providers=45;Agents=20;Nodes=30;Preferences=15;LineProfiles=30;LineCompletion=30;LineRecovery=30;AutoTransportContext=30;OperationRecordDetail=30;DraftDisposition=30;DraftDiscardPreview=30;DeploymentDiscover=30;DeploymentGet=30;DeploymentSessionSnapshot=5;StartupStatus=20;InstallationInfo=20;RuntimeReport=30;OperationHistory=45;DeploymentCenter=45;ServerList=30;LineNetworkPreview=30;LineNetworkRollbackPreview=30;ConnectionDefaultPreview=45;ConnectionSwitchPreview=45;ConfigurationRollbackPreview=30;RecordDeletePreview=30;HistoryClearPreview=30;ProxyRecoveryStatus=20;ProxyRecoveryPreview=20}
function Get-TCWorkerActionContract {param([string]$Action)
 $known=$script:TCWorkerActions.ContainsKey($Action);$read=$script:TCReadLimits.ContainsKey($Action)
 [pscustomobject]@{Action=$Action;Known=$known;Modules=@($script:TCWorkerActions[$Action]);ReadOnly=$read;TimeoutSeconds=$(if($read){$script:TCReadLimits[$Action]}else{600});Global=($Action -in @('Overview','Providers','Agents','Nodes','Preferences','StartupStatus','DeploymentSessionSnapshot','DeploymentPoll','DeploymentProceed'));ReuseReadProcess=($Action -in @('Overview','Providers','Agents'))}
}
function Get-TCWorkerActionNames {@($script:TCWorkerActions.Keys|Sort-Object)}
Export-ModuleMember -Function Get-TCWorkerActionContract,Get-TCWorkerActionNames