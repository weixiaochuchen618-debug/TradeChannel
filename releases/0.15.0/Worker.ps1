#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$RequestPath,[Parameter(Mandatory=$true)][string]$ResultPath,[switch]$IsolatedTest,[string]$TestRoot)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$env:PSModulePath=Join-Path $PSHOME 'Modules'
$request=$null;$data=$null;$serverTaskLease=$null
try{
    if($IsolatedTest){
        $fixtureRoot=[IO.Path]::GetFullPath($TestRoot).TrimEnd('\')
        $tempPrefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
        if(-not ($fixtureRoot+'\').StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($fixtureRoot) -notmatch '^TradeChannel-worker-fixture-[a-f0-9]{32}$'){throw '隔离验证仅接受可信临时数据根。'}
        $jobRoot=$fixtureRoot+'\Product\jobs\'
    }else{$jobRoot=[IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'TradeChannel\Product\jobs'))+'\'}
    foreach($p in @($RequestPath,$ResultPath)){if(-not([IO.Path]::GetFullPath($p)).StartsWith($jobRoot,[StringComparison]::OrdinalIgnoreCase)){throw '无效的任务目录。'}}
    $request=Get-Content -LiteralPath $RequestPath -Encoding UTF8 -Raw|ConvertFrom-Json
    Import-Module (Join-Path $PSScriptRoot 'RuntimeBridge.psm1') -Force -DisableNameChecking
    if($IsolatedTest){
        if([string]$request.Action -notin @('Overview','Nodes','LineProfiles','LineRegister','Preferences','RuntimeReport','InstallationInfo','DeploymentCenter','OperationHistory','HistoryClearPreview','HistoryClearCommit','HistoryRestore','DeploymentDiscover','DeploymentGet','DeploymentCreate','ServerList','ServerImportLegacy','PairInviteInspect','PairGrantInspect','PairRequestInspect','PairRequestCreate','PairComplete','ConfigurationRollbackPreview','ConfigurationRollbackPrepare','ConfigurationRollbackApply')){throw '隔离验证禁止生产会话或网络变更动作。'}
        $null=Initialize-TCIsolatedReadContext -Root $fixtureRoot
    }
    $paths=Get-TCProductPaths
    if(Test-Path -LiteralPath (Join-Path $PSScriptRoot 'NodeStore.psm1')){Import-Module (Join-Path $PSScriptRoot 'NodeStore.psm1') -Force -DisableNameChecking}
    if(Test-Path -LiteralPath (Join-Path $PSScriptRoot 'ServerSetup.psm1')){Import-Module (Join-Path $PSScriptRoot 'ServerSetup.psm1') -Force -DisableNameChecking}
    Import-Module (Join-Path $PSScriptRoot 'Startup.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'InstallerSetup.psm1') -Force -DisableNameChecking
    $taskReference=$null
    if($request.Action -in @('DeploymentAttach','DeploymentProceed','DeploymentPoll')){$taskReference=@{RunId=[string]$request.RunId}}
    elseif($request.Action -eq 'LinuxStart' -and $request.PSObject.Properties['ParentJobId'] -and $request.ParentJobId){$taskReference=@{SourceJobId=[string]$request.ParentJobId}}
    elseif($request.Action -eq 'LinuxComplete'){$taskReference=@{SourceJobId=[string]$request.Id}}
    elseif($request.Action -eq 'PairComplete'){
        Import-Module (Join-Path $PSScriptRoot 'DeploymentFlow.psm1') -DisableNameChecking
        $prior=@(Get-TCDeploymentRuns -Root $paths.Root|Where-Object {$_.PSObject.Properties['EnrollmentId'] -and $_.EnrollmentId -ceq [string]$request.EnrollmentId})|Select-Object -First 1
        if($prior){$taskReference=@{RunId=$prior.RunId}}
    }
    if($taskReference){
        Import-Module (Join-Path $PSScriptRoot 'ServerRegistry.psm1') -DisableNameChecking
        $server=Assert-TCServerTaskActive -Root $paths.Root @taskReference
        if($server -and $request.Action -notin @('DeploymentAttach','DeploymentProceed','DeploymentPoll')){$serverTaskLease=Open-TCServerTaskLease -Root $paths.Root -ServerId $server.LocalRecordId}
    }
    switch([string]$request.Action){
        'Overview' {
            $data=Get-TCOverview
            Import-Module (Join-Path $PSScriptRoot 'RuntimeObservability.psm1') -DisableNameChecking
            try{$null=Observe-TCRuntimeState -Root $paths.Root -Overview $data}catch{$data|Add-Member NoteProperty ObservationWarning '运行事件记录暂不可用，当前连接状态仍按实际查询结果显示。' -Force}
            $runtimeEvidence=$null
            try{$runtimeModule=Get-Module RuntimeBridge;$runtimeEvidence=& $runtimeModule {Get-TCRuntimeSnapshot}}catch{}
            $data|Add-Member NoteProperty RuntimeEvidence ([pscustomobject]@{State=$(if($runtimeEvidence){$runtimeEvidence.State}else{'Unknown'});Source='RuntimeSnapshot'}) -Force
        }
        'RuntimeReport' {Import-Module (Join-Path $PSScriptRoot 'RuntimeObservability.psm1') -DisableNameChecking;$data=Get-TCRuntimeReport -Root $paths.Root -Overview (Get-TCOverview)}
        'InstallationInfo' {Import-Module (Join-Path $PSScriptRoot 'InstallationDiscovery.psm1') -DisableNameChecking;$data=Get-TCInstallationInfo -PackageRoot $PSScriptRoot -Root $paths.Root}
        'ConfigurationRollbackPreview' {Import-Module (Join-Path $PSScriptRoot 'ConfigurationRecovery.psm1') -DisableNameChecking;$data=Get-TCConfigurationRollbackPreview -Root $paths.Root -NodeId ([string]$request.NodeId)}
        'ConfigurationRollbackPrepare' {Import-Module (Join-Path $PSScriptRoot 'ConfigurationRecovery.psm1') -DisableNameChecking;$data=Prepare-TCConfigurationRollback -Root $paths.Root -NodeId ([string]$request.NodeId) -PreviewToken ([string]$request.PreviewToken)}
        'ConfigurationRollbackApply' {Import-Module (Join-Path $PSScriptRoot 'ConfigurationRecovery.psm1') -DisableNameChecking;$data=Restore-TCNodeConfiguration -Root $paths.Root -NodeId ([string]$request.NodeId) -PreviewToken ([string]$request.PreviewToken)}
        'DeploymentDiscover' {Import-Module (Join-Path $PSScriptRoot 'DeploymentFlow.psm1') -DisableNameChecking;$data=Get-TCDeploymentDiscovery -Root $paths.Root}
        'DeploymentCenter' {Import-Module (Join-Path $PSScriptRoot 'OperationHistory.psm1') -DisableNameChecking;$data=Get-TCDeploymentCenter -Root $paths.Root}
        'OperationHistory' {Import-Module (Join-Path $PSScriptRoot 'OperationHistory.psm1') -DisableNameChecking;$data=@(Get-TCOperationHistory -Root $paths.Root -IncludeHidden:([bool]$request.IncludeHidden))}
        'HistoryClearPreview' {Import-Module (Join-Path $PSScriptRoot 'OperationHistory.psm1') -DisableNameChecking;$parameters=@{Root=$paths.Root};if($request.Ids){$parameters.Ids=[string[]]@($request.Ids)};$data=New-TCHistoryClearPreview @parameters}
        'HistoryClearCommit' {Import-Module (Join-Path $PSScriptRoot 'OperationHistory.psm1') -DisableNameChecking;$data=Clear-TCOperationHistory -Root $paths.Root -PreviewToken ([string]$request.PreviewToken)}
        'HistoryRestore' {Import-Module (Join-Path $PSScriptRoot 'OperationHistory.psm1') -DisableNameChecking;$data=Restore-TCOperationHistory -Root $paths.Root -Id ([string]$request.Id)}
        'DeploymentGet' {Import-Module (Join-Path $PSScriptRoot 'DeploymentFlow.psm1') -DisableNameChecking;$data=Get-TCDeploymentRun -Root $paths.Root -RunId ([string]$request.RunId)}
        'DeploymentCreate' {
            Import-Module (Join-Path $PSScriptRoot 'DeploymentFlow.psm1') -DisableNameChecking
            Import-Module (Join-Path $PSScriptRoot 'DeploymentStore.psm1') -DisableNameChecking
            Assert-TCDFields $request @('Action','Intent','ServerId','Connection','Name','Transport','TcpPort','ServerName','TemplateNodeId','ReuseSourceRunId','IdentitySessionRef','IdentityTargetToken')
            $data=New-TCDeploymentRun -Root $paths.Root -Intent ([string]$request.Intent) -ServerId ([string](Get-TCDField $request ServerId '')) -Connection (Get-TCDField $request Connection) -Name ([string]$request.Name) -Transport ([string](Get-TCDField $request Transport 'Auto')) -TcpPort ([int]$request.TcpPort) -ServerName ([string]$request.ServerName) -TemplateNodeId ([string](Get-TCDField $request TemplateNodeId '')) -ClientInspection (Get-TCClientInspection) -ReuseSourceRunId ([string](Get-TCDField $request ReuseSourceRunId '')) -IdentitySessionRef (Get-TCDField $request IdentitySessionRef) -IdentityTargetToken ([string](Get-TCDField $request IdentityTargetToken ''))
        }
        'DeploymentAttach' {Import-Module (Join-Path $PSScriptRoot 'DeploymentFlow.psm1') -DisableNameChecking;$data=Set-TCDeploymentSession -Root $paths.Root -RunId ([string]$request.RunId) -SessionRef $request.SessionRef}
        'DeploymentAccessState' {
            Import-Module (Join-Path $PSScriptRoot 'DeploymentFlow.psm1') -DisableNameChecking
            Import-Module (Join-Path $PSScriptRoot 'DeploymentStore.psm1') -DisableNameChecking
            Assert-TCDFields $request @('Action','RunId','SessionRef','AttemptOnly') @('Action','RunId','SessionRef')
            $data=Set-TCDeploymentAccessState -Root $paths.Root -RunId ([string]$request.RunId) -SessionRef $request.SessionRef -AttemptOnly:([bool](Get-TCDField $request AttemptOnly $false))
        }
        'DeploymentProceed' {
            Import-Module (Join-Path $PSScriptRoot 'DeploymentFlow.psm1') -DisableNameChecking
            Import-Module (Join-Path $PSScriptRoot 'DeploymentStore.psm1') -DisableNameChecking
            Assert-TCDFields $request @('Action','RunId','Command','ApprovedChangeDigest','InterfaceIndex') @('Action','RunId','Command')
            $parameters=@{Root=$paths.Root;RunId=[string]$request.RunId;Command=[string]$request.Command;ApprovedChangeDigest=[string](Get-TCDField $request ApprovedChangeDigest '')}
            if($request.PSObject.Properties['InterfaceIndex']){if($request.Command -cne 'Probe'){throw '检测网卡只用于本机候选检查。'};$parameters.InterfaceIndex=[int]$request.InterfaceIndex}
            $data=Invoke-TCDeploymentAdvance @parameters
        }
        'DeploymentPoll' {Import-Module (Join-Path $PSScriptRoot 'DeploymentFlow.psm1') -DisableNameChecking;$data=Sync-TCDeploymentRun -Root $paths.Root -RunId ([string]$request.RunId)}
        'ServerList' {Import-Module (Join-Path $PSScriptRoot 'ServerRegistry.psm1') -DisableNameChecking;$data=@(Get-TCServers -Root $paths.Root)}
        'ServerImportLegacy' {Import-Module (Join-Path $PSScriptRoot 'ServerRegistry.psm1') -DisableNameChecking;$data=Import-TCLegacyServerIndex -Root $paths.Root}
        'ServerIdentityTrustPreview' {Import-Module (Join-Path $PSScriptRoot 'ServerRegistry.psm1') -DisableNameChecking;$data=New-TCServerIdentityTrustPreview -Root $paths.Root -ServerId $request.ServerId -SessionRef $request.SessionRef -VerificationToken $request.VerificationToken}
        'ServerIdentityAssessment' {
            Import-Module (Join-Path $PSScriptRoot 'ServerRegistry.psm1') -DisableNameChecking
            $parameters=@{Root=$paths.Root;ServerId=$request.ServerId;SessionRef=$request.SessionRef}
            if($request.ApprovalToken){$parameters.ApprovalToken=$request.ApprovalToken}else{$parameters.VerificationToken=$request.VerificationToken}
            $data=New-TCServerIdentityAssessment @parameters
        }
        'ServerIdentityTransition' {Import-Module (Join-Path $PSScriptRoot 'ServerRegistry.psm1') -DisableNameChecking;$data=Confirm-TCServerIdentityTransition -Root $paths.Root -ServerId $request.ServerId -SessionRef $request.SessionRef -AssessmentToken $request.AssessmentToken -ConfirmedFingerprint $request.ConfirmedFingerprint -ApprovedChangeDigest $request.ApprovedChangeDigest -DeclaredApplicationReset:([bool]$request.DeclaredApplicationReset)}
        'PairGrantInspect' {Import-Module (Join-Path $PSScriptRoot 'DeploymentPairing.psm1') -DisableNameChecking;$data=Resolve-TCPairEnrollment -Root $paths.Root -EncryptedAuthorization ([string]$request.EncryptedAuthorization)}
        'ServerReinstallPreview' {
            Import-Module (Join-Path $PSScriptRoot 'ServerRegistry.psm1') -DisableNameChecking
            Import-Module (Join-Path $PSScriptRoot 'DeploymentStore.psm1') -DisableNameChecking
            Assert-TCDFields $request @('Action','ServerId','SessionRef','VerificationToken') @('Action','ServerId','SessionRef','VerificationToken')
            $data=New-TCServerReinstallPreview -Root $paths.Root -ServerId $request.ServerId -SessionRef $request.SessionRef -VerificationToken $request.VerificationToken
        }
        'ServerReinstallConfirm' {
            Import-Module (Join-Path $PSScriptRoot 'ServerRegistry.psm1') -DisableNameChecking
            Import-Module (Join-Path $PSScriptRoot 'DeploymentStore.psm1') -DisableNameChecking
            Assert-TCDFields $request @('Action','ServerId','SessionRef','ApprovalToken','ConfirmedFingerprint','ApprovedChangeDigest') @('Action','ServerId','SessionRef','ApprovalToken','ConfirmedFingerprint','ApprovedChangeDigest')
            $data=Confirm-TCServerReinstallRecord -Root $paths.Root -ServerId $request.ServerId -SessionRef $request.SessionRef -ApprovalToken $request.ApprovalToken -ConfirmedFingerprint $request.ConfirmedFingerprint -ApprovedChangeDigest $request.ApprovedChangeDigest
        }
        'PairInviteInspect' {Import-Module (Join-Path $PSScriptRoot 'DeploymentPairing.psm1') -DisableNameChecking;$data=Get-TCPairInvite -Invite ([string]$request.Invite) -AllowUnconfirmed}
        'PairRequestCreate' {Import-Module (Join-Path $PSScriptRoot 'DeploymentPairing.psm1') -DisableNameChecking;$data=New-TCPairRequest -Invite ([string]$request.Invite) -ConfirmedFingerprint ([string]$request.ConfirmedFingerprint) -DeviceName ([string]$request.DeviceName) -Root $paths.Root -WgPath $paths.Wg}
        'PairRequestInspect' {Import-Module (Join-Path $PSScriptRoot 'DeploymentPairing.psm1') -DisableNameChecking;$data=Get-TCPairRequestInfo -PairRequest ([string]$request.PairRequest)}
        'PairComplete' {
            Import-Module (Join-Path $PSScriptRoot 'DeploymentFlow.psm1') -DisableNameChecking
            Import-Module (Join-Path $PSScriptRoot 'DeploymentStore.psm1') -DisableNameChecking
            $name=[string](Get-TCDField $request Name '新授权线路')
            $data=Complete-TCPairCandidate -Root $paths.Root -EnrollmentId ([string]$request.EnrollmentId) -EncryptedAuthorization ([string]$request.EncryptedAuthorization) -Name $name -ClientInspection (Get-TCClientInspection)
        }
        'CandidateProbe' {Import-Module (Join-Path $PSScriptRoot 'CandidateProbe.psm1') -DisableNameChecking;$data=Test-TCCandidateProbe -Root $paths.Root -NodeId ([string]$request.NodeId)}
        'Preferences' {$data=Get-TCPreferences;$startup=Get-TCStartup;$data.OpenAtLogin=[bool]$startup.Enabled}
        'SavePreferences' {
            # Only fields the console sent are saved; older consoles omit Daily and the assistant list.
            $values=@{};foreach($key in @('Mode','Exit','Daily','Agents','ProviderId','TradeProviderId')){if($request.PSObject.Properties[$key] -and ($request.$key -or $key -in @('ProviderId','TradeProviderId'))){$values[$key]=[string]$request.$key}}
            if($request.PSObject.Properties['NodeId']){$values.NodeId=$request.NodeId}
            if($request.PSObject.Properties['ProfileId']){$values.ProfileId=[string]$request.ProfileId}
            if($request.PSObject.Properties['AgentIds']){$values.AgentIds=[string[]]@($request.AgentIds|Where-Object {$_})}
            if($request.PSObject.Properties['AgentCustom']){$values.AgentCustom=[object[]]@($request.AgentCustom|Where-Object {$_})}
            $data=Save-TCPreferences @values
        }
        'Session' {
            $values=@{Action=[string]$request.SessionAction}
            foreach($key in @('Mode','Exit','Daily','Agents','ProviderId','TradeProviderId')){if($request.PSObject.Properties[$key] -and ($request.$key -or $key -in @('ProviderId','TradeProviderId'))){$values[$key]=[string]$request.$key}}
            if($request.PSObject.Properties['NodeId']){$values.NodeId=$request.NodeId}
            if($request.PSObject.Properties['AgentIds']){$values.AgentIds=[string[]]@($request.AgentIds|Where-Object {$_})}
            if($request.PSObject.Properties['AgentCustom']){$values.AgentCustom=[object[]]@($request.AgentCustom|Where-Object {$_})}
            $data=Invoke-TCSession @values
        }
        'Agents' {$data=Get-TCAgentOverview}
        {$_ -in @('Providers','ProviderRegister','ProviderPrepare','ProviderRestore','ProviderCheck','ProviderUpdate','ProviderRemove')} {
            Import-Module (Join-Path $PSScriptRoot 'ProviderBridge.psm1') -Force -DisableNameChecking
            $data=Invoke-TCProviderRequest -Request $request -Root $paths.Root
        }
        'TradeDomains' {Import-Module (Join-Path $PSScriptRoot 'ManagementStore.psm1') -Force;$data=Get-TCTradeDomainManagement -Root $paths.Root}
        'TradeDomainEdit' {Import-Module (Join-Path $PSScriptRoot 'ManagementStore.psm1') -Force;$data=Set-TCTradeDomainManagement -Root $paths.Root -Operation ([string]$request.Operation) -Domain ([string]$request.Domain)}
        'UpgradeActive' {$data=Update-TCActivePolicy}
        'StartupStatus' {$data=Get-TCStartup}
        'SetStartup' {$data=Set-TCStartup -Enabled ([bool]$request.Enabled) -SourceDirectory $PSScriptRoot}
        'DesktopShortcut' {$data=& (Join-Path $PSScriptRoot 'Create-DesktopShortcut.ps1')}
        'InspectClient' {$data=Get-TCClientInspection}
        'InspectServer' {$data=Get-TCServerInspection}
        {$_ -in @('LinuxStart','LinuxPoll','LinuxComplete','LinuxRecent','LinuxTasks','LinuxArchive')} {
            Import-Module (Join-Path $PSScriptRoot 'LinuxServerSetup.psm1') -Force -DisableNameChecking
            $data=Invoke-TCLinuxRequest -Request $request -Root $paths.Root
        }
        'Nodes' {Import-Module (Join-Path $PSScriptRoot 'LineStore.psm1') -DisableNameChecking;$data=@(Get-TCLineCards -Root $paths.Root)}
        'LineProfiles' {Import-Module (Join-Path $PSScriptRoot 'LineStore.psm1') -DisableNameChecking;$data=Get-TCLine -Root $paths.Root -Id ([string]$request.Id)}
        'DeploymentCancelProbe' {Import-Module (Join-Path $PSScriptRoot 'DeploymentFlow.psm1') -DisableNameChecking;$data=Request-TCDeploymentProbeStop -Root $paths.Root -RunId ([string]$request.RunId)}
        'LineRegister' {Import-Module (Join-Path $PSScriptRoot 'LineStore.psm1') -DisableNameChecking;$data=Register-TCLineProfiles -Root $paths.Root -Id ([string]$request.Id)}
        'LinePreference' {Import-Module (Join-Path $PSScriptRoot 'LineStore.psm1') -DisableNameChecking;$data=Set-TCLinePreferredProfile -Root $paths.Root -Id ([string]$request.Id) -ProfileId ([string]$request.ProfileId)}
        'ConnectionDefaultPreview' {Import-Module (Join-Path $PSScriptRoot 'ConnectionTransactions.psm1') -DisableNameChecking;$data=Get-TCDefaultConnectionSwitchPreview -Root $paths.Root -LineId ([string]$request.LineId)}
        'ConnectionSwitchPreview' {Import-Module (Join-Path $PSScriptRoot 'ConnectionTransactions.psm1') -DisableNameChecking;$data=Get-TCConnectionSwitchPreview -Root $paths.Root -LineId ([string]$request.LineId) -ProfileId ([string]$request.ProfileId)}
        'ConnectionTransactionReconcile' {Import-Module (Join-Path $PSScriptRoot 'ConnectionTransactions.psm1') -DisableNameChecking;$rows=@(Reconcile-TCConnectionTransactions -Root $paths.Root -ResolveStopped);$data=[pscustomobject]@{Results=$rows;Resolved=(@($rows|Where-Object Status -ne 'ResolvedStopped').Count -eq 0);NetworkOperationRequested=$false}}
        'ConnectionSwitchCommit' {Import-Module (Join-Path $PSScriptRoot 'ConnectionTransactions.psm1') -DisableNameChecking;$data=Invoke-TCConnectionSwitch -Root $paths.Root -LineId ([string]$request.LineId) -ProfileId ([string]$request.ProfileId) -PreviewToken ([string]$request.PreviewToken)}
        'DeleteNode' {
            Import-Module (Join-Path $PSScriptRoot 'NodeStore.psm1') -Force -DisableNameChecking
            $data = Remove-TCNode -Root $paths.StoreRoot -Id ([string]$request.Id)
        }
        'RenameNode' {
            Import-Module (Join-Path $PSScriptRoot 'NodeStore.psm1') -Force -DisableNameChecking
            $data = Rename-TCNode -Root $paths.StoreRoot -Id ([string]$request.Id) -Name ([string]$request.Name)
        }
        'DiagnoseNode' {
            Import-Module (Join-Path $PSScriptRoot 'Diagnostics.psm1') -Force -DisableNameChecking
            $data=Test-TCNodeDiagnostics -Root $paths.StoreRoot -Id ([string]$request.Id)
        }
        'TransportInfo' {$data=Get-TCTransportInfo -Root $paths.StoreRoot -Id ([string]$request.Id)}
        'MaintenanceReport' {Import-Module (Join-Path $PSScriptRoot 'Maintenance.psm1') -Force -DisableNameChecking;$data=Get-TCMaintenanceReport -Root $paths.Root}
        'RepairState' {Import-Module (Join-Path $PSScriptRoot 'Maintenance.psm1') -Force -DisableNameChecking;$data=Repair-TCClientState -Root $paths.Root -ClearProviders:([bool]$request.ClearProviders)}
        'ExportDiagnostics' {Import-Module (Join-Path $PSScriptRoot 'Maintenance.psm1') -Force -DisableNameChecking;$data=Export-TCClientDiagnostics -Root $paths.Root -Destination ([string]$request.Path)}
        'SetTransportMode' {
            Import-Module (Join-Path $PSScriptRoot 'NodeStore.psm1') -Force -DisableNameChecking
            $params = @{}
            if ($request.TransportParams) {
                foreach ($p in $request.TransportParams.PSObject.Properties) { $params[$p.Name] = $p.Value }
            }
            $data = Set-TCTransportMode -Root $paths.StoreRoot -Id ([string]$request.Id) -Mode ([string]$request.Mode) -TransportParams $params
        }
        'ResetHostKey' {
            Import-Module (Join-Path $PSScriptRoot 'LinuxServerSetup.psm1') -Force -DisableNameChecking
            $data = Reset-TCLinuxHostKey -ServerHost ([string]$request.Host) -Port $(if($request.Port){[int]$request.Port}else{22}) -Root $paths.Root
        }
        'Adopt' {
            $d=Get-TCInstalledDeployment;if(-not $d){throw '没有找到可接管的本机通道。请选择导入配置。'}
            $data=Register-TCExisting -Root $paths.StoreRoot -ManifestPath $d.ManifestPath -Name ([string]$request.Name)
        }
        'ImportNode' {
            $providers=@();$warnings=@()
            if($request.UseProvider){
                Import-Module (Join-Path $PSScriptRoot 'ProviderBridge.psm1') -Force -DisableNameChecking
                $selection=Select-TCImportProviders -Root $paths.Root -Programs ([string[]]@($request.Programs)) -SkipUnavailable:([bool]$request.SkipUnavailableProviders)
                $providers=@($selection.Providers);$warnings=@($selection.Warnings)
            }
            $data=Import-TCWireGuard -Root $paths.StoreRoot -Path ([string]$request.Path) -Name ([string]$request.Name) -EnginePath $paths.Engine -WgPath $paths.Wg -TradeProgramPaths ([string[]]@($request.Programs)) -DirectDnsIPv4 ([string]$request.Dns) -Providers $providers
            $data|Add-Member NoteProperty ImportWarnings $warnings -Force
        }
        'ActivateNode' {
            $node=@(Get-TCNodes -Root $paths.StoreRoot|Where-Object {$_.id -eq [string]$request.Id})
            if($node.Count -ne 1 -or -not $node[0].manifestPath){throw '该节点尚未具备可启用配置。请先完成授权并导入客户端配置。'}
            $data=Enable-TCNode -ManifestPath $node[0].manifestPath
        }
        'Command' {$data=@(Invoke-TCCommand -Action ([string]$request.Command))}
        'CheckActive' {$data=Test-TCActiveConnection}
        'AutoTransportContext' {Import-Module (Join-Path $PSScriptRoot 'AutoTransport.psm1') -DisableNameChecking;$data=Get-TCTransportPreparation -Root $paths.Root -Id ([string]$request.Id);$credentialAvailable=$false;if($data.ServerId){Import-Module (Join-Path $PSScriptRoot 'ServerRegistry.psm1') -DisableNameChecking;$record=Get-TCServer -Root $paths.Root -Id $data.ServerId;$credentialAvailable=[bool]$record.CredentialRef};$data|Add-Member NoteProperty CredentialAvailable $credentialAvailable -Force}
        'AutoTransportBind' {
            Import-Module (Join-Path $PSScriptRoot 'AutoTransport.psm1') -DisableNameChecking
            Import-Module (Join-Path $PSScriptRoot 'ServerRegistry.psm1') -DisableNameChecking
            $info=Get-TCTransportPreparation -Root $paths.Root -Id ([string]$request.Id)
            $connection=@{Host=$info.DefaultServer;Port=[int]$request.Port;User=[string]$request.User}
            if($info.ServerId){$data=Set-TCServerRecord -Root $paths.Root -Id $info.ServerId -Connection $connection -Name $info.Name}
            else{$data=Set-TCServerRecord -Root $paths.Root -Connection $connection -Name $info.Name}
        }
        'AutoTransportSaved' {Import-Module (Join-Path $PSScriptRoot 'AutoTransport.psm1') -DisableNameChecking;$info=Get-TCSavedTransportInfo -Root $paths.Root -Id ([string]$request.Id);$data=New-TCAutomaticTransportCandidate -Root $paths.Root -Id ([string]$request.Id) -TransportInfo $info}
        'AutoTransportPrepare' {Import-Module (Join-Path $PSScriptRoot 'AutoTransport.psm1') -DisableNameChecking;$data=New-TCAutomaticTransportCandidate -Root $paths.Root -Id ([string]$request.Id) -TransportInfo $request.TransportInfo}
        'LineRecovery' {Import-Module (Join-Path $PSScriptRoot 'LineRecovery.psm1') -DisableNameChecking;$data=Get-TCConnectionRecovery -Root $paths.Root -Id ([string]$request.Id)}
        'RemoveProtection' {$data=Remove-TCClientProtection}
        'ExportSettings' {$data=Export-TCSettings -Root $paths.StoreRoot -Destination ([string]$request.Path)}
        'ImportSettings' {$data=Import-TCSettings -Root $paths.StoreRoot -Path ([string]$request.Path)}
        'ServerPlan' {$data=New-TCServerPlan -PublicEndpoint ([string]$request.Endpoint) -Name ([string]$request.Name) -InterfaceAlias ([string]$request.InterfaceAlias) -TunnelSubnet ([string]$request.Subnet)}
        'ServerApply' {$data=Invoke-TCServerPlan -PlanPath ([string]$request.Path) -WgPath $paths.Wg}
        'DeviceRequest' {$data=New-TCClientRequest -OutputDirectory ([string]$request.Path) -WgPath $paths.Wg}
        'ServerAuthorize' {$data=Add-TCServerDevice -RequestPath ([string]$request.Path) -ClientAddress ([string]$request.Address)}
        'CompleteClient' {$data=Complete-TCClientConfig -RequestDirectory ([string]$request.RequestDirectory) -ResponsePath ([string]$request.Path) -Destination ([string]$request.Destination)}
        'InstallWireGuard' {
            $source=if($request.Source){[string]$request.Source}else{'Bundled'}
            $data=Invoke-TCWireGuardInstall -Source $source -PackageRoot $PSScriptRoot -Root $paths.Root
        }
        default {throw '不支持的操作。'}
    }
    $result=[ordered]@{Ok=$true;Action=$request.Action;Data=$data;Message='操作完成';At=(Get-Date).ToString('o')}
}catch{
    $message=$_.Exception.Message
    $message=$message -replace '(?i)(privatekey|private_key|password|presharedkey)\s*[=:]\s*\S+','$1=<隐藏>'
    $message=$message -replace '[A-Za-z0-9+/]{43}=','<密钥已隐藏>'
    $result=[ordered]@{Ok=$false;Action=$(if($request){$request.Action}else{'Unknown'});Message=$message;At=(Get-Date).ToString('o')}
}finally{if($serverTaskLease){$serverTaskLease.Dispose()}}
[IO.File]::WriteAllText($ResultPath,($result|ConvertTo-Json -Depth 18),(New-Object Text.UTF8Encoding($true)))
