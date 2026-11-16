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
   $body=if($interrupted -and $protected){'连接已中断，交易软件直连保护仍生效。打开控制台查看原因。'}elseif($interrupted){'连接已中断，交易保护状态待确认。请打开控制台检查。'}else{'无法确认连接状态，请打开控制台检查。不会自动重启或切换线路。'}
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
 $state=if($o){switch([string]$o.StateKey){'Connected'{'已连接'}'Disconnected'{'未连接'}'Fault'{'状态待确认'}'Unconfigured'{'尚未配置'}default{'正在检查'}}}else{'尚未读取'}
 $connections=if($o -and $o.Running -and $o.StateKey -eq 'Connected' -and $o.PSObject.Properties['Connections']){[string]$o.Connections+'（当前读数）'}else{'暂未读到'}
 $guard=if($o -and $o.GuardState -eq 'Protected'){'已开启'}elseif($o -and $o.GuardState -eq 'Unprotected'){'保护未完整启用'}else{'待确认'}
 AddC $p (Margin (T ('连接：'+$state+' · 活动连接：'+$connections) 12.5 $script:Text2) '0,8,0,0')
 AddC $p (T ('交易线路：'+$(if($o){[string]$o.Exit}else{'未知'})+'（线路设置，实测 IP 请运行连接检查）') 12 $script:Text3)
 AddC $p (T ('保护：'+$guard+' · '+$(if($o -and $o.ForeignTunnel){'检测到其他 VPN'}else{'暂无其他 VPN 提示'})) 12 $script:Text3)
 $b=Btn '查看运行记录与报告' 'RuntimeReportOpen' {ShowRuntimeReport} 'Ghost';$b.Margin='0,10,0,0';AddC $p $b;AddC $Parent $card
}
function ShowRuntimeReport {
 $script:Page='runtime';Head '' '运行诊断' ''
 if(-not $script:RuntimeReportUI){StartJob @{Action='RuntimeReport'} {param($d)$script:RuntimeReportUI=$d;ShowRuntimeReport} '读取运行报告…';return}
 $report=$script:RuntimeReportUI;$card=Card;$p=Stack;$card.Child=$p
 $current=Get-TCDField $report Current
 $stateLabel=switch([string](Get-TCDField $current State 'Unknown')){'Connected'{'已连接'}'Disconnected'{'未连接'}'Connecting'{'正在连接'}'Disconnecting'{'正在断开'}'Unconfigured'{'尚未配置'}'Fault'{'需要处理'}default{'待确认'}}
 $guard=Get-TCDField $current Guard
 $guardLabel=switch([string](Get-TCDField $guard State 'Unknown')){'Protected'{'已开启'}'Unprotected'{'未完整开启'}default{'待确认'}}
 KeyValue $p '连接状态' $stateLabel
 KeyValue $p '交易保护' $guardLabel
 $observed=Get-TCDField $current ObservedAtUtc ''
 if($observed){try{$observed=([DateTimeOffset]$observed).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')}catch{};KeyValue $p '检查时间' $observed}
 if($report.JournalWarning){AddC $p (Note ([string]$report.JournalWarning) 'amber')}
 $bar=New-Object Windows.Controls.WrapPanel
 $refresh=Btn '重新检查' 'RuntimeReportRefresh' {StartJob @{Action='RuntimeReport'} {param($d)$script:RuntimeReportUI=$d;ShowRuntimeReport} '检查运行状态…'} 'Btn';AddC $bar $refresh
 $export=Btn '导出诊断报告' 'RuntimeReportExport' {$path=ChooseFile '保存运行诊断' 'JSON (*.json)|*.json' -Save -Name 'TradeChannel-runtime-report.json';if($path){StartJob @{Action='ExportDiagnostics';Path=$path} {param($d)ResultDialog $d '诊断已导出'} '导出诊断报告…'}} 'Ghost';AddC $bar (Margin $export '8,0,0,0');AddC $p (Margin $bar '0,16,0,0')
 AddC $script:HostPanel $card
 SectionLabel $script:HostPanel '最近事件'
 $card=Card;$p=Stack;$card.Child=$p
 $labels=@{SessionStarting='开始连接';SessionReady='连接已就绪';SessionStopped='连接已停止';SessionFault='连接发生异常';DailyExitChanged='日常上网线路已变化';ForeignTunnelChanged='其他 VPN 状态变化';ProxyNormalized='系统代理设置已处理';TransientReadError='暂时无法读取状态';ConfigurationRestored='线路配置已恢复';TradeExitChanged='交易线路选择已变化';ModeChanged='应用走向已变化';GuardChanged='交易保护状态已更新';CleanupResolved='上次连接的清理已归位';StateObserved='连接状态已更新'}
 $events=@($report.Events|Sort-Object AtUtc -Descending|Select-Object -First 20)
 if(-not $events.Count){AddC $p (T '暂无运行事件。' 13 $script:Text3)}
 foreach($event in $events){
  $at=[string](Get-TCDField $event AtUtc (Get-TCDField $event At ''));try{$at=([DateTimeOffset]$at).ToLocalTime().ToString('MM-dd HH:mm:ss')}catch{}
  $kind=[string](Get-TCDField $event Type '');$label=if($labels.ContainsKey($kind)){$labels[$kind]}else{'运行状态已记录'}
  KeyValue $p $at $label
 }
 $technical=New-Object Windows.Controls.Expander;$technical.Header='详细诊断数据';$technical.Content=T ([string]$report.SummaryText) 12 $script:Text3;$technical.Margin='0,16,0,0';AddC $p $technical
 AddC $script:HostPanel $card
 SectionLabel $script:HostPanel '处理问题'
 $card=Card;$p=Stack;$card.Child=$p
 $pending=Btn '查看待处理操作' 'PendingOperations' {ShowPendingUiOperation} 'Ghost';AddC $p $pending
 $proxy=Btn '检查系统代理设置' 'ProxyRecoveryOpen' {ShowProxyRecovery} 'Ghost';AddC $p $proxy
 AddC $script:HostPanel $card
}
function ShowProxyRecovery {
 StartJob @{Action='ProxyRecoveryStatus'} {param($rows)
  PageHead '系统代理恢复' '检查本程序遗留的代理设置，保留你后续做的修改。' 'proxy-recovery'
  if(-not @($rows).Count){AddC $script:HostPanel (T '没有需要恢复的代理设置。' 13 $script:Text2);return}
  foreach($row in @($rows)){
   AddC $script:HostPanel (T $row.Message 13 $script:Text2)
   if(-not $row.CanResolve){continue}
   foreach($choice in @('KeepCurrent','RestorePrevious')){
    $button=Btn $(if($choice -eq 'KeepCurrent'){'保留当前设置'}else{'恢复连接前设置…'}) ('Proxy'+$choice+$row.SessionId) {
     StartJob @{Action='ProxyRecoveryPreview';SessionId=$this.Tag.SessionId;Choice=$this.Tag.Choice} {param($preview)
      OpenDialog '确认处理系统代理？' $preview.Message '执行前会检查设置；如有变化，需要重新预览。' '确认' {param($approved)
       StartJob @{Action='ProxyRecoveryCommit';SessionId=$approved.SessionId;Choice=$approved.Choice;PreviewToken=$approved.PreviewToken} {param($result)ShowProxyRecovery} '检查并处理遗留代理设置…'
      } '取消' -Context $preview -SafeDefault
     } '预览代理恢复…'
    } 'Ghost';$button.Tag=@{SessionId=$row.SessionId;Choice=$choice};AddC $script:HostPanel $button
   }
  }
 } '读取代理恢复记录…'
}
function ShowConfigurationRollback {param([string]$NodeId)
 $script:RollbackNodeId=$NodeId
 StartJob @{Action='ConfigurationRollbackPreview';NodeId=$NodeId} {param($d)$script:RollbackUI=$d;ShowConfigurationRollbackResult} '检查上次配置和当前状态…'
}
function ShowConfigurationRollbackResult {
 $script:Page='rollback';Head '' '还原线路配置' '还原修改前的配置，完成后可手动连接。'
 $d=$script:RollbackUI;$card=Card;$p=Stack;$card.Child=$p
 AddC $p (T ([string]$d.Message) 13 $script:Text2)
 if(-not $d.Available){AddC $p (Note '上一份配置缺失或已被修改，暂不能还原。')}
 elseif($d.RequiresMaintenance){
  AddC $p (Note '这份配置正在使用。请先退出交易软件并在概览断开连接，再回来还原。')
  $button=Btn '先准备还原配置' 'RollbackPrepare' {OpenDialog '准备还原配置？' '先验证并保存修改前的配置，当前连接保持。' '启用前请退出交易软件并断开连接。' '准备配置' {StartJob @{Action='ConfigurationRollbackPrepare';NodeId=$script:RollbackNodeId;PreviewToken=$script:RollbackUI.PreviewToken} {param($result)ResultDialog $result '还原配置已备好'} '准备还原配置…'}} 'Ghost';$button.Margin='0,16,0,0';AddC $p $button
 }elseif($d.CanRestore){
  $button=Btn '还原这条线路' 'RollbackApply' {OpenDialog '还原到修改前配置？' '将还原这条未连接线路的配置，当前网络和其他线路保持。' '执行前会再次检查文件和连接状态。' '还原配置' {StartJob @{Action='ConfigurationRollbackApply';NodeId=$script:RollbackNodeId;PreviewToken=$script:RollbackUI.PreviewToken} {param($result)ResultDialog $result '配置已还原，尚未连接';FetchNodes} '还原未连接线路配置…'}} 'Primary';$button.Margin='0,16,0,0';AddC $p $button
 }
 $back=Btn '返回线路' 'RollbackBack' {ShowNodes;FetchNodes} 'Ghost';$back.Margin='0,12,0,0';AddC $p $back;AddC $script:HostPanel $card
}
function AddInstallationInformation {param($Parent)
 $card=Card '20,18';$card.Margin='0,16,0,0';$p=Stack;$card.Child=$p
 AddC $p (T ('当前版本：'+$script:Version) 14 $script:Ink 'SemiBold');AddC $p (T ('程序位置：'+$script:PackageRoot) 12 $script:Text3)
 AddC $p (T '其他程序副本可在下方查看。' 12 $script:Text3)
 $button=Btn '检查程序与快捷方式' 'InstallationInfoCheck' {StartJob @{Action='InstallationInfo'} {param($d)$script:InstallInfoUI=$d;ShowInstallationInformation} '检查程序入口…'} 'Ghost';$button.Margin='0,10,0,0';AddC $p $button;AddC $Parent $card
}
function ShowInstallationInformation {
 $script:Page='installation';Head '' '程序与快捷方式' '检查已知位置的程序与快捷方式。'
 $p=Stack;$data=$script:InstallInfoUI
 AddC $p (T ('正在运行：'+$data.Current.PackageRoot+' · '+$data.Current.Version) 13 $script:Ink)
 foreach($copy in @($data.Copies)){AddC $p (Margin (T ('其他记录：'+[string](Get-TCDField $copy PackageRoot (Get-TCDField $copy Path ''))+' · '+[string](Get-TCDField $copy Version '未知')) 12 $script:Text3) '0,10,0,0')}
 foreach($notice in @($data.Notices)){AddC $p (T ([string]$notice) 12 $script:Text3)}
 $repair=Btn '重建本版本桌面入口' 'InstallationRepairShortcut' {StartJob @{Action='DesktopShortcut'} {param($d)ResultDialog $d '桌面入口已更新'} '重建本版本入口…'} 'Ghost';$repair.Margin='0,16,0,0';AddC $p $repair;AddC $script:HostPanel $p
}
