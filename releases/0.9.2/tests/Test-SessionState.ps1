#requires -Version 5.1
$ErrorActionPreference='Stop'
# Every runtime dependency below is mocked before use. No production state,
# controller, WFP, proxy, scheduled task, engine or supervisor is touched.
$root=Join-Path ([IO.Path]::GetTempPath()) ('TC-SessionState-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($root)
$module=Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'RuntimeBridge.psm1') -Force -PassThru -DisableNameChecking
try{
    $bridgeChecks=& $module {
        param($testRoot)
        $script:Root=$testRoot;$script:Checks=0
        $script:PreferenceWrites=0;$script:SessionTextWriter=${function:Write-TCSessionText}
        function script:Write-TCSessionText {
            param([string]$Path,[string]$Text)
            if(Test-TCSamePath $Path (Join-Path $script:Root 'ui-preferences.json')){$script:PreferenceWrites++}
            & $script:SessionTextWriter $Path $Text
        }
        $script:Boot=(Get-Date).ToUniversalTime().AddHours(-3)
        $script:SessionStart=(Get-Date).ToUniversalTime().AddSeconds(-20)
        $script:ApiFails=$false;$script:InventoryFails=$false;$script:NinjaBusy=$false;$script:ApiCalls=0
        $script:ConfigPath=Join-Path $testRoot 'config.json';$script:ManifestPath=Join-Path $testRoot 'manifest.json'
        $script:EnginePath=Join-Path $testRoot 'sing-box.exe'
        $script:NodeA='11111111-1111-1111-1111-111111111111';$script:NodeB='22222222-2222-2222-2222-222222222222'
        Write-TCSessionJson $script:ConfigPath @{outbounds=@(@{tag='trade-exit'})}
        Write-TCSessionJson $script:ManifestPath @{CandidatePath=$script:ConfigPath;EnginePath=$script:EnginePath;SyntaxValidated=$true;DeploymentApproved=$true;TradeProgramPaths=@('C:\Mock\NinjaTrader.exe');ProviderProgramPaths=@('C:\Mock\provider.exe');ProviderDirectory='C:\Mock';ProviderSocksPort=10823;ServerEndpoint='192.0.2.1:12345'}
        Write-TCSessionJson (Join-Path $testRoot 'deployment.json') @{ManifestPath=$script:ManifestPath}
        Copy-Item -LiteralPath $script:ManifestPath -Destination (Join-Path $testRoot 'other.json')
        $null=[IO.Directory]::CreateDirectory((Join-Path $testRoot 'Product'))
        Write-TCSessionJson (Join-Path $testRoot 'Product\index.json') @{nodes=@(@{id=$script:NodeA;name='测试节点 A';manifestPath=$script:ManifestPath},@{id=$script:NodeB;name='测试节点 B';manifestPath=(Join-Path $testRoot 'other.json')})}
        function script:Assert-Session {param([bool]$Condition,[string]$Message)if(-not $Condition){throw ('Session regression: '+$Message)};$script:Checks++}
        function script:Assert-Rejected {param([scriptblock]$Operation,[string]$Message)$failed=$false;try{& $Operation|Out-Null}catch{$failed=$true};Assert-Session $failed $Message}
        function script:Get-TCBootTime {$script:Boot}
        function script:Get-TCProcessInventory {param($Manifest)if($script:InventoryFails){throw 'Injected inventory failure'};@($script:Inventory)}
        function script:Get-Process {param($Name,$Id,$ErrorAction)if($Name -eq 'NinjaTrader' -and $script:NinjaBusy){[pscustomobject]@{Name='NinjaTrader'}}}
        function script:Get-TCGuardApplicationId {param($Path)'\device\mock\ninjatrader.exe'}
        function script:Get-TCGuardSnapshot {$script:Guard}
        function script:Get-TCProviderStatus {param($Manifest)$null}
        function script:Invoke-TCController {
            param($Manifest,$Path,$Method,$Body)
            $script:ApiCalls++
            if($script:ApiFails){throw 'Injected API unavailable'}
            switch($Path){
                '/configs' {if($script:OmitModes){[pscustomobject]@{mode=$script:ActualMode}}else{[pscustomobject]@{mode=$script:ActualMode;'mode-list'=$script:ControllerModes}}}
                '/proxies/trade-exit' {[pscustomobject]@{now=$script:ActualExit}}
                '/proxies/daily-exit' {[pscustomobject]@{now=$script:ActualDaily}}
                '/connections' {
                    if($script:ExitDuringRead){$script:Inventory=@()}
                    [pscustomobject]@{connections=@(@{id='mock-connection'})}
                }
                default {throw 'Unexpected controller request'}
            }
        }
        function script:Start-Process {throw 'Unmocked process start forbidden'}
        function script:Stop-Process {throw 'Unmocked process stop forbidden'}
        function script:Set-ItemProperty {throw 'Registry mutation forbidden'}
        function script:Remove-ItemProperty {throw 'Registry mutation forbidden'}
        function script:Register-ScheduledTask {throw 'Task mutation forbidden'}
        function script:Reset-Session {
            $marker=Join-Path $script:Root 'stop.request';if(Test-Path -LiteralPath $marker){Remove-Item -LiteralPath $marker}
            $script:ApiFails=$false;$script:InventoryFails=$false;$script:ExitDuringRead=$false;$script:NinjaBusy=$false
            $script:ActualMode='rule';$script:ActualExit='hk';$script:ActualDaily='direct';$script:FailMode=$false
            $script:ControllerModes=@('rule','global');$script:OmitModes=$false;$script:FailModeAfterApply=$false;$script:ModeFailureApiFails=$false;$script:ModeFailureReplacesEngine=$false
            $script:Snapshot=[pscustomobject]@{State='Running';SupervisorPid=4101;EnginePid=4102;ManifestPath=$script:ManifestPath;ConfigPath=$script:ConfigPath;StartedAt=$script:SessionStart.ToString('o');SupervisorStartedAt=$script:SessionStart.AddMilliseconds(-100).ToString('o');EngineStartedAt=$script:SessionStart.AddSeconds(1).ToString('o');BootStartedAt=$script:Boot.ToString('o');Error=$null;CleanupError=$false}
            $script:Inventory=@(
                [pscustomobject]@{ProcessId=4101;Name='powershell.exe';ExecutablePath='C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe';CommandLine=('powershell.exe -File "C:\legacy\tools\Run-TradeChannel.ps1" -ManifestPath "'+$script:ManifestPath+'"');CreationDate=$script:SessionStart.AddMilliseconds(-100);ParentProcessId=1},
                [pscustomobject]@{ProcessId=4102;Name='sing-box.exe';ExecutablePath=$script:EnginePath;CommandLine=('sing-box.exe run -c "'+$script:ConfigPath+'"');CreationDate=$script:SessionStart.AddSeconds(1);ParentProcessId=4101}
            )
            $script:Guard=[pscustomobject]@{ProviderPresent=$true;InfrastructureVerified=$true;Filters=@(foreach($family in @('IPv4','IPv6')){[pscustomobject]@{ApplicationId='\device\mock\ninjatrader.exe';Family=$family;Recognized=$true;IsBlock=$true;IsPersistent=$true;IsDisabled=$false;IsPermit=$false}})}
            Write-TCSessionJson (Join-Path $script:Root 'runtime.json') $script:Snapshot
        }
        Reset-Session
        $o=Get-TCOverview
        Assert-Session ($o.StateKey -eq 'Connected' -and $o.PrimaryAction -eq 'Disconnect' -and $o.Running -and $o.Mode -eq 'rule' -and $o.Exit -eq 'hk' -and $o.NodeName -eq '测试节点 A') 'healthy current identity + controller must connect'
        Assert-Session ($o.ModeSwitchSupported -and (@($o.ControllerModes) -join ',') -ceq 'rule,global') 'overview exposes modes observed from configs'
        $script:ControllerModes=@('GLOBAL');$script:ActualMode='GLOBAL';$o=Get-TCOverview
        Assert-Session ($o.Running -and -not $o.ModeSwitchSupported -and (@($o.ControllerModes) -join ',') -ceq 'global') 'a global-only engine stays connected with switching unavailable'
        $script:ControllerModes=@('RuLe','GLOBAL','rule');$o=Get-TCOverview
        Assert-Session ($o.ModeSwitchSupported -and (@($o.ControllerModes) -join ',') -ceq 'rule,global') 'controller mode capabilities are canonical and deduplicated'
        $before=$script:ApiCalls;$e=Get-TCSessionEvidence -SkipController
        Assert-Session ($script:ApiCalls -eq $before -and @($e.ControllerModes).Count -eq 0 -and -not $e.ModeSwitchSupported) 'skipped controller does not invent switching support'
        Reset-Session;$o=Get-TCOverview
        Assert-Session ($o.GuardState -eq 'Protected' -and $o.Detail -match '订单需分别检查') 'browser/control success must not attest all trading services'
        Assert-Session (-not $o.DailySupported -and $null -eq $o.Daily -and $o.DesiredDaily -eq 'Direct' -and $o.PolicyVersion -eq 1 -and $o.UpgradeAvailable -and $o.ConnectedSince -and @($o.TradePrograms) -contains 'NinjaTrader.exe') 'v1 line reports upgrade, no daily selector and connection age'
        foreach($field in @('Running','State','Mode','ControllerModes','ModeSwitchSupported','Exit','Connections','ManifestPath','NodeEndpoint','NinjaRunning','ProviderConfigured','Error','ObservedAt','ProtectionNote','StateKey','Title','Detail','PrimaryAction','PrimaryEnabled','DesiredMode','DesiredExit','NodeName','GuardState','GuardSummary','BootRestartDetected','Daily','DailySupported','DesiredDaily','DailyReason','ForeignTunnel','Provider','PolicyVersion','UpgradeAvailable','ConnectedSince','ProxyEvents','TradePrograms','TradeDomains','AgentsSupported','Agents','DesiredAgents','AgentIds','AgentCustom','AgentNames')){Assert-Session ([bool]$o.PSObject.Properties[$field]) ('overview contract field: '+$field)}
        $manifestBefore=[IO.File]::ReadAllText($script:ManifestPath);$manifest=$manifestBefore|ConvertFrom-Json
        $manifest|Add-Member -NotePropertyName PolicyVersion -NotePropertyValue 4 -Force
        Write-TCSessionJson $script:ManifestPath $manifest
        foreach($case in @(
            @{Modes=@('global');Actual='global';Upgrade=$true},
            @{Modes=@('rule');Actual='rule';Upgrade=$true},
            @{Modes=@('RULE','GLOBAL');Actual='rule';Upgrade=$false},
            @{Modes=@();Actual='rule';Upgrade=$false}
        )){
            $script:ControllerModes=$case.Modes;$script:ActualMode=$case.Actual;$o=Get-TCOverview
            Assert-Session ($o.Running -and $o.PolicyVersion -eq 4 -and $o.UpgradeAvailable -eq $case.Upgrade) ('v4 repair availability follows known live modes: '+($case.Modes -join ','))
        }
        $script:OmitModes=$true;$o=Get-TCOverview
        Assert-Session ($o.Running -and -not $o.UpgradeAvailable -and -not $o.ModeSwitchSupported) 'missing mode-list is unknown, not an automatic v4 repair recommendation'
        Reset-Session;$script:Inventory=@();$o=Get-TCOverview
        Assert-Session (-not $o.Running -and -not $o.UpgradeAvailable -and @($o.ControllerModes).Count -eq 0 -and -not $o.ModeSwitchSupported) 'disconnected v4 line does not infer old engine capabilities'
        Write-TCSessionText $script:ManifestPath $manifestBefore;Reset-Session
        $script:Snapshot.BootStartedAt=$script:Boot.AddSeconds(3.5).ToString('o')
        Write-TCSessionJson (Join-Path $script:Root 'runtime.json') $script:Snapshot
        $o=Get-TCOverview
        Assert-Session ($o.Running -and -not $o.BootRestartDetected) 'WMI boot-time drift cannot invalidate two exact live process identities'
        $script:Inventory[1].CreationDate=$script:SessionStart.AddSeconds(1).AddMilliseconds(5)
        Assert-Session (-not (Get-TCOverview).Running) 'boot-time drift exception must not accept a reused engine PID'
        Reset-Session
        $script:Snapshot.BootStartedAt=$script:Boot.AddSeconds(3.5).ToString('o');$script:Snapshot.PSObject.Properties.Remove('EngineStartedAt')
        Write-TCSessionJson (Join-Path $script:Root 'runtime.json') $script:Snapshot
        Assert-Session (-not (Get-TCOverview).Running) 'legacy approximate timestamps cannot override a boot mismatch'
        Reset-Session
        # Pre-0.3 supervisor compatibility relies on birth time, exact arguments,
        # parent PID, boot and both manifest/config paths, not just executable.
        foreach($field in @('SupervisorStartedAt','EngineStartedAt','BootStartedAt')){$script:Snapshot.PSObject.Properties.Remove($field)}
        Write-TCSessionJson (Join-Path $script:Root 'runtime.json') $script:Snapshot
        Assert-Session ((Get-TCOverview).Running) 'registered old supervisor must remain compatible'
        # Other workers can contain literal -File text inside -Command. These
        # are synthetic process records; never enumerate or contact production.
        $legacyInventory=@($script:Inventory)
        $script:Inventory+=,[pscustomobject]@{ProcessId=4901;Name='powershell.exe';ExecutablePath='C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe';CommandLine='powershell.exe -NoProfile -Command "Write-Output -File bad|path"';CreationDate=$script:SessionStart;ParentProcessId=1}
        $o=Get-TCOverview
        Assert-Session ($o.StateKey -eq 'Connected' -and -not $o.Error) 'malformed unrelated PowerShell command must not fault a healthy legacy session'
        $script:Inventory=$legacyInventory+@([pscustomobject]@{ProcessId=4902;Name='pwsh.exe';ExecutablePath='C:\Mock\pwsh.exe';CommandLine='pwsh.exe -Command Write-Output -File "C:\unrelated\Run-TradeChannel.ps1"';CreationDate=$script:SessionStart;ParentProcessId=1})
        Assert-Session ((Get-TCOverview).StateKey -eq 'Connected') 'supervisor filename inside unrelated command payload is not a launched supervisor'
        $script:Inventory=$legacyInventory+@([pscustomobject]@{ProcessId=4903;Name='powershell.exe';ExecutablePath='C:\Mock\powershell.exe';CommandLine='powershell.exe -File "C:\bad|path\Run-TradeChannel.ps1"';CreationDate=$script:SessionStart;ParentProcessId=1})
        Assert-Session ((Get-TCOverview).StateKey -eq 'Connected') 'invalid unrelated host File argument must be ignored without aborting inventory'
        $script:Inventory=$legacyInventory+@([pscustomobject]@{ProcessId=4904;Name='sing-box.exe';ExecutablePath='C:\unrelated\sing-box.exe';CommandLine='sing-box.exe -File bad|path -c "C:\unrelated\config.json"';CreationDate=$script:SessionStart;ParentProcessId=1})
        $o=Get-TCOverview
        Assert-Session ($o.StateKey -eq 'Fault' -and -not $o.CanConnect -and -not $o.Running) 'malformed unrelated sing-box must remain fail closed'
        $script:Inventory=$legacyInventory
        [IO.File]::SetLastWriteTimeUtc((Join-Path $script:Root 'runtime.json'),$script:SessionStart.AddSeconds(2))
        $script:Inventory[1].CreationDate=$script:SessionStart.AddSeconds(3)
        Assert-Session (-not (Get-TCOverview).Running) 'old supervisor PID reuse after record write must be rejected even within startup window'
        Reset-Session
        $script:Snapshot.StartedAt=$script:Boot.AddDays(-1).ToString('o');$script:Snapshot.BootStartedAt=$script:Boot.AddDays(-1).ToString('o');$script:Snapshot.Error='stale error';$script:Inventory=@()
        Write-TCSessionJson (Join-Path $script:Root 'runtime.json') $script:Snapshot
        $before=$script:ApiCalls;$o=Get-TCOverview
        Assert-Session ($o.StateKey -eq 'Disconnected' -and $o.BootRestartDetected -and -not $o.Running -and $null -eq $o.Mode -and $null -eq $o.Exit -and $o.PrimaryAction -eq 'Connect' -and $script:ApiCalls -eq $before) 'cold boot stale Running must disconnect without probing stale API'
        Reset-Session;$script:Inventory=@()
        $o=Get-TCOverview
        Assert-Session ($o.StateKey -eq 'Disconnected' -and -not $o.BootRestartDetected -and $o.CanConnect) 'exited processes cannot inherit Running'
        Reset-Session;$script:Inventory[1].CreationDate=$script:SessionStart.AddMinutes(1)
        $o=Get-TCOverview
        Assert-Session (-not $o.Running -and -not $o.CanConnect -and $null -eq $o.Mode) 'same executable/PID/config with different creation time is PID reuse'
        Reset-Session;$script:Inventory[1].CreationDate=$script:SessionStart.AddSeconds(1).AddMilliseconds(10)
        Assert-Session (-not (Get-TCOverview).Running) 'new identity records must also reject sub-second PID reuse'
        Reset-Session;$script:Inventory[0].CreationDate=$script:SessionStart.AddSeconds(5)
        Assert-Session (-not (Get-TCOverview).Running) 'supervisor PID reuse must not connect'
        Reset-Session;$script:Snapshot.ConfigPath=$script:ConfigPath+'.other'
        Write-TCSessionJson (Join-Path $script:Root 'runtime.json') $script:Snapshot
        Assert-Session (-not (Get-TCOverview).Running) 'snapshot config must match current manifest'
        Reset-Session;$script:Inventory[1].CommandLine='sing-box.exe run -c "C:\foreign\config.json"'
        Assert-Session (-not (Get-TCOverview).Running -and -not (Get-TCOverview).CanConnect) 'engine command-line config must match exactly; unknown engine must block launches'
        Reset-Session;$script:Snapshot.ManifestPath=$script:ManifestPath+'.other'
        Write-TCSessionJson (Join-Path $script:Root 'runtime.json') $script:Snapshot
        Assert-Session (-not (Get-TCOverview).Running) 'snapshot manifest must match deployment'
        Reset-Session;$script:ApiFails=$true
        $o=Get-TCOverview
        Assert-Session ($o.StateKey -eq 'Fault' -and $o.PrimaryAction -eq 'Disconnect' -and $o.PrimaryEnabled -and -not $o.CanConnect -and $null -eq $o.Mode -and $null -eq $o.Exit) 'API unavailable must offer disconnect, never start another instance'
        Assert-Session (@($o.ControllerModes).Count -eq 0 -and -not $o.ModeSwitchSupported) 'unavailable controller does not advertise live mode capabilities'
        Reset-Session;$script:InventoryFails=$true
        Assert-Session ((Get-TCOverview).StateKey -eq 'Fault' -and -not (Get-TCOverview).CanConnect) 'failed inventory read must not mean disconnected'
        Reset-Session;$script:Inventory[1].CommandLine=$null
        Assert-Session ((Get-TCOverview).StateKey -eq 'Fault' -and -not (Get-TCOverview).CanConnect) 'missing engine command line must not mean safe to start'
        Reset-Session;$script:ApiFails=$true;[IO.File]::WriteAllText((Join-Path $script:Root 'stop.request'),'manual')
        Assert-Session ((Get-TCOverview).StateKey -eq 'Disconnecting' -and -not (Get-TCOverview).PrimaryEnabled) 'stop request wins over API failure while a verified owner is stopping'
        [IO.File]::SetLastWriteTimeUtc((Join-Path $script:Root 'stop.request'),(Get-Date).ToUniversalTime().AddMinutes(-1))
        Assert-Session ((Get-TCOverview).StateKey -eq 'Fault' -and (Get-TCOverview).PrimaryAction -eq 'Disconnect' -and (Get-TCOverview).PrimaryEnabled) 'stop timeout must not leave permanent disabled Disconnecting'
        Reset-Session;$script:ExitDuringRead=$true
        Assert-Session ((Get-TCOverview).StateKey -eq 'Disconnected') 'exit between API response and readback must not leave Connected'
        Reset-Session;$script:Guard.Filters[0].IsDisabled=$true
        Assert-Session ((Get-TCOverview).GuardState -eq 'Unprotected') 'Disabled persistent filter is not protection'
        Reset-Session;$script:Guard.Filters[0].ApplicationId='\device\mock\unrelated.exe'
        Assert-Session ((Get-TCOverview).GuardState -eq 'Unprotected') 'unrelated program filter cannot protect Ninja'
        Reset-Session;$script:Guard=$null
        Assert-Session ((Get-TCOverview).GuardState -eq 'Unknown') 'failed guard read is Unknown'
        Reset-Session;$script:Snapshot.State='Starting';$script:Snapshot.EnginePid=$null;$script:Inventory=@($script:Inventory[0])
        Write-TCSessionJson (Join-Path $script:Root 'runtime.json') $script:Snapshot
        $o=Get-TCOverview
        Assert-Session ($o.StateKey -eq 'Connecting' -and -not $o.PrimaryEnabled) 'verified Starting prevents doubleclick'
        $script:Snapshot.State='Stopping';Write-TCSessionJson (Join-Path $script:Root 'runtime.json') $script:Snapshot
        Assert-Session ((Get-TCOverview).StateKey -eq 'Disconnecting') 'verified stopping renders Disconnecting'
        $script:Inventory=@();$script:Snapshot.State='Disconnected';Write-TCSessionJson (Join-Path $script:Root 'runtime.json') $script:Snapshot
        Assert-Session ((Get-TCOverview).StateKey -eq 'Disconnected') 'manual disconnect renders next step'
        $script:Snapshot.State='StoppedWithError';$script:Snapshot.CleanupError=$true;Write-TCSessionJson (Join-Path $script:Root 'runtime.json') $script:Snapshot
        Assert-Session ((Get-TCOverview).StateKey -eq 'Fault') 'cleanup failure is a real fault'
        # Edit-only preferences: preserve omitted fields and every runtime byte.
        Reset-Session
        $runtimeBefore=[IO.File]::ReadAllText((Join-Path $script:Root 'runtime.json'));$deploymentBefore=[IO.File]::ReadAllText((Join-Path $script:Root 'deployment.json'));$apiBefore=$script:ApiCalls
        $null=Save-TCPreferences -Mode Global -Exit Provider -NodeId $script:NodeB
        $null=Save-TCPreferences -Mode Trading
        $p=Get-TCPreferences
        Assert-Session ($p.Mode -eq 'Trading' -and $p.Exit -eq 'Provider' -and $p.NodeId -eq $script:NodeB -and -not $p.OpenAtLogin -and $p.ManualConnect) 'last selected preferences and omitted fields must persist'
        Assert-Session ($script:ApiCalls -eq $apiBefore -and [IO.File]::ReadAllText((Join-Path $script:Root 'runtime.json')) -eq $runtimeBefore -and [IO.File]::ReadAllText((Join-Path $script:Root 'deployment.json')) -eq $deploymentBefore -and -not (Test-Path -LiteralPath (Join-Path $script:Root 'Product\ui-preferences.json'))) 'saving must not activate/reconfigure/write inside NodeStore'
        $o=Get-TCOverview
        Assert-Session ($o.Mode -eq 'rule' -and $o.Exit -eq 'hk' -and $o.DesiredExit -eq 'Provider' -and $o.NodeId -eq $script:NodeB) 'desired selection must remain separate from effective state'
        $null=Save-TCPreferences -NodeId $null
        Assert-Session ($null -eq (Get-TCPreferences).NodeId -and (Get-TCPreferences).Exit -eq 'Provider') 'explicit null clears only NodeId'
        $null=Save-TCPreferences -Daily Provider
        Assert-Session ((Get-TCPreferences).Daily -eq 'Provider' -and (Get-TCPreferences).Exit -eq 'Provider' -and (Get-TCPreferences).Mode -eq 'Trading' -and (Get-TCOverview).DesiredDaily -eq 'Provider') 'daily intent persists independently of mode and exit'
        $null=Save-TCPreferences -Daily Direct

        # Actual runtime dispatcher, with only OS/launch/control adapters mocked.
        . (Join-Path $script:Package 'runtime\Invoke-TradeChannel.ps1') -LoadFunctionsOnly
        $script:Starts=0;$script:Stops=0;$script:Selections=0;$script:StallStop=$false
        function Assert-TCRuntimeElevation {}
        function Start-TCSupervisor {
            param($ManifestPath)
            $script:Starts++;Reset-Session
            [pscustomobject]@{Id=4101;HasExited=$false}
        }
        function Stop-TCIdentifiedEngine {param($Identity)$script:Stops++;$script:Inventory=@()}
        function Set-TCRunningSelection {param($Action,$Deployment,$Manifest)$script:Selections++}
        function Start-Sleep {
            param($Milliseconds)
            if((Test-Path -LiteralPath (Join-Path $script:Root 'stop.request')) -and -not $script:StallStop){
                $script:Inventory=@();$script:Snapshot.State='EmergencyStopped';Write-TCSessionJson (Join-Path $script:Root 'runtime.json') $script:Snapshot
                Remove-Item -LiteralPath (Join-Path $script:Root 'stop.request')
            }
        }
        Reset-Session;$script:ApiFails=$true
        Assert-Rejected {Invoke-TCRuntimeAction Connect} 'controller failure must reject Connect'
        Assert-Rejected {Invoke-TCRuntimeAction Global} 'legacy mode action with failed controller must not launch'
        Assert-Session ($script:Starts -eq 0 -and $script:Selections -eq 0) 'control failure must have zero starts/changes'
        $null=Invoke-TCRuntimeAction Disconnect
        $null=Invoke-TCRuntimeAction Disconnect
        Assert-Session ($script:Starts -eq 0 -and $script:Stops -eq 0 -and (Get-TCOverview).StateKey -eq 'Disconnected' -and (Test-Path -LiteralPath (Join-Path $script:Root 'stop.request'))) 'manual disconnect works with dead API, is idempotent and retains marker'
        $script:ApiFails=$false
        $null=Invoke-TCRuntimeAction Connect;$null=Invoke-TCRuntimeAction Connect
        Assert-Session ($script:Starts -eq 1 -and -not (Test-Path -LiteralPath (Join-Path $script:Root 'stop.request'))) 'double Connect launches once; explicit Connect clears stop marker'
        $script:Inventory=@();$script:Snapshot.State='Starting';Write-TCSessionJson (Join-Path $script:Root 'runtime.json') $script:Snapshot
        $script:NinjaBusy=$true
        Assert-Rejected {Invoke-TCRuntimeAction Connect} 'Ninja busy must block disconnected start'
        Assert-Session ($script:Starts -eq 1) 'busy gate must run before starting'
        Reset-Session;$script:Inventory[1].CreationDate=$script:SessionStart.AddMinutes(1)
        Assert-Rejected {Invoke-TCRuntimeAction Disconnect} 'PID reuse must never stop unrelated process'
        Assert-Session ($script:Stops -eq 0) 'PID reuse stop count remains zero'
        Reset-Session;$script:Snapshot.State='StoppedWithError';$script:Snapshot.CleanupError=$true;$script:Inventory=@();Write-TCSessionJson (Join-Path $script:Root 'runtime.json') $script:Snapshot
        Assert-Rejected {Invoke-TCRuntimeAction Disconnect} 'cleanup error must not report successful disconnect'

        # Session orchestration: mock execution only, keep real preferences,
        # evidence and overview so UI-facing selections are exercised end to end.
        $script:Commands=New-Object 'System.Collections.Generic.List[string]';$script:EnabledNodes=New-Object 'System.Collections.Generic.List[string]'
        function script:Invoke-TCCommand {
            param($Action)
            $script:Commands.Add($Action)
            switch($Action){
                Connect {Reset-Session}
                Disconnect {$script:Inventory=@();$script:Snapshot.State='Disconnected';Write-TCSessionJson (Join-Path $script:Root 'runtime.json') $script:Snapshot}
                Trading {
                    if(-not $script:FailMode -or $script:FailModeAfterApply){$script:ActualMode='rule'}
                    if($script:FailMode -or $script:FailModeAfterApply){
                        if($script:ModeFailureApiFails){$script:ApiFails=$true}
                        if($script:ModeFailureReplacesEngine){
                            $script:Inventory[1].CreationDate=$script:SessionStart.AddSeconds(2)
                            $script:Snapshot.EngineStartedAt=$script:Inventory[1].CreationDate.ToString('o')
                            Write-TCSessionJson (Join-Path $script:Root 'runtime.json') $script:Snapshot
                        }
                        throw 'Injected controller mode read-back failure'
                    }
                }
                Global {$script:ActualMode='global'}
                HongKong {$script:ActualExit='hk'}
                Provider {$script:ActualExit='provider'}
                DailyDirect {$script:ActualDaily='direct';[pscustomobject]@{Applied=$true;Effective='direct';Reason=$null}}
                DailyProvider {if($script:ProviderReady){$target=Resolve-TCProviderTarget (Get-Content -LiteralPath $script:ManifestPath -Encoding UTF8 -Raw|ConvertFrom-Json) (Get-TCPreferences).ProviderId;$script:ActualDaily=$target.Tag;[pscustomobject]@{Applied=$true;Effective=$target.Tag;Reason=$null;ProviderIPv4='198.51.100.7'}}else{[pscustomobject]@{Applied=$false;Effective='direct';Reason='NotListening'}}}
                # The real writer into the disposable root; only the engine reload is absent.
                Agents {$sel=Get-TCAgentSelection (Get-TCPreferences);$w=Write-TCAgentRuleSets -Root $script:Root -Selection $sel;[pscustomobject]@{Supported=$true;Lane=$sel.Lane;Applied=$true;Changed=$w.Changed;ConnectionsMoved=0}}
                default {throw 'Unexpected action'}
            }
        }
        function script:Enable-TCNode {
            param($ManifestPath,$Mode,$Exit)
            $script:EnabledNodes.Add($ManifestPath)
            [IO.File]::WriteAllText($ManifestPath,[IO.File]::ReadAllText($script:ManifestPath))
            $script:ManifestPath=$ManifestPath
            Write-TCSessionJson (Join-Path $script:Root 'deployment.json') @{ManifestPath=$ManifestPath}
            Reset-Session
            $script:ActualMode=if($Mode -eq 'Global'){'global'}else{'rule'}
            $script:ActualExit=if($Exit -eq 'Provider'){'provider'}else{'hk'}
        }
        Reset-Session;$script:Inventory=@()
        $null=Invoke-TCSession Connect -Mode Global -Exit Provider -NodeId $script:NodeA
        Assert-Session (($script:Commands.ToArray() -join ',') -eq 'Connect,Provider,Global' -and (Get-TCOverview).Mode -eq 'global') 'Connect submits explicit mode/exit'
        $null=Invoke-TCSession Connect -Mode Trading -Exit HongKong
        Assert-Session ($script:Commands.Count -eq 3) 'connected Connect is idempotent, never silently applies selection'
        $null=Invoke-TCSession Apply -Mode Trading -Exit HongKong -NodeId $script:NodeA
        Assert-Session (($script:Commands.ToArray() -join ',') -eq 'Connect,Provider,Global,HongKong,Trading') 'Apply explicitly submits connected selection'
        # Unsupported mode changes must fail before any preference write, exit
        # change, daily/agent command or node activation, even with bundled edits.
        foreach($case in @(
            @{Name='global only';Modes=@('GLOBAL');Actual='global';Mode='tRaDiNg';Wanted='rule';Omit=$false},
            @{Name='mode-list absent';Modes=@();Actual='global';Mode='Trading';Wanted='rule';Omit=$true},
            @{Name='empty mode-list';Modes=@();Actual='global';Mode='Trading';Wanted='rule';Omit=$false},
            @{Name='unrelated modes';Modes=@('global','direct');Actual='global';Mode='Trading';Wanted='rule';Omit=$false},
            @{Name='product label is not a controller mode';Modes=@('global','Trading');Actual='global';Mode='Trading';Wanted='rule';Omit=$false},
            @{Name='rule only';Modes=@('RULE');Actual='rule';Mode='gLoBaL';Wanted='global';Omit=$false}
        )){
            $script:ActualMode=$case.Actual;$script:ControllerModes=$case.Modes;$script:OmitModes=$case.Omit;$script:Commands.Clear()
            $writes=$script:PreferenceWrites;$prior=[IO.File]::ReadAllText((Join-Path $script:Root 'ui-preferences.json'));$failure=$null
            try{$null=Invoke-TCSession Apply -Mode $case.Mode -Exit Provider -Daily Provider -NodeId $script:NodeA -Agents Trade -AgentIds @('claude-code') -AgentCustom @([pscustomobject]@{Kind='Site';Value='perplexity.ai'})}catch{$failure=$_.Exception.Message}
            Assert-Session ($failure -and $failure.StartsWith('[TC:ModeUnavailable]') -and $failure.Contains('（'+$case.Wanted+'）') -and $failure -match '引擎配置缺少' -and $failure -match '更新线路配置并重新连接' -and $failure -match '当前连接未改变') ('unsupported mode explains the remedy: '+$case.Name)
            Assert-Session ($script:PreferenceWrites -eq $writes -and [IO.File]::ReadAllText((Join-Path $script:Root 'ui-preferences.json')) -ceq $prior -and $script:Commands.Count -eq 0 -and $script:EnabledNodes.Count -eq 0 -and $script:ActualMode -eq $case.Actual -and $script:ActualExit -eq 'hk') ('unsupported mode has zero writes/commands: '+$case.Name)
        }
        Reset-Session;$script:ActualMode='global';$script:ControllerModes=@('RuLe','GLOBAL');$script:Commands.Clear()
        $o=Invoke-TCSession Apply -Mode tRaDiNg -Exit HongKong
        Assert-Session (($script:Commands.ToArray() -join ',') -eq 'Trading' -and $o.Mode -eq 'rule' -and $o.ModeSwitchSupported) 'canonical wanted mode accepts mixed-case advertised support and input'
        $script:ActualMode='global';$script:ControllerModes=@('GLOBAL');$script:Commands.Clear()
        $o=Invoke-TCSession Apply -Mode gLoBaL
        Assert-Session ($script:Commands.Count -eq 0 -and $o.Mode -eq 'global' -and -not $o.ModeSwitchSupported) 'unchanged mode works on a single-mode engine'

        # A selector can succeed before the mode command fails. Re-read the same
        # live engine and reconcile trading fields only, keeping other new intent.
        Reset-Session;$script:ActualMode='global';$script:ActualExit='provider';$script:FailMode=$true;$script:Commands.Clear()
        $null=Save-TCPreferences -Mode Trading -Exit Provider -Daily Direct -Agents Daily -AgentIds @('mirasim')
        $writes=$script:PreferenceWrites;$failure=$null
        try{$null=Invoke-TCSession Apply -Mode Trading -Exit HongKong -Daily Provider -Agents Trade -AgentIds @('claude-code')}catch{$failure=$_.Exception.Message}
        $after=Get-TCPreferences;$o=Get-TCOverview
        Assert-Session ($failure -eq 'Injected controller mode read-back failure' -and $after.Mode -eq 'Global' -and $after.Exit -eq 'HongKong' -and $o.Mode -eq 'global' -and $o.Exit -eq 'hk') 'failed mode switch reconciles to the real partially applied trade selection'
        Assert-Session ($after.Daily -eq 'Provider' -and $after.Agents -eq 'Trade' -and (@($after.AgentIds) -join ',') -eq 'claude-code' -and $script:PreferenceWrites -eq $writes+2 -and ($script:Commands.ToArray() -join ',') -eq 'HongKong,Trading') 'failure preserves new daily/agent intent and never rolls the network back'

        Reset-Session;$script:ActualMode='global';$script:FailModeAfterApply=$true;$script:Commands.Clear()
        $null=Save-TCPreferences -Mode Global -Exit Provider -Daily Direct -Agents Daily
        $writes=$script:PreferenceWrites;$failure=$null
        try{$null=Invoke-TCSession Apply -Mode Trading -Exit HongKong -Daily Provider -Agents Trade}catch{$failure=$_.Exception.Message}
        $after=Get-TCPreferences;$o=Get-TCOverview
        Assert-Session ($failure -eq 'Injected controller mode read-back failure' -and $o.Mode -eq 'rule' -and $o.Exit -eq 'hk' -and $after.Mode -eq 'Trading' -and $after.Exit -eq 'HongKong' -and $after.Daily -eq 'Provider' -and $after.Agents -eq 'Trade' -and $script:PreferenceWrites -eq $writes+1 -and ($script:Commands.ToArray() -join ',') -eq 'Trading') 'mode applied before an error must never restore stale trade or other preferences'

        foreach($unverifiable in @('Unavailable','Replaced')){
            Reset-Session;$script:ActualMode='global';$script:FailMode=$true;$script:Commands.Clear()
            $script:ModeFailureApiFails=$unverifiable -eq 'Unavailable';$script:ModeFailureReplacesEngine=$unverifiable -eq 'Replaced'
            $null=Save-TCPreferences -Mode Global -Exit Provider -Daily Direct -Agents Daily
            $writes=$script:PreferenceWrites;$failure=$null
            try{$null=Invoke-TCSession Apply -Mode Trading -Exit HongKong -Daily Provider -Agents Trade}catch{$failure=$_.Exception.Message}
            $after=Get-TCPreferences;$o=Get-TCOverview
            Assert-Session ($failure -eq 'Injected controller mode read-back failure' -and $after.Mode -eq 'Trading' -and $after.Exit -eq 'HongKong' -and $after.Daily -eq 'Provider' -and $after.Agents -eq 'Trade' -and $script:PreferenceWrites -eq $writes+1 -and ($script:Commands.ToArray() -join ',') -eq 'Trading') ('unverified failure never guesses a preference restore: '+$unverifiable)
            if($unverifiable -eq 'Unavailable'){Assert-Session (-not $o.Running -and $null -eq $o.Mode) 'unavailable state is not presented as successfully applied'}
            else{Assert-Session ($o.Running -and $o.Mode -eq 'global' -and $o.DesiredMode -eq 'Trading') 'replacement engine remains authoritative without reconciling the old session'}
        }
        Reset-Session
        $script:Commands.Clear();$script:NinjaBusy=$true
        Assert-Rejected {Invoke-TCSession Apply -NodeId $script:NodeB} 'busy app must block node switch'
        Assert-Session ($script:Commands.Count -eq 0 -and $script:EnabledNodes.Count -eq 0) 'busy node switch must have zero mutations'
        $script:NinjaBusy=$false;$script:ControllerModes=@('rule')
        $null=Invoke-TCSession Apply -Mode Global -Exit Provider -NodeId $script:NodeB
        Assert-Session ($script:EnabledNodes.Count -eq 1 -and $script:EnabledNodes[0] -eq (Join-Path $script:Root 'other.json')) 'different selected node must go through Enable-TCNode'
        $held=Open-TCSessionLock
        try{Assert-Rejected {Invoke-TCSession Disconnect} 'concurrent click must be gated before any command'}finally{$held.Dispose()}
        $script:Commands.Clear();$null=Invoke-TCSession Disconnect;$null=Invoke-TCSession Disconnect
        Assert-Session (($script:Commands.ToArray() -join ',') -eq 'Disconnect,Disconnect' -and (Get-TCOverview).StateKey -eq 'Disconnected') 'Disconnect must never call Connect or apply preferences'
        Assert-Rejected {Invoke-TCSession Apply -Mode Global} 'disconnected Apply cannot auto-start'
        $script:Commands.Clear();$null=Save-TCPreferences -Mode Global -Exit Provider -NodeId $script:NodeA
        Assert-Session ($script:Commands.Count -eq 0 -and (Get-TCOverview).StateKey -eq 'Disconnected') 'edit after disconnect must not reconnect'
        # Daily exit (policy v2): independent of trading exit, never fatal when the provider is not ready.
        Write-TCSessionJson $script:ConfigPath @{outbounds=@(@{tag='trade-exit'},@{tag='daily-exit'})}
        $script:Commands.Clear();Reset-Session;$script:ProviderReady=$true
        $o=Invoke-TCSession Apply -Mode Trading -Exit HongKong -Daily Provider
        Assert-Session (($script:Commands.ToArray() -join ',') -eq 'DailyProvider' -and $o.Daily -eq 'provider' -and $o.Exit -eq 'hk' -and $o.DailyApply.Applied) 'daily change applies alone without touching the trade exit'
        $script:Commands.Clear();$null=Invoke-TCSession Apply -Mode Trading -Exit HongKong -Daily Provider
        Assert-Session ($script:Commands.Count -eq 0) 'unchanged daily selection sends nothing'
        $null=Save-TCPreferences -Mode Trading -Exit Provider -NodeId $script:NodeA
        Reset-Session;$script:ActualMode='global';$script:ControllerModes=@('global');$script:Commands.Clear();$enabled=$script:EnabledNodes.Count
        $o=Invoke-TCSession Apply -Daily Provider
        Assert-Session (($script:Commands.ToArray() -join ',') -eq 'DailyProvider' -and $o.Mode -eq 'global' -and $o.Exit -eq 'hk' -and $o.DesiredMode -eq 'Global' -and $o.DesiredExit -eq 'HongKong' -and -not $o.ModeSwitchSupported -and $script:EnabledNodes.Count -eq $enabled) 'daily-only edit preserves actual global/HK despite stale trading preferences and limited modes'
        # Changing just the daily provider must retain a different live trading
        # provider, including its dedicated tag and identity.
        $manifestBefore=[IO.File]::ReadAllText($script:ManifestPath);$manifest=$manifestBefore|ConvertFrom-Json
        $dailyId='00000000-0000-0000-0000-000000000001';$tradeId='00000000-0000-0000-0000-000000000002'
        $manifest|Add-Member -NotePropertyName Providers -NotePropertyValue @(
            @{Id=$dailyId;Tag='provider';Port=10823;Directory='C:\Mock';Programs=@('C:\Mock\provider.exe')},
            @{Id=$tradeId;Tag='provider2';TradeTag='provider2-trade';Port=10824;TradePort=10825;Directory='C:\Mock2';Programs=@('C:\Mock2\provider.exe')}
        ) -Force
        Write-TCSessionJson $script:ManifestPath $manifest
        $null=Save-TCPreferences -Mode Trading -Exit HongKong -ProviderId $dailyId -TradeProviderId $dailyId
        $script:ActualExit='provider2-trade';$script:Commands.Clear()
        $o=Invoke-TCSession Apply -ProviderId $tradeId
        $after=Get-TCPreferences
        Assert-Session (($script:Commands.ToArray() -join ',') -eq 'DailyProvider' -and $o.Mode -eq 'global' -and $o.Exit -eq 'provider2-trade' -and $o.Daily -eq 'provider2' -and $after.Mode -eq 'Global' -and $after.Exit -eq 'Provider' -and $after.TradeProviderId -eq $tradeId -and $script:EnabledNodes.Count -eq $enabled) 'daily-provider-only edit cannot switch or repair the live trading selection'
        Write-TCSessionText $script:ManifestPath $manifestBefore
        $null=Save-TCPreferences -ProviderId '' -TradeProviderId ''
        $script:Commands.Clear();Reset-Session;$script:ProviderReady=$false
        $o=Invoke-TCSession Apply -Daily Provider
        Assert-Session ($o.Running -and $o.Daily -eq 'direct' -and -not $o.DailyApply.Applied -and $o.DailyApply.Reason -eq 'NotListening' -and (Get-TCPreferences).Daily -eq 'Provider') 'provider not ready keeps daily direct, keeps the intent and does not fail the session'
        $script:Commands.Clear();$script:ActualDaily='provider';$null=Invoke-TCSession Apply -Daily Direct
        Assert-Session (($script:Commands.ToArray() -join ',') -eq 'DailyDirect' -and (Get-TCOverview).Daily -eq 'direct') 'daily direct applies alone'
        $script:Commands.Clear();$null=Invoke-TCSession Disconnect;$script:Commands.Clear();$null=Save-TCPreferences -Daily Provider
        Assert-Session ($script:Commands.Count -eq 0 -and (Get-TCOverview).DesiredDaily -eq 'Provider' -and $null -eq (Get-TCOverview).Daily) 'disconnected daily choice only saves intent'
        # AI assistant list (policy v3): saved with the other choices, applied by rewriting
        # watched rule-sets, and never a trading command.
        $null=Save-TCPreferences -Agents Trade -AgentIds @('mirasim','claude-code') -AgentCustom @([pscustomobject]@{Kind='Site';Value='https://Perplexity.AI/'})
        $p=Get-TCPreferences
        Assert-Session ($p.Agents -eq 'Trade' -and (@($p.AgentIds) -join ',') -eq 'mirasim,claude-code' -and @($p.AgentCustom).Count -eq 1 -and $p.AgentCustom[0].Value -eq 'perplexity.ai' -and $p.Daily -eq 'Provider') 'assistant choice persists beside the other choices'
        Assert-Rejected {Save-TCPreferences -AgentCustom @([pscustomobject]@{Kind='Site';Value='1.2.3.4'})} 'an invalid custom site is rejected'
        $null=Save-TCPreferences -Mode Trading
        Assert-Session ((@((Get-TCPreferences).AgentIds) -join ',') -eq 'mirasim,claude-code' -and @((Get-TCPreferences).AgentCustom).Count -eq 1) 'a console that does not send the list never clears it'
        Write-TCSessionJson $script:ConfigPath @{outbounds=@(@{tag='trade-exit'},@{tag='daily-exit'});route=@{rule_set=@(@{type='local';tag='tc-agents'},@{type='local';tag='tc-agents-dns'})}}
        $o=Get-TCOverview
        Assert-Session ($o.AgentsSupported -and $null -eq $o.Agents -and $o.DesiredAgents -eq 'Trade' -and @($o.AgentNames) -contains 'Mirasim' -and @($o.AgentNames) -contains 'perplexity.ai') 'disconnected overview shows the saved list, not an applied lane'
        $null=Save-TCPreferences -Daily Direct;$script:Commands.Clear();Reset-Session
        $o=Invoke-TCSession Apply -Agents Trade -AgentIds @('mirasim','claude-code')
        Assert-Session (($script:Commands.ToArray() -join ',') -eq 'Agents' -and $o.Agents -eq 'Trade' -and $o.AgentApply.Lane -eq 'Trade' -and $o.Exit -eq 'hk' -and $o.Mode -eq 'rule') 'connected: the list applies alone, trading exit and mode untouched'
        $script:Commands.Clear();$null=Invoke-TCSession Apply -Agents Trade
        Assert-Session ($script:Commands.Count -eq 0) 'unchanged assistant choice sends nothing'
        $script:Commands.Clear();$o=Invoke-TCSession Apply -AgentIds @('mirasim')
        Assert-Session (($script:Commands.ToArray() -join ',') -eq 'Agents' -and (@((Get-TCPreferences).AgentIds) -join ',') -eq 'mirasim' -and $o.Agents -eq 'Trade') 'editing the list applies at once'
        $script:Commands.Clear();$o=Invoke-TCSession Apply -Agents Daily
        Assert-Session (($script:Commands.ToArray() -join ',') -eq 'Agents' -and $o.Agents -eq 'Daily') 'the list returns to daily traffic at once'
        $null=Save-TCPreferences -Mode Trading -Exit Provider -NodeId $script:NodeA -Daily Direct
        $script:ActualMode='global';$script:ControllerModes=@('GLOBAL');$script:Commands.Clear();$enabled=$script:EnabledNodes.Count
        $o=Invoke-TCSession Apply -Agents Trade
        Assert-Session (($script:Commands.ToArray() -join ',') -eq 'Agents' -and $o.Mode -eq 'global' -and $o.Exit -eq 'hk' -and $o.Agents -eq 'Trade' -and $o.DesiredMode -eq 'Global' -and $o.DesiredExit -eq 'HongKong' -and -not $o.ModeSwitchSupported -and $script:EnabledNodes.Count -eq $enabled) 'agent-only edit keeps global/HK and never repairs or switches a single-mode engine'
        $script:Commands.Clear();$o=Invoke-TCSession Apply -AgentIds @('claude-code')
        Assert-Session (($script:Commands.ToArray() -join ',') -eq 'Agents' -and $o.Mode -eq 'global' -and $o.Exit -eq 'hk' -and $script:EnabledNodes.Count -eq $enabled) 'agent-list-only edit also leaves the live trading choice intact'
        Write-TCSessionJson $script:ConfigPath @{outbounds=@(@{tag='trade-exit'},@{tag='daily-exit'})}
        $script:Commands.Clear();$o=Invoke-TCSession Apply -Agents Trade
        Assert-Session ($script:Commands.Count -eq 0 -and -not $o.AgentsSupported -and (Get-TCPreferences).Agents -eq 'Trade') 'a v2 line only saves the choice'
        $script:Commands.Clear();$null=Invoke-TCSession Disconnect;$script:Commands.Clear();$null=Save-TCPreferences -Agents Daily
        Assert-Session ($script:Commands.Count -eq 0 -and (Get-TCPreferences).Agents -eq 'Daily') 'disconnected assistant choice only saves intent'
        Write-TCSessionJson $script:ConfigPath @{outbounds=@(@{tag='trade-exit'})}
        $script:Checks
    } $root
    $supervisorChecks=& {
        param($testRoot,$package)
        . (Join-Path $package 'runtime\Run-TradeChannel.ps1') -LoadFunctionsOnly
        # Safe in-memory test doubles, never the P/Invoke guard implementation.
        if('TradeChannelGuard' -as [type]){throw 'Supervisor tests require a fresh process without a loaded native guard'}
        Add-Type -TypeDefinition @'
using System;
public static class TradeChannelGuard {
    public static int Installs, Permits, Disposals;
    public static bool FailDispose;
    public static ulong[] InstallPersistentBlocks(string[] paths) { Installs++; return new ulong[]{1,2}; }
    public static IDisposable OpenTunPermit(string[] paths, uint index) { Permits++; return new MockLease(); }
    private class MockLease : IDisposable { public void Dispose() { Disposals++; if(FailDispose) throw new Exception("Injected permit cleanup failure"); } }
}
public static class TradeChannelProxyNotify { public static bool InternetSetOption(IntPtr p, int a, IntPtr b, int c) { return true; } }
'@
        $script:SupRoot=Join-Path $testRoot 'supervisor';$null=[IO.Directory]::CreateDirectory($script:SupRoot)
        $script:SupManifest=Join-Path $script:SupRoot 'manifest.json';$script:SupChecks=0
        [IO.File]::WriteAllText($script:SupManifest,(@{SyntaxValidated=$true;DeploymentApproved=$true;CandidatePath=(Join-Path $script:SupRoot 'config.json');EnginePath='C:\Mock\sing-box.exe';ControlPort=17891;TradeProgramPaths=@('C:\Mock\NinjaTrader.exe')}|ConvertTo-Json))
        function Assert-Supervisor {param([bool]$Condition,[string]$Message)if(-not $Condition){throw ('Supervisor regression: '+$Message)};$script:SupChecks++}
        function Open-TCSupervisorMutex {
            $mock=[pscustomobject]@{}
            $mock|Add-Member ScriptMethod WaitOne {param($timeout)return $true}
            $mock|Add-Member ScriptMethod ReleaseMutex {}
            $mock|Add-Member ScriptMethod Dispose {}
            $mock
        }
        function Get-Process {
            param($Name,$Id,$ErrorAction)
            if($Id){return [pscustomobject]@{StartTime=(Get-Date).AddSeconds(-2)}}
            if($Name -eq 'NinjaTrader'){
                $script:SupStates.Add((Get-Content -LiteralPath (Join-Path $script:SupRoot 'runtime.json') -Raw|ConvertFrom-Json).State)
                if($script:SupBusy){[pscustomobject]@{Name='NinjaTrader'}}
            }
        }
        function Get-CimInstance {param($ClassName,$ErrorAction)[pscustomobject]@{LastBootUpTime=(Get-Date).AddHours(-3)}}
        function Get-Service {param($Name,$ErrorAction)@()}
        function Get-NetAdapter {param($Name,$ErrorAction)[pscustomobject]@{Status='Up';ifIndex=42;InterfaceGuid='mock-tun-guid'}}
        function Get-TCSupervisorListeners {if($script:FakeEngine){[pscustomobject]@{Port=17891;Address=[Net.IPAddress]::Loopback}}}
        function Get-ItemProperty {param($LiteralPath)if($script:SupThrowInLoop -and (Get-Content -LiteralPath (Join-Path $script:SupRoot 'runtime.json') -Raw|ConvertFrom-Json).State -eq 'Running'){throw 'Injected registry read failure'};[pscustomobject]$script:SupProxy}
        function Set-ItemProperty {param($LiteralPath,$Name,$Value)$script:SupProxy[$Name]=$Value;$script:ProxyWrites++}
        function Remove-ItemProperty {param($LiteralPath,$Name,$ErrorAction)$script:SupProxy[$Name]='';$script:ProxyWrites++}
        function Stop-Process {throw 'Native process stop is forbidden in supervisor tests'}
        function Register-ScheduledTask {throw 'Task mutation forbidden'}
        function Test-TCSupervisorController {param($Manifest)if($script:SupApiFails){throw 'Injected control failure'}}
        # Registry change notifications are replaced by the mocked Start-Sleep tick.
        function New-TCProxyWatch {$null}
        function Start-Process {
            param($FilePath,$ArgumentList,$WindowStyle,[switch]$PassThru,$RedirectStandardOutput,$RedirectStandardError)
            $script:SupStarts++
            $script:FakeEngine=[pscustomobject]@{Id=7102;StartTime=(Get-Date);HasExited=$false}
            $script:FakeEngine|Add-Member ScriptMethod Kill {
                $script:SupStates.Add((Get-Content -LiteralPath (Join-Path $script:SupRoot 'runtime.json') -Raw|ConvertFrom-Json).State)
                $script:SupKills++
                if($script:SupKillFails){throw 'Injected engine kill failure'}
                $this.HasExited=$true
            }
            $script:FakeEngine|Add-Member ScriptMethod WaitForExit {param($milliseconds)return $this.HasExited}
            $script:FakeEngine|Add-Member ScriptMethod Dispose {}
            if($script:SupCancelStarting){[IO.File]::WriteAllText((Join-Path $script:SupRoot 'stop.request'),'manual')}
            $script:FakeEngine
        }
        function Start-Sleep {
            param($Milliseconds)
            $script:SupStates.Add((Get-Content -LiteralPath (Join-Path $script:SupRoot 'runtime.json') -Raw|ConvertFrom-Json).State)
            if($script:SupUnexpectedExit){$script:FakeEngine.HasExited=$true}
            else{[IO.File]::WriteAllText((Join-Path $script:SupRoot 'stop.request'),'manual')}
        }
        function Reset-Supervisor {
            $script:SupStarts=0;$script:SupKills=0;$script:SupBusy=$false;$script:SupApiFails=$false;$script:SupCancelStarting=$false;$script:SupUnexpectedExit=$false;$script:SupKillFails=$false;$script:SupThrowInLoop=$false;$script:FakeEngine=$null;$script:ProxyWrites=0
            $script:SupProxy=@{ProxyEnable=0;ProxyServer='';AutoConfigURL=''}
            $script:SupStates=New-Object 'System.Collections.Generic.List[string]'
            [TradeChannelGuard]::Installs=0;[TradeChannelGuard]::Permits=0;[TradeChannelGuard]::Disposals=0;[TradeChannelGuard]::FailDispose=$false
            [IO.File]::WriteAllText((Join-Path $script:SupRoot 'runtime.json'),'{"State":"Running","EnginePid":999,"Error":"stale"}')
            $marker=Join-Path $script:SupRoot 'stop.request';if(Test-Path -LiteralPath $marker){Remove-Item -LiteralPath $marker}
        }
        function Read-SupervisorState {Get-Content -LiteralPath (Join-Path $script:SupRoot 'runtime.json') -Raw|ConvertFrom-Json}
        Reset-Supervisor
        $result=Invoke-TCSupervisor -ManifestPath $script:SupManifest -Root $script:SupRoot
        $s=Read-SupervisorState
        Assert-Supervisor ($result -eq 0 -and $s.State -eq 'Disconnected' -and -not $s.Error -and $script:SupStarts -eq 1 -and $script:SupKills -eq 1 -and [TradeChannelGuard]::Disposals -eq 1) 'manual stop must clean once without restarting'
        Assert-Supervisor (($script:SupStates.ToArray() -join ',') -eq 'Starting,Running,Stopping') 'publish real startup/running/shutdown phases before work'
        Assert-Supervisor ($s.SupervisorStartedAt -and $s.EngineStartedAt -and $s.BootStartedAt -and $s.FinishedAt -and (Test-Path -LiteralPath (Join-Path $script:SupRoot 'stop.request'))) 'persist process/boot identities and manual disconnect marker'
        Assert-Supervisor ([IO.File]::Exists((Join-Path $script:SupRoot 'agents\agents-route.json')) -and [IO.File]::Exists((Join-Path $script:SupRoot 'agents\agents-dns.json'))) 'assistant rule-sets are written before the engine starts'
        Reset-Supervisor;$script:SupBusy=$true
        $result=Invoke-TCSupervisor -ManifestPath $script:SupManifest -Root $script:SupRoot
        Assert-Supervisor ($result -eq 1 -and (Read-SupervisorState).State -eq 'StoppedWithError' -and $script:SupStarts -eq 0 -and [TradeChannelGuard]::Installs -eq 0 -and $script:ProxyWrites -eq 0) 'early busy failure must replace stale Running before any mutation'
        Reset-Supervisor;$script:SupApiFails=$true
        $result=Invoke-TCSupervisor -ManifestPath $script:SupManifest -Root $script:SupRoot
        Assert-Supervisor ($result -eq 1 -and (Read-SupervisorState).State -eq 'StoppedWithError' -and $script:SupStarts -eq 1 -and $script:SupKills -eq 1 -and [TradeChannelGuard]::Permits -eq 0) 'controller failure must not publish Running or open permit'
        Reset-Supervisor;$script:SupCancelStarting=$true
        $result=Invoke-TCSupervisor -ManifestPath $script:SupManifest -Root $script:SupRoot
        Assert-Supervisor ($result -eq 0 -and (Read-SupervisorState).State -eq 'Disconnected' -and -not (Read-SupervisorState).Error -and $script:SupStarts -eq 1 -and [TradeChannelGuard]::Permits -eq 0) 'manual cancel during Starting is disconnected, not Fault'
        Reset-Supervisor;[IO.File]::WriteAllText((Join-Path $script:SupRoot 'stop.request'),'manual')
        $result=Invoke-TCSupervisor -ManifestPath $script:SupManifest -Root $script:SupRoot
        Assert-Supervisor ($result -eq 0 -and $script:SupStarts -eq 0 -and [TradeChannelGuard]::Installs -eq 0 -and (Read-SupervisorState).State -eq 'Disconnected') 'launch with persisted disconnect marker must not auto-connect'
        Reset-Supervisor;$script:SupUnexpectedExit=$true
        $result=Invoke-TCSupervisor -ManifestPath $script:SupManifest -Root $script:SupRoot
        Assert-Supervisor ($result -eq 1 -and (Read-SupervisorState).State -eq 'StoppedWithError' -and $script:SupStarts -eq 1 -and [TradeChannelGuard]::Disposals -eq 1) 'unexpected engine exit is Fault and never triggers recovery start'
        Reset-Supervisor;[TradeChannelGuard]::FailDispose=$true
        $result=Invoke-TCSupervisor -ManifestPath $script:SupManifest -Root $script:SupRoot
        Assert-Supervisor ($result -eq 1 -and (Read-SupervisorState).State -eq 'StoppedWithError' -and (Read-SupervisorState).CleanupError -and $script:SupKills -eq 1) 'permit cleanup failure must not report disconnected success'
        Reset-Supervisor;$script:SupKillFails=$true
        $result=Invoke-TCSupervisor -ManifestPath $script:SupManifest -Root $script:SupRoot
        Assert-Supervisor ($result -eq 1 -and (Read-SupervisorState).State -eq 'StoppedWithError' -and (Read-SupervisorState).CleanupError -and -not $script:FakeEngine.HasExited) 'failed engine stop must stay Fault with identity retained'
        Reset-Supervisor;$script:SupProxy=@{ProxyEnable=1;ProxyServer='127.0.0.1:8001';AutoConfigURL=''}
        $result=Invoke-TCSupervisor -ManifestPath $script:SupManifest -Root $script:SupRoot
        Assert-Supervisor ($result -eq 0 -and $script:SupProxy.ProxyEnable -eq 1 -and $script:ProxyWrites -gt 0 -and $script:SupStarts -eq 1) 'mock provider proxy normalization restores saved setting without restarting'
        Reset-Supervisor;$script:SupProxy=@{ProxyEnable=1;ProxyServer='127.0.0.1:9999';AutoConfigURL=''}
        $result=Invoke-TCSupervisor -ManifestPath $script:SupManifest -Root $script:SupRoot;$s=Read-SupervisorState
        Assert-Supervisor ($result -eq 0 -and $s.State -eq 'Disconnected' -and $script:SupStarts -eq 1 -and $s.ProxyEvents -ge 1 -and $s.LastProxyKind -eq 'Unknown' -and $s.LastProxySummary -eq '127.0.0.1:9999' -and $script:SupProxy.ProxyEnable -eq 1) 'unrecognized proxy is suspended and restored, never stops the channel'
        Reset-Supervisor;$script:SupProxy=@{ProxyEnable=0;ProxyServer='';AutoConfigURL='http://wpad.corp.example/proxy.pac'}
        $result=Invoke-TCSupervisor -ManifestPath $script:SupManifest -Root $script:SupRoot;$s=Read-SupervisorState
        Assert-Supervisor ($result -eq 0 -and $s.State -eq 'Disconnected' -and $s.LastProxyKind -eq 'Unknown' -and $script:SupProxy.AutoConfigURL -eq 'http://wpad.corp.example/proxy.pac') 'unrecognized PAC is suspended and restored without a fault'
        Reset-Supervisor;$script:SupThrowInLoop=$true
        $result=Invoke-TCSupervisor -ManifestPath $script:SupManifest -Root $script:SupRoot;$s=Read-SupervisorState
        Assert-Supervisor ($result -eq 0 -and $s.State -eq 'Disconnected' -and $s.TransientErrors -ge 1 -and $s.LastTransientError -eq 'ProxyCheck') 'transient read failures are recorded, never stop the channel'
        # Daily-exit reconciliation: controller, provider checks and preflight are mocked.
        . (Join-Path $package 'runtime\TradeChannel.Providers.ps1')
        $script:DailySupported=$true;$script:Preflight=$null;$script:NextPreflight=[DateTime]::MinValue;$script:PreflightFile=Join-Path $script:SupRoot 'preflight.txt'
        $script:SelectorNow='direct';$script:Puts=New-Object 'System.Collections.Generic.List[string]'
        $script:Health=[pscustomobject]@{Healthy=$true;Reason=$null};$script:PreflightOk=$true;$script:PreflightStarts=0
        function Invoke-TCSupervisorApi {param($Path,$Method='GET',$Body)if($Method -eq 'PUT'){$name=($Body|ConvertFrom-Json).name;$script:Puts.Add($name);$script:SelectorNow=$name;return};[pscustomobject]@{now=$script:SelectorNow}}
        function Get-TCProviderHealth {param($Manifest,$Provider,[switch]$SkipTunnelCheck)$script:Health}
        function Start-TCProviderPreflight {param($Port,$OutFile,$TimeoutSeconds)$script:PreflightStarts++;[pscustomobject]@{HasExited=$false}}
        function Read-TCProviderPreflight {param($Process,$OutFile)[pscustomobject]@{Ok=$script:PreflightOk;IP='198.51.100.7'}}
        function Set-DailyIntent {param($Value)[IO.File]::WriteAllText((Join-Path $script:SupRoot 'ui-preferences.json'),(@{Mode='Trading';Exit='HongKong';Daily=$Value}|ConvertTo-Json))}
        $sm=[pscustomobject]@{ProviderSocksPort=10823;ProviderProgramPaths=@('C:\Mock\provider.exe');ProviderDirectory='C:\Mock'};$sync=@{ForeignTunnel=$null}
        Set-DailyIntent 'Direct';Sync-TCDailyExit -State $sync -Manifest $sm -Root $script:SupRoot
        Assert-Supervisor ($script:Puts.Count -eq 0 -and $sync.DailyEffective -eq 'direct' -and $sync.DailyIntent -eq 'Direct') 'direct intent keeps direct without commands'
        Set-DailyIntent 'Provider';Sync-TCDailyExit -State $sync -Manifest $sm -Root $script:SupRoot
        Assert-Supervisor ($script:Puts.Count -eq 0 -and $script:PreflightStarts -eq 1 -and $sync.DailyReason -eq 'Checking' -and $sync.DailyEffective -eq 'direct') 'healthy provider is preflighted before daily traffic moves'
        Sync-TCDailyExit -State $sync -Manifest $sm -Root $script:SupRoot
        Assert-Supervisor ($script:Puts.Count -eq 0 -and $script:PreflightStarts -eq 1 -and $sync.DailyReason -eq 'Checking') 'running preflight is not duplicated and never blocks'
        $script:Preflight.HasExited=$true;Sync-TCDailyExit -State $sync -Manifest $sm -Root $script:SupRoot
        Assert-Supervisor (($script:Puts.ToArray() -join ',') -eq 'provider' -and $sync.DailyEffective -eq 'provider' -and -not $sync.DailyReason) 'proven forwarding moves daily traffic to the provider'
        Sync-TCDailyExit -State $sync -Manifest $sm -Root $script:SupRoot
        Assert-Supervisor ($script:Puts.Count -eq 1) 'steady healthy provider sends nothing'
        $script:Health=[pscustomobject]@{Healthy=$false;Reason='NotListening'};Sync-TCDailyExit -State $sync -Manifest $sm -Root $script:SupRoot
        Assert-Supervisor (($script:Puts.ToArray() -join ',') -eq 'provider,direct' -and $sync.DailyEffective -eq 'direct' -and $sync.DailyReason -eq 'NotListening' -and $sync.DailyIntent -eq 'Provider') 'provider loss falls back to direct and keeps the intent'
        $script:Health=[pscustomobject]@{Healthy=$true;Reason=$null};$script:PreflightOk=$false;$script:Preflight=$null
        Sync-TCDailyExit -State $sync -Manifest $sm -Root $script:SupRoot;$script:Preflight.HasExited=$true;Sync-TCDailyExit -State $sync -Manifest $sm -Root $script:SupRoot
        Assert-Supervisor ($script:Puts.Count -eq 2 -and $sync.DailyReason -eq 'ForwardingFailed' -and $script:NextPreflight -gt (Get-Date)) 'failed forwarding stays direct with a retry backoff'
        $starts=$script:PreflightStarts;Sync-TCDailyExit -State $sync -Manifest $sm -Root $script:SupRoot
        Assert-Supervisor ($script:PreflightStarts -eq $starts -and $sync.DailyReason -eq 'ForwardingFailed') 'backoff prevents preflight storms'
        $script:NextPreflight=[DateTime]::MinValue;$script:PreflightOk=$true;$script:SelectorNow='provider';$sync.ForeignTunnel='BatVPN'
        Sync-TCDailyExit -State $sync -Manifest $sm -Root $script:SupRoot
        Assert-Supervisor ($script:SelectorNow -eq 'direct' -and $sync.DailyReason -eq 'ForeignTunnel') 'a competing tunnel forces daily traffic direct'
        Set-DailyIntent 'Direct';$sync.ForeignTunnel=$null;$script:SelectorNow='provider';Sync-TCDailyExit -State $sync -Manifest $sm -Root $script:SupRoot
        Assert-Supervisor ($script:SelectorNow -eq 'direct' -and -not $sync.DailyReason) 'user choosing direct always wins'
        $script:DailySupported=$false
        $script:SupChecks
    } $root (Split-Path $PSScriptRoot -Parent)
    [pscustomobject]@{Passed=$true;Checks=($bridgeChecks+$supervisorChecks);SessionChecks=$bridgeChecks;SupervisorChecks=$supervisorChecks;Scope='Isolated mocks: identity, API failure, preferences, actions, startup, cancellation and cleanup';RealNetworkChanges=0}
}finally{
    Remove-Module RuntimeBridge -ErrorAction SilentlyContinue
    $resolved=[IO.Path]::GetFullPath($root);$parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not $resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'TC-SessionState-*'){throw 'Cleanup guard rejected path'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
