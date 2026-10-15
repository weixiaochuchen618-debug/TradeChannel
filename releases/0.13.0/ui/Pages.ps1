# Pages: Overview, Lines, Settings. Shared helpers come from TradeChannel.ps1.
function TwoColumns {
 param($Left,$Right,[string]$Ratio='*')
 $grid=Grid @($Ratio,'16','*');Cell $grid $Left 0;Cell $grid $Right 2;return $grid
}
# Compatibility helpers for the deployment wizard.
function Tx {param([string]$Text,[double]$Size=13,[string]$Color='#15181D',[bool]$Strong=$false);return (T $Text $Size $Color $(if($Strong){'SemiBold'}else{'Normal'}))}
function Head {param([string]$Kicker,[string]$Title,[string]$Description);PageHead $Title $Description $script:Page}
function Note {param([string]$Text,[string]$Tone='blue')
 $c=$script:Tone[$(if($Tone -eq 'amber'){'warn'}else{'idle'})];$b=New-Object Windows.Controls.Border;$b.Background=B $c.Bg;$b.CornerRadius='10';$b.Padding='14,11'
 $g=Grid @('Auto','*');$i=Icon $(if($Tone -eq 'amber'){'alert'}else{'info'}) 16 $c.Fg;$i.Margin='0,2,10,0';$i.VerticalAlignment='Top';Cell $g $i 0;Cell $g (T $Text 12.5 $script:Text2) 1;$b.Child=$g;return $b
}
function Chip {param([string]$Text);$b=New-Object Windows.Controls.Border;$b.CornerRadius='8';$b.Background=B '#F2F3F5';$b.Padding='9,4';$b.Margin='0,0,8,8';$b.Child=T $Text 12 $script:Text2;return $b}
function StatusLine {param([string]$Tone,[string]$Text,[string]$Id='')
 $s=Stack 'Horizontal';$d=Dot $Tone 6;$d.Margin='0,0,7,0';AddC $s $d
 $c=$script:Tone[$Tone];$t=T $Text 12.5 $(if($Tone -eq 'idle'){$script:Text2}else{$c.Fg});$t.VerticalAlignment='Center';if($Id){$t=ControlName $t $Id};AddC $s $t;return $s
}
function MiniCard {param([string]$IconName,[string]$Title)
 $card=Card '20,18';$p=Stack;$card.Child=$p
 $head=Stack 'Horizontal';$i=Icon $IconName 17 $script:Ink;$i.Margin='0,0,9,0';AddC $head $i;AddC $head (T $Title 13.5 $script:Ink 'SemiBold');AddC $p (Margin $head '0,0,0,12')
 return @{Card=$card;Panel=$p}
}

