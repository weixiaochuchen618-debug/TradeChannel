# Deployment, history and record detail share public read-only views.
. (Join-Path $PSScriptRoot 'NavigationContext.ps1')
. (Join-Path $PSScriptRoot 'DeploymentCenterPages.ps1')
function ShowUnifiedOperationHistory {
 $script:Role='operation-history';$script:Page='setup';Head '' '操作历史' '查看以往操作。隐藏只改变历史展示；已放弃的添加可在下方恢复填写。'
 $bar=New-Object Windows.Controls.WrapPanel
 AddC $bar (Btn '隐藏可整理的历史' 'ClearEndedOperations' {ClearEndedOperationHistoryUI} 'Btn')
 AddC $bar (Margin (Btn '刷新' 'RefreshOperationHistory' {$script:DeployUI.HistoryLoaded=$false;$script:DeployUI.DraftHistoryLoaded=$false;ShowUnifiedOperationHistory} 'Ghost') '10,0,0,0')
 AddC $bar (Margin (Btn '返回部署中心' 'HistoryBack' {ShowSetupCenter} 'Ghost') '10,0,0,0');AddC $script:HostPanel (Margin $bar '0,0,0,16')
 $filters=New-Object Windows.Controls.WrapPanel
 $search=ControlName (New-Object Windows.Controls.TextBox) 'HistorySearch';$search.Width=190;$search.MinHeight=34;$search.Text=[string](ProfileUIField $script:DeployUI 'HistorySearchText' '');$search.ToolTip='按服务器名称或操作名称筛选';AddC $filters $search
 $source=ControlName (New-Object Windows.Controls.ComboBox) 'HistorySourceFilter';$source.Width=170;$source.MinHeight=34;$source.Margin='10,0,0,0'
 foreach($entry in @(@('所有来源',''),@('线路准备','DeploymentRun'),@('旧版部署记录','LegacyLinuxJob'),@('服务器维护','ManagementIntent'))){$i=New-Object Windows.Controls.ComboBoxItem;$i.Content=$entry[0];$i.Tag=$entry[1];$null=$source.Items.Add($i);if([string]$i.Tag -eq [string](ProfileUIField $script:DeployUI 'HistorySourceKind' '')){$source.SelectedItem=$i}}
 AddC $filters $source
 $status=ControlName (New-Object Windows.Controls.ComboBox) 'HistoryStatusFilter';$status.Width=130;$status.MinHeight=34;$status.Margin='10,0,0,0'
 foreach($entry in @(@('所有结果',''),@('可隐藏','Ended'),@('需要处理','Attention'),@('需要保留','Protected'))){$i=New-Object Windows.Controls.ComboBoxItem;$i.Content=$entry[0];$i.Tag=$entry[1];$null=$status.Items.Add($i);if([string]$i.Tag -eq [string](ProfileUIField $script:DeployUI 'HistoryStatusKind' '')){$status.SelectedItem=$i}}
 AddC $filters $status
 $apply=Btn '筛选' 'ApplyHistoryFilters' {$script:DeployUI.HistorySearchText=$script:Controls.HistorySearch.Text;$script:DeployUI.HistorySourceKind=[string]$script:Controls.HistorySourceFilter.SelectedItem.Tag;$script:DeployUI.HistoryStatusKind=[string]$script:Controls.HistoryStatusFilter.SelectedItem.Tag;ShowUnifiedOperationHistory} 'Ghost';$apply.Margin='10,0,0,0';AddC $filters $apply
 AddC $script:HostPanel (Margin $filters '0,0,0,14')
 $selectedBar=New-Object Windows.Controls.WrapPanel;AddC $selectedBar (Btn '隐藏所选记录' 'ClearSelectedOperations' {ClearSelectedOperationHistoryUI} 'Ghost');AddC $selectedBar (Margin (Btn '导出当前摘要…' 'ExportOperationHistory' {ExportOperationHistoryUI} 'Ghost') '10,0,0,0');AddC $script:HostPanel (Margin $selectedBar '0,0,0,14')
 $check=ControlName (New-Object Windows.Controls.CheckBox) 'ShowClearedHistory';$check.Content='显示已隐藏记录';$check.IsChecked=[bool](ProfileUIField $script:DeployUI 'HistoryIncludeHidden' $false)
 $check.Add_Click({$script:DeployUI.HistoryIncludeHidden=[bool]$this.IsChecked;$script:DeployUI.HistoryLoaded=$false;ShowUnifiedOperationHistory});AddC $script:HostPanel (Margin $check '0,0,0,14')
 $visible=@(GetFilteredOperationHistoryUI);$script:DeployUI.HistoryVisibleRecords=$visible
 foreach($record in $visible){
  $card=Card '18,14';$p=Stack;$card.Child=$p;AddC $p (T ([string]$record.Name+' · '+(ManagementLabel ([string]$record.Status))) 14 $script:Ink 'SemiBold')
  AddC $p (Margin (T ((ManagementTime $record.UpdatedAtUtc)+' · '+(DeploymentSourceLabel ([string]$record.SourceKind))) 12 $script:Text3) '0,5,0,0')
  if($record.Protected){AddC $p (Margin (T '仍被当前线路、未完成操作或恢复资料引用，保留所需数据。' 12 '#A15C07') '0,6,0,0')}
  $b=Btn '查看记录' ('ViewHistory'+([string]$record.Id-replace '[^A-Za-z0-9]','')) {InvokeDeploymentHistoryRecord $this.Tag} 'Ghost';$b.Tag=$record;AddC $p $b
  if($record.Hidden){$b=Btn '恢复显示' ('RestoreHistory'+([string]$record.Id-replace '[^A-Za-z0-9]','')) {RestoreOperationHistoryUI ([string]$this.Tag)} 'Ghost';$b.Tag=$record.Id;AddC $p $b}
  if($record.CanClear -and -not $record.Hidden){
   $selected=ControlName (New-Object Windows.Controls.CheckBox) ('HistoryPick'+([string]$record.Id-replace '[^A-Za-z0-9]',''));$selected.Content='选择隐藏';$selected.Tag=$record.Id;AddC $p $selected
   $b=Btn '隐藏历史' ('ClearHistory'+([string]$record.Id-replace '[^A-Za-z0-9]','')) {ClearEndedOperationHistoryUI -Ids @([string]$this.Tag)} 'Ghost';$b.Tag=$record.Id;AddC $p $b
  }
  $details=([string]$record.Stage+' · '+[string]$record.Operation+' · '+(@($record.ProtectionReasons)-join ', '));$null=ManagementDetails $p $details '技术详情'
  AddC $script:HostPanel (Margin $card '0,0,0,10')
 }
 if(-not $visible.Count -and (ProfileUIField $script:DeployUI 'HistoryLoaded' $false)){AddC $script:HostPanel (Note '没有符合当前筛选条件的操作记录。')}
 ShowDiscardedDraftHistoryUI
 if(-not (ProfileUIField $script:DeployUI 'HistoryLoaded' $false) -and -not $script:Smoke -and -not (IsBusy)){
  $script:DeployUI.HistoryLoaded=$true
  $script:DeployUI.HistoryLoadContext=CaptureNavigationContext
  StartJob @{Action='OperationHistory';IncludeHidden=[bool](ProfileUIField $script:DeployUI 'HistoryIncludeHidden' $false)} {param($data)$script:DeployUI.HistoryRecords=@($data);if(TestNavigationContext $script:DeployUI.HistoryLoadContext){ShowUnifiedOperationHistory}} '读取操作历史…' -Failed {param($message)ErrorDialog $message}
 }elseif(-not (ProfileUIField $script:DeployUI 'DraftHistoryLoaded' $false) -and -not $script:Smoke -and -not (IsBusy)){
  $script:DeployUI.DraftHistoryLoaded=$true;$script:DeployUI.DraftHistoryLoadContext=CaptureNavigationContext
  StartJob @{Action='DraftDisposition'} {param($data)$script:DeployUI.DraftHistory=$data;if(TestNavigationContext $script:DeployUI.DraftHistoryLoadContext){ShowUnifiedOperationHistory}} '读取已放弃的添加…' -Failed {param($message)ErrorDialog $message}
 }
}
function ShowDiscardedDraftHistoryUI {
 $dto=ProfileUIField $script:DeployUI 'DraftHistory';$records=@(ProfileUIField $dto 'Records' @()|Where-Object {$_ -and (ProfileUIField $_ 'Discarded' $false)})
 $serverIds=@($records|ForEach-Object {$_.ServerRecordId});$rows=@($records)+@(ProfileUIField $dto 'Servers' @()|Where-Object {$_ -and (ProfileUIField $_ 'Discarded' $false) -and $_.ServerRecordId -notin $serverIds})
 $rows=@($rows|Sort-Object Id -Unique)
 if(-not $rows.Count){return}
 SectionLabel $script:HostPanel '已放弃的添加' '只保留原填写资料；恢复后重新核对，不会自动执行部署。'
 foreach($row in $rows){
  $card=Card '18,14';$p=Stack;$card.Child=$p;$id=[string]$row.Id;$control=$id-replace '[^A-Za-z0-9]',''
  AddC $p (T ([string](ProfileUIField $row 'Name' '未命名的添加')) 15 $script:Ink 'SemiBold')
  AddC $p (Margin (T ('已放弃 · '+(ManagementTime (ProfileUIField $row 'DiscardedAtUtc' ''))) 12 $script:Text3) '0,5,0,0')
  $b=Btn '查看记录' ('ViewDiscarded'+$control) {ShowOperationRecordDetail ([string]$this.Tag)} 'Ghost';$b.Tag=$id;AddC $p $b
  $b=Btn '恢复填写' ('RestoreDraft'+$control) {RestoreDeploymentDraftUI ([string]$this.Tag)} 'Btn';$b.Tag=$id;$b.IsEnabled=(-not $script:ReadOnly);AddC $p $b
  AddC $script:HostPanel (Margin $card '0,0,0,10')
 }
}
function ClearEndedOperationHistoryUI {param([string[]]$Ids)
 if(IsBusy -or $script:ReadOnly){return}
 $script:DeployUI.HistoryMutationContext=CaptureNavigationContext
 $request=@{Action='HistoryClearPreview'};if($Ids){$request.Ids=@($Ids)}
 StartJob $request {param($preview)
  if([int]$preview.EligibleCount -eq 0){Toast ('没有可隐藏的历史记录；保留 '+$preview.ProtectedCount+' 条所需记录。');return}
  StartJob @{Action='HistoryClearCommit';PreviewToken=[string]$preview.PreviewToken} {param($result)
   Toast ('已隐藏 '+$result.ClearedCount+' 条历史记录；保留 '+$result.ProtectedCount+' 条所需记录。')
   $script:DeployUI.Center=$null;$script:DeployUI.CenterLoaded=$false;$script:DeployUI.HistoryLoaded=$false;if(TestNavigationContext $script:DeployUI.HistoryMutationContext){ShowUnifiedOperationHistory}
  } '隐藏历史记录…' -Failed {param($message)ErrorDialog $message}
 } '核对可隐藏范围与当前引用…' -Failed {param($message)ErrorDialog $message}
}
function GetFilteredOperationHistoryUI {
 $query=[string](ProfileUIField $script:DeployUI 'HistorySearchText' '');$source=[string](ProfileUIField $script:DeployUI 'HistorySourceKind' '');$status=[string](ProfileUIField $script:DeployUI 'HistoryStatusKind' '')
 foreach($record in @(ProfileUIField $script:DeployUI 'HistoryRecords' @())){
  if(ProfileUIField $record 'DiscardedEffective' $false){continue}
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
 if(-not $ids.Count){Toast '请先选择可隐藏的历史记录。';return}
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
 $script:DeployUI.HistoryMutationContext=CaptureNavigationContext
 StartJob @{Action='HistoryRestore';Id=$Id} {param($data)$script:DeployUI.HistoryLoaded=$false;if(TestNavigationContext $script:DeployUI.HistoryMutationContext){ShowUnifiedOperationHistory};Toast '已恢复历史显示。'} '恢复记录显示…'
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
