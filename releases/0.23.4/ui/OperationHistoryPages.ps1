# Deployment, history and record detail share public read-only views.
. (Join-Path $PSScriptRoot 'NavigationContext.ps1')
. (Join-Path $PSScriptRoot 'DeploymentCenterPages.ps1')
function RecordIsDeleted {param($Record) return ((ProfileUIField $Record 'Deleted' $false) -or (ProfileUIField $Record 'Hidden' $false))}
function RecordCanDelete {param($Record) return [bool](ProfileUIField $Record 'CanDeleteRecord' (ProfileUIField $Record 'CanClear' $false))}
function RecordDeleteBlockText {param($Record)
 switch([string](ProfileUIField $Record 'DeleteBlockReason' '')){
  'RelatedOperationActive'{'关联任务正在执行，结束后可删除这条记录。'}
  'NotOperationRecord'{'已保存线路请在线路页面管理。'}
  default{'这条记录的状态待确认，请先查看本机清理范围。'}
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
 $script:Role='operation-history';$script:Page='setup';Head '' '操作记录' ''
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
 AddC $bar (Margin (Btn '导出记录概况…' 'ExportOperationHistory' {ExportOperationHistoryUI} 'Ghost') '10,0,0,0');AddC $script:HostPanel (Margin $bar '0,0,0,10')
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
 SectionLabel $script:HostPanel '已放弃的添加' '可恢复填写或删除记录；继续前请重新确认资料。'
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
function NewLocalCleanupTargetUI {param([string[]]$Ids)
 $ids=@($Ids|Where-Object {-not [string]::IsNullOrWhiteSpace($_)}|Sort-Object -Unique)
 $scopes=@($ids|ForEach-Object {if($_ -clike 'Line:*'){'Line'}elseif($_ -clike 'ServerRecord:*'){'Server'}else{'DeploymentTask'}}|Sort-Object -Unique)
 if(-not $ids.Count -or $scopes.Count -ne 1){return $null}
 $scope=$scopes[0];$kind=switch($scope){Line{'线路'}Server{'服务器资料'}default{'任务记录'}}
 $names=@(foreach($id in $ids){
  $rows=@(if($scope -eq 'Line'){$script:Nodes|Where-Object {('Line:'+[string](ProfileUIField $_ LineId (ProfileUIField $_ id ''))) -ceq $id}}else{ProfileUIField $script:DeployUI HistoryRecords @()|Where-Object {[string]$_.Id -ceq $id}})
  if(-not $rows.Count -and $scope -ne 'Line'){
   $detail=ProfileUIField $script:DeployUI RecordDetail;$center=ProfileUIField $script:DeployUI Center
   $items=@($detail)+@(foreach($group in @('AttentionItems','ContinueItems','DraftItems','PreparedItems','AvailableServers')){ProfileUIField $center $group @()})
   $rows=@($items|Where-Object {[string](ProfileUIField $_ Id '') -ceq $id})
   $run=ProfileUIField $script:DeployUI Run
   if(-not $rows.Count -and ('DeploymentRun:'+[string](ProfileUIField $run RunId '')) -ceq $id){$rows=@($run)}
   if(-not $rows.Count -and $scope -eq 'Server'){
    $discovery=ProfileUIField $script:DeployUI Discovery
    $servers=@(ProfileUIField $discovery Servers @())+@(ProfileUIField $discovery ManagementServers @())+@(ProfileUIField $script:DeployUI Server)
    $rows=@($servers|Where-Object {('ServerRecord:'+[string](ProfileUIField $_ LocalRecordId '')) -ceq $id})
   }
  }
  if($rows.Count){[string](ProfileUIField $rows[0] Name $kind)}else{$kind}
 })
 $label=if($ids.Count -eq 1){'「'+$names[0]+'」'}else{'所选 '+$ids.Count+' 项'+$kind}
 return @{OperationId=[guid]::NewGuid().ToString('N');Context=(CaptureNavigationContext);Ids=$ids;Scope=$scope;Kind=$kind;Name=($names -join '、');Label=$label;Phase='New';PreviewToken='';Submitted=$false;Cancelled=$false;TransactionIds=@();RequestContext=$null;Message='';Details=''}
}
function TestLocalCleanupTargetUI {param($Pending)
 return ($Pending -and [object]::ReferenceEquals($Pending,(ProfileUIField $script:DeployUI RecordDeletePending)) -and -not $Pending.Cancelled)
}
function NewLocalCleanupRequestUI {param($Pending,[string]$Action)
 $context=@{Type='LocalCleanup';UiRequestId=[guid]::NewGuid().ToString('N');OperationId=$Pending.OperationId;Pending=$Pending;Action=$Action;Ids=@($Pending.Ids);PreviewToken=[string]$Pending.PreviewToken}
 $Pending.RequestContext=$context;return $context
}
function TestLocalCleanupRequestUI {param($Context)
 $pending=ProfileUIField $Context Pending
 return ((TestLocalCleanupTargetUI $pending) -and [object]::ReferenceEquals($Context,$pending.RequestContext) -and [string]$Context.OperationId -ceq [string]$pending.OperationId)
}
function OpenLocalCleanupDialogUI {param($Pending,[string]$Role,[string]$Title,[string]$Body,[string]$Confirm,[scriptblock]$Action,[string]$Cancel='返回',[string]$Style='Btn',[string]$Note='')
 $context=@{CleanupDialog=$Role;Pending=$Pending;Details=[string]$Pending.Details}
 OpenDialog $Title $Body $Note $Confirm $Action $Cancel $Style $context -SafeDefault
 # The existing dialog shell is shared by the legacy and WebView2 surfaces.
 # Keep diagnostics out of the primary copy; the web snapshot exposes the same
 # details to its <details> renderer. No XAML or generic dialog contract changes.
 $overlay=$script:Window.FindName('Overlay')
 if($overlay.GetType().GetEvent('IsVisibleChanged') -and -not (ProfileUIField $script:DeployUI CleanupDialogHooked $false)){
  $overlay.Add_IsVisibleChanged({
   if(-not $this.IsVisible){
    $dialog=$script:DialogContext
    if((ProfileUIField $dialog CleanupDialog '') -ceq 'PreviewWait' -and $dialog.Pending.Phase -eq 'Previewing'){CancelLocalCleanupPreviewUI ([string]$dialog.Pending.OperationId) -KeepDialog}
    if($script:CleanupDialogDetailsControl){$script:CleanupDialogDetailsControl.Visibility='Collapsed'}
   }
  });$script:DeployUI.CleanupDialogHooked=$true
 }
 $bodyControl=$script:Window.FindName('DialogBody');$parent=ProfileUIField $bodyControl Parent
 if($parent -and $parent.GetType().FullName -eq 'System.Windows.Controls.StackPanel'){
  if($script:CleanupDialogDetailsControl -and $script:CleanupDialogDetailsControl.Parent){$null=$script:CleanupDialogDetailsControl.Parent.Children.Remove($script:CleanupDialogDetailsControl)}
  $script:CleanupDialogDetailsControl=$null
  if($Pending.Details){$expander=New-Object Windows.Controls.Expander;$expander.Header='查看详情';$expander.Margin='0,12,0,0';$expander.IsExpanded=$false;$text=New-Object Windows.Controls.TextBlock;$text.Text=$Pending.Details;$text.TextWrapping='Wrap';$text.FontSize=12;$expander.Content=$text;$null=$parent.Children.Add($expander);$script:CleanupDialogDetailsControl=$expander}
 }
 if(Get-Command SyncTCWebState -ErrorAction SilentlyContinue){SyncTCWebState -Force}
}
function CancelLocalCleanupPreviewUI {param([string]$OperationId,[switch]$KeepDialog)
 $pending=ProfileUIField $script:DeployUI RecordDeletePending
 if(-not $pending -or $pending.OperationId -cne $OperationId -or $pending.Phase -notin @('Previewing','Ready') -or $pending.Submitted){return}
 $pending.Cancelled=$true;$pending.Phase='Cancelled';$pending.PreviewToken='';$pending.Message='已取消检查，'+$pending.Kind+'未删除。'
 if($pending.RequestContext -and (Get-Command CancelQueuedUiRequest -ErrorAction SilentlyContinue)){CancelQueuedUiRequest $pending.RequestContext.UiRequestId}
 if(-not $KeepDialog -and [object]::ReferenceEquals((ProfileUIField $script:DialogContext Pending),$pending)){CloseDialog}
 Toast $pending.Message
 if(Get-Command SyncTCWebState -ErrorAction SilentlyContinue){SyncTCWebState -Force}
}
function DeleteOperationRecordsUI {param([string[]]$Ids,[switch]$AbandonLocalTracking)
 if((IsBusy) -or $script:ReadOnly){return}
 $old=ProfileUIField $script:DeployUI RecordDeletePending
 if($old -and -not $old.Cancelled -and ($old.Phase -in @('Previewing','Checking','Submitted','OutcomeUnknown') -or ($old.Submitted -and $old.Phase -notin @('Deleted','NotApplied')))){Toast ($old.Label+'正在处理，请等待原操作结果。');return}
 if($old -and $old.Phase -eq 'Ready' -and [object]::ReferenceEquals((ProfileUIField $script:DialogContext Pending),$old)){return}
 $pending=NewLocalCleanupTargetUI $Ids
 if(-not $pending){Toast '请选择同一种类型的线路、任务或服务器资料。';return}
 $pending.AbandonLocalTracking=[bool]$AbandonLocalTracking;$script:DeployUI.RecordDeletePending=$pending
 RequestLocalCleanupPreviewUI $pending
}
function RequestLocalCleanupPreviewUI {param($Pending)
 if(-not (TestLocalCleanupTargetUI $Pending) -or $Pending.Submitted -or $script:ReadOnly){return}
 $Pending.Phase='Previewing';$Pending.PreviewToken='';$Pending.Message='正在检查'+$Pending.Label+'是否可删除';$Pending.WaitClock=[Diagnostics.Stopwatch]::StartNew()
 $context=NewLocalCleanupRequestUI $Pending 'RecordDeletePreview'
 OpenLocalCleanupDialogUI $Pending 'PreviewWait' $Pending.Message '正在检查本机使用情况，通常需要 10–20 秒。取消等待会保留资料。' '取消检查' {param($dialog)CancelLocalCleanupPreviewUI $dialog.Pending.OperationId} ''
 StartJob @{Action='RecordDeletePreview';Ids=@($Pending.Ids);AbandonLocalTracking=[bool]$Pending.AbandonLocalTracking} {
  param($preview,$context)CompleteLocalCleanupPreviewUI $preview $context
 } $Pending.Message -Silent -CallbackContext $context -Failed {
  param($message,$context,$failure)
  if(-not (TestLocalCleanupRequestUI $context)){return};$pending=$context.Pending;$pending.Phase='Blocked';$pending.Details=RecordListErrorText $message
  ShowLocalCleanupErrorUI $message ([string](ProfileUIField $failure Code '')) $pending
 } -Finalized {param($notice,$context)
  if((TestLocalCleanupRequestUI $context) -and $context.Pending.Phase -eq 'Previewing' -and $notice.Status -in @('Rejected','Cancelled','Failed','CallbackFailed')){
   $context.Pending.Phase='Blocked';$context.Pending.Message='检查尚未完成，'+$context.Pending.Kind+'未删除。'
   if([object]::ReferenceEquals((ProfileUIField $script:DialogContext Pending),$context.Pending)){CloseDialog}
  }
 }
}
function CompleteLocalCleanupPreviewUI {param($Preview,$Context)
 if(-not (TestLocalCleanupRequestUI $Context)){return};$pending=$Context.Pending
 $selected=@(ProfileUIField $Preview SelectedIds @())
 $matches=($selected.Count -eq $pending.Ids.Count -and @($selected|Where-Object {$_ -cnotin $pending.Ids}).Count -eq 0)
 $ready=($matches -and [int](ProfileUIField $Preview EligibleCount 0) -eq $pending.Ids.Count -and [string](ProfileUIField $Preview PreviewToken '') -and -not @(ProfileUIField $Preview Blocked @()).Count -and [string](ProfileUIField $Preview BusinessState 'PreviewReady') -ceq 'PreviewReady')
 $pending.Timings=ProfileUIField $Preview Timings
 $pending.Preview=$Preview;$pending.Phase=if($ready){'Ready'}else{'Blocked'}
 $pending.TransactionIds=@(@($pending.TransactionIds)+@(ProfileUIField $Preview TransactionIds @())+@(ProfileUIField $Preview Blocked @()|ForEach-Object {ProfileUIField $_ TransactionId ''})|Where-Object {$_ -cmatch '^[a-f0-9]{32}$'}|Sort-Object -Unique)
 $details=@('所选对象：'+($pending.Ids -join '、'))
 if($pending.TransactionIds.Count){$details+=,'原连接记录：'+($pending.TransactionIds -join '、')}
 $details+=@(ProfileUIField $Preview Blocked @()|ForEach-Object {[string](ProfileUIField $_ Code '')+'：'+[string](ProfileUIField $_ Message '')})
 $details+=@('关联任务 '+[int](ProfileUIField $Preview OperationCount 0)+' 项，线路 '+[int](ProfileUIField $Preview LineCount 0)+' 条，本机文件 '+[int](ProfileUIField $Preview FileCount 0)+' 个。')
 $details+=@(ProfileUIField $Preview Warnings @()|ForEach-Object {[string](ProfileUIField $_ Message '')})
 $preserved=@(ProfileUIField $Preview Preserved @());if($preserved.Count){$details+=,'保留：'+($preserved -join '；')}
 $pending.Details=$details -join [Environment]::NewLine
 if(-not $matches){$pending.Details='检查结果与所选对象不一致，请重新检查。'}
 $pending.Message=if($ready){$pending.Label+'尚未删除，等待确认。'}else{$pending.Label+'尚未删除，需要检查处理。'}
 if(-not (TestNavigationContext $pending.Context)){
  if([object]::ReferenceEquals((ProfileUIField $script:DialogContext Pending),$pending)){CloseDialog}
  Toast $pending.Message;return
 }
 if(-not $ready){ShowLocalCleanupBlockedUI $pending;return}
 $pending.PreviewToken=[string]$Preview.PreviewToken
 $body=switch($pending.Scope){
  Line{'将移除此电脑上的线路及仅供它使用的资料。服务器上的服务会保留。'}
  Server{'将移除此电脑上的服务器资料及本次列出的独占记录。服务器上的服务和设备授权会保留。'}
  default{'将清理所选任务记录及仅供它使用的本机资料。已保存线路和服务器上的服务会保留。'}
 }
 if(ProfileUIField $Preview RemoteOutcomeUnverified $false){$body+=[Environment]::NewLine+'服务器原操作结果待确认；此次仅清理本机记录，服务器现状保留。'}
 foreach($warning in @(ProfileUIField $Preview Warnings @()|Where-Object {[string](ProfileUIField $_ Code '') -eq 'LocalCandidateAbandonment'})){$body+=[Environment]::NewLine+[string]$warning.Message}
 OpenLocalCleanupDialogUI $pending 'Confirm' ('删除'+$pending.Label+'？') $body ('删除'+$pending.Kind) {param($dialog)SubmitLocalCleanupUI $dialog.Pending} '取消' 'Danger'
}
function ShowLocalCleanupBlockedUI {param($Pending)
 $Pending.Phase='Blocked';$Pending.Message=$Pending.Label+'尚未删除，需要检查处理。'
 if(-not (TestNavigationContext $Pending.Context)){Toast $Pending.Message;return}
 $codes=@(ProfileUIField $Pending.Preview Blocked @()|ForEach-Object {[string](ProfileUIField $_ Code '')})
 $body=if($codes -contains 'CurrentLine' -and (ProfileUIField $script:Overview Running $false) -and [string](ProfileUIField $script:Overview ActiveLineId '') -cin @($Pending.Ids|ForEach-Object {$_ -creplace '^Line:',''})){'这条线路正在使用，断开后可删除。线路尚未删除。'}else{'上次操作的清理结果还需要检查。'+$Pending.Kind+'尚未删除。'}
 OpenLocalCleanupDialogUI $Pending 'Blocked' ('暂时无法删除'+$Pending.Label) $body '检查并处理' {param($dialog)InspectLocalCleanupTargetUI $dialog.Pending} '返回'
}
function InspectLocalCleanupTargetUI {param($Pending)
 if(-not (TestLocalCleanupTargetUI $Pending) -or $script:ReadOnly -or (IsBusy) -or $Pending.Submitted){return}
 $Pending.Context=CaptureNavigationContext
 $executors=@(ProfileUIField $Pending.Preview Executors @())
 if($executors.Count){
  $Pending.Phase='Checking';$Pending.Executors=$executors
  StartUiCommand -Module 'DeploymentTransport.psm1' -Command 'Close-TCDeployIdleSessionsForCleanup' -Arguments @{Root=$script:Root;Executors=$executors;WaitSeconds=5} -Context $Pending -Complete {
   param($result,$pending)
   if(-not (TestLocalCleanupTargetUI $pending)){return}
   if($script:DeployUI.SessionRef -and [string]$script:DeployUI.SessionRef.InstanceId -cin @($pending.Executors|ForEach-Object {$_.SessionRef.InstanceId})){$script:DeployUI.SessionRef=$null;$script:DeployUI.SessionAttached=$false;$script:DeployUI.AccessAttemptId=[guid]::NewGuid().ToString();ClearDeploymentCredentialUI -KeepDraft}
   RequestLocalCleanupPreviewUI $pending
  } -Failed {param($message,$pending)if(TestLocalCleanupTargetUI $pending){$pending.Phase='Blocked';$pending.Details=$message;ShowLocalCleanupBlockedUI $pending}} -Message ('正在检查'+$Pending.Label+'的上次操作…')
  return
 }
 if(ProfileUIField $Pending.Preview CanAbandonLocalTracking $false){
  OpenLocalCleanupDialogUI $Pending 'Abandon' '只放弃本机跟踪？' '服务器原操作结果待确认。可先检查仅供此电脑使用的任务资料。' '检查本机清理范围' {param($dialog)
   $pending=$dialog.Pending;if(-not (TestLocalCleanupTargetUI $pending) -or $pending.Submitted){return};$pending.AbandonLocalTracking=$true;RequestLocalCleanupPreviewUI $pending
  } '保留并返回' 'Btn' '服务器上已执行的安装和授权会保留；本机清理不代表服务器操作已撤销。'
  return
 }
 # Inspect the original target first. This boundary is read-only and shares the
 # backend PID/birth validation; no unscoped reconciliation or reconnection.
 if($Pending.Scope -eq 'Line' -and (Get-Command ReadTCWebConnectionAttempt -ErrorAction SilentlyContinue)){
  $evidence=@(foreach($id in $Pending.Ids){
   $lineId=$id.Substring(5);$transactions=@($Pending.TransactionIds)
   if(-not $transactions.Count -and (Get-Variable WebConnectionAttempts -Scope Script -ErrorAction SilentlyContinue)){$attempt=$script:WebConnectionAttempts[$lineId];if($attempt){$transactions=@($attempt.TransactionId)}}
   foreach($transactionId in $transactions){$attempt=ReadTCWebConnectionAttempt $transactionId $lineId;if($attempt){$attempt}}
  })
  $Pending.TargetEvidence=$evidence;$Pending.TransactionIds=@($evidence|ForEach-Object {$_.TransactionId}|Sort-Object -Unique)
 }
 $Pending.Phase='Checking';$Pending.Message='正在检查'+$Pending.Label+'的使用情况'
 StartUiCommand -Module 'RuntimeBridge.psm1' -Command 'Get-TCConnectionUsageEvidence' -Arguments @{Root=$script:Root} -Context $Pending -Complete {
  param($evidence,$pending)
  if(-not (TestLocalCleanupTargetUI $pending)){return};$pending.UsageEvidence=$evidence;RequestLocalCleanupPreviewUI $pending
 } -Failed {param($message,$pending)
  if(TestLocalCleanupTargetUI $pending){$pending.Phase='Blocked';$pending.Details=$message;ShowLocalCleanupBlockedUI $pending}
 } -Message $Pending.Message
}
function GetLocalCleanupResultStateUI {param($Result,$Pending=$null)
 $deletedFlag=ProfileUIField $Result DataDeleted $null
 if($deletedFlag -is [bool] -and -not $deletedFlag -and [string](ProfileUIField $Result Outcome '') -cin @('NotApplied','RolledBack')){return 'NotApplied'}
 if([string](ProfileUIField $Result BusinessState 'Deleted') -cne 'Deleted'){return 'OutcomeUnknown'}
 if($deletedFlag -isnot [bool] -or -not $deletedFlag){if([string](ProfileUIField $Result Outcome '') -eq 'NotApplied'){return 'NotApplied'};return 'OutcomeUnknown'}
 $lines=@(ProfileUIField $Result DeletedLineIds @()|Where-Object {$_});$ids=@(ProfileUIField $Result DeletedIds @()|Where-Object {$_})
 if(-not $lines.Count -and -not $ids.Count){return 'OutcomeUnknown'}
 if($Pending){
  $selected=ProfileUIField $Result SelectedIds
  if($null -ne $selected -and (@($selected).Count -ne $Pending.Ids.Count -or @($selected|Where-Object {$_ -cnotin $Pending.Ids}).Count)){return 'OutcomeUnknown'}
  foreach($id in $Pending.Ids){if($id -clike 'Line:*'){if($id.Substring(5) -cnotin $lines){return 'OutcomeUnknown'}}elseif($id -cnotin $ids){return 'OutcomeUnknown'}}
 }
 return 'Deleted'
}
function SubmitLocalCleanupUI {param($Pending)
 if(-not (TestLocalCleanupTargetUI $Pending) -or $Pending.Phase -ne 'Ready' -or $Pending.Submitted -or -not $Pending.PreviewToken -or -not (TestNavigationContext $Pending.Context) -or (IsBusy) -or $script:ReadOnly){return}
 # Latch before dispatch; double clicks, rejected dispatch and unknown results
 # never authorize a second commit of this confirmation.
 $Pending.Submitted=$true;$Pending.Phase='Submitted';$Pending.Message='正在删除'+$Pending.Label
 $script:DeployUI.HistoryMutationContext=$Pending.Context
 $context=NewLocalCleanupRequestUI $Pending 'RecordDeleteCommit'
 StartJob @{Action='RecordDeleteCommit';PreviewToken=[string]$Pending.PreviewToken} {
  param($result,$context)
  if(-not (TestLocalCleanupRequestUI $context)){return}
  $pending=$context.Pending;$state=GetLocalCleanupResultStateUI $result $pending
  if($state -eq 'Deleted'){$null=CompleteLocalCleanupUI $result $pending}
  elseif($state -eq 'NotApplied'){CompleteLocalCleanupNotAppliedUI $pending}
  else{$pending.Phase='OutcomeUnknown';ShowOriginalLocalCleanupReceiptUI $pending;RequestLocalCleanupRefreshUI $pending}
 } $Pending.Message -CallbackContext $context -Failed {
  param($message,$context,$failure)
  if(-not (TestLocalCleanupRequestUI $context)){return};$pending=$context.Pending
  $pending.Details=RecordListErrorText $message
  $code=[string](ProfileUIField $failure Code '')
  # A bounded refusal is a known result. Only an absent/uncertain result keeps
  # the original commit latched; neither path repeats the deletion.
  if((ProfileUIField $failure OutcomeUnknown $true) -eq $false){
   if($code -ceq 'CleanupRecoveryRequired'){$pending.Phase='Blocked';ShowLocalCleanupErrorUI $message $code $pending}
   else{CompleteLocalCleanupNotAppliedUI $pending $code}
  }else{$pending.Phase='OutcomeUnknown';ShowLocalCleanupErrorUI $message $code $pending}
 } -Finalized {param($notice,$context)
  if((TestLocalCleanupRequestUI $context) -and $context.Pending.Phase -eq 'Submitted' -and $notice.Status -in @('Rejected','Failed','CallbackFailed','OutcomeUnknown')){
   if($notice.Status -eq 'Rejected' -or ($notice.Status -eq 'Failed' -and -not (ProfileUIField $notice RequestId ''))){
    $context.Pending.Phase='NotApplied';$context.Pending.Submitted=$false;$context.Pending.PreviewToken='';$context.Pending.Message=$context.Pending.Label+'尚未删除，本次操作未能提交。'
   }else{$context.Pending.Phase='OutcomeUnknown';$context.Pending.Message=$context.Pending.Label+'删除结果待确认，请勿重复删除。'}
   Toast $context.Pending.Message
  }
 }
}
function CompleteLocalCleanupNotAppliedUI {param($Pending,[string]$Code='')
 if(-not (TestLocalCleanupTargetUI $Pending)){return}
 $Pending.Phase='NotApplied';$Pending.Submitted=$false;$Pending.PreviewToken='';$Pending.ResultCheckActive=$false
 $Pending.Message=$Pending.Label+'未删除。'
 $body=if($Code -in @('CleanupPreviewStale','CleanupPreviewInvalid')){'检查后本机资料或使用情况有变化，旧确认已失效。重新检查后，可再次确认删除。'}else{'原操作已确认，本机资料仍在。重新检查后可再次确认删除。'}
 Toast $Pending.Message
 OpenLocalCleanupDialogUI $Pending 'NotApplied' ('尚未删除'+$Pending.Label) $body '重新检查并删除' {param($dialog)RetryLocalCleanupUI $dialog.Pending} '保留并返回'
 RequestLocalCleanupRefreshUI $Pending
}
function RetryLocalCleanupUI {param($Pending)
 if(-not (TestLocalCleanupTargetUI $Pending) -or $Pending.Submitted -or $Pending.Phase -cne 'NotApplied' -or (IsBusy) -or $script:ReadOnly){return}
 # Start a new preview and a new confirmation identity. Old callbacks remain
 # bound to their original target and cannot submit the new confirmation.
 DeleteOperationRecordsUI -Ids @($Pending.Ids) -AbandonLocalTracking:([bool]$Pending.AbandonLocalTracking)
}
function RequestLocalCleanupRefreshUI {param($Pending=$null)
 $old=ProfileUIField $script:DeployUI CleanupRefresh
 if(-not $Pending -and $old){$Pending=$old.Pending}
 $epoch=[long](ProfileUIField $script:DeployUI CleanupEpoch 0)
 if($old -and $old.Phase -eq 'Loading'){
  if([long]$old.Epoch -eq $epoch -and [object]::ReferenceEquals($old.Pending,$Pending)){return}
  $old.Phase='Superseded'
  if(Get-Command CancelQueuedUiRequest -ErrorAction SilentlyContinue){CancelQueuedUiRequest $old.UiRequestId}
 }
 $refresh=@{Type='LocalCleanupRefresh';UiRequestId=[guid]::NewGuid().ToString('N');Pending=$Pending;OperationId=[string](ProfileUIField $Pending OperationId '');Phase='Loading';Epoch=$epoch;Message='正在刷新线路列表…'}
 $script:DeployUI.CleanupRefresh=$refresh
 StartJob @{Action='Nodes'} {
  param($data,$refresh)
  if(-not [object]::ReferenceEquals($refresh,(ProfileUIField $script:DeployUI CleanupRefresh))){return}
  $deleted=@(ProfileUIField $script:DeployUI DeletedLineIds @())
  if(@($data|Where-Object {[string](ProfileUIField $_ LineId (ProfileUIField $_ id '')) -cin $deleted}).Count){FailLocalCleanupRefreshUI '读取结果仍包含已删除的线路，请重试刷新。' $refresh;return}
  $script:Nodes=@($data|Where-Object {$_});$refresh.Phase='Completed';$refresh.Message='线路列表已刷新。'
  if(Get-Command UpdateReadPresentation -ErrorAction SilentlyContinue){UpdateReadPresentation -DataChanged}
  if(Get-Command SyncTCWebState -ErrorAction SilentlyContinue){SyncTCWebState -Force}
 } '正在刷新线路列表…' -Silent -CallbackContext $refresh -Failed {param($message,$refresh)FailLocalCleanupRefreshUI $message $refresh} -Finalized {param($notice,$refresh)
  if([object]::ReferenceEquals($refresh,(ProfileUIField $script:DeployUI CleanupRefresh)) -and $refresh.Phase -eq 'Loading' -and $notice.Status -in @('Rejected','Cancelled','Failed','CallbackFailed')){FailLocalCleanupRefreshUI '线路列表暂未刷新，请重试读取。' $refresh}
 }
}
function FailLocalCleanupRefreshUI {param([string]$Message,$Refresh)
 if(-not [object]::ReferenceEquals($Refresh,(ProfileUIField $script:DeployUI CleanupRefresh))){return}
 $Refresh.Phase='Failed';$Refresh.Message=switch([string](ProfileUIField $Refresh.Pending Phase '')){'Deleted'{'已删除'+$Refresh.Pending.Label+'，列表暂未刷新。'}'NotApplied'{$Refresh.Pending.Label+'未删除，列表暂未刷新。'}default{'删除结果待确认，列表暂未刷新。'}}
 Toast $Refresh.Message
 if(TestNavigationContext (ProfileUIField $Refresh.Pending Context)){
  $details=[string](ProfileUIField $Refresh.Pending Details '');$Refresh.Pending.Details=$Message
  OpenLocalCleanupDialogUI $Refresh.Pending 'Refresh' '列表暂未刷新' $Refresh.Message '重试刷新' {param($dialog)RequestLocalCleanupRefreshUI $dialog.Pending} '稍后'
  $Refresh.Pending.Details=$details
 }
}
function ReadLocalCleanupReceiptUI {param($Pending)
 $id=[string](ProfileUIField $Pending CommitRequestId '')
 if($id -cnotmatch '^[a-f0-9]{32}$'){return $null}
 try{
  $receipt=Read-TCDJson -Path (Join-Path $script:JobRoot ($id+'.receipt.json')) -MaxBytes 65536
  if((ProfileUIField $receipt SchemaVersion 0) -ne 1 -or [string](ProfileUIField $receipt RequestId '') -cne $id -or [string](ProfileUIField $receipt Action '') -cne 'RecordDeleteCommit'){return $null}
  return $receipt
 }catch{return $null}
}
function CheckOriginalLocalCleanupResultUI {param($Pending)
 if(-not (TestLocalCleanupTargetUI $Pending) -or -not $Pending.Submitted -or $Pending.Phase -ne 'OutcomeUnknown' -or (ProfileUIField $Pending ResultCheckActive $false)){return}
 $Pending.ExecutorState=GetUiCleanupExecutorState $Pending
 if($Pending.ExecutorState -cne 'Exited'){
  $Pending.Details=if($Pending.ExecutorState -ceq 'Running'){'原删除任务仍在运行，请等待结束后检查结果。此次不会重复删除。'}else{'无法确认原删除任务是否已结束，保留原提交状态。'}
  ShowOriginalLocalCleanupReceiptUI $Pending;return
 }
 $Pending.ResultCheckActive=$true;$Pending.Message='正在检查'+$Pending.Label+'的原删除结果'
 if(-not $script:Smoke){RefreshUiJobReceipts}
 StartUiCommand -Module 'OperationHistory.psm1' -Command 'Get-TCLocalDeploymentCleanupOutcome' -Arguments @{Root=$script:Root;PreviewToken=[string]$Pending.PreviewToken} -Context $Pending -Complete {
  param($outcome,$pending)
  if(-not (TestLocalCleanupTargetUI $pending)){return};$pending.ResultCheckActive=$false
   if((GetUiCleanupExecutorState $pending) -cne 'Exited'){
    $pending.Details='原删除任务的退出情况尚未核实，继续保留原提交状态。';ShowOriginalLocalCleanupReceiptUI $pending;return
   }
  $state=[string](ProfileUIField $outcome Outcome '')
  if($state -ceq 'Completed' -and (ProfileUIField $outcome DataDeleted $false) -eq $true){
   try{
    $id=[string](ProfileUIField $outcome CleanupId '');$parsed=[guid]::Empty
    if(-not [guid]::TryParseExact($id,'D',[ref]$parsed) -or $parsed -eq [guid]::Empty){throw 'Cleanup identity missing'}
    $journal=Read-TCDJson -Path (Join-Path $script:Root ('local-cleanup\'+$id+'\journal.json'))
    $root=(Assert-TCDPath $script:Root).TrimEnd('\')
    if((ProfileUIField $journal SchemaVersion 0) -ne 1 -or [string](ProfileUIField $journal Id '') -cne $id -or [string](ProfileUIField $journal Status '') -cne 'Completed' -or [string](ProfileUIField $journal TokenDigest '') -cne (Get-TCDDigest ([string]$pending.PreviewToken)) -or [string](ProfileUIField $journal RootDigest '') -cne (Get-TCDDigest $root.ToLowerInvariant()) -or [string](ProfileUIField $journal UserSid '') -cne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value){throw 'Cleanup proof mismatch'}
    $result=ProfileUIField $journal Result
    if((GetLocalCleanupResultStateUI $result $pending) -cne 'Deleted'){throw 'Cleanup target mismatch'}
    $null=CompleteLocalCleanupUI $result $pending;return
   }catch{$pending.Details='原删除结果仍待确认，不会重复删除。'}
  }elseif($state -cin @('NotApplied','RolledBack')){
   if(-not $script:Smoke){RefreshUiJobReceipts};CompleteLocalCleanupNotAppliedUI $pending;return
  }
  ShowOriginalLocalCleanupReceiptUI $pending;RequestLocalCleanupRefreshUI $pending
 } -Failed {param($message,$pending)
  if(TestLocalCleanupTargetUI $pending){$pending.ResultCheckActive=$false;$pending.Details=RecordListErrorText $message;ShowOriginalLocalCleanupReceiptUI $pending}
 } -Message $Pending.Message
}
function ShowOriginalLocalCleanupReceiptUI {param($Pending)
 $Pending.Phase='OutcomeUnknown';$Pending.Message=$Pending.Label+'删除结果待确认，请勿重复删除。'
 $receipt=ReadLocalCleanupReceiptUI $Pending;$Pending.OriginalReceipt=$receipt
 if((GetUiCleanupExecutorState $Pending) -ceq 'Exited'){
  OpenLocalCleanupDialogUI $Pending 'OutcomeUnknown' '删除结果待确认' $Pending.Message '恢复并检查' {param($dialog)RecoverOriginalLocalCleanupUI $dialog.Pending} '稍后' 'Btn' '原删除任务已结束，可检查本机清理是否需要恢复。'
 }elseif($receipt){
  OpenLocalCleanupDialogUI $Pending 'OutcomeUnknown' '删除结果待确认' $Pending.Message '查看原删除记录' {param($dialog)
   $pending=$dialog.Pending;if(TestLocalCleanupTargetUI $pending){ShowUiReceiptDetail $pending.OriginalReceipt}
  } '稍后'
 }else{
  OpenLocalCleanupDialogUI $Pending 'OutcomeUnknown' '删除结果待确认' $Pending.Message '重新检查原结果' {param($dialog)CheckOriginalLocalCleanupResultUI $dialog.Pending} '稍后'
 }
}
function RecoverOriginalLocalCleanupUI {param($Pending)
 if(-not (TestLocalCleanupTargetUI $Pending) -or (GetUiCleanupExecutorState $Pending) -cne 'Exited' -or (IsBusy) -or $script:ReadOnly){return}
 $context=NewLocalCleanupRequestUI $Pending 'RecordCleanupRecover'
 StartJob @{Action='RecordCleanupRecover'} {param($result,$context)
  if(-not (TestLocalCleanupRequestUI $context)){return};$pending=$context.Pending
  if(-not $script:Smoke){RefreshUiJobReceipts}
  $completed=@(ProfileUIField $result CompletedResults @()|Where-Object {(GetLocalCleanupResultStateUI $_ $pending) -ceq 'Deleted'})
  if($completed.Count -eq 1){$null=CompleteLocalCleanupUI $completed[0] $pending;return}
  CheckOriginalLocalCleanupResultUI $pending
 } '恢复并检查原删除结果…' -CallbackContext $context -Failed {param($message,$context)
  if(TestLocalCleanupRequestUI $context){$context.Pending.Details=RecordListErrorText $message;ShowOriginalLocalCleanupReceiptUI $context.Pending}
 }
}
function CompleteLocalCleanupUI {param($Result,$Pending=$null)
 if((GetLocalCleanupResultStateUI $Result $Pending) -ne 'Deleted'){return $false}
 $return=if($Pending){$Pending.Context}else{ProfileUIField $script:DeployUI 'HistoryMutationContext'};$returnValid=TestNavigationContext $return
 $deleted=@(ProfileUIField $Result 'DeletedIds' @())
 $deletedLines=@(ProfileUIField $Result 'DeletedLineIds' @())
 foreach($cache in @('LinePreferenceRequests','LineCheckRequests','LineCheckResults','LineCardControls')){
  $dictionary=Get-Variable $cache -Scope Script -ValueOnly -ErrorAction SilentlyContinue
  if($dictionary -is [Collections.IDictionary]){foreach($id in $deletedLines){if($cache -eq 'LineCardControls' -and $dictionary[$id]){$dictionary[$id].Menu.IsOpen=$false};$dictionary.Remove($id)}}
 }
 if($script:LineProfileUI -and [string](ProfileUIField $script:LineProfileUI Id '') -in $deletedLines){$script:LineProfileUI=$null}
 if($script:ConnectionCompletionUI -and [string](ProfileUIField $script:ConnectionCompletionUI LineId '') -in $deletedLines){$script:ConnectionCompletionUI=$null}
 if(Get-Variable DeploymentTrustDecisions -Scope Script -ErrorAction SilentlyContinue){foreach($id in $deleted){if($id -clike 'DeploymentRun:*'){$script:DeploymentTrustDecisions.Remove($id.Substring(14))}}}
 if(('DeploymentRun:'+ [string](ProfileUIField (ProfileUIField $script:DeployUI 'Run') 'RunId' '')) -in $deleted){ClearDeploymentCredentialUI;$script:DeployUI.AccessAttemptId=[guid]::NewGuid().ToString();$script:DeployUI.PreparationConsent=$null;$script:DeployUI.TaskCredentialAvailable=$false;foreach($key in @('Run','SessionRef','Credential','RecoveredCredential')){$script:DeployUI[$key]=$null}}
 $script:DeployUI.Discovery=$null;$script:DeployUI.ServerDiscoveryAttempted=$false
 $script:DeployUI.Management=$null
 $script:Nodes=@($script:Nodes|Where-Object {[string](ProfileUIField $_ LineId (ProfileUIField $_ id '')) -cnotin $deletedLines})
 $script:DeployUI.DeletedLineIds=@(@(ProfileUIField $script:DeployUI DeletedLineIds @())+$deletedLines|Sort-Object -Unique)
 $script:DeployUI.CleanupEpoch=1+[long](ProfileUIField $script:DeployUI CleanupEpoch 0)
 if(Get-Variable UncertainUiJobs -Scope Script -ErrorAction SilentlyContinue){foreach($unrelatedJob in @($script:UncertainUiJobs.ToArray())){
   if(('DeploymentRun:'+ [string](ProfileUIField $unrelatedJob 'RunId' '')) -in $deleted){$null=$script:UncertainUiJobs.Remove($unrelatedJob);if($unrelatedJob.Process -and $unrelatedJob.Process.HasExited){$unrelatedJob.Process.Dispose()}}
 }}
 if(Get-Variable JobQueue -Scope Script -ErrorAction SilentlyContinue){foreach($queued in @($script:JobQueue.ToArray())){
  $request=$queued.Request
  if(('DeploymentRun:'+ [string](ProfileUIField $request 'RunId' '')) -in $deleted -or ('ServerRecord:'+ [string](ProfileUIField $request 'ServerId' '')) -in $deleted -or [string](ProfileUIField $request 'Id' '') -in @(ProfileUIField $Result 'DeletedLineIds' @())){$null=$script:JobQueue.Remove($queued)}
 };$script:QueuedJob=if($script:JobQueue.Count){$script:JobQueue[0]}else{$null}}
 InvalidateDeploymentLists;$script:DeployUI.HistorySelectedIds=@();$script:DeployUI.HistoryRecords=@(ProfileUIField $script:DeployUI HistoryRecords @()|Where-Object {[string]$_.Id -cnotin $deleted -and [string]$_.Id -cnotin @($deletedLines|ForEach-Object {'Line:'+$_})})
 if($Pending){$Pending.Phase='Deleted';$Pending.PreviewToken='';$Pending.Message='已删除'+$Pending.Label+'。';Toast $Pending.Message}
 if(-not $script:Smoke){RefreshUiJobReceipts}
 if($returnValid){
  if([string](ProfileUIField $return TargetId '') -cin @($deletedLines+$deleted)){
   if(-not (Get-Command ShowTCWebShell -ErrorAction SilentlyContinue) -or -not (ShowTCWebShell 'lines')){ShowNodes}
  }else{ReturnNavigationContext $return -SkipLineRefresh}
 }
 RequestLocalCleanupRefreshUI $Pending
 if(-not $script:Smoke -and (Get-Command RefreshOverview -ErrorAction SilentlyContinue)){RefreshOverview -Silent}
 return $true
}
function CompleteLocalCleanupRecoveryUI {param($Result)
 $deleted=@();$lines=@()
 foreach($completed in @(ProfileUIField $Result 'CompletedResults' @())){if((GetLocalCleanupResultStateUI $completed) -eq 'Deleted'){$deleted+=@(ProfileUIField $completed 'DeletedIds' @());$lines+=@(ProfileUIField $completed 'DeletedLineIds' @())}}
 if($deleted.Count -or $lines.Count){$null=CompleteLocalCleanupUI ([pscustomobject]@{DataDeleted=$true;DeletedIds=$deleted;DeletedLineIds=$lines})}
 else{RequestLocalCleanupRefreshUI;Toast '本机清理已检查，正在刷新列表。'}
}
function ShowLocalCleanupErrorUI {param([string]$Message,[string]$Code='',$Pending=$null)
 if($Pending -and -not (TestNavigationContext $Pending.Context)){Toast ($Pending.Label+'尚未确认删除，需要检查处理。');return}
 if($Pending -and $Pending.Phase -eq 'OutcomeUnknown'){
  $Pending.Message=$Pending.Label+'删除结果待确认，请勿重复删除。'
  OpenLocalCleanupDialogUI $Pending 'OutcomeUnknown' '删除结果待确认' $Pending.Message '检查原删除结果' {param($dialog)CheckOriginalLocalCleanupResultUI $dialog.Pending} '稍后'
  return
 }
 if($Code -eq 'CleanupRecoveryRequired' -or $Message -match '\[TC:CleanupRecoveryRequired\]'){
  OpenDialog '上次本机清理需要恢复' '原资料仍在本机。恢复会撤回未提交的清理，或完成已提交的清理，并检查原操作结果。' '只处理本机文件，不会重新部署服务器。' '完成本机恢复' {StartJob @{Action='RecordCleanupRecover'} {param($data)CompleteLocalCleanupRecoveryUI $data} '恢复本机清理…'} '返回' 'Btn'
 }elseif($Pending){$Pending.Details=RecordListErrorText $Message;ShowLocalCleanupBlockedUI $Pending}
 else{ErrorDialog (RecordListErrorText $Message)}
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
 StartJob @{Action='RecordRestore';Id=$Id} {param($data)CompleteRecordListMutationUI;Toast '已恢复显示，原有进度保留。'} '正在恢复显示…' -Failed {param($message)if(TestNavigationContext $script:DeployUI.HistoryMutationContext){ErrorDialog (RecordListErrorText $message)}else{Toast '恢复显示未完成，请返回操作历史重试。'}}
}
function ExportOperationHistoryUI {
 $summary=[pscustomobject]@{Kind='TradeChannel.OperationHistorySummary';ExportedAtUtc=[DateTimeOffset]::UtcNow.ToString('o');Records=@(GetFilteredOperationHistoryUI -AllGroups);ContainsCredentials=$false}
 if($script:Smoke){$script:ExportedHistoryFixture=$summary;return}
 $dialog=New-Object Microsoft.Win32.SaveFileDialog;$dialog.Title='导出记录概况';$dialog.Filter='记录概况 (*.json)|*.json';$dialog.FileName='TradeChannel-操作记录.json';$dialog.OverwritePrompt=$true
 if($dialog.ShowDialog()){
  [IO.File]::WriteAllText([IO.Path]::GetFullPath($dialog.FileName),($summary|ConvertTo-Json -Depth 10),(New-Object Text.UTF8Encoding($true)));Toast '已导出记录概况，不含密码、私钥或授权密文。'
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
 if(-not (DispatchUnifiedConnectionMaterial $text)){ErrorDialog '未识别为邀请、设备申请或加密授权，请检查资料类型。'}
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
