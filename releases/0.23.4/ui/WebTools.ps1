#requires -Version 5.1
# Small workflow views reuse the existing job and confirmation contracts.
function ShowTCWebNodeView {
 switch($script:WebNodeView){
  'providers'{PageHead '代理软件' '' 'nodes';ProviderManagement}
  'agents'{PageHead 'AI 工具名单' '' 'nodes';AgentListCard}
  'domains'{ShowTradeDomainManager}
  default{$null=ShowTCWebShell 'lines'}
 }
}
function SetTCWebStartup {param([bool]$Enabled)
 if($script:ReadOnly -or (IsBusy)){return}
 if(-not $Enabled -and $script:UserSettings.AutoConnectOnLogin){
  Toast '请先关闭自动连接，再关闭登录时打开';return
 }
 StartJob @{Action='SetStartup';Enabled=$Enabled} {param($result)
  $script:Prefs.OpenAtLogin=[bool]$result.Enabled
  Toast $(if($result.Enabled){'登录后会打开 TradeChannel'}else{'已关闭登录时打开'})
  SyncTCWebState -Force
 } '正在保存启动设置…' -Failed {param($message)ErrorDialog $message;SyncTCWebState -Force}
}
function ShowTCWebRename {param([string]$Id)
 $node=NodeEntry $Id;if(-not $node){return}
 PageHead '重命名线路' '' 'line-rename'
 $card=Card;$panel=Stack;$card.Child=$panel
 AddC $panel (T '线路名称' 13 $script:Ink 'SemiBold')
 $input=ControlName (New-Object Windows.Controls.TextBox) 'RenameLineName'
 $input.Text=[string]$node.name;$input.MaxLength=120;$input.Margin='0,10,0,18';AddC $panel $input
 $buttons=New-Object Windows.Controls.WrapPanel
 $save=Btn '保存名称' 'RenameLineSave' {
  $name=$script:Controls.RenameLineName.Text.Trim()
  if(-not $name -or $name.Length -gt 120 -or $name -match '[\x00-\x1f]'){Toast '请填写 1–120 个字的线路名称';return}
  $id=[string]$this.Tag
  StartJob @{Action='RenameNode';Id=$id;Name=$name} {param($result)
   $null=ShowTCWebShell 'lines';FetchNodes;Toast '线路名称已保存'
  } '正在保存线路名称…'
 } 'Primary';$save.Tag=$Id;AddC $buttons $save
 AddC $buttons (Margin (Btn '取消' 'RenameLineCancel' {$null=ShowTCWebShell 'lines'} 'Ghost') '8,0,0,0')
 AddC $panel $buttons;AddC $script:HostPanel $card
}
function ShowTCWebMaintenance {
 PageHead '维护与恢复' '' 'web-maintenance'
 $card=Card;$panel=Stack;$card.Child=$panel
 AddC $panel (T '连接恢复' 17 $script:Ink 'SemiBold')
 AddC $panel (Rule)
 $pending=Btn '查看待处理操作' 'WebPendingOperations' {ShowPendingUiOperation} 'Btn'
 SettingRow $panel '未完成的操作' '查看上次的结果，继续或恢复。' $pending
 AddC $panel (Rule)
 $proxy=Btn '检查代理设置' 'WebProxyRecovery' {ShowProxyRecovery} 'Btn'
 SettingRow $panel '系统代理' '连接已结束，但日常上网仍不正常时使用。' $proxy
 AddC $panel (Rule)
 $cleanup=Btn '结束上次连接的清理' 'WebResolveCleanup' {
  StartJob @{Action='ResolveSessionCleanup'} {param($result)
   if($result.Resolved){Toast ([string]$result.Message)}
   elseif($result.NeedsChoice){Toast '代理设置与记录不一致，请选择保留或恢复。';ShowProxyRecovery;return}
   else{ResultDialog $result '上次连接的清理尚未完成';return}
   RefreshOverview -Silent;ShowTCWebMaintenance
  } '正在完成上次连接的清理…'
 } 'Btn'
 SettingRow $panel '上次连接的清理' '上次连接结束后没有完成收尾时使用。' $cleanup
 AddC $panel (Rule)
 $repair=Btn '恢复连接状态' 'WebRepairState' {
  OpenDialog '恢复连接状态？' '将断开连接并清理异常状态。线路资料和交易保护保留，完成后请重新连接。' '请先退出交易软件。' '恢复并断开' {
   StartJob @{Action='RepairState';ClearProviders=$false} {param($result)Toast $result.Message;RefreshOverview -Silent;ShowTCWebMaintenance} '正在恢复连接状态…'
  } '取消' 'Danger'
 } 'Btn'
 SettingRow $panel '连接或断开未完成' '连接反复失败或一直处理中时使用。' $repair
 AddC $script:HostPanel $card
 SectionLabel $script:HostPanel '配置与程序'
 $card=Card;$panel=Stack;$card.Child=$panel
 $upgrade=Btn '更新线路配置' 'WebUpgradeConfiguration' {OpenUpgrade} 'Btn'
 $upgrade.IsEnabled=[bool]($script:Overview.UpgradeAvailable -or $script:Providers.RequiresUpgrade)
 SettingRow $panel '线路配置' $(if($upgrade.IsEnabled){'更新会重新连接，请先结束交易。'}else{'当前配置无需更新。'}) $upgrade
 AddC $panel (Rule)
 $installation=Btn '检查程序入口' 'WebInstallationInfo' {StartJob @{Action='InstallationInfo'} {param($result)$script:InstallInfoUI=$result;ShowInstallationInformation} '正在检查程序与快捷方式…'} 'Btn'
 SettingRow $panel '程序与快捷方式' '检查桌面入口是否指向当前版本。' $installation
 AddC $script:HostPanel $card
 SectionLabel $script:HostPanel '停用 TradeChannel'
 $card=Card;$panel=Stack;$card.Child=$panel
 $remove=Btn '解除交易保护' 'WebRemoveProtection' {
  OpenDialog '解除交易保护？' '将停止连接并允许交易软件直接使用本地网络。' '请先退出交易软件。日常断开无需解除保护。' '解除保护' {
   StartJob @{Action='RemoveProtection'} {param($result)ResultDialog $result;RefreshOverview -Silent;ShowTCWebMaintenance} '正在解除交易保护…'
  } '取消' 'Danger'
 } 'Danger'
 SettingRow $panel '交易软件直连保护' '解除后交易软件可直连本地网络。' $remove
 AddC $script:HostPanel $card
}
