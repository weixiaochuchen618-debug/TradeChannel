# The dialog context outlives all worker callbacks; no secret WireGuard fields
# are ever placed into this form. Reality public parameters belong to one node.
$script:TransportForm=$null
function TransportField {
    param($Parent,[string]$Label,[string]$Key,[string]$Hint='')
    AddC $Parent (Margin (T $Label 12.5 $script:Ink 'SemiBold') '0,10,0,4')
    $box=ControlName (New-Object Windows.Controls.TextBox) ('Transport'+$Key)
    $box.Text=[string]$script:TransportForm[$Key];$box.Tag=$Key
    $box.Add_TextChanged({$script:TransportForm[[string]$this.Tag]=$this.Text})
    AddC $Parent $box
    if($Hint){AddC $Parent (Margin (T $Hint 11.5 $script:Text3) '0,3,0,0')}
}
function ShowTransportForm {
    PageHead 'TCP 传输设置' '填写这台服务器的连接参数。保存后重新连接才生效。' 'nodes'
    $card=Card '24,20';$p=Stack;$card.Child=$p
    AddC $p (T ('线路：'+[string]$script:TransportForm.Name) 16 $script:Ink 'SemiBold')
    TransportField $p '传输服务器' 'Server' '通常与 WireGuard 服务器相同，也可填写管理员指定的域名。'
    TransportField $p 'TCP 端口' 'Port' '填写服务器实际监听端口，例如 443。'
    TransportField $p '用户 UUID' 'Uuid'
    TransportField $p 'Reality 公钥' 'RealityPublicKey' '填写服务器公钥；服务端私钥不应复制到客户端。'
    TransportField $p 'ShortId' 'RealityShortId' '偶数位十六进制，最多 16 位；服务器允许空值时可留空。'
    TransportField $p '伪装域名（SNI）' 'ServerName' '与服务器 Reality 配置一致，例如 www.bing.com。'
    AddC $p (Margin (Note '服务器必须已配置对应的 VLESS/Reality 服务。仅把客户端切到 TCP 不能在服务器上创建服务。新 Linux 服务器可在部署向导选择 TCP 方式。') '0,14,0,0')
    $bar=Stack 'Horizontal';$bar.Margin='0,18,0,0'
    AddC $bar (Btn '保存 TCP 设置…' 'SaveTransport' {
        $parameters=@{}
        foreach($key in @('Server','Port','Uuid','RealityPublicKey','RealityShortId','ServerName')){$parameters[$key]=[string]$script:TransportForm[$key]}
        $script:TransportSubmission=@{Id=[string]$script:TransportForm.Id;Parameters=$parameters}
        OpenDialog '保存该线路的 TCP 配置？' ('线路：'+[string]$script:TransportForm.Name+'；传输端点：'+$parameters.Server+':'+$parameters.Port+'。') '保存会创建新的经过校验的配置，旧配置保留。请先断开正在使用的这条线路。' '保存配置' {
            StartJob @{Action='SetTransportMode';Id=$script:TransportSubmission.Id;Mode='Tcp';TransportParams=$script:TransportSubmission.Parameters} {param($d)ShowNodes;FetchNodes;Toast $d.Message} '正在校验并保存 TCP 配置…'
        } '取消'
    } 'Primary')
    AddC $bar (Margin (Btn '返回线路' 'CancelTransport' {ShowNodes;FetchNodes} 'Btn') '10,0,0,0')
    AddC $p $bar;AddC $script:HostPanel $card
}
function LoadTransportForm {
    param([string]$Id)
    StartJob @{Action='TransportInfo';Id=$Id} {param($d)
        $script:TransportForm=@{Id=[string]$d.Id;Name=[string]$d.Name;Server=[string]$d.DefaultServer;Port='443';Uuid='';RealityPublicKey='';RealityShortId='';ServerName=''}
        if($d.Settings){foreach($key in @('Server','Port','Uuid','RealityPublicKey','RealityShortId','ServerName')){$script:TransportForm[$key]=[string]$d.Settings.$key}}
        ShowTransportForm
    } '正在读取该线路的 TCP 设置…'
}
