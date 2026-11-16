# All list/record reads are presentation-only. Execution uses an explicit, refreshed entry.
function InvalidateDeploymentLists {
 $script:DeployUI.Center=$null;$script:DeployUI.CenterLoaded=$false;$script:DeployUI.HistoryLoaded=$false;$script:DeployUI.DraftHistoryLoaded=$false;$script:DeployUI.RecordDetail=$null
}
function DeploymentItemId {param($Item) [string](ProfileUIField $Item 'Id' '')}
function DeploymentItemControlId {param($Item) (DeploymentItemId $Item) -replace '[^A-Za-z0-9]',''}
function DeploymentSourceLabel {param([string]$Kind)
 switch($Kind){'DeploymentRun'{'线路准备'}'LegacyLinuxJob'{'旧版部署记录'}'ManagementIntent'{'服务器维护'}'ServerRecord'{'服务器登记'}default{'准备记录'}}
}
function DraftBlockText {param([string]$Code)
 if(-not $Code){return ''}
 switch($Code){'ExecutorActive'{'本次准备仍在执行，请等待结束。'}'AlreadyDiscarded'{'这次添加已放弃，可恢复填写。'}default{'已有进度、关联资料或待确认状态，请保留记录并查看详情。'}}
}
function AddDeploymentCenterItem {param($Parent,$Item,[switch]$Draft)
 $row=Card '18,15';$panel=Stack;$row.Child=$panel;$id=DeploymentItemControlId $Item
 AddC $panel (T ([string](ProfileUIField $Item 'Name' '未命名的添加')) 16 $script:Ink 'SemiBold')
 $state=[string](ProfileUIField $Item 'StateLabel' '记录状态待确认');AddC $panel (Margin (T $state 13 $script:Ink 'SemiBold') '0,6,0,0')
 $reason=[string](ProfileUIField $Item 'Reason' '');if($reason){AddC $panel (Margin (T $reason 12.5 $script:Text2) '0,4,0,0')}
 $meta=@((DeploymentSourceLabel ([string](ProfileUIField $Item 'SourceKind' (ProfileUIField $Item 'Kind' '')))),[string](ProfileUIField $Item 'TargetLabel' ''))|Where-Object {$_}
 $at=ProfileUIField $Item 'UpdatedAtUtc';if($at){$meta+=('更新于 '+(ManagementTime $at))}
 AddC $panel (Margin (T ($meta -join ' · ') 11.5 $script:Text3) '0,6,0,0')
 $bar=New-Object Windows.Controls.WrapPanel
 $label=[string](ProfileUIField $Item 'EntryLabel' '查看记录详情');$action=[string](ProfileUIField $Item 'EntryAction' 'ViewRecord')
 $b=Btn $label ('CentreAction'+$id) {InvokeDeploymentCenterAction $this.Tag} 'Btn';$b.Tag=$Item;$b.Margin='0,10,10,0';AddC $bar $b
 if($action -ne 'ViewRecord'){$details=Btn '查看记录' ('CentreDetails'+$id) {ShowOperationRecordDetail ([string]$this.Tag)} 'Ghost';$details.Tag=DeploymentItemId $Item;$details.Margin='0,10,10,0';AddC $bar $details}
 if($Draft -and (ProfileUIField $Item 'CanDiscardDraft' $false)){$remove=Btn '放弃本次添加' ('DiscardDraft'+$id) {DiscardDeploymentDraftUI ([string]$this.Tag)} 'Ghost';$remove.Tag=DeploymentItemId $Item;$remove.Margin='0,10,0,0';$remove.IsEnabled=(-not $script:ReadOnly);AddC $bar $remove}
 if([string](ProfileUIField $Item 'SourceKind' '') -ne 'Line'){
  $remove=Btn '删除记录…' ('CentreDelete'+$id) {DeleteOperationRecordsUI -Ids @([string]$this.Tag)} 'Ghost';$remove.Tag=DeploymentItemId $Item;$remove.Margin='0,10,0,0';$remove.IsEnabled=((RecordCanDelete $Item) -and -not $script:ReadOnly);AddC $bar $remove
  if(-not (RecordCanDelete $Item)){$remove.ToolTip=RecordDeleteBlockText $Item;AddC $panel (Margin (T (RecordDeleteBlockText $Item) 12 $script:Text3) '0,8,0,0')}
 }
 AddC $panel $bar;AddC $Parent (Margin $row '0,0,0,10')
}
function ShowSetupCenter {
 $script:Step=0;$script:Role='deployment-center';$script:Page='setup';SetNavigationContext 'setup' 'deployment-center'
 Head '' '部署中心' '添加线路或继续部署。已有线路请到「线路」管理。'
 $card=Card '20,18';$p=Stack;$card.Child=$p
 AddC $p (T '为这台电脑添加线路' 19 $script:Ink 'SemiBold')
 AddC $p (Margin (T '填写服务器资料，或打开收到的连接资料。' 13 $script:Text2) '0,6,0,0')
 $bar=New-Object Windows.Controls.WrapPanel
 AddC $bar (Btn '添加线路' 'DeployAddLine' {BeginProductDeployment 'Auto'} 'Primary')
 AddC $bar (Margin (Btn '打开连接资料…' 'OpenConnectionMaterial' {OpenUnifiedConnectionMaterial} 'Btn') '10,0,0,0')
 AddC $p (Margin $bar '0,14,0,0')
 $links=New-Object Windows.Controls.WrapPanel
 foreach($spec in @(
  @{Text='还没有服务器？购买准备';Id='CentrePurchase';Click={ShowPurchasePreparation}},
  @{Text='迁移到新电脑';Id='OpenMigration';Click={ShowMigration}},
  @{Text='Windows Server 部署';Id='SetupWinServer';Click={BeginWizard 'server'}},
  @{Text='导入管理恢复资料';Id='CentreRecoveryImport';Click={ShowManagementRecovery -Mode Import}}
 )){$b=Btn $spec.Text $spec.Id $spec.Click 'Ghost';$b.Margin='0,10,12,0';AddC $links $b}
 AddC $p $links;AddC $script:HostPanel (Margin $card '0,0,0,12')
 $tools=New-Object Windows.Controls.WrapPanel
 AddC $tools (Btn '操作记录' 'UnifiedOperationHistory' {ShowUnifiedOperationHistory} 'Ghost')
 AddC $tools (Margin (Btn '刷新记录' 'RefreshDeploymentCenter' {$script:DeployUI.CenterLoaded=$false;ShowSetupCenter} 'Ghost') '10,0,0,0')
 AddC $script:HostPanel (Margin $tools '0,0,0,8')
 $centre=ProfileUIField $script:DeployUI 'Center'
 if(-not $centre){AddC $script:HostPanel (Note $(if(ProfileUIField $script:DeployUI 'CenterError' ''){'记录读取未完成，请点击刷新记录重试。'}else{'正在读取准备进度…'}))}
 else{
  if(@(ProfileUIField $centre 'CleanupPending' @()).Count){
   AddC $script:HostPanel (Note '上次本机清理被中断。请先完成本机恢复，再添加线路。' 'amber')
   AddC $script:HostPanel (Btn '完成本机恢复' 'RecoverLocalCleanup' {ShowLocalCleanupErrorUI '[TC:CleanupRecoveryRequired]'} 'Btn')
  }
  $attention=@(ProfileUIField $centre 'AttentionItems' @());$continued=@(ProfileUIField $centre 'ContinueItems' @());$drafts=@(ProfileUIField $centre 'DraftItems' @());$prepared=@(ProfileUIField $centre 'PreparedItems' @())
  foreach($group in @(@{Title='需要处理';Items=$attention;Hint='先查看原因，再处理对应步骤'},@{Title='继续准备';Items=$continued;Hint='继续原任务，保留已完成的进度'})){
   if(@($group.Items).Count){SectionLabel $script:HostPanel ($group.Title+'（'+@($group.Items).Count+'）') $group.Hint;foreach($item in $group.Items){AddDeploymentCenterItem $script:HostPanel $item}}
  }
  if(-not $attention.Count -and -not $continued.Count){AddC $script:HostPanel (Margin (Note '没有待继续的部署任务。') '0,10,0,0')}
  if($drafts.Count){
   $content=Stack;AddC $content (Margin (T '展开草稿可继续填写，或放弃这次添加。' 12.5 $script:Text2) '0,8,0,12')
   foreach($draft in $drafts){AddDeploymentCenterItem $content $draft -Draft}
   $exp=ControlName (New-Object Windows.Controls.Expander) 'DeploymentDrafts';$exp.Header=('已保存草稿（'+$drafts.Count+'）');$exp.Content=$content;$exp.Margin='0,20,0,0'
   $exp.IsExpanded=[bool](ProfileUIField $script:DeployUI 'DraftsExpanded' $false)
   $exp.Add_Expanded({$script:DeployUI.DraftsExpanded=$true});$exp.Add_Collapsed({$script:DeployUI.DraftsExpanded=$false});AddC $script:HostPanel $exp
  }
  $servers=@(ProfileUIField $centre 'AvailableServers' @());if($servers.Count){
   $b=Btn ('管理已识别服务器（'+$servers.Count+'）') 'CentreServerDirectory' {OpenServerManagement -ReturnKind DeploymentCenter} 'Ghost';AddC $script:HostPanel (Margin $b '0,16,0,0')
  }
 }
 if(-not $script:Smoke -and -not (IsBusy) -and -not (ProfileUIField $script:DeployUI 'CenterLoaded' $false) -and -not (ProfileUIField $script:DeployUI 'CenterLoading' $false)){
  $script:DeployUI.CenterLoading=$true;$script:DeployUI.CenterLoadContext=CaptureNavigationContext
  StartJob @{Action='DeploymentCenter'} {param($data)$script:DeployUI.Center=$data;$script:DeployUI.CenterError='';$script:DeployUI.CenterLoading=$false;$script:DeployUI.CenterLoaded=$true;if(TestNavigationContext $script:DeployUI.CenterLoadContext){ShowSetupCenter}} '读取部署中心…' -Failed {param($message)$script:DeployUI.CenterLoading=$false;$script:DeployUI.CenterLoaded=$true;$script:DeployUI.CenterError=$message;if(TestNavigationContext $script:DeployUI.CenterLoadContext){ShowSetupCenter;Toast '部署记录暂时无法读取，请稍后刷新'}}
 }
}
function InvokeDeploymentCenterAction {param($Item)
 if(IsBusy){return};$id=DeploymentItemId $Item
 if(-not $id){ErrorDialog '记录缺少明确标识，请刷新后重试。';return}
 if([string](ProfileUIField $Item 'EntryAction' 'ViewRecord') -eq 'ViewRecord'){ShowOperationRecordDetail $id;return}
 $script:DeployUI.PendingCentreEntry=@{Id=$id;Context=(CaptureNavigationContext)}
 StartJob @{Action='OperationRecordDetail';Id=$id} {param($fresh)
  $pending=$script:DeployUI.PendingCentreEntry;$script:DeployUI.PendingCentreEntry=$null
  if(-not $pending -or [string](ProfileUIField $fresh 'Id' '') -cne $pending.Id){ErrorDialog '记录已变化，请刷新后重新选择。';return}
  if(-not (TestNavigationContext $pending.Context)){return}
  OpenDeploymentCenterEntry $fresh
 } '检查这条记录的最新状态…' -Failed {param($message)$script:DeployUI.PendingCentreEntry=$null;ErrorDialog $message}
}
function OpenDeploymentCenterEntry {param($Item)
 $id=DeploymentItemId $Item;$action=[string](ProfileUIField $Item 'EntryAction' 'ViewRecord');$server=[string](ProfileUIField $Item 'ServerRecordId' '');$source=[string](ProfileUIField $Item 'SourceId' '');$line=[string](ProfileUIField $Item 'LineId' '')
 if((ProfileUIField $Item 'Discarded' $false) -or (RecordIsDeleted $Item)){ShowOperationRecordDetail $id;return}
 switch($action){
  'OpenLine'{if($line){LoadLineConnections $line;return}}
  'OpenManagement'{if($server){OpenServerRecordManagement $server -ReturnKind Context;return}}
  'BeginDeployment'{if($server -and -not $script:ReadOnly){BeginProductDeployment 'Auto' $server;return}}
  'OpenRun'{if($source -and [string](ProfileUIField $Item 'SourceKind' '') -eq 'DeploymentRun' -and -not $script:ReadOnly){ResumeProductDeployment $source;return}}
  'EditDraft'{if($source -and [string](ProfileUIField $Item 'SourceKind' '') -eq 'DeploymentRun' -and -not $script:ReadOnly){ResumeProductDeployment $source;return};if($server -and -not $script:ReadOnly){BeginProductDeployment 'Auto' $server;return}}
  'OpenLegacy'{if($source -and (ProfileUIField $Item 'CanResume' $false) -and -not $script:ReadOnly){$script:Role='linux';ShowLinux;ResumeLinux $source;return}}
 }
 ShowOperationRecordDetail $id
}
function InvokeDeploymentHistoryRecord {param($Record)
 if($Record){ShowOperationRecordDetail ([string]$Record.Id)}
}
function ShowOperationRecordDetail {param([string]$Id,[switch]$RenderOnly,$ReturnContext=$null)
 if(-not $Id){ShowUnifiedOperationHistory;return}
 if(-not $RenderOnly){
  if($PSBoundParameters.ContainsKey('ReturnContext')){$script:DeployUI.RecordReturnContext=$ReturnContext}
  elseif($script:Role -ne 'operation-record'){$script:DeployUI.RecordReturnContext=CaptureNavigationContext}
  $script:DeployUI.RecordDetail=$null;$script:DeployUI.RecordDetailError='';$script:DeployUI.RecordDetailId=$Id
 }
 $script:Page='setup';$script:Role='operation-record';SetNavigationContext 'setup' 'operation-record' $Id $script:DeployUI.RecordReturnContext
 Head '' '记录详情' '查看状态与下一步；打开详情不会继续部署。'
 $bar=New-Object Windows.Controls.WrapPanel
 AddC $bar (Btn '返回' 'RecordBack' {ReturnNavigationContext $script:DeployUI.RecordReturnContext} 'Ghost')
 AddC $bar (Margin (Btn '刷新这条记录' 'RecordRefresh' {ShowOperationRecordDetail $script:DeployUI.RecordDetailId} 'Ghost') '10,0,0,0');AddC $script:HostPanel (Margin $bar '0,0,0,14')
 $record=ProfileUIField $script:DeployUI 'RecordDetail'
 if($record){
  $card=Card;$p=Stack;$card.Child=$p;AddC $p (T ([string](ProfileUIField $record 'Name' '准备记录')) 18 $script:Ink 'SemiBold')
  AddC $p (Margin (T ([string](ProfileUIField $record 'StateLabel' '记录状态待确认')) 14 $script:Ink 'SemiBold') '0,10,0,0')
  $reason=[string](ProfileUIField $record 'Reason' '');if($reason){AddC $p (Margin (T $reason 13 $script:Text2) '0,6,0,12')}
  KeyValue $p '记录来源' (DeploymentSourceLabel ([string](ProfileUIField $record 'SourceKind' 'ServerRecord')))
  $target=[string](ProfileUIField $record 'TargetLabel' '');if($target){KeyValue $p '对应目标' $target}
  $time=ProfileUIField $record 'UpdatedAtUtc';if($time){KeyValue $p '最后更新' (ManagementTime $time)}
  $discarded=[bool](ProfileUIField $record 'Discarded' $false);$deleted=RecordIsDeleted $record
  if($deleted){AddC $p (Margin (Note '记录已从列表移除，原资料和线路保留。恢复后可查看进度。') '0,12,0,0');$b=DeploymentActions $p '恢复记录' 'RecordRestoreHistory' {RestoreOperationHistoryUI $script:DeployUI.RecordDetailId};$b.IsEnabled=(-not $script:ReadOnly)}
  elseif($discarded){AddC $p (Margin (Note '这次添加已放弃，原资料保留。恢复后请重新确认目标和准备范围。') '0,12,0,0');$b=DeploymentActions $p '恢复填写' 'RecordRestoreDraft' {RestoreDeploymentDraftUI $script:DeployUI.RecordDetailId};$b.IsEnabled=(-not $script:ReadOnly)}
  elseif([string](ProfileUIField $record 'EntryAction' 'ViewRecord') -ne 'ViewRecord'){$b=DeploymentActions $p ([string](ProfileUIField $record 'EntryLabel' '打开对应步骤')) 'RecordNext' {InvokeDeploymentCenterAction $script:DeployUI.RecordDetail};$b.IsEnabled=(-not $script:ReadOnly -or [string]$record.EntryAction -in @('OpenLine','OpenManagement'))}
  elseif([string](ProfileUIField $record 'SourceKind' '') -eq 'LegacyLinuxJob'){
   AddC $p (Margin (Note '旧记录无法直接继续。请确认目标后重新添加，原记录与操作结果保留。') '0,12,0,0')
   $b=DeploymentActions $p '重新添加线路…' 'RecordAddNew' {BeginProductDeployment 'Auto'} 'Ghost';$b.IsEnabled=(-not $script:ReadOnly)
  }
  if(-not $deleted -and -not $discarded -and (ProfileUIField $record 'CanDiscardDraft' $false)){$b=DeploymentActions $p '放弃本次添加' 'RecordDiscardDraft' {DiscardDeploymentDraftUI $script:DeployUI.RecordDetailId} 'Ghost';$b.IsEnabled=(-not $script:ReadOnly)}
  if(-not $deleted -and [string](ProfileUIField $record 'SourceKind' '') -ne 'Line'){
   $b=DeploymentActions $p '删除记录…' 'RecordDeleteHistory' {DeleteOperationRecordsUI -Ids @($script:DeployUI.RecordDetailId)} 'Ghost';$b.IsEnabled=((RecordCanDelete $record) -and -not $script:ReadOnly)
   if(-not (RecordCanDelete $record)){AddC $p (Margin (T (RecordDeleteBlockText $record) 12 $script:Text3) '0,12,0,0')}
  }
  $technical=@('记录标识：'+$Id,'阶段：'+[string](ProfileUIField $record 'Stage' ''),'结果：'+[string](ProfileUIField $record 'Status' ''),'保留原因：'+(@(ProfileUIField $record 'ProtectionReasons' @()) -join ', ')) -join [Environment]::NewLine
  $null=ManagementDetails $p $technical '技术详情';AddC $script:HostPanel $card
 }elseif(ProfileUIField $script:DeployUI 'RecordDetailError' ''){AddC $script:HostPanel (Note '这条记录暂时无法读取。请刷新重试，或返回列表查看其他记录。' 'amber')}
 else{AddC $script:HostPanel (Note '正在读取这条记录…')}
 if(-not $RenderOnly){
  $script:DeployUI.RecordLoadContext=CaptureNavigationContext
  StartJob @{Action='OperationRecordDetail';Id=$Id} {param($data)
   if((TestNavigationContext $script:DeployUI.RecordLoadContext) -and [string]$script:DeployUI.RecordDetailId -ceq [string]$data.Id){$script:DeployUI.RecordDetail=$data;ShowOperationRecordDetail $script:DeployUI.RecordDetailId -RenderOnly}
  } '读取记录详情…' -Failed {param($message)if(TestNavigationContext $script:DeployUI.RecordLoadContext){$script:DeployUI.RecordDetailError=$message;ShowOperationRecordDetail $script:DeployUI.RecordDetailId -RenderOnly}}
 }
}
function DiscardDeploymentDraftUI {param([string]$Id)
 if((IsBusy) -or $script:ReadOnly){return};$script:DeployUI.DraftReturnContext=CaptureNavigationContext
 StartJob @{Action='DraftDiscardPreview';Ids=@($Id)} {param($preview)
  if(-not (TestNavigationContext $script:DeployUI.DraftReturnContext)){return}
  if([int]$preview.EligibleCount -ne 1 -or [int]$preview.ProtectedCount -gt 0){ErrorDialog '这次添加已有进度或关联资料，请到记录详情处理。';return}
  $script:DeployUI.DraftDiscardPreview=$preview
  OpenDialog '放弃这次添加？' '将移出待办和草稿，并整理这次添加留下的空服务器登记。' '原资料、线路和服务器保留，可在操作记录的「已放弃的添加」中恢复填写。' '放弃本次添加' {
   StartJob @{Action='DraftDiscardCommit';PreviewToken=[string]$script:DeployUI.DraftDiscardPreview.PreviewToken} {param($result)
    $return=$script:DeployUI.DraftReturnContext;InvalidateDeploymentLists;Toast '已放弃，可在操作记录中恢复填写';if(TestNavigationContext $return){ReturnNavigationContext $return}
   } '整理这次添加的记录…' -Failed {param($message)$script:DeployUI.DraftDiscardPreview=$null;ErrorDialog $message}
  } '保留草稿'
 } '检查这次添加是否已执行部署…' -Failed {param($message)ErrorDialog $message}
}
function RestoreDeploymentDraftUI {param([string]$Id)
 if((IsBusy) -or $script:ReadOnly){return};$script:DeployUI.DraftReturnContext=CaptureNavigationContext
 StartJob @{Action='DraftRestore';Id=$Id} {param($result)
  InvalidateDeploymentLists;$script:DeployUI.DraftsExpanded=$true;if(TestNavigationContext $script:DeployUI.DraftReturnContext){ShowSetupCenter};Toast '已恢复填写，请确认资料后继续'
 } '恢复这次添加的资料…' -Failed {param($message)ErrorDialog $message}
}
