#requires -Version 5.1
# Shared by local preflight and the live exit probe. Never include source JSON
# or an inner parser exception in diagnostic output: configs contain secrets.
function Read-TCExitDiagnosticJson {
    param([Parameter(Mandatory=$true)][string]$Path)
    try {
        Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw '[TC:DiagnosticConfigReadFailed] 无法读取出口检查配置，请重新核对本机连接资料。'
    }
}
function Get-TCExitDiagnosticInput {
    param([Parameter(Mandatory=$true)]$Manifest,[ValidateSet('Trade','Daily')][string]$Lane='Trade',[switch]$CheckInterfaces)
    $cfg=Read-TCExitDiagnosticJson -Path ([string]$Manifest.CandidatePath)
    $inbound=@($cfg.inbounds | Where-Object tag -ceq 'egress-probe')
    if($inbound.Count -ne 1 -or $inbound[0].type -cne 'mixed' -or $inbound[0].listen -cne '127.0.0.1' -or [int]$inbound[0].listen_port -lt 1 -or [int]$inbound[0].listen_port -gt 65535){
        throw '[TC:ProbeRouteUnverified] 缺少有效的本机出口检查入口，请重新准备此线路。'
    }
    $name=if($Lane -eq 'Daily'){'tradechannel-daily'}else{'tradechannel-probe'}
    $user=@($inbound[0].users | Where-Object username -ceq $name)
    if($user.Count -ne 1 -or -not $user[0].password -or [string]$user[0].password -match '[\r\n"\\]'){
        throw '[TC:ProbeRouteUnverified] 出口检查身份缺失或不唯一，请重新准备此线路。'
    }
    if($CheckInterfaces){
        if($Manifest.PSObject.Properties['NetworkPolicy'] -and $Manifest.NetworkPolicy){
            $policy=$Manifest.NetworkPolicy
            if($policy.SchemaVersion -ne 1 -or $policy.Kind -cne 'PhysicalInterface' -or -not $policy.InterfaceId){throw '[TC:DiagnosticInterfaceUnknown] 本机网络策略格式无法核验。'}
            try{$adapters=@(Get-NetAdapter -IncludeHidden -ErrorAction Stop)}catch{throw '[TC:DiagnosticInterfaceUnknown] 无法读取网卡身份。'}
            $same=@($adapters|Where-Object {([string]$_.InterfaceGuid).Trim('{}') -ieq ([string]$policy.InterfaceId).Trim('{}')})
            if($same.Count -ne 1){throw '[TC:DiagnosticInterfaceMissing] 原物理网卡已不可用，请选择本机网络。'}
            if($same[0].Name -cne $policy.InterfaceName){throw '[TC:DiagnosticInterfaceRenamed] 原物理网卡已改名，请更新此线路的本机网络设置。'}
        }
        $names=@(@($cfg.endpoints)+@($cfg.outbounds)+@($cfg.dns.servers)+@($cfg.route) | ForEach-Object {
            if($_.bind_interface){[string]$_.bind_interface}
            if($_.default_interface){[string]$_.default_interface}
        } | Select-Object -Unique)
        if($names.Count){
            try{$available=@(Get-NetAdapter -IncludeHidden -ErrorAction Stop | ForEach-Object {$_.Name})}
            catch{throw '[TC:DiagnosticInterfaceUnknown] 无法核对连接配置绑定的网卡，请重试本机网络检查。'}
            foreach($name in $names){if($name -notin $available){throw '[TC:DiagnosticInterfaceMissing] 连接配置绑定的网卡已不存在，请重新选择检测网络并准备配置。'}}
        }
        # A dial pinned to a local IPv4 address fails once DHCP or a network
        # change moves that address; catch it before the old line is stopped.
        $pinned=@(@($cfg.endpoints)+@($cfg.outbounds)+@($cfg.dns.servers) | Where-Object {$_ -and $_.inet4_bind_address} | ForEach-Object {
            [pscustomobject]@{Interface=[string]$_.bind_interface;Address=[string]$_.inet4_bind_address}
        })
        if($pinned.Count){
            try{$assigned=@(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | ForEach-Object {[pscustomobject]@{Interface=[string]$_.InterfaceAlias;Address=[string]$_.IPAddress}})}
            catch{throw '[TC:DiagnosticInterfaceUnknown] 无法核对连接配置绑定的网卡，请重试本机网络检查。'}
            foreach($pin in $pinned){
                if(-not @($assigned | Where-Object {$_.Address -eq $pin.Address -and (-not $pin.Interface -or $_.Interface -eq $pin.Interface)}).Count){throw '[TC:DiagnosticAddressChanged] 连接配置绑定的本机 IPv4 地址已不在所选网卡上，请重新检查这条线路以更新网络绑定。'}
            }
        }
    }
    # This object stays inside the caller; never serialize it as evidence.
    [pscustomobject]@{Config=$cfg;Inbound=$inbound[0];User=$user[0]}
}
# The fallback domain check connects to an address that an in-tunnel DoH lookup returned. Accept exactly that shape:
# the URL's own name on port 443 and a public unicast IPv4 literal, never a loopback, private or reserved address.
function Test-TCPublicIPv4Literal {
    param([string]$Text)
    $ip=$null
    if($Text -notmatch '^\d{1,3}(\.\d{1,3}){3}$' -or -not [Net.IPAddress]::TryParse($Text,[ref]$ip) -or $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork){return $false}
    $b=$ip.GetAddressBytes()
    if($b[0] -in 0,10,127 -or $b[0] -ge 224){return $false}
    if($b[0] -eq 100 -and $b[1] -ge 64 -and $b[1] -le 127){return $false}
    if($b[0] -eq 169 -and $b[1] -eq 254){return $false}
    if($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31){return $false}
    if($b[0] -eq 192 -and ($b[1] -eq 168 -or ($b[1] -eq 0 -and $b[2] -in 0,2))){return $false}
    if($b[0] -eq 198 -and ($b[1] -in 18,19 -or ($b[1] -eq 51 -and $b[2] -eq 100))){return $false}
    if($b[0] -eq 203 -and $b[1] -eq 0 -and $b[2] -eq 113){return $false}
    return $true
}
function Assert-TCExitProbeConnectTo {
    param([string]$Url,[string]$ConnectTo)
    $uri=[Uri]$Url
    if($ConnectTo -cnotmatch '^(?<host>[A-Za-z0-9][A-Za-z0-9.-]{0,252}):443:(?<ip>\d{1,3}(?:\.\d{1,3}){3}):443$'){throw 'Invalid connect-to target.'}
    if(-not [string]::Equals($matches['host'],$uri.DnsSafeHost,[StringComparison]::OrdinalIgnoreCase) -or $uri.Port -ne 443){throw 'The connect-to name must be the URL host on port 443.'}
    if(-not (Test-TCPublicIPv4Literal $matches['ip'])){throw 'The connect-to address must be a public IPv4 address.'}
}
