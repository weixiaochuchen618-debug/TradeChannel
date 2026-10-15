function WizardCard {param([string]$Title,[string]$Description='',[string]$IconName='settings')
 $card=Card '24,22';$panel=Stack;$card.Child=$panel
 SetupCardHeader $panel $Title $Description $IconName
 AddC $script:HostPanel $card;return $panel
}
# Provider setup is independent of importing a trading node. SelfTest captures
# every Worker request; no provider files are accessed from this UI process.
function OpenProviderForm {param($Candidate=$null)
 $script:ProviderForm=@{Kind='custom';Name='';Directory='';DailyPort='';TradePort=''}
 if($Candidate){foreach($key in @('Kind','Name','Directory','DailyPort','TradePort')){if($Candidate.$key){$script:ProviderForm[$key]=[string]$Candidate.$key}}}
 $script:ProviderFormOpen=$true;ShowNodes
 $script:Window.UpdateLayout();$y=$script:Controls.ProviderFormCard.TransformToAncestor($script:HostPanel).Transform((New-Object Windows.Point(0,0))).Y
 $script:Window.FindName('Scroll').ScrollToVerticalOffset($y);$script:Window.UpdateLayout();$null=$script:Controls.ProviderFieldName.Focus()
}
function ProviderField {param($Parent,[string]$Label,[string]$Key,[string]$Hint='')
 AddC $Parent (Margin (T $Label 12.5 $script:Ink 'SemiBold') '0,12,0,6')
 $box=ControlName (New-Object Windows.Controls.TextBox) ('ProviderField'+$Key);$box.Text=[string]$script:ProviderForm[$Key];$box.Tag=$Key
 $box.IsReadOnly=($script:ProviderForm.Kind -notin @('custom','manual') -and $Key -ne 'Name' -and -not $script:ProviderForm.Editing)
 $box.Add_TextChanged({$script:ProviderForm[[string]$this.Tag]=$this.Text});AddC $Parent $box
 if($Hint){AddC $Parent (Margin (T $Hint 12 $script:Text3) '0,5,0,0')}
}
function ProviderRegistrationForm {
 $manual=($script:ProviderForm.Kind -in @('custom','manual'))
 $card=ControlName (Card '22,20') 'ProviderFormCard';$card.Margin='0,4,0,12';$p=Stack;$card.Child=$p
 AddC $p (T '登记本机 SOCKS 客户端' 16 $script:Ink 'SemiBold')
 AddC $p (Margin (T '只保存名称、目录与端口。香港连接保持，新增服务商等待维护窗口更新配置。' 12.5 $script:Text2) '0,6,0,0')
 if($manual){AddC $p (Margin (Note '当前仅供日常上网；交易备用建议 Clash Verge/BatVPN。填写 SOCKS 端口不代表已具备交易备用能力。') '0,12,0,0')}
 else{AddC $p (Margin (T '目录与端口按客户端当前配置自动登记；需要修改时，请先在客户端调整后重新发现。' 12 $script:Text3) '0,8,0,0')}
 ProviderField $p '显示名称' 'Name' '例如：工作用 Clash、备用 SOCKS。'
 ProviderField $p '客户端安装目录' 'Directory' '填写包含客户端程序的本机目录，不能填写订阅链接。'
 $browse=Btn '选择目录…' 'BrowseProviderDirectory' {$folder=ChooseFolder '选择 SOCKS 客户端的安装目录';if($folder){$script:ProviderForm.Directory=$folder;$script:Controls.ProviderFieldDirectory.Text=$folder}} 'Ghost';$browse.IsEnabled=$manual;$browse.HorizontalAlignment='Left';$browse.Margin='0,6,0,0';AddC $p $browse
 ProviderField $p '日常 SOCKS / mixed 端口' 'DailyPort' '1–65535，例如 7897。'
 if(-not $manual -and $script:ProviderForm.TradePort){ProviderField $p '检测到的交易 SOCKS 端口' 'TradePort' '登记后仍需应用配置并通过独立转发检查，才能确认切换。'}
 $buttons=Stack 'Horizontal';$buttons.Margin='0,18,0,0';$save=Btn '登记服务商' 'RegisterProvider' {RegisterProvider} 'Primary';$save.IsEnabled=(-not (IsBusy));$save.Margin='0,0,8,0';AddC $buttons $save
 AddC $buttons (Btn '取消' 'CancelProviderForm' {$script:ProviderFormOpen=$false;ShowNodes} 'Ghost');AddC $p $buttons;AddC $script:HostPanel $card
}
function RegisterProvider {
 if(IsBusy){return};$f=$script:ProviderForm;$name=([string]$f.Name).Trim();$directory=([string]$f.Directory).Trim().Trim('"')
 if(-not $name -or $name.Length -gt 80){ErrorDialog '请填写 1–80 个字符的服务商名称。';return}
 if($directory -notmatch '^[A-Za-z]:[\\/]') {ErrorDialog '请填写客户端安装目录的完整本机路径，例如 C:\Tools\Clash。';return}
 $daily=0;if(-not [int]::TryParse(([string]$f.DailyPort).Trim(),[ref]$daily) -or $daily -lt 1 -or $daily -gt 65535){ErrorDialog '日常 SOCKS 端口需为 1–65535 的整数。';return}
 $request=@{Action=$(if($f.Editing){'ProviderUpdate'}else{'ProviderRegister'});Kind=[string]$f.Kind;Name=$name;Directory=$directory;DailyPort=$daily}
 if($f.Editing){$request.Id=[string]$f.Id}
 if($f.Kind -notin @('custom','manual') -and ([string]$f.TradePort).Trim()){$trade=0;if(-not [int]::TryParse(([string]$f.TradePort).Trim(),[ref]$trade) -or $trade -lt 1 -or $trade -gt 65535){ErrorDialog '检测到的交易 SOCKS 端口无效，请在客户端检查后重新发现。';return};$request.TradePort=$trade}
 StartJob $request {param($d)
  $script:ProviderFormOpen=$false;$script:ProviderNotice=[string]$d.Friendly
  ShowNodes;FetchProviders -Silent;Toast ([string]$d.Friendly)
 } '正在登记服务商；香港连接保持…'
}
function PrepareProvider {param([string]$Id)
 if(IsBusy){return};$entry=ProviderEntry $Id;if(-not $entry -or $entry.Kind -notin @('clashverge','Clash')){return}
 if(ProviderInUse $Id){OpenDialog '该服务商正在承载流量' '请先主动将交易切回自建线路、日常上网改为直连，再准备客户端。' '当前交易出口和香港连接保持，未发送准备请求。' '知道了' $null '';return}
 $script:ProviderMutationId=$Id
 OpenDialog ('准备 '+$entry.Name+'？') '将先保存可回滚备份，再为 Clash 的全局扩展配置加入域名识别与独立交易 SOCKS 入口。完成后可在同一卡片「回滚准备」。' '香港通道保持运行；不会自动启动或重新加载客户端。完成后请在维护窗口按结果提示重新载入 Clash 配置，再检查出口。此操作不会更新通道配置。' '备份并准备' {
  StartJob @{Action='ProviderPrepare';Id=$script:ProviderMutationId} {param($d)
   $script:ProviderNotice='Clash 准备已完成，备份可回滚。香港连接保持；新增服务商仍需维护窗口更新通道配置。'
   FetchProviders -Silent;ResultDialog $d 'Clash 准备结果'
  } '正在备份并准备 Clash；香港连接保持…'
 }
}
function RestoreProvider {param([string]$Id)
 if(IsBusy){return}
 if(ProviderInUse $Id){OpenDialog '该服务商正在承载流量' '请先主动将交易切回自建线路、日常上网改为直连，再恢复客户端备份。' '当前交易出口和香港连接保持，未发送回滚请求。' '知道了' $null '';return}
 $script:ProviderMutationId=$Id
 OpenDialog ('回滚 '+(ProviderName $Id)+' 的准备？') '将恢复该服务商上次准备时保存的客户端配置备份。恢复结果会说明是否需要在客户端重新载入配置。' '香港通道保持运行，不撤销服务商登记，也不会自动更新或重启通道。' '恢复备份' {
  StartJob @{Action='ProviderRestore';Id=$script:ProviderMutationId} {param($d)
   $script:ProviderNotice='已恢复 Clash 配置备份，香港连接保持。请按恢复结果检查客户端。'
   FetchProviders -Silent;ResultDialog $d 'Clash 回滚结果'
  } '正在恢复服务商备份；香港连接保持…'
 }
}
function SetupCardHeader {param($Parent,[string]$Title,[string]$Description='',[string]$IconName='settings',[int]$TileSize=40)
 $header=New-Object Windows.Controls.Grid
 foreach($width in @('Auto','*')){$column=New-Object Windows.Controls.ColumnDefinition;$column.Width=$width;$null=$header.ColumnDefinitions.Add($column)}
 $tile=IconTile -Name $IconName -Size $TileSize;$tile.VerticalAlignment='Top';$tile.Margin='0,0,14,0';AddC $header $tile
 $copy=Stack;[Windows.Controls.Grid]::SetColumn($copy,1);AddC $copy (Tx $Title 20 '#15181D' $true)
 if($Description){AddC $copy (Margin (Tx $Description 13 '#858C97') '0,6,0,0')}
 AddC $header $copy;AddC $Parent (Margin $header '0,0,0,20')
}
function SetupHint {param([string]$Text,[string]$IconName='info')
 $box=New-Object Windows.Controls.Border;$box.Background=B '#ECEEF1';$box.CornerRadius='10';$box.Padding='14'
 $grid=New-Object Windows.Controls.Grid
 foreach($width in @('Auto','*')){$column=New-Object Windows.Controls.ColumnDefinition;$column.Width=$width;$null=$grid.ColumnDefinitions.Add($column)}
 $icon=Icon -Name $IconName -Size 20 -Color '#15181D';$icon.VerticalAlignment='Top';$icon.Margin='0,2,10,0';AddC $grid $icon
 $copy=Tx $Text 13 '#4B5360';[Windows.Controls.Grid]::SetColumn($copy,1);AddC $grid $copy;$box.Child=$grid;return $box
}
function SetupTasks {param($Parent,[string[]]$Items)
 for($index=0;$index -lt $Items.Count;$index++){
  $row=New-Object Windows.Controls.Grid;$row.Margin='0,0,0,14'
  foreach($width in @('Auto','*')){$column=New-Object Windows.Controls.ColumnDefinition;$column.Width=$width;$null=$row.ColumnDefinitions.Add($column)}
  $number=New-Object Windows.Controls.Border;$number.Width=26;$number.Height=26;$number.CornerRadius='13';$number.Background=B '#F2F3F5';$number.Margin='0,0,12,0';$number.VerticalAlignment='Top'
  $label=Tx ([string]($index+1)) 13 '#15181D' $true;$label.HorizontalAlignment='Center';$label.VerticalAlignment='Center';$number.Child=$label;AddC $row $number
  $copy=Tx $Items[$index] 13 '#4B5360';[Windows.Controls.Grid]::SetColumn($copy,1);AddC $row $copy;AddC $Parent $row
 }
}
function WizardFooter {param([string]$Text,[scriptblock]$Action,[bool]$Enabled=$true)
 $bar=New-Object Windows.Controls.WrapPanel;$bar.Margin='0,24,0,0'
 $next=Btn $Text 'WizardNext' $Action 'Primary';$next.IsEnabled=$Enabled;$next.FontSize=14;$next.MinHeight=44;$next.Margin='0,0,12,8';AddC $bar $next
 $back=Btn '上一步' 'WizardBack' {if($script:Step -gt 0){$script:Step--};ShowSetup} 'Quiet';$back.FontSize=14;$back.MinHeight=44;$back.Margin='0,0,0,8';AddC $bar $back;AddC $script:HostPanel $bar
}
function BeginWizard {param([string]$Role)
 $script:Role=$Role;$script:Step=1
 if($Role -eq 'client'){StartJob @{Action='InspectClient'} {param($d)$script:Inspection=$d;if(@($d.NinjaTraderPaths).Count){$script:Wizard.Programs=@($d.NinjaTraderPaths)};if(@($d.DirectDnsIPv4).Count){$script:Wizard.Dns=[string]@($d.DirectDnsIPv4)[0]};ShowSetup} '正在检查本机环境…'}
 else{StartJob @{Action='InspectServer'} {param($d)$script:ServerInspection=$d;$route=@($d.ManagementDefaultRoutes|Where-Object {$_.DestinationPrefix -eq '0.0.0.0/0'});if($route.Count){$adapter=@($d.Adapters|Where-Object {$_.InterfaceIndex -eq $route[0].InterfaceIndex});if($adapter.Count){$script:Wizard.InterfaceAlias=[string]$adapter[0].Name}};ShowSetup} '正在检查服务器环境…'}
}
function ShowSetup {
 if($script:Role -eq 'linux' -and $script:Step -gt 0){ShowLinux;return}
 $script:Page='setup';Head '' '部署向导' '在需要配置的那台电脑上操作；每一步都会说明材料、影响和下一步。'
 if($script:Step -eq 0){
  # Scenario 1 & 2 Cards
  $card1=Card '24,20';$card1.CornerRadius='12';$p1=Stack;$card1.Child=$p1
  SetupCardHeader $p1 '全新环境部署' '新电脑 + 新买的 VPS 服务器' 'laptop' 44
  AddC $p1 (Tx '电脑与服务器都是新的。从本机通过 SSH 一键部署云端 Linux VPS，并自动完成本机客户端配置。' 13.5 '#4B5360')
  AddC $p1 (Margin (SetupHint '只需准备：服务器公网 IP 与 root 密码。' 'globe') '0,14,0,16')
  $b1=Btn '开始全新部署 (一站式推荐)' 'DeployNew' {BeginLinux} 'Primary';$b1.HorizontalAlignment='Left';$b1.MinHeight=42;$b1.FontSize=13.5;AddC $p1 $b1

  $card2=Card '24,20';$card2.CornerRadius='12';$p2=Stack;$card2.Child=$p2
  SetupCardHeader $p2 '更换或新增服务器' '电脑不变，接入新 VPS 线路' 'server' 44
  AddC $p2 (Tx '原有服务器故障或需要新增备用。新节点自动继承当前服务商与交易名单，部署后一键平滑切换。' 13.5 '#4B5360')
  AddC $p2 (Margin (SetupHint '旧线路在部署期间保持在线，不受影响。' 'shield') '0,14,0,16')
  $b2=Btn '接入新服务器' 'DeployAdd' {BeginLinux} 'Btn';$b2.HorizontalAlignment='Left';$b2.MinHeight=42;$b2.FontSize=13.5;AddC $p2 $b2
  AddC $script:HostPanel (TwoColumns $card1 $card2 '*')

  # Scenario 3 Card & Migration Card
  $card3=Card '24,20';$card3.CornerRadius='12';$p3=Stack;$card3.Child=$p3
  SetupCardHeader $p3 '原有服务器，换新电脑' '服务器正常运行，新设备连入' 'move' 44
  AddC $p3 (Tx '服务器在云端正常运行，但换了交易电脑或重装了系统。可导入旧电脑迁移包，或直接授权新设备。' 13.5 '#4B5360')
  $row3=New-Object Windows.Controls.WrapPanel;$row3.Margin='0,14,0,0'
  $b3a=Btn '导入电脑迁移包' 'OpenMigration' {ShowMigration} 'Btn';$b3a.Margin='0,0,10,0';AddC $row3 $b3a
  $b3b=Btn '授权这台新电脑' 'OpenPairing' {ShowPairing} 'Ghost';AddC $row3 $b3b
  AddC $p3 $row3

  $card4=Card '24,20';$card4.CornerRadius='12';$p4=Stack;$card4.Child=$p4
  SetupCardHeader $p4 '其他导入方式' '已有配置文件或 Windows 服务器' 'folder' 44
  AddC $p4 (Tx '支持直接导入第三方或管理员分发的 WireGuard (.conf) 配置文件，或配置 Windows Server 2022。' 13.5 '#4B5360')
  $row4=New-Object Windows.Controls.WrapPanel;$row4.Margin='0,14,0,0'
  $b4a=Btn '导入 .conf 配置' 'ManualConf' {BeginWizard 'client'} 'Ghost';$b4a.Margin='0,0,10,0';AddC $row4 $b4a
  $b4b=Btn 'Windows Server' 'SetupWinServer' {BeginWizard 'server'} 'Ghost';AddC $row4 $b4b
  AddC $p4 $row4
  AddC $script:HostPanel (TwoColumns $card3 $card4 '*')

  $links=New-Object Windows.Controls.WrapPanel;$links.Margin='0,16,0,0'
  $help=Btn '详细部署与排障指南 →' 'SetupHelp' {OpenHelp} 'Quiet';$help.FontSize=13.5;AddC $links $help
  AddC $script:HostPanel $links;return
 }
 $steps=if($script:Role -eq 'client'){@('检查环境','连接资料','应用与网络','保存完成')}else{@('检查环境','节点信息','审阅并部署','授权设备')}
 $stepper=New-Object Windows.Controls.Primitives.UniformGrid;$stepper.Columns=4;$stepper.Margin='0,0,0,24'
 for($i=0;$i -lt $steps.Count;$i++){
  $active=($script:Step -eq $i+1);$completed=($script:Step -gt $i+1)
  $cell=New-Object Windows.Controls.Grid
  foreach($width in @('*','32','*')){$column=New-Object Windows.Controls.ColumnDefinition;$column.Width=$width;$null=$cell.ColumnDefinitions.Add($column)}
  foreach($height in @('32','Auto')){$row=New-Object Windows.Controls.RowDefinition;$row.Height=$height;$null=$cell.RowDefinitions.Add($row)}
  if($i -gt 0){$line=New-Object Windows.Controls.Border;$line.Height=1;$line.VerticalAlignment='Center';$line.Background=B $(if($completed -or $active){'#9BA1AA'}else{'#E3E6EA'});AddC $cell $line}
  if($i -lt $steps.Count-1){$line=New-Object Windows.Controls.Border;$line.Height=1;$line.VerticalAlignment='Center';$line.Background=B $(if($completed){'#9BA1AA'}else{'#E3E6EA'});[Windows.Controls.Grid]::SetColumn($line,2);AddC $cell $line}
  $circle=New-Object Windows.Controls.Border;$circle.Width=32;$circle.Height=32;$circle.CornerRadius='16';$circle.BorderThickness='1'
  $circle.Background=B $(if($active){'#15181D'}elseif($completed){'#F2F3F5'}else{'#FFFFFF'});$circle.BorderBrush=B $(if($active -or $completed){'#15181D'}else{'#E3E6EA'})
  $number=Tx ([string]($i+1)) 14 $(if($active){'#FFFFFF'}elseif($completed){'#15181D'}else{'#858C97'}) $true;$number.HorizontalAlignment='Center';$number.VerticalAlignment='Center';$circle.Child=$number
  [Windows.Controls.Grid]::SetColumn($circle,1);AddC $cell $circle
  $label=Tx $steps[$i] 13 $(if($active){'#15181D'}elseif($completed){'#15181D'}else{'#858C97'}) $active;$label.TextAlignment='Center';$label.Margin='4,9,4,0'
  [Windows.Controls.Grid]::SetRow($label,1);[Windows.Controls.Grid]::SetColumnSpan($label,3);AddC $cell $label;AddC $stepper $cell
 };AddC $script:HostPanel $stepper
 if($script:Role -eq 'client'){
  switch($script:Step){
   1 {
    $p=WizardCard '先检查这台交易电脑' '这里只读取环境，不改变当前网络。' 'laptop';$i=$script:Inspection
    if($i){Row $p '系统' ([string]$i.OS);Row $p '管理员权限' $(if($i.Elevated){'已具备'}else{'需要重新以管理员启动'});Row $p '内置连接引擎' $(if($i.EngineStaged){'已就绪'}else{'文件缺失'});Row $p 'NinjaTrader' $(if(@($i.NinjaTraderPaths).Count){'已找到'}else{'未找到，可手动选择'});Row $p '现有通道' $(if($i.ExistingDeployment){'已发现'}else{'尚未配置'})}
    AddC $p (Margin (Note '没有 NinjaTrader 也能仅使用网页交易。服务商为可选项，可稍后到「线路」页独立登记。') '0,20,0,0')
    WizardFooter '继续：选择连接资料' {$script:Step=2;ShowSetup}
    if($i.ExistingDeployment){AddC $script:HostPanel (Margin (Btn '直接登记现有通道' 'WizardAdopt' {StartJob @{Action='Adopt';Name='现有自建主线'} {param($d)$script:Step=4;ShowSetup} '正在登记已有节点，不改网络…'} 'Quiet') '0,8,0,0')}
   }
   2 {
    # A configuration is bound by CompleteLinuxClient or the user's file picker.
    # Never infer a different server from the newest client.conf in the job tree.
    $p=WizardCard '添加客户端连接资料' '配置包含连接密钥，只保留在本机。' 'document'
    if($script:Wizard.Name){
        AddC $p (Margin (Pill ('✓ 已自动继承节点名称：'+$script:Wizard.Name) '#0F5132' '#D1E7DD') '0,0,0,10')
    }
    if($script:Wizard.Path -and (Test-Path -LiteralPath $script:Wizard.Path)){
        $isManaged=$script:Wizard.Path.Contains('linux-jobs')
        $tip=if($isManaged){'✓ 系统已自动检索并关联最新部署生成的客户端配置文件，无需手动寻找！'}else{'已选择客户端配置文件'}
        AddC $p (Margin (Pill $tip '#0F5132' '#D1E7DD') '0,0,0,12')
    }
    $null=Field $p '线路名称' 'Name' '例如：香港主线、美国备用。'
    $null=Field $p '客户端 .conf 或 WireGuard 导出 .zip' 'Path' '' -ReadOnly
    $button=Btn '选择其他连接文件…' 'BrowseNode' {$path=ChooseFile '选择 WireGuard 客户端配置' 'WireGuard 配置 (*.conf;*.zip)|*.conf;*.zip';if($path){$script:Wizard.Path=$path;ShowSetup}};$button.HorizontalAlignment='Left';$button.Margin='0,10,0,14';AddC $p $button
    AddC $p (Note '【旧电脑接入新服务器连接文件说明】：`n若您刚通过向导完成云端 Linux VPS 部署，系统已在后台自动合成了 client.conf 并自动填入上方，核对后直接点击下方「继续」即可；若为外部配置文件可手动点击上方按钮选择。')
    WizardFooter '继续：确认应用与网络' {if(-not $script:Wizard.Path -or -not (Test-Path -LiteralPath $script:Wizard.Path)){ErrorDialog '请先选择或确认有效的客户端 .conf 配置文件。';return};$script:Step=3;ShowSetup}
    AddC $script:HostPanel (Margin (Btn '没有配置文件？申请设备授权' 'NeedPairing' {ShowPairing} 'Quiet') '0,8,0,0')
   }
   3 {
    $p=WizardCard '确认要保护的应用' '仅交易模式会将 NinjaTrader 和交易网站送往所选出口。' 'shield'
    AddC $p (Margin (Tx 'NinjaTrader 程序路径' 14 '#15181D' $true) '0,0,0,8');$app=ControlName (New-Object Windows.Controls.TextBox) 'TradePrograms';$app.Text=(@($script:Wizard.Programs)-join ';');$app.Add_TextChanged({$script:Wizard.Programs=@($this.Text -split ';'|Where-Object {$_})});AddC $p $app
    AddC $p (Margin (Tx '只用网页可留空。不要选择整个浏览器或共享的 WebView2 程序。' 13 '#858C97') '0,8,0,12')
    $browse=Btn '选择 NinjaTrader.exe…' 'BrowseNinja' {$path=ChooseFile '选择 NinjaTrader.exe' '可执行程序 (*.exe)|*.exe';if($path){$script:Wizard.Programs=@($path);ShowSetup}} 'Quiet';$browse.HorizontalAlignment='Left';AddC $p $browse
    $null=Field $p '本地网络 DNS' 'Dns' '已从当前网络读取。通常是路由器地址；无法识别时请按本地网卡设置填写。'
    $registered=@($script:Inspection.RegisteredProviders|Where-Object {$_});$hasProviders=($registered.Count -gt 0)
    if(-not $hasProviders){$script:Wizard.UseProvider=$false}
    elseif(-not $script:Wizard.ContainsKey('UseProviderExplicitlySet')){$script:Wizard.UseProvider=$true}
    $cbText=if($hasProviders){'同时纳入全部已登记服务商（推荐）：'+(@($registered|ForEach-Object {$_.Name}) -join '、')}else{'同时纳入全部已登记服务商（暂未登记）'}
    $cb=ControlName (New-Object Windows.Controls.CheckBox) 'UseProvider';$cb.Content=$cbText;$cb.FontSize=13.5;$cb.Margin='0,20,0,0';$cb.IsChecked=[bool]$script:Wizard.UseProvider;$cb.IsEnabled=$hasProviders;$cb.Add_Click({$script:Wizard.UseProvider=[bool]$this.IsChecked;$script:Wizard.UseProviderExplicitlySet=$true});AddC $p $cb
    $hint=if($hasProviders){'已登记：'+(@($registered|ForEach-Object {$_.Name}) -join '、')+'。只生成新线路配置，当前香港连接保持；启用新配置请安排维护窗口。'}else{'尚无已登记服务商。可到「线路」页登记，或先不勾选完成香港配置；自动发现的客户端不会被自动登记。'}
    AddC $p (Margin (Note $hint) '0,12,0,0')
    $manage=Btn '前往线路页登记服务商 →' 'WizardProviders' {ShowNodes;FetchNodes} 'Ghost';$manage.HorizontalAlignment='Left';$manage.Margin='0,8,0,0';AddC $p $manage
    WizardFooter '保存并校验线路' {StartJob @{Action='ImportNode';Path=$script:Wizard.Path;Name=$script:Wizard.Name;Programs=$script:Wizard.Programs;Dns=$script:Wizard.Dns;UseProvider=[bool]$script:Wizard.UseProvider} {param($d)$script:Step=4;ShowSetup} '正在生成候选配置并校验…'}
   }
   4 {
    $p=WizardCard '线路资料已保存' '当前完成的是资料登记或静态配置检查。连接后再验证实际出口。' 'check'
    $saved=Pill '已保存 · 尚未应用新线路' '#15181D' '#F2F3F5';$saved.Child.FontSize=13;AddC $p (Margin $saved '0,0,0,20')
    AddC $p (Margin (Tx '接下来' 14 '#15181D' $true) '0,0,0,14')
    SetupTasks $p @('到线路页选择刚保存的节点。','退出整个 NinjaTrader 后，在连接页连接或应用更改。','检查出口，再确认登录、实时行情、历史 K 线与 TradingView 图表。')
    WizardFooter '前往线路' {ShowNodes;FetchNodes}
   }
  }
 }else{
  switch($script:Step){
   1 {
    $p=WizardCard '检查转发服务器' '在远程桌面中的目标服务器上执行。新建流程仅支持专用 Windows Server 2022 节点。' 'server';$i=$script:ServerInspection
    if($i){AddC $p (Tx ([string]$i.Friendly) 13 '#4B5360')}
    AddC $p (Margin (Note '已有 WireGuard / NAT 的服务器请保留原配置。此向导发现资源冲突会停止；现有节点可以继续提供客户端配置。') '0,17,0,15')
    AddC $p (Margin (Tx '安装 WireGuard 服务器组件' 14 '#4B5360' $true) '0,6,0,6')
    AddC $p (Margin (Tx '随包提供官方联网安装引导器。两种方式均需要服务器能访问 WireGuard 下载站。' 12 '#8D99AB') '0,0,0,13')
    $installOptions=New-Object Windows.Controls.WrapPanel
    $button=Btn '使用随包安装程序…' 'InstallWireGuard' {OpenDialog '使用随包安装程序' '将校验包内 WireGuard 官方安装程序并在这台服务器运行，安装引导器仍需联网下载完整组件。' '已有 WireGuard 会保留；此步骤不会启用旧隧道。交易电脑无需执行此安装。' '开始安装' {StartJob @{Action='InstallWireGuard';Source='Bundled'} {param($d)BeginWizard 'server';ResultDialog $d '服务器组件检查'} '正在校验并安装随包组件…'}};$button.Margin='0,0,10,8';AddC $installOptions $button
    $button=Btn '从官网下载并安装…' 'InstallWireGuardOnline' {OpenDialog '从官网下载并安装' '将从 WireGuard 官网下载官方安装引导器，验证签名后在这台服务器安装。' '需要联网；已有组件会保留。安装失败可以改用随包引导器或检查官网访问。' '下载并安装' {StartJob @{Action='InstallWireGuard';Source='Online'} {param($d)BeginWizard 'server';ResultDialog $d '服务器组件检查'} '正在从官网下载并校验组件…'} '返回'};$button.Margin='0,0,0,8';AddC $installOptions $button;AddC $p $installOptions
    $can=$i -and $i.OS.Supported;WizardFooter '继续：填写节点信息' {$script:Step=2;ShowSetup} $can
   }
   2 {
    $p=WizardCard '填写新节点信息' '自动识别外网网卡，计划生成时检查地址与资源冲突。' 'globe'
    $null=Field $p '线路名称' 'Name' '例如：美国主线。';$null=Field $p '服务器公网 IPv4:UDP端口' 'Endpoint' '从云平台复制公网 IPv4，端口通常为 51820。'
    $null=Field $p '外网网卡名称' 'InterfaceAlias' '使用外网上网网卡；不能选择 WireGuard 虚拟网卡。'
    $null=Field $p '隧道内网网段' 'Subnet' '保持默认即可；检测到冲突时换一个未使用的私有网段。'
    WizardFooter '生成变更计划' {StartJob @{Action='ServerPlan';Name=$script:Wizard.Name;Endpoint=$script:Wizard.Endpoint;InterfaceAlias=$script:Wizard.InterfaceAlias;Subnet=$script:Wizard.Subnet} {param($d)$script:ServerPlan=$d;$script:Wizard.PlanPath=[string]$d.PlanPath;$script:Step=3;ShowSetup} '正在生成服务器计划，尚不部署…'}
   }
   3 {
    $p=WizardCard '审阅后应用到此服务器' '本步骤会创建计划中的 WireGuard、NAT、转发与防火墙资源。' 'document';$plan=$script:ServerPlan.Plan
    Row $p '节点' ([string]$plan.Name);Row $p '公网入口' ([string]$plan.PublicEndpoint);Row $p '隧道网段' ([string]$plan.TunnelSubnet);Row $p '新增 NAT' ([string]$plan.NatName);Row $p '云端入站规则' ([string]$plan.RequiredCloudRule)
    AddC $p (Margin (Note "先在云平台为本服务器放行对应 UDP 端口，保留远程桌面规则。`n保持远程桌面，并确保可通过厂商控制台恢复访问。" 'amber') '0,13,0,10')
    AddC $p (Btn '查看完整计划摘要' 'ViewPlan' {ResultDialog $script:ServerPlan '服务器变更计划'} 'Quiet')
    WizardFooter '应用服务器计划…' {if(-not $script:Wizard.PlanPath){ErrorDialog '尚未生成计划，请返回上一步。';return};OpenDialog '应用这份服务器计划？' ('节点：'+$script:ServerPlan.Plan.Name+"`n入口："+$script:ServerPlan.Plan.PublicEndpoint+"`n将按上方计划创建服务、NAT、转发与防火墙规则。") '请先完成云安全组放行并保留管理连接。' '应用计划' {StartJob @{Action='ServerApply';Path=$script:Wizard.PlanPath} {param($d)$script:ServerApply=$d;$script:Step=4;ShowSetup} '正在应用服务器计划…'}}
   }
   4 {
    $p=WizardCard '服务器本机配置已完成' '还需要客户端完成握手与公网转发检查，才能确认整条线路可用。' 'check'
    SetupTasks $p @('在交易电脑生成公开设备申请。','将 public.request.json 复制到这台服务器。','在下方授权，将返回文件带回交易电脑。','在交易电脑合成客户端配置，导入并连接。')
    WizardFooter '添加交易设备' {ShowAuthorize}
   }
  }
 }
}
function ShowPairing {
 $script:Page='setup';Head '' '给这台电脑授权' '每台电脑独立身份。只把公开申请交给服务器，私钥安全保留在本机。'
 if(-not $script:PairDirectory){
  $pairBase=Join-Path $script:Root 'pairing'
  if(-not (Test-Path -LiteralPath $pairBase)){$null=New-Item -ItemType Directory -Path $pairBase -Force}
  $script:PairDirectory=Join-Path $pairBase ('device_'+(Get-Date -Format 'yyyyMMdd_HHmmss'))
 }
 $hasKey=Test-Path -LiteralPath (Join-Path $script:PairDirectory 'client.key')
 $hasReq=Test-Path -LiteralPath (Join-Path $script:PairDirectory 'public.request.json')

 $p=WizardCard '1. 在交易电脑生成申请' '系统默认使用内置受保护目录，无需手动选择文件夹。' 'key'
 Row $p '申请与私钥存储目录' $script:PairDirectory '#4B5360'
 if($hasReq){
  AddC $p (Margin (Pill '✓ 设备申请已生成 · public.request.json 已就绪' '#0F5132' '#D1E7DD') '0,6,0,10')
 }
 $btnRow=New-Object Windows.Controls.WrapPanel;$btnRow.Margin='0,10,0,0'
 $b=Btn '一键生成设备申请' 'DeviceRequest' {
  StartJob @{Action='DeviceRequest';Path=$script:PairDirectory} {param($d)
   $script:PairDirectory=[string]$d.RequestDirectory
   ShowPairing
   ResultDialog $d '设备申请已就绪'
  } '正在生成本机设备身份…'
 } 'Primary'
 $b.Margin='0,0,10,0';AddC $btnRow $b
 $bChange=Btn '更改保存目录…' 'ChangePairFolder' {
  $f=ChooseFolder '选择自定义保存目录（私钥与申请将保存在此）'
  if($f){$script:PairDirectory=$f;ShowPairing}
 } 'Ghost'
 AddC $btnRow $bChange;AddC $p $btnRow

 AddC $script:HostPanel (Margin (SetupHint '2. 到服务器授权：将生成的 public.request.json 发送给管理员或复制到服务器授权，取得返回文件（public.response.json）后回到此处。' 'server') '0,20,0,20')

 $p=WizardCard '3. 合成客户端配置' '系统自动关联第 1 步生成的本机私钥，只需选择服务器返回的授权文件。' 'document'
 if($hasKey){
  Row $p '本机私钥状态' '已自动匹配第 1 步私钥 (client.key)' '#0F5132'
 }else{
  Row $p '本机私钥状态' '请先完成第 1 步生成私钥' '#E65100'
 }
 $b=Btn '选择服务器返回的授权文件并合成配置…' 'CompleteClient' {
  $reqDir=if($hasKey){$script:PairDirectory}else{ChooseFolder '选择包含 client.key 的目录'}
  if(-not $reqDir){return}
  $response=ChooseFile '选择服务器返回的授权 JSON (public.response.json)' '授权文件 (*.json)|*.json'
  if(-not $response){return}
  $out=Join-Path $reqDir 'client.conf'
  StartJob @{Action='CompleteClient';RequestDirectory=$reqDir;Path=$response;Destination=$out} {param($d)
   $script:Wizard.Path=[string]$d.ConfigPath
   if($d.NodeName){$script:Wizard.Name=[string]$d.NodeName}
   $script:Role='client';$script:Step=2;ShowSetup
   ResultDialog $d '客户端配置已自动合成，线路名称已自动同步！请继续完成导入。'
  } '正在核对身份并合成客户端配置…'
 } 'Primary'
 $b.IsEnabled=$hasKey;$b.HorizontalAlignment='Left';$b.Margin='0,10,0,0';AddC $p $b

 $bar=New-Object Windows.Controls.WrapPanel;$bar.Margin='0,24,0,0'
 $b=Btn '服务器授权入口' 'ToAuthorize' {ShowAuthorize} 'Quiet';$b.FontSize=14;$b.Margin='0,0,12,8';AddC $bar $b
 $b=Btn '返回部署向导' 'PairingBack' {ShowSetup} 'Quiet';$b.FontSize=14;$b.Margin='0,0,0,8';AddC $bar $b;AddC $script:HostPanel $bar
}
function ShowAuthorize {
 $script:Page='setup';Head '' '服务器：添加交易设备' '在转发服务器上操作，仅修改本向导管理的节点。'
 $p=WizardCard '授权交易电脑' '选取公开申请，分配一个尚未使用的隧道地址。' 'shield'
 $null=Field $p '公开设备申请' 'RequestPath' '' -ReadOnly;AddC $p (Margin (Btn '选择 public.request.json…' 'BrowseRequest' {$path=ChooseFile '选择公开设备申请' 'JSON 文件 (*.json)|*.json';if($path){$script:Wizard.RequestPath=$path;ShowAuthorize}}) '0,10,0,10')
 $null=Field $p '分配给设备的 VPN 地址' 'Address' '例如网段是 10.78.0.0/24，首台设备可用 10.78.0.2；每台设备必须不同。'
 $bar=New-Object Windows.Controls.WrapPanel;$bar.Margin='0,24,0,0'
 $button=Btn '授权并生成返回文件' 'Authorize' {if(-not $script:Wizard.RequestPath){ErrorDialog '请先选择公开设备申请。';return};StartJob @{Action='ServerAuthorize';Path=$script:Wizard.RequestPath;Address=$script:Wizard.Address} {param($d)ResultDialog $d '授权已生成'} '正在添加设备并生成返回文件…'} 'Primary';$button.FontSize=14;$button.MinHeight=44;$button.Margin='0,0,12,8';AddC $bar $button
 $button=Btn '返回' 'AuthorizeBack' {ShowPairing} 'Quiet';$button.FontSize=14;$button.MinHeight=44;$button.Margin='0,0,0,8';AddC $bar $button;AddC $script:HostPanel $bar
}
function ShowMigration {
 $script:Page='setup';Head '' '迁移到新电脑' '迁移节点说明；新电脑完成独立授权后再连接。'
 $left=Card '24,22';$left.CornerRadius='12';$p=Stack;$left.Child=$p
 SetupCardHeader $p '旧电脑' '导出不含密钥的设置包，复制到新电脑。现有连接保持运行。' 'folder'
 $button=Btn '导出设置…' 'ExportSettings' {$path=ChooseFile '保存不含密钥的设置迁移包' 'JSON 文件 (*.json)|*.json' -Save -Name 'tradechannel-settings.json';if($path){StartJob @{Action='ExportSettings';Path=$path} {param($d)ResultDialog ([pscustomobject]@{Friendly='设置已导出。将文件复制到新电脑，在同一页面导入。'})} '正在导出设置…'}};$button.HorizontalAlignment='Left';$button.FontSize=14;AddC $p $button
 $right=Card '24,22';$right.CornerRadius='12';$p=Stack;$right.Child=$p
 SetupCardHeader $p '新电脑' '导入后节点显示待授权。申请新的设备身份，再合成客户端配置。' 'laptop'
 $button=Btn '导入设置…' 'ImportSettings' {$path=ChooseFile '选择设置迁移包' 'JSON 文件 (*.json)|*.json';if($path){StartJob @{Action='ImportSettings';Path=$path} {param($d)ShowPairing;ResultDialog ([pscustomobject]@{Friendly='设置已导入。请继续为这台电脑申请独立授权。'})} '正在导入设置…'}} 'Primary';$button.HorizontalAlignment='Left';$button.FontSize=14;AddC $p $button
 AddC $script:HostPanel (TwoColumns $left $right '*')
 AddC $script:HostPanel (Margin (SetupHint '设置包不含私钥，不等于完整身份备份。保留已有受限 WireGuard 导出；两台同时使用的电脑必须使用不同的客户端身份。' 'key') '0,20,0,20')
 $p=WizardCard '更换香港 / 美国服务器' '在新服务器部署并授权本机 → 在本机添加独立线路 → 连接页选择并应用。旧节点保留，验收完成后再处理。' 'server'
 $bar=New-Object Windows.Controls.WrapPanel;$bar.Margin='0,24,0,0'
 $button=Btn '申请新设备授权' 'MigrationPairing' {ShowPairing};$button.FontSize=14;$button.Margin='0,0,12,8';AddC $bar $button
 $button=Btn '返回部署向导' 'MigrationBack' {$script:Step=0;ShowSetup} 'Quiet';$button.FontSize=14;$button.Margin='0,0,0,8';AddC $bar $button;AddC $script:HostPanel $bar
}