# ---------- Overview ----------
function LaneRow {param([string]$IconName,[string]$Title,[string]$Subtitle,$Segmented,[string]$Tone,[string]$Status,[string]$Id,$Extra=$null)
 $row=New-Object Windows.Controls.Border;$row.Padding='22,18'
 $g=Grid @('Auto','*','Auto')
 $tile=IconTile $IconName 40 '#F2F3F5' $script:Ink;$tile.Margin='0,1,16,0';Cell $g $tile 0
 $copy=Stack;AddC $copy (T $Title 14.5 $script:Ink 'SemiBold');AddC $copy (Margin (ControlName (T $Subtitle 12.5 $script:Text3) ($Id+'Subtitle')) '0,2,0,0')
 if($Status){AddC $copy (Margin (StatusLine $Tone $Status ($Id+'Status')) '0,10,0,0')};if($Extra){AddC $copy $Extra};Cell $g $copy 1
 $Segmented.Margin='20,0,0,0';Cell $g $Segmented 2;AddResponsiveLayout $g 'Lane';$row.Child=$g;return $row
}
function LaneDivider {$div=New-Object Windows.Controls.Border;$div.Height=1;$div.Background=B '#EEF0F2';$div.Margin='22,0,22,0';return $div}
# Segment label for a line name: a trailing "(…)" qualifier is dropped; the full name stays in the tooltip and status line.
function SegName {param([string]$Name,[switch]$Full)
 $n=$Name;if(-not $Full){$short=($Name -replace '\s*[（(][^（）()]*[）)]\s*$','').Trim();if($short){$n=$short}}
 if($n.Length -gt 12){$n=$n.Substring(0,11)+'…'};return $n
}
function TradeLane {
 $o=$script:Overview;$running=IsRunning;$ready=@($script:Nodes|Where-Object {$_.manifestPath})
 $options=@(foreach($node in $ready){@{Label=(SegName ([string]$node.name));Name=[string]$node.name;Value=('node:'+[string]$node.id);Tip=((@([string]$node.name,[string]$node.endpoint)|Where-Object {$_}) -join ' · ')}})
 # Two lines must never look alike: keep full names when the short labels collide.
 if(@($options|ForEach-Object {$_.Label}|Sort-Object -Unique).Count -lt $options.Count){foreach($x in $options){$x.Label=(SegName $x.Name -Full)}}
 if(-not $options.Count){$options=@(@{Label=$(if($o -and $o.NodeName){SegName ([string]$o.NodeName)}else{'自建线路'});Value=('node:'+(ActiveNodeId));Tip=$(if($o -and $o.NodeName){[string]$o.NodeName}else{$null})})}
 $selectedProvider=ProviderEntry;$providerOk=((ProviderApplied $selectedProvider) -and (ProviderSupportsTrading $selectedProvider) -and -not $script:ProviderReadError)
 $options+=@{Label='服务商备用';Value='Provider';Enabled=$providerOk;Tip=$(if($selectedProvider -and -not (ProviderSupportsTrading $selectedProvider)){'当前仅供日常上网；交易备用建议 Clash Verge/BatVPN'}elseif($providerOk){'检查 '+(ProviderName)+' 后确认切换；当前交易服务商可与日常选择不同'}else{'先登记服务商，再在维护窗口更新配置'})}
 $selected=TradeLaneValue
 if(-not @($options|Where-Object {$_.Value -eq $selected}).Count -and $selected -ne 'Provider'){$selected=$options[0].Value}
 $tone='idle';$status='下次连接时使用'
 if($running){
  if((IsProviderTag ([string]$o.Exit))){$tone='warn';$status='经 '+(TradeLabel)+' · 自建线路恢复后建议切回'}
  else{$tone='ok';$node=@($script:Nodes|Where-Object {NodeHasActiveProfile $_})|Select-Object -First 1;$status=if($node){ActiveLineStatus $node}else{'经 '+(TradeLabel)+' 转发'};if($status -like '*最近未通过*'){$tone='warn'}}
 }
 if((StateKey) -eq 'Applying'){$tone='warn';$status='正在切换交易线路…'}
 if($script:Pending -eq 'CheckingProvider'){$tone='info';$status='正在检查备用，当前交易出口保持'}
 LaneRow 'trade' '交易' 'NinjaTrader · TradingView · Tradovate' (Segments 'Trade' $options $selected (-not (IsBusy))) $tone $status 'TradeLane'
}
function DailyLane {
 $o=$script:Overview;$running=IsRunning;$entry=ProviderEntry;$applied=ProviderApplied $entry;$ready=ProviderDailyReady $entry
 $supported=($applied -and (-not $running -or $o.DailySupported) -and -not $script:ProviderReadError)
 $tip=if(-not $applied){'当前服务商尚未应用；需在维护窗口更新配置'}elseif($running -and -not $ready){'客户端当前没有可用监听；请先启动并连接服务商'}else{'使用 '+(ProviderName)+' 的日常端口，分流规则由该客户端决定'}
 $options=@(@{Label='本地直连';Value='Direct';Tip='其他应用直接使用本地网络'},@{Label='当前服务商';Value='Provider';Enabled=($supported -and (-not $running -or $ready));Tip=$tip},@{Label='走交易线路';Value='Trade';Tip='其他应用也经当前交易出口转发（全局）'})
 $selected=DailyLaneValue;$tone='idle';$status='下次连接时使用'
 if($running){
  switch($selected){
   'Trade'{$tone='warn';$status='经 '+(TradeLabel)+' 转发 · 与交易共用服务器带宽'}
   'Direct'{$tone='idle';$status='其他应用直接使用本地网络'}
   'Provider'{
    if((IsProviderTag ([string]$o.Daily))){$tone='ok';$status='经 '+(ActiveDailyProviderName)+' · 按该客户端规则分流'}
    else{$tone='warn';$status=switch([string]$o.DailyReason){'NotListening'{(ProviderName)+' 未连接，暂时直连'}'Checking'{'正在确认服务商可以转发，暂时直连'}'ForwardingFailed'{'服务商暂时无法转发，暂时直连'}'UnknownOwner'{'代理端口被其他程序占用，已保持直连'}'ForeignTunnel'{'检测到其他虚拟网卡，已保持直连'}'RequiresUpgrade'{'所选服务商配置待更新，当前日常出口保持'}default{'服务商未就绪，当前日常出口以实际状态为准'}}}
   }
  }
 }
 if($script:Pending -eq 'ApplyingDaily'){$tone='warn';$status='正在切换…'}
 LaneRow 'globe' '日常上网' '浏览器、聊天工具等其他应用' (Segments 'Daily' $options $selected (-not (IsBusy))) $tone $status 'DailyLane'
}
# Names on the saved list, from the console's own copy once it has been read.
function AgentNames {
 if($null -eq $script:Prefs.AgentIds){return @($script:Overview.AgentNames|Where-Object {$_})}
 @(@(Get-TCAgentCatalog|Where-Object {@($script:Prefs.AgentIds) -contains $_.Id}|ForEach-Object {$_.Short})+@($script:Prefs.AgentCustom|Where-Object {$_}|ForEach-Object {if($_.Kind -eq 'Program'){[IO.Path]::GetFileName([string]$_.Value)}else{[string]$_.Value}}))
}
function AgentLane {
 $o=$script:Overview;$running=IsRunning;$supported=[bool]($o -and $o.AgentsSupported);$global=((DailyLaneValue) -eq 'Trade')
 $names=@(AgentNames)
 $subtitle=if(-not $names.Count){'名单为空，可在「线路」页添加'}elseif($names.Count -le 3){$names -join '、'}else{($names[0..2] -join '、')+' 等 '+$names.Count+' 项'}
 $lock=if(-not $supported){'升级线路配置后可用'}elseif($global){'日常上网已走交易线路，AI 助手随之走交易线路'}else{''}
 $enabled=($supported -and -not $global)
 $options=@(@{Label='跟随日常上网';Value='Daily';Enabled=$enabled;Tip=$(if($lock){$lock}else{'与其他应用一样，按「日常上网」的选择出网'})},@{Label='走交易线路';Value='Trade';Enabled=$enabled;Tip=$(if($lock){$lock}else{'名单内的助手经交易线路转发，与交易共用服务器带宽'})})
 $selected=AgentLaneValue;$tone='idle';$status='下次连接时使用'
 if(-not $supported){$status='升级线路配置后，可把所选助手单独放到交易线路'}
 elseif($running){
  if($global){$tone='warn';$status='日常上网已走交易线路，助手随之经 '+(TradeLabel)+' 转发'}
  elseif($selected -eq 'Trade'){$tone='ok';$status='经 '+(TradeLabel)+' 转发 · 其他应用不受影响'}
  else{$status='跟随日常上网：'+$(if((IsProviderTag ([string]$o.Daily))){ActiveDailyProviderName}elseif($o.DesiredDaily -eq 'Provider'){'暂时直连'}else{'本地直连'})}
 }
 if($script:Pending -eq 'ApplyingAgents'){$tone='warn';$status='正在切换…'}
 $link=Btn '管理名单 →' 'ManageAgents' {ShowNodes;FetchNodes} 'Ghost';$link.Padding='0';$link.MinHeight=0;$link.Margin='0,8,0,0';$link.FontSize=12.5
 LaneRow 'agent' 'AI 助手' $subtitle (Segments 'Agents' $options $selected (-not (IsBusy))) $tone $status 'AgentLane' $link
}
function CheckCard {
 $m=MiniCard 'pulse' '出口检查';$p=$m.Panel;$c=$script:Checks
 if($c){
  $d=$c.Data
  KeyValue $p '交易出口' $(if($d.ObservedIP){[string]$d.ObservedIP}else{'未取得'}) $(if($d.ExitHttp){$script:Ink}else{'#B42318'}) 'CheckTradeIP'
  $dailyText=switch([string]$d.DailyLane){'trade'{'与交易相同'}default{if($d.DailyIP){[string]$d.DailyIP}else{'未取得'}}}
  KeyValue $p '日常出口' $dailyText $script:Ink 'CheckDailyIP'
  if($d.PSObject.Properties['AgentLane']){KeyValue $p 'AI 助手' $(if($d.AgentLane -eq 'trade'){'与交易相同'}else{'与日常相同'}) $script:Ink 'CheckAgentLane'}
  KeyValue $p 'TradingView' $(if($d.TradingViewHttp){'可访问'}else{'访问失败'}) $(if($d.TradingViewHttp){'#15803D'}else{'#B42318'})
  KeyValue $p '响应时间' $(if($d.TradeLatencyMs){[string]$d.TradeLatencyMs+' ms'}else{'—'})
  AddC $p (Margin (T ('检查于 '+$c.At+'。行情、历史数据和订单请在交易软件中确认。') 11.5 $script:Text3) '0,6,0,12')
 }else{AddC $p (Margin (T '查看交易流量和日常流量实际从哪里出去，以及交易线路的响应时间。' 12.5 $script:Text3) '0,0,0,14')}
 $b=Btn '检查出口' 'CheckConnection' {RunCheck} 'Btn';$b.HorizontalAlignment='Left';$b.IsEnabled=((IsRunning) -and -not (IsBusy));AddC $p $b
 return $m.Card
}
function ProviderCard {
 $m=MiniCard 'globe' '服务商';$p=$m.Panel;$pv=ProviderEntry
 $text=if($script:ProviderReadError){'服务商状态读取失败'}elseif(-not $script:Providers){'正在读取服务商'}elseif(-not $pv){'尚未选择服务商'}elseif(ProviderApplied $pv){[string]$pv.Name+' · 已应用'}else{[string]$pv.Name+' · 待更新配置'}
 AddC $p (StatusLine $(if($pv -and -not (ProviderApplied $pv)){'warn'}else{'idle'}) $text 'ProviderState')
 AddC $p (Margin (T $(if($pv){ProviderHealthText $pv.Health}else{'支持自动发现 BatVPN、Clash Verge，也可手工登记其他 SOCKS 客户端。'}) 12.5 $script:Text2) '0,12,0,8')
 $b=Btn '管理服务商 →' 'ManageProviders' {ShowNodes;FetchNodes} 'Ghost';$b.HorizontalAlignment='Left';$b.Padding='0';AddC $p $b
 return $m.Card
}
function ProviderStateLabel {param($Entry)
 if(-not (ProviderApplied $Entry)){return '已登记 · 待更新'}
 if((IsRunning) -and -not (ProviderDailyReady $Entry)){return '已应用 · 端口未就绪'}
 return '已登记 · 已应用'
}
function NewChoiceBox {param([string]$Id,[double]$Width=300)
 if(-not $script:ProviderChoiceStyle){
  $script:ProviderChoiceStyle=[Windows.Markup.XamlReader]::Parse(@'
<Style xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" TargetType="ComboBox">
 <Setter Property="Background" Value="White"/><Setter Property="Foreground" Value="#15181D"/><Setter Property="BorderBrush" Value="#D6DAE0"/>
 <Setter Property="HorizontalContentAlignment" Value="Stretch"/><Setter Property="ScrollViewer.CanContentScroll" Value="True"/>
 <Setter Property="ItemContainerStyle"><Setter.Value><Style TargetType="ComboBoxItem">
  <Setter Property="Padding" Value="10,9"/><Setter Property="HorizontalContentAlignment" Value="Stretch"/>
  <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ComboBoxItem"><Border x:Name="Item" CornerRadius="6" Padding="{TemplateBinding Padding}" Background="Transparent"><ContentPresenter/></Border>
   <ControlTemplate.Triggers><Trigger Property="IsHighlighted" Value="True"><Setter TargetName="Item" Property="Background" Value="#EEF3FE"/></Trigger><Trigger Property="IsSelected" Value="True"><Setter TargetName="Item" Property="Background" Value="#F2F3F5"/></Trigger></ControlTemplate.Triggers>
  </ControlTemplate></Setter.Value></Setter>
 </Style></Setter.Value></Setter>
 <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ComboBox"><Grid>
  <ToggleButton x:Name="Toggle" Focusable="False" ClickMode="Press" IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
   <ToggleButton.Template><ControlTemplate TargetType="ToggleButton"><Border x:Name="Box" Background="White" BorderBrush="#D6DAE0" BorderThickness="1" CornerRadius="9"><Path Data="M 0 0 L 4 4 L 8 0" Stroke="#858C97" StrokeThickness="1.3" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,13,0"/></Border>
    <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Box" Property="Background" Value="#F7F8FA"/></Trigger><Trigger Property="IsChecked" Value="True"><Setter TargetName="Box" Property="BorderBrush" Value="#2B59E8"/></Trigger></ControlTemplate.Triggers>
   </ControlTemplate></ToggleButton.Template>
  </ToggleButton>
  <ContentPresenter IsHitTestVisible="False" Content="{TemplateBinding SelectionBoxItem}" ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}" Margin="12,0,32,0" VerticalAlignment="Center"/>
  <Border x:Name="FocusRing" BorderBrush="Transparent" BorderThickness="1" CornerRadius="9" IsHitTestVisible="False"/>
  <Popup x:Name="PART_Popup" Placement="Bottom" IsOpen="{TemplateBinding IsDropDownOpen}" AllowsTransparency="True" Focusable="False">
   <Border MinWidth="{TemplateBinding ActualWidth}" Background="White" BorderBrush="#D6DAE0" BorderThickness="1" CornerRadius="9" Padding="4" Margin="0,4,0,0"><ScrollViewer MaxHeight="260" CanContentScroll="True"><ItemsPresenter KeyboardNavigation.DirectionalNavigation="Contained"/></ScrollViewer></Border>
  </Popup>
 </Grid><ControlTemplate.Triggers><Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.55"/></Trigger><Trigger Property="IsKeyboardFocusWithin" Value="True"><Setter TargetName="FocusRing" Property="BorderBrush" Value="#2B59E8"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
</Style>
'@)
 }
 $box=ControlName (New-Object Windows.Controls.ComboBox) $Id;$box.Style=$script:ProviderChoiceStyle;$box.MinHeight=38;$box.Width=$Width;$box.FontSize=12.5;$box.VerticalContentAlignment='Center'
 return $box
}
function ProviderChoice {param([string]$Id='ProviderChoice')
 $box=NewChoiceBox $Id
 $directItem=New-Object Windows.Controls.ComboBoxItem;$directItem.Tag='';$directItem.Content='不使用服务商（本地直连）';$directItem.ToolTip='日常上网使用本地网络直连，不走服务商代理'
 $null=$box.Items.Add($directItem)
 if([string]::IsNullOrEmpty([string]$script:Prefs.ProviderId)){$box.SelectedItem=$directItem}
 foreach($entry in @($script:Providers.Items|Where-Object {$_ -and $_.Registered})){
  $item=New-Object Windows.Controls.ComboBoxItem;$item.Tag=[string]$entry.Id
  $state=ProviderStateLabel $entry
  $item.Content=((SegName ([string]$entry.Name) -Full)+' · '+$state);$item.ToolTip=([string]$entry.Name+' · '+$state+$(if(-not (ProviderSupportsTrading $entry)){' · 当前仅供日常上网'}else{''}))
  $null=$box.Items.Add($item);if([string]$entry.Id -eq [string]$script:Prefs.ProviderId){$box.SelectedItem=$item}
 }
 if(-not $box.Items.Count){$null=$box.Items.Add('暂无已登记服务商');$box.SelectedIndex=0}
 $box.IsEnabled=($box.Items.Count -gt 0 -and $box.Items[0] -is [Windows.Controls.ComboBoxItem] -and -not (IsBusy) -and -not $script:ProviderReadError)
 $box.Add_SelectionChanged({if($this.SelectedItem -is [Windows.Controls.ComboBoxItem]){SelectProvider ([string]$this.SelectedItem.Tag)}})
 return $box
}
function ProviderChoiceRow {
 $p=ProviderEntry;$row=New-Object Windows.Controls.Border;$row.Padding='22,14';$g=Grid @('*','Auto');$copy=Stack
 AddC $copy (T $(if($p -and -not (ProviderSupportsTrading $p)){'日常服务商'}else{'日常 / 下次备用的服务商'}) 12.5 $script:Ink 'SemiBold')
 $hint=if($script:ProviderReadError){'读取失败，请到线路页重新发现'}elseif($p -and -not (ProviderSupportsTrading $p)){'当前仅供日常上网；交易备用建议 Clash Verge/BatVPN'}elseif($p -and -not (ProviderApplied $p)){'已登记待更新 · 香港连接保持'}else{'选择不改变当前交易备用；切换交易需单独确认'}
 AddC $copy (Margin (ControlName (T $hint 12 $script:Text3) 'ProviderSelectionHint') '0,3,16,0');Cell $g $copy 0;Cell $g (ProviderChoice) 1;$row.Child=$g;return $row
}
function GuardCard {
 $m=MiniCard 'shield' '交易保护';$p=$m.Panel;$state=[string]$script:Overview.GuardState
 $tone=switch($state){'Protected'{'ok'}'Unprotected'{'warn'}default{'idle'}};$text=switch($state){'Protected'{'已开启'}'Unprotected'{'未完整启用'}default{'待确认'}}
 AddC $p (StatusLine $tone $text 'GuardState')
 AddC $p (Margin (T 'NinjaTrader 只能经通道联网。断开通道后仍保留，避免交易误走本地网络。' 12.5 $script:Text2) '0,12,0,0')
 return $m.Card
}
function ShowHome {
 PageHead '' '' 'home';$script:HomeSignature=HomeSignature
 $o=$script:Overview;$h=Hero
 if($o){
  if($o.ForeignTunnel){AddC $script:HostPanel (Notice 'bad' '检测到其他虚拟网卡' ('「'+[string]$o.ForeignTunnel+'」可能与交易线路争夺路由。请在对应客户端关闭 VPN / TUN 模式。'))}
  if(($o.UpgradeAvailable -or $script:Providers.RequiresUpgrade) -and (StateKey) -in @('Connected','Disconnected')){
   $missingMode=($o.PSObject.Properties['ControllerModes'] -and @($o.ControllerModes).Count -gt 0 -and ('rule' -notin @($o.ControllerModes) -or 'global' -notin @($o.ControllerModes)))
   $notice=if($missingMode){'当前引擎缺少交易/全局模式声明，重试按钮不会修复。需要在维护窗口更新配置并重连；当前香港连接保持。'}else{'新服务商需维护窗口更新至 v4 后使用。当前香港连接保持，登记和准备不会自动更新配置。'}
   AddC $script:HostPanel (Notice 'info' $(if($missingMode){'分流配置需要修复'}else{'服务商配置待更新'}) $notice '维护说明…' {OpenUpgrade} 'UpgradeNotice')
  }
  $recent=$false;try{$recent=($o.LastProxyKind -eq 'Unknown' -and ((Get-Date)-([DateTimeOffset]$o.LastProxyAt).LocalDateTime).TotalMinutes -lt 30)}catch{}
  if($recent){AddC $script:HostPanel (Notice 'warn' '已暂停其他程序设置的系统代理' ('系统代理曾被改为 '+[string]$o.LastProxySummary+'。通道运行期间由 TradeChannel 统一管理代理，交易连接未受影响；断开后会恢复原设置。'))}
 }
 # Hero: one status, one sentence, one action.
 $hero=Card '28,24';$g=Grid @('Auto','*','Auto')
 $dot=Dot $h.Tone 12;$dot.Margin='0,6,18,0';$dot.VerticalAlignment='Top';Cell $g $dot 0
 $copy=Stack;AddC $copy (ControlName (T $h.Title 24 $script:Ink 'SemiBold') 'StatusTitle');AddC $copy (Margin (ControlName (T $h.Detail 13.5 $script:Text2) 'StatusDetail') '0,4,24,0')
 if((StateKey) -eq 'Connected'){
  $meta=@((DurationText $o.ConnectedSince),([string]$o.Connections+' 个连接'),$(if($o.GuardState -eq 'Protected'){'NinjaTrader 保护已开启'}else{'保护状态待确认'}))|Where-Object {$_}
  AddC $copy (Margin (ControlName (T ($meta -join '  ·  ') 12 $script:Text3) 'StatusMeta') '0,10,0,0')
  $quick=Stack 'Horizontal';$quick.Margin='0,12,0,0'
  $selfName=NodeLabel (ActiveNodeId);$returnLabel=if($selfName -match '香港|Hong\s*Kong|\bHK\b'){'回香港'}else{'回到 '+(SegName $selfName -Full)}
  $hk=Btn $returnLabel 'QuickHongKong' {QuickHongKong} 'Btn';$hk.MinHeight=32;$hk.Margin='0,0,8,0';$hk.IsEnabled=((CanReturnHongKong) -and (TradeLaneValue) -eq 'Provider' -and -not (IsBusy));$hk.ToolTip=('返回当前自建线路：'+$selfName+'；不重启通道，不启用其他节点');[Windows.Controls.ToolTipService]::SetShowOnDisabled($hk,$true);AddC $quick $hk
  $only=Btn '仅交易' 'QuickTradingOnly' {QuickTradingOnly} 'Btn';$only.MinHeight=32;$only.IsEnabled=(-not (IsBusy) -and ((DailyLaneValue) -ne 'Direct'));$only.ToolTip='日常上网改为直连；当前交易出口与 AI 助手设置保持';AddC $quick $only
  AddC $quick (Margin (T 'AI 助手设置保持' 11.5 $script:Text3) '12,7,0,0');AddC $copy $quick
 }
 Cell $g $copy 1
 $primary=Btn $h.Button 'Primary' {PrimaryAction} $h.Style;$primary.MinWidth=118;$primary.MinHeight=42;$primary.VerticalAlignment='Center';$primary.IsEnabled=$h.Enabled;Cell $g $primary 2
 $hero.Child=$g;AddC $script:HostPanel $hero
 # Where traffic goes: three lanes, each with one choice.
 SectionLabel $script:HostPanel '流量走向' $(if(IsRunning){'已应用的选项即时生效；交易备用先检查、再确认'}else{'未连接时，选择会在下次连接时使用'})
 $lanes=Card '0';$stack=Stack;AddC $stack (TradeLane);AddC $stack (LaneDivider);AddC $stack (DailyLane);AddC $stack (LaneDivider);AddC $stack (AgentLane);AddC $stack (LaneDivider);AddC $stack (ProviderChoiceRow);$lanes.Child=$stack;AddC $script:HostPanel $lanes
 SectionLabel $script:HostPanel '状态'
  $cards=Grid @('*','16','*','16','*');Cell $cards (CheckCard) 0;Cell $cards (ProviderCard) 2;Cell $cards (GuardCard) 4;AddResponsiveLayout $cards 'Cards';AddC $script:HostPanel $cards
  AddRuntimeStatusCard $script:HostPanel
 $tip=Stack 'Horizontal';$tip.Margin='2,20,0,0';$i=Icon 'info' 14 $script:Text3;$i.Margin='0,2,8,0';AddC $tip $i
 AddC $tip (T '关闭方式可在设置页选择，后台连接继续。电脑重启后需要手动连接。' 12 $script:Text3);AddC $script:HostPanel $tip
}

