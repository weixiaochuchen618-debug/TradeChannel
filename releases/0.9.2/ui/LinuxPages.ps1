# Linux deployment is a separate remote job. It never calls Session, ActivateNode
# or changes any active local route. Remote credentials go to OpenSSH's console.
$script:Linux=[ordered]@{Stage=0;Host='';Port='22';User='root';IdentityFile='';Name='新的 Linux 交易节点';VpnPort='51820';Subnet='10.78.0.0/24';UseTcp=$false;TcpPort='443';ServerName='www.bing.com';JobId=$null;Operation=$null;PlanJobId=$null;PlanId=$null;Data=$null;Inspection=$null;Busy=$false;Message='';Error='';CloudConfirmed=$false;Recent=@();PollAt=[DateTime]::MinValue}

function LinuxField {param($Parent,[string]$Label,[string]$Key,[string]$Hint='')
 AddC $Parent (Margin (T $Label 12.5 $script:Ink 'SemiBold') '0,14,0,6')
 $box=ControlName (New-Object Windows.Controls.TextBox) ('Linux'+$Key);$box.Text=[string]$script:Linux[$Key];$box.Tag=$Key
 $box.IsReadOnly=[bool]$script:Linux.Busy
 $box.Add_TextChanged({$script:Linux[[string]$this.Tag]=$this.Text})
 AddC $Parent $box;if($Hint){AddC $Parent (Margin (T $Hint 12 $script:Text3) '0,4,0,0')};return $box
}
function LinuxOnPage {return ($script:Page -eq 'setup' -and $script:Role -eq 'linux')}
function BeginLinux { $script:Role='linux';ShowLinux;LinuxRecent }
function StartLinux {param([ValidateSet('Inspect','Plan','Apply','Status','Recover','Authorize','Finalize')][string]$Operation)
 if($script:Linux.Busy -or (IsBusy)){return}
 $request=@{Action='LinuxStart';Operation=$Operation}
 if($Operation -in @('Apply','Recover','Finalize')){
  if(-not $script:Linux.PlanJobId){ErrorDialog '先生成并检查服务器计划。';return}
  $request.ParentJobId=[string]$script:Linux.PlanJobId
  if($script:Linux.PlanId){$request.PlanId=[string]$script:Linux.PlanId}
 }else{
  $addr=$null;$port=0;$udp=0
  if([string]$script:Linux.Host -notmatch '^\d{1,3}(\.\d{1,3}){3}$' -or -not [Net.IPAddress]::TryParse([string]$script:Linux.Host,[ref]$addr)){ErrorDialog '请输入服务器的完整 IPv4 地址，例如云控制台显示的公网 IP。';return}
  if(-not [int]::TryParse([string]$script:Linux.Port,[ref]$port) -or $port -lt 1 -or $port -gt 65535){ErrorDialog 'SSH 端口应为 1–65535；没有改过通常是 22。';return}
  if([string]$script:Linux.User -notmatch '^[a-z_][a-z0-9_-]{0,31}$'){ErrorDialog '请填写 SSH 用户名，例如 root 或 ubuntu。';return}
  if(-not [int]::TryParse([string]$script:Linux.VpnPort,[ref]$udp) -or $udp -lt 1 -or $udp -gt 65535){ErrorDialog 'WireGuard UDP 端口应为 1–65535；推荐 51820。';return}
  $request.Connection=@{Host=[string]$script:Linux.Host;Port=$port;User=[string]$script:Linux.User;IdentityFile=[string]$script:Linux.IdentityFile}
  $request.Name=[string]$script:Linux.Name;$request.PublicEndpoint=([string]$script:Linux.Host+':'+$udp);$request.TunnelSubnet=[string]$script:Linux.Subnet
  if($Operation -eq 'Plan' -and $script:Linux.UseTcp){$request.Transport=@{Type='tcp-reality';Port=[int]$script:Linux.TcpPort;ServerName=[string]$script:Linux.ServerName}}
 }
 $script:Linux.Error='';$script:Linux.Message='正在准备登录窗口…';$script:Linux.Operation=$Operation;$script:Linux.Busy=$true
 StartJob $request {param($r)
  $script:Linux.JobId=[string]$r.JobId;$script:Linux.PollAt=[DateTime]::MinValue;$script:Linux.Message='请在打开的登录窗口输入 SSH 密码或密钥口令；本工具不保存密码。'
  if(-not $r.JobId){$script:Linux.Busy=$false;ErrorDialog '部署任务没有返回任务编号，未继续后续操作。'}
  if(LinuxOnPage){ShowLinux}
 } '正在准备远程部署任务；当前香港连接保持…' '' -Failed {param($message)$script:Linux.Busy=$false;$script:Linux.Error=$message;if(LinuxOnPage){ShowLinux}}
 if(LinuxOnPage){ShowLinux}
}
function PollLinux {
 if(-not $script:Linux.JobId -or $script:Job){return}
 $script:Linux.PollAt=Get-Date
 StartJob @{Action='LinuxPoll';Id=[string]$script:Linux.JobId} {param($r)CompleteLinuxPoll $r} '正在读取服务器任务状态…' '' -Silent -Failed {param($message)
  $script:Linux.Busy=$false;$script:Linux.Error='无法确认远程结果：'+$message+'。请检查任务状态后再重试，避免重复部署。';if(LinuxOnPage){ShowLinux}
 }
}
function CompleteLinuxPoll {param($Result)
 $script:Linux.Message=[string]$Result.Message
 if($Result.Status -in @('Pending','Running')){$script:Linux.Busy=$true;return}
 $script:Linux.Busy=$false;$script:Linux.Operation=[string]$Result.Operation
 if($Result.Status -notin @('Completed','Complete')){$script:Linux.Error=if($Result.Message){[string]$Result.Message}else{'任务未完成，请检查登录窗口及服务器实际状态。'};if(LinuxOnPage){ShowLinux};return}
 $script:Linux.Error='';$script:Linux.Data=$Result.Data
 if($Result.Connection){foreach($key in @('Host','Port','User','IdentityFile')){if($Result.Connection.PSObject.Properties[$key]){$script:Linux[$key]=[string]$Result.Connection.$key}}}
 foreach($key in @('Name','TunnelSubnet')){if($Result.PSObject.Properties[$key] -and $Result.$key){$script:Linux[$(if($key -eq 'TunnelSubnet'){'Subnet'}else{$key})]=[string]$Result.$key}}
 switch([string]$Result.Operation){
  'Inspect'{$script:Linux.Inspection=$Result.Data;$script:Linux.Stage=1}
  'Plan'{$script:Linux.PlanId=[string]$Result.Data.PlanId;$script:Linux.PlanJobId=[string]$Result.JobId;$script:Linux.Stage=2;$script:Linux.CloudConfirmed=$false}
  'Apply'{$script:Linux.Stage=3;$script:Linux.ApplyJobId=[string]$Result.JobId}
  'Authorize'{$script:Linux.Stage=3;$script:Linux.ApplyJobId=[string]$Result.JobId}
  'Finalize'{$script:Linux.Stage=3}
  'Recover'{$script:Linux.Stage=1;$script:Linux.Inspection=$null}
  'Status'{$script:Linux.Stage=4}
 }
 if(LinuxOnPage){ShowLinux}
}
function ResumeLinux {param([string]$Id)
 if($script:Linux.Busy){return};$script:Linux.JobId=$Id;$script:Linux.Busy=$true;$script:Linux.Message='正在读取已有任务…';PollLinux
}
function LinuxRecent {
 StartJob @{Action='LinuxRecent'} {param($r)$script:Linux.Recent=@($r.Items|Where-Object {$_});if(LinuxOnPage){ShowLinux}} '读取本机部署记录…' '' -Failed {param($message)$script:Linux.Error=$message;if(LinuxOnPage){ShowLinux}}
}
function ConfirmLinuxApply {
 if($script:Linux.Busy -or -not $script:Linux.CloudConfirmed){return}
 $d=$script:Linux.Data
 OpenDialog '部署到这台 Linux 服务器？' ('目标：'+[string]$d.PublicEndpoint+"`n将按已审阅计划安装 WireGuard 及可选 TCP 组件，配置设备授权、转发、防火墙和开机启动。服务器端的具体变更已列在计划中。") '本机当前交易线路保持。完成后只生成新节点资料，切换线路需要你另外操作。' '开始部署' {StartLinux 'Apply'}
}
$script:LinuxCompletion=$null
$script:CompletedLinuxNodeId=$null
function FinishLinuxImport {
 param($Imported)
 $script:CompletedLinuxNodeId=if($Imported.Id){[string]$Imported.Id}elseif($Imported.Node.Id){[string]$Imported.Node.Id}else{''}
 if(-not $script:CompletedLinuxNodeId){ErrorDialog '新线路已导入，但未收到节点 ID。请在线路页查看，不自动切换。';return}
 if($script:LinuxCompletion.Transport){
  StartJob @{Action='SetTransportMode';Id=$script:CompletedLinuxNodeId;Mode='Tcp';TransportParams=$script:LinuxCompletion.Transport} {param($d)ShowLinuxImportComplete} '正在保存该服务器的 TCP 传输参数…'
 }else{ShowLinuxImportComplete}
}
function ShowLinuxImportComplete {
 $script:Role='client';$script:Step=0;ShowNodes;FetchNodes
 OpenDialog ('新线路「'+[string]$script:LinuxCompletion.NodeName+'」已加入本机') '配置与设备授权已导入。实际出口、行情及重启恢复仍需分别检查。可以现在切换，也可以保留当前线路。' '切换前请先退出整个 NinjaTrader；切换会中断经过交易线路的连接。' '立即切换到新线路' {
  if($script:CompletedLinuxNodeId){OnTrade ('node:'+$script:CompletedLinuxNodeId)}else{ShowNodes}
 } '留在当前线路'
}
function CompleteLinuxClient {
 if($script:Linux.Busy -or -not $script:Linux.JobId){return}
 $script:LinuxCompletion=@{JobId=[string]$script:Linux.JobId;ConfigPath='';NodeName=[string]$script:Linux.Name;Transport=$null;Inspection=$null;Programs=@();Dns=''}
 StartJob @{Action='LinuxComplete';Id=$script:LinuxCompletion.JobId} {param($r)
  $script:LinuxCompletion.ConfigPath=[string]$r.ConfigPath
  if($r.NodeName){$script:LinuxCompletion.NodeName=[string]$r.NodeName}
  if($r.PSObject.Properties['Transport'] -and $r.Transport){$parameters=@{};foreach($field in $r.Transport.PSObject.Properties){$parameters[$field.Name]=$field.Value};$script:LinuxCompletion.Transport=$parameters}
  StartJob @{Action='InspectClient'} {param($i)
   $script:LinuxCompletion.Inspection=$i;$script:LinuxCompletion.Programs=@($i.NinjaTraderPaths)
   $script:LinuxCompletion.Dns=if(@($i.DirectDnsIPv4).Count){[string]$i.DirectDnsIPv4[0]}else{''}
   $providers=@($i.RegisteredProviders|Where-Object {$_})
   StartJob @{Action='ImportNode';Path=$script:LinuxCompletion.ConfigPath;Name=$script:LinuxCompletion.NodeName;Programs=$script:LinuxCompletion.Programs;Dns=$script:LinuxCompletion.Dns;UseProvider=($providers.Count -gt 0)} {param($imported)FinishLinuxImport $imported} '正在注册新线路…' -Failed {param($msg)
    $script:Wizard.Path=$script:LinuxCompletion.ConfigPath;$script:Wizard.Name=$script:LinuxCompletion.NodeName;$script:Role='client';$script:Step=2
    $script:Inspection=$script:LinuxCompletion.Inspection;$script:Wizard.Programs=$script:LinuxCompletion.Programs;$script:Wizard.Dns=$script:LinuxCompletion.Dns;ShowSetup
    ErrorDialog ('自动导入未完成：'+$msg+'。连接文件已保留并填入导入向导。')
   }
  } '正在检查本机应用与 DNS…'
 } '正在核对授权并合成配置…' '' -Failed {param($message)$script:Linux.Error=$message;ShowLinux}
}

