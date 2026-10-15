$script:RuntimeReportUI=$null;$script:InstallInfoUI=$null;$script:RollbackUI=$null;$script:LastObservedState=$null;$script:LastFaultNotice=$null;$script:TrayNotifications=@()
function ObserveTrayState {param($Overview)
 if(-not $Overview){return}
 $state=[string]$Overview.StateKey;$previous=$script:LastObservedState;$script:LastObservedState=$state
 $terminal=[string](Get-TCDField (Get-TCDField $Overview RuntimeEvidence) State 'Unknown')
 $intentional=$script:UserDisconnectIntent -or $terminal -in @('Stopped','Disconnected','StoppedByUser')
 $fault=$previous -eq 'Connected' -and $state -in @('Fault','Disconnected') -and -not $intentional
 if($state -eq 'Connected'){$script:LastFaultNotice=$null;$script:UserDisconnectIntent=$false}
 if($fault){
  $key=$state+'|'+[string]$Overview.Error
  if($script:LastFaultNotice -cne $key){
   $script:LastFaultNotice=$key
   $protected=[string]$Overview.GuardState -eq 'Protected'
   $interrupted=$terminal -eq 'StoppedWithError'
   $body=if($interrupted -and $protected){'通道已中断，交易程序直连保护仍生效。点击打开控制台核对原因。'}elseif($interrupted){'通道已中断，交易保护状态尚待核对。点击打开控制台。'}else{'无法确认交易通道状态，请打开控制台核对。不会自动重启或切换线路。'}
   $notice=[pscustomobject]@{Title=$(if($interrupted){'交易通道已中断'}else{'连接状态需要处理'});Text=$body;State=$state}
   $script:TrayNotifications+=,$notice
   if($script:Tray -and -not $script:Smoke){$script:Tray.ShowBalloonTip(8000,$notice.Title,$notice.Text,[Windows.Forms.ToolTipIcon]::Error)}
  }
 }
 # Visual updates use StateKey()/Pending in UpdateChrome; notifications above
 # remain grounded in observed runtime transitions, never UI intentions.
}
function AddRuntimeStatusCard {param($Parent)
 $o=$script:Overview;$card=Card '20,18';$card.Margin='0,18,0,0';$p=Stack;$card.Child=$p
 AddC $p (T '运行状况' 14.5 $script:Ink 'SemiBold')
 $state=if($o){switch([string]$o.StateKey){'Connected'{'运行中'}'Disconnected'{'未连接'}'Fault'{'状态待核对'}'Unconfigured'{'尚未配置'}default{'正在核对'}}}else{'尚未读取'}
 $connections=if($o -and $o.Running -and $o.StateKey -eq 'Connected' -and $o.PSObject.Properties['Connections']){[string]$o.Connections+'（控制器）'}else{'未取得控制器观测'}
 $guard=if($o -and $o.GuardState -eq 'Protected'){'已核验保护'}elseif($o -and $o.GuardState -eq 'Unprotected'){'保护未完整启用'}else{'待确认'}
 AddC $p (Margin (T ('通道：'+$state+' · 活动连接：'+$connections) 12.5 $script:Text2) '0,8,0,0')
 AddC $p (T ('交易选择：'+$(if($o){[string]$o.Exit}else{'未知'})+'（控制器选择，不代表实测公网 IP）') 12 $script:Text3)
 AddC $p (T ('保护：'+$guard+' · '+$(if($o -and $o.ForeignTunnel){'检测到其他隧道'}else{'未取得其他隧道告警'})) 12 $script:Text3)
 $b=Btn '查看本次运行时间轴 / 导出报告' 'RuntimeReportOpen' {ShowRuntimeReport} 'Ghost';$b.Margin='0,10,0,0';AddC $p $b;AddC $Parent $card
}
function ShowRuntimeReport {
 $script:Page='runtime';Head '' '运行状况与时间轴' '状态、事件和证据来源分开呈现，覆盖本软件管理的连接。'
 if(-not $script:RuntimeReportUI){StartJob @{Action='RuntimeReport'} {param($d)$script:RuntimeReportUI=$d;ShowRuntimeReport} '读取运行报告…';return}
 $report=$script:RuntimeReportUI;$card=Card;$p=Stack;$card.Child=$p
 AddC $p (T ([string]$report.SummaryText) 13 $script:Text2)
 $pending=Btn '查看待核对的后台操作' 'PendingOperations' {ShowPendingUiOperation} 'Ghost';AddC $p $pending
 $proxy=Btn '系统代理恢复…' 'ProxyRecoveryOpen' {ShowProxyRecovery} 'Ghost';AddC $p $proxy
 foreach($event in @($report.Events)){
  $text=[string](Get-TCDField $event AtUtc (Get-TCDField $event At ''))+' · '+[string](Get-TCDField $event Type '')+' · '+[string](Get-TCDField $event Source '')
  AddC $p (Margin (T $text 12 $script:Text3) '0,8,0,0')
 }
 $refresh=Btn '刷新报告' 'RuntimeReportRefresh' {StartJob @{Action='RuntimeReport'} {param($d)$script:RuntimeReportUI=$d;ShowRuntimeReport} '刷新运行报告…'} 'Ghost';$refresh.Margin='0,16,8,0';AddC $p $refresh
 $export=Btn '导出 JSON 与文字摘要' 'RuntimeReportExport' {$path=ChooseFile '保存运行诊断（同时生成文字摘要）' 'JSON (*.json)|*.json' -Save -Name 'TradeChannel-runtime-report.json';if($path){StartJob @{Action='ExportDiagnostics';Path=$path} {param($d)ResultDialog $d '诊断已导出'} '导出脱敏报告…'}} 'Ghost';$export.Margin='0,10,0,0';AddC $p $export
 AddC $script:HostPanel $card
}
function ShowProxyRecovery {
 StartJob @{Action='ProxyRecoveryStatus'} {param($rows)
  PageHead '系统代理恢复' '只处理本程序留下的设置恢复记录，保留你随后做的修改。' 'proxy-recovery'
  if(-not @($rows).Count){AddC $script:HostPanel (T '没有需要处理的代理恢复记录。' 13 $script:Text2);return}
  foreach($row in @($rows)){
   AddC $script:HostPanel (T $row.Message 13 $script:Text2)
   if(-not $row.CanResolve){continue}
   foreach($choice in @('KeepCurrent','RestorePrevious')){
    $button=Btn $(if($choice -eq 'KeepCurrent'){'保留当前设置'}else{'恢复会话前设置…'}) ('Proxy'+$choice+$row.SessionId) {
     StartJob @{Action='ProxyRecoveryPreview';SessionId=$this.Tag.SessionId;Choice=$this.Tag.Choice} {param($preview)
      OpenDialog '确认处理系统代理？' $preview.Message '提交时再次核对当前值；设置变化后需要重新预览。' '确认' {param($approved)
       StartJob @{Action='ProxyRecoveryCommit';SessionId=$approved.SessionId;Choice=$approved.Choice;PreviewToken=$approved.PreviewToken} {param($result)ShowProxyRecovery} '核对并处理遗留代理设置…'
      } '取消' -Context $preview -SafeDefault
     } '预览代理恢复…'
    } 'Ghost';$button.Tag=@{SessionId=$row.SessionId;Choice=$choice};AddC $script:HostPanel $button
   }
  }
 } '读取代理恢复记录…'
}
function ShowConfigurationRollback {param([string]$NodeId)
 $script:RollbackNodeId=$NodeId
 StartJob @{Action='ConfigurationRollbackPreview';NodeId=$NodeId} {param($d)$script:RollbackUI=$d;ShowConfigurationRollbackResult} '核对上次配置和当前状态…'
}
function ShowConfigurationRollbackResult {
 $script:Page='rollback';Head '' '还原线路配置' '还原修改前的配置引用；不会自动切换线路或连接。'
 $d=$script:RollbackUI;$card=Card;$p=Stack;$card.Child=$p
 AddC $p (T ([string]$d.Message) 13 $script:Text2)
 if(-not $d.Available){AddC $p (Note '没有可核验的上一份配置。原文件缺失或被修改时，不会强行还原。')}
 elseif($d.RequiresMaintenance){
  AddC $p (Note '此配置正在使用。请安排维护：退出交易软件，在概览明确断开，再回到这里重新核对并还原。不能在在线状态直接替换配置。')
  $button=Btn '只准备回退候选，保持当前连接' 'RollbackPrepare' {OpenDialog '生成回退候选？' '只验证和生成候选，不更新当前线路、不改变网络。' '启用仍需要维护时间和明确操作。' '准备候选' {StartJob @{Action='ConfigurationRollbackPrepare';NodeId=$script:RollbackNodeId;PreviewToken=$script:RollbackUI.PreviewToken} {param($result)ResultDialog $result '回退候选已准备'} '验证回退候选…'}} 'Ghost';$button.Margin='0,16,0,0';AddC $p $button
 }elseif($d.CanRestore){
  $button=Btn '确认还原这条未连接线路' 'RollbackApply' {OpenDialog '还原到修改前配置？' '仅更新这条未连接线路的配置引用。当前网络和其他线路保持。' '执行前会再次核对文件哈希和运行状态。' '还原配置' {StartJob @{Action='ConfigurationRollbackApply';NodeId=$script:RollbackNodeId;PreviewToken=$script:RollbackUI.PreviewToken} {param($result)ResultDialog $result '配置已还原，尚未连接';FetchNodes} '还原未连接线路配置…'}} 'Primary';$button.Margin='0,16,0,0';AddC $p $button
 }
 $back=Btn '返回线路' 'RollbackBack' {ShowNodes;FetchNodes} 'Ghost';$back.Margin='0,12,0,0';AddC $p $back;AddC $script:HostPanel $card
}
function AddInstallationInformation {param($Parent)
 $card=Card '20,18';$card.Margin='0,16,0,0';$p=Stack;$card.Child=$p
 AddC $p (T ('当前版本：'+$script:Version) 14 $script:Ink 'SemiBold');AddC $p (T ('程序位置：'+$script:PackageRoot) 12 $script:Text3)
 AddC $p (T '同名目录大小写不会作为两份安装；其他程序副本仅提示，不自动清理。' 12 $script:Text3)
 $button=Btn '检查快捷方式和其他程序副本' 'InstallationInfoCheck' {StartJob @{Action='InstallationInfo'} {param($d)$script:InstallInfoUI=$d;ShowInstallationInformation} '检查已知入口，不扫描整盘…'} 'Ghost';$button.Margin='0,10,0,0';AddC $p $button;AddC $Parent $card
}
function ShowInstallationInformation {
 $script:Page='installation';Head '' '程序与快捷方式' '仅检查已知位置，不删除其他副本，不联网查询更新。'
 $p=Stack;$data=$script:InstallInfoUI
 AddC $p (T ('正在运行：'+$data.Current.PackageRoot+' · '+$data.Current.Version) 13 $script:Ink)
 foreach($copy in @($data.Copies)){AddC $p (Margin (T ('其他记录：'+[string](Get-TCDField $copy PackageRoot (Get-TCDField $copy Path ''))+' · '+[string](Get-TCDField $copy Version '未知')) 12 $script:Text3) '0,10,0,0')}
 foreach($notice in @($data.Notices)){AddC $p (T ([string]$notice) 12 $script:Text3)}
 $repair=Btn '重建指向本版本的桌面入口' 'InstallationRepairShortcut' {StartJob @{Action='DesktopShortcut'} {param($d)ResultDialog $d '桌面入口已更新'} '重建本版本入口…'} 'Ghost';$repair.Margin='0,16,0,0';AddC $p $repair;AddC $script:HostPanel $p
}
