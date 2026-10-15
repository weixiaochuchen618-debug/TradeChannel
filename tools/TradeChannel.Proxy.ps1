#requires -Version 5.1
# Pure interpretation of the BatVPN/WinINet state. No registry or network writes here.
function Get-TradeProxyDecision {
    [CmdletBinding()]
    param(
        [int]$ProxyEnable,
        [AllowNull()][string]$ProxyServer,
        [AllowNull()][string]$AutoConfigURL,
        [int]$HttpPort=8001,
        [int]$SocksPort=10823,
        [int]$PacPort=7777
    )
    $pacText=([string]$AutoConfigURL).Trim()
    # BatVPN's bundled sysproxy.exe literally stores "off" during OFF/mode transitions.
    $pacOff=($pacText -ieq 'off')
    $pacActive=(-not [string]::IsNullOrWhiteSpace($pacText) -and -not $pacOff)
    # Keep string concatenation independent of PowerShell's comma operator.
    $allowed=@(('127.0.0.1:'+$HttpPort),('localhost:'+$HttpPort),('127.0.0.1:'+$SocksPort),('localhost:'+$SocksPort))
    $reason=$null
    if($ProxyEnable -eq 1){
        if([string]::IsNullOrWhiteSpace($ProxyServer)){$reason='Enabled system proxy has no server address.'}
        else{
            foreach($entry in ($ProxyServer -split ';')){
                $value=($entry -split '=',2)[-1].Trim()
                if($value -notin $allowed){$reason='An unrecognized system proxy was enabled.';break}
            }
        }
    }
    if($pacActive){
        $uri=$null
        if(-not [Uri]::TryCreate($pacText,[UriKind]::Absolute,[ref]$uri)){$reason='An unrecognized PAC script requires review.'}
        elseif($uri.Scheme -ne 'http' -or $uri.Host -notin @('127.0.0.1','localhost') -or $uri.Port -ne $PacPort){$reason='An unrecognized PAC script requires review.'}
    }
    [pscustomobject]@{
        Allowed=($null -eq $reason)
        Reason=$reason
        ProxyEnabled=($ProxyEnable -eq 1)
        PACEnabled=$pacActive
        PACDisabledMarker=$pacOff
        NeedsNormalization=($ProxyEnable -eq 1 -or $pacActive -or $pacOff)
        # Only a real PAC URL can be restored. Never restore the invalid URI marker.
        RestorablePAC=$(if($pacActive){$pacText}else{$null})
    }
}