function LinuxTasks {param($Parent,$Items)
 foreach($item in @($Items)){
  $messages=@{
   UnsupportedOS='需要 Ubuntu 24.04 或 Debian 13 的 x86_64 系统镜像。';UnsupportedHost='需要具有 systemd 的完整虚拟机；当前不支持受限容器。'
   RouteDrift='服务器默认路由已改变，请重新检查并生成计划。';PolicyRouting='检测到额外的策略路由，当前向导不自动接管。'
   ForeignNetworkManager='发现 Docker、虚拟化或其他网络管理服务，请使用专用新服务器。';ForeignFirewallService='已有防火墙服务运行，向导不会自动覆盖；请先核查服务器用途。'
   ForeignFirewall='发现已有防火墙规则，当前自动部署不覆盖这些规则。';ForeignWireGuard='发现已有 WireGuard 配置，请保留原配置并核查。'
   ForeignInterface='发现已有隧道、网桥或同名网卡，需要先处理冲突。';ExistingForwarding='服务器已有 IPv4 转发，可能承载其他业务，向导不接管。'
   SubnetConflict='隧道网段与已有地址或路由重叠，请更换隧道网段。';PortConflict='UDP 端口已被占用，请选择空闲端口后重新生成计划。'
   HostMismatch='部署计划属于另一台服务器，请重新生成。';PackagePolicyConflict='已有软件包启动策略，无法安全自动安装依赖。'
   NeedsRecovery='有未完成的部署事务，请先检查并恢复，再重新部署。'
  }
  $text=if($item -is [string]){$item}elseif($item.Code -and $messages.ContainsKey([string]$item.Code)){$messages[[string]$item.Code]}elseif($item.Message){[string]$item.Message}elseif($item.Summary){[string]$item.Summary}elseif($item.Description){[string]$item.Description}else{[string]$item}
  if($text){AddC $Parent (Margin (T ('• '+$text) 13 $script:Text2) '0,4,0,4')}
 }
}
function ShowLinux {
 $script:Role='linux';$script:Page='setup';Head '' '部署 Linux 服务器' '在本机完成准备与部署；当前交易通道继续运行。'
 $labels=@('服务器资料','检查环境','审阅并部署','导入新节点');$steps=New-Object Windows.Controls.Primitives.UniformGrid;$steps.Columns=4;$steps.Margin='0,0,0,18'
 for($n=0;$n -lt $labels.Count;$n++){$text=T (([string]($n+1))+'  '+$labels[$n]) 13 $(if($script:Linux.Stage -eq $n){$script:Ink}else{$script:Text3}) $(if($script:Linux.Stage -eq $n){'SemiBold'}else{'Normal'});AddC $steps $text};AddC $script:HostPanel $steps
 if($script:Linux.Error){
  AddC $script:HostPanel (Margin (Notice 'warn' '任务需要处理' ([string]$script:Linux.Error)) '0,0,0,14')
  if($script:Linux.Error -match '找不到路径|RequestMissing|RequestMismatch|ClientCompletionFailed|未绑定原始本机设备申请'){
   $recMsg='检测到本机私钥或计划文件缺失。由于云端 VPS 已经成功部署，您无需重新部署服务器，只需为当前这台电脑生成新的独立授权即可自动并入自建线路。'
   AddC $script:HostPanel (Margin (Notice 'info' '一键自愈修复推荐' $recMsg) '0,0,0,12')
   $bDirectAuth=Btn '立即重新为本机生成授权并导入线路' 'DirectAuthorize' {StartLinux 'Authorize'} 'Primary'
   $bDirectAuth.HorizontalAlignment='Left';$bDirectAuth.Margin='0,0,0,14';AddC $script:HostPanel $bDirectAuth
  }
  if($script:Linux.Error -match 'HOST IDENTIFICATION HAS CHANGED|Host key verification failed|指纹|known_hosts'){
   $resetBtn=Btn '一键重置此服务器的本地指纹' 'ResetFingerprint' {
    StartJob @{Action='ResetHostKey';Host=[string]$script:Linux.Host;Port=[int]$script:Linux.Port} {param($d)
     Toast '旧指纹已移除；重新连接时请核对新的 SHA256 指纹'
     $script:Linux.Error=''
     StartLinux 'Inspect'
    } '正在重置本地指纹…'
   } 'Btn';$resetBtn.Margin='0,0,0,12';AddC $script:HostPanel $resetBtn
  }
 }
 if($script:Linux.Busy){
  AddC $script:HostPanel (Notice 'info' '等待登录或服务器操作完成' $script:Linux.Message)
  $p=WizardCard '登录窗口中的操作' '看到 password: 再输入完整密码并回车。没有字符、星号或光标移动是正常现象。' 'key'
  SetupTasks $p @('第一次连接：将窗口里的 SHA256 主机指纹与云控制台提供的指纹核对，一致后输入 yes。','如果提示无法校验主机或指纹已变更，停止登录并核实目标，不要忽略警告。','root 用户可直接部署；其他用户需要免密码 sudo。若条件不满足，向导会说明下一步。','保持登录窗口打开，完成后结果会自动回到这里。关闭窗口可能中止任务，应先检查服务器状态再重试。')
 }else{
  switch([int]$script:Linux.Stage){
   0 {
    $left=Card '22,20';$p=Stack;$left.Child=$p;SetupCardHeader $p '连接资料' '来自云厂商控制台，不填写 VPN 服务商订阅。' 'server'
    $null=LinuxField $p '服务器公网 IPv4' 'Host' '例如 203.0.113.10；填写你实际购买的 VPS 地址。'
    $null=LinuxField $p 'SSH 端口' 'Port' '默认 22；只有厂商另有说明才修改。'
    $null=LinuxField $p 'SSH 用户名' 'User' '默认 root；ubuntu 等其他用户需具备免密码 sudo。'
    $right=Card '22,20';$p=Stack;$right.Child=$p;SetupCardHeader $p '节点设置' '默认值适合首个 Linux 节点，检查会拒绝地址冲突。' 'settings'
    $null=LinuxField $p '线路名称' 'Name' '例如「香港 Linux 主线」或「美国备用」。'
    $null=LinuxField $p 'WireGuard UDP 端口' 'VpnPort' '默认 51820，与 SSH 端口作用不同。'
    $null=LinuxField $p '隧道网段' 'Subnet' '仅供隧道内部使用，不能与本地或服务器已有网段重叠。'
    AddC $script:HostPanel (TwoColumns $left $right '*')
    $p=WizardCard '登录方式' '密码不在 TradeChannel 中保存。使用密码时，下面的密钥路径留空即可。' 'key'
    $box=LinuxField $p 'SSH 私钥文件（可选）' 'IdentityFile' '这是服务器 SSH 登录密钥，不是 WireGuard 私钥；带口令的密钥会在登录窗口询问口令。'
    $cb=ControlName (New-Object Windows.Controls.CheckBox) 'LinuxUseTcp';$cb.Content='使用 TCP 传输（当服务器 UDP 受限时）';$cb.IsChecked=[bool]$script:Linux.UseTcp;$cb.Margin='0,14,0,0';$cb.Add_Click({$script:Linux.UseTcp=[bool]$this.IsChecked;ShowLinux});AddC $p $cb
    if($script:Linux.UseTcp){$null=LinuxField $p 'TCP 服务端口' 'TcpPort' '将安装本工具独立的 VLESS/Reality 服务，不覆盖已占用端口。';$null=LinuxField $p 'Reality 伪装域名' 'ServerName' '使用支持 TLS 1.3 的公网 HTTPS 域名；服务器需能访问此域名的 443 端口。'}
    $b=Btn '选择 SSH 密钥…' 'LinuxChooseKey' {$path=ChooseFile '选择 SSH 登录密钥' '所有文件 (*.*)|*.*';if($path){$script:Linux.IdentityFile=$path;ShowLinux}} 'Btn';$b.HorizontalAlignment='Left';$b.Margin='0,10,0,0';AddC $p $b
    AddC $script:HostPanel (Margin (Note '预览版适配目标：Ubuntu Server 24.04 / Debian 13，无桌面的专用 VPS。Linux 端需要 python3 和可用的软件源；不重装系统、不接管已有复杂防火墙。') '0,14,0,0')
    $bar=New-Object Windows.Controls.WrapPanel;$bar.Margin='0,20,0,0';AddC $bar (Btn '连接并检查（不部署）' 'LinuxInspect' {StartLinux 'Inspect'} 'Primary');AddC $bar (Margin (Btn '查看近期任务' 'LinuxRecent' {LinuxRecent} 'Ghost') '12,0,0,0');AddC $script:HostPanel $bar
    $b=Btn '服务器已部署？为本机新增授权…' 'LinuxAuthorizeExisting' {OpenDialog '为这台电脑添加设备授权？' ('服务器：'+[string]$script:Linux.Host+'。要求它已经由本工具部署；工具将在本机生成独立设备身份，只把公钥发送到服务器。') '不会重建服务器或切换当前本机通道。现有设备授权保留。' '登录并授权本机' {StartLinux 'Authorize'}} 'Ghost';$b.HorizontalAlignment='Left';$b.Margin='0,12,0,0';AddC $script:HostPanel $b
   }
   1 {
    $i=$script:Linux.Inspection
    $isDeployed=([bool]$i.Supported -and [bool]$i.AlreadyDeployed)
    $cardSub=if($isDeployed){'检测到此服务器已部署运行中，可直接为本机授权并接入。'}else{'只检查新服务器，尚未安装或启用新的通道。'}
    $p=WizardCard '环境检查结果' $cardSub 'check'
    Row $p '服务器' ([string]$script:Linux.Host)
    Row $p '服务器状态' $(if($isDeployed){'已部署运行中 (Applied)'}elseif($i.Supported){'环境支持，可继续准备计划'}else{'需要处理下方问题后重新检查'}) $(if($isDeployed){'#0F5132'}else{$script:Ink})
    if($i.OS){Row $p '系统' (([string]$i.OS.Id)+' '+([string]$i.OS.Version)+' '+([string]$i.OS.Architecture))}
    LinuxTasks $p $i.Issues;LinuxTasks $p $i.Warnings
    if($isDeployed){
     if($i.ExistingNodeName -and -not $script:Linux.Name){$script:Linux.Name=$i.ExistingNodeName}
     AddC $p (Margin (Pill '✓ 此服务器已完成服务端部署 (无需重复安装)' '#0F5132' '#D1E7DD') '0,10,0,0')
     if($i.ExistingNodeName){Row $p '已部署节点名称' $i.ExistingNodeName '#0F5132'}
     AddC $p (Margin (Note '云端 WireGuard 与防火墙转发已就绪。点击下方主按钮，直接为这台电脑添加授权并自动并入自建线路。') '0,10,0,0')
    }else{
     AddC $p (Margin (Note '下一步只保存服务器部署计划及公开设备申请。本机私钥不会上传，也不会修改当前香港线路。') '0,16,0,0')
    }
    $bar=New-Object Windows.Controls.WrapPanel;$bar.Margin='0,20,0,0'
    if($isDeployed){
     $bAuth=Btn '该服务器已部署：直接为本机授权并导入线路' 'LinuxAuthFromInspect' {StartLinux 'Authorize'} 'Primary'
     $bAuth.Margin='0,0,10,0';AddC $bar $bAuth
     $bPlan=Btn '重新生成计划并覆盖…' 'LinuxPlan' {StartLinux 'Plan'} 'Ghost'
     $bPlan.Margin='0,0,10,0';AddC $bar $bPlan
    }else{
     $b=Btn '生成部署计划' 'LinuxPlan' {StartLinux 'Plan'} 'Primary';$b.IsEnabled=[bool]$i.Supported
     $b.Margin='0,0,10,0';AddC $bar $b
    }
    $bReinspect=Btn '重新检查' 'LinuxReinspect' {StartLinux 'Inspect'} 'Btn';$bReinspect.Margin='0,0,10,0';AddC $bar $bReinspect
    $bEdit=Btn '修改资料' 'LinuxEdit' {$script:Linux.Stage=0;ShowLinux} 'Ghost';AddC $bar $bEdit
    AddC $p $bar
   }
   2 {
    $d=$script:Linux.Data;$p=WizardCard '部署前核对' '以下变更只应用到指定的新 Linux 服务器。' 'server'
    Row $p '节点名称' ([string]$d.Name);Row $p '公网端点' ([string]$d.PublicEndpoint);Row $p '服务器隧道地址' ([string]$d.ServerAddress);Row $p '本机授权地址' ([string]$d.ClientAddress)
    $tcp=if($d.PSObject.Properties['Transport']){$d.Transport}else{$null}
    if($tcp){Row $p '客户端传输' ('TCP '+[string]$tcp.Port);Row $p '伪装域名' ([string]$tcp.ServerName);AddC $p (Margin (Note '将额外下载并校验固定版本 sing-box 服务端、生成服务器专属传输身份，创建本节点独立的 TCP 服务。') '0,10,0,0')}
    LinuxTasks $p $d.Steps;LinuxTasks $p $d.Warnings
    AddC $p (Margin (Note $(if($tcp){'云安全组须放行 TCP '+[string]$tcp.Port+'，保留 SSH 管理端口。WireGuard 的 UDP 中继在服务器本机完成。'}else{'云安全组须放行上方端点的 UDP 端口，保留 SSH 管理端口。工具不能替你确认云端放行。'})) '0,18,0,0')
    if($tcp){SetupTasks $p @('在云控制台为这台 VPS 放行 TCP '+[string]$tcp.Port+'，保留 SSH 管理端口。','VLESS/Reality 服务只中继本节点的 WireGuard 数据，不作为普通开放代理。','服务器需要能访问指定伪装域名的 HTTPS 服务。')}else{SetupTasks $p @('在购买 VPS 的网站打开这台服务器详情 → 安全组／云防火墙 → 入站规则。','添加允许规则：协议 UDP，目标端口填上方公网端点冒号后的数字（默认 51820），保存并绑定到这台 VPS。','保留 TCP 的 SSH 端口。来源可填本地公网 IP/32；公网 IP 经常变化时，详见 Linux 部署指南。','若厂商明确显示未启用云防火墙、入站默认放行，无需添加重复规则。此设置不在 Windows WireGuard 界面里。')}
    $cb=ControlName (New-Object Windows.Controls.CheckBox) 'LinuxCloudConfirmed';$cb.Content=$(if($tcp){'已核对云端允许 TCP '+[string]$tcp.Port+' 入站，并保留 SSH 入口'}else{'已核对云端允许此 UDP 端口入站，并保留 SSH 入口'});$cb.Margin='0,18,0,0';$cb.IsChecked=[bool]$script:Linux.CloudConfirmed;$cb.Add_Click({$script:Linux.CloudConfirmed=[bool]$this.IsChecked;$script:Controls.LinuxApply.IsEnabled=$script:Linux.CloudConfirmed});AddC $p $cb
    $bar=Stack 'Horizontal';$bar.Margin='0,20,0,0';$b=Btn '应用到新服务器…' 'LinuxApply' {ConfirmLinuxApply} 'Primary';$b.IsEnabled=[bool]$script:Linux.CloudConfirmed;AddC $bar $b;AddC $bar (Margin (Btn '重新生成计划' 'LinuxReplan' {$script:Linux.Stage=0;ShowLinux} 'Ghost') '10,0,0,0');AddC $p $bar
   }
   3 {
    $p=WizardCard '服务器配置已应用' '接下来合成本机配置并登记新节点，当前线路继续保持。' 'check'
    AddC $p (Pill '已应用 · 外网与重启恢复待验证' 'warn')
    SetupTasks $p @('点击下方按钮，核对服务器授权并在本机生成客户端配置。','继续交易电脑向导，确认程序路径与网络，保存为新节点。','新节点需要另行验证实际出口、行情与重启恢复，不能仅凭部署成功停用旧服务器。','正式换线会短暂断开连接；处理好账户状态并退出整个 NinjaTrader 后再操作。AI 若跟随交易线路，也要验证新出口可用。')
    $b=Btn '生成本机配置并进入导入向导' 'LinuxComplete' {CompleteLinuxClient} 'Primary';$b.HorizontalAlignment='Left';AddC $p $b
    $bAuth=Btn '私钥缺失或断点恢复：重新为本机授权并导入' 'LinuxStage3Auth' {StartLinux 'Authorize'} 'Btn';$bAuth.HorizontalAlignment='Left';$bAuth.Margin='0,10,0,0';AddC $p $bAuth
    $b=Btn '检查服务器状态' 'LinuxStatus' {StartLinux 'Status'} 'Ghost';$b.HorizontalAlignment='Left';$b.Margin='0,12,0,0';AddC $p $b
   }
   4 {
    $d=$script:Linux.Data;$p=WizardCard '服务器状态' '这是服务器本地状态，外网和实际交易应用需要单独验收。' 'server'
    Row $p '服务器' ([string]$script:Linux.Host);if($d.Status){Row $p '云端部署状态' ([string]$d.Status) '#0F5132'}
    # 检查本地线路库中是否已存在该服务器线路（防止重复生成配置与线路重复堆叠）
    $existingNode=@($script:Nodes|Where-Object {$_.endpoint -like ([string]$script:Linux.Host+':*')})[0]
    if($existingNode){
     Row $p '本机线路状态' ('已导入本机（线路名称：'+$existingNode.name+'）') '#0F5132'
     AddC $p (Margin (Pill '✓ 本机已完成该服务器的配置生成与线路添加，无需重复操作' '#0F5132' '#D1E7DD') '0,8,0,8')
    }else{
     Row $p '本机线路状态' '尚未导入为本机自建线路' '#E65100'
    }
    if($d.Summary){AddC $p (T ([string]$d.Summary) 13 $script:Text2)}
    LinuxTasks $p $d.Issues;LinuxTasks $p $d.Warnings
    AddC $p (Margin (Note '服务进程存在或配置已应用，不代表客户端握手、外网转发、重启恢复和行情已通过。') '0,16,0,0')
    $btnBar=New-Object Windows.Controls.WrapPanel;$btnBar.Margin='0,16,0,0'
    if($existingNode){
     $bGoNodes=Btn '前往线路列表查看/连接' 'LinuxGoNodes' {ShowNodes;FetchNodes} 'Primary'
     $bGoNodes.Margin='0,0,10,0';AddC $btnBar $bGoNodes
     $bAuth=Btn '为此电脑重新生成授权…' 'LinuxAuthFromStatus' {StartLinux 'Authorize'} 'Ghost';$bAuth.Margin='0,0,10,0';AddC $btnBar $bAuth
    }elseif($script:Linux.ApplyJobId){
     $bComplete=Btn '完成部署：生成配置并导入线路' 'LinuxCompleteFromStatus' {if($script:Linux.ApplyJobId){$script:Linux.JobId=$script:Linux.ApplyJobId};CompleteLinuxClient} 'Primary'
     $bComplete.Margin='0,0,10,0';AddC $btnBar $bComplete
     $bAuth=Btn '为本机重新生成授权…' 'LinuxAuthFromStatus' {StartLinux 'Authorize'} 'Ghost';$bAuth.Margin='0,0,10,0';AddC $btnBar $bAuth
    }elseif($d.Status -eq 'Applied'){
     $bAuth=Btn '为本机生成独立授权并导入' 'LinuxAuthFromStatus' {StartLinux 'Authorize'} 'Primary';$bAuth.Margin='0,0,10,0';AddC $btnBar $bAuth
    }
    $bBack=Btn '返回服务器资料' 'LinuxStateBack' {$script:Linux.Stage=0;ShowLinux} 'Btn';AddC $btnBar $bBack
    AddC $p $btnBar
   }
  }
 }
 if(-not $script:Linux.Busy -and $script:Linux.Error -and $script:Linux.PlanJobId){
  $bar=Stack 'Horizontal';$bar.Margin='0,14,0,0';AddC $bar (Btn '检查服务器实际状态' 'LinuxFailureStatus' {StartLinux 'Status'} 'Btn')
  AddC $bar (Margin (Btn '恢复未完成的部署…' 'LinuxRecover' {OpenDialog '恢复这次 Linux 部署？' '只恢复所选计划拥有的服务器配置。已经承载其他设备或配置已被手工改变时，工具会停止并说明原因。' '当前本机香港通道保持；操作会打开 SSH 登录窗口。' '检查并恢复' {StartLinux 'Recover'}} 'Ghost') '10,0,0,0');AddC $script:HostPanel $bar
  $b=Btn '核验并完成部署记录…' 'LinuxFinalize' {OpenDialog '核验已创建的服务器配置？' '只适用于这份计划的首次部署。服务器必须完整符合计划：文件、服务、设备授权和防火墙均通过，才会完成部署记录并生成客户端资料。' '不会重装或忽略差异；未通过校验时保留待处理状态。' '核验并完成' {StartLinux 'Finalize'}} 'Ghost';$b.HorizontalAlignment='Left';$b.Margin='0,10,0,0';AddC $script:HostPanel $b
 }
  if(-not $script:Linux.Busy -and @($script:Linux.Recent).Count){
   SectionLabel $script:HostPanel '本机近期任务与服务器记录'
   foreach($item in @($script:Linux.Recent)){
    $card=Card '20,14';$card.CornerRadius='10';$card.Margin='0,0,0,10';$card.Background=B '#FAFAFA'
    $g=Grid @('*','Auto');$sp=Stack
    $titleText=if($item.Name){$item.Name+' ('+$item.Host+')'}else{'服务器：'+$item.Host}
    AddC $sp (T $titleText 13.5 $script:Ink 'SemiBold')
    $stageDesc='执行中…';$pillBg='#E3E6EA';$pillFg='#4B5360';$btnText='查看 / 继续';$btnStyle='Btn'
    if($item.Operation -eq 'Apply' -and $item.Status -in @('Completed','Complete')){
     $stageDesc='已部署完成 · 待导入本机';$pillBg='#D1E7DD';$pillFg='#0F5132';$btnText='继续并导入线路';$btnStyle='Primary'
    }elseif($item.Operation -eq 'Authorize' -and $item.Status -in @('Completed','Complete')){
     $stageDesc='设备授权完成 · 待导入本机';$pillBg='#D1E7DD';$pillFg='#0F5132';$btnText='继续并导入线路';$btnStyle='Primary'
    }elseif($item.Operation -eq 'Plan' -and $item.Status -in @('Completed','Complete')){
     $stageDesc='计划已生成 · 等待应用';$pillBg='#FFF3CD';$pillFg='#664D03';$btnText='继续应用部署';$btnStyle='Primary'
    }elseif($item.Operation -eq 'Inspect' -and $item.Status -in @('Completed','Complete')){
     $stageDesc='环境检查完成 · 尚未部署';$pillBg='#E9ECEF';$pillFg='#495057';$btnText='查看检查结果';$btnStyle='Ghost'
    }elseif($item.Operation -eq 'Status'){
     $stageDesc='状态检查 · 服务器在线';$pillBg='#CFE2FF';$pillFg='#084298';$btnText='查看服务器状态';$btnStyle='Btn'
    }elseif($item.Status -in @('Failed','Fault')){
     $stageDesc=$(if($item.OutcomeUnknown){'结果未知 · 需检查服务器'}else{'任务异常'});$pillBg='#F8D7DA';$pillFg='#842029';$btnText='查看报错';$btnStyle='Ghost'
    }
    $rowMeta=Stack 'Horizontal';$rowMeta.Margin='0,6,0,0'
    AddC $rowMeta (Pill $stageDesc $pillFg $pillBg)
    if($item.CreatedAt){
     $timeStr=try{([DateTimeOffset]::Parse([string]$item.CreatedAt)).ToLocalTime().ToString('MM-dd HH:mm')}catch{[string]$item.CreatedAt}
     AddC $rowMeta (Margin (T $timeStr 12 '#858C97') '10,0,0,0')
    }
    AddC $sp $rowMeta;Cell $g $sp 0
    $b=Btn $btnText '' {ResumeLinux ([string]$this.Tag)} $btnStyle;$b.Tag=[string]$item.JobId;$b.VerticalAlignment='Center'
    Cell $g $b 1;$card.Child=$g;AddC $script:HostPanel $card
   }
  }
 $back=Btn '返回部署入口' 'LinuxBack' {$script:Role='client';$script:Step=0;ShowSetup} 'Ghost';$back.HorizontalAlignment='Left';$back.Margin='0,18,0,0';AddC $script:HostPanel $back
}
