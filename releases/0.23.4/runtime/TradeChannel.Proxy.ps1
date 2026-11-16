#requires -Version 5.1
# Pure interpretation of the WinINet proxy state. No registry or network writes here.
# While TradeChannel runs it owns the system proxy: every enabled proxy or PAC is
# suspended (and restored on exit). An unrecognized value is reported, never fatal.
function ConvertTo-TradeProxySummary {
    param([string]$Value)
    $text=([string]$Value).Trim()
    if(-not $text){return ''}
    $uri=$null
    if([Uri]::TryCreate($text,[UriKind]::Absolute,[ref]$uri) -and $uri.Host){return ($uri.Scheme+'://'+$uri.Host+':'+$uri.Port)}
    # host:port lists; drop any credentials before display or persistence.
    $parts=@(foreach($entry in ($text -split ';')){
        $value=($entry -split '=',2)[-1].Trim()
        if($value -match '@'){$value=($value -split '@')[-1]}
        if($value){$value}
    })
    return (($parts|Select-Object -Unique) -join ';')
}
function Get-TradeProxyDecision {
    [CmdletBinding()]
    param(
        [int]$ProxyEnable,
        [AllowNull()][string]$ProxyServer,
        [AllowNull()][string]$AutoConfigURL,
        [int]$HttpPort=8001,
        [int]$SocksPort=10823,
        [int]$PacPort=7777,
        # Every local port any registered provider may drive the system proxy to.
        [AllowNull()][AllowEmptyCollection()][int[]]$KnownPorts,
        [AllowNull()][AllowEmptyCollection()][int[]]$PacPorts
    )
    $pacText=([string]$AutoConfigURL).Trim()
    # BatVPN's bundled sysproxy.exe literally stores "off" during OFF/mode transitions.
    $pacOff=($pacText -ieq 'off')
    $pacActive=(-not [string]::IsNullOrWhiteSpace($pacText) -and -not $pacOff)
    $ports=@(@($HttpPort,$SocksPort)+@($KnownPorts)|Where-Object {$_ -gt 0}|Select-Object -Unique)
    $pacList=@(@($PacPort)+@($PacPorts)|Where-Object {$_ -gt 0}|Select-Object -Unique)
    # Keep string concatenation independent of PowerShell's comma operator.
    $known=@(foreach($port in $ports){('127.0.0.1:'+$port);('localhost:'+$port)})
    $recognized=$true
    if($ProxyEnable -eq 1){
        if([string]::IsNullOrWhiteSpace($ProxyServer)){$recognized=$false}
        else{
            foreach($entry in ($ProxyServer -split ';')){
                $value=($entry -split '=',2)[-1].Trim()
                if($value -and $value -notin $known){$recognized=$false}
            }
        }
    }
    if($pacActive){
        $uri=$null
        if(-not [Uri]::TryCreate($pacText,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -ne 'http' -or $uri.Host -notin @('127.0.0.1','localhost') -or $pacList -notcontains $uri.Port){$recognized=$false}
    }
    $active=($ProxyEnable -eq 1 -or $pacActive)
    $summary=@()
    if($ProxyEnable -eq 1){$summary+=ConvertTo-TradeProxySummary $ProxyServer}
    if($pacActive){$summary+=('PAC '+(ConvertTo-TradeProxySummary $pacText))}
    [pscustomobject]@{
        # Kept for older callers: no proxy state is ever a reason to stop the channel.
        Allowed=$true
        Reason=$null
        Kind=$(if(-not $active){'None'}elseif($recognized){'Provider'}else{'Unknown'})
        Summary=(($summary|Where-Object {$_}) -join ' / ')
        ProxyEnabled=($ProxyEnable -eq 1)
        PACEnabled=$pacActive
        PACDisabledMarker=$pacOff
        NeedsNormalization=($ProxyEnable -eq 1 -or $pacActive -or $pacOff)
        # Only a real PAC URL can be restored. Never restore the invalid URI marker.
        RestorablePAC=$(if($pacActive){$pacText}else{$null})
    }
}
