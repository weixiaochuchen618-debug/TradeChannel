# Deployment centre and operation history are presentation only. Mutations go
# through the protected worker APIs; this page never invokes a runtime command.
function ShowSetupCenter {
 $script:Step=0;$script:Role='deployment-center';$script:Page='setup'
 Head '' '部署中心' '添加线路、继续准备和操作历史使用同一入口；当前连接保持。'
 $card=Card;$p=Stack;$card.Child=$p
 SetupCardHeader $p '为这台电脑添加线路' '软件识别本机与服务器状态，准备 UDP / TCP 和本机连接资料。' 'server'
 $bar=New-Object Windows.Controls.WrapPanel
 AddC $bar (Btn '添加线路' 'DeployAddLine' {BeginProductDeployment 'Auto'} 'Primary')
 AddC $bar (Margin (Btn '打开连接资料…' 'OpenConnectionMaterial' {OpenUnifiedConnectionMaterial} 'Btn') '10,0,0,0')
 AddC $p (Margin $bar '0,14,0,0');AddC $script:HostPanel (Margin $card '0,0,0,16')
 $tools=New-Object Windows.Controls.WrapPanel
 AddC $tools (Btn '操作历史' 'UnifiedOperationHistory' {ShowUnifiedOperationHistory} 'Ghost')
 AddC $tools (Margin (Btn '设备与维护' 'UnifiedServerMaintenance' {$script:DeployUI.ManagementMode=$true;ShowServerManagement} 'Ghost') '10,0,0,0')
 AddC $tools (Margin (Btn '刷新记录' 'RefreshDeploymentCenter' {$script:DeployUI.CenterLoaded=$false;ShowSetupCenter} 'Ghost') '10,0,0,0')
 AddC $script:HostPanel (Margin $tools '0,0,0,18')
 $centre=ProfileUIField $script:DeployUI 'Center'
 if(-not $centre){AddC $script:HostPanel (Note '正在读取准备进度，现有连接保持。')}
 else{
  $cards=@(ProfileUIField $centre 'Cards' @());$records=@(ProfileUIField $centre 'ContinueRuns' @())+@(ProfileUIField $centre 'PreparedRuns' @())
  foreach($item in $cards){
   $row=Card '18,16';$panel=Stack;$row.Child=$panel;AddC $panel (T ([string]$item.Name) 16 $script:Ink 'SemiBold')
   $record=@($records|Where-Object Id -eq $item.PrimaryId)|Select-Object -First 1
   $state=if($record){ManagementLabel ([string]$record.Stage)}elseif($item.Classification -eq 'Prepared'){'连接已准备'}else{'服务器记录已核验'}
   AddC $panel (Margin (T $state 12.5 $script:Text3) '0,5,0,0')
   $label=switch([string]$item.NextAction){'ViewLine'{'查看线路'}'ConnectLine'{'查看已准备线路'}'Recover'{'核对结果并继续'}'Reconcile'{'核对结果并继续'}'CompleteRemaining'{'补齐连接配置'}'Inspect'{'继续部署'}'Probe'{'继续检查连接'}'ManageServer'{'继续部署'}default{if($item.Classification -eq 'Prepared'){'查看线路'}else{'继续部署'}}}
   $button=Btn $label ('CentreAction'+([string]$item.Id-replace '[^A-Za-z0-9]','')) {InvokeDeploymentCenterAction $this.Tag} 'Btn';$button.Tag=$item;AddC $panel (Margin $button '0,12,0,0')
   AddC $script:HostPanel (Margin $row '0,0,0,10')
  }
  $drafts=@(ProfileUIField $centre 'Drafts' @());$draftServers=@(ProfileUIField $centre 'DraftServers' @())
  if($drafts.Count -or $draftServers.Count){
   $content=Stack
   foreach($draft in $drafts){AddC $content (T ([string]$draft.Name) 13 $script:Text2);$b=Btn '继续填写' ('ContinueDraft'+([string]$draft.SourceId-replace '[^A-Za-z0-9]','')) {InvokeDeploymentHistoryRecord $this.Tag};$b.Tag=$draft;AddC $content $b}
   foreach($server in $draftServers){AddC $content (T ([string]$server.Name+' · '+[string]$server.Host) 13 $script:Text3);if($server.Host){$b=Btn '继续部署' ('ContinueServer'+([string]$server.ServerRecordId-replace '-','')) {BeginProductDeployment 'Auto' ([string]$this.Tag)} 'Ghost';$b.Tag=$server.ServerRecordId;AddC $content $b}}
   $exp=ControlName (New-Object Windows.Controls.Expander) 'DeploymentDrafts';$exp.Header=('草稿与待核对记录（'+($drafts.Count+$draftServers.Count)+'）');$exp.Content=$content;$exp.Margin='0,16,0,0';AddC $script:HostPanel $exp
  }
 }
 $advanced=New-Object Windows.Controls.Expander;$advanced.Header='其他接入与技术工具';$advanced.Margin='0,22,0,0';$more=Stack;$advanced.Content=$more
 AddC $more (Btn '我还没有服务器：查看准备指引' 'CentrePurchase' {ShowPurchasePreparation} 'Ghost')
 AddC $more (Btn '导入电脑迁移包' 'OpenMigration' {ShowMigration} 'Ghost')
 AddC $more (Btn 'Windows Server 配置' 'SetupWinServer' {BeginWizard 'server'} 'Ghost')
 AddC $more (Btn '历史记录的技术诊断' 'CentreTechnicalHistory' {ShowUnifiedOperationHistory} 'Ghost')
 AddC $script:HostPanel $advanced
 if(-not $script:Smoke -and -not (ProfileUIField $script:DeployUI 'CenterLoaded' $false) -and -not (ProfileUIField $script:DeployUI 'CenterLoading' $false)){
  $script:DeployUI.CenterLoading=$true
  StartJob @{Action='DeploymentCenter'} {param($data)$script:DeployUI.Center=$data;$script:DeployUI.CenterLoading=$false;$script:DeployUI.CenterLoaded=$true;if($script:Role -eq 'deployment-center'){ShowSetupCenter}} '读取部署中心…' '' -Silent -Failed {param($message)$script:DeployUI.CenterLoading=$false;$script:DeployUI.CenterError=$message;Toast '部署记录暂时无法读取，请稍后重试'}
 }
}
function InvokeDeploymentCenterAction {param($Item)
 if(IsBusy){return}
 if($Item.PrimaryId){
  $records=@(ProfileUIField $script:DeployUI.Center 'ContinueRuns' @())+@(ProfileUIField $script:DeployUI.Center 'PreparedRuns' @())
  $record=@($records|Where-Object Id -eq $Item.PrimaryId)|Select-Object -First 1
  if($record){InvokeDeploymentHistoryRecord $record;return}
 }
 if($Item.LinkedNodeIds.Count){ShowNodes;FetchNodes;return}
 if($Item.ServerRecordId){BeginProductDeployment 'Auto' ([string]$Item.ServerRecordId)}
}
function InvokeDeploymentHistoryRecord {param($Record)
 if(-not $Record){return}
 switch([string]$Record.SourceKind){
  'DeploymentRun'{if($Record.IdentityState -eq 'Archived'){ErrorDialog '这份记录属于重装前身份，请从部署中心选择新身份。';return};ResumeProductDeployment ([string]$Record.SourceId)}
  'LegacyLinuxJob'{$script:Role='linux';ShowLinux;ResumeLinux ([string]$Record.SourceId)}
  'ManagementIntent'{if($Record.ServerRecordId){SelectServerUI ([string]$Record.ServerRecordId)}else{ErrorDialog '此记录缺少可核对的服务器绑定，请查看历史详情。'}}
 }
}
function ShowUnifiedOperationHistory {
 $script:Role='operation-history';$script:Page='setup';Head '' '操作历史' '清理已结束记录的展示，当前线路、授权及恢复资料保留。'
 $bar=New-Object Windows.Controls.WrapPanel
 AddC $bar (Btn '清空已结束记录' 'ClearEndedOperations' {ClearEndedOperationHistoryUI} 'Btn')
 AddC $bar (Margin (Btn '刷新' 'RefreshOperationHistory' {$script:DeployUI.HistoryLoaded=$false;ShowUnifiedOperationHistory} 'Ghost') '10,0,0,0')
 AddC $bar (Margin (Btn '返回部署中心' 'HistoryBack' {ShowSetupCenter} 'Ghost') '10,0,0,0');AddC $script:HostPanel (Margin $bar '0,0,0,16')
 $filters=New-Object Windows.Controls.WrapPanel
 $search=ControlName (New-Object Windows.Controls.TextBox) 'HistorySearch';$search.Width=190;$search.MinHeight=34;$search.Text=[string](ProfileUIField $script:DeployUI 'HistorySearchText' '');$search.ToolTip='按服务器名称或操作名称筛选';AddC $filters $search
 $source=ControlName (New-Object Windows.Controls.ComboBox) 'HistorySourceFilter';$source.Width=170;$source.MinHeight=34;$source.Margin='10,0,0,0'
 foreach($entry in @(@('所有来源',''),@('部署准备','DeploymentRun'),@('历史部署','LegacyLinuxJob'),@('设备与维护','ManagementIntent'))){$i=New-Object Windows.Controls.ComboBoxItem;$i.Content=$entry[0];$i.Tag=$entry[1];$null=$source.Items.Add($i);if([string]$i.Tag -eq [string](ProfileUIField $script:DeployUI 'HistorySourceKind' '')){$source.SelectedItem=$i}}
 AddC $filters $source
 $status=ControlName (New-Object Windows.Controls.ComboBox) 'HistoryStatusFilter';$status.Width=130;$status.MinHeight=34;$status.Margin='10,0,0,0'
 foreach($entry in @(@('所有结果',''),@('已结束','Ended'),@('需要处理','Attention'),@('受保护','Protected'))){$i=New-Object Windows.Controls.ComboBoxItem;$i.Content=$entry[0];$i.Tag=$entry[1];$null=$status.Items.Add($i);if([string]$i.Tag -eq [string](ProfileUIField $script:DeployUI 'HistoryStatusKind' '')){$status.SelectedItem=$i}}
 AddC $filters $status
 $apply=Btn '筛选' 'ApplyHistoryFilters' {$script:DeployUI.HistorySearchText=$script:Controls.HistorySearch.Text;$script:DeployUI.HistorySourceKind=[string]$script:Controls.HistorySourceFilter.SelectedItem.Tag;$script:DeployUI.HistoryStatusKind=[string]$script:Controls.HistoryStatusFilter.SelectedItem.Tag;ShowUnifiedOperationHistory} 'Ghost';$apply.Margin='10,0,0,0';AddC $filters $apply
 AddC $script:HostPanel (Margin $filters '0,0,0,14')
 $selectedBar=New-Object Windows.Controls.WrapPanel;AddC $selectedBar (Btn '清理所选记录' 'ClearSelectedOperations' {ClearSelectedOperationHistoryUI} 'Ghost');AddC $selectedBar (Margin (Btn '导出当前摘要…' 'ExportOperationHistory' {ExportOperationHistoryUI} 'Ghost') '10,0,0,0');AddC $script:HostPanel (Margin $selectedBar '0,0,0,14')
 $check=ControlName (New-Object Windows.Controls.CheckBox) 'ShowClearedHistory';$check.Content='显示已清理记录';$check.IsChecked=[bool](ProfileUIField $script:DeployUI 'HistoryIncludeHidden' $false)
 $check.Add_Click({$script:DeployUI.HistoryIncludeHidden=[bool]$this.IsChecked;$script:DeployUI.HistoryLoaded=$false;ShowUnifiedOperationHistory});AddC $script:HostPanel (Margin $check '0,0,0,14')
 $visible=@(GetFilteredOperationHistoryUI);$script:DeployUI.HistoryVisibleRecords=$visible
 foreach($record in $visible){
  $card=Card '18,14';$p=Stack;$card.Child=$p;AddC $p (T ([string]$record.Name+' · '+(ManagementLabel ([string]$record.Status))) 14 $script:Ink 'SemiBold')
  AddC $p (Margin (T ((ManagementTime $record.UpdatedAtUtc)+' · '+[string]$record.SourceKind) 12 $script:Text3) '0,5,0,0')
  if($record.Protected){AddC $p (Margin (T '仍被当前线路、未完成操作或恢复资料引用，保留所需数据。' 12 '#A15C07') '0,6,0,0')}
  if($record.Hidden){$b=Btn '恢复展示' ('RestoreHistory'+([string]$record.Id-replace '[^A-Za-z0-9]','')) {RestoreOperationHistoryUI ([string]$this.Tag)} 'Ghost';$b.Tag=$record.Id;AddC $p $b}
  elseif($record.CanResume){$b=Btn '继续本次准备' ('ResumeHistory'+([string]$record.Id-replace '[^A-Za-z0-9]','')) {InvokeDeploymentHistoryRecord $this.Tag} 'Ghost';$b.Tag=$record;AddC $p $b}
  if($record.CanClear -and -not $record.Hidden){
   $selected=ControlName (New-Object Windows.Controls.CheckBox) ('HistoryPick'+([string]$record.Id-replace '[^A-Za-z0-9]',''));$selected.Content='选择清理';$selected.Tag=$record.Id;AddC $p $selected
   $b=Btn '从历史列表移除' ('ClearHistory'+([string]$record.Id-replace '[^A-Za-z0-9]','')) {ClearEndedOperationHistoryUI -Ids @([string]$this.Tag)} 'Ghost';$b.Tag=$record.Id;AddC $p $b
  }
  $details=([string]$record.Stage+' · '+[string]$record.Operation+' · '+(@($record.ProtectionReasons)-join ', '));$null=ManagementDetails $p $details '记录详情'
  AddC $script:HostPanel (Margin $card '0,0,0,10')
 }
 if(-not (ProfileUIField $script:DeployUI 'HistoryLoaded' $false) -and -not $script:Smoke -and -not (IsBusy)){
  $script:DeployUI.HistoryLoaded=$true
  StartJob @{Action='OperationHistory';IncludeHidden=[bool](ProfileUIField $script:DeployUI 'HistoryIncludeHidden' $false)} {param($data)$script:DeployUI.HistoryRecords=@($data);if($script:Role -eq 'operation-history'){ShowUnifiedOperationHistory}} '读取统一操作历史…' -Failed {param($message)$script:DeployUI.HistoryLoaded=$false;ErrorDialog $message}
 }
}
function ClearEndedOperationHistoryUI {param([string[]]$Ids)
 if(IsBusy -or $script:ReadOnly){return}
 $request=@{Action='HistoryClearPreview'};if($Ids){$request.Ids=@($Ids)}
 StartJob $request {param($preview)
  if([int]$preview.EligibleCount -eq 0){Toast ('没有可清空的已结束记录；保留 '+$preview.ProtectedCount+' 条所需记录。');return}
  StartJob @{Action='HistoryClearCommit';PreviewToken=[string]$preview.PreviewToken} {param($result)
   Toast ('已清空 '+$result.ClearedCount+' 条展示；保留 '+$result.ProtectedCount+' 条所需记录。')
   $script:DeployUI.Center=$null;$script:DeployUI.CenterLoaded=$false;$script:DeployUI.HistoryLoaded=$false;ShowUnifiedOperationHistory
  } '清理已结束记录的展示…' -Failed {param($message)ErrorDialog $message}
 } '核对可清理范围与当前引用…' -Failed {param($message)ErrorDialog $message}
}
function GetFilteredOperationHistoryUI {
 $query=[string](ProfileUIField $script:DeployUI 'HistorySearchText' '');$source=[string](ProfileUIField $script:DeployUI 'HistorySourceKind' '');$status=[string](ProfileUIField $script:DeployUI 'HistoryStatusKind' '')
 foreach($record in @(ProfileUIField $script:DeployUI 'HistoryRecords' @())){
  if($source -and $record.SourceKind -ne $source){continue}
  if($query -and ([string]$record.Name+' '+[string]$record.Operation).IndexOf($query,[StringComparison]::OrdinalIgnoreCase) -lt 0){continue}
  if($status -eq 'Ended' -and -not $record.CanClear){continue}
  if($status -eq 'Protected' -and -not $record.Protected){continue}
  if($status -eq 'Attention' -and -not ($record.AttentionRequired -or $record.Classification -eq 'Continue')){continue}
  $record
 }
}
function ClearSelectedOperationHistoryUI {
 $ids=@(foreach($record in @(ProfileUIField $script:DeployUI 'HistoryVisibleRecords' @())){$key='HistoryPick'+([string]$record.Id-replace '[^A-Za-z0-9]','');if($script:Controls.ContainsKey($key) -and $script:Controls[$key].IsChecked){[string]$record.Id}})
 if(-not $ids.Count){Toast '请先选择可清理的已结束记录。';return}
 ClearEndedOperationHistoryUI -Ids $ids
}
function ExportOperationHistoryUI {
 $summary=[pscustomobject]@{Kind='TradeChannel.OperationHistorySummary';ExportedAtUtc=[DateTimeOffset]::UtcNow.ToString('o');Records=@(GetFilteredOperationHistoryUI);ContainsCredentials=$false}
 if($script:Smoke){$script:ExportedHistoryFixture=$summary;return}
 $dialog=New-Object Microsoft.Win32.SaveFileDialog;$dialog.Title='导出操作状态摘要';$dialog.Filter='JSON 摘要 (*.json)|*.json';$dialog.FileName='TradeChannel-操作记录.json';$dialog.OverwritePrompt=$true
 if($dialog.ShowDialog()){
  [IO.File]::WriteAllText([IO.Path]::GetFullPath($dialog.FileName),($summary|ConvertTo-Json -Depth 10),(New-Object Text.UTF8Encoding($true)));Toast '已导出状态摘要，不包含密码、私钥或授权密文。'
 }
}
function RestoreOperationHistoryUI {param([string]$Id)
 if(IsBusy -or $script:ReadOnly){return}
 StartJob @{Action='HistoryRestore';Id=$Id} {param($data)$script:DeployUI.HistoryLoaded=$false;ShowUnifiedOperationHistory;Toast '已恢复历史展示；服务器身份和连接保持。'} '恢复记录展示…'
}
function OpenUnifiedConnectionMaterial {
 if($script:ReadOnly){ErrorDialog '只读窗口不导入接入资料。';return}
 $path=ChooseFile '打开邀请、授权或已有连接配置' '连接资料 (*.json;*.conf;*.tcinvite;*.tcauth)|*.json;*.conf;*.tcinvite;*.tcauth|所有文件 (*.*)|*.*'
 if(-not $path){return}
 if((Get-Item -LiteralPath $path).Length -gt 1MB){ErrorDialog '接入资料超过允许大小。';return}
 if([IO.Path]::GetExtension($path) -ieq '.conf'){BeginWizard 'client';$script:Wizard.Path=$path;$script:Step=2;ShowSetup;return}
 $text=[IO.File]::ReadAllText($path,[Text.Encoding]::UTF8)
 if(-not (DispatchUnifiedConnectionMaterial $text)){ErrorDialog '未识别为邀请、设备申请或授权返回，请核对资料类型。'}
}
function DispatchUnifiedConnectionMaterial {param([string]$Text)
 if([string]::IsNullOrWhiteSpace($Text) -or $Text.Trim() -match '^(ssh\s|(?:[a-z_][a-z0-9_-]*@)?\d{1,3}\.)'){return $false}
 if($script:ReadOnly){return $false}
 Import-Module (Join-Path $script:PackageRoot 'DeploymentPairing.psm1') -DisableNameChecking
 $command=Get-Command Get-TCPairMaterialKind -ErrorAction SilentlyContinue
 if(-not $command){return $false}
 $kind=Get-TCPairMaterialKind -Material $Text
 if([string](ProfileUIField $kind 'Kind' '') -in @('Unknown','Invalid','ServerConnection','')){return $false}
 if(-not $kind.CanProcess){ErrorDialog '已识别交接类型，但资料缺少签名或加密保护，请使用管理端生成的原始资料。';return $true}
 ReceivePairMaterialUI -Material $Text;return $true
}
