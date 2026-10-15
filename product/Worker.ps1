#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$RequestPath,[Parameter(Mandatory=$true)][string]$ResultPath)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$env:PSModulePath=Join-Path $PSHOME 'Modules'
$request=$null;$data=$null
try{
    $jobRoot=[IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'TradeChannel\Product\jobs'))+'\'
    foreach($p in @($RequestPath,$ResultPath)){if(-not([IO.Path]::GetFullPath($p)).StartsWith($jobRoot,[StringComparison]::OrdinalIgnoreCase)){throw '无效的任务目录。'}}
    $request=Get-Content -LiteralPath $RequestPath -Encoding UTF8 -Raw|ConvertFrom-Json
    Import-Module (Join-Path $PSScriptRoot 'RuntimeBridge.psm1') -Force -DisableNameChecking
    $paths=Get-TCProductPaths
    if(Test-Path -LiteralPath (Join-Path $PSScriptRoot 'NodeStore.psm1')){Import-Module (Join-Path $PSScriptRoot 'NodeStore.psm1') -Force -DisableNameChecking}
    if(Test-Path -LiteralPath (Join-Path $PSScriptRoot 'ServerSetup.psm1')){Import-Module (Join-Path $PSScriptRoot 'ServerSetup.psm1') -Force -DisableNameChecking}
    Import-Module (Join-Path $PSScriptRoot 'Startup.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'InstallerSetup.psm1') -Force -DisableNameChecking
    switch([string]$request.Action){
        'Overview' {$data=Get-TCOverview}
        'Preferences' {$data=Get-TCPreferences;$startup=Get-TCStartup;$data.OpenAtLogin=[bool]$startup.Enabled}
        'SavePreferences' {
            # Only fields the console sent are saved; older consoles omit Daily and the assistant list.
            $values=@{};foreach($key in @('Mode','Exit','Daily','Agents','ProviderId','TradeProviderId')){if($request.PSObject.Properties[$key] -and $request.$key){$values[$key]=[string]$request.$key}}
            if($request.PSObject.Properties['NodeId']){$values.NodeId=$request.NodeId}
            if($request.PSObject.Properties['AgentIds']){$values.AgentIds=[string[]]@($request.AgentIds|Where-Object {$_})}
            if($request.PSObject.Properties['AgentCustom']){$values.AgentCustom=[object[]]@($request.AgentCustom|Where-Object {$_})}
            $data=Save-TCPreferences @values
        }
        'Session' {
            $values=@{Action=[string]$request.SessionAction}
            foreach($key in @('Mode','Exit','Daily','Agents','ProviderId','TradeProviderId')){if($request.PSObject.Properties[$key] -and $request.$key){$values[$key]=[string]$request.$key}}
            if($request.PSObject.Properties['NodeId']){$values.NodeId=$request.NodeId}
            if($request.PSObject.Properties['AgentIds']){$values.AgentIds=[string[]]@($request.AgentIds|Where-Object {$_})}
            if($request.PSObject.Properties['AgentCustom']){$values.AgentCustom=[object[]]@($request.AgentCustom|Where-Object {$_})}
            $data=Invoke-TCSession @values
        }
        'Agents' {$data=Get-TCAgentOverview}
        {$_ -in @('Providers','ProviderRegister','ProviderPrepare','ProviderRestore','ProviderCheck')} {
            Import-Module (Join-Path $PSScriptRoot 'ProviderBridge.psm1') -Force -DisableNameChecking
            $data=Invoke-TCProviderRequest -Request $request -Root $paths.Root
        }
        'UpgradeActive' {$data=Update-TCActivePolicy}
        'StartupStatus' {$data=Get-TCStartup}
        'SetStartup' {$data=Set-TCStartup -Enabled ([bool]$request.Enabled) -SourceDirectory $PSScriptRoot}
        'DesktopShortcut' {$data=& (Join-Path $PSScriptRoot 'Create-DesktopShortcut.ps1')}
        'InspectClient' {$data=Get-TCClientInspection}
        'InspectServer' {$data=Get-TCServerInspection}
        {$_ -in @('LinuxStart','LinuxPoll','LinuxComplete','LinuxRecent')} {
            Import-Module (Join-Path $PSScriptRoot 'LinuxServerSetup.psm1') -Force -DisableNameChecking
            $data=Invoke-TCLinuxRequest -Request $request -Root $paths.Root
        }
        'Nodes' {$data=@(Get-TCNodes -Root $paths.StoreRoot)}
        'Adopt' {
            $d=Get-TCInstalledDeployment;if(-not $d){throw '没有找到可接管的本机通道。请选择导入配置。'}
            $data=Register-TCExisting -Root $paths.StoreRoot -ManifestPath $d.ManifestPath -Name ([string]$request.Name)
        }
        'ImportNode' {
            $providers=@()
            if($request.UseProvider){
                $inspect=Get-TCClientInspection;$providers=@($inspect.RegisteredProviders)
                if(-not $providers.Count){throw '请先在线路页登记服务商，或取消服务商选项先完成自建线路部署。'}
            }
            $data=Import-TCWireGuard -Root $paths.StoreRoot -Path ([string]$request.Path) -Name ([string]$request.Name) -EnginePath $paths.Engine -WgPath $paths.Wg -TradeProgramPaths ([string[]]@($request.Programs)) -DirectDnsIPv4 ([string]$request.Dns) -Providers $providers
        }
        'ActivateNode' {
            $node=@(Get-TCNodes -Root $paths.StoreRoot|Where-Object {$_.id -eq [string]$request.Id})
            if($node.Count -ne 1 -or -not $node[0].manifestPath){throw '该节点尚未具备可启用配置。请先完成授权并导入客户端配置。'}
            $data=Enable-TCNode -ManifestPath $node[0].manifestPath
        }
        'Command' {$data=@(Invoke-TCCommand -Action ([string]$request.Command))}
        'CheckActive' {$data=Test-TCActiveConnection}
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
}
[IO.File]::WriteAllText($ResultPath,($result|ConvertTo-Json -Depth 18),(New-Object Text.UTF8Encoding($true)))
