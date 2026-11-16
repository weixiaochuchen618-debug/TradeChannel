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
    StartJob @{Action='ProviderUpdate';Id=$Id;RefreshPaths=$true} {param($d)$script:ProviderNotice=$d.Friendly;FetchProviders -Silent;Toast $d.Friendly} '正在刷新代理软件路径…'
}
function DeleteProvider {
    param([string]$Id)
    if(IsBusy){return};$entry=ProviderEntry $Id;if(-not $entry){return}
    if(ProviderInUse $Id){ErrorDialog '正在使用此代理软件，请先切换连接再删除登记。';return}
    $script:ProviderDeleteId=$Id
    OpenDialog ('删除代理软件「'+$entry.Name+'」档案？') '仅删除本程序中的登记和使用偏好。代理软件、订阅和文件保留；已有线路中的旧规则需更新配置后移除。' '当前连接和其他代理软件登记保留。' '删除档案' {
        StartJob @{Action='ProviderRemove';Id=$script:ProviderDeleteId} {param($d)$script:ProviderNotice=$d.Friendly;FetchProviders -Silent;RefreshOverview -Silent;Toast $d.Friendly} '正在移除代理软件档案…'
    } '取消' 'Danger'
}
function LoadTradeDomainManager {
    StartJob @{Action='TradeDomains'} {param($d)$script:TradeDomainState=$d;ShowTradeDomainManager} '读取交易域名名单…'
}
function ChangeTradeDomain {
    param([string]$Operation,[string]$Domain='')
    if(IsBusy){return}
    StartJob @{Action='TradeDomainEdit';Operation=$Operation;Domain=$Domain} {param($d)$script:TradeDomainState=$d;ShowTradeDomainManager;Toast $d.Message} '正在保存交易网站名单…'
}
function ShowTradeDomainManager {
    PageHead '交易网站' '保存后用于新线路；已有线路需要更新配置后生效。' 'nodes'
    $card=Card '22,18';$p=Stack;$card.Child=$p
    if($script:TradeDomainState.NeedsPolicyUpdate){AddC $p (Notice 'info' '有待应用的名单' '请先退出 NinjaTrader，再到设置页更新已有线路配置。')}
    foreach($domain in @($script:TradeDomainState.Domains)){
        $row=Grid @('*','Auto');$row.Margin='0,6,0,0';Cell $row (T ([string]$domain) 13.5 $script:Ink) 0
        $remove=Btn '移除' '' {ChangeTradeDomain 'Remove' ([string]$this.Tag)} 'Ghost';$remove.Tag=[string]$domain;Cell $row $remove 1;AddC $p $row
    }
    $bar=Grid @('*','Auto');$bar.Margin='0,16,0,0'
    $input=ControlName (New-Object Windows.Controls.TextBox) 'TradeDomainInput';Cell $bar $input 0
    $add=Btn '添加域名' 'AddTradeDomain' {ChangeTradeDomain 'Add' ([string]$script:Controls.TradeDomainInput.Text)} 'Btn';$add.Margin='10,0,0,0';Cell $bar $add 1;AddC $p $bar
    AddC $p (Margin (Note '填写域名或网址，子域名也会匹配。名单用于交易网页的连接与解析；NinjaTrader 程序保护独立生效。') '0,12,0,0')
    $buttons=Stack 'Horizontal';$buttons.Margin='0,16,0,0';AddC $buttons (Btn '恢复默认名单' 'ResetTradeDomains' {ChangeTradeDomain 'Reset'} 'Btn')
    AddC $buttons (Margin (Btn '返回应用' 'TradeDomainBack' {if(-not ((Get-Command ShowTCWebShell -ErrorAction SilentlyContinue) -and (ShowTCWebShell 'apps'))){ShowNodes}} 'Ghost') '10,0,0,0');AddC $p $buttons;AddC $script:HostPanel $card
}
function LoadLinuxTaskManager {
    StartJob @{Action='LinuxTasks'} {param($d)$script:LinuxTaskItems=@($d.Items|Where-Object {$_});ShowLinuxTaskManager} '读取任务与归档记录…'
}
function ArchiveLinuxTask {
    param([string]$Id,[bool]$Archived=$true)
    if(IsBusy){return}
    $script:PendingArchive=@{Id=$Id;Archived=$Archived}
    OpenDialog $(if($Archived){'归档这个部署任务？'}else{'恢复这个部署任务？'}) '仅调整本机列表显示，配置、密钥、授权和恢复记录保留。' '正在执行的任务不能归档；服务器不受影响。' $(if($Archived){'归档任务'}else{'恢复任务'}) {
        StartJob @{Action='LinuxArchive';Id=$script:PendingArchive.Id;Archived=$script:PendingArchive.Archived} {param($d)Toast $d.Message;LoadLinuxTaskManager} '更新任务显示状态…'
    } '取消'
}
function ShowLinuxTaskManager {
    PageHead '部署任务管理' '归档后可随时恢复显示。' 'setup'
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
    if(IsBusy -or $script:ReadOnly){return}
    # 有草稿时并入草稿，避免这条即时提交把用户还没保存的改动整份覆盖掉。
    if($script:AgentDraft){
        $script:AgentDraft.Ids=@(Get-TCAgentCatalog|ForEach-Object {$_.Id})
        $script:AgentSaveState='Dirty'
        Render;Toast '已勾选常用 AI 工具，保存后生效'
        return
    }
    ChangeAgents @{AgentIds=@(Get-TCAgentCatalog|ForEach-Object {$_.Id})} '已勾选常用 AI 工具；自定义名单保留'
}
