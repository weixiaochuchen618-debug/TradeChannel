# Deployment, history and record detail share public read-only views.
. (Join-Path $PSScriptRoot 'NavigationContext.ps1')
. (Join-Path $PSScriptRoot 'DeploymentCenterPages.ps1')
function RecordIsDeleted {param($Record) return ((ProfileUIField $Record 'Deleted' $false) -or (ProfileUIField $Record 'Hidden' $false))}
function RecordCanDelete {param($Record) return [bool](ProfileUIField $Record 'CanDeleteRecord' (ProfileUIField $Record 'CanClear' $false))}
function RecordDeleteBlockText {param($Record)
 switch([string](ProfileUIField $Record 'DeleteBlockReason' '')){
  'RelatedOperationActive'{'关联任务正在执行，结束后可删除这条记录。'}
  'NotOperationRecord'{'已保存线路请在线路页面管理。'}
  default{'这条记录还有待核对状态。可以先查看本机清理范围，再按实际结果处理。'}
 }
}
function GetFilteredOperationHistoryUI {param([switch]$DiscardedOnly,[switch]$AllGroups)
 $query=[string](ProfileUIField $script:DeployUI 'HistorySearchText' '');$source=[string](ProfileUIField $script:DeployUI 'HistorySourceKind' '');$status=[string](ProfileUIField $script:DeployUI 'HistoryStatusKind' '')
 foreach($record in @(ProfileUIField $script:DeployUI 'HistoryRecords' @())){
  if(-not $record){continue}
  $deleted=RecordIsDeleted $record
  if($deleted -and -not (ProfileUIField $script:DeployUI 'HistoryIncludeHidden' $false)){continue}
  $discarded=[bool](ProfileUIField $record 'DiscardedEffective' $false)
  if(-not $AllGroups -and $discarded -ne [bool]$DiscardedOnly){continue}
  if($source -and $record.SourceKind -ne $source){continue}
  if($query -and ([string]$record.Name+' '+[string](ProfileUIField $record 'Operation' '')).IndexOf($query,[StringComparison]::OrdinalIgnoreCase) -lt 0){continue}
  if($status -eq 'Ended' -and ($deleted -or -not (RecordCanDelete $record))){continue}
  if($status -eq 'Protected' -and ($deleted -or (RecordCanDelete $record))){continue}
  if($status -eq 'Attention' -and -not ((ProfileUIField $record 'AttentionRequired' $false) -or (ProfileUIField $record 'Classification' '') -eq 'Continue')){continue}
  $record
 }
}
function UpdateHistorySelectionUI {
 $eligible=@(ProfileUIField $script:DeployUI 'HistoryVisibleRecords' @()|Where-Object {$_ -and -not (RecordIsDeleted $_) -and (RecordCanDelete $_)})
 $selected=@(ProfileUIField $script:DeployUI 'HistorySelectedIds' @()|Where-Object {$_ -in @($eligible|ForEach-Object {$_.Id})}|Sort-Object -Unique)
 $script:DeployUI.HistorySelectedIds=$selected
 foreach($record in $eligible){$key='HistoryPick'+(DeploymentItemControlId $record);if($script:Controls.ContainsKey($key)){$script:Controls[$key].IsChecked=($record.Id -in $selected)}}
 if($script:Controls.ContainsKey('DeleteSelectedRecords')){$script:Controls.DeleteSelectedRecords.Content=('删除所选（'+$selected.Count+'）');$script:Controls.DeleteSelectedRecords.IsEnabled=($selected.Count -gt 0 -and -not $script:ReadOnly)}
 if($script:Controls.ContainsKey('SelectAllHistory')){$script:Controls.SelectAllHistory.Content=$(if($eligible.Count -gt 0 -and $selected.Count -eq $eligible.Count){'取消全选'}else{'全选当前结果'});$script:Controls.SelectAllHistory.IsEnabled=($eligible.Count -gt 0 -and -not $script:ReadOnly)}
 if($script:Controls.ContainsKey('HistorySelectionSummary')){$script:Controls.HistorySelectionSummary.Text=('当前结果 '+@(ProfileUIField $script:DeployUI 'HistoryVisibleRecords' @()).Count+' 条 · 可选择 '+$eligible.Count+' 条 · 已选择 '+$selected.Count+' 条')}
}
function SelectAllOperationHistoryUI {
 $eligible=@(ProfileUIField $script:DeployUI 'HistoryVisibleRecords' @()|Where-Object {$_ -and -not (RecordIsDeleted $_) -and (RecordCanDelete $_)})
 $selected=@(ProfileUIField $script:DeployUI 'HistorySelectedIds' @())
 $script:DeployUI.HistorySelectedIds=if($eligible.Count -gt 0 -and @($eligible|Where-Object {$_.Id -notin $selected}).Count -eq 0){@()}else{@($eligible|ForEach-Object {$_.Id})}
 UpdateHistorySelectionUI
}
function AddHistoryRecordActions {param($Parent,$Record,[switch]$Discarded)
 $bar=New-Object Windows.Controls.WrapPanel;$id=[string]$Record.Id;$control=DeploymentItemControlId $Record;$deleted=RecordIsDeleted $Record
 if(-not $deleted){
  $pick=ControlName (New-Object Windows.Controls.CheckBox) ('HistoryPick'+$control);$pick.Content='选择';$pick.Tag=$id;$pick.Margin='0,8,16,8';$pick.VerticalAlignment='Center'
  $pick.Style=$script:Window.FindResource('RecordSelection');$pick.IsEnabled=((RecordCanDelete $Record) -and -not $script:ReadOnly)
  $pick.Add_Click({
   $ids=@(ProfileUIField $script:DeployUI 'HistorySelectedIds' @()|Where-Object {$_ -cne [string]$this.Tag});if($this.IsChecked){$ids+=,[string]$this.Tag}
   $script:DeployUI.HistorySelectedIds=$ids;UpdateHistorySelectionUI
  });AddC $bar $pick
 }
 $b=Btn '查看记录' ($(if($Discarded){'ViewDiscarded'}else{'ViewHistory'})+$control) {ShowOperationRecordDetail ([string]$this.Tag)} 'Ghost';$b.Tag=$id;$b.Margin='0,0,10,0';AddC $bar $b
 if($deleted){
  $b=Btn '恢复显示' ('RestoreHistory'+$control) {RestoreOperationHistoryUI ([string]$this.Tag)} 'Btn';$b.Tag=$id;$b.IsEnabled=(-not $script:ReadOnly);AddC $bar $b
 }else{
  if($Discarded){$b=Btn '恢复填写' ('RestoreDraft'+$control) {RestoreDeploymentDraftUI ([string]$this.Tag)} 'Btn';$b.Tag=$id;$b.Margin='0,0,10,0';$b.IsEnabled=(-not $script:ReadOnly);AddC $bar $b}
  $b=Btn '清理本机资料…' ('DeleteHistory'+$control) {DeleteOperationRecordsUI -Ids @([string]$this.Tag)} 'Ghost';$b.Tag=$id;$b.IsEnabled=(-not $script:ReadOnly -and [string]$Record.SourceKind -ne 'Line');AddC $bar $b
  if(-not (RecordCanDelete $Record)){$b.ToolTip=RecordDeleteBlockText $Record}
 }
 AddC $Parent (Margin $bar '0,8,0,0')
 if(-not $deleted -and -not (RecordCanDelete $Record)){AddC $Parent (Margin (T (RecordDeleteBlockText $Record) 12 $script:Text3) '0,4,0,0')}
}
function ShowUnifiedOperationHistory {
 $script:Role='operation-history';$script:Page='setup';Head '' '操作历史' '删除会清理所选服务器在本机的部署资料。先预览关联范围，再确认；服务器上的服务保持原状。'
 $filters=New-Object Windows.Controls.WrapPanel
 $search=ControlName (New-Object Windows.Controls.TextBox) 'HistorySearch';$search.Width=190;$search.MinHeight=34;$search.Text=[string](ProfileUIField $script:DeployUI 'HistorySearchText' '');$search.ToolTip='按服务器名称或操作名称筛选';AddC $filters $search
 $source=ControlName (New-Object Windows.Controls.ComboBox) 'HistorySourceFilter';$source.Width=170;$source.MinHeight=34;$source.Margin='10,0,0,0'
 foreach($entry in @(@('所有来源',''),@('线路准备','DeploymentRun'),@('旧版部署记录','LegacyLinuxJob'),@('服务器维护','ManagementIntent'),@('服务器登记','ServerRecord'))){$i=New-Object Windows.Controls.ComboBoxItem;$i.Content=$entry[0];$i.Tag=$entry[1];$null=$source.Items.Add($i);if([string]$i.Tag -eq [string](ProfileUIField $script:DeployUI 'HistorySourceKind' '')){$source.SelectedItem=$i}}
 AddC $filters $source
 $status=ControlName (New-Object Windows.Controls.ComboBox) 'HistoryStatusFilter';$status.Width=130;$status.MinHeight=34;$status.Margin='10,0,0,0'
 foreach($entry in @(@('所有状态',''),@('可删除','Ended'),@('需要处理','Attention'),@('正在执行','Protected'))){$i=New-Object Windows.Controls.ComboBoxItem;$i.Content=$entry[0];$i.Tag=$entry[1];$null=$status.Items.Add($i);if([string]$i.Tag -eq [string](ProfileUIField $script:DeployUI 'HistoryStatusKind' '')){$status.SelectedItem=$i}}
 AddC $filters $status
 $apply=Btn '筛选' 'ApplyHistoryFilters' {$script:DeployUI.HistorySearchText=$script:Controls.HistorySearch.Text;$script:DeployUI.HistorySourceKind=[string]$script:Controls.HistorySourceFilter.SelectedItem.Tag;$script:DeployUI.HistoryStatusKind=[string]$script:Controls.HistoryStatusFilter.SelectedItem.Tag;$script:DeployUI.HistorySelectedIds=@();ShowUnifiedOperationHistory} 'Ghost';$apply.Margin='10,0,0,0';AddC $filters $apply;AddC $script:HostPanel (Margin $filters '0,0,0,14')
 $bar=New-Object Windows.Controls.WrapPanel
 AddC $bar (Btn '全选当前结果' 'SelectAllHistory' {SelectAllOperationHistoryUI} 'Btn')
 AddC $bar (Margin (Btn '删除所选（0）' 'DeleteSelectedRecords' {ClearSelectedOperationHistoryUI} 'Btn') '10,0,0,0')
 AddC $bar (Margin (Btn '刷新' 'RefreshOperationHistory' {$script:DeployUI.HistoryLoaded=$false;$script:DeployUI.HistorySelectedIds=@();ShowUnifiedOperationHistory} 'Ghost') '10,0,0,0')
 AddC $bar (Margin (Btn '返回部署中心' 'HistoryBack' {ShowSetupCenter} 'Ghost') '10,0,0,0')
 AddC $bar (Margin (Btn '导出当前摘要…' 'ExportOperationHistory' {ExportOperationHistoryUI} 'Ghost') '10,0,0,0');AddC $script:HostPanel (Margin $bar '0,0,0,10')
 $summary=ControlName (T '' 12 $script:Text3) 'HistorySelectionSummary';AddC $script:HostPanel (Margin $summary '0,0,0,12')
 $check=ControlName (New-Object Windows.Controls.CheckBox) 'ShowClearedHistory';$check.Content='显示旧版隐藏记录';$check.IsChecked=[bool](ProfileUIField $script:DeployUI 'HistoryIncludeHidden' $false)
 $check.Add_Click({$script:DeployUI.HistoryIncludeHidden=[bool]$this.IsChecked;$script:DeployUI.HistorySelectedIds=@();$script:DeployUI.HistoryLoaded=$false;ShowUnifiedOperationHistory});AddC $script:HostPanel (Margin $check '0,0,0,14')
 $visible=@(GetFilteredOperationHistoryUI);$script:DeployUI.HistoryVisibleRecords=@(GetFilteredOperationHistoryUI -AllGroups)
 foreach($record in $visible){
  $card=Card '18,14';$p=Stack;$card.Child=$p
  $label=if(RecordIsDeleted $record){'已隐藏（旧版）'}elseif($record.SourceKind -eq 'ServerRecord'){[string](ProfileUIField $record 'StateLabel' '已登记')}else{ManagementLabel ([string]$record.Status)}
  AddC $p (T ([string]$record.Name+' · '+$label) 14 $script:Ink 'SemiBold')
  AddC $p (Margin (T ((ManagementTime $record.UpdatedAtUtc)+' · '+(DeploymentSourceLabel ([string]$record.SourceKind))) 12 $script:Text3) '0,5,0,0')
  AddHistoryRecordActions $p $record
  $details=([string](ProfileUIField $record 'Stage' '')+' · '+[string](ProfileUIField $record 'Operation' '')+' · '+(@(ProfileUIField $record 'ProtectionReasons' @())-join ', '));$null=ManagementDetails $p $details '技术详情'
  AddC $script:HostPanel (Margin $card '0,0,0,10')
 }
 ShowDiscardedDraftHistoryUI
 UpdateHistorySelectionUI
 if(-not $script:DeployUI.HistoryVisibleRecords.Count){
  if(ProfileUIField $script:DeployUI 'HistoryError' ''){AddC $script:HostPanel (Note '记录读取未完成，请点击刷新重试。' 'amber')}
  elseif(ProfileUIField $script:DeployUI 'HistoryLoaded' $false){AddC $script:HostPanel (Note '没有符合当前筛选条件的记录。旧版隐藏的记录可打开上方开关后查看。')}
  else{AddC $script:HostPanel (Note '正在读取操作记录…')}
 }
 if(-not (ProfileUIField $script:DeployUI 'HistoryLoaded' $false) -and -not $script:Smoke -and -not (IsBusy)){
  $script:DeployUI.HistoryLoaded=$true;$script:DeployUI.HistoryLoadContext=CaptureNavigationContext
  StartJob @{Action='OperationHistory';IncludeHidden=[bool](ProfileUIField $script:DeployUI 'HistoryIncludeHidden' $false)} {param($data)$script:DeployUI.HistoryRecords=@($data|Where-Object {$_});$script:DeployUI.HistoryError='';if(TestNavigationContext $script:DeployUI.HistoryLoadContext){ShowUnifiedOperationHistory}} '读取操作历史…' -Failed {param($message)$script:DeployUI.HistoryError=$message;if(TestNavigationContext $script:DeployUI.HistoryLoadContext){ShowUnifiedOperationHistory;ErrorDialog $message}}
 }
}
function ShowDiscardedDraftHistoryUI {
 $rows=@(GetFilteredOperationHistoryUI -DiscardedOnly)
 if(-not $rows.Count){return}
 SectionLabel $script:HostPanel '已放弃的添加' '可恢复填写，也可以删除记录。恢复填写后需要重新核对资料。'
 foreach($row in $rows){
  $card=Card '18,14';$p=Stack;$card.Child=$p
  AddC $p (T ([string]$row.Name) 15 $script:Ink 'SemiBold')
  $label=if(RecordIsDeleted $row){'已隐藏 · 原为已放弃的添加'}else{'已放弃'}
  AddC $p (Margin (T ($label+' · '+(ManagementTime (ProfileUIField $row 'DiscardedAtUtc' ''))) 12 $script:Text3) '0,5,0,0')
  AddHistoryRecordActions $p $row -Discarded;AddC $script:HostPanel (Margin $card '0,0,0,10')
 }
}
function CompleteRecordListMutationUI {
 $return=ProfileUIField $script:DeployUI 'HistoryMutationContext'
 InvalidateDeploymentLists;$script:DeployUI.HistorySelectedIds=@();$script:DeployUI.HistoryRecords=@()
 if(TestNavigationContext $return){ReturnNavigationContext $return}
}
function RecordListErrorText {param([string]$Message)
 switch -Regex ($Message){
  '\[TC:HistoryPreviewStale\]' {return '记录在确认前发生了变化，请刷新后重新选择。此次未删除记录。'}
  '\[TC:HistoryPreviewInvalid\]' {return '这次确认信息已失效，请重新选择记录并确认。'}
  '\[TC:HistoryRecordMissing\]' {return '所选记录已变化或不再存在，请刷新列表。'}
  '\[TC:(HistoryBusy|Busy)\]' {return '另一个操作正在更新记录，请稍后重试。'}
  '\[TC:HistoryRemovalInvalid\]' {return '记录管理数据暂时无法读取，原部署资料仍保留。请重新读取记录。'}
  default {return $Message}
 }
}
function DeleteOperationRecordsUI {param([string[]]$Ids,[switch]$AbandonLocalTracking)
 if((IsBusy) -or $script:ReadOnly){return}
 if(-not $Ids -or -not $Ids.Count){Toast '请先选择要删除的记录。';return}
 $script:DeployUI.RecordDeletePending=@{Context=(CaptureNavigationContext);Ids=@($Ids|Sort-Object -Unique);AbandonLocalTracking=[bool]$AbandonLocalTracking}
 StartJob @{Action='RecordDeletePreview';Ids=@($script:DeployUI.RecordDeletePending.Ids);AbandonLocalTracking=[bool]$AbandonLocalTracking} {param($preview)
  $pending=$script:DeployUI.RecordDeletePending;$script:DeployUI.RecordDeletePending=$null
  if(-not $pending -or -not (TestNavigationContext $pending.Context)){return}
  if([int]$preview.EligibleCount -eq 0){
   $executors=@(ProfileUIField $preview 'Executors' @())
   if($executors.Count){
    $pending.Executors=$executors
    OpenDialog '核对并结束旧登录会话' '本机还保留这次准备的登录执行器。将先读取它的实际状态，只有当前没有服务器步骤执行时才正常关闭，然后重新核对清理范围。' '最多等待 5 秒确认退出；无法确认时保留资料并说明原因。不会强行中止服务器变更。' '核对空闲会话并继续' {param($pending)
     if(-not (TestNavigationContext $pending.Context) -or (IsBusy) -or $script:ReadOnly){return}
     StartUiCommand -Module 'DeploymentTransport.psm1' -Command 'Close-TCDeployIdleSessionsForCleanup' -Arguments @{Root=$script:Root;Executors=@($pending.Executors);WaitSeconds=5} -Context $pending -Complete {
      param($result,$pending)
      if(-not (TestNavigationContext $pending.Context)){return}
      if($script:DeployUI.SessionRef -and [string]$script:DeployUI.SessionRef.InstanceId -in @($pending.Executors|ForEach-Object {$_.SessionRef.InstanceId})){$script:DeployUI.SessionRef=$null;$script:DeployUI.SessionAttached=$false;$script:DeployUI.AccessAttemptId=[guid]::NewGuid().ToString();ClearDeploymentCredentialUI -KeepDraft}
      DeleteOperationRecordsUI -Ids $pending.Ids -AbandonLocalTracking:([bool]$pending.AbandonLocalTracking)
     } -Failed {param($message,$context)ErrorDialog $message} -Message '核对旧登录会话并等待正常退出…'
    } '返回' 'Btn' $pending
   }elseif(ProfileUIField $preview 'CanAbandonLocalTracking' $false){
    OpenDialog '只放弃本机跟踪？' '这条记录的远端结果尚未核对。可以删除本机任务、独占凭据和关联缓存，再由新任务重新检查服务器现状。' '服务器上已执行的安装和授权会保留。本机清理不会被记录为远端回滚。' '只放弃本机跟踪，核对清理范围' {param($pending)
     if((TestNavigationContext $pending.Context) -and -not (IsBusy) -and -not $script:ReadOnly){DeleteOperationRecordsUI -Ids $pending.Ids -AbandonLocalTracking}
    } '保留并返回' 'Btn' $pending
   }else{ErrorDialog ((@(ProfileUIField $preview 'Blocked' @()|ForEach-Object {$_.Message})) -join [Environment]::NewLine)}
   return
  }
  $pending.PreviewToken=[string]$preview.PreviewToken
  $names=@(ProfileUIField $preview 'Targets' @()|ForEach-Object {[string]$_.Name+' · '+$(if($_.Endpoint){$_.Endpoint}else{'无有效接入地址的登记'})})
  $body=($names -join [Environment]::NewLine)+[Environment]::NewLine+[Environment]::NewLine+'将清理 '+$preview.ServerCount+' 个服务器身份、'+$preview.OperationCount+' 项部署操作、'+$preview.LineCount+' 份本机线路配置及 '+$preview.FileCount+' 个关联文件。'
  $body+=[Environment]::NewLine+'包括同一登录地址的旧身份、部署资料、已保存凭据、检测缓存和后台回执。'
  foreach($warning in @(ProfileUIField $preview 'Warnings' @())){if(ProfileUIField $warning 'Message' ''){$body+=[Environment]::NewLine+[string]$warning.Message}}
  if(ProfileUIField $preview 'RemoteOutcomeUnverified' $false){$body+=[Environment]::NewLine+'服务器原操作结果仍未核对；本次仅放弃本机跟踪，服务器现状保留。'}
  $preserved=@(ProfileUIField $preview 'Preserved' @());if($preserved.Count){$body+=[Environment]::NewLine+'保留：'+($preserved -join '；')}
  OpenDialog '删除本机部署资料？' $body '确认后无法从操作历史恢复。这不会卸载服务器服务或撤销远端设备授权；再次部署将从新的本机记录开始。' '删除本机资料' {param($pending)
   if(-not $pending -or -not (TestNavigationContext $pending.Context) -or (IsBusy) -or $script:ReadOnly){return}
   $script:DeployUI.HistoryMutationContext=$pending.Context
   StartJob @{Action='RecordDeleteCommit';PreviewToken=[string]$pending.PreviewToken} {param($result)
    CompleteLocalCleanupUI $result;Toast '已清理对应的本机部署资料，可以重新添加线路。'
   } '清理本机部署资料…' -Failed {param($message,$context,$failure)ShowLocalCleanupErrorUI $message ([string](ProfileUIField $failure 'Code' ''))}
  } '取消' 'Primary' $pending
 } '核对完整清理范围…' -Failed {param($message,$context,$failure)$script:DeployUI.RecordDeletePending=$null;ShowLocalCleanupErrorUI $message ([string](ProfileUIField $failure 'Code' ''))}
}
function CompleteLocalCleanupUI {param($Result)
 $deleted=@(ProfileUIField $Result 'DeletedIds' @())
 if(('DeploymentRun:'+ [string](ProfileUIField (ProfileUIField $script:DeployUI 'Run') 'RunId' '')) -in $deleted){ClearDeploymentCredentialUI;$script:DeployUI.AccessAttemptId=[guid]::NewGuid().ToString();$script:DeployUI.PreparationConsent=$null;$script:DeployUI.TaskCredentialAvailable=$false;foreach($key in @('Run','SessionRef','Credential','RecoveredCredential')){$script:DeployUI[$key]=$null}}
 $script:DeployUI.Discovery=$null;$script:DeployUI.ServerDiscoveryAttempted=$false
 $script:DeployUI.Management=$null;$script:Nodes=@()
 if(Get-Variable UncertainUiJobs -Scope Script -ErrorAction SilentlyContinue){foreach($pending in @($script:UncertainUiJobs.ToArray())){
  if(('DeploymentRun:'+ [string](ProfileUIField $pending 'RunId' '')) -in $deleted){$null=$script:UncertainUiJobs.Remove($pending);if($pending.Process -and $pending.Process.HasExited){$pending.Process.Dispose()}}
 }}
 if(Get-Variable JobQueue -Scope Script -ErrorAction SilentlyContinue){foreach($queued in @($script:JobQueue.ToArray())){
  $request=$queued.Request
  if(('DeploymentRun:'+ [string](ProfileUIField $request 'RunId' '')) -in $deleted -or ('ServerRecord:'+ [string](ProfileUIField $request 'ServerId' '')) -in $deleted -or [string](ProfileUIField $request 'Id' '') -in @(ProfileUIField $Result 'DeletedLineIds' @())){$null=$script:JobQueue.Remove($queued)}
 };$script:QueuedJob=if($script:JobQueue.Count){$script:JobQueue[0]}else{$null}}
 CompleteRecordListMutationUI
 if(-not $script:Smoke){RefreshUiJobReceipts;FetchNodes};ShowSetupCenter
}
function CompleteLocalCleanupRecoveryUI {param($Result)
 $deleted=@();$lines=@()
 foreach($completed in @(ProfileUIField $Result 'CompletedResults' @())){$deleted+=@(ProfileUIField $completed 'DeletedIds' @());$lines+=@(ProfileUIField $completed 'DeletedLineIds' @())}
 CompleteLocalCleanupUI ([pscustomobject]@{DeletedIds=$deleted;DeletedLineIds=$lines})
}
function ShowLocalCleanupErrorUI {param([string]$Message,[string]$Code='')
 if($Code -eq 'CleanupRecoveryRequired' -or $Message -match '\[TC:CleanupRecoveryRequired\]'){
  OpenDialog '上次本机清理需要恢复' '清理被中断，原资料仍保存在本机。恢复会回退未提交的清理，或完成已经提交的清理，并核对原后台回执。' '只处理本机文件，不会重新部署服务器。' '完成本机恢复' {StartJob @{Action='RecordCleanupRecover'} {param($data)CompleteLocalCleanupRecoveryUI $data} '恢复本机清理…'} '返回' 'Btn'
 }else{ErrorDialog (RecordListErrorText $Message)}
}
function ClearSelectedOperationHistoryUI {
 $ids=@(foreach($record in @(ProfileUIField $script:DeployUI 'HistoryVisibleRecords' @())){
  $key='HistoryPick'+(DeploymentItemControlId $record)
  if(-not (RecordIsDeleted $record) -and (RecordCanDelete $record) -and $script:Controls.ContainsKey($key) -and $script:Controls[$key].IsChecked){[string]$record.Id}
 })
 DeleteOperationRecordsUI -Ids $ids
}
function RestoreOperationHistoryUI {param([string]$Id)
 if((IsBusy) -or $script:ReadOnly){return}
 $script:DeployUI.HistoryMutationContext=CaptureNavigationContext
 StartJob @{Action='RecordRestore';Id=$Id} {param($data)CompleteRecordListMutationUI;Toast '已恢复显示，原有进度保留。'} '恢复显示显示…' -Failed {param($message)if(TestNavigationContext $script:DeployUI.HistoryMutationContext){ErrorDialog (RecordListErrorText $message)}else{Toast '恢复显示未完成，请返回操作历史重试。'}}
}
function ExportOperationHistoryUI {
 $summary=[pscustomobject]@{Kind='TradeChannel.OperationHistorySummary';ExportedAtUtc=[DateTimeOffset]::UtcNow.ToString('o');Records=@(GetFilteredOperationHistoryUI -AllGroups);ContainsCredentials=$false}
 if($script:Smoke){$script:ExportedHistoryFixture=$summary;return}
 $dialog=New-Object Microsoft.Win32.SaveFileDialog;$dialog.Title='导出操作状态摘要';$dialog.Filter='JSON 摘要 (*.json)|*.json';$dialog.FileName='TradeChannel-操作记录.json';$dialog.OverwritePrompt=$true
 if($dialog.ShowDialog()){
  [IO.File]::WriteAllText([IO.Path]::GetFullPath($dialog.FileName),($summary|ConvertTo-Json -Depth 10),(New-Object Text.UTF8Encoding($true)));Toast '已导出状态摘要，不包含密码、私钥或授权密文。'
 }
}
function OpenUnifiedConnectionMaterial {
 if($script:ReadOnly){ErrorDialog '只读窗口不导入接入资料。';return}
 $path=ChooseFile '打开邀请、授权或已有连接配置' '连接资料 (*.json;*.conf;*.zip;*.tcinvite;*.tcauth)|*.json;*.conf;*.zip;*.tcinvite;*.tcauth|所有文件 (*.*)|*.*'
 if(-not $path){return}
 # Existing configuration files remain subject to ImportNode validation.
 # The handoff-text limit does not apply to WireGuard configuration archives.
 if([IO.Path]::GetExtension($path) -iin @('.conf','.zip')){BeginWizard 'client' -ConfigurationPath $path;return}
 if((Get-Item -LiteralPath $path).Length -gt 1MB){ErrorDialog '接入资料超过允许大小。';return}
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