# ---------- Lines ----------
function AgentRow {param($Entry,[bool]$Loaded)
 $g=Grid @('Auto','*');$g.Margin='0,9,0,9'
 $box=ControlName (New-Object Windows.Controls.CheckBox) ('Agent'+($Entry.Id -replace '[^A-Za-z0-9]',''));$box.Tag=[string]$Entry.Id
 $box.IsChecked=[bool]($Loaded -and @($script:Prefs.AgentIds) -contains $Entry.Id);$box.IsEnabled=($Loaded -and -not (IsBusy));$box.VerticalAlignment='Top';$box.Margin='0,1,16,0'
 $box.Add_Click({OnAgentToggle ([string]$this.Tag) ([bool]$this.IsChecked)});Cell $g $box 0
 $copy=Stack;$title=Stack 'Horizontal';AddC $title (T $Entry.Name 13.5 $script:Ink 'SemiBold')
 if($Entry.Kind -eq 'App' -and $script:AgentPresence -and $script:AgentPresence.ContainsKey([string]$Entry.Id)){
  $pill=switch($script:AgentPresence[[string]$Entry.Id]){'Running'{Pill '运行中' 'ok'}'Installed'{Pill '已安装' 'idle'}default{Pill '未检测到' 'idle'}};$pill.Margin='10,0,0,0';AddC $title $pill
 }
 AddC $copy $title
 $detail=if($Entry.Kind -eq 'Web'){(@($Entry.Domains) -join '、')+' · '+$Entry.Detail}else{$Entry.Detail}
 AddC $copy (Margin (T $detail 12 $script:Text3) '0,2,0,0');Cell $g $copy 1
 return $g
}
function CustomAgentRow {param($Item,[int]$Index)
 $g=Grid @('Auto','*','Auto');$g.Margin='0,9,0,9';$isApp=([string]$Item.Kind -eq 'Program')
 # Same width as a switch column, so custom names line up with the built-in ones.
 $mark=New-Object Windows.Controls.Border;$mark.Width=38;$mark.Margin='0,1,28,0';$mark.VerticalAlignment='Top'
 $glyph=Icon $(if($isApp){'laptop'}else{'globe'}) 16 $script:Text3;$glyph.HorizontalAlignment='Center';$mark.Child=$glyph;Cell $g $mark 0
 $copy=Stack;AddC $copy (T $(if($isApp){[IO.Path]::GetFileName([string]$Item.Value)}else{[string]$Item.Value}) 13.5 $script:Ink 'SemiBold')
 AddC $copy (Margin (T $(if($isApp){'程序 · '+[string]$Item.Value}else{'网址 · 所有程序访问它时都随名单'}) 12 $script:Text3) '0,2,0,0');Cell $g $copy 1
 $remove=Btn '移除' ('RemoveAgent'+$Index) {RemoveAgentCustom ([string]$this.Tag)} 'Ghost';$remove.Tag=([string]$Item.Kind+'|'+[string]$Item.Value);$remove.IsEnabled=(-not (IsBusy));$remove.VerticalAlignment='Center';Cell $g $remove 2
 return $g
}
function AgentListCard {
 $o=$script:Overview;$supported=[bool]($o -and $o.AgentsSupported);$loaded=($null -ne $script:Prefs.AgentIds)
 $hint=if(-not $supported){'升级线路配置后可用'}elseif((DailyLaneValue) -eq 'Trade'){'日常上网已走交易线路'}elseif((AgentLaneValue) -eq 'Trade'){'名单当前走交易线路'}else{'名单当前跟随日常上网'}
 SectionLabel $script:HostPanel 'AI 助手名单' $hint
 $recommend=Btn '勾选常用 AI 工具' 'RecommendedAgents' {SelectRecommendedAgents} 'Btn';$recommend.HorizontalAlignment='Left';$recommend.Margin='0,0,0,10';AddC $script:HostPanel $recommend
 $card=Card '22,10';$p=Stack;$card.Child=$p
 AddC $p (Margin (T '概览页「AI 助手」选「走交易线路」时，勾选的助手经交易出口，其他应用不受影响。改动立即生效，不中断交易连接。' 12.5 $script:Text2) '0,8,0,4')
 foreach($group in @(@('App','桌面程序'),@('Web','网页版'),@('Service','模型 API 与下载平台'))){
  AddC $p (Margin (T $group[1] 12 $script:Text3 'SemiBold') '0,14,0,0')
  foreach($entry in @(Get-TCAgentCatalog|Where-Object {$_.Kind -eq $group[0]})){AddC $p (AgentRow $entry $loaded)}
 }
 AddC $p (Margin (T '自定义' 12 $script:Text3 'SemiBold') '0,14,0,2')
 $index=0;foreach($item in @($script:Prefs.AgentCustom|Where-Object {$_})){AddC $p (CustomAgentRow $item $index);$index++}
 $add=Grid @('*','Auto','Auto');$add.Margin='0,8,0,0'
 $siteBox=ControlName (New-Object Windows.Controls.TextBox) 'AgentSiteInput';$siteBox.IsEnabled=($loaded -and -not (IsBusy))
 $siteBox.Add_KeyDown({param($sender,$e)if($e.Key -eq 'Return'){AddAgentCustom 'Site' ([string]$sender.Text);$e.Handled=$true}});Cell $add $siteBox 0
 $site=Btn '添加网址' 'AddAgentSite' {AddAgentCustom 'Site' ([string]$script:Controls['AgentSiteInput'].Text)} 'Btn';$site.Margin='10,0,0,0';$site.IsEnabled=$siteBox.IsEnabled;Cell $add $site 1
 $app=Btn '添加程序…' 'AddAgentProgram' {$path=ChooseFile '选择要加入名单的程序' '程序 (*.exe)|*.exe';if($path){AddAgentCustom 'Program' $path}} 'Btn';$app.Margin='10,0,0,0';$app.IsEnabled=$siteBox.IsEnabled;Cell $add $app 2
 AddC $p $add;AddC $p (Margin (T '网址填域名即可，例如 perplexity.ai，其子域名一并生效。' 11.5 $script:Text3) '0,6,0,0')
 AddC $p (Margin (Note '桌面程序按程序识别，它访问的网址都随之走；网页版只匹配浏览器（Chrome、Edge、Firefox 等）访问所列网址。走交易线路时，名单网址也经交易线路解析，避免拿到被污染的地址。') '0,14,0,12')
 AddC $script:HostPanel $card
}
function ProviderClientHint {param($Entry)
 $state=$Entry.ClientState;$needs=@()
 if($state.TunMode){$needs+='关闭 TUN / VPN'};if($state.SystemProxy){$needs+='关闭系统代理'};if($state.ProxyGuard){$needs+='关闭代理守卫'}
 if($Entry.Kind -eq 'clashverge' -and $state -and -not $state.SnifferReady){$needs+='准备域名识别'}
 if($needs.Count){return '客户端待处理：'+($needs -join '、')}
 switch([string]$Entry.Kind){'batvpn'{return '日常使用白名单；交易备用需先在客户端切到全局。'}'clashverge'{return '日常使用规则模式；准备完成后，在 Clash 中重新载入配置。'}default{return '当前仅供日常上网；交易备用建议 Clash Verge/BatVPN。'}}
}
function ProviderManagement {
 $head=Grid @('*','Auto','Auto');$head.Margin='2,8,0,12';$title=T '服务商' 14 $script:Ink 'SemiBold';$title.VerticalAlignment='Center';Cell $head $title 0
 $discover=Btn '重新发现' 'DiscoverProviders' {FetchProviders} 'Btn';$discover.IsEnabled=(-not (IsBusy));$discover.Margin='0,0,8,0';Cell $head $discover 1
 $manual=Btn '登记其他客户端…' 'AddProvider' {OpenProviderForm} 'Btn';$manual.IsEnabled=(-not (IsBusy));Cell $head $manual 2;AddC $script:HostPanel $head
 AddC $script:HostPanel (Margin (T '自动发现 BatVPN / Clash Verge；其他 SOCKS 客户端可填写目录与端口。登记不会启动客户端或更新通道。' 12.5 $script:Text3) '2,0,0,12')
 if($script:ProviderReadError){AddC $script:HostPanel (Notice 'warn' '服务商信息读取未完成' ($script:ProviderReadError+'。当前交易出口保持，可重新发现。'))}
 elseif(-not $script:Providers){AddC $script:HostPanel (Notice 'info' '正在读取服务商' '现有香港连接保持。')}
 if($script:ProviderNotice){AddC $script:HostPanel (Notice 'info' '服务商资料已保存' $script:ProviderNotice)}
 if($script:Providers.RequiresUpgrade){AddC $script:HostPanel (Notice 'info' '已登记 ≠ 已应用' '新增服务商需维护窗口更新配置至 v4。现有香港连接保持；选择待更新项只保存默认服务商。')}
 $choice=Card '20,14';$g=Grid @('*','Auto');$copy=Stack;AddC $copy (T '默认服务商' 13 $script:Ink 'SemiBold');AddC $copy (Margin (T '当前交易备用独立保持；自定义 SOCKS 仅供日常使用。' 12 $script:Text3) '0,3,14,0');Cell $g $copy 0;Cell $g (ProviderChoice 'NodesProviderChoice') 1;$choice.Child=$g;$choice.Margin='0,0,0,10';AddC $script:HostPanel $choice
 foreach($entry in @($script:Providers.Items|Where-Object {$_})){
  $key=([string]$entry.Id -replace '[^A-Za-z0-9]','');$card=ControlName (Card '20,18') ('ProviderCard'+$key);$card.Margin='0,0,0,10';$p=Stack;$card.Child=$p
  $g=Grid @('Auto','*');$tile=IconTile 'globe' 38;$tile.Margin='0,0,14,0';Cell $g $tile 0;$copy=Stack
  $title=New-Object Windows.Controls.WrapPanel;AddC $title (T ([string]$entry.Name) 15 $script:Ink 'SemiBold')
  $pill=Pill $(if(ProviderApplied $entry){ProviderStateLabel $entry}elseif($entry.Registered){'已登记 · 待更新配置'}else{'未登记'}) $(if((ProviderApplied $entry) -and (ProviderDailyReady $entry)){'ok'}else{'warn'});$pill.Margin='10,0,0,0';AddC $title $pill
  if([string]$entry.Id -eq [string]$script:Prefs.ProviderId){$selected=Pill $(if(ProviderSupportsTrading $entry){'日常 / 下次备用'}else{'日常上网'}) 'info';$selected.Margin='8,0,0,0';AddC $title $selected}
  if((IsRunning) -and (IsProviderTag ([string]$script:Overview.Exit)) -and [string]$entry.Id -eq [string]$script:Overview.TradeProviderId){$trade=Pill '当前交易备用' 'warn';$trade.Margin='8,0,0,0';AddC $title $trade}
  AddC $copy $title
  $ports='日常 SOCKS '+$(if($entry.DailyPort){[string]$entry.DailyPort}else{'待填写'})
  if(ProviderSupportsTrading $entry){$ports+='  ·  交易 SOCKS '+$(if($entry.TradePort){[string]$entry.TradePort}else{'使用日常端口'})}
  AddC $copy (Margin (T $ports 12 $script:Text3) '0,5,0,0');Cell $g $copy 1;AddC $p $g
  $report=if($script:ProviderReports.ContainsKey([string]$entry.Id)){$script:ProviderReports[[string]$entry.Id]}else{$entry.Health}
  $healthy=if($script:ProviderReports.ContainsKey([string]$entry.Id)){ProviderCheckPassed $report ([bool]$report.UiForTrade)}else{ProviderHealthOk $report}
  AddC $p (Margin (StatusLine $(if($healthy){'ok'}elseif($script:ProviderReports.ContainsKey([string]$entry.Id)){'warn'}else{'idle'}) (ProviderHealthText $report) ('ProviderHealth'+$key)) '0,12,0,0')
  AddC $p (Margin (T (ProviderClientHint $entry) 12.5 $script:Text2) '0,7,0,0')
  if($entry.MissingClient){AddC $p (Margin (Notice 'warn' '客户端档案已失效' ([string]$entry.MissingReason)) '0,10,0,0')}
  $buttons=New-Object Windows.Controls.WrapPanel;$buttons.Margin='0,12,0,0'
  $check=Btn '检查' ('CheckProvider'+$key) {CheckProvider ([string]$this.Tag)} 'Btn';$check.Tag=[string]$entry.Id;$check.IsEnabled=($entry.Registered -and -not (IsBusy));$check.Margin='0,0,8,0';AddC $buttons $check
  $select=Btn $(if([string]$entry.Id -eq [string]$script:Prefs.ProviderId){'已选择'}else{'选择服务商'}) ('SelectProvider'+$key) {SelectProvider ([string]$this.Tag)} 'Btn';$select.Tag=[string]$entry.Id;$select.IsEnabled=($entry.Registered -and [string]$entry.Id -ne [string]$script:Prefs.ProviderId -and -not (IsBusy));$select.Margin='0,0,8,0';AddC $buttons $select
  if([string]$entry.Id -eq [string]$script:Prefs.ProviderId){
   $unselect=Btn '取消选择' ('UnselectProvider'+$key) {SelectProvider ''} 'Ghost';$unselect.IsEnabled=(-not (IsBusy));$unselect.Margin='0,0,8,0';$unselect.ToolTip='清除当前服务商，日常上网改走本地直连';AddC $buttons $unselect
  }
  if($entry.Kind -in @('clashverge','Clash')){
   $prepare=Btn '自动准备' ('PrepareProvider'+$key) {PrepareProvider ([string]$this.Tag)} 'Btn';$prepare.Tag=[string]$entry.Id;$prepare.IsEnabled=($entry.Registered -and -not (IsBusy));$prepare.Margin='0,0,8,0';$prepare.ToolTip='备份后准备 Clash Verge 域名识别与交易备用端口';AddC $buttons $prepare
   $restore=Btn '恢复原配置' ('RestoreProvider'+$key) {RestoreProvider ([string]$this.Tag)} 'Ghost';$restore.Tag=[string]$entry.Id;$restore.IsEnabled=($entry.Registered -and -not (IsBusy));AddC $buttons $restore
  }
  $edit=Btn '编辑档案' ('EditProvider'+$key) {EditProvider ([string]$this.Tag)} 'Ghost';$edit.Tag=$entry.Id;$edit.IsEnabled=(-not (IsBusy) -and -not (ProviderInUse $entry.Id));AddC $buttons $edit
  $refresh=Btn '刷新程序路径' ('RefreshProvider'+$key) {RefreshProviderPaths ([string]$this.Tag)} 'Ghost';$refresh.Tag=$entry.Id;$refresh.IsEnabled=$edit.IsEnabled;AddC $buttons $refresh
  $delete=Btn '删除档案' ('DeleteProvider'+$key) {DeleteProvider ([string]$this.Tag)} 'Ghost';$delete.Tag=$entry.Id;$delete.IsEnabled=$edit.IsEnabled;AddC $buttons $delete
  AddC $p $buttons;AddC $script:HostPanel $card
 }
 $index=0
 foreach($candidate in @($script:Providers.Candidates|Where-Object {$_})){
  $registered=@($script:Providers.Items|Where-Object {$_.Registered -and $_.Kind -eq $candidate.Kind -and (-not $_.Directory -or $_.Directory -eq $candidate.Directory)}).Count -gt 0
  if($registered){$index++;continue}
  $card=Card '20,14';$card.Margin='0,0,0,10';$g=Grid @('*','Auto');$copy=Stack;AddC $copy (T ('发现 '+[string]$candidate.Name) 13.5 $script:Ink 'SemiBold')
  AddC $copy (Margin (T ([string]$candidate.Directory) 12 $script:Text3) '0,4,16,0')
  if(@($candidate.Issues|Where-Object {$_}).Count){AddC $copy (Margin (T (@($candidate.Issues) -join ' ') 12 '#A15C07') '0,4,16,0')};Cell $g $copy 0
  $register=Btn $(if($registered){'已登记'}else{'登记…'}) ('RegisterCandidate'+$index) {OpenProviderForm $this.Tag} 'Btn';$register.Tag=$candidate;$register.IsEnabled=(-not $registered -and -not (IsBusy));Cell $g $register 1;$card.Child=$g;AddC $script:HostPanel $card;$index++
 }
 if($script:Providers -and -not @($script:Providers.Items|Where-Object {$_}).Count -and -not @($script:Providers.Candidates|Where-Object {$_}).Count){AddC $script:HostPanel (Notice 'idle' '未发现本机服务商' '可安装并配置 BatVPN / Clash Verge 后重新发现，或登记其他 SOCKS 客户端。香港线路可继续独立使用。')}
 if($script:ProviderFormOpen){ProviderRegistrationForm}
}
function ShowNodes {
 PageHead '线路' '服务商、自建线路、AI 助手名单与交易名单。' 'nodes'
 $o=$script:Overview;$active=TradeLaneValue
 $head=Grid @('*','Auto');$head.Margin='2,4,0,10';$label=T '自建线路' 12 $script:Text3 'SemiBold';$label.VerticalAlignment='Bottom';Cell $head $label 0
 $add=Btn '＋ 添加线路' 'AddNode' {$script:Role='client';$script:Step=0;ShowSetup} 'Btn';Cell $head $add 1;AddC $script:HostPanel $head
 if(-not @($script:Nodes).Count){
  AddC $script:HostPanel (Notice 'info' '还没有登记线路' '已在运行的通道可以直接登记；新电脑请在部署页添加。' '登记当前通道' {StartJob @{Action='Adopt';Name='现有自建主线'} {param($d)FetchNodes;Toast '已登记当前通道'} '正在登记现有配置，不改变网络…'} 'Adopt')
 }
 foreach($node in @($script:Nodes|Sort-Object @{Expression={if(NodeHasActiveProfile $_){0}else{1}}})){
  $isActive=NodeHasActiveProfile $node
  $card=ControlName (Card '20,18') ('NodeCard'+([string]$node.id).Replace('-',''));$card.Margin='0,0,0,10';if($isActive){$card.BorderBrush=B '#C9CDD3'}
  $g=Grid @('Auto','*','Auto');$tile=IconTile 'server' 40 '#F2F3F5' $script:Ink;$tile.Margin='0,0,16,0';Cell $g $tile 0
  $p=Stack;$title=New-Object Windows.Controls.WrapPanel;AddC $title (T ([string]$node.name) 15 $script:Ink 'SemiBold')
  $recommend=LineRecommendationView $node
  $statusText=if($isActive){ActiveLineStatus $node}elseif($node.manifestPath){$recommend.Label}else{'待授权'}
  AddC $p $title
  AddC $p (Margin (ControlName (T $statusText 13 $script:Ink 'SemiBold') ('NodeStatus'+([string]$node.id).Replace('-',''))) '0,6,0,0')
  $detail=[string]$node.endpoint;if($isActive -and $o.PolicyVersion){$detail+='  ·  配置 v'+$o.PolicyVersion};AddC $p (Margin (T $detail 12.5 $script:Text3) '0,4,0,0');AddC $p (Margin (T (LineConnectionsSummary $node) 12 $script:Text3) '0,6,12,0');Cell $g $p 1
  if(-not $isActive){AddC $p (Margin (T ($recommend.Basis+'。'+$recommend.Reason) 12 $script:Text2) '0,6,12,0')}
  $nodeValue='node:'+[string]$node.id
  $nodeIdStr=[string]$node.id
  $actions=New-Object Windows.Controls.WrapPanel;$actions.VerticalAlignment='Center';$actions.MaxWidth=420
  if(-not $node.manifestPath){
   $b=Btn '完成授权' ('Node'+$nodeIdStr.Replace('-','')) {ShowPairing} 'Btn';$b.Margin='0,0,6,0';AddC $actions $b
  }elseif(-not $isActive -and $recommend.CanConnect){
   $b=Btn $recommend.Button ('Node'+$nodeIdStr.Replace('-','')) {PreviewDefaultLineConnection ([string]$this.Tag)} 'Btn';$b.Tag=$nodeIdStr;$b.Margin='0,0,6,0';AddC $actions $b
  }
  if(-not $isActive){$diag=Btn '重试检查' ('DiagNode'+$nodeIdStr.Replace('-','')) {ShowConnectionRecovery ([string]$this.Tag) ''} 'Ghost';$diag.Tag=$nodeIdStr;$diag.Margin='0,0,6,0';$diag.ToolTip='核对配置、设备身份与检查结果';AddC $actions $diag}
  $profileBtn=Btn '连接方式…' ('Profiles'+$nodeIdStr.Replace('-','')) {LoadLineConnections ([string]$this.Tag)} 'Ghost';$profileBtn.Tag=$nodeIdStr;$profileBtn.Margin='0,0,6,0';AddC $actions $profileBtn
  if(LineNeedsBackupPreparation $node){$toggleBtn=Btn '补齐备用配置（可选）' ('Proto'+$nodeIdStr.Replace('-','')) {OpenAutomaticTransport ([string]$this.Tag)} 'Ghost';$toggleBtn.Tag=$nodeIdStr;$toggleBtn.Margin='0,0,6,0';$toggleBtn.ToolTip='仅补齐这条旧线路缺少的服务器或本机配置';AddC $actions $toggleBtn}
  $ren=Btn '改名' ('RenNode'+$nodeIdStr.Replace('-','')) {OpenRenameNode ([string]$this.Tag)} 'Ghost';$ren.Tag=$nodeIdStr;$ren.Margin='0,0,6,0';$ren.ToolTip='重命名此自建线路别名';AddC $actions $ren
  $rollback=Btn '还原配置' ('RollbackNode'+$nodeIdStr.Replace('-','')) {ShowConfigurationRollback ([string]$this.Tag)} 'Ghost';$rollback.Tag=$nodeIdStr;$rollback.Margin='0,0,6,0';AddC $actions $rollback
  if(-not $isActive){
   $del=Btn '删除' ('DelNode'+$nodeIdStr.Replace('-','')) {OpenDeleteNode ([string]$this.Tag)} 'Ghost';$del.Tag=$nodeIdStr;$del.ToolTip='从本机删除此线路资料';AddC $actions $del
  }
  Cell $g $actions 2
  $card.Child=$g;AddC $script:HostPanel $card
 }
 ProviderManagement
 AgentListCard
 SectionLabel $script:HostPanel '交易名单' '这些流量始终走交易线路'
 $manage=Btn '管理交易域名…' 'ManageTradeDomains' {LoadTradeDomainManager} 'Btn';$manage.HorizontalAlignment='Left';$manage.Margin='0,0,0,8';AddC $script:HostPanel $manage
 $card=Card '20,18';$p=Stack;$card.Child=$p
 foreach($group in @(@('程序',@($o.TradePrograms)),@('网站',@($o.TradeDomains)),@('辅助解析',@($o.AuxDomains)))){
  $items=@($group[1]|Where-Object {$_});if(-not $items.Count){continue}
  $row=Grid @('96','*');$row.Margin='0,4,0,4';$label=T $group[0] 12.5 $script:Text3;$label.Margin='0,4,0,0';Cell $row $label 0
  $wrap=New-Object Windows.Controls.WrapPanel;foreach($item in $items){AddC $wrap (Chip ([string]$item))};Cell $row $wrap 1;AddC $p $row
 }
 if(-not @($o.TradeDomains).Count){AddC $p (T '连接后显示当前线路的交易名单。' 12.5 $script:Text3)}
 AddC $p (Margin (T '辅助解析：NinjaTrader 用到的功能开关与统计服务，只经交易线路解析域名。名单随线路配置生成。' 11.5 $script:Text3) '0,8,0,0')
 AddC $script:HostPanel $card
}

