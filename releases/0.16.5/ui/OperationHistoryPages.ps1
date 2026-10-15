# Deployment, history and record detail share public read-only views.
. (Join-Path $PSScriptRoot 'NavigationContext.ps1')
. (Join-Path $PSScriptRoot 'DeploymentCenterPages.ps1')
function RecordIsDeleted {param($Record) return ((ProfileUIField $Record 'Deleted' $false) -or (ProfileUIField $Record 'Hidden' $false))}
function RecordCanDelete {param($Record) return [bool](ProfileUIField $Record 'CanDeleteRecord' (ProfileUIField $Record 'CanClear' $false))}
function RecordDeleteBlockText {param($Record)
 switch([string](ProfileUIField $Record 'DeleteBlockReason' '')){
  'RelatedOperationActive'{'关联任务正在执行，结束后可删除这条记录。'}
  'NotOperationRecord'{'已保存线路请在线路页面管理。'}
  default{'任务正在执行，结束后可删除这条记录。'}
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
  $b=Btn '恢复记录' ('RestoreHistory'+$control) {RestoreOperationHistoryUI ([string]$this.Tag)} 'Btn';$b.Tag=$id;$b.IsEnabled=(-not $script:ReadOnly);AddC $bar $b
 }else{
  if($Discarded){$b=Btn '恢复填写' ('RestoreDraft'+$control) {RestoreDeploymentDraftUI ([string]$this.Tag)} 'Btn';$b.Tag=$id;$b.Margin='0,0,10,0';$b.IsEnabled=(-not $script:ReadOnly);AddC $bar $b}
  $b=Btn '删除记录…' ('DeleteHistory'+$control) {DeleteOperationRecordsUI -Ids @([string]$this.Tag)} 'Ghost';$b.Tag=$id;$b.IsEnabled=((RecordCanDelete $Record) -and -not $script:ReadOnly);AddC $bar $b
  if(-not (RecordCanDelete $Record)){$b.ToolTip=RecordDeleteBlockText $Record}
 }
 AddC $Parent (Margin $bar '0,8,0,0')
 if(-not $deleted -and -not (RecordCanDelete $Record)){AddC $Parent (Margin (T (RecordDeleteBlockText $Record) 12 $script:Text3) '0,4,0,0')}
}
function ShowUnifiedOperationHistory {
 $script:Role='operation-history';$script:Page='setup';Head '' '操作历史' '删除只移除列表记录，部署资料和线路保留。需要找回时，打开「显示已删除记录」。'
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
 $check=ControlName (New-Object Windows.Controls.CheckBox) 'ShowClearedHistory';$check.Content='显示已删除记录';$check.IsChecked=[bool](ProfileUIField $script:DeployUI 'HistoryIncludeHidden' $false)
 $check.Add_Click({$script:DeployUI.HistoryIncludeHidden=[bool]$this.IsChecked;$script:DeployUI.HistorySelectedIds=@();$script:DeployUI.HistoryLoaded=$false;ShowUnifiedOperationHistory});AddC $script:HostPanel (Margin $check '0,0,0,14')
 $visible=@(GetFilteredOperationHistoryUI);$script:DeployUI.HistoryVisibleRecords=@(GetFilteredOperationHistoryUI -AllGroups)
 foreach($record in $visible){
  $card=Card '18,14';$p=Stack;$card.Child=$p
  $label=if(RecordIsDeleted $record){'已删除'}elseif($record.SourceKind -eq 'ServerRecord'){[string](ProfileUIField $record 'StateLabel' '已登记')}else{ManagementLabel ([string]$record.Status)}
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
  elseif(ProfileUIField $script:DeployUI 'HistoryLoaded' $false){AddC $script:HostPanel (Note '没有符合当前筛选条件的记录。已删除的记录可打开上方开关后恢复。')}
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
  $label=if(RecordIsDeleted $row){'已删除 · 原为已放弃的添加'}else{'已放弃'}
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
function DeleteOperationRecordsUI {param([string[]]$Ids)
 if((IsBusy) -or $script:ReadOnly){return}
 if(-not $Ids -or -not $Ids.Count){Toast '请先选择要删除的记录。';return}
 $script:DeployUI.RecordDeletePending=@{Context=(CaptureNavigationContext);Ids=@($Ids|Sort-Object -Unique)}
 StartJob @{Action='RecordDeletePreview';Ids=@($script:DeployUI.RecordDeletePending.Ids)} {param($preview)
  $pending=$script:DeployUI.RecordDeletePending;$script:DeployUI.RecordDeletePending=$null
  if(-not $pending -or -not (TestNavigationContext $pending.Context)){return}
  if([int]$preview.EligibleCount -eq 0){Toast '所选记录正在执行或已删除，请刷新后重新选择。';return}
  $pending.PreviewToken=[string]$preview.PreviewToken
  $names=@(ProfileUIField $preview 'Eligible' @()|Select-Object -First 6|ForEach-Object {[string]$_.Name+' · '+(DeploymentSourceLabel ([string]$_.SourceKind))+' · '+(ManagementTime $_.UpdatedAtUtc)})
  $body='将从部署中心和操作历史移除 '+$preview.EligibleCount+' 条记录。'
  if($names.Count){$body+=[Environment]::NewLine+[Environment]::NewLine+($names -join [Environment]::NewLine)}
  if([int]$preview.EligibleCount -gt 6){$body+=[Environment]::NewLine+'另有 '+([int]$preview.EligibleCount-6)+' 条所选记录。'}
  if([int]$preview.ProtectedCount -gt 0){$body+=[Environment]::NewLine+'其中 '+$preview.ProtectedCount+' 条正在执行，本次保留。'}
  OpenDialog '删除所选记录？' $body '原部署资料、线路和密钥保留，服务继续运行。可在操作历史打开「显示已删除记录」后恢复。' '删除记录' {param($pending)
   if(-not $pending -or -not (TestNavigationContext $pending.Context) -or (IsBusy) -or $script:ReadOnly){return}
   $script:DeployUI.HistoryMutationContext=$pending.Context
   StartJob @{Action='RecordDeleteCommit';PreviewToken=[string]$pending.PreviewToken} {param($result)
    CompleteRecordListMutationUI;Toast ('已删除 '+$result.DeletedCount+' 条记录，可在操作历史中恢复。')
   } '删除列表记录…' -Failed {param($message)if(TestNavigationContext $script:DeployUI.HistoryMutationContext){ErrorDialog (RecordListErrorText $message)}else{Toast '删除记录未完成，请返回操作历史重试。'}}
  } '取消' 'Primary' $pending
 } '核对所选记录…' -Failed {param($message)$pending=$script:DeployUI.RecordDeletePending;$script:DeployUI.RecordDeletePending=$null;if($pending -and (TestNavigationContext $pending.Context)){ErrorDialog (RecordListErrorText $message)}}
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
 StartJob @{Action='RecordRestore';Id=$Id} {param($data)CompleteRecordListMutationUI;Toast '已恢复记录，原有进度保留。'} '恢复记录显示…' -Failed {param($message)if(TestNavigationContext $script:DeployUI.HistoryMutationContext){ErrorDialog (RecordListErrorText $message)}else{Toast '恢复记录未完成，请返回操作历史重试。'}}
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
