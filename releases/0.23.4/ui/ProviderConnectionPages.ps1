#requires -Version 5.1
$script:ProviderConnectResult=$null
function ConnectProviderUI {
    param([string]$Id='', [string]$Kind='')
    if((IsBusy) -or $script:ReadOnly){return}
    $request=@{Action='ProviderConnect';ForTrade=$false}
    if($Id){if(-not (ProviderEntry $Id)){return};$request.Id=$Id}
    elseif($Kind -cin @('batvpn','clashverge')){$request.CandidateKind=$Kind}
    else{return}
    SubmitProviderConnectionUI $request
}
function SubmitProviderConnectionUI {param([hashtable]$Request)
    StartJob $Request {param($result)
        $script:ProviderConnectResult=$result;$script:ProviderFormOpen=$false
        $script:ProviderNotice='';ShowNodes;FetchProviders -Silent;RefreshOverview -Silent
        Toast $(if($result.Applied){'代理软件已接入'}elseif($result.NeedsUpgrade){'旧线路需要更新一次配置'}elseif($result.NeedsClientAction){'请完成代理软件中的设置'}else{'接入进度已保存'})
    } '正在接入代理软件…'
}
function UseProviderForDailyUI {param([string]$Id)
    if((IsBusy) -or $script:ReadOnly -or -not (ProviderApplied (ProviderEntry $Id))){return}
    if(IsRunning){ApplyRunning @{ProviderId=$Id;Daily='Provider'} 'ApplyingDaily' '日常上网已使用所选代理软件'}
    else{SavePrefs @{ProviderId=$Id;Daily='Provider'} '已保存，连接后用于日常上网'}
}
function ProviderManagement {
    $head=Grid @('*','Auto','Auto');$head.Margin='0,0,0,16'
    Cell $head (T '接入已安装的代理软件' 14 $script:Text2) 0
    $refresh=Btn '刷新' 'DiscoverProviders' {FetchProviders} 'Ghost';$refresh.Margin='0,0,8,0';Cell $head $refresh 1
    Cell $head (Btn '手动添加…' 'AddProvider' {OpenProviderForm} 'Btn') 2;AddC $script:HostPanel $head
    if($script:ProviderReadError){AddC $script:HostPanel (Notice 'warn' '暂时无法读取' $script:ProviderReadError)}
    $result=$script:ProviderConnectResult
    if($result){
        $card=Card '20,16';$p=Stack;$card.Child=$p
        AddC $p (T $(if($result.Applied){'接入完成'}elseif($result.NeedsUpgrade){'旧线路需要更新一次'}elseif($result.NeedsClientAction){'还需要在代理软件中完成一步'}elseif($result.NeedsConnection){'连接线路后即可继续'}else{'接入暂未完成'}) 16 $script:Ink 'SemiBold')
        $message=if($result.Applied){'可以在应用页选择它的用途。'}elseif($result.NeedsUpgrade){'当前线路来自旧版本。更新一次后，后续接入代理无需重启线路。'}else{[string]$result.NextStep}
        AddC $p (Margin (Note $message) '0,8,0,0')
        if($result.NeedsUpgrade){AddC $p (Margin (Btn '更新线路配置…' 'ProviderUpgrade' {OpenUpgrade} 'Primary') '0,12,0,0')}
        elseif($result.Id -and -not $result.Applied){$retry=Btn '继续接入' 'ProviderConnectRetry' {ConnectProviderUI ([string]$this.Tag)} 'Btn';$retry.Tag=$result.Id;AddC $p (Margin $retry '0,12,0,0')}
        if($result.Code -and $result.Code -ne 'Applied'){$details=New-Object Windows.Controls.Expander;$details.Header='技术详情';$details.Content=T ([string]$result.Code) 11.5 $script:Text3;AddC $p (Margin $details '0,10,0,0')}
        AddC $script:HostPanel (Margin $card '0,0,0,14')
    }
    foreach($entry in @($script:Providers.Items|Where-Object {$_})){
        $id=[string]$entry.Id;$key=$id.Replace('-','');$ready=ProviderApplied $entry
        $card=ControlName (Card '22,18') ('ProviderCard'+$key);$p=Stack;$card.Child=$p
        $row=Grid @('*','Auto');$title=Stack;AddC $title (T ([string]$entry.Name) 16 $script:Ink 'SemiBold')
        AddC $title (Margin (T $(if($entry.MissingClient){'程序已移走，请更新路径'}elseif($ready){'已接入'}elseif($entry.NeedsUpgrade){'等待更新旧线路'}else{'等待接入'}) 12 $script:Text3) '0,4,0,0');Cell $row $title 0
        $connect=Btn $(if($ready){'重新检查'}else{'接入'}) ('ConnectProvider'+$key) {ConnectProviderUI ([string]$this.Tag)} 'Btn';$connect.Tag=$id;Cell $row $connect 1;AddC $p $row
        if($ready){
            $actions=New-Object Windows.Controls.WrapPanel;$actions.Margin='0,14,0,0'
            $daily=Btn '用于日常上网' ('UseDailyProvider'+$key) {UseProviderForDailyUI ([string]$this.Tag)} 'Btn';$daily.Tag=$id;AddC $actions $daily
            if(ProviderSupportsTrading $entry){$trade=Btn '用作交易备用…' ('UseTradeProvider'+$key) {CheckProvider ([string]$this.Tag) -ForTrade} 'Ghost';$trade.Tag=$id;AddC $actions (Margin $trade '8,0,0,0')}
            AddC $p $actions
        }
        $advanced=Stack
        AddC $advanced (T ([string]$entry.Directory) 11.5 $script:Text3)
        AddC $advanced (T ('本机端口：'+$entry.DailyPort+$(if($entry.TradePort){' · 交易备用 '+$entry.TradePort}else{''})) 11.5 $script:Text3)
        $actions=New-Object Windows.Controls.WrapPanel;$actions.Margin='0,10,0,0'
        foreach($spec in @(@{Text='编辑资料';Name='EditProvider';Callback={EditProvider ([string]$this.Tag)}},@{Text='更新程序路径';Name='RefreshProvider';Callback={RefreshProviderPaths ([string]$this.Tag)}},@{Text='移除接入';Name='DeleteProvider';Callback={DeleteProvider ([string]$this.Tag)}})){
            $b=Btn $spec.Text ($spec.Name+$key) $spec.Callback 'Ghost';$b.Tag=$id;$b.IsEnabled=(-not (ProviderInUse $id));AddC $actions $b
        }
        if($entry.Kind -in @('clashverge','Clash')){$restore=Btn '恢复代理软件原配置…' ('RestoreProvider'+$key) {RestoreProvider ([string]$this.Tag)} 'Ghost';$restore.Tag=$id;$restore.IsEnabled=(-not (ProviderInUse $id));AddC $actions $restore}
        AddC $advanced $actions;$details=New-Object Windows.Controls.Expander;$details.Header='更多';$details.Content=$advanced;AddC $p (Margin $details '0,14,0,0')
        AddC $script:HostPanel (Margin $card '0,0,0,12')
    }
    $index=0
    foreach($candidate in @($script:Providers.Candidates|Where-Object {$_})){
        if(@($script:Providers.Items|Where-Object {$_.Kind -eq $candidate.Kind -and (-not $_.Directory -or $_.Directory -eq $candidate.Directory)}).Count){continue}
        $card=Card '22,18';$row=Grid @('*','Auto');$p=Stack;AddC $p (T ([string]$candidate.Name) 16 $script:Ink 'SemiBold');AddC $p (T '已发现，点击接入会自动准备和检查。' 12 $script:Text3);Cell $row $p 0
        $connect=Btn '接入' ('ConnectCandidate'+$index) {ConnectProviderUI -Kind ([string]$this.Tag)} 'Btn';$connect.Tag=[string]$candidate.Kind;Cell $row $connect 1;$card.Child=$row;AddC $script:HostPanel (Margin $card '0,0,0,12');$index++
    }
    if($script:Providers -and -not @($script:Providers.Items).Count -and -not @($script:Providers.Candidates).Count){AddC $script:HostPanel (Note '打开 BatVPN 或 Clash Verge 并加载订阅后，点击刷新。也可以手动添加其他代理软件。')}
    if($script:ProviderFormOpen){ProviderRegistrationForm}
}
