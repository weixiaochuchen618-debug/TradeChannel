#requires -Version 5.1
$script:TradeApplicationState=$null
function LoadTradeApplicationManager {
    StartJob @{Action='TradeApplications'} {param($data)$script:TradeApplicationState=$data;ShowTradeApplicationManager} '正在读取交易软件名单…'
}
function ChangeTradeApplication {
    param([string]$Kind,[string]$Operation,[string]$Value='')
    if(IsBusy){return}
    StartJob @{Action='TradeApplicationEdit';Kind=$Kind;Operation=$Operation;Value=$Value;Revision=[int]$script:TradeApplicationState.Revision} {param($data)
        $script:TradeApplicationState=$data;ShowTradeApplicationManager;Toast $data.Message
    } '正在保存名单…'
}
function ApplyTradeApplicationList {
    if(IsBusy){return}
    $view=$script:TradeApplicationState
    $removed=@($view.AppliedPrograms|Where-Object {$_ -and @($view.Programs.Path) -inotcontains $_}|ForEach-Object {[IO.Path]::GetFileName($_)})
    $note=if($removed.Count){'移出名单的程序将可使用本地网络：'+($removed -join '、')+'。'}else{'断开时，名单中的程序仍会保留联网保护。'}
    $token=[string]$view.SnapshotToken
    OpenDialog '应用交易软件名单？' '将更新当前线路并重新连接。请先退出名单中的交易软件，完成后再打开。' $note '应用并重新连接' {
        param($context)
        StartJob @{Action='TradeApplicationApply';SnapshotToken=[string]$context.Token} {param($data)
            $script:TradeApplicationState=$data;RefreshOverview -Silent;FetchNodes;ShowTradeApplicationManager;Toast '交易软件名单已生效'
        } '正在应用交易软件名单…' 'Applying'
    } -SafeDefault -Context @{Token=$token}
}
function LoadTradeDomainManager {LoadTradeApplicationManager}
function ShowTradeDomainManager {ShowTradeApplicationManager}
function ChangeTradeDomain {param([string]$Operation,[string]$Domain='')ChangeTradeApplication 'Domain' $Operation $Domain}
function ShowTradeApplicationManager {
    PageHead '交易软件名单' '' 'nodes'
    $view=$script:TradeApplicationState
    if(-not $view){AddC $script:HostPanel (Note '正在读取名单…');return}
    if($view.NeedsPolicyUpdate){
        $notice=Card '18,16';$np=Stack;$notice.Child=$np
        AddC $np (T '有待应用的修改' 15 $script:Ink 'SemiBold');AddC $np (Margin (Note '当前连接仍使用原名单。结束交易后，应用到当前线路。') '0,5,0,12')
        AddC $np (Btn '应用到当前线路' 'ApplyTradeApplications' {ApplyTradeApplicationList} 'Primary');AddC $script:HostPanel $notice
    }
    $card=Card '22,18';$p=Stack;$card.Child=$p
    AddC $p (TitleWithHint '程序' '程序的全部连接使用交易线路；断开时阻止它直接联网。' 17)
    $index=0
    foreach($program in @($view.Programs)){
        $row=Grid @('*','Auto','Auto');$row.Margin='0,8,0,0';$text=Stack
        AddC $text (T ([string]$program.Name+$(if($program.Missing){' · 文件已移走'}elseif($program.Applied){' · 已生效'}else{' · 未生效'})) 13.5 $script:Ink)
        AddC $text (T ([string]$program.Path) 11.5 $script:Text3);Cell $row $text 0
        # 未生效的程序就地给「启用」：名单是整份写进线路的，所以它和「应用到当前线路」是同一个
        # 动作，只是放在用户正在看的那一行，不必再滚回页面顶部找按钮。
        if(-not $program.Applied -and -not $program.Missing){
            $enable=Btn '启用' ('EnableTradeProgram'+$index) {ApplyTradeApplicationList} 'Ghost'
            $enable.Margin='0,0,10,0';Cell $row $enable 1
        }
        $remove=Btn '移除' '' {ChangeTradeApplication 'Program' 'Remove' ([string]$this.Tag)} 'Ghost';$remove.Tag=[string]$program.Path;Cell $row $remove 2;AddC $p $row
        $index++
    }
    if(-not @($view.Programs).Count){AddC $p (Note '尚未添加程序；下方的网站名单仍可使用。')}
    # A dropped .exe is captured by the WebView2 host (a browser cannot read a
    # full path), so this box is the only drop target the host answers.
    $bar=Grid @('*','Auto','Auto');$bar.Margin='0,16,0,0'
    $programInput=ControlName (New-Object Windows.Controls.TextBox) 'TradeProgramInput'
    $programInput.MaxLength=1024
    [Windows.Automation.AutomationProperties]::SetName($programInput,'交易程序路径')
    $programInput=HelpTip $programInput '把程序文件（.exe）直接拖进这个框会自动填入路径；桌面快捷方式也可以拖进来，会自动换成它指向的程序。'
    Cell $bar $programInput 0
    $browse=Btn '浏览…' 'BrowseTradeProgram' {$path=ChooseFile '选择交易程序' '可执行程序 (*.exe)|*.exe|快捷方式 (*.lnk)|*.lnk';if($path){$path=ResolveTCWebShortcut $path;if($path){$script:Controls.TradeProgramInput.Text=$path}}} 'Ghost'
    $browse.Margin='10,0,0,0';Cell $bar $browse 1
    $addProgram=Btn '添加程序' 'AddTradeProgram' {
        $path=([string]$script:Controls.TradeProgramInput.Text).Trim().Trim('"').Trim()
        if(-not $path){Toast '请先把程序拖进输入框，或点「浏览…」选择';return}
        ChangeTradeApplication 'Program' 'Add' $path
    } 'Btn'
    $addProgram.Margin='10,0,0,0';Cell $bar $addProgram 2
    AddC $p $bar
    AddC $script:HostPanel $card
    $card=Card '22,18';$p=Stack;$card.Child=$p
    AddC $p (TitleWithHint '交易网站' '只调整这些网站的线路，不会限制整个浏览器。' 17)
    foreach($domain in @($view.Domains)){
        $row=Grid @('*','Auto');$row.Margin='0,6,0,0';Cell $row (T ([string]$domain) 13.5 $script:Ink) 0
        $remove=Btn '移除' '' {ChangeTradeApplication 'Domain' 'Remove' ([string]$this.Tag)} 'Ghost';$remove.Tag=[string]$domain;Cell $row $remove 1;AddC $p $row
    }
    $bar=Grid @('*','Auto');$bar.Margin='0,16,0,0'
    $input=ControlName (New-Object Windows.Controls.TextBox) 'TradeDomainInput';[Windows.Automation.AutomationProperties]::SetName($input,'网站地址');Cell $bar $input 0
    $add=Btn '添加网站' 'AddTradeDomain' {ChangeTradeApplication 'Domain' 'Add' ([string]$script:Controls.TradeDomainInput.Text)} 'Btn';$add.Margin='10,0,0,0';Cell $bar $add 1;AddC $p $bar
    $null=HelpTip $script:Controls.TradeDomainInput '填写网址或域名，子域名会一并加入。'
    AddC $p (Margin (Btn '恢复默认网站' 'ResetTradeDomains' {ChangeTradeApplication 'Domain' 'Reset'} 'Ghost') '0,12,0,0');AddC $script:HostPanel $card
    AddC $script:HostPanel (Margin (Btn '返回应用' 'TradeDomainBack' {$null=ShowTCWebShell 'apps'} 'Ghost') '0,16,0,0')
}
