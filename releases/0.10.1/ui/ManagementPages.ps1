$script:TradeDomainState=$null;$script:LinuxTaskItems=@();$script:ShowArchivedTasks=$false
function EditProvider {
    param([string]$Id)
    if(IsBusy){return};$p=ProviderEntry $Id;if(-not $p){return}
    OpenProviderForm $p
    $script:ProviderForm.Id=$Id;$script:ProviderForm.Editing=$true;ShowNodes
}
function RefreshProviderPaths {
    param([string]$Id)
    if(IsBusy){return}
    StartJob @{Action='ProviderUpdate';Id=$Id;RefreshPaths=$true} {param($d)$script:ProviderNotice=$d.Friendly;FetchProviders -Silent;Toast $d.Friendly} '正在刷新该客户端路径，当前出口保持…'
}
function DeleteProvider {
    param([string]$Id)
    if(IsBusy){return};$entry=ProviderEntry $Id;if(-not $entry){return}
    if(ProviderInUse $Id){ErrorDialog '该服务商仍在承载流量。请先主动改用其他出口，再删除档案。';return}
    $script:ProviderDeleteId=$Id
    OpenDialog ('删除服务商「'+$entry.Name+'」档案？') '仅移除本产品中的服务商登记和指向它的偏好，不删除客户端、订阅或其他文件。已有节点中的旧规则需维护更新后移除。' '当前通道不重启，其他服务商档案保留。' '删除档案' {
        StartJob @{Action='ProviderRemove';Id=$script:ProviderDeleteId} {param($d)$script:ProviderNotice=$d.Friendly;FetchProviders -Silent;RefreshOverview -Silent;Toast $d.Friendly} '正在移除服务商档案…'
    } '取消' 'Danger'
}
function LoadTradeDomainManager {
    StartJob @{Action='TradeDomains'} {param($d)$script:TradeDomainState=$d;ShowTradeDomainManager} '读取交易域名名单…'
}
function ChangeTradeDomain {
    param([string]$Operation,[string]$Domain='')
    if(IsBusy){return}
    StartJob @{Action='TradeDomainEdit';Operation=$Operation;Domain=$Domain} {param($d)$script:TradeDomainState=$d;ShowTradeDomainManager;Toast $d.Message} '正在保存交易域名，当前连接保持…'
}
function ShowTradeDomainManager {
    PageHead '交易域名管理' '保存的名单用于新节点；已有线路通过维护更新应用，当前连接保持。' 'nodes'
    $card=Card '22,18';$p=Stack;$card.Child=$p
    if($script:TradeDomainState.NeedsPolicyUpdate){AddC $p (Notice 'info' '有待应用的名单' '列表已保存。新导入节点采用此列表；已有线路需在退出 NinjaTrader 后执行设置页的维护更新。')}
    foreach($domain in @($script:TradeDomainState.Domains)){
        $row=Grid @('*','Auto');$row.Margin='0,6,0,0';Cell $row (T ([string]$domain) 13.5 $script:Ink) 0
        $remove=Btn '移除' '' {ChangeTradeDomain 'Remove' ([string]$this.Tag)} 'Ghost';$remove.Tag=[string]$domain;Cell $row $remove 1;AddC $p $row
    }
    $bar=Grid @('*','Auto');$bar.Margin='0,16,0,0'
    $input=ControlName (New-Object Windows.Controls.TextBox) 'TradeDomainInput';Cell $bar $input 0
    $add=Btn '添加域名' 'AddTradeDomain' {ChangeTradeDomain 'Add' ([string]$script:Controls.TradeDomainInput.Text)} 'Btn';$add.Margin='10,0,0,0';Cell $bar $add 1;AddC $p $bar
    AddC $p (Margin (Note '填写域名或网址即可，子域名一并匹配。此名单决定网页交易流量与解析；NinjaTrader 程序保护独立保持。') '0,12,0,0')
    $buttons=Stack 'Horizontal';$buttons.Margin='0,16,0,0';AddC $buttons (Btn '恢复默认名单' 'ResetTradeDomains' {ChangeTradeDomain 'Reset'} 'Btn')
    AddC $buttons (Margin (Btn '返回线路' 'TradeDomainBack' {ShowNodes} 'Ghost') '10,0,0,0');AddC $p $buttons;AddC $script:HostPanel $card
}
function LoadLinuxTaskManager {
    StartJob @{Action='LinuxTasks'} {param($d)$script:LinuxTaskItems=@($d.Items|Where-Object {$_});ShowLinuxTaskManager} '读取任务与归档记录…'
}
function ArchiveLinuxTask {
    param([string]$Id,[bool]$Archived=$true)
    if(IsBusy){return}
    $script:PendingArchive=@{Id=$Id;Archived=$Archived}
    OpenDialog $(if($Archived){'归档这个部署任务？'}else{'恢复这个部署任务？'}) '只修改本机任务列表的显示标记。配置、私钥、授权回复和恢复记录全部保留，不修改服务器。' '正在执行的任务不能归档。' $(if($Archived){'归档任务'}else{'恢复任务'}) {
        StartJob @{Action='LinuxArchive';Id=$script:PendingArchive.Id;Archived=$script:PendingArchive.Archived} {param($d)Toast $d.Message;LoadLinuxTaskManager} '更新任务显示状态…'
    } '取消'
}
function ShowLinuxTaskManager {
    PageHead '部署任务管理' '归档旧记录以整理近期列表；归档不删除密钥、不影响服务器。' 'setup'
    $toggle=ControlName (New-Object Windows.Controls.CheckBox) 'ShowArchivedTasks';$toggle.Content='显示已归档任务';$toggle.IsChecked=$script:ShowArchivedTasks;$toggle.Margin='0,0,0,14';$toggle.Add_Click({$script:ShowArchivedTasks=[bool]$this.IsChecked;ShowLinuxTaskManager});AddC $script:HostPanel $toggle
    foreach($item in @($script:LinuxTaskItems|Where-Object {$script:ShowArchivedTasks -or -not $_.Archived})){
        $card=Card '18,14';$card.Margin='0,0,0,8';$g=Grid @('*','Auto');$text=Stack
        AddC $text (T $(if($item.Name){[string]$item.Name}else{[string]$item.Host}) 14 $script:Ink 'SemiBold')
        AddC $text (T ([string]$item.Host+' · '+$item.Operation+' · '+$item.Status+$(if($item.Archived){' · 已归档'}else{''})) 12 $script:Text3);Cell $g $text 0
        $actions=Stack 'Horizontal'
        $resume=Btn '查看 / 继续' '' {$script:Role='linux';ResumeLinux ([string]$this.Tag)} 'Btn';$resume.Tag=$item.JobId;$resume.Margin='0,0,8,0';AddC $actions $resume
        $archive=Btn $(if($item.Archived){'恢复到近期'}else{'归档'}) '' {ArchiveLinuxTask ([string]$this.Tag.Id) ([bool]$this.Tag.Archive)} 'Ghost';$archive.Tag=@{Id=$item.JobId;Archive=(-not $item.Archived)};$archive.IsEnabled=($item.Status -in @('Completed','Complete','Failed'));AddC $actions $archive
        Cell $g $actions 1;$card.Child=$g;AddC $script:HostPanel $card
    }
    $back=Btn '返回部署' 'TaskManagementBack' {ShowLinux;LinuxRecent} 'Ghost';$back.Margin='0,14,0,0';AddC $script:HostPanel $back
}
function SelectRecommendedAgents {
    if(IsBusy){return}
    ChangeAgents @{AgentIds=@(Get-TCAgentCatalog|ForEach-Object {$_.Id})} '已勾选常用 AI 工具；自定义名单保留'
}
