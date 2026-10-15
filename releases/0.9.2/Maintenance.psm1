#requires -Version 5.1
Set-StrictMode -Version 2
function Invoke-TCMaintenanceContext {
    param([string]$Root,[scriptblock]$Action,[object[]]$Arguments=@())
    $module=Import-Module (Join-Path $PSScriptRoot 'RuntimeBridge.psm1') -PassThru -DisableNameChecking
    & $module {param($DataRoot,$Callback,$ArgsList)$priorRoot=$script:Root;try{$script:Root=[IO.Path]::GetFullPath($DataRoot);& $Callback $DataRoot @ArgsList}finally{$script:Root=$priorRoot}} $Root $Action $Arguments
}
function Get-TCMaintenanceReport {
    [CmdletBinding()]param([string]$Root=(Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'TradeChannel'))
    Invoke-TCMaintenanceContext $Root {
        $o=Get-TCOverview;$p=Get-TCPreferences
        [pscustomobject]@{Version='0.9.2';State=$o.StateKey;Running=$o.Running;CanConnect=$o.CanConnect;ManifestPath=$o.ManifestPath;GuardState=$o.GuardState;Error=$o.Error;Preferences=[pscustomobject]@{NodeId=$p.NodeId;Daily=$p.Daily;ProviderId=$p.ProviderId;TradeProviderId=$p.TradeProviderId};NetworkChanged=$false;Message='诊断仅查看当前状态，未停止进程或更改网络。'}
    }
}
function Repair-TCClientState {
    [CmdletBinding()]param([string]$Root=(Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'TradeChannel'),[switch]$ClearProviders)
    $ErrorActionPreference='Stop'
    if(Get-Process -Name NinjaTrader -ErrorAction SilentlyContinue){throw '请先退出整个 NinjaTrader，再执行维护恢复。'}
    Invoke-TCMaintenanceContext $Root {
        param($DataRoot,$ResetProviders)
        $null=Invoke-TCSession Disconnect
        $after=Get-TCOverview
        if($after.Running -or $after.StateKey -eq 'Fault'){throw '断开未通过状态核验。恢复记录保留，请先导出诊断；未操作未知进程或其他网卡。'}
        if($ResetProviders){
            $prefsPath=Join-Path $DataRoot 'ui-preferences.json'
            if(Test-Path -LiteralPath $prefsPath){$backup=Join-Path $DataRoot ('backup\preferences-'+[guid]::NewGuid().ToString('N')+'.json');$null=[IO.Directory]::CreateDirectory((Split-Path $backup -Parent));Copy-Item -LiteralPath $prefsPath -Destination $backup}
            $null=Save-TCPreferences -Daily Direct -ProviderId '' -TradeProviderId '' -Exit HongKong
        }
        [pscustomobject]@{Repaired=$true;GuardPreserved=$true;ProvidersCleared=$ResetProviders;Message='已核验停止本项目通道，交易保护保留。现在可在概览页选择原线路并手动连接。';ExternalAdaptersChanged=$false;DeploymentRecordPreserved=$true}
    } @([bool]$ClearProviders)
}
function Export-TCClientDiagnostics {
    [CmdletBinding()]param([string]$Root=(Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'TradeChannel'),[Parameter(Mandatory=$true)][string]$Destination)
    $ErrorActionPreference='Stop'
    $output=[IO.Path]::GetFullPath($Destination)
    if([IO.File]::Exists($output)){throw '诊断目标已存在，请选择新文件名。'}
    $report=Get-TCMaintenanceReport -Root $Root
    $report | Add-Member NoteProperty Adapters @(Get-NetAdapter|Select-Object Name,InterfaceDescription,Status)
    $report | Add-Member NoteProperty DefaultRoutes @(Get-NetRoute -DestinationPrefix '0.0.0.0/0'|Select-Object InterfaceIndex,NextHop,RouteMetric)
    [IO.File]::WriteAllText($output,($report|ConvertTo-Json -Depth 7),(New-Object Text.UTF8Encoding($true)))
    [pscustomobject]@{Path=$output;Exported=$true;NetworkChanged=$false;Message='诊断已导出；不包含 WireGuard 私钥、配置密码或订阅内容。'}
}
Export-ModuleMember -Function Get-TCMaintenanceReport,Repair-TCClientState,Export-TCClientDiagnostics