# ---------- Settings ----------
function SettingRow {param($Parent,[string]$Title,[string]$Description,$Control)
 $g=Grid @('*','Auto');$copy=Stack;AddC $copy (T $Title 13.5 $script:Ink 'SemiBold');if($Description){AddC $copy (Margin (T $Description 12.5 $script:Text3) '0,3,24,0')};Cell $g $copy 0
 if($Control){$Control.VerticalAlignment='Center';Cell $g $Control 1};AddC $Parent $g
}
function ShowSettings {
 PageHead '设置' '启动方式、窗口行为和维护。' 'settings'
 $card=Card '24,20';$p=Stack;$card.Child=$p
 $box=ControlName (New-Object Windows.Controls.CheckBox) 'OpenAtLogin';$box.IsChecked=[bool]$script:Prefs.OpenAtLogin
 $box.Add_Click({$enabled=[bool]$this.IsChecked;StartJob @{Action='SetStartup';Enabled=$enabled} {param($d)$script:Prefs.OpenAtLogin=[bool]$d.Enabled;ShowSettings;Toast $(if($d.Enabled){'登录后会打开控制台'}else{'已关闭登录时打开'})} '正在保存登录设置…'})
 SettingRow $p '登录 Windows 后打开控制台' '只打开界面，不会自动连接；何时连接由你决定。' $box
 AddC $p (Rule)
 SettingRow $p '电脑重启后' '先在概览页连接，再打开 NinjaTrader。重启前的连接不会自动恢复。' $null
 AddC $p (Rule)
 $shortcut=Btn '创建桌面快捷方式' 'DesktopShortcut' {StartJob @{Action='DesktopShortcut'} {param($d)Toast '桌面快捷方式已创建'} '正在创建桌面快捷方式…'} 'Btn'
 SettingRow $p '桌面入口' '为当前用户创建 TradeChannel 快捷方式。' $shortcut
 AddC $script:HostPanel $card
 SectionLabel $script:HostPanel '窗口与连接'
 if($script:WindowPrefs.Warning){AddC $script:HostPanel (Notice 'warn' '关闭偏好已使用默认值' $script:WindowPrefs.Warning)}
 $card=Card '24,16';$p=Stack;$card.Child=$p
 $choice=NewChoiceBox 'CloseBehaviorChoice' 260
 foreach($option in @(@{Value='Tray';Label='收起到托盘（推荐）'},@{Value='ExitInterface';Label='退出界面，连接保持'})){
  $item=New-Object Windows.Controls.ComboBoxItem;$item.Content=$option.Label;$item.Tag=$option.Value;$null=$choice.Items.Add($item)
  if($option.Value -eq $script:WindowPrefs.CloseBehavior){$choice.SelectedItem=$item}
 }
 $choice.Add_SelectionChanged({if(-not $script:ChangingCloseChoice -and $this.SelectedItem -and $this.SelectedItem.Tag -ne $script:WindowPrefs.CloseBehavior){SetWindowCloseBehavior ([string]$this.SelectedItem.Tag)}})
 SettingRow $p '点击关闭按钮时' '关闭方式只影响管理界面，后台通道独立运行。' $choice
 AddC $p (Margin (ControlName (T (WindowCloseDescription) 12.5 $script:Text3) 'CloseBehaviorSummary') '0,10,0,0')
 AddC $p (Rule)
 KeyValue $p '重新打开' '托盘和桌面入口会唤醒已有窗口，不会重复连接';KeyValue $p '概览「断开」' '停止通道，保留 NinjaTrader 保护'
 AddC $script:HostPanel $card
 SectionLabel $script:HostPanel '维护'
 $card=Card '24,20';$p=Stack;$card.Child=$p
 $upgrade=Btn '更新线路配置…' 'UpgradeSettings' {OpenUpgrade} 'Btn';$upgrade.IsEnabled=(-not (IsBusy) -and [bool]($script:Overview.UpgradeAvailable -or $script:Providers.RequiresUpgrade))
 SettingRow $p '维护窗口更新配置' '新服务商需要配置 v4；更新会重新连接并中断香港通道，请结束交易与 AI 助手任务后再执行。' $upgrade
 AddC $p (Rule)
 $remove=Btn '解除保护…' 'RemoveProtection' {OpenDialog '解除 NinjaTrader 保护？' '会停止通道，并移除本工具为 NinjaTrader 设置的联网限制。之后 NinjaTrader 可以直接使用本地网络。' '请先退出整个 NinjaTrader。日常断开不需要解除保护；只有准备停用本工具时才需要。' '解除保护' {StartJob @{Action='RemoveProtection'} {param($d)ResultDialog $d;RefreshOverview -Silent} '正在解除保护…'} '取消' 'Danger'} 'Danger'
 SettingRow $p '解除 NinjaTrader 保护' '准备停用本工具时使用。日常断开无需解除。' $remove
 AddC $script:HostPanel $card
 SectionLabel $script:HostPanel '维护与诊断'
 $card=Card '24,20';$p=Stack;$card.Child=$p
 $diag=Btn '导出诊断…' 'ExportDiagnostics' {
  $path=ChooseFile '保存只读诊断' 'JSON (*.json)|*.json' -Save -Name 'TradeChannel-diagnostics.json'
  if($path){StartJob @{Action='ExportDiagnostics';Path=$path} {param($d)Toast $d.Message} '正在导出诊断，不修改网络…'}
 } 'Btn'
 SettingRow $p '导出诊断报告' '保存状态与网卡、默认路由信息，不含连接私钥或订阅。' $diag
 $repair=Btn '恢复连接状态…' 'RepairState' {
  OpenDialog '维护恢复当前通道？' '将核实并停止本项目通道，保留交易保护、节点与恢复记录。之后需要你手动重新连接。无法核实归属时停止操作，不清理其他 VPN。' '请先退出整个 NinjaTrader。此操作会断开当前交易通道。' '核验并断开' {StartJob @{Action='RepairState';ClearProviders=$false} {param($d)Toast $d.Message;RefreshOverview -Silent} '正在核验本项目状态…'} '取消' 'Danger'
 } 'Btn'
 SettingRow $p '恢复连接状态' '用于上次连接或断开未完成。不禁用其他网卡，不删除部署记录。' $repair
 AddC $script:HostPanel $card
 SectionLabel $script:HostPanel '关于'
 $card=Card '24,16';$p=Stack;$card.Child=$p
  KeyValue $p '版本' ($script:Version+' 预览版');KeyValue $p '连接引擎' 'sing-box 1.14.2（内置 WireGuard）'
  KeyValue $p '程序位置' $PSScriptRoot
  KeyValue $p '线路配置' $(if($script:Overview -and $script:Overview.PolicyVersion){'v'+$script:Overview.PolicyVersion}else{'—'})
  AddC $script:HostPanel $card
  AddInstallationInformation $script:HostPanel
}
